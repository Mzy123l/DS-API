"""任务管理测试：完成、错误转发、取消与内存回收。"""

from __future__ import annotations

import json
import time

from app.config import Config
from app.filecache import CachedFile
from app.jobs import JobManager
from tests.fake_upstream import (
    FakeUpstream,
    anthropic_script,
    anthropic_server_search_script,
    responses_script,
)

ANTHROPIC_PAYLOAD = {"model": "deepseek-v4-pro", "stream": True, "messages": []}


def wait_until(predicate, timeout: float = 5.0) -> bool:
    """轮询等待条件成立（测试内的轻量同步）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def build_manager(upstream: FakeUpstream) -> JobManager:
    return JobManager(Config(upstream_base=upstream.base_url))


def test_job_runs_to_completion_and_keeps_lines() -> None:
    with FakeUpstream(lines=anthropic_script(with_source=True)) as upstream:
        manager = build_manager(upstream)
        job = manager.create(
            "anthropic", ANTHROPIC_PAYLOAD, {"x-api-key": "sk-test"}
        )
        assert wait_until(lambda: job.finished)
        snapshot = job.snapshot()
        assert snapshot["status"] == "done"
        assert snapshot["reasoning"] == "思考中"
        assert snapshot["content"] == "你好"
        assert snapshot["sources"][0]["url"] == "https://example.com/a"
        assert snapshot["line_count"] == len(job.lines)
        assert any("message_stop" in line for line in job.lines)
        # 上游收到的路径、透传头与请求体
        assert upstream.requests[0]["path"] == "/anthropic/v1/messages"
        assert upstream.requests[0]["headers"]["x-api-key"] == "sk-test"
        # 明确声明不压缩，保证 SSE 逐行即时读取
        assert upstream.requests[0]["headers"]["accept-encoding"] == "identity"
        assert upstream.requests[0]["body"] == ANTHROPIC_PAYLOAD


def test_responses_protocol_hits_responses_path() -> None:
    with FakeUpstream(lines=responses_script("答")) as upstream:
        manager = build_manager(upstream)
        job = manager.create("responses", {"model": "m"}, {})
        assert wait_until(lambda: job.finished)
        assert job.snapshot()["content"] == "答"
        assert upstream.requests[0]["path"] == "/responses"


def test_upstream_error_is_kept_for_relay() -> None:
    with FakeUpstream(status=401, error_message="鉴权失败") as upstream:
        manager = build_manager(upstream)
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        assert wait_until(lambda: job.finished)
        snapshot = job.snapshot()
        assert snapshot["status"] == "error"
        assert snapshot["error"] == "鉴权失败"
        assert job.upstream_status == 401
        assert "鉴权失败" in (job.error_body or "")


def test_cancel_stops_running_job() -> None:
    # 不发 message_stop：上游保持连接，任务停在 running，便于验证取消
    with FakeUpstream(
        lines=anthropic_script()[:-1], hold_seconds=30.0
    ) as upstream:
        manager = build_manager(upstream)
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        assert wait_until(lambda: job.upstream_status == 200)
        assert manager.cancel(job.id) is True
        assert wait_until(lambda: job.finished)
        assert job.snapshot()["status"] == "canceled"
        assert manager.get(job.id) is job
        assert manager.cancel("不存在") is False
        assert manager.get("不存在") is None
        assert job.canceled is True


def test_tail_streams_new_lines_until_done() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        manager = build_manager(upstream)
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        collected: list[str] = []
        done = False
        deadline = time.time() + 5.0
        while time.time() < deadline and not done:
            new_lines, done = job.tail(len(collected), timeout=1.0)
            collected.extend(new_lines)
        assert done
        assert any("message_stop" in line for line in collected)
        # 已结束且全部读完后，再取不会拿到新行
        assert job.tail(len(collected), timeout=0.1) == ([], True)
        assert manager.count() == 1
        assert manager.active_count() == 0


def test_prune_drops_expired_and_extra_jobs() -> None:
    with FakeUpstream(lines=anthropic_script()) as upstream:
        manager = JobManager(
            Config(upstream_base=upstream.base_url, max_jobs=2, job_ttl_seconds=0.0)
        )
        for _ in range(3):
            manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
            assert wait_until(lambda: manager.active_count() == 0)
        # 保留数量受 max_jobs 限制
        assert manager.count() <= 2


def test_invalid_upstream_address_fails_job() -> None:
    manager = JobManager(Config(upstream_base="http://127.0.0.1:1"))
    job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
    assert wait_until(lambda: job.finished)
    snapshot = job.snapshot()
    assert snapshot["status"] == "error"
    assert "请求失败" in (snapshot["error"] or "")


def test_protocol_of_falls_back_to_anthropic() -> None:
    assert JobManager.protocol_of("responses") == "responses"
    assert JobManager.protocol_of("anthropic") == "anthropic"
    assert JobManager.protocol_of(None) == "anthropic"
    assert JobManager.protocol_of("unknown") == "anthropic"


def test_job_summary_reports_timings_and_upload_size() -> None:
    """打点行要能看出：上行大小、上游首字节、首个增量、思考用时、总耗时。"""
    with FakeUpstream(lines=anthropic_script()) as upstream:
        manager = build_manager(upstream)
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        assert wait_until(lambda: job.finished)
        summary = job.summary()
        assert f"job {job.id[:8]}" in summary
        assert "status=done" in summary
        assert "upstream=200" in summary
        assert "bytes=" in summary and "bytes=0" not in summary
        assert "ttfb=" in summary and "ttfb=-" not in summary
        assert "first_delta=" in summary and "first_delta=-" not in summary
        assert "reasoning=" in summary and "total=" in summary


def test_checkpoint_callback_receives_partial_content() -> None:
    """流式正文到达时触发 checkpoint 回调，服务重启后至少保留已输出部分。"""
    checkpoints: list[str] = []
    with FakeUpstream(lines=anthropic_script()) as upstream:
        manager = JobManager(
            Config(
                upstream_base=upstream.base_url,
                checkpoint_interval=0.0,
            ),
            on_job_checkpoint=lambda job: checkpoints.append(job.acc.content),
        )
        job = manager.create(
            "anthropic",
            ANTHROPIC_PAYLOAD,
            {"x-api-key": "sk-test"},
            conversation_id=1,
        )
        assert wait_until(lambda: job.finished)
        assert any("你好" in content for content in checkpoints)


def test_checkpoint_happens_during_thinking_before_content() -> None:
    """只有思考、正文还没开始时也要 checkpoint（思考阶段重启不能丢思考）。"""
    checkpoints: list[tuple[str, str]] = []
    # 只发思考增量，然后挂住：正文还没开始，任务保持 running
    with FakeUpstream(
        lines=anthropic_script()[:2], hold_seconds=30.0
    ) as upstream:
        manager = JobManager(
            Config(
                upstream_base=upstream.base_url,
                checkpoint_interval=0.0,
            ),
            on_job_checkpoint=lambda job: checkpoints.append(
                (job.acc.reasoning, job.acc.content)
            ),
        )
        job = manager.create(
            "anthropic",
            ANTHROPIC_PAYLOAD,
            {"x-api-key": "sk-test"},
            conversation_id=1,
        )
        assert wait_until(lambda: job.acc.reasoning == "思考中")
        assert wait_until(
            lambda: any(
                reasoning == "思考中" and content == ""
                for reasoning, content in checkpoints
            )
        )
        manager.cancel(job.id)


# --------------------------------------------------- 服务端执行的函数工具（ocr）

def test_unknown_tool_is_rejected_without_calling_upstream() -> None:
    """只有 ocr 是服务端执行的函数工具；其它名字直接回错误。"""
    manager = JobManager(Config(upstream_base="http://127.0.0.1:1"))
    job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
    try:
        result = manager._execute_tool(
            job, {"id": "t1", "name": "search", "arguments": '{"query":"x"}'}
        )
        assert "未知工具" in json.loads(result)["error"]
    finally:
        manager.cancel(job.id)


def test_ocr_tool_without_file_id_reports_error() -> None:
    manager = JobManager(Config(upstream_base="http://127.0.0.1:1"))
    job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
    try:
        result = manager._execute_tool(
            job, {"id": "t1", "name": "ocr", "arguments": "{}"}
        )
        assert "缺少 file_id" in json.loads(result)["error"]
    finally:
        manager.cancel(job.id)


def test_ocr_tool_falls_back_to_default_purpose() -> None:
    """非法/缺失的 purpose 回落到 text_recognition。"""
    manager = JobManager(Config(upstream_base="http://127.0.0.1:1"))
    cache = manager.file_cache
    cache.put(
        CachedFile(
            file_id="file-1",
            filename="a.png",
            content_type="image/png",
            data=b"img",
        )
    )
    job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
    try:
        result = manager._execute_ocr(job, {"file_id": "file-1", "purpose": "bad"})
        # 上游连不上：错误里带状态码，但请求确实发过（说明走了默认 purpose 分支）
        assert "工具调用失败" in json.loads(result)["error"]
    finally:
        manager.cancel(job.id)


def test_ocr_tool_upstream_error_is_reported() -> None:
    with FakeUpstream(status=413, error_message="文件太大") as upstream:
        manager = JobManager(Config(upstream_base=upstream.base_url))
        manager.file_cache.put(
            CachedFile(
                file_id="file-2",
                filename="a.pdf",
                content_type="application/pdf",
                data=b"data",
            )
        )
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        try:
            result = manager._execute_ocr(job, {"file_id": "file-2"})
            payload = json.loads(result)
            assert "文件太大" in payload["error"]
            assert "不要重试" in payload["error"]
        finally:
            manager.cancel(job.id)


def test_ocr_tool_bad_json_response() -> None:
    with FakeUpstream() as upstream:
        upstream.ocr_result = None  # 让处理器回 null 而不是对象
        manager = JobManager(Config(upstream_base=upstream.base_url))
        manager.file_cache.put(
            CachedFile(
                file_id="file-3",
                filename="a.pdf",
                content_type="application/pdf",
                data=b"data",
            )
        )
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        try:
            result = manager._execute_ocr(job, {"file_id": "file-3"})
            assert "格式错误" in json.loads(result)["error"]
        finally:
            manager.cancel(job.id)


def test_ocr_text_result_shapes() -> None:
    """OCR 结果整理：逐页拼接、失败页带 finish_reasons、无文字时给错误。"""
    from app.jobs import _ocr_text_result

    assert _ocr_text_result("不是对象") == {"error": "工具返回格式错误"}
    assert _ocr_text_result({"pages": "不是列表"}) == {
        "error": "OCR 没有返回 pages"
    }
    result = _ocr_text_result(
        {
            "id": "f1",
            "page_count": 3,
            "pages": [
                {"index": 0, "text": "一", "finish_reason": "success"},
                "坏数据",
                {"index": 1, "text": "  ", "finish_reason": "success"},
                {"index": 2, "text": "三", "finish_reason": "truncated"},
            ],
        }
    )
    assert result["text"] == "一\n\n三"
    assert result["file_id"] == "f1"
    assert result["page_count"] == 3
    assert result["finish_reasons"] == ["truncated"]

    empty = _ocr_text_result({"pages": []})
    assert empty["text"] == ""
    assert empty["error"] == "文件里没有识别出文字"


def test_checkpoint_failure_does_not_break_job() -> None:
    """checkpoint 回调抛异常时只打印一行，任务照常完成。"""
    def boom(job):
        raise RuntimeError("db 挂了")

    with FakeUpstream(lines=anthropic_script()) as upstream:
        manager = JobManager(
            Config(upstream_base=upstream.base_url, checkpoint_interval=0.0),
            on_job_checkpoint=boom,
        )
        job = manager.create(
            "anthropic", ANTHROPIC_PAYLOAD, {}, conversation_id=1
        )
        assert wait_until(lambda: job.finished)
        assert job.snapshot()["status"] == "done"
        assert job.snapshot()["content"] == "你好"


def test_snapshot_keeps_steps_and_hides_internal_fields() -> None:
    """快照新增 steps/citations，旧字段一个不少。"""
    with FakeUpstream(lines=anthropic_server_search_script()) as upstream:
        manager = build_manager(upstream)
        job = manager.create("anthropic", ANTHROPIC_PAYLOAD, {})
        assert wait_until(lambda: job.finished)
        snapshot = job.snapshot()
        # 旧字段
        for key in (
            "job_id",
            "protocol",
            "status",
            "reasoning",
            "content",
            "sources",
            "reasoning_ms",
            "error",
            "conversation_id",
            "stored_message_id",
            "result_ready",
            "line_count",
            "created_at",
            "updated_at",
        ):
            assert key in snapshot
        # 新字段
        assert snapshot["steps"][0]["kind"] == "search"
        assert all(
            not key.startswith("_") for key in snapshot["steps"][0]
        )
        assert snapshot["citations"][0]["url"] == "https://example.com/a"
