import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 内置头像池服务 —— 系统提供的 34 张插画头像的枚举 / 路径解析 / 随机抽取。
///
/// 设计文档：`docs/DEV/features/local_first_account_and_avatar_plan.md` §3.2 / §3.5。
///
/// 🔴 **只存 id（如 `av_07`），不存图片字节**：
/// ① prefs 只多 5 字节；② 能区分「内置头像」与「用户上传」（登录后据此判断是否
/// 需要上传）；③ 首启动 `createDefault()` 零 IO（不读 asset 字节，不阻塞首帧）。
///
/// 头像池内容通过 [ensureLoaded] 从 `AssetManifest` 动态列举（加图零改代码）。
/// 列举失败时退回 [fallbackIds] 常量表 —— 外部 API 不变，调用方无需感知。
class AvatarPresetService {
  AvatarPresetService._();

  /// 资源目录（pubspec 中按目录声明，Flutter 目录声明不递归）。
  static const String assetDir = 'assets/images/avatars';

  /// 素材统一为 webp（396–500px 方形，单张 10–95KB，34 张合计 ≈1.1MB）。
  static const String ext = '.webp';

  /// 兜底常量表的规模。与 `assets/images/avatars/` 实际文件数一致。
  static const int fallbackCount = 34;

  static List<String>? _ids;

  /// 兜底 id 表：`av_01` … `av_34`（与素材规范化命名完全一致）。
  ///
  /// `AssetManifest` 列不出内容时使用（P-01 的降级路径，见方案 §4.4）。
  static List<String> get fallbackIds => List<String>.generate(
        fallbackCount,
        (i) => 'av_${(i + 1).toString().padLeft(2, '0')}',
        growable: false,
      );

  /// 头像池 id 列表（**同步**可读）。未调用 [ensureLoaded] 时返回兜底常量表，
  /// 因此 `createDefault()` 可以在不 await 任何 IO 的前提下拿到可用池。
  static List<String> get ids => _ids ?? fallbackIds;

  /// 列举并缓存头像池（幂等，进程内只真正执行一次）。
  static Future<List<String>> ensureLoaded({AssetBundle? bundle}) async {
    final cached = _ids;
    if (cached != null) return cached;

    List<String> result;
    try {
      final manifest =
          await AssetManifest.loadFromAssetBundle(bundle ?? rootBundle);
      result = manifest
          .listAssets()
          .where((p) => p.startsWith('$assetDir/') && p.endsWith(ext))
          .map((p) =>
              p.substring(assetDir.length + 1, p.length - ext.length))
          .toList()
        ..sort();
      if (result.isEmpty) {
        debugPrint('[AVATAR-PRESET] ⚠️ assets 列举为空，回退常量表');
        result = fallbackIds;
      }
    } catch (e) {
      debugPrint('[AVATAR-PRESET] ⚠️ AssetManifest 列举失败，回退常量表: $e');
      result = fallbackIds;
    }
    _ids = List<String>.unmodifiable(result);
    debugPrint('[AVATAR-PRESET] 头像池就绪 | ${_ids!.length} 张');
    return _ids!;
  }

  /// id → 资源路径；空 id 返回空串（调用方据此走默认头像）。
  static String pathOf(String id) => id.isEmpty ? '' : '$assetDir/$id$ext';

  /// 该 id 是否在当前池内。
  static bool isValid(String id) => id.isNotEmpty && _idsOrFallback().contains(id);

  static List<String> _idsOrFallback() => _ids ?? fallbackIds;

  /// 随机抽一张，**必须排除 [current]**（否则用户点重抽看不到变化，会以为按钮坏了）。
  ///
  /// 池只有 1 张时只能返回它；`current` 不在池内（如自定义图上传过）时任意抽。
  static String randomExcept(String? current, {Random? random}) {
    final pool = ids;
    if (pool.isEmpty) return '';
    if (pool.length == 1) return pool.first;

    final cur = current ?? '';
    final rnd = random ?? Random();
    // 8 次随机尝试：34 张池子下「连续 8 次都抽到同一张」的概率约 1e-12。
    for (var i = 0; i < 8; i++) {
      final candidate = pool[rnd.nextInt(pool.length)];
      if (candidate != cur) return candidate;
    }
    // 确定性兜底，绝不进入循环等待。
    final idx = pool.indexOf(cur);
    return pool[(idx < 0 ? 0 : idx + 1) % pool.length];
  }

  /// 读取某张内置头像的原始字节（**有 IO**）。
  ///
  /// ⚠️ 只允许在「登录后上传云端头像」这类明确需要字节的路径调用。
  /// `LocalAccountService.createDefault()` **禁止**调用本方法（首帧卡顿，方案 R6）。
  static Future<Uint8List?> loadBytes(String id) async {
    final path = pathOf(id);
    if (path.isEmpty) return null;
    try {
      final data = await rootBundle.load(path);
      return data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      debugPrint('[AVATAR-PRESET] ⚠️ 读取内置头像失败 ($path): $e');
      return null;
    }
  }

  /// 仅供测试：清空列举缓存（配合自定义 [AssetBundle] 或隔离用例）。
  @visibleForTesting
  static void resetCacheForTest() => _ids = null;
}
