import 'package:flutter/material.dart';

/// DeepSeek 官方 App 的视觉参数（玻璃质感版）。
///
/// 品牌主色取自官方 BrandKeyColor（0xFF4D6BFE），玻璃层用半透明白 +
/// 品牌光斑，正文仍保持深色实字，保证可读性。
abstract final class AppColors {
  /// 品牌靛蓝（主题色 / 选中态）
  static const Color brand = Color(0xFF4D6BFE);

  /// 品牌深色（渐变起点）
  static const Color brandDeep = Color(0xFF3D5AF0);

  /// 品牌浅色（渐变终点）
  static const Color brandSoft = Color(0xFF7189FF);

  /// 辅助紫（渐变点缀）
  static const Color violet = Color(0xFFA57BFF);

  /// 品牌浅色底色（按钮底色 / 选中 pill 容器）
  static const Color brandTint = Color(0xFFEDF1FF);

  /// 输入框浅灰背景
  static const Color inputBg = Color(0xFFF5F5F5);

  /// 用户气泡浅靛蓝背景（旧样式，保留兼容）
  static const Color userBubble = Color(0xFFEDF1FF);

  /// 主体文本
  static const Color textPrimary = Color(0xFF1A1A1A);

  /// 次要文本（副标题 / 灰色说明）
  static const Color textSecondary = Color(0xFF9A9A9A);

  /// 引用块 / 思考区 / 行内代码的文字灰（对齐官方 App 取色）
  static const Color textQuote = Color(0xFF7E7F84);

  /// 弱次要文本（思考区灰字）
  static const Color textHint = Color(0xFFB0B0B0);

  /// 分隔线 / 边框
  static const Color border = Color(0xFFE6E6E6);

  /// 思考区灰色块背景
  static const Color thinkingBg = Color(0xFFF7F7F8);

  /// 模式选择器外层容器底
  /// 快速/专家模式选择器底色：纯白（靠描边区分轨道与页面）
  static const Color selectorBg = Colors.white;

  /// 模式选择器选中段（白色卡片）
  static const Color selectorSelected = Colors.white;

  /// 危险 / 错误
  static const Color danger = Color(0xFFE5484D);

  // ---------------- 玻璃质感扩展 ----------------

  /// 玻璃面板底色（约 62% 白）
  static const Color glass = Color(0x9EFFFFFF);

  /// 更实的玻璃（抽屉面板）
  static const Color glassStrong = Color(0xCCFFFFFF);

  /// 玻璃高光描边
  static const Color glassBorder = Color(0xDBFFFFFF);

  /// 极淡外描边，让玻璃块从白底上"浮"起来
  static const Color hairline = Color(0x0D1F2687);

  /// eyebrow 小字（空态英文标签）
  static const Color eyebrow = Color(0xFF8B95B5);

  /// 抽屉底部次要信息（降权后的账号行）
  static const Color textQuiet = Color(0xFFA5ABBD);
}

/// 渐变 token：只用在少数关键位置，避免整屏发紫。
abstract final class AppGradients {
  /// 品牌渐变（选中段 / 发送按钮）
  static const LinearGradient brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7189FF), Color(0xFF4A67FB)],
  );

  /// 标题文字渐变（深蓝 → 蓝 → 紫）
  static const LinearGradient brandText = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF3D5AF0), Color(0xFF6C84FF), Color(0xFFA57BFF)],
  );

  /// 用户气泡：柔和玻璃渐变
  static const LinearGradient userBubble = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF2FFFFFF), Color(0xE6F0F3FF), Color(0xE6F7F0FF)],
  );

  /// 助手回答气泡（开启「回答气泡」后）：
  /// 白 → 浅蓝紫 → 浅紫，和用户气泡同一套白端渐变。
  /// 方向取左上镜像：白在右上、紫在左下，和用户气泡（紫在右侧）形成呼应。
  static const LinearGradient answerBubble = LinearGradient(
    begin: Alignment.topRight,
    end: Alignment.bottomLeft,
    colors: [Color(0xFFFFFFFF), Color(0xFFF7F8FF), Color(0xFFFCF9FF)],
    stops: [0, 0.5, 1],
  );

  /// 抽屉选中行
  static const LinearGradient selected = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xF2EDF1FF), Color(0xB8F5F2FF)],
  );

  /// 选中行左侧指示条
  static const LinearGradient rail = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF6C84FF), Color(0xFFA57BFF)],
  );

  /// 输入卡/账号卡的极淡渐变光
  static const LinearGradient edge = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x66FFFFFF), Color(0x14FFFFFF)],
  );
}

/// 阴影 token：玻璃面板统一用「外描边 + 大而软的投影」。
abstract final class AppShadows {
  /// 常规玻璃卡片
  static const List<BoxShadow> glass = [
    BoxShadow(color: Color(0x0D1F2687), blurRadius: 0, spreadRadius: 1),
    BoxShadow(
      color: Color(0x401F2687),
      blurRadius: 34,
      offset: Offset(0, 14),
      spreadRadius: -22,
    ),
  ];

  /// 悬浮玻璃（输入卡）：多一层品牌蓝柔光
  static const List<BoxShadow> glassFloat = [
    BoxShadow(color: Color(0x0A1F2687), blurRadius: 0, spreadRadius: 1),
    BoxShadow(
      color: Color(0x521F2687),
      blurRadius: 48,
      offset: Offset(0, 22),
      spreadRadius: -28,
    ),
    BoxShadow(
      color: Color(0x2E6D86FF),
      blurRadius: 46,
      offset: Offset(0, 10),
      spreadRadius: -18,
    ),
  ];

  /// 圆形玻璃图标按钮
  static const List<BoxShadow> icon = [
    BoxShadow(
      color: Color(0x1A1F2687),
      blurRadius: 16,
      offset: Offset(0, 6),
      spreadRadius: -10,
    ),
  ];

  /// 输入卡：干净的一层投影，不叠品牌光晕（避免卡片发灰发脏）
  static const List<BoxShadow> input = [
    BoxShadow(color: Color(0x0D1F2687), blurRadius: 0, spreadRadius: 1),
    BoxShadow(
      color: Color(0x1F1F2687),
      blurRadius: 24,
      offset: Offset(0, 10),
      spreadRadius: -16,
    ),
  ];

  /// 用户气泡（刻意压得很淡，让助手正文成为视觉主体）
  static const List<BoxShadow> bubble = [
    BoxShadow(
      color: Color(0x0A2952D2),
      blurRadius: 18,
      offset: Offset(0, 6),
      spreadRadius: -12,
    ),
  ];
}

abstract final class AppDimens {
  static const double pagePadding = 16;
  static const double corner = 14;
  static const double bubbleCorner = 20;
  static const double controlHeight = 44;
  static const double inputCorner = 26;
}

/// 全局字体（跟随系统 sans-serif，深色/浅色一致）
TextStyle _baseText(
  double size,
  Color color, {
  FontWeight weight = FontWeight.w400,
}) => TextStyle(fontSize: size, color: color, fontWeight: weight, height: 1.45);

ThemeData buildLightTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.white,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.light,
      primary: AppColors.brand,
      surface: Colors.white,
    ),
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      bodyMedium: _baseText(15, AppColors.textPrimary),
      bodyLarge: _baseText(16, AppColors.textPrimary),
      titleMedium: _baseText(17, AppColors.textPrimary, weight: FontWeight.w600),
      titleLarge: _baseText(20, AppColors.textPrimary, weight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: _baseText(17, AppColors.textPrimary, weight: FontWeight.w600),
      iconTheme: const IconThemeData(color: AppColors.textPrimary),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1, space: 1),
    inputDecorationTheme: const InputDecorationTheme(border: InputBorder.none),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.brand,
      selectionColor: Color(0x334D6BFE),
      selectionHandleColor: AppColors.brand,
    ),
  );
}

ThemeData buildDarkTheme() {
  // 官方 App 深色模式：以近黑为底、品牌色提亮。本轮优先保障浅色（默认）还原。
  const bg = Color(0xFF151517);
  const surface = Color(0xFF1E1E22);
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: Brightness.dark,
      primary: const Color(0xFF7C8DFF),
      surface: surface,
    ),
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: _baseText(17, Colors.white, weight: FontWeight.w600),
    ),
  );
}
