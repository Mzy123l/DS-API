import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_repository.dart';
import 'controllers/network.dart';
import 'controllers/session_store.dart';
import 'controllers/settings_controller.dart';
import 'controllers/turn_controller.dart';
import 'controllers/tts_controller.dart';
import 'deepseek_client.dart';
import 'models.dart';
import 'net_client.dart';
import 'speech.dart';
import 'storage.dart';
export 'controllers/session_store.dart' show BracketSpeechModeData;

/// 应用状态（组合根 + UI 门面）：串接设置、本地存储、DeepSeek 流式请求。
///
/// 具体职责已拆到各控制器：
/// - [SettingsController]：设置项读写与持久化；
/// - [NetworkConfig]：请求客户端与会话存储工厂；
/// - [SessionStore]：会话/消息 CRUD、分页、视图代次；
/// - [TurnController]：发送/编辑/重算、流式接收、后台恢复；
/// - [TtsController]：TTS/ASR 入口。
///
/// 本类保留原有 getter/方法签名（facade），UI 层零改动。
class AppState extends ChangeNotifier {
  AppState({
    AppDatabase? db,
    SettingsStore? settings,
    ChatRepository? repository,
    DeepSeekClient Function()? clientFactory,
  })  : _ctorDb = db,
        _ctorSettings = settings,
        _ctorRepository = repository,
        _ctorClientFactory = clientFactory {
    _db = _ctorDb ?? AppDatabase();
    _settingsStore = _ctorSettings ?? SettingsStore();
    settingsCtl = SettingsController(store: _settingsStore);
    // 设置项（快速/专家模式、深度思考、智能搜索、推理强度）变化必须传到 UI：
    // root_shell watch 的是 AppState，而 SettingsController 自己 notifyListeners
    // 没有任何订阅者——界面要等下一次别的通知（点别处、流式增量）才刷新，
    // 表现就是「按了开关没反应，点一下其他地方才变」。
    settingsCtl.addListener(notifyListeners);
    network = NetworkConfig(settings: settingsCtl, db: _db)
      ..clientFactory = _ctorClientFactory;
    if (_ctorRepository != null) network.injectRepository(_ctorRepository);
    session = SessionStore(
      network: network,
      settings: settingsCtl,
      db: _db,
    );
    tts = TtsController(settings: settingsCtl, network: network)
      ..onNotice = showNotice;
    // 播放状态（playingKey / loading）变化必须传到 UI：root_shell watch 的
    // 是 AppState，而 TtsController 是独立 ChangeNotifier——重构拆分时
    // 播放按钮「状态不对」的根因就是这条转发被断掉（只通知了控制器自己）。
    tts.addListener(notifyListeners);
    turns = TurnController(
      session: session,
      settings: settingsCtl,
      network: network,
      tts: tts,
    )
      ..onNotice = showNotice
      ..onNotify = notifyListeners;
  }

  final AppDatabase? _ctorDb;
  final SettingsStore? _ctorSettings;
  final ChatRepository? _ctorRepository;
  final DeepSeekClient Function()? _ctorClientFactory;

  late final AppDatabase _db;
  late final SettingsStore _settingsStore;

  // 各控制器（公开给需要的 UI/测试；AppState 自身也大量委托）。
  late final SettingsController settingsCtl;
  late final NetworkConfig network;
  late final SessionStore session;
  late final TtsController tts;
  late final TurnController turns;

  // ---------------------------------------------------------- 设置（facade）

  AppMode get mode => settingsCtl.mode;
  set mode(AppMode value) => settingsCtl.mode = value;

  bool get deepThink => settingsCtl.deepThink;
  set deepThink(bool value) => settingsCtl.deepThink = value;

  bool get webSearch => settingsCtl.webSearch;
  set webSearch(bool value) => settingsCtl.webSearch = value;

  ApiProtocol get protocol => settingsCtl.protocol;
  set protocol(ApiProtocol value) => settingsCtl.protocol = value;

  String get reasoningEffort => settingsCtl.reasoningEffort;
  set reasoningEffort(String value) => settingsCtl.reasoningEffort = value;

  String? get apiKey => settingsCtl.apiKey;
  set apiKey(String? value) => settingsCtl.apiKey = value;

  /// 中转服务器地址（App 内可改，换服务器无需重新编译）
  String get serverBaseUrl => settingsCtl.serverBaseUrl;
  set serverBaseUrl(String value) => settingsCtl.serverBaseUrl = value;

  /// 服务器访问口令（服务端设置 RELAY_TOKEN 时必填）
  String get serverToken => settingsCtl.serverToken;
  set serverToken(String value) => settingsCtl.serverToken = value;

  /// 服务器证书 SHA-256 指纹（自签名证书用）
  String get serverCertSha256 => settingsCtl.serverCertSha256;
  set serverCertSha256(String value) => settingsCtl.serverCertSha256 = value;

  /// 是否把生成任务交给服务器执行（后台/断网也能续上）
  bool get useServer => settingsCtl.useServer;
  set useServer(bool value) => settingsCtl.useServer = value;

  /// 请求客户端的创建方式：默认按当前设置新建（每个会话一个），测试可注入。
  DeepSeekClient Function()? get clientFactory => network.clientFactory;
  set clientFactory(DeepSeekClient Function()? value) =>
      network.clientFactory = value;

  String? get quickModelOverride => settingsCtl.quickModelOverride;
  String? get expertModelOverride => settingsCtl.expertModelOverride;
  String? modelOverrideFor(AppMode m) => settingsCtl.modelOverrideFor(m);
  String get effectiveModel => settingsCtl.effectiveModel;

  Future<void> setMode(AppMode next) => settingsCtl.setMode(next);
  Future<void> setDeepThink(bool value) => settingsCtl.setDeepThink(value);
  Future<void> setWebSearch(bool value) => settingsCtl.setWebSearch(value);
  Future<void> setProtocol(ApiProtocol value) => settingsCtl.setProtocol(value);
  Future<void> setReasoningEffort(String value) =>
      settingsCtl.setReasoningEffort(value);
  Future<void> setApiKey(String? key) => settingsCtl.setApiKey(key);
  Future<void> setApiKeyAndModels(
    String? key,
    String? quickModel,
    String? expertModel,
  ) => settingsCtl.setApiKeyAndModels(key, quickModel, expertModel);

  // ------------------------------------------------------------- TTS（facade）

  /// 语音服务（TTS 朗读 / ASR 录音），由 main.dart 注入同一个实例。
  SpeechService? get speech => tts.speech;

  /// 当前会话的括号朗读模式（会话级，默认朗读括号内容）。
  BracketSpeechMode get bracketMode => tts.bracketMode;

  /// 当前会话是否启用语音生成工具（会话级，默认关；联网时自动忽略）。
  bool get ttsToolEnabled => tts.ttsToolEnabled;

  /// 执行 `text_to_speech` 的入口（测试可注入替身；为空时不声明该工具）。
  Future<String> Function(String text)? get ttsRunner => tts.ttsRunner;
  set ttsRunner(Future<String> Function(String text)? value) =>
      tts.ttsRunner = value;

  /// 当前生效的朗读音色。
  TtsVoice get ttsVoice => tts.ttsVoice;

  String get ttsVoiceId => settingsCtl.ttsVoiceId;

  bool get autoSpeak => settingsCtl.autoSpeak;

  /// 切换自动朗读开关。
  Future<void> setAutoSpeak(bool value) async {
    await settingsCtl.setAutoSpeak(value);
    // 关掉时把正在播的也停下，避免「关了还在念」
    if (!value) await tts.speech?.stop();
    notifyListeners();
  }

  /// 设置朗读音色（当前 UI 不暴露，保留给后续扩展）。
  Future<void> setTtsVoice(String voiceId) =>
      settingsCtl.setTtsVoice(voiceId);

  /// 注入语音服务实例（main.dart 里创建，整个 App 共用一份）。
  void attachSpeech(SpeechService service) {
    tts.attach(service);
    notifyListeners();
  }

  /// 朗读一条回答（点播放按钮）。
  Future<void> speakMessage(ChatMessage msg, {required String key}) =>
      tts.speakMessage(msg, key: key);

  /// 停止朗读。
  Future<void> stopSpeaking() => tts.stopSpeaking();

  /// 「下载」：把音频存到系统标准下载目录。
  /// [preferCardAudio] 为 true 取音频卡片里的录音，否则按正文现合成。
  Future<void> downloadMessageAudio(
    ChatMessage msg, {
    required String fileName,
    bool preferCardAudio = false,
  }) => tts.downloadMessageAudio(
    msg,
    fileName: fileName,
    preferCardAudio: preferCardAudio,
  );

  /// 播放某条回答携带的音频（模型用 `text_to_speech` 生成）。
  Future<void> playMessageAudio(ChatMessage msg, {required String key}) =>
      tts.playMessageAudio(msg, key: key);

  /// 按住说话：开始录音。
  Future<bool> startVoiceInput() => tts.startVoiceInput();

  /// 松手：结束录音并转写，成功时返回文本（由输入框填入）。
  Future<String?> stopVoiceInput() => tts.stopVoiceInput();

  /// 取消录音。
  Future<void> cancelVoiceInput() => tts.cancelVoiceInput();

  /// 上传一个文档到 Files API，返回可引用的 [ChatFile]。
  Future<ChatFile?> uploadDocument(Attachment attachment) =>
      turns.uploadDocument(attachment);

  /// 切换当前会话的括号朗读模式（会话级持久化）。
  Future<void> toggleBracketMode() => tts.toggleBracketMode();

  /// 设置当前会话的括号朗读模式（面板保存时用）。
  Future<void> setBracketMode(BracketSpeechMode mode) => tts.setBracketMode(mode);

  /// 切换当前会话的语音生成工具开关（会话级持久化；联网时自动忽略）。
  Future<void> toggleTtsTool() => tts.toggleTtsTool();

  /// 设置当前会话的语音生成工具开关（面板保存时用）。
  Future<void> setTtsToolEnabled(bool enabled) =>
      tts.setTtsToolEnabled(enabled);

  // -------------------------------------------------------- 会话存储（facade）

  /// 当前使用的会话存储
  ChatRepository get store => network.store;

  List<Conversation> get conversations => session.conversations;
  set conversations(List<Conversation> value) => session.conversations = value;

  /// 历史列表是否还有更早的一页（服务器分页）
  bool get hasMoreConversations => session.hasMoreConversations;
  set hasMoreConversations(bool value) => session.hasMoreConversations = value;

  /// 当前会话是否还有更早的消息（服务器分页）
  bool get hasOlderMessages => session.hasOlderMessages;
  set hasOlderMessages(bool value) => session.hasOlderMessages = value;

  /// 是否正在加载更早的消息（避免重复触发）
  bool get loadingOlder => session.loadingOlder;
  set loadingOlder(bool value) => session.loadingOlder = value;

  /// 历史搜索命中（消息级）。空查询时为空列表。
  List<MessageHit> get searchHits => session.searchHits;

  int? get currentConversationId => session.currentConversationId;
  set currentConversationId(int? value) =>
      session.currentConversationId = value;

  String get conversationTitle => session.conversationTitle;
  set conversationTitle(String value) => session.conversationTitle = value;

  List<ChatMessage> get messages => session.messages;
  set messages(List<ChatMessage> value) => session.messages = value;

  /// 当前会话是否正在生成回答（按会话判断：别的会话在输出时本会话照样可以提问）。
  bool get busy => turns.busy;

  /// 正在生成的会话 id（历史列表等可用于标识）。
  Set<int> get runningConversationIds => turns.runningConversationIds;

  /// 当前正在编辑的用户消息下标；null 表示未处于编辑态。
  int? get editingIndex => turns.editingIndex;
  set editingIndex(int? value) => turns.editingIndex = value;

  /// 需要把消息列表拉回底部的信号：每次开始新一轮提问自增。
  int get scrollToken => turns.scrollToken;

  /// 最近的错误 / 提示（UI 用 SnackBar 展示）
  String? noticeText;
  bool noticeIsError = false;

  bool get hasMessages => session.hasMessages;
  bool get isChatView => session.isChatView;

  /// 当前生效的系统提示词（用户输入开头的 `<system>...</system>` 可覆盖）
  String get systemPrompt => session.systemPrompt;
  set systemPrompt(String value) => session.systemPrompt = value;

  /// 当前会话是否开启「回答气泡」。
  bool get answerBubble => session.answerBubble;
  set answerBubble(bool value) => session.answerBubble = value;

  /// 服务端音频 id → 本地文件路径（避免重复下载同一段音频）。
  Map<String, String> get generatedAudio => turns.generatedAudio;

  /// 消息列表贴底状态变化（由 MessagesView 回调）。
  void setFollowing(bool value) => turns.setFollowing(value);

  /// 更新某条消息（如思考区展开/折叠）。
  void replaceMessage(int index, ChatMessage message) {
    session.replaceMessage(index, message);
    notifyListeners();
  }

  // ------------------------------------------------------------------ 生命周期

  Future<void> init() async {
    await settingsCtl.load();
    tts.rebindNetwork();
    await refreshConversations();
    notifyListeners();
    // 启动时后台补齐服务器上的全部会话（本机缺失的历史会重新出现）
    unawaited(_syncAllConversations());
    // 旧版本的本机历史：一次性搬到服务器
    unawaited(_migrateLegacyHistory());
    // 上次没跑完的服务器任务：继续补齐
    await turns.resumePendingJobs();
  }

  Future<void> refreshConversations() async {
    await session.refreshConversations();
    notifyListeners();
  }

  /// 启动时后台补齐会话列表（包装成 AppState 私有入口，保持 init 原语义）。
  Future<void> _syncAllConversations() async {
    await session.syncAllConversations();
    notifyListeners();
  }

  /// 把旧的本地历史一次性上传到服务器（失败下次启动重试）。
  Future<void> _migrateLegacyHistory() async {
    await session.migrateLegacyHistory();
    notifyListeners();
  }

  /// 继续加载更早的会话（历史抽屉滑到底部时触发）。
  Future<void> loadMoreConversations() async {
    await session.loadMoreConversations();
    notifyListeners();
  }

  /// 按关键词搜索聊天记录（消息级，供历史页搜索使用）。
  Future<void> searchMessages(String query) async {
    await session.searchMessages(query);
    notifyListeners();
  }

  /// 新建对话：只切换视图。
  ///
  /// 正在输出的回答留在原会话继续跑（后台会话），这里不打断它；
  /// 前台的保活服务也跟着所有会话一起收尾。
  Future<void> newChat() async {
    session.resetView();
    turns.enterConversationView();
    if (tts.speech != null) tts.speech!.bracketMode = BracketSpeechMode.speak;
    tts.bracketMode = BracketSpeechMode.speak;
    tts.ttsToolEnabled = false;
    notifyListeners();
  }

  Future<void> loadConversation(Conversation conv) async {
    await session.loadConversation(conv);
    if (session.currentConversationId == conv.id) {
      turns.enterConversationView();
      // 读回该会话的两个语音开关（会话级持久化）
      final speech = await session.loadConversationSettings(conv.id);
      tts.bracketMode = speech.speech.bracketMode;
      tts.ttsToolEnabled = speech.speech.ttsTool;
      if (tts.speech != null) {
        tts.speech!.bracketMode = speech.speech.bracketMode;
      }
      if (speech.mode != null) settingsCtl.mode = speech.mode!;
      tts.currentConversationId = conv.id;
    }
    notifyListeners();
    // 该会话可能还在生成（本地任务没停，或服务端还有正在跑的任务）：把回答接回界面
    unawaited(turns.attachRunningTurn(conv.id));
  }

  /// 右上角按钮：查看/编辑当前对话的系统提示词。
  ///
  /// 保存空内容表示恢复默认提示词。
  Future<void> setSystemPrompt(String prompt) async {
    await session.applySystemPrompt(prompt);
    notifyListeners();
  }

  /// 设置当前会话的「回答气泡」。
  ///
  /// 新对话还没落库时只记在内存，首条消息创建会话时随会话一起写到服务端。
  Future<void> setAnswerBubble(bool value) async {
    await session.setAnswerBubble(value);
    notifyListeners();
  }

  /// App 从后台回到前台：重新对齐一次服务端历史（退后台期间服务端可能已生成完）。
  Future<void> refreshCurrentConversation() async {
    await session.refreshCurrentConversation();
    notifyListeners();
  }

  /// 继续加载更早的消息（聊天页往上翻时触发）。
  Future<void> loadOlderMessages() async {
    await session.loadOlderMessages();
    notifyListeners();
  }

  Future<void> deleteConversation(Conversation conv) async {
    await deleteConversations([conv.id]);
  }

  /// 全部会话 id（"全选"用，向服务器要全量而不是只算已加载的）
  Future<List<int>> allConversationIds() => session.allConversationIds();

  /// 批量删除（一次删除 + 一次刷新，避免逐条刷新列表）
  Future<void> deleteConversations(List<int> ids) async {
    await session.deleteConversations(ids, _cancelTurnForDeleted);
    if (currentConversationId != null && ids.contains(currentConversationId)) {
      await newChat();
    }
    // 无论删除的是不是当前会话，都要刷新历史列表。
    await refreshConversations();
  }

  Future<void> _cancelTurnForDeleted(int id) async {
    turns.dropTurn(id);
  }

  /// 保存中转服务器配置（地址可随时修改，无需重新编译）。
  Future<void> setServerSettings({
    required String baseUrl,
    required bool enabled,
    String? token,
    String? certSha256,
  }) async {
    final trimmed = baseUrl.trim();
    settingsCtl.serverBaseUrl = trimmed.isEmpty
        ? defaultServerBaseUrl
        : trimmed;
    settingsCtl.useServer = enabled;
    if (token != null) settingsCtl.serverToken = token.trim();
    if (certSha256 != null) {
      settingsCtl.serverCertSha256 = normalizeFingerprint(certSha256);
    }
    await _settingsStore.setServerBaseUrl(settingsCtl.serverBaseUrl);
    await _settingsStore.setUseServer(enabled);
    await _settingsStore.setServerToken(settingsCtl.serverToken);
    await _settingsStore.setServerCertSha256(settingsCtl.serverCertSha256);
    network.rebuildRepository();
    // 换服务器/开关存储后旧列表不再适用，清空后重新拉取并后台补全
    session.resetConversationList();
    await refreshConversations();
    unawaited(_syncAllConversations());
    tts.rebindNetwork();
    notifyListeners();
  }

  // ------------------------------------------------------------ 发送/编辑/重算

  /// 发送消息（含可选图片附件）。
  Future<void> send(
    String text, {
    List<Attachment> attachments = const [],
  }) => turns.send(text, attachments: attachments);

  /// 重新生成第 [index] 条助手回答（不限次数）。
  Future<void> regenerateAt(int index) => turns.regenerateAt(index);

  /// 重新生成最后一条回答（保留兼容入口）。
  Future<void> retry() => turns.retry();

  /// 编辑第 [index] 条用户消息：修改文本后删除该条之后的所有消息并重新生成。
  Future<void> editUserMessage(
    int index,
    String newText, {
    List<Attachment> attachments = const [],
  }) => turns.editUserMessage(index, newText, attachments: attachments);

  /// 停止当前会话的生成（别的会话正在跑的任务不受影响）。
  Future<void> stopGeneration() => turns.stopGeneration();

  /// 进入“修改输入”编辑态：把该用户消息内容带到底部输入区。
  void startEdit(int index) => turns.startEdit(index);

  /// 取消“修改输入”，恢复普通输入态。
  void cancelEdit() => turns.cancelEdit();

  // ------------------------------------------------------------------ 提示

  void showNotice(String text, {bool isError = false}) {
    noticeText = text;
    noticeIsError = isError;
    notifyListeners();
  }

  void clearNotice() {
    noticeText = null;
  }

  @override
  void dispose() {
    // 解绑 tts 的转发：否则控制器再通知会打到已 dispose 的 AppState
    tts.removeListener(notifyListeners);
    settingsCtl.removeListener(notifyListeners);
    turns.dispose();
    super.dispose();
  }
}
