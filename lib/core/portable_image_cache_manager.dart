import 'dart:io' show File;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../services/storage/cache_quota_service.dart';
import 'image_referer.dart';
import 'portable_file_system.dart';

/// 便携式网络图片缓存管理器。
///
/// 替代 [DefaultCacheManager]，将网络图片缓存（游戏封面、截图、元数据图片等）
/// 从系统盘 `Temp` 与 `AppData\Roaming` 重定向到软件安装目录：
/// - 缓存文件：`<安装目录>/data/cache/images/libCachedImageData/`
/// - 缓存元数据：`<安装目录>/data/cache/images/libCachedImageData.json`
///
/// cacheKey 沿用 `libCachedImageData`（与 DefaultCacheManager 一致），
/// 便于迁移时识别旧缓存目录。使用单例避免重复构造 Config。
///
/// 缓存策略：
/// - 最多 400 个缓存对象（放宽对象数，字节配额由 CacheQuotaService 兜底）
/// - 14 天过期清理（原 30 天）
/// - 字节配额：超 500MB 自动按最后使用时间淘汰至 400MB（CacheQuotaService）
class PortableImageCacheManager extends CacheManager with ImageCacheManager {
  static const String key = 'libCachedImageData';

  static final PortableImageCacheManager _instance =
      PortableImageCacheManager._();

  /// 元数据仓库（JsonCacheInfoRepository）。
  ///
  /// 提升为 static final 供 [CacheQuotaService] 读取全部缓存对象
  /// （url / relativePath / validTill / length / touched）做字节配额淘汰。
  /// 单例场景下 static 最稳，避免构造体内引用实例字段。
  static final JsonCacheInfoRepository _repo =
      JsonCacheInfoRepository.withFile(
    File(p.join(PathHelper.imageCacheDir, '${PortableImageCacheManager.key}.json')),
  );

  factory PortableImageCacheManager() => _instance;

  PortableImageCacheManager._()
      : super(
          Config(
            key,
            // 字节配额由 CacheQuotaService 兜底；此处适度放宽对象数减少
            // 小图无谓驱逐，stalePeriod 30→14 天加速清理长期未用项。
            maxNrOfCacheObjects: 400,
            stalePeriod: const Duration(days: 14),
            fileSystem: PortableFileSystem(key),
            repo: _repo,
            // 🔴 防盗链注入点（2026-11-04）：2Dfan 图床 `img.achost.top`
            // 是 Referer 白名单校验，不带 Referer 直接 404。所有
            // CachedNetworkImage / NsfwImage 都走这个 CacheManager，
            // 在这里统一补头即可，不必改十几个 UI 调用点。
            // 见 `image_referer.dart` 的实测证据表。
            fileService: _HotlinkAwareFileService(),
          ),
        ) {
    // 挂载字节配额自动淘汰（幂等；首次 60s 后 + 每 30min 一轮）。
    CacheQuotaService.instance.attach(this, _repo);
    try {
      // P2 内存优化：Flutter 内存图片缓存默认 100MB → 降到 64MB，
      // 降低高密度图集（库/探索网格同时挂载大量封面）的常驻内存，
      // 仅影响本进程全局，不落盘、不触发磁盘增删。try/catch 兜底防异常。
      PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024;
    } catch (e) {
      debugPrint('[ImageCache] 设置 maximumSizeBytes=64MB 失败: $e');
    }
  }
}

/// 会按 URL 自动补防盗链请求头（Referer / UA）的文件服务。
///
/// 只有 [ImageReferer] 表里登记过的图床才动，其余 URL **原样透传**，
/// 因此不会影响 VNDB / Steam / Bangumi 等已有图片加载行为。
class _HotlinkAwareFileService extends HttpFileService {
  /// 诊断日志计数：只打前 20 条，避免整页图集刷屏
  static int _logged = 0;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) {
    final extra = ImageReferer.headersFor(url);
    if (extra.isEmpty) return super.get(url, headers: headers);
    if (_logged < 20) {
      _logged++;
      debugPrint('[IMG] 防盗链注入 Referer=${extra['Referer']} ← $url');
    }
    // extra 放后面：防盗链 Referer 必须覆盖调用方传来的值
    return super.get(url, headers: {...?headers, ...extra});
  }
}
