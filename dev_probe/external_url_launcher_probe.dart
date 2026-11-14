/// 系统浏览器拉起探针（裸 VM：真起 HTTP 服务 + 真开一次浏览器）。
///
///   dart --packages=.dart_tool/package_config.json dev_probe/external_url_launcher_probe.dart
///
/// 唯一目的：钉死 2026-11-13 那次翻车——`cmd /c start "" <url>` 把 OAuth
/// 授权地址在第一个 `&` 处截断，两家平台分别报
/// 「ClientID/RedirectURI/State required」和「login is not supported」，
/// 看起来像站点不支持，其实是我们的启动器丢参数。
///
/// 所以核心断言不是「进程起来了」，而是**浏览器实际收到的 query 参数**：
/// 少一个就说明又被哪个 shell 吃了。跑的时候会真的弹出一次浏览器标签，
/// 它访问的就是本地临时服务（页面写 `probe ok`），关掉即可。
library;

import 'dart:async';
import 'dart:io';

import 'package:chrono_tide/core/external_url_launcher.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name${detail.isEmpty ? '' : '  <$detail>'}');
  }
}

Future<Uri?> _waitFor(Uri? Function() read, Duration limit) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < limit) {
    final Uri? uri = read();
    if (uri != null) return uri;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

const String _redirect = 'http://127.0.0.1:23380/callback/nextmoe';

Future<void> main() async {
  print('=== A. 无效输入不误开浏览器 ===');
  check('A1 空字符串返回 false', !await launchExternalUrl(''));
  check('A2 纯空白返回 false', !await launchExternalUrl('   '));

  print('=== B. 真浏览器：多参数 URL 必须一个不丢 ===');
  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final int port = server.port;
  print('（本地临时服务 127.0.0.1:$port，浏览器会打开一次）');

  Uri? received;
  server.listen((HttpRequest req) async {
    received ??= req.uri;
    req.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    req.response.write('<html><body>probe ok</body></html>');
    try {
      await req.response.close();
    } catch (_) {}
  });

  final String url = 'http://127.0.0.1:$port/probe?response_type=code'
      '&client_id=CLIENT-1'
      '&redirect_uri=${Uri.encodeComponent(_redirect)}'
      '&state=STATE-1'
      '&scope=openid%20profile'
      '&code_challenge=abc-_~xyz'
      '&code_challenge_method=S256';

  final bool opened = await launchExternalUrl(url);
  check('B1 拉起报告成功', opened);

  final Uri? got = await _waitFor(
    () => received,
    const Duration(seconds: 25),
  );
  check('B2 浏览器确实请求到了本地服务', got != null);
  if (got != null) {
    final Map<String, String> q = got.queryParameters;
    check('B3 路径未被截断', got.path == '/probe', got.path);
    check('B4 参数个数 = 7（截断时会只剩 1 个）', q.length == 7, '${q.length}');
    check('B5 response_type 到位', q['response_type'] == 'code');
    check('B6 client_id 到位', q['client_id'] == 'CLIENT-1', q['client_id'] ?? '');
    check('B7 redirect_uri 原样到位', q['redirect_uri'] == _redirect,
        q['redirect_uri'] ?? '');
    check('B8 state 到位', q['state'] == 'STATE-1', q['state'] ?? '');
    check('B9 scope 空格编码正确', q['scope'] == 'openid profile',
        q['scope'] ?? '');
    check('B10 code_challenge 字符集未被改写',
        q['code_challenge'] == 'abc-_~xyz', q['code_challenge'] ?? '');
    check('B11 code_challenge_method 到位',
        q['code_challenge_method'] == 'S256',
        q['code_challenge_method'] ?? '');
  }

  await server.close(force: true);

  print('=== C. 防回归：业务层不许再退回 cmd start ===');
  // 光测「现在能通」不够——真正的风险是下次有人图省事把
  // `cmd /c start` 写回去，那这个 bug 会静默复活（只是又变成「站点拒绝」）。
  final String src = await File(
    'lib/services/website_bookmark_service.dart',
  ).readAsString();
  check('C1 openExternal 里没有 cmd start', !src.contains("'/c', 'start'"));
  check('C2 openExternal 走 launchExternalUrl', src.contains('launchExternalUrl'));

  print('');
  print('TOTAL  PASS=$_pass  FAIL=$_fail');
  if (_fail > 0) throw StateError('$_fail 条断言失败');
}
