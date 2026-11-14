import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/path_helper.dart';
import '../utils/title_cleaner.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';
import 'network_proxy_policy.dart';

/// 标题图抓取结果状态。
enum GameTitleLogoStatus {
  /// 成功：已下载并落盘。
  ok,

  /// 本地已存在标题图（幂等命中，未发起网络请求）。
  alreadyExists,

  /// 目录搜索无结果 / 名称对不上（= 无法确定是哪部作品）。
  noMatch,

  /// 命中作品但没有任何 Steam 锚点（非 Steam 发行 / 目录未收录）。
  noSteamAnchor,

  /// 有 Steam 锚点但该 appid 没有 logo.png（或返回非 PNG / 尺寸不合格）。
  noLogo,

  /// 下载失败。
  downloadFailed,

  /// 网络 / 解析异常。
  networkError,
}

/// 标题图抓取结果（服务层不抛异常，失败一律以状态返回）。
@immutable
class GameTitleLogoResult {
  const GameTitleLogoResult({
    required this.status,
    this.fileName,
    this.steamAppId,
    this.matchedVia = '',
    this.message,
  });

  final GameTitleLogoStatus status;

  /// 落盘文件名（相对元数据目录，成功时非空）。
  final String? fileName;

  /// 命中的 Steam appid（便于排查 / 二次核对）。
  final String? steamAppId;

  /// 匹配依据：`anchor`（元数据源锚点精确对齐）/ `title`（标题归一化全等）。
  final String matchedVia;
  final String? message;

  bool get isOk =>
      status == GameTitleLogoStatus.ok ||
      status == GameTitleLogoStatus.alreadyExists;
}

/// 游戏标题图（透明 logo）抓取服务。
///
/// ## 为什么要这个服务
/// 主页 / BPM 主页的「大标题位」在截图里那种艺术字效果，靠的是**一张独立的
/// 透明标题图**（Playnite 的同款机制），而不是把游戏名渲染得更大。本服务负责
/// 把这张图搞到本地。
///
/// ## 来源（两级，前一级失手才走下一级）
/// 1. **Steam 官方 CDN**（质量最高：厂商原始素材）
///    `NextMoe 目录搜索 → sources[] 里的 steam:<appid> → Steam CDN logo.png`
///    实测（`.workbuddy/probe_game_logo/`，20 个 galgame 抽样）：
///    13/20 命中，全部 `image/png` + RGBA 透明通道。
/// 2. **SteamGridDB**（补前一级的缺口，需要用户自己的免费 API Key）
///    有 appid → `/games/steam/{appid}` 精确映射；无 appid → 按名称搜索，
///    同样只接受「归一化全等且唯一」。之后 `/logos/game/{gameId}` 取图，
///    在候选里优先 `official`，再按 `score` 排序，逐个校验直到有一张能用。
///    没有配置 Key 时这一级**静默跳过**，行为与只做 CDN 时完全一致。
///
/// 🔴 为什么 Key 是用户自己填：SteamGridDB 的 Key 是**个人凭据**，
/// 内置一份共用 Key 会违反其条款，也会让所有人共用同一个限流额度。
///
/// ## 🔴 核心纪律：宁可没有，也不能贴错
/// 贴错图（把 B 游戏的 logo 显示在 A 游戏上）比没有图难排查得多，而且用户
/// 一眼就会觉得"这软件乱了"。因此匹配只接受两种情况：
/// 1. **元数据源锚点精确对齐**（game.json 的 `metadata_source_id` 在搜索结果的
///    `sources[]` 里原样出现，如 `vndb:v12849`）；
/// 2. **标题归一化后完全相等且唯一命中**（`TitleCleaner.normalizeForCompare`）。
///
/// 多个候选同分 → 直接放弃。模糊相似度匹配**故意不做**。
///
/// ## 其它纪律
/// - 失败静默降级（返回状态、不抛异常），绝不阻塞入库 / 启动；
/// - 会话内去重 + 7 天负缓存（`data/title_logo_attempts.json`），
///   避免每次启动都去撞同一个必然失败的条目（如 `Fate/stay night`）；
/// - 只写元数据目录内的固定文件名 [GameDataFormat.titleLogoFileName]，
///   **不覆盖既有文件**（幂等命中直接返回）；
/// - 只读远端 + 只写自己的产物，不触碰任何游戏数据。
class GameTitleLogoService {
  GameTitleLogoService._();

  static final GameTitleLogoService instance = GameTitleLogoService._();

  static const String _ua = 'ChronoTide/1.0 (Metadata Scraper)';

  /// Steam 官方美术资源 CDN（`logo.png` = 透明标题图）。
  static const String _steamCdnBase =
      'https://cdn.akamai.steamstatic.com/steam/apps';

  /// SteamGridDB API v2（官方 OpenAPI 规格：`/static/openapi.yml`）。
  static const String _sgdbBase = 'https://www.steamgriddb.com/api/v2';

  /// 设置页读写的偏好键（SteamGridDB 个人 API Key）。
  ///
  /// 公开是为了让设置卡片与这里共用同一个键名常量，避免手抄字符串写错。
  static const String sgdbApiKeyPref = 'sgdb_api_key';

  /// 负缓存有效期：失败 7 天内不重试。
  static const Duration _retryAfter = Duration(days: 7);

  /// SGDB 候选最多试几张：避免某个条目下 50 张图全是方形/不透明的怪图时
  /// 把一轮抓取拖成几十次下载。
  static const int _sgdbMaxCandidates = 6;

  Dio? _dio;

  /// SteamGridDB 个人 Key（从 SharedPreferences 读一次后内存缓存）。
  String _sgdbKey = '';
  bool _sgdbKeyLoaded = false;

  /// 读用户配置的 SteamGridDB Key（设置卡片显示用；空串 = 未配置）。
  static Future<String> readSgdbApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(sgdbApiKeyPref) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<String> _ensureSgdbKey() async {
    if (_sgdbKeyLoaded) return _sgdbKey;
    _sgdbKey = await readSgdbApiKey();
    _sgdbKeyLoaded = true;
    return _sgdbKey;
  }

  /// 设置页保存 / 清除 Key 后调用。
  ///
  /// 🔴 必须**同时清掉负缓存**：负缓存的有效期是 7 天，用户刚填好 Key 却因为
  /// 之前（无 Key 时）的失败记录被挡 7 天，会以为「填了没用」。
  Future<void> onSgdbKeyChanged() async {
    _sgdbKeyLoaded = false;
    _sgdbKey = '';
    await clearNegativeCache();
  }

  /// 清空失败记录，让所有缺图游戏在下次被显示时重新尝试。
  Future<void> clearNegativeCache() async {
    _attemptedAt.clear();
    try {
      final file = File(_attemptFilePath);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ 负缓存清除失败（忽略）: $e');
    }
  }

  Future<Dio> _ensureDio() async {
    final existing = _dio;
    if (existing != null) return existing;

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Authorization': 'Bearer ${NextMoeService.apiKey}',
        'User-Agent': _ua,
      },
    ));

    // 全局统一代理策略（自动跟随系统代理 / 手动 / 直连）。
    NetworkProxyPolicy.instance.attachTo(dio);

    _dio = dio;
    return dio;
  }

  // ===========================================================================
  // 抓取主流程
  // ===========================================================================

  /// 抓取并落盘某游戏的标题图（**不写 game.json**，由调用方决定是否采纳）。
  ///
  /// [metaDataDir] 游戏元数据目录（game.json 所在处）；
  /// [title] 展示用主标题；[originalTitle] / [subtitle] 作为备用检索词；
  /// [metadataSource] + [metadataSourceId] 存在时优先用源锚点精确对齐
  /// （如 `vndb` + `v12849`）。
  Future<GameTitleLogoResult> fetchAndStore({
    required String metaDataDir,
    required String title,
    String? originalTitle,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) async {
    if (metaDataDir.isEmpty) {
      return const GameTitleLogoResult(
        status: GameTitleLogoStatus.noMatch,
        message: '元数据目录为空',
      );
    }

    final dir = Directory(metaDataDir);
    if (!await dir.exists()) {
      return const GameTitleLogoResult(
        status: GameTitleLogoStatus.noMatch,
        message: '元数据目录不存在',
      );
    }

    // 幂等：已有标题图直接复用（也避免覆盖用户手放的文件）
    final dest = File(
        '$metaDataDir${Platform.pathSeparator}${GameDataFormat.titleLogoFileName}');
    if (await dest.exists() && await dest.length() > 0) {
      return const GameTitleLogoResult(
        status: GameTitleLogoStatus.alreadyExists,
        fileName: GameDataFormat.titleLogoFileName,
      );
    }

    final Dio dio;
    try {
      dio = await _ensureDio();
    } catch (e) {
      return GameTitleLogoResult(
        status: GameTitleLogoStatus.networkError,
        message: '$e',
      );
    }

    // 检索词：主标题 → 原名 → 副标题拆出的每个别名（去重，空串剔除）
    //
    // 🔴 副标题是 `subtitle_composer` 产出的「除主标题外全部别名，` / ` 连接」，
    // 拼在一起永远等不上任何一个库里的单个片名。必须拆开单独检索 ——
    // 这对 SGDB 按名搜索尤其关键（它索引的是英文/日文原名，中文主标题搜不到）。
    final queries = _buildQueries(
      title: title,
      originalTitle: originalTitle,
      subtitle: subtitle,
    );
    if (queries.isEmpty) {
      return const GameTitleLogoResult(
        status: GameTitleLogoStatus.noMatch,
        message: '标题为空',
      );
    }

    // 1) 主线：找 Steam appid → 官方 CDN 取 logo.png
    final match = await _resolveSteamAppId(
      dio,
      queries: queries,
      title: title,
      subtitle: subtitle,
      metadataSource: metadataSource,
      metadataSourceId: metadataSourceId,
    );
    String? appId;
    var via = match?.via ?? '';
    Uint8List? png;

    // 🔴 必须**逐个候选 appid 试到成功**，不能只取第一个。
    //    NextMoe 一个作品常挂多个 steam 锚点（实测 AOKANA 3 个、Dies irae 4 个），
    //    其中第一个经常是 DLC/试玩版/旧包，CDN 上没有 logo.png。
    //    实测 20 个 galgame：只取首锚点 11/20，遍历全部 13/20
    //    （Making*Lovers 3143290→2093420、Dies irae 644540→1011990 就属于这种）。
    //    这是**零密钥**就能拿到的那部分覆盖率，不能浪费。
    if (match != null) {
      for (var i = 0; i < match.appIds.length; i++) {
        final id = match.appIds[i];
        final raw = await _downloadLogoPng(dio, id);
        if (raw == null) continue;
        final norm = await normalizeLogoPng(raw);
        if (norm == null) continue;
        png = norm;
        appId = id;
        if (i > 0) {
          debugPrint('[TITLE-LOGO] ↩️ 首锚点无图，改用第 ${i + 1} 个候选: $id');
        }
        break;
      }
      // 全部候选都没图时，仍留第一个给 SGDB 做精确映射
      appId ??= match.appIds.isNotEmpty ? match.appIds.first : null;
    }

    // 2) 补源：SteamGridDB（未配置 Key 时内部直接返回 null）
    if (png == null) {
      final sg = await _fetchFromSgdb(
        dio,
        steamAppId: appId,
        queries: queries,
        wantKey: TitleCleaner.normalizeForCompare(title),
      );
      if (sg != null) {
        png = sg.png;
        via = sg.via;
        appId ??= sg.appId;
      }
    }

    // 3) 两级都没拿到 → 按"卡在哪一步"返回可排查的状态
    if (png == null) {
      return GameTitleLogoResult(
        status: match == null
            ? GameTitleLogoStatus.noMatch
            : GameTitleLogoStatus.noLogo,
        steamAppId: appId,
        matchedVia: via,
        message: match == null ? '目录中未能确定唯一对应作品' : null,
      );
    }

    // 4) 落盘
    //
    // 🔴 图片之外还要写 `logo_file` / `logo_origin`：`findLogoFile` 虽然对固定名
    //    `title_logo.png` 有兜底探测，但显式记账才能回答"这张图是哪来的"
    //    （`steam` = 官方 CDN，`sgdb` = SteamGridDB 社区图）。排查时不用翻日志。
    //    写 json 失败**不阻断**：图已经落盘，固定名探测照样能显示它。
    final origin = via.startsWith('sgdb') ? 'sgdb' : 'steam';
    try {
      await dest.writeAsBytes(png, flush: true);
      try {
        await GameDataFormat.updateGameJson(metaDataDir, {
          'logo_file': GameDataFormat.titleLogoFileName,
          'logo_origin': origin,
        });
      } catch (_) {}
      debugPrint('[TITLE-LOGO] ✅ 已落盘: ${dest.path} '
          '(${png.length} B, appid=$appId, via=$via, origin=$origin)');
      return GameTitleLogoResult(
        status: GameTitleLogoStatus.ok,
        fileName: GameDataFormat.titleLogoFileName,
        steamAppId: appId,
        matchedVia: via,
      );
    } catch (e) {
      return GameTitleLogoResult(
        status: GameTitleLogoStatus.downloadFailed,
        steamAppId: appId,
        matchedVia: via,
        message: '$e',
      );
    }
  }

  /// 解析某游戏可能对应的 Steam appid 列表（**只查目录，不下载任何素材**）。
  ///
  /// 为什么公开：OP 视频抓取（`GameOpVideoService`）需要同一套锚点解析 ——
  /// 「源锚点精确对齐 / 标题归一化全等且唯一 / 多义直接放弃」这套纪律已经
  /// 在标题图上验证过两轮（覆盖率 13/20 → 16/20 全因 refs 深挖），
  /// 重新实现一遍只会引入第二套判定口径，迟早出现「标题图贴对了但 OP 抓错」。
  ///
  /// 返回空列表 = 目录里定位不到唯一作品（或该作品没有 steam 锚点）。
  /// 失败不抛异常（网络异常也返回空列表），调用方按「抓不到」处理即可。
  Future<List<String>> resolveSteamAppIds({
    required String title,
    String? originalTitle,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) async {
    final queries = _buildQueries(
      title: title,
      originalTitle: originalTitle,
      subtitle: subtitle,
    );
    if (queries.isEmpty) return const <String>[];
    try {
      final dio = await _ensureDio();
      final match = await _resolveSteamAppId(
        dio,
        queries: queries,
        title: title,
        subtitle: subtitle,
        metadataSource: metadataSource,
        metadataSourceId: metadataSourceId,
      );
      return match?.appIds ?? const <String>[];
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ appid 解析失败（$title）: $e');
      return const <String>[];
    }
  }

  /// 构造检索词：主标题 → 原名 → 副标题拆出的每个别名（去重、去空、上限 5）。
  ///
  /// 上限 5 是防别名很多的游戏把一轮抓取拖成十几次请求；
  /// 副标题必须**按 ` / ` 拆开**（见 `fetchAndStore` 里的长注释）。
  static List<String> _buildQueries({
    required String title,
    String? originalTitle,
    String? subtitle,
  }) {
    final queries = <String>[];
    void addQuery(String raw) {
      final s = raw.trim();
      if (s.isEmpty || queries.length >= 5) return;
      if (!queries.contains(s)) queries.add(s);
    }

    addQuery(title);
    addQuery(originalTitle ?? '');
    for (final part in (subtitle ?? '').split(' / ')) {
      addQuery(part);
    }
    return queries;
  }

  /// 验证一个 Key 是否可用（设置页「验证」按钮用）。
  ///
  /// 返回 null = 可用；否则返回可直接展示的中文错误文案。
  /// 用一个极轻的检索端点探活，不消耗真实的抓取流程。
  Future<String?> verifySgdbApiKey(String key) async {
    final k = key.trim();
    if (k.isEmpty) return 'Key 为空';
    try {
      final dio = await _ensureDio();
      final res = await dio.get<dynamic>(
        '$_sgdbBase/search/autocomplete/a',
        options: _sgdbOptions(k, lenient: true),
      );
      if (res.statusCode == 200) return null;
      if (res.statusCode == 401 || res.statusCode == 403) {
        return 'Key 无效或已被撤销，请重新生成';
      }
      if (res.statusCode == 429) return '请求过于频繁（限流），请稍后再试';
      return '验证失败（HTTP ${res.statusCode}）';
    } catch (e) {
      return '网络异常：$e';
    }
  }

  // ===========================================================================
  // 匹配
  // ===========================================================================

  Future<_SteamMatch?> _resolveSteamAppId(
    Dio dio, {
    required List<String> queries,
    required String title,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) async {
    if (queries.isEmpty) return null;

    /// 单个作品最多往外试几个候选 appid。实测 refs 合并后最多见到 6 个
    /// （AOKANA 的 refs 里还挂着各语言的 release），上限 6 是防极端条目
    /// 把一轮抓取拖成十几次请求。
    const maxAppIds = 6;

    final wantKey = TitleCleaner.normalizeForCompare(title);
    // 源锚点形态：`vndb:v12849` / `bangumi:554817` …
    final anchor = (metadataSource != null &&
            metadataSource.isNotEmpty &&
            metadataSourceId != null &&
            metadataSourceId.isNotEmpty)
        ? '${metadataSource.toLowerCase()}:${metadataSourceId.toLowerCase()}'
        : null;

    for (final q in queries) {
      List<Map<String, dynamic>> hits;
      try {
        hits = await _search(dio, q);
      } catch (e) {
        debugPrint('[TITLE-LOGO] ⚠️ 检索失败（$q）: $e');
        continue;
      }
      if (hits.isEmpty) continue;

      // ① 源锚点精确对齐：最可靠，接受
      if (anchor != null) {
        for (final h in hits) {
          final srcs = (h['sources'] as List? ?? const [])
              .map((s) => s.toString().toLowerCase())
              .toList();
          if (srcs.contains(anchor)) {
            final ids = await _steamAppIdsDeep(dio, h);
            if (ids.isNotEmpty) {
              return _SteamMatch(appIds: ids.take(maxAppIds).toList(), via: 'anchor');
            }
          }
        }
      }

      // ② 标题归一化全等，且**唯一**命中
      //
      // 🔴 判定必须用**当前检索词** `q` 的归一化，不能一直用主标题 wantKey。
      //    否则副标题拆出来的别名（英文名/日文名）虽然搜到了正确条目，
      //    判定环节却拿中文主标题去比，永远不相等 —— 那些别名等于白搜。
      //    主标题 wantKey 仍然保留，因为 q 可能来自别名而主标题本来就能对上。
      final qKey = TitleCleaner.normalizeForCompare(q);
      final exact = <Map<String, dynamic>>[];
      for (final h in hits) {
        if (_titleEquals(h, qKey) || _titleEquals(h, wantKey)) {
          exact.add(h);
        }
      }
      if (exact.length == 1) {
        final ids = await _steamAppIdsDeep(dio, exact.first);
        if (ids.isNotEmpty) {
          return _SteamMatch(appIds: ids.take(maxAppIds).toList(), via: 'title');
        }
      } else if (exact.length > 1) {
        // 多义：宁可放弃，也不猜（贴错图比没图难排查）
        debugPrint('[TITLE-LOGO] 🤔 多义命中（$q → ${exact.length} 个），放弃');
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _search(Dio dio, String q) async {
    final res = await executeRateLimited(
      SourceType.nextmoe,
      () => dio.get<dynamic>(
        '${NextMoeService.apiBase}/catalog/search',
        queryParameters: {'object': 'work', 'q': q, 'nsfw': 'true'},
      ),
    );
    final data = res.data is String ? jsonDecode(res.data as String) : res.data;
    final map = data is Map ? data : const {};
    final items = map['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  /// 搜索结果与目标标题是否**完全相等**（display_name / 各语言 localized）。
  bool _titleEquals(Map<String, dynamic> hit, String wantKey) {
    if (wantKey.isEmpty) return false;
    final candidates = <String>[];
    final display = hit['display_name']?.toString();
    if (display != null) candidates.add(display);
    final localized = hit['localized'];
    if (localized is Map) {
      for (final v in localized.values) {
        if (v is Map) {
          final value = v['value']?.toString();
          if (value != null) candidates.add(value);
        }
      }
    }
    for (final c in candidates) {
      if (TitleCleaner.normalizeForCompare(c) == wantKey) return true;
    }
    return false;
  }

  /// 一个作品在 NextMoe 里挂的**全部** steam 锚点，按原顺序去重。
  ///
  /// 不去重会重复试同一个 id（NextMoe 的 sources 里有重复项）；
  /// 只取第一个会白白丢掉覆盖率（见调用处注释）。
  List<String> _steamAppIds(Map<String, dynamic> hit) {
    final out = <String>[];
    for (final s in (hit['sources'] as List? ?? const [])) {
      final str = s.toString();
      if (!str.toLowerCase().startsWith('steam:')) continue;
      final id = str.substring('steam:'.length).trim();
      if (id.isNotEmpty && !out.contains(id)) out.add(id);
    }
    return out;
  }

  /// 比 [_steamAppIds] 完整：搜索结果的 `sources` 数组**不可靠**，
  /// 作品详情的 `refs` 才是完整的外部 id 映射。
  ///
  /// 🔴 实测（2026-10-17，7 个主线抓不到图的 galgame）：
  /// ```
  /// Clover Day's     sources=[]            → refs=[2430690]   有图
  /// Fate/stay night  sources=[]            → refs=[2396980]   有图
  /// Summer Pockets   sources=[3418570]     → refs 补 897220   有图
  /// ```
  /// 也就是说**光靠 refs 就多捞回 3 个**，覆盖率 13/20 → 16/20，
  /// 而且完全不需要任何 Key。多一次详情的代价完全值得。
  Future<List<String>> _steamAppIdsDeep(
      Dio dio, Map<String, dynamic> hit) async {
    final out = _steamAppIds(hit);
    final wid = hit['id'];
    if (wid == null) return out;
    try {
      final res = await executeRateLimited(
        SourceType.nextmoe,
        () => dio.get<dynamic>(
          '${NextMoeService.apiBase}/catalog/works/$wid',
          queryParameters: {'nsfw': 'true', 'include': 'refs'},
        ),
      );
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final map = data is Map ? data : const {};
      final refs = map['refs'];
      if (refs is List) {
        for (final r in refs) {
          if (r is! Map) continue;
          if (r['source']?.toString() != 'steam') continue;
          final id = r['external_id']?.toString().trim() ?? '';
          if (id.isNotEmpty && !out.contains(id)) out.add(id);
        }
      }
    } catch (e) {
      // refs 拿不到就退回 sources —— 不能因为一次详情失败让整轮抓取失败
      debugPrint('[TITLE-LOGO] ⚠️ 拉取 refs 失败（work=$wid），退回 sources: $e');
    }
    return out;
  }

  // ===========================================================================
  // SteamGridDB（第二源，需要用户自己的 Key）
  // ===========================================================================
  //
  // 端点全部来自官方 OpenAPI 规格（`https://www.steamgriddb.com/static/openapi.yml`，
  // v2.10.0，已实测确认鉴权头是 `Authorization: Bearer <key>`）：
  //   GET /games/steam/{appid}          → data.id
  //   GET /search/autocomplete/{term}   → data[]（id / name / release_date）
  //   GET /logos/game/{gameId}          → data[]（url / style / score / width / height）
  //
  // 🔴 只取 `mimes=image/png`：下游 `normalizeLogoPng` 只认 PNG 魔数，
  // 拿到 webp 会被判成坏图（SGDB 上 webp 的透明 logo 不少，但那需要额外解码分支）。

  /// 在 SteamGridDB 上找一张能用的标题图；**已规整**（裁好透明边）。
  ///
  /// 返回 null 的四种情况（一律静默，交给文字回退）：
  /// 未配置 Key / 检索不到唯一对应作品 / 该条目没有可用 logo / 网络异常。
  Future<_SgdbPng?> _fetchFromSgdb(
    Dio dio, {
    String? steamAppId,
    required List<String> queries,
    required String wantKey,
  }) async {
    final key = await _ensureSgdbKey();
    if (key.isEmpty) return null;

    // ① 有 appid：直接映射到 SGDB 条目（比按名字搜精确得多）
    int? gameId;
    var via = '';
    if (steamAppId != null && steamAppId.isNotEmpty) {
      final mapped = await _sgdbGameIdBySteam(dio, key, steamAppId);
      if (mapped != null) {
        gameId = mapped;
        via = 'sgdb-steam';
      }
    }

    // ② 没有 appid / 映射失败：按名字搜，只接受归一化全等且唯一
    if (gameId == null) {
      for (final q in queries) {
        final hits = await _sgdbSearch(dio, key, q);
        if (hits.isEmpty) continue;
        final exact = <int>[];
        for (final h in hits) {
          final name = h['name']?.toString() ?? '';
          final id = h['id'];
          if (id is! int) continue;
          if (wantKey.isNotEmpty &&
              TitleCleaner.normalizeForCompare(name) == wantKey) {
            exact.add(id);
          }
        }
        if (exact.length == 1) {
          gameId = exact.first;
          via = 'sgdb-title';
          break;
        }
        if (exact.length > 1) {
          // 同名多条目（本体 / 重制 / 合集）：宁可放弃，也不猜
          debugPrint('[TITLE-LOGO] 🤔 SGDB 同名多义（$q → ${exact.length} 个），放弃');
        }
      }
    }

    if (gameId == null) return null;

    // ③ 取候选并逐个校验
    final candidates = await _sgdbLogoCandidates(dio, key, gameId);
    var tried = 0;
    for (final url in candidates) {
      if (tried++ >= _sgdbMaxCandidates) break;
      final raw = await _downloadPngBytes(dio, url);
      if (raw == null) continue;
      final png = await normalizeLogoPng(raw);
      if (png == null) {
        debugPrint('[TITLE-LOGO] ⏭️ SGDB 候选不合格（方形/不透明/过小）: $url');
        continue;
      }
      debugPrint('[TITLE-LOGO] ✅ SGDB 命中: game=$gameId via=$via $url');
      return _SgdbPng(png: png, via: via, appId: steamAppId);
    }
    return null;
  }

  /// SGDB 请求选项：鉴权头走**请求级覆盖**（[Dio] 的 BaseOptions 上挂的是
  /// NextMoe 的 Bearer，同键会被这里替换掉，不会互相干扰）。
  Options _sgdbOptions(String key, {bool lenient = false}) => Options(
        headers: {'Authorization': 'Bearer $key'},
        // lenient：404（无此条目）/429（限流）都是正常结果，不当异常抛
        validateStatus: lenient ? (s) => s != null && s < 500 : null,
      );

  Future<int?> _sgdbGameIdBySteam(Dio dio, String key, String appId) async {
    try {
      final res = await dio.get<dynamic>(
        '$_sgdbBase/games/steam/$appId',
        options: _sgdbOptions(key, lenient: true),
      );
      if (res.statusCode != 200) return null;
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final map = data is Map ? data : const {};
      if (map['success'] != true) return null;
      final id = (map['data'] as Map?)?['id'];
      return id is int ? id : null;
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ SGDB 平台映射失败（$appId）: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _sgdbSearch(
      Dio dio, String key, String q) async {
    try {
      final res = await dio.get<dynamic>(
        '$_sgdbBase/search/autocomplete/${Uri.encodeComponent(q)}',
        options: _sgdbOptions(key, lenient: true),
      );
      if (res.statusCode != 200) return const [];
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final map = data is Map ? data : const {};
      final list = map['data'];
      if (list is! List) return const [];
      return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ SGDB 检索失败（$q）: $e');
      return const [];
    }
  }

  /// 按「官方优先 → 分数高优先」排好序的候选 URL 列表。
  Future<List<String>> _sgdbLogoCandidates(
      Dio dio, String key, int gameId) async {
    try {
      final res = await dio.get<dynamic>(
        '$_sgdbBase/logos/game/$gameId',
        queryParameters: {
          'mimes': 'image/png',
          'types': 'static',
          'nsfw': 'false',
          'humor': 'false',
          'limit': '50',
          'page': '0',
        },
        options: _sgdbOptions(key, lenient: true),
      );
      if (res.statusCode != 200) return const [];
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      final map = data is Map ? data : const {};
      final list = map['data'];
      if (list is! List) return const [];

      final items = <Map>[];
      for (final e in list) {
        if (e is! Map) continue;
        final url = e['url']?.toString() ?? '';
        if (url.isEmpty) continue;
        // API 里 width/height 可能缺省；缺省就不参与比例预筛，交给 normalize
        final w = (e['width'] as num?)?.toDouble() ?? 0;
        final h = (e['height'] as num?)?.toDouble() ?? 0;
        if (w > 0 && h > 0 && w < h * 1.2) continue; // 竖版/方版不可能是标题图
        items.add(e);
      }

      int styleRank(Object? s) {
        switch (s?.toString()) {
          case 'official':
            return 0;
          case 'white':
            return 1;
          case 'black':
            return 2;
          case 'custom':
            return 3;
          default:
            return 4;
        }
      }

      items.sort((a, b) {
        final r = styleRank(a['style']).compareTo(styleRank(b['style']));
        if (r != 0) return r;
        final sa = (a['score'] as num?)?.toDouble() ?? 0;
        final sb = (b['score'] as num?)?.toDouble() ?? 0;
        return sb.compareTo(sa);
      });

      return items.map((e) => e['url'].toString()).toList();
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ SGDB 取 logo 列表失败（$gameId）: $e');
      return const [];
    }
  }

  /// 下载任意 URL 的 PNG 字节（校验魔数）。SGDB 的图在 `cdn2.steamgriddb.com`。
  Future<Uint8List?> _downloadPngBytes(Dio dio, String url) async {
    try {
      final res = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data == null || data.length < 33) return null;
      final bytes = Uint8List.fromList(data);
      if (bytes[0] != 0x89 ||
          bytes[1] != 0x50 ||
          bytes[2] != 0x4E ||
          bytes[3] != 0x47) {
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ SGDB 图片下载失败（$url）: $e');
      return null;
    }
  }

  // ===========================================================================
  // 下载 + 规整
  // ===========================================================================

  Future<Uint8List?> _downloadLogoPng(Dio dio, String appId) async {
    final url = '$_steamCdnBase/$appId/logo.png';
    try {
      final res = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          // 404 = 该作品没有标题图，属于正常结果，不当异常
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data == null || data.isEmpty) return null;
      final bytes = Uint8List.fromList(data);
      // PNG 魔数（Steam 也有 appid 指向 .jpg 的情况，这里只认 PNG）
      if (bytes.length < 33 ||
          bytes[0] != 0x89 ||
          bytes[1] != 0x50 ||
          bytes[2] != 0x4E ||
          bytes[3] != 0x47) {
        return null;
      }
      return bytes;
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ 下载失败（$url）: $e');
      return null;
    }
  }

  /// 规整标题图：校验尺寸/比例 → 裁掉透明边 → 重新编码为 PNG。
  ///
  /// 返回 null = 这张图不适合当标题图（尺寸过小 / 竖版 / 全透明）；
  /// 解码或重编码失败时**降级返回原字节**（得到一张带白边的图，比没有强）。
  ///
  /// 🔴 为什么要裁透明边：Steam 的 `logo.png` 画布尺寸并不统一
  /// （实测 AOKANA 640×167 内容占 99%×98%；ATRI 640×360 内容只占 95%×78%），
  /// 直接按 `BoxFit.contain` 铺进标题位会让不同游戏的 logo 视觉大小差 20%+。
  ///
  /// 这两道闸（宽扁比例 / 非全幅不透明）是**自动链路的唯一质量保证**：
  /// 只有全自动抓取，没有人工复核，所以宁可判掉也不能贴上去一张错图。
  @visibleForTesting
  Future<Uint8List?> normalizeLogoPng(Uint8List bytes) async {
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
      final w = image.width;
      final h = image.height;

      // 尺寸下限：太小的图放大到标题位一定糊
      if (w < 96 || h < 24) return null;
      // 标题图天然是宽扁的；竖版/方版基本都是别的东西（截图、图标、封面）
      if (w < h * 1.2) return null;
      // 像素总量保护（防止异常大图把扫描拖死）
      if (w * h > 6000000) return bytes;

      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return bytes;
      final rgba = byteData.buffer.asUint8List();

      // 扫 alpha bbox（alpha 在每个像素的第 4 字节）
      var minX = w, minY = h, maxX = -1, maxY = -1;
      for (var y = 0; y < h; y++) {
        final rowBase = y * w * 4;
        for (var x = 0; x < w; x++) {
          if (rgba[rowBase + x * 4 + 3] > 12) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }

      if (maxX < 0) {
        // 全透明 = 没有内容
        return null;
      }

      final cw = maxX - minX + 1;
      final ch = maxY - minY + 1;

      // 全幅不透明 = 大概率是一张普通插画/截图，不是透明标题图
      final coverage = (cw * ch) / (w * h);
      if (coverage > 0.995) return null;

      // 已经是满幅内容：不必重编码（省一次 PNG 编码）
      if (cw == w && ch == h) return bytes;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(
            minX.toDouble(), minY.toDouble(), cw.toDouble(), ch.toDouble()),
        ui.Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final cropped = await recorder.endRecording().toImage(cw, ch);
      final png = await cropped.toByteData(format: ui.ImageByteFormat.png);
      cropped.dispose();
      if (png == null) return bytes;
      return png.buffer.asUint8List();
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ 规整失败，降级用原图: $e');
      return bytes;
    } finally {
      image?.dispose();
    }
  }

  // ===========================================================================
  // 自动补抓（懒触发 + 会话去重 + 7 天负缓存）
  // ===========================================================================

  final Set<String> _autoInFlight = {};
  final Map<String, int> _attemptedAt = {};
  bool _attemptCacheLoaded = false;
  Future<void> _attemptSaveQueue = Future<void>.value();
  Future<void> _autoQueue = Future<void>.value();

  static String get _attemptFilePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}title_logo_attempts.json';

  /// 后台补抓某游戏的标题图（幂等、可重复触发）。
  ///
  /// 调用点：大标题位渲染时发现「无标题图」→ 触发一次。只有用户真正看到的
  /// 游戏才会去抓，成本最低；成功后更新注册表内存对象并通知 UI 重建。
  void requestAutoFetch({
    required String gameId,
    required String metaDataDir,
    required String title,
    String? originalTitle,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) {
    if (gameId.isEmpty || metaDataDir.isEmpty) return;
    if (_autoInFlight.contains(gameId)) return;

    _autoInFlight.add(gameId);
    // 串行队列：避免快速翻页时并发打满限流
    _autoQueue = _autoQueue.then((_) async {
      try {
        await _loadAttemptCache();
        final now = DateTime.now().millisecondsSinceEpoch;
        final last = _attemptedAt[gameId];
        if (last != null && now - last < _retryAfter.inMilliseconds) {
          return; // 负缓存期内不重试
        }

        final result = await fetchAndStore(
          metaDataDir: metaDataDir,
          title: title,
          originalTitle: originalTitle,
          subtitle: subtitle,
          metadataSource: metadataSource,
          metadataSourceId: metadataSourceId,
        );

        if (result.isOk) {
          _attemptedAt.remove(gameId);
          _applyToRegistry(gameId, metaDataDir);
        } else {
          _attemptedAt[gameId] = now;
        }
        _scheduleAttemptFlush();
      } catch (e) {
        debugPrint('[TITLE-LOGO] ⚠️ 自动补抓异常（忽略）: $e');
      } finally {
        _autoInFlight.remove(gameId);
      }
    });
  }

  /// 抓取成功后，把结果同步进注册表内存对象并通知刷新。
  void _applyToRegistry(String gameId, String metaDataDir) {
    try {
      final file = File(
          '$metaDataDir${Platform.pathSeparator}${GameDataFormat.titleLogoFileName}');
      if (!file.existsSync()) return;
      final registry = LocalGameRegistry.instance;
      final game = registry.getGameById(gameId);
      if (game != null) {
        game.logoPath = file.path;
      }
      registry.notifyDataChanged();
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ 注册表同步失败（忽略）: $e');
    }
  }

  Future<void> _loadAttemptCache() async {
    if (_attemptCacheLoaded) return;
    _attemptCacheLoaded = true;
    try {
      final file = File(_attemptFilePath);
      if (!await file.exists()) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      data.forEach((k, v) {
        final ts = v is int ? v : int.tryParse('$v');
        if (k.isNotEmpty && ts != null) _attemptedAt[k] = ts;
      });
    } catch (e) {
      debugPrint('[TITLE-LOGO] ⚠️ 负缓存读取失败（忽略）: $e');
    }
  }

  void _scheduleAttemptFlush() {
    final previous = _attemptSaveQueue;
    _attemptSaveQueue = () async {
      await previous;
      try {
        final file = File(_attemptFilePath);
        final dir = file.parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        await file.writeAsString(jsonEncode(_attemptedAt), flush: true);
      } catch (e) {
        debugPrint('[TITLE-LOGO] ⚠️ 负缓存写入失败（忽略）: $e');
      }
    }();
  }

  /// 测试专用：清空 Dio 与内部状态。
  @visibleForTesting
  void resetForTest() {
    _dio = null;
    _sgdbKey = '';
    _sgdbKeyLoaded = false;
    _autoInFlight.clear();
    _attemptedAt.clear();
    _attemptCacheLoaded = false;
    _autoQueue = Future<void>.value();
  }
}

class _SteamMatch {
  const _SteamMatch({required this.appIds, required this.via});

  /// 该作品的全部候选 Steam appid（**按 NextMoe 给的顺序**，已去重）。
  /// 调用方必须逐个试 —— 首个常常是 DLC/试玩版，CDN 上没有 logo.png。
  final List<String> appIds;
  final String via;
}

/// SGDB 命中结果：[png] 已规整（裁掉透明边），调用方直接落盘即可。
class _SgdbPng {
  const _SgdbPng({required this.png, required this.via, this.appId});
  final Uint8List png;
  final String via;
  final String? appId;
}
