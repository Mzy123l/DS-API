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
import 'package:ds_api/storage.dart';

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
  Future<void> renameConversation(int id, String title) async {}

  @override
  Future<void> setSystemPrompt(int id, String prompt) async {
    final conv = conversations[id];
    if (conv == null) return;
    conversations[id] = conv.copyWith(systemPrompt: prompt);
  }

  @override
  Future<void> deleteConversation(int id) async {}

  @override
  Future<bool> conversationExists(int id) async =>
      conversations.containsKey(id);

  @override
  Future<void> cacheConversations(
    List<Conversation> items, {
    bool replace = false,
  }) async {
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
  Future<bool> hasLegacyData() async => false;
}

/// 假中转：思考阶段先挂住，之后可以放行完成。
class ReasoningRelay {
  static const int convId = 1;
  bool includeCheckpointRow = false;
  String reasoning = '思考中…';
  String content = '';
  bool done = false;
  int snapshotRequests = 0;

  /// 前 N 次快照请求返回 500（模拟退后台时网络不可用）
  int failSnapshots = 0;

  /// true：快照接口直接 404（模拟服务重启后任务已被回收）
  bool jobGone = false;

  /// 发完思考内容就断开连接（模拟退后台后连接被系统断开）
  bool dropAfterReasoning = false;
  late HttpServer _server;
  Completer<void>? _chatGate;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    final gate = _chatGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/v1/chat') {
      final body = await utf8.decoder.bind(req).join();
      // 标题生成走一条独立的短请求，别占用主回答的快照失败次数
      if (body.contains('概括这段提问')) {
        final res = req.response
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..bufferOutput = false;
        res.write(
          'data: ${jsonEncode({
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': '{"title": "测试"}'},
          })}\n\n',
        );
        res.write('data: ${jsonEncode({'type': 'message_stop'})}\n\n');
        await res.close();
        return;
      }
      final gate = Completer<void>();
      _chatGate = gate;
      final res = req.response
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..bufferOutput = false;
      res.write(
        'data: ${jsonEncode({'type': '__job', 'job_id': 'job-1'})}\n\n',
      );
      res.write(
        'data: ${jsonEncode({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': reasoning},
        })}\n\n',
      );
      await res.flush();
      if (dropAfterReasoning) {
        await res.close();
        return;
      }
      await gate.future;
      await res.close();
      return;
    }
    if (req.method == 'POST' && path == '/v1/conversations') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'id': convId}));
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/v1/conversations') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'items': [
            {
              'id': convId,
              'title': '会话',
              'model': AppMode.quick.model,
              'updated_at': DateTime.now().millisecondsSinceEpoch,
              'preview': '',
            },
          ],
          'has_more': false,
        }),
      );
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/v1/conversations/$convId/messages') {
      final items = <Map<String, dynamic>>[
        {
          'id': 1,
          'conversation_id': convId,
          'role': 'user',
          'content': '问题',
          'reasoning': '',
          'reasoning_ms': 0,
          'sources': <Object>[],
          'images': <Object>[],
          'ts': 0,
        },
        if (includeCheckpointRow)
          {
            'id': 2,
            'conversation_id': convId,
            'role': 'assistant',
            'content': content,
            'reasoning': reasoning,
            'reasoning_ms': 0,
            'sources': <Object>[],
            'images': <Object>[],
            'ts': 1,
          },
      ];
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({'items': items, 'has_more': false, 'oldest_id': 1}),
      );
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && path == '/v1/conversations/$convId/messages') {
      await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'id': 1}));
      await req.response.close();
      return;
    }
    if (req.method == 'GET' && path == '/v1/jobs/job-1') {
      snapshotRequests++;
      if (jobGone) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (failSnapshots > 0) {
        failSnapshots--;
        req.response.statusCode = 500;
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'job_id': 'job-1',
          'status': done ? 'done' : 'running',
          'reasoning': reasoning,
          'content': content,
          'sources': <Object>[],
          'reasoning_ms': 0,
          'stored_message_id': done ? 2 : null,
          'result_ready': done,
        }),
      );
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }
}

/// 等待条件成立（流式回调是异步的，没法直接 await）。
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

AppState buildState(MemoryDb db, SettingsStore settings, ReasoningRelay relay) {
  return AppState(
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
    )
    ..apiKey = 'sk-test'
    ..protocol = ApiProtocol.anthropic
    ..useServer = true;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('杀掉进程后重开：思考中 + 服务端完成任务应能补齐', () async {
    final relay = ReasoningRelay();
    await relay.start();
    final db = MemoryDb();
    final settings = SettingsStore();
    final first = buildState(db, settings, relay);
    addTearDown(() async {
      first.dispose();
      await relay.stop();
    });

    await first.init();
    first.apiKey = 'sk-test';
    await first.send('问题');
    await waitFor(
      () =>
          first.messages.isNotEmpty && first.messages.last.reasoning == '思考中…',
      reason: '思考内容没有出现',
    );
    expect(await SettingsStore().pendingJob, contains('job-1'));

    // 模拟进程被杀：不再使用 first，直接新建 AppState 重开
    await relay._chatGate?.future.timeout(
      const Duration(milliseconds: 200),
      onTimeout: () {},
    );

    final second = buildState(db, settings, relay);
    addTearDown(second.dispose);
    await second.init();
    second.apiKey = 'sk-test';
    await waitFor(
      () => second.messages.any((m) => m.reasoning.isNotEmpty),
      reason: '重开后没有恢复思考内容',
    );
    expect(second.busy, isTrue);

    // 服务端完成生成
    relay.content = '最终回答';
    relay.done = true;
    await waitFor(() => !second.busy, reason: '重开后任务没有收尾');
    expect(second.messages.last.content, '最终回答');
    expect(second.messages.last.reasoning, '思考中…');
    final saved = await db.loadMessages(1);
    expect(saved.last.content, '最终回答');
    expect(saved.last.reasoning, '思考中…');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  test('退后台时快照暂时不可用：不能清空思考内容、不能丢弃任务', () async {
    final relay = ReasoningRelay()
      ..dropAfterReasoning = true
      ..failSnapshots = 5;
    await relay.start();
    final db = MemoryDb();
    final settings = SettingsStore();
    final state = buildState(db, settings, relay);
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.init();
    state.apiKey = 'sk-test';
    await state.send('问题');
    await waitFor(
      () => state.messages.last.reasoning == '思考中…',
      reason: '思考内容没有出现',
    );

    // 连接被断开、快照连续失败（退后台 / 切网），此时任务仍在服务端跑。
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(state.busy, isTrue, reason: '不应因为取不到快照就结束本轮');
    expect(state.messages.last.reasoning, '思考中…', reason: '思考内容不能丢');
    expect(await SettingsStore().pendingJob, contains('job-1'));

    // 网络恢复、服务端完成生成
    relay.content = '最终回答';
    relay.done = true;
    await waitFor(
      () => !state.busy && state.messages.last.content == '最终回答',
      reason: '网络恢复后没有补齐最终回答',
      timeout: const Duration(seconds: 30),
    );
    expect(state.messages.last.reasoning, '思考中…');
    expect(await SettingsStore().pendingJob, isNull);
    // 等收尾里的落库/刷新跑完，避免 tearDown 先 dispose 触发告警
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  test('服务端任务已被回收（404）：按会话历史拉回已存好的回答，且不重复', () async {
    final relay = ReasoningRelay()
      ..dropAfterReasoning = true
      ..jobGone = true
      ..includeCheckpointRow = true
      ..content = '最终回答'
      ..done = true;
    await relay.start();
    final db = MemoryDb();
    final settings = SettingsStore();
    final state = buildState(db, settings, relay);
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.init();
    state.apiKey = 'sk-test';
    await state.send('问题');
    // 收尾（busy=false）与「按服务端历史补回回答」是两步：只等 busy 会在
    // 消息写回之前就断言（偶发读到空内容），这里连内容一起等。
    await waitFor(
      () => !state.busy && state.messages.last.content == '最终回答',
      reason: '任务丢失后没有把服务端已存好的回答补回来',
      timeout: const Duration(seconds: 30),
    );
    // 服务端已经存好的回答要补回界面，不能只留一句提示
    expect(state.messages.last.content, '最终回答');
    expect(state.messages.last.reasoning, '思考中…');
    final assistants = [
      for (final msg in state.messages)
        if (msg.role == MessageRole.assistant) msg,
    ];
    expect(assistants.length, 1, reason: '不能和本机临时内容各存一条');
    expect(await SettingsStore().pendingJob, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  test('加载会话时不能把只有思考内容的尾条当空占位删掉', () async {
    final relay = ReasoningRelay()
      ..includeCheckpointRow = true
      ..content = ''
      ..reasoning = '思考中…';
    await relay.start();
    final db = MemoryDb();
    final settings = SettingsStore();
    final state = buildState(db, settings, relay);
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });

    await state.init();
    state.apiKey = 'sk-test';
    await state.loadConversation(
      Conversation(
        id: 1,
        title: '会话',
        model: AppMode.quick.model,
        updatedAt: DateTime.now(),
      ),
    );

    expect(state.messages, isNotEmpty);
    expect(state.messages.last.role, MessageRole.assistant);
    expect(state.messages.last.content, isEmpty);
    expect(state.messages.last.reasoning, '思考中…');
    // 等 _attachRunningTurn 的 active_job 查询跑完，避免 teardown 先停服务端
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
}
