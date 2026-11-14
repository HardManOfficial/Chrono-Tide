// DL-DISK-GUARD 端到端探针（flutter_tester 下运行，不依赖 `flutter test`）
//
// 为什么要自己写：本机 `flutter test` / `dart analyze` 都被句柄池耗尽
// （CreateFile failed 231）拦死，只能编译 kernel + flutter_tester 直跑。
//
// 覆盖本次改动的 4 条真实语义：
//   A. 写入改 RandomAccessFile 后，分片断流续传仍然正常（不回归既有 P0-1/P0-2）
//   B. 正常完成路径：文件大小等长、分片临时文件被清掉
//   C. 用户取消：状态 cancelled、分片清理干净
//   D. 写不进去时**快速失败**（不再无限"正在下载 0 B/s"、不再白重试 15 轮）
//
// 编译运行（在 D:\CTLIB 下）：
//   flutter/bin/cache/dart-sdk/bin/dartaotruntime.exe \
//     flutter/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
//     --platform flutter/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
//     --packages .dart_tool/package_config.json --target flutter \
//     -o dev_probe/dl_guard_e2e_probe.dill dev_probe/dl_guard_e2e_probe.dart
//   flutter/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
//     --disable-vm-service dev_probe/dl_guard_e2e_probe.dill
//
// 🔴 flutter_tester 坑：异步 `Directory.create(recursive: true)` 会**永久挂起**
//    （event loop 抽干后进程静默 exit 0），所以目标目录一律先 createSync 建好。

import 'dart:async';
import 'dart:io';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/download_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  SharedPreferences.setMockInitialValues({});
  final tmpDir = Directory.systemTemp.createTempSync('ct_dl_probe_');
  PathHelper.exeDirOverride = tmpDir.path;
  // 先把 downloads 建出来，绕开 flutter_tester 的 create(recursive) 挂起
  Directory(PathHelper.downloadsDir).createSync(recursive: true);
  stdout.writeln('[probe] downloads = ${PathHelper.downloadsDir}');

  final servers = <_RangeServer>[];
  try {
    await _caseA(servers);
    await _caseB(servers);
    await _caseC(servers);
    await _caseD(servers);
    await _caseE(servers);
    await _caseF(servers);
  } finally {
    for (final s in servers) {
      await s.close();
    }
    PathHelper.exeDirOverride = null;
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('=== 汇总: PASS=$_pass FAIL=$_fail ===');
  exit(_fail == 0 ? 0 : 1);
}

/// A：分片首次请求被截断 → 续传补全（回归既有 P0-1/P0-2）
Future<void> _caseA(List<_RangeServer> servers) async {
  const size = 400 * 1024;
  final server = await _RangeServer.start(totalSize: size, truncateFirst: true);
  servers.add(server);

  final core = DownloadCore();
  final errors = <String>[];
  core.addErrorListener(errors.add);
  await core.start(
    url: server.url('/game.rar'),
    gameId: 'probe-a',
    fileName: 'probe_a.bin',
    autoExtract: false,
  );

  stdout.writeln('[A] status=${core.status} errors=$errors');
  check('A 断流续传后状态 completed',
      core.status == DownloadStatus.completed, '${core.status}');
  check('A 无错误', errors.isEmpty, errors.join(' / '));
  if (core.savedPath != null) {
    check('A 文件大小精确等于 Content-Length',
        File(core.savedPath!).lengthSync() == size,
        '${File(core.savedPath!).lengthSync()} vs $size');
  }
  check('A 确实发生过续传（出现 start>0 的 Range）',
      server.rangeStarts.any((s) => s > 0), server.rangeStarts.join(','));
}

/// B：正常完成 → 分片临时文件全部清掉
Future<void> _caseB(List<_RangeServer> servers) async {
  const size = 3 * 1024 * 1024;
  final server = await _RangeServer.start(totalSize: size);
  servers.add(server);

  final core = DownloadCore();
  final errors = <String>[];
  core.addErrorListener(errors.add);
  await core.start(
    url: server.url('/game2.rar'),
    gameId: 'probe-b',
    fileName: 'probe_b.bin',
    autoExtract: false,
  );

  check('B 正常完成', core.status == DownloadStatus.completed, '${core.status}');
  check('B 无错误', errors.isEmpty, errors.join(' / '));
  final leftover = Directory(PathHelper.downloadsDir)
      .listSync()
      .where((e) => e.path.contains('.part_'))
      .toList();
  check('B 完成后无 .part 残留', leftover.isEmpty,
      leftover.map((e) => e.path).join(','));
}

/// C：下载中取消 → cancelled + 分片清理
Future<void> _caseC(List<_RangeServer> servers) async {
  const size = 8 * 1024 * 1024;
  final server = await _RangeServer.start(totalSize: size, slow: true);
  servers.add(server);

  final core = DownloadCore();
  final future = core.start(
    url: server.url('/game3.rar'),
    gameId: 'probe-c',
    fileName: 'probe_c.bin',
    autoExtract: false,
  );
  await Future<void>.delayed(const Duration(milliseconds: 600));
  core.cancel();
  await future.timeout(const Duration(seconds: 20),
      onTimeout: () => stdout.writeln('[C] ⚠️ 取消后 20s 仍未收敛'));

  check('C 取消后状态 cancelled',
      core.status == DownloadStatus.cancelled, '${core.status}');
  final leftover = Directory(PathHelper.downloadsDir)
      .listSync()
      .where((e) => e.path.contains('.part_'))
      .toList();
  check('C 取消后无 .part 残留', leftover.isEmpty,
      leftover.map((e) => e.path).join(','));
}

/// D：写不进去时必须**快速失败**（不能像旧实现那样无限"正在下载"）
Future<void> _caseD(List<_RangeServer> servers) async {
  const size = 256 * 1024;
  final server = await _RangeServer.start(totalSize: size);
  servers.add(server);

  // 制造写失败：把**分片临时文件**路径先建成目录 → open/write 必然失败。
  // （注意文件名来自 URL 末段，fileName 参数只是兜底，所以 URL 与名字必须一致）
  final blockedPath = '${PathHelper.downloadsDir}\\probe_d.bin.part_0.tmp';
  final outPath = '${PathHelper.downloadsDir}\\probe_d.bin';
  for (final p in [blockedPath, outPath]) {
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
      final d = Directory(p);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }
  Directory(blockedPath).createSync(recursive: true);

  final core = DownloadCore();
  final errors = <String>[];
  core.addErrorListener(errors.add);
  final sw = Stopwatch()..start();
  await core.start(
    url: server.url('/probe_d.bin'),
    gameId: 'probe-d',
    fileName: 'probe_d.bin',
    autoExtract: false,
  ).timeout(const Duration(seconds: 90), onTimeout: () {
    stdout.writeln('[D] ⚠️ 90s 仍未收敛（可能仍在重试）');
  });
  sw.stop();

  stdout.writeln('[D] status=${core.status} 用时=${sw.elapsed.inSeconds}s '
      'errors=$errors');
  check('D 写失败 → 状态 failed', core.status == DownloadStatus.failed,
      '${core.status}');
  check('D 错误信息可读（含磁盘/写入/权限关键词）',
      errors.isNotEmpty &&
          ['磁盘空间不足', '写入', '权限'].any((k) => errors.first.contains(k)),
      errors.isEmpty ? '(无错误)' : errors.first);
  // 旧实现会退避重试 15 轮（1+2+4+8+15×11 ≈ 3 分钟）；新实现应远快于此
  check('D 快速失败（< 30s）', sw.elapsed.inSeconds < 30,
      '${sw.elapsed.inSeconds}s');

  try {
    Directory(blockedPath).deleteSync(recursive: true);
  } catch (_) {}
}

/// E：磁盘准入 —— 声明一个远超可用空间的包，必须**在下第一个字节之前**被拦下。
///
/// 服务端只回 Content-Length（不真的发 4GB），所以这条用例成本近乎为零；
/// 它验证的是「14GB 的包把盘写满才发现」那个现场不会再发生。
Future<void> _caseE(List<_RangeServer> servers) async {
  const size = 4 * 1024 * 1024 * 1024; // 4GB，需要 ~8.5GB 空闲
  final server = await _RangeServer.start(totalSize: size);
  servers.add(server);

  final core = DownloadCore();
  final errors = <String>[];
  core.addErrorListener(errors.add);
  final sw = Stopwatch()..start();
  await core.start(
    url: server.url('/probe_e.bin'),
    gameId: 'probe-e',
    fileName: 'probe_e.bin',
    autoExtract: false,
  );
  sw.stop();

  stdout.writeln('[E] status=${core.status} 用时=${sw.elapsed.inMilliseconds}ms '
      'errors=$errors');
  check('E 空间不足 → 状态 failed', core.status == DownloadStatus.failed,
      '${core.status}');
  check('E 错误信息含「磁盘空间不足」与所需体积',
      errors.isNotEmpty &&
          errors.first.contains('磁盘空间不足') &&
          errors.first.contains('需要约'),
      errors.isEmpty ? '(无错误)' : errors.first);
  check('E 立即拦下（< 5s，未真正下载）', sw.elapsed.inSeconds < 5,
      '${sw.elapsedMilliseconds}ms');
  final leftover = Directory(PathHelper.downloadsDir)
      .listSync()
      .where((e) => e.path.contains('probe_e'))
      .toList();
  check('E 未落任何分片文件', leftover.isEmpty,
      leftover.map((e) => e.path).join(','));
}

/// F：缓存里已有完整包时不得重下（DL-SKIP-REDOWNLOAD）。
///
/// 真实场景：14GB 下完了、解压阶段失败（压缩包按策略保留在缓存里），用户点重试。
/// 旧实现会把整包再下一遍，而盘上那份还占着空间 —— 等于用 28GB 的读写换一份
/// 早就存在的文件。这里验证第二次 start 不再向服务器要任何 body 数据。
Future<void> _caseF(List<_RangeServer> servers) async {
  const size = 512 * 1024;
  final server = await _RangeServer.start(totalSize: size);
  servers.add(server);
  const fileName = 'probe_f_skip.bin';

  final first = DownloadCore();
  await first.start(
    url: server.url('/$fileName'),
    gameId: 'probe-f',
    fileName: fileName,
    autoExtract: false,
  );
  final path = '${PathHelper.downloadsDir}/$fileName';
  check('F 首次下载完成且文件存在',
      first.status == DownloadStatus.completed && File(path).existsSync(),
      '${first.status}');

  final before = server.rangeStarts.length;

  final second = DownloadCore();
  final errors = <String>[];
  second.addErrorListener(errors.add);
  final sw = Stopwatch()..start();
  await second.start(
    url: server.url('/$fileName'),
    gameId: 'probe-f',
    fileName: fileName,
    autoExtract: false,
  );
  sw.stop();
  final after = server.rangeStarts.length;

  check('F 第二次直接 completed（不重下）',
      second.status == DownloadStatus.completed && errors.isEmpty,
      '${second.status} ${errors}');
  check('F 第二次没有发出任何 body 下载请求',
      after == before, 'before=$before after=$after');
  check('F 跳过重下耗时极短（< 3s）', sw.elapsed.inSeconds < 3,
      '${sw.elapsedMilliseconds}ms');

  try {
    File(path).deleteSync();
  } catch (_) {}
}

/// 支持 Range 的本地测试服务器。
class _RangeServer {
  final HttpServer server;
  final int port;
  final int totalSize;
  final bool truncateFirst;
  final bool slow;
  final Map<String, int> _attempts = {};
  final List<int> rangeStarts = [];

  _RangeServer._(this.server, this.port, this.totalSize,
      {required this.truncateFirst, required this.slow});

  static Future<_RangeServer> start({
    required int totalSize,
    bool truncateFirst = false,
    bool slow = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _RangeServer._(server, server.port, totalSize,
        truncateFirst: truncateFirst, slow: slow);
    server.listen(s._handle);
    return s;
  }

  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method == 'HEAD') {
        req.response.headers
          ..set('content-length', '$totalSize')
          ..set('accept-ranges', 'bytes');
        await req.response.close();
        return;
      }

      final rangeHeader = req.headers.value('range');
      var start = 0;
      var end = totalSize - 1;
      if (rangeHeader != null) {
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rangeHeader);
        if (m != null) {
          start = int.parse(m.group(1)!);
          end = int.parse(m.group(2)!);
        }
      }
      if (start > end) end = start;
      rangeStarts.add(start);

      final key = '$start-$end';
      final attempt = (_attempts[key] ?? 0) + 1;
      _attempts[key] = attempt;

      final remaining = end - start + 1;
      final sendAll = !(truncateFirst && start == 0 && attempt == 1);
      final sendBytes = sendAll ? remaining : remaining ~/ 2;

      req.response.statusCode = rangeHeader == null ? 200 : 206;
      req.response.headers
        ..set('content-length', '$remaining')
        ..set('accept-ranges', 'bytes');

      const chunkSize = 8192;
      var written = 0;
      while (written < sendBytes) {
        final n = (sendBytes - written) < chunkSize
            ? (sendBytes - written)
            : chunkSize;
        req.response.add(List<int>.filled(n, start & 0xFF));
        written += n;
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      await req.response.close();
    } catch (_) {
      // 客户端提前断开（取消/重试）时走到这里，忽略
    }
  }
}
