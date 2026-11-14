// Phase 1 注入层真机探针 —— 只做「注入」，窗口编排交给 Python 侧
// （Python 已有成熟的窗口枚举/前台/观察逻辑，避免在 Dart 里重造）
//
// 用法：
//   ./flutter/bin/dart.bat run dev_probe/injector_probe.dart <pid> <mode>
//   mode: altenter | enter | f13 | click
//
// 输出：RESULT <outcome> accepted=<n>
import 'dart:io';

import 'package:chrono_tide/services/gamepad/input_injector.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: injector_probe.dart <pid> <mode>');
    exit(2);
  }
  final pid = int.tryParse(args[0]);
  final mode = args[1];
  if (pid == null) {
    stderr.writeln('bad pid: ${args[0]}');
    exit(2);
  }

  final sink = SendInputSink.tryCreate();
  final fg = User32ForegroundChecker.tryCreate();
  if (sink == null || fg == null) {
    stdout.writeln('RESULT unsupported accepted=0');
    exit(3);
  }

  stdout.writeln('DIAG inputStruct=${SendInputSink.debugInputStructSize} '
      'keybd=${SendInputSink.debugKeybdInputSize} '
      'mouse=${SendInputSink.debugMouseInputSize}');

  final injector = InputInjector(sink: sink, foreground: fg)
    ..bindTargetPid(pid);
  stdout.writeln('DIAG foregroundPid=${fg.foregroundPid()} target=$pid '
      'guard=${injector.isForegroundGuardPassing}');

  InjectionResult r;
  switch (mode) {
    case 'altenter':
      // 组合键：按住 Alt → 敲 Enter → 松开 Alt（顺带验证 holdKeyDown/releaseKey）
      final d1 = injector.holdKeyDown(0x12);
      final d2 = await injector.tapKey(0x0D);
      final d3 = injector.releaseKey(0x12);
      stdout.writeln('DIAG altDown=$d1 enter=$d2 altUp=$d3');
      r = d2;
      break;
    case 'enter':
      r = await injector.tapKey(0x0D);
      break;
    case 'f13':
      // 惰性键：控制组用，真实键盘上没有
      r = await injector.tapKey(0x7C);
      break;
    case 'click':
      r = await injector.clickAt(0.5, 0.45);
      break;
    default:
      stderr.writeln('unknown mode: $mode');
      exit(2);
  }

  stdout.writeln('RESULT ${r.outcome.name} accepted=${r.accepted}');
  sink.dispose();
}
