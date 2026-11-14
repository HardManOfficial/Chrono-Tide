import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 2DFan（2dfan.com 及其镜像）登录态 Cookie 存储。
///
/// 为什么需要：2DFan 是 HTML 抓取，未登录时部分条目/搜索页会退化为空壳，
/// 用户填了自己浏览器的 Cookie 后命中率明显提高。这里只负责持久化，
/// 是否有效由站点决定 —— 不做网络校验（多镜像 + 慢响应会把「镜像抽风」
/// 误报成「Cookie 失效」）。
///
/// 使用方式：
/// - [load]：读取（带进程内缓存，避免每个请求都打 prefs）
/// - [save] / [clear]：写入后同步更新缓存，下一条请求立即生效
class TwoDFanCookieStore {
  TwoDFanCookieStore._();

  static const String _prefsKey = 'two_dfan_cookie';

  static String? _cache;
  static bool _loaded = false;

  /// 读取 Cookie；未配置返回 null。
  ///
  /// 🔴 首次读盘后缓存到进程内：`TwoDFanService` 每次请求都会调本方法，
  /// 不缓存等于每个请求一次 prefs IO。
  static Future<String?> load() async {
    if (_loaded) return _cache;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = (prefs.getString(_prefsKey) ?? '').trim();
      _cache = value.isEmpty ? null : value;
    } catch (e) {
      debugPrint('[TwoDFanCookieStore] 加载失败: $e');
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
      debugPrint('[TwoDFanCookieStore] ✅ Cookie 已保存（${value.length} 字符）');
    } catch (e) {
      debugPrint('[TwoDFanCookieStore] 保存失败: $e');
    }
  }

  /// 清除 Cookie。
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (e) {
      debugPrint('[TwoDFanCookieStore] 清除失败: $e');
    }
    _cache = null;
    _loaded = true;
    debugPrint('[TwoDFanCookieStore] Cookie 已清除');
  }

  /// 仅探针使用：重置进程内缓存，让下一次 [load] 重新读盘。
  @visibleForTesting
  static void resetCacheForTest() {
    _cache = null;
    _loaded = false;
  }
}
