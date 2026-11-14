import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/game.dart' show SourceType;
import '../models/letmoe_resource.dart';
import 'metadata_base.dart';
import 'nextmoe_service.dart';

/// letmoe 下载资源链接面服务（SITE-LIBRARY「获取 / 分享」的数据源）。
///
/// ## 端点（base `https://api.nextmoe.dev/v2/letmoe`，文档见
/// developer.nextmoe.dev/docs/letmoe，2026-11-13 全部 curl 实测通过）
///
/// - `GET /works/{id}/resources?nsfw=true` → 资源列表
/// - `GET /resources/{id}/file` → 一条资源的下载方式（直链/网盘/提取码/解压密码）
/// - `GET /works?ids=` → 批量问哪些作品有资源
///
/// ## 身份体系
///
/// 作品 id == catalog 作品 id == 全站搜索鲲命中的 `SiteSearchHit.siteId`。
/// 2DFan 命中的 subject id **不属于**该体系，须先经
/// [NextMoeService.resolveWorkIdByTitle] 反查。
///
/// ## 🔴 缓存策略（官方契约，不能省）
///
/// - 资源**列表**：进程内 TTL 缓存（面板反复开关不重复打接口）；
/// - `/file`：**⛔ 绝不缓存** —— 官方明确「答案一律 no-store，每次成功都给
///   资源记一次下载，在读者点下载时再调，不要预取」。
///
/// ## nsfw 契约
///
/// 列表端点缺省 `nsfw=false`（成人作品直接消失）⇒ 必须显式 `nsfw=true`。
class LetmoeResourceService {
  static final LetmoeResourceService _instance =
      LetmoeResourceService._internal();

  factory LetmoeResourceService() => _instance;

  static const String apiBase = '${NextMoeService.apiBase}/letmoe';

  late final Dio _dio;

  LetmoeResourceService._internal() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        // 复用 SDK 应用密钥（letmoe:files scope 密钥创建时自动带上）。
        // ⛔ 不要在本文件再抄一份常量。
        'Authorization': 'Bearer ${NextMoeService.apiKey}',
        'Accept': 'application/json',
        // 网关拒默认 UA（moyu 源同款教训），必须自带
        'User-Agent': 'ChronoTide/1.0 (Site Library Resources)',
      },
    ));
    applyProxyConfig(null, _dio);
  }

  /// GET + 连接级重试（与 [NextMoeService._getWithConnectRetry] 同因同款：
  /// api.nextmoe.dev 的一个 Cloudflare 边缘 IP 黑洞 TCP 连接，连接层失败
  /// 重试换边；HTTP 层错误原样抛出，不掩盖服务端问题）。
  Future<Response<T>> _getWithConnectRetry<T>(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    const attempts = 3;
    DioException? last;
    for (var i = 1; i <= attempts; i++) {
      try {
        return await executeRateLimited<T>(SourceType.nextmoe,
            () => _dio.get<T>(path, queryParameters: query));
      } on DioException catch (e) {
        final t = e.type;
        if (t != DioExceptionType.connectionTimeout &&
            t != DioExceptionType.connectionError) {
          rethrow;
        }
        last = e;
        fetchLog('[Letmoe] 连接失败（第 $i/$attempts 次）[$path]，重试');
        if (i < attempts) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    throw last!;
  }

  /// 资源列表缓存（key = workId）。TTL 与补丁检索同量级。
  static const Duration _listCacheTtl = Duration(minutes: 10);
  final Map<String, _CachedList> _listCache = <String, _CachedList>{};

  /// 一部作品的资源列表。404 / 空都返回空数组（= 该作品没有资源，不是错误）。
  Future<List<LetmoeResource>> listWorkResources(
    String workId, {
    bool nsfw = true,
    bool forceRefresh = false,
  }) async {
    final id = workId.trim();
    if (id.isEmpty || int.tryParse(id) == null) return const <LetmoeResource>[];

    final cached = _listCache[id];
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.at) <= _listCacheTtl) {
      return cached.resources;
    }

    try {
      final response = await _getWithConnectRetry<dynamic>(
        '$apiBase/works/$id/resources',
        {'nsfw': nsfw ? 'true' : 'false'},
      );
      // 404 = 该作品在 letmoe 无资源（官方语义），不是错误
      if (response.statusCode != 200) {
        fetchLog('[Letmoe] 资源列表返回 ${response.statusCode} [work=$id]');
        return const <LetmoeResource>[];
      }
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (data is! Map) return const <LetmoeResource>[];
      final itemsRaw = data['items'];
      if (itemsRaw is! List) return const <LetmoeResource>[];

      final out = <LetmoeResource>[];
      for (final item in itemsRaw) {
        if (item is! Map) continue;
        out.add(LetmoeResource.fromJson(Map<String, dynamic>.from(item)));
      }
      _listCache[id] = _CachedList(
        resources: out,
        at: DateTime.now(),
      );
      fetchLog('[Letmoe] 资源列表 ${out.length} 条 [work=$id]');
      return out;
    } catch (e) {
      fetchLog('[Letmoe] 资源列表失败 [work=$id]: $e');
      return const <LetmoeResource>[];
    }
  }

  /// 一条资源的下载方式。**不缓存**（官方 no-store + 下载计数语义）。
  ///
  /// 🔴 [nsfw] **必须传 true**（默认即 true）：`/file` 与列表端点共用 nsfw
  /// 可见性口径，不带参数时成人作品的资源直接 404 `no visible resource with
  /// id`——2026-11-14 实测，是「一大批资源恒显示解析失败」的真因。
  ///
  /// 404 / 失败返回空 [LetmoeResourceFiles]（上层显示「暂无下载方式」）。
  Future<LetmoeResourceFiles> getResourceFile(
    String resourceId, {
    bool nsfw = true,
  }) async {
    final id = resourceId.trim();
    if (id.isEmpty || int.tryParse(id) == null) {
      return LetmoeResourceFiles(resourceId: id);
    }
    try {
      final response = await _getWithConnectRetry<dynamic>(
        '$apiBase/resources/$id/file',
        {'nsfw': nsfw ? 'true' : 'false'},
      );
      if (response.statusCode != 200) {
        fetchLog('[Letmoe] /file 返回 ${response.statusCode} [resource=$id]');
        return LetmoeResourceFiles(resourceId: id);
      }
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (data is! Map) return LetmoeResourceFiles(resourceId: id);
      return LetmoeResourceFiles.fromJson(Map<String, dynamic>.from(data));
    } catch (e) {
      fetchLog('[Letmoe] /file 失败 [resource=$id]: $e');
      return LetmoeResourceFiles(resourceId: id);
    }
  }

  /// 批量问哪些作品有资源（`/works?ids=`，一次最多 100 个）。
  ///
  /// 返回按传入顺序排列的摘要；无资源的 id 不在结果里（missing 语义）。
  Future<List<LetmoeWorkSummary>> workSummaries(List<String> workIds) async {
    final ids = workIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && int.tryParse(e) != null)
        .take(100)
        .toList();
    if (ids.isEmpty) return const <LetmoeWorkSummary>[];
    try {
      final response = await _getWithConnectRetry<dynamic>(
        '$apiBase/works',
        {
          'ids': ids.join(','),
          'nsfw': 'true',
        },
      );
      if (response.statusCode != 200) {
        fetchLog('[Letmoe] works 批量返回 ${response.statusCode}');
        return const <LetmoeWorkSummary>[];
      }
      final data = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (data is! Map) return const <LetmoeWorkSummary>[];
      final itemsRaw = data['items'];
      if (itemsRaw is! List) return const <LetmoeWorkSummary>[];

      final byId = <String, LetmoeWorkSummary>{};
      for (final item in itemsRaw) {
        if (item is! Map) continue;
        final s = LetmoeWorkSummary.tryFromJson(Map<String, dynamic>.from(item));
        if (s != null) byId[s.id] = s;
      }
      // 官方契约：返回顺序 ≠ 传入顺序，按传入 id 重排
      return [
        for (final id in ids)
          if (byId.containsKey(id)) byId[id]!,
      ];
    } catch (e) {
      fetchLog('[Letmoe] works 批量失败: $e');
      return const <LetmoeWorkSummary>[];
    }
  }

  /// 清空列表缓存（探针 / 强刷用）。
  void clearCache() => _listCache.clear();
}

class _CachedList {
  final List<LetmoeResource> resources;
  final DateTime at;
  const _CachedList({required this.resources, required this.at});
}
