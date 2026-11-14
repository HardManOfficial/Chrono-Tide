/// PATCH-VAULT 应用事务（纯 Dart，有 IO）。
///
/// ## 范式来源
///
/// 对齐 `game_font_patch_service.dart:429 install` / `:513 _safeRollbackInstall`：
/// **备份先行 → 写 manifest → 投放 → 失败逆序回滚**。比 GalGear 的 Rust 事务
/// 更贴本项目，且能在本环境的纯 Dart 探针里完整跑通。
///
/// ## 九道门禁（方案 §5）
///
/// 1-4、6、9 由 UI 通过 [PatchApplyPreflight] 注入（游戏运行检测带 FFI，
/// 纯 Dart 层不能 import `Win32ProcessService`）；5、7、8 在本文件内硬校验。
///
/// 🔴 **在任何一次写入之前**先落 `state=applying` 的 manifest —— 进程被杀时
/// `recover()` 才有凭据把半成品收回去。
/// 🔴 只删／只还原「自己写过的文件」，不碰用户其它文件
/// （ADR-019 精确回滚范式 ⇒ 不触发 ADR-007 / ADR-020 回收站链路）。
/// 🔴 写前重校验源与目标哈希：预览之后文件被改过就中止，不闷头覆盖。

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import 'game_dirs.dart';
import 'patch_apply_plan.dart';
import 'patch_vault_index.dart';

class PatchVaultException implements Exception {
  const PatchVaultException(this.message, {this.rolledBack = false});

  final String message;

  /// true = 失败后已尽力逆序回滚到应用前状态。
  final bool rolledBack;

  @override
  String toString() => message;
}

/// 门禁回调：返回 null 表示放行，返回非空字符串表示拒绝原因（直接展示给用户）。
typedef PatchApplyPreflight = Future<String?> Function();

/// 进度回调（phase / 已完成 / 总数）。
typedef PatchApplyProgress = void Function(String phase, int done, int total);

class PatchApplyService {
  const PatchApplyService();

  /// [debugFailAfterWrites] 仅供离线探针注入「写满 N 个文件后磁盘故障」，
  /// 生产恒传 -1。用它验证失败逆序回滚真的会跑，而不是只在注释里存在。
  Future<PatchTransaction> apply({
    required PatchPlan plan,
    required PatchApplySource source,
    required GameDirs dirs,
    required String gameId,
    required String patchId,
    required PatchApplyPreflight preflight,
    String txId = '',
    PatchApplyProgress? onProgress,
    int debugFailAfterWrites = -1,
  }) async {
    if (plan.isBlocked) {
      throw PatchVaultException(plan.blockedReasons.join('\n'));
    }
    if (plan.isEmpty || dirs.isOffline) {
      throw const PatchVaultException('没有可应用的文件，或游戏目录不可访问');
    }
    if (gameId.isEmpty) {
      throw const PatchVaultException('该游戏缺少稳定标识（game_id 为空），无法绑定补丁');
    }

    final gate = await preflight();
    if (gate != null && gate.isNotEmpty) {
      throw PatchVaultException(gate);
    }

    final id = txId.isEmpty ? PatchVaultIndex.newId('tx') : txId;
    final backupDir = dirs.backupDirFor(id);
    if (backupDir.isEmpty) {
      throw const PatchVaultException('无法确定备份目录');
    }
    final backupRoot = Directory(backupDir);
    final manifestStore = PatchVaultManifestStore(
      manifestPath: dirs.manifestPath,
      gameId: gameId,
    );

    // ---------- ① 写前重校验：源文件 / 待覆盖目标都必须是预览时的那份 ----------
    final preEntries = <PatchTxEntry>[];
    for (var i = 0; i < plan.entries.length; i++) {
      final e = plan.entries[i];
      final src = File(e.sourcePath);
      if (!src.existsSync()) {
        throw PatchVaultException('补丁源文件在确认后发生变化（缺失）：${e.relativePath}');
      }
      if (await PatchVaultIndex.sha256(src.path) != e.sourceSha256) {
        throw PatchVaultException(
            '补丁源文件在确认后被改动：${e.relativePath}，请重新预览');
      }
      if (e.existed) {
        final t = File(e.targetPath);
        if (!t.existsSync() ||
            await PatchVaultIndex.sha256(t.path) != e.beforeSha256) {
          throw PatchVaultException(
              '游戏文件在确认后被改动：${e.relativePath}，请重新预览');
        }
      } else if (File(e.targetPath).existsSync()) {
        throw PatchVaultException('目标文件在确认后被新建：${e.relativePath}，请重新预览');
      }
      preEntries.add(PatchTxEntry(
        relativePath: e.relativePath,
        targetPath: e.targetPath,
        backupPath: e.existed ? path.join(backupDir, e.relativePath) : '',
        beforeSha256: e.beforeSha256,
        afterSha256: e.sourceSha256, // 预期值，写入后以实际值覆盖
        existedBefore: e.existed,
        sizeBytes: e.sizeBytes,
      ));
      onProgress?.call('校验', i + 1, plan.entries.length);
    }

    // ---------- ② 备份被覆盖的原文件（存在才备份） ----------
    if (backupRoot.existsSync()) {
      throw const PatchVaultException('备份目录已存在（事务 ID 冲突），请重试');
    }
    await backupRoot.create(recursive: true);
    for (var i = 0; i < preEntries.length; i++) {
      final e = preEntries[i];
      if (!e.existedBefore) continue;
      final b = File(e.backupPath);
      await Directory(path.dirname(b.path)).create(recursive: true);
      await File(e.targetPath).copy(b.path);
      if (await PatchVaultIndex.sha256(b.path) != e.beforeSha256) {
        await _safeDeleteTree(backupRoot);
        throw const PatchVaultException('备份校验失败，已中止（未写入任何游戏文件）');
      }
      onProgress?.call('备份', i + 1, preEntries.length);
    }

    // ---------- ③ 先落 applying manifest（崩溃 recover 的凭据） ----------
    var tx = PatchTransaction(
      txId: id,
      patchId: patchId,
      gameId: gameId,
      appliedAt: DateTime.now().toIso8601String(),
      targetRoot: plan.targetRoot,
      backupDir: backupDir,
      state: PatchTxState.applying,
      entries: preEntries,
    );
    await manifestStore.upsert(tx);

    final createdDirs = <String>[];
    final appliedEntries = <PatchTxEntry>[];
    try {
      // ---------- ④ 逐条写入 ----------
      for (var i = 0; i < plan.entries.length; i++) {
        final e = plan.entries[i];
        final target = File(e.targetPath);
        final parent = Directory(path.dirname(target.path));
        if (!parent.existsSync()) {
          await _createDirsTracking(
            parent,
            stopAt: plan.targetRoot,
            created: createdDirs,
          );
        }
        await File(e.sourcePath).copy(target.path);

        final actual = await PatchVaultIndex.sha256(target.path);
        if (actual != e.sourceSha256) {
          throw PatchVaultException('写入校验失败：${e.relativePath}');
        }
        appliedEntries.add(preEntries[i].copyWithSha(actual));
        onProgress?.call('应用', i + 1, plan.entries.length);

        if (debugFailAfterWrites >= 0 && appliedEntries.length == debugFailAfterWrites) {
          throw StateError('[probe] 注入的写入故障');
        }
      }

      // ---------- ⑤ 全部成功：manifest 转 installed ----------
      tx = tx.copyWith(state: PatchTxState.installed, entries: appliedEntries);
      await manifestStore.upsert(tx);
      return tx;
    } catch (e) {
      // ---------- 失败：严格逆序回滚 ----------
      final report = await _rollbackWritten(
        applied: appliedEntries,
        planned: preEntries,
        createdDirs: createdDirs,
        targetRoot: plan.targetRoot,
      );
      await _safeDeleteTree(backupRoot);
      try {
        await manifestStore.remove(id);
      } catch (_) {}
      throw PatchVaultException(
        '应用失败，已${report.ok ? '逆序回滚到应用前状态' : '尝试回滚，但有 ${report.failures.length} 项未能自动还原'}：'
        '$e'
        '${report.failures.isEmpty ? '' : '\n${report.failures.join('\n')}'}',
        rolledBack: report.ok,
      );
    }
  }

  /// 逆序还原本次**已经写过**的文件；没写到的条目不碰。
  static Future<_RollbackReport> _rollbackWritten({
    required List<PatchTxEntry> applied,
    required List<PatchTxEntry> planned,
    required List<String> createdDirs,
    required String targetRoot,
  }) async {
    final failures = <String>[];
    for (final e in applied.reversed) {
      try {
        if (e.existedBefore) {
          final b = File(e.backupPath);
          if (b.existsSync()) {
            await b.copy(e.targetPath);
            if (await PatchVaultIndex.sha256(e.targetPath) !=
                e.beforeSha256) {
              failures.add('还原后哈希不符：${e.relativePath}');
            }
          } else {
            failures.add('备份丢失，无法还原：${e.relativePath}');
          }
        } else {
          final t = File(e.targetPath);
          if (t.existsSync()) await t.delete();
        }
      } catch (err) {
        failures.add('还原失败：${e.relativePath}（$err）');
      }
    }

    // 只清本次新建的**空**目录，从深到浅；⛔ 绝不删落点根本身。
    final sorted = createdDirs.toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final normRoot = path.normalize(targetRoot).toLowerCase();
    for (final d in sorted) {
      if (path.normalize(d).toLowerCase() == normRoot) continue;
      try {
        final dir = Directory(d);
        if (dir.existsSync() && await dir.list().isEmpty) {
          await dir.delete();
        }
      } catch (_) {}
    }
    return _RollbackReport(failures);
  }

  /// 创建目标父目录，并记下本次新建的目录（供回滚清理）。
  static Future<void> _createDirsTracking(
    Directory dir, {
    required String stopAt,
    required List<String> created,
  }) async {
    final missing = <Directory>[];
    var cur = dir;
    while (!cur.existsSync()) {
      missing.add(cur);
      final parent = cur.parent;
      if (parent.path == cur.path) break;
      cur = parent;
      if (path.normalize(cur.path).toLowerCase() ==
          path.normalize(stopAt).toLowerCase()) {
        break;
      }
    }
    for (final d in missing.reversed) {
      if (!d.existsSync()) {
        await d.create();
        created.add(d.path);
      }
    }
  }

  static Future<void> _safeDeleteTree(Directory d) async {
    try {
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }
}

class _RollbackReport {
  const _RollbackReport(this.failures);

  final List<String> failures;
  bool get ok => failures.isEmpty;
}

/// 逐条更新 afterSha 的小扩展（避免给模型加可变状态）。
extension PatchTxEntryShaX on PatchTxEntry {
  PatchTxEntry copyWithSha(String actual) => PatchTxEntry(
        relativePath: relativePath,
        targetPath: targetPath,
        backupPath: backupPath,
        beforeSha256: beforeSha256,
        afterSha256: actual,
        existedBefore: existedBefore,
        sizeBytes: sizeBytes,
      );
}
