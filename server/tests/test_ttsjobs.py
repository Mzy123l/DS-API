"""TTS 任务表测试：去重、清理与流式转发。

缺陷回归点：去重键必须同时包含 voice_id / audio_format / text，
写入（submit）与清理（_prune_locked）不能各算一套，否则 `_by_text`
只增不减，残留映射还会让后续提交命中已被回收的任务。
"""

from __future__ import annotations

import json
import time
import urllib.error

import pytest

from app.filecache import FileCache
from app.ttsjobs import TtsJobManager
from tests.fake_upstream import FAKE_WAV, FakeUpstream
from tests.test_api import running_relay

AUTH = "Bearer sk-tts"
TEXT = "你好世界"


def build_manager(upstream: FakeUpstream, ttl: float = 3600.0) -> TtsJobManager:
    return TtsJobManager(audio_cache=FileCache(), ttl=ttl)


def submit(
    manager: TtsJobManager,
    upstream: FakeUpstream,
    text: str = TEXT,
    voice_id: str = "stella",
    audio_format: str = "wav",
):
    return manager.submit(
        text=text,
        voice_id=voice_id,
        auth=AUTH,
        owner=None,
        upstream_base=upstream.base_url,
        timeout=10.0,
        audio_format=audio_format,
    )


def wait_until(predicate, timeout: float = 10.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def status_of(manager: TtsJobManager, job_id: str) -> str | None:
    job = manager.get(job_id)
    return None if job is None else job.status


# ---------------------------------------------------------------- 去重


def test_same_request_hits_existing_job() -> None:
    """同一 text + voice + format 重复提交：命中同一任务，只打一次上游。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream)
        first, created_first = submit(manager, upstream)
        assert created_first is True
        second, created_second = submit(manager, upstream)
        assert created_second is False
        assert second.job_id == first.job_id
        assert wait_until(lambda: status_of(manager, first.job_id) == "done")
        # 重复提交零计费：上游只收到一次请求
        assert len(upstream.requests) == 1


def test_different_format_is_a_different_job() -> None:
    """audio_format 参与去重键：容器名不同就是两个任务。

    audio_format 只是往上游透传的字符串（客户端现在只请求 wav）。
    """
    with FakeUpstream() as upstream:
        manager = build_manager(upstream)
        wav_job, created_wav = submit(manager, upstream, audio_format="wav")
        alt_job, created_alt = submit(manager, upstream, audio_format="mp3")
        assert created_wav is True
        assert created_alt is True
        assert alt_job.job_id != wav_job.job_id
        assert wait_until(
            lambda: status_of(manager, wav_job.job_id) == "done"
            and status_of(manager, alt_job.job_id) == "done"
        )
        # 两个任务各自打到上游（并发启动，顺序不确定，只比较集合）
        assert sorted(r["body"]["format"] for r in upstream.requests) == [
            "mp3",
            "wav",
        ]


def test_different_voice_is_a_different_job() -> None:
    """音色同样参与去重键（键的另一半也不许漂移）。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream)
        stella_job, _ = submit(manager, upstream, voice_id="stella")
        tide_job, created = submit(manager, upstream, voice_id="tide")
        assert created is True
        assert tide_job.job_id != stella_job.job_id


# ---------------------------------------------------------------- 清理


def test_prune_removes_stale_text_mapping() -> None:
    """_prune_locked 必须真正清掉 `_by_text`，不能只增不减。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream, ttl=0.0)
        job, _ = submit(manager, upstream)
        assert wait_until(lambda: status_of(manager, job.job_id) == "done")
        with manager._lock:
            assert manager._by_text, "提交后应当有去重映射"
        # ttl=0：下一次 submit 里的 _prune_locked 一定判它过期
        submit(manager, upstream, text="另一段文字")
        with manager._lock:
            assert job.job_id not in manager._jobs
            # 关键断言：映射随任务一起被清掉，不残留
            digest = manager._digest("stella", "wav", TEXT)
            assert manager._by_text.get(digest) is None
            # 只剩新任务那一条映射
            assert len(manager._by_text) == 1


def test_prune_stale_mapping_does_not_revive_old_job() -> None:
    """老任务被回收后再提交同文本：新建任务，映射指向新任务。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream, ttl=0.0)
        old, _ = submit(manager, upstream)
        assert wait_until(lambda: status_of(manager, old.job_id) == "done")
        fresh, created = submit(manager, upstream)
        assert created is True
        assert fresh.job_id != old.job_id
        with manager._lock:
            digest = manager._digest("stella", "wav", TEXT)
            assert manager._by_text[digest] == fresh.job_id
            assert old.job_id not in manager._jobs


def test_get_renews_within_cap() -> None:
    """上限之内：查询会把过期时刻往后推（续期），任务不会被回收。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream, ttl=10.0)
        job, _ = submit(manager, upstream)
        assert wait_until(lambda: status_of(manager, job.job_id) == "done")
        with manager._lock:
            before = job.finished_at
        assert before is not None
        time.sleep(0.01)
        assert manager.get(job.job_id) is job
        with manager._lock:
            assert job.finished_at is not None
            assert job.finished_at > before, "查询应当把过期时刻往后推"
            # 续期不是永久免疫：过期时刻仍然存在，_prune_locked 还能看到它
            assert job.job_id in manager._jobs


def test_get_does_not_renew_beyond_cap() -> None:
    """超过总时长上限后不再续期，任务照常被 prune 回收。"""
    with FakeUpstream() as upstream:
        manager = build_manager(upstream, ttl=10.0)
        job, _ = submit(manager, upstream)
        assert wait_until(lambda: status_of(manager, job.job_id) == "done")
        expired_at = time.time() - manager.ttl - 1.0
        with manager._lock:
            job.created_at = time.time() - manager.ttl * 10
            job.finished_at = expired_at
        manager.get(job.job_id)
        with manager._lock:
            assert job.finished_at == expired_at, "超过上限后不应再续期"
        submit(manager, upstream, text="触发清理")
        with manager._lock:
            assert job.job_id not in manager._jobs


# ------------------------------------------------------------ 流式转发


def test_tts_defaults_to_wav_container() -> None:
    """不传 format 时上游收到的必须是 wav（裸 pcm 路线已废弃）。

    回归点：服务端默认曾是 pcm，客户端拿到的音频没有容器头，
    长按下载存成 .wav 后播放器一律报「格式不对」。
    """
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            res = relay.post(
                "/v1/tools/tts",
                {"text": "默认格式", "voice_id": "stella"},
                {"Authorization": AUTH},
            )
            assert res.status == 202
            job_id = json.loads(res.read())["job_id"]
            assert wait_until(lambda: status_of(relay.server.tts_manager, job_id) == "done")

            assert upstream.requests[0]["body"]["format"] == "wav"

            # 取回的音频也是 wav 容器（RIFF/WAVE 头）
            audio_id = relay.server.tts_manager.get(job_id).audio_id
            status, raw, headers = relay.get_raw(f"/v1/audio/{audio_id}")
            assert status == 200
            assert raw.startswith(b"RIFF")
            assert raw[8:12] == b"WAVE"


def test_tts_stream_forwards_audio_bytes() -> None:
    """GET /v1/tts-stream/{id}：字节完整转发，Content-Type 跟随上游。"""
    with FakeUpstream() as upstream:
        with running_relay(upstream.base_url) as relay:
            res = relay.post(
                "/v1/tools/tts",
                {"text": "流式转发", "voice_id": "stella", "format": "wav"},
                {"Authorization": AUTH},
            )
            assert res.status == 202
            job_id = json.loads(res.read())["job_id"]

            status, raw, headers = relay.get_raw(f"/v1/tts-stream/{job_id}")
            assert status == 200
            lowered = {name.lower(): value for name, value in headers.items()}
            assert lowered["content-type"] == "audio/wav"
            # 逐字节一致：中途没有按文本解码
            assert raw == FAKE_WAV


def test_tts_stream_reports_error_and_missing_job() -> None:
    """error 任务回 502、未知任务回 404（都是 JSON 错误体）。"""
    with FakeUpstream(status=402, error_message="余额不足") as upstream:
        with running_relay(upstream.base_url) as relay:
            relay.post("/v1/tools/tts", {"text": "失败"}, {"Authorization": AUTH})
            job = next(iter(relay.server.tts_manager._jobs.values()))
            assert wait_until(lambda: job.status == "error")

            with pytest.raises(urllib.error.HTTPError) as error:
                relay.get(f"/v1/tts-stream/{job.job_id}")
            assert error.value.code == 502
            assert "余额不足" in json.loads(error.value.read())["error"]["message"]

            with pytest.raises(urllib.error.HTTPError) as missing:
                relay.get("/v1/tts-stream/0123456789abcdef0123456789abcdef")
            assert missing.value.code == 404
            assert "任务不存在" in json.loads(missing.value.read())["error"][
                "message"
            ]
