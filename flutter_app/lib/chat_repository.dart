import 'dart:convert';

import 'package:http/http.dart' as http;

import 'data/message_codec.dart';
import 'models.dart';
import 'storage.dart';

/// 会话列表分页大小（与官方客户端一样按页取，避免一次性拉全量）。
const int conversationPageSize = 30;

/// 消息分页大小：打开会话先取最近这些条，往上翻再继续取。
const int messagePageSize = 30;

/// 会话存储抽象：本地 SQLite 与服务器存储两种实现。
///
/// AppState 只依赖这个接口，服务器可用/不可用（开关关闭）时切换实现即可。
abstract class ChatRepository {
  /// 会话列表是否还有更早的页
  bool get hasMoreConversations;

  /// 指定会话是否还有更早的消息（分页游标按会话隔离）
  bool hasOlderMessagesFor(int convId);

  /// 重新拉取第一页会话列表
  Future<List<Conversation>> refreshConversations();

  /// 拉取服务器上的**全部**会话（逐页拉完再一次性替换本地缓存）。
  ///
  /// 启动时用：本机缺失的会话会在后台补齐；任意一页失败都不会破坏现有缓存。
  Future<List<Conversation>> syncAllConversations();

  /// 继续加载更早的会话（历史抽屉滑到底部时触发）
  Future<List<Conversation>> loadMoreConversations();

  /// 全部会话 id（用于"全选"，不只是已加载的那几页）
  Future<List<int>> allConversationIds();

  Future<int> createConversation(
    String title,
    String model, {
    String systemPrompt = '',
    bool answerBubble = false,
  });

  Future<void> renameConversation(int id, String title);

  /// 保存某个会话的系统提示词（空字符串表示回到默认值）。
  Future<void> updateSystemPrompt(int id, String prompt);

  /// 保存某个会话的「回答气泡」开关。
  Future<void> setAnswerBubble(int id, bool value);

  Future<void> deleteConversation(int id);

  /// 打开会话：取最近 [limit] 条消息（升序返回）
  Future<List<ChatMessage>> loadLatestMessages(int convId, {int? limit});

  /// 继续加载更早的消息（聊天页往上翻时触发）
  Future<List<ChatMessage>> loadOlderMessages(int convId);

  /// 一次性拉完该会话在当前窗口之前的全部消息（升序返回）。
  ///
  /// 发送新消息、编辑或重新生成前调用，保证请求上下文不会漏掉早前轮次。
  Future<List<ChatMessage>> loadAllOlderMessages(int convId);

  /// 追加一条消息，返回带服务器 id 的消息
  Future<ChatMessage> appendMessage(int convId, ChatMessage msg);

  /// 只写本地缓存（服务端已自行落库，例如中转模式下生成的回答）
  Future<void> cacheMessage(int convId, ChatMessage msg);

  /// 只保留前 [keep] 条消息（编辑 / 重新生成）
  Future<void> truncateMessages(int convId, int keep);

  /// 删除 id >= [beforeId] 的消息（编辑 / 重新生成，按消息 id 截断）。
  ///
  /// [keepFallback] 是同一位置在完整历史里的下标，供旧版服务器识别
  /// `keep` 参数；新版服务器优先使用 `before_id`。两者同时发送时，
  /// 新旧服务器的截断结果一致，App 可以先于服务器升级。
  Future<void> truncateMessagesBefore(
    int convId,
    int beforeId, {
    int? keepFallback,
  });

  Future<List<MessageHit>> searchMessages(String query);
}

/// 存储层错误（网络 / 服务端返回非 200）。
class ChatRepositoryException implements Exception {
  const ChatRepositoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 纯本地实现：完全沿用旧版 SQLite 行为（不分页，一次给全量）。
class LocalChatRepository implements ChatRepository {
  LocalChatRepository(this.db);

  final AppDatabase db;

  @override
  bool get hasMoreConversations => false;

  @override
  bool hasOlderMessagesFor(int convId) => false;

  @override
  Future<List<Conversation>> refreshConversations() => db.listConversations();

  @override
  Future<List<Conversation>> syncAllConversations() => db.listConversations();

  @override
  Future<List<Conversation>> loadMoreConversations() => db.listConversations();

  @override
  Future<List<int>> allConversationIds() async =>
      [for (final conv in await db.listConversations()) conv.id];

  @override
  Future<int> createConversation(
    String title,
    String model, {
    String systemPrompt = '',
    bool answerBubble = false,
  }) => db.createConversation(title, model, systemPrompt: systemPrompt);

  @override
  Future<void> renameConversation(int id, String title) =>
      db.renameConversation(id, title);

  @override
  Future<void> updateSystemPrompt(int id, String prompt) =>
      db.setSystemPrompt(id, prompt);

  @override
  Future<void> setAnswerBubble(int id, bool value) async {
    // 纯本地模式没有服务端，开关存在本机设置里
    await SettingsStore().setAnswerBubbleFor(id, value);
  }

  @override
  Future<void> deleteConversation(int id) => db.deleteConversation(id);

  @override
  Future<List<ChatMessage>> loadLatestMessages(int convId, {int? limit}) =>
      db.loadMessages(convId);

  @override
  Future<List<ChatMessage>> loadOlderMessages(int convId) async => const [];

  @override
  Future<List<ChatMessage>> loadAllOlderMessages(int convId) async => const [];

  @override
  Future<ChatMessage> appendMessage(int convId, ChatMessage msg) async {
    final id = await db.saveMessage(convId, msg);
    return msg.id == null ? msg.copyWith(id: id) : msg;
  }

  @override
  Future<void> cacheMessage(int convId, ChatMessage msg) async {
    await db.saveMessage(convId, msg);
  }

  @override
  Future<void> truncateMessages(int convId, int keep) =>
      db.truncateMessages(convId, keep);

  @override
  Future<void> truncateMessagesBefore(
    int convId,
    int beforeId, {
    int? keepFallback,
  }) => db.truncateMessagesBefore(convId, beforeId);

  @override
  Future<List<MessageHit>> searchMessages(String query) =>
      db.searchMessages(query);
}

/// 服务器存储：HTTP + 本地缓存 + 游标分页（对应服务端 /v1/conversations 接口）。
class ServerChatRepository implements ChatRepository {
  ServerChatRepository({
    required this.baseUrl,
    required this.cache,
    this.token = '',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final AppDatabase cache;

  /// 服务器访问口令（服务端 RELAY_TOKEN 非空时必填）
  final String token;
  final http.Client _client;

  bool _hasMoreConversations = false;
  int? _convCursorUpdatedAt;
  int? _convCursorId;

  /// 每个会话各自的分页状态：cursor 不再被别的会话的加载覆盖。
  final Map<int, _MessagePage> _messagePages = {};

  @override
  bool get hasMoreConversations => _hasMoreConversations;

  @override
  bool hasOlderMessagesFor(int convId) =>
      _messagePages[convId]?.hasMore ?? false;

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Map<String, String> get _headers => {
    if (token.isNotEmpty) 'x-relay-token': token,
  };

  // ------------------------------------------------------------------ 会话

  @override
  Future<List<Conversation>> refreshConversations() async {
    final data = await _get('/v1/conversations?limit=$conversationPageSize');
    final items = _parseConversations(data['items']);
    _hasMoreConversations = PageCodec.hasMore(data);
    _setConversationCursor(items);
    // 合并而不是清空：首屏刷新不能把已经缓存/加载过的更早会话删掉，
    // 否则断网重启后旧会话就“消失”了。全量替换只在 syncAllConversations 做。
    await cache.cacheConversations(items);
    return items;
  }

  @override
  Future<List<Conversation>> syncAllConversations() async {
    // 先把所有页拉完再一次性替换缓存：中途失败不会破坏现有本地历史。
    const pageSize = 200;
    const maxPages = 1000; // 防御异常服务端：最多 20 万条会话
    final all = <Conversation>[];
    int? beforeUpdatedAt;
    int? beforeId;
    for (var page = 0; page < maxPages; page++) {
      final path = beforeUpdatedAt == null
          ? '/v1/conversations?limit=$pageSize'
          : '/v1/conversations?limit=$pageSize'
                '&before_updated_at=$beforeUpdatedAt&before_id=$beforeId';
      final data = await _get(path);
      final items = _parseConversations(data['items']);
      all.addAll(items);
      if (!PageCodec.hasMore(data) || items.isEmpty) break;
      final last = items.last;
      beforeUpdatedAt = last.updatedAt.millisecondsSinceEpoch;
      beforeId = last.id;
    }
    _hasMoreConversations = false;
    _convCursorUpdatedAt = null;
    _convCursorId = null;
    await cache.cacheConversations(all, replace: true);
    return all;
  }

  @override
  Future<List<Conversation>> loadMoreConversations() async {
    if (!_hasMoreConversations ||
        _convCursorUpdatedAt == null ||
        _convCursorId == null) {
      return cache.listConversations();
    }
    final data = await _get(
      '/v1/conversations?limit=$conversationPageSize'
      '&before_updated_at=$_convCursorUpdatedAt&before_id=$_convCursorId',
    );
    final items = _parseConversations(data['items']);
    _hasMoreConversations = PageCodec.hasMore(data);
    _setConversationCursor(items);
    await cache.cacheConversations(items);
    return cache.listConversations();
  }

  void _setConversationCursor(List<Conversation> items) {
    if (items.isEmpty) return;
    final last = items.last;
    _convCursorUpdatedAt = last.updatedAt.millisecondsSinceEpoch;
    _convCursorId = last.id;
  }

  @override
  Future<List<int>> allConversationIds() async {
    final ids = <int>[];
    int? beforeUpdatedAt;
    int? beforeId;
    while (true) {
      final path = beforeUpdatedAt == null
          ? '/v1/conversations?limit=200'
          : '/v1/conversations?limit=200'
                '&before_updated_at=$beforeUpdatedAt&before_id=$beforeId';
      final data = await _get(path);
      final items = _parseConversations(data['items']);
      ids.addAll([for (final conv in items) conv.id]);
      if (!PageCodec.hasMore(data) || items.isEmpty) break;
      beforeUpdatedAt = items.last.updatedAt.millisecondsSinceEpoch;
      beforeId = items.last.id;
    }
    return ids;
  }

  @override
  Future<int> createConversation(
    String title,
    String model, {
    String systemPrompt = '',
    bool answerBubble = false,
  }) async {
    final data = await _post('/v1/conversations', {
      'title': title,
      'model': model,
      'system_prompt': systemPrompt,
      'answer_bubble': answerBubble,
    });
    final id = (data['id'] as num?)?.toInt() ?? 0;
    await cache.cacheConversations([
      Conversation(
        id: id,
        title: title,
        model: model,
        updatedAt: DateTime.now(),
        systemPrompt: systemPrompt,
        answerBubble: answerBubble,
      ),
    ]);
    return id;
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    await _patch('/v1/conversations/$id', {'title': title});
    await cache.renameConversation(id, title);
  }

  @override
  Future<void> updateSystemPrompt(int id, String prompt) async {
    // 先写本地：老服务端还不支持这个字段时，至少本机不会丢
    await cache.setSystemPrompt(id, prompt);
    await _patch('/v1/conversations/$id', {'system_prompt': prompt});
  }

  @override
  Future<void> setAnswerBubble(int id, bool value) async {
    await _patch('/v1/conversations/$id', {'answer_bubble': value});
  }

  @override
  Future<void> deleteConversation(int id) async {
    await _delete('/v1/conversations/$id');
    await cache.deleteConversation(id);
  }

  // ------------------------------------------------------------------ 消息

  @override
  Future<List<ChatMessage>> loadLatestMessages(int convId, {int? limit}) async {
    final size = limit ?? messagePageSize;
    try {
      final data = await _get(
        '/v1/conversations/$convId/messages?limit=$size',
      );
      final items = _parseMessages(data['items']);
      _messagePages[convId] = _MessagePage(
        oldestId: PageCodec.oldestId(data),
        hasMore: PageCodec.hasMore(data),
      );
      await cache.cacheMessages(convId, items, replace: true);
      return items;
    } on ChatRepositoryException {
      // 服务器不可用：退回本地缓存，至少还能看已加载过的内容
      // 同时清掉分页状态，下一次补齐历史会重新建立游标。
      _messagePages.remove(convId);
      return cache.loadMessages(convId);
    }
  }

  @override
  Future<List<ChatMessage>> loadOlderMessages(int convId) async {
    final page = _messagePages[convId];
    if (page == null || !page.hasMore || page.oldestId == null) {
      return const [];
    }
    final data = await _get(
      '/v1/conversations/$convId/messages?limit=$messagePageSize'
      '&before_id=${page.oldestId}',
    );
    final items = _parseMessages(data['items']);
    _messagePages[convId] = _MessagePage(
      oldestId: PageCodec.oldestId(data) ?? page.oldestId,
      hasMore: PageCodec.hasMore(data),
    );
    await cache.cacheMessages(convId, items);
    return items;
  }

  @override
  Future<List<ChatMessage>> loadAllOlderMessages(int convId) async {
    // 还没有本会话分页状态时先取一次最新页，建立游标。
    if (!_messagePages.containsKey(convId)) {
      await loadLatestMessages(convId);
      if (!_messagePages.containsKey(convId)) {
        throw const ChatRepositoryException('服务器不可用，无法补齐更早历史');
      }
    }
    final pages = <List<ChatMessage>>[];
    while (hasOlderMessagesFor(convId)) {
      final beforeId = _messagePages[convId]?.oldestId;
      final older = await loadOlderMessages(convId);
      if (older.isEmpty) break;
      pages.insert(0, older);
      if (_messagePages[convId]?.oldestId == beforeId) break;
    }
    return [for (final page in pages) ...page];
  }

  @override
  Future<ChatMessage> appendMessage(int convId, ChatMessage msg) async {
    final data = await _post(
      '/v1/conversations/$convId/messages',
      MessageCodec.toWire(msg),
    );
    final saved = msg.copyWith(id: (data['id'] as num?)?.toInt());
    await cache.saveMessage(convId, saved);
    return saved;
  }

  /// 只写本地缓存（服务端已自行落库，例如中转模式下的回答）。
  @override
  Future<void> cacheMessage(int convId, ChatMessage msg) =>
      cache.saveMessage(convId, msg).then((_) {});

  /// 批量追加（迁移旧数据用，避免一条条发请求）。
  Future<void> appendMessagesChunk(int convId, List<ChatMessage> msgs) async {
    if (msgs.isEmpty) return;
    await _post('/v1/conversations/$convId/messages/bulk', {
      'messages': [for (final msg in msgs) MessageCodec.toWire(msg)],
    });
  }

  @override
  Future<void> truncateMessages(int convId, int keep) async {
    await _post('/v1/conversations/$convId/truncate', {'keep': keep});
    await cache.truncateMessages(convId, keep);
    _messagePages[convId] = const _MessagePage(oldestId: null);
  }

  @override
  Future<void> truncateMessagesBefore(
    int convId,
    int beforeId, {
    int? keepFallback,
  }) async {
    await _post(
      '/v1/conversations/$convId/truncate',
      {
        'before_id': beforeId,
        'keep': ?keepFallback,
      },
    );
    await cache.truncateMessagesBefore(convId, beforeId);
    // 截断后保留的是最早的这一段，前面不会再有更早页。
    _messagePages[convId] = const _MessagePage(oldestId: null);
  }

  @override
  Future<List<MessageHit>> searchMessages(String query) async {
    try {
      final data = await _get(
        '/v1/search?limit=50&q=${Uri.encodeQueryComponent(query)}',
      );
      final raw = data['items'];
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map)
            MessageHit(
              conversationId: (item['conversation_id'] as num?)?.toInt() ?? 0,
              conversationTitle: item['conversation_title'] as String? ?? '',
              role: item['role'] == 'user'
                  ? MessageRole.user
                  : MessageRole.assistant,
              content: item['content'] as String? ?? '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                (item['ts'] as num?)?.toInt() ?? 0,
              ),
              matches: [
                for (final m in (item['matches'] as List? ?? const []))
                  if (m is num) m.toInt(),
              ],
            ),
      ];
    } on ChatRepositoryException {
      return cache.searchMessages(query);
    }
  }

  /// 该会话是否有正在生成的任务（App 重开后按会话恢复，与官方 resume_stream 同思路）。
  Future<String?> activeJobId(int convId) async {
    try {
      final data = await _get('/v1/conversations/$convId/active_job');
      final jobId = data['job_id'];
      return jobId is String && jobId.isNotEmpty ? jobId : null;
    } on ChatRepositoryException {
      return null;
    }
  }

  // -------------------------------------------------------------- HTTP 工具

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await _client
        .get(Uri.parse('$_base$path'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await _client
        .post(
          Uri.parse('$_base$path'),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _client
        .patch(
          Uri.parse('$_base$path'),
          headers: {'Content-Type': 'application/json', ..._headers},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    final res = await _client
        .delete(Uri.parse('$_base$path'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode != 200) {
      throw ChatRepositoryException('服务器返回 ${res.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const ChatRepositoryException('服务器返回格式错误');
    }
    return decoded;
  }

  List<Conversation> _parseConversations(Object? raw) =>
      ConversationCodec.listFromWire(raw);

  List<ChatMessage> _parseMessages(Object? raw) =>
      MessageCodec.listFromWire(raw);
}

/// 单个会话的消息分页状态。
class _MessagePage {
  const _MessagePage({required this.oldestId, this.hasMore = false});

  final int? oldestId;
  final bool hasMore;
}
