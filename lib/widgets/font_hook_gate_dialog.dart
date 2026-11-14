// font_hook_gate_dialog.dart
// 「是否安装改字体程序」的启动前引导（Phase 3 用户入口①）。
//
// 出现时机（由 library_page 的启动链路决定）：
//   · 用户**首次启动**某个尚未安装补丁的游戏时（`probe == notInstalled`）；
//   · 且该游戏未被标记「已决定过」（`FontOverridePrefs.isGateAnswered`）。
//
// 与方案 §10-P2-3 的关系：
//   P2-3 禁止的是「启动路径**静默自动补装**」（怕突发写盘 / UAC 失败）。
//   本引导是**用户显式勾选后才执行**的安装，不属于静默补装；
//   同时 `staleOrDamaged`（补丁残缺）**不进**本引导，避免启动时突发写盘 ——
//   残缺状态只由「更换字体」对话框处理。
//
// 返回 [FontHookGateResult]；调用方据此决定是否安装、是否记住决定。

import 'package:flutter/material.dart';

import '../services/font_compatibility_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';

/// 引导结果。
class FontHookGateResult {
  /// 是否安装改字体程序（= 勾选状态）。
  final bool install;

  /// 是否记住本次决定（不再询问该游戏）。
  final bool remember;

  const FontHookGateResult({required this.install, required this.remember});

  static const FontHookGateResult skipped =
      FontHookGateResult(install: false, remember: false);
}

class FontHookGateDialog extends StatefulWidget {
  final String gameTitle;

  /// `game.json.launch_path`（可选）。用于不兼容清单的 exe 名兜底匹配。
  final String launchPath;

  /// 是否已经为「不再询问」提供过默认勾选（首次出现时为 false）。
  final bool defaultRemember;

  const FontHookGateDialog({
    super.key,
    required this.gameTitle,
    this.launchPath = '',
    this.defaultRemember = false,
  });

  static Future<FontHookGateResult?> show({
    required BuildContext context,
    required String gameTitle,
    String launchPath = '',
    bool defaultRemember = false,
  }) {
    return showDialog<FontHookGateResult>(
      context: context,
      barrierDismissible: true,
      builder: (_) => FontHookGateDialog(
        gameTitle: gameTitle,
        launchPath: launchPath,
        defaultRemember: defaultRemember,
      ),
    );
  }

  @override
  State<FontHookGateDialog> createState() => _FontHookGateDialogState();
}

class _FontHookGateDialogState extends State<FontHookGateDialog> {
  late bool _install = true;
  late bool _remember = widget.defaultRemember;

  /// 本地不兼容清单命中结果（Phase 4.3）；只提示，不禁用「安装」勾选。
  late final FontCompatVerdict? _compat = FontCompatibilityService.instance
      .lookup(title: widget.gameTitle, exeName: widget.launchPath);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.shadowColor,
              offset: const Offset(0, 6),
              blurRadius: 16,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: _buildContent(),
            ),
            const SizedBox(height: 18),
            _buildFooter(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.placeholderCover, width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.font_download_outlined,
              size: 24, color: AppColors.brandBlue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('安装改字体程序',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryText,
                    )),
                const SizedBox(height: 2),
                Text(widget.gameTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: AppColors.secondaryText)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final compat = _compat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '检测到「${widget.gameTitle}」还没有安装字体器。\n'
          '安装后游戏里的文字会换用更清晰的中文字体，解决乱码、缺字、字体发虚；'
          '进游戏按 Insert 还能随时呼出字体面板换字体、调字形。',
          style: TextStyle(
              fontSize: 13.5,
              color: AppColors.primaryText,
              height: 1.65),
        ),
        const SizedBox(height: 14),
        if (compat != null) ...[
          _buildCompatNotice(compat),
          const SizedBox(height: 10),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.warningAmber.withOpacity(0.08),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border:
                Border.all(color: AppColors.warningAmber.withOpacity(0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined,
                      size: 15, color: AppColors.warningAmber),
                  const SizedBox(width: 6),
                  Text('请留意',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warningAmber)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '安装方式是在游戏目录放入一个字体程序（winmm.dll），'
                '这属于常见的「代理加载」做法。\n'
                '少数**联网 / 反作弊**游戏可能将其视为篡改而拒绝启动或报错，'
                '遇到这种情况请到「启动管理 → 字体替换 → 恢复」一键还原，'
                '游戏文件不会被改动。',
                style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.secondaryText,
                    height: 1.6),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _checkRow(
          label: '为「${widget.gameTitle}」安装字体器',
          subtitle: '自动识别你设置的启动程序，按它的位数安装对应组件',
          value: _install,
          onChanged: (v) => setState(() => _install = v),
        ),
        _checkRow(
          label: '不再提示',
          subtitle: '之后启动该游戏时不再询问',
          value: _remember,
          onChanged: (v) => setState(() => _remember = v),
        ),
      ],
    );
  }

  /// 已知不兼容提示（Phase 4.3，只提示、不禁用安装勾选）。
  Widget _buildCompatNotice(FontCompatVerdict v) {
    final color = v.isWarning ? AppColors.warningAmber : AppColors.infoBlue;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(v.isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(v.isWarning ? '已知不兼容' : '兼容性提示',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: color)),
                const SizedBox(height: 5),
                Text(
                  v.doc.isEmpty ? v.reason : '${v.reason}\n${v.doc}',
                  style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.secondaryText,
                      height: 1.6),
                ),
                const SizedBox(height: 4),
                Text('仍可继续安装；遇到问题可在「启动管理 → 字体替换 → 恢复」一键还原。',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.placeholderText,
                        height: 1.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _checkRow({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 34,
              height: 20,
              child: FittedBox(
                fit: BoxFit.fill,
                child: Switch(
                  value: value,
                  onChanged: onChanged,
                  activeColor: AppColors.selectedAccent,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.primaryText)),
                  const SizedBox(height: 1),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.placeholderText,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              FontHookGateResult(install: false, remember: _remember),
            ),
            child: Text('暂不使用',
                style: TextStyle(
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(
              FontHookGateResult(install: _install, remember: _remember),
            ),
            child: Text(_install ? '安装并启动' : '继续启动',
                style: TextStyle(
                    color: AppColors.selectedAccent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
