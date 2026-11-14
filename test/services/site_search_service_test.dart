import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'package:chrono_tide/services/site_search/site_search_service.dart';

/// 全站搜索（SITE-SEARCH）离线测试
///
/// 覆盖三件事：
/// 1. 命中模型的口径（uid / 年份 / 副标题 / 元数据映射）；
/// 2. 聚合层的并发合并顺序、单源失败隔离、全失败不缓存；
/// 3. 缓存与防重入（连点两次按钮只能打一次站点）。
///
/// 🔴 全部走注入的假实现，**不发任何网络请求**（站点抓取有随机性，
/// 联网测试会变成 flaky）。
void main() {
  SiteSearchHit hit(
    SiteSearchSource source,
    String siteId,
    String title, {
    double rating = 0,
    String? releaseDate,
    String? coverUrl,
  }) =>
      SiteSearchHit(
        source: source,
        siteId: siteId,
        title: title,
        rating: rating,
        releaseDate: releaseDate,
        coverUrl: coverUrl,
      );

  group('SiteSearchHit 模型', () {
    test('uid 由 站点 + siteId 组成，跨站点同 id 不撞车', () {
      final a = hit(SiteSearchSource.moyu, '68', 'A');
      final b = hit(SiteSearchSource.twoDfan, '68', 'B');
      expect(a.uid, 'moyu:68');
      expect(b.uid, '2dfan:68');
      expect(a.uid == b.uid, isFalse);
    });

    test('releaseYear 取前四位；不足四位视为无数据', () {
      expect(hit(SiteSearchSource.moyu, '1', 'A', releaseDate: '2017-07-28')
          .releaseYear, 2017);
      // 只有年份的精度（NextMoe release_date_precision=year）也应能取到
      expect(hit(SiteSearchSource.moyu, '1', 'A', releaseDate: '2017')
          .releaseYear, 2017);
      expect(hit(SiteSearchSource.moyu, '1', 'A').releaseYear, null);
      expect(hit(SiteSearchSource.moyu, '1', 'A', releaseDate: '20')
          .releaseYear, null);
    });

    test('subtitle 优先原版标题，其次首个别名，同主标题则跳过', () {
      const base = SiteSearchHit(
        source: SiteSearchSource.moyu,
        siteId: '1',
        title: '雪女',
        originalTitle: '雪おんな',
      );
      expect(base.subtitle, '雪おんな');

      const aliased = SiteSearchHit(
        source: SiteSearchSource.moyu,
        siteId: '1',
        title: '雪女',
        aliasNames: ['雪女', 'Yuki Onna'],
      );
      expect(aliased.subtitle, 'Yuki Onna');

      const none = SiteSearchHit(
        source: SiteSearchSource.moyu,
        siteId: '1',
        title: '雪女',
      );
      expect(none.subtitle, null);
    });

    test('isValid 要求 siteId 与 title 都非空', () {
      expect(hit(SiteSearchSource.moyu, '', 'A').isValid, isFalse);
      expect(hit(SiteSearchSource.moyu, '1', '').isValid, isFalse);
      expect(hit(SiteSearchSource.moyu, '1', 'A').isValid, isTrue);
    });

    test('fromMetadataResult 做字段改名，不二次改写标题/评分', () {
      final result = MetadataResult(
        game: Game(
          id: '68',
          name: '美少女万华镜 -罪与罚的少女-',
          originalTitle: '美少女万華鏡 -罪と罰の少女-',
          aliasNames: const ['Bishoujo Mangekyou'],
          coverUrl: 'https://image.example/cover.webp',
          company: 'ωstar',
          summary: '简介',
          rating: 8.4,
          voteCount: 2535,
          releaseDate: '2017-07-28',
          sourceType: SourceType.nextmoe,
          sourceId: '68',
        ),
        tags: const [TagItem(name: '拔作', source: 'bangumi', weight: 1)],
      );

      final h = SiteSearchHit.fromMetadataResult(
        SiteSearchSource.moyu,
        result,
        detailUrl: 'https://www.kungal.com/search?keywords=x',
        nsfw: true,
        detailLoaded: true,
      );

      expect(h.siteId, '68');
      expect(h.title, '美少女万华镜 -罪与罚的少女-');
      expect(h.originalTitle, '美少女万華鏡 -罪と罰の少女-');
      expect(h.aliasNames, ['Bishoujo Mangekyou']);
      expect(h.developer, 'ωstar');
      expect(h.rating, 8.4);
      expect(h.voteCount, 2535);
      expect(h.tags, ['拔作']);
      expect(h.nsfw, isTrue);
      expect(h.detailLoaded, isTrue);
    });

    test('SiteSearchSource.fromKey 未知值返回 null（老数据可读）', () {
      expect(SiteSearchSource.fromKey('moyu'), SiteSearchSource.moyu);
      expect(SiteSearchSource.fromKey('2dfan'), SiteSearchSource.twoDfan);
      expect(SiteSearchSource.fromKey('dlsite'), null);
      expect(SiteSearchSource.fromKey(''), null);
    });
  });

  group('站点映射（真实页面结构 fixture，不发网络）', () {
    // 与 test/services/two_dfan_service_test.dart 同一份真实搜索页结构，
    // 只为验证「卡片 map → SiteSearchHit」这层映射（评分 ×2 / 评价数正则）。
    const fanHtml = r'''
<div id="subject-list" class="subject-list">
  <div class="subject-card" id="subject_card_11612">
    <div class="subject-card-cover">
      <a href="/subjects/11612">
        <img src="https://img.achost.top/uploads/subjects/normal_6a8.jpg" />
      </a>
    </div>
    <span class="subject-card-score">
      <span class="subject-card-score-value">4.6</span>
      <span class="subject-card-score-count">197人评价</span>
    </span>
    <h3 class="subject-card-title"><a href="/subjects/11612">美少女万華鏡異聞 雪おんな</a></h3>
    <span class="subject-card-meta-item">
      <span class="subject-card-meta-label">品牌:</span>
      <span class="subject-card-meta-value"><a class="nexus-inline-link">ωstar</a></span>
    </span>
    <span class="subject-card-meta-item">
      <span class="subject-card-meta-label">发售日期:</span>
      <span class="subject-card-meta-value"><time datetime="2024-04-26">2024-04-26</time></span>
    </span>
  </div>
  <div class="subject-card" id="subject_card_1471">
    <h3 class="subject-card-title"><a href="/subjects/1471">美少女万華鏡 -かつて少女だった君へ-</a></h3>
  </div>
</div>
''';

    test('2DFan 卡片 → 命中：5 分制 ×2、评价数取数字、品牌/发售日/封面就位', () {
      final cards = TwoDFanService.parseSearchResultsForTest(fanHtml);
      expect(cards.length, 2);

      final hit = TwoDFanService.parseSearchHitForTest(cards.first);
      expect(hit, isNotNull);
      expect(hit!.siteId, '11612');
      expect(hit.title, '美少女万華鏡異聞 雪おんな');
      // 站点 5 分制 4.6 → 归一 9.2（与详情页同口径）
      expect(hit.rating, closeTo(9.2, 0.001));
      expect(hit.voteCount, 197);
      expect(hit.developer, 'ωstar');
      expect(hit.releaseDate, '2024-04-26');
      expect(hit.coverUrl, startsWith('https://img.achost.top'));
      expect(hit.source, SiteSearchSource.twoDfan);
      expect(hit.nsfw, isTrue);
      // 列表卡片态：详情还没拉过
      expect(hit.detailLoaded, isFalse);
      expect(hit.detailUrl, 'https://2dfmax.top/subjects/11612');
    });

    test('2DFan 缺评分/日期的卡片：0 与 null，不伪造数据', () {
      final cards = TwoDFanService.parseSearchResultsForTest(fanHtml);
      final hit = TwoDFanService.parseSearchHitForTest(cards[1])!;
      expect(hit.rating, 0);
      expect(hit.voteCount, null);
      expect(hit.releaseDate, null);
      expect(hit.coverUrl, null);
      expect(hit.title, '美少女万華鏡 -かつて少女だった君へ-');
    });

    test('NextMoe work JSON → 命中：中文标题、评分归一、元标签剔除、R18', () {
      final hit = NextMoeService.parseSearchHitForTest(const {
        'id': '68',
        'display_name': '美少女万華鏡 -罪と罰の少女-',
        'localized': {
          'ja': {'value': '美少女万華鏡 -罪と罰の少女-'},
          'zh-Hans': {'value': '美少女万华镜 -罪与罚的少女-'},
        },
        'content_rating': 'r18',
        'release_date': '2017-07-28',
        'cover': {'url': 'https://image.kungal.iloveren.link/a.webp'},
        'companies': [
          {'display_name': 'ωstar', 'attribution_role': 'developer'},
        ],
        'ratings': [
          {'source': 'vndb', 'score': 7.13, 'vote_count': 2535},
          {'source': 'bangumi', 'score': 6.9, 'vote_count': 4686},
        ],
        'tags': [
          {
            'display_name': '拔作',
            'source': 'bangumi',
            'tier': 'core',
            'tag_kind': 'content',
            'spoiler': 'none',
          },
          {
            // 平台元标签：必须被剔除
            'display_name': 'Galgame',
            'source': 'bangumi',
            'tier': 'hidden',
            'tag_kind': 'meta',
            'spoiler': 'none',
          },
        ],
      });

      expect(hit, isNotNull);
      expect(hit!.siteId, '68');
      expect(hit.title, '美少女万华镜 -罪与罚的少女-');
      expect(hit.originalTitle, '美少女万華鏡 -罪と罰の少女-');
      expect(hit.developer, 'ωstar');
      expect(hit.rating, closeTo(7.13, 0.001));
      expect(hit.voteCount, 2535);
      expect(hit.releaseDate, '2017-07-28');
      expect(hit.tags, ['拔作']);
      expect(hit.nsfw, isTrue);
      expect(hit.source, SiteSearchSource.moyu);
      // 鲲没有 NextMoe 作品网页 → 落到鲲站内搜索页
      expect(hit.detailUrl, contains('kungal.com/search'));
    });
  });

  group('SiteSearchService 聚合', () {
    test('空关键词直接返回空结果，不打站点', () async {
      var called = 0;
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async {
          called++;
          return const <SiteSearchHit>[];
        },
        fanSearch: (_) async {
          called++;
          return const <SiteSearchHit>[];
        },
      );

      final outcome = await service.search('   ');
      expect(outcome.isEmpty, isTrue);
      expect(called, 0);
    });

    test('两源结果按 鲲 → 2DFan 顺序拼接', () async {
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async => [
          hit(SiteSearchSource.moyu, '1', '鲲A'),
          hit(SiteSearchSource.moyu, '2', '鲲B'),
        ],
        fanSearch: (_) async => [
          hit(SiteSearchSource.twoDfan, '9', 'FAN'),
        ],
      );

      final outcome = await service.search('测试');
      expect(outcome.hits.map((h) => h.uid).toList(),
          ['moyu:1', 'moyu:2', '2dfan:9']);
      expect(outcome.perSource.length, 2);
      expect(outcome.allFailed, isFalse);
      expect(outcome.failureSummary, null);
    });

    test('单源抛异常不影响另一源，且失败原因可读', () async {
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async => throw TimeoutException('slow'),
        fanSearch: (_) async => [hit(SiteSearchSource.twoDfan, '9', 'FAN')],
      );

      final outcome = await service.search('测试');
      expect(outcome.hits.length, 1);
      expect(outcome.hits.single.source, SiteSearchSource.twoDfan);
      expect(outcome.allFailed, isFalse);
      expect(outcome.failureSummary, contains('鲲'));
      expect(outcome.failureSummary, contains('超时'));
    });

    test('空结果算成功，不算失败（不污染提示条）', () async {
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async => const <SiteSearchHit>[],
        fanSearch: (_) async => const <SiteSearchHit>[],
      );

      final outcome = await service.search('没收录的词');
      expect(outcome.isEmpty, isTrue);
      expect(outcome.allFailed, isFalse);
      expect(outcome.failureSummary, null);
    });

    test('全失败：allFailed=true 且不写缓存（断网不会钉住 5 分钟）', () async {
      var calls = 0;
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async {
          calls++;
          throw StateError('鲲不可达');
        },
        fanSearch: (_) async {
          calls++;
          throw StateError('2DFan 全部域名不可达');
        },
      );

      final first = await service.search('测试');
      expect(first.allFailed, isTrue);
      expect(service.cacheSizeForTest, 0);

      await service.search('测试');
      expect(calls, 4); // 第二次仍然真的去问了
    });

    test('缓存命中：5 分钟内同词只打一次站点', () async {
      var calls = 0;
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async {
          calls++;
          return [hit(SiteSearchSource.moyu, '1', 'A')];
        },
        fanSearch: (_) async {
          calls++;
          return const <SiteSearchHit>[];
        },
      );

      final first = await service.search('测试');
      expect(first.fromCache, isFalse);

      final second = await service.search('  测试  ');
      expect(second.fromCache, isTrue);
      expect(calls, 2); // 首轮各一次，第二轮全命中缓存

      final forced = await service.search('测试', forceRefresh: true);
      expect(forced.fromCache, isFalse);
      expect(calls, 4);
    });

    test('防重入：并发同词只打一次站点', () async {
      var calls = 0;
      final gate = Completer<void>();
      final service = SiteSearchService.forTest(
        moyuSearch: (_) async {
          calls++;
          await gate.future;
          return [hit(SiteSearchSource.moyu, '1', 'A')];
        },
        fanSearch: (_) async => const <SiteSearchHit>[],
      );

      final f1 = service.search('测试');
      final f2 = service.search('测试');
      gate.complete();
      final r1 = await f1;
      final r2 = await f2;

      expect(calls, 1);
      expect(r1.hits.length, r2.hits.length);
    });

    test('详情失败时原样返回旧对象（detailLoaded 仍为 false，UI 可重试）',
        () async {
      final service = SiteSearchService.forTest(
        detailFetch: (source, siteId) async => null,
      );
      final base = hit(SiteSearchSource.moyu, '68', 'A');

      final result = await service.fetchDetail(base);
      expect(result.uid, base.uid);
      expect(result.detailLoaded, isFalse);
    });

    test('详情成功：缺字段时用卡片态兜底，不让好数据变空', () async {
      final service = SiteSearchService.forTest(
        detailFetch: (source, siteId) async => const SiteSearchHit(
          source: SiteSearchSource.moyu,
          siteId: '68',
          title: 'A',
          summary: '完整简介',
          rating: 0, // 详情没给评分
          detailLoaded: true,
        ),
      );

      final base = hit(
        SiteSearchSource.moyu,
        '68',
        'A',
        rating: 8.8,
        releaseDate: '2017-07-28',
        coverUrl: 'https://image.example/c.webp',
      );

      final result = await service.fetchDetail(base);
      expect(result.summary, '完整简介');
      expect(result.rating, 8.8);
      expect(result.releaseDate, '2017-07-28');
      expect(result.coverUrl, 'https://image.example/c.webp');
      expect(result.detailLoaded, isTrue);
    });

    test('详情已拉过则直接返回，不再请求', () async {
      var calls = 0;
      final service = SiteSearchService.forTest(
        detailFetch: (source, siteId) async {
          calls++;
          return hit(SiteSearchSource.moyu, siteId, 'A');
        },
      );
      final base = hit(SiteSearchSource.moyu, '68', 'A');

      await service.fetchDetail(base.copyWith(detailLoaded: true));
      expect(calls, 0);
    });

    test('normalizeKeyword：小写 + 折叠连续空白 + 去首尾', () {
      expect(SiteSearchService.normalizeKeyword('  Re:Zero   '), 're:zero');
      expect(SiteSearchService.normalizeKeyword('美少女  万华镜'), '美少女 万华镜');
    });
  });
}
