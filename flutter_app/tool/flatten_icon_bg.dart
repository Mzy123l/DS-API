// 把 assets/icon_app.png 的渐变背景压成纯白（保留鲸鱼主体与圆角透明区）。
//
// 用法：cd flutter_app && dart run tool/flatten_icon_bg.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final file = File('assets/icon_app.png');
  final image = img.decodePng(file.readAsBytesSync());
  if (image == null) {
    stderr.writeln('解码失败');
    exit(1);
  }
  var changed = 0;
  for (final pixel in image) {
    final maxChannel = [
      pixel.r,
      pixel.g,
      pixel.b,
    ].reduce((a, b) => a > b ? a : b);
    final minChannel = [
      pixel.r,
      pixel.g,
      pixel.b,
    ].reduce((a, b) => a < b ? a : b);
    // 浅色且几乎无彩度 → 属于渐变背景，压成纯白
    if (maxChannel > 225 && (maxChannel - minChannel) < 34) {
      pixel.setRgba(255, 255, 255, pixel.a);
      changed++;
    }
  }
  file.writeAsBytesSync(img.encodePng(image));
  stdout.writeln('已处理 ${image.width}x${image.height}，背景像素 $changed 个');
}
