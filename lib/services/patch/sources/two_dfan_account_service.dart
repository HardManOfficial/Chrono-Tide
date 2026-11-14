import 'dart:async';

import 'package:dio/dio.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'two_dfan_page_parser.dart';

/// 2DFan 账号会话：用**用户自己的浏览器登录态**做校验、查价、兑换。
///
/// ## 🔴 为什么不「代登录」（先读这段，别再想着做密码登录）
///
/// 2DFan 的登录页（实测 `2dfmax.top/login`）表单是：
///
/// ```html
/// <form action="/login" method="post">
///   <input name="login"> <input name="password">
///   <div class="cf-turnstile" data-sitekey="0x4AAAAAAAju-ZORvFgbC-Cd"></div>
/// </form>
/// ```
///
/// 验证码是 **Cloudflare Turnstile**。它在真实浏览器里跑指纹挑战，服务端会
/// 校验一次性 token。⇒ **任何纯 HTTP 的「输密码代登录」都不可能通过**，
/// 内嵌 WebView 也大概率被判 bot。参考项目 GalGear 同样**不做代登录**，
/// 而是让用户把浏览器里的会话 Cookie 交给软件（`FanCredentials{cookie, token}`，
/// 存 Windows 凭据管理器）。
///
/// 所以这里的「登录」= **复用你已经登录过的浏览器会话**。用户在浏览器登录一次
/// （Turnstile 由他本人拖一下），把 Cookie 粘进设置页，软件这边就拥有了完整的
/// 账号能力：看昵称、看积分、用积分兑换、把兑换后的文件下到本地。
///
/// ## 🔴 不可逆操作的护栏（三条，缺一不可）
///
/// 1. **下单前重新查价**：`purchase()` 先 `inspect()` 一次，`fresh.price` 必须
///    等于用户确认时看到的价格；不等就中止（`priceChanged`）。
/// 2. **只 POST 一次**：⛔ 绝不自动重试。超时/网络错误时我们**不知道**服务器
///    有没有扣分 —— 此时只能告知用户「结果不确定，请去网页确认」，
///    让用户自己判断（自动重发可能导致**重复扣分**）。
/// 3. **下单后再查一次**：只有确认页面已出现文件链接，才算成功。
///
/// ## 镜像与 Cookie 的关系（用户最容易踩的坑）
///
/// Cookie 是**按域名**存的。用户在 `2dfan.com` 登录、软件却在 `2dfmax.top`
/// 请求 ⇒ 会话不认，表现就是「明明登录了却显示未登录」。
/// ⇒ [resolveBase] 会把实际使用的域名暴露给 UI，设置页必须显示它并提示
/// 「请在同一个域名下登录」。
class TwoDFanAccountService {
  TwoDFanAccountService._();

  static final TwoDFanAccountService instance = TwoDFanAccountService._();

  /// 全镜像失败后的软冷却（与 `TwoDFanPatchSource` 同口径，⛔ 不要永久置空）
  static const Duration kAllFailedCooldown = Duration(minutes: 2);

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  String? _resolvedBase;
  DateTime? _cooldownUntil;

  /// 下单单飞闸：⛔ 同一时刻只允许一笔兑换在路上。
  ///
  /// 没有这个闸，用户连点两下「兑换」就会发两次 POST = **扣两次积分**。
  bool _purchasing = false;

  bool get isPurchasing => _purchasing;

  /// 供 UI 显示「当前用的是哪个镜像」与探针注入
  String? get resolvedBase => _resolvedBase;

  /// 供探针注入 Dio（跳过真实网络）
  Dio? dioOverride;

  /// 供探针注入 cookie
  String? cookieOverride;

  // ==================== 会话 ====================

  Future<String?> _cookie() async {
    final forced = cookieOverride;
    if (forced != null) return forced.trim().isEmpty ? null : forced.trim();
    return TwoDFanCookieStore.load();
  }

  /// 解析可用镜像（运行期回退 + 软冷却）。
  ///
  /// [preferBase] 可以让调用方指定域名（用户在哪个域登录就用哪个）——
  /// 这是「Cookie 与域名绑定」这个坑的唯一解药。
  Future<String?> resolveBase({String? preferBase}) async {
    final forced = (preferBase ?? '').trim();
    if (forced.isNotEmpty) {
      final normalized = _normalizeBase(forced);
      if (normalized != null) {
        _resolvedBase = normalized;
        return normalized;
      }
    }

    final cooldown = _cooldownUntil;
    if (cooldown != null && DateTime.now().isBefore(cooldown)) {
      return null;
    }
    final cached = _resolvedBase;
    if (cached != null && await _probe(cached)) return cached;

    for (final domain in TwoDFanService.kFanDomains) {
      if (await _probe(domain)) {
        _resolvedBase = domain;
        _cooldownUntil = null;
        return domain;
      }
    }
    _cooldownUntil = DateTime.now().add(kAllFailedCooldown);
    return null;
  }

  Future<bool> _probe(String base) async {
    try {
      final resp = await _client(base).get<String>(
        '$base/',
        options: Options(responseType: ResponseType.plain),
      );
      final body = resp.data ?? '';
      // 🔴 只判 200 不够：主域会返回 200 的风控/占位页，必须看站内特征串
      return body.contains('2dfan') ||
          body.contains('subject') ||
          body.contains('download');
    } catch (_) {
      return false;
    }
  }

  /// 构造带 Cookie 的 Dio。
  ///
  /// ⚠️ Cookie 只发给**这一个域**：2DFan 的站内文件/签名直链是同域或自有 CDN，
  /// 不带 cookie 也能下（参考项目就刻意用「无凭证 client」下 CDN）。
  Dio _client(String base, {String? cookie}) {
    final dio = dioOverride ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 25),
          followRedirects: true,
          headers: <String, dynamic>{
            'User-Agent': _ua,
            'Accept': 'text/html,application/xhtml+xml',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
        ));
    applyProxyConfig(null, dio);
    return dio;
  }

  Future<String> _getHtml(String base, String path, {String? cookie}) async {
    final resp = await _client(base, cookie: cookie).get<String>(
      '$base$path',
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data ?? '';
  }

  // ==================== 账号校验 ====================

  /// 读当前登录状态与积分。
  ///
  /// [baseOverride] 允许 UI 指定域名（用户在哪登录就查哪）。
  /// [cookie] 允许调用方**用一份未落盘的 Cookie** 试一次（设置页「粘贴后立即
  /// 校验」用），不传则读已保存的。
  Future<FanAccountInfo> check({String? baseOverride, String? cookie}) async {
    final inline = (cookie ?? '').trim();
    final session = inline.isNotEmpty ? inline : await _cookie();
    if (session == null) return FanAccountInfo.anonymous;

    final base = await resolveBase(preferBase: baseOverride);
    if (base == null) {
      throw const TwoDFanSessionError('所有 2DFan 镜像都不可达');
    }
    final html = await _getHtml(base, '/', cookie: session);
    return TwoDFanPageParser.parseAccount(html);
  }

  // ==================== 查价 ====================

  /// 读某个资源页的完整判定（价格 / 余额 / 能否兑换 / 网盘入口）。
  ///
  /// 🔴 **匿名也能调**：2DFan 的「网盘载点」不需要登录就能看到，
  /// 所以详情页可以先匿名抓到网盘链接，再让用户决定要不要登录换直连。
  Future<FanDownloadPlan> inspect(
    String downloadId, {
    String? baseOverride,
  }) async {
    final id = downloadId.trim();
    if (id.isEmpty || !RegExp(r'^\d+$').hasMatch(id)) {
      throw const TwoDFanSessionError('资源 id 不合法');
    }
    final base = await resolveBase(preferBase: baseOverride);
    if (base == null) {
      throw const TwoDFanSessionError('所有 2DFan 镜像都不可达');
    }
    final cookie = await _cookie();
    final html = await _getHtml(base, '/downloads/$id', cookie: cookie);
    return TwoDFanPageParser.parseDownloadPage(html, '$base/downloads/$id');
  }

  // ==================== 兑换（不可逆）====================

  /// 消耗积分兑换站内直链。
  ///
  /// [confirmedPrice] 是**用户在确认框里看到并同意的价格**。传 null 表示
  /// 「页面没标价」—— 那种情况一律拒绝，⛔ 不在不知道价格的情况下扣分。
  Future<FanPurchaseResult> purchase(
    String downloadId, {
    required int? confirmedPrice,
    String? baseOverride,
  }) async {
    if (_purchasing) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '上一笔兑换还没结束，请稍候',
      );
    }
    _purchasing = true;
    try {
      return await _purchaseInner(
        downloadId,
        confirmedPrice: confirmedPrice,
        baseOverride: baseOverride,
      );
    } finally {
      _purchasing = false;
    }
  }

  Future<FanPurchaseResult> _purchaseInner(
    String downloadId, {
    required int? confirmedPrice,
    String? baseOverride,
  }) async {
    final id = downloadId.trim();
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '资源 id 不合法',
      );
    }
    final cookie = await _cookie();
    if (cookie == null) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '还没有配置 2DFan 登录 Cookie',
      );
    }

    // ---- ① 下单前复核：价格、登录态、余额、端点都必须重新成立 ----
    final FanDownloadPlan fresh;
    try {
      fresh = await inspect(id, baseOverride: baseOverride);
    } catch (e) {
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '下单前复核失败：$e',
      );
    }

    if (fresh.fileUrl != null && !fresh.requiresPurchase) {
      // 站点已经给了文件（可能上次已兑换），不必再扣一次
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.alreadyAvailable,
        plan: fresh,
        message: '站点已给出下载链接，不需要再兑换',
      );
    }
    if (confirmedPrice == null || fresh.price == null) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '页面没有标价，已中止（不会在未知价格下扣积分）',
      );
    }
    if (fresh.price != confirmedPrice) {
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '价格已变化（你确认时 $confirmedPrice 积分，现在 ${fresh.price} 积分），已中止',
      );
    }
    if (!fresh.authenticated) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '登录态已失效，请重新导入 Cookie',
      );
    }
    if (fresh.balance == null) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '读不到账号积分，已中止（不会在未知余额下扣积分）',
      );
    }
    if (fresh.balance! < fresh.price!) {
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '积分不足（需 ${fresh.price}，当前 ${fresh.balance}）',
      );
    }
    final action = fresh.purchaseAction;
    final csrf = fresh.csrf;
    if (action == null || csrf == null || csrf.isEmpty) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '站点没有给出兑换端点，请到网页端操作',
      );
    }

    // ---- ② 只发这一次 POST ----
    final base = await resolveBase(preferBase: baseOverride);
    if (base == null) {
      return const FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '所有 2DFan 镜像都不可达',
      );
    }

    try {
      final resp = await _client(base, cookie: cookie).post<String>(
        action,
        data: <String, String>{'authenticity_token': csrf},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: <String, dynamic>{
            // 站点会校验来源，缺失容易被当成 CSRF 攻击
            'Referer': '$base/downloads/$id',
            'Origin': base,
          },
          // 3xx 一律不自动跟随：跟随可能把「扣分成功后的跳转」变成第二次副作用
          followRedirects: false,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      final code = resp.statusCode ?? 0;
      if (code >= 400) {
        return FanPurchaseResult(
          outcome: FanPurchaseOutcome.uncertain,
          message: '站点返回 $code，无法确认是否已扣分，请到网页端核对',
        );
      }
    } catch (e) {
      // 🔴 网络错误时**绝不能重试**：可能已经扣了分，重试就是扣第二次
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.uncertain,
        message: '请求异常（$e）。可能已扣分，请先到网页端核对，不要直接重试',
      );
    }

    // ---- ③ 下单后再读一次，确认真的拿到了文件 ----
    try {
      final after = await inspect(id, baseOverride: baseOverride);
      if (after.fileUrl != null) {
        return FanPurchaseResult(
          outcome: FanPurchaseOutcome.purchased,
          plan: after,
          message: '兑换成功',
        );
      }
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.uncertain,
        plan: after,
        message: '已提交兑换，但页面还没出现下载链接。请稍后重新打开本条目查看',
      );
    } catch (e) {
      return FanPurchaseResult(
        outcome: FanPurchaseOutcome.uncertain,
        message: '兑换请求已发出，但复核失败（$e）。请到网页端确认',
      );
    }
  }

  // ==================== 内部 ====================

  static String? _normalizeBase(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    return '${uri.scheme}://${uri.host}';
  }
}

/// 兑换结果语义。
enum FanPurchaseOutcome {
  /// 兑换成功且已拿到文件链接
  purchased,

  /// 站点本来就已经给了文件（上次兑换过），没有额外扣分
  alreadyAvailable,

  /// 明确失败（未扣分）：未登录 / 积分不足 / 价格变化 / 无端点
  failed,

  /// **结果不确定**：请求发出但没拿到确认。可能已扣分。
  /// ⇒ UI 必须提示用户去网页核对，⛔ 不允许「一键重试」。
  uncertain,
}

class FanPurchaseResult {
  final FanPurchaseOutcome outcome;
  final FanDownloadPlan? plan;
  final String message;

  const FanPurchaseResult({
    required this.outcome,
    this.plan,
    this.message = '',
  });

  bool get isSuccess =>
      outcome == FanPurchaseOutcome.purchased ||
      outcome == FanPurchaseOutcome.alreadyAvailable;
}

class TwoDFanSessionError implements Exception {
  final String message;
  const TwoDFanSessionError(this.message);
  @override
  String toString() => message;
}
