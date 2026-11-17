import 'dart:convert';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import 'models.dart';

/// “+”面板顶部的最近图片（官方可左右滑动的那条预览）。
class RecentImage {
  const RecentImage({
    required this.id,
    required this.asset,
    required this.thumb,
  });

  /// 资源 id（用于选中态去重）
  final String id;
  final AssetEntity asset;

  /// 缩略图字节（列表展示用）；读取失败时为 null，此时格子留空
  final Uint8List? thumb;
}

/// 最近图片的加载结果。
class RecentImagesResult {
  const RecentImagesResult({required this.images, required this.denied});

  final List<RecentImage> images;

  /// 相册权限被拒绝（用于提示重新授权）
  final bool denied;
}

/// 读取设备最近的图片（默认 60 张，按创建时间倒序）。
///
/// 未授权时会主动申请一次；被拒绝则返回 `denied: true`，由 UI 决定是否提示。
Future<RecentImagesResult> loadRecentImages({int limit = 60}) async {
  // 先触发系统授权弹窗；部分 Android 版本（14+）插件会误报 denied，
  // 因此不采信它的状态，改为以实际查询结果为准。
  await PhotoManager.requestPermissionExtend();
  await PhotoManager.setIgnorePermissionCheck(true);
  try {
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (albums.isEmpty) {
      return const RecentImagesResult(images: [], denied: false);
    }
    final assets = await albums.first.getAssetListRange(start: 0, end: limit);
    final images = <RecentImage>[];
    for (final asset in assets) {
      final thumb = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(240),
      );
      images.add(RecentImage(id: asset.id, asset: asset, thumb: thumb));
    }
    return RecentImagesResult(images: images, denied: false);
  } catch (_) {
    return const RecentImagesResult(images: [], denied: true);
  }
}

/// 把相册资源转成待发送附件：最长边压到 1568px 的 JPEG，避免整张原图 base64 过大。
Future<Attachment?> attachmentFromAsset(AssetEntity asset) async {
  final Uint8List? bytes = await asset.thumbnailDataWithSize(
    const ThumbnailSize.square(1568),
    quality: 88,
  );
  if (bytes == null || bytes.isEmpty) return null;
  return Attachment(
    path: 'asset:${asset.id}',
    dataUrl: 'data:image/jpeg;base64,${base64Encode(bytes)}',
  );
}

/// 打开系统设置页，便于用户重新授予相册权限。
Future<void> openGallerySettings() => PhotoManager.openSetting();
