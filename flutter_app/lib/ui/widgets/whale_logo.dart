import 'package:flutter/material.dart';

/// DeepSeek 官方鲸鱼 Logo（白色圆角方块 + 蓝鲸，与启动图标一致）。
class WhaleLogo extends StatelessWidget {
  const WhaleLogo({super.key, this.size = 56, this.corner = 16});

  final double size;
  final double corner;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(corner),
      child: Image.asset(
        'assets/icon_app.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}

/// 用户头像：小鲸鱼（白底蓝鲸，圆角小方块）。
class WhaleAvatar extends StatelessWidget {
  const WhaleAvatar({super.key, this.size = 32, this.radius = 9});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.asset(
        'assets/icon_app.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
