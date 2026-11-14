/// OAuth 2.0 PKCE（RFC 7636）与授权地址构造。
///
/// ⛔ 刻意只依赖 `dart:convert` / `dart:math` / `package:crypto`：
/// 本文件要能在**裸 Dart VM** 里被探针跑真值断言
/// （`dev_probe/oauth_pkce_probe.dart`），因此不许 import Flutter。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// PKCE 三件套 + 授权地址构造。
///
/// 术语：`verifier` 只在本地保留，`challenge` 才会出现在浏览器地址里；
/// 换令牌时必须把 `verifier` 原样回传，否则站点会报 `invalid_grant`。
class OAuthPkce {
  OAuthPkce._();

  /// RFC 7636 §4.1 允许的字符集（unreserved），长度 43–128。
  static const String unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static final Random _random = Random.secure();

  /// 32 字节随机 → base64url（去 padding）= 43 字符，正好是规范下限。
  static String _randomToken(int bytes) {
    final List<int> buffer =
        List<int>.generate(bytes, (_) => _random.nextInt(256), growable: false);
    return base64Url.encode(buffer).replaceAll('=', '');
  }

  /// code_verifier（43 字符）。
  static String createVerifier() => _randomToken(32);

  /// OAuth `state`（防 CSRF，也用于回调分发时对账）。
  static String createState() => _randomToken(32);

  /// OIDC `nonce`（Hikarinagi 的授权端点会校验）。
  static String createNonce() => _randomToken(24);

  /// `code_challenge = BASE64URL(SHA256(ASCII(verifier)))`，S256 方法。
  static String challengeFor(String verifier) => base64Url
      .encode(sha256.convert(utf8.encode(verifier)).bytes)
      .replaceAll('=', '');

  /// verifier 是否合法（长度 + 字符集）。探针拿它挡「随手写个短串」的回归。
  static bool isValidVerifier(String verifier) {
    if (verifier.length < 43 || verifier.length > 128) return false;
    for (int i = 0; i < verifier.length; i++) {
      if (!unreserved.contains(verifier[i])) return false;
    }
    return true;
  }

  /// 拼授权地址。
  ///
  /// 用 [Uri.replace] 而不是手写字符串拼接：scope 里的空格要编码成 `+`
  /// （两家的真实地址就是这样），`&`/`=` 也必须转义，手拼迟早漏一个。
  static String buildAuthorizeUrl({
    required String endpoint,
    required Map<String, String> params,
  }) {
    final Uri base = Uri.parse(endpoint);
    final Map<String, String> merged = <String, String>{
      ...base.queryParameters,
      ...params,
    };
    return base.replace(queryParameters: merged).toString();
  }
}
