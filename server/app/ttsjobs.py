"""TTS 生成任务：合成与客户端连接解耦，开始后不可中断 + 可流式转发。

为什么做成任务而不是同步代理：

- 官方 TTS 是流式返回，合成一段长文本要几秒到几十秒；同步代理时
  客户端断开（切后台、取消）会让这次合成的音频**丢失**——上游照常
  计费，却没人拿到结果。
- 任务化之后：提交即返回任务号，合成在服务端后台线程跑完并存进
  音频缓存。客户端断开、取消、退出 App 都**不影响**合成——
  「只要开始生成了，就不允许被中断」。

客户端有两种取结果的方式：

1. `GET /v1/tts-jobs/{id}` 轮询到 done → `GET /v1/audio/{audio_id}` 取全量；
2. **`GET /v1/tts-stream/{id}` 流式挂接**：上游到一个块就转发一个块，
   字节一路透传到客户端——无轮询间隙，合成完成即收完。

合成结果按「文本 + 音色」哈希记账：同一段文字重复提交会直接命中
已有任务（done），不会向上游重复计费。
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import queue
import ssl
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

from .filecache import CachedFile

# 任务完成后保留时长（秒）：客户端断线后有充足时间回来取结果
DEFAULT_JOB_TTL = 3600.0

# 「访问即续期」的总时长上限（相对 ttl 的倍数）：查询只能在这个上限内
# 延后回收，避免反复轮询把任务永久留在内存里（见 TtsJobManager.get）。
JOB_RETENTION_MAX_FACTOR = 4.0

# 上游音频响应读取上限（30 分钟音频的最大可能体积，防异常占满内存）
MAX_TTS_AUDIO_BYTES = 384 * 1024 * 1024


@dataclass
class TtsJob:
    """一次 TTS 合成任务的状态。"""

    job_id: str
    text: str
    voice_id: str
    # 音频容器：wav（带 RIFF 头的容器，客户端落盘即可播放）
    audio_format: str = "wav"
    # audio_cache 里的文件 id（合成完成后写入）
    audio_id: str | None = None
    status: str = "pending"  # pending / running / done / error
    error: str | None = None
    created_at: float = field(default_factory=time.time)
    finished_at: float | None = None
    billed_chars: str | None = None
    # 流式转发：合成线程往里放块，转发端从中取（done/error 后关闭）
    chunks: "queue.Queue[bytes | None]" = None  # type: ignore[assignment]
    # 合成线程持有的上游连接：客户端流式断开时不关闭（合成不可中断）
    content_type: str = "audio/wav"


class TtsJobManager:
    """TTS 任务表：提交、后台合成、轮询 / 流式取结果与回收。

    合成线程由本类驱动：直接调上游（不经回调），把字节块同时写给
    「音频缓存组装器」和「流式订阅队列」——转发端拿到块就发，缓存
    攒完就落盘，两条路互不阻塞。
    """

    def __init__(
        self,
        audio_cache: Any,
        ttl: float = DEFAULT_JOB_TTL,
    ) -> None:
        self.audio_cache = audio_cache
        self.ttl = ttl
        self._jobs: dict[str, TtsJob] = {}
        self._lock = threading.Lock()
        self._by_text: dict[str, str] = {}

    @classmethod
    def _digest(cls, voice_id: str, audio_format: str, text: str) -> str:
        """去重键：音色 + 音频容器 + 文本。

        写入（submit）与清理（_prune_locked）必须用同一个键，否则残留映射
        永远删不掉。抽成一个方法，避免两处再次漂移。
        """
        return hashlib.sha256(
            f"{voice_id}|{audio_format}|{text}".encode("utf-8")
        ).hexdigest()[:24]

    # ------------------------------------------------------------ 提交/查询

    def submit(
        self,
        text: str,
        voice_id: str,
        auth: str,
        owner: int | None,
        upstream_base: str,
        timeout: float,
        audio_format: str = "wav",
    ) -> tuple[TtsJob, bool]:
        """提交一个合成任务，返回（任务, 是否新建）。

        同一段文字 + 同一音色已有任务时：
        - 已完成 → 直接返回原任务（客户端按 audio_id 取结果，零计费）
        - 进行中 → 返回原任务（客户端可轮询或挂流，不会第二次计费）

        [audio_format] 默认 `wav`（带 RIFF 头的容器，客户端可直接落盘播放）。
        裸 `pcm` 没有容器头，客户端存成 .wav 播放器会报「格式不对」，
        那条路线已废弃。
        """
        digest = self._digest(voice_id, audio_format, text)
        with self._lock:
            self._prune_locked()
            existing_id = self._by_text.get(digest)
            if existing_id is not None:
                existing = self._jobs.get(existing_id)
                if existing is not None:
                    return existing, False
            job = TtsJob(
                job_id=uuid.uuid4().hex,
                text=text,
                voice_id=voice_id,
                audio_format=audio_format,
                chunks=queue.Queue(),
            )
            self._jobs[job.job_id] = job
            self._by_text[digest] = job.job_id
            if os.getenv("TTS_DEBUG"):
                print(
                    f"TTS_DEBUG new-job {job.job_id[:8]} fmt={audio_format} "
                    f"len(text)={len(text)}",
                    flush=True,
                )
        thread = threading.Thread(
            target=self._run,
            args=(job, auth, owner, upstream_base, timeout),
            daemon=True,
            name=f"tts-{job.job_id[:8]}",
        )
        thread.start()
        return job, True

    def get(self, job_id: str) -> TtsJob | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            if job.finished_at is not None:
                # 访问即续期：客户端还在取就别过期。
                # 但续期必须封顶：轮询（GET /v1/tts-jobs、/v1/tts-stream）本身
                # 就会调到本方法，无上限续期会让任务永不回收、内存只增不减。
                # 上限是「任务创建后 ttl * JOB_RETENTION_MAX_FACTOR 秒」，
                # 过了就不再续期，交给 _prune_locked 正常回收。
                deadline = (
                    job.created_at + self.ttl * JOB_RETENTION_MAX_FACTOR
                )
                if time.time() < deadline:
                    job.finished_at = time.time()
            return job

    def snapshot(self, job: TtsJob) -> dict[str, Any]:
        with self._lock:
            return {
                "job_id": job.job_id,
                "status": job.status,
                "audio_id": job.audio_id,
                "error": job.error,
                "billed_chars": job.billed_chars,
            }

    # ------------------------------------------------------------ 内部实现

    def _run(
        self,
        job: TtsJob,
        auth: str,
        owner: int | None,
        upstream_base: str,
        timeout: float,
    ) -> None:
        """后台合成：与客户端连接完全无关，跑完为止。

        字节块双路分发：
        - 写入组装缓冲（全部收完后作为完整文件落进音频缓存）；
        - 推进 chunks 队列（流式转发端即时取走）。
        客户端断开流式连接**不影响**本线程——上游响应照常读完。
        """
        with self._lock:
            job.status = "running"
        parsed = urlsplit(upstream_base)
        host = parsed.hostname or ""
        connection: http.client.HTTPConnection | None = None
        audio_id: str | None = None
        assembled = bytearray()
        try:
            payload = json.dumps(
                {
                    "text": job.text,
                    "voice_id": job.voice_id,
                    "format": job.audio_format,
                    "filter_markdown": True,
                }
            ).encode("utf-8")
            headers = {
                "Content-Type": "application/json",
                "Accept": "audio/*, application/octet-stream",
                "Authorization": auth,
                "Content-Length": str(len(payload)),
            }
            if parsed.scheme == "https":
                connection = http.client.HTTPSConnection(
                    host,
                    parsed.port,
                    timeout=timeout,
                    context=ssl.create_default_context(),
                )
            else:
                connection = http.client.HTTPConnection(
                    host, parsed.port, timeout=timeout
                )
            connection.request(
                "POST", self._target_path(parsed.path), body=payload, headers=headers
            )
            response = connection.getresponse()
            content_type = (
                response.getheader("Content-Type")
                or ("audio/wav" if job.audio_format == "wav" else "application/octet-stream")
            )
            if response.status != 200:
                raw = response.read(1024 * 1024)
                self._fail(job, f"HTTP {response.status}: {_error_text(raw)}")
                return
            if "json" in content_type:
                raw = response.read(1024 * 1024)
                self._fail(job, _error_text(raw))
                return

            # 流式读取上游：按小块分发，保证客户端音频缓冲不断流。
            # 块太大（如 64KB ≈ 1.36s 音频）会让客户端两次到数据之间缓冲取空，
            # 造成 underrun 爆音；太小则转发循环过密。8KB ≈ 170ms 较平衡。
            while True:
                chunk = (
                    response.read1(8192)
                    if hasattr(response, "read1")
                    else response.read(8192)
                )
                if not chunk:
                    break
                assembled.extend(chunk)
                job.chunks.put(chunk)

            if not assembled:
                self._fail(job, "合成失败：没有返回音频")
                return
            # 诊断：把最近一次音频落盘，便于在服务器上分析波形/采样参数
            if os.getenv("TTS_DEBUG"):
                head = bytes(assembled[:48]).hex()
                print(
                    f"TTS_DEBUG done fmt={job.audio_format} type={content_type} "
                    f"len={len(assembled)} head={head}",
                    flush=True,
                )
                try:
                    dump = f"/tmp/tts-{job.job_id[:8]}.{job.audio_format}"
                    with open(dump, "wb") as fh:
                        fh.write(bytes(assembled))
                    print(f"TTS_DEBUG dump={dump}", flush=True)
                except OSError:
                    pass
            audio_id = uuid.uuid4().hex[:16]
            self.audio_cache.put(
                CachedFile(
                    file_id=audio_id,
                    filename=f"speech-{audio_id}.wav",
                    content_type=content_type,
                    data=bytes(assembled),
                    owner=owner,
                )
            )
            with self._lock:
                job.audio_id = audio_id
                job.status = "done"
                job.finished_at = time.time()
                job.billed_chars = response.getheader("X-Billed-Chars")
                job.content_type = content_type
        except Exception as exc:  # noqa: BLE001 - 后台线程不能崩
            self._fail(job, f"合成失败：{exc}")
            return
        finally:
            # 流式端收到 None 才知道结束；无论成败都要通知
            job.chunks.put(None)
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass

    def _target_path(self, base_path: str) -> str:
        """上游 TTS 路径（base 自带 /anthropic 等前缀时去掉）。"""
        prefix = base_path.rstrip("/")
        for suffix in ("/anthropic/v1", "/anthropic", "/v1"):
            if prefix.endswith(suffix):
                prefix = prefix[: -len(suffix)]
                break
        return f"{prefix}/v1/tools/tts"

    def _fail(self, job: TtsJob, message: str) -> None:
        with self._lock:
            job.status = "error"
            job.error = message
            job.finished_at = time.time()
        print(f"TTS 任务失败 {job.job_id[:8]}：{message}", flush=True)

    def _prune_locked(self) -> None:
        """淘汰过期任务（结果已进音频缓存的，任务记录本身没价值）。"""
        now = time.time()
        expired = [
            jid
            for jid, job in self._jobs.items()
            if job.finished_at is not None and now - job.finished_at > self.ttl
        ]
        for jid in expired:
            job = self._jobs.pop(jid, None)
            if job is None:
                continue
            digest = self._digest(job.voice_id, job.audio_format, job.text)
            if self._by_text.get(digest) == jid:
                self._by_text.pop(digest, None)


def _error_text(raw: bytes) -> str:
    """从上游错误体里取 message。"""
    try:
        decoded = json.loads(raw.decode("utf-8", "replace"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return "上游返回错误"
    if isinstance(decoded, dict):
        error = decoded.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message:
                return message
        if isinstance(error, str) and error:
            return error
        if isinstance(decoded.get("message"), str):
            return decoded["message"]
    return "上游返回错误"
