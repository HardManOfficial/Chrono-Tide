/// OAuth 核心的纯 Dart 真值探针（裸 VM 直接跑，不需要 flutter_tester）。
///
///   dart --packages=.dart_tool/package_config.json dev_probe/oauth_pkce_probe.dart
///
/// 覆盖的是「改错了不会报错、只会在真机上莫名失败」的那部分：
/// PKCE 的 S256 算法、授权地址参数、回调端口/路径绑定、令牌过期与刷新、
/// userinfo 昵称取值顺序、令牌 JSON 往返。
library;

import 'dart:convert';

import 'package:chrono_tide/services/oauth/oauth_pkce.dart';
import 'package:chrono_tide/services/oauth/oauth_providers.dart';
import 'package:chrono_tide/services/oauth/oauth_token.dart';

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

void main() {
  print('=== A. PKCE ===');
  final String verifier = OAuthPkce.createVerifier();
  check('A1 verifier 长度 43', verifier.length == 43, '${verifier.length}');
  check('A2 verifier 字符集合法', OAuthPkce.isValidVerifier(verifier), verifier);
  check('A3 两次生成不重复', OAuthPkce.createVerifier() != verifier);
  check('A4 state 与 verifier 不同源', OAuthPkce.createState() != verifier);
  check('A5 state 长度 43', OAuthPkce.createState().length == 43);

  // RFC 7636 Appendix B 的官方测试向量：算法一改这里就会红。
  const String rfcVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
  const String rfcChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
  check('A6 RFC 7636 向量挑战值一致',
      OAuthPkce.challengeFor(rfcVerifier) == rfcChallenge,
      OAuthPkce.challengeFor(rfcVerifier));

  final String challenge = OAuthPkce.challengeFor(verifier);
  check('A7 challenge 是 43 位无 padding base64url',
      challenge.length == 43 && !challenge.contains('=') &&
          !challenge.contains('+') && !challenge.contains('/'),
      challenge);

  check('A8 拒绝过短的 verifier', !OAuthPkce.isValidVerifier('a' * 42));
  check('A9 拒绝非法字符', !OAuthPkce.isValidVerifier('${'a' * 42}!'));
  check('A10 接受 128 位上限', OAuthPkce.isValidVerifier('a' * 128));
  check('A11 拒绝 129 位', !OAuthPkce.isValidVerifier('a' * 129));

  print('=== B. 授权地址 ===');
  const OAuthProviderConfig nextmoe = kOAuthNextMoe;
  final String url = OAuthPkce.buildAuthorizeUrl(
    endpoint: nextmoe.authorizeEndpoint,
    params: <String, String>{
      'response_type': 'code',
      'client_id': nextmoe.clientId,
      'redirect_uri': nextmoe.redirectUri,
      'scope': nextmoe.scopes,
      'state': 'STATE123',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    },
  );
  final Uri parsed = Uri.parse(url);
  check('B1 授权端点正确',
      parsed.origin == 'https://account.nextmoe.com' &&
          parsed.path == '/api/v1/oauth/authorize',
      parsed.toString());
  check('B2 参数齐全', <String>[
    'response_type',
    'client_id',
    'redirect_uri',
    'scope',
    'state',
    'code_challenge',
    'code_challenge_method',
  ].every(parsed.queryParameters.containsKey));
  check('B3 scope 空格往返无损',
      parsed.queryParameters['scope'] == nextmoe.scopes,
      parsed.queryParameters['scope'] ?? 'null');
  check('B4 强制 S256', parsed.queryParameters['code_challenge_method'] == 'S256');
  check('B5 回调地址逐字符一致',
      parsed.queryParameters['redirect_uri'] ==
          'http://127.0.0.1:23380/callback/nextmoe',
      parsed.queryParameters['redirect_uri'] ?? 'null');

  final String hikariUrl = OAuthPkce.buildAuthorizeUrl(
    endpoint: kOAuthHikarinagi.authorizeEndpoint,
    params: <String, String>{
      'client_id': kOAuthHikarinagi.clientId,
      'redirect_uri': kOAuthHikarinagi.redirectUri,
      'prompt': 'consent',
    },
  );
  check('B6 Hikarinagi 回调路径正确',
      Uri.parse(hikariUrl).queryParameters['redirect_uri'] ==
          'http://127.0.0.1:23380/callback/hikarinagi',
      hikariUrl);
  check('B7 Hikarinagi 带 prompt=consent',
      Uri.parse(hikariUrl).queryParameters['prompt'] == 'consent');

  print('=== C. 平台配置一致性 ===');
  final Set<String> ids =
      kOAuthProviders.map((OAuthProviderConfig p) => p.id).toSet();
  check('C1 provider id 不重复', ids.length == kOAuthProviders.length);
  check('C2 两家共用 23380 端口但路径不同（否则回调会串）',
      kOAuthNextMoe.callbackPort == kOAuthHikarinagi.callbackPort &&
          kOAuthNextMoe.callbackPath != kOAuthHikarinagi.callbackPath);
  check('C3 回调只用环回地址（不能是 0.0.0.0）',
      kOAuthProviders.every((OAuthProviderConfig p) =>
          p.redirectUri.startsWith('http://127.0.0.1:')));
  check('C4 scope 都含 openid',
      kOAuthProviders.every((OAuthProviderConfig p) => p.scopes.contains('openid')));
  check('C5 Hikarinagi 不索取写权限（我们不同步状态）',
      !kOAuthHikarinagi.scopes.contains('status:write'),
      kOAuthHikarinagi.scopes);
  check('C6 Hikarinagi 保留 offline_access（要 refresh token）',
      kOAuthHikarinagi.scopes.contains('offline_access'));
  check('C7 按 id 可反查', oauthProviderOf('nextmoe')?.clientId == nextmoe.clientId);
  check('C8 未知 id 返回 null', oauthProviderOf('bangumi') == null);

  print('=== D. 令牌解析 ===');
  final DateTime now = DateTime(2026, 11, 13, 12, 0, 0);
  final OAuthToken? token = parseTokenResponse(<String, dynamic>{
    'access_token': '  at-abc  ',
    'refresh_token': 'rt-1',
    'expires_in': 3600,
    'scope': 'openid profile',
    'token_type': 'Bearer',
  }, now: now);
  check('D1 access_token 去空白', token?.accessToken == 'at-abc');
  check('D2 expires_in 转绝对时间',
      token?.expiresAt == now.add(const Duration(hours: 1)),
      '${token?.expiresAt}');
  check('D3 refresh_token 保留', token?.refreshToken == 'rt-1');
  check('D4 缺 access_token 返回 null',
      parseTokenResponse(<String, dynamic>{'error': 'invalid_grant'}) == null);
  check('D5 空串 access_token 返回 null',
      parseTokenResponse(<String, dynamic>{'access_token': '   '}) == null);
  final OAuthToken noExpiry =
      parseTokenResponse(<String, dynamic>{'access_token': 'x'})!;
  check('D6 没有 expires_in 时过期时间为 null', noExpiry.expiresAt == null);
  check('D7 过期时间未知时不主动刷新',
      !needsRefresh(noExpiry, now: now));

  print('=== E. 过期与刷新 ===');
  final OAuthToken fresh = token!.copyWith(expiresAt: now.add(const Duration(minutes: 10)));
  check('E1 还剩 10 分钟不需要刷新', !needsRefresh(fresh, now: now));
  final OAuthToken tight = token.copyWith(expiresAt: now.add(const Duration(seconds: 30)));
  check('E2 只剩 30 秒需要刷新', needsRefresh(tight, now: now));
  final OAuthToken boundary = token.copyWith(expiresAt: now.add(const Duration(seconds: 60)));
  check('E3 正好 60 秒边界要刷新（提前量含边界）',
      needsRefresh(boundary, now: now));
  final OAuthToken past = token.copyWith(expiresAt: now.subtract(const Duration(minutes: 5)));
  check('E4 已过期要刷新', needsRefresh(past, now: now));
  check('E5 已过期文案', past.expiryLabel == '已过期', past.expiryLabel);

  final OAuthToken rotated = token.copyWith(
    accessToken: 'at-new',
    refreshToken: null, // 站点没返回新的 → 保留旧的
    accountName: '汐',
  );
  check('E6 copyWith(refreshToken:null) 保留原 refresh_token',
      rotated.refreshToken == 'rt-1');
  check('E7 copyWith 保留昵称', rotated.accountName == '汐');

  print('=== F. userinfo 昵称 ===');
  check('F1 优先 name',
      parseUserInfoName(<String, dynamic>{'name': 'A', 'nickname': 'B'}) == 'A');
  check('F2 退回 nickname',
      parseUserInfoName(<String, dynamic>{'nickname': 'B', 'preferred_username': 'C'}) ==
          'B');
  check('F3 再退 preferred_username',
      parseUserInfoName(<String, dynamic>{'preferred_username': 'C'}) == 'C');
  check('F4 email 兜底',
      parseUserInfoName(<String, dynamic>{'email': 'a@b.c'}) == 'a@b.c');
  check('F5 全空返回空串', parseUserInfoName(<String, dynamic>{}) == '');
  check('F6 空白值不算命中',
      parseUserInfoName(<String, dynamic>{'name': '   ', 'nickname': ''}) == '');

  print('=== G. 持久化往返 ===');
  final String encoded = jsonEncode(rotated.toJson());
  final OAuthToken? decoded = OAuthToken.fromJson(jsonDecode(encoded));
  check('G1 JSON 往返令牌一致',
      decoded?.accessToken == rotated.accessToken &&
          decoded?.refreshToken == rotated.refreshToken &&
          decoded?.accountName == rotated.accountName &&
          decoded?.expiresAt == rotated.expiresAt);
  check('G2 脏数据返回 null',
      OAuthToken.fromJson(<String, dynamic>{'foo': 1}) == null);
  check('G3 非 Map 返回 null', OAuthToken.fromJson('oops') == null);

  print('');
  print('TOTAL  PASS=$_pass  FAIL=$_fail');
  if (_fail > 0) throw StateError('$_fail 条断言失败');
}
