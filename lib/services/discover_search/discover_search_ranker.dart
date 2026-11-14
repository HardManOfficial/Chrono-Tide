import '../../models/game_model.dart';

/// 库内搜索的相关性打分与重排（DISCOVER-SEARCH-RANKER）
///
/// 为什么需要它：探索库的 `defaultOrder` 是**不排序**，直接沿用 PB 的
/// `-created` 顺序（最新录入在前）。于是搜「AIR」时，标题就叫 AIR 的作品
/// 因为录入早被挤到最后一页，第一屏全是最新录入的 `fairy` / `amairo` /
/// `pairing` 这类英文名裸子串命中（2026-11-13 用 562 条真实库数据实测）。
///
/// 🔴 只做**排序**，不做过滤：所有命中的作品都会保留，弱命中垫底即可。
/// 收窄召回会丢掉「只记得英文名一部分」这类合法搜索。
///
/// 🔴 与 `services/site_search/site_search_ranker.dart` 是两套独立口径：
/// 那个打站外 `SiteSearchHit`（还要考虑跨源混排与 Top1 兜底），
/// 这个打库内 `GameModel`。⛔ 不要合并。
class DiscoverSearchRanker {
  const DiscoverSearchRanker._();

  // ==================== 分数表 ====================

  /// 字段基准分：标题 > 日文原名 > 英文名 > 会社 > 标签
  static const int _wTitle = 1000;
  static const int _wOriginal = 800;
  static const int _wEnglish = 700;
  static const int _wDeveloper = 420;
  static const int _wTag = 300;

  /// 匹配质量加成（真命中）
  static const int _qExact = 400;
  static const int _qPrefix = 300;
  static const int _qWordOrSubstr = 200;

  /// 弱命中（裸子串，如 `fairy` → `air`、`pairing` → `air`）
  ///
  /// 🔴 一律压到**任何真命中之下**（真命中最低 = 标签词边界 500），
  /// 用户 2026-11-13 拍板「保留但不许排前面」。字段间仍保留微小差异，
  /// 让同为弱命中时的次序稳定可读。
  static const int _wWeakTitle = 60;
  static const int _wWeakOriginal = 55;
  static const int _wWeakEnglish = 50;
  static const int _wWeakDeveloper = 45;
  static const int _wWeakTag = 40;

  /// 不命中
  static const int noMatch = -1;

  // ==================== 对外 ====================

  /// 单条作品对一组关键词的相关性分数（越高越靠前；[noMatch] = 不命中）
  ///
  /// 多关键词是 AND 语义（与页面过滤一致）：取**最弱**那个关键词的分数，
  /// 即「有一个词只是弱命中，整条就进弱命中档」。
  ///
  /// [developerHaystack] 传入会社别名的拼接文本（页面已有缓存版本，
  /// 支持「精灵社 / 雪碧社 → sprite」这类昵称命中）；不传则只看原文。
  static int score(
    GameModel game,
    List<String> keywords, {
    String Function(GameModel game)? developerHaystack,
  }) {
    if (keywords.isEmpty) return 0;

    final haystack = developerHaystack?.call(game) ?? game.developer;
    var weakest = 1 << 30;

    for (final raw in keywords) {
      final kw = _stripAll(raw);
      if (kw.isEmpty) continue;

      var best = noMatch;

      void consider(String rawText, int weight, int weakWeight) {
        final level = _levelOf(rawText, kw);
        if (level == _Level.none) return;
        final s = level == _Level.loose
            ? weakWeight
            : weight + _qualityBonus(level);
        if (s > best) best = s;
      }

      consider(game.title, _wTitle, _wWeakTitle);
      consider(game.originalTitle, _wOriginal, _wWeakOriginal);
      consider(game.englishTitle, _wEnglish, _wWeakEnglish);
      consider(haystack, _wDeveloper, _wWeakDeveloper);
      for (final tag in game.tags) {
        consider(tag, _wTag, _wWeakTag);
      }

      if (best == noMatch) return noMatch;
      if (best < weakest) weakest = best;
    }

    return weakest == (1 << 30) ? 0 : weakest;
  }

  /// 按相关性重排（**稳定**：同分保持传入顺序）
  ///
  /// 调用方通常在「用户选择的排序」之后调用本方法：用户选的排序决定
  /// 同档次序，相关性永远压在最前面（用户 2026-11-13 拍板）。
  ///
  /// 🔴 Dart 的 `List.sort` **不稳定**，同分必须用原始下标兜底，
  /// 否则同为 50 分的噪音会每帧乱跳，用户以为列表在抽搐。
  static List<GameModel> rank(
    List<GameModel> input,
    List<String> keywords, {
    String Function(GameModel game)? developerHaystack,
  }) {
    if (keywords.isEmpty || input.length < 2) return input;

    final scored = <_Scored>[];
    for (var i = 0; i < input.length; i++) {
      scored.add(_Scored(
        game: input[i],
        score: score(input[i], keywords, developerHaystack: developerHaystack),
        index: i,
      ));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.index.compareTo(b.index);
    });
    return [for (final s in scored) s.game];
  }

  // ==================== 匹配质量 ====================

  static int _qualityBonus(_Level level) {
    switch (level) {
      case _Level.exact:
        return _qExact;
      case _Level.prefix:
        return _qPrefix;
      case _Level.wordOrSubstr:
        return _qWordOrSubstr;
      case _Level.loose:
      case _Level.none:
        return 0;
    }
  }

  /// 原始字段文本 [rawText] 与（已归一化的）关键词 [kw] 的匹配质量
  ///
  /// 🔴 **两套文本各司其职**：
  /// - `exact / prefix / CJK 子串` 用**去标点**后的文本（搜 `triplepairing`
  ///   也能命中 `Triple Pairing`）；
  /// - 拉丁词边界用**保留空格标点**的小写原文——去标点会把
  ///   `ef - a fairy tale` 压成 `efafairytale`，`\bair\b` 就永远不成立了
  ///   （2026-11-13 探针抓到的真 bug）。
  static _Level _levelOf(String rawText, String kw) {
    if (rawText.isEmpty || kw.isEmpty) return _Level.none;
    final hay = _stripAll(rawText);
    if (hay.isEmpty) return _Level.none;
    if (hay == kw) return _Level.exact;
    if (hay.startsWith(kw)) return _Level.prefix;
    if (_hasCjk(kw)) {
      return hay.contains(kw) ? _Level.wordOrSubstr : _Level.none;
    }
    final raw = rawText.toLowerCase();
    if (RegExp('\\b${RegExp.escape(kw)}\\b').hasMatch(raw)) {
      return _Level.wordOrSubstr;
    }
    // 中英混排：`三角圆舞曲 -Triple Pairing-` 去标点后紧挨着中文，
    // 在 stripped 串里前后都是 CJK（或串首尾）⇒ 原始边界本来就是非拉丁字符，
    // 算真命中；而 `fairy` 里的 `air` 前后都是拉丁字母 ⇒ 仍是弱命中。
    final idx = hay.indexOf(kw);
    if (idx >= 0) {
      final beforeOk = idx == 0 || _hasCjk(hay[idx - 1]);
      final afterIdx = idx + kw.length;
      final afterOk = afterIdx >= hay.length || _hasCjk(hay[afterIdx]);
      if (beforeOk && afterOk) return _Level.wordOrSubstr;
    }
    return hay.contains(kw) ? _Level.loose : _Level.none;
  }

  static bool _hasCjk(String s) {
    for (final rune in s.runes) {
      final isHan = rune >= 0x4E00 && rune <= 0x9FFF;
      final isKana = rune >= 0x3040 && rune <= 0x30FF;
      final isHalfKana = rune >= 0xFF66 && rune <= 0xFF9F;
      if (isHan || isKana || isHalfKana) return true;
    }
    return false;
  }

  /// 去掉空白与常见标点并小写（只用于**匹配**，不要拿它做去重）
  ///
  /// 例：`三角圆舞曲 -Triple Pairing-` → `三角圆舞曲triplepairing`，
  /// 这样搜「三角圆舞曲」「Triple Pairing」「triplepairing」都能命中标题。
  static String _stripAll(String raw) {
    if (raw.isEmpty) return raw;
    return raw
        .toLowerCase()
        .replaceAll(_punctuation, '')
        .trim();
  }

  static final RegExp _punctuation = RegExp(
    r'[\s\u3000「」『』()（）\[\]【】{}<>《》:：;；·・,，.。!！?？~～\-—_/\\|｜*＊'
    r'"' "'" r'’“”‘’+＋=&％%※♪★☆]',
  );
}

/// 匹配质量档
enum _Level { none, loose, wordOrSubstr, prefix, exact }

/// 排序中间态（带原始下标，保证稳定排序）
class _Scored {
  const _Scored({
    required this.game,
    required this.score,
    required this.index,
  });

  final GameModel game;
  final int score;
  final int index;
}
