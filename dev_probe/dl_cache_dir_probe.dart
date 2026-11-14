// DL-CACHE-FOLLOW-INSTALL 探针（flutter_tester 下运行，纯逻辑，不建界面）
//
// 验证 `DownloadCacheDir` 的规则（用户 2026-11-03 明确定义）：
//   ① 游戏下载缓存**跟随安装位置**，不再固定写进 exe/downloads；
//      未指定安装位置 → `<exe>/ChronoTide_Cache/downloads`
//   ② 跨盘安装 → `<安装位置父目录>/ChronoTide_Cache/downloads`，且目录真实创建
//   ③ 解析结果写回 PathHelper.downloadsDir（既有消费者零改动跟随）
//   ④ 软件自身资产目录（appAssetsDir）与游戏缓存**分家**，恒为 exe/downloads
//   ⑤ isManagedCachePath：托管缓存内的文件才允许清理
//   ⑥ cleanupIfEmpty：空缓存目录会被删掉，非空的一定保留
//
// 编译运行（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dartaotruntime.exe \
//     flutter/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
//     --platform flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
//     --packages .dart_tool/package_config.json --target flutter \
//     -o dev_probe/dl_cache_dir_probe.dill dev_probe/dl_cache_dir_probe.dart
//   flutter/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
//     --disable-vm-service dev_probe/dl_cache_dir_probe.dill

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/download_cache_dir.dart';
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

Future<void> main() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  try {
    await SharedPreferences.getInstance();
  } catch (e) {
    stdout.writeln('[probe] ⚠️ SharedPreferences 不可用: $e');
  }

  final factory = p.normalize(PathHelper.defaultDownloadsDir);
  final exeRoot = p.normalize(PathHelper.exeDir);
  stdout.writeln('[probe] exeDir        = ${PathHelper.exeDir}');
  stdout.writeln('[probe] 出厂 downloads = $factory');

  // ① 未指定安装位置（默认装到 exe/Games 下）→ 缓存跟到 exe/ChronoTide_Cache
  final a = await DownloadCacheDir.resolveFor(installTargetDir: null);
  final expectedDefault = p.normalize(
      p.join(exeRoot, DownloadCacheDir.folderName,
          DownloadCacheDir.downloadsSubDir));
  stdout.writeln('[probe] 默认安装解析 = $a');
  check('① 默认安装 → 缓存进 <exe>/ChronoTide_Cache（不再写进 downloads）',
      p.equals(a, expectedDefault), a);
  check('① 默认安装不再覆盖为出厂 downloads',
      !p.equals(a, factory), a);

  // ①b 同盘自定义安装（exe 盘上的游戏目录）→ 跟随父目录，而不是出厂 downloads
  final sameDiskTarget = p.join(exeRoot, 'Games', 'ProbeSameDisk');
  final b = await DownloadCacheDir.resolveFor(installTargetDir: sameDiskTarget);
  final expectedSame =
      p.normalize(p.join(exeRoot, 'Games', DownloadCacheDir.folderName,
          DownloadCacheDir.downloadsSubDir));
  check('①b 同盘自定义安装 → 跟随安装父目录',
      p.equals(b, expectedSame), b);

  // ② 换到另一块盘
  final otherDrive = _otherDrive();
  if (otherDrive == null) {
    stdout.writeln('SKIP  ②③ 本机没有第二块可用盘');
  } else {
    stdout.writeln('[probe] 第二块盘 = $otherDrive');
    final target = p.join(otherDrive, 'Games', 'ProbeGame');
    final expected =
        p.normalize(p.join(otherDrive, 'Games', DownloadCacheDir.folderName,
            DownloadCacheDir.downloadsSubDir));
    final c = await DownloadCacheDir.resolveFor(installTargetDir: target)
        .timeout(const Duration(seconds: 20), onTimeout: () {
      stdout.writeln('[probe] ⚠️ resolveFor 20s 未返回');
      return '(timeout)';
    });
    stdout.writeln('[probe] 跨盘解析 = $c');
    check('② 跨盘 → 缓存落到安装位置旁边（<库根>/ChronoTide_Cache）',
        p.equals(c, expected), c);
    check('② 目录已真实创建', Directory(c).existsSync());
    check('③ PathHelper.downloadsDir 已跟随', p.equals(PathHelper.downloadsDir, c),
        PathHelper.downloadsDir);
    check('③ 候选目录里没有残留探测文件',
        !File(p.join(c, '.ct_write_probe')).existsSync());

    // ⑤ isManagedCachePath
    final inside = p.join(c, 'SomeGame_v1.7z');
    final outside = p.join(otherDrive, 'MyOwnArchives', 'SomeGame_v1.7z');
    check('⑤ 缓存内的包判定为托管（可清理）',
        DownloadCacheDir.isManagedCachePath(inside), inside);
    check('⑤ 用户自选目录的包不判定为托管（绝不删）',
        !DownloadCacheDir.isManagedCachePath(outside), outside);
    check('⑤ 出厂 downloads 仍判定为托管（老残留照样清）',
        DownloadCacheDir.isManagedCachePath(p.join(factory, 'old.part_0.tmp')));

    // ⑥ cleanupIfEmpty：空 → 删；非空 → 留
    final keepFile = File(p.join(c, 'keep.bin'))..writeAsBytesSync(const [1, 2]);
    await DownloadCacheDir.cleanupIfEmpty(c);
    check('⑥ 非空缓存目录不会被删', Directory(c).existsSync() && keepFile.existsSync());

    keepFile.deleteSync();
    await DownloadCacheDir.cleanupIfEmpty(c);
    final rootGone = !Directory(
            p.join(otherDrive, 'Games', DownloadCacheDir.folderName))
        .existsSync();
    check('⑥ 空缓存目录（含外层根）被清掉',
        !Directory(c).existsSync() && rootGone, c);

    // ⑦ deleteManagedArchive：安装成功后删原包的真实行为
    Directory(c).createSync(recursive: true);
    final managedPkg = File(p.join(c, 'Installed_v1.7z'))
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    final freed = await DownloadCacheDir.deleteManagedArchive(managedPkg.path);
    check('⑦ 托管缓存内的包被删除并回报体积',
        freed == 4096 && !managedPkg.existsSync(), '$freed');
    check('⑦ 删完空缓存根一并收掉',
        !Directory(p.join(otherDrive, 'Games', DownloadCacheDir.folderName))
            .existsSync());

    final userPkgDir = Directory(p.join(otherDrive, 'MyOwnArchives'));
    userPkgDir.createSync(recursive: true);
    final userPkg = File(p.join(userPkgDir.path, 'Mine_v1.7z'))
      ..writeAsBytesSync(List<int>.filled(1024, 3));
    final notFreed = await DownloadCacheDir.deleteManagedArchive(userPkg.path);
    check('⑦ 用户自选的包不被删除（返回 null）',
        notFreed == null && userPkg.existsSync(), '$notFreed');
    try {
      userPkg.deleteSync();
      userPkgDir.deleteSync();
    } catch (_) {}

    final notFound = await DownloadCacheDir.deleteManagedArchive(
        p.join(c, 'never_existed.7z'));
    check('⑦ 文件不存在时安全返回 null', notFound == null, '$notFound');
  }

  // ④ 软件自身资产目录与游戏缓存分家
  check('④ appAssetsDir 恒为 exe/downloads',
      p.equals(DownloadCacheDir.appAssetsDir, factory),
      DownloadCacheDir.appAssetsDir);
  check('④ 游戏缓存 ≠ 软件资产目录（本次已分家）',
      !p.equals(PathHelper.downloadsDir, factory), PathHelper.downloadsDir);

  // 兜底清理本探针在 exe 盘造出来的空目录
  for (final dir in [
    expectedDefault,
    p.join(exeRoot, 'Games', DownloadCacheDir.folderName,
        DownloadCacheDir.downloadsSubDir),
  ]) {
    try {
      if (Directory(dir).existsSync() && Directory(dir).listSync().isEmpty) {
        Directory(dir).deleteSync();
        final parent = Directory(p.dirname(dir));
        if (parent.existsSync() && parent.listSync().isEmpty) parent.deleteSync();
      }
    } catch (_) {}
  }

  stdout.writeln('=== 汇总: PASS=$_pass FAIL=$_fail ===');
  exit(_fail == 0 ? 0 : 1);
}

/// 找一块与 exe 不同、且不是光驱/网络盘的本地盘。
String? _otherDrive() {
  final exeDrive = RegExp(r'^([A-Za-z]):').firstMatch(PathHelper.exeDir);
  final exeLetter = exeDrive?.group(1)?.toUpperCase();
  for (final letter in ['E', 'F', 'G', 'D', 'C']) {
    if (letter == exeLetter) continue;
    if (Directory('$letter:\\').existsSync()) return '$letter:\\';
  }
  return null;
}
