// game_compatibility_service.dart
// 游戏启动程序的 Windows 兼容性属性自动配置
//
// 落点：`HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`
//   · 值名 = exe **绝对路径**（Windows 路径大小写不敏感，但值名按原样存储）
//   · 值   = 以 `~` 开头的空格分隔标志串
//
// 实测样本（本机 71 条真实值中的一条）：
//   `~ DISABLEDXMAXIMIZEDWINDOWEDMODE RUNASADMIN HIGHDPIAWARE WIN8RTM`
//   `~`                                → 以兼容模式运行此程序
//   `WIN8RTM`                          → 兼容模式 = Windows 8
//   `DISABLEDXMAXIMIZEDWINDOWEDMODE`   → 禁用全屏优化
//   `HIGHDPIAWARE`                     → 替代高 DPI 缩放（由应用程序执行缩放）
//   `RUNASADMIN`                       → 以管理员身份运行
//
// 设计取舍：
// 1. **每次启动前幂等 upsert**，不是"仅首次写入"。用户可能在属性页手改、
//    游戏目录会迁移、换 exe 会变 —— 每次校验一次（<5ms）比维护一份会过期的
//    状态可靠得多。
// 2. **只增删我们自己负责的标志**。用户手动勾的 256COLOR / DWM8And16BitMitigation
//    之类一律原样保留；回滚依据 `data/compat/managed.json` 的记录，
//    不靠"猜"，也不整条删值。
// 3. **不覆盖用户手设的兼容模式版本**：若注册表里已是 WIN7RTM 而我们想要
//    WIN8RTM，保留用户的 WIN7RTM 并记一条 warn —— 覆盖用户的显式选择比
//    "没按默认值执行"更糟。
// 4. RUNASADMIN 例外：它是「启动管理」里的显式开关，配置为 false 时无条件移除
//    （即便当初是用户手加的），否则 UI 与真实状态会长期错位。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import 'win32_registry_service.dart';

/// 兼容性标志常量（注册表里的字面量，不可随意改）
class CompatFlags {
  CompatFlags._();

  /// 「以兼容模式运行此程序」的启用标记
  static const String compatModeMarker = '~';

  /// 兼容模式 = Windows 8
  static const String win8 = 'WIN8RTM';

  /// 兼容模式 = Windows 7
  static const String win7 = 'WIN7RTM';

  /// 禁用全屏优化
  static const String disableFullscreenOptimization =
      'DISABLEDXMAXIMIZEDWINDOWEDMODE';

  /// 替代高 DPI 缩放行为（由应用程序执行缩放）
  static const String highDpiOverride = 'HIGHDPIAWARE';

  /// 以管理员身份运行
  static const String runAsAdmin = 'RUNASADMIN';

  /// 全部已知的「兼容模式版本」标志。
  /// 只用于**冲突检测**：同一台机器上兼容模式只能有一个版本。
  static const List<String> knownCompatVersions = <String>[
    'WIN95',
    'WIN98',
    'WINME',
    'NT4SP5',
    'WIN2000',
    'WINXPSP2',
    'WINXPSP3',
    'VISTARTM',
    'VISTASP1',
    'VISTASP2',
    'WIN7RTM',
    'WIN8RTM',
    'WIN81RTM',
  ];

  /// 输出顺序：与 Windows 属性页勾选后的落盘顺序一致，便于人眼比对
  static const List<String> outputOrder = <String>[
    disableFullscreenOptimization,
    runAsAdmin,
    highDpiOverride,
    win8,
  ];
}

/// 期望的兼容性配置（来自全局总开关 + 每游戏「以管理员身份运行」）
class CompatDesired {
  /// 启用「以兼容模式运行此程序」并选 Windows 8
  final bool win8CompatMode;

  /// 勾选「禁用全屏优化」
  final bool disableFullscreenOptimization;

  /// 勾选「替代高 DPI 缩放行为」
  final bool highDpiOverride;

  /// 勾选「以管理员身份运行」（每游戏独立，默认关闭）
  final bool runAsAdmin;

  const CompatDesired({
    this.win8CompatMode = true,
    this.disableFullscreenOptimization = true,
    this.highDpiOverride = true,
    this.runAsAdmin = false,
  });

  /// 全部关闭（总开关关掉且不需要管理员时使用）
  static const CompatDesired none = CompatDesired(
    win8CompatMode: false,
    disableFullscreenOptimization: false,
    highDpiOverride: false,
    runAsAdmin: false,
  );

  /// 由「全局总开关 + 每游戏管理员开关」组合出本次期望值。
  ///
  /// 🔴 关键：管理员开关**不受**总开关管辖。
  /// 总开关关掉只是不做兼容性优化，「以管理员身份运行」是用户对该游戏的
  /// 显式要求，必须照做 —— 否则用户会遇到"我明明开了管理员却启动失败"。
  factory CompatDesired.resolve({
    required bool autoConfigEnabled,
    required bool runAsAdmin,
  }) {
    return CompatDesired(
      win8CompatMode: autoConfigEnabled,
      disableFullscreenOptimization: autoConfigEnabled,
      highDpiOverride: autoConfigEnabled,
      runAsAdmin: runAsAdmin,
    );
  }

  CompatDesired copyWith({bool? runAsAdmin}) => CompatDesired(
        win8CompatMode: win8CompatMode,
        disableFullscreenOptimization: disableFullscreenOptimization,
        highDpiOverride: highDpiOverride,
        runAsAdmin: runAsAdmin ?? this.runAsAdmin,
      );

  /// 本次希望存在于注册表值里的标志（不含 `~`）
  Set<String> toTokens() {
    final tokens = <String>{};
    if (disableFullscreenOptimization) {
      tokens.add(CompatFlags.disableFullscreenOptimization);
    }
    if (highDpiOverride) tokens.add(CompatFlags.highDpiOverride);
    if (runAsAdmin) tokens.add(CompatFlags.runAsAdmin);
    return tokens;
  }

  /// 兼容模式是否要由我们写入 Windows 8
  bool get wantsWin8 => win8CompatMode;

  @override
  String toString() =>
      'CompatDesired(win8=$win8CompatMode, fsOpt=$disableFullscreenOptimization, '
      'dpi=$highDpiOverride, admin=$runAsAdmin)';
}

/// 注册表值解析结果
class CompatSnapshot {
  /// 原始值（null = 该 exe 在注册表里没有任何兼容性设置）
  final String? raw;

  /// 是否带 `~`（属性页里「以兼容模式运行此程序」处于勾选态）
  final bool compatModeEnabled;

  /// 兼容模式版本标志（WIN8RTM / WIN7RTM…），没有则为 null
  final String? compatVersion;

  /// 全部标志（不含 `~`），保持原出现顺序
  final List<String> tokens;

  const CompatSnapshot({
    required this.raw,
    required this.compatModeEnabled,
    required this.compatVersion,
    required this.tokens,
  });

  static const CompatSnapshot empty = CompatSnapshot(
    raw: null,
    compatModeEnabled: false,
    compatVersion: null,
    tokens: <String>[],
  );

  bool has(String token) => tokens.contains(token);

  bool get runAsAdmin => has(CompatFlags.runAsAdmin);
  bool get highDpiOverride => has(CompatFlags.highDpiOverride);
  bool get disableFullscreenOptimization =>
      has(CompatFlags.disableFullscreenOptimization);
}

/// 单次 ensure 的结果
class CompatResult {
  /// 是否真的改了注册表
  final bool changed;

  /// 操作是否成功（未变化也算成功）
  final bool ok;

  /// 操作类型，便于日志与测试断言：
  /// `skip` / `update` / `created` / `fail` / `unavailable` / `no-exe`
  final String action;

  final String? before;
  final String? after;

  /// 人类可读说明（失败原因 / 冲突提示）
  final String? detail;

  const CompatResult({
    required this.changed,
    required this.ok,
    required this.action,
    this.before,
    this.after,
    this.detail,
  });

  @override
  String toString() =>
      'CompatResult($action, changed=$changed, ok=$ok, detail=$detail)';
}

/// 兼容性配置服务（无状态调用，内部持有 managed 记录缓存）
class GameCompatibilityService {
  GameCompatibilityService._();

  static final GameCompatibilityService instance = GameCompatibilityService._();

  /// 注册表子键（HKCU 下）
  static const String registrySubKey =
      r'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers';

  /// 我们写入过哪些标志的记账文件（相对 data/）
  static const String _managedFileName = 'managed.json';

  /// exe 路径 → 我们写入过的标志集合
  Map<String, List<String>>? _managed;

  bool _loaded = false;

  // ══════════════════════════════════════════════
  // 路径规范化
  // ══════════════════════════════════════════════

  /// 把任意形态的 exe 路径规范成注册表值名形态。
  ///
  /// 🔴 必须做，理由来自实测：历史遗留值里存在
  /// `D:\Chrono Tide\Games/命运石之门_…/…exe`（正反斜杠混用）与
  /// 整段路径被重复拼接的脏值 —— 值名不一致就会产生永远命中不了的孤儿值。
  static String canonicalExePath(String exePath) {
    final trimmed = exePath.trim();
    if (trimmed.isEmpty) return '';
    try {
      return p.normalize(File(trimmed).absolute.path);
    } catch (_) {
      return p.normalize(trimmed);
    }
  }

  // ══════════════════════════════════════════════
  // 解析
  // ══════════════════════════════════════════════

  /// 把注册表原始字符串解析成结构
  static CompatSnapshot parse(String? raw) {
    if (raw == null) return CompatSnapshot.empty;
    final tokens = <String>[];
    var compatModes = false;
    for (final part in raw.split(' ')) {
      final token = part.trim();
      if (token.isEmpty) continue;
      if (token == CompatFlags.compatModeMarker) {
        compatModes = true;
        continue;
      }
      tokens.add(token);
    }
    String? version;
    for (final token in tokens) {
      if (CompatFlags.knownCompatVersions.contains(token)) {
        version = token;
        break;
      }
    }
    return CompatSnapshot(
      raw: raw,
      compatModeEnabled: compatModes || version != null,
      compatVersion: version,
      tokens: tokens,
    );
  }

  /// 读取某个 exe 当前的兼容性设置（不会创建任何东西）
  CompatSnapshot read(String exePath) {
    final canonical = canonicalExePath(exePath);
    if (canonical.isEmpty) return CompatSnapshot.empty;
    if (!Win32RegistryService.isAvailable) return CompatSnapshot.empty;
    final valueName = _resolveValueName(canonical);
    if (valueName == null) return CompatSnapshot.empty;
    final raw = Win32RegistryService.readString(
      subKey: registrySubKey,
      valueName: valueName,
    );
    return parse(raw);
  }

  /// 定位注册表里真实的值名（大小写不敏感）；不存在返回 null
  String? _resolveValueName(String canonical) {
    final exact = Win32RegistryService.readString(
      subKey: registrySubKey,
      valueName: canonical,
    );
    if (exact != null) return canonical;
    // 精确未命中 → 枚举做大小写不敏感匹配
    final names = Win32RegistryService.listValueNames(subKey: registrySubKey);
    final lower = canonical.toLowerCase();
    for (final name in names) {
      if (name.toLowerCase() == lower) return name;
    }
    return null;
  }

  // ══════════════════════════════════════════════
  // 写入（幂等）
  // ══════════════════════════════════════════════

  /// 确保该 exe 的兼容性属性符合 [desired]。
  ///
  /// 幂等：已经符合就只返回 `skip`，不写注册表。
  /// 失败一律不抛出 —— 调用方（启动流程）不允许被兼容性配置阻断。
  Future<CompatResult> ensure(String exePath, CompatDesired desired) async {
    final canonical = canonicalExePath(exePath);
    if (canonical.isEmpty) {
      return const CompatResult(
        changed: false,
        ok: false,
        action: 'no-exe',
        detail: '空路径',
      );
    }
    if (!Platform.isWindows) {
      return const CompatResult(
        changed: false,
        ok: false,
        action: 'unavailable',
        detail: '非 Windows 平台',
      );
    }
    if (!Win32RegistryService.isAvailable) {
      return const CompatResult(
        changed: false,
        ok: false,
        action: 'unavailable',
        detail: '注册表接口不可用',
      );
    }

    await _ensureManagedLoaded();
    final valueName = _resolveValueName(canonical) ?? canonical;
    final before = Win32RegistryService.readString(
      subKey: registrySubKey,
      valueName: valueName,
    );
    final snapshot = parse(before);

    final managedBefore = (_managed![canonical] ?? const <String>[])
        .map((e) => e.toUpperCase())
        .toSet();
    final desiredTokens =
        desired.toTokens().map((e) => e.toUpperCase()).toSet();

    // 1) 计算目标集合
    final result = <String>{...snapshot.tokens};

    // 1.1 我们以前加过、现在不要了 → 移除
    for (final token in managedBefore) {
      if (!desiredTokens.contains(token) &&
          !_isCompatVersionToken(token, desired)) {
        result.remove(token);
      }
    }
    // 1.2 现在要的 → 加上
    for (final token in desiredTokens) {
      result.add(token);
    }

    // 2) 兼容模式版本处理（不覆盖用户手设的其他版本）
    String? conflict;
    if (desired.wantsWin8) {
      final existingVersion = snapshot.compatVersion?.toUpperCase();
      final managedHasWin8 = managedBefore.contains(CompatFlags.win8);
      if (existingVersion == null) {
        result.add(CompatFlags.win8);
      } else if (existingVersion != CompatFlags.win8) {
        if (managedHasWin8) {
          // 是我们以前写的 Win8，被用户改成了别的版本 → 尊重用户，不夺回
          conflict = '用户已改为 $existingVersion，保留用户设置';
        } else {
          conflict = '注册表已有 $existingVersion（多为手动设置），保留原版本';
        }
      }
    } else {
      // 不用兼容模式：只撤掉**我们自己**写过的 Win8
      if (managedBefore.contains(CompatFlags.win8)) {
        result.remove(CompatFlags.win8);
        // 若去掉后没有任何兼容模式版本了，`~` 也一并撤掉（见序列化）
      }
    }

    // 3) RUNASADMIN 维护（UI 显式开关，关闭即无条件移除）
    if (!desired.runAsAdmin) {
      result.remove(CompatFlags.runAsAdmin);
    }

    final after = _serialize(result, snapshot);
    final changed = after != (before ?? '');
    if (!changed) {
      return CompatResult(
        changed: false,
        ok: true,
        action: 'skip',
        before: before,
        after: after,
        detail: conflict,
      );
    }

    if (after.isEmpty) {
      final ok = Win32RegistryService.deleteValue(
        subKey: registrySubKey,
        valueName: valueName,
      );
      if (ok) {
        await _recordManaged(canonical, const <String>[]);
      }
      return CompatResult(
        changed: ok,
        ok: ok,
        action: ok ? 'update' : 'fail',
        before: before,
        after: null,
        detail: conflict ?? (ok ? '已清空并删除值' : '删除注册表值失败'),
      );
    }

    final writeOk = Win32RegistryService.writeString(
      subKey: registrySubKey,
      valueName: valueName,
      value: after,
    );
    if (writeOk) {
      // 记账：把当前值里属于"我们负责的"标志都记下来（含用户本就有的同项）
      final managedNow = <String>[
        for (final token in _serializeTokens(result, snapshot))
          if (_isManagedToken(token)) token,
      ];
      await _recordManaged(canonical, managedNow);
    }
    return CompatResult(
      changed: writeOk,
      ok: writeOk,
      action: writeOk ? (before == null ? 'created' : 'update') : 'fail',
      before: before,
      after: after,
      detail: conflict ?? (writeOk ? null : '写入注册表失败'),
    );
  }

  /// 把该 exe 上**我们写入过**的标志全部撤销（保留用户手设的其他标志）。
  ///
  /// 总开关关闭时对每个游戏调用一次。返回是否真的改了注册表。
  Future<CompatResult> rollback(String exePath) async {
    final canonical = canonicalExePath(exePath);
    if (canonical.isEmpty) {
      return const CompatResult(
        changed: false,
        ok: false,
        action: 'no-exe',
      );
    }
    if (!Win32RegistryService.isAvailable) {
      return const CompatResult(
          changed: false, ok: false, action: 'unavailable');
    }
    await _ensureManagedLoaded();
    final managedBefore = _managed![canonical] ?? const <String>[];
    if (managedBefore.isEmpty) {
      // 没记过账 → 不知道该撤什么，宁可不碰
      return const CompatResult(
        changed: false,
        ok: true,
        action: 'skip',
        detail: '无写入记录，未做任何修改',
      );
    }
    return ensure(canonical, CompatDesired.none);
  }

  /// 目录迁移：把兼容性值名从旧 exe 路径改到新 exe 路径
  ///
  /// 由 `LocalGameRegistry.finalizeGameMove` 调用。找不到旧值直接返回 false。
  Future<bool> migratePath({
    required String oldExePath,
    required String newExePath,
  }) async {
    final oldCanonical = canonicalExePath(oldExePath);
    final newCanonical = canonicalExePath(newExePath);
    if (oldCanonical.isEmpty || newCanonical.isEmpty) return false;
    if (oldCanonical.toLowerCase() == newCanonical.toLowerCase()) return false;
    if (!Win32RegistryService.isAvailable) return false;

    final oldValueName = _resolveValueName(oldCanonical);
    if (oldValueName == null) return false;
    final raw = Win32RegistryService.readString(
      subKey: registrySubKey,
      valueName: oldValueName,
    );
    if (raw == null || raw.isEmpty) return false;

    final written = Win32RegistryService.writeString(
      subKey: registrySubKey,
      valueName: newCanonical,
      value: raw,
    );
    if (!written) return false;
    final removed = Win32RegistryService.deleteValue(
      subKey: registrySubKey,
      valueName: oldValueName,
    );
    if (!removed) {
      debugPrint('[COMPAT] ⚠️ 旧值名删除失败（新值已写入）: $oldValueName');
    }

    await _ensureManagedLoaded();
    final managed = _managed!.remove(oldCanonical);
    if (managed != null) {
      _managed![newCanonical] = managed;
      await _saveManaged();
    }
    debugPrint('[COMPAT] ✅ 兼容性值名已迁移: $oldValueName → $newCanonical');
    return true;
  }

  // ══════════════════════════════════════════════
  // 序列化
  // ══════════════════════════════════════════════

  String _serialize(Set<String> tokens, CompatSnapshot before) {
    final ordered = _serializeTokens(tokens, before);
    if (ordered.isEmpty) return '';
    return '${CompatFlags.compatModeMarker} ${ordered.join(' ')}';
  }

  /// 固定顺序输出：已知标志按 [CompatFlags.outputOrder]，未知标志保持原出现顺序
  List<String> _serializeTokens(Set<String> tokens, CompatSnapshot before) {
    final ordered = <String>[];
    for (final token in CompatFlags.outputOrder) {
      if (tokens.contains(token) && !ordered.contains(token)) {
        ordered.add(token);
      }
    }
    for (final token in before.tokens) {
      if (tokens.contains(token) && !ordered.contains(token)) {
        ordered.add(token);
      }
    }
    // 兼容模式版本（WIN7RTM 等不在 outputOrder 里的）
    for (final token in tokens) {
      if (!ordered.contains(token)) ordered.add(token);
    }
    return ordered;
  }

  bool _isCompatVersionToken(String token, CompatDesired desired) {
    if (CompatFlags.knownCompatVersions.contains(token)) {
      // Win8 归我们管；其他版本是用户手设，永不由差异法移除
      return token == CompatFlags.win8 && desired.wantsWin8;
    }
    return false;
  }

  bool _isManagedToken(String token) {
    return token == CompatFlags.win8 ||
        token == CompatFlags.highDpiOverride ||
        token == CompatFlags.disableFullscreenOptimization ||
        token == CompatFlags.runAsAdmin;
  }

  // ══════════════════════════════════════════════
  // 记账文件
  // ══════════════════════════════════════════════

  static String get managedStorePath =>
      p.join(PathHelper.dataDir, 'compat', _managedFileName);

  Future<void> _ensureManagedLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _managed = <String, List<String>>{};
    try {
      final file = File(managedStorePath);
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return;
      final entries = decoded['entries'];
      if (entries is! Map) return;
      entries.forEach((key, value) {
        if (key is String && value is List) {
          _managed![key] = value
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      });
    } catch (e) {
      debugPrint('[COMPAT] ⚠️ 读取记账文件失败（按空记录处理）: $e');
    }
  }

  Future<void> _recordManaged(String canonical, List<String> tokens) async {
    await _ensureManagedLoaded();
    if (tokens.isEmpty) {
      _managed!.remove(canonical);
    } else {
      _managed![canonical] = tokens;
    }
    await _saveManaged();
  }

  Future<void> _saveManaged() async {
    try {
      final dir = Directory(p.dirname(managedStorePath));
      if (!await dir.exists()) await dir.create(recursive: true);
      final payload = <String, dynamic>{
        'version': 1,
        'entries': _managed ?? <String, List<String>>{},
      };
      await File(managedStorePath)
          .writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    } catch (e) {
      debugPrint('[COMPAT] ⚠️ 写入记账文件失败（不影响本次启动）: $e');
    }
  }

  /// 当前记账条数（诊断用）
  Future<int> managedEntryCount() async {
    await _ensureManagedLoaded();
    return _managed?.length ?? 0;
  }

  /// 全部被记录过的 exe 路径（总开关关闭时用于批量回滚）
  Future<List<String>> managedExePaths() async {
    await _ensureManagedLoaded();
    return (_managed?.keys ?? const <String>[]).toList();
  }

  /// 批量撤销所有记账过的 exe（总开关关闭时调用）。
  ///
  /// 纯基于记账文件，不依赖游戏列表 —— 即使用户已经把游戏删了，
  /// 也能把残留的注册表项清干净。返回真正发生变动的条数。
  Future<int> rollbackAllManaged() async {
    final paths = await managedExePaths();
    var changedCount = 0;
    for (final path in paths) {
      try {
        final result = await rollback(path);
        if (result.changed) changedCount++;
      } catch (e) {
        debugPrint('[COMPAT] ⚠️ 回滚失败（跳过）: $path → $e');
      }
    }
    debugPrint('[COMPAT] 批量回滚完成: $changedCount/${paths.length} 条发生变动');
    return changedCount;
  }

  /// 仅供单测：重置内部缓存
  @visibleForTesting
  void resetForTest() {
    _managed = null;
    _loaded = false;
  }
}
