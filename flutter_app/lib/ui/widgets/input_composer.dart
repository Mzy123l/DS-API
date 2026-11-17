import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../models.dart';
import '../../storage.dart';
import '../../theme.dart';
import '../../gallery.dart';

/// 底部输入区：附件（相册/拍照/文件）+ 输入框 + 深度思考/智能搜索。
class InputComposer extends StatefulWidget {
  const InputComposer({
    super.key,
    required this.onSend,
    required this.deepThink,
    required this.webSearch,
    required this.reasoningEffort,
    required this.onDeepThinkChanged,
    required this.onWebSearchChanged,
    required this.onEffortChanged,
    required this.onNotice,
    this.onStartVoice,
    this.onStopVoice,
    this.onCancelVoice,
    this.editing = false,
    this.editingText = '',
    this.editingImages = const [],
    this.editingFiles = const [],
    this.onCancelEdit,
    this.onCommitEdit,
  });

  final void Function(String text, List<Attachment> attachments) onSend;
  final bool deepThink;
  final bool webSearch;
  final String reasoningEffort;
  final ValueChanged<bool> onDeepThinkChanged;
  final ValueChanged<bool> onWebSearchChanged;
  final ValueChanged<String> onEffortChanged;
  final void Function(String) onNotice;

  /// 按住说话：开始录音（返回是否真的开始了）
  final Future<bool> Function()? onStartVoice;

  /// 松手：结束录音并转写，返回识别文本
  final Future<String?> Function()? onStopVoice;

  /// 取消录音
  final Future<void> Function()? onCancelVoice;

  /// 是否处于“修改输入”编辑态（点击历史用户消息触发）。
  final bool editing;
  final String editingText;

  /// 编辑态下该消息已有的图片（重新编辑时也要能看到）
  final List<String> editingImages;

  /// 编辑态下该消息已有的文件（重新编辑时以卡片形式带回输入区）
  final List<Attachment> editingFiles;
  final VoidCallback? onCancelEdit;
  final void Function(String text, List<Attachment> attachments)? onCommitEdit;

  @override
  State<InputComposer> createState() => _InputComposerState();
}

class _InputComposerState extends State<InputComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _picker = ImagePicker();
  final List<Attachment> _attachments = [];
  bool _attachmentsExpanded = false;

  /// “+”面板顶部的最近图片（可左右滑动）
  List<RecentImage> _recentImages = [];
  bool _galleryLoaded = false;
  bool _galleryDenied = false;
  final Set<String> _selectedAssetIds = {};

  bool get _hasText => _controller.text.trim().isNotEmpty;

  /// 是否正在录音（按住说话）
  bool _recording = false;

  /// 录音期间用户滑走/取消
  bool _voiceCanceled = false;

  /// 开始录音（按住说话）。
  Future<void> _beginVoice() async {
    final start = widget.onStartVoice;
    if (start == null) {
      widget.onNotice('语音功能暂不可用');
      return;
    }
    if (_hasText) {
      widget.onNotice('请先清空输入框再按住说话');
      return;
    }
    final ok = await start();
    if (!ok || !mounted) return;
    setState(() {
      _recording = true;
      _voiceCanceled = false;
    });
    HapticFeedback.mediumImpact();
  }

  /// 松手：结束录音并转写，把文字填进输入框。
  Future<void> _endVoice() async {
    if (!_recording) return;
    final canceled = _voiceCanceled;
    setState(() => _recording = false);
    if (canceled) {
      await widget.onCancelVoice?.call();
      return;
    }
    final stop = widget.onStopVoice;
    if (stop == null) return;
    final text = await stop();
    if (!mounted || text == null || text.isEmpty) return;
    // 追加到已有文字后面，不覆盖用户已经打好的内容
    final current = _controller.text.trim();
    _controller.text = current.isEmpty ? text : '$current $text';
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    setState(() {});
  }

  /// 录音中往上滑取消。
  void _cancelVoiceByDrag() {
    if (!_recording) return;
    setState(() => _voiceCanceled = true);
    HapticFeedback.lightImpact();
  }

  @override
  void initState() {
    super.initState();
    // “+”附件面板默认收起（与官方一致，展开才显示拍照/相册/文件）
    _attachmentsExpanded = false;
    // 相册内容变化时刷新“+”面板里的最近图片（Android 走 ContentObserver）
    try {
      PhotoManager.addChangeCallback(_onGalleryChanged);
      PhotoManager.startChangeNotify();
    } catch (_) {
      // 桌面/网页等平台没有相册通知，忽略
    }
  }

  @override
  void dispose() {
    try {
      PhotoManager.stopChangeNotify();
      PhotoManager.removeChangeCallback(_onGalleryChanged);
    } catch (_) {
      // 忽略不支持的平台
    }
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 相册里的图片增删/修改后：面板正展开时立即刷新最近图片。
  void _onGalleryChanged(MethodCall call) {
    if (!mounted || !_attachmentsExpanded) return;
    _ensureRecentImages(force: true);
  }

  @override
  void didUpdateWidget(InputComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入编辑态：把目标消息内容带入输入框并拉起键盘；退出编辑态：清空输入。
    if (widget.editing && !oldWidget.editing) {
      _controller.text = widget.editingText;
      // 把该消息已有的图片放回附件区，编辑时能看到、也能继续带着发
      _attachments
        ..clear()
        ..addAll([
          for (final url in widget.editingImages)
            Attachment(path: 'history-image', dataUrl: url),
          ...widget.editingFiles,
        ]);
      _focus.requestFocus();
    } else if (!widget.editing && oldWidget.editing) {
      _controller.clear();
      _attachments.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    }
  }

  void _send() {
    final text = _controller.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    if (widget.editing) {
      // 必须传拷贝：下面马上会清空 _attachments，而 editUserMessage 是异步的
      // （第一次 await 之后才读附件），直接传引用会让文件/图片全丢。
      widget.onCommitEdit?.call(text, List.of(_attachments));
      _controller.clear();
      setState(() {
        _attachments.clear();
        _selectedAssetIds.clear();
        _attachmentsExpanded = false;
        // 下次展开时重新读相册
        _galleryLoaded = false;
      });
      return;
    }
    widget.onSend(text, List.of(_attachments));
    _controller.clear();
    // 发送后自动收回“+”附件菜单、撤下已选图片/文件
    setState(() {
      _attachments.clear();
      _selectedAssetIds.clear();
      _attachmentsExpanded = false;
      _galleryLoaded = false;
    });
  }

  /// 读取最近图片（[force] 为 true 时忽略缓存，重新扫相册）。
  ///
  /// “+”面板每次展开都强制刷新，相册里新增/删除的图片能立刻反映出来。
  Future<void> _ensureRecentImages({bool force = false}) async {
    if (_galleryLoaded && !force) return;
    _galleryLoaded = true;
    try {
      final result = await loadRecentImages();
      if (!mounted) return;
      setState(() {
        _recentImages = result.images;
        _galleryDenied = result.denied;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _galleryDenied = true);
    }
  }

  /// 点击最近图片：选中则加入待发送附件，再次点击取消。
  Future<void> _toggleRecentImage(RecentImage image) async {
    final path = 'asset:${image.id}';
    if (_selectedAssetIds.contains(image.id)) {
      setState(() {
        _selectedAssetIds.remove(image.id);
        _attachments.removeWhere((a) => a.path == path);
      });
      return;
    }
    final att = await attachmentFromAsset(image.asset);
    if (!mounted) return;
    if (att == null) {
      widget.onNotice('这张图片读取失败，请换一张');
      return;
    }
    setState(() {
      _selectedAssetIds.add(image.id);
      _attachments.add(att);
    });
  }

  Future<void> _pick(AttachmentSource source) async {
    try {
      String? path;
      if (source == AttachmentSource.gallery) {
        final file = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        path = file?.path;
      } else if (source == AttachmentSource.camera) {
        final file = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
        );
        path = file?.path;
      } else {
        final files = await FilePicker.pickFiles(type: FileType.any);
        path = files.isNotEmpty ? files.single.path : null;
      }
      if (path == null) return;
      final att = await loadFileAttachment(path);
      if (att == null) {
        widget.onNotice(
          looksLikeImagePath(path)
              ? '这张图片的格式暂不支持（仅支持 JPG/PNG/GIF/WebP），请换一张或先转成 JPG'
              : '暂不支持此类文件，请选择 PDF / Word / PPT / 文本文件或图片',
        );
        return;
      }
      // 选完文件/图片后自动收起右下角“+”面板（官方同款行为）
      setState(() {
        _attachments.add(att);
        _attachmentsExpanded = false;
      });
      if (att.isDocument) {
        widget.onNotice('发送时会先上传并解析「${att.fileName}」');
      }
    } catch (e) {
      widget.onNotice('选择文件失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final showAttach = _attachmentsExpanded;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_attachments.isNotEmpty) ...[
              _AttachmentPreview(
                attachments: _attachments,
                onRemove: (i) => setState(() {
                  final removed = _attachments.removeAt(i);
                  if (removed.path.startsWith('asset:')) {
                    _selectedAssetIds.remove(
                      removed.path.substring('asset:'.length),
                    );
                  }
                }),
              ),
              const SizedBox(height: 8),
            ],
            if (widget.editing) ...[
              _EditModeBar(onCancel: widget.onCancelEdit),
              const SizedBox(height: 6),
            ],
            // 输入卡片：输入框 + 底部功能行（官方为同一张圆角描边卡片）
            _buildInputCard(showAttach),
            // “+”展开后：拍照 / 相册 / 文件 三个大按钮（官方在输入框下方）
            if (showAttach) ...[
              const SizedBox(height: 10),
              _RecentImagesStrip(
                images: _recentImages,
                denied: _galleryDenied,
                selectedIds: _selectedAssetIds,
                onToggle: _toggleRecentImage,
                onRetry: () async {
                  await openGallerySettings();
                  if (!mounted) return;
                  setState(() {
                    _galleryLoaded = false;
                    _galleryDenied = false;
                  });
                  await _ensureRecentImages();
                },
              ),
              _AttachmentPanel(onPick: _pick),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInputCard(bool showAttach) {
    // 纯白卡 + 1px 浅灰边 + 一层极轻投影：不再用磨砂/白描边叠灰
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppDimens.inputCorner),
        border: Border.all(color: const Color(0xFFEDEFF5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            focusNode: _focus,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            style: const TextStyle(fontSize: 16, color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: '发消息或按住说话',
              hintStyle: TextStyle(fontSize: 16, color: Color(0xFF9AA1B0)),
              border: InputBorder.none,
              isCollapsed: true,
              contentPadding: EdgeInsets.symmetric(vertical: 6),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          _buildBottomRow(showAttach),
        ],
      ),
    );
  }

  Widget _buildBottomRow(bool showAttach) {
    return Row(
      children: [
        // 左侧功能 pill：窄屏时整体等比缩小，避免与右侧按钮互相遮挡
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _FeaturePill(
                  icon: Icons.auto_awesome_outlined,
                  label: '深度思考',
                  active: widget.deepThink,
                  onTap: () => widget.onDeepThinkChanged(!widget.deepThink),
                ),
                const SizedBox(width: 8),
                _FeaturePill(
                  icon: Icons.public,
                  label: '智能搜索',
                  active: widget.webSearch,
                  onTap: () => widget.onWebSearchChanged(!widget.webSearch),
                ),
                const SizedBox(width: 8),
                _EffortPill(
                  effort: widget.reasoningEffort,
                  onChanged: widget.onEffortChanged,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _CircleButton(
          icon: showAttach ? Icons.close : Icons.add,
          size: 23,
          onTap: () {
            final next = !_attachmentsExpanded;
            setState(() => _attachmentsExpanded = next);
            if (next) _ensureRecentImages(force: true);
          },
        ),
        const SizedBox(width: 14),
        if (_hasText)
          _CircleButton(
            icon: Icons.arrow_upward,
            size: 23,
            filled: true,
            onTap: _send,
          )
        else
          // 按住说话：录音 → 官方 ASR 接口转文字 → 填进输入框
          GestureDetector(
            onLongPressStart: (_) => _beginVoice(),
            onLongPressEnd: (_) => _endVoice(),
            onLongPressMoveUpdate: (d) {
              // 往上滑取消录音（与常见语音输入手势一致）
              if (d.localOffsetFromOrigin.dy < -60) _cancelVoiceByDrag();
            },
            child: _CircleButton(
              icon: _recording ? Icons.mic : Icons.mic_none,
              size: 23,
              filled: _recording,
              onTap: null,
            ),
          ),
      ],
    );
  }
}

/// “修改输入”顶栏：左侧标签 + 右侧关闭按钮。
class _EditModeBar extends StatelessWidget {
  const _EditModeBar({required this.onCancel});

  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          '修改输入',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const Spacer(),
        InkWell(
          onTap: onCancel,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 18, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

enum AttachmentSource { gallery, camera, file }

/// “+”展开后的附件面板：拍照 / 相册 / 文件 三个等宽大按钮（官方样式）。
class _RecentImagesStrip extends StatelessWidget {
  const _RecentImagesStrip({
    required this.images,
    required this.denied,
    required this.selectedIds,
    required this.onToggle,
    required this.onRetry,
  });

  final List<RecentImage> images;
  final bool denied;
  final Set<String> selectedIds;
  final void Function(RecentImage) onToggle;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      if (!denied) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '未授权访问相册，最近图片不可用',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: const Text('去授权', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        SizedBox(
          height: 74,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: images.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _thumb(images[i]),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _thumb(RecentImage img) {
    final selected = selectedIds.contains(img.id);
    return GestureDetector(
      onTap: () => onToggle(img),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 74,
              height: 74,
              child: img.thumb == null
                  ? const ColoredBox(color: AppColors.thinkingBg)
                  : Image.memory(
                      img.thumb!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.brand
                    : Colors.white.withValues(alpha: 0.8),
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.brand : Colors.white,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 13, color: Colors.white)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// “+”展开后的附件面板：拍照 / 相册 / 文件 三个等宽大按钮（官方样式）。
/// 上方为 [_RecentImagesStrip]（最近图片，可左右滑动并多选）。
class _AttachmentPanel extends StatelessWidget {
  const _AttachmentPanel({required this.onPick});

  final void Function(AttachmentSource) onPick;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _BigAttachmentButton(
            icon: Icons.photo_camera_outlined,
            label: '拍照',
            onTap: () => onPick(AttachmentSource.camera),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _BigAttachmentButton(
            icon: Icons.image_outlined,
            label: '相册',
            onTap: () => onPick(AttachmentSource.gallery),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _BigAttachmentButton(
            icon: Icons.attach_file,
            label: '文件',
            onTap: () => onPick(AttachmentSource.file),
          ),
        ),
      ],
    );
  }
}

class _BigAttachmentButton extends StatelessWidget {
  const _BigAttachmentButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 92,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEDEFF5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: AppColors.textPrimary),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({required this.attachments, required this.onRemove});

  final List<Attachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final att = attachments[i];
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: att.isImage
                    ? _memoryImage(att.dataUrl, 64)
                    : _FileThumb(name: att.fileName),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () => onRemove(i),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 非图片文件的缩略预览：文件图标 + 文件名。
class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.inputBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.insert_drive_file_outlined,
            size: 22,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 2),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.brand : const Color(0xFF6E7689);
    return InkWell(
      onTap: onTap,
      customBorder: const StadiumBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          // 描边式：白卡上不再出现灰色实心胶囊
          color: active ? AppColors.brandTint : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: active
                ? AppColors.brand.withValues(alpha: 0.22)
                : const Color(0xFFE7EAF2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: color,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 推理强度选择：点击弹出 low / high / max，对应 reasoning_effort。
class _EffortPill extends StatelessWidget {
  const _EffortPill({required this.effort, required this.onChanged});

  final String effort;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '推理强度',
      initialValue: effort,
      onSelected: onChanged,
      color: Colors.white,
      elevation: 4,
      offset: const Offset(0, 0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        for (final e in reasoningEfforts)
          PopupMenuItem<String>(
            value: e,
            child: Row(
              children: [
                if (e == effort) ...[
                  const Icon(Icons.check, size: 16, color: AppColors.brand),
                  const SizedBox(width: 8),
                ],
                Text(
                  e,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFFE7EAF2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune, size: 15, color: Color(0xFF6E7689)),
            const SizedBox(width: 4),
            Text(
              effort,
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF6E7689),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.size = 23,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: filled ? AppGradients.brand : null,
          shape: BoxShape.circle,
          border: filled
              ? null
              : Border.all(color: const Color(0xFFDCE0EA), width: 1.2),
          boxShadow: filled
              ? [
                  BoxShadow(
                    color: AppColors.brand.withValues(alpha: 0.35),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                    spreadRadius: -6,
                  ),
                ]
              : null,
        ),
        child: Icon(
          icon,
          size: filled ? 16 : 17,
          color: filled ? Colors.white : AppColors.textPrimary,
        ),
      ),
    );
  }
}

/// 从 data URL 渲染图片（本地文件与相册资源统一走这里，避免依赖 content:// 路径）。
Widget _memoryImage(String dataUrl, double size) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return const SizedBox.shrink();
  try {
    return Image.memory(
      base64Decode(dataUrl.substring(comma + 1)),
      width: size,
      height: size,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => SizedBox(
        width: size,
        height: size,
        child: const ColoredBox(color: AppColors.thinkingBg),
      ),
    );
  } catch (_) {
    return const SizedBox.shrink();
  }
}
