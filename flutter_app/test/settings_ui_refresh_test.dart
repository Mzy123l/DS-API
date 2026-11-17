import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/storage.dart';
import 'package:ds_api/theme.dart';
import 'package:ds_api/ui/root_shell.dart';

/// 界面级回归：挂真实 HomeBody（内部 `context.watch<AppState>()`），
/// 点一下开关只 pump 一帧就必须看到状态变化。
///
/// 旧行为：按下「深度思考 / 智能搜索 / 推理强度 / 快速-专家」后界面不动，
/// 得点一下别处（触发别的 notifyListeners）才刷新。根因是 AppState 没有
/// 订阅 SettingsController 的通知。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 挂载真实主页（空态：Logo + 模式选择 + 输入区）。
  Future<AppState> pumpHome(WidgetTester tester) async {
    final state = AppState(settings: SettingsStore());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: HomeBody(
              onOpenHistory: () {},
              onNewChat: () {},
              onOpenSystemPrompt: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return state;
  }

  /// 输入区 pill 的文字颜色 = 激活态（AppColors.brand 表示已开启）。
  Color? pillColor(WidgetTester tester, String label) =>
      tester.widget<Text>(find.text(label)).style?.color;

  testWidgets('点「深度思考」：一帧内 pill 立刻变激活色', (tester) async {
    final state = await pumpHome(tester);
    final initial = state.deepThink;
    expect(pillColor(tester, '深度思考'), initial ? AppColors.brand : isNotNull);

    await tester.tap(find.text('深度思考'));
    // 只 pump 一帧：修复前这里还是旧颜色（要等别的通知才刷新）
    await tester.pump();

    expect(state.deepThink, !initial);
    expect(
      pillColor(tester, '深度思考'),
      state.deepThink ? AppColors.brand : isNot(AppColors.brand),
      reason: '按下深度思考后界面没有立即刷新',
    );
  });

  testWidgets('点「智能搜索」：一帧内 pill 立刻变激活色', (tester) async {
    final state = await pumpHome(tester);
    final initial = state.webSearch;

    await tester.tap(find.text('智能搜索'));
    await tester.pump();

    expect(state.webSearch, !initial);
    expect(
      pillColor(tester, '智能搜索'),
      state.webSearch ? AppColors.brand : isNot(AppColors.brand),
      reason: '按下智能搜索后界面没有立即刷新',
    );
  });

  testWidgets('切「专家模式」：一帧内模式选择器与副标题立刻更新', (tester) async {
    final state = await pumpHome(tester);
    expect(state.mode, AppMode.quick);
    expect(find.text(AppMode.quick.subtitle), findsOneWidget);

    await tester.tap(find.text(AppMode.expert.label));
    await tester.pump();

    expect(state.mode, AppMode.expert);
    expect(
      find.text(AppMode.expert.subtitle),
      findsOneWidget,
      reason: '切到专家模式后副标题没有立即刷新',
    );
    // 选中态：专家段文字用品牌色
    expect(pillColor(tester, AppMode.expert.label), AppColors.brand);
  });

  testWidgets('切推理强度：菜单选项生效后 pill 立刻显示新值', (tester) async {
    final state = await pumpHome(tester);
    expect(state.reasoningEffort, defaultReasoningEffort);

    // 打开强度菜单，选 max
    await tester.tap(find.text(state.reasoningEffort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('max').last);
    // 只 pump 一帧（菜单还在收起动画里，所以按字号区分 pill 自己的文字）
    await tester.pump();

    expect(state.reasoningEffort, 'max');
    expect(
      effortPillTexts(tester, 'max'),
      1,
      reason: '推理强度 pill 没有立即显示新值',
    );
    expect(effortPillTexts(tester, defaultReasoningEffort), 0);
  });
}

/// 推理强度 pill 自己的文字（字号 12.5；菜单项是 14）。
int effortPillTexts(WidgetTester tester, String text) => tester
    .widgetList<Text>(find.text(text))
    .where((t) => t.style?.fontSize == 12.5)
    .length;
