"""旧数据迁移：把消息开头的 ``<system>...</system>`` 提取为会话提示词并删除标签。

规则与客户端 ``prompt.dart`` 保持一致：

- 只有出现在**用户消息最开头**的 ``<system>`` 块才算提示词；
- 块内容允许跨行；没有闭合标签时按普通文本处理，不做修改；
- 同一会话有多条带标签的消息时，**最后一次**生效；
- 提示词写入 ``conversations.system_prompt`` 后，标签从消息正文中删除；
- 脚本只输出统计数字，不打印任何消息内容。

用法（容器内）::

    python -m app.migrate --db /srv/data/relay.db
    python -m app.migrate --db /srv/data/relay.db --dry-run
    python -m app.migrate --db /srv/data/relay.db --no-backup
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from typing import Any

_OPEN = "<system>"
_CLOSE = "</system>"


def split_system_prompt(content: str) -> tuple[str | None, str]:
    """拆出开头的系统提示词块。

    返回 ``(prompt, body)``：

    - 没有可识别的块：``(None, content)``，内容保持不变；
    - 有块但内容为空：``(None, body)``，标签仍然删除；
    - 正常：``(prompt, body)``。
    """
    text = content.lstrip()
    if not text.startswith(_OPEN):
        return None, content
    end = text.find(_CLOSE, len(_OPEN))
    if end < 0:
        return None, content  # 未闭合：按普通文本处理
    prompt = text[len(_OPEN) : end].strip()
    body = text[end + len(_CLOSE) :].strip()
    return (prompt or None), body


def _has_system_prompt_column(conn: sqlite3.Connection) -> bool:
    columns = conn.execute("PRAGMA table_info(conversations)").fetchall()
    return any(row[1] == "system_prompt" for row in columns)


def _backup(conn: sqlite3.Connection, db_path: str) -> str:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    target = f"{db_path}.bak-{stamp}"
    while Path(target).exists():
        target = f"{target}-1"
    dst = sqlite3.connect(target)
    try:
        conn.backup(dst)
    finally:
        dst.close()
    return target


def migrate(
    db_path: str,
    *,
    dry_run: bool = False,
    backup: bool = True,
) -> dict[str, Any]:
    """执行迁移并返回统计；``dry_run`` 只统计、不写库。"""
    if db_path != ":memory:" and not Path(db_path).exists():
        raise FileNotFoundError(db_path)

    conn = sqlite3.connect(db_path, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA busy_timeout = 10000")
        backup_path: str | None = None
        if backup and not dry_run and db_path != ":memory:":
            backup_path = _backup(conn, db_path)

        conn.execute("BEGIN IMMEDIATE")
        has_column = _has_system_prompt_column(conn)
        rows = conn.execute(
            "SELECT id, conv_id, content FROM messages"
            " WHERE role = 'user' ORDER BY conv_id, id"
        ).fetchall()

        prompts: dict[int, str] = {}
        updates: list[tuple[str, int]] = []
        empty_bodies = 0
        for row in rows:
            prompt, body = split_system_prompt(row["content"])
            if body == row["content"]:
                continue
            updates.append((body, int(row["id"])))
            if not body:
                empty_bodies += 1
            if prompt:
                # 同一个会话以最后一条带标签的消息为准
                prompts[int(row["conv_id"])] = prompt

        if dry_run:
            existing: dict[int, str] = {}
            if has_column:
                existing = {
                    int(row["id"]): (row["system_prompt"] or "")
                    for row in conn.execute(
                        "SELECT id, system_prompt FROM conversations"
                    )
                }
            pending = [
                conv_id
                for conv_id, prompt in prompts.items()
                if not (existing.get(conv_id) or "").strip()
            ]
            conn.rollback()
            return {
                "dry_run": True,
                "backup_path": backup_path,
                "detected_conversations": len(prompts),
                "updated_conversations": len(pending),
                "stripped_messages": len(updates),
                "empty_bodies": empty_bodies,
            }

        if not has_column:
            conn.execute(
                "ALTER TABLE conversations ADD COLUMN system_prompt"
                " TEXT NOT NULL DEFAULT ''"
            )

        current = {
            int(row["id"]): (row["system_prompt"] or "")
            for row in conn.execute("SELECT id, system_prompt FROM conversations")
        }
        updated_prompts = 0
        for conv_id, prompt in prompts.items():
            if conv_id not in current:
                continue
            if current[conv_id].strip():
                # 新客户端已经写入的提示词优先，旧标签只负责补空值
                continue
            conn.execute(
                "UPDATE conversations SET system_prompt = ? WHERE id = ?",
                (prompt, conv_id),
            )
            updated_prompts += 1

        for body, message_id in updates:
            conn.execute(
                "UPDATE messages SET content = ? WHERE id = ?", (body, message_id)
            )

        conn.commit()
        return {
            "dry_run": False,
            "backup_path": backup_path,
            "detected_conversations": len(prompts),
            "updated_conversations": updated_prompts,
            "stripped_messages": len(updates),
            "empty_bodies": empty_bodies,
        }
    except Exception:
        try:
            conn.rollback()
        except sqlite3.Error:
            pass
        raise
    finally:
        conn.close()


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="把旧消息里的 <system> 提示词迁移到会话并删除标签"
    )
    parser.add_argument(
        "--db",
        default=os.environ.get("RELAY_DB", "/srv/data/relay.db"),
        help="SQLite 数据库路径（默认取 RELAY_DB 或 /srv/data/relay.db）",
    )
    parser.add_argument("--dry-run", action="store_true", help="只统计，不写库")
    parser.add_argument("--no-backup", action="store_true", help="不生成备份文件")
    args = parser.parse_args(argv)

    try:
        stats = migrate(
            args.db,
            dry_run=args.dry_run,
            backup=not args.no_backup,
        )
    except Exception as exc:  # noqa: BLE001 - CLI 统一提示
        print(f"迁移失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    if stats["backup_path"]:
        print(f"备份文件：{stats['backup_path']}")
    mode = "预演" if stats["dry_run"] else "完成"
    print(f"迁移{mode}（不输出任何消息内容）：")
    print(f"  识别到提示词的会话：{stats['detected_conversations']}")
    print(f"  写入 system_prompt 的会话：{stats['updated_conversations']}")
    print(f"  清理掉 <system> 标签的消息：{stats['stripped_messages']}")
    print(f"  清理后正文为空的消息：{stats['empty_bodies']}")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI 入口
    raise SystemExit(main())
