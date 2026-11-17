import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/chat_repository.dart';
import 'package:ds_api/models.dart';

import 'app_state_turns_test.dart' show MemoryDb;

/// 假服务器：会话列表每次只返回 2 条，用来验证启动时会自动翻页拉全。
class PagedConversationServer {
  PagedConversationServer({required this.conversations, required this.messages});

  final List<Map<String, dynamic>> conversations;
  final Map<int, List<Map<String, dynamic>>> messages;
  int listRequests = 0;
  int messageRequests = 0;
  int activeJobRequests = 0;

  late HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/v1/conversations') {
      listRequests++;
      final beforeId = int.tryParse(
        req.uri.queryParameters['before_id'] ?? '',
      );
      var start = 0;
      if (beforeId != null) {
        final index = conversations.indexWhere(
          (item) => item['id'] == beforeId,
        );
        if (index >= 0) start = index + 1;
      }
      final end = (start + 2) > conversations.length
          ? conversations.length
          : start + 2;
      final items = conversations.sublist(start, end);
      _writeJson(req, {
        'items': items,
        'has_more': end < conversations.length,
      });
      return;
    }
    final match = RegExp(
      r'^/v1/conversations/(\d+)/messages$',
    ).firstMatch(path);
    if (req.method == 'GET' && match != null) {
      messageRequests++;
      final id = int.parse(match.group(1)!);
      final items = messages[id] ?? const [];
      _writeJson(req, {
        'items': items,
        'has_more': false,
        'oldest_id': items.isEmpty ? null : items.first['id'],
      });
      return;
    }
    final activeJob = RegExp(
      r'^/v1/conversations/(\d+)/active_job$',
    ).firstMatch(path);
    if (req.method == 'GET' && activeJob != null) {
      activeJobRequests++;
      _writeJson(req, {'job_id': null});
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void _writeJson(HttpRequest req, Map<String, dynamic> body) {
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}

Map<String, dynamic> conversationJson(int id, int updatedAt) => {
  'id': id,
  'title': '会话$id',
  'model': AppMode.quick.model,
  'system_prompt': '',
  'preview': '',
  'updated_at': updatedAt,
};

Map<String, dynamic> messageJson(int id, String role, String content) => {
  'id': id,
  'role': role,
  'content': content,
  'reasoning': '',
  'reasoning_ms': 0,
  'sources': <Object>[],
  'images': <Object>[],
  'ts': 1700000000000 + id,
};

void main() {
  setUp(() {
    // 源码不再内置任何服务器地址，测试必须显式给出中转地址，
    // 否则 DeepSeekClient.useRelay 为 false，不会去问服务端活跃任务。
    SharedPreferences.setMockInitialValues({
      'server_base_url': 'http://127.0.0.1:1',
      'use_server': true,
    });
  });

  test('启动时自动拉全服务器会话列表；点开会话时再拉消息', () async {
    final server = PagedConversationServer(
      conversations: [
        for (var i = 5; i >= 1; i--)
          conversationJson(i, 1700000000000 + i),
      ],
      messages: {
        5: [
          messageJson(1, 'user', '服务器上的问题'),
          messageJson(2, 'assistant', '服务器上的回答'),
        ],
      },
    );
    await server.start();
    final db = MemoryDb();
    final repository = ServerChatRepository(
      baseUrl: server.baseUrl,
      cache: db,
      client: http.Client(),
    );
    final state = AppState(db: db, repository: repository);
    addTearDown(() async {
      state.dispose();
      await server.stop();
    });

    await state.init();
    // 启动只等第一页；后台同步继续拉剩余分页
    await _waitFor(
      () => state.conversations.length == 5,
      reason: '启动后没有拉全会话列表',
    );
    expect(state.hasMoreConversations, isFalse);
    expect(server.listRequests, greaterThan(1));
    expect(
      [for (final conv in state.conversations) conv.id],
      [5, 4, 3, 2, 1],
    );

    // 发送/改名后的首屏刷新不能再把已加载的更早会话清掉
    await state.refreshConversations();
    expect(state.conversations.length, 5);
    expect(state.hasMoreConversations, isFalse);

    // 点开缺失的会话：此时才去拉它的消息
    await state.loadConversation(
      state.conversations.firstWhere((conv) => conv.id == 5),
    );
    await _waitFor(
      () => state.messages.length == 2,
      reason: '点开会话后没有拉取消息',
    );
    expect(server.messageRequests, 1);
    expect(
      [for (final message in state.messages) message.content],
      ['服务器上的问题', '服务器上的回答'],
    );
    // loadConversation 会异步询问是否有正在生成的任务；等它结束再关假服务器
    await _waitFor(
      () => server.activeJobRequests > 0,
      reason: '没有检查活跃任务',
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

Future<void> _waitFor(
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
