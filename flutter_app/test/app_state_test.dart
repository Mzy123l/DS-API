import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按模式自定义模型名', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未设置覆盖值时使用当前模式默认模型', () {
      final state = AppState();
      state.mode = AppMode.quick;
      expect(state.effectiveModel, AppMode.quick.model);

      state.mode = AppMode.expert;
      expect(state.effectiveModel, AppMode.expert.model);
    });

    test('快速模式设置覆盖值后优先使用，专家模式不受影响', () async {
      final state = AppState();
      state.mode = AppMode.quick;
      await state.setApiKeyAndModels(
        'sk-test123',
        'deepseek-v4-flash-vision-exp',
        null,
      );
      expect(state.effectiveModel, 'deepseek-v4-flash-vision-exp');

      state.mode = AppMode.expert;
      expect(state.effectiveModel, AppMode.expert.model);

      await state.setApiKeyAndModels('sk-test123', null, 'deepseek-v4-pro');
      state.mode = AppMode.expert;
      expect(state.effectiveModel, 'deepseek-v4-pro');
      expect(state.modelOverrideFor(AppMode.quick), isNull);
    });

    test('setApiKeyAndModels 分别写入 SharedPreferences 并可回读', () async {
      final state = AppState();
      await state.setApiKeyAndModels(
        'sk-test123',
        'deepseek-v4-flash-vision-exp',
        'deepseek-v4-pro',
      );
      expect(state.apiKey, 'sk-test123');
      expect(state.quickModelOverride, 'deepseek-v4-flash-vision-exp');
      expect(state.expertModelOverride, 'deepseek-v4-pro');

      // 通过一个全新的 SettingsStore 回读，验证确实持久化到了 SharedPreferences
      final store = SettingsStore();
      expect(await store.apiKey, 'sk-test123');
      expect(await store.modelOverrideQuick, 'deepseek-v4-flash-vision-exp');
      expect(await store.modelOverrideExpert, 'deepseek-v4-pro');
    });

    test('模型名为空时清除对应模式覆盖并回退到默认', () async {
      final state = AppState();
      await state.setApiKeyAndModels(
        'sk-test123',
        'deepseek-v4-flash-vision-exp',
        'deepseek-v4-pro',
      );
      state.mode = AppMode.expert;
      expect(state.effectiveModel, 'deepseek-v4-pro');

      await state.setApiKeyAndModels(
        'sk-test123',
        'deepseek-v4-flash-vision-exp',
        '   ',
      );
      expect(state.expertModelOverride, isNull);
      expect(state.quickModelOverride, 'deepseek-v4-flash-vision-exp');
      expect(state.effectiveModel, AppMode.expert.model);

      final store = SettingsStore();
      expect(await store.modelOverrideExpert, isNull);
      expect(await store.modelOverrideQuick, 'deepseek-v4-flash-vision-exp');
    });
  });

  group('接口协议', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('未设置时默认走 Anthropic（联网搜索/识图都可用）', () {
      final state = AppState();
      expect(state.protocol, ApiProtocol.anthropic);
      expect(ApiProtocol.fromIndex(null), ApiProtocol.anthropic);
      expect(ApiProtocol.fromIndex(99), ApiProtocol.anthropic);
      expect(ApiProtocol.fromIndex(0), ApiProtocol.responses);
    });

    test('切换协议后写入本地设置', () async {
      final state = AppState();
      await state.setProtocol(ApiProtocol.responses);
      expect(state.protocol, ApiProtocol.responses);
      expect(await SettingsStore().apiProtocol, ApiProtocol.responses.index);
    });
  });
}
