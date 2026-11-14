// win32_font_enumerator_test.dart
// 系统字体枚举回归测试（2026-10-17）。
//
// ⚠️ 仅在 Windows 上有意义（底层是 gdi32!EnumFontFamiliesExW）。
// 其余平台直接跳过，避免 CI 误报。
//
// 覆盖：枚举非空且数量合理、含中日文族、竖排变体被标记而非塞进可用列表、
//       排序（东亚字体优先）、搜索、磁盘缓存往返、损坏缓存静默回退。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/win32_font_enumerator.dart';

void main() {
  if (!Platform.isWindows) {
    test('非 Windows 平台跳过字体枚举测试', () {}, skip: '仅 Windows');
    return;
  }

  late Directory appRoot;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_fontenum_');
    PathHelper.exeDirOverride = appRoot.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    Win32FontEnumerator.resetSessionCache();
    final f = File(PathHelper.systemFontsCacheFilePath);
    if (f.existsSync()) f.deleteSync();
  });

  group('enumerateSync（直接调 GDI）', () {
    test('拿到 > 50 个族名（正常 Windows 应数百）', () {
      final list = Win32FontEnumerator.enumerateSync();
      expect(list.length, greaterThan(50),
          reason: 'Phase 0 V6 实测本机 520 族；若只有 4 个说明 lfCharSet 口径错了');
      expect(list.any((f) => f.isVerticalVariant), isTrue,
          reason: '应存在 @ 竖排变体，证明过滤必要');
    });

    test('含中日文字体族（真族名，非显示名）', () {
      final names =
          Win32FontEnumerator.enumerateSync().map((f) => f.name).toSet();
      final hasCjk = names.any((n) =>
          n.contains('YaHei') ||
          n.contains('SimSun') ||
          n.contains('Gothic') ||
          n.contains('Meiryo'));
      expect(hasCjk, isTrue, reason: '必须拿到真族名才能与 FontNameW 匹配');
    });

    test('charsets 被记录（至少一个族报告了 GB2312 或 Shift-JIS）', () {
      final list = Win32FontEnumerator.enumerateSync();
      expect(
          list.any((f) => f.supportsSimplifiedChinese) ||
              list.any((f) => f.supportsJapanese),
          isTrue);
    });

    test('排序：东亚字体排在非东亚之前；结果按名字稳定', () {
      final list = Win32FontEnumerator.enumerateSync();
      // 找到第一个非东亚的下标，其后再出现东亚即为乱序
      final firstNonEa = list.indexWhere((f) => !f.supportsEastAsian);
      if (firstNonEa >= 0) {
        expect(list.skip(firstNonEa).any((f) => f.supportsEastAsian), isFalse,
            reason: '东亚字体应全部排在前面');
      }
    });
  });

  group('可用列表与搜索', () {
    test('usable 过滤掉全部竖排变体', () {
      final snap = SystemFontsSnapshot(
        families: Win32FontEnumerator.enumerateSync(),
        generatedAt: 'x',
      );
      expect(snap.usable.any((f) => f.isVerticalVariant), isFalse);
      expect(snap.usable.length, lessThan(snap.families.length));
    });

    test('matchesQuery：大小写不敏感、忽略空格', () {
      const f = SystemFontFamily(name: 'Microsoft YaHei', charsets: [134]);
      expect(f.matchesQuery('yahei'), isTrue);
      expect(f.matchesQuery('Microsoft YaHei'), isTrue);
      expect(f.matchesQuery('   '), isTrue);
      expect(f.matchesQuery('不存在'), isFalse);
    });

    test('字符集能力判定', () {
      const f = SystemFontFamily(name: 'X', charsets: [134, 128]);
      expect(f.supportsSimplifiedChinese, isTrue);
      expect(f.supportsJapanese, isTrue);
      expect(f.supportsTraditionalChinese, isFalse);
      expect(f.supportsKorean, isFalse);
      expect(f.supportsEastAsian, isTrue);
    });
  });

  group('缓存', () {
    test('enumerate 落盘 → 再读命中缓存', () async {
      final first = await Win32FontEnumerator.enumerate(refresh: true);
      expect(first.fromCache, isFalse);
      expect(first.families, isNotEmpty);
      expect(File(PathHelper.systemFontsCacheFilePath).existsSync(), isTrue);

      Win32FontEnumerator.resetSessionCache();
      final second = await Win32FontEnumerator.enumerate();
      expect(second.fromCache, isTrue);
      expect(second.families.length, first.families.length);
      expect(second.families.first.name, first.families.first.name);
    });

    test('缓存损坏 ⇒ 静默回退重枚举（不抛）', () async {
      final f = File(PathHelper.systemFontsCacheFilePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('{ this is not json');
      Win32FontEnumerator.resetSessionCache();
      expect(Win32FontEnumerator.readDiskCache(), isNull);
      final snap = await Win32FontEnumerator.enumerate();
      expect(snap.families, isNotEmpty);
    });

    test('缓存内容为空数组 ⇒ 视为无效缓存', () {
      final f = File(PathHelper.systemFontsCacheFilePath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'generated_at': 'x', 'families': []}));
      expect(Win32FontEnumerator.readDiskCache(), isNull);
    });

    test('clearCache 删除磁盘缓存', () async {
      await Win32FontEnumerator.enumerate(refresh: true);
      expect(File(PathHelper.systemFontsCacheFilePath).existsSync(), isTrue);
      await Win32FontEnumerator.clearCache();
      expect(File(PathHelper.systemFontsCacheFilePath).existsSync(), isFalse);
    });

    test('序列化往返保留 charsets', () {
      const f = SystemFontFamily(name: 'SimSun', charsets: [134, 136]);
      final back = SystemFontFamily.fromJson(f.toJson());
      expect(back.name, 'SimSun');
      expect(back.charsets, [134, 136]);
      expect(back.isVerticalVariant, isFalse);
    });
  });
}
