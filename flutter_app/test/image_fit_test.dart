import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ds_api/image_fit.dart';
import 'package:ds_api/deepseek_client.dart';
import 'package:ds_api/storage.dart';

Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(30, 120, 200));
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

Uint8List _gif(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(10, 200, 10));
  return Uint8List.fromList(img.encodeGif(image));
}

Uint8List _webpVp8x(int width, int height) {
  final bytes = BytesBuilder();
  bytes.add([0x52, 0x49, 0x46, 0x46]); // RIFF
  bytes.add([0x00, 0x00, 0x00, 0x00]); // 文件长度（探测用不到）
  bytes.add([0x57, 0x45, 0x42, 0x50]); // WEBP
  bytes.add([0x56, 0x50, 0x38, 0x58]); // VP8X
  bytes.add([0x0A, 0x00, 0x00, 0x00]); // 块长度
  bytes.add([0x00, 0x00, 0x00, 0x00]); // 标志位
  final w = width - 1;
  final h = height - 1;
  bytes.add([w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF]);
  bytes.add([h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF]);
  return bytes.toBytes();
}

Uint8List _heic() {
  // ftyp 盒 + heic 品牌，足够让内容嗅探认出「这是 HEIC」
  return Uint8List.fromList([
    0x00, 0x00, 0x00, 0x18, // box size
    0x66, 0x74, 0x79, 0x70, // ftyp
    0x68, 0x65, 0x69, 0x63, // heic
    0x00, 0x00, 0x00, 0x00,
    0x68, 0x65, 0x69, 0x63,
    0x6D, 0x69, 0x66, 0x31,
    0x00, 0x00, 0x00, 0x00,
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('探测 JPEG/PNG/GIF/WebP：格式与尺寸按内容判断', () {
    final jpeg = probeImage(_jpeg(64, 48));
    expect(jpeg.format, 'jpeg');
    expect(jpeg.mediaType, 'image/jpeg');
    expect(jpeg.width, 64);
    expect(jpeg.height, 48);
    expect(jpeg.supported, isTrue);

    final png = probeImage(_png(120, 90));
    expect(png.format, 'png');
    expect((png.width, png.height), (120, 90));

    final gif = probeImage(_gif(33, 44));
    expect(gif.format, 'gif');
    expect((gif.width, gif.height), (33, 44));

    final webp = probeImage(_webpVp8x(9000, 12));
    expect(webp.format, 'webp');
    expect((webp.width, webp.height), (9000, 12));
  });

  test('HEIC/AVIF/BMP/TIFF 能识别但不被上游支持', () {
    final heic = probeImage(_heic());
    expect(heic.format, 'heic');
    expect(heic.supported, isFalse);
    expect(heic.mediaType, 'image/heic');

    final avif = probeImage(
      Uint8List.fromList([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, //
        0x61, 0x76, 0x69, 0x66, 0x00, 0x00, 0x00, 0x00,
      ]),
    );
    expect(avif.format, 'avif');
    expect(avif.supported, isFalse);

    final bmp = probeImage(Uint8List.fromList([0x42, 0x4D, 0x00, 0x00]));
    expect(bmp.format, 'bmp');

    final tiff = probeImage(
      Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00]),
    );
    expect(tiff.format, 'tiff');
  });

  test('限制内的图片原样返回，不重新编码', () async {
    final jpeg = _jpeg(4032, 3024);
    final prepared = await prepareImageForApi(jpeg);
    expect(prepared, isNotNull);
    expect(prepared!.format, 'jpeg');
    expect(prepared.bytes, same(jpeg), reason: '尺寸/体积都在限制内，不应重压');
  });

  test('不支持的格式返回 null（交给界面提示，而不是让上游报错）', () async {
    expect(await prepareImageForApi(_heic()), isNull);
  });

  test('单边超过 8192px 时缩到 8192 再发', () async {
    final tall = _png(9000, 8);
    expect(probeImage(tall).longestSide, 9000);

    final prepared = await prepareImageForApi(tall);
    expect(prepared, isNotNull);
    expect(prepared!.format, 'jpeg');
    final after = probeImage(prepared.bytes);
    expect(after.format, 'jpeg');
    expect(after.width, 8192);
    expect(after.longestSide, lessThanOrEqualTo(apiImageMaxSide));
  });

  group('prepareInputImages：历史图片在发请求前再兜一层', () {
    Map<String, dynamic> inputWith(String dataUrl) => {
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': '看图'},
        {'type': 'input_image', 'image_url': dataUrl, 'detail': 'low'},
      ],
    };

    test('正常的图片原样保留（不重复编码）', () async {
      final url = 'data:image/jpeg;base64,${base64Encode(_jpeg(64, 48))}';
      final prepared = await prepareInputImages([inputWith(url)]);
      expect(prepared.dropped, 0);
      final parts = prepared.input.single['content'] as List;
      expect((parts[1] as Map)['image_url'], url);
    });

    test('超尺寸的老图片会被缩到 8192 再发', () async {
      final url = 'data:image/png;base64,${base64Encode(_png(9000, 8))}';
      final prepared = await prepareInputImages([inputWith(url)]);
      expect(prepared.dropped, 0);
      final parts = prepared.input.single['content'] as List;
      final fixed = (parts[1] as Map)['image_url'] as String;
      expect(fixed, isNot(url));
      expect(fixed, startsWith('data:image/jpeg;base64,'));
      expect(
        probeImage(base64Decode(fixed.substring(fixed.indexOf(',') + 1))).width,
        8192,
      );
    });

    test('不支持的格式直接跳过并计数，而不是让整条请求 400', () async {
      final url = 'data:image/jpeg;base64,${base64Encode(_heic())}';
      final prepared = await prepareInputImages([inputWith(url)]);
      expect(prepared.dropped, 1);
      final parts = prepared.input.single['content'] as List;
      expect(parts.length, 1);
      expect((parts.single as Map)['type'], 'input_text');
    });

    test('整条消息只有一张不支持的图时补文本块，避免空 content', () async {
      final url = 'data:image/jpeg;base64,${base64Encode(_heic())}';
      final prepared = await prepareInputImages([
        {
          'role': 'user',
          'content': [
            {'type': 'input_image', 'image_url': url},
          ],
        },
      ]);
      expect(prepared.dropped, 1);
      final parts = prepared.input.single['content'] as List;
      expect(parts, isNotEmpty);
      expect((parts.single as Map)['type'], 'input_text');
    });
  });

  group('loadFileAttachment 按内容而不是扩展名判断', () {
    final tmp = Directory.systemTemp.createTempSync('dsapi_image_fit');
    tearDownAll(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('扩展名 .png、内容其实是 JPEG：按 image/jpeg 发出', () async {
      final f = File('${tmp.path}/looks_like_png.png');
      f.writeAsBytesSync(_jpeg(40, 30));

      final att = await loadFileAttachment(f.path);
      expect(att, isNotNull);
      expect(att!.isImage, isTrue);
      expect(att.dataUrl, startsWith('data:image/jpeg;base64,'));
    });

    test('扩展名 .jpg、内容其实是 HEIC：本地拦下', () async {
      final f = File('${tmp.path}/IMG_0001.jpg');
      f.writeAsBytesSync(_heic());

      expect(await loadFileAttachment(f.path), isNull);
      expect(looksLikeImagePath(f.path), isTrue);
    });
  });
}
