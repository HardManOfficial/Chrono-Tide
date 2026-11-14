import 'dart:async';

import 'package:dio/dio.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../models/patch_resource.dart';
import '../patch_source.dart';
import 'moyu_query_params.dart';
import 'moyu_resource_parser.dart';

/// 鲲（NextMoe v2 + moyu 资源页）补丁源。
///
/// ## 为什么是一个源而不是两个
///
/// `api.nextmoe.dev/v2/moyu/*` 是鲲的**官方 API 上游**，`www.moyu.moe` 是它的
/// 前端页面 —— 同一条供应链的两个入口。合并成一个源后不会出现
/// "同一补丁两条记录"，省掉去重键。分工：
/// - **列表 / 元数据**走 v2：字段全（`hash`/`note`/`type`/`language`/`size`）
/// - **直链**走资源页 HTML：v2 的 `/resources/{id}/file` 要 `moyu:files` scope，
///   我们只有 `catalog:read`，实测 403
///
/// ## 检索路径（唯一）
///
/// ```
/// catalog work id
///   → GET /v2/moyu/patches?refs=catalog:<id>      拿 patch 列表
///   → GET /v2/moyu/patches/<patchId>/resources    拿资源列表（每个 patch 一次）
///   → GET https://www.moyu.moe/resource/<id>      解析直链 / 网盘（并发受限）
/// ```
///
/// 🔴 **鲲不支持"按补丁名全站搜索"**：v2 的 `catalog/search` 只认
/// `work/character/credit_name/company/tag/series/engine/trait`，没有 `patch`
/// （实测 `object=patch` 报错）。所以本源的 [PatchSourceCapabilities.byKeyword]
/// 是 **false** —— 想搜补丁名只能靠 2DFan，或先解析到作品再查。
///
/// ## 降级
///
/// - 没有 workId：直接返回失败（聚合层会去问 2DFan）
/// - patches 为空：返回空结果（**不是失败** —— 该作品确实没补丁）
/// - 直链解析失败：该条保持 [PatchDelivery.web]，用户可跳原站
/// - 整源网络失败：返回 [PatchSourceResult.failed]
class MoyuPatchSource implements PatchSource {
  static const String apiBase = 'https://api.nextmoe.dev/v2';
  static const String webBase = 'https://www.moyu.moe';

  /// 单次拉取的资源上限。一个作品的补丁资源实测 4~10 条，100 足够且不触发翻页
  static const int _pageLimit = 100;

  /// 并发抓资源列表（每 patch 一次请求）—— 别打太狠，NextMoe 免费档 60 次/分
  static const int _resourceConcurrency = 3;

  /// 并发抓资源页 HTML 解析直链
  static const int _directConcurrency = 4;

  /// 单条直链解析超时。超时就让该条退化成「打开资源页」，不拖垮整轮
  static const Duration _directTimeout = Duration(seconds: 10);

  final Dio _dio;

  /// 直链解析结果缓存（进程内，key = resource id）。
  /// ⚠️ 直链会过期，所以只在本次会话内复用，不做长磁盘缓存。
  final Map<String, PatchDeliveryInfo> _directCache =
      <String, PatchDeliveryInfo>{};

  MoyuPatchSource({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                // 复用 SDK 里的应用密钥，⛔ 不要在本文件再抄一份常量
                'Authorization': 'Bearer ${NextMoeService.apiKey}',
                'Accept': 'application/json',
                // 🔴 网关会拒 urllib / Dart 默认 UA（实测 403），必须自带 UA
                'User-Agent': 'ChronoTide/1.0 (Patch Station)',
              },
            )) {
    applyProxyConfig(null, _dio);
  }

  @override
  PatchSite get site => PatchSite.kunlun;

  @override
  PatchSourceCapabilities get capabilities => const PatchSourceCapabilities(
        byWorkId: true,
        byKeyword: false,
        byGameId: false,
        directDownload: true,
      );

  /// 不主动关 Dio：实例可能由调用方注入并复用，关掉会连带影响其他源
  @override
  void dispose() {}

  @override
  Future<PatchSourceResult> search(PatchQueryContext ctx) async {
    final workId = ctx.workId;
    if (workId == null) {
      return const PatchSourceResult.failed('未识别到作品，无法在鲲检索');
    }

    try {
      final patches = await _fetchPatches(workId, nsfw: ctx.nsfw);
      if (patches.isEmpty) {
        // 作品存在但确实没有补丁 —— 是「没找到」，不是「失败」
        return const PatchSourceResult.empty();
      }

      // 每个 patch 拉一次资源列表（并发受限）
      final perPatch = await _mapLimited<Map<String, dynamic>, List<_RawResource>>(
        patches,
        _resourceConcurrency,
        (patch) async {
          final patchId = _asString(patch['id']);
          if (patchId.isEmpty) return const <_RawResource>[];
          final resources = await _fetchResources(patchId);
          return resources
              .map((r) => _RawResource(
                    json: r,
                    patchId: patchId,
                    patchTypes: _asStringList(patch['type']),
                  ))
              .toList();
        },
      );

      final raws = perPatch.expand((e) => e).toList();
      if (raws.isEmpty) return const PatchSourceResult.empty();

      // 先全部按 web 态构造（可立即出列表），再异步补直链
      var list = raws.map((r) => _toResource(r, ctx)).toList();

      final resolved = await _mapLimited<PatchResource, PatchResource>(
        list,
        _directConcurrency,
        (res) async => _enrichDelivery(res),
      );

      list = resolved;
      return PatchSourceResult(resources: list);
    } on DioException catch (e) {
      return PatchSourceResult.failed(_humanizeDioError(e));
    } catch (e) {
      return PatchSourceResult.failed('鲲检索异常：$e');
    }
  }

  // ---------------- 网络 ----------------

  /// 拉某作品的补丁列表。
  ///
  /// 🔴 [nsfw] 必须传：不传的话服务端按默认 SFW 过滤，`content_limit=nsfw`
  /// 的条目会被静默丢进 `missing`，R18 作品直接表现为「一个补丁都没有」。
  /// 实测缘之空（catalog:51）不带 nsfw 返回 `items:[]`，
  /// 带 `nsfw=true` 才返回 1 个 patch / 11 条资源。
  Future<List<Map<String, dynamic>>> _fetchPatches(
    int workId, {
    required bool nsfw,
  }) async {
    final resp = await executeRateLimited<dynamic>(
      SourceType.nextmoe,
      () => _dio.get<dynamic>(
        '$apiBase/moyu/patches',
        queryParameters: buildMoyuPatchesQuery(
          workId: workId,
          nsfw: nsfw,
          limit: _pageLimit,
        ),
      ),
    );
    return _itemsOf(resp.data);
  }

  Future<List<Map<String, dynamic>>> _fetchResources(String patchId) async {
    final resp = await executeRateLimited<dynamic>(
      SourceType.nextmoe,
      () => _dio.get<dynamic>(
        '$apiBase/moyu/patches/$patchId/resources',
        queryParameters: buildMoyuResourcesQuery(limit: _pageLimit),
      ),
    );
    return _itemsOf(resp.data);
  }

  /// 抓资源页 HTML 并解析投递形态。失败 / 超时一律降级为 web（不算错误）。
  Future<PatchResource> _enrichDelivery(PatchResource res) async {
    final cached = _directCache[res.id];
    if (cached != null) return _applyDelivery(res, cached);

    try {
      final resp = await _dio
          .get<String>(
            '$webBase/resource/${res.id}',
            options: Options(
              responseType: ResponseType.plain,
              headers: {
                // 资源页是给浏览器看的，UA 别用 API 那套
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml',
              },
            ),
          )
          .timeout(_directTimeout);

      final html = resp.data ?? '';
      final info = MoyuResourceParser.resolveDelivery(html);
      _directCache[res.id] = info;
      return _applyDelivery(res, info);
    } catch (_) {
      // 网络/超时/解析任何问题 → 保持 web 态，用户仍能跳原站
      return res;
    }
  }

  // ---------------- 组装 ----------------

  PatchResource _toResource(_RawResource raw, PatchQueryContext ctx) {
    return MoyuV2Mapper.toResource(
      raw.json,
      patchId: raw.patchId,
      gameTitle:
          ctx.titles.isNotEmpty ? ctx.titles.first : ctx.effectiveKeyword,
      patchTypes: raw.patchTypes,
    );
  }

  PatchResource _applyDelivery(PatchResource res, PatchDeliveryInfo info) {
    // 无论主形态是哪一种，页面上识别到的**全部**入口都要挂上：
    // 详情展开时会逐条列出（多网盘 / 直链+网盘并存），
    // ⛔ 只留第一个等于把用户赶回原页。
    final withLinks =
        info.links.isEmpty ? res : res.copyWith(links: info.links);

    switch (info.delivery) {
      case PatchDelivery.direct:
        if ((info.directUrl ?? '').isEmpty) return withLinks;
        return withLinks.copyWith(
          delivery: PatchDelivery.direct,
          directUrl: info.directUrl,
        );
      case PatchDelivery.netdisk:
        if ((info.netdiskUrl ?? '').isEmpty) return withLinks;
        return withLinks.copyWith(
          delivery: PatchDelivery.netdisk,
          netdiskUrl: info.netdiskUrl,
          extractCode: info.extractCode ?? res.extractCode,
        );
      case PatchDelivery.web:
        return withLinks;
    }
  }
}

// ==================== 内部工具 ====================

class _RawResource {
  final Map<String, dynamic> json;
  final String patchId;

  /// patch 级 type（资源自身 type 为空时用它兜底）
  final List<String> patchTypes;

  const _RawResource({
    required this.json,
    required this.patchId,
    this.patchTypes = const <String>[],
  });
}

/// v2 响应是 `{"object":"list","items":[...],"next_cursor":...}`（无信封）
List<Map<String, dynamic>> _itemsOf(dynamic data) => MoyuV2Mapper.itemsOf(data);

String _asString(dynamic v) => v == null ? '' : v.toString();

List<String> _asStringList(dynamic v) {
  if (v is! List) return const <String>[];
  return v
      .map((e) => _asString(e).trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

String _humanizeDioError(DioException e) {
  final code = e.response?.statusCode;
  if (code == 401 || code == 403) return '密钥无效或无权限';
  if (code == 404) return '接口不存在';
  if (code == 429) return '请求过于频繁';
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      return '网络超时';
    case DioExceptionType.connectionError:
      return '网络不可达';
    default:
      return '网络错误${code == null ? '' : '（$code）'}';
  }
}

/// 并发受限的 map（保持输入顺序）。
///
/// 自己写而不用集合扩展：项目里没有并发池依赖，也不想为此加包
/// （AGENTS.md：⛔ 不新增 pubspec 依赖）。
Future<List<R>> _mapLimited<T, R>(
  List<T> input,
  int concurrency,
  Future<R> Function(T item) task,
) async {
  if (input.isEmpty) return <R>[];
  final results = List<R?>.filled(input.length, null, growable: false);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next;
      if (index >= input.length) return;
      next++;
      results[index] = await task(input[index]);
    }
  }

  final workers = <Future<void>>[
    for (var i = 0; i < concurrency.clamp(1, input.length); i++) worker(),
  ];
  await Future.wait(workers);
  return results.cast<R>().toList(growable: false);
}
