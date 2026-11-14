import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 下载加速通道：本机代理探测 + 下载专用 Dio 构造。
///
/// ## 为什么需要它（2026-11-14 本机实测）
///
/// 部分 CDN（如 letmoe 的 `dl.imoe.uk`，后面是 Cloudflare）对**直连**链路
/// 限速到 ~0.2 MB/s/连接：连续 8 次独立连接全部落在 0.10–0.23 MB/s，
/// 4 路并发合计仅 0.8–2.1 MB/s —— 与用户看到的「1.18 MB/s」吻合。
/// 同一时刻经本机代理：单连接 2.0–2.7 MB/s，4 路并发合计 **12.7 MB/s**。
///
/// 浏览器之所以快，是因为它走了本机代理；而软件下载默认跟随「系统代理」，
/// 系统代理关闭（注册表 `ProxyEnable=0`）时全程直连，与软件本身无关。
///
/// ## 设计边界
///
/// - **不改默认行为**：只有用户在确认弹窗里显式勾选时，本次下载才走代理；
/// - **只作用于本次下载**：不写全局策略、不碰元数据抓取/图片/更新等请求；
/// - **已有全局代理时不重复叠加**：由调用方先查
///   `NetworkProxyPolicy.instance.effectiveProxy` 再决定是否调用 [detect]
///   （本文件刻意不依赖 Flutter，便于用裸 VM 探针实测）。
class DownloadAcceleration {
  DownloadAcceleration._();

  /// 常见本地代理端口（Clash / v2ray / 加速器 / SSR 等系）。
  static const List<int> candidatePorts = <int>[
    7890, 7891, 7892, 7893, 7897, 7899, //
    1080, 1081, 2080, 8080,
    10808, 10809, 10801, 20171,
  ];

  static const Duration _connectTimeout = Duration(milliseconds: 600);
  static const Duration _verifyTimeout = Duration(seconds: 3);

  /// 最多验证几个候选端口：每个最坏 3s（验证超时），取 2 个把最坏等待
  /// 压在 6s 内 —— 这个探测发生在弹确认框之前，不能让用户干等。
  static const int _maxVerify = 2;

  static void _log(String m) => dev.log(m, name: 'DL-ACCEL');

  /// 探测一个**能真的把 [probeUrl] 拉下来**的本机代理。
  ///
  /// 返回 `http://127.0.0.1:<port>`；找不到 / 验证失败返回 null。
  /// 先并行探端口（≤600ms），再按端口顺序验证前 3 个。
  ///
  /// ⚠️ 调用方应先确认当前没有生效的全局代理，否则会变成双重代理。
  static Future<String?> detect({String? probeUrl}) async {
    final open = <int>[];
    await Future.wait(candidatePorts.map((p) async {
      try {
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          p,
          timeout: _connectTimeout,
        );
        s.destroy();
        open.add(p);
      } catch (_) {
        // 端口没开：正常情况，静默跳过
      }
    }));
    if (open.isEmpty) {
      _log('未发现监听中的本机代理端口');
      return null;
    }
    open.sort();
    _log('候选代理端口: $open');

    for (final p in open.take(_maxVerify)) {
      final url = 'http://127.0.0.1:$p';
      if (await _verify(url, probeUrl)) return url;
    }
    _log('候选端口均无法拉通目标地址');
    return null;
  }

  static Future<bool> _verify(String proxyUrl, String? probeUrl) async {
    final target = (probeUrl == null || probeUrl.isEmpty)
        ? 'https://www.cloudflare.com/cdn-cgi/trace'
        : probeUrl;
    final dio = dioFor(proxyUrl);
    try {
      // 用 `Range: bytes=0-0` 的 GET 而不是 HEAD：部分 CDN/代理组合对 HEAD
      // 返回 405/403，会误判成「代理不可用」；只取 1 字节，代价可忽略。
      final resp = await dio.get<ResponseBody>(
        target,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
          validateStatus: (c) => c != null && c < 500,
        ),
      ).timeout(_verifyTimeout);
      final code = resp.statusCode ?? 0;
      try {
        await resp.data?.stream.drain<void>().timeout(_verifyTimeout);
      } catch (_) {
        // 1 字节响应收尾失败不影响结论
      }
      _log('代理 $proxyUrl 验证 HTTP $code');
      return code == 200 || code == 206;
    } catch (e) {
      _log('代理 $proxyUrl 不可用: $e');
      return false;
    } finally {
      dio.close(force: true);
    }
  }

  /// 构造**只走 [proxyUrl]** 的 Dio，参数与 `DownloadCore` 的共享实例对齐。
  ///
  /// 调用方负责在用完后 `close(force: true)`，避免连接池悬挂。
  static Dio dioFor(String proxyUrl) {
    final endpoint = proxyUrl
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/+$'), '');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      // 与 DownloadCore 弱网修复后的值一致：45s 无数据判定连接半开。
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 30),
      receiveDataWhenStatusError: true,
      headers: {
        'User-Agent': 'ChronoTide/2.0',
        'Connection': 'keep-alive',
        'Keep-Alive': 'timeout=120, max=100',
      },
    ));

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..idleTimeout = const Duration(seconds: 120)
        ..findProxy = ((Uri _) => 'PROXY $endpoint'),
    );
    return dio;
  }
}
