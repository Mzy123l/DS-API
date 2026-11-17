import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../theme.dart';
import 'whale_logo.dart';

/// 历史会话抽屉。默认半屏；点击搜索框进入全屏搜索；底部为账号/配置行。
///
/// 列表与搜索页对齐官方样式：按日期分组、会话行只有标题；
/// 搜索结果是“消息级”命中（头像 + 标题 + 时间 + 片段，可切换同一会话内的多命中）。
class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({
    super.key,
    required this.conversations,
    required this.currentId,
    required this.apiKey,
    required this.quickModelOverride,
    required this.expertModelOverride,
    required this.searchActive,
    required this.searchHits,
    required this.onSearchActive,
    required this.onSearch,
    required this.onSelect,
    required this.onOpenHit,
    required this.onDelete,
    required this.onOpenKeyConfig,
    required this.onOpenVoiceSettings,
    required this.onBack,
    this.hasMore = false,
    this.onLoadMore,
    this.onLoadAllIds,
    this.onDeleteIds,
  });

  final List<Conversation> conversations;
  final int? currentId;
  final String? apiKey;
  final String? quickModelOverride;
  final String? expertModelOverride;
  final bool searchActive;
  final List<MessageHit> searchHits;
  final ValueChanged<bool> onSearchActive;
  final ValueChanged<String> onSearch;
  final ValueChanged<Conversation> onSelect;
  final ValueChanged<MessageHit> onOpenHit;
  final ValueChanged<Conversation> onDelete;
  final VoidCallback onOpenKeyConfig;

  /// 打开设置页（默认朗读音色等）
  final VoidCallback onOpenVoiceSettings;
  final VoidCallback onBack;

  /// 是否还有更早的会话（服务器分页）
  final bool hasMore;

  /// 列表滑到底部时加载下一页
  final VoidCallback? onLoadMore;
  /// 取全部会话 id（"全选"要选到服务器上所有会话，不只是已加载的）
  final Future<List<int>> Function()? onLoadAllIds;
  /// 按 id 批量删除
  final Future<void> Function(List<int> ids)? onDeleteIds;

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  /// 多选模式（点右上角三根线进入）：可滑动选择条目，底部支持全选/删除
  bool _selectMode = false;
  final Set<int> _selectedIds = <int>{};
  /// 固定行高：滑选要把触点坐标换算成行序号
  static const double _rowHeight = 44;
  final ScrollController _listCtrl = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  /// 当前列表（滑选时按行序号取会话）
  List<Conversation> _visible = const [];
  int? _dragIndex;
  int _lastTopIndex = -1;
  /// 全部会话数量（拉全量 id 后才知道）
  int? _allCount;
  /// 是否处于"滑选"中（起点必须在圆框内）
  bool _dragActive = false;
  /// 滑选开始时的滚动位置：滑选期间把列表钉住，禁止上下滑动
  double _dragStartOffset = 0;
  /// 滑选起始那一下已经切换过选中态，抬手时的点击要忽略
  bool _suppressTap = false;

  /// 滚动时刷新顶部常驻日期
  void _onListScroll() {
    final index = (_listCtrl.offset / _rowHeight).floor();
    if (index == _lastTopIndex || !mounted) return;
    _lastTopIndex = index;
    setState(() {});
  }

  /// 触点 → 行序号（行高固定，直接用偏移换算）
  int? _indexAt(Offset globalPosition) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(globalPosition);
    final contentY = local.dy + (_listCtrl.hasClients ? _listCtrl.offset : 0);
    final index = (contentY / _rowHeight).floor();
    if (index < 0 || index >= _visible.length) return null;
    return index;
  }

  /// 起点：只有落在左侧勾选圆框内才开始滑选，其余位置交给点击
  void _onPointerDown(Offset globalPosition) {
    if (!_selectMode || _visible.isEmpty) return;
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(globalPosition);
    // 圆形勾选框大致在 x∈[12,44] 的范围内
    final inCircle = local.dx >= 8 && local.dx <= 48;
    final index = _indexAt(globalPosition);
    _dragActive = inCircle && index != null;
    if (!_dragActive || index == null) return;
    _dragStartOffset = _listCtrl.hasClients ? _listCtrl.offset : 0;
    _dragIndex = index;
    _suppressTap = true;
    _toggleAt(index);
  }

  /// 移动：滑选过程中划过的每一行都切换一次
  void _onPointerMove(Offset globalPosition) {
    if (!_dragActive) return;
    // 滑选期间禁掉列表滚动：把偏移钉回按下时的位置
    if (_listCtrl.hasClients &&
        (_listCtrl.offset - _dragStartOffset).abs() > 0.5) {
      _listCtrl.jumpTo(
        _dragStartOffset.clamp(
          _listCtrl.position.minScrollExtent,
          _listCtrl.position.maxScrollExtent,
        ),
      );
    }
    final index = _indexAt(globalPosition);
    if (index == null || index == _dragIndex) return;
    _dragIndex = index;
    _suppressTap = false;
    _toggleAt(index);
  }

  void _endDrag() {
    _dragIndex = null;
    _dragActive = false;
    if (_suppressTap) {
      // 抬手后紧跟的 onClick 忽略一次，避免把滑选起始那行又切回去
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        _suppressTap = false;
      });
    }
  }

  void _toggleAt(int index) {
    final id = _visible[index].id;
    setState(() {
      if (!_selectedIds.add(id)) _selectedIds.remove(id);
    });
  }

  /// 同一条消息有多个命中时，当前展示第几个（key 由消息身份生成）
  final Map<String, int> _hitCursor = {};

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(_onFocusChange);
    _listCtrl.addListener(_onListScroll);
  }

  @override
  void dispose() {
    _searchFocus.removeListener(_onFocusChange);
    _searchFocus.dispose();
    _searchCtrl.dispose();
    _listCtrl.removeListener(_onListScroll);
    _listCtrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    // 聚焦 -> 全屏搜索；失焦 -> 回到半屏
    if (_searchFocus.hasFocus != widget.searchActive) {
      widget.onSearchActive(_searchFocus.hasFocus);
    }
  }

  void _hideKeyboard() {
    _searchFocus.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  void _onBackPressed() {
    final wasFocused = _searchFocus.hasFocus;
    _hideKeyboard();
    if (!wasFocused) {
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.searchActive;
    // 背景由外层磨砂玻璃面板提供，这里保持透明
    return Container(
      color: Colors.transparent,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(full ? 4 : 16, 10, 16, 6),
              child: Row(
                children: [
                  if (full)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new, size: 19),
                      color: AppColors.textPrimary,
                      onPressed: _onBackPressed,
                    ),
                  Expanded(child: _buildSearchField()),
                ],
              ),
            ),
            Expanded(
              child: full
                  ? _buildSearchResults()
                  : _buildConversationList(),
            ),
            if (!full) _selectMode ? _buildSelectBar() : _buildAccountRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.66),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: AppColors.brand.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F1F2687),
            blurRadius: 16,
            offset: Offset(0, 6),
            spreadRadius: -10,
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.search,
            size: 20,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: (v) {
                setState(() => _query = v.trim());
                widget.onSearch(v.trim());
              },
              textInputAction: TextInputAction.search,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.textPrimary,
              ),
              decoration: const InputDecoration(
                hintText: '搜索对话内容...',
                hintStyle: TextStyle(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                setState(() => _query = '');
                widget.onSearch('');
              },
              child: const Icon(
                Icons.cancel,
                size: 19,
                color: Color(0xFFC7C7CC),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 会话列表 ----------------

  List<Conversation> _sortedConversations() {
    final list = List<Conversation>.from(widget.conversations);
    // 只用时间排序（最近更新在前），不再提供"按标题"
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Widget _buildConversationList() {
    final list = _sortedConversations();
    if (list.isEmpty) {
      return const Center(
        child: Text('暂无对话', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    _visible = list;
    // 顶部常驻日期标签（不随列表滚动），右侧是多选按钮
    final topIndex = (_listCtrl.hasClients ? _listCtrl.offset : 0) ~/ _rowHeight;
    final labelIndex = topIndex.clamp(0, list.length - 1);
    return Column(
      children: [
        _groupHeader(_dayLabel(list[labelIndex].updatedAt), showSort: true),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (widget.hasMore &&
                  notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 120) {
                widget.onLoadMore?.call();
              }
              return false;
            },
            child: Listener(
              // 多选模式下手指划过即选中 / 再划一次取消
              onPointerDown: (e) => _onPointerDown(e.position),
              onPointerMove: (e) => _onPointerMove(e.position),
              onPointerUp: (_) => _endDrag(),
              onPointerCancel: (_) => _endDrag(),
              child: ListView.builder(
                key: _listKey,
                controller: _listCtrl,
                padding: EdgeInsets.zero,
                itemExtent: _rowHeight,
                itemCount: list.length + (widget.hasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i >= list.length) {
                    return const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  return _conversationRow(list[i]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupHeader(String label, {required bool showSort}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, showSort ? 6 : 14, 8, 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.textSecondary,
            ),
          ),
          const Spacer(),
          if (showSort) ...[
            // 多选（三根线）：与排序按钮并排放在日期行右侧
            IconButton(
              tooltip: '多选',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.menu, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => setState(() {
                _selectMode = !_selectMode;
                _selectedIds.clear();
              }),
            ),
          ],
        ],
      ),
    );
  }

  Widget _conversationRow(Conversation c) {
    final selected = c.id == widget.currentId;
    final picked = _selectedIds.contains(c.id);
    final highlighted = picked || (!_selectMode && selected);
    return InkWell(
      onTap: _selectMode
          ? () {
              if (_suppressTap) return; // 滑选起始那一下已处理
              setState(() {
                if (!_selectedIds.add(c.id)) _selectedIds.remove(c.id);
              });
            }
          : () => widget.onSelect(c),
      // 官方列表行没有删除按钮，删除走长按
      onLongPress: _selectMode ? null : () => _confirmDelete(c),
      child: Container(
        width: double.infinity,
        height: _rowHeight,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: highlighted ? AppGradients.selected : null,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            // 选中行左侧的渐变指示条
            if (highlighted && !_selectMode)
              Container(
                width: 3,
                height: 17,
                decoration: const BoxDecoration(
                  gradient: AppGradients.rail,
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(3),
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    if (_selectMode) ...[
                      Icon(
                        picked ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 18,
                        color: picked ? AppColors.brand : AppColors.textHint,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: highlighted
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: highlighted
                              ? const Color(0xFF2F47BD)
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 多选模式底部操作条：全选 / 删除 / 完成。
  Widget _buildSelectBar() {
    final all = _allCount != null && _selectedIds.length == _allCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        children: [
          TextButton(
            onPressed: () async {
              if (all) {
                setState(() {
                  _selectedIds.clear();
                  _allCount = null;
                });
                return;
              }
              // 先秒选已加载的（即时反馈），再后台补齐全量，避免点下去卡住
              setState(() {
                _selectedIds
                  ..clear()
                  ..addAll(widget.conversations.map((c) => c.id));
                _allCount = null;
              });
              final ids = await widget.onLoadAllIds?.call() ?? <int>[];
              if (!mounted) return;
              setState(() {
                _selectedIds
                  ..clear()
                  ..addAll(ids);
                _allCount = ids.length;
              });
            },
            child: Text(all ? '取消全选' : '全选'),
          ),
          const Spacer(),
          Text(
            '已选 ${_selectedIds.length}',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
            child: const Text(
              '删除',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _selectMode = false;
              _selectedIds.clear();
            }),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  void _deleteSelected() {
    final targets = [
      for (final c in widget.conversations)
        if (_selectedIds.contains(c.id)) c,
    ];
    final ids = _selectedIds.toList();
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
      _allCount = null;
    });
    // 已加载的走既有回调，未加载的按 id 删（全选场景）
    final loadedIds = {for (final c in targets) c.id};
    final rest = [for (final id in ids) if (!loadedIds.contains(id)) id];
    if (rest.isEmpty) {
      for (final c in targets) {
        widget.onDelete(c);
      }
      return;
    }
    widget.onDeleteIds?.call(ids);
  }

  void _confirmDelete(Conversation c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除「${c.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.onDelete(c);
            },
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  // ---------------- 消息级搜索 ----------------

  Widget _buildSearchResults() {
    if (_query.isEmpty) {
      return const Center(
        child: Text(
          '输入关键词，搜索全部聊天记录',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      );
    }
    if (widget.searchHits.isEmpty) {
      return const Center(
        child: Text(
          '没有找到相关结果',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      itemCount: widget.searchHits.length,
      itemBuilder: (context, i) => _hitRow(widget.searchHits[i]),
    );
  }

  Widget _hitRow(MessageHit hit) {
    final key = '${hit.conversationId}#${hit.timestamp.millisecondsSinceEpoch}';
    final cursor = (_hitCursor[key] ?? 0).clamp(0, hit.matchCount - 1);
    return InkWell(
      onTap: () => widget.onOpenHit(hit),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HitAvatar(isUser: hit.role == MessageRole.user),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          hit.conversationTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _timeLabel(hit.timestamp),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textHint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hit.matchCount > 1) ...[
                        _MatchBadge(
                          label: '${cursor + 1}/${hit.matchCount}',
                          onTap: () => setState(() {
                            _hitCursor[key] = (cursor + 1) % hit.matchCount;
                          }),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(child: _snippet(hit, cursor)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 命中片段：截取命中词前后各 14 个字符，命中词高亮。
  Widget _snippet(MessageHit hit, int cursor) {
    final start = hit.matches[cursor];
    final end = (start + _query.length).clamp(0, hit.content.length);
    const pad = 14;
    final from = (start - pad).clamp(0, hit.content.length);
    final to = (end + pad).clamp(0, hit.content.length);
    final before = hit.content.substring(from, start).replaceAll('\n', ' ');
    final matched = hit.content.substring(start, end);
    final after = hit.content.substring(end, to).replaceAll('\n', ' ');
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(
          fontSize: 13.5,
          color: AppColors.textSecondary,
          height: 1.35,
        ),
        children: [
          if (from > 0) const TextSpan(text: '…'),
          TextSpan(text: before),
          TextSpan(
            text: matched,
            style: const TextStyle(
              color: AppColors.brand,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: after),
          if (to < hit.content.length) const TextSpan(text: '…'),
        ],
      ),
    );
  }

  String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return DateFormat('M月d日').format(t);
  }

  String _timeLabel(DateTime t) {
    final now = DateTime.now();
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? DateFormat('HH:mm').format(t)
        : DateFormat('M月d日').format(t);
  }

  // ---------------- 底部账号/配置行 ----------------

  /// 底部账号/配置入口：刻意降低视觉权重（小头像 / 淡文字 / 细分隔线），
  /// 让列表成为抽屉里唯一的视觉重点。
  Widget _buildAccountRow() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x0D1F2687))),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: widget.onOpenKeyConfig,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 9, 4, 9),
                child: Row(
                  children: [
                    const WhaleAvatar(size: 28, radius: 9),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'DeepSeek API Key',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF7D8499),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _accountSubtitle(),
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppColors.textQuiet,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: Color(0xFFC6CBD8),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 设置入口：朗读音色等偏好
          InkWell(
            onTap: widget.onOpenVoiceSettings,
            customBorder: const CircleBorder(),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(8, 10, 14, 10),
              child: Icon(
                Icons.settings_outlined,
                size: 17,
                color: Color(0xFF9AA1B0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 把 API Key 掩码为 sk-第一位******最后一位；未配置时给出提示。
  String _maskKey() {
    final key = widget.apiKey;
    if (key == null || key.isEmpty) return '未配置 API Key';
    final body = key.startsWith('sk-') ? key.substring(3) : key;
    if (body.isEmpty) return '未配置 API Key';
    final first = body.substring(0, 1);
    final last = body.substring(body.length - 1);
    return 'sk-$first******$last';
  }

  /// 账号行副标题：API Key 掩码（+ 已设置的自定义模型名，按模式区分）。
  String _accountSubtitle() {
    final key = _maskKey();
    final quick = widget.quickModelOverride;
    final expert = widget.expertModelOverride;
    final quickSet = quick != null && quick.trim().isNotEmpty;
    final expertSet = expert != null && expert.trim().isNotEmpty;
    if (quickSet || expertSet) {
      final parts = <String>[];
      if (quickSet) parts.add('快速 ${quick.trim()}');
      if (expertSet) parts.add('专家 ${expert.trim()}');
      return '$key · ${parts.join(' | ')}';
    }
    return key;
  }
}

/// 搜索结果头像：直接用官方截图抠出的两张图（助手 / 带小人角标的用户）。
class _HitAvatar extends StatelessWidget {
  const _HitAvatar({required this.isUser});

  final bool isUser;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      isUser
          ? 'assets/icon_avatar_user.png'
          : 'assets/icon_avatar_assistant.png',
      width: 44,
      height: 44,
    );
  }
}

/// 同一条消息多命中的序号徽标（点击切换展示第几个命中）。
class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 1),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.thinkingBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.autorenew,
              size: 11,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
