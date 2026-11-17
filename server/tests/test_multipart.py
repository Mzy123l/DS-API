"""multipart 拆装与工具代理的单元测试（纯函数层，不起服务）。"""

from __future__ import annotations

import json

from app.multipart import (
    build_multipart,
    parse_boundary,
    parse_multipart,
    part_by_name,
    parts_to_debug,
)
from app.tools import (
    MAX_MEDIA_RESPONSE_BYTES,
    MAX_TOOL_RESPONSE_BYTES,
    proxy_get_request,
    proxy_json_request,
    proxy_multipart_request,
    proxy_tool_request,
    tools_target_path,
)
from tests.fake_upstream import FAKE_WAV, FakeUpstream

# ------------------------------------------------------------------ multipart


def test_parse_boundary_variants() -> None:
    assert parse_boundary("multipart/form-data; boundary=abc") == "abc"
    assert parse_boundary('multipart/form-data; boundary="a b"') == "a b"
    assert parse_boundary("multipart/form-data") is None
    assert parse_boundary("application/json") is None
    assert parse_boundary(None) is None


def test_parse_multipart_reads_fields_and_files() -> None:
    body, content_type = build_multipart(
        fields=[("purpose", "text_recognition")],
        files=[("file", "a.pdf", "application/pdf", b"%PDF-1.7 data")],
    )
    parts = parse_multipart(body, content_type)
    assert parts is not None
    assert parts_to_debug(parts) == [
        {
            "name": "purpose",
            "filename": None,
            "content_type": None,
            "size": len("text_recognition"),
        },
        {
            "name": "file",
            "filename": "a.pdf",
            "content_type": "application/pdf",
            "size": len(b"%PDF-1.7 data"),
        },
    ]
    purpose = part_by_name(parts, "purpose")
    assert purpose is not None and purpose.text == "text_recognition"
    file_part = part_by_name(parts, "file")
    assert file_part is not None
    assert file_part.data == b"%PDF-1.7 data"
    assert part_by_name(parts, "missing") is None


def test_build_multipart_puts_fields_before_files() -> None:
    """官方要求 purpose 必须在 file 之前。"""
    body, content_type = build_multipart(
        fields=[("purpose", "user_data")],
        files=[("file", "a.txt", "text/plain", b"hi")],
    )
    assert content_type.startswith("multipart/form-data; boundary=")
    assert body.index(b'name="purpose"') < body.index(b'name="file"')
    assert body.endswith(b"--\r\n")
    assert parse_multipart(body, content_type) is not None


def test_build_multipart_escapes_quotes_in_filename() -> None:
    body, content_type = build_multipart(
        files=[("file", 'a"b.txt', "text/plain", b"x")],
        boundary="fixed",
    )
    assert content_type == "multipart/form-data; boundary=fixed"
    assert b'filename="a\\"b.txt"' in body


def test_build_multipart_defaults_content_type() -> None:
    body, _ = build_multipart(files=[("file", "a.bin", "", b"x")])
    assert b"Content-Type: application/octet-stream" in body


def test_parse_multipart_rejects_bad_input() -> None:
    assert parse_multipart(b"anything", "application/json") is None
    assert (
        parse_multipart(b"no boundary here", "multipart/form-data; boundary=x") is None
    )
    # 只有结束标记、没有实际分段
    assert parse_multipart(b"--x--\r\n", "multipart/form-data; boundary=x") == []


def test_parse_multipart_skips_segment_without_header_end() -> None:
    body = b'--x\r\nContent-Disposition: form-data; name="a"\r\n--x--\r\n'
    parts = parse_multipart(body, "multipart/form-data; boundary=x")
    assert parts == []


# ---------------------------------------------------------------- 工具代理


def test_tools_target_path_strips_known_prefixes() -> None:
    assert tools_target_path("", "/files") == "/files"
    assert tools_target_path("/v1", "/files") == "/files"
    assert tools_target_path("/anthropic/v1", "/files") == "/files"
    assert tools_target_path("/anthropic", "/files") == "/files"
    assert tools_target_path("/api", "/files") == "/api/files"


def test_proxy_raw_rejects_invalid_base() -> None:
    status, body, content_type, headers = proxy_json_request(
        "ftp://bad", "/v1/tools/tts", {"text": "x"}, "Bearer k", 5.0
    )
    assert status == 400
    assert json.loads(body)["error"]["message"] == "上游地址无效"
    assert content_type.startswith("application/json")
    assert headers == {}


def test_proxy_reports_connection_failure() -> None:
    status, body, _content_type, _headers = proxy_json_request(
        "http://127.0.0.1:1", "/v1/tools/tts", {"text": "x"}, "Bearer k", 2.0
    )
    assert status == 502
    assert "上游请求失败" in json.loads(body)["error"]["message"]


def test_proxy_multipart_and_get_roundtrip() -> None:
    with FakeUpstream() as upstream:
        body, content_type = build_multipart(
            fields=[("purpose", "text_recognition")],
            files=[("file", "a.pdf", "application/pdf", b"data")],
        )
        status, raw, response_type, _headers = proxy_multipart_request(
            upstream.base_url, "/files", body, content_type, "Bearer k", 5.0
        )
        assert status == 200
        assert json.loads(raw)["id"] == "file-api-123"
        assert response_type.startswith("application/json")
        assert upstream.requests[0]["raw"] == body

        status, raw, _type, _headers = proxy_get_request(
            upstream.base_url, "/files", "Bearer k", 5.0
        )
        assert status == 200
        assert json.loads(raw)["object"] == "list"
        assert upstream.requests[1]["method"] == "GET"


def test_proxy_tts_returns_raw_bytes_and_billed_header() -> None:
    with FakeUpstream() as upstream:
        status, raw, content_type, headers = proxy_json_request(
            upstream.base_url,
            "/v1/tools/tts",
            {"text": "hi"},
            "Bearer k",
            5.0,
            max_bytes=MAX_MEDIA_RESPONSE_BYTES,
        )
        assert status == 200
        assert raw == FAKE_WAV
        assert content_type == "audio/wav"
        assert headers["x-billed-chars"] == "42"


def test_proxy_rejects_oversized_response() -> None:
    """超限直接报错，不悄悄截断（音频截断会坏）。"""
    with FakeUpstream() as upstream:
        status, body, _type, _headers = proxy_json_request(
            upstream.base_url,
            "/v1/tools/tts",
            {"text": "hi"},
            "Bearer k",
            5.0,
            max_bytes=4,
        )
    assert status == 502
    assert json.loads(body)["error"]["message"] == "上游响应过大"


def test_legacy_proxy_tool_request_still_returns_text() -> None:
    """旧签名（JSON 进、文本出）保持可用，Search / Fetch 调用点不用改。"""
    with FakeUpstream() as upstream:
        status, body, content_type = proxy_tool_request(
            upstream.base_url,
            "/v1/tools/search",
            {"query": "hi"},
            "Bearer k",
            5.0,
        )
    assert status == 200
    assert isinstance(body, str)
    assert content_type.startswith("application/json")
    assert json.loads(body)["results"][0]["url"] == "https://example.com/a"


def test_response_limits_allow_long_audio() -> None:
    """音频上限按「30 分钟」放宽，远大于文本上限。"""
    assert MAX_MEDIA_RESPONSE_BYTES > MAX_TOOL_RESPONSE_BYTES
    # 30 分钟 48kHz/16bit 立体声 ≈ 346 MiB，上限必须罩得住
    assert MAX_MEDIA_RESPONSE_BYTES >= 346 * 1024 * 1024
