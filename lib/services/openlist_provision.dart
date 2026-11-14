import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/path_helper.dart';
import 'global_install_center.dart';
import 'openlist_service.dart';
import 'openlist_update_core.dart';

export 'openlist_update_core.dart' show OlUpdatePhase, OlUpdateReport, OlPaths;

/// OpenList 半移植化（2026-10-02）：按需「对接」+ 自动更新（2026-10-16）。
///
/// 本文件是**宿主接线层**：把 PathHelper 的路径、debugPrint、服务运行态、
/// 安装中心忙碌态、UI 阶段回调注入给纯 Dart 引擎
/// [OpenListUpdateCore]。引擎自身的逻辑（指纹比对 / 下载 / 解压 / 布局归一化
/// / 整目录切换 / 失败回滚 / 退避）全部在 `openlist_update_core.dart`，
/// 不依赖 Flutter，可用 `dart.exe` 端到端验证。
///
/// 三级版本化：
/// - T1 配置 `data.zip`（≈71KB）→ 静默自动更新（服务在跑则挂起）
/// - T2 组件 `openlist.zip`（≈53MB）→ 静默自动安装（下载完等安全窗口再换目录）
/// - T3 布局 → 解压后运行时归一化（兼容扁平 / 多层结构）
///
/// 🔴 数据源（2026-10-16 变更）：配置包**不再走 PocketBase 附件**，改为官方
/// 静态服务器 `data.zip`（与组件包同源）。PB 的 `openlist_configs` 通道自此
/// 废弃（字段保留不删）。
class OpenListProvision {
  OpenListProvision._();

  /// 官方静态资源服务器根地址
  static const String officialServerBase = 'http://117.72.115.30:8000';

  /// 组件整合包下载地址（兼容旧调用点）
  static String get packageUrl => '$serverBase/${OpenListUpdateCore.componentPackageName}';

  /// 配置包下载地址
  static String get configPackageUrl =>
      '$serverBase/${OpenListUpdateCore.configPackageName}';

  static String get serverBase => serverBaseOverride ?? officialServerBase;

  /// 仅供离线探针：覆盖服务器根地址。null = 使用 [officialServerBase]。
  @visibleForTesting
  static String? serverBaseOverride;

  /// 当前阶段（UI 用：对接按钮的忙碌态由它驱动）
  static final ValueNotifier<OlUpdatePhase> phase =
      ValueNotifier<OlUpdatePhase>(OlUpdatePhase.idle);

  static OpenListUpdateCore? _coreCache;
  static String? _coreBase;
  static String? _coreMarkerPath;
  static String? _coreVersion;

  /// 应用版本缓存（`PackageInfo.version`）。
  ///
  /// 引擎要求它是**同步字段**（纯 Dart、不便依赖 Flutter 插件），而
  /// `PackageInfo.fromPlatform()` 是异步的 ⇒ 启动时用 [primeAppVersion]
  /// 预热一次，之后所有判定都是同步读。
  static String _appVersion = '';

  static String get appVersion => _appVersion;

  /// 预热应用版本（幂等，可重复调用；失败只留日志）。
  ///
  /// 读不到版本时保持空串 ⇒ [OpenListUpdateCore.reconcileOnUpgrade] 会
  /// 主动跳过升级对齐（宁可不动，也不要基于空版本号误判「升级了」）。
  static Future<void> primeAppVersion() async {
    if (_appVersion.isNotEmpty) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) _appVersion = info.version;
    } catch (e) {
      debugPrint('[OL-UPD] ⚠️ 读取应用版本失败（升级对齐将跳过）: $e');
    }
  }

  /// 引擎单例（服务器地址 / 存储根 / 应用版本变化时重建，便于探针切换）
  static OpenListUpdateCore get core {
    final base = serverBase;
    final markerPath = PathHelper.openlistProvisionMarkerPath;
    if (_coreCache == null ||
        _coreBase != base ||
        _coreMarkerPath != markerPath ||
        _coreVersion != _appVersion) {
      _coreBase = base;
      _coreMarkerPath = markerPath;
      _coreVersion = _appVersion;
      _coreCache = OpenListUpdateCore(
        paths: _paths(),
        serverBase: base,
        log: (m) => debugPrint(m),
        isServiceRunning: () => OpenListService.isRunning,
        isBusy: () => GlobalInstallCenter.instance.isBusy,
        onPhase: (p) {
          if (phase.value != p) phase.value = p;
        },
        currentAppVersion: _appVersion,
      );
    }
    return _coreCache!;
  }

  static OlPaths _paths() => OlPaths(
        runtimeDir: PathHelper.runtimeDir,
        openlistDir: PathHelper.openlistDir,
        openlistExePath: PathHelper.openlistExePath,
        openlistDataDir: PathHelper.openlistDataDir,
        openlistConfigPath: PathHelper.openlistConfigPath,
        markerPath: PathHelper.openlistProvisionMarkerPath,
        statePath: PathHelper.openlistProvisionStatePath,
        stagingDir: PathHelper.openlistStagingDir,
        backupDir: PathHelper.openlistBackupDir,
        tmpDir: PathHelper.portableTmpDir,
        bundled7zPath: PathHelper.bundled7zPath,
      );

  // ============================ 对外查询 ============================

  /// 是否已对接（异步）
  static Future<bool> isPaired() => core.isPaired();

  /// 是否已对接（同步；用户窗口按钮区等 UI 处使用）
  static bool isPairedSync() => core.isPairedSync();

  // ============================ 自动更新 ============================

  /// 探测并应用配置 / 组件更新（启动后延迟一次 + 打开用户窗口一次）。
  ///
  /// [installComponent] = false 时只探测组件版本，不下载 53MB。
  static Future<OlUpdateReport> checkAndApply({
    bool installComponent = true,
    bool upgradeAlign = false,
  }) =>
      core.checkAndApply(
        installComponent: installComponent,
        upgradeAlign: upgradeAlign,
      );

  /// 版本升级对齐（2026-10-18）。
  ///
  /// 纯本地判定：版本号没变 / 无对接痕迹时**不发任何网络请求**。
  /// 供启动后 1.5 秒调用（见 `main_container._scheduleOpenListAutoUpdate`）。
  static Future<OlUpdateReport> reconcileOnUpgrade() => core.reconcileOnUpgrade();

  /// 本地是否留下过 OpenList 痕迹（不要求可运行）。
  static Future<bool> hasProvisionTrace() => core.hasProvisionTrace(null);

  /// 同步版痕迹判定（只 stat 文件，微秒级）。
  static bool hasProvisionTraceSync() => core.hasProvisionTraceSync();

  /// 本地组件是否健全（exe + data.db + config.json 三者齐全）。
  static Future<bool> isInstallSound() => core.isInstallSound();

  /// 服务启动前的兜底（2026-10-18）：可运行 → `true`；
  /// 有痕迹但缺失 → 现场对齐一次再判；**无痕迹 → 绝不下载，直接 `false`**。
  ///
  /// 供 [OpenListService.ensureRunning] 调用：3.1.2 及更早的历史用户
  /// 组件缺失时，用户点下载的这一刻就是最后一次补救机会 —— 在这里补装，
  /// 而不是直接返回 null 让用户看到「取不到链接」。
  static Future<bool> ensureReadyForUse() async {
    if (await isPaired()) return true;
    try {
      if (!await hasProvisionTrace()) return false;
    } catch (_) {
      return false;
    }
    debugPrint('[OL-UPD] 🩹 下载服务组件缺失但存在痕迹 → 现场补齐');
    await primeAppVersion();
    final r = await reconcileOnUpgrade();
    debugPrint('[OL-UPD] 现场补齐结果: $r');
    return isPaired();
  }

  /// 仅同步配置包（`OpenListService.boot()` 前置调用）。
  static Future<bool> ensureConfigFresh() => core.ensureConfigFresh();

  /// 服务停止后调用：把挂起的配置更新补上。
  static Future<void> applyPendingConfig() => core.applyPendingConfig();

  // ============================ 手动对接 ============================

  /// 执行对接：下载整合包 → 解压到暂存 → 布局归一化 → 切换。
  ///
  /// [onProgress] 下载进度 0.0~1.0；[onStage] 阶段文案。
  /// 成功返回 null；失败返回可直接展示给用户的错误描述。
  static Future<String?> pair({
    void Function(double progress)? onProgress,
    void Function(String stage)? onStage,
  }) =>
      core.pair(onProgress: onProgress, onStage: onStage);

  /// 既有 OpenList 的归属标记补写（2026-10-18 语义反转）。
  ///
  /// 历史：2026-10-04 的规则是「有 `openlist.exe` 但无 `.provisioned` →
  /// 判定为安装包硬内置的遗留 → **整目录删除**，要求用户重新对接」。
  ///
  /// 🔴 2026-10-18 反转为「**补写标记 + 纳入自动对齐**」，原因：
  /// ① 实测 3.1.2 老用户「更新完取不到下载链接」的根因之一就是这条规则
  ///    —— 标记一旦丢失（换机 / 手动搬 `runtime/` / 旧内置残留 / 异常中断），
  ///    用户的服务被清空，而所有自动机制都以「exe 存在」为前提
  ///    ⇒ 删掉后再也没有任何代码会把它补回来；
  /// ② 现在的组件包有 ETag 指纹 + 布局归一化，旧组件会被**自动替换成最新**，
  ///    不需要靠「删掉重来」来保证干净；
  /// ③ 用户明确的诉求：判定到「原先有 OpenList」就同步更新它，而不是抹掉。
  ///
  /// 旧内置与新流程的**唯一实质差异**（旧 exe 可能端口/配置不同）由
  /// [OpenListUpdateCore.checkAndApply] 的指纹比对 + [isInstallSound]
  /// 完整性校验兜住。
  ///
  /// 启动早期 fire-and-forget 调用；任何失败只留日志，绝不阻断启动。
  static Future<void> migrateLegacyIfNeeded() async {
    try {
      final exe = File(PathHelper.openlistExePath);
      if (!exe.existsSync()) return; // 未对接/已清除，无事可做

      final marker = File(PathHelper.openlistProvisionMarkerPath);
      if (marker.existsSync()) return; // 已经有标记，正常路径

      try {
        await marker.create(recursive: true);
        debugPrint('[OL-MIGRATE] 检测到无标记的既有 OpenList → 已补写 .provisioned，'
            '纳入自动对齐（不再删除）');
      } catch (e) {
        debugPrint('[OL-MIGRATE] ⚠️ 标记补写失败（不影响使用）: $e');
      }
    } catch (e) {
      debugPrint('[OL-MIGRATE] ⚠️ 迁移异常（已忽略）: $e');
    }
  }
}
