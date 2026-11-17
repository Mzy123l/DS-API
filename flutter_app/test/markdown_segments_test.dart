import 'package:ds_api/ui/widgets/messages_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitMarkdownSegments', () {
    test('普通文本不产生引用段', () {
      final segments = splitMarkdownSegments('第一段\n\n第二段\n');
      expect(segments.length, 1);
      expect(segments.single.isQuote, isFalse);
      expect(segments.single.isCode, isFalse);
    });

    test('引用块被单独切出，且去掉 > 标记、保留段落分隔', () {
      final segments = splitMarkdownSegments('上文\n\n> 引用一\n>\n> 引用二 `code`\n\n下文\n');
      expect(segments.map((s) => s.isQuote), [false, true, false]);
      expect(segments[1].text.trim(), '引用一\n\n引用二 `code`');
    });

    test('引用块里的列表与加粗保持原样', () {
      final segments = splitMarkdownSegments('> - **要点**\n> - 第二点\n');
      expect(segments.length, 1);
      expect(segments.single.isQuote, isTrue);
      expect(segments.single.text.trim(), '- **要点**\n- 第二点');
    });

    test('代码块不被当作引用，且引用块与代码块可共存', () {
      final segments = splitMarkdownSegments(
        '> 引用\n\n```dart\nvoid main() {}\n```\n\n> 又一段引用\n',
      );
      expect(segments.map((s) => (s.isQuote, s.isCode)), [
        (true, false),
        (false, true),
        (true, false),
      ]);
      expect(segments[1].language, 'dart');
    });

    test('嵌套引用只去掉一层标记', () {
      final segments = splitMarkdownSegments('> > 深层引用\n');
      expect(segments.single.isQuote, isTrue);
      expect(segments.single.text.trim(), '> 深层引用');
    });
  });
}
