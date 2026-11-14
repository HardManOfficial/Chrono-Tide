# 系统级「浅色 / 深色」现代主题重设计方案 v2 —— 设计语言「极光 Aurora」

> 状态：**Phase A/B 已实施**（2026-09-12 用户批准；氛围档=静态+深色微呼吸；
> 节奏=B 后暂停真机验收）。A=风格档内核+seedColor 修复（2986867）；
> B=侧栏 4 类导航控件现代化+main_container 氛围层（8f50833）。Phase C1/C2/D 待验收后续排。
>
> **⚠️ 2026-09-12 深夜修订（用户指定）**：浅色主题中性色系由蓝灰改「**石英白**」方案，
> §4.1 浅色列以本修订为准——侧导航/画布/标题栏 `#F8F9FA`、卡片纯白 `#FFFFFF`、
> 主文字 `#1C1B1F`、辅助文字 `#49454F`、分割线 `#CAC4D0`（发丝线为 35% 透明度）、
> 占位字 `#79747E`、hover 面 `#ECEEF1`、嵌入面 `#E9EAEE`；强调色保持科技蓝
> `#3E6FE8`；描述更新为「现代石英白 · 柔光科技感」。深色主题不变。
>
> 日期：2026-09-12　|　取代：`modern_light_dark_theme_plan.md`（v1，纯换色版，已标 superseded）
> 稳定区：`lib/theme/`、`lib/main_container.dart`（Phase B 需改，本方案整体即授权请求）
> 假设沿用：「暖白」= 内置默认主题「暖阳」(warmSun)。

---

## 1. v1 为什么"只是换色"——诊断（重设计依据）

v1 在既有 37 个**色彩令牌**内重调了调色板，但手绘风的"骨"不在色彩令牌里，而是**硬编码在组件参数中**：

| 手绘特征 | 固化位置（证据） | 换色能否消除 |
|---|---|---|
| 硬偏移阴影（offset(2,2) + blur 0 的"贴纸影"） | 设置卡 settings_modal、主题卡、输入框 form_inputs.dart:66 等数十处 | ❌ 影子形状不在令牌里 |
| 粗描边（1.6~2px 实线勾边，标题栏 width:2） | custom_title_bar.dart:152、卡片、按钮 border | ❌ 线宽不在令牌里 |
| 直角/小圆角语言 + 方正卡面 | 各组件 BorderRadius 8~12 | ❌ |
| hover 仅"填色变化"、无抬升/辉光 | interactive_wrapper.dart:125-129 | ❌ |
| 页面底全平铺纯色，无氛围 | main_container 内容区 | ❌ |

**结论：必须给主题系统增加"风格档"层**——主题不仅带颜色，还带形状语言（线宽/圆角/阴影/交互反馈/氛围）。
这是 v2 的架构核心，也是「从零独立设计」在工程上的落点。

## 2. 架构：主题风格层（对 6 套老主题零影响）

### 2.1 CTThemeData 增加可选风格字段（schema 向后兼容）

```dart
enum CTVisualStyle { classicHanddrawn, aurora }   // 新枚举，默认 classicHanddrawn
```

CTThemeData 追加**单个**可选字段 `visualStyle`（构造默认 `classicHanddrawn`）：
- 6 套老主题不写该字段 → 行为与今天**逐像素一致**（有回归测试锁定，见 §12）；
- 序列化：顶层写 `'style': 'aurora'`（仅 aurora 时写）；旧 JSON 无此键 → 读出 classic；
  旧版本应用读到新 JSON 会忽略未知键 → 双向兼容，`schemaVersion` 保持 1；
- **顺带修复存量缺陷**：`seedColor` 往返丢失（toJson 写顶层 :217 / fromJson 读 colors 内 :276）——
  改为 colors 内写 + 双位置兼容读。此缺陷使所有用户主题加载后 M3 种子色回退暖棕，
  属主题序列化本体，纳入 Phase A。

### 2.2 新增 `AppStyle` 风格门面（与 AppColors 同款静态模式）

新文件 `lib/theme/app_style.dart`，从当前主题读风格档，**老调用点零改动，新调用点按需替换**：

```dart
class AppStyle {
  static CTVisualStyle get style;        // 当前主题风格档
  static bool get isModern;              // == aurora
  // —— 线宽档案 ——
  static double get wStrong;             // classic 2.0 / aurora 1.0（选中态描边）
  static double get wNormal;             // classic 1.6 / aurora 0.8（常规勾边）
  static double get wHairline;           // classic 1.0 / aurora 0.5（发丝线）
  // —— 圆角档案 ——
  static double get rSm, rMd, rLg, rXl;  // classic 6/8/10/12 / aurora 6/10/14/18
  // —— 阴影档案（BoxShadow 列表）——
  static List<BoxShadow> get e1, e2, e3; // 见 §7 阴影体系
  static List<BoxShadow> focusGlow(Color c); // 经典=无 / aurora=accent 辉光环
  // —— 派生色（代码派生，不进 JSON）——
  static Color get accentHover;          // lerp(accent, black/white, 0.10)
  static Color get accentPressed;        // lerp 0.18
  static Color get accentSoftBg;         // accent 10%（浅）/ 16%（深）
  static Color get ringColor;            // 选中环 = accent 45%
}
```

### 2.3 氛围光（柔和科技感的"环境层"）

在 main_container 内容区（`_buildBasePage` 容器，:761/:841 一带）加一层 keyed 装饰：
仅 `AppStyle.isModern` 时渲染，老主题零渲染：

- **顶部冷光洗**：线性渐变（accent 4% → 0，高约 220px）；
- **两团极淡辉光**：径向渐变（accent 2.5% / infoBlue 2%），右上 + 左下，直径约 45% 视口；
- 背景图开启时自动关闭（与 HallAmbientBackdrop 同规则）；默认**静态**（零运行时开销），
  可选"呼吸"档见 §13 问 2。

## 3. 设计语言「极光 Aurora」三支柱

1. **纯净表面**：去勾边、靠"底色分层 + 柔和海拔"区分层级；线只出现在发丝分隔与交互瞬间；
2. **单色科技蓝**：全应用唯一彩色强调（浅 #3E6FE8 / 深 #5B8DEF），选中/聚焦/进度/链接统一；
3. **环境光**：极低饱和的蓝调氛围层 + 交互瞬间的柔和辉光，科技感来自"光"而非"线"。

## 4. 色彩体系（完整）

### 4.1 中性色阶（12 档 → 令牌映射）

| 阶 | 浅色（冷灰白） | 深色（深空蓝黑） | 映射令牌 |
|---|---|---|---|
| N0 画布最亮 | #F7F9FC | — | background(浅) |
| N1 分区面 | #EFF2F8 | #131926 | sidebar/titleBar |
| N2 卡片面 | #FFFFFF | #1A2233 | buttonBackground |
| N3 hover 面 | #E8EDF6 | #232E45 | cardHoverBg |
| N4 嵌入面 | #E3E9F2 | #212B40 | addCoverBg / placeholderCover / toggleBg |
| N5 占位底 | #EDF1F7 | #1A2233 | placeholderBg |
| N6 发丝线 | #C3CEDD@20% | #2F3B52@20% | borderLight |
| N7 实线 | #C3CEDD | #2F3B52 | border |
| N8 占位字 | #9AA7BA | #5C6880 | placeholderText |
| N9 次要字 | #5C6B84 | #8D99AE | secondaryText / inputHint |
| N10 主字 | #1F2A3D | #E7ECF5 | primaryText / titleBrown |
| N11 纯黑/白极 | #FFFFFF | #0F141F | navActiveBg(白胶囊) / background(深) |

### 4.2 主色（强调）与辅助色

| | 浅色 | 深色 | 说明 |
|---|---|---|---|
| 主强调 selectedAccent | #3E6FE8 | #5B8DEF | 唯一彩色强调 |
| 派生 hover / pressed | 派生 -10% / -18% 亮度 | 派生 +8% / +16% | AppStyle 派生，不进 JSON |
| 软底 accentSoftBg | 10% 蓝 | 16% 蓝 | 选中行/图标容器底 |
| 辅助渐变 brandBlue | #5B8DEF | #5B8DEF | 与主色构成信息渐变对 |
| 信息 infoBlue / infoBg | #4377D6 / #EAF1FE | #6FA5F2 / #1A2742 | 链接/提示 |
| 种子 seedColor | #3E6FE8 | #4E8DF5 | M3 染色（修复往返后真正生效） |

### 4.3 功能色（新增 warning 语义，修 SnackBar 误用星金问题）

| 语义 | fg 浅/深 | bg 浅/深 | 现映射 |
|---|---|---|---|
| 成功 | #2FA46C / #4CC38A | #E4F5EC / #16281F | successGreen/successBg |
| 危险 | #E5484D / #F0666E | #FDEBEE / #301A1F | dangerRed/errorBg/hoverClose* |
| 警告（**新增 2 令牌** warningAmber/warningBg） | #B97D10 / #F5C04A | #FCF3E1 / #33290F | 替代 SnackBar 警告档误用的 starGold |
| 信息 | infoBlue / infoBg | 同左 | infoBlue/infoBg |

> 新增 2 个 CTThemeData 字段：构造可选（默认 = starGold 现值 / 浅金底），老主题零影响；
> withColor/lerp/toJson/fromJson 同步接入。星级 starGold 恢复纯星级语义。

## 5. 背景与层级

| 层 | 内容 | 浅色 | 深色 | 阴影档 |
|---|---|---|---|---|
| L-1 氛围 | 顶部冷光洗 + 两团辉光 | accent 4%→0 | accent 3%→0 | — |
| L0 窗口 | background | #F7F9FC | #0F141F | — |
| L1 分区 | 侧栏/标题栏 | #EFF2F8 | #131926 | 右/下 0.5px 发丝线 |
| L2 卡面 | 卡片/按钮/输入 | #FFFFFF | #1A2233 | 静息 e1，hover e2 |
| L3 浮层 | 弹窗/菜单/下拉 | #FFFFFF | #1A2233（不再用 sidebarBackground 当浮层底） | e3 + 1px 发丝线 |
| L4 顶浮 | SnackBar/悬浮按钮 | 同 L3 | 同 L3 | e3 + accent 微辉光 |

深色海拔规则：**越浮越亮**（#0F141F → #131926 → #1A2233 → #232E45 hover），阴影退居辅助。

## 6. 文字排版

字体三分工不变（F1 得意黑/F2 Outfit/F3 NotoSansSC，`app_styles.dart` 零改动）。
颜色角色映射走 §4.1 色阶；aurora 档排版微调（经 AppStyles 不动、仅新样式处生效）：
大标题字距 +0.2、正文行高维持现行；数字/英文优先 F2。对比度保障（深色）：主字对 L0
14.2:1、次要 4.8:1、accent 对卡面 4.0:1（UI 合规）、占位 3.1:1（占位语义允许）。

## 7. 边框与阴影（风格档核心差异）

| 项 | 暖白手绘档（现状，不动） | 极光档 |
|---|---|---|
| 勾边 | 1.6~2px 实线 | 0.5~1px；静息多为无勾边 |
| 卡片静息 | 边框 + 硬贴纸影 | 无边框 + e1（0,1,3,黑 8%/白 6%） |
| 卡片 hover | 填色变化 | translateY(-1) + e2（0,2,8,10%） |
| 选中 | border 加粗 | 1.5px accent 环 + 24% accent 外辉光（blur 6） |
| 焦点（键盘） | — | 2px accent 环 + blur 4 辉光 |
| 弹窗/浮层 | 1.5px 勾边 + 硬影 | 无勾边 + e3（0,8,24,14%）+ 发丝线 |
| 深色阴影 | 黑 40% 硬影 | 黑 30% 软影 + 亮海拔（§5） |

## 8. 组件状态规格（全部组件 × 全状态，两主题同构）

> 表中「accent 环」「辉光」仅 aurora 档生效；手绘档保持现状。深浅差异只体现为取
> §4 色阶值，形态规则完全一致（保证两主题风格统一）。

| 组件组 | 默认 | 悬停 | 点击(按下) | 选中 | 焦点 | 禁用 | 过渡 |
|---|---|---|---|---|---|---|---|
| 侧栏导航（展开/收起） | 透明底；激活=白胶囊(rMd)+e1+图标 accent(浅)/深蓝(深) | cardHoverBg 面 + wHairline 边 | scale 0.98 | 激活样式 + accent 环辉光 | 同聚焦环 | placeholderText 图标，无阴影 | 120ms fill / 180ms 形变 |
| 主页按钮 | L2 面 | e1→e2 抬升 | scale 0.97 | accent 环 | 聚焦环 | 38% 透明度 | 150ms |
| 标题栏 | L1 底 + 无勾边（发丝底线） | 窗口钮 hover 面 | 关闭钮 hover=危险 fg 8% 底 | — | — | — | 120ms |
| 游戏卡片（库/探索） | L2 面、无勾边、封面 rLg 裁切 | 抬升 + e2 + 标题变 accent | scale 0.98 | accent 环 + 辉光 | 聚焦环 | — | 180ms（恒定 Transform 结构保持） |
| 主页列表项 | 透明 | cardHoverBg + rMd | 0.98 | accentSoftBg + accent 环 | 聚焦环 | — | 120ms |
| 主按钮（确定/启动/应用） | accent 底 + 白字(浅)/白底深字见注 | accentHover | accentPressed | — | 聚焦环(外圈白隙) | 38% | 150ms |
| 次按钮（取消/返回） | 透明底 + wNormal 发丝边 + 主字 | accentSoftBg + accent 边 | 5% 压暗 | accent 环 | 聚焦环 | 38% | 150ms |
| info/danger/变体按钮 | infoBg/danger 8% 底 + 对应 fg | 加深 5% | 0.98 | — | 聚焦环 | 38% | 150ms |
| 输入框 | L2 底 + wHairline 边(rMd) | 边升 N7 | — | — | **accent 边 1.5px + 辉光** | 38% + 占位字 | 150ms |
| 下拉/菜单项 | L3 面 + e3 | accentSoftBg | 0.98 | accentSoftBg + accent 左条 3px | 聚焦环 | 38% | 120ms |
| 对话框 | L3 + e3 + rXl；标题 F1 | 遮罩黑 32%(浅)/48%(深) | — | — | — | — | 进出场 180ms fade+scale 0.96→1 |
| SnackBar 四态 | 功能色 fg 底 + 白字 + e3 + rMd | 悬停亮度 +4% | — | — | — | — | 250ms 滑入 |
| 开关/滑块/进度/Chip（M3） | seedColor 染色 | M3 默认 | M3 默认 | accent | — | 38% | M3 默认 |
| 标签/筛选 Chip | 透明 + 发丝边 | accentSoftBg | — | accentSoftBg + accent 字 | — | 38% | 120ms |
| Tooltip | 深色反转底（浅=深底白字/深=亮底深字） | — | — | — | — | — | 150ms |
| 滚动条 | thumb=N7 40%，rSm 胶囊 | thumb N7 70% | — | — | — | — | 150ms |
| 悬浮按钮（用户/任务） | L3 + e2 | 抬升 e3 | 0.97 | — | 聚焦环 | — | 150ms |
| 运行任务横幅 | L4 玻璃感面（accent 2% 混入） | 展开把手 hover 面 | — | — | — | — | AnimatedSize 260ms（现状保留） |
| 加载/骨架 | 占位底 N5 + 微 shimmer（aurora 档） | — | — | — | — | — | 1.2s 循环 |

注：主按钮文字色沿用 onPrimary=primaryText 现行映射（M3），深色下由 seed 派生保证可读。

## 9. 交互反馈与过渡动画体系

- **时长**：instant 120ms（fill/hover 色）/ base 180ms（形状/位移）/ slow 250ms（主题切换/面板）；
- **曲线**：统一 easeOutCubic（与现行主题切换一致）；按压缩放 0.97~0.98；
- **主题切换**：沿用 250ms 全令牌 Color.lerp；`visualStyle` 在 t=0.5 切换（阴影/圆角/氛围层
  随插值中点切换，一次交割、无中途混合态）；
- **辉光规则**：辉光只出现在"交互瞬间或激活态"（选中环/焦点/激活导航/悬浮按钮），环境光恒定
  极低饱和——避免"赛博朋克化"；
- **性能红线**：氛围层为静态渐变（零动画）；BackdropFilter 仅现状已有处（BPM），桌面新增**零**
  blur；shimmer 仅在显式加载态出现。

## 10. 覆盖面与不受影响清单

- 自动覆盖：全部 AppColors 驱动 UI（~3800 引用）+ M3 组件（seed 染色）+ 窗口底色联动；
- 需改调用点（Phase B/C 逐文件清单见 §11）：InteractiveWrapper、sidebar、custom_title_bar、
  main_container(氛围层+半圆按钮)、library_page/discover_page 卡片、home_page、
  game_detail_dialog、app_dialog/confirm_dialog/name_dialog、app_snack_bar、
  download_button、library_context_menu/tags_popup_menu/more-menus、
  settings_group_card/settings_tile/settings_modal 卡片、floating_*、running_task_bar、
  form_inputs(核心输入)、update_dialog/install_confirmation_dialog 等高频弹窗；
- **明确不动**：6 套老主题观感（回归锁）、BPM 全体系（BpmPalette→pushOverride 构造的
  CTThemeData 无 style 字段=classic 档，内嵌 JoinPage 保持 BPM 风格）、字体体系、
  explore_hall 装饰层（HallDecor 自有深浅分支，仅走查确认不冲突）、持久化 schema（保持 v1 兼容）。

## 11. 分阶段实施（每阶段独立提交+验证，可随时叫停）

| 阶段 | 内容 | 主要文件 | 验证 |
|---|---|---|---|
| **A 内核** | CTVisualStyle 枚举+字段、lerp/toJson/fromJson（含 style、warning 2 令牌、**修复 seedColor**）、AppStyle 门面、frost/obsidian 重调为 Aurora 色板并启用 aurora 档、单测（老档默认值锁 + 新档值 + JSON 往返） | app_theme_manager.dart、theme_registry.dart、app_style.dart(新)、theme_element_registry(新增元素可选)、test/theme/** | analyze + 新单测 + 全量 |
| **B 外壳** | 氛围层接入、侧栏导航/主页按钮/标题栏现代化（线宽/圆角/阴影/状态） | main_container.dart、sidebar.dart、custom_title_bar.dart | analyze + 全量 + **真机走查点 ①** |
| **C1 基建组件** | InteractiveWrapper(hover/按压/辉光)、对话框三件套、SnackBar、输入框、菜单、Chip、Tooltip/滚动条 | 上表组件各 1 文件 | 同上 |
| **C2 页面组件** | 卡片（库/探索/主页）、详情弹窗、设置卡片/行、下载按钮、悬浮按钮、横幅、高频弹窗 | library/discover/home/detail/settings 等 ~12 文件 | 同上 + **真机走查点 ②** |
| **D 拾遗走查** | 长尾弹窗/边角（走查发现清单驱动）、explore_hall 观感确认 | 按需 | 全量 + 全页面走查 |

## 12. 回归保障（老主题零影响的技术保证）

1. **默认值锁测试**：classic 档下 AppStyle 全部 getter == 旧硬编码值（wStrong=2.0、
   wNormal=1.6、阴影=offset(2,2)/blur0 等）——任何漂移测试即红；
2. 6 老主题 × 氛围层不渲染断言（`isModern == false`）；
3. JSON 兼容：无 style 键的旧 JSON 读出 classic；含 style 的 JSON 在旧版应用中安全忽略；
4. 全量测试基线（当前 456 过/1 失败——失败属并行会话 gal_game_detector 中间态，
   与本任务无关，每阶段跑完对比不得新增）。

## 13. 待你确认的三个点

1. **方案整体是否批准**（含稳定区 main_container 的氛围层接入、新增 warning 2 令牌、
   顺带修复 seedColor 序列化缺陷）；
2. **氛围特效档位**：静态氛围光（推荐，零性能成本）/ 静态+交互辉光外再加深色下极缓
   "呼吸"（60s 周期，GPU 成本极低但非常驻推荐）/ 最小化（无氛围层，仅扁平+交互辉光）；
3. **实施节奏**：A→B→D 连续推进（推荐，B 后先真机看外壳效果）；还是 A→B→C→D 全连续。

## 14. 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| 调用点替换遗漏导致 aurora 下仍见手绘残影 | P2 | §10 清单驱动 + 走查兜底；残留列 D 阶段拾遗 |
| 并行会话冲突（join/批 4 进行中） | P2 | 本方案不触碰 join/**（form_inputs 除外，C2 阶段与其协调）；提交前逐文件核归属 |
| 深色对比不足 | P2 | §4.1 色阶 + §6 对比度表先审后做；走查含 960×540 小窗 |
| 老主题回归 | P1 | §12 四重锁 + 每阶段全量测试 |
