import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

/// 全站搜索的**标题相关性打分与重排**。
///
/// ## 为什么必须在客户端做
///
/// 两个站点接口都没有「只搜标题」的能力（2026-11-11 实测）：
/// - 鲲 `/catalog/search?q=` 会把关键词**拆成单字**匹配，所以「缘之空」会命中
///   一大批「X之Y」——终之空 / 悠之缘 / 夏之空 / 卵之键 / 时之带；
/// - 2DFan `/search?keyword=` 是全站全文检索（搜索框占位符写着「搜索游戏、资源、
///   攻略…」），连**罗马字读音**都参与匹配：`なないろ`→nanairo 含 "iro"、
///   `FairlyLife` 含 "air"，搜 AIR 时连 CLANNAD 都被排到第 5 位。
///
/// 站点侧既没有字段限定参数，也不返回相关度分数，只能在拿到结果后自己判。
///
/// ## 打分口径
///
/// 对每条命中，取 [SiteSearchHit.title] / [SiteSearchHit.originalTitle] /
/// [SiteSearchHit.aliasNames] 三者中**最高**的一档：
///
/// | 档位 | 条件 | 分 |
/// |---|---|---|
/// | 完全相等 | 归一化后与关键词一字不差 | 100 |
/// | 前缀 | 标题以关键词开头 | 85 |
/// | 词边界包含 | 关键词作为独立词/子串出现 | 70 |
/// | 不匹配 | 拉丁关键词落在某个词中间 | 0（丢弃） |
///
/// 🔴 **拉丁关键词必须带词边界**：否则 `FairlyLife` / `FairChild` / `airy` 都会
/// 因为含 `air` 而冒充 AIR 的搜索结果。CJK 没有词边界概念，用子串即可
/// （`AIRメイド` 仍然算命中，因为 `AIR` 后面是假名，不是拉丁字母）。
///
/// ## 每源 Top1 兜底
///
/// 站点标题语言与用户输入语言**天然不对齐**：鲲的卡片标题是中文（缘之空 /
/// 鸟之诗），2DFan 的卡片标题是日文原名（ヨスガノソラ）。用户用中文搜
/// 「缘之空」时，2DFan 那条正确结果的标题里一个汉字都对不上，纯过滤会把它
/// 整条误杀。因此：**某个源一条都没命中时，保留它原始排序的第 1 条**——
/// 站点自己的相关度第一名，通常就是正确答案。兜底项固定为最低分
/// ([kScoreTop1Fallback])，永远排在真命中之后。
class SiteSearchRanker {
  SiteSearchRanker._();

  /// 归一化后与关键词一字不差
  static const int kScoreExact = 100;

  /// 标题以关键词开头
  static const int kScorePrefix = 85;

  /// 关键词作为词（拉丁）或子串（CJK）出现在标题里
  static const int kScoreContains = 70;

  /// 某源一条都没命中时，兜底保留的原始第 1 名。
  ///
  /// 只要求 > 0（能活过「score == 0 丢弃」这道闸），且小到永远排在真命中后面。
  static const int kScoreTop1Fallback = 1;

  /// 打一条命中的分（取三个候选标题里的最高档）
  ///
  /// 供单元测试直接调用，不参与排序决策。
  static int scoreHit(SiteSearchHit hit, String keyword) =>
      _scoreHit(hit, _Key.parse(keyword));

  /// 打一个标题串的分。
  ///
  /// 与 [scoreHit] 的区别：只看这一个串，不看别名。
  static int scoreTitle(String candidate, String keyword) =>
      _scoreTitle(candidate, _Key.parse(keyword));

  /// 对「每个源各自的结果」做过滤 + 跨源混排。
  ///
  /// [perSource] 顺序即优先级（鲲 → 2DFan）：分数相同的条目按这个顺序、
  /// 再按源内原始序号向前排，保证同一关键词每次的结果顺序稳定。
  static SiteSearchRankResult rank(
    List<SiteSearchSourceResult> perSource,
    String keyword,
  ) {
    final key = _Key.parse(keyword);
    var candidateCount = 0;

    // 关键词为空（理论上调用方已拦掉）：原样拼接，不过滤不排序
    if (key.norm.isEmpty) {
      final all = <SiteSearchHit>[
        for (final r in perSource) ...r.hits,
      ];
      return SiteSearchRankResult(hits: all, candidateCount: all.length);
    }

    final scored = <_Scored>[];

    for (var srcIndex = 0; srcIndex < perSource.length; srcIndex++) {
      final result = perSource[srcIndex];
      candidateCount += result.hits.length;
      if (result.hits.isEmpty) continue;

      var anyMatched = false;
      for (var i = 0; i < result.hits.length; i++) {
        final hit = result.hits[i];
        final score = _scoreHit(hit, key);
        if (score > 0) anyMatched = true;
        scored.add(_Scored(hit, score, srcIndex, i));
      }

      // 该源一条都没命中 → 兜底保留原始第 1 条（见类文档「每源 Top1 兜底」）
      if (!anyMatched) {
        scored.add(_Scored(result.hits.first, kScoreTop1Fallback, srcIndex, 0));
      }
    }

    scored.sort((a, b) {
      if (a.score != b.score) return b.score.compareTo(a.score);
      if (a.sourceIndex != b.sourceIndex) {
        return a.sourceIndex.compareTo(b.sourceIndex);
      }
      return a.originIndex.compareTo(b.originIndex);
    });

    return SiteSearchRankResult(
      hits: [
        for (final s in scored)
          if (s.score > 0) s.hit,
      ],
      candidateCount: candidateCount,
    );
  }

  // ==================== 内部实现 ====================

  /// 一条命中的最高档：主标题 / 原版标题 / 别名里谁最贴就用谁。
  ///
  /// 🔴 别名必须一起比：鲲把中文名放 `title`、日文原名放 `originalTitle`，
  /// 用户搜任何一个都该算命中（搜「鸟之诗」和搜「AIR」都要能检索到那部作品）。
  static int _scoreHit(SiteSearchHit hit, _Key key) {
    var best = _scoreTitle(hit.title, key);

    final original = hit.originalTitle;
    if (original != null && original.isNotEmpty) {
      final s = _scoreTitle(original, key);
      if (s > best) best = s;
    }

    for (final alias in hit.aliasNames) {
      if (alias.isEmpty) continue;
      final s = _scoreTitle(alias, key);
      if (s > best) best = s;
    }

    return best;
  }

  static int _scoreTitle(String candidate, _Key key) {
    if (candidate.isEmpty || key.norm.isEmpty) return 0;

    final raw = _toRaw(candidate);
    if (raw.isEmpty) return 0;
    final norm = _stripAll(raw);
    if (norm.isEmpty) return 0;

    // 1) 完全相等
    if (norm == key.norm) return kScoreExact;

    // 2) 前缀
    if (key.isLatin) {
      if (_latinAtWordStart(raw, key.raw)) return kScorePrefix;
    } else if (norm.startsWith(key.norm)) {
      return kScorePrefix;
    }

    // 3) 包含
    if (key.isLatin) {
      // 🔴 拉丁关键词只认词边界：`FairlyLife` 里的 air 不算命中
      return _latinAsWord(raw, key.raw) ? kScoreContains : 0;
    }
    return norm.contains(key.norm) ? kScoreContains : 0;
  }

  /// 候选串是否**以** [kwRaw] 开头，且紧随其后不是拉丁字母/数字。
  ///
  /// `AIR` → `AIR`（等长）✅ / `AIRメイド` ✅ / `AIR WING` ✅ / `airy` ❌
  static bool _latinAtWordStart(String raw, String kwRaw) {
    if (!raw.startsWith(kwRaw)) return false;
    if (raw.length == kwRaw.length) return true;
    return !_isLatinOrDigit(raw.codeUnitAt(kwRaw.length));
  }

  /// [kwRaw] 是否作为**独立词**出现在候选串里（前后都不是拉丁字母/数字）。
  ///
  /// 用 `\b`：Dart 的 `\b` 是 ASCII 词边界，所以 `AIRメイド` 里 `R`→`メ`
  /// 也算边界（假名不是 word char），符合「AIR 系列」的实际命名习惯。
  static bool _latinAsWord(String raw, String kwRaw) {
    final re = RegExp(
      '\\b${RegExp.escape(kwRaw)}\\b',
      caseSensitive: false,
    );
    return re.hasMatch(raw);
  }

  static bool _isLatinOrDigit(int codeUnit) =>
      (codeUnit >= 0x30 && codeUnit <= 0x39) || // 0-9
      (codeUnit >= 0x61 && codeUnit <= 0x7A) || // a-z
      (codeUnit >= 0x41 && codeUnit <= 0x5A); // A-Z

  /// 全角 → 半角 + 小写 + 折叠空白（**保留空格**，词边界要靠它）
  static String _toRaw(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      var c = r;
      if (c >= 0xFF01 && c <= 0xFF5E) {
        c -= 0xFEE0; // ！～ → !~
      } else if (c == 0x3000) {
        c = 0x20; // 全角空格
      }
      buf.writeCharCode(c);
    }
    return buf.toString().toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 去掉空白与常见标点（用于「一字不差」与 CJK 子串判定）
  ///
  /// ⚠️ 只用于**匹配**，不要拿它做去重——去重有 `discover_page._normalizeTitle`，
  /// 两套口径混用会让同一部作品在一处被判重复、在另一处又没被判。
  static final RegExp _kSeparators = RegExp(
    r'[\s\u3000「」『』()（）\[\]【】{}<>:：;；·・,，.。!！?？~～\-—_/\\|｜*＊+＋=&%％]',
  );

  static String _stripAll(String raw) => raw.replaceAll(_kSeparators, '');
}

/// 关键词的两种形态 + 是否拉丁。
class _Key {
  /// 保留空格的小写形态（喂 `\b` 正则）
  final String raw;

  /// 去空白去标点（喂「相等 / 前缀 / 子串」判定）
  final String norm;

  /// 是否纯拉丁（字母 + 数字 + 空格）——决定要不要启用词边界
  final bool isLatin;

  const _Key(this.raw, this.norm, this.isLatin);

  factory _Key.parse(String keyword) {
    final raw = SiteSearchRanker._toRaw(keyword);
    final norm = SiteSearchRanker._stripAll(raw);
    final isLatin =
        norm.isNotEmpty && RegExp(r'^[a-z0-9 ]+$').hasMatch(norm);
    return _Key(raw, norm, isLatin);
  }
}

class _Scored {
  final SiteSearchHit hit;
  final int score;

  /// 源序号（鲲 0、2DFan 1）——同分时保证跨源顺序稳定
  final int sourceIndex;

  /// 源内原始序号——同分时保留站点自己的相关度顺序
  final int originIndex;

  const _Scored(this.hit, this.score, this.sourceIndex, this.originIndex);
}

/// [SiteSearchRanker.rank] 的产物。
class SiteSearchRankResult {
  /// 过滤 + 排序后的命中（跨源混排）
  final List<SiteSearchHit> hits;

  /// 过滤前的候选总数（概览条用它算「已滤除 N 条标题不匹配」）
  final int candidateCount;

  const SiteSearchRankResult({
    required this.hits,
    required this.candidateCount,
  });

  /// 被标题匹配筛掉的条数
  int get filteredCount => candidateCount - hits.length;
}
