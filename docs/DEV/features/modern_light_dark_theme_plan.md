# 系统级「浅色 / 深色」现代主题设计方案

> 状态：**Phase 1 已实施；已被 v2 方案取代（superseded）**——v1 仅换色、未脱离
> 手绘骨架，v2（`modern_theme_aurora_redesign.md`）引入风格档层彻底重设计。
> 历史记录（2026-09-12 用户批准；显示名定为「浅色 / 深色」，
> id 保持 frost / obsidian）。代码：`app_theme_manager.dart` enum +2、
> `theme_registry.dart` +2 const、`test/theme/builtin_themes_test.dart` 9 用例全过。
> 待办：真机视觉走查（§9 第 4 条）；Phase 2 可选项未实施。
> 发现存量缺陷（未修）：CTThemeData JSON 往返 seedColor 丢失，详见 DEV_LOG 2026-09-12 本条目。
> 日期：2026-09-12
> 涉及稳定区：`lib/theme/`（本方案的核心改动点，已获用户批准）
> 假设：用户所称最初主题「暖白」= 内置默认主题 **「暖阳」(warmSun)**（暖白纸感背景、
> 暖棕手绘风）。如不符请指出，方案主体不受影响。

---

## 1. 定位与总体结论

为 Chrono Tide 新增 **2 套系统级内置主题**（与「暖阳」同级的全局预设，非特色背景主题）：

| | 浅色 | 深色 |
|---|---|---|
| 名称 | **霜白**（可改名） | **曜石**（可改名） |
| id | `frost` | `obsidian` |
| emoji | ❄️ | 🌑 |
| brightness | light | dark |
| 一句话 | 现代冷灰白 + 科技蓝强调 | 现代深空蓝黑 + 亮蓝强调 |
| 归组 | 经典配色（`isFeatured: false`） | 经典配色（`isFeatured: false`） |

设计语言：**现代扁平 + 柔和科技感**（非手绘风）——

1. **冷灰蓝中性色系**：所有中性色（底/面/边/字）从暖棕切换为冷灰蓝（蓝相 215° 左右），彻底告别纸感；
2. **白卡片 + 低对比分隔**：浅色 = 冷灰蓝底上白色浮起卡片；深色 = 深空底上"提亮一级"面板；描边保留既有 1~2px 语言但对比度压低，观感"轻"；
3. **单一科技蓝强调**：全应用只有一个强调色（浅 `#3E6FE8` / 深 `#5B8DEF`），选中/聚焦/激活/进度统一走它；
4. **柔和科技感落点（零组件改动即可获得）**：
   - `seedColor` 驱动 Material 3（Switch / Slider / Chip / Progress / 菜单等）整体染成科技蓝；
   - 激活态阴影带冷色相/深色下带微光，替代暖棕硬阴影；
   - 侧栏激活白胶囊 + 蓝描边 + 冷色阴影，自带"光感"。

## 2. 色彩体系：完整令牌对照表（核心交付）

两张主题各 37 个令牌，全部映射到现有 `CTThemeData` 字段，**不新增令牌、不改 schema**。

### 2.1 霜白（frost，浅色）

| 令牌 | 值 | 用途 / 设计意图 |
|---|---|---|
| seedColor | `#3E6FE8` | M3 种子，Material 组件染科技蓝 |
| background | `#F6F8FB` | 主窗口底：冷灰蓝近白，不是纯白（纯白刺眼） |
| sidebarBackground | `#EFF2F8` | 侧栏：比主底深半档，形成纵向分区 |
| titleBarBackground | `#EFF2F8` | 标题栏与侧栏同色（既有惯例） |
| primaryText | `#1F2A3D` | 主文字：深蓝灰，不用纯黑（现代感关键） |
| secondaryText | `#5C6B84` | 次要文字：中灰蓝，对比度 ~5.6:1 |
| border | `#C3CEDD` | 强边框：冷灰蓝，替代暖阳的棕色边 |
| borderLight | `#33C3CEDD` | 弱边框：20% 同色，分隔线/卡片静息边 |
| buttonBackground | `#FFFFFF` | 按钮与卡片面：白，在灰蓝底上"浮起" |
| selectedAccent | `#3E6FE8` | 强调色：选中/聚焦/主操作 |
| dangerRed | `#E5484D` | 现代红（非暖阳的 `#D4183D` 深红） |
| placeholderText | `#9AA7BA` | 占位文字 |
| placeholderBg | `#EDF1F7` | 占位底/输入框静息底 |
| addCoverBg | `#E3E9F2` | 添加封面虚线区底 |
| shadowColor | `#2E27405C` | 阴影：冷蓝灰 ~18%（替代暖棕影） |
| successGreen | `#2FA46C` | 现代绿 |
| successBg | `#E4F5EC` | 成功底 |
| errorBg | `#FDEBEE` | 错误底 |
| hoverCloseBg | `#FDEBEE` | 关闭按钮 hover 底 |
| hoverCloseBorder | `#E5484D` | 关闭按钮 hover 边 |
| inputHint | `#995C6B84` | 输入 hint（62% 次要文字） |
| cardHoverBg | `#E8EDF6` | hover 填充：比底深一档的冷灰蓝 |
| navActiveBg | `#FFFFFF` | 侧栏激活：白胶囊 |
| navActiveBorder | `#3E6FE8` | 激活描边/激活图标色 = 强调蓝 |
| navInactiveBorder | `#D5DEEA` | 非激活描边 |
| toggleBg | `#E3E9F2` | 开关底 |
| toggleBorder | `#C3CEDD` | 开关边 |
| toggleIcon | `#33415C` | 开关图标：深蓝灰 |
| placeholderCover | `#E3E9F2` | 封面占位 |
| titleBrown | `#1F2A3D` | 标题色（沿用令牌名，语义=大标题） |
| starGold | `#F2A93B` | 星级：现代琥珀 |
| infoBlue | `#4377D6` | 信息蓝 |
| brandBlue | `#5B8DEF` | 品牌蓝（渐变辅色，比强调蓝浅一档） |
| infoBg | `#EAF1FE` | 信息底 |
| 背景图 | 无 | 现代主题不走背景图 |

### 2.2 曜石（obsidian，深色）

| 令牌 | 值 | 用途 / 设计意图 |
|---|---|---|
| seedColor | `#4E8DF5` | M3 种子（暗色方案自动派生） |
| background | `#0F141F` | 主底：深空蓝黑（比暗夜 `#1A1714` 更冷更沉） |
| sidebarBackground | `#131926` | 侧栏：提亮一级 |
| titleBarBackground | `#131926` | 同侧栏 |
| primaryText | `#E7ECF5` | 主文字：冷白 |
| secondaryText | `#8D99AE` | 次要文字：灰蓝 |
| border | `#2F3B52` | 强边框：暗蓝灰，替代暖夜棕 |
| borderLight | `#332F3B52` | 弱边框：20% |
| buttonBackground | `#1A2233` | 按钮与卡片面：比底亮一级的蓝灰面板 |
| selectedAccent | `#5B8DEF` | 强调蓝（深色下提亮，保证对比） |
| dangerRed | `#F0666E` | 深色下提亮的红 |
| placeholderText | `#5C6880` | 占位 |
| placeholderBg | `#1A2233` | 占位底 = 面板色 |
| addCoverBg | `#212B40` | 添加封面底 |
| shadowColor | `#66000000` | 深色阴影：黑 40%（微光靠边框与强调色） |
| successGreen | `#4CC38A` | 现代绿（提亮） |
| successBg | `#16281F` | 成功底 |
| errorBg | `#301A1F` | 错误底 |
| hoverCloseBg | `#301A1F` | 关闭 hover 底 |
| hoverCloseBorder | `#F0666E` | 关闭 hover 边 |
| inputHint | `#998D99AE` | 输入 hint |
| cardHoverBg | `#232E45` | hover 填充：再亮一级的蓝灰 |
| navActiveBg | `#FFFFFF` | 激活白胶囊（与暗夜/暮光同约定，暗色下反而醒目） |
| navActiveBorder | `#35549E` | 激活描边/图标：深科技蓝（保证白底上可读） |
| navInactiveBorder | `#2F3B52` | 非激活描边 |
| toggleBg | `#1A2233` | 开关底 |
| toggleBorder | `#2F3B52` | 开关边 |
| toggleIcon | `#B6C2D9` | 开关图标 |
| placeholderCover | `#212B40` | 封面占位 |
| titleBrown | `#E7ECF5` | 标题色 |
| starGold | `#F5C04A` | 星级 |
| infoBlue | `#6FA5F2` | 信息蓝（提亮） |
| brandBlue | `#5B8DEF` | 品牌蓝 |
| infoBg | `#1A2742` | 信息底：深蓝微光感 |
| 背景图 | 无 | — |

### 2.3 双主题一致性约束（自查规则）

- 同一令牌在两主题中**亮度关系恒定**：background < sidebar ≤ card 面；hover 填充永远比所在面深/亮一档；
- 强调色唯一：除状态三色（success/danger/info）外不引入第二彩色；
- 深色主文字对 `#0F141F` 对比 ≥ 12:1，次要 ≥ 4.6:1；浅色主文字对 `#F6F8FB` ≥ 13:1，次要 ≥ 5.5:1；
- `navActiveBg` 在两主题都为白（既有 token 契约：激活图标/文字用 `navActiveBorder` 渲染，必须保证白底可读——暗夜 `#5A4A3A`、霜白/曜石用深蓝同理）。

## 3. 背景与层级

三层表面模型（与现有实现一致，只换色）：

```
L0 窗口底  background          #F6F8FB / #0F141F
L1 分区    sidebar / titlebar  #EFF2F8 / #131926（含 0.8px borderLight 右缘 + 极淡投影）
L2 浮面    卡片/按钮/输入框     buttonBackground（白 / #1A2233）+ border 静息描边
L3 浮层    弹窗/菜单           sidebarBackground + border 1.5px（confirm_dialog 现行做法）
```

- 弹窗/菜单/对话框沿用 L3（`sidebarBackground` + `AppColors.border` 1.5px），两主题自动成立；
- 特色主题的背景图逻辑与本方案无关（新主题无背景图，`pageBackground == background`）；
- 窗口边缘色：`main.dart` 已监听主题并 `windowManager.setBackgroundColor`，切换无白边/黑边残留。

## 4. 文字排版

**字体体系零改动**（F1 得意黑 / F2 Outfit / F3 NotoSansSC 全局共用，`app_styles.dart` 不动）。
仅文字颜色映射：

| 角色 | 令牌 | 霜白 | 曜石 |
|---|---|---|---|
| 大标题/卡片标题/按钮文字 | primaryText（titleBrown 同值） | `#1F2A3D` | `#E7ECF5` |
| 描述/日期/统计/非激活导航 | secondaryText | `#5C6B84` | `#8D99AE` |
| 占位/空态提示 | placeholderText / inputHint | `#9AA7BA` | `#5C6880` |
| 评分星 | starGold | `#F2A93B` | `#F5C04A` |
| 链接/信息强调 | infoBlue | `#4377D6` | `#6FA5F2` |

## 5. 边框与阴影

| 项 | 实现 | 霜白 | 曜石 |
|---|---|---|---|
| 卡片/按钮静息边 | borderLight 1px | 20% 冷灰蓝，近乎无感 | 20% 暗蓝灰 |
| 卡片选中/重要边 | border 或 selectedAccent 2px | 强调蓝 | 强调蓝 |
| 分隔线 | borderLight | 近乎无感 | 近乎无感 |
| 组件硬阴影（offset 2,2 / blur 0，手绘遗产） | shadowColor | 冷蓝灰 18%，观感"轻" | 黑 40% |
| 侧栏右缘投影 | border 5% + blur 5 | 冷色 | 冷色 |

> 注：`blurRadius: 0` 的硬阴影参数写在各组件里（最小变更不动）。冷色 shadowColor
> 已能显著"去手绘感"；**组件级软阴影（blur 12+）列为 Phase 2 可选项**（见 §8）。

## 6. 组件状态矩阵（hover / 按下 / 选中 / 禁用 / 过渡）

全部基于**现有令牌与现有组件逻辑**，两主题自动成立，无需改组件代码：

| 组件 / 状态 | 现行取色（文件证据） | 霜白表现 | 曜石表现 |
|---|---|---|---|
| 侧栏导航 hover | `cardHoverBg` + `navInactiveBorder`（sidebar.dart:335-343） | 冷灰蓝浅填充 | 蓝灰亮一档填充 |
| 侧栏导航激活 | `navActiveBg` 白胶囊 + `navActiveBorder` + shadowColor 阴影（sidebar.dart:336-346） | 白胶囊 + 蓝描边 + 蓝图标 | 白胶囊 + 深蓝图标 + 微光 |
| 主页按钮 | `cardHoverBg` + `border`（element registry `home_button`） | 同上规律 | 同上 |
| 通用按钮 hover | InteractiveWrapper 默认不变填充、边框加深（interactive_wrapper.dart:125-129） | 边框转 `border` 实色 | 边框转 `border` 实色 |
| 卡片 hover（库/探索） | `cardHoverBg`；恒定 Transform 结构防闪烁（library_page.dart:3150 修复） | 冷灰蓝 | 蓝灰 |
| 卡片选中 | border 加粗 + border 实色 | 蓝/冷灰 | 蓝/暗蓝灰 |
| 关闭按钮 hover | `hoverCloseBg`/`hoverCloseBorder` | 红底红边 | 暗红底亮红边 |
| SnackBar 成功/错误/警告/信息 | successGreen / dangerRed / starGold / infoBlue 纯色底（app_snack_bar.dart） | 现代四色 | 提亮四色 |
| 下载按钮 info/danger/普通变体 | infoBg+infoBlue / errorBg+dangerRed / buttonBackground+border（download_button.dart:81-215） | 浅蓝/浅红/白 | 深蓝微光/暗红/面板 |
| 对话框 | sidebarBackground + border 1.5px（confirm_dialog.dart:64-67） | 浅灰蓝浮层 | 深蓝灰浮层 |
| 输入框 | placeholderBg 底 + border 边 + focus 转 selectedAccent（主题编辑器元素表佐证） | 浅灰蓝 → 聚焦蓝边 | 面板底 → 聚焦亮蓝边 |
| M3 组件（Switch/Slider/Chip/Progress/菜单/Tooltip） | `ColorScheme.fromSeed(seedColor)` + primary=selectedAccent、onSurface=primaryText、outline=border（main.dart:879-893） | 整体科技蓝染色 | 亮科技蓝染色 |
| 禁用态 | M3 onSurface 38% 自动；自绘组件落 placeholderText | 灰蓝弱化 | 暗灰蓝弱化 |
| 主题切换过渡 | 250ms `Color.lerp` 全令牌插值（app_theme_manager.dart:149-202） | 冷暖/深浅平滑渐变 | 同左 |
| 侧栏展开收起 | AnimatedContainer 250ms | 无感换色 | 无感换色 |
| BPM 大屏模式 | 独立 BpmPalette（深/浅已存在），不受桌面主题影响；内嵌桌面 JoinPage 走 `pushOverride` 自动取 BPM 配色 | 不受影响 | 不受影响 |

## 7. 覆盖面审计（重要结论）

- 全应用 ~3800 处 `AppColors.*` 引用、`Theme.of(context).brightness` 0 处 → **换调色板即全局换肤**，新主题在所有页面自动生效；
- 既有硬编码色（`Colors.white/black` 254 处、非 theme 目录 `Color(0x…` 281 处）在 **暗夜/暮光下就是现状**，新深色主题与暗夜同基线，不会更差；热点清单（game_detail_dialog 48 处、explore_hall 系列白字浮层、library_page 5 处等）属存量债务，本方案**不顺手修**（铁律），列 Phase 2 备选；
- 已知令牌缺口：`AppColors.warning` 不存在（settings_tile.dart:11 用局部 `kSettingsWarning` 规避）——本方案不新增令牌，维持现状；
- 浅色下与暖阳的差异是色相级（暖棕→冷蓝灰），所有"暖色假设"组件（如有）在暗夜时代已验证过冷/深色可行性，风险低。

## 8. 分阶段实施计划

### Phase 1（本次待批准）：纯新增两套预设，零组件改动

| 文件 | 改动 | 规模 |
|---|---|---|
| `lib/theme/app_theme_manager.dart` | `enum CTTheme` 追加 `frost, obsidian`（插在 warmSun/darkNight 之后，成对排列） | +2 行 |
| `lib/theme/theme_registry.dart` | `_builtinThemes` 追加 2 个 const CTThemeData（§2 全表） | +~80 行 |
| `test/theme/builtin_themes_test.dart`（新建） | ①注册数 6→8；②frost/obsidian 可按 id 取到且亮度正确；③`setThemeById` 可切换；④lerp(frost↔obsidian) 不抛异常；⑤toJson/fromJson 往返字段一致 | +~60 行 |

- **显示位置**：设置 → 主题设计器 → 「经典配色」行，顺序变为 暖阳 · 霜白 · 暗夜 · 曜石 · 暮光（枚举顺序即排列，无其它接线）；
- **明确不改**：`main.dart`、`app_colors.dart`、`app_styles.dart`、`theme_storage.dart`、`theme_element_registry.dart`、设置页、侧栏、BPM、全部页面/组件；
- **持久化/迁移**：零——内置主题不落盘，仅激活 id 是字符串，老用户数据零影响；回滚 = 删两段 const + 枚举两值。

### Phase 2（可选，另行批准，本方案不含）

- P2-1 侧栏激活光晕（BoxShadow(selectedAccent)）与卡片 hover 抬升软阴影（blur 12+）；
- P2-2 主操作按钮 accent 渐变（selectedAccent→brandBlue）；
- P2-3 `AppColors.warning` 令牌下沉并替换 kSettingsWarning；
- P2-4 深色硬编码热点 tokenization（game_detail_dialog 等，与暗夜共享收益）。

## 9. 验证方案

1. `./flutter/bin/flutter.bat analyze lib/theme/app_theme_manager.dart lib/theme/theme_registry.dart`（0 新增 error）；
2. `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test test/theme/`，再全量（基线 443/0，新增失败即回滚）；
3. `git status --short` 确认只动上述 3 个文件（⚠️ 当前工作区已有 5 个 join/services 未提交改动，属其他任务，本次绝不触碰）；
4. 人工走查（真机，两主题各一遍）：主页/库页/探索页/添加页/详情弹窗/设置六页/安装中心/登录注册 + hover、选中、拖拽导入、SnackBar 四色、主题互切 250ms 过渡、浅⇄深切换、6 老主题回归、BPM 不受影响、960×540 最小窗口。

## 10. 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| 深色下存量硬编码白字/白底观感 | P3（与暗夜同现状） | §7 已声明；Phase 2-4 可选治理 |
| 枚举顺序变化影响遍历显示顺序 | P3 | 仅影响经典配色排列，无逻辑分支依赖顺序 |
| 「暖白」指代偏差 | P3 | 见文档顶部假设，仅影响命名，不影响结构 |

## 11. 深色主题悬浮提示可读性（TOOLTIP-DARK-CONTRAST，2026-11-03）

**问题**：深色档 `primaryText = #E7ECF5`（近白）。历史上 3 处 Tooltip 用
`decoration.color: AppColors.primaryText` 做底、`textStyle.color: Colors.white` 做字
⇒ 白底白字，对比度 1.19:1，几乎不可读。

**位置**：`widgets/explore_hall/website_section.dart`、`widgets/explore_hall/docs_section.dart`（`_LinkPill`）、
`widgets/settings_modal.dart`（超分预设 chip）。

**方案（已实施）**：

1. `AppColors` 新增派生 getter（不改 `CTThemeData` 结构）：
   - `tooltipBg`：深色 = `Color.alphaBlend(Colors.white.withOpacity(0.08), background)`；浅色 = `primaryText`
   - `tooltipFg`：深色 = `primaryText`；浅色 = `Colors.white`
   - `tooltipBorder`：`border`
2. `main.dart:_buildThemeData` 增加 `tooltipTheme`，**仅深色档给值**（浅色传 null ⇒ 框架默认，零变化），
   顺带把「默认 Tooltip 在深色下是 `Colors.white.withOpacity(0.9)` 亮白浮块」一并统一成深色浮层。
3. 三处自定义 Tooltip 改为引用上述 getter。

**效果**：深色对比度 1.19:1 → 12.6:1（底 `#222731` / 字 `#E7ECF5`）；浅色主题逐像素不变。

**扫描工具**：`dev_probe/scan_tooltip_colors.py`（遍历 lib 下全部 `Tooltip(`，打印底/字色，
用于后续回归「又有人写反色」）。
