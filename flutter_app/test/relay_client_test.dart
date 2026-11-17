import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/net_client.dart';

/// 假中转服务器：模拟 /v1/chat 流、任务快照与取消接口。
class FakeRelay {
  FakeRelay({this.jobId = 'job-1'});

  final String jobId;

  /// 本次 /v1/chat 要回放的上游事件行（不含 __job 事件）
  List<String> chatLines = const [];

  /// 按请求次序回放的事件行（联网搜索工具循环会发多轮请求）
  List<List<String>> chatScripts = const [];
  int _chatScript = 0;

  /// 前 N 次 /v1/chat 直接返回错误（用于错误转发 / max_tokens 重试）
  int chatFailCount = 0;
  int chatFailStatus = 400;
  String chatFailBody = '{"error":{"message":"boom"}}';

  /// 官方 Search / Fetch API 的假响应
  Map<String, dynamic> searchResponse = {
    'results': [
      {
        'title': 'DeepSeek 官网',
        'url': 'https://www.deepseek.com',
        'snippet': '官方站点',
        'summary': 'DeepSeek 官方站点',
      },
      {
        'title': '第二篇',
        'url': 'https://example.com/b',
        'snippet': '摘要',
        'summary': '长摘要',
      },
    ],
  };
  Map<String, dynamic> fetchResponse = {
    'title': '示例文章',
    'content': '# 示例文章\n\n正文内容',
  };

  /// 非 0 时工具接口返回该错误状态
  int toolFailStatus = 0;

  /// 收到 /v1/tools/search、/v1/tools/fetch 的请求记录
  final List<Map<String, dynamic>> toolRequests = [];

  /// 每一轮 /v1/chat 的请求体（联网搜索会有多轮）
  final List<Map<String, dynamic>> chatPayloads = [];

  /// true：只发 __job 事件就断开（模拟退后台/断网）
  bool dropChatEarly = false;

  /// 发出 N 行后强制中断连接（模拟传输层报错）
  int? abortAfterLines;

  /// 依次返回的任务快照（最后一项会重复返回）
  List<Map<String, dynamic>> snapshots = const [];

  /// 收到 /v1/chat 时的请求体，用于断言协议与 payload
  Map<String, dynamic>? lastChatPayload;
  Map<String, String> lastChatHeaders = const {};

  final List<String> cancelRequests = <String>[];
  int snapshotRequests = 0;

  /// 保持 /v1/chat 响应不结束（用于取消测试），测试结束前 complete
  Completer<void>? holdChat;

  late HttpServer _server;
  int _snapshotIndex = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handle);
  }

  Future<void> stop() async {
    final hold = holdChat;
    if (hold != null && !hold.isCompleted) hold.complete();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    final path = req.uri.path;
    if (req.method == 'POST' &&
        (path == '/v1/chat' ||
            path == '/anthropic/v1/messages' ||
            path == '/responses')) {
      await _handleChat(req, body);
      return;
    }
    if (req.method == 'POST' &&
        (path == '/v1/tools/search' || path == '/v1/tools/fetch')) {
      await _handleTool(req, path, body);
      return;
    }
    if (req.method == 'GET' && path.startsWith('/v1/jobs/')) {
      snapshotRequests++;
      var index = _snapshotIndex;
      if (index > snapshots.length - 1) index = snapshots.length - 1;
      final snapshot = snapshots.isEmpty
          ? <String, dynamic>{'status': 'done', 'content': '', 'reasoning': ''}
          : snapshots[index];
      if (_snapshotIndex < snapshots.length - 1) _snapshotIndex++;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(snapshot));
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && path.endsWith('/cancel')) {
      cancelRequests.add(path);
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"canceled":true}');
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> _handleTool(HttpRequest req, String path, String body) async {
    final decoded = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    toolRequests.add({
      'path': path,
      'body': decoded,
      'headers': {
        for (final name in ['authorization', 'x-relay-token'])
          if (req.headers.value(name) != null) name: req.headers.value(name)!,
      },
    });
    if (toolFailStatus != 0) {
      req.response.statusCode = toolFailStatus;
      req.response.headers.contentType = ContentType.json;
      req.response.write('{"error":{"message":"工具调用失败"}}');
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode(path.endsWith('/search') ? searchResponse : fetchResponse),
    );
    await req.response.close();
  }

  Future<void> _handleChat(HttpRequest req, String body) async {
    final payload = jsonDecode(body) as Map<String, dynamic>;
    lastChatPayload = payload;
    chatPayloads.add(payload);
    lastChatHeaders = {
      for (final name in ['x-api-key', 'authorization', 'x-relay-token'])
        if (req.headers.value(name) != null) name: req.headers.value(name)!,
    };
    if (chatFailCount > 0) {
      chatFailCount--;
      req.response.statusCode = chatFailStatus;
      req.response.headers.contentType = ContentType.json;
      req.response.write(chatFailBody);
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    // SSE 需要边写边发：关掉输出缓冲，否则数据要等响应结束才到客户端
    req.response.bufferOutput = false;
    req.response.write(
      'data: ${jsonEncode({'type': '__job', 'job_id': jobId})}\n\n',
    );
    await req.response.flush();
    if (dropChatEarly) {
      await req.response.close();
      return;
    }
    final lines = chatScripts.isEmpty
        ? chatLines
        : chatScripts[_chatScript.clamp(0, chatScripts.length - 1)];
    if (chatScripts.isNotEmpty && _chatScript < chatScripts.length - 1) {
      _chatScript++;
    }
    for (var i = 0; i < lines.length; i++) {
      if (abortAfterLines != null && i >= abortAfterLines!) {
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      }
      req.response.write('${lines[i]}\n\n');
      await req.response.flush();
    }
    if (holdChat != null) await holdChat!.future;
    await req.response.close();
  }
}

String delta(String text) =>
    'data: ${jsonEncode({
      'type': 'content_block_delta',
      'delta': {'type': 'text_delta', 'text': text},
    })}';

const String stopLine = 'data: {"type":"message_stop"}';

/// 调用一次中转模式的 send，收集回调结果。
Future<Map<String, dynamic>> sendViaRelay(
  DeepSeekClient client, {
  int? conversationId,
  bool webSearch = false,
  ApiProtocol protocol = ApiProtocol.anthropic,
}) async {
  var content = '';
  var reasoning = '';
  String? jobId;
  String? error;
  var done = false;
  final seenSnapshots = <String>[];
  final seenSources = <List<ChatSource>>[];
  final seenMessageIds = <int?>[];
  final eventSources = <ChatSource>[];
  await client.send(
    input: [
      {'role': 'user', 'content': 'hi'},
    ],
    model: 'deepseek-v4-pro',
    protocol: protocol,
    thinkingEnabled: true,
    reasoningEffort: 'high',
    apiKey: 'sk-test',
    webSearch: webSearch,
    onReasoningDelta: (d) => reasoning += d,
    onContentDelta: (d) => content += d,
    onReasoningTimed: (_) {},
    onSources: eventSources.addAll,
    onDone: () => done = true,
    onError: (e) => error = e,
    onJobStarted: (id) => jobId = id,
    onSnapshot: (RemoteSnapshot snap) {
      reasoning = snap.reasoning;
      content = snap.content;
      seenSnapshots.add(snap.content);
      seenSources.add(snap.sources);
      seenMessageIds.add(snap.messageId);
    },
    conversationId: conversationId,
  );
  return {
    'content': content,
    'reasoning': reasoning,
    'jobId': jobId,
    'error': error,
    'done': done,
    'snapshots': seenSnapshots,
    'sources': seenSources,
    'eventSources': eventSources,
    'messageIds': seenMessageIds,
  };
}

String sse(Map<String, dynamic> event) => 'data: ${jsonEncode(event)}';

String toolUseStart(int index, String id, String name) => sse({
  'type': 'content_block_start',
  'index': index,
  'content_block': {
    'type': 'tool_use',
    'id': id,
    'name': name,
    'input': <String, dynamic>{},
  },
});

String toolArgsDelta(int index, String partial) => sse({
  'type': 'content_block_delta',
  'index': index,
  'delta': {'type': 'input_json_delta', 'partial_json': partial},
});

String blockStop(int index) =>
    sse({'type': 'content_block_stop', 'index': index});

void main() {
  test('证书指纹归一化：去冒号/空格并转小写', () {
    expect(normalizeFingerprint('5E:E5:BA:18 96:2E'), '5ee5ba18962e');
    expect(normalizeFingerprint('  '), '');
  });

  test('未配置服务器地址时自动回退直连', () {
    final client = DeepSeekClient(relayBaseUrl: '  ', useRelay: true);
    expect(client.useRelay, isFalse);
    client.configure(relayBaseUrl: 'http://1.2.3.4:51888');
    expect(client.useRelay, isTrue);
    client.configure(useRelay: false);
    expect(client.useRelay, isFalse);
  });

  test('中转模式：流式增量 + 任务号 + 快照对齐', () async {
    final relay = FakeRelay();
    relay.chatLines = [delta('你好'), delta('世界'), stopLine];
    relay.snapshots = [
      {
        'status': 'done',
        'content': '你好世界',
        'reasoning': '想过了',
        'stored_message_id': 42,
        'sources': [
          {'title': '站点', 'url': 'https://example.com'},
        ],
      },
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      relayToken: 'relay-token-1',
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(client, conversationId: 7);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['jobId'], 'job-1');
    // 流式期间追加的增量 + 结束时按服务端快照对齐
    expect(result['snapshots'], ['你好世界']);
    expect(result['reasoning'], '想过了');
    final sources = result['sources'] as List<List<ChatSource>>;
    expect(sources.last.single.url, 'https://example.com');
    // 服务端落库后的消息 id 会通过快照带回来（用于分页游标与去重）
    expect((result['messageIds'] as List).last, 42);
    // 请求体走中转协议，并把 Key 透传给上游
    expect(relay.lastChatPayload!['protocol'], 'anthropic');
    expect(relay.lastChatPayload!['conversation_id'], 7);
    expect(relay.lastChatHeaders['x-api-key'], 'sk-test');
    // 服务器口令随每个请求带上
    expect(relay.lastChatHeaders['x-relay-token'], 'relay-token-1');

    await relay.stop();
  });

  test('中转模式：断流后用任务快照补齐完整回答', () async {
    final relay = FakeRelay();
    // 服务端刚接到任务就断开（模拟退到后台 / 切网）
    relay.dropChatEarly = true;
    relay.snapshots = [
      {'status': 'running', 'content': '写到一半', 'reasoning': ''},
      {
        'status': 'done',
        'content': '完整的回答',
        'reasoning': '完整思考',
        'sources': [
          {'title': '来源', 'url': 'https://a.example'},
        ],
      },
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(client);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['snapshots'], ['写到一半', '完整的回答']);
    expect(result['content'], '完整的回答');
    expect(result['reasoning'], '完整思考');
    expect(relay.snapshotRequests, greaterThanOrEqualTo(2));

    await relay.stop();
  });

  test('中转模式：传输层报错也能靠快照补齐', () async {
    final relay = FakeRelay();
    relay.chatLines = [delta('开头')];
    relay.abortAfterLines = 1;
    relay.snapshots = [
      {'status': 'done', 'content': '开头和结尾', 'reasoning': ''},
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(client);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['content'], '开头和结尾');

    await relay.stop();
  });

  test('中转模式：连接静默失联（无 onDone/onError）也能靠快照补齐', () async {
    final relay = FakeRelay();
    relay.chatLines = [
      sse({
        'type': 'content_block_delta',
        'delta': {'type': 'thinking_delta', 'thinking': '正在想'},
      }),
    ];
    // 发完思考就挂住：TCP 半开时客户端既收不到结束事件也不会报错
    relay.holdChat = Completer<void>();
    relay.snapshots = [
      {'status': 'done', 'content': '完整回答', 'reasoning': '正在想'},
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
      relayIdleTimeout: const Duration(milliseconds: 200),
    );

    final result = await sendViaRelay(client);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['content'], '完整回答');
    expect(result['reasoning'], '正在想');
    await relay.stop();
  });

  test('中转模式：上游错误原样上报（不吞消息）', () async {
    final relay = FakeRelay();
    relay.chatFailCount = 5;
    relay.chatFailStatus = 401;
    relay.chatFailBody = '{"error":{"message":"鉴权失败"}}';
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(client);

    expect(result['error'], '鉴权失败');
    expect(result['done'], isFalse);

    await relay.stop();
  });

  test('中转模式：服务端要求 max_tokens 时降级重试', () async {
    final relay = FakeRelay();
    relay.chatFailCount = 1;
    relay.chatFailStatus = 400;
    relay.chatFailBody = '{"error":{"message":"max_tokens 必须是整数"}}';
    relay.chatLines = [delta('答'), stopLine];
    relay.snapshots = [
      {'status': 'done', 'content': '答', 'reasoning': ''},
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(client);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    // 第一次不带 max_tokens，被拒后第二次带上上限值
    final payload = relay.lastChatPayload!['payload'] as Map<String, dynamic>;
    expect(payload['max_tokens'], 131072);

    await relay.stop();
  });

  test('中转模式：取消会通知服务端停止任务', () async {
    final relay = FakeRelay();
    relay.chatLines = [delta('慢慢写')];
    relay.holdChat = Completer<void>();
    relay.snapshots = [
      {'status': 'running', 'content': '慢慢写', 'reasoning': ''},
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final future = sendViaRelay(client);
    // 等拿到任务号后再取消（最多等 3 秒，避免卡死时误报超时）
    var waitedMs = 0;
    while (client.activeJobId == null && waitedMs < 3000) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waitedMs += 10;
    }
    expect(client.activeJobId, 'job-1');
    client.cancel();
    await future;
    // 取消请求是异步发出的，给它一点时间
    for (var i = 0; i < 50 && relay.cancelRequests.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(relay.cancelRequests, ['/v1/jobs/job-1/cancel']);

    await relay.stop();
  });

  test('resumeJob：App 重开后补齐没看完的回答', () async {
    final relay = FakeRelay();
    relay.snapshots = [
      {
        'status': 'done',
        'content': '服务器上已经写完的回答',
        'reasoning': '思考过程',
        'sources': [
          {'title': 'T', 'url': 'https://b.example'},
        ],
      },
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    var content = '';
    var reasoning = '';
    var sources = <ChatSource>[];
    var done = false;
    String? error;
    await client.resumeJob(
      jobId: 'job-1',
      onSnapshot: (RemoteSnapshot snap) {
        reasoning = snap.reasoning;
        content = snap.content;
        sources = snap.sources;
      },
      onDone: () => done = true,
      onError: (e) => error = e,
    );

    expect(error, isNull);
    expect(done, isTrue);
    expect(content, '服务器上已经写完的回答');
    expect(reasoning, '思考过程');
    expect(sources.single.title, 'T');

    await relay.stop();
  });

  test('resumeJob：未启用中转时直接提示', () async {
    final client = DeepSeekClient(useRelay: false);
    String? error;
    await client.resumeJob(
      jobId: 'job-x',
      onSnapshot: (_) {},
      onDone: () {},
      onError: (e) => error = e,
    );
    expect(error, contains('未启用中转服务器'));
  });

  test('Search / Fetch 地址：直连与中转各自拼接正确', () {
    final direct = DeepSeekClient(baseUrl: 'https://api.deepseek.com');
    expect(
      direct.toolsEndpointUrl('search'),
      'https://api.deepseek.com/v1/tools/search',
    );

    final anthropicBase = DeepSeekClient(
      baseUrl: 'https://api.deepseek.com/anthropic',
    );
    expect(
      anthropicBase.toolsEndpointUrl('fetch'),
      'https://api.deepseek.com/v1/tools/fetch',
    );

    final relay = DeepSeekClient(
      relayBaseUrl: 'https://relay.example:51888/',
      useRelay: true,
    );
    expect(
      relay.toolsEndpointUrl('search'),
      'https://relay.example:51888/v1/tools/search',
    );
  });

  test('中转模式：工具循环由服务端执行，客户端只收一条流', () async {
    final relay = FakeRelay();
    // 服务端会把中间轮的终止事件扣下，工具执行完再把最终轮追加到同一条流里；
    // 这里直接模拟“合并后”的流：中间工具事件 + 最终文本 + 唯一终止事件。
    relay.chatLines = [
      sse({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      }),
      sse({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': '先想一下'},
      }),
      delta('我先搜索一下。'),
      sse({
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_search_tool_result',
          'content': [
            {'title': '服务端搜索', 'url': 'https://server.example/a'},
          ],
        },
      }),
      toolUseStart(2, 'tool-1', 'search'),
      toolArgsDelta(2, '{"query":"DeepSeek '),
      toolArgsDelta(2, '搜索"}'),
      blockStop(2),
      sse({
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
      }),
      delta('根据搜索结果，DeepSeek 官网是 https://www.deepseek.com。'),
      stopLine,
    ];
    relay.snapshots = [
      {
        'status': 'done',
        'content': '我先搜索一下。根据搜索结果，DeepSeek 官网是 https://www.deepseek.com。',
        'reasoning': '先想一下',
        'stored_message_id': 42,
        'result_ready': true,
      },
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      relayToken: 'relay-token-1',
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(
      client,
      conversationId: 7,
      webSearch: true,
    );

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(
      result['content'],
      '我先搜索一下。根据搜索结果，DeepSeek 官网是 https://www.deepseek.com。',
    );
    // 客户端只发一次 /v1/chat；工具由服务端执行
    expect(relay.chatPayloads.length, 1);
    expect(relay.chatPayloads.single['conversation_id'], 7);
    expect(relay.toolRequests, isEmpty);
    expect((result['messageIds'] as List).last, 42);

    final payload = relay.chatPayloads.single['payload'] as Map<String, dynamic>;
    final tools = payload['tools'] as List;
    // 全家桶：联网搜索由上游服务端执行，客户端不再声明 search / fetch 函数工具
    expect(tools, [
      {'type': 'deepseek_web_search', 'name': 'deepseek_web_search'},
      {'type': 'deepseek_read_url', 'name': 'deepseek_read_url'},
    ]);

    final sources = result['eventSources'] as List<ChatSource>;
    expect(
      sources.map((s) => s.url),
      contains('https://server.example/a'),
    );

    await relay.stop();
  });

  test('中转模式：responses 协议的工具循环也由服务端执行', () async {
    final relay = FakeRelay();
    relay.chatLines = [
      sse({'type': 'response.reasoning_text.delta', 'delta': '先想一下'}),
      sse({
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {
          'type': 'function_call',
          'id': 'fc_1',
          'call_id': 'call_1',
          'name': 'fetch',
          'arguments': '',
        },
      }),
      sse({
        'type': 'response.function_call_arguments.delta',
        'item_id': 'fc_1',
        'delta': '{"url":"https://example.com/a"}',
      }),
      sse({'type': 'response.output_text.delta', 'delta': '我去抓取原文。'}),
      sse({'type': 'response.output_text.delta', 'delta': '文章标题：示例文章'}),
      sse({
        'type': 'response.completed',
        'response': {'output': []},
      }),
    ];
    relay.snapshots = [
      {
        'status': 'done',
        'content': '我去抓取原文。文章标题：示例文章',
        'reasoning': '先想一下',
        'stored_message_id': 43,
        'result_ready': true,
      },
    ];
    await relay.start();
    final client = DeepSeekClient(
      relayBaseUrl: relay.baseUrl,
      useRelay: true,
      client: http.Client(),
    );

    final result = await sendViaRelay(
      client,
      conversationId: 7,
      webSearch: true,
      protocol: ApiProtocol.responses,
    );

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['content'], '我去抓取原文。文章标题：示例文章');
    expect((result['messageIds'] as List).last, 43);
    expect(relay.chatPayloads.length, 1);
    expect(relay.chatPayloads.single['conversation_id'], 7);
    expect(relay.toolRequests, isEmpty);

    final payload = relay.chatPayloads.single['payload'] as Map<String, dynamic>;
    final tools = payload['tools'] as List;
    // Responses 协议只要 type，不带 name
    expect(tools, [
      {'type': 'deepseek_web_search'},
      {'type': 'deepseek_read_url'},
    ]);

    await relay.stop();
  });

  test('直连模式：联网搜索由上游服务端执行，客户端只发一次请求', () async {
    final relay = FakeRelay();
    // 官方全家桶：模型自己搜，搜索结果以 server_tool_use + web_search_tool_result
    // 事件流回，客户端不需要执行任何函数工具。
    relay.chatLines = [
      sse({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'server_tool_use',
          'id': 'srvtoolu_s_00_1',
          'name': 'deepseek_web_search',
          'input': {
            'action': 'search',
            'queries': ['DeepSeek V4.1'],
          },
          'kind': 'search',
        },
      }),
      sse({
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_search_tool_result',
          'tool_use_id': 'srvtoolu_s_00_1',
          'content': [
            {
              'type': 'web_search_result',
              'title': '官方更新日志',
              'url': 'https://api-docs.deepseek.com/updates',
              'snippet': '全家桶应用 API 已发布',
              'site_name': 'DeepSeek',
            },
          ],
          'kind': 'search',
        },
      }),
      delta('搜完了，这是最终回答'),
      stopLine,
    ];
    await relay.start();
    final client = DeepSeekClient(
      baseUrl: relay.baseUrl,
      client: http.Client(),
    );

    final result = await sendViaRelay(client, webSearch: true);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['content'], '搜完了，这是最终回答');
    // 服务端自己完成搜索：只有一次请求，没有额外的工具调用请求
    expect(relay.chatPayloads.length, 1);
    expect(relay.toolRequests, isEmpty);

    // 直连模式下 chatPayloads 存的就是请求体本身
    final payload = relay.chatPayloads.single;
    expect(payload['tools'], [
      {'type': 'deepseek_web_search', 'name': 'deepseek_web_search'},
      {'type': 'deepseek_read_url', 'name': 'deepseek_read_url'},
    ]);

    await relay.stop();
  });

  test('联网搜索：声明 read_url，来源从服务端结果里解析出来', () async {
    final server = FakeRelay();
    server.chatLines = [
      sse({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'server_tool_use',
          'id': 'srvtoolu_rl_00_1',
          'name': 'deepseek_read_url',
          'input': {'action': 'read_link', 'url': 'https://example.com/a'},
          'kind': 'read_link',
        },
      }),
      sse({
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_fetch_tool_result',
          'tool_use_id': 'srvtoolu_rl_00_1',
          'content': {
            'type': 'web_fetch_result',
            'url': 'https://example.com/a',
            'content': {
              'type': 'document',
              'source': {
                'type': 'text',
                'media_type': 'text/plain',
                'data': '',
              },
              'title': '示例文章',
            },
            'published_at': null,
          },
          'kind': 'read_link',
          'signature': 'sig-1',
        },
      }),
      delta('直连模式的最终回答'),
      stopLine,
    ];
    await server.start();
    final client = DeepSeekClient(
      baseUrl: server.baseUrl,
      client: http.Client(),
    );

    final result = await sendViaRelay(client, webSearch: true);

    expect(result['error'], isNull);
    expect(result['done'], isTrue);
    expect(result['content'], '直连模式的最终回答');
    expect(server.chatPayloads.length, 1);
    expect(server.toolRequests, isEmpty);

    await server.stop();
  });
}
