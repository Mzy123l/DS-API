import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 品牌氛围背景：顶部两团柔光 + 底部一点冷光。
///
/// 放在 Scaffold body 最底层；上层内容必须是透明背景，光斑才能透出来。
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF6F9FF), Color(0xFFFDFDFF), Colors.white],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
        Positioned(
          left: -150,
          top: -190,
          child: _glow(470, const Color(0xFF7890FF), 0.28),
        ),
        Positioned(
          right: -170,
          top: -160,
          child: _glow(440, const Color(0xFFC08CFF), 0.16),
        ),
        Positioned(
          left: -150,
          bottom: 40,
          child: _glow(380, const Color(0xFF7DD3FC), 0.05),
        ),
        Positioned(
          right: -140,
          bottom: -120,
          child: _glow(400, const Color(0xFF7890FF), 0.05),
        ),
      ],
    );
  }

  Widget _glow(double size, Color color, double opacity) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// 磨砂玻璃面板：半透明白 + 背景模糊 + 1px 白色高光描边 + 柔和投影。
///
/// 只给"停得住"的控件使用（输入卡 / 空态 Logo 托 / 抽屉）；
/// 长列表里的气泡用 [AppGradients.userBubble] 模拟，避免逐条 blur 掉帧。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = AppDimens.inputCorner,
    this.padding = EdgeInsets.zero,
    this.blur = 20,
    this.tint = AppColors.glass,
    this.borderColor = AppColors.glassBorder,
    this.shadows = AppShadows.glass,
    this.margin,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double blur;
  final Color tint;
  final Color borderColor;
  final List<BoxShadow> shadows;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      margin: margin,
      decoration: BoxDecoration(borderRadius: borderRadius, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 右上角圆形玻璃图标按钮（取代方形的 IconButton 底）。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.child,
    required this.onTap,
    this.size = 36,
    this.tooltip,
    this.tint,
  });

  final Widget child;
  final VoidCallback onTap;
  final double size;
  final String? tooltip;

  /// 自定义底色（例如开关类按钮的开启态）；为空时用默认玻璃白
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final button = GlassPanel(
      radius: size / 2,
      blur: 12,
      tint: tint ?? const Color(0x8CFFFFFF),
      borderColor: AppColors.glassBorder,
      shadows: AppShadows.icon,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: tooltip,
      child: tooltip == null
          ? button
          : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// 品牌渐变文字（ShaderMask 裁切）。
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    required this.style,
    this.gradient = AppGradients.brandText,
  });

  final String text;
  final TextStyle style;
  final LinearGradient gradient;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) =>
          gradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Text(text, style: style),
    );
  }
}
