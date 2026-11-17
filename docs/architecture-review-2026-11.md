# DS-API 架构评审（2026-11-14）

## 一句话结论

**架构方向是对的，不需要推倒重来；但前端有一个必须尽早拆的上帝对象，服务端有两个必须马上修的正确性缺陷。**

- 服务端 `server/`：分层清晰、职责单一、测试扎实（81% 覆盖、119 项全绿），是健康的部分。
- 前端 `flutter_app/`：单机版设计是对的，但演化成了 4 个大文件承载全部逻辑，新增功能成本已经很高。
- 最优先动作不是"重构"，是修 2 个线上级别的缺陷（TTS 去重失配、口令进日志）。

---

## 一、整体架构

```
Flutter App ──HTTPS(自签+指纹固定)──> ds-relay ──HTTPS──> api.deepseek.com
    │                                   │
    └── 本地 SQLite（离线缓存/设置）      └── SQLite relay.db（历史唯一副本）
```

核心设计是**"把生成挪到服务器"**：`POST /v1/chat` 立即返回 `job_id`，服务端自己的线程跑完整个流式生成（含工具轮次），客户端断线/退后台/被杀都不影响；重连后按 `GET /v1/jobs/{id}` 快照或 `active_job` 补齐。

这个设计是对的，解决的是真问题（安卓后台进程冻结导致长回答半死），并且实现得相当克制：

- **零第三方依赖**，纯标准库（`pyproject.toml:4` `dependencies = []`），Docker 镜像小、升级无供应链风险；
- **API Key 透传不落盘**（`main.py:86` `_PASSTHROUGH_HEADERS`），服务端只存口令的 SHA-256（`config.py:84`）；
- **协议适配集中在一处**：`sse.py` 用 `StreamAccumulator` 同时吃 anthropic / responses / chat 三套事件，新增字段不用改多处；
- **多轮工具循环在服务端收口**（`jobs.py:_run`），客户端只消费一条 SSE 流。

### 分层评价

| 层 | 状态 | 说明 |
| --- | --- | --- |
| 传输/代理 `tools.py` | 好 | 4 个薄函数复用同一个 `proxy_raw_request`，multipart 与音频全程 bytes 透传，边界处理正确 |
| 协议解析 `sse.py` | 好 | 单一累加器，事件映射表驱动（`_TOOL_NAME_KINDS`），是教科书式写法 |
| 任务编排 `jobs.py` | 可接受 | `Job` 状态机 + `JobManager` 线程模型清晰；但混入了 `_execute_ocr`/`_execute_tts` 两个具体工具实现（818 行里约 100 行） |
| 存储 `store.py` | 可接受 | 一把锁串行化 SQLite，对"个人低并发"是合理取舍；但 schema 升级靠 6 段 try/except ALTER，见下 |
| HTTP 入口 `main.py` | 偏胖 | 1200 行里 `RelayHandler` 同时干路由、鉴权、multipart、SSE 转发、TTS 转发、请求体解析 |

---

## 二、服务端：两个必修缺陷 + 三个技术债

### P0-1 TTS 去重键失配（真实 bug，会重复计费）

`ttsjobs.py` 写入和清理用的哈希键不一致：

```python
# 109 行：写入键 = voice | format | text
digest = sha256(f"{voice_id}|{audio_format}|{text}")

# 318 行：清理键 = voice | text（少了 format）
digest = sha256(f"{job.voice_id}|{job.text}")
```

后果：`_prune_locked()` 永远删不掉 `_by_text` 里过期的映射。任务记录被弹出后，同一个 digest 还在字典里，用户重复提交同一段文字时会命中 `existing_id`，拿到一个 `job is None` → 走到新建分支。而如果 TTL 内重复提交，行为又依赖 `finished_at` 被 `get()` 清空（`ttsjobs.py:147-150`，这个"访问即续期"会让任务永不回收）。`_by_text` 还会无界增长（只增不删）。

修法：抽一个 `_digest(voice, fmt, text)` 方法，两处共用（约 5 行改动）。

### P0-2 口令会进访问日志

```python
# main.py:969-980  支持 ?token= 鉴权（媒体播放器带不了自定义头）
# main.py:1093-1097 log_message 直接写 format % args
```

`BaseHTTPRequestHandler` 默认 log 格式是 `"%s" %s %s`，即 `requestline`，而 `requestline` 是 `self.command + " " + self.path`——`self.path` **含查询串**。所以 `GET /v1/tts-stream/xxx?token=<明文口令> HTTP/1.1` 会原样进 `docker logs`。这与 README 里"口令只以哈希形式存在服务器"的承诺直接冲突，是安全问题。

修法：`log_message` 里先把 `self.path` 的 query 去掉再记（3 行改动），并考虑对 `?token=` 这种鉴权方式加时效签名。

### 技术债 1：schema 迁移靠 try/except

`store.py:68-120` 六段 `ALTER TABLE ... except sqlite3.OperationalError: pass`，另外还有一个独立的 `migrate.py` 做数据迁移。没有版本号，没有单一迁移入口，靠"列已存在就抛错"来判断。再加字段就得复制第七段。建议：加 `PRAGMA user_version`，把迁移收敛成一个有序列表。

### 技术债 2：`main.py` 路由是 if 链

`do_GET`/`do_POST` 各一条 20+ 分支的 if 链，正则散在模块顶部。加一个接口要改 3 个地方（正则、`do_X` 分支、`_handle_*` 方法）。改成 `[(pattern, handler, methods)]` 路由表即可，收益中等、成本低。

### 技术债 3：测试盲区

实测 `python -m pytest -q --cov=app` → **119 passed, 81%**。覆盖率数字漂亮，但几个高风险路径恰好没测：

- `GET /v1/tts-stream/{id}` 流式转发（`main.py:843-877`）**整段未覆盖** —— 这是 TTS 主路径；
- `?token=` URL 鉴权分支（`main.py:977`）无测试 —— 正好是 P0-2 那条；
- `_execute_tts` 工具路径（`jobs.py:689-756`）零测试；
- SSE 心跳 `: ping`（`main.py:957`）、413 请求体上限（`main.py:1018-1038`）未覆盖。

这解释了为什么 P0-1 这种键失配能活下来——TTS 去重逻辑本身没有断言。

---

## 三、前端：架构需要重构，但不是重写

### 3.1 上帝对象：`AppState` 2242 行、45 处 `notifyListeners`

已实测确认：`main.dart:33` 用 `Consumer<AppState>` 包住**整个 `MaterialApp`**，所以任意一次 `notifyListeners`（包括弹一条 SnackBar）都会重建路由树。

`app_state.dart` 一个类同时负责 8 类关注点：持久化设置、网络客户端工厂、会话/消息分页、发送/编辑/重算编排、流式接收合并、后台恢复、TTS/ASR 全部入口、纯 UI 状态（`scrollToken`、`noticeText`、`editingIndex`、`_following`）。其中 `send` / `editUserMessage` / `_regenerateFromHead` 是三段 100+ 行的近似复制流程。

这是**当前最大的成本来源**：任何新功能（分支对话、离线草稿、多选）都得在这 2242 行里找插入点，而三份流程改一处必漏两处。

### 3.2 传输层混了业务层：`deepseek_client` 2205 行

同一个文件里既有"拼 payload + 降级重试 + 构造鉴权头"（重复了 4 份，见下表），又在跑 `_sendWithTools` 这种完整的工具多轮编排，还顺手把 `ChatMessage` 转成上游协议格式。

| 重复点 | 位置 |
| --- | --- |
| payload 构造 + `max_tokens` 降级 + 鉴权头 | `_roundDirect` / `_roundRelay` / `_sendRelay` / `_sendDirect` |
| SSE 逐行解析 | `_consumeSse` 与 `_sendDirect` 内联版（连注释都重复） |
| 协议事件解析 | `_handleAnthropicLine` 与 `_handleLine`，仅事件名不同 |

### 3.3 重构的代价评估

项目从 2026-08-23 到 11-14，91 次提交，`app_state.dart` 改了 30 次、`messages_view.dart` 26 次。也就是说：**这两个文件每周都在动**，但每次都是在同一团复杂度上继续加，边际成本是递增的。

好消息是测试兜底比预期强：`flutter analyze` → No issues found；`flutter test` → 102 项全过（2 项需真服务器的被 skip）。断线恢复、多会话并发、杀掉重开这些最难测的场景都有覆盖。**这意味着重构是安全的，有回归网。**

---

## 四、建议：分三档，别一次全做

### 第一档：本周做，1-2 小时，全是止血

1. 修 TTS 去重键失配（P0-1）
2. 修口令进日志（P0-2）
3. 补 3 个测试：`/v1/tts-stream`、`?token=` 鉴权、413 上限
4. 删掉 `图标.ico` / `图标.jpg` —— **更正一个误判**：这两个文件不是垃圾，`flutter_app/tool/set_launcher_icon.dart:18` 默认读 `../图标.ico` 来生成启动图标。所以**不能直接 `git rm`**，正确做法是移到 `flutter_app/assets/` 下 or 转成 LFS；`.git` 已经 15MB。

### 第二档：前端拆 `AppState`，收益最高，建议排期做

按关注点拆成 4 个对象，`AppState` 只留组合与 UI 状态（目标 < 400 行）：

| 新对象 | 迁出内容 |
| --- | --- |
| `SessionStore` | 会话/消息 CRUD、分页、`_viewTokens` 手写代次 |
| `TurnController` | 发送/编辑/重算（合并三份复制流程）+ 流式合并 + 后台恢复 |
| `TtsController` | 全部 TTS/ASR 入口 |
| `SettingsController` | 设置持久化 |

配套最小改动：`main.dart:33` 的 `Consumer` 收窄到真正需要重建的子树，别包住 `MaterialApp`。

**同类收益/成本比更高的两项，可以并行做**：

- **收敛消息编解码**：同一份消息 DTO 现在手工写了三遍（`chat_repository.dart`、`storage.dart`、`deepseek_client.dart` 各一套，服务端 `store.py` 还有一套）。抽一个 `ChatMessageDto` 只保留 `toWire/fromWire/toRow/fromRow`。
- **结构化附件标记**：`app_state.dart` 现在把附件拼成 `【文件：名｜大小】\n内容` 塞进正文，`messages_view.dart` 再用正则反解。这是把协议写进了用户可见文本——用户发一句含该样式的正常文字就会被误解析成文件卡，而且这个正则每条用户气泡每帧跑 3 次。改成独立字段。

### 第三档：可以不做，或等有痛点再做

- `main.py` 路由表化、`jobs.py` 拆出工具执行器、schema 版本化迁移 —— 都是"读起来更舒服"，当前没有正确性问题。
- 流式渲染性能（`RepaintBoundary`、按条 Listenable）—— 只有当用户反馈长会话卡顿时才值得动。
- 换框架（FastAPI/异步）——**不建议**。零依赖是当前部署方式（`scp` + `deploy.sh` + 单容器）的最大优势，换框架会连带改部署、镜像、自签证书链路，收益不匹配。

---

## 五、评分

| 维度 | 评分 | 依据 |
| --- | --- | --- |
| 架构方向 | 8/10 | 生成任务服务端化是对的，且实现克制 |
| 服务端代码质量 | 7/10 | 分层清晰；扣分在 `main.py` 偏胖与两个 P0 缺陷 |
| 服务端测试 | 7/10 | 81%、行为验证为主；扣分在 TTS 主路径与鉴权未覆盖 |
| 前端代码质量 | 4/10 | 4 个文件承载全部逻辑，DTO 三写，协议进正文 |
| 前端测试 | 7/10 | 断线恢复覆盖优秀；UI 层几乎裸奔 |
| 工程化 | 5/10 | 无 CI、无 lint（Python）、无版本 tag；Flutter 侧有 `flutter_lints` |

**总评：6.5/10 —— 方向对、服务端健康、前端该拆了。不做重构的代价现在还可以忍受，但 3 个月后就是障碍。**
