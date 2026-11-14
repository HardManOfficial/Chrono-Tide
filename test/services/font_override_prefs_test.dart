import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/models/game_font_override.dart';
import 'package:chrono_tide/services/font_override_prefs.dart';

/// 「游戏字体替换」跨游戏本机偏好 —— 默认值 / 持久化往返 / 引导决策记录。
///
/// 覆盖范围说明（诚实标注）：
/// - 本文件只测偏好本身。**不测**「偏好真的落到 `FontHook.ini` / `game.json`」——
///   那属于 `GameFontPatchService` 的职责，已由 `game_font_patch_service_test.dart`
///   与 `font_hook_ini_codec_test.dart` 覆盖（用临时目录做真实文件 IO）。
/// - **不测**任何 UI 渲染 —— 由离线 widget 探针
///   `.workbuddy/probe_fonthook_ui/`（flutter_tester 真跑）覆盖。
///
/// 🔴 为什么偏好值得单独测：它是**懒加载**的（刻意不接 `main.dart` 稳定区），
/// 因此「未加载时 getter 必须返回默认值而不是抛异常」是一条真实契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── key 名与实现强耦合，测试里显式复写一遍，防止实现悄悄改名 ──────────
  const String kKeyFont = 'font_override_default_font_name';
  const String kKeyCharset = 'font_override_default_charset';
  const String kKeyCharsetReplace = 'font_override_default_charset_replace';
  const String kKeyMetrics = 'font_override_default_metrics';
  const String kKeyGateIds = 'font_override_gate_answered_ids';
  const String kKeyGatePrompt = 'font_override_gate_prompt_enabled';

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FontOverridePrefs.resetForTest();
  });

  tearDown(FontOverridePrefs.resetForTest);

  group('默认值（未加载时也不许抛）', () {
    test('未调用 ensureLoaded 时 getter 返回默认值', () {
      final prefs = FontOverridePrefs.instance;
      expect(prefs.loaded, isFalse);
      expect(prefs.defaultFontName, '');
      expect(prefs.hasDefaultFont, isFalse);
      expect(prefs.defaultCharset, FontCharset.defaultCharset);
      expect(prefs.defaultCharsetReplace, isFalse);
      expect(prefs.defaultMetrics.heightScale, 1000);
      expect(prefs.gatePromptEnabled, isTrue);
      expect(prefs.isGateAnswered('any'), isFalse);
      expect(prefs.buildDefaultOverride(), isNull);
    });

    test('ensureLoaded 幂等：重复调用不改变状态', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      expect(prefs.loaded, isTrue);
      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.ensureLoaded();
      expect(notified, 0, reason: '已加载过应直接 return，不发通知');
    });
  });

  group('持久化往返', () {
    test('设置统一字体后写盘，resetForTest + 重新加载可读回', () async {
      await FontOverridePrefs.instance.setDefaultFontName('Microsoft YaHei');
      await FontOverridePrefs.instance.setDefaultCharset(FontCharset.shiftJis);
      await FontOverridePrefs.instance.setDefaultCharsetReplace(true);

      final raw = await SharedPreferences.getInstance();
      expect(raw.getString(kKeyFont), 'Microsoft YaHei');
      expect(raw.getInt(kKeyCharset), FontCharset.shiftJis);
      expect(raw.getBool(kKeyCharsetReplace), isTrue);

      FontOverridePrefs.resetForTest();
      final fresh = FontOverridePrefs.instance;
      await fresh.ensureLoaded();
      expect(fresh.defaultFontName, 'Microsoft YaHei');
      expect(fresh.defaultCharset, FontCharset.shiftJis);
      expect(fresh.defaultCharsetReplace, isTrue);
    });

    test('prefs 已有值 → ensureLoaded 直接沿用', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kKeyFont: 'SimHei',
        kKeyGatePrompt: false,
      });
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      expect(prefs.defaultFontName, 'SimHei');
      expect(prefs.gatePromptEnabled, isFalse);
    });

    test('度量对象 JSON 往返', () async {
      final m = FontMetrics.defaults.copyWith(
        heightScale: 1120,
        lineSpacing: 6,
        enabled: FontMetricToggles.none.copyWith(lineSpacing: true),
      );
      await FontOverridePrefs.instance.setDefaultMetrics(m);

      FontOverridePrefs.resetForTest();
      final fresh = FontOverridePrefs.instance;
      await fresh.ensureLoaded();
      expect(fresh.defaultMetrics.heightScale, 1120);
      expect(fresh.defaultMetrics.lineSpacing, 6);
      expect(fresh.defaultMetrics.enabled.lineSpacing, isTrue);
      expect(fresh.defaultMetrics.enabled.height, isFalse);
    });

    test('度量 JSON 损坏 → 回落默认值，不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kKeyMetrics: '{不是合法 JSON',
      });
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      expect(prefs.defaultMetrics.heightScale, 1000);
      expect(prefs.defaultMetrics.weight, 400);
    });
  });

  group('buildDefaultOverride', () {
    test('无字体 ⇒ null；有字体 ⇒ enabled=true 且带当前字符集', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      expect(prefs.buildDefaultOverride(), isNull);

      await prefs.setDefaultFontName('SimSun');
      await prefs.setDefaultCharset(FontCharset.gb2312);
      final cfg = prefs.buildDefaultOverride();
      expect(cfg, isNotNull);
      expect(cfg!.enabled, isTrue);
      expect(cfg.fontName, 'SimSun');
      expect(cfg.charset, FontCharset.gb2312);
      expect(cfg.hasFont, isTrue);
    });

    test('显式传入字体名优先于偏好；空白串仍视为无效', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.setDefaultFontName('SimSun');
      expect(prefs.buildDefaultOverride(fontName: 'MS Gothic')!.fontName,
          'MS Gothic');
      expect(prefs.buildDefaultOverride(fontName: '   '), isNull);
    });

    test('字体名首尾空格会被裁掉（防写入非法 FontNameW）', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.setDefaultFontName('  SimHei  ');
      expect(prefs.buildDefaultOverride()!.fontName, 'SimHei');
    });
  });

  group('启动引导决策记录', () {
    test('mark / clear 往返，并落盘为字符串列表', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();

      await prefs.markGateAnswered('game-a');
      await prefs.markGateAnswered('game-b');
      expect(prefs.isGateAnswered('game-a'), isTrue);
      expect(prefs.isGateAnswered('game-b'), isTrue);
      expect(prefs.isGateAnswered('game-c'), isFalse);

      final raw = await SharedPreferences.getInstance();
      expect(raw.getStringList(kKeyGateIds)!.toSet(), {'game-a', 'game-b'});

      await prefs.clearGateAnswered('game-a');
      expect(prefs.isGateAnswered('game-a'), isFalse);
      expect(prefs.isGateAnswered('game-b'), isTrue);
    });

    test('空 gameId 被忽略（无法稳定标识，不应污染记录）', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      await prefs.markGateAnswered('');
      expect(prefs.isGateAnswered(''), isFalse);
      final raw = await SharedPreferences.getInstance();
      expect(raw.getStringList(kKeyGateIds), anyOf(isNull, isEmpty));
    });

    test('重复 mark 同一 id 不重复写盘（集合语义）', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      await prefs.markGateAnswered('dup');
      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.markGateAnswered('dup');
      expect(notified, 0);
    });

    test('persisted id 列表可被重新加载', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kKeyGateIds: <String>['x1', 'x2'],
      });
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      expect(prefs.isGateAnswered('x1'), isTrue);
      expect(prefs.isGateAnswered('x2'), isTrue);
    });
  });

  group('通知语义', () {
    test('setGatePromptEnabled 只在值真的变化时通知', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.ensureLoaded();
      var notified = 0;
      prefs.addListener(() => notified++);

      await prefs.setGatePromptEnabled(false);
      expect(notified, 1);
      await prefs.setGatePromptEnabled(false);
      expect(notified, 1);
      await prefs.setGatePromptEnabled(true);
      expect(notified, 2);
    });

    test('setDefaultFontName 同值不通知', () async {
      final prefs = FontOverridePrefs.instance;
      await prefs.setDefaultFontName('A');
      var notified = 0;
      prefs.addListener(() => notified++);
      await prefs.setDefaultFontName('A');
      expect(notified, 0);
      await prefs.setDefaultFontName('B');
      expect(notified, 1);
    });
  });

  group('seedForTest', () {
    test('绕过 prefs 注入状态且标记为已加载', () {
      final prefs = FontOverridePrefs.instance;
      prefs.seedForTest(
        defaultFontName: 'MS Gothic',
        gateAnsweredIds: ['g9'],
        gatePromptEnabled: false,
      );
      expect(prefs.loaded, isTrue);
      expect(prefs.defaultFontName, 'MS Gothic');
      expect(prefs.isGateAnswered('g9'), isTrue);
      expect(prefs.gatePromptEnabled, isFalse);
    });
  });
}
