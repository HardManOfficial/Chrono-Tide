import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'network_proxy_policy.dart';
import 'oauth/oauth_loopback.dart';
import 'oauth/oauth_pkce.dart';
import 'oauth/oauth_providers.dart';
import 'oauth/oauth_token.dart';
import 'oauth/oauth_token_store.dart';
import 'website_bookmark_service.dart';

/// 平台账号「快捷登录」的编排层。
///
/// 流程（与 LunaBox / ReinaManager 一致）：
///   起本地回调服务 → 开系统浏览器到授权页 → 用户点「同意」
///   → 浏览器 302 回 `127.0.0.1:<port><path>?code=…`
///   → 用 PKCE verifier 换令牌 → 拉 userinfo 拿昵称 → 落盘
///
/// 🔴 关键约束（都实测过，别改）：
/// - **回调端口/路径与注册信息绑定**，换端口立刻 `15002 无效的回调地址`；
/// - 端口只在登录期间占用，拿到回调**立即关闭**（ReinaManager 也用 23380）；
/// - 换令牌必须带 `code_verifier`，否则 `invalid_grant`；
/// - refresh_token **会轮换**，刷新后必须原地覆盖保存；
/// - 所有请求走 [NetworkProxyPolicy]：Hikarinagi 直连被 reset，必须能走代理。
class MetadataLoginService extends ChangeNotifier {
  MetadataLoginService._();

  static final MetadataLoginService instance = MetadataLoginService._();

  /// 与两家站点的授权页等待时间对齐（ReinaManager 也是 5 分钟）。
  static const Duration browserTimeout = Duration(minutes: 5);

  Dio? _dio;
  OAuthLoopbackSession? _session;
  int _runId = 0;
  bool _hydrated = false;

  String? _activeProviderId;
  String? _statusText;
  bool _failed = false;

  /// 是否正在授权（任一平台）。
  bool get isBusy => _activeProviderId != null;

  /// 正在授权的平台 id。
  String? get activeProviderId => _activeProviderId;

  /// 进度/结果一句话（卡片直接显示）。
  String? get statusText => _statusText;

  /// [statusText] 是否是错误。
  bool get hasError => _failed;

  bool get isHydrated => _hydrated;

  Dio _client() {
    final Dio dio = _dio ??= Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    ));
    NetworkProxyPolicy.instance.attachTo(dio);
    return dio;
  }

  /// 读一次已保存的令牌（启动或首次进设置页时调）。
  Future<void> hydrate() async {
    await OAuthTokenStore.hydrateAll(
      kOAuthProviders.map((OAuthProviderConfig p) => p.id),
    );
    _hydrated = true;
    notifyListeners();
  }

  OAuthToken? tokenOf(String providerId) => OAuthTokenStore.peek(providerId);

  bool isLoggedIn(String providerId) {
    final OAuthToken? token = tokenOf(providerId);
    return token != null && token.accessToken.isNotEmpty;
  }

  String accountNameOf(String providerId) =>
      tokenOf(providerId)?.accountName ?? '';

  /// **同步**取一个「现在就能用」的令牌，供抓取层构造时注入。
  ///
  /// 濒临过期 / 已过期一律返回 null（回退内置凭据或应用密钥）——
  /// 抓取层是同步的，不能为了刷新一次令牌把整个请求链变成异步；
  /// 真要刷新走 [validAccessToken]，那是给能 await 的调用方用的。
  String? cachedAccessToken(String providerId) {
    final OAuthToken? token = tokenOf(providerId);
    if (token == null || token.accessToken.isEmpty) return null;
    if (needsRefresh(token)) return null;
    return token.accessToken;
  }

  /// 该平台当前可用的 access_token（必要时先刷新）；未登录返回 null。
  Future<String?> validAccessToken(String providerId) async {
    final OAuthToken? token = tokenOf(providerId);
    if (token == null) return null;
    if (!needsRefresh(token)) return token.accessToken;
    final OAuthProviderConfig? provider = oauthProviderOf(providerId);
    if (provider == null) return token.accessToken;
    final String? refreshed = await _refresh(provider, token);
    return refreshed ?? token.accessToken;
  }

  /// 开始一次登录。返回是否成功；失败原因看 [statusText]。
  Future<bool> login(OAuthProviderConfig provider) async {
    // 总开关关掉时直接拒绝（UI 也不会有入口，这里防别的调用方绕过）。
    if (!kOAuthQuickLoginEnabled) {
      debugPrint('[MetadataLogin] 快捷登录已禁用（kOAuthQuickLoginEnabled=false）');
      return false;
    }
    if (isBusy) return false;
    final int runId = ++_runId;

    _activeProviderId = provider.id;
    _failed = false;
    _statusText = '正在打开浏览器…';
    notifyListeners();

    OAuthLoopbackSession? session;
    try {
      session = await OAuthLoopbackSession.open(
        port: provider.callbackPort,
        callbackPath: provider.callbackPath,
      );
    } on OAuthPortBusyException {
      _finishLogin(
        runId,
        ok: false,
        message: describePortBusy(provider.callbackPort),
      );
      return false;
    }

    if (runId != _runId) {
      await session.close();
      return false;
    }
    _session = session;

    final String verifier = OAuthPkce.createVerifier();
    final String state = OAuthPkce.createState();
    final String challenge = OAuthPkce.challengeFor(verifier);
    // 🔴 回调地址必须用**实际监听端口**（`callbackPort == 0` 时端口由内核分配），
    // 并且换令牌那一步要与之逐字节相同，否则 `invalid_grant`。
    // 所以只在这里算一次，一路传下去。
    final String redirectUri = provider.redirectUriFor(session.port);
    final String url = OAuthPkce.buildAuthorizeUrl(
      endpoint: provider.authorizeEndpoint,
      params: <String, String>{
        'response_type': 'code',
        'client_id': provider.clientId,
        'redirect_uri': redirectUri,
        'scope': provider.scopes,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        if (provider.prompt != null) 'prompt': provider.prompt!,
      },
    );

    // 排查用：授权地址一律打出来。2026-11-13 那次「两家平台都说登录不支持」
    // 的根因就是地址被启动器截断，只有对比这条日志才看得出来。
    debugPrint('[MetadataLogin] 授权地址：$url');

    final bool opened = await WebsiteBookmarkService.openExternal(url);
    if (!opened) {
      await session.cancel();
      _finishLogin(runId, ok: false, message: '打不开系统浏览器，请检查默认浏览器设置');
      return false;
    }

    _statusText = '请在浏览器里完成 ${provider.siteName} 授权（5 分钟内有效）';
    notifyListeners();

    final OAuthCallbackResult callback = await session.waitFor(
      timeout: browserTimeout,
    );
    _session = null;

    if (runId != _runId) return false;

    if (!callback.isSuccess) {
      _finishLogin(runId, ok: false, message: callback.friendlyMessage);
      return false;
    }
    // state 对不上＝回调不是本次授权发出的（CSRF / 串了别家的登录）。
    if ((callback.state ?? '') != state) {
      _finishLogin(runId, ok: false, message: '授权响应校验失败（state 不匹配），请重试');
      return false;
    }

    _statusText = '正在兑换令牌…';
    notifyListeners();

    final OAuthToken? token = await _exchangeCode(
      provider: provider,
      code: callback.code!.trim(),
      verifier: verifier,
      redirectUri: redirectUri,
    );
    if (runId != _runId) return false;
    if (token == null) {
      _finishLogin(runId, ok: false, message: _lastError ?? '换取令牌失败');
      return false;
    }

    // 昵称只是「登录看起来成功了」的凭据，拿不到不影响可用性。
    final String name = await _fetchAccountName(provider, token.accessToken);
    final OAuthToken saved =
        token.copyWith(accountName: name.isEmpty ? provider.displayName : name);
    await OAuthTokenStore.save(provider.id, saved);

    _finishLogin(
      runId,
      ok: true,
      message: '已登录：${saved.accountName}（${saved.expiryLabel}）',
    );
    return true;
  }

  /// 取消当前授权（关掉本地监听）。
  Future<void> cancel() async {
    final OAuthLoopbackSession? session = _session;
    _session = null;
    _runId++;
    await session?.cancel();
    _activeProviderId = null;
    _failed = false;
    _statusText = '已取消登录';
    notifyListeners();
  }

  /// 退出登录（只清本机令牌，不动站点上的授权）。
  Future<void> logout(String providerId) async {
    await OAuthTokenStore.clear(providerId);
    _statusText = null;
    _failed = false;
    notifyListeners();
  }

  // ─────────────────────── 内部 ───────────────────────

  String? _lastError;

  void _finishLogin(int runId, {required bool ok, required String message}) {
    if (runId != _runId) return;
    _activeProviderId = null;
    _failed = !ok;
    _statusText = message;
    notifyListeners();
  }

  Future<OAuthToken?> _exchangeCode({
    required OAuthProviderConfig provider,
    required String code,
    required String verifier,
    required String redirectUri,
  }) async {
    try {
      final Response<dynamic> res = await _client().post<dynamic>(
        provider.tokenEndpoint,
        data: <String, String>{
          'grant_type': 'authorization_code',
          'client_id': provider.clientId,
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': verifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, dynamic>{'Accept': 'application/json'},
          validateStatus: (int? _) => true,
          responseType: ResponseType.json,
        ),
      );
      final Map<String, dynamic> body = _asJsonMap(res.data);
      if (res.statusCode != 200) {
        _lastError = _describeTokenError(body, res.statusCode);
        return null;
      }
      final OAuthToken? token = parseTokenResponse(body);
      if (token == null) {
        _lastError = _describeTokenError(body, res.statusCode);
      }
      return token;
    } on DioException catch (e) {
      _lastError = _describeDioError(e);
      return null;
    } catch (e) {
      _lastError = '换取令牌异常：$e';
      return null;
    }
  }

  Future<String?> _refresh(
    OAuthProviderConfig provider,
    OAuthToken token,
  ) async {
    final String? refreshToken = token.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return null;
    try {
      final Response<dynamic> res = await _client().post<dynamic>(
        provider.tokenEndpoint,
        data: <String, String>{
          'grant_type': 'refresh_token',
          'client_id': provider.clientId,
          'refresh_token': refreshToken,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, dynamic>{'Accept': 'application/json'},
          validateStatus: (int? _) => true,
          responseType: ResponseType.json,
        ),
      );
      final Map<String, dynamic> body = _asJsonMap(res.data);
      if (res.statusCode != 200) {
        debugPrint('[MetadataLogin] ⚠️ 刷新失败 ${res.statusCode}');
        return null;
      }
      final OAuthToken? next = parseTokenResponse(body);
      if (next == null) return null;
      // 🔴 刷新令牌会轮换：站点没返回新的就保留旧的。
      await OAuthTokenStore.save(
        provider.id,
        next.copyWith(
          refreshToken: next.refreshToken ?? refreshToken,
          accountName: token.accountName,
        ),
      );
      return next.accessToken;
    } catch (e) {
      debugPrint('[MetadataLogin] ⚠️ 刷新异常: $e');
      return null;
    }
  }

  Future<String> _fetchAccountName(
    OAuthProviderConfig provider,
    String accessToken,
  ) async {
    try {
      final Response<dynamic> res = await _client().get<dynamic>(
        provider.userInfoEndpoint,
        options: Options(
          headers: <String, dynamic>{
            'Authorization': 'Bearer $accessToken',
            'Accept': 'application/json',
          },
          validateStatus: (int? _) => true,
          responseType: ResponseType.json,
        ),
      );
      if (res.statusCode != 200) return '';
      final Map<String, dynamic> body = _asJsonMap(res.data);
      // 有些实现把载荷包在 data 里
      final Object? inner = body['data'];
      return parseUserInfoName(
          inner is Map ? _asJsonMap(inner) : body);
    } catch (_) {
      return '';
    }
  }

  Map<String, dynamic> _asJsonMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((Object? k, Object? v) =>
          MapEntry<String, dynamic>(k.toString(), v));
    }
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((Object? k, Object? v) =>
              MapEntry<String, dynamic>(k.toString(), v));
        }
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  /// token 端点报错时给一句人话，并保留站点原始 `error` 便于排查。
  String _describeTokenError(Map<String, dynamic> body, int? status) {
    final Object? error = body['error'];
    final Object? desc = body['error_description'] ?? body['message'];
    final String detail = <String>[
      if (error is String && error.isNotEmpty) error,
      if (desc is String && desc.isNotEmpty) desc,
    ].join('：');
    if (detail.isEmpty) return '换取令牌失败（HTTP $status）';
    if (error == 'invalid_grant') {
      return '授权码已失效（可能重复使用或超过 5 分钟），请重新登录';
    }
    if (error == 'invalid_client') {
      return '客户端校验失败（$detail），可能是注册信息已变更';
    }
    return '换取令牌失败：$detail';
  }

  String _describeDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '连接站点超时，请检查网络/代理后重试';
      case DioExceptionType.connectionError:
        return '连不上站点（可能被墙），请开启代理后重试';
      case DioExceptionType.badResponse:
        return '站点返回错误：HTTP ${e.response?.statusCode}';
      default:
        return '网络异常：${e.message ?? e.type.name}';
    }
  }
}
