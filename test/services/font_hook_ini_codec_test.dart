// font_hook_ini_codec_test.dart
// 「游戏字体替换」INI / manifest 编解码回归测试（2026-10-17）。
//
// 覆盖三条不可省的纪律 + 与原工具的互认口径：
//   · PickerShowOnStartup 恒为 0（Phase 0 V1：不写 0 则游戏内面板每次启动都弹）
//   · FontNameW 必需；关闭替换靠 EnableFontHook=0 而非清空字体名
//   · 度量项「开关为 0 则数值不应用」⇒ 未启用写 EnableXxx=0
//   · 读-改-写：我方不管理的既有键原样保留
//   · manifest 为 UTF-16LE + BOM，扩展键不破坏 CTFontHook 的前缀匹配读取
//
// 纯逻辑测试（不碰磁盘、不碰进程）。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_font_override.dart';
import 'package:chrono_tide/services/font_hook_ini_codec.dart';

void main() {
  group('UTF-16LE 手写 codec', () {
    test('ASCII / 中文 / 代理对 往返一致', () {
      for (final s in ['abc', '简体中文', '日本語のテスト', '𝔘𝔫𝔦𝔠𝔬𝔡𝔢', '']) {
        final bytes = FontHookIniCodec.utf16leEncode(s);
        expect(bytes.length, s.codeUnits.length * 2);
        expect(FontHookIniCodec.utf16leDecode(bytes), s);
      }
    });

    test('BOM 剥离：UTF-8 / UTF-16LE / 无 BOM / UTF-16BE 都能读', () {
      const text = 'FontNameW=Microsoft YaHei';
      expect(
          FontHookIniCodec.decodeWithBomStripped(
              [0xEF, 0xBB, 0xBF, ...text.codeUnits]),
          text);
      expect(
          FontHookIniCodec.decodeWithBomStripped(
              [0xFF, 0xFE, ...FontHookIniCodec.utf16leEncode(text)]),
          text);
      expect(FontHookIniCodec.decodeWithBomStripped(text.codeUnits), text);
      // UTF-16BE（CTFontHook 不产出，但读到不应炸）
      final be = <int>[0xFE, 0xFF];
      for (final cu in text.codeUnits) {
        be.add((cu >> 8) & 0xFF);
        be.add(cu & 0xFF);
      }
      expect(FontHookIniCodec.decodeWithBomStripped(be), text);
    });
  });

  group('INI 生成', () {
    test('🔴 PickerShowOnStartup 恒为 0（不可省）', () {
      final text = FontHookIniCodec.buildIniText(
          const GameFontOverride(fontName: 'SimSun'));
      final e = FontHookIniCodec.parseEntries(text);
      expect(e['PickerShowOnStartup'], '0');
      expect(text, contains('PickerShowOnStartup=0'));
    });

    test('必需键 FontNameW/FontNameA 均写入且同值', () {
      final text = FontHookIniCodec.buildIniText(
          const GameFontOverride(fontName: '思源黑体 CN'));
      final e = FontHookIniCodec.parseEntries(text);
      expect(e['FontNameW'], '思源黑体 CN');
      expect(e['FontNameA'], '思源黑体 CN');
    });

    test('带 BOM（EF BB BF）且为 UTF-8', () {
      final bytes = FontHookIniCodec.buildIniBytes(
          const GameFontOverride(fontName: 'SimSun'));
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    });

    test('关闭替换：EnableFontHook=0 但**保留**字体名（空 FontNameW 会让 LoadConfig 失败）', () {
      final text = FontHookIniCodec.buildIniText(const GameFontOverride(
          enabled: false, fontName: 'SimSun'));
      final e = FontHookIniCodec.parseEntries(text);
      expect(e['EnableFontHook'], '0');
      expect(e['EnableFaceNameReplace'], '0');
      expect(e['FontNameW'], 'SimSun'); // 🔴 不可清空
    });

    test('度量项：未启用的项写 EnableXxx=0（数值存在但开关为 0 不应用）', () {
      final text = FontHookIniCodec.buildIniText(GameFontOverride(
        fontName: 'SimSun',
        metrics: const FontMetrics(heightScale: 1100, weight: 700),
      ));
      final e = FontHookIniCodec.parseEntries(text);
      expect(e['EnableFontHeightScale'], '0'); // 值有但不启用
      expect(e['FontHeightScale1000'], '1100');
      expect(e['EnableFontWeight'], '0');
      expect(e['FontWeight'], '700');
      expect(e['EnableFontVerticalMetrics'], '0');
    });

    test('字符集：EnableCharsetReplace / ForcedCharset 正确落盘', () {
      final text = FontHookIniCodec.buildIniText(const GameFontOverride(
          fontName: 'SimSun',
          charset: FontCharset.shiftJis,
          charsetReplace: true));
      final e = FontHookIniCodec.parseEntries(text);
      expect(e['EnableCharsetReplace'], '1');
      expect(e['ForcedCharset'], '128');
    });
  });

  group('读-改-写：我方不管理的键必须原样保留', () {
    test('游戏内面板加的高级键（伪装/映射/引擎项）在重新生成后仍在', () {
      const existing = '''
[FontHook]
FontNameW=OldFont
EnableFontHook=1
PickerShowOnStartup=1
EnableCodepageSpoof=1
SpoofCodepage=932
EnableTextSubstitution=1
EngineKrkrFontMap=1
; 这是注释，不该被当成键
# 这也是注释
''';
      final text = FontHookIniCodec.buildIniText(
        const GameFontOverride(enabled: true, fontName: 'NewFont'),
        existingText: existing,
      );
      final e = FontHookIniCodec.parseEntries(text);
      // 我方键被更新
      expect(e['FontNameW'], 'NewFont');
      expect(e['PickerShowOnStartup'], '0');
      // 高级键保留
      expect(e['EnableCodepageSpoof'], '1');
      expect(e['SpoofCodepage'], '932');
      expect(e['EnableTextSubstitution'], '1');
      expect(e['EngineKrkrFontMap'], '1');
    });

    test('无既有内容时不追加空块', () {
      final text =
          FontHookIniCodec.buildIniText(const GameFontOverride(fontName: 'A'));
      expect(text.contains('以下为管理器不管理的既有键'), isFalse);
    });
  });

  group('INI 解析', () {
    test('完整往返：生成 → 解析 → 关键字段一致', () {
      final cfg = GameFontOverride(
        enabled: true,
        fontName: 'Microsoft YaHei',
        charset: FontCharset.gb2312,
        charsetReplace: true,
        metrics: const FontMetrics(
          heightScale: 1050,
          widthScale: 980,
          charSpacing: 2,
          lineSpacing: 3,
          weight: 600,
          ascentPermille: 900,
          descentPermille: -100,
          enabled: FontMetricToggles(
              height: true, width: false, charSpacing: true, weight: true),
        ),
      );
      final parsed = FontHookIniCodec.parseIni(
          FontHookIniCodec.buildIniText(cfg))!;
      expect(parsed.enabled, isTrue);
      expect(parsed.fontName, 'Microsoft YaHei');
      expect(parsed.charset, FontCharset.gb2312);
      expect(parsed.charsetReplace, isTrue);
      expect(parsed.metrics.heightScale, 1050);
      expect(parsed.metrics.widthScale, 980);
      expect(parsed.metrics.charSpacing, 2);
      expect(parsed.metrics.lineSpacing, 3);
      expect(parsed.metrics.weight, 600);
      expect(parsed.metrics.ascentPermille, 900);
      expect(parsed.metrics.descentPermille, -100);
      expect(parsed.metrics.enabled.height, isTrue);
      expect(parsed.metrics.enabled.width, isFalse);
      expect(parsed.metrics.enabled.charSpacing, isTrue);
      expect(parsed.metrics.enabled.lineSpacing, isFalse);
      expect(parsed.metrics.enabled.weight, isTrue);
      expect(parsed.metrics.enabled.vertical, isFalse);
    });

    test('缺 FontNameW / 空值 ⇒ 返回 null（调用方按「未配置」处理，不覆盖原文件）', () {
      expect(FontHookIniCodec.parseIni('[FontHook]\nEnableFontHook=1'), isNull);
      expect(FontHookIniCodec.parseIni('[FontHook]\nFontNameW=\n'), isNull);
      expect(FontHookIniCodec.parseIni(''), isNull);
    });

    test('解析器忽略注释/空行/节标题；重复键取最后一个（与原工具同口径）', () {
      final e = FontHookIniCodec.parseEntries('''
; comment
# comment
[FontHook]

FontNameW=A
FontNameW=B
''');
      expect(e['FontNameW'], 'B');
      expect(e.length, 1);
    });
  });

  group('manifest.ini（UTF-16LE + BOM）与互认', () {
    test('生成物为 UTF-16LE + BOM，前 4 键与原工具逐字节同格式', () {
      final bytes = FontHookIniCodec.buildManifestBytes(
        installedAt: '2026-10-17 00:30:00',
        dllArch: '64bit',
        hadWinmm: false,
        hadIni: true,
      );
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xFE);
      final text = FontHookIniCodec.utf16leDecode(bytes.sublist(2));
      expect(text, contains('[CTFontHook]'));
      expect(text, contains('InstalledAt=2026-10-17 00:30:00'));
      expect(text, contains('DllArch=64bit'));
      expect(text, contains('HadWinmm=0'));
      expect(text, contains('HadIni=1'));
    });

    test('我方扩展键不破坏「原工具口径」的前缀匹配读取（互认关键）', () {
      final bytes = FontHookIniCodec.buildManifestBytes(
        installedAt: '2026-10-17 00:30:00',
        dllArch: '32bit',
        hadWinmm: true,
        hadIni: false,
        dllSha256: 'deadbeef',
      );
      final text = FontHookIniCodec.utf16leDecode(bytes.sublist(2));
      // 复刻 CTFontHook 的 ReadManifestValue：逐行前缀匹配
      expect(FontHookIniCodec.readManifestValue(text, 'DllArch'), '32bit');
      expect(FontHookIniCodec.readManifestValue(text, 'HadWinmm'), '1');
      expect(FontHookIniCodec.readManifestValue(text, 'HadIni'), '0');
      // 我方扩展键
      expect(FontHookIniCodec.readManifestValue(text, 'ManagedBy'),
          FontHookIniCodec.managedByValue);
      expect(FontHookIniCodec.readManifestValue(text, 'DllSha256'), 'deadbeef');
    });

    test('parseManifest：我方装的 ⇒ managedByUs=true', () {
      final text = FontHookIniCodec.utf16leDecode(FontHookIniCodec
          .buildManifestBytes(
            installedAt: 't',
            dllArch: '64bit',
            hadWinmm: false,
            hadIni: false,
          )
          .sublist(2));
      final info = FontHookIniCodec.parseManifest(text);
      expect(info.managedByUs, isTrue);
      expect(info.dllArch, '64bit');
      expect(info.hadWinmm, isFalse);
    });

    test('parseManifest：原工具装的（无 ManagedBy）⇒ managedByUs=false', () {
      const upstream = '[CTFontHook]\r\n'
          'InstalledAt=2026-01-01 00:00:00\r\n'
          'DllArch=32bit\r\n'
          'HadWinmm=1\r\n'
          'HadIni=0\r\n';
      final info = FontHookIniCodec.parseManifest(upstream);
      expect(info.managedByUs, isFalse);
      expect(info.dllArch, '32bit');
      expect(info.hadWinmm, isTrue);
    });
  });

  group('模型 JSON 往返', () {
    test('GameFontOverride 全字段往返', () {
      final cfg = GameFontOverride(
        enabled: true,
        fontName: 'SimSun',
        charset: FontCharset.big5,
        charsetReplace: true,
        metrics: const FontMetrics(
            heightScale: 900,
            enabled: FontMetricToggles(vertical: true, weight: true)),
        patchedAt: '2026-10-17T00:00:00+08:00',
        dllArch: '32bit',
        managedByUs: true,
      );
      final back = GameFontOverride.fromJson(cfg.toJson());
      expect(back.enabled, isTrue);
      expect(back.fontName, 'SimSun');
      expect(back.charset, FontCharset.big5);
      expect(back.charsetReplace, isTrue);
      expect(back.metrics.heightScale, 900);
      expect(back.metrics.enabled.vertical, isTrue);
      expect(back.metrics.enabled.weight, isTrue);
      expect(back.patchedAt, '2026-10-17T00:00:00+08:00');
      expect(back.dllArch, '32bit');
      expect(back.managedByUs, isTrue);
    });

    test('null / 空 JSON ⇒ disabled', () {
      expect(GameFontOverride.fromJson(null).enabled, isFalse);
      expect(GameFontOverride.fromJson(const {}).enabled, isFalse);
      expect(GameFontOverride.fromJson(const {}).hasFont, isFalse);
    });

    test('缺字段时走默认值（老数据兼容）', () {
      final o = GameFontOverride.fromJson(const {'enabled': true});
      expect(o.fontName, '');
      expect(o.charset, FontCharset.defaultCharset);
      expect(o.metrics.heightScale, 1000);
      expect(o.metrics.weight, 400);
      expect(o.metrics.ascentPermille, 880);
      expect(o.metrics.descentPermille, -120);
      expect(o.metrics.enabled.anyEnabled, isFalse);
    });
  });

  // ═════════════════════════════════════════════════════════════════
  // 兼容设置（2026-10-17 改版新增：调用 / 映射 / 转码）
  // ═════════════════════════════════════════════════════════════════
  group('兼容设置九键', () {
    test('默认全关：写 EnableXxx=0，数值仍落在原工具默认值', () {
      final ini = FontHookIniCodec.buildIniText(
          GameFontOverride.disabled.copyWith(enabled: true, fontName: 'A'));
      String? v(String k) => _lineOf(ini, k);
      expect(v('EnableCodepageSpoof'), '0');
      expect(v('EnableTextSubstitution'), '0');
      expect(v('EnableCodepageRedirect'), '0');
      expect(v('SpoofFromCharset'), '134');
      expect(v('SpoofToCharset'), '128');
      expect(v('TextSubstitutionMode'), '0');
      expect(v('TextSubstitutionCodepage'), '932');
      expect(v('CodepageRedirectFrom'), '936');
      expect(v('CodepageRedirectTo'), '65001');
    });

    test('全开往返：九键逐一对齐', () {
      const cfg = GameFontOverride(
        enabled: true,
        fontName: 'MS Gothic',
        compat: FontCompatSettings(
          spoof: true,
          spoofFrom: FontCharset.big5,
          spoofTo: FontCharset.hangul,
          textSubstitution: true,
          textSubstitutionMode: 2,
          textSubstitutionCodepage: 936,
          codepageRedirect: true,
          codepageRedirectFrom: 932,
          codepageRedirectTo: 65001,
        ),
      );
      final back = FontHookIniCodec.parseIni(
          FontHookIniCodec.buildIniText(cfg))!;
      expect(back.compat.spoof, isTrue);
      expect(back.compat.spoofFrom, FontCharset.big5);
      expect(back.compat.spoofTo, FontCharset.hangul);
      expect(back.compat.textSubstitution, isTrue);
      expect(back.compat.textSubstitutionMode, 2);
      expect(back.compat.textSubstitutionCodepage, 936);
      expect(back.compat.codepageRedirect, isTrue);
      expect(back.compat.codepageRedirectFrom, 932);
      expect(back.compat.codepageRedirectTo, 65001);
    });

    test('🔴 越界 TextSubstitutionMode 归一化为 0（不是钳到边界 2）', () {
      // CTFontHook 的解析矩阵：0..2 之外一律按 0 处理。若这边钳到 2，
      // 回读后会写回 2，把用户手改的 INI 悄悄变成「简>繁」。
      final hi = FontHookIniCodec.parseIni(
          'EnableFontHook=1\nFontNameW=A\nTextSubstitutionMode=9\n')!;
      final lo = FontHookIniCodec.parseIni(
          'EnableFontHook=1\nFontNameW=A\nTextSubstitutionMode=-3\n')!;
      expect(hi.compat.textSubstitutionMode, 0);
      expect(lo.compat.textSubstitutionMode, 0);
    });

    test('九键全在 managedKeys 里（读-改-写不得误删）', () {
      for (final k in const [
        'EnableCodepageSpoof',
        'SpoofFromCharset',
        'SpoofToCharset',
        'EnableTextSubstitution',
        'TextSubstitutionMode',
        'TextSubstitutionCodepage',
        'EnableCodepageRedirect',
        'CodepageRedirectFrom',
        'CodepageRedirectTo',
      ]) {
        expect(FontHookIniCodec.managedKeys.contains(k), isTrue,
            reason: '$k 必须在 managedKeys 内');
      }
    });

    test('关闭替换时兼容键仍在（读-改-写不丢玩家调好的兼容项）', () {
      const cfg = GameFontOverride(
        enabled: false,
        fontName: 'A',
        compat: FontCompatSettings(spoof: true, textSubstitution: true),
      );
      final ini = FontHookIniCodec.buildIniText(cfg);
      expect(_lineOf(ini, 'EnableFontHook'), '0');
      expect(_lineOf(ini, 'EnableCodepageSpoof'), '1');
      expect(_lineOf(ini, 'EnableTextSubstitution'), '1');
    });

    test('预置表与 CTFontHook 源一致', () {
      expect(FontCompatPresets.spoofOptions.join(','), '128,134,136,1,129');
      expect(FontCompatPresets.textSubstitutionModeLabels.join('/'),
          '日繁/繁>简/简>繁');
      expect(FontCompatPresets.redirectPresets.length, 5);
      expect(FontCompatPresets.redirectPresetIndex(936, 65001), 1);
      expect(FontCompatPresets.redirectPresetIndex(0, 65001), 2);
      expect(FontCompatPresets.redirectPresetIndex(1, 2), -1);
    });

    test('compat JSON 往返 + 缺键回落默认', () {
      const cfg = FontCompatSettings(
          spoof: true, spoofTo: FontCharset.hangul, codepageRedirectTo: 932);
      final back = FontCompatSettings.fromJson(cfg.toJson());
      expect(back.spoof, isTrue);
      expect(back.spoofTo, FontCharset.hangul);
      expect(back.codepageRedirectTo, 932);

      final d = FontCompatSettings.fromJson(null);
      expect(d.spoof, isFalse);
      expect(d.spoofFrom, 134);
      expect(d.spoofTo, 128);
      expect(d.textSubstitutionCodepage, 932);
      expect(d.codepageRedirectFrom, 936);
      expect(d.codepageRedirectTo, 65001);
      expect(d.anyEnabled, isFalse);
    });
  });
}

/// 取 INI 文本里某键的值（最后一次出现）。
String? _lineOf(String ini, String key) {
  String? out;
  for (final l in ini.split('\n')) {
    final t = l.trim();
    if (t.startsWith('$key=')) out = t.substring(key.length + 1).trim();
  }
  return out;
}
