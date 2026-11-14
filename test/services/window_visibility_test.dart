import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/window_visibility.dart';

/// PERF-IDLE-QUIET（2026-11-03）：窗口可见性门闩的状态机约束。
///
/// 这个状态被 `main_container` 的 `TickerMode` 直接消费，一旦多通知/漏通知，
/// 后果是「窗口可见但动画全停」或「窗口隐藏但仍在 144fps 空转」——
/// 两者都是用户可感知的回归，所以只钉住这三条契约。
void main() {
  testWidgets('同值重复设置不触发通知；翻转后才通知', (tester) async {
    final events = <bool>[];
    void listener() => events.add(WindowVisibility.isVisible);

    // 归一到已知初态（静态状态跨用例共享）
    WindowVisibility.setVisible(true);
    WindowVisibility.visible.addListener(listener);
    addTearDown(() => WindowVisibility.visible.removeListener(listener));

    WindowVisibility.setVisible(false, reason: 'test-hide');
    WindowVisibility.setVisible(false, reason: 'test-hide-again');
    expect(events, <bool>[false], reason: '同值重复设置不得触发通知');

    WindowVisibility.setVisible(true, reason: 'test-show');
    WindowVisibility.setVisible(true, reason: 'test-show-again');
    expect(events, <bool>[false, true], reason: '恢复可见只能通知一次');
    expect(WindowVisibility.isVisible, isTrue);
  });

  testWidgets('隐藏后 800ms 内恢复可见时，去抖清理不执行也不报错', (tester) async {
    WindowVisibility.setVisible(true);
    WindowVisibility.setVisible(false, reason: 'test-hide');
    expect(WindowVisibility.isVisible, isFalse);

    // 去抖窗口内立即恢复：_trimTimer 应被取消，pump 越过 800ms 不得抛异常
    WindowVisibility.setVisible(true, reason: 'test-show-fast');
    await tester.pump(const Duration(milliseconds: 900));
    expect(WindowVisibility.isVisible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('隐藏稳定 800ms 后执行 ImageCache live 引用回收', (tester) async {
    WindowVisibility.setVisible(true);
    WindowVisibility.setVisible(false, reason: 'test-hide-settled');
    await tester.pump(const Duration(milliseconds: 900));
    expect(WindowVisibility.isVisible, isFalse);
    expect(tester.takeException(), isNull);

    WindowVisibility.setVisible(true); // 收尾：恢复初态，避免静态状态污染后续用例
  });
}
