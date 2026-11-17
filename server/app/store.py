"""服务器侧会话/消息存储：SQLite + 游标分页。

设计要点：
- 会话和消息都存在服务器上，客户端按页拉取，避免一次性传输大量内容；
- 消息页按 id 倒序取「最近 N 条」，返回时再正序，游标用 `before_id`；
- 数据落在挂载卷里（容器重建不丢）。
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

_SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  model TEXT NOT NULL,
  system_prompt TEXT NOT NULL DEFAULT '',
  answer_bubble INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conv_id INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  reasoning TEXT NOT NULL DEFAULT '',
  reasoning_ms INTEGER NOT NULL DEFAULT 0,
  sources TEXT NOT NULL DEFAULT '[]',
  images TEXT NOT NULL DEFAULT '[]',
  files TEXT NOT NULL DEFAULT '[]',
  audio TEXT NOT NULL DEFAULT '[]',
  pending INTEGER NOT NULL DEFAULT 0,
  ts INTEGER NOT NULL);

CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conv_id, id);
CREATE INDEX IF NOT EXISTS idx_conversations_updated
  ON conversations(updated_at DESC, id DESC);
"""

# 单条消息内容长度不设上限


def _now_ms() -> int:
    return int(time.time() * 1000)


class ChatStore:
    """线程安全的轻量 SQLite 存储。

    个人中转服务并发很低，用一把锁串行化读写即可，比连接池简单可靠。
    """

    def __init__(self, path: str) -> None:
        self.path = path
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(_SCHEMA)
            # 老库升级：补上 images 列（已存在会抛错，忽略即可）
            try:
                self._conn.execute(
                    "ALTER TABLE messages ADD COLUMN images"
                    " TEXT NOT NULL DEFAULT '[]'"
                )
            except sqlite3.OperationalError:
                pass
            # 老库升级：pending 标记“这一轮回答还没收尾”。
            # 联网搜索多轮时复用同一条 pending 行，避免一轮回答拆成多条消息；
            # 客户端中途断开时，这行就是已经生成的部分，重进能看到。
            try:
                self._conn.execute(
                    "ALTER TABLE messages ADD COLUMN pending"
                    " INTEGER NOT NULL DEFAULT 0"
                )
            except sqlite3.OperationalError:
                pass
            # 老库升级：每个会话各自保存一份系统提示词。
            # 空字符串表示“没有单独设置”，客户端回退到 <system> 或默认值。
            try:
                self._conn.execute(
                    "ALTER TABLE conversations ADD COLUMN system_prompt"
                    " TEXT NOT NULL DEFAULT ''"
                )
            except sqlite3.OperationalError:
                pass
            # 老库升级：会话级「回答气泡」开关（0/1）。
            try:
                self._conn.execute(
                    "ALTER TABLE conversations ADD COLUMN answer_bubble"
                    " INTEGER NOT NULL DEFAULT 0"
                )
            except sqlite3.OperationalError:
                pass
            # 老库升级：消息引用的已上传文档（Files API 的 file_id）。
            try:
                self._conn.execute(
                    "ALTER TABLE messages ADD COLUMN files"
                    " TEXT NOT NULL DEFAULT '[]'"
                )
            except sqlite3.OperationalError:
                pass
            # 老库升级：模型生成的音频文件路径。
            try:
                self._conn.execute(
                    "ALTER TABLE messages ADD COLUMN audio"
                    " TEXT NOT NULL DEFAULT '[]'"
                )
            except sqlite3.OperationalError:
                pass
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ------------------------------------------------------------------ 会话

    def list_conversations(
        self,
        limit: int = 30,
        before_updated_at: int | None = None,
        before_id: int | None = None,
    ) -> dict[str, Any]:
        """按更新时间倒序分页（同毫秒用 id 兜底排序）。"""
        where = ""
        params: list[Any] = []
        if before_updated_at is not None and before_id is not None:
            where = "WHERE c.updated_at < ? OR (c.updated_at = ? AND c.id < ?)"
            params += [before_updated_at, before_updated_at, before_id]
        rows = self._query(
            f"""
            SELECT c.id, c.title, c.model, c.system_prompt, c.answer_bubble,
              c.created_at, c.updated_at,
              COALESCE(
                (SELECT m.content FROM messages m
                  WHERE m.conv_id = c.id AND m.role = 'assistant'
                  ORDER BY m.id DESC LIMIT 1),
                (SELECT m2.content FROM messages m2
                  WHERE m2.conv_id = c.id ORDER BY m2.id DESC LIMIT 1),
                '') AS preview
            FROM conversations c
            {where}
            ORDER BY c.updated_at DESC, c.id DESC
            LIMIT ?
            """,
            [*params, limit + 1],
        )
        has_more = len(rows) > limit
        return {"items": [dict(r) for r in rows[:limit]], "has_more": has_more}

    def create_conversation(
        self,
        title: str,
        model: str,
        updated_at: int | None = None,
        system_prompt: str = "",
        answer_bubble: bool = False,
    ) -> int:
        ts = updated_at or _now_ms()
        with self._lock:
            cursor = self._conn.execute(
                "INSERT INTO conversations"
                "(title, model, system_prompt, answer_bubble, created_at, updated_at)"
                " VALUES(?, ?, ?, ?, ?, ?)",
                (
                    title or "新对话",
                    model or "",
                    system_prompt or "",
                    1 if answer_bubble else 0,
                    ts,
                    ts,
                ),
            )
            self._conn.commit()
            return int(cursor.lastrowid or 0)

    def set_answer_bubble(self, conv_id: int, enabled: bool) -> bool:
        """保存会话的「回答气泡」开关。"""
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE conversations SET answer_bubble = ? WHERE id = ?",
                (1 if enabled else 0, conv_id),
            )
            self._conn.commit()
            return cursor.rowcount > 0

    def set_system_prompt(self, conv_id: int, prompt: str) -> bool:
        """保存会话的系统提示词（空字符串表示回到默认值）。"""
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE conversations SET system_prompt = ? WHERE id = ?",
                (prompt or "", conv_id),
            )
            self._conn.commit()
            return cursor.rowcount > 0

    def conversation_system_prompt(self, conv_id: int) -> str | None:
        rows = self._query(
            "SELECT system_prompt FROM conversations WHERE id = ?", [conv_id]
        )
        return (rows[0]["system_prompt"] or "") if rows else None

    def rename_conversation(self, conv_id: int, title: str) -> bool:
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?",
                (title, _now_ms(), conv_id),
            )
            self._conn.commit()
            return cursor.rowcount > 0

    def touch_conversation(self, conv_id: int) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE conversations SET updated_at = ? WHERE id = ?",
                (_now_ms(), conv_id),
            )
            self._conn.commit()

    def delete_conversation(self, conv_id: int) -> bool:
        with self._lock:
            self._conn.execute(
                "DELETE FROM messages WHERE conv_id = ?", (conv_id,)
            )
            cursor = self._conn.execute(
                "DELETE FROM conversations WHERE id = ?", (conv_id,)
            )
            self._conn.commit()
            return cursor.rowcount > 0

    def conversation_exists(self, conv_id: int) -> bool:
        rows = self._query(
            "SELECT 1 FROM conversations WHERE id = ?", [conv_id]
        )
        return bool(rows)

    def conversation_title(self, conv_id: int) -> str | None:
        rows = self._query(
            "SELECT title FROM conversations WHERE id = ?", [conv_id]
        )
        return rows[0]["title"] if rows else None

    # ------------------------------------------------------------------ 消息

    def message_page(
        self,
        conv_id: int,
        limit: int = 30,
        before_id: int | None = None,
    ) -> dict[str, Any]:
        """取一页消息：默认是「最新 limit 条」，`before_id` 用于继续往前翻。"""
        where = "conv_id = ?"
        params: list[Any] = [conv_id]
        if before_id is not None:
            where += " AND id < ?"
            params.append(before_id)
        rows = self._query(
            f"""
            SELECT id, conv_id, role, content, reasoning, reasoning_ms, sources,
                   images, files, audio, pending, ts
            FROM messages WHERE {where}
            ORDER BY id DESC LIMIT ?
            """,
            [*params, limit + 1],
        )
        has_more = len(rows) > limit
        page = rows[:limit]
        # 反转成正序（对话从上到下），游标取本页最旧一条
        items = [self._message_row(r) for r in reversed(page)]
        return {
            "items": items,
            "has_more": has_more,
            "oldest_id": items[0]["id"] if items else None,
        }

    def append_message(
        self,
        conv_id: int,
        role: str,
        content: str,
        reasoning: str = "",
        reasoning_ms: int = 0,
        sources: list[dict[str, str]] | None = None,
        images: list[str] | None = None,
        files: list[dict[str, Any]] | None = None,
        audio: list[str] | None = None,
        pending: bool = False,
        ts: int | None = None,
        touch: bool = True,
    ) -> int:
        ts_value = ts or _now_ms()
        with self._lock:
            cursor = self._conn.execute(
                "INSERT INTO messages(conv_id, role, content, reasoning,"
                " reasoning_ms, sources, images, files, audio, pending, ts)"
                " VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    conv_id,
                    role,
                    content,
                    reasoning,
                    int(reasoning_ms or 0),
                    json.dumps(sources or [], ensure_ascii=False),
                    json.dumps(images or []),
                    json.dumps(files or [], ensure_ascii=False),
                    json.dumps(audio or []),
                    1 if pending else 0,
                    ts_value,
                ),
            )
            if touch:
                self._conn.execute(
                    "UPDATE conversations SET updated_at = ? WHERE id = ?",
                    (ts_value, conv_id),
                )
            self._conn.commit()
            return int(cursor.lastrowid or 0)

    def append_messages(self, conv_id: int, messages: list[dict[str, Any]]) -> list[int]:
        ids: list[int] = []
        for item in messages:
            ids.append(
                self.append_message(
                    conv_id,
                    role=str(item.get("role") or "user"),
                    content=str(item.get("content") or ""),
                    reasoning=str(item.get("reasoning") or ""),
                    reasoning_ms=int(item.get("reasoning_ms") or 0),
                    sources=item.get("sources") or [],
                    images=item.get("images") or [],
                    files=item.get("files") or [],
                    audio=item.get("audio") or [],
                    ts=item.get("ts"),
                    touch=False,
                )
            )
        if ids:
            self.touch_conversation(conv_id)
        return ids

    def update_message(
        self,
        message_id: int,
        content: str,
        reasoning: str = "",
        reasoning_ms: int = 0,
        sources: list[dict[str, str]] | None = None,
        audio: list[str] | None = None,
        pending: bool | None = None,
    ) -> bool:
        """更新一条消息的内容（流式 checkpoint / 最终落库共用）。

        [pending] 为 None 时不改 pending 标记；联网搜索中间轮传 True，
        最终回答/停止/出错时传 False。
        [audio] 不为 None 时更新音频列表（text_to_speech 生成的音频 id）。
        """
        with self._lock:
            audio_sql = ""
            params: list[Any] = [
                content,
                reasoning,
                int(reasoning_ms or 0),
                json.dumps(sources or [], ensure_ascii=False),
            ]
            if audio is not None:
                audio_sql = ", audio = ?"
                params.append(json.dumps(audio, ensure_ascii=False))
            if pending is None:
                params.append(message_id)
                cursor = self._conn.execute(
                    "UPDATE messages SET content = ?, reasoning = ?,"
                    f" reasoning_ms = ?, sources = ?{audio_sql} WHERE id = ?",
                    params,
                )
            else:
                params.extend([1 if pending else 0, message_id])
                cursor = self._conn.execute(
                    "UPDATE messages SET content = ?, reasoning = ?,"
                    " reasoning_ms = ?, sources = ?"
                    f"{audio_sql}, pending = ? WHERE id = ?",
                    params,
                )
            self._conn.commit()
            return cursor.rowcount > 0

    def pending_assistant_id(self, conv_id: int) -> int | None:
        """取该会话最后一条还没收尾的助手消息（联网搜索下一轮复用它）。

        只有“最后一条消息就是这条助手消息”时才复用：客户端开始新一轮提问时
        会先追加用户消息，此时最后一条不是助手消息，不会再误改上一轮的残留。
        """
        rows = self._query(
            """
            SELECT id, role, pending FROM messages
            WHERE conv_id = ?
            ORDER BY id DESC LIMIT 1
            """,
            [conv_id],
        )
        if not rows:
            return None
        row = rows[0]
        if row["role"] == "assistant" and row["pending"]:
            return int(row["id"])
        return None

    def set_message_pending(self, message_id: int, pending: bool) -> bool:
        """只改 pending 标记（没有新内容但这一轮已经结束时收尾用）。"""
        with self._lock:
            cursor = self._conn.execute(
                "UPDATE messages SET pending = ? WHERE id = ?",
                (1 if pending else 0, message_id),
            )
            self._conn.commit()
            return cursor.rowcount > 0

    def truncate_messages(self, conv_id: int, keep: int) -> int:
        """只保留最早的 keep 条消息（编辑/重新生成时截断后续内容）。

        返回值是**被删消息引用的音频 id 列表**（负数形式返回删除行数没有
        意义——调用方关心的是悬空音频），行数可以从 `message_count` 推算。
        """
        with self._lock:
            doomed = self._conn.execute(
                """
                SELECT audio FROM messages
                WHERE conv_id = ?
                  AND id NOT IN (
                    SELECT id FROM messages WHERE conv_id = ?
                    ORDER BY id ASC LIMIT ?
                  )
                """,
                (conv_id, conv_id, max(keep, 0)),
            ).fetchall()
            orphan_audio = _collect_audio_ids(doomed)
            cursor = self._conn.execute(
                """
                DELETE FROM messages
                WHERE conv_id = ?
                  AND id NOT IN (
                    SELECT id FROM messages WHERE conv_id = ?
                    ORDER BY id ASC LIMIT ?
                  )
                """,
                (conv_id, conv_id, max(keep, 0)),
            )
            self._conn.commit()
            # 把行数挂在返回值之外的方式：写进实例属性会引入并发问题，
            # 这里用元组返回更直白
            return cursor.rowcount, orphan_audio

    def truncate_messages_before(self, conv_id: int, before_id: int) -> int:
        """删除 id >= before_id 的消息（按消息 id 截断）。

        与 [truncate_messages] 相同，返回（删除行数, 被删消息的音频 id）。
        """
        with self._lock:
            doomed = self._conn.execute(
                """
                SELECT audio FROM messages
                WHERE conv_id = ? AND id >= ?
                """,
                (conv_id, before_id),
            ).fetchall()
            orphan_audio = _collect_audio_ids(doomed)
            cursor = self._conn.execute(
                "DELETE FROM messages WHERE conv_id = ? AND id >= ?",
                (conv_id, before_id),
            )
            self._conn.commit()
            return cursor.rowcount, orphan_audio

    def message_count(self, conv_id: int) -> int:
        rows = self._query(
            "SELECT COUNT(*) AS n FROM messages WHERE conv_id = ?", [conv_id]
        )
        return int(rows[0]["n"]) if rows else 0

    # ------------------------------------------------------------------ 搜索

    def search_messages(self, query: str, limit: int = 300) -> list[dict[str, Any]]:
        """在消息正文里做子串搜索（不区分大小写），返回带命中位置的条目。"""
        needle = query.strip()
        if not needle:
            return []
        escaped = needle.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        rows = self._query(
            """
            SELECT m.id, m.conv_id, m.role, m.content, m.ts, c.title
            FROM messages m JOIN conversations c ON c.id = m.conv_id
            WHERE m.content LIKE ? ESCAPE '\\'
            ORDER BY m.ts DESC, m.id DESC
            LIMIT ?
            """,
            [f"%{escaped}%", limit],
        )
        hits: list[dict[str, Any]] = []
        for row in rows:
            content = row["content"] or ""
            matches = _match_indexes(content, needle)
            if not matches:
                continue
            hits.append(
                {
                    "id": row["id"],
                    "conversation_id": row["conv_id"],
                    "conversation_title": row["title"],
                    "role": row["role"],
                    "content": content,
                    "ts": row["ts"],
                    "matches": matches,
                }
            )
        return hits

    def stats(self) -> dict[str, int]:
        conv = self._query("SELECT COUNT(*) AS n FROM conversations", [])
        msg = self._query("SELECT COUNT(*) AS n FROM messages", [])
        return {
            "conversations": int(conv[0]["n"]) if conv else 0,
            "messages": int(msg[0]["n"]) if msg else 0,
        }

    def clear(self) -> None:
        """清空全部数据（测试与运维用）。"""
        with self._lock:
            self._conn.executescript(
                "DELETE FROM messages; DELETE FROM conversations;"
            )
            self._conn.commit()

    # -------------------------------------------------------------- 内部工具

    def _query(self, sql: str, params: list[Any]) -> list[sqlite3.Row]:
        with self._lock:
            return list(self._conn.execute(sql, params).fetchall())

    @staticmethod
    def _message_row(row: sqlite3.Row) -> dict[str, Any]:
        try:
            sources = json.loads(row["sources"] or "[]")
        except json.JSONDecodeError:
            sources = []
        try:
            images = json.loads(row["images"] or "[]")
        except (json.JSONDecodeError, IndexError):
            images = []
        try:
            files = json.loads(row["files"] or "[]")
        except (json.JSONDecodeError, IndexError):
            files = []
        try:
            audio = json.loads(row["audio"] or "[]")
        except (json.JSONDecodeError, IndexError):
            audio = []
        return {
            "id": row["id"],
            "conversation_id": row["conv_id"],
            "role": row["role"],
            "content": row["content"],
            "reasoning": row["reasoning"],
            "reasoning_ms": row["reasoning_ms"],
            "sources": sources if isinstance(sources, list) else [],
            "images": images if isinstance(images, list) else [],
            "files": files if isinstance(files, list) else [],
            "audio": audio if isinstance(audio, list) else [],
            "pending": bool(row["pending"]),
            "ts": row["ts"],
        }


def _collect_audio_ids(rows: list[sqlite3.Row]) -> list[str]:
    """把被删消息的 audio 列（JSON 数组）合并成一个去重列表。"""
    ids: list[str] = []
    for row in rows:
        try:
            audio = json.loads(row["audio"] or "[]")
        except (json.JSONDecodeError, IndexError, KeyError):
            continue
        if not isinstance(audio, list):
            continue
        for item in audio:
            if isinstance(item, str) and item and item not in ids:
                ids.append(item)
    return ids


def _match_indexes(content: str, query: str) -> list[int]:
    """统计 query 在 content 中出现的字符下标（忽略大小写，最多 50 个）。"""
    if not query:
        return []
    haystack = content.lower()
    needle = query.lower()
    out: list[int] = []
    start = 0
    while len(out) < 50:
        index = haystack.find(needle, start)
        if index < 0:
            break
        out.append(index)
        start = index + len(needle)
    return out
