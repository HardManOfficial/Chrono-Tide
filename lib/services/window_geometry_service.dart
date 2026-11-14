// 窗口几何持久化 —— 记住上次退出时的位置 / 尺寸 / 最大化状态，下次启动原样恢复。
//
// 背景（为什么需要它）：
//   阶段 A 修掉了「默认尺寸不按工作区钳制」，但窗口几何**完全不持久化** ——
//   每次启动都回到 1280×720 居中。对大屏用户来说这等于每次开机都要重新最大化 /
//   重新摆位；而窗口一旦被摆到不合适的位置，唯一出路是阶段 B 的托盘逃生入口
//   （用户得先知道有那个菜单）。本服务补上「记住上次几何」这一环。
//
// 与既有两条链路的关系：
//   ① 启动默认值（阶段 A，`startup_window_size.dart` 的 `resolveStartupWindowSize`）
//      继续生效，作为**没存过几何 / 几何已失效**时的回落；
//   ② 托盘「重置窗口位置与尺寸」（阶段 B）继续作为用户可主动触发的逃生出口，
//      复位后的新几何会被本服务自动记下来。
//
// 🔴 三个关键决策（都有踩坑依据，勿轻易改）：
//   1. **一律物理像素**：插件的 `getBounds/setBounds` 都乘/除 `getDevicePixelRatio()`
//      （= **窗口所在屏** 的 DPR），窗口跨不同 DPI 显示器移动时逻辑值会漂；而阶段 B
//      已确立「物理像素 + FFI `SetWindowPos`」的口径（`applyMainWindowRect`）。
//      这里读用 `readMainWindowRectPhysical`、写用 `applyMainWindowRect`，同源同款。
//   2. **恢复必须发生在 `show()` 之前**（见 `main.dart` 的 `waitUntilReadyToShow`
//      回调），否则用户会看到窗口「先居中再跳走」。
//   3. **恢复「最大化」必须延到首帧之后**（`applyDeferredMaximize`）：`main.dart` 既有
//      注释已实测记载，frameless 窗口在 FlutterView 建立前收到 `SC_MAXIMIZE` 会导致
//      客户区异常 + 界面冻结（同 `setFullScreen` 的坑）。
//
// 保存侧的三重守卫（都会跳过写盘）：
//   ① 启动恢复完成前不写（否则会拿默认尺寸把上次几何覆盖掉）；
//   ② 大屏模式 / 全屏期间不写（否则会把 BPM 铺屏矩形存成「用户几何」）；
//   ③ 最小化期间不写。
// 另外 400ms 防抖 —— 拖拽窗口会高频触发 `onWindowResized`。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../big_picture/big_picture_manager.dart';
import 'startup_window_size.dart';

/// 窗口几何持久化服务（单例）。
///
/// 自身实现 [WindowListener] 并挂到 `windowManager` 的**监听列表**上
/// （该列表支持多实例：`custom_title_bar.dart` 已有另一份在跑），
/// 因此 `main.dart` 只需在既有 `windowManager.addListener(this)` 旁调用一次
/// [attach]，无需把保存逻辑塞进稳定区文件。
class WindowGeometryService with WindowListener {
  WindowGeometryService._();

  static final WindowGeometryService instance = WindowGeometryService._();

  // ── SharedPreferences 键（物理像素 int）──
  static const String _kX = 'win_geom_x';
  static const String _kY = 'win_geom_y';
  static const String _kW = 'win_geom_w';
  static const String _kH = 'win_geom_h';
  static const String _kDpi = 'win_geom_dpi';
  static const String _kMaximized = 'win_geom_maximized';

  /// 拖拽窗口时 `onWindowResized` 高频触发，落盘做防抖。
  static const Duration _kSaveDebounce = Duration(milliseconds: 400);

  bool _attached = false;
  bool _restoreDone = false;
  bool _pendingMaximized = false;
  Timer? _saveDebounce;

  /// 是否已挂到 windowManager（供诊断）。
  bool get attached => _attached;

  /// 挂到 `windowManager` 的监听列表（幂等）。需在窗口就绪前调用一次。
  void attach() {
    if (_attached) return;
    _attached = true;
    windowManager.addListener(this);
    debugPrint('[WIN-GEOM] 已挂载窗口几何持久化监听');
  }

  /// 启动时恢复上次的窗口几何。
  ///
  /// 🔴 必须在 `windowManager.show()` **之前**调用（`waitUntilReadyToShow` 回调内），
  /// 否则用户会看到窗口先居中再跳到目标位置。
  ///
  /// 返回是否真的下发了矩形；任何一步拿不到 / 失败都返回 `false`，
  /// 此时调用方维持既有默认路径（居中 + 工作区钳制），等价于本服务不存在。
  Future<bool> restoreBeforeShow() async {
    try {
      final saved = await _load();
      if (saved == null) {
        debugPrint('[WIN-GEOM] 无历史几何，使用默认尺寸');
        return false;
      }

      // 保存时所在的那块屏还在吗？（MONITOR_DEFAULTTONULL 判定）
      final WorkAreaPhysical? area = readWorkAreaNearRect(saved.rect);
      if (area == null) {
        debugPrint('[WIN-GEOM] 历史几何已不落在任何显示器上，回落默认居中: '
            '${saved.rect.width}x${saved.rect.height}'
            '@(${saved.rect.left},${saved.rect.top})');
        return false;
      }

      final ResetWindowGeometry? geo = computeRestoreGeometry(
        saved: saved.rect,
        savedDpi: saved.dpi,
        target: area,
      );
      if (geo == null) {
        debugPrint('[WIN-GEOM] 历史几何不可用，回落默认居中');
        return false;
      }

      // bringToFront: false —— 此刻窗口还没 show()，抢 z-order/焦点只会与
      // 紧随其后的 show() + focus() 打架。
      final bool applied = applyMainWindowRect(
        x: geo.x,
        y: geo.y,
        width: geo.width,
        height: geo.height,
        bringToFront: false,
      );
      try {
        await windowManager.setMinimumSize(Size(geo.minWidth, geo.minHeight));
      } catch (e) {
        debugPrint('[WIN-GEOM] 重写最小尺寸失败: $e');
      }

      _pendingMaximized = saved.maximized;
      debugPrint('[WIN-GEOM] 恢复几何: win=${geo.width}x${geo.height}'
          '@(${geo.x},${geo.y}) scale=${geo.scale} applied=$applied '
          'maximized=${saved.maximized} '
          'work=${geo.workAreaWidth}x${geo.workAreaHeight}');
      return applied;
    } catch (e) {
      debugPrint('[WIN-GEOM] 恢复几何异常，回落默认居中: $e');
      return false;
    } finally {
      // 🔴 无论成败都要开门：否则保存侧的第一条守卫会永久拦截所有写盘。
      _restoreDone = true;
    }
  }

  /// 首帧之后套用「上次退出时是最大化」。
  ///
  /// 🔴 不能在首帧前做 —— 见文件头注释第 3 条。
  /// 大屏模式已被 `restoreFromPrefs` 恢复时跳过（两条链路会互相覆盖）。
  Future<void> applyDeferredMaximize() async {
    if (!_pendingMaximized) return;
    _pendingMaximized = false;
    try {
      if (BigPictureManager.instance.isActive) {
        debugPrint('[WIN-GEOM] 大屏模式已恢复，跳过最大化还原');
        return;
      }
      await windowManager.maximize();
      debugPrint('[WIN-GEOM] 已恢复最大化状态');
    } catch (e) {
      debugPrint('[WIN-GEOM] 恢复最大化失败: $e');
    }
  }

  // ───────────────────────── 保存链路 ─────────────────────────

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowRestore() => _scheduleSave();

  /// 防抖登记一次保存。启动恢复完成前一律忽略（避免把默认尺寸覆盖掉历史几何）。
  void _scheduleSave() {
    if (!_attached || !_restoreDone) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_kSaveDebounce, () => unawaited(_save()));
  }

  /// 立即落盘一次（供诊断 / 未来退出流程复用）。
  Future<void> flush() async {
    _saveDebounce?.cancel();
    if (!_attached) return;
    await _save();
  }

  /// 读窗口当前几何并写盘。全程容错，绝不抛。
  Future<void> _save() async {
    try {
      final WindowRectPhysical? rect = readMainWindowRectPhysical();
      if (rect == null) return;

      // 守卫②：大屏模式 / 全屏期间存下来的会是铺屏矩形，不是「用户几何」
      if (BigPictureManager.instance.isActive) return;
      if (await windowManager.isFullScreen()) return;
      // 守卫③：最小化时 GetWindowRect 给的是图标位置
      if (await windowManager.isMinimized()) return;

      final WorkAreaPhysical? area = readWorkAreaPhysical();
      final int dpi = area?.dpi ?? 0;
      final bool maximized = await windowManager.isMaximized();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kX, rect.left);
      await prefs.setInt(_kY, rect.top);
      await prefs.setInt(_kW, rect.width);
      await prefs.setInt(_kH, rect.height);
      await prefs.setInt(_kDpi, dpi);
      await prefs.setBool(_kMaximized, maximized);

      debugPrint('[WIN-GEOM] 已保存几何: ${rect.width}x${rect.height}'
          '@(${rect.left},${rect.top}) dpi=$dpi maximized=$maximized');
    } catch (e) {
      debugPrint('[WIN-GEOM] 保存几何异常: $e');
    }
  }

  /// 读历史几何。缺任何一项都视为「没存过」（`?? 缺省`，不引入迁移）。
  Future<({WindowRectPhysical rect, int dpi, bool maximized})?> _load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int? x = prefs.getInt(_kX);
      final int? y = prefs.getInt(_kY);
      final int? w = prefs.getInt(_kW);
      final int? h = prefs.getInt(_kH);
      if (x == null || y == null || w == null || h == null) return null;
      if (w <= 0 || h <= 0) return null;
      return (
        rect: (left: x, top: y, width: w, height: h),
        dpi: prefs.getInt(_kDpi) ?? 0,
        maximized: prefs.getBool(_kMaximized) ?? false,
      );
    } catch (e) {
      debugPrint('[WIN-GEOM] 读取历史几何失败: $e');
      return null;
    }
  }

  /// 退出流程可调用：取消防抖并摘掉监听（当前无调用点，进程退出即失效）。
  void detach() {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    if (!_attached) return;
    _attached = false;
    windowManager.removeListener(this);
  }
}
