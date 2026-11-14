/// 「游戏字体替换」的本机偏好（跨游戏、与本机绑定）。
///
/// 与其他偏好服务（[MotionPreference] 等）一样走 `shared_preferences`，
/// 经 `PortableSharedPreferencesStore` 重定向到
/// `data/prefs/shared_preferences.json` —— 便携版拷走整个目录即可带走。
///
/// 职责边界：
///   · 本类只存**跨游戏的全局默认**与**引导决策记录**，不存任何单游戏配置
///     （单游戏配置的唯一事实源是 `game.json.font_override`）。
///   · 「本机偏好」的定位决定了它不能进 `game.json`：
///     换机器/换用户时，单游戏配置该跟着游戏走，默认字体该跟着人走。
///
/// 加载策略：**懒加载**。不依赖 `main.dart` 引导（`lib/main.dart` 属稳定区），
/// 由第一个消费方（字体对话框 / 启动引导）调用 [ensureLoaded] 触发；
/// 未加载时所有 getter 返回默认值，不会抛异常。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/game_font_override.dart';
import 'win32_font_enumerator.dart';

class FontOverridePrefs extends ChangeNotifier {
  // ── SharedPreferences key ─────────────────────────────────────────────
  // 统一前缀 `font_override_`：从 key 本身就能看出真实作用域。
  static const String _kDefaultFontName = 'font_override_default_font_name';
  static const String _kDefaultCharset = 'font_override_default_charset';
  static const String _kDefaultCharsetReplace =
      'font_override_default_charset_replace';
  static const String _kDefaultMetrics = 'font_override_default_metrics';
  static const String _kGateAnsweredIds = 'font_override_gate_answered_ids';
  static const String _kGatePromptEnabled = 'font_override_gate_prompt_enabled';

  static FontOverridePrefs? _instance;
  static FontOverridePrefs get instance =>
      _instance ??= FontOverridePrefs._();
  FontOverridePrefs._();

  bool _loaded = false;
  bool get loaded => _loaded;

  String _defaultFontName = '';
  int _defaultCharset = FontCharset.defaultCharset;
  bool _defaultCharsetReplace = false;
  FontMetrics _defaultMetrics = FontMetrics.defaults;
  final Set<String> _gateAnsweredIds = <String>{};
  bool _gatePromptEnabled = true;

  // ── getter ────────────────────────────────────────────────────────────

  /// 批量安装 / 首次引导时使用的**统一字体族名**（空串 = 尚未选择）。
  ///
  /// 🔴 存的是**真族名**（如 `Microsoft YaHei`），不是显示名 ——
  /// 写进 `FontHook.ini` 的 `FontNameW` 必须是真族名，否则静默失效。
  String get defaultFontName => _defaultFontName;

  int get defaultCharset => _defaultCharset;

  bool get defaultCharsetReplace => _defaultCharsetReplace;

  FontMetrics get defaultMetrics => _defaultMetrics;

  /// 是否已配置「统一字体」（批量安装的必要条件）。
  bool get hasDefaultFont => _defaultFontName.trim().isNotEmpty;

  /// 启动引导总闸。用户关掉后不再在任何游戏上询问。
  bool get gatePromptEnabled => _gatePromptEnabled;

  /// 该游戏是否已就「是否安装改字体程序」做过决定（安装过 / 选过暂不）。
  ///
  /// 命中即**不再**在启动流程里询问。
  bool isGateAnswered(String gameId) => _gateAnsweredIds.contains(gameId);

  /// 依据当前偏好生成一份「可投放」的配置模板（尚未叠加单游戏覆盖）。
  ///
  /// [fontName] 为空 ⇒ 返回 null，调用方按「尚未选择统一字体」处理。
  GameFontOverride? buildDefaultOverride({String? fontName}) {
    final name = (fontName ?? _defaultFontName).trim();
    if (name.isEmpty) return null;
    return GameFontOverride(
      enabled: true,
      fontName: name,
      charset: _defaultCharset,
      charsetReplace: _defaultCharsetReplace,
      metrics: _defaultMetrics,
    );
  }

  /// 建议一个可用的默认字体族名。
  ///
  /// ⚠️ 这**不是**「统一字体」设置项 —— 面板改版后已经不向用户暴露全局字体
  /// 配置。这里只是让「刚装好字体器」的游戏立刻拥有一份能生效的配置：
  /// 空 `FontNameW` 会让 CTFontHook 的 `LoadConfig` 整体失败，比没配置更糟。
  ///
  /// 优先级：用户设过的默认字体 → `Microsoft YaHei` → 首个简中字体
  /// → 首个东亚字体 → 首个可用字体。全都枚举不到 ⇒ 返回空串，
  /// 调用方应提示用户手动选一个。
  static Future<String> suggestFontName() async {
    final prefs = FontOverridePrefs.instance;
    await prefs.ensureLoaded();
    if (prefs.hasDefaultFont) return prefs.defaultFontName.trim();
    try {
      final snap = await Win32FontEnumerator.enumerate();
      final usable = snap.usable;
      if (usable.isEmpty) return '';
      for (final f in usable) {
        if (f.name.toLowerCase() == 'microsoft yahei') return f.name;
      }
      for (final f in usable) {
        if (f.supportsSimplifiedChinese) return f.name;
      }
      for (final f in usable) {
        if (f.supportsEastAsian) return f.name;
      }
      return usable.first.name;
    } catch (_) {
      return '';
    }
  }

  // ── 加载 / 写入 ────────────────────────────────────────────────────────

  /// 从 `SharedPreferences` 读取。幂等：已加载过直接返回。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _defaultFontName = prefs.getString(_kDefaultFontName) ?? '';
      _defaultCharset =
          prefs.getInt(_kDefaultCharset) ?? FontCharset.defaultCharset;
      _defaultCharsetReplace = prefs.getBool(_kDefaultCharsetReplace) ?? false;
      _defaultMetrics = _decodeMetrics(prefs.getString(_kDefaultMetrics));
      _gatePromptEnabled = prefs.getBool(_kGatePromptEnabled) ?? true;

      final rawIds = prefs.getStringList(_kGateAnsweredIds) ?? const [];
      _gateAnsweredIds
        ..clear()
        ..addAll(rawIds.where((e) => e.isNotEmpty));
    } catch (e) {
      debugPrint('[FONT-PREF] 读取偏好失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  static FontMetrics _decodeMetrics(String? raw) {
    if (raw == null || raw.isEmpty) return FontMetrics.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return FontMetrics.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 损坏的偏好值只丢这一项，不拖垮整份偏好
    }
    return FontMetrics.defaults;
  }

  Future<void> setDefaultFontName(String value) async {
    if (_defaultFontName == value) return;
    _defaultFontName = value;
    notifyListeners();
    await _write((p) => p.setString(_kDefaultFontName, value));
  }

  Future<void> setDefaultCharset(int value) async {
    if (_defaultCharset == value) return;
    _defaultCharset = value;
    notifyListeners();
    await _write((p) => p.setInt(_kDefaultCharset, value));
  }

  Future<void> setDefaultCharsetReplace(bool value) async {
    if (_defaultCharsetReplace == value) return;
    _defaultCharsetReplace = value;
    notifyListeners();
    await _write((p) => p.setBool(_kDefaultCharsetReplace, value));
  }

  Future<void> setDefaultMetrics(FontMetrics value) async {
    _defaultMetrics = value;
    notifyListeners();
    await _write((p) => p.setString(_kDefaultMetrics, jsonEncode(value.toJson())));
  }

  Future<void> setGatePromptEnabled(bool value) async {
    if (_gatePromptEnabled == value) return;
    _gatePromptEnabled = value;
    notifyListeners();
    await _write((p) => p.setBool(_kGatePromptEnabled, value));
  }

  /// 记录某游戏已就引导做过决定。`gameId` 为空时忽略（无法稳定标识）。
  Future<void> markGateAnswered(String gameId) async {
    if (gameId.isEmpty || !_gateAnsweredIds.add(gameId)) return;
    notifyListeners();
    await _write((p) => p.setStringList(_kGateAnsweredIds, _gateAnsweredIds.toList()));
  }

  /// 撤销（供「再次询问」类入口使用）。
  Future<void> clearGateAnswered(String gameId) async {
    if (!_gateAnsweredIds.remove(gameId)) return;
    notifyListeners();
    await _write((p) => p.setStringList(_kGateAnsweredIds, _gateAnsweredIds.toList()));
  }

  Future<void> _write(Future<bool> Function(SharedPreferences) op) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await op(prefs);
    } catch (e) {
      // 写盘失败只丢持久化，不影响本次会话 —— 与 MotionPreference 同口径
      debugPrint('[FONT-PREF] 写入偏好失败: $e');
    }
  }

  // ── 测试辅助 ──────────────────────────────────────────────────────────

  @visibleForTesting
  static void resetForTest() => _instance = null;

  @visibleForTesting
  void seedForTest({
    String? defaultFontName,
    int? defaultCharset,
    FontMetrics? defaultMetrics,
    Iterable<String>? gateAnsweredIds,
    bool? gatePromptEnabled,
  }) {
    _loaded = true;
    if (defaultFontName != null) _defaultFontName = defaultFontName;
    if (defaultCharset != null) _defaultCharset = defaultCharset;
    if (defaultMetrics != null) _defaultMetrics = defaultMetrics;
    if (gateAnsweredIds != null) {
      _gateAnsweredIds
        ..clear()
        ..addAll(gateAnsweredIds);
    }
    if (gatePromptEnabled != null) _gatePromptEnabled = gatePromptEnabled;
    notifyListeners();
  }
}
