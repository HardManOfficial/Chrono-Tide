// 窗口几何决策：按显示器工作区钳制启动尺寸，并把被裁到屏外的窗口复位回来。
//
// 背景（为什么需要它）：
//   原先 `lib/main.dart` 无条件下发 `Size(1280, 720)` / `minimumSize(960, 540)`，
//   完全不感知显示器工作区。在「小屏 + 高缩放」的真实组合下（典型：12.5" 1366×768
//   @125%、14" 1920×1080 @150%）窗口会超出工作区，四边出血；而本应用是
//   `setAsFrameless()` + 自绘 32px 标题栏，**没有系统标题栏可兜底**，一旦右上角的
//   关闭/最大化/最小化三键被推出屏幕，鼠标就够不到了。
//
// 本文件承担两条链路（共用同一套「工作区 + 边距」口径，避免出现第二份魔数）：
//   ① 启动：[resolveStartupWindowSize] —— 读**窗口所在屏**工作区 → 收窄期望尺寸
//      → 返回逻辑像素给 `WindowOptions`。放得下时结果与改动前**逐字节一致**；
//      不设 maximumSize，用户仍可自由最大化/拉伸。
//   ② 复位：[resetMainWindowToVisibleWorkArea] —— 读**光标所在屏**工作区 →
//      算物理像素矩形 → `SetWindowPos`。这是托盘菜单的逃生入口（窗口被拖到屏外、
//      显示器/缩放变更后尺寸不再匹配时，用户没有任何窗口内可点的手段）。
//
// 🔴 硬约束：本文件**不 import Flutter / dart:ui**，只用 dart:ffi + dart:io。
//   原因同 `openlist_update_core.dart`：需要探针用 `dart.exe` 直跑真实代码
//   （见 `.workbuddy/probe_window_size/probe_dart.dart`，27 PASS / 0 FAIL）。
//
// 口径自洽性（本方案最关键的鲁棒点）：
//   `windowManager.setSize(w, h)` 在原生侧会做 `w × devicePixelRatio`。只要这里的
//   除数用的是**同一个** DPR（`windowManager.getDevicePixelRatio()`），
//   `setSize(workLogical)` 得到的物理尺寸就**恰好等于真实工作区**——
//   **不依赖该 DPR 是否"物理正确"**。DPR 读偏小 → 钳制变松（退化为改动前行为）；
//   读偏大 → 略微多缩（仍可用）。两个方向都不会造出更糟的窗口。
//
//   复位链路更进一步：全程**物理像素**（`rcWork` 本身就是物理值，`SetWindowPos`
//   也吃物理值），零 DPR 换算 —— 连「窗口屏 DPR 与光标屏 DPR 不一致」这个坑
//   都不存在了。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

// ───────────────────────── 期望尺寸（改动前的硬编码值）─────────────────────────
//
// 1280×720 是 Figma 设计画布尺寸，也是项目布局溢出哨兵测试覆盖的档位
// （`test/explore_hall/explore_hall_layout_test.dart` 用 960×540 / 1280×800），
// 因此作为「设计锚点」保留不变 —— 本文件只在放不下时才收窄它。

const double kRequestedWindowWidth = 1280;
const double kRequestedWindowHeight = 720;

/// 最小窗口尺寸 = **设计尺寸**（2026-10-25 收敛）。
///
/// 🔴 为什么不再是 960×540：960×540 是"程序允许、但从没设计过"的尺寸。
/// 在那个尺寸下每个页面都得各自发明兜底（侧栏等比缩放、主页窄窗竖条、
/// 大厅整页滚动），三套策略互不统一，用户看到的就是"窗口尺寸非常混乱"。
/// 现在把最小尺寸直接抬到设计画布 1280×720：
/// - 用户不可能把窗口拖到"设计撑不住"的尺寸 ⇒ 页面级永不滚动、永不压扁；
/// - 默认 = 最小 = 恢复下限，三个数合一 ⇒ 窗口不会再自己变大变小；
/// - 屏幕工作区本身小于 1280×720 时由 [fitWindowToWorkArea] 钳到工作区，
///   此时才启用各页面的小窗兜底（极端屏专用路径）。
const double kRequestedMinWindowWidth = kRequestedWindowWidth;
const double kRequestedMinWindowHeight = kRequestedWindowHeight;

/// 工作区边距（逻辑像素）：让窗口与任务栏/屏幕边缘留出一条可见的抓取缝。
///
/// 🔴 取值 **24** 而非 48，由探针逐档数据定下来：1366×768@125%（工作区 1093×566）
/// 在 @24 下得 1069×**542**，高度仍 ≥ 项目已验证的 960×540 下限；@48 会掉到
/// 1045×**518**，跌出布局哨兵覆盖范围。
const double kStartupWindowMargin = 24;

/// 恢复历史几何时的「可用性下限」（逻辑像素）。
///
/// 🔴 为什么需要它（2026-10-25 真机事故）：`computeRestoreGeometry` 原先对历史尺寸
/// **只有上限（工作区）没有下限** —— 任何一次意外缩放（把窗口拖/滚到最小宽度贴边、
/// AltSnap 的 Alt+拖拽、Aero 吸附残留）都会被 `WindowGeometryService` 存下来，
/// 之后每次启动原样恢复，成为**永久固化的小窗**，装多少次新版本都不会自愈。
/// 真机案例：1920×1080@125% 上历史几何 1200×750 物理 = 960×600 逻辑（宽度正好贴着
/// 960 的最小宽度下限），用户以为「打包把窗口改小了」，实为这条记录在忠实还原。
///
/// 🔴 2026-10-25 第二轮：改为一律等于**设计尺寸**（1280×720），与
/// [kRequestedMinWindowWidth]/[kRequestedMinWindowHeight] 同源同值。
/// 此前是 1120×620 这个"第四个数"，与最小尺寸（960×540）自相矛盾：
/// 用户能把窗口拖到 960×600（程序允许），下次启动却被判定"太小"强行放大到
/// 1280×720 —— 窗口自己变大变小，这就是用户说的「窗口尺寸非常混乱」。
/// 现在「设计 = 默认 = 最小 = 恢复下限」是同一个数，三处再也不会打架。
///
/// 小屏（1366×768@125%，工作区逻辑 1093×566）放不下 1280×720 时，
/// 该下限会被 [fitWindowToWorkArea] 的工作区钳制接管，结果与默认尺寸一致，
/// 不会反而把窗口撑出屏幕。
const double kRestoreMinLogicalWidth = kRequestedWindowWidth;
const double kRestoreMinLogicalHeight = kRequestedWindowHeight;

/// 启动窗口尺寸决策结果。
class StartupWindowSize {
  const StartupWindowSize({
    required this.width,
    required this.height,
    required this.minWidth,
    required this.minHeight,
    required this.clamped,
    required this.workAreaWidth,
    required this.workAreaHeight,
  });

  /// 期望（最终）窗口尺寸，逻辑像素。
  final double width;
  final double height;

  /// 最小窗口尺寸，逻辑像素。永远 ≤ 对应最终尺寸。
  final double minWidth;
  final double minHeight;

  /// 是否因工作区不足而缩小过（用于日志；也可作为将来「要不要自动最大化」的依据）。
  final bool clamped;

  /// 决策所依据的工作区（逻辑像素）；取不到时为 0。
  final double workAreaWidth;
  final double workAreaHeight;

  /// 取不到工作区 / 非 Windows 时的回落值 —— 即改动前的行为（零风险开关）。
  static const StartupWindowSize fallback = StartupWindowSize(
    width: kRequestedWindowWidth,
    height: kRequestedWindowHeight,
    minWidth: kRequestedMinWindowWidth,
    minHeight: kRequestedMinWindowHeight,
    clamped: false,
    workAreaWidth: 0,
    workAreaHeight: 0,
  );

  @override
  String toString() =>
      'win=${_fmt(width)}x${_fmt(height)} min=${_fmt(minWidth)}x${_fmt(minHeight)} '
      'clamped=$clamped work=${_fmt(workAreaWidth)}x${_fmt(workAreaHeight)}';

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// 把「期望尺寸 / 期望最小尺寸」按工作区收窄。纯函数、零 IO、不抛异常。
///
/// - 工作区缺省（<= 0）时**原样返回**，即退化为改动前行为（零风险开关）。
/// - 最小尺寸**同样**受工作区约束，且永不大于最终尺寸（避免自相矛盾的下限）。
StartupWindowSize fitWindowToWorkArea({
  double requestedWidth = kRequestedWindowWidth,
  double requestedHeight = kRequestedWindowHeight,
  double requestedMinWidth = kRequestedMinWindowWidth,
  double requestedMinHeight = kRequestedMinWindowHeight,
  required double workAreaWidth,
  required double workAreaHeight,
  double margin = kStartupWindowMargin,
}) {
  if (workAreaWidth <= 0 || workAreaHeight <= 0) {
    return StartupWindowSize(
      width: requestedWidth,
      height: requestedHeight,
      minWidth: requestedMinWidth,
      minHeight: requestedMinHeight,
      clamped: false,
      workAreaWidth: workAreaWidth,
      workAreaHeight: workAreaHeight,
    );
  }
  final double maxW = (workAreaWidth - margin).clamp(1.0, double.infinity);
  final double maxH = (workAreaHeight - margin).clamp(1.0, double.infinity);

  final double width = requestedWidth < maxW ? requestedWidth : maxW;
  final double height = requestedHeight < maxH ? requestedHeight : maxH;

  final double minW = _min3(requestedMinWidth, maxW, width);
  final double minH = _min3(requestedMinHeight, maxH, height);

  return StartupWindowSize(
    width: width,
    height: height,
    minWidth: minW,
    minHeight: minH,
    clamped: width != requestedWidth || height != requestedHeight,
    workAreaWidth: workAreaWidth,
    workAreaHeight: workAreaHeight,
  );
}

double _min3(double a, double b, double c) {
  final double ab = a < b ? a : b;
  return ab < c ? ab : c;
}

int _minInt(int a, int b) => a < b ? a : b;

int _atLeastOne(int v) => v < 1 ? 1 : v;

// ───────────────────────── 复位几何（托盘「重置窗口位置与尺寸」）─────────────────────────

/// 复位几何 —— 全部相对**目标显示器**。
///
/// - [x]/[y]/[width]/[height]：**物理像素**，直接喂 FFI `SetWindowPos`，零 DPR 换算。
/// - [minWidth]/[minHeight]：**逻辑像素**，喂 `windowManager.setMinimumSize`。
/// - [scale]：目标显示器 DPI（96 = 100%）。
typedef ResetWindowGeometry = ({
  int x,
  int y,
  int width,
  int height,
  double minWidth,
  double minHeight,
  int scale,
  int workAreaWidth,
  int workAreaHeight,
});

/// 计算「复位到可见工作区并居中」的目标矩形与最小尺寸。纯函数、零 IO、不抛异常。
///
/// 与 [fitWindowToWorkArea] 的分工：那个返回**逻辑像素**（喂 `setSize`，由原生
/// 乘当前窗口 DPR），本函数返回**物理像素**（喂 FFI `SetWindowPos`）——
/// 于是复位路径上「窗口所在屏 DPR」与「光标所在屏 DPR」不一致的坑（混合 DPI
/// 双屏）从源头消失：矩形与缩放比例取自**同一块屏**。
///
/// [WorkAreaPhysical.dpi] 为 0（查询失败）时按 96 处理，仅影响 [minWidth]/
/// [minHeight] 的折算，矩形不受影响。
ResetWindowGeometry computeResetGeometry({
  required WorkAreaPhysical area,
  double margin = kStartupWindowMargin,
  double requestedWidth = kRequestedWindowWidth,
  double requestedHeight = kRequestedWindowHeight,
  double requestedMinWidth = kRequestedMinWindowWidth,
  double requestedMinHeight = kRequestedMinWindowHeight,
}) {
  final int dpi = area.dpi > 0 ? area.dpi : 96;
  final double scale = dpi / 96.0;

  // 物理像素下的可用上限（四周留 margin 逻辑 px，与启动路径同一口径）
  final int maxW = _atLeastOne((area.width - margin * scale).round());
  final int maxH = _atLeastOne((area.height - margin * scale).round());

  final int winW = _minInt((requestedWidth * scale).round(), maxW);
  final int winH = _minInt((requestedHeight * scale).round(), maxH);

  // 最小尺寸同样受工作区约束，且永不大于最终尺寸（避免自相矛盾的下限）
  final int minPhysW = _minInt((requestedMinWidth * scale).round(), winW);
  final int minPhysH = _minInt((requestedMinHeight * scale).round(), winH);

  return (
    x: area.left + (area.width - winW) ~/ 2,
    y: area.top + (area.height - winH) ~/ 2,
    width: winW,
    height: winH,
    // 逻辑值 = 物理 / 目标屏 scale ⇒ 原生 × pixel_ratio_（WM_DPICHANGED 会把它
    // 更新为目标屏比例）后回到同一个物理值。
    minWidth: minPhysW / scale,
    minHeight: minPhysH / scale,
    scale: dpi,
    workAreaWidth: area.width,
    workAreaHeight: area.height,
  );
}

// ───────────────────────── Win32：读主窗口所在显示器的工作区 ─────────────────────────

/// 主窗口 / 光标所在显示器的工作区与 DPI（**物理像素**）。
///
/// [dpi] 为该显示器的有效 DPI（96 = 100%）。**0 = 查询失败（缩放未知）**，
/// 调用方按 96 处理：矩形本身是全物理像素、不受影响，只有「最小尺寸折算」
/// 会退化为 1:1。
typedef WorkAreaPhysical = ({
  int left,
  int top,
  int width,
  int height,
  int dpi,
});

/// 读工作区（**物理像素** + 该显示器 DPI）。
///
/// [atCursor] = false（默认）：主窗口所在显示器。主窗口句柄经
/// `FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW")` 获取 —— 该类名由 runner 注册且
/// 全进程唯一（`windows/runner/win32_window.cpp:43`），与已上线的
/// `big_picture_manager.dart:408` 同源同款。runner 在 Flutter 引擎启动前就已创建
/// 该窗口，因此启动链路上句柄必然可用。
///
/// [atCursor] = true：**光标**所在显示器。托盘「重置窗口位置与尺寸」用它 ——
/// 窗口可能已被拖到屏外，此时「光标在哪块屏」才是用户想要的落点，也与
/// `WindowOptions.center: true` 的取屏口径一致（`screen_retriever` 同样按光标点取屏）。
///
/// 拿不到句柄时（非 Windows / 异常）降级为按光标取屏。
///
/// 任一环节失败返回 null，**不抛异常**。
WorkAreaPhysical? readWorkAreaPhysical({bool atCursor = false}) {
  if (!Platform.isWindows) return null;
  try {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
    final findWindowW = user32.lookupFunction<
        ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
        int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>('FindWindowW');
    final monitorFromWindow = user32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
        int Function(int, int)>('MonitorFromWindow');
    final monitorFromPoint = user32.lookupFunction<
        ffi.IntPtr Function(_Win32Point, ffi.Uint32),
        int Function(_Win32Point, int)>('MonitorFromPoint');
    final getCursorPos = user32.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<_Win32Point>),
        int Function(ffi.Pointer<_Win32Point>)>('GetCursorPos');

    // MONITOR_DEFAULTTONEAREST
    const int monitorDefaultToNearest = 2;

    int hmon = 0;

    // ① 主路径：主窗口句柄 → 窗口所在显示器（atCursor 时跳过）
    if (!atCursor) {
      final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      try {
        final hwnd = findWindowW(className, ffi.nullptr);
        if (hwnd != 0) {
          hmon = monitorFromWindow(hwnd, monitorDefaultToNearest);
        }
      } finally {
        calloc.free(className);
      }
    }

    // ② 降级路径（或 atCursor）：按光标所在显示器
    if (hmon == 0) {
      final pt = calloc<_Win32Point>();
      try {
        if (getCursorPos(pt) == 0) return null;
        hmon = monitorFromPoint(pt.ref, monitorDefaultToNearest);
      } finally {
        calloc.free(pt);
      }
    }
    if (hmon == 0) return null;

    return _queryMonitorArea(hmon);
  } catch (_) {
    // 🔴 启动链路铁律：任何 FFI 异常都不得冒泡，一律回落。
    return null;
  }
}

/// 取指定显示器句柄的工作区（`rcWork`）+ 有效 DPI，**物理像素**。
///
/// 任一环节失败返回 null，不抛异常。三处取屏口径（窗口 / 光标 / 矩形）共用本函数，
/// 避免出现第二份「rcWork + dpi」的实现。
///
/// dpi 来源：shcore.dll 的 `GetDpiForMonitor`（Win8.1+）。runner.exe.manifest 已声明
/// PerMonitorV2，因此读数是该显示器的真实有效 DPI（未声明 DPI 感知的进程会恒得 96，
/// 探针已实测过这个差别）。查询失败回落 0 = 未知。
WorkAreaPhysical? _queryMonitorArea(int hmon) {
  try {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
    final getMonitorInfoW = user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_Win32MonitorInfo>),
        int Function(int, ffi.Pointer<_Win32MonitorInfo>)>('GetMonitorInfoW');
    final info = calloc<_Win32MonitorInfo>();
    try {
      info.ref.cbSize = ffi.sizeOf<_Win32MonitorInfo>();
      if (getMonitorInfoW(hmon, info) == 0) return null;
      // rcWork = 工作区（已排除任务栏 / 已贴靠的应用栏）
      final rc = info.ref.rcWork;
      final int w = rc.right - rc.left;
      final int h = rc.bottom - rc.top;
      if (w <= 0 || h <= 0) return null;
      return (
        left: rc.left,
        top: rc.top,
        width: w,
        height: h,
        dpi: _readMonitorDpi(hmon),
      );
    } finally {
      calloc.free(info);
    }
  } catch (_) {
    return null;
  }
}

/// 主窗口所在显示器的工作区（启动链路沿用名，等价 `readWorkAreaPhysical()`）。
WorkAreaPhysical? readMainWorkAreaPhysical() => readWorkAreaPhysical();

/// 读指定显示器的有效 DPI；不可用 / 失败返回 0（= 未知缩放）。
///
/// `GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI = 0, &x, &y)` 来自 shcore.dll
/// （Win8.1+）；该 DLL 不存在时静默回落。**任何异常都被吞掉** —— DPI 只影响
/// 最小尺寸的折算精度，不该让整条复位链路失败。
int _readMonitorDpi(int hmon) {
  ffi.Pointer<ffi.Uint32> dx = ffi.nullptr;
  ffi.Pointer<ffi.Uint32> dy = ffi.nullptr;
  try {
    final ffi.DynamicLibrary shcore = ffi.DynamicLibrary.open('shcore.dll');
    final getDpiForMonitor = shcore.lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>),
        int Function(int, int, ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>)>('GetDpiForMonitor');
    dx = calloc<ffi.Uint32>();
    dy = calloc<ffi.Uint32>();
    if (getDpiForMonitor(hmon, 0, dx, dy) != 0) return 0;
    return dx.value > 0 ? dx.value : 0;
  } catch (_) {
    return 0;
  } finally {
    if (dx != ffi.nullptr) calloc.free(dx);
    if (dy != ffi.nullptr) calloc.free(dy);
  }
}

// ───────────────────────── Win32：把主窗口矩形设为物理像素 ─────────────────────────

/// 把主窗口矩形直接设为**物理像素**矩形（FFI `SetWindowPos`）。返回是否成功。
///
/// 与 `big_picture_manager.dart` 的铺屏调用**同源同款**（同一句柄获取方式、
/// 同一组 SWP flags，见插件 `window_manager.cpp:607`），全程容错、不抛异常。
///
/// 🔴 为什么不用插件 `setSize` + `setAlignment`：前者的物理换算用**窗口所在屏**
/// 的 DPR，后者按**光标所在屏**的工作区算位置 —— 混合 DPI 双屏下两者不同源，
/// 会算出偏位/偏尺寸的窗口。本函数不做任何 DPR 换算，矩形与缩放比例取自同一块屏。
///
/// [bringToFront] = true（默认，托盘「重置窗口位置与尺寸」用）：`HWND_TOP`，
/// 复位后把窗口带到前面。启动恢复几何时必须传 `false` —— 那时窗口还没 `show()`，
/// 抢 z-order / 激活只会与紧随其后的 `show()` + `focus()` 打架（改用
/// `SWP_NOZORDER | SWP_NOACTIVATE`，只改矩形、不碰前后关系与焦点）。
bool applyMainWindowRect({
  required int x,
  required int y,
  required int width,
  required int height,
  bool bringToFront = true,
}) {
  if (!Platform.isWindows) return false;
  if (width <= 0 || height <= 0) return false;
  try {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
    final findWindowW = user32.lookupFunction<
        ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
        int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>('FindWindowW');
    final setWindowPos = user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.Int32, ffi.Int32,
            ffi.Int32, ffi.Int32, ffi.Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');

    // 与 BPM 铺屏同一组 flags（window_manager.cpp:607）
    const int swpNoZOrder = 0x0004; // SWP_NOZORDER
    const int swpNoActivate = 0x0010; // SWP_NOACTIVATE
    const int swpNoOwnerZOrder = 0x0200; // SWP_NOOWNERZORDER
    const int swpFrameChanged = 0x0020; // SWP_FRAMECHANGED

    final int flags = bringToFront
        ? (swpNoOwnerZOrder | swpFrameChanged)
        : (swpNoZOrder | swpNoActivate | swpNoOwnerZOrder | swpFrameChanged);

    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final hwnd = findWindowW(className, ffi.nullptr);
      if (hwnd == 0) return false;
      final ok = setWindowPos(
        hwnd,
        0, // HWND_TOP（与 BPM 一致：复位后把窗口带到前面）
        x,
        y,
        width,
        height,
        flags,
      );
      return ok != 0;
    } finally {
      calloc.free(className);
    }
  } catch (_) {
    return false;
  }
}

/// 把主窗口复位到**光标所在显示器**的工作区内并居中（托盘逃生入口）。
///
/// 返回 `null` = 取不到工作区（非 Windows / FFI 失败）；`applied` = 矩形是否
/// 成功下发 —— 无论成败都不抛异常。
///
/// 只负责「算 + 摆」，不负责退出全屏 / 取消最大化 —— 那些前置状态由调用方
/// （`tray_service._resetWindow()`）按顺序处理，因为插件侧的还原是**异步消息**，
/// 必须在 SetWindowPos 之前落定。
({ResetWindowGeometry geometry, bool applied})? resetMainWindowToVisibleWorkArea({
  double margin = kStartupWindowMargin,
}) {
  try {
    final WorkAreaPhysical? area = readWorkAreaPhysical(atCursor: true);
    if (area == null) return null;
    final ResetWindowGeometry geo =
        computeResetGeometry(area: area, margin: margin);
    return (
      geometry: geo,
      applied: applyMainWindowRect(
        x: geo.x,
        y: geo.y,
        width: geo.width,
        height: geo.height,
      ),
    );
  } catch (_) {
    return null;
  }
}

// ───────────────────────── 几何持久化：恢复上次的位置与尺寸 ─────────────────────────

/// 主窗口的物理像素矩形（`GetWindowRect` 读回的原始值）。
typedef WindowRectPhysical = ({int left, int top, int width, int height});

/// 计算「把保存的几何恢复到目标显示器」的物理矩形与最小尺寸。
///
/// 纯函数、零 IO、不抛异常；返回 `null` = 不可恢复（调用方回落默认居中路径）。
///
/// - [savedDpi]：保存时窗口所在显示器的有效 DPI（96 = 100%）。`0` = 未知。
/// - [target]：目标显示器的工作区 + 其有效 DPI。
///
/// 四条设计要点：
/// ① **缩放补偿** `fix = target.dpi / savedDpi`：用户把 Windows 缩放从 100% 调到
///    125% 后重启，恢复到的是**同一个视觉尺寸**（物理值 ×1.25），而不是同一个物理
///    像素数 —— 后者看上去会凭空小一圈。取不到任一侧 DPI 时 `fix = 1`（按物理原样恢复）。
/// ② **尺寸 margin = 0**：`kStartupWindowMargin` 是给「默认尺寸」留一条抓取缝用的，
///    恢复用户自己的几何时不该偷缩 24px —— 「把窗口拉到刚好铺满工作区」是合法意图。
/// ③ **位置按相对几何中心映射**再钳进工作区 ⇒ 同屏（`fix == 1`）时 round-trip
///    **逐字节相等**；跨屏 / 缩放变化时按比例落点；两者都不可能让窗口出屏。
/// ④ **可用性下限**（[kRestoreMinLogicalWidth]/[kRestoreMinLogicalHeight]）：历史
///    尺寸折算成逻辑像素后低于下限 ⇒ 判定为意外缩放，**尺寸回默认、位置照旧恢复**。
///    这是唯一能自愈「已经固化的坏几何」的位置（见常量注释里的真机事故）。
///
/// 保存时所在的那块屏若已不存在（矩形与目标屏工作区**无交集**，典型：副屏被拔），
/// 则在目标屏**居中**，而不是贴到边缘。
ResetWindowGeometry? computeRestoreGeometry({
  required WindowRectPhysical saved,
  required int savedDpi,
  required WorkAreaPhysical target,
}) {
  if (saved.width <= 0 || saved.height <= 0) return null;
  if (target.width <= 0 || target.height <= 0) return null;

  final int dpi = target.dpi > 0 ? target.dpi : 96;
  final double scale = dpi / 96.0;
  final double fix =
      (savedDpi > 0 && target.dpi > 0) ? target.dpi / savedDpi : 1.0;

  // 折算成「目标屏下的期望尺寸」后交给与启动路径同一个收窄函数。
  final double savedLogicalWidth = saved.width * fix / scale;
  final double savedLogicalHeight = saved.height * fix / scale;
  final bool tooSmall = savedLogicalWidth < kRestoreMinLogicalWidth ||
      savedLogicalHeight < kRestoreMinLogicalHeight;

  final StartupWindowSize fit = fitWindowToWorkArea(
    requestedWidth: tooSmall ? kRequestedWindowWidth : savedLogicalWidth,
    requestedHeight: tooSmall ? kRequestedWindowHeight : savedLogicalHeight,
    workAreaWidth: target.width / scale,
    workAreaHeight: target.height / scale,
    // 尺寸回默认时连边距一起回默认（与启动路径同口径，留出抓取缝）；
    // 恢复用户自己的几何时不偷缩 24px —— 「拉到刚好铺满工作区」是合法意图。
    margin: tooSmall ? kStartupWindowMargin : 0,
  );

  final int winW = _atLeastOne((fit.width * scale).round());
  final int winH = _atLeastOne((fit.height * scale).round());

  final bool overlapped = _rectsIntersect(
    saved,
    left: target.left,
    top: target.top,
    width: target.width,
    height: target.height,
  );

  int x;
  int y;
  if (!overlapped) {
    // 保存时那块屏已经不在了 ⇒ 在目标屏居中
    x = target.left + (target.width - winW) ~/ 2;
    y = target.top + (target.height - winH) ~/ 2;
  } else {
    // 相对几何中心映射
    final double relCx =
        (saved.left + saved.width / 2 - target.left) / target.width;
    final double relCy =
        (saved.top + saved.height / 2 - target.top) / target.height;
    x = (target.left + relCx * target.width - winW / 2).round();
    y = (target.top + relCy * target.height - winH / 2).round();
  }

  // 钳进工作区（构造性保证：窗口一定可达）
  final int maxX = target.left + _atLeastZero(target.width - winW);
  final int maxY = target.top + _atLeastZero(target.height - winH);
  if (x < target.left) x = target.left;
  if (y < target.top) y = target.top;
  if (x > maxX) x = maxX;
  if (y > maxY) y = maxY;

  // 最小尺寸：按目标屏折算（原生 WM_GETMINMAXINFO 会 × pixel_ratio_），且永不大于最终尺寸
  final int minPhysW = _minInt((kRequestedMinWindowWidth * scale).round(), winW);
  final int minPhysH = _minInt((kRequestedMinWindowHeight * scale).round(), winH);

  return (
    x: x,
    y: y,
    width: winW,
    height: winH,
    minWidth: minPhysW / scale,
    minHeight: minPhysH / scale,
    scale: dpi,
    workAreaWidth: target.width,
    workAreaHeight: target.height,
  );
}

/// 两矩形是否相交（含边界接触）。纯函数。
bool _rectsIntersect(
  WindowRectPhysical r, {
  required int left,
  required int top,
  required int width,
  required int height,
}) {
  return r.left < left + width &&
      left < r.left + r.width &&
      r.top < top + height &&
      top < r.top + r.height;
}

int _atLeastZero(int v) => v < 0 ? 0 : v;

/// 读主窗口当前的**物理像素**矩形（FFI `GetWindowRect`）。
///
/// 与 [applyMainWindowRect] 成对：一个读、一个写，全程物理像素、零 DPR 换算。
/// 取不到（非 Windows / 句柄缺失 / 调用失败）返回 null，不抛异常。
WindowRectPhysical? readMainWindowRectPhysical() {
  if (!Platform.isWindows) return null;
  try {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
    final findWindowW = user32.lookupFunction<
        ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>),
        int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>('FindWindowW');
    final getWindowRect = user32.lookupFunction<
        ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<_Win32Rect>),
        int Function(int, ffi.Pointer<_Win32Rect>)>('GetWindowRect');

    final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    try {
      final hwnd = findWindowW(className, ffi.nullptr);
      if (hwnd == 0) return null;
      final rc = calloc<_Win32Rect>();
      try {
        if (getWindowRect(hwnd, rc) == 0) return null;
        final r = rc.ref;
        final int w = r.right - r.left;
        final int h = r.bottom - r.top;
        if (w <= 0 || h <= 0) return null;
        return (left: r.left, top: r.top, width: w, height: h);
      } finally {
        calloc.free(rc);
      }
    } finally {
      calloc.free(className);
    }
  } catch (_) {
    return null;
  }
}

/// 读「与给定物理矩形相交的显示器」的工作区与 DPI。
///
/// 先用 `MonitorFromRect(rect, MONITOR_DEFAULTTONULL = 0)` 判定是否**完全不与任何
/// 显示器相交**（返回 0）—— 这正是「保存时的屏已经不在（被拔掉 / 分辨率大改）」的
/// 判据；命中后再用 `MONITOR_DEFAULTTONEAREST = 2` 取该显示器的工作区。
///
/// 任一环节失败返回 null，不抛异常。
WorkAreaPhysical? readWorkAreaNearRect(WindowRectPhysical rect) {
  if (!Platform.isWindows) return null;
  if (rect.width <= 0 || rect.height <= 0) return null;
  try {
    final ffi.DynamicLibrary user32 = ffi.DynamicLibrary.open('user32.dll');
    final monitorFromRect = user32.lookupFunction<
        ffi.IntPtr Function(ffi.Pointer<_Win32Rect>, ffi.Uint32),
        int Function(ffi.Pointer<_Win32Rect>, int)>('MonitorFromRect');

    final rc = calloc<_Win32Rect>();
    try {
      rc.ref.left = rect.left;
      rc.ref.top = rect.top;
      rc.ref.right = rect.left + rect.width;
      rc.ref.bottom = rect.top + rect.height;
      // MONITOR_DEFAULTTONULL：完全不相交则返回 0
      if (monitorFromRect(rc, 0) == 0) return null;
      final int hmon = monitorFromRect(rc, 2);
      if (hmon == 0) return null;
      return _queryMonitorArea(hmon);
    } finally {
      calloc.free(rc);
    }
  } catch (_) {
    return null;
  }
}

// ───────────────────────── 综合入口 ─────────────────────────

/// 计算启动时的窗口尺寸与最小尺寸。
///
/// [devicePixelRatio] 必须传 `windowManager.getDevicePixelRatio()` —— 与
/// `setSize` 在原生侧使用的换算因子**同源**，从而保证口径自洽（见文件头注释）。
///
/// 全链路容错：非 Windows / 句柄缺失 / 工作区非法 / DPR 非法 一律回落
/// [StartupWindowSize.fallback]（= 改动前行为），**绝不抛异常**。
StartupWindowSize resolveStartupWindowSize({required double devicePixelRatio}) {
  try {
    if (!Platform.isWindows) return StartupWindowSize.fallback;
    final double dpr = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;

    final WorkAreaPhysical? area = readMainWorkAreaPhysical();
    if (area == null) return StartupWindowSize.fallback;

    return fitWindowToWorkArea(
      workAreaWidth: area.width / dpr,
      workAreaHeight: area.height / dpr,
    );
  } catch (_) {
    return StartupWindowSize.fallback;
  }
}

// ───────────────────────── Win32 结构体（与 C 定义同布局）─────────────────────────

final class _Win32Rect extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

final class _Win32Point extends ffi.Struct {
  @ffi.Int32()
  external int x;

  @ffi.Int32()
  external int y;
}

/// `typedef struct tagMONITORINFO { DWORD cbSize; RECT rcMonitor; RECT rcWork; DWORD dwFlags; }`
final class _Win32MonitorInfo extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;

  external _Win32Rect rcMonitor;

  external _Win32Rect rcWork;

  @ffi.Uint32()
  external int dwFlags;
}
