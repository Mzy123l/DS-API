import 'dart:async';

import '../chat_repository.dart';
import '../models.dart';
import '../prompt.dart';
import '../speech.dart';
import '../storage.dart';
import 'network.dart';
import 'settings_controller.dart';

/// 会话/消息存储与视图状态：会话列表 CRUD 与分页、当前会话消息列表、
/// 手写并发代次（_viewTokens）、系统提示词解析与消息合并工具。
///
/// 不持有 ChangeNotifier：由组合根 [AppState] 统一 notifyListeners。
class SessionStore {
  SessionStore({
    required this.network,
    required this.settings,
    required this.db,
  });

  final NetworkConfig network;
  final SettingsController settings;
  final AppDatabase db;

  /// 某会话是否正在生成（由组合根接到 TurnController，恢复任务时判断）。
  bool Function(int conversationId)? isTurnRunning;

  /// 界面提示回调（统一失败文案等）。
  void Function(String text, {bool isError})? onNotice;

  List<Conversation> conversations = [];

  /// 历史列表是否还有更早的一页（服务器分页）
  bool hasMoreConversations = false;

  /// 本机是否已经拉完服务器上的全部会话（启动后台同步完成后为 true）。
  bool _allConversationsLoaded = false;

  /// 启动时会话列表后台同步是否进行中（避免重复触发）。
  bool _syncingConversations = false;

  /// 历史列表翻页是否进行中（避免与后台同步并发改游标）。
  bool _loadingMoreConversations = false;

  /// 当前会话是否还有更早的消息（服务器分页）
  bool hasOlderMessages = false;

  /// 是否正在加载更早的消息（避免重复触发）
  bool loadingOlder = false;

  /// 历史搜索命中（消息级）。空查询时为空列表。
  List<MessageHit> searchHits = [];
  int? currentConversationId;
  String conversationTitle = '新对话';
  List<ChatMessage> messages = [];

  /// 当前会话的系统提示词（`<system>` 标签或编辑对话框写入后更新）。
  String systemPrompt = defaultSystemPrompt;

  /// 当前会话是否开启「回答气泡」：开启后本会话所有回答都包进气泡。
  /// 仅记在本机（按会话 id），换设备不跟随；新对话默认关闭。
  bool answerBubble = false;

  /// [messages] 当前属于哪个会话。切换会话时先清空，避免把上一个会话的内容
  /// 与本次加载结果合并。
  int? _messagesConversationId;

  /// 每个会话的视图代次：加载、发送、编辑、重新生成、回答收尾时自增。
  /// 过期的异步加载结果只能跳过状态更新，不能覆盖更新的界面内容。
  final Map<int, int> _viewTokens = {};

  /// 旧本地历史迁移是否正在执行（避免并发重复上传）
  bool _legacyMigrating = false;

  /// 新对话还没落库时先留在内存的提示词（创建会话时一起写入）。
  String? _pendingSystemPrompt;

  /// 服务器返回的会话列表是否已经拉完（后台同步后不再显示加载更多）。
  bool get allConversationsLoaded => _allConversationsLoaded;

  ChatRepository get store => network.store;

  bool get hasMessages => messages.isNotEmpty;

  bool get isChatView =>
      currentConversationId != null ||
      messages.any(
        (m) => m.role == MessageRole.assistant && m.content.isNotEmpty,
      );

  bool get busy =>
      currentConversationId != null &&
      (isTurnRunning?.call(currentConversationId!) ?? false);

  int bumpViewToken(int convId) =>
      _viewTokens[convId] = (_viewTokens[convId] ?? 0) + 1;

  bool isCurrentView(int convId, int token) =>
      currentConversationId == convId &&
      _messagesConversationId == convId &&
      _viewTokens[convId] == token;

  /// 把消息列表绑到指定会话（发送/编辑/重算把结果写进当前视图前调用）。
  void bindMessagesTo(int convId) => _messagesConversationId = convId;

  /// 当前视图是否正在显示该会话（切走后异步结果不能覆盖别的会话）。
  bool viewMatches(int convId) =>
      currentConversationId == convId && _messagesConversationId == convId;

  // ---------------------------------------------------------------- 会话列表

  Future<void> refreshConversations() async {
    final existing = List<Conversation>.from(conversations);
    try {
      final fresh = await store.refreshConversations();
      conversations = mergeConversations(existing, fresh);
    } catch (_) {
      // 服务器不可用：用本地缓存兜底，保证历史还能看
      conversations = mergeConversations(
        existing,
        await db.listConversations(),
      );
    }
    hasMoreConversations = _allConversationsLoaded
        ? false
        : store.hasMoreConversations;
  }

  /// 按 id 合并会话列表：服务器返回的条目覆盖同 id 的旧值，
  /// 本机已经加载过的更早分页保留下来（不会因为一次刷新而消失）。
  List<Conversation> mergeConversations(
    List<Conversation> existing,
    List<Conversation> incoming,
  ) {
    final byId = <int, Conversation>{
      for (final conv in existing) conv.id: conv,
    };
    for (final conv in incoming) {
      final old = byId[conv.id];
      // 老服务端不返回 system_prompt 时，不能把本机编辑过的值刷成空
      if (old != null &&
          conv.systemPrompt.trim().isEmpty &&
          old.systemPrompt.trim().isNotEmpty) {
        byId[conv.id] = conv.copyWith(systemPrompt: old.systemPrompt);
      } else {
        byId[conv.id] = conv;
      }
    }
    final merged = byId.values.toList()
      ..sort((a, b) {
        final byTime = b.updatedAt.compareTo(a.updatedAt);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
    return merged;
  }

  /// 启动时后台补齐会话列表：把服务器上还有、本机尚未加载的会话全部拉下来。
  Future<void> syncAllConversations() async {
    if (_syncingConversations) return;
    _syncingConversations = true;
    try {
      final all = await store.syncAllConversations();
      conversations = all;
      _allConversationsLoaded = !store.hasMoreConversations;
      hasMoreConversations = store.hasMoreConversations;
    } catch (_) {
      // 网络不可用：保留当前列表与本地缓存，下次启动继续补
    } finally {
      _syncingConversations = false;
    }
  }

  /// 继续加载更早的会话（历史抽屉滑到底部时触发）。
  Future<bool> loadMoreConversations({bool quiet = false}) async {
    if (!hasMoreConversations || _loadingMoreConversations) return false;
    _loadingMoreConversations = true;
    try {
      conversations = await store.loadMoreConversations();
      hasMoreConversations = store.hasMoreConversations;
      if (!hasMoreConversations) _allConversationsLoaded = true;
      return true;
    } on ChatRepositoryException catch (e) {
      if (!quiet) onNotice?.call(e.message, isError: true);
      return false;
    } finally {
      _loadingMoreConversations = false;
    }
  }

  /// 按关键词搜索聊天记录（消息级，供历史页搜索使用）。
  Future<void> searchMessages(String query) async {
    try {
      searchHits = await store.searchMessages(query);
    } on ChatRepositoryException {
      searchHits = await db.searchMessages(query);
    }
  }

  Conversation? conversationById(int id) {
    for (final conv in conversations) {
      if (conv.id == id) return conv;
    }
    return null;
  }

  Future<List<int>> allConversationIds() async {
    try {
      return await store.allConversationIds();
    } on ChatRepositoryException {
      return [for (final conv in conversations) conv.id];
    }
  }

  Future<void> deleteConversations(
    List<int> ids,
    Future<void> Function(int id) cancelTurn,
  ) async {
    if (ids.isEmpty) return;
    // 被删掉的会话不再继续生成：停掉任务并通知服务端取消
    for (final id in ids) {
      await cancelTurn(id);
    }
    try {
      for (final id in ids) {
        await store.deleteConversation(id);
      }
    } catch (e) {
      onNotice?.call(failureText('删除', e), isError: true);
      return;
    }
    // 先从内存列表移除，避免 refresh 的“合并”把已删会话又留下
    conversations = [
      for (final conv in conversations)
        if (!ids.contains(conv.id)) conv,
    ];
  }

  /// 保存中转服务器配置后的列表复位（换服务器后旧列表不再适用）。
  void resetConversationList() {
    conversations = [];
    _allConversationsLoaded = false;
    hasMoreConversations = false;
  }

  // ------------------------------------------------------------ 会话加载/切换

  /// 新建对话：只切换视图（正在输出的回答留在原会话继续跑）。
  void resetView() {
    messages = [];
    _messagesConversationId = null;
    currentConversationId = null;
    conversationTitle = '新对话';
    systemPrompt = defaultSystemPrompt;
    answerBubble = false;
    hasOlderMessages = false;
    loadingOlder = false;
    _pendingSystemPrompt = null;
  }

  /// 切换会话前先清空旧消息（避免上一个会话的内容合并进来）。
  void prepareSwitch(int convId) {
    if (_messagesConversationId != convId) {
      messages = [];
      _messagesConversationId = convId;
    }
    currentConversationId = convId;
  }

  Future<void> loadConversation(Conversation conv) async {
    // 点开的就是当前正在输出的会话：不重载、也不打断生成
    if (conv.id == currentConversationId && busy) return;
    final token = bumpViewToken(conv.id);
    prepareSwitch(conv.id);
    conversationTitle = conv.title;
    // 读回该会话的「回答气泡」开关（服务端会话字段）
    answerBubble = conv.answerBubble;
    hasOlderMessages = false;
    loadingOlder = false;    // 先用本地缓存秒开，再拉服务器最新一页（避免“点历史要等网络”）
    final List<ChatMessage> cached;
    try {
      cached = await db.loadMessages(conv.id, limit: messagePageSize);
    } catch (e) {
      // 以前这种异常会静默丢弃，用户看到的就是“点了历史没反应”
      onNotice?.call('读取本地会话失败：$e', isError: true);
      return;
    }
    if (currentConversationId != conv.id) return;
    // 合并而不是整体替换：等待期间可能正好有回答收尾，不能把它覆盖掉。
    messages = mergeMessagesById(messages, trimTrailingPlaceholder(cached));
    systemPrompt = promptForConversation(
      conv.id,
      messages,
      fallback: conv.systemPrompt,
    );
    if (token == _viewTokens[conv.id]) {
      hasOlderMessages = cached.length >= messagePageSize;
    }
    loadingOlder = false;

    final List<ChatMessage> loaded;
    try {
      loaded = await store.loadLatestMessages(conv.id);
    } catch (e) {
      // 超时/证书/网络等异常同样给用户一个明确提示
      onNotice?.call('加载会话失败：$e', isError: true);
      return;
    }
    // 等待期间用户又切走了就别覆盖
    if (currentConversationId != conv.id) return;
    // 历史里若残留未完成/被中断的空 assistant 占位，进入时去掉，避免显示空白输出。
    // 仍然用合并：旧的分页响应可能比刚完成的回答更早，不能整体覆盖。
    messages = mergeMessagesById(messages, trimTrailingPlaceholder(loaded));
    systemPrompt = promptForConversation(
      conv.id,
      messages,
      fallback: conv.systemPrompt,
    );
    if (token == _viewTokens[conv.id]) {
      hasOlderMessages = store.hasOlderMessagesFor(conv.id);
    }
    loadingOlder = false;
  }

  /// 加载会话后回填会话级设置（会话自己的模式、语音开关）。
  /// 返回该会话保存的模式（可能为 null 表示跟随当前模式）。
  Future<({AppMode? mode, BracketSpeechModeData speech})>
      loadConversationSettings(int convId) async {
    final bracket = await settings.store.bracketModeFor(convId);
    final ttsTool = await settings.store.ttsToolFor(convId);
    final mode = conversationById(convId)?.mode;
    return (
      mode: mode,
      speech: BracketSpeechModeData(bracketMode: bracket, ttsTool: ttsTool),
    );
  }

  /// 按会话 id 载入消息（恢复未完成任务时使用）。
  Future<void> loadConversationById(int id) async {
    bumpViewToken(id);
    prepareSwitch(id);
    // 会话列表里已带「回答气泡」开关
    final conv = conversationById(id);
    answerBubble = conv?.answerBubble ?? false;
    conversationTitle =
        conv?.title ?? '新对话';
    final loaded = await store.loadLatestMessages(id);
    if (currentConversationId != id || _messagesConversationId != id) return;
    messages = mergeMessagesById(messages, trimTrailingPlaceholder(loaded));
    systemPrompt = promptForConversation(id, messages);
    hasOlderMessages = store.hasOlderMessagesFor(id);
  }

  /// App 从后台回到前台：当前会话没有正在生成的回答时，重新对齐一次服务端历史。
  ///
  /// 退后台期间连接可能被系统挂起/切断，服务端却已经生成完；重新拉一页能
  /// 把回答补回界面，而不是一直停在“没有输出”的状态。
  Future<void> refreshCurrentConversation() async {
    final convId = currentConversationId;
    if (convId == null || (isTurnRunning?.call(convId) ?? false)) return;
    try {
      final loaded = await store.loadLatestMessages(convId);
      if (currentConversationId != convId ||
          (isTurnRunning?.call(convId) ?? false)) {
        return;
      }
      messages = mergeMessagesById(
        trimTrailingPlaceholder(messages),
        trimTrailingPlaceholder(loaded),
      );
      hasOlderMessages = store.hasOlderMessagesFor(convId);
    } catch (_) {
      // 网络还没恢复：保持现状，下次回到前台再试
    }
  }

  /// 继续加载更早的消息（聊天页往上翻时触发）。
  Future<void> loadOlderMessages() async {
    final convId = currentConversationId;
    if (convId == null || loadingOlder || !hasOlderMessages) return;
    final token = _viewTokens[convId] ?? 0;
    loadingOlder = true;
    try {
      final older = await store.loadOlderMessages(convId);
      if (currentConversationId != convId) return;
      if (older.isNotEmpty) messages = mergeMessagesById(messages, older);
      refreshPromptFromHistory(convId);
      if (isCurrentView(convId, token)) {
        hasOlderMessages = store.hasOlderMessagesFor(convId);
      }
    } catch (e) {
      onNotice?.call(failureText('加载更早消息', e), isError: true);
    } finally {
      loadingOlder = false;
    }
  }

  /// 在生成新回答前补齐当前会话的全部更早消息。
  ///
  /// 服务器默认只返回最近一页；如果直接拿这一页去拼请求，模型会看不到更早轮次。
  /// 这里只在“确实还有更早页”时多拉几次，普通短会话没有额外请求。
  Future<void> ensureFullHistory(int convId) async {
    // 界面上的 hasOlder 可能来自“本地缓存刚好满一页”的保守判断；
    // 两者只要有一个为真，就尝试把更早页补齐。
    final viewHasOlder = _messagesConversationId == convId && hasOlderMessages;
    if (!viewHasOlder && !store.hasOlderMessagesFor(convId)) return;
    final older = await store.loadAllOlderMessages(convId);
    if (older.isNotEmpty) {
      messages = mergeMessagesById(messages, older);
      _messagesConversationId = convId;
      // 老会话的 `<system>` 可能只在早前页里：补齐后按最新的标签刷新
      refreshPromptFromHistory(convId);
    }
    hasOlderMessages = store.hasOlderMessagesFor(convId);
  }

  // ------------------------------------------------------------ 消息合并工具

  /// 去掉尾部未完成的空 assistant 占位（历史残留）。
  List<ChatMessage> trimTrailingPlaceholder(List<ChatMessage> list) {
    final result = List<ChatMessage>.from(list);
    while (result.isNotEmpty &&
        result.last.role == MessageRole.assistant &&
        result.last.content.isEmpty &&
        result.last.reasoning.isEmpty) {
      result.removeLast();
    }
    return result;
  }

  /// 按消息 id 合并两份消息列表：id 相同以后者为准，无 id 的本地占位保留在末尾。
  ///
  /// 用于“本地已有刚完成的回答，但服务器分页响应更早”的场景，避免旧响应把
  /// 新回答整体覆盖掉。
  List<ChatMessage> mergeMessagesById(
    List<ChatMessage> existing,
    List<ChatMessage> incoming,
  ) {
    final byId = <int, ChatMessage>{};
    final withoutId = <ChatMessage>[];
    for (final msg in existing) {
      final id = msg.id;
      if (id == null) {
        withoutId.add(msg);
      } else {
        byId[id] = msg;
      }
    }
    for (final msg in incoming) {
      final id = msg.id;
      if (id != null) byId[id] = msg;
    }
    final ids = byId.keys.toList()..sort();
    return [for (final id in ids) byId[id]!, ...withoutId];
  }

  /// 消息在列表中的位置：优先按服务器 id 找，找不到再按原对象身份找。
  int indexOfMessage(List<ChatMessage> list, ChatMessage target) {
    final id = target.id;
    if (id != null) {
      final byId = list.indexWhere(
        (msg) => msg.id == id && msg.role == target.role,
      );
      if (byId >= 0) return byId;
    }
    return list.indexWhere((msg) => identical(msg, target));
  }

  /// 更新某条消息（如思考区展开/折叠）。
  void replaceMessage(int index, ChatMessage message) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = message;
  }

  // ------------------------------------------------------------ 系统提示词

  /// 从历史消息里反解系统提示词（最后一条带 `<system>` 的用户消息）。
  String systemPromptFrom(List<ChatMessage> list) {
    // A 方案：最后一次覆盖 —— 取最后一条带 <system> 的用户消息，
    // 与实时发送时的行为一致（谁最后写谁生效）
    String? found;
    for (final msg in list) {
      if (msg.role != MessageRole.user) continue;
      final parsed = parseSystemPrompt(msg.content);
      if (parsed.system != null) found = parsed.system;
    }
    return found ?? defaultSystemPrompt;
  }

  /// 某个会话当前应使用的系统提示词：
  /// 优先会话自己保存的最新值，其次从历史 `<system>` 反解，最后默认值。
  String promptForConversation(
    int convId,
    List<ChatMessage> list, {
    String fallback = '',
  }) {
    final fromList = conversationById(convId)?.systemPrompt ?? '';
    final stored = (fromList.trim().isNotEmpty ? fromList : fallback).trim();
    if (stored.isNotEmpty) return stored;
    return systemPromptFrom(list);
  }

  /// 保存时把“空输入”归一成默认值：显式保存默认值也写入数据库，
  /// 这样恢复默认后不会再从历史 `<system>` 里被旧标签“反解”回来。
  String encodeSystemPrompt(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return defaultSystemPrompt;
    return trimmed;
  }

  /// 更新会话列表里缓存的提示词，供历史页/对话框立即看到最新值。
  void setConversationPrompt(int convId, String prompt) {
    final index = conversations.indexWhere((conv) => conv.id == convId);
    if (index >= 0) {
      conversations[index] = conversations[index].copyWith(
        systemPrompt: prompt,
      );
    }
  }

  /// 系统提示词的最新值：`<system>` 标签或编辑对话框写入后都走这里。
  ///
  /// 当前会话已创建时立即落库；还没创建（新对话首条消息之前）就先留在
  /// 内存里，等创建会话时一起写入。
  Future<void> applySystemPrompt(String prompt) async {
    final trimmed = prompt.trim();
    systemPrompt = trimmed.isEmpty ? defaultSystemPrompt : trimmed;
    _pendingSystemPrompt = trimmed.isEmpty ? null : trimmed;
    final convId = currentConversationId;
    if (convId == null) return;
    final stored = encodeSystemPrompt(systemPrompt);
    setConversationPrompt(convId, stored);
    try {
      await store.updateSystemPrompt(convId, stored);
    } catch (e) {
      onNotice?.call('系统提示词保存失败：$e', isError: true);
    }
  }

  /// 首条消息创建会话时写入待存的提示词（内存里留过的那份）。
  String promptForNewConversation() =>
      encodeSystemPrompt(_pendingSystemPrompt ?? systemPrompt);

  /// 老会话没有单独保存提示词时，翻到更早的消息可能才发现 `<system>`：
  /// 此时按历史里的最后一个标签刷新当前值。
  void refreshPromptFromHistory(int convId) {
    if (currentConversationId != convId) return;
    final stored = conversationById(convId)?.systemPrompt.trim() ?? '';
    if (stored.isNotEmpty) return;
    final next = systemPromptFrom(messages);
    if (next == systemPrompt) return;
    systemPrompt = next;
  }

  /// 设置当前会话的「回答气泡」。
  ///
  /// 新对话还没落库时只记在内存，首条消息创建会话时随会话一起写到服务端。
  Future<void> setAnswerBubble(bool value) async {
    answerBubble = value;
    final id = currentConversationId;
    if (id != null) {
      try {
        await store.setAnswerBubble(id, value);
      } catch (_) {
        // 老服务端还没有这个字段：界面已生效，忽略同步失败
      }
    }
  }

  // ------------------------------------------------------------ 旧数据迁移

  /// 把旧的本地历史一次性上传到服务器（失败下次启动重试）。
  Future<void> migrateLegacyHistory() async {
    if (_legacyMigrating || !settings.useServer) return;
    try {
      if (await settings.store.legacyImported) return;
      if (!await db.hasLegacyData()) return;
    } catch (_) {
      return;
    }
    final repo = store;
    if (repo is! ServerChatRepository) return;
    _legacyMigrating = true;
    try {
      final legacy = await db.loadLegacyConversations();
      for (final conv in legacy) {
        final newId = await repo.createConversation(conv.title, conv.model);
        final msgs = await db.loadLegacyMessages(conv.id);
        for (var i = 0; i < msgs.length; i += 50) {
          final end = (i + 50) > msgs.length ? msgs.length : i + 50;
          await repo.appendMessagesChunk(newId, msgs.sublist(i, end));
        }
      }
      await db.dropLegacy();
      await settings.store.setLegacyImported(true);
      await refreshConversations();
      // 迁移可能新建了多页会话，后台再补一次全量列表
      unawaited(syncAllConversations());
      onNotice?.call('本机历史已迁移到服务器');
    } catch (_) {
      // 网络等原因失败：保留本地数据，下次启动重试
    } finally {
      _legacyMigrating = false;
    }
  }

  /// 统一失败文案：把超时/证书/网络等非仓储异常也变成用户看得见的提示。
  String failureText(String action, Object error) {
    final detail = error is ChatRepositoryException ? error.message : '$error';
    return '$action失败：$detail';
  }
}

/// 会话级语音设置（加载会话时一并读回）。
class BracketSpeechModeData {
  const BracketSpeechModeData({
    required this.bracketMode,
    required this.ttsTool,
  });

  final BracketSpeechMode bracketMode;
  final bool ttsTool;
}
