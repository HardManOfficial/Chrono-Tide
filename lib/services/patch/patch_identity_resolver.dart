import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';
import 'patch_identity_matcher.dart';

/// 游戏 → NextMoe `catalog` work id 的解析器（带缓存 / 并发合并 / 磁盘快照）。
///
/// ## 为什么需要它
///
/// 探索库 `GameModel` **没有任何外部 id 字段**（只有 `id/title/originalTitle/
/// englishTitle/tags/...`）。而鲲的补丁必须靠 `refs=catalog:<workId>` 锚定，
/// 所以"标题 → work id"这一步躲不掉。
///
/// ## 为什么不复用 `KungalLinkService`
///
/// 它解析的是 **KUNGAL 站内 claim id**（用来拼 `kungal.com` 详情页链接），
/// 走的是"搜索 + 逐条取 claim 块"的路径，产出类型也不同。硬塞进来会污染它
/// 的语义（而且它是稳定区，AGENTS.md 要求非必要不动）。这里只**借鉴**它的
/// 三个好设计：
/// 1. 磁盘快照 30 天 TTL
/// 2. `_inFlight` 存 **Future** 而不是 Set（并发调用共享结果，而不是第二个调用
///    直接拿到 null —— 那是它记录过的历史缺陷）
/// 3. 多候选标题依次尝试
///
/// ## 精度诚实声明
///
/// [PatchWorkMatch.confidence] < 0.8 时，调用方**应当**在 UI 上显示
/// "匹配到：XXX"，让用户能看出串味。⛔ 不要假装 100% 准。
class PatchIdentityResolver {
  static final PatchIdentityResolver _instance =
      PatchIdentityResolver._internal();

  factory PatchIdentityResolver() => _instance;

  PatchIdentityResolver._internal();

  static const String apiBase = 'https://api.nextmoe.dev/v2';

  /// 与 `KungalLinkService._diskTtl` 对齐（30 天）
  static const Duration kDiskTtl = Duration(days: 30);

  static const String _fileName = 'patch_identity.json';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      // 复用 SDK 的应用密钥，⛔ 不在这里抄第二份
      'Authorization': 'Bearer ${NextMoeService.apiKey}',
      'Accept': 'application/json',
      // 🔴 网关拒默认 UA（实测 403）
      'User-Agent': 'ChronoTide/1.0 (Patch Station)',
    },
  ));

  /// gameId → 解析结果（含"确认没有"的负结果，用 [PatchWorkMatch.none] 表示）
  final Map<String, _Entry> _cache = <String, _Entry>{};

  /// 🔴 在飞请求存 **Future**：并发重复调用共享同一个结果。
  /// 若存 Set 并直接 return null，第二个调用者会拿到假空值。
  final Map<String, Future<PatchWorkMatch>> _inFlight =
      <String, Future<PatchWorkMatch>>{};

  String? _cacheFilePath;
  bool _diskLoaded = false;

  /// 仅供测试：替换网络查询（null = 用真实实现）。
  /// 与 `KungalLinkService.debugResolver` 同款思路 —— 单例 + 真实网络
  /// 没法在测试里注入，只能开一个静态钩子。
  static Future<List<Map<String, dynamic>>> Function(String keyword)?
      debugSearchOverride;

  /// 同步取已解析结果（详情页首帧用，零网络）。
  ///
  /// 首次调用会同步把磁盘快照读进内存（文件只有几 KB）。
  PatchWorkMatch? lookup(String gameId) {
    if (gameId.trim().isEmpty) return null;
    _ensureDiskLoadedSync();
    final e = _cache[gameId];
    if (e == null) return null;
    if (DateTime.now().difference(e.resolvedAt) > kDiskTtl) return null;
    return e.match;
  }

  /// 该 gameId 是否已有结论（含"解析过但没找到"）
  bool hasConclusion(String gameId) {
    _ensureDiskLoadedSync();
    return _cache.containsKey(gameId);
  }

  /// 解析（带缓存 / 并发合并）。
  Future<PatchWorkMatch> resolve({
    required String gameId,
    required List<String> candidateTitles,
    bool nsfw = true,
    bool forceRefresh = false,
  }) async {
    if (gameId.trim().isEmpty) return PatchWorkMatch.none;

    if (!forceRefresh) {
      final cached = lookup(gameId);
      if (cached != null) return cached;
      if (hasConclusion(gameId)) {
        // 命中了负缓存（解析过，确认没有）
        final e = _cache[gameId];
        if (e != null &&
            DateTime.now().difference(e.resolvedAt) <= kDiskTtl) {
          return e.match;
        }
      }
      final running = _inFlight[gameId];
      if (running != null) return running;
    }

    final future = _doResolve(
      gameId: gameId,
      candidateTitles: candidateTitles,
      nsfw: nsfw,
    );
    _inFlight[gameId] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(gameId);
    }
  }

  Future<PatchWorkMatch> _doResolve({
    required String gameId,
    required List<String> candidateTitles,
    required bool nsfw,
  }) async {
    final candidates = _dedupeTitles(candidateTitles);
    PatchWorkMatch best = PatchWorkMatch.none;

    for (final title in candidates) {
      try {
        final items = await _searchWorks(title, nsfw: nsfw);
        if (items.isEmpty) continue;
        final match = pickWorkMatch(items, <String>[title]);
        if (match.found) {
          best = match;
          // 精确命中就不再试下一个别名（省一次请求）
          if (match.isConfident) break;
        }
      } catch (_) {
        // 单个别名失败不致命：换下一个别名再试（学习 KungalLinkService）
        continue;
      }
    }

    _cache[gameId] = _Entry(match: best, resolvedAt: DateTime.now());
    unawaited(_saveDisk());
    return best;
  }

  Future<List<Map<String, dynamic>>> _searchWorks(
    String keyword, {
    required bool nsfw,
  }) async {
    final override = debugSearchOverride;
    if (override != null) return override(keyword);

    final resp = await executeRateLimited<dynamic>(
      SourceType.nextmoe,
      () => _dio.get<dynamic>(
        '$apiBase/catalog/search',
        queryParameters: {
          'object': 'work',
          'q': keyword,
          'nsfw': nsfw ? 'true' : 'false',
        },
      ),
    );
    final data = resp.data;
    if (data is! Map) return const <Map<String, dynamic>>[];
    final items = data['items'];
    if (items is! List) return const <Map<String, dynamic>>[];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  // ---------------- 磁盘 ----------------

  String _path() {
    _cacheFilePath ??= p.join(PathHelper.dataDir, 'cache', _fileName);
    return _cacheFilePath!;
  }

  /// 同步读盘（首帧可用）。任何异常都静默 —— 缓存坏了不能挡功能
  void _ensureDiskLoadedSync() {
    if (_diskLoaded) return;
    _diskLoaded = true;
    try {
      final f = File(_path());
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return;
      final now = DateTime.now();
      for (final entry in raw.entries) {
        final v = entry.value;
        if (v is! Map) continue;
        final at = DateTime.tryParse(v['at']?.toString() ?? '');
        if (at == null) continue;
        if (now.difference(at) > kDiskTtl) continue;
        final workIdRaw = v['workId'];
        final workId = workIdRaw is int
            ? workIdRaw
            : int.tryParse(workIdRaw?.toString() ?? '');
        _cache[entry.key.toString()] = _Entry(
          match: PatchWorkMatch(
            workId: workId,
            matchedTitle: v['matchedTitle']?.toString() ?? '',
            confidence: (v['confidence'] as num?)?.toDouble() ?? 0,
          ),
          resolvedAt: at,
        );
      }
    } catch (_) {
      // 忽略：缓存不可用就等于首次运行
    }
  }

  Future<void> _saveDisk() async {
    try {
      final f = File(_path());
      final dir = f.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final out = <String, dynamic>{};
      for (final e in _cache.entries) {
        out[e.key] = <String, dynamic>{
          'workId': e.value.match.workId,
          'matchedTitle': e.value.match.matchedTitle,
          'confidence': e.value.match.confidence,
          'at': e.value.resolvedAt.toIso8601String(),
        };
      }
      // 先写 tmp 再 rename：避免写一半被杀进程留下坏 JSON
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(out), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // 落盘失败不影响本次解析
    }
  }

  // ---------------- 工具 ----------------

  static List<String> _dedupeTitles(List<String> raw) {
    final out = <String>[];
    for (final t in raw) {
      final s = t.trim();
      if (s.isEmpty) continue;
      if (out.contains(s)) continue;
      out.add(s);
    }
    return out;
  }
}

class _Entry {
  final PatchWorkMatch match;
  final DateTime resolvedAt;

  const _Entry({required this.match, required this.resolvedAt});
}
