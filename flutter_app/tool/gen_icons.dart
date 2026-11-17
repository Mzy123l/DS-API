// ignore_for_file: avoid_print
// 用官方鲸鱼 icon.png 生成各密度 mipmap 启动图标
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final src = img.decodeImage(File('assets/icon.png').readAsBytesSync())!;
  const sizes = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  final resDir = 'android/app/src/main/res';
  for (final e in sizes.entries) {
    final dir = '$resDir/${e.key}';
    Directory(dir).createSync(recursive: true);
    final scaled = img.copyResize(src, width: e.value, height: e.value, interpolation: img.Interpolation.average);
    File('$dir/ic_launcher.png').writeAsBytesSync(img.encodePng(scaled));
    print('wrote $dir/ic_launcher.png (${e.value})');
  }
}
