import 'dart:async';

import '../../models/patch_resource.dart';
import 'sources/two_dfan_account_service.dart';
import 'sources/two_dfan_page_parser.dart';

/// 「这个补丁到底怎么下」的统一答案。
///
/// ## 为什么要有这一层
///
/// 三个来源拿投递信息的成本完全不同：
///
/// | 来源 | 何时能知道直链 | 代价 |
/// |---|---|---|
/// | 鲲 | 检索时顺手抓资源页 | 已在 [PatchResource.links] 里 |
/// | 2DFan | **必须**单独抓 `/downloads/{id}` | 每补丁多一次请求 |
/// | 社区 | 检索时就有 | 已在模型里 |
///
/// 若在检索阶段就对 2DFan 逐条抓详情，一次搜索最多 5 部作品 × N 条补丁
/// ⇒ 几十个请求，站点会限流、用户要等十几秒。
/// ⇒ 2DFan 改成**按需解析**：用户点开「查看下载」的那一刻才抓，只抓这一条。
///
/// ## 缓存口径
///
/// - 成功后缓存 [kCacheTtl]（2 分钟）：价格与余额随时会变，⛔ 不能长期缓存，
///   否则用户看到的是"旧积分"，下单时被价格复核拦下反而更困惑。
/// - 失败**不缓存**：网络抖动一次不该让条目永久显示"打不开"。
class PatchDeliveryService {
  PatchDeliveryService._();

  static final PatchDeliveryService instance = PatchDeliveryService._();

  static const Duration kCacheTtl = Duration(minutes: 2);

  final Map<String, _CachedDetail> _cache = <String, _CachedDetail>{};

  /// 正在解析的 key（并发去重：用户快速展开/收起同一张卡不该发两次请求）
  final Map<String, Future<PatchDeliveryDetail>> _inflight =
      <String, Future<PatchDeliveryDetail>>{};

  /// 解析一条补丁的投递详情。
  ///
  /// [force] 跳过缓存（用户点「刷新」时用）。
  Future<PatchDeliveryDetail> resolve(
    PatchResource resource, {
    bool force = false,
  }) {
    final cached = _cache[resource.key];
    if (!force && cached != null && !cached.isExpired) {
      return Future<PatchDeliveryDetail>.value(cached.detail);
    }
    final running = _inflight[resource.key];
    if (running != null) return running;

    final future = _resolveInner(resource).then((detail) {
      if (detail.error == null) {
        _cache[resource.key] = _CachedDetail(detail, DateTime.now());
      }
      return detail;
    }).whenComplete(() {
      _inflight.remove(resource.key);
    });
    _inflight[resource.key] = future;
    return future;
  }

  Future<PatchDeliveryDetail> _resolveInner(PatchResource resource) async {
    switch (resource.site) {
      case PatchSite.twoDfan:
        return _resolveFan(resource);
      case PatchSite.kunlun:
      case PatchSite.community:
        return PatchDeliveryDetail.fromResource(resource);
    }
  }

  /// 2DFan：抓下载页 → 拿网盘载点 / 积分 / 兑换能力
  ///
  /// 🔴 [preferBase] 用**检索阶段已经探通的那个域名**（`webUrl` 的 host）：
  /// 2DFan 的 Cookie 按域名生效，若详情页去另一个镜像抓，会出现
  /// 「列表里显示已登录、展开后说未登录」这种自相矛盾。
  Future<PatchDeliveryDetail> _resolveFan(PatchResource resource) async {
    try {
      final plan = await TwoDFanAccountService.instance.inspect(
        resource.id,
        baseOverride: _hostOf(resource.webUrl),
      );
      return PatchDeliveryDetail.fromFanPlan(resource, plan);
    } catch (e) {
      // 🔴 解析失败**不改变**条目的底线能力：仍然可以跳原页
      return PatchDeliveryDetail.fromResource(resource).copyWith(
        error: '抓取资源页失败：$e',
        reason: '暂时读不到下载方式，可以先打开原页',
      );
    }
  }

  /// `https://2dfmax.top/downloads/123` → `2dfmax.top`（拿不到就返回 null）
  static String? _hostOf(String url) {
    final host = Uri.tryParse(url.trim())?.host ?? '';
    return host.isEmpty ? null : host;
  }

  /// 兑换后手动更新缓存（拿到新 plan 时直接写回，省一次请求）
  void put(String key, PatchDeliveryDetail detail) {
    _cache[key] = _CachedDetail(detail, DateTime.now());
  }

  /// 丢弃某条缓存（用户改 Cookie / 重新登录后必须调，否则显示旧身份）
  void invalidate(String key) => _cache.remove(key);

  /// 全部丢弃（登录态变更时调）
  void invalidateAll() => _cache.clear();

  /// 供探针重置
  void resetForTest() {
    _cache.clear();
    _inflight.clear();
  }
}

class _CachedDetail {
  final PatchDeliveryDetail detail;
  final DateTime at;

  _CachedDetail(this.detail, this.at);

  bool get isExpired =>
      DateTime.now().difference(at) > PatchDeliveryService.kCacheTtl;
}

/// 一条补丁的投递详情（UI 只认这个结构，浅色展开位与深色栏共用）。
class PatchDeliveryDetail {
  /// 主形态（决定主按钮）
  final PatchDelivery delivery;

  /// 全部可用入口
  final List<PatchDeliveryLink> links;

  /// 不能直接下载时的**人话**说明（空串 = 无需提示）
  final String reason;

  /// 抓取/解析错误（非空时 UI 显示一行错误 + 「重试」）
  final String? error;

  // ---- 2DFan 专属：积分账 ----

  /// 本次费用（积分）；null = 站点没标价
  final int? price;

  /// 账号积分余额
  final int? balance;

  /// 是否已登录 2DFan
  final bool authenticated;

  /// 账号摘要（「已登录：xxx · 积分 42」）
  final String accountSummary;

  /// 技术上可以兑换（已登录 + 余额够 + 有端点）
  final bool canPurchase;

  /// 页面提示站点本身要求登录/兑换（用于按钮文案）
  final bool requiresPurchase;

  const PatchDeliveryDetail({
    required this.delivery,
    this.links = const <PatchDeliveryLink>[],
    this.reason = '',
    this.error,
    this.price,
    this.balance,
    this.authenticated = false,
    this.accountSummary = '',
    this.canPurchase = false,
    this.requiresPurchase = false,
  });

  /// 从模型现有信息构造（鲲 / 社区，以及 2DFan 抓取失败时的兜底）
  factory PatchDeliveryDetail.fromResource(PatchResource r) {
    final links = <PatchDeliveryLink>[...r.links];
    // 模型里可能只有主入口（老缓存 / 社区源），补进列表，避免详情空着
    if (links.isEmpty) {
      final direct = (r.directUrl ?? '').trim();
      final netdisk = (r.netdiskUrl ?? '').trim();
      if (direct.isNotEmpty) {
        links.add(PatchDeliveryLink(
          url: direct,
          kind: PatchDelivery.direct,
          label: Uri.tryParse(direct)?.host ?? '直链',
        ));
      }
      if (netdisk.isNotEmpty) {
        links.add(PatchDeliveryLink(
          url: netdisk,
          kind: PatchDelivery.netdisk,
          label: r.netdiskProvider?.displayName ?? '网盘',
          extractCode: r.extractCode,
          provider: r.netdiskProvider?.displayName,
        ));
      }
    }
    return PatchDeliveryDetail(
      delivery: r.delivery,
      links: links,
      reason: r.delivery == PatchDelivery.web ? '这个条目没有可直接下载的文件' : '',
    );
  }

  /// 从 2DFan 页面判定构造
  factory PatchDeliveryDetail.fromFanPlan(
    PatchResource r,
    FanDownloadPlan plan,
  ) {
    final links = plan.links
        .where((l) => l.kind == FanLinkKind.direct || l.kind == FanLinkKind.netdisk)
        .map((l) => PatchDeliveryLink(
              url: l.url,
              kind: l.kind == FanLinkKind.direct
                  ? PatchDelivery.direct
                  : PatchDelivery.netdisk,
              label: l.provider ?? l.label,
              extractCode: l.extractCode,
              provider: l.provider,
            ))
        .toList(growable: false);

    final hasDirect = links.any((l) => l.isDirect);
    final hasNetdisk = links.any((l) => !l.isDirect);
    final delivery = hasDirect
        ? PatchDelivery.direct
        : (hasNetdisk ? PatchDelivery.netdisk : PatchDelivery.web);

    return PatchDeliveryDetail(
      delivery: delivery,
      links: links,
      reason: plan.reason,
      price: plan.price,
      balance: plan.balance,
      authenticated: plan.authenticated,
      accountSummary: FanAccountInfo(
        loggedIn: plan.authenticated,
        points: plan.balance,
      ).summary,
      canPurchase: plan.canPurchase || plan.canAcquireFree,
      requiresPurchase: plan.requiresPurchase,
    );
  }

  PatchDeliveryDetail copyWith({
    PatchDelivery? delivery,
    List<PatchDeliveryLink>? links,
    String? reason,
    String? error,
    int? price,
    int? balance,
    bool? authenticated,
    String? accountSummary,
    bool? canPurchase,
    bool? requiresPurchase,
  }) {
    return PatchDeliveryDetail(
      delivery: delivery ?? this.delivery,
      links: links ?? this.links,
      reason: reason ?? this.reason,
      error: error ?? this.error,
      price: price ?? this.price,
      balance: balance ?? this.balance,
      authenticated: authenticated ?? this.authenticated,
      accountSummary: accountSummary ?? this.accountSummary,
      canPurchase: canPurchase ?? this.canPurchase,
      requiresPurchase: requiresPurchase ?? this.requiresPurchase,
    );
  }

  List<PatchDeliveryLink> get directLinks =>
      links.where((l) => l.isDirect).toList(growable: false);

  List<PatchDeliveryLink> get netdiskLinks =>
      links.where((l) => !l.isDirect).toList(growable: false);

  bool get hasDirect => directLinks.isNotEmpty;
  bool get hasNetdisk => netdiskLinks.isNotEmpty;

  /// 主直链（软件内下载用它）
  String? get primaryDirectUrl =>
      directLinks.isEmpty ? null : directLinks.first.url;

  /// 主网盘（「复制链接与提取码」用它）
  PatchDeliveryLink? get primaryNetdisk =>
      netdiskLinks.isEmpty ? null : netdiskLinks.first;

  bool get isFan => price != null || requiresPurchase || authenticated;
}
