import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pffi;
import 'package:flutter/foundation.dart';

/// 网络路径（UNC / 映射网络驱动器）识别与卷身份工具。
///
/// ## 背景（2026-09-26 NAS 映射网络驱动器适配）
///
/// 部分用户把 SMB 共享目录映射成本地盘符（如 `Z:`）后把游戏库放在上面。
/// 项目原有实现只覆盖本地磁盘，在该场景下有三类系统性偏差：
///
/// 1. **盘符形态与 UNC 形态指向同一位置却不相等**
///    （`Z:\Games\X` vs `\\host\share\Games\X`）→ 排重失效、同卷判定失效
///    （本可原子 `rename` 的移动退化成跨卷 copy + delete，慢且可能因只读共享失败）。
/// 2. **映射盘离线/断连时 Win32 不抛 Dart 异常，而是返回 0/false** →
///    磁盘空间与存在性判定静默降级为「可用但未知」，把失败推到流程中段
///    （下载完成后才报空间不足 / 目录不存在）。
/// 3. **访问未就绪的盘会弹出系统「无磁盘」对话框并阻塞调用线程** →
///    在 UI isolate 上表现为「软件未响应」。
///
/// 本类集中提供上述能力的唯一实现，供 `PathNormalizer` / `PathValidator` /
/// `GameMoveService` / `WatchFolderService` / `LocalGameRegistry` 复用。
///
/// ## 降级原则
///
/// 所有 Win32 调用（kernel32 / mpr）失败时**一律返回中性结果**
/// （`false` / `null` / 原路径），调用方据此退回原有本地磁盘语义 ——
/// 即在非 Windows 或受限环境下，本类的行为等价于「全部按本地盘处理」，
/// **不引入任何本地磁盘路径的行为变化**。
class NetworkPath {
  NetworkPath._();

  // ==================== Win32 常量 ====================

  static const int _driveUnknown = 0;
  static const int _driveNoRootDir = 1;
  static const int _driveRemote = 4;

  /// `SetErrorMode`：关键错误不弹窗，直接返回失败（避免访问离线盘时阻塞线程）
  static const int _semFailCriticalErrors = 0x0001;
  static const int _semNoOpenFileErrorBox = 0x8000;

  /// `WNetGetUniversalNameW` 的 `UNIVERSAL_NAME_INFO_LEVEL`
  static const int _universalNameInfoLevel = 1;

  /// `WNetGetUniversalNameW` 缓冲不足
  static const int _errorMoreData = 234;

  // ==================== 动态库句柄 ====================

  static ffi.DynamicLibrary? _openLibrary(String name) {
    try {
      return ffi.DynamicLibrary.open(name);
    } catch (_) {
      return null;
    }
  }

  static final ffi.DynamicLibrary? _kernel32 = _openLibrary('kernel32.dll');
  static final ffi.DynamicLibrary? _mpr = _openLibrary('mpr.dll');

  // ==================== 长路径前缀 ====================

  /// 剥离 Windows 长路径前缀：
  /// - `\\?\UNC\host\share\x` → `\\host\share\x`
  /// - `\\?\C:\x` → `C:\x`
  ///
  /// 非长路径原样返回。应用自身从不生成该前缀，但用户/第三方工具可能带入。
  static String stripLongPathPrefix(String path) {
    if (path.isEmpty) return path;
    const uncPrefix = r'\\?\UNC\';
    if (path.length > uncPrefix.length &&
        path.toUpperCase().startsWith(uncPrefix.toUpperCase())) {
      return '\\\\${path.substring(uncPrefix.length)}';
    }
    const longPrefix = r'\\?\';
    if (path.startsWith(longPrefix)) {
      return path.substring(longPrefix.length);
    }
    return path;
  }

  // ==================== 卷根 / 卷身份 ====================

  /// 解析路径所属卷的根：
  /// - 盘符：`Z:\a\b` → `Z:\`
  /// - UNC：`\\host\share\a` → `\\host\share`
  ///
  /// 解析失败（相对路径 / 裸盘符 / 空）返回 null。
  static String? volumeRoot(String path) {
    if (path.isEmpty) return null;
    final p = stripLongPathPrefix(path.replaceAll('/', '\\'));
    final drive = RegExp(r'^([A-Za-z]:)(\\|$)').firstMatch(p);
    if (drive != null) return '${drive.group(1)!}\\';
    final unc = RegExp(r'^(\\\\[^\\]+\\[^\\]+)').firstMatch(p);
    if (unc != null) return unc.group(1);
    return null;
  }

  /// 是否为网络路径：UNC 共享，或映射到网络位置的盘符。
  static bool isNetwork(String path) {
    _suppressCriticalErrorDialogsOnce();
    if (path.isEmpty) return false;
    final p = stripLongPathPrefix(path.replaceAll('/', '\\'));
    if (p.startsWith(r'\\')) return true;
    final root = volumeRoot(p);
    if (root == null || root.startsWith(r'\\')) return false;
    return _isRemoteDrive(root);
  }

  /// 该路径是否位于「映射网络驱动器」盘符上（不含 UNC 形式）。
  static bool isMappedDrive(String path) {
    if (path.isEmpty) return false;
    final root = volumeRoot(path);
    if (root == null || root.startsWith(r'\\')) return false;
    return _isRemoteDrive(root);
  }

  /// 卷身份（用于同卷/同位置比较）：
  /// - 本地盘 → 盘符（`c:`）
  /// - 映射网络盘 → 解析出的 UNC 共享（`\\host\share`），解析失败回退盘符
  /// - UNC → 共享本身（`\\host\share`）
  ///
  /// 解析失败返回 null。
  static String? volumeIdentity(String path) {
    final root = volumeRoot(path);
    if (root == null) return null;
    if (root.startsWith(r'\\')) return root.toLowerCase();
    final unc = _driveUnc(root);
    return (unc ?? root).toLowerCase();
  }

  /// 把映射网络驱动器路径解析为 **UNC 等价路径**（非映射盘 / 解析失败时原值返回）。
  ///
  /// 用途：需要「位置无关」表达形式的场景 —— 例如写入注册表 `Run` 键的启动
  /// 命令：盘符在开机登录时可能尚未映射（或服务器未就绪），而 UNC 不依赖映射。
  /// 与 [canonicalizeVolume] 同实现，取此名以表达用途。
  static String toUniversalPath(String path) => canonicalizeVolume(path);

  /// 两个路径是否位于同一卷。任一无法解析 → 返回 false（保守按跨卷处理）。
  static bool isSameVolume(String a, String b) {
    final ia = volumeIdentity(a);
    final ib = volumeIdentity(b);
    if (ia == null || ib == null) return false;
    return ia == ib;
  }

  /// 将路径的卷前缀规范化为「位置无关」形态：
  /// 映射网络盘 `Z:\Games\X` → `\\host\share\Games\X`；其余原样返回。
  ///
  /// 用于让盘符形态与 UNC 形态在排重/比较时相等。
  /// **本地磁盘路径不做任何改写**（不会引入本地行为变化）。
  static String canonicalizeVolume(String path) {
    if (path.isEmpty) return path;
    final p = stripLongPathPrefix(path.replaceAll('/', '\\'));
    final root = volumeRoot(p);
    if (root == null || root.startsWith(r'\\')) return p;
    final unc = _driveUnc(root);
    if (unc == null) return p;
    // root 形如 `Z:\`，末位反斜杠保留作为分隔符
    return '$unc${p.substring(root.length - 1)}';
  }

  // ==================== 卷可达性 ====================

  /// 异步探测卷根是否可达（不阻塞调用方 isolate）。
  ///
  /// 网络盘离线时 `Directory(root).exists()` 会等待 SMB 超时；
  /// 这里用 [timeout] 兜底，超时按「不可达」处理 —— 调用方据此选择
  /// **保留**（而不是清理）用户数据。无法解析卷根时返回 true（不阻断流程）。
  static Future<bool> isVolumeReachableAsync(
    String path, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _suppressCriticalErrorDialogsOnce();
    final root = volumeRoot(path);
    if (root == null) return true;
    try {
      return await Directory(root)
          .exists()
          .timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  /// 同步探测卷根是否可达。
  ///
  /// ⚠️ 映射盘离线时可能阻塞 SMB 超时，**只允许在非 UI isolate 或已有
  /// 先验判断的场合使用**；UI 路径请用 [isVolumeReachableAsync]。
  static bool isVolumeReachableSync(String path) {
    _suppressCriticalErrorDialogsOnce();
    final root = volumeRoot(path);
    if (root == null) return true;
    try {
      return Directory(root).existsSync();
    } catch (_) {
      return false;
    }
  }

  // ==================== Win32 调用 ====================

  static bool _suppressed = false;

  /// `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX)`：
  /// 访问离线/未就绪的盘时**不弹系统对话框、不阻塞线程**，直接返回失败。
  /// 进程级设置，幂等，只生效一次；设置失败静默忽略。
  static void _suppressCriticalErrorDialogsOnce() {
    if (_suppressed) return;
    _suppressed = true;
    final k32 = _kernel32;
    if (k32 == null) return;
    try {
      final setErrorMode = k32.lookupFunction<
          ffi.Uint32 Function(ffi.Uint32),
          int Function(int)>('SetErrorMode');
      setErrorMode(_semFailCriticalErrors | _semNoOpenFileErrorBox);
    } catch (_) {
      // 非 Windows / 被安全策略拦截：忽略，退回默认行为
    }
  }

  static final Map<String, bool> _remoteDriveCache = {};

  /// 盘符是否为 DRIVE_REMOTE（映射网络驱动器）。结果按盘符缓存。
  static bool _isRemoteDrive(String driveRoot) {
    final forced = debugRemoteDrives;
    if (forced != null) {
      return forced.contains(driveRoot.substring(0, driveRoot.length - 1));
    }
    final key = driveRoot.toUpperCase();
    final cached = _remoteDriveCache[key];
    if (cached != null) return cached;
    final k32 = _kernel32;
    if (k32 == null) return false; // 动态库不可用：不缓存，保持「按本地盘处理」
    bool remote;
    try {
      final getDriveTypeW = k32.lookupFunction<
          ffi.Uint32 Function(ffi.Pointer<pffi.Utf16>),
          int Function(ffi.Pointer<pffi.Utf16>)>('GetDriveTypeW');
      final rootPtr = driveRoot.toNativeUtf16();
      try {
        final type = getDriveTypeW(rootPtr);
        // DRIVE_NO_ROOT_DIR / DRIVE_UNKNOWN：盘当前未挂载，**不缓存**
        //（映射盘可能随后才连接上，缓存 false 会永久误判为本地盘）
        if (type == _driveNoRootDir || type == _driveUnknown) return false;
        remote = type == _driveRemote;
      } finally {
        pffi.malloc.free(rootPtr);
      }
    } catch (_) {
      return false; // 调用异常：不缓存
    }
    _remoteDriveCache[key] = remote;
    return remote;
  }

  static final Map<String, (String?, DateTime)> _driveUncCache = {};

  /// 盘符 → UNC 共享（如 `Z:\` → `\\host\share`）。
  ///
  /// 非网络盘 / 解析失败返回 null。**成功值永久缓存**（映射关系在一段
  /// 会话内不会变，而该调用位于排重热路径上）；**失败值只缓存 5 秒** ——
  /// 🔴 2026-10-06 修复：旧实现把 null 也永久缓存，映射盘在某一瞬间
  /// （NAS 唤醒中 / Explorer 重连中）反查失败一次，本进程余生所有反查
  /// 都返回 null，访问端候选②（反查盘符）彻底失效 → 被判「离线」。
  ///
  /// ★ 2026-10-06 双通道：`WNetGetUniversalNameW` 在盘离线/服务器未就绪时
  /// 可能失败，而 `WNetGetConnectionW` 查询的是**本地注册连接表**，
  /// 断连的映射盘通常仍能返回其 UNC 目标 —— 保证「离线时导入映射盘游戏」
  /// 也能落盘 UNC 真路径（canonicalizeVolume 依赖本方法）。
  static String? _driveUnc(String driveRoot) {
    final key = driveRoot.toUpperCase();
    final override = debugDriveUncOverrides;
    if (override != null) return override[key];
    final cached = _driveUncCache[key];
    if (cached != null) {
      final (unc, at) = cached;
      if (unc != null ||
          DateTime.now().difference(at) < const Duration(seconds: 5)) {
        return unc;
      }
    }
    String? unc;
    if (_isRemoteDrive(driveRoot)) {
      unc = _uncFromDriveRoot(driveRoot) ?? _uncFromConnection(driveRoot);
    }
    _driveUncCache[key] = (unc, DateTime.now());
    return unc;
  }

  /// 仅供测试：强制视为 DRIVE_REMOTE 的盘符集合（如 `{'Z:'}`）。
  /// 非 null 时短路真实 `GetDriveTypeW` 探测；null = 走真实探测。
  @visibleForTesting
  static Set<String>? debugRemoteDrives;

  /// 仅供测试：强制盘符 → UNC 映射（键形如 `'Z:\\'`）。
  /// 非 null 时短路真实 WNet 解析；null = 走真实解析。
  @visibleForTesting
  static Map<String, String>? debugDriveUncOverrides;

  /// 查找当前映射到 [uncRoot]（形如 `\\host\share`）的本地盘符。
  ///
  /// 返回形如 `Z:` 的盘符（**不含**尾反斜杠）；找不到返回 null。
  /// 用途：存储的是 UNC 真路径时，访问端反查用户当前的盘符形态
  /// （盘符重映射 / 换机后自动跟随，无需改写存储数据）。
  static String? driveLetterForUncShare(String uncRoot) {
    if (uncRoot.isEmpty) return null;
    final target = uncRoot.replaceAll('/', '\\').toLowerCase();
    if (!target.startsWith(r'\\')) return null;
    for (var i = 0; i < 26; i++) {
      final letter = String.fromCharCode(0x41 + i); // 'A'..'Z'
      final unc = _driveUnc('$letter:\\');
      if (unc != null && unc.toLowerCase() == target) {
        return '$letter:';
      }
    }
    return null;
  }

  /// `WNetGetConnectionW`（mpr.dll）：查询本地设备名注册的网络资源名。
  ///
  /// 与 `WNetGetUniversalNameW` 的区别：只查**本地连接表**，不要求服务器
  /// 在线 —— 断连的映射盘通常仍能解析。失败返回 null。
  static String? _uncFromConnection(String driveRoot) {
    final mpr = _mpr;
    if (mpr == null) return null;
    try {
      final wnetGetConnectionW = mpr.lookupFunction<
          ffi.Uint32 Function(ffi.Pointer<pffi.Utf16>, ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint32>),
          int Function(ffi.Pointer<pffi.Utf16>, ffi.Pointer<pffi.Utf16>,
              ffi.Pointer<ffi.Uint32>)>('WNetGetConnectionW');

      // 入参是设备名 'Z:'（不带尾反斜杠）
      final localName = driveRoot.endsWith('\\') && driveRoot.length > 1
          ? driveRoot.substring(0, driveRoot.length - 1)
          : driveRoot;
      final localPtr = localName.toNativeUtf16();
      final sizePtr = pffi.malloc<ffi.Uint32>();
      // lpLength 以 wchar（字符）为单位，故按 Uint16 分配再 cast。
      // 🔴 Utf16 不是 SizedNativeType（ffi 2.1.3），直接 malloc<Utf16> 编译不过。
      var bufferSize = 1024;
      var rawBuf = pffi.malloc<ffi.Uint16>(bufferSize);
      try {
        sizePtr.value = bufferSize;
        var rc =
            wnetGetConnectionW(localPtr, rawBuf.cast<pffi.Utf16>(), sizePtr);
        if (rc == _errorMoreData) {
          final needed = sizePtr.value;
          if (needed > bufferSize) {
            pffi.malloc.free(rawBuf);
            bufferSize = needed;
            rawBuf = pffi.malloc<ffi.Uint16>(bufferSize);
          }
          sizePtr.value = bufferSize;
          rc = wnetGetConnectionW(localPtr, rawBuf.cast<pffi.Utf16>(), sizePtr);
        }
        if (rc != 0) return null;
        final name = rawBuf.cast<pffi.Utf16>().toDartString();
        return name.isEmpty ? null : name;
      } finally {
        pffi.malloc.free(localPtr);
        pffi.malloc.free(sizePtr);
        pffi.malloc.free(rawBuf);
      }
    } catch (e) {
      debugPrint('[NET-PATH] ⚠️ WNetGetConnectionW 解析失败($driveRoot): $e');
      return null;
    }
  }

  /// 仅供测试：清空盘符探测缓存与测试注入钩子
  @visibleForTesting
  static void debugClearCaches() {
    _remoteDriveCache.clear();
    _driveUncCache.clear();
    debugRemoteDrives = null;
    debugDriveUncOverrides = null;
  }

  /// `WNetGetUniversalNameW`（mpr.dll）把盘符路径解析为 UNC。
  ///
  /// 失败（未连接 / 非网络路径 / 动态库不可用）返回 null。
  static String? _uncFromDriveRoot(String driveRoot) {
    final mpr = _mpr;
    if (mpr == null) return null;
    try {
      final wnetGetUniversalNameW = mpr.lookupFunction<
          ffi.Uint32 Function(ffi.Pointer<pffi.Utf16>, ffi.Uint32,
              ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>),
          int Function(ffi.Pointer<pffi.Utf16>, int, ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Uint32>)>('WNetGetUniversalNameW');

      final localPtr = driveRoot.toNativeUtf16();
      final sizePtr = pffi.malloc<ffi.Uint32>();
      var bufferSize = 2048;
      var buffer = pffi.malloc<ffi.Uint8>(bufferSize);
      try {
        sizePtr.value = bufferSize;
        var rc = wnetGetUniversalNameW(localPtr, _universalNameInfoLevel,
            buffer.cast<ffi.Void>(), sizePtr);
        if (rc == _errorMoreData) {
          pffi.malloc.free(buffer);
          bufferSize = sizePtr.value;
          buffer = pffi.malloc<ffi.Uint8>(bufferSize);
          sizePtr.value = bufferSize;
          rc = wnetGetUniversalNameW(localPtr, _universalNameInfoLevel,
              buffer.cast<ffi.Void>(), sizePtr);
        }
        if (rc != 0) return null;
        final namePtr = buffer.cast<ffi.Pointer<pffi.Utf16>>().value;
        if (namePtr == ffi.nullptr) return null;
        final name = namePtr.toDartString();
        return name.isEmpty ? null : name;
      } finally {
        pffi.malloc.free(localPtr);
        pffi.malloc.free(sizePtr);
        pffi.malloc.free(buffer);
      }
    } catch (e) {
      debugPrint('[NET-PATH] ⚠️ WNetGetUniversalNameW 解析失败($driveRoot): $e');
      return null;
    }
  }
}
