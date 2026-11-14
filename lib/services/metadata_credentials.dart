import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'network_proxy_policy.dart';
import 'patch/sources/two_dfan_account_service.dart';
import 'patch/sources/two_dfan_page_parser.dart';

/// 平台凭证类型（唯一定义，UI 与目录都从这里取）。
///
/// 只区分「用户可提供 / 不可提供」两类，刻意不引入 OAuth 授权码流程：
/// - Bangumi / 2DFan 从来没有给第三方开放注册 OAuth 应用；
/// - 鲲GAL 的 OAuth 回调地址写死在站点侧
///   （`https://www.kungal.com/auth/callback`），第三方客户端拿不到，
///   LunaBox 是自己注册了 public client 再在构建时注入 client_id，
///   这条路我们没有凭据可用。
/// 所以一期只做**凭据管理**：用户从浏览器拿到 Cookie / 令牌粘进来。
enum MetadataCredentialKind {
  /// 公开接口，无需任何凭证。
  none,

  /// 平台内置了客户端凭证（如 Hikarinagi 的 client_credentials），用户不用管。
  builtIn,

  /// 需要用户粘贴个人访问令牌（Bangumi PAT）。
  personalToken,

  /// 需要用户粘贴浏览器 Cookie（鲲GAL / 2DFan 登录态）。
  cookie,
}

/// 一次凭证校验的结果（三个平台共用一套形状）。
@immutable
class CredentialCheck {
  const CredentialCheck({
    required this.ok,
    required this.message,
    this.identity,
  });

  final bool ok;

  /// 给用户看的一句话：成功写「谁登录了 / 可用」，失败写清**为什么**。
  final String message;

  /// 登录身份（昵称 / 用户名 / uid），拿不到时为 null。
  final String? identity;
}

/// 鲲登录 Cookie 的探测结论（纯数据，便于裸 VM 断言）。
enum KunProbeVerdict {
  /// 站点认可这次请求（`code == 0`）。
  ok,

  /// 未登录 / 登录失效（HTTP 401 或 `code == 205`）。
  loginRequired,

  /// 站点明确拒绝（其它非 0 code），带 message。
  rejected,

  /// 说不清（网络异常、非 JSON）。
  unknown,
}

/// 元数据平台凭证的统一入口（UI 侧）。
///
/// 🔴 存储不重复造轮子：
/// - Bangumi 个人令牌沿用 SDK 的 `BangumiTokenStore`（key
///   `bangumi_personal_access_token`）—— 那边 `BangumiMirrorService` 每次
///   搜索都会 `loadToken()`，所以这里保存后**无需重启、无需清服务缓存**。
/// - 鲲 Cookie 存 SDK 的 `KunCookieStore`（key `kun_galgame_cookie`），
///   由 `KunService` 在每次请求时注入 `Cookie` 头。
/// - 2DFan Cookie 存 SDK 的 `TwoDFanCookieStore`（key `two_dfan_cookie`），
///   由 `TwoDFanService` 在每次请求时注入 `Cookie` 头。
///
/// 本类只负责「读 / 写 / 校验」，不持有状态，UI 直接调静态方法。
class MetadataCredentialService {
  MetadataCredentialService._();

  // ─────────────────────── Bangumi ───────────────────────

  /// 校验 Bangumi 个人访问令牌：请求 `GET /v0/me`。
  ///
  /// 比「显示已登录」更有信息量：成功时把昵称 / 用户名 显示出来，
  /// 用户能确认填的是**自己的**令牌；失败时区分「令牌无效」与「网络不通」，
  /// 否则用户会把代理问题当成令牌问题（反过来也一样）。
  static Future<CredentialCheck> verifyBangumiToken(String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      return const CredentialCheck(ok: false, message: '令牌为空');
    }

    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      headers: <String, String>{
        // Bangumi 要求 UA 带应用标识，否则可能被 403
        'User-Agent': 'ChronoTide/1.0 (Metadata Credential Check)',
        'Accept': 'application/json',
        'Authorization': 'Bearer $trimmed',
      },
    ));
    NetworkProxyPolicy.instance.attachTo(dio);

    try {
      final Response<dynamic> res =
          await dio.get<dynamic>('https://api.bgm.tv/v0/me');
      final dynamic body = res.data;
      if (res.statusCode == 200 && body is Map) {
        final Map<dynamic, dynamic> map = body;
        final String nickname = (map['nickname'] ?? '').toString().trim();
        final String username = (map['username'] ?? '').toString().trim();
        return CredentialCheck(
          ok: true,
          identity: nickname.isNotEmpty ? nickname : username,
          message: '令牌有效',
        );
      }
      return CredentialCheck(
        ok: false,
        message: '接口返回 ${res.statusCode}',
      );
    } on DioException catch (e) {
      final int? code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        return CredentialCheck(
          ok: false,
          message: '令牌无效或已过期（HTTP $code）',
        );
      }
      return CredentialCheck(
        ok: false,
        message: '网络请求失败：${_briefError(e, 'api.bgm.tv')}',
      );
    } catch (e) {
      return CredentialCheck(ok: false, message: '校验失败：$e');
    } finally {
      dio.close(force: true);
    }
  }

  // ─────────────────────── 鲲GAL/NextMoe ───────────────────────

  /// 纯函数：把一次 `/api/search` 的响应翻译成结论。
  ///
  /// 🔴 为什么不能只看状态码：鲲在「未登录」时回的是 **HTTP 200 +
  /// `{"code":205,"message":"用户登录失效"}`**，只看 200 会把登录失效
  /// 显示成「已登录」。
  static KunProbeVerdict interpretKunProbe({
    required int? statusCode,
    required Object? body,
  }) {
    if (statusCode == 401 || statusCode == 403) {
      return KunProbeVerdict.loginRequired;
    }
    if (body is Map) {
      final Object? code = body['code'];
      if (code == 205 || code == '205') return KunProbeVerdict.loginRequired;
      if (code == 0 || code == '0') return KunProbeVerdict.ok;
      if (code != null) return KunProbeVerdict.rejected;
      // 没有 code 但结构像搜索结果（NextMoe 风格）也算通
      return KunProbeVerdict.ok;
    }
    return KunProbeVerdict.unknown;
  }

  /// 从鲲的响应体里尽量捞一个身份名（昵称 / 用户名 / uid）。
  static String? kunIdentityOf(Object? body) {
    if (body is! Map) return null;
    final Object? data = body['data'];
    if (data is! Map) return null;
    for (final String key in <String>['name', 'username', 'nickname', 'uid']) {
      final Object? v = data[key];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString();
    }
    return null;
  }

  /// 校验鲲登录 Cookie：真发一次搜索（`/api/search`）。
  ///
  /// 用搜索端点而不是 `/api/user/info`：整站 `/api/**` 共用一道门禁，
  /// 未登录的**任何**路径都是 205，而 `/api/user/info` 是否存在无法从
  /// 401 里分辨；搜索端点是我们自己抓取时必用的，通过即代表抓取能跑。
  static Future<CredentialCheck> verifyKunCookie(String cookie) async {
    final String trimmed = cookie.trim();
    if (trimmed.isEmpty) {
      return const CredentialCheck(ok: false, message: 'Cookie 为空');
    }
    final String? shapeError = validateCookieShape(trimmed);
    if (shapeError != null) {
      return CredentialCheck(ok: false, message: shapeError);
    }

    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: <String, String>{
        'User-Agent': 'ChronoTide/1.0 (Metadata Credential Check)',
        'Accept': 'application/json',
        'Cookie': trimmed,
      },
    ));
    NetworkProxyPolicy.instance.attachTo(dio);

    try {
      final Response<dynamic> res = await dio.get<dynamic>(
        'https://www.kungal.com/api/search',
        queryParameters: <String, dynamic>{
          'keywords': 'test',
          'type': 'galgame',
          'page': 1,
          'limit': 1,
        },
      );
      final KunProbeVerdict verdict = interpretKunProbe(
        statusCode: res.statusCode,
        body: res.data,
      );
      return _kunVerdictCheck(verdict, res.statusCode, res.data);
    } on DioException catch (e) {
      final int? code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        return const CredentialCheck(
          ok: false,
          message: 'Cookie 无效或已过期（站点要求重新登录）',
        );
      }
      return CredentialCheck(
        ok: false,
        message: '网络请求失败：${_briefError(e, 'www.kungal.com')}',
      );
    } catch (e) {
      return CredentialCheck(ok: false, message: '校验失败：$e');
    } finally {
      dio.close(force: true);
    }
  }

  static CredentialCheck _kunVerdictCheck(
      KunProbeVerdict verdict, int? statusCode, Object? body) {
    switch (verdict) {
      case KunProbeVerdict.ok:
        return CredentialCheck(
          ok: true,
          identity: kunIdentityOf(body),
          message: 'Cookie 有效，鲲论坛接口可用',
        );
      case KunProbeVerdict.loginRequired:
        return const CredentialCheck(
          ok: false,
          message: '站点回「用户登录失效」：请在浏览器登录 kungal.com 后重新复制 Cookie',
        );
      case KunProbeVerdict.rejected:
        final String msg =
            (body is Map ? (body['message'] ?? '') : '').toString();
        return CredentialCheck(
          ok: false,
          message: '站点拒绝：${msg.isEmpty ? '未知原因' : msg}',
        );
      case KunProbeVerdict.unknown:
        return CredentialCheck(
          ok: false,
          message: '无法判断（HTTP ${statusCode ?? '—'}），'
              '请先在浏览器确认已登录 kungal.com',
        );
    }
  }

  // ─────────────────────── 2DFan ───────────────────────

  /// 实测 2DFan Cookie 是否**真的认得出登录态**。
  ///
  /// ## 为什么必须校验（旧实现只保存不校验，用户被坑）
  ///
  /// 2DFan 的 Cookie 是**按域名**生效的：用户在 `2dfan.com` 登录、我们探到
  /// `2dfmax.top` ⇒ 会话不认，表现就是「明明填了 Cookie，补丁还是显示未登录」。
  /// 只回一句「已保存」会把这种错配原样埋掉，用户到兑换那一步才发现。
  ///
  /// [TwoDFanAccountService.check] 会在**实际要用的镜像**上读一次首页，
  /// 返回昵称与积分 ⇒ 直接把真伪摆上屏。
  ///
  /// 🔴 网络失败**不判死**：2DFan 是多镜像站，镜像抽风很常见，
  /// 那种情况不能报「Cookie 无效」（用户会白折腾一次重新登录）。
  static Future<CredentialCheck> verifyTwoDFanCookie(String cookie) async {
    final String trimmed = cookie.trim();
    if (trimmed.isEmpty) {
      return const CredentialCheck(ok: false, message: 'Cookie 为空');
    }
    final String? shapeError = validateCookieShape(trimmed);
    if (shapeError != null) {
      return CredentialCheck(ok: false, message: shapeError);
    }
    try {
      final FanAccountInfo info =
          await TwoDFanAccountService.instance.check(cookie: trimmed);
      if (info.loggedIn) {
        return CredentialCheck(ok: true, message: info.summary);
      }
      return const CredentialCheck(
        ok: false,
        message: 'Cookie 已保存，但站点仍视你为未登录：'
            '请确认登录的是同一个域名（2dfan.com / 2dfmax.top …），'
            '并复制**完整**的 Cookie 串',
      );
    } on TwoDFanSessionError catch (e) {
      return CredentialCheck(ok: true, message: '已保存；暂时无法联网校验（${e.message}）');
    } catch (e) {
      return CredentialCheck(ok: true, message: '已保存；暂时无法联网校验（$e）');
    }
  }

  // ─────────────────────── Hikarinagi ───────────────────────

  /// 实测 Hikarinagi 是否可用（内置 OAuth 客户端凭据）。
  ///
  /// 🔴 这个按钮是为了回答「这个站到底能不能用」：Hikarinagi 的开放接口
  /// 走 OAuth2 client_credentials，客户端凭据是**我们内置**的，用户不需要
  /// 登录；但国内直连常见 connection reset（本机实测如此），走代理即通。
  /// 所以这里分别报「令牌拿不到」「搜索失败」，让用户能分辨是凭据问题
  /// 还是网络问题。
  static Future<CredentialCheck> testHikarinagi() async {
    final Dio dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
    ));
    NetworkProxyPolicy.instance.attachTo(dio);

    String? token;
    try {
      final String basic = base64Encode(utf8.encode(
          '${HikarinagiService.kHikarinagiClientId}:${HikarinagiService.kHikarinagiClientSecret}'));
      final Response<dynamic> res = await dio.post<dynamic>(
        'https://id.hikarinagi.org/oidc/token',
        data: 'grant_type=client_credentials&scope=catalog:read',
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, dynamic>{'Authorization': 'Basic $basic'},
          responseType: ResponseType.plain,
        ),
      );
      final Object? body = res.data is String ? jsonDecode(res.data) : res.data;
      if (body is Map && body['access_token'] != null) {
        token = body['access_token'].toString();
      }
    } on DioException catch (e) {
      return CredentialCheck(
        ok: false,
        message: '取令牌失败：${_briefError(e, 'id.hikarinagi.org')}',
      );
    } catch (e) {
      return CredentialCheck(ok: false, message: '取令牌失败：$e');
    }

    if (token == null) {
      return const CredentialCheck(
        ok: false,
        message: '站点未返回 access_token（内置客户端凭据可能已失效）',
      );
    }

    try {
      final Response<dynamic> res = await dio.get<dynamic>(
        'https://www.hikarinagi.org/api/v3/open/search',
        queryParameters: <String, dynamic>{
          'q': 'test',
          'types': 'galgame',
          'page': 1,
          'page_size': 1,
        },
        options: Options(headers: <String, dynamic>{
          'Authorization': 'Bearer $token',
        }),
      );
      final Object? body = res.data is String ? jsonDecode(res.data) : res.data;
      final int count = _hikariItemCount(body);
      if (res.statusCode == 200) {
        return CredentialCheck(
          ok: true,
          message: '内置凭据可用（搜索返回 $count 条）',
        );
      }
      return CredentialCheck(ok: false, message: '搜索返回 ${res.statusCode}');
    } on DioException catch (e) {
      return CredentialCheck(
        ok: false,
        message: '搜索失败：${_briefError(e, 'www.hikarinagi.org')}',
      );
    } catch (e) {
      return CredentialCheck(ok: false, message: '搜索失败：$e');
    } finally {
      dio.close(force: true);
    }
  }

  static int _hikariItemCount(Object? body) {
    if (body is! Map) return 0;
    final Object? data = body['data'];
    if (data is! Map) return 0;
    final Object? items = data['items'];
    return items is List ? items.length : 0;
  }

  // ─────────────────────── 通用 ───────────────────────

  static String _briefError(DioException e, String host) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时（若开了代理，请到「网络与存储」确认代理生效）';
      case DioExceptionType.connectionError:
        return '无法连接 $host（可能需要代理）';
      case DioExceptionType.badResponse:
        return 'HTTP ${e.response?.statusCode}';
      case DioExceptionType.cancel:
        return '已取消';
      case DioExceptionType.badCertificate:
        return '证书校验失败';
      default:
        // 兜底：dio 后续版本新增的异常类型不该让整页崩掉
        return e.message ?? e.type.toString();
    }
  }

  /// 用户是否已配置鲲登录 Cookie。
  static Future<bool> hasKunCookie() async =>
      ((await KunCookieStore.load()) ?? '').isNotEmpty;

  /// 用户是否已配置 2DFan Cookie。
  static Future<bool> hasTwoDFanCookie() async =>
      ((await TwoDFanCookieStore.load()) ?? '').isNotEmpty;

  /// 浏览器 Cookie 的粗略形态检查（鲲 / 2DFan 共用）。
  ///
  /// 只判断「看起来像 Cookie」，不假装能验证登录态：Cookie 是否有效
  /// 只有真正请求站点才知道，而这两家都有多镜像域名，在形态检查里
  /// 做网络校验既慢又容易把「镜像抽风」误报成「Cookie 失效」。
  static String? validateCookieShape(String raw) {
    final String v = raw.trim();
    if (v.isEmpty) return 'Cookie 为空';
    if (v.contains('\n') || v.contains('\r')) {
      return 'Cookie 不能包含换行，请粘贴单行内容';
    }
    if (!v.contains('=')) return 'Cookie 格式不像（应形如 a=1; b=2）';
    if (v.length < 8) return 'Cookie 太短，可能粘贴不完整';
    return null;
  }

  /// 兼容旧名（2DFan 专用入口）。
  static String? validateTwoDFanCookieShape(String raw) =>
      validateCookieShape(raw);

  /// 凭证类型 → 一句人类可读的状态文案。
  static String describeCredential(
      MetadataCredentialKind kind, bool hasValue) {
    switch (kind) {
      case MetadataCredentialKind.builtIn:
        return '内置客户端凭据，无需填写';
      case MetadataCredentialKind.none:
        return '公开接口，无需凭证';
      case MetadataCredentialKind.personalToken:
        return hasValue ? '已填写个人令牌' : '未填写（匿名访问，限额较低）';
      case MetadataCredentialKind.cookie:
        return hasValue ? '已登录' : '未登录（部分内容读不到）';
    }
  }

  /// 当前进程是否运行在测试环境（探针里不发起真实网络请求）。
  static bool get isTestEnv => Platform.environment['FLUTTER_TEST'] == 'true';
}
