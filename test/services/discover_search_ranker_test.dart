import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_model.dart';
import 'package:chrono_tide/services/discover_search/discover_search_ranker.dart';

/// 库内搜索相关性重排 —— 离线单测（DISCOVER-SEARCH-RANKER）
///
/// fixture 来自 2026-11-13 实测的**真实云端库**：562 条记录里筛出「含 air」的
/// 13 条，顺序就是 PB `-created`（最新录入在前）——也正是用户截图里那一屏
/// 「三角圆舞曲 / 天使的星期日 / 悠久之翼…」而真正的 AIR 要翻页才能看到。
///
/// 🔴 这组用例守护的是「搜 AIR 时标题就叫 AIR 的必须在前两条」，不是风格问题。
void main() {
  final t = DateTime(2026, 1, 1);

  GameModel g(
    String title, {
    String orig = '',
    String eng = '',
    String dev = '',
    List<String> tags = const [],
    String id = 'x',
  }) =>
      GameModel(
        id: id,
        title: title,
        originalTitle: orig,
        englishTitle: eng,
        developer: dev,
        tags: tags,
        created: t,
        updated: t,
      );

  int sc(GameModel game, List<String> kws) =>
      DiscoverSearchRanker.score(game, kws);

  group('匹配质量档位', () {
    test('标题完全相等 > 前缀 > 裸子串', () {
      final exact = sc(g('AIR'), ['air']);
      final prefix = sc(g('AIR重置版'), ['air']);
      final loose = sc(g('三角圆舞曲 -Triple Pairing-'), ['air']);
      expect(exact, 1400);
      expect(exact, greaterThan(prefix));
      expect(prefix, greaterThan(loose));
    });

    test('拉丁词边界：crimson air 是真命中，fairy 只是弱命中', () {
      final word = sc(
          g('月姬',
              eng: 'tsukihime: blue blue glass moon under the crimson air'),
          ['air']);
      final fairy = sc(g('悠久之翼', eng: 'ef - a fairy tale of the two.'),
          ['air']);
      expect(word, 900);
      expect(fairy, 50);
      expect(word, greaterThan(fairy));
    });

    test('中文无词边界：子串即真命中', () {
      expect(sc(g('悠久之翼-后篇'), ['悠久']), 1300);
      expect(sc(g('杀恋～悠久流传的恋之歌～'), ['悠久']), 1200);
    });

    test('会社 / 标签命中在标题命中之后', () {
      final devExact = sc(g('某作', dev: 'Key'), ['key']);
      final devPrefix = sc(g('某作', dev: 'Key社'), ['key']);
      final tag = sc(g('另一作', tags: ['拔作']), ['拔作']);
      expect(devExact, 820);
      expect(devPrefix, 720);
      expect(tag, 700);
      expect(devExact, lessThan(sc(g('AIR重置版'), ['air'])));
    });

    test('去标点归一化：triplepairing 命中 Triple Pairing', () {
      expect(sc(g('Triple Pairing'), ['triplepairing']), 1400);
      // 中英混排时英文词前后紧邻 CJK ⇒ 真命中
      expect(
          sc(g('三角圆舞曲 -Triple Pairing-'), ['triplepairing']),
          greaterThanOrEqualTo(1200));
    });

    test('多关键词是 AND，取最弱一环', () {
      final multi = g('AIR 原版');
      expect(sc(multi, ['air', '原版']),
          lessThanOrEqualTo(sc(multi, ['air'])));
      expect(sc(multi, ['air', '绝不存在的词']), DiscoverSearchRanker.noMatch);
    });

    test('空关键词返回 0', () {
      expect(sc(g('AIR'), const []), 0);
    });
  });

  group('重排行为', () {
    test('同分保持传入顺序（稳定排序）', () {
      final a = g('同分甲', eng: 'xxairy', id: 'a');
      final b = g('同分乙', eng: 'yyairz', id: 'b');
      expect(DiscoverSearchRanker.rank([a, b], ['air']).map((x) => x.id),
          ['a', 'b']);
      expect(DiscoverSearchRanker.rank([b, a], ['air']).map((x) => x.id),
          ['b', 'a']);
    });

    test('不增删元素、不改入参', () {
      final input = [g('AIR', id: '1'), g('天色幻想岛', id: '2', eng: 'Amairo')];
      final snapshot = input.map((x) => x.id).toList();
      final out = DiscoverSearchRanker.rank(input, ['air']);
      expect(out.length, 2);
      expect(out.map((x) => x.id).toSet(), {'1', '2'});
      expect(input.map((x) => x.id).toList(), snapshot);
    });
  });

  group('真实库数据（含 air 的 13 条，PB -created 顺序）', () {
    final fixture = <GameModel>[
      g('三角圆舞曲 Fandisc',
          orig: 'トリプルペアリング ミニファンディスク',
          eng: 'Triple Pairing MiniFandisc',
          dev: 'HOOKSOFT',
          id: 'f0'),
      g('天使的星期日/天使的星期天',
          orig: '天使の日曜日',
          eng:
              'Tenshi no Nichiyoubi “ef - a fairy tale of the two.” Pleasurable Box.',
          dev: 'minori',
          id: 'f1'),
      g('悠久之翼-前篇',
          orig: 'ef - the first tale.',
          eng: 'ef - a fairy tale of the two.',
          dev: 'minori',
          id: 'f2'),
      g('天色幻想岛',
          orig: '天色＊アイルノーツ', eng: 'Amairo * Islenauts', id: 'f3'),
      g('七色的轮回转生',
          orig: 'なないろリンカネーション',
          eng: 'nanairo reincarnation',
          id: 'f4'),
      g('三角圆舞曲 -Triple Pairing-',
          orig: 'トリプルペアリング -triple pairing-',
          eng: 'sanjiao yuanwuqu -triple pairing-',
          id: 'f5'),
      g('月姬',
          orig: '月姫',
          eng: 'tsukihime: blue blue glass moon under the crimson air',
          dev: '型月',
          id: 'f6'),
      g('巧克甜恋3', eng: 'amairo chocolata 3', id: 'f7'),
      g('巧克甜恋2', eng: 'amairo chocolata 2', id: 'f8'),
      g('巧克甜恋', eng: 'amairo chocolata', id: 'f9'),
      g('9-nine-天色天歌天籁音',
          eng: '9-nine- sorairo sorauta soranooto', id: 'f10'),
      g('AIR原版', dev: 'Key社', id: 'f11'),
      g('AIR重置版', dev: 'Key社', id: 'f12'),
    ];

    test('AIR 两部被顶到前两名', () {
      final ranked = DiscoverSearchRanker.rank(fixture, ['air']);
      expect(ranked.take(2).map((x) => x.title).toSet(), {'AIR原版', 'AIR重置版'});
    });

    test('第 3 名是真词边界命中（月姬），此后全是弱命中', () {
      final ranked = DiscoverSearchRanker.rank(fixture, ['air']);
      expect(ranked[2].title, '月姬');
      expect(DiscoverSearchRanker.score(ranked[2], ['air']), 900);
      for (final item in ranked.skip(3)) {
        expect(DiscoverSearchRanker.score(item, ['air']), lessThanOrEqualTo(60),
            reason: '${item.title} 应垫在弱命中档');
      }
    });
  });
}
