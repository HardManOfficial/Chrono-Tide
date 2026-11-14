import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../core/path_helper.dart';

/// 详情页「KUNGAL 站内详情」一键外跳服务。
///
/// 需求：探索详情页数据再全，也不如 KUNGAL 站点收集得齐；给详情页一个**轻量**
/// 入口，一键打开该作品在 KUNGAL 的站内页（`https://www.kungal.com/galgame/{id}`），
/// 交互形态对齐「发售日历点条目直接跳对应网页」。
///
/// 🔴 为什么必须做「标题 → id」解析
/// KUNGAL 自身 REST（`/api/search`、`/api/galgame/search`）2026-10-24 实测已
/// **全部登录墙**（`{"code":205,"message":"用户登录失效"}`），匿名拿不到 id；
/// 但 NextMoe 开放 API v2 的 work 对象自带 KUNGAL 认领信息：
/// ```json
/// "claim": {"site": "kungal", "site_work_id": "373", "state": "live"}
/// ```
/// 故改用 NextMoe 目录（与发售月历同一数据源、同一把密钥）做匹配。
///
/// 解析链：
/// 1. **会话缓存**（gameId → 结果，含「查无」负缓存）——详情页反复进出不重复请求
/// 2. **磁盘缓存**（`data/cache/kungal_link.json`，30 天）——冷启动直接命中
/// 3. NextMoe 搜索（多别名：中文名 / 日文原名 / 英文名 / 繁中名）→ 逐条取
///    `claim.site_work_id`。中文名首条取不到 id 时（中文名命中「无 KUNGAL 页」
///    的作品）继续用日文原名再搜一轮，提高命中率。
///
/// 站内 ID 一旦解析成功即**长期有效**，故命中后不再重新校验（避免每次开详情
/// 都打一次网络）。
///
/// ⚠️ 本服务只负责「拿到 id」。入口是否出现由 UI 决定：已解析出 id → 显示；
/// 尚不确定 → **隐藏**（会静默解析一次，成功后入口自然出现）。
class KungalLinkService {
  KungalLinkService._() : _useDisk = true;

  static final KungalLinkService _instance = KungalLinkService._();
  static KungalLinkService get instance => _instance;

  /// 仅供测试：不落盘、不读盘
  @visibleForTesting
  KungalLinkService.forTest() : _useDisk = false;

  static const String host = 'https://www.kungal.com';

  /// 站内作品详情页（id 无效时为空串，UI 不应展示外跳）
  static String detailUrlOf(int id) =>
      id > 0 ? '$host/galgame/$id' : '';

  /// 站内搜索页（解析不出 id 时的兜底落点，保证按钮永远「点了有反馈」）
  static String searchUrlOf(String keyword) {
    final kw = keyword.trim();
    if (kw.isEmpty) return '$host/galgame';
    return '$host/search?keywords=${Uri.encodeQueryComponent(kw)}&type=galgame';
  }

  static const String _nmApiBase = 'https://api.nextmoe.dev/v2';
  static const Duration _diskTtl = Duration(days: 30);

  final bool _useDisk;

  /// gameId → KUNGAL 站内 id（null = 已解析但确认 KUNGAL 无此作品）
  final Map<String, int?> _cache = {};

  /// 在飞解析：**存 Future 而不是 Set**。
  ///
  /// 🔴 历史缺陷：原实现 `if (_inFlight.contains(id)) return null;` —— 并发
  /// 重复调用会直接拿到 null 且不等待，等于把别人的解析结果丢掉。用户「退出
  /// 详情页再进来才出现按钮」的体感就是这么来的（第一次解析在飞、第二次被
  /// 判空丢弃，直到第一次后台跑完写入缓存）。改成共享同一个 Future。
  final Map<String, Future<int?>> _inFlight = {};

  bool _diskLoaded = false;
  String? _cacheFilePath;

  /// 预解析队列（探索库列表加载后预热，见 [prefetch]）
  final List<_PrefetchJob> _prefetchQueue = [];
  int _prefetchActive = 0;

  /// 预解析并发上限：解析单条 = 1 次搜索 + 并行 claim，2 路并发足以在
  /// 十几秒内热完首屏 30 条，又不会把开放 API 打出限流。
  static const int _prefetchConcurrency = 2;

  // ---------------- 对外接口 ----------------

  /// 同步取已解析出的 id（详情页首帧 build 用，零网络、零异步 IO）。
  ///
  /// 首次调用会**同步**把磁盘缓存读进内存（文件只有几 KB，毫秒级），
  /// 因此冷启动后第一次进详情页也能首帧命中，不必等一个异步 IO 往返。
  int? lookup(String gameId) {
    _ensureDisk();
    return _cache[gameId];
  }

  /// 该 gameId 是否已经有结论（含「确认 KUNGAL 无此作品」）。
  ///
  /// 与 [lookup] 的区别：`lookup` 返回 null 可能是「没查过」，也可能
  /// 「查过但没有」；本方法用来区分，避免入口重复打网络。
  bool hasResolved(String gameId) {
    _ensureDisk();
    return _cache.containsKey(gameId);
  }

  /// 解析 KUNGAL 站内 id（带缓存 / 并发合并）。
  ///
  /// [candidateTitles] 按优先级传入（主标题、日文原名、英文名…），
  /// 内部会去空白、去重。返回 null 表示：未找到，或暂时无法判定。
  Future<int?> resolve(String gameId, List<String> candidateTitles) async {
    if (gameId.isEmpty) return null;
    _ensureDisk();
    if (_cache.containsKey(gameId)) return _cache[gameId];

    // 已经在解析：共享同一个 Future，等它出结果（绝不再返回 null 丢弃）
    final running = _inFlight[gameId];
    if (running != null) return running;

    final titles = _normalizeCandidates(candidateTitles);
    if (titles.isEmpty) return null;

    final future = _doResolve(gameId, titles);
    _inFlight[gameId] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(gameId);
    }
  }

  Future<int?> _doResolve(String gameId, List<String> titles) async {
    try {
      final fake = debugResolver;
      final id = fake != null ? await fake(titles) : await _searchKungalId(titles);
      // 负结果也记入会话缓存：入口常驻后，避免每次开详情都重打一遍网络。
      // （磁盘仍只落正结果，30 天后会重新尝试，给「KUNGAL 后补收录」留机会）
      _cache[gameId] = id;
      if (id != null) await _saveDisk();
      return id;
    } catch (e) {
      debugPrint('[KungalLink] 解析失败 [$gameId]: $e');
      return null;
    }
  }

  /// 批量预解析（探索库列表加载后调用）。
  ///
  /// 目的：把「点进详情才开始解析」改成「列表一出来就后台热好」，
  /// 用户点卡片时大概率 [lookup] 直接命中 ⇒ 入口首帧就在、点击直达作品页。
  /// 已解析 / 在飞 / 已排队的自动跳过，重复调用安全。
  void prefetch(List<({String id, List<String> titles})> items) {
    _ensureDisk();
    var queued = false;
    for (final it in items) {
      if (it.id.isEmpty) continue;
      if (_cache.containsKey(it.id)) continue;
      if (_inFlight.containsKey(it.id)) continue;
      if (_prefetchQueue.any((q) => q.id == it.id)) continue;
      _prefetchQueue.add(_PrefetchJob(it.id, it.titles));
      queued = true;
    }
    if (queued) _pumpPrefetch();
  }

  void _pumpPrefetch() {
    while (_prefetchActive < _prefetchConcurrency && _prefetchQueue.isNotEmpty) {
      final job = _prefetchQueue.removeAt(0);
      if (_cache.containsKey(job.id) || _inFlight.containsKey(job.id)) continue;
      _prefetchActive++;
      resolve(job.id, job.titles).whenComplete(() {
        _prefetchActive--;
        _pumpPrefetch();
      });
    }
  }

  /// 仅供测试：注入结果后走真实落盘（零网络）
  @visibleForTesting
  void seed(String gameId, int? id) => _cache[gameId] = id;

  /// 仅供测试：替换真实网络解析（null = 用真实实现）。
  ///
  /// 存在的理由只有一个：验证「并发调用共享同一 Future」这个修复本身
  /// （见 [_inFlight] 的注释），否则必须打真实网络才能覆盖。
  @visibleForTesting
  static Future<int?> Function(List<String> titles)? debugResolver;

  /// 仅解析结果（不读写缓存），便于单测纯函数行为
  @visibleForTesting
  static String? claimIdOf(Map<String, dynamic> work) {
    final claim = work['claim'];
    if (claim is! Map) return null;
    final site = claim['site']?.toString() ?? '';
    if (site != 'kungal') return null;
    final raw = claim['site_work_id']?.toString() ?? '';
    final parsed = int.tryParse(raw);
    // ⚠️ '0' / 负数 / 非数字都算无效（KUNGAL 站内 id 从 1 起）
    if (raw.isEmpty || parsed == null || parsed <= 0) return null;
    return raw;
  }

  // ---------------- 内部实现 ----------------

  static List<String> _normalizeCandidates(List<String> raw) {
    final out = <String>[];
    for (final t in raw) {
      final v = t.trim();
      if (v.isEmpty) continue;
      if (out.contains(v)) continue;
      out.add(v);
    }
    return out;
  }

  /// 用候选标题逐个搜索，取第一条带 KUNGAL 认领 id 的命中。
  ///
  /// 命中率优化的关键：中文名有命中但该作品无 KUNGAL 页时，不要就此放弃，
  /// 换下一个别名（通常是日文原名，KUNGAL 一定会有）再搜。
  ///
  /// ⚡ 性能关键：搜索返回的候选条目**并行**取 claim（原实现串行，最坏
  /// 3×1.2s=3.6s），谁先命中用谁。实测单次请求约 1.1~1.2s，故理想路径
  /// 从「搜索 + 串行 3 条详情」≈ 4.7s 压到「搜索 + 1 条详情」≈ 2.3s。
  Future<int?> _searchKungalId(List<String> titles) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Authorization': 'Bearer ${NextMoeService.apiKey}',
        'User-Agent': 'ChronoTide/1.0 (KungalLink)',
        'Accept': 'application/json',
      },
    ));

    try {
      // 最多试 3 个别名，避免一次详情页打开打出多次请求
      for (final keyword in titles.take(3)) {
        final items = await _searchWorks(dio, keyword);
        if (items == null || items.isEmpty) continue;

        // 少数情况下搜索响应自带 claim，能省掉详情请求
        for (final item in items.whereType<Map>()) {
          final direct = claimIdOf(Map<String, dynamic>.from(item));
          final parsed = int.tryParse(direct ?? '');
          if (parsed != null && parsed > 0) return parsed;
        }

        final workIds = items
            .whereType<Map>()
            .take(3)
            .map((e) => e['id']?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
        if (workIds.isEmpty) continue;

        final hit = await _raceClaimId(dio, workIds);
        if (hit != null) return hit;
      }
      return null;
    } finally {
      dio.close();
    }
  }

  Future<List?> _searchWorks(Dio dio, String keyword) async {
    try {
      final resp = await dio.get(
        '$_nmApiBase/catalog/search',
        queryParameters: {
          'object': 'work',
          'q': keyword,
          'nsfw': 'true',
        },
      );
      if (resp.statusCode != 200) return null;
      final data = resp.data is String
          ? jsonDecode(resp.data as String)
          : resp.data;
      if (data is! Map) return null;
      final items = data['items'];
      return items is List ? items : null;
    } catch (e) {
      debugPrint('[KungalLink] 搜索失败 ["$keyword"]: $e');
      return null;
    }
  }

  /// 并行取多个候选作品的 claim，第一个命中即返回（其余请求自然作废）
  Future<int?> _raceClaimId(Dio dio, List<String> workIds) {
    final completer = Completer<int?>();
    var pending = workIds.length;

    void settle() {
      pending--;
      if (pending <= 0 && !completer.isCompleted) completer.complete(null);
    }

    for (final workId in workIds) {
      _fetchClaimId(dio, workId).then((raw) {
        final parsed = int.tryParse(raw ?? '');
        if (parsed != null && parsed > 0 && !completer.isCompleted) {
          completer.complete(parsed);
        }
      }).whenComplete(settle);
    }
    return completer.future;
  }

  /// 取作品详情，仅要 `claim` 块（include 点名瘦身，仍含 claim）
  Future<String?> _fetchClaimId(Dio dio, String workId) async {
    try {
      final resp = await dio.get(
        '$_nmApiBase/catalog/works/$workId',
        queryParameters: {'nsfw': 'true', 'include': 'titles'},
      );
      if (resp.statusCode != 200) return null;
      final data = resp.data is String
          ? jsonDecode(resp.data as String)
          : resp.data;
      if (data is! Map) return null;
      return claimIdOf(Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }

  /// 同步加载磁盘缓存（首次调用时执行一次，之后零开销）。
  ///
  /// 🔴 必须同步：入口要求「首帧就出现」，若这里还是异步 IO，详情页
  /// `initState` 里 `lookup()` 必然拿到 null ⇒ 冷启动第一次进详情照样
  /// 看不到按钮。缓存文件只有几 KB，同步读在毫秒级，可接受。
  void _ensureDisk() {
    if (_diskLoaded) return;
    _diskLoaded = true;
    if (!_useDisk) return;
    try {
      final dirPath = p.join(PathHelper.dataDir, 'cache');
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _cacheFilePath = p.join(dirPath, 'kungal_link.json');
      final file = File(_cacheFilePath!);
      if (!file.existsSync()) return;
      final content = file.readAsStringSync();
      final data = jsonDecode(content);
      if (data is! Map) return;
      final cachedAtStr = data['_cached_at']?.toString();
      if (cachedAtStr == null) return;
      final cachedAt = DateTime.tryParse(cachedAtStr);
      if (cachedAt == null ||
          DateTime.now().difference(cachedAt) > _diskTtl) {
        return;
      }
      final entries = data['entries'];
      if (entries is Map) {
        entries.forEach((k, v) {
          final parsed = int.tryParse(v?.toString() ?? '');
          if (k is String && parsed != null) {
            // 0 是「确认无 KUNGAL 页」的落盘编码，还原成 null
            _cache[k] = parsed > 0 ? parsed : null;
          }
        });
      }
      debugPrint('[KungalLink] 📦 已加载磁盘缓存: ${_cache.length} 条');
    } catch (e) {
      debugPrint('[KungalLink] ⚠️ 读取磁盘缓存失败: $e');
    }
  }

  Future<void> _saveDisk() async {
    if (!_useDisk || _cacheFilePath == null) return;
    try {
      final payload = {
        '_cached_at': DateTime.now().toIso8601String(),
        // 🔴 只落**正结果**：负结果（确认无 KUNGAL 页）只留在会话内，
        // 否则会被写成 0 并锁 30 天，KUNGAL 后补收录的作品就再也升级不上来。
        'entries': {
          for (final e in _cache.entries)
            if (e.value != null && e.value! > 0) e.key: e.value!,
        },
      };
      final tmp = File('$_cacheFilePath.tmp');
      await tmp.writeAsString(jsonEncode(payload));
      await tmp.rename(_cacheFilePath!);
    } catch (e) {
      debugPrint('[KungalLink] ⚠️ 写入磁盘缓存失败: $e');
    }
  }
}

/// 预解析队列任务（gameId + 候选标题快照）
class _PrefetchJob {
  _PrefetchJob(this.id, this.titles);

  final String id;
  final List<String> titles;
}
