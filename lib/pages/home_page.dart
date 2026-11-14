import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../widgets/interactive_wrapper.dart';
import '../theme/app_styles.dart';
import '../services/local_game_registry.dart';
import '../services/game_data_format.dart';
import '../services/game_title_logo_service.dart';
import '../widgets/game_detail_dialog.dart';
import '../widgets/game_title_logo.dart';
import '../widgets/play_stats_panel.dart';
import '../widgets/nsfw/nsfw_image.dart';

class HomePage extends StatefulWidget {
  final ValueChanged<String>? onLaunchGame;
  final VoidCallback? onGoToLibrary;
  final ValueChanged<String>? onToggleMark;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onToggleBigPicture;

  const HomePage({
    super.key,
    this.onLaunchGame,
    this.onGoToLibrary,
    this.onToggleMark,
    this.onDelete,
    this.onToggleBigPicture,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<LibraryGame> _allGames = [];
  List<LibraryGame> _recentGames = [];
  int _selectedIndex = 0;
  PlayStatus? _activeFilter;
  final Map<String, String> _localeModes = {};
  final Map<String, String> _upscalingModes = {};
  // UX-18: 磁盘扫描期间显示加载指示器，避免空白
  bool _isScanning = false;

  // 封面路径缓存，避免每次 build 同步 I/O
  final Map<String, String?> _coverPathCache = {};

  // ★ 2026-10-04 横幅封面路径缓存（与封面缓存同套路；null = 已探测、无横幅）
  final Map<String, String?> _bannerPathCache = {};

  // 平滑滚动控制器
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _refreshFromDisk();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    super.dispose();
  }

  void _onRegistryChanged() {
    // UX-34: 区分通知类型——结构性变化需重新加载,游玩时长变化仅刷新
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      _coverPathCache.clear();
      _bannerPathCache.clear();
      if (mounted) _loadGames();
    } else {
      // playTimeUpdate:游戏对象引用已被原地修改,仅 setState 让 UI 反映新值
      // 避免每 30s 清空封面缓存并触发同步 I/O 扫描磁盘
      if (mounted) setState(() {});
    }
  }

  /// 从磁盘重新扫描并加载数据，确保注册表是最新的
  Future<void> _refreshFromDisk() async {
    // UX-18: 首次扫描（库为空）时显示加载指示器，避免空白等待
    final wasEmpty = _allGames.isEmpty;
    if (wasEmpty) setState(() => _isScanning = true);
    try {
      await LocalGameRegistry.instance.scan();
      _loadGames();
    } finally {
      if (wasEmpty && mounted) setState(() => _isScanning = false);
    }
  }

  void _loadGames() {
    final games = LocalGameRegistry.instance.allGames;
    final recentGames = List<LibraryGame>.from(games);
    recentGames.sort((a, b) {
      final aHas = a.lastOpenedAt.isNotEmpty;
      final bHas = b.lastOpenedAt.isNotEmpty;
      if (aHas && bHas) return b.lastOpenedAt.compareTo(a.lastOpenedAt);
      if (aHas) return -1;
      if (bHas) return 1;
      return b.installedAt.compareTo(a.installedAt);
    });

    setState(() {
      _allGames = games;
      _recentGames = recentGames;
      // UX-14: 选中索引基于筛选列表，加载后重新校验
      _ensureSelectionInFilter();
    });
    _resolveCoverPaths();
    _loadLaunchModes();
  }

  /// UX-34: 异步一次性解析所有封面路径，缓存结果，避免阻塞主线程
  Future<void> _resolveCoverPaths() async {
    for (final game in _allGames) {
      if (_coverPathCache.containsKey(game.title)) continue;
      String? resolved;
      if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
        resolved = game.coverUrl;
      } else {
        try {
          resolved = GameDataFormat.findCoverFile(game.pathForCover)?.path;
        } catch (_) {}
      }
      _coverPathCache[game.title] = resolved;

      // ★ 2026-10-04 横幅封面：与封面同套路解析并缓存（无横幅 = null）
      if (_bannerPathCache.containsKey(game.title)) continue;
      String? bannerResolved;
      if (game.bannerUrl.isNotEmpty && File(game.bannerUrl).existsSync()) {
        bannerResolved = game.bannerUrl;
      } else {
        try {
          bannerResolved =
              GameDataFormat.findBannerFile(game.pathForCover)?.path;
        } catch (_) {}
      }
      _bannerPathCache[game.title] = bannerResolved;
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadLaunchModes() async {
    for (final game in _allGames) {
      try {
        final data = await GameDataFormat.readGameJson(game.metaDataDir);
        if (data != null) {
          if (data.localeMode.isNotEmpty) {
            _localeModes[game.title] = data.localeMode;
          }
          if (data.upscalingMode.isNotEmpty) {
            _upscalingModes[game.title] = data.upscalingMode;
          }
        }
      } catch (_) {}
    }
    // UX-23: 异步加载完成后触发 UI 重建，使 locale/upscaling 模式即时显示
    if (mounted) setState(() {});
  }

  List<LibraryGame> get _filteredGames {
    var result = List<LibraryGame>.from(_recentGames);
    if (_activeFilter != null) {
      result = result.where((g) => g.playStatus == _activeFilter).toList();
    }
    return result;
  }

  // UX-14: 选中索引基于筛选后的列表，确保选中游戏始终在可见列表中
  LibraryGame? get _selectedGame {
    final filtered = _filteredGames;
    return filtered.isNotEmpty && _selectedIndex < filtered.length
        ? filtered[_selectedIndex]
        : null;
  }

  int get _totalPlayTime => _allGames.fold(0, (sum, g) => sum + g.playTime);

  void _selectGame(int index) {
    final filtered = _filteredGames;
    if (index < 0 || index >= filtered.length) return;
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  void _selectGameFromList(LibraryGame game) {
    final idx = _filteredGames.indexOf(game);
    if (idx >= 0 && idx != _selectedIndex) {
      _selectGame(idx);
    }
    // 紧凑布局：选中即回到详情（窄窗下列表是独占全宽的视图）
    if (_compactListOpen) {
      setState(() => _compactListOpen = false);
    }
  }

  void _navigateLeft() {
    if (_selectedIndex > 0) {
      _selectGame(_selectedIndex - 1);
    }
  }

  void _navigateRight() {
    if (_selectedIndex < _filteredGames.length - 1) {
      _selectGame(_selectedIndex + 1);
    }
  }

  /// UX-14: 切换筛选条件后，确保选中索引在筛选列表有效范围内
  void _ensureSelectionInFilter() {
    final filtered = _filteredGames;
    if (_selectedIndex >= filtered.length) {
      _selectedIndex = filtered.isNotEmpty ? 0 : 0;
    }
  }

  void _handleLaunch() {
    final game = _selectedGame;
    if (game == null) return;
    // ★ H11: UI 层双重启动保护
    // 注意：onLaunchGame 是 void 回调（非 Future），无法 await，
    // 真正的并发保护由 GameLaunchService._isLaunching 兜底。
    // 这里通过 MainContainer._onLaunchGame 内部的 scan + resolveUserChoice
    // 异步链路实现启动，重复点击会被 GameLaunchService 拦截并返回失败 SnackBar。
    // 为避免误导，不在此处设置无效的 UI 标志（会因同步返回而立即释放）。
    widget.onLaunchGame?.call(game.title);
  }

  void _handleDetails() {
    final game = _selectedGame;
    if (game == null) return;
    GameDetailDialog.show(
      context: context,
      directoryPath: game.pathForCover,
      onLaunchGame: _handleLaunch,
      initialLocaleMode: _localeModes[game.title] ?? 'none',
      initialUpscalingMode: _upscalingModes[game.title] ?? 'none',
      onLocaleModeChanged: (mode) {
        _localeModes[game.title] = mode;
      },
      onUpscalingModeChanged: (mode) {
        _upscalingModes[game.title] = mode;
      },
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.pageBackground,
      // UX-18: 扫描期间显示加载状态，避免空白
      child: _isScanning && _allGames.isEmpty
          ? _buildLoadingState()
          : _allGames.isEmpty
              ? _buildEmptyState()
              // RESPONSIVE-LIST：内容区放不下「详情 830 画布 + 320 列表」时，
              // 列表改走右侧常驻竖条（点开独占全宽），避免详情被等比压到
              // 0.5 倍（正文变 7px）。
              : LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    if (_useCompactLayout(constraints)) {
                      return _buildCompactBody();
                    }
                    return _buildWideBody();
                  },
                ),
    );
  }

  // ============ RESPONSIVE-LIST：详情 / 游戏库列表的自适应分栏 ============

  /// 右侧游戏库在宽版布局里的内联宽度
  static const double _kListPanelWidth = 320;

  /// 内联分栏可接受的最小详情缩放比。
  ///
  /// 0.82 对应正文 14px → 11.5px，是"仍能正常阅读"的下限；
  /// 低于它说明 320px 列表把详情挤得太窄，应改为竖条让位。
  static const double _kListInlineMinScale = 0.82;

  /// 紧凑布局下游戏库列表（独占全宽视图）是否打开
  bool _compactListOpen = false;

  /// 当前内容区能否容下「详情设计画布 + 320 内联列表」
  ///
  /// 判定口径必须与 `_buildDetailContent` 的等比缩放完全一致：
  /// 详情面板左右 padding 20+12=32、上下 16+16=32，画布 830×640。
  /// 两处口径不一致就会出现"以为放得下、实际被缩到一半"的错位。
  static bool _useCompactLayout(BoxConstraints c) {
    if (!c.maxWidth.isFinite || !c.maxHeight.isFinite) return false;
    final double detailWidth = c.maxWidth - _kListPanelWidth - 32;
    final double detailHeight = c.maxHeight - 32;
    if (detailWidth <= 0 || detailHeight <= 0) return true;
    final double scale = math.min(
      detailWidth / _kDetailDesignWidth,
      detailHeight / _kDetailDesignHeight,
    );
    return scale < _kListInlineMinScale;
  }

  /// 宽版布局：详情 + 并排的 320 列表（原布局，零改动）
  Widget _buildWideBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: _buildDetailPanel(),
        ),
        SizedBox(
          width: _kListPanelWidth,
          child: _buildGameListPanel(),
        ),
      ],
    );
  }

  /// 紧凑布局：详情独占 + 右侧常驻的「游戏库」竖条
  ///
  /// 不做浮层抽屉：详情面板左右边缘被切换箭头占据、右下角是统计面板，
  /// 任何浮层按钮都会压到内容。改为一根常驻竖条（与库页分类匣同思路），
  /// 点开后列表独占全宽——窄窗下一屏反而能看到的游戏更多。
  ///
  /// 960×600 下详情可用宽从 426 升到 734，缩放比 0.51 → 0.84（正文 11.7px）。
  Widget _buildCompactBody() {
    if (_compactListOpen) {
      return _buildGameListPanel(
        standalone: true,
        onClose: () => setState(() => _compactListOpen = false),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildDetailPanel()),
        _buildListRail(),
      ],
    );
  }

  /// 紧凑布局下常驻的游戏库入口竖条
  Widget _buildListRail() {
    final bool isDark = AppColors.isDark;
    return Tooltip(
      message: '打开游戏库列表',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _compactListOpen = true),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34,
            margin: const EdgeInsets.fromLTRB(4, 16, 6, 16),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.sidebarBackground.withOpacity(0.92)
                  : AppColors.background.withOpacity(0.85),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border, width: 1.5),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.videogame_asset_rounded,
                  size: 15,
                  color: AppColors.primaryText,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_filteredGames.length}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: AppColors.secondaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '库',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 空状态 ====================
  Widget _buildLoadingState() {
    // UX-18: 磁盘扫描期间显示加载指示器
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.secondaryText.withOpacity(0.6),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '正在扫描游戏库...',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videogame_asset_rounded,
            size: 64,
            color: AppColors.border.withOpacity(0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '库中没有游戏哦',
            style: TextStyle(
              fontSize: 20,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '快去添加或探索游戏吧！',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.secondaryText.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 左侧详情面板 ====================
  Widget _buildDetailPanel() {
    final game = _selectedGame;
    if (game == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Stack(
        children: [
          // #6: 切换动画 - 用 AnimatedSwitcher 包裹背景+内容
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: child,
              );
            },
            child: _buildDetailContent(game),
          ),
          // 左右切换按钮（不参与动画，始终在最上层）
          // UX-14: 切换按钮可见性基于筛选列表
          if (_filteredGames.length > 1) ...[
            if (_selectedIndex > 0)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _buildNavArrow(isLeft: true),
              ),
            if (_selectedIndex < _filteredGames.length - 1)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: _buildNavArrow(isLeft: false),
              ),
          ],
        ],
      ),
    );
  }

  /// UX-41: 详情区设计画布尺寸——可用空间小于该尺寸时整体等比缩小
  /// （830 = 封面180 + 间距16 + 按钮组~290 + 间隙 + 统计表320 + 边距，恰好无重叠）
  static const double _kDetailDesignWidth = 830;
  static const double _kDetailDesignHeight = 640;

  /// 构建左侧详情内容（背景 + 主内容），带 key 供 AnimatedSwitcher 识别切换
  ///
  /// UX-41: 自适应等比缩放（8.21 原始布局结构 + 宽高同步自适应）：
  ///   - 宽高均 ≥ 设计最小值(830×640)：按老版本原始布局渲染，外观完全一致
  ///   - 任一侧不足：按更紧张一侧的比率整体等比缩小，画布尺寸随可用空间
  ///     反推（可用尺寸/scale，恒 ≥ 830×640）——封面、按钮、统计表、文字
  ///     同比例收缩；缩放后内容恰好铺满面板，宽度收缩时高度同步自适应，
  ///     标题贴顶、底部组件贴底，结构与原始布局一致，不居中悬浮、不留空档。
  ///     FittedBox 自带命中测试逆变换，缩小后交互功能不受影响。
  ///   - 毛玻璃背景不参与缩放，始终铺满整个面板。
  Widget _buildDetailContent(LibraryGame game) {
    // 前景内容：老版本原始结构（两种渲染分支共用）
    final foregroundChildren = <Widget>[
      // 主内容
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标签行
          _buildTagRow(game),
          const SizedBox(height: 12),
          // 游戏标题
          _buildGameTitle(game),
          // #4: 开发商信息
          if (game.developer.isNotEmpty) ...[
            const SizedBox(height: 4),
            _buildDeveloper(game),
          ],
          const SizedBox(height: 8),
          // 游戏简介
          _buildGameDescription(game),
          const Spacer(),
          // 底部区域：封面 + 信息 + 按钮
          _buildBottomSection(game),
          // 底部呼吸位（2026-11-03 移除页面指示器圆点，仅保留少量留白）
          const SizedBox(height: 10),
        ],
      ),
      // 游玩状态标签 - 右上角轻量化显示
      Positioned(
        top: 4,
        right: 4,
        child: _buildPlayStatusBadge(game),
      ),
      // 游玩统计面板 - 右下角，与启动按钮保持间距
      Positioned(
        right: 4,
        bottom: 8,
        child: PlayStatsPanel(currentGame: game),
      ),
    ];

    return Stack(
      key: ValueKey(game.title),
      children: [
        // #7: 模糊背景 - 改用 BackdropFilter 毛玻璃效果（不参与缩放，铺满面板）
        Positioned.fill(
          child: _buildBlurredBackground(game),
        ),
        // 前景内容：按可用尺寸选择 原始布局 / 整体等比缩小
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final availableW = constraints.maxWidth;
              final availableH = constraints.maxHeight;
              // 约束异常（无限尺寸）时按原始布局兜底
              if (!availableW.isFinite || !availableH.isFinite) {
                return Stack(children: foregroundChildren);
              }
              // 等比缩放系数：宽/高两侧比率中更紧张的一侧
              final widthRatio = availableW / _kDetailDesignWidth;
              final heightRatio = availableH / _kDetailDesignHeight;
              final scale = widthRatio < heightRatio ? widthRatio : heightRatio;
              if (scale >= 1) {
                // 空间充足：老版本原始布局，内容自然铺满面板
                return Stack(children: foregroundChildren);
              }
              // 空间不足：整体等比缩小，画布尺寸 = 可用尺寸 / scale
              // → 缩放后内容恰好铺满整个面板，宽高同步自适应：
              //   宽度收缩时高度同步跟随（画布高度随可用高度反推），
              //   标题仍贴顶、封面/按钮/统计表仍贴底贴右，Spacer 正常
              //   撑开，结构与原始布局完全一致，不居中悬浮、不留空档。
              // 画布内尺寸恒 ≥ 设计最小值(830×640)，保证组件间不重叠。
              return FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: availableW / scale,
                  height: availableH / scale,
                  child: Stack(children: foregroundChildren),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // #7: BackdropFilter 毛玻璃背景
  Widget _buildBlurredBackground(LibraryGame game) {
    final isDark = AppColors.isDark;
    // ★ 2026-10-04 横幅优先：横版大图铺横向面板只需轻微适配，
    //   竖封面在此处是破坏性放大裁切（无横幅时回退竖封面，行为不变）
    final Widget baseImage = _hasBanner(game)
        ? _buildBannerImage(game, fit: BoxFit.cover, showBadge: false)
        : _buildCoverImage(game, fit: BoxFit.cover, showBadge: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 放大的封面图（最底层）
          baseImage,
          // BackdropFilter: 模糊下层的封面图，并叠加半透明背景色
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
            child: Container(
              color: AppColors.background.withOpacity(isDark ? 0.55 : 0.18),
            ),
          ),
          // 底部渐变，增强深度感
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppColors.background.withOpacity(isDark ? 0.35 : 0.25),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// UX-34: 使用缓存的封面路径构建图片，路径已在加载时验证，不再 build 中做同步 I/O
  Widget _buildCoverImage(
    LibraryGame game, {
    BoxFit fit = BoxFit.cover,
    bool manuallyBlurred = false,
    bool showBadge = true,
  }) {
    final cachedPath = _coverPathCache[game.title];
    if (cachedPath != null && cachedPath.isNotEmpty) {
      return NsfwImage.file(
        cachedPath,
        contentKind: NsfwContentKind.cover,
        fit: fit,
        // v2.5：揭示入口为角标按钮，不与卡片自身点击冲突；v2.7 移到左上角
        enableReveal: true,
        // v2.7：用户手动「模糊」下沉进 NsfwImage，与 NSFW 打码同一路径
        // （装饰性背景调用处保持默认 false）
        manuallyBlurred: manuallyBlurred,
        // v2.7.1：装饰性毛玻璃背景传 false（被 BackdropFilter 糊掉 + 遮罩压住，
        // 显示徽标只会是看不见也点不到的死角标）。
        showBadge: showBadge,
        // 与 child 的 cacheWidth/cacheHeight 一致，避免同一张图二次解码
        decodeWidth: 480,
        decodeHeight: 720,
        child: Image.file(
          File(cachedPath),
          width: double.infinity,
          height: double.infinity,
          fit: fit,
          // ★ 性能优化：卡片封面限宽解码（与 library_page 卡片 480/720 规格一致）
          cacheWidth: 480,
          cacheHeight: 720,
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        ),
      );
    }
    return _buildPlaceholderCover();
  }

  /// ★ 2026-10-04 横幅封面：使用缓存的横幅路径构建图片（结构与封面同构）。
  ///
  /// 横幅是横向大图，解码限宽 960（比竖封面 480 宽一档，横向像素更多）；
  /// 不传 decodeHeight（横图高度不定，按宽高比自然解码）。
  Widget _buildBannerImage(
    LibraryGame game, {
    BoxFit fit = BoxFit.cover,
    bool showBadge = true,
  }) {
    final cachedPath = _bannerPathCache[game.title];
    if (cachedPath != null && cachedPath.isNotEmpty) {
      return NsfwImage.file(
        cachedPath,
        contentKind: NsfwContentKind.cover,
        fit: fit,
        enableReveal: true,
        // v2.7.1：装饰性毛玻璃背景传 false，理由同 _buildCoverImage。
        showBadge: showBadge,
        decodeWidth: 960,
        child: Image.file(
          File(cachedPath),
          width: double.infinity,
          height: double.infinity,
          fit: fit,
          cacheWidth: 960,
          errorBuilder: (_, __, ___) => _buildPlaceholderCover(),
        ),
      );
    }
    return _buildPlaceholderCover();
  }

  /// 横幅是否存在（缓存已探测且非空）
  bool _hasBanner(LibraryGame game) {
    final p = _bannerPathCache[game.title];
    return p != null && p.isNotEmpty;
  }

  Widget _buildPlaceholderCover() {
    return Container(
      color: AppColors.placeholderCover,
      child: Center(
        child: Icon(
          Icons.videogame_asset_rounded,
          size: 48,
          color: AppColors.border.withOpacity(0.3),
        ),
      ),
    );
  }

  Widget _buildTagRow(LibraryGame game) {
    if (game.tags.isEmpty) return const SizedBox.shrink();
    final isDark = AppColors.isDark;
    // 限制标签数量，最多显示 5 个
    final displayTags =
        game.tags.length > 5 ? game.tags.sublist(0, 5) : game.tags;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: displayTags.map((tag) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(
              color: isDark ? AppColors.border : AppColors.borderLight,
            ),
            color: isDark
                ? AppColors.buttonBackground.withOpacity(0.9)
                : AppColors.background.withOpacity(0.85),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            tag,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: isDark ? AppColors.primaryText : AppColors.border,
              height: 15 / 10,
            ),
          ),
        );
      }).toList(),
    );
  }

  /// 右上角游玩状态轻量化标签
  Widget _buildPlayStatusBadge(LibraryGame game) {
    final isDark = AppColors.isDark;
    final status = game.playStatus;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: (isDark ? AppColors.buttonBackground : AppColors.background)
            .withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: status.color.withOpacity(0.5),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 12, color: status.color),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: status.color,
              letterSpacing: 0.5,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  /// 游戏大标题：有标题图（透明 logo）贴图，否则 38px 得意黑文字。
  ///
  /// 与 BPM 主页同一套语义（`GameTitleLogo`），差别只有尺寸与底色：
  /// 桌面主页跟随主题，浅色主题下白 logo 靠 widget 内的深色剪影保证可读。
  Widget _buildGameTitle(LibraryGame game) {
    final fallback = Text(
      game.title.isNotEmpty ? game.title : '未命名游戏',
      style: TextStyle(
        fontFamily: AppStyles.zhFontFamily,
        fontSize: 38,
        fontWeight: FontWeight.w400,
        height: 38 / 38,
        letterSpacing: 2,
        color: AppColors.primaryText,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    // 无标题图 → 后台补抓一次（脱 build 相；服务内部有去重与负缓存）
    if (game.logoPath.isEmpty && game.gameId.isNotEmpty) {
      Timer.run(() {
        GameTitleLogoService.instance.requestAutoFetch(
          gameId: game.gameId,
          metaDataDir: game.metaDataDir,
          title: game.title,
          subtitle: game.subtitle,
          metadataSource: game.metadataSource,
          metadataSourceId: game.metadataSourceId,
        );
      });
    }

    return GameTitleLogo(
      logoPath: game.logoPath,
      // 设计画布 830 宽，标题可用宽度留够给右侧统计面板
      maxWidth: 480,
      // 原文字行高 38 → logo 取 64（略高于行高）：横扁素材按高度归一，
      // 60 时带副标题的 logo 副行会糊成一团
      maxHeight: 64,
      onLightSurface: !AppColors.isDark,
      fallback: fallback,
    );
  }

  // #4: 开发商信息
  Widget _buildDeveloper(LibraryGame game) {
    return Text(
      game.developer,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: Colors.teal.withOpacity(0.8),
        height: 16 / 11,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildGameDescription(LibraryGame game) {
    if (game.description.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 39,
      child: Text(
        game.description,
        style: TextStyle(
        fontFamily: AppStyles.uiFontFamily,
        fontSize: 12,
        height: 20 / 12,
        letterSpacing: 0,
        color: AppColors.secondaryText,
      ),
      maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildBottomSection(LibraryGame game) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // #8: 封面卡片放大 - 从 161 放大到 180
            _buildCoverCard(game),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatChips(game),
                  const SizedBox(height: 16),
                  _buildActionButtons(game),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // #8: 封面卡片放大并优化比例
  ///
  /// ★ 2026-10-09 横幅适配回退：封面卡**始终**使用竖版封面（180 × 240，3:4）。
  ///   横幅只服务于左侧面板的背景层（_buildBlurredBackground 横幅优先），
  ///   卡片不再随横幅切换为横版——对齐 BPM「背景用横幅 / 卡片用竖封面」，
  ///   主页整体设计保持不变。
  Widget _buildCoverCard(LibraryGame game) {
    return Container(
      width: 180,
      height: 180 * 4 / 3, // 竖封面 3:4（240px）
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        borderRadius:
            BorderRadius.circular(AppStyle.isModern ? AppStyle.rLg : 10),
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 2),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
                BoxShadow(
                  color: AppColors.border.withOpacity(0.15),
                  offset: const Offset(2, 3),
                  blurRadius: 6,
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // v2.7：手动模糊下沉进 NsfwImage，此处不再在外层套 ImageFiltered。
        child: _buildCoverImage(game, manuallyBlurred: game.isBlurred),
      ),
    );
  }

  Widget _buildStatChips(LibraryGame game) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildStatChip(
          icon: Icons.schedule_outlined,
          value: _formatPlayTime(game.playTime),
          label: '游玩时长',
        ),
        _buildStatChip(
          icon: Icons.access_time,
          value: _formatLastPlayed(game.lastOpenedAt),
          label: '上次游玩',
        ),
      ],
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String value,
    required String label,
  }) {
    final isDark = AppColors.isDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 2),
        borderRadius:
            BorderRadius.circular(AppStyle.isModern ? AppStyle.rSm : 4),
        color: isDark
            ? AppColors.buttonBackground.withOpacity(0.95)
            : AppColors.background.withOpacity(0.9),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
                BoxShadow(
                  color: AppColors.border.withOpacity(0.15),
                  offset: const Offset(2, 2),
                ),
              ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 13,
                  color: isDark ? AppColors.primaryText : AppColors.border),
              const SizedBox(width: 6),
              Text(
                value,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.38,
                  color: AppColors.primaryText,
                  height: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
              color: isDark
                  ? AppColors.secondaryText
                  : AppColors.border.withOpacity(0.7),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(LibraryGame game) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // v3.9 按钮体系：primary 语义变体（原硬编码暖阳时代浅蓝三色，
        // 在浅/深主题下不融洽）；文字/图标色经 DefaultTextStyle/IconTheme 继承
        HoverButton(
          variant: CtButtonVariant.primary,
          size: CtButtonSize.md,
          onTap: _handleLaunch,
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_arrow, size: 14,
                  color: AppStyle.primaryButtonInk),
              const SizedBox(width: 10),
              Text(
                '立即启动',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: AppStyle.primaryButtonInk,
                  height: 24 / 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // v3.9 按钮体系：secondary 语义变体（原 border 描边 + titleBrown 系）
        HoverButton(
          variant: CtButtonVariant.secondary,
          size: CtButtonSize.md,
          onTap: _handleDetails,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '详情',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: AppColors.primaryText,
                  height: 24 / 16,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 16, color: AppColors.primaryText),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNavArrow({required bool isLeft}) {
    final isDark = AppColors.isDark;
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: isLeft ? _navigateLeft : _navigateRight,
          child: Container(
            width: 36,
            height: 60,
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(isDark ? 0.75 : 0.6),
              borderRadius: BorderRadius.horizontal(
                left: isLeft ? Radius.zero : const Radius.circular(8),
                right: isLeft ? const Radius.circular(8) : Radius.zero,
              ),
              border: Border.all(
                color: AppColors.border.withOpacity(isDark ? 0.6 : 0.3),
                width: 1,
              ),
            ),
            child: Icon(
              isLeft ? Icons.chevron_left : Icons.chevron_right,
              size: 24,
              color: AppColors.primaryText.withOpacity(0.7),
            ),
          ),
        ),
      ),
    );
  }

  // ==================== 右侧游戏列表面板 ====================
  Widget _buildGameListPanel({bool standalone = false, VoidCallback? onClose}) {
    final isDark = AppColors.isDark;
    return Container(
      // 宽版沿用原外边距；紧凑独占全宽时四周留 8 的呼吸位
      margin: standalone
          ? const EdgeInsets.all(8)
          : const EdgeInsets.fromLTRB(0, 16, 20, 16),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 2),
        borderRadius: BorderRadius.circular(12),
        color: isDark
            ? AppColors.sidebarBackground.withOpacity(0.92)
            : AppColors.background.withOpacity(0.85),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.15),
            offset: const Offset(4, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildListHeader(onClose: onClose),
          Expanded(
            child: _buildGameListView(),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader({VoidCallback? onClose}) {
    final isDark = AppColors.isDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.videogame_asset_rounded,
                  size: 16,
                  color: isDark ? AppColors.primaryText : AppColors.border),
              const SizedBox(width: 6),
              Text(
                '游戏库',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: isDark ? AppColors.border : AppColors.borderLight),
                  color: isDark
                      ? AppColors.buttonBackground
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '${_allGames.length} 款',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.primaryText : AppColors.border,
                    height: 15 / 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: isDark ? AppColors.border : AppColors.borderLight),
                  color: isDark
                      ? AppColors.buttonBackground
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  _formatPlayTime(_totalPlayTime),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.primaryText : AppColors.border,
                    height: 15 / 10,
                  ),
                ),
              ),
              const Spacer(),
              // 大屏模式入口按钮
              if (widget.onToggleBigPicture != null)
                _buildBigPictureButton(isDark),
              // 紧凑独占形态的收起按钮（宽版布局不传 onClose，不渲染）
              if (onClose != null) ...[
                const SizedBox(width: 6),
                _buildListCloseButton(onClose),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _buildFilterChips(),
        ],
      ),
    );
  }

  /// 紧凑独占形态下收起游戏库列表的小按钮
  Widget _buildListCloseButton(VoidCallback onClose) {
    return Tooltip(
      message: '收起列表',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onClose,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 13,
              color: AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }

  /// 大屏模式 (BPM) 入口按钮 - 纯图标小按钮 (v1.2)
  ///
  /// 放在列表头部 Spacer 之后的空白处,纯图标无文字,
  /// 与 header 其他小徽章视觉重量一致,最小化对原 UI 的影响。
  Widget _buildBigPictureButton(bool isDark) {
    return Tooltip(
      message: '大屏模式 (F11)',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => widget.onToggleBigPicture?.call(),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                color: isDark ? AppColors.border : AppColors.borderLight,
              ),
              color: isDark ? AppColors.buttonBackground : AppColors.background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.fullscreen_rounded,
              size: 14,
              color: isDark ? AppColors.primaryText : AppColors.border,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final filters = [
      (null, '全部'),
      (PlayStatus.inProgress, '游玩中'),
      (PlayStatus.completed, '已通关'),
      (PlayStatus.notStarted, '未入坑'),
      (PlayStatus.dropped, '已弃坑'),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((item) {
          final (status, label) = item;
          final isActive = _activeFilter == status;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _HoverChip(
              label: label,
              isActive: isActive,
              onTap: () {
                setState(() {
                  _activeFilter = isActive ? null : status;
                  // UX-14: 切换筛选时确保选中游戏在新筛选列表内
                  _ensureSelectionInFilter();
                });
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildGameListView() {
    final filtered = _filteredGames;
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没有符合条件的游戏',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.secondaryText,
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      cacheExtent: 2000, // 性能优化: 增大预渲染区域，减少快速滑动时的白屏
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final game = filtered[index];
        final isSelected = _selectedGame == game;
        // UX-34: RepaintBoundary 隔离每行的重绘
        return RepaintBoundary(
          child: _HomeGameRow(
            key: ValueKey(game.title),
            game: game,
            isSelected: isSelected,
            coverPath: _coverPathCache[game.title],
            onTap: () => _selectGameFromList(game),
            onDoubleTap: () => widget.onLaunchGame?.call(game.title),
          ),
        );
      },
    );
  }

  // ==================== 工具方法 ====================
  static String _formatPlayTime(int seconds) {
    if (seconds <= 0) return '0m';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h';
    return '${minutes}m';
  }

  static String _formatLastPlayed(String lastOpenedAt) {
    if (lastOpenedAt.isEmpty) return '从未游玩';
    try {
      final dt = DateTime.parse(lastOpenedAt);
      final diff = DateTime.now().difference(dt);
      // UX-22: 修复判断顺序——先检查分钟/小时粒度，再检查天，
      // 否则 inDays==0 会先命中，导致当天内的"刚刚"/"X分钟前"永远不显示。
      if (diff.inMinutes < 1) return '刚刚';
      if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
      if (diff.inDays == 0) return '今天';
      if (diff.inDays == 1) return '昨天';
      if (diff.inDays < 7) return '${diff.inDays}天前';
      if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}周前';
      if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
      return '${(diff.inDays / 365).floor()}年前';
    } catch (_) {
      return '从未游玩';
    }
  }
}

// ==================== 右侧游戏行组件 ====================
class _HomeGameRow extends StatelessWidget {
  final LibraryGame game;
  final bool isSelected;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _HomeGameRow({
    super.key,
    required this.game,
    required this.isSelected,
    this.coverPath,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    return _HomeGameRowInner(
      game: game,
      isSelected: isSelected,
      coverPath: coverPath,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
    );
  }
}

/// 内部实现，管理 hover 状态
class _HomeGameRowInner extends StatefulWidget {
  final LibraryGame game;
  final bool isSelected;
  final String? coverPath;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  const _HomeGameRowInner({
    required this.game,
    required this.isSelected,
    this.coverPath,
    required this.onTap,
    this.onDoubleTap,
  });

  @override
  State<_HomeGameRowInner> createState() => _HomeGameRowInnerState();
}

class _HomeGameRowInnerState extends State<_HomeGameRowInner> {
  bool _hovered = false;

  // #11: 选中状态变化时自动滚动到可见位置
  @override
  void didUpdateWidget(_HomeGameRowInner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当从"未选中"变为"选中"时，滚动到可见位置
    if (widget.isSelected && !oldWidget.isSelected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5, // 尽量居中显示
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final Color bgColor;
    if (isSelected) {
      bgColor = AppColors.selectedAccent.withOpacity(0.12);
    } else if (_hovered) {
      bgColor = AppColors.cardHoverBg;
    } else {
      bgColor = Colors.transparent;
    }

    // 边框始终存在，避免 null ↔ Border.all 切换导致的闪烁
    final Color borderColor;
    final double borderWidth;
    if (isSelected) {
      borderColor = AppColors.selectedAccent;
      borderWidth = 1.5;
    } else if (_hovered) {
      borderColor = AppColors.borderLight;
      borderWidth = 1;
    } else {
      // 未选中且未 hover 时，使用透明边框占位（保持布局不变）
      borderColor = Colors.transparent;
      borderWidth = 1;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Row(
            children: [
              // 缩略图 - 固定尺寸，不做动画避免布局抖动
              Container(
                width: 40,
                height: 55,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.borderLight, width: 1),
                  color: AppColors.placeholderCover,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: _buildCoverThumb(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _buildStatusDot(widget.game.playStatus),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.game.title.isNotEmpty
                                ? widget.game.title
                                : '未命名游戏',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primaryText,
                              height: 1.3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          widget.game.playStatus.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.game.playStatus.color,
                            height: 1.2,
                          ),
                        ),
                        if (widget.game.playTime > 0) ...[
                          Text(
                            ' · ',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.secondaryText.withOpacity(0.5),
                            ),
                          ),
                          Icon(Icons.schedule,
                              size: 11,
                              color: AppColors.secondaryText.withOpacity(0.6)),
                          const SizedBox(width: 3),
                          Text(
                            _formatPlayTimeShort(widget.game.playTime),
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.secondaryText,
                              height: 1.2,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                _formatRelativeTime(widget.game.lastOpenedAt),
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// UX-34: 使用缓存路径，路径已在加载时验证，不再每次 build 做同步 I/O
  /// 性能优化: 添加 cacheWidth/cacheHeight 避免全分辨率解码
  Widget _buildCoverThumb() {
    final path = widget.coverPath;
    if (path != null && path.isNotEmpty) {
      return NsfwImage.file(
        path,
        contentKind: NsfwContentKind.cover,
        width: double.infinity,
        height: double.infinity,
        // v2.7：40×55 小缩略图不显示角标（会盖住整张图）；且此处宽高传的是
        // double.infinity，若不显式关闭，槽位判定会把无限大误判为大槽位而
        // 强行显示角标（原本依赖 enableReveal 默认 false 间接规避）。
        showBadge: false,
        child: Image.file(
          File(path),
          width: double.infinity,
          height: double.infinity,
          fit: BoxFit.cover,
          cacheWidth: 100, // 缩略图物理像素: ~50px × 2x DPR
          cacheHeight: 140,
          errorBuilder: (_, __, ___) => _buildPlaceholderThumb(),
        ),
      );
    }
    return _buildPlaceholderThumb();
  }

  Widget _buildPlaceholderThumb() {
    return Container(
      color: AppColors.placeholderCover,
      child: Icon(
        Icons.videogame_asset_rounded,
        size: 16,
        color: AppColors.border.withOpacity(0.3),
      ),
    );
  }

  Widget _buildStatusDot(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.secondaryText.withOpacity(0.5),
              width: 1.5,
            ),
          ),
        );
      case PlayStatus.inProgress:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Colors.green.withOpacity(0.4), blurRadius: 3),
            ],
          ),
        );
      case PlayStatus.dropped:
        return Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.orange,
            shape: BoxShape.circle,
          ),
        );
      case PlayStatus.completed:
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AppColors.starGold,
            shape: BoxShape.circle,
          ),
        );
    }
  }

  static String _formatPlayTimeShort(int seconds) {
    if (seconds <= 0) return '0m';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h';
    return '${minutes}m';
  }

  // 修复：当天显示"今天"，不再显示"0天前"
  static String _formatRelativeTime(String lastOpenedAt) {
    if (lastOpenedAt.isEmpty) return '从未游玩';
    try {
      final dt = DateTime.parse(lastOpenedAt);
      final diff = DateTime.now().difference(dt);
      // 修复：当天显示"今天"
      if (diff.inDays == 0) return '今天';
      if (diff.inDays == 1) return '昨天';
      if (diff.inDays < 7) return '${diff.inDays}天前';
      if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}周前';
      if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
      return '${(diff.inDays / 365).floor()}年前';
    } catch (_) {
      return '从未游玩';
    }
  }
}

// ==================== 悬浮按钮组件 ====================
// ==================== 筛选标签组件 ====================
class _HoverChip extends StatefulWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _HoverChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_HoverChip> createState() => _HoverChipState();
}

class _HoverChipState extends State<_HoverChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: widget.isActive
                ? AppColors.selectedAccent.withOpacity(0.15)
                : _hovered
                    ? AppColors.cardHoverBg
                    : Colors.transparent,
            border: Border.all(
              color: widget.isActive
                  ? AppColors.selectedAccent
                  : _hovered
                      ? AppColors.border
                      : AppColors.borderLight,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w500,
              color: widget.isActive
                  ? AppColors.selectedAccent
                  : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
