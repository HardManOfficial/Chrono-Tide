// CT 探索库源单元测试（离线，基于 PocketBase games 集合真实字段形态）
//
// 覆盖：记录解析（标题/副标题/封面横幅文件 URL 拼接/会社字段兼容/
// 评分归一/截图提取/标签双形态）。fixture 字段取自自有 PB
// games 集合（title/originalTitle/cover/screenshots 等）。
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

void main() {
  group('CT 探索库 基础标识', () {
    test('SourceType.ct 枚举与展示名', () {
      expect(SourceType.ct.displayName, 'CT');
      expect(SourceType.ct.isMix, isFalse);
    });

    test('服务标识', () {
      final service = CTService();
      expect(service.sourceType, SourceType.ct);
      expect(service.sourceName, 'CT');
    });
  });

  group('CT 记录解析（fixture：自有 PB games 集合字段形态）', () {
    final recordFixture = <String, dynamic>{
      'id': 'p3q9x2m8k4w1n7c',
      'title': '天津罪',
      'originalTitle': 'アマツツミ',
      'englishTitle': 'Amatsutsumi',
      'traditionalChineseTitle': '天津罪',
      'description': '純愛系アドベンチャーゲーム。',
      'developer': 'Purple software',
      'cover': 'cover_abc123.webp',
      'bannerUrl': 'banner_def456.webp',
      'screenshots': ['ss_001.webp', 'ss_002.webp'],
      'tags': ['纯爱', '校园'],
      'rating': 8.1,
      'voteCount': 356,
      'releaseDate': '2016-04-07',
    };

    test('标题与副标题', () {
      final result =
          CTService().parseRecordForTesting(Map.of(recordFixture));
      expect(result.game.name, '天津罪');
      expect(result.game.originalTitle, 'アマツツミ');
      expect(result.game.sourceType, SourceType.ct);
      expect(result.game.sourceId, 'p3q9x2m8k4w1n7c');
    });

    test('文件字段拼接完整 URL', () {
      final result =
          CTService().parseRecordForTesting(Map.of(recordFixture));
      const base = 'http://117.72.115.30:8090';
      const recordId = 'p3q9x2m8k4w1n7c';
      expect(result.game.coverUrl,
          '$base/api/files/games/$recordId/cover_abc123.webp');
      expect(result.game.bannerUrl,
          '$base/api/files/games/$recordId/banner_def456.webp');
      expect(result.game.screenshotUrls, [
        '$base/api/files/games/$recordId/ss_001.webp',
        '$base/api/files/games/$recordId/ss_002.webp',
      ]);
    });

    test('会社/简介/评分/发售日', () {
      final result =
          CTService().parseRecordForTesting(Map.of(recordFixture));
      expect(result.game.company, 'Purple software');
      expect(result.game.summary, '純愛系アドベンチャーゲーム。');
      expect(result.game.rating, 8.1);
      expect(result.game.voteCount, 356);
      expect(result.game.releaseDate, '2016-04-07');
    });

    test('标签：List 形态直通（中文不走翻译）', () {
      final result =
          CTService().parseRecordForTesting(Map.of(recordFixture));
      expect(result.tags.map((t) => t.name), ['纯爱', '校园']);
      expect(result.tags.every((t) => t.source == 'ct'), isTrue);
    });

    test('标签：逗号字符串形态兼容', () {
      final json = Map.of(recordFixture)..['tags'] = '纯爱, 校园';
      final result = CTService().parseRecordForTesting(json);
      expect(result.tags.map((t) => t.name), ['纯爱', '校园']);
    });

    test('异常评分（100 分制）归一化到 0-10', () {
      final json = Map.of(recordFixture)..['rating'] = 82;
      final result = CTService().parseRecordForTesting(json);
      expect(result.game.rating, closeTo(8.2, 0.01));
    });

    test('缺 title 视为空结果', () {
      final json = Map.of(recordFixture)..['title'] = '';
      final result = CTService().parseRecordForTesting(json);
      expect(result.game.name, '');
    });

    test('缺封面/截图/横幅字段安全降级', () {
      final json = Map.of(recordFixture)
        ..remove('cover')
        ..remove('bannerUrl')
        ..remove('screenshots');
      final result = CTService().parseRecordForTesting(json);
      expect(result.game.coverUrl, '');
      expect(result.game.bannerUrl, '');
      expect(result.game.screenshotUrls, isNull);
    });
  });

  group('CT 名称搜索索引（2026-10-05 别名检索优化）', () {
    test('filter 覆盖四个命名字段（OR）', () {
      final service = CTService();
      final filter = service.nameSearchFilterForTesting('万華鏡');
      expect(filter, isNotNull);
      for (final field in [
        'title',
        'originalTitle',
        'englishTitle',
        'traditionalChineseTitle'
      ]) {
        expect(filter, contains("$field ~ '万華鏡'"));
      }
    });

    test('filter 转义：单引号安全进入四字段', () {
      final service = CTService();
      final filter = service.nameSearchFilterForTesting("it's");
      expect(filter, isNotNull);
      expect(filter, contains(r"it\'s"));
      // 不允许出现未转义的裸引号破坏表达式
      expect(RegExp(r"[^\\]'").allMatches(filter!).length, 8); // 每字段首尾各一
    });

    test('空/纯控制字符输入返回 null（不加过滤）', () {
      final service = CTService();
      expect(service.nameSearchFilterForTesting(''), isNull);
      expect(service.nameSearchFilterForTesting('  \n\t '), isNull);
    });

    test('归一化：大小写/全角半角/标点空白', () {
      expect(CTService.normalizeForSearch('Bishoujo Mangekyou'),
          'bishoujomangekyou');
      expect(CTService.normalizeForSearch('ＢＩＳＨＯＵＪＯ　ＭＡＮＧＥＫＹＯＵ'),
          'bishoujomangekyou');
      expect(CTService.normalizeForSearch('万華鏡１ -呪われし-'),
          '万華鏡1呪われし');
      expect(CTService.normalizeForSearch('美少女万華鏡！～刪檔～'),
          '美少女万華鏡刪檔');
      // ★ 2026-10-10：装饰/分隔符号（＊×☆…）也参与归一化——保证
      // 「突然＊恋人」与「突然恋人」归一为同一键（分词召回与精度闸同口径）
      expect(CTService.normalizeForSearch('突然＊恋人'), '突然恋人');
      expect(CTService.normalizeForSearch('Making＊Lovers☆FHD'),
          'makingloversfhd');
    });

    test('归一化后不同变体命中同一键', () {
      final a = CTService.normalizeForSearch('Bishoujo Mangekyou!');
      final b = CTService.normalizeForSearch('ｂｉｓｈｏｕｊｏ ｍａｎｇｅｋｙｏｕ');
      expect(a, b);
      expect(a, isNotEmpty);
    });
  });

  group('CT 名称索引：分词召回 + 精度闸（2026-10-10 修复）', () {
    test('分词：CJK 4 字 → 滑窗 2-gram（召回被标点隔断的同一作品）', () {
      expect(CTService.queryTokensForTesting('突然恋人'),
          ['突然', '然恋', '恋人']);
    });

    test('分词：全角＊等标点先剥离再切分', () {
      expect(CTService.queryTokensForTesting('突然＊恋人'), ['突然', '恋人']);
    });

    test('分词：拉丁词按空白切词（Making Lovers → making/lovers）', () {
      expect(CTService.queryTokensForTesting('Making Lovers'),
          ['making', 'lovers']);
    });

    test('分词：段数过多时截断到上限（防候选爆炸）', () {
      final tokens =
          CTService.queryTokensForTesting('美少女万華鏡 呪われし伝説の少女');
      expect(tokens.length, 6);
      expect(tokens, containsAll(<String>['美少', '呪わ']));
    });

    test('精度闸：包含全部关键词段才入选（标点变体命中）', () {
      final items = [
        {'id': 'a', 'title': '突然＊恋人', 'originalTitle': '突然＊恋人'},
        {'id': 'b', 'title': '毫不相干的游戏', 'originalTitle': '別の作品'},
      ];
      final hit = CTService().pickBestMatchForTesting(items, '突然恋人');
      expect(hit, isNotNull);
      expect(hit!['id'], 'a');
    });

    test('精度闸：无候选全段命中 → 返回 null（不再回退第一条）', () {
      final items = [
        {'id': 'x', 'title': '恋爱物语', 'originalTitle': '恋愛物語'},
        {'id': 'y', 'title': '某作品', 'originalTitle': 'なにか'},
      ];
      expect(CTService().pickBestMatchForTesting(items, '突然恋人'), isNull);
    });

    test('精度闸：英文带空格可命中（Making Lovers vs Making * Lovers FHD…）', () {
      final items = [
        {
          'id': 'm',
          'title': 'Making＊Lovers',
          'englishTitle': 'Making * Lovers FHD Deluxe Edition',
        },
        {'id': 'z', 'title': '另一个', 'englishTitle': 'Other Game'},
      ];
      final hit = CTService().pickBestMatchForTesting(items, 'Making Lovers');
      expect(hit, isNotNull);
      expect(hit!['id'], 'm');
    });

    test('精确命中优先于前缀/包含命中', () {
      final items = [
        {'id': 'sub', 'title': '突然恋人 完全版'},
        {'id': 'exact', 'title': '突然恋人'},
      ];
      final hit = CTService().pickBestMatchForTesting(items, '突然恋人');
      expect(hit!['id'], 'exact');
    });

    test('记录解析：汇总全部别名（日文/英文/繁中，去重且剔除主标题）', () {
      final json = {
        'id': 'r1',
        'title': '天津罪',
        'originalTitle': 'アマツツミ',
        'englishTitle': 'Amatsutsumi',
        'traditionalChineseTitle': '天津罪', // 与主标题相同 → 剔除
        'developer': 'Purple software',
      };
      final result = CTService().parseRecordForTesting(json);
      expect(result.game.aliasNames, ['アマツツミ', 'Amatsutsumi']);
    });

    test('记录解析：无别名时 aliasNames 为 null', () {
      final json = {'id': 'r2', 'title': '无别名作品'};
      final result = CTService().parseRecordForTesting(json);
      expect(result.game.aliasNames, isNull);
    });
  });
}
