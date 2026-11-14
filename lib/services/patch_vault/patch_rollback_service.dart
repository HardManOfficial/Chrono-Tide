/// PATCH-VAULT 回退（纯 Dart，有 IO）。
///
/// 用户最核心的诉求：「想打就打，不想要的时候能回原版」。
/// 本文件提供单补丁撤销与「一键恢复原版」，两条铁律：
///
/// 1. **严格逆序**：重叠补丁按 `appliedAt` 倒序卸载。先撤早装的会把后装的
///    内容覆盖掉，留下无法解释的混合状态（对齐 `patches.rs:601-616` 结论）。
/// 2. **只碰自己写过的文件**：有备份就 copy 回去，原本不存在就删掉自己新建的，
///    ⛔ 不递归清目录、不碰用户其它文件 ⇒ 不触发 ADR-007 / ADR-020 回收站链路。
///
/// 🔴 **还原前必须比对哈希**：当前文件若与 manifest 记录的「应用后哈希」不一致，
/// 说明用户后来手动改过 ⇒ 先抛 [PatchVaultDriftException] 让用户选择，
/// ⛔ 不闷头覆盖（否则「恢复原版反而弄丢用户改动」）。

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import 'patch_apply_service.dart' show PatchApplyPreflight, PatchVaultException;
import 'patch_vault_index.dart';

class PatchDrift {
  const PatchDrift({
    required this.relativePath,
    required this.targetPath,
    required this.expectedSha,
    required this.actualSha,
  });

  final String relativePath;
  final String targetPath;
  final String expectedSha;
  final String actualSha;
}

/// 哈希漂移：需要 UI 弹确认，用户明确选择后才允许继续还原。
class PatchVaultDriftException extends PatchVaultException {
  const PatchVaultDriftException(this.drifts)
      : super('有文件在应用后被改动过，还原会覆盖这些改动');

  final List<PatchDrift> drifts;
}

class PatchRollbackReport {
  const PatchRollbackReport({
    required this.undoneTxIds,
    required this.failures,
    required this.restoredFiles,
    required this.removedFiles,
  });

  final List<String> undoneTxIds;
  final List<String> failures;
  final int restoredFiles;
  final int removedFiles;

  bool get ok => failures.isEmpty;

  PatchRollbackReport merge(PatchRollbackReport other) => PatchRollbackReport(
        undoneTxIds: <String>[...undoneTxIds, ...other.undoneTxIds],
        failures: <String>[...failures, ...other.failures],
        restoredFiles: restoredFiles + other.restoredFiles,
        removedFiles: removedFiles + other.removedFiles,
      );

  static PatchRollbackReport get empty => const PatchRollbackReport(
        undoneTxIds: <String>[],
        failures: <String>[],
        restoredFiles: 0,
        removedFiles: 0,
      );
}

class PatchRollbackService {
  const PatchRollbackService();

  /// 检查某条事务能否单独撤销。
  ///
  /// 若**在它之后**还有已安装事务写过同一目标路径，单独撤销会破坏后装补丁的
  /// 内容 ⇒ 必须先撤销后面的。返回拒绝原因；空串 = 允许。
  Future<String> canUndo(PatchVaultManifestStore store, String txId) async {
    final m = await store.load();
    final target = m.transactions.where((t) => t.txId == txId).toList();
    if (target.isEmpty) return '找不到该补丁的应用记录';
    final anchor = target.first;
    if (!anchor.isInstalled) return '该补丁处于未完成状态，请先运行恢复检查';

    final later = m.installed
        .where((t) =>
            t.txId != txId &&
            (t.appliedAt.compareTo(anchor.appliedAt) > 0 ||
                (t.appliedAt == anchor.appliedAt &&
                    t.txId.compareTo(anchor.txId) > 0)))
        .toList();
    if (later.isEmpty) return '';
    final myPaths = anchor.entries.map((e) => _norm(e.targetPath)).toSet();
    for (final t in later) {
      for (final e in t.entries) {
        if (myPaths.contains(_norm(e.targetPath))) {
          return '之后还有 ${later.length} 个补丁覆盖过相同文件，'
              '请先撤销后面的补丁（或直接用「一键恢复原版」按逆序全部卸载）';
        }
      }
    }
    return '';
  }

  /// 还原前的哈希漂移检查（UI 可先调它展示清单，再决定要不要继续）。
  Future<List<PatchDrift>> checkDrift(PatchTransaction tx) async {
    final out = <PatchDrift>[];
    for (final e in tx.entries) {
      final f = File(e.targetPath);
      if (!f.existsSync()) {
        out.add(PatchDrift(
          relativePath: e.relativePath,
          targetPath: e.targetPath,
          expectedSha: e.afterSha256,
          actualSha: '',
        ));
        continue;
      }
      try {
        final actual = await PatchVaultIndex.sha256(f.path);
        if (actual != e.afterSha256) {
          out.add(PatchDrift(
            relativePath: e.relativePath,
            targetPath: e.targetPath,
            expectedSha: e.afterSha256,
            actualSha: actual,
          ));
        }
      } catch (_) {
        // 读不了就当漂移，交给用户决定，不静默跳过
        out.add(PatchDrift(
          relativePath: e.relativePath,
          targetPath: e.targetPath,
          expectedSha: e.afterSha256,
          actualSha: '',
        ));
      }
    }
    return out;
  }

  /// 撤销单条事务（不检查后续补丁；UI 应先调 [canUndo]）。
  Future<PatchRollbackReport> undo(
    PatchVaultManifestStore store,
    String txId, {
    required PatchApplyPreflight preflight,
    bool allowDrift = false,
  }) async {
    final m = await store.load();
    PatchTransaction? tx;
    for (final t in m.transactions) {
      if (t.txId == txId) {
        tx = t;
        break;
      }
    }
    if (tx == null) {
      throw const PatchVaultException('找不到该补丁的应用记录，可能已被撤销');
    }
    final gate = await preflight();
    if (gate != null && gate.isNotEmpty) {
      throw PatchVaultException(gate);
    }

    final drifts = await checkDrift(tx);
    if (drifts.isNotEmpty && !allowDrift) {
      throw PatchVaultDriftException(drifts);
    }

    // 先标记 restoring：中途被杀时 recover() 知道重新尝试。
    await store.upsert(tx.copyWith(state: PatchTxState.restoring));

    final failures = <String>[];
    var restored = 0;
    var removed = 0;
    for (final e in tx.entries.reversed) {
      try {
        if (e.existedBefore) {
          final b = File(e.backupPath);
          if (!b.existsSync()) {
            failures.add('备份文件已丢失，无法还原：${e.relativePath}');
            continue;
          }
          await b.copy(e.targetPath);
          if (await PatchVaultIndex.sha256(e.targetPath) != e.beforeSha256) {
            failures.add('还原后哈希不符：${e.relativePath}');
            continue;
          }
          restored++;
        } else {
          final t = File(e.targetPath);
          if (t.existsSync()) {
            await t.delete();
            removed++;
          }
          // 只清自己新建的**空**父目录，⛔ 不递归删
          await _pruneEmptyParents(e.targetPath, tx.targetRoot);
        }
      } catch (err) {
        failures.add('还原失败：${e.relativePath}（$err）');
      }
    }

    if (failures.isNotEmpty) {
      // 🔴 备份目录**不能删**：留给用户重试 / 手动取回。
      await store.upsert(tx.copyWith(state: PatchTxState.installed));
      throw PatchVaultException(
        '有 ${failures.length} 个文件未能自动还原，备份已保留：\n'
        '${failures.join('\n')}',
      );
    }

    await _safeDeleteTree(Directory(tx.backupDir));
    await store.remove(tx.txId);
    return PatchRollbackReport(
      undoneTxIds: <String>[tx.txId],
      failures: const <String>[],
      restoredFiles: restored,
      removedFiles: removed,
    );
  }

  /// 一键恢复原版：该游戏全部已装补丁**严格逆序**卸载。
  ///
  /// 这里不做 [canUndo] 检查 —— 逆序正是它要求的顺序。
  Future<PatchRollbackReport> restoreAll(
    PatchVaultManifestStore store, {
    required PatchApplyPreflight preflight,
    bool allowDrift = false,
  }) async {
    final m = await store.load();
    final ordered = m.installed.reversed.toList();
    if (ordered.isEmpty) {
      return PatchRollbackReport.empty;
    }
    var report = PatchRollbackReport.empty;
    for (final tx in ordered) {
      // 每次重新读 manifest，保证拿到的是上一步撤销后的最新状态。
      final cur = await store.load();
      final exists = cur.transactions.any((t) => t.txId == tx.txId);
      if (!exists) continue;
      final one = await undo(
        store,
        tx.txId,
        preflight: preflight,
        allowDrift: allowDrift,
      );
      report = report.merge(one);
    }
    return report;
  }

  static Future<void> _pruneEmptyParents(
      String filePath, String targetRoot) async {
    final normRoot = path.normalize(targetRoot).toLowerCase();
    var dir = Directory(path.dirname(filePath));
    for (var i = 0; i < 8; i++) {
      if (path.normalize(dir.path).toLowerCase() == normRoot) break;
      if (!dir.existsSync()) break;
      try {
        if (await dir.list().isEmpty) {
          await dir.delete();
        } else {
          break;
        }
      } catch (_) {
        break;
      }
      dir = dir.parent;
    }
  }

  static Future<void> _safeDeleteTree(Directory d) async {
    try {
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  static String _norm(String p) =>
      path.normalize(p).replaceAll('/', '\\').toLowerCase();
}
