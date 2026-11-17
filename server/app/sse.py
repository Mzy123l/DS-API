"""SSE 增量解析：把上游流式事件累加成完整回答，供断线客户端补齐。

2026-11 版官方「全家桶」把联网搜索/阅读链接改成了**服务端工具**：
客户端只声明 `deepseek_web_search` / `deepseek_read_url`，搜索由上游自己跑，
结果以 `server_tool_use` + `web_search_tool_result` / `web_fetch_tool_result`
事件流回。这里负责把这些事件累加成 `steps`（工具步骤）与 `sources`（来源），
并把引用（citations）一并收进来。
"""

from __future__ import annotations

import json
import time
from typing import Any, Literal
from urllib.parse import urlsplit

JobStatus = Literal["starting", "running", "done", "error", "canceled"]

PROTOCOL_ANTHROPIC = "anthropic"
PROTOCOL_RESPONSES = "responses"
# Chat Completions 协议：本项目不主动用，但服务端工具事件也一并解析，避免解析错
PROTOCOL_CHAT = "chat"

# 服务端工具的种类（官方 2026-11 全家桶）
SERVER_TOOL_KINDS = frozenset(
    {"search", "deep_search", "read_link", "image_search", "deep_image_search"}
)

# 由**中转服务**执行的函数工具（模型调用、服务端执行、结果回填）。
# 注意：search / fetch 不再是函数工具——联网搜索已由上游服务端执行。
SERVER_FUNCTION_TOOL_NAMES = frozenset({"ocr", "text_to_speech"})

# 旧名字保留：外部若还按这个常量导入不会断
CLIENT_TOOL_NAMES = SERVER_FUNCTION_TOOL_NAMES

# 服务端工具名 → 种类（Anthropic 的 server_tool_use.name）
_TOOL_NAME_KINDS = {
    "web_search": "search",
    "deep_search": "deep_search",
    "web_fetch": "read_link",
    "read_url": "read_link",
    "web_read": "read_link",
    "image_search": "image_search",
    "deep_image_search": "deep_image_search",
}

# 种类 → 步骤动作（契约里的 action 字段）
_KIND_ACTIONS = {
    "search": "search",
    "deep_search": "search",
    "read_link": "read_link",
    "image_search": "image_search",
    "deep_image_search": "image_search",
}


def upstream_path(protocol: str, base_url: str) -> str:
    """按协议与上游 base 计算请求路径。

    与客户端 endpointUrl 的规则保持一致：
    - responses：{base}/responses
    - anthropic：base 自带路径时用 {base}/messages，否则 {base}/anthropic/v1/messages
    """
    # 只看 base 里自带的路径部分：带路径说明用户已经指定到接口层级
    path = urlsplit(base_url).path.strip("/")
    if protocol == PROTOCOL_RESPONSES:
        return "/responses"
    return "/messages" if path else "/anthropic/v1/messages"


def _as_text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _non_empty(value: Any) -> str | None:
    """把可选字符串字段规整成「非空字符串或 None」。"""
    if isinstance(value, str) and value:
        return value
    return None


class StreamAccumulator:
    """按协议累加上游 SSE 事件。

    支持两种主协议：
    - anthropic：content_block_delta(thinking_delta/text_delta)、
      content_block_start(server_tool_use / web_search_tool_result /
      web_fetch_tool_result)、citations_delta、message_stop、error
    - responses：response.reasoning_text.delta / response.output_text.delta、
      web_search_call item、response.output_text.annotation.added、
      response.completed、response.failed
    以及 Chat Completions 的 `server_tool_event`（只解析、不主动使用）。
    """

    def __init__(self, protocol: str) -> None:
        self.protocol = protocol
        self.reasoning = ""
        self.content = ""
        # 来源：旧字段 title/url 一定在；site_name/snippet/page_age 有值才带
        self.sources: list[dict[str, Any]] = []
        # 工具步骤（服务端搜索/读链接）
        self.steps: list[dict[str, Any]] = []
        # 引用（Anthropic citations / Responses annotations）
        self.citations: list[dict[str, Any]] = []
        self.error: str | None = None
        self.done = False
        # 本轮是否出现了需要服务端执行的函数工具调用（目前只有 ocr）
        self.tool_use = False
        # 本轮的工具调用明细（由服务端工具循环执行）
        self.round_tool_calls: list[dict[str, str]] = []
        self._anthropic_tool_indexes: dict[int, dict[str, str]] = {}
        self._response_tool_ids: dict[str, dict[str, str]] = {}
        # 服务端工具：Anthropic 按 content block 下标、Responses 按 item id 关联
        self._step_by_index: dict[int, dict[str, Any]] = {}
        self._step_by_id: dict[str, dict[str, Any]] = {}
        # 思考/正文各自开始的时间戳（毫秒），用于回填"思考用时"
        self.reasoning_started_at: int | None = None
        self.content_started_at: int | None = None
        self._reasoning_delta_seen = False
        self._content_delta_seen = False

    def reset_round_tools(self) -> None:
        """开始下一轮上游请求前清掉上一轮的工具调用（内容/思考保留）。"""
        self.round_tool_calls = []
        self._anthropic_tool_indexes = {}
        self._response_tool_ids = {}
        self.tool_use = False
        self.done = False

    def add_sources(self, sources: list[dict[str, Any]]) -> None:
        """外部（例如服务端执行工具后）补充来源。"""
        self._add_sources(sources)

    def feed(self, line: str) -> None:
        """喂入一行原始 SSE 文本（非 data 行会被忽略）。"""
        raw = line.strip()
        if not raw.startswith("data:"):
            return
        data = raw[5:].strip()
        if not data:
            return
        if data == "[DONE]":
            if self.protocol != PROTOCOL_ANTHROPIC:
                self.done = True
            return
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            return
        if not isinstance(event, dict):
            return
        if self.protocol == PROTOCOL_ANTHROPIC:
            self._feed_anthropic(event)
        elif self.protocol == PROTOCOL_CHAT:
            self._feed_chat(event)
        else:
            self._feed_responses(event)

    # ------------------------------------------------------------------ 内部

    def _feed_anthropic(self, event: dict[str, Any]) -> None:
        etype = event.get("type")
        if etype == "error":
            self.error = _error_message(event.get("error"), "API 请求失败")
            return
        if etype == "message_stop":
            self.done = True
            return
        if etype == "content_block_start":
            block = event.get("content_block")
            if not isinstance(block, dict):
                return
            btype = block.get("type")
            index = event.get("index")
            if btype == "thinking":
                self._add_reasoning(_as_text(block.get("thinking")))
            elif btype == "text":
                self._add_content(_as_text(block.get("text")))
                self._add_citations(block.get("citations"))
            elif btype == "server_tool_use":
                step = self._start_anthropic_server_tool(block)
                if step is not None and isinstance(index, int):
                    self._step_by_index[index] = step
            elif btype == "web_search_tool_result":
                self._apply_search_result(block, index)
            elif btype == "web_fetch_tool_result":
                self._apply_fetch_result(block, index)
            elif btype == "tool_use":
                name = block.get("name")
                if name in SERVER_FUNCTION_TOOL_NAMES:
                    call = {
                        "id": str(block.get("id") or ""),
                        "name": str(name),
                        "arguments": "",
                    }
                    initial = block.get("input")
                    if isinstance(initial, dict) and initial:
                        call["arguments"] = json.dumps(
                            initial, ensure_ascii=False
                        )
                    self.round_tool_calls.append(call)
                    self.tool_use = True
                    if isinstance(index, int):
                        self._anthropic_tool_indexes[index] = call
            return
        if etype == "content_block_delta":
            delta = event.get("delta")
            if not isinstance(delta, dict):
                return
            dtype = delta.get("type")
            if dtype == "thinking_delta":
                self._add_reasoning(_as_text(delta.get("thinking")))
            elif dtype == "text_delta":
                self._add_content(_as_text(delta.get("text")))
            elif dtype == "citations_delta":
                self._add_citations([delta.get("citation")])
            elif dtype == "input_json_delta":
                index = event.get("index")
                partial = delta.get("partial_json")
                if not isinstance(partial, str):
                    return
                # 服务端工具的入参（query / url）在流式 delta 里拼出来
                step = (
                    self._step_by_index.get(index)
                    if isinstance(index, int)
                    else None
                )
                if step is not None:
                    self._append_step_input(step, partial)
                    return
                call = (
                    self._anthropic_tool_indexes.get(index)
                    if isinstance(index, int)
                    else None
                )
                if call is not None:
                    call["arguments"] += partial
            return

    def _feed_responses(self, event: dict[str, Any]) -> None:
        etype = event.get("type")
        if etype == "response.failed":
            self.error = _error_message(event.get("error"), "API 请求失败")
            return
        error = event.get("error")
        if isinstance(error, dict):
            self.error = _error_message(error, "API 错误")
            return
        if etype == "response.reasoning_text.delta":
            delta = _as_text(event.get("delta"))
            if delta:
                self._reasoning_delta_seen = True
                self._add_reasoning(delta)
            return
        if etype == "response.reasoning_text.done":
            # 兜底：上游只发 .done（无 delta）时用它补内容，避免重复
            if not self._reasoning_delta_seen:
                self._add_reasoning(
                    _as_text(event.get("delta")) or _as_text(event.get("text"))
                )
            return
        if etype == "response.output_text.delta":
            delta = _as_text(event.get("delta"))
            if delta:
                self._content_delta_seen = True
                self._add_content(delta)
            return
        if etype == "response.output_text.done":
            if not self._content_delta_seen:
                self._add_content(
                    _as_text(event.get("delta")) or _as_text(event.get("text"))
                )
            return
        if etype == "response.output_text.annotation.added":
            annotation = event.get("annotation")
            if isinstance(annotation, dict):
                self._add_citations([annotation])
            return
        if etype == "response.completed":
            response = event.get("response")
            output = response.get("output") if isinstance(response, dict) else None
            if isinstance(output, list):
                for item in output:
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") == "function_call":
                        self._add_response_tool(item, update=True)
                    elif item.get("type") == "web_search_call":
                        self._apply_response_web_search_call(item, update=True)
            self.done = True
            return
        if etype == "response.output_item.added":
            item = event.get("item")
            if isinstance(item, dict):
                if item.get("type") == "function_call":
                    self._add_response_tool(item)
                elif item.get("type") == "web_search_call":
                    self._apply_response_web_search_call(item)
            return
        if etype == "response.function_call_arguments.delta":
            item_id = event.get("item_id")
            call = (
                self._response_tool_ids.get(item_id)
                if isinstance(item_id, str)
                else None
            )
            delta = event.get("delta")
            if call is not None and isinstance(delta, str):
                call["arguments"] += delta
            return
        if etype == "response.function_call_arguments.done":
            item_id = event.get("item_id")
            call = (
                self._response_tool_ids.get(item_id)
                if isinstance(item_id, str)
                else None
            )
            args = event.get("arguments")
            if call is not None and isinstance(args, str):
                call["arguments"] = args
            return
        if etype == "response.output_item.done":
            item = event.get("item")
            if isinstance(item, dict):
                if item.get("type") == "function_call":
                    self._add_response_tool(item, update=True)
                elif item.get("type") == "web_search_call":
                    self._apply_response_web_search_call(item, update=True)
            return

    def _feed_chat(self, event: dict[str, Any]) -> None:
        """Chat Completions：只认 `server_tool_event`，其余按普通增量处理。"""
        etype = event.get("type")
        if etype == "error":
            self.error = _error_message(event.get("error"), "API 请求失败")
            return
        if etype in ("[DONE]", "done"):
            self.done = True
            return
        if etype == "server_tool_event":
            # 事件体可能包一层 `event`，两种形状都认
            payload = event.get("event")
            if not isinstance(payload, dict):
                payload = event
            self._apply_chat_server_tool(payload)
            return
        if etype in ("reasoning_content", "reasoning"):
            self._add_reasoning(_as_text(event.get("content") or event.get("delta")))
            return
        if etype in ("content", "content_delta"):
            self._add_content(_as_text(event.get("content") or event.get("delta")))
            return
        choices = event.get("choices")
        if isinstance(choices, list):
            for choice in choices:
                if not isinstance(choice, dict):
                    continue
                delta = choice.get("delta")
                if not isinstance(delta, dict):
                    continue
                self._add_reasoning(_as_text(delta.get("reasoning_content")))
                self._add_content(_as_text(delta.get("content")))
            return

    # ------------------------------------------------- 服务端工具步骤（新增）

    def _start_anthropic_server_tool(
        self, block: dict[str, Any]
    ) -> dict[str, Any] | None:
        """`content_block_start` 的 server_tool_use：登记一个 running 步骤。"""
        kind = _normalize_kind(block.get("kind"), block.get("name"))
        if kind is None:
            return None
        step = self._new_step(kind)
        step["id"] = _non_empty(block.get("id")) or ""
        initial = block.get("input")
        if isinstance(initial, dict):
            self._apply_step_input(step, initial)
        return step

    def _apply_search_result(self, block: dict[str, Any], index: Any) -> None:
        """`web_search_tool_result`：补来源，并把对应步骤标成完成/失败。"""
        content = block.get("content")
        step = self._step_for_result(block, index, "search")
        if step is None:
            kind = _normalize_kind(block.get("kind"), None) or "search"
            step = self._new_step(kind)
        error = _tool_result_error(content)
        if error is not None:
            step["status"] = "error"
            step["error"] = error
            return
        added = self._add_sources(content)
        step["status"] = "done"
        step["result_count"] = len(added)

    def _apply_fetch_result(self, block: dict[str, Any], index: Any) -> None:
        """`web_fetch_tool_result`：kind 是 read_link / deep_search。"""
        content = block.get("content")
        kind = _normalize_kind(block.get("kind"), None)
        step = self._step_for_result(block, index, kind or "read_link")
        if step is None:
            step = self._new_step(kind or "read_link")
        step["signature"] = _non_empty(block.get("signature")) or ""
        if not isinstance(content, dict):
            step["status"] = "error"
            step["error"] = "unavailable"
            return
        if content.get("type") == "web_fetch_tool_result_error":
            step["status"] = "error"
            step["error"] = _non_empty(content.get("error_code")) or "unavailable"
            return
        url = _non_empty(content.get("url"))
        if url:
            step["url"] = url
        title = _non_empty(content.get("title"))
        if title is None:
            document = content.get("content")
            if isinstance(document, dict):
                title = _non_empty(document.get("title"))
        if title:
            step["title"] = title
        if url:
            self._add_sources([{"url": url, "title": title or url}])
        step["status"] = "done"

    def _apply_response_web_search_call(
        self, item: dict[str, Any], update: bool = False
    ) -> None:
        """Responses 的 `web_search_call` item（搜索/打开页面/页内查找）。"""
        item_id = _non_empty(item.get("id")) or ""
        action = item.get("action") if isinstance(item.get("action"), dict) else {}
        action_type = _non_empty(action.get("type")) if action else None
        kind = _normalize_kind(item.get("kind"), action_type)
        if kind is None:
            kind = _KIND_FROM_ACTION.get(action_type or "", "search")
        step = self._step_by_id.get(item_id) if item_id else None
        if step is None:
            step = self._new_step(kind)
            if item_id:
                step["id"] = item_id
                self._step_by_id[item_id] = step
        else:
            step["kind"] = kind
            step["action"] = _KIND_ACTIONS.get(kind, step.get("action", "search"))
        if action:
            queries = action.get("queries")
            if isinstance(queries, list):
                text = "、".join(
                    q for q in queries if isinstance(q, str) and q
                )
                if text:
                    step["query"] = text
            url = _non_empty(action.get("url"))
            if url:
                step["url"] = url
            pattern = _non_empty(action.get("pattern"))
            if pattern:
                step["pattern"] = pattern
            self._add_sources(action.get("sources"))
        page = item.get("page")
        if isinstance(page, dict):
            url = _non_empty(page.get("url"))
            if url:
                if not step.get("url"):
                    step["url"] = url
                # 打开/查找过的页面本身也算来源，客户端可以直接展示
                self._add_sources(
                    [{"url": url, "title": _non_empty(page.get("title")) or url}]
                )
        elif step.get("url") and step.get("action") == "read_link":
            # open_page / find_in_page 只给了 action.url 时，同样算一条来源
            self._add_sources(
                [{"url": step["url"], "title": step.get("title") or step["url"]}]
            )
        step["signature"] = _non_empty(item.get("signature")) or ""
        status = _non_empty(item.get("status"))
        error = item.get("error")
        if error:
            step["status"] = "error"
            step["error"] = _error_message(error, "unavailable")
        elif status in ("completed", "done", "succeeded"):
            step["status"] = "done"
        elif status in ("failed", "error"):
            step["status"] = "error"
        elif update and status is None:
            step["status"] = "done"

    def _apply_chat_server_tool(self, payload: dict[str, Any]) -> None:
        """Chat Completions 的 server_tool_event：尽力解析成步骤。"""
        action = payload.get("action")
        if isinstance(action, dict):
            kind = _normalize_kind(payload.get("kind"), action.get("type"))
            if kind is None:
                kind = _KIND_FROM_ACTION.get(
                    _non_empty(action.get("type")) or "", "search"
                )
            step = self._new_step(kind)
            queries = action.get("queries")
            if isinstance(queries, list):
                step["query"] = "、".join(
                    q for q in queries if isinstance(q, str) and q
                )
            url = _non_empty(action.get("url"))
            if url:
                step["url"] = url
            self._add_sources(action.get("sources") or payload.get("results"))
        else:
            kind = _normalize_kind(payload.get("kind"), payload.get("name"))
            if kind is None:
                return
            step = self._new_step(kind)
            query = _non_empty(payload.get("query"))
            if query:
                step["query"] = query
            url = _non_empty(payload.get("url"))
            if url:
                step["url"] = url
            self._add_sources(payload.get("results") or payload.get("sources"))
        status = _non_empty(payload.get("status"))
        if status in ("completed", "done", "succeeded", None):
            step["status"] = "done" if status else "running"
        elif status in ("failed", "error"):
            step["status"] = "error"

    # ------------------------------------------------------- 步骤内部工具

    def _new_step(self, kind: str) -> dict[str, Any]:
        """新建一个工具步骤（默认 running，等结果事件再改状态）。"""
        step: dict[str, Any] = {
            "kind": kind,
            "action": _KIND_ACTIONS.get(kind, "search"),
            "status": "running",
        }
        self.steps.append(step)
        return step

    def _step_for_index(self, index: Any) -> dict[str, Any] | None:
        if isinstance(index, int):
            return self._step_by_index.get(index)
        return None

    def _step_for_result(
        self, block: dict[str, Any], index: Any, kind: str
    ) -> dict[str, Any] | None:
        """把结果事件对到它的 server_tool_use 步骤。

        官方两个事件是**各自独立的 content block**（下标不同），所以不能只按
        index 找；按 `tool_use_id` 找最可靠，找不到再退回「最近一个同 kind、
        状态还是 running 的步骤」，都没有就返回 None（调用方新建步骤）。
        """
        tool_use_id = _non_empty(block.get("tool_use_id"))
        if tool_use_id:
            for step in reversed(self.steps):
                if step.get("id") == tool_use_id:
                    return step
        for step in reversed(self.steps):
            if step.get("kind") == kind and step.get("status") == "running":
                return step
        return self._step_for_index(index)

    def _apply_step_input(self, step: dict[str, Any], payload: dict[str, Any]) -> None:
        """把 server_tool_use.input 里的 query / url 填进步骤。"""
        query = _non_empty(payload.get("query"))
        if query:
            step["query"] = query
        url = _non_empty(payload.get("url"))
        if url:
            step["url"] = url
        pattern = _non_empty(payload.get("pattern"))
        if pattern:
            step["pattern"] = pattern

    def _append_step_input(self, step: dict[str, Any], partial: str) -> None:
        """流式拼接入参，拼完能解析出 JSON 时就回填步骤并丢掉缓冲。"""
        buffered = str(step.get("_input") or "") + partial
        try:
            decoded = json.loads(buffered)
        except json.JSONDecodeError:
            step["_input"] = buffered
            return
        step.pop("_input", None)
        if isinstance(decoded, dict):
            self._apply_step_input(step, decoded)

    def _add_response_tool(
        self, item: dict[str, Any], update: bool = False
    ) -> None:
        """记录一个 Responses function_call（只收服务端要执行的函数工具）。"""
        name = item.get("name")
        if name not in SERVER_FUNCTION_TOOL_NAMES:
            return
        item_id = item.get("id")
        existing = (
            self._response_tool_ids.get(item_id)
            if isinstance(item_id, str)
            else None
        )
        args = item.get("arguments")
        if existing is not None:
            if update and isinstance(args, str):
                existing["arguments"] = args
            self.tool_use = True
            return
        call = {
            "id": str(item.get("call_id") or item_id or ""),
            "name": str(name),
            "arguments": args if isinstance(args, str) else "",
        }
        self.round_tool_calls.append(call)
        self.tool_use = True
        if isinstance(item_id, str):
            self._response_tool_ids[item_id] = call

    # 记录首个非空增量，用于计算思考用时
    def _add_reasoning(self, text: str) -> None:
        if not text:
            return
        if self.reasoning_started_at is None:
            self.reasoning_started_at = int(time.time() * 1000)
        self.reasoning += text

    def _add_content(self, text: str) -> None:
        if not text:
            return
        if self.content_started_at is None:
            self.content_started_at = int(time.time() * 1000)
        self.content += text

    def reasoning_ms(self) -> int:
        """思考用时（首个思考增量 → 首个正文增量）。"""
        if self.reasoning_started_at is None or self.content_started_at is None:
            return 0
        return max(0, self.content_started_at - self.reasoning_started_at)

    def _add_sources(self, content: Any) -> list[dict[str, Any]]:
        """把搜索结果补进 sources（按 url 去重），返回本次新增的条目。"""
        if not isinstance(content, list):
            return []
        seen = {item.get("url") for item in self.sources}
        added: list[dict[str, Any]] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            url = item.get("url")
            if not isinstance(url, str) or not url or url in seen:
                continue
            title = item.get("title")
            source: dict[str, Any] = {
                "title": title if isinstance(title, str) and title else url,
                "url": url,
            }
            # 契约新增字段：有值才带，旧字段一个不少
            site_name = _non_empty(item.get("site_name"))
            if site_name:
                source["site_name"] = site_name
            snippet = _non_empty(item.get("snippet"))
            if snippet:
                source["snippet"] = snippet
            page_age = _non_empty(item.get("page_age"))
            if page_age:
                source["page_age"] = page_age
            site_icon = _non_empty(item.get("site_icon"))
            if site_icon:
                source["site_icon"] = site_icon
            image_url = _non_empty(item.get("image_url"))
            if image_url:
                source["image_url"] = image_url
            self.sources.append(source)
            added.append(source)
            seen.add(url)
        return added

    def _add_citations(self, citations: Any) -> None:
        """收集引用（Anthropic citations / Responses annotations）。"""
        if not isinstance(citations, list):
            return
        for citation in citations:
            if not isinstance(citation, dict):
                continue
            url = _non_empty(citation.get("url"))
            title = _non_empty(citation.get("title")) or url
            if not url and not title:
                continue
            entry: dict[str, Any] = {}
            if title:
                entry["title"] = title
            if url:
                entry["url"] = url
            cited_text = _non_empty(citation.get("cited_text"))
            if cited_text:
                entry["cited_text"] = cited_text
            for key in ("start_index", "end_index", "encrypted_index"):
                value = citation.get(key)
                if isinstance(value, int):
                    entry[key] = value
            self.citations.append(entry)
            # 引用里的链接同样是来源：补进 sources，客户端不用再单独处理
            if url:
                self._add_sources([{"url": url, "title": title or url}])


# Responses 的 action.type → 种类
_KIND_FROM_ACTION = {
    "search": "search",
    "open_page": "read_link",
    "find_in_page": "read_link",
    "image_search": "image_search",
}


def _normalize_kind(raw_kind: Any, raw_name: Any) -> str | None:
    """把 kind / 工具名规整成契约里的种类名，认不出返回 None。"""
    if isinstance(raw_kind, str) and raw_kind in SERVER_TOOL_KINDS:
        return raw_kind
    if isinstance(raw_name, str):
        if raw_name in SERVER_TOOL_KINDS:
            return raw_name
        mapped = _TOOL_NAME_KINDS.get(raw_name)
        if mapped is not None:
            return mapped
    return None


def _tool_result_error(content: Any) -> str | None:
    """工具结果里的错误码：`[{"type":"..._error","error_code":"unavailable"}]`。"""
    if not isinstance(content, list) or not content:
        return None
    first = content[0]
    if not isinstance(first, dict):
        return None
    result_type = _non_empty(first.get("type")) or ""
    if not result_type.endswith("_error"):
        return None
    return _non_empty(first.get("error_code")) or "unavailable"


def _error_message(error: Any, fallback: str) -> str:
    if isinstance(error, dict):
        message = error.get("message")
        if isinstance(message, str) and message:
            return message
        code = error.get("code")
        if isinstance(code, str) and code:
            return code
    if isinstance(error, str) and error:
        return error
    return fallback


def extract_error(body: str, status: int) -> str:
    """从上游错误响应体里取出可读信息（与客户端同款兜底文案）。"""
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError:
        return f"请求失败 (HTTP {status})"
    if isinstance(decoded, dict):
        error = decoded.get("error")
        if isinstance(error, dict):
            message = error.get("message")
            if isinstance(message, str) and message:
                return message
        if isinstance(error, str) and error:
            return error
    return f"请求失败 (HTTP {status})"
