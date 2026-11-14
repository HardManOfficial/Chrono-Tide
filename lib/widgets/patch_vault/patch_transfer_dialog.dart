/// 补丁文件转移对话框（PATCH-VAULT）。
///
/// 交互骨架对齐详情页「移动游戏位置」（`game_detail_dialog.dart:819-887`：
/// 守卫 → 选目标 → 二次确认 → 独立进度 → 结果提示），**差异**：
/// - 目标目录**预填** `<启动程序目录>/补丁/`（原流程无预填）；
/// - 语义是单文件 / 单文件夹搬运，⛔ 不调用 `GameMoveService`（它会改 game.json）；
/// - 默认**移动**（用户 2026-11-11 拍板），但保留「改为复制」选项。
///
/// 返回新的绝对路径；取消或失败返回 null（失败信息在框内显示，不吞）。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../services/patch_vault/patch_transfer_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../app_dialog.dart';

class PatchTransferDialog extends StatefulWidget {
  const PatchTransferDialog({
    super.key,
    required this.sourcePath,
    required this.defaultTargetDir,
  });

  final String sourcePath;
  final String defaultTargetDir;

  static Future<String?> show({
    required BuildContext context,
    required String sourcePath,
    required String defaultTargetDir,
  }) =>
      showAppDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (_) => PatchTransferDialog(
          sourcePath: sourcePath,
          defaultTargetDir: defaultTargetDir,
        ),
      );

  @override
  State<PatchTransferDialog> createState() => _PatchTransferDialogState();
}

class _PatchTransferDialogState extends State<PatchTransferDialog> {
  late final TextEditingController _targetCtrl;
  bool _move = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _targetCtrl = TextEditingController(text: widget.defaultTargetDir);
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDir() async {
    final picked = await FilePicker.platform.getDirectoryPath();
    if (picked != null && picked.isNotEmpty && mounted) {
      _targetCtrl.text = picked;
      setState(() => _error = null);
    }
  }

  Future<void> _run() async {
    final target = _targetCtrl.text.trim();
    if (target.isEmpty) {
      setState(() => _error = '请先选择目标目录');
      return;
    }
    if (!File(widget.sourcePath).existsSync() &&
        !Directory(widget.sourcePath).existsSync()) {
      setState(() => _error = '源文件已不存在，无法转移');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await const PatchTransferService().transfer(
        sourcePath: widget.sourcePath,
        targetDir: target,
        move: _move,
      );
      if (!mounted) return;
      // 结果由主面板用通知条呈现；这里直接返回新路径，避免多余等待。
      Navigator.of(context).pop(result.newPath);
    } on PatchTransferException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '转移失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = path.basename(widget.sourcePath);
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          constraints: const BoxConstraints(maxHeight: 460),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppStyle.rLg),
            border: Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline),
            boxShadow: AppStyle.e3,
          ),
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('转移补丁文件',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.titleBrown)),
              const SizedBox(height: 4),
              Text('把散落的补丁收到你想放的位置，不必回资源管理器里拖。',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.secondaryText)),
              const SizedBox(height: 16),
              _label('补丁文件'),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: AppColors.primaryText)),
              const SizedBox(height: 4),
              Text(widget.sourcePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: AppColors.secondaryText)),
              const SizedBox(height: 16),
              _label('目标目录（默认：启动程序目录下的「补丁」文件夹）'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _targetCtrl,
                      enabled: !_busy,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.primaryText),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppStyle.rSm),
                          borderSide:
                              BorderSide(color: AppColors.borderLight),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : _pickDir,
                    child: const Text('浏览', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                value: _move,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _move = v ?? true),
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('移动原文件（取消勾选＝改为复制，保留原文件）',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.primaryText)),
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.accentCyan.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(AppStyle.rSm),
                  border: Border.all(
                      color: AppColors.accentCyan.withOpacity(0.35)),
                ),
                child: Text(
                  '目标位置若已有同名文件，不会覆盖，会自动改名（_2、_3…）。'
                  '转移后登记路径会自动更新。',
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: AppColors.primaryText),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: TextStyle(fontSize: 12, color: AppColors.dangerRed)),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _busy ? null : _run,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_move ? '开始移动' : '开始复制'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.secondaryText)),
      );
}
