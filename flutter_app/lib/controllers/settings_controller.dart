import 'package:flutter/foundation.dart';

import '../models.dart';
import '../speech.dart';
import '../storage.dart';

/// 设置项的读写与持久化：App 级设置字段与对应 setter 集中在这里。
/// [AppState] 保留同名字段/方法的委托（facade），UI 无需感知拆分。
class SettingsController extends ChangeNotifier {
  SettingsController({SettingsStore? store}) : _store = store ?? SettingsStore();

  final SettingsStore _store;

  /// 底层持久化存储（迁移标记等运维字段仍走它）。
  SettingsStore get store => _store;

  AppMode mode = AppMode.quick;
  bool deepThink = true;
  bool webSearch = false;
  ApiProtocol protocol = ApiProtocol.anthropic;
  String reasoningEffort = defaultReasoningEffort;
  String? apiKey;

  /// 中转服务器地址（App 内可改，换服务器无需重新编译）
  String serverBaseUrl = defaultServerBaseUrl;

  /// 服务器访问口令（服务端设置 RELAY_TOKEN 时必填）
  String serverToken = defaultServerToken;

  /// 服务器证书 SHA-256 指纹（自签名证书用）
  String serverCertSha256 = defaultServerCertSha256;

  /// 是否把生成任务交给服务器执行（后台/断网也能续上）
  bool useServer = true;

  /// 朗读音色。目前固定为官方默认的「海星」；[TtsVoice] 已按多值设计，
  /// 后续官方开放新音色时只改这里与 [TtsVoice.values] 即可。
  String ttsVoiceId = defaultTtsVoiceId;

  /// 自动朗读：开启后每条新回答生成完自动朗读，关闭则不朗读。
  bool autoSpeak = false;

  String? _quickModelOverride;
  String? _expertModelOverride;

  /// 快速模式的自定义模型名（可空；为空时用该模式默认模型）。
  String? get quickModelOverride => _quickModelOverride;

  /// 专家模式的自定义模型名（可空；为空时用该模式默认模型）。
  String? get expertModelOverride => _expertModelOverride;

  /// 当前生效的朗读音色。
  TtsVoice get ttsVoice => TtsVoice.fromId(ttsVoiceId);

  /// 取指定模式的自定义模型名（已去空格；未设置返回 null）。
  String? modelOverrideFor(AppMode m) {
    final v = m == AppMode.quick ? _quickModelOverride : _expertModelOverride;
    return (v != null && v.trim().isNotEmpty) ? v.trim() : null;
  }

  /// 实际请求使用的模型：优先当前模式的自定义模型，其次该模式默认模型。
  String get effectiveModel => modelOverrideFor(mode) ?? mode.model;

  /// 从持久化存储读回全部设置（App 启动时调用一次）。
  Future<void> load() async {
    apiKey = await _store.apiKey;
    _quickModelOverride = await _store.modelOverrideQuick;
    _expertModelOverride = await _store.modelOverrideExpert;
    mode = AppMode.fromIndex(await _store.mode);
    deepThink = await _store.deepThink;
    webSearch = await _store.webSearch;
    protocol = ApiProtocol.fromIndex(await _store.apiProtocol);
    serverBaseUrl = await _store.serverBaseUrl;
    serverToken = await _store.serverToken;
    serverCertSha256 = await _store.serverCertSha256;
    useServer = await _store.useServer;
    final storedEffort = await _store.reasoningEffort;
    reasoningEffort = reasoningEfforts.contains(storedEffort)
        ? storedEffort
        : defaultReasoningEffort;
    ttsVoiceId = await _store.ttsVoice;
    autoSpeak = await _store.autoSpeak;
    notifyListeners();
  }

  Future<void> setMode(AppMode next) async {
    mode = next;
    // 先通知再落盘：这几个开关是点击即生效的 UI 状态，等 await 完再刷新
    // 会晚一帧到几帧（磁盘慢时更明显），表现为「按了没反应」。
    notifyListeners();
    await _store.setMode(next.index);
  }

  Future<void> setDeepThink(bool value) async {
    deepThink = value;
    notifyListeners();
    await _store.setDeepThink(value);
  }

  Future<void> setWebSearch(bool value) async {
    webSearch = value;
    notifyListeners();
    await _store.setWebSearch(value);
  }

  Future<void> setProtocol(ApiProtocol value) async {
    protocol = value;
    await _store.setApiProtocol(value.index);
    notifyListeners();
  }

  Future<void> setReasoningEffort(String value) async {
    reasoningEffort = reasoningEfforts.contains(value)
        ? value
        : defaultReasoningEffort;
    notifyListeners();
    await _store.setReasoningEffort(reasoningEffort);
  }

  Future<void> setApiKey(String? key) async {
    apiKey = key;
    await _store.setApiKey(key);
    notifyListeners();
  }

  /// 设置朗读音色（当前 UI 不暴露，保留给后续扩展）。
  Future<void> setTtsVoice(String voiceId) async {
    ttsVoiceId = voiceId;
    await _store.setTtsVoice(voiceId);
    notifyListeners();
  }

  /// 切换自动朗读开关。
  Future<void> setAutoSpeak(bool value) async {
    if (autoSpeak == value) return;
    autoSpeak = value;
    await _store.setAutoSpeak(value);
    notifyListeners();
  }

  /// 同时保存 API Key 与快速/专家模式的自定义模型名（留空则该模式回退到默认模型）。
  Future<void> setApiKeyAndModels(
    String? key,
    String? quickModel,
    String? expertModel,
  ) async {
    apiKey = key;
    _quickModelOverride = (quickModel != null && quickModel.trim().isNotEmpty)
        ? quickModel.trim()
        : null;
    _expertModelOverride =
        (expertModel != null && expertModel.trim().isNotEmpty)
        ? expertModel.trim()
        : null;
    await _store.setApiKey(key);
    await _store.setModelOverrideQuick(_quickModelOverride);
    await _store.setModelOverrideExpert(_expertModelOverride);
    notifyListeners();
  }
}
