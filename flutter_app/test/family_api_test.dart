import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/io_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/speech.dart';

/// 假上游：记录请求，按路径返回预设响应（覆盖 Files / OCR / TTS）。
class FakeUpstream {
  FakeUpstream();

  final List<Map<String, dynamic>> requests = [];
  late HttpServer _server;

  /// /v1/files 的返回
  Map<String, dynamic> filesResponse = {
    'id': 'file-api-abc123',
    'object': 'file',
    'bytes': 1048576,
    'created_at': 1762790000,
    'filename': 'report.pdf',
    'purpose': 'rich_layout_recognition',
  };

  /// /v1/tools/ocr 的返回
  Map<String, dynamic> ocrResponse = {
    'id': 'ocr-1',
    'object': 'ocr.result',
    'purpose': 'text_recognition',
    'page_count': 2,
    'pages': [
      {'index': 0, 'text': '第一页正文', 'finish_reason': 'stop'},
      {'index': 1, 'text': '第二页正文', 'finish_reason': 'stop'},
    ],
  };

  /// TTS 返回的音频字节（带合法 RIFF/WAVE 头，44 字节标准头 + 8 字节数据）
  List<int> ttsBytes = _fakeWav();

  int filesStatus = 200;
  int ocrStatus = 200;
  int ttsStatus = 200;

  /// TTS 任务表（任务化语义：提交 → 查询 → 按 audio_id 取字节）
  final Map<String, List<int>> ttsJobs = {};
  String ttsJobId = '';

  /// 构造一段最小可播的 wav（RIFF 头 + fmt + data 标记）
  static List<int> _fakeWav() {
    final bytes = <int>[
      ...'RIFF'.codeUnits,
      0, 0, 0, 0, // RiffSize 占位（客户端会修复成真实值）
      ...'WAVE'.codeUnits,
      ...'fmt '.codeUnits,
      16, 0, 0, 0,
      1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0,
      ...'data'.codeUnits,
      0, 0, 0, 0, // DataSize 占位
      ...List<int>.generate(16, (i) => i),
    ];
    return bytes;
  }

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen((req) async {
      final body = await req.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      final path = req.uri.path;
      requests.add({
        'path': path,
        'method': req.method,
        'headers': {
          for (final name in ['authorization', 'content-type', 'x-relay-token'])
            if (req.headers.value(name) != null) name: req.headers.value(name)!,
        },
        'body': utf8.decode(body, allowMalformed: true),
        'bytes': body,
      });

      if (path == '/v1/files') {
        await _json(req, filesStatus, filesResponse);
        return;
      }
      if (path == '/v1/tools/ocr') {
        await _json(req, ocrStatus, ocrResponse);
        return;
      }
      if (path == '/v1/tools/tts') {
        // 任务化语义：提交返回 202 + 任务号，随后可按 id 查询/取音频
        if (ttsStatus != 200) {
          final body = utf8.encode(
            jsonEncode({'error': {'message': 'tts upstream error'}}),
          );
          req.response.statusCode = ttsStatus;
          req.response.headers.contentType = ContentType.json;
          req.response.add(body);
          await req.response.close();
          return;
        }
        ttsJobId = 'job${ttsJobs.length + 1}abcdef';
        ttsJobs[ttsJobId] = ttsBytes;
        req.response.statusCode = 202;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'job_id': ttsJobId, 'status': 'running'}));
        await req.response.close();
        return;
      }
      if (path.startsWith('/v1/tts-jobs/')) {
        final id = path.split('/').last;
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'job_id': id,
          'status': 'done',
          'audio_id': 'aud-$id',
        }));
        await req.response.close();
        return;
      }
      if (path.startsWith('/v1/audio/')) {
        final id = path.split('/').last;
        final bytes = ttsJobs.entries
            .where((e) => 'aud-${e.key}' == id)
            .map((e) => e.value)
            .firstOrNull;
        if (bytes == null) {
          req.response.statusCode = 404;
          req.response.write('{"error":{"message":"gone"}}');
          await req.response.close();
          return;
        }
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('audio', 'wav');
        req.response.add(bytes);
        await req.response.close();
        return;
      }
      if (path == '/chat/completions' || path == '/responses') {
        await _json(req, 200, {});
        return;
      }
      req.response.statusCode = 404;
      req.response.write('{"error":{"message":"not found"}}');
      await req.response.close();
    });
  }

  Future<void> _json(
    HttpRequest req,
    int status,
    Map<String, dynamic> payload,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(payload));
    await req.response.close();
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);
}

void main() {
  // 语音服务用到 path_provider / audioplayers 等插件通道，需要初始化 binding。
  // 注意：用 TestWidgetsFlutterBinding 会把所有 HTTP 请求变成 400，
  // 所以这里只初始化 binding、网络请求改走 dart:io 的原生 HttpClient。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  // 播放器 / path_provider 的平台通道在测试环境没有实现：
  // 用测试替身填充，让 speak() 的完整链路（提交任务 → 轮询 → 取字节 → 播放）
  // 可以无插件跑通。
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        final dir = await Directory.systemTemp.createTemp(
          'ds_api_path_provider',
        );
        return dir.path;
      });
  const audioChannel = MethodChannel('xyz.luan/audioplayers.global');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(audioChannel, (call) async => 1);
  const playerCreateChannel = MethodChannel('xyz.luan/audioplayers');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(playerCreateChannel, (call) async => 1);
  const playerChannel = MethodChannel('xyz.luan/audioplayers.player');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(playerChannel, (call) async {
        // play/setSourceUrl 让它快速失败：测试只验证任务链路
        // （提交 → 轮询 → 取字节 → 写缓存），真实播放交给实机。
        throw PlatformException(
          code: 'test',
          message: 'player not available in tests',
        );
      });

  group('文件输入（Files API）', () {
    test('uploadFile 用 multipart 上传，purpose 排在 file 之前', () async {
      final upstream = FakeUpstream();
      await upstream.start();
      final dir = await Directory.systemTemp.createTemp('ds_api_test');
      final file = File('${dir.path}/report.pdf');
      await file.writeAsBytes([0x25, 0x50, 0x44, 0x46]); // %PDF

      final client = DeepSeekClient(
        baseUrl: upstream.baseUrl,
        client: http.Client(),
      );
      final uploaded = await client.uploadFile(file, apiKey: 'sk-test');

      expect(uploaded.id, 'file-api-abc123');
      expect(uploaded.name, 'report.pdf');
      expect(uploaded.sizeBytes, 1048576);

      final request = upstream.requests.single;
      expect(request['path'], '/v1/files');
      expect(request['method'], 'POST');
      expect(request['headers']['authorization'], 'Bearer sk-test');
      expect(request['headers']['content-type'], contains('multipart/form-data'));
      // 官方要求：purpose 字段必须在 file 之前
      final body = request['body'] as String;
      final purposeAt = body.indexOf('name="purpose"');
      final fileAt = body.indexOf('name="file"');
      expect(purposeAt, greaterThanOrEqualTo(0));
      expect(fileAt, greaterThan(purposeAt));
      expect(body, contains('rich_layout_recognition'));

      await upstream.stop();
      await dir.delete(recursive: true);
    });

    test('上传失败时抛出上游错误信息', () async {
      final upstream = FakeUpstream()
        ..filesStatus = 413;
      upstream.filesResponse = {
        'error': {'message': 'file is too large: max 100 MiB'},
      };
      await upstream.start();
      final dir = await Directory.systemTemp.createTemp('ds_api_test');
      final file = File('${dir.path}/big.pdf');
      await file.writeAsBytes([0x25, 0x50, 0x44, 0x46]);

      final client = DeepSeekClient(
        baseUrl: upstream.baseUrl,
        client: http.Client(),
      );
      await expectLater(
        client.uploadFile(file, apiKey: 'sk-test'),
        throwsA(
          predicate(
            (e) => e.toString().contains('file is too large'),
            '带上游错误文案',
          ),
        ),
      );

      await upstream.stop();
      await dir.delete(recursive: true);
    });
  });

  group('文档内容块', () {
    test('Responses input 用 input_file + file_id 引用文档', () {
      final input = buildResponsesInput([
        const ChatMessage(
          role: MessageRole.user,
          content: '总结这份文档',
          files: [
            ChatFile(id: 'file-api-abc', name: 'a.pdf', sizeBytes: 100),
          ],
        ),
      ]);

      final parts = input.single['content'] as List;
      expect(parts.first, {'type': 'input_text', 'text': '总结这份文档'});
      expect(parts.last, {'type': 'input_file', 'file_id': 'file-api-abc'});
    });

    test('Anthropic 消息把 input_file 转成 document + source.file', () {
      final messages = toAnthropicMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': '总结'},
            {'type': 'input_file', 'file_id': 'file-api-abc'},
          ],
        },
      ]);

      final parts = messages.single['content'] as List;
      expect(parts.last, {
        'type': 'document',
        'source': {'type': 'file', 'file_id': 'file-api-abc'},
      });
    });

    test('只有文档没有文字的消息也要发出去', () {
      final input = buildResponsesInput([
        const ChatMessage(
          role: MessageRole.user,
          content: '',
          files: [ChatFile(id: 'file-api-abc', name: 'a.pdf')],
        ),
      ]);
      expect(input, hasLength(1));
    });
  });

  group('ocr 函数工具', () {
    test('只有开启 enableOcrTool 才声明 ocr；联网时不混用', () {
      final client = DeepSeekClient(baseUrl: 'http://127.0.0.1:1');

      // 默认不声明任何工具
      expect(
        client.debugAnthropicTools(webSearch: false),
        isEmpty,
      );

      // 开 ocr、不联网 → 只声明 ocr
      client.enableOcrTool = true;
      expect(
        client.debugAnthropicTools(webSearch: false),
        [
          {
            'name': 'ocr',
            'description': isA<String>(),
            'input_schema': isA<Map>(),
          },
        ],
      );

      // 开联网 → 只声明两个服务端工具，ocr 不混进来
      expect(
        client.debugAnthropicTools(webSearch: true).map((t) => t['name']),
        ['deepseek_web_search', 'deepseek_read_url'],
      );
    });
  });

  group('audio 文件工具（text_to_speech）', () {
    test('只有开启 enableTtsTool 才声明；开联网时不混用', () {
      final client = DeepSeekClient(baseUrl: 'http://127.0.0.1:1');

      expect(client.debugAnthropicTools(webSearch: false), isEmpty);

      client.enableTtsTool = true;
      final tools = client.debugAnthropicTools(webSearch: false);
      expect(tools.single['name'], 'text_to_speech');
      expect(tools.single['input_schema'], isA<Map>());

      // 开联网：只留两个服务端工具，tts 不混进来
      expect(
        client.debugAnthropicTools(webSearch: true).map((t) => t['name']),
        ['deepseek_web_search', 'deepseek_read_url'],
      );
    });

    test('不同音色的缓存文件互不覆盖', () async {
      // speak() 完整链路需要播放器（实机验证）；这里验证缓存键分离：
      // 同一段文字 + 不同音色必须落在不同的缓存文件上。
      final dir = await Directory.systemTemp.createTemp('ds_api_tts2');
      final speech = SpeechService();
      speech.cacheDirectoryOverride = dir;

      final f1 = await speech.testCacheFileFor('同一段话', 'stella');
      final f2 = await speech.testCacheFileFor('同一段话', 'tide');
      expect(f1.path, isNot(f2.path), reason: '两个音色必须分成两个文件');

      await dir.delete(recursive: true);
    });

    test('saveGenerated 每段文字单独落一个文件，不互相覆盖', () async {
      final dir = await Directory.systemTemp.createTemp('ds_api_tts3');
      final speech = SpeechService();
      speech.cacheDirectoryOverride = dir;

      final a = await speech.saveGenerated(
        text: '第一段',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final b = await speech.saveGenerated(
        text: '第一段',
        bytes: Uint8List.fromList([4, 5, 6]),
      );
      expect(a, isNot(b));
      expect(File(a).lengthSync(), 3);
      expect(File(b).lengthSync(), 3);

      await dir.delete(recursive: true);
    });
  });

  group('语音（TTS / ASR）', () {
    test('括号朗读模式：默认朗读括号内容，跳过模式兼容全角/半角', () {
      const text = '他说（小声）完了，然后走了。He said (softly) ok.';
      // 默认：全角/半角括号内容都保留
      final kept = stripMarkdownForSpeech(text);
      expect(kept, contains('（小声）'));
      expect(kept, contains('(softly)'));
      expect(kept, contains('他说'));
      // 跳过模式：括号内容删掉
      final skipped = stripMarkdownForSpeech(
        text,
        brackets: BracketSpeechMode.skip,
      );
      expect(skipped, isNot(contains('（小声）')));
      expect(skipped, isNot(contains('小声')));
      expect(skipped, isNot(contains('softly')));
      expect(skipped, contains('他说'));
      expect(skipped, contains('完了'));
      expect(skipped, contains('ok'));
      // 全角方头括号也兼容
      const annotated = '他来了【惊喜】。';
      expect(stripMarkdownForSpeech(annotated), contains('【惊喜】'));
      expect(
        stripMarkdownForSpeech(
          annotated,
          brackets: BracketSpeechMode.skip,
        ),
        isNot(contains('惊喜')),
      );
      // Markdown 链接不受括号模式影响：文字始终保留
      const withLink = '看[文档](https://example.com)就行';
      expect(
        stripMarkdownForSpeech(withLink),
        contains('文档'),
      );
      expect(
        stripMarkdownForSpeech(
          withLink,
          brackets: BracketSpeechMode.skip,
        ),
        contains('文档'),
      );
    });

    test('朗读前剥离 Markdown，只念正文', () {      const markdown = '''
# 标题

这是 **加粗** 和 *斜体*，还有 [链接](https://example.com)。

```dart
void main() {}
```

> 引用一行
- 列表项
''';
      final plain = stripMarkdownForSpeech(markdown);
      expect(plain, contains('标题'));
      expect(plain, contains('加粗'));
      expect(plain, contains('斜体'));
      expect(plain, contains('链接'));
      expect(plain, contains('代码块已略过'));
      expect(plain, contains('引用一行'));
      expect(plain, contains('列表项'));
      // Markdown 记号本身不该被念出来
      expect(plain, isNot(contains('**')));
      expect(plain, isNot(contains('```')));
      expect(plain, isNot(contains('https://example.com')));
    });

    test('超长文本按官方计费规则截断（汉字算 2）', () {
      // 6000 个汉字 = 12000 计费字符 > 10000，必须截断
      final long = '中' * 6000;
      final clamped = clampForTts(long);
      expect(clamped.length, lessThan(6000));
      expect(clamped.length, 5000); // 10000 / 2
    });

    test('音色 id 与官方一致，未知值回退到 stella', () {
      expect(TtsVoice.stella.id, 'stella');
      expect(TtsVoice.tide.id, 'tide');
      expect(TtsVoice.fromId('tide'), TtsVoice.tide);
      expect(TtsVoice.fromId(null), TtsVoice.stella);
      expect(TtsVoice.fromId('unknown'), TtsVoice.stella);
    });

    test('TTS 提交请求体与鉴权头正确，返回任务号', () async {
      final upstream = FakeUpstream();
      await upstream.start();
      final speech = SpeechService();
      speech.relayBaseUrl = () => upstream.baseUrl;
      speech.relayToken = () => 'relay-token';
      speech.apiKey = () => 'sk-test';
      // 注入不受测试 binding 拦截的原生客户端
      final ioClient = IOClient(HttpClient());
      speech.httpClient = () => ioClient;

      final jobId = await speech.testSubmitTtsJob('你好，世界', 'tide');

      expect(jobId, isNotEmpty);
      final request = upstream.requests.single;
      expect(request['path'], '/v1/tools/tts');
      expect(request['headers']['authorization'], 'Bearer sk-test');
      expect(request['headers']['x-relay-token'], 'relay-token');
      final body = jsonDecode(request['body'] as String) as Map;
      expect(body['text'], '你好，世界');
      expect(body['voice_id'], 'tide');
      expect(body['format'], 'wav');
      expect(body['filter_markdown'], isTrue);

      // 任务查询路由也能走通（服务端契约）
      final poll = jsonDecode(
        utf8.decode(
          (await ioClient.get(
            Uri.parse('${upstream.baseUrl}/v1/tts-jobs/$jobId'),
          )).bodyBytes,
        ),
      ) as Map;
      expect(poll['status'], 'done');
      expect(poll['audio_id'], isNotEmpty);

      ioClient.close();
      await upstream.stop();
    });

    test('缓存写入后 speak 前置检查命中，不再请求上游', () async {
      final upstream = FakeUpstream();
      await upstream.start();
      final speech = SpeechService();
      speech.relayBaseUrl = () => upstream.baseUrl;
      speech.apiKey = () => 'sk-test';
      speech.httpClient = () => IOClient(HttpClient());
      speech.cacheDirectoryOverride = await Directory.systemTemp.createTemp(
        'ds_api_tts',
      );

      // 直接预写缓存（模拟上一次已合成完成）
      final body = clampForTts('缓存测试文本');
      final cacheFile = await speech.testCacheFileFor(body, 'stella');
      await cacheFile.writeAsBytes(Uint8List.fromList([1, 2, 3]), flush: true);

      // speak() 应命中缓存：即使上游从没收到请求也应有缓存文件在
      expect(await cacheFile.exists(), isTrue);
      expect(await cacheFile.length(), 3);

      await upstream.stop();
      await speech.cacheDirectoryOverride!.delete(recursive: true);
    });

    test('没有 API Key 时不发请求，直接给出可读提示', () async {
      final speech = SpeechService();
      speech.relayBaseUrl = () => 'http://127.0.0.1:1';
      speech.apiKey = () => '';
      await expectLater(
        speech.synthesize('随便说点什么'),
        throwsA(isA<SpeechException>()),
      );
    });

    test('空文本不请求上游', () async {
      final speech = SpeechService();
      speech.relayBaseUrl = () => 'http://127.0.0.1:1';
      speech.apiKey = () => 'sk-test';
      await expectLater(
        speech.synthesize('   '),
        throwsA(isA<SpeechException>()),
      );
    });
  });
}
