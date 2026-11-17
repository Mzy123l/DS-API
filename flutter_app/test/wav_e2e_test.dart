// WAV 播放链路的端到端断言（自包含，不依赖外部服务）：
//
// 假上游返回一段**带 RIFF 头但长度字段是占位值(0)**的 wav —— 这正是官方
// 流式合成的真实形态。客户端必须：
//   1. 用 audioplayers 播**本地文件**（不是原生 PCM 通道）；
//   2. 落盘的文件头是 RIFF....WAVE；
//   3. 长度字段被修成真实值（不是占位值 0），且自洽：
//        RiffSize == fileSize - 8
//        DataSize == fileSize - dataOffset - 4
//
// 历史缺陷：裸 PCM（无容器头）直接存成 .wav，播放器报「格式不对」。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

import 'package:ds_api/speech.dart';

/// 假上游：提交 → 查询 → 取音频，音频是一段长度字段为占位值的真 wav。
class FakeUpstream {
  final HttpServer _server;

  FakeUpstream._(this._server);

  static Future<FakeUpstream> start() async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final upstream = FakeUpstream._(server);
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/v1/tools/tts') {
        req.response.statusCode = 202;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'job_id': 'job1',
          'status': 'running',
        }));
        await req.response.close();
        return;
      }
      if (path.startsWith('/v1/tts-jobs/')) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'job_id': 'job1',
          'status': 'done',
          'audio_id': 'aud1',
        }));
        await req.response.close();
        return;
      }
      if (path.startsWith('/v1/audio/')) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('audio', 'wav');
        req.response.add(wavWithPlaceholderLengths());
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      req.response.write('{"error":{"message":"not found"}}');
      await req.response.close();
    });
    return upstream;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> stop() => _server.close(force: true);
}

/// 44 字节标准头 + 0.5 秒 24kHz/16bit/单声道 PCM。
/// RiffSize / DataSize 写成 0（占位值），模拟官方流式合成未写完长度的形态。
List<int> wavWithPlaceholderLengths() {
  const sampleRate = 24000;
  const dataLength = 24000; // 0.5 秒
  final data = <int>[];
  for (var i = 0; i < dataLength ~/ 2; i++) {
    final v = (12000 *
            math.sin(2 * math.pi * 440 * i / sampleRate))
        .round();
    data.add(v & 0xFF);
    data.add((v >> 8) & 0xFF);
  }
  final header = <int>[
    ...'RIFF'.codeUnits,
    0, 0, 0, 0, // RiffSize 占位
    ...'WAVE'.codeUnits,
    ...'fmt '.codeUnits,
    16, 0, 0, 0, // fmt chunk 长度
    1, 0, // PCM
    1, 0, // 单声道
    0xC0, 0x5D, 0, 0, // 24000 Hz (0x5DC0 小端)
    0x00, 0xBB, 0x01, 0, // byte rate = 48000 (0xBB80 小端)
    2, 0, // block align = 2
    16, 0, // 16 bit
    ...'data'.codeUnits,
    0, 0, 0, 0, // DataSize 占位
  ];
  return [...header, ...data];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final plays = <Map<dynamic, dynamic>>[];
  final eventSinks = <String, MockStreamHandlerEventSink>{};

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // path_provider：给一个临时目录
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      final dir = await Directory.systemTemp.createTemp('ds_api_wav');
      return dir.path;
    });

    // audioplayers 全局作用域
    const globalChannel = MethodChannel('xyz.luan/audioplayers.global');
    messenger.setMockMethodCallHandler(globalChannel, (call) async => 1);

    // audioplayers 播放器通道：记录播放请求；create 时按 playerId 挂事件通道
    const playerChannel = MethodChannel('xyz.luan/audioplayers');
    messenger.setMockMethodCallHandler(playerChannel, (call) async {
      final args = (call.arguments as Map?) ?? const {};
      final playerId = args['playerId'] as String?;
      if (call.method == 'create' && playerId != null) {
        messenger.setMockStreamHandler(
          EventChannel('xyz.luan/audioplayers/events/$playerId'),
          MockStreamHandler.inline(
            onListen: (Object? _, MockStreamHandlerEventSink sink) {
              eventSinks[playerId] = sink;
            },
          ),
        );
        return 1;
      }
      if (call.method == 'setSourceUrl') {
        plays.add(args);
        // 通知「准备完成」：播放器才继续往下走
        eventSinks[playerId]?.success({
          'event': 'audio.onPrepared',
          'value': true,
        });
        return 1;
      }
      return 1;
    });
  });

  test('朗读落盘的是带 RIFF 头的真 wav，长度字段真实且自洽', () async {
    final upstream = await FakeUpstream.start();
    final speech = SpeechService();
    speech.relayBaseUrl = () => upstream.baseUrl;
    speech.apiKey = () => 'sk-test';
    speech.httpClient = () => IOClient(HttpClient());
    final cacheDir = await Directory.systemTemp.createTemp('ds_api_wav_cache');
    speech.cacheDirectoryOverride = cacheDir;

    await speech.speak(key: 'k1', text: '端到端验证');

    // ---- 1. 播的是本地文件（DeviceFileSource），不是原生 PCM ----
    expect(plays, isNotEmpty, reason: '应当调用 audioplayers 播本地文件');
    final playedPath = plays.last['url'] as String;
    expect(plays.last['isLocal'], isTrue, reason: '必须播本地文件');
    print('[wav] 播放 url=$playedPath isLocal=${plays.last['isLocal']}');

    // ---- 2. 文件头 ----
    final bytes = await File(playedPath).readAsBytes();
    print('[wav] 大小 = ${bytes.length} 字节');
    print('[wav] 头 16 字节 = ${_hex(bytes.sublist(0, 16))}');
    print('[wav] ASCII = ${_ascii(bytes.sublist(0, 12))}');
    expect(bytes.sublist(0, 4), 'RIFF'.codeUnits, reason: '必须是 RIFF 头');
    expect(bytes.sublist(8, 12), 'WAVE'.codeUnits, reason: '必须是 WAVE 头');
    expect(bytes.length, greaterThan(44));

    // ---- 3. 长度字段真实且自洽 ----
    final riffSize = _u32(bytes, 4);
    final dataSize = _u32(bytes, 40);
    print('[wav] RiffSize = $riffSize（应 ${bytes.length - 8}）');
    print('[wav] DataSize = $dataSize（应 ${bytes.length - 44}）');
    expect(riffSize, isNot(0), reason: 'RiffSize 不能是占位值 0');
    expect(dataSize, isNot(0), reason: 'DataSize 不能是占位值 0');
    expect(riffSize, bytes.length - 8);
    expect(dataSize, bytes.length - 44);

    // data 段偏移自洽：'data' 标记在 36，长度字段在 40..44，data 从 44 开始
    final dataMarker = _findAscii(bytes, 'data');
    expect(dataMarker, 36, reason: '标准 44 字节头里 data 标记在 36');
    expect(dataSize, bytes.length - dataMarker - 8,
        reason: 'dataSize == fileSize - dataOffset - 4');

    // ---- 4. 采样参数自洽 ----
    final sampleRate = _u32(bytes, 24);
    final bits = _u16(bytes, 34);
    final channels = _u16(bytes, 22);
    print('[wav] fmt: rate=$sampleRate bits=$bits channels=$channels');
    expect(sampleRate, 24000);
    expect(bits, 16);
    expect(channels, 1);
    expect(dataSize % (bits ~/ 8 * channels), 0,
        reason: '数据长度必须是整帧的倍数');

    // ---- 5. 不得再走原生 PCM 通道 ----
    const pcmChannel = MethodChannel('com.deepseek.dsapi/pcm');
    final pcmCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pcmChannel, (call) async {
      pcmCalls.add(call);
      return null;
    });
    await speech.speak(key: 'k1', text: '端到端验证'); // 第二次：缓存命中
    expect(pcmCalls, isEmpty, reason: '不得再走原生 PCM 通道');

    await speech.dispose();
    await cacheDir.delete(recursive: true);
    await upstream.stop();
  });

  test('下载产物是带 RIFF 头的真 wav（长按下载能播放）', () async {
    final upstream = await FakeUpstream.start();
    final speech = SpeechService();
    speech.relayBaseUrl = () => upstream.baseUrl;
    speech.apiKey = () => 'sk-test';
    speech.httpClient = () => IOClient(HttpClient());
    final cacheDir = await Directory.systemTemp.createTemp('ds_api_wav_cache');
    speech.cacheDirectoryOverride = cacheDir;

    final path = await speech.download(
      text: '下载路径验证',
      fileName: 'answer.wav',
    );
    print('[wav-dl] 保存到 = $path');
    expect(path.endsWith('.wav'), isTrue);

    final bytes = await File(path).readAsBytes();
    print('[wav-dl] 大小 = ${bytes.length} 字节');
    print('[wav-dl] 头 16 字节 = ${_hex(bytes.sublist(0, 16))}');
    expect(bytes.sublist(0, 4), 'RIFF'.codeUnits,
        reason: '下载的文件必须有 RIFF 头，否则播放器报「格式不对」');
    expect(bytes.sublist(8, 12), 'WAVE'.codeUnits);

    final riffSize = _u32(bytes, 4);
    final dataSize = _u32(bytes, 40);
    print('[wav-dl] RiffSize = $riffSize（应 ${bytes.length - 8}）');
    print('[wav-dl] DataSize = $dataSize（应 ${bytes.length - 44}）');
    expect(riffSize, bytes.length - 8);
    expect(dataSize, bytes.length - 44);
    expect(dataSize, isNot(0), reason: '不能是占位值 0');

    await speech.dispose();
    await cacheDir.delete(recursive: true);
    await upstream.stop();
  });
}

int _u32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _u16(List<int> b, int o) => b[o] | (b[o + 1] << 8);

int _findAscii(List<int> b, String needle) {
  final codes = needle.codeUnits;
  for (var i = 0; i + codes.length <= b.length; i++) {
    var hit = true;
    for (var j = 0; j < codes.length; j++) {
      if (b[i + j] != codes[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');

String _ascii(List<int> b) =>
    b.map((v) => v >= 32 && v < 127 ? String.fromCharCode(v) : '.').join();
