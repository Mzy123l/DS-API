# DS-API 中转服务（ds-relay）

> 线上部署、日常运维、故障处理见 [../README.md](../README.md)。

## 解决什么问题

安卓 App 退到后台后，系统会冻结进程和网络，正在生成的长回答容易「半死」——
本地连接断了，内容也就没了。

这个服务把**生成这件事挪到服务器上**：

1. App 把请求交给服务器，服务器立刻返回一个任务号；
2. 服务器自己跟 DeepSeek 建立流式连接并持续读取，**App 断线也不影响它跑完**；
3. App 拿到任务号后走两条路：
   - 正在前台：直接收服务器转发的流式事件（体验与直连完全一致）；
   - 断线/退后台/进程被杀：重新打开 App 后按任务号拉取快照，把完整回答补齐。

API Key 全程由客户端携带（透传给上游），服务端**不落盘、不记录**。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/v1/chat` | 创建任务并流式返回。Body：`{"protocol":"anthropic"｜"responses","payload":{...上游请求体...}}`；鉴权头 `x-api-key`（anthropic）/`authorization`（responses）原样透传 |
| GET | `/v1/jobs/{job_id}` | 任务快照：`status`（starting/running/done/error/canceled）、`reasoning`、`content`、`sources`、`steps`、`citations`、`error` |
| POST | `/v1/jobs/{job_id}/cancel` | 取消任务（同时断开上游连接） |
| GET | `/healthz` | 健康检查（含 `capabilities`） |

### 会话存储（分页）

会话与消息存在服务端的 SQLite（容器内 `/srv/data/relay.db`，挂载到宿主机
`~/ds-relay/data`），客户端按页拉取，避免一次性传输大量内容：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/v1/conversations?limit=30&before_updated_at=&before_id=` | 会话列表分页，游标 `(updated_at, id)`，返回 `has_more`；每项含 `system_prompt` |
| POST | `/v1/conversations` | 新建会话 `{title, model, system_prompt?}` → `{id}` |
| PATCH | `/v1/conversations/{id}` | 改标题 `{title}` 和/或系统提示词 `{system_prompt}`（至少一项；空串表示恢复默认） |
| DELETE | `/v1/conversations/{id}` | 删除会话及其消息 |
| GET | `/v1/conversations/{id}/messages?limit=30&before_id=` | 取最近 N 条；`before_id` 继续往前翻，返回 `has_more`、`oldest_id` |
| POST | `/v1/conversations/{id}/messages` | 追加一条消息 → `{id}` |
| POST | `/v1/conversations/{id}/messages/bulk` | 批量追加（旧数据迁移用） |
| POST | `/v1/conversations/{id}/truncate` | 截断消息：优先 `before_id`（删除 id ≥ before_id）；旧客户端仍可用 `keep`（只保留前 N 条） |
| GET | `/v1/conversations/{id}/active_job` | 该会话正在生成的任务（客户端重连后重新接上流） |
| GET | `/v1/search?q=&limit=` | 消息全文检索，返回命中位置 |
| POST | `/v1/tools/search` | 代理官方 Search API，Body 同官方：`{query, count?, ori_question?, localization?, need_content?}` |
| POST | `/v1/tools/fetch` | 代理官方 Fetch API，Body：`{url}` |

### 全家桶（2026-11）：Files / OCR / ASR / TTS

对应 [../docs/family-api-contract.md](../docs/family-api-contract.md)。这几个接口除了中转口令
`x-relay-token`，同样要带 DeepSeek API Key（`Authorization: Bearer ...` 或 `x-api-key`）。

| 方法 | 路径 | 上行 | 下行 |
| --- | --- | --- | --- |
| POST | `/v1/files` | `multipart/form-data`，**`purpose` 必须排在 `file` 之前** | 上游 JSON（`{id, object, bytes, filename, purpose}`） |
| GET | `/v1/files` | — | 上游文件列表 |
| POST | `/v1/tools/ocr` | `multipart/form-data`：`file` + `purpose` | OCR JSON（`pages[].text`） |
| POST | `/v1/tools/asr` | `multipart/form-data`：`file` | `{request_id, text, duration_ms}` |
| POST | `/v1/tools/tts` | JSON `{text, voice_id, format, filter_markdown}`（`format` 只接受 `wav`） | **二进制音频**（`audio/wav`），透传 `X-Billed-Chars` |

实现要点（客户端要注意的地方）：

- **multipart 原样转发**：中转不解析、不重新编码请求体，`Content-Type` 连 boundary
  一起透传，所以客户端自己拼的字段顺序（`purpose` 在前、`file` 在后）会原样到上游；
- **TTS 二进制透传**：响应体按 bytes 写回，不做 UTF-8 解码，音频不会被破坏；
- `/v1/files` 上传成功时，中转会把文件字节**缓存进内存**（键为上游返回的 `id`），
  供服务端执行的 `ocr` 函数工具取用；缓存按「总字节 + 条目数」双上限 LRU 淘汰
  （`FILE_CACHE_BYTES` / `FILE_CACHE_FILES`），进程重启后清空；
- 需要 beta 头时客户端带 `anthropic-beta`，中转会一并透传给上游；
- 上游状态码与响应体原样返回，客户端按官方文档处理 400/401/402/403/404/429/5xx。

### 联网搜索 / 阅读链接由上游执行

2026-11 之后，联网搜索**不再由中转跑工具循环**：客户端在对话请求的 `tools` 里声明
`{"type":"deepseek_web_search","name":"deepseek_web_search"}`（Responses 只要 `type`），
上游服务端自己搜，结果以 `server_tool_use` + `web_search_tool_result` 事件流回；
阅读链接同理（`deepseek_read_url` → `web_fetch_tool_result`，带 `signature`）。

- 中转只负责把这些事件累加进快照：`steps`（工具步骤）与 `sources`（来源）；
- `sources` 在旧的 `title`/`url` 之外补 `site_name`、`snippet`、`page_age`
  （有值才带，旧字段一个不少）；
- `steps[]` 形如 `{kind, action, status, query|url, ...}`，
  `kind` 取值 `search` / `deep_search` / `read_link` / `image_search` / `deep_image_search`；
- **中转不往 payload 里塞任何工具**，工具声明完全由客户端决定（官方限制
  `deepseek_web_search` / `deepseek_read_url` 不能与其他服务端工具混用，
  `tool_choice` 也不能指定它们）；
- `ocr` 仍是**中转执行的函数工具**：模型调用时，中转按 `file_id` 从缓存取字节、
  调上游 `/v1/tools/ocr`，把逐页文本拼成字符串回填给模型后继续下一轮。

`system_prompt` 按会话各存一份，只作为客户端查看/编辑用的会话元数据；真正发给上游时
仍由客户端放进请求体顶层 `system`（Anthropic）或 `instructions`（Responses），
服务端只透传 payload。

`/v1/tools/*` 是 DeepSeek 在 2026-10-17 开放的 Search / Fetch API 的透传：
调用方除了中转口令 `x-relay-token`，还要带 DeepSeek API Key（`Authorization: Bearer ...`，
也兼容 `x-api-key`）。中转只做校验与转发，Key 不落盘、不记录；上游的状态码与 JSON
响应原样返回，客户端可直接按官方文档处理 400/401/402/403/404/429/5xx。

`POST /v1/chat` 可带 `conversation_id`：生成过程中服务端会按
`JOB_CHECKPOINT_INTERVAL` 定期把已输出的内容（**包括还没出正文时的思考内容**）
checkpoint 到会话存储，任务结束时再更新为最终内容（正文 + 思考 + 来源 + 思考用时）。
客户端被杀掉、服务重启时至少保留 checkpoint 过的部分，不会整段丢回答。

带 `conversation_id` 的请求，服务端会为这一轮回答维护**一条 pending 助手消息**
（多轮工具调用也复用同一条）：

- 联网搜索 / 阅读链接由**上游服务端执行**，中转不再自己调 `/v1/tools/search`；
- 每一轮（包括中转执行 `ocr` 这类函数工具的中间轮）都实时更新这条消息，
  客户端断开/切网/被杀掉都不丢；
- 下一轮复用同一条消息，不会把一轮回答拆成好几条；
- 中转执行函数工具（`ocr`）的轮次**不设上限**，直到模型不再调用工具、客户端停止或上游报错；
- 只有最终回答（没有工具调用）、客户端手动停止或上游报错，才把这条消息标记为收尾；
- 因此除非客户端显式点“停止”，服务端都会继续生成并把当前进度落库。

SSE 流的第一个事件是任务号，之后是上游事件的**原样透传**：

```
data: {"type":"__job","job_id":"...","protocol":"anthropic"}

data: {"type":"content_block_delta", ...}
```

可选请求头 `x-upstream-base`：临时指定上游地址（默认取环境变量 `UPSTREAM_BASE`）。

## 部署（Docker）

服务器上执行（已内置 `~/ds-relay/deploy/deploy.sh`）：

```bash
bash ~/ds-relay/deploy/deploy.sh
```

脚本会 build 镜像并把容器跑起来，对外映射 **80**（云安全组默认放行）与 51888（备用）。

常用运维命令：

```bash
docker ps --filter name=ds-relay          # 状态
docker logs -f ds-relay                   # 日志
docker restart ds-relay                   # 重启
docker rm -f ds-relay                     # 停止并删除
```

### 旧数据迁移：`<system>` → 会话提示词

新版本把系统提示词存进 `conversations.system_prompt`，历史消息里不再保留
`<system>...</system>` 标签。升级镜像后，先停服务再运行一次迁移（幂等，可重复执行）：

```bash
docker stop ds-relay
docker run --rm -v ~/ds-relay/data:/srv/data ds-relay:latest \
  python -m app.migrate --db /srv/data/relay.db --dry-run   # 先看统计
docker run --rm -v ~/ds-relay/data:/srv/data ds-relay:latest \
  python -m app.migrate --db /srv/data/relay.db            # 执行（自动备份）
docker start ds-relay
```

脚本只输出会话/消息条数，**不会打印任何对话内容**；规则与 App 一致：只识别用户消息
开头且闭合的 `<system>` 块，同一会话以最后一条为准，中间出现的标签按普通文本保留。

### 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `UPSTREAM_BASE` | `https://api.deepseek.com` | 上游地址 |
| `RELAY_TOKEN_HASH` | 无（必填） | 访问口令的 SHA-256（64 位十六进制）。缺失时服务拒绝启动 |
| `RELAY_TOKEN` | 无 | 口令明文，启动时就地哈希；仅在没给 `RELAY_TOKEN_HASH` 时生效 |
| `RELAY_HOST` | `0.0.0.0` | 监听地址 |
| `RELAY_PORT` | `51888` | 容器内监听端口 |
| `UPSTREAM_TIMEOUT` | `900` | 单次上游请求超时（秒） |
| `JOB_TTL_SECONDS` | `1800` | 任务结束后的内存保留时长（秒） |
| `JOB_CHECKPOINT_INTERVAL` | `2` | 流式回答写入数据库的间隔（秒） |
| `MAX_JOBS` | `50` | 内存中最多保留的任务数 |
| `START_TIMEOUT` | `60` | 等上游返回状态码的超时（秒） |
| `TOOLS_TIMEOUT` | `60` | 搜索/抓取、Files/OCR/ASR/TTS 的单次上游超时（秒） |
| `MAX_BODY_BYTES` | `134217728`（128 MiB） | 请求体上限（字节），multipart 上传也受它约束 |
| `FILE_CACHE_BYTES` | `268435456`（256 MiB） | 上传文件缓存的总字节上限（LRU 淘汰） |
| `FILE_CACHE_FILES` | `64` | 上传文件缓存的条目数上限 |

### 端口与 HTTPS

默认对外端口是 **51888，走 HTTPS**（需在云安全组放行该端口；80/443 不再使用）。

因为只有 IP、没有域名，证书用**自签名**、客户端按**指纹固定**校验：

- 部署脚本首次运行会生成 `~/ds-relay/tls/relay.crt`（EC P-256，SAN 含
  `IP:<公网IP>`、`IP:127.0.0.1`、`DNS:localhost`，有效期 10 年），私钥权限 600；
- 部署时打印证书的 **SHA-256 指纹**，填到 App 的「服务器证书指纹」；
- App 只在「系统 CA 校验通过」或「指纹与所填一致」时接受连接，
  其他自签名证书一律拒绝（等价于证书固定）；
- 以后换成正式 CA 证书时，把指纹留空即可，无需改代码。

重新生成证书（指纹会变，App 里要重新填）：

```bash
rm -f ~/ds-relay/tls/relay.crt ~/ds-relay/tls/relay.key
bash ~/ds-relay/deploy/deploy.sh    # 会打印新的指纹
```

> 想直接用系统信任链（浏览器/curl 不再告警）时，需要域名 + Let's Encrypt：
> 放行 443、把域名解析到本机，用 Caddy 自动签发即可，App 侧只需把地址改成
> `https://域名` 并清空证书指纹。

### 访问口令（必填，服务端只存哈希）

访问口令是**必填项**：服务默认监听 `0.0.0.0`，没有口令就等于把转发额度和
`relay.db` 里的全部会话交给公网。因此启动时会检查口令哈希：

- 没配 `RELAY_TOKEN_HASH` / `RELAY_TOKEN` → `build_server` 抛 `ConfigError`，
  进程以退出码 1 结束（`docker ps` 能看到容器没起来），**不会**退化成"无口令放行"；
- 哈希不是 64 位十六进制 → 同样拒绝启动；
- 即使绕过启动检查直接建服务器，`/v1` 也会返回 503 而不是放行（`/healthz` 仍免口令）。

首次部署会自动生成一个随机口令，**服务器上只保存它的 SHA-256**：

- 哈希文件：`~/ds-relay/.relay_token_hash`（权限 600），容器里只有
  `RELAY_TOKEN_HASH` 环境变量；
- 明文只在部署时打印一次，填进 App 的「API 配置 → 服务器口令」；
- 校验方式：客户端把口令放在 `x-relay-token` 头里，服务端现算 SHA-256 再比对
  （常量时间比较），所以拿到服务器文件也**推不出可用于认证的口令**；
- `/healthz` 不需要口令（供容器健康检查与探活）。

轮换口令（旧口令立即失效，App 里要重新填）：

```bash
rm -f ~/ds-relay/.relay_token_hash
bash ~/ds-relay/deploy/deploy.sh     # 会打印新的口令，只显示一次
```

也可以自己定口令（本地算哈希后再部署，明文不落到服务器）：

```bash
printf '%s' '你的口令' | sha256sum | cut -d' ' -f1 > ~/ds-relay/.relay_token_hash
bash ~/ds-relay/deploy/deploy.sh
```

> 注意：目前是 HTTP（80 端口）明文传输，口令能防止他人直接读写你的历史；
> 若担心链路被监听，可以给它配域名 + HTTPS（需要的话我再加）。

## 本地开发与测试

纯标准库实现（Python 3.12+），运行不需要第三方依赖：

```bash
cd server
python -m app.main                 # 本机起服务（需先设口令，否则拒绝启动）
python -m pytest -q --cov=app      # 单测（覆盖率 >= 80%）
python tools/mock_upstream.py 18080 # 假上游，用于不带 Key 联调
```

本机开发也要带口令（缺了会直接报「未配置访问口令」并退出）：

```bash
export RELAY_TOKEN=dev-token      # 明文，启动时就地哈希
# 或：export RELAY_TOKEN_HASH=$(printf '%s' dev-token | sha256sum | cut -d' ' -f1)
python -m app.main
```

容器内冒烟（假上游 + 中转 + 快照补齐）：

```bash
curl -sS -X POST http://127.0.0.1/v1/chat \
  -H 'content-type: application/json' \
  -H 'x-api-key: sk-mock' \
  -H 'x-upstream-base: http://172.17.0.1:18080' \
  -d '{"protocol":"anthropic","payload":{"model":"m","stream":true,"messages":[]}}'
```
