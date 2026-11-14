import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:html/parser.dart' as html_parser;

import '../models/game.dart';
import '../models/site_search_hit.dart';
import '../models/tags.dart';
import 'metadata_base.dart';
import 'two_dfan_cookie.dart';

/// 2Dfan 数据源服务
///
/// **接入形态**：HTML 抓取（站点无公开 API），参考同行项目 GalGear 的
/// `providers.rs::search_fan / parse_metadata` 实现，并按实测页面结构校正。
///
/// **站点**：`2dfan.com`（主域，国内 DNS 污染 + 半通）+ 4 个镜像。
/// 按 [kFanDomains] 顺序探测（镜像优先），并通过 [_getHtml] 的**运行期
/// 回退**在请求失败时立即切换域名——不依赖一次性探测的运气。
///
/// **端点**：
/// - 搜索：`GET {base}/search?keyword={kw}`（20 条/页）
///   - 卡片：`#subject-list .subject-card`（`id="subject_card_{subjectId}"`）
///   - 标题：`.subject-card-title a`（href = `/subjects/{id}`）
///   - 评分：`.subject-card-score-value` / `.subject-card-score-count`（"197人评价"）
///   - 品牌 / 发售日期：`.subject-card-meta-item`（label + value，日期在 `time[datetime]`）
/// - 详情：`GET {base}/subjects/{id}`
///   - 标题：`h1.subject-title`；别名：`<title>` 的 `_` 分隔串（尾部 `2DFan` 需剔除）
///   - 封面：`img.subject-cover-img`（CDN `img.achost.top`，绝对地址）
///   - 简介：`.intro-content`（含 `<p>` / `<br>`，需转纯文本）
///   - 会社 / 发售日：`.subject-meta-list .meta-row`（`dt` 标签 + `dd` 值，
///     dd 内多为 `<a class="nexus-inline-link">`）
///   - 标签：`.subject-tags-inline a.nexus-tag`
///   - 评分/投票数：`[data-island="SubjectRatingPanel"]` 的 `data-props` JSON
///     （`score` 0–5 分制、`ranksCount` 评价人数），属性值已由 HTML 解析器解码
///
/// **数据范围**：中文/日文标题、多别名、封面、简介、会社、发售日、评分、
/// 投票数、中文标签。**无截图、无横幅**（站点不上传这两类素材）。
///
/// **主标题口径（2026-11-04 决策）**：中文优先——`<title>` 别名串里挑
/// 第一个「含 CJK 且无假名」的片段作主标题，`h1` 原文作副标题（原版标题），
/// 其余片段全部进别名列表。理由：h1 多为日文原名，而 MIX 主标题链里
/// 2Dfan 高于 VNDB/KunGal，若直接取 h1 会把日文名顶成中文主标题。
///
/// **标签口径**：过滤「汉化 / AI翻译 / 普通机翻 / 官方中文」这类**资源属性**
/// 标签（它们描述的是搬运补丁的语言状态，不是作品属性），与 NextMoe 剔除
/// `tag_kind=meta` 的做法一致。
class TwoDFanService implements MetadataSourceService {
  final Dio _dio;

  /// 候选域名（顺序即优先级）。首个探测成功的会在会话内缓存复用。
  ///
  /// ⚠️ `2dfan.com`（主域）在中国大陆网络下 **DNS 被污染**（解析到
  /// `128.242.250.148`），且处于「半通」状态：首页有时能 200，紧随其后的
  /// `/search`、`/subjects/*` 却必然连接超时。它曾排在第一位，导致
  /// `_resolveBase()` 探测通过后锁定，之后**整个会话所有搜索全废**
  /// （用户侧表现＝「2Dfan 突然搜不到了」）。故降到**最后一位**只作兜底。
  static const List<String> kFanDomains = [
    'https://2dfmax.top',
    'https://fan2d.top',
    'https://acgfan.top',
    'https://2dfdf.de',
    'https://2dfan.com',
  ];

  /// 会话内解析出的可用基址（null = 尚未探测出结果）
  static String? _resolvedBase;

  /// 进程内已判定不可用的域名。某域名请求失败即计入，后续探测跳过；
  /// 全部计入时清空重来（网络恢复后仍有机会复活）。
  static final Set<String> _badDomains = {};

  /// 全部域名探测失败的时刻。只做**软记忆**（[kAllFailedCooldown] 内不再重探），
  /// 而不是永久置空——永久置空会让一次网络抖动废掉整个会话。
  static DateTime? _allFailedAt;

  static const Duration kAllFailedCooldown = Duration(minutes: 2);

  /// 单次请求的域名切换上限（防止在多个坏域名间死循环）
  static const int kMaxFallbackAttempts = 5;

  TwoDFanService({Dio? dio})
      : _dio = Dio(BaseOptions(
          // 实测镜像域名应答均在 0.8–2.5s，连接收紧到 4s：
          // 域名回退时最坏 5×4s，且坏域名会被立即跳过复用
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'zh-CN,zh;q=0.9,ja;q=0.8',
          },
        )) {
    // 与其余源一致：继承全局智能代理配置（可用代理→走代理；无代理→直连）
    applyProxyConfig(dio, _dio);
  }

  @override
  SourceType get sourceType => SourceType.twoDfan;

  @override
  String get sourceName => '2Dfan';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  /// 仅供单元测试 / 离线探针：重置域名解析缓存（含坏域名表与冷却时间）
  static void resetResolvedBaseForTest([String? base]) {
    _resolvedBase = base;
    _badDomains.clear();
    _allFailedAt = null;
  }

  /// 仅供单元测试 / 离线探针：读取当前锁定的基址
  @visibleForTesting
  static String? get resolvedBaseForTest => _resolvedBase;

  /// 仅供单元测试 / 离线探针：读取被判坏的域名
  @visibleForTesting
  static Set<String> get badDomainsForTest => Set.unmodifiable(_badDomains);

  /// 仅供单元测试 / 离线探针：解析搜索结果页（不发网络请求）
  @visibleForTesting
  static List<Map<String, dynamic>> parseSearchResultsForTest(String body) =>
      TwoDFanService()._parseSearchResults(body);

  /// 仅供单元测试 / 离线探针：解析详情页（不发网络请求）
  @visibleForTesting
  static MetadataResult parseDetailForTest(
    String body, {
    String base = 'https://2dfmax.top',
    String id = '11612',
    Map<String, dynamic> candidate = const {},
  }) =>
      TwoDFanService()._parseDetail(body, base, id, candidate);

  @override
  Future<bool> testConnection() async {
    try {
      // 用搜索端点探测：既验证站点可达，也验证搜索功能真的能用
      final page = await _getHtml('/search', query: {'keyword': 'test'});
      return page.response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    final keyword = name.trim();
    if (keyword.isEmpty) return _emptyResult();

    try {
      // 1) 搜索
      final searchPage = await _getHtml(
        '/search',
        query: {'keyword': keyword},
      );
      if (searchPage.response.statusCode != 200) {
        fetchLog('[2Dfan] 搜索返回 ${searchPage.response.statusCode} [$keyword]');
        return _emptyResult();
      }

      final candidates =
          _parseSearchResults(searchPage.response.data.toString());
      if (candidates.isEmpty) {
        fetchLog('[2Dfan] 搜索无结果 [$keyword]');
        return _emptyResult();
      }

      final candidate = _pickBestMatch(candidates, keyword);
      final id = (candidate['id'] ?? '').toString();
      if (id.isEmpty) return _emptyResult();

      // 2) 详情
      final detailPage = await _getHtml('/subjects/$id');
      if (detailPage.response.statusCode != 200) {
        fetchLog('[2Dfan] 详情返回 ${detailPage.response.statusCode} [id=$id]');
        return _emptyResult();
      }

      return _parseDetail(
        detailPage.response.data.toString(),
        detailPage.base,
        id,
        candidate,
      );
    } catch (e) {
      fetchLog('[2Dfan] 查询失败 [$name]: $e');
      return _emptyResult();
    }
  }

  // ==================== 域名回退 ====================

  /// 带**运行期域名回退**的 HTML 请求。
  ///
  /// 仅靠一次性探测是不够的：`2dfan.com` 实测会出现「首页 200、子路径超时」
  /// 的半通状态，探测通过后被锁定，整个会话就废了。所以每次请求失败都会
  /// 把当前域名计入 [_badDomains] 并立刻换下一个重试。
  Future<_FanPage> _getHtml(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    Object? lastError;
    // 🔴 登录态 Cookie（用户在设置 → 元数据 里填的）：未填时为 null，
    // 与旧行为完全一致；填了则每个请求都带上，提高命中率。
    final String? cookie = await TwoDFanCookieStore.load();
    for (var attempt = 0; attempt < kMaxFallbackAttempts; attempt++) {
      final base = await _resolveBase();
      if (base == null) {
        throw StateError('所有 2Dfan 域名均不可达: ${kFanDomains.join(", ")}');
      }
      try {
        final response = await executeRateLimited<String>(
          SourceType.twoDfan,
          () => _dio.get<String>(
            '$base$path',
            queryParameters: query,
            options: Options(
              responseType: ResponseType.plain,
              headers: cookie == null
                  ? null
                  : <String, dynamic>{'Cookie': cookie},
            ),
          ),
        );
        // 5xx 视为该域名不可用；2xx/4xx 是有效应答（404 表示条目真的不存在）
        if ((response.statusCode ?? 0) >= 500) {
          lastError = 'HTTP ${response.statusCode}';
          _markBadDomain(base, '$path 返回 ${response.statusCode}');
          continue;
        }
        return _FanPage(base, response);
      } catch (e) {
        lastError = e;
        _markBadDomain(base, '$path 异常: ${e.toString().split('\n').first}');
      }
    }
    throw StateError('2Dfan 域名切换 ${kMaxFallbackAttempts} 次仍失败: $lastError');
  }

  /// 标记域名为坏并撤销锁定，让下一次 [_resolveBase] 重新选
  static void _markBadDomain(String base, String reason) {
    _badDomains.add(base);
    if (_resolvedBase == base) _resolvedBase = null;
    fetchLog('[2Dfan] ⚠️ 域名不可用，切换下一个: $base ($reason)');
  }

  /// 解析可用基址：按 [kFanDomains] 顺序探测，首个通过校验即锁定并缓存。
  ///
  /// 校验不止看 200：还要内容确实是 2Dfan 站点（防 DNS 污染 / 运营商
  /// 停靠页返回 200 的情况）。全部失败时记下时间戳，冷却期内不再重探。
  Future<String?> _resolveBase() async {
    final cached = _resolvedBase;
    if (cached != null && cached.isNotEmpty && !_badDomains.contains(cached)) {
      return cached;
    }

    final failedAt = _allFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < kAllFailedCooldown) {
      return null;
    }

    var candidates =
        kFanDomains.where((d) => !_badDomains.contains(d)).toList();
    if (candidates.isEmpty) {
      // 全部域名都被判过坏：清空重来，给网络恢复后的域名一次机会
      _badDomains.clear();
      candidates = List<String>.of(kFanDomains);
    }

    for (final domain in candidates) {
      try {
        final response = await _dio.get(
          '$domain/',
          options: Options(
            responseType: ResponseType.plain,
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        if (response.statusCode != 200) continue;
        final body = response.data.toString();
        // 内容校验：首页必须包含站点特征，否则是被劫持/停靠页
        final looksLikeFan = body.contains('subject-card') ||
            body.toLowerCase().contains('2dfan');
        if (!looksLikeFan) {
          _badDomains.add(domain);
          fetchLog('[2Dfan] ⚠️ 域名返回非站点内容，跳过: $domain');
          continue;
        }
        _resolvedBase = domain;
        _allFailedAt = null;
        fetchLog('[2Dfan] ✅ 站点基址锁定: $domain');
        return domain;
      } catch (_) {
        // 换下一个域名
      }
    }

    _resolvedBase = null;
    _allFailedAt = DateTime.now();
    fetchLog('[2Dfan] ⚠️ 全部域名探测失败（${kAllFailedCooldown.inMinutes} 分钟后可重试）');
    return null;
  }

  // ==================== 搜索页解析 ====================

  List<Map<String, dynamic>> _parseSearchResults(String body) {
    final doc = html_parser.parse(body);
    var cards = doc.querySelectorAll('#subject-list .subject-card');
    if (cards.isEmpty) cards = doc.querySelectorAll('.subject-card');

    final out = <Map<String, dynamic>>[];
    for (final card in cards) {
      final anchor = card.querySelector('.subject-card-title a');
      final href = anchor?.attributes['href'] ?? '';
      final id = _subjectIdFromHref(href) ??
          RegExp(r'(\d+)').firstMatch(card.id)?.group(1) ??
          '';
      final title = _clean(anchor?.text ?? '');
      if (id.isEmpty || title.isEmpty) continue;
      if (out.any((e) => e['id'] == id)) continue;

      final cover = _clean(
          card.querySelector('.subject-card-cover img')?.attributes['src'] ?? '');

      out.add({
        'id': id,
        'name': title,
        'cover_url': cover,
        'rating': _clean(
            card.querySelector('.subject-card-score-value')?.text ?? ''),
        'vote_count': _clean(
            card.querySelector('.subject-card-score-count')?.text ?? ''),
        'brand': _metaItemValue(card, '品牌'),
        'release_date': _metaItemValue(card, '发售日期'),
      });
    }
    return out;
  }

  /// 从 `.subject-card-meta-item` 里按标签取 value 文本
  String _metaItemValue(dynamic card, String label) {
    final items = card.querySelectorAll('.subject-card-meta-item');
    for (final item in items) {
      final labelText = _clean(
              item.querySelector('.subject-card-meta-label')?.text ?? '')
          .replaceAll(RegExp(r'[:：]$'), '');
      if (labelText != label) continue;
      final time = item.querySelector('time');
      final dateAttr = time?.attributes['datetime'];
      if (dateAttr != null && dateAttr.trim().isNotEmpty) {
        return dateAttr.trim();
      }
      return _clean(item.querySelector('.subject-card-meta-value')?.text ?? '');
    }
    return '';
  }

  String? _subjectIdFromHref(String href) {
    final match = RegExp(r'/subjects/(\d+)').firstMatch(href);
    return match?.group(1);
  }

  // ==================== 详情页解析 ====================

  MetadataResult _parseDetail(
    String body,
    String base,
    String id,
    Map<String, dynamic> candidate,
  ) {
    final doc = html_parser.parse(body);

    final heading = _clean(doc.querySelector('h1.subject-title')?.text ??
        doc.querySelector('h1')?.text ??
        '');
    if (heading.isEmpty) return _emptyResult();

    // 别名单：<title> 以 `_` 分隔多个译名，尾部固定带站名
    final names = _aliasesFromTitle(doc.querySelector('title')?.text ?? '');
    final mainTitle = _pickChineseTitle(names) ?? heading;
    final originalTitle = mainTitle == heading ? null : heading;
    final aliasNames = <String>[];
    for (final n in names) {
      if (n == mainTitle || n == originalTitle) continue;
      if (aliasNames.contains(n)) continue;
      aliasNames.add(n);
    }

    // 封面（CDN 绝对地址，兜底补 base）
    var cover = _clean(
        doc.querySelector('img.subject-cover-img')?.attributes['src'] ?? '');
    if (cover.startsWith('/')) cover = '$base$cover';
    if (cover.isEmpty) cover = (candidate['cover_url'] ?? '').toString();

    // 简介（.intro-content 内含 <p>/<br>，转纯文本保留段落）
    final introEl = doc.querySelector('.intro-content') ??
        doc.querySelector('.subject-description');
    final summary = introEl == null ? '' : _textOfHtml(introEl.innerHtml);

    // 会社：开发商 → 品牌 → 发行商 逐级回退（多数条目只有「品牌」）
    final meta = _parseMetaRows(doc);
    final company = _firstNonEmpty([
      meta['开发商'],
      meta['品牌'],
      meta['发行商'],
      meta['发行'],
      meta['发行品牌'],
      (candidate['brand'] ?? '').toString(),
    ]);

    final releaseDate = _normalizeDate(_firstNonEmpty([
      meta['发售日期'],
      meta['发行日期'],
      (candidate['release_date'] ?? '').toString(),
    ]));

    // 评分 / 投票数：SSR 数据岛优先，页面文本兜底
    final ratingPanel = _parseRatingIsland(doc);
    final score5 = ratingPanel?['score'] as num?;
    final ranksCount = ratingPanel?['ranksCount'] as num?;

    var rating = 0.0;
    if (score5 != null && score5 > 0) {
      // 站点为 5 分制 → ×2 归一到 10 分制
      rating = normalizeRating(score5.toDouble() * 2);
    } else {
      final text = _clean(doc.querySelector('.rating-score')?.text ?? '');
      final parsed = double.tryParse(text);
      if (parsed != null && parsed > 0) {
        rating = normalizeRating(parsed * 2);
      }
    }

    int? voteCount = ranksCount?.toInt();
    if (voteCount == null || voteCount <= 0) {
      final m =
          RegExp(r'(\d+)').firstMatch((candidate['vote_count'] ?? '').toString());
      voteCount = m == null ? null : int.tryParse(m.group(1)!);
    }

    // 标签
    final tags = <TagItem>[];
    for (final a in doc.querySelectorAll('.subject-tags-inline a.nexus-tag')) {
      final name = _clean(a.text);
      if (name.isEmpty) continue;
      if (kJunkTagPatterns.any((p) => name.contains(p))) continue;
      if (tags.any((t) => t.name == name)) continue;
      tags.add(TagItem(name: name, source: '2Dfan', weight: 1.0));
    }

    return MetadataResult(
      game: Game(
        id: id,
        name: mainTitle,
        originalTitle: originalTitle,
        aliasNames: aliasNames.isEmpty ? null : aliasNames,
        coverUrl: cover,
        company: company,
        summary: summary,
        rating: rating,
        voteCount: voteCount,
        releaseDate: releaseDate.isEmpty ? null : releaseDate,
        sourceType: SourceType.twoDfan,
        sourceId: id,
        screenshotUrls: const [],
      ),
      tags: tags,
    );
  }

  /// `.subject-meta-list .meta-row` → {标签: 值}
  ///
  /// dd 里常是多个 `<a class="nexus-inline-link">`，`element.text` 会**无分隔符
  /// 拼接**（"みたかりん夏和小八汐優"），因此单值字段优先取首个 `<a>`。
  Map<String, String> _parseMetaRows(dynamic doc) {
    final out = <String, String>{};
    for (final row in doc.querySelectorAll('.subject-meta-list .meta-row')) {
      final label = _clean(row.querySelector('dt')?.text ?? '')
          .replaceAll(RegExp(r'[:：]$'), '');
      if (label.isEmpty) continue;
      final dd = row.querySelector('dd');
      if (dd == null) continue;
      final firstLink = dd.querySelector('a');
      final value = firstLink != null
          ? _clean(firstLink.text)
          : _clean(dd.text);
      if (value.isNotEmpty) out[label] = value;
    }
    return out;
  }

  /// 解析 `[data-island="SubjectRatingPanel"]` 的 `data-props`
  ///
  /// 属性值由 HTML 解析器自动做了实体解码，可直接 jsonDecode。
  Map<String, dynamic>? _parseRatingIsland(dynamic doc) {
    final panel = doc.querySelector('[data-island="SubjectRatingPanel"]');
    final raw = panel?.attributes['data-props'];
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 从 `<title>` 提取别名列表（`美少女万華鏡異聞 雪おんな_美少女万华镜异闻 雪女_…_2DFan`）
  List<String> _aliasesFromTitle(String rawTitle) {
    final out = <String>[];
    for (var part in rawTitle.split('_')) {
      part = _clean(part);
      if (part.isEmpty) continue;
      if (part.toUpperCase() == '2DFAN') continue;
      if (out.contains(part)) continue;
      out.add(part);
    }
    return out;
  }

  /// 中文优先：取第一个「含 CJK 且不含假名」的片段
  String? _pickChineseTitle(List<String> names) {
    for (final name in names) {
      if (!_containsCjk(name)) continue;
      if (_containsKana(name)) continue;
      return name;
    }
    return null;
  }

  bool _containsCjk(String s) => RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]').hasMatch(s);

  bool _containsKana(String s) =>
      RegExp(r'[\u3040-\u309F\u30A0-\u30FF]').hasMatch(s);

  String _firstNonEmpty(List<Object?> values) {
    for (final v in values) {
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  /// `2024-04-26` / `2024年4月26日` / `2024/4/26` → `YYYY-MM-DD`
  String _normalizeDate(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final m = RegExp(r'(\d{4})\s*[-/年.]\s*(\d{1,2})\s*[-/月.]\s*(\d{1,2})')
        .firstMatch(text);
    if (m == null) return text;
    final y = m.group(1)!;
    final mo = m.group(2)!.padLeft(2, '0');
    final d = m.group(3)!.padLeft(2, '0');
    return '$y-$mo-$d';
  }

  /// 把 HTML 片段转纯文本：`<br>` / `</p>` 转换行，其余标签剥离
  String _textOfHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    text = _unescapeHtml(text);
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return lines.join('\n');
  }

  String _unescapeHtml(String s) => s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// 最佳候选：精确(100) > 前缀(40) > 包含(20)
  ///
  /// 站点自身已按相关度排序，且中日标题跨语言时字面匹配必然落空
  /// （h1 是日文原名、用户打中文），故**无任何分时回退首个候选**，
  /// 而不是像 Bangumi/CT 那样直接放弃——否则中文查询永远 0 结果。
  Map<String, dynamic> _pickBestMatch(
      List<Map<String, dynamic>> items, String query) {
    final queryNorm = _normalizeForMatch(query);
    Map<String, dynamic> best = items.first;
    var bestScore = 0;

    for (final item in items) {
      final nameNorm = _normalizeForMatch((item['name'] ?? '').toString());
      if (nameNorm.isEmpty) continue;
      var score = 0;
      if (nameNorm == queryNorm) {
        score = 100;
      } else if (nameNorm.startsWith(queryNorm)) {
        score = 40;
      } else if (nameNorm.contains(queryNorm) ||
          queryNorm.contains(nameNorm)) {
        score = 20;
      }
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }

    if (bestScore == 0) {
      fetchLog('[2Dfan] 字面匹配落空，采用站点首个候选: ${best['name']}');
    }
    return best;
  }

  String _normalizeForMatch(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\u3000]'), '')
      .replaceAll(RegExp(r'[「」『』()（）\[\]【】:：·・,，.。!！?？~～\-—_/\\|｜*＊]'),
          '');

  MetadataResult _emptyResult() =>
      MetadataResult(game: Game(id: '', name: '', sourceType: SourceType.twoDfan));

  // ==================== 全站搜索（SITE-SEARCH） ====================

  /// 关键词 → 作品列表（全站搜索用，1 次请求，卡片数据自带封面/评分/品牌）
  ///
  /// 🔴 不做「逐条补详情」：2DFan 的**列表页本身就有封面/评分/评价数/品牌/
  /// 发售日**（比鲲的列表接口信息还全），详情页新增的只有简介与标签。
  /// 20 条逐条详情＝20 次 HTML 请求（每页 100KB+），既慢又容易被限流，
  /// 所以列表只回卡片态，简介/标签留到详情页拉。
  ///
  /// ⚠️ 域名回退由 [_getHtml] 负责（站点半通时自动换镜像），这里只管解析。
  Future<List<SiteSearchHit>> searchSubjects(String keyword,
      {int limit = 20}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const <SiteSearchHit>[];

    try {
      final page = await _getHtml('/search', query: {'keyword': kw});
      if (page.response.statusCode != 200) {
        fetchLog('[2Dfan] 全站搜索返回 ${page.response.statusCode} [$kw]');
        return const <SiteSearchHit>[];
      }

      final cards = _parseSearchResults(page.response.data.toString());
      if (cards.isEmpty) {
        fetchLog('[2Dfan] 全站搜索无结果 [$kw]');
        return const <SiteSearchHit>[];
      }

      final out = <SiteSearchHit>[];
      for (final card in cards) {
        final hit = _hitFromSearchCard(card, page.base);
        if (hit == null) continue;
        out.add(hit);
        if (out.length >= limit) break;
      }
      fetchLog('[2Dfan] 全站搜索命中 ${out.length}/$limit [$kw]');
      return out;
    } catch (e) {
      fetchLog('[2Dfan] 全站搜索失败 [$kw]: $e');
      return const <SiteSearchHit>[];
    }
  }

  /// 按站点 subject id 取单条详情（站点详情页用）
  ///
  /// 复用 [_parseDetail]：中文优先标题、会社逐级回退、评分归一、标签过滤全部
  /// 沿用，**不另起一套解析**——两套解析会让同一部作品在「添加页抓取」和
  /// 「全站搜索」里显示成两个名字。
  Future<SiteSearchHit?> fetchSubjectById(String id) async {
    final subjectId = id.trim();
    if (subjectId.isEmpty) return null;
    try {
      final page = await _getHtml('/subjects/$subjectId');
      if (page.response.statusCode != 200) {
        fetchLog('[2Dfan] 详情返回 ${page.response.statusCode} [id=$subjectId]');
        return null;
      }
      final result = _parseDetail(
        page.response.data.toString(),
        page.base,
        subjectId,
        const <String, dynamic>{},
      );
      if (!result.isValid) return null;
      return SiteSearchHit.fromMetadataResult(
        SiteSearchSource.twoDfan,
        result,
        detailUrl: '${page.base}/subjects/$subjectId',
        // 2DFan 全站按成人向处理（站点本身没有分级字段）
        nsfw: true,
        detailLoaded: true,
      );
    } catch (e) {
      fetchLog('[2Dfan] 详情失败 [id=$subjectId]: $e');
      return null;
    }
  }

  /// 仅供单元测试 / 离线探针：搜索卡片 map → 命中（不发网络请求）
  ///
  /// 覆盖「5 分制 ×2 归一 / 评价数正则 / 相对封面补全」这三条最容易写错的映射。
  @visibleForTesting
  static SiteSearchHit? parseSearchHitForTest(
    Map<String, dynamic> card, {
    String base = 'https://2dfmax.top',
  }) =>
      TwoDFanService()._hitFromSearchCard(card, base);

  /// 搜索卡片 → 命中（卡片态）
  ///
  /// 口径与详情页对齐：
  /// - 评分 `subject-card-score-value` 是 **5 分制**（`4.6`）→ ×2 归一到 10 分制；
  /// - 评价数 `subject-card-score-count` 是 `"197人评价"` → 正则取数字；
  /// - 封面可能是相对路径（镜像域名差异）→ 按当前生效基址补全。
  SiteSearchHit? _hitFromSearchCard(Map<String, dynamic> card, String base) {
    final id = (card['id'] ?? '').toString();
    final name = (card['name'] ?? '').toString();
    if (id.isEmpty || name.isEmpty) return null;

    var cover = (card['cover_url'] ?? '').toString().trim();
    if (cover.startsWith('/')) cover = '$base$cover';
    if (cover.startsWith('//')) cover = 'https:$cover';

    var rating = 0.0;
    final score5 = double.tryParse((card['rating'] ?? '').toString().trim());
    if (score5 != null && score5 > 0) {
      rating = normalizeRating(score5 * 2);
    }

    int? voteCount;
    final countMatch =
        RegExp(r'(\d+)').firstMatch((card['vote_count'] ?? '').toString());
    if (countMatch != null) voteCount = int.tryParse(countMatch.group(1)!);

    final releaseDate = _normalizeDate((card['release_date'] ?? '').toString());
    final brand = (card['brand'] ?? '').toString().trim();

    return SiteSearchHit(
      source: SiteSearchSource.twoDfan,
      siteId: id,
      title: name,
      coverUrl: cover.isEmpty ? null : cover,
      developer: brand.isEmpty ? null : brand,
      rating: rating,
      voteCount: voteCount,
      releaseDate: releaseDate.isEmpty ? null : releaseDate,
      nsfw: true,
      detailUrl: '$base/subjects/$id',
    );
  }
}

/// 一次成功请求的结果：同时带回**实际生效的基址**
///
/// 域名可能在请求过程中被切换（[TwoDFanService._getHtml] 的回退逻辑），
/// 详情页解析需要用它补全封面相对路径，所以必须与响应一起传递。
class _FanPage {
  final String base;
  final Response<String> response;
  const _FanPage(this.base, this.response);
}

/// 资源属性标签（描述搬运补丁的语言状态，不属于作品属性）——直接丢弃
const List<String> kJunkTagPatterns = [
  '汉化',
  '漢化',
  '机翻',
  '機翻',
  'AI翻译',
  'ai翻译',
  'AI漢化',
  '官方中文',
  '生肉',
  '精翻',
  '云翻',
  '人工翻译',
  '官中',
];
