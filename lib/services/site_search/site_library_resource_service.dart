import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

/// 全站库资源解析器（SITE-LIBRARY）。
///
/// ## 术语（用户 2026-11-13 拍板）
///
/// - **探索库** = 原生游戏库（PocketBase 记录驱动的那个）；
/// - **全站库** = 全站搜索结果的总称（含探索库命中 + 鲲 + 2DFan）。
///   站外命中详情页的「获取 / 分享 / 补丁」不再一律灰置，按新语义点亮：
///   获取 = 对应站点的下载指令（letmoe 托管直链走软件内下载）；
///   分享 = 网盘下载（复制链接 + 提取码后外跳）；
///   补丁 = 沿用补丁站（PATCH-STATION）既有能力。
///
/// ## 解析路径
///
/// | 命中来源 | catalog work id | letmoe 资源 |
/// |----------|-----------------|-------------|
/// | 鲲（moyu） | `siteId` 本身就是（零成本） | 直接查 |
/// | 2DFan | 标题反查 [NextMoeService.resolveWorkIdByTitle] | 反查命中才查 |
///
/// 🔴 2DFan 反查**宁缺毋滥**：标题全等（归一化后）才认，查不到 →
/// [SiteLibraryResourceContext.resolved] 为 false，上层把「获取 / 分享」
/// 灰置并提示（补丁不受影响，走 2DFan 关键词检索）。
class SiteLibraryResourceResolver {
  SiteLibraryResourceResolver._();

  static final SiteLibraryResourceResolver instance =
      SiteLibraryResourceResolver._();

  final LetmoeResourceService _letmoe = LetmoeResourceService();
  final NextMoeService _nextmoe = NextMoeService();

  /// 解析一次全站命中的资源上下文。
  ///
  /// [forceRefresh] = 用户点了面板「刷新」：穿透 letmoe 列表 TTL 缓存重拉。
  ///
  /// 永不抛异常：网络失败 = 空资源 + resolved 保持 true（workId 已知，只是
  /// letmoe 没有资源 / 暂时不可达），面板显示「暂无资源 + 重试」。
  Future<SiteLibraryResourceContext> resolve(
    SiteSearchHit hit, {
    bool forceRefresh = false,
  }) async {
    // 鲲命中：siteId 就是 catalog work id（`/galgame/{id}` 同体系）。
    if (hit.source == SiteSearchSource.moyu) {
      final workId = int.tryParse(hit.siteId.trim()) ?? 0;
      if (workId <= 0) {
        return SiteLibraryResourceContext.unresolved(hit);
      }
      final resources =
          await _letmoe.listWorkResources('$workId', forceRefresh: forceRefresh);
      return SiteLibraryResourceContext(
        hit: hit,
        workId: workId,
        resolved: true,
        resources: resources,
      );
    }

    // 2DFan 命中：subject id ≠ catalog id，标题反查（严格全等）。
    final candidates = <String>[
      hit.title,
      if (hit.originalTitle != null && hit.originalTitle!.isNotEmpty)
        hit.originalTitle!,
      ...hit.aliasNames,
    ];
    final workIdStr = await _nextmoe.resolveWorkIdByTitle(candidates);
    final workId = int.tryParse(workIdStr?.trim() ?? '') ?? 0;
    if (workId <= 0) {
      return SiteLibraryResourceContext.unresolved(hit);
    }
    final resources =
        await _letmoe.listWorkResources('$workId', forceRefresh: forceRefresh);
    return SiteLibraryResourceContext(
      hit: hit,
      workId: workId,
      resolved: true,
      resources: resources,
    );
  }
}

/// 一次解析的产物（详情页「获取 / 分享」面板的数据源）。
class SiteLibraryResourceContext {
  const SiteLibraryResourceContext({
    required this.hit,
    required this.workId,
    required this.resolved,
    this.resources = const <LetmoeResource>[],
  });

  final SiteSearchHit hit;

  /// catalog work id（鲲命中 = siteId；2DFan 命中 = 反查所得；未定位 = 0）
  final int workId;

  /// false = 2DFan 命中未能定位到 catalog 作品（获取 / 分享灰置兜底）
  final bool resolved;

  /// letmoe 资源列表（可能为空 = 定位到了但该作品没有资源）
  final List<LetmoeResource> resources;

  const SiteLibraryResourceContext.unresolved(this.hit)
      : workId = 0,
        resolved = false,
        resources = const <LetmoeResource>[];

  /// 有无游戏本体资源（type=game）
  bool get hasGameResource => resources.any((r) => r.isGame);
}
