import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// reasoning_effort 可选值（DeepSeek 思考强度：low / high / max）
const List<String> reasoningEfforts = ['low', 'high', 'max'];

/// reasoning_effort 默认值（与官方一致：high）
const String defaultReasoningEffort = 'high';

/// 中转服务器默认地址（仅作为首次运行的默认值）。
///
/// App 内「API 配置」可随时修改并持久化到本机；换服务器不需要重新编译，
/// 也可以在构建时用 `--dart-define=DS_SERVER_BASE_URL=...` 覆盖。
/// 源码里不写死任何服务器地址：留空表示未配置，需用户在 App 内填写。
const String defaultServerBaseUrl = String.fromEnvironment(
  'DS_SERVER_BASE_URL',
);

/// 服务器访问口令默认值（构建时用 `--dart-define=DS_SERVER_TOKEN=...` 注入）。
///
/// 源码里不写死口令；服务端 `RELAY_TOKEN` 非空时客户端必须带上同样的口令。
const String defaultServerToken = String.fromEnvironment('DS_SERVER_TOKEN');

/// 服务器证书 SHA-256 指纹（自签名证书用，构建时 `--dart-define=DS_SERVER_CERT_SHA256=...` 注入）。
///
/// 留空表示走系统信任链（正式 CA 证书场景）。
const String defaultServerCertSha256 = String.fromEnvironment(
  'DS_SERVER_CERT_SHA256',
);

/// 对话模式：快速 / 专家
///
/// - 快速模式：deepseek-flash（V4.1-Flash，内置识图与全家桶联网能力）
/// - 专家模式：deepseek-v4-pro
///
/// 官方自 2026-09-10 起把模型名统一为 `deepseek-flash`，旧名
/// `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 仍可调用但会被路由到它。
/// 全家桶的 `deepseek_web_search` / `deepseek_read_url` 只支持 `deepseek-flash`。
enum AppMode {
  quick(
    label: '快速模式',
    icon: 'bolt',
    subtitle: '适合日常对话，即时响应',
    model: 'deepseek-flash',
  ),
  expert(
    label: '专家模式',
    icon: 'diamond',
    subtitle: '适合深度推理，回答更严谨',
    model: 'deepseek-v4-pro',
  );

  const AppMode({
    required this.label,
    required this.icon,
    required this.subtitle,
    required this.model,
  });

  final String label;
  final String icon;
  final String subtitle;
  final String model;

  static AppMode fromIndex(int index) =>
      index == 0 ? AppMode.quick : AppMode.expert;
}

enum MessageRole { user, assistant }

/// 接口协议：决定请求打到哪个端点、用哪套请求体与流式格式。
///
/// - [responses]：OpenAI 兼容的 Responses API
/// - [anthropic]：Anthropic Messages API（联网搜索走服务端工具）
/// 两者能力都随模型/服务端演进，界面只做客观描述，不写死"支持/不支持"。
enum ApiProtocol {
  responses(label: 'Responses', subtitle: 'OpenAI 兼容接口 {base}/responses'),
  anthropic(label: 'Anthropic', subtitle: 'Messages 接口 {base}/messages');

  const ApiProtocol({required this.label, required this.subtitle});

  final String label;
  final String subtitle;

  /// 读取历史设置：非法或缺失时回退到 [ApiProtocol.anthropic]。
  static ApiProtocol fromIndex(int? index) {
    if (index == null || index < 0 || index >= values.length) {
      return ApiProtocol.anthropic;
    }
    return values[index];
  }
}

/// 支持识图的模型：官方文档里只有 Flash 系列支持图片输入，
/// `deepseek-v4-pro` 明确标注 Vision「Not supported」。
const String visionModel = 'deepseek-flash';

/// 全家桶能力（联网搜索 / 阅读链接 / 文件输入）要求的模型。
const String familyModel = 'deepseek-flash';

/// 默认朗读音色（官方默认 `stella`）。
const String defaultTtsVoiceId = 'stella';

/// 模型是否支持图片输入。
///
/// 未知/自定义模型按「支持」处理：避免因为认不出的名字把用户配置的模型
/// 悄悄换掉，只有官方明确不支持的模型才需要改路。
bool modelSupportsVision(String model) {
  final name = model.trim().toLowerCase();
  if (name.isEmpty) return true;
  // Anthropic 兼容端点会把 claude-opus* 映射到 deepseek-v4-pro
  if (name.startsWith('claude-opus')) return false;
  return name != 'deepseek-v4-pro';
}

/// 全家桶服务端工具（`deepseek_web_search` / `deepseek_read_url`）只在这些模型上可用。
///
/// 官方说明：请使用 `deepseek-flash`。旧名会被路由到同一模型，因此一并放行；
/// 其它模型（如 `deepseek-v4-pro`）声明这些工具会 400，需要降级。
bool modelSupportsFamilyTools(String model) {
  final name = model.trim().toLowerCase();
  if (name.isEmpty) return true;
  if (name == 'deepseek-v4-pro' || name.startsWith('claude-opus')) return false;
  return true;
}

/// 带图请求实际使用的模型：选中的模型不支持识图时，改用 [visionModel]。
///
/// 否则上游会直接 400（「unsupported image」），用户只能看到一句看不懂的错误。
String modelForRequest(String model, {required bool hasImages}) {
  if (!hasImages || modelSupportsVision(model)) return model;
  return visionModel;
}

/// Responses 形态的 input 里是否带图片（含历史消息里的图）。
bool inputHasImages(List<Map<String, dynamic>> input) {
  for (final item in input) {
    final content = item['content'];
    if (content is! List) continue;
    for (final part in content) {
      if (part is Map && part['type'] == 'input_image') return true;
    }
  }
  return false;
}

/// 联网搜索来源（`web_search_tool_result` 或客户端 search / fetch 工具的结果）。
@immutable
class ChatSource {
  const ChatSource({required this.title, required this.url});

  final String title;
  final String url;

  /// 展示用的站点名（解析失败时退回原始 url）。
  String get host {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    return host.isEmpty ? url : host;
  }
}

/// 单条对话消息（承载正文 / 思维链 / 图片）
@immutable
class ChatMessage {
  const ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.reasoning = '',
    this.reasoningMs = 0,
    this.imageDataUrls = const [],
    this.sources = const [],
    this.files = const [],
    this.audioFiles = const [],
    // 思考块默认收起：输出中显示限高小块（上下箭头），结束后只留标题行
    this.thinkingExpanded = false,
    this.timestamp,
  });

  /// 服务器侧消息 id（分页游标 / 本地缓存主键）；本地新建尚未落库时为 null
  final int? id;
  final MessageRole role;
  final String content;

  /// 思维链正文（reasoning_content），默认展开、点击折叠
  final String reasoning;
  final int reasoningMs;

  /// 视觉消息携带的图片 data URL 列表（仅 user，支持多图）
  final List<String> imageDataUrls;

  /// 第一张图片的 data URL（兼容单图场景的读取）
  String? get imageDataUrl =>
      imageDataUrls.isEmpty ? null : imageDataUrls.first;

  /// 联网搜索来源（仅助手消息；服务端搜索块或 read_url 结果带回）
  final List<ChatSource> sources;

  /// 已上传到 Files API 的文档（仅 user；重放历史时据此重建内容块）
  final List<ChatFile> files;

  /// 模型用 `text_to_speech` 生成的音频文件路径（仅 assistant；可多个）
  final List<String> audioFiles;
  final bool thinkingExpanded;
  final DateTime? timestamp;

  bool get hasImage => imageDataUrls.isNotEmpty;

  bool get hasSources => sources.isNotEmpty;

  bool get hasFiles => files.isNotEmpty;

  bool get hasAudio => audioFiles.isNotEmpty;

  DateTime get effectiveTime => timestamp ?? DateTime.now();

  ChatMessage copyWith({
    int? id,
    String? content,
    String? reasoning,
    int? reasoningMs,
    List<String>? imageDataUrls,
    List<ChatSource>? sources,
    List<ChatFile>? files,
    List<String>? audioFiles,
    bool? thinkingExpanded,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role,
      content: content ?? this.content,
      reasoning: reasoning ?? this.reasoning,
      reasoningMs: reasoningMs ?? this.reasoningMs,
      imageDataUrls: imageDataUrls ?? this.imageDataUrls,
      sources: sources ?? this.sources,
      files: files ?? this.files,
      audioFiles: audioFiles ?? this.audioFiles,
      thinkingExpanded: thinkingExpanded ?? this.thinkingExpanded,
      timestamp: timestamp,
    );
  }
}

/// 一条回答的朗读 / 播放标识（播放态判断的唯一来源）。
///
/// 只依赖**稳定**标识：优先服务端消息 id（分页前插、下标位移都不影响它）；
/// 流式中的新消息还没有 id，但那时它必然是列表最后一条，用「会话 + 下标」
/// 同样稳定。
///
/// 这里**不能**带 `content.length`：流式输出期间正文长度每帧都在变，key 一变
/// `playingKey == key` 立刻不成立，按钮会一直卡在「未播放」态（旧实现的问题）；
/// 下标也不能单独用：加载更早消息（前插）会让整体位移，播放态串到别的消息。
String speakKeyFor(int? conversationId, ChatMessage msg, {int? index}) {
  final conv = conversationId ?? 0;
  final id = msg.id;
  if (id != null) return '$conv:id:$id';
  return '$conv:index:${index ?? -1}';
}

/// 历史搜索命中的单条消息（消息级搜索结果）。
class MessageHit {
  const MessageHit({
    required this.conversationId,
    required this.conversationTitle,
    required this.role,
    required this.content,
    required this.timestamp,
    required this.matches,
  });

  final int conversationId;
  final String conversationTitle;
  final MessageRole role;
  final String content;
  final DateTime timestamp;

  /// 该消息内命中位置的字符下标（升序），用于片段定位与「1/2」计数
  final List<int> matches;

  int get matchCount => matches.length;
}

/// 会话（历史列表 / 本地存储）
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.model,
    required this.updatedAt,
    this.preview = '',
    this.systemPrompt = '',
    this.answerBubble = false,
  });

  final int id;
  final String title;
  final String model;
  final DateTime updatedAt;
  final String preview;

  /// 该会话单独的系统提示词；空字符串表示未设置（回退到 `<system>` 或默认值）。
  final String systemPrompt;

  /// 该会话是否开启「回答气泡」：开启后所有回答包进气泡。
  final bool answerBubble;

  AppMode? get mode {
    for (final m in AppMode.values) {
      if (m.model == model) return m;
    }
    return null;
  }

  Conversation copyWith({
    String? title,
    String? model,
    DateTime? updatedAt,
    String? preview,
    String? systemPrompt,
    bool? answerBubble,
  }) {
    return Conversation(
      id: id,
      title: title ?? this.title,
      model: model ?? this.model,
      updatedAt: updatedAt ?? this.updatedAt,
      preview: preview ?? this.preview,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      answerBubble: answerBubble ?? this.answerBubble,
    );
  }
}

/// 附件的投递方式。
///
/// - [image]：走 `input_image` 内容块（内联 base64）
/// - [text]：小文本文件，内容直接拼进正文
/// - [document]：PDF / Office 等，先上传 Files API 拿 `file_id`，
///   再以 `document` / `input_file` 内容块引用（官方推荐方式）
enum AttachmentKind { image, text, document }

/// 待发送附件（相册 / 拍照 / 文件）。
class Attachment {
  const Attachment({
    required this.path,
    required this.dataUrl,
    this.textContent,
    this.sizeBytes = 0,
    this.kind,
    this.fileId,
    this.uploading = false,
  });

  final String path;

  /// base64 data URL（[data:image/xxx;base64,...]），发送时使用
  final String dataUrl;

  /// 文本文件的内容（UTF-8 解码后），非文本附件为 null
  final String? textContent;

  /// 文件字节数（用于消息里的文件卡片展示"4.43KB"）
  final int sizeBytes;

  /// 投递方式；为空时按 [dataUrl] / [textContent] 推断（兼容旧数据）
  final AttachmentKind? kind;

  /// 已上传到 Files API 后的 id（`file-api-xxx`）；未上传时为 null
  final String? fileId;

  /// 是否正在上传（界面上显示进度）
  final bool uploading;

  /// 文件名（用于非图片附件的预览/提示）
  String get fileName => p.basename(path);

  /// 是否为图片（仅图片可走 input_image 上传）
  bool get isImage =>
      (kind ?? _inferredKind()) == AttachmentKind.image &&
      dataUrl.startsWith('data:image/');

  /// 是否为可读文本文件
  bool get isText => (kind ?? _inferredKind()) == AttachmentKind.text;

  /// 是否需要走 Files API
  bool get isDocument => (kind ?? _inferredKind()) == AttachmentKind.document;

  AttachmentKind _inferredKind() {
    if (dataUrl.startsWith('data:image/')) return AttachmentKind.image;
    if (textContent != null) return AttachmentKind.text;
    return AttachmentKind.document;
  }

  Attachment copyWith({
    String? fileId,
    bool? uploading,
    AttachmentKind? kind,
    String? textContent,
    int? sizeBytes,
  }) {
    return Attachment(
      path: path,
      dataUrl: dataUrl,
      textContent: textContent ?? this.textContent,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      kind: kind ?? this.kind,
      fileId: fileId ?? this.fileId,
      uploading: uploading ?? this.uploading,
    );
  }
}

/// 消息里引用的文档 / 文本文件（重放历史时据此重建内容块）。
@immutable
class ChatFile {
  const ChatFile({
    required this.id,
    required this.name,
    this.sizeBytes = 0,
    this.text,
  });

  /// Files API 返回的 `file-api-xxx`；文本文件用 `text:文件名` 前缀，
  /// 上游不支持的格式用 `unsupported:文件名` 前缀（本地结构化记录，不进请求）。
  final String id;
  final String name;
  final int sizeBytes;

  /// 文本文件的完整内容（仅 `text:` 文件有）；发给模型时展开成文本块，
  /// 显示层只渲染文件卡片，不展示这段内容。
  final String? text;

  bool get isTextFile => id.startsWith('text:');

  bool get isUnsupported => id.startsWith('unsupported:');

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'size': sizeBytes,
    if (text != null) 'text': text,
  };

  static ChatFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    return ChatFile(
      id: id,
      name: (raw['name'] as String?) ?? 'document',
      sizeBytes: (raw['size'] as num?)?.toInt() ?? 0,
      text: raw['text'] is String ? raw['text'] as String : null,
    );
  }
}
