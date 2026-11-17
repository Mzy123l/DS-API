import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/app_state.dart';
import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/storage.dart';

import 'app_state_turns_test.dart' show MemoryDb, RecordingRepository;

/// Bug3 回归：重新生成必须覆盖旧回答。
/// 根因是 _runTurnFlow 的 regenerate 分支在服务端截断后
/// 没有同步截断内存消息列表：旧回答留在界面、新回答追加在后面。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('regenerateAt 后内存列表同步截断（旧回答从界面消失）', () async {
    final db = MemoryDb();
    db.conversations[1] = Conversation(
      id: 1,
      title: '重测会话',
      model: AppMode.quick.model,
      updatedAt: DateTime.now(),
    );
    db.messages[1] = [
      ChatMessage(id: 1, role: MessageRole.user, content: '问题一'),
      ChatMessage(id: 2, role: MessageRole.assistant, content: '回答一'),
      ChatMessage(id: 3, role: MessageRole.user, content: '问题二'),
      ChatMessage(id: 4, role: MessageRole.assistant, content: '回答二'),
    ];
    final repo = RecordingRepository(db);
    final state = AppState(
      db: db,
      settings: SettingsStore(),
      repository: repo,
      // 指向不可达地址即可：没有 Key 时流程只做截断+占位，不发请求
      clientFactory: () => DeepSeekClient(baseUrl: 'http://127.0.0.1:1'),
    )..apiKey = null;
    addTearDown(state.dispose);

    await state.loadConversation(
      Conversation(
        id: 1,
        title: '重测会话',
        model: AppMode.quick.model,
        updatedAt: DateTime.now(),
      ),
    );
    expect(state.messages.length, 4);

    // 对「回答一」（下标 1）重新生成：目标消息及其后的全部内容应被替换
    await state.regenerateAt(1);

    // 无 Key：流程只做截断并提示（不会追加占位、不发起请求）。
    // 内存列表 = 截断后的 head（1 条用户消息），旧回答全部从界面消失。
    expect(state.messages.length, 1, reason: '旧回答没有被内存截断顶掉');
    expect(state.messages.first.id, 1);
    expect(state.messages.first.content, '问题一');
    // 旧回答一/回答二已从内存列表消失
    expect(
      state.messages.where((m) => m.content == '回答一'),
      isEmpty,
      reason: '回答一还留在界面上（旧 bug 现象）',
    );
    expect(state.messages.where((m) => m.content == '回答二'), isEmpty);
    // 服务端侧也已截断到 id=2 之前
    expect(repo.calls, contains('truncateBefore:2'));
    expect(db.messages[1]!.length, 1);
  });
}
