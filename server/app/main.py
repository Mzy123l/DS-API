"""HTTP 入口：SSE 中转 + 任务快照查询，纯标准库实现（无需第三方依赖）。"""

from __future__ import annotations

import json
import hmac
import hashlib
import os
import re
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, cast
from urllib.request import urlopen
from urllib.parse import parse_qs, urlsplit

from . import __version__
from .config import Config, ConfigError, require_token_hash
from .filecache import CachedFile, FileCache
from .ttsjobs import TtsJobManager
from .jobs import Job, JobManager
from .multipart import parse_multipart, part_by_name
from .store import ChatStore
from .tools import (
    MAX_MEDIA_RESPONSE_BYTES,
    proxy_get_request,
    proxy_json_request,
    proxy_multipart_request,
    proxy_tool_request,
)

# 任务相关路径
_JOB_PATH = re.compile(r"^/v1/jobs/([0-9a-zA-Z]{8,64})/?$")
_JOB_CANCEL_PATH = re.compile(r"^/v1/jobs/([0-9a-zA-Z]{8,64})/cancel/?$")
_CHAT_PATHS = ("/v1/chat", "/v1/chat/")

# 会话 / 消息存储接口
_CONVERSATIONS_PATH = re.compile(r"^/v1/conversations/?$")
_CONVERSATION_ITEM = re.compile(r"^/v1/conversations/(\d+)/?$")
_CONVERSATION_MESSAGES = re.compile(r"^/v1/conversations/(\d+)/messages/?$")
_CONVERSATION_MESSAGES_BULK = re.compile(
    r"^/v1/conversations/(\d+)/messages/bulk/?$"
)
_CONVERSATION_TRUNCATE = re.compile(r"^/v1/conversations/(\d+)/truncate/?$")
_CONVERSATION_ACTIVE_JOB = re.compile(r"^/v1/conversations/(\d+)/active_job/?$")
_SEARCH_PATH = re.compile(r"^/v1/search/?$")

# 官方 Search / Fetch API（OpenAI 兼容的原始 JSON 接口），由中转代理
_TOOL_PATHS = ("/v1/tools/search", "/v1/tools/fetch")

# 官方 Files / OCR / ASR / TTS（2026-11 全家桶），由中转代理
_FILES_PATH = "/v1/files"

# 模型生成的音频：客户端按快照里的 id 取回 wav 字节
_AUDIO_PATH = re.compile(r"^/v1/audio/([0-9a-fA-F]{8,32})/?$")
# 上游的 Files 接口在根路径 `/files` 上（不是 /v1/files），中转对外用 /v1/files
_FILES_UPSTREAM_PATH = "/files"
_OCR_PATH = "/v1/tools/ocr"
_ASR_PATH = "/v1/tools/asr"
_TTS_PATH = "/v1/tools/tts"

# TTS 任务查询：GET /v1/tts-jobs/{id}，流式转发：GET /v1/tts-stream/{id}
_TTS_JOB_PATH = re.compile(r"^/v1/tts-jobs/([0-9a-zA-Z]{8,64})/?$")
_TTS_STREAM_PATH = re.compile(r"^/v1/tts-stream/([0-9a-zA-Z]{8,64})/?$")

# multipart 上行接口：请求体按原始字节转发，不能走 _read_json
# 注意 `/v1/files` 有独立的处理函数（还要写缓存），不放在这里
_MULTIPART_PATHS = (_OCR_PATH, _ASR_PATH)

# 二进制下行接口：响应体可能是音频，不能按 UTF-8 解码
_BINARY_PATHS = (_TTS_PATH,)

# /healthz 的 capabilities：客户端据此判断哪些代理能力可用
_CAPABILITIES = (
    "files",
    "ocr",
    "asr",
    "tts",
    "web_search",
    "read_url",
)

# 需要原样透传给上游的鉴权头
_PASSTHROUGH_HEADERS = ("x-api-key", "authorization", "anthropic-version")

# Files / OCR / ASR / TTS 额外透传的请求头（官方要求 anthropic-beta 等）
_EXTRA_PASSTHROUGH_HEADERS = ("anthropic-beta", "x-deepseek-beta")

# 客户端长时间无新数据时发送心跳注释行，避免中间链路断开
_HEARTBEAT_SECONDS = 10.0

# 健康检查路径：Docker 与进程内看门狗都会高频访问，不写进访问日志
_HEALTH_PATHS = ("/healthz", "/healthz/")


class HandshakeError(Exception):
    """TLS 握手失败/超时（扫描器与断线客户端很常见，不必打印堆栈）。"""


class RelayServer(ThreadingHTTPServer):
    """带任务表的 HTTP 服务器。

    TLS 只在“每个连接自己的处理线程”里握手（见 [RelayHandler.setup]），
    监听 socket 保持明文：早先的实现把监听 socket 直接 wrap 成 SSL，
    握手是在 accept 循环所在的线程里同步做的，一个连上却不发 ClientHello
    的客户端就能把整个服务卡死（2026-09-22 线上事故）。
    """

    daemon_threads = True
    allow_reuse_address = True
    # 内核排队连接上限：突发时不易被直接拒绝
    request_queue_size = 128

    def __init__(
        self,
        address: tuple[str, int],
        config: Config,
        store: ChatStore | None = None,
        tls_context: ssl.SSLContext | None = None,
    ) -> None:
        self.config = config
        self.tls_context = tls_context
        self.store = store if store is not None else ChatStore(config.db_path)
        # 上传文件缓存：`POST /v1/files` 成功时写入，供服务端执行的 ocr 工具读取
        self.file_cache = FileCache(
            max_bytes=config.file_cache_bytes,
            max_entries=config.file_cache_files,
        )
        # 生成音频缓存：`text_to_speech` 工具合成后写入，客户端按 id 取回 wav
        self.audio_cache = FileCache(
            max_bytes=config.file_cache_bytes,
            max_entries=config.file_cache_files,
        )
        # TTS 任务管理：合成与客户端连接解耦，开始后不可中断
        self.tts_manager = TtsJobManager(
            audio_cache=self.audio_cache,
        )
        self.manager = JobManager(
            config,
            on_job_finished=self._store_job_result,
            on_job_checkpoint=self._checkpoint_job_result,
            file_cache=self.file_cache,
            audio_cache=self.audio_cache,
        )
        super().__init__(address, RelayHandler)

    def handle_error(self, request: Any, client_address: Any) -> None:
        """连接级异常只记一行（握手失败、客户端断开都不该刷堆栈）。"""
        exc = sys.exc_info()[1]
        if isinstance(
            exc,
            (HandshakeError, ssl.SSLError, TimeoutError, ConnectionError),
        ):
            host = client_address[0] if client_address else "?"
            sys.stderr.write(f"{host} 连接异常：{type(exc).__name__}: {exc}\n")
            sys.stderr.flush()
            return
        super().handle_error(request, client_address)

    def _store_job_result(self, job: Job) -> None:
        """任务结束时落库；中间轮次也保留，并复用同一条 pending 助手消息。

        - 联网搜索的工具轮：更新同一条 pending 行，客户端断开也不丢；
        - 最终回答：把这条行标记为已收尾；
        - 只有客户端手动停止（canceled）或上游报错，才在有工具调用时也强制收尾。
        """
        conv_id = job.conversation_id
        if conv_id is None:
            job.result_ready = True
            return
        if not self.store.conversation_exists(conv_id):
            job.result_ready = True
            return
        if job.stored_message_id is None:
            job.stored_message_id = self.store.pending_assistant_id(conv_id)
        has_output = bool(job.acc.content or job.acc.reasoning)
        final = (
            job.canceled
            or bool(job.acc.error or job.error)
            or not job.acc.tool_use
        )
        if not has_output:
            if final and job.stored_message_id is not None:
                self.store.set_message_pending(job.stored_message_id, False)
            job.result_ready = True
            return
        updated = False
        audio_ids = [item["id"] for item in job.audio_files if "id" in item]
        if job.stored_message_id is not None:
            updated = self.store.update_message(
                job.stored_message_id,
                content=job.acc.content,
                reasoning=job.acc.reasoning,
                reasoning_ms=job.acc.reasoning_ms(),
                sources=job.acc.sources,
                audio=audio_ids or None,
                pending=not final,
            )
        if not updated:
            job.stored_message_id = self.store.append_message(
                conv_id,
                role="assistant",
                content=job.acc.content,
                reasoning=job.acc.reasoning,
                reasoning_ms=job.acc.reasoning_ms(),
                sources=job.acc.sources,
                audio=audio_ids,
                pending=not final,
            )
        self.store.touch_conversation(conv_id)
        job.result_ready = True

    def _checkpoint_job_result(self, job: Job) -> None:
        """流式过程中定期落库：客户端断开、服务重启后已输出部分仍留在会话里。

        联网搜索的中间轮次也 checkpoint；复用同一条 pending 助手消息，
        后续轮次继续更新它，不会把一轮回答拆成多条。
        """
        conv_id = job.conversation_id
        if conv_id is None or (not job.acc.content and not job.acc.reasoning):
            return
        if not self.store.conversation_exists(conv_id):
            return
        if job.stored_message_id is None:
            job.stored_message_id = self.store.pending_assistant_id(conv_id)
        if job.stored_message_id is None:
            job.stored_message_id = self.store.append_message(
                conv_id,
                role="assistant",
                content=job.acc.content,
                reasoning=job.acc.reasoning,
                reasoning_ms=job.acc.reasoning_ms(),
                sources=job.acc.sources,
                audio=[item["id"] for item in job.audio_files if "id" in item],
                pending=True,
                touch=False,
            )
            return
        self.store.update_message(
            job.stored_message_id,
            content=job.acc.content,
            reasoning=job.acc.reasoning,
            reasoning_ms=job.acc.reasoning_ms(),
            sources=job.acc.sources,
            audio=[item["id"] for item in job.audio_files if "id" in item],
            pending=True,
        )


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"ds-relay/{__version__}"
    sys_version = ""

    def setup(self) -> None:  # noqa: D102 - 覆盖 StreamRequestHandler.setup
        """建立连接：TLS 握手在本连接的线程里做，并且带超时。

        握手失败/超时直接丢掉这条连接，不会影响其它客户端；
        随后的请求读写也都有超时，半开连接最多占住一个线程一小会儿。
        """
        config = self._server.config
        context = self._server.tls_context
        if context is not None:
            self.request.settimeout(config.tls_handshake_timeout)
            try:
                self.request = context.wrap_socket(
                    self.request,
                    server_side=True,
                )
            except (ssl.SSLError, OSError) as exc:
                try:
                    self.request.close()
                except OSError:
                    pass
                raise HandshakeError(str(exc)) from exc
        self.timeout = config.request_timeout
        super().setup()

    # ------------------------------------------------------------------ 路由

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        path = urlsplit(self.path).path
        if not self._check_auth(path):
            return
        if path in ("/healthz", "/healthz/"):
            self._send_json(
                200,
                {
                    "status": "ok",
                    "version": __version__,
                    "upstream": self._server.config.upstream_base,
                    "jobs": self._server.manager.count(),
                    "active_jobs": self._server.manager.active_count(),
                    "store": self._server.store.stats(),
                    "tools": ["search", "fetch"],
                    # 已接通的代理能力：客户端据此降级（旧字段一个不少）
                    "capabilities": list(_CAPABILITIES),
                    "files": self._server.file_cache.stats(),
                },
            )
            return
        if path.rstrip("/") == _FILES_PATH:
            self._handle_files_list()
            return
        audio_match = _AUDIO_PATH.match(path)
        if audio_match:
            self._handle_audio(audio_match.group(1))
            return
        if _CONVERSATIONS_PATH.match(path):
            query = parse_qs(urlsplit(self.path).query)
            self._send_json(
                200,
                self._server.store.list_conversations(
                    limit=_int_param(query, "limit", 30, 1, 200),
                    before_updated_at=_int_param(query, "before_updated_at"),
                    before_id=_int_param(query, "before_id"),
                ),
            )
            return
        tts_job_match = _TTS_JOB_PATH.match(path)
        if tts_job_match:
            self._handle_tts_job(tts_job_match.group(1))
            return
        tts_stream_match = _TTS_STREAM_PATH.match(path)
        if tts_stream_match:
            self._handle_tts_stream(tts_stream_match.group(1))
            return
        match = _CONVERSATION_MESSAGES.match(path)
        if match:
            query = parse_qs(urlsplit(self.path).query)
            self._send_json(
                200,
                self._server.store.message_page(
                    int(match.group(1)),
                    limit=_int_param(query, "limit", 30, 1, 200),
                    before_id=_int_param(query, "before_id"),
                ),
            )
            return
        match = _CONVERSATION_ACTIVE_JOB.match(path)
        if match:
            job = self._server.manager.find_active_by_conversation(
                int(match.group(1))
            )
            if job is None:
                self._send_json(404, {"error": "job not found"})
            else:
                self._send_json(
                    200,
                    {
                        "job_id": job.id,
                        "status": job.status,
                        "protocol": job.protocol,
                    },
                )
            return
        if _SEARCH_PATH.match(path):
            query = parse_qs(urlsplit(self.path).query)
            self._send_json(
                200,
                {
                    "items": self._server.store.search_messages(
                        (query.get("q") or [""])[0],
                        limit=_int_param(query, "limit", 300, 1, 1000),
                    )
                },
            )
            return
        match = _JOB_PATH.match(path)
        if match:
            job = self._server.manager.get(match.group(1))
            if job is None:
                self._send_json(404, {"error": "job not found"})
            else:
                self._send_json(200, job.snapshot())
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        path = urlsplit(self.path).path
        if not self._check_auth(path):
            return
        if path in _CHAT_PATHS:
            self._handle_chat()
            return
        normalized = path.rstrip("/") or "/"
        if normalized == _FILES_PATH:
            self._handle_files_upload()
            return
        if normalized in _MULTIPART_PATHS:
            self._handle_multipart_proxy(normalized)
            return
        if normalized == _TTS_PATH:
            self._handle_tts()
            return
        tool_path = _tool_path(path)
        if tool_path is not None:
            self._handle_tools(tool_path)
            return
        if _CONVERSATIONS_PATH.match(path):
            body = self._read_json()
            if body is None:
                return
            conv_id = self._server.store.create_conversation(
                str(body.get("title") or "新对话"),
                str(body.get("model") or ""),
                _optional_int(body.get("updated_at")),
                str(body.get("system_prompt") or ""),
                bool(body.get("answer_bubble")),
            )
            self._send_json(200, {"id": conv_id})
            return
        match = _CONVERSATION_MESSAGES_BULK.match(path)
        if match:
            body = self._read_json()
            if body is None:
                return
            messages = body.get("messages")
            if not isinstance(messages, list):
                self._send_json(400, {"error": {"message": "messages 必须是数组"}})
                return
            ids = self._server.store.append_messages(
                int(match.group(1)),
                [m for m in messages if isinstance(m, dict)],
            )
            self._send_json(200, {"ids": ids})
            return
        match = _CONVERSATION_MESSAGES.match(path)
        if match:
            body = self._read_json()
            if body is None:
                return
            conv_id = int(match.group(1))
            message_id = self._server.store.append_message(
                conv_id,
                role=str(body.get("role") or "user"),
                content=str(body.get("content") or ""),
                reasoning=str(body.get("reasoning") or ""),
                reasoning_ms=int(body.get("reasoning_ms") or 0),
                sources=body.get("sources") or [],
                images=body.get("images") or [],
                files=body.get("files") or [],
                audio=body.get("audio") or [],
                ts=_optional_int(body.get("ts")),
            )
            self._send_json(200, {"id": message_id})
            return
        match = _CONVERSATION_TRUNCATE.match(path)
        if match:
            body = self._read_json()
            if body is None:
                return
            conv_id = int(match.group(1))
            before_id = _optional_int(body.get("before_id"))
            if before_id is not None:
                deleted, orphan_audio = self._server.store.truncate_messages_before(
                    conv_id, before_id
                )
            else:
                deleted, orphan_audio = self._server.store.truncate_messages(
                    conv_id, int(body.get("keep") or 0)
                )
            # 被截断消息引用的音频没了归属：从缓存清掉，不再占额度
            for audio_id in orphan_audio:
                self._server.audio_cache.discard(audio_id)
            self._send_json(200, {"deleted": deleted})
            return
        match = _JOB_CANCEL_PATH.match(path)
        if match:
            ok = self._server.manager.cancel(match.group(1))
            self._send_json(200 if ok else 404, {"canceled": ok})
            return
        self._send_json(404, {"error": "not found"})

    def do_PATCH(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        path = urlsplit(self.path).path
        if not self._check_auth(path):
            return
        match = _CONVERSATION_ITEM.match(path)
        if not match:
            self._send_json(404, {"error": "not found"})
            return
        body = self._read_json()
        if body is None:
            return
        title = body.get("title")
        system_prompt = body.get("system_prompt")
        answer_bubble = body.get("answer_bubble")
        if title is None and system_prompt is None and answer_bubble is None:
            self._send_json(
                400,
                {"error": {"message": "至少提供 title、system_prompt 或 answer_bubble"}},
            )
            return
        conv_id = int(match.group(1))
        updated = False
        if title is not None:
            if not isinstance(title, str) or not title.strip():
                self._send_json(400, {"error": {"message": "title 不能为空"}})
                return
            updated = self._server.store.rename_conversation(conv_id, title.strip())
        if system_prompt is not None:
            if not isinstance(system_prompt, str):
                self._send_json(
                    400, {"error": {"message": "system_prompt 必须是字符串"}}
                )
                return
            saved = self._server.store.set_system_prompt(conv_id, system_prompt)
            updated = saved or updated
        if answer_bubble is not None:
            if not isinstance(answer_bubble, bool):
                self._send_json(
                    400, {"error": {"message": "answer_bubble 必须是布尔值"}}
                )
                return
            saved = self._server.store.set_answer_bubble(conv_id, answer_bubble)
            updated = saved or updated
        self._send_json(200 if updated else 404, {"updated": updated})

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        path = urlsplit(self.path).path
        if not self._check_auth(path):
            return
        match = _CONVERSATION_ITEM.match(path)
        if not match:
            self._send_json(404, {"error": "not found"})
            return
        ok = self._server.store.delete_conversation(int(match.group(1)))
        # 会话没了，它生成的音频也该跟着走：不清会一直占着缓存
        self._server.audio_cache.discard_owner(int(match.group(1)))
        self._send_json(200 if ok else 404, {"deleted": ok})

    # -------------------------------------------------------------- 聊天中转

    def _handle_chat(self) -> None:
        server = self._server
        request = self._read_json()
        if request is None:
            return
        if not isinstance(request, dict):
            self._send_json(400, {"error": {"message": "请求体格式错误"}})
            return
        payload = request.get("payload")
        if not isinstance(payload, dict):
            self._send_json(400, {"error": {"message": "缺少 payload 字段"}})
            return
        upstream_base = self._upstream_override()
        if upstream_base is False:  # 显式传入但格式非法
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        headers = {
            name: value
            for name in _PASSTHROUGH_HEADERS
            if (value := self.headers.get(name))
        }
        job = server.manager.create(
            protocol=JobManager.protocol_of(request.get("protocol")),
            payload=payload,
            headers=headers,
            upstream_base=upstream_base or None,
            conversation_id=_optional_int(request.get("conversation_id")),
        )
        if not job.wait_for_start(time.time() + server.config.start_timeout):
            job.cancel()
            self._send_json(504, {"error": {"message": "上游响应超时"}})
            return
        if job.upstream_status != 200:
            # 原样转发上游状态码与错误体，客户端沿用既有错误处理
            self._send_text(
                job.upstream_status or 502,
                job.error_body or "",
                content_type="application/json; charset=utf-8",
            )
            return
        self._stream_job(job)

    def _upstream_override(self) -> str | bool | None:
        """读取 x-upstream-base 头；未提供返回 None，非法返回 False。"""
        raw = self.headers.get("x-upstream-base")
        if not raw:
            return None
        parsed = urlsplit(raw)
        if parsed.scheme in ("http", "https") and parsed.hostname:
            return raw.rstrip("/")
        return False

    # ------------------------------------------- Files / OCR / ASR / TTS 代理

    def _auth_header(self) -> str:
        """取上游鉴权头：优先 Authorization，其次把 x-api-key 转成 Bearer。"""
        auth = (self.headers.get("Authorization") or "").strip()
        if auth:
            return auth
        api_key = (self.headers.get("x-api-key") or "").strip()
        return f"Bearer {api_key}" if api_key else ""

    def _extra_upstream_headers(self) -> dict[str, str]:
        """Files / OCR / ASR / TTS 需要额外透传的请求头。

        官方文档要求引用文档时必须带 `anthropic-beta: files-api-2025-04-14`，
        这类 beta 头由客户端给、服务端原样转给上游。
        """
        return {
            name: value
            for name in _EXTRA_PASSTHROUGH_HEADERS
            if (value := self.headers.get(name))
        }

    def _proxy_target(self) -> str | bool | None:
        """计算上游地址：x-upstream-base 覆盖优先，非法返回 False。"""
        upstream = self._upstream_override()
        if upstream is False:
            return False
        return upstream or self._server.config.upstream_base

    def _handle_files_upload(self) -> None:
        """`POST /v1/files`：原样转发 multipart，成功时顺手缓存一份字节。

        为什么缓存：上游只回 `file_id`，模型之后调用 `ocr` 工具时只带这个 id，
        服务端拿不到原始字节就没法再调 `/v1/tools/ocr`（那个接口要 multipart 的 file）。
        """
        auth = self._auth_header()
        if not auth:
            self._send_json(401, _missing_key_error())
            return
        body = self._read_body()
        if body is None:
            return
        content_type = self.headers.get("Content-Type") or ""
        target = self._proxy_target()
        if target is False:
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        status, raw, response_type, headers = proxy_multipart_request(
            cast(str, target),
            _FILES_UPSTREAM_PATH,
            body,
            content_type,
            auth,
            self._server.config.tools_timeout,
            max_bytes=self._server.config.max_body_bytes,
            extra_headers=self._extra_upstream_headers(),
        )
        if status == 200:
            self._cache_uploaded_file(body, content_type, raw)
        self._send_bytes(status, raw, response_type, headers)

    def _cache_uploaded_file(
        self, body: bytes, content_type: str, response_body: bytes
    ) -> None:
        """把刚上传成功的文件字节缓存起来（键是上游返回的 id）。"""
        try:
            decoded = json.loads(response_body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return
        if not isinstance(decoded, dict):
            return
        file_id = decoded.get("id")
        if not isinstance(file_id, str) or not file_id:
            return
        parts = parse_multipart(body, content_type)
        if not parts:
            return
        part = part_by_name(parts, "file")
        if part is None or not part.data:
            return
        self._server.file_cache.put(
            CachedFile(
                file_id=file_id,
                filename=part.filename or str(decoded.get("filename") or "upload.bin"),
                content_type=part.content_type or "application/octet-stream",
                data=part.data,
            )
        )

    def _handle_audio(self, file_id: str) -> None:
        """`GET /v1/audio/{id}`：取回模型生成的音频（wav 字节）。

        音频不进消息、不进快照：快照里只有 id 与文件名，客户端按需取字节，
        这样历史长会话不会被几 MB 的音频撑大。
        """
        cached = self._server.audio_cache.get(file_id)
        if cached is None:
            self._send_json(
                404, {"error": {"message": "音频不存在或已过期，请重新生成"}}
            )
            return
        self._send_bytes(
            200,
            cached.data,
            cached.content_type or "audio/wav",
            {"Content-Disposition": f'inline; filename="{cached.filename}"'},
        )

    def _handle_files_list(self) -> None:
        auth = self._auth_header()
        if not auth:
            self._send_json(401, _missing_key_error())
            return
        target = self._proxy_target()
        if target is False:
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        status, raw, response_type, headers = proxy_get_request(
            cast(str, target),
            _FILES_UPSTREAM_PATH,
            auth,
            self._server.config.tools_timeout,
            max_bytes=self._server.config.max_body_bytes,
            extra_headers=self._extra_upstream_headers(),
        )
        self._send_bytes(status, raw, response_type, headers)

    def _handle_multipart_proxy(self, path: str) -> None:
        """`/v1/tools/ocr`、`/v1/tools/asr`：multipart 进、JSON 出。

        请求体与 Content-Type（含 boundary）原样透传，不做解析重编码。
        """
        auth = self._auth_header()
        if not auth:
            self._send_json(401, _missing_key_error())
            return
        body = self._read_body()
        if body is None:
            return
        content_type = self.headers.get("Content-Type") or ""
        if "multipart/form-data" not in content_type.lower():
            self._send_json(
                400,
                {"error": {"message": f"{path} 只接受 multipart/form-data"}},
            )
            return
        target = self._proxy_target()
        if target is False:
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        status, raw, response_type, headers = proxy_multipart_request(
            cast(str, target),
            path,
            body,
            content_type,
            auth,
            self._server.config.tools_timeout,
            max_bytes=self._server.config.max_body_bytes,
            extra_headers=self._extra_upstream_headers(),
        )
        self._send_bytes(status, raw, response_type, headers)

    def _handle_tts(self) -> None:
        """`POST /v1/tools/tts`：任务化合成——**开始后不可中断**。

        提交即返回任务号（202），合成在服务端后台线程跑完并存进音频缓存。
        客户端断开、取消、停止播放都不影响合成：
        - 「生成一半的语音残留」不再存在——要么完整成功进缓存，要么失败；
        - 客户端轮询 `GET /v1/tts-jobs/{id}`，done 后按 audio_id 取字节。

        兼容旧同步语义：请求带 `?wait=1` 时阻塞到合成完成，直接返回音频
        字节（老客户端/调试用）。同一段文字 + 音色的重复提交直接命中
        已有任务，不会向上游重复计费。
        """
        auth = self._auth_header()
        if not auth:
            self._send_json(401, _missing_key_error())
            return
        body = self._read_json()
        if body is None:
            return
        if not isinstance(body, dict):
            self._send_json(400, {"error": {"message": "请求体必须是 JSON 对象"}})
            return
        problem = _validate_tts_request(body)
        if problem is not None:
            self._send_json(400, {"error": {"message": problem}})
            return
        target = self._proxy_target()
        if target is False:
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        voice_id = str(body.get("voice_id") or "stella")
        text = str(body.get("text") or "")
        query = parse_qs(urlsplit(self.path).query)
        owner = _optional_int((query.get("conversation_id") or [None])[0])
        job, _created = self._server.tts_manager.submit(
            text=text,
            voice_id=voice_id,
            auth=auth,
            owner=owner,
            upstream_base=cast(str, target),
            timeout=self._server.config.tools_timeout,
            # wav：带 RIFF 头的容器，客户端落盘即可播放（裸 pcm 没有容器头，
            # 存成 .wav 播放器会报「格式不对」，那条路线已废弃）
            audio_format=str(body.get("format") or "wav"),
        )
        # wait=1：兼容同步语义（调试/老客户端），阻塞取全量音频
        if parse_qs(urlsplit(self.path).query).get("wait", ["0"])[0] == "1":
            deadline = time.time() + self._server.config.tools_timeout
            while time.time() < deadline:
                current = self._server.tts_manager.get(job.job_id)
                if current is None or current.status in ("done", "error"):
                    break
                time.sleep(0.2)
            current = self._server.tts_manager.get(job.job_id)
            if current is None or current.status != "done":
                error = current.error if current else "合成超时"
                self._send_json(
                    502, {"error": {"message": error or "合成超时"}}
                )
                return
            cached = self._server.audio_cache.get(current.audio_id or "")
            if cached is None:
                self._send_json(
                    502, {"error": {"message": "音频缓存已过期"}}
                )
                return
            self._send_bytes(
                200, cached.data, cached.content_type or "audio/wav"
            )
            return
        # 默认：任务化，立即返回任务号
        self._send_json(202, self._server.tts_manager.snapshot(job))

    def _handle_tts_job(self, job_id: str) -> None:
        """`GET /v1/tts-jobs/{id}`：查询合成任务状态。"""
        job = self._server.tts_manager.get(job_id)
        if job is None:
            self._send_json(
                404,
                {"error": {"message": "任务不存在或已过期，请重新生成"}},
            )
            return
        self._send_json(200, self._server.tts_manager.snapshot(job))

    def _handle_tts_stream(self, job_id: str) -> None:
        """`GET /v1/tts-stream/{id}`：**流式转发**合成音频。

        上游到一个块就转发一个块——客户端拿到首块即拥有带 RIFF 头的
        可播放 wav 前缀，合成完成即收完，没有轮询间隙。
        客户端中途断开**不影响**合成：任务线程照常读完上游并把完整
        音频落进缓存，断开的客户端下次点播直接命中缓存。
        任务已 done 时直接回全量；error/不存在回 JSON 错误。
        """
        job = self._server.tts_manager.get(job_id)
        if job is None:
            self._send_json(
                404,
                {"error": {"message": "任务不存在或已过期，请重新生成"}},
            )
            return
        if job.status == "error":
            self._send_json(
                502, {"error": {"message": job.error or "合成失败"}}
            )
            return
        try:
            self.send_response(200)
            self.send_header(
                "Content-Type", job.content_type or "audio/wav"
            )
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
        except OSError:
            return
        while True:
            try:
                # 等一块音频（合成线程 put；done/error 后收到 None）
                chunk = job.chunks.get(timeout=self._server.config.tools_timeout)
            except Exception:
                break  # 等待超时：放弃转发（合成继续，音频进缓存）
            if chunk is None:
                break  # 合成结束
            if not self._write_bytes(chunk):
                # 客户端断开：停止转发，合成线程不受影响
                return
        # 转发完成；如果任务此刻已 done，补齐尾部语义无需额外动作

    def _write_bytes(self, data: bytes) -> bool:
        try:
            self.wfile.write(data)
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    # ------------------------------------------------------------ 搜索 / 抓取

    def _handle_tools(self, path: str) -> None:
        """代理官方 Search / Fetch API：客户端只换 base，不用直连上游。

        - 客户端鉴权沿用 `x-relay-token`；DeepSeek API Key 走
          `Authorization: Bearer ...`（也接受 anthropic 风格的 `x-api-key`）；
        - 参数在本地先校验一遍，错误信息与官方格式保持一致；
        - 上游状态码与响应体原样返回，客户端可直接按官方文档处理错误。
        """
        body = self._read_json()
        if body is None:
            return
        if not isinstance(body, dict):
            self._send_json(400, {"error": {"message": "请求体必须是 JSON 对象"}})
            return
        problem = _validate_tool_request(path, body)
        if problem is not None:
            self._send_json(400, {"error": {"message": problem}})
            return
        auth = self._auth_header()
        if not auth:
            self._send_json(401, _missing_key_error())
            return
        upstream = self._upstream_override()
        if upstream is False:  # 显式传入但格式非法
            self._send_json(400, {"error": {"message": "上游地址无效"}})
            return
        status, response_body, content_type = proxy_tool_request(
            upstream or self._server.config.upstream_base,
            path,
            body,
            auth,
            self._server.config.tools_timeout,
        )
        self._send_text(status, response_body, content_type=content_type)

    def _stream_job(self, job: Job) -> None:
        """把任务的流式行按顺序写回客户端；客户端断开不影响任务继续执行。"""
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
        except OSError:
            return
        header = json.dumps(
            {"type": "__job", "job_id": job.id, "protocol": job.protocol},
            ensure_ascii=False,
        )
        if not self._write(f"data: {header}\n\n"):
            return
        index = 0
        while True:
            lines, done = job.tail(index, _HEARTBEAT_SECONDS)
            if lines:
                # 一次写出整批事件：减少小包与 flush 次数，客户端拼帧更省事
                payload = "".join(
                    line if line.endswith("\n") else line + "\n"
                    for line in lines
                )
                if not self._write(payload):
                    return
            index += len(lines)
            if done:
                return
            if not lines and not self._write(": ping\n\n"):
                return

    # -------------------------------------------------------------- 写响应

    def _check_auth(self, path: str) -> bool:
        """校验访问口令。

        服务端只保存口令的 SHA-256：把客户端传来的口令现算哈希再比对，
        即使服务器文件被看到也拿不到可用于认证的明文。
        `/healthz` 不校验，方便容器健康检查与外部探活。

        口令哈希是必填项（build_server 在启动时就拒绝空口令），这里再做一次
        兜底：万一有代码绕过启动检查，也只会拒绝请求，不会放行。

        也接受查询参数 `?token=...`：媒体播放器的 HTTP 栈带不了自定义
        请求头，流式音频地址（/v1/tts-stream）只能走 URL 鉴权。
        """
        if path in ("/healthz", "/healthz/"):
            return True
        expected = self._server.config.relay_token_hash
        if not expected:
            self._drain_body()
            self._send_json(
                503,
                {"error": {"message": "服务器未配置访问口令，已拒绝请求"}},
            )
            return False
        provided = self.headers.get("x-relay-token") or ""
        if not provided:
            # 播放器流式播放只能通过 URL 传口令
            provided = (parse_qs(urlsplit(self.path).query).get("token") or [
                ""
            ])[0]
        if provided:
            digest = hashlib.sha256(provided.encode("utf-8")).hexdigest()
            if hmac.compare_digest(digest, expected):
                return True
        # 提前拒绝时必须把请求体读掉：HTTP/1.1 是长连接，未消费的字节
        # 会被当成下一条请求的起始行（表现为 "Bad request syntax"）。
        self._drain_body()
        self._send_json(401, {"error": {"message": "服务器口令不正确"}})
        return False

    def _drain_body(self) -> None:
        """把当前请求体读掉并丢弃，保证长连接上的下一条请求从干净状态开始。"""
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            length = 0
        if length <= 0:
            return
        # 上限内才读：超大请求体留给 413 流程，不做无意义的内存拷贝
        remaining = min(length, self._server.config.max_body_bytes + 1)
        try:
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    break
                remaining -= len(chunk)
        except OSError:
            # 客户端已断开：这条连接本来就要丢弃
            self.close_connection = True

    def _read_json(self) -> Any | None:
        """读取并解析 JSON 请求体；失败时已回写错误响应并返回 None。"""
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self._send_json(400, {"error": {"message": "请求体为空"}})
            return None
        if length > self._server.config.max_body_bytes:
            self._send_json(413, {"error": {"message": "请求体过大"}})
            return None
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self._send_json(400, {"error": {"message": "请求体不是合法 JSON"}})
            return None

    def _read_body(self) -> bytes | None:
        """读取原始请求体（multipart / 二进制用）；失败时已回写错误并返回 None。

        与 `_read_json` 的区别：这里**不做 JSON 解析**，字节原样返回，
        长度校验与 413 语义保持一致。
        """
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self._send_json(400, {"error": {"message": "请求体为空"}})
            return None
        if length > self._server.config.max_body_bytes:
            self._send_json(413, {"error": {"message": "请求体过大"}})
            return None
        remaining = length
        chunks: list[bytes] = []
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 1024 * 1024))
            if not chunk:
                self._send_json(400, {"error": {"message": "请求体不完整"}})
                return None
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _write(self, text: str) -> bool:
        try:
            self.wfile.write(text.encode("utf-8"))
            self.wfile.flush()
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False)
        self._send_text(status, body, content_type="application/json; charset=utf-8")

    def _send_text(self, status: int, body: str, content_type: str) -> None:
        self._send_bytes(status, body.encode("utf-8"), content_type)

    def _send_bytes(
        self,
        status: int,
        data: bytes,
        content_type: str,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        """按原始字节写响应（音频/文件列表都走这里）。

        额外头来自上游（`X-Billed-Chars` / `Content-Disposition` 等），
        写出去之前先剔掉换行，避免头部注入。
        """
        try:
            self.send_response(status)
            self.send_header("Content-Type", _header_value(content_type))
            self.send_header("Content-Length", str(len(data)))
            for name, value in (extra_headers or {}).items():
                self.send_header(_header_value(name), _header_value(value))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    @property
    def _server(self) -> RelayServer:
        return cast(RelayServer, self.server)

    def log_message(self, format: str, *args: Any) -> None:
        # 健康检查（Docker + 看门狗）每 30 秒一次，写进日志只会把日志刷满。
        # 判断前先剥掉查询串：`?token=...` 不能改变命中结果。
        if urlsplit(self.path).path in _HEALTH_PATHS:
            return
        # 访问日志只记 path，**永远不记查询串**：媒体播放器只能用
        # `?token=<明文口令>` 鉴权（见 _check_auth），而默认日志格式里的
        # requestline 带完整查询串，会把口令原样写进 stderr / docker logs。
        sys.stderr.write(
            f"{self.log_date_time_string()} {_redact_query(format % args)}\n"
        )


def _header_value(value: str) -> str:
    """去掉头部值里的换行，避免把上游内容写进响应头造成头部注入。"""
    return str(value).replace("\r", " ").replace("\n", " ")


def _redact_query(line: str) -> str:
    """把日志行里出现的 `?查询串` 一律截掉，只留 path。

    默认访问日志格式是 requestline（`"GET /v1/tts-stream/xxx?token=... HTTP/1.1"`），
    查询串会原样带进来；这里统一剥掉，保证口令之类的东西不落日志。
    末尾的 HTTP 版本不受影响：`\\S*` 遇到空格即止。
    """
    return re.sub(r"\?\S*", "", line)


def _missing_key_error() -> dict[str, Any]:
    """缺少 DeepSeek API Key 时的统一错误体（与 Search / Fetch 保持一致）。"""
    return {
        "error": {
            "message": "缺少 API Key：请带 Authorization: Bearer ... 或 x-api-key"
        }
    }


# TTS 允许的音色（官方文档：stella 女声 / tide 男声）
_TTS_VOICES = frozenset({"stella", "tide"})
# TTS 允许的输出格式（裸 pcm 已废弃：没有容器头，客户端存成 .wav 无法播放）
_TTS_FORMATS = frozenset({"wav"})
# 单次 TTS 计费字符上限（官方限制）
_TTS_MAX_CHARS = 10000


def _validate_tts_request(body: dict[str, Any]) -> str | None:
    """按官方 TTS 规则做本地校验，返回错误文案或 None。

    只拦明显不合法的请求（空文本、超长、未知音色/格式），
    其余字段原样透传，避免与上游规则不一致。
    """
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        return "text 不能为空"
    if len(text) > _TTS_MAX_CHARS:
        return f"text 不能超过 {_TTS_MAX_CHARS} 个字符"
    voice = body.get("voice_id")
    if voice is not None and voice not in _TTS_VOICES:
        return "voice_id 只能是 stella 或 tide"
    fmt = body.get("format")
    if fmt is not None and fmt not in _TTS_FORMATS:
        return "format 只能是 wav"
    return None


def _int_param(
    query: dict[str, list[str]],
    name: str,
    default: int | None = None,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int | None:
    """从查询串取整数参数（非法值回退默认值，并按上下限收敛）。"""
    raw = (query.get(name) or [None])[0]
    try:
        value: int | None = int(raw) if raw is not None else default
    except (TypeError, ValueError):
        value = default
    if value is None:
        return None
    if minimum is not None:
        value = max(minimum, value)
    if maximum is not None:
        value = min(maximum, value)
    return value


def _optional_int(value: Any) -> int | None:
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _tool_path(path: str) -> str | None:
    """把 /v1/tools/search/ 之类的路径归一化，非工具接口返回 None。"""
    normalized = path.rstrip("/") or "/"
    return normalized if normalized in _TOOL_PATHS else None


def _validate_tool_request(path: str, body: dict[str, Any]) -> str | None:
    """按官方 Search / Fetch 的参数规则做本地校验，返回错误文案或 None。"""
    if path.endswith("/search"):
        query = body.get("query")
        if not isinstance(query, str) or not query.strip():
            return "query 不能为空"
        if len(query) > 128:
            return "query 不能超过 128 个字符"
        count = body.get("count")
        if count is not None and (
            isinstance(count, bool) or not isinstance(count, int)
        ):
            return "count 必须是整数"
        return None

    url = body.get("url")
    if not isinstance(url, str) or not url.strip():
        return "url 不能为空"
    if len(url) > 8192:
        return "url 不能超过 8192 个字符"
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return "url 必须是含 host 的 HTTP/HTTPS 地址"
    if parsed.username or parsed.password:
        return "url 不能携带用户名或密码"
    return None


class HealthWatchdog(threading.Thread):
    """进程内看门狗：健康检查连续失败就退出进程，交给 Docker 拉起来。

    accept 循环万一再被别的原因卡住（内核、网络、未知 bug），进程自己不会退出，
    Docker 的 unhealthy 也不会重启容器。这里兜一层底：连续 N 次探测失败就
    `os._exit(1)`，由 `--restart unless-stopped` 把服务重新拉起来。
    """

    def __init__(
        self,
        port: int,
        interval: float,
        failures_allowed: int,
        use_tls: bool,
        exit_process: Any | None = None,
    ) -> None:
        super().__init__(daemon=True, name="health-watchdog")
        self.port = port
        self.interval = max(interval, 1.0)
        self.failures_allowed = max(failures_allowed, 1)
        self.use_tls = use_tls
        self._exit = exit_process or os._exit

    def probe(self) -> bool:
        """本机自检一次：能拿到 /healthz 200 就算健康。"""
        scheme = "https" if self.use_tls else "http"
        context: ssl.SSLContext | None = None
        if self.use_tls:
            # 自检走回环地址，证书是自签的，不校验链
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        try:
            with urlopen(  # noqa: S310 - 固定本机地址
                f"{scheme}://127.0.0.1:{self.port}/healthz",
                timeout=5,
                context=context,
            ) as res:
                return res.status == 200
        except Exception:  # noqa: BLE001 - 探测失败一律按不健康处理
            return False

    def run(self) -> None:
        failures = 0
        while True:
            time.sleep(self.interval)
            if self.probe():
                failures = 0
                continue
            failures += 1
            print(
                f"看门狗：健康检查失败 {failures}/{self.failures_allowed}",
                flush=True,
            )
            if failures >= self.failures_allowed:
                print("看门狗：连续失败，退出进程等 Docker 重启", flush=True)
                self._exit(1)
                return


def build_server(
    config: Config,
    tls_context: ssl.SSLContext | None = None,
) -> tuple[RelayServer, ssl.SSLContext | None]:
    """按配置组装服务器。

    TLS 上下文只交给连接处理器，**不包监听 socket**：
    否则握手会在 accept 循环里同步进行，一个不配合的客户端就能卡死整个服务。

    口令哈希缺失时直接抛 ConfigError：宁可起不来，也不能起一个对公网
    完全敞开的中转（服务默认监听 0.0.0.0）。
    """
    require_token_hash(config)
    context = tls_context
    if context is None and config.tls_cert and config.tls_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(config.tls_cert, config.tls_key)
    server = RelayServer(
        (config.host, config.port),
        config,
        tls_context=context,
    )
    return server, context


def main() -> None:
    config = Config.from_env()
    try:
        server, tls_context = build_server(config)
    except ConfigError as exc:
        # 配置错误让进程直接失败：Docker 会显示退出码，而不是“healthy 但全开”
        print(f"ds-relay 启动失败：{exc}", file=sys.stderr, flush=True)
        raise SystemExit(1) from exc
    scheme = "https" if tls_context is not None else "http"
    print(
        f"ds-relay {__version__} {scheme}://{config.host}:{config.port} "
        f"(upstream={config.upstream_base})",
        flush=True,
    )
    HealthWatchdog(
        port=config.port,
        interval=config.watchdog_interval,
        failures_allowed=config.watchdog_failures,
        use_tls=tls_context is not None,
    ).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
