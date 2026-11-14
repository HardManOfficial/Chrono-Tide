import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 元数据字段的「首选平台」偏好。
///
/// 语义刻意做成**前置覆盖**而不是完整重排：
/// 用户只回答「这个字段先看哪家」，其余平台继续按内置优先级链后退
/// （`MetadataFetcher._mixFieldPriority`）。这样既给了用户决定权，
/// 又不会因为选了一个源就丢掉其它源的数据 —— 只改一行优先级链仍然
/// 有完整的降级能力。
///
/// 值是一个**列表**而非单值：设置页把「鲲GAL/NextMoe」显示成一张卡，
/// 它背后是两个 [SourceType]（nextmoe / kun）；选它时两个一起提到链首，
/// 组内相对顺序保持不变。单源平台就是长度为 1 的列表。
///
/// 存储：`SharedPreferences` 的 `metadata_field_priority`，值为 JSON
/// `{"cover_url":["vndb"],"rating":["nextmoe","kun"]}`（[SourceType.name]）。
/// 兼容早期写入的单值形态 `{"cover_url":"vndb"}`。
class MetadataFieldPriority {
  MetadataFieldPriority._();

  static const String prefKey = 'metadata_field_priority';

  /// 可配置字段（顺序即 UI 顺序）。
  ///
  /// 🔴 key 必须与 `MetadataFetcher._mixFieldPriority` 的 key 完全一致，
  /// 否则覆盖不生效且不报错（静默失效是最难查的一类 bug）。
  static const List<String> fields = <String>[
    'cover_url',
    'screenshot_urls',
    'rating',
    'summary',
    'tags',
    'developer',
    'game_name',
  ];

  static const Map<String, String> _labels = <String, String>{
    'cover_url': '封面',
    'screenshot_urls': '截图',
    'rating': '评分 / 投票数',
    'summary': '简介',
    'tags': '标签',
    'developer': '会社（开发商）',
    'game_name': '主标题（中文名）',
  };

  static const Map<String, String> _hints = <String, String>{
    'cover_url': '封面图的来源。默认 NextMoe → CT → 2Dfan → VNDB …',
    'screenshot_urls': '游戏截图。2DFan 不提供截图，故不在内置链里。',
    'rating': '评分与投票数（发售日 / 时长也复用这条链）。VNDB 最权威。',
    'summary': '简介正文。',
    'tags': '标签列表（含权重与剧透标记）。',
    'developer': '会社 / 开发商名称。',
    'game_name': '显示用的主标题，中文名优先。',
  };

  static String labelOf(String field) => _labels[field] ?? field;

  static String hintOf(String field) => _hints[field] ?? '';

  /// 把 JSON 里的一条值解析成 [SourceType] 列表（兼容单值形态）。
  static List<SourceType> _parseSources(Object? value) {
    final List<Object?> raw = value is List ? value : <Object?>[value];
    final List<SourceType> out = <SourceType>[];
    for (final Object? item in raw) {
      if (item == null) continue;
      final String name = item.toString();
      for (final SourceType s in SourceType.values) {
        if (s.name == name && s != SourceType.mix && s != SourceType.local) {
          if (!out.contains(s)) out.add(s);
          break;
        }
      }
    }
    return out;
  }

  /// 读取全部覆盖项。解析失败的条目直接丢弃（不阻塞页面）。
  static Future<Map<String, List<SourceType>>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefKey);
      if (raw == null || raw.trim().isEmpty) return <String, List<SourceType>>{};

      final decoded = json.decode(raw);
      if (decoded is! Map) return <String, List<SourceType>>{};

      final out = <String, List<SourceType>>{};
      decoded.forEach((dynamic key, dynamic value) {
        final String field = key.toString();
        if (!fields.contains(field)) return;
        final List<SourceType> sources = _parseSources(value);
        if (sources.isNotEmpty) out[field] = sources;
      });
      return out;
    } catch (e) {
      debugPrint('[MetadataFieldPriority] ⚠️ 读取失败: $e');
      return <String, List<SourceType>>{};
    }
  }

  /// 覆盖整张表（null 值 / 空列表表示该字段回到内置链）。
  static Future<void> save(Map<String, List<SourceType>?> overrides) async {
    final map = <String, List<String>>{};
    overrides.forEach((String field, List<SourceType>? sources) {
      if (sources == null || sources.isEmpty || !fields.contains(field)) return;
      map[field] = sources.map((SourceType s) => s.name).toList(growable: false);
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      if (map.isEmpty) {
        await prefs.remove(prefKey);
      } else {
        await prefs.setString(prefKey, json.encode(map));
      }
      debugPrint('[MetadataFieldPriority] ✅ 已保存 ${map.length} 项覆盖');
    } catch (e) {
      debugPrint('[MetadataFieldPriority] ⚠️ 保存失败: $e');
    }
  }

  /// 只改一个字段（[sources] 为 null/空表示恢复默认）。
  static Future<void> setOne(String field, List<SourceType>? sources) async {
    final current = await load();
    await save(<String, List<SourceType>?>{...current, field: sources});
  }

  /// 纯函数：给定覆盖表与内置链，算出某字段实际使用的优先级链。
  ///
  /// 「选中的平台提到首位（组内保持顺序），其余保持内置顺序」—— 这样即使
  /// 用户选了一个在内置链末位的源，前面的源仍然是后备而不是被丢掉。
  ///
  /// 由 [MetadataFetcher] 在 MIX 合并时调用，也可在纯 Dart 探针里直接测。
  static List<SourceType> resolveChain(
    String field,
    List<SourceType>? override,
    Map<String, List<SourceType>> builtin,
  ) {
    final base = builtin[field] ?? builtin['rating'] ?? const <SourceType>[];
    if (override == null || override.isEmpty) return base;
    final Set<SourceType> front = override.toSet();
    return <SourceType>[
      ...override,
      ...base.where((SourceType s) => !front.contains(s)),
    ];
  }
}
