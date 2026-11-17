import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:ds_api/models.dart';
import 'package:ds_api/speech.dart';
import 'package:ds_api/theme.dart';
import 'package:ds_api/ui/root_shell.dart';
import 'package:ds_api/ui/widgets/glass.dart';
import 'package:ds_api/ui/widgets/history_drawer.dart';
import 'package:ds_api/ui/widgets/input_composer.dart';
import 'package:ds_api/ui/widgets/messages_view.dart';
import 'package:ds_api/ui/widgets/speaker_icon.dart';
import 'package:ds_api/ui/widgets/system_prompt_dialog.dart';

/// 本地视觉验收入口（不参与正式打包）：
///
///   flutter create --platforms=web .
///   flutter build web -t tool/preview_main.dart
///
/// 通过 ?state=empty|chat|drawer 切换三块界面。
void main() => runApp(const PreviewApp());

class PreviewApp extends StatelessWidget {
  const PreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    final state = Uri.base.queryParameters['state'] ?? 'empty';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      home: PreviewPage(state: state),
    );
  }
}

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.state});

  final String state;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07080C),
      body: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'DS-API UI · ${widget.state}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 14),
                _phone(_screen(widget.state)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _phone(Widget child) {
  return Container(
    width: 390,
    height: 844,
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(56),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A3F4F), Color(0xFF101218), Color(0xFF08090D)],
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: 50,
          offset: const Offset(0, 30),
        ),
      ],
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(48), child: child),
  );
}

Widget _screen(String state) {
  return MediaQuery(
    data: const MediaQueryData(
      size: Size(374, 828),
      padding: EdgeInsets.only(top: 40, bottom: 30),
      devicePixelRatio: 1,
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const AmbientBackground(),
        _body(state),
        Positioned(
          top: 11,
          left: 133,
          child: Container(
            width: 108,
            height: 31,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Positioned(
          top: 16,
          left: 28,
          right: 28,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '9:41',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111318),
                ),
              ),
              const Row(
                children: [
                  Icon(
                    Icons.signal_cellular_alt,
                    size: 14,
                    color: Color(0xFF111318),
                  ),
                  SizedBox(width: 4),
                  Icon(Icons.wifi, size: 14, color: Color(0xFF111318)),
                  SizedBox(width: 4),
                  Icon(Icons.battery_full, size: 16, color: Color(0xFF111318)),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          bottom: 8,
          left: 121,
          child: Container(
            width: 132,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _body(String state) {
  switch (state) {
    case 'chat':
      return Column(
        children: [
          _TopBar(title: '产品介绍优化', mode: AppMode.quick),
          Expanded(
            child: MessagesView(
              conversationId: 1,
              scrollToken: 0,
              messages: _messages,
              busy: false,
              answerBubble: true,
              onToggleThinking: (_) {},
              onRegenerateAt: (_) {},
              onEditStart: (_) {},
              onStop: () {},
              onNotice: (_) {},
              // 音频卡片：预览里直接展示模型生成的音频文件形态
              onSpeak: (_, _) {},
              onDownloadAudio: (_, _) {},
              onPlayAudio: (_, _) {},
              audioVoice: (i, _) => TtsVoice.stella,
            ),
          ),
          _composer(),
        ],
      );
    case 'drawer':
      return _drawerBody();
    case 'prompt':
      return Stack(
        children: [
          Column(
            children: [
              const _TopBar(mode: AppMode.quick),
              Expanded(
                child: EmptyHome(
                  mode: AppMode.quick,
                  onModeChanged: (_) {},
                  onSuggestion: (_) {},
                ),
              ),
              _composer(),
            ],
          ),
          const Positioned.fill(
            child: ColoredBox(color: Color(0x4D000000)),
          ),
          Center(
            child: SizedBox(
              width: 310,
              child: SystemPromptDialog(
                initialPrompt: '',
                initialAnswerBubble: true,
                onSave: (_, _, _, _) async {},
              ),
            ),
          ),
        ],
      );
    default:
      return Column(
        children: [
          const _TopBar(mode: AppMode.quick),
          Expanded(
            child: EmptyHome(
              mode: AppMode.quick,
              onModeChanged: (_) {},
              onSuggestion: (_) {},
            ),
          ),
          _composer(),
        ],
      );
  }
}

Widget _composer() {
  return InputComposer(
    onSend: (_, _) {},
    deepThink: true,
    webSearch: false,
    reasoningEffort: 'high',
    onDeepThinkChanged: (_) {},
    onWebSearchChanged: (_) {},
    onEffortChanged: (_) {},
    onNotice: (_) {},
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.mode, this.title});

  final String? title;
  final AppMode mode;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.fromLTRB(6, top + 6, 14, 0),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.menu, size: 22), onPressed: () {}),
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
          // 朗读（官方同款手绘喇叭，与生产代码共用同一个组件）
          GlassIconButton(
            onTap: () {},
            child: const SpeakerIcon(size: 20, color: AppColors.textPrimary),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            onTap: () {},
            child: const Icon(
              Icons.edit_note_rounded,
              size: 19,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          GlassIconButton(
            onTap: () {},
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

Widget _drawerBody() {
  return Stack(
    fit: StackFit.expand,
    children: [
      Column(
        children: [
          const _TopBar(mode: AppMode.quick),
          Expanded(
            child: EmptyHome(
              mode: AppMode.quick,
              onModeChanged: (_) {},
              onSuggestion: (_) {},
            ),
          ),
          _composer(),
        ],
      ),
      const Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 86,
        child: ColoredBox(color: Color(0x33000000)),
      ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 288,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(26),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 60,
                spreadRadius: -18,
                offset: const Offset(28, 0),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(26),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
              child: ColoredBox(
                color: AppColors.glassStrong,
                child: HistoryDrawer(
                  conversations: _conversations,
                  currentId: 1,
                  apiKey: 'sk-8******f',
                  quickModelOverride: null,
                  expertModelOverride: null,
                  searchActive: false,
                  searchHits: const [],
                  onSearchActive: (_) {},
                  onSearch: (_) {},
                  onSelect: (_) {},
                  onOpenHit: (_) {},
                  onDelete: (_) {},
                  onOpenKeyConfig: () {},
                  onOpenVoiceSettings: () {},
                  onBack: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

const List<ChatMessage> _messages = [
  ChatMessage(
    role: MessageRole.user,
    content: '帮我把这段产品介绍写得更打动人一些。',
  ),
  ChatMessage(
    role: MessageRole.assistant,
    reasoning: '先看原文的结构，找出信息层级和语气问题。',
    reasoningMs: 8000,
    content:
        '当然可以。原文信息很完整，但偏重功能罗列。下面这版把重心放回「用户能感受到的变化」：\n\n'
        '## 三个调整\n\n'
        '- 开头先给结论，让读者 3 秒知道它解决什么问题\n'
        '- 用「少做一步」代替「自动化」，把功能翻译成体感\n'
        '- 用 `MarkdownStyleSheet` 统一配置字号与间距\n\n'
        '> 如果你愿意，把目标读者告诉我，我再按人群调一版语气。\n\n'
        '```dart\n'
        'p: TextStyle(fontSize: 15.5, height: 1.6),\n'
        '```\n\n'
        '| 元素 | 现在 | 设计 |\n'
        '| --- | --- | --- |\n'
        '| 正文 | 16.5 | 15.5 |\n',
    // 模型生成过一段音频：界面会以卡片展示，点图标即播放
    audioFiles: ['/tmp/speech-1763000000000-ab12cd34.wav'],
  ),
  ChatMessage(role: MessageRole.user, content: '语气再轻松一点，像在跟朋友聊天。'),
];

final List<Conversation> _conversations = [
  Conversation(
    id: 1,
    title: '产品介绍优化',
    model: AppMode.quick.model,
    updatedAt: DateTime.now(),
  ),
  Conversation(
    id: 2,
    title: 'Flutter 图片压缩方案',
    model: AppMode.quick.model,
    updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
  ),
  Conversation(
    id: 3,
    title: '周末去杭州怎么玩',
    model: AppMode.quick.model,
    updatedAt: DateTime.now().subtract(const Duration(hours: 5)),
  ),
  Conversation(
    id: 4,
    title: '帮我解释一下这段报错',
    model: AppMode.quick.model,
    updatedAt: DateTime.now().subtract(const Duration(days: 1)),
  ),
  Conversation(
    id: 5,
    title: 'SQL 索引优化',
    model: AppMode.quick.model,
    updatedAt: DateTime.now().subtract(const Duration(days: 1, hours: 2)),
  ),
  Conversation(
    id: 6,
    title: '读《人类简史》的笔记整理',
    model: AppMode.quick.model,
    updatedAt: DateTime.now().subtract(const Duration(days: 2)),
  ),
];
