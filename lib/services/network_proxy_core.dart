import 'dart:io';

/// 全局网络代理策略的模式（唯一定义）。
///
/// - [system]：自动跟随 Windows 系统代理（读 IE 代理注册表）；探测不到时
///   回退环境变量代理。
/// - [manual]：只使用用户在设置页填写的代理 URL，不做存活验证。
/// - [direct]：强制直连，连环境变量代理也不使用。
///
/// 本文件是**纯 Dart**（只依赖 `dart:io`），刻意不 import `package:flutter/*`
/// 与 `shared_preferences` —— 231 环境下可用裸 Dart VM 跑行为探针验证策略，
/// 不必上 `gen_kernel_aot` + `flutter_tester`。
enum NetworkProxyMode { system, manual, direct }

const String kProxyModeSystem = 'system';
const String kProxyModeManual = 'manual';
const String kProxyModeDirect = 'direct';

/// 🔴 裸 Dart VM 探针里不能用 `Enum.name`（项目实测），故显式映射。
String proxyModeToPref(NetworkProxyMode mode) {
  switch (mode) {
    case NetworkProxyMode.system:
      return kProxyModeSystem;
    case NetworkProxyMode.manual:
      return kProxyModeManual;
    case NetworkProxyMode.direct:
      return kProxyModeDirect;
  }
}

/// 读偏好。🔴 存量兼容：从未写过 `network_proxy_mode`、但填过 `proxy_url`
/// 的老用户 ⇒ 直接判为「手动」，升级前后行为完全一致；新用户默认
/// 「自动跟随系统代理」。
NetworkProxyMode proxyModeFromPref(String? value,
    {required bool hasManualUrl}) {
  switch (value) {
    case kProxyModeManual:
      return NetworkProxyMode.manual;
    case kProxyModeDirect:
      return NetworkProxyMode.direct;
    case kProxyModeSystem:
      return NetworkProxyMode.system;
    default:
      return hasManualUrl
          ? NetworkProxyMode.manual
          : NetworkProxyMode.system;
  }
}

/// 把用户/系统给的代理地址规范化成 Dart `HttpClient.findProxy` 需要的
/// `host:port` 形式。
///
/// 🔴 旧实现把 `http://127.0.0.1:7890` 原样拼成
/// `PROXY http://127.0.0.1:7890` —— 这不是合法的 findProxy 语法，
/// 手动代理因此可能压根没生效。这里统一剥 scheme 与路径。
///
/// ⚠️ Dart 的 `PROXY` 指令只支持 HTTP CONNECT 代理。写了 `socks5://` 时
/// 剥掉 scheme 后仍按 HTTP 代理处理（与旧行为一致），UI 文案不承诺 SOCKS。
String? normalizeProxy(String? raw) {
  var v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  for (final scheme
      in const ['http://', 'https://', 'socks5://', 'socks://']) {
    if (v.toLowerCase().startsWith(scheme)) {
      v = v.substring(scheme.length);
      break;
    }
  }
  v = v.trim();
  final slash = v.indexOf('/');
  if (slash >= 0) v = v.substring(0, slash);
  v = v.trim();
  return v.isEmpty ? null : v;
}

/// `host:port` 的解析结果（不用 record，兼容裸 Dart VM 探针）。
class ProxyEndpoint {
  const ProxyEndpoint(this.host, this.port);

  final String host;
  final int port;
}

/// 从规范化后的代理串解析主机与端口，供 TCP 存活验证使用。
/// 无端口 / 端口非法一律返回 null（宁可不验，也不要拼出错误的 PROXY）。
ProxyEndpoint? parseProxyHostPort(String normalized) {
  final idx = normalized.lastIndexOf(':');
  if (idx <= 0 || idx == normalized.length - 1) return null;
  final host = normalized.substring(0, idx);
  final port = int.tryParse(normalized.substring(idx + 1));
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
  return ProxyEndpoint(host, port);
}

/// 同步生成 `HttpClient.findProxy` 的返回值。
///
/// [effective] 是已经过「策略解析 + 规范化 +（system 模式）存活验证」的结果。
/// system 模式且没探测到系统代理时回退环境变量，保持升级前的三级语义。
String findProxyString(NetworkProxyMode mode, String? effective, Uri uri) {
  if (mode == NetworkProxyMode.direct) return 'DIRECT';
  if (effective != null && effective.isNotEmpty) return 'PROXY $effective';
  return HttpClient.findProxyFromEnvironment(uri);
}

/// 设置页展示的「当前生效状态」。
String proxyStatusText(NetworkProxyMode mode, String? effective) {
  switch (mode) {
    case NetworkProxyMode.direct:
      return '当前：不使用代理（强制直连）';
    case NetworkProxyMode.manual:
      return effective == null
          ? '当前：手动代理未填写，请求将直连'
          : '当前生效：手动代理 $effective';
    case NetworkProxyMode.system:
      return effective == null
          ? '当前未检测到可用的系统代理，请求将直连或按环境变量'
          : '当前生效：系统代理 $effective';
  }
}

/// 是否该刷新缓存。时钟回拨也强制刷新，避免卡在「永不刷新」。
bool shouldRefreshProxy(DateTime? last, DateTime now, Duration ttl) {
  if (last == null) return true;
  final delta = now.difference(last);
  return delta >= ttl || delta < Duration.zero;
}
