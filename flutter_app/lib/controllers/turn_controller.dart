import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../chat_repository.dart';
import '../deepseek_client.dart';
import '../foreground_service.dart';
import '../models.dart';
import '../prompt.dart';
import '../speech.dart';
import 'network.dart';
import 'session_store.dart';
import 'settings_controller.dart';
import 'tts_controller.dart';

/// 一次生成流程的种类：发送新消息 / 编辑用户消息重算 / 重新生成回答。
///
/// 三条流程合并成一个核心 [_runTurnFlow]：差异点只有是否创建会话、
/// 截断位置、占位消息与上下文构造方式。
enum TurnFlowKind { send, edit, regenerate }

/// 发送 / 编辑 / 重算编排 + 流式接收与合并刷新 + 后台恢复。
///
/// 不持有 ChangeNotifier：由组合根 [AppState] 统一 notifyListeners。
class TurnController {
  TurnController({
    required this.session,
    required this.settings,
    required this.network,
    required this.tts,
  }) {
    // TTS 工具生成的音频记到正在生成的这一轮，收尾时随消息一起落库
    tts.onTurnAudio = (path) async => _rememberTurnAudio(path);
    session.isTurnRunning = (convId) => _turns.containsKey(convId);
  }

  final SessionStore session;
  final SettingsController settings;
  final NetworkConfig network;
  final TtsController tts;

  /// 界面提示回调（组合根接到 AppState.showNotice）。
  void Function(String text, {bool isError})? onNotice;

  /// 通知界面刷新（组合根接到 AppState.notifyListeners）。
  void Function()? onNotify;

  /// 正在生成的回答：每个会话一份运行态。
  ///
  /// 切走会话只是不再把增量写进界面，流本身继续接收；切回来按运行态接着显示，
  /// 所以多个会话可以同时提问、同时输出，互不打断。
  final Map<int, _RunningTurn> _turns = {};

  /// 是否“贴底跟随”：用户上翻看历史时为 false，此时流式内容只缓冲不渲染，
  /// 保证阅读位置纹丝不动（回到最底下再一次性补上）
  bool _following = true;

  /// 当前正在编辑的用户消息下标；null 表示未处于编辑态。
  int? editingIndex;

  /// 需要把消息列表拉回底部的信号：每次开始新一轮提问（发送/编辑/重新生成）自增。
  /// 用显式信号而不是「内容变长」判断，避免流式输出时把正在翻看历史的用户拉回底部。
  int scrollToken = 0;

  /// 服务端音频 id → 本地文件路径（避免重复下载同一段音频）。
  final Map<String, String> generatedAudio = {};

  void _notice(String text, {bool isError = false}) =>
      onNotice?.call(text, isError: isError);

  void _notify() => onNotify?.call();

  bool get busy => _turns.containsKey(session.currentConversationId);

  /// 正在生成的会话 id（历史列表等可用于标识）。
  Set<int> get runningConversationIds => _turns.keys.toSet();

  // -------------------------------------------------------------- 视图跟随

  /// 消息列表贴底状态变化（由 MessagesView 回调）。
  void setFollowing(bool value) {
    if (_following == value) return;
    _following = value;
    // 回到最底下：把期间攒下的内容一次补上
    if (value) _flushRunningTurns();
  }

  /// 进入会话视图：恢复贴底跟随并退出编辑态（打开历史会话时用）。
  void enterConversationView() {
    _following = true;
    editingIndex = null;
  }

  /// 把当前会话正在生成的回答一次性写进界面（回到列表底部时用）。
  void _flushRunningTurns() {
    final turn = _turns[session.currentConversationId];
    if (turn == null) return;
    _syncTurnToView(turn, force: true);
  }

  // ---------------------------------------------------------- 三条流程入口

  /// 发送消息（含可选图片附件）。
  Future<void> send(
    String text, {
    List<Attachment> attachments = const [],
  }) async {
    if (busy) {
      _notice('正在回复中，请稍候');
      return;
    }
    // 处于“修改输入”编辑态时，发送即提交编辑（重新生成）
    if (editingIndex != null) {
      await editUserMessage(editingIndex!, text, attachments: attachments);
      return;
    }
    await _runTurnFlow(kind: TurnFlowKind.send, text: text, attachments: attachments);
  }

  /// 重新生成第 [index] 条助手回答（不限次数）。
  /// 做法：截断到该条之前，基于上文重新流式生成；该条及其后的旧回答都会被替换。
  Future<void> regenerateAt(int index) async {
    if (busy) {
      _notice('正在回复中，请稍候');
      return;
    }
    if (index < 0 || index >= session.messages.length) return;
    if (session.messages[index].role != MessageRole.assistant) {
      _notice('仅助手回答可重新生成');
      return;
    }
    await _runTurnFlow(kind: TurnFlowKind.regenerate, targetIndex: index);
  }

  /// 重新生成最后一条回答（保留兼容入口）。
  Future<void> retry() async {
    if (busy || session.messages.isEmpty) return;
    if (session.messages.last.role != MessageRole.assistant) return;
    await regenerateAt(session.messages.length - 1);
  }

  /// 编辑第 [index] 条用户消息：修改文本后删除该条之后的所有消息，并基于新提问重新生成。
  Future<void> editUserMessage(
    int index,
    String newText, {
    List<Attachment> attachments = const [],
  }) async {
    if (busy) {
      _notice('正在回复中，请稍候');
      return;
    }
    if (index < 0 || index >= session.messages.length) return;
    if (session.messages[index].role != MessageRole.user) {
      _notice('仅可编辑用户消息');
      return;
    }
    await _runTurnFlow(
      kind: TurnFlowKind.edit,
      text: newText,
      attachments: attachments,
      targetIndex: index,
    );
  }

  /// 进入“修改输入”编辑态：把该用户消息内容带到底部输入区。
  void startEdit(int index) {
    if (busy) {
      _notice('正在回复中，请稍候');
      return;
    }
    if (index < 0 || index >= session.messages.length) return;
    if (session.messages[index].role != MessageRole.user) {
      _notice('仅可编辑用户消息');
      return;
    }
    editingIndex = index;
    _notify();
  }

  /// 取消“修改输入”，恢复普通输入态。
  void cancelEdit() {
    if (editingIndex == null) return;
    editingIndex = null;
    _notify();
  }

  // ------------------------------------------------------------- 核心流程

  /// 发送 / 编辑 / 重新生成合并后的核心流程。
  ///
  /// 差异点：
  /// - [TurnFlowKind.send]：解析 `<system>`、附件上传、先落库用户消息、
  ///   可能触发标题生成，最后追加空 assistant 占位；
  /// - [TurnFlowKind.edit]：按目标消息截断、替换为编辑后的消息再落库；
  /// - [TurnFlowKind.regenerate]：按目标回答截断、不落库新消息。
  Future<void> _runTurnFlow({
    required TurnFlowKind kind,
    String text = '',
    List<Attachment> attachments = const [],
    int? targetIndex,
  }) async {
    // 1. 解析正文与系统提示词（发送/编辑才有新文本）
    String? systemOverride;
    String trimmed = '';
    if (kind != TurnFlowKind.regenerate) {
      final parsed = parseSystemPrompt(text);
      trimmed = parsed.text.trim();
      systemOverride = parsed.system;
      if (kind == TurnFlowKind.send) {
        // 只发一个 <system> 块：不产生消息，但提示词要立即保存下来
        if (trimmed.isEmpty && attachments.isEmpty) {
          if (systemOverride != null) {
            await session.applySystemPrompt(systemOverride);
            _notify();
          }
          return;
        }
      } else if (trimmed.isEmpty) {
        _notice('内容不能为空', isError: true);
        return;
      }
    }
    // 新写入的 <system> 覆盖当前会话的提示词（最后一次生效）
    if (systemOverride != null) {
      await session.applySystemPrompt(systemOverride);
      _notify();
    }

    // 2. 直连 Key 检查：发送在创建会话前拦截；编辑/重算允许先截断再提示
    final hasKey = settings.apiKey != null && settings.apiKey!.isNotEmpty;
    if (kind == TurnFlowKind.send && !hasKey) {
      _notice('请先配置 DeepSeek API Key', isError: true);
      return;
    }

    // 3. 首条消息时创建会话
    if (session.currentConversationId == null) {
      try {
        session.currentConversationId = await session.store.createConversation(
          '新对话',
          settings.effectiveModel,
          systemPrompt: session.promptForNewConversation(),
          answerBubble: session.answerBubble,
        );
      } catch (e) {
        _notice('创建会话失败：$e', isError: true);
        return;
      }
    }
    final convId = session.currentConversationId!;

    // 4. 发送/编辑/重算前补齐更早的页：模型才能看到完整上下文，
    //    截断位置也才是全局下标而不是窗口下标。
    // 编辑/重算先用窗口下标捕获目标对象：补齐历史会在列表头部插入更早页，
    // 下标会位移，之后必须按对象身份重新定位。
    ChatMessage? originalTarget;
    if (kind != TurnFlowKind.send) {
      originalTarget = session.messages[targetIndex!];
    }
    try {
      await session.ensureFullHistory(convId);
    } catch (e) {
      _notice(
        session.failureText(switch (kind) {
          TurnFlowKind.send => '加载历史上下文',
          TurnFlowKind.edit => '加载编辑上下文',
          TurnFlowKind.regenerate => '加载重新生成上下文',
        }, e),
        isError: true,
      );
      return;
    }
    if (kind == TurnFlowKind.send) {
      session.bindMessagesTo(convId);
      if (session.currentConversationId != convId) return;
    } else if (!session.viewMatches(convId)) {
      return;
    }

    // 5. 编辑/重算：按对象身份重新定位目标消息（补齐历史后下标已位移）
    ChatMessage? target;
    var targetPos = -1;
    if (kind != TurnFlowKind.send) {
      targetPos = session.indexOfMessage(session.messages, originalTarget!);
      if (targetPos < 0) {
        _notice(
          kind == TurnFlowKind.edit
              ? '找不到要编辑的消息，请重新打开会话'
              : '找不到要重新生成的消息，请重新打开会话',
          isError: true,
        );
        return;
      }
      target = session.messages[targetPos];
    }

    List<Map<String, dynamic>> input;

    if (kind == TurnFlowKind.send) {
      // 6a. 发送：附件 → 结构化消息 → 先落库再进内存
      final uploaded = await uploadDocuments(attachments);
      final parts = attachmentParts(uploaded);
      final userMsg = ChatMessage(
        role: MessageRole.user,
        // 只存正文：系统提示词已经单独存在会话里，消息里不再保留标签；
        // 附件信息全在 files 里，不再拼 `【文件：…】` 标记。
        content: trimmed,
        imageDataUrls: parts.images,
        files: parts.files,
        timestamp: DateTime.now(),
      );
      // 先落库（服务器存），拿到 id 后再进内存，保证分页游标一致。
      // 等待期间用户切走时不再写进当前列表，避免把消息加到别的会话里。
      final ChatMessage savedUser;
      try {
        savedUser = await session.store.appendMessage(convId, userMsg);
      } catch (e) {
        _notice(session.failureText('发送', e), isError: true);
        return;
      }
      if (!session.viewMatches(convId)) return;
      session.messages.add(savedUser);

      // 标题交给模型生成（JSON 输出）；生成前保持“新对话”。
      // B 方案：只在前 3 轮内刷新（话题通常这时定型），之后冻结。
      final userTurns = session.messages
          .where((m) => m.role == MessageRole.user)
          .length;
      if (userTurns <= 3) {
        unawaited(_generateTitle(_titleContext(), convId));
      }
      scrollToken++;
      session.messages.add(
        ChatMessage(
          role: MessageRole.assistant,
          content: '',
          timestamp: DateTime.now(),
        ),
      );
      await session.refreshConversations();
      _notify();

      input = buildResponsesInput(session.messages, includeReasoning: settings.webSearch);
    } else {
      // 6b. 编辑/重算：截断到目标之前，基于上文重新生成
      final List<ChatMessage> head;
      if (kind == TurnFlowKind.edit) {
        final uploaded = await uploadDocuments(attachments);
        final parts = attachmentParts(uploaded);
        editingIndex = null;
        // 保留目标之前的全部消息，用编辑后的该条替换原消息，并删除其后的全部消息。
        head = List<ChatMessage>.from(session.messages.sublist(0, targetPos));
        head.add(
          target!.copyWith(
            // 只存正文：提示词走会话的 system_prompt，不在消息里保留标签
            content: trimmed,
            imageDataUrls: parts.images,
            files: parts.files,
          ),
        );
      } else {
        head = List<ChatMessage>.from(session.messages.sublist(0, targetPos));
      }
      input = buildResponsesInput(head, includeReasoning: settings.webSearch);
      if (input.isEmpty) {
        _notice(
          kind == TurnFlowKind.edit ? '内容为空' : '没有可重新生成的上下文',
          isError: true,
        );
        return;
      }
      session.bumpViewToken(convId);
      // 被截断消息引用的音频不再可播：清掉本地临时缓存（服务端那边
      // 会按 truncate 返回的孤儿音频自己清理）。
      tts.dropLocalAudioCache(session.messages.sublist(targetPos));
      // 按服务器消息 id 截断：删除目标消息及其后的全部内容。
      // 旧接口 keep 只在目标还没有 id 时作为兜底；此时历史已补齐，下标是全局下标。
      try {
        if (target!.id != null) {
          await session.store.truncateMessagesBefore(
            convId,
            target.id!,
            keepFallback: targetPos,
          );
        } else {
          await session.store.truncateMessages(convId, targetPos);
        }
        if (kind == TurnFlowKind.edit) {
          if (!session.viewMatches(convId)) return;
          final saved = await session.store.appendMessage(convId, head.last);
          if (!session.viewMatches(convId)) return;
          session.messages = [...head.sublist(0, head.length - 1), saved];
        } else {
          if (!session.viewMatches(convId)) return;
          // 重新生成：服务端已按 before_id 截断，内存列表也要同步截断，
          // 否则旧回答留在界面上、新回答又追加到后面（不覆盖旧回答）。
          session.messages = List<ChatMessage>.from(head);
        }
        session.bindMessagesTo(convId);
        session.hasOlderMessages = false;
      } catch (e) {
        _notice(
          session.failureText(kind == TurnFlowKind.edit ? '编辑' : '重新生成', e),
          isError: true,
        );
        return;
      }
      scrollToken++;
      _notify();

      // 无可用 Key 时仅保留截断结果，提示用户补充 Key 后继续
      if (!hasKey) {
        _notice('已更新消息并删除后续内容，请先配置 DeepSeek API Key', isError: true);
        await session.refreshConversations();
        _notify();
        return;
      }
      session.messages.add(
        ChatMessage(
          role: MessageRole.assistant,
          content: '',
          timestamp: DateTime.now(),
        ),
      );
      _notify();
    }

    _startTurn(
      input: input,
      reasonEffort: settings.reasoningEffort,
      deepThink: settings.deepThink,
      webSearch: settings.webSearch,
    );
  }

  // ------------------------------------------------------------ 发起与接收

  /// 发起一次生成：每个会话一个独立客户端与运行态，互不打断、可同时进行。
  void _startTurn({
    required List<Map<String, dynamic>> input,
    required String reasonEffort,
    required bool deepThink,
    required bool webSearch,
  }) {
    final key = settings.apiKey;
    final convId = session.currentConversationId;
    if (key == null || key.isEmpty || convId == null) return;
    final turn = _RunningTurn(
      conversationId: convId,
      client: network.createClient(),
    );
    _turns[convId] = turn;
    _notify();
    unawaited(ForegroundTaskManager.start());
    // 系统提示词随请求下发（Anthropic 走 system，Responses 走 instructions）
    turn.client.systemPrompt = session.systemPrompt;
    // 语音生成工具：会话级开关控制；没接语音服务（测试/降级）时也不声明
    if (tts.ttsToolEnabled && tts.speech != null) {
      turn.client.enableTtsTool = true;
      turn.client.ttsRunner = tts.runTtsTool;
    }
    unawaited(
      _sendTurn(
        turn: turn,
        input: input,
        key: key,
        convId: convId,
        reasonEffort: reasonEffort,
        deepThink: deepThink,
        webSearch: webSearch,
      ),
    );
  }

  /// 真正发请求前先整理图片，再交给客户端。
  ///
  /// 图片按文件真实内容确认格式、超出上游限制的按需缩小：历史消息里
  /// 之前存进去的超尺寸图重发时也不会再被上游拒掉（unsupported image）。
  Future<void> _sendTurn({
    required _RunningTurn turn,
    required List<Map<String, dynamic>> input,
    required String key,
    required int convId,
    required String reasonEffort,
    required bool deepThink,
    required bool webSearch,
  }) async {
    ({List<Map<String, dynamic>> input, int dropped}) prepared;
    try {
      prepared = await prepareInputImages(input);
    } catch (e) {
      await _handleTurnError(turn, '图片处理失败：$e');
      return;
    }
    // 处理图片期间用户可能已经停止/删除了会话，别再发出去
    if (turn.finished || turn.stopped || !identical(_turns[convId], turn)) {
      return;
    }
    if (prepared.dropped > 0) {
      _notice('有 ${prepared.dropped} 张图片的格式上游不支持（仅 JPG/PNG/GIF/WebP），已跳过');
    }
    final hasImages = inputHasImages(prepared.input);
    final hasFiles = inputHasFiles(prepared.input);
    // 专家模式用的 deepseek-v4-pro 不支持识图：带图的一轮自动改走快速模型，
    // 否则上游直接 400（unsupported image），用户只能看到一句读不懂的错误。
    // 全家桶服务端工具（联网搜索 / 阅读链接）同样只支持 deepseek-flash。
    var model = modelForRequest(settings.effectiveModel, hasImages: hasImages);
    if (hasImages && model != settings.effectiveModel) {
      _notice('${settings.mode.label}不支持识图，本轮图片已改用快速模式（$model）发送');
    }
    final familyReady = modelSupportsFamilyTools(model);
    if (webSearch && !familyReady) {
      model = familyModel;
      _notice('${settings.mode.label}不支持联网搜索，本轮已改用 $model 发送');
    }
    // 有已上传文档时才声明 ocr 工具（模型自己决定要不要读文字）
    turn.client.enableOcrTool = hasFiles;
    await turn.client.send(
      input: prepared.input,
      model: model,
      protocol: settings.protocol,
      thinkingEnabled: deepThink,
      reasoningEffort: reasonEffort,
      apiKey: key,
      webSearch: webSearch,
      conversationId: convId,
      onReasoningDelta: (d) => _appendTurnDelta(turn, reasoning: d),
      onContentDelta: (d) => _appendTurnDelta(turn, content: d),
      onReasoningTimed: (ms) => _setTurnReasoningMs(turn, ms),
      onSources: (sources) => _appendTurnSources(turn, sources),
      onJobStarted: (jobId) {
        // 新一轮任务开始：服务端会复用同一条 pending 助手行，
        // 先清掉上一轮快照里的 id，等这一次的快照/checkpoint 再写回来。
        turn.messageId = null;
        // 联网搜索的多轮任务号只用于停止当前轮；服务端会把每一轮进度
        // 更新到同一条 pending 行，客户端断开也不会丢。
        if (webSearch) {
          turn.jobId = jobId;
        } else {
          unawaited(_rememberPendingJob(turn, jobId));
        }
      },
      onSnapshot: (snapshot) => _applyTurnSnapshot(turn, snapshot),
      onDone: () => unawaited(_finishTurn(turn)),
      onJobLost: () => unawaited(_handleJobLost(turn)),
      onError: (e) => unawaited(_handleTurnError(turn, e)),
    );
  }

  /// 停止当前会话的生成（别的会话正在跑的任务不受影响）。
  Future<void> stopGeneration() async {
    final turn = _turns[session.currentConversationId];
    if (turn == null) return;
    // 还没真正发出请求（正在整理图片）时也要拦住，避免停止后又偷偷发出去
    turn.stopped = true;
    // cancel() 内部同时通知服务端停止生成
    final jobId = turn.jobId;
    turn.client.cancel();
    if (jobId != null) {
      // 中转模式：服务端会把已生成的部分落库。这里等它的快照回来对齐正文与
      // 消息 id，收尾时就只补本地缓存，不会和这次服务端落库各存一条。
      final snapshot = await turn.client.waitJobSnapshot(jobId);
      if (snapshot != null) _applyTurnSnapshot(turn, snapshot);
    }
    await _finishTurn(turn, removeEmpty: true);
  }

  /// 出错收尾：先把服务端已经落库的那条消息 id 对齐，避免客户端再追加一条。
  Future<void> _handleTurnError(_RunningTurn turn, String message) async {
    final jobId = turn.jobId;
    if (jobId != null && turn.client.useRelay) {
      final snapshot = await turn.client.waitJobSnapshot(jobId);
      if (snapshot != null) _applyTurnSnapshot(turn, snapshot);
    }
    await _finishTurn(turn);
    _notice(message, isError: true);
  }

  /// 丢弃某会话的运行态（会话被删除时用）：同时通知服务端停止生成。
  void dropTurn(int conversationId) {
    final turn = _turns.remove(conversationId);
    unawaited(_clearPendingJob(conversationId));
    if (turn == null) return;
    turn.finished = true;
    turn.stopped = true;
    turn.flushTimer?.cancel();
    turn.flushTimer = null;
    turn.client.cancel();
    if (_turns.isEmpty) unawaited(ForegroundTaskManager.stop());
    _notify();
  }

  // ------------------------------------------------------------ 流式增量

  /// 流式增量：先累积到该会话的运行态，稍后合并刷新界面。
  ///
  /// 每秒几十个增量时按 80ms 合并一次，能显著减少整树重建；
  /// 会话不在前台时只累积不渲染，切回来一次性补上。
  void _appendTurnDelta(
    _RunningTurn turn, {
    String reasoning = '',
    String content = '',
  }) {
    if (reasoning.isEmpty && content.isEmpty) return;
    turn.reasoning += reasoning;
    turn.content += content;
    turn.dirty = true;
    _scheduleTurnFlush(turn);
  }

  void _setTurnReasoningMs(_RunningTurn turn, int ms) {
    turn.reasoningMs = ms;
    turn.dirty = true;
    _scheduleTurnFlush(turn);
  }

  /// 追加联网搜索来源（按 URL 去重）。
  void _appendTurnSources(_RunningTurn turn, List<ChatSource> sources) {
    if (sources.isEmpty) return;
    final seen = {for (final source in turn.sources) source.url};
    final added = [
      for (final source in sources)
        if (seen.add(source.url)) source,
    ];
    if (added.isEmpty) return;
    turn.sources = [...turn.sources, ...added];
    turn.dirty = true;
    _scheduleTurnFlush(turn);
  }

  /// 服务端快照是权威数据：直接覆盖本地累积的增量（断线补齐时用）。
  void _applyTurnSnapshot(_RunningTurn turn, RemoteSnapshot snapshot) {
    // 服务端快照可能比本地已显示的增量短（网络/落库时序、max_tokens 提示等），
    // 只在快照更长或等长时覆盖，避免最后一段内容被旧快照“回退”掉。
    if (snapshot.content.length >= turn.content.length) {
      turn.content = snapshot.content;
    }
    if (snapshot.reasoning.length >= turn.reasoning.length) {
      turn.reasoning = snapshot.reasoning;
    }
    if (snapshot.sources.isNotEmpty) {
      final byUrl = <String, ChatSource>{
        for (final source in turn.sources) source.url: source,
        for (final source in snapshot.sources) source.url: source,
      };
      turn.sources = byUrl.values.toList();
    }
    if (snapshot.reasoningMs > turn.reasoningMs) {
      turn.reasoningMs = snapshot.reasoningMs;
    }
    // 服务端执行 text_to_speech 时音频在它那边：只记下 id，字节等用户点播再取
    if (snapshot.audio.isNotEmpty && turn.client.useRelay) {
      _rememberRemoteAudio(turn, snapshot.audio);
    }
    if (snapshot.messageId != null) {
      turn.messageId = snapshot.messageId;
    } else if (snapshot.resultReady) {
      // 服务端明确说这一轮没有落库（例如联网搜索的中间轮次被清掉）：
      // 不能再拿之前的 checkpoint id 当成“已保存”，否则收尾时只写本地缓存，
      // 重进会话就会被服务端最新一页覆盖掉。
      turn.messageId = null;
    }
    turn.dirty = true;
    _scheduleTurnFlush(turn);
  }

  /// 记录服务端生成的音频 id（快照里只给 id，音频本体留在服务器）。
  ///
  /// **不预取字节**：用户点播放才按 id 拉一次，点下载才存到系统下载目录；
  /// 这样既不占手机空间，也不会为没人听的音频白花流量。
  void _rememberRemoteAudio(_RunningTurn turn, List<ChatFile> files) {
    final existing = {for (final id in turn.audioFiles) id};
    final added = [
      for (final file in files)
        if (existing.add(file.id)) file.id,
    ];
    if (added.isEmpty) return;
    turn.audioFiles = [...turn.audioFiles, ...added];
    turn.dirty = true;
    _scheduleTurnFlush(turn);
    _notify();
  }

  /// TTS 工具合成的音频落到当前会话的运行态（收尾时随消息一起落库）。
  void _rememberTurnAudio(String path) {
    final turn = _turns[session.currentConversationId];
    if (turn == null) return;
    turn.audioFiles = [...turn.audioFiles, path];
    _scheduleTurnFlush(turn);
    _notify();
  }

  void _scheduleTurnFlush(_RunningTurn turn) {
    turn.flushTimer ??= Timer(const Duration(milliseconds: 80), () {
      turn.flushTimer = null;
      _syncTurnToView(turn);
    });
  }

  /// 把运行态写进界面。
  ///
  /// 只作用于「正在显示的会话」：后台会话的内容先留在运行态里，等切回来再补。
  /// [force] 为 true 时忽略「用户是否正在上翻历史」（切回会话 / 回到列表底部）。
  void _syncTurnToView(_RunningTurn turn, {bool force = false}) {
    if (turn.conversationId != session.currentConversationId) return;
    if (!turn.dirty && !force) return;
    // 用户正在上翻看历史：先不写列表，回到最底下再补（否则内容变化把位置顶走）
    if (!_following && !force) return;
    final messages = session.messages;
    if (messages.isEmpty) return;
    final index = messages.length - 1;
    final last = messages[index];
    if (last.role != MessageRole.assistant) return;
    // 尾条可能已经不是本轮的占位（例如并发加载/切换刚好完成），
    // 这时只允许写自己的消息，不能覆盖别人的回答。
    if (!_belongsToTurn(last, turn)) return;
    // 正文一开始输出，就把思考块自动收起（本轮只做一次）
    var thinkingExpanded = last.thinkingExpanded;
    if (turn.content.isNotEmpty &&
        !turn.autoCollapsed &&
        turn.reasoning.isNotEmpty) {
      thinkingExpanded = false;
      turn.autoCollapsed = true;
    }
    turn.dirty = false;
    final unchanged =
        last.id == turn.messageId &&
        last.content == turn.content &&
        last.reasoning == turn.reasoning &&
        last.reasoningMs == turn.reasoningMs &&
        last.thinkingExpanded == thinkingExpanded &&
        last.sources.length == turn.sources.length &&
        last.audioFiles.length == turn.audioFiles.length;
    if (unchanged) return;
    session.replaceMessage(
      index,
      last.copyWith(
        id: turn.messageId,
        content: turn.content,
        reasoning: turn.reasoning,
        reasoningMs: turn.reasoningMs,
        sources: turn.sources,
        audioFiles: turn.audioFiles,
        thinkingExpanded: thinkingExpanded,
      ),
    );
    _notify();
  }

  /// 把某会话正在生成的回答接回界面（切回会话 / 重开 App 时用）。
  void _attachTurnToView(_RunningTurn turn) {
    if (turn.conversationId != session.currentConversationId) return;
    final messages = session.messages;
    final last = messages.isEmpty ? null : messages.last;
    if (last != null) _adoptCheckpoint(last, turn);
    if (last == null || !_belongsToTurn(last, turn)) {
      session.messages = [
        ...messages,
        ChatMessage(
          role: MessageRole.assistant,
          content: '',
          timestamp: DateTime.now(),
        ),
      ];
    }
    // 尾条已是助手消息：空占位直接复用；服务端先落库的同一条回答用运行态覆盖，
    // 避免同一轮回答在界面上出现两条。
    turn.dirty = true;
    _syncTurnToView(turn, force: true);
  }

  /// 服务端 checkpoint 可能已经把部分回答写进历史：续接时接管这条消息，
  /// 避免在它后面再插一条同 id 的占位，或在恢复失败时把已保存部分删掉。
  void _adoptCheckpoint(ChatMessage last, _RunningTurn turn) {
    if (last.role != MessageRole.assistant ||
        last.content.isEmpty ||
        last.id == null) {
      return;
    }
    if (turn.messageId != null && turn.messageId != last.id) return;
    final prefixMatch =
        turn.content.isNotEmpty &&
        (last.content.startsWith(turn.content) ||
            turn.content.startsWith(last.content));
    if (turn.content.isNotEmpty && !prefixMatch) return;
    turn.messageId = last.id;
    // checkpoint 可能比本地增量更新，取更长的那份，避免把已保存内容写短。
    if (last.content.length >= turn.content.length) {
      turn.content = last.content;
      turn.reasoning = last.reasoning;
      turn.reasoningMs = last.reasoningMs;
      turn.sources = last.sources;
    }
  }

  /// 尾条是否就是本轮回答：空占位、已经带上本轮 message id，或内容完全一致。
  bool _belongsToTurn(ChatMessage msg, _RunningTurn turn) {
    if (msg.role != MessageRole.assistant) return false;
    if (turn.messageId != null && msg.id == turn.messageId) return true;
    if (msg.id == null) return true;
    if (msg.content.isNotEmpty && turn.content.isNotEmpty) {
      if (msg.content.startsWith(turn.content) ||
          turn.content.startsWith(msg.content)) {
        return true;
      }
    }
    return msg.content == turn.content;
  }

  // -------------------------------------------------------------- 收尾

  /// 收尾：把最终回答落库、清理运行态与未完成任务记录。
  ///
  /// [persist] 为 false 时只收尾界面，不写消息存储：服务端可能已经存过同一条
  /// 回答，由调用方再按会话历史补齐，避免重复。
  Future<void> _finishTurn(
    _RunningTurn turn, {
    bool removeEmpty = true,
    bool persist = true,
  }) async {
    if (turn.finished) return;
    turn.finished = true;
    turn.flushTimer?.cancel();
    turn.flushTimer = null;
    // 只移除自己；如果同会话已有更新的一轮，不能把新运行态删掉。
    if (identical(_turns[turn.conversationId], turn)) {
      _turns.remove(turn.conversationId);
    }
    session.bumpViewToken(turn.conversationId);

    final isCurrent =
        turn.conversationId == session.currentConversationId &&
        session.viewMatches(turn.conversationId);
    if (isCurrent) {
      // 收尾前把运行态里的最后一段内容落进消息，避免丢失
      _attachTurnToView(turn);
      // 思考结束后默认收起思考块
      final messages = session.messages;
      if (messages.isNotEmpty) {
        final index = messages.length - 1;
        final last = messages[index];
        if (last.role == MessageRole.assistant &&
            last.reasoning.isNotEmpty &&
            last.thinkingExpanded) {
          session.replaceMessage(index, last.copyWith(thinkingExpanded: false));
        }
      }
      if (removeEmpty && session.messages.isNotEmpty) {
        final last = session.messages.last;
        // 只有正文和思考都为空才丢弃：思考到一半被中断时，思考内容也要留住
        if (_belongsToTurn(last, turn) &&
            last.content.isEmpty &&
            last.reasoning.isEmpty) {
          session.messages.removeLast();
        }
      }
      if (persist && session.messages.isNotEmpty) {
        final index = session.messages.length - 1;
        final last = session.messages[index];
        if (_belongsToTurn(last, turn) &&
            (last.content.isNotEmpty || last.reasoning.isNotEmpty)) {
          final saved = await _persistAssistant(turn.conversationId, last);
          final stillSame =
              session.currentConversationId == turn.conversationId &&
              session.viewMatches(turn.conversationId) &&
              session.messages.length > index &&
              session.messages[index].role == last.role &&
              session.messages[index].id == last.id &&
              session.messages[index].content == last.content &&
              session.messages[index].reasoning == last.reasoning;
          if (saved != null && stillSame) {
            session.replaceMessage(index, saved);
          }
        }
      }
    } else if (persist &&
        (turn.content.isNotEmpty || turn.reasoning.isNotEmpty)) {
      // 后台会话：界面没挂这条回答，直接按运行态落库
      await _persistAssistant(
        turn.conversationId,
        _turnMessage(turn),
        quiet: true,
      );
    }
    await _clearPendingJob(turn.conversationId);
    if (_turns.isEmpty) unawaited(ForegroundTaskManager.stop());
    await session.refreshConversations();
    _notify();
    // 自动朗读：开关打开时，这一轮回答生成完就念出来
    unawaited(_autoSpeakTurn(turn));
  }

  /// 自动朗读开关打开时，朗读刚生成的这一轮回答。
  ///
  /// 只朗读「正在看的会话」的最终正文：后台会话突然出声会打扰用户；
  /// 被用户停止 / 出错的一轮也不朗读。
  Future<void> _autoSpeakTurn(_RunningTurn turn) async {
    final service = tts.speech;
    if (!settings.autoSpeak || service == null) return;
    if (turn.stopped || turn.reasoning.isEmpty && turn.content.isEmpty) return;
    if (turn.content.trim().isEmpty) return;
    if (turn.conversationId != session.currentConversationId) return;
    final convId = turn.conversationId;
    // 等一下落库/刷新，保证界面上已经是最终文本
    final msg = ChatMessage(
      role: MessageRole.assistant,
      content: turn.content,
      audioFiles: turn.audioFiles,
    );
    try {
      await service.speak(
        key: 'auto:$convId:${turn.content.length}',
        text: msg.content,
        voice: settings.ttsVoice,
      );
    } on SpeechException catch (e) {
      _notice(e.message, isError: true);
    } catch (_) {
      // 自动朗读失败不该打断对话
    }
  }

  /// 运行态 → 消息对象（后台会话落库用）。
  ChatMessage _turnMessage(_RunningTurn turn) => ChatMessage(
    id: turn.messageId,
    role: MessageRole.assistant,
    content: turn.content,
    reasoning: turn.reasoning,
    reasoningMs: turn.reasoningMs,
    sources: turn.sources,
    audioFiles: turn.audioFiles,
    timestamp: DateTime.now(),
  );

  /// 收尾时落库回答。
  ///
  /// 中转模式下服务端在任务结束时已经存好了（消息带 id），这里只补本地缓存；
  /// 直连模式下由客户端上传到会话存储。
  Future<ChatMessage?> _persistAssistant(
    int convId,
    ChatMessage msg, {
    bool quiet = false,
  }) async {
    try {
      if (msg.id != null) {
        await session.store.cacheMessage(convId, msg);
        return msg;
      }
      return await session.store.appendMessage(convId, msg);
    } on ChatRepositoryException catch (e) {
      // 后台会话落库失败时界面多半不在该会话，弹提示反而让人摸不着头脑
      if (!quiet) _notice('回答未能保存到服务器：${e.message}', isError: true);
      return null;
    } catch (e) {
      // 超时、证书、SQLite 等非仓储异常同样不能中断收尾流程。
      if (!quiet) _notice('回答未能保存：$e', isError: true);
      return null;
    }
  }

  /// 服务端任务丢失后的兜底。
  ///
  /// 这种时候服务端往往已经把最终回答写进会话存储，所以优先按服务端最新一页
  /// 刷新；如果确实没存下，再把本机已经收到的思考/正文补写回去，不能让整轮
  /// 回答凭空消失（这正是“退后台后思考内容和输出都没了”的另一条路径）。
  Future<void> _handleJobLost(_RunningTurn turn) async {
    if (turn.finished) return;
    final convId = turn.conversationId;
    final hasPartial = turn.content.isNotEmpty || turn.reasoning.isNotEmpty;
    final partial = _turnMessage(turn);
    final isCurrent = session.viewMatches(convId);
    // 先收尾，但先不落库：服务端可能已经把同一条回答存下了
    await _finishTurn(turn, removeEmpty: !hasPartial, persist: false);
    if (isCurrent) {
      try {
        final loaded = await session.store.loadLatestMessages(convId);
        if (session.viewMatches(convId)) {
          final serverHasAnswer = loaded.any(
            (m) =>
                m.role == MessageRole.assistant &&
                (m.content.isNotEmpty || m.reasoning.isNotEmpty),
          );
          // 服务端已有回答时丢掉本地未落库的临时占位，避免出现两条
          final kept = serverHasAnswer
              ? [
                  for (final msg in session.messages)
                    if (msg.id != null) msg,
                ]
              : session.messages;
          session.messages = session.mergeMessagesById(
            kept,
            session.trimTrailingPlaceholder(loaded),
          );
          if (!serverHasAnswer && hasPartial) {
            final saved = await _persistAssistant(convId, partial, quiet: true);
            if (saved != null &&
                session.currentConversationId == convId &&
                !session.messages.any((m) => m.id == saved.id)) {
              session.messages.add(saved);
            }
          }
          _notify();
        }
      } catch (_) {
        // 服务端历史拉不到：至少保留本机已经显示的部分
      }
    } else if (hasPartial) {
      await _persistAssistant(convId, partial, quiet: true);
    }
    _notice('该会话的生成任务已在服务器结束，已按服务端记录刷新');
  }

  // ------------------------------------------------------------ 标题生成

  /// 取最近 3 条用户提问作为标题生成的上下文（去掉 system 段与文件正文）。
  String _titleContext() {
    final texts = <String>[];
    for (final msg in session.messages.reversed) {
      if (msg.role != MessageRole.user) continue;
      // 新消息正文已干净；旧消息（legacy）里尾部还带着附件文本标记，
      // 截掉标记段取正文即可（只用于标题生成，不参与渲染）。
      final text = displayTextOf(msg.content).split('【文件：').first.trim();
      if (text.isNotEmpty) texts.add(text);
      if (texts.length >= 3) break;
    }
    return texts.reversed.join('\n---\n');
  }

  /// 让模型生成会话标题（JSON 输出），失败就保持“新对话”。
  Future<void> _generateTitle(String userText, int convId) async {
    final key = settings.apiKey;
    if (key == null || key.isEmpty) return;
    final client = network.createClient();
    client.systemPrompt =
        'You are a title generator. Reply only with json like '
        '{"title": "短标题"}';
    var buffer = '';
    await client.send(
      input: [
        {
          'role': 'user',
          'content':
              '请用不超过 20 个字概括这段提问，按 json 输出，例如 '
              '{"title": "天气查询"}：\n\n$userText',
        },
      ],
      model: settings.effectiveModel,
      protocol: settings.protocol,
      thinkingEnabled: false,
      reasoningEffort: 'low',
      apiKey: key,
      webSearch: false,
      onReasoningDelta: (_) {},
      onContentDelta: (delta) => buffer += delta,
      onReasoningTimed: (_) {},
      onDone: () {},
      onError: (_) {},
    );
    final title = parseTitleFromJson(buffer);
    if (title == null || session.currentConversationId != convId) return;
    session.conversationTitle = title;
    _notify();
    try {
      await session.store.renameConversation(convId, title);
      await session.refreshConversations();
    } on ChatRepositoryException {
      // 标题没存上不影响使用，下次再生成
    }
  }

  // ------------------------------------------------------------ 附件处理

  /// 附件 → 图片 dataURL 列表 + 结构化文件列表。
  ///
  /// 图片走 input_image；文本文件的内容放进 [ChatFile.text]（发给模型时由
  /// buildResponsesInput 展开成文本块），存库与显示不再往正文拼标记；
  /// PDF / Office 先上传 Files API 拿 file_id，不支持的格式只留结构化记录。
  ({List<String> images, List<ChatFile> files}) attachmentParts(
    List<Attachment> attachments,
  ) {
    final images = <String>[];
    final files = <ChatFile>[];
    for (final att in attachments) {
      if (att.isImage) {
        images.add(att.dataUrl);
      } else if (att.isText) {
        files.add(
          ChatFile(
            id: 'text:${att.fileName}',
            name: att.fileName,
            sizeBytes: att.sizeBytes,
            text: att.textContent ?? '',
          ),
        );
      } else if (att.fileId != null) {
        // 已经上传过（编辑历史消息时带回的）
        files.add(
          ChatFile(
            id: att.fileId!,
            name: att.fileName,
            sizeBytes: att.sizeBytes,
          ),
        );
      } else {
        // 上游不支持的格式：只做结构化记录（卡片可见），不再发无效请求。
        files.add(
          ChatFile(id: 'unsupported:${att.fileName}', name: att.fileName),
        );
      }
    }
    return (images: images, files: files);
  }

  /// 上传所有待发送的文档附件（PDF / Office / 图片型文档）。
  ///
  /// 返回上传后的附件列表：文档带上 `fileId`，其余原样保留。
  /// 上传失败的文档会从列表里去掉并提示一次。
  Future<List<Attachment>> uploadDocuments(
    List<Attachment> attachments,
  ) async {
    if (!attachments.any((a) => a.isDocument && a.fileId == null)) {
      return attachments;
    }
    final key = settings.apiKey;
    if (key == null || key.isEmpty) {
      _notice('上传文档需要先配置 DeepSeek API Key', isError: true);
      return attachments;
    }
    final result = <Attachment>[];
    var failed = 0;
    for (final att in attachments) {
      if (!att.isDocument || att.fileId != null) {
        result.add(att);
        continue;
      }
      try {
        final uploaded = await network
            .newClient()
            .uploadFile(File(att.path), apiKey: key);
        result.add(att.copyWith(fileId: uploaded.id));
      } catch (e) {
        failed++;
      }
    }
    if (failed > 0) {
      _notice('有 $failed 个文件上传失败，已跳过', isError: true);
    }
    return result;
  }

  /// 上传一个文档到 Files API，返回可引用的 [ChatFile]。
  Future<ChatFile?> uploadDocument(Attachment attachment) async {
    final key = settings.apiKey;
    if (key == null || key.isEmpty) {
      _notice('请先配置 DeepSeek API Key', isError: true);
      return null;
    }
    try {
      final client = network.newClient();
      final uploaded = await client.uploadFile(
        File(attachment.path),
        apiKey: key,
      );
      return ChatFile(
        id: uploaded.id,
        name: uploaded.name,
        sizeBytes: uploaded.sizeBytes,
      );
    } catch (e) {
      _notice(session.failureText('上传文件', e), isError: true);
      return null;
    }
  }

  /// 请求 input 里是否带了已上传的文档（决定要不要声明 ocr 工具）。
  bool inputHasFiles(List<Map<String, dynamic>> input) {
    for (final item in input) {
      final content = item['content'];
      if (content is! List) continue;
      for (final part in content) {
        if (part is Map && part['type'] == 'input_file') return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------ 后台恢复

  /// 记录服务器任务：App 被杀/重开后据此把回答补齐。
  ///
  /// 按会话分别记录（可同时存在多条），旧的单条 JSON 格式仍可解析。
  Future<void> _rememberPendingJob(_RunningTurn turn, String jobId) async {
    turn.jobId = jobId;
    final jobs = await _readPendingJobs();
    jobs
      ..removeWhere(
        (job) =>
            job.conversationId == turn.conversationId || job.jobId == jobId,
      )
      ..add(_PendingJob(jobId, turn.conversationId));
    await _writePendingJobs(jobs);
  }

  /// 任务结束后清掉该会话的记录。
  Future<void> _clearPendingJob(int conversationId) async {
    final jobs = await _readPendingJobs();
    final kept = [
      for (final job in jobs)
        if (job.conversationId != conversationId) job,
    ];
    if (kept.length != jobs.length) await _writePendingJobs(kept);
  }

  Future<List<_PendingJob>> _readPendingJobs() async {
    final raw = await settings.store.pendingJob;
    if (raw == null || raw.isEmpty) return [];
    final jobs = <_PendingJob>[];
    try {
      final decoded = jsonDecode(raw);
      final items = decoded is List ? decoded : [decoded];
      for (final item in items) {
        if (item is! Map) continue;
        final jobId = item['job_id'];
        final convId = item['conv_id'];
        if (jobId is String && jobId.isNotEmpty && convId is int) {
          jobs.add(_PendingJob(jobId, convId));
        }
      }
    } catch (_) {
      // 数据损坏时当作没有未完成任务
    }
    return jobs;
  }

  Future<void> _writePendingJobs(List<_PendingJob> jobs) async {
    if (jobs.isEmpty) {
      await settings.store.setPendingJob(null);
      return;
    }
    await settings.store.setPendingJob(
      jsonEncode([
        for (final job in jobs)
          {'job_id': job.jobId, 'conv_id': job.conversationId},
      ]),
    );
  }

  /// App 启动时：把上次没跑完的服务器任务都续上（可同时续多个会话）。
  Future<void> resumePendingJobs() async {
    final jobs = await _readPendingJobs();
    if (jobs.isEmpty) return;
    final probe = network.createClient();
    if (!probe.useRelay) {
      await _writePendingJobs(const []);
      return;
    }
    for (final job in jobs) {
      // 最近一条摆到前台显示，其余在后台补齐
      final isLatest = job == jobs.last;
      if (isLatest && job.conversationId != session.currentConversationId) {
        enterConversationView();
        await session.loadConversationById(job.conversationId);
        _notify();
      }
      // 会话已被删除（消息为空）时放弃恢复，避免凭空造出一条空回答
      if (job.conversationId == session.currentConversationId &&
          session.messages.isEmpty) {
        await _clearPendingJob(job.conversationId);
        continue;
      }
      if (_turns.containsKey(job.conversationId)) continue;
      final turn = _RunningTurn(
        conversationId: job.conversationId,
        client: network.createClient(),
      )..jobId = job.jobId;
      _turns[job.conversationId] = turn;
      if (job.conversationId == session.currentConversationId) {
        _attachTurnToView(turn);
      }
      _notify();
      unawaited(_resumeTurn(turn, job.jobId));
    }
  }

  /// 接上服务端正在生成的任务（App 重开 / 重新进入会话时使用）。
  Future<void> _resumeTurn(_RunningTurn turn, String jobId) async {
    await turn.client.resumeJob(
      jobId: jobId,
      onSnapshot: (snapshot) => _applyTurnSnapshot(turn, snapshot),
      onDone: () => unawaited(_finishTurn(turn)),
      onJobLost: () => unawaited(_handleJobLost(turn)),
      onError: (e) => unawaited(_handleTurnError(turn, e)),
    );
  }

  /// 会话里若还有正在生成的回答，把它接回界面。
  ///
  /// 本地有运行态（切走又切回）直接用；本地没有则问服务端有没有活跃任务
  /// （App 被杀过、或任务在别的设备上发起）。
  Future<void> attachRunningTurn(int convId) async {
    final local = _turns[convId];
    if (local != null) {
      _attachTurnToView(local);
      return;
    }
    final repo = session.store;
    if (repo is! ServerChatRepository) return;
    final client = network.createClient();
    if (!client.useRelay) return;
    final jobId = await repo.activeJobId(convId);
    if (jobId == null ||
        session.currentConversationId != convId ||
        _turns.containsKey(convId)) {
      return;
    }
    final turn = _RunningTurn(conversationId: convId, client: client)
      ..jobId = jobId;
    _turns[convId] = turn;
    _attachTurnToView(turn);
    _notify();
    await _resumeTurn(turn, jobId);
  }

  /// 释放运行态（组合根 dispose 时取消刷新定时器）。
  void dispose() {
    for (final turn in _turns.values) {
      turn.flushTimer?.cancel();
    }
  }
}

/// 一次进行中的生成（每个会话一份）。
///
/// 内容先累积在这里，再按 80ms 合并刷新到界面：会话切走时只是不再渲染，
/// 流本身继续接收增量，切回来接着显示；多个会话因此可以同时提问。
class _RunningTurn {
  _RunningTurn({required this.conversationId, required this.client});

  final int conversationId;

  /// 本次请求独立的客户端：多会话并行时各自的流与任务号互不覆盖
  final DeepSeekClient client;

  /// 思维链 / 正文 / 搜索来源 / 思考用时
  String reasoning = '';
  String content = '';
  List<ChatSource> sources = const [];
  int reasoningMs = 0;

  /// 模型用 `text_to_speech` 生成的音频文件（本轮）
  List<String> audioFiles = const [];

  /// 服务端落库后的助手消息 id
  int? messageId;

  /// 服务端任务号（中转模式下断线可续）
  String? jobId;

  /// 本轮思考块是否已自动收起（正文一开始输出只收一次）
  bool autoCollapsed = false;

  /// 是否有还没写进界面的新内容
  bool dirty = false;

  /// 合并刷新定时器
  Timer? flushTimer;

  /// 是否已收尾（onDone 与“停止”不会重复执行）
  bool finished = false;

  /// 用户是否已经停止这一轮（发请求前整理图片时也可能被停止）
  bool stopped = false;
}

/// 服务器上未跑完的任务（App 被杀/重开后用于续接）。
class _PendingJob {
  const _PendingJob(this.jobId, this.conversationId);

  final String jobId;
  final int conversationId;
}
