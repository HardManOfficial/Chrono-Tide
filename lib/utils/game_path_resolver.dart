import 'dart:io';

import 'package:flutter/foundation.dart';

import 'network_path.dart';

/// 游戏本体目录路径的解析状态。
enum GamePathState {
  /// 盘符形态可用（用户导入时的原始形态，与资源管理器所见一致）。
  ok,

  /// 盘符形态不可用，已回退到 UNC 真路径直连（功能不受影响）。
  uncFallback,

  /// 所有形态均不可达（NAS 离线 / 映射断开 / 本地目录被删）。
  offline,
}

/// [GamePathResolver.resolve] 的结果视图。
///
/// - [displayPath]：**展示用**。优先用户盘符形态（`Z:\...`），
///   盘符失效时如实反映当前访问形态（UNC）。
/// - [accessPath]：**本次实际可用的访问路径**（已通过存在性校验）。
///   离线时为空串 —— 调用方据此给出提示，**绝不静默写入或改写存储路径**。
/// - [statusText]：非 ok 时的用户可读说明；ok 时为空串。
class ResolvedGamePath {
  final String displayPath;
  final String accessPath;
  final GamePathState state;
  final bool isNetwork;
  final String statusText;

  const ResolvedGamePath({
    required this.displayPath,
    required this.accessPath,
    required this.state,
    required this.isNetwork,
    required this.statusText,
  });
}

/// 游戏本体目录路径统一解析器（★ 2026-10-06 NAS 映射网络驱动器适配）。
///
/// ## 存储口径（★ 方案 B，2026-10-06 定稿）
///
/// `game.json.directory_path` 存**用户导入时的原始形态** —— 映射盘导入即
/// 盘符形态（`Z:\...`，与资源管理器所见一致）；UNC 导入即 UNC；本地路径
/// 不变。`source_path` 存**备形态**：主形态为盘符时是 UNC 真路径（盘符
/// 重映射 / 未挂载时的兜底），其余为空串。
/// 两种形态经 `PathNormalizer.forCompare` 归一到同一结果，
/// 身份 / 排重 / 同卷判定不受存储形态影响。
///
/// 本解析器是访问端的唯一入口，探测顺序为**盘符形态优先、UNC 兜底**：
///
/// 1. 盘符形态候选（存储值 / `source_path` / 动态反查盘符）逐个探测；
/// 2. 全部失败 → UNC 候选（存储值 / `source_path` 的 UNC 等价）逐个探测；
/// 3. 全部失败 → 对主存储值做一次**短超时重试**（防 SMB 唤醒抖动误判）；
/// 4. 仍失败 → [GamePathState.offline]，由调用方明确提示。
///
/// 老数据（directory_path 为 UNC 真路径 / 历史 `\\?\UNC\`）读取端兼容：
/// 动态反查盘符成功时同样能拿到盘符形态访问，**不回写存储值**。
///
/// ## 稳定性约定（网络波动）
///
/// - 所有存在性探测**异步 + 超时**（10s），绝不阻塞 UI isolate 到 SMB 死等；
/// - 进程级 `SetErrorMode` 抑制系统「无磁盘」弹窗（[NetworkPath] 既有能力）；
/// - 结果带 8s TTL 缓存；同卷根连续离线时进入 15s 快速离线通道，
///   避免批量场景（如批量创建快捷方式）对同一离线卷反复等待；
/// - 详情窗「重新检测目录」菜单项可随时清除缓存强制重探。
///
/// ## 兼容
///
/// - 老数据 `directory_path` 为 `\\?\UNC\...`（历史缺陷产物）或盘符形态：
///   读取端剥离前缀后按同一逻辑解析，**不回写存储值**；
/// - 本地磁盘路径：`isNetwork` 为 false，行为退化为「目录存在 = ok」，
///   与既有本地语义完全一致。
class GamePathResolver {
  GamePathResolver._();

  /// 单个候选路径的存在性探测超时（网络盘离线时 SMB 可能长时间无响应）。
  ///
  /// 🔴 2026-10-06：4s → 10s。NAS 冷启动 / 唤醒 / 首次 SMB 建连经常超过
  /// 4 秒，旧值会把「正在唤醒」误判成「离线」，再叠加快速离线通道放大。
  static const Duration _probeTimeout = Duration(seconds: 10);

  /// 离线判定的最后一搏超时（短，只用于避免把唤醒中的 NAS 判死）。
  static const Duration _offlineRetryTimeout = Duration(seconds: 5);

  /// 结果缓存 TTL：启动/打开目录等操作在短时间内会重复触发解析。
  static const Duration _cacheTtl = Duration(seconds: 8);

  /// 同一卷根连续离线后的快速离线窗口（批量场景防雪崩）。
  static const Duration _offlineVolumeTtl = Duration(seconds: 15);

  static final Map<String, (ResolvedGamePath, DateTime)> _cache = {};
  static final Map<String, DateTime> _offlineVolumeUntil = {};

  /// 仅供测试：注入「UNC 共享根 → 当前映射盘符」的映射表。
  /// 非 null 时短路真实 `WNetGetConnectionW` 反查；null = 走真实反查。
  @visibleForTesting
  static String? Function(String uncRoot)? debugDriveMapProvider;

  /// 仅供测试：注入存在性探测（避免测试机没有真实映射盘）。
  /// 返回值即 `_dirExists` 的结果；null = 走真实探测。
  @visibleForTesting
  static Future<bool> Function(String path, Duration timeout)? debugProbe;

  /// 解析游戏本体目录的当前可用形态。
  ///
  /// [directoryPath]：game.json 存储值（用户原始形态 / 老 UNC 数据 /
  /// 历史 `\\?\UNC\` / 本地路径）。
  /// [sourcePath]：`source_path` 字段（备形态；老数据为空）。
  static Future<ResolvedGamePath> resolve({
    required String directoryPath,
    String sourcePath = '',
  }) async {
    // 触发 SetErrorMode（幂等）：访问离线盘不弹系统对话框、不阻塞线程
    NetworkPath.isNetwork(directoryPath);

    final stored =
        NetworkPath.stripLongPathPrefix(directoryPath.replaceAll('/', '\\'));
    final src =
        NetworkPath.stripLongPathPrefix(sourcePath.replaceAll('/', '\\'));

    if (stored.isEmpty) {
      return const ResolvedGamePath(
        displayPath: '',
        accessPath: '',
        state: GamePathState.offline,
        isNetwork: false,
        statusText: '该游戏未记录游戏目录',
      );
    }

    final cacheKey = '${stored.toLowerCase()}|$src';
    final cached = _cache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$2) < _cacheTtl) {
      return cached.$1;
    }

    final net = NetworkPath.isNetwork(stored) || NetworkPath.isNetwork(src);
    final ResolvedGamePath result;
    if (!net) {
      result = await _resolveLocal(stored);
    } else {
      result = await _resolveNetwork(stored, src);
    }
    _cache[cacheKey] = (result, DateTime.now());
    return result;
  }

  /// 仅供测试：清空解析缓存与快速离线通道
  @visibleForTesting
  static void debugClearCache() {
    _cache.clear();
    _offlineVolumeUntil.clear();
    debugDriveMapProvider = null;
    debugProbe = null;
  }

  /// 清空解析缓存与快速离线通道（**正式 API**）。
  ///
  /// UI「重新检测目录」入口：NAS 刚唤醒 / 映射盘刚重连时，结果缓存（8s）
  /// 与快速离线通道（15s）可能还挂着旧的离线结论，用户手动重试立即重探。
  static void invalidateCache() {
    _cache.clear();
    _offlineVolumeUntil.clear();
  }

  // ==================== 本地路径 ====================

  static Future<ResolvedGamePath> _resolveLocal(String stored) async {
    final ok = await _dirExists(stored);
    return ResolvedGamePath(
      displayPath: stored,
      accessPath: ok ? stored : '',
      state: ok ? GamePathState.ok : GamePathState.offline,
      isNetwork: false,
      statusText: ok ? '' : '游戏目录不存在：$stored',
    );
  }

  // ==================== 网络路径 ====================

  static Future<ResolvedGamePath> _resolveNetwork(String stored, String src) async {
    final rootKey = NetworkPath.volumeRoot(stored)?.toLowerCase();
    final srcRootKey =
        src.isNotEmpty ? NetworkPath.volumeRoot(src)?.toLowerCase() : null;
    final now = DateTime.now();
    // 快速离线通道：同一卷根刚被判离线，直接短路（批量场景防雪崩）
    if ((rootKey != null && _isVolumeOffline(rootKey, now)) ||
        (srcRootKey != null && _isVolumeOffline(srcRootKey, now))) {
      return _offlineResult(stored, cached: true);
    }

    // ── 收集候选形态（★ 方案 B：盘符形态优先，UNC 兜底） ──
    final driveForms = <String>[];
    final uncForms = <String>[];
    void addForm(String p) {
      if (p.isEmpty) return;
      final list = p.startsWith(r'\\') ? uncForms : driveForms;
      if (!list.contains(p)) list.add(p);
    }

    addForm(stored);
    addForm(src);
    // 动态反查：存储值为 UNC 时合成当前映射盘符形态（盘符重映射自动跟随）
    if (stored.startsWith(r'\\')) {
      addForm(_synthFromDriveMap(stored) ?? '');
    } else {
      // 存储值为盘符时补它的 UNC 等价（覆盖映射被删但 UNC 仍可达）
      final unc = NetworkPath.canonicalizeVolume(stored);
      if (unc != stored) addForm(unc);
    }

    // 🔴 防盘符重映射误命中：存储盘符当前指向的共享与备形态（UNC 真路径）
    //   的共享**明确不同** → 盘符已重映射到别处，改为 UNC 优先探测。
    //   （canonicalizeVolume 解析不出当前 UNC 时不动顺序 —— 未知 ≠ 重映射）
    var driveFirst = driveForms.isNotEmpty;
    if (driveFirst && src.startsWith(r'\\')) {
      final currentUnc = NetworkPath.canonicalizeVolume(stored);
      if (currentUnc.startsWith(r'\\') &&
          !_sameShare(currentUnc, src) &&
          driveForms.contains(stored)) {
        driveFirst = false;
      }
    }

    final ordered = driveFirst
        ? [...driveForms, ...uncForms]
        : [...uncForms, ...driveForms];
    for (final cand in ordered) {
      if (await _dirExists(cand)) {
        return _resultForAccess(cand, driveForms);
      }
    }

    // 最后一搏：主存储值短超时重试（防 NAS 唤醒 / SMB 抖动误判离线）
    if (await _dirExists(stored, timeout: _offlineRetryTimeout)) {
      return _resultForAccess(stored, driveForms);
    }

    // 标记快速离线（存储值与备形态的卷根都算）
    final until = DateTime.now().add(_offlineVolumeTtl);
    if (rootKey != null) _offlineVolumeUntil[rootKey] = until;
    if (srcRootKey != null) _offlineVolumeUntil[srcRootKey] = until;
    return _offlineResult(stored);
  }

  /// 按实际访问形态组装结果（★ 方案 B 语义）。
  ///
  /// - 访问形态是盘符 → [GamePathState.ok]，展示即访问；
  /// - 访问形态是 UNC 且**存在**盘符形态候选 → [GamePathState.uncFallback]，
  ///   展示仍用盘符形态（用户期望的形态），如实说明当前走了网络路径；
  /// - 访问形态是 UNC 且从未有过盘符形态（用户直接以 UNC 导入）→
  ///   [GamePathState.ok]，UNC 就是该用户的「本地形态」。
  static ResolvedGamePath _resultForAccess(
      String access, List<String> driveForms) {
    if (!access.startsWith(r'\\')) {
      return ResolvedGamePath(
        displayPath: access,
        accessPath: access,
        state: GamePathState.ok,
        isNetwork: true,
        statusText: '',
      );
    }
    final driveDisplay = driveForms.isNotEmpty ? driveForms.first : '';
    if (driveDisplay.isEmpty) {
      return ResolvedGamePath(
        displayPath: access,
        accessPath: access,
        state: GamePathState.ok,
        isNetwork: true,
        statusText: '',
      );
    }
    return ResolvedGamePath(
      displayPath: driveDisplay,
      accessPath: access,
      state: GamePathState.uncFallback,
      isNetwork: true,
      statusText: '映射盘未响应，已通过网络路径访问',
    );
  }

  static ResolvedGamePath _offlineResult(String stored, {bool cached = false}) {
    return ResolvedGamePath(
      displayPath: stored,
      accessPath: '',
      state: GamePathState.offline,
      isNetwork: true,
      statusText: cached
          ? '网络位置暂不可达（刚探测失败，可稍后重试）'
          : '网络位置不可达（NAS 离线或映射已断开）',
    );
  }

  static bool _isVolumeOffline(String rootKey, DateTime now) {
    final until = _offlineVolumeUntil[rootKey];
    return until != null && now.isBefore(until);
  }

  /// 存储值为 UNC 时，反查当前映射到同一共享的盘符并合成盘符形态路径。
  ///
  /// `\\host\share\Games\X` + 当前 `Z:` 映射到 `\\host\share` → `Z:\Games\X`。
  /// 非 UNC 存储 / 反查失败返回 null。
  static String? _synthFromDriveMap(String stored) {
    final root = NetworkPath.volumeRoot(stored);
    if (root == null || !root.startsWith(r'\\')) return null;
    final provider = debugDriveMapProvider;
    final letter =
        provider != null ? provider(root) : NetworkPath.driveLetterForUncShare(root);
    if (letter == null) return null;
    return '$letter${stored.substring(root.length)}';
  }

  // ==================== 工具 ====================

  static Future<bool> _dirExists(String path, {Duration? timeout}) async {
    final probe = debugProbe;
    if (probe != null) return probe(path, timeout ?? _probeTimeout);
    try {
      return await Directory(path)
          .exists()
          .timeout(timeout ?? _probeTimeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  static bool _sameShare(String a, String b) {
    final ra = NetworkPath.volumeRoot(a);
    final rb = NetworkPath.volumeRoot(b);
    if (ra == null || rb == null) return false;
    return ra.toLowerCase() == rb.toLowerCase();
  }
}
