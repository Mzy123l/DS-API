import 'dart:convert';

import '../models.dart';

/// 消息 / 会话 / 分页的编解码单一定义（wire JSON ↔ DTO ↔ SQLite 行）。
///
/// 客户端以前把同一份 DTO 手工写了三遍（`chat_repository`、`storage`、
/// `deepseek_client`），字段名、默认值、空值兜底各写一套。现在只留这一处：
///
/// - wire：中转服务 HTTP JSON，权威定义见 `server/app/store.py` 的
///   `_message_row` 与 `append_message`，以及 `main.py` 的
///   `CONVERSATION_MESSAGES` 分支；
/// - row：本地 SQLite（列名与 wire 字段名相同，但类型不同，
///   见 [messagesTableSql] / [conversationsTableSql]）。
///
/// 改动这里的默认值等于改客户端对外行为，除非同时核对服务端契约。

/// 本地缓存单条消息允许写库的图片 JSON 上限（16MB）。
///
/// Android 的 SQLite 查询结果要放进 CursorWindow（默认约 2MB）：一条消息把
/// 几 MB 的 base64 图片存在同一行里，读整页时会抛
/// `Row too big to fit into CursorWindow`，表现为「某个历史会话怎么点都进不去」。
///
/// 超过上限的图片就不写本地缓存：内存里的消息不受影响，
/// 联网时图片照常从服务器取，重新发送也不会丢内容。
const int maxCachedImageJsonBytes = 16 * 1024 * 1024;

/// 图片列写库前的编码：超过 [maxCachedImageJsonBytes] 时只存空数组。
String encodeCachedImages(List<String> images) {
  if (images.isEmpty) return '[]';
  final encoded = jsonEncode(images);
  if (encoded.length <= maxCachedImageJsonBytes) return encoded;
  return '[]';
}

/// 消息表建表语句：列名必须与 [MessageCodec.toRow] / [MessageCodec.fromRow] 一致。
///
/// 与 wire 的差别都在类型上：`sources` / `images` / `files` / `audio` 在 wire
/// 是 JSON 数组、在库里是 JSON 字符串；`pending` 在 wire 是 bool、在服务端库里
/// 是 0/1（客户端库不存该列）；`reasoning_ms` / `ts` 两处都是整数。
const String messagesTableSql = '''
      CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY,
        conv_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        reasoning TEXT NOT NULL DEFAULT '',
        reasoning_ms INTEGER NOT NULL DEFAULT 0,
        sources TEXT NOT NULL DEFAULT '[]',
        images TEXT NOT NULL DEFAULT '[]',
        files TEXT NOT NULL DEFAULT '[]',
        audio TEXT NOT NULL DEFAULT '[]',
        ts INTEGER NOT NULL)
    ''';

/// 会话表建表语句：列名必须与 [ConversationCodec.toRow] / `fromRow` 一致。
///
/// 注意 `answer_bubble` 不在本地库里（纯本地模式存在 SharedPreferences），
/// 所以本地缓存读出来的会话该字段恒为 false。
const String conversationsTableSql = '''
      CREATE TABLE IF NOT EXISTS conversations(
        id INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        model TEXT NOT NULL,
        system_prompt TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        preview TEXT NOT NULL DEFAULT '')
    ''';

/// 单条消息与 wire / SQLite 行之间的互转。
abstract final class MessageCodec {
  /// DTO → 中转服务请求体（`POST /v1/conversations/{id}/messages`）。
  ///
  /// 不发送 `id` / `conversation_id`（由路径决定），也不发送 `pending`：
  /// 服务端 `append_message` 里 `pending` 默认 False，客户端从不主动写它。
  static Map<String, dynamic> toWire(ChatMessage msg) => {
    'role': msg.role == MessageRole.user ? 'user' : 'assistant',
    'content': msg.content,
    'reasoning': msg.reasoning,
    'reasoning_ms': msg.reasoningMs,
    'sources': [
      for (final source in msg.sources)
        {'title': source.title, 'url': source.url},
    ],
    'images': msg.imageDataUrls,
    'files': [for (final file in msg.files) file.toJson()],
    'audio': msg.audioFiles,
    'ts': msg.effectiveTime.millisecondsSinceEpoch,
  };

  /// wire 里的一条消息 → DTO（字段缺失时的默认值与旧实现逐项一致）。
  ///
  /// 与 row 版本的差别是这里的字段是 JSON 原生类型（数组而非字符串），
  /// 且行为更「严格」：`sources` 不是数组时抛类型错误，和旧实现一致。
  static ChatMessage fromWire(Map<dynamic, dynamic> item) => ChatMessage(
    id: (item['id'] as num?)?.toInt(),
    role: item['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
    content: item['content'] as String? ?? '',
    reasoning: item['reasoning'] as String? ?? '',
    reasoningMs: (item['reasoning_ms'] as num?)?.toInt() ?? 0,
    sources: _sources(item['sources'] as List? ?? const []),
    imageDataUrls: _strings(item['images'] as List? ?? const []),
    files: _files(item['files'] as List? ?? const []),
    audioFiles: _strings(item['audio'] as List? ?? const []),
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (item['ts'] as num?)?.toInt() ?? 0,
    ),
  );

  /// wire 里的 `items` 数组 → DTO 列表（非数组返回空，非 Map 的元素跳过）。
  static List<ChatMessage> listFromWire(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) fromWire(item),
    ];
  }

  /// DTO → messages 表一行。
  ///
  /// `id` 为 null 时不写该列（交给 SQLite 自增）；`images` 走
  /// [encodeCachedImages]，超大图片降级成空数组。
  static Map<String, Object?> toRow(int convId, ChatMessage msg) => {
    if (msg.id != null) 'id': msg.id,
    'conv_id': convId,
    'role': msg.role == MessageRole.user ? 'user' : 'assistant',
    'content': msg.content,
    'reasoning': msg.reasoning,
    'reasoning_ms': msg.reasoningMs,
    'sources': jsonEncode([
      for (final source in msg.sources)
        {'title': source.title, 'url': source.url},
    ]),
    'images': encodeCachedImages(msg.imageDataUrls),
    'files': jsonEncode([for (final file in msg.files) file.toJson()]),
    'audio': jsonEncode(msg.audioFiles),
    'ts': msg.effectiveTime.millisecondsSinceEpoch,
  };

  /// messages 表一行 → DTO。
  ///
  /// 与 wire 版本刻意保留的差别：`content` / `ts` 直接强转（库里非空），
  /// JSON 列解析失败一律退回空列表（历史坏数据不能让会话打不开）。
  static ChatMessage fromRow(Map<String, Object?> row) => ChatMessage(
    id: row['id'] as int?,
    role: row['role'] == 'user' ? MessageRole.user : MessageRole.assistant,
    content: row['content'] as String,
    reasoning: row['reasoning'] as String? ?? '',
    reasoningMs: row['reasoning_ms'] as int? ?? 0,
    sources: _sources(_jsonArray(row['sources'])),
    imageDataUrls: _strings(_jsonArray(row['images'])),
    files: _files(_jsonArray(row['files'])),
    audioFiles: _strings(_jsonArray(row['audio'])),
    timestamp: DateTime.fromMillisecondsSinceEpoch(row['ts'] as int),
  );

  /// 任务快照（`GET /v1/jobs/{id}`）里的 `sources`。
  ///
  /// 与历史消息的解析有两处刻意不同（旧实现就是这样，别合并）：
  /// 空 url 直接丢弃；标题为空串时回退到 url。
  static List<ChatSource> sourcesFromSnapshot(Object? raw) {
    if (raw is! List) return const [];
    final sources = <ChatSource>[];
    for (final item in raw) {
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

  /// 任务快照里的 `audio`：只有 id 与文件名（客户端按 id 走 `/v1/audio/{id}`）。
  ///
  /// 注意服务端这里给的是 `bytes`，不是 [ChatFile.toJson] 的 `size`；
  /// 缺省文件名也与 [ChatFile.fromJson] 的 `document` 不同。
  static List<ChatFile> audioFilesFromSnapshot(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map && item['id'] is String)
          ChatFile(
            id: item['id'] as String,
            name: (item['name'] as String?) ?? 'speech.wav',
            sizeBytes: (item['bytes'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// SQLite 的 JSON 列 → 数组；空串 / 解析失败 / 不是数组都返回空列表。
  static List<Object?> _jsonArray(Object? column) {
    if (column is! String || column.isEmpty) return const [];
    try {
      final decoded = jsonDecode(column);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  static List<ChatSource> _sources(List<dynamic> raw) => [
    for (final source in raw)
      if (source is Map && source['url'] is String)
        ChatSource(
          title: (source['title'] as String?) ?? source['url'] as String,
          url: source['url'] as String,
        ),
  ];

  static List<String> _strings(List<dynamic> raw) => [
    for (final item in raw)
      if (item is String && item.isNotEmpty) item,
  ];

  static List<ChatFile> _files(List<dynamic> raw) => [
    for (final item in raw) ?ChatFile.fromJson(item),
  ];
}

/// 会话与 wire / SQLite 行之间的互转。
abstract final class ConversationCodec {
  /// wire 里的一条会话 → DTO（默认值与旧实现逐项一致）。
  static Conversation fromWire(Map<dynamic, dynamic> item) => Conversation(
    id: (item['id'] as num?)?.toInt() ?? 0,
    title: item['title'] as String? ?? '新对话',
    model: item['model'] as String? ?? '',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (item['updated_at'] as num?)?.toInt() ?? 0,
    ),
    preview: item['preview'] as String? ?? '',
    systemPrompt: item['system_prompt'] as String? ?? '',
    answerBubble: item['answer_bubble'] == true || item['answer_bubble'] == 1,
  );

  /// wire 里的 `items` 数组 → DTO 列表（非数组返回空，非 Map 的元素跳过）。
  static List<Conversation> listFromWire(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) fromWire(item),
    ];
  }

  /// DTO → conversations 表一行。
  ///
  /// `created_at` 与 `updated_at` 都写 [Conversation.updatedAt]（旧实现如此）；
  /// [systemPrompt] 用于覆盖本机保留的提示词（见 `AppDatabase.cacheConversations`）。
  /// `answer_bubble` 不落库，本地缓存读回时恒为 false。
  static Map<String, Object?> toRow(
    Conversation conv, {
    String? systemPrompt,
  }) => {
    'id': conv.id,
    'title': conv.title,
    'model': conv.model,
    'system_prompt': systemPrompt ?? conv.systemPrompt,
    'created_at': conv.updatedAt.millisecondsSinceEpoch,
    'updated_at': conv.updatedAt.millisecondsSinceEpoch,
    'preview': conv.preview,
  };

  /// conversations 表一行 → DTO（`id` / `title` / `model` 在库里非空）。
  static Conversation fromRow(Map<String, Object?> row) => Conversation(
    id: row['id'] as int,
    title: row['title'] as String,
    model: row['model'] as String,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    preview: row['preview'] as String? ?? '',
    systemPrompt: row['system_prompt'] as String? ?? '',
  );
}

/// 分页元数据（会话列表与消息页共用同一组字段名）。
///
/// 游标本身的拼装在调用方（`before_id` / `before_updated_at` 是查询串参数）。
abstract final class PageCodec {
  /// `has_more`：只有明确为 true 才算还有下一页。
  static bool hasMore(Map<String, dynamic> data) => data['has_more'] == true;

  /// `oldest_id`：本页最旧一条的 id，没有时返回 null。
  static int? oldestId(Map<String, dynamic> data) =>
      (data['oldest_id'] as num?)?.toInt();
}
