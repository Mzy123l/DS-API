// 图片格式/尺寸识别与「超限才缩放」。
//
// DeepSeek 视觉接口（Messages / Responses / Chat Completions）只接受
// JPEG / PNG / GIF / WebP，而且**按文件真实内容判断格式**，不看扩展名或
// 声明的 MIME；单边超过 8192px、单图超过 32MiB、请求体超过 48MiB 都会被
// 直接拒掉（客户端看到的是一句 unsupported image）。
//
// App 里选图走的是「原图」（只压质量、不压尺寸），所以：
// - 扩展名是 .jpg 但内容是 HEIC/AVIF（部分厂商会这样存）时，以前会被当成
//   image/jpeg 发出去 → 上游认不出内容 → 报 unsupported image；
// - 高像素照片 / 长截图单边超过 8192px 时同样会被拒。
// 这里统一按字节判断格式，并且**只在超出上游限制时**才缩图，
// 正常图片原样发送，不改分辨率、不重新压缩。
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// 上游支持的图片格式（按文件实际内容判断）。
const Set<String> apiImageFormats = {'jpeg', 'png', 'gif', 'webp'};

/// 上游单边像素上限（官方限制：单边最长 8192px）。
const int apiImageMaxSide = 8192;

/// 单图字节软上限：base64 后会乘 4/3，留在 32MiB 单图 / 48MiB 请求体限制内。
const int apiImageMaxBytes = 12 * 1024 * 1024;

/// 图片探测结果：真实格式 + 像素尺寸（尺寸未知时为 null）。
class ImageProbe {
  const ImageProbe(this.format, {this.width, this.height});

  /// jpeg / png / gif / webp / heic / avif / bmp / tiff / unknown
  final String format;
  final int? width;
  final int? height;

  /// 能识别出这是张图片（无论上游是否支持该格式）。
  bool get isKnown => format != 'unknown';

  /// 上游是否接受该格式。
  bool get supported => apiImageFormats.contains(format);

  String get mediaType => 'image/$format';

  /// 长边像素；尺寸未知时按 0 处理。
  int get longestSide => math.max(width ?? 0, height ?? 0);

  @override
  String toString() => 'ImageProbe($format, ${width ?? '?'}x${height ?? '?'})';
}

/// 准备发给上游的图片：格式已确认、尺寸已落在限制内。
class ApiImage {
  const ApiImage(this.bytes, this.format);

  final Uint8List bytes;
  final String format;

  String get mediaType => 'image/$format';
}

/// 识别图片的真实格式与像素尺寸（只看文件头，不解码整张图）。
ImageProbe probeImage(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return _probeJpeg(bytes);
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return _probePng(bytes);
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return _probeGif(bytes);
  }
  if (bytes.length >= 16 &&
      _ascii(bytes, 0, 4) == 'RIFF' &&
      _ascii(bytes, 8, 4) == 'WEBP') {
    return _probeWebp(bytes);
  }
  if (bytes.length >= 12 && _ascii(bytes, 4, 4) == 'ftyp') {
    final brand = _ascii(bytes, 8, 4);
    if (brand == 'avif' || brand == 'avis') {
      return const ImageProbe('avif');
    }
    if (const {
      'heic',
      'heix',
      'hevc',
      'hevx',
      'heim',
      'heis',
      'mif1',
      'msf1',
    }.contains(brand)) {
      return const ImageProbe('heic');
    }
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return const ImageProbe('bmp');
  }
  if (bytes.length >= 4 &&
      ((bytes[0] == 0x49 &&
              bytes[1] == 0x49 &&
              bytes[2] == 0x2A &&
              bytes[3] == 0x00) ||
          (bytes[0] == 0x4D &&
              bytes[1] == 0x4D &&
              bytes[2] == 0x00 &&
              bytes[3] == 0x2A))) {
    return const ImageProbe('tiff');
  }
  return const ImageProbe('unknown');
}

/// 把图片处理成上游可接受的形态：
/// - 不支持的格式（HEIC/AVIF/BMP/TIFF…）返回 null，由调用方提示用户；
/// - 已在限制内：原字节返回，不改画质；
/// - 超过单边 8192px 或单图 12MB：按需缩到限制内再编码成 JPEG。
Future<ApiImage?> prepareImageForApi(Uint8List bytes) async {
  final probe = probeImage(bytes);
  if (!probe.supported) return null;

  final tooWide = probe.longestSide > apiImageMaxSide;
  final tooHeavy = bytes.length > apiImageMaxBytes;
  if (!tooWide && !tooHeavy) {
    return ApiImage(bytes, probe.format);
  }
  // 尺寸未知（罕见：文件头损坏）时不冒险解码，按原样发，交给上游判定。
  if (probe.width == null || probe.height == null) {
    return ApiImage(bytes, probe.format);
  }
  // 只是体积大、尺寸没超：缩到 4096 长边足够识别，又能显著减小上传体积。
  final maxSide = tooWide ? apiImageMaxSide : 4096;
  final scaled = await _resizeToJpeg(bytes, probe, maxSide);
  if (scaled == null) return null;
  return ApiImage(scaled, 'jpeg');
}

/// 把一个图片 data URL 整理成上游可接受的形式：
/// - 格式不支持（HEIC/AVIF…）或 base64 损坏：返回 null，由调用方跳过这张图；
/// - 已在限制内且声明的类型正确：原样返回，不重复编码；
/// - 超出限制 / 声明类型与内容不符：返回整理后的 data URL。
Future<String?> sanitizeImageDataUrl(String dataUrl) async {
  if (!dataUrl.startsWith('data:')) return null;
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return null;
  final meta = dataUrl.substring(5, comma);
  final semicolon = meta.indexOf(';');
  final declared = (semicolon >= 0 ? meta.substring(0, semicolon) : meta)
      .trim();
  final Uint8List bytes;
  try {
    bytes = base64Decode(dataUrl.substring(comma + 1));
  } catch (_) {
    return null;
  }
  final prepared = await prepareImageForApi(bytes);
  if (prepared == null) return null;
  if (identical(prepared.bytes, bytes) && prepared.mediaType == declared) {
    return dataUrl;
  }
  return 'data:${prepared.mediaType};base64,${base64Encode(prepared.bytes)}';
}

/// 缩放到 [maxSide] 长边并编码成 JPEG（只保留尺寸内的内容）。
Future<Uint8List?> _resizeToJpeg(
  Uint8List bytes,
  ImageProbe probe,
  int maxSide,
) async {
  final width = probe.width;
  final height = probe.height;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  final longest = math.max(width, height);
  final scale = math.min(1.0, maxSide / longest);
  final targetWidth = math.max(1, (width * scale).round());
  final targetHeight = math.max(1, (height * scale).round());

  ui.Codec? codec;
  ui.Image? decoded;
  try {
    codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    final frame = await codec.getNextFrame();
    decoded = frame.image;
    final decodedWidth = decoded.width;
    final decodedHeight = decoded.height;
    final rgba = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null || decodedWidth <= 0 || decodedHeight <= 0) return null;
    final raster = img.Image.fromBytes(
      width: decodedWidth,
      height: decodedHeight,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(raster, quality: 88));
  } catch (_) {
    return null;
  } finally {
    decoded?.dispose();
    codec?.dispose();
  }
}

ImageProbe _probeJpeg(Uint8List bytes) {
  var index = 2;
  while (index + 9 < bytes.length) {
    if (bytes[index] != 0xFF) {
      index++;
      continue;
    }
    final marker = bytes[index + 1];
    // SOI/TEM/RSTn 没有长度字段
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      index += 2;
      continue;
    }
    // EOI 或 SOS：后面是压缩数据，不再有 SOF
    if (marker == 0xD9 || marker == 0xDA) break;
    final length = (bytes[index + 2] << 8) | bytes[index + 3];
    if (length < 2) break;
    final isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      final height = (bytes[index + 5] << 8) | bytes[index + 6];
      final width = (bytes[index + 7] << 8) | bytes[index + 8];
      return ImageProbe('jpeg', width: width, height: height);
    }
    index += 2 + length;
  }
  return const ImageProbe('jpeg');
}

ImageProbe _probePng(Uint8List bytes) {
  // IHDR 固定是第一个块：宽度/高度各 4 字节大端
  if (bytes.length < 24 || _ascii(bytes, 12, 4) != 'IHDR') {
    return const ImageProbe('png');
  }
  final width =
      (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  final height =
      (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  return ImageProbe('png', width: width, height: height);
}

ImageProbe _probeGif(Uint8List bytes) {
  if (bytes.length < 10) return const ImageProbe('gif');
  final width = bytes[6] | (bytes[7] << 8);
  final height = bytes[8] | (bytes[9] << 8);
  return ImageProbe('gif', width: width, height: height);
}

ImageProbe _probeWebp(Uint8List bytes) {
  final chunk = _ascii(bytes, 12, 4);
  if (chunk == 'VP8 ' && bytes.length >= 30) {
    final width = ((bytes[26] | (bytes[27] << 8)) & 0x3FFF);
    final height = ((bytes[28] | (bytes[29] << 8)) & 0x3FFF);
    return ImageProbe('webp', width: width, height: height);
  }
  if (chunk == 'VP8L' && bytes.length >= 25) {
    final bits =
        bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    final width = (bits & 0x3FFF) + 1;
    final height = ((bits >> 14) & 0x3FFF) + 1;
    return ImageProbe('webp', width: width, height: height);
  }
  if (chunk == 'VP8X' && bytes.length >= 30) {
    final width = (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)) + 1;
    final height = (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)) + 1;
    return ImageProbe('webp', width: width, height: height);
  }
  return const ImageProbe('webp');
}

String _ascii(Uint8List bytes, int start, int length) {
  if (start + length > bytes.length) return '';
  return String.fromCharCodes(bytes, start, start + length);
}
