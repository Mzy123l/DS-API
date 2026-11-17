import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/models.dart';
import 'package:ds_api/ui/widgets/messages_view.dart';

/// 造一段足够长的对话，保证列表可以滚动。
List<ChatMessage> buildMessages(int count, {String lastAssistant = '回答'}) {
  return [
    for (var i = 0; i < count; i++)
      i.isEven
          ? ChatMessage(role: MessageRole.user, content: '问题 $i')
          : ChatMessage(role: MessageRole.assistant, content: '回答 $i'),
    ChatMessage(role: MessageRole.assistant, content: lastAssistant),
  ];
}

Widget wrap({
  required List<ChatMessage> messages,
  int? conversationId = 1,
  int scrollToken = 0,
  bool busy = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 420,
        child: MessagesView(
          conversationId: conversationId,
          scrollToken: scrollToken,
          messages: messages,
          busy: busy,
          onToggleThinking: (_) {},
          onRegenerateAt: (_) {},
          onEditStart: (_) {},
          onStop: () {},
          onNotice: (_) {},
        ),
      ),
    ),
  );
}

/// 读取列表当前滚动位置（列表是 reverse，0 即最底部）。
double currentOffset(WidgetTester tester) {
  // 内容不足一屏时是贴顶的 SingleChildScrollView，超过一屏才是倒序 ListView
  final list = find.byType(ListView);
  if (list.evaluate().isNotEmpty) {
    return tester.widget<ListView>(list.first).controller!.offset;
  }
  final scrollView = find.byType(SingleChildScrollView).first;
  return tester.widget<SingleChildScrollView>(scrollView).controller!.offset;
}

Finder get bottomButton => find.byKey(scrollToBottomButtonKey);

void main() {
  testWidgets('消息不足一屏时内容贴顶显示', (tester) async {
    await tester.pumpWidget(
      wrap(
        messages: const [
          ChatMessage(role: MessageRole.user, content: '短问题'),
          ChatMessage(role: MessageRole.assistant, content: '短回答'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 第一条消息应该靠近顶部（而不是被挤到最下面）
    final top = tester.getTopLeft(find.text('短问题')).dy;
    expect(top, lessThan(120));
    expect(currentOffset(tester), 0);
    expect(bottomButton, findsNothing);
  });

  testWidgets('打开会话默认停在最底下，不显示回到底部按钮', (tester) async {
    await tester.pumpWidget(wrap(messages: buildMessages(30)));
    await tester.pumpAndSettle();

    expect(currentOffset(tester), 0);
    expect(bottomButton, findsNothing);
  });

  testWidgets('往上翻后出现回到底部按钮，点击可回到最底下', (tester) async {
    await tester.pumpWidget(wrap(messages: buildMessages(30)));
    await tester.pumpAndSettle();

    // 手指下拉 = 往上翻看更早的内容
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(currentOffset(tester), greaterThan(0));
    expect(bottomButton, findsOneWidget);

    await tester.tap(bottomButton);
    await tester.pumpAndSettle();
    expect(currentOffset(tester), 0);
    expect(bottomButton, findsNothing);
  });

  testWidgets('上翻/回到底部会通知外层（用于冻结流式刷新）', (tester) async {
    final events = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 420,
            child: MessagesView(
              conversationId: 1,
              scrollToken: 0,
              messages: buildMessages(30),
              busy: true,
              onToggleThinking: (_) {},
              onRegenerateAt: (_) {},
              onEditStart: (_) {},
              onStop: () {},
              onNotice: (_) {},
              onAtBottomChanged: events.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(events.last, isFalse); // 上翻 → 暂停刷新

    await tester.tap(bottomButton);
    await tester.pumpAndSettle();
    expect(events.last, isTrue); // 回到底部 → 恢复刷新并补齐
  });

  testWidgets('上翻后偏移保持不变（流式内容由外层缓冲，不写进列表）', (tester) async {
    final messages = buildMessages(30, lastAssistant: '正在写');
    await tester.pumpWidget(wrap(messages: messages, busy: true));
    await tester.pumpAndSettle();

    // 往上翻
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final before = currentOffset(tester);
    expect(before, greaterThan(0));

    // 即使此时列表数据被换成更长的内容，也不应把视图拉走或跳回底部
    final grown = List<ChatMessage>.from(messages);
    grown[grown.length - 1] = grown.last.copyWith(
      content: '正在写\n\n${'内容行\n' * 20}',
    );
    await tester.pumpWidget(wrap(messages: grown, busy: true));
    await tester.pumpAndSettle();

    expect(currentOffset(tester), greaterThanOrEqualTo(before - 1));
    expect(bottomButton, findsOneWidget);
  });

  testWidgets('正在输出时手动上翻，内容增长不会把视图拉回底部', (tester) async {
    final messages = buildMessages(30, lastAssistant: '正在写');
    await tester.pumpWidget(wrap(messages: messages, busy: true));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    final offsetBefore = currentOffset(tester);
    expect(offsetBefore, greaterThan(0));

    // 流式输出：最后一条内容变长
    final grown = List<ChatMessage>.from(messages);
    grown[grown.length - 1] = grown.last.copyWith(content: '正在写更多内容……');
    await tester.pumpWidget(wrap(messages: grown, busy: true));
    await tester.pumpAndSettle();

    expect(currentOffset(tester), offsetBefore);
    expect(bottomButton, findsOneWidget);
  });

  testWidgets('点历史记录切到另一个会话时回到最底下', (tester) async {
    await tester.pumpWidget(wrap(messages: buildMessages(30)));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(currentOffset(tester), greaterThan(0));

    await tester.pumpWidget(
      wrap(messages: buildMessages(12), conversationId: 2),
    );
    await tester.pumpAndSettle();

    expect(currentOffset(tester), 0);
    expect(bottomButton, findsNothing);
  });

  testWidgets('自己发新消息时回到最底下', (tester) async {
    final messages = buildMessages(30);
    await tester.pumpWidget(wrap(messages: messages, scrollToken: 3));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(currentOffset(tester), greaterThan(0));

    final withNewTurn = [
      ...messages,
      const ChatMessage(role: MessageRole.user, content: '新问题'),
      const ChatMessage(role: MessageRole.assistant, content: ''),
    ];
    await tester.pumpWidget(
      wrap(messages: withNewTurn, busy: true, scrollToken: 4),
    );
    await tester.pumpAndSettle();

    expect(currentOffset(tester), 0);
    expect(bottomButton, findsNothing);
  });

  testWidgets('新消息：文件卡片从结构化 files 渲染，正文不带标记', (tester) async {
    await tester.pumpWidget(
      wrap(
        messages: const [
          ChatMessage(
            role: MessageRole.user,
            content: '帮我总结',
            files: [
              ChatFile(
                id: 'text:notes.txt',
                name: 'notes.txt',
                sizeBytes: 10,
                text: '文件内容',
              ),
              ChatFile(id: 'file-api-1', name: 'report.pdf', sizeBytes: 2048),
            ],
          ),
          ChatMessage(role: MessageRole.assistant, content: '回答'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('帮我总结'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('10B'), findsOneWidget);
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('2KB'), findsOneWidget);
    // 正文与卡片里都不应再出现旧文本标记
    expect(find.textContaining('【文件：'), findsNothing);
  });

  testWidgets('legacy：旧消息正文带标记时仍渲染文件卡片并隐藏标记', (tester) async {
    await tester.pumpWidget(
      wrap(
        messages: [
          const ChatMessage(
            role: MessageRole.user,
            content: '这是提问正文\n\n【文件：a.txt｜1KB】\n旧文件的内容',
          ),
          const ChatMessage(role: MessageRole.assistant, content: '回答'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这是提问正文'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('1KB'), findsOneWidget);
    // 标记段（含文件内容）不直接出现在气泡正文里
    expect(find.textContaining('旧文件的内容'), findsNothing);
    expect(find.textContaining('【文件：'), findsNothing);
  });

  group('操作行图标按下反馈（重新生成 / 停止）', () {
    /// 取操作行里那个图标当前的缩放值（按下态 0.82）。
    double iconScale(WidgetTester tester, IconData icon) {
      final scale = find.ancestor(
        of: find.byIcon(icon),
        matching: find.byType(AnimatedScale),
      );
      expect(scale, findsOneWidget, reason: '图标外面没有按下反馈的包装');
      return tester.widget<AnimatedScale>(scale).scale;
    }

    testWidgets('按住重新生成：图标立刻缩小，松手后恢复', (tester) async {
      await tester.pumpWidget(
        wrap(
          messages: const [
            ChatMessage(role: MessageRole.user, content: '问题'),
            ChatMessage(role: MessageRole.assistant, content: '回答'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(iconScale(tester, Icons.refresh), 1);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.refresh)),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        iconScale(tester, Icons.refresh),
        lessThan(1),
        reason: '按下重新生成没有任何视觉反馈',
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(iconScale(tester, Icons.refresh), 1);
    });

    testWidgets('按住停止：同样有按下反馈', (tester) async {
      await tester.pumpWidget(
        wrap(
          messages: const [
            ChatMessage(role: MessageRole.user, content: '问题'),
            ChatMessage(role: MessageRole.assistant, content: '正在写'),
          ],
          busy: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(iconScale(tester, Icons.stop), 1);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.stop)),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(iconScale(tester, Icons.stop), lessThan(1));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(iconScale(tester, Icons.stop), 1);
    });
  });
}
