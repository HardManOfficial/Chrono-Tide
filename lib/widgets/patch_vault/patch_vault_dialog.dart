/// PATCH-VAULT 主面板 —— 库页卡片右键「补丁管理」打开的唯一入口。
///
/// ## 目标对齐（用户 2026-11-11 20:19）
///
/// ① 管理：用户自行导入本地补丁，程序只读识别类型，可视化列表，可转移路径；
/// ② 辅助打补丁：按常见习惯给**推荐落点**（可改、须确认），不替用户决定；
/// ③ 无痛／回退：应用前备份 + manifest 记账 → 撤销 / 一键恢复原版。
///
/// 🔴 面板**常驻提示条**：打补丁前先去游戏目录看说明（用户明确要求）。
/// 🔴 面板打开时对当前游戏执行懒 `recover()`（稳定区 main.dart 禁改，
/// 见 `patch_vault_recover.dart` 文件头说明）。
/// 🔴 门禁统一由 [PatchApplyPreflight] 注入给服务层，服务层本身零 FFI/Flutter。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../core/path_helper.dart';
import '../../models/patch_vault_record.dart';
import '../../services/game_data_format.dart';
import '../../services/local_game_registry.dart';
import '../../services/path_validator.dart';
import '../../services/win32_process_service.dart';
import '../../services/patch/patch_preview.dart';
import '../../services/patch_vault/game_dirs.dart';
import '../../services/patch_vault/patch_apply_plan.dart';
import '../../services/patch_vault/patch_apply_service.dart';
import '../../services/patch_vault/patch_inspector.dart';
import '../../services/patch_vault/patch_rollback_service.dart';
import '../../services/patch_vault/patch_vault_index.dart';
import '../../services/patch_vault/patch_vault_recover.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../../utils/game_path_resolver.dart';
import '../app_dialog.dart';
import '../app_snack_bar.dart';
import 'patch_apply_preview.dart';
import 'patch_record_card.dart';
import 'patch_transfer_dialog.dart';

class PatchVaultDialog extends StatefulWidget {
  const PatchVaultDialog({
    super.key,
    required this.game,
    this.debugSkipLoad = false,
  });

  final LibraryGame game;

  /// 仅渲染探针用：跳过磁盘 IO（flutter_tester 的 fake-async 不推进真实 IO）。
  final bool debugSkipLoad;

  static Future<void> show(
    BuildContext context,
    LibraryGame game, {
    bool debugSkipLoad = false,
  }) async {
    await showAppDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) =>
          PatchVaultDialog(game: game, debugSkipLoad: debugSkipLoad),
    );
  }

  @override
  State<PatchVaultDialog> createState() => _PatchVaultDialogState();
}

class _PatchVaultDialogState extends State<PatchVaultDialog> {
  late final PatchVaultIndex _index;
  late final String _indexRoot;
  GameDirs? _dirs;
  bool _loading = true;
  bool _busy = false;
  String _progress = '';
  String? _fatal;
  PatchVaultData _data = PatchVaultData.empty;
  PatchVaultManifest _manifest = PatchVaultManifest.empty('');
  final Map<String, PatchRecordCheck> _checks = <String, PatchRecordCheck>{};
  List<String> _gameExeNames = <String>[];
  List<String> _gameTopDirs = <String>[];
  PatchRecoverReport? _recoverReport;

  @override
  void initState() {
    super.initState();
    _indexRoot = path.join(PathHelper.dataDir, 'patch_vault');
    _index = PatchVaultIndex(rootDir: _indexRoot);
    if (widget.debugSkipLoad) {
      _dirs = GameDirs.compute(
        bodyRoot: r'C:\ChronoTideProbe\game',
        launchPath: '',
        probeDirExists: (_) => false,
      );
      _loading = false;
    } else {
      _load();
    }
  }

  PatchVaultManifestStore get _store => PatchVaultManifestStore(
        manifestPath: _dirs!.manifestPath,
        gameId: widget.game.gameId,
      );

  List<PatchRecord> get _records =>
      _data.of(widget.game.gameId).patches;

  int appliedCountOf(String patchId) => _manifest.installed
      .where((t) => t.patchId == patchId)
      .length;

  // ═══════════════════════════ 加载 ═══════════════════════════

  Future<void> _load() async {
    try {
      final view = await GamePathResolver.resolve(
        directoryPath: widget.game.directoryPath,
        sourcePath: widget.game.sourcePath,
      );
      final exe = view.accessPath.isEmpty
          ? ''
          : GameDataFormat.resolveLaunchPath(
              widget.game.launchPath, view.accessPath);
      final dirs = GameDirs.compute(
        bodyRoot: view.accessPath,
        launchPath: widget.game.launchPath,
        resolvedExePath: exe,
        isOffline: view.state == GamePathState.offline,
        probeDirExists: (d) => Directory(d).existsSync(),
      );
      _dirs = dirs;
      if (dirs.isValid) {
        final shape = await scanGameShape(dirs.bodyRoot,
            launchDir: dirs.launchDir);
        _gameExeNames = shape.exeNames;
        _gameTopDirs = shape.topDirs;
      }
      if (widget.game.gameId.isEmpty) {
        _fatal = '该游戏缺少稳定标识（game_id 为空），无法把补丁绑定到它。'
            '请先在库里重新扫描该游戏；本功能不会改写 game.json。';
      } else if (!dirs.isValid) {
        _fatal = '游戏目录当前不可访问（网络盘离线 / 目录被移动）。'
            '补丁登记仍可查看，但应用与回退已禁用。';
      }
      await _reload(recover: true);
    } catch (e) {
      _fatal = '补丁面板初始化失败：$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _reload({bool recover = false}) async {
    final dirs = _dirs;
    _data = await _index.load();
    if (dirs != null && dirs.isValid && widget.game.gameId.isNotEmpty) {
      if (recover) {
        _recoverReport = await const PatchVaultRecover().run(
          manifestPath: dirs.manifestPath,
          gameId: widget.game.gameId,
        );
      }
      _manifest = await _store.load();
    }
    _checks.clear();
    for (final r in _records) {
      _checks[r.id] = await PatchVaultIndex.checkRecord(r);
    }
    if (mounted) setState(() {});
  }

  // ═══════════════════════════ 门禁 ═══════════════════════════

  /// 方案 §5 门禁 1–4：目录可用 / 游戏未运行 / 真写探测 / 磁盘预检。
  PatchApplyPreflight preflightFor(PatchPlan plan) => () async {
        final dirs = _dirs;
        if (dirs == null || !dirs.isValid) return '游戏目录不可访问，已中止';
        if (Win32ProcessService.getProcessesInDirectory(dirs.bodyRoot)
                .isNotEmpty ||
            Win32ProcessService.getProcessesInDirectory(dirs.launchDir)
                .isNotEmpty) {
          return '游戏正在运行，请先关闭游戏再打补丁';
        }
        if (!_isWritable(dirs.launchDir)) {
          return '无法写入游戏目录（可能位于 Program Files 等受保护位置），'
              '可尝试以管理员身份运行管理器';
        }
        // 备份在启动目录、补丁可能落在本体根（两盘不同时都要查）
        final roots = <String>{
          dirs.launchDir,
          if (plan.targetRoot.isNotEmpty) plan.targetRoot,
        };
        for (final root in roots) {
          if (!await DiskSpaceInfoProbe.hasEnough(root, plan)) {
            return '磁盘剩余空间不足（$root 需约 '
                '${formatPatchPreviewBytes(DiskSpaceInfoProbe.requiredBytes(plan))}）';
          }
        }
        if (widget.game.gameId.isEmpty) return '该游戏缺少 game_id，已中止';
        return null;
      };

  static bool _isWritable(String dir) {
    try {
      final probe = File(path.join(
          dir, '.ct_patch_vault_probe_${DateTime.now().microsecondsSinceEpoch}'));
      probe.writeAsStringSync('1', flush: true);
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════ 导入 ═══════════════════════════

  Future<void> _importFiles() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null) return;
    for (final f in res.files) {
      final p = f.path;
      if (p != null && p.isNotEmpty) await _register(p);
    }
  }

  Future<void> _importFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null && dir.isNotEmpty) await _register(dir);
  }

  Future<void> _register(String sourcePath) async {
    if (_fatal != null && widget.game.gameId.isEmpty) {
      AppSnackBar.error(context, '该游戏缺少 game_id，无法登记补丁');
      return;
    }
    final isDir = await FileSystemEntity.isDirectory(sourcePath);
    if (!isDir && !await File(sourcePath).exists()) {
      AppSnackBar.error(context, '路径不存在：$sourcePath');
      return;
    }
    if (_records.any((r) =>
        r.sourcePath.toLowerCase() == sourcePath.toLowerCase())) {
      AppSnackBar.info(context, '该路径已登记：${path.basename(sourcePath)}');
      return;
    }
    setState(() {
      _busy = true;
      _progress = '正在识别 ${path.basename(sourcePath)} …';
    });
    try {
      final ins = await PatchInspector(
        gameExeNames: _gameExeNames,
        gameTopDirs: _gameTopDirs,
      ).inspect(sourcePath);
      int size;
      int mtime;
      String sha;
      if (isDir) {
        size = ins.totalBytes;
        mtime = 0;
        sha = '';
      } else {
        final f = File(sourcePath);
        final st = await f.stat();
        size = st.size;
        mtime = st.modified.millisecondsSinceEpoch;
        sha = await PatchVaultIndex.sha256(sourcePath);
      }
      final manual = ins.container.needsManualExtract ||
          ins.container.isInstaller ||
          ins.container == PatchContainer.unknown;
      final rec = PatchRecord(
        id: PatchVaultIndex.newId(),
        gameId: widget.game.gameId,
        sourcePath: sourcePath,
        fileName: path.basename(sourcePath),
        sizeBytes: size,
        mtimeMs: mtime,
        sha256: sha,
        container: ins.container,
        kind: ins.kind,
        hasReadme: ins.hasReadme,
        hasExe: ins.hasExe,
        status: manual
            ? PatchVaultStatus.manual
            : PatchVaultStatus.registered,
        addedAt: DateTime.now().toIso8601String(),
        isDirectory: isDir,
        note: manual ? ins.reason : '',
      );
      await _index.addRecord(rec);
      await _reload();
      if (mounted) {
        AppSnackBar.success(context, '已登记：${rec.fileName}（${ins.kind.label}）');
      }
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '登记失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  // ═══════════════════════════ 应用 ═══════════════════════════

  Future<void> _onApply(PatchRecord record) async {
    final dirs = _dirs;
    if (dirs == null || !dirs.isValid || widget.game.gameId.isEmpty) {
      AppSnackBar.error(context, '游戏目录不可访问或缺少 game_id，无法应用');
      return;
    }
    // 门禁 5：登记后源哈希是否仍一致
    if (record.sha256.isNotEmpty) {
      final cur = await PatchVaultIndex.sha256(record.sourcePath);
      if (cur != record.sha256) {
        AppSnackBar.error(context, '补丁文件与登记时不同，请移除后重新导入');
        return;
      }
    }
    final confirm = await PatchApplyPreview.show(
      context: context,
      record: record,
      dirs: dirs,
      gameId: widget.game.gameId,
      gameTitle: widget.game.title,
      indexRoot: _indexRoot,
      gameExeNames: _gameExeNames,
      gameTopDirs: _gameTopDirs,
    );
    if (confirm == null) return;

    setState(() {
      _busy = true;
      _progress = '正在应用补丁（备份 → 写入 → 记账）…';
    });
    try {
      final tx = await const PatchApplyService().apply(
        plan: confirm.plan,
        source: confirm.source,
        dirs: dirs,
        gameId: widget.game.gameId,
        patchId: record.id,
        preflight: preflightFor(confirm.plan),
        onProgress: (phase, done, total) {
          if (mounted) setState(() => _progress = '$phase $done/$total');
        },
      );
      await _index.putTxSummary(
        widget.game.gameId,
        PatchTxSummary(
          txId: tx.txId,
          patchId: tx.patchId,
          appliedAt: tx.appliedAt,
          targetRoot: tx.targetRoot,
        ),
      );
      await _index.updateRecord(
          widget.game.gameId,
          record.copyWith(status: PatchVaultStatus.applied));
      if (mounted) {
        AppSnackBar.success(context,
            '补丁已应用（${tx.entries.length} 个文件）。不想要时点「撤销」即可回原版');
      }
    } on PatchVaultException catch (e) {
      if (mounted) AppSnackBar.error(context, e.message);
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '应用失败：$e');
    } finally {
      await disposeApplySource(confirm.source);
      await _reload();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  // ═══════════════════════════ 回退 ═══════════════════════════

  Future<void> _onUndo(PatchRecord record) async {
    final dirs = _dirs;
    if (dirs == null || !dirs.isValid) return;
    final txs = _manifest.installed
        .where((t) => t.patchId == record.id)
        .toList()
      ..sort((a, b) => b.appliedAt.compareTo(a.appliedAt));
    if (txs.isEmpty) {
      AppSnackBar.info(context, '该补丁没有应用记录');
      return;
    }
    final tx = txs.first;
    final svc = const PatchRollbackService();
    final why = await svc.canUndo(_store, tx.txId);
    if (why.isNotEmpty) {
      AppSnackBar.warning(context, why);
      return;
    }
    if (!await _confirmDrift(<PatchTransaction>[tx])) return;
    setState(() {
      _busy = true;
      _progress = '正在撤销补丁…';
    });
    try {
      final report = await svc.undo(
        _store,
        tx.txId,
        preflight: preflightFor(const PatchPlan(
          targetRoot: '',
          entries: <PatchPlanEntry>[],
          totalBytes: 0,
          backupBytes: 0,
          overwriteCount: 0,
          warnings: <String>[],
          blockedReasons: <String>[],
        )),
        allowDrift: true,
      );
      await _index.removeTxSummary(widget.game.gameId, tx.txId);
      final still = _manifest.installed
          .where((t) => t.patchId == record.id && t.txId != tx.txId)
          .isNotEmpty;
      if (!still) {
        await _index.updateRecord(
            widget.game.gameId,
            record.copyWith(status: PatchVaultStatus.registered));
      }
      if (mounted) {
        AppSnackBar.success(context,
            '已撤销：还原 ${report.restoredFiles} 个文件、移除 ${report.removedFiles} 个新增文件');
      }
    } on PatchVaultException catch (e) {
      if (mounted) AppSnackBar.error(context, e.message);
    } finally {
      await _reload();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  Future<void> _onRestoreAll() async {
    final dirs = _dirs;
    if (dirs == null || !dirs.isValid) return;
    final all = _manifest.installed;
    if (all.isEmpty) {
      AppSnackBar.info(context, '这个游戏没有已应用的补丁记录');
      return;
    }
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('一键恢复原版'),
            content: Text(
              '将按应用顺序的逆序撤销 ${all.length} 条补丁记录，'
              '把本功能写过的文件还原到打补丁之前。\n\n'
              '本功能只还原自己写过的文件，不会删除你的其它游戏文件。',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('开始恢复')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    if (!await _confirmDrift(all)) return;

    setState(() {
      _busy = true;
      _progress = '正在按逆序恢复原版…';
    });
    try {
      final report = await const PatchRollbackService().restoreAll(
        _store,
        preflight: preflightFor(const PatchPlan(
          targetRoot: '',
          entries: <PatchPlanEntry>[],
          totalBytes: 0,
          backupBytes: 0,
          overwriteCount: 0,
          warnings: <String>[],
          blockedReasons: <String>[],
        )),
        allowDrift: true,
      );
      for (final tx in report.undoneTxIds) {
        await _index.removeTxSummary(widget.game.gameId, tx);
      }
      for (final r in _records) {
        if (r.status == PatchVaultStatus.applied) {
          await _index.updateRecord(
              widget.game.gameId,
              r.copyWith(status: PatchVaultStatus.registered));
        }
      }
      if (mounted) {
        AppSnackBar.success(context,
            '已恢复原版：撤销 ${report.undoneTxIds.length} 条补丁记录');
      }
    } on PatchVaultException catch (e) {
      if (mounted) AppSnackBar.error(context, e.message);
    } finally {
      await _reload();
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = '';
        });
      }
    }
  }

  /// 还原前哈希漂移：列出被改动的文件，用户明确点「仍要还原」才继续。
  Future<bool> _confirmDrift(List<PatchTransaction> txs) async {
    final svc = const PatchRollbackService();
    final all = <PatchDrift>[];
    for (final tx in txs) {
      all.addAll(await svc.checkDrift(tx));
    }
    if (all.isEmpty) return true;
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('有文件在打补丁后被改动过'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Text(
                  '还原会用备份覆盖这些文件，你在打补丁之后所做的改动会丢失：\n\n'
                  '${all.map((d) => '· ${d.relativePath}').join('\n')}\n\n'
                  '如果不确定，请先自行备份这些文件。',
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('先不还原')),
              FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.dangerRed),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('仍要还原')),
            ],
          ),
        ) ??
        false;
    return ok;
  }

  // ═══════════════════════════ 转移 / 移除 ═══════════════════════════

  Future<void> _onTransfer(PatchRecord record) async {
    final dirs = _dirs;
    if (dirs == null) return;
    final newPath = await PatchTransferDialog.show(
      context: context,
      sourcePath: record.sourcePath,
      defaultTargetDir: dirs.transferDir,
    );
    if (newPath == null || newPath.isEmpty) return;
    try {
      int size = record.sizeBytes;
      int mtime = record.mtimeMs;
      String sha = record.sha256;
      if (!record.isDirectory) {
        final st = await File(newPath).stat();
        size = st.size;
        mtime = st.modified.millisecondsSinceEpoch;
        sha = await PatchVaultIndex.sha256(newPath);
      }
      await _index.updateRecord(
        widget.game.gameId,
        record.copyWith(
          sourcePath: newPath,
          fileName: path.basename(newPath),
          sizeBytes: size,
          mtimeMs: mtime,
          sha256: sha,
          status: record.status == PatchVaultStatus.missing
              ? PatchVaultStatus.registered
              : record.status,
        ),
      );
      await _reload();
      if (mounted) AppSnackBar.success(context, '已转移并同步登记路径');
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '同步登记失败：$e');
    }
  }

  Future<void> _onRemove(PatchRecord record) async {
    if (appliedCountOf(record.id) > 0) {
      AppSnackBar.warning(context, '该补丁已应用，请先「撤销」再移除登记');
      return;
    }
    await _index.removeRecord(widget.game.gameId, record.id);
    await _reload();
    if (mounted) AppSnackBar.info(context, '已移除登记（补丁文件本身未删除）');
  }

  Future<void> _openDir(String dir) async {
    if (dir.isEmpty) return;
    try {
      // explorer 不接受 \\?\ 前缀（game_detail_dialog.dart:1024 的历史坑）
      final clean = dir.replaceFirst(r'\\?\', '');
      await Process.start('explorer', <String>[clean]);
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '打开目录失败：$e');
    }
  }

  // ═══════════════════════════ UI ═══════════════════════════

  @override
  Widget build(BuildContext context) {
    final dirs = _dirs;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 920,
          height: 660,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppStyle.rLg),
            border: Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline),
            boxShadow: AppStyle.e3,
          ),
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: 12),
              _tipBar(),
              const SizedBox(height: 10),
              if (dirs != null) _pathRow(dirs),
              const SizedBox(height: 10),
              _actionRow(),
              const SizedBox(height: 10),
              Expanded(child: _list()),
              const SizedBox(height: 8),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Row(
        children: [
          Icon(Icons.extension_outlined, size: 22, color: AppColors.titleBrown),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('补丁管理',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppColors.titleBrown)),
                Text('当前游戏：${widget.game.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.secondaryText)),
              ],
            ),
          ),
          if (_manifest.installed.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.successGreen.withOpacity(0.10),
                borderRadius: BorderRadius.circular(AppStyle.rSm),
              ),
              child: Text('已应用 ${_manifest.installed.length} 条',
                  style: TextStyle(
                      fontSize: 11, color: AppColors.successGreen)),
            ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.secondaryText,
            splashRadius: 18,
          ),
        ],
      );

  Widget _tipBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withOpacity(0.08),
          borderRadius: BorderRadius.circular(AppStyle.rSm),
          border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined,
                size: 17, color: AppColors.accentCyan),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                '打补丁前，建议先到游戏目录查看是否有游戏或补丁的说明文件，按其要求操作。'
                '本面板只负责整理文件、给出常见习惯下的落点建议，最终位置由你确认。',
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.primaryText),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: () => _openDir(_dirs?.launchDir ?? ''),
              icon: const Icon(Icons.folder_open_outlined, size: 14),
              label: const Text('打开游戏目录',
                  style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(20, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 9),
              ),
            ),
          ],
        ),
      );

  Widget _pathRow(GameDirs dirs) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.buttonBackground,
          borderRadius: BorderRadius.circular(AppStyle.rSm),
          border: Border.all(
              color: AppColors.borderLight, width: AppStyle.wHairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('启动程序目录（备份与转移默认位置）：${dirs.launchDir}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: AppColors.secondaryText)),
            if (dirs.rootsDiffer)
              Text('游戏本体根：${dirs.bodyRoot}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.secondaryText)),
            if (dirs.warning.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(dirs.warning,
                    style: TextStyle(
                        fontSize: 10.5, color: AppColors.secondaryText)),
              ),
          ],
        ),
      );

  Widget _actionRow() => Row(
        children: [
          FilledButton.icon(
            onPressed: _busy || _loading ? null : _importFiles,
            icon: const Icon(Icons.file_open_outlined, size: 15),
            label: const Text('导入补丁文件', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _busy || _loading ? null : _importFolder,
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 15),
            label: const Text('导入补丁文件夹', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _busy || _loading || _manifest.installed.isEmpty
                ? null
                : _onRestoreAll,
            icon: const Icon(Icons.settings_backup_restore_outlined, size: 15),
            label: const Text('一键恢复原版', style: TextStyle(fontSize: 12)),
          ),
        ],
      );

  Widget _list() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_fatal != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 30, color: AppColors.dangerRed),
            const SizedBox(height: 10),
            SizedBox(
              width: 520,
              child: Text(_fatal!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.primaryText)),
            ),
          ],
        ),
      );
    }
    if (_records.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 34, color: AppColors.placeholderText),
            const SizedBox(height: 10),
            Text('还没有登记补丁',
                style: TextStyle(
                    fontSize: 14, color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            Text('点上方「导入补丁文件 / 文件夹」，把散落在各处的补丁收进来。'
                '导入只登记路径，不会复制、移动或解压。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: AppColors.secondaryText)),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _records.length,
      itemBuilder: (context, i) {
        final r = _records[i];
        return PatchRecordCard(
          record: r,
          check: _checks[r.id] ??
              const PatchRecordCheck(
                  exists: true, changed: false, message: ''),
          appliedTxCount: appliedCountOf(r.id),
          busy: _busy,
          onApply: () => _onApply(r),
          onUndo: () => _onUndo(r),
          onTransfer: () => _onTransfer(r),
          onRemove: () => _onRemove(r),
          onOpenContaining: () =>
              _openDir(path.dirname(r.sourcePath)),
        );
      },
    );
  }

  Widget _footer() {
    final recover = _recoverReport;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recover != null && recover.hasWork) ...[
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: recover.ok
                  ? AppColors.successGreen.withOpacity(0.07)
                  : AppColors.dangerRed.withOpacity(0.07),
              borderRadius: BorderRadius.circular(AppStyle.rSm),
            ),
            child: Text(
              recover.ok
                  ? '已自动收拾 ${recover.handledTxIds.length} 条上次未完成的事务'
                  : [...recover.failures, ...recover.warnings].join('\n'),
              style: TextStyle(
                  fontSize: 11,
                  color: recover.ok
                      ? AppColors.successGreen
                      : AppColors.dangerRed),
            ),
          ),
          const SizedBox(height: 6),
        ],
        if (_progress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(_progress,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.secondaryText)),
              ],
            ),
          ),
        Text(
          '边界说明：EXE 安装器不代跑、7z/RAR 需自行解压；这两类以及你在本功能之外'
          '手动打过的补丁没有基线，无法自动回退。撤销只还原本功能写过的文件。',
          style: TextStyle(
              fontSize: 10.5, height: 1.4, color: AppColors.secondaryText),
        ),
      ],
    );
  }
}

/// 磁盘预检：×1.15 + 256MB（对齐项目既有空间账）。
///
/// 抽出来是为了让门禁闭包保持可读，且 FFI 查询失败时**不静默放行**。
class DiskSpaceInfoProbe {
  static int requiredBytes(PatchPlan plan) =>
      ((plan.backupBytes + plan.totalBytes) * 1.15).ceil() + 256 * 1024 * 1024;

  static Future<bool> hasEnough(String dir, PatchPlan plan) async {
    try {
      final info = await PathValidator.getDiskSpaceInfo(dir);
      if (!info.isAvailable) return false;
      return info.hasEnoughSpace(requiredBytes(plan));
    } catch (_) {
      // 查询能力不可用时退化为「未知放行」，与项目既有语义一致
      return true;
    }
  }
}
