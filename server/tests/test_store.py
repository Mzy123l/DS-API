"""存储层测试：分页、截断、搜索与思考用时。"""

from __future__ import annotations

from collections.abc import Iterator

import pytest

from app.store import ChatStore


@pytest.fixture
def store() -> Iterator[ChatStore]:
    value = ChatStore(":memory:")
    try:
        yield value
    finally:
        value.close()


def test_conversations_paging_by_updated_at(store: ChatStore) -> None:
    ids = [store.create_conversation(f"会话{i}", "m") for i in range(5)]
    # 手动打散更新时间，验证排序只看 updated_at
    for index, conv_id in enumerate(ids):
        store.append_message(conv_id, "user", f"内容{index}", ts=1000 + index)

    first = store.list_conversations(limit=2)
    assert len(first["items"]) == 2
    assert first["has_more"] is True
    assert first["items"][0]["id"] == ids[4]
    assert first["items"][0]["preview"] == "内容4"

    second = store.list_conversations(
        limit=2,
        before_updated_at=first["items"][-1]["updated_at"],
        before_id=first["items"][-1]["id"],
    )
    assert [item["id"] for item in second["items"]] == [ids[2], ids[1]]
    assert second["has_more"] is True

    third = store.list_conversations(
        limit=2,
        before_updated_at=second["items"][-1]["updated_at"],
        before_id=second["items"][-1]["id"],
    )
    assert [item["id"] for item in third["items"]] == [ids[0]]
    assert third["has_more"] is False


def test_message_page_returns_latest_and_older_pages(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    for index in range(10):
        store.append_message(conv, "user" if index % 2 == 0 else "assistant", f"m{index}")

    page = store.message_page(conv, limit=4)
    assert [item["content"] for item in page["items"]] == ["m6", "m7", "m8", "m9"]
    assert page["has_more"] is True
    assert page["oldest_id"] == page["items"][0]["id"]

    older = store.message_page(conv, limit=4, before_id=page["oldest_id"])
    assert [item["content"] for item in older["items"]] == ["m2", "m3", "m4", "m5"]
    assert older["has_more"] is True

    oldest = store.message_page(conv, limit=4, before_id=older["oldest_id"])
    assert [item["content"] for item in oldest["items"]] == ["m0", "m1"]
    assert oldest["has_more"] is False


def test_append_with_sources_and_reasoning(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    store.append_message(
        conv,
        "assistant",
        "回答",
        reasoning="思考",
        reasoning_ms=1234,
        sources=[{"title": "T", "url": "https://e.com"}],
    )
    page = store.message_page(conv, limit=10)
    item = page["items"][0]
    assert item["reasoning"] == "思考"
    assert item["reasoning_ms"] == 1234
    assert item["sources"] == [{"title": "T", "url": "https://e.com"}]
    assert item["role"] == "assistant"


def test_truncate_keeps_prefix_and_deletes_rest(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    for index in range(6):
        store.append_message(conv, "user", f"m{index}")

    assert store.truncate_messages(conv, 2) == (4, [])
    page = store.message_page(conv, limit=10)
    assert [item["content"] for item in page["items"]] == ["m0", "m1"]
    assert store.message_count(conv) == 2
    assert store.truncate_messages(conv, 0) == (2, [])
    assert store.message_count(conv) == 0


def test_truncate_before_message_id(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    ids = [
        store.append_message(conv, "user", f"m{index}") for index in range(6)
    ]

    # 从第 4 条消息开始删；前面 3 条必须完整保留，不受客户端加载窗口影响。
    assert store.truncate_messages_before(conv, ids[3]) == (3, [])
    page = store.message_page(conv, limit=10)
    assert [item["content"] for item in page["items"]] == ["m0", "m1", "m2"]


def test_rename_and_delete_conversation(store: ChatStore) -> None:
    conv = store.create_conversation("旧标题", "m")
    store.append_message(conv, "user", "hi")

    assert store.rename_conversation(conv, "新标题") is True
    assert store.conversation_title(conv) == "新标题"
    assert store.rename_conversation(999, "x") is False

    assert store.conversation_exists(conv) is True
    assert store.delete_conversation(conv) is True
    assert store.conversation_exists(conv) is False
    assert store.message_count(conv) == 0
    assert store.delete_conversation(conv) is False


def test_conversation_system_prompt_roundtrip(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m", system_prompt="你是猫")
    assert store.conversation_system_prompt(conv) == "你是猫"
    item = store.list_conversations(limit=10)["items"][0]
    assert item["system_prompt"] == "你是猫"

    # 最新一次写入覆盖旧值；空字符串表示回到默认
    assert store.set_system_prompt(conv, "你是狗") is True
    assert store.conversation_system_prompt(conv) == "你是狗"
    assert store.set_system_prompt(conv, "") is True
    assert store.conversation_system_prompt(conv) == ""

    assert store.set_system_prompt(999, "x") is False
    assert store.conversation_system_prompt(999) is None


def test_append_messages_bulk_and_stats(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    ids = store.append_messages(
        conv,
        [
            {"role": "user", "content": "一"},
            {"role": "assistant", "content": "二", "reasoning": "r"},
        ],
    )
    assert len(ids) == 2 and ids[0] < ids[1]
    assert store.message_count(conv) == 2
    stats = store.stats()
    assert stats == {"conversations": 1, "messages": 2}


def test_search_messages_returns_match_offsets(store: ChatStore) -> None:
    conv = store.create_conversation("标题", "m")
    store.append_message(conv, "user", "Hello 世界 hello")
    store.append_message(conv, "assistant", "无关内容")

    hits = store.search_messages("hello")
    assert len(hits) == 1
    assert hits[0]["conversation_id"] == conv
    assert hits[0]["conversation_title"] == "标题"
    assert hits[0]["matches"] == [0, 9]
    assert store.search_messages("  ") == []
    # LIKE 通配符需要转义，不能当成模式匹配
    store.append_message(conv, "user", "100% 完成")
    assert len(store.search_messages("%")) == 1


def test_reasoning_ms_from_accumulator() -> None:
    from app.sse import PROTOCOL_ANTHROPIC, StreamAccumulator

    acc = StreamAccumulator(PROTOCOL_ANTHROPIC)
    assert acc.reasoning_ms() == 0
    acc.feed('data: {"type":"content_block_delta","delta":'
             '{"type":"thinking_delta","thinking":"想"}}')
    acc.feed('data: {"type":"content_block_delta","delta":'
             '{"type":"text_delta","text":"答"}}')
    assert acc.reasoning_ms() >= 0
    assert acc.reasoning == "想" and acc.content == "答"


def test_clear_removes_everything(store: ChatStore) -> None:
    conv = store.create_conversation("对话", "m")
    store.append_message(conv, "user", "hi")
    store.clear()
    assert store.stats() == {"conversations": 0, "messages": 0}


def test_truncate_reports_orphan_audio(store: ChatStore) -> None:
    """截断/删除消息时，被删消息引用的音频 id 要返回给调用方清理缓存。"""
    conv = store.create_conversation("对话", "m")
    store.append_message(conv, "user", "问")
    store.append_message(conv, "assistant", "答", audio=["a1", "a2"])
    store.append_message(conv, "user", "再问")
    store.append_message(conv, "assistant", "再答", audio=["a3", "a1"])

    # 截断到第 2 条之后：后两条被删，被删消息引用 a3、a1
    deleted, orphans = store.truncate_messages_before(conv, 3)
    assert deleted == 2
    assert orphans == ["a3", "a1"]

    # keep 语义用一份新数据验证
    conv2 = store.create_conversation("对话2", "m")
    store.append_message(conv2, "user", "问")
    store.append_message(conv2, "assistant", "答", audio=["b1"])
    deleted, orphans = store.truncate_messages(conv2, 1)
    assert deleted == 1
    assert orphans == ["b1"]

    # 没有音频时返回空列表
    store.append_message(conv, "user", "没有音频")
    deleted, orphans = store.truncate_messages(conv, 3)
    assert orphans == []


def test_delete_conversation_reports_audio_via_cache(
    store: ChatStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    """删除会话时路由层按 owner 清理音频缓存（owner 记账在 FileCache）。"""
    from app.filecache import CachedFile, FileCache

    cache = FileCache()
    conv = store.create_conversation("对话", "m")
    store.append_message(conv, "assistant", "答", audio=["a1"])
    cache.put(
        CachedFile(
            file_id="a1",
            filename="a1.wav",
            content_type="audio/wav",
            data=b"x",
            owner=conv,
        )
    )
    cache.put(
        CachedFile(
            file_id="other",
            filename="other.wav",
            content_type="audio/wav",
            data=b"y",
            owner=conv + 1,
        )
    )

    # 路由层删除会话后调用 discard_owner：只清本会话名下
    removed = cache.discard_owner(conv)
    assert removed == 1
    assert cache.get("a1") is None
    assert cache.get("other") is not None
