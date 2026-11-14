import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

/// 「副标题 = 除主标题外的全部别名」合成工具（2026-10-10）。
///
/// 副标题语义扩展：不再只是日文原名，而是**除主标题外的所有其他名称**
/// （日文原名 / 英文名 / 繁中名等），以 ` / ` 连接、去重、剔除与主标题
/// 相同者。三条导入链路（添加页一键抓取 / CT 探索库选择 / 批量与智能导入）
/// 共用本工具，保证口径完全一致。
///
/// 数据来源字段（legacy 抓取结果 map，见 MetadataFetcher._convertToLegacyFormat
/// 与 JoinController.importFromCtLibrary）：
/// - `alias_names`：结构化多别名 List<String>（CT 源提供；其他源为空）；
/// - `original_title`：老字段，单个别名（回退用）。
class SubtitleComposer {
  SubtitleComposer._();

  /// 多别名连接符
  static const String separator = ' / ';

  /// 从 legacy 抓取结果 map 提取别名列表（保序、去空、未去重）。
  ///
  /// 优先 `alias_names`（List，结构化多别名）；缺失/为空时回退
  /// `original_title`（单个别名）。两者皆空 → 返回空列表。
  static List<String> aliasesFromResult(Map<String, dynamic> result) {
    final raw = result['alias_names'];
    if (raw is List) {
      final list = <String>[];
      for (final e in raw) {
        final s = e?.toString().trim() ?? '';
        if (s.isNotEmpty) list.add(s);
      }
      if (list.isNotEmpty) return list;
    } else if (raw is String && raw.trim().isNotEmpty) {
      final list = raw
          .split(RegExp(r'[/／]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (list.isNotEmpty) return list;
    }
    final legacy = result['original_title']?.toString().trim() ?? '';
    return legacy.isEmpty ? const <String>[] : <String>[legacy];
  }

  /// 归一化后的别名**列表**：剔除空值、与主标题重复者、去重（归一化比较），保序。
  ///
  /// ★ 2026-10-10 需求 3：别名展示改为「一个名字一个框」，UI 需要拿到列表而非
  /// 拼接串，故把原 [compose] 的筛选逻辑抽成本方法（[compose] 直接 `join`）。
  static List<String> resolve(
    List<String> aliases, {
    Iterable<String> mainTitles = const <String>[],
  }) {
    final excludeNorm = <String>{
      for (final t in mainTitles)
        if (CTService.normalizeForSearch(t).isNotEmpty)
          CTService.normalizeForSearch(t),
    };
    final seen = <String>{};
    final out = <String>[];
    for (final a in aliases) {
      final t = a.trim();
      if (t.isEmpty) continue;
      final norm = CTService.normalizeForSearch(t);
      if (norm.isEmpty) continue;
      if (excludeNorm.contains(norm)) continue;
      if (seen.add(norm)) out.add(t);
    }
    return out;
  }

  /// 把 [compose] 的产物拆回别名列表（分隔符 [separator] = ` / `）。
  ///
  /// 仅用于「历史单字段 `subtitle`（game.json）已存拼接串」的展示端；
  /// 能直接拿到列表的调用方应优先用 [resolve]。无分隔符时返回单元素列表。
  static List<String> split(String composed) {
    final t = composed.trim();
    if (t.isEmpty) return const <String>[];
    return t
        .split(separator)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 合成副标题：剔除空值、与主标题重复者、去重（归一化比较），以 ` / ` 连接。
  ///
  /// [mainTitles]：需排除的主标题候选（元数据标题 / 用户当前标题 / 导入标题）。
  /// 归一化口径与 CT 名称索引一致（[CTService.normalizeForSearch]）。
  /// 全部被剔除时返回空串（调用方据此不覆盖既有副标题）。
  static String compose(
    List<String> aliases, {
    Iterable<String> mainTitles = const <String>[],
  }) =>
      resolve(aliases, mainTitles: mainTitles).join(separator);

  /// 便捷：直接从 legacy 抓取结果合成副标题（[aliasesFromResult] + [compose]）。
  static String fromResult(
    Map<String, dynamic> result, {
    Iterable<String> mainTitles = const <String>[],
  }) =>
      compose(aliasesFromResult(result), mainTitles: mainTitles);
}
