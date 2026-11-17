# 全家桶 API 接入契约（2026-11 版）

本文是客户端（Flutter）与中转服务（ds-relay）之间的内部契约，对齐官方
[更新日志 2026-11-13](https://api-docs.deepseek.com/zh-cn/updates) 发布的
「全家桶应用 API」：联网搜索、文件输入、阅读链接、OCR、ASR、TTS。

上游官方接口一律由中转代理，客户端只认本文的地址；API Key 仍由客户端通过
`Authorization: Bearer <key>`（或 `x-api-key: <key>`）透传，服务端不落盘。

---

## 1. 能力与官方接口对照

| 能力 | 官方接口 | 官方约束 |
| --- | --- | --- |
| 联网搜索 | 对话请求里声明 `{"type":"deepseek_web_search"}` | 仅 `deepseek-flash`；搜索由上游服务端执行 |
| 阅读链接 | 对话请求里声明 `{"type":"deepseek_read_url"}` | 只读**最后一条**用户消息里的 URL，最多 10 个 |
| 文件输入 | `POST /files` 拿 `file_id`，对话里引用 | `purpose` 必须放在 `file` 之前；≤100 MiB / 1000 页 |
| OCR | `POST /v1/tools/ocr`（multipart） | `file` + `purpose` 两个字段，传其他字段 400 |
| ASR | `POST /v1/tools/asr`（multipart） | 16-bit PCM WAV 或 Ogg Opus，≤8 MiB，≤120 秒 |
| TTS | `POST /v1/tools/tts`（JSON，流式音频） | 音色 `stella`（海星，本项目只用它）；≤10000 计费字符 |

> 本项目音色固定为官方默认的 `stella`（海星）。官方目前只开放
> `stella` / `tide` 两种，客户端枚举按多值设计以备扩展，界面只展示海星。

`tool_choice` 不能指定 `deepseek_web_search` / `deepseek_read_url`，否则 400。
声明这两个工具时 `temperature`、`top_p`、`stop`、`n` 等参数会被上游忽略。

---

## 2. 中转新增接口

所有 `/v1` 接口在服务端配置了 `RELAY_TOKEN` 时都必须带 `x-relay-token`。

### 2.1 `POST /v1/files` — 上传并解析文档

- 请求：`multipart/form-data`，字段顺序必须是 `purpose` 在前、`file` 在后。
  - `purpose`: `text_recognition` | `rich_layout_recognition` | `user_data`
- 中转行为：把文件原样转发到上游 `POST {base}/files`；**同时把字节缓存一份**
  （键为上游返回的 `id`），供后续 `ocr` 工具读取。
- 响应：原样透传上游 JSON，例如
  `{"id":"file-api-xxx","object":"file","bytes":1048576,"filename":"a.pdf","purpose":"text_recognition"}`

### 2.2 `GET /v1/files` — 列出已上传文件

原样透传上游 `GET {base}/files`，便于排查缓存与配额。

### 2.3 `POST /v1/tools/ocr` — 识别文字

- 请求：`multipart/form-data`，`file` + `purpose`。
- 响应：上游 OCR JSON（`{id, page_count, pages:[{index,text,finish_reason}], usage}`）。

### 2.4 `POST /v1/tools/asr` — 语音识别

- 请求：`multipart/form-data`，`file` 为 16-bit PCM WAV 或 Ogg Opus。
- 响应：`{"request_id":"...","text":"...","duration_ms":3200}`。

### 2.5 `POST /v1/tools/tts` — 语音合成

- 请求：JSON `{"text":"...","voice_id":"stella|tide","format":"wav","filter_markdown":true}`
- 响应：二进制音频，`Content-Type: audio/wav`，透传上游的 `X-Billed-Chars`（若有）。
- 失败时返回上游的 JSON 错误体与状态码。
- 历史：曾支持 `format=pcm`（裸数据、无容器头）。该路线因「下载出来的
  音频没有容器头、播放器报格式不对」已废弃，现在只接受 `wav`。

### 2.6 `POST /v1/tools/search`、`POST /v1/tools/fetch`

保留原样（官方独立 Search / Fetch 接口），用于直连模式的兜底与调试。

### 2.7 `GET /healthz`

新增 `capabilities` 字段，列出服务端已接通的代理能力，便于客户端降级判断。

---

## 3. 对话请求里的工具声明

### 3.1 Anthropic（`/anthropic/v1/messages`）

```json
"tools": [
  {"type": "deepseek_web_search", "name": "deepseek_web_search"},
  {"type": "deepseek_read_url",  "name": "deepseek_read_url"}
]
```

引用文档时消息内容块：

```json
{"type": "document", "source": {"type": "file", "file_id": "file-api-xxx"}}
```

**必须带请求头** `anthropic-beta: files-api-2025-04-14`。

### 3.2 Responses（`/responses`）

```json
"tools": [{"type": "deepseek_web_search"}, {"type": "deepseek_read_url"}]
```

引用文档：

```json
{"type": "input_file", "file_id": "file-api-xxx"}
```

### 3.3 联网工具与函数工具的共存限制

官方错误表里有「声明了其他服务端工具 → 400」。为规避风险：

- **开启联网搜索时**：只声明 `deepseek_web_search` + `deepseek_read_url`，
  不声明任何函数工具；
- **关闭联网搜索时**：可声明 `ocr` / `text_to_speech` 函数工具，
  由客户端（直连）或中转服务执行。

### 3.4 `ocr` 函数工具（中转服务执行）

客户端在 `tools` 里声明，中转服务在模型调用时执行：

```json
{
  "name": "ocr",
  "description": "识别用户上传的文档或图片中的文字。传入 /v1/files 返回的 file_id。",
  "parameters": {
    "type": "object",
    "properties": {
      "file_id": {"type": "string", "description": "上传文档后返回的 file_id"},
      "purpose": {"type": "string", "enum": ["text_recognition", "rich_layout_recognition"]}
    },
    "required": ["file_id"]
  }
}
```

中转服务按 `file_id` 从缓存取出原始字节，调用上游 `/v1/tools/ocr`，
把逐页文本拼成文本回填给模型。

### 3.5 `text_to_speech` 函数工具（客户端执行）

让模型**直接产出一个音频文件**（不是「朗读当前回答」）。

```json
{
  "name": "text_to_speech",
  "description": "把文字合成为语音音频文件……",
  "parameters": {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"]
  }
}
```

客户端收到调用后请求 `/v1/tools/tts`，把音频落成独立文件
（`speech-<时间戳>-<哈希>.wav`），返回 `{status, file, message}` 给模型，
并在该条回答下方渲染音频卡片（点左侧圆形图标播放/停止）。

---

## 4. 服务端 SSE 解析约定

中转服务把上游事件累加成完整回答，快照字段与旧版兼容，新增：

| 字段 | 说明 |
| --- | --- |
| `sources[].site_name` | 站点名（`web_search_tool_result` 的扩展字段） |
| `sources[].snippet` | 摘要 |
| `sources[].page_age` | 发布时间（RFC 3339） |
| `steps[]` | 工具步骤：`{kind, action, query/url, status}` |

`kind` 取值：`search`、`deep_search`、`read_link`、`image_search`、`deep_image_search`。

---

## 5. 客户端存储约定

消息新增 `files` 列（JSON 数组，元素为 `{"id":"file-api-xxx","name":"a.pdf","size":123}`），
与 `images` 同构；重放历史时据此重新生成 `document` / `input_file` 内容块。
