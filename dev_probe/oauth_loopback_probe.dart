/// 本地 OAuth 回调服务器的行为探针（裸 VM，真起真停）。
///
///   dart --packages=.dart_tool/package_config.json dev_probe/oauth_loopback_probe.dart
///
/// 这是「点登录 → 浏览器跳回来」这条链里唯一能在这台机器上自动验证的环节，
/// 所以覆盖得细一点：正常回调、无关路径不抢单、取消、超时、端口占用。
///
/// 端口按「先试真端口 23380，被占就顺延」处理：ReinaManager 常驻 23380，
/// 开发时未必关得掉，逻辑本身与端口无关，顺延不影响结论。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chrono_tide/services/oauth/oauth_loopback.dart';
import 'package:chrono_tide/services/oauth/oauth_providers.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name${detail.isEmpty ? "" : "  <$detail>"}');
  }
}

const String _path = '/callback/nextmoe';

int _port = 0;

Future<int> _pickPort() async {
  for (final int p in <int>[23380, 23381, 23382, 23383, 23390]) {
    try {
      final OAuthLoopbackSession s =
          await OAuthLoopbackSession.open(port: p, callbackPath: '/__probe');
      await s.close();
      return p;
    } on OAuthPortBusyException {
      continue;
    }
  }
  throw StateError('23380–23390 全被占用，无法验证');
}

Future<HttpClientResponse> _get(String url) async {
  final HttpClient client = HttpClient();
  final HttpClientRequest req = await client.getUrl(Uri.parse(url));
  final HttpClientResponse res = await req.close();
  return res;
}

/// 回调页声明的是 `charset=utf-8`，因此必须按 UTF-8 解码。
/// （用 SystemEncoding 会在中文 Windows 上按 GBK 解，中文全变乱码，
/// 这不是页面的问题，是探针读错了。）
Future<String> _body(HttpClientResponse res) =>
    res.transform(utf8.decoder).join();

Future<void> main() async {
  _port = await _pickPort();
  print('（本轮使用端口 $_port）');

  print('=== A. 正常回调 ===');
  final OAuthLoopbackSession s1 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  final Future<OAuthCallbackResult> waiting1 =
      s1.waitFor(timeout: const Duration(seconds: 8));
  final HttpClientResponse res =
      await _get('http://127.0.0.1:$_port$_path?code=CODE-1&state=STATE-1');
  final String html = await _body(res);
  final OAuthCallbackResult r1 = await waiting1;

  check('A1 HTTP 200', res.statusCode == 200, '${res.statusCode}');
  check('A2 拿到授权码', r1.code == 'CODE-1', r1.code ?? 'null');
  check('A3 state 原样带回', r1.state == 'STATE-1', r1.state ?? 'null');
  check('A4 判定为成功', r1.isSuccess);
  check('A5 回调页是 HTML 且中文正常',
      html.contains('登录成功') && html.contains('CHRONO TIDE'));
  check('A6 页头 no-store（避免浏览器缓存登录结果）',
      (res.headers.value('cache-control') ?? '').contains('no-store'));
  // 响应体必须完整：早前实现先 complete 再写响应，会被 close(force) 掐断
  check('A7 响应体完整（末尾有 </html>）', html.trimRight().endsWith('</html>'));

  print('=== B. 无关路径不抢单 ===');
  final OAuthLoopbackSession s2 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  final Future<OAuthCallbackResult> waiting2 =
      s2.waitFor(timeout: const Duration(seconds: 8));
  final HttpClientResponse favicon =
      await _get('http://127.0.0.1:$_port/favicon.ico');
  await _body(favicon);
  check('B1 /favicon.ico 返回 404', favicon.statusCode == 404, '${favicon.statusCode}');
  final HttpClientResponse real =
      await _get('http://127.0.0.1:$_port$_path?code=CODE-2&state=STATE-2');
  await _body(real);
  final OAuthCallbackResult r2 = await waiting2;
  check('B2 无关请求后仍能收到真正的回调', r2.code == 'CODE-2', r2.code ?? 'null');

  print('=== C. 站点拒绝 / 取消 / 超时 ===');
  final OAuthLoopbackSession s3 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  final Future<OAuthCallbackResult> waiting3 =
      s3.waitFor(timeout: const Duration(seconds: 8));
  final HttpClientResponse denied = await _get(
      'http://127.0.0.1:$_port$_path?error=access_denied&state=S3');
  final String deniedHtml = await _body(denied);
  final OAuthCallbackResult r3 = await waiting3;
  check('C1 error=access_denied 判为非成功', !r3.isSuccess);
  check('C2 话术说人话（不是裸错误码）',
      r3.friendlyMessage.contains('拒绝'), r3.friendlyMessage);
  check('C3 拒绝页也渲染出来', deniedHtml.contains('登录未完成'));

  final OAuthLoopbackSession s4 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  final Future<OAuthCallbackResult> waiting4 =
      s4.waitFor(timeout: const Duration(seconds: 8));
  await s4.cancel();
  final OAuthCallbackResult r4 = await waiting4;
  check('C4 取消返回 cancelled', r4.error == 'cancelled', r4.error ?? 'null');
  check('C5 取消话术', r4.friendlyMessage.contains('取消'), r4.friendlyMessage);

  final OAuthLoopbackSession s5 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  final OAuthCallbackResult r5 =
      await s5.waitFor(timeout: const Duration(milliseconds: 150));
  check('C6 超时返回 timeout', r5.error == 'timeout', r5.error ?? 'null');
  check('C7 超时话术提示 5 分钟', r5.friendlyMessage.contains('5 分钟'),
      r5.friendlyMessage);

  print('=== D. 端口占用 ===');
  final OAuthLoopbackSession s6 = await OAuthLoopbackSession.open(
      port: _port, callbackPath: '/callback/hikarinagi');
  bool busy = false;
  try {
    await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  } on OAuthPortBusyException {
    busy = true;
  }
  check('D1 同端口重复绑定抛 OAuthPortBusyException', busy);
  await s6.close();

  final String busyText = describePortBusy(23380);
  check('D2 占用提示点名端口号', busyText.contains('23380'), busyText);
  check('D3 占用提示点名 ReinaManager（用户知道关谁）',
      busyText.contains('ReinaManager'), busyText);

  print('=== E. 关闭后端口可复用 ===');
  final OAuthLoopbackSession s7 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  check('E1 关闭后能重新绑定', s7.port == _port);
  await s7.close();
  final OAuthLoopbackSession s8 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  check('E2 连续开关不泄漏端口', s8.port == _port);
  await s8.close();
  // 再用一次，确认没有「关一次就永久废掉」的残留
  final OAuthLoopbackSession s9 =
      await OAuthLoopbackSession.open(port: _port, callbackPath: _path);
  check('E3 第三次仍可绑定', s9.port == _port);
  await s9.close();

  print('=== F. 随机端口（自注册应用后 callbackPort=0）===');
  // NextMoe 文档：环回回调按 RFC 8252 §7.3 **忽略端口比对**。
  // 所以换成我们自己的 client 后可以让内核分配端口，
  // 不必再跟 ReinaManager 抢 23380。
  final OAuthLoopbackSession s10 = await OAuthLoopbackSession.open(
    port: 0,
    callbackPath: kOAuthNextMoe.callbackPath,
  );
  check('F1 内核分配了真实端口', s10.port > 1024, '${s10.port}');
  final String redirect = kOAuthNextMoe.redirectUriFor(s10.port);
  check(
    'F2 redirect_uri 用实际端口拼',
    redirect == 'http://127.0.0.1:${s10.port}/callback/nextmoe',
    redirect,
  );
  final Future<OAuthCallbackResult> waiting10 =
      s10.waitFor(timeout: const Duration(seconds: 8));
  final HttpClientResponse res10 =
      await _get('$redirect?code=CODE-F&state=STATE-F');
  await _body(res10);
  final OAuthCallbackResult r10 = await waiting10;
  check('F3 按该地址能收到回调', r10.code == 'CODE-F', r10.code ?? 'null');

  print('=== G. provider 配置自洽 ===');
  // 🔴 请求未在应用侧注册的 scope，授权时直接 15006（NextMoe 文档「常见错误」）。
  check('G1 NextMoe 不索取 folder:*（一期没做收藏夹同步）',
      !kOAuthNextMoe.scopes.contains('folder:'), kOAuthNextMoe.scopes);
  check('G2 NextMoe scope 就是 openid/profile/catalog:read',
      kOAuthNextMoe.scopes == 'openid profile catalog:read',
      kOAuthNextMoe.scopes);
  check('G3 两家回调都落在 127.0.0.1 环回（localhost 会被站点拒）',
      kOAuthProviders.every((OAuthProviderConfig p) =>
          p.redirectUriFor(1234).startsWith('http://127.0.0.1:1234/')));
  check('G4 固定端口时 redirectUri 与 redirectUriFor(port) 一致',
      kOAuthNextMoe.redirectUri ==
          kOAuthNextMoe.redirectUriFor(kOAuthNextMoe.callbackPort));

  print('');
  print('TOTAL  PASS=$_pass  FAIL=$_fail');
  if (_fail > 0) throw StateError('$_fail 条断言失败');
}
