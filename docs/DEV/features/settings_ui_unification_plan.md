# 设置页 UI 统一与可发现性改造方案

> 状态：**P1–P4 已实施**（2026-11-13，提交 `refactor(settings): 设置页 UI 统一`；实施记录见 §6，偏差见 §6.4）
> 触发：用户反馈「设置页复杂、找不到想要的设置、每个板块看着都难受」
> 前序：`settings_preference_ia_redesign_plan.md`（2026-09-08，Phase 0–2 已完成，**Phase 3/4 从未收尾**）
> 用户裁决（三选）：侧栏**仅四簇分组**（不做搜索框）／卡片**一组一张、卡内多行**／范围 **P1–P4 全做完**

---

## 0. 结论摘要（TL;DR）

设置页的问题**不是「内容太多」**（8 个 tab / 25 个分组 / ~70 个可调项，这个量级很正常），
而是三件事：

| # | 病症 | 一句话 |
|---|------|--------|
| **D1** | **两套视觉语言并存** | 一半页面是「无边框行 + 分组标题」，另一半是「每项一张 1.6px 边框 + 硬投影的重卡」。同一屏里两种粒度，眼睛无法建立秩序。 |
| **D2** | **卡片粒度错了一层** | 卡片应该包「一组设置」，现在包「一条设置」。一屏 5–6 个带边框的白/米色方框，全是等权重，**没有视觉落点**，所以「看着难受」。 |
| **D3** | **只有导航，没有检索** | 8 个 tab 平铺、名字是名词（「网络与存储」里塞了代理/下载/路径/归档/云备份/缓存 6 件事）。想调「缓存清理」得先猜它在哪个 tab —— **这就是「找半天」的真因**。 |

改造方向（**不推翻现有 IA，不碰业务逻辑**）：

1. **加搜索**：设置窗口顶部常驻搜索框，检索全部 8 个 tab 的 ~70 个设置项，点一下跳到对应 tab 并高亮该分组。解决「找半天」。
2. **侧栏分组**：8 个平铺项分 4 簇（我的 / 界面 / 游戏 / 系统），加簇标题。解决「一眼扫不出结构」。
3. **卡片下沉一层**：一章一组卡，卡内多行 + 发丝分隔线；行不再各自带框。**这是视觉观感提升最大的一步**。
4. **统一页头**：每个 tab 顶部「标题（20/600）+ 一句话说明」，替代现状 30px 装饰字 + 直接怼分组标题。

预估：新增 5 个文件、改 8 个文件，`settings_modal.dart` 净减约 600 行（拆出去而不是继续堆）。

---

## 1. 现状审计（全部带 `路径:行号`）

### 1.1 骨架

| 元素 | 现状 | 位置 |
|------|------|------|
| 窗口 | 默认 900×620，最小 820×520，最大 1200×860 | `settings_modal.dart:143-148` |
| 页头 | 高 **70**，装饰字 **30px** + `letterSpacing 2.0`，右侧 32×32 关闭钮（硬投影） | `:561-637` |
| 侧栏 | 宽 **200**，8 项平铺，无分组、无搜索，第 8 项需滚动才见 | `:639-700` |
| Tab 按钮 | 高 40、圆角 12、字号 **16**、图标 18、选中 = `buttonBackground` + 1.6px 边框 | `:702-743` |
| 内容区 | `padding all(24)`，`switch` 出 8 个页面 | `:745-773` |
| 分组 | `SettingsSection`：标题 `labelLarge(14/600)` + 描述 `labelMedium(12)` + 子项间 **8px** | `settings_section.dart:34-65` |
| 行 | `SettingsTile`：高 56/68、圆角 8、**无边框**、hover 变色 | `settings_tile.dart:69-140` |

### 1.2 两套视觉语言：证据

**语言 A（新，行列表）** —— `内容保护` / `元数据` / `大屏模式` 的开关部分：
`SettingsSection` + `SettingsSwitchTile`，无边框行、组标题 14px。

**语言 B（旧，重卡）** —— `游戏与启动` / `网络与存储` / `外观` / `关于`：

```dart
// settings_modal.dart:2090-2110  _buildAutoStartCard
Container(
  decoration: BoxDecoration(
    color: AppStyle.isModern ? AppColors.buttonBackground : AppColors.sidebarBackground,
    border: AppStyle.isModern ? Border.all(color: borderLight, width: wHairline)
                              : Border.all(color: border, width: 1.6),
    boxShadow: AppStyle.isModern ? AppStyle.e1 : [BoxShadow(color: borderLight, offset(2,2), blur 0)],
  ),
  padding: EdgeInsets.all(16),
  child: Row( icon 40×40 r8 / 标题 16 / 副标题 13 / Switch ),
)
```

`_buildAutoStartCard`（`:2089`）、`_buildAutoShortcutCard`（`:2185`）这两张卡**本质上就是**一行
`SettingsTile`（图标 + 标题 + 副标题 + 开关），却被写成了 40×40 图标、16px 标题、独立边框和投影。
同页 `游戏窗口` / `超分增强` / `游玩记录` 又是第三种写法。

**语言 C（第三套）** —— `个人资料`：`padding only(bottom: 9)` + 下边框的「✏️ 修改资料」标题
（`:1152-1179`，`fontSize 20`，颜色用 `AppColors.border`），`24px` 固定间距，自定义 `_buildFieldRow`。
和 A/B 都不兼容。

### 1.3 粒度错误：一屏 6 个等权重方框

`网络与存储` 一页（`:970-1017`）有 6 个分组：网络 / 大标题素材 / 游戏库目录 / 归档库 / 云备份 / 缓存。
其中 4 个分组里 **只有 1 张卡**。于是用户看到的是 6 个相互独立的米色方框，每个都要单独读一遍才发现
「原来这张框里只有一行字 + 一个开关」。信息密度被框线吃掉了。

### 1.4 硬数字（量化「混乱」）

```
settings_modal.dart                 5661 行     ← 单文件，8 个页面 + 全部卡片
BoxDecoration(...)                     76 处
BoxShadow / Border.all                 52 处
EdgeInsets 去重后                      40 种
fontSize 档位                          10 档（10/11/12/13/14/16/18/20/30/36）
SizedBox(height:) 去重后                8 种（4/6/8/10/12/14/16/24）
BorderRadius.circular 去重后            6 种（4/5/6/8/12 + 令牌 AppRadius.lg）
```

设计令牌（`AppSpacing` / `AppStyles` / `AppRadius`）**已经齐全**（`app_spacing.dart`、
`app_styles.dart:283-291`），问题是**没被用起来**。

### 1.5 IA 错配（用户点名的「猜不到在哪」）

| tab | 实际装了 | 问题 |
|-----|---------|------|
| 游戏与启动 | 系统 / 启动兼容性 / 游戏窗口 / 超分增强 / **游玩记录** | 「游玩记录」是统计口径，不是启动 |
| 大屏模式 | 背景视频 / 操作引导 / **手柄设置** | 手柄是全局输入设备，藏在「大屏模式」里没人找得到 |
| 网络与存储 | 网络 / **大标题素材** / 游戏库目录 / 归档库 / 云备份 / 缓存 | 「标题图素材」是元数据来源，跟网络存储无关 |
| 外观 | 软件主题 / 自定义设计 | 命名与内容基本对得上 |

### 1.6 页头层级塌陷

`设置 / Settings` 用 30px 装饰字（`:581-589`），而组标题 14px、行标题 14px（`titleSmall`）。
**页头与正文之间只有 1 个中间层级**，扫视时没有层级差 → 「打开就不知道该看哪」。

---

## 2. 设计规范（执行时严格照此，勿自由发挥）

### 2.1 三个层级（新增「页头」层）

| 层级 | 用途 | 字号/字重 | 颜色 | 间距 |
|------|------|-----------|------|------|
| L0 窗口标题 | 页头左侧「设置」 | 20 / 600（`titleMedium` 放大一档，**去掉 letterSpacing 2.0**） | `primaryText` | — |
| L1 页面标题 | 每个 tab 的内容标题 + 一句说明 | 20 / 600 + 12 / 400 | `primaryText` + `secondaryText` | 下 20 |
| L2 分组标题 | `SettingsSection.title` | 13 / 600（`labelMedium` 加粗） | `secondaryText` | 上 24（首组 0）、下 8 |
| L3 行 | 设置项 | 14 / 600 标题 + 12 / 400 副标题 | `primaryText` / `secondaryText` | 高 56（无副标题）/ 64 |

### 2.2 卡片：一章一卡

```
┌ 分组标题 ─────────────────────────────┐
│ ┌─────────────────────────────────┐  │
│ │ ▣  自动跟随系统代理        [开关] │  │
│ │ ─────────────────────────────── │  │  ← 发丝分隔线，左缩进 56（对齐文字起点）
│ │ ▣  代理地址        127.0.0.1:7890│  │
│ └─────────────────────────────────┘  │
└──────────────────────────────────────┘
```

| 属性 | 经典档（warmSun 等 handdrawn） | 极光档（frost / obsidian） |
|---|---|---|
| 卡面 | `sidebarBackground` | `buttonBackground` |
| 卡边框 | `Border.all(border, 1.6)` | `Border.all(borderLight, wHairline)` |
| 卡阴影 | `BoxShadow(borderLight, (2,2), blur 0)` | `AppStyle.e1` |
| 圆角 | `AppRadius.md(8)` | `AppStyle.rMd(10)` |
| 卡内 padding | `EdgeInsets.symmetric(vertical: 4)` | 同 |
| 行分隔线 | `borderLight`，1.0 | `borderLight`，0.5 |
| 行 hover | `cardHoverBg`，120ms | 同 |

**硬约束**：卡内**不得**再出现带边框/阴影的子块（消除「框中框」）。
需要强调的子块（如账号卡、路径展示）一律改成 `placeholderBg` 填充 + 圆角 8，无边框。

### 2.3 侧栏（4 簇）

```
检索输入框  ⌕ 搜索设置…
─────────────────────
我的
  个人资料
界面
  外观
  大屏模式
游戏
  游戏与启动
  元数据
  内容保护
系统
  网络与存储
  关于应用
─────────────────────
  ← 返回
```

- 簇标题：11 / 600，`secondaryText.withOpacity(0.75)`，`letterSpacing 0.6`，上下留 8/4。
- Tab 高 40 → **36**，字号 16 → **14.5**（`navActive` 级别），图标 18 → 16，内距 12。
  8 项 + 4 簇标题在 820×520 下仍可完整显示（4×18 + 8×36 + 3×8 = 384 ≤ 可用 448，**不再需要滚动**）。
- 选中态沿用现有语义（`buttonBackground` + 1.6px 边框），极光档用 `navActiveBg` + `navActiveBorder`。

### 2.4 搜索

- 位置：页头中部（标题右侧），宽 220，高 32，圆角 `pill`，`placeholderBg` 底，无边框；
  聚焦时 1.6px `border` 描边。占位符「搜索设置…」，右侧 `Esc` 提示。
- 行为：输入即过滤（无防抖，本地数组）；`↓/↑` 选择、`Enter` 跳转、`Esc` 清空。
- 结果区：覆盖内容区（不弹新窗口），每条两行：**标题** / `分组 · tab名`；命中片段高亮。
- 空结果：「没有找到「xxx」——试试 代理 / 缓存 / 主题 / 令牌」。
- 跳转：切 tab → `Scrollable.ensureVisible(分组, 300ms, alignment 0.08)` → 该组卡片描边脉冲 1 次（600ms）。

### 2.5 图标与配色

- 行图标容器 **32×32 / 图标 18**（现状有 40×40/22，统一到 32）。
- 状态色只用三种：开 `successGreen`、关 `secondaryText`、警告 `kSettingsWarning`。
- 圆角只允许 `AppRadius.md(8)` / `AppRadius.lg(12)` / `pill(20)`。

---

## 3. 实施阶段（每阶段独立提交 + 探针）

### P1 · 骨架与可发现性（本轮先做）

| 文件 | 动作 |
|------|------|
| `settings/settings_tab_meta.dart`（新） | `SettingsTabMeta` 增加 `description`；新增 `SettingsTabGroup`（4 簇） |
| `settings/settings_search_index.dart`（新） | ~70 条 `{tab, group, title, keywords}` 静态索引 |
| `settings/settings_search_field.dart`（新） | 搜索框 + 结果列表（纯 UI，回调上抛） |
| `settings/settings_page_header.dart`（新） | L1 页头（标题 + 说明） |
| `settings/settings_anchor.dart`（新） | 分组锚点注册表 + `ensureVisible` + 高亮脉冲 |
| `settings_modal.dart` | 页头高 70→64、标题 30→20；侧栏分簇 + 内嵌搜索框；内容区挂页头；`_jumpTo` |

验收：搜索能命中每个 tab 至少 3 条；最小窗下侧栏不需滚动；0 溢出。

### P2 · 卡片下沉（视觉收益最大）

| 文件 | 动作 |
|------|------|
| `settings/settings_group_card.dart`（新） | 组卡容器（经典/极光两档参数） |
| `settings/settings_section.dart` | `children` 自动包进组卡；`boxed: false` 逃生舱 |
| `settings/settings_tile.dart` | 增加 `showDivider`；行高 56/64；图标统一 32 |
| `settings_modal.dart` | `_buildAutoStartCard` / `_buildAutoShortcutCard` 等 **12 处手写重卡** → `SettingsTile` |

验收：全页 grep 不到「卡内再 Border.all」；一屏可见设置项数量 ≥ 现状 1.6 倍。

### P3 · 逐页重排（含 IA 微调）

1. **个人资料**：删掉「✏️ 修改资料」边框标题 → L1 页头 + 一张「账号」卡（头像行 / 昵称 / 简介 /
   保存按钮贴卡底右侧）。业务逻辑零改动。
2. **网络与存储**：6 组 → 4 组（网络 / 下载与缓存 / 存储位置 / 归档与云备份）；
   「大标题素材」**移到元数据**页（它本质是元数据来源的 Key）。
3. **游戏与启动**：把「游玩记录」并入「系统」组，或保持独立但改名「统计口径」。
4. **大屏模式**：手柄设置单独成组「输入设备」，不再藏在背景视频后面。
5. **关于应用**：统一 L1 页头；版本卡 / 开源链接 / 致谢三块保持现有位置。

### P4 · 收尾

- 字号收敛到 11/12/13/14/16/20 六档；间距收敛到 `AppSpacing`。
- 每个 tab 的 `description` 写「一句话说清这页能干什么」。
- `settings_modal.dart` 目标 ≤ 4800 行（拆出去的分页各自成文件）。

---

## 4. 风险

| # | 风险 | 处置 |
|---|------|------|
| R1 | `InteractiveWrapper` 会给子项加缩放/位移（`interactive_wrapper.dart:69-77`），行内按钮包了会双触发 | 行内控件**一律不包**，只用 `SettingsTile` 自带的 hover |
| R2 | 820×520 下溢出（历史踩过 41px） | 侧栏改 36 高后余量 64px；内容区继续「只有中点可滚」 |
| R3 | 现有探针按文案/按钮定位（`settings_modal_metadata_probe` 的 `tapTab('元数据')`） | P1 后先跑旧探针，按失败项改断言，**不改探针语义** |
| R4 | 两档主题（classic / aurora）观感必须都对 | 组卡参数走 `AppStyle.isModern`，不看死颜色 |
| R5 | 页面内藏业务逻辑（保存资料 / 头像 / 更新检查 / Magpie） | 只换容器，不搬逻辑；**不动** `lib/theme/`、`main.dart`、`main_container.dart` |
| R6 | release 下整页灰块 = build 抛异常 | 每次改 `build` 必跑 flutter_tester 整屏探针 + 断言「必然存在的文案」 |
| R7 | 工作区有 300+ 别人的未提交文件 | 显式 `git add` 单文件，禁 `-A` |

---

## 5. 验收

- 新增探针 `settings_shell_probe`（骨架 + 8 tab × 2 尺寸 + 极光档，共 **75 PASS**）。
- 既有 `settings_modal_metadata_probe`(63) / `settings_modal_proxy_probe`(26) 全绿。
- 820×520 与 1280×720 两尺寸 × 8 个 tab：0 溢出、0 异常。
- 侧栏第 8 项在 820×520 下 `bottom=467 ≤ 520`（几何断言，非「文案在树里」）。

---

## 6. 实施记录（2026-11-13）

### 6.1 新增文件

| 文件 | 作用 |
|------|------|
| `lib/widgets/settings/settings_group_card.dart` | 组卡容器（`SettingsGroupCard`）+ 卡内说明行（`SettingsCardNote`） |
| `lib/widgets/settings/settings_page_header.dart` | 一级页头（`SettingsPageHeader`） |
| `lib/widgets/settings/settings_segmented.dart` | 行尾分段选择器（`SettingsSegmented`） |
| `dev_probe/settings_shell_probe.dart` | 骨架 / 8 tab / 两尺寸 / 两风格档回归探针（75 条） |

### 6.2 改动要点

- `settings_tab.dart`：`SettingsTabMeta` 增加 `cluster` + `description`；新增 `SettingsCluster`（我的/界面/游戏/系统）与 `ofCluster()`。
- `settings_section.dart`：新增 `boxed`（默认 **false**，逐页迁移，未迁移处零变化）+ `trailing`。
- `settings_tile.dart`：带副标题行高 68→64；新增 `subtitleTooltip`（超长路径悬浮看全）。
- `settings_switch_tile.dart`：新增 `activeColor`（兼容历史上的紫/青功能色开关）。
- `settings_modal.dart`：
  - 页头 70→64、标题 30→**22**（装饰字保留，去一半字距）；
  - 侧栏 8 项平铺 → **4 簇**；tab 40→**34**、字号 16→14、图标 18→16；返回按钮 32→30；
  - 内容区统一挂 `SettingsPageHeader`，8 个页面不再各画标题；
  - 组卡迁移 6 处：开机自启 / 快捷方式 / 启动兼容性 ×2 / 快捷窗口 / 游玩记录 ×2 / 下载强度 ×5 / 游戏库目录；
  - 个人资料页重排（删「✏️ 修改资料」下边框标题；输入框去硬编码 `width: 442`；保存按钮 55→40、右对齐）；
  - 「大标题素材」移到元数据页；「减少动效」独立成组；「官方视频抓取」独立成组。
- 行数：`settings_modal.dart` **5661 → 5108**（−553）。

### 6.3 探针结果

```
settings_shell_probe            75 PASS / 0 FAIL
settings_modal_metadata_probe   63 PASS / 0 FAIL
settings_modal_proxy_probe      26 PASS / 0 FAIL
------------------------------------------------
合计                           164 PASS / 0 FAIL
analyze 10 文件                 0 error（6 warning 均为改造前既有）
```

### 6.4 与方案的偏差 / 遗留

1. **搜索框没做**：用户裁决「仅四簇分组」。`§2.4` 的设计保留在文档里——如果簇分组上线后仍觉得找不到，搜索是纯增量（约 200 行，不动现有结构）。
2. **`手柄映射` 组仍是「裸列表」**（`gamepad_settings_section.dart:213` 未 `boxed`）：它内部是 `Row + ListTile` 混排、`contentPadding: zero`，直接塞进组卡会贴边，需要先重排它自己的列表行。留作下一轮。
3. **代理 / Magpie / 缓存 / 归档库 / 云备份 / 主题设计器**保持原样（`boxed:false`）：它们各自就是「一整块表单 = 一组」，已经满足「一组一张卡」，内部重排属于另一个量级的活。
4. **`_buildNotificationCard`（`settings_modal.dart:2053`）仍是死代码**：analyzer 报「未引用」。历史上它就没被挂载过，本次按项目规矩**不删**，需要单独批准。
