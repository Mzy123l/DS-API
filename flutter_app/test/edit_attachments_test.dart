import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/models.dart';
import 'package:ds_api/ui/widgets/input_composer.dart';

/// 回归：带文件的消息「重新编辑 → 再发送」后文件丢失。
///
/// 根因：`InputComposer._send()` 在编辑态把内部可变列表 `_attachments`
/// 直接交给 `onCommitEdit`，紧接着同步 `_attachments.clear()`；而
/// `editUserMessage` 是异步的（第一次 await 之后才读附件），此时列表已被
/// 清空 —— 文件（和图片）全部丢掉。发送新消息的路径用的是拷贝，所以只有
/// 编辑态出问题。
///
/// 本测试固化：编辑态提交时必须交出一份**独立拷贝**，清空输入区不影响它。
void main() {
  /// 挂一个处于编辑态、已带回文件的输入区。
  ///
  /// 返回一个读取器：拿到最近一次 `onCommitEdit` 交出的附件列表。
  ///
  /// 注意：编辑态内容是在 `didUpdateWidget` 里回填的，所以必须先挂非编辑态、
  /// 再切到编辑态（直接以 editing:true 首次挂载不会回填）。
  Future<List<Attachment>? Function()> pumpEditingComposer(
    WidgetTester tester,
  ) async {
    List<Attachment>? committed;
    Widget build({required bool editing}) => MaterialApp(
      home: Scaffold(
        body: InputComposer(
          onSend: (_, _) {},
          deepThink: true,
          webSearch: false,
          reasoningEffort: defaultReasoningEffort,
          onDeepThinkChanged: (_) {},
          onWebSearchChanged: (_) {},
          onEffortChanged: (_) {},
          onNotice: (_) {},
          editing: editing,
          editingText: '帮我总结',
          editingFiles: const [
            Attachment(
              path: 'notes.txt',
              dataUrl: 'data:text/plain;base64,',
              textContent: '文件内容',
              sizeBytes: 12,
            ),
          ],
          onCancelEdit: () {},
          onCommitEdit: (text, attachments) {
            // 真实调用方（root_shell）在这里立刻返回，附件要带进异步流程
            committed = attachments;
          },
        ),
      ),
    );

    await tester.pumpWidget(build(editing: false));
    await tester.pumpAndSettle();
    // 进入编辑态：回填正文与文件
    await tester.pumpWidget(build(editing: true));
    await tester.pumpAndSettle();
    return () => committed;
  }

  testWidgets('编辑态点发送：交出的附件里文件还在（不被 clear 清空）', (tester) async {
    final readCommitted = await pumpEditingComposer(tester);

    // 输入区里已带回该消息的文件卡片
    expect(find.text('notes.txt'), findsOneWidget);

    // 点发送箭头
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final committed = readCommitted();
    expect(committed, isNotNull, reason: '编辑提交没有回调');
    expect(
      committed!.length,
      1,
      reason: '文件在提交瞬间被清空了（旧 bug：编辑后重新发送文件丢失）',
    );
    expect(committed.single.fileName, 'notes.txt');
    expect(committed.single.textContent, '文件内容');
  });

  testWidgets('编辑态提交后输入区附件确实清空（下次不再误带）', (tester) async {
    await pumpEditingComposer(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // 提交拷贝后，输入区自身照常清空
    expect(find.text('notes.txt'), findsNothing);
  });
}
