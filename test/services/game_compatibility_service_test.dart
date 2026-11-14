import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/game_compatibility_service.dart';
import 'package:chrono_tide/services/launch_process_launcher.dart';

void main() {
  group('CompatSnapshot 解析', () {
    test('null → 全空', () {
      final snapshot = GameCompatibilityService.parse(null);
      expect(snapshot.raw, isNull);
      expect(snapshot.compatModeEnabled, isFalse);
      expect(snapshot.compatVersion, isNull);
      expect(snapshot.tokens, isEmpty);
    });

    test('完整标志串（实测样本）', () {
      const raw =
          '~ DISABLEDXMAXIMIZEDWINDOWEDMODE RUNASADMIN HIGHDPIAWARE WIN8RTM';
      final snapshot = GameCompatibilityService.parse(raw);
      expect(snapshot.compatModeEnabled, isTrue);
      expect(snapshot.compatVersion, CompatFlags.win8);
      expect(snapshot.runAsAdmin, isTrue);
      expect(snapshot.highDpiOverride, isTrue);
      expect(snapshot.disableFullscreenOptimization, isTrue);
      // `~` 不进入 tokens
      expect(snapshot.tokens.contains(CompatFlags.compatModeMarker), isFalse);
      expect(snapshot.tokens.length, 4);
    });

    test('只有 HIGHDPIAWARE 时没有兼容模式版本', () {
      final snapshot = GameCompatibilityService.parse('~ HIGHDPIAWARE');
      expect(snapshot.compatModeEnabled, isTrue);
      expect(snapshot.compatVersion, isNull);
      expect(snapshot.highDpiOverride, isTrue);
      expect(snapshot.runAsAdmin, isFalse);
    });

    test('用户手设的 Win7 能被识别为版本', () {
      final snapshot = GameCompatibilityService.parse('~ WIN7RTM HIGHDPIAWARE');
      expect(snapshot.compatVersion, CompatFlags.win7);
    });

    test('保留用户自加标志（256COLOR）', () {
      final snapshot = GameCompatibilityService.parse('~ 256COLOR');
      expect(snapshot.tokens, contains('256COLOR'));
      expect(snapshot.compatVersion, isNull);
    });

    test('多个空格 / 前后空白不产生空 token', () {
      final snapshot = GameCompatibilityService.parse('  ~   HIGHDPIAWARE  ');
      expect(snapshot.tokens, <String>[CompatFlags.highDpiOverride]);
    });
  });

  group('CompatDesired', () {
    test('默认值：三项优化开、管理员关', () {
      const desired = CompatDesired();
      expect(desired.win8CompatMode, isTrue);
      expect(desired.disableFullscreenOptimization, isTrue);
      expect(desired.highDpiOverride, isTrue);
      expect(desired.runAsAdmin, isFalse);
      expect(desired.toTokens(), <String>{
        CompatFlags.disableFullscreenOptimization,
        CompatFlags.highDpiOverride,
      });
    });

    test('总开关关闭但管理员开启 → 只写 RUNASADMIN', () {
      final desired = CompatDesired.resolve(
        autoConfigEnabled: false,
        runAsAdmin: true,
      );
      expect(desired.toTokens(), <String>{CompatFlags.runAsAdmin});
      expect(desired.wantsWin8, isFalse);
    });

    test('总开关开启 + 管理员开启 → 三项优化 + RUNASADMIN', () {
      final desired = CompatDesired.resolve(
        autoConfigEnabled: true,
        runAsAdmin: true,
      );
      expect(desired.toTokens(), <String>{
        CompatFlags.disableFullscreenOptimization,
        CompatFlags.highDpiOverride,
        CompatFlags.runAsAdmin,
      });
    });

    test('none 不含任何 token', () {
      expect(CompatDesired.none.toTokens(), isEmpty);
    });
  });

  group('canonicalExePath', () {
    test('空串 → 空串', () {
      expect(GameCompatibilityService.canonicalExePath('   '), '');
    });

    test('正反斜杠混用被归一（实测脏值形态）', () {
      final canonical = GameCompatibilityService.canonicalExePath(
        r'D:\Chrono Tide\Games/命运石之门/a.exe',
      );
      expect(canonical.contains('/'), isFalse);
      expect(canonical, r'D:\Chrono Tide\Games\命运石之门\a.exe');
    });

    test('重复分隔符与 . 段被清理', () {
      final canonical = GameCompatibilityService.canonicalExePath(
        r'D:\Games\\sub\..\sub\a.exe',
      );
      expect(canonical, r'D:\Games\sub\a.exe');
    });
  });

  group('LaunchProcessLauncher 参数拼接', () {
    test('含空格路径加引号', () {
      expect(
        LaunchProcessLauncher.debugJoinArguments([r'D:\My Games\a.exe']),
        r'"D:\My Games\a.exe"',
      );
    });

    test('普通参数不加引号', () {
      expect(
        LaunchProcessLauncher.debugJoinArguments(['-t']),
        '-t',
      );
    });

    test('空参数变为空引号对', () {
      expect(
        LaunchProcessLauncher.debugJoinArguments(['']),
        '""',
      );
    });

    test('多参数按空格连接', () {
      expect(
        LaunchProcessLauncher.debugJoinArguments([
          '-t',
          r'D:\a b\c.exe',
        ]),
        r'-t "D:\a b\c.exe"',
      );
    });
  });

  group('权限联动规则', () {
    test('游戏提权 ⇒ 工具必须提权', () {
      expect(
        LaunchProcessLauncher.shouldElevateTool(
          toolWantsElevation: false,
          gameElevated: true,
        ),
        isTrue,
      );
    });

    test('游戏不提权 + 工具不要求 → 都不提权', () {
      expect(
        LaunchProcessLauncher.shouldElevateTool(
          toolWantsElevation: false,
          gameElevated: false,
        ),
        isFalse,
      );
    });

    test('工具主动要求提权', () {
      expect(
        LaunchProcessLauncher.shouldElevateTool(
          toolWantsElevation: true,
          gameElevated: false,
        ),
        isTrue,
      );
    });
  });
}
