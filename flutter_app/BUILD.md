# DeepSeek App（Flutter 版）构建说明

## 环境

- Flutter 3.47.1（Dart 3.13.1）
- Android SDK（platform android-36 + build-tools 36.0.0）
- JDK：Android Studio 自带 JBR，或 `C:\Program Files\Android\openjdk\jdk-21.0.8`（JAVA_HOME）
- Android SDK 路径：`%LOCALAPPDATA%\Android\sdk`（ANDROID_HOME / ANDROID_SDK_ROOT）

首次需 `flutter pub get`。国内网络下 maven.google.com 不可达，项目已将 Gradle
仓库切换为阿里云镜像（见 `android/settings.gradle.kts`、`android/build.gradle.kts`）。

## 命令

> 服务器配置（地址 / 口令 / 证书指纹）已记录在 `flutter_app/.env.local`（**已被
> gitignore，不进仓库**）。出包直接用脚本，不用再手打一串 `--dart-define`：
>
> ```powershell
> powershell -File tool/build_release.ps1             # 只出包
> powershell -File tool/build_release.ps1 -Install    # 出包并 adb 覆盖安装（不启动 App）
> ```

```powershell
# 设置一次环境（路径按你本机实际安装位置改）
$env:FLUTTER_ROOT="C:\path\to\flutter"
$env:JAVA_HOME="C:\Program Files\Android\openjdk\jdk-21.0.8"
$env:ANDROID_HOME="$env:LOCALAPPDATA\Android\sdk"
$env:PATH="$env:FLUTTER_ROOT\bin;$env:PATH"

cd <仓库根目录>\flutter_app

# 静态检查 / 单测
flutter analyze
flutter test

# 模拟器（x86_64）debug
flutter build apk --debug --target-platform android-x64

# 签名 release（分 ABI）
flutter build apk --release --split-per-abi
# 产物：build/app/outputs/flutter-apk/app-arm64-v8a-release.apk（真机）
#       build/app/outputs/flutter-apk/app-x86_64-release.apk（模拟器）
```

## 签名

签名复用 DS-API 已有的 keystore：`..\keystore\deepseek.keystore`，别名 `deepseek`。
密码写在 `android/keystore.properties`（已被 `.gitignore` 忽略），
`android/app/build.gradle.kts` 通过 `rootProject.file(...)` 读取。

> 注意：keystore 密码敏感，勿提交到仓库；如更换，改 `keystore.properties` 即可。

## 启动图标

启动图标源文件是 `tool/assets/app_icon_source.ico`（512×512，原为仓库根目录的
`图标.ico`，已改成 ASCII 文件名并以 `git mv` 迁移，历史可追溯）。改图后重新生成
五档 mipmap：

```powershell
cd <仓库根目录>\flutter_app
dart run tool/set_launcher_icon.dart
```

> 该 `.ico` 只是构建期输入，**不进** `pubspec.yaml` 的 `assets`，App 运行时不加载。
> 另外两个 `tool/gen_icons.dart`、`tool/gen_launcher_icons.ps1` 走的是
> `assets/icon.png` / `assets/icon_official.png`，与它无关。

## 接入真实 API

App 内「API 配置」中可选择接口协议，**一次请求只走选中的那一个端点**：

- **Anthropic（默认）**：`{base}/anthropic/v1/messages`；base 自带路径时用 `{base}/messages`
  （本地转发如 `http://10.0.2.2:8989/v1` → `/v1/messages`）
  - 思考：`thinking.type = enabled/disabled` + `output_config.effort`（low/high/max）
  - 联网搜索：官方服务端工具 `{"type":"deepseek_web_search","name":"deepseek_web_search"}`
    + 阅读链接 `{"type":"deepseek_read_url"}`，**搜索与抓取都由上游服务端执行**，
    客户端不再自己跑 search/fetch 函数工具；来源从 `web_search_tool_result`
    或 `web_fetch_tool_result` 解析（标题 + 链接 + 站点名 + 摘要）
  - 识图：`image` 内容块（base64；只认 JPEG/PNG/GIF/WebP，按文件内容判断）
  - 文档：`document` 内容块 + `source.file.file_id`，请求头需带
    `anthropic-beta: files-api-2025-04-14`
  - 流式 SSE：`content_block_delta(thinking_delta/text_delta)`、
    `content_block_start(server_tool_use/web_search_tool_result/web_fetch_tool_result)`、`message_stop`
- **Responses**：`{base}/responses`（OpenAI 兼容）
  - 思考：`reasoning.effort`；识图：`input_image`；文档：`input_file` + `file_id`
  - 联网工具同样用 `deepseek_web_search` / `deepseek_read_url`（只写 `type`，不带 `name`）

- 模型：快速模式 `deepseek-flash`（V4.1-Flash，全家桶联网能力只支持它），
  专家模式 `deepseek-v4-pro`（旧名 `deepseek-v4-flash-vision-exp` 已下线，
  仍可调用但会被路由到 `deepseek-flash`）
- 识图限制（官方）：只支持 JPEG/PNG/GIF/WebP，**按文件实际内容判断**，单边 ≤
  8192px、单图 ≤ 32MiB、整包 ≤ 48MiB；`deepseek-v4-pro` 不支持图片输入。
  - 选图/文件一律按字节嗅探格式：扩展名是 `.jpg`、内容其实是 HEIC/AVIF 的图会
    在本地拦下并提示，不再原样发出去（上游只会回一句 `unsupported image`）；
  - 只在超出上面的限制时才缩放（8192px 长边；超大体积缩到 4096），正常图片
    字节原样发送，不重压、不改分辨率；
  - 发请求前还会再整理一遍历史里的图片，老会话里存进去的超尺寸图重发也不会 400；
  - 专家模式带图时自动用快速模型（`deepseek-flash`）发这一轮，并提示一次；
  - 专家模式开联网搜索时同样自动改走 `deepseek-flash`（全家桶工具只支持它）。

## 全家桶能力（2026-11 版）

对齐官方 [更新日志 2026-11-13](https://api-docs.deepseek.com/zh-cn/updates) 的
「全家桶应用 API」。内部契约见 [../docs/family-api-contract.md](../docs/family-api-contract.md)。

| 能力 | 客户端行为 | 走哪个接口 |
| --- | --- | --- |
| 联网搜索 | 输入区「智能搜索」开关 → 声明 `deepseek_web_search` | 上游服务端执行 |
| 阅读链接 | 同上，一并声明 `deepseek_read_url`（只读最后一条用户消息里的 URL） | 上游服务端执行 |
| 文件输入 | 选 PDF / Word / PPT → 上传拿 `file_id` → 以文档块引用 | `POST /v1/files` |
| OCR | 有已上传文档时声明 `ocr` 函数工具，模型自己决定读不读 | `POST /v1/tools/ocr` |
| ASR | 输入框麦克风**按住说话** → 录音 → 转文字填进输入框 | `POST /v1/tools/asr` |
| TTS | 右上角喇叭朗读最新回答；每条回答底部播放按钮 | `POST /v1/tools/tts` |

**联网搜索与 ocr 工具不混用**：官方限制 `deepseek_web_search` / `deepseek_read_url`
不能与其他服务端工具同时声明，所以开联网时客户端不声明 `ocr`。

### 语音（TTS）

- **音色固定为官方默认的「海星」**（`stella`）。官方 `voice_id` 目前只开放
  `stella` / `tide` 两种，本项目只用海星；`TtsVoice` 枚举按多值设计，
  后续官方开放新音色时在数据层加一项即可，界面无需改动。
- **朗读是点击时才生成**：只有点播放/下载才请求 TTS，不会预先生成。
- **只生成一次**：结果按「文字 + 音色 + 格式」的 SHA-256 落盘缓存，
  同一段文字再次播放直接读本地文件，不再消耗额度。设置页可清空缓存。
- 朗读前会剥掉 Markdown（代码块念「代码块已略过」），并按官方计费规则
  （汉字算 2 个字符）截断到 10000 以内。

### 音频文件（模型工具 `text_to_speech`）

与「朗读当前回答」是两件不同的事：

- **模型工具**：对话里要求「把这段念出来 / 生成一段语音」时，模型调用
  `text_to_speech` 工具，拿到一个音频文件；客户端把它落成独立文件
  （`speech-<时间戳>-<哈希>.wav`），并在回答下方展示**音频卡片**。
- **卡片**：点左侧圆形图标即播放/停止，没有额外按钮。同一段文字多次生成
  各自独立成文件，互不覆盖。
- 该工具与联网搜索**不混用**（官方限制服务端工具与其它工具同时声明）。

### 语音（ASR）

- 输入框麦克风**长按录音**，松手转写；录音中上滑取消。
- 录音格式固定为 16-bit PCM WAV / 16kHz / 单声道，正好满足官方要求
  （≤8MiB、≤120 秒），超限会在本地先拦下。
- 需要 `RECORD_AUDIO` 权限（Manifest 已声明，首次录音时系统弹窗）。

## 后台流式保活

生成回答期间通过 `flutter_foreground_task` 启动前台服务（dataSync 类型），
防止 Android 在应用退后台后回收进程 / 冻结网络导致输出中断。Manifest 已声明
`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`WAKE_LOCK`、`POST_NOTIFICATIONS`
权限与对应 Service。首次生成时 Android 13+ 会弹出通知授权。

本地调试可用 `tool/mock_deepseek.dart` 模拟流（不依赖真实 key）：

```powershell
dart run tool/mock_deepseek.dart 8081
flutter build apk --debug --target-platform android-x64 --dart-define=DEEPSEEK_BASE_URL=http://10.0.2.2:8081
```

## 中转服务器（推荐，彻底解决退后台中断）

App 内「API 配置」→ **生成任务交给服务器**：默认关闭，需要你先填自己的中转地址。

- 地址写在这里即可，**换服务器不用重新编译**；留空/关闭开关则回到直连官方 API
- 预置默认值可用
  `--dart-define=DS_SERVER_BASE_URL=http://<ip>:<port>`
- 服务端设了口令时，把口令填进「API 配置 → 服务器口令」；打包时可用
  `--dart-define=DS_SERVER_TOKEN=<口令>` 预置默认值（源码里不写死口令）
- 服务端用自签名证书时，把证书 SHA-256 指纹填进「API 配置 → 服务器证书指纹」；
  打包时用 `--dart-define=DS_SERVER_CERT_SHA256=<指纹>` 预置（正式 CA 证书留空）
- 服务端部署与接口说明见 [../server/README.md](../server/README.md)

## 会话历史（服务器存储 + 分页）

历史记录同样存在服务器（SQLite），客户端只按页拉取：

- 历史抽屉每页 30 条会话，滑到底部自动加载更早的；
- 打开会话先取最近 30 条消息，往上翻再继续拉，本地留一份缓存；
- 首次升级会把旧版本机 SQLite 里的历史一次性搬到服务器（失败下次启动重试）。

联调用例（需要服务器已部署，跑真实链路：客户端 → 中转 → 上游）：

```powershell
flutter test test/relay_smoke_test.dart --dart-define=RELAY_SMOKE_BASE=http://<你的服务器地址>
# 需要真实 key 的流式用例再带上：--dart-define=RELAY_SMOKE_KEY=sk-xxx
```
