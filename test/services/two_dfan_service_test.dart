// 2Dfan 数据源解析单元测试（离线，不发真实网络请求）
//
// 夹具取自 2026-11-04 实测页面（2dfmax.top），只保留解析用到的结构：
// - 搜索页：`#subject-list .subject-card`（标题/评分/评价数/品牌/发售日期）
// - 详情页：`h1.subject-title`、`img.subject-cover-img`、`.intro-content`、
//   `.subject-meta-list .meta-row`、`.subject-tags-inline a.nexus-tag`、
//   `[data-island="SubjectRatingPanel"]` 的 data-props

import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

const String _searchHtml = r'''
<html><body>
<div id="subject-list" class="subject-list">
  <div class="subject-card" id="subject_card_11612">
    <div class="subject-card-aside">
      <div class="subject-card-cover">
        <a href="/subjects/11612">
          <img alt="美少女万華鏡異聞 雪おんな" src="https://img.achost.top/uploads/subjects/packages/normal_6a8caa0f.jpg" />
        </a>
      </div>
      <span class="subject-card-score">
        <span class="subject-card-score-value">4.6</span>
        <span class="subject-card-score-count">197人评价</span>
      </span>
    </div>
    <div class="subject-card-col">
      <div class="subject-card-info">
        <h3 class="subject-card-title"><a href="/subjects/11612">美少女万華鏡異聞 雪おんな</a></h3>
        <div class="subject-card-meta">
          <span class="subject-card-meta-item">
            <span class="subject-card-meta-label">品牌:</span>
            <span class="subject-card-meta-value"><a class="nexus-inline-link" href="/tags/star">ωstar</a></span>
          </span>
          <span class="subject-card-meta-item">
            <span class="subject-card-meta-label">发售日期:</span>
            <span class="subject-card-meta-value"><time datetime="2024-04-26">2024-04-26</time></span>
          </span>
        </div>
      </div>
    </div>
  </div>
  <div class="subject-card" id="subject_card_1471">
    <h3 class="subject-card-title"><a href="/subjects/1471">美少女万華鏡 -かつて少女だった君へ-</a></h3>
  </div>
  <!-- 非作品链接：必须被忽略 -->
  <div class="subject-card" id="subject_card_bad">
    <h3 class="subject-card-title"><a href="/subjects/search">搜索</a></h3>
  </div>
</div>
</body></html>
''';

const String _detailHtml = r'''
<html><head>
<title>美少女万華鏡異聞 雪おんな_美少女万华镜异闻 雪女_美少女万华镜6_美少女万华镜 番外_2DFan</title>
</head><body>
<h1 class="subject-title">美少女万華鏡異聞 雪おんな</h1>
<div class="subject-cover">
  <img class="subject-cover-img" alt="美少女万華鏡異聞 雪おんな" src="https://img.achost.top/uploads/subjects/packages/6a8caa0f.jpg" />
</div>
<dl class="subject-meta-list">
  <div class="meta-row"><dt>品牌</dt><dd><a class="nexus-inline-link" href="/tags/star">ωstar</a></dd></div>
  <div class="meta-row"><dt>发售日期</dt><dd>2024-04-26</dd></div>
  <div class="meta-row"><dt>声优</dt><dd><a class="nexus-inline-link">みたかりん</a><a class="nexus-inline-link">夏和小</a></dd></div>
</dl>
<div class="subject-tags-inline">
  <a class="nexus-tag" href="/tags/adv">ADV</a>
  <a class="nexus-tag" href="/tags/x">雪女</a>
  <a class="nexus-tag" href="/tags/x">恋爱</a>
  <a class="nexus-tag" href="/tags/x">汉化</a>
  <a class="nexus-tag" href="/tags/x">AI翻译</a>
</div>
<section class="subject-intro">
  <div class="intro-content">
    前言
    <p>美少女万华镜，新生！<br>八宝备仁策划兼原画。</p>
    <p>故事介绍<br>妖异，即迷人又令人恐惧。</p>
  </div>
</section>
<div data-island="SubjectRatingPanel"
     data-props="{&quot;subjectId&quot;:11612,&quot;score&quot;:4.6,&quot;ranksCount&quot;:197,&quot;ranksDistribution&quot;:{&quot;great&quot;:23}}">
  <span class="rating-score">4.6</span>
</div>
</body></html>
''';

/// 只有「开发商」的详情页（会社回退链的第一级）
const String _detailWithDeveloper = r'''
<html><head><title>純愛ギャル_纯爱辣妹_2DFan</title></head><body>
<h1 class="subject-title">純愛ギャル</h1>
<dl class="subject-meta-list">
  <div class="meta-row"><dt>开发商</dt><dd><a class="nexus-inline-link">テスト開発</a></dd></div>
  <div class="meta-row"><dt>发售日期</dt><dd>2023年5月1日</dd></div>
</dl>
</body></html>
''';

void main() {
  group('搜索结果页解析', () {
    test('提取 id/title/评分/评价数/品牌/发售日期，并忽略非作品链接', () {
      final items = TwoDFanService.parseSearchResultsForTest(_searchHtml);
      expect(items.length, 2, reason: '/subjects/search 不是作品，应被剔除');

      final first = items.first;
      expect(first['id'], '11612');
      expect(first['name'], '美少女万華鏡異聞 雪おんな');
      expect(first['rating'], '4.6');
      expect(first['vote_count'], '197人评价');
      expect(first['brand'], 'ωstar');
      expect(first['release_date'], '2024-04-26');
      expect(first['cover_url'],
          contains('img.achost.top/uploads/subjects/packages/normal_'));
    });

    test('缺失评分/日期的卡片不崩，字段为空串', () {
      final items = TwoDFanService.parseSearchResultsForTest(_searchHtml);
      final second = items[1];
      expect(second['id'], '1471');
      expect(second['rating'], '');
      expect(second['release_date'], '');
    });
  });

  group('详情页解析', () {
    test('中文优先：主标题取中文译名，日文原名作副标题，其余进别名', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.isValid, isTrue);
      expect(r.game.id, '11612');
      expect(r.game.name, '美少女万华镜异闻 雪女',
          reason: '<title> 里第一个无假名的 CJK 片段');
      expect(r.game.originalTitle, '美少女万華鏡異聞 雪おんな',
          reason: 'h1 应为副标题（原版标题）');
      expect(r.game.aliasNames, isNotNull);
      expect(r.game.aliasNames, contains('美少女万华镜6'));
      expect(r.game.aliasNames, contains('美少女万华镜 番外'));
      expect(r.game.aliasNames, isNot(contains('2DFan')),
          reason: '尾部站名必须剔除');
      expect(r.game.aliasNames, isNot(contains(r.game.name)),
          reason: '别名不应重复主标题');
      expect(r.game.aliasNames, isNot(contains(r.game.originalTitle)));
    });

    test('会社回退：无「开发商」时取「品牌」', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.game.company, 'ωstar');
    });

    test('会社优先「开发商」，日期日式格式归一为 YYYY-MM-DD', () {
      final r = TwoDFanService.parseDetailForTest(_detailWithDeveloper,
          id: '99', base: 'https://2dfmax.top');
      expect(r.game.company, 'テスト開発');
      expect(r.game.releaseDate, '2023-05-01');
      expect(r.game.name, '纯爱辣妹');
      expect(r.game.originalTitle, '純愛ギャル');
    });

    test('评分 5 分制 ×2 归一到 10 分制，投票数取 ranksCount', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.game.rating, closeTo(9.2, 0.001));
      expect(r.game.voteCount, 197);
      expect(r.game.sourceType, SourceType.twoDfan);
      expect(r.game.sourceId, '11612');
    });

    test('封面为 CDN 绝对地址，直接采用', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.game.coverUrl,
          'https://img.achost.top/uploads/subjects/packages/6a8caa0f.jpg');
    });

    test('简介把 <p>/<br> 转成换行，且不残留标签', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.game.summary, contains('美少女万华镜，新生！'));
      expect(r.game.summary, contains('\n'));
      expect(r.game.summary, isNot(contains('<p>')));
      expect(r.game.summary, isNot(contains('&nbsp;')));
    });

    test('标签过滤「汉化/AI翻译」等资源属性标签', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      final names = r.tags.map((t) => t.name).toList();
      expect(names, containsAll(<String>['ADV', '雪女', '恋爱']));
      expect(names, isNot(contains('汉化')));
      expect(names, isNot(contains('AI翻译')));
      expect(r.tags.every((t) => t.source == '2Dfan'), isTrue);
      expect(r.tags.every((t) => t.weight == 1.0), isTrue);
    });

    test('2Dfan 不提供截图与横幅', () {
      final r = TwoDFanService.parseDetailForTest(_detailHtml);
      expect(r.game.screenshotUrls, isEmpty);
      expect(r.game.bannerUrl, isNull);
    });

    test('页面无 h1 时判定为无效结果', () {
      final r = TwoDFanService.parseDetailForTest('<html><body></body></html>');
      expect(r.isValid, isFalse);
    });
  });

  group('域名回退配置', () {
    test('镜像优先，污染主域 2dfan.com 垫底', () {
      // 2026-11-04 修正：2dfan.com 在国内 DNS 被污染到 128.242.250.148，
      // 且处于「首页可能 200、/search 与 /subjects/* 必超时」的半通状态。
      // 它曾排首位，探测一旦通过即锁定，导致整个会话搜索全废。
      expect(TwoDFanService.kFanDomains.first, isNot('https://2dfan.com'));
      expect(TwoDFanService.kFanDomains.last, 'https://2dfan.com');
      expect(TwoDFanService.kFanDomains.length, greaterThanOrEqualTo(2));
      expect(TwoDFanService.kFanDomains.every((d) => d.startsWith('https://')),
          isTrue);
    });

    test('重置接口同时清空坏域名表', () {
      TwoDFanService.resetResolvedBaseForTest('https://2dfan.com');
      expect(TwoDFanService.resolvedBaseForTest, 'https://2dfan.com');
      TwoDFanService.resetResolvedBaseForTest();
      expect(TwoDFanService.resolvedBaseForTest, isNull);
      expect(TwoDFanService.badDomainsForTest, isEmpty);
    });
  });
}
