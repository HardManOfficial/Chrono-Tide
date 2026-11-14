// win32_font_enumerator.dart
// 系统已装字体族的枚举（L5 独立能力）。
//
// 为什么必须走 `gdi32!EnumFontFamiliesExW` 而不是读注册表：
//   `HKLM\...\Windows NT\CurrentVersion\Fonts` 里存的是**显示名**
//   （如「微软雅黑」），而 CTFontHook 的 `FontNameW` 匹配的是**族名**
//   （如 `Microsoft YaHei`）。用显示名去配 = 用户选完静默失效。
//   只有 GDI 枚举拿到的才是真族名（Phase 0 V6 实测：520 个族名）。
//
// 🔴 口径要点（Phase 0 V6 实测纠正）：
//   · `lfCharSet` 必须取 **1（DEFAULT_CHARSET）**。取 `0xFF` 只会返回
//     4 个 OEM 光栅字体（Terminal/Modern/Roman/Script）。
//   · 回调必须用 `NativeCallable.isolateLocal`，且**必须传 `exceptionalReturn`**
//     （否则编译报错）；回调内**禁止抛异常**（穿越 FFI 边界是 UB）。
//   · `@` 开头的族名是竖排变体（实测 69 个），默认过滤掉。
//   · 实测耗时 4–10 ms（520 族）⇒ 独立 isolate 是「好习惯」而非硬需求，
//     因此本实现 isolate 失败时**回退到当前 isolate**，不引入脆性。
//
// 缓存：`data/cache/system_fonts.json`（跨会话），`refresh: true` 时重枚举。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../core/path_helper.dart';
import '../models/game_font_override.dart';

// ═══════════════════════════════════════════════════════════
// Win32 结构体（与 C 定义同布局）
// ═══════════════════════════════════════════════════════════

/// `LOGFONTW` = 5×LONG(20) + 8×BYTE(8) + WCHAR[32](64) = 92 字节
final class LOGFONTW extends Struct {
  @Int32()
  external int lfHeight;
  @Int32()
  external int lfWidth;
  @Int32()
  external int lfEscapement;
  @Int32()
  external int lfOrientation;
  @Int32()
  external int lfWeight;
  @Uint8()
  external int lfItalic;
  @Uint8()
  external int lfUnderline;
  @Uint8()
  external int lfStrikeOut;
  @Uint8()
  external int lfCharSet;
  @Uint8()
  external int lfOutPrecision;
  @Uint8()
  external int lfClipPrecision;
  @Uint8()
  external int lfQuality;
  @Uint8()
  external int lfPitchAndFamily;
  @Array(32)
  external Array<Uint16> lfFaceName;
}

/// `ENUMLOGFONTEXW` = `LOGFONTW`(92) + WCHAR[64] + WCHAR[32] + WCHAR[32] = 348 字节
final class ENUMLOGFONTEXW extends Struct {
  external LOGFONTW elfLogFont;
  @Array(64)
  external Array<Uint16> elfFullName;
  @Array(32)
  external Array<Uint16> elfStyle;
  @Array(32)
  external Array<Uint16> elfScript;
}

typedef _EnumFontFamiliesExNative = Int32 Function(
    Pointer<Void> hdc,
    Pointer<LOGFONTW> lpLogfont,
    Pointer<NativeFunction<_FontEnumProcNative>> lpProc,
    IntPtr lParam,
    Uint32 dwFlags);
typedef _EnumFontFamiliesExDart = int Function(
    Pointer<Void> hdc,
    Pointer<LOGFONTW> lpLogfont,
    Pointer<NativeFunction<_FontEnumProcNative>> lpProc,
    int lParam,
    int dwFlags);

typedef _FontEnumProcNative = Int32 Function(Pointer<ENUMLOGFONTEXW> lpelfe,
    Pointer<Void> lpntme, Uint32 fontType, IntPtr lParam);

typedef _GetDCNative = Pointer<Void> Function(Pointer<Void> hWnd);
typedef _GetDCDart = Pointer<Void> Function(Pointer<Void> hWnd);
typedef _ReleaseDCNative = Int32 Function(Pointer<Void> hWnd, Pointer<Void> hDC);
typedef _ReleaseDCDart = int Function(Pointer<Void> hWnd, Pointer<Void> hDC);

/// 一个字体族。
class SystemFontFamily implements Comparable<SystemFontFamily> {
  /// 真族名（= CTFontHook `FontNameW` 匹配的值）
  final String name;

  /// 该族报告过的全部 `lfCharSet`（去重、升序）。
  /// 常见值：1=DEFAULT，128=Shift-JIS，129=韩，134=GB2312，136=BIG5。
  final List<int> charsets;

  /// 是否是竖排变体（族名以 `@` 开头）
  final bool isVerticalVariant;

  const SystemFontFamily({
    required this.name,
    required this.charsets,
    this.isVerticalVariant = false,
  });

  /// 是否支持简中（GB2312）。
  bool get supportsSimplifiedChinese =>
      charsets.contains(FontCharset.gb2312);

  /// 是否支持日文（Shift-JIS）。
  bool get supportsJapanese => charsets.contains(FontCharset.shiftJis);

  bool get supportsTraditionalChinese => charsets.contains(FontCharset.big5);

  bool get supportsKorean => charsets.contains(FontCharset.hangul);

  /// 命中任何一个东亚字符集（用于 UI 默认排序：把能打字的字体排前面）。
  bool get supportsEastAsian =>
      supportsSimplifiedChinese ||
      supportsJapanese ||
      supportsTraditionalChinese ||
      supportsKorean;

  /// 用于搜索：小写去空格比较。
  bool matchesQuery(String q) {
    if (q.trim().isEmpty) return true;
    final needle = q.trim().toLowerCase();
    return name.toLowerCase().contains(needle) ||
        name.replaceAll(' ', '').toLowerCase().contains(
            needle.replaceAll(' ', ''));
  }

  @override
  int compareTo(SystemFontFamily other) {
    // 优先东亚字体，其次按名字（不区分大小写）排序
    if (supportsEastAsian != other.supportsEastAsian) {
      return supportsEastAsian ? -1 : 1;
    }
    return name.toLowerCase().compareTo(other.name.toLowerCase());
  }

  factory SystemFontFamily.fromJson(Map<String, dynamic> json) =>
      SystemFontFamily(
        name: json['name'] as String? ?? '',
        charsets: ((json['charsets'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
        isVerticalVariant: json['vertical'] == true,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'charsets': charsets,
        if (isVerticalVariant) 'vertical': true,
      };

  @override
  String toString() => '$name$charsets';
}

/// 枚举结果快照。
class SystemFontsSnapshot {
  final List<SystemFontFamily> families;
  final String generatedAt;
  final bool fromCache;

  const SystemFontsSnapshot({
    required this.families,
    required this.generatedAt,
    this.fromCache = false,
  });

  List<SystemFontFamily> get usable =>
      families.where((f) => !f.isVerticalVariant).toList();

  @override
  String toString() =>
      'SystemFontsSnapshot(${families.length} families, cache=$fromCache)';
}

class Win32FontEnumerator {
  Win32FontEnumerator._();

  /// 进程内会话缓存（避免同一会话反复读盘）
  static SystemFontsSnapshot? _sessionCache;

  /// 清空会话缓存（测试用）。
  static void resetSessionCache() => _sessionCache = null;

  // ═══════════════════════════════════════════════════════════
  // 同步枚举（必须在**调用它的那个 isolate** 内直接调用）
  // ═══════════════════════════════════════════════════════════

  /// 直接调 GDI 枚举。`NativeCallable.isolateLocal` 的约束要求
  /// 本方法在哪个 isolate 被调用，回调就注册在哪个 isolate。
  static List<SystemFontFamily> enumerateSync() {
    final gdi32 = DynamicLibrary.open('gdi32.dll');
    final user32 = DynamicLibrary.open('user32.dll');

    final enumFontFamilies = gdi32.lookupFunction<_EnumFontFamiliesExNative,
        _EnumFontFamiliesExDart>('EnumFontFamiliesExW');
    final getDC =
        user32.lookupFunction<_GetDCNative, _GetDCDart>('GetDC');
    final releaseDC =
        user32.lookupFunction<_ReleaseDCNative, _ReleaseDCDart>('ReleaseDC');

    // 族名 → 字符集集合（同一族会按不同 charset 多次回调）
    final names = <String>{};
    final charsets = <String, Set<int>>{};

    final cb = NativeCallable<_FontEnumProcNative>.isolateLocal(
      (Pointer<ENUMLOGFONTEXW> lpelfe, Pointer<Void> lpntme, int fontType,
          int lParam) {
        try {
          final lf = lpelfe.ref.elfLogFont;
          final sb = StringBuffer();
          for (var i = 0; i < 32; i++) {
            final c = lf.lfFaceName[i];
            if (c == 0) break;
            sb.writeCharCode(c);
          }
          final name = sb.toString();
          if (name.isNotEmpty) {
            names.add(name);
            (charsets[name] ??= <int>{}).add(lf.lfCharSet);
          }
        } catch (_) {
          // 回调内禁止抛出：异常穿越 FFI 边界是未定义行为
        }
        return 1; // 非 0 = 继续枚举
      },
      // 🔴 必须提供：否则编译期报 "Expected an exceptional return value"
      exceptionalReturn: 1,
    );

    final hdc = getDC(nullptr);
    if (hdc == nullptr) {
      cb.close();
      return const [];
    }

    final lf = calloc<LOGFONTW>();
    try {
      lf.ref.lfCharSet = 1; // DEFAULT_CHARSET ⇒ 枚举全部字符集（V6 实测口径）
      lf.ref.lfPitchAndFamily = 0;
      lf.ref.lfFaceName[0] = 0;
      enumFontFamilies(hdc, lf, cb.nativeFunction, 0, 0);
    } finally {
      calloc.free(lf);
      releaseDC(nullptr, hdc);
      cb.close();
    }

    final list = names
        .map((n) => SystemFontFamily(
              name: n,
              charsets: (charsets[n] ?? const <int>{})
                  .toList()
                ..sort(),
              isVerticalVariant: n.startsWith('@'),
            ))
        .toList()
      ..sort();
    return list;
  }

  // ═══════════════════════════════════════════════════════════
  // 异步枚举（隔离 isolate + 磁盘缓存）
  // ═══════════════════════════════════════════════════════════

  /// 取系统字体列表。
  ///
  /// 顺序：会话缓存 → （refresh 时跳过）磁盘缓存 → 重新枚举。
  /// 枚举默认放进独立 isolate，避免阻塞首帧；**失败则回退当前 isolate**
  /// （实测只需 4–10 ms，回退不会造成可感知卡顿）。
  static Future<SystemFontsSnapshot> enumerate({bool refresh = false}) async {
    if (!refresh && _sessionCache != null) {
      return SystemFontsSnapshot(
        families: _sessionCache!.families,
        generatedAt: _sessionCache!.generatedAt,
        fromCache: true,
      );
    }

    if (!refresh) {
      final disk = readDiskCache();
      if (disk != null) {
        _sessionCache = disk;
        return SystemFontsSnapshot(
          families: disk.families,
          generatedAt: disk.generatedAt,
          fromCache: true,
        );
      }
    }

    List<SystemFontFamily> families;
    try {
      families = await Isolate.run(enumerateSync);
    } catch (_) {
      // isolate 不可用（或 FFI 在子 isolate 受限）⇒ 当前 isolate 直跑
      families = enumerateSync();
    }

    final snap = SystemFontsSnapshot(
      families: families,
      generatedAt: DateTime.now().toIso8601String(),
    );
    _sessionCache = snap;
    await _writeDiskCache(snap);
    return snap;
  }

  /// 只读磁盘缓存；不存在/损坏返回 null（**不抛异常**，静默回退重枚举）。
  static SystemFontsSnapshot? readDiskCache() {
    try {
      final f = File(PathHelper.systemFontsCacheFilePath);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return null;
      final list = (j['families'] as List?) ?? const [];
      final families = list
          .whereType<Map>()
          .map((e) => SystemFontFamily.fromJson(Map<String, dynamic>.from(e)))
          .where((f) => f.name.isNotEmpty)
          .toList();
      if (families.isEmpty) return null;
      families.sort();
      return SystemFontsSnapshot(
        families: families,
        generatedAt: j['generated_at'] as String? ?? '',
        fromCache: true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeDiskCache(SystemFontsSnapshot snap) async {
    try {
      final f = File(PathHelper.systemFontsCacheFilePath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'generated_at': snap.generatedAt,
        'count': snap.families.length,
        'families': snap.families.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {
      // 缓存写失败不影响功能
    }
  }

  /// 删除磁盘缓存（「刷新字体列表」用）。
  static Future<void> clearCache() async {
    _sessionCache = null;
    try {
      final f = File(PathHelper.systemFontsCacheFilePath);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
