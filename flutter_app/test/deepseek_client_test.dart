import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';

String _sse(String type, [Map<String, dynamic> extra = const {}]) =>
    'data: ${jsonEncode({'type': type, ...extra})}\n\n';

void main() {
  test('buildResponsesInput 拼接 user/assistant 与图片', () {
    final input = buildResponsesInput([
      const ChatMessage(role: MessageRole.user, content: '你好'),
      const ChatMessage(
        role: MessageRole.user,
        content: '',
        imageDataUrls: ['data:image/png;base64,AA'],
      ),
      const ChatMessage(role: MessageRole.assistant, content: '回答'),
      const ChatMessage(role: MessageRole.assistant, content: ''), // 占位应被跳过
    ]);
    expect(input.length, 3);
    expect(input[0]['content'], '你好');
    expect(input[1]['content'], isA<List<Map<String, dynamic>>>());
    expect(input[2]['role'], 'assistant');
  });

  test('用户正文里的 <system> 块被剥离，不当作普通文本发送', () {
    final input = buildResponsesInput([
      const ChatMessage(
        role: MessageRole.user,
        content: '<system>你是猫</system>\n你好',
      ),
      // 不在开头的标签按普通文本保留
      const ChatMessage(role: MessageRole.user, content: '普通 <system> 文本'),
      // 只有标签、没有正文：整条消息不应发给模型
      const ChatMessage(
        role: MessageRole.user,
        content: '<system>只设置提示词</system>',
      ),
    ]);
    expect(input.length, 2);
    expect(input[0]['content'], '你好');
    expect(input[1]['content'], '普通 <system> 文本');
  });

  test('Anthropic 请求把系统提示词放在顶层 system，而不是用户消息里', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    Map<String, dynamic>? seenPayload;
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seenPayload = jsonDecode(body) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('message_stop'));
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    )..systemPrompt = '你是猫';
    await client.send(
      input: buildResponsesInput(const [
        ChatMessage(
          role: MessageRole.user,
          content: '<system>你是猫</system>\n你好',
        ),
      ]),
      model: 'deepseek-flash',
      protocol: ApiProtocol.anthropic,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (_) {},
      onReasoningTimed: (_) {},
      onDone: () {},
      onError: (_) {},
    );

    expect(seenPayload!['system'], '你是猫');
    final messages = seenPayload!['messages'] as List;
    final first = messages.first as Map;
    expect(jsonEncode(first), isNot(contains('<system>')));
    expect(jsonEncode(messages), contains('你好'));
    await server.close(force: true);
  });

  test('Responses 请求把系统提示词放在 instructions，并剥离 <system> 标签', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    Map<String, dynamic>? seenPayload;
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seenPayload = jsonDecode(body) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('response.completed'));
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    )..systemPrompt = '你是猫';
    await client.send(
      input: buildResponsesInput(const [
        ChatMessage(
          role: MessageRole.user,
          content: '<system>你是猫</system>\n你好',
        ),
      ]),
      model: 'deepseek-flash',
      protocol: ApiProtocol.responses,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (_) {},
      onReasoningTimed: (_) {},
      onDone: () {},
      onError: (_) {},
    );

    expect(seenPayload!['instructions'], '你是猫');
    expect(jsonEncode(seenPayload!['input']), isNot(contains('<system>')));
    await server.close(force: true);
  });

  test('流式解析 reasoning/content，.done 不重复，思考用时正确', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('response.created'));
      req.response.write(
        _sse('response.reasoning_text.delta', {'delta': '思考1'}),
      );
      req.response.write(
        _sse('response.reasoning_text.delta', {'delta': '思考2'}),
      );
      req.response.write(_sse('response.output_text.delta', {'delta': '你好'}));
      req.response.write(_sse('response.output_text.delta', {'delta': '！'}));
      req.response.write(_sse('response.output_text.done', {'delta': '你好！'}));
      req.response.write(_sse('response.completed'));
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    );
    var reasoning = '';
    var content = '';
    int? ms;
    var done = false;
    String? error;

    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-v4-flash-vision-exp',
      protocol: ApiProtocol.responses,
      thinkingEnabled: true,
      reasoningEffort: 'high',
      apiKey: 'sk-test',
      onReasoningDelta: (d) => reasoning += d,
      onContentDelta: (d) => content += d,
      onReasoningTimed: (m) => ms = m,
      onDone: () => done = true,
      onError: (e) => error = e,
    );

    expect(error, isNull);
    expect(reasoning, '思考1思考2');
    expect(content, '你好！'); // .done 不再重复追加
    expect(ms, greaterThanOrEqualTo(0));
    expect(done, isTrue);

    await server.close(force: true);
  });

  test('response.completed 终止流式，onDone 仅触发一次且内容正确', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('response.output_text.delta', {'delta': '你好'}));
      req.response.write(_sse('response.completed'));
      // completed 之后的尾随数据应被客户端忽略（终止后停止解析）
      req.response.write(_sse('response.output_text.delta', {'delta': '不应出现'}));
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    );
    var content = '';
    var doneCount = 0;
    String? error;

    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-v4-flash-vision-exp',
      protocol: ApiProtocol.responses,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (d) => content += d,
      onReasoningTimed: (_) {},
      onDone: () => doneCount++,
      onError: (e) => error = e,
    );

    expect(error, isNull);
    expect(content, '你好'); // 尾随 delta 被忽略，不重复
    expect(doneCount, 1); // 终止 + 连接关闭不会重复触发

    await server.close(force: true);
  });

  test('流结束时最后一条 SSE 没有换行：最后一段增量仍要解析', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('response.output_text.delta', {'delta': '第一段'}));
      // 最后一条模拟上游/网络在尾随换行前断开
      req.response.write(
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': '最后一段'})}',
      );
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    );
    var content = '';
    var done = false;
    String? error;

    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-v4-flash-vision-exp',
      protocol: ApiProtocol.responses,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (d) => content += d,
      onReasoningTimed: (_) {},
      onDone: () => done = true,
      onError: (e) => error = e,
    );

    expect(error, isNull);
    expect(content, '第一段最后一段');
    expect(done, isTrue);

    await server.close(force: true);
  });

  test('toAnthropicMessages：文本/图片转换与同角色合并', () {
    final messages = toAnthropicMessages([
      {'role': 'user', 'content': '你好'},
      {
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': '看图'},
          {
            'type': 'input_image',
            'image_url': 'data:image/png;base64,AAAB',
            'detail': 'low',
          },
        ],
      },
      {'role': 'assistant', 'content': '回答'},
      {'role': 'assistant', 'content': ''}, // 空内容应被跳过
    ]);

    // 两条相邻 user 合并为一条，content 为两个文本块 + 一个图片块
    expect(messages.length, 2);
    expect(messages[0]['role'], 'user');
    final firstContent = messages[0]['content'] as List<Map<String, dynamic>>;
    expect(firstContent.length, 3);
    expect(firstContent[0], {'type': 'text', 'text': '你好'});
    expect(firstContent[2]['type'], 'image');
    expect(firstContent[2]['source'], {
      'type': 'base64',
      'media_type': 'image/png',
      'data': 'AAAB',
    });
    expect(messages[1]['role'], 'assistant');
  });

  test('Anthropic 端点流式解析：思维链/正文/搜索来源/完成', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? seenPath;
    Map<String, dynamic>? seenPayload;
    server.listen((req) async {
      seenPath = req.uri.path;
      final body = await utf8.decoder.bind(req).join();
      seenPayload = jsonDecode(body) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      void ev(String name, Map<String, dynamic> data) {
        req.response.write('event: $name\ndata: ${jsonEncode(data)}\n\n');
      }

      ev('message_start', {
        'type': 'message_start',
        'message': {'id': 'm1', 'role': 'assistant'},
      });
      ev('content_block_start', {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': ''},
      });
      ev('content_block_delta', {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': '先想一下'},
      });
      ev('content_block_start', {
        'type': 'content_block_start',
        'index': 1,
        'content_block': {
          'type': 'web_search_tool_result',
          'tool_use_id': 'c1',
          'content': [
            {
              'type': 'web_search_result',
              'title': '标题一',
              'url': 'https://example.com/a',
            },
            {
              'type': 'web_search_result',
              'title': '标题二',
              'url': 'https://example.com/b',
            },
          ],
        },
      });
      ev('content_block_delta', {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'text_delta', 'text': '答'},
      });
      ev('content_block_delta', {
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'text_delta', 'text': '案'},
      });
      ev('message_delta', {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
      });
      ev('message_stop', {'type': 'message_stop'});
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    );
    var reasoning = '';
    var content = '';
    var done = false;
    String? error;
    final sources = <ChatSource>[];

    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-flash',
      protocol: ApiProtocol.anthropic,
      thinkingEnabled: true,
      reasoningEffort: 'high',
      apiKey: 'sk-test',
      webSearch: true,
      onReasoningDelta: (d) => reasoning += d,
      onContentDelta: (d) => content += d,
      onReasoningTimed: (_) {},
      onSources: sources.addAll,
      onDone: () => done = true,
      onError: (e) => error = e,
    );

    expect(error, isNull);
    expect(reasoning, '先想一下');
    expect(content, '答案');
    expect(done, isTrue);
    expect(sources.map((s) => s.url), [
      'https://example.com/a',
      'https://example.com/b',
    ]);
    expect(sources.first.host, 'example.com');
    // 官方根地址走 /anthropic/v1/messages
    expect(seenPath, '/anthropic/v1/messages');
    // 不设回答上限：默认根本不发 max_tokens，长度由服务端决定
    expect(seenPayload!.containsKey('max_tokens'), isFalse);
    expect(seenPayload!['thinking'], {'type': 'enabled'});
    expect(seenPayload!['output_config'], {'effort': 'high'});
    // 全家桶：联网搜索用官方服务端工具 deepseek_web_search + deepseek_read_url
    final tools = seenPayload!['tools'] as List;
    expect(tools, [
      {'type': 'deepseek_web_search', 'name': 'deepseek_web_search'},
      {'type': 'deepseek_read_url', 'name': 'deepseek_read_url'},
    ]);

    await server.close(force: true);
  });

  test('带路径的 base 走 {base}/messages（本地网关场景）', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? seenPath;
    server.listen((req) async {
      seenPath = req.uri.path;
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write('data: ${jsonEncode({'type': 'message_stop'})}\n\n');
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      client: http.Client(),
    );
    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-flash',
      protocol: ApiProtocol.anthropic,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (_) {},
      onReasoningTimed: (_) {},
      onDone: () {},
      onError: (_) {},
    );

    expect(seenPath, '/v1/messages');
    await server.close(force: true);
  });

  test('服务端强制要求 max_tokens 时才补值重试，且成功后沿用', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final seen = <int?>[];
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      final maxTokens = jsonDecode(body)['max_tokens'] as int?;
      seen.add(maxTokens);
      if (maxTokens == null) {
        req.response.statusCode = 400;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'error': {'message': 'max_tokens: field required'},
          }),
        );
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      req.response.write(_sse('message_stop'));
      await req.response.close();
    });

    final client = DeepSeekClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      client: http.Client(),
    );
    var done = false;
    String? error;
    await client.send(
      input: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'deepseek-flash',
      protocol: ApiProtocol.anthropic,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (_) {},
      onReasoningTimed: (_) {},
      onDone: () => done = true,
      onError: (e) => error = e,
    );

    // 首选不发 max_tokens（不设上限），被服务端拒绝后才补上大值
    expect(seen, [null, 131072]);
    expect(error, isNull);
    expect(done, isTrue);

    // 后续请求直接沿用已探测到的取值，不再重复试探
    done = false;
    await client.send(
      input: [
        {'role': 'user', 'content': 'hi again'},
      ],
      model: 'deepseek-flash',
      protocol: ApiProtocol.anthropic,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: 'sk-test',
      onReasoningDelta: (_) {},
      onContentDelta: (_) {},
      onReasoningTimed: (_) {},
      onDone: () => done = true,
      onError: (e) => error = e,
    );
    expect(seen, [null, 131072, 131072]);
    expect(done, isTrue);

    await server.close(force: true);
  });
}
