// 游戏本体「移入回收站」安全边界判定测试（2026-10-26）
//
// 背景：库页「同时删除本地游戏文件」长期是空承诺 —— 本地导入游戏的
// `directoryPath` 就是用户自己的文件夹，ADR-007 护栏一律跳过删除。
// 本轮把它改成「移入回收站（可还原）」，前提是目标必须通过安全边界判定。
//
// 本文件锁定判定口径：任何一条命中即拒绝（宁可留垃圾，不可误删）。
// 系统/用户目录用注入的 environment 模拟，不依赖测试机真实布局。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/game_body_recycle_policy.dart';

void main() {
  const appRoots = <String>[r'D:\Apps\CTLib'];
  const emptyEnv = <String, String>{};

  String? block(String target,
          {List<String> roots = appRoots,
          Map<String, String> env = emptyEnv}) =>
      GameBodyRecyclePolicy.blockReason(target,
          appRoots: roots, environment: env);

  group('允许回收：本地磁盘上的普通用户目录', () {
    test('本地导入游戏的真实形态', () {
      expect(block(r'E:\GAL\野良与皇女与流浪猫之心'), isNull);
    });

    test('盘符 + 一级目录', () {
      expect(block(r'E:\GAL'), isNull);
    });

    test('用户主目录深处（Desktop\\GAL\\游戏）', () {
      const env = {'USERPROFILE': r'C:\Users\me', 'SystemRoot': r'C:\Windows'};
      expect(block(r'C:\Users\me\Desktop\GAL\SomeGame', env: env), isNull);
    });
  });

  group('拒绝：路径本身无效或指向应用自有位置', () {
    test('空路径', () {
      expect(block(''), GameBodyRecyclePolicy.reasonEmpty);
      expect(block('   '), GameBodyRecyclePolicy.reasonEmpty);
    });

    test('磁盘根目录（防止删整盘）', () {
      expect(block(r'E:\'), GameBodyRecyclePolicy.reasonDriveRoot);
      expect(block('E:'), GameBodyRecyclePolicy.reasonDriveRoot);
      expect(block(r'C:\'), GameBodyRecyclePolicy.reasonDriveRoot);
    });

    test('应用自有目录本身', () {
      expect(block(r'D:\Apps\CTLib'), GameBodyRecyclePolicy.reasonAppRoot);
    });

    test('应用目录的上级目录（关键：不能被当成普通用户目录放过）', () {
      expect(block(r'D:\Apps'), GameBodyRecyclePolicy.reasonAppAncestor);
      expect(block(r'D:\Apps\'), GameBodyRecyclePolicy.reasonAppAncestor);
    });

    test('应用目录内部不触发本判定（走原有永久删除路径）', () {
      expect(block(r'D:\Apps\CTLib\Games\X'), isNull);
    });
  });

  group('拒绝：系统关键目录', () {
    const env = <String, String>{
      'SystemRoot': r'C:\Windows',
      'ProgramFiles': r'C:\Program Files',
      'ProgramFiles(x86)': r'C:\Program Files (x86)',
      'ProgramData': r'C:\ProgramData',
      'USERPROFILE': r'C:\Users\me',
    };

    test('Windows 目录及其子树', () {
      expect(block(r'C:\Windows', env: env), GameBodyRecyclePolicy.reasonSystem);
      expect(block(r'C:\Windows\System32\drivers', env: env),
          GameBodyRecyclePolicy.reasonSystem);
    });

    test('Program Files 子树', () {
      expect(block(r'C:\Program Files\SomeGame\bin', env: env),
          GameBodyRecyclePolicy.reasonSystem);
      expect(block(r'C:\Program Files (x86)\SomeGame', env: env),
          GameBodyRecyclePolicy.reasonSystem);
    });

    test('ProgramData 子树', () {
      expect(block(r'C:\ProgramData\Foo', env: env),
          GameBodyRecyclePolicy.reasonSystem);
    });
  });

  group('拒绝：用户主目录本体与一级子目录', () {
    const env = <String, String>{'USERPROFILE': r'C:\Users\me'};

    test('主目录本身', () {
      expect(block(r'C:\Users\me', env: env),
          GameBodyRecyclePolicy.reasonUserProfile);
    });

    test('Desktop / Documents 等一级子目录', () {
      expect(block(r'C:\Users\me\Desktop', env: env),
          GameBodyRecyclePolicy.reasonUserProfile);
      expect(block(r'C:\Users\me\Documents', env: env),
          GameBodyRecyclePolicy.reasonUserProfile);
    });
  });

  group('拒绝：网络位置（FOF_ALLOWUNDO 无效，会退化为永久删除）', () {
    test('UNC 路径', () {
      expect(block(r'\\NAS\share\Games\SomeGame'),
          GameBodyRecyclePolicy.reasonNetwork);
    });
  });

  group('拒绝原因不得为空且可读', () {
    test('所有拒绝原因都是非空中文短句', () {
      expect(GameBodyRecyclePolicy.reasonNetwork.isNotEmpty, isTrue);
      expect(GameBodyRecyclePolicy.reasonAppAncestor, contains('上级'));
      expect(GameBodyRecyclePolicy.reasonDriveRoot, contains('根目录'));
    });
  });
}
