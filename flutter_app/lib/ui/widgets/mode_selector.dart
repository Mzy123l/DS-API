import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme.dart';

/// 首页「快速 / 专家」模式选择器：玻璃轨道 + 白色滑块（iOS 分段控件质感）。
///
/// 选中段不再用高饱和渐变和蓝色光晕——白色实底 + 品牌色文字 + 极轻投影，
/// 比"渐变按钮"克制得多，也不会抢空态标题的视觉。
class ModeSelector extends StatelessWidget {
  const ModeSelector({super.key, required this.mode, required this.onChanged});

  final AppMode mode;
  final ValueChanged<AppMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.85)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A1F2687),
            blurRadius: 18,
            offset: Offset(0, 8),
            spreadRadius: -14,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Segment(
            m: AppMode.quick,
            selected: mode == AppMode.quick,
            onTap: () => onChanged(AppMode.quick),
          ),
          _Segment(
            m: AppMode.expert,
            selected: mode == AppMode.expert,
            onTap: () => onChanged(AppMode.expert),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.m, required this.selected, required this.onTap});

  final AppMode m;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.brand : const Color(0xFF8A91A5);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x141F2687),
                    blurRadius: 10,
                    offset: Offset(0, 3),
                    spreadRadius: -2,
                  ),
                  BoxShadow(
                    color: Color(0x0D1F2687),
                    blurRadius: 2,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(m), size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              m.label,
              style: TextStyle(
                color: color,
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _icon(AppMode m) =>
      m.icon == 'diamond' ? Icons.diamond_outlined : Icons.bolt;
}
