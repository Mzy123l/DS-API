"""测试用假上游：按预设脚本返回 SSE，可模拟慢速流、长连接与错误状态。

2026-11 全家桶之后还要覆盖几类新接口，所以这里额外支持：

- multipart 记录：`record()` 保留**原始字节**与 `Content-Type`（含 boundary），
  便于断言「中转是否原样转发、有没有重新编码」；
- 二进制下行：`/v1/tools/tts` 直接回音频字节；
- `/files`（POST 上传 / GET 列表）、`/v1/tools/{ocr,asr}`。
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Sequence
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

# 假音频：wav 头 + 一段可辨认的字节，用于验证「二进制透传没被 UTF-8 破坏」
FAKE_WAV = (
    b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
    b"\x44\xac\x00\x00\x88\x58\x01\x00\x02\x00\x10\x00data\x00\x00\x00\x00"
    b"\xff\xfe\x00\x80\xff\x7f"  # 非 UTF-8 字节：按文本解码必然损坏
)


class FakeUpstream:
    """一个可启动/停止的本地 HTTP 上游，并记录收到的请求。"""

    def __init__(
        self,
        status: int = 200,
        lines: Sequence[str] | None = None,
        scripts: Sequence[Sequence[str]] | None = None,
        error_message: str = "boom",
        delay: float = 0.0,
        hold_seconds: float = 0.0,
        tools_status: int | None = None,
        search_results: list[dict[str, Any]] | None = None,
        fetch_page: dict[str, Any] | None = None,
        file_record: dict[str, Any] | None = None,
        ocr_result: dict[str, Any] | None = None,
        asr_result: dict[str, Any] | None = None,
        tts_audio: bytes | None = None,
        tts_content_type: str = "audio/wav",
        tts_billed_chars: str | None = "42",
        files_list: dict[str, Any] | None = None,
    ) -> None:
        self.status = status
        self.lines = list(lines or [])
        # 多次 /v1/chat 依次回放不同脚本（联网搜索多轮请求用；用完后重复最后一段）
        self.scripts = (
            [list(script) for script in scripts] if scripts is not None else None
        )
        self._script_index = 0
        self._script_lock = threading.Lock()
        self.error_message = error_message
        self.delay = delay
        self.hold_seconds = hold_seconds
        # 搜索/抓取接口的状态码（不单独指定时跟随 status）
        self.tools_status = status if tools_status is None else tools_status
        self.search_results = (
            list(search_results)
            if search_results is not None
            else [
                {
                    "rerank_score": 2.4,
                    "title": "示例站点",
                    "url": "https://example.com/a",
                    "snippet": "短摘要",
                    "summary": "长摘要",
                    "content": "",
                    "site_name": "Example",
                    "site_icon": None,
                    "date": None,
                    "authority": 3,
                },
                {
                    "rerank_score": 1.2,
                    "title": "第二站",
                    "url": "https://example.com/b",
                    "snippet": "短摘要 2",
                    "summary": "长摘要 2",
                    "content": "",
                    "site_name": None,
                    "site_icon": None,
                    "date": None,
                    "authority": 2,
                },
            ]
        )
        self.fetch_page = (
            dict(fetch_page)
            if fetch_page is not None
            else {"title": "示例文章", "content": "# 示例文章\n\n正文内容"}
        )
        # /files 上传返回体（id 就是后续 ocr 工具用的 file_id）
        self.file_record = (
            dict(file_record)
            if file_record is not None
            else {
                "id": "file-api-123",
                "object": "file",
                "bytes": 12,
                "created_at": 1700000000,
                "filename": "a.pdf",
                "purpose": "text_recognition",
            }
        )
        self.files_list = (
            dict(files_list)
            if files_list is not None
            else {"object": "list", "data": [dict(self.file_record)]}
        )
        # /v1/tools/ocr 返回体
        self.ocr_result = (
            dict(ocr_result)
            if ocr_result is not None
            else {
                "id": "file-api-123",
                "object": "ocr_result",
                "created": 1700000000,
                "purpose": "text_recognition",
                "page_count": 2,
                "pages": [
                    {"index": 0, "text": "第一页内容", "finish_reason": "success"},
                    {"index": 1, "text": "第二页内容", "finish_reason": "success"},
                ],
                "usage": {"pages": 2},
            }
        )
        # /v1/tools/asr 返回体
        self.asr_result = (
            dict(asr_result)
            if asr_result is not None
            else {
                "request_id": "asr-1",
                "text": "识别出来的话",
                "duration_ms": 3200,
            }
        )
        self.tts_audio = FAKE_WAV if tts_audio is None else tts_audio
        self.tts_content_type = tts_content_type
        self.tts_billed_chars = tts_billed_chars
        self.requests: list[dict[str, Any]] = []
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # ------------------------------------------------------------ 生命周期

    def start(self) -> FakeUpstream:
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), _make_handler(self))
        self._server.daemon_threads = True
        self._thread = threading.Thread(
            target=self._server.serve_forever, daemon=True
        )
        self._thread.start()
        return self

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None

    @property
    def base_url(self) -> str:
        assert self._server is not None, "FakeUpstream 未启动"
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    def __enter__(self) -> FakeUpstream:
        return self.start()

    def __exit__(self, *exc_info: object) -> None:
        self.stop()

    # -------------------------------------------------------------- 内部用

    def record(
        self, path: str, headers: Any, body: bytes, method: str = "POST"
    ) -> None:
        try:
            payload = json.loads(body or b"{}")
        except (json.JSONDecodeError, UnicodeDecodeError):
            payload = None
        # 头名统一小写，便于断言
        normalized = {str(name).lower(): value for name, value in headers.items()}
        self.requests.append(
            {
                "method": method,
                "path": path,
                "headers": normalized,
                # multipart 断言要看原始字节，这里保留一份
                "raw": body,
                "content_type": normalized.get("content-type"),
                "body": payload,
            }
        )

    def next_lines(self) -> list[str]:
        """取本次请求要回放的 SSE 行；配置了 scripts 时按顺序前进。"""
        if not self.scripts:
            return list(self.lines)
        with self._script_lock:
            index = min(self._script_index, len(self.scripts) - 1)
            self._script_index += 1
            return list(self.scripts[index])


def _make_handler(state: FakeUpstream) -> type[BaseHTTPRequestHandler]:
    """为每个 FakeUpstream 生成一个绑定其状态的请求处理器。"""

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self) -> None:  # noqa: N802 - 框架约定
            state.record(self.path, self.headers, b"", method="GET")
            if self.path.rstrip("/") == "/files":
                self._send_json(200, state.files_list)
                return
            self._send_json(404, {"error": {"message": "not found"}})

        def do_POST(self) -> None:  # noqa: N802 - 框架约定
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length)
            state.record(self.path, self.headers, raw)
            normalized = self.path.rstrip("/")
            if normalized in ("/v1/tools/search", "/v1/tools/fetch"):
                self._respond_tools(state)
                return
            if normalized == "/files":
                self._send_json(200, state.file_record)
                return
            if normalized in ("/v1/tools/ocr", "/v1/tools/asr"):
                # 非 200 时按错误返回，便于测试「工具调用失败」分支
                if state.status != 200:
                    self._send_json(
                        state.status, {"error": {"message": state.error_message}}
                    )
                    return
                payload = (
                    state.ocr_result
                    if normalized.endswith("/ocr")
                    else state.asr_result
                )
                self._send_json(200, payload)
                return
            if normalized == "/v1/tools/tts":
                self._respond_tts(state)
                return
            if state.status != 200:
                self._send_json(
                    state.status, {"error": {"message": state.error_message}}
                )
                return
            self._respond_stream(state)

        def _respond_stream(self, state: FakeUpstream) -> None:
            """对话接口：按脚本逐行回放 SSE。"""
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            try:
                for line in state.next_lines():
                    self.wfile.write(f"{line}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    if state.delay:
                        time.sleep(state.delay)
                if state.hold_seconds:
                    time.sleep(state.hold_seconds)
            except OSError:
                pass

        def _respond_tools(self, state: FakeUpstream) -> None:
            """搜索/抓取接口：返回官方格式的 JSON（或指定错误状态）。"""
            if state.tools_status != 200:
                self._send_json(
                    state.tools_status,
                    {"error": {"message": state.error_message}},
                )
                return
            if self.path.rstrip("/").endswith("/search"):
                payload: Any = {"results": state.search_results}
            else:
                payload = state.fetch_page
            self._send_json(200, payload)

        def _respond_tts(self, state: FakeUpstream) -> None:
            """TTS：回**二进制音频**，带上计费字符数头。"""
            if state.status != 200:
                self._send_json(
                    state.status, {"error": {"message": state.error_message}}
                )
                return
            body = state.tts_audio
            self.send_response(200)
            self.send_header("Content-Type", state.tts_content_type)
            self.send_header("Content-Length", str(len(body)))
            if state.tts_billed_chars is not None:
                self.send_header("X-Billed-Chars", state.tts_billed_chars)
            self.end_headers()
            self.wfile.write(body)

        def _send_json(self, status: int, payload: Any) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: Any) -> None:
            """静默：测试里不需要访问日志。"""

    return Handler


def anthropic_script(
    reasoning: str = "思考中",
    content: str = "你好",
    with_source: bool = False,
) -> list[str]:
    """构造一段 anthropic 形态的 SSE 行序列。"""
    events: list[Any] = [
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": reasoning},
        },
    ]
    if with_source:
        events.append(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": [
                        {"title": "示例站点", "url": "https://example.com/a"},
                        {"title": "示例站点", "url": "https://example.com/a"},
                    ],
                },
            }
        )
    events.extend(
        [
            {
                "type": "content_block_delta",
                "index": 1,
                "delta": {"type": "text_delta", "text": content},
            },
            {"type": "message_stop"},
        ]
    )
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def responses_script(content: str = "回答") -> list[str]:
    """构造一段 Responses 形态的 SSE 行序列。"""
    events = [
        {"type": "response.output_text.delta", "delta": content},
        {"type": "response.completed"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def anthropic_server_search_script(
    query: str = "DeepSeek 全家桶",
    content: str = "搜到了。",
    site_name: str = "示例站点",
) -> list[str]:
    """Anthropic 协议下**服务端执行**的联网搜索：没有 tool_use，只有结果事件。

    形状对齐官方：`server_tool_use`（kind=search）→ `web_search_tool_result`
    （带 encrypted_content / page_age / snippet / site_name）→ 正文。
    """
    events: list[Any] = [
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "server_tool_use",
                "id": "srvtoolu_1",
                "name": "web_search",
                "kind": "search",
                "input": {},
            },
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {
                "type": "input_json_delta",
                "partial_json": json.dumps({"query": query}, ensure_ascii=False),
            },
        },
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {
                "type": "web_search_tool_result",
                "tool_use_id": "srvtoolu_1",
                "kind": "search",
                "content": [
                    {
                        "title": "示例站点",
                        "url": "https://example.com/a",
                        "encrypted_content": "enc-abc",
                        "page_age": "2026-11-01T08:00:00Z",
                        "snippet": "这是摘要",
                        "site_name": site_name,
                        "site_icon": "https://example.com/favicon.ico",
                        "image_url": "https://example.com/a.png",
                    },
                    {
                        "title": "第二站",
                        "url": "https://example.com/b",
                        "encrypted_content": "enc-def",
                        "page_age": None,
                        "snippet": "第二段摘要",
                        "site_name": None,
                        "site_icon": None,
                    },
                ],
            },
        },
        {
            "type": "content_block_delta",
            "index": 2,
            "delta": {"type": "text_delta", "text": content},
        },
        {
            "type": "content_block_delta",
            "index": 2,
            "delta": {
                "type": "citations_delta",
                "citation": {
                    "type": "web_search_result_location",
                    "url": "https://example.com/a",
                    "title": "示例站点",
                    "cited_text": "这是摘要",
                    "encrypted_index": "idx-1",
                },
            },
        },
        {"type": "message_stop"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def anthropic_read_link_script(
    url: str = "https://example.com/a",
    content: str = "读完了。",
) -> list[str]:
    """Anthropic 协议下的阅读链接：`web_fetch_tool_result` 带 signature。"""
    events: list[Any] = [
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "server_tool_use",
                "id": "srvtoolu_2",
                "name": "web_fetch",
                "kind": "read_link",
                "input": {"url": url},
            },
        },
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {
                "type": "web_fetch_tool_result",
                "tool_use_id": "srvtoolu_2",
                "kind": "read_link",
                "signature": "sig-xyz",
                "content": {
                    "type": "web_fetch_result",
                    "url": url,
                    "title": "示例文章",
                    "published_at": "2026-11-02T00:00:00Z",
                    "content": {
                        "type": "document",
                        "source": {
                            "type": "text",
                            "media_type": "text/plain",
                            "data": "",
                        },
                        "title": "示例文章",
                    },
                },
            },
        },
        {
            "type": "content_block_delta",
            "index": 2,
            "delta": {"type": "text_delta", "text": content},
        },
        {"type": "message_stop"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def responses_web_search_script(
    query: str = "DeepSeek 全家桶",
    content: str = "搜到了。",
    site_name: str = "示例站点",
) -> list[str]:
    """Responses 协议下的 `web_search_call` item（搜索由上游服务端执行）。"""
    events: list[Any] = [
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "web_search_call",
                "id": "ws_1",
                "status": "in_progress",
                "kind": "search",
                "action": {"type": "search", "queries": [query], "sources": []},
            },
        },
        {
            "type": "response.output_item.done",
            "output_index": 0,
            "item": {
                "type": "web_search_call",
                "id": "ws_1",
                "status": "completed",
                "kind": "search",
                "action": {
                    "type": "search",
                    "queries": [query],
                    "sources": [
                        {
                            "title": "示例站点",
                            "url": "https://example.com/a",
                            "snippet": "这是摘要",
                            "site_name": site_name,
                            "page_age": "2026-11-01T08:00:00Z",
                        },
                        {
                            "title": "第二站",
                            "url": "https://example.com/b",
                            "snippet": "第二段摘要",
                        },
                    ],
                },
                "page": None,
                "signature": "sig-ws-1",
                "error": None,
            },
        },
        {"type": "response.output_text.delta", "delta": content},
        {
            "type": "response.output_text.annotation.added",
            "annotation": {
                "type": "url_citation",
                "url": "https://example.com/a",
                "title": "示例站点",
                "start_index": 0,
                "end_index": 3,
            },
        },
        {"type": "response.completed"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def anthropic_ocr_tool_use_script(file_id: str = "file-api-123") -> list[str]:
    """模型调用 `ocr` 函数工具的中间轮（这个工具由中转服务执行）。"""
    events: list[Any] = [
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "tool_use",
                "id": "tool-ocr-1",
                "name": "ocr",
                "input": {},
            },
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {
                "type": "input_json_delta",
                "partial_json": json.dumps(
                    {"file_id": file_id, "purpose": "text_recognition"},
                    ensure_ascii=False,
                ),
            },
        },
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}},
        {"type": "message_stop"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def responses_ocr_tool_use_script(file_id: str = "file-api-123") -> list[str]:
    """Responses 协议下调用 `ocr` 函数工具的中间轮。"""
    arguments = json.dumps({"file_id": file_id}, ensure_ascii=False)
    events: list[Any] = [
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "function_call",
                "id": "fc_ocr",
                "call_id": "call-ocr-1",
                "name": "ocr",
                "arguments": "",
            },
        },
        {
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_ocr",
            "delta": arguments,
        },
        {
            "type": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "function_call",
                        "id": "fc_ocr",
                        "call_id": "call-ocr-1",
                        "name": "ocr",
                        "arguments": arguments,
                    }
                ]
            },
        },
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]
