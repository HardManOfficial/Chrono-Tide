import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'package:chrono_tide/services/site_search/site_search_ranker.dart';

/// 全站搜索标题重排 —— 离线单测
///
/// fixture 全部来自 2026-11-11 实测的真实接口返回（`curl` 抓的原始标题），
/// 不是手编的理想数据：鲲搜「缘之空」返回的 20 条、2DFan 搜「AIR」返回的 20 条，
/// 都是这一天的原样。
///
/// 🔴 这组用例守护的是「搜 AIR 不该搜出 CLANNAD」和「搜缘之空不该只剩一堆
/// X之Y」，不是风格问题。
void main() {
  SiteSearchHit hit(
    String title, {
    SiteSearchSource source = SiteSearchSource.moyu,
    String siteId = '1',
    String? originalTitle,
    List<String> aliasNames = const [],
  }) =>
      SiteSearchHit(
        source: source,
        siteId: siteId,
        title: title,
        originalTitle: originalTitle,
        aliasNames: aliasNames,
      );

  List<SiteSearchHit> fanHits(List<String> titles) => [
        for (var i = 0; i < titles.length; i++)
          hit(titles[i],
              source: SiteSearchSource.twoDfan, siteId: '${7000 + i}'),
      ];

  group('scoreTitle · 拉丁关键词必须带词边界', () {
    test('完全相等', () {
      expect(SiteSearchRanker.scoreTitle('AIR', 'AIR'),
          SiteSearchRanker.kScoreExact);
      expect(SiteSearchRanker.scoreTitle('Air', 'AIR'),
          SiteSearchRanker.kScoreExact);
    });

    test('全角字母按半角算', () {
      expect(SiteSearchRanker.scoreTitle('ＡＩＲ', 'air'),
          SiteSearchRanker.kScoreExact);
    });

    test('前缀', () {
      expect(SiteSearchRanker.scoreTitle('AIRメイド', 'AIR'),
          SiteSearchRanker.kScorePrefix);
      expect(SiteSearchRanker.scoreTitle('AIR WING', 'AIR'),
          SiteSearchRanker.kScorePrefix);
      expect(SiteSearchRanker.scoreTitle("Air in X'mas", 'AIR'),
          SiteSearchRanker.kScorePrefix);
    });

    test('独立词算命中', () {
      expect(
        SiteSearchRanker.scoreTitle('My Dream ～On Airが待てなくて～', 'AIR'),
        SiteSearchRanker.kScoreContains,
      );
    });

    test('🔴 词中间不算命中（FairlyLife 不该冒充 AIR）', () {
      for (final noise in [
        'FairlyLife',
        'FairChild',
        'airy［F］airy',
        'triple pairing',
        'The last fairy tale.',
        'CLANNAD',
      ]) {
        expect(SiteSearchRanker.scoreTitle(noise, 'AIR'), 0, reason: noise);
      }
    });
  });

  group('scoreTitle · CJK 用子串', () {
    test('完全相等', () {
      expect(SiteSearchRanker.scoreTitle('缘之空', '缘之空'),
          SiteSearchRanker.kScoreExact);
    });

    test('空格不参与比较', () {
      expect(SiteSearchRanker.scoreTitle('缘 之 空', '缘之空'),
          SiteSearchRanker.kScoreExact);
    });

    test('前缀 / 包含', () {
      expect(SiteSearchRanker.scoreTitle('缘之空 -Yosuga no Sora-', '缘之空'),
          SiteSearchRanker.kScorePrefix);
      expect(SiteSearchRanker.scoreTitle('缘之空', '缘之'),
          SiteSearchRanker.kScorePrefix);
      expect(SiteSearchRanker.scoreTitle('缘之空', '之空'),
          SiteSearchRanker.kScoreContains);
    });

    test('🔴 拆字匹配的噪音一律不命中', () {
      // 鲲把「缘之空」拆成单字，因此返回的全是下面这些
      for (final noise in [
        '终之空',
        '悠之缘',
        '夏之空－夏空－',
        '星之梦',
        '卵之键',
        '时之带',
        '暗之种',
      ]) {
        expect(SiteSearchRanker.scoreTitle(noise, '缘之空'), 0, reason: noise);
      }
    });
  });

  group('scoreHit · 三个候选标题取最高', () {
    test('中文标题命不中，但英文原名命得中（鲲的 AIR = 鸟之诗）', () {
      // 实测：id=2156 title=鸟之诗 / display_name=AIR
      final air = hit('鸟之诗', originalTitle: 'AIR');
      expect(SiteSearchRanker.scoreHit(air, 'AIR'),
          SiteSearchRanker.kScoreExact);
      expect(SiteSearchRanker.scoreHit(air, '鸟之诗'),
          SiteSearchRanker.kScoreExact);
    });

    test('别名命中也算', () {
      final h = hit('鸟之诗', originalTitle: 'エアー', aliasNames: ['Air']);
      expect(SiteSearchRanker.scoreHit(h, 'AIR'),
          SiteSearchRanker.kScoreExact);
    });

    test('三个候选都不命中就是 0', () {
      final h = hit('CLANNAD', originalTitle: 'CLANNAD');
      expect(SiteSearchRanker.scoreHit(h, 'AIR'), 0);
    });
  });

  group('rank · 过滤 + 跨源混排', () {
    test('搜「缘之空」：鲲只留真正的缘之空，2DFan 靠 Top1 兜底', () {
      // 鲲的真实返回顺序（前 8 条）
      final moyu = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [
          hit('缘之空', siteId: '51', originalTitle: 'ヨスガノソラ'),
          hit('终之空', siteId: '5623'),
          hit('悠之缘', siteId: '2483'),
          hit('夏之空－夏空－', siteId: '9813'),
          hit('星之梦', siteId: '196'),
          hit('卵之键', siteId: '210526'),
        ],
      );
      // 2DFan 的真实返回：卡片态只有日文标题，一个汉字都对不上
      final fan = SiteSearchSourceResult(
        source: SiteSearchSource.twoDfan,
        hits: fanHits([
          'ヨスガノソラ',
          'そして初恋が妹になる',
          'よめがみ My Sweet Goddess！',
          'BALDR SKY Dive2“RECORDARE”',
        ]),
      );

      final ranked = SiteSearchRanker.rank([moyu, fan], '缘之空');

      expect(ranked.hits.length, 2);
      expect(ranked.hits[0].title, '缘之空');
      expect(ranked.hits[1].title, 'ヨスガノソラ'); // Top1 兜底
      expect(ranked.candidateCount, 10);
      expect(ranked.filteredCount, 8);
    });

    test('搜「AIR」：真 AIR 置顶，周边作品在后，CLANNAD 被滤掉', () {
      // 鲲：鸟之诗（=AIR）排在站点第 0 位
      final moyu = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [
          hit('鸟之诗', siteId: '2156', originalTitle: 'AIR'),
          hit('Air Line ～奈落的空中乘务员～', siteId: '46854'),
          hit('AIR女仆', siteId: '16161'),
          hit('AIR WING', siteId: '246408'),
          hit('大气汚染(假)', siteId: '16158'),
        ],
      );
      // 2DFan：AIR 在第 0 位，CLANNAD 混在第 4 位
      final fan = SiteSearchSourceResult(
        source: SiteSearchSource.twoDfan,
        hits: fanHits([
          'AIR',
          'Air',
          'CLANNAD',
          'FairlyLife',
          "Air in X'mas",
        ]),
      );

      final ranked = SiteSearchRanker.rank([moyu, fan], 'AIR');
      final titles = [for (final h in ranked.hits) h.title];

      expect(titles, isNot(contains('CLANNAD')));
      expect(titles, isNot(contains('FairlyLife')));
      expect(titles, isNot(contains('大气汚染(假)')));
      // 100 分档：鸟之诗 / AIR / Air，鲲在前
      expect(titles.take(3).toList(), ['鸟之诗', 'AIR', 'Air']);
      // 85 分档在后
      expect(titles.skip(3).toSet(),
          {'Air Line ～奈落的空中乘务员～', 'AIR女仆', 'AIR WING', "Air in X'mas"});
    });

    test('同分时按源顺序，再按站点原始顺序（结果稳定）', () {
      final a = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [hit('AIR甲', siteId: '1'), hit('AIR乙', siteId: '2')],
      );
      final b = SiteSearchSourceResult(
        source: SiteSearchSource.twoDfan,
        hits: fanHits(['AIR丙']),
      );

      final first = SiteSearchRanker.rank([a, b], 'AIR');
      final second = SiteSearchRanker.rank([a, b], 'AIR');

      expect([for (final h in first.hits) h.title],
          ['AIR甲', 'AIR乙', 'AIR丙']);
      expect([for (final h in second.hits) h.title],
          [for (final h in first.hits) h.title]);
    });

    test('两源都没命中：各留 Top1，且都排在真命中之后', () {
      final a = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [hit('完全无关甲', siteId: '1'), hit('完全无关乙', siteId: '2')],
      );
      final b = SiteSearchSourceResult(
        source: SiteSearchSource.twoDfan,
        hits: fanHits(['air', 'AIR 命中']),
      );

      final ranked = SiteSearchRanker.rank([a, b], 'AIR');

      // 2DFan 的「AIR 命中」是前缀 85 分，排在兜底之前
      expect(ranked.hits.first.title, 'air'); // 精确 100，且在 2DFan 里排第 0
      expect(ranked.hits.map((h) => h.title).toList().last, '完全无关甲');
      expect(ranked.hits.length, 3); // air + AIR 命中 + 鲲的 Top1
    });

    test('失败源不参与排序也不进 hits', () {
      final failed = SiteSearchSourceResult.failed(
        SiteSearchSource.twoDfan,
        '请求超时',
      );
      final ok = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [hit('缘之空', siteId: '51')],
      );

      final ranked = SiteSearchRanker.rank([ok, failed], '缘之空');
      expect(ranked.hits.length, 1);
      expect(ranked.candidateCount, 1);
    });

    test('关键词为空时原样放行（不过滤不排序）', () {
      final a = SiteSearchSourceResult(
        source: SiteSearchSource.moyu,
        hits: [hit('甲', siteId: '1'), hit('乙', siteId: '2')],
      );
      final ranked = SiteSearchRanker.rank([a], '   ');
      expect([for (final h in ranked.hits) h.title], ['甲', '乙']);
      expect(ranked.candidateCount, 2);
      expect(ranked.filteredCount, 0);
    });

    test('全空输入不崩', () {
      final ranked = SiteSearchRanker.rank(const [], 'AIR');
      expect(ranked.hits, isEmpty);
      expect(ranked.candidateCount, 0);
      expect(ranked.filteredCount, 0);
    });
  });
}
