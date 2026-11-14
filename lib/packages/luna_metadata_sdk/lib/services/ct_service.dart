import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'metadata_base.dart';

/// CT 探索库数据源服务（Chrono Tide 自建元数据平台）
///
/// 数据来源：自有 PocketBase 的 `games` 集合（http://117.72.115.30:8090，
/// 与探索页/客户端下载同源），由项目管理员与社区分享者共同整理的
/// 中文元数据，目标是社区优秀的中文元数据平台。
///
/// **接入方式**：与外部平台同构（实现 [MetadataSourceService]），
/// 以 Dio 直调 PB REST API（SDK 包不依赖 pocketbase 客户端库）：
/// - 搜索：`GET {base}/api/collections/games/records?filter=(title~'kw')`
/// - 文件：`{base}/api/files/games/{recordId}/{filename}`
///
/// **网络策略**：PB 部署在国内（京东云），强制直连（[applyProxyConfig]
/// 传 null → 显式 DIRECT），避免用户代理把国内流量绕到海外节点导致
/// 失败，与探索页 PocketBase 客户端（不走代理）行为一致。
///
/// **权限**：games 集合对匿名开放只读（探索页匿名浏览同源），无需鉴权。
///
/// **字段映射**（PB 字段 → 元数据字段）：
/// - `title` → 主标题（中文，社区裁定）
/// - `originalTitle` → 副标题（日文原版标题，上游经 CJK 检查填入副标题）
/// - `description` → 简介；`developer`（兼容旧字段 `Developer`）→ 会社
/// - `cover` / `bannerUrl`（file）→ 竖版封面 / 横幅封面
/// - `screenshots`（多 file）→ 截图列表；`tags`（list 或逗号串）→ 标签
///   （社区整理，已是中文，不走 TagTranslator）
/// - `rating`（0-10）/`voteCount`/`releaseDate` → 评分 / 投票数 / 发售日
class CTService implements MetadataSourceService {
  final Dio _dio;

  /// PB 服务地址（与主程序 lib/core/pb_config.dart 的 _baseUrl 保持一致；
  /// SDK 包不依赖主程序代码，故此处独立常量）
  static const String apiBase = 'http://117.72.115.30:8090';

  CTService({Dio? dio})
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
            'Accept': 'application/json',
          },
        )) {
    // 自建国内服务器：强制直连（不走用户代理，理由见类注释）
    applyProxyConfig(null, _dio);
  }

  @override
  SourceType get sourceType => SourceType.ct;

  @override
  String get sourceName => 'CT';

  @override
  Future<List<MetadataResult>> fetchByIds(List<String> ids) async => [];

  @override
  Future<bool> testConnection() async {
    try {
      final response = await executeRateLimited(
        SourceType.ct,
        () => _dio.get('$apiBase/api/collections/games/records',
            queryParameters: {'perPage': '1'}),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<MetadataResult> fetchByName(String name) async {
    final keyword = name.trim();
    if (keyword.isEmpty) return _emptyResult();

    try {
      // 多字段 OR：主标题 / 日文原名 / 英文名 / 繁中别名（2026-10-05）
      // 实测：仅 title 过滤时搜日文原名「美少女万華鏡」0 命中，
      // 多字段后 7 命中——别名检索是 CT 源可用的前提。
      //
      // ★ 2026-10-10 分词多查询召回（本次核心修复）：
      //   PB 的 `~` 是 SQLite LIKE，只做全半角折叠、**不剥标点/空格**。
      //   线上实测：搜「突然＊恋人」（带＊）命中 1，搜「突然恋人」（去＊，
      //   用户自然会这么打）**0 命中**；搜「Making Lovers」（英文带空格）
      //   0 命中，而该记录 englishTitle='Making * Lovers FHD Deluxe Edition'。
      //   即：探索页（本机归一化匹配）搜得到、一键抓取（服务端 LIKE）搜不到。
      //   修法：把关键词切成「可被服务端命中的最小片段」（CJK 2-gram /
      //   拉丁词），逐段四字段 OR 查询后并集去重召回，再由 [_pickBestMatch]
      //   的归一化 AND 门做精度收敛。
      var items = await _recallRecords(keyword);

      // 0 命中时全角→半角折叠重试（PB 的 ~ 不做全半角归一；用户用全角
      // 输入时原文 LIKE 不命中，折叠字形后即可命中半角标题）
      if (items == null || items.isEmpty) {
        final folded = _foldFullWidth(keyword);
        if (folded != keyword) {
          items = await _recallRecords(folded);
        }
      }

      if (items == null || items.isEmpty) return _emptyResult();

      final bestMatch = _pickBestMatch(items, keyword);
      if (bestMatch == null) return _emptyResult();
      return _parseRecord(bestMatch);
    } catch (e) {
      fetchLog('[CT] 查询失败 [$name]: $e');
      return _emptyResult();
    }
  }

  /// 候选窗口硬上限（多段并集后，防 token 过多导致候选爆炸）
  static const int _maxCandidates = 120;

  /// 单段查询的候选窗口
  static const int _perTokenPerPage = 60;

  /// 分词召回上限（每段一次请求，CT 限流 200ms/次 → 最坏 ~1.4s）
  static const int _maxTokens = 6;

  /// 分词多查询召回：整串 + 逐段（CJK 2-gram / 拉丁词）四字段 OR 并集去重。
  ///
  /// 返回 null = 整串请求失败（网络/参数）；空 List = 正常无命中。
  /// 目的见 [fetchByName]——服务端 LIKE 不剥标点/空格，必须让每个可命中
  /// 片段单独成查询，才能召回「突然＊恋人」这类标点变体。
  Future<List<dynamic>?> _recallRecords(String keyword) async {
    final seen = <String>{};
    final out = <dynamic>[];

    // 1) 整串优先（保持原行为：完整名称一次命中；也保证顺序稳定）
    final primary = await _searchRecords(keyword, perPage: _perTokenPerPage);
    if (primary == null) return null; // 整串请求失败 → 视为查询失败
    _absorb(primary, seen, out);

    // 2) 逐段并集召回（跳过与整串相同的段，避免重复请求）
    final tokens = _queryTokens(keyword);
    for (final token in tokens) {
      if (out.length >= _maxCandidates) break;
      if (token == keyword) continue;
      final part = await _searchRecords(token, perPage: _perTokenPerPage);
      if (part == null) continue; // 单段失败不影响整体（降级为部分召回）
      _absorb(part, seen, out);
    }
    return out;
  }

  /// 把一批 items 并入 out（按记录 id 去重，保持首次出现顺序）
  static void _absorb(List<dynamic> items, Set<String> seen, List<dynamic> out) {
    for (final item in items) {
      if (out.length >= _maxCandidates) return;
      final id = (item is Map) ? item['id']?.toString() : null;
      final key =
          (id == null || id.isEmpty) ? '#${out.length}_${item.hashCode}' : id;
      if (seen.add(key)) out.add(item);
    }
  }

  /// 关键词分词：[fetchByName] 的服务端召回单元。
  ///
  /// 规则（用与 [normalizeForSearch] 相同的字形折叠 + 标点剥离口径）：
  /// - 按空白/中英文标点切段（先剥 [_searchNoise]，再剥剩余符号如 ＊）；
  /// - 含 CJK 且长度 ≥4 → 滑窗 2-gram（「突然恋人」→ 突然/然恋/恋人，
  ///   可召回被标点/空格隔断的「突然＊恋人」）；
  /// - 含 CJK 且长度 ≤3 → 整段；
  /// - 拉丁/数字且长度 ≥3 → 整词；
  /// - 全部被丢弃时回退为归一化整串。
  static List<String> _queryTokens(String keyword) {
    final cleaned = _foldFullWidth(keyword)
        .toLowerCase()
        .replaceAll(_searchNoise, ' ') // 先剥标点/空白（含 ・ 等）
        .replaceAll(_nonWord, ' ') // 再剥剩余符号（含 ＊ 等）
        .trim();

    final tokens = <String>[];
    final seen = <String>{};
    void add(String t) {
      if (t.isNotEmpty && seen.add(t)) tokens.add(t);
    }

    if (cleaned.isEmpty) {
      final norm = normalizeForSearch(keyword);
      if (norm.isNotEmpty) add(norm);
    } else {
      for (final seg in cleaned.split(RegExp(r'\s+'))) {
        if (seg.isEmpty) continue;
        if (_hasCjk.hasMatch(seg)) {
          final runes = seg.runes.toList();
          if (runes.length >= 4) {
            for (var i = 0; i + 1 < runes.length; i++) {
              add(String.fromCharCodes(runes.sublist(i, i + 2)));
            }
          } else {
            add(seg);
          }
        } else if (seg.length >= 3) {
          add(seg);
        }
      }
      if (tokens.isEmpty) {
        final norm = normalizeForSearch(keyword);
        if (norm.isNotEmpty) add(norm);
      }
    }
    return tokens.length > _maxTokens ? tokens.sublist(0, _maxTokens) : tokens;
  }

  /// 任意 CJK / 假名 / 谚文（用于判定段是否按 CJK 规则切 2-gram）
  static final RegExp _hasCjk = RegExp(
      r'[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]');

  /// 非「词」字符（剥掉后仅剩拉丁字母/数字/CJK/假名），用于分词清理
  static final RegExp _nonWord = RegExp(
      r'[^a-z0-9\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]+');

  /// 按关键词执行一次多字段搜索，返回 items 列表。
  /// 返回 null = 请求失败/无有效输入；空 List = 正常无命中。
  Future<List<dynamic>?> _searchRecords(String keyword,
      {int perPage = 60}) async {
    final filter = _nameSearchFilter(keyword);
    if (filter == null) return null;

    final response = await executeRateLimited(
      SourceType.ct,
      () => _dio.get('$apiBase/api/collections/games/records',
          queryParameters: {
            'page': '1',
            // 多字段命中面大于单 title，扩大候选窗口避免漏掉最佳匹配
            'perPage': '$perPage',
            'sort': '-created',
            'filter': filter,
          }),
    );
    if (response.statusCode != 200) return null;

    final json =
        response.data is String ? jsonDecode(response.data) : response.data;
    return safeList(
        json is Map ? Map<String, dynamic>.from(json) : {}, 'items');
  }

  /// 全角 ASCII（0xFF01-0xFF5E）与全角空格 → 半角（保留分隔符，
  /// 供服务端 LIKE 二次查询；与 [normalizeForSearch] 共用字形折叠）
  static String _foldFullWidth(String input) {
    final buf = StringBuffer();
    for (final ch in input.runes) {
      if (ch == 0x3000) {
        buf.write(' ');
      } else if (ch >= 0xFF01 && ch <= 0xFF5E) {
        buf.writeCharCode(ch - 0xFEE0);
      } else {
        buf.writeCharCode(ch);
      }
    }
    return buf.toString();
  }

  /// PB filter 字符串字面量转义（与主程序 lib/utils/pb_filter.dart 同规则：
  /// 控制字符折叠 → 截断 64 → 先反斜杠后单引号，顺序不可颠倒）。
  /// SDK 包不依赖主程序代码，故内联实现。返回 null = 无有效输入，不加过滤。
  String? _escapePbLiteral(String keyword) {
    if (keyword.isEmpty) return null;
    var safe = keyword.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
    if (safe.isEmpty) return null;
    if (safe.length > 64) {
      safe = safe.substring(0, 64);
      // 避免截断代理对（emoji 等）产生半个字符
      final lastUnit = safe.codeUnitAt(safe.length - 1);
      if (safe.length > 1 && lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
        safe = safe.substring(0, safe.length - 1);
      }
      safe = safe.trimRight();
    }
    if (safe.isEmpty) return null;
    // ★ 顺序不可颠倒：先反斜杠，再单引号
    return safe.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
  }

  /// 名称搜索 filter：主标题 / 日文原名 / 英文名 / 繁中别名 四字段 OR
  ///
  /// （2026-10-05 实测：仅 title 过滤时搜日文原名「美少女万華鏡」0 命中、
  /// 英文名「Mangekyou」0 命中；多字段 OR 均 7 命中。别名检索是 CT 源
  /// 在一键抓取里可用的前提——用户输入的往往是别名或部分名称。）
  String? _nameSearchFilter(String keyword) {
    final safe = _escapePbLiteral(keyword);
    if (safe == null) return null;
    return "(title ~ '$safe' || originalTitle ~ '$safe' || "
        "englishTitle ~ '$safe' || traditionalChineseTitle ~ '$safe')";
  }

  /// 搜索文本归一化（public static，供 CT 探索库弹窗本地搜索共用）：
  /// 小写化 → 全角 ASCII/全角空格转半角 → 去除空白与中英文常见标点。
  ///
  /// 目的：用户输入「美少女万華鏡１」「Bishoujo Mangekyou - Norowareshi…」
  /// 等大小写/全半角/标点变体时仍能命中同一部作品（对齐 VNDB/Nextcloud
  /// 的宽松索引体验）。
  ///
  /// ★ 2026-10-10：噪声集合补入「*＊×✕✖☆★♪♫※|｜」等装饰/分隔符号。
  /// 此前未剥离 `*`，导致「突然＊恋人」归一化仍含 `*`，与分词召回
  /// （[_queryTokens] 剥离全部非词字符）口径不一致 → 精度闸误杀，是
  /// 「探索页搜得到、抓取搜不到」的最后一环。
  static String normalizeForSearch(String input) {
    var s = _foldFullWidth(input).toLowerCase();
    // 去空白与常见标点（raw 三引号内含单个引号合法；注意不能出现三连引号）
    return s.replaceAll(_searchNoise, '');
  }

  /// 归一化时剔除的噪声字符：空白 + 中英文常见标点 + 装饰/分隔符号
  static final RegExp _searchNoise = RegExp(
      r"""[\s\-_~·・:：;；,，.。!！?？()（）\[\]【】「」『』"'“”‘’，、*＊×✕✖☆★♪♫※|｜]""");

  /// 仅供单元测试离线验证 filter 生成（不发起网络请求）
  @visibleForTesting
  String? nameSearchFilterForTesting(String keyword) =>
      _nameSearchFilter(keyword);

  /// 仅供单元测试离线验证分词（不发起网络请求）
  @visibleForTesting
  static List<String> queryTokensForTesting(String keyword) =>
      _queryTokens(keyword);

  /// 仅供单元测试离线验证最佳匹配挑选 / 精度闸（不发起网络请求）
  @visibleForTesting
  Map<String, dynamic>? pickBestMatchForTesting(
          List<dynamic> results, String query) =>
      _pickBestMatch(results, query);

  /// 从搜索结果中挑选与查询词最匹配的项（★ 2026-10-10 加精度闸）
  ///
  /// 候选名称集合：title + originalTitle + englishTitle +
  /// traditionalChineseTitle（全部别名参与匹配），打分规则与其他源一致
  /// （精确 100 / 前缀 40 / 包含 20）。匹配统一走 [normalizeForSearch]
  /// （全半角/标点/大小写归一）。
  ///
  /// **精度闸**（修复「搜不到 → 全 0 分回退第一条」的张冠李戴）：
  /// - 查询分词后，候选必须**包含全部关键词段**（归一化后 AND 门）才入选；
  /// - 例外：候选某名称与查询**完全相等**（精确命中）时直接采用；
  /// - 无任何候选过闸 → 返回 null（调用方给空结果），不回退第一条。
  Map<String, dynamic>? _pickBestMatch(List<dynamic> results, String query) {
    final candidates = <Map<String, dynamic>>[];
    for (final r in results) {
      if (r is Map) candidates.add(Map<String, dynamic>.from(r));
    }
    if (candidates.isEmpty) return null;

    final queryNorm = normalizeForSearch(query);
    final tokens = _queryTokens(query);

    Map<String, dynamic>? bestResult;
    int bestScore = 0; // 0 = 不合格

    for (final item in candidates) {
      final names = <String>{
        for (final key in [
          'title',
          'originalTitle',
          'englishTitle',
          'traditionalChineseTitle'
        ])
          if ((safeString(item, key) ?? '').isNotEmpty) safeString(item, key)!,
      };
      final normNames = <String>[
        for (final n in names) normalizeForSearch(n),
      ].where((s) => s.isNotEmpty).toList();

      int nameBest = 0;
      for (final nn in normNames) {
        int score = 0;
        if (queryNorm.isNotEmpty && nn == queryNorm) {
          score = 100;
        } else if (queryNorm.isNotEmpty && nn.startsWith(queryNorm)) {
          score = 40;
        } else if (queryNorm.isNotEmpty &&
            (nn.contains(queryNorm) || queryNorm.contains(nn))) {
          score = 20;
        }
        if (score > nameBest) nameBest = score;
      }

      // 精度闸：精确命中直接采用；否则要求全部关键词段命中（AND 门）
      int score;
      if (nameBest >= 100) {
        score = nameBest;
      } else if (tokens.isEmpty) {
        score = nameBest;
      } else {
        var covered = 0;
        for (final t in tokens) {
          if (normNames.any((nn) => nn.contains(t))) covered++;
        }
        score = (covered == tokens.length) ? (nameBest > 0 ? nameBest : 20) : 0;
      }

      if (score > bestScore) {
        bestScore = score;
        bestResult = item;
      }
    }
    return bestResult;
  }

  /// 仅供单元测试离线验证（对齐 NextMoeService.parseDetailForTesting）
  @visibleForTesting
  MetadataResult parseRecordForTesting(Map<String, dynamic> json) =>
      _parseRecord(json);

  MetadataResult _parseRecord(Map<String, dynamic> json) {
    final id = safeString(json, 'id') ?? '';
    final name = safeString(json, 'title') ?? '';
    if (id.isEmpty || name.isEmpty) return _emptyResult();

    // 副标题：日文原版标题（上游 selectScrapeResult 经 CJK 检查后填入）
    final originalTitle = _nonEmpty(safeString(json, 'originalTitle'));

    // ★ 2026-10-10 全部别名汇总（除主标题外的其他名称：日文原名 / 英文名 /
    //   繁中名），供上游「副标题 = 全部别名」语义使用。去重、剔除与主标题
    //   相同者、按 日文→英文→繁中 顺序保序；无别名时为 null。
    final aliasNames = _collectAliasNames(json, name);

    final coverUrl = _fileUrl(id, safeString(json, 'cover')) ??
        _fileUrl(id, safeString(json, 'coverUrl')) ??
        '';
    final bannerUrl = _fileUrl(id, safeString(json, 'bannerUrl')) ?? '';

    // 会社：兼容 PB 字段命名变更（developer → Developer，与 GameModel 同策略）
    final developer =
        _nonEmpty(safeString(json, 'developer') ?? safeString(json, 'Developer'));

    // 评分：云端沉淀值约定 0-10 分制（normalizeRating 对 <=10 原样放行，
    // 仅对异常 100 分制兜底归一）
    final rating = normalizeRating(safeDouble(json, 'rating') ?? 0.0);

    return MetadataResult(
      game: Game(
        id: id,
        name: name,
        originalTitle: originalTitle,
        aliasNames: aliasNames,
        coverUrl: coverUrl,
        bannerUrl: bannerUrl,
        company: developer,
        summary: safeString(json, 'description') ?? '',
        rating: rating,
        voteCount: safeInt(json, 'voteCount'),
        releaseDate: safeString(json, 'releaseDate') ?? '',
        sourceType: SourceType.ct,
        sourceId: id,
        screenshotUrls: _extractScreenshots(id, json),
      ),
      tags: [
        // 社区整理的中文标签，直通不走 TagTranslator
        for (final tagName in _parseTagNames(json))
          TagItem(name: tagName, source: 'ct', weight: 1.0),
      ],
    );
  }

  /// 汇总「除主标题外的全部别名」（日文原名 / 英文名 / 繁中名）。
  ///
  /// 去重（归一化比较）、剔除与主标题相同者、按 日文→英文→繁中 顺序保序；
  /// 无别名时返回 null（上游回退 [Game.originalTitle]）。
  static List<String>? _collectAliasNames(
      Map<String, dynamic> json, String mainTitle) {
    final mainNorm = normalizeForSearch(mainTitle);
    final seen = <String>{};
    final out = <String>[];
    for (final key in [
      'originalTitle',
      'englishTitle',
      'traditionalChineseTitle',
    ]) {
      final value = (safeString(json, key) ?? '').trim();
      if (value.isEmpty) continue;
      final norm = normalizeForSearch(value);
      if (norm.isEmpty || norm == mainNorm) continue;
      if (seen.add(norm)) out.add(value);
    }
    return out.isEmpty ? null : out;
  }

  /// tags 字段解析：PB select 多选返回 List；旧数据可能是逗号分隔字符串
  static List<String> _parseTagNames(Map<String, dynamic> json) {
    final raw = json['tags'];
    if (raw is List) {
      return raw.map((t) => t.toString().trim()).where((t) => t.isNotEmpty).toList();
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
    }
    return const [];
  }

  /// PB 文件字段 → 完整 URL（file 字段存文件名，裸值为空串 = 无文件）
  static String? _fileUrl(String recordId, String? filename) {
    if (filename == null || filename.isEmpty) return null;
    return '$apiBase/api/files/games/$recordId/$filename';
  }

  /// screenshots 多文件字段 → URL 列表（保留云端整理的全部截图，不设上限）
  static List<String>? _extractScreenshots(String recordId, Map<String, dynamic> json) {
    final raw = json['screenshots'];
    if (raw is! List || raw.isEmpty) return null;
    final urls = <String>[];
    for (final item in raw) {
      final url = _fileUrl(recordId, item?.toString());
      if (url != null) urls.add(url);
    }
    return urls.isEmpty ? null : urls;
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  MetadataResult _emptyResult() {
    return MetadataResult(game: Game(id: '', name: '', sourceType: SourceType.ct));
  }
}
