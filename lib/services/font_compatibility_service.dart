// font_compatibility_service.dart
// L4 辅助层：本地「不兼容游戏清单」的读取与匹配（Phase 4.3，方案 §10-P0-4）。
//
// 用户 2026-10-17 拍板的三条边界：
//   ① 纯本地清单（随包内置）—— 不联网、不拉服务器；
//   ② 只展示不上报 —— 本文件不写盘、不提交任何数据；
//   ③ 命中后黄色标注 + 说明，**不阻断**安装。
//
// 清单源文件：仓库 `resources/fonthook/incompatible.json`，
// 打包脚本复制到 `runtime/fonthook/incompatible.json`；开发态自动回退读仓库源文件。
// 清单缺失 / 损坏一律按「无清单」处理，绝不影响字体功能本身。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../core/path_helper.dart';
import '../utils/title_cleaner.dart';

/// 命中后的展示级别。
enum FontCompatSeverity {
  /// 黄色警告（默认）
  warn,

  /// 蓝色提示
  info,
}

/// 清单中的单条记录。
@immutable
class FontCompatEntry {
  final List<String> titles;
  final List<String> exes;
  final FontCompatSeverity severity;
  final String reason;
  final String doc;

  const FontCompatEntry({
    required this.titles,
    required this.reason,
    this.exes = const [],
    this.severity = FontCompatSeverity.warn,
    this.doc = '',
  });

  /// 解析单条；缺少可展示的 [reason] 或没有任何匹配键时返回 null（忽略该条）。
  static FontCompatEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final reason = (raw['reason'] ?? '').toString().trim();
    if (reason.isEmpty) return null;
    final titles = _stringList(raw['titles']);
    final exes = _stringList(raw['exes']);
    if (titles.isEmpty && exes.isEmpty) return null;
    final sev = (raw['severity'] ?? '').toString().trim().toLowerCase();
    return FontCompatEntry(
      titles: titles,
      exes: exes,
      severity: sev == 'info' ? FontCompatSeverity.info : FontCompatSeverity.warn,
      reason: reason,
      doc: (raw['doc'] ?? '').toString().trim(),
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is List) {
      return raw
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }
}

/// 匹配结果（展示所需的最少信息）。
@immutable
class FontCompatVerdict {
  final FontCompatSeverity severity;
  final String reason;
  final String doc;

  const FontCompatVerdict({
    required this.severity,
    required this.reason,
    this.doc = '',
  });

  bool get isWarning => severity == FontCompatSeverity.warn;
}

/// 本地不兼容清单服务（进程内单例 + 懒加载）。
///
/// 刻意**不**在 `main.dart` 里初始化（`AGENTS.md` §2.4 稳定区）：
/// 首次 [lookup] / [entryCount] 时才同步读盘 —— 清单是几 KB 的小文件，
/// 同步读一次无性能问题，同时让调用方保持同步签名。
class FontCompatibilityService {
  FontCompatibilityService._();

  static final FontCompatibilityService instance = FontCompatibilityService._();

  bool _loaded = false;
  int _entryCount = 0;

  /// 规范化标题 → verdict（匹配时不再重复归一化标题）
  final Map<String, FontCompatVerdict> _titleIndex = {};

  /// 小写 exe 文件名 → verdict
  final Map<String, FontCompatVerdict> _exeIndex = {};

  /// 实际读取的文件（空 = 未找到清单）
  String _sourcePath = '';
  bool _fromDevFallback = false;
  bool _damaged = false;

  String get sourcePath {
    ensureLoaded();
    return _sourcePath;
  }

  bool get fromDevFallback {
    ensureLoaded();
    return _fromDevFallback;
  }

  /// 清单文件存在但解析失败（供 UI / 日志区分「没有清单」与「清单坏了」）。
  bool get damaged {
    ensureLoaded();
    return _damaged;
  }

  /// 清单条数（按 entry 计，不是索引键数）。
  int get entryCount {
    ensureLoaded();
    return _entryCount;
  }

  bool get isEmpty {
    ensureLoaded();
    return _entryCount == 0;
  }

  /// 懒加载（幂等）。
  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    final file = _resolveFile();
    if (file == null) return;
    try {
      _ingest(_readText(file));
      _sourcePath = file;
    } catch (_) {
      _damaged = true;
    }
  }

  /// 查询某游戏是否在清单中。
  ///
  /// [title] 游戏标题；[exeName] 启动程序文件名（可含路径，会取 basename）。
  /// 清单为空或两者都未命中时返回 null。
  FontCompatVerdict? lookup({String? title, String? exeName}) {
    ensureLoaded();
    if (_entryCount == 0) return null;

    final t = (title ?? '').trim();
    if (t.isNotEmpty) {
      final key = TitleCleaner.normalizeForCompare(t);
      if (key.isNotEmpty) {
        final hit = _titleIndex[key];
        if (hit != null) return hit;
      }
    }

    final ex = (exeName ?? '').trim();
    if (ex.isNotEmpty) {
      final hit = _exeIndex[path.basename(ex).toLowerCase()];
      if (hit != null) return hit;
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════
  // 内部
  // ═══════════════════════════════════════════════════════════

  /// ① 发布态：`<exeDir>/runtime/fonthook/incompatible.json`
  /// ② 开发态回退：从 exeDir 向上找仓库 `resources/fonthook/incompatible.json`
  String? _resolveFile() {
    try {
      final deployed = PathHelper.fontHookCompatFilePath;
      if (File(deployed).existsSync()) return deployed;
    } catch (_) {}

    if (kDebugMode) {
      final dev = _findDevFile();
      if (dev != null) {
        _fromDevFallback = true;
        return dev;
      }
    }
    return null;
  }

  String? _findDevFile() {
    try {
      var dir = Directory(PathHelper.exeDir);
      for (var i = 0; i < 8; i++) {
        final candidate = File(
            path.join(dir.path, 'resources', 'fonthook', 'incompatible.json'));
        if (candidate.existsSync()) return candidate.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (_) {}
    return null;
  }

  /// 兼容带 / 不带 BOM（打包脚本用 .NET 无 BOM 写，手工放置的可能是 UTF-8 BOM）。
  String _readText(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }

  void _ingest(String jsonText) {
    Object? root;
    try {
      root = jsonDecode(jsonText);
    } catch (_) {
      // 非法 JSON：标记 damaged，按「无清单」处理（绝不向上抛）
      _damaged = true;
      return;
    }
    if (root is! Map) return;
    final raw = root['entries'];
    if (raw is! List) return;
    for (final item in raw) {
      final entry = FontCompatEntry.fromJson(item);
      if (entry == null) continue;
      _entryCount++;
      final verdict = FontCompatVerdict(
        severity: entry.severity,
        reason: entry.reason,
        doc: entry.doc,
      );
      for (final t in entry.titles) {
        final k = TitleCleaner.normalizeForCompare(t);
        if (k.isNotEmpty) _titleIndex.putIfAbsent(k, () => verdict);
      }
      for (final e in entry.exes) {
        final k = path.basename(e).toLowerCase();
        if (k.isNotEmpty) _exeIndex.putIfAbsent(k, () => verdict);
      }
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 测试
  // ═══════════════════════════════════════════════════════════

  /// 注入清单 JSON（绕过文件系统，供探针 / 单测使用）。
  @visibleForTesting
  void seedFromJsonForTest(String jsonText) {
    _resetInternal();
    _loaded = true;
    _ingest(jsonText);
  }

  /// 重置为「未加载」——下一次访问会重新读盘。
  @visibleForTesting
  void resetForTest() => _resetInternal();

  void _resetInternal() {
    _loaded = false;
    _entryCount = 0;
    _titleIndex.clear();
    _exeIndex.clear();
    _sourcePath = '';
    _fromDevFallback = false;
    _damaged = false;
  }
}
