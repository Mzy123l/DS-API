import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 归一化证书指纹：去空格、去冒号、转小写。
String normalizeFingerprint(String value) =>
    value.trim().toLowerCase().replaceAll(':', '').replaceAll(' ', '');

/// 构造 HTTP 客户端：配置了指纹时接受「指纹一致的自签名证书」。
///
/// 服务端用自签名证书（IP 直连没有域名），客户端按证书指纹校验，
/// 等价于证书固定：只有指纹匹配的连接才被接受，其他自签名证书一律拒绝。
/// 指纹为空时保持默认行为（只信任系统 CA），所以换成正式证书也不需要改代码。
///
/// 另外收紧连接复用：模型一次生成可能持续几分钟，这段时间存储请求的连接
/// 一直空闲；Android 上旧连接常被网络/NAT 静默断掉，之后一复用它就会报
/// `Software caused connection abort`。把空闲回收调短、并给连接建立设上限，
/// 下一次请求会重新建连。
http.Client buildPinnedHttpClient(String certSha256) {
  final inner = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 5);
  final pin = normalizeFingerprint(certSha256);
  if (pin.isNotEmpty) {
    inner.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == pin;
  }
  return IOClient(inner);
}
