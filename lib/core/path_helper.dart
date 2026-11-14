import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';

class PathHelper {
  static String? _exeDir;

  static String get exeDir {
    _exeDir ??= _resolveExeDir();
    return _exeDir!;
  }

  static String _resolveExeDir() {
    final exePath = Platform.resolvedExecutable;
    return File(exePath).parent.path;
  }

  /// 仅供单元测试：将 exeDir 指向临时目录，隔离磁盘写入
  ///
  /// 必须在任何路径 getter 被解析之前调用（因为 exeDir 首次访问后即缓存）。
  /// 传 null 可还原为自动解析。
  static set exeDirOverride(String? value) => _exeDir = value;

  // ========== Runtime 目录（外置工具统一存放） ==========
  static String get runtimeDir => path.join(exeDir, 'runtime');

  // --- Locale Emulator (LE) 转区工具 ---
  static String get localeEmulatorDir =>
      path.join(runtimeDir, 'locale_emulator');
  static String get leProcPath => path.join(localeEmulatorDir, 'LEProc.exe');
  static String get loaderDllPath =>
      path.join(localeEmulatorDir, 'LoaderDll.dll');
  static String get localeEmulatorDllPath =>
      path.join(localeEmulatorDir, 'LocaleEmulator.dll');
  static String get leCommonLibraryPath =>
      path.join(localeEmulatorDir, 'LECommonLibrary.dll');
  static String get leConfigPath =>
      path.join(localeEmulatorDir, 'LEConfig.xml');
  static String get leLangDir => path.join(localeEmulatorDir, 'Lang');

  // --- SDL3 手柄输入库 ---
  static String get sdl3Dir => path.join(runtimeDir, 'sdl3');
  static String get sdl3DllPath => path.join(sdl3Dir, 'SDL3.dll');

  // --- OpenList 文件服务器 ---
  static String get openlistDir => path.join(runtimeDir, 'openlist');
  static String get openlistExePath => path.join(openlistDir, 'openlist.exe');
  static String get openlistDataZipPath => path.join(openlistDir, 'data.zip');
  static String get openlistDataDir => path.join(openlistDir, 'data');
  static String get openlistConfigPath =>
      path.join(openlistDataDir, 'config.json');

  /// 新流程对接标记（0 字节文件）：`pair()` 成功后写入。
  /// 存在 = 该 OpenList 是用户通过应用内「对接」下载的新流程资产，
  /// 更新/迁移必须保留；缺失（但有 openlist.exe）= 旧版安装包硬内置遗留。
  static String get openlistProvisionMarkerPath =>
      path.join(openlistDir, '.provisioned');

  // --- OpenList 自动更新（2026-10-16）---
  // ⚠️ 状态文件刻意放在 `runtime/` 而非 `runtime/openlist/` 内：
  //    组件包整目录替换（openlist → openlist.old → 新目录）会连带清空
  //    `openlist/` 下的所有内容，状态若放在里面会在每次更新后丢失、
  //    导致「已应用版本」永远记不住 → 无限重复更新。
  /// 自动更新记账文件（已应用指纹 + 失败退避），与 `.provisioned` 职责分离
  static String get openlistProvisionStatePath =>
      path.join(runtimeDir, '.openlist_state.json');

  /// 组件包解压暂存目录（与 runtime/ 同卷 → 可原子改名切换）
  static String get openlistStagingDir =>
      path.join(runtimeDir, '.openlist_staging');

  /// 组件目录备份（切换前改名到此；成功后删除，失败回滚）
  static String get openlistBackupDir =>
      path.join(runtimeDir, '.openlist_backup');

  // --- 内置工具 ---
  static String get toolsDir => path.join(runtimeDir, 'tools');
  static String get bundled7zPath => path.join(toolsDir, '7z.exe');

  // --- CTFontHook 游戏字体替换载荷（2026-10-17）---
  // 与 Locale Emulator / Magpie 同族范式：由打包脚本部署到 runtime/，不入 assets。
  // 布局固定为 32bit/ 与 64bit/ 两个子目录（与 CTFontHook 的 dist 发布包一致）。
  static String get fontHookDir => path.join(runtimeDir, 'fonthook');
  static String get fontHookDll32Path =>
      path.join(fontHookDir, '32bit', 'winmm.dll');
  static String get fontHookDll64Path =>
      path.join(fontHookDir, '64bit', 'winmm.dll');

  /// 我方载荷元数据（**不是** CTFontHook 的文件，由打包脚本生成）
  static String get fontHookVersionFilePath =>
      path.join(fontHookDir, 'version.json');

  /// 本地「不兼容游戏清单」（Phase 4.3）。
  ///
  /// 随安装包内置（打包脚本从仓库 `resources/fonthook/incompatible.json` 复制而来），
  /// 供字体界面标注「已知有兼容性问题」的游戏。**只读**，不联网、不上报。
  /// 缺失时按「无清单」处理，不报错。
  static String get fontHookCompatFilePath =>
      path.join(fontHookDir, 'incompatible.json');

  /// 系统字体族枚举结果缓存（Phase 2，跨会话复用，避免每次进对话框都枚举）
  static String get systemFontsCacheFilePath =>
      path.join(dataDir, 'cache', 'system_fonts.json');

  // --- 后台服务 ---
  static String get scraperServicePath =>
      path.join(runtimeDir, 'scraper_service.exe');

  // ========== 应用数据目录（根级） ==========
  /// ★ DL-CACHE-FOLLOW-INSTALL（2026-11-03）：**软件自身资产**（App 更新包等）
  /// 的缓存目录，固定为 exe 同级的 `downloads/`。
  ///
  /// 这个目录从此只装本程序自己的东西：游戏安装包一律跟着用户的安装位置走
  /// （见 [downloadsDir]），不再往这里堆 —— 也就不会出现「软件的 downloads 里
  /// 莫名其妙多出十几个 GB 游戏包」这种误会。
  static String get defaultDownloadsDir => path.join(exeDir, 'downloads');

  /// ★ DL-CACHE-FOLLOW-INSTALL（2026-11-03）：**游戏本体下载缓存**的当前生效
  /// 目录，跟随「用户选择的安装位置」。
  ///
  /// 旧实现写死 exe 同级 `downloads/`：用户正是因为软件所在盘不宽裕才把游戏装
  /// 到别的盘，缓存却仍往 exe 盘写 —— 大文件下载必然把那块盘写满（实测 14GB
  /// 的包把 D 盘写到 0 字节，writeFrom 抛 errno 112）。
  ///
  /// 由 `DownloadCacheDir.resolveFor()` 在每次下载开始时按安装位置解析并设置
  /// （落到 `<安装位置父目录>/ChronoTide_Cache/downloads`），同时持久化到
  /// shared_preferences（`download_cache_dir`）供启动期清理复用。
  /// 取值 `null` = 解析失败回退出厂目录（下载不至于直接打不开）。
  static String? downloadsDirOverride;

  static String get downloadsDir => downloadsDirOverride ?? defaultDownloadsDir;
  static String get gamesDir => path.join(exeDir, 'Games');

  /// 是否为解压产生的临时层目录名。
  ///
  /// 临时层由 `ExtractManager` 生成，形如 `<本体>._temp_layer_<N>` 或
  /// `<本体>_temp_layer_<N>`（**数字结尾**）。启动清理／存储清理会递归删除命中
  /// 的目录，因此判据必须是「以 `_temp_layer_数字` 结尾」而不是
  /// `contains('_temp_layer_')` —— 后者会把名字里恰好含这个片段的真实游戏目录
  /// 一起删掉。
  static bool isTempLayerDirName(String name) =>
      _tempLayerDirPattern.hasMatch(name);

  static final RegExp _tempLayerDirPattern =
      RegExp(r'_temp_layer_\d+$', caseSensitive: false);

  /// 下载缓存根目录名（`<库根>/ChronoTide_Cache/downloads`）。
  ///
  /// 自定义安装选在 `Games/` 内时，缓存根会出现在 `Games/ChronoTide_Cache` ——
  /// 扫描器/迁移器必须显式跳过它，否则会被当成一个「没有 game.json 的游戏目录」。
  static const String downloadCacheFolderName = 'ChronoTide_Cache';

  static String get logsDir => path.join(exeDir, 'logs');
  static String get dataDir => path.join(exeDir, 'data');

  // ========== 便携式存储子目录（统一置于 data/ 下，不污染安装根目录） ==========
  // 所有应用产生的缓存/数据/图片均存放于此，避免占用系统 C 盘。
  static String get prefsDir => path.join(dataDir, 'prefs');
  static String get prefsFilePath =>
      path.join(prefsDir, 'shared_preferences.json');

  /// 游戏手柄适配的每游戏映射配置（独立文件，不触碰 game.json ⇒ 零 schema 迁移面）
  ///
  /// 键用 ADR-011 的稳定主键 game_id（UUID v4），不用 directoryPath（会被目录迁移改变）。
  static String get gamepadProfilesFilePath =>
      path.join(dataDir, 'gamepad_profiles.json');

  /// 手柄适配会话日志（原生层生命周期证据，排查断连用）
  static String get gamepadLogFilePath =>
      path.join(logsDir, 'gamepad_adaptation.log');

  static String get gameConfigsDir => path.join(dataDir, 'game_configs');
  static String get userThemesDir => path.join(dataDir, 'user_themes');
  static String get userBackgroundsDir =>
      path.join(dataDir, 'user_backgrounds');
  static String get imageCacheDir => path.join(dataDir, 'cache', 'images');

  // --- NSFW 局部检测（v2）---
  /// ONNX 模型释放目录：模型从 assets 释放到此处后由 worker isolate 读取。
  static String get modelsDir => path.join(dataDir, 'models');

  /// 图片级检测结果缓存（key → bbox 列表），见
  /// `docs/DEV/features/nsfw_filter_implementation_plan.md` §4.3。
  static String get nsfwDetectionsFilePath =>
      path.join(dataDir, 'cache', 'nsfw_detections.json');
  static String get portableTmpDir => path.join(dataDir, 'tmp');
  static String get lockDir => path.join(dataDir, 'lock');
  static String get lockFilePath =>
      path.join(lockDir, 'chrono_tide_instance.lock');
  static String get launchRequestDir =>
      path.join(lockDir, 'chrono_tide_launch_requests');
  static String get migrationDir => path.join(dataDir, 'migration');

  // ========== 安装目录可写性探针 ==========
  // 装在只读位置（如 Program Files）时返回 false，所有便携存储降级回系统目录。
  static bool? _portableWritable;

  /// 同步探针：在 dataDir 下创建并删除测试文件，结果缓存复用。
  /// 供 main.dart 顶层（无法 await）解析锁文件路径使用。
  ///
  /// ⚠️ 2026-09-26 NAS 适配：**网络位置（UNC / 映射网络驱动器）请勿调用本 getter**
  /// —— 盘离线时 `existsSync` / `createSync` 会同步阻塞在 SMB 超时上（数十秒），
  /// 而它通常在 `runApp` 之前求值。数据落点判定请用带超时的异步
  /// [isPortableWritable]；`main.dart` 已对网络位置短路，不会走到这里。
  static bool get isPortableWritableSync {
    if (_portableWritable != null) return _portableWritable!;
    return _probePortableWritableSync();
  }

  static bool _probePortableWritableSync() {
    try {
      final dir = Directory(dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File(path.join(dataDir, '.writable_test'));
      probe.writeAsStringSync('probe');
      probe.deleteSync();
      _portableWritable = true;
    } catch (_) {
      _portableWritable = false;
    }
    return _portableWritable!;
  }

  /// 网络位置的写探针超时（建目录 + 写 + 删，各一次 SMB 往返）
  static const Duration _networkProbeTimeout = Duration(seconds: 8);

  /// 异步探针：真实写探针 + 超时，结果缓存复用。
  ///
  /// 本地安装目录复用同步探针（与旧行为逐字一致）。
  ///
  /// ★ 2026-09-26 NAS 适配：网络位置改走**带超时的异步探针** ——
  /// ① 不在 UI isolate 上同步等待 SMB；② 盘离线 / 共享只读时如实返回 false，
  /// 让便携存储正确降级到系统目录（旧实现只有同步探针，离线时会先卡住
  /// 数十秒、再由异常降级）。
  static Future<bool> isPortableWritable() async {
    if (_portableWritable != null) return _portableWritable!;
    if (!NetworkPath.isNetwork(dataDir)) {
      return _probePortableWritableSync();
    }
    try {
      _portableWritable = await _probePortableWritableAsync()
          .timeout(_networkProbeTimeout, onTimeout: () => false);
    } catch (_) {
      _portableWritable = false;
    }
    return _portableWritable!;
  }

  /// 异步写探针。超时被外层截断后，本函数仍会在 IO 返回时清理测试文件。
  static Future<bool> _probePortableWritableAsync() async {
    File? probe;
    try {
      final dir = Directory(dataDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      probe = File(path.join(dataDir, '.writable_test'));
      await probe.writeAsString('probe', flush: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (probe != null && await probe.exists()) await probe.delete();
      } catch (_) {}
    }
  }

  /// 创建所有便携子目录（每步独立 try-catch，失败仅 debugPrint 不抛错）。
  static Future<void> ensurePortableDirs() async {
    final dirs = [
      prefsDir,
      gameConfigsDir,
      userThemesDir,
      userBackgroundsDir,
      imageCacheDir,
      portableTmpDir,
      lockDir,
      launchRequestDir,
      migrationDir,
    ];
    for (final d in dirs) {
      try {
        final dir = Directory(d);
        // ★ 2026-09-26 NAS 适配：改用异步 exists()，避免网络位置（UNC / 映射盘）
        // 上的同步往返阻塞 UI isolate。
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (e) {
        debugPrint('[PathHelper] 创建目录失败 $d: $e');
      }
    }
  }

  // ========== 辅助方法 ==========
  // .rar.lz4 解压：Dart 原生调用 bz.exe(Bandizip) 解 LZ4 外层 + UnRAR.exe 解 RAR 内层
  static String get bandizipExePath => path.join(toolsDir, 'bz.exe');
  static String get unrarExePath => path.join(toolsDir, 'UnRAR.exe');

  static String getDownloadFilePath(String fileName) {
    return path.join(downloadsDir, fileName);
  }

  static String getGameDir(String gameTitle) {
    final safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return path.join(gamesDir, safeName.isEmpty ? 'UnknownGame' : safeName);
  }

  static String getTempChunkPath(int chunkIndex) {
    return path.join(downloadsDir, '.chunk_$chunkIndex.tmp');
  }

  // ========== 归属判定（删除前的安全闸门） ==========
  /// 判断 [filePath] 是否位于应用自己管理的目录内。
  ///
  /// 用途：删除临时文件（如批量入库的封面缓存）前的守卫。
  /// 表单选封面（join_controller.pickCover）保存的是用户磁盘上原图的**绝对路径**，
  /// 该路径又可在单游戏表单与批量列表之间互传；
  /// 若不加判断直接 delete，会删掉用户桌面/图片目录里的原文件且不可恢复。
  ///
  /// 因此：**不在应用自有目录内的一律不删**。
  /// 代价是应用缓存内产生的临时封面可能残留（磁盘缓慢增长），
  /// 远优于删除用户文件。
  ///
  /// 比较使用 [PathNormalizer.forCompare]：绝对化 → 统一分隔符 → 折叠 `..`
  /// → 小写（Windows 不区分大小写）→ 去尾部斜杠，避免大小写/分隔符差异导致误判。
  static bool isInsideAppStorage(String filePath) {
    if (filePath.isEmpty) return false;
    final target = PathNormalizer.forCompare(filePath);
    if (target.isEmpty) return false;

    final roots = <String>[
      exeDir, // 覆盖 downloads / Games / logs / data 及其全部子目录
      dataDir, // 显式列出以防 exeDir 解析异常
      imageCacheDir,
      portableTmpDir,
      Directory.systemTemp.path, // CoverDownloadService 下载的封面落在系统 temp
    ];

    for (final root in roots) {
      final normalizedRoot = PathNormalizer.forCompare(root);
      if (normalizedRoot.isEmpty) continue;
      if (target == normalizedRoot || target.startsWith('$normalizedRoot\\')) {
        return true;
      }
    }
    return false;
  }
}
