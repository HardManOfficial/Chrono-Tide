/// 补丁源抽象（PATCH-STATION）。
///
/// 三个实现：[MoyuPatchSource]（鲲）、[TwoDFanPatchSource]（2DFan）、
/// [CommunityPatchSource]（自家 PB）。
///
/// 🔴 **能力不同，不要强行统一成一种检索方式**：
/// - 鲲：能按 NextMoe `catalog` work id **精确锚定**（`refs=catalog:<id>`），
///   这是精度最高的一条路；
/// - 2DFan：只有关键词检索（`/search?keyword=`），**没有 id 体系**，
///   靠标题搜完再多一步"取前 N 个作品"；
/// - 社区：只能按 PB `gameId` 或标题模糊查 `game_resources`。
///
/// 所以 [search] 收一个「上下文」而不是单个字符串，各源自己挑能用的字段。
/// ⛔ 不要在聚合层替源决定"该用哪个 id" —— 那是各源自己的知识。
library;

import '../../models/patch_resource.dart';

/// 一次检索的输入上下文（能填多少填多少，源自己挑）。
class PatchQueryContext {
  /// 用户直接输入的关键词（游戏名或补丁名）。可能为空（只用 id 时）
  final String keyword;

  /// 探索库 PB `games.id`（社区源用；也用于缓存键）
  final String? gameId;

  /// NextMoe `catalog` work id（鲲源精确锚定用；解析失败为 null）
  final int? workId;

  /// 候选标题链（主标题 / 日文原名 / 英文名，按优先级）。
  /// 用于"没有 work id 时由源自己按标题搜"以及 2DFan 的关键词检索。
  final List<String> titles;

  /// 是否包含成人内容（沿用全局 NSFW 开关）
  final bool nsfw;

  const PatchQueryContext({
    required this.keyword,
    this.gameId,
    this.workId,
    this.titles = const <String>[],
    this.nsfw = true,
  });

  /// 送去检索的最佳关键词：优先用户输入，其次首个候选标题
  String get effectiveKeyword {
    final k = keyword.trim();
    if (k.isNotEmpty) return k;
    for (final t in titles) {
      final s = t.trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  bool get hasAnyKey =>
      effectiveKeyword.isNotEmpty || (gameId ?? '').isNotEmpty || workId != null;
}

/// 单源检索结果。
///
/// 🔴 [error] 非空时 [resources] 必须为空 —— 「失败」与「没找到」必须能区分，
/// 否则 UI 无法解释"为什么这次条数变少了"。⛔ 失败时塞占位/假条目。
class PatchSourceResult {
  final List<PatchResource> resources;

  /// 失败原因（人类可读，直接进 UI 提示条）。null = 本次成功
  final String? error;

  const PatchSourceResult({this.resources = const <PatchResource>[], this.error});

  const PatchSourceResult.failed(String reason)
      : resources = const <PatchResource>[],
        error = reason;

  const PatchSourceResult.empty()
      : resources = const <PatchResource>[],
        error = null;

  bool get ok => error == null;
}

/// 源能力矩阵（UI 据此决定"这个源能不能用"、聚合层据此决定调度顺序）。
class PatchSourceCapabilities {
  /// 能按 NextMoe work id 精确锚定
  final bool byWorkId;

  /// 能按任意关键词检索（补丁名 / 游戏名）
  final bool byKeyword;

  /// 能按 PB gameId 查
  final bool byGameId;

  /// 能给出可直连下载地址（否则只能跳转/网盘）
  final bool directDownload;

  const PatchSourceCapabilities({
    this.byWorkId = false,
    this.byKeyword = true,
    this.byGameId = false,
    this.directDownload = false,
  });
}

/// 补丁源接口。
abstract class PatchSource {
  PatchSite get site;

  PatchSourceCapabilities get capabilities;

  /// 检索。实现方必须自己吞掉所有异常并转成 [PatchSourceResult.failed]，
  /// ⛔ 不要把异常抛给聚合层（那里并发跑三个源，一个 throw 会带崩整轮）。
  Future<PatchSourceResult> search(PatchQueryContext ctx);

  /// 释放资源（Dio 连接池等）。默认无操作。
  ///
  /// ⚠️ 用 `implements PatchSource` 的实现类**必须自己写这个方法** ——
  /// `implements` 不继承默认实现（只有 `extends` 才继承）。
  void dispose() {}
}
