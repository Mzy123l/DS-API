// ignore_for_file: avoid_print
// 生成白底蓝鲸图标（对齐官方启动图标：白色圆角底 + 品牌蓝鲸鱼）。
// 方法：对 assets/icon_official.png（蓝底白鲸）按亮度反相 → 白底蓝鲸，保留圆角与平滑边缘。
import 'dart:io';

import 'package:image/image.dart' as img;

const _brand = (0x4D, 0x6B, 0xFE);

void main() {
  final src =
      img.decodeImage(File('assets/icon_official.png').readAsBytesSync())!;
  const size = 1024;
  final big = img.copyResize(
    src,
    width: size,
    height: size,
    interpolation: img.Interpolation.cubic,
  );

  // 品牌蓝亮度（背景），作为反相阈值
  const bgLum = (77 + 107 + 254) / 3.0; // 146
  final out = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final p = big.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final a = p.a.toInt();
      // t=0 背景(蓝) -> 白；t=1 鲸鱼(白) -> 品牌蓝
      var t = ((r + g + b) / 3.0 - bgLum) / (255.0 - bgLum);
      t = t.clamp(0.0, 1.0);
      final or = 255 + (_brand.$1 - 255) * t;
      final og = 255 + (_brand.$2 - 255) * t;
      final ob = 255 + (_brand.$3 - 255) * t;
      out.setPixelRgba(
        x,
        y,
        or.round().clamp(0, 255),
        og.round().clamp(0, 255),
        ob.round().clamp(0, 255),
        a,
      );
    }
  }

  File('assets/icon_app.png').writeAsBytesSync(img.encodePng(out));
  print('Wrote assets/icon_app.png');

  // 重新生成各密度 mipmap 启动图标
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
    final scaledIcon = img.copyResize(
      out,
      width: e.value,
      height: e.value,
      interpolation: img.Interpolation.cubic,
    );
    File('$dir/ic_launcher.png').writeAsBytesSync(img.encodePng(scaledIcon));
    print('wrote $dir/ic_launcher.png (${e.value})');
  }
}
