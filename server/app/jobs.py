"""生成任务管理：在服务器侧完成上游请求，客户端断线也不影响输出。

2026-11 全家桶之后，联网搜索 / 阅读链接由**上游服务端**执行：客户端在
`tools` 里声明 `deepseek_web_search` / `deepseek_read_url`，模型自己搜，
结果以 `server_tool_use` + `web_search_tool_result` 事件流回。所以这里**不再**
有 search/fetch 的客户端工具循环。

保留的是「通用函数工具执行框架」，目前只服务一个工具：`ocr`。
模型调用 `ocr` 时，服务端从文件缓存取原始字节，调上游 `/v1/tools/ocr`，
把逐页文本拼成字符串回填给模型，然后继续下一轮请求。

注意：**服务端不往 payload 里塞任何工具**。官方限制「声明了
`deepseek_web_search` / `deepseek_read_url` 时不能与其他服务端工具混用」，
工具声明完全由客户端决定，服务端只负责执行客户端声明的函数工具。
"""

from __future__ import annotations

import http.client
import json
import ssl
import threading
import time
import uuid
from typing import Any
from urllib.parse import urlsplit

from .config import Config
from .filecache import CachedFile, FileCache
from .multipart import build_multipart
from .sse import (
    PROTOCOL_ANTHROPIC,
    PROTOCOL_RESPONSES,
    SERVER_FUNCTION_TOOL_NAMES,
    StreamAccumulator,
    extract_error,
    upstream_path,
)
from .tools import MAX_MEDIA_RESPONSE_BYTES, proxy_json_request, proxy_multipart_request

# 上游错误响应体只保留前若干字节，避免异常时占满内存
_MAX_ERROR_BODY = 1024 * 1024

# 服务端执行的函数工具：ocr 的默认 purpose 与可接受值
_OCR_PURPOSES = frozenset({"text_recognition", "rich_layout_recognition"})
_DEFAULT_OCR_PURPOSE = "text_recognition"


def _parse_arguments(raw: Any) -> dict[str, Any]:
    """把模型给的 arguments（JSON 字符串或对象）解析成字典。"""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        return decoded if isinstance(decoded, dict) else {}
    return {}


def _tool_error_message(body: str, status: int) -> str:
    """从工具错误响应里取可读信息。"""
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError:
        return f"HTTP {status}"
    if isinstance(decoded, dict):
        error = decoded.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message:
                return message
    return f"HTTP {status}"


class Job:
    """一次生成任务的完整状态。"""

    def __init__(
        self,
        protocol: str,
        payload: dict[str, Any],
        headers: dict[str, str],
        upstream_base: str,
        timeout: float,
        conversation_id: int | None = None,
    ) -> None:
        self.id = uuid.uuid4().hex
        self.protocol = protocol
        self.payload = payload
        self.headers = headers
        self.upstream_base = upstream_base
        self.timeout = timeout
        # 关联的会话：任务结束后由服务端直接把回答写进存储
        self.conversation_id = conversation_id
        self.stored_message_id: int | None = None
        # 最终内容是否已经写进会话存储（checkpoint 行可能先于它创建）
        self.result_ready = False
        self.status = "starting"
        self.error: str | None = None
        self.upstream_status: int | None = None
        self.error_body: str | None = None
        self.acc = StreamAccumulator(protocol)
        self.lines: list[str] = []
        self.created_at = time.time()
        self.updated_at = self.created_at
        self.finished_at: float | None = None
        # 打点：上游何时返回状态码、第一条 SSE 何时到、请求体多大
        self.upstream_status_at: float | None = None
        self.first_line_at: float | None = None
        self.request_bytes = 0
        # 上次 checkpoint 时间：0 表示还没有写过，首段正文到达就立即写一次
        self.last_checkpoint_at = 0.0
        # 模型用 text_to_speech 生成的音频：文件 id 列表（字节存在音频缓存里，
        # 客户端按 id 从 /v1/audio/{id} 取回，避免把二进制塞进消息或快照）
        self.audio_files: list[dict[str, Any]] = []
        self._cv = threading.Condition()
        self._canceled = False
        self._conn: http.client.HTTPConnection | None = None

    # ------------------------------------------------------------ 状态读写

    @property
    def finished(self) -> bool:
        return self.status in ("done", "error", "canceled")

    @property
    def canceled(self) -> bool:
        return self._canceled

    def final_status(self) -> str:
        """最终状态：已结束时就是当前状态，未结束时按取消/错误/正常推算。"""
        if self.finished:
            return self.status
        if self._canceled:
            return "canceled"
        if self.acc.error or self.error:
            return "error"
        return "done"

    def set_upstream_result(self, status: int, error_body: str | None = None) -> None:
        """记录上游结果。

        非 200 时必须连错误响应体一起写入，否则调用方会在读完 body 之前
        就把响应转发出去，导致客户端收到空错误体。
        """
        with self._cv:
            self.upstream_status_at = time.time()
            self.upstream_status = status
            if status == 200:
                self.status = "running"
            else:
                self.error_body = error_body
                self.error = extract_error(error_body or "", status)
                self.status = "error"
                self.finished_at = time.time()
            self.updated_at = time.time()
            self._cv.notify_all()

    def append_line(self, line: str) -> None:
        with self._cv:
            if self.first_line_at is None:
                self.first_line_at = time.time()
            self.lines.append(line)
            self.updated_at = time.time()
            self._cv.notify_all()

    def fail(self, message: str) -> None:
        with self._cv:
            if self.finished:
                return
            self.status = "error"
            self.error = message
            self.finished_at = time.time()
            self.updated_at = self.finished_at
            self._cv.notify_all()

    def finish(self) -> None:
        """流正常结束：根据累加器结果落定最终状态。"""
        with self._cv:
            if self.finished:
                return
            if self.acc.error:
                self.status = "error"
                self.error = self.acc.error
            else:
                self.status = "done"
            self.finished_at = time.time()
            self.updated_at = self.finished_at
            self._cv.notify_all()

    def cancel(self) -> None:
        with self._cv:
            if self.finished:
                return
            self._canceled = True
            self.status = "canceled"
            self.finished_at = time.time()
            self.updated_at = self.finished_at
            conn = self._conn
            self._cv.notify_all()
        # 关掉上游连接，让正在阻塞的读取线程立刻退出
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass

    # ------------------------------------------------------------ 读取接口

    def wait_for_start(self, deadline: float) -> bool:
        """等待上游返回状态码，返回 False 表示超时。"""
        with self._cv:
            while self.upstream_status is None and self.status == "starting":
                remaining = deadline - time.time()
                if remaining <= 0:
                    return False
                self._cv.wait(remaining)
            return True

    def tail(self, index: int, timeout: float) -> tuple[list[str], bool]:
        """取 [index:] 的新行；第二项表示任务已结束且没有更多行。"""
        with self._cv:
            deadline = time.time() + max(timeout, 0.0)
            # 等到“有新行”或“任务结束”为止；被无关通知唤醒时继续等
            while index >= len(self.lines) and not self.finished:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                self._cv.wait(remaining)
            new_lines = self.lines[index:]
            done = self.finished and index + len(new_lines) >= len(self.lines)
            return new_lines, done

    def snapshot(self) -> dict[str, Any]:
        with self._cv:
            return {
                "job_id": self.id,
                "protocol": self.protocol,
                "status": self.status,
                "reasoning": self.acc.reasoning,
                "content": self.acc.content,
                "sources": list(self.acc.sources),
                # 新增：服务端工具步骤与引用（旧字段全部保留）
                "steps": _public_steps(self.acc.steps),
                "citations": list(self.acc.citations),
                # 模型生成的音频：客户端按 id 去 /v1/audio/{id} 取回二进制
                "audio": list(self.audio_files),
                "reasoning_ms": self.acc.reasoning_ms(),
                "error": self.error,
                "conversation_id": self.conversation_id,
                "stored_message_id": self.stored_message_id,
                "result_ready": self.result_ready,
                "line_count": len(self.lines),
                "created_at": self.created_at,
                "updated_at": self.updated_at,
            }

    def summary(self) -> str:
        """一行打点：上行大小 / 上游首字节 / 首个增量 / 思考用时 / 总耗时。

        排查“回复变慢”时先看这一行：ttfb 大 = 上游排队或网络慢；
        reasoning 大 = 模型思考久（客户端会看到“正在思考”）；
        bytes 大 = 客户端上行（图片）大，上传本身就要时间。
        """

        def elapsed(value: float | None) -> str:
            if value is None:
                return "-"
            return f"{value - self.created_at:.1f}s"

        total = (self.finished_at or time.time()) - self.created_at
        return (
            f"job {self.id[:8]} conv={self.conversation_id} "
            f"status={self.status} upstream={self.upstream_status or '-'} "
            f"bytes={self.request_bytes} ttfb={elapsed(self.upstream_status_at)} "
            f"first_delta={elapsed(self.first_line_at)} "
            f"reasoning={self.acc.reasoning_ms() / 1000:.1f}s "
            f"total={total:.1f}s"
        )


def _public_steps(steps: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """对外输出步骤时去掉内部字段（以下划线开头的流式拼接缓冲）。"""
    return [
        {key: value for key, value in step.items() if not key.startswith("_")}
        for step in steps
    ]


class JobManager:
    """任务表：负责创建、查询、取消与内存回收。"""

    def __init__(
        self,
        config: Config,
        on_job_finished: Any | None = None,
        on_job_checkpoint: Any | None = None,
        file_cache: FileCache | None = None,
        audio_cache: FileCache | None = None,
    ) -> None:
        self.config = config
        # 任务结束回调：由外部把最终回答写进会话存储
        self._on_job_finished = on_job_finished
        # 流式过程中回调：由外部把已生成内容 checkpoint 到会话存储
        self._on_job_checkpoint = on_job_checkpoint
        # 上传文件缓存：ocr 工具从这里取原始字节
        self.file_cache = file_cache if file_cache is not None else FileCache()
        # 生成音频缓存：text_to_speech 合成后放这里，客户端按 id 取回
        self.audio_cache = (
            audio_cache if audio_cache is not None else FileCache()
        )
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()

    def create(
        self,
        protocol: str,
        payload: dict[str, Any],
        headers: dict[str, str],
        upstream_base: str | None = None,
        conversation_id: int | None = None,
    ) -> Job:
        job = Job(
            protocol=protocol,
            payload=payload,
            headers=headers,
            upstream_base=(upstream_base or self.config.upstream_base),
            timeout=self.config.upstream_timeout,
            conversation_id=conversation_id,
        )
        with self._lock:
            self._prune_locked()
            self._jobs[job.id] = job
        thread = threading.Thread(
            target=self._run, args=(job,), daemon=True, name=f"job-{job.id[:8]}"
        )
        thread.start()
        return job

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def cancel(self, job_id: str) -> bool:
        job = self.get(job_id)
        if job is None:
            return False
        job.cancel()
        return True

    def find_active_by_conversation(self, conv_id: int) -> Job | None:
        """按会话找正在跑的任务：客户端重连后据此重新接上流（对齐官方 resume_stream）。"""
        with self._lock:
            for job in self._jobs.values():
                if job.conversation_id == conv_id and not job.finished:
                    return job
        return None

    def count(self) -> int:
        with self._lock:
            return len(self._jobs)

    def active_count(self) -> int:
        with self._lock:
            return sum(1 for job in self._jobs.values() if not job.finished)

    # ------------------------------------------------------------ 内部实现

    def _prune_locked(self) -> None:
        now = time.time()
        ttl = self.config.job_ttl_seconds
        expired = [
            jid
            for jid, job in self._jobs.items()
            if job.finished_at is not None and now - job.finished_at > ttl
        ]
        for jid in expired:
            self._jobs.pop(jid, None)
        # 仍然超量时，淘汰最早结束的任务
        while len(self._jobs) >= self.config.max_jobs:
            finished = [
                (job.finished_at or job.created_at, jid)
                for jid, job in self._jobs.items()
                if job.finished
            ]
            if not finished:
                break
            self._jobs.pop(min(finished)[1], None)

    def _run(self, job: Job) -> None:
        """在服务器侧跑完整的生成流程（含 ocr 这类函数工具轮次）。

        客户端只消费一条 SSE 流；工具执行、续请求都在这里完成，所以客户端
        断开/切网不会打断生成，最终回答照样落库。
        联网搜索/读链接由上游服务端执行，不在这里循环。
        """
        try:
            if not (urlsplit(job.upstream_base).hostname or ""):
                job.fail("上游地址无效")
                return
            # 工具轮次不设上限：一直续到模型不再调用工具、出错或被取消为止。
            round_index = 0
            while True:
                if job.canceled:
                    break
                reasoning_before = len(job.acc.reasoning)
                content_before = len(job.acc.content)
                job.acc.reset_round_tools()
                self._run_round(job, round_index)
                if (
                    job.canceled
                    or job.acc.error is not None
                    or job.error is not None
                ):
                    break
                calls = list(job.acc.round_tool_calls)
                if not calls:
                    break
                results: list[str] = []
                for call in calls:
                    if job.canceled:
                        break
                    results.append(self._execute_tool(job, call))
                if job.canceled:
                    break
                self._append_tool_round(
                    job,
                    calls,
                    results,
                    round_reasoning=job.acc.reasoning[reasoning_before:],
                    round_content=job.acc.content[content_before:],
                )
                round_index += 1
            # 服务端已经自己跑完整个流程：这一轮要收尾，不再是 pending。
            if (
                not job.canceled
                and job.acc.error is None
                and job.error is None
            ):
                job.acc.tool_use = False
        except Exception as exc:  # noqa: BLE001 - 统一转成任务错误状态
            if not job.canceled:
                job.fail(f"请求失败：{exc}")
        finally:
            if job._conn is not None:
                try:
                    job._conn.close()
                except OSError:
                    pass
                job._conn = None
            if self._on_job_finished is not None:
                try:
                    self._on_job_finished(job)
                except Exception as exc:  # noqa: BLE001 - 存储失败不能影响任务状态
                    print(f"存储回答失败：{exc}", flush=True)
            job.finish()
            # 每个任务一行打点，排查“回复变慢”全靠它
            print(job.summary(), flush=True)

    def _run_round(self, job: Job, round_index: int) -> None:
        """跑一轮上游请求，把事件写进 job.lines；中间轮的终止事件先扣下。"""
        parsed = urlsplit(job.upstream_base)
        host = parsed.hostname or ""
        if not host:
            job.fail("上游地址无效")
            return
        path = upstream_path(job.protocol, job.upstream_base)
        conn: http.client.HTTPConnection | None = None
        try:
            if parsed.scheme == "https":
                conn = http.client.HTTPSConnection(
                    host,
                    parsed.port,
                    timeout=job.timeout,
                    context=ssl.create_default_context(),
                )
            else:
                conn = http.client.HTTPConnection(
                    host, parsed.port, timeout=job.timeout
                )
            job._conn = conn
            body = json.dumps(job.payload, ensure_ascii=False).encode("utf-8")
            job.request_bytes = len(body)
            headers = {
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
                # 明确不要压缩：SSE 需要逐行即时读取，压缩会拖慢首字延迟
                "Accept-Encoding": "identity",
                "Content-Length": str(len(body)),
                **job.headers,
            }
            conn.request("POST", path, body=body, headers=headers)
            response = conn.getresponse()
            if response.status != 200:
                raw = response.read(_MAX_ERROR_BODY)
                job.set_upstream_result(
                    response.status, raw.decode("utf-8", "replace")
                )
                # 第一轮失败时请求还没进入 SSE，_handle_chat 会直接回 HTTP 错误；
                # 只有已经在流式下发后的续轮失败才需要给客户端补终止事件。
                if round_index > 0 and job.error:
                    self._emit_text(job, f"\n\n（上游请求失败：{job.error}）")
                    self._emit_terminal(job)
                return
            job.set_upstream_result(response.status)
            terminal_line: str | None = None
            for raw_line in response:
                if job.canceled:
                    break
                line = raw_line.decode("utf-8", "replace").rstrip("\r\n")
                job.acc.feed(line)
                if self._is_terminal(job, line):
                    terminal_line = line
                    self._maybe_checkpoint(job)
                    break
                job.append_line(line + "\n")
                self._maybe_checkpoint(job)
                if job.acc.error is not None:
                    break
            # 中间轮有工具调用：暂不把终止事件发给客户端，等工具执行完继续下一轮；
            # 最终轮/没有工具调用时才终止客户端这条流。
            if terminal_line is not None and not job.acc.round_tool_calls:
                job.append_line(terminal_line + "\n")
                self._maybe_checkpoint(job)
        except Exception as exc:  # noqa: BLE001
            if not job.canceled:
                job.fail(f"请求失败：{exc}")
                if round_index > 0:
                    self._emit_text(job, f"\n\n（连接中断：{exc}）")
                    self._emit_terminal(job)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except OSError:
                    pass
            job._conn = None

    @staticmethod
    def _is_terminal(job: Job, line: str) -> bool:
        if not line.startswith("data:"):
            return False
        data = line[5:].strip()
        if not data:
            return False
        if data == "[DONE]":
            return job.protocol != PROTOCOL_ANTHROPIC
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            return False
        if not isinstance(event, dict):
            return False
        if job.protocol == PROTOCOL_ANTHROPIC:
            return event.get("type") == "message_stop"
        return event.get("type") == "response.completed"

    def _emit_text(self, job: Job, text: str) -> None:
        """服务端自己追加一段文本（终止说明/连接错误），让客户端看得到。"""
        if job.protocol == PROTOCOL_ANTHROPIC:
            event: dict[str, Any] = {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": text},
            }
        else:
            event = {"type": "response.output_text.delta", "delta": text}
        line = "data: " + json.dumps(event, ensure_ascii=False)
        job.acc.feed(line)
        job.append_line(line + "\n")
        self._maybe_checkpoint(job)

    def _emit_terminal(self, job: Job) -> None:
        event: dict[str, Any] = (
            {"type": "message_stop"}
            if job.protocol == PROTOCOL_ANTHROPIC
            else {"type": "response.completed"}
        )
        line = "data: " + json.dumps(event, ensure_ascii=False)
        job.acc.feed(line)
        job.append_line(line + "\n")

    def _append_tool_round(
        self,
        job: Job,
        calls: list[dict[str, str]],
        results: list[str],
        *,
        round_reasoning: str,
        round_content: str,
    ) -> None:
        """把本轮 assistant 的工具调用和 tool 结果追加回请求体。

        注意：不改 `tool_choice`。官方规定 `tool_choice` 不能指向
        `deepseek_web_search` / `deepseek_read_url`（会 400），
        客户端怎么设就怎么透传。
        """
        reasoning = round_reasoning.strip()
        content = round_content.strip()
        if job.protocol == PROTOCOL_ANTHROPIC:
            messages = job.payload.get("messages")
            if not isinstance(messages, list):
                messages = []
                job.payload["messages"] = messages
            assistant: list[dict[str, Any]] = []
            if reasoning:
                assistant.append({"type": "thinking", "thinking": reasoning})
            if content:
                assistant.append({"type": "text", "text": content})
            for call in calls:
                assistant.append(
                    {
                        "type": "tool_use",
                        "id": call.get("id", ""),
                        "name": call.get("name", ""),
                        "input": _parse_arguments(call.get("arguments")),
                    }
                )
            messages.append({"role": "assistant", "content": assistant})
            messages.append(
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": call.get("id", ""),
                            "content": output,
                        }
                        for call, output in zip(calls, results)
                    ],
                }
            )
            return
        items = job.payload.get("input")
        if not isinstance(items, list):
            items = []
            job.payload["input"] = items
        if reasoning:
            items.append(
                {
                    "type": "reasoning",
                    "content": [{"type": "reasoning_text", "text": reasoning}],
                }
            )
        if content:
            items.append({"role": "assistant", "content": content})
        for call in calls:
            items.append(
                {
                    "type": "function_call",
                    "call_id": call.get("id", ""),
                    "name": call.get("name", ""),
                    "arguments": call.get("arguments") or "{}",
                }
            )
        for call, output in zip(calls, results):
            items.append(
                {
                    "type": "function_call_output",
                    "call_id": call.get("id", ""),
                    "output": output,
                }
            )

    # -------------------------------------------------- 服务端执行的函数工具

    def _execute_tool(self, job: Job, call: dict[str, str]) -> str:
        """在服务端执行函数工具，返回给模型的文本结果。"""
        name = call.get("name") or ""
        if name not in SERVER_FUNCTION_TOOL_NAMES:
            return json.dumps(
                {"error": f"未知工具：{name}"}, ensure_ascii=False
            )
        if name == "ocr":
            return self._execute_ocr(job, _parse_arguments(call.get("arguments")))
        if name == "text_to_speech":
            return self._execute_tts(job, _parse_arguments(call.get("arguments")))
        return json.dumps({"error": f"未知工具：{name}"}, ensure_ascii=False)

    def _execute_tts(self, job: Job, args: dict[str, Any]) -> str:
        """`text_to_speech` 工具：调上游合成音频，存进音频缓存并登记到任务。

        音频是二进制，没法当文本回填给模型：这里只把「生成成功 + 编号」
        告诉模型，真正的音频通过任务快照的 `audio` 字段下发，
        客户端再按 `/v1/audio/{id}` 取回字节。
        """
        text = str(args.get("text") or "").strip()
        if not text:
            return json.dumps(
                {"error": "text_to_speech 缺少 text"}, ensure_ascii=False
            )
        auth = job.headers.get("authorization") or ""
        if not auth:
            key = job.headers.get("x-api-key") or ""
            if key:
                auth = f"Bearer {key}"
        payload = {
            "text": text,
            "voice_id": str(args.get("voice_id") or "stella"),
            "format": "wav",
            "filter_markdown": True,
        }
        status, raw, content_type, headers = proxy_json_request(
            job.upstream_base,
            "/v1/tools/tts",
            payload,
            auth,
            self.config.tools_timeout,
            max_bytes=MAX_MEDIA_RESPONSE_BYTES,
            # 明确要音频：默认的 application/json 会让上游按 JSON 回错误体
            accept="audio/wav, audio/*, application/octet-stream",
        )
        if status != 200:
            detail = _tool_error_message(
                raw.decode("utf-8", "replace"), status
            )
            return json.dumps(
                {
                    "error": (
                        f"工具调用失败：{detail}。"
                        "不要重试同一段文字，请根据已有信息直接回答。"
                    )
                },
                ensure_ascii=False,
            )
        if not raw:
            return json.dumps({"error": "合成失败：没有返回音频"}, ensure_ascii=False)
        if "json" in (content_type or ""):
            # 上游用 200 回错误体的情况：当失败处理
            return json.dumps(
                {"error": _tool_error_message(raw.decode("utf-8", "replace"), 200)},
                ensure_ascii=False,
            )
        file_id = uuid.uuid4().hex[:16]
        name = f"speech-{file_id}.wav"
        self.audio_cache.put(
            CachedFile(
                file_id=file_id,
                filename=name,
                content_type=content_type or "audio/wav",
                data=raw,
                # 记下所属会话：删除会话时把孤儿音频一并清掉
                owner=job.conversation_id,
            )
        )
        job.audio_files.append(
            {
                "id": file_id,
                "name": name,
                "bytes": len(raw),
                "chars": headers.get("x-billed-chars") or "",
            }
        )
        return json.dumps(
            {
                "status": "ok",
                "audio_id": file_id,
                "message": "音频已生成，客户端会以音频卡片展示，用户可直接播放。",
            },
            ensure_ascii=False,
        )

    def _execute_ocr(self, job: Job, args: dict[str, Any]) -> str:
        """`ocr` 工具：按 file_id 从缓存取字节，调上游 /v1/tools/ocr。

        官方 `/v1/tools/ocr` 只接受 `file` + `purpose` 两个字段，传其他字段 400；
        multipart 里 `purpose` 放在 `file` 之前（与 `/files` 的要求一致）。
        """
        file_id = str(args.get("file_id") or "").strip()
        if not file_id:
            return json.dumps(
                {"error": "ocr 缺少 file_id"}, ensure_ascii=False
            )
        cached = self.file_cache.get(file_id)
        if cached is None:
            return json.dumps(
                {
                    "error": (
                        f"文件 {file_id} 不在服务端缓存里（可能已过期或服务重启过）。"
                        "请让用户重新上传该文件后再试，不要重试同一个 file_id。"
                    )
                },
                ensure_ascii=False,
            )
        purpose = str(args.get("purpose") or _DEFAULT_OCR_PURPOSE).strip()
        if purpose not in _OCR_PURPOSES:
            purpose = _DEFAULT_OCR_PURPOSE
        body, content_type = build_multipart(
            fields=[("purpose", purpose)],
            files=[
                (
                    "file",
                    cached.filename or "upload.bin",
                    cached.content_type or "application/octet-stream",
                    cached.data,
                )
            ],
        )
        auth = job.headers.get("authorization") or ""
        if not auth:
            key = job.headers.get("x-api-key") or ""
            if key:
                auth = f"Bearer {key}"
        status, raw, _content_type, _headers = proxy_multipart_request(
            job.upstream_base,
            "/v1/tools/ocr",
            body,
            content_type,
            auth,
            self.config.tools_timeout,
        )
        if status != 200:
            detail = _tool_error_message(raw.decode("utf-8", "replace"), status)
            return json.dumps(
                {
                    "error": (
                        f"工具调用失败：{detail}。"
                        "不要重试同一个文件，请根据已有信息直接回答。"
                    )
                },
                ensure_ascii=False,
            )
        try:
            data = json.loads(raw.decode("utf-8", "replace"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return json.dumps(
                {"error": "工具返回格式错误"}, ensure_ascii=False
            )
        return json.dumps(_ocr_text_result(data), ensure_ascii=False)

    def _maybe_checkpoint(self, job: Job) -> None:
        """按时间间隔把已生成内容写进数据库，服务重启后至少保留已输出部分。

        思考内容也要 checkpoint：模型思考阶段可能持续一两分钟，这时正文还是空的，
        如果只在有正文时才落库，服务一重启这段思考就整段丢了。
        """
        if self._on_job_checkpoint is None or job.conversation_id is None:
            return
        if not job.acc.content and not job.acc.reasoning:
            return
        now = time.time()
        interval = max(self.config.checkpoint_interval, 0.0)
        if job.last_checkpoint_at and now - job.last_checkpoint_at < interval:
            return
        job.last_checkpoint_at = now
        try:
            self._on_job_checkpoint(job)
        except Exception as exc:  # noqa: BLE001 - checkpoint 失败不影响主流程
            print(f"回答 checkpoint 失败：{exc}", flush=True)

    @staticmethod
    def protocol_of(value: Any) -> str:
        """校验协议名，非法值回退到 anthropic。"""
        return PROTOCOL_RESPONSES if value == PROTOCOL_RESPONSES else PROTOCOL_ANTHROPIC


def _ocr_text_result(data: Any) -> dict[str, Any]:
    """把 OCR 响应整理成回填给模型的文本结果。

    上游形状：`{id, page_count, pages:[{index,text,finish_reason}], usage}`。
    逐页文本拼成一个字符串，页与页之间空一行，便于模型区分页面。
    """
    if not isinstance(data, dict):
        return {"error": "工具返回格式错误"}
    pages = data.get("pages")
    if not isinstance(pages, list):
        return {"error": "OCR 没有返回 pages"}
    chunks: list[str] = []
    for page in pages:
        if not isinstance(page, dict):
            continue
        text = page.get("text")
        if isinstance(text, str) and text.strip():
            chunks.append(text.strip())
    text = "\n\n".join(chunks)
    result: dict[str, Any] = {
        "file_id": data.get("id") or "",
        "page_count": data.get("page_count") or len(pages),
        "text": text,
    }
    # 部分页面识别失败时把原因带回去，模型才知道内容可能不完整
    failures = [
        page.get("finish_reason")
        for page in pages
        if isinstance(page, dict)
        and page.get("finish_reason")
        and page.get("finish_reason") != "success"
    ]
    if failures:
        result["finish_reasons"] = failures
    if not text:
        result["error"] = "文件里没有识别出文字"
    return result
