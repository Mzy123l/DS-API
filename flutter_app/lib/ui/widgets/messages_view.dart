import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../prompt.dart';
import '../../speech.dart';
import '../../storage.dart';
import '../../theme.dart';

/// 用户消息里的文件卡片信息。
///
/// 新消息来自结构化的 [ChatFile]（`msg.files`）；旧消息（正文带
/// `【文件：名｜大小】` 标记）由 [legacySplitUserContent] 的 legacy 路径解析。
class UserFileCard {
  const UserFileCard({
    required this.name,
    required this.size,
    this.content = '',
    this.sizeBytes = 0,
  });

  final String name;
  final String size;

  /// 文件内容（重新编辑时要原样带回输入区）
  final String content;
  final int sizeBytes;
}

/// 拆分用户消息为正文与文件卡片。
///
/// 新消息附件在结构化 `files` 字段里，正文是干净的，直接取字段；
/// 没有结构化文件且正文带旧标记时走 legacy 解析。
({String text, List<UserFileCard> files}) userMessageParts(ChatMessage msg) {
  if (msg.hasFiles) {
    return (
      text: displayTextOf(msg.content).trim(),
      files: [
        for (final file in msg.files)
          UserFileCard(
            name: file.name,
            size: file.sizeBytes > 0 ? formatBytes(file.sizeBytes) : '',
            content: file.text ?? '',
            sizeBytes: file.sizeBytes,
          ),
      ],
    );
  }
  return legacySplitUserContent(msg.content);
}

/// legacy 兼容（仅历史数据）：旧版客户端把附件拼成 `【文件：…】` 文本标记
/// 写进消息正文，服务器与本地库里已有这类历史消息，必须继续能显示与回填。
///
/// 只解析不含 file_id 的旧内容标记；已上传 / 不支持格式的旧标记本来就不被
/// 该正则匹配，行为保持不变。每条消息至多调用一次（渲染处已缓存），
/// 不要在 build 里反复调用。
({String text, List<UserFileCard> files}) legacySplitUserContent(
  String content,
) {
  final text = displayTextOf(content);
  final files = <UserFileCard>[];
  final pattern = RegExp(
    r'【文件：([^】]+)】\n([\s\S]*?)(?=\n\n【文件：|\s*$)',
  );
  final stripped = text.replaceAllMapped(pattern, (match) {
    final label = match.group(1) ?? '';
    final parts = label.split('｜');
    files.add(
      UserFileCard(
        name: parts.first.trim(),
        size: parts.length > 1 ? parts[1].trim() : '',
        content: match.group(2) ?? '',
        sizeBytes: _parseSize(parts.length > 1 ? parts[1].trim() : ''),
      ),
    );
    return '';
  });
  return (text: stripped.trim(), files: files);
}

/// 把 "4.43KB" 这类显示文案还原成字节数。
int _parseSize(String label) {
  final match = RegExp(
    r'^([0-9.]+)\s*(B|KB|MB)$',
    caseSensitive: false,
  ).firstMatch(label.trim());
  if (match == null) return 0;
  final value = double.tryParse(match.group(1) ?? '') ?? 0;
  final unit = (match.group(2) ?? 'B').toUpperCase();
  final factor = switch (unit) {
    'KB' => 1024.0,
    'MB' => 1024.0 * 1024.0,
    _ => 1.0,
  };
  return (value * factor).round();
}

/// 回答分段：普通 Markdown 文本 / 代码块 / 引用块。
/// 代码块单独渲染成官方样式（语言标签 + 复制按钮 + 横向滚动）；
/// 引用块单独渲染是因为 flutter_markdown 的引用块文字颜色会被段落样式盖掉。
class MarkdownSegment {
  const MarkdownSegment({
    required this.text,
    this.language,
    this.isCode = false,
    this.isQuote = false,
    this.isMath = false,
  });

  final String text;
  final String? language;
  final bool isCode;

  /// 引用块（已去掉每行的 `>` 标记，按普通 Markdown 渲染）
  final bool isQuote;

  /// 块级 LaTeX 公式（`$$...$$`，内容不含定界符）
  final bool isMath;
}

/// 引用行：最多 3 个前导空格 + `>`，符合 Markdown 引用块语法。
final RegExp _quoteLinePattern = RegExp(r'^\s{0,3}>');

/// 按 ``` 围栏把回答拆成文本段与代码段（未闭合的尾段按代码块处理），
/// 再把文本段里的引用块拆成独立的引用段。
List<MarkdownSegment> splitMarkdownSegments(String data) {
  final segments = <MarkdownSegment>[];
  final textBuffer = StringBuffer();
  final codeBuffer = StringBuffer();
  final mathBuffer = StringBuffer();
  var inCode = false;
  var inMath = false;
  var language = '';

  void flushText() {
    final text = textBuffer.toString();
    if (text.trim().isNotEmpty) segments.add(MarkdownSegment(text: text));
    textBuffer.clear();
  }

  for (final line in data.split('\n')) {
    final trimmed = line.trimLeft();
    // 块级公式：$$ ... $$ 或 LaTeX 的 \[ ... \]（都可跨行）
    if (inMath) {
      final right = trimmed.trimRight();
      final closedBy = right.endsWith(r'$$')
          ? r'$$'
          : (right.endsWith(r'\]') ? r'\]' : null);
      if (closedBy != null) {
        mathBuffer.writeln(right.substring(0, right.length - closedBy.length));
        segments.add(MarkdownSegment(text: mathBuffer.toString().trim(), isMath: true));
        mathBuffer.clear();
        inMath = false;
      } else {
        mathBuffer.writeln(line);
      }
      continue;
    }
    final mathOpen = trimmed.startsWith(r'$$')
        ? r'$$'
        : (trimmed.startsWith(r'\[') ? r'\[' : null);
    if (mathOpen != null && !inCode) {
      flushText();
      final rest = trimmed.substring(mathOpen.length);
      final restRight = rest.trimRight();
      final sameLineClose = restRight.endsWith(r'$$')
          ? r'$$'
          : (restRight.endsWith(r'\]') ? r'\]' : null);
      if (sameLineClose != null && restRight.length > sameLineClose.length) {
        // 单行 $$...$$ / \[...\]
        segments.add(
          MarkdownSegment(
            text: restRight
                .substring(0, restRight.length - sameLineClose.length)
                .trim(),
            isMath: true,
          ),
        );
      } else {
        inMath = true;
        mathBuffer.clear();
        if (rest.trim().isNotEmpty) mathBuffer.writeln(rest);
      }
      continue;
    }
    final isFence = trimmed.startsWith('```');
    if (isFence && !inCode) {
      flushText();
      inCode = true;
      language = trimmed.substring(3).trim();
      codeBuffer.clear();
      continue;
    }
    if (isFence && inCode) {
      segments.add(
        MarkdownSegment(
          text: codeBuffer.toString(),
          language: language.isEmpty ? null : language,
          isCode: true,
        ),
      );
      inCode = false;
      continue;
    }
    if (inCode) {
      codeBuffer.writeln(line);
    } else {
      textBuffer.writeln(line);
    }
  }
  if (inCode) {
    segments.add(
      MarkdownSegment(
        text: codeBuffer.toString(),
        language: language.isEmpty ? null : language,
        isCode: true,
      ),
    );
  } else {
    if (inMath && mathBuffer.isNotEmpty) {
      segments.add(MarkdownSegment(text: mathBuffer.toString().trim(), isMath: true));
      mathBuffer.clear();
      inMath = false;
    }
    flushText();
  }
  return segments.expand(_splitQuotes).toList();
}

/// 把一段文本按引用行切成「引用段 / 普通文本段」交替的序列。
Iterable<MarkdownSegment> _splitQuotes(MarkdownSegment segment) sync* {
  // 代码块与公式段整段透传，不参与引用块拆分（否则 isMath 标记会丢，公式变成原文）
  if (segment.isCode || segment.isMath) {
    yield segment;
    return;
  }
  final lines = <String>[];
  var inQuote = false;

  Iterable<MarkdownSegment> flush() sync* {
    final text = lines.join('\n');
    if (text.trim().isNotEmpty) {
      yield MarkdownSegment(text: text, isQuote: inQuote);
    }
    lines.clear();
  }

  for (final line in segment.text.split('\n')) {
    final isQuoteLine = _quoteLinePattern.hasMatch(line);
    if (isQuoteLine != inQuote) {
      yield* flush();
      inQuote = isQuoteLine;
    }
    lines.add(isQuoteLine ? _stripQuoteMarker(line) : line);
  }
  yield* flush();
}

/// 行内公式语法：把 `$...$` 变成 `<math>` 节点，交给 [_InlineMathBuilder] 渲染。
class _InlineMathSyntax extends md.InlineSyntax {
  /// [pattern] 为捕获组即公式内容的行内公式正则：
  /// `$...$` 与 LaTeX 的 `\(...\)` 两种写法都支持。
  _InlineMathSyntax(super.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math', match.group(1)!));
    return true;
  }
}

/// 行内公式渲染器：用 flutter_math_fork 排成行内 WidgetSpan。
class _InlineMathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tex = element.textContent;
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: preferredStyle,
      onErrorFallback: (_) => Text('\$$tex\$', style: preferredStyle),
    );
  }
}

/// 去掉行首的 `>` 与其后的一个空格（嵌套引用只去掉一层）。
String _stripQuoteMarker(String line) {
  final match = RegExp(r'^\s{0,3}>\s?').firstMatch(line);
  return match == null ? line : line.substring(match.end);
}

/// 打开外部链接（回答里的 Markdown 链接、来源列表）。
Future<void> openExternalUrl(
  String? href,
  void Function(String message) onNotice,
) async {
  if (href == null || href.trim().isEmpty) return;
  final uri = Uri.tryParse(href.trim());
  if (uri == null || !uri.hasScheme) {
    onNotice('链接无效：$href');
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) onNotice('无法打开链接：$href');
  } catch (_) {
    onNotice('无法打开链接：$href');
  }
}

/// 聊天消息列表：用户气泡 / 助手思考区（可折叠）+ Markdown 回答 + 操作行。
class MessagesView extends StatefulWidget {
  const MessagesView({
    super.key,
    required this.conversationId,
    required this.scrollToken,
    required this.messages,
    required this.busy,
    required this.onToggleThinking,
    required this.onRegenerateAt,
    required this.onEditStart,
    required this.onStop,
    required this.onNotice,
    this.onSpeak,
    this.onDownloadAudio,
    this.onDownloadCardAudio,
    this.onPlayAudio,
    this.audioVoice,
    this.speakingKey,
    this.answerBubble = false,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.onLoadOlder,
    this.onAtBottomChanged,
  });

  /// 当前会话 id：变化说明切换了历史会话，需要回到最新一条
  final int? conversationId;

  /// 拉回底部的信号（发送/编辑/重新生成时自增）
  final int scrollToken;
  final List<ChatMessage> messages;
  final bool busy;
  final ValueChanged<int> onToggleThinking;
  final void Function(int index) onRegenerateAt;
  final ValueChanged<int> onEditStart;
  final VoidCallback onStop;
  final void Function(String) onNotice;

  /// 点播放按钮：朗读这条回答（语音在点击时才生成）
  final void Function(int index, ChatMessage msg)? onSpeak;

  /// 长按操作行播放按钮：按这条回答的**正文**合成音频保存到本地
  final void Function(int index, ChatMessage msg)? onDownloadAudio;

  /// 音频卡片的下载：取模型 text_to_speech 生成的那条录音
  final void Function(int index, ChatMessage msg)? onDownloadCardAudio;

  /// 音频卡片左侧图标：播放 / 停止模型生成的音频
  final void Function(int index, ChatMessage msg)? onPlayAudio;

  /// 这条回答音频用的音色（显示在卡片副标题上）
  final TtsVoice Function(int index, ChatMessage msg)? audioVoice;

  /// 当前正在朗读的标识（与 [AppState] 里的 key 一致）
  final String? speakingKey;

  /// 会话级「回答气泡」：开启后所有助手回答都包进气泡。
  final bool answerBubble;

  /// 服务器上是否还有更早的消息
  final bool hasOlder;

  /// 是否正在加载更早的消息
  final bool loadingOlder;

  /// 滑到顶部时拉取更早的一页
  final VoidCallback? onLoadOlder;

  /// 是否贴底发生变化（false 表示用户正在上翻看历史）
  final ValueChanged<bool>? onAtBottomChanged;

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final _controller = ScrollController();

  /// 是否停在底部（列表 reverse 后，offset 0 即最底下）。
  bool _atBottom = true;

  /// 内容是否不足一屏：不足时改用“贴顶”布局，避免短会话被挤到最底部。
  ///
  /// 初值为 false（按长会话渲染，先锚在最新一条），首帧测量后再修正，
  /// 这样打开长会话不会先闪一下顶部内容。
  bool _contentFits = false;

  /// 每条消息的 key（跳到指定消息时用来精确定位）
  final Map<int, GlobalKey> _itemKeys = {};

  /// 聊天区滚动视图本体的 key（换算条目相对顶部偏移用）
  final GlobalKey _listBoxKey = GlobalKey();

  /// 距底部多少像素内仍算“贴着底部”
  static const double _bottomThreshold = 80;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // 打开会话默认停在最新的内容上
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void didUpdateWidget(covariant MessagesView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.conversationId != oldWidget.conversationId) {
      // 点历史记录切会话：默认滑到最底下
      _jumpToBottom();
    } else if (widget.scrollToken != oldWidget.scrollToken) {
      // 自己刚发了消息 / 编辑后重新生成：回到最底下看回答
      _jumpToBottom();
    }
    // 助手流式输出时不再强制滚底：用户手动往上翻，就停在当前位置
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// 滚动位置变化：记录当前是否贴在底部，用于决定是否显示回到底部按钮。
  void _onScroll() {
    if (!_controller.hasClients) return;
    final atBottom = _controller.offset <= _bottomThreshold;
    if (atBottom != _atBottom && mounted) {
      setState(() => _atBottom = atBottom);
      // 上翻时通知外层暂停刷新（内容冻结 → 阅读位置不动、不闪烁）
      widget.onAtBottomChanged?.call(atBottom);
    }
    // 滑到顶部（reverse 列表的末尾）时继续拉更早的消息
    if (widget.hasOlder &&
        !widget.loadingOlder &&
        _controller.offset >= _controller.position.maxScrollExtent - 240) {
      widget.onLoadOlder?.call();
    }
  }

  /// 测量内容高度，决定“贴顶”还是“贴底跟随”两种布局。
  void _measureFits() {
    if (!mounted || !_controller.hasClients) return;
    final fits = _controller.position.maxScrollExtent <= 0.5;
    if (fits == _contentFits) return;
    setState(() {
      _contentFits = fits;
      if (fits && !_atBottom) {
        _atBottom = true;
        widget.onAtBottomChanged?.call(true);
      }
    });
    // 切换布局后重新定位：贴顶模式停在顶部，贴底模式停在最新一条
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  void _jumpToBottom() {
    if (!_controller.hasClients) return;
    _controller.jumpTo(0);
    if (!_atBottom && mounted) {
      setState(() => _atBottom = true);
      widget.onAtBottomChanged?.call(true);
    }
  }

  void _animateToBottom() {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每帧后测量一次内容高度：决定“贴顶”还是“贴底跟随”
    // 每帧后测量内容高度：决定“贴顶”还是“贴底跟随”
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureFits());
    final content = _contentFits ? _buildTopAligned() : _buildReverseList();
    return Stack(
      children: [
        content,
        if (!_atBottom && !_contentFits)
          Positioned(
            right: 4,
            bottom: 12,
            child: _ScrollToBottomButton(onTap: _animateToBottom),
          ),
      ],
    );
  }

  /// 内容不足一屏：普通（非倒序）滚动视图 + Column，内容贴顶排列。
  Widget _buildTopAligned() {
    return SingleChildScrollView(
      key: _listBoxKey,
      controller: _controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.hasOlder || widget.loadingOlder) _buildOlderLoader(),
          for (var i = 0; i < widget.messages.length; i++)
            _buildItem(context, i),
        ],
      ),
    );
  }

  /// 内容超过一屏：倒序列表锚在底部，新增内容自然出现在视野内；
  /// 用户往上翻时不会被强制拉回底部。
  Widget _buildReverseList() {
    return ListView.builder(
      key: _listBoxKey,
      controller: _controller,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount:
          widget.messages.length +
          (widget.hasOlder || widget.loadingOlder ? 1 : 0),
      itemBuilder: (context, i) {
        // reverse 列表：末尾这一项在最上面，用于「加载更早的消息」
        if (i >= widget.messages.length) return _buildOlderLoader();
        return _buildItem(context, widget.messages.length - 1 - i);
      },
    );
  }

  Widget _buildItem(BuildContext context, int index) {
    final m = widget.messages[index];
    final isLast = index == widget.messages.length - 1;
    // 每条的 key：用于"跳到某条用户消息"时精确滚动
    final key = _itemKeys.putIfAbsent(index, () => GlobalKey());
    return KeyedSubtree(
      key: key,
      child: _buildBubble(context, index, m, isLast),
    );
  }

  /// 弹出「跳到某条提问」选择框（只列已加载的用户消息）。
  Future<void> _showJumpDialog() async {
    final userIndexes = [
      for (var i = 0; i < widget.messages.length; i++)
        if (widget.messages[i].role == MessageRole.user) i,
    ];
    if (userIndexes.isEmpty) return;
    // 先收起输入法，避免选择框关闭后又被自动调起
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: userIndexes.length,
            itemBuilder: (_, n) {
              final index = userIndexes[n];
              final text = userMessageParts(
                widget.messages[index],
              ).text.replaceAll('\n', ' ');
              return ListTile(
                dense: true,
                leading: Text(
                  '${n + 1}',
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                title: Text(
                  text.isEmpty ? '(仅附件)' : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                onTap: () => Navigator.of(ctx).pop(index),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    // 跳转或取消之后同样收起输入法（不让键盘自己弹出来）
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    if (picked != null && mounted) await _scrollToMessage(picked);
  }

  /// 滚动到指定消息：优先用 key 精确定位，不在可视区就按比例粗跳后重试。
  Future<void> _scrollToMessage(int index) async {
    if (_contentFits) return; // 一屏装得下，全都可见
    if (!_controller.hasClients) return;
    try {
      // 先回到底部（最新一条），从已知位置开始逐屏向上找目标。
      // 不用任何"平均高度"估算——长回答高度差极大，估算必然跑偏。
      _controller.jumpTo(_controller.position.minScrollExtent);
      await WidgetsBinding.instance.endOfFrame;

      // 长会话可能有几十万像素：不能逐屏走。这里用二分查找定位目标所在区域。
      // 倒序列表：offset 增大 → 展示的条目序号变小（更老）。
      var lo = _controller.position.minScrollExtent;
      var hi = _controller.position.maxScrollExtent;
      var probes = 0;
      while (_itemKeys[index]?.currentContext == null &&
          hi - lo > _stepSize() &&
          probes < 30) {
        probes++;
        final mid = lo + (hi - lo) / 2;
        _controller.jumpTo(mid.clamp(lo, hi));
        await WidgetsBinding.instance.endOfFrame;
        final built = _builtIndexRange();
        // 这一帧还没构建出任何条目：再等一帧重试（不计入 probe 次数）
        if (built == null) {
          probes--;
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }
        if (index < built.$1) {
          lo = mid; // 目标更老 → 往 offset 大的方向
        } else if (index > built.$2) {
          hi = mid; // 目标更新 → 往 offset 小的方向
        } else {
          break; // 目标就在这一屏附近
        }
      }

      // 二分收敛后：先向上（更老）推，再向下（更新）推，双向找目标
      var guard = 0;
      while (_itemKeys[index]?.currentContext == null && guard < 40) {
        guard++;
        if (!_controller.hasClients) break;
        final next = (_controller.offset + _stepSize() * 0.5).clamp(
          _controller.position.minScrollExtent,
          _controller.position.maxScrollExtent,
        );
        if ((next - _controller.offset).abs() < 1) break;
        _controller.jumpTo(next);
        await WidgetsBinding.instance.endOfFrame;
      }
      var back = 0;
      while (_itemKeys[index]?.currentContext == null && back < 40) {
        back++;
        if (!_controller.hasClients) break;
        final prev = (_controller.offset - _stepSize() * 0.5).clamp(
          _controller.position.minScrollExtent,
          _controller.position.maxScrollExtent,
        );
        if ((prev - _controller.offset).abs() < 1) break;
        _controller.jumpTo(prev);
        await WidgetsBinding.instance.endOfFrame;
      }
      // 边界兜底：目标很靠顶（尤其 idx≈0）时，maxScrollExtent 往往还是估算值，
      // 跳到"估算的最大值"并不能把顶部真正构建出来。反复跳到当前最大值，
      // 每次都会多构建一些条目并让 max 更准，直到目标出现或 max 稳定。
      var settle = 0;
      while (_itemKeys[index]?.currentContext == null && settle < 25) {
        settle++;
        if (!_controller.hasClients) break;
        final beforeMax = _controller.position.maxScrollExtent;
        final beforeOffset = _controller.offset;
        _controller.jumpTo(beforeMax);
        await WidgetsBinding.instance.endOfFrame;
        final afterMax = _controller.position.maxScrollExtent;
        final reachedTop = beforeOffset >= beforeMax - 1;
        if (reachedTop && afterMax <= beforeMax + 1) break; // 到顶且不再增长
      }
      final target = _itemKeys[index]?.currentContext;
      if (target == null || !target.mounted) {
        return;
      }
      await _alignToTop(index);
    } catch (e) {
      // 跳转失败不影响正常使用，忽略
    }
  }

  /// 目标消息「上边缘相对聊天区上边缘」的像素偏移（取不到返回 null）。
  double _stepSize() {
    final viewport = _controller.hasClients
        ? _controller.position.viewportDimension
        : 0.0;
    return viewport > 1 ? viewport * 0.85 : 800.0;
  }

  /// 当前这一屏里已构建条目的序号范围（用于二分判断方向）。
  (int, int)? _builtIndexRange() {
    int? minIndex;
    int? maxIndex;
    _itemKeys.forEach((index, key) {
      if (key.currentContext == null) return;
      minIndex = minIndex == null || index < minIndex! ? index : minIndex;
      maxIndex = maxIndex == null || index > maxIndex! ? index : maxIndex;
    });
    if (minIndex == null || maxIndex == null) return null;
    return (minIndex!, maxIndex!);
  }

  double? _offsetFromTop(int index) {
    final ctx = _itemKeys[index]?.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    final listBox = _listBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || listBox == null || !box.hasSize || !listBox.hasSize) {
      return null;
    }
    // 全局坐标相减：不做 ancestor 映射（那条路径会抛断言，异常被吞掉后
    // 会停在 ensureVisible(0.5) 的居中位置——也就是"跳到中间"的原因）
    final itemTop = box.localToGlobal(Offset.zero).dy;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    return itemTop - listTop;
  }

  /// 顶对齐：用**实测误差**闭环修正，不依赖倒序轴的方向约定。
  Future<void> _alignToTop(int index) async {
    // 先把目标大致带进视野
    final ctx = _itemKeys[index]?.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(ctx, alignment: 0.5);
    }
    var sign = 1.0;
    double? lastVisibleOffset; // 目标最后一次可见时的偏移（走错时回退用）
    for (var i = 0; i < 8; i++) {
      final delta = _offsetFromTop(index);
      if (delta != null && delta.abs() <= 1.5) return; // 已对齐
      if (delta == null) {
        // 目标被滚出视野：说明上一步方向反了 → 退回上次可见位置并换向重来
        if (lastVisibleOffset != null && _controller.hasClients) {
          _controller.jumpTo(lastVisibleOffset);
          await WidgetsBinding.instance.endOfFrame;
          sign = -sign;
          lastVisibleOffset = null;
          continue;
        }
        return;
      }
      final before = delta.abs();
      lastVisibleOffset = _controller.offset;
      final position = _controller.position;
      final target = (_controller.offset + sign * delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - _controller.offset).abs() < 0.5) return; // 到边界
      _controller.jumpTo(target);
      await WidgetsBinding.instance.endOfFrame;
      final after = _offsetFromTop(index)?.abs();
      // 误差没变小说明方向反了，换向
      if (after != null && after > before - 0.5) sign = -sign;
    }
  }

  Widget _buildBubble(
    BuildContext context,
    int index,
    ChatMessage m,
    bool isLast,
  ) {
    if (m.role == MessageRole.user) {
      return _UserBubble(
        msg: m,
        canEdit: !widget.busy,
        onEdit: () => widget.onEditStart(index),
        onCopy: () {
          if (m.content.isEmpty) {
            widget.onNotice('该消息无文字内容');
            return;
          }
          Clipboard.setData(ClipboardData(text: m.content));
          widget.onNotice('已复制到剪贴板');
        },
      );
    }
    // 流式进行中的空占位 assistant：显示加载指示
    final showTyping = widget.busy && isLast && m.content.isEmpty;
    final speakKey = speakKeyFor(widget.conversationId, m, index: index);
    return _AssistantBubble(
      msg: m,
      index: index,
      busy: widget.busy,
      isLast: isLast,
      showTyping: showTyping,
      answerBubble: widget.answerBubble,
      onToggleThinking: () => widget.onToggleThinking(index),
      onRegenerate: () => widget.onRegenerateAt(index),
      onStop: widget.onStop,
      onViewSource: () => _showSource(context, m),
      onJumpToMessage: _showJumpDialog,
      onNotice: widget.onNotice,
      onSpeak: widget.onSpeak == null
          ? null
          : () => widget.onSpeak!(index, m),
      // 操作行长按：按这条回答的正文现合成（与卡片里的录音无关）
      onDownloadSpeech: widget.onDownloadAudio == null
          ? null
          : () => widget.onDownloadAudio!(index, m),
      // 音频卡片右侧下载：取模型生成的那条录音
      onDownloadAudioFile: widget.onDownloadCardAudio == null
          ? null
          : () => widget.onDownloadCardAudio!(index, m),
      onPlayAudio: widget.onPlayAudio == null
          ? null
          : () => widget.onPlayAudio!(index, m),
      audioVoice: widget.audioVoice?.call(index, m) ?? TtsVoice.stella,
      speaking: widget.speakingKey != null && widget.speakingKey == speakKey,
    );
  }

  /// 顶部「正在加载更早的消息」占位。
  Widget _buildOlderLoader() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  void _showSource(BuildContext context, ChatMessage msg) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('原文（Markdown）'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              msg.content,
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: msg.content));
              widget.onNotice('已复制原文到剪贴板');
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

/// 「回到底部」按钮的 Key（供测试定位使用）。
const Key scrollToBottomButtonKey = Key('scroll-to-bottom-button');

/// 回到底部按钮：圆形、白底、周围灰色阴影，内部是深灰向下箭头。
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '回到底部',
      child: GestureDetector(
        key: scrollToBottomButtonKey,
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x291F2687),
                blurRadius: 18,
                offset: Offset(0, 6),
                spreadRadius: -4,
              ),
            ],
          ),
          child: const Center(
            child: CustomPaint(
              size: Size(16, 11),
              painter: _ChevronDownPainter(openingDegrees: 105),
            ),
          ),
        ),
      ),
    );
  }
}

/// 深灰向下箭头：`<` 旋转 90° 后的造型，开口约 105°。
class _ChevronDownPainter extends CustomPainter {
  const _ChevronDownPainter({this.openingDegrees = 105});

  /// 两条边之间的夹角（开口角度）
  final double openingDegrees;

  /// 线条颜色（深灰）与粗细
  static const Color _color = AppColors.textPrimary;
  static const double _strokeWidth = 2.2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _color
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final half = openingDegrees / 2 * math.pi / 180;
    final apex = Offset(size.width / 2, size.height - _strokeWidth / 2);
    final arm = size.height - _strokeWidth;
    final left = apex + Offset(-arm * math.sin(half), -arm * math.cos(half));
    final right = apex + Offset(arm * math.sin(half), -arm * math.cos(half));
    canvas.drawPath(
      Path()
        ..moveTo(left.dx, left.dy)
        ..lineTo(apex.dx, apex.dy)
        ..lineTo(right.dx, right.dy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ChevronDownPainter oldDelegate) =>
      oldDelegate.openingDegrees != openingDegrees;
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.msg,
    required this.canEdit,
    required this.onEdit,
    required this.onCopy,
  });

  final ChatMessage msg;
  final bool canEdit;
  final VoidCallback onEdit;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    // 气泡内可用宽度：文件卡/图片都必须收在这个宽度内，否则会顶出气泡
    final innerWidth = MediaQuery.of(context).size.width * 0.78 - 28;
    // 正文与文件卡片只解析一次（build 内复用，不再每帧对正文重复跑正则）
    final parts = userMessageParts(msg);
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        // 点击整体气泡即可进入编辑；长按复制该条内容
        behavior: HitTestBehavior.opaque,
        onTap: canEdit ? onEdit : null,
        onLongPress: onCopy,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(vertical: 6),
          // 外层不再铺蓝底：图片/文件卡保持白底独立成块，只有文字进气泡
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (msg.hasImage) ...[
                // 图片预览：圆角 + 浅描边，按比例缩放（官方样式），不再裁成小方块
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final url in msg.imageDataUrls)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _imagePreview(
                          url,
                          innerWidth,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              for (final file in parts.files)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _FileCard(file: file),
                ),
              if (parts.text.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    gradient: AppGradients.userBubble,
                    // 全圆角：右下角不再留尖角
                    borderRadius: BorderRadius.circular(AppDimens.bubbleCorner),
                    // 描边压回很浅的一档，避免和正文抢视觉
                    border: Border.all(color: const Color(0xFFE9EDF7)),
                    boxShadow: AppShadows.bubble,
                  ),
                  child: Text(
                    parts.text,
                    style: const TextStyle(
                      // 比助手正文小一号、颜色更浅：阅读主体是回答
                      fontSize: 15,
                      color: Color(0xFF2E3340),
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.msg,
    required this.index,
    required this.busy,
    required this.isLast,
    required this.showTyping,
    required this.answerBubble,
    required this.onToggleThinking,
    required this.onRegenerate,
    required this.onStop,
    required this.onViewSource,
    required this.onJumpToMessage,
    required this.onNotice,
    this.onSpeak,
    // 操作行长按喇叭：按这条回答的**正文**现合成（与卡片录音无关）
    this.onDownloadSpeech,
    // 音频卡片下载：取模型 text_to_speech 生成的那条录音
    this.onDownloadAudioFile,
    this.onPlayAudio,
    this.audioVoice = TtsVoice.stella,
    this.speaking = false,
    });

  final ChatMessage msg;
  final int index;
  final bool busy;
  /// 是否是最后一条（正在输出）
  final bool isLast;
  final bool showTyping;

  /// 会话级开关：把所有回答包进气泡
  final bool answerBubble;
  final VoidCallback onToggleThinking;
  final VoidCallback onRegenerate;
  final VoidCallback onStop;
  final VoidCallback onViewSource;
  /// 跳到某条用户消息（弹选择框）
  final VoidCallback onJumpToMessage;
  final void Function(String) onNotice;

  /// 操作行上的朗读按钮：朗读这条回答（点击时才生成语音）
  final VoidCallback? onSpeak;

  /// 长按操作行喇叭：按回答正文现合成音频保存到本地
  /// （语义是「下载这段文字的朗读」，不是卡片里的录音）
  final VoidCallback? onDownloadSpeech;

  /// 音频卡片下载：保存模型 text_to_speech 生成的那条录音
  final VoidCallback? onDownloadAudioFile;

  /// 音频卡片左侧圆形按钮：播放 / 停止模型生成的音频文件
  final VoidCallback? onPlayAudio;

  /// 音频卡片上显示的音色
  final TtsVoice audioVoice;

  /// 当前是否正在朗读/播放这条回答
  final bool speaking;

  /// 回答正文：文本段走 Markdown（链接可点开），代码段走官方样式代码块，
  /// 引用块走单独的灰色样式。
  List<Widget> _buildAnswer(BuildContext context, String content) {
    final widgets = <Widget>[];
    for (final segment in splitMarkdownSegments(content)) {
      if (segment.isCode) {
        widgets.add(
          _CodeBlock(
            code: segment.text.trimRight(),
            language: segment.language,
            onNotice: onNotice,
          ),
        );
      } else if (segment.isQuote) {
        widgets.add(_QuoteBlock(text: segment.text, onNotice: onNotice));
      } else if (segment.isMath) {
        // 块级 LaTeX 公式：公式本身可横向滚动，避免超长公式被截断
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Math.tex(
                segment.text,
                mathStyle: MathStyle.display,
                textStyle: _answerTextStyle,
                onErrorFallback: (_) => SelectableText(
                  '\$\$${segment.text}\$\$',
                  style: _answerTextStyle,
                ),
              ),
            ),
          ),
        );
      } else {
        widgets.add(
          SelectionArea(
            child: _MarkdownText(
              // 未配对的 ** 先转义，避免渲染失败把正文吞掉
              data: escapeUnmatchedBold(segment.text),
              styleSheet: _markdownStyle,
              baseStyle: _answerTextStyle,
              onTapLink: (text, href, title) => openExternalUrl(href, onNotice),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    // 防空白：非流式中、且既无正文也无思考内容时，不渲染空气泡（历史残留占位）
    if (!showTyping && msg.content.isEmpty && msg.reasoning.isEmpty) {
      return const SizedBox.shrink();
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (msg.reasoning.isNotEmpty) ...[
          _ThinkingSection(
            msg: msg,
            onToggle: onToggleThinking,
            // 思考中（正文还没开始）用小块滚动展示
            streaming: busy && isLast && msg.content.isEmpty,
          ),
          const SizedBox(height: 2),
        ],
        if (showTyping)
          // 思考阶段（正文还没出来）也要能停止生成
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _TypingIndicator(),
              Align(
                alignment: Alignment.centerRight,
                child: _ActionIcon(icon: Icons.stop, onTap: onStop),
              ),
            ],
          )
        else if (msg.content.isNotEmpty) ...[
          ..._buildAnswer(context, msg.content),
          if (msg.hasSources) ...[
            const SizedBox(height: 2),
            _SourcesSection(sources: msg.sources, onNotice: onNotice),
          ],
          // 音频卡片：模型用 text_to_speech 生成的音频，点左侧图标即播放
          if (msg.hasAudio && onPlayAudio != null) ...[
            for (final id in msg.audioFiles)
              _AudioFileCard(
                fileName: '${id.length > 8 ? id.substring(0, 8) : id}.wav',
                voice: audioVoice,
                playing: speaking,
                onPlay: onPlayAudio!,
                // 卡片的下载按钮：取这条录音本身
                onDownload: onDownloadAudioFile,
              ),
          ],
          const SizedBox(height: 8),
          _ActionRow(
            busy: busy,
            onRegenerate: onRegenerate,
            onStop: onStop,
            onViewSource: onViewSource,
            onJumpToMessage: onJumpToMessage,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: msg.content));
              onNotice('已复制到剪贴板');
            },
            onSpeak: onSpeak,
            // 操作行长按：按正文合成（不是卡片录音）
            onDownloadAudio: onDownloadSpeech,
            speaking: speaking,
          ),
        ],
      ],
    );
    if (!answerBubble) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: content,
      );
    }
    // 开启「回答气泡」：所有回答（含长回答）包进白端渐变气泡
    final maxWidth = MediaQuery.of(context).size.width * 0.92 - 32;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          gradient: AppGradients.answerBubble,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: const Color(0xFFF0EEF9)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x142952D2),
              blurRadius: 20,
              offset: Offset(0, 8),
              spreadRadius: -18,
            ),
          ],
        ),
        child: content,
      ),
    );
  }
}

/// 回答正文的基础字体（Markdown 里的普通文本用它取色）。
///
/// 字号与用户气泡（15）基本一致，靠更深的颜色和更松的行距保持阅读主体地位。
const TextStyle _answerTextStyle = TextStyle(
  fontSize: 15.5,
  color: Color(0xFF14171F),
  height: 1.6,
);

/// 思考区的基础字体（比正文小一号的灰字）。
const TextStyle _reasoningTextStyle = TextStyle(
  fontSize: 14,
  color: AppColors.textQuote,
  height: 1.55,
);

/// 引用块的基础字体（官方引用块整段是灰字）。
const TextStyle _quoteTextStyle = TextStyle(
  fontSize: 15,
  color: Color(0xFF5F6577),
  height: 1.6,
);

/// Markdown 渲染容器：统一基础字体。
///
/// 说明：flutter_markdown 0.7 在 Material 主题下，段落样式会带上 `inherit: false`
/// （来自 Typography 本地化），引用块内文字取的是「段落样式」，因此
/// `MarkdownStyleSheet.blockquote` 的颜色不生效——所以引用块不交给它渲染，
/// 由 [_QuoteBlock] 单独处理。
class _MarkdownText extends StatelessWidget {
  const _MarkdownText({
    required this.data,
    required this.styleSheet,
    required this.baseStyle,
    this.onTapLink,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final TextStyle baseStyle;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: baseStyle,
      child: MarkdownBody(
        data: data,
        styleSheet: styleSheet,
        onTapLink: onTapLink,
        // 行内 LaTeX：$...$
        builders: {'math': _InlineMathBuilder()},
        extensionSet: md.ExtensionSet(
          md.ExtensionSet.gitHubWeb.blockSyntaxes,
          [
            // 行内公式：支持 $...$ 与 LaTeX 的 \(...\)
            _InlineMathSyntax(r'\$([^$\n]+)\$'),
            _InlineMathSyntax(r'\\\((.+?)\\\)'),
            ...md.ExtensionSet.gitHubWeb.inlineSyntaxes,
          ],
        ),
      ),
    );
  }
}

/// 回答正文的 Markdown 样式。
///
/// 字号跟用户气泡对齐（15.5 / 15），靠块间距、标题层级、引用/代码块的
/// 浅色底建立结构；行内代码用 TextStyle.backgroundColor 上底色。
final MarkdownStyleSheet _markdownStyle = MarkdownStyleSheet(
  // 正文颜色交给外层 DefaultTextStyle（见 _MarkdownText）
  p: const TextStyle(fontSize: 15.5, height: 1.6),
  // 加粗比正文略重即可：w700 在中文里糊成一团，且会和标题失去区分度
  strong: const TextStyle(fontWeight: FontWeight.w600),
  em: const TextStyle(fontStyle: FontStyle.italic),
  // 列表符号、表格单元由 flutter_markdown 直接取样式渲染，颜色写死更稳妥
  listBullet: const TextStyle(fontSize: 15.5, color: Color(0xFF14171F)),
  h1: const TextStyle(fontSize: 19.5, fontWeight: FontWeight.w600, height: 1.4),
  h2: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.4),
  h3: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, height: 1.45),
  h4: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.45),
  h5: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.45),
  h6: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.45),
  // 兜底：正文引用块已由 _QuoteBlock 单独渲染，这里只为「引用块里再套引用块」
  // 之类漏网情况保留浅灰竖线（文字颜色受 flutter_markdown 限制，跟随段落样式）
  blockquote: const TextStyle(
    fontSize: 15,
    color: AppColors.textQuote,
    height: 1.55,
  ),
  blockquotePadding: const EdgeInsets.only(left: 14),
  blockquoteDecoration: const BoxDecoration(
    border: Border(left: BorderSide(color: AppColors.border, width: 2)),
  ),
  a: TextStyle(
    color: AppColors.brand,
    decoration: TextDecoration.underline,
    decorationColor: AppColors.brand.withValues(alpha: 0.35),
  ),
  // 行内代码：浅灰底 + 深灰字（TextStyle 的背景是矩形，无圆角）
  code: const TextStyle(
    fontSize: 14.5,
    fontFamily: 'monospace',
    color: Color(0xFF3A4054),
    backgroundColor: Color(0xFFF2F4F9),
  ),
  // 官方没有那道 5px 粗黑分割线，这里压成一条 1px 浅灰细线
  horizontalRuleDecoration: const BoxDecoration(
    border: Border(top: BorderSide(color: Color(0xFFEDEFF4))),
  ),
  // 表格：只保留横线，表头灰字加粗
  tableBorder: TableBorder(
    top: BorderSide(color: const Color(0xFFE0E5EF)),
    bottom: BorderSide(color: const Color(0xFFECEEF4)),
    horizontalInside: BorderSide(color: const Color(0xFFECEEF4)),
  ),
  tableHead: const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: Color(0xFF5F6577),
  ),
  tableBody: const TextStyle(fontSize: 14, color: Color(0xFF2A2F3D)),
  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  // 段落/块之间的呼吸感（flutter_markdown 默认 8）
  blockSpacing: 12,
  listIndent: 18,
);

/// 引用块内的 Markdown 样式：整段压成灰字。
final MarkdownStyleSheet _quoteMarkdownStyle = _markdownStyle.copyWith(
  p: const TextStyle(fontSize: 15, color: Color(0xFF5F6577), height: 1.6),
  strong: const TextStyle(
    fontWeight: FontWeight.w700,
    color: AppColors.textQuote,
  ),
  em: const TextStyle(fontStyle: FontStyle.italic, color: AppColors.textQuote),
  listBullet: const TextStyle(fontSize: 16, color: AppColors.textQuote),
  h1: const TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.4,
    color: AppColors.textQuote,
  ),
  h2: const TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    height: 1.4,
    color: AppColors.textQuote,
  ),
  h3: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.45,
    color: AppColors.textQuote,
  ),
  h4: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.45,
    color: AppColors.textQuote,
  ),
  h5: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.45,
    color: AppColors.textQuote,
  ),
  h6: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    height: 1.45,
    color: AppColors.textQuote,
  ),
  tableHead: const TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AppColors.textQuote,
  ),
  tableBody: const TextStyle(fontSize: 15, color: AppColors.textQuote),
);

/// 引用块：浅灰底 + 左侧 3px 竖线 + 圆角，作为正文里的"旁注"。
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.text, required this.onNotice});

  final String text;
  final void Function(String) onNotice;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FB),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(width: 3, color: const Color(0xFFD8DEEC)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 12, 14, 12),
            child: SelectionArea(
              child: _MarkdownText(
                data: text,
                styleSheet: _quoteMarkdownStyle,
                baseStyle: _quoteTextStyle,
                onTapLink: (linkText, href, title) =>
                    openExternalUrl(href, onNotice),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 思考过程（已思考面板）的 Markdown 样式：官方是白底 + 浅灰竖线 + 灰字。
final MarkdownStyleSheet _reasoningMarkdownStyle = MarkdownStyleSheet(
  p: const TextStyle(
    fontSize: 14,
    color: AppColors.textQuote,
    height: 1.55,
  ),
  listBullet: const TextStyle(fontSize: 14, color: AppColors.textQuote),
  h1: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
  h2: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
  h3: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  h4: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  h5: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  h6: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
  blockquote: const TextStyle(
    fontSize: 14,
    color: AppColors.textQuote,
    height: 1.55,
  ),
  blockquotePadding: const EdgeInsets.only(left: 12),
  blockquoteDecoration: const BoxDecoration(
    border: Border(left: BorderSide(color: AppColors.border, width: 2)),
  ),
  code: const TextStyle(
    fontSize: 13,
    fontFamily: 'monospace',
    color: AppColors.textQuote,
  ),
  a: const TextStyle(color: AppColors.brand),
  horizontalRuleDecoration: const BoxDecoration(
    border: Border(top: BorderSide(color: AppColors.border)),
  ),
  tableBorder: TableBorder.all(color: AppColors.border),
  tableHead: const TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: AppColors.textQuote,
  ),
  tableBody: const TextStyle(fontSize: 13, color: AppColors.textQuote),
  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
);

/// 代码块：白卡 + 1px 描边 + 顶部语言栏，正文等宽字体且可横向滚动。
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.onNotice,
  });

  final String code;
  final String? language;
  final void Function(String) onNotice;

  @override
  Widget build(BuildContext context) {
    final label = (language == null || language!.isEmpty) ? 'code' : language!;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFBFCFE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFECEEF4)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 12),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 0.2,
                    color: Color(0xFF8A91A5),
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                    onNotice('已复制代码');
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.copy_rounded,
                          size: 13,
                          color: Color(0xFF8A91A5),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '复制',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF8A91A5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 1, color: Color(0xFFEFF1F6)),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.7,
                  color: Color(0xFF2A2F3D),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 联网搜索来源：默认收起，展开后点标题复制链接（暂不内置浏览器跳转）。
class _SourcesSection extends StatefulWidget {
  const _SourcesSection({required this.sources, required this.onNotice});

  final List<ChatSource> sources;
  final void Function(String) onNotice;

  @override
  State<_SourcesSection> createState() => _SourcesSectionState();
}

class _SourcesSectionState extends State<_SourcesSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.public,
                  size: 15,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '${widget.sources.length} 条来源',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.thinkingBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in widget.sources)
                  InkWell(
                    onTap: () => openExternalUrl(s.url, widget.onNotice),
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: s.url));
                      widget.onNotice('已复制来源链接');
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                          Text(
                            s.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 音频文件卡片：白卡 + 1px 浅灰边，与文件卡片、来源卡片同一套语言。
///
/// 卡片是「模型生成的一个音频文件」的展示位：**点左侧圆形图标即播放/停止**，
/// 没有额外按钮。文件由模型的 `text_to_speech` 工具产出。
class _AudioFileCard extends StatelessWidget {
  const _AudioFileCard({
    required this.fileName,
    required this.voice,
    required this.playing,
    required this.onPlay,
    this.onDownload,
  });

  final String fileName;

  /// 这条音频使用的音色
  final TtsVoice voice;

  /// 是否正在播放
  final bool playing;

  /// 点左侧图标：播放 / 停止
  final VoidCallback onPlay;

  /// 下载到系统下载目录（音频平时只存在服务器）
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Row(
        children: [
          // 左侧圆形按钮：点击即播放 / 停止（官方同款「播放」入口）
          InkWell(
            onTap: onPlay,
            customBorder: const CircleBorder(),
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                gradient: AppGradients.brand,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 21,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '音频 · ${voice.label}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (onDownload != null)
            IconButton(
              onPressed: onDownload,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              color: AppColors.textSecondary,
              tooltip: '下载到手机下载目录',
              icon: const Icon(Icons.download_outlined),
            ),
        ],
      ),
    );
  }
}

class _ThinkingSection extends StatefulWidget {  const _ThinkingSection({
    required this.msg,
    required this.onToggle,
    this.streaming = false,
  });

  final ChatMessage msg;
  final VoidCallback onToggle;

  /// 是否正在输出思考（此时用限高小块滚动展示）
  final bool streaming;

  @override
  State<_ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<_ThinkingSection> {
  final _ctrl = ScrollController();

  @override
  void didUpdateWidget(covariant _ThinkingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 思考中：有新内容就滚到小块底部
    if (widget.streaming &&
        widget.msg.reasoning.length != oldWidget.msg.reasoning.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_ctrl.hasClients) {
          _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.msg;
    // 思考中默认显示小块；用户点开则展开完整块；结束后按 thinkingExpanded（默认收起）
    final expanded = msg.thinkingExpanded;
    final seconds = (msg.reasoningMs / 1000).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: widget.onToggle,
          borderRadius: BorderRadius.circular(7),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(7),
              // 描边压回很浅的一档，胶囊只作为辅助信息
              border: Border.all(color: const Color(0xFFEDF0F6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A1F2687),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                  spreadRadius: -6,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.streaming ? '正在思考' : '已思考',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.2,
                    color: Color(0xFF6E7899),
                  ),
                ),
                if (!widget.streaming && msg.reasoningMs > 0)
                  Text(
                    '（用时 $seconds 秒）',
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.2,
                      color: Color(0xFF6E7899),
                    ),
                  ),
                const SizedBox(width: 2),
                Icon(
                  // 思考中未展开：上下箭头（<>）；展开：向下；已结束收起：向右的 >
                  (widget.streaming && !expanded)
                      ? Icons.unfold_more
                      : (expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.chevron_right),
                  size: 13,
                  color: const Color(0xFF8A94B4),
                ),
              ],
            ),
          ),
        ),
        if (widget.streaming && !expanded)
          // 输出中：限高小块，内部滚动显示思考过程
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 10),
            padding: const EdgeInsets.only(left: 12),
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.border, width: 2),
              ),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: SingleChildScrollView(
                controller: _ctrl,
                child: _MarkdownText(
                  data: msg.reasoning,
                  styleSheet: _reasoningMarkdownStyle,
                  baseStyle: _reasoningTextStyle,
                ),
              ),
            ),
          )
        else if (expanded)
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 10),
            padding: const EdgeInsets.only(left: 12),
            // 官方思考区：白底、只有一条浅灰竖线、整段灰字
            decoration: const BoxDecoration(
              border: Border(
                left: BorderSide(color: AppColors.border, width: 2),
              ),
            ),
            child: _MarkdownText(
              data: msg.reasoning,
              styleSheet: _reasoningMarkdownStyle,
              baseStyle: _reasoningTextStyle,
            ),
          ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.busy,
    required this.onRegenerate,
    required this.onStop,
    required this.onViewSource,
    required this.onJumpToMessage,
    required this.onCopy,
    this.onSpeak,
    this.onDownloadAudio,
    this.speaking = false,
  });

  final bool busy;
  final VoidCallback onRegenerate;
  final VoidCallback onStop;
  final VoidCallback onViewSource;
  final VoidCallback onJumpToMessage;
  final VoidCallback onCopy;

  /// 点播放：朗读这条回答（官方同款「播放」按钮）
  final VoidCallback? onSpeak;

  /// 长按播放：下载这条回答的音频
  final VoidCallback? onDownloadAudio;

  /// 是否正在朗读这条
  final bool speaking;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ActionIcon(icon: Icons.copy_rounded, onTap: onCopy),
        const SizedBox(width: 16),
        _ActionIcon(icon: Icons.subject, onTap: onViewSource),
        const SizedBox(width: 16),
        // 跳到某条用户提问
        _ActionIcon(icon: Icons.list_alt, onTap: onJumpToMessage),
        if (onSpeak != null) ...[
          const SizedBox(width: 16),
          // 朗读：点击播放/停止，长按下载音频（与官方客户端一致）
          _ActionIcon(
            icon: speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined,
            onTap: onSpeak,
            onLongPress: onDownloadAudio,
            highlighted: speaking,
            tooltip: '朗读（长按下载音频）',
          ),
        ],
        const Spacer(),
        _ActionIcon(
          icon: busy ? Icons.stop : Icons.refresh,
          onTap: busy ? onStop : onRegenerate,
        ),
      ],
    );
  }
}

class _ActionIcon extends StatefulWidget {
  const _ActionIcon({
    required this.icon,
    required this.onTap,
    this.onLongPress,
    this.highlighted = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool highlighted;
  final String? tooltip;

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  /// 按下态：重新生成 / 停止是「点了要等一轮」的操作，手指按下时必须有反馈，
  /// 否则用户以为没点上会重复点。
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.highlighted || _pressed;
    final iconWidget = Icon(
      widget.icon,
      size: 20,
      color: highlighted ? AppColors.brand : AppColors.textSecondary,
    );
    final button = InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onHighlightChanged: (value) {
        if (!mounted || _pressed == value) return;
        setState(() => _pressed = value);
      },
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
        child: AnimatedScale(
          scale: _pressed ? 0.82 : 1,
          duration: const Duration(milliseconds: 90),
          child: iconWidget,
        ),
      ),
    );
    // 不用 Tooltip：默认长按会弹出，会和「长按下载」抢手势
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: button,
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _dot(),
          const SizedBox(width: 4),
          _dot(),
          const SizedBox(width: 4),
          _dot(),
        ],
      ),
    );
  }

  Widget _dot() => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      color: AppColors.textSecondary.withValues(alpha: 0.5),
      shape: BoxShape.circle,
    ),
  );
}

/// 用户消息里的文件卡片：浅色底图标块 + 文件名 + 大小（对齐官方 文件预览.jpg）。
class _FileCard extends StatelessWidget {
  const _FileCard({required this.file});

  final UserFileCard file;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 长文件名不能撑破气泡
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFEEF0F4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.description,
              size: 24,
              color: Color(0xFF5B6BF0),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (file.size.isNotEmpty)
                  Text(
                    file.size,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// `**` 个数为奇数时最后一个无法配对（渲染容易吃掉后面的文本）：
/// 把它转义成普通字符，保证原文照常显示。
String escapeUnmatchedBold(String text) {
  final count = RegExp(r'\*\*').allMatches(text).length;
  if (count == 0 || count.isEven) return text;
  final last = text.lastIndexOf('**');
  if (last < 0) return text;
  return '${text.substring(0, last)}\\*\\*${text.substring(last + 2)}';
}

/// 图片预览：按比例缩放 + 圆角 + 浅描边（官方 图片预览.jpg 样式）。
Widget _imagePreview(String dataUrl, double maxWidth) {
  // data URL 形如 data:image/png;base64,xxx
  final comma = dataUrl.indexOf(',');
  final base64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: SizedBox(
      // 固定尺寸缩略图，不按原图比例撑大
      width: _imageThumbSize,
      height: _imageThumbSize,
      child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Image.memory(
        base64Decode(base64),
        width: _imageThumbSize,
        height: _imageThumbSize,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
      ),
    ),
  );
}

/// 消息里图片缩略图的固定边长
const double _imageThumbSize = 160;
