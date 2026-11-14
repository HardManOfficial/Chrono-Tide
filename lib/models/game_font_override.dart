// game_font_override.dart
// 「游戏字体替换」的语义模型（L2 配置层）。
//
// 事实源原则（见 docs/DEV/features/game_font_override_implementation_plan.md §4.4）：
//   · 本模型 = 唯一事实源，持久化在 game.json 的 `font_override` 字段；
//   · <游戏目录>/FontHook.ini = **派生产物**，每次由 FontHookIniCodec 重新生成，
//     不存内容（不与之双份事实源）。
//
// 🔴 本字段**刻意不在** game_data_format.dart 的 `_overwritableFields` 内：
//    它是「用户累积出来的状态」，重新抓取元数据绝不允许清空。
//
// 与 CTFontHook 的 INI 键一一对应关系见 FontHookIniCodec。

/// 度量项开关。**每项由独立开关控制；数值存在但开关为 false 时不应用**
/// （CTFontHook `docs/configuration.md:37`）。
class FontMetricToggles {
  /// 字高缩放（对应 `EnableFontHeightScale`）
  final bool height;

  /// 字宽缩放（对应 `EnableFontWidthScale`）
  final bool width;

  /// 字间距（对应 `EnableFontCharSpacing`）
  final bool charSpacing;

  /// 行距（对应 `EnableFontLineSpacing`）
  final bool lineSpacing;

  /// 字重（对应 `EnableFontWeight`）
  final bool weight;

  /// 垂直度量（对应 `EnableFontVerticalMetrics`）
  final bool vertical;

  const FontMetricToggles({
    this.height = false,
    this.width = false,
    this.charSpacing = false,
    this.lineSpacing = false,
    this.weight = false,
    this.vertical = false,
  });

  static const FontMetricToggles none = FontMetricToggles();

  bool get anyEnabled =>
      height || width || charSpacing || lineSpacing || weight || vertical;

  FontMetricToggles copyWith({
    bool? height,
    bool? width,
    bool? charSpacing,
    bool? lineSpacing,
    bool? weight,
    bool? vertical,
  }) =>
      FontMetricToggles(
        height: height ?? this.height,
        width: width ?? this.width,
        charSpacing: charSpacing ?? this.charSpacing,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        weight: weight ?? this.weight,
        vertical: vertical ?? this.vertical,
      );

  factory FontMetricToggles.fromJson(Map<String, dynamic>? json) {
    if (json == null) return none;
    bool r(String k) => json[k] == true;
    return FontMetricToggles(
      height: r('height'),
      width: r('width'),
      charSpacing: r('char_spacing'),
      lineSpacing: r('line_spacing'),
      weight: r('weight'),
      vertical: r('vertical'),
    );
  }

  Map<String, dynamic> toJson() => {
        'height': height,
        'width': width,
        'char_spacing': charSpacing,
        'line_spacing': lineSpacing,
        'weight': weight,
        'vertical': vertical,
      };
}

/// 排版微调数值。与 CTFontHook 的默认值一致，便于「关掉开关」时写回中性值。
class FontMetrics {
  /// 字高缩放，千分比（1000 = 原样）。对应 `FontHeightScale1000`
  final int heightScale;

  /// 字宽缩放，千分比。对应 `FontWidthScale1000`
  final int widthScale;

  /// 字间距，像素。对应 `FontCharSpacing`
  final int charSpacing;

  /// 行距，像素。对应 `FontLineSpacing`
  final int lineSpacing;

  /// 字重（400 = 常规）。对应 `FontWeight`
  final int weight;

  /// 上沿占比，千分比。对应 `FontAscentPermille`
  final int ascentPermille;

  /// 下沿占比，千分比（负数）。对应 `FontDescentPermille`
  final int descentPermille;

  final FontMetricToggles enabled;

  const FontMetrics({
    this.heightScale = 1000,
    this.widthScale = 1000,
    this.charSpacing = 0,
    this.lineSpacing = 0,
    this.weight = 400,
    this.ascentPermille = 880,
    this.descentPermille = -120,
    this.enabled = FontMetricToggles.none,
  });

  static const FontMetrics defaults = FontMetrics();

  FontMetrics copyWith({
    int? heightScale,
    int? widthScale,
    int? charSpacing,
    int? lineSpacing,
    int? weight,
    int? ascentPermille,
    int? descentPermille,
    FontMetricToggles? enabled,
  }) =>
      FontMetrics(
        heightScale: heightScale ?? this.heightScale,
        widthScale: widthScale ?? this.widthScale,
        charSpacing: charSpacing ?? this.charSpacing,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        weight: weight ?? this.weight,
        ascentPermille: ascentPermille ?? this.ascentPermille,
        descentPermille: descentPermille ?? this.descentPermille,
        enabled: enabled ?? this.enabled,
      );

  factory FontMetrics.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    int i(String k, int fallback) =>
        (json[k] as num?)?.toInt() ?? fallback;
    return FontMetrics(
      heightScale: i('height_scale', 1000),
      widthScale: i('width_scale', 1000),
      charSpacing: i('char_spacing', 0),
      lineSpacing: i('line_spacing', 0),
      weight: i('weight', 400),
      ascentPermille: i('ascent_permille', 880),
      descentPermille: i('descent_permille', -120),
      enabled: FontMetricToggles.fromJson(
          json['enabled'] is Map ? Map<String, dynamic>.from(json['enabled'] as Map) : null),
    );
  }

  Map<String, dynamic> toJson() => {
        'height_scale': heightScale,
        'width_scale': widthScale,
        'char_spacing': charSpacing,
        'line_spacing': lineSpacing,
        'weight': weight,
        'ascent_permille': ascentPermille,
        'descent_permille': descentPermille,
        'enabled': enabled.toJson(),
      };
}

/// 字符集常量。值与 CTFontHook `docs/configuration.md:26` 一致。
class FontCharset {
  static const int defaultCharset = 1; // DEFAULT
  static const int shiftJis = 128; // 日文
  static const int hangul = 129; // 韩文
  static const int gb2312 = 134; // 简体中文
  static const int big5 = 136; // 繁体中文

  /// UI 用药丸清单（顺序即展示顺序）。
  static const List<int> uiOrder = [
    defaultCharset,
    gb2312,
    shiftJis,
    big5,
    hangul,
  ];

  static String label(int v) {
    switch (v) {
      case shiftJis:
        return '日文';
      case hangul:
        return '韩文';
      case gb2312:
        return '简中';
      case big5:
        return '繁中';
      case defaultCharset:
      default:
        return '默认';
    }
  }

  /// 与 CTFontHook 字体选择器**完全一致**的措辞（`g_charsets` 表）。
  ///
  /// 单游戏面板刻意用这套词而不是 [label]：玩家在原工具里看到的是
  /// 「中文 / 繁体」，换到管理器里不该变成「简中 / 繁中」。
  static String pickerLabel(int v) {
    switch (v) {
      case shiftJis:
        return '日文';
      case hangul:
        return '韩文';
      case gb2312:
        return '中文';
      case big5:
        return '繁体';
      case defaultCharset:
      default:
        return '默认';
    }
  }
}

/// 兼容设置（对应 CTFontHook 字体选择器「兼容设置」区的四组开关）。
///
/// 全部是**纯新增可空字段**：老 `game.json` 没有 `compat` 键时按默认值处理，
/// 因此不需要升 `format_version`（ADR-012 纯新增例外）。
///
/// 键名与语义严格对齐 `CTFontHook/docs/configuration.md`：
///   · 调用 ⇒ `EnableCodepageSpoof` + `SpoofFromCharset` + `SpoofToCharset`
///   · 映射 ⇒ `EnableTextSubstitution` + `TextSubstitutionMode` + `TextSubstitutionCodepage`
///   · 转码 ⇒ `EnableCodepageRedirect` + `CodepageRedirectFrom` + `CodepageRedirectTo`
///
/// 「彻底」不在这里：它就是 [GameFontOverride.enabled]（`EnableFaceNameReplace`），
/// 已经由安装状态本身表达。
class FontCompatSettings {
  /// 字符集能力伪装（「调用」）。对应 `EnableCodepageSpoof`。
  final bool spoof;

  /// 伪装的源字符集。对应 `SpoofFromCharset`，默认 134（GB2312）。
  final int spoofFrom;

  /// 伪装的目标字符集。对应 `SpoofToCharset`，默认 128（Shift-JIS）。
  final int spoofTo;

  /// 文字映射（「映射」）。对应 `EnableTextSubstitution`。
  final bool textSubstitution;

  /// 映射模式：0 日文旧字形 / 1 繁转简 / 2 简转繁。对应 `TextSubstitutionMode`。
  final int textSubstitutionMode;

  /// 无法检测原始编码时的回退代码页。对应 `TextSubstitutionCodepage`。
  final int textSubstitutionCodepage;

  /// 代码页转换重定向（「转码」）。对应 `EnableCodepageRedirect`。
  final bool codepageRedirect;

  /// 被重定向的源代码页。对应 `CodepageRedirectFrom`。0 = 系统 ACP。
  final int codepageRedirectFrom;

  /// 实际转换代码页。对应 `CodepageRedirectTo`。
  final int codepageRedirectTo;

  const FontCompatSettings({
    this.spoof = false,
    this.spoofFrom = FontCompatPresets.spoofDefaultFrom,
    this.spoofTo = FontCompatPresets.spoofDefaultTo,
    this.textSubstitution = false,
    this.textSubstitutionMode = 0,
    this.textSubstitutionCodepage = 932,
    this.codepageRedirect = false,
    this.codepageRedirectFrom = 936,
    this.codepageRedirectTo = 65001,
  });

  /// 全部关闭（等价于 CTFontHook 的默认状态）。
  static const FontCompatSettings defaults = FontCompatSettings();

  bool get anyEnabled => spoof || textSubstitution || codepageRedirect;

  FontCompatSettings copyWith({
    bool? spoof,
    int? spoofFrom,
    int? spoofTo,
    bool? textSubstitution,
    int? textSubstitutionMode,
    int? textSubstitutionCodepage,
    bool? codepageRedirect,
    int? codepageRedirectFrom,
    int? codepageRedirectTo,
  }) =>
      FontCompatSettings(
        spoof: spoof ?? this.spoof,
        spoofFrom: spoofFrom ?? this.spoofFrom,
        spoofTo: spoofTo ?? this.spoofTo,
        textSubstitution: textSubstitution ?? this.textSubstitution,
        textSubstitutionMode: textSubstitutionMode ?? this.textSubstitutionMode,
        textSubstitutionCodepage:
            textSubstitutionCodepage ?? this.textSubstitutionCodepage,
        codepageRedirect: codepageRedirect ?? this.codepageRedirect,
        codepageRedirectFrom: codepageRedirectFrom ?? this.codepageRedirectFrom,
        codepageRedirectTo: codepageRedirectTo ?? this.codepageRedirectTo,
      );

  factory FontCompatSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    int i(String k, int fallback) => (json[k] as num?)?.toInt() ?? fallback;
    bool b(String k) => json[k] == true;
    return FontCompatSettings(
      spoof: b('spoof'),
      spoofFrom: i('spoof_from', FontCompatPresets.spoofDefaultFrom),
      spoofTo: i('spoof_to', FontCompatPresets.spoofDefaultTo),
      textSubstitution: b('text_substitution'),
      textSubstitutionMode: i('text_substitution_mode', 0),
      textSubstitutionCodepage: i('text_substitution_codepage', 932),
      codepageRedirect: b('codepage_redirect'),
      codepageRedirectFrom: i('codepage_redirect_from', 936),
      codepageRedirectTo: i('codepage_redirect_to', 65001),
    );
  }

  Map<String, dynamic> toJson() => {
        'spoof': spoof,
        'spoof_from': spoofFrom,
        'spoof_to': spoofTo,
        'text_substitution': textSubstitution,
        'text_substitution_mode': textSubstitutionMode,
        'text_substitution_codepage': textSubstitutionCodepage,
        'codepage_redirect': codepageRedirect,
        'codepage_redirect_from': codepageRedirectFrom,
        'codepage_redirect_to': codepageRedirectTo,
      };
}

/// 兼容设置的可选项（与 CTFontHook 字体选择器的下拉项逐一对应）。
class FontCompatPresets {
  FontCompatPresets._();

  /// `configuration.md`：`SpoofFromCharset=134` / `SpoofToCharset=128`。
  static const int spoofDefaultFrom = FontCharset.gb2312;
  static const int spoofDefaultTo = FontCharset.shiftJis;

  /// 代码页常量。
  static const int cpAcp = 0; // 系统 ANSI 代码页

  /// 「调用」两端的可选字符集（原面板 `g_spoofCharsets` 顺序：日/中/繁/默认/韩）。
  static const List<int> spoofOptions = [
    FontCharset.shiftJis,
    FontCharset.gb2312,
    FontCharset.big5,
    FontCharset.defaultCharset,
    FontCharset.hangul,
  ];

  /// 「映射」模式标签（原面板 `g_textSubstitutionModes`）。
  static const List<String> textSubstitutionModeLabels = ['日繁', '繁>简', '简>繁'];

  /// 「映射」回退代码页可选项。
  static const List<int> textSubstitutionCodepages = [932, 936];

  static String codepageLabel(int cp) {
    switch (cp) {
      case 932:
        return '日文';
      case 936:
        return '中文';
      case 65001:
        return 'UTF-8';
      case cpAcp:
        return '系统';
      default:
        return '$cp';
    }
  }

  /// 「转码」预设（原面板 `g_codepageRedirectPresets`，顺序一致）。
  static const List<CodepagePreset> redirectPresets = [
    CodepagePreset('日文→UTF-8', 932, 65001),
    CodepagePreset('中文→UTF-8', 936, 65001),
    CodepagePreset('系统→UTF-8', cpAcp, 65001),
    CodepagePreset('UTF-8→日文', 65001, 932),
    CodepagePreset('UTF-8→中文', 65001, 936),
  ];

  /// 找出与给定 from/to 匹配的预设下标；无匹配返回 -1。
  static int redirectPresetIndex(int from, int to) {
    for (var i = 0; i < redirectPresets.length; i++) {
      final p = redirectPresets[i];
      if (p.from == from && p.to == to) return i;
    }
    return -1;
  }
}

/// 「转码」预设的一条。
class CodepagePreset {
  final String label;
  final int from;
  final int to;
  const CodepagePreset(this.label, this.from, this.to);
}

/// 单个游戏的字体替换配置。
///
/// 整体可空（`game.json` 无 `font_override` 键）⇒ 视为「未启用」。
class GameFontOverride {
  /// 是否启用字体替换（= CTFontHook 的 `EnableFontHook` / `EnableFaceNameReplace`）。
  ///
  /// ⚠️ 关闭时**保留 `fontName`**：空 `FontNameW` 会让 CTFontHook 的 `LoadConfig`
  /// 直接失败（`utils.cpp:1057-1058`），必须靠开关关闭而非清空字体名。
  final bool enabled;

  /// 字体**族名**（不是显示名）。对应 `FontNameW` / `FontNameA`。
  ///
  /// 🔴 必须是真族名（如 `Microsoft YaHei`），显示名（如「微软雅黑」）会静默失效。
  final String fontName;

  /// 字符集。见 [FontCharset]。
  final int charset;

  /// 是否强制替换字符集（对应 `EnableCharsetReplace`）。
  final bool charsetReplace;

  final FontMetrics metrics;

  /// 兼容设置（调用 / 映射 / 转码）。见 [FontCompatSettings]。
  final FontCompatSettings compat;

  /// 最后一次由管理器写入补丁的时间（ISO8601）。
  final String patchedAt;

  /// 投放的 DLL 架构：`32bit` / `64bit` / 空串（未知）。
  final String dllArch;

  /// 补丁是否由本管理器安装（对应 manifest 的 `ManagedBy=Chrono_Tide`）。
  ///
  /// false 但补丁存在 ⇒ 由 CTFontHook 原生工具装过（互认）。
  final bool managedByUs;

  const GameFontOverride({
    this.enabled = false,
    this.fontName = '',
    this.charset = FontCharset.defaultCharset,
    this.charsetReplace = false,
    this.metrics = FontMetrics.defaults,
    this.compat = FontCompatSettings.defaults,
    this.patchedAt = '',
    this.dllArch = '',
    this.managedByUs = false,
  });

  static const GameFontOverride disabled = GameFontOverride();

  /// 是否是一个「可投放」的有效配置（有字体名才算）。
  bool get hasFont => fontName.trim().isNotEmpty;

  GameFontOverride copyWith({
    bool? enabled,
    String? fontName,
    int? charset,
    bool? charsetReplace,
    FontMetrics? metrics,
    FontCompatSettings? compat,
    String? patchedAt,
    String? dllArch,
    bool? managedByUs,
  }) =>
      GameFontOverride(
        enabled: enabled ?? this.enabled,
        fontName: fontName ?? this.fontName,
        charset: charset ?? this.charset,
        charsetReplace: charsetReplace ?? this.charsetReplace,
        metrics: metrics ?? this.metrics,
        compat: compat ?? this.compat,
        patchedAt: patchedAt ?? this.patchedAt,
        dllArch: dllArch ?? this.dllArch,
        managedByUs: managedByUs ?? this.managedByUs,
      );

  /// 解析 `game.json` 里的 `font_override`。null / 非 Map ⇒ [disabled]。
  factory GameFontOverride.fromJson(Map<String, dynamic>? json) {
    if (json == null) return disabled;
    return GameFontOverride(
      enabled: json['enabled'] == true,
      fontName: json['font_name'] as String? ?? '',
      charset: (json['charset'] as num?)?.toInt() ?? FontCharset.defaultCharset,
      charsetReplace: json['charset_replace'] == true,
      metrics: FontMetrics.fromJson(json['metrics'] is Map
          ? Map<String, dynamic>.from(json['metrics'] as Map)
          : null),
      compat: FontCompatSettings.fromJson(json['compat'] is Map
          ? Map<String, dynamic>.from(json['compat'] as Map)
          : null),
      patchedAt: json['patched_at'] as String? ?? '',
      dllArch: json['dll_arch'] as String? ?? '',
      managedByUs: json['managed_by_us'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'font_name': fontName,
        'charset': charset,
        'charset_replace': charsetReplace,
        'metrics': metrics.toJson(),
        'compat': compat.toJson(),
        'patched_at': patchedAt,
        'dll_arch': dllArch,
        'managed_by_us': managedByUs,
      };

  @override
  String toString() =>
      'GameFontOverride(enabled=$enabled, font=$fontName, charset=$charset, '
      'arch=$dllArch, ours=$managedByUs)';
}
