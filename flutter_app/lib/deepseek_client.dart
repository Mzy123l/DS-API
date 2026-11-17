// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'data/message_codec.dart';
import 'image_fit.dart';
import 'models.dart';
import 'prompt.dart';

/// 上传到官方 Files API 的文档。
class UploadedFile {
  const UploadedFile({
    required this.id,
    required this.name,
    this.sizeBytes = 0,
  });

  final String id;
  final String name;
  final int sizeBytes;
}

/// 把消息列表转换为 Responses API 的 input 数组。
/// 与 QML 版 buildResponsesInput 保持一致：
/// - 跳过空占位（末尾空 assistant 及无文字无图的 user）
/// - 图片用 content 数组传递（input_image + image_url dataURL + detail: low）
/// - 文档用 input_file + file_id 传递（官方 Files API）
List<Map<String, dynamic>> buildResponsesInput(
  List<ChatMessage> messages, {
  bool includeReasoning = false,
}) {
  final result = <Map<String, dynamic>>[];
  for (final msg in messages) {
    final isUser = msg.role == MessageRole.user;
    final hasImage = isUser && msg.hasImage;
    final hasFile = isUser && msg.hasFiles;
    // `<system>...</system>` 只作为请求顶层的 system / instructions，
    // 不能把标签本身也当成用户正文发给模型（否则它只是一段普通文本）。
    final content = isUser
        ? displayTextOf(msg.content).trim()
        : msg.content.trim();
    if (content.isEmpty && !hasImage && !hasFile) continue;

    // 带 tools 的请求必须回传历史 reasoning_content（DeepSeek 会校验），
    // 否则工具调用循环会 400。普通对话传了也会被忽略，但这里按需才带。
    if (includeReasoning && !isUser && msg.reasoning.trim().isNotEmpty) {
      result.add({
        'type': 'reasoning',
        'content': [
          {'type': 'reasoning_text', 'text': msg.reasoning.trim()},
        ],
      });
    }

    if (hasImage || hasFile) {
      final parts = <Map<String, dynamic>>[];
      if (content.isNotEmpty) {
        parts.add({'type': 'input_text', 'text': content});
      }
      for (final url in msg.imageDataUrls) {
        parts.add({'type': 'input_image', 'image_url': url, 'detail': 'low'});
      }
      for (final file in msg.files) {
        if (file.isTextFile) {
          // 文本文件：结构化内容在请求时刻展开成文本块（上游没有独立的
          // 文本文件通道），存库与显示只用结构化字段，不污染正文。
          final text = file.text ?? '';
          parts.add({
            'type': 'input_text',
            'text': '<file name="${file.name}">\n$text\n</file>',
          });
        } else if (!file.isUnsupported) {
          parts.add({'type': 'input_file', 'file_id': file.id});
        }
        // unsupported: 文件上游不认识，跳过不发，避免 400。
      }
      result.add({'role': isUser ? 'user' : 'assistant', 'content': parts});
    } else {
      result.add({'role': isUser ? 'user' : 'assistant', 'content': content});
    }
  }
  return result;
}

/// 发送前整理 input 里的图片：按真实内容确认格式、超出上游限制的按需缩小。
///
/// 历史消息里的图片也会走到这里，所以之前存进去的超尺寸图重发时不会
/// 再被上游拒掉（unsupported image）。返回整理后的 input 与被丢弃的
/// 图片数量（格式上游不支持，例如 HEIC/AVIF）。
Future<({List<Map<String, dynamic>> input, int dropped})> prepareInputImages(
  List<Map<String, dynamic>> input,
) async {
  if (!inputHasImages(input)) return (input: input, dropped: 0);
  var dropped = 0;
  var changed = false;
  final result = <Map<String, dynamic>>[];
  for (final item in input) {
    final content = item['content'];
    if (content is! List) {
      result.add(item);
      continue;
    }
    final parts = <Object?>[];
    var itemChanged = false;
    for (final part in content) {
      if (part is Map && part['type'] == 'input_image') {
        final url = part['image_url'];
        if (url is String) {
          final fixed = await sanitizeImageDataUrl(url);
          if (fixed == null) {
            dropped++;
            itemChanged = true;
            continue;
          }
          if (fixed != url) {
            final copy = Map<String, dynamic>.from(part);
            copy['image_url'] = fixed;
            parts.add(copy);
            itemChanged = true;
            continue;
          }
        }
      }
      parts.add(part);
    }
    if (itemChanged) {
      // 图片全被丢掉时必须留一个文本块：空 content 数组同样会被上游拒掉。
      if (parts.isEmpty) {
        parts.add({'type': 'input_text', 'text': '（图片格式不受支持，已跳过）'});
      }
      changed = true;
      final copy = Map<String, dynamic>.from(item);
      copy['content'] = parts;
      result.add(copy);
    } else {
      result.add(item);
    }
  }
  return (input: changed ? result : input, dropped: dropped);
}

/// 把 Responses 形态的 `input` 转换为 Anthropic Messages 的 `messages`。
/// - 文本：input_text / output_text -> {type: text}
/// - 图片：input_image 的 data URL -> {type: image, source: base64}
/// - Anthropic 要求 user/assistant 交替，相邻同角色会合并为一条，避免 400
List<Map<String, dynamic>> toAnthropicMessages(
  List<Map<String, dynamic>> input,
) {
  final result = <Map<String, dynamic>>[];
  for (final item in input) {
    // 联网搜索的工具调用：客户端内部统一用 Responses 形态的 input item，
    // 转到 Anthropic 时分别映射成 tool_use / tool_result 块。
    final itemType = item['type'];
    if (itemType == 'reasoning') {
      final text = _reasoningText(item['content']);
      if (text.isNotEmpty) {
        _appendAnthropicParts(result, 'assistant', [
          {'type': 'thinking', 'thinking': text},
        ]);
      }
      continue;
    }
    if (itemType == 'function_call') {
      final id = item['call_id'] ?? item['id'];
      final name = item['name'];
      if (id is String && id.isNotEmpty && name is String && name.isNotEmpty) {
        _appendAnthropicParts(result, 'assistant', [
          {
            'type': 'tool_use',
            'id': id,
            'name': name,
            'input': _decodeToolArguments(item['arguments']),
          },
        ]);
      }
      continue;
    }
    if (itemType == 'function_call_output') {
      final id = item['call_id'];
      if (id is String && id.isNotEmpty) {
        final output = item['output'];
        _appendAnthropicParts(result, 'user', [
          {
            'type': 'tool_result',
            'tool_use_id': id,
            'content': output is String ? output : jsonEncode(output),
          },
        ]);
      }
      continue;
    }

    final role = item['role'] == 'assistant' ? 'assistant' : 'user';
    final rawContent = item['content'];
    final parts = <Map<String, dynamic>>[];
    if (rawContent is String) {
      if (rawContent.trim().isNotEmpty) {
        parts.add({'type': 'text', 'text': rawContent});
      }
    } else if (rawContent is List) {
      for (final part in rawContent) {
        if (part is! Map) continue;
        final type = part['type'];
        if (type == 'input_text' || type == 'output_text') {
          final text = part['text'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add({'type': 'text', 'text': text});
          }
        } else if (type == 'input_image') {
          final parsed = _parseImageDataUrl(part['image_url'] as String? ?? '');
          if (parsed != null) {
            parts.add({
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': parsed.mediaType,
                'data': parsed.data,
              },
            });
          }
        } else if (type == 'input_file') {
          // 官方 Files API 引用：Anthropic 用 document + source.file.file_id
          final fileId = part['file_id'];
          if (fileId is String && fileId.isNotEmpty) {
            parts.add({
              'type': 'document',
              'source': {'type': 'file', 'file_id': fileId},
            });
          }
        }
      }
    }
    _appendAnthropicParts(result, role, parts);
  }
  return result;
}

/// 相邻同角色消息合并进同一条（Anthropic 要求 user/assistant 交替）。
void _appendAnthropicParts(
  List<Map<String, dynamic>> result,
  String role,
  List<Map<String, dynamic>> parts,
) {
  if (parts.isEmpty) return;
  if (result.isNotEmpty && result.last['role'] == role) {
    (result.last['content'] as List<Map<String, dynamic>>).addAll(parts);
  } else {
    result.add({'role': role, 'content': parts});
  }
}

/// 从 Responses 形态的 reasoning item 里取出明文思考内容。
String _reasoningText(dynamic content) {
  if (content is String) return content.trim();
  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is Map &&
          part['type'] == 'reasoning_text' &&
          part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    return buffer.toString().trim();
  }
  return '';
}

/// 把模型生成的 arguments（JSON 字符串或对象）还原成 Map。
Map<String, dynamic> _decodeToolArguments(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) {
    return {for (final entry in raw.entries) entry.key.toString(): entry.value};
  }
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
      }
    } catch (_) {
      // 模型偶发生成非法 JSON：按空参数处理，由工具执行端返回可读错误。
    }
  }
  return const <String, dynamic>{};
}

/// 解析 `data:image/png;base64,xxx` 形态的图片地址。
_ImageData? _parseImageDataUrl(String dataUrl) {
  if (!dataUrl.startsWith('data:')) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  final meta = dataUrl.substring(5, comma);
  final semicolon = meta.indexOf(';');
  final mediaType = (semicolon >= 0 ? meta.substring(0, semicolon) : meta)
      .trim();
  final data = dataUrl.substring(comma + 1).trim();
  if (mediaType.isEmpty || data.isEmpty) return null;
  return _ImageData(mediaType, data);
}

class _ImageData {
  const _ImageData(this.mediaType, this.data);

  final String mediaType;
  final String data;
}

/// 官方全家桶服务端工具名（由上游执行，客户端不需要实现）。
const String webSearchToolName = 'deepseek_web_search';
const String readUrlToolName = 'deepseek_read_url';

/// 中转服务执行的函数工具名（客户端只声明，服务端负责跑）。
const String ocrToolName = 'ocr';

/// 语音合成工具：模型按用户要求把一段文字合成为音频文件返回。
const String ttsToolName = 'text_to_speech';

/// `text_to_speech` 函数工具：让模型**直接产出一个音频文件**。
///
/// 与「朗读当前回答」不是一回事：这是模型可调用的工具，用户在对话里
/// 提出「把这段念出来 / 生成一段语音」时，模型调用它拿到音频文件。
///
/// 描述只讲「做什么、参数是什么」：不写客户端怎么渲染、也不教模型
/// 什么时候该用——那是模型自己按用户意图判断的事。
const Map<String, dynamic> _ttsToolSpec = {
  'name': ttsToolName,
  'description': '把一段文本合成为语音音频，返回可播放的音频文件。',
  'parameters': {
    'type': 'object',
    'properties': {
      'text': {
        'type': 'string',
        'description': '要合成的文本',
      },
    },
    'required': ['text'],
  },
};

/// 服务端工具声明：Anthropic 协议要求带 `name`，Responses 只要 `type`。
///
/// 官方限制：这两个工具**只能声明一次**，且不能与其它服务端工具混用；
/// `tool_choice` 也不能指定它们（会 400）。
List<Map<String, dynamic>> anthropicFamilyTools({
  bool webSearch = true,
  bool readUrl = true,
  bool ocr = false,
  bool tts = false,
}) => [
  if (webSearch) {'type': webSearchToolName, 'name': webSearchToolName},
  if (readUrl) {'type': readUrlToolName, 'name': readUrlToolName},
  if (ocr) _anthropicFunctionTool(_ocrToolSpec),
  if (tts) _anthropicFunctionTool(_ttsToolSpec),
];

/// Responses 协议的工具声明。
List<Map<String, dynamic>> responsesFamilyTools({
  bool webSearch = true,
  bool readUrl = true,
  bool ocr = false,
  bool tts = false,
}) => [
  if (webSearch) {'type': webSearchToolName},
  if (readUrl) {'type': readUrlToolName},
  if (ocr) _responsesFunctionTool(_ocrToolSpec),
  if (tts) _responsesFunctionTool(_ttsToolSpec),
];

/// `ocr` 函数工具：由中转服务执行（直连时客户端自己执行）。
///
/// 参数是 `/v1/files` 返回的 `file_id`。描述同样只讲能力与参数。
const Map<String, dynamic> _ocrToolSpec = {
  'name': ocrToolName,
  'description': '识别文档或图片中的文字，按页返回。',
  'parameters': {
    'type': 'object',
    'properties': {
      'file_id': {'type': 'string', 'description': '文档的 file_id'},
      'purpose': {
        'type': 'string',
        'enum': ['text_recognition', 'rich_layout_recognition'],
        'description':
            'text_recognition 只提取文字；rich_layout_recognition 连图片版式一起识别。默认 text_recognition',
      },
    },
    'required': ['file_id'],
  },
};

Map<String, dynamic> _anthropicFunctionTool(Map<String, dynamic> spec) => {
  'name': spec['name'],
  'description': spec['description'],
  'input_schema': spec['parameters'],
};

Map<String, dynamic> _responsesFunctionTool(Map<String, dynamic> spec) => {
  'type': 'function',
  'name': spec['name'],
  'description': spec['description'],
  'parameters': spec['parameters'],
};

/// 一次请求的流式解析状态（增量时序 + 本轮工具调用）。
class _StreamState {
  bool reasoningGot = false;
  bool contentGot = false;
  int? reasoningStartedAtMs;
  int? contentStartedAtMs;

  /// 本轮已到达的正文/思维链（继续对话时作为 assistant 上下文回传）
  String content = '';
  String reasoning = '';

  /// 本轮模型要求客户端执行的工具调用
  final List<_ToolCall> toolCalls = [];
  final Map<int, _ToolCall> anthropicToolsByIndex = {};
  final Map<String, _ToolCall> responseToolsById = {};
}

/// 模型发起的一次函数工具调用（search / fetch）。
class _ToolCall {
  _ToolCall({required this.id, required this.name});

  final String id;
  final String name;
  String arguments = '';

  Map<String, dynamic> get input => _decodeToolArguments(arguments);
}

/// 单轮请求的结果（联网搜索工具循环用）。
class _RoundOutcome {
  const _RoundOutcome.ok() : error = null, canceled = false;
  const _RoundOutcome.error(this.error) : canceled = false;
  const _RoundOutcome.canceled() : error = null, canceled = true;

  final String? error;
  final bool canceled;
}

/// 单行 SSE 事件解析结果：判断该事件是否应结束本次请求。
enum _StreamTerminal { none, done, failed }

/// 一次流式消费的结果：终止原因 + 网络异常（异常表示连接中断）。
class _StreamResult {
  const _StreamResult(this.terminal, [this.error]);

  final _StreamTerminal terminal;
  final Object? error;
}

/// 服务器侧任务快照：断线补齐时用它对账（内容以服务端为准）。
class RemoteSnapshot {
  const RemoteSnapshot({
    required this.reasoning,
    required this.content,
    this.sources = const [],
    this.reasoningMs = 0,
    this.messageId,
    this.resultReady = false,
    this.audio = const [],
  });

  final String reasoning;
  final String content;
  final List<ChatSource> sources;
  final int reasoningMs;

  /// 服务端落库后的助手消息 id（未落库时为 null）
  final int? messageId;

  /// 服务端是否已经把最终内容写进这条消息。
  /// 旧服务器不下发该字段时为 false，调用方按旧逻辑回退。
  final bool resultReady;

  /// 模型用 text_to_speech 生成的音频（服务端执行时由快照带回）
  final List<ChatFile> audio;
}

/// 一次任务快照查询的结果。
///
/// [gone] 表示服务端明确回了 404（任务已被回收），与“网络暂时连不上”区分开：
/// 后者要一直重试，前者才需要按会话历史兜底。
class _JobSnapshotResult {
  const _JobSnapshotResult.available(this.data) : gone = false;

  const _JobSnapshotResult.gone() : data = null, gone = true;

  const _JobSnapshotResult.unavailable() : data = null, gone = false;

  final Map<String, dynamic>? data;
  final bool gone;
}

/// DeepSeek 流式客户端，支持两种协议（由调用方选定，一次请求只走一种）：
///
/// - [ApiProtocol.responses]：POST {base}/responses，SSE 解析
/// - response.reasoning_text.delta / .done  -> 思维链
/// - response.output_text.delta / .done     -> 回答正文
/// - response.output_item.* / function_call_arguments.* -> search / fetch 工具调用
/// - response.failed                        -> 错误
///
/// - [ApiProtocol.anthropic]：POST {base}/messages（Anthropic Messages），SSE 解析
/// - content_block_delta(thinking_delta)    -> 思维链
/// - content_block_delta(text_delta)        -> 回答正文
/// - content_block_start(web_search_tool_result) -> 联网搜索来源
/// - content_block_start(tool_use) / input_json_delta -> search / fetch 工具调用
/// - message_stop / error                   -> 完成 / 错误
///
/// 开启联网搜索时会同时下发官方 web_search 服务端工具与 search / fetch 函数工具：
/// 服务端工具由上游执行；函数工具由客户端调用 `POST /v1/tools/search|fetch`
/// 执行，结果回填后继续下一轮，直到模型给出最终回答。
class DeepSeekClient {
  static const String _defaultBase = String.fromEnvironment(
    'DEEPSEEK_BASE_URL',
    defaultValue: 'https://api.deepseek.com',
  );

  /// 回答长度不设上限：请求默认不发送 max_tokens，由服务端决定输出长度。
  /// 仅当服务端强制要求 max_tokens 字段（返回 400）时，才按此序列补值重试。
  static const List<int> _anthropicMaxTokensFallbacks = <int>[
    131072,
    65536,
    32768,
    8192,
  ];

  DeepSeekClient({
    String? baseUrl,
    String? relayBaseUrl,
    String? relayToken,
    bool useRelay = false,
    http.Client? client,
    Duration relayIdleTimeout = _defaultRelayIdleTimeout,
  }) : baseUrl = baseUrl ?? _defaultBase,
       _relayBaseUrl = relayBaseUrl,
       _relayToken = relayToken,
       _useRelay = useRelay,
       _client = client,
       _relayIdleTimeout = relayIdleTimeout;

  /// 直连上游地址（默认官方 API，可用 `--dart-define=DEEPSEEK_BASE_URL` 覆盖）。
  String baseUrl;

  String? _relayBaseUrl;
  String? _relayToken;
  bool _useRelay;

  /// 运行期更新地址配置：App 内改服务器地址后立即生效，无需重启或重编译。
  void configure({
    String? baseUrl,
    String? relayBaseUrl,
    String? relayToken,
    bool? useRelay,
  }) {
    final trimmedBase = baseUrl?.trim();
    if (trimmedBase != null && trimmedBase.isNotEmpty) {
      this.baseUrl = trimmedBase;
    }
    if (relayBaseUrl != null) _relayBaseUrl = relayBaseUrl.trim();
    if (relayToken != null) _relayToken = relayToken.trim();
    if (useRelay != null) _useRelay = useRelay;
  }

  /// 是否走中转服务器（未配置地址时自动回退到直连）。
  bool get useRelay => _useRelay && (_relayBaseUrl?.trim().isNotEmpty ?? false);

  String? get relayBaseUrl => _relayBaseUrl;

  /// 服务器访问口令（服务端设置 RELAY_TOKEN 时必填）
  String? get relayToken => _relayToken;

  /// 系统提示词：Anthropic 端点放顶层 `system`，Responses 端点放 `instructions`
  String? systemPrompt;

  /// 是否声明 `ocr` 函数工具（本会话里有已上传的文档时开启）。
  ///
  /// 中转模式下由服务端执行；直连模式下由客户端自己调 `/v1/tools/ocr`。
  bool enableOcrTool = false;

  /// 是否声明 `text_to_speech` 函数工具：模型可**直接产出音频文件**。
  bool enableTtsTool = false;

  /// 执行 `text_to_speech` 时实际调用 TTS 的函数（由 AppState 注入）。
  ///
  /// 返回本地音频文件路径；失败抛异常，错误信息会回填给模型。
  Future<String> Function(String text)? ttsRunner;

  /// 实际要声明的 `ocr` 工具：只有当前请求里真的带了 file_id 才有意义。
  bool get _ocrTool => enableOcrTool;

  /// 调试/测试用：按当前开关生成 Anthropic 协议的工具声明。
  ///
  /// 与真正发请求时走的是同一套规则（联网时不混入 ocr / tts）。
  @visibleForTesting
  List<Map<String, dynamic>> debugAnthropicTools({required bool webSearch}) =>
      anthropicFamilyTools(
        webSearch: webSearch,
        readUrl: webSearch,
        ocr: _ocrTool && !webSearch,
        tts: enableTtsTool && !webSearch,
      );

  Map<String, String> get _relayHeaders => {
    if ((_relayToken ?? '').isNotEmpty) 'x-relay-token': _relayToken!,
  };

  /// 当前任务的服务器侧 id（中转模式下由服务端下发）。
  String? _jobId;

  String? get activeJobId => _jobId;

  http.Client? _client;

  /// 替换底层 HTTP 客户端（例如换成按指纹校验自签名证书的实现）。
  void useHttpClient(http.Client client) {
    _client = client;
  }

  StreamSubscription<String>? _streamSubscription;
  Completer<void>? _streamCompleter;
  Completer<_StreamResult>? _relayCompleter;
  bool _cancelled = false;

  /// 中转流的空闲看门狗：服务端每 10 秒发一次心跳，超过这个时间一个字节
  /// 都没收到，说明连接已经静默断开（退后台/切网时很常见），应转去拉快照。
  /// 取 90 秒：服务端等上游首字节最长 60 秒，期间客户端本来就收不到数据。
  static const Duration _defaultRelayIdleTimeout = Duration(seconds: 90);
  final Duration _relayIdleTimeout;
  Timer? _idleTimer;

  /// 已探测通过的 max_tokens 取值（null 表示不发该字段也能通过），
  /// 成功后记住，后续请求不再重复试探。
  List<int?>? _maxTokensPlanCache;

  /// 按协议解析请求地址：
  /// - responses：{base}/responses
  /// - anthropic：base 已带路径（本地网关 .../v1）时用 {base}/messages，
  ///   否则按官方格式用 {base}/anthropic/v1/messages
  String endpointUrl(ApiProtocol protocol) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    if (protocol == ApiProtocol.responses) return '$base/responses';
    final path = Uri.parse(base).path;
    if (path.isEmpty || path == '/') return '$base/anthropic/v1/messages';
    return '$base/messages';
  }

  void cancel() {
    _cancelled = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _streamSubscription?.cancel();
    // 手动取消时也要让 send() 的 await 正常返回，避免 busy 永远卡住
    final c = _streamCompleter;
    if (c != null && !c.isCompleted) c.complete();
    final rc = _relayCompleter;
    if (rc != null && !rc.isCompleted) {
      rc.complete(const _StreamResult(_StreamTerminal.none));
    }
    // 中转模式下同时通知服务器停止生成，避免继续消耗额度
    final jobId = _jobId;
    if (jobId != null && useRelay) unawaited(_cancelRemoteJob(jobId));
  }

  /// 只脱离当前流（切走会话/新建对话时用）：**不通知服务器取消**，
  /// 任务继续在服务端跑，回到该会话时按任务快照续上。
  void detach() {
    _cancelled = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _streamSubscription?.cancel();
    final c = _streamCompleter;
    if (c != null && !c.isCompleted) c.complete();
    final rc = _relayCompleter;
    if (rc != null && !rc.isCompleted) {
      rc.complete(const _StreamResult(_StreamTerminal.none));
    }
  }

  /// 发起一次对话请求。input 由调用方拼接完整上下文。
  ///
  /// - 直连（默认）：直接请求上游，流式解析 SSE；
  /// - 中转（[useRelay]）：请求交给服务器执行并下发任务 id，
  ///   连接中断（退后台、切网、进程被回收）时用任务快照补齐完整回答。
  ///
  /// 联网搜索现在由上游服务端执行（`deepseek_web_search`），客户端不再跑
  /// search / fetch 工具循环；只有 `ocr` 函数工具需要在本地或中转侧执行。
  Future<void> send({
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    bool webSearch = false,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function() onDone,
    required void Function(String error) onError,
    void Function(String jobId)? onJobStarted,
    void Function(RemoteSnapshot snapshot)? onSnapshot,

    /// 服务端明确表示任务已不存在（服务重启 / 超过保留时间）时回调。
    void Function()? onJobLost,
    int? conversationId,
  }) async {
    _cancelled = false;
    _jobId = null;
    // 只有需要本地执行的函数工具（ocr / tts）才走多轮循环；
    // 联网搜索由上游服务端完成，一条流就能拿到最终回答。
    if ((_ocrTool || enableTtsTool) && !useRelay) {
      await _sendWithTools(
        input: input,
        model: model,
        protocol: protocol,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
        apiKey: apiKey,
        webSearch: webSearch,
        onReasoningDelta: onReasoningDelta,
        onContentDelta: onContentDelta,
        onReasoningTimed: onReasoningTimed,
        onSources: onSources,
        onDone: onDone,
        onError: onError,
        onJobStarted: onJobStarted,
        onSnapshot: onSnapshot,
        conversationId: conversationId,
      );
      return;
    }
    if (useRelay) {
      // 联网搜索 / 文件输入 / ocr 工具都走这里：服务端负责执行工具和续轮次，
      // 客户端只收流。
      await _sendRelay(
        input: input,
        model: model,
        protocol: protocol,
        thinkingEnabled: thinkingEnabled,
        reasoningEffort: reasoningEffort,
        apiKey: apiKey,
        webSearch: webSearch,
        onReasoningDelta: onReasoningDelta,
        onContentDelta: onContentDelta,
        onReasoningTimed: onReasoningTimed,
        onSources: onSources,
        onDone: onDone,
        onError: onError,
        onJobStarted: onJobStarted,
        onSnapshot: onSnapshot,
        onJobLost: onJobLost,
        conversationId: conversationId,
      );
      return;
    }
    await _sendDirect(
      input: input,
      model: model,
      protocol: protocol,
      thinkingEnabled: thinkingEnabled,
      reasoningEffort: reasoningEffort,
      apiKey: apiKey,
      webSearch: webSearch,
      onReasoningDelta: onReasoningDelta,
      onContentDelta: onContentDelta,
      onReasoningTimed: onReasoningTimed,
      onSources: onSources,
      onDone: onDone,
      onError: onError,
    );
  }

  /// 函数工具主循环（直连模式下执行 `ocr`）。
  ///
  /// 轮次不设上限：一直续到模型不再调用工具、用户取消或请求出错为止。
  /// 服务端工具（`deepseek_web_search` / `deepseek_read_url`）由上游执行，
  /// 它们的调用与结果不会出现在这里的 [st.toolCalls] 中。
  Future<void> _sendWithTools({
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    bool webSearch = false,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function() onDone,
    required void Function(String error) onError,
    void Function(String jobId)? onJobStarted,
    void Function(RemoteSnapshot snapshot)? onSnapshot,
    int? conversationId,
  }) async {
    if (input.isEmpty) {
      onError('消息为空');
      return;
    }
    final working = <Map<String, dynamic>>[
      for (final item in input) Map<String, dynamic>.from(item),
    ];
    String? lastJobId;
    while (true) {
      if (_cancelled) {
        _cancelled = false;
        return;
      }
      final st = _StreamState();
      final outcome = useRelay
          ? await _roundRelay(
              st: st,
              input: working,
              model: model,
              protocol: protocol,
              thinkingEnabled: thinkingEnabled,
              reasoningEffort: reasoningEffort,
              apiKey: apiKey,
              webSearch: true,
              onReasoningDelta: onReasoningDelta,
              onContentDelta: onContentDelta,
              onReasoningTimed: onReasoningTimed,
              onSources: onSources,
              onJobStarted: (jobId) {
                lastJobId = jobId;
                onJobStarted?.call(jobId);
              },
              conversationId: conversationId,
            )
          : await _roundDirect(
              st: st,
              input: working,
              model: model,
              protocol: protocol,
              thinkingEnabled: thinkingEnabled,
              reasoningEffort: reasoningEffort,
              apiKey: apiKey,
              webSearch: true,
              onReasoningDelta: onReasoningDelta,
              onContentDelta: onContentDelta,
              onReasoningTimed: onReasoningTimed,
              onSources: onSources,
            );
      if (outcome.canceled || _cancelled) {
        _cancelled = false;
        return;
      }
      if (outcome.error != null) {
        onError(outcome.error!);
        return;
      }
      // 没有函数调用：本轮就是最终回答。服务端已经把它写进会话，
      // 拉一次任务快照拿到 stored_message_id，客户端只补本地缓存。
      if (st.toolCalls.isEmpty) {
        if (useRelay && lastJobId != null) {
          await _recoverRelayJob(
            jobId: lastJobId!,
            onSnapshot: onSnapshot,
            onDone: onDone,
            onError: onError,
          );
        } else {
          onDone();
        }
        return;
      }
      if (st.reasoning.trim().isNotEmpty) {
        working.add({
          'type': 'reasoning',
          'content': [
            {'type': 'reasoning_text', 'text': st.reasoning.trim()},
          ],
        });
      }
      if (st.content.trim().isNotEmpty) {
        working.add({'role': 'assistant', 'content': st.content});
      }
      for (final call in st.toolCalls) {
        working.add({
          'type': 'function_call',
          'call_id': call.id,
          'name': call.name,
          'arguments': call.arguments.trim().isEmpty ? '{}' : call.arguments,
        });
      }
      for (final call in st.toolCalls) {
        if (_cancelled) {
          _cancelled = false;
          return;
        }
        final output = await _executeTool(call, apiKey, onSources);
        working.add({
          'type': 'function_call_output',
          'call_id': call.id,
          'output': output,
        });
      }
    }
  }

  /// 直连模式的一轮请求（联网搜索工具循环用，不触发 onDone）。
  Future<_RoundOutcome> _roundDirect({
    required _StreamState st,
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    required bool webSearch,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
  }) async {
    final client = _client ??= http.Client();
    final uri = Uri.parse(endpointUrl(protocol));
    final maxTokensPlan = protocol == ApiProtocol.anthropic
        ? _anthropicMaxTokensPlan()
        : const <int?>[null];
    try {
      for (var i = 0; i < maxTokensPlan.length; i++) {
        final maxTokens = maxTokensPlan[i];
        final payload = protocol == ApiProtocol.anthropic
            ? _anthropicPayload(
                input: input,
                model: model,
                maxTokens: maxTokens,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              )
            : _responsesPayload(
                input: input,
                model: model,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              );
        final request = http.Request('POST', uri)
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..body = jsonEncode(payload);
        if (protocol == ApiProtocol.anthropic) {
          request.headers['x-api-key'] = apiKey;
          request.headers['anthropic-version'] = '2023-06-01';
        } else {
          request.headers['Authorization'] = 'Bearer $apiKey';
        }
        final res = await client.send(request);
        if (res.statusCode != 200) {
          final bodyText = await res.stream.bytesToString();
          final message = _extractError(bodyText, res.statusCode);
          if (i + 1 < maxTokensPlan.length && _isMaxTokensRejected(message)) {
            continue;
          }
          return _RoundOutcome.error(message);
        }
        if (protocol == ApiProtocol.anthropic) {
          _maxTokensPlanCache = <int?>[maxTokens];
        }
        var eventError = '';
        final result = await _consumeSse(
          res.stream,
          st,
          protocol: protocol,
          onReasoningDelta: onReasoningDelta,
          onContentDelta: onContentDelta,
          onReasoningTimed: onReasoningTimed,
          onSources: onSources,
          onError: (message) => eventError = message,
        );
        if (_cancelled) return const _RoundOutcome.canceled();
        if (eventError.isNotEmpty) return _RoundOutcome.error(eventError);
        if (result.error != null) {
          return _RoundOutcome.error('请求失败：${result.error}');
        }
        return const _RoundOutcome.ok();
      }
    } catch (e) {
      return _RoundOutcome.error('请求失败：$e');
    }
    return const _RoundOutcome.error('请求失败');
  }

  /// 中转模式的一轮请求：中间轮次由服务端识别工具调用并跳过落库。
  Future<_RoundOutcome> _roundRelay({
    required _StreamState st,
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    required bool webSearch,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    void Function(String jobId)? onJobStarted,
    int? conversationId,
  }) async {
    final base = _trimSlash(_relayBaseUrl ?? '');
    final client = _client ??= http.Client();
    final maxTokensPlan = protocol == ApiProtocol.anthropic
        ? _anthropicMaxTokensPlan()
        : const <int?>[null];
    try {
      for (var i = 0; i < maxTokensPlan.length; i++) {
        final maxTokens = maxTokensPlan[i];
        final payload = protocol == ApiProtocol.anthropic
            ? _anthropicPayload(
                input: input,
                model: model,
                maxTokens: maxTokens,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              )
            : _responsesPayload(
                input: input,
                model: model,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              );
        final request = http.Request('POST', Uri.parse('$base/v1/chat'))
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..headers.addAll(_relayHeaders)
          ..body = jsonEncode({
            'protocol': protocol == ApiProtocol.anthropic
                ? 'anthropic'
                : 'responses',
            'payload': payload,
            'conversation_id': ?conversationId,
          });
        if (protocol == ApiProtocol.anthropic) {
          request.headers['x-api-key'] = apiKey;
          request.headers['anthropic-version'] = '2023-06-01';
        } else {
          request.headers['Authorization'] = 'Bearer $apiKey';
        }
        final res = await client.send(request);
        if (res.statusCode != 200) {
          final bodyText = await res.stream.bytesToString();
          final message = _extractError(bodyText, res.statusCode);
          if (i + 1 < maxTokensPlan.length && _isMaxTokensRejected(message)) {
            continue;
          }
          return _RoundOutcome.error(message);
        }
        if (protocol == ApiProtocol.anthropic) {
          _maxTokensPlanCache = <int?>[maxTokens];
        }
        var eventError = '';
        final result = await _consumeSse(
          res.stream,
          st,
          protocol: protocol,
          onReasoningDelta: onReasoningDelta,
          onContentDelta: onContentDelta,
          onReasoningTimed: onReasoningTimed,
          onSources: onSources,
          onError: (message) => eventError = message,
          onJobEvent: (line) => _handleJobEvent(line, onJobStarted),
        );
        if (_cancelled) return const _RoundOutcome.canceled();
        if (eventError.isNotEmpty) return _RoundOutcome.error(eventError);
        if (result.error != null) {
          return _RoundOutcome.error('请求失败：${result.error}');
        }
        return const _RoundOutcome.ok();
      }
    } catch (e) {
      return _RoundOutcome.error('请求失败：$e');
    }
    return const _RoundOutcome.error('请求失败');
  }

  /// 执行一次函数工具调用，返回给模型的文本结果。
  ///
  /// 现在只剩 `ocr`（联网搜索与阅读链接由上游服务端执行，不会走到这里）。
  Future<String> _executeTool(
    _ToolCall call,
    String apiKey,
    void Function(List<ChatSource> sources)? onSources,
  ) async {
    final input = call.input;
    try {
      if (call.name == ocrToolName) {
        final fileId = (input['file_id'] as String?)?.trim() ?? '';
        if (fileId.isEmpty) {
          return jsonEncode({'error': 'ocr 缺少 file_id'});
        }
        final rawPurpose = input['purpose'];
        final purpose =
            (rawPurpose is String && rawPurpose.isNotEmpty)
            ? rawPurpose
            : 'text_recognition';
        final data = await _postJson('/v1/tools/ocr', {
          'file_id': fileId,
          'purpose': purpose,
        }, apiKey);
        final pages = data['pages'];
        final buffer = StringBuffer();
        if (pages is List) {
          for (final page in pages) {
            if (page is! Map) continue;
            final text = page['text'];
            if (text is! String || text.trim().isEmpty) continue;
            final index = page['index'];
            buffer.writeln('--- 第 ${(index is num ? index.toInt() : 0) + 1} 页 ---');
            buffer.writeln(text);
          }
        }
        if (buffer.isEmpty) {
          return jsonEncode({'error': '这份文件没有识别出文字'});
        }
        return jsonEncode({'text': buffer.toString().trim()});
      }
      if (call.name == ttsToolName) {
        final text = (input['text'] as String?)?.trim() ?? '';
        if (text.isEmpty) {
          return jsonEncode({'error': 'text_to_speech 缺少 text'});
        }
        final runner = ttsRunner;
        if (runner == null) {
          return jsonEncode({'error': '当前环境不支持语音合成'});
        }
        final path = await runner(text);
        // 告诉模型文件已生成；具体音频由客户端以卡片形式展示给用户
        return jsonEncode({
          'status': 'ok',
          'file': path,
          'message': '音频已生成，客户端会以音频卡片展示，用户可直接播放。',
        });
      }
      return jsonEncode({'error': '未知工具：${call.name}'});
    } catch (e) {
      // 4xx（例如文件过期）重试也不会成功；明确告诉模型别再试。
      return jsonEncode({'error': '工具调用失败：$e。不要重试同一个文件，请根据已有信息直接回答。'});
    }
  }

  /// 调用中转/上游的 JSON 接口（目前用于 ocr）。
  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> payload,
    String apiKey,
  ) async {
    final client = _client ??= http.Client();
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };
    if (useRelay) headers.addAll(_relayHeaders);
    final response = await client
        .post(
          Uri.parse(apiEndpointUrl(path)),
          headers: headers,
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 180));
    dynamic decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode != 200) {
      var message = '请求失败 (HTTP ${response.statusCode})';
      if (decoded is Map && decoded['error'] is Map) {
        final inner = decoded['error'] as Map;
        final raw = inner['message'];
        if (raw is String && raw.isNotEmpty) message = raw;
      }
      throw Exception(message);
    }
    if (decoded is Map<String, dynamic>) return decoded;
    throw Exception('返回格式错误');
  }

  /// 调用官方 Search / Fetch API（直连上游或经中转）。
  Future<Map<String, dynamic>> postTool(
    String tool,
    Map<String, dynamic> payload,
    String apiKey,
  ) => _postJson('/v1/tools/$tool', payload, apiKey);

  /// 通用 API 地址：中转模式走中转，直连模式走上游根路径。
  ///
  /// 兼容 base 自带路径的配置（`.../v1`、`.../anthropic`、`.../anthropic/v1`）。
  String apiEndpointUrl(String path) {
    if (useRelay) {
      return '${_trimSlash(_relayBaseUrl ?? '')}$path';
    }
    final base = _trimSlash(baseUrl);
    final uri = Uri.parse(base);
    final current = uri.path;
    if (current.isEmpty ||
        current == '/' ||
        current == '/v1' ||
        current == '/anthropic' ||
        current == '/anthropic/v1') {
      return '${uri.scheme}://${uri.authority}$path';
    }
    return '$base$path';
  }

  /// 官方 Search / Fetch API 地址：中转模式走中转，直连模式走上游根路径。
  String toolsEndpointUrl(String tool) => apiEndpointUrl('/v1/tools/$tool');

  /// 上传并解析一个文档（官方 Files API），返回 `file-api-xxx`。
  ///
  /// - 中转模式：走中转的 `/v1/files`（服务端会把字节缓存一份给 ocr 工具用）；
  /// - 直连模式：直接打上游 `POST {base}/files`。
  ///
  /// 官方要求 multipart 里 **`purpose` 字段排在 `file` 之前**，顺序不能反。
  /// 解析在服务端完成，解析成功才返回，所以超时给得比较宽。
  Future<UploadedFile> uploadFile(
    File file, {
    required String apiKey,
    String purpose = 'rich_layout_recognition',
  }) async {
    final client = _client ??= http.Client();
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(apiEndpointUrl('/v1/files')),
    );
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.headers['Accept'] = 'application/json';
    if (useRelay) request.headers.addAll(_relayHeaders);
    // 顺序敏感：先 purpose，再 file
    request.fields['purpose'] = purpose;
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: p.basename(file.path),
      ),
    );
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 300));
    final response = await http.Response.fromStream(streamed);
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode != 200) {
      var message = '上传失败 (HTTP ${response.statusCode})';
      if (decoded is Map && decoded['error'] is Map) {
        final inner = decoded['error'] as Map;
        final raw = inner['message'];
        if (raw is String && raw.isNotEmpty) message = raw;
      }
      throw Exception(message);
    }
    if (decoded is! Map) throw Exception('上传返回格式错误');
    final id = decoded['id'];
    if (id is! String || id.isEmpty) throw Exception('上传没有返回 file_id');
    return UploadedFile(
      id: id,
      name: (decoded['filename'] as String?) ?? p.basename(file.path),
      sizeBytes: (decoded['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// 取回服务端生成的音频字节（`GET /v1/audio/{id}`）。
  ///
  /// 服务端执行 text_to_speech 时，音频只存在它的缓存里，快照只给 id；
  /// 客户端点播放时按 id 取一次并落本地文件，之后直接播本地。
  Future<Uint8List?> fetchAudio(String audioId, {String apiKey = ''}) async {
    final base = _trimSlash(_relayBaseUrl ?? '');
    if (base.isEmpty) return null;
    final client = _client ??= http.Client();
    final headers = <String, String>{..._relayHeaders};
    if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
    try {
      final res = await client
          .get(Uri.parse('$base/v1/audio/$audioId'), headers: headers)
          .timeout(const Duration(seconds: 120));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return null;
      return res.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// 恢复服务器上已有任务的输出（App 重开后补齐没看完的回答）。
  ///
  /// [onJobLost]：服务端明确表示任务已不存在时回调（由调用方按会话历史补）。
  Future<void> resumeJob({
    required String jobId,
    required void Function(RemoteSnapshot snapshot) onSnapshot,
    required void Function() onDone,
    required void Function(String error) onError,
    void Function()? onJobLost,
  }) async {
    if (!useRelay) {
      onError('未启用中转服务器，无法恢复未完成的回答');
      return;
    }
    _cancelled = false;
    _jobId = jobId;
    await _recoverRelayJob(
      jobId: jobId,
      onSnapshot: onSnapshot,
      onDone: onDone,
      onError: onError,
      onJobLost: onJobLost,
    );
  }

  /// 等任务进入终态并取回快照（点“停止”后对齐落库结果用）。
  ///
  /// 取消时服务端会先把任务标记为 canceled，随后才把已生成的内容写进会话存储，
  /// 所以这里要等到落库 id 出现（或确认没有内容可存）再返回：
  /// 拿到 id 后客户端只补本地缓存，就不会和这次服务端落库各存一条。
  ///
  /// 未启用中转、始终取不到快照（网络不通等）时返回 null。
  Future<RemoteSnapshot?> waitJobSnapshot(
    String jobId, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    if (!useRelay) return null;
    final deadline = DateTime.now().add(timeout);
    RemoteSnapshot? latest;
    while (DateTime.now().isBefore(deadline)) {
      final result = await _fetchJobSnapshot(
        jobId,
        timeout: const Duration(milliseconds: 1500),
      );
      final raw = result.data;
      if (raw != null) {
        latest = _toSnapshot(raw);
        final status = raw['status'] as String? ?? '';
        final finished =
            status == 'done' || status == 'canceled' || status == 'error';
        // 新服务器会下发 result_ready：checkpoint 行创建很早，必须等最终更新
        // 完成，不能只看 messageId 非空。旧服务器没有该字段，按旧逻辑回退。
        final hasReadyFlag = raw.containsKey('result_ready');
        final stored = hasReadyFlag
            ? (latest.resultReady || latest.content.trim().isEmpty)
            : (latest.messageId != null || latest.content.trim().isEmpty);
        if (finished && (stored || status == 'error')) return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return latest;
  }

  /// 中转模式：POST {server}/v1/chat，服务端边生成边回传，断线可续。
  Future<void> _sendRelay({
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    required bool webSearch,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function() onDone,
    required void Function(String error) onError,
    void Function(String jobId)? onJobStarted,
    void Function(RemoteSnapshot snapshot)? onSnapshot,
    void Function()? onJobLost,
    int? conversationId,
  }) async {
    if (input.isEmpty) {
      onError('消息为空');
      return;
    }
    final base = _trimSlash(_relayBaseUrl ?? '');
    final maxTokensPlan = protocol == ApiProtocol.anthropic
        ? _anthropicMaxTokensPlan()
        : const <int?>[null];
    final client = _client ??= http.Client();

    try {
      for (var i = 0; i < maxTokensPlan.length; i++) {
        final maxTokens = maxTokensPlan[i];
        final payload = protocol == ApiProtocol.anthropic
            ? _anthropicPayload(
                input: input,
                model: model,
                maxTokens: maxTokens,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              )
            : _responsesPayload(
                input: input,
                model: model,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              );
        final request = http.Request('POST', Uri.parse('$base/v1/chat'))
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..headers.addAll(_relayHeaders)
          ..body = jsonEncode({
            'protocol': protocol == ApiProtocol.anthropic
                ? 'anthropic'
                : 'responses',
            'payload': payload,
            'conversation_id': ?conversationId,
          });
        if (protocol == ApiProtocol.anthropic) {
          request.headers['x-api-key'] = apiKey;
          request.headers['anthropic-version'] = '2023-06-01';
        } else {
          request.headers['Authorization'] = 'Bearer $apiKey';
        }

        final res = await client.send(request);
        if (res.statusCode != 200) {
          final bodyText = await res.stream.bytesToString();
          final message = _extractError(bodyText, res.statusCode);
          // 服务端拒绝当前 max_tokens 时降级重试，其余错误直接上报
          if (_isMaxTokensRejected(message) && i + 1 < maxTokensPlan.length) {
            continue;
          }
          onError(message);
          return;
        }
        if (protocol == ApiProtocol.anthropic) {
          _maxTokensPlanCache = <int?>[maxTokens];
        }

        final st = _StreamState();
        final result = await _consumeSse(
          res.stream,
          st,
          protocol: protocol,
          onReasoningDelta: onReasoningDelta,
          onContentDelta: onContentDelta,
          onReasoningTimed: onReasoningTimed,
          onSources: onSources,
          onError: onError,
          onJobEvent: (line) => _handleJobEvent(line, onJobStarted),
        );
        if (_cancelled) {
          _cancelled = false;
          return;
        }
        // 服务端已明确报错（error 事件）时直接结束
        if (result.terminal == _StreamTerminal.failed) return;

        final jobId = _jobId;
        if (jobId == null) {
          // 没有任务号说明服务端不支持续传：退化成直连那套收尾逻辑
          final error = result.error;
          if (error != null) {
            onError('请求失败：$error');
          } else {
            onDone();
          }
          return;
        }
        await _recoverRelayJob(
          jobId: jobId,
          onSnapshot: onSnapshot,
          onDone: onDone,
          onError: onError,
          onJobLost: onJobLost,
        );
        return;
      }
    } catch (e) {
      onError('请求失败：$e');
    }
  }

  /// 逐行消费 SSE：识别任务事件，并按协议分发增量内容。
  Future<_StreamResult> _consumeSse(
    http.ByteStream stream,
    _StreamState st, {
    required ApiProtocol protocol,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function(String error) onError,
    bool Function(String line)? onJobEvent,
  }) {
    final lineBuffer = StringBuffer();
    final completer = Completer<_StreamResult>();
    _relayCompleter = completer;
    var finished = false;
    StreamSubscription<String>? subscription;

    void finish(_StreamResult result) {
      if (finished) return;
      finished = true;
      _idleTimer?.cancel();
      _idleTimer = null;
      if (!completer.isCompleted) completer.complete(result);
    }

    /// 中转模式有 10 秒心跳：超过空闲上限没有任何数据就视为断线。
    void resetIdleTimer() {
      if (!useRelay) return;
      _idleTimer?.cancel();
      _idleTimer = Timer(_relayIdleTimeout, () {
        if (finished) return;
        // 静默断线不会触发 onDone/onError：主动结束这一路流，
        // 让上层转去拉任务快照，把服务端已经生成的内容补齐。
        finish(
          _StreamResult(_StreamTerminal.none, TimeoutException('连接长时间没有数据')),
        );
        subscription?.cancel();
      });
    }

    bool handleLine(String line) {
      if (onJobEvent != null && onJobEvent(line)) return false;
      final terminal = protocol == ApiProtocol.anthropic
          ? _handleAnthropicLine(
              line,
              st,
              onReasoningDelta: onReasoningDelta,
              onContentDelta: onContentDelta,
              onReasoningTimed: onReasoningTimed,
              onSources: onSources,
              onError: onError,
            )
          : _handleLine(
              line,
              st,
              onReasoningDelta: onReasoningDelta,
              onContentDelta: onContentDelta,
              onReasoningTimed: onReasoningTimed,
              onError: onError,
            );
      if (terminal == _StreamTerminal.none) return false;
      finish(_StreamResult(terminal));
      subscription?.cancel();
      return true;
    }

    subscription = stream
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            resetIdleTimer();
            lineBuffer.write(chunk);
            var text = lineBuffer.toString();
            // 逐行解析：每个 chunk 里可能打包多条 SSE 事件
            var idx = text.indexOf('\n');
            while (idx >= 0) {
              final line = text.substring(0, idx).trim();
              text = text.substring(idx + 1);
              if (handleLine(line)) return;
              idx = text.indexOf('\n');
            }
            lineBuffer
              ..clear()
              ..write(text);
          },
          onDone: () {
            // 最后一条 SSE 可能没有以换行结束：连接关闭前把缓冲区里剩的
            // 最后一段内容解析掉，避免“输出完成后最后一段消失”。
            final rest = lineBuffer.toString().trim();
            if (rest.isNotEmpty && !finished) handleLine(rest);
            finish(const _StreamResult(_StreamTerminal.none));
          },
          onError: (Object e) => finish(_StreamResult(_StreamTerminal.none, e)),
        );
    _streamSubscription = subscription;
    resetIdleTimer();
    return completer.future;
  }

  /// 识别服务端下发的任务事件：`data: {"type":"__job","job_id":"..."}`。
  bool _handleJobEvent(String line, void Function(String jobId)? onJobStarted) {
    if (!line.startsWith('data:')) return false;
    final raw = line.substring(5).trim();
    if (!raw.startsWith('{')) return false;
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return false;
    }
    if (decoded is! Map<String, dynamic> || decoded['type'] != '__job') {
      return false;
    }
    final jobId = decoded['job_id'];
    if (jobId is String && jobId.isNotEmpty) {
      _jobId = jobId;
      onJobStarted?.call(jobId);
    }
    return true;
  }

  /// 用服务端任务快照补齐回答：连接断了也不会丢内容。
  ///
  /// 退后台 / 切网时快照接口可能连续失败，但服务端任务往往还在跑。
  /// 这类“暂时连不上”不能当成任务结束：以前失败几次就 onDone/onError，
  /// 会把只剩思考内容的这一轮提前收尾、清掉待恢复任务，回答看起来就“丢了”。
  /// 现在按退避一直重试，只有服务端明确 404（任务已被回收）才交给调用方处理。
  Future<void> _recoverRelayJob({
    required String jobId,
    required void Function() onDone,
    required void Function(String error) onError,
    void Function(RemoteSnapshot snapshot)? onSnapshot,
    void Function()? onJobLost,
  }) async {
    var canceledWaits = 0;
    var retryDelay = const Duration(milliseconds: 800);
    // 退到后台几小时、网络一直连不上时总要有个停点：服务端任务最长保留 30 分钟，
    // 到点后按“任务已回收”处理，由调用方用会话历史兜底。
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    while (!_cancelled && DateTime.now().isBefore(deadline)) {
      final result = await _fetchJobSnapshot(jobId);
      if (result.gone) {
        // 服务端明确说任务不在了：优先让调用方按会话历史补齐
        if (onJobLost != null) {
          onJobLost();
        } else {
          onError('服务器上已找不到该任务，回答未能完整取回');
        }
        return;
      }
      final snapshot = result.data;
      if (snapshot == null) {
        // 网络暂时不可用：继续等，别把仍在生成的任务丢掉
        await Future<void>.delayed(retryDelay);
        final next = retryDelay.inMilliseconds * 2;
        retryDelay = Duration(milliseconds: next > 5000 ? 5000 : next);
        continue;
      }
      retryDelay = const Duration(milliseconds: 800);
      canceledWaits = 0;
      final status = snapshot['status'] as String? ?? '';
      onSnapshot?.call(_toSnapshot(snapshot));
      if (status == 'done') {
        onDone();
        return;
      }
      if (status == 'canceled') {
        // 服务端取消后是“先标记 canceled，再把已生成内容落库”。
        // 这里必须等到落库 id（或确认没有内容可存），否则客户端会再 append
        // 一条，服务端随后也 append 一条，导致服务器/本地记录对不上。
        final snapshotContent = snapshot['content'] as String? ?? '';
        // 新服务器用 result_ready 标识最终内容已写完；旧服务器没有该字段，
        // 仍然按 stored_message_id 判断。
        final hasReadyFlag = snapshot.containsKey('result_ready');
        final stored = hasReadyFlag
            ? (snapshot['result_ready'] == true ||
                  snapshotContent.trim().isEmpty)
            : (snapshot['stored_message_id'] != null ||
                  snapshotContent.trim().isEmpty);
        if (stored) {
          onDone();
          return;
        }
        canceledWaits++;
        // 正常情况下落库是毫秒级；等太久说明服务端存储异常，按原逻辑收尾，
        // 由客户端自己补写这一条，避免恢复流程无限等待。
        if (canceledWaits >= 20) {
          onDone();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 900));
        continue;
      }
      if (status == 'error') {
        onError(snapshot['error'] as String? ?? '请求失败');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    if (_cancelled) return;
    if (onJobLost != null) {
      onJobLost();
    } else {
      onError('与服务器连接中断，未能取回回答');
    }
  }

  /// 服务端任务快照 → [RemoteSnapshot]。
  RemoteSnapshot _toSnapshot(Map<String, dynamic> raw) => RemoteSnapshot(
    reasoning: raw['reasoning'] as String? ?? '',
    content: raw['content'] as String? ?? '',
    sources: MessageCodec.sourcesFromSnapshot(raw['sources']),
    reasoningMs: (raw['reasoning_ms'] as num?)?.toInt() ?? 0,
    messageId: (raw['stored_message_id'] as num?)?.toInt(),
    resultReady: raw['result_ready'] == true,
    audio: MessageCodec.audioFilesFromSnapshot(raw['audio']),
  );

  /// 查询任务快照：区分「网络暂时不可用」与「服务端明确说任务不存在」。
  Future<_JobSnapshotResult> _fetchJobSnapshot(
    String jobId, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final base = _trimSlash(_relayBaseUrl ?? '');
    if (base.isEmpty) return const _JobSnapshotResult.unavailable();
    final client = _client ??= http.Client();
    try {
      final res = await client
          .get(Uri.parse('$base/v1/jobs/$jobId'), headers: _relayHeaders)
          .timeout(timeout);
      if (res.statusCode == 404) return const _JobSnapshotResult.gone();
      if (res.statusCode != 200) return const _JobSnapshotResult.unavailable();
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic>
          ? _JobSnapshotResult.available(decoded)
          : const _JobSnapshotResult.unavailable();
    } catch (_) {
      return const _JobSnapshotResult.unavailable();
    }
  }

  Future<void> _cancelRemoteJob(String jobId) async {
    final base = _trimSlash(_relayBaseUrl ?? '');
    if (base.isEmpty) return;
    try {
      final client = _client ??= http.Client();
      await client
          .post(
            Uri.parse('$base/v1/jobs/$jobId/cancel'),
            headers: _relayHeaders,
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // 取消失败不影响本地状态：任务会在服务端自行跑完并被回收
    }
  }

  static String _trimSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  /// 直连上游：直接请求 {base}/responses 或 {base}/messages。
  Future<void> _sendDirect({
    required List<Map<String, dynamic>> input,
    required String model,
    required ApiProtocol protocol,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required String apiKey,
    bool webSearch = false,
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function() onDone,
    required void Function(String error) onError,
  }) async {
    // 每次发送前重置取消标记，避免上一次取消污染本次请求
    _cancelled = false;
    if (input.isEmpty) {
      onError('消息为空');
      return;
    }

    final client = _client ??= http.Client();
    final uri = Uri.parse(endpointUrl(protocol));
    final st = _StreamState();
    bool errored = false;
    final maxTokensPlan = protocol == ApiProtocol.anthropic
        ? _anthropicMaxTokensPlan()
        : const <int?>[null];

    try {
      for (var i = 0; i < maxTokensPlan.length; i++) {
        final maxTokens = maxTokensPlan[i];
        final payload = protocol == ApiProtocol.anthropic
            ? _anthropicPayload(
                input: input,
                model: model,
                maxTokens: maxTokens,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              )
            : _responsesPayload(
                input: input,
                model: model,
                thinkingEnabled: thinkingEnabled,
                reasoningEffort: reasoningEffort,
                webSearch: webSearch,
              );

        final request = http.Request('POST', uri)
          ..headers['Content-Type'] = 'application/json'
          ..headers['Accept'] = 'text/event-stream'
          ..body = jsonEncode(payload);
        if (protocol == ApiProtocol.anthropic) {
          request.headers['x-api-key'] = apiKey;
          request.headers['anthropic-version'] = '2023-06-01';
        } else {
          request.headers['Authorization'] = 'Bearer $apiKey';
        }

        final res = await client.send(request);
        if (res.statusCode != 200) {
          final bodyText = await res.stream.bytesToString();
          final message = _extractError(bodyText, res.statusCode);
          // 服务端拒绝当前 max_tokens（超出其上限）时降级重试，其余错误直接上报
          if (i + 1 < maxTokensPlan.length && _isMaxTokensRejected(message)) {
            continue;
          }
          onError(message);
          return;
        }
        // 记住本次可行的取值，后续请求直接沿用，不再重复试探
        if (protocol == ApiProtocol.anthropic) {
          _maxTokensPlanCache = <int?>[maxTokens];
        }

        final lineBuffer = StringBuffer();
        final completer = Completer<void>();
        _streamCompleter = completer;
        bool finished = false;
        StreamSubscription<String>? subscription;
        void finish() {
          if (finished) return;
          finished = true;
          if (!completer.isCompleted) completer.complete();
        }

        bool handleLine(String line) {
          final terminal = protocol == ApiProtocol.anthropic
              ? _handleAnthropicLine(
                  line,
                  st,
                  onReasoningDelta: onReasoningDelta,
                  onContentDelta: onContentDelta,
                  onReasoningTimed: onReasoningTimed,
                  onSources: onSources,
                  onError: onError,
                )
              : _handleLine(
                  line,
                  st,
                  onReasoningDelta: onReasoningDelta,
                  onContentDelta: onContentDelta,
                  onReasoningTimed: onReasoningTimed,
                  onError: onError,
                );
          if (terminal == _StreamTerminal.none) return false;
          if (terminal == _StreamTerminal.failed) errored = true;
          finish();
          subscription?.cancel();
          return true;
        }

        subscription = res.stream
            .transform(utf8.decoder)
            .listen(
              (chunk) {
                lineBuffer.write(chunk);
                var text = lineBuffer.toString();
                // 逐行解析：每次只取“第一个换行前”的一行，避免把一个 chunk 里打包的
                // 多条 SSE 事件误当成一整行导致 jsonDecode 失败、增量内容全部丢失。
                var idx = text.indexOf('\n');
                while (idx >= 0) {
                  final line = text.substring(0, idx).trim();
                  text = text.substring(idx + 1);
                  if (handleLine(line)) return;
                  idx = text.indexOf('\n');
                }
                lineBuffer
                  ..clear()
                  ..write(text);
              },
              onDone: () {
                // 上游如果最后一条事件没有尾随换行，也要把剩余内容解析掉。
                final rest = lineBuffer.toString().trim();
                if (rest.isNotEmpty && !finished) handleLine(rest);
                finish();
              },
              onError: (e) {
                errored = true;
                completer.completeError(e);
              },
            );
        _streamSubscription = subscription;
        _streamCompleter = completer;
        await completer.future;
        if (_cancelled) {
          _cancelled = false;
          return;
        }
        if (!errored) onDone();
        return;
      }
    } catch (e) {
      if (!errored) onError('请求失败：$e');
    }
  }

  /// 本次请求要尝试的 max_tokens 序列：首选“不发该字段”（不设上限），
  /// 只有服务端拒绝时才依次补值重试。
  List<int?> _anthropicMaxTokensPlan() =>
      _maxTokensPlanCache ?? <int?>[null, ..._anthropicMaxTokensFallbacks];

  /// 错误是否与服务端对 max_tokens 的要求有关（用于触发补值重试）。
  bool _isMaxTokensRejected(String message) =>
      message.contains('max_tokens') || message.contains('max output');

  /// Responses API 请求体（OpenAI 兼容）。
  Map<String, dynamic> _responsesPayload({
    required List<Map<String, dynamic>> input,
    required String model,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required bool webSearch,
  }) {
    final payload = <String, dynamic>{
      'model': model,
      'input': input,
      'stream': true,
      // 深度思考：Responses API 用 reasoning.effort 控制；关闭时降到最低
      'reasoning': {
        'effort': (thinkingEnabled && reasoningEffort.isNotEmpty)
            ? reasoningEffort
            : 'low',
      },
    };
    // 系统提示词：Responses 端点用 instructions
    final system = systemPrompt?.trim();
    if (system != null && system.isNotEmpty) payload['instructions'] = system;
    final tools = responsesFamilyTools(
      webSearch: webSearch,
      readUrl: webSearch,
      ocr: _ocrTool,
      tts: enableTtsTool,
    );
    if (tools.isNotEmpty) payload['tools'] = tools;
    return payload;
  }

  /// Anthropic Messages 请求体：思考用 thinking.type + output_config.effort，
  /// 联网搜索用官方 `deepseek_web_search` + `deepseek_read_url` 服务端工具。
  Map<String, dynamic> _anthropicPayload({
    required List<Map<String, dynamic>> input,
    required String model,
    required int? maxTokens,
    required bool thinkingEnabled,
    required String reasoningEffort,
    required bool webSearch,
  }) {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'messages': toAnthropicMessages(input),
      'thinking': {'type': thinkingEnabled ? 'enabled' : 'disabled'},
    };
    // 不设回答上限：默认不发 max_tokens，只有服务端强制要求时才带上
    if (maxTokens != null) payload['max_tokens'] = maxTokens;
    // 系统提示词：Anthropic 端点用顶层 system 字段
    final system = systemPrompt?.trim();
    if (system != null && system.isNotEmpty) payload['system'] = system;
    if (thinkingEnabled && reasoningEffort.isNotEmpty) {
      payload['output_config'] = {'effort': reasoningEffort};
    }
    final tools = anthropicFamilyTools(
      webSearch: webSearch,
      readUrl: webSearch,
      // 官方限制：联网工具不能与其他服务端工具混用；函数工具为稳妥起见
      // 在开启联网时不声明。
      ocr: _ocrTool && !webSearch,
      tts: enableTtsTool && !webSearch,
    );
    if (tools.isNotEmpty) payload['tools'] = tools;
    return payload;
  }

  /// Anthropic Messages 的 SSE 事件解析。
  _StreamTerminal _handleAnthropicLine(
    String line,
    _StreamState st, {
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    void Function(List<ChatSource> sources)? onSources,
    required void Function(String error) onError,
  }) {
    if (!line.startsWith('data:')) return _StreamTerminal.none;
    final raw = line.substring(5).trim();
    if (raw.isEmpty || raw == '[DONE]') return _StreamTerminal.none;

    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _StreamTerminal.none;
    }
    if (decoded is! Map<String, dynamic>) return _StreamTerminal.none;

    final type = decoded['type'] as String?;
    if (type == 'error') {
      final err = decoded['error'];
      final msg = (err is Map && err['message'] is String)
          ? err['message'] as String
          : 'API 请求失败';
      onError(msg);
      return _StreamTerminal.failed;
    }
    if (type == 'message_stop') return _StreamTerminal.done;

    if (type == 'content_block_start') {
      final block = decoded['content_block'];
      if (block is Map<String, dynamic>) {
        final blockType = block['type'];
        if (blockType == 'thinking') {
          _emitReasoning(
            st,
            block['thinking'] as String? ?? '',
            onReasoningDelta,
          );
        } else if (blockType == 'text') {
          _emitContent(
            st,
            block['text'] as String? ?? '',
            onContentDelta: onContentDelta,
            onReasoningTimed: onReasoningTimed,
          );
        } else if (blockType == 'web_search_tool_result') {
          final sources = _parseSearchResults(block['content']);
          if (sources.isNotEmpty) onSources?.call(sources);
        } else if (blockType == 'tool_use') {
          // 模型要求客户端执行 search / fetch
          final call = _ToolCall(
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
          );
          final initial = block['input'];
          if (initial is Map && initial.isNotEmpty) {
            call.arguments = jsonEncode(initial);
          }
          st.toolCalls.add(call);
          final index = decoded['index'];
          if (index is int) st.anthropicToolsByIndex[index] = call;
        }
      }
      return _StreamTerminal.none;
    }

    if (type == 'content_block_delta') {
      final delta = decoded['delta'];
      if (delta is Map<String, dynamic>) {
        final deltaType = delta['type'];
        if (deltaType == 'thinking_delta') {
          _emitReasoning(
            st,
            delta['thinking'] as String? ?? '',
            onReasoningDelta,
          );
        } else if (deltaType == 'text_delta') {
          _emitContent(
            st,
            delta['text'] as String? ?? '',
            onContentDelta: onContentDelta,
            onReasoningTimed: onReasoningTimed,
          );
        } else if (deltaType == 'input_json_delta') {
          // 工具参数是分片到达的，按 block index 拼起来再解析
          final index = decoded['index'];
          final call = index is int ? st.anthropicToolsByIndex[index] : null;
          final partial = delta['partial_json'];
          if (call != null && partial is String) call.arguments += partial;
        }
      }
      return _StreamTerminal.none;
    }

    return _StreamTerminal.none;
  }

  /// 从 web_search_tool_result 的 content 数组提取来源（标题 + 链接）。
  List<ChatSource> _parseSearchResults(dynamic content) {
    if (content is! List) return const [];
    final sources = <ChatSource>[];
    for (final item in content) {
      if (item is! Map) continue;
      final url = item['url'];
      if (url is! String || url.isEmpty) continue;
      final title = item['title'];
      sources.add(
        ChatSource(
          title: (title is String && title.isNotEmpty) ? title : url,
          url: url,
        ),
      );
    }
    return sources;
  }

  void _emitReasoning(
    _StreamState st,
    String delta,
    void Function(String delta) onReasoningDelta,
  ) {
    if (delta.isEmpty) return;
    if (!st.reasoningGot) {
      st.reasoningGot = true;
      st.reasoningStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    st.reasoning += delta;
    onReasoningDelta(delta);
  }

  void _emitContent(
    _StreamState st,
    String delta, {
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
  }) {
    if (delta.isEmpty) return;
    _maybeEmitTiming(st, onReasoningTimed: onReasoningTimed);
    st.contentGot = true;
    st.content += delta;
    onContentDelta(delta);
  }

  _StreamTerminal _handleLine(
    String line,
    _StreamState st, {
    required void Function(String delta) onReasoningDelta,
    required void Function(String delta) onContentDelta,
    required void Function(int ms) onReasoningTimed,
    required void Function(String error) onError,
  }) {
    if (!line.startsWith('data:')) return _StreamTerminal.none;
    final raw = line.substring(5).trim();
    if (raw.isEmpty) return _StreamTerminal.none;
    if (raw == '[DONE]') return _StreamTerminal.done;

    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _StreamTerminal.none;
    }
    if (decoded is! Map<String, dynamic>) return _StreamTerminal.none;

    final type = decoded['type'] as String?;
    if (type == 'response.failed') {
      final msg = (decoded['error']?['message'] as String?) ?? 'API 请求失败';
      onError(msg);
      return _StreamTerminal.failed;
    }
    if (decoded.containsKey('error')) {
      onError((decoded['error']?['message'] as String?) ?? 'API 错误');
      return _StreamTerminal.failed;
    }

    if (type == 'response.reasoning_text.delta') {
      final delta = decoded['delta'] as String? ?? '';
      if (delta.isNotEmpty) {
        if (!st.reasoningGot) {
          st.reasoningGot = true;
          st.reasoningStartedAtMs = DateTime.now().millisecondsSinceEpoch;
        }
        st.reasoning += delta;
        onReasoningDelta(delta);
      }
      return _StreamTerminal.none;
    }
    // .done 仅在未收到任何 delta 时兜底，避免重复
    if (type == 'response.reasoning_text.done') {
      if (!st.reasoningGot) {
        final fallback =
            (decoded['delta'] as String?) ?? (decoded['text'] as String?) ?? '';
        if (fallback.isNotEmpty) {
          st.reasoning += fallback;
          onReasoningDelta(fallback);
        }
      }
      return _StreamTerminal.none;
    }
    if (type == 'response.output_text.delta') {
      final delta = decoded['delta'] as String? ?? '';
      if (delta.isNotEmpty) {
        _maybeEmitTiming(st, onReasoningTimed: onReasoningTimed);
        st.contentGot = true;
        st.content += delta;
        onContentDelta(delta);
      }
      return _StreamTerminal.none;
    }
    if (type == 'response.output_text.done') {
      // 仅当没有任何 content delta 时用 .done 兜底，避免重复
      if (!st.contentGot) {
        final fallback =
            (decoded['delta'] as String?) ?? (decoded['text'] as String?) ?? '';
        if (fallback.isNotEmpty) {
          _maybeEmitTiming(st, onReasoningTimed: onReasoningTimed);
          st.content += fallback;
          onContentDelta(fallback);
        }
      }
      return _StreamTerminal.none;
    }
    // 工具调用：output_item.added 创建，arguments.delta 拼接，done/completed 兜底。
    if (type == 'response.output_item.added') {
      final item = decoded['item'];
      if (item is Map && item['type'] == 'function_call') {
        final call = _ToolCall(
          id: (item['call_id'] as String?) ?? (item['id'] as String?) ?? '',
          name: item['name'] as String? ?? '',
        );
        final args = item['arguments'];
        if (args is String) call.arguments = args;
        st.toolCalls.add(call);
        final itemId = item['id'];
        if (itemId is String) st.responseToolsById[itemId] = call;
      }
      return _StreamTerminal.none;
    }
    if (type == 'response.function_call_arguments.delta') {
      final itemId = decoded['item_id'];
      final call = itemId is String ? st.responseToolsById[itemId] : null;
      final delta = decoded['delta'];
      if (call != null && delta is String) call.arguments += delta;
      return _StreamTerminal.none;
    }
    if (type == 'response.function_call_arguments.done') {
      final itemId = decoded['item_id'];
      final call = itemId is String ? st.responseToolsById[itemId] : null;
      final args = decoded['arguments'];
      if (call != null && args is String) call.arguments = args;
      return _StreamTerminal.none;
    }
    if (type == 'response.output_item.done') {
      final item = decoded['item'];
      if (item is Map && item['type'] == 'function_call') {
        final itemId = item['id'];
        final call = itemId is String ? st.responseToolsById[itemId] : null;
        final args = item['arguments'];
        if (call != null && args is String) call.arguments = args;
      }
      return _StreamTerminal.none;
    }
    // response.completed：明确终止事件，立即结束请求，不必等 HTTP 连接关闭。
    if (type == 'response.completed') {
      _collectResponseToolCalls(decoded, st);
      return _StreamTerminal.done;
    }
    // 其余事件（created / in_progress / web_search_call.*）忽略
    return _StreamTerminal.none;
  }

  /// response.completed 里带完整 output，补齐流式事件里可能漏掉的函数调用。
  void _collectResponseToolCalls(dynamic decoded, _StreamState st) {
    final response = decoded is Map ? decoded['response'] : null;
    final output = response is Map ? response['output'] : null;
    if (output is! List) return;
    for (final item in output) {
      if (item is! Map || item['type'] != 'function_call') continue;
      final id = (item['call_id'] as String?) ?? (item['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      _ToolCall? call;
      for (final existing in st.toolCalls) {
        if (existing.id == id) {
          call = existing;
          break;
        }
      }
      if (call == null) {
        call = _ToolCall(id: id, name: item['name'] as String? ?? '');
        st.toolCalls.add(call);
      }
      final args = item['arguments'];
      if (args is String && args.isNotEmpty) call.arguments = args;
    }
  }

  void _maybeEmitTiming(
    _StreamState st, {
    required void Function(int ms) onReasoningTimed,
  }) {
    if (st.contentStartedAtMs != null) return;
    st.contentStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    final started = st.reasoningStartedAtMs;
    onReasoningTimed(started == null ? 0 : st.contentStartedAtMs! - started);
  }

  String _extractError(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      final msg = decoded['error']?['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    } catch (_) {}
    return '请求失败 (HTTP $status)';
  }
}
