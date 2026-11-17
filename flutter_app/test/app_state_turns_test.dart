import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/chat_repository.dart';
import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/prompt.dart';
import 'package:ds_api/storage.dart';

/// 内存版本地库：只实现 AppState 用到的那部分，测试里不碰 sqflite。
class MemoryDb extends AppDatabase {
  final Map<int, List<ChatMessage>> messages = {};
  final Map<int, Conversation> conversations = {};
  int _nextConversationId = 1;
  int _nextMessageId = 1;

  @override
  Future<List<Conversation>> listConversations() async =>
      conversations.values.toList();

  @override
  Future<int> createConversation(
    String title,
    String model, {
    String systemPrompt = '',
  }) async {
    final id = _nextConversationId++;
    conversations[id] = Conversation(
      id: id,
      title: title,
      model: model,
      updatedAt: DateTime.now(),
      systemPrompt: systemPrompt,
    );
    return id;
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    final conv = conversations[id];
    if (conv == null) return;
    conversations[id] = Conversation(
      id: id,
      title: title,
      model: conv.model,
      updatedAt: conv.updatedAt,
      systemPrompt: conv.systemPrompt,
    );
  }

  @override
  Future<void> setSystemPrompt(int id, String prompt) async {
    final conv = conversations[id];
    if (conv == null) return;
    conversations[id] = conv.copyWith(systemPrompt: prompt);
  }

  @override
  Future<void> deleteConversation(int id) async {
    conversations.remove(id);
    messages.remove(id);
  }

  @override
  Future<bool> conversationExists(int id) async =>
      conversations.containsKey(id);

  @override
  Future<void> cacheConversations(
    List<Conversation> items, {
    bool replace = false,
  }) async {
    if (replace) conversations.clear();
    for (final conv in items) {
      conversations[conv.id] = conv;
    }
  }

  @override
  Future<void> cacheMessages(
    int convId,
    List<ChatMessage> items, {
    bool replace = false,
  }) async {
    if (replace) messages[convId] = [];
    for (final msg in items) {
      _put(convId, msg);
    }
  }

  @override
  Future<int> saveMessage(int convId, ChatMessage msg) async =>
      _put(convId, msg);

  /// 与真实实现一致：同 id 覆盖，新消息追加在后。
  int _put(int convId, ChatMessage msg) {
    final list = messages.putIfAbsent(convId, () => []);
    final id = msg.id ?? _nextMessageId++;
    final saved = msg.copyWith(id: id);
    final index = list.indexWhere((m) => m.id == id);
    if (index >= 0) {
      list[index] = saved;
    } else {
      list.add(saved);
    }
    final conv = conversations[convId];
    if (conv != null) {
      conversations[convId] = conv.copyWith(updatedAt: DateTime.now());
    }
    return id;
  }

  @override
  Future<List<ChatMessage>> loadMessages(
    int convId, {
    int? limit,
    int? beforeId,
  }) async {
    var list = List<ChatMessage>.from(messages[convId] ?? const []);
    if (beforeId != null) {
      list = [
        for (final m in list)
          if ((m.id ?? 0) < beforeId) m,
      ];
    }
    if (limit != null && list.length > limit) {
      list = list.sublist(list.length - limit);
    }
    return list;
  }

  @override
  Future<void> truncateMessages(int convId, int keep) async {
    final list = messages[convId];
    if (list == null) return;
    messages[convId] = list.take(keep).toList();
  }

  @override
  Future<void> truncateMessagesBefore(
    int convId,
    int beforeId, {
    int? keepFallback,
  }) async {
    final list = messages[convId];
    if (list == null) return;
    messages[convId] = [
      for (final msg in list)
        if ((msg.id ?? 0) < beforeId) msg,
    ];
  }

  @override
  Future<List<MessageHit>> searchMessages(
    String query, {
    int limit = 300,
  }) async => const [];

  @override
  Future<bool> hasLegacyData() async => false;
}

/// 记录落库方式的仓库：区分“新增一条”（appendMessage）与“只补本地缓存”（cacheMessage）
class RecordingRepository extends LocalChatRepository {
  RecordingRepository(super.db);

  final List<String> calls = [];

  @override
  Future<ChatMessage> appendMessage(int convId, ChatMessage msg) {
    calls.add('append');
    return super.appendMessage(convId, msg);
  }

  @override
  Future<void> cacheMessage(int convId, ChatMessage msg) {
    calls.add('cache');
    return super.cacheMessage(convId, msg);
  }

  @override
  Future<void> truncateMessages(int convId, int keep) {
    calls.add('truncate:$keep');
    return super.truncateMessages(convId, keep);
  }

  @override
  Future<void> truncateMessagesBefore(
    int convId,
    int beforeId, {
    int? keepFallback,
  }) {
    calls.add('truncateBefore:$beforeId');
    return super.truncateMessagesBefore(
      convId,
      beforeId,
      keepFallback: keepFallback,
    );
  }
}

/// 把最新一页人为挂起，用来复现“回答完成后旧加载才返回”的竞态。
class GatedRepository extends LocalChatRepository {
  GatedRepository(super.db);

  Completer<void>? pageGate;
  Completer<void>? pageStarted;

  @override
  Future<List<ChatMessage>> loadLatestMessages(int convId, {int? limit}) async {
    final gate = pageGate;
    if (gate != null) {
      pageStarted?.complete();
      await gate.future;
      pageGate = null;
      return const [];
    }
    return super.loadLatestMessages(convId, limit: limit);
  }
}

/// 假装还有更早页，用来验证发送前会把早期消息拼进请求上下文。
class PagedRepository extends LocalChatRepository {
  PagedRepository(super.db);

  @override
  bool hasOlderMessagesFor(int convId) => true;

  @override
  Future<List<ChatMessage>> loadAllOlderMessages(int convId) async => [
    ChatMessage(
      id: 90001,
      role: MessageRole.user,
      content: '早前问题',
      timestamp: DateTime.now(),
    ),
    ChatMessage(
      id: 90002,
      role: MessageRole.assistant,
      content: '早前回答',
      timestamp: DateTime.now(),
    ),
  ];
}

/// 模拟服务器：最新一页只给 30 条，但更早的页仍可通过分页取回。
class WindowRepository extends RecordingRepository {
  WindowRepository(super.db);

  @override
  bool hasOlderMessagesFor(int convId) => true;

  @override
  Future<List<ChatMessage>> loadLatestMessages(int convId, {int? limit}) async {
    final all = await db.loadMessages(convId);
    return all.length <= 30 ? all : all.sublist(all.length - 30);
  }

  @override
  Future<List<ChatMessage>> loadAllOlderMessages(int convId) async {
    final all = await db.loadMessages(convId);
    return all.length <= 30 ? const [] : all.sublist(0, all.length - 30);
  }
}

/// 假中转：一个会话里已经有一条 checkpoint 助手消息，续接时不能重复追加。
class CheckpointRelayServer {
  static const int conversationId = 1;

  String fullContent = '部分回答·后续';
  late HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/v1/conversations') {
      _json(req, {
        'items': [
          {
            'id': conversationId,
            'title': '会话',
            'model': AppMode.quick.model,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
            'preview': '',
          },
        ],
        'has_more': false,
      });
      return;
    }
    if (req.method == 'GET' &&
        path == '/v1/conversations/$conversationId/messages') {
      _json(req, {
        'items': [
          {
            'id': 1,
            'conversation_id': conversationId,
            'role': 'user',
            'content': '问题',
            'reasoning': '',
            'reasoning_ms': 0,
            'sources': <Object>[],
            'images': <Object>[],
            'ts': 0,
          },
          {
            'id': 42,
            'conversation_id': conversationId,
            'role': 'assistant',
            'content': '部分回答',
            'reasoning': '',
            'reasoning_ms': 0,
            'sources': <Object>[],
            'images': <Object>[],
            'ts': 1,
          },
        ],
        'has_more': false,
        'oldest_id': 1,
      });
      return;
    }
    if (req.method == 'GET' && path == '/v1/jobs/job-1') {
      _json(req, {
        'job_id': 'job-1',
        'status': 'done',
        'content': fullContent,
        'reasoning': '',
        'sources': <Object>[],
        'reasoning_ms': 0,
        'stored_message_id': 42,
        'result_ready': true,
      });
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void _json(HttpRequest req, Map<String, dynamic> body) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}

/// 假上游（直连模式）：每收到一次请求回放一段 SSE，
/// 第二段要等测试放开 [gates] 里对应的门才发，用来模拟“回答还在生成中”。
class FakeUpstream {
  final List<Completer<void>> gates = [];
  int completedRequests = 0;

  /// 最近一次主回答请求体，用来断言上下文是否包含更早轮次。
  String? lastBody;

  late HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    // 标题生成另走一条短请求，避免占用测试的“回答”通道
    if (body.contains('概括这段提问')) {
      await _writeJson(req);
      return;
    }
    lastBody = body;
    final index = gates.length;
    final gate = Completer<void>();
    gates.add(gate);
    final response = req.response
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..bufferOutput = false;
    _write(response, _delta('回答${index + 1}·第一段'));
    await response.flush();
    await gate.future;
    _write(response, _delta('·第二段'));
    _write(response, 'data: ${jsonEncode({'type': 'response.completed'})}\n\n');
    completedRequests++;
    await response.close();
  }

  Future<void> _writeJson(HttpRequest req) async {
    req.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    _write(req.response, _delta('{"title": "测试会话"}'));
    _write(
      req.response,
      'data: ${jsonEncode({'type': 'response.completed'})}\n\n',
    );
    await req.response.close();
  }

  /// 连接被客户端主动断开时写入会抛异常，这里直接忽略（不影响断言）。
  void _write(HttpResponse response, String text) {
    try {
      response.write(text);
    } catch (_) {}
  }

  static String _delta(String text) =>
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': text})}\n\n';
}

/// 假中转服务器：只需要 /v1/chat、任务快照与取消接口。
/// 用来复现“切走再切回时把任务取消掉”的旧问题。
class FakeRelayServer {
  final List<String> cancelRequests = [];

  /// 取消后前 N 次快照故意不带落库 id（复现服务端“先停任务、后落库”的时序）
  int snapshotsBeforeStoredId = 0;

  /// 快照正文覆盖值；为空时跟流式正文一致。
  /// 用来模拟“服务端快照比客户端已显示内容短”的时序。
  String? snapshotContent;

  String content = '';
  bool done = false;
  bool canceled = false;

  int _cancelSnapshotsSeen = 0;
  Completer<void>? _gate;
  late HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    release();
    await _server.close(force: true);
  }

  /// 放开被挂住的流：补第二段并让任务变成已完成。
  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/v1/chat') {
      await utf8.decoder.bind(req).join();
      await _handleChat(req);
      return;
    }
    if (req.method == 'GET' && path == '/v1/jobs/job-1') {
      final storedReady =
          !canceled || _cancelSnapshotsSeen >= snapshotsBeforeStoredId;
      if (canceled) _cancelSnapshotsSeen++;
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'status': canceled ? 'canceled' : (done ? 'done' : 'running'),
          'content': snapshotContent ?? content,
          'reasoning': '',
          'stored_message_id': (done && storedReady) ? 42 : null,
        }),
      );
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && path == '/v1/jobs/job-1/cancel') {
      cancelRequests.add(path);
      canceled = true;
      done = true;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"canceled":true}');
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> _handleChat(HttpRequest req) async {
    final gate = Completer<void>();
    _gate = gate;
    content = '中转·第一段';
    try {
      final response = req.response
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..bufferOutput = false;
      response.write(
        'data: ${jsonEncode({'type': '__job', 'job_id': 'job-1'})}\n\n',
      );
      response.write(
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': content})}\n\n',
      );
      await response.flush();
      await gate.future;
      // 收到取消时不再往下写（服务端此时已停止生成，只等它落库）
      if (!canceled) {
        content = '中转·第一段·第二段';
        done = true;
        response.write(
          'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': '·第二段'})}\n\n',
        );
        response.write(
          'data: ${jsonEncode({'type': 'response.completed'})}\n\n',
        );
      }
      await response.close();
    } catch (_) {
      // 客户端断开时忽略
    }
  }
}

/// 轮询等待条件成立（流式回调是异步的，没法直接 await）。
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = '条件未满足',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

AppState buildState({
  required MemoryDb db,
  required DeepSeekClient Function() clientFactory,
  ChatRepository? repository,
  bool useServer = false,
}) {
  final state =
      AppState(
          db: db,
          settings: SettingsStore(),
          repository: repository ?? LocalChatRepository(db),
          clientFactory: clientFactory,
        )
        ..apiKey = 'sk-test'
        ..protocol = ApiProtocol.responses
        ..useServer = useServer;
  return state;
}

Conversation conv(int id, {String title = '会话'}) => Conversation(
  id: id,
  title: title,
  model: AppMode.quick.model,
  updatedAt: DateTime.now(),
);

void main() {
  setUp(() {
    // 用内存版 SharedPreferences，不初始化测试 Binding：
    // Binding 会把 HttpClient 换成返回 400 的假实现，这套用例需要真实回环请求。
    SharedPreferences.setMockInitialValues({});
  });

  test('切到别的会话再切回来：生成不被打断，接着显示后续内容', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('问题1');
    final convId = state.currentConversationId!;
    await waitFor(
      () => state.messages.last.content == '回答1·第一段',
      reason: '第一段没有出现',
    );
    expect(state.busy, isTrue);

    // 切到别的会话：原来的生成只在后台跑，不该被取消
    await state.loadConversation(conv(999, title: '别的会话'));
    expect(state.currentConversationId, 999);
    expect(state.busy, isFalse);
    expect(state.runningConversationIds, {convId});

    // 切回来：已经生成的内容立刻回到界面，并且还在“生成中”
    await state.loadConversation(conv(convId));
    expect(state.busy, isTrue);
    expect(state.messages.last.content, '回答1·第一段');

    upstream.gates.first.complete();
    await waitFor(
      () => state.messages.last.content == '回答1·第一段·第二段',
      reason: '切回来后没有继续输出',
    );
    await waitFor(() => !state.busy, reason: '任务没有收尾');

    // 收尾后落库，重开该会话能读到完整回答
    final saved = await db.loadMessages(convId);
    expect(saved.last.content, '回答1·第一段·第二段');
  });

  test('多个会话可以同时提问、同时输出，互不打断', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('问题1');
    final first = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '回答1·第一段');

    // 新建对话（不打断上一个会话）后立刻再提问
    await state.newChat();
    expect(state.currentConversationId, isNull);
    await state.send('问题2');
    final second = state.currentConversationId!;
    expect(second, isNot(first));
    await waitFor(() => state.messages.last.content == '回答2·第一段');

    expect(state.busy, isTrue);
    expect(state.runningConversationIds, containsAll([first, second]));
    // 两个上游请求同时在跑（各自一条独立的流）
    expect(upstream.gates.length, 2);

    // 先让第二个会话收尾，再让第一个：两条互不影响
    upstream.gates[1].complete();
    await waitFor(() => !state.busy, reason: '当前会话没有收尾');
    expect(state.runningConversationIds, {first});
    expect((await db.loadMessages(second)).last.content, '回答2·第一段·第二段');

    upstream.gates[0].complete();
    await waitFor(
      () => state.runningConversationIds.isEmpty,
      reason: '第一个会话没有收尾',
    );
    expect((await db.loadMessages(first)).last.content, '回答1·第一段·第二段');
  });

  test('切走后后台跑完：切回来能看到完整回答，也不会串到别的会话', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('问题1');
    final convId = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '回答1·第一段');
    await state.loadConversation(conv(999, title: '别的会话'));

    // 在别的会话里让原会话跑完
    upstream.gates.first.complete();
    await waitFor(() => upstream.completedRequests == 1, reason: '后台回答没有跑完');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // 后台内容不会写进正在看的这个会话
    expect(state.messages, isEmpty);
    expect(state.runningConversationIds, isEmpty);

    await state.loadConversation(conv(convId));
    expect(state.busy, isFalse);
    expect(state.messages.last.content, '回答1·第一段·第二段');
  });

  test('停止只停当前会话，别的会话继续输出', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('问题1');
    final first = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '回答1·第一段');

    await state.newChat();
    await state.send('问题2');
    final second = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '回答2·第一段');

    // 回到第一个会话点“停止”：只停它自己
    await state.loadConversation(conv(first));
    await state.stopGeneration();
    expect(state.busy, isFalse);
    expect(state.runningConversationIds, {second});
    // 停止时已生成的部分照样落库
    expect((await db.loadMessages(first)).last.content, '回答1·第一段');

    upstream.gates[1].complete();
    await waitFor(
      () => state.runningConversationIds.isEmpty,
      reason: '第二个会话没有收尾',
    );
    expect((await db.loadMessages(second)).last.content, '回答2·第一段·第二段');
  });

  test('中转模式：切走再切回不会取消服务端任务', () async {
    final relay = FakeRelayServer();
    await relay.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      useServer: true,
      clientFactory: () => DeepSeekClient(
        relayBaseUrl: relay.baseUrl,
        useRelay: true,
        client: http.Client(),
      ),
    );
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.send('问题1');
    final convId = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '中转·第一段');
    // 任务号按会话记录，App 被杀后可以续上
    expect(await SettingsStore().pendingJob, contains('job-1'));

    await state.loadConversation(conv(999, title: '别的会话'));
    await state.loadConversation(conv(convId));

    // 旧实现会在这里对上一次的任务发 /cancel，导致回答被切断
    expect(relay.cancelRequests, isEmpty);
    expect(state.busy, isTrue);
    expect(state.messages.last.content, '中转·第一段');

    relay.release();
    await waitFor(() => !state.busy, reason: '中转任务没有收尾');
    expect(state.messages.last.content, '中转·第一段·第二段');
    // 服务端已落库的同一条回答只做本地缓存，不会重复追加
    expect((await db.loadMessages(convId)).last.content, '中转·第一段·第二段');
    expect((await db.loadMessages(convId)).last.id, 42);
    // 收尾后清掉未完成任务记录
    expect(await SettingsStore().pendingJob, isNull);
  });

  test('中转：最终快照比流式内容短时，不能覆盖掉最后一段', () async {
    final relay = FakeRelayServer()..snapshotContent = '中转·第一段';
    await relay.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      useServer: true,
      clientFactory: () => DeepSeekClient(
        relayBaseUrl: relay.baseUrl,
        useRelay: true,
        client: http.Client(),
      ),
    );
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.send('问题1');
    await waitFor(() => state.messages.last.content == '中转·第一段');

    relay.release();
    await waitFor(() => !state.busy, reason: '中转任务没有收尾');
    // 服务端快照只回了第一段，但本地流式已经收到第二段，不能回退覆盖。
    expect(state.messages.last.content, '中转·第一段·第二段');
  });

  test('中转模式：点停止后不重复落库（按服务端快照对齐这一条）', () async {
    // 服务端取消时先回“已停止、还没落库”，随后才带上落库 id
    final relay = FakeRelayServer()..snapshotsBeforeStoredId = 2;
    await relay.start();
    final db = MemoryDb();
    final repo = RecordingRepository(db);
    final state = buildState(
      db: db,
      repository: repo,
      useServer: true,
      clientFactory: () => DeepSeekClient(
        relayBaseUrl: relay.baseUrl,
        useRelay: true,
        client: http.Client(),
      ),
    );
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.send('问题1');
    final convId = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '中转·第一段');

    repo.calls.clear();
    await state.stopGeneration();
    expect(state.busy, isFalse);
    // 只补本地缓存，不再新增一条（旧实现在这里会 append 出第二条）
    expect(repo.calls, ['cache']);
    await waitFor(() => relay.cancelRequests.isNotEmpty, reason: '没有通知服务端取消');
    expect(relay.cancelRequests, ['/v1/jobs/job-1/cancel']);

    // 服务端已把这段内容落库：本地只缓存它那一条，不再追加第二条
    final assistants = [
      for (final msg in await db.loadMessages(convId))
        if (msg.role == MessageRole.assistant) msg,
    ];
    expect(assistants.length, 1);
    expect(assistants.single.id, 42);
    expect(assistants.single.content, '中转·第一段');
    // 界面上也只有这一条
    expect(state.messages.last.id, 42);
    expect(state.messages.last.content, '中转·第一段');
    expect(await SettingsStore().pendingJob, isNull);
  });

  test('长会话重新生成：按目标消息 id 截断，不用加载窗口下标', () async {
    final db = MemoryDb();
    db.conversations[1] = Conversation(
      id: 1,
      title: '长会话',
      model: AppMode.quick.model,
      updatedAt: DateTime.now(),
    );
    db.messages[1] = [
      for (var id = 1; id <= 100; id++)
        ChatMessage(
          id: id,
          role: id.isOdd ? MessageRole.user : MessageRole.assistant,
          content: 'm$id',
          timestamp: DateTime.now(),
        ),
    ];
    final repo = WindowRepository(db);
    final state = buildState(
      db: db,
      repository: repo,
      clientFactory: () => DeepSeekClient(baseUrl: 'http://127.0.0.1:1'),
    )..apiKey = null;
    addTearDown(state.dispose);

    // 只加载最近 30 条（约 15 轮），这是容易截错位置的窗口。
    await state.loadConversation(conv(1, title: '长会话'));
    expect(state.messages.length, 30);
    repo.calls.clear();

    // 重新生成窗口里的最后一条回答（全局 id=100）。
    await state.regenerateAt(state.messages.length - 1);

    expect(repo.calls, contains('truncateBefore:100'));
    expect(
      repo.calls.any((call) => call.startsWith('truncate:')),
      isFalse,
      reason: '不应再把窗口下标 29 当成全局保留条数',
    );
    expect(db.messages[1]!.length, 99);
  });

  test('发送前补齐更早分页，请求上下文包含早期轮次', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final repo = PagedRepository(db);
    final state = buildState(
      db: db,
      repository: repo,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('新问题');
    await waitFor(
      () => upstream.lastBody?.contains('早前问题') == true,
      reason: '请求体没有带上更早的用户消息',
    );
    expect(upstream.lastBody, contains('早前回答'));
    expect(
      state.messages.map((m) => m.content),
      containsAll(['早前问题', '早前回答', '新问题']),
    );
  });

  test('回答完成后旧加载才返回：不能清空刚完成的回答', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final repo = GatedRepository(db);
    final state = buildState(
      db: db,
      repository: repo,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('问题1');
    final convA = state.currentConversationId!;
    await waitFor(() => state.messages.last.content == '回答1·第一段');

    // 切到别的会话，A 的回答继续在后台跑。
    await state.newChat();
    await state.send('问题2');
    await waitFor(() => state.messages.last.content == '回答2·第一段');

    // 回到 A：这次加载被人为挂起，稍后返回的是“回答落库前”的旧页。
    repo.pageStarted = Completer<void>();
    repo.pageGate = Completer<void>();
    unawaited(state.loadConversation(conv(convA, title: '会话A')));
    await repo.pageStarted!.future;

    upstream.gates[0].complete();
    await waitFor(
      () => state.messages.last.content == '回答1·第一段·第二段',
      reason: 'A 的完整回答没有先显示出来',
    );

    repo.pageGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.messages.last.content, '回答1·第一段·第二段');
  });

  test('服务端 checkpoint 续接：接管已落库的部分回答，不产生第二条', () async {
    final relay = CheckpointRelayServer();
    await relay.start();
    final db = MemoryDb();
    db.conversations[CheckpointRelayServer.conversationId] = Conversation(
      id: CheckpointRelayServer.conversationId,
      title: '会话',
      model: AppMode.quick.model,
      updatedAt: DateTime.now(),
    );
    db.messages[CheckpointRelayServer.conversationId] = [
      ChatMessage(
        id: 1,
        role: MessageRole.user,
        content: '问题',
        timestamp: DateTime.now(),
      ),
      ChatMessage(
        id: 42,
        role: MessageRole.assistant,
        content: '部分回答',
        timestamp: DateTime.now(),
      ),
    ];
    final settings = SettingsStore();
    await settings.setPendingJob(
      jsonEncode([
        {'job_id': 'job-1', 'conv_id': CheckpointRelayServer.conversationId},
      ]),
    );
    final state = AppState(
      db: db,
      settings: settings,
      repository: ServerChatRepository(
        baseUrl: relay.baseUrl,
        cache: db,
        client: http.Client(),
      ),
      clientFactory: () => DeepSeekClient(
        relayBaseUrl: relay.baseUrl,
        useRelay: true,
        client: http.Client(),
      ),
    );
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.init();
    await waitFor(
      () =>
          !state.busy &&
          state.messages.isNotEmpty &&
          state.messages.last.role == MessageRole.assistant &&
          state.messages.last.content == '部分回答·后续',
      reason: 'checkpoint 回答没有续接完成',
    );

    final assistants = [
      for (final msg in state.messages)
        if (msg.role == MessageRole.assistant) msg,
    ];
    expect(assistants.length, 1);
    expect(assistants.single.id, 42);
    expect(assistants.single.content, '部分回答·后续');
  });

  test('系统提示词：<system> 只进顶层字段，最新值覆盖并按会话保存', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('<system>你是猫</system>\n问题1');
    final convId = state.currentConversationId!;
    await waitFor(() => upstream.lastBody?.contains('你是猫') == true);

    var body = jsonDecode(upstream.lastBody!) as Map<String, dynamic>;
    // Responses 协议：系统提示词走 instructions，正文里不再出现标签
    expect(body['instructions'], '你是猫');
    expect(jsonEncode(body['input']), isNot(contains('<system>')));
    expect(jsonEncode(body['input']), contains('问题1'));
    expect(db.conversations[convId]!.systemPrompt, '你是猫');
    expect(state.systemPrompt, '你是猫');
    // 新消息只存正文，不再把 <system> 标签写进会话历史
    expect(state.messages.first.content, '问题1');

    upstream.gates.first.complete();
    await waitFor(() => !state.busy, reason: '第一轮没有收尾');

    // 同一会话再写一个 <system>：最后一次生效，并覆盖已保存的值
    await state.send('<system>你是狗</system>\n问题2');
    await waitFor(() => upstream.lastBody?.contains('你是狗') == true);
    body = jsonDecode(upstream.lastBody!) as Map<String, dynamic>;
    expect(body['instructions'], '你是狗');
    expect(db.conversations[convId]!.systemPrompt, '你是狗');
    expect(state.systemPrompt, '你是狗');

    upstream.gates[1].complete();
    await waitFor(() => !state.busy, reason: '第二轮没有收尾');

    // 新建对话回到默认值；重新进入旧会话时恢复该会话自己的提示词
    await state.newChat();
    expect(state.systemPrompt, defaultSystemPrompt);
    await state.loadConversation(conv(convId));
    expect(state.systemPrompt, '你是狗');
  });

  test('系统提示词：编辑框保存到当前会话，新对话首条消息随会话落库', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    // 还没创建对话时编辑：先留在内存，等首条消息创建会话时一起写入
    await state.setSystemPrompt('新提示');
    expect(state.systemPrompt, '新提示');
    await state.send('你好');
    final convId = state.currentConversationId!;
    await waitFor(() => upstream.lastBody != null);
    final body = jsonDecode(upstream.lastBody!) as Map<String, dynamic>;
    expect(body['instructions'], '新提示');
    expect(db.conversations[convId]!.systemPrompt, '新提示');

    upstream.gates.first.complete();
    await waitFor(() => !state.busy, reason: '第一轮没有收尾');

    // 已有对话里编辑：立即更新并持久化，下一次请求立刻生效
    await state.setSystemPrompt('改过的提示');
    expect(state.systemPrompt, '改过的提示');
    expect(db.conversations[convId]!.systemPrompt, '改过的提示');

    await state.send('继续');
    await waitFor(() => upstream.lastBody?.contains('改过的提示') == true);
    final next = jsonDecode(upstream.lastBody!) as Map<String, dynamic>;
    expect(next['instructions'], '改过的提示');
    upstream.gates[1].complete();
    await waitFor(() => !state.busy, reason: '第二轮没有收尾');

    // 保存空内容 = 恢复默认（显式写入默认值，避免旧 <system> 被反解回来）
    await state.setSystemPrompt('');
    expect(state.systemPrompt, defaultSystemPrompt);
    expect(db.conversations[convId]!.systemPrompt, defaultSystemPrompt);
  });
}
