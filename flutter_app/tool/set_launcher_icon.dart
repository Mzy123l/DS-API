// 把 tool/assets/app_icon_source.ico 转成各密度的 Android 启动图标（应用内鲸鱼图标不动）。
//
// 用法：cd flutter_app && dart run tool/set_launcher_icon.dart [图标路径]
// 默认读取 tool/assets/app_icon_source.ico（原名 图标.ico，原先放在仓库根目录，
// 改用 ASCII 文件名以避开 Git Bash / PowerShell / CI 的编码差异）。
// 这里只是构建期源文件，不进 pubspec.yaml 的 assets，App 运行时不加载。
import 'dart:io';

import 'package:image/image.dart' as img;

const Map<String, int> _sizes = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

void main(List<String> args) {
  final source = File(
    args.isNotEmpty ? args.first : 'tool/assets/app_icon_source.ico',
  );
  if (!source.existsSync()) {
    stderr.writeln('找不到 ${source.path}');
    exit(1);
  }
  final bytes = source.readAsBytesSync();
  // ICO 容器里可能有多张图，先按 ICO 解码，失败再退回普通位图解码。
  final decoded = img.decodeIco(bytes) ?? img.decodeImage(bytes);
  if (decoded == null) {
    stderr.writeln('ICO 解码失败');
    exit(1);
  }
  stdout.writeln('源图：${decoded.width}x${decoded.height}');
  for (final entry in _sizes.entries) {
    final resized = img.copyResize(
      decoded,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.cubic,
    );
    final target = File(
      'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
    );
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(img.encodePng(resized));
    stdout.writeln('${target.path}  ${entry.value}x${entry.value}');
  }
}
