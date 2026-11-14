import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'site_search_ranker.dart';

/// 全站搜索（SITE-SEARCH）聚合结果。
///
/// 🔴 必须把「每个源各自怎么样」原样带出来（[perSource]）：只回一个扁平
/// [hits] 时，UI 无法解释「这次为什么只有 2DFan 的条目」——是鲲真的没收录，
/// 还是鲲挂了 / 超时 / 被限流。这两件事对用户是**完全不同**的信息。
class SiteSearchOutcome {
  /// **按标题相关性排序后**的全部命中（跨源混排，最匹配的在最前）
  final List<SiteSearchHit> hits;

  /// 每个源自己的结果（含失败原因）
  final List<SiteSearchSourceResult> perSource;

  /// 命中是否来自会话缓存（UI 可据此省掉一次 loading 动画）
  final bool fromCache;

  /// **过滤前**的候选总条数。
  ///
  /// 站点接口是全文模糊检索（鲲拆单字、2DFan 连罗马字都算），所以「拿到了
  /// 40 条」与「有 2 条真的叫这个名字」是两件事。概览条要能把差额讲清楚，
  /// 否则用户会以为站点只收录了 2 部作品。
  final int candidateCount;

  const SiteSearchOutcome({
    this.hits = const <SiteSearchHit>[],
    this.perSource = const <SiteSearchSourceResult>[],
    this.fromCache = false,
    this.candidateCount = 0,
  });

  static const SiteSearchOutcome empty = SiteSearchOutcome();

  bool get isEmpty => hits.isEmpty;

  /// 被标题匹配筛掉的条数
  int get filteredCount =>
      candidateCount > hits.length ? candidateCount - hits.length : 0;

  /// 全部源都失败（不是「没搜到」，是「一个都没问成」）
  bool get allFailed => perSource.isNotEmpty && perSource.every((r) => !r.ok);

  /// 失败源的人类可读描述（拼成一行给提示条用）；全成功返回 null
  String? get failureSummary {
    final failures = perSource.where((r) => !r.ok).toList();
    if (failures.isEmpty) return null;
    return failures
        .map((r) => '${r.source.displayName}：${r.error}')
        .join('；');
  }

  SiteSearchOutcome copyWith({
    List<SiteSearchHit>? hits,
    List<SiteSearchSourceResult>? perSource,
    bool? fromCache,
    int? candidateCount,
  }) {
    return SiteSearchOutcome(
      hits: hits ?? this.hits,
      perSource: perSource ?? this.perSource,
      fromCache: fromCache ?? this.fromCache,
      candidateCount: candidateCount ?? this.candidateCount,
    );
  }
}

/// 全站搜索聚合服务
///
/// 职责边界（刻意保持很窄）：
/// - **编排**：并发问两个站点、隔离单源失败、管缓存与防重入；
/// - **过滤与排序**：交给 [SiteSearchRanker]（标题相关性打分 + 每源 Top1 兜底
///   + 跨源混排）。这步**必须留在聚合层**：站点侧没有字段限定能力，而 UI 只
///   拿到一个扁平列表，放 UI 里做就会和详情页各算一套；
/// - **不解析、不翻译**：字段抽取全部下放给站点自己的 `searchSubjects` /
///   `searchWorks`（它们各自最懂自己的页面与口径）。再解析一遍会让同一部作品
///   在「全站搜索」和「添加页一键抓取」里显示成两个名字。
///
/// 与探索库完全解耦：本服务不碰 PocketBase、不写 game.json、不改任何全局状态。
class SiteSearchService {
  SiteSearchService._();

  static final SiteSearchService instance = SiteSearchService._();

  /// 仅供单元测试：注入假的站点检索实现（不建 Dio、不发网络请求）
  @visibleForTesting
  SiteSearchService.forTest({
    Future<List<SiteSearchHit>> Function(String keyword)? moyuSearch,
    Future<List<SiteSearchHit>> Function(String keyword)? fanSearch,
    Future<SiteSearchHit?> Function(SiteSearchSource source, String siteId)?
        detailFetch,
  })  : _moyuSearchOverride = moyuSearch,
        _fanSearchOverride = fanSearch,
        _detailFetchOverride = detailFetch;

  Future<List<SiteSearchHit>> Function(String keyword)? _moyuSearchOverride;
  Future<List<SiteSearchHit>> Function(String keyword)? _fanSearchOverride;
  Future<SiteSearchHit?> Function(SiteSearchSource source, String siteId)?
      _detailFetchOverride;

  /// 同一关键词的结果缓存时长。
  ///
  /// 5 分钟的依据：全站搜索是「一次性动作」——用户点了按钮才有结果，之后
  /// 改字就清空。短时间内反复点同一个词（或点完又点回来）不该重复打站点，
  /// 但也不能像元数据缓存那样放 24h（站点新收录的作品会永远看不到）。
  static const Duration kCacheTtl = Duration(minutes: 5);

  /// 结果缓存条数上限。
  ///
  /// 🔴 之前无上限：`_cache` 只在写入时被查、从不清扫，TTL 只决定「还能不能
  /// 命中」，条目本身永久驻留。用户连搜几十个词就攒几十份完整结果（每条命中
  /// 含封面 URL / 简介 / 标签），长时间运行内存缓慢上涨。这里按「最久未写入」
  /// 淘汰到上限，只保留近期真正常用的几组。
  static const int kCacheMaxEntries = 24;

  /// 单源兜底超时。站点自己的 Dio 已有 connect/receive 超时，这里只防
  /// 「整体卡死」（例如 2DFan 5 个镜像逐个 4s 回退 = 20s）。
  static const Duration kSourceTimeout = Duration(seconds: 20);

  /// 详情页兜底超时
  static const Duration kDetailTimeout = Duration(seconds: 20);

  final Map<String, _CachedOutcome> _cache = {};
  final Map<String, Future<SiteSearchOutcome>> _inFlight = {};

  NextMoeService? _moyuService;
  TwoDFanService? _twoDFanService;

  NextMoeService get _moyu => _moyuService ??= NextMoeService();
  TwoDFanService get _twoDFan => _twoDFanService ??= TwoDFanService();

  /// 关键词归一（缓存键）：小写 + 折叠首尾与连续空白。
  /// 不剥标点——「Re:Zero」和「ReZero」在站点侧确实是两个查询。
  static String normalizeKeyword(String keyword) =>
      keyword.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// 全站检索 [keyword]。
  ///
  /// [forceRefresh] = true 时跳过缓存（用户手动「重新搜索」）。
  Future<SiteSearchOutcome> search(
    String keyword, {
    bool forceRefresh = false,
  }) {
    final key = normalizeKeyword(keyword);
    if (key.isEmpty) return Future.value(SiteSearchOutcome.empty);

    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null &&
          DateTime.now().difference(cached.at) < kCacheTtl) {
        return Future.value(cached.outcome.copyWith(fromCache: true));
      }
    }

    // 同一关键词正在搜：复用同一个 Future，**不重复打站点**
    // （用户手快连点两次按钮 / 输入框回车又点按钮，都会走到这里）
    final running = _inFlight[key];
    if (running != null) return running;

    final future = _run(key);
    _inFlight[key] = future;
    return future.whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<SiteSearchOutcome> _run(String keyword) async {
    // 两源并发；每个源自己吞异常并转成 error 字段，故这里不会有未捕获异常
    final results = await Future.wait<SiteSearchSourceResult>([
      _searchMoyu(keyword),
      _searchTwoDFan(keyword),
    ]);

    // 🔴 在这里统一做「标题相关性过滤 + 跨源混排」：两个站点接口都是全文
    // 模糊匹配（鲲拆单字、2DFan 连罗马字都算），原样铺出去就是一堆无关作品。
    // ⛔ 不要把这步下放到 UI——详情页复用的也是这份 hits，两处打分必然不一致。
    final ranked = SiteSearchRanker.rank(results, keyword);

    final outcome = SiteSearchOutcome(
      hits: ranked.hits,
      perSource: results,
      candidateCount: ranked.candidateCount,
    );
    // 🔴 全失败不写缓存：否则一次断网会把「全部失败」钉住 5 分钟
    if (!outcome.allFailed) {
      _cache[normalizeKeyword(keyword)] = _CachedOutcome(outcome, DateTime.now());
      _trimCache();
    }
    return outcome;
  }

  /// 缓存上限淘汰：先清过期，再按写入时间丢最旧的。
  void _trimCache() {
    if (_cache.length <= kCacheMaxEntries) return;
    final now = DateTime.now();
    _cache.removeWhere((_, v) => now.difference(v.at) >= kCacheTtl);
    if (_cache.length <= kCacheMaxEntries) return;
    final oldest = _cache.entries.toList()
      ..sort((a, b) => a.value.at.compareTo(b.value.at));
    for (final e in oldest.take(_cache.length - kCacheMaxEntries)) {
      _cache.remove(e.key);
    }
  }

  Future<SiteSearchSourceResult> _searchMoyu(String keyword) async {
    const source = SiteSearchSource.moyu;
    try {
      final hits = await (_moyuSearchOverride ?? _moyu.searchWorks)(keyword)
          .timeout(kSourceTimeout);
      if (hits.isEmpty) {
        // 空结果也是成功——站点确实没收录，别显示成错误
        return const SiteSearchSourceResult(source: source);
      }
      return SiteSearchSourceResult(source: source, hits: hits);
    } catch (e) {
      final reason = _humanize(e);
      debugPrint('[SiteSearch] 鲲 失败: $reason');
      return SiteSearchSourceResult.failed(source, reason);
    }
  }

  Future<SiteSearchSourceResult> _searchTwoDFan(String keyword) async {
    const source = SiteSearchSource.twoDfan;
    try {
      final hits = await (_fanSearchOverride ?? _twoDFan.searchSubjects)(keyword)
          .timeout(kSourceTimeout);
      if (hits.isEmpty) {
        return const SiteSearchSourceResult(source: source);
      }
      return SiteSearchSourceResult(source: source, hits: hits);
    } catch (e) {
      final reason = _humanize(e);
      debugPrint('[SiteSearch] 2DFan 失败: $reason');
      return SiteSearchSourceResult.failed(source, reason);
    }
  }

  /// 补全单条命中的详情（简介 / 截图 / 别名 / 标签）
  ///
  /// 失败时**原样返回旧对象**（[SiteSearchHit.detailLoaded] 仍为 false），
  /// 让 UI 可以显示「加载失败，点击重试」，而不是把空简介当成事实。
  Future<SiteSearchHit> fetchDetail(SiteSearchHit hit) async {
    if (hit.detailLoaded) return hit;
    try {
      final override = _detailFetchOverride;
      final full = override != null
          ? await override(hit.source, hit.siteId).timeout(kDetailTimeout)
          : await _fetchFromSite(hit).timeout(kDetailTimeout);
      if (full == null) return hit;

      // 详情缺字段时用卡片态兜底：详情页比列表页更容易漏封面/评分
      // （2DFan 的封面在详情页偶尔是懒加载占位），不能让好数据变空。
      return full.copyWith(
        coverUrl: (full.coverUrl ?? '').isEmpty ? hit.coverUrl : full.coverUrl,
        bannerUrl:
            (full.bannerUrl ?? '').isEmpty ? hit.bannerUrl : full.bannerUrl,
        developer:
            (full.developer ?? '').isEmpty ? hit.developer : full.developer,
        rating: full.rating > 0 ? full.rating : hit.rating,
        voteCount: full.voteCount ?? hit.voteCount,
        releaseDate:
            (full.releaseDate ?? '').isEmpty ? hit.releaseDate : full.releaseDate,
        tags: full.tags.isEmpty ? hit.tags : full.tags,
      );
    } catch (e) {
      debugPrint('[SiteSearch] 详情失败 ${hit.uid}: ${_humanize(e)}');
      return hit;
    }
  }

  Future<SiteSearchHit?> _fetchFromSite(SiteSearchHit hit) {
    switch (hit.source) {
      case SiteSearchSource.moyu:
        return _moyu.fetchWorkById(hit.siteId);
      case SiteSearchSource.twoDfan:
        return _twoDFan.fetchSubjectById(hit.siteId);
    }
  }

  /// 清空缓存（设置页「清缓存」或站点数据明显过期时调）
  void clearCache() => _cache.clear();

  /// 仅供测试：当前缓存条目数
  @visibleForTesting
  int get cacheSizeForTest => _cache.length;

  /// 把异常翻译成人话（直接进提示条，别把 StackTrace 甩给用户）
  static String _humanize(Object e) {
    if (e is TimeoutException) return '请求超时';
    if (e is StateError) {
      // 2DFan 全部镜像不可达时抛的是 StateError，message 已经可读
      final msg = e.message;
      if (msg.isNotEmpty) return msg;
    }
    final raw = e.toString().replaceFirst('Exception: ', '');
    return raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
  }
}

class _CachedOutcome {
  final SiteSearchOutcome outcome;
  final DateTime at;
  const _CachedOutcome(this.outcome, this.at);
}
