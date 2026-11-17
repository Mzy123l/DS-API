"""multipart/form-data 的最小实现：只做中转需要的「拆」和「拼」。

为什么自己写：项目约定纯标准库、不加第三方依赖，而 `cgi` 模块在 Python 3.13
已被移除，`email` 解析 multipart 又太绕。这里只覆盖 RFC 7578 里实际用到的部分：

- 拆：从 Content-Type 里取 boundary，按 boundary 切段，读出字段名/文件名/字节；
- 拼：按官方要求的字段顺序（`purpose` 在前、`file` 在后）拼请求体。

**转发给上游时不会用这里重新编码**：中转把客户端原始字节直接透传，
这里只在两处使用——服务端自己缓存上传文件（拆），以及内部调用 OCR（拼）。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

_BOUNDARY_RE = re.compile(r'boundary="?([^";]+)"?', re.IGNORECASE)
# 生成 boundary 用的字符集：RFC 2046 允许 bcharsnospace 的常见子集
_BOUNDARY_SAFE = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


@dataclass
class MultipartPart:
    """一个 multipart 分段。"""

    name: str = ""
    filename: str | None = None
    content_type: str | None = None
    data: bytes = b""
    headers: dict[str, str] = field(default_factory=dict)

    @property
    def text(self) -> str:
        """按 UTF-8 解码（字段值用；二进制内容请用 data）。"""
        return self.data.decode("utf-8", "replace")


def parse_boundary(content_type: str | None) -> str | None:
    """从 Content-Type 里取 boundary，取不到返回 None。"""
    if not content_type:
        return None
    if "multipart/form-data" not in content_type.lower():
        return None
    match = _BOUNDARY_RE.search(content_type)
    return match.group(1) if match else None


def _parse_part_headers(raw: bytes) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in raw.split(b"\r\n"):
        if not line:
            continue
        name, _, value = line.decode("utf-8", "replace").partition(":")
        if not name or not _:
            continue
        headers[name.strip().lower()] = value.strip()
    return headers


def _disposition_value(disposition: str, key: str) -> str | None:
    """从 Content-Disposition 里取 name= / filename= 的值（带不带引号都认）。"""
    match = re.search(
        rf'(?:^|;)\s*{key}\s*=\s*(?:"([^"]*)"|([^;]+))',
        disposition,
        re.IGNORECASE,
    )
    if not match:
        return None
    value = match.group(1) if match.group(1) is not None else match.group(2)
    return value.strip() if value else value


def parse_multipart(
    body: bytes, content_type: str | None
) -> list[MultipartPart] | None:
    """把 multipart 请求体拆成分段列表；不是 multipart 或格式坏掉返回 None。"""
    boundary = parse_boundary(content_type)
    if not boundary:
        return None
    delimiter = b"--" + boundary.encode("utf-8", "replace")
    # 首段前面可能有 preamble，末段后面是结束标记 "--"
    segments = body.split(delimiter)
    if len(segments) < 2:
        return None
    parts: list[MultipartPart] = []
    for segment in segments[1:]:
        if segment.startswith(b"--"):
            # 结束标记
            break
        # 每段以 CRLF 开头、以 CRLF 结尾
        if segment.startswith(b"\r\n"):
            segment = segment[2:]
        if segment.endswith(b"\r\n"):
            segment = segment[:-2]
        head, separator, data = segment.partition(b"\r\n\r\n")
        if not separator:
            continue
        headers = _parse_part_headers(head)
        disposition = headers.get("content-disposition", "")
        parts.append(
            MultipartPart(
                name=_disposition_value(disposition, "name") or "",
                filename=_disposition_value(disposition, "filename"),
                content_type=headers.get("content-type"),
                data=data,
                headers=headers,
            )
        )
    return parts


def part_by_name(parts: list[MultipartPart], name: str) -> MultipartPart | None:
    """按字段名取第一个分段。"""
    for part in parts:
        if part.name == name:
            return part
    return None


def _escape_quotes(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def build_multipart(
    fields: list[tuple[str, str]] | None = None,
    files: list[tuple[str, str, str, bytes]] | None = None,
    *,
    boundary: str | None = None,
) -> tuple[bytes, str]:
    """按给定顺序拼 multipart 请求体，返回 (body, Content-Type)。

    `fields` 是普通文本字段 `(name, value)`；`files` 是文件字段
    `(name, filename, content_type, data)`。两者按「先 fields 后 files」拼接，
    所以调用方要把 `purpose` 放进 fields、把 `file` 放进 files，
    正好满足官方「purpose 必须在 file 之前」的要求。
    """
    if boundary is None:
        boundary = _random_boundary()
    chunks: list[bytes] = []
    for name, value in fields or []:
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{_escape_quotes(name)}"\r\n'
                f"\r\n"
            ).encode("utf-8")
        )
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")
    for name, filename, content_type, data in files or []:
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{_escape_quotes(name)}"; '
                f'filename="{_escape_quotes(filename)}"\r\n'
                f"Content-Type: {content_type or 'application/octet-stream'}\r\n"
                f"\r\n"
            ).encode("utf-8")
        )
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def _random_boundary() -> str:
    """生成一个不会出现在正文里的 boundary。"""
    import os

    return "----dsrelay" + "".join(
        _BOUNDARY_SAFE[b % len(_BOUNDARY_SAFE)] for b in os.urandom(24)
    )


def parts_to_debug(parts: list[MultipartPart]) -> list[dict[str, Any]]:
    """测试/日志用：只描述结构，不带文件内容。"""
    return [
        {
            "name": part.name,
            "filename": part.filename,
            "content_type": part.content_type,
            "size": len(part.data),
        }
        for part in parts
    ]
