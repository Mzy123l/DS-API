# DS-API

基于 Flutter 的 DeepSeek 官方同款 UI 安卓客户端。

## 功能

- 官方鲸鱼图标与界面，历史抽屉按官方比例（约 77% 屏宽）展开
- 快速模式 / 专家模式；深度思考、智能搜索开关、推理强度（low/high/max）
- 智能搜索同时挂载官方 `web_search` 服务端工具与 `search` / `fetch` 函数工具：
  模型可自行搜索网页、抓取正文，来源按 URL 去重后展示
- DeepSeek Responses API 流式对话（`deepseek-v4-flash-vision-exp` / `deepseek-v4-pro`）
- 思维链默认展开、可点击折叠
- 支持图片 / 拍照 / 任意文件附件
- **生成任务交给服务器执行**（见 [server/README.md](../server/README.md)）：
  退到后台、切网、甚至进程被回收，回答都会在服务器上跑完，回到 App 自动补齐
- **会话历史存在服务器**并按页加载：历史抽屉每页 30 条、聊天页向上滑再拉更早的消息，
  本地只留缓存；旧版本机历史首次启动自动迁移
- 服务器地址可在「API 配置」里随时改，换服务器不需要重新编译
- HTTPS（自签名证书按 SHA-256 指纹固定校验，口令与内容全程加密）
- 打开历史会话默认停在最新消息；输出过程中向上翻看不会被强制拉回底部，
  右下角提供「回到底部」按钮（白底圆形 + 灰色阴影 + 深灰向下箭头）
- 本地存储（sqflite / shared_preferences）

## 构建

参见 [BUILD.md](BUILD.md)。签名使用 `keystore/deepseek.keystore`，密码见
`android/keystore.properties`（已 gitignore，勿提交）。
