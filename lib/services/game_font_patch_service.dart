// game_font_patch_service.dart
// L1 部署层：把 CTFontHook 的 winmm.dll 投放进游戏目录 / 还原 / 生成配置。
//
// 磁盘布局与 CTFontHook 原装安装器（`installer/main.cpp:591-744`）**逐字节一致**，
// 外加我方扩展键，保证两个工具互相认得出对方装过的游戏。
//
// 🔴 为什么不需要改启动链路：winmm.dll 躺在游戏 exe 同目录，
//    而游戏的工作目录正是 exe 所在目录（local_game_registry.dart 的 workDir），
//    Windows DLL 搜索顺序里「应用程序所在目录」优先 ⇒ 无论进程由谁创建
//    （Dart Process.start / cmd 回退 / LEProc / Magpie / 托盘），代理都会加载。
//    Phase 0 V1 已在真实 Windows 上实测证实。
//
// 本文件**不**触碰任何既有启动链路的 spawn 落点（见方案 §8.3）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
// 用已是直接依赖的 pointycastle（项目内 enc/ 已在用），避免为一次
// 指纹计算新增 crypto 依赖（pubspec.yaml 本期零改动）。
import 'package:pointycastle/export.dart' show SHA256Digest;

import '../core/path_helper.dart';
import '../models/game_font_override.dart';
import 'font_hook_ini_codec.dart';
import 'win32_process_service.dart';

/// 补丁状态。
enum PatchState {
  /// 无 manifest（可能连 winmm.dll 都没有）
  notInstalled,

  /// 有 manifest 且 `ManagedBy=Chrono_Tide` ⇒ 由本管理器安装
  installedByUs,

  /// 有 manifest 但无 `ManagedBy` ⇒ 由 CTFontHook 原生工具安装（互认）
  installedByExternal,

  /// 有 manifest 但关键文件缺失/尺寸不符 ⇒ 补丁残缺
  staleOrDamaged,
}

/// `probe()` 的结果：只读，无副作用。
class PatchProbeResult {
  final PatchState state;
  final ManifestInfo? manifest;

  /// 游戏目录下是否存在 `winmm.dll`
  final bool winmmPresent;
  final int winmmSize;

  /// 游戏目录下是否存在 `FontHook.ini`
  final bool iniPresent;

  /// 该目录下是否有进程正在运行（游戏运行中禁止写）
  final bool running;

  /// 目录是否可写（预检，避免装到 Program Files 才失败）
  final bool dirWritable;

  /// 人类可读的细节（用于 UI 状态区）
  final String detail;

  const PatchProbeResult({
    required this.state,
    this.manifest,
    this.winmmPresent = false,
    this.winmmSize = 0,
    this.iniPresent = false,
    this.running = false,
    this.dirWritable = true,
    this.detail = '',
  });

  bool get installed => state != PatchState.notInstalled;

  @override
  String toString() =>
      'PatchProbeResult($state, winmm=$winmmPresent/$winmmSize, ini=$iniPresent, '
      'running=$running, writable=$dirWritable)';
}

/// 载荷（`runtime/fonthook/`）可用性。
class FontHookPayloadStatus {
  final bool ready;

  /// 实际使用的载荷根目录
  final String root;

  /// `version.json` 里的版本号（读不到则为空）
  final String version;

  /// 是否走了开发态回退（非打包部署目录）
  final bool devFallback;

  /// 未就绪时的人类可读原因
  final String message;

  const FontHookPayloadStatus({
    required this.ready,
    required this.root,
    this.version = '',
    this.devFallback = false,
    this.message = '',
  });
}

/// 面向 UI 的异常（message 可直接展示给用户）。
class FontPatchException implements Exception {
  final String message;
  final String? detail;
  const FontPatchException(this.message, {this.detail});

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

class GameFontPatchService {
  GameFontPatchService._();

  /// 投放产物名固定为 `winmm.dll`（CTFontHook README:11 / ADR-0002，同名代理劫持的硬要求）。
  static const String dllFileName = 'winmm.dll';

  // ═══════════════════════════════════════════════════════════
  // 载荷定位
  // ═══════════════════════════════════════════════════════════

  static FontHookPayloadStatus? _payloadCache;

  /// 清缓存（测试 / 载荷重新部署后调用）。
  static void resetPayloadCache() => _payloadCache = null;

  static FontHookPayloadStatus payloadStatus({bool refresh = false}) {
    if (!refresh && _payloadCache != null) return _payloadCache!;
    _payloadCache = _resolvePayload();
    return _payloadCache!;
  }

  static FontHookPayloadStatus _resolvePayload() {
    // ① 发布态唯一路径：打包脚本部署的 runtime/fonthook/
    if (_isPayloadReadyAt(PathHelper.fontHookDir)) {
      return FontHookPayloadStatus(
        ready: true,
        root: PathHelper.fontHookDir,
        version: _readPayloadVersion(PathHelper.fontHookDir),
      );
    }

    // ② 开发态回退：`flutter run` 时 runtime/ 尚未部署。
    //    仅 debug 构建生效，绝不影响发布包行为。
    if (kDebugMode) {
      final dev = _findDevPayloadRoot();
      if (dev != null) {
        return FontHookPayloadStatus(
          ready: true,
          root: dev,
          version: _readPayloadVersion(dev),
          devFallback: true,
          message: '开发态载荷（未打包）',
        );
      }
    }

    return const FontHookPayloadStatus(
      ready: false,
      root: '',
      message: '字体组件未就绪（缺少 runtime/fonthook/32bit|64bit/winmm.dll）',
    );
  }

  static bool _isPayloadReadyAt(String root) {
    return File(path.join(root, '32bit', dllFileName)).existsSync() &&
        File(path.join(root, '64bit', dllFileName)).existsSync();
  }

  static String _readPayloadVersion(String root) {
    try {
      final f = File(path.join(root, 'version.json'));
      if (!f.existsSync()) return '';
      // 兼容带 BOM 的写盘方式（打包脚本用 .NET 无 BOM 写，但手工放置的可能是 BOM）
      final text = FontHookIniCodec.decodeWithBomStripped(f.readAsBytesSync());
      final j = jsonDecode(text);
      if (j is Map && j['version'] != null) return j['version'].toString();
    } catch (_) {}
    return '';
  }

  /// 开发态：从当前 exe 向上找 `FontHook/CTFontHook/dist/` 下最新的发布包。
  ///
  /// 只在 [kDebugMode] 下被调用。找不到返回 null（不影响发布态）。
  static String? _findDevPayloadRoot() {
    try {
      var dir = Directory(PathHelper.exeDir);
      for (var i = 0; i < 8; i++) {
        final distDir = Directory(
            path.join(dir.path, 'FontHook', 'CTFontHook', 'dist'));
        if (distDir.existsSync()) {
          final candidates = distDir
              .listSync()
              .whereType<Directory>()
              .where((d) => _isPayloadReadyAt(d.path))
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
          if (candidates.isNotEmpty) return candidates.first.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}
    return null;
  }

  /// 把某个 CTFontHook 发布包（含 `32bit/`、`64bit/`）部署到我方载荷目录。
  ///
  /// 供**打包脚本**与**开发/测试**使用；应用运行时不会自行下载载荷。
  static Future<FontHookPayloadStatus> preparePayloadFrom(
    String srcDistDir, {
    String? targetDir,
  }) async {
    final target = targetDir ?? PathHelper.fontHookDir;
    for (final sub in ['32bit', '64bit']) {
      final src = File(path.join(srcDistDir, sub, dllFileName));
      if (!src.existsSync()) {
        throw FontPatchException('载荷源缺少 $sub/$dllFileName',
            detail: src.path);
      }
      final dst = File(path.join(target, sub, dllFileName));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
    }
    // 生成本项目自己的 version.json（不是 CTFontHook 的文件）
    final vj = File(path.join(target, 'version.json'));
    await vj.parent.create(recursive: true);
    final payload = {
      'upstream': 'CTFontHook',
      'version': _guessVersionFromDirName(srcDistDir),
      'obtained_at': DateTime.now().toIso8601String(),
      'license': 'MIT',
      'dll': {
        '32bit': await _fingerprint(path.join(target, '32bit', dllFileName)),
        '64bit': await _fingerprint(path.join(target, '64bit', dllFileName)),
      },
    };
    await vj.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    resetPayloadCache();
    return payloadStatus(refresh: true);
  }

  static String _guessVersionFromDirName(String dir) {
    final name = path.basename(dir); // 例：CTFontHook-0.1.1-20261016-2056
    final m = RegExp(r'^[A-Za-z]+-(\d+\.\d+(?:\.\d+)?)').firstMatch(name);
    return m?.group(1) ?? name;
  }

  static Future<Map<String, dynamic>> _fingerprint(String filePath) async {
    final f = File(filePath);
    if (!f.existsSync()) return {'size': 0, 'sha256': ''};
    final bytes = await f.readAsBytes();
    return {
      'size': bytes.length,
      'sha256': SHA256Digest()
          .process(bytes)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
    };
  }

  // ═══════════════════════════════════════════════════════════
  // PE 架构识别（只读文件头，绝不把整个 exe 读进内存）
  // ═══════════════════════════════════════════════════════════

  /// 只读前 4 KB 判断 exe 架构。
  ///
  /// ⚠️ 刻意**不复用** `LocaleService.detectPeArchitecture`：后者用
  /// `readAsBytesSync()` 把整个 exe 读进内存（`locale_service.dart:79`），
  /// 对 1 GB 的 exe 是 ~1 GB 峰值。此处不动既有方法，只提供只读头部的新实现。
  static PeArch detectPeArchFromHeader(String exePath) {
    RandomAccessFile? raf;
    try {
      final f = File(exePath);
      if (!f.existsSync()) return PeArch.unknown;
      if (f.lengthSync() < 64) return PeArch.unknown;

      raf = f.openSync();
      final head = raf.readSync(4096);
      if (head.length < 64) return PeArch.unknown;

      final bd = ByteData.sublistView(head);
      final peOffset = bd.getUint32(0x3C, Endian.little);
      if (peOffset + 6 > head.length) return PeArch.unknown;
      if (head[peOffset] != 0x50 ||
          head[peOffset + 1] != 0x45 ||
          head[peOffset + 2] != 0x00 ||
          head[peOffset + 3] != 0x00) {
        return PeArch.unknown;
      }
      final machine = bd.getUint16(peOffset + 4, Endian.little);
      if (machine == 0x014C) return PeArch.x86;
      if (machine == 0x8664) return PeArch.x64;
      return PeArch.unknown;
    } catch (_) {
      return PeArch.unknown;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// 架构 → CTFontHook 的 DLL 子目录名（`32bit` / `64bit`）。
  static String archSubDir(PeArch arch) {
    switch (arch) {
      case PeArch.x86:
        return '32bit';
      case PeArch.x64:
        return '64bit';
      case PeArch.unknown:
        return '';
    }
  }

  // ═══════════════════════════════════════════════════════════
  // probe
  // ═══════════════════════════════════════════════════════════

  static File _iniFile(String gameDir) =>
      File(path.join(gameDir, FontHookIniCodec.iniFileName));
  static Directory _bakDir(String gameDir) =>
      Directory(path.join(gameDir, FontHookIniCodec.backupDirName));
  static File _manifestFile(String gameDir) =>
      File(path.join(_bakDir(gameDir).path, FontHookIniCodec.manifestFileName));
  static File _dllFile(String gameDir) => File(path.join(gameDir, dllFileName));

  /// 只读探测某个游戏目录的补丁状态。无任何副作用。
  static PatchProbeResult probe(String gameDir, {String? exePath}) {
    if (gameDir.isEmpty || !Directory(gameDir).existsSync()) {
      return const PatchProbeResult(
          state: PatchState.notInstalled, detail: '游戏目录不存在');
    }

    final dll = _dllFile(gameDir);
    final ini = _iniFile(gameDir);
    final manifest = _manifestFile(gameDir);

    final winmmPresent = dll.existsSync();
    final winmmSize = winmmPresent ? dll.lengthSync() : 0;
    final iniPresent = ini.existsSync();
    final running = Win32ProcessService.getProcessesInDirectory(gameDir).isNotEmpty;
    final writable = checkDirWritable(gameDir);

    if (!manifest.existsSync()) {
      return PatchProbeResult(
        state: PatchState.notInstalled,
        winmmPresent: winmmPresent,
        winmmSize: winmmSize,
        iniPresent: iniPresent,
        running: running,
        dirWritable: writable,
        detail: winmmPresent ? '目录内已有 winmm.dll（非本工具安装）' : '未安装',
      );
    }

    ManifestInfo? info;
    try {
      final text = FontHookIniCodec.decodeWithBomStripped(
          manifest.readAsBytesSync());
      info = FontHookIniCodec.parseManifest(text);
    } catch (_) {
      info = null;
    }

    if (!winmmPresent) {
      return PatchProbeResult(
        state: PatchState.staleOrDamaged,
        manifest: info,
        winmmPresent: false,
        iniPresent: iniPresent,
        running: running,
        dirWritable: writable,
        detail: '有安装记录但 winmm.dll 缺失（可能被游戏更新覆盖或手动删除）',
      );
    }

    final state = (info?.managedByUs ?? false)
        ? PatchState.installedByUs
        : PatchState.installedByExternal;
    return PatchProbeResult(
      state: state,
      manifest: info,
      winmmPresent: true,
      winmmSize: winmmSize,
      iniPresent: iniPresent,
      running: running,
      dirWritable: writable,
      detail: state == PatchState.installedByUs
          ? '由时汐字体器安装'
          : '由 CTFontHook 原工具安装',
    );
  }

  /// 目录可写性预检：建一个临时文件再删掉。
  ///
  /// 不接受「用 `File.writeAsString` 试写真实目标名」的做法——
  /// 那会污染游戏目录。
  static bool checkDirWritable(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return false;
      final probe = File(path.join(dir, '.ctlib_write_probe.tmp'));
      probe.writeAsStringSync('1', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // install / uninstall
  // ═══════════════════════════════════════════════════════════

  /// 安装补丁（投放 DLL + 备份原文件 + 写 manifest）。**不写 FontHook.ini**，
  /// 配置文件由 [writeConfig] 单独负责（职责分离，便于「只改配置不重装」）。
  ///
  /// 失败一律抛 [FontPatchException]，message 可直接展示。
  static Future<PatchProbeResult> install(
    String gameDir, {
    required String exePath,
  }) async {
    final payload = payloadStatus();
    if (!payload.ready) {
      throw FontPatchException(payload.message);
    }

    final dir = Directory(gameDir);
    if (!dir.existsSync()) {
      throw const FontPatchException('游戏目录不存在');
    }

    // ① 架构必须可识别（Phase 0 V4：错配是「静默无效果」，比崩溃更隐蔽）
    final arch = detectPeArchFromHeader(exePath);
    if (arch == PeArch.unknown) {
      throw const FontPatchException('无法识别该启动程序的架构（仅支持 32/64 位程序）');
    }
    final sub = archSubDir(arch);
    final srcDll = File(path.join(payload.root, sub, dllFileName));
    if (!srcDll.existsSync()) {
      throw FontPatchException('字体组件缺少 $sub/$dllFileName',
          detail: payload.root);
    }

    // ② 已装过则拒绝（与原工具同语义：必须先卸载/还原）
    if (_manifestFile(gameDir).existsSync()) {
      throw const FontPatchException('该游戏已安装字体补丁，请先还原再重新安装');
    }

    // ③ 游戏运行中禁止写（Phase 0 V7：已加载的 DLL 覆盖/删除都会失败）
    if (Win32ProcessService.getProcessesInDirectory(gameDir).isNotEmpty) {
      throw const FontPatchException('游戏正在运行，请先关闭游戏');
    }

    // ④ 可写性预检（Phase 0 V8：Program Files 会以错误码 5 失败）
    if (!checkDirWritable(gameDir)) {
      throw const FontPatchException(
          '无法写入游戏目录（可能位于 Program Files 等受保护位置），'
          '可尝试以管理员身份运行管理器');
    }

    final bakDir = _bakDir(gameDir);
    final backupSub = Directory(path.join(bakDir.path, 'backup'));
    final dll = _dllFile(gameDir);
    final ini = _iniFile(gameDir);

    final hadWinmm = dll.existsSync();
    final hadIni = ini.existsSync();

    try {
      await backupSub.create(recursive: true);

      // ⑤ 备份原文件（存在才备份，与原工具 `DoInstall` 一致）
      if (hadWinmm) {
        await dll.copy(path.join(backupSub.path, dllFileName));
      }
      if (hadIni) {
        await ini.copy(path.join(backupSub.path, FontHookIniCodec.iniFileName));
      }

      // ⑥ 投放
      await srcDll.copy(dll.path);

      // ⑦ 写 manifest（UTF-16LE + BOM，含我方扩展键）
      final sha = await _sha256Of(dll.path);
      final bytes = FontHookIniCodec.buildManifestBytes(
        installedAt: _nowStamp(),
        dllArch: sub,
        hadWinmm: hadWinmm,
        hadIni: hadIni,
        dllSha256: sha,
      );
      await _manifestFile(gameDir).writeAsBytes(bytes, flush: true);
    } on FileSystemException catch (e) {
      // 回滚：删掉半成品，避免留下「有 .CTFontHook 但没 manifest」的脏状态
      await _safeRollbackInstall(gameDir, hadWinmm: hadWinmm, hadIni: hadIni);
      throw FontPatchException('写入游戏目录失败', detail: e.osError?.message ?? e.message);
    }

    return probe(gameDir, exePath: exePath);
  }

  static Future<void> _safeRollbackInstall(
    String gameDir, {
    required bool hadWinmm,
    required bool hadIni,
  }) async {
    try {
      final bak = _bakDir(gameDir);
      final backupSub = Directory(path.join(bak.path, 'backup'));
      final dll = _dllFile(gameDir);
      final ini = _iniFile(gameDir);

      if (hadWinmm) {
        final b = File(path.join(backupSub.path, dllFileName));
        if (b.existsSync()) await b.copy(dll.path);
      } else if (dll.existsSync()) {
        await dll.delete();
      }
      if (hadIni) {
        final b = File(path.join(backupSub.path, FontHookIniCodec.iniFileName));
        if (b.existsSync()) await b.copy(ini.path);
      }
      if (bak.existsSync()) await bak.delete(recursive: true);
    } catch (_) {
      // 回滚失败只能留给用户手动处理，不掩盖原始异常
    }
  }

  /// 卸载：还原/删除 `winmm.dll`，按原文件存在性还原 `FontHook.ini`，
  /// 清空 `.CTFontHook`。
  ///
  /// 🔴 与原工具一致：**`FontHook.ini` 若是本工具生成的则保留**（内含玩家设置），
  /// 只有「游戏原本就有该文件」时才从备份还原。
  static Future<PatchProbeResult> uninstall(String gameDir) async {
    final manifest = _manifestFile(gameDir);
    if (!manifest.existsSync()) {
      throw const FontPatchException('该游戏没有安装记录，无法还原');
    }

    if (Win32ProcessService.getProcessesInDirectory(gameDir).isNotEmpty) {
      throw const FontPatchException('游戏正在运行，请先关闭游戏');
    }

    final bak = _bakDir(gameDir);
    final backupSub = Directory(path.join(bak.path, 'backup'));
    final dll = _dllFile(gameDir);
    final ini = _iniFile(gameDir);

    ManifestInfo? info;
    try {
      info = FontHookIniCodec.parseManifest(
          FontHookIniCodec.decodeWithBomStripped(manifest.readAsBytesSync()));
    } catch (_) {
      info = null;
    }

    final hadWinmm = info?.hadWinmm ?? false;
    final hadIni = info?.hadIni ?? false;

    try {
      // winmm.dll：原本存在 → 还原；否则删除
      if (hadWinmm) {
        final b = File(path.join(backupSub.path, dllFileName));
        if (b.existsSync()) {
          await b.copy(dll.path);
        } else if (dll.existsSync()) {
          await dll.delete();
        }
      } else if (dll.existsSync()) {
        await dll.delete();
      }

      // FontHook.ini：原本存在 → 还原；否则**保留**（内含玩家设置）
      if (hadIni) {
        final b = File(path.join(backupSub.path, FontHookIniCodec.iniFileName));
        if (b.existsSync()) {
          await b.copy(ini.path);
        }
      }

      await bak.delete(recursive: true);
    } on FileSystemException catch (e) {
      throw FontPatchException('还原失败', detail: e.osError?.message ?? e.message);
    }

    return probe(gameDir);
  }

  // ═══════════════════════════════════════════════════════════
  // 配置读写
  // ═══════════════════════════════════════════════════════════

  /// 生成并写入 `<游戏目录>/FontHook.ini`（UTF-8 带 BOM）。
  ///
  /// - [existingText] 为 null 时会从磁盘自行读取，以执行「读-改-写」，
  ///   保留我方不管理的高级键。
  /// - 🔴 拒绝在 `fontName` 为空时写盘：空 `FontNameW` 会让 CTFontHook 的
  ///   `LoadConfig` 直接失败（配置整体不生效），是比「没配置」更糟的状态。
  static Future<void> writeConfig(
    String gameDir,
    GameFontOverride cfg, {
    String? existingText,
    bool checkRunning = true,
  }) async {
    if (!cfg.hasFont) {
      throw const FontPatchException('尚未选择字体，无法写入配置');
    }
    if (checkRunning &&
        Win32ProcessService.getProcessesInDirectory(gameDir).isNotEmpty) {
      throw const FontPatchException('游戏正在运行，请先关闭游戏');
    }

    String? existing = existingText;
    final ini = _iniFile(gameDir);
    if (existing == null && ini.existsSync()) {
      try {
        existing = FontHookIniCodec.decodeWithBomStripped(ini.readAsBytesSync());
      } catch (_) {
        existing = null;
      }
    }

    final bytes = FontHookIniCodec.buildIniBytes(cfg, existingText: existing);
    await ini.parent.create(recursive: true);
    await ini.writeAsBytes(bytes, flush: true);
  }

  /// 读取 `<游戏目录>/FontHook.ini` 并解析。
  ///
  /// 解析不出（缺 `FontNameW`）返回 null ⇒ 调用方按「未配置」处理，
  /// **不要**据此覆盖原文件（避免抹掉用户的设置）。
  static GameFontOverride? readConfig(String gameDir) {
    final ini = _iniFile(gameDir);
    if (!ini.existsSync()) return null;
    try {
      final text = FontHookIniCodec.decodeWithBomStripped(ini.readAsBytesSync());
      final parsed = FontHookIniCodec.parseIni(text);
      if (parsed == null) return null;
      // 补上 manifest 才有的信息（架构 / 归属）
      final p = probe(gameDir);
      return parsed.copyWith(
        dllArch: p.manifest?.dllArch ?? '',
        managedByUs: p.manifest?.managedByUs ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 「打开游戏内字体面板」（高级项兜底）
  // ═══════════════════════════════════════════════════════════

  /// 带着 `CTFONTHOOK_SHOW_PICKER=1` 启动游戏，强制弹出游戏内字体面板。
  ///
  /// ⚠️ 刻意**不**复用既有启动链（`executeLaunch`）：那需要给多个签名加
  /// 环境变量透传参数，属侵入式改动。这里自行 spawn，代价是这次启动
  /// **不记录游戏时长、不显示运行中横幅** —— 这是低频的「配置」动作，
  /// 而非「游玩」动作（见方案 §4.6）。
  static Future<void> showPickerFor({
    required String exePath,
    required String gameDir,
  }) async {
    if (!File(exePath).existsSync()) {
      throw FontPatchException('启动程序不存在', detail: exePath);
    }
    try {
      await Process.start(
        exePath,
        const [],
        workingDirectory: gameDir,
        environment: const {'CTFONTHOOK_SHOW_PICKER': '1'},
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      throw FontPatchException('启动游戏失败', detail: '$e');
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 工具
  // ═══════════════════════════════════════════════════════════

  static String _nowStamp() {
    final n = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${p2(n.month)}-${p2(n.day)} '
        '${p2(n.hour)}:${p2(n.minute)}:${p2(n.second)}';
  }

  static Future<String> _sha256Of(String filePath) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      final digest = SHA256Digest().process(bytes);
      return digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } catch (_) {
      return '';
    }
  }

  /// 解析出「启动程序绝对路径」。供 UI 使用（launch_path 是相对游戏目录的）。
  static String? resolveExePath(String gameDir, String launchPath) {
    if (launchPath.isEmpty) return null;
    if (path.isAbsolute(launchPath)) return launchPath;
    return path.join(gameDir, launchPath);
  }
}

/// 我方使用的 PE 架构枚举（与 `LocaleService.PeArchitecture` 语义相同，
/// 但独立定义以**完全不碰** locale_service.dart）。
enum PeArch { x86, x64, unknown }
