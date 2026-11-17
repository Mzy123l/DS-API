"""上传文件的内存缓存：给服务端执行的 `ocr` 工具取原始字节用。

为什么要缓存：`POST /v1/files` 把文件传上去以后，上游只回一个 `file_id`；
模型之后调用 `ocr` 工具时只带 `file_id`，拿不到原始字节，无法再调一次
`/v1/tools/ocr`（那个接口要 multipart 的 file）。所以上传成功时顺手把字节
留一份在内存里。

容量控制：按「总字节数 + 条目数」双上限做 LRU 淘汰，避免长期占内存；
进程重启后缓存清空，此时 `ocr` 工具会明确告知模型让用户重新上传。
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from dataclasses import dataclass

# 默认上限：单文件 ≤100 MiB（官方限制），这里总容量按 256 MiB / 64 个文件
DEFAULT_MAX_BYTES = 256 * 1024 * 1024
DEFAULT_MAX_ENTRIES = 64


@dataclass
class CachedFile:
    """一个缓存的上传文件。

    [owner] 是可选项：生成类缓存（如 TTS 音频）用它记录「属于哪个会话」，
    会话删除时可以按 owner 把孤儿音频一并清掉。上传类文件没有明确的
    所属会话，保持 None。
    """

    file_id: str
    filename: str
    content_type: str
    data: bytes
    owner: int | None = None

    @property
    def size(self) -> int:
        return len(self.data)


class FileCache:
    """线程安全的 LRU 文件缓存。

    命中会把条目挪到队尾（最近使用），淘汰从队头开始：
    先按字节数淘汰，再按条目数淘汰，两者任一超限都会触发。
    """

    def __init__(
        self,
        max_bytes: int = DEFAULT_MAX_BYTES,
        max_entries: int = DEFAULT_MAX_ENTRIES,
    ) -> None:
        self.max_bytes = max(0, max_bytes)
        self.max_entries = max(0, max_entries)
        self._items: OrderedDict[str, CachedFile] = OrderedDict()
        self._bytes = 0
        self._lock = threading.Lock()
        # 累计淘汰次数：便于排查「为什么 ocr 说文件不在了」
        self.evictions = 0

    # ------------------------------------------------------------ 读写接口

    def put(self, cached: CachedFile) -> bool:
        """放入一个文件；超出容量时淘汰最久未用的条目。返回是否成功存入。

        单个文件本身就超过总容量上限时不缓存（返回 False），
        否则会把整个缓存挤空还放不下。
        """
        if not cached.file_id or not cached.data:
            return False
        if self.max_entries <= 0 or self.max_bytes <= 0:
            return False
        if cached.size > self.max_bytes:
            return False
        with self._lock:
            existing = self._items.pop(cached.file_id, None)
            if existing is not None:
                self._bytes -= existing.size
            self._items[cached.file_id] = cached
            self._bytes += cached.size
            self._evict_locked()
            return cached.file_id in self._items

    def get(self, file_id: str) -> CachedFile | None:
        """取文件并把条目标记为最近使用；不存在返回 None。"""
        if not file_id:
            return None
        with self._lock:
            cached = self._items.get(file_id)
            if cached is None:
                return None
            self._items.move_to_end(file_id)
            return cached

    def discard(self, file_id: str) -> bool:
        """删掉一个条目（测试与显式失效用）。"""
        with self._lock:
            cached = self._items.pop(file_id, None)
            if cached is None:
                return False
            self._bytes -= cached.size
            return True

    def discard_owner(self, owner: int) -> int:
        """删掉某个会话名下的全部条目，返回删除的数量。

        会话被删除时调用：否则该会话生成的音频会一直占着缓存，
        直到 LRU 自然淘汰，还会把活跃会话的音频挤出去。
        """
        with self._lock:
            orphan_ids = [
                fid
                for fid, cached in self._items.items()
                if cached.owner == owner
            ]
            for fid in orphan_ids:
                cached = self._items.pop(fid)
                self._bytes -= cached.size
            return len(orphan_ids)

    def clear(self) -> None:
        with self._lock:
            self._items.clear()
            self._bytes = 0

    # ------------------------------------------------------------ 状态查询

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)

    @property
    def total_bytes(self) -> int:
        with self._lock:
            return self._bytes

    def ids(self) -> list[str]:
        """按「最久未用 → 最近使用」顺序返回所有 file_id。"""
        with self._lock:
            return list(self._items.keys())

    def stats(self) -> dict[str, int]:
        with self._lock:
            return {
                "files": len(self._items),
                "bytes": self._bytes,
                "max_files": self.max_entries,
                "max_bytes": self.max_bytes,
                "evictions": self.evictions,
            }

    # ------------------------------------------------------------ 内部实现

    def _evict_locked(self) -> None:
        """按 LRU 淘汰，直到两个上限都满足。"""
        while self._items and (
            len(self._items) > self.max_entries or self._bytes > self.max_bytes
        ):
            _, dropped = self._items.popitem(last=False)
            self._bytes -= dropped.size
            self.evictions += 1
