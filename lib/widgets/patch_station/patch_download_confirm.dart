import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../../models/patch_resource.dart';
import '../../services/patch/patch_download_core.dart';
import '../../services/patch/patch_save_location.dart';
import '../../services/path_validator.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import 'patch_site_logo.dart';

/// 「开始下载」前的确认框（2026-11-10 用户定调：与探索库下载游戏本体一致）。
///
/// ## 为什么必须有这一步
///
/// 补丁下完就是**成品**（有的直链会失效，删了补不回来），落点错了要用户
/// 自己去翻盘符找。⛔ 所以不在面板里常驻一行「保存到 …」，而是**下载前**
/// 用这个确认框让用户看清「下什么、多大、放哪」，并且可以当场换目录。
///
/// 与此前的 `patch_save_dir_dialog` 的区别：那个只有目录选择，不知道要下
/// 什么；这个把补丁信息、包名预览、目标盘余量一起摊开。
///
/// ## 视觉语言
///
/// 刻意对齐 `InstallConfirmationDialog`（游戏本体下载：620×N、边框卡片、
/// 底部「取消 / 开始」两枚按钮）——用户在两个下载入口看到的是同一套东西。
///
/// 🔴 文案边界：本框只承诺「下载 + 可选解压到同一目录」，⛔ 不出现
/// 「安装 / 应用 / 覆盖游戏」这类字样，因为补丁站不具备那种能力。
class PatchDownloadConfirm extends StatefulWidget {
  const PatchDownloadConfirm({
    super.key,
    required this.resource,
    this.initialDir,
    this.willExtract = true,
  });

  final PatchResource resource;
  final String? initialDir;
  final bool willExtract;

  /// 返回用户选定的目录；`null` = 取消
  static Future<String?> show({
    required BuildContext context,
    required PatchResource resource,
    String? initialDir,
    bool willExtract = true,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PatchDownloadConfirm(
        resource: resource,
        initialDir: initialDir,
        willExtract: willExtract,
      ),
    );
  }

  @override
  State<PatchDownloadConfirm> createState() => _PatchDownloadConfirmState();
}

class _PatchDownloadConfirmState extends State<PatchDownloadConfirm> {
  String? _dir;
  int? _freeBytes;
  bool _picking = false;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dir = widget.initialDir;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    var dir = widget.initialDir;
    if (dir == null || dir.trim().isEmpty) {
      try {
        dir = await PatchSaveLocation.instance.resolve();
      } catch (_) {
        // 探针环境没有 SharedPreferences 平台实现 ⇒ 退回默认建议目录
        try {
          dir = PatchSaveLocation.suggestedDir;
        } catch (_) {
          dir = null;
        }
      }
    }
    if (!mounted) return;
    setState(() => _dir = dir);
    await _refreshSpace();
  }

  Future<void> _refreshSpace() async {
    final dir = _dir;
    if (dir == null || dir.trim().isEmpty) return;
    try {
      final info = await PathValidator.getDiskSpaceInfo(dir);
      if (!mounted) return;
      setState(() =>
          _freeBytes = info.freeSpaceBytes >= 0 ? info.freeSpaceBytes : null);
    } catch (_) {
      if (mounted) setState(() => _freeBytes = null);
    }
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final picked = await PatchSaveLocation.instance.pick(initialDir: _dir);
      if (!mounted) return;
      if (picked != null) {
        setState(() {
          _dir = picked;
          _error = null;
        });
        await _refreshSpace();
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _confirm() async {
    final dir = (_dir ?? '').trim();
    if (dir.isEmpty) {
      setState(() => _error = '请先选择保存目录');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await PatchSaveLocation.instance.ensureDir(dir) &&
        await PatchSaveLocation.instance.isWritable(dir);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _checking = false;
        _error = '这个目录不可写（只读盘 / 权限不足），换一个再试';
      });
      return;
    }
    Navigator.of(context).pop(dir);
  }

  /// 完整落点预览：`<目录>\<包名>`
  String _targetFile() {
    final dir = _dir ?? '';
    if (dir.trim().isEmpty) return '';
    final url = (widget.resource.directUrl ?? '').trim();
    final name = patchFileName(widget.resource, url);
    return path.join(dir, name);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.resource;
    final sizeBytes = r.sizeBytes;
    final insufficient = sizeBytes != null &&
        _freeBytes != null &&
        _freeBytes! < (sizeBytes * 1.05).round();

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          constraints: const BoxConstraints(maxHeight: 640),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.4),
            borderRadius: BorderRadius.circular(AppRadius.xl),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.28),
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPatchCard(),
                      const SizedBox(height: 20),
                      _buildLocation(),
                      const SizedBox(height: 14),
                      _buildTargetPreview(),
                      const SizedBox(height: 12),
                      _buildSizeRow(insufficient),
                    ],
                  ),
                ),
              ),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1.2),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(Icons.download_rounded,
              size: 18, color: AppColors.secondaryText),
          const SizedBox(width: 10),
          Text(
            '确认下载',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatchCard() {
    final r = widget.resource;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border.all(color: AppColors.border, width: 1.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PatchSiteLogo(site: r.site, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      r.site.displayName,
                      style: AppStyles.bodyRegular.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: PatchSiteLogo.colorOf(r.site),
                      ),
                    ),
                    const SizedBox(width: 6),
                    for (final k in r.badgeLabels.take(2)) ...[
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.secondaryText.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: Text(
                          k,
                          style: AppStyles.bodyRegular.copyWith(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (r.sizeLabel.isNotEmpty)
                      Text(
                        r.sizeLabel,
                        style: AppStyles.bodyRegular.copyWith(
                          fontSize: 11,
                          color: AppColors.secondaryText,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  r.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocation() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.folder_outlined,
                size: 15, color: AppColors.secondaryText),
            const SizedBox(width: 7),
            Text(
              '保存位置',
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.secondaryText,
              ),
            ),
            const Spacer(),
            Text(
              '与下载游戏本体一致，可自选',
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 11,
                color: AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: _picking ? null : _pick,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.buttonBackground,
                      border: Border.all(color: AppColors.border, width: 1.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        if (_picking)
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  AppColors.secondaryText),
                            ),
                          )
                        else
                          Icon(Icons.folder_open_rounded,
                              size: 15, color: AppColors.secondaryText),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            (_dir ?? '').trim().isEmpty ? '点击选择目录…' : _dir!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppStyles.bodyRegular.copyWith(
                              fontSize: 12.5,
                              color: AppColors.primaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right_rounded,
                            size: 16,
                            color: AppColors.secondaryText.withOpacity(0.7)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _ghostButton(
              label: '默认位置',
              onTap: () async {
                String d;
                try {
                  d = PatchSaveLocation.suggestedDir;
                } catch (_) {
                  return;
                }
                setState(() {
                  _dir = d;
                  _error = null;
                });
                await _refreshSpace();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTargetPreview() {
    final target = _targetFile();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border.withOpacity(0.5), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.willExtract ? '将写入（并解压到同名文件夹）' : '将写入',
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryText.withOpacity(0.75),
            ),
          ),
          const SizedBox(height: 5),
          SelectableText(
            target.isEmpty ? '—' : target,
            maxLines: 2,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 11.5,
              height: 1.4,
              fontFamily: 'Consolas',
              color: AppColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSizeRow(bool insufficient) {
    final r = widget.resource;
    final sizeText = r.sizeLabel.isEmpty ? '未知（不影响下载）' : r.sizeLabel;
    final freeText =
        _freeBytes == null ? '未知' : PathValidator.formatFileSize(_freeBytes!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.cloud_download_outlined,
                size: 14, color: AppColors.secondaryText.withOpacity(0.8)),
            const SizedBox(width: 5),
            Text('下载包体积 ',
                style: AppStyles.bodyRegular
                    .copyWith(fontSize: 11.5, color: AppColors.secondaryText)),
            Text(sizeText,
                style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText)),
            const SizedBox(width: 16),
            Icon(Icons.storage_outlined,
                size: 14, color: AppColors.secondaryText.withOpacity(0.8)),
            const SizedBox(width: 5),
            Text('目标盘可用 ',
                style: AppStyles.bodyRegular
                    .copyWith(fontSize: 11.5, color: AppColors.secondaryText)),
            Text(freeText,
                style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText)),
          ],
        ),
        if (insufficient) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14, color: AppColors.dangerRed),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '目标盘空间可能不足（解压还要额外空间），建议换到别的盘',
                  style: AppStyles.bodyRegular
                      .copyWith(fontSize: 11.5, color: AppColors.dangerRed),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 14, color: AppColors.dangerRed),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _error!,
                  style: AppStyles.bodyRegular
                      .copyWith(fontSize: 11.5, color: AppColors.dangerRed),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.info_outline_rounded,
                size: 13, color: AppColors.secondaryText.withOpacity(0.55)),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '只下载，不会装进游戏目录，也不会启动游戏',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11,
                  color: AppColors.secondaryText.withOpacity(0.7),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border.withOpacity(0.6), width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _ghostButton(
            label: '取消',
            onTap: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 12),
          _primaryButton(
            label: _checking ? '检查中…' : '开始下载',
            icon: Icons.download_rounded,
            enabled: !_checking && (_dir ?? '').trim().isNotEmpty,
            onTap: _confirm,
          ),
        ],
      ),
    );
  }

  Widget _ghostButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            border: Border.all(color: AppColors.border, width: 1.1),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            label,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: const Duration(milliseconds: 140),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.selectedAccent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                  color: AppColors.border.withOpacity(0.35), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
