import 'package:flutter/material.dart';

import '../../prompt.dart';
import '../../theme.dart';

/// 系统提示词查看/编辑器。
///
/// 每个对话各存一份；保存空内容表示恢复默认提示词。
/// 文案保持陈述式：只说明范围与结果，不解释怎么"写好"提示词。
///
/// 面板里同时承载两个**会话级**语音开关：
/// - 语音生成工具（联网时自动忽略）
/// - 括号朗读（括号内容是否念出来）
class SystemPromptDialog extends StatefulWidget {
  const SystemPromptDialog({
    super.key,
    required this.initialPrompt,
    required this.onSave,
    this.initialAnswerBubble = false,
    this.conversationTitle,
    this.initialTtsTool = false,
    this.initialBracketSpeak = true,
  });

  final String initialPrompt;

  /// 当前对话标题；null 表示还没创建对话（保存后用于即将开始的新对话）。
  final String? conversationTitle;

  /// 当前是否开启「回答气泡」。
  final bool initialAnswerBubble;

  /// 当前会话是否启用语音生成工具。
  final bool initialTtsTool;

  /// 当前会话是否朗读括号内容。
  final bool initialBracketSpeak;

  final Future<void> Function(
    String prompt,
    bool answerBubble,
    bool ttsTool,
    bool bracketSpeak,
  )
  onSave;

  @override
  State<SystemPromptDialog> createState() => _SystemPromptDialogState();
}

class _SystemPromptDialogState extends State<SystemPromptDialog> {
  late final TextEditingController _ctrl;
  late bool _answerBubble;
  late bool _ttsTool;
  late bool _bracketSpeak;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialPrompt);
    _answerBubble = widget.initialAnswerBubble;
    _ttsTool = widget.initialTtsTool;
    _bracketSpeak = widget.initialBracketSpeak;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_ctrl.text, _answerBubble, _ttsTool, _bracketSpeak);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.conversationTitle == null
        ? '用于新对话'
        : '仅对「${widget.conversationTitle}」生效';
    // 弹窗宽度跟随屏幕，390 屏约 342，避免窄屏下按钮挤成两行
    final width = (MediaQuery.of(context).size.width - 48).clamp(280.0, 420.0);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '系统提示词',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () =>
                        setState(() => _ctrl.text = defaultSystemPrompt),
                    child: const Text(
                      '恢复默认',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                scope,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ctrl,
                minLines: 8,
                maxLines: 14,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppColors.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: '描述你希望它如何回答',
                  hintStyle: const TextStyle(color: AppColors.textHint),
                  filled: true,
                  fillColor: const Color(0xFFFBFCFE),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE3E6EE)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFE3E6EE)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppColors.brand,
                      width: 1.4,
                    ),
                  ),
                  contentPadding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: 10),
              _DialogSwitchRow(
                label: '回答气泡',
                subtitle: null,
                value: _answerBubble,
                onChanged: (v) => setState(() => _answerBubble = v),
              ),
              _DialogSwitchRow(
                label: '语音生成工具',
                subtitle: '允许模型生成音频文件（联网搜索时自动忽略）',
                value: _ttsTool,
                onChanged: (v) => setState(() => _ttsTool = v),
              ),
              _DialogSwitchRow(
                label: '朗读括号内容',
                subtitle: '关 = 朗读时跳过（小声）这类括号内容',
                value: _bracketSpeak,
                onChanged: (v) => setState(() => _bracketSpeak = v),
              ),
              const SizedBox(height: 2),
              // 底部只放操作按钮：回答气泡开关已在上面 [_DialogSwitchRow] 里，
              // 这里不再重复一份（否则同一开关出现两次、状态看着还不一致）。
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text(
                      '取消',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 2),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: _saving ? null : _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板里的一行开关：左标签（+可选说明），右小号 Switch。
class _DialogSwitchRow extends StatelessWidget {
  const _DialogSwitchRow({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final labelColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: AppColors.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 1),
          Text(
            subtitle!,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textHint,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: labelColumn),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: value,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.brand,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
