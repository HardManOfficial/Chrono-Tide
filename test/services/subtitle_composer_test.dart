// 副标题合成（「副标题 = 除主标题外的全部别名」）· 单元测试（离线）
//
// 覆盖需求（2026-10-10）：
// 1. legacy 结果字段提取：alias_names 优先、original_title 回退；
// 2. 以 " / " 连接、去重、剔除与主标题相同者；
// 3. 归一化口径与 CT 名称索引一致（大小写/全半角/标点）。
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/subtitle_composer.dart';

void main() {
  group('SubtitleComposer.aliasesFromResult', () {
    test('优先 alias_names（List）并保序去空', () {
      final result = <String, dynamic>{
        'alias_names': ['アマツツミ', 'Amatsutsumi', '', '  '],
        'original_title': '（应被忽略）',
      };
      expect(SubtitleComposer.aliasesFromResult(result),
          ['アマツツミ', 'Amatsutsumi']);
    });

    test('alias_names 缺失/为空 → 回退 original_title', () {
      expect(
        SubtitleComposer.aliasesFromResult(<String, dynamic>{
          'original_title': 'アマツツミ',
        }),
        ['アマツツミ'],
      );
      expect(
        SubtitleComposer.aliasesFromResult(<String, dynamic>{
          'alias_names': <String>[],
          'original_title': 'アマツツミ',
        }),
        ['アマツツミ'],
      );
    });

    test('两者皆空 → 空列表', () {
      expect(SubtitleComposer.aliasesFromResult(<String, dynamic>{}), isEmpty);
    });
  });

  group('SubtitleComposer.compose', () {
    test('多别名以 " / " 连接（日文原名 / 英文名 / 繁中名）', () {
      final s = SubtitleComposer.compose(
        ['アマツツミ', 'Amatsutsumi', '天津罪'],
        mainTitles: ['天津罪'],
      );
      // 繁中名与主标题相同 → 剔除
      expect(s, 'アマツツミ / Amatsutsumi');
    });

    test('剔除与主标题相同者 + 去重（归一化比较）', () {
      final s = SubtitleComposer.compose(
        ['Bishoujo Mangekyou', 'ｂｉｓｈｏｕｊｏ　ｍａｎｇｅｋｙｏｕ', '美少女万華鏡'],
        mainTitles: ['BISHOUJO-MANGEKYOU!', '美少女万華鏡'],
      );
      // 首项与主标题归一后相同 → 剔除；第二项与首项重复 → 去重
      expect(s, '');
    });

    test('直接由 legacy 结果合成（alias_names 优先）', () {
      final s = SubtitleComposer.fromResult(
        <String, dynamic>{
          'alias_names': ['アマツツミ', 'Amatsutsumi'],
          'original_title': 'アマツツミ',
        },
        mainTitles: ['天津罪'],
      );
      expect(s, 'アマツツミ / Amatsutsumi');
    });

    test('全部被剔除 → 空串（调用方据此不覆盖既有副标题）', () {
      final s = SubtitleComposer.compose(
        ['天津罪'],
        mainTitles: ['天津罪'],
      );
      expect(s, '');
    });
  });
}
