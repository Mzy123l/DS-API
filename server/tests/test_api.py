"""HTTP 接口端到端测试：中转流、快照补齐、取消与错误转发。"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import replace

import pytest

from app.config import Config, ConfigError, require_token_hash
from app.main import RelayServer, build_server
from app.store import ChatStore
from tests.fake_upstream import (
    FAKE_WAV,
    FakeUpstream,
    anthropic_read_link_script,
    anthropic_script,
    anthropic_server_search_script,
    responses_script,
    responses_web_search_script,
)

# 测试用固定口令：服务端不允许“无口令运行”，夹具必须带一个
TEST_TOKEN = "test-relay-token"


class RelayHarness:
    """在后台线程里跑真实中转服务，指向指定上游。"""

    def __init__(
        self,
        upstream_base: str,
        token: str = TEST_TOKEN,
        config: Config | None = None,
    ) -> None:
        # 服务端只保存哈希：测试里先把明文换算成哈希
        token_hash = (
            hashlib.sha256(token.encode("utf-8")).hexdigest() if token else ""
        )
        base_config = config or Config(upstream_base=upstream_base)
        self.server = RelayServer(
            ("127.0.0.1", 0),
            replace(
                base_config,
                upstream_base=upstream_base,
                relay_token_hash=token_hash,
            ),
            store=ChatStore(":memory:"),
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address[:2]
        self.base = f"http://{host}:{port}"
        self.token = token

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.server.store.close()
        self.thread.join(timeout=5)

    def post(self, path: str, body: dict, headers: dict | None = None):
        headers = dict(headers or {})
        if self.token:
            headers.setdefault("x-relay-token", self.token)
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json", **headers},
            method="POST",
        )
        return urllib.request.urlopen(request, timeout=10)

    def get(self, path: str, headers: dict | None = None):
        request = urllib.request.Request(f"{self.base}{path}")
        if self.token:
            request.add_header("x-relay-token", self.token)
        for name, value in (headers or {}).items():
            request.add_header(name, value)
        return urllib.request.urlopen(request, timeout=10)

    def post_raw(
        self,
        path: str,
        data: bytes,
        content_type: str,
        headers: dict | None = None,
    ):
        """发原始字节（multipart / 音频用），返回 (状态码, 响应字节, 响应头)。"""
        all_headers = {"Content-Type": content_type, **(headers or {})}
        if self.token:
            all_headers.setdefault("x-relay-token", self.token)
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=data,
            headers=all_headers,
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read(), dict(response.headers)


    def get_raw(self, path: str, headers: dict | None = None):
        """GET 并返回 (状态码, 响应字节, 响应头)（音频字节下载用）。"""
        all_headers = {**(headers or {})}
        if self.token:
            all_headers.setdefault("x-relay-token", self.token)
        request = urllib.request.Request(
            f"{self.base}{path}",
            headers=all_headers,
            method="GET",
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read(), dict(response.headers)
    def patch(self, path: str, body: dict):
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["x-relay-token"] = self.token
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="PATCH",
        )
        return urllib.request.urlopen(request, timeout=10)

    def delete(self, path: str):
        request = urllib.request.Request(f"{self.base}{path}", method="DELETE")
        if self.token:
            request.add_header("x-relay-token", self.token)
        return urllib.request.urlopen(request, timeout=10)


@contextmanager
def running_relay(
    upstream_base: str,
    token: str = TEST_TOKEN,
    config: Config | None = None,
) -> Iterator[RelayHarness]:
    harness = RelayHarness(upstream_base, token=token, config=config)
    try:
        yield harness
    finally:
        harness.close()


def chat_request(protocol: str = "anthropic") -> dict:
    return {
        "protocol": protocol,
        "payload": {"model": "m", "stream": True, "messages": []},
    }


def anthropic_ocr_tool_use_script(file_id: str = "file-api-123") -> list[str]:
    """中间轮：模型调用 `ocr` 函数工具（由中转服务执行）。"""
    events = [
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "先识别文字"},
        },
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "text_delta", "text": "我先识别文档。"},
        },
        {
            "type": "content_block_start",
            "index": 2,
            "content_block": {
                "type": "tool_use",
                "id": "tool-ocr-1",
                "name": "ocr",
                "input": {},
            },
        },
        {
            "type": "content_block_delta",
            "index": 2,
            "delta": {
                "type": "input_json_delta",
                "partial_json": json.dumps({"file_id": file_id}, ensure_ascii=False),
            },
        },
        {"type": "message_delta", "delta": {"stop_reason": "tool_use"}},
        {"type": "message_stop"},
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def responses_ocr_tool_use_script(file_id: str = "file-api-123") -> list[str]:
    """Responses 协议的中间工具轮（ocr）。"""
    arguments = json.dumps({"file_id": file_id}, ensure_ascii=False)
    events = [
        {"type": "response.reasoning_text.delta", "delta": "先识别"},
        {
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "type": "function_call",
                "id": "fc_1",
                "call_id": "call-1",
                "name": "ocr",
                "arguments": "",
            },
        },
        {
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_1",
            "delta": arguments,
        },
        {"type": "response.output_text.delta", "delta": "我先识别。"},
        {
            "type": "response.completed",
            "response": {
                "output": [
                    {
                        "type": "function_call",
                        "id": "fc_1",
                        "call_id": "call-1",
                        "name": "ocr",
                        "arguments": arguments,
                    }
                ]
            },
        },
    ]
    return [f"data: {json.dumps(event, ensure_ascii=False)}" for event in events]


def test_healthz_reports_state() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.get("/healthz") as response:
                data = json.loads(response.read())
            assert response.status == 200
            assert data["status"] == "ok"
            assert data["jobs"] == 0
            assert data["active_jobs"] == 0
            assert data["tools"] == ["search", "fetch"]


def test_chat_streams_then_snapshot_returns_full_result() -> None:
    with FakeUpstream(lines=anthropic_script(with_source=True)) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post(
                "/v1/chat", chat_request(), {"x-api-key": "sk-1"}
            ) as response:
                raw = response.read().decode("utf-8")
            assert response.status == 200
            assert response.headers["Content-Type"].startswith("text/event-stream")
            lines = [line for line in raw.split("\n") if line.startswith("data: ")]
            first = json.loads(lines[0][len("data: ") :])
            assert first["type"] == "__job"
            assert first["protocol"] == "anthropic"
            assert any("message_stop" in line for line in lines[1:])
            assert upstream.requests[0]["headers"]["x-api-key"] == "sk-1"

            job_id = first["job_id"]
            with relay.get(f"/v1/jobs/{job_id}") as snapshot_response:
                snapshot = json.loads(snapshot_response.read())
            # 断线后依旧能补齐完整结果（服务端已完成生成）
            assert snapshot["status"] == "done"
            assert snapshot["content"] == "你好"
            assert snapshot["reasoning"] == "思考中"
            assert snapshot["sources"][0]["url"] == "https://example.com/a"


def test_chat_rejects_bad_requests() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as missing_payload:
                relay.post("/v1/chat", {"protocol": "anthropic"})
            assert missing_payload.value.code == 400

            bad_json = urllib.request.Request(
                f"{relay.base}/v1/chat",
                data="{不是 json".encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "x-relay-token": relay.token,
                },
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as bad_json_error:
                urllib.request.urlopen(bad_json, timeout=10)
            assert bad_json_error.value.code == 400

            no_body = urllib.request.Request(
                f"{relay.base}/v1/chat",
                data=b"",
                headers={"Content-Length": "0", "x-relay-token": relay.token},
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as no_body_error:
                urllib.request.urlopen(no_body, timeout=10)
            assert no_body_error.value.code == 400

            array_body = urllib.request.Request(
                f"{relay.base}/v1/chat",
                data=b"[1,2,3]",
                headers={
                    "Content-Type": "application/json",
                    "x-relay-token": relay.token,
                },
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as array_error:
                urllib.request.urlopen(array_body, timeout=10)
            assert array_error.value.code == 400


def test_chat_relays_upstream_error_and_custom_upstream() -> None:
    with FakeUpstream(status=400, error_message="max_tokens 必须是整数") as upstream:
        with running_relay("http://127.0.0.1:1") as relay:
            with pytest.raises(urllib.error.HTTPError) as error:
                relay.post(
                    "/v1/chat",
                    chat_request(),
                    {"x-upstream-base": upstream.base_url},
                )
            assert error.value.code == 400
            body = json.loads(error.value.read())
            assert body["error"]["message"] == "max_tokens 必须是整数"


def test_invalid_upstream_override_header() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as error:
                relay.post(
                    "/v1/chat", chat_request(), {"x-upstream-base": "ftp://bad"}
                )
            assert error.value.code == 400


def test_unknown_job_and_cancel_and_route() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as missing:
                relay.get("/v1/jobs/0123456789abcdef")
            assert missing.value.code == 404

            with pytest.raises(urllib.error.HTTPError) as cancel:
                relay.post("/v1/jobs/0123456789abcdef/cancel", {})
            assert cancel.value.code == 404

            with pytest.raises(urllib.error.HTTPError) as not_found:
                relay.get("/nope")
            assert not_found.value.code == 404

            with pytest.raises(urllib.error.HTTPError) as post_not_found:
                relay.post("/nope", {})
            assert post_not_found.value.code == 404


def test_cancel_running_job_through_api() -> None:
    # 上游发完内容后一直挂着，任务保持 running，便于演示“断线仍在生成”
    lines = anthropic_script()[:-1]
    with FakeUpstream(lines=lines, hold_seconds=30.0) as upstream:
        with running_relay(upstream.base_url) as relay:
            response = relay.post("/v1/chat", chat_request())
            header_line = response.readline().decode("utf-8").strip()
            response.readline()  # 事件之间的空行
            job_id = json.loads(header_line[len("data: ") :])["job_id"]

            with relay.get(f"/v1/jobs/{job_id}") as snapshot_response:
                snapshot = json.loads(snapshot_response.read())
            assert snapshot["status"] == "running"
            assert snapshot["content"] == "你好"

            with relay.post(f"/v1/jobs/{job_id}/cancel", {}) as cancel_response:
                assert json.loads(cancel_response.read()) == {"canceled": True}

            # 取消后服务端结束流，客户端连接随之关闭
            response.read()
            response.close()
            with relay.get(f"/v1/jobs/{job_id}") as final_response:
                final = json.loads(final_response.read())
            assert final["status"] == "canceled"


def test_conversation_and_message_endpoints() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            # 新建会话
            with relay.post(
                "/v1/conversations",
                {"title": "标题", "model": "m", "system_prompt": "你是猫"},
            ) as res:
                conv_id = json.loads(res.read())["id"]
            assert conv_id > 0

            # 追加消息（含来源与思考用时）
            for index in range(5):
                body = {
                    "role": "user" if index % 2 == 0 else "assistant",
                    "content": f"第{index}条",
                    "reasoning": "思考" if index == 1 else "",
                    "reasoning_ms": 100 if index == 1 else 0,
                    "sources": [{"title": "T", "url": "https://e.com"}]
                    if index == 1
                    else [],
                }
                with relay.post(
                    f"/v1/conversations/{conv_id}/messages", body
                ) as res:
                    assert json.loads(res.read())["id"] > 0

            # 分页：先拿最新 2 条，再往前翻
            with relay.get(
                f"/v1/conversations/{conv_id}/messages?limit=2"
            ) as res:
                page = json.loads(res.read())
            assert [m["content"] for m in page["items"]] == ["第3条", "第4条"]
            assert page["has_more"] is True

            with relay.get(
                f"/v1/conversations/{conv_id}/messages"
                f"?limit=2&before_id={page['oldest_id']}"
            ) as res:
                older = json.loads(res.read())
            assert [m["content"] for m in older["items"]] == ["第1条", "第2条"]
            assert older["items"][0]["reasoning"] == "思考"
            assert older["items"][0]["reasoning_ms"] == 100
            assert older["items"][0]["sources"][0]["url"] == "https://e.com"

            # 会话列表分页
            with relay.get("/v1/conversations?limit=1") as res:
                conversations = json.loads(res.read())
            assert len(conversations["items"]) == 1
            assert conversations["items"][0]["id"] == conv_id
            assert conversations["items"][0]["preview"]
            assert conversations["items"][0]["system_prompt"] == "你是猫"

            # 搜索
            with relay.get(
                f"/v1/search?q={urllib.parse.quote('第3条')}"
            ) as res:
                hits = json.loads(res.read())["items"]
            assert len(hits) == 1
            assert hits[0]["conversation_id"] == conv_id
            assert hits[0]["matches"] == [0]

            # 重命名与删除
            with relay.patch(
                f"/v1/conversations/{conv_id}", {"title": "改名"}
            ) as res:
                assert json.loads(res.read()) == {"updated": True}
            # 系统提示词写入（最新值覆盖旧值，空串表示回到默认）
            with relay.patch(
                f"/v1/conversations/{conv_id}", {"system_prompt": "你是狗"}
            ) as res:
                assert json.loads(res.read()) == {"updated": True}
            with relay.get("/v1/conversations?limit=1") as res:
                after = json.loads(res.read())["items"][0]
            assert after["title"] == "改名"
            assert after["system_prompt"] == "你是狗"
            with relay.patch(
                f"/v1/conversations/{conv_id}", {"system_prompt": ""}
            ) as res:
                assert json.loads(res.read()) == {"updated": True}
            with pytest.raises(urllib.error.HTTPError) as empty_patch:
                relay.patch(f"/v1/conversations/{conv_id}", {})
            assert empty_patch.value.code == 400
            with relay.delete(f"/v1/conversations/{conv_id}") as res:
                assert json.loads(res.read()) == {"deleted": True}
            with pytest.raises(urllib.error.HTTPError) as missing:
                relay.patch(f"/v1/conversations/{conv_id}", {"title": "x"})
            assert missing.value.code == 404


def test_chat_with_conversation_stores_answer() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post("/v1/conversations", {"title": "问答", "model": "m"}) as res:
                conv_id = json.loads(res.read())["id"]
            with relay.post(
                f"/v1/conversations/{conv_id}/messages",
                {"role": "user", "content": "你好"},
            ):
                pass

            request = chat_request()
            request["conversation_id"] = conv_id
            with relay.post("/v1/chat", request) as response:
                raw = response.read().decode("utf-8")
            job_id = json.loads(
                [line for line in raw.split("\n") if line.startswith("data: ")][0][6:]
            )["job_id"]

            # 服务端在任务结束后已把回答写进会话存储
            with relay.get(f"/v1/jobs/{job_id}") as res:
                snapshot = json.loads(res.read())
            assert snapshot["status"] == "done"
            assert snapshot["stored_message_id"] is not None

            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            roles = [m["role"] for m in page["items"]]
            assert roles == ["user", "assistant"]
            assert page["items"][1]["content"] == "你好"
            assert page["items"][1]["reasoning"] == "思考中"
            assert page["items"][1]["id"] == snapshot["stored_message_id"]


def test_bulk_messages_and_truncate_endpoints() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post("/v1/conversations", {"title": "导入", "model": "m"}) as res:
                conv_id = json.loads(res.read())["id"]
            with relay.post(
                f"/v1/conversations/{conv_id}/messages/bulk",
                {
                    "messages": [
                        {"role": "user", "content": "一"},
                        {"role": "assistant", "content": "二"},
                        {"role": "user", "content": "三"},
                    ]
                },
            ) as res:
                ids = json.loads(res.read())["ids"]
                assert len(ids) == 3

            # 同时带 before_id 和 keep（旧版参数）时，新版必须以 before_id 为准。
            # 旧版客户端/服务器升级期间不会因为 keep=0 被误清空。
            with relay.post(
                f"/v1/conversations/{conv_id}/truncate",
                {"before_id": ids[2], "keep": 0},
            ) as res:
                assert json.loads(res.read()) == {"deleted": 1}
            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assert [m["content"] for m in page["items"]] == ["一", "二"]

            with relay.post(
                f"/v1/conversations/{conv_id}/truncate", {"keep": 1}
            ) as res:
                assert json.loads(res.read()) == {"deleted": 1}
            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assert [m["content"] for m in page["items"]] == ["一"]

            with pytest.raises(urllib.error.HTTPError) as bad_bulk:
                relay.post(
                    f"/v1/conversations/{conv_id}/messages/bulk",
                    {"messages": "不是数组"},
                )
            assert bad_bulk.value.code == 400


def test_active_job_endpoint_for_resume() -> None:
    # 上游发完内容后挂住，任务保持 running，便于按会话恢复
    lines = anthropic_script()[:-1]
    with FakeUpstream(lines=lines, hold_seconds=30.0) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post("/v1/conversations", {"title": "恢复", "model": "m"}) as res:
                conv_id = json.loads(res.read())["id"]

            with pytest.raises(urllib.error.HTTPError) as no_job:
                relay.get(f"/v1/conversations/{conv_id}/active_job")
            assert no_job.value.code == 404

            request = chat_request()
            request["conversation_id"] = conv_id
            response = relay.post("/v1/chat", request)
            header_line = response.readline().decode("utf-8").strip()
            response.readline()
            job_id = json.loads(header_line[len("data: ") :])["job_id"]

            with relay.get(
                f"/v1/conversations/{conv_id}/active_job"
            ) as active:
                data = json.loads(active.read())
            assert data["job_id"] == job_id
            assert data["status"] == "running"

            relay.post(f"/v1/jobs/{job_id}/cancel", {})
            response.read()
            response.close()
            with pytest.raises(urllib.error.HTTPError) as gone:
                relay.get(f"/v1/conversations/{conv_id}/active_job")
            assert gone.value.code == 404


def test_token_is_required_when_configured() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url, token="s3cret-token") as relay:
            # 带对口令：正常
            with relay.get("/v1/conversations") as res:
                assert res.status == 200

            # 不带 / 带错口令：401
            for headers in ({}, {"x-relay-token": "wrong"}):
                request = urllib.request.Request(f"{relay.base}/v1/conversations")
                for name, value in headers.items():
                    request.add_header(name, value)
                with pytest.raises(urllib.error.HTTPError) as err:
                    urllib.request.urlopen(request, timeout=10)
                assert err.value.code == 401
                body = json.loads(err.value.read())
                assert body["error"]["message"] == "服务器口令不正确"

            # healthz 不需要口令（容器健康检查）
            with urllib.request.urlopen(f"{relay.base}/healthz", timeout=10) as res:
                assert res.status == 200

            # 聊天接口同样受保护
            request = urllib.request.Request(
                f"{relay.base}/v1/chat",
                data=json.dumps(chat_request()).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as chat_err:
                urllib.request.urlopen(request, timeout=10)
            assert chat_err.value.code == 401


def test_stream_checkpoint_survives_before_job_finishes() -> None:
    """任务还在跑时 checkpoint 就能查到；结束后也只保留同一条助手消息。"""
    # 去掉 message_stop，让任务保持 running；上游收到最后一行后挂住。
    lines = anthropic_script(content="第一段")[:-1]
    with FakeUpstream(lines=lines, hold_seconds=3.0) as upstream:
        config = Config(
            upstream_base=upstream.base_url,
            checkpoint_interval=0.0,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            with relay.post(
                "/v1/conversations", {"title": "续写", "model": "m"}
            ) as res:
                conv_id = json.loads(res.read())["id"]

            request = chat_request()
            request["conversation_id"] = conv_id
            result: dict[str, object] = {}

            def run_chat() -> None:
                try:
                    with relay.post(
                        "/v1/chat", request, {"x-api-key": "sk-1"}
                    ) as response:
                        response.read()
                    result["done"] = True
                except Exception as exc:  # noqa: BLE001 - 失败信息给断言用
                    result["error"] = exc

            thread = threading.Thread(target=run_chat, daemon=True)
            thread.start()
            deadline = time.time() + 5.0
            assistant = None
            while time.time() < deadline:
                with relay.get(
                    f"/v1/conversations/{conv_id}/messages"
                ) as res:
                    page = json.loads(res.read())
                assistant = next(
                    (
                        item
                        for item in page["items"]
                        if item["role"] == "assistant"
                    ),
                    None,
                )
                if assistant is not None and assistant["content"] == "第一段":
                    break
                time.sleep(0.05)

            # 任务还没结束，checkpoint 行已经写入存储。
            assert assistant is not None
            assert assistant["content"] == "第一段"

            thread.join(timeout=10)
            assert "error" not in result
            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assistants = [
                item for item in page["items"] if item["role"] == "assistant"
            ]
            assert len(assistants) == 1
            assert assistants[0]["content"] == "第一段"


def test_stream_checkpoint_keeps_reasoning_before_content() -> None:
    """只有思考、正文还没出来时也要 checkpoint，思考内容不能等到有正文才存。"""
    # 只发思考增量，然后挂住：任务保持 running，正文为空。
    lines = anthropic_script()[:2]
    with FakeUpstream(lines=lines, hold_seconds=3.0) as upstream:
        config = Config(
            upstream_base=upstream.base_url,
            checkpoint_interval=0.0,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            with relay.post(
                "/v1/conversations", {"title": "思考中", "model": "m"}
            ) as res:
                conv_id = json.loads(res.read())["id"]

            request = chat_request()
            request["conversation_id"] = conv_id
            result: dict[str, object] = {}

            def run_chat() -> None:
                try:
                    with relay.post(
                        "/v1/chat", request, {"x-api-key": "sk-1"}
                    ) as response:
                        response.read()
                    result["done"] = True
                except Exception as exc:  # noqa: BLE001 - 失败信息给断言用
                    result["error"] = exc

            thread = threading.Thread(target=run_chat, daemon=True)
            thread.start()
            deadline = time.time() + 5.0
            assistant = None
            while time.time() < deadline:
                with relay.get(
                    f"/v1/conversations/{conv_id}/messages"
                ) as res:
                    page = json.loads(res.read())
                assistant = next(
                    (
                        item
                        for item in page["items"]
                        if item["role"] == "assistant"
                    ),
                    None,
                )
                if assistant is not None and assistant["reasoning"] == "思考中":
                    break
                time.sleep(0.05)

            assert assistant is not None
            assert assistant["reasoning"] == "思考中"
            assert assistant["content"] == ""

            thread.join(timeout=10)
            assert "error" not in result


def test_web_search_runs_on_upstream_and_sources_reach_snapshot() -> None:
    """联网搜索由**上游服务端**执行：中转不再自己跑工具循环。

    客户端只发一次 /v1/chat，上游一次请求就把 server_tool_use +
    web_search_tool_result + 正文流回来；中转只负责解析并落库。
    """
    script = anthropic_server_search_script(content="搜到了，答案在这。")
    with FakeUpstream(lines=script) as upstream:
        config = Config(
            upstream_base=upstream.base_url,
            checkpoint_interval=0.0,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            with relay.post(
                "/v1/conversations", {"title": "搜索", "model": "m"}
            ) as res:
                conv_id = json.loads(res.read())["id"]

            request = chat_request()
            request["conversation_id"] = conv_id
            request["payload"]["tools"] = [
                {"type": "deepseek_web_search", "name": "deepseek_web_search"},
                {"type": "deepseek_read_url", "name": "deepseek_read_url"},
            ]
            with relay.post(
                "/v1/chat", request, {"x-api-key": "sk-1"}
            ) as response:
                stream = response.read().decode("utf-8")

            # 只发了 1 次上游请求：搜索是上游自己执行的
            chat_requests = [
                item
                for item in upstream.requests
                if item["path"].endswith("/messages")
                or item["path"].endswith("/responses")
            ]
            assert len(chat_requests) == 1
            # 中转不再调 /v1/tools/search 跑工具循环
            assert not any(
                item["path"] == "/v1/tools/search"
                for item in upstream.requests
            )
            # 工具声明完全由客户端决定：服务端不塞任何工具
            assert chat_requests[0]["body"]["tools"] == request["payload"]["tools"]
            # 客户端只收到一次终止事件
            assert stream.count("message_stop") == 1

            job_id = json.loads(
                [line for line in stream.split("\n") if line.startswith("data: ")][0][6:]
            )["job_id"]
            with relay.get(f"/v1/jobs/{job_id}") as res:
                snapshot = json.loads(res.read())

            # 来源：旧字段在，新字段补齐
            assert [s["url"] for s in snapshot["sources"]] == [
                "https://example.com/a",
                "https://example.com/b",
            ]
            assert snapshot["sources"][0]["site_name"] == "示例站点"
            assert snapshot["sources"][0]["snippet"] == "这是摘要"
            assert snapshot["sources"][0]["page_age"] == "2026-11-01T08:00:00Z"
            # 新增 steps / citations
            assert snapshot["steps"][0]["kind"] == "search"
            assert snapshot["steps"][0]["query"] == "DeepSeek 全家桶"
            assert snapshot["steps"][0]["status"] == "done"
            assert snapshot["citations"][0]["url"] == "https://example.com/a"

            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assistants = [
                item for item in page["items"] if item["role"] == "assistant"
            ]
            assert len(assistants) == 1
            assert assistants[0]["content"] == "搜到了，答案在这。"
            assert assistants[0]["pending"] is False
            assert assistants[0]["sources"][0]["site_name"] == "示例站点"


def test_web_search_responses_protocol_runs_on_upstream() -> None:
    """Responses 协议：web_search_call item 解析成 steps 与来源。"""
    script = responses_web_search_script(content="搜到了，答案在这。")
    with FakeUpstream(lines=script) as upstream:
        config = Config(
            upstream_base=upstream.base_url,
            checkpoint_interval=0.0,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            with relay.post(
                "/v1/conversations", {"title": "搜索", "model": "m"}
            ) as res:
                conv_id = json.loads(res.read())["id"]
            request = chat_request("responses")
            request["conversation_id"] = conv_id
            request["payload"]["tools"] = [{"type": "deepseek_web_search"}]
            with relay.post(
                "/v1/chat", request, {"x-api-key": "sk-1"}
            ) as response:
                stream = response.read().decode("utf-8")

            assert stream.count("response.completed") == 1
            assert not any(
                item["path"] == "/v1/tools/search"
                for item in upstream.requests
            )
            job_id = json.loads(
                [line for line in stream.split("\n") if line.startswith("data: ")][0][6:]
            )["job_id"]
            with relay.get(f"/v1/jobs/{job_id}") as res:
                snapshot = json.loads(res.read())
            assert snapshot["steps"][0]["kind"] == "search"
            assert snapshot["steps"][0]["signature"] == "sig-ws-1"
            assert [s["url"] for s in snapshot["sources"]] == [
                "https://example.com/a",
                "https://example.com/b",
            ]
            assert snapshot["citations"][0]["url"] == "https://example.com/a"

            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assistants = [
                item for item in page["items"] if item["role"] == "assistant"
            ]
            assert len(assistants) == 1
            assert assistants[0]["content"] == "搜到了，答案在这。"
            assert assistants[0]["pending"] is False


def test_tools_search_and_fetch_proxy() -> None:
    """官方 Search / Fetch 接口由中转原样转发，鉴权头透传。"""
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post(
                "/v1/tools/search",
                {"query": "DeepSeek 搜索", "count": 5, "need_content": True},
                {"Authorization": "Bearer sk-tool"},
            ) as response:
                assert response.status == 200
                data = json.loads(response.read())
            assert [item["url"] for item in data["results"]] == [
                "https://example.com/a",
                "https://example.com/b",
            ]
            assert upstream.requests[0]["path"] == "/v1/tools/search"
            assert (
                upstream.requests[0]["headers"]["authorization"]
                == "Bearer sk-tool"
            )
            assert upstream.requests[0]["body"]["query"] == "DeepSeek 搜索"
            assert upstream.requests[0]["body"]["need_content"] is True

            with relay.post(
                "/v1/tools/fetch",
                {"url": "https://example.com/a"},
                {"Authorization": "Bearer sk-tool"},
            ) as response:
                page = json.loads(response.read())
            assert page["title"] == "示例文章"
            assert "正文内容" in page["content"]
            assert upstream.requests[1]["path"] == "/v1/tools/fetch"


def test_tools_accepts_x_api_key_and_requires_key() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post(
                "/v1/tools/search",
                {"query": "hello"},
                {"x-api-key": "sk-from-header"},
            ) as response:
                assert response.status == 200
            assert (
                upstream.requests[0]["headers"]["authorization"]
                == "Bearer sk-from-header"
            )

            with pytest.raises(urllib.error.HTTPError) as missing:
                relay.post("/v1/tools/search", {"query": "hello"})
            assert missing.value.code == 401
            body = json.loads(missing.value.read())
            assert "API Key" in body["error"]["message"]


def test_tools_validation_errors() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            headers = {"Authorization": "Bearer sk-tool"}
            cases = [
                ("/v1/tools/search", {}),
                ("/v1/tools/search", {"query": "   "}),
                ("/v1/tools/search", {"query": "x" * 129}),
                ("/v1/tools/search", {"query": "ok", "count": True}),
                ("/v1/tools/fetch", {}),
                ("/v1/tools/fetch", {"url": "ftp://example.com"}),
                ("/v1/tools/fetch", {"url": "http://user:pass@example.com"}),
            ]
            for path, payload in cases:
                with pytest.raises(urllib.error.HTTPError) as error:
                    relay.post(path, payload, headers)
                assert error.value.code == 400, (path, payload)
                body = json.loads(error.value.read())
                assert body["error"]["message"]

            # count 不再限制 1~50：原样转给上游
            for count in (0, 51, 200):
                with relay.post(
                    "/v1/tools/search",
                    {"query": "ok", "count": count},
                    headers,
                ) as response:
                    assert response.status == 200
                assert upstream.requests[-1]["body"]["count"] == count

            array_body = urllib.request.Request(
                f"{relay.base}/v1/tools/search",
                data=b"[1,2,3]",
                headers={
                    "Content-Type": "application/json",
                    "x-relay-token": relay.token,
                    **headers,
                },
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as array_error:
                urllib.request.urlopen(array_body, timeout=10)
            assert array_error.value.code == 400


def test_tools_upstream_error_passthrough() -> None:
    with FakeUpstream(
        tools_status=429, error_message="超过 QPS 限制"
    ) as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as error:
                relay.post(
                    "/v1/tools/search",
                    {"query": "hello"},
                    {"Authorization": "Bearer sk-tool"},
                )
            assert error.value.code == 429
            body = json.loads(error.value.read())
            assert body["error"]["message"] == "超过 QPS 限制"


def test_tools_custom_upstream_and_invalid_override() -> None:
    with FakeUpstream() as upstream:
        with running_relay("http://127.0.0.1:1") as relay:
            with relay.post(
                "/v1/tools/fetch",
                {"url": "https://example.com/a"},
                {
                    "Authorization": "Bearer sk-tool",
                    "x-upstream-base": upstream.base_url,
                },
            ) as response:
                assert response.status == 200
            assert upstream.requests[0]["path"] == "/v1/tools/fetch"

            with pytest.raises(urllib.error.HTTPError) as invalid:
                relay.post(
                    "/v1/tools/search",
                    {"query": "hello"},
                    {
                        "Authorization": "Bearer sk-tool",
                        "x-upstream-base": "ftp://bad",
                    },
                )
            assert invalid.value.code == 400


def test_tools_require_relay_token_when_configured() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url, token="s3cret-token") as relay:
            request = urllib.request.Request(
                f"{relay.base}/v1/tools/search",
                data=json.dumps({"query": "hello"}).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer sk-tool",
                },
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(request, timeout=10)
            assert error.value.code == 401
            assert upstream.requests == []

            with relay.post(
                "/v1/tools/search",
                {"query": "hello"},
                {"Authorization": "Bearer sk-tool"},
            ) as response:
                assert response.status == 200


def test_token_hash_config_resolution(monkeypatch) -> None:
    """只给明文 RELAY_TOKEN 时就地哈希；给了哈希则直接使用（服务端不存明文）。"""
    expected = hashlib.sha256(b"abc123").hexdigest()
    monkeypatch.delenv("RELAY_TOKEN_HASH", raising=False)
    monkeypatch.setenv("RELAY_TOKEN", "abc123")
    assert Config.from_env().relay_token_hash == expected

    monkeypatch.setenv("RELAY_TOKEN_HASH", expected.upper())
    assert Config.from_env().relay_token_hash == expected

    monkeypatch.delenv("RELAY_TOKEN_HASH")
    monkeypatch.delenv("RELAY_TOKEN")
    assert Config.from_env().relay_token_hash == ""


def test_server_refuses_to_start_without_token() -> None:
    """没配口令必须起不来：不能退化成“对公网全放行”。"""
    with pytest.raises(ConfigError):
        build_server(Config(host="127.0.0.1", port=0, db_path=":memory:"))

    with pytest.raises(ConfigError):
        require_token_hash(Config(relay_token_hash="   "))

    # 非十六进制/长度不对的哈希同样拒绝（避免把明文当哈希塞进来）
    with pytest.raises(ConfigError):
        require_token_hash(Config(relay_token_hash="not-a-sha256"))


def test_unconfigured_token_never_opens_the_api() -> None:
    """绕过启动检查直接建服务器时，/v1 也必须拒绝，而不是放行。"""
    server = RelayServer(
        ("127.0.0.1", 0),
        Config(relay_token_hash=""),
        store=ChatStore(":memory:"),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address[:2]
        base = f"http://{host}:{port}"
        with pytest.raises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(f"{base}/v1/conversations", timeout=10)
        assert error.value.code == 503
        assert "未配置访问口令" in json.loads(error.value.read())["error"]["message"]
        # healthz 仍可用，容器健康检查与探活不受影响
        with urllib.request.urlopen(f"{base}/healthz", timeout=10) as res:
            assert res.status == 200
    finally:
        server.shutdown()
        server.server_close()
        server.store.close()
        thread.join(timeout=5)


# ------------------------------------------------- Files / OCR / ASR / TTS

def multipart_body(
    fields: list[tuple[str, str]],
    files: list[tuple[str, str, str, bytes]],
    boundary: str = "----testboundary1234",
) -> tuple[bytes, str]:
    """按官方要求的字段顺序拼 multipart（purpose 在前、file 在后）。"""
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            ).encode("utf-8")
        )
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")
    for name, filename, content_type, data in files:
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"; '
                f'filename="{filename}"\r\n'
                f"Content-Type: {content_type}\r\n\r\n"
            ).encode("utf-8")
        )
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"


def test_healthz_reports_capabilities() -> None:
    """`capabilities` 列出已接通的代理能力，便于客户端降级。"""
    with FakeUpstream(lines=anthropic_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.get("/healthz") as response:
                data = json.loads(response.read())
    assert set(data["capabilities"]) >= {
        "files",
        "ocr",
        "asr",
        "tts",
        "web_search",
        "read_url",
    }
    # 旧字段一个不少
    assert data["tools"] == ["search", "fetch"]
    assert data["files"]["files"] == 0


def test_files_upload_forwards_multipart_faithfully_and_caches() -> None:
    """`POST /v1/files`：请求体与 boundary 原样透传，成功时缓存字节。"""
    payload = b"%PDF-1.7\nfake pdf bytes \xff\xfe\x00\x01"
    body, content_type = multipart_body(
        [("purpose", "text_recognition")],
        [("file", "a.pdf", "application/pdf", payload)],
    )
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            status, raw, _headers = relay.post_raw(
                "/v1/files",
                body,
                content_type,
                {"Authorization": "Bearer sk-files"},
            )
            assert status == 200
            data = json.loads(raw)
            assert data["id"] == "file-api-123"
            # 缓存已写入（键为上游返回的 id）
            assert relay.server.file_cache.get("file-api-123") is not None
            assert relay.server.file_cache.get("file-api-123").data == payload

            # 上游收到的字节与 Content-Type 完全一致（没有重新编码）
            sent = upstream.requests[0]
            assert sent["path"] == "/files"
            assert sent["raw"] == body
            assert sent["content_type"] == content_type
            assert sent["headers"]["authorization"] == "Bearer sk-files"


def test_files_upload_requires_api_key_and_relay_token() -> None:
    body, content_type = multipart_body(
        [("purpose", "user_data")], [("file", "a.txt", "text/plain", b"hi")]
    )
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as missing:
                relay.post_raw("/v1/files", body, content_type)
            assert missing.value.code == 401
            assert "API Key" in json.loads(missing.value.read())["error"]["message"]
            assert upstream.requests == []

        with running_relay(upstream.base_url, token="s3cret-token") as relay:
            request = urllib.request.Request(
                f"{relay.base}/v1/files",
                data=body,
                headers={
                    "Content-Type": content_type,
                    "Authorization": "Bearer sk-files",
                },
                method="POST",
            )
            with pytest.raises(urllib.error.HTTPError) as no_token:
                urllib.request.urlopen(request, timeout=10)
            assert no_token.value.code == 401
            assert upstream.requests == []


def test_files_list_proxies_get() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.get(
                "/v1/files", {"Authorization": "Bearer sk-files"}
            ) as response:
                data = json.loads(response.read())
            assert data["data"][0]["id"] == "file-api-123"
            assert upstream.requests[0]["method"] == "GET"
            assert upstream.requests[0]["path"] == "/files"
            assert upstream.requests[0]["headers"]["authorization"] == (
                "Bearer sk-files"
            )


def test_ocr_and_asr_multipart_forwarding() -> None:
    """OCR / ASR：multipart 进、JSON 出，请求体原样转发。"""
    ocr_body, ocr_type = multipart_body(
        [("purpose", "rich_layout_recognition")],
        [("file", "scan.png", "image/png", b"\x89PNG\r\n\x1a\n")],
    )
    asr_body, asr_type = multipart_body(
        [], [("file", "voice.wav", "audio/wav", FAKE_WAV)]
    )
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            status, raw, _headers = relay.post_raw(
                "/v1/tools/ocr", ocr_body, ocr_type, {"x-api-key": "sk-x"}
            )
            assert status == 200
            ocr = json.loads(raw)
            assert ocr["page_count"] == 2
            assert ocr["pages"][0]["text"] == "第一页内容"
            sent = upstream.requests[0]
            assert sent["path"] == "/v1/tools/ocr"
            assert sent["raw"] == ocr_body
            assert sent["content_type"] == ocr_type
            # x-api-key 转成 Bearer 再给上游
            assert sent["headers"]["authorization"] == "Bearer sk-x"

            status, raw, _headers = relay.post_raw(
                "/v1/tools/asr", asr_body, asr_type, {"x-api-key": "sk-x"}
            )
            assert status == 200
            assert json.loads(raw)["text"] == "识别出来的话"
            sent = upstream.requests[1]
            assert sent["path"] == "/v1/tools/asr"
            assert sent["raw"] == asr_body


def test_ocr_requires_multipart_content_type() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            with pytest.raises(urllib.error.HTTPError) as error:
                relay.post(
                    "/v1/tools/ocr",
                    {"file": "x"},
                    {"Authorization": "Bearer sk-x"},
                )
            assert error.value.code == 400
            assert "multipart" in json.loads(error.value.read())["error"]["message"]
            assert upstream.requests == []


def test_tts_binary_passthrough() -> None:
    """TTS：响应体是音频字节，必须原样透传（不能 UTF-8 解码再编码）。"""
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            status, raw, headers = relay.post_raw(
                "/v1/tools/tts",
                json.dumps(
                    {
                        "text": "你好世界",
                        "voice_id": "stella",
                        "format": "wav",
                        "filter_markdown": True,
                    }
                ).encode("utf-8"),
                "application/json",
                {"Authorization": "Bearer sk-tts"},
            )
            # 任务化：提交返回 202 + 任务号，合成在后台完成
            assert status == 202
            job = json.loads(raw)
            assert job["status"] in ("pending", "running", "done")
            job_id = job["job_id"]

            # 轮询到 done（后台线程需要一点时间打到上游），再按 audio_id 取字节
            deadline = time.time() + 10
            audio_id = None
            while time.time() < deadline:
                poll = json.loads(relay.get(f"/v1/tts-jobs/{job_id}").read())
                if poll["status"] == "done":
                    audio_id = poll["audio_id"]
                    break
                assert poll["status"] in ("pending", "running")
                time.sleep(0.05)
            assert audio_id, "任务没有在 10 秒内完成"

            sent = upstream.requests[0]
            assert sent["path"] == "/v1/tools/tts"
            assert sent["body"]["voice_id"] == "stella"
            assert sent["body"]["filter_markdown"] is True
            assert sent["headers"]["authorization"] == "Bearer sk-tts"

            status2, raw2, headers2 = relay.get_raw(f"/v1/audio/{audio_id}")
            assert status2 == 200
            # 字节完全一致：包含 0xff 0xfe 等非法 UTF-8 序列
            assert raw2 == FAKE_WAV
            assert raw2.startswith(b"RIFF")
            lowered = {name.lower(): value for name, value in headers2.items()}
            assert lowered["content-type"] == "audio/wav"


def test_tts_validation_and_upstream_error() -> None:
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            headers = {"Authorization": "Bearer sk-tts"}
            cases = [
                ({"text": ""}, "text"),
                ({"text": "x" * 10001}, "10000"),
                ({"text": "hi", "voice_id": "unknown"}, "voice_id"),
                ({"text": "hi", "format": "mp3"}, "format"),
                # 裸 pcm 已废弃：没有容器头，客户端落盘 .wav 播放器无法播放
                ({"text": "hi", "format": "pcm"}, "format"),
            ]
            for payload, keyword in cases:
                with pytest.raises(urllib.error.HTTPError) as error:
                    relay.post("/v1/tools/tts", payload, headers)
                assert error.value.code == 400
                assert keyword in json.loads(error.value.read())["error"]["message"]
            assert upstream.requests == []

    # 上游失败：提交仍返回 202，任务转为 error 并带上可读原因
    # （合成不可中断——失败也是后台完成的，客户端轮询拿到错误）
    with FakeUpstream(status=402, error_message="余额不足") as upstream:
        with running_relay(upstream.base_url) as relay:
            res = relay.post(
                "/v1/tools/tts",
                {"text": "hi"},
                {"Authorization": "Bearer sk-tts"},
            )
            job_id = json.loads(res.read())["job_id"]
            deadline = time.time() + 10
            poll = None
            while time.time() < deadline:
                poll = json.loads(
                    relay.get(f"/v1/tts-jobs/{job_id}").read()
                )
                if poll["status"] in ("done", "error"):
                    break
                time.sleep(0.05)
            assert poll is not None and poll["status"] == "error"
            assert "余额不足" in poll["error"]


def test_ocr_tool_call_fills_text_back_to_model() -> None:
    """模型调用 ocr：服务端从缓存取字节、调上游 OCR、把逐页文本回填。"""
    payload = b"%PDF-1.7 fake"
    upload_body, upload_type = multipart_body(
        [("purpose", "text_recognition")],
        [("file", "a.pdf", "application/pdf", payload)],
    )
    scripts = [anthropic_ocr_tool_use_script(), anthropic_script(content="最终回答")]
    with FakeUpstream(scripts=scripts) as upstream:
        config = Config(
            upstream_base=upstream.base_url,
            checkpoint_interval=0.0,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            # 先上传，缓存里才有字节
            relay.post_raw(
                "/v1/files", upload_body, upload_type, {"x-api-key": "sk-1"}
            )
            with relay.post(
                "/v1/conversations", {"title": "OCR", "model": "m"}
            ) as res:
                conv_id = json.loads(res.read())["id"]

            request = chat_request()
            request["conversation_id"] = conv_id
            request["payload"]["tools"] = [
                {"type": "function", "name": "ocr", "parameters": {}}
            ]
            with relay.post(
                "/v1/chat", request, {"x-api-key": "sk-1"}
            ) as response:
                stream = response.read().decode("utf-8")

            # 两轮上游请求：模型先要 ocr，服务端执行后继续
            chat_requests = [
                item
                for item in upstream.requests
                if item["path"].endswith("/messages")
            ]
            assert len(chat_requests) == 2
            ocr_requests = [
                item for item in upstream.requests if item["path"] == "/v1/tools/ocr"
            ]
            assert len(ocr_requests) == 1
            # 服务端自己拼的 multipart：purpose 在前、file 在后
            sent = ocr_requests[0]
            assert sent["content_type"].startswith("multipart/form-data; boundary=")
            purpose_at = sent["raw"].index(b'name="purpose"')
            file_at = sent["raw"].index(b'name="file"')
            assert purpose_at < file_at
            assert payload in sent["raw"]

            # 回填给模型的是逐页拼起来的文本
            second = chat_requests[1]["body"]
            tool_results = [
                block
                for message in second["messages"]
                if message.get("role") == "user"
                for block in (
                    message["content"] if isinstance(message["content"], list) else []
                )
                if isinstance(block, dict) and block.get("type") == "tool_result"
            ]
            assert tool_results
            filled = json.loads(tool_results[0]["content"])
            assert filled["text"] == "第一页内容\n\n第二页内容"
            assert filled["page_count"] == 2
            assert filled["file_id"] == "file-api-123"

            assert stream.count("message_stop") == 1
            with relay.get(f"/v1/conversations/{conv_id}/messages") as res:
                page = json.loads(res.read())
            assistants = [
                item for item in page["items"] if item["role"] == "assistant"
            ]
            assert len(assistants) == 1
            assert assistants[0]["content"] == "我先识别文档。最终回答"
            assert assistants[0]["pending"] is False


def test_ocr_tool_call_for_responses_protocol() -> None:
    payload = b"fake image"
    upload_body, upload_type = multipart_body(
        [("purpose", "text_recognition")],
        [("file", "a.png", "image/png", payload)],
    )
    scripts = [
        responses_ocr_tool_use_script(),
        responses_script("最终回答"),
    ]
    with FakeUpstream(scripts=scripts) as upstream:
        config = Config(upstream_base=upstream.base_url, checkpoint_interval=0.0)
        with running_relay(upstream.base_url, config=config) as relay:
            relay.post_raw(
                "/v1/files", upload_body, upload_type, {"x-api-key": "sk-1"}
            )
            request = chat_request("responses")
            request["payload"]["input"] = [{"role": "user", "content": "看看这个"}]
            with relay.post(
                "/v1/chat", request, {"x-api-key": "sk-1"}
            ) as response:
                stream = response.read().decode("utf-8")

            assert stream.count("response.completed") == 1
            assert any(
                item["path"] == "/v1/tools/ocr" for item in upstream.requests
            )
            # function_call_output 回填了识别文本
            second = [
                item
                for item in upstream.requests
                if item["path"] == "/responses"
            ][1]["body"]
            outputs = [
                item
                for item in second["input"]
                if isinstance(item, dict)
                and item.get("type") == "function_call_output"
            ]
            assert outputs
            assert "第一页内容" in outputs[0]["output"]


def test_ocr_tool_call_without_cached_file_tells_model() -> None:
    """缓存里没有该 file_id 时，明确告诉模型让用户重新上传。"""
    scripts = [
        anthropic_ocr_tool_use_script("file-missing"),
        anthropic_script(content="那我直接回答"),
    ]
    with FakeUpstream(scripts=scripts) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post(
                "/v1/chat", chat_request(), {"x-api-key": "sk-1"}
            ) as response:
                response.read()
            # 没有缓存命中就不该去调上游 OCR
            assert not any(
                item["path"] == "/v1/tools/ocr" for item in upstream.requests
            )
            second = [
                item
                for item in upstream.requests
                if item["path"].endswith("/messages")
            ][1]["body"]
            tool_results = [
                block
                for message in second["messages"]
                if message.get("role") == "user"
                for block in (
                    message["content"] if isinstance(message["content"], list) else []
                )
                if isinstance(block, dict) and block.get("type") == "tool_result"
            ]
            filled = json.loads(tool_results[0]["content"])
            assert "不在服务端缓存" in filled["error"]
            assert "重新上传" in filled["error"]


def test_file_cache_evicts_least_recently_used() -> None:
    """缓存按「总字节 + 条目数」双上限 LRU 淘汰。"""
    from app.filecache import CachedFile, FileCache

    cache = FileCache(max_bytes=10, max_entries=3)
    for index in range(3):
        assert cache.put(
            CachedFile(
                file_id=f"f{index}",
                filename="a.bin",
                content_type="application/octet-stream",
                data=b"xx",
            )
        )
    assert cache.ids() == ["f0", "f1", "f2"]
    # 访问 f0，让它变成最近使用
    assert cache.get("f0") is not None
    assert cache.put(
        CachedFile(
            file_id="f3",
            filename="a.bin",
            content_type="application/octet-stream",
            data=b"xx",
        )
    )
    # 条目数超限：淘汰最久未用的 f1（f0 刚被访问过，挪到了队尾）
    assert cache.ids() == ["f2", "f0", "f3"]
    assert cache.get("f1") is None
    assert cache.evictions == 1

    # 字节数超限：再放一个大文件，继续按 LRU 淘汰
    assert cache.put(
        CachedFile(
            file_id="big",
            filename="a.bin",
            content_type="application/octet-stream",
            data=b"x" * 8,
        )
    )
    assert cache.total_bytes <= 10
    assert "f0" not in cache.ids()

    # 单文件本身就超过总容量：不缓存（否则会把缓存挤空还放不下）
    assert not cache.put(
        CachedFile(
            file_id="huge",
            filename="a.bin",
            content_type="application/octet-stream",
            data=b"x" * 11,
        )
    )
    # 空内容 / 空 id 也不缓存
    assert not cache.put(
        CachedFile(
            file_id="",
            filename="a.bin",
            content_type="application/octet-stream",
            data=b"x",
        )
    )
    assert not cache.put(
        CachedFile(
            file_id="empty",
            filename="a.bin",
            content_type="application/octet-stream",
            data=b"",
        )
    )
    assert cache.discard("f3") is True
    assert cache.discard("f3") is False
    cache.clear()
    assert len(cache) == 0
    assert cache.stats()["files"] == 0


def test_file_cache_respects_config_limits() -> None:
    """`/healthz` 里的 files 统计来自配置的上限。"""
    from app.config import Config as _Config

    with FakeUpstream() as upstream:
        config = _Config(
            upstream_base=upstream.base_url,
            file_cache_bytes=1024,
            file_cache_files=2,
        )
        with running_relay(upstream.base_url, config=config) as relay:
            with relay.get("/healthz") as response:
                data = json.loads(response.read())
            assert data["files"]["max_bytes"] == 1024
            assert data["files"]["max_files"] == 2


def test_unknown_protocol_and_read_url_script_still_parses() -> None:
    """阅读链接脚本（web_fetch_tool_result）经中转后 steps 里有 read_link。"""
    with FakeUpstream(lines=anthropic_read_link_script()) as upstream:
        with running_relay(upstream.base_url) as relay:
            with relay.post(
                "/v1/chat", chat_request(), {"x-api-key": "sk-1"}
            ) as response:
                stream = response.read().decode("utf-8")
            job_id = json.loads(
                [line for line in stream.split("\n") if line.startswith("data: ")][0][6:]
            )["job_id"]
            with relay.get(f"/v1/jobs/{job_id}") as res:
                snapshot = json.loads(res.read())
            assert snapshot["steps"][0]["kind"] == "read_link"
            assert snapshot["steps"][0]["signature"] == "sig-xyz"
            assert snapshot["sources"][0]["url"] == "https://example.com/a"


