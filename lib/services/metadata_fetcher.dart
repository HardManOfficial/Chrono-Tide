import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import '../core/path_helper.dart';
import 'metadata_field_priority.dart';
import 'metadata_login_service.dart';
import 'network_proxy_core.dart';
import 'network_proxy_policy.dart';
import 'oauth/oauth_providers.dart';

/// 元数据抓取统一调度器
///
/// 职责：
/// 1. 并发查询多个数据源（Future.wait，4源并行将最坏耗时从200秒降至~15秒）
/// 2. 磁盘持久化缓存（24h TTL，应用重启不丢失）
/// 3. 数据源可配置（用户可在设置页勾选启用源）
/// 4. 字段格式转换（_convertToLegacyFormat，保留 rating/tags权重 等元数据）
class MetadataFetcher {
  static Dio? _dio;

  // 服务实例缓存（P0.3）
  // 避免每次 _createService 创建新实例，导致服务内的 Token 缓存
  // （如 YmgalService._cachedToken）随实例销毁而失效。
  // 代理变更时通过 _clearServiceCache 清空重建。
  static final Map<SourceType, MetadataSourceService> _serviceCache = {};

  // 内存缓存（热数据，启动时从磁盘加载）
  static final Map<String, Map<String, dynamic>> _cache = {};
  static const Duration _cacheTtl = Duration(hours: 24);

  // 磁盘缓存文件路径（延迟初始化）
  static String? _cacheFilePath;
  static bool _cacheLoaded = false;

  /// 磁盘缓存版本：数据源解析逻辑变更时递增，旧缓存整体自动失效
  ///
  /// v3：MIX 与独立平台数据共存（此前 MIX 启用时会抑制底层平台条目）
  /// v4：接入 NextMoe（六源对齐目录）为 MIX 全字段第一优先级
  /// v5：接入 CT 探索库（MIX 第二优先级 + 独立条目）
  /// v6：CT 名称索引修复（分词多查询召回 + 精度闸）与「副标题 = 全部别名」
  ///     （新增 alias_names 透传）——旧缓存不含新字段/旧召回结果，整体失效
  /// v7：移除 DLsite/ErogameScape/TouchGal，接入 2Dfan（新增源 + MIX 插入位
  ///     + 字段链改动）——旧缓存含已下线平台的条目，整体失效
  /// v8：2Dfan 污染主域被锁定的半通死链修复（METADATA-FAN-DOMAIN-HEAL）。
  ///     当时 2Dfan 逐个超时返回空，但**其余源的结果非空 ⇒ 聚合结果照样入缓存**，
  ///     于是缓存里全是"不含 2Dfan 条目"的记录，TTL 24h 内重搜会命中旧缓存、
  ///     根本不会重新请求 2Dfan ⇒ 修好后仍然"搜不到"。故整体失效一次。
  static const int _cacheVersion = 8;

  /// 数据源的规范展示顺序（唯一顺序来源）
  ///
  /// 「抓取数据源设定」弹窗的列表、默认启用顺序、以及抓取结果条目的
  /// 排列顺序全部以此为准，避免出现"列表一个顺序 / 结果另一个顺序"。
  ///
  /// 顺序约定（产品需求，2026-11-04 调整：移除 DLsite/ErogameScape/TouchGal，
  /// 新增 2Dfan 并插在 CT 之后、VNDB 之前）：
  /// 1. MIX源（整合源，最顶部）
  /// 2. NextMoe
  /// 3. CT 探索库
  /// 4. 2Dfan
  /// 5. VNDB
  /// 6. KunGal
  /// 7. Hikarinagi
  /// 8. 月幕GAL
  /// 9. Steam
  /// 10. Bangumi
  static const List<SourceType> kSourceOrder = [
    SourceType.mix,
    SourceType.nextmoe,
    // CT 探索库（自有平台）：产品需求——优先级 NextMoe 之下、VNDB 之上
    SourceType.ct,
    // 2Dfan（中文 Galgame 资料站，HTML 抓取）：产品需求——CT 之下、VNDB 之上
    SourceType.twoDfan,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
  ];

  /// 数据源在规范顺序中的位次（未登记则返回末尾大值，保证不丢源）
  static int _sourceOrderIndexOf(SourceType source) {
    final index = kSourceOrder.indexOf(source);
    return index < 0 ? kSourceOrder.length : index;
  }

  /// 将任意数据源集合按 [kSourceOrder] 规范排序
  ///
  /// 未登记的新数据源按枚举顺序追加在末尾，避免将来新增平台时从列表中丢失。
  static List<SourceType> sortSourcesByDisplayOrder(
      Iterable<SourceType> sources) {
    final list = sources.where((s) => s != SourceType.local).toList();
    list.sort((a, b) {
      final c = _sourceOrderIndexOf(a).compareTo(_sourceOrderIndexOf(b));
      if (c != 0) return c;
      return a.index.compareTo(b.index);
    });
    return list;
  }

  // 用户启用的数据源（默认 MIX + 8 独立源，可通过 setEnabledSources 配置）
  // KunGal：公开 API，详情含 vndb_id 可跨源补全 VNDB 评分/投票数/截图
  // MIX：整合源。整合范围**跟随**平台开关（2026-11-13 起）：
  //      关掉的平台不参与整合，全关时兜底回退到全部内置源。
  //      平台开关同时控制一键抓取列表中的独立条目。
  //      批量导入默认直接采用 MIX 整合结果
  // 顺序与 [kSourceOrder] 保持一致（见上）
  static List<SourceType> _enabledSources = [
    SourceType.mix,
    SourceType.nextmoe,
    SourceType.ct,
    SourceType.twoDfan,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
  ];

  /// 字段级「首选平台」覆盖（字段名 → 平台组，见 [MetadataFieldPriority]）。
  ///
  /// 空表 = 所有字段走 [_mixFieldPriority] 的内置链；用户只选「先看哪家」，
  /// 其余平台仍按内置顺序后备，不会因为选了某家就丢掉其它源。
  /// 值是列表：设置页把 nextmoe + kun 显示成一张「鲲GAL/NextMoe」卡片，
  /// 选中时两个一起提前（组内顺序不变）。
  static Map<String, List<SourceType>> _fieldPriorityOverrides =
      <String, List<SourceType>>{};

  /// 初始化：加载代理设置 + 数据源配置 + 磁盘缓存
  static Future<void> init() async {
    // 设置抓取日志路径（release 模式下诊断各平台抓取失败原因）
    setFetchLogPath(p.join(PathHelper.dataDir, 'metadata_fetch.log'));
    fetchLog('[MetadataFetcher] ===== init() 开始 =====');
    await _loadProxySettings();
    await _loadEnabledSources();
    // 字段级「首选平台」覆盖（用户设置 → 元数据 → 优先级）。未配置时为空表，
    // 所有字段继续走 _mixFieldPriority 的内置链。
    _fieldPriorityOverrides = await MetadataFieldPriority.load();
    // 平台登录令牌：必须在建服务之前读进内存。
    // 🔴 不在这里 hydrate 的话，用户重启后不开设置页，抓取层永远拿不到令牌
    // （`cachedAccessToken` 走内存副本），会静默退回内置凭据。
    await MetadataLoginService.instance.hydrate();
    await _initDio();
    fetchLog(
        '[MetadataFetcher] 启用数据源: ${_enabledSources.map((s) => s.displayName).join(", ")}');
    fetchLog('[MetadataFetcher] ${NetworkProxyPolicy.instance.statusText}');
    // 加载 VNDB 大数据翻译资源（~2990 条标签），失败时静默降级
    await TagTranslator.initialize();
    await _loadDiskCache();
    fetchLog('[MetadataFetcher] ===== init() 完成 =====');
  }

  // ==================== 代理设置 ====================

  /// 加载全局代理策略并安装全局 HttpOverrides。
  ///
  /// 策略（自动跟随系统代理 / 手动 / 直连）与运行期刷新全部由
  /// [NetworkProxyPolicy] 统一负责；本类只负责把全局 Dio 接上去。
  static Future<void> _loadProxySettings() async {
    await NetworkProxyPolicy.instance.load();
  }

  /// 初始化全局 Dio 并接入统一代理策略。
  ///
  /// 🔴 旧实现在这里一次性解析代理（app 配置 > 系统代理 > 环境变量），
  /// 把结果写死进 `onHttpClientCreate` ⇒ 运行期开关系统代理永远不生效；
  /// 且手动 URL 会永久压过系统代理、代理端口不通时静默退回直连 ——
  /// 这正是「开了代理元数据抓取反而时好时坏」的根因。
  /// 现在回调只读策略的当前值，策略自己按 TTL 在请求前刷新。
  static Future<void> _initDio() async {
    _dio = Dio(BaseOptions(
      // P0.1：缩短超时，单源最坏从 30s 降至 15s，配合并发降低总耗时
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
      },
    ));
    NetworkProxyPolicy.instance.attachTo(_dio!);
  }

  /// 兼容旧调用方：写入手动代理（空 = 回到自动跟随系统代理）。
  /// 设置页现在直接调 [NetworkProxyPolicy.apply]。
  static Future<void> updateProxy(String? proxyUrl) async {
    final url = (proxyUrl ?? '').trim();
    await NetworkProxyPolicy.instance.apply(
      url.isEmpty ? NetworkProxyMode.system : NetworkProxyMode.manual,
      url,
    );
    // 沿用旧语义：代理变更后重建服务实例（内含 Token 缓存）
    _clearServiceCache();
    await _initDio();
  }

  /// 清空服务实例缓存（P0.3）
  ///
  /// 在代理变更、或需要强制重建服务（如清空缓存）时调用。
  static void _clearServiceCache() {
    _serviceCache.clear();
    debugPrint('[MetadataFetcher] 🧹 服务实例缓存已清空');
  }

  // ==================== 数据源配置 ====================

  static Future<void> _loadEnabledSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('enabled_metadata_sources');
      if (saved != null && saved.isNotEmpty) {
        final loaded = <SourceType>[];
        for (final name in saved) {
          final match = SourceType.values.where((e) => e.name == name);
          if (match.isNotEmpty && match.first != SourceType.local) {
            loaded.add(match.first);
          }
        }
        if (loaded.isNotEmpty) {
          // 一次性迁移：MIX 源上线前的老配置不含 mix，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final migrated = prefs.getBool('mix_source_migrated') ?? false;
          if (!migrated) {
            await prefs.setBool('mix_source_migrated', true);
            if (!loaded.contains(SourceType.mix)) {
              loaded.insert(0, SourceType.mix);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：MIX 源已默认开启');
            }
          }
          // 一次性迁移：NextMoe 源上线前的老配置不含 nextmoe，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final nmMigrated = prefs.getBool('nextmoe_source_migrated') ?? false;
          if (!nmMigrated) {
            await prefs.setBool('nextmoe_source_migrated', true);
            if (!loaded.contains(SourceType.nextmoe)) {
              loaded.insert(0, SourceType.nextmoe);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：NextMoe 源已默认开启');
            }
          }
          // 一次性迁移：CT 探索库源上线前的老配置不含 ct，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final ctMigrated = prefs.getBool('ct_source_migrated') ?? false;
          if (!ctMigrated) {
            await prefs.setBool('ct_source_migrated', true);
            if (!loaded.contains(SourceType.ct)) {
              loaded.insert(0, SourceType.ct);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：CT 探索库源已默认开启');
            }
          }
          // 一次性迁移：2Dfan 源上线前的老配置不含 twoDfan，
          // 升级后默认补开（仅此一次；用户此后手动关闭不会被再次打开）
          final fanMigrated =
              prefs.getBool('two_dfan_source_migrated') ?? false;
          if (!fanMigrated) {
            await prefs.setBool('two_dfan_source_migrated', true);
            if (!loaded.contains(SourceType.twoDfan)) {
              loaded.insert(0, SourceType.twoDfan);
              await prefs.setStringList(
                'enabled_metadata_sources',
                loaded.map((s) => s.name).toList(),
              );
              debugPrint('[MetadataFetcher] ✅ 迁移：2Dfan 源已默认开启');
            }
          }
          // 老配置可能是任意顺序（含升级前保存的枚举顺序），
          // 统一规范化为 kSourceOrder，保证弹窗勾选顺序与抓取结果顺序一致
          _enabledSources = sortSourcesByDisplayOrder(loaded);
        }
      }
      debugPrint(
          '[MetadataFetcher] ✅ 启用数据源: ${_enabledSources.map((s) => s.displayName).join(", ")}');
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载数据源配置失败: $e');
    }
  }

  /// 设置启用的数据源（用户在设置页修改后调用）
  ///
  /// 会清空缓存（数据源变化后旧缓存失效）
  static Future<void> setEnabledSources(List<SourceType> sources) async {
    if (sources.isEmpty) {
      debugPrint('[MetadataFetcher] ⚠️ 数据源列表为空，忽略');
      return;
    }
    final ordered = sortSourcesByDisplayOrder(sources);
    _enabledSources = ordered;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enabled_metadata_sources',
      ordered.map((s) => s.name).toList(),
    );
    // 数据源变化后旧缓存失效
    clearCache();
    debugPrint(
        '[MetadataFetcher] ✅ 数据源已更新: ${sources.map((s) => s.displayName).join(", ")}');
  }

  /// 设置某字段的「首选平台」（null/空 = 恢复内置链）。
  ///
  /// 只改优先级链的顺序，不改变「其它平台作为后备」的语义。
  /// 变更后清空缓存：旧的 MIX 结果是用旧优先级算出来的，必须失效。
  static Future<void> setFieldPriority(
      String field, List<SourceType>? sources) async {
    if (!MetadataFieldPriority.fields.contains(field)) {
      debugPrint('[MetadataFetcher] ⚠️ 未知字段，忽略: $field');
      return;
    }
    if (sources == null || sources.isEmpty) {
      _fieldPriorityOverrides.remove(field);
    } else {
      _fieldPriorityOverrides[field] = List<SourceType>.unmodifiable(sources);
    }
    await MetadataFieldPriority.save(_fieldPriorityOverrides);
    clearCache();
    debugPrint('[MetadataFetcher] ✅ $field 首选平台 = '
        '${sources == null || sources.isEmpty ? "内置默认" : sources.map((s) => s.displayName).join(" + ")}');
  }

  /// 当前字段级覆盖（供设置页回显）。
  static Map<String, List<SourceType>> getFieldPriorityOverrides() =>
      Map<String, List<SourceType>>.unmodifiable(_fieldPriorityOverrides);

  /// 某字段**实际生效**的优先级链（含用户覆盖），供 UI 显示「当前：X → Y → Z」。
  static List<SourceType> getEffectiveFieldChain(String field) =>
      MetadataFieldPriority.resolveChain(
        field,
        _fieldPriorityOverrides[field],
        _mixFieldPriority,
      );

  /// 当前 MIX 实际会整合哪些平台（供设置页显示，跟随平台开关）。
  static List<SourceType> getEffectiveMixSources() {
    final Set<SourceType> enabled = _enabledSources.toSet();
    final List<SourceType> picked =
        _mixSources.where((s) => enabled.contains(s)).toList(growable: false);
    return List<SourceType>.unmodifiable(
        picked.isEmpty ? _mixSources : picked);
  }

  /// 获取当前启用的数据源（供设置页展示）
  static List<SourceType> getEnabledSources() =>
      List.unmodifiable(_enabledSources);

  /// 获取所有可选数据源（除 local 外），按 [kSourceOrder] 规范顺序返回
  ///
  /// 弹窗列表与抓取结果条目共用此顺序。
  static List<SourceType> getAvailableSources() =>
      sortSourcesByDisplayOrder(SourceType.values);

  // ==================== 磁盘缓存持久化 ====================

  static String get _cacheDirPath => p.join(PathHelper.dataDir, 'cache');

  static Future<void> _loadDiskCache() async {
    if (_cacheLoaded) return;
    try {
      _cacheFilePath = p.join(_cacheDirPath, 'metadata_cache.json');
      final file = File(_cacheFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content) as Map<String, dynamic>;
        // 版本不匹配 → 旧缓存整体作废并删除（解析逻辑变更后旧结果不可信）
        if (data['_version'] != _cacheVersion) {
          await file.delete();
          debugPrint('[MetadataFetcher] 🗑️ 缓存版本不匹配（v$_cacheVersion），旧缓存已失效');
          _cacheLoaded = true;
          return;
        }
        // 清理过期缓存
        final now = DateTime.now();
        for (final entry in data.entries) {
          if (entry.value is Map) {
            final cached = Map<String, dynamic>.from(entry.value);
            final cachedAtStr = cached['_cached_at'] as String?;
            if (cachedAtStr != null) {
              final cachedAt = DateTime.parse(cachedAtStr);
              if (now.difference(cachedAt) < _cacheTtl) {
                _cache[entry.key] = cached;
              }
            }
          }
        }
        debugPrint('[MetadataFetcher] 📦 已加载磁盘缓存: ${_cache.length} 条');
      }
      _cacheLoaded = true;
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 加载磁盘缓存失败: $e');
      _cacheLoaded = true;
    }
  }

  static Future<void> _persistCache() async {
    if (_cacheFilePath == null) return;
    try {
      final file = File(_cacheFilePath!);
      final dir = Directory(p.dirname(_cacheFilePath!));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await file
          .writeAsString(jsonEncode({..._cache, '_version': _cacheVersion}));
    } catch (e) {
      debugPrint('[MetadataFetcher] ⚠️ 持久化缓存失败: $e');
    }
  }

  // ==================== 核心抓取（并发）====================

  /// 抓取游戏元数据
  ///
  /// 性能优化：并发查询所有启用数据源（Future.wait），
  /// 最坏耗时从串行 200秒 降至单源最慢决定（约15秒）。
  ///
  /// - [gameName] 游戏名称
  /// - [preferredSource] 指定单源查询（为 null 时使用 _enabledSources）
  /// - [useCache] 是否使用缓存
  static Future<List<Map<String, dynamic>>> fetchGame(
    String gameName, {
    SourceType? preferredSource,
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) {
      return [];
    }
    // MIX 为整合源：路由到 fetchGameMixed（无独立抓取服务）
    if (preferredSource == SourceType.mix) {
      final mixed = await fetchGameMixed(gameName, useCache: useCache);
      return mixed == null ? [] : [mixed];
    }
    fetchLog(
        '[MetadataFetcher] >>> fetchGame("$gameName") sources=${preferredSource?.name ?? "all enabled"} useCache=$useCache');

    final cacheKey = '${preferredSource?.name ?? "all"}:$gameName';

    // 缓存命中检查
    if (useCache && _cache.containsKey(cacheKey)) {
      final cached = _cache[cacheKey]!;
      final cachedAtStr = cached['_cached_at'] as String?;
      if (cachedAtStr != null) {
        final cachedAt = DateTime.parse(cachedAtStr);
        if (DateTime.now().difference(cachedAt) < _cacheTtl) {
          debugPrint('[MetadataFetcher] 📦 使用缓存: $gameName');
          // 缓存可能存储多个结果（_results 字段）
          final cachedResults = cached['_results'];
          if (cachedResults is List) {
            return cachedResults
                .map((r) => r is Map
                    ? Map<String, dynamic>.from(r)
                    : <String, dynamic>{})
                .where((r) => r.isNotEmpty)
                .toList();
          }
          // 兼容旧格式（单个结果）
          return [Map<String, dynamic>.from(cached)..remove('_cached_at')];
        }
      }
      _cache.remove(cacheKey);
    }

    try {
      // 启用的独立数据源（preferredSource 单源模式时仅该源）
      final independent = preferredSource != null
          ? [preferredSource]
          : _enabledSources.where((s) => s != SourceType.mix).toList();
      final mixEnabled = preferredSource == null
          ? _enabledSources.contains(SourceType.mix)
          : preferredSource == SourceType.mix;

      // 实际发起请求的源集合：
      // - 全部已启用的独立源（各自返回独立条目，供用户对比选择）
      // - MIX 启用时补充其**全部**底层平台（MIX 整合范围固定为 5 平台，
      //   不随各平台开关变化；未启用的底层平台仅供电整合取数，
      //   不作为独立条目返回——用户未开启它们）。
      //   已启用的底层平台只请求一次，结果同时用于独立条目与 MIX 整合
      final fetchSet = <SourceType>{...independent};
      if (mixEnabled) {
        fetchSet.addAll(_mixSources);
      }

      // ===== 并发查询所有数据源 =====
      // 每个源独立 try-catch，单源失败不影响其他源
      final perSource = <SourceType, Map<String, dynamic>>{};
      final futures = fetchSet.map((source) async {
        final sw = Stopwatch()..start();
        try {
          final service = _createService(source);
          final result = await service.fetchByName(gameName);
          sw.stop();
          if (result.isValid) {
            final legacy = _convertToLegacyFormat(result);
            perSource[source] = legacy;
            fetchLog(
                '[MetadataFetcher] [$source] ✅ 成功 (${sw.elapsedMilliseconds}ms) name="${result.game.name}" id=${result.game.id}');
            // 仅已启用的独立源返回条目；MIX 专用补充源只供整合
            return independent.contains(source) ? legacy : null;
          }
          fetchLog(
              '[MetadataFetcher] [$source] ⚠️ 无效结果 (${sw.elapsedMilliseconds}ms) name="${result.game.name}" id="${result.game.id}"');
          return null;
        } catch (e) {
          sw.stop();
          fetchLog(
              '[MetadataFetcher] [$source] ❌ 异常 (${sw.elapsedMilliseconds}ms): $e');
          return null;
        }
      });

      var results = (await Future.wait(futures))
          .whereType<Map<String, dynamic>>()
          .toList();

      // MIX 整合条目：由本轮已抓取的底层平台结果合成（零额外请求），
      // 置于列表首位（综合推荐项），与其余平台的独立条目共存，
      // 供用户在多平台数据间自行选择
      if (mixEnabled) {
        final mixPerSource = <SourceType, Map<String, dynamic>>{};
        for (final entry in perSource.entries) {
          if (_mixSources.contains(entry.key)) {
            mixPerSource[entry.key] = entry.value;
          }
        }
        if (mixPerSource.isNotEmpty) {
          results.insert(0, _mergeMixResults(mixPerSource));
          fetchLog(
              '[MetadataFetcher] [mix] ✅ 整合条目已加入结果 (${mixPerSource.length}平台命中)');
        } else {
          fetchLog('[MetadataFetcher] [mix] ⚠️ 底层平台均无数据，无 MIX 条目');
        }
      }

      // 缓存写入（持久化到磁盘）
      if (results.isNotEmpty) {
        _cache[cacheKey] = {
          '_cached_at': DateTime.now().toIso8601String(),
          '_results': results,
        };
        // 异步持久化，不阻塞返回
        _persistCache();
      }

      debugPrint(
          '[MetadataFetcher] ✅ 查询完成: $gameName → ${results.length} 条结果 (并发${fetchSet.length}源, MIX=${mixEnabled ? "开" : "关"})');
      return results;
    } catch (e) {
      debugPrint('[MetadataFetcher] ❌ 总体错误: $e');
      return [];
    }
  }

  // ==================== MIX 源（多平台字段级整合）====================

  /// MIX 源整合的底层平台（月幕GAL = ymgal）
  static const List<SourceType> _mixSources = [
    SourceType.nextmoe,
    SourceType.ct,
    SourceType.twoDfan,
    SourceType.vndb,
    SourceType.hikarinagi,
    SourceType.kun,
    SourceType.steam,
    SourceType.ymgal,
  ];

  // 仅供单元测试 / 离线探针：只读暴露 MIX 整合配置（勿在业务代码使用）
  @visibleForTesting
  static List<SourceType> get mixSourcesForTest =>
      List.unmodifiable(_mixSources);

  @visibleForTesting
  static Map<String, List<SourceType>> get mixFieldPriorityForTest =>
      _mixFieldPriority;

  /// MIX 源各数据字段抓取优先级（高 → 低）
  ///
  /// NextMoe 为六源对齐目录（VNDB/Bangumi/DLsite/ErogameScape/Ci-en/
  /// Getchu 逐字段裁定的标准答案），作为**所有字段的第一优先级**；
  /// CT 探索库（自有平台，社区共建中文元数据）按产品需求列第二优先级
  /// （NextMoe 之下、VNDB 之上）；2Dfan（中文 Galgame 资料站，HTML 抓取）
  /// 列第三优先级（CT 之下、VNDB 之上，2026-11-04 接入）；其余平台保持
  /// 原有相对顺序依次降级（高优先源缺失/异常时后退）。
  static const Map<String, List<SourceType>> _mixFieldPriority = {
    // 封面图：NextMoe → CT → 2Dfan → VNDB → Hikarinagi → KunGal → Steam → 月幕GAL
    'cover_url': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.vndb,
      SourceType.hikarinagi,
      SourceType.kun,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 副标题（原版标题）：NextMoe → CT → 2Dfan → VNDB → KunGal
    'original_title': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.vndb,
      SourceType.kun
    ],
    // ★ 2026-10-10 「副标题 = 全部别名」：结构化别名列表。CT 提供多别名
    // （日文原名/英文名/繁中名）列首位；★ 2026-11-04 2Dfan 的 <title> 也是
    // 一串译名（`原名_中文名_简称…`），列 CT 之后；其余平台该项恒为空列表，
    // pick() 自动跳过。全部为空时 merged 不含该键 → 上游回退 original_title。
    'alias_names': [
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.nextmoe,
      SourceType.vndb,
      SourceType.kun
    ],
    // ★ 2026-10-04 横幅封面：NextMoe（covers[] 横版）与 KunGal
    // （effective_banner_url）提供横幅；VNDB kana API 无横幅字段。
    // ★ 2026-10-05 修复：接入 Hikarinagi（covers[] 横版，开发者实测该平台
    // 横幅数据最完整）；KunGal 降为链尾——其 effective_banner_url 是论坛帖
    // 头图、无尺寸元数据，曾混入音乐盘图等非横幅内容（下载侧宽高比校验
    // ≥1.15 兜底，见 CoverDownloadService.downloadCover）。
    // 未列出的平台 pick() 自动跳过（其结果里 banner_url 恒为空串）。
    'banner_url': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.hikarinagi,
      SourceType.kun,
    ],
    // 标签：NextMoe → CT → 2Dfan → Hikarinagi → KunGal → VNDB → Steam
    'tags': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.hikarinagi,
      SourceType.kun,
      SourceType.vndb,
      SourceType.steam
    ],
    // 会社（开发商）：NextMoe → CT → 2Dfan → VNDB → KunGal → Hikarinagi → Steam
    'developer': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.vndb,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.steam
    ],
    // 简介：NextMoe → CT → 2Dfan → KunGal → Hikarinagi → VNDB → Steam → 月幕GAL
    'summary': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 截图：NextMoe → CT → KunGal → Hikarinagi → VNDB
    // （2Dfan 不提供截图，故不列入本链）
    'screenshot_urls': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb
    ],
    // 主标题：中文名优先（NextMoe 六源对齐中文名 → CT 社区中文名 →
    // 2Dfan 中文译名 → KunGal → …）
    'game_name': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.kun,
      SourceType.vndb,
      SourceType.hikarinagi,
      SourceType.steam,
      SourceType.ymgal
    ],
    // 评分/投票数/发售日：NextMoe（自带 VNDB 评分）→ CT → 2Dfan → VNDB → …
    'rating': [
      SourceType.nextmoe,
      SourceType.ct,
      SourceType.twoDfan,
      SourceType.vndb,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.steam,
      SourceType.ymgal
    ],
  };

  /// MIX 源：并发抓取多平台并按字段优先级整合（批量导入默认源）
  ///
  /// 流程：
  /// 1. 并发抓取 [_mixSources] 中**已启用**的底层平台（单源失败/无数据不影响
  ///    其他源，各源结果同时写入独立缓存键 `源:name`）。
  ///    整合范围跟随用户在设置页的平台开关；全关时兜底回退到全部内置源。
  /// 2. 按 [_mixFieldPriority] 逐字段取最高优先级平台的非空值，
  ///    天然实现"优先平台无数据 → 按优先级后退到次级平台"
  /// 3. 整合结果统一标识 `platform = "MIX源"`，并附带
  ///    `source_platforms`（各平台与其 ID 的映射，供排重使用）
  /// 4. 整合结果缓存于 `mix:name`（TTL 同单源缓存），重复抓取零请求
  ///
  /// 所有平台均无数据时返回 null。
  static Future<Map<String, dynamic>?> fetchGameMixed(
    String gameName, {
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) return null;

    // MIX 合并结果缓存
    final mixCacheKey = '${SourceType.mix.name}:$gameName';
    if (useCache && _cache.containsKey(mixCacheKey)) {
      final cached = _cache[mixCacheKey]!;
      final cachedAtStr = cached['_cached_at'] as String?;
      if (cachedAtStr != null &&
          DateTime.now().difference(DateTime.parse(cachedAtStr)) < _cacheTtl) {
        final cachedResult = cached['_results'];
        if (cachedResult is List && cachedResult.isNotEmpty) {
          fetchLog('[MetadataFetcher] 📦 MIX 缓存命中: $gameName');
          return Map<String, dynamic>.from(cachedResult.first);
        }
      }
      _cache.remove(mixCacheKey);
    }

    // 2026-11-13（用户拍板）：MIX 整合范围**跟随平台开关**。
    // 旧实现在这里写死 `_mixSources`，导致「在设置里关掉 VNDB」之后
    // MIX 仍然偷偷用 VNDB —— 开关看起来完全没生效，是最容易让人失去
    // 信任的那种不一致。
    //
    // 兜底：用户把源全关（理论上 setEnabledSources 会拒绝空表，但偏好
    // 可能被外部写坏）时回退到全部内置源，避免 MIX 直接失效。
    final Set<SourceType> enabled = _enabledSources.toSet();
    final List<SourceType> picked =
        _mixSources.where((s) => enabled.contains(s)).toList(growable: false);
    final sources = List<SourceType>.unmodifiable(
        picked.isEmpty ? _mixSources : picked);

    fetchLog('[MetadataFetcher] >>> fetchGameMixed("$gameName") '
        'sources=${sources.map((s) => s.displayName).join(" + ")}');

    // 并发抓取各平台（fetchGame 单源模式，各源独立缓存/超时/异常捕获）
    final perSource = <SourceType, Map<String, dynamic>>{};
    final futures = sources.map((source) async {
      // 单源结果缓存在 `源:name`，MIX 内部复用避免重复请求
      final results = await fetchGame(gameName,
          preferredSource: source, useCache: useCache);
      if (results.isNotEmpty) perSource[source] = results.first;
    });
    await Future.wait(futures);

    if (perSource.isEmpty) {
      fetchLog('[MetadataFetcher] MIX 全源无数据: $gameName');
      return null;
    }

    final merged = _mergeMixResults(perSource);
    // MIX 合并结果缓存
    _cache[mixCacheKey] = {
      '_cached_at': DateTime.now().toIso8601String(),
      '_results': [merged],
    };
    _persistCache();
    return merged;
  }

  /// 按字段优先级合并各平台结果
  ///
  /// 每个字段独立取值：按 [_mixFieldPriority] 顺序找到第一个非空值；
  /// 未配置优先级的字段（rating/vote_count/release_date 等数值类）
  /// 复用 'rating' 的优先级链。`platform` 固定为 "MIX源"，
  /// `platform_id` 取主标题提供平台的 ID，`source_platforms`
  /// 记录全部命中平台与其 ID（供批量导入做源 ID 排重）。
  static Map<String, dynamic> _mergeMixResults(
      Map<SourceType, Map<String, dynamic>> perSource) {
    // 按字段优先级取第一个非空值
    Object? pick(String field) {
      // 用户设置的首选平台优先，其余仍按内置链后备
      // （resolveChain：选中的提到首位 + 去掉重复，不丢其它源）
      final priority = MetadataFieldPriority.resolveChain(
        field,
        _fieldPriorityOverrides[field],
        _mixFieldPriority,
      );
      for (final source in priority) {
        final result = perSource[source];
        if (result == null) continue;
        final value = result[field];
        final isEmpty = value == null ||
            (value is String && value.trim().isEmpty) ||
            (value is List && value.isEmpty) ||
            (value is num && value == 0);
        if (!isEmpty) return value;
      }
      return null;
    }

    final merged = <String, dynamic>{};
    // vote_count/release_date 未单独配置优先级，pick() 自动复用
    // 'rating' 的优先级链（VNDB 最权威 → 逐级后退）
    final mixFields = [
      ..._mixFieldPriority.keys,
      'vote_count',
      'release_date',
      // 预计游玩时长：未单独配置优先级，pick() 自动复用
      // 'rating' 的优先级链（VNDB 唯一提供方 → 必命中）
      'length_minutes',
      'length_votes',
    ];
    for (final field in mixFields) {
      final value = pick(field);
      if (value != null) merged[field] = value;
    }

    // tags_meta 跟随 tags 同源（标签元数据与标签名保持一致）
    final tagsPriority = _mixFieldPriority['tags']!;
    for (final source in tagsPriority) {
      final result = perSource[source];
      if (result == null) continue;
      final tags = result['tags'];
      final tagsMeta = result['tags_meta'];
      final tagsEmpty = tags is! List || tags.isEmpty;
      final metaEmpty = tagsMeta is! List || tagsMeta.isEmpty;
      if (!tagsEmpty && !metaEmpty) {
        merged['tags_meta'] = tagsMeta;
        break;
      }
    }

    // 平台标识：统一展示为 MIX源；platform_id 取主标题提供平台
    merged['platform'] = SourceType.mix.displayName;
    final namePriority = _mixFieldPriority['game_name']!;
    for (final source in namePriority) {
      final result = perSource[source];
      if (result == null) continue;
      final id = result['platform_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        merged['platform_id'] = id;
        break;
      }
    }

    // 各命中平台的源 ID 映射（供排重：任一底层平台 ID 冲突即视为重复）
    final sourcePlatforms = <String, String>{};
    for (final entry in perSource.entries) {
      final id = entry.value['platform_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        sourcePlatforms[entry.key.displayName] = id;
      }
    }
    merged['source_platforms'] = sourcePlatforms;

    fetchLog('[MetadataFetcher] ✅ MIX 整合完成: '
        'name="${merged['game_name']}" '
        '来源=${perSource.keys.map((s) => s.displayName).join("+")} '
        '字段提供='
        '${_mixFieldPriority.keys.where((f) => merged.containsKey(f) && f != 'game_name').map((f) => '$f=${_fieldProvider(f, perSource)}').join(", ")}');
    return merged;
  }

  /// 诊断辅助：返回某字段实际由哪个平台提供（仅日志用）
  static String _fieldProvider(
      String field, Map<SourceType, Map<String, dynamic>> perSource) {
    final priority = _mixFieldPriority[field] ?? const <SourceType>[];
    for (final source in priority) {
      final result = perSource[source];
      if (result == null) continue;
      final value = result[field];
      final isEmpty = value == null ||
          (value is String && value.trim().isEmpty) ||
          (value is List && value.isEmpty);
      if (!isEmpty) return source.displayName;
    }
    return '-';
  }

  /// 多平台并发抓取游戏截图（详情页 Priority 3 / 截图补全 backfill 使用）
  ///
  /// 从 [sources] 并发抓取，按 sources 顺序（即优先级）合并各源截图并
  /// 去重，最多 [maxTotal] 张。默认顺序与 MIX 源截图优先级一致
  /// （NextMoe → KunGal → Hikarinagi → VNDB，见
  /// [_mixFieldPriority]['screenshot_urls']）。
  /// 单源失败/无截图不影响其他源；全部无截图时返回空列表。
  ///
  /// 备选标题回退：主标题 [gameName] 无截图时，依次尝试 [altNames]
  /// （如副标题/日文原标题/英文标题）——中文标题在数据源常无收录，
  /// 原版标题往往能命中。任一标题抓到截图即停止回退。
  static Future<List<String>> fetchScreenshots(
    String gameName, {
    List<String> altNames = const [],
    List<SourceType> sources = const [
      SourceType.nextmoe,
      SourceType.kun,
      SourceType.hikarinagi,
      SourceType.vndb,
    ],
    int maxTotal = 6,
    bool useCache = true,
  }) async {
    if (gameName.trim().isEmpty) return [];

    var urls = await _fetchScreenshotsForName(gameName,
        sources: sources, maxTotal: maxTotal, useCache: useCache);

    // 主标题无截图 → 依次尝试备选标题（跳过空值与重复）
    if (urls.isEmpty) {
      final primary = gameName.trim();
      for (final alt in altNames) {
        final altName = alt.trim();
        if (altName.isEmpty || altName == primary) continue;
        fetchLog('[MetadataFetcher] 🔄 主标题无截图，回退备选标题: '
            '"$primary" → "$altName"');
        urls = await _fetchScreenshotsForName(altName,
            sources: sources, maxTotal: maxTotal, useCache: useCache);
        if (urls.isNotEmpty) break;
      }
    }

    return urls;
  }

  /// 按单个标题并发抓取截图（[fetchScreenshots] 的单标题实现）
  static Future<List<String>> _fetchScreenshotsForName(
    String gameName, {
    required List<SourceType> sources,
    required int maxTotal,
    required bool useCache,
  }) async {
    if (gameName.trim().isEmpty) return [];

    fetchLog('[MetadataFetcher] >>> fetchScreenshots("$gameName") '
        'sources=${sources.map((s) => s.name).join(",")}');

    // 三源并发抓取（单源异常静默降级为空结果）
    final futures = sources.map((source) async {
      try {
        return await fetchGame(gameName,
            preferredSource: source, useCache: useCache);
      } catch (e) {
        fetchLog('[MetadataFetcher] [$source] 截图抓取异常: $e');
        return <Map<String, dynamic>>[];
      }
    });
    final resultsBySource = await Future.wait(futures);

    // 按源优先级合并截图，去重
    final urls = <String>[];
    final seen = <String>{};
    for (final results in resultsBySource) {
      for (final result in results) {
        final shotUrls = result['screenshot_urls'];
        if (shotUrls is! List) continue;
        for (final url in shotUrls) {
          final u = url.toString();
          if (u.isEmpty || seen.contains(u)) continue;
          seen.add(u);
          urls.add(u);
          if (urls.length >= maxTotal) {
            fetchLog('[MetadataFetcher] ✅ 截图抓取完成: $gameName → '
                '${urls.length}张 (达上限，来源优先级截断)');
            return urls;
          }
        }
      }
    }

    fetchLog('[MetadataFetcher] ✅ 截图抓取完成: $gameName → ${urls.length}张');
    return urls;
  }

  /// 获取/创建数据源服务（P0.3：带实例缓存）
  ///
  /// 命中缓存直接返回，否则创建并缓存。关键收益：服务内的 Token 缓存
  /// （如 YmgalService._cachedToken）跨多次 fetchGame 复用，避免每个游戏
  /// 都重新获取 Token。代理变更时通过 [_clearServiceCache] 清空重建。
  static MetadataSourceService _createService(SourceType sourceType) {
    final cached = _serviceCache[sourceType];
    if (cached != null) return cached;

    final service = _instantiateService(sourceType);
    _serviceCache[sourceType] = service;
    return service;
  }

  static MetadataSourceService _instantiateService(SourceType sourceType) {
    // ===== 对齐 LunaBox：所有平台统一继承全局智能代理配置 =====
    // 全局 _dio 已通过三级检测（app配置 > Windows系统代理 > 环境变量）
    // + TCP 存活验证确定最终代理：可用代理→走代理；死代理/无代理→直连。
    // 每个服务创建自己的 Dio（含专属 headers），通过 applyProxyConfig
    // 复制全局 onHttpClientCreate 回调（独立 adapter，非共享）。
    //
    // 这样无论用户网络环境如何都能正确访问：
    // - 开启代理：所有平台走可用代理（含国内可直连平台，代理也能转发）
    // - 关闭代理但残留注册表：策略的 TCP 存活验证排除死代理 → 直连
    // - 完全无代理：findProxyFromEnvironment → 直连（VNDB 等国内可直连平台正常）
    switch (sourceType) {
      case SourceType.vndb:
        return VNDBService(dio: _dio);
      case SourceType.steam:
        return SteamService(dio: _dio);
      case SourceType.ymgal:
        return YmgalService(dio: _dio);
      case SourceType.kun:
        return KunService(dio: _dio);
      case SourceType.hikarinagi:
        return HikarinagiService(
          dio: _dio,
          // 登录了就用用户自己的令牌（不吃全软件共享的那把），没登录回退内置凭据
          userToken: () => MetadataLoginService.instance
              .cachedAccessToken(kOAuthHikarinagi.id),
        );
      case SourceType.nextmoe:
        return NextMoeService(
          dio: _dio,
          userToken: () => MetadataLoginService.instance
              .cachedAccessToken(kOAuthNextMoe.id),
        );
      case SourceType.ct:
        return CTService(dio: _dio);
      case SourceType.twoDfan:
        return TwoDFanService(dio: _dio);
      case SourceType.bangumi:
        return BangumiMirrorService(dio: _dio);
      default:
        throw ArgumentError('不支持的数据源: $sourceType');
    }
  }

  /// 字段格式转换
  ///
  /// 数据质量修复（Phase 2.1）：
  /// - 补回 rating 字段（之前完全丢失）
  /// - 保留 tags 权重/剧透/来源元数据（tags_meta 字段）
  /// - platform 使用 displayName（如"VNDB"而非"vndb"）
  /// 阶段3.1：补回 vote_count 字段（VNDB 投票数，作为热度代理）
  static Map<String, dynamic> _convertToLegacyFormat(MetadataResult result) {
    final game = result.game;

    return {
      'game_name': game.name,
      // 原版标题（优先日文，来自数据源多语言标题），供上游作为"副标题"使用
      'original_title': game.originalTitle,
      // ★ 2026-10-10 「副标题 = 全部别名」：结构化别名列表（日文原名/英文名/
      //   繁中名），CT 与 2Dfan 提供（其余源为 null → 空列表）。
      //   上游 selectScrapeResult / 批量导入优先用它合成 subtitle，
      //   为空时回退 original_title（老行为）。
      'alias_names': game.aliasNames ?? const <String>[],
      'platform': game.sourceType.displayName,
      'platform_id': game.sourceId ?? game.id,
      // 标签名称列表（向后兼容）
      'tags': result.tags.map((tag) => tag.name).toList(),
      // 标签元数据列表（保留权重/剧透/来源，供UI排序和过滤使用）
      'tags_meta': result.tags
          .map((tag) => {
                'name': tag.name,
                'weight': tag.weight,
                'is_spoiler': tag.isSpoiler,
                'source': tag.source,
              })
          .toList(),
      // 补回评分字段（之前完全丢失）
      'rating': game.rating,
      // 补回投票数字段（热度代理，VNDB 提供，其他源为 null）
      'vote_count': game.voteCount,
      // 预计游玩时长（VNDB 多用户平均，分钟；其他源为 null）
      'length_minutes': game.lengthMinutes,
      'length_votes': game.lengthVotes,
      'summary': game.summary ?? '',
      'cover_url': game.coverUrl ?? '',
      // ★ 2026-10-04 横幅封面：NextMoe covers[] 横版 / KunGal banner_url，
      // VNDB 无横幅字段为 null → 转空串（下游按"无横幅"处理）
      'banner_url': game.bannerUrl ?? '',
      'release_date': game.releaseDate ?? '',
      'developer': game.company ?? '',
      'screenshot_urls': game.screenshotUrls ?? [],
    };
  }

  static Future<bool> testConnection(SourceType source) async {
    try {
      // MIX 整合源：底层任一平台连通即视为可用
      if (source == SourceType.mix) {
        final results =
            await Future.wait(_mixSources.map((s) => testConnection(s)));
        return results.contains(true);
      }
      final service = _createService(source);
      return await service.testConnection();
    } catch (e) {
      debugPrint('[MetadataFetcher] 连接测试失败 [$source]: $e');
      return false;
    }
  }

  /// 并发测试所有数据源连接（之前为串行）
  ///
  /// MIX 不单独测试：其底层 5 平台已在本列表中逐个测试，
  /// MIX 可用性 = 任一底层平台连通（见 [testConnection]）
  static Future<Map<SourceType, bool>> testAllConnections() async {
    final sources = SourceType.values
        .where((s) => s != SourceType.local && s != SourceType.mix);
    final futures = sources.map((source) async {
      return MapEntry(source, await testConnection(source));
    });

    final entries = await Future.wait(futures);
    return Map.fromEntries(entries);
  }

  /// 清空缓存（内存 + 磁盘）
  ///
  /// 注意：返回 Future<void>，调用方应 await（或在异步上下文中 fire-and-forget）
  static Future<void> clearCache() async {
    _cache.clear();
    if (_cacheFilePath != null) {
      try {
        final file = File(_cacheFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[MetadataFetcher] ⚠️ 删除磁盘缓存失败: $e');
      }
    }
    debugPrint('[MetadataFetcher] 🗑️ 缓存已清空（内存+磁盘）');
  }

  static String? get currentProxy {
    final url = NetworkProxyPolicy.instance.manualUrl;
    return url.isEmpty ? null : url;
  }
}
