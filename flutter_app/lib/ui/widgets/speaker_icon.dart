import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 官方同款喇叭图标：喇叭主体 + 两道声波弧。
///
/// Material 的 `volume_up_outlined` 线条偏粗、比例偏小，和官方客户端
/// 右上角的喇叭对不上，所以这里按 24x24 坐标系手绘一份。
///
/// 抽成公共组件的原因：右上角顶栏与本地预览页都要用同一个图标，
/// 避免预览和真实界面各画一套、验收时看的不是真实效果。
class SpeakerIcon extends StatelessWidget {
  const SpeakerIcon({
    super.key,
    this.size = 20,
    this.color = const Color(0xFF1A1A1A),
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SpeakerPainter(color: color)),
    );
  }
}

class _SpeakerPainter extends CustomPainter {
  const _SpeakerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 按 24x24 的图标坐标系绘制，再等比缩放到实际尺寸
    final s = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 喇叭主体：左侧矩形 + 向右张开的锥形（闭合轮廓）
    final body = Path()
      ..moveTo(11 * s, 5 * s)
      ..lineTo(6 * s, 9 * s)
      ..lineTo(2 * s, 9 * s)
      ..lineTo(2 * s, 15 * s)
      ..lineTo(6 * s, 15 * s)
      ..lineTo(11 * s, 19 * s)
      ..close();
    canvas.drawPath(body, paint);

    // 两道声波弧：从喇叭口向右张开（-60° 到 +60°）
    final center = Offset(11 * s, 12 * s);
    canvas.drawArc(
      Rect.fromCenter(center: center, width: 9 * s, height: 11 * s),
      -math.pi / 3,
      math.pi * 2 / 3,
      false,
      paint,
    );
    canvas.drawArc(
      Rect.fromCenter(center: center, width: 17 * s, height: 19 * s),
      -math.pi / 3,
      math.pi * 2 / 3,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_SpeakerPainter oldDelegate) =>
      oldDelegate.color != color;
}
