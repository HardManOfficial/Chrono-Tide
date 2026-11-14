/// 「恢复默认设置」面板（2026-11-14 新增）。
///
/// ## 为什么是弹窗而不是第 9 个 tab
///
/// 设置页刚做完 UI 统一（4 簇 / 8 tab），再加一个 tab 会让「找设置」这件事
/// 更重；而恢复默认本身不是「设置项」，是一个**逃生舱**。放在设置窗口页头右侧
/// （低视觉权重、位置固定、任何 tab 下都在），符合这类危险动作的通行位置。
///
/// ## 交互三段
///
/// 1. **勾选**：4 类，默认全选（用户要的默认口径）；
/// 2. **二次确认**：`showConfirmDialog(isDanger: true)`，列出将要恢复的类别；
/// 3. **结果页**：恢复条数 + 副作用清单 + 「立即重启 / 稍后手动重启」。
///
/// 重启是必需的（原因见 `services/settings_reset/settings_reset_service.dart`
/// 文件头：30+ 个偏好服务都是启动时读一次的单例）。
///
/// ## 视觉约束
///
/// 全部走 `AppColors` / `AppSpacing` / `AppStyle` 令牌，与设置页组卡
/// （`SettingsGroupCard`：1.6px 边框 + e1 硬影 / 发丝线 + 软影）同一套语言；
/// 卡内不再套带边框的子块（消除「框中框」）。
library;

import 'package:flutter/material.dart';

import '../../services/settings_reset/settings_reset_core.dart';
import '../../services/settings_reset/settings_reset_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_style.dart';
import '../app_dialog.dart';
import '../app_snack_bar.dart';
import '../confirm_dialog.dart';
import '../custom_title_bar.dart';
import 'settings_group_card.dart';

/// 打开「恢复默认设置」面板。
///
/// 不可点遮罩关闭：面板里有勾选状态，误触丢状态比多按一次「取消」更烦。
Future<void> showSettingsResetDialog(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => const SettingsResetPanel(),
  );
}

/// 面板本体（公开类型只是为了探针能直接挂载渲染）。
class SettingsResetPanel extends StatefulWidget {
  const SettingsResetPanel({super.key, this.debugInitialReport});

  /// 仅供探针直接把面板渲染成**结果页**（生产入口永远从勾选态开始）。
  /// 结果页高度随副作用条目变化，是最容易溢出的那一屏，必须能单独渲染验证。
  final SettingsResetReport? debugInitialReport;

  @override
  State<SettingsResetPanel> createState() => _SettingsResetPanelState();
}

class _SettingsResetPanelState extends State<SettingsResetPanel> {
  /// 勾选状态。默认**全选**（用户口径：默认全部恢复）。
  final Set<SettingsResetDomain> _selected =
      SettingsResetDomain.values.toSet();

  bool _busy = false;
  bool _closeHovered = false;
  bool _restarting = false;

  /// 非 null ⇒ 已进入结果页。
  late SettingsResetReport? _report = widget.debugInitialReport;

  bool get _allSelected =>
      _selected.length == SettingsResetDomain.values.length;

  int get _selectedItemCount {
    int n = 0;
    for (final SettingsResetDomain d in SettingsResetDomain.values) {
      if (_selected.contains(d)) n += settingsResetItemCount(d);
    }
    return n;
  }

  void _toggle(SettingsResetDomain domain) {
    if (_busy) return;
    setState(() {
      if (!_selected.remove(domain)) _selected.add(domain);
    });
  }

  void _toggleAll() {
    if (_busy) return;
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(SettingsResetDomain.values);
      }
    });
  }

  Future<void> _confirmAndRestore() async {
    if (_selected.isEmpty || _busy) return;

    final String list = SettingsResetDomain.values
        .where(_selected.contains)
        .map((SettingsResetDomain d) =>
            '· ${d.label}（${settingsResetItemCount(d)} 项）')
        .join('\n');
    final bool ok = await showConfirmDialog(
      context: context,
      title: '确认恢复默认设置？',
      message: '将要恢复的类别：\n$list\n\n'
          '共 $_selectedItemCount 项设置会回到出厂状态，此操作无法撤销。',
      confirmText: '恢复',
      cancelText: '再想想',
      isDanger: true,
      hint: '游戏、游戏数据、账号与平台凭证不会被删除；恢复后需重启应用完全生效。',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final SettingsResetReport report =
        await SettingsResetService.restore(domains: _selected.toSet());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _report = report;
    });
  }

  Future<void> _restartNow() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    final bool ok = await SettingsResetService.scheduleRelaunch();
    if (!mounted) return;
    if (!ok) {
      setState(() => _restarting = false);
      AppSnackBar.error(context, '无法自动重启，请手动关闭本程序后重新打开');
      return;
    }
    await CustomTitleBar.performCleanExit(context);
  }

  void _restartLater() {
    Navigator.of(context).maybePop();
    AppSnackBar.info(context, '设置已恢复，重启应用后完全生效');
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.of(context).size;
    // 窗口最小 820×520 时这也是个弹窗，所以高度必须跟着可用空间走，
    // 而不是写死 620。下限 300 保证标题+按钮永远能同时出现（正文可滚）。
    final double maxHeight = _clampSafe(
      screen.height - kTitleBarHeight - AppSpacing.xxxl,
      300,
      640,
    );
    final bool modern = AppStyle.isModern;

    return Center(
      child: Container(
        width: 560,
        constraints: BoxConstraints(maxHeight: maxHeight),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppStyle.rLg),
          border: Border.all(
            color: modern ? AppColors.borderLight : AppColors.border,
            width: modern ? AppStyle.wNormal : 1.6,
          ),
          boxShadow: AppStyle.e3,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(),
            Container(height: 1, color: AppColors.borderLight),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.lg,
                  AppSpacing.xl,
                  AppSpacing.lg,
                ),
                child: _report == null ? _buildSelector() : _buildResult(),
              ),
            ),
            _report == null ? _buildSelectorFooter() : _buildResultFooter(),
          ],
        ),
      ),
    );
  }

  /// 安全 clamp：`hi < lo` 时 `num.clamp` 会抛 ArgumentError（窗口被压到极小时的坑）。
  static double _clampSafe(double v, double lo, double hi) {
    if (hi < lo) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
  }

  // ───────────────────────── 页头 ─────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.dangerRed.withOpacity(0.12),
              borderRadius: BorderRadius.circular(AppStyle.rSm),
            ),
            child: Icon(
              Icons.settings_backup_restore_rounded,
              size: 18,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _report == null ? '恢复默认设置' : '恢复完成',
                  style: TextStyle(
                    fontSize: 17,
                    height: 22 / 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _report == null
                      ? '选择要恢复的范围。设置会回到出厂状态，恢复后需重启应用。'
                      : '下列设置已恢复为出厂状态。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 17 / 12,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildCloseButton(),
        ],
      ),
    );
  }

  Widget _buildCloseButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _closeHovered = true),
      onExit: (_) => setState(() => _closeHovered = false),
      child: GestureDetector(
        onTap: _busy || _restarting
            ? null
            : () => Navigator.of(context).maybePop(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _closeHovered
                ? AppColors.primaryText.withOpacity(0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppStyle.rSm),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 16,
            color: _closeHovered
                ? AppColors.primaryText
                : AppColors.secondaryText,
          ),
        ),
      ),
    );
  }

  // ───────────────────────── 勾选态 ─────────────────────────

  Widget _buildSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              '恢复范围',
              style: TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              '共 $_selectedItemCount 项',
              style: TextStyle(
                fontSize: 11.5,
                height: 16 / 11.5,
                color: AppColors.secondaryText,
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _toggleAll,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: 2,
                  ),
                  child: Text(
                    _allSelected ? '取消全选' : '全选',
                    style: TextStyle(
                      fontSize: 12,
                      height: 16 / 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.selectedAccent,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsGroupCard(
          dividerIndent: AppSpacing.md,
          children: <Widget>[
            for (final SettingsResetDomain domain
                in SettingsResetDomain.values)
              _DomainRow(
                domain: domain,
                selected: _selected.contains(domain),
                enabled: !_busy,
                onTap: () => _toggle(domain),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _buildKeepNote(),
      ],
    );
  }

  /// 「不会删什么」—— 这句话比上面任何一句都重要：用户怕的是丢东西。
  Widget _buildKeepNote() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        borderRadius: BorderRadius.circular(AppStyle.rMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.shield_outlined,
            size: 14,
            color: AppColors.secondaryText,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '不会被删除：游戏与游戏数据、账号与平台凭证（Token / Cookie / PAT）、'
              '自定义主题与背景图文件、手柄映射档案。',
              style: TextStyle(
                fontSize: 11.5,
                height: 17 / 11.5,
                color: AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectorFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderLight)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildWarningLine(
            '恢复后无法撤销，且需要重启应用才能完全生效。',
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              _PanelButton(
                label: '取消',
                onTap: _busy ? null : () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: AppSpacing.sm),
              _PanelButton(
                label: _busy ? '恢复中…' : '恢复选中项',
                danger: true,
                busy: _busy,
                onTap: (_busy || _selected.isEmpty) ? null : _confirmAndRestore,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWarningLine(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.warning_amber_rounded,
          size: 14,
          color: AppColors.warningAmber,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 17 / 11.5,
              color: AppColors.warningAmber,
            ),
          ),
        ),
      ],
    );
  }

  // ───────────────────────── 结果态 ─────────────────────────

  Widget _buildResult() {
    final SettingsResetReport report = _report!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Center(
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (report.hasFailure ? AppColors.dangerRed
                      : AppColors.successGreen)
                  .withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              report.hasFailure
                  ? Icons.error_outline_rounded
                  : Icons.check_rounded,
              size: 22,
              color: report.hasFailure
                  ? AppColors.dangerRed
                  : AppColors.successGreen,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: Text(
            report.summaryLine,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              height: 20 / 13.5,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText,
            ),
          ),
        ),
        if (report.fatalError != null) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            report.fatalError!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.dangerRed,
            ),
          ),
        ],
        if (report.failedKeys.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '有 ${report.failedKeys.length} 项没能写入（可能被占用），重启后会自动回到默认。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.dangerRed,
            ),
          ),
        ],
        if (report.sideEffects.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.lg),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.placeholderBg,
              borderRadius: BorderRadius.circular(AppStyle.rMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final String line in report.sideEffects)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: AppColors.secondaryText,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            line,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 17 / 11.5,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.infoBg,
            borderRadius: BorderRadius.circular(AppStyle.rMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.restart_alt_rounded,
                size: 15,
                color: AppColors.infoBlue,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '其余改动（主题以外的界面、启动、元数据、网络与存储）'
                  '在重启后生效。现在重启最省事，勾选了的设置会一次性全部到位。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 17 / 11.5,
                    color: AppColors.infoBlue,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderLight)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          _PanelButton(
            label: '稍后手动重启',
            onTap: _restarting ? null : _restartLater,
          ),
          const SizedBox(width: AppSpacing.sm),
          _PanelButton(
            label: _restarting ? '正在重启…' : '立即重启',
            danger: true,
            busy: _restarting,
            onTap: _restarting ? null : _restartNow,
          ),
        ],
      ),
    );
  }
}

/// 一行可勾选的恢复范围。
class _DomainRow extends StatefulWidget {
  const _DomainRow({
    required this.domain,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final SettingsResetDomain domain;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_DomainRow> createState() => _DomainRowState();
}

class _DomainRowState extends State<_DomainRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool on = widget.selected;
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          color: _hovered && widget.enabled
              ? AppColors.cardHoverBg
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: _CheckBox(on: on, dimmed: !widget.enabled),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            widget.domain.label,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 19 / 13.5,
                              fontWeight: FontWeight.w600,
                              color: on
                                  ? AppColors.primaryText
                                  : AppColors.secondaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          '${settingsResetItemCount(widget.domain)} 项',
                          style: TextStyle(
                            fontSize: 11,
                            height: 16 / 11,
                            color: AppColors.placeholderText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.domain.summary,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 17 / 11.5,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自绘勾选框（项目没有统一 Checkbox 组件，主题里也没有配 CheckboxTheme；
/// 用 Material 默认蓝会与本主题的 `selectedAccent` 撞色）。
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.on, required this.dimmed});

  final bool on;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final Color accent = dimmed ? AppColors.secondaryText : AppColors.selectedAccent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: on ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: on ? accent : AppColors.border,
          width: 1.6,
        ),
      ),
      child: on
          ? Icon(
              Icons.check_rounded,
              size: 12,
              color: AppColors.onAccentSolid,
            )
          : null,
    );
  }
}

/// 面板内按钮。
///
/// 为什么不复用 `HoverButton`：那个组件带鼠标跟随的放大反馈与硬投影，
/// 是为页面主行动设计的；弹窗底部这一排要"安静的方框"，两套语言不能混。
class _PanelButton extends StatefulWidget {
  const _PanelButton({
    required this.label,
    required this.onTap,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool busy;

  @override
  State<_PanelButton> createState() => _PanelButtonState();
}

class _PanelButtonState extends State<_PanelButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool disabled = widget.onTap == null;
    final bool modern = AppStyle.isModern;
    final Color base = widget.danger ? AppColors.dangerRed : AppColors.background;
    final Color fg = widget.danger
        ? AppColors.onAccentSolid
        : AppColors.primaryText;
    final Color borderColor =
        widget.danger ? AppColors.dangerRed : AppColors.border;

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: disabled
                ? base.withOpacity(0.45)
                : (_hovered
                    ? Color.alphaBlend(
                        (widget.danger ? Colors.white : AppColors.primaryText)
                            .withOpacity(0.10),
                        base,
                      )
                    : base),
            borderRadius: BorderRadius.circular(AppStyle.rSm),
            border: Border.all(
              color: disabled ? borderColor.withOpacity(0.5) : borderColor,
              width: modern ? AppStyle.wNormal : 1.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.busy) ...<Widget>[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation<Color>(fg),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w600,
                  color: disabled ? fg.withOpacity(0.7) : fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
