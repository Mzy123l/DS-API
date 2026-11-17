import 'package:flutter/material.dart';

import '../../speech.dart';
import '../../theme.dart';

/// 设置页：语音缓存管理。
///
/// 音色目前固定为官方默认的「海星」，UI 不提供切换（底层 [TtsVoice]
/// 已按多值设计，后续官方开放新音色时只需在数据层加一项）。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.speech});

  /// 语音服务（清空缓存用）；为空时不显示该入口
  final SpeechService? speech;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool _clearing = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '朗读音色',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              '当前使用官方默认音色「海星」',
              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
            ),
            if (widget.speech != null) ...[
              const Divider(height: 22),
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '语音缓存',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '生成过的音频存在本地，重复播放不再消耗额度',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _clearing ? null : _clearCache,
                    child: Text(_clearing ? '清理中…' : '清空'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }

  Future<void> _clearCache() async {
    final speech = widget.speech;
    if (speech == null) return;
    setState(() => _clearing = true);
    final removed = await speech.clearCache();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已清理 $removed 个语音缓存文件')),
    );
  }
}
