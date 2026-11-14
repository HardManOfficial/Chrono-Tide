# Chrono Tide 大屏模式 (BPM) 架构文档

> 面向开发者 · 版本 v1.3.1 · 2026-07-06

本文档描述 BPM 的技术架构、模块职责、焦点系统设计、测试策略与扩展指南。读者应已熟悉 Flutter 桌面开发与项目整体结构。

> **v1.3.1 变更摘要**：4K/高 DPI 显示适配修复——在 `main.dart` 窗口就绪后调用 `windowManager.setAsFrameless()` 完全移除 Windows `WS_THICKFRAME` 边框（`titleBarStyle.hidden` 只隐藏标题栏，不移除可调整大小的边框，在 4K + 200% 缩放下会显示为 2-3px 白边）；添加主题切换监听器 `_onThemeChangedForWindow` 动态同步窗口背景色，避免主题切换瞬间露出旧色；BPM `enter()/exit()` 增加 `_syncWindowBackground()` 全屏前后同步窗口背景色，避免全屏切换瞬间露出边框色。详见 3.1 节。

> **v1.3 变更摘要**：首页从 v1.2 双栏布局重写为 Ubiquity 风格全屏沉浸式 5 层叠加结构——移除 `BackdropFilter`（修复模糊效果溢出到 NavBar/标题栏的关键 Bug），改用三段式纵向渐变遮罩；右侧 480px 文字列表改为底部水平竖版封面轮播（140×200，2:3 比例）；信息层移至左中最大宽 720px，标题加大至 48px；启动按钮改半透明胶囊样式；筛选 chips 移至顶部右侧浮动。详见 3.4 节。

> **v1.2 变更摘要**：全页面 UI 系统优化（30+ 问题修复）——首页 / 库页 / 探索页焦点滚动联动与布局容错；添加页引入 BPM 专属包装组件 `BpmFileDropZone` / `BpmMetadataSection` 替换桌面组件（包装模式：仅替换交互/视觉层，业务逻辑透传 `JoinController`）；详情页修复无 exe 死胡同（就地打开启动管理器）、启动按钮窄屏溢出、焦点系统与字号规范。详见各章节 v1.2 标注。

---

## 一、整体架构

### 1.1 模式切换架构

BPM 与桌面模式共享同一个 `MainContainer` 顶层 widget，通过监听 `BigPictureManager.instance`（单例 ChangeNotifier）在两种外壳之间切换：

```
MaterialApp
└── MainContainer (StatefulWidget)
    └── AnimatedBuilder(animation: BigPictureManager)
        └── Stack（结构恒定，槽位顺序固定 —— 见 features/bpm_mode_transition.md §3）
            ├── [槽位 0] 桌面外壳 _buildDesktopShell()（BPM 入场幕布升起后 → 零尺寸占位）
            └── [槽位 1] AnimatedBuilder(animation: [_bpmEnter, _bpmLogo])
                          └── BPM 外壳 + 入场过渡层（幕布 / 手柄图标 / 镜头推近）
```

**关键决策**：

| 决策 | 选择 | 理由 |
|---|---|---|
| 模式切换机制 | 监听 `BigPictureManager` 重建（非路由） | 与桌面模式 page 切换一致，不引入 Navigator 路由 |
| 状态承载 | 单例 `BigPictureManager extends ChangeNotifier` | 仿 `AppThemeManager` 模式，全局可访问，无 BuildContext 依赖 |
| 全屏控制 | `windowManager.setFullScreen` + 测试注入 handler | 避免测试环境依赖 windowManager |
| 进入 BPM 动画 | 三段式：① 幕布合拢 150ms（全屏切换藏在这段）→ ② 手柄图标描出 421ms + **收尾柔光 119ms**（**两个光点自顶中央同点出发、一左一右沿轮廓勾出整个手柄**，合拢后边框向外柔光一闪；兼作加载指示）→ ③ 幕布揭开 + 外壳 1.06→1.0 落座 300ms | Steam 大屏切换观感；总时长 ≈0.99s 不变；详见 `features/bpm_mode_transition.md` |
| 退出 BPM | **无动画**：窗口先复位 → 再切壳，进度直达稳态 | 用户要求「返回桌面不需要动画，但同样丝滑」；零额外延迟 |
| 动画进度 | 幕布/外壳 `AnimationController _bpmEnter`（0→1，两段 `animateTo`）+ 图标 `AnimationController _bpmLogo`（0→1） | ②段与「窗口全屏完成」闸门**并行**、谁慢等谁，避免窗口抖动落在可见阶段 |

### 1.2 数据共享

BPM 与桌面模式**完全共享**业务服务层，不引入任何 BPM 专属数据副本：

| 服务 | 共享方式 | BPM 使用位置 |
|---|---|---|
| `LocalGameRegistry.instance` | 单例 ChangeNotifier | Home / Library / Detail |
| `GameLaunchService.instance` | 单例（无状态） | Detail / 双击启动 |
| `GameRepository.getGameList` | 静态方法 | Discover |
| `JoinController` | 实例化于 Join 页 | Join |
| `GlobalInstallCenter` | 单例 | Discover 下载 |
| `AppThemeManager.instance` | 单例 ChangeNotifier | Shell 顶层 `AnimatedBuilder` |
| `GameConfigManager` | 单例 | GameLaunchService 内部 |

---

## 二、文件结构

```
lib/big_picture/
├── big_picture_manager.dart        # 全局状态: enter/exit/toggle + 全屏 handler
├── big_picture_shell.dart          # 外壳: BpmShortcuts + NavBar + Content + Detail
├── big_picture_theme.dart          # 视觉常量集合 (尺寸/缩放/字号/动画时长)
│
├── focus/
│   ├── focus_grid_policy.dart      # 二维网格焦点导航策略 (Rect 几何算法)
│   └── bpm_shortcuts.dart           # Shortcuts+Actions 封装 (F11/ESC/Ctrl+F)
│
├── widgets/
│   ├── focus_glow.dart             # 焦点辉光基础组件 (边框+阴影+Enter/Space 激活)
│   ├── bpm_interactive_wrapper.dart # 焦点+悬停+触屏三合一交互包装器
│   ├── big_picture_nav_bar.dart    # 左侧 96px 垂直导航栏 (v1.1: 显式顺序 [home, library, discover, join]，文字「探索」「添加」)
│   ├── big_picture_game_card.dart  # 320x180 16:9 游戏卡片
│   ├── big_picture_content_row.dart # 横向滚动内容行 (首页用)
│   ├── big_picture_action_sheet.dart # 底部动作表 (启动/标记/管理/删除)
│   ├── bpm_file_drop_zone.dart     # BPM 文件拖拽区 (v1.2 新增 - 包装桌面 FileDropZone,替换交互层为 BpmInteractiveWrapper)
│   └── bpm_metadata_section.dart   # BPM 元数据展示区 (v1.2 新增 - 包装桌面 MetadataSection,统一 BPM 字号/配色,可配置高度)
│
└── pages/
    ├── big_picture_home.dart       # 首页 (v1.3: Ubiquity 风格全屏沉浸式 5 层叠加结构 - 全屏封面背景 + 渐变遮罩 + 左中信息层 + 顶部右侧筛选 chips + 底部水平竖版封面轮播)
    ├── big_picture_library_page.dart # 游戏库 (v1.2: _FocusableGameCard 焦点滚动 + LayoutBuilder 窄屏适配 + 排序菜单 BPM 风格化)
    ├── big_picture_discover.dart   # 探索 (v1.2: 双重 Focus 修复 + ConstrainedBox + 加载更多可重试 + RepaintBoundary)
    ├── big_picture_join.dart       # 添加 (v1.2: BpmFileDropZone + BpmMetadataSection 替换桌面组件 + FocusTraversalGroup + 错误卡片对比度)
    └── big_picture_detail.dart     # 详情页 (v1.2: 无 exe 就地打开启动管理器 + onExeSelected 持久化 + Wrap/ConstrainedBox 窄屏容错 + FocusTraversalGroup + AppBar 标题「详情」 + 字号规范)
```

**对应测试结构**：

```
test/big_picture/
├── big_picture_manager_test.dart       # 6 tests: enter/exit/toggle 状态机 + 幂等
├── launch_result_test.dart             # 5 tests: LaunchResult 数据 + 单例
├── focus_grid_policy_test.dart         # 6 tests: 4方向 + 边界 null
└── widgets/
    ├── focus_glow_test.dart            # 5 tests: 渲染/autofocus/Enter/Space/无回调
    ├── bpm_interactive_wrapper_test.dart # 5 tests: tap/disabled/render/focusScale/longPress
    └── big_picture_nav_bar_test.dart   # 3 tests: 渲染/点击/退出
```

**总计 30 项自动化测试全部通过**。

---

## 三、模块职责

### 3.1 BigPictureManager (`big_picture_manager.dart`)

全局状态单例，仿 `AppThemeManager` 模式：

```dart
class BigPictureManager extends ChangeNotifier {
  static final BigPictureManager instance = BigPictureManager._();
  
  bool _isActive = false;
  bool get isActive => _isActive;
  
  // 测试注入点: 替换 windowManager 调用
  SetFullScreenHandler _setFullScreenHandler = (fs) async {
    await windowManager.setFullScreen(fs);
  };
  
  @visibleForTesting
  void setFullScreenHandler(SetFullScreenHandler handler) {
    _setFullScreenHandler = handler;
  }
  
  Future<void> enter() async { /* 幂等进入 */ }
  Future<void> exit() async { /* 幂等退出 */ }
  Future<void> toggle() async => _isActive ? exit() : enter();
}
```

**设计要点**：

1. **幂等性**：`enter()`/`exit()` 重复调用不产生副作用
2. **测试可注入**：`setFullScreenHandler` 让测试替换 windowManager 调用，避免引入 mocktail
3. **不持久化**：每次应用启动默认桌面模式，符合用户预期
4. **状态变更通知**：所有状态变化通过 `notifyListeners()` 触发 `MainContainer` 重建

**入口位置（v1.1 变更）**：

v1.0 入口位于桌面侧边栏底部 `_buildBigPictureButton`。v1.1 将入口迁移至桌面模式两处位置，避免侧边栏展开时挤压主页按钮。v1.2 进一步重构入口按钮形态：用户窗口由「底部第三按钮（挤压原两按钮）」改为「头部右上角 `_HeaderIconButton`（与关闭按钮并列，32×32）」；主页入口由「icon+text 胶囊」改为「24×24 纯图标按钮」，两处入口均置于原 UI 空白处，不再影响既有布局：

| 入口位置 | 触发链 | 实现位置 |
|---|---|---|
| 主页列表头部图标按钮 | `HomePage.onToggleBigPicture` → `BigPictureManager.instance.toggle()` | `lib/pages/home_page.dart` 的 `_buildBigPictureButton`（24×24 纯图标按钮，位于 header `Spacer()` 后的空白处）+ `lib/main_container.dart` HomePage 构造注入 `onToggleBigPicture` |
| 用户窗口右上角图标按钮 | `UserProfileModal.onOpenBigPicture` → 关闭用户窗口 → `BigPictureManager.instance.toggle()` | `lib/widgets/user_profile_modal.dart` 头部右上角 `_HeaderIconButton`（与关闭按钮并列，复用同一 32×32 视觉规范）+ `lib/main_container.dart` 的 `_buildProfileModal` 注入 `onOpenBigPicture` |
| F11 全局快捷键 | `BpmShortcuts` 监听 `LogicalKeyboardKey.f11` → `BigPictureManager.instance.toggle()` | 仅在 BPM 内生效；桌面模式需通过入口按钮进入 |

入口设计参考 Steam / Playnite：作为整体使用样式切换功能，而非主要页面导航项。

**v1.3.1 4K/高 DPI 适配修复**：

v1.3.0 及之前版本在 4K 显示屏 + 高 DPI 缩放（200%/250%）下，窗口周边会出现明显白边。根源在 `windows/runner/win32_window.cpp` 使用 `WS_OVERLAPPEDWINDOW` 样式（包含 `WS_THICKFRAME` 可调整大小的边框），而 `WindowOptions(titleBarStyle: TitleBarStyle.hidden)` **只隐藏标题栏，不移除 `WS_THICKFRAME` 边框**。在 4K + 200% 缩放下，`WS_THICKFRAME` 边框会被放大到 2-3px，显示为系统主题色（浅色模式下是白色）。同时 `EnableNonClientDpiScaling`（PerMonitor V1 API）与 Flutter 的 PerMonitor V2 不完全兼容，导致非客户区缩放不一致。

修复方案（三层同步）：

1. **`main.dart` 窗口初始化**：在 `waitUntilReadyToShow` 回调中调用 `windowManager.setAsFrameless()`，完全移除 Windows 窗口边框。`CustomTitleBar` 已通过 `windowManager.startDragging()` 提供拖拽功能，不依赖 `WS_THICKFRAME`。

2. **`main.dart` 主题切换监听器**：添加全局函数 `_onThemeChangedForWindow`，在主题切换时调用 `windowManager.setBackgroundColor()` 动态同步窗口背景色。避免主题切换瞬间，窗口边缘露出旧主题色（在 4K 高 DPI 下会被放大为明显边框）。

3. **`big_picture_manager.dart` BPM 全屏同步**：`enter()` 在调用 `setFullScreen(true)` 之前先调用 `_syncWindowBackground()` 同步窗口背景色；`exit()` 在 `setFullScreen(false)` 之后再次同步。避免全屏切换瞬间露出旧背景色。

**trade-off**：`setAsFrameless()` 会移除 Windows 原生窗口阴影和圆角（Windows 11）。这是可接受的 trade-off，因为：
- 应用通过 `CustomTitleBar` 提供完整的窗口控制（拖拽/最小化/最大化/关闭）
- 应用有 `minimumSize` 约束，不需要用户调整窗口大小
- 消除 4K 白边问题比保留窗口阴影更重要
- DWM 阴影通常仍会保留（与窗口样式独立）

### 3.2 BigPictureShell (`big_picture_shell.dart`)

BPM 模式顶层外壳，组织 4 个页面 + 详情页 + 动作表：

```dart
@override
Widget build(BuildContext context) {
  return CustomTitleBar(
    child: BpmShortcuts(
      onToggleBpm: () => BigPictureManager.instance.toggle(),
      onEscape: _onEscape,
      onFocusSearch: _onFocusSearch,
      child: AnimatedBuilder(
        animation: AppThemeManager.instance,
        builder: (context, _) {
          // Stack: 背景层 + Row[NavBar(FocusTraversalGroup), Content(FocusTraversalGroup)]
        },
      ),
    ),
  );
}
```

**关键设计**：

1. **复用 `CustomTitleBar`**：保留窗口拖动 / 最小化 / 最大化 / 关闭逻辑
2. **`BpmShortcuts` 顶层包裹**：所有快捷键在 BPM 内全局生效
3. **`FocusTraversalGroup` 隔离**：导航栏与内容区是两个独立焦点域，Tab 在其间切换
4. **`AnimatedSwitcher` 200ms fade**：页面切换平滑过渡
5. **`searchFocusNode` 注入**：Shell 持有 Library 页搜索框焦点节点，供 Ctrl+F 使用

### 3.3 BigPictureTheme (`big_picture_theme.dart`)

视觉常量集合，所有数值基于"10 英尺 UI"理念：

| 类别 | 关键常量 | 值 |
|---|---|---|
| 整体缩放 | `scale` | 1.6 |
| 导航栏 | `navBarWidth` / `navItemSize` | 96 / 64 |
| 卡片 | `cardWidth` × `cardHeight` | 320 × 180 (16:9) |
| 卡片焦点态 | `cardFocusScale` / `cardHoverScale` | 1.05 / 1.02 |
| 字号 | `displayFontSize` ~ `labelFontSize` | 36 ~ 14 |
| 动画时长 | `focusAnimDuration` / `modeTransitionDuration` / `pageTransitionDuration` | 200ms / 250ms / 200ms |

颜色仍走 `AppColors` 静态门面（非 const），BPM 不引入独立主题色板，确保主题切换一致性。

### 3.4 Pages 模块 v1.1 变更说明

四个页面在 v1.1 完成重要重构与 bug 修复，关键变更如下：

**BigPictureHome (`pages/big_picture_home.dart`)**

从 v1.0 的「横向 3 行滚动卡片（最近游玩 / 我的收藏 / 全部游戏）」重构为**双栏布局**：

```dart
Row(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    Expanded(flex: 3, child: _buildDetailPanel()),      // 左侧详情
    SizedBox(width: 480, child: _buildGameListPanel()),  // 右侧列表
  ],
)
```

- **左侧详情面板**：`BackdropFilter` 模糊封面背景 + 标签行 + 标题（ZhiMangXing）+ 开发者 + 简介 + 大封面（240x135）+ 启动按钮 + 详情按钮 + 页面指示器 + 状态徽章
- **右侧游戏列表面板**：统计头部 + 5 个筛选 chips（对应 `PlayStatus` 枚举：全部 / 游玩中 / 已通关 / 未入坑 / 已弃坑）+ `ListView.separated`
- **数据源**：`LocalGameRegistry.instance`（与 v1.0 一致），不再调用 `GameRepository`（v1.0 的「全部游戏」行曾是远端数据）
- **切换交互**：方向键 ↑↓ 或鼠标点击右侧列表项，`setState` 更新 `_currentIndex`，左侧详情面板同步重建

**BigPictureDiscover (`pages/big_picture_discover.dart`)**

修复 v1.0 的三处 bug：

1. **数量统计延迟**：新增 `int _totalCount = -1`（-1 加载中 / 0+ 实际总数）字段，`_loadInitialGames` 使用 `Future.wait` 并发获取总数与第一页数据，避免先渲染再补数量的视觉抖动
2. **无法下滑**：GridView 用 `FocusTraversalGroup(policy: FocusGridPolicy())` 包裹；每张卡片 `Focus(onFocusChange)` 在获焦时 `WidgetsBinding.instance.addPostFrameCallback` 内调用 `Scrollable.ensureVisible(context, alignment: 0.5, duration: 200ms)` 联动滚动
3. **详情窗口不可拖动**：`_DiscoverDetailDialog` 宽度从 720 加至 880，`constraints.maxHeight` 从固定 600 改为 `MediaQuery.of(context).size.height - 200`，内部 `SingleChildScrollView` 包裹内容

**BigPictureJoin (`pages/big_picture_join.dart`)**

恢复 v1.0 缺失的**元数据编辑板块**：

- 新增 `_buildMetadataEditSection()`：游戏名 / 一键抓取按钮 / 标签 / 开发者 / 简介输入字段
- 新增 `_buildScrapeButton()`：含 loading 状态切换、空名校验
- 新增 `_buildScrapeResultsSection()`：以固定高度 280 容器包裹桌面 `MetadataSection`，复用其抓取结果卡片与选中逻辑
- 新增 `_buildLabeledInput()` 辅助方法：统一 BPM 风格的标签 + 输入框组合
- 与桌面模式入库流程完全一致：可修改、填写、抓取、导入

**BigPictureNavBar (`widgets/big_picture_nav_bar.dart`)**

- 行 62-63 改为显式顺序列表 `[NavPage.home, NavPage.library, NavPage.discover, NavPage.join]` 而非 `NavPage.values.map`，因为 `NavPage` 枚举定义顺序（library, discover, join, home）与 BPM 期望顺序不符
- `_navLabel` 中 `NavPage.discover` 由「发现」改为「探索」，`NavPage.join` 由「入库」改为「添加」，与桌面模式一致

### 3.5 Pages 模块 v1.2 变更说明

v1.2 完成全页面 UI 系统优化，统一焦点滚动联动模式与布局容错规范：

**BigPictureHome (`pages/big_picture_home.dart`)**

**v1.3 Ubiquity 风格全屏沉浸式重写**——从 v1.2 的双栏布局（左详情 + 右 480px 列表）改为 5 层 Stack 叠加结构：

```dart
Stack(fit: StackFit.expand)
├── Layer 0: Image.file(coverPath, fit: cover)  // 全屏封面,无 BackdropFilter
├── Layer 1: LinearGradient(0.55→0.15→0.45→0.85) // 三段式渐变遮罩
├── Layer 2: Positioned(left, top:0, bottom: posterCarouselHeight)
│   └── Container(maxWidth: heroInfoMaxWidth=720)  // 左中信息层
│       └── Column[标签 + 48px 标题 + 元数据 + 简介 + 启动/详情按钮]
├── Layer 3: Positioned(top, right)              // 顶部右侧浮动筛选 chips
└── Layer 4: Positioned(left, right, bottom, height: 240) // 底部水平轮播
    └── ListView.separated(horizontal) [_PosterCard(140×200)]
```

**关键设计决策**：

1. **移除 `BackdropFilter`**：v1.2 用 `BackdropFilter(blur 12,12)` 模糊封面背景，但 `StackFit.expand` 导致模糊层扩展到整个左侧面板甚至溢出边界，**模糊效果渗透到 NavBar 和窗口标题栏**——v1.3 直接 `BoxFit.cover` 铺满，配合三段式纵向渐变遮罩保证文字可读
2. **竖版封面轮播**：v1.2 右侧 480px 文字列表视觉割裂 → v1.3 底部水平 140×200（2:3 接近 GAL 标准封面）轮播，选中卡片 `Border.all(selectedAccent, 3)` + `Transform.scale(1.08)` + `BoxShadow` 辉光，未选中卡片 `Colors.black.withOpacity(0.45)` 暗化遮罩
3. **半透明按钮**：启动按钮保留强调色填充，详情按钮改用 `Colors.white.withOpacity(0.18)` 玻璃拟态 + `Border.all(white.withOpacity(0.4))`，不破坏沉浸感
4. **autofocus 策略**：v1.2 让启动按钮 autofocus → v1.3 让首项轮播卡片 autofocus，启动按钮不抢焦点，让用户先浏览选定游戏再启动，符合 Ubiquity 交互范式
5. **新增 `BigPictureTheme` 常量**：`posterCardWidth/Height/Spacing`、`posterCarouselHeight`、`posterFocusScale`、`heroInfoMaxWidth`、`glassButtonOpacity`、`scrimTopOpacity/scrimBottomOpacity`
6. **筛选下空状态**：新增 `_buildEmptyFilterState()` 显示「清除筛选」按钮，区别于全库空状态

**`_PosterCard` 组件**（v1.3 新增）：

复用 v1.2 的 Focus + Scrollable.ensureVisible 联动滚动模式（外层 `Focus(canRequestFocus: false, descendantsAreFocusable: true, onFocusChange)` 监听焦点变化触发横向滚动），但布局改为竖版卡片：底部渐变 + 单行标题 + 右上角选中标记圆点。

**v1.2 历史决策**（已被 v1.3 替代，仅供参考）：
- 移除顶部冗余「Chrono Tide 大屏模式」标题行
- 页面指示器智能省略：游戏 >7 显示「X / Y」文字，≤7 显示圆点
- `bool _initialFocusRequested` 持久化标志解决 `autofocus: index == 0` 每次 build 重触发问题
- 空状态新增「前往添加」「前往探索」按钮（`onGoToAdd` / `onGoToDiscover` 回调注入）

**BigPictureLibraryPage (`pages/big_picture_library_page.dart`)**

- 新增 `_FocusableGameCard` 包装器（与首页 `_GameListTile` 相同的 Focus + ensureVisible 模式）
- 顶部 `LayoutBuilder` 适配窄屏（<720px 两行布局），搜索框 `Flexible(ConstrainedBox(maxWidth: 320))`
- 数量显示改为 `'${games.length} / ${_games.length} 个游戏'`（过滤后 / 总数）
- 排序菜单用 `showAppDialog` + `BpmInteractiveWrapper` 替代 `SimpleDialog`，选中项 radio_button 图标 + 高亮
- `bool _initialFocusRequested` 持久化 autofocus

**BigPictureDiscover (`pages/big_picture_discover.dart`)**

- `_DiscoverCard` 外层 `Focus(canRequestFocus: false, descendantsAreFocusable: true)` 修复双重 Focus 节点冲突
- 详情对话框 `Container(width: 880)` → `ConstrainedBox(maxWidth: 880)`，内容区 `Expanded(SingleChildScrollView)` 包裹，按钮组 `Wrap`
- 移除卡片显式 width/height，让 gridDelegate 紧约束生效
- 加载更多失败时不设 `_hasMoreData = false`，允许重试
- `_onScroll()` 首行 `if (!_scrollController.hasClients) return;` 守卫
- `RepaintBoundary` 包裹卡片

**BigPictureJoin (`pages/big_picture_join.dart`)** + **新增包装组件**

引入**包装模式**——BPM 专属包装版本仅替换交互层与视觉层，业务逻辑透传 `JoinController`，桌面原代码不动：

- 新增 `widgets/bpm_file_drop_zone.dart`：包装桌面 `FileDropZone`，`InteractiveWrapper` → `BpmInteractiveWrapper`，支持键盘焦点（`autofocus: true`），字号统一到 BPM 规范。复用 `handleFileSelected` / `pickFile` / `clearFileSelection` / `detectFileType` / `getFileIcon` / `getFileLabel` / `setDragging` / `isDragging` API
- 新增 `widgets/bpm_metadata_section.dart`：包装桌面 `MetadataSection`，`InteractiveWrapper` → `BpmInteractiveWrapper`，高度可配置（默认 320，移除硬编码 203），平台徽章颜色映射。复用 `scrapeResults` / `selectedResult` / `selectScrapeResult` / `isScraping` API
- 移除导入按钮 `autofocus: true`（与 TextField/BpmFileDropZone 焦点冲突）
- 抓取按钮进度环颜色 `AppColors.border` → `Colors.white` 提升对比度
- 错误卡片文字 `AppColors.dangerRed` → `AppColors.primaryText`（图标/边框/底色保持 dangerRed 保留错误语义）
- 主体用 `FocusTraversalGroup` 包裹

**BigPictureDetail (`pages/big_picture_detail.dart`)**

- **P1 无 exe 死胡同修复**：`_handleLaunch` 中 `resolveUserChoice` 返回 null 时，不再弹 SnackBar 让用户切桌面模式，改为 `await _openLaunchManager()` 就地引导
- **P2 onExeSelected 实现**：`onExeSelected: (_) {}` 空回调改为调用 `GameLaunchService.instance.persistUserChoice(widget.game.title, selectedExe)` + `AppSnackBar.info('已更新启动程序')`；传 `initialExePath` 让对话框预选当前 exe（参考桌面 `library_page.dart:1494-1513` canonical 模式）
- **P3 启动按钮窄屏容错**：`Row` → `Wrap(spacing, runSpacing)`，启动按钮 `width: launchButtonWidth` → `ConstrainedBox(minWidth: launchButtonWidth)`
- **P4 焦点修复**：移除外层 `Focus(autofocus: true)`，改由返回按钮 `BpmInteractiveWrapper(autofocus: true)` 接管初始焦点
- **P5 FocusTraversalGroup**：主体包裹 `FocusTraversalGroup` 统一焦点导航顺序
- **P6 AppBar 标题**：`widget.game.title` → `'详情'`，避免与左面板大标题重复
- **P7 元数据项**：`Column` 包 `Expanded` + `maxLines:1 + ellipsis` 防止长文本横向溢出
- **P8 描述**：`Text` 加 `maxLines: 12, overflow: ellipsis`
- **P9 字号规范**：`fontSize: 11` → `BigPictureTheme.labelFontSize`（14）符合 BPM 最小字号规范

**焦点滚动联动统一模式**（v1.2 跨页面共性）：

```dart
// 首页 _GameListTile / 库页 _FocusableGameCard / 探索页 _DiscoverCard 共用模式
return Focus(
  canRequestFocus: false,           // 外层 Focus 仅监听,不参与导航
  descendantsAreFocusable: true,    // 允许内部 BpmInteractiveWrapper 获焦
  onFocusChange: (focused) {
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      });
    }
  },
  child: BpmInteractiveWrapper(...),
);
```

---

## 四、焦点系统设计

BPM 焦点系统是分层的，每层职责清晰：

```
┌──────────────────────────────────────────────────────────────┐
│ BpmShortcuts (Shortcuts + Actions)                          │  ← 全局快捷键
│   F11 / ESC / Ctrl+F                                         │
├──────────────────────────────────────────────────────────────┤
│ FocusTraversalGroup (导航栏)  │  FocusTraversalGroup (内容)  │  ← 焦点域隔离
│   默认 ReadingOrder          │    FocusGridPolicy / 默认     │
├───────────────────────────────┼──────────────────────────────┤
│ BpmInteractiveWrapper         │  BpmInteractiveWrapper        │  ← 交互包装
│   ├ FocusGlow (焦点辉光)     │   ├ FocusGlow                 │
│   ├ AnimatedScale (缩放)      │   ├ AnimatedScale             │
│   └ GestureDetector (触屏)   │   └ GestureDetector           │
└───────────────────────────────┴──────────────────────────────┘
```

### 4.1 FocusGlow (`focus_glow.dart`)

最底层焦点基础设施：

- **职责**：渲染焦点辉光（边框 + 阴影）+ Enter/Space 激活
- **输入**：`FocusNode`（可外部传入或内部创建）+ `onSelect` 回调
- **状态**：`_isFocused` 监听 FocusNode，触发 `setState` 重建 `AnimatedContainer`
- **键盘处理**：`onKeyEvent` 拦截 `Enter` / `Space`，调用 `onSelect`
- **可访问性**：可选 `Semantics` 包裹（button + label + focused）

### 4.2 BpmInteractiveWrapper (`bpm_interactive_wrapper.dart`)

在 FocusGlow 之上扩展三种输入：

| 状态 | 触发 | 视觉效果 |
|---|---|---|
| 焦点态 | 键盘 Tab/方向键 | 高亮边框 + 1.05x 缩放（focusScale） |
| 悬停态 | 鼠标进入 | 无边框 + 1.02x 缩放（hoverScale） |
| 普通态 | 无 | 无特效 |
| 禁用态 | `onTap == null` | basic 光标，不响应任何输入 |

**优先级**：焦点态 > 悬停态 > 普通态。

**手势分发**：`GestureDetector` 处理 `onTap` / `onDoubleTap` / `onLongPress`，所有回调可选。

### 4.3 FocusGridPolicy (`focus_grid_policy.dart`)

二维网格的方向键导航策略：

```dart
class FocusGridPolicy extends ReadingOrderTraversalPolicy {
  @override
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) {
    final candidates = _collectFocusableNodes(currentNode);  // 同 FocusScope 内
    final currentRect = _globalRect(currentNode);
    // 几何打分: 主轴距离 + 交叉轴偏移 * 0.5
    // 返回最低分候选; 无候选返回 null (不循环)
  }
}
```

**为什么不用线性索引（如 `ReadingOrderTraversalPolicy` 默认行为）？**

- BPM 的 `GridView` 使用 `SliverGridDelegateWithMaxCrossAxisExtent`，列数随窗口宽度动态变化
- 线性索引在换行时会跳到错误位置（如最右列按 `→` 跳到下一行最左列）
- 几何算法基于 `Rect` 中心点距离，无论列数如何变化都正确

**为什么继承 `ReadingOrderTraversalPolicy` 而非 `FocusTraversalPolicy`？**

- 复用 Tab/Shift+Tab 的线性阅读顺序（用于 group 进入时的首个焦点定位）
- 只覆盖 `findFirstFocusInDirection` 实现方向键的二维几何导航
- `FocusTraversalPolicy` 是抽象类，需实现 `inDirection` / `sortDescendants` 等多个抽象方法

**几何打分算法**：

```
方向 up:
  过滤: 候选 center.y < current center.y
  得分 = (current.y - candidate.y) + |candidate.x - current.x| * 0.5
  交叉轴偏移权重 0.5, 优先选主轴最近且交叉轴最近的候选
```

### 4.4 BpmShortcuts (`bpm_shortcuts.dart`)

全局快捷键封装（Shortcuts + Actions）：

| 键 | Intent | 默认行为（Shell 注入） |
|---|---|---|
| F11 | `_ToggleBpmIntent` | `BigPictureManager.instance.toggle()` |
| Escape | `_EscapeIntent` | 详情页→返回；否则 `BigPictureManager.exit()` |
| Ctrl+F | `_FocusSearchIntent` | 聚焦 Library 页搜索框（其他页无操作） |

**Shell 的 `_onEscape` 实现**：

```dart
void _onEscape() {
  if (_showDetailPage) {
    _onDetailBack();  // 详情页 → 返回原页面
  } else {
    BigPictureManager.instance.exit();  // 退出 BPM
  }
}
```

**Tab / Shift+Tab**：不在 BpmShortcuts 内，由 Flutter 默认 `FocusTraversalGroup` 切换行为处理。

---

## 五、启动服务复用

`GameLaunchService.instance` 是从桌面 `LibraryPage` 抽取的共享服务，桌面与 BPM 完全共用：

```
GameLaunchService.instance
├── resolveUserChoice(title) → String?       # 读取已保存 exe 路径
├── persistUserChoice(title, exePath)         # 持久化到 3 处
└── executeLaunch(game, exePath) → LaunchResult
    ├── 1. persistUserChoice
    ├── 2. 读取 game.json: locale_mode / upscaling_mode
    ├── 3. 选择启动方式:
    │     ├── magpie → MagpieService.startGameWithUpscaling (含回退)
    │     └── 其他 → LocalGameRegistry.launchGame
    └── 4. 更新 last_opened_at / first_opened_at / playStatus
```

**LaunchResult**：

```dart
class LaunchResult {
  final bool success;
  final String? error;
  final String localeMode;
  final String upscalingMode;
  
  factory LaunchResult.success({localeMode, upscalingMode});
  factory LaunchResult.failure(String error);
}
```

**不依赖 BuildContext**，所有 UI 反馈由调用方自行决定（BPM 用 `AppSnackBar`，桌面模式用 `AppSnackBar` 或 Dialog）。

---

## 六、测试策略

### 6.1 测试范围决策

**采用**：单元测试 + Widget 测试（不引入 `integration_test`）

**理由**：

1. 项目无桌面集成测试基础设施，引入成本高
2. Windows 桌面集成测试需目标平台执行，CI 复杂度高
3. BPM 核心逻辑（焦点算法 / 状态机 / 数据构造）可独立于 UI 测试
4. 集成场景以**详细手动测试清单**覆盖（见用户手册）

### 6.2 测试文件清单

| 文件 | 类型 | 测试数 | 覆盖范围 |
|---|---|---|---|
| `big_picture_manager_test.dart` | 单元 | 6 | enter/exit/toggle + 幂等 + 监听器通知 |
| `launch_result_test.dart` | 单元 | 5 | LaunchResult.success/failure + 单例 |
| `focus_grid_policy_test.dart` | Widget | 6 | 4 方向 + 边界 null + 换行正确 |
| `widgets/focus_glow_test.dart` | Widget | 5 | 渲染 + autofocus + Enter/Space + 无回调 |
| `widgets/bpm_interactive_wrapper_test.dart` | Widget | 5 | tap + 禁用 + 渲染 + focusScale + longPress |
| `widgets/big_picture_nav_bar_test.dart` | Widget | 3 | 渲染 + 点击 + 退出 |
| **合计** | | **31** | **全部通过** |

### 6.3 关键测试技巧

**1. BigPictureManager 全屏 handler 注入**

避免在测试环境调用 `windowManager.setFullScreen`（会失败）：

```dart
setUp(() {
  BigPictureManager.instance.setFullScreenHandler((_) async {});
});
```

**2. FocusGridPolicy 显式 FocusNode 列表**

不能用 `GlobalKey.currentState` 取 FocusNode（返回 `_FocusState` 类型），需显式传入：

```dart
final nodes = List.generate(6, (_) => FocusNode());
await tester.pumpWidget(
  MaterialApp(home: FocusScope(
    child: FocusTraversalGroup(
      policy: FocusGridPolicy(),
      child: GridView.builder(..., itemBuilder: (_, i) => Focus(focusNode: nodes[i], child: ...)),
    ),
  )),
);
```

**3. AnimatedScale 焦点态验证**

`focusNode.requestFocus()` 后单帧 `pump()` 不足以让 setState 传播到 AnimatedScale 重建，必须用 `pumpAndSettle()`：

```dart
focusNode.requestFocus();
await tester.pumpAndSettle();  // 等待 AnimatedScale 完成动画
expect(scale.scale, 1.5);
```

### 6.4 不测试的部分

| 模块 | 不测试原因 |
|---|---|
| `GameLaunchService.executeLaunch` | 深度依赖 File / SharedPreferences / LocalGameRegistry / MagpieService，完整 mock 成本高，改为依赖类型签名测试 + 手动验收 |
| `BigPictureShell` 集成 | 涉及 BpmShortcuts + FocusTraversalGroup + AnimatedBuilder 嵌套，集成场景以手动测试清单覆盖 |
| `BigPictureDetail` / `BigPictureJoin` | 涉及大量业务服务，组件本身逻辑简单，手动验收 |

---

## 七、性能优化

### 7.1 RepaintBoundary 隔离

每张游戏卡片用 `RepaintBoundary` 包裹，避免相邻卡片焦点动画触发整网格重绘：

```dart
// lib/big_picture/widgets/big_picture_game_card.dart
@override
Widget build(BuildContext context) {
  return RepaintBoundary(  // 隔离卡片重绘
    child: BpmInteractiveWrapper(...),
  );
}
```

### 7.2 模式切换过渡（2026-10-03 起：三段式，非 AnimatedSwitcher）

> ⚠️ **模式切换已不再使用 `AnimatedSwitcher`** —— 旧实现（250ms→420ms 对称 fade+scale）
> 会让桌面与 BPM 两棵全屏树在过渡期同时逐帧重绘，且全屏切换先于切壳下发，
> 观感「先抖一下再硬切」。现方案见 `features/bpm_mode_transition.md`。
> 第二段「手柄图标描出」（`lib/big_picture/widgets/bpm_enter_overlay.dart`：
> 两个光点自顶部中央**同点出发**，顺时针 / 逆时针各沿轮廓走一半弧长，在底平台汇合）
> **兼作大屏的加载指示**，与窗口全屏就绪闸门并行。轮廓 24 个锚点是对 Steam 参考
> 截图逐行扫描量出来的（宽高比 1.364、顶边占 74% 宽、最宽点在 y≈71%）。
> 这 540ms 内部再分两段：**描出 0.03→0.78** + **收尾柔光 0.78→1.00（≈119ms）**
> —— 轮廓合拢后整条边框**向外**发一次柔光、先快后慢散掉（填充路径 + `BlurStyle.outer`，
> 柔光色按明暗分支：浅色下不能复用描边色，否则"发光"会变成"发黑"）。
> 前移描出终点腾出这个窗口，**总时长不变**。

```dart
// lib/main_container.dart —— 结构恒定的根 Stack
Stack(
  fit: StackFit.expand,
  children: [
    if (showDesktop) _buildDesktopShell() else const SizedBox.shrink(), // 槽位 0 恒在
    if (isActive)
      AnimatedBuilder(
        animation: Listenable.merge([_bpmEnter, _bpmLogo]),
        child: _buildBpmShell(),                    // 只在模式翻转时构造一次
        builder: (context, child) => _buildBpmTransition(child!),
      ),
  ],
);
```

`_buildBpmTransition` 内部同样是**槽位恒定**的 Stack：槽位 0 = BPM 外壳
（恒存的 `Offstage` + `Transform.scale`），槽位 1 = 幕布、槽位 2 = 手柄图标
（两者都是可增删的**尾随**槽位，删掉不会让外壳换位而重建）。

BPM 外壳自身页面切换仍用 `AnimatedSwitcher`（`lib/big_picture/big_picture_shell.dart`，200ms fade）：

```dart
AnimatedSwitcher(
  duration: const Duration(milliseconds: 200),
  child: KeyedSubtree(key: pageKey, child: _buildPageContent()),
);
```

### 7.3 焦点辉光 AnimatedContainer

`FocusGlow` 用 `AnimatedContainer`（200ms）而非 `setState` 直接重建，避免焦点切换时的视觉跳变。

---

## 八、扩展指南

### 8.1 添加新页面

1. 在 `lib/big_picture/pages/` 新建 `big_picture_xxx.dart`
2. 在 `NavPage` 枚举（`lib/widgets/sidebar.dart`）添加新值
3. 在 `BigPictureNavBar._navIcon` / `_navLabel` 添加对应图标和标签
4. 在 `BigPictureShell._buildPageContent` switch 添加新页面分支
5. **必填**：将新页面加入 `BigPictureNavBar` 的显式顺序列表 `[NavPage.home, NavPage.library, NavPage.discover, NavPage.join]`，**不要使用 `NavPage.values.map`**。原因：`NavPage` 枚举定义顺序（library, discover, join, home）与 BPM 期望顺序不符，v1.1 已统一改为显式列表
6. **可选**：若新页面有搜索框，参考 LibraryPage 实现 `searchFocusNode` 注入

### 8.2 添加新快捷键

在 `lib/big_picture/focus/bpm_shortcuts.dart` 添加：

```dart
// 1. 新增 Intent
class _MyNewIntent extends Intent { const _MyNewIntent(); }

// 2. 添加到 _shortcuts
static const _shortcuts = {
  ...
  SingleActivator(LogicalKeyboardKey.keyP, control: true): _MyNewIntent(),
};

// 3. 添加 Action
actions: {
  ...
  _MyNewIntent: CallbackAction<_MyNewIntent>(
    onInvoke: (_) => onMyNewAction?.call(),
  ),
},

// 4. 暴露回调
final VoidCallback? onMyNewAction;
```

在 `BigPictureShell` 注入对应回调。

### 8.3 修改焦点导航策略

若要支持手柄输入或循环导航，修改 `lib/big_picture/focus/focus_grid_policy.dart`：

- **循环**：`findFirstFocusInDirection` 返回 null 时改为返回最远端节点
- **手柄**：在 `BpmShortcuts` 中添加 `LogicalKeyboardKey.gameButtonA` 等映射到 `_ActivateIntent`
- **加权**：调整 `_scoreCandidate` 中的 `0.5` 权重改变主轴/交叉轴优先级

### 8.4 主题适配

BPM 不引入独立主题色板，所有颜色走 `AppColors` 静态门面。新增颜色时：

1. 在 `lib/theme/app_colors.dart` 添加 `static Color get myColor => ...`
2. BPM 内直接使用 `AppColors.myColor`，主题切换时自动更新

---

## 九、已知限制

| 限制 | 影响 | 缓解方案 |
|---|---|---|
| 不支持游戏手柄输入 | 串流到 Steam Link 等设备时需键鼠 | 后续版本接入 `RawKeyboardListener` 监听 gamepad |
| 探索页下载流程需切回桌面 | BPM 无 `InstallCenterPage` 大屏版 | 后续 Phase 6 添加 BPM 下载进度条 |
| 主题切换需退出 BPM | BPM 内无设置入口 | 后续在 NavBar 添加设置按钮 |
| BPM 不持久化 | 每次启动默认桌面模式 | 设计决策，符合用户预期 |
| 焦点辉光颜色固定 | 不能为不同主题定制辉光色 | 当前用 `AppColors.selectedAccent`，已随主题变化 |

---

## 十、参考文档

- 总设计方案：`.trae/documents/big_picture_mode_implementation_plan.md`
- Phase 3-5 完成计划：`.trae/documents/bpm_phase3_to_5_completion_plan.md`
- v1.1 优化重构计划：`.trae/documents/bpm_optimization_refactor_plan.md`（入口迁移 / NavBar 顺序 / 首页双栏 / 探索页修复 / 添加页元数据板块）
- v1.1 最终收尾计划：`.trae/documents/bpm_finalization_plan.md`（tag_translator 修复 + 文档同步）
- v1.2 UI 全面优化计划：`.trae/documents/bpm_ui_optimization_plan.md`（30+ 问题清单与 6 批次实施方案）
- v1.2 收尾执行计划：`.trae/documents/bpm_ui_optimization_v1.2_completion_plan.md`（批次 4 收尾 + 批次 5 详情页修复 + 批次 6 验证）
- 用户手册：`docs/big_picture_mode.md`
- 实施报告：见总设计方案末尾「实施报告」章节
