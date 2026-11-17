/// 语音能力：TTS（朗读回答）与 ASR（语音输入）。
///
/// 官方接口（见 docs/family-api-contract.md）：
/// - `POST /v1/tools/tts`  JSON 进、音频字节出（wav）
/// - `POST /v1/tools/asr`  multipart 进、`{text, duration_ms}` 出
///
/// 两者都经中转服务代理，API Key 由客户端透传、服务端不落盘。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 官方音色（与 `voice_id` 一一对应）。
///
/// 目前官方只开放 `stella`（海星）。枚举保留多值形态，后续官方新增音色时
/// 直接加一项即可；界面只展示 [available] 里的音色，不会出现空选项。
enum TtsVoice {
  stella(id: 'stella', label: '海星', desc: '女声 · 默认'),
  tide(id: 'tide', label: '暗潮', desc: '男声');

  const TtsVoice({required this.id, required this.label, required this.desc});

  final String id;
  final String label;
  final String desc;

  /// 当前官方开放的音色（新增音色时改这里）。
  static const List<TtsVoice> available = [TtsVoice.stella];

  static TtsVoice fromId(String? id) {
    for (final v in values) {
      if (v.id == id) return v;
    }
    return TtsVoice.stella;
  }
}

/// TTS 单次请求的文本上限（官方：10000 个计费字符，汉字算 2）。
const int ttsMaxBilledChars = 10000;

/// 朗读时对括号内容的处理方式。
///
/// 官方客户端默认把括号内容也念出来；跳过括号是可选项
/// （补充说明念出来啰嗦的场景用），所以枚举以朗读为默认。
enum BracketSpeechMode {
  /// 保留括号内容一起朗读（默认）
  speak,

  /// 跳过括号内容
  skip,
}

/// 把正文压到可朗读的文本：去掉 Markdown 记号，按计费字符截断。
///
/// 官方 `filter_markdown` 只处理格式，不计长度；超长会直接 400，
/// 所以客户端先按「汉字 2 分、其他 1 分」的规则切到上限以内。
///
/// [brackets] 决定括号内容是保留（默认）还是删掉（跳过模式）。
String clampForTts(
  String text, {
  BracketSpeechMode brackets = BracketSpeechMode.speak,
}) {
  final plain = stripMarkdownForSpeech(text, brackets: brackets);
  var score = 0;
  final buffer = StringBuffer();
  for (final rune in plain.runes) {
    final char = String.fromCharCode(rune);
    // 与官方一致：汉字（含全角标点）算 2 个字符，其余算 1 个
    final cost = _isWideChar(rune) ? 2 : 1;
    if (score + cost > ttsMaxBilledChars) break;
    score += cost;
    buffer.write(char);
  }
  return buffer.toString().trim();
}

bool _isWideChar(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK 统一表意文字
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0x3000 && rune <= 0x303F) || // CJK 标点
    (rune >= 0xFF00 && rune <= 0xFFEF); // 全角字符

/// 朗读前去掉 Markdown 记号：代码块整体略过，只念正文。
///
/// [brackets] 决定括号内容是保留（默认）还是删掉（跳过模式）。
String stripMarkdownForSpeech(
  String text, {
  BracketSpeechMode brackets = BracketSpeechMode.speak,
}) {
  var out = text;
  // 先处理 Markdown 链接/图片：只保留文字。
  // 必须在括号处理之前——否则 `[链接](url)` 的 `[链接]` 会被当括号删掉。
  out = out.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  out = out.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (m) => m.group(1) ?? '',
  );
  // 括号内容：默认念出来；跳过模式才删（补充说明念出来啰嗦的场景）。
  // 兼容全角（）与半角 ()，以及【】、［］（中文里常见的强调/补注）。
  if (brackets == BracketSpeechMode.skip) {
    out = out.replaceAllMapped(
      RegExp(r'（[^）]*）|\([^)]*\)'),
      (_) => '',
    );
    out = out.replaceAllMapped(
      RegExp(r'【[^】]*】|［[^］]*］'),
      (_) => '',
    );
  }
  // 代码块不朗读（念出来没有意义）
  out = out.replaceAllMapped(
    RegExp(r'```[\s\S]*?```', multiLine: true),
    (_) => '（代码块已略过）',
  );
  // 行内代码保留内容
  out = out.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1) ?? '');
  // 标题、引用、列表符号
  out = out.replaceAllMapped(
    RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true),
    (_) => '',
  );
  out = out.replaceAllMapped(RegExp(r'^\s{0,3}>\s?', multiLine: true), (_) => '');
  out = out.replaceAllMapped(
    RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true),
    (_) => '',
  );
  // 强调与删除线（replaceAll 不解析 $1 分组，必须用 replaceAllMapped）
  out = out.replaceAllMapped(RegExp(r'(\*\*|__)(.*?)\1'), (m) => m[2] ?? '');
  out = out.replaceAllMapped(RegExp(r'(\*|_)(.*?)\1'), (m) => m[2] ?? '');
  out = out.replaceAllMapped(RegExp(r'~~(.*?)~~'), (m) => m[1] ?? '');
  // 表格分隔行
  out = out.replaceAllMapped(
    RegExp(r'^\s*\|?[\s:|-]{3,}\|?\s*$', multiLine: true),
    (_) => '',
  );
  out = out.replaceAll('|', ' ');
  // 折叠多余空行
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return out.trim();
}

/// TTS 请求结果：音频字节 + 容器格式（wav）。
class TtsAudio {
  const TtsAudio({required this.bytes, required this.format});

  final Uint8List bytes;

  /// `wav`（带 RIFF 头的容器）
  ///
  /// 历史上还有裸 `pcm`（无容器头，直接存成 .wav 会报「格式不对」），
  /// 那条路线已废弃，现在只产出 wav。
  final String format;
}

/// 语音服务：调用中转的 TTS / ASR 接口，并管理播放器与录音器。
///
/// 一个 App 实例共用一个 [SpeechService]（见 main.dart 的 Provider），
/// 保证同一时刻只有一条音频在播、一次录音在进行。
class SpeechService {
  /// 由 AppState 在设置变化时注入，指向当前生效的中转地址与口令。
  String Function()? relayBaseUrl;
  String Function()? relayToken;
  String Function()? apiKey;

  /// 注入的 HTTP 客户端（必须与其它请求共用同一个指纹校验客户端）。
  ///
  /// 中转服务用的是自签名证书，Dart 默认的 `http.post` 不认它，
  /// 会直接抛 `CERTIFICATE_VERIFY_FAILED`。所以这里不能用默认客户端，
  /// 要由 AppState 注入带 `badCertificateCallback` 指纹校验的那一个。
  http.Client? Function()? httpClient;

  /// 当前会话的括号朗读模式（由 AppState 按会话切换，默认朗读括号内容）。
  BracketSpeechMode bracketMode = BracketSpeechMode.speak;

  /// 播放器与录音器都按需创建：构造 [SpeechService] 时不碰平台通道，
  /// 这样在没有音频插件的环境（单元测试）里也能正常构造。
  AudioPlayer? _playerInstance;

  AudioPlayer get _player => _playerInstance ??= AudioPlayer();

  AudioRecorder? _recorderInstance;

  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();

  /// 实际发请求用的客户端：优先用注入的（带证书指纹校验），
  /// 没注入时才退回默认客户端（例如单元测试）。
  late final http.Client _fallbackClient = http.Client();

  http.Client get _client => httpClient?.call() ?? _fallbackClient;

  /// 当前正在播放的回答标识（由调用方给，例如消息 id + 索引）
  String? _playingKey;
  String? get playingKey => _playingKey;

  /// 当前播放状态变化时通知界面刷新
  final ValueNotifier<SpeechPlaybackState> playback =
      ValueNotifier<SpeechPlaybackState>(SpeechPlaybackState.idle);

  /// 临时音频文件目录（播放与「下载」都落在这里）
  Directory? _cacheDir;

  /// 缓存目录覆盖：测试或特殊部署可指定固定目录，绕过 path_provider。
  Directory? cacheDirectoryOverride;

  /// 正在录音的临时文件路径
  String? _recordingPath;

  bool get isRecording => _recordingPath != null;

  // ------------------------------------------------------------------ 地址

  String get _base {
    final raw = relayBaseUrl?.call().trim() ?? '';
    if (raw.isEmpty) return '';
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  Map<String, String> get _headers => {
    if ((relayToken?.call() ?? '').isNotEmpty)
      'x-relay-token': relayToken!.call(),
  };

  /// TTS / ASR 都走中转（直连模式下也能用：地址回退到官方 API）。
  Uri _endpoint(String path) {
    final base = _base;
    if (base.isEmpty) {
      return Uri.parse('https://api.deepseek.com$path');
    }
    return Uri.parse('$base$path');
  }

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final override = cacheDirectoryOverride;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      _cacheDir = override;
      return override;
    }
    final root = await getTemporaryDirectory();
    final dir = Directory(p.join(root.path, 'tts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  // ------------------------------------------------------------------ TTS

  /// 合成一段语音，返回音频字节（不播放）。
  ///
  /// [voice] 为空时用 [TtsVoice.stella]（官方默认）。
  Future<TtsAudio> synthesize(
    String text, {
    TtsVoice? voice,
    String format = 'wav',
  }) async {
    final body = clampForTts(text, brackets: bracketMode);
    if (body.isEmpty) throw const SpeechException('这段回答没有可朗读的文字');
    final voiceId = (voice ?? TtsVoice.stella).id;
    // 同一段文字 + 同一音色只合成一次：命中磁盘缓存直接复用
    final cached = await _cachedAudio(body, voiceId, format);
    if (cached != null) return cached;

    final key = (apiKey?.call() ?? '').trim();
    if (key.isEmpty) throw const SpeechException('请先配置 DeepSeek API Key');
    final jobId = await _submitTtsJob(body, voiceId, format: format);
    final audioId = await _awaitTtsJobDone(jobId);
    if (audioId == null) {
      throw const SpeechException('合成失败，请稍后重试');
    }
    final bytes = await _fetchAudioBytesNow(audioId);
    if (bytes == null || bytes.isEmpty) {
      throw const SpeechException('音频已过期，请让模型重新生成');
    }
    _ensurePlayableAudio(bytes);
    final audio = TtsAudio(bytes: bytes, format: format);
    // 落盘：下次同一段文字直接播这个文件，不再消耗额度
    await _saveCache(body, voiceId, format, audio);
    return audio;
  }

  /// 读取已缓存音频；没有命中返回 null。
  Future<TtsAudio?> _cachedAudio(
    String body,
    String voiceId,
    String format,
  ) async {
    try {
      final file = await _cacheFile(body, voiceId, format);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return TtsAudio(bytes: bytes, format: format);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache(
    String body,
    String voiceId,
    String format,
    TtsAudio audio,
  ) async {
    try {
      final file = await _cacheFile(body, voiceId, format);
      await file.writeAsBytes(audio.bytes, flush: true);
    } catch (_) {
      // 缓存写失败不影响播放
    }
  }

  /// 缓存文件路径：内容哈希 + 音色 + 格式，同一段文字永远落在同一个文件上。
  Future<File> _cacheFile(String body, String voiceId, String format) async {
    final dir = await _ensureCacheDir();
    final digest = sha256.convert(utf8.encode('$voiceId|$format|$body'));
    // 只剩 wav 一种容器（裸 pcm 没有容器头，存成 .wav 播放器报「格式不对」，
    // 那条路线已废弃），扩展名统一走 wav。
    return File(p.join(dir.path, '${digest.toString()}.wav'));
  }

  /// 测试辅助：按文字与音色取缓存文件路径（验证缓存键分离用）。
  @visibleForTesting
  Future<File> testCacheFileFor(String text, String voiceId) =>
      _cacheFile(clampForTts(text), voiceId, 'wav');

  /// 测试辅助：提交 TTS 任务（验证提交请求体与轮询契约用）。
  @visibleForTesting
  Future<String> testSubmitTtsJob(String text, String voiceId) =>
      _submitTtsJob(clampForTts(text), voiceId);

  /// 朗读一条回答：提交合成任务 → 取回音频 → 修 WAV 头 → 播放本地文件。
  ///
  /// 再次对同一条调用表示「停止播放」。
  ///
  /// 链路：提交合成任务（服务端开始后不可中断）→ 轮询到 done → 按 audio_id
  /// 取全量字节 → 校验并就地修 WAV 头 → 落缓存 → 播放本地文件。
  ///
  /// 为什么必须「合成完再播」：WAV 头里带总长度（RiffSize/DataSize），
  /// 上游流式返回时这两个字段常常是占位值，ExoPlayer 按错误长度解码会直接报
  /// `MEDIA_ERROR_UNKNOWN`。这是 WAV 格式的硬约束——头必须知道总长，
  /// 所以收齐 + 修头之后才交给播放器。
  ///
  /// 历史：曾试过「裸 PCM + 原生 AudioTrack 边合成边出声」（爆音、电流声、
  /// 下载的音频没有容器头、播放器报「格式不对」），已整体废弃回到 WAV。
  ///
  /// 本地缓存命中直接播（零请求、秒出声）。服务端合成完成后音频落缓存，
  /// 下次点播同一段文字秒出。
  Future<void> speak({
    required String key,
    required String text,
    TtsVoice? voice,
  }) async {
    if (_playingKey == key) {
      await stop();
      return;
    }
    await stop();
    playback.value = SpeechPlaybackState.loading;
    _playingKey = key;
    try {
      final body = clampForTts(text, brackets: bracketMode);
      if (body.isEmpty) {
        throw const SpeechException('这段回答没有可朗读的文字');
      }
      final voiceId = (voice ?? TtsVoice.stella).id;
      // 本地缓存命中直接播（零请求、零等待）；缓存的是 wav 容器
      final file = await _cacheFile(body, voiceId, 'wav');
      if (await file.exists() && await file.length() > 0) {
        await _player.play(DeviceFileSource(file.path));
        playback.value = SpeechPlaybackState.playing;
        _watchCompletion(key);
        return;
      }
      // 提交合成任务（服务端开始后跑完为止，不随客户端断开中断）
      final jobId = await _submitTtsJob(body, voiceId);
      if (_playingKey != key) {
        return; // 提交期间用户已切走：任务在服务端继续
      }
      final audioId = await _awaitTtsJobDone(jobId);
      if (audioId == null) {
        throw const SpeechException('合成失败，请稍后重试');
      }
      if (_playingKey != key) return;
      final bytes = await _fetchAudioBytesNow(audioId);
      if (bytes == null || bytes.isEmpty) {
        throw const SpeechException('音频已过期，请让模型重新生成');
      }
      // 校验 + 就地修 WAV 头：上游的长度字段是占位值，不修播放器解码必失败
      _ensurePlayableAudio(bytes);
      // 先落缓存再播：既避免重复计费，也让播放走已验证稳定的本地路径
      await file.writeAsBytes(bytes, flush: true);
      if (_playingKey != key) return;
      await _player.play(DeviceFileSource(file.path));
      playback.value = SpeechPlaybackState.playing;
      _watchCompletion(key);
    } catch (e) {
      // 出错时把「播放中」状态收干净：否则 _playingKey 残留，
      // 下一次点击会被当成「停止当前播放」而毫无反应。
      if (_playingKey == key) {
        _playingKey = null;
        playback.value = SpeechPlaybackState.idle;
      }
      rethrow;
    }
  }

  /// 提交服务端 TTS 任务，返回任务号。
  ///
  /// 只请求 wav 容器：裸 pcm 没有容器头，存成 .wav 给播放器会报「格式不对」。
  Future<String> _submitTtsJob(
    String body,
    String voiceId, {
    String format = 'wav',
  }) async {
    final key = (apiKey?.call() ?? '').trim();
    if (key.isEmpty) throw const SpeechException('请先配置 DeepSeek API Key');
    final response = await _client
        .post(
          _endpoint('/v1/tools/tts'),
          headers: {
            ..._headers,
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'text': body,
            'voice_id': voiceId,
            'format': format,
            'filter_markdown': true,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 202 && response.statusCode != 200) {
      throw SpeechException(_errorText(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['job_id'] is! String) {
      throw const SpeechException('合成任务提交失败');
    }
    return decoded['job_id'] as String;
  }

  /// 等服务端任务到 done，返回音频 id；出错抛可读异常。
  Future<String?> _awaitTtsJobDone(String jobId) async {
    final deadline = DateTime.now().add(const Duration(minutes: 6));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final response = await _client
          .get(_endpoint('/v1/tts-jobs/$jobId'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 404) {
        throw const SpeechException('任务已过期，请重新生成');
      }
      if (response.statusCode != 200) {
        throw SpeechException(_errorText(response));
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) continue;
      final status = decoded['status'];
      if (status == 'done') {
        final audioId = decoded['audio_id'];
        return audioId is String && audioId.isNotEmpty ? audioId : null;
      }
      if (status == 'error') {
        throw SpeechException(
          (decoded['error'] as String?) ?? '合成失败，请稍后重试',
        );
      }
      // pending / running：继续轮询
    }
    throw const SpeechException('合成超时，请稍后重试');
  }

  void _watchCompletion(String key) {
    late final StreamSubscription<void> sub;
    sub = _player.onPlayerComplete.listen((_) {
      if (_playingKey == key) {
        _playingKey = null;
        playback.value = SpeechPlaybackState.idle;
      }
      unawaited(sub.cancel());
    });
  }

  /// 停止播放。
  ///
  /// 服务端任务是「开始后不可中断」的：这里只是客户端不再等待/出声，
  /// 服务端的合成会照常完成并存进缓存，下次点播直接命中。
  Future<void> stop() async {
    _playingKey = null;
    playback.value = SpeechPlaybackState.idle;
    try {
      await _playerInstance?.stop();
    } catch (_) {
      // 播放器未初始化等情况忽略
    }
  }

  /// 长按播放按钮：把音频另存到用户可访问的目录。
  ///
  /// 已生成过的段落直接复制本地文件，不会再次请求 TTS。
  /// 返回保存后的路径（失败时抛 [SpeechException]）。
  Future<String> download({
    required String text,
    required String fileName,
    TtsVoice? voice,
  }) async {
    final body = clampForTts(text, brackets: bracketMode);
    if (body.isEmpty) throw const SpeechException('这段回答没有可朗读的文字');
    final voiceId = (voice ?? TtsVoice.stella).id;
    final cached = await _cacheFile(body, voiceId, 'wav');
    final dir = await _downloadDir();
    final target = File(p.join(dir.path, _safeFileName(fileName)));
    if (await cached.exists() && await cached.length() > 0) {
      await target.writeAsBytes(await cached.readAsBytes(), flush: true);
      return target.path;
    }
    final audio = await synthesize(text, voice: voice, format: 'wav');
    await target.writeAsBytes(audio.bytes, flush: true);
    return target.path;
  }

  /// 下载目录：优先外部存储的应用私有目录（无需额外权限），
  /// 拿不到时退回缓存目录。
  Future<Directory> _downloadDir() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {
      base = null;
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'audio'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ------------------------------------------------------------------ ASR

  /// 开始录音（16-bit PCM WAV，正好满足官方 ASR 的格式要求）。
  ///
  /// 返回是否成功开始。
  Future<bool> startRecording() async {
    if (_recordingPath != null) return true;
    if (!await _recorder.hasPermission()) {
      throw const SpeechException('没有麦克风权限，请在系统设置里允许录音');
    }
    final dir = await _ensureCacheDir();
    final path = p.join(
      dir.path,
      'rec-${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: path,
    );
    _recordingPath = path;
    return true;
  }

  /// 结束录音并转写为文字。
  ///
  /// 返回识别文本；录音为空或识别失败时抛 [SpeechException]。
  Future<String> stopRecordingAndTranscribe() async {
    final path = _recordingPath;
    _recordingPath = null;
    final recorded = path == null ? null : await _recorder.stop();
    final file = File(recorded ?? path ?? '');
    if (!await file.exists()) {
      throw const SpeechException('没有录到声音');
    }
    final length = await file.length();
    if (length < 1024) {
      await _deleteQuietly(file);
      throw const SpeechException('录音太短了，请按住多说一会儿');
    }
    // 官方上限 8 MiB / 120 秒；超限先拦下来，免得白传一遍
    if (length > 8 * 1024 * 1024) {
      await _deleteQuietly(file);
      throw const SpeechException('录音超过 8MB，请缩短后重试');
    }
    try {
      return await transcribe(file);
    } finally {
      await _deleteQuietly(file);
    }
  }

  /// 上传一个音频文件做识别。
  Future<String> transcribe(File file) async {
    final key = (apiKey?.call() ?? '').trim();
    if (key.isEmpty) throw const SpeechException('请先配置 DeepSeek API Key');
    final request = http.MultipartRequest('POST', _endpoint('/v1/tools/asr'))
      ..headers.addAll({
        ..._headers,
        'Authorization': 'Bearer $key',
        'Accept': 'application/json',
      })
      ..files.add(
        await http.MultipartFile.fromPath('file', file.path, filename: 'a.wav'),
      );
    // 与 TTS 一样：必须用注入的指纹校验客户端发出去
    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 180));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw SpeechException(_errorText(response));
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final text = decoded is Map ? decoded['text'] : null;
    if (text is! String || text.trim().isEmpty) {
      throw const SpeechException('没有识别出内容，请再说一次');
    }
    return text.trim();
  }

  /// 取消录音（不转写）。
  Future<void> cancelRecording() async {
    final path = _recordingPath;
    _recordingPath = null;
    try {
      await _recorder.cancel();
    } catch (_) {}
    if (path != null) await _deleteQuietly(File(path));
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorderInstance?.dispose();
    } catch (_) {}
    await _playerInstance?.dispose();
    playback.dispose();
  }

  // ------------------------------------------------------------------ 工具

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  String _errorText(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String && error.isNotEmpty) return error;
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } catch (_) {}
    return '请求失败 (HTTP ${response.statusCode})';
  }

  /// 这段文字 + 音色是否已经生成过朗读音频（命中则不再请求 TTS）。
  Future<bool> hasAudio(String text, {TtsVoice? voice}) async {
    final body = clampForTts(text, brackets: bracketMode);
    if (body.isEmpty) return false;
    try {
      final file = await _cacheFile(
        body,
        (voice ?? TtsVoice.stella).id,
        'wav',
      );
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 把模型生成的音频存成独立文件（每段文本一个文件，互不覆盖）。
  ///
  /// 与「朗读缓存」分开：这里返回的是给用户看的音频文件，
  /// 文件名带时间戳，同一段文字多次生成也各自独立。
  Future<String> saveGenerated({
    required String text,
    required Uint8List bytes,
    TtsVoice? voice,
    String? fileName,
  }) async {
    final dir = await _ensureGeneratedDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final digest = sha256
        .convert(utf8.encode('${(voice ?? TtsVoice.stella).id}|$text'))
        .toString()
        .substring(0, 8);
    // 指定了文件名（例如服务端给音频 id）就用它，便于按 id 去重
    final name = fileName ?? 'speech-$stamp-$digest.wav';
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 把音频存到**系统标准下载目录**（用户点「下载」时才调用）。
  ///
  /// Android 走应用内原生通道写 MediaStore 公共 Download（无需存储权限）；
  /// 其它平台/通道不可用时退回应用外部目录，并把路径返回给界面提示。
  Future<String> saveToDownloads({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final tmp = await _writeTempForDownload(bytes);
    try {
      if (Platform.isAndroid) {
        final result = await _mediaStoreChannel.invokeMethod<String>(
          'saveToDownloads',
          {'path': tmp.path, 'fileName': fileName},
        );
        if (result != null && result.isNotEmpty) return result;
      }
    } on MissingPluginException {
      // 没有原生实现（例如桌面调试）：落到下面的兜底路径
    } on PlatformException {
      // 同样的兜底
    }
    final dir = await _downloadDir();
    final target = File(p.join(dir.path, _safeFileName(fileName)));
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  static const MethodChannel _mediaStoreChannel = MethodChannel(
    'com.deepseek.dsapi/media_store',
  );

  /// MediaStore 需要一个已存在的临时文件做源。
  Future<File> _writeTempForDownload(Uint8List bytes) async {
    final dir = await _ensureCacheDir();
    final tmp = File(
      p.join(dir.path, 'dl-${DateTime.now().microsecondsSinceEpoch}.wav'),
    );
    await tmp.writeAsBytes(bytes, flush: true);
    return tmp;
  }

  /// 播放一个本地音频文件；[key] 用于界面判断当前播的是哪一个。
  Future<void> playFile(String path, {required String key}) async {
    if (_playingKey == key) {
      await stop();
      return;
    }
    await stop();
    playback.value = SpeechPlaybackState.loading;
    _playingKey = key;
    try {
      await _player.play(DeviceFileSource(path));
      playback.value = SpeechPlaybackState.playing;
      _watchCompletion(key);
    } catch (e) {
      _playingKey = null;
      playback.value = SpeechPlaybackState.idle;
      rethrow;
    }
  }

  /// 播放**远端**音频：点播放时才向服务器拉一次，拉到就缓存到临时目录。
  ///
  /// 音频默认只存在服务器（不占手机空间），用户点播放才下载到本机临时目录。
  /// 播放失败时把坏缓存清掉，下次点播自动重新拉取。
  Future<void> playRemote({
    required String audioId,
    required Future<Uint8List?> Function(String id) fetch,
    required String key,
  }) async {
    if (_playingKey == key) {
      await stop();
      return;
    }
    await stop();
    playback.value = SpeechPlaybackState.loading;
    _playingKey = key;
    try {
      final file = await _remoteAudioFile(audioId, fetch);
      await _player.play(DeviceFileSource(file.path));
      playback.value = SpeechPlaybackState.playing;
      _watchCompletion(key);
    } on AudioPlayerException catch (_) {
      // 字节能拉到但播放器解不了：清掉坏缓存，下次点播重取
      _playingKey = null;
      playback.value = SpeechPlaybackState.idle;
      await dropRemoteCache(audioId);
      rethrow;
    } catch (e) {
      _playingKey = null;
      playback.value = SpeechPlaybackState.idle;
      rethrow;
    }
  }

  /// 取远端音频字节（「下载」用）。
  Future<Uint8List> fetchRemoteBytes(
    String audioId,
    Future<Uint8List?> Function(String id) fetch,
  ) async {
    final file = await _remoteAudioFile(audioId, fetch);
    return file.readAsBytes();
  }

  /// 远端音频的本地缓存（只在播放/下载时按需生成）。
  Future<File> _remoteAudioFile(
    String audioId,
    Future<Uint8List?> Function(String id) fetch,
  ) async {
    final dir = await _ensureCacheDir();
    final file = File(p.join(dir.path, 'remote-$audioId.wav'));
    if (await file.exists() && await file.length() > 0) return file;
    final bytes = await fetch(audioId);
    if (bytes == null || bytes.isEmpty) {
      throw const SpeechException('音频已过期，请让模型重新生成');
    }
    _ensurePlayableAudio(bytes);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 删除损坏的远端音频缓存（下次点播会重新拉取）。
  Future<void> dropRemoteCache(String audioId) async {
    try {
      final dir = await _ensureCacheDir();
      final file = File(p.join(dir.path, 'remote-$audioId.wav'));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 确认拿到的确实是可播放的音频容器，并**就地修复 WAV 头**。
  ///
  /// 上游是流式合成：RiffSize/DataSize 两个长度字段常常是占位值
  /// （0 或 0xFFFFFFFF）。Android 播放器要求真实长度，否则直接报
  /// `MEDIA_ERROR_UNKNOWN`。字节已经完整落到内存，把两个长度补成真实值即可。
  /// 上游出错时也可能「200 + JSON 错误体」，提前拦下来给出可读原因。
  void _ensurePlayableAudio(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const SpeechException('返回的音频不完整，请重试');
    }
    final head = String.fromCharCodes(bytes.sublist(0, 4));
    if (head == 'RIFF') {
      _repairWavHeader(bytes);
      return;
    }
    // JSON 错误体：把里面的话说出来，比播放器的 MEDIA_ERROR 有用得多
    final text = String.fromCharCodes(bytes.take(300));
    if (text.trimLeft().startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final error = decoded['error'];
          if (error is Map && error['message'] is String) {
            throw SpeechException('合成失败：${error['message']}');
          }
          if (error is String && error.isNotEmpty) {
            throw SpeechException('合成失败：$error');
          }
        }
      } on SpeechException {
        rethrow;
      } catch (_) {}
      throw SpeechException('合成失败：${text.trim()}');
    }
    // ogg / mp3 不需要修头，直接放行
    final head8 = String.fromCharCodes(
      bytes.length > 8 ? bytes.sublist(0, 8) : bytes,
    );
    if (head8.startsWith('OggS') ||
        head8.startsWith('ID3') ||
        (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0)) {
      return;
    }
    // 裸 PCM 没有容器头，直接落盘 .wav 播放器会报「格式不对」——
    // 那条路线已废弃，这里不再放行。
    throw const SpeechException('返回的不是可播放的音频，请重试');
  }

  /// 把 WAV 头里的两个长度字段改成真实值（按 RFC 2317 标准 44 字节头）。
  ///
  /// data 块不一定在固定偏移：按标准布局先试 36..40，找不到再全量扫一遍。
  void _repairWavHeader(Uint8List bytes) {
    void patch(int riffOffset, int dataOffset) {
      final byteData = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.length,
      );
      byteData.setUint32(riffOffset, bytes.length - 8, Endian.little);
      byteData.setUint32(
        dataOffset,
        bytes.length - dataOffset - 4,
        Endian.little,
      );
    }

    bool looksSane(int riffOffset, int dataOffset) =>
        dataOffset + 4 <= bytes.length &&
        bytes.length - dataOffset - 4 > 0;

    // 标准 44 字节头：RIFFsize@4，data 标记@36，dataSize@40
    final stdMarker = String.fromCharCodes(bytes.sublist(36, 40));
    if (stdMarker == 'data' && looksSane(4, 40)) {
      patch(4, 40);
      return;
    }
    // 非标准布局：扫描 'data' 标记（只在头部 4KB 里找，避免误伤音频数据）
    final scanEnd = bytes.length < 4096 ? bytes.length : 4096;
    for (var i = 12; i + 8 <= scanEnd; i++) {
      if (bytes[i] == 0x64 &&
          bytes[i + 1] == 0x61 &&
          bytes[i + 2] == 0x74 &&
          bytes[i + 3] == 0x61) {
        if (looksSane(4, i + 4)) {
          patch(4, i + 4);
          return;
        }
      }
    }
    // 都没找到：保持原样，交给播放器自己处理
  }

  /// 从服务器取一段音频字节（任务 done 后按 audio_id 拉本地缓存用）。
  Future<Uint8List?> _fetchAudioBytesNow(String audioId) async {
    final key = (apiKey?.call() ?? '').trim();
    final response = await _client
        .get(
          _endpoint('/v1/audio/$audioId'),
          headers: {
            ..._headers,
            if (key.isNotEmpty) 'Authorization': 'Bearer $key',
          },
        )
        .timeout(const Duration(seconds: 120));
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  }

  /// 模型生成的音频目录（与朗读缓存分开，方便整体清理）。
  Future<Directory> _ensureGeneratedDir() async {
    final base = cacheDirectoryOverride ?? await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'generated'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 清空语音缓存（设置页「清空语音缓存」用）。
  Future<int> clearCache() async {
    var removed = 0;
    try {
      final dir = await _ensureCacheDir();
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          await entity.delete();
          removed++;
        } catch (_) {}
      }
    } catch (_) {}
    return removed;
  }

  String _safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? 'answer.wav' : cleaned;
  }
}

/// 播放状态（界面按它切换图标）。
enum SpeechPlaybackState { idle, loading, playing }

/// 语音相关错误（界面直接展示 message）。
class SpeechException implements Exception {
  const SpeechException(this.message);

  final String message;

  @override
  String toString() => message;
}
