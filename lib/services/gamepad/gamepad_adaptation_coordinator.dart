/// 游戏手柄适配 —— 会话协调器（2026-09-27 v2：附加服务 + 启动前确认）
///
/// 职责（按 2026-09-27 用户拍板的产品流程重构）：
/// - **不再有「首次启动询问」**：映射的启停由用户在**启动前**决定 ——
///   BPM 启动入口先经 [resolveLaunchPref] 弹「手柄映射确认」弹窗
///   （是否启用 + 选预设），确认结果写入 `data/gamepad_profiles.json`，
///   游戏会话确认存活后（[onSessionConfirmed]）**直接按配置启动会话**；
/// - **单实例 raw 消费（附加模式）**：会话不再自建第二套 SDL3/XInput/DInput
///   后端（双实例互抢事件 + stop 双重 dispose 曾导致堆损坏崩溃 0xC0000374
///   与 BPM 手柄永久死亡），而是 [attachGamepadService] 挂到 BPM shell 的
///   服务上消费 raw 流；桌面模式（无 BPM 服务）回退自建后端；
/// - 单例：`running_tasks_service._onSessionConfirmed` 直接调用；
/// - 结束回调链式挂载（保留 TrayService 处理器，身份比对幂等）；
/// - 全程 try-catch：协调器任何异常都不能影响游戏启动/时长统计主流程。
library;

import 'dart:ffi' as ffi;

import 'package:flutter/foundation.dart'
    show ChangeNotifier, visibleForTesting;

import '../../big_picture/services/bpm_gamepad_service.dart'
    show BpmGamepadService;
import '../local_game_registry.dart';
import 'gamepad_adaptation_session.dart';
import 'gamepad_log.dart';
import 'gamepad_profile.dart'
    show
        GamepadPresets,
        GamepadProfile,
        GamepadMapping,
        GamepadProfileFile;
import 'gamepad_profile_store.dart';
import 'input_injector.dart' show ForegroundChecker, User32ForegroundChecker;

/// 启动前的映射偏好（BPM 确认弹窗的数据源）
class GamepadLaunchPref {
  const GamepadLaunchPref({
    required this.gameId,
    required this.gameTitle,
    required this.enabled,
    required this.presetId,
  });

  final String gameId;
  final String gameTitle;

  /// `data/gamepad_profiles.json` 里该游戏的独立开关（主页手柄按钮控制）
  final bool enabled;

  /// 该游戏命中的预设（专属 > 全局默认 > SteamOS 通用）
  final String presetId;
}

class GamepadAdaptationCoordinator extends ChangeNotifier {
  GamepadAdaptationCoordinator._();

  static final GamepadAdaptationCoordinator instance =
      GamepadAdaptationCoordinator._();

  GamepadAdaptationSession? _active;
  String? _activeGameId;
  void Function(String gameTitle, int sessionSeconds)? _ourEndedHook;

  /// BPM shell 的手柄服务（附加模式的数据源；桌面模式为 null）
  BpmGamepadService? _attachedService;

  /// BPM shell 在 initState 里注入（附加模式）；桌面模式不注入 → 回退自建。
  void attachGamepadService(BpmGamepadService service) {
    if (identical(_attachedService, service)) return;
    _attachedService = service;
    GamepadLog.log('[GAMEPAD] 已附加 BPM 手柄服务（单实例 raw 消费模式）');
  }

  void detachGamepadService() {
    if (_attachedService == null) return;
    _attachedService = null;
    GamepadLog.log('[GAMEPAD] 已摘除 BPM 手柄服务附加');
  }

  /// 当前活跃会话（诊断面板 Phase 4 消费）
  GamepadAdaptationSession? get activeSession => _active;
  String? get activeGameId => _activeGameId;

  /// 是否有活跃的游戏适配会话
  ///
  /// 🔴 供 BPM 手柄服务做**互斥闸门**（与 [isGameForeground] 联用）：
  /// 游戏前台期间 BPM 必须停止语义消费。
  bool get hasActiveSession => _active != null;

  /// 当前会话的前台判定器（Guard 包装，pid 归一后 == targetPid 即游戏在前台）
  ForegroundChecker? _activeForeground;
  int? _activeTargetPid;

  /// isGameForeground 判定结果缓存（250ms）—— dispatchGate 每 16ms 调用，
  /// Guard 的 exe 查询虽有 per-pid 缓存，仍省掉重复 GetForegroundWindow。
  DateTime _fgCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fgCached = false;

  /// 「当前活跃会话的游戏进程是否在前台」（判定结果缓存 250ms）。
  ///
  /// 🔴 供 shell 的 dispatchGate 做前台感知：
  /// `gate = hasActiveSession && isGameForeground` —— 用户 Alt+Tab 回
  /// Chrono Tide 时 BPM 手柄导航**立即恢复**（修复「切回软件手柄死区」）。
  bool get isGameForeground {
    if (_active == null) return false;
    final checker = _activeForeground;
    if (checker == null || _activeTargetPid == null) return false;
    final now = DateTime.now();
    if (now.difference(_fgCheckedAt) < const Duration(milliseconds: 250)) {
      return _fgCached;
    }
    _fgCheckedAt = now;
    _fgCached = checker.foregroundPid() == _activeTargetPid;
    return _fgCached;
  }

  // ── 本应用前台判定（2026-10-06「玩游戏时 BPM 界面同时乱动」修复）──

  /// 生产路径的自查组件（懒加载；非 Windows / 缺 DLL 为 null）
  User32ForegroundChecker? _selfForeground;
  int? _selfPid;

  /// 测试注入：前台 checker 与「本应用 pid」覆盖（非 null 时优先于生产路径）
  ForegroundChecker? _selfForegroundOverride;
  int? _selfPidOverride;

  /// 本应用前台判定结果缓存（250ms）—— dispatchGate 每 16ms 调用
  DateTime _appFgCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _appFgCached = false;

  /// 「Chrono Tide 自身窗口是否是前台窗口」（判定结果缓存 250ms）。
  ///
  /// 🔴 背景：BPM 手柄是 FFI 全局轮询（XInput/SDL3/DInput），**不经过窗口
  /// 焦点** —— 不做本判定的话，游戏（或任何其他应用）前台时 BPM 照常消费
  /// 语义事件，玩游戏手柄按 A，BPM 界面同时把它当「确认」，两边同时动。
  /// 旧闸门条件 `hasActiveSession && isGameForeground` 只覆盖「开了映射
  /// 会话」的场景，覆盖不了「未启用映射 / 游戏无 pid / 无 game_id」的情况。
  ///
  /// 语义约定：
  /// - 查询不可用（非 Windows / FFI 失败）→ 返回 true（视为前台，维持
  ///   本修复之前的旧行为）—— FFI 坏了宁可回到旧 bug，也不能让 BPM 导航
  ///   永久失灵；
  /// - 判定不可靠时保守返回 false（让路）只发生在「前台窗口不属于本
  ///   进程」，这正是期望行为。
  bool get isAppForeground {
    final checker = _selfForegroundOverride ?? (_selfForeground ??=
        User32ForegroundChecker.tryCreate());
    final selfPid =
        _selfPidOverride ?? (_selfPid ??= _querySelfPid());
    if (checker == null || selfPid == null) return true; // 查询不可用：旧行为
    final now = DateTime.now();
    if (now.difference(_appFgCheckedAt) < const Duration(milliseconds: 250)) {
      return _appFgCached;
    }
    _appFgCheckedAt = now;
    _appFgCached = checker.foregroundPid() == selfPid;
    return _appFgCached;
  }

  /// kernel32!GetCurrentProcessId（进程 pid 终身不变，查一次即缓存）
  static int? _querySelfPid() {
    try {
      final lib = ffi.DynamicLibrary.open('kernel32.dll');
      final fn = lib
          .lookupFunction<ffi.Uint32 Function(), int Function()>(
              'GetCurrentProcessId');
      return fn();
    } catch (_) {
      return null;
    }
  }

  /// 测试注入：替换前台 checker 与本应用 pid（同时清空判定缓存）。
  /// 传 `(null, null)` 恢复生产路径。
  @visibleForTesting
  void debugOverrideAppForegroundChecker(
      ForegroundChecker? checker, int? selfPid) {
    _selfForegroundOverride = checker;
    _selfPidOverride = selfPid;
    _appFgCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _appFgCached = false;
  }

  /// 由 `running_tasks_service._onSessionConfirmed` 调用（每会话恰好一次）。
  /// [pid] 为会话的主追踪 PID（`_GameSession.bestPid`），可能为 null
  /// （启动器型游戏未捕获到 PID）——此时跳过适配并记日志。
  void onSessionConfirmed({
    required String gameTitle,
    required String metaDataDir,
    required int? pid,
  }) {
    try {
      unawaitedSafe(_onConfirmed(
        gameTitle: gameTitle,
        metaDataDir: metaDataDir,
        pid: pid,
      ));
    } catch (e) {
      GamepadLog.log('[GAMEPAD] ⚠️ 会话确认处理异常（不影响游戏）: $e');
    }
  }

  Future<void> _onConfirmed({
    required String gameTitle,
    required String metaDataDir,
    required int? pid,
  }) async {
    // 结束钩子先就位（幂等）：会话一旦确认，退出时必须能停掉手柄会话
    _ensureEndedHook();

    if (pid == null) {
      GamepadLog.log('[GAMEPAD] 未捕获游戏 PID，跳过手柄适配: $gameTitle');
      return;
    }

    final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
    final gameId = game?.gameId;
    if (gameId == null || gameId.isEmpty) {
      GamepadLog.log('[GAMEPAD] 找不到 game_id，跳过手柄适配: $gameTitle');
      return;
    }

    // 🔴 启用与否已由用户在**启动前**决定（主页手柄按钮 / 启动确认弹窗），
    // 会话确认这里只照配置直启 —— 同一游戏的重复会话确认（启动器型游戏
    // launcher→真游戏切换）幂等：会话已活跃则跳过。
    if (hasActiveSession && _activeGameId == gameId) {
      GamepadLog.log('[GAMEPAD] 同游戏会话已活跃，跳过重复确认: $gameTitle');
      return;
    }

    final file = await GamepadProfileStore.load();
    final entry = file.profiles[gameId];
    if (entry == null || !entry.enabled) {
      GamepadLog.log('[GAMEPAD] 该游戏未启用手柄适配（用户配置）: $gameTitle');
      return;
    }
    final profile = file.effectiveFor(gameId);
    if (!profile.enabled) {
      GamepadLog.log('[GAMEPAD] 该游戏已禁用手柄适配（生效配置）: $gameTitle');
      return;
    }

    await _startSession(
      pid: pid,
      profile: profile,
      gameId: gameId,
      gameDirectoryPath: game?.directoryPath ?? '',
    );
  }

  /// 结束钩子：链式包装现有处理器（通常是 TrayService 的 Toast 通知），
  /// 身份比对保证幂等 —— 每次会话确认都调用，但只在「槽位不是我们的链」时重挂。
  void _ensureEndedHook() {
    final registry = LocalGameRegistry.instance;
    final current = registry.onGameSessionEnded;
    if (_ourEndedHook != null && identical(current, _ourEndedHook)) return;

    final previous = current;
    _ourEndedHook = (gameTitle, sessionSeconds) {
      previous?.call(gameTitle, sessionSeconds);
      try {
        _onEnded(gameTitle);
      } catch (e) {
        GamepadLog.log('[GAMEPAD] ⚠️ 会话结束处理异常: $e');
      }
    };
    registry.onGameSessionEnded = _ourEndedHook;
    GamepadLog.log('[GAMEPAD] 已挂载游戏退出钩子（链式，保留原有处理器）');
  }

  void _onEnded(String gameTitle) {
    _stopActive('游戏退出');
  }

  void _stopActive(String reason) {
    final session = _active;
    if (session == null) return;
    session.stop();
    _active = null;
    _activeGameId = null;
    _activeForeground = null;
    _activeTargetPid = null;
    GamepadLog.log('[GAMEPAD] 会话已停止（$reason）');
  }

  /// 启动前的偏好解析（BPM 确认弹窗调用）：读每游戏配置 + 建议预设
  Future<GamepadLaunchPref?> resolveLaunchPref(String gameTitle) async {
    try {
      final game = LocalGameRegistry.instance.getGameByTitle(gameTitle);
      final gameId = game?.gameId;
      if (gameId == null || gameId.isEmpty) return null;
      final file = await GamepadProfileStore.load();
      final entry = file.profiles[gameId];
      final presetId = entry?.preset ?? file.defaults.preset;
      return GamepadLaunchPref(
        gameId: gameId,
        gameTitle: gameTitle,
        enabled: entry?.enabled ?? false,
        presetId: presetId ?? GamepadPresets.steamosVnId,
      );
    } catch (e) {
      GamepadLog.log('[GAMEPAD] ⚠️ 读取启动偏好失败: $e');
      return null;
    }
  }

  /// 预设选项快照（内置 + 自定义），供弹窗下拉；[file] 缺省时自行加载
  Future<List<(String, String)>> loadPresetOptions(
      [GamepadProfileFile? file]) async {
    final f = file ?? await GamepadProfileStore.load();
    final options = <(String, String)>[
      (GamepadPresets.steamosVnId, 'SteamOS 通用方案（推荐）'),
      (GamepadPresets.genericVnId, '经典方案（键盘直映）'),
    ];
    for (final p in f.customPresets.values) {
      options.add((p.id, '自定义 · ${p.name}'));
    }
    return options;
  }

  /// 保存启动确认弹窗 / 主页手柄按钮的选择（每游戏开关 + 预设）
  ///
  /// [mappings] 为 null 时按 [presetId] 展开内置预设；非 null 时原样保存
  /// （编辑器自定义映射路径）。
  Future<void> saveLaunchChoice({
    required String gameId,
    required String gameTitle,
    required bool enabled,
    required String presetId,
    List<GamepadMapping>? mappings,
  }) async {
    try {
      final file = await GamepadProfileStore.load();
      final existing = file.profiles[gameId];
      final effectiveMappings = mappings ??
          (identical(presetId, existing?.preset) && existing != null
              ? existing.mappings
              : (file.mappingsFor(presetId) ?? GamepadPresets.steamosVn));
      file.profiles[gameId] = (existing ?? const GamepadProfile()).copyWith(
        gameTitle: gameTitle,
        preset: presetId,
        enabled: enabled,
        mappings: effectiveMappings,
      );
      await GamepadProfileStore.save(file);
      GamepadLog.log(
          '[GAMEPAD] 已保存启动选择: $gameTitle enabled=$enabled preset=$presetId');
    } catch (e) {
      GamepadLog.log('[GAMEPAD] ⚠️ 保存启动选择失败: $e');
    }
  }

  Future<void> _startSession({
    required int pid,
    required GamepadProfile profile,
    required String gameId,
    String gameDirectoryPath = '',
  }) async {
    _stopActive('新会话启动');
    // 🔴 附加模式：优先挂 BPM 的单实例服务（事件/仲裁/native 资源全部单份）
    final session = GamepadAdaptationSession.tryStart(
      targetPid: pid,
      profile: profile,
      gameDirectoryPath: gameDirectoryPath,
      externalService: _attachedService,
      onLog: GamepadLog.log,
    );
    if (session == null) {
      _activeForeground = null;
      _activeTargetPid = null;
      return;
    }
    _active = session;
    _activeGameId = gameId;
  }

  /// 应用退出/测试用：停掉活跃会话并摘除结束钩子
  void detach() {
    _stopActive('detach');
    final registry = LocalGameRegistry.instance;
    if (_ourEndedHook != null &&
        identical(registry.onGameSessionEnded, _ourEndedHook)) {
      registry.onGameSessionEnded = null;
    }
    _ourEndedHook = null;
  }
}

/// 不让孤立的 Future 异常逃逸到调用方
void unawaitedSafe(Future<void> future) {
  future.catchError((Object e) {
    GamepadLog.log('[GAMEPAD] ⚠️ 异步处理异常: $e');
  });
}
