# Chrono Tide UI 主题系统升级方案

> **版本**: v3.0（最终决策版 / 交付版）
> **日期**: 2026-07-25
> **项目性质**: UI 主题系统升级优化（用户自定义主题能力建设）
> **当前版本**: Chrono Tide v1.4.5
> **文档状态**: ✅ 决策已确认，准备进入 P0 实施
> **关联文档**: [UI_UX_UPGRADE_PLAN.md](./UI_UX_UPGRADE_PLAN.md)、[UI_DEVELOPMENT_GUIDE.md](../UI_DEVELOPMENT_GUIDE.md)
> **设计参考**: [Figma 615_2 主题设计器草图](../.figma/615_2/index.jsx)、[Figma 615_560 侧栏 UI](../.figma/615_560/index.jsx)

---

## 0. 决策记录（v3.0 定版）

### 0.1 决策一览

| 编号 | 决策点 | 选定方案 | 决策人 | 决策时间 |
|------|--------|---------|--------|---------|
| **A2** | 组件规范项目怎么处理 | 主题编辑器独立推进，组件规范作为 P7 单独立项 | 用户 | 2026-07-25 |
| **B1** | 库页/探索页游戏卡片是否合并 | 现在不管，允许两套独立组件各自有可编辑元素 | 用户 | 2026-07-25 |
| **C1** | 发布策略 | 第一版 P0-P3（13-17 天），第二版 P4-P6（6-8 天） | 用户 | 2026-07-25 |
| **D1** | HSV picker 实现 | **自建**（不引入 `flutter_colorpicker`） | 用户 | 2026-07-25 |
| **D2** | Recent Colors 生命周期 | **会话级**（关闭编辑器清空，不持久化） | 用户 | 2026-07-25 |
| **D3** | 撤销/重做栈深度 | **50 步** | 用户 | 2026-07-25 |
| **D4** | 编辑器顶部 Tab | **先单 Tab**（只有"调色板" Tab，二期再加"主题设计器" Tab） | 用户 | 2026-07-25 |

### 0.2 版本演进

| 版本 | 关键变化 |
|------|---------|
| v1.0 | 表单化分组调色面板（6 大分组列 35+ 令牌），**已废止** |
| v2.0 | 重大转向 WYSIWYG 调色设计器（左可编辑预览 + 右 fill/stroke 面板），引入双 Tab、双通道、Recent Colors、撤销栈、24 元素清单 |
| **v3.0** | **决策定版**：移除"主题设计器 Tab"（D4）、明确 HSV 自建（D1）、Recent Colors 会话级（D2）、50 步撤销（D3）、明确组件规范独立为 P7（A2）、明确允许卡片组件不合并（B1）、分两期发布（C1） |

### 0.3 v2 → v3 关键调整

| 维度 | v2 | v3（定版） |
|------|----|----|
| 编辑器结构 | 顶部双 Tab [调色板] [主题设计器] | **单 Tab（无 Tab 概念）**——只有一个"调色板"主界面 |
| 24 个可编辑元素 | 单一 `app_card` 涵盖库页+探索页 | **增加"影响范围"标注**——每个元素标注影响哪些实际位置 |
| 组件规范 | 在主题编辑器范围内涉及 | **剥离为 P7 独立项**（不阻塞主线） |
| 发布节奏 | 一次性 P0-P6 | **两期发布**：第一版 P0-P3 / 第二版 P4-P6 |
| HSV picker | 备选"自建 vs 引入" | **明确自建**（D1） |
| Recent Colors | 备选"会话级 vs 持久化" | **明确会话级**（D2） |
| 撤销栈深度 | 备选 50/100/200 | **明确 50**（D3） |
| 主题设计器 Tab 的高级编辑 | 双 Tab 之一 | **不实施**——D4 决策后移除；35 令牌批量编辑推迟到 P7 组件规范项目 |

---

## 目录

1. [现状分析](#一现状分析)
2. [解决方案设计：WYSIWYG 调色设计器](#二解决方案设计wyiwyg-调色设计器)
3. [技术实现方案](#三技术实现方案)
4. [技术难点与风险](#四技术难点与风险及应对方案)
5. [分阶段开发计划（两期发布）](#五分阶段开发计划两期发布)
6. [P7 UI 组件规范独立项（仅描述范围）](#六p7-ui-组件规范独立项仅描述范围)
7. [可行性分析](#七可行性分析)
8. [对接交付说明（给下一个 AI 模型）](#八对接交付说明给下一个-ai-模型)

---

## 一、现状分析

### 1.1 主题系统实现方式

| 文件 | 行数 | 职责 |
|------|------|------|
| [app_theme_manager.dart](../lib/theme/app_theme_manager.dart) | 553 | 主题定义、状态管理、过渡动画、持久化 |
| [app_colors.dart](../lib/theme/app_colors.dart) | 52 | 静态颜色门面，供全应用消费 |
| [app_styles.dart](../lib/theme/app_styles.dart) | 290 | 字体排版令牌、圆角常量 |

**核心数据流**：

```
CTTheme 枚举 (6 个预设) → CTThemeData (35+ 颜色字段)
  → AppThemeManager.current getter（过渡期返回 lerp 插值）
  → AppColors 静态门面 (30+ getter) → 全应用 300+ 调用点
  → AnimatedBuilder(animation: AppThemeManager.instance) 驱动重建
```

**关键实现**：
1. **6 个硬编码主题**：`CTTheme` 枚举（[app_theme_manager.dart:185-441](../lib/theme/app_theme_manager.dart#L185-L441)），`static const Map` 形式编译期固定
2. **ChangeNotifier 单例 + 250ms 过渡**：`AppThemeManager.instance.setTheme()` 触发 `Color.lerp` 帧回调动画（[app_theme_manager.dart:467-519](../lib/theme/app_theme_manager.dart#L467-L519)）
3. **ColorScheme 联动**：[main.dart:719-767](../lib/main.dart#L719-L767) `ColorScheme.fromSeed` + 语义令牌覆盖
4. **背景图渲染**：[main_container.dart:660-733](../lib/main_container.dart#L660-L733) 3 层 Stack，仅支持 bundled asset
5. **主题设计器 UI**：[settings_modal.dart:2398-2767](../lib/widgets/settings_modal.dart#L2398-L2767) 现有"经典配色"+"特色主题"+"自定义背景"占位（**未实现** = UX-27）
6. **窗口背景同步**：[main.dart:209,375](../lib/main.dart#L209) DWM 背景色同步
7. **BPM 共享 AppColors**：[big_picture_theme.dart](../lib/big_picture/big_picture_theme.dart) 仅布局常量，自动跟随主题

### 1.2 关键发现：各页面"颜色归属"已统一

经代码核查，所有页面的"主内容区背景"和"游戏卡片背景"**已通过 `AppColors` 抽象统一**：

| 页面 | 主内容区背景令牌 | 来源 |
|------|----------------|------|
| 库页 | `AppColors.pageBackground` | [library_page.dart:1614-1618](../lib/pages/library_page.dart#L1614-L1618) |
| 探索页 | `AppColors.pageBackground` | [discover_page.dart:582-583](../lib/pages/discover_page.dart#L582-L583) |
| 主页 | `AppColors.pageBackground` | [home_page.dart:225-226](../lib/pages/home_page.dart#L225-L226) |
| 添加页 | `AppColors.pageBackground` | [join_page.dart:298-299](../lib/pages/join_page.dart#L298-L299) |
| 游戏详情页 | `AppColors.background` | [game_detail_page.dart:586](../lib/pages/game_detail_page.dart#L586) |
| 安装中心 | `AppColors.background` | [install_center_page.dart:98-100](../lib/pages/install_center_page.dart#L98-L100) |

`AppColors.background` 与 `AppColors.pageBackground` 实为同一令牌（仅"有背景图时"返回透明，[app_colors.dart:8-10](../lib/theme/app_colors.dart#L8-L10)）。

**结论**：**改一次颜色 = 6 个页面一起变**。但用户**不知道**这一点——编辑器需要"影响范围提示"。

### 1.3 关键发现：游戏卡片 2 套独立实现

| 实现 | 文件位置 | 用途 |
|------|---------|------|
| `_LibraryCardWidget` | [library_page.dart:2198](../lib/pages/library_page.dart#L2198) | 库页游戏卡片 |
| `_DiscoverCardWidget` | [discover_page.dart:1035](../lib/pages/discover_page.dart#L1035) | 探索页游戏卡片 |

**B1 决策后**：两套卡片**不合并**，各自独立维护。颜色层面共用 `AppColors.background` / `AppColors.border` 令牌；样式细节（粗细/圆角/阴影）由各自 widget 内部硬编码决定，不进主题编辑器。

### 1.4 关键发现：侧栏 3 按钮同源

[sidebar.dart:96-161](../lib/widgets/sidebar.dart#L96-L161) 的 3 个导航按钮（库/探索/添加）通过**同一个 widget 方法** `_buildNavItemExpanded` 渲染 3 次（传入不同 `label` 和 `isActive`），改一次 = 改全部 3 个。

### 1.5 现有功能限制

| 限制 | 影响 | 根因 |
|------|------|------|
| **6 主题硬编码** | 用户无法调整任何颜色 | `CTTheme` 枚举 + `static const Map` |
| **`CTTheme` 枚举驱动** | 无法运行时新增主题 | `_currentTheme` 类型为 `CTTheme` |
| **背景图仅支持 bundled** | 用户无法上传 | `Image.asset` 硬编码 |
| **"自定义背景"占位空壳** | UX-27 用户困惑 | `onTap: null` 未实现 |
| **无主题保存/加载/管理** | 无用户主题库 | SharedPreferences 仅存激活主题名 |
| **无主题分享** | 用户间无法共享 | 无序列化机制 |

---

## 二、解决方案设计：WYSIWYG 调色设计器

### 2.1 设计理念与心智模型

**核心隐喻**：把当前 UI 本身当作"画板"，用户**像在 Figma/Pencil 里编辑图层一样**操作。

**类比参考**：
- **Figma / Pencil**：左文件树/画板 + 右 fill/stroke/effects 面板
- **Unity / UE5 编辑器**：左 Hierarchy 预览 + 右 Inspector 颜色通道
- **游戏角色编辑器**（原神/模拟人生）：多"颜色槽"独立调节 + 实时 3D 预览

**统一一句话**：

> "把现在 UI 的样子直接放在调色板左边，用户看着图、点哪改哪；右边就是该区域的填充 / 描边 / 文字色"。

### 2.2 整体交互流程

```
设置 → 主题设计器（现有卡片）
  ├─ 经典配色（6 内置, 不动）
  ├─ 特色主题（3 背景图, 不动）
  ├─ 我的主题（第二版新增：用户主题库）
  └─ 调色板（新增入口，原"自定义背景"占位替换）
        └─ 点击 → 打开 "主题设计器" 弹窗（独立全屏模态）
              ├─ 左侧 [主面板区]：可缩放实时 UI 预览 + 双击/点击选择元素
              │   ├─ 选中元素高亮（蓝色描边）
              │   ├─ 右侧面板顶部显示"当前选中：侧栏"
              │   ├─ 双击可进入嵌套层级（侧栏 → 库按钮）
              │   └─ **影响范围提示**（A2 决策新增）
              └─ 右侧 [主题设计器面板]（单 Tab，无 Tab 切换）：
                    ├─ 填充 标签 + 当前色值 + 眼睛图标
                    ├─ 大型 HSV 调色板（白→饱和 + 色相条 + Alpha 滑块）
                    ├─ Hex / 百分比 输入框
                    ├─ Recent Colors（最近 24 色，**会话级**，D2 决策）
                    ├─ 描边 标签 + 当前色值
                    ├─ 文字色 标签（仅文字元素显示）
                    └─ 上传图片或 GIF 作为应用背景

              └─ 顶部工具栏：[↶ 撤销] [↷ 重做] [应用] [保存为新主题] [取消]
```

**D4 决策说明**：v2 的"主题设计器 Tab"（高级批量编辑 35 令牌）已移除。第一版只有"调色板"主界面，单 Tab 无 Tab 切换。35 令牌批量编辑推迟到 P7 组件规范项目（见第六章）。

### 2.3 编辑器 UI 设计

#### 2.3.1 弹窗整体布局

```
┌──────────────────────────────────────────────────────────────────┐
│  [图标] 设置 / Settings / 调色板                       [─] [□] [×] │  ← 标题栏
├──────────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────┐ ┌─────────────────────────────┐    │
│ │                            │ │ 当前选中：侧栏 / Sidebar     │    │  ← 右侧顶部
│ │                            │ │ ⚠ 此修改将影响: 侧栏 1 处    │    │  ← 影响范围 (A2)
│ │     可缩放 UI 预览          │ ├─────────────────────────────┤    │
│ │   （带选择高亮）             │ │ 填充  [█ FFEEEE 100% Solid] [👁]│   │
│ │                            │ │ ┌────────────────────────┐ │    │
│ │                            │ │ │   HSV 调色板（自建,D1）  │ │    │
│ │     [Chrono Tide]          │ │ └────────────────────────┘ │    │
│ │     [库][探索][添加]        │ │ [色相条] [Alpha] Hex/%      │    │
│ │     [主页]                 │ │                             │    │
│ │     [游戏卡片网格]          │ │ 描边  [█ 000000 100% Solid] [👁]│   │
│ │                            │ │ ┌────────────────────────┐ │    │
│ │                            │ │ │   HSV 调色板（自建）     │ │    │
│ │                            │ │ └────────────────────────┘ │    │
│ │                            │ │ [色相条] [Alpha] Hex/%      │    │
│ │                            │ │                             │    │
│ │                            │ │ Recent Colors（会话级,D2）  │    │
│ │                            │ │ [█][█][█][█][█][█][█][█]   │    │
│ │                            │ ├─────────────────────────────┤    │
│ │                            │ │ 文字色 [█ 5C4A3D 100%] [👁]│   │  ← 仅文字元素
│ │                            │ ├─────────────────────────────┤    │
│ │                            │ │ ⬆ 上传图片或 GIF 作为应用背景 │   │
│ └────────────────────────────┘                                  │
├──────────────────────────────────────────────────────────────────┤
│  [↶ 撤销(D3:50步)] [↷ 重做]    [取消] [保存为新主题] [应用并保存] │  ← 底部
└──────────────────────────────────────────────────────────────────┘
```

#### 2.3.2 左侧"主面板区"——可编辑 UI 预览

**核心组件**：
- 缩放比例控件（25% / 50% / 75% / 100%），默认 50%
- 选中元素**蓝色描边高亮**（类 Figma selection box）
- 鼠标悬停可编辑元素时显示**淡蓝半透明覆盖**（hover 态）
- **双击进入嵌套层级**（侧栏 → "库"按钮 → "库"文字）
- 顶部面包屑显示当前选中路径（如 `应用窗口 / 内容区 / 游戏卡片 / 标题文字`）

**"预览骨架"实现模式**（不渲染真实完整应用）：
- 渲染一个**简化的、固定的、确定性的 UI 缩略图**
- 包含所有可编辑元素的代表性样例
- 与真实 UI **视觉 1:1 还原**（同色同字体同间距），**不含业务数据**
- 骨架由 `EditorPreviewBuilder` 组件构建，从 `CTThemeData` + `backgroundImage` config 实时取色
- 用户的点击/双击触发**元素 ID 选择事件**

#### 2.3.3 右侧"主题设计器"面板（单 Tab，无 Tab 切换）

**三组颜色通道**（按元素类型显示对应通道，D 决策后正式启用文字色）：

| 元素类型 | 填充 | 描边 | 文字色 |
|---------|------|------|--------|
| 容器类（侧栏/标题栏/卡片） | ✅ | ✅ | — |
| 按钮类 | ✅ | ✅ | ✅ |
| 文字类 | — | — | ✅ |
| 图标类 | ✅（单色图标） | — | — |
| 装饰类（金色星标等） | ✅ | — | — |

**每个通道面板结构**（以"填充"为例）：
```
填充  [█ FFEEEE 100% Solid] [👁 显示/隐藏] [↻ 复位]
┌──────────────────────────────────┐
│   HSV 调色板（自建, D1）           │  ← 2D SV picker
│   ┌──────────────────────┐       │
│   │                      │       │
│   │    圆点（当前选色）    │       │
│   │                      │       │
│   └──────────────────────┘       │
└──────────────────────────────────┘
[色相条:  R  Y  G  C  B  M  R  ]
[饱和度:  ━━━━━●━━━━━ 100%        ]
[明度:    ━━━━━━●━━━ 88%          ]
[Alpha:   ━━━━●━━━━━━ 100%        ]
Hex: [FFEEEE▼]  R:[255] G:[238] B:[238] A:[100%]
[+] 设为最近颜色
```

**通道附加参数**：
- **Stroke**：颜色 + **宽度**（0.5–4.0px）+ 透明度
- **TextColor**：颜色 + 透明度

**通道可见性 / 锁定**：
- 眼睛图标：隐藏 = 该通道在编辑器中透明显示（可看背景），仍可编辑；状态持久化
- 锁图标：锁定 = 切换主题/复位时该通道不变

### 2.4 撤销/重做（D3 决策：50 步栈）

**栈机制**：
- `List<CTThemeData> _undoStack` + `List<CTThemeData> _redoStack`，**深度上限 50**（D3）
- 每次"完整调色动作"入栈（拖动连续变化只在结束时入栈一次）
- 栈内存影响：50 × 约 500 字节 = 约 25KB，可忽略

**完整调色动作定义**：
- HSV picker `onPanEnd`（pointerUp）
- 数值输入框失焦
- Recent Color 点击
- 通道切换 / 元素切换
- 背景图上传
- 通道眼睛/锁切换

**键盘快捷键**：
- `Ctrl+Z` 撤销 / `Ctrl+Y` 或 `Ctrl+Shift+Z` 重做
- `Esc` 关闭编辑器

**底部按钮**：`↶ 撤销` / `↷ 重做` 始终可见，栈空时灰显。

### 2.5 Recent Colors（D2 决策：会话级）

- 最近 24 色，**会话级**（D2）—— 关闭编辑器清空，不持久化
- 网格展示，2 行 × 12 列
- 点击色块 = 应用该色到当前通道
- 与"当前通道"隔离：填充/描边/文字色各有自己的 Recent Colors
- 各通道独立存储 24 色，互不干扰

### 2.6 影响范围提示（A2 决策新增）

**目的**：解决用户"我改了这个怎么这么多地方变了"的困惑。

**实现**：
- 每个 `ThemeElementDescriptor` 新增 `List<String> impactLocations` 字段
- 元素被选中时，右侧面板顶部显示影响范围（如"⚠ 此修改将影响：侧栏 1 处、游戏卡片 2 套、对话框 13 个"）
- 数据来源：与 1.2-1.3 节验证过的实际代码位置对应

### 2.7 24 个可编辑元素清单（B1 决策定版）

**B1 决策说明**：库页 `_LibraryCardWidget` 与探索页 `_DiscoverCardWidget` 是 2 套独立 widget，**不合并**。两套卡片在主题编辑器中**作为同一个可编辑元素 `app_card` 暴露**——因为颜色层面共用 `AppColors.background` / `AppColors.border` 令牌，改一个 = 全部一起变（B1 不要求颜色分离控制）。**样式细节**（边框粗细/圆角/阴影）由各 widget 内部硬编码，**不在编辑器控制范围**。

| ID | 显示名 | 元素类型 | 映射令牌 | 通道 | 影响范围 |
|----|--------|---------|---------|------|---------|
| `app_window` | 主窗口背景 | 容器 | `background` | fill | 库页内容区、探索页内容区、主页内容区、添加页内容区、游戏详情页、安装中心（6 处） |
| `app_sidebar` | 侧栏 | 容器 | `sidebarBackground` + `borderLight` | fill + stroke | 全应用侧栏（1 处，左侧固定） |
| `app_titlebar` | 标题栏 | 容器 | `titleBarBackground` | fill | 标题栏（1 处，kTitleBarHeight=32.0） |
| `app_titlebar_text` | 标题栏文字 | 文字 | `primaryText` | textColor | 标题栏文字（窗口标题） |
| `sidebar_title` | 侧栏大标题 | 文字 | `titleBrown` | textColor | 侧栏顶部"Chrono Tide"标题 |
| `nav_active` | 侧栏激活按钮 | 按钮 | `navActiveBg` + `navActiveBorder` | fill + stroke + textColor | 当前激活的导航按钮（库/探索/添加 中 1 个） |
| `nav_inactive` | 侧栏非激活按钮 | 按钮 | `navInactiveBorder` + `cardHoverBg` | stroke + fill | 侧栏 2 个未激活的导航按钮（自动联动） |
| `home_button` | 主页按钮 | 按钮 | `cardHoverBg` + `border` | fill + stroke | 侧栏底部主页按钮（1 个） |
| `app_card` | 游戏卡片 | 容器 | `buttonBackground` + `border` | fill + stroke | **库页 + 探索页游戏卡片**（2 套独立 widget，颜色层面联动，B1） |
| `card_cover_placeholder` | 卡片封面占位 | 容器 | `placeholderCover` | fill | 所有卡片缺封面占位（库页 + 探索页） |
| `card_title` | 卡片标题文字 | 文字 | `primaryText` | textColor | 库页 + 探索页卡片标题 |
| `accent_color` | 主题强调色 | 装饰 | `selectedAccent` | fill | 全应用强调色（选中态/勾选） |
| `border_global` | 全局边框 | 装饰 | `border` | fill（颜色） | 卡片、按钮、对话框、输入框等所有边框 |
| `border_light_global` | 全局浅边框 | 装饰 | `borderLight` | fill | 浅色边框（同上所有位置） |
| `button_bg` | 通用按钮背景 | 容器 | `buttonBackground` | fill | 通用按钮、设置项 |
| `button_text` | 通用按钮文字 | 文字 | `primaryText` | textColor | 通用按钮文字 |
| `text_primary` | 主要文字 | 文字 | `primaryText` | textColor | 所有正文 |
| `text_secondary` | 次要文字 | 文字 | `secondaryText` | textColor | 描述、辅助说明 |
| `text_placeholder` | 占位文字 | 文字 | `placeholderText` | textColor | 输入框、占位符 |
| `state_success` | 成功状态 | 装饰 | `successGreen` + `successBg` | fill × 2 | 成功提示、状态徽章 |
| `state_danger` | 危险状态 | 装饰 | `dangerRed` + `errorBg` + `hoverCloseBg` + `hoverCloseBorder` | fill × 4 | 危险提示、关闭按钮 hover |
| `state_info` | 信息状态 | 装饰 | `infoBlue` + `infoBg` + `brandBlue` | fill × 3 | 信息提示 |
| `state_star` | 星级金色 | 装饰 | `starGold` | fill | 评分星标 |
| `app_background_image` | 应用背景图 | 装饰 | `backgroundImageConfig` | （独立控件） | 3 个特色主题背景图 + 用户上传背景图 |

**共 24 个可编辑元素**，覆盖核心 UI 高曝光区域。

### 2.8 主题保存/加载/管理（第二版 P4 实施）

**存储结构**：
- `${appSupportDir}/user_themes/{themeId-1}.json` —— 用户主题定义
- `${appSupportDir}/user_backgrounds/{bgUuid-1}.{ext}` + 缩略图 —— 用户上传背景图
- SharedPreferences `'app_theme'` —— 激活主题 id

**JSON Schema**（与 v2 兼容）：
```json
{
  "schemaVersion": 1,
  "id": "9f3a2b7c-...",
  "name": "我的蔚蓝",
  "emoji": "🌊",
  "description": "基于蓝天的自定义主题",
  "baseOn": "ocean",
  "brightness": "light",
  "seedColor": "#FF4A90D9",
  "colors": { "background": "#FFE8F4FC", "...": "..." },
  "backgroundImage": {
    "source": "file",
    "filename": "bgUuid-1.png",
    "overlayOpacity": 0.30,
    "blurSigma": 0.0,
    "fit": "cover",
    "alignment": "center"
  },
  "createdAt": "2026-07-25T10:00:00Z",
  "updatedAt": "2026-07-25T10:00:00Z"
}
```

**注**：24 元素的"通道→令牌"映射是**运行时**的（`ThemeElementRegistry`），**不进 JSON 文件**——这保证 v1/v2/v3 主题可互导。

### 2.9 主题分享（第二版 P5 实施）

`.cttheme` 文件格式 = ZIP 压缩包：
- `theme.json`（同上 schema）
- `backgrounds/{filename}`（如有）
- `thumbnail.png`（主题卡片缩略图，可选）

- **导出**：打包为 ZIP，扩展名 `.cttheme`，系统文件保存对话框
- **导入**：解压 + schema 校验 + 生成新 UUID + 复制背景图 + 写 JSON
- 冲突策略：总是新 UUID 导入，命名加"(导入)"后缀

### 2.10 与现有偏好设置页主题调色板的兼容性

**完全保留现有 UI**：

1. [settings_modal.dart:2507-2558](../lib/widgets/settings_modal.dart#L2507-L2558) "经典配色"区**完全不动**
2. [settings_modal.dart:2584-2705](../lib/widgets/settings_modal.dart#L2584-L2705) "特色主题"区**完全不动**
3. [settings_modal.dart:2718-2759](../lib/widgets/settings_modal.dart#L2718-L2759) "自定义背景"**占位按钮** 替换为 **"调色板"入口按钮**：
   - 文案改为"主题调色板 · 调色 / 背景 / 分享"
   - `onTap` 打开 `ThemeEditorDialog`
4. 第二版（P4）新增"我的主题"区（第一版不显示，避免新用户看到空白）

**与 UI_UX_UPGRADE_PLAN.md UX-27 的关系**：本方案整体闭合 UX-27。

---

## 三、技术实现方案

### 3.1 整体架构（四层分层）

```
┌──────────────────────────────────────────────────────────────┐
│ Layer 4: UI 层                                                │
│  - ThemeEditorDialog（全屏弹窗）                              │
│  - EditorPreviewPanel（左侧可编辑预览骨架）                    │
│  - ColorChannelPanel（填充/描边/文字色面板）                  │
│  - HsvColorPicker（HSV 自建，D1 决策）                        │
│  - RecentColorsStrip（会话级，D2 决策）                       │
│  - UndoRedoBar（50 步栈，D3 决策）                            │
│  - ImpactHint（影响范围提示，A2 决策）                        │
│  - MyThemesSection（第二版 P4）                                │
│  - 现有 _buildThemeDesignerCard（内置主题, 不动）              │
└──────────────────────────────────────────────────────────────┘
                          ↑ 调用
┌──────────────────────────────────────────────────────────────┐
│ Layer 3: ThemeManager 层                                       │
│  - currentThemeId: String（v3 重构）                          │
│  - setTheme(String id) / applyCustomTheme(CTThemeData)        │
│  - 250ms lerp 过渡动画（保留）                                 │
│  - notifyListeners → AnimatedBuilder                          │
└──────────────────────────────────────────────────────────────┘
                          ↑ 读取/注册
┌──────────────────────────────────────────────────────────────┐
│ Layer 2: ThemeRegistry 层                                      │
│  - Map<String, CTThemeData> _themes（内置+用户）               │
│  - registerBuiltin / loadUserThemes / save / delete / dup     │
│  - ThemeElementRegistry 静态（24 元素 + 令牌映射 + 影响范围）  │
└──────────────────────────────────────────────────────────────┘
                          ↑ 读写
┌──────────────────────────────────────────────────────────────┐
│ Layer 1: ThemeStorage 层                                       │
│  - UserThemeJsonStore / BackgroundImageStore / SharedPrefs    │
│  - CtThemePackage（.cttheme 打包/解包，第二版 P5）            │
└──────────────────────────────────────────────────────────────┘
                          ↑ 基于不可变值对象
┌──────────────────────────────────────────────────────────────┐
│ Foundation: CTThemeData + AppColors 门面                       │
│  新增: toJson/fromJson/backgroundImageConfig (P2-P3)          │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 关键数据流

**编辑器打开时**：
```
ThemeEditorDialog.init()
  → 读 AppThemeManager.instance.current 快照
  → ValueNotifier<CTThemeData> _previewNotifier
  → 加载 ThemeElementRegistry.allElements()
  → 默认选中 'app_window'
  → _undoStack = [snapshot] (D3 50 步上限)
```

**用户点击预览元素时**：
```
EditorPreviewBuilder onElementTap(elementId)
  → _selectedElementId = elementId
  → 查 ThemeElementRegistry.byId(elementId)
  → 显示 ImpactHint (A2)
  → 右侧 ColorChannelPanel rebuild
```

**用户拖动 HSV picker 时**（高频）:
```
HsvColorPicker onColorChanged(Color)
  → _onColorChanged(tokenField, newColor)
  → 克隆 CTThemeData + 改对应 tokenField
  → _previewNotifier.value = newData
  → 预览区立即变色（仅预览区，全应用不动）
```

**用户松开 HSV picker 时**（完整动作入栈）:
```
HsvColorPicker onColorChangeEnd
  → _undoStack.push(snapshot)  // D3 上限 50，超出丢弃最早
  → _redoStack.clear()
```

**用户点"应用"时**:
```
onApply()
  → AppThemeManager.instance.applyCustomTheme(_previewNotifier.value)
  → 250ms lerp 过渡（现有机制）
  → 持久化 'app_theme'
```

### 3.3 可编辑元素 → 令牌映射

```dart
// lib/theme/theme_element_registry.dart
class ThemeElementDescriptor {
  final String id;                  // 'app_sidebar'
  final String displayName;         // '侧栏'
  final ElementType type;           // container / button / text / decoration
  final List<ThemeProperty> properties;
  final List<String> impactLocations;  // A2 决策：影响范围
}

class ThemeProperty {
  final String name;                // 'fill' / 'stroke' / 'textColor'
  final String tokenField;          // 'sidebarBackground' / 'borderLight'
  final Color value;
  final bool visible;               // 眼睛图标
  final bool locked;                // 锁图标
}

class ThemeElementRegistry {
  static late final List<ThemeElementDescriptor> _all;
  
  static void register() {
    _all = [
      // 24 个 const 元素，每个含 impactLocations (A2 决策)
      const ThemeElementDescriptor(
        id: 'app_window',
        displayName: '主窗口背景',
        type: ElementType.container,
        properties: [ThemeProperty('fill', 'background')],
        impactLocations: [
          '库页内容区', '探索页内容区', '主页内容区',
          '添加页内容区', '游戏详情页', '安装中心',
        ],
      ),
      const ThemeElementDescriptor(
        id: 'app_sidebar',
        displayName: '侧栏',
        type: ElementType.container,
        properties: [
          ThemeProperty('fill', 'sidebarBackground'),
          ThemeProperty('stroke', 'borderLight'),
        ],
        impactLocations: ['全应用侧栏（1 处）'],
      ),
      const ThemeElementDescriptor(
        id: 'app_card',
        displayName: '游戏卡片',
        type: ElementType.container,
        properties: [
          ThemeProperty('fill', 'buttonBackground'),
          ThemeProperty('stroke', 'border'),
        ],
        impactLocations: [
          '库页游戏卡片（_LibraryCardWidget）',
          '探索页游戏卡片（_DiscoverCardWidget）',
          '⚠ B1 决策：两套独立 widget，颜色层面联动，样式细节不联动',
        ],
      ),
      // ... 共 24 个
    ];
  }
}
```

### 3.4 预览隔离

**关键原则**：编辑器内的修改不污染全应用，仅"应用"才生效。

```dart
class ThemeEditorDialog extends StatefulWidget {
  Widget build() {
    return Dialog(
      child: ValueListenableBuilder<CTThemeData>(
        valueListenable: _previewNotifier,
        builder: (context, previewData, _) {
          return Row([
            // 左侧预览区：直接消费 previewData，**绕过 AppColors**
            EditorPreviewPanel(themeData: previewData, ...),
            // 右侧调色板：也直接消费 previewData
            ColorChannelPanel(themeData: previewData, ...),
          ]);
        },
      ),
    );
  }
}
```

**对比**：
- `AppColors.background` → `AppThemeManager.colors.background` → **全局**
- `previewData.background` → 参数直接读 → **编辑器局部**

### 3.5 HSV 调色板自建实现（D1 决策）

**为什么自建**：避免引入 `flutter_colorpicker` 第三方依赖（~200KB 安装包），保持项目"OpenList 体积优化"理念一致。

**实现要点**（`lib/widgets/hsv_color_picker.dart`）：

```dart
class HsvColorPicker extends StatefulWidget {
  final Color color;
  final ValueChanged<Color> onChanged;     // 拖动中高频
  final ValueChanged<Color> onChangeEnd;   // 松手时入栈
  // ...
  Widget build() {
    final hsv = HSVColor.fromColor(color);
    return Column([
      _buildSvPanel(hsv),        // 2D SV picker（白色 → 饱和色）
      _buildHueSlider(hsv),      // 色相条
      _buildAlphaSlider(color),  // Alpha 滑块
      _buildPreciseInput(color), // Hex / HSV / RGBA 输入
    ]);
  }
  
  Widget _buildSvPanel(HSVColor hsv) {
    return LayoutBuilder(builder: (ctx, c) {
      return GestureDetector(
        onPanDown: (d) => _updateFromSv(d.localPosition, c),
        onPanUpdate: (d) => _updateFromSv(d.localPosition, c),
        onPanEnd: (_) => widget.onChangeEnd(_currentColor),  // D3 入栈
        child: Container(
          decoration: BoxDecoration(
            gradient: RadialGradient(  // 中心白 → 边缘饱和色
              colors: [Colors.white, _hueToColor(hsv.hue)],
            ),
          ),
          child: Stack([
            // 圆点（当前选色）
            Positioned(
              left: hsv.saturation * c.maxWidth - 6,
              top: (1 - hsv.value) * c.maxHeight - 6,
              child: _pickerKnob(),
            ),
          ]),
        ),
      );
    });
  }
}
```

**性能**：
- `RepaintBoundary` 隔离重绘
- `onChanged` 仅更新本地 HSV 状态，**onChangeEnd 才入 undo 栈**（D3）
- 拖动过程不触发 `ValueNotifier` 重建，仅 picker 内部 rebuild

### 3.6 性能优化策略

| 风险 | 对策 |
|------|------|
| 用户背景图解码阻塞 | `precacheImage(FileImage)` 启动时预缓存 |
| 大图内存 | 上传校验 ≤ 10MB；缩略图 256×256；主图 `cacheWidth/cacheHeight` 限分辨率 |
| HSV 拖动高频重建 | `RepaintBoundary` 包裹 picker；`onChangeEnd` 才入栈（D3） |
| 预览骨架体积大 | 50% 缩放 + 简化结构 + `RepaintBoundary` 隔离 |
| Undo 栈爆炸 | 50 步上限（D3）；onPanEnd 入栈（非 onChanged） |
| 跨"有图/无图"主题闪烁 | `AnimatedSwitcher` 包裹背景 Image，250ms fade |
| JSON 加载阻塞启动 | `loadUserThemes()` 用 `compute()` 后台 isolate |

### 3.7 数据存储方案

**三层存储**（与 v2 一致）：
- **SharedPreferences**：`'app_theme'` 存激活主题 id；`'theme_schema_version'` 存迁移版本
- **JSON 文件**：`${appSupportDir}/user_themes/{id}.json`
- **图片文件**：`${appSupportDir}/user_backgrounds/{id}.{ext}` + 缩略图
- **`.cttheme` ZIP**（第二版 P5）：分享导出

**为什么不用 SQLite/Hive**：用户主题预期 < 50 个，JSON 文件足够；JSON 天然可读可手动编辑；避免新增依赖。

**事务性写入**：先写 `*.json.tmp` 再 `rename`，避免写入中断导致 JSON 损坏。

---

## 四、技术难点与风险，及应对方案

### 4.1 技术难点

| 难点 | 难度 | 应对方案 |
|------|------|---------|
| **D1: `CTTheme` 枚举 → String id 重构** | 🔴 高 | 保留 `CTTheme` 枚举作内置 id 来源（`CTTheme.warmSun.name == "warmSun"`）；`_currentTheme: CTTheme` → `_currentThemeId: String`；`_themes: Map<CTTheme, CTThemeData>` → `Map<String, CTThemeData>`。`AppColors` 不动。 |
| **D2: `CTThemeData` const + runtime 共存** | 🟡 中 | 6 内置主题保留 const 定义（`id` 字段为 const string）；用户主题用工厂构造 `CTThemeData.fromJson()`。`lerp` 签名不变。 |
| **D3: 预览骨架的"选择高亮"** | 🟡 中 | 选中元素套 `Container(border: Border.all(color: Colors.blue, width: 2))`；嵌套层级 opacity 0.5 focus dim；hover 用 `MouseRegion` + 半透明蓝覆盖。 |
| **D4: 自建 HSV picker 边缘 case** | 🟡 中 | 2D panel 边界 clamp；色相循环（hue = hue % 360）；alpha=0 显示棋盘格；颜色相等跳过 onChanged；4K 高 DPI 用物理像素。 |
| **D5: 元素 → 令牌映射维护** | 🟢 低 | 24 个 const 集中 `theme_element_registry.dart`；新增元素追加 1 个 const。 |
| **D6: Recent Colors 会话级（D2 决策）** | 🟢 低 | 内存存储；关闭编辑器清空；如需持久化，**第二版 P5 之后**再说。 |
| **D7: 50 步栈（D3 决策）的内存** | 🟢 低 | 50 × 约 500B = 25KB，可忽略。 |
| **D8: 同一令牌被多元素共享的 UX** | 🟡 中 | A2 决策的影响范围提示（ImpactHint）解决。 |
| **D9: BPM 下用户主题可读性** | 🟢 低 | 共享 `AppColors`，自动应用。验收抽样测试。 |
| **D10: B1 决策下两套卡片样式细节不同步** | 🟡 中 | 影响范围提示明确告知"颜色联动，样式细节不联动"。如用户要求样式也统一，推迟到 P7 组件规范项目。 |
| **D11: 单 Tab 设计（D4 决策）的扩展性** | 🟢 低 | 第一版单 Tab 无 Tab 切换；高级批量编辑 35 令牌推迟到 P7。 |

### 4.2 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| **R1: 枚举→String 重构遗漏调用点** | 中 | 高 | `flutter analyze` 0 error；6 内置全量回归；`CTTheme` 枚举保留为 `'app_theme'` key 兼容层 |
| **R2: 预览骨架与真实 UI 视觉不一致** | 中 | 中 | 验收阶段对比 ≥95% 像素；不一致清单修复；B1 决策已接受样式细节差异 |
| **R3: 24 个可编辑元素清单不够/过多** | 中 | 中 | 第一版灰度发布；收集反馈；P7 组件规范项目可增减 |
| **R4: HSV picker 在 4K 高 DPI 屏精度** | 中 | 中 | 拖动时显示精确数值；键盘 ±1 微调；用物理像素 |
| **R5: 撤销栈丢失"应用前状态"** | 中 | 中 | "应用"动作不入 undo 栈；undo 仅作用于编辑器内部调整 |
| **R6: 自建 HSV picker 第三方参考不足** | 中 | 低 | 借鉴 Figma / Sketch / Adobe Color 的交互；自建 ~300 行可控 |
| **R7: Recent Colors 会话级（D2）用户后续要求持久化** | 低 | 低 | 第二版 P5 之后用户反馈驱动；本期不预设 |
| **R8: 单 Tab 缺少高级编辑入口（D4）** | 中 | 低 | 高级批量编辑 35 令牌推迟到 P7 组件规范项目；本期不影响主流程 |
| **R9: B1 决策后两套卡片颜色混淆** | 中 | 中 | 影响范围提示明确告知"颜色联动，样式不联动"；用户后续可推动 P7 合并 |
| **R10: 两期发布间存在"未完成态"** | 低 | 低 | 第一版发布即可让 UX-27 闭合（自定义背景基础版可用）；第二版补全保存/分享/性能 |

### 4.3 回归测试重点

每个内置主题 + 至少 5 个用户主题下验证：

1. 主题切换过渡动画（250ms 无闪烁）
2. 窗口背景色同步（无白边）
3. BPM 模式应用正确
4. 启动后激活主题恢复
5. 6 内置主题视觉与升级前一致
6. **预览骨架与真实 UI 视觉一致性 ≥95%**（v3 新增验收项）
7. **24 个可编辑元素清单覆盖度 ≥90%**（v3 新增验收项）
8. **HSV picker 在 6 个色相边界无异常**（v3 新增验收项）
9. **撤销/重做 50 步无栈溢出/丢失**（v3 新增验收项，D3）
10. **Recent Colors 关闭编辑器后清空**（v3 新增验收项，D2）
11. **影响范围提示准确反映实际修改位置**（v3 新增验收项，A2）
12. **B1 决策下两套卡片颜色联动、样式不联动**（v3 新增验收项）
13. 用户主题保存/加载/删除/复制（第二版 P4）
14. `.cttheme` 导出→导入 roundtrip（第二版 P5）
15. 背景图上传/替换/移除
16. 背景图文件被删除后降级

---

## 五、分阶段开发计划（两期发布）

### 5.1 总览

| 期数 | 阶段 | 名称 | 工期 | 依赖 |
|------|------|------|------|------|
| **第一版** | P0 | 基础架构重构（id 驱动） | 3–4 天 | — |
| | P1 | 自定义背景图功能 | 2–3 天 | P0 |
| | P2 | 可编辑元素体系 + 预览骨架 | 3–4 天 | P0 |
| | P3 | WYSIWYG 调色设计器（核心） | 5–6 天 | P1, P2 |
| **小计** | | | **13–17 天** | |
| **第二版** | P4 | 主题保存/加载/管理 | 2 天 | P3 |
| | P5 | 主题分享（导入/导出） | 2–3 天 | P4 |
| | P6 | 性能优化与打磨 | 2–3 天 | P1–P5 |
| **小计** | | | **6–8 天** | |
| **总合计** | | | **19–25 天** | |
| **未来** | P7 | UI 组件规范独立项（仅范围描述） | 2–3 周 | — |

### 5.2 第一版：P0–P3（13–17 天）

#### P0：基础架构重构（3–4 天）

**目标**：枚举 → id 驱动，建立 Registry/Storage 分层，**零 UI 变化**。

**任务**：
1. `CTThemeData` 扩展：新增 `id`、`source` 字段；`backgroundImagePath` + `backgroundOverlayOpacity` 收敛为 `BackgroundImageConfig`；新增 `toJson` / `fromJson`
2. `ThemeRegistry` 新建：内置主题 id = 枚举 name
3. `ThemeStorage` 新建：JSON / 图片 / SharedPreferences
4. `AppThemeManager` 重构：`_currentTheme: CTTheme` → `_currentThemeId: String`
5. SharedPreferences 向后兼容

**里程碑 M0**：6 内置主题全量回归通过，零 UI 变化。

**验收标准**：
- 6 内置主题切换、过渡动画、持久化行为与重构前逐项一致
- `AppColors` 300+ 调用点零改动
- `CTThemeData.toJson()/fromJson()` 双向无损
- `loadSavedTheme()` 能正确读取老版本 SharedPreferences 值
- BPM 模式主题应用正常
- `flutter analyze` 0 error

---

#### P1：自定义背景图功能（2–3 天）

**任务**：
1. `BackgroundImageConfig`（`source` bundled/file/none、`filename`、`overlayOpacity`、`blurSigma`、`fit`、`alignment`）
2. `BackgroundImageResolver`：input config → output widget（`Image.asset` / `Image.file` + `ImageFiltered` blur + `Opacity` overlay）
3. `BackgroundImageStore`：`upload(File) → bgUuid`（复制到 `user_backgrounds/` + 生成缩略图）；`delete(bgUuid)`（引用计数）
4. [main_container.dart:678-725](../lib/main_container.dart#L678-L725) 渲染改造：3 层 Stack 改用 `BackgroundImageResolver`
5. [settings_modal.dart:2718-2759](../lib/widgets/settings_modal.dart#L2718-L2759) "自定义背景"占位按钮 → "管理背景"入口 + `BackgroundEditorPanel`
6. `precacheImage` 预缓存

**里程碑 M1**：用户可上传 jpg/png/gif 作为背景，重启后保留。**同时闭合 UX-27 基础版**。

**验收标准**：
- 上传 jpg/png/gif 成功应用为背景
- 遮罩透明度/模糊/填充可调且实时预览
- 背景图切换有 250ms fade 过渡
- 文件被外部删除后降级为纯色，不崩溃
- GIF 动画正常播放
- 上传 > 10MB 被拒绝并提示

---

#### P2：可编辑元素体系 + 预览骨架（3–4 天）

**任务**：
1. `ThemeElementDescriptor` / `ThemeProperty` 值对象
2. `ThemeElementRegistry` 静态注册 24 个元素（含 `impactLocations` 字段，A2 决策）
3. `EditorPreviewBuilder` 组件（50% 缩放的 UI 骨架）
4. 预览骨架与真实 UI 视觉对比测试（≥95%）
5. 元素点击/双击交互 + 选中高亮
6. **影响范围提示组件 `ImpactHint`**（A2 决策新增）

**里程碑 M2**：24 个可编辑元素清单可用，预览骨架视觉一致性 ≥95%，影响范围提示准确。

**验收标准**：
- 24 个 const 元素集中可维护
- 预览骨架与真实 UI 视觉对比 ≥95% 像素接近
- 元素点击/双击进入编辑流畅
- 选中态蓝色描边高亮
- 影响范围提示反映实际代码位置

---

#### P3：WYSIWYG 调色设计器（5–6 天，核心）

**任务**：
1. `HsvColorPicker` 自建（D1 决策）—— 2D SV + 色相条 + Alpha + Hex/HSV 输入
2. `ColorChannelPanel`（填充/描边/文字色三通道，**单 Tab 无 Tab 切换**）
3. `ThemeEditorDialog` 主体（左预览 + 右调色）
4. `RecentColorsStrip`（**会话级**，D2 决策，关闭编辑器清空）
5. `UndoRedoBar`（**50 步栈**，D3 决策 + 键盘 Ctrl+Z/Y）
6. 通道眼睛/锁切换
7. **"应用" / "保存为新主题" / "取消" 操作**（注意：第二版 P4 才实现完整"保存到主题库"）
8. [settings_modal.dart:2718-2759](../lib/widgets/settings_modal.dart#L2718-L2759) 占位按钮 → 调色板入口

**第一版边界说明**：
- 第一版 P3 只能"应用"（覆盖当前主题）和"取消"
- **"保存为新主题"** 创建用户主题（生成 UUID + 存 JSON）—— 此功能第一版实现，因为是基础能力
- **"我的主题"列表区** 第二版 P4 才在 settings 中显示入口（避免第一版 UI 看起来不完整）

**里程碑 M3**：完整 WYSIWYG 调色设计器可用。**同时完整闭合 UX-27**。

**验收标准**：
- 24 个元素均可独立编辑
- 三通道（填充/描边/文字色）独立调节
- HSV picker 拖动流畅（≥55fps）
- Recent Colors 会话级（关闭编辑器清空）
- 撤销/重做 50 步有效
- 影响范围提示准确
- "应用"触发 250ms 全应用过渡
- "保存为新主题"创建用户主题 JSON
- 通道眼睛/锁切换持久化

---

### 5.3 第二版：P4–P6（6–8 天）

#### P4：主题保存/加载/管理（2 天）

**任务**：
1. `ThemeRegistry.saveUserTheme` / `loadUserThemes` / `delete` / `duplicate`
2. **"我的主题"列表区**（第一版不显示）
3. 编辑/复制/删除/导出/导入按钮组
4. 空状态隐藏
5. 启动时 `compute()` 后台加载

**里程碑 M4**：用户主题库完整可用。

---

#### P5：主题分享（导入/导出）（2–3 天）

**任务**：
1. `CtThemePackage` ZIP 打包/解包
2. 导出/导入 UI
3. Schema 版本兼容
4. 冲突策略（新 UUID + 命名加"(导入)"）

**里程碑 M5**：用户间可通过 `.cttheme` 共享主题。

---

#### P6：性能优化与打磨（2–3 天）

**任务**：
1. `precacheImage` 策略
2. 主题卡片列表懒加载
3. 调色滑块节流 + `RepaintBoundary` 审计
4. `AnimatedSwitcher` 跨"有图/无图"过渡
5. BPM 模式下用户主题对比度验证
6. 全量回归：6 内置 + 5 用户主题 × 16 场景

**里程碑 M6**：全部性能指标达标，准备发布。

---

## 六、P7 UI 组件规范独立项（仅描述范围）

> **重要**：P7 **不在本方案实施范围内**，由 v3.0 A2 决策剥离。单独立项治理，不阻塞 P0-P6 主题编辑器主线。

### 6.1 范围描述

**目标**：建立 Chrono Tide 全应用的 UI 组件规范，解决"同一概念有 2 套独立 widget 实现"的问题。

**典型现状**：
- "游戏卡片"概念 = `_LibraryCardWidget` + `_DiscoverCardWidget` 两套独立 widget
- "对话框"概念 = 13 个独立实现（[UI_UX_UPGRADE_PLAN.md 附录 A](./UI_UX_UPGRADE_PLAN.md)）

### 6.2 工作内容（粗略）

1. **组件拆分与合并**：识别重复 widget，提取共享 base 类
2. **组件层级与命名规范**：定义 `AppCard`（base）→ `LibraryCard`、`DiscoverCard`（变体）的层级
3. **令牌重命名**：语义不清晰的令牌重命名（如 `buttonBackground` 是否要拆为 `cardBackground` / `buttonBackground`）
4. **可编辑元素清单重新映射**：合并后重新绘制 24 元素的"组件 → 令牌"映射
5. **实施 B2 决策**（如届时用户改主意）：卡片组件合并
6. **35 令牌批量编辑 UI**（v3 决策 D4 中"主题设计器 Tab" 推迟到 P7）

### 6.3 与 P0-P6 的关系

| 维度 | 关系 |
|------|------|
| 阻塞关系 | ❌ P7 不阻塞 P0-P6 |
| 依赖关系 | P7 可在 P3 后启动（编辑器已就绪） |
| 共享数据 | P7 完成后，24 元素映射需重新绘制一次（编辑器不受影响） |
| 工作量 | 预估 2-3 周 |

### 6.4 何时启动

**推荐**：
- 第一版 P3 上线后启动 P7
- 第二版 P6 完成时 P7 可同步收尾
- 第三版（含 35 令牌高级编辑）即建立在 P7 基础上

---

## 七、可行性分析

### 7.1 与现有系统的兼容性评估

| 兼容维度 | 评估 | 说明 |
|---------|------|------|
| **`AppColors` 门面** | ✅ 完全兼容 | 静态 getter 不变，300+ 调用点零改动 |
| **6 内置主题** | ✅ 完全兼容 | id = 枚举 name，行为/UI/持久化全保留 |
| **SharedPreferences** | ✅ 向后兼容 | 老 `'app_theme'` 值 = 内置主题 id |
| **`ColorScheme.fromSeed`** | ✅ 兼容 | [main.dart:719-767](../lib/main.dart#L719-L767) 从 `AppThemeManager.colors` 取色，用户主题自动流入 |
| **250ms lerp 过渡** | ✅ 保留 | `CTThemeData.lerp` 签名不变 |
| **大图模式 (BPM)** | ✅ 自动受益 | 共享 `AppColors`，用户主题自动应用 |
| **窗口背景色同步** | ✅ 兼容 | `main.dart:209,375` 监听机制不变 |
| **`pubspec.yaml` 依赖** | ✅ 无新增核心依赖（D1 决策） | HSV 自建，背景图用 `file_picker`（已有） |
| **打包脚本** | ✅ 无影响 | 无新依赖、新工具链 |
| **既有 UI_UX_UPGRADE_PLAN 修复** | ✅ 不冲突 | BUG-01/02/04/05/06 已闭合 |
| **UI_UX_UPGRADE_PLAN.md UX-27** | ✅ 完整闭合 | 占位按钮 → 完整调色设计器 |

### 7.2 B1 决策的影响（两套卡片不合并）

- 颜色层面：共用 `AppColors.background`/`AppColors.border`，改一全变
- 样式层面：两套 widget 独立硬编码，不进编辑器
- 影响范围提示明确告知"颜色联动，样式不联动"
- 用户后续可推动 P7 合并（不阻塞当前主题编辑器）

### 7.3 潜在影响范围

**直接影响（需改动）**：

| 文件 | 改动量 |
|------|-------|
| [app_theme_manager.dart](../lib/theme/app_theme_manager.dart) | 中（枚举→id 重构 + `applyCustomTheme`，~150 行） |
| [app_colors.dart](../lib/theme/app_colors.dart) | 极小 |
| [main_container.dart](../lib/main_container.dart) | 中（背景图渲染改用 `BackgroundImageResolver`，~30 行） |
| [main.dart](../lib/main.dart) | 极小（`_buildThemeData` 无需改） |
| [settings_modal.dart](../lib/widgets/settings_modal.dart) | 中（占位按钮替换 + 第二版"我的主题"区，~100 行新增） |

**新增文件**：

| 文件 | 职责 |
|------|------|
| `lib/theme/theme_element_registry.dart` | 24 个可编辑元素 + 元素→令牌映射 + **影响范围**（A2 决策） |
| `lib/theme/background_image_config.dart` | 背景图配置值对象 |
| `lib/theme/background_image_resolver.dart` | 背景图渲染 widget 工厂 |
| `lib/theme/theme_registry.dart` | 主题库 CRUD |
| `lib/theme/theme_storage.dart` | JSON/图片/SharedPreferences 存储层 |
| `lib/theme/ct_theme_package.dart` | `.cttheme` ZIP 打包/解包（第二版 P5） |
| `lib/widgets/theme_editor_dialog.dart` | 全屏调色设计器 |
| `lib/widgets/editor_preview_builder.dart` | 左侧可编辑 UI 预览骨架 |
| `lib/widgets/hsv_color_picker.dart` | **自建 HSV 调色板（D1 决策）** |
| `lib/widgets/color_channel_panel.dart` | 填充/描边/文字色面板 |
| `lib/widgets/recent_colors_strip.dart` | 最近颜色条（**会话级，D2 决策**） |
| `lib/widgets/undo_redo_bar.dart` | 撤销/重做按钮（**50 步栈，D3 决策** + 快捷键） |
| `lib/widgets/impact_hint.dart` | **影响范围提示（A2 决策）** |
| `lib/widgets/my_themes_section.dart` | "我的主题"列表区（第二版 P4） |

**间接影响（仅需回归测试）**：
- 300+ `AppColors.xxx` 调用点——消费侧零改动
- `big_picture/`——共享 AppColors，验证即可
- `sidebar.dart`、`custom_title_bar.dart`、`download_button.dart` 等——消费 AppColors，验证即可
- 打包脚本、OpenList、PocketBase、元数据抓取——**完全无影响**（主题系统与业务子系统正交）

### 7.4 可行性结论

| 维度 | 结论 |
|------|------|
| **技术可行性** | ✅ 高。所有关键决策（D1 自建、D2 会话级、D3 50 步、D4 单 Tab）已收敛到最低复杂度；架构分层清晰；24 元素映射简单可靠 |
| **架构可行性** | ✅ 高。四层架构 + 数据/UI 解耦；`CTThemeData` const+runtime 共存已规划；A2 决策将组件规范剥离避免耦合 |
| **UX 契合度** | ✅ 极高。WYSIWYG + fill/stroke/textColor 三通道符合用户设计参考与心智模型 |
| **兼容可行性** | ✅ 高。SharedPreferences 向后兼容；6 内置主题 UI 不变；BPM 自动受益；B1 决策接受卡片样式差异 |
| **性能可行性** | ✅ 高。预览骨架确定性渲染 < 16ms；HSV picker 隔离重绘；编辑器修改仅影响预览，"应用"才触发全应用；JSON 加载后台 isolate |
| **工期可行性** | ✅ 高。C1 决策分两期发布：第一版 13-17 天即可让 UX-27 完整闭合；第二版 6-8 天补全 |
| **风险可控性** | ✅ 中高。最大风险 R1（枚举→String 重构）通过 `flutter analyze` + 全量回归可控；R2（预览骨架视觉一致性）通过对比测试保障 |

**总体结论**：v3.0 方案在用户 7 项决策（A2/B1/C1/D1-D4）全部收敛的基础上，**技术路径清晰，UX 体验显著优于前代方案，分两期发布降低单次风险**。**建议立即立项进入 P0 阶段**。

---

## 八、对接交付说明（给下一个 AI 模型）

> 本节是本方案文档作为"对接交付物"的核心。下一个 AI 模型（即真正实施开发的 AI）请按本节指引开始工作。

### 8.1 方案文档元信息

| 项目 | 值 |
|------|-----|
| 文档路径 | `d:\CTLIB\docs\UI_主题系统升级方案.md` |
| 文档版本 | v3.0（最终决策版） |
| 项目根目录 | `d:\CTLIB` |
| Flutter 项目 | `d:\CTLIB\lib` |
| 当前项目版本 | Chrono Tide v1.4.5 |
| 文档日期 | 2026-07-25 |

### 8.2 决策快速回顾

| 决策 | 选择 |
|------|------|
| A2 | 组件规范剥离为 P7 独立项（不阻塞主线） |
| B1 | 库页/探索页游戏卡片不合并，颜色层面通过共享 `AppColors` 联动 |
| C1 | 第一版 P0-P3（13-17 天）→ 第二版 P4-P6（6-8 天） |
| D1 | HSV picker 自建（不引入第三方） |
| D2 | Recent Colors 会话级 |
| D3 | 撤销/重做 50 步栈 |
| D4 | 单 Tab 编辑器（无 Tab 切换） |

### 8.3 关键文件清单（实施时必读）

**核心参考**：
- [app_theme_manager.dart](../lib/theme/app_theme_manager.dart) — 553 行，主题管理核心
- [app_colors.dart](../lib/theme/app_colors.dart) — 52 行，静态门面
- [app_styles.dart](../lib/theme/app_styles.dart) — 290 行，字体排版
- [main.dart:719-767](../lib/main.dart#L719-L767) — `_buildThemeData` ColorScheme 联动
- [main_container.dart:660-733](../lib/main_container.dart#L660-L733) — 背景图渲染
- [settings_modal.dart:2398-2767](../lib/widgets/settings_modal.dart#L2398-L2767) — 主题设计器 UI

**页面背景令牌核查**（已验证）：
- [library_page.dart:1614-1618](../lib/pages/library_page.dart#L1614-L1618)
- [discover_page.dart:582-583](../lib/pages/discover_page.dart#L582-L583)
- [home_page.dart:225-226](../lib/pages/home_page.dart#L225-L226)
- [join_page.dart:298-299](../lib/pages/join_page.dart#L298-L299)
- [game_detail_page.dart:586](../lib/pages/game_detail_page.dart#L586)
- [install_center_page.dart:98-100](../lib/pages/install_center_page.dart#L98-L100)

**侧栏 3 按钮同源**（已验证）：
- [sidebar.dart:96-161](../lib/widgets/sidebar.dart#L96-L161) — `_buildNavItemExpanded` 渲染 3 次

**B1 决策相关（两套卡片不合并）**：
- [library_page.dart:2198](../lib/pages/library_page.dart#L2198) — `_LibraryCardWidget`
- [discover_page.dart:1035](../lib/pages/discover_page.dart#L1035) — `_DiscoverCardWidget`

### 8.4 不在范围内的事项

1. ❌ **不修改** 任何 6 内置主题的颜色值（`CTTheme` enum + `static const Map` 保留）
2. ❌ **不修改** `AppColors` 静态门面的 getter 签名（300+ 调用点不变）
3. ❌ **不修改** `_buildThemeData` 内部逻辑（已工作正常）
4. ❌ **不修改** 业务子系统：OpenList、PocketBase、元数据抓取、打包脚本
5. ❌ **不实施** P7 UI 组件规范（已剥离为独立项）
6. ❌ **不实施** "主题设计器 Tab" 高级批量编辑 35 令牌（D4 决策移除）
7. ❌ **不合并** `_LibraryCardWidget` 和 `_DiscoverCardWidget`（B1 决策不合并）

### 8.5 与项目硬约束的关系

本方案须严格遵守的现有项目约束（详见 `c:\Users\SteinsGate\.trae-cn\memory\projects\-d-CTLIB\project_memory.md`）：

- **打包脚本**：本方案仅新增运行时文件读写，无新依赖、无新工具链，不影响打包脚本
- **OpenList 体积优化**：D1 决策（HSV 自建）符合此理念
- **"OpenList 必须保留核心功能"**：与本方案无关
- **`AppColors` 静态门面零改动**：本方案完全遵守
- **窗口背景色同步**（`main.dart:209`）：保留
- **大图模式共享 `AppColors`**：保留（BPM 自动受益）
- **TouchGal / OpenList 简化**：与本方案无关
- **`pubspec.yaml` 依赖最小化**：D1 决策下零新增核心依赖

### 8.6 建议的启动顺序

**P0 阶段**（第一周）：

1. **第一步**：读 [app_theme_manager.dart](../lib/theme/app_theme_manager.dart) 全文，理解 `CTTheme` / `CTThemeData` / `AppThemeManager` 三个核心
2. **第二步**：读 [main.dart:719-783](../lib/main.dart#L719-L783) 全文，理解 ColorScheme 联动
3. **第三步**：读 [app_colors.dart](../lib/theme/app_colors.dart) 全文，确认所有 30+ getter
4. **第四步**：开始 P0 任务 1-5（详见 5.2 节）
5. **第五步**：P0 完成后跑 `flutter analyze` 确保 0 error，跑 6 内置主题全量回归

**P0 验收前请自检**：
- [ ] 6 内置主题切换、过渡动画、持久化与重构前一致
- [ ] `AppColors` 300+ 调用点零改动（`git diff` 应无业务侧代码变更）
- [ ] `CTThemeData.toJson()/fromJson()` 双向无损
- [ ] SharedPreferences 旧值能正确加载
- [ ] `flutter analyze` 0 error
- [ ] `flutter build windows` 成功

### 8.7 风险点提示

实施时需特别注意：

1. **`CTTheme` 枚举保留**为 `'app_theme'` SharedPreferences key 兼容层，**不要删除**
2. **`backgroundImagePath` + `backgroundOverlayOpacity` 收敛**为 `BackgroundImageConfig` 时，内置主题的 const 定义需保留
3. **24 元素的 `impactLocations` 字段**（A2 决策）是 v3.0 关键字段，**不要遗漏**
4. **D4 决策下不实施双 Tab**，高级编辑能力推迟到 P7
5. **D1 决策下 HSV 自建**，不引入 `flutter_colorpicker`
6. **B1 决策下两套卡片不合并**，但通过共享 `AppColors` 令牌实现颜色联动
7. **预览骨架与真实 UI 视觉一致性 ≥95%** 是关键验收指标，需重点关注

### 8.8 验收文档

实施完成后，请生成以下交付物：
1. 每个里程碑（M0–M6）的验收报告
2. 性能指标数据（主题切换帧率、编辑器调色延迟、启动加载耗时）
3. 回归测试报告（6 内置 + 5 用户主题 × 16 场景）
4. 用户主题示例 JSON 文件（3-5 个）用于演示
5. UI 截图（编辑器主界面、3 通道填色、Recent Colors、撤销栈、影响范围提示）

---

## 附录 A：v1 → v2 → v3 心智模型对照

| 用户表达 | v1（表单） | v2（双 Tab WYSIWYG） | v3（单 Tab WYSIWYG，定版） |
|---------|-----------|---------------------|--------------------------|
| "我想把侧栏改成蓝色" | 找"侧栏背景"令牌 → 改色 | 双击预览中的侧栏 → 右侧改 fill | **双击预览中的侧栏 → 右侧改 fill（单 Tab）** |
| "我想让按钮有描边" | 找"按钮边框"令牌 | 双击按钮 → 右侧改 stroke | **同 v2** |
| "金色星标太暗了" | 找"starGold"令牌 | 双击星标 → 右侧改 fill | **同 v2** |
| "改这个怎么这么多地方变了？" | 不提示 | 不提示 | **影响范围提示（ImpactHint，A2）** |
| "改坏想撤回" | 不支持 | Ctrl+Z 50 步 | **Ctrl+Z 50 步（D3）** |
| "记得那个好看的红" | 不支持 | Recent Colors | **Recent Colors（会话级，D2）** |
| "我想要主题设计器高级编辑" | —— | 双 Tab 之"主题设计器" | **不实施（D4），推迟 P7** |

## 附录 B：24 个可编辑元素速查表

```
应用窗口背景       app_window          background              fill
侧栏               app_sidebar         sidebarBackground+borderLight  fill+stroke
标题栏             app_titlebar        titleBarBackground       fill
标题栏文字         app_titlebar_text   primaryText              textColor
侧栏大标题         sidebar_title       titleBrown               textColor
侧栏激活按钮       nav_active          navActiveBg+navActiveBorder  fill+stroke+textColor
侧栏非激活按钮     nav_inactive        navInactiveBorder+cardHoverBg  stroke+fill
主页按钮           home_button         cardHoverBg+border       fill+stroke
游戏卡片           app_card            buttonBackground+border  fill+stroke  ⚠B1 两套 widget 颜色联动
卡片封面占位       card_cover_placeholder  placeholderCover     fill
卡片标题           card_title          primaryText              textColor
主题强调色         accent_color        selectedAccent           fill
全局边框           border_global       border                   fill
全局浅边框         border_light_global borderLight              fill
通用按钮背景       button_bg           buttonBackground         fill
通用按钮文字       button_text         primaryText              textColor
主要文字           text_primary        primaryText              textColor
次要文字           text_secondary      secondaryText            textColor
占位文字           text_placeholder    placeholderText          textColor
成功状态           state_success       successGreen+successBg   fill×2
危险状态           state_danger        dangerRed+errorBg+hoverCloseBg+hoverCloseBorder  fill×4
信息状态           state_info          infoBlue+infoBg+brandBlue  fill×3
星级金色           state_star          starGold                 fill
应用背景图         app_background_image backgroundImageConfig   独立控件
```

## 附录 C：变更历史

| 版本 | 日期 | 主要变化 |
|------|------|---------|
| v1.0 | 2026-07-25 | 初版：表单化分组调色面板（6 大分组，35+ 令牌），**已废止** |
| v2.0 | 2026-07-25 | 重大转向 WYSIWYG 调色设计器；引入双 Tab、三通道、Recent Colors、撤销栈、24 元素清单、影响范围提示、组件规范 |
| **v3.0** | 2026-07-25 | **决策定版**：移除"主题设计器 Tab"（D4）；明确 HSV 自建（D1）、Recent Colors 会话级（D2）、50 步撤销（D3）；剥离组件规范为 P7（A2）；允许卡片组件不合并（B1）；分两期发布（C1）；新增"对接交付说明"章节 |

---

*本方案基于 2026-07-25 代码版本（v1.4.5）生成，整合 Figma 615_2/615_560 设计参考与用户决策。仅作方案交付物，不涉及任何代码或文件修改。下一步：进入 P0 实施阶段。*
