// 存储/下载系统审计探针（flutter_tester 下运行，纯逻辑）
//
// 覆盖 2026-11-03 第三轮审计修掉的几处：
//   ① PathHelper.isTempLayerDirName：临时层判定收紧为「以 _temp_layer_数字 结尾」，
//      避免 `contains('_temp_layer_')` 把名字里恰好含该片段的真实游戏目录递归删掉
//   ② DownloadSpaceBudget：两个下载任务同盘时的预留登记与释放
//   ③ PathValidator 系统目录判定：盘根 / 环境变量系统目录 / 回收站一律拒绝，
//      但不误伤用户自己的目录
//
// 编译运行（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dartaotruntime.exe \
//     flutter/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
//     --platform flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
//     --packages .dart_tool/package_config.json --target flutter \
//     -o dev_probe/storage_download_audit_probe.dill dev_probe/storage_download_audit_probe.dart
//   flutter/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
//     --disable-vm-service dev_probe/storage_download_audit_probe.dill

import 'dart:io';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/download_space_budget.dart';
import 'package:chrono_tide/services/path_validator.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    stdout.writeln('PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    stdout.writeln('FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void main() {
  stdout.writeln('[probe] exeDir = ${PathHelper.exeDir}');

  // ---------- ① 临时层目录名判定 ----------
  check('① 真临时层（点分隔 + 数字结尾）命中',
      PathHelper.isTempLayerDirName('某游戏._temp_layer_0'));
  check('① 真临时层（下划线 + 两位数）命中',
      PathHelper.isTempLayerDirName('某游戏_temp_layer_12'));
  check('① 真临时层（大写）命中',
      PathHelper.isTempLayerDirName('Game._TEMP_LAYER_3'));
  check('① 用户目录名含片段但不以数字结尾 → 不命中（不会被误删）',
      !PathHelper.isTempLayerDirName('我的_temp_layer_存档'));
  check('① 普通游戏目录 → 不命中',
      !PathHelper.isTempLayerDirName('Summer Pockets'));
  check('① 数字在中间 → 不命中',
      !PathHelper.isTempLayerDirName('_temp_layer_1_backup'));

  // ---------- ② 全局磁盘预留 ----------
  DownloadSpaceBudget.resetForTest();
  const taskA = 'task-A';
  const taskB = 'task-B';
  const gb = 1024 * 1024 * 1024;

  check('② 初始没有其他任务预留',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskA) == 0);

  DownloadSpaceBudget.reserve(r'E:\Games', taskA, 2 * gb);
  check('② A 预留后，B 看到 2GB 被占',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskB) == 2 * gb,
      '${DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskB) ~/ gb}GB');
  check('② A 自己看不到自己（不会自扣）',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskA) == 0);

  DownloadSpaceBudget.reserve(r'E:\Games', taskB, 1 * gb);
  check('② 两个任务叠加时，A 看到 B 的 1GB',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskA) == 1 * gb);

  check('② 换一块盘互不影响',
      DownloadSpaceBudget.reservedByOthers(r'F:\Games', taskA) == 0);

  DownloadSpaceBudget.release(taskB);

  // 小写盘符 / 正斜杠归一
  DownloadSpaceBudget.reserve(r'e:/Other', 'task-C', 512 * 1024 * 1024);
  check('② 盘符大小写/分隔符归一（e:/ 与 E:\\ 视为同一块盘）',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games\X', taskA) == 512 * 1024 * 1024,
      '${DownloadSpaceBudget.reservedByOthers(r'E:\Games\X', taskA) ~/ (1024 * 1024)}MB');

  DownloadSpaceBudget.release(taskA);
  check('② 释放 A 后，B 眼中只剩 C 的 512MB',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskB) == 512 * 1024 * 1024,
      '${DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskB) ~/ (1024 * 1024)}MB');

  DownloadSpaceBudget.release(taskB);
  DownloadSpaceBudget.release('task-C');
  check('② 全部释放后归零（预留不会泄漏成永久误拦）',
      DownloadSpaceBudget.reservedByOthers(r'E:\Games', taskA) == 0 &&
          DownloadSpaceBudget.reservedByOthers(r'E:\Other', taskA) == 0);

  // ---------- ③ 系统目录判定 ----------
  String? errOf(String path) {
    final r = PathValidator.validateCustomGameLocation(path);
    return r.isValid ? null : '${r.errorCode}:${r.message}';
  }

  check('③ 盘根 D:\\ 被拒（清理逻辑对盘根一律跳过，装进去就收不回）',
      errOf(r'D:\')?.startsWith('SYSTEM_DIR') == true, '${errOf(r'D:\')}');
  check('③ 盘根不带分隔符 D: 被拒',
      errOf('D:')?.startsWith('SYSTEM_DIR') == true, '${errOf('D:')}');
  check('③ C:\\Windows\\System32 被拒',
      errOf(r'C:\Windows\System32')?.startsWith('SYSTEM_DIR') == true,
      '${errOf(r'C:\Windows\System32')}');
  check('③ Program Files 子目录被拒',
      errOf(r'C:\Program Files\Foo')?.startsWith('SYSTEM_DIR') == true,
      '${errOf(r'C:\Program Files\Foo')}');

  // 环境变量系统的目录（跨盘符）也要挡：用 ProgramData 所在盘构造
  final programData = Platform.environment['ProgramData'];
  if (programData != null && programData.isNotEmpty) {
    final probe = '$programData\\CtProbeGame';
    check('③ %ProgramData% 子目录被拒（跨盘符也成立）',
        errOf(probe)?.startsWith('SYSTEM_DIR') == true, '${errOf(probe)}');
  }

  // 用户自己的目录不能误伤：用一个确实存在、且不是系统目录的位置
  final safeBase = _safeBaseDir();
  if (safeBase == null) {
    stdout.writeln('SKIP  ③ 本机没有可用于「不误伤」验证的普通目录');
  } else {
    final target = '$safeBase\\CtProbeGame_${DateTime.now().millisecondsSinceEpoch}';
    final err = errOf(target);
    check('③ 普通用户目录不被误判为系统目录', err == null, '$err');
    try {
      final d = Directory(target);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('=== 汇总: PASS=$_pass FAIL=$_fail ===');
  exit(_fail == 0 ? 0 : 1);
}

/// 找一个「非系统、非盘根、非用户主目录、且存在」的目录作为安全基准。
String? _safeBaseDir() {
  for (final candidate in [
    r'D:\CTLIB\dev_probe',
    r'E:\',
    r'D:\',
  ]) {
    if (candidate == r'E:\' || candidate == r'D:\') {
      // 盘根本身不能当 safeBase（会被判系统目录），跳过
      continue;
    }
    if (Directory(candidate).existsSync()) return candidate;
  }
  return null;
}
