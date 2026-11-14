# 全局按钮质感与交互反馈升级计划

> 状态：**计划待批准**（阶段 A 全局研究已完成，未动代码；批准后按批实施）
> 日期：2026-09-13
> 输入：用户反馈——"很多按钮只是背景色+描边毫无质感，部分主题下看不清（添加页
> 确认入库/取消），交互反馈基本没设计"。以三大系统主题（暖阳/浅色/深色）为准。

---

## 1. 全局研究结论（问题全景）

### 1.1 P0 · 语义失效——「border 令牌被当语义色用」（看不清的根因）

按钮组件把 `AppColors.border` 当"主色"、`background` 当"文字色"用。暖阳时代
border=暖棕≈品牌色所以成立；**极光档 border=中性灰（#CAC4D0/#2F3B52）→ 全崩**：

| 位置 | 现状 | 浅色(frost)实况 |
|---|---|---|
| 添加页 `action_buttons.dart:100` 确认入库 | border 色当底 + background 色当字 | 淡灰底+灰字，对比 **~1.6:1**（用户点名） |
| `action_buttons.dart:74` 取消 | background 底 + border 色字 | 白底+淡灰字，**看不清** |
| 主页 `home_page.dart:817-821` 启动按钮 | **硬编码暖阳时代浅蓝**（0xFF5A8FD4/1A3560/B4D4FF） | 三大主题全部不融洽 |
| 主页 `home_page.dart:842` 详情按钮 | border 边 + titleBrown 阴影 | 与入库按钮同病 |
| `field_lock_button` | border@15% 底 + border 色图标 | 锁定态几乎不可见 |

### 1.2 P1 · 同病按钮族（border 系散布）

`swipe_switcher`、`undo_redo_bar`、`batch_import_section`、`smart_import_section`、
`metadata_source_settings_dialog`、`exe_selector_dialog`、`launch_manager_dialog`、
`user_profile_modal`、`payment_modal`、各弹窗底部按钮——同一"border 当主色"模式。

### 1.3 P2 · 交互反馈缺失

- `GestureDetector+Container` 直连按钮散布 43 文件（多数无 MouseRegion → 无 hover）；
- `home_page._HoverButton`（私有复刻）：hover 仅阴影 blur 变化，无明度反馈；
- `InteractiveWrapper` 默认只有缩放位移，无填充/边框反馈（hover 反馈靠调用方传参，多数没传）；
- 禁用态普遍"仅 onTap=null"，无视觉禁用。

### 1.4 P3 · 四套按钮实现并存

`HoverButton`（3 处）/ `home_page._HoverButton`（私有复刻）/ InteractiveWrapper+手搓
Container（63 文件）/ TextButton（对话框）——语义变体（主/次/幽灵/危险）无统一实现。

## 2. 设计方案：「CtButton 语义按钮体系」

### 2.1 四个语义变体（全部令牌驱动，零新 JSON 令牌）

| 变体 | 底色 | 文字/图标 | 边框 | 用途 |
|---|---|---|---|---|
| **primary 主操作** | `AppStyle.primaryButtonFill`（手绘档=border 色 → 暖阳保持棕底米白字原味；极光档=selectedAccent） | `AppStyle.primaryButtonInk`（手绘档=background 色；极光档=白） | 同底色（无边视觉） | 入库/确定/保存/启动 |
| **secondary 次操作** | buttonBackground（白卡） | primaryText | borderLight 发丝 | 取消/返回/次要 |
| **ghost 幽灵/图标** | 透明 | secondaryText（hover→primaryText） | 透明（hover→accentSoftBg 底） | 小图标钮、锁定钮、工具钮 |
| **danger 危险** | 手绘档 errorBg / 极光档 dangerRed 8% | dangerRed | dangerRed 30% | 删除/清空 |

> 关键派生（进 AppStyle，classic 档锁定现值）：
> `primaryButtonFill` = classic→AppColors.border / aurora→selectedAccent；
> `primaryButtonInk` = classic→AppColors.background / aurora→Colors.white。
> 效果：暖阳=棕底米白字（历史原味）、浅色=科技蓝底白字、深色=亮蓝底白字——三主题全部融洽。

### 2.2 质感与交互规格（极光档；手绘档保硬影语言但换语义令牌）

| 状态 | primary | secondary / danger | ghost |
|---|---|---|---|
| 静息 | accent 底 + 顶部微光泽（白 10%→0 渐变）+ e1 | 白底发丝边 + e1（classic 硬影） | 透明 |
| 悬停 | accentHover 底 + e2 抬升（120ms） | accentSoftBg 底 + accent 发丝边 | accentSoftBg 底 |
| 按压 | accentPressed 底 + scale 0.98（120ms） | 填充压暗 5% + scale 0.98 | scale 0.96 |
| 选中（可保持态） | — | accent 发丝边 + accentSoftBg | accentSoftBg + accent 图标 |
| 禁用 | 底/字 38% 灰化 + 无阴影 + basic 光标 | 同左 | 图标 38% |
| 焦点（键盘） | 2px accent 外环 + 辉光 | 同左 | 同左 |

尺寸档：lg 高 56（入库/下载）/ md 高 40（弹窗行内）/ sm 高 32（小操作）；
圆角 rLg/rMd/rSm；统一 120ms easeOutCubic。

### 2.3 实现载体

- **升级 `HoverButton`** → 全语义变体（`CtButtonVariant` 枚举 + `size` 档），
  InteractiveWrapper 继续负责缩放位移，HoverButton 负责填充/边/阴影/光泽；
- `AppStyle` 新增 4 个派生 getter（primaryButtonFill/Ink + dangerSoftBg 等，
  classic 档锁旧值 + 单测锁定）；
- `home_page._HoverButton` 私有实现**删除**，调用点换 HoverButton（消灭复刻）。

### 2.4 分批实施（每批独立提交+验证）

| 批 | 内容 | 文件 |
|---|---|---|
| **批 1** | HoverButton 语义化升级 + AppStyle 派生色 + classic 锁测试 | interactive_wrapper.dart、app_style.dart、test/theme/ |
| **批 2 · P0** | 添加页入库/取消换 primary/secondary + 禁用视觉差；主页启动/详情换 HoverButton（消灭硬编码浅蓝 + 删私有实现）；field_lock 换 ghost 选中态 | action_buttons.dart、home_page.dart、field_lock_button.dart |
| **批 3 · P1** | border 系热点替换：undo_redo_bar、swipe_switcher、batch/smart_import_section、metadata_source_settings_dialog、exe_selector、launch_manager、user_profile、payment 等 | 上述 ~10 文件 |
| **批 4 · P2** | 走查驱动补反馈：GestureDetector 直连按钮收编 HoverButton(ghost)/InteractiveWrapper+hover 参数；禁用态补齐 | 按走查清单 |
| 拾遗 | 长尾弹窗按钮 + 真机走查清单 | 按需 |

**明确不改**：TextButton（confirm/name 对话框已达标）、download_button（上一批
已现代化）、BPM 体系、6 老主题的非按钮部分；不加 pubspec 依赖。

## 3. 验证

1. analyze 触达文件 0 新增 error；test/theme（含新增 classic 锁定断言）+ 全量对照基线；
2. 真机走查：暖阳/浅色/深色 × {添加页入库/取消（含禁用态）、主页启动/详情、
   设置弹窗、右键菜单、撤销栏、锁定钮}——每按钮看 静息/悬停/按压/禁用 四态
   与主题融洽度。

## 4. 风险

| 风险 | 缓解 |
|---|---|
| 暖阳原味走样 | classic 档 primary=border 色逐值锁定 + 用户走查暖阳首验 |
| 批 3 波及面大 | 每文件独立小改 + 单独提交，可随时叫停 |
| 并行会话冲突 | 提交前逐文件核归属（join/ 区文件尤为注意） |
