/// 标题 → NextMoe `catalog` work id 的匹配算法（纯 Dart，无网络、无 Flutter）。
///
/// 为什么单独拆：这段逻辑决定"补丁查得准不准"，是最该被离线反复验证的部分。
/// 网络那段（[PatchIdentityResolver]）只是把 JSON 喂进来。
///
/// ## 背景（2026-11-10 实测）
///
/// `GET /v2/catalog/search?object=work&q=<标题>&nsfw=true` 直接返回候选作品，
/// `items[].id` 就是 `refs=catalog:<id>` 要的那个 id。探索库 24 条真实标题
/// 实测解析率 100%、其中有补丁 92%。
///
/// ⚠️ **但"解析到了"不等于"解析对了"**：同系列作品（Vol.1 / Vol.2、
/// 原作 / 重制版）会串味。所以本算法输出**置信度**，UI 可以把
/// "匹配到：XXX" 显示出来让用户自己判断，而不是假装精确。
library;

/// 匹配结果。
class PatchWorkMatch {
  /// NextMoe `catalog` work id；null = 没匹配到
  final int? workId;

  /// 命中的作品显示名（用于 UI 提示"匹配到：XXX"）
  final String matchedTitle;

  /// 置信度：1.0 归一化后完全相等；0.8 一方包含另一方；0.5 仅取首条；0 = 无
  final double confidence;

  const PatchWorkMatch({
    this.workId,
    this.matchedTitle = '',
    this.confidence = 0,
  });

  static const PatchWorkMatch none = PatchWorkMatch();

  bool get found => workId != null;

  /// 是否可以当"精确命中"对待（≥0.8）
  bool get isConfident => confidence >= 0.8;
}

/// 标题归一化：用于宽松比较。
///
/// 只做**不会引入歧义**的处理，⛔ 不要在这里删除"Vol.2 / 重制版"这类
/// 区分性后缀 —— 那恰恰是区分同系列作品的关键信息。
String normalizePatchTitle(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return '';

  final buf = StringBuffer();
  for (final rune in s.runes) {
    // 全角 → 半角（ASCII 可见区 + 全角空格）
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buf.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buf.writeCharCode(0x20);
    } else {
      buf.writeCharCode(rune);
    }
  }
  s = buf.toString();

  // 折叠空白，去掉常见包裹符号
  s = s.replaceAll(RegExp(r'[\s\u00a0]+'), ' ');
  s = s.replaceAll(RegExp(r'''[「」『』【】\[\]（）()~〜～]'''), '');
  return s.trim();
}

/// 从 `/v2/catalog/search` 的响应里挑出最可能的 work。
///
/// [candidates] 按优先级给（主标题 → 日文原名 → 英文名），逐个尝试。
/// [items] 是响应里的 `items[]` 原始 JSON 列表。
///
/// 策略（**宁可选错也要给出置信度**，让上层能提示）：
/// 1. 归一化后完全相等 → 1.0
/// 2. 一方包含另一方且短串长度 ≥ 长串 60% → 0.8（防"千恋"匹配"千恋万花"这种过度泛化）
/// 3. 都不满足 → 取首条，置信度 0.5
/// 4. 无候选 / 无 items → [PatchWorkMatch.none]
PatchWorkMatch pickWorkMatch(
  List<Map<String, dynamic>> items,
  List<String> candidates,
) {
  if (items.isEmpty) return PatchWorkMatch.none;

  final normCandidates = <String>[];
  for (final c in candidates) {
    final n = normalizePatchTitle(c);
    if (n.isNotEmpty && !normCandidates.contains(n)) normCandidates.add(n);
  }
  if (normCandidates.isEmpty) return _firstAsWeakMatch(items);

  // 先严格：完全相等
  for (final cand in normCandidates) {
    for (final item in items) {
      final id = _idOf(item);
      if (id == null) continue;
      final title = displayNameOf(item);
      if (normalizePatchTitle(title) == cand) {
        return PatchWorkMatch(
          workId: id,
          matchedTitle: title,
          confidence: 1.0,
        );
      }
      // 也检查 localized 的各语言名（中文名可能与 display_name 不同）
      for (final alt in localizedNamesOf(item)) {
        if (normalizePatchTitle(alt) == cand) {
          return PatchWorkMatch(
            workId: id,
            matchedTitle: title.isEmpty ? alt : title,
            confidence: 1.0,
          );
        }
      }
    }
  }

  // 再宽松：包含关系
  for (final cand in normCandidates) {
    for (final item in items) {
      final id = _idOf(item);
      if (id == null) continue;
      final title = displayNameOf(item);
      final names = <String>[
        if (title.trim().isNotEmpty) title,
        ...localizedNamesOf(item),
      ];
      for (final n in names) {
        final norm = normalizePatchTitle(n);
        if (norm.isEmpty) continue;
        final shorter = cand.length <= norm.length ? cand : norm;
        final longer = cand.length <= norm.length ? norm : cand;
        if (shorter.length < 4) continue; // 太短的串不做包含匹配
        if (longer.contains(shorter) &&
            shorter.length >= (longer.length * 0.6)) {
          return PatchWorkMatch(
            workId: id,
            matchedTitle: title.isEmpty ? n : title,
            confidence: 0.8,
          );
        }
      }
    }
  }

  return _firstAsWeakMatch(items);
}

PatchWorkMatch _firstAsWeakMatch(List<Map<String, dynamic>> items) {
  for (final item in items) {
    final id = _idOf(item);
    if (id == null) continue;
    return PatchWorkMatch(
      workId: id,
      matchedTitle: displayNameOf(item),
      confidence: 0.5,
    );
  }
  return PatchWorkMatch.none;
}

int? _idOf(Map<String, dynamic> item) {
  final raw = item['id'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  final s = raw?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  return int.tryParse(s);
}

/// v2 的作品显示名
String displayNameOf(Map<String, dynamic> item) {
  final d = item['display_name'];
  if (d is String && d.trim().isNotEmpty) return d.trim();
  // 退回落 localized 的第一个值
  final names = localizedNamesOf(item);
  return names.isEmpty ? '' : names.first;
}

/// `localized` 可能是 `{"zh-Hans": {"value": "..."}}` 或 `{"zh-Hans": "..."}`
List<String> localizedNamesOf(Map<String, dynamic> item) {
  final loc = item['localized'];
  if (loc is! Map) return const <String>[];
  final out = <String>[];
  for (final v in loc.values) {
    if (v is String && v.trim().isNotEmpty) {
      out.add(v.trim());
    } else if (v is Map) {
      final inner = v['value'];
      if (inner is String && inner.trim().isNotEmpty) out.add(inner.trim());
    }
  }
  return out;
}

// ==================== 身份解析的作用域与采信门槛 ====================
//
// 这两个函数是**纯的**（无网络 / 无 io），所以裸 Dart 的
// `dev_probe/patch_station_probe.dart` 能直接断言它们 —— 这正是当初出 bug
// 的地方：逻辑本身不难，难的是没人验证「关键词检索到底有没有去解析」。

/// 身份解析用哪个 key 做缓存 / 并发合并。
///
/// - 有 PB `gameId`（锁定到某部作品）→ 直接用 `gameId`，它是权威锚点；
/// - 没有 `gameId`（探索库顶栏的全局关键词检索）→ 退化成 `kw:<归一化关键词>`。
///
/// 🔴 **空串 = 这次别解析**。以前调用方的门禁是 `(gameId ?? '').isNotEmpty`，
/// 于是全局检索这一步被整段跳过；而鲲的能力表是 `byKeyword: false`
/// （NextMoe 没有补丁名检索，只能 `refs=catalog:<id>` 锚定）⇒ 鲲**一次都不会
/// 被请求**，用户看到的就是「全局搜几乎搜不到鲲的补丁」。
String patchIdentityCacheKey({
  required String? gameId,
  required String keyword,
}) {
  final g = (gameId ?? '').trim();
  if (g.isNotEmpty) return g;
  final k = normalizePatchTitle(keyword);
  return k.isEmpty ? '' : 'kw:$k';
}

/// 关键词检索（没有 `gameId` 当权威锚点）时，是否采信解析结果。
///
/// 🔴 必须 [PatchWorkMatch.isConfident]（≥0.8）：没有 gameId 时唯一的依据是
/// 标题相似度，`pickWorkMatch` 在完全对不上时会退化成「取首条 + 置信度 0.5」，
/// 那种结果拿去查鲲就是把别人的补丁串进来。宁可少给，也不串味。
bool acceptKeywordWorkMatch(PatchWorkMatch match) =>
    match.found && match.isConfident;

