import 'dart:async';

import 'package:flutter/foundation.dart';

import '../deepseek_client.dart';
import '../models.dart';
import '../net_client.dart';
import '../speech.dart';
import 'network.dart';
import 'settings_controller.dart';

/// TTS / ASR 全部入口：朗读、下载/播放回答音频、按住说话，以及
/// `text_to_speech` 工具的执行器。
class TtsController extends ChangeNotifier {
  TtsController({required this.settings, required this.network});

  final SettingsController settings;
  final NetworkConfig network;

  /// 语音服务（TTS 朗读 / ASR 录音），由 main.dart 注入同一个实例。
  SpeechService? speech;

  /// 当前会话的括号朗读模式（会话级，默认朗读括号内容）。
  BracketSpeechMode bracketMode = BracketSpeechMode.speak;

  /// 当前会话是否启用语音生成工具（会话级，默认关；联网时自动忽略）。
  bool ttsToolEnabled = false;

  /// 执行 `text_to_speech` 的入口（测试可注入替身；为空时不声明该工具）。
  Future<String> Function(String text)? ttsRunner;

  /// 落盘通知回调（由组合根注入，转成界面提示）。
  void Function(String text, {bool isError})? onNotice;

  /// 注入语音服务实例（main.dart 里创建，整个 App 共用一份）。
  void attach(SpeechService service) {
    speech = service;
    _bindSpeech();
    // 播放状态变化时刷新界面（卡片按钮、顶栏喇叭）
    service.playback.addListener(notifyListeners);
  }

  /// 把语音服务绑到当前设置：地址/口令/Key 变化后立即生效。
  void _bindSpeech() {
    final service = speech;
    if (service == null) return;
    service.relayBaseUrl = () => settings.serverBaseUrl;
    service.relayToken = () => settings.serverToken;
    service.apiKey = () => settings.apiKey ?? '';
    // 中转是自签名证书，TTS/ASR 必须用同一个按指纹校验的客户端，
    // 否则会走 Dart 默认 TLS 校验并抛 CERTIFICATE_VERIFY_FAILED。
    service.httpClient = () =>
        buildPinnedHttpClient(network.pinnedCertSha256);
  }

  /// 服务器地址/口令变化后重新绑定语音服务的取值回调。
  void rebindNetwork() => _bindSpeech();

  /// 切换当前会话的括号朗读模式（会话级持久化）。
  Future<void> toggleBracketMode() async {
    await setBracketMode(
      bracketMode == BracketSpeechMode.speak
          ? BracketSpeechMode.skip
          : BracketSpeechMode.speak,
    );
  }

  /// 设置当前会话的括号朗读模式（面板保存时用）。
  Future<void> setBracketMode(BracketSpeechMode mode) async {
    bracketMode = mode;
    if (speech != null) speech!.bracketMode = mode;
    final convId = currentConversationId;
    if (convId != null) {
      await settings.store.setBracketModeFor(convId, mode);
    }
    notifyListeners();
  }

  /// 切换当前会话的语音生成工具开关（会话级持久化；联网时自动忽略）。
  Future<void> toggleTtsTool() async {
    await setTtsToolEnabled(!ttsToolEnabled);
  }

  /// 设置当前会话的语音生成工具开关（面板保存时用）。
  Future<void> setTtsToolEnabled(bool enabled) async {
    ttsToolEnabled = enabled;
    final convId = currentConversationId;
    if (convId != null) {
      await settings.store.setTtsToolFor(convId, enabled);
    }
    notifyListeners();
  }

  /// 当前生效的朗读音色。
  TtsVoice get ttsVoice => settings.ttsVoice;

  /// 朗读一条回答（点播放按钮）。
  ///
  /// 语音在**点击时才生成**；同一段文字 + 同一音色只会合成一次，
  /// 之后一直复用本地已保存的音频文件。
  Future<void> speakMessage(ChatMessage msg, {required String key}) async {
    final service = speech;
    if (service == null) return;
    if (msg.content.trim().isEmpty) {
      onNotice?.call('这条回答还没有内容');
      return;
    }
    try {
      await service.speak(key: key, text: msg.content, voice: ttsVoice);
    } on SpeechException catch (e) {
      onNotice?.call(e.message, isError: true);
    } catch (e) {
      onNotice?.call('朗读失败：$e', isError: true);
    }
  }

  /// 停止朗读。
  Future<void> stopSpeaking() async {
    await speech?.stop();
  }

  /// 「下载」：把音频存到**系统标准下载目录**（不下载就一直留在服务器）。
  ///
  /// 来源由 [preferCardAudio] 区分（两个入口语义不同，不能混）：
  /// - 操作行长按喇叭（默认）：按回答**正文**现合成（命中朗读缓存不重复计费），
  ///   即使消息带音频卡片也不用它的录音——用户要的是「这段文字的朗读」；
  /// - 音频卡片的下载按钮（[preferCardAudio]=true）：按音频 id 取模型
  ///   `text_to_speech` 生成的那条录音。
  Future<void> downloadMessageAudio(
    ChatMessage msg, {
    required String fileName,
    bool preferCardAudio = false,
  }) async {
    final service = speech;
    if (service == null) return;
    try {
      Uint8List bytes;
      if (preferCardAudio && msg.audioFiles.isNotEmpty) {
        bytes = await service.fetchRemoteBytes(
          msg.audioFiles.first,
          (id) => _fetchAudioBytes(id),
        );
      } else {
        if (msg.content.trim().isEmpty) {
          onNotice?.call('这条回答没有可朗读的文字');
          return;
        }
        // 下载必须用 wav 容器：裸 pcm 没有容器头，直接落盘 .wav 播放器
        // 会报「格式不对」。现在朗读与下载统一走 wav。
        bytes = (await service.synthesize(
          msg.content,
          voice: ttsVoice,
          format: 'wav',
        ))
            .bytes;
      }
      final where = await service.saveToDownloads(
        bytes: bytes,
        fileName: fileName,
      );
      onNotice?.call('音频已保存到 $where');
    } on SpeechException catch (e) {
      onNotice?.call(e.message, isError: true);
    } catch (e) {
      onNotice?.call('保存音频失败：$e', isError: true);
    }
  }

  /// 播放某条回答携带的音频（模型用 `text_to_speech` 生成）。
  ///
  /// 音频**默认只存在服务器**：点播放时才按 id 拉一次并缓存到临时目录；
  /// 再点同一个表示停止。同一时刻只播一条。
  Future<void> playMessageAudio(
    ChatMessage msg, {
    required String key,
  }) async {
    final service = speech;
    if (service == null) return;
    if (msg.audioFiles.isEmpty) {
      onNotice?.call('这条回答没有音频文件');
      return;
    }
    try {
      await service.playRemote(
        audioId: msg.audioFiles.first,
        key: key,
        fetch: (id) => _fetchAudioBytes(id),
      );
    } on SpeechException catch (e) {
      onNotice?.call(e.message, isError: true);
    } catch (e) {
      onNotice?.call('播放失败：$e', isError: true);
    }
  }

  /// 按音频 id 取字节（服务端执行 TTS 时音频存在它的缓存里）。
  Future<Uint8List?> _fetchAudioBytes(String audioId) {
    return _newClient().fetchAudio(audioId, apiKey: settings.apiKey ?? '');
  }

  /// 默认的 TTS 执行器：合成 → 落盘 → 记到当前轮（收尾时随消息一起落库）。
  Future<String> _defaultTtsRunner(String text) async {
    final service = speech;
    if (service == null) throw const SpeechException('当前环境不支持语音合成');
    final audio = await service.synthesize(text, voice: ttsVoice);
    final path = await service.saveGenerated(
      text: text,
      bytes: audio.bytes,
      voice: ttsVoice,
    );
    final turn = onTurnAudio;
    if (turn != null) await turn(path);
    notifyListeners();
    return path;
  }

  /// 模型调用 `text_to_speech` 时执行：合成音频并落到本地，返回文件路径。
  Future<String> runTtsTool(String text) =>
      (ttsRunner ?? _defaultTtsRunner)(text);

  /// 按住说话：开始录音。
  Future<bool> startVoiceInput() async {
    final service = speech;
    if (service == null) return false;
    try {
      return await service.startRecording();
    } on SpeechException catch (e) {
      onNotice?.call(e.message, isError: true);
      return false;
    } catch (e) {
      onNotice?.call('无法开始录音：$e', isError: true);
      return false;
    }
  }

  /// 松手：结束录音并转写，成功时返回文本（由输入框填入）。
  Future<String?> stopVoiceInput() async {
    final service = speech;
    if (service == null) return null;
    try {
      final text = await service.stopRecordingAndTranscribe();
      return text;
    } on SpeechException catch (e) {
      onNotice?.call(e.message, isError: true);
      return null;
    } catch (e) {
      onNotice?.call('语音识别失败：$e', isError: true);
      return null;
    }
  }

  /// 取消录音。
  Future<void> cancelVoiceInput() async {
    await speech?.cancelRecording();
  }

  /// 清掉被截断消息引用的音频本地临时缓存（重新生成 / 编辑时调用）。
  ///
  /// 消息列表里的 audioFiles 在直连模式下是本地路径、中转模式下是音频 id；
  /// 对应的临时文件（`remote-{id}.wav`）不再会被播放，留着只会占空间。
  /// 服务端那边的缓存由 truncate 接口按孤儿音频自己清理。
  void dropLocalAudioCache(List<ChatMessage> doomed) {
    final service = speech;
    if (service == null) return;
    for (final msg in doomed) {
      for (final id in msg.audioFiles) {
        unawaited(service.dropRemoteCache(id));
      }
    }
  }

  DeepSeekClient _newClient() => network.newClient();

  /// 当前会话 id（由组合根按需回填，会话级设置持久化用）。
  int? currentConversationId;

  /// 当前轮生成出音频时回调（组合根接到 TurnController 的运行态上）。
  Future<void> Function(String path)? onTurnAudio;
}
