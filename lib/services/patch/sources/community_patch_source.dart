import '../../../models/game_resource_model.dart';
import '../../../models/patch_resource.dart';
import '../../game_resource_service.dart';
import '../patch_source.dart';

/// 自家社区补丁源（PB `game_resources` + 分享外链）。
///
/// ## 定位
///
/// 这是**只有我们才有的**源：用户自己上传的补丁，随探索库一起走。
/// 两个外部站（鲲 / 2DFan）没有的冷门补丁，往往在这里。
///
/// ## 与另外两源的关键差异
///
/// - 它按 **PB `gameId`** 查，不按标题 → 精度 100%（不存在串味）
/// - 它不需要任何身份解析 → 没登录、没网也能查（PB 匿名可读）
/// - `linkType` 直接告诉我们投递形态，不用抓 HTML 猜
///
/// ## 过滤口径
///
/// 只取 `kind='community' && status='published'`（复用现成
/// [GameResourceService.fetchCommunity]，⛔ 不自己拼 filter 串）。
/// `kind='official'` 是**游戏本体**，不属于补丁站 —— 那是「获取」按钮的事。
class CommunityPatchSource implements PatchSource {
  @override
  PatchSite get site => PatchSite.community;

  @override
  PatchSourceCapabilities get capabilities => const PatchSourceCapabilities(
        byWorkId: false,
        byKeyword: false,
        byGameId: true,
        directDownload: true,
      );

  @override
  void dispose() {}

  @override
  Future<PatchSourceResult> search(PatchQueryContext ctx) async {
    final gameId = (ctx.gameId ?? '').trim();
    if (gameId.isEmpty) {
      // 没关联探索库游戏时这个源无从下手 —— 是「不适用」，不是「失败」。
      // 返回 empty 而不是 failed，避免 UI 上出现无意义的红字。
      return const PatchSourceResult.empty();
    }

    try {
      final rows = await GameResourceService.fetchCommunity(gameId);
      if (rows.isEmpty) return const PatchSourceResult.empty();

      final out = <PatchResource>[];
      for (final r in rows) {
        final mapped = toResource(r);
        if (mapped != null) out.add(mapped);
      }
      return PatchSourceResult(resources: out);
    } catch (e) {
      return PatchSourceResult.failed('社区资源读取失败');
    }
  }

  /// 单条 PB 资源 → 补丁模型。
  ///
  /// 抽成 static 纯映射：`GameResourceModel` 是纯数据类，可以离线构造样本，
  /// 探针能直接验证字段映射（包括 `linkType` 三态）。
  static PatchResource? toResource(GameResourceModel r) {
    final id = r.id.trim();
    if (id.isEmpty) return null;

    final title = r.title.trim();
    final size = parseHumanSizeToBytes(r.fileSize);
    final kinds = PatchKind.fromRawList(r.resourceTypes);
    final rawKinds = r.resourceTypes
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);

    // 投递形态：PB 自己就标了 linkType，不用猜
    PatchDelivery delivery;
    String? directUrl;
    String? netdiskUrl;
    String? extractCode;

    final url = r.url.trim();
    switch (r.linkType) {
      case ResourceLinkType.direct:
        if (url.isEmpty) {
          delivery = PatchDelivery.web;
        } else {
          delivery = PatchDelivery.direct;
          directUrl = url;
        }
        break;
      case ResourceLinkType.netdisk:
        if (url.isEmpty) {
          delivery = PatchDelivery.web;
        } else {
          delivery = PatchDelivery.netdisk;
          netdiskUrl = url;
          final code = r.extractCode.trim();
          extractCode = code.isEmpty ? null : code;
        }
        break;
      case ResourceLinkType.other:
      case null:
        // 「其他」型没有可直下的链接，只能把原贴地址给用户
        delivery = PatchDelivery.web;
        break;
    }

    return PatchResource(
      key: '${PatchSite.community.tag}:$id',
      site: PatchSite.community,
      id: id,
      title: title.isEmpty ? '社区资源 #$id' : title,
      gameTitle: r.gameTitle.trim(),
      kinds: kinds.isEmpty ? const <PatchKind>[PatchKind.other] : kinds,
      rawKinds: rawKinds,
      languages: r.languages
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      platforms: r.platforms
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      sizeBytes: size,
      note: r.note.trim(),
      // 「其他」型没有可直下的链接，只能把原贴地址给用户
      webUrl: r.url.trim(),
      delivery: delivery,
      directUrl: directUrl,
      netdiskUrl: netdiskUrl,
      extractCode: extractCode,
      author: r.ownerName.trim(),
      downloadCount: r.downloadCount,
      updatedAt: r.updated,
    );
  }
}
