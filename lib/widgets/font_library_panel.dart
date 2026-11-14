// font_library_panel.dart
// 全库「字体器管理」浮层面板（L4 UI 层）—— 库页顶栏「字体」按钮的落地面板。
//
// 定位（用户 2026-10-17 二次反馈后确定）：
//   · 这里**不是**「全局字体配置中心」——不做统一字体、不做批量改字形；
//   · 它的唯一职责是回答一个问题：**我库里哪些游戏装了字体器**，
//     并让用户能快速安装 / 恢复，把「玩得越多、装得越多」的管理成本压下来；
//   · 具体给某部游戏选什么字体，统一走 `FontPickerPanel`（与原面板一致）。
//
// 视觉与交互刻意对齐库页「管理」浮层（筛选面板）：同样是贴按钮展开的
// 浮层卡片 + 点外部关闭，而不是模态窗口。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/game_font_override.dart';
import '../services/font_compatibility_service.dart';
import '../services/font_override_prefs.dart';
import '../services/game_data_format.dart';
import '../services/game_font_patch_service.dart';
import '../services/local_game_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import 'font_picker_dialog.dart';

/// 一行游戏的可变状态。
class _GameRow {
  final LibraryGame game;
  PatchProbeResult? probe;
  GameFontOverride? cfg;
  FontCompatVerdict? compat;
  bool selected = false;

  _GameRow(this.game);

  String get title => game.title;

  bool get installed =>
      probe != null &&
      probe!.state != PatchState.notInstalled &&
      probe!.state != PatchState.staleOrDamaged;

  bool get damaged => probe?.state == PatchState.staleOrDamaged;

  /// 可以执行「安装」的前置条件（未安装 + 有有效 exe + 不在运行）。
  bool get canInstall =>
      !installed &&
      !damaged &&
      !(probe?.running ?? false) &&
      (GameFontPatchService.resolveExePath(
              game.directoryPath, game.launchPath) ??
          '')
          .isNotEmpty;

  String get statusText {
    final p = probe;
    if (p == null) return '探测失败';
    switch (p.state) {
      case PatchState.installedByUs:
        return '已安装';
      case PatchState.installedByExternal:
        return '外部安装';
      case PatchState.staleOrDamaged:
        return '不完整';
      case PatchState.notInstalled:
        return game.launchPath.trim().isEmpty ? '未设启动程序' : '未安装';
    }
  }

  Color get statusColor {
    final p = probe;
    if (p == null) return AppColors.placeholderText;
    switch (p.state) {
      case PatchState.installedByUs:
        return AppColors.successGreen;
      case PatchState.installedByExternal:
        return AppColors.infoBlue;
      case PatchState.staleOrDamaged:
        return AppColors.warningAmber;
      case PatchState.notInstalled:
        return AppColors.placeholderText;
    }
  }

  /// 当前实际生效的字体（已安装且配置有字体名时才有意义）。
  String get fontText {
    if (!installed) return '原游戏字体';
    final name = cfg?.fontName.trim() ?? '';
    return name.isEmpty ? '原游戏字体' : name;
  }
}

/// 全库字体器管理浮层面板。
class FontLibraryPanel extends StatefulWidget {
  final Offset anchor;
  final Size anchorSize;
  final VoidCallback onClose;

  /// 批量/单台产生过写入时回调（库页据此刷新，可选）。
  final VoidCallback? onChanged;

  /// 仅测试用：跳过异步探测（`flutter_tester` 的 fake-async 不推进真实 IO）。
  final bool debugSkipLoad;

  const FontLibraryPanel({
    super.key,
    required this.anchor,
    required this.anchorSize,
    required this.onClose,
    this.onChanged,
    this.debugSkipLoad = false,
  });

  /// 在 [anchor] 下方弹出面板；返回可手动移除的 [OverlayEntry]。
  ///
  /// [onClosed] 在面板被自身关闭（点外部 / 点关闭按钮）后回调，
  /// 供调用方复位「按钮高亮」等宿主状态。
  static OverlayEntry show({
    required BuildContext context,
    required RenderBox anchor,
    VoidCallback? onChanged,
    VoidCallback? onClosed,
  }) {
    var removed = false;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => FontLibraryPanel(
        anchor: anchor.localToGlobal(Offset.zero),
        anchorSize: anchor.size,
        onChanged: onChanged,
        onClose: () {
          if (removed) return;
          removed = true;
          entry.remove();
          onClosed?.call();
        },
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    return entry;
  }

  @override
  State<FontLibraryPanel> createState() => _FontLibraryPanelState();
}

class _FontLibraryPanelState extends State<FontLibraryPanel> {
  bool _loading = true;
  bool _busy = false;
  double _progress = 0;

  final List<_GameRow> _rows = [];
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.debugSkipLoad) {
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // 探测
  // ═══════════════════════════════════════════════════════════

  Future<void> _load() async {
    final pkg = GameFontPatchService.payloadStatus();
    final games = LocalGameRegistry.instance.allGames;

    final rows = <_GameRow>[];
    for (final g in games) {
      final row = _GameRow(g);
      _refreshRow(row);
      row.selected = row.canInstall;
      rows.add(row);
    }

    if (!mounted) return;
    setState(() {
      _rows
        ..clear()
        ..addAll(rows);
      _loading = false;
      _payloadReady = pkg.ready;
      _payloadMessage = pkg.message;
    });
  }

  bool _payloadReady = true;
  String _payloadMessage = '';

  void _refreshRow(_GameRow r) {
    try {
      final exe = GameFontPatchService.resolveExePath(
          r.game.directoryPath, r.game.launchPath);
      r.probe = GameFontPatchService.probe(r.game.directoryPath, exePath: exe);
      r.cfg = GameFontPatchService.readConfig(r.game.directoryPath);
      r.compat = FontCompatibilityService.instance
          .lookup(title: r.game.title, exeName: exe);
    } catch (_) {
      r.probe = null;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 批量动作
  // ═══════════════════════════════════════════════════════════

  Future<void> _batchInstall() async {
    if (_busy) return;
    final targets = _rows.where((r) => r.selected).toList();
    if (targets.isEmpty) {
      _snack('请先勾选要安装的游戏');
      return;
    }
    if (!_payloadReady) {
      _snack(_payloadMessage.isEmpty ? '字体组件未就绪' : _payloadMessage,
          error: true);
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
    });

    var ok = 0;
    var skipped = 0;
    var failed = 0;
    final reasons = <String>[];

    // 统一字体只为「首次安装」提供一个能生效的初值，不是全局配置
    final fontName = await FontOverridePrefs.suggestFontName();

    for (var i = 0; i < targets.length; i++) {
      final r = targets[i];
      if (!mounted) return;
      setState(() => _progress = (i + 1) / targets.length);

      final exe = GameFontPatchService.resolveExePath(
          r.game.directoryPath, r.game.launchPath);
      final skip = _skipReason(r, exe);
      if (skip != null) {
        skipped++;
        if (reasons.length < 3) reasons.add('${r.title}：$skip');
        continue;
      }
      if (fontName.isEmpty) {
        skipped++;
        if (reasons.length < 3) reasons.add('${r.title}：未能确定可用字体');
        continue;
      }

      try {
        await GameFontPatchService.install(r.game.directoryPath,
            exePath: exe!);
        final cfg = (r.cfg ?? GameFontOverride.disabled).copyWith(
          enabled: true,
          fontName: fontName,
        );
        await GameFontPatchService.writeConfig(r.game.directoryPath, cfg);
        await _persist(r, cfg);
        _refreshRow(r);
        r.selected = false;
        ok++;
      } on FontPatchException catch (e) {
        failed++;
        if (reasons.length < 3) reasons.add('${r.title}：${e.message}');
      } catch (e) {
        failed++;
        if (reasons.length < 3) reasons.add('${r.title}：$e');
      }
    }

    if (!mounted) return;
    setState(() => _busy = false);
    _summary('批量安装', ok, skipped, failed, reasons);
    widget.onChanged?.call();
  }

  Future<void> _batchRestore() async {
    if (_busy) return;
    final targets = _rows.where((r) => r.selected && r.installed).toList();
    if (targets.isEmpty) {
      _snack('勾选的游戏里没有已安装字体器的');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
    });

    var ok = 0;
    var skipped = 0;
    var failed = 0;
    final reasons = <String>[];

    for (var i = 0; i < targets.length; i++) {
      final r = targets[i];
      if (!mounted) return;
      setState(() => _progress = (i + 1) / targets.length);

      if (r.probe?.running ?? false) {
        skipped++;
        if (reasons.length < 3) reasons.add('${r.title}：游戏正在运行');
        continue;
      }
      try {
        await GameFontPatchService.uninstall(r.game.directoryPath);
        final cfg = (r.cfg ?? GameFontOverride.disabled)
            .copyWith(enabled: false, patchedAt: '');
        await _persist(r, cfg);
        _refreshRow(r);
        r.selected = false;
        ok++;
      } on FontPatchException catch (e) {
        failed++;
        if (reasons.length < 3) reasons.add('${r.title}：${e.message}');
      } catch (e) {
        failed++;
        if (reasons.length < 3) reasons.add('${r.title}：$e');
      }
    }

    if (!mounted) return;
    setState(() => _busy = false);
    _summary('批量恢复', ok, skipped, failed, reasons);
    widget.onChanged?.call();
  }

  /// 单台安装（行内按钮）。
  Future<void> _installOne(_GameRow r) async {
    if (_busy) return;
    final exe = GameFontPatchService.resolveExePath(
        r.game.directoryPath, r.game.launchPath);
    final skip = _skipReason(r, exe);
    if (skip != null) {
      _snack('${r.title}：$skip', error: true);
      return;
    }
    final fontName = await FontOverridePrefs.suggestFontName();
    if (fontName.isEmpty) {
      _snack('未能确定可用字体，请先手动打开「字体设置」选一个', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await GameFontPatchService.install(r.game.directoryPath, exePath: exe!);
      final cfg = (r.cfg ?? GameFontOverride.disabled)
          .copyWith(enabled: true, fontName: fontName);
      await GameFontPatchService.writeConfig(r.game.directoryPath, cfg);
      await _persist(r, cfg);
      _refreshRow(r);
      _snack('已为「${r.title}」安装字体器');
      widget.onChanged?.call();
    } on FontPatchException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('安装失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 单台恢复（行内按钮）。
  Future<void> _restoreOne(_GameRow r) async {
    if (_busy) return;
    if (r.probe?.running ?? false) {
      _snack('${r.title}：游戏正在运行，请先关闭', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await GameFontPatchService.uninstall(r.game.directoryPath);
      final cfg =
          (r.cfg ?? GameFontOverride.disabled).copyWith(enabled: false, patchedAt: '');
      await _persist(r, cfg);
      _refreshRow(r);
      _snack('已恢复「${r.title}」的原游戏字体');
      widget.onChanged?.call();
    } on FontPatchException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('恢复失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _skipReason(_GameRow r, String? exe) {
    if (r.game.launchPath.trim().isEmpty) return '未设置启动程序';
    if (exe == null || exe.isEmpty) return '启动程序路径无效';
    if (r.damaged) return '字体器不完整，请先恢复';
    if (r.probe?.running ?? false) return '游戏正在运行';
    return null;
  }

  Future<void> _persist(_GameRow r, GameFontOverride cfg) async {
    try {
      await GameDataFormat.updateGameJson(
          r.game.metaDataDir, {'font_override': cfg.toJson()});
    } catch (_) {
      // 回写失败不阻断 —— 磁盘上的 FontHook.ini 已经生效
    }
  }

  void _summary(String title, int ok, int skipped, int failed,
      List<String> reasons) {
    final buf = StringBuffer('$title：成功 $ok · 跳过 $skipped · 失败 $failed');
    if (reasons.isNotEmpty) {
      buf.write('\n');
      buf.write(reasons.join('\n'));
      if (failed + skipped > 3) buf.write('\n…');
    }
    final text = buf.toString();
    if (failed > 0) {
      _snack(text, error: true);
    } else {
      _snack(text);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(fontSize: 13, color: Colors.white)),
        backgroundColor: error ? AppColors.dangerRed : AppColors.primaryText,
        behavior: SnackBarBehavior.floating,
        width: 420,
        duration: Duration(seconds: error ? 4 : 2),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════
  // build
  // ═══════════════════════════════════════════════════════════

  List<_GameRow> get _visibleRows {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where((r) =>
            r.title.toLowerCase().contains(q) ||
            r.fontText.toLowerCase().contains(q))
        .toList();
  }

  int get _installedCount => _rows.where((r) => r.installed).length;

  int get _selectedCount => _rows.where((r) => r.selected).length;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final panelW = math.min(600.0, screen.width - 32);
    final panelH = math.min(560.0, screen.height - 48);

    double left = widget.anchor.dx - panelW + widget.anchorSize.width;
    double top = widget.anchor.dy + widget.anchorSize.height + 8;
    if (top + panelH > screen.height - 16) {
      top = widget.anchor.dy - panelH - 8;
    }
    left = left.clamp(16.0, screen.width - panelW - 16).toDouble();
    top = top.clamp(16.0, screen.height - panelH - 16).toDouble();

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onClose,
            behavior: HitTestBehavior.translucent,
            child: Container(color: Colors.transparent),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: panelW,
          height: panelH,
          child: _buildPanel(),
        ),
      ],
    );
  }

  Widget _buildPanel() {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.18),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Divider(height: 1, thickness: 1, color: AppColors.borderLight),
            _buildToolbar(),
            Divider(height: 1, thickness: 1, color: AppColors.borderLight),
            Expanded(
              child: _loading
                  ? Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: AppColors.selectedAccent),
                      ),
                    )
                  : _buildList(),
            ),
            Divider(height: 1, thickness: 1, color: AppColors.borderLight),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      child: Row(
        children: [
          Icon(Icons.font_download_outlined,
              size: 17, color: AppColors.selectedAccent),
          const SizedBox(width: 8),
          Text('字体器管理',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText)),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.selectedAccent.withOpacity(0.10),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text('已安装 $_installedCount / 共 ${_rows.length}',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.selectedAccent)),
          ),
          const Spacer(),
          Tooltip(
            message: '关闭',
            waitDuration: const Duration(milliseconds: 400),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: widget.onClose,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(Icons.close,
                      size: 16, color: AppColors.secondaryText),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(
                        fontSize: 12.5, color: AppColors.primaryText),
                    cursorColor: AppColors.selectedAccent,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      hintText: '搜索游戏名或字体名',
                      hintStyle: TextStyle(
                          fontSize: 12.5, color: AppColors.inputHint),
                      prefixIcon: Icon(Icons.search,
                          size: 15, color: AppColors.inputHint),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 30, minHeight: 28),
                      filled: true,
                      fillColor: AppColors.buttonBackground,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide: BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        borderSide:
                            BorderSide(color: AppColors.selectedAccent),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _ghostBtn('全选', () => setState(() {
                    for (final r in _visibleRows) {
                      r.selected = true;
                    }
                  })),
              const SizedBox(width: 6),
              _ghostBtn('清空', () => setState(() {
                    for (final r in _rows) {
                      r.selected = false;
                    }
                  })),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _busy
                      ? '处理中… ${(_progress * 100).round()}%'
                      : '已勾选 $_selectedCount 部',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.secondaryText),
                ),
              ),
              _ghostBtn('批量恢复', _batchRestore, danger: true),
              const SizedBox(width: 6),
              _primaryBtn('批量安装并应用', _batchInstall),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                minHeight: 3,
                backgroundColor: AppColors.borderLight,
                valueColor: AlwaysStoppedAnimation(AppColors.selectedAccent),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_rows.isEmpty) {
      return Center(
        child: Text('库里还没有已安装的游戏',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
      );
    }
    final rows = _visibleRows;
    if (rows.isEmpty) {
      return Center(
        child: Text('没有匹配「$_query」的游戏',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      itemCount: rows.length,
      itemExtent: 48,
      itemBuilder: (_, i) => _buildRow(rows[i]),
    );
  }

  Widget _buildRow(_GameRow r) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _busy ? null : () => setState(() => r.selected = !r.selected),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: r.selected,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => r.selected = v == true),
                  activeColor: AppColors.selectedAccent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(r.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.primaryText)),
                        ),
                        if (r.compat != null) ...[
                          const SizedBox(width: 4),
                          Tooltip(
                            message: '已知不兼容：${r.compat!.reason}',
                            waitDuration: const Duration(milliseconds: 300),
                            child: Icon(Icons.warning_amber_rounded,
                                size: 12, color: AppColors.warningAmber),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${r.statusText} · ${r.fontText}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: r.statusColor == AppColors.placeholderText
                            ? AppColors.placeholderText
                            : r.statusColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (r.installed)
                _rowBtn(
                  '字体设置',
                  onTap: () => _openPicker(r),
                )
              else if (r.damaged)
                _rowBtn('恢复', onTap: () => _restoreOne(r))
              else
                _rowBtn('安装', onTap: () => _installOne(r), primary: true),
              if (r.installed) ...[
                const SizedBox(width: 4),
                _rowBtn('恢复', onTap: () => _restoreOne(r), danger: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 打开单游戏的「字体选择器」窗口（v1.2 起为独立窗口）。
  void _openPicker(_GameRow r) {
    FontPickerDialog.open(
      context: context,
      gameTitle: r.game.title,
      gameDirectory: r.game.directoryPath,
      launchPath: r.game.launchPath,
      metaDataDir: r.game.metaDataDir,
      onChanged: () {
        _refreshRow(r);
        if (mounted) setState(() {});
        widget.onChanged?.call();
      },
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: AppColors.placeholderText),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '安装后即可在游戏内按 Insert 呼出字体面板；这里只做安装与恢复。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, color: AppColors.placeholderText),
            ),
          ),
        ],
      ),
    );
  }

  // ── 小部件 ──────────────────────────────────────────────────

  Widget _rowBtn(
    String label, {
    VoidCallback? onTap,
    bool primary = false,
    bool danger = false,
  }) {
    final color = primary
        ? AppColors.selectedAccent
        : danger
            ? AppColors.dangerRed
            : AppColors.secondaryText;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _busy ? null : onTap,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary
                ? AppColors.selectedAccent.withOpacity(0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: primary
                  ? AppColors.selectedAccent.withOpacity(0.45)
                  : AppColors.border,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _busy ? AppColors.placeholderText : color)),
        ),
      ),
    );
  }

  Widget _ghostBtn(String label, VoidCallback onTap, {bool danger = false}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _busy ? null : onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: _busy
                      ? AppColors.placeholderText
                      : danger
                          ? AppColors.dangerRed
                          : AppColors.secondaryText)),
        ),
      ),
    );
  }

  Widget _primaryBtn(String label, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _busy ? null : onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _busy
                ? AppColors.selectedAccent.withOpacity(0.35)
                : AppColors.selectedAccent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ),
      ),
    );
  }
}
