import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ds_api/storage.dart';

void main() {
  final tmp = Directory.systemTemp.createTempSync('dsapi_attach_test');

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('文本文件应读取内容供模型查看', () async {
    final f = File('${tmp.path}/note.txt');
    f.writeAsStringSync('Hello DeepSeek\n这是一个文本文件');

    final att = await loadFileAttachment(f.path);
    expect(att, isNotNull);
    expect(att!.isImage, isFalse);
    expect(att.isText, isTrue);
    expect(att.textContent, contains('Hello DeepSeek'));
  });

  test('图片文件按内容魔数识别为图片附件（无扩展名可识别）', () async {
    final f = File('${tmp.path}/img.photo');
    f.writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);

    final att = await loadFileAttachment(f.path);
    expect(att, isNotNull);
    expect(att!.isImage, isTrue);
    expect(att.dataUrl, startsWith('data:image/'));
  });

  test('明显二进制后缀（如 zip）应被过滤', () async {
    final f = File('${tmp.path}/package.zip');
    f.writeAsBytesSync(<int>[0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]);

    final att = await loadFileAttachment(f.path);
    expect(att, isNull);
  });

  test('文本后缀但内容含 NUL 字节应被过滤', () async {
    final f = File('${tmp.path}/fake.txt');
    f.writeAsBytesSync(<int>[0x41, 0x00, 0x42]);

    final att = await loadFileAttachment(f.path);
    expect(att, isNull);
  });

  test('超大文本不再截断', () async {
    final f = File('${tmp.path}/big.txt');
    f.writeAsStringSync('a' * 150000);

    final att = await loadFileAttachment(f.path);
    expect(att, isNotNull);
    expect(att!.textContent, isNotNull);
    expect(att.textContent!.length, 150000);
  });

  test('本地缓存：超大图片不写库（避免 CursorWindow 装不下导致会话打不开）', () {
    expect(encodeCachedImages(const []), '[]');

    // 正常大小的图片照常写入
    final small = ['data:image/jpeg;base64,${'A' * 200}'];
    expect(encodeCachedImages(small), jsonEncode(small));

    // 超过上限（16MB）的图片只存空数组
    final huge = ['data:image/jpeg;base64,${'A' * (maxCachedImageJsonBytes + 100)}'];
    expect(encodeCachedImages(huge), '[]');
  });
}
