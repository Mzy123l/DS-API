import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/storage.dart';

/// 输入区开关（快速/专家模式、深度思考、智能搜索、推理强度）的刷新回归。
///
/// 根因（重构拆分引入）：这四个开关都落在 `SettingsController` 上，它变化时
/// 只通知自己的监听者；而 root_shell 用 `context.watch<AppState>()` 订阅 UI，
/// AppState 没有转发 settingsCtl 的通知，于是「按下开关不刷新，点一下别处
/// 才更新」。
///
/// 本测试固化两个不变量：
/// 1. 设置项一变，AppState 必须通知监听者（界面才会重建）；
/// 2. 通知发生在写磁盘**之前**（点击当帧就刷新，不等 SharedPreferences）。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('深度思考 / 智能搜索 / 推理强度 / 模式 变化都会通知 AppState', () async {
    final state = AppState(settings: SettingsStore());
    addTearDown(state.dispose);

    var notified = 0;
    state.addListener(() => notified++);

    await state.setDeepThink(false);
    expect(state.deepThink, isFalse);
    expect(notified, greaterThan(0), reason: '深度思考开关没有传到界面');

    var before = notified;
    await state.setWebSearch(true);
    expect(state.webSearch, isTrue);
    expect(notified, greaterThan(before), reason: '智能搜索开关没有传到界面');

    before = notified;
    await state.setReasoningEffort('max');
    expect(state.reasoningEffort, 'max');
    expect(notified, greaterThan(before), reason: '推理强度没有传到界面');

    before = notified;
    await state.setMode(AppMode.expert);
    expect(state.mode, AppMode.expert);
    expect(notified, greaterThan(before), reason: '快速/专家模式没有传到界面');
  });

  test('通知先于落盘：点击当帧就刷新，不等 SharedPreferences 写完', () {
    final state = AppState(settings: SettingsStore());
    addTearDown(state.dispose);

    var notified = 0;
    state.addListener(() => notified++);

    // 故意不 await：模拟点击那一刻。值必须已经改好、通知已经发出。
    state.setDeepThink(false);
    expect(state.deepThink, isFalse, reason: '状态没有立即更新');
    expect(notified, greaterThan(0), reason: '通知没有立即发出（界面要等落盘）');

    state.setWebSearch(true);
    expect(state.webSearch, isTrue);

    state.setReasoningEffort('low');
    expect(state.reasoningEffort, 'low');

    state.setMode(AppMode.expert);
    expect(state.mode, AppMode.expert);
  });
}
