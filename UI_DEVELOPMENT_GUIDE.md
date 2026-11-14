# ChronoTide UI 设计开发指南 (AI 接手规范)

> **版本**: v2.0 | **最后更新**: 2026-06-03
> **适用对象**: 所有参与 ChronoTide UI 开发的开发者 / AI 助手
> **核心原则**: 用 `AppColors` 语义色 = 自动适配全部 6 套主题，零额外工作

---

## 一、核心架构：为什么你不需要担心多主题适配

ChronoTide 的主题系统采用**语义化颜色代理层**，架构如下：

```
开发者写代码 → AppColors.xxx（语义色）→ AppThemeManager（当前主题）→ CTThemeData（具体色值）
```

**这意味着：只要你全程使用 `AppColors` 语义色，你的组件在 6 套主题下都会自动正确渲染。**

| 层级 | 文件 | 职责 |
|------|------|------|
| **语义层** | `app_colors.dart` | 29 个语义色 getter（如 `background`, `border`, `primaryText`） |
| **样式层** | `app_styles.dart` | 8 套文字样式（如 `titleLarge`, `buttonText`） |
| **管理层** | `app_theme_manager.dart` | 6 套主题定义 + 切换 + 持久化 |
| **组件层** | 各 widget 文件 | 只引用 `AppColors.xxx` 和 `AppStyles.xxx` |

### 当前 6 套主题一览

| 主题 Key | 名称 | 类型 | 亮度 |
|----------|------|------|------|
| `warmSun` | 暖阳 | 经典（默认） | Light |
| `darkNight` | 暗夜 | 经典 | Dark |
| `twilight` | 暮光 | 经典 | Dark |
| `mint` | 墨绿金 | 特色（有背景图） | Dark |
| `sakura` | 樱花浪漫 | 特色（有背景图） | Light |
| `ocean` | 蓝天白云 | 特色（有背景图） | Light |

---

## 二、铁律：开发新组件时必须遵守的规则

### 规则 1：永远不要硬编码颜色值（除非是固定色元素）

```dart
// ❌ 错误 - 硬编码，切换主题后不会变色
Container(color: Color(0xFFFDFBF7))
Border.all(color: Color(0xFF8B7355))

// ✅ 正确 - 使用语义色，自动跟随主题
Container(color: AppColors.background)
Border.all(color: AppColors.border)
```

### 规则 2：永远不要使用 `const` 修饰包含 AppColors 的表达式

因为 `AppColors.xxx` 是动态 getter，不是编译时常量：

```dart
// ❌ 错误 - 编译报错 Invalid constant value
const BoxDecoration(color: AppColors.background)
const TextStyle(color: AppColors.primaryText)

// ✅ 正确 - 去掉 const
BoxDecoration(color: AppColors.background)
TextStyle(color: AppColors.primaryText)
```

### 规则 3：BoxShadow、Border 等同样不能用 const

```dart
// ❌ 错误
boxShadow: const [BoxShadow(color: AppColors.border, ...)]

// ✅ 正确
boxShadow: [BoxShadow(color: AppColors.border, ...)]
```

---

## 三、29 个语义色完整参考表

### 背景色组（4 个）

| 语义色名 | 用途 | 暖阳示例 | 暗夜示例 |
|----------|------|----------|----------|
| `AppColors.background` | 主区域背景 | `#FDFBF7` | `#1A1714` |
| `AppColors.pageBackground` | 页面容器背景（特色主题下透明） | `#FDFBF7` | `transparent` |
| `AppColors.sidebarBackground` | 侧边栏背景 | `#FBF6EF` | `#242019` |
| `AppColors.titleBarBackground` | 标题栏背景 | `#FBF6EF` | `#242019` |

### 文字色组（3 个）

| 语义色名 | 用途 | 暖阳示例 | 暗夜示例 |
|----------|------|----------|----------|
| `AppColors.primaryText` | 主文字（标题、正文） | `#5C4A3D` | `#E8E0D0` |
| `AppColors.secondaryText` | 次要文字（描述、提示） | `#A08264` | `#9B9080` |
| `AppColors.placeholderText` | 占位文字（输入框 hint） | `#C4B3A1` | `#6D6358` |

### 边框色组（3 个）

| 语义色名 | 用途 | 暖阳示例 | 暗夜示例 |
|----------|------|----------|----------|
| `AppColors.border` | 主边框（卡片、按钮、窗口） | `#8B7355` | `#3D3530` |
| `AppColors.borderLight` | 浅边框（分割线、次要分隔） | `#338B7355` | `#333D3530` |
| `AppColors.navInactiveBorder` | 导航项未激活边框 | `#C8B49A` | `#3D3530` |

### 按钮与交互色组（6 个）

| 语义色名 | 用途 | 暖阳示例 | 暗夜示例 |
|----------|------|----------|----------|
| `AppColors.buttonBackground` | 按钮默认背景 | `#F0E6D2` | `#2D2824` |
| `AppColors.selectedBlue` | 选中态/主要操作色 | `#B4D4FF` | `#5A7A9B` |
| `AppColors.dangerRed` | 危险/删除操作 | `#D4183D` | `#E05555` |
| `AppColors.successGreen` | 成功状态 | `#4CAF50` | `#66BB6A` |
| `AppColors.cardHoverBg` | 卡片悬停背景 | `#F5EDE6` | `#2D2824` |
| `AppColors.hoverCloseBg` | 关闭按钮悬停背景 | `#FFEBEE` | `#3A1B1B` |

### 导航专用色组（3 个）

| 语义色名 | 用途 | 暖阳示例 | 暗夜示例 |
|----------|------|----------|----------|
| `AppColors.navActiveBg` | 导航项激活背景 | `#FFFFFF` | `#FFFFFF` |
| `AppColors.navActiveBorder` | 导航项激活边框 | `#A07840` | `#5A4A3A` |
| `AppColors.navInactiveBorder` | 导航项非激活边框 | `#C8B49A` | `#3D3530` |

### 辅助功能色组（7 个）

| 语义色名 | 用途 |
|----------|------|
| `AppColors.placeholderBg` | 占位区域背景 |
| `AppColors.addCoverBg` | 添加封面占位背景 |
| `AppColors.shadowColor` | 通用阴影色 |
| `AppColors.successBg` | 成功提示背景 |
| `AppColors.errorBg` | 错误提示背景 |
| `AppColors.inputHint` | 输入框提示文字 |
| `AppColors.toggleBg` / `toggleBorder` / `toggleIcon` | 开关组件三色 |

---

## 四、固定色元素白名单（不跟随主题）

以下组件使用**硬编码固定色**，在任何主题下保持一致：

| 组件 | 固定原因 | 使用的固定色 |
|------|----------|-------------|
| **用户头像外圈**（用户详情窗口、设置页个人资料） | 品牌识别一致性 | 外圈 `#F0E6D2`，内圈 `#FBF6EF`，边框/阴影 `#8B7355` |
| **FloatingUserButton**（右下角用户按钮） | 同上 | 同上 |
| **关闭按钮 ×**（所有模态窗口） | Figma 设计规范 | 背景 `AppColors.background`，边框 `AppColors.border`（带 hover 变化） |
| **SVG 图标的 colorFilter**（如 user_avatar_icon.svg） | 图标本身品牌色 | `Color(0xFFA08264)` |

> **注意：** 如果需要新增"固定色"元素，必须在下方记录并说明理由。

---

## 五、标准组件模式（复制即用）

### 5.1 标准卡片

```dart
Container(
  decoration: BoxDecoration(
    color: AppColors.background,
    border: Border.all(color: AppColors.border, width: 1.6),
    borderRadius: BorderRadius.circular(8),
    boxShadow: [
      BoxShadow(
        color: AppColors.border,
        offset: const Offset(2, 3),
        blurRadius: 0,
      ),
    ],
  ),
  // ... child
)
```

### 5.2 标准按钮（带 hover 交互）

**方式 A：使用 InteractiveWrapper（缩放+位移效果）**

```dart
InteractiveWrapper(
  onTap: () { /* action */ },
  hoverScale: 1.05,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.buttonBackground,
      border: Border.all(color: AppColors.border, width: 1.6),
      borderRadius: BorderRadius.circular(6),
      boxShadow: [
        BoxShadow(
          color: AppColors.border,
          offset: const Offset(2, 3),
          blurRadius: 0,
        ),
      ],
    ),
    child: Text('按钮文字', style: AppStyles.buttonText),
  ),
)
```

**方式 B：使用 HoverButton（颜色变化效果）**

```dart
HoverButton(
  onTap: () { /* action */ },
  normalColor: AppColors.buttonBackground,
  hoverColor: AppColors.cardHoverBg,
  borderColor: AppColors.border,
  hoverBorderColor: AppColors.primaryText,
  child: Text('按钮文字', style: AppStyles.buttonText),
)
```

**方式 C：自定义 MouseRegion（精细控制，如关闭按钮）**

```dart
bool _hovered = false; // State 字段

MouseRegion(
  cursor: SystemMouseCursors.click,
  onEnter: (_) => setState(() => _hovered = true),
  onExit: (_) => setState(() => _hovered = false),
  child: GestureDetector(
    onTap: () { /* action */ },
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: _hovered
            ? AppColors.primaryText.withOpacity(0.1)
            : AppColors.background,
        border: Border.all(
          color: _hovered ? AppColors.border : AppColors.border.withOpacity(0.5),
          width: _hovered ? 2 : 1.6,
        ),
        borderRadius: BorderRadius.circular(5),
        boxShadow: [
          BoxShadow(
            color: AppColors.border,
            offset: _hovered ? const Offset(1, 2) : const Offset(2, 3),
            blurRadius: 0,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(Icons.icon_name, size: 18,
        color: _hovered ? AppColors.primaryText : AppColors.secondaryText),
    ),
  ),
)
```

### 5.3 标准输入框

```dart
TextField(
  style: TextStyle(
    fontFamily: 'ZhiMangXing',
    fontSize: 18,
    color: AppColors.primaryText,
  ),
  decoration: InputDecoration(
    hintText: '提示文字',
    hintStyle: TextStyle(color: AppColors.placeholderText),
    filled: true,
    fillColor: AppColors.background,
    enabledBorder: OutlineInputBorder(
      borderSide: BorderSide(color: AppColors.border, width: 1.6),
      borderRadius: BorderRadius.circular(6),
    ),
    focusedBorder: OutlineInputBorder(
      borderSide: BorderSide(color: AppColors.selectedBlue, width: 2),
      borderRadius: BorderRadius.circular(6),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  ),
)
```

### 5.4 标准模态窗口外壳

```dart
Center(
  child: Material(
    color: Colors.transparent,
    child: Container(
      width: 500,
      height: 550,
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.6),
        boxShadow: [
          BoxShadow(
            color: AppColors.border,
            offset: const Offset(4, 6),
            blurRadius: 0,
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 22, 28),
      child: Column(/* ... */),
    ),
  ),
)
```

### 5.5 Toggle 开关

```dart
Container(
  width: 44,
  height: 24,
  decoration: BoxDecoration(
    color: value ? AppColors.selectedBlue : AppColors.toggleBg,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: value ? AppColors.selectedBlue : AppColors.toggleBorder, width: 1),
  ),
  padding: EdgeInsets.fromLTRB(value ? 22 : 2, 2, value ? 2 : 22, 2),
  alignment: value ? Alignment.centerRight : Alignment.centerLeft,
  child: Container(
    width: 20,
    height: 20,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white,
      border: Border.all(color: const Color(0xFFFFFFFF), width: 1),
    ),
  ),
)
```

---

## 六、字体系统

| 样式名 | 字体 | 字号 | 行高 | 用途 |
|--------|------|------|------|------|
| `AppStyles.titleLarge` | ZhiMangXing | 30px | 36/30 | 页面标题（如"设置 / Settings"） |
| `AppStyles.heading` | ZhiMangXing | 24px | 32/24 | 区块标题（加粗） |
| `AppStyles.navActive` | Mali | 24px | 32/24 | 导航栏激活项 |
| `AppStyles.navInactive` | Mali | 24px | 32/24 | 导航栏非激活项 |
| `AppStyles.bodyRegular` | Mali | 20px | 28/20 | 正文内容 |
| `AppStyles.buttonText` | Mali | 16px | 24/16 | 按钮文字（加粗） |
| `AppStyles.inputPlaceholder` | ZhiMangXing | 24px | 28/24 | 输入框占位符 |
| `AppStyles.gameTitle` | Inter | 14px | 20/14 | 游戏卡片标题（半粗） |

**字体常量引用：**
- 中文标题 → `'ZhiMangXing'` 或 `AppStyles.zhFontFamily`
- 英文 UI → `'Mali'` 或 `AppStyles.enFontFamily`
- 表单/数据 → `'Inter'`

---

## 七、Neubrutalism 设计规范（视觉风格）

ChronoTide 采用 **Neubrutalism（新野兽派）/ Warm Retro** 风格：

| 属性 | 规范值 |
|------|--------|
| 阴影偏移 | `Offset(2, 3)` 或 `Offset(4, 6)`（大元素） |
| 阴影模糊 | `blurRadius: 0`（硬阴影，核心特征） |
| 边框宽度 | 主边框 `1.6px` ~ `2px`，次边框 `1px` ~ `1.2px` |
| 圆角 | 按钮 `5~8px`，卡片 `8~12px`，圆形头像/开关 |
| 交互时长 | `150ms`（快速响应），最大不超过 `200ms` |
| 缓动曲线 | `Curves.easeOutCubic` |
| Hover 效果 | 缩放 1.02~1.08 + 上浮 1~2px + 颜色微变 |
| Press 效果 | 缩放 0.98 + 阴影收缩 offset(1,2) |

---

## 八、特色主题特殊处理

3 套特色主题（墨绿金、樱花浪漫、蓝天白云）有**背景图片**。处理要点：

### 8.1 页面背景用 `pageBackground` 而非 `background`

```dart
// ✅ 正确 - 特色主题下 transparent，让背景图透出来
Container(color: AppColors.pageBackground)

// ❌ 错误 - 会遮挡背景图
Container(color: AppColors.background)
```

### 8.2 背景图的层级关系（main_container.dart）

```
Stack:
  Layer 1: Image.asset(backgroundImage) + Opacity(0.85) + IgnorePointer
  Layer 2: Gradient overlay (left=overlayOpacity, right=transparent) + IgnorePointer
  Layer 3: 页面内容 (_buildCurrentPage) — 在背景之上
  Layer 4: FloatingUserButton, FloatingTaskButton — 最顶层悬浮
```

### 8.3 特色主题的透明/半透明色

特色主题中很多颜色使用了**低 alpha 值**来配合背景图：
- `buttonBackground`: 约 60~80% 不透明度
- `cardHoverBg`: 约 10~20% 不透明度
- `toggleBg`: 约 80% 不透明度

这些已在 `CTThemeData` 中定义好，**无需手动处理**。

---

## 九、AI 接手任务 Checklist

当你（AI）接到一个 ChronoTide 的 UI 任务时，按此清单执行：

### Step 1: 理解任务
- [ ] 明确要创建/修改哪些组件
- [ ] 确认是否涉及新页面、新弹窗、还是修改现有组件

### Step 2: 编码阶段
- [ ] **所有颜色必须使用 `AppColors.xxx`**，禁止硬编码 `Color(0xFF...)`
- [ ] **所有文字样式优先使用 `AppStyles.xxx`**
- [ ] **禁止对包含 `AppColors` 的表达式使用 `const`**
- [ ] **阴影使用 `AppColors.border` 或 `AppColors.borderLight`**
- [ ] **边框使用 `AppColors.border`**（主）或 `AppColors.borderLight`（次）
- [ ] **交互组件包裹 `InteractiveWrapper`** 或添加 `MouseRegion` hover 效果
- [ ] **符合 Neubrutalism 风格**：硬阴影 offset(2,3)、圆角 5~12px

### Step 3: 特殊场景检查
- [ ] 如果是**头像/品牌类元素** → 查阅「四、固定色元素白名单」
- [ ] 如果是**模态窗口关闭按钮** → 复制「五、5.2 方式 C」模式
- [ ] 如果是**页面级容器背景** → 使用 `AppColors.pageBackground`
- [ ] 如果涉及**SVG 图标染色** → 使用 `ColorFilter.mode(Color(0xFFA08264), srcIn)`

### Step 4: 验证
- [ ] 运行 `flutter analyze <文件路径>` 确认无 error
- [ ] 在脑中模拟暖阳/暗夜两套主题下的显示效果
- [ ] 确认深色背景下文字可读性（对比度足够）
- [ ] 确认浅色背景下边框/阴影可见性（不会融入背景）

---

## 十、常见错误速查表

| 错误现象 | 原因 | 修复方法 |
|----------|------|----------|
| 切换暗夜主题后组件不可见 | 硬编码了浅色背景色 | 改为 `AppColors.background` |
| 深色主题下按钮融入背景 | 边框用了 `Color(0x1A000000)` | 改为 `AppColors.border.withOpacity(0.5)` |
| `flutter analyze` 报 const 错误 | 对动态色用了 `const` | 去掉 `const` 关键字 |
| 新组件没有 hover 效果 | 忘记包 `InteractiveWrapper` | 包裹或添加 `MouseRegion` |
| 特色主题下内容被遮挡 | 容器用了 `AppColors.background` | 改为 `AppColors.pageBackground` |
| SVG 图标变色了 | `colorFilter` 用了 `AppColors.xxx` | 改为固定 `Color(0xFFA08264)` |
| 关闭按钮有内方框 | 用了旧 SVG 资源 | 改为 `Icon(Icons.close)` + 标准装饰 |

---

## 十一、关键文件索引

| 文件路径 | 职责 |
|----------|------|
| `lib/theme/app_theme_manager.dart` | 6 套主题定义、切换逻辑、持久化 |
| `lib/theme/app_colors.dart` | 29 个语义色代理 |
| `lib/theme/app_styles.dart` | 8 套文字样式 |
| `lib/widgets/interactive_wrapper.dart` | 通用交互包裹器（hover/press） |
| `lib/widgets/settings_modal.dart` | 设置窗口（含主题设计器） |
| `lib/widgets/user_profile_modal.dart` | 用户详情窗口 |
| `lib/widgets/payment_modal.dart` | 赞赏窗口 |
| `lib/widgets/floating_user_button.dart` | 右下角用户按钮（固定色参考） |
| `lib/widgets/sidebar.dart` | 侧边导航栏 |
| `lib/main_container.dart` | 主容器（含背景图渲染、sidebar 状态） |
| `lib/main.dart` | 应用入口（AnimatedBuilder 包裹） |
| `.figma/image/` | Figma 设计稿截图参考 |

---

> **最后提醒：这套系统的设计目标就是让你只关注「默认暖阳主题下的视觉效果」，只要严格使用 `AppColors` 语义色，其余 5 套主题的适配由系统自动完成。不需要也不应该在每个组件里手动处理多主题逻辑。**
