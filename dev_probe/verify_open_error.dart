// 补充探针：分片文件「打不开」时 Dart 抛出的确切实参形态。
// 用途：给 download_core 的 _classifyWriteError 补判定（当前 D 用例会当成
// 普通网络抖动重试 15 轮 ≈ 3 分钟）。
//
// 用法（纯 Dart，不需要 flutter）：
//   flutter/bin/cache/dart-sdk/bin/dart.exe --packages=.dart_tool/package_config.json \
//     dev_probe/verify_open_error.dart

import 'dart:io';

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('ct_open_err_');
  try {
    // ① 目标路径是目录
    final dirPath = '${tmp.path}\\blocked.bin.part_0.tmp';
    Directory(dirPath).createSync(recursive: true);
    await _probe('目标是目录', dirPath);

    // ② 目标是系统保护目录（无写权限）
    await _probe('无写权限', r'C:\Windows\System32\ct_probe_x.bin');

    // ③ 父目录不存在
    await _probe('父目录不存在', '${tmp.path}\\no_such_dir\\x.bin');
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<void> _probe(String label, String path) async {
  stdout.writeln('--- $label: $path');
  RandomAccessFile? raf;
  try {
    raf = await File(path).open(mode: FileMode.append);
    stdout.writeln('    open 成功（未抛异常）');
    try {
      await raf.writeFrom(List<int>.filled(16, 1));
      stdout.writeln('    write 成功（未抛异常）');
    } catch (e) {
      _dump('writeFrom', e);
    }
  } catch (e) {
    _dump('open', e);
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

void _dump(String where, Object e) {
  if (e is FileSystemException) {
    stdout.writeln('    $where → FileSystemException');
    stdout.writeln('      message = ${e.message}');
    stdout.writeln('      osError = ${e.osError?.message}');
    stdout.writeln('      errCode = ${e.osError?.errorCode}');
  } else {
    stdout.writeln('    $where → ${e.runtimeType}: $e');
  }
}
