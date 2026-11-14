import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/path_helper.dart';
import 'path_validator.dart';

/// ★ DL-CACHE-FOLLOW-INSTALL（2026-11-03）：下载缓存目录解析器。
///
/// ## 分工（用户 2026-11-03 明确定义）
///
/// - **游戏本体下载缓存**：跟随「用户选择的安装位置」。用户把游戏装到哪，缓存就
///   落在那里附近的 [folderName] 目录里，**不再往 exe 同级的 `downloads/` 堆**。
///   旧行为恰好坑到「因为软件所在盘不够才把游戏装到别的盘」的用户 —— 实测 14GB
///   的包把 D 盘写到 0 字节（`writeFrom ... errno = 112 磁盘空间不足`），下载
///   表现为「卡在 0 B/s、界面永远正在下载」。
/// - **软件自身资产（更新包等）**：仍用出厂目录 [PathHelper.defaultDownloadsDir]
///   （`exe/downloads`）。它只装 App 自己的东西，不再承载任何游戏安装包 ——
///   「downloads 里突然多出 15GB 游戏包」这类误会由此消除。
///
/// ## 游戏缓存的落点
///
/// 设「库根」= 安装位置的父目录（自定义安装 `E:\Games\SomeGame` → `E:\Games`；
/// 未自定义 → `exeDir`），则：
/// 1. `<库根>\ChronoTide_Cache\downloads`
/// 2. `<安装盘>:\ChronoTide_Cache\downloads`（库根不可写时的退路，如库根是只读共享）
/// 3. 出厂目录（宁可回到旧行为，也不让下载直接打不开）
///
/// 候选必须通过「可创建 + 真写 1 字节 + 剩余 ≥ [minFreeBytes]」三道探测。
/// 选择结果写回 [PathHelper.downloadsDirOverride]，`extract_manager`、
/// `storage_cleanup_service`、`global_install_center` 等既有消费者无需改动即可
/// 跟随；同时持久化到 [prefKey]，供**下次启动**的残留清理定位（否则换了盘的
/// `.part` 分片会永远留在用户硬盘上）。
class DownloadCacheDir {
  DownloadCacheDir._();

  /// 缓存根目录名（用户可直接看到并手动清理，名字本身就说明它是缓存）。
  static const String folderName = PathHelper.downloadCacheFolderName;

  /// 缓存根下的子目录名。
  static const String downloadsSubDir = 'downloads';

  /// 持久化键：上次实际使用的缓存目录。
  static const String prefKey = 'download_cache_dir';

  /// 持久化键：**历史**用过的缓存目录列表（最多 [maxKnownDirs] 个）。
  ///
  /// 必须记住历史：用户换一个盘装游戏，缓存目录就换一处；上一处若还留着失败
  /// 时保留下来的 `.part` 分片，就再没有流程会去管它 —— 几个 GB 的孤儿文件会
  /// 一直占着硬盘。
  static const String prefHistoryKey = 'download_cache_dir_history';

  static const int maxKnownDirs = 8;

  /// 进程内缓存的历史目录（启动时由 [restoreFromPrefsIfNeeded] 灌入）。
  static final List<String> _knownDirs = <String>[];

  /// 候选目录可接受的最低剩余空间（低于此值直接换候选）。
  static const int minFreeBytes = 512 * 1024 * 1024;

  static bool _restored = false;

  /// 当前生效的游戏下载缓存目录。
  static String get active => PathHelper.downloadsDir;

  /// 软件自身资产（App 更新包等）的缓存目录。
  ///
  /// 与游戏缓存**分家**：这里只放本程序自己的东西，永远不落游戏安装包。
  static String get appAssetsDir => PathHelper.defaultDownloadsDir;

  /// 启动期残留清理要扫描的目录：出厂目录 + 当前生效目录 + 历史目录（去重）。
  ///
  /// 必须全扫 —— 用户换过盘/换过安装位置后，旧位置上的半成品分片不会有
  /// 任何流程再去管它。
  static List<String> get scanDirs {
    final out = <String>[];
    for (final dir in [
      PathHelper.defaultDownloadsDir,
      PathHelper.downloadsDir,
      ..._knownDirs,
    ]) {
      final normalized = p.normalize(dir);
      if (!out.any((e) => p.equals(e, normalized))) out.add(normalized);
    }
    return out;
  }

  /// 该文件是否属于「由本程序托管、可安全删除」的下载缓存。
  ///
  /// 用途：解压成功后删原压缩包 —— 只删我们自己下到缓存里的，用户在本地磁盘
  /// 上自选的压缩包绝不能碰。判据是「落在当前生效缓存目录内」或「路径里带
  /// [folderName] 段」，两者任一即可（后者覆盖「本次没走 resolveFor 但确实是
  /// 我们上次下到缓存里的」情形）。
  static bool isManagedCachePath(String filePath) {
    final norm = p.normalize(filePath);
    final roots = <String>[
      PathHelper.downloadsDir,
      PathHelper.defaultDownloadsDir,
    ];
    for (final root in roots) {
      final nr = p.normalize(root);
      if (p.equals(nr, norm) || p.isWithin(nr, norm)) return true;
    }
    return p
        .split(norm)
        .any((seg) => seg.toLowerCase() == folderName.toLowerCase());
  }

  /// 启动期恢复上次选择的缓存目录（幂等；失败静默回退出厂目录）。
  ///
  /// 由 `InterruptCleanup` 在清理前调用，避免「换了盘的分片没人清」。
  static Future<void> restoreFromPrefsIfNeeded() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();

      // 历史目录先灌进来（与当前目录是否可恢复无关 —— 清理要用）。
      final history = prefs.getStringList(prefHistoryKey) ?? const <String>[];
      for (final h in history) {
        final normalized = p.normalize(h);
        if (!_knownDirs.any((e) => p.equals(e, normalized))) {
          _knownDirs.add(normalized);
        }
      }

      final saved = prefs.getString(prefKey);
      if (saved == null || saved.isEmpty) return;
      final normalized = p.normalize(saved);
      if (p.equals(normalized, PathHelper.defaultDownloadsDir)) return;
      if (!_probe(normalized)) {
        debugPrint('[DL-CACHE] ⚠️ 上次的缓存目录已不可用，回退出厂目录: $normalized');
        return;
      }
      PathHelper.downloadsDirOverride = normalized;
      debugPrint('[DL-CACHE] 下载缓存目录已恢复: $normalized');
    } catch (e) {
      debugPrint('[DL-CACHE] ⚠️ 恢复缓存目录失败: $e');
    }
  }

  /// 按「游戏安装位置」解析本次下载应使用的缓存目录，并写回全局。
  ///
  /// [installTargetDir] 为本体安装位置（用户自定义的**游戏目录本身**，如
  /// `E:\Games\SomeGame`）；为空表示走默认安装（`exe/Games/<游戏名>`）。
  ///
  /// 返回最终使用的目录（已确保存在）。
  static Future<String> resolveFor({String? installTargetDir}) async {
    final root = _libraryRootOf(installTargetDir);

    for (final candidate in _candidates(root)) {
      if (_probe(candidate) && await _hasRoom(candidate)) {
        await _apply(candidate);
        return PathHelper.downloadsDir;
      }
      debugPrint('[DL-CACHE] ⚠️ 候选缓存目录不可用，试下一个: $candidate');
    }

    debugPrint('[DL-CACHE] ⚠️ 安装位置所在的盘上没有可用缓存目录，'
        '回退出厂目录 ${PathHelper.defaultDownloadsDir}');
    await _apply(null);
    return PathHelper.downloadsDir;
  }

  /// 「库根」：自定义安装取安装位置的父目录，默认安装取出厂 exe 目录。
  static String _libraryRootOf(String? installTargetDir) {
    final target =
        (installTargetDir != null && installTargetDir.trim().isNotEmpty)
            ? p.normalize(installTargetDir.trim())
            : PathHelper.gamesDir;
    final parent = p.dirname(target);
    if (parent.isEmpty || p.equals(parent, target)) return PathHelper.exeDir;
    // 安装位置直接就在盘根（E:\SomeGame → E:\）时，父目录即盘根，天然可用。
    return parent;
  }

  /// 候选目录（按优先级）。库根优先 —— 缓存与游戏本体在一起，用户一眼能对上；
  /// 库根不可写时退到安装盘根。
  static List<String> _candidates(String root) {
    final out = <String>[];
    void add(String dir) {
      final normalized = p.normalize(dir);
      if (!out.any((e) => p.equals(e, normalized))) out.add(normalized);
    }

    add(p.join(root, folderName, downloadsSubDir));
    final drive = _driveOf(root);
    if (drive != null) add(p.join(drive, folderName, downloadsSubDir));
    return out;
  }

  /// 真实可写探测：建目录 → 写 1 字节 → 删掉，并校验剩余空间。
  ///
  /// 只判 `Directory.exists` 不够：受限目录（如盘根、只读共享）能解析路径但
  /// 写不进去，等到下载中途才失败是最坏的结果。
  ///
  /// 这里刻意用**同步** IO：都是字节级操作（`mkdir` + 写 1 字节 + `unlink`），
  /// 耗时在微秒级，卡主线程可忽略；而 `flutter_tester` 下异步
  /// `Directory.create(recursive: true)` 会永久挂起（event loop 抽干后进程静默
  /// 退出），探针根本测不到这段逻辑。见 `dev_probe/dl_cache_dir_probe.dart`。
  static bool _probe(String dir) {
    try {
      final directory = Directory(dir);
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final probe = File(p.join(dir, '.ct_write_probe'));
      probe.writeAsBytesSync(const [0], flush: true);
      try {
        probe.deleteSync();
      } catch (_) {}
      return true;
    } on FileSystemException catch (e) {
      debugPrint('[DL-CACHE] ⚠️ 候选目录不可写: $dir | ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[DL-CACHE] ⚠️ 候选目录探测异常: $dir | $e');
      return false;
    }
  }

  /// 剩余空间是否够用（[minFreeBytes]）。
  ///
  /// 与写入探测分开：查空间要走 FFI/平台调用，失败时应「按未知放行」而不是
  /// 把候选目录判死。
  static Future<bool> _hasRoom(String dir) async {
    try {
      final info = await PathValidator.getDiskSpaceInfo(dir);
      if (info.isAvailable &&
          info.freeSpaceBytes >= 0 &&
          info.freeSpaceBytes < minFreeBytes) {
        debugPrint('[DL-CACHE] ⚠️ 候选目录剩余空间过小'
            '（${PathValidator.formatFileSize(info.freeSpaceBytes)}）: $dir');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[DL-CACHE] ⚠️ 查询剩余空间失败（按未知放行）: $dir | $e');
      return true;
    }
  }

  /// 写回全局 + 持久化。[dir] 为 null 表示回退出厂目录。
  static Future<void> _apply(String? dir) async {
    _restored = true;
    final normalized = dir == null ? null : p.normalize(dir);
    PathHelper.downloadsDirOverride = normalized;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (normalized == null) {
        await prefs.remove(prefKey);
      } else {
        await prefs.setString(prefKey, normalized);
        // 历史列表：最近用过的排前面，超出上限的丢掉最旧的。
        final history = prefs.getStringList(prefHistoryKey) ?? <String>[];
        final next = <String>[
          normalized,
          ...history.where((e) => !p.equals(p.normalize(e), normalized)),
        ].take(maxKnownDirs).toList();
        await prefs.setStringList(prefHistoryKey, next);
        _knownDirs
          ..clear()
          ..addAll(next.map((e) => p.normalize(e)));
      }
    } catch (_) {
      // 持久化失败不影响本次下载（只影响下次启动的残留清理定位）
    }
    debugPrint('[DL-CACHE] 游戏下载缓存目录: ${PathHelper.downloadsDir}');
  }

  /// 删除托管缓存中的压缩包，并把变空的缓存目录一起收掉。
  ///
  /// 返回被删掉的字节数；`null` 表示「不属于托管缓存」或「文件不存在」——
  /// 两种情况都不该被当成清理失败。
  static Future<int?> deleteManagedArchive(String filePath) async {
    if (!isManagedCachePath(filePath)) return null;
    final file = File(filePath);
    if (!file.existsSync()) {
      await cleanupIfEmpty(p.dirname(filePath));
      return null;
    }
    final size = file.lengthSync();
    file.deleteSync();
    await cleanupIfEmpty(p.dirname(filePath));
    return size;
  }

  /// 删掉变空的缓存根（`<库根>/ChronoTide_Cache`），不留空壳目录。
  ///
  /// 只删「空的 [folderName] 目录本身及其空的 downloads 子目录」，递归删除一律
  /// 不做 —— 万一用户往里面放了东西，必须原样留着。
  static Future<void> cleanupIfEmpty([String? dir]) async {
    final target = dir ?? PathHelper.downloadsDir;
    try {
      final downloads = Directory(target);
      if (!downloads.existsSync()) return;
      if (downloads.listSync().isNotEmpty) return;
      downloads.deleteSync();
      debugPrint('[DL-CACHE] 🧹 已删除空缓存目录: $target');

      final root = p.dirname(target);
      if (p.basename(root).toLowerCase() != folderName.toLowerCase()) return;
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) return;
      if (rootDir.listSync().isNotEmpty) return;
      rootDir.deleteSync();
      debugPrint('[DL-CACHE] 🧹 已删除空缓存根: $root');
    } catch (e) {
      debugPrint('[DL-CACHE] ⚠️ 清理空缓存目录失败（忽略）: $e');
    }
  }

  /// `E:\xxx` → `E:\`；非盘符路径（UNC / 相对路径）返回 null。
  static String? _driveOf(String pathStr) {
    final match = RegExp(r'^([A-Za-z]):').firstMatch(pathStr.trim());
    if (match == null) return null;
    return '${match.group(1)!.toUpperCase()}:\\';
  }
}
