// dev_probe/spawn_probe.dart
// 用途：隔离「沙箱是否阻断『从 dart 进程再 spawn 子进程』」这一层。
// 运行：flutter\bin\cache\dart-sdk\bin\dart.exe dev_probe\spawn_probe.dart
import 'dart:io';

void main() {
  stdout.write('dart 父进程 ok, pid=$pid\n');
  for (final probe in <List<String>>[
    <String>['where.exe', 'java'],
    <String>['cmd.exe', '/c', 'ver'],
    <String>['D:/CTLIB/flutter/bin/cache/dart-sdk/bin/dart.exe', '--version'],
  ]) {
    try {
      final r = Process.runSync(probe.first, probe.sublist(1));
      stdout.write('OK   ${probe.join(' ')} -> exit=${r.exitCode}\n');
    } catch (e) {
      stdout.write('FAIL ${probe.join(' ')} -> $e\n');
    }
  }
}
