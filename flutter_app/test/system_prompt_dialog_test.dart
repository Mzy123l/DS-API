import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/ui/widgets/system_prompt_dialog.dart';

/// 回归：系统提示词面板底部的「回答气泡」开关和上面的重复了。
///
/// 同一面板里出现两个「回答气泡」开关，底部那个还和上面那个状态互相独立，
/// 看着像"状态对不上"。现在只保留上面 [_DialogSwitchRow] 那一份。
void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    bool answerBubble = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SystemPromptDialog(
            initialPrompt: '你是助手',
            initialAnswerBubble: answerBubble,
            conversationTitle: '会话',
            onSave: (_, _, _, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('「回答气泡」只出现一次，且不再与上面的开关状态打架', (tester) async {
    await pumpDialog(tester);

    // 标签只出现一次
    expect(
      find.text('回答气泡'),
      findsOneWidget,
      reason: '回答气泡开关重复了（底部那份应该删掉）',
    );

    // 开关总数 = 回答气泡 + 语音生成工具 + 朗读括号内容
    expect(find.byType(Switch), findsNWidgets(3));
  });

  testWidgets('回答气泡开关仍然可用，并把值传给 onSave', (tester) async {
    (String, bool, bool, bool)? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SystemPromptDialog(
            initialPrompt: '你是助手',
            conversationTitle: '会话',
            onSave: (prompt, answerBubble, ttsTool, bracketSpeak) async {
              saved = (prompt, answerBubble, ttsTool, bracketSpeak);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开「回答气泡」后保存
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.$2, isTrue, reason: '回答气泡开关没有生效');
  });

  testWidgets('初始值 true 时开关显示为开', (tester) async {
    await pumpDialog(tester, answerBubble: true);
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.first.value, isTrue);
  });
}
