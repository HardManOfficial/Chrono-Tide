/// 批量刷新元数据的**纯 Dart**判定核心（不 import flutter，可裸 VM 跑探针）。
///
/// 抽出来的理由：这块决定「哪些字段该写、哪些该跳过」的规则，
/// 一旦写反就是**静默的数据损坏** —— 用户勾了「只补空字段」却被覆盖，
/// 只有等他哪天手改的简介消失了才会发现。这种逻辑必须能脱离
/// Flutter / 网络 / 磁盘单独断言。
///
/// 🔴 键名必须与 game.json 完全一致（见 `GameDataFormat.GameJsonData.toJson`）。
/// 改键名等于改文件格式，必须同步 `format_version` 的兼容考量。
library;

/// game.json 里与元数据相关的**当前值**（刷新前的快照）。
class MetadataExistingValues {
  const MetadataExistingValues({
    this.description = '',
    this.developer = '',
    this.releaseDate = '',
    this.metadataSource = '',
    this.metadataSourceId = '',
    this.tags = const <String>[],
    this.rating = 0,
    this.ratingCount = 0,
    this.estimatedMinutes = 0,
    this.companyId,
  });

  final String description;
  final String developer;
  final String releaseDate;
  final String metadataSource;
  final String metadataSourceId;
  final List<String> tags;
  final double rating;
  final int ratingCount;
  final int estimatedMinutes;

  /// null = 会社词典未解析（老数据 / 未命中）
  final int? companyId;
}

/// 一次抓取结果规整后的强类型视图。
class MetadataRefreshCandidate {
  const MetadataRefreshCandidate({
    this.summary,
    this.developer,
    this.releaseDate,
    this.platform,
    this.platformId,
    this.tags = const <String>[],
    this.rating,
    this.ratingCount,
    this.estimatedMinutes,
  });

  final String? summary;
  final String? developer;
  final String? releaseDate;
  final String? platform;
  final String? platformId;
  final List<String> tags;
  final double? rating;
  final int? ratingCount;
  final int? estimatedMinutes;

  bool get hasAnyField => summary != null ||
      developer != null ||
      releaseDate != null ||
      platform != null ||
      platformId != null ||
      tags.isNotEmpty ||
      (rating != null && rating! > 0) ||
      (ratingCount != null && ratingCount! > 0) ||
      (estimatedMinutes != null && estimatedMinutes! > 0);

  /// 从 MIX 返回的 `Map<String, dynamic>` 规整（空串/空表/0 一律视为「无数据」）。
  ///
  /// 空值归一在这里做**一次**，下游就不必到处写 `value.isNotEmpty` 判断 ——
  /// 旧代码里那种判断散落各处，是「某个源返回空串把已有值冲成空」的经典来源。
  static MetadataRefreshCandidate fromFetched(Map<String, dynamic> data) {
    String? str(String key) {
      final Object? raw = data[key];
      if (raw == null) return null;
      final String v = raw.toString().trim();
      return v.isEmpty ? null : v;
    }

    final List<String> tags = <String>[];
    final Object? rawTags = data['tags'];
    if (rawTags is List) {
      for (final Object? t in rawTags) {
        final String v = t?.toString().trim() ?? '';
        if (v.isNotEmpty && !tags.contains(v)) tags.add(v);
      }
    }

    double? num2d(String key) {
      final Object? raw = data[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '');
    }

    int? num2i(String key) {
      final Object? raw = data[key];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '');
    }

    final double? rating = num2d('rating');
    final int? ratingCount = num2i('vote_count');
    final int? lengthMinutes = num2i('length_minutes');

    return MetadataRefreshCandidate(
      summary: str('summary'),
      developer: str('developer'),
      releaseDate: str('release_date'),
      platform: str('platform'),
      platformId: str('platform_id'),
      tags: List<String>.unmodifiable(tags),
      rating: (rating != null && rating > 0) ? rating : null,
      ratingCount: (ratingCount != null && ratingCount > 0) ? ratingCount : null,
      estimatedMinutes:
          (lengthMinutes != null && lengthMinutes > 0) ? lengthMinutes : null,
    );
  }
}

/// 计算本次要写入 game.json 的字段（空表 = 无需写盘）。
///
/// [overwrite] false = **只补空字段**（默认，保护用户手改内容）；
/// true = 连已有值也覆盖。
///
/// [companyId] 由调用方用会社词典解析后传入（null = 未命中，不写）。
///
/// 🔴 刻意**不包含**任何标题类字段（`title` / `original_title` / `subtitle`）
/// 以及封面/截图字段：刷新只补数据，不改名、不下载。
Map<String, dynamic> computeRefreshUpdates({
  required MetadataExistingValues existing,
  required MetadataRefreshCandidate fetched,
  required bool overwrite,
  int? companyId,
}) {
  final Map<String, dynamic> updates = <String, dynamic>{};

  void putString(String key, String? value, String currentValue) {
    if (value == null) return;
    if (currentValue == value) return;
    if (!overwrite && currentValue.trim().isNotEmpty) return;
    updates[key] = value;
  }

  void putNumber(String key, num? value, num currentValue) {
    if (value == null || value <= 0) return;
    if (currentValue == value) return;
    if (!overwrite && currentValue > 0) return;
    updates[key] = value;
  }

  putString('description', fetched.summary, existing.description);
  putString('developer', fetched.developer, existing.developer);
  putString('release_date', fetched.releaseDate, existing.releaseDate);
  putString('metadata_source', fetched.platform, existing.metadataSource);
  putString(
      'metadata_source_id', fetched.platformId, existing.metadataSourceId);
  putNumber('rating', fetched.rating, existing.rating);
  putNumber('rating_count', fetched.ratingCount, existing.ratingCount);
  putNumber(
      'estimated_minutes', fetched.estimatedMinutes, existing.estimatedMinutes);

  if (fetched.tags.isNotEmpty) {
    // 集合比较：标签只换了顺序不该算「变化」，否则每次刷新都写一遍盘
    final Set<String> a = existing.tags.toSet();
    final Set<String> b = fetched.tags.toSet();
    final bool same = a.length == b.length && a.containsAll(b);
    if (!same && (overwrite || existing.tags.isEmpty)) {
      updates['tags'] = List<String>.from(fetched.tags);
    }
  }

  if (companyId != null &&
      companyId != existing.companyId &&
      (overwrite || existing.companyId == null)) {
    updates['company_id'] = companyId;
  }

  return updates;
}
