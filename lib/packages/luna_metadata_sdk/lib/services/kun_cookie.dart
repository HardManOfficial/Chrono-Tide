import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 鲲 Galgame（kungal.com）登录态 Cookie 存储。
///
/// 为什么需要：鲲的论坛接口 `/api/**` 自 2026-11 起整站走登录门禁，
/// 未登录一律返回 `{"code":205,"message":"用户登录失效"}`（连搜索都拿不到），
/// 于是「元数据里鲲一条都搜不到」。站点本身用 Cookie 维持会话
/// （`maxAge: 604800`），所以把用户浏览器的 Cookie 透传给 `/api/*`
/// 即可恢复能力 —— 不需要注册 OAuth 客户端（鲲的 OAuth 回调地址固定在
/// `https://www.kungal.com/auth/callback`，第三方拿不到）。
///
/// 与 [TwoDFanCookieStore] 同一套策略：只负责持久化 + 进程内缓存，
/// 是否有效由站点决定；有效性校验放在 UI 层（真发一次搜索探测）。
class KunCookieStore {
  KunCookieStore._();

  static const String _prefsKey = 'kun_galgame_cookie';

  static String? _cache;
  static bool _loaded = false;

  /// 读取 Cookie；未配置返回 null。
  static Future<String?> load() async {
    if (_loaded) return _cache;
    try {
      final prefs = await SharedPreferences.getInstance();
      final String value = (prefs.getString(_prefsKey) ?? '').trim();
      _cache = value.isEmpty ? null : value;
    } catch (e) {
      debugPrint('[KunCookieStore] 加载失败: $e');
      _cache = null;
    }
    _loaded = true;
    return _cache;
  }

  /// 保存 Cookie（空串等同清除）。
  static Future<void> save(String cookie) async {
    final String value = cookie.trim();
    if (value.isEmpty) {
      await clear();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value);
      _cache = value;
      _loaded = true;
      debugPrint('[KunCookieStore] ✅ Cookie 已保存（${value.length} 字符）');
    } catch (e) {
      debugPrint('[KunCookieStore] 保存失败: $e');
    }
  }

  /// 清除 Cookie。
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (e) {
      debugPrint('[KunCookieStore] 清除失败: $e');
    }
    _cache = null;
    _loaded = true;
    debugPrint('[KunCookieStore] Cookie 已清除');
  }

  /// 仅探针使用：重置进程内缓存，让下一次 [load] 重新读盘。
  @visibleForTesting
  static void resetCacheForTest() {
    _cache = null;
    _loaded = false;
  }
}
