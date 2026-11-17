"""旧数据迁移脚本测试：只用临时库，不接触真实对话数据。"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from app.migrate import migrate, split_system_prompt
from app.store import ChatStore


@pytest.fixture
def db_path(tmp_path: Path) -> Iterator[str]:
    path = str(tmp_path / "relay.db")
    store = ChatStore(path)
    try:
        yield path
    finally:
        store.close()


def test_split_only_leading_block_is_removed() -> None:
    assert split_system_prompt("<system>你是猫</system>\n你好") == ("你是猫", "你好")
    assert split_system_prompt("  <system>多行\n提示</system>正文") == (
        "多行\n提示",
        "正文",
    )
    # 不在开头、未闭合、空内容：按约定分别处理
    assert split_system_prompt("你好 <system>你是猫</system>") == (
        None,
        "你好 <system>你是猫</system>",
    )
    assert split_system_prompt("<system>未闭合") == (None, "<system>未闭合")
    assert split_system_prompt("<system></system>正文") == (None, "正文")


def test_migrate_extracts_latest_prompt_and_strips_messages(db_path: str) -> None:
    store = ChatStore(db_path)
    conv = store.create_conversation("会话", "m")
    first = store.append_message(conv, "user", "<system>你是猫</system>\n第一问")
    store.append_message(conv, "assistant", "回答")
    second = store.append_message(
        conv, "user", "<system>你是狗\n跨行提示</system>\n第二问"
    )
    store.close()

    stats = migrate(db_path, backup=False)
    assert stats["detected_conversations"] == 1
    assert stats["updated_conversations"] == 1
    assert stats["stripped_messages"] == 2
    assert stats["empty_bodies"] == 0

    check = sqlite3.connect(db_path)
    try:
        prompt = check.execute(
            "SELECT system_prompt FROM conversations WHERE id = ?", (conv,)
        ).fetchone()[0]
        assert prompt == "你是狗\n跨行提示"
        rows = dict(
            check.execute(
                "SELECT id, content FROM messages WHERE id IN (?, ?)", (first, second)
            ).fetchall()
        )
        assert rows[first] == "第一问"
        assert rows[second] == "第二问"
    finally:
        check.close()

    # 可重复执行：第二次没有任何需要改的内容
    again = migrate(db_path, backup=False)
    assert again["updated_conversations"] == 0
    assert again["stripped_messages"] == 0


def test_migrate_keeps_existing_prompt_and_ignores_non_leading_tags(
    db_path: str,
) -> None:
    store = ChatStore(db_path)
    conv = store.create_conversation("会话", "m", system_prompt="新客户端写入")
    store.append_message(conv, "user", "<system>旧标签</system>\n问题")
    untouched = store.append_message(conv, "user", "普通 <system>旧标签</system> 文本")
    store.close()

    stats = migrate(db_path, backup=False)
    assert stats["updated_conversations"] == 0
    assert stats["stripped_messages"] == 1

    check = sqlite3.connect(db_path)
    try:
        prompt = check.execute(
            "SELECT system_prompt FROM conversations WHERE id = ?", (conv,)
        ).fetchone()[0]
        assert prompt == "新客户端写入"
        content = check.execute(
            "SELECT content FROM messages WHERE id = ?", (untouched,)
        ).fetchone()[0]
        assert content == "普通 <system>旧标签</system> 文本"
    finally:
        check.close()


def test_migrate_dry_run_does_not_write(db_path: str) -> None:
    store = ChatStore(db_path)
    conv = store.create_conversation("会话", "m")
    msg = store.append_message(conv, "user", "<system>你是猫</system>\n你好")
    store.close()

    stats = migrate(db_path, dry_run=True, backup=False)
    assert stats["detected_conversations"] == 1
    assert stats["updated_conversations"] == 1
    assert stats["stripped_messages"] == 1

    check = sqlite3.connect(db_path)
    try:
        prompt = check.execute(
            "SELECT system_prompt FROM conversations WHERE id = ?", (conv,)
        ).fetchone()[0]
        content = check.execute(
            "SELECT content FROM messages WHERE id = ?", (msg,)
        ).fetchone()[0]
        assert prompt == ""
        assert content == "<system>你是猫</system>\n你好"
    finally:
        check.close()
