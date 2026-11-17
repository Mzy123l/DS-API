# DS-API

安卓端 DeepSeek 客户端 + 自建中转服务。

客户端是 Flutter 写的安卓 App，界面与交互对齐 DeepSeek 官方；中转服务是一个
Python 写的轻量 HTTP 服务，把「生成」这件事放到服务器侧执行——App 退到后台、
切换网络、甚至断线重连都不会中断回答。

| 目录 | 说明 |
| --- | --- |
| `flutter_app/` | Flutter 安卓客户端（构建见 [flutter_app/BUILD.md](flutter_app/BUILD.md)） |
| `server/` | 中转服务 ds-relay（接口说明见 [server/README.md](server/README.md)） |
| `docs/` | 接口契约与架构评审记录 |

## 它解决什么问题

直接把 API Key 放在手机里直连官方 API 有三个麻烦：退到后台容易被系统掐断、
长回答生成到一半切网就白等、历史记录只存在本机。DS-API 把生成任务交给中转服务，
客户端只负责收发事件，于是：

- **退后台不断流**：任务在服务器上跑，App 回来按任务快照补齐，不用重新生成；
- **断线可恢复**：长回答生成过程中每 2 秒 checkpoint 一次，服务重启也只丢内存里
  那一小段；
- **历史存服务端**：会话和消息存在服务器的 SQLite 里，换设备登录同一台服务器
  就能看到历史；
- **API Key 不落盘**：Key 由客户端随请求头透传给上游，中转只做校验与转发。

## 功能

**客户端**

- 快速 / 专家双模式：`deepseek-flash`（内置识图与全家桶联网能力）、`deepseek-v4-pro`
- 深度思考开关、推理强度（low / high / max）
- 智能搜索：联网搜索 + 阅读链接由上游服务端工具 `deepseek_web_search` /
  `deepseek_read_url` 执行，客户端只解析来源
- 识图（JPEG/PNG/GIF/WebP，按文件内容嗅探而非扩展名）、文档输入（PDF/Word/PPT）
- 语音：按住说话转文字（ASR）、朗读回答（TTS，音色 `stella`）
- 文件与图片附件、消息重新编辑、重新生成、停止输出
- 会话历史分页、全文检索、系统提示词按会话存储
- 后台流式保活（前台服务 + 通知），防止系统回收进程导致输出中断

**服务端**

- `/v1/chat` 任务化流式转发，任务可查询、可取消、断线可续
- 会话/消息持久化（SQLite）、分页拉取、全文检索
- 全家桶接口代理：Files / OCR / ASR / TTS
- 每连接独立 TLS 握手 + 读写超时 + 进程内看门狗（防单条连接卡死整个服务）
- 访问口令只存 SHA-256，明文不落服务器

接口清单见 [server/README.md](server/README.md)，全家桶契约见
[docs/family-api-contract.md](docs/family-api-contract.md)。

## 快速开始

### 1. 起中转服务

```bash
cd server
python -m pip install -e .        # 或直接用镜像，见 server/README.md
python -m app.main                # 默认监听 0.0.0.0:51888
```

首次部署想带上自签名证书和访问口令，用 `deploy/deploy.sh`（需在 Linux 服务器上）：

```bash
PUBLIC_IP=<你的公网IP> bash server/deploy/deploy.sh
```

脚本会生成口令哈希与自签名证书、构建镜像并启动容器；**首次运行会把明文口令
打印一次**，把它填进 App 的「服务器口令」里。

### 2. 装客户端

构建方式见 [flutter_app/BUILD.md](flutter_app/BUILD.md)。装好后在
「API 配置」里填三项：

| 配置项 | 说明 |
| --- | --- |
| 服务器地址 | 你的中转服务地址，如 `https://<你的服务器地址>:51888` |
| 服务器口令 | 服务端设了 `RELAY_TOKEN_HASH` 时必填 |
| 服务器证书指纹 | 自签名证书时填 SHA-256（去掉冒号、小写）；正式 CA 证书留空 |

源码里**不写死任何服务器地址、口令或证书指纹**。你也可以在打包时用
`--dart-define` 预置默认值：

```powershell
flutter build apk --release --split-per-abi `
  --dart-define=DS_SERVER_BASE_URL=https://<你的服务器地址>:51888 `
  --dart-define=DS_SERVER_TOKEN=<口令> `
  --dart-define=DS_SERVER_CERT_SHA256=<指纹>
```

三项都可省略；地址留空时 App 自动回退到直连官方 API。

## 服务器运维

下面这些命令里的 `<ssh 用户>`、`<服务器地址>` 换成你自己的。

### 日常命令

```bash
# 状态 / 资源
docker ps -a --filter name=ds-relay
docker stats --no-stream ds-relay
docker top ds-relay

# 日志（healthz 已静默，不会刷屏）
docker logs --tail 200 ds-relay
docker logs --since 1h ds-relay | grep -v healthz

# 探活（自签证书用 --cacert 指定）
curl -sS --cacert ~/ds-relay/tls/relay.crt https://localhost:51888/healthz
curl -sS --cacert ~/ds-relay/tls/relay.crt https://localhost:51888/healthz | python3 -m json.tool

# 容器内进程/线程：正常是 2 个线程（主线程 + 看门狗）
docker exec ds-relay ls /proc/1/task | wc -l

# 直接查库（只读）
docker exec ds-relay python -c "
import sqlite3
db = sqlite3.connect('/srv/data/relay.db')
print('会话', db.execute('select count(*) from conversations').fetchone()[0])
print('消息', db.execute('select count(*) from messages').fetchone()[0])
print(db.execute('select id,title,updated_at from conversations order by id desc limit 5').fetchall())
"
```

### 部署 / 升级

`deploy/deploy.sh` 做四件事：确保口令哈希与自签名证书存在 → `docker build`
→ `docker rm -f` 旧容器 → 用固定挂载重新 `docker run`。

```bash
# 1) 从本地同步代码（本地仓库根目录执行）
scp -r server/app server/deploy server/Dockerfile server/pyproject.toml \
  <ssh 用户>@<服务器地址>:~/ds-relay/

# 2) 服务器上重新构建并启动（会打印证书指纹，便于和 App 里核对）
ssh <ssh 用户>@<服务器地址> "bash ~/ds-relay/deploy/deploy.sh"
```

注意事项：

- `data/`、`tls/`、`.relay_token_hash` **不要覆盖**：证书指纹与口令不变，App 不用重新配置；
- `docker rm -f` 会丢掉旧容器的日志，需要留证据时先 `docker logs ds-relay > /tmp/relay-$(date +%F).log`；
- 升级前后各 `curl` 一次 `/healthz`，确认版本与状态。

从 1.3.0 起系统提示词按会话存储，旧消息里的 `<system>...</system>` 需要在升级后迁移一次
（先停服务；脚本只输出条数，不打印对话内容）：

```bash
docker stop ds-relay
docker run --rm -v ~/ds-relay/data:/srv/data ds-relay:latest \
  python -m app.migrate --db /srv/data/relay.db --dry-run   # 先预演
docker run --rm -v ~/ds-relay/data:/srv/data ds-relay:latest \
  python -m app.migrate --db /srv/data/relay.db            # 正式执行，自动备份
docker start ds-relay
```

回滚：

```bash
# 升级前先留一份代码快照
tar czf ~/ds-relay-backup-$(date +%F-%H%M).tgz -C ~ ds-relay --exclude=data
# 需要回滚时
tar xzf ~/ds-relay-backup-<时间>.tgz -C ~
bash ~/ds-relay/deploy/deploy.sh
```

### 自愈与超时

| 机制 | 说明 |
| --- | --- |
| 每连接 TLS 握手 | 监听 socket 保持明文，握手在每条连接自己的线程里做，**不会卡住 accept 循环** |
| 握手超时 10s | 连上但不完成握手的客户端，10 秒后直接丢弃这条连接 |
| 读写超时 30s | 半开连接（发一半请求就不说话）最多占住一个线程 30 秒 |
| 进程内看门狗 | 每 30s 用 `/healthz` 自检，连续 3 次失败就退出进程，Docker 立刻重启容器 |
| 健康检查静默 | `/healthz` 不写访问日志，日志里只看得到真实请求 |

### 任务打点（排查「回复变慢」）

每个生成任务结束时输出一行，字段就是排查顺序：

```
job c839c616 conv=88 status=done upstream=200 bytes=3412345 ttfb=0.9s first_delta=1.4s reasoning=154.8s total=180.2s
```

| 字段 | 含义 | 偏大说明 |
| --- | --- | --- |
| `bytes` | 客户端送上来的请求体大小（图片按 base64 算） | 几 MB = 图片在每轮重传，上行就慢 |
| `ttfb` | 中转→上游拿到响应状态码的耗时 | 上游排队或网络慢 |
| `first_delta` | 上游第一个流式事件到达的时间 | 上游首字延迟 |
| `reasoning` | 模型「思考」时长（客户端这段时间显示「正在思考」） | 上下文长/图片多时可达 1-2 分钟，可在 App 里关深度思考或降低推理强度 |
| `total` | 整轮耗时 | — |

```bash
docker logs --since 30m ds-relay | grep '^job '        # 只看任务打点
```

对应环境变量（不设就用默认值；要改就在 `deploy.sh` 的 `docker run` 里加 `-e`）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RELAY_HOST` | `0.0.0.0` | 监听地址 |
| `RELAY_PORT` | `51888` | 监听端口 |
| `UPSTREAM_BASE` | `https://api.deepseek.com` | 上游地址 |
| `RELAY_DB` | `/srv/data/relay.db` | SQLite 路径 |
| `RELAY_TOKEN_HASH` | 无（**必填**） | 访问口令的 SHA-256（64 位十六进制）。缺失时服务拒绝启动 |
| `RELAY_TOKEN` | 无 | 口令明文，启动时就地哈希；仅在没给 `RELAY_TOKEN_HASH` 时生效 |
| `TLS_CERT` / `TLS_KEY` | 空 | 都配置时以 HTTPS 提供服务 |
| `TLS_HANDSHAKE_TIMEOUT` | 10 | TLS 握手超时（秒） |
| `REQUEST_TIMEOUT` | 30 | 单连接请求读写超时（秒） |
| `WATCHDOG_INTERVAL` | 30 | 看门狗自检间隔（秒） |
| `WATCHDOG_FAILURES` | 3 | 连续失败几次就退出进程 |
| `UPSTREAM_TIMEOUT` | 900 | 单次上游请求超时（秒） |
| `START_TIMEOUT` | 60 | 等待上游返回状态码的超时（秒） |
| `TOOLS_TIMEOUT` | 60 | `/v1/tools/*` 的上游超时（秒） |
| `JOB_TTL_SECONDS` | 1800 | 任务结束后内存保留时长（秒） |
| `JOB_CHECKPOINT_INTERVAL` | 2 | 流式回答 checkpoint 到数据库的间隔（秒） |
| `MAX_JOBS` | 50 | 内存里最多保留的任务数 |
| `MAX_BODY_BYTES` | 128 MiB | 请求体上限 |
| `FILE_CACHE_BYTES` / `FILE_CACHE_FILES` | 256 MiB / 64 | `/v1/files` 上传缓存（供 ocr 工具用，LRU 淘汰） |

### 备份与恢复

`relay.db` 是历史记录的唯一副本，建议定期备份：

```bash
mkdir -p ~/backup
docker exec ds-relay python -c "
import sqlite3
src = sqlite3.connect('/srv/data/relay.db')
dst = sqlite3.connect('/srv/data/backup-tmp.db')
src.backup(dst); dst.close(); src.close()
"
mv ~/ds-relay/data/backup-tmp.db ~/backup/relay-$(date +%F).db
```

恢复：

```bash
docker stop ds-relay
cp ~/backup/relay-<日期>.db ~/ds-relay/data/relay.db
docker start ds-relay        # 或 docker run ...（见 deploy.sh）
```

> 删掉的会话不会自动回收空间（SQLite 只把页标为空闲）。需要回收时：
> `docker exec ds-relay python -c "import sqlite3; sqlite3.connect('/srv/data/relay.db').execute('VACUUM')"`

## 故障手册

### App 发消息没反应 / 一直转圈

1. `docker ps --filter name=ds-relay`：`Up (unhealthy)` 基本就是服务端卡住了；
2. `curl --cacert ~/ds-relay/tls/relay.crt https://localhost:51888/healthz`：
   超时/空响应 = 卡死；
3. 处理：`docker restart ds-relay`，再探活一次；
4. 想留证据再重启：先 `docker logs ds-relay > /tmp/relay.log`，并抓一次线程栈：

```bash
# 只读 attach，不影响线上进程；会临时起一个调试容器（用完自动删）
docker run --rm --pid=container:ds-relay --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined --entrypoint sh ds-relay:latest -c \
  'pip install -q py-spy -i https://pypi.tuna.tsinghua.edu.cn/simple >/dev/null 2>&1; py-spy dump --pid 1'
```

### 历史案例：TLS 握手卡死整个服务

- 现象：容器 `Up (unhealthy)`，端口在 LISTEN 但所有请求（含健康检查）超时，
  进程只有一个线程，日志停在最后一次成功请求。
- 定位：调试容器里 `py-spy dump --pid 1` 显示主线程停在
  `do_handshake → wrap_socket → accept → get_request → serve_forever`。
- 根因：旧实现把监听 socket 直接 `wrap_socket(server_side=True)`，
  TLS 握手是在 accept 循环所在线程里同步完成的，一条「连上不发 ClientHello」的
  外部连接就把 accept 永久挂住。
- 修复：握手改到每连接线程（带 10s 超时）+ 读写 30s 超时 + 进程内看门狗；
  见 `app/main.py` 的 `RelayServer` / `RelayHandler.setup` / `HealthWatchdog`。

### App 报「服务器口令不正确」（401）

- 服务端只存哈希：`~/ds-relay/.relay_token_hash`；
- 口令不匹配（换过口令、或 App 里填错）时：

```bash
# 轮换口令：删掉哈希文件后重新部署，会把新口令打印一次（只显示一次）
rm -f ~/ds-relay/.relay_token_hash
bash ~/ds-relay/deploy/deploy.sh          # 记下打印出来的口令
# 也可以自定义口令（明文不落服务器）
printf '%s' '新口令' | sha256sum | cut -d' ' -f1 > ~/ds-relay/.relay_token_hash
bash ~/ds-relay/deploy/deploy.sh
```

改完把口令填进 App 的「API 配置 → 服务器口令」。

### App 报证书/连接错误

```bash
openssl x509 -in ~/ds-relay/tls/relay.crt -noout -fingerprint -sha256
```

把打印的指纹（去掉冒号、小写）和 App 里的「服务器证书指纹」核对；不一致就删掉
`~/ds-relay/tls/relay.crt|key` 重新部署（指纹会变，App 必须重填）。

### 上游相关错误

App 里看到的 `401 / 402 / 429` 来自 DeepSeek 上游，服务端只做透传：
API Key 由客户端携带，检查 App 里填的 Key、余额或限流，服务端不需要改。

### 磁盘 / 内存

```bash
df -h /                    # 宿主机磁盘
du -sh ~/ds-relay/data     # 库大小
free -m
docker stats --no-stream ds-relay
```

### 服务端历史为空

`/healthz` 里的 `store.conversations` 是会话数。若是 0 而 App 里曾有很多对话：

```bash
docker logs ds-relay | grep -c 'DELETE /v1/conversations'   # 删除是 App 发起的
```

服务端**不会自动清理**会话，计数归零只会是 App 端删除操作（或恢复了旧备份）。

## 安全与端口

- 云安全组需放行你的服务端口（默认 **51888/TCP**）；
- **访问口令是硬性要求**：没配 `RELAY_TOKEN_HASH` 服务直接启动失败（退出码 1），
  不会出现「漏设口令 = 公网全开」；`deploy.sh` 在哈希文件为空/损坏时也会先停下；
- 口令只以 SHA-256 形式存在于服务器（600 权限），传输走 HTTPS（自签名 + 指纹固定）；
- 想换成正式证书（浏览器/curl 不再告警）：解析一个域名到本机、放行 443，
  用 Caddy/Nginx 做 TLS 卸载并反代到 `127.0.0.1:51888`，App 侧把地址改成
  `https://域名` 并清空证书指纹即可，服务端代码不用动；
- 仓库里**不含**任何服务器地址、口令、证书指纹或签名密钥——这些都在
  `.env.local`、`keystore/`、`android/keystore.properties`，已被 `.gitignore` 忽略。

## 本地开发与联调

```bash
cd server
python -m pytest -q                    # 单测
export RELAY_TOKEN=dev-token           # 必填：缺了会直接拒绝启动
python -m app.main                     # 本机起服务（默认 0.0.0.0:51888）
python tools/mock_upstream.py 18080    # 假上游，用于不花额度的联调

# 用假上游跑一条完整的流式任务（容器内自测，端口 51999 是个临时实例）
docker run --rm -p 127.0.0.1:51999:51888 --entrypoint sh \
  -v ~/ds-relay/tls:/srv/tls:ro -e TLS_CERT=/srv/tls/relay.crt -e TLS_KEY=/srv/tls/relay.key \
  -e RELAY_TOKEN=dev-token \
  ds-relay:latest -c 'python -m app.main' &
curl -sS -X POST https://127.0.0.1:51999/v1/chat \
  -H 'content-type: application/json' -H 'x-api-key: sk-mock' \
  -H 'x-relay-token: dev-token' \
  -H 'x-upstream-base: http://172.17.0.1:18080' \
  -d '{"protocol":"anthropic","payload":{"model":"m","stream":true,"messages":[]}}'
```

客户端：

```bash
cd flutter_app
flutter analyze
flutter test
```

## 许可

[GNU General Public License v3.0](LICENSE) 或更新版本（GPL-3.0-or-later）。

本项目基于 DeepSeek 官方 API 构建，与深度求索公司无隶属关系。
