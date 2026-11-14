import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../theme/app_styles.dart';
import 'smart_import_notification.dart';

enum NavPage { library, discover, join, home }

/// 侧边栏等比缩放的基准尺寸（= 展开态设计稿尺寸，单位逻辑 px）。
///
/// 🔴 为什么需要这套常量：此前侧栏所有尺寸都是**固定像素**
/// （侧栏 224 / 卡片 175×144 / 间距 32 / 主页 56），纵向固定需求恒为
/// [baseNeededHeight] ≈ 698。当窗口可用高不足时，`Column` 里的
/// `Expanded` 只拿到剩余高度，而子项是固定高 ⇒ `RenderFlex` **不压缩子项**
/// （`rendering/flex.dart` 的 `performLayout`：溢出时 `remainingSpace` 取 0，
/// 子项依次堆叠），超出部分被裁掉（`paint()` 里 `_hasOverflow` 走 clip 分支）。
/// 表现：三张卡按 176 步进往下堆，「添加」卡只剩顶部一截图标、
/// 「主页」被顶到底部且文字被裁到窗口外——界面「被切断」。
///
/// 现在按可用高**等比缩放**（宽高同比，保证卡片高宽比恒为 144/175），
/// 使任何窗口尺寸下三张卡 + 主页按钮都完整可见，且视觉比例始终一致。
///
/// 注：本类仅供 `sidebar.dart` 内部与 `main_container` 的切换按钮定位使用，
/// 刻意不导出（下划线私有类，同库内可见）。
class _SidebarMetrics {
  /// 展开态侧栏宽 = 左右 padding 24×2 + 卡片宽 175 (+1 圆整)
  static const double baseWidth = 224;

  /// 收起态侧栏宽（不参与缩放：收起态本身是紧凑图标条，固定宽即可）
  static const double collapsedWidth = 71;

  /// 卡片宽 / 高 / 间距
  static const double cardWidth = 175;
  static const double cardHeight = 144;
  static const double cardGap = 32;

  /// 导航区左右 padding（展开态）
  static const double hPadding = 24;

  /// 标题带：顶部 padding 31 + titleLarge 行高 36 + 底部 padding 17
  static const double titleTop = 31;
  static const double titleHeight = 36;
  static const double titleBottom = 17;

  /// 导航区顶部 padding（展开态）
  static const double navTop = 10;

  /// 主页扁条：高 56 + 底部 padding 20
  static const double homeHeight = 56;
  static const double homeBottom = 20;

  /// 展开态的纵向基准需求（scale = 1.0 时占满的最小可用高）
  static const double baseNeededHeight = titleTop +
      titleHeight +
      titleBottom +
      navTop +
      (cardHeight + cardGap) * 3 +
      homeHeight +
      homeBottom;

  /// 缩放下限：低于此值字号会小到不可读，且实际对应窗口高已小于
  /// 最小窗口高（540），正常不可达。真触底时由调用方退回滚动兜底。
  static const double minScale = 0.55;

  /// 图标基准尺寸与文字基准字号
  static const double iconLarge = 32;
  static const double iconGap = 12;
  static const double labelFontSize = 16;

  /// 由可用高算等比缩放系数。
  ///
  /// - 可用高非有限（未被约束）⇒ 返回 1.0（不缩放）
  /// - 可用高 ≤ 0 ⇒ 走下限（这是合法输入：外层暂时测不到高度时应尽量小，
  ///   而不是当成"未约束"放大到 1.0）
  /// - 下限 [minScale]，上限 4.0（纯防御；正常窗口不可能到）
  static double scaleFor(double availableHeight) {
    if (!availableHeight.isFinite) return 1.0;
    return (availableHeight / baseNeededHeight).clamp(minScale, 4.0).toDouble();
  }

  /// 展开态侧栏在给定可用高下的实际宽度（供外层定位切换按钮使用）。
  static double widthFor({
    required bool isCollapsed,
    required double availableHeight,
  }) =>
      isCollapsed ? collapsedWidth : baseWidth * scaleFor(availableHeight);
}

class Sidebar extends StatefulWidget {
  final NavPage currentPage;
  final ValueChanged<NavPage> onPageChanged;
  final bool isCollapsed;
  final VoidCallback? onToggle;

  /// 入库成功回调（侧边栏通知气泡一键入库后刷新库页）
  final VoidCallback? onGameAdded;

  /// 展开态侧栏在给定可用高下的实际宽度。
  ///
  /// 侧栏宽度现在随窗口高等比缩放（见 [_SidebarMetrics]），
  /// `main_container` 里定位「收展切换按钮」时必须用同一套口径，
  /// 否则按钮会与侧栏边缘错位。
  static double widthFor({
    required bool isCollapsed,
    required double availableHeight,
  }) =>
      _SidebarMetrics.widthFor(
        isCollapsed: isCollapsed,
        availableHeight: availableHeight,
      );

  /// 等比缩放系数（1.0 = 基准设计尺寸）。
  static double scaleFor(double availableHeight) =>
      _SidebarMetrics.scaleFor(availableHeight);

  const Sidebar({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    this.isCollapsed = false,
    this.onToggle,
    this.onGameAdded,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  int _hoveredIndex = -1;
  int _homeHoveredIndex = -1; // 0=normal, 1=hovered

  @override
  Widget build(BuildContext context) {
    // 收起态是紧凑图标条（固定 71 宽），纵向需求远小于展开态；
    // 只有展开态才需要按可用高等比缩放。
    if (widget.isCollapsed) return _buildExpanded(collapsed: true);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxHeight;
        // 🔴 constraints.maxHeight 可能是 infinity（若上层未约束）⇒ 视为不缩放
        final double scale = available.isFinite && available > 0
            ? (available / _SidebarMetrics.baseNeededHeight)
                .clamp(_SidebarMetrics.minScale, 4.0)
                .toDouble()
            : 1.0;
        return _buildExpanded(collapsed: false, scale: scale);
      },
    );
  }

  Widget _buildExpanded({required bool collapsed, double scale = 1.0}) {
    final bool isCollapsed = collapsed;
    // 等比缩放派生量（收起态恒为基准值，不受 scale 影响）
    final double s = isCollapsed ? 1.0 : scale;
    final double sidebarWidth = isCollapsed
        ? _SidebarMetrics.collapsedWidth
        : _SidebarMetrics.baseWidth * s;
    final double cardWidth = _SidebarMetrics.cardWidth * s;
    final double hPadding = _SidebarMetrics.hPadding * s;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.none,
      width: sidebarWidth,
      height: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border(
          right: BorderSide(
            color: AppColors.borderLight,
            width: 0.8,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.border.withOpacity(0.05),
            offset: const Offset(2, 0),
            blurRadius: 5,
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (isCollapsed)
                Padding(
                  padding: const EdgeInsets.only(top: 22, bottom: 20),
                  child: Text(
                    'CT',
                    // 与展开态「Chrono Tide」同一套标题样式（F1 得意黑
                    // titleLarge）：此前收起态是独立 TextStyle（系统默认
                    // 字体 + w700 合成粗体 + 20px），导致收起/展开切换时
                    // 标题字体肉眼可见地不一致。
                    style: AppStyles.titleLarge.copyWith(
                      color: AppColors.border,
                      letterSpacing: 0.6,
                    ),
                  ),
                )
              else
                Padding(
                  // 标题带随 scale 收缩（等比：31/17 的留白与字号同比）
                  padding: EdgeInsets.only(
                    top: _SidebarMetrics.titleTop * s,
                    bottom: _SidebarMetrics.titleBottom * s,
                  ),
                  child: SizedBox(
                    width: cardWidth + hPadding * 2,
                    child: Text(
                      'Chrono Tide',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: AppStyles.titleLarge.copyWith(
                        color: AppColors.border,
                        letterSpacing: 0.6 * s,
                        fontSize: AppStyles.titleLarge.fontSize! * s,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: isCollapsed
                    ? Padding(
                        padding: const EdgeInsets.only(
                            left: 12, right: 12, top: 8, bottom: 8),
                        child: Column(
                          children: [
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/library_icon_new.svg',
                              activeIconPath:
                                  'assets/images/library_icon_new.svg',
                              label: '库',
                              page: NavPage.library,
                              isActive: widget.currentPage == NavPage.library,
                              index: 0,
                            ),
                            _buildNavItemCollapsed(
                              iconPath: 'assets/images/discover_icon.svg',
                              activeIconPath:
                                  'assets/images/discover_active_icon.svg',
                              label: '探索',
                              page: NavPage.discover,
                              isActive: widget.currentPage == NavPage.discover,
                              index: 1,
                            ),
                            // 智能导入通知：徽章 + 悬停/主动弹出气泡
                            // 收起态按钮 47x60 含顶部 margin 12：
                            // - 徽章 top = 12 - 5 = 7（抵消 margin，贴按钮右上角）
                            // - 气泡垂直校正 +6（按钮中心 42 vs 含 margin 整体中心 36）
                            SmartImportNotification(
                              isActive: widget.currentPage == NavPage.join,
                              onGameAdded: widget.onGameAdded,
                              badgeTop: 7,
                              bubbleOffset: const Offset(8, 6),
                              child: _buildNavItemCollapsed(
                                iconPath: 'assets/images/add_icon.svg',
                                activeIconPath:
                                    'assets/images/add_active_icon.svg',
                                label: '添加',
                                page: NavPage.join,
                                isActive:
                                    widget.currentPage == NavPage.join,
                                index: 2,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Padding(
                        padding: EdgeInsets.only(
                            left: hPadding,
                            right: hPadding,
                            top: _SidebarMetrics.navTop * s),
                        child: Column(
                          children: [
                            _buildNavItemExpanded(
                              iconPath: 'assets/images/library_icon_new.svg',
                              activeIconPath:
                                  'assets/images/library_icon_new.svg',
                              label: '库',
                              page: NavPage.library,
                              isActive: widget.currentPage == NavPage.library,
                              hasBookmark: true,
                              bookmarkPath:
                                  'assets/images/discover_active_bookmark.png',
                              index: 0,
                              scale: s,
                            ),
                            _buildNavItemExpanded(
                              iconPath: 'assets/images/discover_icon.svg',
                              activeIconPath:
                                  'assets/images/discover_active_icon.svg',
                              label: '探索',
                              page: NavPage.discover,
                              isActive: widget.currentPage == NavPage.discover,
                              hasBookmark: true,
                              bookmarkPath:
                                  'assets/images/discover_active_bookmark.png',
                              index: 1,
                              scale: s,
                            ),
                            // 智能导入通知：徽章 + 悬停/主动弹出气泡
                            // 展开态卡片 175x144 含底部 margin 32：
                            // - 徽章默认 top -5（卡片无顶部 margin，位置正确）
                            // - 气泡垂直校正 -16（卡片中心 72 vs 含 margin 整体中心 88）
                            // 🔴 卡片随 scale 等比变化 ⇒ 徽章/气泡偏移必须同比，
                            //   否则卡片缩小时红点会飘到卡片中央。
                            SmartImportNotification(
                              isActive: widget.currentPage == NavPage.join,
                              onGameAdded: widget.onGameAdded,
                              badgeTop: -5 * s,
                              bubbleOffset: Offset(8 * s, -16 * s),
                              child: _buildNavItemExpanded(
                                iconPath: 'assets/images/add_icon.svg',
                                activeIconPath:
                                    'assets/images/add_active_icon.svg',
                                label: '添加',
                                page: NavPage.join,
                                isActive:
                                    widget.currentPage == NavPage.join,
                                hasBookmark: true,
                                bookmarkPath:
                                    'assets/images/add_active_bookmark.png',
                                index: 2,
                                scale: s,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              // 主页按钮 - 位于侧边栏底部
              // 网络状态指示已移至用户头像浮动气泡（见 FloatingUserButton）
              _buildHomeButton(isCollapsed: isCollapsed, scale: s),
            ],
          ),
        ],
      ),
    );
  }

  // 2026-09-11: 已删除死代码 buildSemicircleToggle（0 调用点，经用户批准）。
  // 其 UX-25 改进（Tooltip/Semantics/weight:700）已移植到在用组件
  // SidebarToggleWidget（main_container.dart）。在用按钮本体见
  // main_container.dart:854-866 挂载点。widget.onToggle 字段保留
  // （公开 API，暂无消费方）。

  Widget _buildNavItemExpanded({
    required String iconPath,
    required String activeIconPath,
    required String label,
    required NavPage page,
    required bool isActive,
    bool hasBookmark = false,
    String bookmarkPath = 'assets/images/add_active_bookmark.png',
    required int index,
    /// 等比缩放系数（宽高同比，保证卡片高宽比恒为 144/175）
    double scale = 1.0,
  }) {
    final currentPath = isActive ? activeIconPath : iconPath;
    final isHovered = _hoveredIndex == index;
    final double s = scale;
    final double cardW = _SidebarMetrics.cardWidth * s;
    final double cardH = _SidebarMetrics.cardHeight * s;

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => widget.onPageChanged(page),
        onTapDown: (_) => setState(() => _hoveredIndex = index),
        onTapUp: (_) => setState(() => _hoveredIndex = -1),
        onTapCancel: () => setState(() => _hoveredIndex = -1),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: EdgeInsets.only(bottom: _SidebarMetrics.cardGap * s),
          width: cardW,
          height: cardH,
          decoration: BoxDecoration(
            borderRadius: AppStyle.navHeroRadius,
            color: isHovered && !isActive
                ? AppColors.cardHoverBg
                // 石英白画布与 background 同色：极光档静息用白卡面保证按钮可见
                : (AppStyle.isModern
                    ? AppColors.buttonBackground
                    : AppColors.background),
            border:
                AppStyle.navHeroBorder(active: isActive, hovered: isHovered),
            boxShadow:
                AppStyle.navHeroShadow(active: isActive, hovered: isHovered),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (hasBookmark && isActive)
                Positioned(
                  // 书签贴在卡片左缘（-11 逻辑）与纵向 63 处，同比缩放
                  left: -11 * s,
                  top: 63 * s,
                  child: Transform.rotate(
                    angle: -6 * 3.14159 / 180,
                    child: Image.asset(
                      bookmarkPath,
                      width: 16 * s,
                      height: 18 * s,
                    ),
                  ),
                ),
              Center(
                child: FittedBox(
                  // 同主页按钮：字体 metrics 的非线性会让内容在大 scale 下
                  // 顶出卡片（亚像素级溢出），用 FittedBox 兜死。
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildIcon(
                          currentPath,
                          _SidebarMetrics.iconLarge * s,
                          _SidebarMetrics.iconLarge * s),
                      SizedBox(height: _SidebarMetrics.iconGap * s),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: (isActive
                                ? AppStyles.navActive
                                : AppStyles.navInactive)
                            .copyWith(
                          // 字号同比缩放；12 为可读下限（scale 触底时才生效）
                          fontSize: (_SidebarMetrics.labelFontSize * s)
                              .clamp(12.0, 40.0)
                              .toDouble(),
                          height: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // UX-25: 导航项添加 Tooltip（hover 显示名称）+ Semantics（屏幕阅读器播报）
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: core,
      ),
    );
  }

  Widget _buildNavItemCollapsed({
    required String iconPath,
    required String activeIconPath,
    required String label,
    required NavPage page,
    required bool isActive,
    required int index,
  }) {
    final currentPath = isActive ? activeIconPath : iconPath;
    final isHovered = _hoveredIndex == index;

    final core = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = -1),
      child: GestureDetector(
        onTap: () => widget.onPageChanged(page),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(top: 12),
          width: 47,
          height: 60,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppStyle.rNavItem),
            // BUG-05: 硬编码白色背景替换为主题感知的 navActiveBg / cardHoverBg
            color: isActive
                ? AppColors.navActiveBg
                : (isHovered ? AppColors.cardHoverBg : Colors.transparent),
            border:
                AppStyle.navPillBorder(active: isActive, hovered: isHovered),
            boxShadow: AppStyle.navPillShadow(active: isActive),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            child: _buildIcon(currentPath, 28, 28),
          ),
        ),
      ),
    );
    // UX-25: 收起态导航项——Tooltip 尤为关键（标签被隐藏），辅助屏幕阅读器播报
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: label,
        child: core,
      ),
    );
  }

  /// 网络状态指示已移至用户头像浮动气泡（FloatingUserButton），
  /// 见 lib/widgets/floating_user_button.dart。

  Widget _buildHomeButton({required bool isCollapsed, double scale = 1.0}) {
    final isActive = widget.currentPage == NavPage.home;
    final isHovered = _homeHoveredIndex == 1;
    final double s = scale;

    if (isCollapsed) {
      // 收起模式：紧凑圆形按钮
      final core = Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _homeHoveredIndex = 1),
          onExit: (_) => setState(() => _homeHoveredIndex = -1),
          child: GestureDetector(
            onTap: () => widget.onPageChanged(NavPage.home),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 47,
              height: 47,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppStyle.rNavItem),
                // BUG-05: 硬编码颜色替换为主题感知变量
                color: isActive
                    ? AppColors.navActiveBg
                    : (isHovered ? AppColors.cardHoverBg : Colors.transparent),
                border:
                    AppStyle.navPillBorder(active: isActive, hovered: isHovered),
                boxShadow: AppStyle.navPillShadow(active: isActive),
              ),
              child: Center(
                child: Icon(
                  Icons.home_rounded,
                  size: 22,
                  // BUG-05: 图标颜色从硬编码替换为主题感知变量
                  color: AppStyle.navIconColor(
                      active: isActive, hovered: isHovered),
                ),
              ),
            ),
          ),
        ),
      );
      // UX-25: 主页按钮添加 Tooltip + Semantics
      return Tooltip(
        message: '主页',
        waitDuration: const Duration(milliseconds: 400),
        child: Semantics(
          button: true,
          selected: isActive,
          label: '主页',
          child: core,
        ),
      );
    }

    // 展开模式：与导航卡同宽的扁条按钮，风格统一（图标在上、文字在下）
    // 🔴 宽高、圆角、图标、字号全部同比缩放，缩到极矮窗口时也不会溢出
    final core = Padding(
      padding: EdgeInsets.only(bottom: _SidebarMetrics.homeBottom * s),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _homeHoveredIndex = 1),
        onExit: (_) => setState(() => _homeHoveredIndex = -1),
        child: GestureDetector(
          onTap: () => widget.onPageChanged(NavPage.home),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _SidebarMetrics.cardWidth * s,
            height: _SidebarMetrics.homeHeight * s,
            decoration: BoxDecoration(
              borderRadius: AppStyle.navHeroRadius,
              border:
                  AppStyle.homeHeroBorder(active: isActive, hovered: isHovered),
              color: isHovered && !isActive
                  ? AppColors.cardHoverBg
                  // 同上：极光档静息用白卡面（石英白画布上不可隐形）
                  : (AppStyle.isModern
                      ? AppColors.buttonBackground
                      : AppColors.background),
              boxShadow:
                  AppStyle.homeHeroShadow(active: isActive, hovered: isHovered),
            ),
            child: FittedBox(
              // 🔴 用 FittedBox 而非裸 Column：图标尺寸与字号虽同比缩放，
              // 但字体行高来自字体 metrics（不是 fontSize 的线性函数），
              // 实测 2560×1440 档卡片内 Column 会溢出 0.38~0.45px（亚像素级，
              // 靠 Flexible 也压不到 0）。FittedBox 让内容等比缩到恰好装下，
              // 既彻底消除 RenderFlex 溢出，又保持视觉比例不变。
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.home_rounded,
                    size: 22 * s,
                    color: AppStyle.homeIconColor(
                        active: isActive, hovered: isHovered),
                  ),
                  SizedBox(height: 4 * s),
                  Text(
                    '主页',
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: (11 * s).clamp(10.0, 30.0).toDouble(),
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1 * s,
                      color: isActive
                          ? AppColors.titleBrown
                          : (isHovered
                              ? AppColors.titleBrown
                              : AppColors.secondaryText),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // UX-25: 主页按钮添加 Tooltip + Semantics
    return Tooltip(
      message: '主页',
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        selected: isActive,
        label: '主页',
        child: core,
      ),
    );
  }

  Widget _buildIcon(String path, double width, double height) {
    if (path.endsWith('.svg')) {
      return FutureBuilder<String>(
        future: DefaultAssetBundle.of(context).loadString(path),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return SvgPicture.string(
              snapshot.data!,
              width: width,
              height: height,
              fit: BoxFit.contain,
            );
          }
          if (snapshot.hasError) {
            debugPrint(
                '[SIDEBAR] ⚠️ SVG加载失败(已静默处理): $path | ${snapshot.error}');
            return const SizedBox.shrink();
          }
          return SizedBox(width: width, height: height);
        },
      );
    }
    return Image.asset(
      path,
      width: width,
      height: height,
      errorBuilder: (context, error, stackTrace) {
        debugPrint('[SIDEBAR] ❌ 图标加载失败: $path | 错误: $error');
        return const SizedBox.shrink();
      },
    );
  }
}

class SemicirclePainter extends CustomPainter {
  final bool isLeft;
  // BUG-05: 颜色从外部传入，避免硬编码，使主题切换时半圆按钮颜色跟随变化
  final Color fillColor;
  final Color borderColor;
  final Color shadowColor;

  SemicirclePainter({
    required this.isLeft,
    required this.fillColor,
    required this.borderColor,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double r = 17.0;
    const double d = 34.0;
    final paint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final shadowPaint = Paint()
      ..color = shadowColor.withOpacity(0.12)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final path = Path();
    if (isLeft) {
      path.moveTo(r, 0);
      path.arcToPoint(
        Offset(r, d),
        radius: const Radius.circular(r),
        clockwise: false,
      );
      path.close();
      canvas.saveLayer(
        Rect.fromLTWH(0, -2, r, d + 4),
        Paint(),
      );
      canvas.translate(0, 1);
      canvas.drawPath(path, shadowPaint);
      canvas.restore();
    } else {
      path.moveTo(0, 0);
      path.arcToPoint(
        Offset(0, d),
        radius: const Radius.circular(r),
        clockwise: true,
      );
      path.close();
      canvas.saveLayer(
        Rect.fromLTWH(-2, -2, r + 4, d + 4),
        Paint(),
      );
      canvas.translate(0, 1);
      canvas.drawPath(path, shadowPaint);
      canvas.restore();
    }

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(SemicirclePainter oldDelegate) =>
      isLeft != oldDelegate.isLeft ||
      fillColor != oldDelegate.fillColor ||
      borderColor != oldDelegate.borderColor ||
      shadowColor != oldDelegate.shadowColor;
}
