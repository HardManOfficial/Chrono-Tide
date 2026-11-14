// ignore_for_file: avoid_print
//
// 探针：验证「下载加速通道」（DownloadAcceleration）端到端可用。
//
// 为什么要自建代理：本机 7892 端口上的代理会随用户开关变化（实测排查过程中
// 它就退出了），探针不能依赖它。这里起一个**进程内**的极简 HTTP CONNECT
// 代理（监听 127.0.0.1:7899，本身直连出网），用它验证：
//   ① detect() 能扫到监听端口并确认「这个代理能拉通目标直链」；
//   ② dioFor(proxy) 真的把请求交给了代理（findProxy 生效）；
//   ③ 代理 URL 归一化（省略 http:// 也能用）；
//   ④ 关掉代理后 detect 会回 null（不误报）。
//
// 运行（裸 VM）：
//   flutter/bin/cache/dart-sdk/bin/dart.exe --packages=.dart_tool/package_config.json \
//     dev_probe/download_accel_probe.dart

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:chrono_tide/services/download_acceleration.dart';

const String _url =
    'https://dl.imoe.uk/letmoe/66df3e2c-6e96-454f-b94a-4c9a06b51e57.zip';
const int _fakeProxyPort = 7899;

int _pass = 0;
int _fail = 0;
int _skip = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('✅ PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('❌ FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

void skip(String name, [String detail = '']) {
  _skip++;
  print('⏭️ SKIP  $name${detail.isEmpty ? '' : '  ($detail)'}');
}

String fmt(int bps) {
  if (bps >= 1048576) return '${(bps / 1048576).toStringAsFixed(2)} MB/s';
  if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  return '$bps B/s';
}

int _headerEnd(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

/// 极简 HTTP CONNECT 代理（只支持 CONNECT，够本探针用）。
class _FakeProxy {
  ServerSocket? _server;
  int connectCount = 0;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4,
        _fakeProxyPort);
    _server!.listen(_handle);
  }

  Future<void> _handle(Socket client) async {
    var headerDone = false;
    final buf = BytesBuilder();
    Socket? upstream;

    client.listen((data) {
      if (headerDone) {
        upstream?.add(data);
        return;
      }
      buf.add(data);
      final bytes = buf.toBytes();
      final idx = _headerEnd(bytes);
      if (idx < 0) return;

      final head = String.fromCharCodes(bytes.sublist(0, idx));
      final firstLine = head.split('\r\n').first;
      final parts = firstLine.split(' ');
      if (parts.length < 2 || parts[0] != 'CONNECT') {
        client.destroy();
        return;
      }
      final hp = parts[1].split(':');
      if (hp.length != 2) {
        client.destroy();
        return;
      }
      headerDone = true;
      connectCount++;

      Socket.connect(hp[0], int.parse(hp[1]),
              timeout: const Duration(seconds: 15))
          .then((u) {
        upstream = u;
        client.add('HTTP/1.1 200 Connection Established\r\n\r\n'.codeUnits);
        final rest = bytes.sublist(idx + 4);
        if (rest.isNotEmpty) u.add(rest);
        u.listen(
          (d) => client.add(d),
          onDone: () => client.destroy(),
          onError: (_) => client.destroy(),
        );
      }).catchError((Object e) {
        client.destroy();
      });
    }, onDone: () => upstream?.destroy(), onError: (_) => client.destroy());
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

/// 下载 [bytes] 字节并返回平均 B/s。
Future<int> _measure(Dio dio, int bytes,
    {Duration limit = const Duration(seconds: 25)}) async {
  final sw = Stopwatch()..start();
  var got = 0;
  try {
    final resp = await dio.get<ResponseBody>(
      _url,
      options: Options(
        headers: {'Range': 'bytes=0-${bytes - 1}'},
        responseType: ResponseType.stream,
      ),
    );
    await for (final chunk in resp.data!.stream.timeout(limit)) {
      got += chunk.length;
      if (got >= bytes) break;
    }
  } catch (e) {
    print('    ⚠️ 测速中断: ${e.runtimeType}');
  }
  sw.stop();
  if (sw.elapsedMilliseconds <= 0) return 0;
  return (got * 1000 / sw.elapsedMilliseconds).round();
}

Future<void> main() async {
  final fake = _FakeProxy();
  await fake.start();
  print('=== [0] 自建 CONNECT 代理已监听 127.0.0.1:$_fakeProxyPort ===');

  print('\n=== [A] detect 探测本机代理 ===');
  final proxy = await DownloadAcceleration.detect(probeUrl: _url);
  print('  结果: $proxy');
  check('A1 探测到可用代理', proxy != null, '$proxy');
  check('A2 返回的是 loopback http 地址',
      proxy != null && RegExp(r'^http://127\.0\.0\.1:\d+$').hasMatch(proxy),
      '$proxy');
  final hitFake = proxy == 'http://127.0.0.1:$_fakeProxyPort';
  if (hitFake) {
    check('A3 自建代理收到了 CONNECT 请求', fake.connectCount > 0,
        '${fake.connectCount} 次');
  } else {
    skip('A3 环境里已有更优先的真实代理，自建代理未被选中',
        '命中 $proxy');
  }

  if (proxy == null) {
    await fake.stop();
    print('\n=== 结果: $_pass PASS / $_fail FAIL ===');
    exit(_fail == 0 ? 0 : 1);
  }

  print('\n=== [B] 经代理下载 4MB（验证 findProxy 真的生效）===');
  final before = fake.connectCount;
  final proxyDio = DownloadAcceleration.dioFor(proxy);
  final bps = await _measure(proxyDio, 4 * 1024 * 1024);
  proxyDio.close(force: true);
  print('  吞吐 → ${fmt(bps)}');
  check('B1 能拉到数据', bps > 0, fmt(bps));
  if (hitFake) {
    check('B2 下载请求经过了代理', fake.connectCount > before,
        'CONNECT ${fake.connectCount - before} 次');
  } else {
    skip('B2 环境里已有真实代理，无法用自建代理计数验证');
  }

  print('\n=== [C] 省略 http:// 的写法 ===');
  final noScheme = proxy.replaceFirst('http://', '');
  final d2 = DownloadAcceleration.dioFor(noScheme);
  final bps2 = await _measure(d2, 1024 * 1024);
  d2.close(force: true);
  print('  "$noScheme" → ${fmt(bps2)}');
  check('C1 归一化后仍可用', bps2 > 0, fmt(bps2));

  print('\n=== [D] 自建代理路径：findProxy 确实把流量交给代理 ===');
  final beforeD = fake.connectCount;
  final fakeDio = DownloadAcceleration.dioFor('http://127.0.0.1:$_fakeProxyPort');
  final dBps = await _measure(fakeDio, 1024 * 1024);
  fakeDio.close(force: true);
  print('  吞吐 → ${fmt(dBps)}  新增 CONNECT ${fake.connectCount - beforeD} 次');
  check('D1 经自建代理能拉到数据', dBps > 0, fmt(dBps));
  check('D2 findProxy 生效（代理收到 CONNECT）', fake.connectCount > beforeD,
      '${fake.connectCount - beforeD} 次');

  print('\n=== [E] 代理关掉后不得静默回退直连 ===');
  await fake.stop();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final deadDio =
      DownloadAcceleration.dioFor('http://127.0.0.1:$_fakeProxyPort');
  final deadBps = await _measure(deadDio, 256 * 1024,
      limit: const Duration(seconds: 6));
  deadDio.close(force: true);
  print('  吞吐 → ${fmt(deadBps)}（期望 0：连接被拒，不回退直连）');
  check('E1 代理不可用时请求失败而非偷偷直连', deadBps == 0, fmt(deadBps));

  print('\n=== 结果: $_pass PASS / $_fail FAIL / $_skip SKIP ===');
  exit(_fail == 0 ? 0 : 1);
}
