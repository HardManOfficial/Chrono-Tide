import 'package:chrono_tide/big_picture/services/bpm_gamepad_service.dart';
import 'package:chrono_tide/services/gamepad/gamepad_adaptation_coordinator.dart';
import 'package:chrono_tide/services/gamepad/input_injector.dart';
import 'package:flutter_test/flutter_test.dart';

/// dispatchGate 总规则单测（2026-10-06「玩游戏时 BPM 界面同时乱动」修复）。
///
/// 覆盖：本应用不在前台 → BPM 语义静音、raw 流照常；
/// 切回前台 → 语义恢复；无映射会话时同样生效（旧闸门的盲区）。
class _FakeForegroundChecker implements ForegroundChecker {
  _FakeForegroundChecker(this.pid);

  /// 当前前台 pid（测试中可变，模拟窗口切换）
  int? pid;

  @override
  bool get isAvailable => true;

  @override
  int? foregroundPid() => pid;
}

void main() {
  final coordinator = GamepadAdaptationCoordinator.instance;

  tearDown(() {
    coordinator.debugOverrideAppForegroundChecker(null, null);
  });

  // 便捷构造：递增 packet 保证 buttonsChanged 为真
  GamepadFrame f(int packet, {int buttons = 0}) =>
      GamepadFrame(packetNumber: packet, buttons: buttons);

  /// 构造带语义/raw 记录的服务，dispatchGate 与 shell 生产闭包同构
  BpmGamepadService buildService({
    required List<String> semantic,
    required List<String> raw,
  }) =>
      BpmGamepadService(
        callbacks: BpmGamepadCallbacks(
          onConfirm: () => semantic.add('confirm'),
          onBack: () => semantic.add('back'),
          onDirection: (_) => semantic.add('dir'),
        ),
      )..dispatchGate = () {
          // 与 big_picture_shell.dart 的生产闸门同构
          if (!coordinator.isAppForeground) return true;
          return coordinator.hasActiveSession &&
              coordinator.isGameForeground;
        };

  group('dispatchGate 总规则（本应用不在前台 → BPM 让路）', () {
    test('游戏前台（无映射会话）：语义静音，raw 流照常', () {
      final checker = _FakeForegroundChecker(1); // 前台 = 游戏 pid
      coordinator.debugOverrideAppForegroundChecker(checker, 9999);
      final semantic = <String>[];
      final raw = <String>[];
      final svc = buildService(semantic: semantic, raw: raw)
        ..addRawListener(BpmGamepadRawListener(
          onButton: (b, down) => raw.add('${down ? '+' : '-'}${b.name}'),
        ));

      svc.consumeFrameForTest(f(1)); // 基线
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));
      svc.consumeFrameForTest(f(3));

      expect(semantic, isEmpty,
          reason: '应用不在前台：A 不应触发 BPM「确认」——即使没有映射会话');
      expect(raw, ['+a', '-a'], reason: 'raw 流不被闸门吞掉（注入层依赖）');
      svc.dispose();
    });

    test('Alt+Tab 回到本应用（无会话）：语义恢复', () {
      final checker = _FakeForegroundChecker(1);
      coordinator.debugOverrideAppForegroundChecker(checker, 9999);
      final semantic = <String>[];
      final svc = buildService(semantic: semantic, raw: const []);

      svc.consumeFrameForTest(f(1)); // 基线（前台 = 游戏）
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a)); // 游戏里按 A

      checker.pid = 9999; // 切回 Chrono Tide
      // 🔴 isAppForeground 判定有 250ms 缓存（生产上切前台后 ≤250ms 恢复，
      // 预期行为）；测试帧零耗时 → 显式重置缓存模拟缓存过期。
      coordinator.debugOverrideAppForegroundChecker(checker, 9999);
      svc.consumeFrameForTest(f(3));
      svc.consumeFrameForTest(f(4, buttons: XInputButtons.a)); // 新的一次按下

      expect(semantic, ['confirm'],
          reason: '切回本应用后新手势恢复正常派发（不补发闸门期间的旧边缘）');
      svc.dispose();
    });

    test('方向事件同样被前台闸门静音', () {
      final checker = _FakeForegroundChecker(2);
      coordinator.debugOverrideAppForegroundChecker(checker, 9999);
      final semantic = <String>[];
      final svc = buildService(semantic: semantic, raw: const []);

      svc.consumeFrameForTest(f(1)); // 基线
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.dpadDown));

      expect(semantic, isEmpty, reason: '应用不在前台：十字键不应移动 BPM 焦点');
      svc.dispose();
    });

    test('本应用在前台且无会话：语义照常（旧行为保持）', () {
      final checker = _FakeForegroundChecker(9999);
      coordinator.debugOverrideAppForegroundChecker(checker, 9999);
      final semantic = <String>[];
      final svc = buildService(semantic: semantic, raw: const []);

      svc.consumeFrameForTest(f(1)); // 基线
      svc.consumeFrameForTest(f(2, buttons: XInputButtons.a));

      expect(semantic, ['confirm']);
      svc.dispose();
    });

    test('生产路径冒烟：isAppForeground 可安全查询（不抛异常）', () {
      coordinator.debugOverrideAppForegroundChecker(null, null);
      expect(coordinator.isAppForeground, isA<bool>());
    });
  });
}
