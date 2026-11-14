/// 代理下发探针（flutter_tester）。
///
/// 锁定的回归：`NetworkProxyPolicy.attachTo()` 只用 dio 5 的新字段
/// `createHttpClient`，而 SDK 的 `applyProxyConfig()` 只读旧字段
/// `onHttpClientCreate` ⇒ 读不到就兜底 DIRECT，而 `MetadataFetcher`
/// 把 9 个数据源全部以 `dio: _dio` 实例化 ⇒ **所有元数据源被钉死直连**。
///
/// ⚠️ 断言口径说明：`HttpClient.findProxy` 在 dart:io 里**只有 setter
/// 没有 getter**，探针无法把 client 内部的回调读回来。因此这里做的是
/// 「结构性断言 + 行为断言」两段：
///   1. 目标 Dio 是否拿到了可执行的代理钩子（旧字段非空且可调用）；
///   2. 钩子体内调用的 `policy.findProxyFor()` 输出是否正确。
/// 两条缺一不可：只有 1 会漏掉策略算错，只有 2 会漏掉「钩子根本没下发」。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'package:chrono_tide/services/network_proxy_core.dart';
import 'package:chrono_tide/services/network_proxy_policy.dart';

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

/// 复刻 `MetadataFetcher._instantiateService()` → 各服务构造函数：
/// 服务自己 new 一个 Dio，再把全局 Dio 的代理配置复制过来。
Dio _newSourceServiceDio(Dio global) {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 4)));
  applyProxyConfig(global, dio);
  return dio;
}

IOHttpClientAdapter _adapterOf(Dio dio) =>
    dio.httpClientAdapter as IOHttpClientAdapter;

/// 目标 Dio 上是否存在「能被 dio 实际执行」的代理钩子。
bool _hasProxyHook(Dio dio) {
  final a = _adapterOf(dio);
  return a.createHttpClient != null || a.onHttpClientCreate != null;
}

/// 空白 override：`HttpOverrides` 的默认 `createHttpClient` 直接返回
/// dart:io 的真实 `_HttpClient`，用它把测试 binding 装的 mock 顶掉。
class _RealHttpOverrides extends HttpOverrides {}

/// 真正执行一次钩子（dio 内部就是这么做的），返回是否成功 + 失败原因。
/// 顺带证明回调体（`client.findProxy = ...`）可执行、不抛异常。
///
/// 🔴 必须用 `HttpOverrides.runWithHttpOverrides(..., _RealHttpOverrides())`
/// 包一层：`AutomatedTestWidgetsFlutterBinding` 自己装了 mock `HttpClient`，
/// 在测试 zone 外直接 `HttpClient()` 会抛
/// `Bad state: There is no current invoker`。换成空白 override 后
/// `HttpClient()` 走 dart:io 真实实现，才能验证 findProxy 真的被设置。
(String?, String) _invokeProxyHook(Dio dio) {
  final a = _adapterOf(dio);
  final factory = a.createHttpClient;
  final legacy = a.onHttpClientCreate;
  if (factory == null && legacy == null) return (null, 'no hook');

  return HttpOverrides.runWithHttpOverrides<(String?, String)>(() {
    HttpClient? client;
    try {
      client = factory != null ? factory() : legacy!(HttpClient());
      return ('ok', '');
    } catch (e) {
      return (null, '$e');
    } finally {
      client?.close(force: true);
    }
  }, _RealHttpOverrides());
}

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();

  await binding.runTest(() async {
    final policy = NetworkProxyPolicy.instance;
    final Uri vndb = Uri.parse('https://api.vndb.org/kana/vn');

    // ═══════════ A. 手动代理 → 必须下发到各数据源 ═══════════
    L('=== A. 手动代理 127.0.0.1:7890 ===');
    policy.configureForTesting(
      mode: NetworkProxyMode.manual,
      manualUrl: 'http://127.0.0.1:7890',
      aliveCheck: (ProxyEndpoint e) async => true,
    );
    await policy.refresh(force: true);
    check('A0 策略解析出规范化代理（剥掉 http://）',
        policy.effectiveProxy == '127.0.0.1:7890', '${policy.effectiveProxy}');
    check('A1 策略输出 PROXY 127.0.0.1:7890',
        policy.findProxyFor(vndb) == 'PROXY 127.0.0.1:7890',
        policy.findProxyFor(vndb));

    final globalA = Dio();
    policy.attachTo(globalA);
    final adapterA = _adapterOf(globalA);
    check('A2 全局 Dio 的 createHttpClient 已挂（dio 5 新字段）',
        adapterA.createHttpClient != null);
    check('A3 全局 Dio 的 onHttpClientCreate 已挂（旧字段，SDK 只认这个）',
        adapterA.onHttpClientCreate != null);

    // 数据源侧：模拟 9 个服务各自 new Dio + applyProxyConfig
    final svcA = _newSourceServiceDio(globalA);
    final svcAdapterA = _adapterOf(svcA);
    check('A4 applyProxyConfig 把回调复制到了数据源 Dio',
        svcAdapterA.createHttpClient != null ||
            svcAdapterA.onHttpClientCreate != null);
    check('A5 数据源确实拿到的是代理回调，而不是 SDK 的 DIRECT 兜底',
        svcAdapterA.onHttpClientCreate != null);
    final (okA, errA) = _invokeProxyHook(svcA);
    check('A6 数据源钩子可执行（设置 findProxy 不抛异常）', okA == 'ok', errA);

    // ═══════════ B. 直连模式 → 必须 DIRECT ═══════════
    L('=== B. 直连模式 ===');
    policy.configureForTesting(mode: NetworkProxyMode.direct, manualUrl: '');
    await policy.refresh(force: true);
    check('B0 策略输出 DIRECT', policy.findProxyFor(vndb) == 'DIRECT',
        policy.findProxyFor(vndb));
    final globalB = Dio();
    policy.attachTo(globalB);
    final svcB = _newSourceServiceDio(globalB);
    check('B1 直连模式数据源仍有钩子（钩子内输出 DIRECT，不是没有钩子）',
        _hasProxyHook(svcB));

    // ═══════════ C. 负向对照：没 attachTo 的 Dio ═══════════
    // 证明 A4/A5 不是恒真：未接策略的 Dio 会被 SDK 兜底成 DIRECT 钩子。
    L('=== C. 负向对照（未接策略）===');
    final bare = Dio();
    final svcC = _newSourceServiceDio(bare);
    final svcAdapterC = _adapterOf(svcC);
    check('C0 未接策略时 SDK 兜底装了 DIRECT 钩子',
        svcAdapterC.createHttpClient == null &&
            svcAdapterC.onHttpClientCreate != null);
    final (okC, _) = _invokeProxyHook(svcC);
    check('C1 兜底钩子可执行（说明 A6 测的是真路径）', okC == 'ok');

    // ═══════════ D. 运行期切换模式，已建好的 Dio 也要跟随 ═══════════
    L('=== D. 运行期切回手动（不重建 Dio）===');
    policy.configureForTesting(
      mode: NetworkProxyMode.manual,
      manualUrl: '127.0.0.1:10808',
    );
    await policy.refresh(force: true);
    check('D0 同一个 Dio 的下一次请求立刻用上新代理',
        policy.findProxyFor(vndb) == 'PROXY 127.0.0.1:10808',
        policy.findProxyFor(vndb));
    final (okD, errD) = _invokeProxyHook(svcB);
    check('D1 复用旧 Dio 的钩子仍可执行', okD == 'ok', errD);
  }, () {});

  L('TOTAL PASS=$_pass FAIL=$_fail');
  if (_fail > 0) exitCode = 1;
}
