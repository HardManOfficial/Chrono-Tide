/// 本地回环回调服务器（OAuth 授权码的落点）。
///
/// 为什么必须自己监听：两家平台都只接受注册时绑定的
/// `http://127.0.0.1:<port>/<path>`，没有自定义协议、也不接受任意端口。
/// 所以流程是——先起本地服务，再开浏览器，用户点「同意」后浏览器 302 回来。
///
/// 🔴 端口是共享资源：ReinaManager 也用 23380。本服务只在**登录期间**占用，
/// 一旦拿到回调立刻关闭；绑不上时抛 [OAuthPortBusyException]，由上层给出
/// 「请关闭占用该端口的程序」的具体提示，而不是笼统的「登录失败」。
///
/// ⛔ 只依赖 dart:io / dart:async，不 import Flutter，方便单独推理。
library;

import 'dart:async';
import 'dart:io';

/// 回调端口已被别的进程占用。
class OAuthPortBusyException implements Exception {
  const OAuthPortBusyException(this.port);

  final int port;

  @override
  String toString() => '本地回调端口 $port 被占用';
}

/// 回调端口被占用时给用户的话。
///
/// 🔴 这不是理论情况：ReinaManager 常驻监听 23380 且与我们用的是同一批
/// 注册客户端，两家同时开就必然撞车。所以提示必须点名「关掉谁」，
/// 而不是「登录失败请重试」。
String describePortBusy(int port) => port == 0
    ? '登录需要在本地回环地址上监听一个端口，但系统没能分配（检查安全软件 / 防火墙）。'
    : '登录需要独占本地端口 $port，但它正被占用'
        '（ReinaManager 也常驻这个端口）。请关闭它后再点登录。';

/// 一次回调的结果（成功 / 站点拒绝 / 超时 / 取消都以它表达）。
class OAuthCallbackResult {
  const OAuthCallbackResult({
    this.code,
    this.error,
    this.errorDescription,
    this.state,
  });

  final String? code;
  final String? error;
  final String? errorDescription;

  /// 回调里带的 `state`，上层负责与本地生成的值比对（防 CSRF）。
  final String? state;

  /// 是否拿到了可用的授权码。
  bool get isSuccess =>
      (code ?? '').trim().isNotEmpty && (error ?? '').trim().isEmpty;

  /// 给用户看的一句话。
  String get friendlyMessage {
    final String err = (error ?? '').trim();
    if (err.isEmpty) return '未拿到授权码';
    switch (err) {
      case 'access_denied':
        return '你在授权页点了「拒绝」，未完成登录';
      case 'invalid_request':
        return '授权请求被拒绝（回调地址或 scope 与注册信息不一致）';
      case 'server_error':
      case 'temporarily_unavailable':
        return '站点暂时不可用，请稍后再试';
      case 'timeout':
        return '等了 5 分钟没等到浏览器回调，已取消';
      case 'cancelled':
        return '已取消登录';
      default:
        final String desc = (errorDescription ?? '').trim();
        return desc.isEmpty ? '授权失败：$err' : '授权失败：$err（$desc）';
    }
  }
}

/// 单次登录会话：绑定端口 → 等一个回调 → 关掉监听。
class OAuthLoopbackSession {
  OAuthLoopbackSession._(HttpServer server, this.callbackPath)
      : _server = server,
        port = server.port;

  /// **实际**监听到的端口。
  ///
  /// 🔴 `open(port: 0)` 时由内核分配，这里的值才是拼 `redirect_uri` 该用的那个。
  /// NextMoe 文档明说环回回调按 RFC 8252 §7.3 **忽略端口比对**，所以
  /// 自注册应用后可以「临时端口 + 端口无关匹配」跑，不必再跟 ReinaManager
  /// 抢 23380。（复用别人注册的 client 时仍必须用它注册的那个端口。）
  final int port;

  final String callbackPath;

  HttpServer? _server;
  final Completer<OAuthCallbackResult> _completer =
      Completer<OAuthCallbackResult>();
  bool _settled = false;

  /// 绑定端口并开始监听。`port: 0` = 让内核挑一个空闲端口。
  /// 绑不上抛 [OAuthPortBusyException]。
  static Future<OAuthLoopbackSession> open({
    required int port,
    required String callbackPath,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
    } on SocketException {
      throw OAuthPortBusyException(port);
    }
    final OAuthLoopbackSession session =
        OAuthLoopbackSession._(server, callbackPath);
    server.listen(
      session._handle,
      onError: (Object _) {},
      cancelOnError: false,
    );
    return session;
  }

  /// 等回调；超时返回 `error=timeout`（不抛异常，调用方统一按结果处理）。
  Future<OAuthCallbackResult> waitFor({Duration timeout = const Duration(minutes: 5)}) async {
    if (_completer.isCompleted) return _completer.future;
    try {
      return await _completer.future.timeout(timeout,
          onTimeout: () => const OAuthCallbackResult(error: 'timeout'));
    } finally {
      await close();
    }
  }

  /// 主动取消（用户点「取消登录」/ 页面销毁）。
  Future<void> cancel() async {
    _settle(const OAuthCallbackResult(error: 'cancelled'));
    await close();
  }

  /// 关掉监听。可以重复调用。
  Future<void> close() async {
    final HttpServer? server = _server;
    _server = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (_) {
      // 已经关了，忽略
    }
  }

  void _settle(OAuthCallbackResult result) {
    if (_settled) return;
    _settled = true;
    if (!_completer.isCompleted) _completer.complete(result);
  }

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    // 浏览器会顺手请求 /favicon.ico；只认注册路径，其它一律 404，
    // 免得把无关请求误判成「回调失败」。
    if (path != callbackPath) {
      request.response.statusCode = HttpStatus.notFound;
      await _respond(request.response, _page(
        ok: false,
        title: '404',
        detail: '这里不是登录回调地址。',
      ));
      return;
    }

    final Map<String, String> q = request.uri.queryParameters;
    final OAuthCallbackResult result = OAuthCallbackResult(
      code: q['code'],
      error: q['error'],
      errorDescription: q['error_description'],
      state: q['state'],
    );

    // 🔴 顺序必须是「先写响应，再 complete，再关监听」：
    // 先 complete 会让 waitFor 的 finally 立刻 close(force: true)，
    // 把还在飞的回调页掐断——浏览器显示连接重置，用户以为登录失败。
    await _respond(
      request.response,
      result.isSuccess
          ? _page(
              ok: true,
              title: '登录成功',
              detail: '已把授权结果交给 Chrono Tide，可以关闭这个页面了。',
            )
          : _page(
              ok: false,
              title: '登录未完成',
              detail: result.friendlyMessage,
            ),
    );
    _settle(result);
    await close();
  }

  Future<void> _respond(HttpResponse response, String html) async {
    try {
      response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      response.headers.set('Cache-Control', 'no-store');
      response.write(html);
      await response.close();
    } catch (_) {
      // 浏览器提前断开
    }
  }

  /// 回调结果页：跟随系统深浅色，避免用户在深色浏览器里被一片纯白晃到。
  static String _page({
    required bool ok,
    required String title,
    required String detail,
  }) {
    final String accent = ok ? '#3BA55D' : '#D9534F';
    final String mark = ok ? '✓' : '!';
    return '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$title · Chrono Tide</title>
<style>
  :root { color-scheme: light dark; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         font-family: "Segoe UI","Microsoft YaHei",system-ui,sans-serif;
         background:#f6f7f9; color:#1c1f23; }
  @media (prefers-color-scheme: dark) { body { background:#1a1c1f; color:#e8eaed; } }
  .card { max-width:420px; padding:36px 32px; text-align:center; }
  .mark { width:56px; height:56px; margin:0 auto 18px; border-radius:50%;
          display:flex; align-items:center; justify-content:center;
          font-size:30px; font-weight:700; color:#fff; background:$accent; }
  h1 { margin:0 0 10px; font-size:19px; font-weight:700; }
  p { margin:0; font-size:13px; line-height:1.7; opacity:.72; }
  .brand { margin-top:26px; font-size:11px; letter-spacing:.12em; opacity:.4; }
</style></head>
<body><div class="card">
  <div class="mark">$mark</div>
  <h1>$title</h1>
  <p>$detail</p>
  <div class="brand">CHRONO TIDE</div>
</div></body></html>''';
  }
}
