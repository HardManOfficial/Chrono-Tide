/// 补丁应用预览 / 二次确认页（PATCH-VAULT）。
///
/// 🔴 **本页不写游戏目录**：zip 只解到应用数据目录的临时隔离区，落点清单是只读探测。
/// 🔴 推荐落点**只是默认选中**，下拉随时可改；猜错就是覆盖玩家的游戏本体。
/// 🔴 二次确认同时显示「目标游戏名 + gameId + 落点绝对路径」，
/// 从结构上防住用户口述的「打错游戏 / 打错位置」。
///
/// 返回 [PatchApplyConfirm] 表示用户已确认，调用方负责执行事务并清理
/// [PatchApplyConfirm.source]；取消返回 null。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import '../../services/patch/patch_preview.dart';
import '../../services/patch_vault/game_dirs.dart';
import '../../services/patch_vault/patch_apply_plan.dart';
import '../../services/patch_vault/patch_inspector.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../app_dialog.dart';

class PatchApplyConfirm {
  const PatchApplyConfirm({
    required this.source,
    required this.plan,
    required this.inspection,
  });

  final PatchApplySource source;
  final PatchPlan plan;
  final PatchInspection inspection;
}

class PatchApplyPreview extends StatefulWidget {
  const PatchApplyPreview({
    super.key,
    required this.record,
    required this.dirs,
    required this.gameId,
    required this.gameTitle,
    required this.indexRoot,
    required this.gameExeNames,
    required this.gameTopDirs,
    this.debugSkipLoad = false,
  });

  final PatchRecord record;
  final GameDirs dirs;
  final String gameId;
  final String gameTitle;
  final String indexRoot;
  final List<String> gameExeNames;
  final List<String> gameTopDirs;

  /// 仅渲染探针用：跳过异步 IO（flutter_tester 的 fake-async 不推进真实 IO）。
  final bool debugSkipLoad;

  static Future<PatchApplyConfirm?> show({
    required BuildContext context,
    required PatchRecord record,
    required GameDirs dirs,
    required String gameId,
    required String gameTitle,
    required String indexRoot,
    required List<String> gameExeNames,
    required List<String> gameTopDirs,
    bool debugSkipLoad = false,
  }) =>
      showAppDialog<PatchApplyConfirm>(
        context: context,
        barrierDismissible: true,
        builder: (_) => PatchApplyPreview(
          record: record,
          dirs: dirs,
          gameId: gameId,
          gameTitle: gameTitle,
          indexRoot: indexRoot,
          gameExeNames: gameExeNames,
          gameTopDirs: gameTopDirs,
          debugSkipLoad: debugSkipLoad,
        ),
      );

  @override
  State<PatchApplyPreview> createState() => _PatchApplyPreviewState();
}

class _PatchApplyPreviewState extends State<PatchApplyPreview> {
  bool _loading = true;
  bool _replanning = false;
  String? _error;
  PatchInspection? _inspection;
  PatchApplySource? _source;
  PatchPlan? _plan;
  String? _recommendedRoot;
  PatchTargetChoice _choice = PatchTargetChoice.launchDir;
  bool _handedOff = false;
  late final TextEditingController _customCtrl;

  @override
  void initState() {
    super.initState();
    _customCtrl = TextEditingController(text: widget.dirs.launchDir);
    if (widget.debugSkipLoad) {
      _loading = false;
    } else {
      _prepare();
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    final src = _source;
    if (!_handedOff && src != null) {
      unawaited(disposeApplySource(src));
    }
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final inspector = PatchInspector(
        gameExeNames: widget.gameExeNames,
        gameTopDirs: widget.gameTopDirs,
      );
      final ins = await inspector.inspect(widget.record.sourcePath);
      if (!mounted) return;
      if (!ins.isApplyable || ins.preview == null) {
        setState(() {
          _loading = false;
          _inspection = ins;
          _error = ins.warnings.isNotEmpty
              ? ins.warnings.join('\n')
              : '该补丁形态无法自动辅助应用，请先自行查看说明';
        });
        return;
      }
      final recommended = recommendTargetRoot(ins.preview!, widget.dirs);
      _recommendedRoot = recommended;
      if (recommended != null &&
          path.normalize(recommended).toLowerCase() ==
              path.normalize(widget.dirs.bodyRoot).toLowerCase()) {
        _choice = PatchTargetChoice.bodyRoot;
      }

      final src = await prepareApplySource(
        sourcePath: widget.record.sourcePath,
        isDirectory: widget.record.isDirectory,
        stagingRoot: path.join(widget.indexRoot, 'tmp'),
        txId: 'preview_${widget.record.id}',
        gameExeNames: widget.gameExeNames,
        gameTopDirs: widget.gameTopDirs,
        preview: ins.preview!,
        relativePaths: ins.relativePaths,
      );
      _source = src;
      _inspection = ins;
      await _rebuildPlan();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法生成应用预览：$e';
        });
      }
    }
  }

  Future<void> _rebuildPlan() async {
    final src = _source;
    if (src == null) return;
    setState(() => _replanning = true);
    final root = resolveTargetRoot(
      _choice,
      widget.dirs,
      customDir: _customCtrl.text.trim(),
    );
    final plan = await buildApplyPlan(
      source: src,
      targetRoot: root,
      dirs: widget.dirs,
    );
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _replanning = false;
    });
  }

  void _onChoiceChanged(PatchTargetChoice? v) {
    if (v == null) return;
    setState(() => _choice = v);
    _rebuildPlan();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 780,
          height: 620,
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
              const SizedBox(height: 12),
              Expanded(child: _body()),
              const SizedBox(height: 12),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('预览并确认补丁应用',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  color: AppColors.titleBrown)),
          const SizedBox(height: 4),
          Text(
            '目标游戏：${widget.gameTitle}　·　gameId：${widget.gameId.isEmpty ? "（缺失）" : widget.gameId}',
            style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
          ),
          Text('补丁文件：${widget.record.fileName}',
              style: TextStyle(fontSize: 12, color: AppColors.secondaryText)),
        ],
      );

  Widget _tipBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.accentCyan.withOpacity(0.08),
          borderRadius: BorderRadius.circular(AppStyle.rSm),
          border: Border.all(color: AppColors.accentCyan.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.menu_book_outlined,
                size: 16, color: AppColors.accentCyan),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '打补丁前，建议先到游戏目录查看是否有游戏或补丁的说明文件，按其要求操作。'
                '特殊情况请以说明为准，本页给的是「常见习惯」下的默认建议。',
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.primaryText),
              ),
            ),
          ],
        ),
      );

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 28, color: AppColors.dangerRed),
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(fontSize: 13, color: AppColors.dangerRed)),
            if (_inspection?.hasReadme == true) ...[
              const SizedBox(height: 12),
              Text('包内说明文件：${_inspection!.readmeNames.join('、')}',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.secondaryText)),
            ],
          ],
        ),
      );
    }
    final plan = _plan;
    final ins = _inspection;
    if (plan == null || ins == null) {
      return const Center(child: Text('预览未生成'));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 300, child: _leftPane(plan, ins)),
        const SizedBox(width: 14),
        Expanded(child: _fileList(plan)),
      ],
    );
  }

  Widget _leftPane(PatchPlan plan, PatchInspection ins) =>
      SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('识别结果（仅供参考）',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            Text('${ins.kind.label} · ${ins.container.label}',
                style: TextStyle(fontSize: 13, color: AppColors.primaryText)),
            const SizedBox(height: 4),
            Text(ins.reason,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: AppColors.secondaryText)),
            if (ins.hasReadme) ...[
              const SizedBox(height: 6),
              Text('说明文件：${ins.readmeNames.join('、')}',
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.successGreen)),
            ],
            const SizedBox(height: 16),
            Text('落点（可改）',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            DropdownButton<PatchTargetChoice>(
              value: _choice,
              isExpanded: true,
              isDense: true,
              items: PatchTargetChoice.values
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(c.label,
                            style: const TextStyle(fontSize: 12)),
                      ))
                  .toList(),
              onChanged: _replanning ? null : _onChoiceChanged,
            ),
            if (_choice == PatchTargetChoice.custom) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _customCtrl,
                style: TextStyle(fontSize: 11, color: AppColors.primaryText),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.all(8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppStyle.rSm)),
                ),
                onSubmitted: (_) => _rebuildPlan(),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _replanning ? null : _rebuildPlan,
                  child: const Text('应用自定义目录',
                      style: TextStyle(fontSize: 11)),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              _recommendedRoot == null
                  ? '⚠ 未识别到明确形态，未推荐落点；请自行确认'
                  : '推荐：$_recommendedRoot',
              style: TextStyle(
                  fontSize: 10.5,
                  height: 1.4,
                  color: _recommendedRoot == null
                      ? AppColors.dangerRed
                      : AppColors.secondaryText),
            ),
            const SizedBox(height: 4),
            Text('实际写入根目录：\n${plan.targetRoot}',
                style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: AppColors.primaryText)),
            if (widget.dirs.rootsDiffer) ...[
              const SizedBox(height: 6),
              Text('启动目录与游戏本体根不同，备份固定放在启动目录下的 .CTPatch/。',
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.4,
                      color: AppColors.secondaryText)),
            ],
            const SizedBox(height: 14),
            _statLine('写入文件', '${plan.entries.length} 个'),
            _statLine('其中覆盖', '${plan.overwriteCount} 个'),
            _statLine('写入体积', formatPatchPreviewBytes(plan.totalBytes)),
            _statLine('需备份体积', formatPatchPreviewBytes(plan.backupBytes)),
            if (_replanning)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (plan.blockedReasons.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...plan.blockedReasons.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('⛔ $r',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.dangerRed)),
                  )),
            ],
            if (plan.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...plan.warnings.map((w) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· $w',
                        style: TextStyle(
                            fontSize: 10.5,
                            height: 1.35,
                            color: AppColors.secondaryText)),
                  )),
            ],
          ],
        ),
      );

  Widget _statLine(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k,
                style: TextStyle(
                    fontSize: 11, color: AppColors.secondaryText)),
            Text(v,
                style: TextStyle(
                    fontSize: 11, color: AppColors.primaryText)),
          ],
        ),
      );

  Widget _fileList(PatchPlan plan) => Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderLight),
          borderRadius: BorderRadius.circular(AppStyle.rSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text('逐文件清单（默认展开，请核对）',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText)),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: plan.entries.length,
                itemBuilder: (context, i) {
                  final e = plan.entries[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: (e.isOverwrite
                                        ? AppColors.dangerRed
                                        : AppColors.successGreen)
                                    .withOpacity(0.10),
                                borderRadius:
                                    BorderRadius.circular(AppStyle.rSm),
                              ),
                              child: Text(
                                e.isOverwrite ? '覆盖' : '新增',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: e.isOverwrite
                                      ? AppColors.dangerRed
                                      : AppColors.successGreen,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(e.relativePath,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.primaryText)),
                            ),
                            Text(formatPatchPreviewBytes(e.sizeBytes),
                                style: TextStyle(
                                    fontSize: 10,
                                    color: AppColors.secondaryText)),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(e.targetPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10,
                                color: AppColors.secondaryText)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );

  Widget _footer() {
    final plan = _plan;
    final canConfirm = !_loading &&
        !_replanning &&
        _error == null &&
        plan != null &&
        !plan.isBlocked &&
        !plan.isEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.dangerRed.withOpacity(0.06),
            borderRadius: BorderRadius.circular(AppStyle.rSm),
            border:
                Border.all(color: AppColors.dangerRed.withOpacity(0.30)),
          ),
          child: Text(
            '二次确认：即将把补丁写入「${plan?.targetRoot ?? "（未选择）"}」，'
            '目标游戏「${widget.gameTitle}」。同名文件会被替换；'
            '应用前会自动备份被覆盖的原文件，之后可撤销或一键恢复原版。'
            'EXE 安装器与本功能之外手动打过的补丁不在此列。',
            style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: AppColors.primaryText),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: canConfirm
                  ? () {
                      _handedOff = true;
                      Navigator.of(context).pop(PatchApplyConfirm(
                        source: _source!,
                        plan: plan,
                        inspection: _inspection!,
                      ));
                    }
                  : null,
              child: const Text('确认应用'),
            ),
          ],
        ),
      ],
    );
  }
}
