import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../speech.dart';
import '../theme.dart';
import 'widgets/glass.dart';
import 'widgets/history_drawer.dart';
import 'widgets/input_composer.dart';
import 'widgets/key_dialog.dart';
import 'widgets/messages_view.dart';
import 'widgets/mode_selector.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/speaker_icon.dart';
import 'widgets/system_prompt_dialog.dart';
import 'widgets/whale_logo.dart';

/// 根界面：主页（空态/聊天态）+ 左侧历史抽屉。
/// 历史抽屉默认半屏展开，点击搜索框时全屏搜索；右滑开、左滑关。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _drawer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  bool _searchActive = false;

  /// 抽屉每次打开/关闭都换一个 key，让 HistoryDrawer 重建 →
  /// 关闭抽屉时多选状态立即清空（不会残留到下次打开）
  int _drawerEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 抽屉动画结束（完全打开/关闭）时刷新 PopScope 的 canPop 判定
    _drawer.addStatusListener((status) {
      if (status == AnimationStatus.dismissed ||
          status == AnimationStatus.completed) {
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 退后台期间网络可能被系统挂起、连接可能被切断：回到前台重新对齐一次
    // 服务端历史，把后台期间已经生成完的回答补回界面。
    final appState = context.read<AppState>();
    unawaited(appState.refreshCurrentConversation());
  }

  void _openDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    _drawer.forward();
  }

  void _closeDrawer() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() {
      _searchActive = false;
      _drawerEpoch++;
    });
    _drawer.reverse();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _drawer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final width = MediaQuery.of(context).size.width;
    // 历史页占比：依据官方参考图实测，抽屉右缘约在屏宽 77% 处，
    // 右侧露出约 23% 主页（与官方 DeepSeek 一致）。
    final drawerWidth = _searchActive ? width : width * 0.77;
    final drawerCorner = _searchActive ? 0.0 : 20.0;

    return PopScope(
      // 仅当抽屉完全关闭且未处于搜索态时，才让系统返回键退出 App
      canPop: _drawer.isDismissed && !_searchActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_searchActive) {
          // 全屏搜索态返回 → 回到半屏抽屉
          setState(() => _searchActive = false);
        } else if (_drawer.value > 0) {
          // 半屏抽屉返回 → 关闭抽屉回到主页
          _closeDrawer();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // 氛围光斑（顶栏与输入卡的玻璃需要背后有颜色可糊）
            const Positioned.fill(child: AmbientBackground()),
            // 主页内容：右滑（或点菜单）打开历史
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) {
                if (d.primaryDelta != null && d.primaryDelta! > 0) {
                  _drawer.value = (_drawer.value + d.primaryDelta! / width)
                      .clamp(0, 1);
                }
              },
              onHorizontalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) > 300 || _drawer.value > 0.4) {
                  _openDrawer();
                } else {
                  _closeDrawer();
                }
              },
              child: HomeBody(
                onOpenHistory: _openDrawer,
                onNewChat: _newChat,
                onOpenSystemPrompt: () => _showSystemPromptDialog(context),
              ),
            ),
            // 历史抽屉（半屏或全屏搜索）：磨砂玻璃面板
            AnimatedBuilder(
              animation: _drawer,
              builder: (context, child) {
                return Positioned(
                  left: -drawerWidth * (1 - _drawer.value),
                  top: 0,
                  bottom: 0,
                  width: drawerWidth,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      if (d.primaryDelta != null && d.primaryDelta! < 0) {
                        _drawer.value =
                            (_drawer.value + d.primaryDelta! / width).clamp(
                              0,
                              1,
                            );
                      }
                    },
                    onHorizontalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -300 ||
                          _drawer.value < 0.4) {
                        _closeDrawer();
                      } else {
                        _openDrawer();
                      }
                    },
                    child: Container(
                      foregroundDecoration: BoxDecoration(
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(drawerCorner),
                          bottomRight: Radius.circular(drawerCorner),
                        ),
                        border: Border(
                          right: BorderSide(
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(drawerCorner),
                          bottomRight: Radius.circular(drawerCorner),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: 0.12 * _drawer.value,
                            ),
                            blurRadius: 70,
                            spreadRadius: -20,
                            offset: const Offset(30, 0),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(drawerCorner),
                          bottomRight: Radius.circular(drawerCorner),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              color: AppColors.glassStrong,
                            ),
                            child: HistoryDrawer(
                              key: ValueKey<int>(_drawerEpoch),
                              conversations: state.conversations,
                              currentId: state.currentConversationId,
                              apiKey: state.apiKey,
                              quickModelOverride: state.quickModelOverride,
                              expertModelOverride: state.expertModelOverride,
                              searchActive: _searchActive,
                              searchHits: state.searchHits,
                              onSearchActive: (active) =>
                                  setState(() => _searchActive = active),
                              onSearch: (q) => state.searchMessages(q),
                              onSelect: (conv) async {
                                _closeDrawer();
                                await state.loadConversation(conv);
                              },
                              onOpenHit: (hit) async {
                                final conv = state.conversations.firstWhere(
                                  (c) => c.id == hit.conversationId,
                                  orElse: () => Conversation(
                                    id: hit.conversationId,
                                    title: hit.conversationTitle,
                                    model: state.effectiveModel,
                                    updatedAt: hit.timestamp,
                                  ),
                                );
                                _closeDrawer();
                                await state.loadConversation(conv);
                              },
                              onDelete: (conv) =>
                                  state.deleteConversation(conv),
                              hasMore: state.hasMoreConversations,
                              onLoadMore: () =>
                                  state.loadMoreConversations(),
                              onLoadAllIds: () =>
                                  state.allConversationIds(),
                              onDeleteIds: (ids) =>
                                  state.deleteConversations(ids),
                              onOpenKeyConfig: () => _showKeyDialog(context),
                              onOpenVoiceSettings: () =>
                                  _showSettingsDialog(context),
                              onBack: () {
                                if (_searchActive) {
                                  setState(() => _searchActive = false);
                                } else {
                                  _closeDrawer();
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            // 点抽屉右侧主页区域关闭（不遮挡抽屉本身）
            if (_drawer.value > 0)
              Positioned(
                left: drawerWidth * _drawer.value,
                top: 0,
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeDrawer,
                  // 抽屉打开时压暗主页（官方同款），点击该区域关闭抽屉
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.08 * _drawer.value),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showKeyDialog(BuildContext context) {
    final state = context.read<AppState>();
    showDialog<void>(
      context: context,
      builder: (_) => KeyDialog(
        initialKey: state.apiKey,
        initialQuickModel: state.quickModelOverride,
        initialExpertModel: state.expertModelOverride,
        initialProtocol: state.protocol,
        initialServerBaseUrl: state.serverBaseUrl,
        initialServerToken: state.serverToken,
        initialServerCertSha256: state.serverCertSha256,
        initialUseServer: state.useServer,
        onSave:
            (
              key,
              quick,
              expert,
              protocol,
              serverBaseUrl,
              serverToken,
              serverCertSha256,
              useServer,
            ) async {
          await state.setApiKeyAndModels(key, quick, expert);
          await state.setProtocol(protocol);
          await state.setServerSettings(
            baseUrl: serverBaseUrl,
            token: serverToken,
            certSha256: serverCertSha256,
            enabled: useServer,
          );
        },
      ),
    );
  }

  Future<void> _newChat() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await context.read<AppState>().newChat();
  }

  /// 设置页：语音缓存清理。
  Future<void> _showSettingsDialog(BuildContext context) async {
    final state = context.read<AppState>();
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(speech: state.speech),
    );
  }

  void _showSystemPromptDialog(BuildContext context) {
    final state = context.read<AppState>();
    showDialog<void>(
      context: context,
      builder: (_) => SystemPromptDialog(
        initialPrompt: state.systemPrompt,
        initialAnswerBubble: state.answerBubble,
        // 两个语音开关都是会话级：跟当前会话走
        initialTtsTool: state.ttsToolEnabled,
        initialBracketSpeak:
            state.bracketMode == BracketSpeechMode.speak,
        conversationTitle: state.currentConversationId == null
            ? null
            : state.conversationTitle,
        onSave: (prompt, answerBubble, ttsTool, bracketSpeak) async {
          await state.setSystemPrompt(prompt);
          await state.setAnswerBubble(answerBubble);
          // 开关只在面板保存时生效，避免误触立即改变行为
          if (state.ttsToolEnabled != ttsTool) {
            await state.setTtsToolEnabled(ttsTool);
          }
          final wantMode = bracketSpeak
              ? BracketSpeechMode.speak
              : BracketSpeechMode.skip;
          if (state.bracketMode != wantMode) {
            await state.setBracketMode(wantMode);
          }
        },
      ),
    );
  }
}

/// 主页主体：空态（Logo+模式选择）或 聊天态（消息列表+输入区）。
class HomeBody extends StatelessWidget {
  const HomeBody({
    super.key,
    required this.onOpenHistory,
    required this.onNewChat,
    required this.onOpenSystemPrompt,
  });

  final VoidCallback onOpenHistory;
  final VoidCallback onNewChat;
  final VoidCallback onOpenSystemPrompt;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isChat = state.hasMessages;
    // 当前编辑的目标消息（用于把内容带入输入区并显示“修改输入”）
    final editingIndex = state.editingIndex;
    final editingMsg =
        (editingIndex != null &&
            editingIndex >= 0 &&
            editingIndex < state.messages.length)
        ? state.messages[editingIndex]
        : null;
    // 编辑态：输入框只放用户自己的文字，文件/图片以附件形式回到输入区。
    // 新消息附件在结构化 files 字段里；旧消息正文带标记，走 legacy 解析。
    final editingParts = editingMsg == null
        ? null
        : userMessageParts(editingMsg);

    return Column(
      children: [
        _TopBar(
          onOpenHistory: onOpenHistory,
          onNewChat: onNewChat,
          onOpenSystemPrompt: onOpenSystemPrompt,
          // 喇叭是「自动朗读」开关：开启后新回答自动朗读，关闭则不朗读
          autoSpeak: state.autoSpeak,
          onToggleAutoSpeak: () => state.setAutoSpeak(!state.autoSpeak),
          speaking: _isSpeaking(state),
          title: isChat ? state.conversationTitle : null,
          mode: state.mode,
        ),
        Expanded(
          child: isChat
              ? MessagesView(
                  conversationId: state.currentConversationId,
                  scrollToken: state.scrollToken,
                  messages: state.messages,
                  busy: state.busy,
                  // 会话级开关：开启后所有回答包进气泡
                  answerBubble: state.answerBubble,
                  onToggleThinking: (i) => _toggleThinking(state, i),
                  onRegenerateAt: (i) => state.regenerateAt(i),
                  onEditStart: (i) => state.startEdit(i),
                  onStop: () => state.stopGeneration(),
                  onNotice: state.showNotice,
                  onSpeak: (i, msg) => state.speakMessage(
                    msg,
                    key: _speakKey(state, i, msg),
                  ),
                  // 操作行长按喇叭：按回答**正文**合成朗读音频
                  // （preferCardAudio=false，即使有音频卡片也不用它的录音）
                  onDownloadAudio: (i, msg) => state.downloadMessageAudio(
                    msg,
                    fileName: 'answer-${msg.id ?? i}.wav',
                    preferCardAudio: false,
                  ),
                  // 音频卡片下载：取模型 text_to_speech 生成的那条录音
                  onDownloadCardAudio: (i, msg) => state.downloadMessageAudio(
                    msg,
                    fileName: 'audio-${msg.id ?? i}.wav',
                    preferCardAudio: true,
                  ),
                  // 音频卡片：模型生成的音频文件，点左侧图标播放/停止
                  onPlayAudio: (i, msg) =>
                      state.playMessageAudio(msg, key: _speakKey(state, i, msg)),
                  audioVoice: (i, msg) => state.ttsVoice,
                  speakingKey: state.speech?.playingKey,
                  hasOlder: state.hasOlderMessages,
                  loadingOlder: state.loadingOlder,
                  onLoadOlder: () => state.loadOlderMessages(),
                  onAtBottomChanged: state.setFollowing,
                )
              : EmptyHome(
                  mode: state.mode,
                  onModeChanged: (m) => state.setMode(m),
                  onSuggestion: (text) => state.send(text),
                ),
        ),
        InputComposer(
          onSend: (text, atts) => state.send(text, attachments: atts),
          editing: editingMsg != null,
          editingText: editingParts?.text ?? '',
          editingImages: editingMsg?.imageDataUrls ?? const [],
          editingFiles: _editingFiles(editingParts, editingMsg),
          onCancelEdit: () => state.cancelEdit(),
          onCommitEdit: (text, attachments) => state.editUserMessage(
            state.editingIndex ?? 0,
            text,
            attachments: attachments,
          ),
          deepThink: state.deepThink,
          webSearch: state.webSearch,
          reasoningEffort: state.reasoningEffort,
          onDeepThinkChanged: (v) => state.setDeepThink(v),
          onWebSearchChanged: (v) => state.setWebSearch(v),
          onEffortChanged: (v) => state.setReasoningEffort(v),
          onNotice: state.showNotice,
          onStartVoice: state.startVoiceInput,
          onStopVoice: state.stopVoiceInput,
          onCancelVoice: state.cancelVoiceInput,
        ),
      ],
    );
  }

  /// 编辑回填的附件列表：
  /// - 文本文件：内容带回输入区附件（legacy 与新消息统一走这条）；
  /// - 已上传文档：把 file_id 带回，重发时不再重复上传（仅新消息有）；
  /// - 不支持的格式（unsupported: 前缀）无法重发，不回填（与旧行为一致）。
  List<Attachment> _editingFiles(
    ({String text, List<UserFileCard> files})? parts,
    ChatMessage? msg,
  ) {
    final result = <Attachment>[];
    for (final file in parts?.files ?? const <UserFileCard>[]) {
      if (file.content.isNotEmpty) {
        result.add(
          Attachment(
            path: file.name,
            dataUrl: 'data:text/plain;base64,',
            textContent: file.content,
            sizeBytes: file.sizeBytes,
          ),
        );
        continue;
      }
      final structured = msg?.files.firstWhere(
        (f) => f.name == file.name && !f.isTextFile && !f.isUnsupported,
        orElse: () => const ChatFile(id: '', name: ''),
      );
      if (structured != null && structured.id.isNotEmpty) {
        result.add(
          Attachment(
            path: file.name,
            dataUrl: '',
            textContent: null,
            sizeBytes: file.sizeBytes,
            fileId: structured.id,
          ),
        );
      }
    }
    return result;
  }

  void _toggleThinking(AppState state, int index) {
    final msgs = List.of(state.messages);
    final m = msgs[index];
    msgs[index] = m.copyWith(thinkingExpanded: !m.thinkingExpanded);
    state.replaceMessage(index, msgs[index]);
  }

  bool _isSpeaking(AppState state) => state.speech?.playingKey != null;
}

/// 朗读标识：收敛到 models.dart 的 speakKeyFor（单一来源），
/// 只依赖稳定标识（消息 id / 会话+下标），不含 content.length——
/// 流式期间长度每帧都变，会导致播放态判断失效。
String _speakKey(AppState state, int index, ChatMessage msg) =>
    speakKeyFor(state.currentConversationId, msg, index: index);

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onOpenHistory,
    required this.onNewChat,
    required this.onOpenSystemPrompt,
    required this.autoSpeak,
    required this.onToggleAutoSpeak,
    required this.speaking,
    required this.title,
    required this.mode,
  });

  final VoidCallback onOpenHistory;
  final VoidCallback onNewChat;
  final VoidCallback onOpenSystemPrompt;

  /// 右上角喇叭按钮当前是否处于「自动朗读」开启态。
  final bool autoSpeak;

  /// 点喇叭：切换自动朗读开关
  final VoidCallback onToggleAutoSpeak;

  /// 当前是否正在朗读
  final bool speaking;
  final String? title;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(6, top + 6, 14, 0),
      child: Row(
        children: [
          IconButton(icon: const _MenuBarIcon(), onPressed: onOpenHistory),
          Expanded(
            child: title == null
                ? const SizedBox()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            mode.icon == 'diamond'
                                ? Icons.diamond_outlined
                                : Icons.bolt,
                            size: 12,
                            color: AppColors.brand,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            mode.label,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          // 喇叭 = 自动朗读开关：开启时新回答自动朗读，关闭时不朗读
          _SpeakButton(
            enabled: autoSpeak,
            speaking: speaking,
            onTap: onToggleAutoSpeak,
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            tooltip: '系统提示词',
            onTap: onOpenSystemPrompt,
            child: const Icon(
              Icons.edit_note_rounded,
              size: 19,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            tooltip: '新对话',
            onTap: onNewChat,
            // 官方截图抠出的“对话气泡 + 加号”
            child: Image.asset(
              'assets/icon_new_chat.png',
              width: 19,
              height: 19,
            ),
          ),
        ],
      ),
    );
  }
}

/// 右上角喇叭：自动朗读开关（开启态高亮）。
///
/// 开启 → 每条新回答生成完自动朗读；关闭 → 不自动朗读。
/// 正在朗读时点击会先停止当前朗读。
class _SpeakButton extends StatelessWidget {
  const _SpeakButton({
    required this.enabled,
    required this.speaking,
    required this.onTap,
  });

  /// 自动朗读是否开启
  final bool enabled;

  /// 当前是否正在朗读
  final bool speaking;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 开启态：品牌色图标 + 淡品牌底，和关闭态形成明确对比
    final color = enabled ? AppColors.brand : AppColors.textPrimary;
    return Semantics(
      button: true,
      toggled: enabled,
      label: enabled ? '自动朗读已开启' : '自动朗读已关闭',
      child: GlassIconButton(
        tooltip: enabled ? '自动朗读：开' : '自动朗读：关',
        onTap: onTap,
        tint: enabled ? AppColors.brandTint : null,
        child: speaking
            ? const Icon(
                Icons.graphic_eq_rounded,
                size: 20,
                color: AppColors.brand,
              )
            : SpeakerIcon(size: 20, color: color),
      ),
    );
  }
}

/// 空态主页：玻璃 Logo 托 + eyebrow + 渐变标题 + 模式选择 + 快捷提问。
class EmptyHome extends StatelessWidget {
  const EmptyHome({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.onSuggestion,
  });

  final AppMode mode;
  final ValueChanged<AppMode> onModeChanged;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    // 键盘弹出后可用高度会变小：改用可滚动布局，避免副标题被裁掉半行
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        children: [
          SizedBox(height: (h * 0.10).clamp(0, 96)),
          const _GlassLogo(),
          const SizedBox(height: 22),
          const Text(
            'DEEPSEEK · AI ASSISTANT',
            style: TextStyle(
              fontSize: 9.5,
              letterSpacing: 2.2,
              fontWeight: FontWeight.w600,
              color: AppColors.eyebrow,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                '你好，',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: AppColors.textPrimary,
                ),
              ),
              const GradientText(
                'DeepSeek',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          const Text(
            '今天想聊点什么？',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 30),
          ModeSelector(mode: mode, onChanged: onModeChanged),
          const SizedBox(height: 10),
          Text(
            mode.subtitle,
            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 30),
          _SuggestionChips(onTap: onSuggestion),
        ],
      ),
    );
  }
}

/// 玻璃底托里放一条鲸鱼：外圈是柔和的品牌光晕。
class _GlassLogo extends StatelessWidget {
  const _GlassLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 116,
      height: 116,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppColors.brand.withValues(alpha: 0.28),
                  AppColors.violet.withValues(alpha: 0.10),
                  AppColors.brand.withValues(alpha: 0),
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
          GlassPanel(
            radius: 36,
            blur: 18,
            tint: const Color(0xCFFFFFFF),
            borderColor: Colors.white,
            shadows: const [
              BoxShadow(color: Color(0x0F1F2687), blurRadius: 0, spreadRadius: 1),
              BoxShadow(
                color: Color(0x521F2687),
                blurRadius: 40,
                offset: Offset(0, 18),
                spreadRadius: -20,
              ),
            ],
            padding: const EdgeInsets.all(22),
            child: const WhaleLogo(size: 72, corner: 22),
          ),
        ],
      ),
    );
  }
}

/// 快捷提问：点一下直接发送这句。
class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.onTap});

  final ValueChanged<String> onTap;

  static const List<String> _texts = [
    '帮我润色一段文案',
    '解释这段代码',
    '规划一个周末',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (final text in _texts) _Chip(text: text, onTap: () => onTap(text)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F1F2687),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 13,
                  color: AppColors.brandSoft,
                ),
                const SizedBox(width: 6),
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF4B5266),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 左上角菜单：长短不同的两条横杠（仿官方）。
class _MenuBarIcon extends StatelessWidget {
  const _MenuBarIcon();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: const Size(22, 18), painter: _MenuBarPainter());
  }
}

class _MenuBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.textPrimary
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // 上长下短，错开宽度
    final y1 = size.height * 0.35;
    final y2 = size.height * 0.68;
    canvas.drawLine(
      Offset(size.width * 0.12, y1),
      Offset(size.width * 0.90, y1),
      p,
    );
    canvas.drawLine(
      Offset(size.width * 0.12, y2),
      Offset(size.width * 0.58, y2),
      p,
    );
  }

  @override
  bool shouldRepaint(_MenuBarPainter oldDelegate) => false;
}
