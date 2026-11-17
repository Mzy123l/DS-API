// ignore_for_file: avoid_print
// 从 deepseek-clone 的 icon.png 提取白色鲸鱼，输出透明底 whale.png
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.isEmpty) {
    print('用法: dart run tool/extract_whale.dart <输入图> [输出图]');
    exit(2);
  }
  final input = args[0];
  final out = args.length > 1
      ? args[1]
      : 'assets/whale.png';

  final bytes = File(input).readAsBytesSync();
  final src = img.decodeImage(bytes)!;
  final dst = img.Image(width: src.width, height: src.height, numChannels: 4);

  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final maxc = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final minc = r < g ? (r < b ? r : b) : (g < b ? g : b);
      final sat = maxc == 0 ? 0.0 : (maxc - minc) / maxc;
      // 鲸鱼接近白色（低饱和度、高亮度）；背景为蓝色渐变（高饱和度）
      final alpha = ((0.28 - sat) / 0.28).clamp(0.0, 1.0);
      dst.setPixelRgba(
        x,
        y,
        255,
        255,
        255,
        (alpha * 255).round(),
      );
    }
  }

  File(out)..createSync(recursive: true)..writeAsBytesSync(img.encodePng(dst));
  print('Wrote $out (${src.width}x${src.height})');
}
