import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'kungal_link_service.dart';

/// KUNGAL 站内「攻略」页外跳服务（2026-11-11，库页详情窗口 v3）。
///
/// 站长开放的攻略 API 是 NextMoe 目录 v2 的
/// `GET /v2/catalog/walkthroughs?work_id={id}&limit=1`，返回该作品攻略列表；
/// 攻略网页模板（2026-11-11 curl 实测 `198/3970`、`231772/737` 均 200）：
/// `https://www.kungal.com/galgame/{work_id}/walkthrough/{walkthrough_id}`。
/// ⚠️ `/galgame/{id}/walkthrough`（不带攻略 id）与 `/walkthrough` 都是 **404**，
/// 所以必须先拿到攻略 id 才能直达，不能只拼作品 id。
///
/// 🔴 `KungalLinkService` 解析出的 KUNGAL 站内 id 可直接当 `work_id` 用：
/// 抽查 `/v2/catalog/works` 多个作品，`work.id == claim.site_work_id` 恒成立。
///
/// 设计约束（与 KungalLinkService 对齐）：
/// - **会话缓存含负结果**：同一会话内「无攻略」不重复打网络；
/// - 🔴 **不落盘**：攻略会新增，磁盘缓存会把「暂无攻略」锁死成脏数据；
/// - **并发合并**：在飞请求共享同一个 Future，不丢弃重复调用的结果；
/// - **失败静默 null**：网络异常时按钮维持置灰，绝不弹错、绝不写数据。
class KungalWalkthroughService {
  KungalWalkthroughService._();

  static final KungalWalkthroughService _instance =
      KungalWalkthroughService._();
  static KungalWalkthroughService get instance => _instance;

  /// 仅供测试：独立实例（干净缓存），配合 [debugResolver] 零网络。
  @visibleForTesting
  KungalWalkthroughService.forTest();

  static const String _apiBase = 'https://api.nextmoe.dev/v2';

  /// 攻略网页直链；任一 id 无效时返回空串（UI 应置灰，不打开空链接）。
  static String pageUrlOf(int workId, int walkthroughId) =>
      workId > 0 && walkthroughId > 0
          ? '${KungalLinkService.host}/galgame/$workId/walkthrough/'
              '$walkthroughId'
          : '';

  /// workId → 第一篇攻略 id（null = 已查过但暂无攻略 / 请求失败）
  final Map<int, int?> _cache = {};

  /// 在飞解析：存 Future 而不是 Set，重复调用共享结果（见 KungalLinkService）
  final Map<int, Future<int?>> _inFlight = {};

  /// 仅供测试：替换真实网络请求（null = 用真实实现）。
  @visibleForTesting
  static Future<int?> Function(int workId)? debugResolver;

  @visibleForTesting
  void clearCache() {
    _cache.clear();
    _inFlight.clear();
  }

  /// 解析该作品第一篇攻略 id；无攻略 / 失败返回 null。
  Future<int?> resolveWalkthroughId(int workId) async {
    if (workId <= 0) return null;
    if (_cache.containsKey(workId)) return _cache[workId];
    final running = _inFlight[workId];
    if (running != null) return running;
    final future = _doResolve(workId);
    _inFlight[workId] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(workId);
    }
  }

  Future<int?> _doResolve(int workId) async {
    try {
      final fake = debugResolver;
      final id = fake != null ? await fake(workId) : await _fetch(workId);
      // 负结果也记入会话缓存，避免「无攻略」作品反复进详情反复打请求。
      _cache[workId] = id;
      return id;
    } catch (e) {
      debugPrint('[KungalWalkthrough] 解析失败 [$workId]: $e');
      return null;
    }
  }

  Future<int?> _fetch(int workId) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Authorization': 'Bearer ${NextMoeService.apiKey}',
        'User-Agent': 'ChronoTide/1.0 (KungalWalkthrough)',
        'Accept': 'application/json',
      },
    ));
    try {
      final resp = await dio.get(
        '$_apiBase/catalog/walkthroughs',
        queryParameters: {
          'work_id': workId.toString(),
          'limit': 1,
        },
      );
      if (resp.statusCode != 200) return null;
      final data = resp.data is String
          ? jsonDecode(resp.data as String)
          : resp.data;
      if (data is! Map) return null;
      return parseFirstId(Map<String, dynamic>.from(data));
    } catch (e) {
      debugPrint('[KungalWalkthrough] 请求失败 [$workId]: $e');
      return null;
    } finally {
      dio.close();
    }
  }

  /// 从列表响应里取第一篇攻略 id（纯函数，供行为探针零网络验证）。
  @visibleForTesting
  static int? parseFirstId(Map<String, dynamic> payload) {
    final items = payload['items'];
    if (items is! List || items.isEmpty) return null;
    final first = items.first;
    if (first is! Map) return null;
    final id = int.tryParse(first['id']?.toString() ?? '');
    return (id != null && id > 0) ? id : null;
  }
}
