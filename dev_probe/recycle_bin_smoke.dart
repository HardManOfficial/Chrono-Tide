// RecycleBinService 端到端冒烟（纯 Dart，2026-10-26）
//
// 本次改动让「删除游戏 → 本地文件移入回收站」成为真实动作，因此必须确认
// `shell32!SHFileOperationW(FOF_ALLOWUNDO)` 链路在本机可用。
//
// 为什么不用 flutter_tester：MEMORY 已记录 flutter_tester 下异步 IO
// （`Directory.create` / `Future.delayed`）不会真正推进，探针会在中途退出。
// `recycle_bin_service.dart` 刻意保持纯 Dart + FFI（无 flutter import），
// 因此可以直接用 dart.exe 跑。
//
// 运行（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages=.dart_tool/package_config.json dev_probe/recycle_bin_smoke.dart
//
// 会在回收站留下一个 `ct_recycle_smoke_*` 小目录（可随时清空回收站）。

import 'dart:io';

import 'package:chrono_tide/services/recycle_bin_service.dart';

Future<void> main() async {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final dir = Directory('.dart_tool/ct_recycle_smoke_$stamp');
  await dir.create(recursive: true);
  await File('${dir.path}/game.exe').writeAsString('smoke');
  await File('${dir.path}/data.pak').writeAsString('x' * 1024);

  final target = dir.absolute.path;
  stdout.writeln('[smoke] target = $target');

  final outcome = await RecycleBinService.moveToRecycleBin(target);
  final stillThere = Directory(target).existsSync();

  stdout.writeln('[smoke] outcome = $outcome');
  stdout.writeln('[smoke] stillExists = $stillThere');

  if (!outcome.ok || stillThere) {
    stdout.writeln('[smoke] FAIL');
    exitCode = 1;
    return;
  }
  stdout.writeln('[smoke] PASS —— 已移入回收站（可在回收站还原或清空）');
}
