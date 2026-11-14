import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 主窗口可见性门闩（PERF-IDLE-QUIET，2026-11-03）
///
/// Flutter Windows 引擎在 `windowManager.hide()` 之后**不会**停止 vsync 调度：
/// Widget 树完整存活，`AnimationController` 照常按刷新率空转，raster 线程
/// 持续做整层合成。于是托盘静默态仍维持 47%~53% GPU / 3%~5% CPU
/// （2026-11-03 用户实测：144Hz 屏，唯一逐帧动画源是 `_AmbientLayer` 的 90s 呼吸）。
///
/// 本类是全应用唯一的「窗口此刻是否对用户可见」状态源：
/// - [visible] 由 `main.dart` 的 `WindowListener` 写入
///   （原生 `WM_SHOWWINDOW` → show/hide，最小化/还原 → minimize/restore）；
/// - `main_container.dart` 的 `build` 用它给整棵内容树套 `TickerMode`，
///   不可见时所有 Ticker 静音、不再产生帧；
/// - 不可见并稳定 800ms 后才释放 `ImageCache` 的 live 引用。
///
/// ⚠️ 本类只描述「可见性」，不承载业务判断。BPM 等需要例外放行的场景
/// 由消费方自行或运算（见 `main_container.build` 内注释）。
class WindowVisibility {
  WindowVisibility._();

  /// 窗口是否可见（最小化 / 隐藏到托盘 / 关闭到托盘 均为 false）。
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  static bool get isVisible => visible.value;

  static Timer? _trimTimer;

  /// 由 `WindowListener` 调用。幂等：值未变化时不做任何事。
  static void setVisible(bool value, {String reason = ''}) {
    if (visible.value == value) return;
    visible.value = value;
    if (value) {
      _trimTimer?.cancel();
      _trimTimer = null;
    } else {
      _scheduleTrim();
    }
    debugPrint('[VISIBILITY] 窗口可见性 → $value'
        '${reason.isEmpty ? '' : '（$reason）'}');
  }

  /// 延迟 800ms 才回收：拖拽/快速显隐切换时不做无谓的纹理释放。
  ///
  /// 只清 live 引用（`clearLiveImages`），不动缓存条目本身 —— 从托盘恢复时
  /// 封面仍命中 ImageCache，不会出现重新解码的闪白/抖动。
  static void _scheduleTrim() {
    _trimTimer?.cancel();
    _trimTimer = Timer(const Duration(milliseconds: 800), () {
      if (visible.value) return;
      try {
        final ImageCache cache = PaintingBinding.instance.imageCache;
        cache.clearLiveImages();
        debugPrint('[VISIBILITY] 已释放 ImageCache live 引用'
            '（缓存 ${cache.currentSize} 项 / ${cache.currentSizeBytes ~/ 1024} KB 保留）');
      } catch (e) {
        debugPrint('[VISIBILITY] 释放 ImageCache 失败（忽略）: $e');
      }
    });
  }
}
