# CTLIB UI 规格文档 — Figma AI 1:1 复刻用

> **用途**：把当前 CTLIB 软件的 UI 1:1 复刻到 Figma 中，供后续设计调整。
> **使用方式**：
> 1. 在 Figma 中打开 **Make AI** / **Figma AI** 生成面板
> 2. 按本文档顺序，每个「Figma AI Prompt」代码块整段复制粘贴
> 3. 默认主题为 **暖阳（warmSun）**，所有 hex 已解析。如需其他主题，把第二节《设计令牌》中对应主题的颜色替换进 prompt 即可
> 4. 一次生成一个屏幕，生成后手动微调对齐即可
>
> **字体提醒**：UI 字体 `Inter`、中文装饰体 `ZhiMangXing`（书法体）、英文装饰体 `Mali`（手写体）。Figma 中需先安装这三种字体（或用相近替代：装饰中文可用 `Ma Shan Zheng`，装饰英文可用 `Gloria Hallelujah`）。

---

## 一、设计令牌总览（warmSun 暖阳主题 · 默认）

### 颜色令牌（已解析为 hex）

| 令牌名 | Hex | 用途 |
|---|---|---|
| background | `#FDFBF7` | 页面主背景 |
| sidebarBackground | `#FBF6EF` | 侧边栏/标题栏背景 |
| titleBarBackground | `#FBF6EF` | 标题栏背景 |
| primaryText | `#5C4A3D` | 主文字色 |
| secondaryText | `#7D6348` | 次要文字色 |
| border | `#8B7355` | 主边框色 |
| borderLight | `#8B7355` 20% 不透明 | 浅边框/分割线 |
| buttonBackground | `#F0E6D2` | 默认按钮背景 |
| selectedAccent | `#B4D4FF` | 选中强调色 |
| dangerRed | `#D4183D` | 危险/删除 |
| placeholderText | `#9A8A76` | 占位文字 |
| placeholderBg | `#F5F1E8` | 占位背景 |
| placeholderCover | `#E9E0D1` | 封面占位 |
| addCoverBg | `#E9E0D1` | 添加封面背景 |
| shadowColor | `#8B7355` 25% 不透明 | 阴影色 |
| successGreen | `#4CAF50` | 成功状态 |
| successBg | `#E8F5E9` | 成功背景 |
| errorBg | `#FFE6EA` | 错误背景 |
| hoverCloseBg | `#FFEBEE` | 关闭按钮 hover 背景 |
| hoverCloseBorder | `#EF5350` | 关闭按钮 hover 边框 |
| inputHint | `#7D6348` 60% 不透明 | 输入提示 |
| cardHoverBg | `#F5EDE6` | 卡片 hover 背景 |
| navActiveBg | `#FFFFFF` | 导航激活背景 |
| navActiveBorder | `#A07840` | 导航激活边框 |
| navInactiveBorder | `#C8B49A` | 导航未激活边框 |
| toggleBg | `#E8E0D0` | 开关未启用背景 |
| toggleBorder | `#C8B49A` | 开关边框 |
| toggleIcon | `#5C3A1A` | 开关图标色 |
| titleBrown | `#5C4A3D` | 标题棕色 |
| starGold | `#D4A017` | 评分金星 |
| infoBlue | `#4A72A5` | 信息蓝 |
| brandBlue | `#6B9EAD` | 品牌蓝 |
| infoBg | `#E6F0FF` | 信息按钮浅蓝背景 |

### 其他主题（仅列关键色，按需替换进 prompt）

| 主题 | 亮度 | background | sidebarBg | primaryText | secondaryText | border | buttonBg | selectedAccent |
|---|---|---|---|---|---|---|---|---|
| 🌞 暖阳 warmSun | light | `#FDFBF7` | `#FBF6EF` | `#5C4A3D` | `#7D6348` | `#8B7355` | `#F0E6D2` | `#B4D4FF` |
| 🌙 暗夜 darkNight | dark | `#1A1714` | `#242019` | `#E8E0D0` | `#9B9080` | `#3D3530` | `#2D2824` | `#5A7A9B` |
| 🌊 墨绿金 mint | dark | `#1A3D35` | `#15302A` | `#F0F4EC` | `#B8D4C0` | `#4A9B6A` | `#D4AF37` 60% | `#E8C84A` |
| 🌸 樱花 sakura | light | `#FDF2F6` | `#F9ECF1` | `#5C2E3E` | `#8C5570` | `#D4849A` | `#FFB7C5` 80% | `#E88BA0` |
| ☁️ 蓝天白云 ocean | light | `#E8F4FC` | `#DEEBF7` | `#2A4A6A` | `#4A6E88` | `#7BAACC` | `#E8F4FC` 75% | `#4A90D9` |
| 🔮 暮光 twilight | dark | `#1A1520` | `#241D2A` | `#E0D8E8` | `#9B8AA8` | `#4A3D55` | `#2D2435` | `#7A6A9B` |

> 完整 36 令牌的 6 主题映射见源码 `lib/theme/app_theme_manager.dart` 第 185-441 行。

### 字体排版阶（Inter 为 UI 主字体）

| 样式名 | 字体 | 字号 | 字重 | 行高 | 字距 | 颜色 | 用途 |
|---|---|---|---|---|---|---|---|
| displayLarge | ZhiMangXing | 36 | Regular | 44 | 1.5 | primaryText | 装饰性大标题 |
| displayMedium | ZhiMangXing | 28 | Regular | 36 | 1.5 | primaryText | 装饰性中标题 |
| displaySmall | ZhiMangXing | 24 | Regular | 32 | 1.2 | primaryText | 装饰性小标题 |
| headlineLarge | ZhiMangXing | 26 | Regular | 34 | 2.0 | primaryText | 区域大标题 |
| headlineMedium | ZhiMangXing | 24 | Regular | 32 | 2.2 | primaryText | 区域标题 |
| headlineSmall | ZhiMangXing | 22 | Regular | 28 | 1.8 | primaryText | 区域小标题 |
| titleLarge | ZhiMangXing | 30 | Regular | 36 | 2.0 | primaryText | 页面大标题 |
| heading | ZhiMangXing | 24 | Regular | 32 | 2.4 | primaryText | 页面标题 |
| titleMedium | Inter | 16 | SemiBold(600) | 24 | 0.5 | primaryText | 功能性标题/导航激活 |
| titleSmall | Inter | 14 | SemiBold(600) | 20 | 0.4 | primaryText | 卡片标题 |
| bodyLarge | Inter | 16 | Regular | 24 | — | primaryText | 大正文 |
| bodyMedium | Inter | 14 | Regular | 20 | — | primaryText | 正文 |
| bodySmall | Inter | 12 | Regular | 16 | — | secondaryText | 小正文 |
| bodyRegular | Inter | 14 | Regular | 20 | — | secondaryText | 次要正文 |
| dialogBody | Inter | 15 | Regular | 22 | — | primaryText | 对话框正文 |
| hintRegular | Inter | 13 | Regular | 18 | — | secondaryText | 辅助说明 |
| labelLarge | Inter | 14 | SemiBold(600) | 20 | 0.5 | primaryText | 按钮标签 |
| labelMedium | Inter | 12 | Medium(500) | 16 | 0.4 | secondaryText | 标签 |
| labelSmall | Inter | 11 | Medium(500) | 14 | 0.4 | secondaryText | 小标签 |
| caption | Inter | 12 | Regular | 16 | — | secondaryText | 说明文字 |
| microCaption | Inter | 10 | Regular | 14 | — | secondaryText | 时间戳/版本号 |
| navActive | Inter | 16 | SemiBold(600) | 24 | 0.5 | primaryText | 导航激活 |
| navInactive | Inter | 16 | Medium(500) | 24 | 0.5 | secondaryText | 导航未激活 |
| buttonText | Inter | 15 | Medium(500) | 22 | — | primaryText | 按钮文字 |
| inputPlaceholder | Inter | 14 | Regular | 20 | — | placeholderText | 输入占位 |
| gameTitle | Inter | 14 | SemiBold(600) | 20 | — | primaryText | 游戏标题 |
| decorativeNumber | Mali | 20 | Regular | 28 | — | primaryText | 装饰性数字 |

### 间距 / 圆角 / 断点

**间距（4px 基线网格）**：xs=4 · sm=8 · md=12 · lg=16 · xl=24 · xxl=32 · xxxl=48
**圆角**：xs=2 · sm=4 · md=8 · lg=12 · xl=16 · pill=20
**响应式断点**：compact <960 · medium <1280 · expanded <1920 · large ≥1920
**全局常量**：标题栏高度 `kTitleBarHeight = 32px`

---

## 二、核心可复用组件（先在 Figma 建立这些 Component，后续屏幕复用）

### 2.1 主按钮（Primary Button）

```
Create a Figma Component named "Button/Primary":
- Frame, Auto Layout Horizontal, padding 16x10, gap 8, align center
- Fill: #F0E6D2 (buttonBackground)
- Stroke: #8B7355 (border), 1.5px, inside
- Corner radius: 8px
- Drop shadow: color #8B7355 at 25% opacity, offset 0x2, blur 6
- Child 1: Icon (24x24, color #5C4A3D)
- Child 2: Text, font Inter, size 15, weight 500, line-height 22, color #5C4A3D
- Variants: Hover (fill #F5EDE6), Disabled (50% opacity), Danger (fill #FFE6EA, stroke #D4183D, text #D4183D)
```

### 2.2 次按钮 / 信息按钮（Info Button）

```
Create a Figma Component named "Button/Info":
- Frame, Auto Layout Horizontal, padding 16x10, gap 8
- Fill: #E6F0FF (infoBg)
- Stroke: #4A72A5 (infoBlue), 1.5px
- Corner radius: 8px
- Text: Inter 15 weight 500, color #4A72A5
- Icon: 24x24, color #4A72A5
```

### 2.3 文本输入框（Text Input）

```
Create a Figma Component named "Input/Text":
- Frame, width 442, height 47, Auto Layout Horizontal, padding 14x11
- Fill: #FBF6EF (sidebarBackground)
- Stroke: #8B7355 (border), 1.6px, inside
- Corner radius: 8px
- Placeholder text: Inter 16 Regular, color #7D6348 at 60% opacity (inputHint)
- Variants: Focus (stroke #A07840 2px), Error (stroke #D4183D, helper text #D4183D below), Disabled (50% opacity)
- Optional prefix/suffix icon slot at 20x20
```

### 2.4 开关（Toggle Switch）

```
Create a Figma Component named "Toggle":
- Frame width 44, height 24, Auto Layout Horizontal, padding 2
- Off variant: Fill #E8E0D0 (toggleBg), Stroke #C8B49A (toggleBorder) 1.6px, thumb position left, thumb 20x20 fill #FBF6EF stroke #C8B49A
- On variant: Fill #B4D4FF (selectedAccent), thumb position right, thumb 20x20 fill #FFFFFF
- Corner radius: pill (20px) on track, full on thumb
```

### 2.5 标签芯片（Tag Chip）

```
Create a Figma Component named "Tag/Chip":
- Frame, Auto Layout Horizontal, padding 10x6, gap 4
- Fill: #F0E6D2 (buttonBackground) at 70% opacity
- Stroke: none
- Corner radius: 12px (pill-ish)
- Text: Inter 12 Medium, color #5C4A3D (primaryText)
- Variants: Active (fill #B4D4FF, stroke #4A72A5), Removable (with 12x12 close icon)
```

### 2.6 游戏卡片（Game Card · 库/发现页通用）

```
Create a Figma Component named "GameCard" with variants (Default, Hover, Selected, Blur, EditMode):
- Frame width 200, Auto Layout Vertical, gap 8
- Fill: #FBF6EF (sidebarBackground)
- Stroke: #C8B49A (navInactiveBorder), 1px
- Corner radius: 12px
- Drop shadow: #8B7355 at 25%, offset 0x2, blur 6
- Child 1: Cover image frame, width 200, height 280 (aspect 5:7), corner radius 8 (top only), fill #E9E0D1 (placeholderCover) when empty, image fit cover
- Child 2: Info area, Auto Layout Vertical, padding 8x6, gap 4
  - Title: Inter 14 SemiBold, color #5C4A3D, max 1 line
  - Subtitle (会社/年份): Inter 12 Regular, color #7D6348, max 1 line
  - Footer row: Auto Layout Horizontal, gap 4
    - Playtime chip: Inter 11 Regular, color #7D6348, fill #F0E6D2, padding 6x2, radius 4
    - Status dot: 6x6 circle, #4CAF50 (installed) / #D4A017 (update) / #9A8A76 (not installed)
- Variants:
  - Hover: fill #F5EDE6 (cardHoverBg), shadow offset 0x4 blur 10, scale 1.02
  - Selected: stroke #A07840 (navActiveBorder) 2px, top-right check icon 20x20 in circle fill #A07840
  - Blur: cover image blur 4px, dark overlay #5C4A3D at 40%, lock icon center
  - EditMode: top-left checkbox 20x20, stroke #8B7355; when checked fill #A07840 with white check
```

### 2.7 导航项（Sidebar Nav Item · 展开态）

```
Create a Figma Component named "NavItem/Expanded" with variants (Active, Inactive, Hover):
- Frame width 160, height 48, Auto Layout Horizontal, padding 16x0, gap 12, align center-left
- Active variant: Fill #FFFFFF (navActiveBg), Stroke #A07840 (navActiveBorder) 1.5px left side only (left accent bar), corner radius 8px
- Inactive variant: Fill transparent, Stroke #C8B49A (navInactiveBorder) 1px left side only, corner radius 8px
- Hover (on inactive): Fill #F5EDE6 (cardHoverBg)
- Child 1: Icon 24x24, color #5C4A3D (active) or #7D6348 (inactive)
- Child 2: Label text, Inter 16 SemiBold (active, primaryText) or Inter 16 Medium (inactive, secondaryText)
```

### 2.8 窗口控制按钮（Window Control Button）

```
Create a Figma Component named "WinButton" with variants (Minimize, Maximize, Close, Hover):
- Frame 32x32, align center
- Fill: transparent
- Child: Icon 16x16, color #5C4A3D, stroke 1.5px
  - Minimize: horizontal line
  - Maximize: square outline
  - Close: X
- Hover variants:
  - Minimize/Maximize hover: Fill #F0E6D2 (buttonBackground)
  - Close hover: Fill #FFEBEE (hoverCloseBg), icon color #EF5350 (hoverCloseBorder)
```

---

## 三、屏幕级 Figma AI Prompt（逐屏复制使用）

> 以下每段都自包含 hex 值，可直接粘贴给 Figma AI。建议每个屏幕新建一个 Page 生成。

### 3.1 应用主壳：标题栏 + 侧边栏 + 主内容容器

```
Create a desktop app window frame at 1440x900, Auto Layout Vertical, fill #FDFBF7:

1. Title bar (Frame width 1440, height 32, Auto Layout Horizontal, align center, padding 0x12, fill #FBF6EF, stroke bottom #8B7355 1px):
   - Left: App logo icon 20x20 + app name "CTLIB" (Inter 13 SemiBold, color #5C4A3D), gap 8
   - Center: empty
   - Right: 3 window control buttons each 32x32 (Minimize, Maximize, Close). Close button hover state fill #FFEBEE with #EF5350 X icon. Minimize/Maximize hover fill #F0E6D2.

2. Body (Frame width 1440, height 868, Auto Layout Horizontal):
   - Sidebar (Frame width 200, height 868, Auto Layout Vertical, fill #FBF6EF, stroke right #8B7355 1px, drop shadow #8B7355 25% offset 2x0 blur 6, padding 16x12, gap 8):
     - Top: User profile area (Frame Auto Layout Horizontal, gap 10, padding 8)
       - Avatar 36x36 circle, fill #E9E0D1, stroke #8B7355 1.5px
       - Vertical: Username "玩家" (Inter 14 SemiBold #5C4A3D) + subtitle "已登录" (Inter 11 Regular #7D6348)
     - Divider: 1px #8B7355 at 20% opacity
     - Nav items (use NavItem/Expanded component), in order:
       - 🏠 首页 (Home) — active state
       - 🎮 游戏库 (Library)
       - 🌟 发现 (Discover)
       - ➕ 加入 (Join)
       - ⬇️ 安装中心 (Install Center)
     - Spacer
     - Bottom: Settings button (齿轮 icon 24x24 + "设置" Inter 14 Medium #7D6348), Big Picture Mode entry button (24x24 icon, positioned in blank space next to settings)
   - Content area (Frame width 1240, height 868, fill #FDFBF7, clip content) — placeholder for page content
```

### 3.2 首页（Home Page）

```
Create the Home page inside a 1240x868 frame, fill #FDFBF7, padding 24, Auto Layout Vertical, gap 16, scroll vertical:

When user has games — two-column layout (Auto Layout Horizontal, gap 24):

LEFT COLUMN (width 360, Auto Layout Vertical, gap 16):
- Page title row: "首页" (font ZhiMangXing 30 Regular, color #5C4A3D, letter-spacing 2.0)
- Cover card (Frame 180x240, corner radius 10, stroke #8B7355 2px, drop shadow #8B7355 25% offset 0x4 blur 12, cover image fit cover, behind it a blurred copy of same cover as background at 60% opacity)
- Info tags row (Auto Layout Horizontal, gap 8): 3-4 tag chips (use Tag/Chip component) showing 品牌/类型/年份
- Action button column (gap 8): Primary "▶ 启动游戏" button (full width, height 44), Secondary "详情" info button (full width, height 40)

RIGHT COLUMN (width fills, Auto Layout Vertical, gap 16):
- Section title "最近游玩" (Inter 16 SemiBold #5C4A3D)
- Stats cards row (Auto Layout Horizontal, gap 12): 3 stat cards each (Frame, Auto Layout Vertical, padding 16, fill #FBF6EF, stroke #8B7355 1px, radius 12, gap 4):
  - Stat 1: Icon 24x24 #4A72A5, Value "12.5h" (Mali 20 Regular #5C4A3D), Label "总游玩时长" (Inter 11 Regular #7D6348)
  - Stat 2: Icon 24x24 #6B9EAD, Value "3" (Mali 20), Label "游戏数量"
  - Stat 3: Icon 24x24 #D4A017, Value "2天前" (Mali 20), Label "上次游玩"
- Section title "游戏列表" (Inter 16 SemiBold #5C4A3D)
- Horizontal scroll of recent game cards (use GameCard component at 160x220), gap 12
- Bottom-right fixed: Play stats panel (Frame 280x180, fill #FBF6EF at 90% opacity, stroke #8B7355 1px, radius 12, padding 16, drop shadow) showing weekly play chart (simple bar chart with #B4D4FF bars)

Empty state (when no games): Centered Auto Layout Vertical, gap 16, align center:
- Illustration 120x120 (placeholder game controller icon, color #9A8A76)
- Title "还没有游戏" (Inter 18 SemiBold #5C4A3D)
- Subtitle "点击侧边栏「加入」开始导入你的游戏库" (Inter 14 Regular #7D6348)
- CTA button "前往加入" (use Button/Primary)
```

### 3.3 游戏库页（Library Page）

```
Create the Library page inside a 1240x868 frame, fill #FDFBF7, padding 20, Auto Layout Vertical, gap 12:

TOP TOOLBAR (Frame width 1200, height 48, Auto Layout Horizontal, gap 12, align center, padding 0x4):
- Search input (Frame width 320, height 40, fill #FBF6EF, stroke #8B7355 1.6px, radius 8, padding 12x10, Auto Layout Horizontal gap 8): search icon 18x18 #7D6348 + placeholder "搜索游戏..." Inter 14 Regular #9A8A76
- Sort dropdown (Frame 140x40, fill #FBF6EF, stroke #8B7355 1.6px, radius 8, padding 12x10): "按名称" Inter 14 + chevron-down icon
- Filter button (Frame 40x40, stroke #8B7355 1.6px, radius 8): filter icon 20x20
- View mode toggle (Frame 80x40, Auto Layout Horizontal, stroke #8B7355 1.6px, radius 8, split into 2 cells 40x40 each): grid icon + list icon, active cell fill #F0E6D2
- Spacer
- Batch import button (use Button/Primary with "📥 批量导入" label)
- Add game button (use Button/Primary with "➕ 添加游戏" label)

CONTENT GRID (Frame, Auto Layout Vertical, gap 16):
- GridView, max card width 200, cross-axis count responsive (compact=3, medium=4, expanded=5, large=6), gap 16
- Each cell: use GameCard component (200x340 with cover 200x280)

EDIT MODE BOTTOM BAR (overlay Frame width 1200, height 60, fill #FBF6EF, stroke top #8B7355 1.5px, drop shadow #8B7355 25% offset 0x-2 blur 8, padding 16x0, Auto Layout Horizontal gap 12, align center):
- Left: "已选 3 项" (Inter 14 SemiBold #5C4A3D)
- Spacer
- Action buttons row (gap 8): "全选" / "取消" (text buttons) + "🏷 标记" + "🔞 模糊" + "🗑 删除" (danger) + "🔗 快捷方式" (use Button variants)

EMPTY STATE: Centered Auto Layout Vertical gap 16:
- Icon 120x120 #9A8A76 (empty box illustration)
- "游戏库还是空的" (Inter 18 SemiBold #5C4A3D)
- "通过侧边栏「加入」或上方「批量导入」添加游戏" (Inter 14 Regular #7D6348)
- "前往探索" button (use Button/Info)
```

### 3.4 发现页（Discover Page）

```
Create the Discover page inside a 1240x868 frame, fill #FDFBF7, padding 20, Auto Layout Vertical, gap 16, scroll vertical:

HEADER (Auto Layout Vertical, gap 12):
- Title row: "发现" (ZhiMangXing 30 Regular #5C4A3D letter-spacing 2.0) + right-aligned disclaimer/info icon button 24x24 #4A72A5
- Search bar (Frame width 1200, height 44, fill #FBF6EF, stroke #8B7355 1.6px, radius 10, padding 14x12, Auto Layout Horizontal gap 10): search icon 20x20 + placeholder "搜索游戏名/标签/品牌..." Inter 15 Regular #9A8A76
- Tag filter row (Auto Layout Horizontal, gap 8, scroll horizontal): 8-12 tag chips (use Tag/Chip), first chip "全部" in active state (fill #B4D4FF stroke #4A72A5)
- Sort row (Auto Layout Horizontal, gap 12): "热门" / "最新" / "评分" segmented control (3 cells, active cell fill #F0E6D2 stroke #8B7355)

CONTENT GRID (Frame, Auto Layout Vertical, gap 24):
- GridView, card size 240x360 (cover 240x320 aspect 3:4), gap 24, cross-axis count responsive
- Each card: cover image (radius 12 top), title (Inter 14 SemiBold #5C4A3D), brand (Inter 12 Regular #7D6348), top-right "已安装" badge when applicable (fill #E8F5E9, text #4CAF50, radius 4, padding 6x2)
- Hover state: scale 1.03, drop shadow stronger, show quick-action overlay (heart + download icons)

DISCLAIMER DIALOG (separate frame, modal): Frame 480x320, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, padding 24, Auto Layout Vertical gap 16:
- Title "内容声明" (Inter 18 SemiBold #5C4A3D)
- Body text (Inter 14 Regular #7D6348, line-height 22): 3-4 lines disclaimer about adult content
- Action row: "我已了解" primary button + "不再显示" checkbox
```

### 3.5 安装中心（Install Center Page）

```
Create the Install Center as a full-screen overlay 1240x868, fill #FDFBF7 at 95% opacity (modal feel), centered content card:

CENTERED CARD (Frame 800x500, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, drop shadow #8B7355 30% offset 0x8 blur 24, padding 32, Auto Layout Vertical gap 24):

HEADER ROW (Auto Layout Horizontal, align center):
- Title "安装中心" (ZhiMangXing 24 Regular #5C4A3D)
- Spacer
- Close button 32x32 (use WinButton/Close)

CONTENT (Auto Layout Horizontal, gap 32):

LEFT — Task preview (Frame width 280, Auto Layout Vertical, gap 16, align center):
- Cover image 200x280, radius 12, stroke #8B7355 1px, drop shadow. If downloading, slow rotation animation (note as comment)
- Title "游戏名称" (Inter 16 SemiBold #5C4A3D, center)
- Tag chips row (gap 6): version + size

RIGHT — Status panel (Frame width fills, Auto Layout Vertical, gap 20, align center, justify center):

State: Downloading
- Circular progress ring 120x120, stroke 8px, track #F0E6D2, progress #4A72A5, center text "65%" (Mali 24 #5C4A3D)
- Status label "下载中..." (Inter 14 Medium #7D6348)
- Speed text "2.4 MB/s · 剩余 3:25" (Inter 12 Regular #9A8A76)
- Linear progress bar (Frame width 300, height 6, fill #F0E6D2, inner fill #4A72A5 65%)
- Action row: "暂停" + "取消" (use Button/Info + danger text button)

State: Complete
- Success icon 80x80 circle fill #E8F5E9, check #4CAF50
- "安装完成" (Inter 18 SemiBold #5C4A3D)
- Description (Inter 13 Regular #7D6348)
- "打开库" primary button

State: Failed
- Error icon 80x80 circle fill #FFE6EA, X #D4183D
- "安装失败" (Inter 18 SemiBold #D4183D)
- Error description (Inter 13 Regular #7D6348, max 3 lines)
- Action row: "重试" (primary) + "关闭" (text)

EMPTY STATE: Centered Auto Layout Vertical gap 16:
- Icon 100x100 #9A8A76 (download icon)
- "暂无安装任务" (Inter 16 SemiBold #5C4A3D)
- "前往发现页下载游戏" (Inter 13 Regular #7D6348)
```

### 3.6 加入页（Join Page · 导入游戏）

```
Create the Join page inside a 1240x868 frame, fill #FDFBF7, padding 24, Auto Layout Vertical, gap 16:

HEADER: Title "加入游戏" (ZhiMangXing 30 Regular #5C4A3D letter-spacing 2.0)

TWO-COLUMN BODY (Auto Layout Horizontal, gap 24):

LEFT COLUMN (width 480, Auto Layout Vertical, gap 16, padding 16, fill #FBF6EF, stroke #8B7355 1px, radius 12):
- Section "游戏信息" (Inter 16 SemiBold #5C4A3D)
- Cover upload area (Frame 200x280, dashed stroke #C8B49A 2px, radius 12, fill #E9E0D1, align center): placeholder icon 40x40 #9A8A76 + "点击或拖拽封面" (Inter 12 #9A8A76)
- Form fields (Auto Layout Vertical, gap 12):
  - "游戏名称" label (Inter 13 Medium #5C4A3D) + text input (use Input/Text)
  - "开发商" label + text input
  - "标签" label + text input with hint "用逗号分隔"
- Screenshots carousel (Frame width 440, height 120, Auto Layout Horizontal gap 8, scroll horizontal): 4-5 thumbnail frames 160x90, radius 8, stroke #8B7355 1px, fill #E9E0D1 placeholder
- "游戏简介" label + multiline text area (Frame width 440, height 100, fill #FBF6EF, stroke #8B7355 1.6px, radius 8, padding 12)

RIGHT COLUMN (width fills, Auto Layout Vertical, gap 16):
- Section "导入设置" (Inter 16 SemiBold #5C4A3D)
- Path picker card (Frame, fill #FBF6EF, stroke #8B7355 1px, radius 12, padding 16, Auto Layout Vertical gap 10):
  - Label "游戏路径" (Inter 13 Medium #5C4A3D)
  - Row: text input (width fills, height 40, read-only style) + "浏览..." button (use Button/Info) + "批量导入" button (use Button/Primary)
  - Helper text "支持识别 .exe / 启动器 / 压缩包" (Inter 11 #7D6348)
- Import mode switcher (3 segmented cells, Auto Layout Horizontal, stroke #8B7355 1.6px, radius 8, each cell 120x44):
  - "智能识别" (active, fill #F0E6D2)
  - "手动指定"
  - "压缩包导入"
- Metadata fetch card (Frame, fill #FBF6EF, stroke #8B7355 1px, radius 12, padding 16, gap 12):
  - Row: "自动抓取元数据" label + Toggle (on state)
  - Row: "数据源设置" link button (use Button/Info, "⚙ 配置")
  - Helper text "已启用: VNDB / Bangumi / DLsite / Steam / ErogameScape / Ymgal (TouchGal 默认禁用)" (Inter 11 #7D6348)
- Spacer
- Bottom action bar (Auto Layout Horizontal, gap 12, align right):
  - "取消" text button
  - "确认导入" primary button (use Button/Primary with "✓ 确认导入")

BATCH IMPORT MODE (when 批量导入 active, replaces left column with):
- Folder drop zone (Frame width 440, height 200, dashed stroke #C8B49A 2px, radius 12, fill #F5F1E8, align center, gap 12): folder icon 60x60 #9A8A76 + "拖拽游戏文件夹到此处" (Inter 14 Medium #7D6348) + "或点击选择文件夹" (Inter 12 #9A8A76)
- Scan results list (Auto Layout Vertical, gap 8): each row shows detected game folder name + matched exe + confidence chip (高/中/低 color coded)
```

### 3.7 游戏详情对话框（Game Detail Dialog）

```
Create a modal dialog Frame 960x680, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, drop shadow #8B7355 30% offset 0x12 blur 32, padding 0, Auto Layout Horizontal:

LEFT PANEL (Frame width 340, height 680, Auto Layout Vertical, padding 24, gap 16, align center):
- Cover image (Frame 280x392 aspect 5:7, radius 12, stroke #8B7355 1.5px, drop shadow #8B7355 25% offset 0x4 blur 12, cover image fit cover)
- Edit cover button (small, below cover, Frame 280x32, fill #E9E0D1, stroke #8B7355 1px, radius 6, Inter 12 #5C4A3D "✎ 更换封面")
- Primary launch button (Frame 280x48, fill #F0E6D2, stroke #8B7355 1.5px, radius 8, Auto Layout Horizontal gap 8 align center): "▶ 启动" (Inter 16 SemiBold #5C4A3D) + chevron-down icon 16x16 (dropdown indicator)
  - Dropdown menu (when expanded): 4 items (普通启动 / 日语转区 / 超分启动 / 超分+转区), each Frame 280x40 fill #FBF6EF stroke #8B7355 1px top border only, Inter 14 #5C4A3D
- Secondary action row (gap 8): "📁 打开目录" + "📄 详情页" (use Button/Info, width fills, height 40)

RIGHT PANEL (Frame width 620, height 680, Auto Layout Vertical, padding 24, gap 16, scroll vertical):
- Header row (Auto Layout Horizontal, align center):
  - Title "游戏标题" (ZhiMangXing 26 Regular #5C4A3D letter-spacing 2.0)
  - Spacer
  - Close button 32x32 (use WinButton/Close)
- Subtitle "开发商 · 发行商 · 发售日" (Inter 13 Regular #7D6348)
- Metadata table (Frame, Auto Layout Vertical, gap 0, stroke #8B7355 at 20% 1px between rows):
  - Row 1 (Frame 572x36, padding 8x0, Auto Layout Horizontal): Label "来源" (Inter 12 Medium #7D6348 width 100) + Value "Steam" (Inter 13 Regular #5C4A3D)
  - Row 2: "安装日期" / "2026-07-19"
  - Row 3: "目录" / "D:\Games\..."
  - Row 4: "占用空间" / "12.4 GB"
  - Row 5: "会社" / "..."
  - Row 6: "评分" / star icon #D4A017 + "8.5" (Inter 13 SemiBold #5C4A3D)
- Play record sub-card (Frame, fill #FDFBF7, stroke #8B7355 at 20% 1px, radius 8, padding 12, Auto Layout Horizontal gap 24):
  - Item: "首次游玩" (Inter 11 #7D6348) + "2026-07-01" (Inter 13 Medium #5C4A3D)
  - Item: "最后游玩" (Inter 11 #7D6348) + "2天前" (Inter 13 Medium #5C4A3D)
  - Item: "总时长" (Inter 11 #7D6348) + "12.5h" (Inter 13 Medium #5C4A3D)
- Tags section: "标签" label + Auto Layout Horizontal wrap gap 6: 8-12 tag chips (use Tag/Chip) + "展开" text button when collapsed
- Screenshots carousel (Frame width 572, height 140, Auto Layout Horizontal gap 8, scroll horizontal): 6-8 thumbnails 200x120 radius 8 stroke #8B7355 1px; selected thumbnail has stroke #A07840 2px; left/right arrow buttons 32x32 at edges
- Description section: "简介" label + body text (Inter 14 Regular #5C4A3D line-height 22, max 4 lines + "显示全部" expandable)

Edit mode variant: All fields become editable (inputs replace text), title gets lock icon, cover shows "更换封面" overlay.
```

### 3.8 认证模态（Auth Modal · 登录/注册）

```
Create a modal Frame 440x560, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, drop shadow #8B7355 30% offset 0x12 blur 32, padding 32, Auto Layout Vertical, gap 20:

HEADER (Auto Layout Horizontal, align center):
- Title "登录" (ZhiMangXing 28 Regular #5C4A3D letter-spacing 2.0) — switches to "注册" in register variant
- Spacer
- Close button 28x28 (use WinButton/Close)

App logo (60x60, centered, fill #F0E6D2, radius 16, stroke #8B7355 1.5px, with controller icon)

FORM (Auto Layout Vertical, gap 14):
- Field group: "邮箱" label (Inter 13 Medium #5C4A3D) + Input/Text (full width, placeholder "请输入邮箱")
- Field group: "密码" label + Input/Text with suffix eye icon (placeholder "请输入密码", obscure dots)
- Register variant adds: "确认密码" + "用户名" fields
- Error message row (when present): warning icon 16x16 #D4183D + text (Inter 12 #D4183D) e.g. "邮箱或密码不正确"
- Helper row (Auto Layout Horizontal, align center, justify space-between):
  - "忘记密码?" text link (Inter 12 #4A72A5 underline)
  - "记住我" + small checkbox (16x16, stroke #8B7355 1.5px, checked fill #A07840 with white check)

PRIMARY BUTTON: "登录" (use Button/Primary full width height 44) — "注册" in register variant

SWITCH LINK (centered): "还没有账号? 立即注册" (Inter 13 #7D6348 with #4A72A5 "立即注册" link) — flips to "已有账号? 立即登录" in register variant

THIRD-PARTY DIVIDER: divider line + "或" centered (Inter 11 #9A8A76)

THIRD-PARTY LOGIN: 2 buttons row (gap 12), each Frame 184x44, fill #FBF6EF, stroke #8B7355 1.5px, radius 8, icon 20x20 + label (Inter 14 Medium #5C4A3D): "Google 登录" / "Steam 登录"
```

### 3.9 设置模态（Settings Modal）

```
Create a modal Frame 700x500, fill #FBF6EF, stroke #8B7355 1.6px, drop shadow #8B7355 25% offset 4x6, radius default (12), Auto Layout Horizontal, padding 0:

LEFT SIDEBAR (Frame width 192, height 500, fill #FBF6EF, stroke right #8B7355 at 20% 1px, Auto Layout Vertical, padding 12, gap 4):
- Close button top-right 32x32 (use WinButton/Close) — actually place at top of sidebar
- Category list (Auto Layout Vertical, gap 4):
  - "👤 个人资料" (active state: height 51, fill #F0E6D2, stroke #8B7355 1px, radius 14, padding 12x10, icon 18x18 #5C4A3D, text Inter 16 SemiBold #5C4A3D)
  - "⚙️ 偏好设置" (inactive: height 51, fill transparent, radius 14, icon #7D6348, text Inter 16 Medium #7D6348)
  - "ℹ️ 关于应用" (inactive)
- Bottom: version text "CTLIB v1.0.0" (Inter 10 #9A8A76)

RIGHT CONTENT PANEL (Frame width 508, height 500, padding 24, Auto Layout Vertical, gap 16, scroll vertical):
- Section title "个人资料" (Inter 20 SemiBold #5C4A3D)
- Section description (Inter 13 #7D6348)
- Settings rows (Auto Layout Vertical, gap 16):

For "偏好设置" category, the rows include these control types:

Toggle row: Frame Auto Layout Horizontal align center justify space-between:
- Left: Label "开机自启动" (Inter 14 Medium #5C4A3D) + helper "登录系统时自动启动 CTLIB" (Inter 11 #7D6348)
- Right: Toggle (use Toggle component, 44x24)

Text input row: Frame Auto Layout Vertical gap 6:
- Label "默认安装路径" (Inter 13 Medium #5C4A3D)
- Row: Input/Text (width fills, height 47) + "浏览" button (use Button/Info)

Dropdown row: Frame Auto Layout Vertical gap 6:
- Label "网络代理" (Inter 13 Medium #5C4A3D)
- Select (Frame width fills height 47, fill #FBF6EF, stroke #8B7355 1.6px, radius 8, padding 14x11, Auto Layout Horizontal justify space-between): "系统代理" (Inter 16 #5C4A3D) + chevron-down 20x20 #7D6348

Theme picker section:
- Label "主题" (Inter 13 Medium #5C4A3D)
- Featured theme cards row (Auto Layout Horizontal gap 12): 3 cards each Frame 160x90 (16:9), radius 12, stroke #8B7355 1px (selected: stroke #A07840 2px + check icon top-right), showing theme preview image + name overlay "🌊 墨绿金" (Inter 12 SemiBold #FFFFFF) at bottom
- Standard theme swatch grid (Auto Layout Horizontal wrap gap 8): 3 swatches each 100x58, radius 10, fill = theme background color, label below "🌞 暖阳" (Inter 11 #7D6348), selected ring stroke #A07840 2px

Data sources section:
- Label "元数据数据源" (Inter 13 Medium #5C4A3D)
- 7 toggle rows (gap 10) each with platform name + enable Toggle:
  - VNDB / Bangumi / DLsite / Steam / ErogameScape / Ymgal (all on by default)
  - TouchGal (off by default, marked "默认禁用" hint)

Translation API section:
- Label "翻译服务" (Inter 13 Medium #5C4A3D)
- API key input (Input/Text with password mask + "测试连接" button)
- Provider dropdown (SiliconFlow default)
- Status indicator (green dot #4CAF50 + "已配置" Inter 11)

Button row (segmented control): Frame width fills height 56, Auto Layout Horizontal, stroke #8B7355 1.6px, radius 8, 2-3 cells each width fills, gap 1px, active cell fill #F0E6D2, inactive fill #FBF6EF, icon 20x20 + label Inter 14 Medium

FOOTER (overlay bottom-right of modal): "保存" primary button + "取消" text button
```

### 3.10 用户资料模态（User Profile Modal）

```
Create a modal Frame 420x520, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, drop shadow #8B7355 30% offset 0x8 blur 24, padding 24, Auto Layout Vertical, gap 16:

HEADER: Title "个人中心" (ZhiMangXing 24 Regular #5C4A3D) + close button 28x28 top-right

PROFILE CARD (Frame, fill #FDFBF7, stroke #8B7355 at 20% 1px, radius 12, padding 20, Auto Layout Vertical gap 12, align center):
- Avatar 80x80 circle, fill #E9E0D1, stroke #8B7355 2px, with edit pencil icon bottom-right (24x24 circle fill #F0E6D2 stroke #8B7355)
- Username "玩家昵称" (Inter 18 SemiBold #5C4A3D)
- Email "user@example.com" (Inter 12 Regular #7D6348)
- Membership badge: "🌟 会员" chip (fill #E8C84A at 20%, stroke #D4A017, text #D4A017, Inter 11 SemiBold, radius 4, padding 6x4)

STATS ROW (Auto Layout Horizontal, gap 12, justify space-between):
- Stat 1 (Frame fills, padding 12, fill #FBF6EF, stroke #8B7355 at 20% 1px, radius 8, align center, gap 4): Value "47" (Mali 22 #5C4A3D) + Label "游戏" (Inter 11 #7D6348)
- Stat 2: "128h" / "总时长"
- Stat 3: "12" / "本月新增"

SETTINGS LIST (Auto Layout Vertical, gap 2, fill #FBF6EF, radius 12, clip):
- Row (Frame height 48, padding 16x0, Auto Layout Horizontal align center, stroke bottom #8B7355 at 10% 1px): icon 20x20 #7D6348 + "账户设置" (Inter 14 #5C4A3D) + spacer + chevron-right 16x16 #9A8A76
- Row: "🔑 修改密码" + chevron
- Row: "📦 我的订单" + chevron
- Row: "🌐 数据备份" + chevron
- Row (last, no border): "ℹ️ 帮助与反馈" + chevron

LOGOUT BUTTON (use Button/Primary danger variant): "退出登录" full width height 44, fill #FFE6EA, stroke #D4183D, text #D4183D
```

### 3.11 付费/会员模态（Payment Modal）

```
Create a modal Frame 720x560, fill #FBF6EF, stroke #8B7355 1.5px, radius 16, drop shadow #8B7355 30% offset 0x12 blur 32, padding 32, Auto Layout Vertical, gap 20:

HEADER: Title "升级会员" (ZhiMangXing 26 Regular #5C4A3D) + subtitle "解锁全部高级功能" (Inter 13 #7D6348) + close button 28x28 top-right

PLAN CARDS ROW (Auto Layout Horizontal, gap 16):
- Plan 1 (Frame width 200, height 280, fill #FBF6EF, stroke #8B7355 1.5px, radius 12, padding 20, Auto Layout Vertical gap 12, align center):
  - "月度" (Inter 14 Medium #7D6348)
  - Price "¥18" (Mali 36 #5C4A3D) + "/月" (Inter 12 #7D6348)
  - Divider 1px #8B7355 at 20%
  - Features list (Auto Layout Vertical gap 8, align left): 4 items each check icon 14x14 #4CAF50 + text Inter 12 #5C4A3D
  - CTA: "选择月度" text button (Inter 13 Medium #4A72A5)
- Plan 2 (RECOMMENDED, same structure but width 220, height 300, stroke #A07840 2px, drop shadow #8B7355 25% offset 0x4 blur 12, top-right ribbon "推荐" fill #D4A017 text #FFFFFF Inter 11 SemiBold):
  - "年度" / "¥128" / "/年" + "节省 40%" badge (fill #E8F5E9 text #4CAF50)
  - Features list (more items)
  - CTA: "选择年度" primary button (use Button/Primary)
- Plan 3 (same as Plan 1):
  - "终身" / "¥388" / "一次付费"
  - Features
  - CTA: "选择终身"

PAYMENT METHOD SECTION:
- Label "支付方式" (Inter 14 SemiBold #5C4A3D)
- 2 option rows (Frame, Auto Layout Horizontal, gap 12, padding 16, fill #FBF6EF, stroke #8B7355 1.5px, radius 8, align center):
  - Radio circle 20x20 (selected: fill #A07840 with inner dot #FFFFFF; unselected: stroke #8B7355 1.5px)
  - Icon 28x28 (Alipay blue / WeChat green)
  - Label "支付宝" (Inter 14 #5C4A3D)
  - Spacer + radio on right

BOTTOM BAR (Auto Layout Horizontal, align center, justify space-between):
- Left: "合计 ¥128.00" (Inter 13 #7D6348) + "¥128.00" (Mali 22 #D4183D)
- Right: "立即支付" primary button (Frame 160x44)
```

### 3.12 大画面模式（Big Picture Mode）

```
Create a fullscreen 1920x1080 frame, fill #1A3D35 (using mint dark theme for BPM, or current user theme), Auto Layout Horizontal, padding 0:

LEFT NAV BAR (Frame width 96, height 1080, fill #15302A at 80% opacity, stroke right #4A9B6A 1px, Auto Layout Vertical, padding 24x0, gap 16, align center):
- Nav icons (each Frame 64x64, radius 12, align center):
  - 🏠 Home (active: fill #1A3D35 at 80%, stroke #E8C84A 4px, icon 32x32 #E8C84A)
  - 🎮 Library (inactive: icon 32x32 #B8D4C0)
  - 🌟 Discover
  - ➕ Join
  - ⚙️ Settings (bottom, after spacer)

MAIN CONTENT (Frame width 1824, height 1080, padding 48, Auto Layout Vertical, gap 32):

HOME PAGE (BPM):
- Hero section (Frame width 1728, height 480, radius 16, drop shadow #000000 50% offset 0x8 blur 24, cover image with dark gradient overlay bottom):
  - Bottom-left overlay text: Game title "游戏名称" (Inter 36 SemiBold #FFFFFF) + brand/year (Inter 18 #B8D4C0) + "▶ 立即游玩" primary button (Frame 200x56, fill #E8C84A, text #1A3D35, Inter 18 SemiBold, radius 12)
- Section title "最近游玩" (Inter 28 SemiBold #F0F4EC)
- Horizontal scroll of large game tiles (use spec below), gap 24

LARGE GAME TILE (BPM Card):
- Frame 320x180, radius 12, stroke #4A9B6A 1px, drop shadow #000000 40% offset 0x4 blur 12
- Cover image fills, fit cover
- Bottom gradient overlay + title (Inter 16 SemiBold #FFFFFF)
- Focus state: scale 1.05, stroke #E8C84A 4px, outer glow (drop shadow #E8C84A 60% offset 0x0 blur 20, plus second shadow offset 0x0 blur 40)
- Selected state: keep focus glow + check icon top-right

FOCUS INDICATOR (reusable component):
- Wrap any focusable element. Style: stroke #E8C84A 4px outside, drop shadow #E8C84A 60% offset 0x0 blur 20, inner shadow #E8C84A 30% offset 0x0 blur 8 inset

TEXT SCALE (BPM): All text 1.5-2x larger than desktop mode.
- Title 36 (vs 18-24 desktop), Body 18 (vs 14), Label 16 (vs 12)

BPM uses mint theme tokens by default:
- background #1A3D35, primaryText #F0F4EC, secondaryText #B8D4C0, border #4A9B6A, selectedAccent #E8C84A, buttonBg #D4AF37 60%, starGold #E8C84A
```

---

## 四、窗口与平台特性备注（给 Figma AI 的全局指令）

生成任何屏幕前，先在 Figma AI 里设置这些全局约束：

```
Global design constraints for CTLIB (a Windows desktop Flutter app):
- Frameless window (no OS title bar) — app draws its own 32px custom title bar
- Window corner radius: Windows 11 native rounded corners (8px) applied by OS DWM
- Default canvas size for screens: 1440x900 (representing 1440x900 window minus 32px title bar = 1440x868 content)
- Design for 100% DPI scaling; elements will be rendered at higher DPI at runtime
- Color system: warm beige/brown palette (warmSun theme) is default — see token table
- Typography: Inter for all UI text; ZhiMangXing (Chinese calligraphy) ONLY for decorative page titles; Mali (handwriting) ONLY for decorative numbers
- 4px spacing grid: all padding/gap values are multiples of 4 (4, 8, 12, 16, 24, 32, 48)
- Corner radius scale: 2, 4, 8, 12, 16, 20 (pill)
- All buttons 40-48px tall, all inputs 44-47px tall, all list rows 48-56px tall
- Icons: Material Symbols rounded style, 20-24px for inline, 32px for nav, 48px+ for BPM
- Hover states: subtle fill change to #F5EDE6 (cardHoverBg), never scale >1.03 except BPM cards
- Shadows: warm-toned (#8B7355 at 25%), never pure black, offset 0x2-4, blur 6-12
- Theme switching: design tokens support 6 themes (warmSun/darkNight/mint/sakura/ocean/twilight) — keep components token-driven for easy re-skin
```

---

## 五、生成顺序建议

1. **先建组件库**（第二节 2.1-2.8）— 8 个 Component，存为 Local Components
2. **再生成主壳**（3.1）— 验证标题栏+侧边栏尺寸
3. **生成库页**（3.3）— 用 2.6 GameCard 复用
4. **生成详情对话框**（3.7）— 最复杂，建议分两次：先左面板，再右面板
5. **生成设置模态**（3.9）— 用 2.3/2.4/2.5 组件复用
6. **其余屏幕按需生成**
7. **BPM 最后做**（3.12）— 独立设计语言，可用 mint 主题

## 六、已知限制与提示

- **Figma AI 一次性生成可能丢失细节**：长 prompt 建议分段，先生成主结构，再用「添加 X 到选中的 frame」迭代补充
- **字体替代**：若 Figma 无 `ZhiMangXing`，用 `Ma Shan Zheng`（Google Fonts 有）；无 `Mali` 用 `Gloria Hallelujah`
- **图标**：Figma AI 默认用 Material Symbols，与 Flutter `Icons` 类一致，可直接用图标名（如 `Icons.home` → Material Symbol `home`）
- **响应式**：Figma AI 不易一次做多端，建议每屏生成一个 1440x900 桌面版本即可，移动/窄屏单独再生成
- **主题切换**：在 Figma 中可用 Variables + Modes 实现多主题，把第二节令牌表导入为 Color Variables 即可一键切主题
