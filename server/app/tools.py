"""工具与多媒体代理：把官方 Search / Fetch / Files / OCR / ASR / TTS 转发给上游。

客户端（以及服务端内部的 ocr 工具）都通过这里访问 DeepSeek 官方接口。
API Key 只随请求头透传，不落盘。

两条硬性要求决定了这里的实现方式：
- 上行：`/files`、`/v1/tools/ocr`、`/v1/tools/asr` 是 multipart，**必须原样转发**
  请求体并连同 boundary 透传 Content-Type，重新编码会破坏字段边界；
- 下行：`/v1/tools/tts` 返回音频，**必须按 bytes 透传**，不能先按 UTF-8 解码。
"""

from __future__ import annotations

import http.client
import json
import ssl
from typing import Any
from urllib.parse import urlsplit

# 文本类响应读取上限：搜索结果可能带正文，留足余量
MAX_TOOL_RESPONSE_BYTES = 64 * 1024 * 1024

# 音频类响应读取上限：官方 TTS 单次最多 30 分钟音频。
# 按 48kHz / 16bit / 立体声估算约 346 MiB（1800s × 192000 B/s），这里放宽到 384 MiB。
MAX_MEDIA_RESPONSE_BYTES = 384 * 1024 * 1024

# 需要透传给客户端的上游响应头（音频计费字符数、文件名、请求号）
PASSTHROUGH_RESPONSE_HEADERS = (
    "x-billed-chars",
    "content-disposition",
    "x-request-id",
)

_JSON_CONTENT_TYPE = "application/json; charset=utf-8"


def tools_target_path(base_path: str, path: str) -> str:
    """计算上游请求路径：兼容 base 带 /anthropic、/v1 等前缀的配置。"""
    prefix = base_path.rstrip("/")
    for suffix in ("/anthropic/v1", "/anthropic", "/v1"):
        if prefix.endswith(suffix):
            prefix = prefix[: -len(suffix)]
            break
    return f"{prefix}{path}"


def _json_error(
    status: int, message: str
) -> tuple[int, bytes, str, dict[str, str]]:
    """构造一个 JSON 错误响应（与旧版 proxy_tool_request 的错误格式一致）。"""
    body = json.dumps(
        {"error": {"message": message}}, ensure_ascii=False
    ).encode("utf-8")
    return status, body, _JSON_CONTENT_TYPE, {}


def proxy_raw_request(
    base: str,
    path: str,
    *,
    method: str = "POST",
    body: bytes = b"",
    content_type: str | None = None,
    authorization: str = "",
    timeout: float,
    accept: str = "application/json",
    max_bytes: int = MAX_TOOL_RESPONSE_BYTES,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, bytes, str, dict[str, str]]:
    """把一次请求原样转发给上游。

    返回 ``(状态码, 原始字节, Content-Type, 需透传的响应头)``。

    这里**不做任何编解码**：multipart 请求体与音频响应都按 bytes 走，
    避免二次编码破坏边界符或音频数据。上游状态码与响应体原样返回，
    客户端可直接按官方文档处理错误。
    """
    parsed = urlsplit(base)
    host = parsed.hostname or ""
    if not host or parsed.scheme not in ("http", "https"):
        return _json_error(400, "上游地址无效")

    target = tools_target_path(parsed.path, path)
    headers: dict[str, str] = {"Accept": accept}
    if content_type:
        headers["Content-Type"] = content_type
    if authorization:
        headers["Authorization"] = authorization
    headers["Content-Length"] = str(len(body))
    if extra_headers:
        headers.update(extra_headers)

    connection: http.client.HTTPConnection | None = None
    try:
        if parsed.scheme == "https":
            connection = http.client.HTTPSConnection(
                host,
                parsed.port,
                timeout=timeout,
                context=ssl.create_default_context(),
            )
        else:
            connection = http.client.HTTPConnection(host, parsed.port, timeout=timeout)
        connection.request(method, target, body=body, headers=headers)
        response = connection.getresponse()
        # 多读一个字节用于判断是否超限，超限直接报错而不是悄悄截断（音频截断会坏）
        raw = response.read(max_bytes + 1)
        if len(raw) > max_bytes:
            return _json_error(502, "上游响应过大")
        response_content_type = response.getheader("Content-Type") or _JSON_CONTENT_TYPE
        passthrough = {
            name: value
            for name in PASSTHROUGH_RESPONSE_HEADERS
            if (value := response.getheader(name))
        }
        return response.status, raw, response_content_type, passthrough
    except (OSError, ValueError, http.client.HTTPException) as exc:
        return _json_error(502, f"上游请求失败：{exc}")
    finally:
        if connection is not None:
            try:
                connection.close()
            except OSError:
                pass


def proxy_json_request(
    base: str,
    path: str,
    payload: dict[str, Any],
    authorization: str,
    timeout: float,
    *,
    method: str = "POST",
    max_bytes: int = MAX_TOOL_RESPONSE_BYTES,
    accept: str = "application/json",
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, bytes, str, dict[str, str]]:
    """JSON 进、**原始字节**出（TTS 音频走这里）。"""
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return proxy_raw_request(
        base,
        path,
        method=method,
        body=body,
        content_type="application/json",
        authorization=authorization,
        timeout=timeout,
        accept=accept,
        max_bytes=max_bytes,
        extra_headers=extra_headers,
    )


def proxy_multipart_request(
    base: str,
    path: str,
    body: bytes,
    content_type: str,
    authorization: str,
    timeout: float,
    *,
    max_bytes: int = MAX_TOOL_RESPONSE_BYTES,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, bytes, str, dict[str, str]]:
    """multipart 进、原始字节出：请求体与 boundary 一并透传，不做重编码。"""
    return proxy_raw_request(
        base,
        path,
        body=body,
        content_type=content_type,
        authorization=authorization,
        timeout=timeout,
        max_bytes=max_bytes,
        extra_headers=extra_headers,
    )


def proxy_get_request(
    base: str,
    path: str,
    authorization: str,
    timeout: float,
    *,
    max_bytes: int = MAX_TOOL_RESPONSE_BYTES,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, bytes, str, dict[str, str]]:
    """GET 转发（`/files` 列表用）。"""
    return proxy_raw_request(
        base,
        path,
        method="GET",
        authorization=authorization,
        timeout=timeout,
        max_bytes=max_bytes,
        extra_headers=extra_headers,
    )


def proxy_tool_request(
    base: str,
    path: str,
    payload: dict[str, Any],
    authorization: str,
    timeout: float,
) -> tuple[int, str, str]:
    """旧接口：JSON 进、文本出（Search / Fetch 仍走这里，保持调用点不变）。"""
    status, raw, content_type, _headers = proxy_json_request(
        base, path, payload, authorization, timeout
    )
    return status, raw.decode("utf-8", "replace"), content_type
