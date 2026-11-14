// GameBodyRecyclePolicy 真机验证探针（231 环境专用）
//
// 231（ERROR_PIPE_BUSY）下 `flutter analyze` / `flutter test` 都无法 spawn
// 子进程，本探针用 flutter_tester 直接执行真实业务代码（非复刻），
// 断言与 `test/services/game_body_recycle_policy_test.dart` 一致。
//
// 编译 + 运行（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dartaotruntime.exe \
//     flutter/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
//     --platform flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
//     --packages .dart_tool/package_config.json --target flutter \
//     -o .dart_tool/recycle_policy_probe.dill dev_probe/recycle_policy_probe.dart
//   flutter/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
//     --disable-vm-service .dart_tool/recycle_policy_probe.dill

import 'dart:io';

import 'package:chrono_tide/services/game_body_recycle_policy.dart';

int _pass = 0;
int _fail = 0;

void expectEq(String name, String? actual, String? expected) {
  if (actual == expected) {
    _pass++;
  } else {
    _fail++;
    stdout.writeln('[FAIL] $name -> 实际=${actual ?? "null"} 期望=${expected ?? "null"}');
  }
}

String? block(
  String target, {
  List<String> roots = const <String>[r'D:\Apps\CTLib'],
  Map<String, String> env = const <String, String>{},
}) =>
    GameBodyRecyclePolicy.blockReason(target,
        appRoots: roots, environment: env);

void main() {
  // ---------- 允许：本地磁盘普通用户目录 ----------
  expectEq('本地导入游戏真实形态', block(r'E:\GAL\野良与皇女与流浪猫之心'), null);
  expectEq('盘符+一级目录', block(r'E:\GAL'), null);
  expectEq(
      '用户主目录深处',
      block(r'C:\Users\me\Desktop\GAL\SomeGame', env: const {
        'USERPROFILE': r'C:\Users\me',
        'SystemRoot': r'C:\Windows',
      }),
      null);

  // ---------- 拒绝：无效 / 应用自有 ----------
  expectEq('空路径', block(''), GameBodyRecyclePolicy.reasonEmpty);
  expectEq('空白路径', block('   '), GameBodyRecyclePolicy.reasonEmpty);
  expectEq('盘根 E:\\', block(r'E:\'), GameBodyRecyclePolicy.reasonDriveRoot);
  expectEq('盘根 E:', block('E:'), GameBodyRecyclePolicy.reasonDriveRoot);
  expectEq('盘根 C:\\', block(r'C:\'), GameBodyRecyclePolicy.reasonDriveRoot);
  expectEq('应用目录本身', block(r'D:\Apps\CTLib'),
      GameBodyRecyclePolicy.reasonAppRoot);
  expectEq('应用目录上级', block(r'D:\Apps'),
      GameBodyRecyclePolicy.reasonAppAncestor);
  expectEq('应用目录上级(带尾斜杠)', block(r'D:\Apps\'),
      GameBodyRecyclePolicy.reasonAppAncestor);
  expectEq('应用目录内部', block(r'D:\Apps\CTLib\Games\X'), null);

  // ---------- 拒绝：系统目录 ----------
  const sysEnv = <String, String>{
    'SystemRoot': r'C:\Windows',
    'ProgramFiles': r'C:\Program Files',
    'ProgramFiles(x86)': r'C:\Program Files (x86)',
    'ProgramData': r'C:\ProgramData',
    'USERPROFILE': r'C:\Users\me',
  };
  expectEq('Windows 根', block(r'C:\Windows', env: sysEnv),
      GameBodyRecyclePolicy.reasonSystem);
  expectEq('Windows 子树', block(r'C:\Windows\System32\drivers', env: sysEnv),
      GameBodyRecyclePolicy.reasonSystem);
  expectEq('Program Files 子树',
      block(r'C:\Program Files\SomeGame\bin', env: sysEnv),
      GameBodyRecyclePolicy.reasonSystem);
  expectEq('Program Files (x86) 子树',
      block(r'C:\Program Files (x86)\SomeGame', env: sysEnv),
      GameBodyRecyclePolicy.reasonSystem);
  expectEq('ProgramData 子树', block(r'C:\ProgramData\Foo', env: sysEnv),
      GameBodyRecyclePolicy.reasonSystem);

  // ---------- 拒绝：用户主目录本体与一级子目录 ----------
  const userEnv = <String, String>{'USERPROFILE': r'C:\Users\me'};
  expectEq('用户主目录本身', block(r'C:\Users\me', env: userEnv),
      GameBodyRecyclePolicy.reasonUserProfile);
  expectEq('Desktop', block(r'C:\Users\me\Desktop', env: userEnv),
      GameBodyRecyclePolicy.reasonUserProfile);
  expectEq('Documents', block(r'C:\Users\me\Documents', env: userEnv),
      GameBodyRecyclePolicy.reasonUserProfile);

  // ---------- 拒绝：网络位置 ----------
  expectEq('UNC 路径', block(r'\\NAS\share\Games\SomeGame'),
      GameBodyRecyclePolicy.reasonNetwork);

  stdout.writeln('[probe] pass=$_pass fail=$_fail');
  if (_fail > 0) {
    exitCode = 1;
  }
}
