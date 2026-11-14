// 纯 Dart 探针（不依赖 flutter，不 spawn 子进程）：验证 DL-DISK-GUARD 所依赖的
// 两个平台事实，避免"改完只能靠猜"。
//
//   ① `RandomAccessFile.open(mode: append)` + `writeFrom` + `flush` + `close`
//      的追加语义是否与旧 `File.openWrite(append)` 一致（续传靠它）。
//   ② 磁盘写满时 `writeFrom` 抛出的到底是什么：是否 `FileSystemException`、
//      `osError.errorCode` 是不是 112、消息里是不是中文"磁盘空间不足。"。
//      `_classifyWriteError` 的判定完全建立在这两点上。
//   ③ 盘符路径运算（`_driveOf` / `_candidates` / 同盘判定）在 Windows 风格下
//      的实际输出。
//
// 用法（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages=flutter/packages/flutter_tools/.dart_tool/package_config.json \
//     dev_probe/verify_disk_guard.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

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
  stdout.writeln('=== ① RandomAccessFile 追加语义 ===');
  final tmpDir = Directory.systemTemp.createTempSync('dl_guard_');
  final f = File(p.join(tmpDir.path, 'append.bin'));
  try {
    // 先写 3 字节
    final raf1 = await f.open(mode: FileMode.write);
    await raf1.writeFrom(<int>[1, 2, 3]);
    await raf1.flush();
    await raf1.close();
    // 再 append 2 字节
    final raf2 = await f.open(mode: FileMode.append);
    await raf2.writeFrom(<int>[4, 5]);
    await raf2.flush();
    await raf2.close();
    final bytes = await f.readAsBytes();
    check('append 追加而非覆盖', bytes.length == 5,
        '实际 ${bytes.length} 字节: $bytes');
    check('append 内容顺序正确', bytes.join(',') == '1,2,3,4,5', bytes.join(','));
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln();
  stdout.writeln('=== ② 磁盘写满时的真实异常形态 ===');
  // 找一个几乎写满的盘：优先 D:（本机实测 100%），找不到就跳过
  final targets = <String>['D:\\', 'C:\\'];
  var observed = false;
  for (final drive in targets) {
    final free = await _freeBytes(drive);
    if (free == null) continue;
    stdout.writeln('  $drive 可用 ${(free / 1024 / 1024).toStringAsFixed(1)} MB');
    if (free > 64 * 1024 * 1024) continue; // 只在这个盘确实快满时才有意义
    final probe = Directory(p.join(drive, 'ct_diskfull_probe'));
    try {
      probe.createSync(recursive: true);
      final big = File(p.join(probe.path, 'big.bin'));
      final raf = await big.open(mode: FileMode.write);
      final chunk = List<int>.filled(1024 * 1024, 0);
      var written = 0;
      try {
        while (written < 256 * 1024 * 1024) {
          await raf.writeFrom(chunk);
          written += chunk.length;
        }
        check('磁盘写满应抛异常', false, '写了 ${written ~/ 1024 ~/ 1024}MB 仍未抛');
      } on FileSystemException catch (e) {
        observed = true;
        stdout.writeln('  捕获: ${e.runtimeType}');
        stdout.writeln('    message  = ${e.message}');
        stdout.writeln('    osError  = ${e.osError?.message}');
        stdout.writeln('    errCode  = ${e.osError?.errorCode}');
        final detail = e.osError?.message ?? '';
        check('是 FileSystemException', true);
        check('errCode == 112 (ERROR_DISK_FULL)', e.osError?.errorCode == 112,
            '${e.osError?.errorCode}');
        check('消息含「磁盘空间不足」', detail.contains('磁盘空间不足'), detail);
        check('消息不含英文 no space（中文系统）', !detail.contains('no space'),
            detail);
      } finally {
        try {
          await raf.close();
        } catch (_) {}
        try {
          probe.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      stdout.writeln('  探针异常（跳过该盘）: $e');
    }
    break;
  }
  if (!observed) {
    stdout.writeln('  SKIP 当前没有接近写满的盘，无法实测 errno 112');
  }

  stdout.writeln();
  stdout.writeln('=== ③ 盘符路径运算（DownloadCacheDir 依赖） ===');
  String? driveOf(String s) {
    final m = RegExp(r'^([A-Za-z]):').firstMatch(s.trim());
    return m == null ? null : '${m.group(1)!.toUpperCase()}:\\';
  }

  check('driveOf(E:\\Games\\Foo) == E:\\', driveOf('E:\\Games\\Foo') == 'E:\\');
  check('driveOf(\\\\nas\\share\\x) == null', driveOf('\\\\nas\\share\\x') == null);
  check('同盘判定大小写无关',
      'E:\\'.toLowerCase() == driveOf('e:/games/x')!.toLowerCase());

  final driveRoot = p.join('E:\\', 'ChronoTide_Cache', 'downloads');
  check('盘根下缓存路径', driveRoot == 'E:\\ChronoTide_Cache\\downloads', driveRoot);

  final target = 'E:\\Games\\Foo';
  final parent = p.dirname(target);
  check('dirname(E:\\Games\\Foo) == E:\\Games', parent == 'E:\\Games', parent);
  check('父目录 != 盘根 ⇒ 会生成第二候选',
      !p.equals(p.normalize(parent), p.normalize('E:\\')),
      'parent=$parent');

  final target2 = 'E:\\Foo';
  check('安装位置就在盘根时不再加父目录候选',
      p.equals(p.normalize(p.dirname(target2)), p.normalize('E:\\')),
      p.dirname(target2));

  check('scanDirs 去重用的 p.equals 能吃掉大小写与斜杠差异',
      p.equals('E:/Games', 'e:\\games'));

  stdout.writeln();
  stdout.writeln('=== ④ 写失败时 IOSink(旧) vs RandomAccessFile(新) 的错误可见性 ===');
  // 用一个"必然写不进去"的目标：系统目录（非管理员无写权限）
  const deniedPath = r'C:\Windows\System32\ct_disk_guard_probe.bin';
  final chunk = List<int>.filled(64 * 1024, 7);

  // 旧写法：openWrite + add + flush
  var sinkThrew = false;
  Object? sinkErr;
  Object? doneErr;
  try {
    final sink = File(deniedPath).openWrite();
    // 旧实现从不监听 done —— 这里只记录它有没有报错，模拟"被全局 onError 吞掉"
    sink.done.catchError((Object e) {
      doneErr = e;
      return null;
    });
    sink.add(chunk);
    try {
      await sink.flush();
    } catch (e) {
      sinkThrew = true;
      sinkErr = e;
    }
    try {
      await sink.close();
    } catch (e) {
      if (!sinkThrew) {
        sinkThrew = true;
        sinkErr = e;
      }
    }
  } catch (e) {
    sinkThrew = true;
    sinkErr = e;
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  stdout.writeln('  IOSink: flush/close 抛异常 = $sinkThrew | done 回调异常 = ${doneErr != null}');
  if (sinkErr is FileSystemException) {
    stdout.writeln('    flush/close 侧: errCode=${(sinkErr as FileSystemException).osError?.errorCode}'
        ' msg=${(sinkErr as FileSystemException).osError?.message}');
  }

  // 新写法：RandomAccessFile
  var rafThrew = false;
  Object? rafErr;
  try {
    final raf = await File(deniedPath).open(mode: FileMode.write);
    try {
      await raf.writeFrom(chunk);
      await raf.flush();
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  } catch (e) {
    rafThrew = true;
    rafErr = e;
  }
  stdout.writeln('  RandomAccessFile: 抛异常 = $rafThrew');
  if (rafErr is FileSystemException) {
    final fe = rafErr as FileSystemException;
    stdout.writeln('    errCode=${fe.osError?.errorCode} msg=${fe.osError?.message}');
    // _classifyWriteError 对"拒绝访问"的判定依赖 code==5 或消息含中文"拒绝访问"
    final byCode = fe.osError?.errorCode == 5;
    final byMsg = (fe.osError?.message ?? '').contains('拒绝访问');
    check('可判定为"权限不足"（code==5 或 中文消息）', byCode || byMsg,
        'code=${fe.osError?.errorCode} msg=${fe.osError?.message}');
  } else {
    check('写出错时抛 FileSystemException', false,
        '实际: ${rafErr.runtimeType}: $rafErr');
  }

  stdout.writeln();
  exitCode = _fail == 0 ? 0 : 1;
}

Future<int?> _freeBytes(String drive) async {
  // 用 Win32 GetDiskFreeSpaceExW（纯 FFI，不 spawn 子进程 —— 本机管道池已耗尽）
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final fn = k32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>),
        int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>)>('GetDiskFreeSpaceExW');
    // 注意：`malloc<Utf16>` 编译不过（Utf16 非原生类型），一律走 toNativeUtf16。
    final root = drive.toNativeUtf16();
    final freeCaller = malloc<Uint64>();
    final total = malloc<Uint64>();
    final freeTotal = malloc<Uint64>();
    try {
      final ok = fn(root, freeCaller, total, freeTotal);
      if (ok == 0) return null;
      return freeCaller.value.toInt();
    } finally {
      malloc.free(root);
      malloc.free(freeCaller);
      malloc.free(total);
      malloc.free(freeTotal);
    }
  } catch (_) {
    return null;
  }
}
