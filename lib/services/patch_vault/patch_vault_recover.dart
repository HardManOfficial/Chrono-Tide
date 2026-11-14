/// PATCH-VAULT 残留事务收拾（纯 Dart，有 IO）。
///
/// ## 为什么需要
///
/// `apply()` 在任何一次写入之前先落 `state=applying` 的 manifest（见
/// `patch_apply_service.dart` ③）。若进程在备份完、写入途中被杀 / 断电，
/// 磁盘上会留下「半个补丁」。下次进来必须把这段收回去，否则用户看到的是
/// 一个说不清状态的混合游戏目录。
///
/// ## 调用时机（与方案的偏差，必须记录在案）
///
/// 方案 §5 写的是「启动时 `recover()`」，但 `main.dart` / `main_container.dart`
/// 属**未经批准禁动的稳定区**。因此落地为**打开补丁管理面板时对当前游戏
/// 执行懒 recover**：同样保证「用户再次接触补丁功能之前残留已被收拾」，
/// 且零稳定区改动。用户新增第二台游戏目录时，只要右键进面板就会各自收拾。
///
/// ## 铁律
///
/// - 只处理 `applying` / `rollingBack` / `restoring`，⛔ 不碰 installed 事务；
/// - 原本不存在的目标文件，**只在哈希等于本事务写入值时才删**（防误删用户
///   后来自己放的同名文件）；
/// - 还原成功才删备份目录、才从 manifest 移除；失败保留现场并报告；
/// - 幂等：重复运行结果一致。

import 'dart:io';

import 'patch_vault_index.dart';

class PatchRecoverReport {
  const PatchRecoverReport({
    required this.handledTxIds,
    required this.failures,
    required this.warnings,
    required this.damagedManifest,
  });

  final List<String> handledTxIds;
  final List<String> failures;
  final List<String> warnings;
  final bool damagedManifest;

  bool get ok => failures.isEmpty && !damagedManifest;
  bool get hasWork =>
      handledTxIds.isNotEmpty ||
      failures.isNotEmpty ||
      warnings.isNotEmpty ||
      damagedManifest;

  static PatchRecoverReport get empty => const PatchRecoverReport(
        handledTxIds: <String>[],
        failures: <String>[],
        warnings: <String>[],
        damagedManifest: false,
      );
}

class PatchVaultRecover {
  const PatchVaultRecover();

  Future<PatchRecoverReport> run({
    required String manifestPath,
    required String gameId,
  }) async {
    final store = PatchVaultManifestStore(
      manifestPath: manifestPath,
      gameId: gameId,
    );
    if (store.hasDamagedManifest) {
      return const PatchRecoverReport(
        handledTxIds: <String>[],
        failures: <String>[],
        warnings: <String>[
          'manifest.json 无法解析：自动回退暂不可用。'
          '备份文件仍在 .CTPatch/backup/ 下，请勿删除该目录'
        ],
        damagedManifest: true,
      );
    }

    final m = await store.load();
    final pending = m.transactions
        .where((t) => !t.isInstalled)
        .toList()
      ..sort((a, b) => b.appliedAt.compareTo(a.appliedAt)); // 新事务先收

    final handled = <String>[];
    final failures = <String>[];
    final warnings = <String>[];

    for (final tx in pending) {
      final txFailures = <String>[];
      for (final e in tx.entries.reversed) {
        try {
          if (e.existedBefore) {
            final b = File(e.backupPath);
            final t = File(e.targetPath);
            // 已经是应用前状态就别重复写（幂等）
            if (b.existsSync()) {
              final current = t.existsSync()
                  ? await PatchVaultIndex.sha256(t.path)
                  : '';
              if (current != e.beforeSha256) {
                await b.copy(t.path);
                if (await PatchVaultIndex.sha256(t.path) != e.beforeSha256) {
                  txFailures.add('还原后哈希不符：${e.relativePath}');
                }
              }
            } else if (!t.existsSync()) {
              // 备份和目标都没了：无可还原，不算失败
            } else {
              txFailures.add('备份丢失，无法还原：${e.relativePath}');
            }
          } else {
            final t = File(e.targetPath);
            if (!t.existsSync()) continue;
            final current = await PatchVaultIndex.sha256(t.path);
            if (current == e.afterSha256 || e.afterSha256.isEmpty) {
              await t.delete();
            } else {
              warnings.add('目标文件已被改动，保留未删：${e.relativePath}');
            }
          }
        } catch (err) {
          txFailures.add('收拾失败：${e.relativePath}（$err）');
        }
      }

      if (txFailures.isNotEmpty) {
        failures.addAll(txFailures);
        // 🔴 保留事务与备份，等下次 / 用户手动处理
        continue;
      }
      try {
        final bak = Directory(tx.backupDir);
        if (bak.existsSync()) await bak.delete(recursive: true);
      } catch (_) {
        warnings.add('备份目录未能清理（不影响还原）：${tx.backupDir}');
      }
      await store.remove(tx.txId);
      handled.add(tx.txId);
    }

    // installed 但备份目录已丢失：不自动改状态，只提醒用户「回退可能失败」。
    final after = await store.load();
    for (final tx in after.installed) {
      final needBackup = tx.entries.any((e) => e.existedBefore);
      if (needBackup && !Directory(tx.backupDir).existsSync()) {
        warnings.add('已应用补丁 ${tx.txId} 的备份目录不见了，撤销时可能无法还原，'
            '请检查 .CTPatch/backup/');
      }
    }

    return PatchRecoverReport(
      handledTxIds: handled,
      failures: failures,
      warnings: warnings,
      damagedManifest: false,
    );
  }
}
