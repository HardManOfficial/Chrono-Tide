/// 全局代理策略 · 纯 Dart 行为探针（裸 Dart VM，231 环境下可跑）。
/// 运行：dart dev_probe/proxy_policy_core_probe.dart
import 'dart:io';

import '../lib/services/network_proxy_core.dart';

int _pass = 0;
int _fail = 0;

void L(String m) => stdout.writeln(m);

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  L('  ${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : ' | $detail'}');
}

void main() {
  final uri = Uri.parse('https://api.example.com/v1/game');

  L('== 模式持久化 / 存量迁移 ==');
  check('system -> pref',
      proxyModeToPref(NetworkProxyMode.system) == kProxyModeSystem);
  check('manual -> pref',
      proxyModeToPref(NetworkProxyMode.manual) == kProxyModeManual);
  check('direct -> pref',
      proxyModeToPref(NetworkProxyMode.direct) == kProxyModeDirect);
  check('pref system -> system',
      proxyModeFromPref('system', hasManualUrl: true) ==
          NetworkProxyMode.system);
  check('pref manual -> manual',
      proxyModeFromPref('manual', hasManualUrl: false) ==
          NetworkProxyMode.manual);
  check('pref direct -> direct',
      proxyModeFromPref('direct', hasManualUrl: false) ==
          NetworkProxyMode.direct);
  check('存量：无模式 + 有手动 URL => 手动（零行为突变）',
      proxyModeFromPref(null, hasManualUrl: true) == NetworkProxyMode.manual);
  check('新用户：无模式 + 无 URL => 自动跟随系统代理',
      proxyModeFromPref(null, hasManualUrl: false) ==
          NetworkProxyMode.system);
  check('脏值兜底 => system',
      proxyModeFromPref('garbage', hasManualUrl: false) ==
          NetworkProxyMode.system);

  L('== 代理串规范化（旧实现 PROXY http://... 非法） ==');
  check('剥 http://', normalizeProxy('http://127.0.0.1:7890') ==
      '127.0.0.1:7890');
  check('剥 https://', normalizeProxy('https://proxy.example.com:8080') ==
      'proxy.example.com:8080');
  check('剥 socks5://', normalizeProxy('socks5://127.0.0.1:1080') ==
      '127.0.0.1:1080');
  check('剥尾部路径', normalizeProxy('http://127.0.0.1:7890/foo') ==
      '127.0.0.1:7890');
  check('裸 host:port 原样', normalizeProxy(' 127.0.0.1:7890 ') ==
      '127.0.0.1:7890');
  check('空白 -> null', normalizeProxy('   ') == null);
  check('null -> null', normalizeProxy(null) == null);

  L('== host:port 解析（TCP 存活验证用） ==');
  final ep = parseProxyHostPort('127.0.0.1:7890');
  check('host', ep?.host == '127.0.0.1');
  check('port', ep?.port == 7890);
  check('无端口 -> null', parseProxyHostPort('localhost') == null);
  check('非数字端口 -> null', parseProxyHostPort('h:abc') == null);
  check('端口 0 -> null', parseProxyHostPort('h:0') == null);
  check('端口越界 -> null', parseProxyHostPort('h:70000') == null);

  L('== findProxy 输出（三态） ==');
  check('system + 探测到代理 => PROXY',
      findProxyString(NetworkProxyMode.system, '127.0.0.1:7890', uri) ==
          'PROXY 127.0.0.1:7890');
  check('manual + URL => PROXY',
      findProxyString(NetworkProxyMode.manual, '127.0.0.1:7890', uri) ==
          'PROXY 127.0.0.1:7890');
  check('direct 压过 effective => DIRECT',
      findProxyString(NetworkProxyMode.direct, '127.0.0.1:7890', uri) ==
          'DIRECT');
  check('system + 无系统代理 => 回退环境变量（无变量时 DIRECT）',
      findProxyString(NetworkProxyMode.system, null, uri) == 'DIRECT');
  check('manual + 空 URL => 回退环境变量（无变量时 DIRECT）',
      findProxyString(NetworkProxyMode.manual, null, uri) == 'DIRECT');

  L('== 状态文案 ==');
  check('system 已探测',
      proxyStatusText(NetworkProxyMode.system, '127.0.0.1:7890')
          .contains('系统代理'));
  check('system 未探测',
      proxyStatusText(NetworkProxyMode.system, null).contains('未检测到'));
  check('manual 未填',
      proxyStatusText(NetworkProxyMode.manual, null).contains('未填写'));
  check('direct',
      proxyStatusText(NetworkProxyMode.direct, null).contains('强制直连'));

  L('== TTL 刷新判据（运行期跟随） ==');
  final now = DateTime(2026, 11, 12, 20);
  const ttl = Duration(seconds: 10);
  check('从未刷新 => 刷新', shouldRefreshProxy(null, now, ttl));
  check('9s 内 => 不刷新',
      !shouldRefreshProxy(now.subtract(const Duration(seconds: 9)), now, ttl));
  check('满 10s => 刷新',
      shouldRefreshProxy(now.subtract(const Duration(seconds: 10)), now, ttl));
  check('超过 10s => 刷新',
      shouldRefreshProxy(now.subtract(const Duration(seconds: 60)), now, ttl));
  check('时钟回拨 => 刷新',
      shouldRefreshProxy(now.add(const Duration(seconds: 30)), now, ttl));

  L('TOTAL PASS=$_pass FAIL=$_fail');
  if (_fail > 0) exitCode = 1;
}
