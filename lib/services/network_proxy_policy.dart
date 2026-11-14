import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'network_proxy_core.dart';
import 'system_proxy_detector.dart';

typedef SystemProxyProbe = Future<String?> Function({bool forceRefresh});
typedef ProxyAliveCheck = Future<bool> Function(ProxyEndpoint endpoint);

/// 全局网络代理策略 —— **唯一事实源**。
///
/// 取代此前散落在 `metadata_fetcher` / `company_logo_service` /
/// `game_title_logo_service` / `game_op_video_service` 的四份重复解析。
///
/// 三条硬约束：
/// 1. **运行期跟随**：`findProxyFor` 是同步回调（每个请求都会调），按 TTL
///    触发一次后台刷新；接了 `attachTo` 的 Dio 还会在请求前 `await refresh()`，
///    保证「开了系统代理后下一次请求就用上」，不必重启软件。
/// 2. **彻底全局**：`installGlobalOverrides()` 一次性给所有未显式设置
///    `findProxy` 的 `HttpClient`（图片、下载、更新、PB 等）装上同一策略。
///    显式设置了 `findProxy` 的调用方（如本地 OpenList 的 `DIRECT`）不受影响，
///    这是有意为之 —— 本地服务走代理反而连不上。
/// 3. **只读静态系统代理**：PAC / 自动发现 / 纯 TUN 读不到，属于已知边界。
class NetworkProxyPolicy {
  NetworkProxyPolicy._();

  static final NetworkProxyPolicy instance = NetworkProxyPolicy._();

  static const String prefModeKey = 'network_proxy_mode';
  // 复用旧 key：存量用户已填的手动代理不会丢，也无需数据迁移。
  static const String prefUrlKey = 'proxy_url';
  // 系统代理探测会起 `reg query`，按 10s 限流；空闲时零开销。
  static const Duration refreshTtl = Duration(seconds: 10);

  NetworkProxyMode _mode = NetworkProxyMode.system;
  String _manualUrl = '';
  String? _effectiveProxy;
  DateTime? _lastRefresh;
  bool _refreshing = false;
  bool _globalInstalled = false;
  bool _testMode = false;

  SystemProxyProbe _probe = SystemProxyDetector.detectProxy;
  ProxyAliveCheck _aliveCheck = _defaultAliveCheck;

  NetworkProxyMode get mode => _mode;
  String get manualUrl => _manualUrl;
  String? get effectiveProxy => _effectiveProxy;
  String get statusText => proxyStatusText(_mode, _effectiveProxy);

  /// 启动时调用一次：读偏好 → 解析一次代理 → 安装全局 HttpOverrides。
  /// 由 `MetadataFetcher.init()` 触发（🔴 `main.dart` 一行不改）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final url = (prefs.getString(prefUrlKey) ?? '').trim();
      _manualUrl = url;
      _mode = proxyModeFromPref(prefs.getString(prefModeKey),
          hasManualUrl: url.isNotEmpty);
    } catch (e) {
      debugPrint('[NetworkProxy] ⚠️ 读取代理偏好失败: $e');
    }
    await refresh(force: true);
    installGlobalOverrides();
  }

  /// 设置页保存。🔴 手动 URL 在**任何模式**下都保存，切回手动不用重填
  /// （对齐「此地址会保存但暂不生效」的语义）。
  Future<void> apply(NetworkProxyMode mode, String manualUrl) async {
    _mode = mode;
    _manualUrl = manualUrl.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefModeKey, proxyModeToPref(mode));
      if (_manualUrl.isEmpty) {
        await prefs.remove(prefUrlKey);
      } else {
        await prefs.setString(prefUrlKey, _manualUrl);
      }
    } catch (e) {
      debugPrint('[NetworkProxy] ⚠️ 保存代理偏好失败: $e');
    }
    await refresh(force: true);
  }

  /// 重新解析当前生效代理。TTL 内重复调用直接返回（避免每请求都跑 reg query）。
  Future<void> refresh({bool force = false}) async {
    if (_refreshing) return;
    if (!force &&
        !shouldRefreshProxy(_lastRefresh, DateTime.now(), refreshTtl)) {
      return;
    }
    _refreshing = true;
    _lastRefresh = DateTime.now();
    try {
      switch (_mode) {
        case NetworkProxyMode.manual:
          // 用户明确指定 ⇒ 不做存活验证，避免被静默放弃。
          _effectiveProxy = normalizeProxy(_manualUrl);
          break;
        case NetworkProxyMode.direct:
          _effectiveProxy = null;
          break;
        case NetworkProxyMode.system:
          final raw = await _probe(forceRefresh: force);
          final normalized = normalizeProxy(raw);
          if (normalized == null) {
            _effectiveProxy = null;
            break;
          }
          // 注册表可能残留死代理（Clash 关了没清）⇒ TCP 存活验证；
          // 从原来的 `MetadataFetcher._validateProxy` 搬过来，行为不变。
          final endpoint = parseProxyHostPort(normalized);
          final alive = endpoint != null && await _aliveCheck(endpoint);
          _effectiveProxy = alive ? normalized : null;
          break;
      }
    } catch (e) {
      debugPrint('[NetworkProxy] ⚠️ 解析代理失败: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// 同步：`HttpClient.findProxy` 回调。
  /// 顺带按 TTL 触发一次后台刷新 —— 有网络活动才刷新，空闲零开销。
  String findProxyFor(Uri uri) {
    _maybeRefresh();
    return findProxyString(_mode, _effectiveProxy, uri);
  }

  void _maybeRefresh() {
    if (_refreshing) return;
    if (!shouldRefreshProxy(_lastRefresh, DateTime.now(), refreshTtl)) return;
    unawaited(refresh());
  }

  /// 把策略接到一个 Dio：请求前刷新（当次生效）+ HttpClient 用统一 findProxy。
  void attachTo(Dio dio) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        await refresh();
        handler.next(options);
      },
    ));
    final adapter = dio.httpClientAdapter;
    // 🔴 dio 5 的 `onHttpClientCreate` 已废弃（6.0 移除），用新的
    // `createHttpClient`；idleTimeout 保持 3s，与旧 `onHttpClientCreate`
    // 写法创建的 client 完全一致。
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () => _newProxiedClient();
      // 🔴🔴 必须**同时**挂旧字段 `onHttpClientCreate`。
      //
      // SDK 的 `applyProxyConfig()`（`luna_metadata_sdk/lib/services/
      // metadata_base.dart:80-96`）只会从源 Dio 复制 `onHttpClientCreate`；
      // 读不到就兜底成 `client.findProxy = (uri) => 'DIRECT'`，而
      // `MetadataFetcher._instantiateService()` 把 9 个源**全部**以
      // `dio: _dio` 实例化 ⇒ 每个源都被钉死直连，全局 HttpOverrides
      // 也救不回来（先设代理、再被这个回调覆盖）。
      //
      // 症状：开了代理抓 VNDB / Hikarinagi / Kun / NextMoe 实际全走直连
      // ⇒「开了代理反而时好时坏」。挂上本回调后 applyProxyConfig 能拿到
      // 非空回调并复制过去，代理才真正下发到各数据源。
      //
      // 对 `_dio` 自身无副作用：dio 的 `_createHttpClient()` 优先用
      // `createHttpClient`（上面已设），不为 null 时不会调用本字段。
      // ignore: deprecated_member_use
      adapter.onHttpClientCreate = (HttpClient client) {
        client.findProxy = findProxyFor;
        return client;
      };
    }
  }

  HttpClient _newProxiedClient() {
    final client = HttpClient()
      ..idleTimeout = const Duration(seconds: 3)
      ..findProxy = findProxyFor;
    return client;
  }

  /// 一次性全局注入。保留并委托此前已存在的 `HttpOverrides`（若有人装过），
  /// 避免静默吞掉别人的行为；测试环境（`FLUTTER_TEST`）一律跳过，
  /// 否则会覆盖 flutter binding 的 mock HttpClient，让测试发出真实网络请求。
  void installGlobalOverrides() {
    if (_globalInstalled || _testMode) return;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    _globalInstalled = true;
    final previous = HttpOverrides.current;
    HttpOverrides.global = _ProxyHttpOverrides(this, previous);
  }

  /// 仅探针使用：注入假的探测/存活检查、直接设定状态，并禁止装全局钩子。
  void configureForTesting({
    SystemProxyProbe? probe,
    ProxyAliveCheck? aliveCheck,
    NetworkProxyMode? mode,
    String? manualUrl,
  }) {
    _testMode = true;
    if (probe != null) _probe = probe;
    if (aliveCheck != null) _aliveCheck = aliveCheck;
    if (mode != null) _mode = mode;
    if (manualUrl != null) _manualUrl = manualUrl;
  }

  static Future<bool> _defaultAliveCheck(ProxyEndpoint endpoint) async {
    try {
      final socket = await Socket.connect(endpoint.host, endpoint.port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}

class _ProxyHttpOverrides extends HttpOverrides {
  _ProxyHttpOverrides(this._policy, this._previous);

  final NetworkProxyPolicy _policy;
  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client =
        _previous?.createHttpClient(context) ?? super.createHttpClient(context);
    client.findProxy = _policy.findProxyFor;
    return client;
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}
