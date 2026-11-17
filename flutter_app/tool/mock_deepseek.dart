// ignore_for_file: avoid_print
// 本地 mock：模拟 DeepSeek Responses API 的 SSE 流，用于端到端 UI 验证。
// 用法：dart run tool/mock_deepseek.dart <port>
import 'dart:convert';
import 'dart:io';

String _sse(String type, [Map<String, dynamic> extra = const {}]) =>
    'data: ${jsonEncode({'type': type, ...extra})}\n\n';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args.first) : 8081;
  final server = await HttpServer.bind('0.0.0.0', port);
  print('mock DeepSeek /responses listening on 0.0.0.0:$port');

  await for (final req in server) {
    if (req.method == 'POST' && req.uri.path == '/responses') {
      final body = await utf8.decodeStream(req);
      print('REQ model=${jsonDecode(body)['model']} webSearch=${jsonDecode(body)['tools'] != null}');

      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write(_sse('response.created'));
      req.response.write(_sse('response.reasoning_text.delta', {
        'delta': '嗯，用户发来了一句简单的问候“你好”。\n\n',
      }));
      req.response.write(_sse('response.reasoning_text.delta', {
        'delta': '这是一个非常基础的社交开场白，没有任何附加信息或具体问题。\n\n想好了用热情但简洁的语气回复，先以问候开场，再引导用户表达具体需求。',
      }));
      req.response.write(_sse('response.reasoning_text.done', {
        'delta': '嗯，用户发来了一句简单的问候“你好”。这是一个非常基础的社交开场白。',
      }));
      req.response.write(_sse('response.output_text.delta', {
        'delta': '你好！很高兴见到你。😊\n\n',
      }));
      req.response.write(_sse('response.output_text.delta', {
        'delta': '有什么我可以帮你的吗？无论是解答问题、聊聊日常，还是需要一些建议，我都乐意陪你聊聊。',
      }));
      req.response.write(_sse('response.output_text.done', {
        'delta': '你好！很高兴见到你。😊\n\n有什么我可以帮你的吗？',
      }));
      req.response.write(_sse('response.completed'));
      await req.response.close();
    } else {
      req.response.statusCode = 404;
      await req.response.close();
    }
  }
}
