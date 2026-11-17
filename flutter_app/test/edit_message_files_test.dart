import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';

import 'app_state_turns_test.dart'
    show FakeUpstream, MemoryDb, buildState, waitFor;

/// 回归：带文件的消息「重新编辑 → 再发送」后文件丢失。
///
/// 这一层固化的是编辑流程本身：编辑时带上的附件必须进入新落库的那条消息，
/// 并且要出现在发给模型的请求体里。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('编辑带文件的消息：文件进入新消息，并出现在请求体里', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    // 先发一条带文本文件的消息
    await state.send(
      '帮我总结',
      attachments: const [
        Attachment(
          path: 'notes.txt',
          dataUrl: 'data:text/plain;base64,',
          textContent: '文件内容第一行',
          sizeBytes: 21,
        ),
      ],
    );
    final convId = state.currentConversationId!;
    await waitFor(() => upstream.lastBody != null, reason: '首轮请求没有发出');
    expect(
      upstream.lastBody,
      contains('文件内容第一行'),
      reason: '首轮就应该把文件内容发给模型',
    );

    // 让首轮跑完
    upstream.gates.first.complete();
    await waitFor(() => !state.busy, reason: '首轮没有收尾');

    // 编辑该用户消息，并带上同一个文件（真实入口：输入区回填后再次发送）
    final userIndex = state.messages.indexWhere(
      (m) => m.role == MessageRole.user,
    );
    expect(userIndex, 0);
    await state.editUserMessage(
      userIndex,
      '帮我总结一下重点',
      attachments: const [
        Attachment(
          path: 'notes.txt',
          dataUrl: 'data:text/plain;base64,',
          textContent: '文件内容第一行',
          sizeBytes: 21,
        ),
      ],
    );
    await waitFor(
      () => upstream.lastBody?.contains('帮我总结一下重点') == true,
      reason: '编辑后的请求没有发出',
    );

    // 1) 请求体里仍然带着文件内容（文件没丢）
    expect(
      upstream.lastBody,
      contains('文件内容第一行'),
      reason: '编辑再发送后文件内容没有进入请求（旧 bug：文件丢失）',
    );
    // 请求体是 JSON，引号被转义，这里按内容块核对
    expect(upstream.lastBody, contains('file name='));
    expect(upstream.lastBody, contains('notes.txt'));

    // 2) 落库的新消息里也保留了结构化文件
    final saved = await db.loadMessages(convId);
    final edited = saved.firstWhere(
      (m) => m.role == MessageRole.user && m.content == '帮我总结一下重点',
    );
    expect(edited.files, isNotEmpty, reason: '编辑后的消息丢了结构化文件');
    expect(edited.files.first.name, 'notes.txt');
    expect(edited.files.first.text, '文件内容第一行');
    // 正文保持干净，不把文件内容拼进正文
    expect(edited.content.contains('文件内容第一行'), isFalse);

    // 3) 界面上的消息同样带文件
    final viewMsg = state.messages.firstWhere(
      (m) => m.role == MessageRole.user && m.content == '帮我总结一下重点',
    );
    expect(viewMsg.files, isNotEmpty);

    upstream.gates.last.complete();
    await waitFor(() => !state.busy, reason: '编辑轮没有收尾');
  });

  test('编辑后正文里不出现 【文件：…】 旧标记', () async {
    final upstream = FakeUpstream();
    await upstream.start();
    final db = MemoryDb();
    final state = buildState(
      db: db,
      clientFactory: () =>
          DeepSeekClient(baseUrl: upstream.baseUrl, client: http.Client()),
    );
    addTearDown(() async {
      state.dispose();
      await upstream.stop();
    });

    await state.send('原始提问');
    await waitFor(() => upstream.lastBody != null);
    upstream.gates.first.complete();
    await waitFor(() => !state.busy, reason: '首轮没有收尾');

    await state.editUserMessage(
      0,
      '改过的提问',
      attachments: const [
        Attachment(
          path: 'a.txt',
          dataUrl: 'data:text/plain;base64,',
          textContent: 'AAA',
          sizeBytes: 3,
        ),
      ],
    );
    await waitFor(() => upstream.lastBody?.contains('改过的提问') == true);

    final body = jsonDecode(upstream.lastBody!) as Map<String, dynamic>;
    expect(jsonEncode(body['input']), isNot(contains('【文件：')));

    upstream.gates.last.complete();
    await waitFor(() => !state.busy, reason: '编辑轮没有收尾');
  });
}
