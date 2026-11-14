// font_picker_dialog.dart
// 单游戏「字体选择器」窗口（L4 UI 层）。
//
// 定位（用户 2026-10-17 三次反馈后确定）：
//   · 管理器对这个功能的本职是**安装器**——自动化装字体器、写好配置、方便管理；
//   · 具体的字体选择与微调，正路是让玩家在**游戏内字体面板**里调（按 Insert 呼出）；
//   · 本窗口是「不用进游戏也能改」的**便捷补充**，因此 v1.2 起：
//       - 形态从贴边浮层**改回独立窗口**（浮层贴在启动管理面板上太挤、太突兀）；
//       - 版式**完全照 CTFontHook 原生字体选择器**（单栏竖排：搜索 → 字符集 →
//         字体列表 → 兼容设置 → 字形微调 → 文字预览 → 底栏），
//         让玩家在两处看到的东西是同一套，不用重新学；
//       - 去掉「恢复」按钮：卸载/还原是**安装器**的职责，统一收在
//         「启动管理 → 字体替换 → 安装/恢复」，本窗口只管「选字体 + 应用」。
//
// 职责边界：只做表现 + 编排，磁盘动作全部委托 `GameFontPatchService` /
// `GameDataFormat`。事实源 = `game.json.font_override`；`FontHook.ini` 是派生产物。
//
// 关键约束（方案 §5.3 / Phase 0 结论）：
//   · `FontNameW` 必须是真族名 ⇒ 字体只能从 FFI 枚举结果里选，不提供手打。
//   · `PickerShowOnStartup=0` 由 `FontHookIniCodec` 硬编码，本文件不接触该键。
//   · 写盘一律要求游戏不在运行（服务层守卫，此处做前置拦截）。
//   · 每一项度量（字宽/字高/字距/上行/下行/行距/粗细）都有独立开关，
//     数值存在但开关关闭时 CTFontHook **不应用**该值（docs/configuration.md:37），
//     所以网格里每格带一个小勾选框——没有开关的输入框等于静默失效。

import 'package:flutter/material.dart';

import '../models/game_font_override.dart';
import '../services/font_compatibility_service.dart';
import '../services/font_override_prefs.dart';
import '../services/game_data_format.dart';
import '../services/game_font_patch_service.dart';
import '../services/win32_font_enumerator.dart';
import 'app_snack_bar.dart';

/// 探针 / golden 用：跳过异步初始化，直接以给定状态渲染首帧。
///
/// 存在原因：`flutter_tester` 的 fake-async 不会推进真实文件 IO，
/// `_bootstrap()` 永远悬着 ⇒ 窗口正文（字体列表 / 兼容设置 / 字形微调）
/// 在自动化里渲染不出来。生产路径**从不**传这个种子。
@visibleForTesting
class FontPickerSeed {
  final GameFontOverride cfg;
  final PatchProbeResult? probe;
  final List<SystemFontFamily> fonts;
  final FontCompatVerdict? compat;

  const FontPickerSeed({
    required this.cfg,
    this.probe,
    this.fonts = const [],
    this.compat,
  });
}

/// 单游戏「字体选择器」窗口。
class FontPickerDialog extends StatefulWidget {
  final String gameTitle;
  final String gameDirectory;

  /// `launch_path`（相对游戏目录），用于解析 exe 与判定架构。
  final String? launchPath;

  /// 该游戏的元数据目录（`game.json` 所在处）。
  final String? metaDataDir;

  /// 本次会话内产生过写入时回调一次（宿主据此刷新字号/状态）。
  final VoidCallback? onChanged;

  /// 仅测试用（见 [FontPickerSeed]）。
  final FontPickerSeed? debugSeed;

  const FontPickerDialog({
    super.key,
    required this.gameTitle,
    required this.gameDirectory,
    this.launchPath,
    this.metaDataDir,
    this.onChanged,
    this.debugSeed,
  });

  /// 以模态窗口打开；关闭时若产生过写入则回调 [onChanged]。
  static Future<void> open({
    required BuildContext context,
    required String gameTitle,
    required String gameDirectory,
    String? launchPath,
    String? metaDataDir,
    VoidCallback? onChanged,
    FontPickerSeed? debugSeed,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      // 窗口语义：只能点「关闭」/ × 退出。点外部误关会丢掉未应用的调整。
      barrierDismissible: false,
      builder: (_) => FontPickerDialog(
        gameTitle: gameTitle,
        gameDirectory: gameDirectory,
        launchPath: launchPath,
        metaDataDir: metaDataDir,
        onChanged: onChanged,
        debugSeed: debugSeed,
      ),
    );
  }

  @override
  State<FontPickerDialog> createState() => _FontPickerDialogState();
}

// ═══════════════════════════════════════════════════════════
// 配色（照 CTFontHook 原生面板：深色玻璃 + 蓝高亮 + 绿「已应用」）
// ═══════════════════════════════════════════════════════════

class _C {
  static const Color bg = Color(0xFF171B24);
  static const Color field = Color(0xFF232A36);
  static const Color border = Color(0x26FFFFFF);
  static const Color borderStrong = Color(0x40FFFFFF);
  static const Color divider = Color(0x14FFFFFF);
  static const Color text = Color(0xFFE7EAF0);
  static const Color textDim = Color(0xFF96A0B2);
  static const Color textFaint = Color(0xFF6C7688);
  static const Color accent = Color(0xFF4C8DF6);
  static const Color accentSoft = Color(0x264C8DF6);
  static const Color green = Color(0xFF3FB950);
  static const Color amber = Color(0xFFD9A23B);
}

class _FontPickerDialogState extends State<FontPickerDialog> {
  bool _initializing = true;
  bool _busy = false;

  PatchProbeResult? _probe;
  FontHookPayloadStatus _payload = const FontHookPayloadStatus(
      ready: false, root: '', message: '正在检查字体组件…');

  GameFontOverride _cfg = GameFontOverride.disabled;
  FontCompatVerdict? _compat;

  List<SystemFontFamily> _allFonts = const [];
  bool _fontEnumFailed = false;
  String _fontQuery = '';

  /// 预览字号（纯 UI 状态，不进配置）。
  double _previewSize = 22;

  final TextEditingController _searchCtrl = TextEditingController();

  String? get _exePath => GameFontPatchService.resolveExePath(
      widget.gameDirectory, widget.launchPath ?? '');

  bool get _runningNow => _probe?.running ?? false;

  @override
  void initState() {
    super.initState();
    final seed = widget.debugSeed;
    if (seed != null) {
      _cfg = seed.cfg;
      _probe = seed.probe;
      _allFonts = seed.fonts;
      _compat = seed.compat;
      _payload = const FontHookPayloadStatus(ready: true, root: 'debug-seed');
      _initializing = false;
    } else {
      _bootstrap();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════════════════════════

  Future<void> _bootstrap() async {
    final payload = GameFontPatchService.payloadStatus();
    final probe = GameFontPatchService.probe(
      widget.gameDirectory,
      exePath: _exePath,
    );

    // 单游戏事实源优先取 game.json，缺省回落到正在生效的 INI
    GameFontOverride cfg = GameFontOverride.disabled;
    final metaDir = widget.metaDataDir;
    if (metaDir != null && metaDir.isNotEmpty) {
      try {
        final gd = await GameDataFormat.readGameJson(metaDir);
        final raw = gd?.fontOverride;
        if (raw != null) cfg = GameFontOverride.fromJson(raw);
      } catch (_) {
        // 读失败按「无配置」处理，不阻断窗口
      }
    }
    if (!cfg.hasFont) {
      final fromIni = GameFontPatchService.readConfig(widget.gameDirectory);
      if (fromIni != null && fromIni.hasFont) cfg = fromIni;
    }

    // 从未配置过该游戏时，用「建议默认字体」兜底（不是全局统一字体概念，
    // 只是让面板一打开就有个可用值，避免用户面对空白列表）
    if (!cfg.hasFont) {
      final seeded = await FontOverridePrefs.suggestFontName();
      if (seeded.isNotEmpty) cfg = cfg.copyWith(fontName: seeded);
    }

    final compat = FontCompatibilityService.instance
        .lookup(title: widget.gameTitle, exeName: _exePath);

    if (!mounted) return;
    setState(() {
      _payload = payload;
      _probe = probe;
      _cfg = cfg;
      _compat = compat;
      _initializing = false;
    });

    // 字体枚举单独一步：慢（~0.2–1s）且可降级，不阻塞状态先上屏
    try {
      final snap = await Win32FontEnumerator.enumerate();
      if (!mounted) return;
      setState(() {
        _allFonts = snap.usable.toList()..sort();
        _fontEnumFailed = _allFonts.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _fontEnumFailed = true);
    }
  }

  Future<void> _reprobe() async {
    final probe =
        GameFontPatchService.probe(widget.gameDirectory, exePath: _exePath);
    if (!mounted) return;
    setState(() => _probe = probe);
  }

  // ═══════════════════════════════════════════════════════════
  // 动作
  // ═══════════════════════════════════════════════════════════

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    if (error) {
      AppSnackBar.error(context, msg);
    } else {
      AppSnackBar.info(context, msg, duration: const Duration(seconds: 2));
    }
  }

  /// 应用：按需补装 → 写 `FontHook.ini` → 回写 `game.json.font_override`。
  Future<void> _apply() async {
    if (_busy) return;

    if (!_cfg.hasFont) {
      _snack('请先选择要使用的字体', error: true);
      return;
    }
    final exe = _exePath;
    if (exe == null || exe.isEmpty) {
      _snack('该游戏尚未设置启动程序，请先在「启动管理」里选择', error: true);
      return;
    }
    if (!_payload.ready) {
      _snack(_payload.message.isEmpty ? '字体组件未就绪' : _payload.message,
          error: true);
      return;
    }
    if (_runningNow) {
      _snack('游戏正在运行，请先关闭游戏', error: true);
      return;
    }
    if (_probe?.state == PatchState.staleOrDamaged) {
      _snack('字体器不完整（winmm.dll 缺失），请先回「启动管理」点「恢复」重装',
          error: true);
      return;
    }

    setState(() => _busy = true);
    try {
      if (_probe?.state == PatchState.notInstalled) {
        await GameFontPatchService.install(widget.gameDirectory, exePath: exe);
      }

      final patched = _cfg.copyWith(enabled: true);
      await GameFontPatchService.writeConfig(widget.gameDirectory, patched);

      final ok = await _persist(patched);
      if (!ok) {
        _snack('配置已写入游戏目录，但游戏数据回写失败', error: true);
      } else {
        _snack('已应用字体「${patched.fontName}」，重启游戏后生效');
      }
      if (!mounted) return;
      setState(() => _cfg = patched);
      // 立即通知宿主刷新（不等关窗）—— Esc / × 退出时也不会漏刷新
      widget.onChanged?.call();
      await _reprobe();
    } on FontPatchException catch (e) {
      _snack(e.message, error: true);
    } catch (e) {
      _snack('应用失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _persist(GameFontOverride cfg) async {
    final metaDir = widget.metaDataDir;
    if (metaDir == null || metaDir.isEmpty) return false;
    try {
      return await GameDataFormat.updateGameJson(
          metaDir, {'font_override': cfg.toJson()});
    } catch (_) {
      return false;
    }
  }

  /// 关闭窗口（不拦截未保存改动：本窗口所有改动都只在点「应用」时才落盘，
  /// 直接关等于放弃，与原工具「关掉窗口即放弃」一致）。
  void _close() {
    Navigator.of(context).maybePop();
  }

  // ═══════════════════════════════════════════════════════════
  // build
  // ═══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    // v1.3：改左右两栏（左 = 参数、右 = 选字体 + 预览），主体不再整页滚动。
    final w = (screen.width - 120).clamp(730.0, 860.0).toDouble();
    final h = (screen.height - 120).clamp(470.0, 530.0).toDouble();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: w,
        height: h,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            decoration: BoxDecoration(
              color: _C.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _C.borderStrong),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.55),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  if (_compat != null) _compatBanner(_compat!),
                  _hairline(),
                  Expanded(
                    child: _initializing
                        ? Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _C.accent,
                              ),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // ── 左栏：兼容设置 + 字形微调 ──
                                SizedBox(width: 300, child: _leftColumn()),
                                const SizedBox(width: 14),
                                // ── 右栏：选字体 + 预览（列表吃掉剩余高度） ──
                                Expanded(child: _rightColumn()),
                              ],
                            ),
                          ),
                  ),
                  _hairline(),
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hairline() => Container(height: 1, color: _C.divider);

  /// 左栏：兼容设置 + 字形微调（v1.3 合并成一列，主体不再滚动）。
  ///
  /// ⚠️ 必须包成**三个块**再交给 spaceBetween：直接摊平会让区间距
  /// 与标题-内容间距一起被均分，标题会被拉离自己的内容。
  Widget _leftColumn() {
    final compatBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 与右栏搜索框顶部对齐
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: _sectionTitle('兼容设置', latin: 'COMPATIBILITY'),
        ),
        const SizedBox(height: 4),
        _compatSection(),
      ],
    );

    final metricsBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: _sectionTitle('字形微调', trailing: _resetMetricsBtn()),
        ),
        _metricsGrid(),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [compatBlock, metricsBlock, _leftFootnote()],
    );
  }

  /// 左栏底部说明：这两组参数是「修老游戏」的，正常玩不需要动。
  Widget _leftFootnote() {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _C.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '兼容设置用于修老游戏的乱码 / 字形错位，不确定就别勾。',
            style: TextStyle(fontSize: 9.5, height: 1.5, color: _C.textFaint),
          ),
          Text(
            '字形微调只作用于当前方案，游戏内按 Insert 也能实时调。',
            style: TextStyle(fontSize: 9.5, height: 1.5, color: _C.textFaint),
          ),
          SizedBox(height: 3),
          Text(
            '两者都写进游戏的 FontHook.ini，随游戏目录走。',
            style: TextStyle(fontSize: 9.5, height: 1.5, color: _C.textFaint),
          ),
        ],
      ),
    );
  }

  /// 右栏：搜索 + 字符集 + 字体列表（吃掉剩余高度）+ 文字预览。
  Widget _rightColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchField(),
        const SizedBox(height: 8),
        _charsetRow(),
        const SizedBox(height: 8),
        Expanded(child: _fontList()),
        const SizedBox(height: 5),
        _hintLine(),
        const SizedBox(height: 8),
        _previewHeader(),
        const SizedBox(height: 6),
        _previewBox(),
      ],
    );
  }

  // ── 标题栏 ──────────────────────────────────────────────────

  Widget _header() {
    return Container(
      // v1.3：标题栏从 50 压到 34，把高度让给正文
      height: 34,
      padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _C.accentSoft,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('A',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _C.accent)),
          ),
          const SizedBox(width: 8),
          Text('字体选择器',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: _C.text)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.gameTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: _C.textFaint),
            ),
          ),
          const SizedBox(width: 8),
          _statusChip(),
          const SizedBox(width: 2),
          _iconBtn(Icons.close, '关闭', _close),
        ],
      ),
    );
  }

  Widget _statusChip() {
    final p = _probe;
    String text = '检查中';
    Color color = _C.textDim;
    if (p != null) {
      switch (p.state) {
        case PatchState.installedByUs:
          text = '已安装';
          color = _C.green;
          break;
        case PatchState.installedByExternal:
          text = '外部安装';
          color = _C.accent;
          break;
        case PatchState.staleOrDamaged:
          text = '不完整';
          color = _C.amber;
          break;
        case PatchState.notInstalled:
          text = '未安装';
          color = _C.textDim;
          break;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 9.5, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _compatBanner(FontCompatVerdict v) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
      color: _C.amber.withOpacity(0.10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 14, color: _C.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已知不兼容：${v.reason}。装完若异常，回「启动管理 → 字体替换 → 恢复」一键还原。',
              style: const TextStyle(
                  fontSize: 11, height: 1.5, color: _C.amber),
            ),
          ),
        ],
      ),
    );
  }

  // ── 搜索 + 字符集 ────────────────────────────────────────────

  Widget _searchField() {
    return SizedBox(
      height: 34,
      child: Container(
        decoration: BoxDecoration(
          color: _C.field,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _C.border),
        ),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _fontQuery = v),
          style: const TextStyle(fontSize: 12.5, color: _C.text),
          cursorColor: _C.accent,
          cursorHeight: 14,
          decoration: const InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 9),
            hintText: '搜索字体',
            hintStyle: TextStyle(fontSize: 12.5, color: _C.textFaint),
            prefixIcon: Icon(Icons.search, size: 16, color: _C.textFaint),
            prefixIconConstraints:
                BoxConstraints(minWidth: 34, minHeight: 32),
          ),
        ),
      ),
    );
  }

  Widget _charsetRow() {
    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: FontCharset.uiOrder.map((cs) {
              return _pill(
                label: FontCharset.pickerLabel(cs),
                active: _cfg.charset == cs,
                onTap: () => setState(() => _cfg = _cfg.copyWith(charset: cs)),
              );
            }).toList(),
          ),
        ),
        const SizedBox(width: 8),
        Text('${_filteredFonts.length} 款',
            style: const TextStyle(fontSize: 10.5, color: _C.textFaint)),
      ],
    );
  }

  Widget _pill({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final color = active ? _C.accent : _C.textDim;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: active ? _C.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: active ? _C.accent.withOpacity(0.75) : _C.border),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ),
      ),
    );
  }

  // ── 字体列表 ────────────────────────────────────────────────

  List<SystemFontFamily> get _filteredFonts {
    final q = _fontQuery.trim();
    if (q.isEmpty) return _allFonts;
    return _allFonts.where((f) => f.matchesQuery(q)).toList();
  }

  Widget _fontList() {
    Widget body;
    if (_fontEnumFailed) {
      body = _listMessage('未能读取本机字体列表。\n可直接进游戏按 Insert 呼出原生字体面板调整。');
    } else if (_allFonts.isEmpty) {
      body = const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: _C.accent),
        ),
      );
    } else {
      final fonts = _filteredFonts;
      body = fonts.isEmpty
          ? _listMessage('没有匹配「$_fontQuery」的字体')
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: fonts.length,
              // 250 / 50 = 正好 5 行，不留半行残影
              itemExtent: 50,
              itemBuilder: (_, i) => _fontRow(fonts[i], fonts[i].name == _cfg.fontName),
            );
    }

    return Container(
      // 高度交给父级 Expanded（v1.3 两栏布局，列表自适应剩余空间）
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.025),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _C.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          children: [
            Positioned.fill(child: body),
            // 底部渐隐：滚动列表高度自适应后必然会露半行，用一层渐变
            // 让「还有更多」看起来是设计而不是裁切事故。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 14,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _C.bg.withOpacity(0.0),
                        _C.bg.withOpacity(0.92),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listMessage(String text) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(text,
          style: const TextStyle(
              fontSize: 12, height: 1.6, color: _C.textDim)),
    );
  }

  Widget _fontRow(SystemFontFamily f, bool selected) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _cfg = _cfg.copyWith(fontName: f.name)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? _C.accentSoft : Colors.transparent,
            border: Border(
              left: BorderSide(
                  color: selected ? _C.accent : Colors.transparent, width: 2.5),
              bottom: const BorderSide(color: _C.divider),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 用该字体自身渲染，选之前就能看出字形
                    Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: f.name,
                        fontSize: 16,
                        height: 1.2,
                        color: _C.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _charsetText(f),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10, color: _C.textFaint, height: 1.1),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (selected) _appliedBadge() else _charsetBadges(f),
            ],
          ),
        ),
      ),
    );
  }

  String _charsetText(SystemFontFamily f) {
    final items = <String>[];
    if (f.supportsSimplifiedChinese) items.add('简中');
    if (f.supportsTraditionalChinese) items.add('繁中');
    if (f.supportsJapanese) items.add('日文');
    if (f.supportsKorean) items.add('韩文');
    if (items.isEmpty) return f.name;
    return items.join(' · ');
  }

  Widget _charsetBadges(SystemFontFamily f) {
    final items = <(String, int)>[
      if (f.supportsSimplifiedChinese) ('简', FontCharset.gb2312),
      if (f.supportsTraditionalChinese) ('繁', FontCharset.big5),
      if (f.supportsJapanese) ('日', FontCharset.shiftJis),
      if (f.supportsKorean) ('韩', FontCharset.hangul),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final it in items)
          Container(
            margin: const EdgeInsets.only(left: 3),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(it.$1,
                style: const TextStyle(fontSize: 9, color: _C.textFaint)),
          ),
      ],
    );
  }

  Widget _appliedBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: _C.green.withOpacity(0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check, size: 11, color: _C.green),
          SizedBox(width: 3),
          Text('已应用',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: _C.green)),
        ],
      ),
    );
  }

  Widget _hintLine() {
    return Row(
      children: const [
        Expanded(
          child: Text(
            '选好字体点「应用」设为当前方案；游戏内按 Insert 可呼出原生面板实时调。',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, height: 1.35, color: _C.textFaint),
          ),
        ),
      ],
    );
  }

  // ── 分区标题 ────────────────────────────────────────────────

  Widget _sectionTitle(String zh, {String? latin, Widget? trailing}) {
    return Row(
      children: [
        Text(zh,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _C.text)),
        if (latin != null) ...[
          const Spacer(),
          Text(latin,
              style: const TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.1,
                  color: _C.textFaint)),
        ] else if (trailing != null) ...[
          const Spacer(),
          trailing,
        ],
      ],
    );
  }

  // ── 兼容设置 ────────────────────────────────────────────────

  /// 兼容设置三组（调用 / 映射 / 转码）。
  ///
  /// v1.3：左栏只有 300 宽，原先把「映射 + 转码」挤在同一行会溢出，
  /// 改成各占一行。
  Widget _compatSection() {
    final c = _cfg.compat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ① 调用（字符集能力伪装）
        Row(
          children: [
            _switchPill('调用', c.spoof,
                () => _setCompat(c.copyWith(spoof: !c.spoof))),
            const SizedBox(width: 7),
            _dimPill(
              label: FontCharset.pickerLabel(c.spoofFrom),
              enabled: c.spoof,
              items: [
                for (final v in FontCompatPresets.spoofOptions)
                  (FontCharset.pickerLabel(v), v)
              ],
              current: c.spoofFrom,
              onPick: (v) => _setCompat(c.copyWith(spoofFrom: v)),
            ),
            const _Arrow(),
            _dimPill(
              label: FontCharset.pickerLabel(c.spoofTo),
              enabled: c.spoof,
              items: [
                for (final v in FontCompatPresets.spoofOptions)
                  (FontCharset.pickerLabel(v), v)
              ],
              current: c.spoofTo,
              onPick: (v) => _setCompat(c.copyWith(spoofTo: v)),
            ),
          ],
        ),
        const SizedBox(height: 7),

        // ② 映射（日繁 → 简 / 简 → 繁）
        Row(
          children: [
            _switchPill('映射', c.textSubstitution,
                () => _setCompat(c.copyWith(textSubstitution: !c.textSubstitution))),
            const SizedBox(width: 7),
            _dimPill(
              label: FontCompatPresets.textSubstitutionModeLabels[
                  c.textSubstitutionMode.clamp(0, 2).toInt()],
              enabled: c.textSubstitution,
              items: [
                for (var i = 0;
                    i < FontCompatPresets.textSubstitutionModeLabels.length;
                    i++)
                  (FontCompatPresets.textSubstitutionModeLabels[i], i)
              ],
              current: c.textSubstitutionMode,
              onPick: (v) => _setCompat(c.copyWith(textSubstitutionMode: v)),
            ),
            const SizedBox(width: 4),
            _dimPill(
              label: FontCompatPresets.codepageLabel(
                  c.textSubstitutionCodepage),
              enabled: c.textSubstitution,
              items: [
                for (final v in FontCompatPresets.textSubstitutionCodepages)
                  (FontCompatPresets.codepageLabel(v), v)
              ],
              current: c.textSubstitutionCodepage,
              onPick: (v) =>
                  _setCompat(c.copyWith(textSubstitutionCodepage: v)),
            ),
          ],
        ),
        const SizedBox(height: 7),

        // ③ 转码（代码页重定向）
        Row(
          children: [
            _switchPill('转码', c.codepageRedirect,
                () => _setCompat(c.copyWith(codepageRedirect: !c.codepageRedirect))),
            const SizedBox(width: 7),
            Flexible(
              child: _dimPill(
                label: _redirectLabel(c),
                enabled: c.codepageRedirect,
                items: [
                  for (var i = 0;
                      i < FontCompatPresets.redirectPresets.length;
                      i++)
                    (FontCompatPresets.redirectPresets[i].label, i)
                ],
                current: FontCompatPresets.redirectPresetIndex(
                    c.codepageRedirectFrom, c.codepageRedirectTo),
                onPick: (i) {
                  final p = FontCompatPresets.redirectPresets[i];
                  _setCompat(c.copyWith(
                      codepageRedirectFrom: p.from, codepageRedirectTo: p.to));
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _setCompat(FontCompatSettings c) {
    setState(() => _cfg = _cfg.copyWith(compat: c));
  }

  String _redirectLabel(FontCompatSettings c) {
    final i = FontCompatPresets.redirectPresetIndex(
        c.codepageRedirectFrom, c.codepageRedirectTo);
    if (i >= 0) return FontCompatPresets.redirectPresets[i].label;
    return '${FontCompatPresets.codepageLabel(c.codepageRedirectFrom)}→'
        '${FontCompatPresets.codepageLabel(c.codepageRedirectTo)}';
  }

  // ── 字形微调 ────────────────────────────────────────────────

  Widget _resetMetricsBtn() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => setState(
            () => _cfg = _cfg.copyWith(metrics: FontMetrics.defaults)),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text('清空调整',
              style: TextStyle(fontSize: 10.5, color: _C.textDim)),
        ),
      ),
    );
  }

  /// 字形微调：2 列 × 4 行（v1.3 从 3 列改 2 列，适配左栏 300 宽）。
  Widget _metricsGrid() {
    final m = _cfg.metrics;
    final e = m.enabled;

    Widget twoCol(Widget a, Widget b) => Row(
          children: [
            Expanded(child: a),
            const SizedBox(width: 6),
            Expanded(child: b),
          ],
        );

    return Column(
      children: [
        twoCol(
          _metricBox(
            label: '字宽',
            value: (m.widthScale / 1000).toStringAsFixed(2) + 'x',
            enabled: e.width,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(width: v))),
            onMinus: () => _setMetrics(m.copyWith(
                widthScale: (m.widthScale - 10).clamp(500, 2000).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                widthScale: (m.widthScale + 10).clamp(500, 2000).toInt())),
          ),
          _metricBox(
            label: '字高',
            value: (m.heightScale / 1000).toStringAsFixed(2) + 'x',
            enabled: e.height,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(height: v))),
            onMinus: () => _setMetrics(m.copyWith(
                heightScale: (m.heightScale - 10).clamp(500, 2000).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                heightScale: (m.heightScale + 10).clamp(500, 2000).toInt())),
          ),
        ),
        const SizedBox(height: 5),
        twoCol(
          _metricBox(
            label: '字距',
            value: '${m.charSpacing}',
            enabled: e.charSpacing,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(charSpacing: v))),
            onMinus: () => _setMetrics(m.copyWith(
                charSpacing: (m.charSpacing - 1).clamp(-20, 40).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                charSpacing: (m.charSpacing + 1).clamp(-20, 40).toInt())),
          ),
          _metricBox(
            label: '行距',
            value: '${m.lineSpacing}',
            enabled: e.lineSpacing,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(lineSpacing: v))),
            onMinus: () => _setMetrics(m.copyWith(
                lineSpacing: (m.lineSpacing - 1).clamp(-20, 60).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                lineSpacing: (m.lineSpacing + 1).clamp(-20, 60).toInt())),
          ),
        ),
        const SizedBox(height: 5),
        twoCol(
          _metricBox(
            label: '上行',
            value: '${m.ascentPermille}',
            enabled: e.vertical,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(vertical: v))),
            onMinus: () => _setMetrics(m.copyWith(
                ascentPermille: (m.ascentPermille - 10).clamp(400, 1600).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                ascentPermille: (m.ascentPermille + 10).clamp(400, 1600).toInt())),
          ),
          _metricBox(
            label: '下行',
            value: '${m.descentPermille}',
            enabled: e.vertical,
            onToggle: (v) => _setMetrics(
                m.copyWith(enabled: m.enabled.copyWith(vertical: v))),
            onMinus: () => _setMetrics(m.copyWith(
                descentPermille: (m.descentPermille - 10).clamp(-600, 0).toInt())),
            onPlus: () => _setMetrics(m.copyWith(
                descentPermille: (m.descentPermille + 10).clamp(-600, 0).toInt())),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: _metricBox(
                label: '粗细',
                value: '${m.weight}',
                enabled: e.weight,
                onToggle: (v) => _setMetrics(
                    m.copyWith(enabled: m.enabled.copyWith(weight: v))),
                onMinus: () => _setMetrics(m.copyWith(
                    weight: (m.weight - 100).clamp(100, 900).toInt())),
                onPlus: () => _setMetrics(
                    m.copyWith(weight: (m.weight + 100).clamp(100, 900).toInt())),
              ),
            ),
            const SizedBox(width: 6),
            // 机制说明：CTFontHook 的 EnableFont* 默认全关，光改数字不生效
            const Expanded(
              child: Text(
                '勾选后才生效',
                maxLines: 2,
                style: TextStyle(
                    fontSize: 9.5, height: 1.3, color: _C.textFaint),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _metricBox({
    required String label,
    required String value,
    required bool enabled,
    required ValueChanged<bool> onToggle,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 6, right: 2),
      decoration: BoxDecoration(
        color: _C.field,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: enabled ? _C.accent.withOpacity(0.45) : _C.border),
      ),
      child: Row(
        children: [
          _miniCheck(enabled, onToggle),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: enabled ? _C.textDim : _C.textFaint)),
          const Spacer(),
          Text(value,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: enabled ? _C.text : _C.textFaint,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
          const SizedBox(width: 2),
          _stepBtn('-', enabled ? onMinus : null),
          _stepBtn('+', enabled ? onPlus : null),
        ],
      ),
    );
  }

  Widget _miniCheck(bool value, ValueChanged<bool> onToggle) {
    return GestureDetector(
      onTap: () => onToggle(!value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(
          color: value ? _C.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: value ? _C.accent : _C.borderStrong, width: 1),
        ),
        child: value
            ? const Icon(Icons.check, size: 9, color: Colors.white)
            : null,
      ),
    );
  }

  Widget _stepBtn(String glyph, VoidCallback? onTap, {double width = 16}) {
    final on = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(3),
        onTap: onTap,
        child: SizedBox(
          width: width,
          height: 22,
          child: Center(
            child: Text(
              glyph,
              style: TextStyle(
                fontSize: 13,
                height: 1,
                fontWeight: FontWeight.w600,
                color: on ? _C.textDim : _C.textFaint.withOpacity(0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setMetrics(FontMetrics m) {
    setState(() => _cfg = _cfg.copyWith(metrics: m));
  }

  FontWeight _weightOf(int w) {
    if (w <= 150) return FontWeight.w100;
    if (w <= 250) return FontWeight.w200;
    if (w <= 350) return FontWeight.w300;
    if (w <= 450) return FontWeight.w400;
    if (w <= 550) return FontWeight.w500;
    if (w <= 650) return FontWeight.w600;
    if (w <= 750) return FontWeight.w700;
    if (w <= 850) return FontWeight.w800;
    return FontWeight.w900;
  }

  // ── 文字预览 ────────────────────────────────────────────────

  Widget _previewHeader() {
    return Row(
      children: [
        const Text('文字预览',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _C.text)),
        const Spacer(),
        _stepBtn(
            'A-',
            _previewSize > 12 ? () => setState(() => _previewSize -= 2) : null,
            width: 26),
        SizedBox(
          width: 42,
          child: Text('${_previewSize.round()} px',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10.5, color: _C.textDim)),
        ),
        _stepBtn(
            'A+',
            _previewSize < 40 ? () => setState(() => _previewSize += 2) : null,
            width: 26),
      ],
    );
  }

  Widget _previewBox() {
    final m = _cfg.metrics;
    final e = m.enabled;
    final style = TextStyle(
      fontFamily: _cfg.fontName.isEmpty ? null : _cfg.fontName,
      fontSize: _previewSize,
      height: e.lineSpacing ? 1.35 + (m.lineSpacing / 100.0) : 1.35,
      letterSpacing: e.charSpacing ? m.charSpacing.toDouble() : null,
      fontWeight: e.weight ? _weightOf(m.weight) : null,
      color: _C.text,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.25),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _C.accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('「测试文字 Sample Text」',
              style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 6),
          Text('あいうえお 0123456789',
              style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  // ── 底栏 ────────────────────────────────────────────────────

  Widget _footer() {
    final canApply = !_busy && _cfg.hasFont && !_runningNow;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
      child: Row(
        children: [
          if (_runningNow)
            const Expanded(
              child: Text(
                '游戏正在运行，请先关闭后再应用',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: _C.amber),
              ),
            )
          else ...[
            Text(
              '字符集 ${FontCharset.pickerLabel(_cfg.charset)}'
              '（${_cfg.charset}）',
              style: const TextStyle(fontSize: 10.5, color: _C.textFaint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _cfg.fontName.isEmpty ? '未选择字体' : _cfg.fontName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: _C.textFaint),
              ),
            ),
          ],
          const SizedBox(width: 10),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 14,
                height: 14,
                child:
                    CircularProgressIndicator(strokeWidth: 1.8, color: _C.accent),
              ),
            ),
          _textBtn('关闭', onTap: _close),
          const SizedBox(width: 8),
          _primaryBtn('应用', onTap: canApply ? _apply : null),
        ],
      ),
    );
  }

  // ── 共用小部件 ──────────────────────────────────────────────

  Widget _switchPill(String label, bool value, VoidCallback onTap) {
    final color = value ? _C.green : _C.textFaint;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: value ? _C.green.withOpacity(0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: value ? _C.green.withOpacity(0.55) : _C.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$label: ',
                  style: TextStyle(fontSize: 10.5, color: color)),
              Text(value ? '开' : '关',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dimPill({
    required String label,
    required bool enabled,
    required List<(String, int)> items,
    required int current,
    required ValueChanged<int> onPick,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: PopupMenuButton<int>(
        tooltip: '',
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        color: _C.field,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: _C.borderStrong),
        ),
        onSelected: enabled ? onPick : null,
        itemBuilder: (_) => [
          for (final e in items)
            PopupMenuItem<int>(
              value: e.$2,
              height: 32,
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    child: e.$2 == current
                        ? const Icon(Icons.check, size: 11, color: _C.accent)
                        : null,
                  ),
                  Text(e.$1,
                      style: const TextStyle(fontSize: 12, color: _C.text)),
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: _C.field,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _C.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 10.5, color: _C.textDim)),
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, size: 12, color: _C.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 15, color: _C.textDim),
          ),
        ),
      ),
    );
  }

  Widget _textBtn(String label, {VoidCallback? onTap}) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: enabled ? _C.borderStrong : _C.divider),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: enabled ? _C.textDim : _C.textFaint)),
        ),
      ),
    );
  }

  Widget _primaryBtn(String label, {VoidCallback? onTap}) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled ? _C.accent : _C.accent.withOpacity(0.35),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ),
      ),
    );
  }
}

/// 「→」小箭头（兼容设置里 from / to 之间）。
class _Arrow extends StatelessWidget {
  const _Arrow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Text('→',
          style: TextStyle(fontSize: 12, color: _C.textFaint, height: 1)),
    );
  }
}
