import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/models.dart';
import 'package:ds_api/storage.dart';
import 'package:ds_api/ui/widgets/messages_view.dart';

/// 附件结构化改造的行为测试：
/// - 新消息：附件信息走结构化 files（含文本文件内容），正文干净；
/// - 旧消息：正文里的 `【文件：…】` 标记仍可解析（legacy 兼容）。

ChatMessage newUserMsg() => const ChatMessage(
  role: MessageRole.user,
  content: '帮我总结一下',
  files: [
    ChatFile(
      id: 'text:notes.txt',
      name: 'notes.txt',
      sizeBytes: 10,
      text: '文件内容第一行',
    ),
    ChatFile(id: 'file-api-123', name: 'report.pdf', sizeBytes: 2048),
    ChatFile(id: 'unsupported:movie.mp4', name: 'movie.mp4'),
  ],
);

void main() {
  group('新消息（结构化 files）', () {
    test('正文不再携带 【文件：…】 标记', () {
      final parts = userMessageParts(newUserMsg());
      expect(parts.text, '帮我总结一下');
      expect(parts.text.contains('【文件：'), isFalse);
    });

    test('三个文件都解析成卡片：文本/已上传/不支持', () {
      final parts = userMessageParts(newUserMsg());
      expect(parts.files.length, 3);
      expect(parts.files[0].name, 'notes.txt');
      expect(parts.files[0].content, '文件内容第一行');
      expect(parts.files[0].size, '10B');
      expect(parts.files[1].name, 'report.pdf');
      expect(parts.files[1].size, '2KB');
      expect(parts.files[2].name, 'movie.mp4');
    });

    test('发给模型的 input：文本文件展开成文本块，unsupported 不进请求', () {
      final input = buildResponsesInput([newUserMsg()]);
      expect(input.length, 1);
      final content = input[0]['content'] as List<Map<String, dynamic>>;
      // 正文 + 文本文件内容块 + 已上传文档块（unsupported 被跳过）
      expect(content.length, 3);
      expect((content[0]['text'] as String).contains('帮我总结一下'), isTrue);
      expect(
        (content[0]['text'] as String).contains('【文件：'),
        isFalse,
      );
      final fileText = content[1]['text'] as String;
      expect(fileText, contains('<file name="notes.txt">'));
      expect(fileText, contains('文件内容第一行'));
      expect(content[2]['file_id'], 'file-api-123');
    });
  });

  group('legacy 兼容（旧消息正文带标记）', () {
    test('旧文本文件标记：卡片渲染信息与编辑回填内容完整', () {
      // 旧格式：正文在前，附件标记拼在尾部
      const legacy = ChatMessage(
        role: MessageRole.user,
        content: '这是提问正文\n\n【文件：a.txt｜1KB】\n旧文件的内容',
      );
      final parts = userMessageParts(legacy);
      expect(parts.text, '这是提问正文');
      expect(parts.files.length, 1);
      expect(parts.files[0].name, 'a.txt');
      expect(parts.files[0].size, '1KB');
      expect(parts.files[0].content, '旧文件的内容');
      // 回填输入区：内容放回附件
      expect(parts.files.first.content, '旧文件的内容');
    });

    test('多个旧标记按顺序解析', () {
      const legacy = ChatMessage(
        role: MessageRole.user,
        content: '【文件：a.txt｜10B】\n内容A\n\n【文件：b.txt｜20B】\n内容B',
      );
      final parts = legacySplitUserContent(legacy.content);
      expect(parts.text, '');
      expect(parts.files.length, 2);
      expect(parts.files[0].name, 'a.txt');
      expect(parts.files[0].content, '内容A');
      expect(parts.files[1].name, 'b.txt');
      expect(parts.files[1].content, '内容B');
    });

    test('用户正文里恰好出现 【文件：xxx】 样式文字且无换行跟随时不误判', () {
      const plain = ChatMessage(
        role: MessageRole.user,
        content: '今天的主题是【文件：系统】的用法',
      );
      final parts = legacySplitUserContent(plain.content);
      expect(parts.files, isEmpty);
      expect(parts.text, '今天的主题是【文件：系统】的用法');
    });

    test('已上传/不支持格式的旧标记不含换行内容，不被内容正则误配', () {
      const legacy = ChatMessage(
        role: MessageRole.user,
        content: '【文件：report.pdf｜2KB】（已上传，file_id=file-api-1）',
      );
      final parts = legacySplitUserContent(legacy.content);
      // 旧行为：这类标记本来就不被正则匹配，保持原样显示
      expect(parts.files, isEmpty);
      expect(parts.text, contains('【文件：report.pdf'));
    });

    test('旧消息发给模型时文本文件内容仍在正文里，不丢失', () {
      final input = buildResponsesInput([
        const ChatMessage(
          role: MessageRole.user,
          content: '这是提问正文\n\n【文件：a.txt｜1KB】\n旧文件的内容',
        ),
      ]);
      final content = input.single['content'];
      expect(content, contains('旧文件的内容'));
      expect(content, contains('这是提问正文'));
    });
  });

  group('ChatFile 编解码', () {
    test('text 字段经 toJson/fromJson 往返保留', () {
      const file = ChatFile(
        id: 'text:a.txt',
        name: 'a.txt',
        sizeBytes: 5,
        text: 'hello',
      );
      final restored = ChatFile.fromJson(file.toJson());
      expect(restored!.text, 'hello');
      expect(restored.isTextFile, isTrue);
    });

    test('旧 JSON（无 text 字段）解析不受影响', () {
      final restored = ChatFile.fromJson({
        'id': 'file-api-9',
        'name': 'doc.pdf',
        'size': 100,
      });
      expect(restored!.text, isNull);
      expect(restored.isTextFile, isFalse);
      expect(restored.isUnsupported, isFalse);
    });

    test('formatBytes 保持既有展示', () {
      expect(formatBytes(10), '10B');
      expect(formatBytes(2048), '2KB');
    });
  });
}
