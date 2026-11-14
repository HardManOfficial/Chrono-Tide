import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../models/patch_resource.dart';
import 'patch_identity_matcher.dart';
import 'patch_identity_resolver.dart';
import 'patch_source.dart';
import 'sources/community_patch_source.dart';
import 'sources/moyu_patch_source.dart';
import 'sources/two_dfan_patch_source.dart';

/// 补丁检索聚合服务（PATCH-STATION 的门面）。
///
/// ## 一次检索做什么
///
/// ```
/// 关键词 / 候选标题
///   └→ PatchIdentityResolver → NextMoe work id
///        （有 gameId 用它当键；没有就用 kw:<归一化关键词>，且只认置信度 ≥0.8）
///        └→ 三源并发：
///             鲲     按 workId 精确锚定（拿不到 workId 就跳过）
///             2DFan  按关键词（串味风险最高，故 UI 需显示匹配到的游戏）
///             社区   按 PB gameId（精度 100%）
///        └→ 合并 + 去重 + 统计
/// ```
///
/// ## 三条硬规则
///
/// 1. 🔴 **单源失败只降级不伪造**：失败源进 [PatchQueryResult.failures]，
///    其余源照常出。⛔ 绝不塞占位条目凑数。
/// 2. 🔴 **失败 ≠ 没找到**：源明确返回空列表（如"这部作品确实没补丁"）时，
///    不写进 failures，否则 UI 会误报"源挂了"。
/// 3. 🔴 **网络绝不进 `build()`**：调用方先渲染骨架，再 await 这个 Future。
///
/// ## 去重
///
/// 鲲与社区可能收录同一个补丁（社区用户转存了鲲的资源）。按
/// `sha256 > 直链 URL > key` 判定同一份，保留**字段更全**的那条
/// （通常是鲲：有 `note`/`sha256`/结构化类型）。
class PatchSearchService {
  static final PatchSearchService _instance = PatchSearchService._internal();

  /// 测试注入点：非空时 `factory` 返回它。
  ///
  /// 只给 `dev_probe` 用（渲染探针要注入假源才能画出具内容的补丁站面板，
  /// 否则只能测空态 —— 而卡片溢出、半张卡、残行这些恰恰只在有数据时出现）。
  /// ⛔ 生产代码永远不要调 [useTestInstance]。
  static PatchSearchService? _testInstance;

  @visibleForTesting
  static void useTestInstance(PatchSearchService? s) => _testInstance = s;

  factory PatchSearchService() => _testInstance ?? _instance;

  PatchSearchService._internal() : this.withSources(null);

  /// 供测试注入假源（⛔ 生产代码走 [factory PatchSearchService]）
  ///
  /// [skipIdentityResolution] = 跳过「标题 → NextMoe work id」那一步。
  /// 测试里必须为 true：那一步是**真网络请求**，在渲染探针（flutter_tester）
  /// 里会一直挂着，锁定态面板就永远停在 loading、一张卡都出不来。
  PatchSearchService.withSources(
    List<PatchSource>? sources, {
    this.skipIdentityResolution = false,
  }) : _sources = <PatchSite, PatchSource>{
          for (final s in sources ?? _createDefaultSources()) s.site: s,
        };

  static List<PatchSource> _createDefaultSources() => <PatchSource>[
        MoyuPatchSource(),
        TwoDFanPatchSource(),
        CommunityPatchSource(),
      ];

  final Map<PatchSite, PatchSource> _sources;

  /// 跳过身份解析（测试专用）
  final bool skipIdentityResolution;

  /// 内存结果缓存（key = gameId 或 归一化关键词），TTL 10 分钟。
  /// ⚠️ 直链会过期，所以不做长缓存；关掉面板再打开能命中就够了。
  final Map<String, _Cached> _cache = <String, _Cached>{};
  static const Duration kCacheTtl = Duration(minutes: 10);

  PatchSource? sourceOf(PatchSite site) => _sources[site];

  /// 清缓存（设置里改了源开关 / 用户手动刷新时调）
  void clearCache() => _cache.clear();

  /// 主入口。
  ///
  /// [keyword] 用户输入（游戏名或补丁名）；[gameId] 探索库游戏 id；
  /// [candidateTitles] 候选标题链（主标题 → 原名 → 英文名）；
  /// [knownWorkId] **已知的** catalog work id（SITE-LIBRARY 全站库命中：
  /// 鲲的 `siteId` 本身就是 catalog id）——非 null 时跳过身份解析直接锚定，
  /// 省一次网络往返且零误配风险（2026-11-13 全站库资源能力新增）；
  /// [enabledSites] 空/null = 全开。
  Future<PatchQueryResult> search({
    required String keyword,
    String? gameId,
    List<String> candidateTitles = const <String>[],
    int? knownWorkId,
    Set<PatchSite>? enabledSites,
    bool nsfw = true,
    bool forceRefresh = false,
  }) async {
    final titles = <String>[
      ...candidateTitles,
      if (keyword.trim().isNotEmpty) keyword.trim(),
    ];

    final cacheKey = _cacheKeyOf(gameId, keyword);
    if (!forceRefresh) {
      final hit = _cache[cacheKey];
      if (hit != null && DateTime.now().difference(hit.at) <= kCacheTtl) {
        return hit.result;
      }
    }

    final active = <PatchSource>[
      for (final s in _sources.values)
        if (enabledSites == null || enabledSites.contains(s.site)) s,
    ];

    // ---- 身份解析（只有鲲需要，但 2DFan 也受益于"用原名再试一次"）----
    //
    // 🔴 门禁**不能**是「必须有 gameId」。探索库顶栏的「补丁站」在没选中游戏
    // 时 gameId 是 null，而鲲的能力表是 byKeyword: false（NextMoe 没有补丁名
    // 检索，只能 refs=catalog:<workId> 锚定）⇒ 跳过这一步等于鲲**一次都不被
    // 请求**，全局搜出来的自然全是 2DFan 的。
    //
    // 没有 gameId 时缓存键退化成 `kw:<归一化关键词>`（见
    // [patchIdentityCacheKey]），并且**只采信 isConfident（≥0.8）**的结果：
    // 没有权威锚点时唯一的依据是标题相似度，低置信度匹配就是把别人的补丁
    // 串进来。宁可少给，也不串味。
    PatchWorkMatch match = PatchWorkMatch.none;
    if (knownWorkId != null && knownWorkId > 0) {
      // SITE-LIBRARY 全站库旁路：workId 已知（鲲命中 = siteId），直接锚定。
      // 置信度给满：id 是站点体系原生锚点，不存在「标题相似但串味」的问题。
      match = PatchWorkMatch(
        workId: knownWorkId,
        matchedTitle: titles.isNotEmpty ? titles.first : '',
        confidence: 1.0,
      );
    } else if (!skipIdentityResolution && titles.isNotEmpty) {
      final gid = (gameId ?? '').trim();
      final scopeKeyword =
          keyword.trim().isNotEmpty ? keyword : (titles.first.trim());
      final scopeKey =
          patchIdentityCacheKey(gameId: gid, keyword: scopeKeyword);
      if (scopeKey.isNotEmpty) {
        final resolved = await PatchIdentityResolver().resolve(
          gameId: scopeKey,
          candidateTitles: titles,
          nsfw: nsfw,
        );
        if (gid.isNotEmpty || acceptKeywordWorkMatch(resolved)) {
          match = resolved;
        }
      }
    }

    final ctx = PatchQueryContext(
      keyword: keyword,
      gameId: gameId,
      workId: match.workId,
      titles: titles,
      nsfw: nsfw,
    );

    // ---- 并发跑（每源自己吞异常，这里再兜一层防漏）----
    final results = await Future.wait<PatchSourceResult>(
      active.map((s) async {
        try {
          return await s.search(ctx);
        } catch (_) {
          return PatchSourceResult.failed('${s.site.displayName} 异常');
        }
      }),
    );

    final failures = <PatchSite, String>{};
    final counts = <PatchSite, int>{};
    final merged = <PatchResource>[];

    for (var i = 0; i < active.length; i++) {
      final s = active[i];
      final r = results[i];
      if (!r.ok) {
        failures[s.site] = r.error ?? '不可用';
        continue;
      }
      counts[s.site] = r.resources.length;
      merged.addAll(r.resources);
    }

    final deduped = _dedupe(merged);

    final result = PatchQueryResult(
      keyword: keyword,
      resolvedGameTitle: match.found ? match.matchedTitle : null,
      resources: deduped,
      failures: failures,
      countsBySite: counts,
      resolvedByTitle: match.found && !match.isConfident,
    );

    _cache[cacheKey] = _Cached(result: result, at: DateTime.now());
    return result;
  }

  String _cacheKeyOf(String? gameId, String keyword) {
    final g = (gameId ?? '').trim();
    if (g.isNotEmpty) return 'g:$g';
    return 'k:${normalizePatchTitle(keyword)}';
  }

  /// 跨源去重：同一份补丁只留字段最全的那条。
  List<PatchResource> _dedupe(List<PatchResource> input) {
    if (input.length <= 1) return input;

    final indexByKey = <String, int>{};
    final out = <PatchResource>[];

    for (final r in input) {
      final key = _dedupeKeyOf(r);
      final existing = indexByKey[key];
      if (existing == null) {
        indexByKey[key] = out.length;
        out.add(r);
        continue;
      }
      if (_richness(r) > _richness(out[existing])) {
        out[existing] = r;
      }
    }
    return out;
  }

  /// 判定"同一份补丁"的键。
  ///
  /// 优先级：sha256（最可靠）> 直链 URL（同一文件同一地址）> 站内 key（永不撞）
  static String _dedupeKeyOf(PatchResource r) {
    final sha = r.sha256.trim().toLowerCase();
    if (sha.length >= 16) return 'sha:$sha';
    final direct = (r.directUrl ?? '').trim();
    if (direct.isNotEmpty) return 'url:$direct';
    return 'key:${r.key}';
  }

  /// 字段丰富度打分（用于冲突时择优）
  static int _richness(PatchResource r) {
    var score = 0;
    if (r.sha256.trim().isNotEmpty) score += 4;
    if (r.note.trim().isNotEmpty) score += 2;
    if (r.sizeBytes != null) score += 1;
    if (r.author.trim().isNotEmpty) score += 1;
    if (r.updatedAt != null) score += 1;
    // 能直下的优先（用户目标就是下载）
    if (r.downloadable) score += 3;
    return score;
  }
}

class _Cached {
  final PatchQueryResult result;
  final DateTime at;

  const _Cached({required this.result, required this.at});
}
