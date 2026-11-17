"""SSE 累加器与上游路径规则的单元测试。"""

from __future__ import annotations

import json

from app.sse import (
    PROTOCOL_ANTHROPIC,
    PROTOCOL_CHAT,
    PROTOCOL_RESPONSES,
    StreamAccumulator,
    extract_error,
    upstream_path,
)
from tests.fake_upstream import (
    anthropic_read_link_script,
    anthropic_server_search_script,
    responses_web_search_script,
)


def data_line(event: dict) -> str:
    return f"data: {json.dumps(event, ensure_ascii=False)}"


def test_anthropic_accumulates_reasoning_content_and_sources() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(": 注释行应被忽略")
    acc.feed(
        data_line(
            {
                "type": "content_block_delta",
                "delta": {"type": "thinking_delta", "thinking": "先想"},
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "content_block_delta",
                "delta": {"type": "text_delta", "text": "答案"},
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": [
                        {"title": "A", "url": "https://a.example"},
                        {"title": "B", "url": "https://b.example"},
                    ],
                },
            }
        )
    )
    assert not acc.done
    acc.feed(data_line({"type": "message_stop"}))
    assert acc.done
    assert acc.reasoning == "先想"
    assert acc.content == "答案"
    assert [s["url"] for s in acc.sources] == [
        "https://a.example",
        "https://b.example",
    ]


def test_server_function_tool_calls_are_collected_for_both_protocols() -> None:
    """只有服务端要执行的函数工具（ocr）才进入工具循环，服务端工具不计入。"""
    anthropic = StreamAccumulator(PROTOCOL_ANTHROPIC)
    anthropic.feed(
        data_line(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {
                    "type": "tool_use",
                    "id": "t1",
                    "name": "ocr",
                },
            }
        )
    )
    anthropic.feed(
        data_line(
            {
                "type": "content_block_delta",
                "index": 1,
                "delta": {
                    "type": "input_json_delta",
                    "partial_json": '{"file_id":"file-1"}',
                },
            }
        )
    )
    assert anthropic.tool_use
    assert len(anthropic.round_tool_calls) == 1
    assert anthropic.round_tool_calls[0]["name"] == "ocr"
    assert anthropic.round_tool_calls[0]["arguments"] == '{"file_id":"file-1"}'

    # search / fetch 不再是客户端函数工具（联网搜索已由上游服务端执行）
    legacy = StreamAccumulator(PROTOCOL_ANTHROPIC)
    legacy.feed(
        data_line(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {"type": "tool_use", "id": "t2", "name": "search"},
            }
        )
    )
    assert not legacy.tool_use
    assert legacy.round_tool_calls == []

    # 只有 stop_reason=message_delta（典型是服务端 web_search 工具）不能算客户端工具
    stop_reason = StreamAccumulator(PROTOCOL_ANTHROPIC)
    stop_reason.feed(
        data_line({"type": "message_delta", "delta": {"stop_reason": "tool_use"}})
    )
    assert not stop_reason.tool_use
    assert stop_reason.round_tool_calls == []

    responses = StreamAccumulator(PROTOCOL_RESPONSES)
    responses.feed(
        data_line(
            {
                "type": "response.output_item.added",
                "item": {
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "c1",
                    "name": "ocr",
                    "arguments": "",
                },
            }
        )
    )
    responses.feed(
        data_line(
            {
                "type": "response.function_call_arguments.delta",
                "item_id": "fc_1",
                "delta": '{"file_id":"file-1"}',
            }
        )
    )
    responses.feed(
        data_line(
            {
                "type": "response.completed",
                "response": {
                    "output": [
                        {
                            "type": "function_call",
                            "id": "fc_1",
                            "call_id": "c1",
                            "name": "ocr",
                            "arguments": '{"file_id":"file-1"}',
                        }
                    ]
                },
            }
        )
    )
    assert responses.tool_use
    assert len(responses.round_tool_calls) == 1
    assert responses.round_tool_calls[0]["name"] == "ocr"
    assert responses.round_tool_calls[0]["arguments"] == '{"file_id":"file-1"}'
    assert responses.done


def test_anthropic_ignores_broken_and_empty_lines() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    for line in ("", "data:", "event: ping", "data: {不是 json", "data: [1,2]"):
        acc.feed(line)
    assert acc.content == ""
    assert acc.error is None
    assert not acc.done


def test_anthropic_error_event() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(data_line({"type": "error", "error": {"message": "额度不足"}}))
    assert acc.error == "额度不足"

    fallback = StreamAccumulator(PROTOCOL_ANTHROPIC)
    fallback.feed(data_line({"type": "error", "error": {}}))
    assert fallback.error == "API 请求失败"


def test_anthropic_content_block_start_and_message_delta() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {"type": "text", "text": "开头"},
            }
        )
    )
    acc.feed(data_line({"type": "content_block_delta", "delta": {"type": "x"}}))
    acc.feed(data_line({"type": "message_delta", "delta": {"stop_reason": "x"}}))
    acc.feed(data_line({"type": "content_block_start", "content_block": "坏数据"}))
    acc.feed(data_line({"type": "content_block_delta", "delta": "坏数据"}))
    assert acc.content == "开头"


def test_anthropic_thinking_start_block() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {"type": "thinking", "thinking": "起始思考"},
            }
        )
    )
    assert acc.reasoning == "起始思考"


def test_responses_stream() -> None:
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    acc.feed(data_line({"type": "response.reasoning_text.delta", "delta": "想"}))
    acc.feed(data_line({"type": "response.output_text.delta", "delta": "答"}))
    acc.feed(data_line({"type": "response.output_text.done", "delta": "不应重复"}))
    assert not acc.done
    acc.feed(data_line({"type": "response.completed"}))
    assert acc.done
    assert acc.reasoning == "想"
    assert acc.content == "答"


def test_responses_done_fallback_and_errors() -> None:
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    acc.feed(data_line({"type": "response.reasoning_text.done", "text": "完整思考"}))
    acc.feed(data_line({"type": "response.output_text.done", "text": "完整回答"}))
    assert acc.reasoning == "完整思考"
    assert acc.content == "完整回答"

    acc.feed(
        data_line({"type": "response.failed", "error": {"message": "模型不可用"}})
    )
    assert acc.error == "模型不可用"

    done_marker = StreamAccumulator(PROTOCOL_RESPONSES)
    done_marker.feed("data: [DONE]")
    assert done_marker.done

    typed_error = StreamAccumulator(PROTOCOL_RESPONSES)
    typed_error.feed(data_line({"error": {"message": "参数错误"}}))
    assert typed_error.error == "参数错误"

    no_delta = StreamAccumulator(PROTOCOL_RESPONSES)
    no_delta.feed(data_line({"type": "response.reasoning_text.delta", "delta": ""}))
    no_delta.feed(data_line({"type": "response.output_text.delta", "delta": ""}))
    assert no_delta.reasoning == ""
    assert no_delta.content == ""


def test_anthropic_done_marker_ignored() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed("data: [DONE]")
    assert not acc.done


def test_extract_error() -> None:
    assert extract_error('{"error":{"message":"坏 key"}}', 401) == "坏 key"
    assert extract_error('{"error":"字符串错误"}', 400) == "字符串错误"
    assert extract_error("不是 json", 500) == "请求失败 (HTTP 500)"
    assert extract_error("{}", 500) == "请求失败 (HTTP 500)"


def test_upstream_path_rules() -> None:
    assert upstream_path(PROTOCOL_ANTHROPIC, "https://api.deepseek.com") == (
        "/anthropic/v1/messages"
    )
    assert upstream_path(PROTOCOL_ANTHROPIC, "http://10.0.0.2:8989/v1") == "/messages"
    assert upstream_path(PROTOCOL_RESPONSES, "https://api.deepseek.com") == (
        "/responses"
    )


def test_sources_dedupe_and_bad_items() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": [
                        {"url": "https://a"},
                        {"title": "无链接"},
                        "字符串",
                        {"title": "空标题", "url": "https://b"},
                    ],
                },
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": [{"url": "https://a"}],
                },
            }
        )
    )
    assert acc.sources == [
        {"title": "https://a", "url": "https://a"},
        {"title": "空标题", "url": "https://b"},
    ]


def test_non_list_search_content_is_ignored() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": "不是列表",
                },
            }
        )
    )
    assert acc.sources == []


def test_non_dict_json_event_is_ignored() -> None:
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    acc.feed("data: [1, 2, 3]")
    assert acc.content == ""
    assert not acc.done


# --------------------------------------------------------------- 服务端工具

def test_anthropic_server_tool_use_and_search_result() -> None:
    """server_tool_use + web_search_tool_result：生成 steps，来源补齐新字段。"""
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    for line in anthropic_server_search_script():
        acc.feed(line)
    assert acc.done
    assert acc.content == "搜到了。"
    # 步骤：kind=search、带上查询词、状态完成、结果条数
    assert len(acc.steps) == 1
    step = acc.steps[0]
    assert step["kind"] == "search"
    assert step["action"] == "search"
    assert step["query"] == "DeepSeek 全家桶"
    assert step["status"] == "done"
    assert step["result_count"] == 2
    # 来源：旧字段 title/url 在，新字段补齐；空值不写
    assert [s["url"] for s in acc.sources] == [
        "https://example.com/a",
        "https://example.com/b",
    ]
    first = acc.sources[0]
    assert first["title"] == "示例站点"
    assert first["site_name"] == "示例站点"
    assert first["snippet"] == "这是摘要"
    assert first["page_age"] == "2026-11-01T08:00:00Z"
    assert first["image_url"] == "https://example.com/a.png"
    assert "site_name" not in acc.sources[1]
    # 引用
    assert acc.citations[0]["url"] == "https://example.com/a"
    assert acc.citations[0]["cited_text"] == "这是摘要"
    # 内部拼接缓冲不外泄
    assert "_input" not in step


def test_anthropic_server_search_error_result() -> None:
    """失败时 content 是 [{"type":"web_search_tool_result_error",...}]。"""
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {
                    "type": "server_tool_use",
                    "id": "s1",
                    "name": "web_search",
                    "kind": "search",
                    "input": {"query": "x"},
                },
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "index": 1,
                "content_block": {
                    "type": "web_search_tool_result",
                    "content": [
                        {
                            "type": "web_search_tool_result_error",
                            "error_code": "unavailable",
                        }
                    ],
                },
            }
        )
    )
    assert acc.sources == []
    assert acc.steps[0]["status"] == "error"
    assert acc.steps[0]["error"] == "unavailable"


def test_anthropic_web_fetch_result_read_link() -> None:
    """web_fetch_tool_result：kind=read_link，带 signature 与页面标题。"""
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    for line in anthropic_read_link_script():
        acc.feed(line)
    assert acc.done
    assert acc.content == "读完了。"
    step = acc.steps[0]
    assert step["kind"] == "read_link"
    assert step["action"] == "read_link"
    assert step["url"] == "https://example.com/a"
    assert step["status"] == "done"
    assert step["signature"] == "sig-xyz"
    assert step["title"] == "示例文章"
    assert acc.sources[0]["url"] == "https://example.com/a"


def test_anthropic_web_fetch_error() -> None:
    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    acc.feed(
        data_line(
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {
                    "type": "web_fetch_tool_result",
                    "kind": "read_link",
                    "content": {
                        "type": "web_fetch_tool_result_error",
                        "error_code": "url_not_allowed",
                    },
                },
            }
        )
    )
    assert acc.steps[0]["kind"] == "read_link"
    assert acc.steps[0]["status"] == "error"
    assert acc.steps[0]["error"] == "url_not_allowed"
    assert acc.sources == []


def test_responses_web_search_call_item() -> None:
    """Responses 的 web_search_call：kind/action/sources/signature 都要解析。"""
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    for line in responses_web_search_script():
        acc.feed(line)
    assert acc.done
    assert acc.content == "搜到了。"
    assert len(acc.steps) == 1
    step = acc.steps[0]
    assert step["kind"] == "search"
    assert step["action"] == "search"
    assert step["query"] == "DeepSeek 全家桶"
    assert step["status"] == "done"
    assert step["signature"] == "sig-ws-1"
    assert step["id"] == "ws_1"
    assert [s["url"] for s in acc.sources] == [
        "https://example.com/a",
        "https://example.com/b",
    ]
    assert acc.sources[0]["site_name"] == "示例站点"
    # 引用来自 response.output_text.annotation.added
    assert acc.citations[0]["url"] == "https://example.com/a"
    assert acc.citations[0]["end_index"] == 3


def test_responses_open_page_and_find_in_page() -> None:
    """action.type=open_page / find_in_page 都归到 read_link。"""
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    acc.feed(
        data_line(
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "web_search_call",
                    "id": "ws_open",
                    "status": "completed",
                    "action": {"type": "open_page", "url": "https://example.com/x"},
                },
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "web_search_call",
                    "id": "ws_find",
                    "status": "completed",
                    "action": {
                        "type": "find_in_page",
                        "url": "https://example.com/y",
                        "pattern": "价格",
                    },
                },
            }
        )
    )
    assert [s["kind"] for s in acc.steps] == ["read_link", "read_link"]
    assert acc.steps[0]["url"] == "https://example.com/x"
    assert acc.steps[1]["pattern"] == "价格"
    # 打开过的页面也算来源
    assert [s["url"] for s in acc.sources] == [
        "https://example.com/x",
        "https://example.com/y",
    ]


def test_responses_web_search_call_error_and_page() -> None:
    acc = StreamAccumulator(PROTOCOL_RESPONSES)
    acc.feed(
        data_line(
            {
                "type": "response.output_item.added",
                "item": {
                    "type": "web_search_call",
                    "id": "ws_err",
                    "status": "in_progress",
                    "action": {"type": "search", "queries": ["q"]},
                    "page": {"url": "https://example.com/p"},
                },
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "response.output_item.done",
                "item": {
                    "type": "web_search_call",
                    "id": "ws_err",
                    "status": "failed",
                    "action": {"type": "search", "queries": ["q"]},
                    "error": {"message": "搜索被限流"},
                },
            }
        )
    )
    step = acc.steps[0]
    assert step["status"] == "error"
    assert step["error"] == "搜索被限流"
    # page.url 兜底填进 url
    assert step["url"] == "https://example.com/p"


def test_chat_server_tool_event_is_parsed() -> None:
    """Chat Completions 的 server_tool_event：不主动用，但不能解析错。"""
    acc = StreamAccumulator(PROTOCOL_CHAT)
    acc.feed(
        data_line(
            {
                "type": "server_tool_event",
                "event": {
                    "kind": "search",
                    "status": "completed",
                    "action": {
                        "type": "search",
                        "queries": ["全家桶"],
                        "sources": [
                            {
                                "title": "站点",
                                "url": "https://example.com/c",
                                "snippet": "摘要",
                            }
                        ],
                    },
                },
            }
        )
    )
    acc.feed(
        data_line(
            {
                "type": "server_tool_event",
                "event": {
                    "kind": "read_link",
                    "url": "https://example.com/d",
                    "status": "completed",
                },
            }
        )
    )
    assert [s["kind"] for s in acc.steps] == ["search", "read_link"]
    assert acc.steps[0]["query"] == "全家桶"
    assert acc.steps[1]["url"] == "https://example.com/d"
    assert acc.sources[0]["url"] == "https://example.com/c"
    assert acc.sources[0]["snippet"] == "摘要"


def test_chat_plain_deltas_are_accumulated() -> None:
    """Chat Completions 的普通增量（choices[].delta）也要能累加。"""
    acc = StreamAccumulator(PROTOCOL_CHAT)
    acc.feed(
        data_line(
            {
                "choices": [
                    {"delta": {"reasoning_content": "想", "content": "答"}}
                ]
            }
        )
    )
    acc.feed("data: [DONE]")
    assert acc.reasoning == "想"
    assert acc.content == "答"
    assert acc.done
