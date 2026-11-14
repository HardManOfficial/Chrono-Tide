/// OpenList 自动更新引擎 —— **纯 Dart 核心**（零 Flutter 依赖）。
///
/// 为什么单独成文件（2026-10-16）：
/// ① 本机 `flutter analyze` / `flutter test` 因 `CreateFile failed 231` 不可用，
///    只能靠 `flutter_tester` 探针；但实测 flutter_tester 里
///    `Directory.create(recursive: true)` / `Future.delayed` 会**永久挂起**
///    （异步 IO 与 Timer 不可靠）⇒ 引擎没法在 flutter_tester 里被验证。
/// ② 抽成纯 Dart 后，可直接用 `dart.exe` 跑端到端探针：真 HTTP、真文件 IO、
///    真 7z 子进程全部可用（`.workbuddy/probe_ol_update/`）。
/// ③ 顺带把「路径 / 日志 / 运行态判据 / 阶段回调」全部变成**注入参数**，
///    宿主（Flutter 层）只负责接线，逻辑本身可被独立测试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// 日志回调（宿主注入；Flutter 层传 `debugPrint`）
typedef OlLog = void Function(String message);

/// 自动更新阶段（UI 观察用）
enum OlUpdatePhase {
  idle,
  checking,
  downloadingConfig,
  downloadingComponent,
  installing,
}

/// 引擎用到的全部路径（由宿主注入；Flutter 层取自 PathHelper）
class OlPaths {
  final String runtimeDir;
  final String openlistDir;
  final String openlistExePath;
  final String openlistDataDir;
  final String openlistConfigPath;

  /// `.provisioned` 标记（对接归属）
  final String markerPath;

  /// 版本记账文件（🔴 必须在 [runtimeDir] 下：组件整目录替换会清空 openlist/）
  final String statePath;

  /// 组件包解压暂存目录（与 [runtimeDir] 同卷，可原子改名）
  final String stagingDir;

  /// 组件目录备份（切换前改名到此）
  final String backupDir;

  /// 通用临时目录（下载中转）
  final String tmpDir;

  /// 内置 7z（解压组件包用）
  final String bundled7zPath;

  const OlPaths({
    required this.runtimeDir,
    required this.openlistDir,
    required this.openlistExePath,
    required this.openlistDataDir,
    required this.openlistConfigPath,
    required this.markerPath,
    required this.statePath,
    required this.stagingDir,
    required this.backupDir,
    required this.tmpDir,
    required this.bundled7zPath,
  });
}

/// 一次自动更新探测的结果
class OlUpdateReport {
  /// 配置包已落盘应用
  final bool configApplied;

  /// 配置包已下载但服务在跑 → 挂起，等空闲应用
  final bool configDeferred;

  /// 组件包已切换完成
  final bool componentApplied;

  /// 检测到组件有新版但尚未装上（仅检测 / 等安全窗口 / 下载失败）
  final bool componentUpdateAvailable;

  /// 本次被跳过的原因（退避中 / 未对接 / 已在检查）
  final String? skipped;

  /// 出现的问题（HEAD 失败 / 下载失败 / 校验失败）
  final String? problem;

  const OlUpdateReport({
    this.configApplied = false,
    this.configDeferred = false,
    this.componentApplied = false,
    this.componentUpdateAvailable = false,
    this.skipped,
    this.problem,
  });

  bool get hasChanges => configApplied || componentApplied;

  @override
  String toString() =>
      'OlUpdateReport(config=$configApplied, deferred=$configDeferred, '
      'component=$componentApplied, available=$componentUpdateAvailable, '
      'skipped=$skipped, problem=$problem)';
}

/// 远端文件指纹（HEAD 探测得到）
class OlRemoteFile {
  /// 指纹：优先 ETag；服务器不返回 ETag 时退化用 Last-Modified
  final String fingerprint;
  final int length;
  const OlRemoteFile(this.fingerprint, this.length);
}

enum _CfgResult { applied, deferred, failed, unchanged }

enum _CompResult { applied, staged, failed, unavailable }

/// 自动更新引擎。
///
/// 版本化三级：
/// | 层 | 管什么 | 包 | 指纹 | 策略 |
/// |---|---|---|---|---|
/// | T1 配置 | `data/{config.json,data.db}` | `data.zip`（≈71KB） | HEAD ETag | 静默自动（服务在跑则挂起） |
/// | T2 组件 | `{openlist.exe,data/}` | `openlist.zip`（≈53MB） | HEAD ETag | 静默自动（下载完等安全窗口再换目录） |
/// | T3 布局 | 包内目录结构 | — | — | 解压后归一化（见 [normalizeComponentLayout]） |
///
/// 一律不抛异常：失败转成 [OlUpdateReport.problem] + 记账退避。
class OpenListUpdateCore {
  /// 组件整合包文件名
  static const String componentPackageName = 'openlist.zip';

  /// 配置包文件名
  static const String configPackageName = 'data.zip';

  /// 失败退避序列（分钟）：15 → 60 → 360，之后固定 6 小时
  static const List<int> backoffMinutes = <int>[15, 60, 360];

  /// 分块并行下载的连接数
  static const int chunkConcurrency = 6;

  final OlPaths paths;
  final String serverBase;
  final OlLog log;

  /// 服务是否正在运行（换配置/目录前必须为 false）
  final bool Function() isServiceRunning;

  /// 是否有正在进行的下载/安装任务（换组件目录前必须为 false）
  final bool Function() isBusy;

  /// 阶段变化回调（宿主转成 ValueNotifier 给 UI）
  final void Function(OlUpdatePhase)? onPhase;

  /// 当前应用版本（`PackageInfo.version`，宿主注入）。
  ///
  /// 用途：识别「软件刚升级过」这个事件 —— 与状态文件里上次记录的
  /// `appVersion` 不等，即视为版本升级，触发一次 [reconcileOnUpgrade]。
  final String currentAppVersion;

  bool _busy = false;
  bool _swapping = false;

  OpenListUpdateCore({
    required this.paths,
    required this.serverBase,
    required this.log,
    required this.isServiceRunning,
    required this.isBusy,
    this.onPhase,
    this.currentAppVersion = '',
  });

  String get componentUrl => '$serverBase/$componentPackageName';
  String get configUrl => '$serverBase/$configPackageName';

  /// 组件包落点：`staging/openlist`
  String get stagedComponentDir => path.join(paths.stagingDir, 'openlist');

  Future<bool> isPaired() async {
    try {
      return await File(paths.openlistExePath).exists();
    } catch (_) {
      return false;
    }
  }

  bool isPairedSync() {
    try {
      return File(paths.openlistExePath).existsSync();
    } catch (_) {
      return false;
    }
  }

  // ============================ 痕迹与健全性 ============================
  // 🔴 为什么需要「痕迹」而不只是「已对接」（2026-10-18）：
  //    3.1.2 发布后老用户升级完**仍然取不到下载链接**，根因是所有自动机制
  //    都以 `runtime/openlist/openlist.exe` 存在为唯一前提 —— 一旦 exe 缺失
  //    （安装包不内置 + `migrateLegacyIfNeeded()` 曾整目录删除），
  //    `ensureRunning()` / `checkAndApply()` 全部静默短路，没有任何代码会去补。
  //    所以判据必须放宽成「曾经有过 OpenList 的痕迹」，见 [hasProvisionTrace]。

  /// 本地是否留下过 OpenList 的痕迹（**不要求可运行**）。
  ///
  /// 五条判据，任一命中即认为「这台机器曾经有过 OpenList」：
  /// ① `runtime/openlist/` 目录存在（哪怕空 / 不完整）；
  /// ② 扁平遗留 `runtime/openlist.exe`（形态 B 解压残留）；
  /// ③ 扁平遗留 `runtime/data/data.db`（runtime 下只有 OpenList 会用 `data/`）；
  /// ④ `.provisioned` 对接标记；
  /// ⑤ 状态文件里曾有成功的 component / config 记录。
  ///
  /// 全部不命中 = 真·从未对接 ⇒ **一律不下载、不动盘**
  /// （产品决策：53MB 组件包必须由用户在「对接」弹窗里明确同意）。
  Future<bool> hasProvisionTrace(Map<String, dynamic>? st) async {
    if (hasProvisionTraceSync()) return true;
    final s = st ?? await _loadState();
    final comp = s['component'];
    final cfg = s['config'];
    return (comp is Map && comp.isNotEmpty) || (cfg is Map && cfg.isNotEmpty);
  }

  /// [hasProvisionTrace] 的同步版（只 stat 文件，不读状态文件）。
  /// 供启动早期「要不要现在就动」的快速判定，微秒级、不发网络请求。
  bool hasProvisionTraceSync() {
    try {
      if (Directory(paths.openlistDir).existsSync()) return true;
      if (File(path.join(paths.runtimeDir, 'openlist.exe')).existsSync()) {
        return true;
      }
      if (File(path.join(paths.runtimeDir, 'data', 'data.db')).existsSync()) {
        return true;
      }
      if (File(paths.markerPath).existsSync()) return true;
    } catch (_) {
      // stat 失败按「无痕迹」处理：宁可不装，也不误伤用户的盘
    }
    return false;
  }

  /// 本地组件是否**健全可用**：`openlist.exe` + `data/data.db` +
  /// `data/config.json` 三者齐全。
  ///
  /// 与 [isPaired] 的区别：[isPaired] 只要求 exe（够不够拉起进程），
  /// 本方法要求配置也齐 —— 用来识别「exe 在、但 data 丢了」的半残状态：
  /// 这种状态服务能起、界面看着正常，但**所有取链接请求都会失败**。
  Future<bool> isInstallSound() async {
    try {
      if (!await File(paths.openlistExePath).exists()) return false;
      if (!await File(path.join(paths.openlistDataDir, 'data.db')).exists()) {
        return false;
      }
      if (!await File(paths.openlistConfigPath).exists()) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ============================ 主入口 ============================

  /// 探测并应用配置 / 组件更新。
  ///
  /// - 单例锁：并发调用直接返回，不排队、不重复下载
  /// - 退避：连续失败按 15min → 1h → 6h 递增（成功即清零）
  /// - [installComponent] = false 时只**探测**组件版本（不下载 53MB）
  /// - [upgradeAlign] = true 时是「软件版本升级后的对齐」：跳过退避闸，
  ///   并且**指纹相同也要做完整性校验**（本地可能已半残）。
  Future<OlUpdateReport> checkAndApply({
    bool installComponent = true,
    bool upgradeAlign = false,
  }) async {
    if (_busy) return const OlUpdateReport(skipped: '已在检查中');
    _busy = true;
    _phase(OlUpdatePhase.checking);
    try {
      final st = await _loadState();

      // 退避闸：连续失败后指数退避，避免离线时空转刷日志。
      // 🔴 版本升级对齐不受此闸约束（2026-10-18）：它是一次性事件，
      //    被旧版本遗留的 `nextRetryAt` 挡住就永远修不回来了。
      if (!upgradeAlign) {
        final nextRetryAt = st['nextRetryAt'] as String?;
        if (nextRetryAt != null) {
          final t = DateTime.tryParse(nextRetryAt);
          if (t != null && DateTime.now().isBefore(t)) {
            return OlUpdateReport(skipped: '退避中（至 ${t.toLocal()}）');
          }
        }
      }

      // 纳入维护的判据 = 可运行（已对接）**或** 留有痕迹。
      // 痕迹命中但 exe 缺失 ⇒ 走「修复式安装」（下载组件包重建）。
      // 两者都不命中 = 真·从未对接，不做任何自动更新：
      // 53MB 组件包的下载必须由用户在「对接」弹窗里明确同意（产品决策），
      // 且此时落配置只会留下孤立目录。
      final paired = await isPaired();
      final hasTrace = await hasProvisionTrace(st);
      if (!paired && !hasTrace) {
        return const OlUpdateReport(skipped: '从未对接，跳过自动更新');
      }
      if (!paired) {
        log('[OL-UPD] 🩹 检测到 OpenList 痕迹但组件缺失 → 进入修复式安装');
      }

      var cfgApplied = false;
      var cfgDeferred = false;
      var compApplied = false;
      var compAvailable = false;
      String? problem;

      // ---------- T2 组件包（重，可只探测）----------
      // 🔴 顺序要求：组件必须在配置**之前**处理。组件是「整目录替换」
      //    （`openlist → backup`，暂存目录改名就位），会把 `data/` 里刚落盘的
      //    `config.json` 一起换掉。若先落配置再换组件，切换完成后
      //    `isInstallSound()` 会因缺 config.json 判为不健全 ⇒ 下次启动又
      //    「强制重装」⇒ 每次启动白下 53MB 的死循环。
      //    （2026-10-18 探针 S12 实测复现，已按此修正。）
      final rp = await _head(componentUrl);
      if (rp == null) {
        problem = 'openlist.zip 探测失败';
      } else {
        final appliedFp = (st['component'] as Map?)?['fingerprint'];
        // 版本升级对齐：指纹相同也不放过。指纹只证明「曾经装过这个版本」，
        // 不证明「现在文件还在」—— 用户可能丢了 data/ 或只剩 exe，
        // 这种半残状态指纹仍然是旧值，必须靠完整性校验识别。
        final needByHealth = upgradeAlign && !await isInstallSound();
        if (needByHealth) {
          log('[OL-UPD] 🩹 版本升级对齐：本地组件不健全（缺 exe / data.db / config.json）'
              '→ 强制重装');
        }
        if (rp.fingerprint != appliedFp || needByHealth) {
          compAvailable = true;
          final r = await _applyComponent(rp, st, allowDownload: installComponent);
          if (r == _CompResult.applied) {
            compApplied = true;
            compAvailable = false;
          } else if (r == _CompResult.failed) {
            problem = 'openlist.zip 更新失败';
          }
        }
      }

      // ---------- T1 配置包（轻量，组件就位后落盘）----------
      // 放在 T2 之后：组件刚整目录替换过 ⇒ `data/` 内是组件包自带的配置，
      // 这里再用服务器 `data.zip` 覆盖一次，保证两者口径一致。
      // 组件真的换过时清掉配置指纹，强制重新落盘（只多 71KB）。
      if (compApplied) st.remove('config');
      final rc = await _head(configUrl);
      if (rc == null) {
        problem ??= 'data.zip 探测失败';
      } else {
        final appliedFp = (st['config'] as Map?)?['fingerprint'];
        final pendingFp = (st['pendingConfig'] as Map?)?['fingerprint'];
        if (rc.fingerprint != appliedFp && rc.fingerprint != pendingFp) {
          _phase(OlUpdatePhase.downloadingConfig);
          switch (await _applyConfig(rc, st)) {
            case _CfgResult.applied:
              cfgApplied = true;
            case _CfgResult.deferred:
              cfgDeferred = true;
            case _CfgResult.failed:
              problem ??= 'data.zip 应用失败';
            case _CfgResult.unchanged:
              break;
          }
        }
      }

      // ---------- 记账 ----------
      if (problem == null) {
        st['failures'] = 0;
        st.remove('nextRetryAt');
      } else {
        final f = (st['failures'] as int?) ?? 0;
        st['failures'] = f + 1;
        st['nextRetryAt'] = DateTime.now()
            .add(Duration(minutes: backoffMinutes[f.clamp(0, backoffMinutes.length - 1)]))
            .toIso8601String();
      }
      st['lastCheckAt'] = DateTime.now().toIso8601String();
      // 只有「本次完全成功」才记下应用版本：失败时保留旧值 → 下次启动会
      // 再次进入升级对齐（不受退避闸约束），用户迟早被修好。
      if (currentAppVersion.isNotEmpty && problem == null) {
        st['appVersion'] = currentAppVersion;
      }
      await _saveState(st);

      final report = OlUpdateReport(
        configApplied: cfgApplied,
        configDeferred: cfgDeferred,
        componentApplied: compApplied,
        componentUpdateAvailable: compAvailable,
        problem: problem,
      );
      log('[OL-UPD] 探测完成 → $report');
      return report;
    } catch (e) {
      log('[OL-UPD] ❌ 探测异常: $e');
      return OlUpdateReport(problem: '$e');
    } finally {
      _busy = false;
      _phase(OlUpdatePhase.idle);
    }
  }

  /// 版本升级对齐（2026-10-18）：识别「软件刚升级过」并做一次服务对齐。
  ///
  /// 判定**全在本地**（读状态文件 + stat 几个路径），不发任何网络请求，
  /// 因此可以放在启动后 1.5 秒就跑，对未对接用户零成本：
  /// - `appVersion` 与当前版本相同 → 本版本已对齐过，直接跳过；
  /// - 无痕迹 → 真·从未对接，**只记账不下载**（不替用户决定 53MB）；
  /// - 有痕迹 → 转 [checkAndApply]（`upgradeAlign: true`：跳过退避闸 +
  ///   指纹相同也做完整性校验）。
  ///
  /// ⚠️ 已知边界：3.1.2 及更早被 `migrateLegacyIfNeeded()` 整目录删过的
  /// 用户，磁盘上已无任何痕迹，会被判为「从未对接」而不自动恢复 ——
  /// 这类用户需手动点一次「对接」（见文档 §14.4）。
  Future<OlUpdateReport> reconcileOnUpgrade() async {
    if (currentAppVersion.isEmpty) {
      return const OlUpdateReport(skipped: '未注入应用版本，跳过升级对齐');
    }
    final st = await _loadState();
    final last = st['appVersion'] as String?;
    if (last == currentAppVersion) {
      return const OlUpdateReport(skipped: '本版本已对齐');
    }
    if (!await hasProvisionTrace(st)) {
      st['appVersion'] = currentAppVersion;
      await _saveState(st);
      log('[OL-UPD] 未发现 OpenList 痕迹（从未对接）→ 仅记录版本 $currentAppVersion，不安装');
      return const OlUpdateReport(skipped: '从未对接，不做升级安装');
    }
    log('[OL-UPD] 🔄 版本升级对齐：${last ?? '（首次运行）'} → $currentAppVersion');
    return checkAndApply(upgradeAlign: true);
  }

  /// 仅同步配置包（`OpenListService.boot()` 前置调用）。
  ///
  /// boot 的调用时机在 `_startProcess()` **之前**，此刻服务必然未运行，
  /// 因此配置更新可直接落盘，不必走「挂起等空闲」。
  Future<bool> ensureConfigFresh() async {
    if (_busy) return false;
    _busy = true;
    _phase(OlUpdatePhase.checking);
    try {
      final st = await _loadState();
      final rc = await _head(configUrl);
      if (rc == null) return false;
      if (rc.fingerprint == (st['config'] as Map?)?['fingerprint']) return false;
      _phase(OlUpdatePhase.downloadingConfig);
      return await _applyConfig(rc, st) == _CfgResult.applied;
    } catch (e) {
      log('[OL-UPD] ⚠️ 配置同步异常: $e');
      return false;
    } finally {
      _busy = false;
      _phase(OlUpdatePhase.idle);
    }
  }

  /// 服务停止后调用：把「挂起的配置更新」补上。
  ///
  /// 只处理配置包（约 71KB），不触发 53MB 组件下载。
  Future<void> applyPendingConfig() async {
    try {
      final st = await _loadState();
      if (st['pendingConfig'] == null) return;
      final rc = await _head(configUrl);
      if (rc == null) return;
      log('[OL-UPD] 处理挂起配置更新: ${await _applyConfig(rc, st)}');
    } catch (e) {
      log('[OL-UPD] ⚠️ 挂起配置更新异常: $e');
    }
  }

  // ============================ 手动对接 ============================

  /// 下载整合包 → 解压到暂存 → 布局归一化 → 切换。
  ///
  /// 成功返回 null；失败返回可直接展示给用户的错误描述。
  ///
  /// ★ 2026-10-16：解压目标由 `runtime/` 改为**暂存 + 归一化后切换**，
  /// 原因见 [normalizeComponentLayout]（线上包实测为扁平结构，直接解压到
  /// runtime/ 会得到 `runtime/openlist.exe`，`isPaired()` 判定失败）。
  Future<String?> pair({
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('准备中…');

    if (!await File(paths.bundled7zPath).exists()) {
      return '解压工具缺失（runtime/tools/7z.exe），请重新安装本程序';
    }

    // 指纹（用于更新记账；拿不到不影响对接成败）
    final remote = await _head(componentUrl);

    final zipFile = File(path.join(paths.tmpDir, componentPackageName));
    try {
      await _downloadTo(componentUrl, zipFile,
          onProgress: onProgress, chunked: true);
    } catch (e) {
      log('[OL-PAIR] ❌ 下载失败: $e');
      await _deleteQuietly(zipFile);
      return '下载失败：$e';
    }

    onStage?.call('解压中…');
    final staging = Directory(paths.stagingDir);
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      if (!await _extractWith7z(zipFile.path, staging.path)) {
        return '解压失败，请重试';
      }
    } finally {
      await _deleteQuietly(zipFile);
    }

    onStage?.call('校验中…');
    final root = await normalizeComponentLayout(staging.path, log: log);
    if (root == null) {
      await _deleteDirQuietly(staging);
      return '解压完成但服务组件不完整，整合包可能已损坏，请重试';
    }

    // 手动对接 = 用户明确要求，不再等安全窗口（force）
    final st = await _loadState();
    final ok = await _swapInStagedComponent(st, remote, force: true);
    if (!ok || !await isPaired()) {
      return '安装失败：无法替换 runtime/openlist 目录（可能被占用），请关闭程序后重试';
    }

    log('[OL-PAIR] ✅ 对接完成');
    return null;
  }

  // ============================ T1 配置包 ============================

  Future<_CfgResult> _applyConfig(OlRemoteFile remote, Map<String, dynamic> st) async {
    final zipFile = File(path.join(paths.tmpDir, 'ol_config.zip'));
    final stage = Directory(path.join(paths.tmpDir, 'ol_config_stage'));
    final bakDir = Directory(path.join(paths.tmpDir, 'ol_config_backup'));

    try {
      // ① 下载（71KB，单连接即可，不浪费 6 次 Range 往返）
      await Directory(paths.tmpDir).create(recursive: true);
      await _downloadTo(configUrl, zipFile, onProgress: null, chunked: false);

      // ② 解压到暂存（纯 Dart archive：包小、无子进程、可独立测试）
      if (await stage.exists()) await stage.delete(recursive: true);
      await stage.create(recursive: true);
      if (!await _extractConfigInto(zipFile, stage)) {
        log('[OL-UPD] ❌ 配置包校验未通过，放弃本次更新');
        return _CfgResult.failed;
      }

      // ③ 服务在跑 → 挂起
      if (isServiceRunning()) {
        st['pendingConfig'] = <String, dynamic>{
          'fingerprint': remote.fingerprint,
          'length': remote.length,
        };
        await _saveState(st);
        log('[OL-UPD] ⏸️ 服务运行中 → 配置更新挂起，待空闲后应用');
        return _CfgResult.deferred;
      }

      // ④ 备份 → 覆盖 → 复核（失败回滚）
      final dataDir = Directory(paths.openlistDataDir);
      await dataDir.create(recursive: true);
      final targetCfg = File(paths.openlistConfigPath);
      final targetDb = File(path.join(dataDir.path, 'data.db'));

      if (await bakDir.exists()) await bakDir.delete(recursive: true);
      await bakDir.create(recursive: true);
      final bakCfg = File(path.join(bakDir.path, 'config.json'));
      final bakDb = File(path.join(bakDir.path, 'data.db'));
      if (await targetCfg.exists()) await targetCfg.copy(bakCfg.path);
      if (await targetDb.exists()) await targetDb.copy(bakDb.path);

      try {
        await File(path.join(stage.path, 'config.json')).copy(targetCfg.path);
        await File(path.join(stage.path, 'data.db')).copy(targetDb.path);
        final dbLen = await targetDb.length();
        if (dbLen < 1024) throw '落盘后 data.db 大小异常（${dbLen}B）';
      } catch (e) {
        log('[OL-UPD] ❌ 配置落盘失败，回滚: $e');
        if (await bakCfg.exists()) await bakCfg.copy(targetCfg.path);
        if (await bakDb.exists()) await bakDb.copy(targetDb.path);
        return _CfgResult.failed;
      }
      await _deleteDirQuietly(bakDir);

      st['config'] = <String, dynamic>{
        'fingerprint': remote.fingerprint,
        'length': remote.length,
        'appliedAt': DateTime.now().toIso8601String(),
      };
      st.remove('pendingConfig');
      await _saveState(st);
      log('[OL-UPD] ✅ 配置已更新（config.json + data.db，'
          '${(remote.length / 1024).toStringAsFixed(1)}KB）');
      return _CfgResult.applied;
    } catch (e) {
      log('[OL-UPD] ❌ 配置更新异常: $e');
      return _CfgResult.failed;
    } finally {
      await _deleteQuietly(zipFile);
      await _deleteDirQuietly(stage);
    }
  }

  /// 从配置 zip 中取出 `config.json` + `data.db` 写入 [stage]，并做校验。
  ///
  /// 用 `package:archive` 而非 7z：包仅 71KB，纯 Dart 解压零子进程开销。
  /// zip 内层路径不写盘（只按固定文件名落两个文件），天然免疫 zip-slip。
  static Future<bool> _extractConfigInto(File zip, Directory stage) async {
    final Archive ar;
    try {
      ar = ZipDecoder().decodeBytes(await zip.readAsBytes());
    } catch (_) {
      return false;
    }

    var gotCfg = false;
    var gotDb = false;
    for (final entry in ar) {
      if (!entry.isFile) continue;
      final base = entry.name.replaceAll('\\', '/').split('/').last;
      if (base != 'config.json' && base != 'data.db') continue;
      final bytes = entry.content as List<int>;
      await File(path.join(stage.path, base)).writeAsBytes(bytes, flush: true);
      if (base == 'config.json') gotCfg = true;
      if (base == 'data.db') gotDb = true;
    }
    if (!gotCfg || !gotDb) return false;

    try {
      final decoded =
          jsonDecode(await File(path.join(stage.path, 'config.json')).readAsString());
      if (decoded is! Map) return false;
    } catch (_) {
      return false;
    }
    return await File(path.join(stage.path, 'data.db')).length() >= 1024;
  }

  // ============================ T2 组件包 ============================

  Future<_CompResult> _applyComponent(
    OlRemoteFile remote,
    Map<String, dynamic> st, {
    required bool allowDownload,
  }) async {
    // ① 已有匹配指纹的暂存包 → 直接尝试切换（不必重复下 53MB）
    final pending = st['pendingComponent'] as Map?;
    if (pending != null &&
        pending['fingerprint'] == remote.fingerprint &&
        await Directory(stagedComponentDir).exists()) {
      return await _swapInStagedComponent(st, remote)
          ? _CompResult.applied
          : _CompResult.staged;
    }

    if (!allowDownload) return _CompResult.unavailable;

    // ② 下载（多连接分块）
    _phase(OlUpdatePhase.downloadingComponent);
    final zipFile = File(path.join(paths.tmpDir, componentPackageName));
    try {
      await _downloadTo(componentUrl, zipFile, onProgress: null, chunked: true);
    } catch (e) {
      log('[OL-UPD] ❌ 组件包下载失败: $e');
      await _deleteQuietly(zipFile);
      return _CompResult.failed;
    }
    if (!await _isZipFile(zipFile)) {
      log('[OL-UPD] ❌ 组件包签名校验失败');
      await _deleteQuietly(zipFile);
      return _CompResult.failed;
    }

    // ③ 解压到暂存
    _phase(OlUpdatePhase.installing);
    final staging = Directory(paths.stagingDir);
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      if (!await _extractWith7z(zipFile.path, staging.path)) {
        return _CompResult.failed;
      }
    } finally {
      await _deleteQuietly(zipFile);
    }

    // ④ 布局归一化（线上包实测为扁平结构，必须靠这步兜住）
    if (await normalizeComponentLayout(staging.path, log: log) == null) {
      log('[OL-UPD] ❌ 组件包目录结构无法识别，放弃本次更新');
      await _deleteDirQuietly(staging);
      return _CompResult.failed;
    }

    // ⑤ 记 pending（下载已完成，等安全窗口）→ 立即尝试切换
    st['pendingComponent'] = <String, dynamic>{
      'fingerprint': remote.fingerprint,
      'length': remote.length,
    };
    await _saveState(st);
    return await _swapInStagedComponent(st, remote)
        ? _CompResult.applied
        : _CompResult.staged;
  }

  /// 把暂存目录里的组件切换到 `openlistDir`。
  ///
  /// 安全窗口（非 [force] 时）：服务未运行 **且** 没有正在进行的下载/安装
  /// 任务 —— 换目录必须先停服务，不确认就切会打断用户任务。
  /// 不满足则返回 false，暂存包保留，下次探测直接复用（不再重复下载）。
  Future<bool> _swapInStagedComponent(
    Map<String, dynamic> st,
    OlRemoteFile? remote, {
    bool force = false,
  }) async {
    if (_swapping) return false;
    final stagedRoot = Directory(stagedComponentDir);
    if (!await stagedRoot.exists()) return false;

    if (!force) {
      if (isServiceRunning()) {
        log('[OL-UPD] ⏸️ 服务运行中 → 组件切换延后');
        return false;
      }
      if (isBusy()) {
        log('[OL-UPD] ⏸️ 有下载/安装任务进行中 → 组件切换延后');
        return false;
      }
    }

    _swapping = true;
    final target = Directory(paths.openlistDir);
    final backup = Directory(paths.backupDir);
    var swapped = false;
    try {
      await Directory(paths.runtimeDir).create(recursive: true);
      if (await backup.exists()) await backup.delete(recursive: true);

      final hadTarget = await target.exists();
      if (hadTarget) await target.rename(backup.path);

      try {
        await stagedRoot.rename(target.path);
        swapped = true;
      } catch (e) {
        log('[OL-UPD] ❌ 切换失败，回滚旧组件: $e');
        if (hadTarget && await backup.exists()) await backup.rename(target.path);
        return false;
      }

      // 🔴 关键：整合包内不含 `.provisioned` 标记，切换后必须补写。
      //    否则 `migrateLegacyIfNeeded()` 会把新目录当「旧内置遗留」整删。
      try {
        final marker = File(paths.markerPath);
        if (!await marker.exists()) await marker.create(recursive: true);
      } catch (e) {
        log('[OL-UPD] ⚠️ 对接标记补写失败: $e');
      }

      // 扁平遗留清理（2026-10-18）：早期形态 B 解压产物是
      // `runtime/openlist.exe` + `runtime/data/`。新目录已就位后它们就是
      // 纯垃圾，还会让「痕迹」判定一直命中、并诱导旧 exe 被误用。
      // 🔴 只在切换**成功后**做：失败时保留，用户至少还有能跑的旧服务。
      await _cleanFlatLegacy();

      await _deleteDirQuietly(backup);
      if (remote != null) {
        st['component'] = <String, dynamic>{
          'fingerprint': remote.fingerprint,
          'length': remote.length,
          'appliedAt': DateTime.now().toIso8601String(),
        };
      }
      st.remove('pendingComponent');
      await _saveState(st);
      log('[OL-UPD] ✅ 组件已更新（${remote?.length ?? 0} 字节）');
      return true;
    } catch (e) {
      log('[OL-UPD] ❌ 组件切换异常: $e');
      return false;
    } finally {
      _swapping = false;
      // 成功后清掉暂存（失败时保留，供下次直接重试切换）
      if (swapped) await _deleteDirQuietly(Directory(paths.stagingDir));
    }
  }

  /// 清理形态 B（扁平）解压遗留：`runtime/openlist.exe` 与 `runtime/data/`。
  ///
  /// 🔴 安全前提（三条都满足才动手）：① 只在新组件已切换成功后调用；
  /// ② `runtime/data/` 必须内含 `data.db` 才认作 OpenList 残留
  /// （runtime 下其它子目录是 tools / sdl3 / fonthook / locale_emulator /
  /// magpie，`data/` 只有 OpenList 扁平包会产出）；③ 失败只记日志。
  Future<void> _cleanFlatLegacy() async {
    final flatExe = File(path.join(paths.runtimeDir, 'openlist.exe'));
    final flatData = Directory(path.join(paths.runtimeDir, 'data'));
    try {
      if (await flatExe.exists()) {
        await flatExe.delete();
        log('[OL-UPD] 🧹 已清理扁平遗留 runtime/openlist.exe');
      }
    } catch (e) {
      log('[OL-UPD] ⚠️ 清理扁平遗留 exe 失败（忽略）: $e');
    }
    try {
      final flatDb = File(path.join(flatData.path, 'data.db'));
      if (await flatData.exists() && await flatDb.exists()) {
        await _deleteDirQuietly(flatData);
        log('[OL-UPD] 🧹 已清理扁平遗留 runtime/data/');
      }
    } catch (e) {
      log('[OL-UPD] ⚠️ 清理扁平遗留 data 失败（忽略）: $e');
    }
  }

  /// 布局归一化：把任意解压形态整理成 `stagingPath/openlist/{openlist.exe,data/}`。
  ///
  /// 三种已知形态（🔴 2026-10-16 实测线上 `openlist.zip` 为形态 B —— 直接
  /// 解压到 `runtime/` 会得到 `runtime/openlist.exe`，`isPaired()` 判定失败、
  /// 用户看到「解压完成但服务组件不完整」，必须靠本函数兜住）：
  ///
  /// | 形态 | 解压结果 | 处理 |
  /// |---|---|---|
  /// | A | `openlist/openlist.exe` + `openlist/data/` | 正确，直通 |
  /// | B | `openlist.exe` + `data/`（扁平） | 自动包进 `openlist/` |
  /// | C | `openlist/openlist/openlist.exe` | 自动展平一层 |
  ///
  /// 成功返回 `stagingPath/openlist` 目录；无法识别返回 null（**不移动任何文件**）。
  static Future<Directory?> normalizeComponentLayout(
    String stagingPath, {
    OlLog? log,
  }) async {
    void say(String s) => log?.call(s);

    final staging = Directory(stagingPath);
    if (!await staging.exists()) return null;

    Future<bool> hasExe(Directory d) =>
        File(path.join(d.path, 'openlist.exe')).exists();

    Directory? source;
    if (await hasExe(staging)) {
      source = staging; // 形态 B（或包内只有 exe + data）
    } else {
      final inner = Directory(path.join(stagingPath, 'openlist'));
      final deeper = Directory(path.join(inner.path, 'openlist'));
      if (await hasExe(inner)) {
        source = inner; // 形态 A
      } else if (await hasExe(deeper)) {
        // 形态 C：`openlist/openlist/openlist.exe`（多套一层）。
        // 把 deeper 定为 source，由下方通用搬移把内容展平进
        // `stagingPath/openlist`，随后空壳 deeper 会被清理掉。
        // ⚠️ 这里**不能**依赖 `hasExe(inner)`：形态 C 下 inner 本身不含 exe，
        //    旧写法把 deeper 判断嵌在 `hasExe(inner)` 分支里 → 永远走不到。
        source = deeper;
      } else {
        // 兜底：恰好一个子目录且含 exe
        final subs = await staging
            .list()
            .where((e) => e is Directory)
            .cast<Directory>()
            .toList();
        if (subs.length == 1 && await hasExe(subs.first)) source = subs.first;
      }
    }
    if (source == null) return null;

    final target = Directory(path.join(stagingPath, 'openlist'));
    if (!path.equals(source.path, target.path)) {
      await target.create(recursive: true);
      // 先快照再移动（移动会改变目录内容）
      final entries = await source.list().toList();
      for (final e in entries) {
        if (path.equals(e.path, target.path)) continue;
        await _moveEntity(e, path.join(target.path, path.basename(e.path)));
      }
      // 形态 C：搬空后把残留的空壳子目录删掉，避免多套一层进 runtime/
      try {
        if (!path.equals(source.path, stagingPath) &&
            await source.exists() &&
            (await source.list().isEmpty)) {
          await source.delete();
        }
      } catch (_) {}
    }

    if (!await hasExe(target)) return null;
    if (!await File(path.join(target.path, 'data', 'data.db')).exists()) {
      say('[OL-UPD] ⚠️ 组件包内未见 data/data.db（仅 exe），仍按有效处理');
    }
    return target;
  }

  /// 移动文件/目录（rename 优先；跨卷或被占用时退化为复制+删除）
  static Future<void> _moveEntity(FileSystemEntity src, String dest) async {
    try {
      await src.rename(dest);
      return;
    } catch (_) {}
    if (src is File) {
      await src.copy(dest);
      await src.delete();
    } else if (src is Directory) {
      await Directory(dest).create(recursive: true);
      final subs = await src.list().toList();
      for (final s in subs) {
        await _moveEntity(s, path.join(dest, path.basename(s.path)));
      }
      try {
        await src.delete();
      } catch (_) {}
    }
  }

  // ============================ 状态读写 ============================

  Future<Map<String, dynamic>> _loadState() async {
    try {
      final f = File(paths.statePath);
      if (!await f.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (e) {
      log('[OL-UPD] ⚠️ 状态读取失败（按空处理）: $e');
      return <String, dynamic>{};
    }
  }

  Future<void> _saveState(Map<String, dynamic> st) async {
    try {
      final f = File(paths.statePath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(st), flush: true);
    } catch (e) {
      // 状态写失败只影响「下次是否重做一次」，不影响功能本身
      log('[OL-UPD] ⚠️ 状态写入失败: $e');
    }
  }

  void _phase(OlUpdatePhase p) => onPhase?.call(p);

  // ============================ 网络与解压 ============================

  /// HEAD 探测远端指纹。ETag 缺失时退化用 Last-Modified；两者皆无 → null。
  Future<OlRemoteFile?> _head(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = (uri) => 'DIRECT';
    try {
      final req = await client.headUrl(Uri.parse(url));
      final resp = await req.close();
      final len = resp.contentLength;
      final etag = resp.headers.value('etag');
      final lastModified = resp.headers.value('last-modified');
      await resp.drain<void>();
      if (resp.statusCode != 200) {
        log('[OL-UPD] HEAD $url → HTTP ${resp.statusCode}');
        return null;
      }
      if (len <= 0) return null;
      final fp = (etag != null && etag.isNotEmpty)
          ? etag
          : (lastModified != null && lastModified.isNotEmpty ? lastModified : '');
      if (fp.isEmpty) return null;
      return OlRemoteFile(fp, len);
    } catch (e) {
      log('[OL-UPD] HEAD 失败 $url: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 下载到 [target]。
  ///
  /// [chunked] = true 时多连接分块并行（组件包 53MB）；false 时单连接流式
  /// （配置包 71KB，省去 6 次 Range 往返）。全程直连不走系统代理。
  Future<void> _downloadTo(
    String url,
    File target, {
    void Function(double)? onProgress,
    required bool chunked,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..findProxy = (uri) => 'DIRECT';
    final uri = Uri.parse(url);
    try {
      if (!chunked) {
        await _downloadSimple(client, uri, target, onProgress);
        return;
      }
      final probe = await client.getUrl(uri);
      probe.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final resp = await probe.close();
      if (resp.statusCode == 206) {
        await resp.drain<void>();
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        final slash = cr.lastIndexOf('/');
        final total =
            slash == -1 ? -1 : int.tryParse(cr.substring(slash + 1)) ?? -1;
        if (total > 0) {
          await _downloadChunked(
              client: client,
              uri: uri,
              total: total,
              target: target,
              onProgress: onProgress);
          return;
        }
        await _downloadSimple(client, uri, target, onProgress);
      } else if (resp.statusCode == 200) {
        await _saveStream(resp, target, onProgress);
      } else {
        throw '服务器返回 HTTP ${resp.statusCode}';
      }
    } finally {
      client.close();
    }
  }

  /// 多连接分块并行下载：每块写独立分片文件，全部完成后按偏移合并。
  static Future<void> _downloadChunked({
    required HttpClient client,
    required Uri uri,
    required int total,
    required File target,
    void Function(double)? onProgress,
  }) async {
    await Directory(path.dirname(target.path)).create(recursive: true);
    final chunkSize = total ~/ chunkConcurrency;
    String partPath(int i) => '${target.path}.p$i';

    // 节流进度回调（多连接下回调频率高，150ms 节流防刷帧）
    final received = List<int>.filled(chunkConcurrency, 0);
    var lastTick = DateTime.now();
    void report() {
      final now = DateTime.now();
      if (now.difference(lastTick).inMilliseconds >= 150) {
        lastTick = now;
        var sum = 0;
        for (final r in received) {
          sum += r;
        }
        onProgress?.call((sum / total).clamp(0.0, 1.0));
      }
    }

    Future<void> fetchChunk(int idx) async {
      final start = idx * chunkSize;
      final end = idx == chunkConcurrency - 1 ? total - 1 : start + chunkSize - 1;
      final expect = end - start + 1;
      final part = File(partPath(idx));

      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          if (await part.exists()) await part.delete();
          final req = await client.getUrl(uri);
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
          final resp = await req.close();
          if (resp.statusCode != 206) {
            throw '分块下载返回 HTTP ${resp.statusCode}（期望 206）';
          }
          final sink = part.openWrite();
          var got = 0;
          try {
            await for (final chunk in resp) {
              sink.add(chunk);
              got += chunk.length;
              received[idx] = got;
              report();
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (got != expect) throw '分块数据不完整（$got/$expect 字节）';
          return;
        } catch (e) {
          if (attempt == 3) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }

    try {
      await Future.wait(
          [for (var i = 0; i < chunkConcurrency; i++) fetchChunk(i)]);
    } catch (e) {
      for (var i = 0; i < chunkConcurrency; i++) {
        await _deleteQuietly(File(partPath(i)));
      }
      rethrow;
    }

    // 按偏移合并分片 → 最终文件（顺序写单个 RandomAccessFile，无并发竞争）
    if (await target.exists()) await target.delete();
    final raf = await target.open(mode: FileMode.write);
    try {
      for (var i = 0; i < chunkConcurrency; i++) {
        final bytes = await File(partPath(i)).readAsBytes();
        await raf.setPosition(i * chunkSize);
        await raf.writeFrom(bytes);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
    for (var i = 0; i < chunkConcurrency; i++) {
      await _deleteQuietly(File(partPath(i)));
    }
    onProgress?.call(1.0);
  }

  /// 单线程流式下载（Range 不可用 / 小文件时的路径）
  static Future<void> _downloadSimple(HttpClient client, Uri uri, File target,
      void Function(double)? onProgress) async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode != 200) {
      throw '服务器返回 HTTP ${response.statusCode}';
    }
    await _saveStream(response, target, onProgress);
  }

  static Future<void> _saveStream(HttpClientResponse response, File target,
      void Function(double)? onProgress) async {
    await Directory(path.dirname(target.path)).create(recursive: true);
    if (await target.exists()) await target.delete();

    final total = response.contentLength; // 未知时为 -1
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// 用内置 7z 解压（组件包 53MB：多线程、支持超长路径与中文名）
  Future<bool> _extractWith7z(String zipPath, String targetDir) async {
    try {
      final exe = paths.bundled7zPath;
      if (!await File(exe).exists()) {
        log('[OL-UPD] ❌ 7z.exe 不存在: $exe');
        return false;
      }
      final result = await Process.run(exe, [
        'x',
        zipPath.replaceAll('/', '\\'),
        '-o$targetDir',
        '-y',
        '-aoa',
        '-spf',
        '-tzip',
      ], runInShell: false, includeParentEnvironment: true);
      if (result.exitCode != 0 && result.exitCode != 1) {
        log('[OL-UPD] ❌ 7z 退出码 ${result.exitCode}: ${result.stdout}');
        return false;
      }
      final entities = await Directory(targetDir).list(recursive: true).toList();
      if (entities.whereType<File>().isEmpty) {
        log('[OL-UPD] ❌ 7z 解压后未产生任何文件');
        return false;
      }
      return true;
    } catch (e) {
      log('[OL-UPD] ❌ 7z 解压异常: $e');
      return false;
    }
  }

  /// ZIP/PK 签名校验（前 4 字节）
  static Future<bool> _isZipFile(File f) async {
    try {
      if (!await f.exists() || await f.length() < 4) return false;
      final bytes = await f.openRead(0, 4).first;
      if (bytes.length < 4) return false;
      return bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          (bytes[2] == 0x03 ||
              bytes[2] == 0x05 ||
              bytes[2] == 0x06 ||
              bytes[2] == 0x07);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> _deleteDirQuietly(Directory d) async {
    try {
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }
}
