/// PATCH-VAULT 存储层（纯 Dart，零 Flutter）。
///
/// 两份 JSON，职责严格分开：
///
/// | 文件 | 位置 | 内容 |
/// |---|---|---|
/// | `index.json` | 应用数据目录 `data/patch_vault/` | 补丁登记 + 事务**摘要** |
/// | `manifest.json` | `<启动目录>/.CTPatch/` | 逐文件备份映射（**回退唯一真值**） |
///
/// 🔴 零 schema 迁移：不写 `game.json`、不动 `format_version=4`、不改注册表。
/// 🔴 所有路径由调用方注入 `rootDir` / `manifestPath`（生产用
///    `PathHelper.dataDir` / `GameDirs.manifestPath`，探针用临时沙盒），
///    本文件不 import `PathHelper`（它带平台探测）。
/// 🔴 写盘一律走 `_atomicWrite`：先写 `.tmp`，把旧文件挪成 `.bak`，
///    再 rename 上去。manifest 丢了 = 用户回不了原版，不能赌单次写入。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import '../patch/patch_download_core.dart' show sha256OfFile;

/// 登记记录的存在性 / 变更检测结果。
class PatchRecordCheck {
  const PatchRecordCheck({
    required this.exists,
    required this.changed,
    required this.message,
  });

  final bool exists;
  final bool changed;
  final String message;
}

/// 应用数据目录侧索引。
class PatchVaultIndex {
  PatchVaultIndex({required this.rootDir});

  /// `data/patch_vault/`（生产）或临时目录（探针）。
  final String rootDir;

  String get indexPath => path.join(rootDir, 'index.json');

  static String newId([String prefix = 'pv']) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_'
      '${math.Random().nextInt(0xFFFFFF).toRadixString(16)}';

  Future<PatchVaultData> load() async {
    final f = File(indexPath);
    if (!f.existsSync()) {
      final bak = File('$indexPath.bak');
      if (bak.existsSync()) {
        try {
          await bak.copy(indexPath);
        } catch (_) {}
      }
    }
    if (!f.existsSync()) return PatchVaultData.empty;
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        return PatchVaultData.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 🔴 索引损坏不能让整个面板起不来，也不能悄悄清空用户数据：
      // 保留损坏文件供人工排查，本次按空索引运行。
    }
    return PatchVaultData.empty;
  }

  Future<void> save(PatchVaultData data) async {
    await Directory(rootDir).create(recursive: true);
    await _atomicWrite(
      File(indexPath),
      const JsonEncoder.withIndent('  ').convert(data.toJson()),
    );
  }

  Future<PatchVaultData> addRecord(PatchRecord record) async {
    final data = await load();
    final old = data.of(record.gameId);
    final list = <PatchRecord>[
      ...old.patches.where((e) => e.id != record.id),
      record,
    ];
    return _put(data, record.gameId, old.copyWith(patches: list));
  }

  Future<PatchVaultData> updateRecord(
      String gameId, PatchRecord record) async {
    final data = await load();
    final old = data.of(gameId);
    final list = <PatchRecord>[
      for (final e in old.patches) e.id == record.id ? record : e,
    ];
    return _put(data, gameId, old.copyWith(patches: list));
  }

  Future<PatchVaultData> removeRecord(String gameId, String recordId) async {
    final data = await load();
    final old = data.of(gameId);
    final list = old.patches.where((e) => e.id != recordId).toList();
    return _put(data, gameId, old.copyWith(patches: list));
  }

  Future<PatchVaultData> putTxSummary(
      String gameId, PatchTxSummary summary) async {
    final data = await load();
    final old = data.of(gameId);
    final list = <PatchTxSummary>[
      ...old.txSummaries.where((e) => e.txId != summary.txId),
      summary,
    ];
    return _put(data, gameId, old.copyWith(txSummaries: list));
  }

  Future<PatchVaultData> removeTxSummary(
      String gameId, String txId) async {
    final data = await load();
    final old = data.of(gameId);
    final list = old.txSummaries.where((e) => e.txId != txId).toList();
    return _put(data, gameId, old.copyWith(txSummaries: list));
  }

  Future<PatchVaultData> _put(
    PatchVaultData data,
    String gameId,
    PatchVaultGameState state,
  ) async {
    final games = Map<String, PatchVaultGameState>.from(data.games);
    games[gameId] = state;
    final next = PatchVaultData(games: games);
    await save(next);
    return next;
  }

  /// 打开面板时的**轻量**校验：只看存在性 + size + mtime。
  ///
  /// 🔴 大文件不每次全量重算 sha256（补丁动辄上 GB），应用前再算一次。
  static Future<PatchRecordCheck> checkRecord(PatchRecord r) async {
    if (r.isDirectory) {
      final exists = await Directory(r.sourcePath).exists();
      return PatchRecordCheck(
        exists: exists,
        changed: false,
        message: exists ? '' : '文件夹已不存在，请重新定位或移除登记',
      );
    }
    final f = File(r.sourcePath);
    if (!await f.exists()) {
      return const PatchRecordCheck(
        exists: false,
        changed: false,
        message: '文件已不存在，请重新定位或移除登记',
      );
    }
    try {
      final st = await f.stat();
      final sizeChanged = r.sizeBytes > 0 && st.size != r.sizeBytes;
      final mtimeChanged =
          r.mtimeMs > 0 && st.modified.millisecondsSinceEpoch != r.mtimeMs;
      if (sizeChanged || mtimeChanged) {
        return const PatchRecordCheck(
          exists: true,
          changed: true,
          message: '文件内容与登记时不同，应用前会重新校验哈希',
        );
      }
      return const PatchRecordCheck(
          exists: true, changed: false, message: '');
    } catch (_) {
      return const PatchRecordCheck(
        exists: true,
        changed: false,
        message: '无法读取文件属性，应用前请自行确认',
      );
    }
  }

  /// 流式 sha256（复用补丁站实现，避免整份读进内存）。
  static Future<String> sha256(String filePath) => sha256OfFile(filePath);
}

/// 游戏目录 `.CTPatch/manifest.json` 的读写。
///
/// 🔴 这是「能不能回退原版」的唯一凭据，写盘必须原子且可恢复。
class PatchVaultManifestStore {
  const PatchVaultManifestStore({
    required this.manifestPath,
    required this.gameId,
  });

  final String manifestPath;
  final String gameId;

  Future<PatchVaultManifest> load() async {
    final f = File(manifestPath);
    if (!f.existsSync()) {
      final bak = File('$manifestPath.bak');
      if (bak.existsSync()) {
        try {
          await bak.copy(manifestPath);
        } catch (_) {}
      }
    }
    if (!f.existsSync()) return PatchVaultManifest.empty(gameId);
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        final m =
            PatchVaultManifest.fromJson(Map<String, dynamic>.from(decoded));
        // 🔴 gameId 不符 = 备份串到别的游戏了，宁可当作没有，也不能乱还原。
        if (m.gameId.isNotEmpty && m.gameId != gameId) {
          return PatchVaultManifest.empty(gameId);
        }
        return m;
      }
    } catch (_) {
      // 损坏时保留原文件；⚠️ 此时无法自动回退，UI 必须明确告知用户
      // （不要假装「没有补丁」）。
    }
    return PatchVaultManifest.empty(gameId);
  }

  bool get hasDamagedManifest {
    final f = File(manifestPath);
    if (!f.existsSync()) return false;
    try {
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is! Map;
    } catch (_) {
      return true;
    }
  }

  Future<void> save(PatchVaultManifest manifest) async {
    final parent = Directory(path.dirname(manifestPath));
    if (!parent.existsSync()) await parent.create(recursive: true);
    await _atomicWrite(
      File(manifestPath),
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );
  }

  Future<PatchVaultManifest> upsert(PatchTransaction tx) async {
    final m = await load();
    final list = <PatchTransaction>[
      ...m.transactions.where((e) => e.txId != tx.txId),
      tx,
    ];
    final next = PatchVaultManifest(gameId: gameId, transactions: list);
    await save(next);
    return next;
  }

  Future<PatchVaultManifest> remove(String txId) async {
    final m = await load();
    final list = m.transactions.where((e) => e.txId != txId).toList();
    final next = PatchVaultManifest(gameId: gameId, transactions: list);
    await save(next);
    return next;
  }
}

/// 原子写：tmp → 旧文件挪 .bak → rename → 清 .bak；失败把 .bak 挪回来。
Future<void> _atomicWrite(File target, String content) async {
  final tmp = File('${target.path}.tmp');
  final bak = File('${target.path}.bak');
  if (tmp.existsSync()) await tmp.delete();
  await tmp.writeAsString(content, flush: true);

  if (bak.existsSync()) await bak.delete();
  final hadTarget = target.existsSync();
  if (hadTarget) await target.rename(bak.path);
  try {
    await tmp.rename(target.path);
  } catch (_) {
    if (bak.existsSync()) await bak.rename(target.path);
    rethrow;
  }
  if (bak.existsSync()) await bak.delete();
}
