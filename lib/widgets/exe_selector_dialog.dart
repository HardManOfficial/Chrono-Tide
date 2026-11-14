import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/locale_service.dart';
import '../services/magpie_service.dart';
import '../services/exe_scanner.dart';
import '../services/launcher_candidate_analyzer.dart';
import 'interactive_wrapper.dart';
import 'launcher_badges.dart';

class ExeSelectorDialog extends StatefulWidget {
  final String gameDirectory;
  final String? initialExePath;
  final String initialLocaleMode;
  final String initialUpscalingMode;

  /// ★ 2026-10-26 启动程序智能推荐：游戏标题与别名（别名可为 ` / ` 拼接串）。
  ///
  /// 只用于「这个 exe 名是不是就是游戏名 / 与游戏中文名重合」的判定，
  /// **不参与**任何启动逻辑。为空时分析器自动跳过相关证据，其余规则照常。
  final String gameTitle;
  final List<String> gameSubtitles;

  /// ★ 2026-10-24：该游戏是否「以管理员身份运行」
  final bool initialRunAsAdmin;
  final ValueChanged<String> onSelected;
  final ValueChanged<String>? onLocaleModeChanged;
  final ValueChanged<String>? onUpscalingModeChanged;
  final ValueChanged<bool>? onRunAsAdminChanged;

  const ExeSelectorDialog({
    super.key,
    required this.gameDirectory,
    this.initialExePath,
    this.initialLocaleMode = 'none',
    this.initialUpscalingMode = 'none',
    this.gameTitle = '',
    this.gameSubtitles = const <String>[],
    this.initialRunAsAdmin = false,
    required this.onSelected,
    this.onLocaleModeChanged,
    this.onUpscalingModeChanged,
    this.onRunAsAdminChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required String gameDirectory,
    String? initialExePath,
    String initialLocaleMode = 'none',
    String initialUpscalingMode = 'none',
    String gameTitle = '',
    List<String> gameSubtitles = const <String>[],
    bool initialRunAsAdmin = false,
    required ValueChanged<String> onSelected,
    ValueChanged<String>? onLocaleModeChanged,
    ValueChanged<String>? onUpscalingModeChanged,
    ValueChanged<bool>? onRunAsAdminChanged,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => ExeSelectorDialog(
        gameDirectory: gameDirectory,
        initialExePath: initialExePath,
        initialLocaleMode: initialLocaleMode,
        initialUpscalingMode: initialUpscalingMode,
        gameTitle: gameTitle,
        gameSubtitles: gameSubtitles,
        initialRunAsAdmin: initialRunAsAdmin,
        onSelected: onSelected,
        onLocaleModeChanged: onLocaleModeChanged,
        onUpscalingModeChanged: onUpscalingModeChanged,
        onRunAsAdminChanged: onRunAsAdminChanged,
      ),
    );
  }

  @override
  State<ExeSelectorDialog> createState() => _ExeSelectorDialogState();
}

class _ExeSelectorDialogState extends State<ExeSelectorDialog> {
  List<File> _exeFiles = [];
  File? _selectedFile;
  bool _isLoading = true;
  String _searchQuery = '';
  bool _localeEnabled = false;
  bool _upscalingEnabled = false;
  bool _localeAvailable = false;
  bool _magpieAvailable = false;

  /// ★ 2026-10-24：该游戏「以管理员身份运行」
  bool _runAsAdmin = false;

  /// ★ 2026-10-26：扫描后的分类/版本/推荐结果（null = 还在扫描或扫描失败）
  LauncherAnalysis? _analysis;

  @override
  void initState() {
    super.initState();
    _localeEnabled = widget.initialLocaleMode == 'japanese';
    _upscalingEnabled = widget.initialUpscalingMode == 'magpie';
    _runAsAdmin = widget.initialRunAsAdmin;
    _scanForExecutables();
    _checkLocaleAvailability();
    _checkMagpieAvailability();
  }

  Future<void> _checkLocaleAvailability() async {
    final available = await LocaleService.isLocaleAvailable();
    if (mounted) setState(() => _localeAvailable = available);
  }

  Future<void> _checkMagpieAvailability() async {
    final available = await MagpieService.instance.isAvailable();
    if (mounted) setState(() => _magpieAvailable = available);
  }

  Future<void> _scanForExecutables() async {
    try {
      final dir = Directory(widget.gameDirectory);
      if (!await dir.exists()) return;
      // UX-26: 改用共享的 ExeScanner 有界扫描，避免大型游戏目录无界递归卡死
      final exeFiles =
          await ExeScanner.scanBounded(dir, maxDepth: 3, maxCount: 200);

      // ★ 2026-10-26 智能推荐：分类 + 版本标签 + 唯一推荐。
      //   放在 setState 之前算（同步 IO，几十毫秒量级），避免列表先空白再跳变。
      //   分析失败绝不能阻塞选择器——退回"没有角标"的原始列表即可。
      LauncherAnalysis? analysis;
      try {
        analysis = LauncherCandidateAnalyzer.analyzeSync(
          files: exeFiles,
          gameDirectory: widget.gameDirectory,
          gameTitle: widget.gameTitle,
          gameAliases: widget.gameSubtitles,
        );
      } catch (e) {
        debugPrint('[EXE-SELECTOR] 候选分析失败（不影响选择）: $e');
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
          _isLoading = false;
        });
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 520,
        height: 540,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.xl),
          border: Border.all(color: AppColors.border, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.border.withOpacity(0.15),
              offset: Offset(0, 4),
              blurRadius: 12,
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: _isLoading ? _buildLoading() : _buildContent(),
            ),
            _buildLocaleToggle(),
            Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            _buildUpscalingToggle(),
            Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            _buildRunAsAdminToggle(),
            Divider(height: 1, color: AppColors.border.withOpacity(0.3)),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(color: AppColors.border.withOpacity(0.2))),
      ),
      child: Row(
        children: [
          Icon(Icons.settings_applications_rounded,
              size: 20, color: AppColors.primaryText.withOpacity(0.7)),
          SizedBox(width: 10),
          Text('选择启动程序',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryText)),
          Spacer(),
          Text('${_filteredExes.length} 个程序',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.secondaryText)),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        style: TextStyle(fontSize: 13),
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
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final exes = _filteredExes;
    if (exes.isEmpty) return _buildEmpty();

    return Column(
      children: [
        _buildSearchBar(),
        if (_analysis?.recommended != null) _buildRecommendHint(),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            itemCount: exes.length,
            itemBuilder: (_, index) => _buildExeItem(exes[index]),
          ),
        ),
      ],
    );
  }

  /// 列表顶部的一行轻提示：说明「为什么多出来一个星标」
  ///
  /// 角标本身体积太小，只能写两个字；完整文案放在这里的常驻说明 + tooltip 里，
  /// 免得用户对着一个星形图标猜意思。
  Widget _buildRecommendHint() {
    final rec = _analysis!.recommended!;
    final label = rec.versionLabel;
    final text = label.isEmpty
        ? '已为你标出 1 个最可能是你需要的启动程序'
        : '已为你标出 1 个最可能是你需要的启动程序（$label）';
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Icon(Icons.auto_awesome_rounded,
              size: 13, color: AppColors.warningAmber),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: AppColors.secondaryText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExeItem(File file) {
    final isSelected = file.path == _selectedFile?.path;
    final fileName = file.path.split('\\').last;
    final relativePath =
        file.path.replaceFirst('${widget.gameDirectory}\\', '');

    // ★ 2026-10-26：分类与版本标签。分析结果缺失时全部退化为"什么都不标"，
    //   列表行为与改动前完全一致。
    final candidate = _analysis?.forPath(file.path);
    final isRecommended = _analysis?.isRecommended(file.path) ?? false;
    final versionLabel = candidate?.versionLabel ?? '';

    return InteractiveWrapper(
      onTap: () => setState(() => _selectedFile = file),
      child: Container(
        margin: EdgeInsets.symmetric(vertical: 2),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
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
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primaryText.withOpacity(0.1)
                    : AppColors.background,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.play_arrow_rounded,
                  size: 16,
                  color: isSelected
                      ? AppColors.primaryText
                      : AppColors.secondaryText),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // 🔴 必须 Flexible + ellipsis：角标是固定宽，文件名不让位
                      //    就会把这一行顶出容器（HALL-FIT-CARDS 的教训）
                      Flexible(
                        child: Text(fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.primaryText)),
                      ),
                      if (isRecommended) ...[
                        SizedBox(width: 6),
                        LauncherRecommendBadge(
                            tooltip: candidate?.recommendTooltip),
                      ] else if (candidate != null && candidate.isTool) ...[
                        SizedBox(width: 6),
                        LauncherToolBadge(
                            tooltip: '配套工具 / 运行库，不是启动游戏用的程序'),
                      ],
                    ],
                  ),
                  SizedBox(height: 2),
                  Text(
                    versionLabel.isEmpty
                        ? relativePath
                        : '$relativePath  ·  $versionLabel',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.secondaryText),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded,
                  size: 18, color: AppColors.primaryText.withOpacity(0.6)),
          ],
        ),
      ),
    );
  }

  Widget _buildLocaleToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Icon(Icons.language_rounded,
              size: 18,
              color: _localeEnabled
                  ? const Color(0xFFE91E63)
                  : AppColors.secondaryText),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('日语转区启动',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (!_localeAvailable && _localeEnabled)
                  Text('⚠ 未检测到转区引擎，请先安装 Locale Emulator',
                      style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFFE65100))),
              ],
            ),
          ),
          Switch.adaptive(
            value: _localeEnabled,
            activeColor: const Color(0xFFE91E63),
            onChanged: (value) {
              setState(() => _localeEnabled = value);
              widget.onLocaleModeChanged?.call(value ? 'japanese' : 'none');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUpscalingToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          Icon(Icons.auto_fix_high_rounded,
              size: 18,
              color: _upscalingEnabled
                  ? const Color(0xFF7C4DFF)
                  : AppColors.secondaryText),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('超分启动',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                if (!_magpieAvailable && _upscalingEnabled)
                  Text('⚠ 未检测到 Magpie，请在偏好设置中配置',
                      style: TextStyle(
                          fontSize: 12,
                          color: const Color(0xFFEF6C00))),
              ],
            ),
          ),
          Switch.adaptive(
            value: _upscalingEnabled,
            activeColor: const Color(0xFF7C4DFF),
            onChanged: (value) {
              setState(() => _upscalingEnabled = value);
              widget.onUpscalingModeChanged?.call(value ? 'magpie' : 'none');
            },
          ),
        ],
      ),
    );
  }

  /// ★ 2026-10-24：「以管理员身份运行」开关（与转区 / 超分并列）
  Widget _buildRunAsAdminToggle() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          Icon(Icons.admin_panel_settings_rounded,
              size: 18,
              color: _runAsAdmin
                  ? const Color(0xFFF59E0B)
                  : AppColors.secondaryText),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('以管理员身份运行',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText,
                    )),
                Text(
                    _runAsAdmin
                        ? '以管理员权限启动（可能触发 UAC 确认）'
                        : '适用于提示"权限不足"的游戏',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.secondaryText)),
              ],
            ),
          ),
          Switch.adaptive(
            value: _runAsAdmin,
            activeColor: const Color(0xFFF59E0B),
            onChanged: (value) {
              setState(() => _runAsAdmin = value);
              widget.onRunAsAdminChanged?.call(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_off_rounded,
              size: 48, color: AppColors.secondaryText.withOpacity(0.3)),
          SizedBox(height: 12),
          Text('未找到可执行文件',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondaryText)),
          SizedBox(height: 6),
          Text('请确认游戏目录是否正确',
              style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.secondaryText.withOpacity(0.7))),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return Center(child: CircularProgressIndicator(color: AppColors.border));
  }

  Widget _buildFooter() {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _buildButton('取消', () => Navigator.pop(context), isPrimary: false),
          SizedBox(width: 12),
          _buildButton('确定', _handleConfirm, isPrimary: true),
        ],
      ),
    );
  }

  Widget _buildButton(String label, VoidCallback onTap,
      {required bool isPrimary}) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 9),
        decoration: BoxDecoration(
          color: isPrimary
              ? AppColors.primaryText
              : AppColors.primaryText.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isPrimary ? Colors.white : AppColors.primaryText)),
      ),
    );
  }

  void _handleConfirm() async {
    if (_selectedFile != null) {
      widget.onSelected(_selectedFile!.path);
    }
    Navigator.of(context).pop();
  }
}
