/// 单条补丁登记卡片（PATCH-VAULT 面板主体）。
///
/// 🔴 状态文案克制：⛔ 不出现「已备份 / 可回滚」这类会诱导用户放心覆盖的承诺。
/// 🔴 安装器 / 7z / rar 明确标注「无法自动回退」「需自行解压」，不假装已管理。

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import '../../services/patch/patch_preview.dart';
import '../../services/patch_vault/patch_vault_index.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';

String formatVaultBytes(int bytes) =>
    formatPatchPreviewBytes(bytes);

class PatchRecordCard extends StatelessWidget {
  const PatchRecordCard({
    super.key,
    required this.record,
    required this.check,
    required this.appliedTxCount,
    required this.busy,
    required this.onApply,
    required this.onUndo,
    required this.onTransfer,
    required this.onRemove,
    required this.onOpenContaining,
  });

  final PatchRecord record;
  final PatchRecordCheck check;
  final int appliedTxCount;
  final bool busy;

  final VoidCallback onApply;
  final VoidCallback onUndo;
  final VoidCallback onTransfer;
  final VoidCallback onRemove;
  final VoidCallback onOpenContaining;

  @override
  Widget build(BuildContext context) {
    final effectiveMissing = !check.exists;
    final cannotApply = effectiveMissing ||
        !record.container.canApply ||
        record.container.isInstaller;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(AppStyle.rMd),
        border: Border.all(color: AppColors.borderLight, width: AppStyle.wHairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                record.isDirectory
                    ? Icons.folder_open_outlined
                    : Icons.inventory_2_outlined,
                size: 18,
                color: AppColors.border,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  record.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              _statusChip(),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _tag(record.container.label, AppColors.border),
              if (record.kind != PatchKind.unknown)
                _tag(record.kind.label, AppColors.accentCyan),
              if (record.hasReadme) _tag('含说明文件', AppColors.successGreen),
              if (record.hasExe) _tag('含 EXE', AppColors.dangerRed),
              _tag(formatVaultBytes(record.sizeBytes), AppColors.secondaryText),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  record.sourcePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppColors.secondaryText),
                ),
              ),
              TextButton(
                onPressed: onOpenContaining,
                style: TextButton.styleFrom(
                  minimumSize: const Size(20, 20),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: Text('打开所在目录',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.accentCyan)),
              ),
            ],
          ),
          if (effectiveMissing)
            _note('源文件已不存在，请重新导入或用「转移」重新定位', AppColors.dangerRed)
          else if (check.changed)
            _note(check.message, AppColors.dangerRed)
          else if (record.container.needsManualExtract)
            _note('请先自行解压，再以「文件夹」形式导入；本功能不解析该格式',
                AppColors.secondaryText)
          else if (record.container.isInstaller)
            _note('本软件不代跑安装器，也不会记录它做的改动 ⇒ 无法自动回退',
                AppColors.dangerRed)
          else if (record.note.isNotEmpty)
            _note(record.note, AppColors.secondaryText),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: busy || cannotApply ? null : onApply,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(20, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('应用补丁', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: busy || appliedTxCount == 0 ? null : onUndo,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(20, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: Text('撤销 ($appliedTxCount)',
                    style: const TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy || !check.exists ? null : onTransfer,
                style: TextButton.styleFrom(
                  minimumSize: const Size(20, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('转移', style: TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : onRemove,
                style: TextButton.styleFrom(
                  minimumSize: const Size(20, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text('移除登记',
                    style: TextStyle(fontSize: 12, color: AppColors.dangerRed)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusChip() {
    final String label;
    final Color color;
    if (!check.exists) {
      label = PatchVaultStatus.missing.label;
      color = AppColors.dangerRed;
    } else if (appliedTxCount > 0) {
      label = PatchVaultStatus.applied.label;
      color = AppColors.successGreen;
    } else if (record.container.isInstaller ||
        record.container.needsManualExtract) {
      label = PatchVaultStatus.manual.label;
      color = AppColors.secondaryText;
    } else {
      label = PatchVaultStatus.registered.label;
      color = AppColors.secondaryText;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(AppStyle.rSm),
        border: Border.all(color: color.withOpacity(0.4), width: 0.5),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(AppStyle.rSm),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );

  Widget _note(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 13, color: color),
            const SizedBox(width: 5),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 11, color: color, height: 1.35)),
            ),
          ],
        ),
      );
}

/// 供「打开所在目录」使用：取补丁源路径的父目录。
String containingDirOf(PatchRecord r) => r.isDirectory
    ? path.dirname(r.sourcePath)
    : path.dirname(r.sourcePath);
