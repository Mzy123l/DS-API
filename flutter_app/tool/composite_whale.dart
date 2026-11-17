// ignore_for_file: avoid_print
import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final whale = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final out = img.Image(width: whale.width, height: whale.height, numChannels: 4);
  // 靛蓝背景
  img.fill(out, color: img.ColorRgb8(0x4D, 0x6B, 0xFE));
  img.compositeImage(out, whale);
  File(args[1]).writeAsBytesSync(img.encodePng(out));
  print('Wrote ${args[1]}');
}
