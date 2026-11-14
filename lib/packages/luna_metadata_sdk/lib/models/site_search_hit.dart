import 'tags.dart';

/// 全站搜索（SITE-SEARCH）的来源站点。
///
/// 🔴 只登记**真正支持关键词列表检索**的站点。现有的 11 个元数据源里，多数
/// 的 `fetchByName` 只回「匹配度最高的一条」，拿不到列表，不能拿来铺网格。
///
/// 当前两个：
/// - [moyu]「鲲」：走 NextMoe catalog 开放 API（`api.nextmoe.dev/v2/catalog`）。
///   ⛔ **不是** `www.kungal.com` 自己的 REST——那套接口 2026-10-24 实测已全部
///   登录墙（`{"code":205,"用户登录失效"}`），匿名拿不到任何东西。
///   NextMoe 是鲲生态的官方数据上游，补丁站的鲲源走的也是它。
/// - [twoDfan]「2DFan」：HTML 抓取，站点无公开 API（多镜像 + 运行期回退）。
enum SiteSearchSource {
  moyu('鲲', 'moyu', 0xFF4C8DFF, 'https://www.kungal.com'),
  twoDfan('2DFan', '2dfan', 0xFFD96B3C, 'https://2dfmax.top');

  const SiteSearchSource(
    this.displayName,
    this.key,
    this.colorValue,
    this.homeUrl,
  );

  /// 展示名（卡片角标 / 详情页来源徽章）
  final String displayName;

  /// 稳定标识（缓存键、持久化）。🔴 别直接用 `Enum.name`——
  /// 本项目有裸 Dart VM 跑探针的场景，那里拿不到枚举的 `.name`。
  final String key;

  /// 角标配色（ARGB）
  final int colorValue;

  /// 站点根地址（「打开原站」兜底）
  final String homeUrl;

  /// 从持久化字符串还原；未知值返回 null（不抛异常，老数据要能读）
  static SiteSearchSource? fromKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final s in SiteSearchSource.values) {
      if (s.key == key) return s;
    }
    return null;
  }
}

/// 一次全站搜索命中（**卡片态 + 详情态共用同一个模型**）。
///
/// 设计取舍：
/// - 卡片态只需要标题/封面/评分/发售日/会社，靠站点**列表接口**一次拿全；
/// - 详情态多出简介/截图/别名，靠**详情接口**二次拉取，用 [copyWith] 回填。
/// - 🔴 两个态必须能互相区分：[detailLoaded] 为 false 时 UI 不许把
///   「简介为空」当成「这部作品没有简介」，否则会闪一下空简介区。
class SiteSearchHit {
  final SiteSearchSource source;

  /// 站点侧 id（鲲 = NextMoe work id；2DFan = `/subjects/{id}` 的数字 id）
  final String siteId;

  /// 中文优先的主标题
  final String title;

  /// 原版标题（多为日文原名）
  final String? originalTitle;

  /// 其余别名（繁中 / 英文 / 其他译名）
  final List<String> aliasNames;

  final String? coverUrl;
  final String? bannerUrl;
  final String? developer;
  final String? summary;

  /// 评分（已归一到 10 分制；0 = 站点未提供）
  final double rating;

  final int? voteCount;

  /// 发售日（`YYYY-MM-DD`，站点未提供为 null）
  final String? releaseDate;

  final List<String> tags;
  final List<String> screenshotUrls;

  /// 站点标注为成人内容（鲲读 `content_rating/content_limit`；2DFan 全站视为成人）
  final bool nsfw;

  /// 「打开原站」落点。null = 该站点没有可直接打开的作品页（退到站内搜索页）
  final String? detailUrl;

  /// 详情接口是否已经拉过（true 才允许把 summary 为空解释成「真的没有」）
  final bool detailLoaded;

  const SiteSearchHit({
    required this.source,
    required this.siteId,
    required this.title,
    this.originalTitle,
    this.aliasNames = const <String>[],
    this.coverUrl,
    this.bannerUrl,
    this.developer,
    this.summary,
    this.rating = 0,
    this.voteCount,
    this.releaseDate,
    this.tags = const <String>[],
    this.screenshotUrls = const <String>[],
    this.nsfw = false,
    this.detailUrl,
    this.detailLoaded = false,
  });

  /// 有效命中判据：站点 id 与标题都不能空（缺一个就画不出卡片，也进不了详情）
  bool get isValid => siteId.isNotEmpty && title.isNotEmpty;

  /// 卡片网格用的稳定 key（`site` + `siteId` 才是唯一——不同站点 id 会撞车）
  String get uid => '${source.key}:$siteId';

  /// 发售年份（卡片角标用）
  int? get releaseYear {
    final d = releaseDate;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  /// 副标题：优先原版标题，其次首个别名
  String? get subtitle {
    final o = originalTitle;
    if (o != null && o.isNotEmpty && o != title) return o;
    for (final a in aliasNames) {
      if (a.isNotEmpty && a != title) return a;
    }
    return null;
  }

  SiteSearchHit copyWith({
    List<String>? aliasNames,
    String? coverUrl,
    String? bannerUrl,
    String? developer,
    String? summary,
    double? rating,
    int? voteCount,
    String? releaseDate,
    List<String>? tags,
    List<String>? screenshotUrls,
    bool? nsfw,
    String? detailUrl,
    bool? detailLoaded,
  }) {
    return SiteSearchHit(
      source: source,
      siteId: siteId,
      title: title,
      originalTitle: originalTitle,
      aliasNames: aliasNames ?? this.aliasNames,
      coverUrl: coverUrl ?? this.coverUrl,
      bannerUrl: bannerUrl ?? this.bannerUrl,
      developer: developer ?? this.developer,
      summary: summary ?? this.summary,
      rating: rating ?? this.rating,
      voteCount: voteCount ?? this.voteCount,
      releaseDate: releaseDate ?? this.releaseDate,
      tags: tags ?? this.tags,
      screenshotUrls: screenshotUrls ?? this.screenshotUrls,
      nsfw: nsfw ?? this.nsfw,
      detailUrl: detailUrl ?? this.detailUrl,
      detailLoaded: detailLoaded ?? this.detailLoaded,
    );
  }

  /// 把 SDK 的统一解析结果（[MetadataResult]）映射成站点命中。
  ///
  /// 🔴 两个站点的 `_parseDetail` 都已经把「中文标题优先 / 评分归一 / 标签过滤」
  /// 做完了，这里只做字段改名，**不做任何二次判断**——重复打分会让同一部作品
  /// 在「添加页抓取」和「全站搜索」里显示成两个名字。
  factory SiteSearchHit.fromMetadataResult(
    SiteSearchSource source,
    MetadataResult result, {
    String? detailUrl,
    bool nsfw = false,
    bool detailLoaded = false,
  }) {
    final game = result.game;
    return SiteSearchHit(
      source: source,
      siteId: (game.sourceId ?? game.id).toString(),
      title: game.name,
      originalTitle: game.originalTitle,
      aliasNames: game.aliasNames ?? const <String>[],
      coverUrl: (game.coverUrl ?? '').isEmpty ? null : game.coverUrl,
      bannerUrl: (game.bannerUrl ?? '').isEmpty ? null : game.bannerUrl,
      developer: (game.company ?? '').isEmpty ? null : game.company,
      summary: (game.summary ?? '').isEmpty ? null : game.summary,
      rating: game.rating,
      voteCount: game.voteCount,
      releaseDate:
          (game.releaseDate ?? '').isEmpty ? null : game.releaseDate,
      tags: [for (final t in result.tags) t.name],
      screenshotUrls: game.screenshotUrls ?? const <String>[],
      nsfw: nsfw,
      detailUrl: detailUrl,
      detailLoaded: detailLoaded,
    );
  }
}

/// 单站点的一次检索结果。
///
/// 🔴 [error] 非空时 [hits] 必须为空 —— **「站点挂了」与「真的没搜到」必须能
/// 区分**，否则 UI 只能显示「0 条结果」，用户会以为整站没这部作品。
/// 这是补丁站 `PatchSourceResult` 的同一条铁律，此处保持一致。
class SiteSearchSourceResult {
  final SiteSearchSource source;
  final List<SiteSearchHit> hits;

  /// 失败原因（人类可读，直接进提示条）。null = 本次请求成功
  final String? error;

  const SiteSearchSourceResult({
    required this.source,
    this.hits = const <SiteSearchHit>[],
    this.error,
  });

  const SiteSearchSourceResult.failed(this.source, String reason)
      : hits = const <SiteSearchHit>[],
        error = reason;

  bool get ok => error == null;

  bool get isEmpty => ok && hits.isEmpty;
}
