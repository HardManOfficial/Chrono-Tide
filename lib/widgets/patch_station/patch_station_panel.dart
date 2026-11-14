import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/patch_resource.dart';
import '../../services/local_game_registry.dart';
import '../../services/patch/patch_download_service.dart';
import '../../services/patch/patch_save_location.dart';
import '../../services/patch/patch_search_service.dart';
import '../../services/website_bookmark_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../../theme/app_styles.dart';
import 'patch_card.dart';
import 'patch_download_confirm.dart';
import 'patch_layout.dart';
import 'patch_site_logo.dart';

/// 补丁站横条（探索库入口，PATCH-STATION）。
///
/// ## 形态（2026-11-10 第二轮用户口述定稿）
///
/// 不再铺满整个窗口，而是**宽约屏幕一半**、右缘贴窗口右侧、从入口按钮正
/// 下方一直垂到窗口底部的大下拉条：
///
/// ```
/// ┌ 上板块（检索区，底色 buttonBackground）────────────┐
/// │ [🔍 搜索游戏名或补丁名…            (搜索)]  ↻      │
/// │ [📚 从游戏库选择：选择或搜索游戏名…        ⌄]      │
/// │ [全部 36] [饭团 2DFan 36] [鱼 鲲 0] [气泡 社区 0]  │
/// ├ 下板块（结果区，底色 background）──────────────────┤
/// │ ┌卡片┐ ┌卡片┐                                     │
/// │ └────┘ └────┘                                     │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// | 区域 | 内容 | 说明 |
/// |---|---|---|
/// | 1 | 搜索栏 + 栏内「搜索」按钮 | ⛔ 不能只靠回车 —— 不熟快捷键的人不会按 |
/// | 2 | 从**本地游戏库**选择 | 不是探索库在线游戏，是管理器库页里的本地条目 |
/// | 3 | 来源筛选 | 全部 / 2DFan / 鲲 / 社区，带条数徽章 |
/// | 4 | 补丁资源卡片 | 两张并排，每张 [查看下载] [原页] |
///
/// ## 为什么没有「保存到 …」底栏
///
/// 用户定调：与下载游戏本体一致 —— **点下载时才弹确认框**，在框里选目录。
/// 常驻一行路径既挤占结果区，又给人「已经选好了」的错觉。
///
/// ## 与详情页入口的关系
///
/// 数据层、卡片、详情浮层、下载链路全部共用；只有**外壳**不同：
/// 探索库是这块浅色横条，详情页是 `patch_station_dark_panel`
/// （深色锚定浮层，与「官方下载 / 资源分享」同款）。
class PatchStationPanel {
  PatchStationPanel._();

  /// 弹出补丁站。返回的 Future 在面板关闭时完成。
  ///
  /// [anchorKey] 入口按钮的 key，用于计算浮层位置。
  /// [game] 锁定态传入的游戏；通用态传 null。
  /// [lockGame] true = 锁定当前作品（不可换锚点）。
  /// [gamePicker] 通用态下「从游戏库选择」的数据源；
  ///   为 null 时自动读 [LocalGameRegistry]（本地游戏库）。
  /// [initialQuery] 打开时预填的搜索词（探索库带入当前搜索词）。
  static Future<void> show({
    required BuildContext context,
    required GlobalKey anchorKey,
    PatchGameRef? game,
    bool lockGame = false,
    String initialQuery = '',
    List<PatchGameRef> Function()? gamePicker,
  }) {
    final renderBox =
        anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return Future<void>.value();

    final offset = renderBox.localToGlobal(Offset.zero);
    final anchorRect = offset & renderBox.size;

    final completer = Completer<void>();
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _PatchStationOverlay(
        anchorRect: anchorRect,
        game: game,
        lockGame: lockGame,
        initialQuery: initialQuery,
        gamePicker: gamePicker,
        onClose: () {
          entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(entry);
    return completer.future;
  }
}

/// 游戏引用（面板不依赖 `GameModel`，避免 UI 层反向耦合模型细节）。
class PatchGameRef {
  const PatchGameRef({
    required this.id,
    required this.title,
    this.aliasTitles = const <String>[],
    this.coverPath = '',
    this.catalogWorkId,
  });

  final String id;
  final String title;

  /// 候选标题链（原名 / 英文名 / 繁中名），身份解析用
  final List<String> aliasTitles;

  /// 本地封面文件的**绝对路径**（空串 = 无封面）。
  ///
  /// 只为让「从游戏库选择」的下拉看起来就是库页那批游戏（用户面评：
  /// 光看一堆标题分不清这是库页还是探索库）。
  final String coverPath;

  /// **已知的** catalog work id（SITE-LIBRARY 全站库鲲命中：`siteId` 就是
  /// catalog id，2026-11-13）——非 null 时 [PatchSearchService.search] 跳过
  /// 「标题 → work id」身份解析直接锚定。原生库游戏（id 是 PB 记录 id）
  /// 保持 null，照走解析。
  final int? catalogWorkId;

  /// 主标题在前，别名在后，去重去空
  List<String> get candidateTitles => <String>[
        if (title.trim().isNotEmpty) title.trim(),
        ...aliasTitles.where((t) => t.trim().isNotEmpty),
      ];
}

// ==================== Overlay 内容 ====================

class _PatchStationOverlay extends StatefulWidget {
  const _PatchStationOverlay({
    required this.anchorRect,
    required this.onClose,
    this.game,
    this.lockGame = false,
    this.initialQuery = '',
    this.gamePicker,
  });

  final Rect anchorRect;
  final VoidCallback onClose;
  final PatchGameRef? game;
  final bool lockGame;
  final String initialQuery;
  final List<PatchGameRef> Function()? gamePicker;

  @override
  State<_PatchStationOverlay> createState() => _PatchStationOverlayState();
}

class _PatchStationOverlayState extends State<_PatchStationOverlay> {
  late final TextEditingController _searchController;
  final TextEditingController _pickerController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  late PatchGameRef? _game;
  String _query = '';
  bool _loading = false;
  PatchQueryResult? _result;
  String? _error;
  PatchSite? _activeSite;

  /// 游戏库下拉是否展开
  bool _pickerOpen = false;
  String _pickerQuery = '';

  /// 轮次闸：快速改关键词时，旧请求回来不能覆盖新结果
  int _runId = 0;

  /// 单飞闸：一次只能有一个检索在跑。
  ///
  /// 🔴 原来没有这道闸：点「搜索」和按回车会**同时**发两次请求，
  /// 两次都回来各自 `setState`，用户看到的是「卡一下 + 结果跳变」。
  /// 更糟的是并发真的会让 Windows 端偶发崩溃（见 v5 崩溃排查记录）。
  bool _searching = false;

  /// 当前展开的补丁（`PatchResource.key`）。null = 全部收起。
  ///
  /// 用户定调：点「查看下载」**不另开窗口**，就在卡片原位置向右展开，
  /// 右边的卡自动让到下排。
  String? _expandedKey;

  /// 每条补丁**上一次实际用过的直链**（key → url）。
  ///
  /// 2DFan 的直链是展开时从页面解析出来的（兑换后才有），模型里恒为 null。
  /// 下载失败后点「重试」走的是无参回调，没有这张表就会报「没有直链」。
  final Map<String, String> _lastDirectUrl = <String, String>{};

  /// 本地游戏库快照（第一次展开下拉时算一次，之后复用）。
  ///
  /// 🔴 不要在 `build()` 里现算：`LocalGameRegistry.allGames` 会排序 +
  /// 复制整张表（上千条），每次重建都做一遍会把 UI 线程拖到掉帧。
  List<PatchGameRef>? _gamesCache;

  @override
  void initState() {
    super.initState();
    _game = widget.game;
    _query = widget.initialQuery.trim();
    _searchController = TextEditingController(text: _query);
    _searchController.addListener(_onSearchTextChanged);
    _pickerController.addListener(() {
      final next = _pickerController.text.trim().toLowerCase();
      if (next != _pickerQuery) setState(() => _pickerQuery = next);
    });
    // 首帧后自动检索：锁定态用游戏名，通用态用带入的搜索词
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runSearch();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchTextChanged);
    _searchController.dispose();
    _pickerController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchTextChanged() {
    final next = _searchController.text.trim();
    if (next != _query) setState(() => _query = next);
  }

  // ---------------- 检索 ----------------

  Future<void> _runSearch({bool forceRefresh = false}) async {
    // 🔴 这个方法是「首帧后自动跑」+「用户点搜索」双入口，关闭面板时
    // postFrameCallback 仍可能排到了队列里 ⇒ 必须先判 mounted，
    // 否则会对已卸载的 State 调 setState（"setState() called after dispose()"）。
    if (!mounted) return;

    // 🔴 单飞闸：回车 + 点按钮会同时进这里。没有这道闸时两个请求并发，
    // 各自 setState，界面抖一下；Windows release 上还观测到过崩溃。
    if (_searching) return;

    final keyword = _query.trim();
    final titleKeyword = keyword.isNotEmpty ? keyword : (_game?.title ?? '');

    // 既不锁定游戏、也没有关键词 ⇒ 没什么可查的，直接空态
    if (titleKeyword.isEmpty && (_game == null)) {
      setState(() {
        _result = null;
        _error = null;
        _loading = false;
      });
      return;
    }

    final runId = ++_runId;
    _searching = true;
    setState(() {
      _loading = true;
      _error = null;
      // 换检索结果时把展开项收起来，否则展开卡里显示的是上一轮的条目
      _expandedKey = null;
    });

    try {
      final result = await PatchSearchService().search(
        keyword: titleKeyword,
        gameId: _game?.id,
        candidateTitles: _game?.candidateTitles ?? const <String>[],
        forceRefresh: forceRefresh,
      );
      if (!mounted || runId != _runId) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || runId != _runId) return;
      setState(() {
        _error = '检索失败：$e';
        _loading = false;
      });
    } finally {
      if (runId == _runId) _searching = false;
    }
  }

  // ---------------- 交互 ----------------

  void _pickGame(PatchGameRef? game) {
    // 🔴 顺序很重要：先落盘状态，再改控制器文本，最后**下一帧**才发检索。
    //
    // 旧实现在 setState 回调里改 `_searchController.text`，会同步触发
    // controller 的 listener → 在 setState 里再 setState；紧接着又在同一个
    // 点击回调里发起网络请求。用户在选完游戏后按回车/点搜索就崩，路径就在这。
    setState(() {
      _game = game;
      _pickerOpen = false;
      _expandedKey = null;
    });
    _pickerController.clear();

    if (game != null) {
      // 锚定后把搜索框也刷成这一部，避免「锚 A 搜 B」的歧义
      _searchController.text = game.title;
      _query = game.title;
    }

    // 交给下一帧：此时点击手势已经结束、焦点切换也已完成
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runSearch();
    });
  }

  void _togglePicker() {
    setState(() {
      _pickerOpen = !_pickerOpen;
      if (!_pickerOpen) _pickerController.clear();
    });
  }

  /// 候选游戏 = **库页（第一个页签）里的本地游戏**。
  ///
  /// 🔴 语义纠偏（用户 2026-11-10 第二次面评）：这里的「游戏库」指管理器
  /// 左侧「库」页里的本地游戏，**不是**探索库（探索是联网检索、没有本地
  /// 目录）。因此数据源必须与 `library_page.dart` 完全一致：
  /// `LocalGameRegistry.instance.allGames` —— 同一个注册表、同一套排序。
  ///
  /// 结果缓存一次（[invalidateGames] 可清），⛔ 不在 `build()` 里现算：
  /// `allGames` 每次调用都要排序 + 复制整张表。
  List<PatchGameRef> _games() {
    final injected = widget.gamePicker?.call();
    if (injected != null) return injected;

    final cached = _gamesCache;
    if (cached != null) return cached;

    try {
      final list = <PatchGameRef>[
        for (final g in LocalGameRegistry.instance.allGames)
          if (g.title.trim().isNotEmpty)
            PatchGameRef(
              id: g.gameId.trim().isNotEmpty ? g.gameId : g.directoryPath,
              title: g.title,
              aliasTitles: <String>[
                if (g.subtitle.trim().isNotEmpty) g.subtitle,
              ],
              coverPath: g.coverUrl.trim(),
            ),
      ]..sort((a, b) => a.title.compareTo(b.title));
      _gamesCache = list;
      return list;
    } catch (_) {
      // 探针 / 注册表未初始化 ⇒ 空列表，UI 显示「本地游戏库为空」
      return const <PatchGameRef>[];
    }
  }

  /// 重新扫一遍本地库（下拉里给一个「刷新」用；注册表变化后也可调）
  void invalidateGames() => _gamesCache = null;

  /// 记忆中的保存目录（不弹框，拿不到就给默认建议）
  Future<String?> _storedDir() async {
    try {
      return await PatchSaveLocation.instance.stored();
    } catch (_) {
      return null;
    }
  }

  /// 点「下载」的完整链路：确认框（可改目录）→ 下载（⛔ 不写游戏目录）
  ///
  /// [directUrl] 是**展开位里刚刚解析到的直链**（2DFan 兑换后才存在）。
  /// 模型里的 `directUrl` 对 2DFan 恒为空，所以必须由调用方把真实地址传进来，
  /// 否则确认框与下载服务都拿不到地址。
  Future<void> _startDownload(PatchResource r, {String? directUrl}) async {
    final url =
        (directUrl ?? _lastDirectUrl[r.key] ?? r.directUrl ?? '').trim();
    if (url.isNotEmpty) _lastDirectUrl[r.key] = url;
    final target = url.isEmpty
        ? r
        : r.copyWith(delivery: PatchDelivery.direct, directUrl: url);
    final initial = await _storedDir();
    if (!mounted) return;
    final dir = await PatchDownloadConfirm.show(
      context: context,
      resource: target,
      initialDir: initial,
    );
    if (dir == null) return;
    try {
      await PatchSaveLocation.instance.set(dir);
    } catch (_) {
      // 记不住不影响本次下载
    }
    await PatchDownloadService.instance.download(target, saveDir: dir);
  }

  /// 点「查看下载」/「收起」：**原地展开**，不另开窗口
  void _toggleExpand(PatchResource r) {
    setState(() {
      _expandedKey = _expandedKey == r.key ? null : r.key;
    });
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final metrics = _PanelMetrics.resolve(
      screen: screenSize,
      anchor: widget.anchorRect,
    );

    return Stack(
      children: [
        // 全屏遮罩：点击关闭
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onClose,
          ),
        ),
        Positioned(
          left: metrics.left,
          top: metrics.top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: metrics.width,
              height: metrics.height,
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(
                  color: AppStyle.isModern
                      ? AppColors.borderLight
                      : AppColors.border,
                  width: AppStyle.isModern ? AppStyle.wHairline : 1.6,
                ),
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: AppStyle.isModern
                    ? AppStyle.e3
                    : [
                        BoxShadow(
                          color: AppColors.border.withOpacity(0.16),
                          offset: const Offset(4, 5),
                          blurRadius: 0,
                        ),
                      ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  _buildHeaderBlock(metrics),
                  Expanded(child: _buildResultArea()),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 上板块：搜索 / 游戏库 / 来源 ----------

  Widget _buildHeaderBlock(_PanelMetrics metrics) {
    // 🔴 展开游戏库下拉时高度是「可变的」，而这块在 Column 里**不参与
    // 分配**（下面才是 Expanded）⇒ 面板矮的时候下拉会把结果区挤成负数、
    // 直接 RenderFlex overflow。这里按「面板高 − 固定部分」反推列表上限。
    final pickerMaxHeight =
        (metrics.height - 185).clamp(96.0, 190.0).toDouble();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border(
          bottom: BorderSide(
            color: AppColors.border.withOpacity(0.45),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 11, 10, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSearchRow(),
          const SizedBox(height: 8),
          _buildLibraryRow(),
          if (_pickerOpen) ...[
            const SizedBox(height: 6),
            _buildPickerList(pickerMaxHeight),
          ],
          const SizedBox(height: 8),
          _buildSiteTabs(),
        ],
      ),
    );
  }

  Widget _buildSearchRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.1),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  size: 15,
                  color: AppColors.secondaryText.withOpacity(0.6),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    style: AppStyles.bodyRegular.copyWith(fontSize: 12.5),
                    // 🔴 回车**必须下一帧再检索**：`onSubmitted` 是在平台
                    // 文本输入信道回调里同步执行的，此刻改路由/改焦点/
                    // 发网络请求都可能重入输入插件（Windows 端实测过
                    // 「选中游戏后按回车 → 卡死 → 进程退出」）。
                    onSubmitted: (_) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _runSearch();
                      });
                    },
                    decoration: InputDecoration(
                      hintText: '搜索游戏名或补丁名…',
                      hintStyle: AppStyles.bodyRegular.copyWith(
                        fontSize: 12.5,
                        color: AppColors.placeholderText.withOpacity(0.7),
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  GestureDetector(
                    onTap: () => _searchController.clear(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Icon(
                        Icons.cancel_rounded,
                        size: 14,
                        color: AppColors.secondaryText.withOpacity(0.5),
                      ),
                    ),
                  ),
                // 🔴 栏内搜索按钮：不熟快捷键的人不知道要按回车
                _searchButton(),
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        _iconButton(
          icon: _loading ? Icons.hourglass_top_rounded : Icons.refresh_rounded,
          tooltip: '刷新（清缓存重查）',
          onTap: _loading ? null : () => _runSearch(forceRefresh: true),
        ),
        _iconButton(
          icon: Icons.close_rounded,
          tooltip: '关闭',
          onTap: widget.onClose,
        ),
      ],
    );
  }

  Widget _searchButton() {
    final active = !_loading;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? () => _runSearch() : null,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.5,
          duration: const Duration(milliseconds: 120),
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            margin: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.accentCyan,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_rounded,
                    size: 12, color: AppColors.onAccentSolid),
                const SizedBox(width: 3),
                Text(
                  '搜索',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onAccentSolid,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final active = onTap != null;
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 16,
              color: AppColors.secondaryText.withOpacity(active ? 0.9 : 0.35),
            ),
          ),
        ),
      ),
    );
  }

  /// 「从游戏库选择」下拉（本地游戏库，不是探索库在线列表）
  Widget _buildLibraryRow() {
    final game = _game;
    final locked = widget.lockGame;
    final active = _pickerOpen;

    return MouseRegion(
      cursor: locked ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: locked ? null : _togglePicker,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(
              color: active
                  ? AppColors.selectedAccent.withOpacity(0.65)
                  : AppColors.border.withOpacity(0.85),
              width: active ? 1.4 : 1,
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Icon(
                Icons.video_library_outlined,
                size: 14,
                color: AppColors.secondaryText.withOpacity(0.7),
              ),
              const SizedBox(width: 7),
              Text(
                '从游戏库选择',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11,
                  color: AppColors.secondaryText.withOpacity(0.85),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  game?.title ?? '（来自「库」页的本地游戏）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 12,
                    fontWeight:
                        game == null ? FontWeight.w400 : FontWeight.w600,
                    color: game == null
                        ? AppColors.placeholderText.withOpacity(0.8)
                        : AppColors.primaryText,
                  ),
                ),
              ),
              if (game != null && !locked)
                GestureDetector(
                  onTap: () => _pickGame(null),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.cancel_rounded,
                      size: 13,
                      color: AppColors.secondaryText.withOpacity(0.55),
                    ),
                  ),
                ),
              if (!locked)
                Icon(
                  active
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: AppColors.secondaryText.withOpacity(0.75),
                )
              else
                Text(
                  '已锁定',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 10.5,
                    color: AppColors.secondaryText.withOpacity(0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPickerList(double maxListHeight) {
    final games = _games();
    final filtered = _pickerQuery.isEmpty
        ? games
        : games
            .where((g) =>
                g.title.toLowerCase().contains(_pickerQuery) ||
                g.aliasTitles
                    .any((a) => a.toLowerCase().contains(_pickerQuery)))
            .toList();

    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border.withOpacity(0.8), width: 1),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 7, 9, 3),
            child: Row(
              children: [
                Icon(Icons.search_rounded,
                    size: 13, color: AppColors.secondaryText.withOpacity(0.6)),
                const SizedBox(width: 5),
                Expanded(
                  child: TextField(
                    controller: _pickerController,
                    autofocus: true,
                    style: AppStyles.bodyRegular.copyWith(fontSize: 11.5),
                    // 🔴 下拉里的回车必须**选中第一条**，而不是什么都不做：
                    // 用户选完游戏会下意识按回车，旧实现里回车打在筛选框上
                    // 毫无反应，紧接着又被当成「搜索」触发一次并发请求。
                    onSubmitted: (_) {
                      if (filtered.isNotEmpty) {
                        _pickGame(filtered.first);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: '筛选本地游戏库…（回车选中第一项）',
                      hintStyle: AppStyles.bodyRegular.copyWith(
                        fontSize: 11.5,
                        color: AppColors.placeholderText.withOpacity(0.7),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                Text(
                  '${filtered.length}/${games.length}',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 10,
                    color: AppColors.secondaryText.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(
                games.isEmpty
                    ? '本地游戏库为空 —— 先去「库」页导入游戏'
                    : '没有匹配的游戏',
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11.5,
                  color: AppColors.secondaryText.withOpacity(0.65),
                ),
              ),
            )
          else
            // 🔴 用定高 + 不 shrinkWrap：`shrinkWrap: true` 会把**所有**条目
            // 一次性布局（本地库上千条时直接卡死 UI），而定高之后
            // `ListView` 才是懒加载的，只画可见的那几条。
            SizedBox(
              height: maxListHeight,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 3),
                itemCount: filtered.length,
                itemExtent: 30,
                itemBuilder: (_, i) => _buildPickerTile(filtered[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPickerTile(PatchGameRef g) {
    final selected = g.id == _game?.id;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _pickGame(g),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          color: selected
              ? AppColors.selectedAccent.withOpacity(0.08)
              : Colors.transparent,
          child: Row(
            children: [
              // 封面缩略图：让用户一眼看出「这就是库页那批游戏」
              _pickerCover(g.coverPath),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  g.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11.5,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded,
                    size: 13, color: AppColors.selectedAccent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickerCover(String path) {
    const size = 22.0;
    final empty = path.trim().isEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: size,
        height: size,
        child: empty
            ? Container(
                color: AppColors.buttonBackground,
                alignment: Alignment.center,
                child: Icon(
                  Icons.image_not_supported_outlined,
                  size: 11,
                  color: AppColors.placeholderText.withOpacity(0.6),
                ),
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                // 文件可能被用户删了 / 库搬走了 ⇒ 不能让它变成红屏
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.buttonBackground,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 11,
                    color: AppColors.placeholderText.withOpacity(0.6),
                  ),
                ),
              ),
      ),
    );
  }

  // ---------- 来源筛选 ----------

  Widget _buildSiteTabs() {
    final counts = _result?.countsBySite ?? const <PatchSite, int>{};
    final failures = _result?.failures ?? const <PatchSite, String>{};
    final total = _result?.resources.length ?? 0;

    final tabs = <Widget>[
      _siteTab(
        site: null,
        label: '全部',
        count: total,
        active: _activeSite == null,
        onTap: () => setState(() => _activeSite = null),
      ),
      for (final site in PatchSite.values)
        _siteTab(
          site: site,
          label: site.displayName,
          count: counts[site] ?? 0,
          active: _activeSite == site,
          failed: failures.containsKey(site),
          onTap: () => setState(() => _activeSite = site),
        ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            tabs[i],
          ],
        ],
      ),
    );
  }

  Widget _siteTab({
    required PatchSite? site,
    required String label,
    required int count,
    required bool active,
    required VoidCallback onTap,
    bool failed = false,
  }) {
    final accent =
        site == null ? AppColors.selectedAccent : PatchSiteLogo.colorOf(site);
    final color = failed
        ? AppColors.dangerRed
        : (active ? AppColors.primaryText : AppColors.secondaryText);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: active
                ? accent.withOpacity(0.12)
                : AppColors.background.withOpacity(0.6),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: active
                  ? accent.withOpacity(0.55)
                  : AppColors.border.withOpacity(0.45),
              width: active ? 1.2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (site != null) ...[
                PatchSiteLogo(site: site, size: 13),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  color: color,
                ),
              ),
              if (count > 0 || failed) ...[
                const SizedBox(width: 4),
                Text(
                  failed ? '!' : '$count',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: failed ? color : color.withOpacity(0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 下板块：结果 ----------

  Widget _buildResultArea() {
    if (_loading && _result == null) {
      return _centerHint(
        icon: Icons.cloud_sync_rounded,
        title: '正在检索补丁…',
        subtitle: '鲲 · 2DFan · 社区 三源并发',
        spinning: true,
      );
    }
    if (_error != null) {
      return _centerHint(
        icon: Icons.error_outline_rounded,
        title: '检索失败',
        subtitle: _error!,
        actionLabel: '重试',
        onAction: () => _runSearch(forceRefresh: true),
      );
    }

    final result = _result;
    if (result == null) {
      return _centerHint(
        icon: Icons.travel_explore_rounded,
        title: '输入游戏名开始查找补丁',
        subtitle: '也可以从游戏库挑一部作品锚定，结果更精准',
      );
    }

    final visible = _visibleResources(result);
    if (visible.isEmpty) {
      return _centerHint(
        icon: Icons.inbox_rounded,
        title: result.allFailed ? '所有补丁源都不可用' : '没有找到补丁',
        subtitle: _emptySubtitle(result),
      );
    }

    return Column(
      children: [
        if (result.hasAnyFailure) _buildFailureBanner(result),
        Expanded(
          // 下载进度只影响卡片底行 ⇒ 只让结果区跟随下载状态重建，
          // ⛔ 不要把整个面板包进 AnimatedBuilder（每 200ms 全树重建）
          child: AnimatedBuilder(
            animation: PatchDownloadService.instance,
            builder: (_, __) => _buildGrid(
              visible,
              showGameTitle: !widget.lockGame,
            ),
          ),
        ),
      ],
    );
  }

  List<PatchResource> _visibleResources(PatchQueryResult result) {
    final site = _activeSite;
    if (site == null) return result.resources;
    return result.resources.where((r) => r.site == site).toList();
  }

  String _emptySubtitle(PatchQueryResult result) {
    if (_activeSite != null) {
      return '${_activeSite!.displayName} 没有该作品的补丁，试试切到「全部」';
    }
    if (result.resolvedByTitle) {
      return '未能确认是哪部作品，换个名称或从游戏库锚定';
    }
    return '换个关键词，或用原名 / 英文名再试';
  }

  Widget _buildFailureBanner(PatchQueryResult result) {
    final text = result.failures.entries
        .map((e) => '${e.key.displayName}：${e.value}')
        .join('；');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.dangerRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 12, color: AppColors.dangerRed),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 10.5,
                color: AppColors.dangerRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 结果网格：**两列** + 原地展开。
  ///
  /// ## 关键点（都是用户实机反馈换来的）
  ///
  /// 1. 🔴 **列宽必须用 `LayoutBuilder` 的真实可用宽算**。之前用
  ///    `metrics.width`（面板宽）算，两者一旦不同步就会「一张卡占一行、
  ///    右边空一大片」。现在按 `constraints.maxWidth` 反推，并满足
  ///    `columns × cardWidth + (columns−1) × gap == innerWidth`。
  /// 2. 展开项宽度 = 整行 ⇒ `Wrap` 自然把它单独放一行，后面的卡片自动
  ///    让到下一行（正是用户要的「往右展开、右边的卡往下排」）。
  Widget _buildGrid(
    List<PatchResource> items, {
    required bool showGameTitle,
  }) {
    const gap = 10.0;
    const padH = 12.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final inner = math.max(0.0, constraints.maxWidth - padH * 2);
        final grid = PatchGridMetrics.resolve(innerWidth: inner, gap: gap);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(padH, 10, padH, 12),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final r in items)
                if (_expandedKey == r.key)
                  PatchExpandedCard(
                    key: ValueKey<String>('expanded-${r.key}'),
                    resource: r,
                    width: inner,
                    showGameTitle: showGameTitle,
                    download: PatchDownloadService.instance.stateOf(r.key),
                    onCollapse: () => _toggleExpand(r),
                    onDownloadDirect: (url) => _startDownload(r, directUrl: url),
                    onCancel: PatchDownloadService.instance.cancel,
                  )
                else
                  PatchCard(
                    key: ValueKey<String>(r.key),
                    resource: r,
                    width: grid.cardWidth,
                    showGameTitle: showGameTitle,
                    download: PatchDownloadService.instance.stateOf(r.key),
                    onOpenInfo: () => _toggleExpand(r),
                    onOpenPage: r.webUrl.trim().isEmpty
                        ? null
                        : () => WebsiteBookmarkService.openExternal(r.webUrl),
                    onDownload: () => _startDownload(r),
                    onCancel: PatchDownloadService.instance.cancel,
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _centerHint({
    required IconData icon,
    required String title,
    String? subtitle,
    bool spinning = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinning)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                icon,
                size: 30,
                color: AppColors.secondaryText.withOpacity(0.35),
              ),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryText.withOpacity(0.8),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11,
                  height: 1.4,
                  color: AppColors.secondaryText.withOpacity(0.7),
                ),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: onAction,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      border: Border.all(color: AppColors.border, width: 1),
                    ),
                    child: Text(
                      actionLabel,
                      style: AppStyles.bodyRegular.copyWith(
                        fontSize: 11,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ==================== 尺寸反推 ====================

/// 面板几何（宽/高/位置 + 卡片列数）。
///
/// 🔴 **一切由可用空间反推，禁止写死**（见 AGENTS 的「面板内容必须整份
/// 落框内」铁律）：写死的宽高在小窗或高缩放下必然压内容或溢出。
class _PanelMetrics {
  const _PanelMetrics({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  /// 面板宽 = 屏幕宽的 52%（用户定的「一半左右」）
  static const double _widthRatio = 0.52;

  /// 宽下限：再窄就放不下一张 250dp 的卡 + 左右内边距
  static const double _minWidth = 460;
  static const double _maxWidth = 700;

  /// 面板与窗口边缘的留白
  static const double _margin = 16;

  /// 高下限：再小连「检索区 + 一行卡」都放不下
  static const double _minHeight = 320;

  /// 与锚点的竖直间距
  static const double _anchorGap = 6;

  static _PanelMetrics resolve({
    required Size screen,
    required Rect anchor,
  }) {
    // 宽度：按比例，受屏幕自身可用宽夹住（小窗时先让位）
    final usableWidth = math.max(0.0, screen.width - _margin * 2);
    final width = math.min(
      usableWidth,
      _clampSafe(screen.width * _widthRatio, _minWidth, _maxWidth),
    );

    // 水平：右缘贴窗口右侧（视觉上与顶栏「发布上传」右缘对齐）
    final left = math.max(_margin, screen.width - width - _margin);

    // 竖直：从锚点下方开始，一直垂到窗口底部
    var top = anchor.bottom + _anchorGap;
    var height = screen.height - top - _margin;

    // 屏幕太矮 / 锚点太靠下 ⇒ 退回「距顶 margin 起、留出底边」
    if (height < _minHeight) {
      height = math.min(_minHeight, math.max(0.0, screen.height - _margin * 2));
      top = math.max(_margin, screen.height - _margin - height);
    }

    return _PanelMetrics(
      left: left,
      top: math.max(0, top),
      width: width,
      height: math.max(0, height),
    );
  }

  /// `num.clamp` 的安全版本：`hi < lo` 时返回 `lo` 而不是抛异常。
  ///
  /// 项目里已有多次踩坑记录（`clamp(lo, hi)` 当 `hi < lo` 抛
  /// `ArgumentError`），尺寸反推里尤其容易撞上（MediaQuery 未就绪时 0×0）。
  static double _clampSafe(double v, double lo, double hi) {
    if (hi <= lo) return lo;
    if (v.isNaN) return lo;
    return v.clamp(lo, hi);
  }
}
