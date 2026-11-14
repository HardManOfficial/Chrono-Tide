// font_hook_ini_codec.dart
// CTFontHook 的 INI 生成 / 解析 与 manifest.ini 读写（L2 配置层的编解码部分）。
//
// 唯一耦合面 = INI 键集合，权威来源 `CTFontHook/docs/configuration.md`。
// 本文件是「我方语义模型 ⇄ CTFontHook 磁盘格式」的唯一转换点。
//
// 🔴 三条不可省的纪律（见实施报告 Phase 0 V1 实测）：
//   1. `PickerShowOnStartup` **恒为 0** 。默认值是 1，若不显式写 0，
//      游戏内字体面板每次启动都会弹出来挡住游戏
//      （CTFontHook `utils.cpp:29` / `:1109`，隐藏判定
//      `font_picker_lifecycle.cppinc:245`）。本文件把它硬编码，**不暴露给 UI**。
//   2. `FontNameW` 是**必需键**：缺失会让 `LoadConfig` 返回 false ⇒ 配置整体不生效。
//      「关闭替换」必须写 `EnableFontHook=0` + **保留字体名**，绝不清空 FontNameW
//      （空值会连带关闭两个开关，`utils.cpp:1066-1069`）。
//   3. 度量项「数值存在但开关为 0 时不应用」（`configuration.md:37`）⇒
//      未启用的项写 `EnableXxx=0`，而不是只写中性数值。

import 'dart:convert';
import '../models/game_font_override.dart';

class FontHookIniCodec {
  FontHookIniCodec._();

  static const String iniFileName = 'FontHook.ini';
  static const String backupDirName = '.CTFontHook';
  static const String manifestFileName = 'manifest.ini';
  static const String managedByValue = 'Chrono_Tide';
  static const int managedByVersion = 1;

  static const String sectionName = 'FontHook';
  static const String manifestSectionName = 'CTFontHook';

  static const int utf8Bom = 0xEF;
  static const int utf16LeBom0 = 0xFF;
  static const int utf16LeBom1 = 0xFE;

  /// 我方**管理**的 INI 键。重新生成时会覆盖这些键；
  /// 其余键（引擎专有项、伪装/映射等一期不呈现的项）**原样保留**。
  static const Set<String> managedKeys = {
    'FontNameW',
    'FontNameA',
    'EnableFontHook',
    'EnableFaceNameReplace',
    'EnableCharsetReplace',
    'ForcedCharset',
    'EnableFontHeightScale',
    'FontHeightScale1000',
    'EnableFontWidthScale',
    'FontWidthScale1000',
    'EnableFontCharSpacing',
    'FontCharSpacing',
    'EnableFontLineSpacing',
    'FontLineSpacing',
    'EnableFontWeight',
    'FontWeight',
    'EnableFontVerticalMetrics',
    'FontAscentPermille',
    'FontDescentPermille',
    // 兼容设置（原面板「调用 / 映射 / 转码」三组，见 configuration.md）
    'EnableCodepageSpoof',
    'SpoofFromCharset',
    'SpoofToCharset',
    'EnableTextSubstitution',
    'TextSubstitutionMode',
    'TextSubstitutionCodepage',
    'EnableCodepageRedirect',
    'CodepageRedirectFrom',
    'CodepageRedirectTo',
    'PickerShowOnStartup',
    'EnableDebugLog',
    'DebugTraceSampleLimit',
    'DebugPickerThreadLogLimit',
  };

  // ═══════════════════════════════════════════════════════════
  // UTF-16LE（dart:convert 无内置 codec）
  // ═══════════════════════════════════════════════════════════

  /// 按 `String.codeUnits`（UTF-16 码元）逐单元写 2 字节小端。
  /// 代理对天然按两个码元往返，不会丢字符。
  static List<int> utf16leEncode(String s) {
    final out = <int>[];
    for (final cu in s.codeUnits) {
      out.add(cu & 0xFF);
      out.add((cu >> 8) & 0xFF);
    }
    return out;
  }

  static String utf16leDecode(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  /// 去掉可能存在的 BOM（UTF-8 / UTF-16LE / UTF-16BE）后解码为字符串。
  static String decodeWithBomStripped(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == utf16LeBom0 && bytes[1] == utf16LeBom1) {
      return utf16leDecode(bytes.sublist(2));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      // UTF-16BE（CTFontHook 不产出，但读到也不应炸）
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ═══════════════════════════════════════════════════════════
  // INI 生成
  // ═══════════════════════════════════════════════════════════

  /// 生成 `FontHook.ini` 的**字节内容**：UTF-8 **带 BOM**、CRLF。
  ///
  /// [existingText] 非空时执行「读-改-写」：我方管理的键用 [cfg] 的值，
  /// 我**不**管理的键（引擎专有 / 高级项）原样保留在文件末尾。
  /// 这是「用户在游戏内面板做的高级设置被管理器点一次就抹掉」的唯一防线。
  static List<int> buildIniBytes(GameFontOverride cfg, {String? existingText}) {
    final body = buildIniText(cfg, existingText: existingText);
    return [utf8Bom, 0xBB, 0xBF, ...utf8.encode(body)];
  }

  static String buildIniText(GameFontOverride cfg, {String? existingText}) {
    final m = cfg.metrics;
    final e = m.enabled;
    final c = cfg.compat;

    String b(bool v) => v ? '1' : '0';

    final buf = StringBuffer();
    buf.writeln('[$sectionName]');
    // FontNameW 必需；此处可能是空串（仅在「尚未选字体」的中间态出现），
    // 调用方应避免在此状态下落盘（见 GameFontPatchService.writeConfig）。
    buf.writeln('FontNameW=${cfg.fontName}');
    buf.writeln('FontNameA=${cfg.fontName}');
    buf.writeln('EnableFontHook=${b(cfg.enabled)}');
    buf.writeln('EnableFaceNameReplace=${b(cfg.enabled)}');
    buf.writeln('EnableCharsetReplace=${b(cfg.charsetReplace)}');
    buf.writeln('ForcedCharset=${cfg.charset}');
    buf.writeln('EnableFontHeightScale=${b(e.height)}');
    buf.writeln('FontHeightScale1000=${m.heightScale}');
    buf.writeln('EnableFontWidthScale=${b(e.width)}');
    buf.writeln('FontWidthScale1000=${m.widthScale}');
    buf.writeln('EnableFontCharSpacing=${b(e.charSpacing)}');
    buf.writeln('FontCharSpacing=${m.charSpacing}');
    buf.writeln('EnableFontLineSpacing=${b(e.lineSpacing)}');
    buf.writeln('FontLineSpacing=${m.lineSpacing}');
    buf.writeln('EnableFontWeight=${b(e.weight)}');
    buf.writeln('FontWeight=${m.weight}');
    buf.writeln('EnableFontVerticalMetrics=${b(e.vertical)}');
    buf.writeln('FontAscentPermille=${m.ascentPermille}');
    buf.writeln('FontDescentPermille=${m.descentPermille}');
    // 兼容设置：三组互相独立，均受总开关约束（EnableFontHook=0 时整体不生效）
    buf.writeln('EnableCodepageSpoof=${b(c.spoof)}');
    buf.writeln('SpoofFromCharset=${c.spoofFrom}');
    buf.writeln('SpoofToCharset=${c.spoofTo}');
    buf.writeln('EnableTextSubstitution=${b(c.textSubstitution)}');
    buf.writeln('TextSubstitutionMode=${c.textSubstitutionMode}');
    buf.writeln('TextSubstitutionCodepage=${c.textSubstitutionCodepage}');
    buf.writeln('EnableCodepageRedirect=${b(c.codepageRedirect)}');
    buf.writeln('CodepageRedirectFrom=${c.codepageRedirectFrom}');
    buf.writeln('CodepageRedirectTo=${c.codepageRedirectTo}');
    // 🔴 恒为 0：不可省略、不可由 UI 改写（否则游戏内面板每次启动都弹）
    buf.writeln('PickerShowOnStartup=0');
    buf.writeln('EnableDebugLog=0');
    buf.writeln('DebugTraceSampleLimit=0');
    buf.writeln('DebugPickerThreadLogLimit=0');

    // 保留我方不管理的既有键
    if (existingText != null && existingText.isNotEmpty) {
      final preserved = <String>[];
      for (final entry in parseEntries(existingText).entries) {
        if (managedKeys.contains(entry.key)) continue;
        preserved.add('${entry.key}=${entry.value}');
      }
      if (preserved.isNotEmpty) {
        buf.writeln('');
        buf.writeln('; --- 以下为管理器不管理的既有键（原样保留）---');
        for (final l in preserved) {
          buf.writeln(l);
        }
      }
    }

    return buf.toString();
  }

  // ═══════════════════════════════════════════════════════════
  // INI 解析
  // ═══════════════════════════════════════════════════════════

  /// 解析为 `key → value` 的有序表。
  ///
  /// 口径与 CTFontHook 一致（`configuration.md:5-12`）：忽略空行、
  /// `;` / `#` 注释与节标题；重复键**取最后一个**。
  static Map<String, String> parseEntries(String text) {
    final out = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith(';') || trimmed.startsWith('#')) continue;
      if (trimmed.startsWith('[')) continue; // 节标题
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final key = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      if (key.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// 从 INI 文本解析出我方语义模型。
  ///
  /// 返回 null 表示「该文件不是我方能理解的 FontHook.ini」
  /// （缺 `FontNameW` 或值为空 —— 此时按未配置处理，**不覆盖**原文件，
  /// 避免抹掉用户设置）。
  static GameFontOverride? parseIni(String text) {
    final e = parseEntries(text);
    final fontName = e['FontNameW']?.trim() ?? '';
    if (fontName.isEmpty) return null;

    int flag(String k) => (e[k] == null || e[k] == '0') ? 0 : 1;
    int num_(String k, int fallback) {
      final v = e[k];
      if (v == null) return fallback;
      return int.tryParse(v) ?? fallback;
    }

    final enabled = flag('EnableFontHook') == 1;
    // TextSubstitutionMode 超出 0..2 会被 CTFontHook **归一化为 0**（不是钳到
    // 边界 2）—— `configuration.md` 解析验证矩阵。此处必须同样归 0，
    // 否则回读后会写回 2，把用户手改的 INI 悄悄变成「简>繁」。
    final rawTextSubMode = num_('TextSubstitutionMode', 0);
    final textSubMode =
        (rawTextSubMode >= 0 && rawTextSubMode <= 2) ? rawTextSubMode : 0;
    return GameFontOverride(
      enabled: enabled,
      fontName: fontName,
      charset: num_('ForcedCharset', FontCharset.defaultCharset),
      charsetReplace: flag('EnableCharsetReplace') == 1,
      metrics: FontMetrics(
        heightScale: num_('FontHeightScale1000', 1000),
        widthScale: num_('FontWidthScale1000', 1000),
        charSpacing: num_('FontCharSpacing', 0),
        lineSpacing: num_('FontLineSpacing', 0),
        weight: num_('FontWeight', 400),
        ascentPermille: num_('FontAscentPermille', 880),
        descentPermille: num_('FontDescentPermille', -120),
        enabled: FontMetricToggles(
          height: flag('EnableFontHeightScale') == 1,
          width: flag('EnableFontWidthScale') == 1,
          charSpacing: flag('EnableFontCharSpacing') == 1,
          lineSpacing: flag('EnableFontLineSpacing') == 1,
          weight: flag('EnableFontWeight') == 1,
          vertical: flag('EnableFontVerticalMetrics') == 1,
        ),
      ),
      compat: FontCompatSettings(
        spoof: flag('EnableCodepageSpoof') == 1,
        spoofFrom: num_('SpoofFromCharset', FontCompatPresets.spoofDefaultFrom),
        spoofTo: num_('SpoofToCharset', FontCompatPresets.spoofDefaultTo),
        textSubstitution: flag('EnableTextSubstitution') == 1,
        textSubstitutionMode: textSubMode,
        textSubstitutionCodepage: num_('TextSubstitutionCodepage', 932),
        codepageRedirect: flag('EnableCodepageRedirect') == 1,
        codepageRedirectFrom: num_('CodepageRedirectFrom', 936),
        codepageRedirectTo: num_('CodepageRedirectTo', 65001),
      ),
      // patchedAt / dllArch / managedByUs 不在 INI 里，由 manifest + game.json 提供
    );
  }

  // ═══════════════════════════════════════════════════════════
  // manifest.ini（.CTFontHook/manifest.ini，UTF-16LE + BOM）
  // ═══════════════════════════════════════════════════════════

  /// 生成 manifest 的**字节内容**（UTF-16LE + BOM，CRLF）。
  ///
  /// 前 4 个键与 CTFontHook 的 `WriteManifest`（`installer/main.cpp:261-278`）
  /// 逐字节一致；后 3 个是我方扩展键。由于 CTFontHook 的读取用
  /// **逐行前缀匹配**（`ReadManifestValue`，`installer/main.cpp:298-312`），
  /// 多出的键**完全不影响**原工具，这就是「互认」成立的前提。
  static List<int> buildManifestBytes({
    required String installedAt,
    required String dllArch, // '32bit' | '64bit'
    required bool hadWinmm,
    required bool hadIni,
    String managedBy = managedByValue,
    String dllSha256 = '',
  }) {
    final body = [
      '[$manifestSectionName]',
      'InstalledAt=$installedAt',
      'DllArch=$dllArch',
      'HadWinmm=${hadWinmm ? 1 : 0}',
      'HadIni=${hadIni ? 1 : 0}',
      'ManagedBy=$managedBy',
      'ManagedByVersion=$managedByVersion',
      if (dllSha256.isNotEmpty) 'DllSha256=$dllSha256',
    ].join('\r\n');
    return [utf16LeBom0, utf16LeBom1, ...utf16leEncode(body)];
  }

  /// CTFontHook 口径的「逐行前缀匹配」读取。抽出来是为了在测试里
  /// 与原工具的 `ReadManifestValue` 行为逐条对齐。
  static String? readManifestValue(String text, String key) {
    final prefix = '$key=';
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.startsWith(prefix)) {
        return line.substring(prefix.length);
      }
    }
    return null;
  }

  /// 解析 manifest 文本 → 我方识别的补丁状态。
  static ManifestInfo parseManifest(String text) {
    final arch = readManifestValue(text, 'DllArch') ?? '';
    final managedBy = readManifestValue(text, 'ManagedBy') ?? '';
    return ManifestInfo(
      installedAt: readManifestValue(text, 'InstalledAt') ?? '',
      dllArch: arch,
      hadWinmm: readManifestValue(text, 'HadWinmm') == '1',
      hadIni: readManifestValue(text, 'HadIni') == '1',
      managedByUs: managedBy == managedByValue,
      dllSha256: readManifestValue(text, 'DllSha256') ?? '',
    );
  }
}

/// `.CTFontHook/manifest.ini` 的解析结果。
class ManifestInfo {
  final String installedAt;
  final String dllArch; // '32bit' | '64bit' | ''
  final bool hadWinmm;
  final bool hadIni;
  final bool managedByUs;
  final String dllSha256;

  const ManifestInfo({
    required this.installedAt,
    required this.dllArch,
    required this.hadWinmm,
    required this.hadIni,
    required this.managedByUs,
    required this.dllSha256,
  });
}
