# Chrono Tide UI/UX 全面升级方案

> **版本**: v1.1  
> **日期**: 2026-07-01  
> **适用范围**: Chrono Tide v1.3.1 全部UI/UX模块  
> **审查覆盖**: 5个核心页面、13个对话框/模态窗口、9个核心组件、3个主题系统文件、2个认证页面  
> **v1.1 更新**: 整合实际使用体验反馈，新增滚动流畅性、拖拽交互逻辑、微交互细节三大问题域

---

## 一、执行摘要

Chrono Tide 作为一款 GAL 游戏管理工具，在视觉风格上形成了独特的复古拟物化设计语言（硬阴影、手写字体、暖棕色调），并在交互细节（hover浮起、按下缩回、卡片抬升）上做到了较高的一致性。然而，本次审查发现了**8个必须修复的功能性漏洞**和**36个建议优化的体验问题**，涵盖主题系统断裂、滚动性能瓶颈、拖拽交互缺陷、响应式缺失、可访问性空白、表单体验薄弱六大领域。

> **v1.1 重大更新**：基于实际使用体验反馈，新增三大问题域——游戏列表滚动卡顿（同步I/O阻塞主线程）、卡片拖拽交互逻辑缺陷（强制交换无取消机制）、微交互/动画过渡细节优化，其中2项升级为P0级必须修复。

### 核心发现速览

| 领域 | 必须修复 | 建议优化 | 总计 |
|------|---------|---------|------|
| 主题/视觉系统 | 4 | 8 | 12 |
| 页面交互流程 | 1 | 9 | 10 |
| 列表滚动与拖拽交互 | 2 | 2 | 4 |
| 对话框/模态窗口 | 0 | 7 | 7 |
| 组件/控件 | 1 | 5 | 6 |
| 微交互与动画细节 | 0 | 5 | 5 |
| 可访问性 | 0 | 4 | 4 |
| **合计** | **8** | **40** | **48** |

---

## 二、问题全量清单与分类

### 2.1 必须修复的功能性漏洞 (P0)

#### BUG-01: ColorScheme 与自定义主题完全断裂
- **严重度**: 🔴 P0 - 功能缺陷
- **文件**: [main.dart](file:///d:/CTLIB/lib/main.dart)
- **现象**: `_buildThemeData()` 中 `ColorScheme.fromSeed(seedColor: 0xFF8B7355)` 在所有主题中硬编码不变。切换到樱花/蓝天主题时，Material组件（Switch、Slider、Chip、Tab、Dialog、SnackBar）仍显示暖棕色调，与主题意图严重冲突
- **影响范围**: 全局所有使用Material组件的界面
- **修复方案**: 在 `_buildThemeData()` 中根据当前 `CTTheme` 动态生成 `ColorScheme`，将 `CTThemeData` 的语义色映射到 MD3 标准令牌

#### BUG-02: 字体族三元矛盾
- **严重度**: 🔴 P0 - 设计系统缺陷
- **文件**: [main.dart](file:///d:/CTLIB/lib/main.dart), [app_styles.dart](file:///d:/CTLIB/lib/theme/app_styles.dart)
- **现象**: 三层字体定义互相冲突：`ThemeData.fontFamily = 'Inter'`，`AppStyles` 定义了 `ZhiMangXing`/`Mali`，实际UI中大量硬编码 `fontFamily: 'Inter'`。装饰字体（书法体/手写体）被用于功能性文字（输入提示、导航激活态），严重影响可读性
- **影响范围**: 全局
- **修复方案**: 确立统一字体策略——`Inter` 作为UI正文字体，`ZhiMangXing`/`Mali` 仅限装饰性大标题使用，清理所有硬编码 `fontFamily`

#### BUG-03: 强制禁用文本缩放
- **严重度**: 🔴 P0 - 无障碍违规
- **文件**: [main.dart](file:///d:/CTLIB/lib/main.dart)
- **现象**: `TextScaler.linear(1.0)` 硬编码，完全剥夺用户使用系统文字缩放的能力，违反 WCAG 1.4.4 Resize Text 标准
- **修复方案**: 移除硬编码，允许系统缩放；如需限制，设置合理的最大缩放比例（如1.5x）

#### BUG-04: 主题切换无过渡动画
- **严重度**: 🔴 P0 - 体验缺陷
- **文件**: [app_theme_manager.dart](file:///d:/CTLIB/lib/theme/app_theme_manager.dart)
- **现象**: `setTheme()` 调用 `notifyListeners()` 后直接重建整个widget树，无渐变过渡，用户看到突兀的闪烁切换
- **修复方案**: 使用 `AnimatedTheme` 或自定义过渡组件，实现200-300ms的淡入淡出切换

#### BUG-05: 侧边栏收起模式硬编码颜色不随主题变化
- **严重度**: 🔴 P0 - 功能缺陷
- **文件**: [sidebar.dart](file:///d:/CTLIB/lib/widgets/sidebar.dart)
- **现象**: 收起模式下导航项使用了 `Color(0xFFFFFFFF)`、`Color(0xFFA07840)`、`Color(0xFFC8B49A)` 等硬编码颜色，切换到暗夜/樱花等主题时样式不会跟随变化
- **修复方案**: 将所有硬编码颜色替换为 `AppColors` 主题变量

#### BUG-06: DownloadButton/FloatingTaskButton 硬编码颜色不随主题变化
- **严重度**: 🔴 P0 - 功能缺陷
- **文件**: [download_button.dart](file:///d:/CTLIB/lib/widgets/download_button.dart), [floating_task_button.dart](file:///d:/CTLIB/lib/widgets/floating_task_button.dart)
- **现象**: 按钮变体颜色（蓝色系/红色系/棕色系）全部硬编码，未引用 `AppColors` 主题系统，主题切换后按钮样式不跟随变化
- **修复方案**: 在 `CTThemeData` 中增加按钮语义色令牌，替换所有硬编码颜色

#### BUG-07: 拖拽事件丢失——指针离开卡片区域后拖拽卡死
- **严重度**: 🔴 P0 - 功能缺陷（用户实际体验反馈）
- **文件**: [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart) (L2298-2303, L1593-1596)
- **根因**: 拖拽事件完全依赖每个 `_LibraryCardWidget` 内嵌的 `Listener` 接收 `onPointerMove` 和 `onPointerUp`。但拖拽开始后原始卡片被替换为 `_BuildGhostCard`（无 Listener），浮动 overlay 被 `IgnorePointer` 包裹（不接收事件）。当指针移动到卡片间距区域、ghost 卡片区域或 GridView 边界外时，`_updateDrag` 和 `_endDrag` 都不会被调用
- **现象**: 用户拖拽卡片后，鼠标移动到卡片间空白区域或列表边缘，拖拽"卡住"——松开鼠标无响应，卡片停留在半空，无法完成也无法取消操作
- **修复方案**: 在页面级别添加全局指针监听，拖拽期间捕获所有指针事件
```dart
// _LibraryPageState.build() 最外层 Stack 包裹 Listener
Listener(
  onPointerMove: _isDragging ? (e) => _updateDrag(e.position) : null,
  onPointerUp: _isDragging ? (e) => _endDrag() : null,
  child: Container(/* 现有代码 */),
)
```
- **验收标准**: 拖拽过程中指针移至任意位置均可正常追踪，松开鼠标时正确结束或取消拖拽

#### BUG-08: 拖拽结束强制执行交换——无法取消/撤回
- **严重度**: 🔴 P0 - 交互逻辑缺陷（用户实际体验反馈）
- **文件**: [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart) (L1058-1113)
- **根因**: `_endDrag()` 中，一旦 `_hoverIndex` 有效（非 -1 且非原位），交换立即执行并持久化到磁盘，无确认步骤、无撤销机制。ESC 键取消虽已实现（L505-513），但用户不可发现（无 UI 提示），且仅支持键盘用户
- **现象**: 用户意外触发拖拽后，想将卡片放回原位，但只要鼠标滑到了另一张卡片上松手就会强制完成交换。现有 ESC 键取消方案操作复杂度高，鼠标/触屏用户无法通过直观手势取消
- **用户期望**: "拖拽放回原位自动取消操作"——将卡片拖回其原始位置时，应视为取消而非交换
- **修复方案**: 综合实施以下三项改进：
  1. **拖回原位自动取消**：`_endDrag()` 检测 `_hoverIndex == _originalIndex` 时执行 `_cancelDrag()` 而非空操作
  2. **目标停留确认**：仅当指针在目标卡片上停留 ≥200ms 后才确认交换，快速滑过视为取消
  3. **可见的取消区域**：在列表边缘显示"拖至此处取消"的视觉提示区，或拖至原位时显示取消指示
- **验收标准**: 意外拖拽可通过放回原位/拖至取消区/快速划过目标三种方式取消；交换操作需用户明确意图（停留确认）

---

### 2.2 建议优化的体验问题 (P1 - 高优先级)

#### UX-01: 间距令牌系统完全缺失
- **文件**: 全局
- **现象**: 无 `AppSpacing`/`AppPadding` 定义，代码中充斥 `SizedBox(height: 6/12/14/16)` 等魔法数字，间距值（4/6/10/12/14/16）无规律，不符合4px/8px基线网格
- **建议**: 定义 `AppSpacing`（4/8/12/16/24/32/48），逐步替换魔法数字

#### UX-02: 字体排版层级严重不足
- **文件**: [app_styles.dart](file:///d:/CTLIB/lib/theme/app_styles.dart)
- **现象**: 仅8个样式令牌，实际代码中大量内联 `TextStyle(fontFamily: 'Inter', fontSize: 14/15/13...)` 硬编码，完全绕过样式系统
- **建议**: 补全至少15个MD3标准层级，将内联样式迁移到 `AppStyles`

#### UX-03: 弹窗无进场/退场动画
- **文件**: [main_container.dart](file:///d:/CTLIB/lib/main_container.dart)
- **现象**: `OverlayEntry` 直接插入/移除，无淡入淡出、缩放等过渡效果，体验生硬
- **建议**: 实现统一的 `AnimatedOverlayEntry` 组件，添加200-300ms的淡入+缩放动画

#### UX-04: 密码输入框缺少显示/隐藏切换
- **文件**: [login_page.dart](file:///d:/CTLIB/lib/pages/login/login_page.dart), [register_page.dart](file:///d:/CTLIB/lib/pages/register/register_page.dart), [auth_modal.dart](file:///d:/CTLIB/lib/widgets/auth_modal.dart)
- **现象**: 所有密码输入均无可见性切换按钮，用户无法确认输入是否正确
- **建议**: 添加密码可见性切换图标按钮（eye/eye_off）

#### UX-05: 表单缺少实时验证反馈
- **文件**: [join_page.dart](file:///d:/CTLIB/lib/pages/join_page.dart), [auth_modal.dart](file:///d:/CTLIB/lib/widgets/auth_modal.dart)
- **现象**: 所有表单均为提交时验证，没有字段级的即时反馈（如输入框变红、实时错误提示）
- **建议**: 实现字段级验证，输入时即时显示错误/成功状态

#### UX-06: 危险操作缺少二次确认
- **文件**: [batch_import_section.dart](file:///d:/CTLIB/lib/pages/join/widgets/batch_import_section.dart), [smart_import_section.dart](file:///d:/CTLIB/lib/pages/join/widgets/smart_import_section.dart), [action_buttons.dart](file:///d:/CTLIB/lib/pages/join/widgets/action_buttons.dart)
- **现象**: 清除选择、删除游戏、清空批量列表、删除监控路径、取消操作等危险操作均无确认对话框
- **建议**: 为所有不可逆操作添加确认对话框

#### UX-07: 响应式布局完全缺失
- **文件**: 全局
- **现象**: 所有页面使用固定宽度/高度，无断点系统。GameDetailPage 左侧固定460px，InstallCenterPage 固定900x580，在窄窗口下内容溢出或不可用
- **建议**: 定义断点系统（compact <960 / medium 960-1280 / expanded >1280），关键页面添加响应式布局

#### UX-08: 侧边栏切换位置跳跃
- **文件**: [main_container.dart](file:///d:/CTLIB/lib/main_container.dart)
- **现象**: `SidebarToggleWidget` 的 `left` 值随折叠状态瞬时变化，导致按钮突然跳跃
- **建议**: 将 `sidebarWidth` 改为 `AnimatedContainer` 驱动，或使用 `AnimatedPositioned`

#### UX-09: SnackBar 未适配主题
- **文件**: [main_container.dart](file:///d:/CTLIB/lib/main_container.dart)
- **现象**: `ScaffoldMessenger.of(context).showSnackBar` 使用 Material 默认样式，暗色主题下可能显示浅色SnackBar
- **建议**: 自定义 SnackBar 主题或封装统一的提示方法

#### UX-34: 游戏列表滚动卡顿——同步 I/O 阻塞主线程（用户实际体验反馈）
- **严重度**: 🟠 P1 - 性能瓶颈
- **文件**: [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart) (L2087-2100, L2498-2509), [home_page.dart](file:///d:/CTLIB/lib/pages/home_page.dart) (L376, L1192), [discover_page.dart](file:///d:/CTLIB/lib/pages/discover_page.dart) (L1253), [game_data_format.dart](file:///d:/CTLIB/lib/services/game_data_format.dart) (L569-608)
- **根因分析**（按影响程度排序）：
  1. **build/initState 中同步文件 I/O**：`_LibraryCardWidgetState._resolveCover()` 在 `initState` 中执行 `File(game.coverUrl).existsSync()`；`_BuildGhostCard._buildCoverImage()` 在 build 方法中直接调用 `existsSync()`；`game_data_format.findCoverFile()` 形成多层同步 I/O 调用链（`existsSync()` → `readAsStringSync()` → `listSync()`）。快速滚动时大量卡片进入视口，每个卡片的 initState 都触发同步 I/O，直接阻塞主线程
  2. **`_filteredAndSortedGames` 每次 build 重复计算**：getter 每次访问执行 `List.from(_games)` + 过滤 + 排序 O(n) + O(n log n)，拖拽期间频繁 setState 导致反复执行
  3. **`_onRegistryChanged` 频繁触发全量 rebuild**：游玩时长追踪等周期性通知导致整个 LibraryPage 完全 rebuild
  4. **缺少 `cacheExtent` 优化**：DiscoverPage 和 HomePage 未设置 cacheExtent，快速滚动时卡片来不及预加载
  5. **缺少 `RepaintBoundary`**：任一卡片 hover 动画变化可能导致整个 GridView/ListView 区域重绘
- **现象**: 使用鼠标中键/滚轮滚动游戏列表时出现明显卡顿，滚动不跟手，动画过渡效果不符合预期
- **建议方案**:
  - 封面路径异步预缓存：在父组件中批量异步解析封面路径，卡片接收预缓存结果
  - 将 `_filteredAndSortedGames` getter 改为缓存字段，仅在筛选条件变化时重算
  - 区分注册表通知类型，仅在数据影响 UI 时 rebuild
  - 设置 `cacheExtent: 800`（DiscoverPage/HomePage），增加预缓存区域
  - 为每个卡片包裹 `RepaintBoundary` 隔离重绘范围

---

### 2.3 建议优化的体验问题 (P2 - 中优先级)

#### UX-10: 无障碍对比度不达标
- **现象**: `placeholderText` 在暗夜主题中对比度仅2.8:1，`secondaryText` 在暮光主题约4.1:1，均低于WCAG AA要求（4.5:1）。ExtractStatus 中0.57透明度文本对比度严重不足
- **建议**: 调整暗色主题的关键文字颜色，确保对比度≥4.5:1

#### UX-11: 进度条无过渡动画
- **文件**: [download_progress_bar.dart](file:///d:/CTLIB/lib/widgets/download_progress_bar.dart)
- **现象**: `FractionallySizedBox` 的 `widthFactor` 变化时无动画包裹，进度跳跃式更新造成视觉闪烁
- **建议**: 使用 `AnimatedFractionallySizedBox` 或 `TweenAnimationBuilder` 实现平滑过渡

#### UX-12: DiscoverPage 存在死代码和重复代码
- **文件**: [discover_page.dart](file:///d:/CTLIB/lib/pages/discover_page.dart)
- **现象**: `_buildGameCard` 方法（约90行）未被使用；封面图片加载逻辑在 `_DiscoverPageState` 和 `_DiscoverCardWidgetState` 中完全重复
- **建议**: 删除死代码，抽取共享的封面图片组件

#### UX-13: LibraryPage 文件过于庞大
- **文件**: [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart)
- **现象**: 3700+行单文件，包含10+私有Widget类，维护困难
- **建议**: 拆分为卡片组件、拖拽管理器、编辑模式组件、管理面板等独立文件

#### UX-14: 首页筛选与选中状态不一致
- **文件**: [home_page.dart](file:///d:/CTLIB/lib/pages/home_page.dart)
- **现象**: `_selectedGame` 基于 `_recentGames`（未过滤列表），但筛选操作作用于 `_filteredGames`，筛选激活时左侧详情展示的游戏可能不在右侧列表中
- **建议**: 选中状态应与筛选结果联动

#### UX-15: GameDetailPage 使用 Image.network 而非 CachedNetworkImage
- **文件**: [game_detail_page.dart](file:///d:/CTLIB/lib/pages/game_detail_page.dart)
- **现象**: 与 DiscoverPage 不一致，没有磁盘缓存，每次进入详情页都重新下载封面图
- **建议**: 统一使用 `CachedNetworkImage`

#### UX-16: 拖拽排序交互体验优化（含用户实际体验反馈）
- **文件**: [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart)
- **现象**: 
  - 交换/插入的区分依赖卡片内水平位置（15%/85%），无视觉提示；插入需要300ms停留也不直观
  - 拖拽过程中非 ghost 卡片的 `onPointerDown` 仍会设置 `_longPressTimer`，可能干扰当前拖拽状态（L1656-1664）
  - `_cancelDrag()` 的 `_liftAnimation.reverse().then(...)` 是异步的，在 reverse 动画期间再次触发 `_startDrag` 可能出现状态竞态
  - ESC 键取消功能已实现但不可发现——没有任何 UI 提示告知用户可按 ESC 取消
- **建议**: 
  - 添加拖拽模式提示（光标变化、插入位置指示线）
  - 拖拽期间禁用非 ghost 卡片的 `_longPressTimer`（`_isDragging` 时 onPointerDown 返回 null）
  - `_startDrag` 开头强制清理上一次未完成的 cancel 动画
  - 拖拽开始时显示轻量提示（如底部 Toast "拖回原位取消 · ESC 退出"）

#### UX-17: 登录/注册缺少"忘记密码"入口
- **文件**: [auth_modal.dart](file:///d:/CTLIB/lib/widgets/auth_modal.dart)
- **现象**: 无密码找回流程，用户忘记密码后无法自助恢复
- **建议**: 添加"忘记密码"链接，引导用户通过邮箱重置

#### UX-18: 首页/库页缺少加载状态
- **文件**: [home_page.dart](file:///d:/CTLIB/lib/pages/home_page.dart), [library_page.dart](file:///d:/CTLIB/lib/pages/library_page.dart)
- **现象**: `_refreshFromDisk()` 期间无任何视觉反馈，磁盘扫描较慢时用户看到空白
- **建议**: 添加加载指示器或骨架屏

#### UX-19: 右键菜单无边界检测
- **文件**: [library_context_menu.dart](file:///d:/CTLIB/lib/widgets/library_context_menu.dart)
- **现象**: 菜单使用绝对定位，没有边界检测，可能超出屏幕右侧或底部
- **建议**: 计算菜单位置时考虑屏幕边界，自动调整方向

#### UX-20: 元数据平台标签缺少图例
- **文件**: [metadata_section.dart](file:///d:/CTLIB/lib/pages/join/widgets/metadata_section.dart)
- **现象**: Bangumi红/VNDB蓝/Steam深色/Ymgal绿的颜色区分没有图例说明，新用户不理解含义
- **建议**: 添加平台图例或Tooltip说明

#### UX-21: 搜索框标签语法无提示
- **文件**: [discover_page.dart](file:///d:/CTLIB/lib/pages/discover_page.dart)
- **现象**: 搜索框输入的第二个词会被当作标签关键词，但UI上没有提示用户这个语法
- **建议**: 在搜索框hint或帮助图标中说明搜索语法

#### UX-22: _formatLastPlayed 逻辑缺陷
- **文件**: [home_page.dart](file:///d:/CTLIB/lib/pages/home_page.dart)
- **现象**: `diff.inDays == 0` 判断在先，`diff.inMinutes < 1` 永远不会执行，当天内"刚刚"永远不会显示
- **建议**: 调整判断顺序，先检查分钟再检查天

#### UX-23: 首页 _loadLaunchModes 不触发UI重建
- **文件**: [home_page.dart](file:///d:/CTLIB/lib/pages/home_page.dart)
- **现象**: 异步加载locale/upscaling模式完成后没有 `setState`，用户看不到模式更新
- **建议**: 加载完成后调用 `setState`

#### UX-24: 标签展开面板无最大高度限制
- **文件**: [discover_page.dart](file:///d:/CTLIB/lib/pages/discover_page.dart)
- **现象**: 标签特别多时展开面板可能撑满整个页面
- **建议**: 设置最大高度并允许滚动

---

### 2.4 建议优化的体验问题 (P3 - 低优先级)

#### UX-35: 微交互与动画过渡细节优化（用户实际体验反馈）
- **现象**: 多处微交互不符合用户预期，影响操作感知的连贯性和舒适度
- **具体问题清单**:
  - **进度条跳跃式更新**：`DownloadProgressBar` 的 `FractionallySizedBox.widthFactor` 变化无动画包裹，进度值跳跃导致视觉闪烁（同 UX-11，此处归类为微交互范畴）
  - **封面图片加载无淡入**：图片从占位符直接切换为实际图片，无交叉淡入过渡，视觉跳跃明显
  - **标签芯片选中/取消无弹性动画**：点击标签时状态切换为瞬时替换，缺少微妙的缩放回弹效果
  - **卡片 hover 状态切换生硬**：虽然 `InteractiveWrapper` 提供了 hover 浮起效果，但阴影变化是线性的，缺少缓动曲线带来的自然感
  - **列表项增删无动画**：游戏入库/删除后列表立即重排，无 `AnimatedList` 式的插入/移除过渡
- **建议**: 
  - 为图片加载添加 `FadeInImage` 或 `AnimatedSwitcher` 交叉淡入
  - 标签芯片选中添加 150ms 弹性缩放动画（scale 1.0 → 0.92 → 1.05 → 1.0）
  - 卡片阴影变化添加 `Curves.easeOutCubic` 缓动
  - 列表增删使用 `AnimatedList` 或 `SliverAnimatedList`

#### UX-36: 窗口控制按钮缺少按压反馈
- **文件**: [custom_title_bar.dart](file:///d:/CTLIB/lib/widgets/custom_title_bar.dart)
- **现象**: 窗口按钮（最小化/最大化/关闭）缺少点击/按下态视觉反馈，只有 hover 态，触感不够明确
- **建议**: 添加 `_isPressed` 状态，按下时略微缩小或颜色加深

#### UX-37: 截图轮播箭头按钮无 hover 效果
- **文件**: [screenshot_carousel.dart](file:///d:/CTLIB/lib/widgets/screenshot_carousel.dart)
- **现象**: 箭头按钮在桌面端无 hover 反馈，用户无法感知可点击区域
- **建议**: 为箭头添加 `InteractiveWrapper` 或简单的背景色 hover 变化

#### UX-38: 登录/注册输入框无焦点高亮
- **文件**: [login_page.dart](file:///d:/CTLIB/lib/pages/login/login_page.dart), [register_page.dart](file:///d:/CTLIB/lib/pages/register/register_page.dart)
- **现象**: 输入框获得焦点时无视觉变化，用户无法判断当前活跃字段
- **建议**: 焦点时边框颜色变为主题强调色

#### UX-39: 批量入库进度信息不透明
- **文件**: [batch_import_controller.dart](file:///d:/CTLIB/lib/pages/join/batch_import_controller.dart)
- **现象**: `importSingleGame` 失败时只 `debugPrint` 不向用户展示具体失败原因，用户无法知道哪些游戏入库失败及原因
- **建议**: 收集每条失败记录，完成后显示失败详情列表

#### UX-25: 可访问性全面缺失
- **现象**: 全部组件缺少 `Semantics` 标注；无键盘焦点指示器；无 Tooltip；无屏幕阅读器支持
- **建议**: 分阶段添加——先覆盖导航项和关键操作按钮，再逐步扩展

#### UX-26: 功能重叠的对话框
- **文件**: [exe_selector_dialog.dart](file:///d:/CTLIB/lib/widgets/exe_selector_dialog.dart), [launch_manager_dialog.dart](file:///d:/CTLIB/lib/widgets/launch_manager_dialog.dart)
- **现象**: 两个组件功能高度重叠（exe扫描+选择+转区/超分开关），代码独立实现
- **建议**: 统一为一个组件，通过参数控制功能范围

#### UX-27: 设置模态框"自定义背景"功能未实现
- **文件**: [settings_modal.dart](file:///d:/CTLIB/lib/widgets/settings_modal.dart)
- **现象**: "即将推出"标签的按钮可点击但无响应，可能造成用户困惑
- **建议**: 禁用按钮或移除入口，等实现后再开放

#### UX-28: 支付模态框二维码为静态图片
- **文件**: [payment_modal.dart](file:///d:/CTLIB/lib/widgets/payment_modal.dart)
- **现象**: 所有金额共用一个赞赏码，用户需手动输入金额
- **建议**: 后端支持动态二维码或至少在UI上明确说明

#### UX-29: 退出遮罩双重旋转效果
- **文件**: [exit_overlay.dart](file:///d:/CTLIB/lib/widgets/exit_overlay.dart)
- **现象**: `CircularProgressIndicator` 在自转的同时容器也在旋转，视觉上令人困惑
- **建议**: 移除容器的旋转动画，仅保留进度指示器自转

#### UX-30: 注册页 `_isFormValid` 未被使用
- **文件**: [register_page.dart](file:///d:/CTLIB/lib/pages/register/register_page.dart)
- **现象**: 计算属性存在但按钮没有利用，注册按钮始终可点击
- **建议**: 利用 `_isFormValid` 控制按钮disabled状态

#### UX-31: 昵称验证条件冗余
- **文件**: [settings_modal.dart](file:///d:/CTLIB/lib/widgets/settings_modal.dart)
- **现象**: `nickname.length < 1` 永远不会触发（前面已判断 `isEmpty`）
- **建议**: 移除冗余条件

#### UX-32: 保存按钮颜色条件两分支相同
- **文件**: [settings_modal.dart](file:///d:/CTLIB/lib/widgets/settings_modal.dart)
- **现象**: `_isSaving ? AppColors.selectedAccent : AppColors.selectedAccent` 两个分支颜色相同，无视觉区分
- **建议**: 为加载中状态使用不同颜色或添加加载指示器

#### UX-33: 窗口背景色硬编码
- **文件**: [main.dart](file:///d:/CTLIB/lib/main.dart)
- **现象**: 窗口背景色 `0xFFFDFBF7` 仅适配暖阳主题，切换暗夜主题时初始化阶段出现白色闪烁
- **建议**: 根据当前主题动态设置窗口背景色

---

## 三、对比分析：与行业最佳实践的差距

### 3.1 与同类产品对比

| 维度 | Steam | Playnite | Chrono Tide 当前 | 差距评估 |
|------|-------|----------|----------------|---------|
| 主题系统 | 1套深色主题 | 多主题+自定义CSS | 6套预设主题 | ✅ 主题数量优势 |
| 主题切换体验 | N/A | 即时切换 | 无过渡闪烁 | ❌ 缺少过渡动画 |
| 响应式布局 | 自适应窗口 | 支持多种布局 | 固定布局 | ❌ 完全缺失 |
| 搜索体验 | 实时搜索+建议 | 基础搜索 | 防抖搜索 | ⚠️ 缺少建议/补全 |
| 表单验证 | 实时验证 | 基础验证 | 提交时验证 | ❌ 体验落后 |
| 无障碍 | 基础支持 | 基础支持 | 完全缺失 | ❌ 严重落后 |
| 键盘导航 | 完整支持 | 部分支持 | 完全缺失 | ❌ 严重落后 |
| 拖拽排序 | 支持 | 支持 | 支持但可发现性差 | ⚠️ 需优化 |
| 游戏详情 | 富媒体展示 | 标签页布局 | 左右分栏 | ✅ 布局合理 |
| 截图展示 | 全屏轮播 | 内嵌展示 | 轮播组件 | ✅ 实现良好 |
| 批量操作 | 多选+批量 | 多选+批量 | 编辑模式+批量 | ✅ 实现良好 |
| 安装流程 | 向导式 | 简单解压 | 确认→下载→解压 | ✅ 流程完整 |

### 3.2 与 Material Design 3 规范对比

| MD3 规范要求 | 当前状态 | 差距等级 |
|-------------|---------|---------|
| 完整 ColorScheme（30+令牌） | 自定义~30个非标准令牌 + 固定种子色 | 🔴 严重脱节 |
| 字体排版层级（15个样式） | 仅8个样式令牌 | 🔴 严重不足 |
| 状态层（State Layer） | 无 | 🔴 完全缺失 |
| 间距4dp基线网格 | 魔法数字 | 🔴 完全缺失 |
| 主题过渡动画 | 无 | 🔴 完全缺失 |
| 组件令牌（Component Tokens） | 无 | 🟡 完全缺失 |
| 文本缩放支持 | 强制1.0x | 🔴 违反规范 |
| 对比度AA级（4.5:1） | 多处不达标 | 🟡 部分不达标 |
| 语义标注（Semantics） | 无 | 🔴 完全缺失 |

### 3.3 项目独特优势

1. **独特的视觉语言**: 硬阴影（Offset(2,3), blurRadius:0）+ 手写字体 + 暖棕色调，形成高度辨识度的复古拟物风格
2. **6套精心设计的主题**: 暖阳/暗夜/墨绿金/樱花/蓝天/暮光，3套支持背景图片
3. **交互包装器模式**: `InteractiveWrapper` 统一了全应用"hover浮起+press按下"的一致手感
4. **字段锁定机制**: 独创的元数据锁定功能，在多次抓取时保留已确认数据，是优秀的UX创新
5. **三级截图优先级**: PB数据→本地文件→API抓取，工程优化到位
6. **批量导入智能识别**: GAL特征检测引擎+自动元数据抓取，流程设计完善

---

## 四、优化建议与实施方案

### 4.1 P0 修复方案（必须修复 - 预计2-3天）

#### 方案1: 修复 ColorScheme 与自定义主题联动

**实施步骤**:
1. 在 `CTThemeData` 中增加 `seedColor` 字段，每个主题定义自己的种子色
2. 修改 `_buildThemeData()` 方法，根据当前 `CTTheme` 动态生成 `ColorScheme`
3. 将 `CTThemeData` 的关键语义色映射到 `ColorScheme` 标准令牌

```dart
// app_theme_manager.dart - 为每个主题增加seedColor
CTTheme.warmSun: CTThemeData(
  seedColor: Color(0xFF8B7355), // 暖棕
  ...
),
CTTheme.sakura: CTThemeData(
  seedColor: Color(0xFFD4849A), // 樱花粉
  ...
),

// main.dart - 动态生成ColorScheme
ThemeData _buildThemeData() {
  final themeData = AppThemeManager.colors;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: themeData.seedColor,
    brightness: themeData.brightness,
  );
  // 覆盖关键令牌
  return ThemeData(
    colorScheme: colorScheme.copyWith(
      primary: themeData.selectedAccent,
      surface: themeData.background,
      onSurface: themeData.primaryText,
      // ... 更多映射
    ),
    ...
  );
}
```

**验收标准**: 切换任意主题后，Material组件（Switch/Slider/Chip/Tab/Dialog）颜色与主题一致

#### 方案2: 修复字体族矛盾

**实施步骤**:
1. 确立字体策略：`Inter` = UI正文，`ZhiMangXing` = 中文装饰标题，`Mali` = 英文装饰标题
2. 在 `AppStyles` 中明确区分装饰样式和功能样式
3. 修复 `inputPlaceholder`/`navActive` 等不应使用装饰字体的样式
4. 批量清理硬编码 `fontFamily: 'Inter'` 的内联样式

**验收标准**: 所有功能性文字使用Inter字体，装饰字体仅用于大标题

#### 方案3: 修复硬编码颜色

**实施步骤**:
1. 在 `CTThemeData` 中增加缺失的语义色令牌（按钮变体色、状态色等）
2. 将 Sidebar 收起模式、DownloadButton、FloatingTaskButton 中的硬编码颜色替换为 `AppColors` 变量
3. 在所有6个主题中为新令牌定义色值

**验收标准**: 切换任意主题后，所有组件颜色正确跟随变化

#### 方案4: 拖拽交互逻辑重构（BUG-07 + BUG-08 + UX-16）

**问题背景**: 用户实际体验反馈——卡片拖拽存在"卡死"和"强制交换"两个严重问题，直接影响核心交互体验。

**实施步骤**:

1. **修复事件丢失（BUG-07）**：在 `_LibraryPageState.build()` 最外层添加全局 `Listener`
```dart
// 拖拽期间捕获全局指针事件，避免指针离开卡片区域后拖拽卡死
Listener(
  onPointerMove: _isDragging ? (e) => _updateDrag(e.position) : null,
  onPointerUp: _isDragging ? (e) => _endDrag() : null,
  child: /* 现有代码 */,
)
```

2. **实现拖回原位自动取消（BUG-08-1）**：修改 `_endDrag()` 逻辑
```dart
void _endDrag() {
  _cancelLongPress();
  _insertDelayTimer?.cancel();
  _autoScrollTimer?.cancel();
  _insertPreviewAnim.reverse();

  // 新增：拖回原位自动取消
  if (_hoverIndex == _originalIndex || _hoverIndex == -1) {
    _cancelDrag();
    return;
  }

  // 新增：目标停留确认（≥200ms）
  final dwellTime = _hoverStartTime != null
      ? DateTime.now().difference(_hoverStartTime!)
      : Duration.zero;
  if (dwellTime < Duration(milliseconds: 200)) {
    _cancelDrag();
    return;
  }

  // 原有交换逻辑...
}
```

3. **拖拽期间禁用其他卡片的 longPress 触发**：
```dart
onPointerDown: !_isDragging ? (event) { /* 原有逻辑 */ } : null,
```

4. **拖拽开始时显示操作提示**：底部 Toast "拖回原位或按 ESC 取消"，1.5秒后自动消失

**验收标准**: 
- 拖拽过程中指针移至任意位置均可正常追踪
- 将卡片拖回原位松手自动取消，无任何状态变更
- 指针在目标上快速划过不触发交换，需停留 ≥200ms
- 拖拽开始后有可见的取消操作提示

#### 方案5: 列表滚动性能优化（UX-34）

**问题背景**: 用户实际体验反馈——游戏列表鼠标中键滚动明显卡顿。

**实施步骤**:

1. **消除 build/initState 中的同步 I/O**：封面路径异步预缓存
```dart
// _LibraryPageState 中增加预缓存
final Map<String, String?> _coverPathCache = {};

Future<void> _resolveAllCoverPaths() async {
  for (final game in _games) {
    if (_coverPathCache.containsKey(game.directoryPath)) continue;
    String? resolved;
    if (game.coverUrl.isNotEmpty && File(game.coverUrl).existsSync()) {
      resolved = game.coverUrl;
    } else {
      try { resolved = GameDataFormat.findCoverFile(game.pathForCover)?.path; }
      catch (_) {}
    }
    _coverPathCache[game.directoryPath] = resolved;
  }
  if (mounted) setState(() {});
}

// _LibraryCardWidget 改为接收 coverPath 参数，不再在 initState 中同步 I/O
```

2. **缓存过滤排序结果**：将 `_filteredAndSortedGames` getter 改为缓存字段
```dart
List<LibraryGame> _cachedFilteredGames = [];
int _filteredGamesHash = 0;

List<LibraryGame> get _filteredAndSortedGames {
  final hash = Object.hash(
    _games.length, _activeSort, _activeDeveloperFilter, _searchQuery,
  );
  if (hash != _filteredGamesHash) {
    _filteredGamesHash = hash;
    _cachedFilteredGames = _computeFilteredAndSortedGames();
  }
  return _cachedFilteredGames;
}
```

3. **设置 cacheExtent**：DiscoverPage 和 HomePage 的 GridView/ListView 添加 `cacheExtent: 800`

4. **添加 RepaintBoundary**：每个卡片外层包裹 `RepaintBoundary`

5. **优化注册表监听**：区分通知类型，游玩时长变化不触发全量 rebuild

**验收标准**: 
- 鼠标中键快速滚动无卡顿
- 帧率稳定 ≥55fps（60fps基准）
- 封面加载期间无白屏闪烁

### 4.2 P1 优化方案（高优先级 - 预计5-7天）

#### 方案6: 建立设计令牌体系

**新增文件**: `lib/theme/app_spacing.dart`

```dart
class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}
```

**补全字体排版**:

```dart
class AppStyles {
  // 现有8个令牌保留
  // 新增标准层级
  static TextStyle get headlineSmall => ...;
  static TextStyle get titleSmall => ...;
  static TextStyle get bodySmall => ...;
  static TextStyle get labelLarge => ...;
  static TextStyle get labelSmall => ...;
  static TextStyle get caption => ...;
}
```

**验收标准**: 魔法数字减少50%以上，字体排版覆盖MD3标准层级

#### 方案7: 弹窗动画系统

**新增组件**: `lib/widgets/animated_overlay.dart`

```dart
class AnimatedOverlayEntry {
  static OverlayEntry show(BuildContext context, {
    required WidgetBuilder builder,
    Duration duration = const Duration(milliseconds: 250),
  }) {
    // 实现淡入+缩放的弹窗进场动画
    // 实现淡出的退场动画
  }
}
```

**替换范围**: MainContainer 中的所有 OverlayEntry（auth/settings/payment/installCenter）

**验收标准**: 所有弹窗有250ms淡入+缩放进场动画，200ms淡出退场动画

#### 方案8: 表单体验升级

**密码显示/隐藏**: 为所有密码输入框添加可见性切换按钮

**实时验证**: 实现 `ValidatedTextField` 组件

```dart
class ValidatedTextField extends StatelessWidget {
  final String? Function(String?) validator;
  final Duration debounce; // 默认300ms
  // 输入时自动验证，显示错误/成功图标
}
```

**危险操作确认**: 封装 `confirmAction()` 工具方法

**验收标准**: 密码框有可见性切换；表单有实时验证；危险操作有确认弹窗

#### 方案9: 响应式布局基础

**新增文件**: `lib/theme/app_breakpoints.dart`

```dart
class AppBreakpoints {
  static const double compact = 960;
  static const double medium = 1280;
  static const double expanded = 1920;
}
```

**优先适配**: GameDetailPage（左侧460px→弹性）、InstallCenterPage（固定900x580→约束最大尺寸）

**验收标准**: 在960px最小窗口下，核心页面内容不溢出

### 4.3 P2 优化方案（中优先级 - 预计7-10天）

| 编号 | 方案 | 预期效果 |
|------|------|---------|
| UX-10 | 调整暗色主题对比度 | placeholderText/secondaryText 对比度 ≥4.5:1 |
| UX-11 | 进度条平滑过渡 | 下载/解压进度无闪烁跳跃 |
| UX-12 | DiscoverPage代码清理 | 减少~90行死代码，消除封面加载逻辑重复 |
| UX-13 | LibraryPage拆分 | 3700行→5-6个独立组件文件 |
| UX-14 | 首页筛选联动 | 选中游戏始终在可见列表中 |
| UX-15 | 统一图片缓存策略 | 全局使用CachedNetworkImage |
| UX-16 | 拖拽排序视觉提示 | 光标变化+插入位置指示线 |
| UX-17 | 添加忘记密码入口 | 密码找回流程可用 |
| UX-18 | 加载状态指示 | 首页/库页有骨架屏或加载指示器 |
| UX-19 | 右键菜单边界检测 | 菜单不超出屏幕边界 |
| UX-20 | 元数据平台图例 | 颜色含义清晰可理解 |
| UX-21 | 搜索语法提示 | 用户知道可用空格分隔标签关键词 |
| UX-22 | 修复时间格式化逻辑 | "刚刚"状态正确显示 |
| UX-23 | 触发UI重建 | 异步数据加载后界面正确更新 |
| UX-24 | 标签面板高度限制 | 大量标签时不撑满页面 |

### 4.4 P3 优化方案（低优先级 - 持续迭代）

| 编号 | 方案 | 预期效果 |
|------|------|---------|
| UX-25 | 可访问性基础 | 导航项+关键按钮有Semantics/Tooltip |
| UX-26 | 合并重叠对话框 | 维护成本降低 |
| UX-27 | 禁用未实现功能 | 避免用户困惑 |
| UX-28 | 支付流程优化 | 金额选择更直观 |
| UX-29 | 修复退出遮罩 | 进度指示器视觉正确 |
| UX-30-33 | 小修复 | 代码质量提升 |

---

## 五、实施优先级与时间规划

### 阶段一：基础修复（第1-4天）

```
Day 1: BUG-01 (ColorScheme联动) + BUG-03 (文本缩放)
Day 2: BUG-02 (字体族修复) + BUG-05 (Sidebar颜色)
Day 3: BUG-04 (主题切换动画) + BUG-06 (按钮颜色)
Day 4: BUG-07 (拖拽事件丢失) + BUG-08 (拖拽取消机制)  ← v1.1新增
```

### 阶段二：体系完善与性能优化（第5-12天）

```
Day 5-6: UX-34 (列表滚动性能优化)  ← v1.1新增，含同步I/O消除+缓存策略
Day 7-8: UX-01 (间距令牌) + UX-02 (字体排版)
Day 9-10: UX-03 (弹窗动画) + UX-04 (密码切换) + UX-05 (实时验证)
Day 11: UX-06 (危险操作确认) + UX-07 (响应式基础)
Day 12: UX-08 (侧边栏动画) + UX-09 (SnackBar主题)
```

### 阶段三：体验优化（第13-23天）

```
Day 13-15: UX-10~14 (对比度/进度条/代码清理/拆分/筛选联动)
Day 16-18: UX-15~19 (缓存/拖拽体验优化/忘记密码/加载状态/菜单边界)
Day 19-21: UX-20~24 (图例/搜索提示/时间修复/重建/标签面板)
Day 22-23: UX-35 (微交互与动画细节优化)  ← v1.1新增
```

### 阶段四：持续迭代（第24天起）

```
按需实施 P3 级别优化
可访问性逐步覆盖
```

---

## 六、可衡量的改进目标

| 指标 | 当前值 | 目标值 | 衡量方式 |
|------|-------|-------|---------|
| 主题切换一致性 | Material组件不跟随 | 100%组件跟随 | 视觉检查6个主题 |
| 硬编码颜色数量 | ~40处 | ≤5处 | 全局搜索 `Color(0x` |
| 内联 TextStyle 数量 | ~60处 | ≤10处 | 全局搜索 `TextStyle(` |
| 魔法间距数字 | ~80处 | ≤20处 | 全局搜索 `SizedBox(height:` |
| WCAG AA 对比度达标率 | ~70% | ≥95% | 对比度检测工具 |
| 弹窗动画覆盖率 | 0% | 100% | 所有OverlayEntry有动画 |
| 表单实时验证覆盖率 | 0% | ≥80% | 关键表单有即时反馈 |
| 危险操作确认覆盖率 | ~50% | 100% | 所有不可逆操作有确认 |
| 代码重复度 | 封面加载6处 | 1处共享组件 | 代码审查 |
| LibraryPage 行数 | 3700+ | ≤800（主文件） | 代码行数统计 |
| 列表滚动帧率 | <30fps（卡顿明显） | ≥55fps | DevTools Performance 面板 | ← v1.1新增
| build中同步I/O调用 | ~8处 | 0处 | 搜索 `existsSync()`/`readAsStringSync()`/`listSync()` | ← v1.1新增
| 拖拽取消成功率 | 0%（只能ESC） | 100%（原位/取消区/划过） | 手动测试3种取消方式 | ← v1.1新增
| 图片加载过渡 | 无淡入 | 100%交叉淡入 | 视觉检查所有图片切换场景 | ← v1.1新增

---

## 七、风险与注意事项

1. **主题色值调整需全量回归**: 修改 `CTThemeData` 中的颜色值可能影响所有页面，需在每个主题下全量测试
2. **字体策略变更影响面大**: 将装饰字体从功能性文字中移除，需逐个页面检查布局是否因字体变化而错位
3. **LibraryPage 拆分需谨慎**: 3700行代码的拆分需要仔细管理状态依赖，建议逐步拆分而非一次性重构
4. **响应式适配应渐进式**: 优先适配问题最严重的页面，避免大规模布局重构
5. **可访问性实施成本高**: Semantics 标注需要逐组件添加，建议按使用频率分批实施
6. **拖拽逻辑重构需充分测试**: BUG-07/BUG-08 的修复涉及核心交互逻辑变更，需测试以下场景：拖拽中松手、拖拽中 ESC、拖回原位、拖至空白区域、拖至列表边缘自动滚动、快速连续拖拽、拖拽动画未完成时再次拖拽（v1.1新增）
7. **同步 I/O 消除需验证缓存一致性**: 将 `existsSync` 改为异步预缓存后，需确保文件删除/移动时缓存能正确失效（v1.1新增）
8. **微交互优化需平衡性能**: 弹性动画、交叉淡入等效果可能增加 GPU 负担，需在低端设备上验证帧率（v1.1新增）

---

## 附录A：审查覆盖文件清单

| 分类 | 文件 | 行数 |
|------|------|------|
| 主题系统 | app_colors.dart, app_styles.dart, app_theme_manager.dart, main.dart | ~900 |
| 主容器 | main_container.dart, sidebar.dart, custom_title_bar.dart | ~1100 |
| 核心页面 | home_page.dart, discover_page.dart, library_page.dart, game_detail_page.dart, install_center_page.dart | ~7300 |
| 对话框 | settings_modal.dart, auth_modal.dart, payment_modal.dart, discover_disclaimer_dialog.dart, game_detail_dialog.dart, install_confirmation_dialog.dart, update_dialog.dart, exit_overlay.dart, user_profile_modal.dart, save_backup_dialog.dart, launch_manager_dialog.dart, exe_selector_dialog.dart, library_context_menu.dart | ~6500 |
| 组件 | screenshot_carousel.dart, download_button.dart, download_progress_bar.dart, floating_task_button.dart, floating_user_button.dart, interactive_wrapper.dart, extract_status.dart, play_stats_panel.dart | ~2000 |
| 入库流程 | join_page.dart, join_controller.dart, batch_import_controller.dart, form_inputs.dart, file_drop_zone.dart, metadata_section.dart, action_buttons.dart, smart_import_section.dart, swipe_switcher.dart, batch_import_section.dart, field_lock_button.dart, progress_dialog.dart | ~4500 |
| 认证 | login_page.dart, register_page.dart | ~600 |

---

*本方案基于2026-07-01的代码版本生成，后续代码变更可能影响部分分析的准确性。*

---

## 附录B：v1.1 变更记录（2026-07-01）

基于实际使用体验反馈，本次更新整合以下内容：

### 新增问题
| 编号 | 问题 | 优先级 | 来源 |
|------|------|--------|------|
| BUG-07 | 拖拽事件丢失——指针离开卡片区域后拖拽卡死 | P0 | 用户实际体验反馈 |
| BUG-08 | 拖拽结束强制执行交换——无法取消/撤回 | P0 | 用户实际体验反馈 |
| UX-34 | 游戏列表滚动卡顿——同步 I/O 阻塞主线程 | P1 | 用户实际体验反馈 |
| UX-35 | 微交互与动画过渡细节优化（5项子问题） | P3 | 用户实际体验反馈 |
| UX-36 | 窗口控制按钮缺少按压反馈 | P3 | 微交互排查 |
| UX-37 | 截图轮播箭头按钮无 hover 效果 | P3 | 微交互排查 |
| UX-38 | 登录/注册输入框无焦点高亮 | P3 | 微交互排查 |
| UX-39 | 批量入库进度信息不透明 | P3 | 细节排查 |

### 问题升级
| 原编号 | 变更 | 说明 |
|--------|------|------|
| UX-16 | 内容扩展 | 从"可发现性差"升级为"交互体验优化"，新增3项子问题和4项修复建议 |

### 新增方案
| 方案 | 对应问题 | 说明 |
|------|---------|------|
| 方案4 | BUG-07 + BUG-08 + UX-16 | 拖拽交互逻辑重构（全局事件监听+拖回取消+停留确认+操作提示） |
| 方案5 | UX-34 | 列表滚动性能优化（异步I/O+缓存策略+cacheExtent+RepaintBoundary） |

### 统计变化
| 项目 | v1.0 | v1.1 |
|------|------|------|
| 必须修复(P0) | 6 | **8** (+2) |
| 建议优化(P1) | 9 | **10** (+1) |
| 建议优化(P2) | 15 | 15 |
| 建议优化(P3) | 9 | **13** (+4) |
| **总问题数** | **39** | **48** (+9) |
| 实施总天数 | ~20天 | **~24天** (+4天) |
| 可衡量指标 | 10项 | **14项** (+4项) |
