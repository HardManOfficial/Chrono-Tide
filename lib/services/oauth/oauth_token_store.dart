import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'oauth_token.dart';

/// OAuth 令牌持久化（按 provider 分键）。
///
/// 只存本机：这是用户自己的登录态，不上传、不进日志、不参与云备份。
/// 与 `BangumiTokenStore` / `KunCookieStore` 同一套策略：只负责
/// 持久化 + 进程内缓存，有效性由站点判定。
class OAuthTokenStore {
  OAuthTokenStore._();

  static const String _prefix = 'oauth_token_v1_';

  /// 在内存里留一份，供抓取层同步读取（Dio 构造是同步的，
  /// 不能等一次异步读盘）。启动时 [hydrateAll] 一次即可。
  static final Map<String, OAuthToken> _memory = <String, OAuthToken>{};

  static String _keyOf(String providerId) => '$_prefix$providerId';

  /// 启动时把已保存的令牌读进内存。
  static Future<void> hydrateAll(Iterable<String> providerIds) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      for (final String id in providerIds) {
        final OAuthToken? token = _decode(prefs.getString(_keyOf(id)));
        if (token == null) {
          _memory.remove(id);
        } else {
          _memory[id] = token;
        }
      }
    } catch (e) {
      debugPrint('[OAuthTokenStore] 加载失败: $e');
    }
  }

  /// 同步读内存副本（未登录 / 未 hydrate 时为 null）。
  static OAuthToken? peek(String providerId) => _memory[providerId];

  /// 异步读盘（设置页首次打开用）。
  static Future<OAuthToken?> load(String providerId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final OAuthToken? token = _decode(prefs.getString(_keyOf(providerId)));
      if (token == null) {
        _memory.remove(providerId);
      } else {
        _memory[providerId] = token;
      }
      return token;
    } catch (e) {
      debugPrint('[OAuthTokenStore] 读取失败: $e');
      return null;
    }
  }

  static Future<void> save(String providerId, OAuthToken token) async {
    _memory[providerId] = token;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyOf(providerId), jsonEncode(token.toJson()));
      debugPrint('[OAuthTokenStore] ✅ ${providerId} 令牌已保存'
          '（${token.accountName.isEmpty ? "匿名" : token.accountName}）');
    } catch (e) {
      debugPrint('[OAuthTokenStore] 保存失败: $e');
    }
  }

  static Future<void> clear(String providerId) async {
    _memory.remove(providerId);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyOf(providerId));
    } catch (e) {
      debugPrint('[OAuthTokenStore] 清除失败: $e');
    }
  }

  static OAuthToken? _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return OAuthToken.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 仅探针使用。
  @visibleForTesting
  static void resetForTest() => _memory.clear();

  /// 仅探针使用：直接写内存，不碰盘。
  @visibleForTesting
  static void seedForTest(String providerId, OAuthToken token) {
    _memory[providerId] = token;
  }
}
