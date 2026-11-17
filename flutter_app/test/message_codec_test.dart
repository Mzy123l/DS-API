import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/data/message_codec.dart';
import 'package:ds_api/models.dart';

/// 编解码收敛后的单一来源测试：锁住「缺字段时的默认值」和
/// 「wire ↔ DTO ↔ SQLite 行」的往返，避免以后改一处忘两处。
void main() {
  group('MessageCodec wire', () {
    test('toWire 字段名与默认值', () {
      final msg = ChatMessage(
        role: MessageRole.assistant,
        content: '回答',
        reasoning: '想过了',
        reasoningMs: 120,
        sources: const [ChatSource(title: 'T', url: 'https://a.example')],
        imageDataUrls: const ['data:image/png;base64,AA'],
        files: const [ChatFile(id: 'file-api-1', name: 'a.pdf', sizeBytes: 7)],
        audioFiles: const ['/tmp/a.wav'],
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(MessageCodec.toWire(msg), {
        'role': 'assistant',
        'content': '回答',
        'reasoning': '想过了',
        'reasoning_ms': 120,
        'sources': [
          {'title': 'T', 'url': 'https://a.example'},
        ],
        'images': ['data:image/png;base64,AA'],
        'files': [
          {'id': 'file-api-1', 'name': 'a.pdf', 'size': 7},
        ],
        'audio': ['/tmp/a.wav'],
        'ts': 1700000000000,
      });
    });

    test('toWire 不写 id / conversation_id / pending', () {
      final wire = MessageCodec.toWire(
        ChatMessage(id: 9, role: MessageRole.user, content: 'hi'),
      );
      expect(wire.containsKey('id'), isFalse);
      expect(wire.containsKey('conversation_id'), isFalse);
      expect(wire.containsKey('pending'), isFalse);
      expect(wire['role'], 'user');
    });

    test('fromWire 缺字段时的默认值', () {
      final msg = MessageCodec.fromWire({'role': 'assistant'});
      expect(msg.id, isNull);
      expect(msg.content, '');
      expect(msg.reasoning, '');
      expect(msg.reasoningMs, 0);
      expect(msg.sources, isEmpty);
      expect(msg.imageDataUrls, isEmpty);
      expect(msg.files, isEmpty);
      expect(msg.audioFiles, isEmpty);
      expect(msg.timestamp, DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('fromWire 未知 role 归为 assistant（只有 "user" 才算用户）', () {
      expect(MessageCodec.fromWire({'role': 'user'}).role, MessageRole.user);
      expect(MessageCodec.fromWire({'role': 'assistant'}).role,
          MessageRole.assistant);
      expect(MessageCodec.fromWire({'role': 'system'}).role,
          MessageRole.assistant);
      expect(MessageCodec.fromWire(const {}).role, MessageRole.assistant);
    });

    test('fromWire 过滤空串与无 url 的项；标题只对 null 回退 url', () {
      final msg = MessageCodec.fromWire({
        'sources': [
          {'title': '', 'url': 'https://a.example'},
          {'title': 'ok', 'url': 'https://b.example'},
          {'title': '没有 url'},
          {'url': 'https://c.example'},
          'not-a-map',
        ],
        'images': ['data:1', '', 123],
        'audio': ['/a.wav', ''],
        'files': [
          {'id': 'file-api-1', 'name': 'a.pdf', 'size': 7},
          {'id': ''},
          {'name': '无 id'},
          'nope',
        ],
      });
      expect(msg.sources.map((s) => s.url), [
        'https://a.example',
        'https://b.example',
        'https://c.example',
      ]);
      // 空串标题保持空串（只在缺字段才回退 url），与快照解析不同
      expect(msg.sources.first.title, '');
      expect(msg.sources.last.title, 'https://c.example');
      expect(msg.imageDataUrls, ['data:1']);
      expect(msg.audioFiles, ['/a.wav']);
      expect(msg.files.single.id, 'file-api-1');
    });

    test('fromWire 接受数字型 id / ts / reasoning_ms', () {
      final msg = MessageCodec.fromWire({
        'id': 5.0,
        'ts': 1700000000000,
        'reasoning_ms': 30,
      });
      expect(msg.id, 5);
      expect(msg.reasoningMs, 30);
      expect(msg.timestamp, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    });

    test('listFromWire：非数组返回空，非 Map 元素跳过', () {
      expect(MessageCodec.listFromWire(null), isEmpty);
      expect(MessageCodec.listFromWire('x'), isEmpty);
      expect(
        MessageCodec.listFromWire([
          {'content': 'a'},
          42,
          {'content': 'b'},
        ]).map((m) => m.content),
        ['a', 'b'],
      );
    });

    test('wire → DTO → wire 往返不丢字段', () {
      final wire = {
        'role': 'user',
        'content': '问题',
        'reasoning': '',
        'reasoning_ms': 0,
        'sources': <Object>[],
        'images': ['data:image/png;base64,AA'],
        'files': [
          {'id': 'file-api-1', 'name': 'a.pdf', 'size': 7},
        ],
        'audio': <Object>[],
        'ts': 1700000000000,
      };
      expect(MessageCodec.toWire(MessageCodec.fromWire(wire)), wire);
    });
  });

  group('MessageCodec row', () {
    test('toRow 用 JSON 字符串存列表列，id 为空时不写 id', () {
      final row = MessageCodec.toRow(
        7,
        ChatMessage(
          role: MessageRole.user,
          content: '问题',
          sources: const [ChatSource(title: 'T', url: 'https://a.example')],
          imageDataUrls: const ['data:image/png;base64,AA'],
          files: const [ChatFile(id: 'file-api-1', name: 'a.pdf', sizeBytes: 7)],
          audioFiles: const ['/tmp/a.wav'],
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      );
      expect(row.containsKey('id'), isFalse);
      expect(row['conv_id'], 7);
      expect(row['role'], 'user');
      expect(row['reasoning'], '');
      expect(row['reasoning_ms'], 0);
      expect(row['sources'], jsonEncode([
        {'title': 'T', 'url': 'https://a.example'},
      ]));
      expect(row['images'], jsonEncode(['data:image/png;base64,AA']));
      expect(row['files'], jsonEncode([
        {'id': 'file-api-1', 'name': 'a.pdf', 'size': 7},
      ]));
      expect(row['audio'], jsonEncode(['/tmp/a.wav']));
      expect(row['ts'], 1700000000000);
    });

    test('toRow 带 id 时写 id（缓存服务端消息）', () {
      final row = MessageCodec.toRow(
        7,
        ChatMessage(id: 11, role: MessageRole.assistant, content: '回答'),
      );
      expect(row['id'], 11);
    });

    test('fromRow 解析 JSON 列；坏数据退化为空列表', () {
      final msg = MessageCodec.fromRow({
        'id': 1,
        'role': 'assistant',
        'content': '回答',
        'reasoning': '想过',
        'reasoning_ms': 55,
        'sources': jsonEncode([
          {'title': 'T', 'url': 'https://a.example'},
        ]),
        'images': '[]',
        'files': '不是 JSON',
        'audio': jsonEncode(['/a.wav', '']),
        'ts': 1700000000000,
      });
      expect(msg.id, 1);
      expect(msg.role, MessageRole.assistant);
      expect(msg.reasoningMs, 55);
      expect(msg.sources.single.title, 'T');
      expect(msg.imageDataUrls, isEmpty);
      expect(msg.files, isEmpty);
      expect(msg.audioFiles, ['/a.wav']);
    });

    test('fromRow 列缺失时的默认值', () {
      final msg = MessageCodec.fromRow({
        'id': null,
        'role': 'user',
        'content': 'x',
        'ts': 0,
      });
      expect(msg.id, isNull);
      expect(msg.reasoning, '');
      expect(msg.reasoningMs, 0);
      expect(msg.sources, isEmpty);
      expect(msg.imageDataUrls, isEmpty);
      expect(msg.files, isEmpty);
      expect(msg.audioFiles, isEmpty);
    });

    test('fromRow 非字符串 / 非数组列退化为空列表', () {
      final msg = MessageCodec.fromRow({
        'role': 'user',
        'content': 'x',
        'sources': '{"a":1}',
        'images': '',
        'files': 42,
        'audio': 'null',
        'ts': 0,
      });
      expect(msg.sources, isEmpty);
      expect(msg.imageDataUrls, isEmpty);
      expect(msg.files, isEmpty);
      expect(msg.audioFiles, isEmpty);
    });

    test('row → DTO → row 往返（id 存在时）', () {
      final msg = ChatMessage(
        id: 5,
        role: MessageRole.user,
        content: '问题',
        imageDataUrls: const ['data:image/png;base64,AA'],
        files: const [ChatFile(id: 'file-api-1', name: 'a.pdf', sizeBytes: 7)],
        audioFiles: const ['/a.wav'],
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      expect(MessageCodec.toRow(3, MessageCodec.fromRow(MessageCodec.toRow(3, msg))),
          MessageCodec.toRow(3, msg));
    });
  });

  group('MessageCodec 快照字段', () {
    test('sourcesFromSnapshot 丢空 url，空标题回退 url', () {
      final sources = MessageCodec.sourcesFromSnapshot([
        {'title': '', 'url': 'https://a.example'},
        {'title': 'T', 'url': 'https://b.example'},
        {'title': '空 url', 'url': ''},
        {'url': 1},
        'junk',
      ]);
      expect(sources.map((s) => s.url), [
        'https://a.example',
        'https://b.example',
      ]);
      expect(sources.first.title, 'https://a.example');
      expect(MessageCodec.sourcesFromSnapshot(null), isEmpty);
      expect(MessageCodec.sourcesFromSnapshot('x'), isEmpty);
    });

    test('audioFilesFromSnapshot 读 bytes 与缺省文件名', () {
      final audio = MessageCodec.audioFilesFromSnapshot([
        {'id': 'abc', 'name': 'speech-1.wav', 'bytes': 12},
        {'id': 'def'},
        {'name': '无 id'},
        'junk',
      ]);
      expect(audio.length, 2);
      expect(audio.first.name, 'speech-1.wav');
      expect(audio.first.sizeBytes, 12);
      // 与 ChatFile.fromJson 的缺省名不同（那边是 document）
      expect(audio.last.name, 'speech.wav');
      expect(audio.last.sizeBytes, 0);
      expect(MessageCodec.audioFilesFromSnapshot(null), isEmpty);
    });
  });

  group('ConversationCodec', () {
    test('fromWire 缺字段时的默认值', () {
      final conv = ConversationCodec.fromWire(const {});
      expect(conv.id, 0);
      expect(conv.title, '新对话');
      expect(conv.model, '');
      expect(conv.updatedAt, DateTime.fromMillisecondsSinceEpoch(0));
      expect(conv.preview, '');
      expect(conv.systemPrompt, '');
      expect(conv.answerBubble, isFalse);
    });

    test('answerBubble 接受 true 与 1', () {
      expect(
        ConversationCodec.fromWire({'answer_bubble': true}).answerBubble,
        isTrue,
      );
      expect(
        ConversationCodec.fromWire({'answer_bubble': 1}).answerBubble,
        isTrue,
      );
      expect(
        ConversationCodec.fromWire({'answer_bubble': 'true'}).answerBubble,
        isFalse,
      );
    });

    test('toRow 用 updatedAt 填 created_at / updated_at；可覆盖 systemPrompt', () {
      final conv = Conversation(
        id: 3,
        title: '会话',
        model: 'deepseek-flash',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        preview: '预览',
        systemPrompt: '服务端的提示词',
        answerBubble: true,
      );
      expect(ConversationCodec.toRow(conv, systemPrompt: '本机保留的'), {
        'id': 3,
        'title': '会话',
        'model': 'deepseek-flash',
        'system_prompt': '本机保留的',
        'created_at': 1700000000000,
        'updated_at': 1700000000000,
        'preview': '预览',
      });
      expect(ConversationCodec.toRow(conv)['system_prompt'], '服务端的提示词');
    });

    test('toRow 不含 answer_bubble（本地库没有该列）', () {
      final row = ConversationCodec.toRow(
        Conversation(
          id: 1,
          title: 't',
          model: 'm',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          answerBubble: true,
        ),
      );
      expect(row.containsKey('answer_bubble'), isFalse);
    });

    test('fromRow 与 toRow 往返', () {
      final conv = Conversation(
        id: 4,
        title: 't',
        model: 'm',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        preview: 'p',
        systemPrompt: 's',
      );
      final back = ConversationCodec.fromRow(ConversationCodec.toRow(conv));
      expect(back.id, conv.id);
      expect(back.title, conv.title);
      expect(back.model, conv.model);
      expect(back.updatedAt, conv.updatedAt);
      expect(back.preview, conv.preview);
      expect(back.systemPrompt, conv.systemPrompt);
      expect(back.answerBubble, isFalse);
    });

    test('listFromWire：非数组返回空，非 Map 元素跳过', () {
      expect(ConversationCodec.listFromWire(null), isEmpty);
      expect(
        ConversationCodec.listFromWire([
          {'id': 1},
          'junk',
          {'id': 2},
        ]).map((c) => c.id),
        [1, 2],
      );
    });
  });

  group('PageCodec', () {
    test('hasMore 只有 true 才算', () {
      expect(PageCodec.hasMore({'has_more': true}), isTrue);
      expect(PageCodec.hasMore({'has_more': false}), isFalse);
      expect(PageCodec.hasMore({'has_more': 1}), isFalse);
      expect(PageCodec.hasMore(const {}), isFalse);
    });

    test('oldestId 接受数字，缺失为 null', () {
      expect(PageCodec.oldestId({'oldest_id': 7}), 7);
      expect(PageCodec.oldestId({'oldest_id': 7.0}), 7);
      expect(PageCodec.oldestId({'oldest_id': null}), isNull);
      expect(PageCodec.oldestId(const {}), isNull);
    });
  });

  test('encodeCachedImages：正常大小写入，超过 16MB 存空数组', () {
    expect(encodeCachedImages(const []), '[]');
    final small = ['data:image/jpeg;base64,${'A' * 200}'];
    expect(encodeCachedImages(small), jsonEncode(small));
    final huge = [
      'data:image/jpeg;base64,${'A' * (maxCachedImageJsonBytes + 100)}',
    ];
    expect(encodeCachedImages(huge), '[]');
  });
}
