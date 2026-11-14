import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// 2DFan 页面解析（纯函数：无网络、无 Flutter 依赖）。
///
/// ## 为什么单独成文件
///
/// 2DFan 是 **HTML 站**，能力边界全看页面结构。把解析从 `TwoDFanPatchSource`
/// 里抽出来有三个好处：
///
/// 1. 裸 Dart 探针能直接对着**真实抓下来的 HTML** 跑（`dart run dev_probe/...`），
///    不必起 Flutter、不必联网；
/// 2. 站点改版时，坏的只可能是这一个文件，一眼能定位；
/// 3. 「登录态 / 积分 / 价格 / 下载入口」四件事的判定规则集中在此，
///    ⛔ 不会在 UI 与网络层各写一份、慢慢走样。
///
/// ## 实测页面结构（2026-11-13，`2dfmax.top/downloads/38989`）
///
/// ### ① 账号（每个页面都有，`NexusHeader` 岛）
/// ```html
/// <header data-island="NexusHeader"
///         data-props='{"user":{"id":1,"name":"Tester","points":42}, ...}'>
/// ```
/// 未登录时 `user` 是 `null`。🔴 **只认这一处**：正文里随便写着「9999积分」
/// 的评论不算（参考项目 GalGear 的同名测试就是钉这一条）。
///
/// ### ② 资源信息四格
/// ```html
/// <div class="download-info-item">
///   <span class="download-info-label">价格</span>
///   <span class="download-info-value">7 积分</span>
/// </div>
/// ```
/// 四格依次是「分类 / 大小 / 价格 / 安全评估」。🔴 价格只看 label **精确等于**
/// 「价格」的那一格 —— 评论区和「相关资源」里也有「N 积分」字样。
///
/// ### ③ 下载链接区（未登录时也能拿到网盘！）
/// ```html
/// <div class="download-links-body">
///   <a class="download-btn download-btn--danger" href="/login">登录下载</a>
///   <a class="download-btn download-btn--primary" target="_blank"
///      href="https://pan.baidu.com/s/xxx?pwd=ep1f">网盘载点1</a>
/// </div>
/// ```
/// ⇒ **2DFan 并非「只有登录才能下载」**：站内直连要点数，但**网盘载点匿名可见**，
/// 提取码就内嵌在 URL 的 `pwd` 参数里。这一条以前被整体忽略，导致用户被迫
/// 跳原页 —— 见 [parseFanDownloadPage] 的 `links`。
///
/// ### ④ 登录后才出现的两条路
/// - `<form method="post" action="/downloads/{id}/purchase">` + `meta[csrf-token]`
///   → 消耗积分兑换（**不可逆**，必须二次确认）
/// - `<a class="download-btn download-btn--primary" href="https://d1.acgxp.com/...">`
///   → 兑换后站点给出的 CDN 直链（`d1/d2/d3.acgxp.com`、`file.achost.top`）

/// 2DFan 账号快照。
class FanAccountInfo {
  /// 是否已登录（`user.id > 0` 或有昵称）
  final bool loggedIn;

  /// 昵称（未登录为空串）
  final String nickname;

  /// 积分余额；`null` = 页面没给（⛔ 不要默认成 0，那会被误判成「积分不足」）
  final int? points;

  const FanAccountInfo({
    required this.loggedIn,
    this.nickname = '',
    this.points,
  });

  static const FanAccountInfo anonymous = FanAccountInfo(loggedIn: false);

  /// 给 UI 的一行摘要
  String get summary {
    if (!loggedIn) return '未登录';
    final who = nickname.isEmpty ? '已登录' : '已登录：$nickname';
    return points == null ? who : '$who · 积分 $points';
  }
}

/// 下载页上的一个可用入口。
enum FanLinkKind {
  /// 站内 CDN 直连（`d1.acgxp.com` 等，需要已兑换）
  direct,

  /// 网盘分享（百度 / 夸克 / 蓝奏…），匿名可见
  netdisk,

  /// 站点要求先登录（`href="/login"` 的「登录下载」按钮）
  loginGate,

  /// 站点要求先消耗积分（`/downloads/{id}/purchase`）
  purchaseGate,
}

class FanPageLink {
  final String url;

  /// 页面上显示的文字，如「网盘载点1」「海外直连」「登录下载」
  final String label;

  final FanLinkKind kind;

  /// 网盘提取码（从 URL 的 `pwd` / `password` / `code` 取）
  final String? extractCode;

  /// 网盘服务商（百度网盘 / 夸克网盘…）；直链为 null
  final String? provider;

  const FanPageLink({
    required this.url,
    required this.label,
    required this.kind,
    this.extractCode,
    this.provider,
  });

  @override
  String toString() => '${kind.name}($label):$url';
}

/// 一个下载页的完整判定结果。
///
/// 🔴 [canPurchase] 为 true 只代表「**技术上可以发那一次 POST**」，
/// 调用方必须在真正下单前再跑一次 [parseFanDownloadPage] 做**价格复核**
/// （见 `TwoDFanAccountService.purchase`），⛔ 不能拿旧 plan 直接下单。
class FanDownloadPlan {
  /// 资源标题（`main h1`）
  final String title;

  /// 价格（积分）。`null` = 页面没标价
  final int? price;

  /// 当前账号积分
  final int? balance;

  final bool authenticated;

  /// 必须消耗积分才能拿到站内直链
  final bool requiresPurchase;

  /// 已登录 + 余额够 + 有兑换端点 + 有 csrf ⇒ 可以下单
  final bool canPurchase;

  /// 价格为 0 但站点仍要求过一次兑换表单
  final bool canAcquireFree;

  /// 已经能直接下的站内文件（兑换后才有）
  final String? fileUrl;

  /// 兑换表单地址（`/downloads/{id}/purchase`）
  final String? purchaseAction;

  /// CSRF token（下单必须带）
  final String? csrf;

  /// 页面上的**全部**可用入口：网盘载点、已拿到的直连、以及「登录下载」占位。
  ///
  /// 🔴 顺序即页面顺序。同一个资源可能有多个网盘（网盘载点1/2/3），
  /// ⛔ 不要只留第一个 —— 那是旧实现的缺陷（用户想看全部）。
  final List<FanPageLink> links;

  /// 不能下载时的**人话**原因（可直接上屏）
  final String reason;

  const FanDownloadPlan({
    required this.title,
    this.price,
    this.balance,
    this.authenticated = false,
    this.requiresPurchase = false,
    this.canPurchase = false,
    this.canAcquireFree = false,
    this.fileUrl,
    this.purchaseAction,
    this.csrf,
    this.links = const <FanPageLink>[],
    this.reason = '',
  });

  /// 匿名可见的网盘入口（不需要登录、不需要积分）
  List<FanPageLink> get netdiskLinks =>
      links.where((l) => l.kind == FanLinkKind.netdisk).toList(growable: false);

  /// 已经拿到的站内直链
  List<FanPageLink> get directLinks =>
      links.where((l) => l.kind == FanLinkKind.direct).toList(growable: false);

  /// 是否有任何**立即可用**的下载入口（网盘或已拿到的直链）
  bool get hasImmediateLink => netdiskLinks.isNotEmpty || directLinks.isNotEmpty;

  bool get hasAny => links.isNotEmpty;
}

abstract final class TwoDFanPageParser {
  /// 站点自有的下载 CDN（兑换后直链落在这里）
  static const List<String> cdnHosts = <String>[
    'd1.acgxp.com',
    'd2.acgxp.com',
    'd3.acgxp.com',
    'file.achost.top',
  ];

  /// 网盘域名 → 显示名（顺序有意义：先具体后泛化）
  static const List<List<String>> _netdiskHosts = <List<String>>[
    <String>['pan.baidu.com', '百度网盘'],
    <String>['pan.quark.cn', '夸克网盘'],
    <String>['quark.cn', '夸克网盘'],
    <String>['lanzou', '蓝奏云'],
    <String>['123pan.com', '123 网盘'],
    <String>['123684.com', '123 网盘'],
    <String>['123865.com', '123 网盘'],
    <String>['mega.nz', 'MEGA'],
    <String>['aliyundrive.com', '阿里云盘'],
    <String>['alipan.com', '阿里云盘'],
    <String>['115.com', '115'],
    <String>['caiyun.139.com', '移动云盘'],
    <String>['drive.uc.cn', 'UC 网盘'],
  ];

  // ==================== 账号 ====================

  /// 从任意 2DFan 页面解析账号状态。
  ///
  /// ⚠️ 站点把用户信息塞在 `NexusHeader` 岛的 `data-props`（JSON），
  /// 且 JSON 里的引号被 HTML 实体转义（`&quot;`）—— [Document] 已自动解码，
  /// 所以这里拿到的是正常 JSON 文本。
  static FanAccountInfo parseAccount(String html) {
    if (html.trim().isEmpty) return FanAccountInfo.anonymous;
    final doc = html_parser.parse(html);
    final props = doc
        .querySelector("header[data-island='NexusHeader'][data-props]")
        ?.attributes['data-props'];
    if (props == null || props.trim().isEmpty) {
      return FanAccountInfo.anonymous;
    }
    final user = _jsonUser(props);
    if (user == null) return FanAccountInfo.anonymous;

    final id = _asInt(user['id']);
    final nickname = _firstString(user, const ['name', 'username', 'display_name']);
    final authenticated = (id != null && id > 0) || nickname.isNotEmpty;

    // 🔴 未登录时 points 一律置 null：站点游客态可能残留 0，
    //    把它当余额会让 UI 显示「积分 0」并误判「积分不足」。
    final points = authenticated
        ? _firstInt(user, const ['points', 'point', 'credits', 'credit'])
        : null;

    return FanAccountInfo(
      loggedIn: authenticated,
      nickname: nickname,
      points: points,
    );
  }

  // ==================== 下载页 ====================

  /// 解析 `/downloads/{id}` 页面。
  ///
  /// [pageUrl] 用来解析相对链接、并判断「同源 / 跨域」。
  static FanDownloadPlan parseDownloadPage(String html, String pageUrl) {
    final doc = html_parser.parse(html);
    final account = parseAccount(html);
    final src = Uri.tryParse(pageUrl.trim());

    final title = (doc.querySelector('main h1')?.text ?? '').trim();

    // ---- 价格：只认 label 精确等于「价格」的那一格 ----
    int? price;
    for (final row in doc.querySelectorAll('main .download-info-item')) {
      final label =
          (row.querySelector('.download-info-label')?.text ?? '').trim();
      if (label != '价格') continue;
      final value = (row.querySelector('.download-info-value')?.text ?? '').trim();
      price = _parsePoints(value);
      if (price != null) break;
    }

    final csrf = (doc.querySelector("meta[name='csrf-token']")?.attributes['content'] ?? '')
        .trim();

    // ---- 遍历下载按钮 ----
    String? fileUrl;
    String? purchaseAction;
    final links = <FanPageLink>[];
    var hasLoginGate = false;
    var hasPurchaseGate = false;

    for (final a in doc.querySelectorAll('main a[href]')) {
      final rawHref = (a.attributes['href'] ?? '').trim();
      if (rawHref.isEmpty) continue;
      final abs = _absolutize(rawHref, src);
      if (abs.isEmpty) continue;

      final label = a.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      final classes = (a.attributes['class'] ?? '').split(RegExp(r'\s+'));
      final isBtn = classes.contains('download-btn') ||
          classes.any((c) => c.startsWith('download-btn--'));

      // ① 「登录下载」占位
      if (_isLoginGate(abs, rawHref, label)) {
        // 🔴 页面导航栏、评论区、下载区各有一个指向 /login 的链接，
        //    只记第一次（下载区那个「登录下载」），否则详情里会冒出 3 条重复项
        if (!hasLoginGate) {
          links.add(FanPageLink(
            url: abs,
            label: label.isEmpty ? '登录下载' : label,
            kind: FanLinkKind.loginGate,
          ));
        }
        hasLoginGate = true;
        continue;
      }

      // ② 兑换端点（`/downloads/{id}/purchase`）
      if (src != null &&
          _isPurchaseAction(abs, src) &&
          (label.contains('购买') ||
              label.contains('兑换') ||
              (a.attributes['data-turbo-method'] ?? '').toLowerCase() == 'post')) {
        hasPurchaseGate = true;
        purchaseAction ??= abs;
        continue;
      }

      // ③ 网盘载点（label 明确写着「网盘」最可靠；再按域名兜底）
      final provider = _netdiskProvider(abs);
      final looksNetdisk =
          label.contains('网盘') || label.contains('载点') || provider != null;
      if (looksNetdisk && provider != null) {
        links.add(FanPageLink(
          url: abs,
          label: label.isEmpty ? provider : label,
          kind: FanLinkKind.netdisk,
          extractCode: _extractCode(abs),
          provider: provider,
        ));
        continue;
      }

      // ④ 站内/自有 CDN 直链
      if (_looksLikeFile(abs, src, label) &&
          (a.attributes['data-turbo-method'] ?? 'get').toLowerCase() == 'get') {
        final link = FanPageLink(
          url: abs,
          label: label.isEmpty ? '直连下载' : label,
          kind: FanLinkKind.direct,
        );
        links.add(link);
        // 与参考项目一致：主按钮优先，后面若还有直连则不覆盖
        if (fileUrl == null || classes.contains('download-btn--primary')) {
          fileUrl = abs;
        }
        if (isBtn) continue;
      }
    }

    // ---- 兑换表单（<form method="post" action="…/purchase">）----
    for (final form in doc.querySelectorAll("main form[method='post'][action]")) {
      final action = _absolutize((form.attributes['action'] ?? '').trim(), src);
      if (action.isEmpty || src == null || !_isPurchaseAction(action, src)) {
        continue;
      }
      purchaseAction ??= action;
      // 表单文本形如「消耗 2 积分下载」；页面没有价格格时用它兜底
      final text = form.text.replaceAll(RegExp(r'\s+'), '');
      if (price == null) price = _parseFormCost(text);
    }

    // ---- 状态判定（逐字对齐参考项目语义）----
    final free = price == 0 ||
        (fileUrl != null && price == null && purchaseAction == null);

    final canAcquireFree = price == 0 &&
        account.loggedIn &&
        purchaseAction != null &&
        csrf.isNotEmpty;

    final requiresPurchase = !free &&
        fileUrl == null &&
        (purchaseAction != null || (price != null && !account.loggedIn));

    final enoughPoints = price != null &&
        price > 0 &&
        account.points != null &&
        account.points! >= price;

    final canPurchase = requiresPurchase &&
        account.loggedIn &&
        enoughPoints &&
        purchaseAction != null &&
        csrf.isNotEmpty;

    return FanDownloadPlan(
      title: title,
      price: price,
      balance: account.points,
      authenticated: account.loggedIn,
      requiresPurchase: requiresPurchase,
      canPurchase: canPurchase,
      canAcquireFree: canAcquireFree,
      fileUrl: fileUrl,
      purchaseAction: purchaseAction,
      csrf: csrf.isEmpty ? null : csrf,
      links: links,
      reason: _reasonOf(
        account: account,
        price: price,
        fileUrl: fileUrl,
        canAcquireFree: canAcquireFree,
        canPurchase: canPurchase,
        requiresPurchase: requiresPurchase,
        hasNetdisk: links.any((l) => l.kind == FanLinkKind.netdisk),
        hasLoginGate: hasLoginGate || hasPurchaseGate,
      ),
    );
  }

  // ==================== 内部 ====================

  /// 不能下载的**人话**原因；能下载（或已有网盘兜底）时返回空串。
  static String _reasonOf({
    required FanAccountInfo account,
    required int? price,
    required String? fileUrl,
    required bool canAcquireFree,
    required bool canPurchase,
    required bool requiresPurchase,
    required bool hasNetdisk,
    required bool hasLoginGate,
  }) {
    if (fileUrl != null || canAcquireFree || canPurchase) return '';
    // 网盘免费可见 ⇒ 不拦，但登录后还能拿到站内直连（更快），给一句提示即可
    if (!account.loggedIn) {
      if (hasNetdisk) return '已有网盘载点可直接打开；登录后还能用积分兑换站内直连';
      if (hasLoginGate || requiresPurchase) return '需要登录 2DFan 账号后下载';
      return '需要登录 2DFan 账号';
    }
    if (requiresPurchase && price == null) return '站点没标价，无法安全兑换';
    if (requiresPurchase && account.points == null) return '读不到账号积分，无法安全兑换';
    if (requiresPurchase &&
        account.points != null &&
        price != null &&
        account.points! < price) {
      return '积分不足（需 $price，当前 ${account.points}）';
    }
    if (requiresPurchase) return '需要消耗积分兑换';
    return '站点没有给出可下载文件';
  }

  static bool _isLoginGate(String abs, String rawHref, String label) {
    if (label.contains('登录')) return true;
    final path = Uri.tryParse(abs)?.path ?? '';
    return path == '/login' || rawHref == '/login';
  }

  static bool _isPurchaseAction(String abs, Uri src) {
    final uri = Uri.tryParse(abs);
    if (uri == null) return false;
    if (uri.host.isNotEmpty && uri.host != src.host) return false;
    return uri.path == '${src.path}/purchase';
  }

  /// 是否是「文件下载」链接（⛔ 登录页 / 兑换端点 / 自身页面都不算）
  static bool _looksLikeFile(String abs, Uri? src, String label) {
    final uri = Uri.tryParse(abs);
    if (uri == null) return false;
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    if (uri.path == '/login' || uri.path.endsWith('/purchase')) return false;
    if (src != null && uri.path == src.path) return false;

    final host = uri.host.toLowerCase();
    if (cdnHosts.contains(host)) return true;

    // 文案命中（参考项目同款白名单）
    const labels = <String>['直连下载', '附件下载', '免费下载', '海外直连', '国内直连', '直链'];
    if (labels.any(label.contains)) return true;

    // 后缀命中（同源站内附件）
    if (src != null && host == src.host) {
      final lower = uri.path.toLowerCase();
      const exts = <String>['.zip', '.rar', '.7z', '.exe', '.tar', '.gz'];
      if (exts.any(lower.endsWith)) return true;
    }
    return false;
  }

  static String? _netdiskProvider(String url) {
    final lower = url.toLowerCase();
    for (final pair in _netdiskHosts) {
      if (lower.contains(pair[0])) return pair[1];
    }
    return null;
  }

  /// 网盘提取码：`?pwd=abcd` / `&password=abcd` / `?code=abcd`
  static String? _extractCode(String url) {
    final m = RegExp(
      r'[?&#](?:pwd|password|code|passcode)=([A-Za-z0-9]{1,32})',
      caseSensitive: false,
    ).firstMatch(url);
    final code = m?.group(1)?.trim();
    return (code == null || code.isEmpty) ? null : code;
  }

  /// `"7 积分"` / `"7积分"` / `"免费"` / `"--"` → 数字
  static int? _parsePoints(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.contains('免费') || s == '0') return 0;
    final m = RegExp(r'(\d[\d,]*)').firstMatch(s);
    if (m == null) return null;
    return int.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  /// `消耗2积分下载` → 2
  static int? _parseFormCost(String compactText) {
    final m = RegExp(r'消耗(\d+)积分').firstMatch(compactText);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  /// 解析 `NexusHeader` 的 `data-props` JSON，取出 `user` 对象。
  ///
  /// 站点会把这个 JSON 原样塞进属性里（`&quot;` 已由 HTML 解析器解码），
  /// 但**不能假定它一定合法**：站点改版 / 实验开关都可能塞进别的形状，
  /// 解析失败一律当「未登录」，⛔ 不要抛异常把整个检索带崩。
  static Map<String, dynamic>? _jsonUser(String props) {
    try {
      final decoded = jsonDecode(props);
      if (decoded is! Map) return null;
      final user = decoded['user'];
      return user is Map ? user.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static String _absolutize(String href, Uri? base) {
    if (href.isEmpty) return '';
    final uri = Uri.tryParse(href);
    if (uri == null) return '';
    if (uri.hasScheme) return uri.toString();
    if (base != null) {
      try {
        return base.resolveUri(uri).toString();
      } catch (_) {
        return '';
      }
    }
    return href;
  }

  static String _firstString(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static int? _firstInt(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = _asInt(m[k]);
      if (v != null) return v;
    }
    return null;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) {
      return int.tryParse(v.replaceAll(',', '').trim());
    }
    return null;
  }
}
