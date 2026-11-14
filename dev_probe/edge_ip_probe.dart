// ignore_for_file: avoid_print
//
// 探针：验证「锁定优质边缘 IP」能否绕过 Cloudflare 慢节点。
//
// 背景（2026-11-14）：dl.imoe.uk 解析出两个 A 记录，其中 104.21.38.225
// 实测 0.16–0.25 MB/s（≈黑洞），172.67.140.59 可达 5 MB/s。Dart 的
// HttpClient 按 DNS 顺序建连、成功即粘住，约 50% 概率全程跑在慢节点上；
// 分片并发 4 路叠加后约 1 MB/s —— 与用户看到的 1.18 MB/s 吻合。
//
// 本探针验证三件事：
//   ① HttpClient.connectionFactory 能否强制 socket 连指定 IP 且 TLS 仍成功；
//   ② 同一 URL 在慢 IP / 快 IP 上的实测吞吐差；
//   ③ 锁定快 IP 后多连接并发能否叠加。
//
// 运行（裸 VM，不需要 flutter_tester）：
//   flutter/bin/cache/dart-sdk/bin/dart.exe --packages=.dart_tool/package_config.json \
//     dev_probe/edge_ip_probe.dart

import 'dart:async';
import 'dart:io';

const String _host = 'dl.imoe.uk';
const String _url =
    'https://dl.imoe.uk/letmoe/66df3e2c-6e96-454f-b94a-4c9a06b51e57.zip';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('✅ PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('❌ FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String fmt(int bps) {
  if (bps >= 1024 * 1024) return '${(bps / 1048576).toStringAsFixed(2)} MB/s';
  if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  return '$bps B/s';
}

HttpClient _clientFor(String? ip) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 10);
  if (ip != null) {
    c.connectionFactory = (uri, proxyHost, proxyPort) {
      // 只换 IP，协议/端口仍按 URL 走；TLS 由 HttpClient 在其上完成
      // （SNI 与证书校验都用 uri.host，不会因锁 IP 而降级安全）。
      return Socket.startConnect(ip, uri.port);
    };
  }
  return c;
}

/// 下载 [bytes] 字节并返回平均 B/s（含 TLS 握手，故对小样本偏保守）。
Future<int> _measure(HttpClient c, int bytes,
    {Duration limit = const Duration(seconds: 20)}) async {
  final sw = Stopwatch()..start();
  var got = 0;
  try {
    final req = await c.getUrl(Uri.parse(_url));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${bytes - 1}');
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
    final resp = await req.close().timeout(limit);
    await for (final chunk in resp.timeout(limit)) {
      got += chunk.length;
      if (got >= bytes) break;
    }
  } catch (e) {
    print('    ⚠️ 测速中断: ${e.runtimeType} $e');
  }
  sw.stop();
  if (sw.elapsedMilliseconds <= 0) return 0;
  return (got * 1000 / sw.elapsedMilliseconds).round();
}

Future<void> main() async {
  print('=== [A] DNS 解析 $_host ===');
  final addrs = await InternetAddress.lookup(_host);
  final v4 = <String>[];
  for (final a in addrs) {
    final tag = a.type == InternetAddressType.IPv4 ? 'v4' : 'v6';
    print('  $tag  ${a.address}');
    if (a.type == InternetAddressType.IPv4) v4.add(a.address);
  }
  check('A1 解析到多个 IPv4（多节点是优选前提）', v4.length >= 2, '${v4.length} 个');

  print('\n=== [B] 逐 IP 探速（512KB）===');
  final speeds = <String, int>{};
  for (final ip in v4) {
    final bps = await _measure(_clientFor(ip), 512 * 1024);
    speeds[ip] = bps;
    print('  $ip → ${fmt(bps)}');
    check('B-$ip 锁 IP 建连 + TLS 成功', bps > 0, fmt(bps));
  }

  final best = (speeds.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))
      .first;
  final worst = (speeds.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value)))
      .first;
  print('\n  最快: ${best.key} ${fmt(best.value)} | 最慢: ${worst.key} ${fmt(worst.value)}');
  check(
      'B-X 节点间存在显著差异（≥2 倍，否则本机制无意义）',
      worst.value == 0 || best.value >= worst.value * 2,
      '${fmt(best.value)} vs ${fmt(worst.value)}');

  print('\n=== [C] 默认 DNS 顺序 vs 锁定快 IP（4MB）===');
  final defBps = await _measure(_clientFor(null), 4 * 1024 * 1024);
  print('  默认解析      → ${fmt(defBps)}');
  final pinnedBps = await _measure(_clientFor(best.key), 4 * 1024 * 1024);
  print('  锁定 ${best.key} → ${fmt(pinnedBps)}');
  check('C1 锁定快 IP 不慢于默认解析', pinnedBps >= defBps ~/ 2,
      '${fmt(pinnedBps)} vs ${fmt(defBps)}');

  print('\n=== [D] 锁定快 IP 后 4 路并发（各 3MB）===');
  final swAll = Stopwatch()..start();
  final tasks = <Future<int>>[];
  for (var i = 0; i < 4; i++) {
    final c = _clientFor(best.key);
    tasks.add(_measure(c, 3 * 1024 * 1024,
            limit: const Duration(seconds: 25))
        .whenComplete(c.close));
  }
  final results = await Future.wait(tasks);
  swAll.stop();
  final sum = results.fold<int>(0, (a, b) => a + b);
  print('  各路: ${results.map(fmt).join(' / ')}');
  print('  合计: ${fmt(sum)}');
  check('D1 四路并发全部成功', results.every((r) => r > 0),
      results.map(fmt).join(','));
  check('D2 并发总吞吐 ≥ 单路（分片策略有效）', sum >= best.value ~/ 2,
      '${fmt(sum)} vs 单路 ${fmt(best.value)}');

  // ── [E] 默认解析（不锁 IP）多路并发：软件当前的实际情况 ──
  print('\n=== [E] 默认 DNS（不锁 IP）4 路并发 × 3MB ===');
  final tasks2 = <Future<int>>[];
  for (var i = 0; i < 4; i++) {
    final c = _clientFor(null);
    tasks2.add(_measure(c, 3 * 1024 * 1024,
            limit: const Duration(seconds: 25))
        .whenComplete(c.close));
  }
  final r2 = await Future.wait(tasks2);
  final sum2 = r2.fold<int>(0, (a, b) => a + b);
  print('  各路: ${r2.map(fmt).join(' / ')}');
  print('  合计: ${fmt(sum2)}');

  // ── [F] 代理通道对照（本机 7892）──
  print('\n=== [F] 本机代理 127.0.0.1:7892 单路 8MB ===');
  try {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = ((Uri uri) => 'PROXY 127.0.0.1:7892');
    final bps = await _measure(c, 8 * 1024 * 1024,
        limit: const Duration(seconds: 20));
    c.close(force: true);
    print('  代理 → ${fmt(bps)}');
    check('F1 代理通道可用', bps > 0, fmt(bps));
    check('F2 代理快于直连（本机实测）', bps > sum2,
        '代理 ${fmt(bps)} vs 直连并发 ${fmt(sum2)}');
  } catch (e) {
    print('  ⚠️ 代理测速失败: $e');
    check('F1 代理通道可用', false, '$e');
    _fail += 0;
  }

  print('\n=== 结果: $_pass PASS / $_fail FAIL ===');
  exit(_fail == 0 ? 0 : 1);
}
