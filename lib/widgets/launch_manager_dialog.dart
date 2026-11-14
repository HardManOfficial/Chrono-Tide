import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/locale_service.dart';
import '../services/magpie_service.dart';
import '../services/shortcut_service.dart';
import '../services/icon_extractor_service.dart';
import '../services/game_data_format.dart';
import '../services/exe_scanner.dart';
// ★ 2026-10-24 启动兼容性：兼容性属性配置 + 全局偏好
import '../services/compat_preference.dart';
import '../services/game_compatibility_service.dart';
// ★ 2026-10-26 启动程序智能推荐：分类 / 版本标签 / 唯一推荐
import '../services/launcher_candidate_analyzer.dart';
import 'elevation_hint_dialog.dart';
import 'launcher_badges.dart';
// 游戏字体替换（CTFontHook 接入）：本弹窗提供「启用字体替换」路口
import '../models/game_font_override.dart';
import '../services/game_font_patch_service.dart';
import '../services/font_override_prefs.dart';
import 'font_picker_dialog.dart';
import 'interactive_wrapper.dart';
import 'app_dialog.dart';
import 'app_snack_bar.dart';

/// 启动管理对话框
///
/// 整合了三个核心功能：
/// 1. 启动程序选择（从游戏目录扫描 exe）
/// 2. 启动模式设置（转区 / 超分 / 以管理员身份运行）
/// 3. 桌面快捷方式管理（创建/删除/图标自定义）
///
/// 2026-10-24 新增「兼容性配置」区：Windows 兼容性属性总开关（全局偏好）
/// 与超分/转区引擎自身的提权开关。
class LaunchManagerDialog extends StatefulWidget {
  final String gameTitle;
  final String gameDirectory;
  final String metaDataDir;
  final String? initialExePath;
  final String initialLocaleMode;
  final String initialUpscalingMode;

  /// 该游戏是否「以管理员身份运行」（`game.json.run_as_admin`）
  final bool initialRunAsAdmin;

  /// ★ 2026-10-26：游戏别名（副标题，可为 ` / ` 拼接串）。
  ///
  /// 只喂给启动程序分析器做「exe 名是否与游戏名重合」的判定，空列表时
  /// 分析器自动跳过该证据，其余规则照常工作。
  final List<String> gameSubtitles;

  final ValueChanged<String> onExeSelected;
  final ValueChanged<String>? onLocaleModeChanged;
  final ValueChanged<String>? onUpscalingModeChanged;
  final ValueChanged<bool>? onRunAsAdminChanged;

  /// 仅测试用：跳过 exe 扫描（`flutter_tester` 的 fake-async 不推进真实 IO，
  /// `_isLoading` 永远不会落 ⇒ 正文渲染不出来）。
  final bool debugSkipScan;

  const LaunchManagerDialog({
    super.key,
    required this.gameTitle,
    required this.gameDirectory,
    required this.metaDataDir,
    this.initialExePath,
    this.initialLocaleMode = 'none',
    this.initialUpscalingMode = 'none',
    this.initialRunAsAdmin = false,
    this.gameSubtitles = const <String>[],
    required this.onExeSelected,
    this.onLocaleModeChanged,
    this.onUpscalingModeChanged,
    this.onRunAsAdminChanged,
    this.debugSkipScan = false,
  });

  static Future<void> show({
    required BuildContext context,
    required String gameTitle,
    required String gameDirectory,
    required String metaDataDir,
    String? initialExePath,
    String initialLocaleMode = 'none',
    String initialUpscalingMode = 'none',
    bool initialRunAsAdmin = false,
    List<String> gameSubtitles = const <String>[],
    required ValueChanged<String> onExeSelected,
    ValueChanged<String>? onLocaleModeChanged,
    ValueChanged<String>? onUpscalingModeChanged,
    ValueChanged<bool>? onRunAsAdminChanged,
  }) async {
    await showAppDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => LaunchManagerDialog(
        gameTitle: gameTitle,
        gameDirectory: gameDirectory,
        metaDataDir: metaDataDir,
        initialExePath: initialExePath,
        initialLocaleMode: initialLocaleMode,
        initialUpscalingMode: initialUpscalingMode,
        initialRunAsAdmin: initialRunAsAdmin,
        gameSubtitles: gameSubtitles,
        onExeSelected: onExeSelected,
        onLocaleModeChanged: onLocaleModeChanged,
        onUpscalingModeChanged: onUpscalingModeChanged,
        onRunAsAdminChanged: onRunAsAdminChanged,
      ),
    );
  }

  @override
  State<LaunchManagerDialog> createState() => _LaunchManagerDialogState();
}

class _LaunchManagerDialogState extends State<LaunchManagerDialog> {
  // EXE 选择相关
  List<File> _exeFiles = [];
  File? _selectedFile;
  bool _isLoading = true;
  String _searchQuery = '';

  /// ★ 2026-10-26：分类 / 版本标签 / 推荐（null = 未扫描或分析失败）
  LauncherAnalysis? _analysis;

  /// 每个候选程序的组件架构（`exe 路径 → '32 位' / '64 位' / '未知'`）。
  ///
  /// 字体器要装与启动程序**同位数**的 winmm.dll，这里提前显示，
  /// 玩家不用等装失败才发现选错了程序。
  final Map<String, String> _exeArch = {};

  // 启动模式
  bool _localeEnabled = false;
  bool _upscalingEnabled = false;
  bool _localeAvailable = false;
  bool _magpieAvailable = false;

  // ★ 2026-10-24 启动兼容性
  /// 该游戏是否「以管理员身份运行」（写 game.json.run_as_admin）
  bool _runAsAdmin = false;

  /// 全局「自动配置兼容性属性」总开关（读写 CompatPreference）
  bool _compatEnabled = true;

  /// 超分 / 转区引擎是否以管理员身份运行（全局偏好）
  bool _elevateTools = true;

  // 快捷方式相关
  bool _hasShortcut = false;
  bool _isProcessingShortcut = false;

  // 字体替换（CTFontHook）
  PatchState _fontState = PatchState.notInstalled;
  String _fontArch = '';
  String _fontName = '';
  bool _fontBusy = false;
  // （2026-09-27 起「首次启动自动生成」开关已迁至设置窗口的全局偏好，
  //   本弹窗不再持有该状态，见 lib/services/auto_shortcut_preference.dart）

  // 图标设置
  IconSource _iconSource = IconSource.exeDefault;

  @override
  void initState() {
    super.initState();
    _localeEnabled = widget.initialLocaleMode == 'japanese';
    _upscalingEnabled = widget.initialUpscalingMode == 'magpie';
    _runAsAdmin = widget.initialRunAsAdmin;
    _loadCompatPrefs();
    if (widget.debugSkipScan) {
      _isLoading = false;
    } else {
      _scanForExecutables();
      _checkLocaleAvailability();
      _checkMagpieAvailability();
      _checkShortcutStatus();
      _loadFontState();
    }
  }

  // ==================== 启动兼容性（2026-10-24） ====================

  /// 读取全局兼容性偏好（幂等；本弹窗是写入方之一）
  Future<void> _loadCompatPrefs() async {
    final pref = CompatPreference.instance;
    await pref.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _compatEnabled = pref.enabled;
      _elevateTools = pref.elevateTools;
    });
    // ★ 2026-10-24 推荐项 4：该游戏本来就开着「以管理员身份运行」时，
    //   打开本弹窗也提示一次（一生只弹一次，故不会反复打扰）。
    if (_runAsAdmin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) maybeShowElevationHint(context, needsElevation: true);
      });
    }
  }

  /// 把当前 exe 的兼容性属性**立即**同步到注册表
  ///
  /// 用户在这个弹窗里切换「以管理员身份运行」后立刻生效，不必等到下次启动 ——
  /// 这样桌面快捷方式（.lnk 直达 exe，绕过管理器）也能马上带上 `RUNASADMIN`。
  Future<void> _syncCompatNow() async {
    final exe = GameCompatibilityService.canonicalExePath(_effectiveExePath);
    if (exe.isEmpty) return;
    try {
      await CompatPreference.instance.ensureLoaded();
      final desired = CompatDesired.resolve(
        autoConfigEnabled: CompatPreference.instance.enabled,
        runAsAdmin: _runAsAdmin,
      );
      await GameCompatibilityService.instance.ensure(exe, desired);
    } catch (e) {
      debugPrint('[LAUNCH-MANAGER] 兼容性同步失败（不影响设置保存）: $e');
    }
  }

  // ==================== 字体器（CTFontHook 接入） ====================

  /// 当前生效的启动程序绝对路径（面板里选中的优先，其次调用方传入的）。
  String get _effectiveExePath =>
      _currentExePath.isNotEmpty ? _currentExePath : (widget.initialExePath ?? '');

  /// 读取补丁状态与当前字体名。
  Future<void> _loadFontState() async {
    try {
      await FontOverridePrefs.instance.ensureLoaded();
      final exe = _effectiveExePath;
      final probe = GameFontPatchService.probe(
        widget.gameDirectory,
        exePath: exe.isEmpty ? null : exe,
      );
      final cfg = GameFontPatchService.readConfig(widget.gameDirectory);
      if (!mounted) return;
      setState(() {
        _fontState = probe.state;
        _fontArch = probe.manifest?.dllArch ?? '';
        _fontName = (cfg?.fontName ?? '').trim();
      });
    } catch (e) {
      debugPrint('[FONT] 读取字体器状态失败: $e');
    }
  }

  /// 安装字体器：投放对应位数的 winmm.dll + 写一份能生效的 `FontHook.ini`。
  ///
  /// 字体名取「建议默认字体」（首选微软雅黑），因为空的 `FontNameW` 会让
  /// CTFontHook 的 `LoadConfig` 整体失败 —— 装完必须是一份可用配置，
  /// 具体字形/排版由玩家在游戏内面板或「字体设置」里再调。
  Future<void> _installFontProgram() async {
    if (_fontBusy) return;
    final exe = _effectiveExePath;
    if (exe.isEmpty) {
      AppSnackBar.warning(context, '请先在上方选择一个启动程序');
      return;
    }
    setState(() => _fontBusy = true);
    try {
      final fontName = await FontOverridePrefs.suggestFontName();
      if (fontName.isEmpty) {
        if (mounted) {
          AppSnackBar.error(context, '未能确定可用字体，请改用「字体设置」手动选择');
        }
        return;
      }
      await GameFontPatchService.install(widget.gameDirectory, exePath: exe);
      final existing = GameFontPatchService.readConfig(widget.gameDirectory);
      final keepName = (existing?.fontName ?? '').trim();
      final cfg = (existing ?? GameFontOverride.disabled).copyWith(
        enabled: true,
        fontName: keepName.isEmpty ? fontName : keepName,
      );
      await GameFontPatchService.writeConfig(widget.gameDirectory, cfg);
      await GameDataFormat.updateGameJson(
          widget.metaDataDir, {'font_override': cfg.toJson()});
      if (mounted) AppSnackBar.success(context, '已安装字体器');
      await _loadFontState();
    } on FontPatchException catch (e) {
      if (mounted) AppSnackBar.error(context, e.message);
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '安装失败：$e');
    } finally {
      if (mounted) setState(() => _fontBusy = false);
    }
  }

  /// 恢复（= 卸载还原）：删掉投放的 dll 与备份目录，游戏回到原字体。
  ///
  /// 🔴 保留 `fontName`：只是把 `enabled` 置 false。空字体名会让
  /// CTFontHook 的 `LoadConfig` 失败，比「没配置」更糟。
  Future<void> _restoreFontProgram() async {
    if (_fontBusy) return;
    setState(() => _fontBusy = true);
    try {
      // 先读一份当前配置：若游戏原本就带 FontHook.ini，`uninstall` 会用备份覆盖
      // 我们的版本，之后读回来就丢了玩家选好的字体名。
      final before = GameFontPatchService.readConfig(widget.gameDirectory) ??
          GameFontOverride.disabled;
      await GameFontPatchService.uninstall(widget.gameDirectory);
      final cfg = before.copyWith(enabled: false, patchedAt: '');
      await GameDataFormat.updateGameJson(
          widget.metaDataDir, {'font_override': cfg.toJson()});
      if (mounted) AppSnackBar.info(context, '已恢复原游戏字体');
      await _loadFontState();
    } on FontPatchException catch (e) {
      if (mounted) AppSnackBar.error(context, e.message);
    } catch (e) {
      if (mounted) AppSnackBar.error(context, '恢复失败：$e');
    } finally {
      if (mounted) setState(() => _fontBusy = false);
    }
  }

  /// 打开「字体选择器」窗口（v1.2 起改回独立窗口，不再贴按钮展开浮层）。
  void _openFontSettings() {
    if (_fontBusy) return;
    FontPickerDialog.open(
      context: context,
      gameTitle: widget.gameTitle,
      gameDirectory: widget.gameDirectory,
      launchPath: _effectiveExePath,
      metaDataDir: widget.metaDataDir,
      onChanged: () => _loadFontState(),
    );
  }

  Widget _buildFontSection() {
    final installed = _fontState == PatchState.installedByUs ||
        _fontState == PatchState.installedByExternal;
    final damaged = _fontState == PatchState.staleOrDamaged;

    final statusText = switch (_fontState) {
      PatchState.installedByUs => '已安装${_fontArch.isEmpty ? "" : "（$_fontArch）"}',
      PatchState.installedByExternal => '外部安装',
      PatchState.staleOrDamaged => '不完整',
      PatchState.notInstalled => '未安装',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.font_download_outlined,
            title: '字体替换',
            trailing: statusText,
            trailingColor: installed
                ? AppColors.successGreen
                : (damaged ? AppColors.warningAmber : null),
          ),
          const SizedBox(height: 6),
          // 提示文：放在标题与操作区之间（用户 2026-10-17 指定）
          Text(
            installed
                ? '游戏启动时自动换用下面的字体；也可进游戏按 Insert 呼出字体面板实时调整。'
                : '在游戏目录内安装字体程序（winmm.dll），可解决乱码 / 缺字 / 字体发虚；'
                    '装好后进游戏按 Insert 即可选字体。',
            style: TextStyle(
                fontSize: 11.5, height: 1.5, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // ① 安装 / 恢复
              _fontActionButton(installed || damaged),
              const SizedBox(width: 10),
              // ② 当前生效的字体（未安装 ⇒ 原游戏字体）
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _fontCurrentChip(installed),
                ),
              ),
              // ③ 字体设置（装好之后才出现）
              if (installed)
                _fontSettingsButton(_openFontSettings),
            ],
          ),
        ],
      ),
    );
  }

  /// 安装 / 恢复按钮（不再是拉杆样式）。
  Widget _fontActionButton(bool installed) {
    final label = installed ? '恢复' : '安装';
    final color = installed ? AppColors.dangerRed : AppColors.selectedAccent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _fontBusy
            ? null
            : () {
                if (installed) {
                  _restoreFontProgram();
                } else {
                  _installFontProgram();
                }
              },
        child: Container(
          height: 30,
          constraints: const BoxConstraints(minWidth: 66),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withOpacity(installed ? 0.06 : 0.10),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: color.withOpacity(0.45)),
          ),
          child: _fontBusy
              ? SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.8, color: color),
                )
              : Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: color)),
        ),
      ),
    );
  }

  /// 当前字体胶囊。
  Widget _fontCurrentChip(bool installed) {
    final text = installed
        ? (_fontName.isEmpty ? '未选择字体' : _fontName)
        : '原游戏字体';
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.text_fields, size: 12, color: AppColors.placeholderText),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: installed
                    ? AppColors.primaryText
                    : AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fontSettingsButton(VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _fontBusy ? null : onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('字体设置',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.selectedAccent)),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right,
                  size: 14, color: AppColors.selectedAccent),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _checkLocaleAvailability() async {
    final available = await LocaleService.isLocaleAvailable();
    if (mounted) setState(() => _localeAvailable = available);
  }

  Future<void> _checkMagpieAvailability() async {
    final available = await MagpieService.instance.isAvailable();
    if (mounted) setState(() => _magpieAvailable = available);
  }

  Future<void> _checkShortcutStatus() async {
    final hasShortcut = ShortcutService.instance.hasShortcut(widget.gameTitle);
    final hasCustomIcon =
        IconExtractorService.instance.hasCustomIcon(widget.metaDataDir);

    // 读取 game.json 中的自定义图标路径与快捷方式路径
    final jsonData = await GameDataFormat.readGameJson(widget.metaDataDir);
    final customIconPath = jsonData?.customIconPath ?? '';
    final storedShortcutPath = jsonData?.shortcutPath ?? '';

    // ★ 一致性修复：.lnk 不存在但 shortcut_path 非空 → 清空 shortcut_path
    // 触发场景：用户从文件资源管理器手动删除 .lnk，此时 game.json 字段已陈旧
    if (!hasShortcut && storedShortcutPath.isNotEmpty) {
      try {
        await GameDataFormat.updateGameJson(widget.metaDataDir, {
          'shortcut_path': '',
        });
        debugPrint('[SHORTCUT] 已清理陈旧的 shortcut_path: $storedShortcutPath');
      } catch (e) {
        debugPrint('[SHORTCUT] 清理 shortcut_path 异常: $e');
      }
    }

    if (mounted) {
      setState(() {
        _hasShortcut = hasShortcut;
        _iconSource = (hasCustomIcon || customIconPath.isNotEmpty)
            ? IconSource.coverCustom
            : IconSource.exeDefault;
      });
    }
  }

  Future<void> _scanForExecutables() async {
    try {
      final dir = Directory(widget.gameDirectory);
      if (!await dir.exists()) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }
      // 限制扫描深度（3层）和数量（200个），避免大目录卡死
      // UX-26: 改用共享的 ExeScanner，消除与 ExeSelectorDialog 的重复实现
      final exeFiles =
          await ExeScanner.scanBounded(dir, maxDepth: 3, maxCount: 200);

      // ★ 2026-10-26 智能推荐：分类 + 版本标签 + 唯一推荐。
      //   失败只影响角标，不影响列表本身（选择器必须有兜底可用的底线）。
      LauncherAnalysis? analysis;
      try {
        analysis = LauncherCandidateAnalyzer.analyzeSync(
          files: exeFiles,
          gameDirectory: widget.gameDirectory,
          gameTitle: widget.gameTitle,
          gameAliases: widget.gameSubtitles,
        );
      } catch (e) {
        debugPrint('[LAUNCH-MANAGER] 候选分析失败（不影响选择）: $e');
      }

      if (mounted) {
        setState(() {
          _analysis = analysis;
          _exeFiles = exeFiles
            ..sort(
                (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
          if (_exeFiles.isNotEmpty) {
            if (widget.initialExePath != null &&
                _exeFiles.any((f) => f.path == widget.initialExePath)) {
              _selectedFile =
                  _exeFiles.firstWhere((f) => f.path == widget.initialExePath);
            } else {
              _selectedFile = _exeFiles.first;
            }
          }
          // 顺带判出每个程序的组件架构：字体器要装与启动程序同位数，
          // 提前显示能避免「装完才发现不匹配」。
          _exeArch.clear();
          for (final f in _exeFiles) {
            _exeArch[f.path] = _archLabel(f.path);
          }
          _isLoading = false;
        });
        // 选中项确定后再读一次字体器状态（此前 exe 未知，架构判不出来）
        await _loadFontState();
      }
    } catch (e) {
      debugPrint('扫描可执行文件失败: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<File> get _filteredExes {
    if (_searchQuery.isEmpty) return _exeFiles;
    final query = _searchQuery.toLowerCase();
    return _exeFiles
        .where((f) => f.path.toLowerCase().contains(query))
        .toList();
  }

  /// 获取当前选中 exe 的解析路径
  String get _currentExePath => _selectedFile?.path ?? '';

  /// PE 头判定组件架构，转成面板上的短标签。
  String _archLabel(String exePath) {
    try {
      return switch (GameFontPatchService.detectPeArchFromHeader(exePath)) {
        PeArch.x86 => '32 位',
        PeArch.x64 => '64 位',
        PeArch.unknown => '未知架构',
      };
    } catch (_) {
      return '未知架构';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 580,
        height: 640,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.border.withOpacity(0.15),
              offset: const Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading
                  ? _buildLoading()
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildExeSection(),
                          _buildDivider(),
                          _buildLaunchModeSection(),
                          _buildDivider(),
                          _buildCompatSection(),
                          _buildDivider(),
                          _buildFontSection(),
                          _buildDivider(),
                          _buildShortcutSection(),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded,
              size: 20, color: AppColors.primaryText.withOpacity(0.7)),
          const SizedBox(width: 10),
          Text('启动管理',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText)),
          const SizedBox(width: 8),
          Text('· ${widget.gameTitle}',
              style: TextStyle(
                  fontSize: 13,
                  color: AppColors.secondaryText)),
          const Spacer(),
          InteractiveWrapper(
            onTap: () => Navigator.pop(context),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded,
                  size: 18, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 启动程序选择 ====================

  Widget _buildExeSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.folder_open_rounded,
            title: '启动程序选择',
            trailing: '${_filteredExes.length} 个程序',
          ),
          const SizedBox(height: 10),
          _buildSearchBar(),
          const SizedBox(height: 8),
          _exeFiles.isEmpty
              ? _buildEmptyExe()
              : SizedBox(
                  height: 180,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    itemCount: _filteredExes.length,
                    itemBuilder: (_, index) =>
                        _buildExeItem(_filteredExes[index]),
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      onChanged: (v) => setState(() => _searchQuery = v),
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: '搜索程序名...',
        hintStyle: TextStyle(
            fontSize: 13,
            color: AppColors.placeholderText),
        prefixIcon:
            Icon(Icons.search, size: 18, color: AppColors.secondaryText),
        isDense: true,
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  Widget _buildExeItem(File file) {
    final isSelected = file.path == _selectedFile?.path;
    final fileName = file.path.split('\\').last;
    final relativePath =
        file.path.replaceFirst('${widget.gameDirectory}\\', '');

    // ★ 2026-10-26：分类与版本标签；分析结果缺失时退化为"什么都不标"
    final candidate = _analysis?.forPath(file.path);
    final isRecommended = _analysis?.isRecommended(file.path) ?? false;
    final versionLabel = candidate?.versionLabel ?? '';

    return InteractiveWrapper(
      onTap: () {
        setState(() => _selectedFile = file);
        // 换了启动程序 ⇒ 位数可能不同，字体器状态要重判
        _loadFontState();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryText.withOpacity(0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryText.withOpacity(0.3)
                : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primaryText.withOpacity(0.1)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.play_arrow_rounded,
                  size: 15,
                  color: isSelected
                      ? AppColors.primaryText
                      : AppColors.secondaryText),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // 🔴 必须 Flexible + ellipsis：本行右侧还要排推荐角标、
                      //    工具角标、架构标签和勾选图标，文件名不让位就会溢出
                      Flexible(
                        child: Text(fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primaryText)),
                      ),
                      if (isRecommended) ...[
                        const SizedBox(width: 6),
                        LauncherRecommendBadge(
                            tooltip: candidate?.recommendTooltip),
                      ] else if (candidate != null && candidate.isTool) ...[
                        const SizedBox(width: 6),
                        const LauncherToolBadge(
                            tooltip: '配套工具 / 运行库，不是启动游戏用的程序'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    versionLabel.isEmpty
                        ? relativePath
                        : '$relativePath  ·  $versionLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
            if (_exeArch[file.path] != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  _exeArch[file.path]!,
                  style: TextStyle(
                      fontSize: 10.5, color: AppColors.secondaryText),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (isSelected)
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppColors.primaryText.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyExe() {
    return SizedBox(
      height: 100,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_rounded,
                size: 36, color: AppColors.secondaryText.withOpacity(0.3)),
            const SizedBox(height: 8),
            Text('未找到可执行文件',
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.secondaryText)),
          ],
        ),
      ),
    );
  }

  // ==================== 启动模式 ====================

  Widget _buildLaunchModeSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.rocket_launch_rounded,
            title: '启动模式',
          ),
          const SizedBox(height: 8),
          _buildToggleRow(
            icon: Icons.language_rounded,
            iconColor: _localeEnabled ? const Color(0xFFE91E63) : null,
            title: '日语转区启动',
            subtitle:
                _localeAvailable ? '使用 Locale Emulator 以日区运行' : '⚠ 未检测到转区引擎',
            subtitleColor: !_localeAvailable ? const Color(0xFFE65100) : null,
            value: _localeEnabled,
            activeColor: const Color(0xFFE91E63),
            onChanged: (value) {
              setState(() => _localeEnabled = value);
              widget.onLocaleModeChanged?.call(value ? 'japanese' : 'none');
            },
          ),
          const SizedBox(height: 4),
          _buildToggleRow(
            icon: Icons.auto_fix_high_rounded,
            iconColor: _upscalingEnabled ? const Color(0xFF7C4DFF) : null,
            title: '超分启动',
            subtitle: _magpieAvailable ? '使用 Magpie 进行超分辨率缩放' : '⚠ 未检测到 Magpie',
            subtitleColor: !_magpieAvailable ? const Color(0xFFEF6C00) : null,
            value: _upscalingEnabled,
            activeColor: const Color(0xFF7C4DFF),
            onChanged: (value) {
              setState(() => _upscalingEnabled = value);
              widget.onUpscalingModeChanged?.call(value ? 'magpie' : 'none');
            },
          ),
          const SizedBox(height: 4),
          // ★ 2026-10-24：「以管理员身份运行」与转区/超分并列，独立开关
          _buildToggleRow(
            icon: Icons.admin_panel_settings_rounded,
            iconColor: _runAsAdmin ? const Color(0xFFF59E0B) : null,
            title: '以管理员身份运行',
            subtitle: _runAsAdmin
                ? '该游戏以管理员权限启动（可能触发 UAC 确认）'
                : '默认关闭 · 适用于提示"权限不足"的游戏',
            value: _runAsAdmin,
            activeColor: const Color(0xFFF59E0B),
            onChanged: (value) {
              setState(() => _runAsAdmin = value);
              widget.onRunAsAdminChanged?.call(value);
              // 立即写注册表：桌面快捷方式直达 exe，不经过管理器也要生效
              _syncCompatNow();
              // ★ 2026-10-24 推荐项 4：刚打开提权开关是「建议以管理员重启」最
              //   可执行的时机（用户此刻正为权限问题做决定）。一生只弹一次。
              if (value && mounted) {
                maybeShowElevationHint(context, needsElevation: true);
              }
            },
          ),
        ],
      ),
    );
  }

  // ==================== 兼容性配置（2026-10-24） ====================

  Widget _buildCompatSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.tune_rounded,
            title: '兼容性配置',
            trailing: _compatEnabled ? '自动' : '已关闭',
            trailingColor: _compatEnabled ? AppColors.successGreen : null,
          ),
          const SizedBox(height: 8),
          _buildToggleRow(
            icon: Icons.auto_mode_rounded,
            iconColor: _compatEnabled ? const Color(0xFF00897B) : null,
            title: '自动配置兼容性属性',
            subtitle: _compatEnabled
                ? 'Windows 8 兼容模式 · 禁用全屏优化 · 替代高 DPI 缩放'
                : '已关闭 · 不再写入，之前写入的也已撤销',
            value: _compatEnabled,
            activeColor: const Color(0xFF00897B),
            onChanged: (value) async {
              setState(() => _compatEnabled = value);
              await CompatPreference.instance.setEnabled(value);
              await _syncCompatNow();
            },
          ),
          const SizedBox(height: 4),
          _buildToggleRow(
            icon: Icons.verified_user_rounded,
            iconColor: _elevateTools ? const Color(0xFF5E35B1) : null,
            title: '超分 / 转区以管理员身份运行',
            subtitle: _elevateTools
                ? '引擎本身提权，覆盖需要更高权限才能工作的游戏'
                : '已关闭 · 引擎以管理器当前权限运行',
            value: _elevateTools,
            activeColor: const Color(0xFF5E35B1),
            onChanged: (value) async {
              setState(() => _elevateTools = value);
              await CompatPreference.instance.setElevateTools(value);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 6),
            child: Text(
              '转区引擎是游戏的父进程，它提权后游戏也会以管理员身份运行；'
              '超分引擎是独立进程，两者权限互不影响。'
              '管理器自身以管理员运行时不会弹 UAC。',
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: AppColors.secondaryText,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleRow({
    required IconData icon,
    Color? iconColor,
    required String title,
    String? subtitle,
    Color? subtitleColor,
    required bool value,
    required Color activeColor,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor ?? AppColors.secondaryText),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (subtitle != null)
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: subtitleColor ?? AppColors.secondaryText)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: activeColor,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  // ==================== 桌面快捷方式 ====================

  Widget _buildShortcutSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(
            icon: Icons.desktop_windows_rounded,
            title: '桌面快捷方式',
            trailing: _hasShortcut ? '✓ 已生成' : '未生成',
            trailingColor: _hasShortcut ? AppColors.successGreen : null,
          ),
          const SizedBox(height: 8),
          // 图标设置
          if (_hasShortcut || _selectedFile != null) ...[
            Text('图标设置',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondaryText)),
            const SizedBox(height: 6),
            _buildIconSourceOption(
              value: IconSource.exeDefault,
              title: '使用程序自带图标',
              subtitle: '从选中的 exe 文件提取图标',
            ),
            _buildIconSourceOption(
              value: IconSource.coverCustom,
              title: '使用封面图作为图标',
              subtitle: '从游戏封面裁剪中心区域生成图标',
            ),
            const SizedBox(height: 10),
          ],
          // 操作按钮
          Row(
            children: [
              if (_hasShortcut) ...[
                Expanded(
                  child: _buildActionButton(
                    label: '重新生成',
                    icon: Icons.refresh_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleCreateShortcut,
                    isPrimary: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildActionButton(
                    label: '删除快捷方式',
                    icon: Icons.delete_outline_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleDeleteShortcut,
                    isPrimary: false,
                    danger: true,
                  ),
                ),
              ] else
                Expanded(
                  child: _buildActionButton(
                    label: '生成桌面快捷方式',
                    icon: Icons.add_rounded,
                    onPressed:
                        _isProcessingShortcut ? null : _handleCreateShortcut,
                    isPrimary: true,
                  ),
                ),
            ],
          ),
          if (_isProcessingShortcut)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildIconSourceOption({
    required IconSource value,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _iconSource == value;
    return InteractiveWrapper(
      onTap: () => setState(() => _iconSource = value),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryText.withOpacity(0.04)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryText.withOpacity(0.25)
                : AppColors.border.withOpacity(0.15),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 16,
              color:
                  isSelected ? AppColors.primaryText : AppColors.secondaryText,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.secondaryText)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 快捷方式操作 ====================

  /// 应用快捷方式设置（图标源处理 + 保存图标路径 + 创建 .lnk）
  ///
  /// 抽取自 [_handleCreateShortcut]，供创建/重新生成/保存时自动同步共用。
  /// 返回是否创建成功。
  Future<bool> _applyShortcut() async {
    String? customIconPath;

    // 如果选择使用封面图标，先生成 ico 文件
    if (_iconSource == IconSource.coverCustom) {
      final coverFile = GameDataFormat.findCoverFile(widget.metaDataDir);
      if (coverFile != null) {
        customIconPath =
            IconExtractorService.instance.getCustomIconPath(widget.metaDataDir);
        final success = await IconExtractorService.instance.convertCoverToIco(
          coverPath: coverFile.path,
          outputPath: customIconPath,
        );
        if (!success) {
          _showSnackBar('封面图标转换失败，将使用程序默认图标', level: NoticeLevel.warning);
          customIconPath = null;
        }
      } else {
        _showSnackBar('未找到封面图片，将使用程序默认图标', level: NoticeLevel.warning);
      }
    } else {
      // 使用程序图标，删除已有的自定义图标
      await IconExtractorService.instance.deleteCustomIcon(widget.metaDataDir);
    }

    // 保存图标路径到 game.json
    await GameDataFormat.updateGameJson(widget.metaDataDir, {
      'custom_icon_path': customIconPath ?? '',
    });

    // 创建快捷方式
    return ShortcutService.instance.createShortcut(
      gameTitle: widget.gameTitle,
      exePath: _currentExePath,
      gameDirectory: widget.gameDirectory,
      customIconPath: customIconPath,
      localeMode: _localeEnabled ? 'japanese' : 'none',
      upscalingMode: _upscalingEnabled ? 'magpie' : 'none',
    );
  }

  Future<void> _handleCreateShortcut() async {
    if (_currentExePath.isEmpty) {
      _showSnackBar('请先选择启动程序', level: NoticeLevel.warning);
      return;
    }

    setState(() => _isProcessingShortcut = true);

    try {
      final success = await _applyShortcut();
      if (success) {
        setState(() {
          _hasShortcut = true;
        });
        _showSnackBar('桌面快捷方式已生成', level: NoticeLevel.success);
      } else {
        _showSnackBar('快捷方式创建失败', level: NoticeLevel.error);
      }
    } catch (e) {
      _showSnackBar('操作失败: $e', level: NoticeLevel.error);
    } finally {
      if (mounted) setState(() => _isProcessingShortcut = false);
    }
  }

  Future<void> _handleDeleteShortcut() async {
    setState(() => _isProcessingShortcut = true);

    try {
      final success =
          await ShortcutService.instance.deleteShortcut(widget.gameTitle);
      if (success) {
        // 同时删除自定义图标
        await IconExtractorService.instance
            .deleteCustomIcon(widget.metaDataDir);
        await GameDataFormat.updateGameJson(widget.metaDataDir, {
          'custom_icon_path': '',
        });

        setState(() {
          _hasShortcut = false;
          _iconSource = IconSource.exeDefault;
        });
        _showSnackBar('桌面快捷方式已删除', level: NoticeLevel.success);
      } else {
        _showSnackBar('未找到快捷方式', level: NoticeLevel.warning);
      }
    } catch (e) {
      _showSnackBar('操作失败: $e', level: NoticeLevel.error);
    } finally {
      if (mounted) setState(() => _isProcessingShortcut = false);
    }
  }

  // ==================== 通用组件 ====================

  Widget _buildSectionTitle({
    required IconData icon,
    required String title,
    String? trailing,
    Color? trailingColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.secondaryText),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryText)),
        const Spacer(),
        if (trailing != null)
          Text(trailing,
              style: TextStyle(
                  fontSize: 12,
                  color: trailingColor ?? AppColors.secondaryText)),
      ],
    );
  }

  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Divider(height: 1, color: AppColors.border.withOpacity(0.2)),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    required bool isPrimary,
    bool danger = false,
  }) {
    final isDisabled = onPressed == null;
    Color bgColor;
    Color textColor;

    if (isDisabled) {
      bgColor = AppColors.primaryText.withOpacity(0.05);
      textColor = AppColors.secondaryText.withOpacity(0.5);
    } else if (danger) {
      bgColor = AppColors.dangerRed.withOpacity(0.08);
      textColor = AppColors.dangerRed;
    } else if (isPrimary) {
      bgColor = AppColors.primaryText;
      textColor = Colors.white;
    } else {
      bgColor = AppColors.primaryText.withOpacity(0.08);
      textColor = AppColors.primaryText;
    }

    return InteractiveWrapper(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textColor)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(child: CircularProgressIndicator(color: AppColors.border));
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: BoxDecoration(
        border:
            Border(top: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildActionButton(
            label: '取消',
            icon: Icons.close_rounded,
            onPressed: () => Navigator.pop(context),
            isPrimary: false,
          ),
          const SizedBox(width: 12),
          _buildActionButton(
            label: '保存并关闭',
            icon: Icons.check_rounded,
            onPressed: _handleSave,
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  void _handleSave() {
    _handleSaveAsync();
  }

  /// 保存设置并关闭对话框
  ///
  /// 若桌面快捷方式已存在且 exe 路径或启动模式发生变化，会自动重新生成
  /// 快捷方式以保持同步（仅 SnackBar 提示，不打扰用户）。
  Future<void> _handleSaveAsync() async {
    final selectedExePath = _selectedFile?.path ?? '';

    // 检查 exe 路径或启动模式是否变化（与 widget 初始值对比）
    final exeChanged =
        selectedExePath.isNotEmpty && selectedExePath != widget.initialExePath;
    final localeChanged =
        (_localeEnabled ? 'japanese' : 'none') != widget.initialLocaleMode;
    final upscalingChanged =
        (_upscalingEnabled ? 'magpie' : 'none') != widget.initialUpscalingMode;
    final needsShortcutSync =
        _hasShortcut && (exeChanged || localeChanged || upscalingChanged);

    // 1. 通知父组件 exe 选择（原逻辑，保持同步执行）
    if (_selectedFile != null) {
      widget.onExeSelected(_selectedFile!.path);
    }

    // 2. 自动同步快捷方式（仅当已生成且关键属性变化时）
    if (needsShortcutSync && selectedExePath.isNotEmpty) {
      setState(() => _isProcessingShortcut = true);
      try {
        final success = await _applyShortcut();
        if (success) {
          _showSnackBar('桌面快捷方式已自动同步更新', level: NoticeLevel.success);
        } else {
          _showSnackBar('快捷方式同步失败，请手动点击"重新生成"', level: NoticeLevel.error);
        }
      } catch (e) {
        _showSnackBar('快捷方式同步失败: $e', level: NoticeLevel.error);
      } finally {
        if (mounted) setState(() => _isProcessingShortcut = false);
      }
    }

    if (mounted) Navigator.of(context).pop();
  }

  void _showSnackBar(String message, {NoticeLevel level = NoticeLevel.info}) {
    if (!mounted) return;
    AppSnackBar.show(context, level, message);
  }
}

/// 图标来源选项
enum IconSource {
  /// 使用 exe 自带图标
  exeDefault,

  /// 使用封面图裁剪生成
  coverCustom,
}
