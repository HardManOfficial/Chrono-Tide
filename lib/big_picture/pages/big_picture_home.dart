import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/local_game_registry.dart';
import '../../services/tag_library_override_store.dart';
import '../../services/game_data_format.dart';
import '../../services/game_title_logo_service.dart';
import '../../theme/app_styles.dart';
import '../../widgets/game_title_logo.dart';
import '../../widgets/nsfw/nsfw_image.dart';
import '../big_picture_theme.dart';
import '../focus/bpm_zone_focus_controller.dart';
import '../widgets/bpm_focus_domain.dart';
import '../widgets/bpm_focus_zone.dart';
import '../widgets/bpm_interactive_wrapper.dart';
import '../widgets/bpm_action_hint_badge.dart';
import '../widgets/bpm_key_cap.dart';
import '../widgets/bpm_trigger_page_hint.dart';

/// BPM 主页 — v3 Cinema 重构
///
/// 借鉴 gal-launcher Cinema 主题「全部游戏」舞台式布局:
/// - 顶部: 搜索胶囊 + 库统计 + 续玩 chips (最近游玩)
/// - 左中: hero 信息层 (meta 行 / 得意黑大标题 / 副标题 / 简介)
/// - 右下: 启动胶囊按钮 (樱粉渐变) + 资料按钮
/// - 底部: shelf 封面横排 (选中上浮 + 樱粉辉光,点击切换舞台焦点)
///
/// 舞台焦点游戏 ([BigPictureHome.stageGame]) 由 Shell 持有,
/// 用于驱动全屏 backdrop;本页通过 [onStageGameChanged] 上报选中变化。
class BigPictureHome extends StatefulWidget {
  /// 舞台焦点游戏 (Shell 传下,驱动 backdrop)
  final LibraryGame? stageGame;

  /// 舞台焦点变化上报 (shelf 点击选中)
  final ValueChanged<LibraryGame> onStageGameChanged;

  /// 启动游戏 (启动按钮 / 双击封面)
  final ValueChanged<LibraryGame> onGameLaunch;

  /// 右侧滑出该游戏的详情面板 (gal-launcher Cinema 式)
  final ValueChanged<LibraryGame> onShowDetailPanel;

  /// 长按封面 → 动作表
  final ValueChanged<LibraryGame>? onGameLongPress;

  /// 空状态「添加游戏」按钮
  final VoidCallback? onAddGame;

  // v3.10.1 三个二级板块各自包一层 [BpmFocusDomain]（独立 FocusScope），
  // 手柄进入板块时的落点由焦点域现算，**本页不再需要任何焦点节点/key 插桩**。

  const BigPictureHome({
    super.key,
    required this.stageGame,
    required this.onStageGameChanged,
    required this.onGameLaunch,
    required this.onShowDetailPanel,
    this.onGameLongPress,
    this.onAddGame,
  });

  @override
  State<BigPictureHome> createState() => _BigPictureHomeState();
}

class _BigPictureHomeState extends State<BigPictureHome> {
  List<LibraryGame> _games = [];
  String _query = '';
  // v3.20: 搜索框聚焦态（引导提示聚焦后淡出）
  bool _searchFocused = false;

  /// v3.22: 搜索框焦点节点 —— 挂 `onKeyEvent` 实现「Esc 清空」：
  /// 查询词非空 → 清空并消费事件（此前 Esc 会冒泡到 BpmShortcuts 直接
  /// **退出大屏模式**，与 v3.21 提示文案「Esc 清空」完全相反，属既有 bug）；
  /// 查询词为空 → 不消费（保留「Esc 退出大屏」的既有全局语义）。
  late final FocusNode _searchFocus =
      FocusNode(onKeyEvent: _handleSearchKeyEvent);

  /// v3.22: 搜索框 Esc 键处理（见 [_searchFocus] 文档）
  KeyEventResult _handleSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_query.isNotEmpty) {
      setState(() => _query = '');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// shelf 横向滚动控制器 (焦点变化时联动滚动到可见)
  final ScrollController _shelfController = ScrollController();

  @override
  void initState() {
    _searchFocus.addListener(_onSearchFocusChanged);
    super.initState();
    _loadGames();
    LocalGameRegistry.instance.addListener(_onRegistryChanged);
  }

  @override
  void _onSearchFocusChanged() {
    if (mounted) setState(() => _searchFocused = _searchFocus.hasFocus);
  }

  void dispose() {
    LocalGameRegistry.instance.removeListener(_onRegistryChanged);
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _shelfController.dispose();
    super.dispose();
  }

  void _onRegistryChanged() {
    final reason = LocalGameRegistry.instance.lastChangeReason;
    if (reason == RegistryChangeReason.structural) {
      _loadGames();
    } else {
      // playTimeUpdate: 对象原地修改,仅刷新
      if (mounted) setState(() {});
    }
  }

  void _loadGames() {
    _games = LocalGameRegistry.instance.allGames;
    if (mounted) setState(() {});
    // 初次加载 / 舞台为空时,默认聚焦最近游玩的第一部（已隐藏的不参与）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.stageGame == null && _visibleGames.isNotEmpty) {
        final first = _sortedByRecency(_visibleGames).first;
        widget.onStageGameChanged(first);
      }
    });
  }

  // ============ 数据派生 ============

  /// 按最近游玩排序 (lastOpenedAt 非空在前,新在前;否则按 installedAt)
  List<LibraryGame> _sortedByRecency(List<LibraryGame> games) {
    final list = List<LibraryGame>.from(games);
    list.sort((a, b) {
      final aTime = DateTime.tryParse(a.lastOpenedAt);
      final bTime = DateTime.tryParse(b.lastOpenedAt);
      if (aTime != null && bTime != null) return bTime.compareTo(aTime);
      if (aTime != null) return -1;
      if (bTime != null) return 1;
      final aIn = DateTime.tryParse(a.installedAt);
      final bIn = DateTime.tryParse(b.installedAt);
      if (aIn != null && bIn != null) return bIn.compareTo(aIn);
      return b.installedAt.compareTo(a.installedAt);
    });
    return list;
  }

  /// 主页可见游戏（已剔除玩家在详情页「⋯ → 主页卡片」里隐藏的条目）。
  ///
  /// 2026-10-18：隐藏只是**主页展示层**的过滤 —— 「我的库」、动作表、
  /// 详情页、搜索之外的入口全部照旧，素材与存档一律不受影响。
  List<LibraryGame> get _visibleGames =>
      _games.where((g) => !g.homeHidden).toList();

  /// 搜索过滤后的 shelf 列表 (保持最近游玩排序)
  List<LibraryGame> get _filteredGames {
    final q = _query.trim().toLowerCase();
    final sorted = _sortedByRecency(_visibleGames);
    if (q.isEmpty) return sorted;
    return sorted.where((g) {
      final title = g.title.toLowerCase();
      final sub = g.subtitle.toLowerCase();
      final dev = g.developer.toLowerCase();
      if (title.contains(q) || sub.contains(q) || dev.contains(q)) {
        return true;
      }
      return g.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  int get _activeCount =>
      _games.where((g) => g.playStatus == PlayStatus.inProgress).length;
  int get _doneCount =>
      _games.where((g) => g.playStatus == PlayStatus.completed).length;
  int get _totalSeconds =>
      _games.fold(0, (sum, g) => sum + g.playTime);

  // ============ 封面路径解析 ============

  String? _resolveCoverPath(LibraryGame game) {
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      return game.coverUrl;
    }
    try {
      return GameDataFormat.findCoverFile(game.pathForCover)?.path;
    } catch (_) {
      return null;
    }
  }

  // ============ 构建 ============

  @override
  Widget build(BuildContext context) {
    if (_games.isEmpty) {
      return _buildEmptyState();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── v3.10 二级板块 ①「搜索栏板块」(搜索胶囊 + 继续游戏 chips) ──
        Positioned(
          top: BigPictureTheme.topBarHeight + 18,
          left: BigPictureTheme.pagePadding,
          right: BigPictureTheme.pagePadding,
          child: BpmFocusZone(
            zone: BpmZoneId.homeSearch,
            expand: const EdgeInsets.all(8),
            child: BpmFocusDomain(
              zone: BpmZoneId.homeSearch,
              child: _buildStageTop(),
            ),
          ),
        ),
        // hero 信息层 (左中,避开底部 shelf) —— 纯展示, 不属于任何板块
        //
        // 2026-10-18：顶边上移 14（+110 → +96）。标题放大 + 多出「会社 / 标签」
        // 两段后内容净增高约 45px，收一点上边距把这段涨幅抵消掉，避免在
        // 1080p 以下分辨率把 hero 顶到搜索框脸上。
        Positioned(
          left: BigPictureTheme.pagePadding,
          bottom: BigPictureTheme.shelfAreaHeight + 24,
          top: BigPictureTheme.topBarHeight + 96,
          child: _buildHeroInfo(),
        ),
        // ── v3.14: 主页右侧「操作按钮板块」已整体移除（用户拍板：对现在的 BPM
        //    没什么用了）—— 启动 / 详情 / 手柄改由卡片交互与二级详情承担：
        //    鼠标 = 单击进详情、双击启动；手柄 = A 进详情、X 启动、手柄按钮在详情内。
        //    对应 `kBpmHomeZones` 同步移除 homeActions（装配完整性测试据此校验）。
        // ── v3.10 二级板块 ③「游戏卡片列表板块」(底部 shelf) ──
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: BigPictureTheme.shelfAreaHeight,
          child: BpmFocusZone(
            zone: BpmZoneId.homeShelf,
            expand: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            // 🔴 v3.10.2 补: 这里原先**只包了 BpmFocusZone(视觉高亮),
            // 漏了 BpmFocusDomain(焦点域)**。没有独立 FocusScope,
            // `inDirection` 的候选集合就等于整个 stage(搜索框 + chips +
            // 操作按钮 + 所有卡片), 真机表现为「主页卡片列表左右键换不了
            // 游戏」; 且 `focusEntryOf(homeShelf)` 永远返回 false →
            // A 键连板块都进不去。三个二级板块必须一一对应装域。
            child: BpmFocusDomain(
              zone: BpmZoneId.homeShelf,
              child: _buildShelf(),
            ),
          ),
        ),
      ],
    );
  }

  // ============ 顶部区 ============

  Widget _buildStageTop() {
    // 2026-10-18：**「继续游戏」chips 行整体移除**（用户拍板）。
    // 主页顶部只剩搜索胶囊；续玩语义由 shelf 的「最近游玩排序 + 首卡默认
    // 舞台焦点」承担，不再单独占一行。焦点域 BpmZoneId.homeSearch 不变。
    return _buildSearchPill();
  }

  Widget _buildSearchPill() {
    return Container(
      width: 340,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: BpmColors.panelGlass,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: BpmColors.mistBlue),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              focusNode: _searchFocus,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 14,
                color: BpmColors.textPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索标题、会社、标签',
                hintStyle: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 14,
                  color: BpmColors.textMuted,
                ),
              ),
            ),
          ),
          // v3.21 修正提示时机：**聚焦后才提示**搜索快捷操作（输入即搜 /
          // Esc 清空），未聚焦不提示 —— 未聚焦时用户还没有输入意图，
          // 提示是噪音；聚焦才代表进入搜索操作。
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _searchFocused ? 1 : 0,
            child: IgnorePointer(
              child: _searchFocused ? _buildSearchHint() : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  /// v3.20 搜索框快捷键提示：键鼠 = 输入即搜 / Esc 清空；手柄 = A 输入 / B 返回
  Widget _buildSearchHint() {
    // v3.21: 总开关关闭 → 不提示
    if (!BpmGuideScope.enabledOf(context)) return const SizedBox.shrink();
    final gamepad =
        BpmInputModeScope.of(context) == BpmInputMode.gamepad;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (gamepad) ...[
        const BpmKeyCap(BpmKeyCapType.gamepadA, size: 17),
        const SizedBox(width: 3),
        const Text('输入', style: kHintStyle),
        const SizedBox(width: 7),
        const BpmKeyCap(BpmKeyCapType.gamepadB, size: 17),
        const SizedBox(width: 3),
        const Text('返回', style: kHintStyle),
      ] else ...[
        const Text('输入即搜', style: kHintStyle),
        const SizedBox(width: 6),
        const BpmKeyCap(BpmKeyCapType.keycap, label: 'Esc', size: 15),
        const SizedBox(width: 3),
        const Text('清空', style: kHintStyle),
      ],
      const SizedBox(width: 4),
    ]);
  }

  /// 底部栏统计组 (v3.5: 由右上角迁入并胶囊化美化)
  Widget _buildShelfStats() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _statPill(
          icon: Icons.schedule_rounded,
          label: '总时长',
          value: _formatTotalTimeShort(),
        ),
        const SizedBox(width: 8),
        _statPill(
          icon: Icons.play_circle_outline_rounded,
          label: '进行中',
          value: '$_activeCount',
        ),
        const SizedBox(width: 8),
        _statPill(
          icon: Icons.emoji_events_outlined,
          label: '已通关',
          value: '$_doneCount',
          accent: BpmColors.cherryRose,
        ),
      ],
    );
  }

  /// 单个统计胶囊 (毛玻璃底 + 图标 + 数值)
  Widget _statPill({
    required IconData icon,
    required String label,
    required String value,
    Color? accent,
  }) {
    final tint = accent ?? BpmColors.mistBlue;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: BpmColors.panelGlass,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: tint.withOpacity(0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 11.5,
              color: BpmColors.textMuted,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              fontFamily: AppStyles.enDecorativeFont,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: BpmColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTotalTimeShort() {
    if (_totalSeconds <= 0) return '0 小时';
    final hours = _totalSeconds ~/ 3600;
    if (hours > 0) return '$hours 小时';
    return '${(_totalSeconds % 3600) ~/ 60} 分钟';
  }

  // ============ hero 信息层 ============

  /// hero 版面（2026-10-18 三段式改版，用户拍板）
  ///
  /// 自上而下：
  ///   ① **标题**（logo 贴图 / 得意黑文字，已放大）
  ///   ② **会社 · 年份**（独立一行，雾蓝小字，字距拉宽）
  ///   ③ **标签**（小型圆角方框，独立一行；沿用 BPM 详情页标签的视觉语言）
  ///   ④ 简介（缩小一档）
  ///
  /// 🔴 三条约束：
  ///   - **不展示副标题**（用户明确要求；副标题在二级详情页完整保留）；
  ///   - 会社与标签**不得混排**（旧版 `会社 · 标签1 · 标签2` 单行已废弃）；
  ///   - 标题与 ② 之间刻意留 40px —— 「标题往上、会社与标签往下」的视觉
  ///     分离就靠这段留白，别把它改小。
  Widget _buildHeroInfo() {
    final game = widget.stageGame;
    if (game == null) return const SizedBox.shrink();

    final companyLine = _companyLine(game);
    final tags = _visibleHeroTags(game);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints:
            const BoxConstraints(maxWidth: BigPictureTheme.heroInfoMaxWidthCinema),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ① 大标题：有标题图（透明 logo）贴图，否则得意黑文字
            _buildHeroLogoTitle(game),
            // ② 会社 · 年份
            if (companyLine != null) ...[
              const SizedBox(height: 40),
              Text(
                companyLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: BigPictureTheme.heroMetaSize,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2.5,
                  color: BpmColors.mistBlue,
                  shadows: [
                    Shadow(
                        color: BpmColors.heroTextShadow,
                        offset: const Offset(0, 3),
                        blurRadius: 20),
                  ],
                ),
              ),
            ],
            // ③ 标签（小型方框，最多 5 个，超出省略）
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              _buildHeroTagRow(tags),
            ],
            // ④ 简介
            if (game.description.isNotEmpty) ...[
              const SizedBox(height: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Text(
                  game.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: BigPictureTheme.heroDescriptionSize,
                    height: BigPictureTheme.heroDescriptionHeight,
                    color: BpmColors.textSecondary,
                    shadows: [
                      Shadow(color: BpmColors.subTextShadow, blurRadius: 14),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 「会社 · 年份」单行文本；两者都缺 → null（该行整段不渲染）。
  ///
  /// 年份取 `release_date` 的前 4 位数字（兼容 `2019` / `2019-07-26` /
  /// `2019年7月` 等形态）；解析不出就只显示会社。
  String? _companyLine(LibraryGame game) {
    final segments = <String>[];
    final dev = game.developer.trim();
    if (dev.isNotEmpty) segments.add(dev);
    final year = _releaseYear(game.releaseDate);
    if (year != null) segments.add(year);
    if (segments.isEmpty) return null;
    return segments.join('  ·  ');
  }

  /// 从发售日期里抽 4 位年份；无效返回 null。
  String? _releaseYear(String raw) {
    final m = RegExp(r'(1[89]\d{2}|20\d{2})').firstMatch(raw);
    return m?.group(0);
  }

  /// 主页 hero 展示的标签（全局隐藏标签同样生效），最多 5 个。
  List<String> _visibleHeroTags(LibraryGame game) =>
      TagLibraryOverrideStore.instance.filterVisibleTags(game.tags).take(5).toList();

  /// 标签行：小型圆角方框（对标桌面版分类匣 chip），最多 5 个。
  ///
  /// 🔴 必须给 Wrap 一个**有界宽度**：hero 外层是 `Positioned(left/top/bottom)`
  /// 无 `right`，宽度约束是 loose（0..∞），Wrap 在无界宽度下**永不换行**、
  /// 会把标签一路铺到屏幕外。`ConstrainedBox(maxWidth: 600)` 是硬要求。
  Widget _buildHeroTagRow(List<String> tags) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in tags)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: BigPictureTheme.heroTagPaddingH,
                vertical: BigPictureTheme.heroTagPaddingV,
              ),
              decoration: BoxDecoration(
                color: BpmColors.deepBase.withOpacity(0.42),
                borderRadius:
                    BorderRadius.circular(BigPictureTheme.heroTagRadius),
                border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
              ),
              child: Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: BigPictureTheme.heroTagFontSize,
                  color: BpmColors.mistBlueSoft,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============ hero 大标题（标题图优先） ============

  /// hero 大标题：有标题图（透明 logo）就贴图，否则用得意黑文字。
  ///
  /// 无标题图时**顺手触发一次后台补抓**（`Timer.run` 脱离 build 相）：
  /// 只有用户真正切到这一屏才会去抓，不给全库扫描加成本。
  /// 服务内部有会话去重 + 7 天负缓存，重复 build 不会打满限流；
  /// 抓取成功后服务会更新注册表内存对象并通知刷新，这里无需轮询。
  Widget _buildHeroLogoTitle(LibraryGame game) {
    final fallback = Text(
      game.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontFamily: AppStyles.zhDecorativeFont,
        fontSize: BigPictureTheme.heroTitleSize,
        fontWeight: FontWeight.w400,
        height: 1.05,
        color: BpmColors.textPrimary,
        shadows: [
          Shadow(
              color: BpmColors.heroTextShadow,
              offset: const Offset(0, 4),
              blurRadius: 28),
          Shadow(color: BpmColors.heroTextGlow, blurRadius: 64),
        ],
      ),
    );

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
      maxWidth: BigPictureTheme.heroTitleLogoMaxWidth,
      // ≈ 两行 72px 标题的视觉高度；logo 是横扁素材，宽度自适应
      maxHeight: BigPictureTheme.heroTitleLogoMaxHeight,
      fallback: fallback,
    );
  }

  String _statusLabel(PlayStatus status) {
    switch (status) {
      case PlayStatus.notStarted:
        return '未开始';
      case PlayStatus.inProgress:
        return '进行中';
      case PlayStatus.dropped:
        return '搁置';
      case PlayStatus.completed:
        return '已通关';
    }
  }

  String _formatPlayTime(int seconds) {
    final hours = seconds ~/ 3600;
    if (hours > 0) return '$hours 小时';
    final minutes = (seconds % 3600) ~/ 60;
    return '$minutes 分钟';
  }

  // ============ 右下操作按钮 ============
  //
  // 🔴 v3.14：`_buildHeroActions`（启动 / 手柄 / 详情三钮）与 `_openGamepadConfig`
  // 已随「主页右侧按钮区移除」一并删除 —— 手柄配置入口收敛到
  // `GamepadGameConfigDialog.showForTitle`，由二级详情的「手柄」按钮调用。

  // ============ 底部 shelf ============

  Widget _buildShelf() {
    final games = _filteredGames;

    return Container(
      // v3.5: 栏边界趋近透明 —— 首段全透明, 只靠一段短渐变把卡片托住
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0.0, 1.0],
          colors: BpmColors.shelfScrim,
        ),
      ),
      // v3.23: 水平 padding 收窄到 shelfViewportBleed —— 横向 ListView 按视口
      // 硬裁剪，而卡片静止时的左右边缘原本正好压在视口边缘上，选中放大
      // （AnimatedScale 只画不改布局，左右各多画 224*0.06/2 = 6.72px）的那段
      // 连同该侧 2px 描边与圆角被一起切掉。外扩裁剪边界即修掉它。
      // ⚠️ 标题行的 32 与卡片的 32 内缩由下面各自补回（见 shelfContent-
      // HorizontalPadding 的用法），静止几何与改动前逐像素一致。
      padding: const EdgeInsets.fromLTRB(
        BigPictureTheme.shelfViewportBleed,
        14,
        BigPictureTheme.shelfViewportBleed,
        18,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 (樱粉圆点 + GALGAME + 计数)
          //
          // v3.23: 货架 Container 的水平 padding 已收窄到 shelfViewportBleed，
          // 标题行在这里自己补回差值（首尾各一个定宽占位），使标题左缘仍与
          // 卡片静止左缘齐平；Row 的可用宽度与改动前一致，Spacer 余量不变。
          Row(
            children: [
              const SizedBox(
                  width: BigPictureTheme.shelfContentHorizontalPadding),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: BpmColors.cherryRose,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: BpmColors.cherryRose.withOpacity(0.8),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                _query.isEmpty ? 'GALGAME' : '搜索结果',
                style: TextStyle(
                  fontFamily: AppStyles.enDecorativeFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 4,
                  color: BpmColors.textPrimary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '·  ${games.length} 部',
                style: TextStyle(
                  fontFamily: AppStyles.enDecorativeFont,
                  fontSize: 12,
                  color: BpmColors.mistBlue,
                ),
              ),
              const Spacer(),
              // v3.5: 原右上角统计, 迁入底部栏并胶囊化
              _buildShelfStats(),
              const SizedBox(width: 14),
              Text(
                '滚轮横向浏览',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 11,
                  color: BpmColors.textMuted,
                ),
              ),
              // v3.23: 尾端占位，凑回标题行的 32 右内缩（见本行上方的说明）
              const SizedBox(
                  width: BigPictureTheme.shelfContentHorizontalPadding),
            ],
          ),
          const SizedBox(height: 10),
          // 封面横排
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification &&
                    n.metrics.axis == Axis.vertical) {
                  return false;
                }
                return false;
              },
              child: Listener(
                onPointerSignal: (event) {
                  // 滚轮 → 横向滚动
                  if (event is! PointerScrollEvent) return;
                  final delta = event.scrollDelta.dy;
                  if (delta != 0 && _shelfController.hasClients) {
                    _shelfController.jumpTo(
                      (_shelfController.offset + delta)
                          .clamp(0.0, _shelfController.position.maxScrollExtent),
                    );
                  }
                },
                child: games.isEmpty
                    ? Center(
                        // 2026-10-18：区分「搜索无结果」与「全部被隐藏」——
                        // 后者必须告诉用户去哪儿找回来，否则会被当成 bug。
                        child: Text(
                          _query.isNotEmpty
                              ? '没有匹配的作品'
                              : '主页没有展示的作品\n在「我的库」或详情页「⋯ → 主页卡片」里恢复',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: AppStyles.uiFontFamily,
                            fontSize: 13,
                            height: 1.6,
                            color: BpmColors.textMuted,
                          ),
                        ),
                      )
                    : BpmTriggerPageHint(
                        child: ListView.separated(
                          controller: _shelfController,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.only(
                            // v3.23: 内容自己保持 32 的静止内缩（见货架 Container
                            // 的 shelfViewportBleed 说明）—— 视口边界因此比卡片
                            // 静止边缘各外扩 12px，选中放大的 6.72px 不再被裁。
                            left: BigPictureTheme.shelfContentHorizontalPadding,
                            right: BigPictureTheme.shelfContentHorizontalPadding,
                            top: 8,
                            bottom: 8,
                          ),
                          itemCount: games.length,
                          separatorBuilder: (_, __) => const SizedBox(
                              width: BigPictureTheme.shelfCardSpacing),
                          itemBuilder: (context, index) {
                            final game = games[index];
                            final selected =
                                widget.stageGame?.title == game.title;
                            return _ShelfCard(
                              key: ValueKey('shelf_${game.title}'),
                              game: game,
                              coverPath: _resolveCoverPath(game),
                              selected: selected,
                              onSelected: () =>
                                  widget.onStageGameChanged(game),
                              // v3.14: 单击 = 选中并进二级详情（原「详情」按钮入口已移除）
                              onOpenDetail: () =>
                                  widget.onShowDetailPanel(game),
                              onLaunch: () => widget.onGameLaunch(game),
                              onLongPress: widget.onGameLongPress != null
                                  ? () => widget.onGameLongPress!(game)
                                  : null,
                              // v3.5: 仅搜索态之外给首卡初始焦点。
                              // 焦点即选中 (见 _ShelfCard.onFocusChange),
                              // 而首卡即「最近游玩」= 默认舞台游戏, 语义自洽。
                              autofocus: index == 0 && _query.isEmpty,
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============ 空状态 (Cinema .empty-hero) ============

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.video_library_outlined,
              size: 64, color: BpmColors.textMuted),
          const SizedBox(height: 20),
          Text(
            '把第一部作品放进来',
            style: TextStyle(
              fontFamily: AppStyles.zhDecorativeFont,
              fontSize: 30,
              color: BpmColors.textPrimary,
            ),
          ),
          const SizedBox(height: 28),
          BpmInteractiveWrapper(
            onTap: widget.onAddGame,
            semanticsLabel: '添加游戏',
            borderRadius: BorderRadius.circular(30),
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 34),
              decoration: BoxDecoration(
                gradient: BpmColors.playButtonGradient,
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: BpmColors.cherryRose.withOpacity(0.32),
                    blurRadius: 36,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded,
                      size: 22, color: BpmColors.playButtonForeground),
                  const SizedBox(width: 8),
                  Text(
                    '添加游戏',
                    style: TextStyle(
                      fontFamily: AppStyles.zhDecorativeFont,
                      fontSize: 18,
                      color: BpmColors.playButtonForeground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============ shelf 封面卡片 ============

/// 底部 shelf 单张竖版封面卡 (Cinema .card)
///
/// - 选中: 樱粉边框 + 辉光 + 上浮 + 不透明
/// - 未选中: 压暗 (filter 模拟 via 叠层)
/// - v3.22 两段式交互: 点击未选中卡 = 选中(焦点即选中); 点击选中卡 = 进二级
///   详情; 双击 = 启动; 长按 = 动作表; 键盘连按 Enter = 启动
class _ShelfCard extends StatelessWidget {
  final LibraryGame game;
  final String? coverPath;
  final bool selected;
  final VoidCallback onSelected;

  /// v3.22: 点击**已选中**卡片进二级详情（选中动作由 wrapper 的
  /// [focusToActivate] 两段式承担，onTap 里不再重复 onSelected）
  final VoidCallback onOpenDetail;
  final VoidCallback onLaunch;
  final VoidCallback? onLongPress;
  final bool autofocus;

  const _ShelfCard({
    super.key,
    required this.game,
    required this.coverPath,
    required this.selected,
    required this.onSelected,
    required this.onOpenDetail,
    required this.onLaunch,
    this.onLongPress,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return BpmInteractiveWrapper(
      // v3.22: 两段式 —— 点击**未选中**卡片只落焦点（onFocusChange → onSelected
      // 切舞台，樱粉选中环浮现）；点击**已选中**卡片才进二级详情。
      // （v3.14 的「单击 = 选中并进详情」是设计漏洞：选中与进详情被绑在同一次点击）
      onTap: onOpenDetail,
      // v3.22: 双击启动前先切舞台 —— backdrop/OP 同步为正在启动的游戏。
      onDoubleTap: () {
        onSelected();
        onLaunch();
      },
      onLongPress: onLongPress,
      // v3.14: 手柄 A = 进详情；移除「连按两次 A 启动」（X 键启动），鼠标双击保留
      enableKeyDoubleTap: false,
      // v3.22: 键盘连按两次 Enter/Space = 启动（手柄合成 Enter 不受影响，
      // 仍为单击激活 —— FocusGlow 按事件来源分别裁决）
      keyboardDoubleTap: true,
      // v3.22: 鼠标两段式 —— 未选中时点击只落焦点选中
      focusToActivate: true,
      autofocus: autofocus,
      focusScale: BigPictureTheme.shelfFocusScale,
      hoverScale: 1.03,
      // v3.5: 焦*点*即选中 —— 键盘/手柄移动焦点即切换舞台,
      // 使「环在哪 = 舞台显示哪部」成为唯一语义。
      onFocusChange: (focused) {
        if (focused) onSelected();
      },
      // v3.5: 选中环由 selected 统一绘制, 关闭焦点环避免双环打架
      focusRing: false,
      semanticsLabel: game.title,
      borderRadius: radius,
      child: AnimatedContainer(
        duration: BigPictureTheme.focusAnimDuration,
        curve: Curves.easeOutCubic,
        width: BigPictureTheme.shelfCardWidth,
        height: BigPictureTheme.shelfCardHeight,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: selected
                ? BpmColors.cherryRose
                : BpmColors.topBarGlass.withOpacity(0.55),
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: BpmColors.deepBase.withOpacity(0.48),
                    blurRadius: 40,
                    offset: const Offset(0, 22),
                  ),
                  BoxShadow(
                    color: BpmColors.cherryRose.withOpacity(0.36),
                    blurRadius: 38,
                  ),
                ]
              : [
                  BoxShadow(
                    color: BpmColors.deepBase.withOpacity(0.32),
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 封面
              if (coverPath != null && coverPath!.isNotEmpty)
                NsfwImage.file(
                  coverPath!,
                  contentKind: NsfwContentKind.cover,
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  decodeWidth: 400,
                  child: Image.file(
                    File(coverPath!),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    cacheWidth: 400,
                    errorBuilder: (_, __, ___) =>
                        _buildPlaceholderCover(),
                  ),
                )
              else
                _buildPlaceholderCover(),
              // v3.20: 游玩状态角标（封面右上角，取代 hero 混排中的状态文字）
              Positioned(
                right: 8,
                top: 8,
                child: BpmStatusBadge(game.playStatus),
              ),
              // v3.20: 操作引导角标（左上角）—— 选中时浮现，随输入模式切换
              Positioned(
                left: 8,
                top: 8,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: selected ? 1 : 0,
                  child: _buildActionHint(),
                ),
              ),
              // 未选中轻微压暗 (v3.5: 0.35 → 0.10,压暗不再承担「选中」语义)
              // v2.7.1：包 IgnorePointer —— ColoredBox 是 HitTestBehavior.opaque，
              // 会挡掉其下 NsfwImage 的揭示角标（左上角眼睛按钮）的点击。
              AnimatedOpacity(
                duration: BigPictureTheme.focusAnimDuration,
                opacity: selected ? 0 : 0.10,
                child: IgnorePointer(
                  child: ColoredBox(color: BpmColors.cardMask),
                ),
              ),
              // 底部渐变 + 标题 (Cinema .cover::after + .label)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 1.0],
                      colors: [
                        const Color(0x00000000),
                        BpmColors.coverGradientBottom,
                      ],
                    ),
                  ),
                  child: Text(
                    game.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                      color: BpmColors.coverLabelText,
                      shadows: const [
                        Shadow(color: Color(0xE6000000), blurRadius: 8),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// v3.21: 操作角标改用共享组件 [BpmActionHintBadge]（与库页海报卡统一）。
  Widget _buildActionHint() => const BpmActionHintBadge();

  Widget _buildPlaceholderCover() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: BpmColors.placeholderGradient,
        ),
      ),
        child: Center(
          child: Icon(Icons.sports_esports_rounded,
              size: 30, color: BpmColors.textMuted),
        ),
      );
    }


  }

// v3.21: kHintStyle / kHintDividerStyle 迁至 widgets/bpm_key_cap.dart
// （kGuideHintStyle / kGuideHintDividerStyle），主页与切页引导共用。
const kHintStyle = kGuideHintStyle;
const kHintDividerStyle = kGuideHintDividerStyle;
