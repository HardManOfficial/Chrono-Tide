/// OAuth 令牌模型与解析（纯 Dart，可裸 VM 断言）。
///
/// ⛔ 不 import Flutter / dio：`dev_probe/oauth_pkce_probe.dart` 直接跑真值。
library;

/// 一次授权拿到的令牌。
class OAuthToken {
  const OAuthToken({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scope = '',
    this.accountName = '',
  });

  final String accessToken;

  /// 刷新令牌。**会轮换**：每次刷新返回新的 refresh_token，
  /// 不覆盖保存就会在下次刷新时变成「已失效」。
  final String? refreshToken;

  final DateTime? expiresAt;
  final String scope;

  /// 用户昵称（userinfo 拿到后回填；空串表示只拿到令牌）。
  final String accountName;

  OAuthToken copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? scope,
    String? accountName,
  }) {
    return OAuthToken(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      scope: scope ?? this.scope,
      accountName: accountName ?? this.accountName,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
        if (expiresAt != null) 'expires_at': expiresAt!.millisecondsSinceEpoch,
        'scope': scope,
        'account_name': accountName,
      };

  static OAuthToken? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? at = raw['access_token'];
    if (at is! String || at.trim().isEmpty) return null;
    final Object? exp = raw['expires_at'];
    final Object? name = raw['account_name'];
    final Object? scope = raw['scope'];
    return OAuthToken(
      accessToken: at.trim(),
      refreshToken: (raw['refresh_token'] is String &&
              (raw['refresh_token'] as String).trim().isNotEmpty)
          ? (raw['refresh_token'] as String).trim()
          : null,
      expiresAt: exp is int && exp > 0
          ? DateTime.fromMillisecondsSinceEpoch(exp)
          : null,
      scope: scope is String ? scope : '',
      accountName: name is String ? name : '',
    );
  }

  /// 有效期的可读描述（设置页用）。
  String get expiryLabel {
    final DateTime? exp = expiresAt;
    if (exp == null) return '有效期未知';
    final Duration left = exp.difference(DateTime.now());
    if (left.isNegative) return '已过期';
    if (left.inHours >= 1) return '${left.inHours} 小时内有效';
    return '${left.inMinutes.clamp(1, 59)} 分钟内有效';
  }
}

/// 该令牌是否「马上要过期、需要先刷新」。
///
/// 默认提前 60 秒刷新：站点签发 1 小时有效期，留 1 分钟余量，
/// 免得请求正好卡在过期边界上拿到 401。
bool needsRefresh(
  OAuthToken token, {
  DateTime? now,
  Duration skew = const Duration(seconds: 60),
}) {
  final DateTime? exp = token.expiresAt;
  if (exp == null) return false;
  final DateTime at = now ?? DateTime.now();
  return !exp.subtract(skew).isAfter(at);
}

/// 解析 token 端点返回（`expires_in` 是相对秒数 → 绝对时间）。
///
/// 返回 null 表示没有可用 access_token（站点报错或字段缺失）。
OAuthToken? parseTokenResponse(Map<String, dynamic> json, {DateTime? now}) {
  final Object? raw = json['access_token'];
  if (raw is! String || raw.trim().isEmpty) return null;
  final DateTime at = now ?? DateTime.now();
  final Object? expiresIn = json['expires_in'];
  final int seconds = expiresIn is num ? expiresIn.toInt() : 0;
  final Object? scope = json['scope'];
  final Object? refresh = json['refresh_token'];
  return OAuthToken(
    accessToken: raw.trim(),
    refreshToken: refresh is String && refresh.trim().isNotEmpty
        ? refresh.trim()
        : null,
    expiresAt: seconds > 0 ? at.add(Duration(seconds: seconds)) : null,
    scope: scope is String ? scope : '',
  );
}

/// 从 userinfo 响应里取显示名（各家字段名不一样，按优先级试）。
String parseUserInfoName(Map<String, dynamic> json) {
  for (final String key in <String>[
    'name',
    'nickname',
    'preferred_username',
    'display_name',
    'username',
    'email',
  ]) {
    final Object? v = json[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return '';
}
