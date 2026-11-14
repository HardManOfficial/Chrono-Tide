# 大屏模式 BPM v3 — Cinema 沉浸式全屏舞台重构

> 建立日期：2026-09-09　状态：**v3.1 导入线已推翻重做——直接对接桌面 JoinPage（见 §8）**
> 参考项目：`其他开发者的项目用于本项目参考/gal-launcher-main/gal-launcher-main`
> 参考主题：Cinema · 沉浸式全屏舞台（`src/layouts/CinemaLayout.tsx` + `design-mockups/themes/cinema.css`）

---

## 1. 背景与目标

用户对 v2 大屏模式（BPM）的 UI 与功能设计「非常不满」，决定整体重构。

**使用场景定位**：串流移动端玩家（手机 / 平板）+ 需要大屏幕沉浸式的用户。

**核心决策（用户拍板）**：
1. UI 直接模仿 gal-launcher 的 **Cinema · 沉浸式全屏舞台** 主题。
2. 大屏模式**定位为本地模式**：只管理本地游戏，**不做探索页**（云端下载）。
3. 三个页面：主页 / 我的库 / 添加游戏（导入窗口，非独立页面）。
4. 「添加游戏」是**导入窗口**：点 rail 按钮 → 横向大选项框（三张二次元素材图）→ 对应导入功能窗口（导入文件区 / 数据预览编辑区 / 元平台板块区）。
5. 智能导入**完整 BPM 化重写**（不嵌入桌面组件外壳）。
6. 导入窗口呈现为**居中大对话框**。

---

## 2. 视觉基调（Cinema 拆解）

| 元素 | 取色 / 做法 | BPM 令牌 |
|---|---|---|
| 页面深底 | `#0c0f16` | `BpmColors.deepBase` |
| 玻璃面板 | `rgba(16,22,32,.42)` | `BpmColors.panelGlass` / `deepPanel` |
| 主文字 | `#fff7f8` | `textPrimary` / `textSecondary` / `textMuted` |
| 雾蓝（meta / 次强调） | `#9ed0ea` / `#b8d4e3` | `mistBlue` / `mistBlueSoft` |
| 樱粉（主强调 / 焦点辉光） | `#e89aa8` | `cherryRose` |
| 启动按钮渐变 | `#fff2f6 → #e89aa8 → #b8d4e3` | `playButtonGradient` |

**布局结构**：全屏 backdrop（舞台焦点游戏封面 + 横纵双向渐变遮罩）→ 左侧竖 rail 导航 → 右侧 stage（hero 舞台 + 底部 shelf 封面横排 / poster wall 海报墙）。

---

## 3. 交付内容

### 阶段① Cinema 外壳（commit `0490c87`）

| 文件 | 说明 |
|---|---|
| `lib/big_picture/big_picture_theme.dart` | **追加** `BpmColors` 色板 + 布局常量。**保留全部旧常量**，保证 `big_picture_detail.dart` / `big_picture_action_sheet.dart` / `focus_glow.dart` 不断编译 |
| `lib/big_picture/widgets/big_picture_nav_bar.dart` | 重写为 Cinema glass rail：主页 / 我的库 / 添加游戏 + 退出。**移除探索页入口** |
| `lib/big_picture/big_picture_shell.dart` | 重写为 backdrop + rail + stage；`AnimatedSwitcher` 200ms fade 切换；ESC 返回、Ctrl+F 聚焦搜索 |

### 阶段② 主页（Cinema「全部游戏」式）

`lib/big_picture/pages/big_picture_home.dart`（927 行）
- **hero 舞台**：选中游戏封面作为全屏 backdrop（由 shell 提供）+ 三段式信息层 + 启动 / 资料浮动按钮。
- **底部 shelf**：横向封面排，选中项上浮 + 樱粉辉光；支持滚轮横向滚动（`PointerScrollEvent`）。
- 顶部搜索 pill（2026-10-18 起**不再有续玩 chips**）。

#### hero 信息层（2026-10-18 三段式改版）

| 段 | 内容 | 关键尺寸 |
|---|---|---|
| ① 标题 | 标题图 logo（`logo_file`）优先，缺图回退得意黑文字 | 文字 `heroTitleSize = 72`；logo `≤620×144` |
| ② 会社 | **只有会社 + 发售年份**（`公司名  ·  2019`），独立一行 | `heroMetaSize = 14`，字距 2.5，`mistBlue` |
| ③ 标签 | 小型圆角方框 Wrap，最多 5 个（全局隐藏标签同样生效） | 字号 11.5 / r5 / padding 9×3 |
| ④ 简介 | `description` 最多 3 行 | 13.5px，行高 1.62，最大宽 600 |

- 🔴 **主页不展示副标题**（用户 2026-10-18 拍板）；副标题仍在二级详情页保留。
- 🔴 会社与标签**不得混排**：旧版 `会社 · 标签1 · 标签2` 单行已废弃（会社、标签是两类数据）。
- ①→② 之间固定 40px：这就是「标题往上、会社与标签往下」的视觉分离手段。
- 标签 Wrap 必须包 `ConstrainedBox(maxWidth: 600)`：hero 外层 `Positioned` 无 `right`，宽度约束是 loose，Wrap 在无界宽度下不会换行。
- 主页卡片隐藏（`bpm_home_hidden`）：详情页「⋯ → 主页卡片」切换；shelf 过滤，其余入口不受影响。

### 阶段③ 我的库（Cinema「收藏展示框」式）

`lib/big_picture/pages/big_picture_library_page.dart`（1085 行）
- **poster wall 海报墙** + 顶部收藏夹筛选 chips。
- 收藏夹管理：新建 / 重命名 / 删除 / 置顶（走 `CollectionService`）。
- 游戏加入 / 移出收藏夹；搜索 / 排序；长按动作表复用 `BigPictureActionSheet`。

### 阶段④ 添加游戏导入线

| 文件 | 说明 |
|---|---|
| `lib/big_picture/widgets/bpm_import_mode_sheet.dart` | 居中大对话框：单文件 / 批量 / 智能 三个横向大选项框，背景用三张素材图 |
| `assets/bpm_import/{mode_single,mode_batch,mode_smart}.png` | 素材图（源自 `D:\CTLIB\素材`），已在 `pubspec.yaml` assets 段登记 |
| `lib/big_picture/pages/big_picture_join.dart` | 三种模式的对话框外壳 + 单文件导入内容（复用 `JoinController`） |
| `lib/big_picture/pages/bpm_batch_import_content.dart` | 批量导入（复用 `BatchImportController`，三分区布局） |
| `lib/big_picture/pages/bpm_smart_import_content.dart` | **智能导入 BPM 化重写**（1291 行），功能面对齐桌面版 `SmartImportSection` |

**智能导入 BPM 化差异**：
- 布局改**左右双栏**（左：监控文件夹 + 导入设置；右：发现队列 + 忽略列表），适配 16:9 大屏，避免超长单列滚动。
- 控件放大到触摸友好尺寸（主操作胶囊高度 36，图标按钮 40×40，启用开关 44×28）。
- 视觉走 Cinema 玻璃卡片；下拉框使用 `dropdownColor: BpmColors.deepPanel` 避免系统浅色弹层。
- **不使用桌面版的「左侧表单联动」**（BPM 无 SwipeSwitcher 表单），元数据直接在候选卡片内展示，入库走 `WatchFolderService.confirmCandidate`。

---

## 4. 明确未改动（稳定区 / 复用区）

- `lib/theme/**`、`lib/main.dart`、`lib/main_container.dart` —— 稳定区，未触碰。
- `lib/big_picture/pages/big_picture_discover.dart` —— **文件保留但 BPM 不再引用**（本地模式）。桌面探索页不受影响。
- `lib/big_picture/pages/big_picture_detail.dart` —— 保留复用，作为「资料」入口。
- `lib/pages/join/**` 桌面入库页 —— 完全未改，BPM 仅复用其 Controller / 组件。
- `JoinController` / `BatchImportController` / `WatchFolderService` / `CollectionService` —— 业务逻辑零改动。

---

## 5. 验证情况

| 项 | 结果 |
|---|---|
| `flutter analyze lib/big_picture` | ✅ **0 error / 0 warning**（187 条 prefer_const info，属存量风格提示） |
| `flutter analyze lib`（全库） | ✅ 无新增 error |
| 全量测试 | ✅ **330 通过 / 11 失败**（基线 327/13）—— 见下 |
| 真机走查 | ⚠️ **未做** |

**测试说明**：
- 基线 13 个失败中有 3 个来自 `big_picture_nav_bar_test.dart`，根因是**测试未注册内置主题**，`FocusGlow` 读 `AppThemeManager.colors` 时 `_themes` 为空抛 null check。
- 已在测试 `setUp` 补 `ThemeRegistry.registerBuiltinThemes()` → 3 个转通过，并新增「添加游戏」用例（共 4/4 通过）。
- 剩余 11 失败 = `focus_glow_test` 10 个（同一根因的存量，**按约定不修**）+ `gal_game_detector_test` 1 个（网络偶发）。
- 总量 340 → 341（新增 1 个用例）。

---

## 6. 已知问题与遗留

| 优先级 | 问题 | 建议 |
|---|---|---|
| P1 | 未真机走查：backdrop 渐变强度、shelf 上浮幅度、海报墙密度需实机观感调整 | 构建 Release 后按下方清单走查 |
| P2 | 智能导入素材图 `mode_smart.png` 原图仅 145×204，放大渲染可能糊 | 已加遮罩兜底；建议用户提供大图替换 |
| P2 | `big_picture_discover.dart` 成孤儿文件（BPM 不再引用） | 保留待定；若确定永久不做 BPM 探索，可考虑归档 |
| P3 | 智能导入 BPM 版不支持「候选 → 表单编辑 → 保存回候选」联动（BPM 无表单区） | 如需编辑候选元数据，后续可在候选卡片内加就地编辑 |

---

## 7. 真机走查清单（待执行）

- [ ] 主页：backdrop 封面切换是否跟手；hero 文字在浅色封面下是否可读
- [ ] 主页 shelf：滚轮横向滚动是否顺畅；选中上浮 + 樱粉辉光观感
- [ ] 我的库：海报墙密度是否合适；收藏夹筛选 chips 是否够大（触控）
- [ ] 我的库：新建 / 重命名 / 删除收藏夹是否即时刷新
- [ ] 添加游戏：三个选项框素材图是否变形；点击响应区域是否够大
- [ ] 单文件导入：拖入 / 选择 → 元数据抓取 → 入库全链路
- [ ] 批量导入：多文件夹拖入 → 队列导入 → 进度
- [ ] 智能导入：添加监控文件夹 → 扫描 → 候选入库 / 忽略 / 恢复
- [ ] rail 导航：焦点框移动、ESC 返回、Ctrl+F 聚焦搜索
- [ ] NSFW：各模式（clean / work）下封面模糊是否正确（铁律：`contentKind: cover`）


---

## 8. v3.1（2026-09-09 晚）：导入线推翻重做——直接对接桌面 JoinPage

### 8.1 问题与根因

用户实测反馈 BPM「UI 和功能均不可用，添加/导入完全失效」：点击导入没有任何成功结果、
元数据抓取辅助填充不工作。

**根因**：v3 自研的导入对话框（`big_picture_join.dart` / `bpm_batch_import_content.dart` /
`bpm_smart_import_content.dart`）虽然调用了 `JoinController` / `BatchImportController`，
但**没有接上桌面 `JoinPage` 的胶水层**——`initListeners`、进度 Overlay
（`JoinProgressDialog` 的 `_showProgress`/`_dismissProgress` 生命周期）、
`MetadataSection` 元数据抓取联动、`handleExtractSuccess`、批量↔表单双向同步
（`_syncBatchGameToSingleForm`/`_saveSingleToBatchGame`）、智能候选联动等十余处衔接。
"看似复用 Controller，实则整条链路断裂"。

### 8.2 用户拍板

BPM 是**同一软件的模式切换**，不是独立产品：
1. 移除 BPM 智能导入，仅保留单文件导入与批量导入；
2. 导入功能直接复用桌面版已有实现，功能与使用体验对齐；
3. 修复后单文件/批量导入均能正常完成，元数据抓取与桌面表现一致。

### 8.3 变更清单（commit `8c6e868` / `d6fb369` / `0a739fb`）

| 文件 | 改动 |
|---|---|
| `lib/pages/join_page.dart` | **最小侵入**：加 2 个默认值不变的可选参数 `enableSmartImport`（默认 true）、`initialMode`（默认 `ImportMode.single`）。`enableSmartImport=false` → 给 SwipeSwitcher 传 `smartModeChild: null`（该组件本就支持 null 隐藏智能按钮，**swipe_switcher.dart 零改动**）。桌面调用处不传参 → 行为完全不变 |
| `lib/big_picture/big_picture_shell.dart` | stage 新增第 2 页 = 导入页：**直接渲染桌面 `JoinPage`**（`enableSmartImport: false` + `initialMode` 按选项框所选 + 传入 BPM 持久 `BatchImportController`，对齐桌面 main_container 全局控制器模式，页面切换不丢批量队列）；ESC 在导入页 → 回主页 |
| `lib/big_picture/widgets/bpm_import_mode_sheet.dart` | 移除智能导入选项（三选变两选，宽度 980→720），`BpmImportMode` 枚举删 `smart` |
| `lib/big_picture/widgets/big_picture_nav_bar.dart` | 「添加游戏」在 `currentPage == 2` 时高亮（与页面项一致） |
| 删除 | `lib/big_picture/pages/big_picture_join.dart`、`bpm_batch_import_content.dart`、`bpm_smart_import_content.dart`、`assets/bpm_import/mode_smart.png` + pubspec 对应登记行 |

### 8.4 效果

单文件导入 / 批量导入的文件选择、**元数据抓取辅助填充**（`MetadataSection`）、双标题切换、
封面/截图、进度对话框、批量↔表单联动，与桌面模式**代码级同源，零差异**。
BPM 与桌面仅剩模式差异（Cinema 外壳、本地库限定）。

### 8.5 验证

- analyze 全库 **0 error / 0 warning**（`lib/big_picture` + `join_page.dart` 142 条 info 全为存量 prefer_const）
- `test/big_picture`：21 通过 / 10 存量失败（与基线一致，nav_bar 4/4 过）
- 全量：**331 通过 / 10 失败**（基线 327/13；10 全为 focus_glow 存量，零新增）
- ⚠️ 未真机走查（导入全链路需实机：选文件 → 元数据抓取 → 入库 → 库页刷新）

### 8.6 🔴 环境事故记录（开发期间，需用户排查）

外部进程**三轮批量删除** `lib/` 与 `assets/`（单轮最高 286 文件，含 NSFW onnx 模型、字体、
主题图），`.git` 始终完好、全部从 HEAD 恢复，无永久损失；未跟踪的 `assets/tools/bz.exe`、
`UnRAR.exe` 从 `build/flutter_assets/` 找回。伴随现象：`git rm` 两次 SIGTERM 留下 stale
`index.lock`；Edit 工具两次报成功但磁盘被回滚（改用 Python 原子写入完成）。
**建议排查删除源**：杀毒软件隔离区（onnx/exe 常被误报）、云同步盘、遗留进程。

---

## 9. v3.2 — Cinema UI 统一重构（2026-09-10 凌晨，commit `1440298`）

用户反馈：对接桌面功能后 UI 极度不统一、Cinema 主题学习不完整、整体偏丑。
按用户的逐项设计指导重构：

| 项 | 改动 |
|---|---|
| rail | 方形圆角纯图标按钮（56×56 / r16 / 无文字），「我的库」直接复用桌面同款 `library_icon_new.svg`（flutter_svg colorFilter 上色） |
| 主页 shelf | 卡片 168×224 → **196×276** 放大（对齐 gal-launcher 结构），**去卡片边框与容器顶边框**（选中态用樱粉辉光+上浮表达） |
| 详情 | 主页右下角【资料】→【详情】，行为从跳详情页改为**右侧滑出面板** |
| 详情面板 | 新增 `bpm_game_detail_panel.dart`：封面横幅（智能裁剪）+ 标题/副标题 + 开发商 + 状态/时长/最后游玩/安装日 + 收藏夹 + 标签 + 简介 + 启动按钮；数据与桌面库详情（GameDetailDialog）核心字段一致 |
| 右键菜单 | 新增 `bpm_context_menu.dart`：五项与桌面 `LibraryContextMenu` **结构一致**（详 情/启动管理/加入收藏夹/存档备份/删 除），Cinema 玻璃风格；我的库海报卡右键弹出（备份走桌面 `SaveBackupDialog`，收藏夹走 BPM 版管理弹窗）；长按动作表保留（触屏入口） |
| 导入窗口化 | 移除 stage 导入页（currentPage==2），点 rail「添加游戏」→ 模式选择窗 → `_BpmImportWindow` 对话框（Cinema 标题栏 + **桌面 JoinPage 直嵌**），尺寸自适应上限 1240×780 |
| 智能裁剪 | 新增 `bpm_smart_cover_image.dart`：64px 低清解码 → 梯度能量显著性 → cover 方向滑窗取最大（垂直方向 30% 上偏加权保人物头部/脸部）→ Alignment；backdrop 接入，**替换中心截取**；结果按路径缓存，异常回退居中 |

### 关键实现（勿回退）
- 面板由 shell 的 `AnimatedPositioned` 控制滑入滑出，`_lastPanelGame` 保证滑出动画期间仍渲染；ESC 优先收面板；切页自动收起。
- 详情页 `BigPictureDetail` 与智能导入一样已成孤儿（不再被 shell 引用），文件保留。
- BpmSmartAlignedImage 必须作为 `NsfwImage.file` 的 **child** 使用（NSFW 模糊链路在外层）。
- nav_bar 测试断言已改为 `bySemanticsLabel`（按钮无文字）；`bpm_interactive_wrapper_test` 补 `ThemeRegistry.registerBuiltinThemes()`（与 nav_bar 同根因的存量，净修复 5 个）。

### 验证
- analyze 全库 0 error / 0 warning
- test/big_picture：27 通过 / 5 失败（5 个全为 focus_glow_test 存量，基线口径内零新增）
- ⚠️ 未真机走查：rail 触控热区、shelf 放大后滚动、面板滑出动画、右键菜单定位、智能裁剪效果（不同封面比例）

## 9. v3.3 详情面板重构 — Mica 云母浮窗（commit `c450fbf`）

### 9.1 设计规范落地

| 规范项 | 实现 |
|---|---|
| 侧边浮窗 + Mica | 四周留边 16px + 圆角 20 + `BackdropFilter blur(28)` + 半透明深蓝面层 `#9C0E1420` + 顶部光泽渐变。真 Mica 需动 `windows/runner`（稳定区）故采用 Flutter 层模拟，与参考项目 SideSheet.css 的 `backdrop-filter: blur(28px) saturate(1.2)` 同构 |
| 顶部信息区 | 标题（得意黑 25）/ 会社（雾蓝次级）/ 标签云（chip，最多 12 个） |
| 游玩状态区 | 4 态分段选择器（未开始/进行中/已通关/已弃坑），写 `GameDataFormat.setPlayStatus` 与桌面同源；游玩历史倒序列表（最多展示 5 条 + 总数） |
| 统计区 | 总时长 hero（X 小时 Y 分钟）+ 2×2：启动次数 / 上次游玩 / 启动模式 / 安装日期 |
| 控制功能区 | 编辑（`BpmGameEditDialog`）/ 背景（`BpmBackdropTuner`）/ 目录（explorer）/ 删除（内联防误触 3s 武装 → MainContainer 确认框二次确认） |
| 启动控制组 | 主启动胶囊 + 「M」超分圆钮（`upscaling_mode: magpie`）+ 「Le」转区圆钮（`locale_mode: japanese`），写 game.json 与桌面同源 |
| 数据展示面板 | gal-launcher「更多信息」式折叠区（AnimatedCrossFade）：简介 + 截图缩略图横滑（NSFW image kind）+ 点击全屏 InteractiveViewer |

### 9.2 新增能力与文件

- `services/bpm_play_history.dart`：游玩历史服务（**桌面无此数据源，属新增能力**）。
  BPM 启动成功后 shell 埋点 append `metaDataDir/bpm_play_history.json`
  （`{started_at, mode}`，上限 200 条），历史列表/启动次数由它驱动；桌面启动暂不埋点。
- `widgets/bpm_game_edit_dialog.dart`：BPM 主题编辑窗口（封面替换 file_picker→复制→
  `cover_file`；标题走 `updateGameTitle` 迁移链路；标签/简介走 `updateGameJson`；
  截图增删走 `screenshots/` 子目录 + `screenshot_files` 字段）。
- `widgets/bpm_backdrop_tuner.dart`：背景图调整器（拖动定位 + 缩放滑条 + 实时预览；
  持久化 game.json `bpm_backdrop_x/y/zoom`，`BpmSmartAlignedImage.manualAlign`
  优先于自动显著性裁剪；「恢复自动」写 null 回退）。
- `big_picture_shell.dart`：浮窗化挂载、新回调接线、启动埋点、backdrop 手动对齐 + zoom。

### 9.3 验证与遗留

- analyze 全库 0 error/0 warning；test/big_picture 27 通过/5 失败（5 全 focus_glow 存量，零新增）。
- ⚠️ 未真机走查：Mica 透明度层次、浮窗在 1080p/2K 下的遮挡面积、拖动手感、
  编辑窗口封面替换后缓存刷新、NSFW 各模式下面板截图占位。
- P2：游玩历史仅记录 BPM 启动事件（无会话时长粒度，桌面亦无）；桌面启动如需同样
  历史可在桌面启动链路加同款埋点。

## 10. v3.4 详情面板手感与布局修复（2026-09-10 晚）

用户实测三项反馈：面板不点关闭按钮就常驻右侧、数据展示区没按"简介 L 型 +
截图滚页图右上角"的原设计走、统计区启动模式没适配超分+转区组合。

### 10.1 关闭机制 — 面板外点击屏障（`big_picture_shell.dart:344`）

- Stack 第三层（浮窗）之下新增 `Positioned.fill` + `GestureDetector(
  onTap: _dismissPanel, behavior: HitTestBehavior.translucent)`，
  **仅 `_panelGame != null` 时挂载**（滑出动画期间 `_lastPanelGame` 保持渲染但不拦截）。
- 语义对齐桌面 `GameDetailDialog` 的 `barrierDismissible: true`：手势竞技场中
  屏障先注册先胜出，**一次点击只关面板，不穿透触发下层卡片动作**
  （点另一个卡片需第二次点击，与桌面点遮罩关弹窗一致）。
- 关闭三路：×按钮 / ESC（`_onEscape`）/ 点面板外任意区域。
- ⚠️ 勿改为 barrier 之下再垫暗色蒙层——BPM 面板外区域保持 backdrop 可见是设计意图。

### 10.2 数据展示区 — 桌面同款 L 型布局（`bpm_game_detail_panel.dart`）

布局与桌面 `game_detail_dialog.dart:2385 _buildDescriptionAndScreenshots` 同构：

```
┌─────────────┬─────────────┐
│ 简介(标题)   │             │
│ 第一段文字   │  截图滚页图  │  ← 右上角, 5:5 分列, gap 12, 16:9
│ (竖排区)    │  (PageView)  │
├─────────────┴─────────────┤
│ 第二段文字 (L 底边, 全宽)    │
└───────────────────────────┘
```

- `_buildLShapeInfo()`：列宽 `(W-12)/2`，竖排区高 = 截图面板高(16:9+2 边框) −
  标题行 17 − 标题间距 6；`_splitDescriptionForLShape()` 桌面 TextPainter
  按行切分算法**逐行同款**（fitLines < 一行 → 全放底边；全放得下 → 无底边）。
- 退化分支与桌面一致：截图过矮（竖排区 <24px）→ 上下结构；简介空 → 截图占满整行；
  截图空 → 简介全文。
- `_BpmShotCarousel`（新增）：`PageView.builder` 滚页图 + 未到边界才显示的
  左右翻页圆钮 + 图上底部叠加指示点（不占布局高度）+ 单击进全屏。
  NSFW 铁律保持：`NsfwImage.file` + `contentKind: image` + child `Image.file`。
- `_BpmLightbox`（新增，替代单图 Dialog）：多图翻页（底部「下一张」+ 左右圆钮 +
  键盘 ←/→）+ ESC/双击/×关闭 + `ModalRoute.isCurrent` 守卫防重复 pop
  （对齐桌面 `_ScreenshotLightbox` 交互，BPM 深底视觉）。
- 需 `import 'package:flutter/services.dart'`（LogicalKeyboardKey）。

### 10.3 验证与遗留

- analyze 两文件 0 error（45 条全 prefer_const info 存量）；
  test/big_picture **27/5**（5 全 focus_glow 存量，零新增）；
  Release 全量编译通过（55.2s）。
- ⚠️ 运维教训：**test 与 release build 不可并行**——两个 flutter 进程同时重建
  `windows/flutter/ephemeral`，导致 `cpp_client_wrapper/*.cc` 丢失、构建报
  C1083；顺序执行即恢复。测试报 `Unable to connect to flutter_tester ... WebSocket`
  为代理劫持 localhost，内联 `NO_PROXY="localhost,127.0.0.1"` 即解（勿 env -u）。
- 📌 未真机走查：L 型竖排行数手感（440px 面板宽下约 3-4 行）、滚页图滑动与
  指示点、Lightbox 键盘焦点、点外部关闭与 shelf/hero 卡片交互的手感、
  启动模式四态在 M+Le 双开下的显示。

## 11. v3.5 — 独立头部栏 / 持久化 / 双主题 / 侧边栏重设计 / 布局与 BUG 修复（2026-09-10 夜）

commit `a353fe1`（稳定区 AppColors 作用域覆盖）+ `db12d02`（BPM v3.5 主体）。

用户需求 8 项，一次落地。下面按项记录，均附「为什么这么改」与「勿回退」要点。

### 11.1 移除系统顶部栏 → 自绘 `BpmTopBar`（需求①）

- 文件：`lib/big_picture/widgets/bpm_top_bar.dart`（新增）、
  `big_picture_shell.dart`（去掉 `CustomTitleBar` 包裹）。
- 结构：基本透明 + 自上而下极淡渐变，左侧 `Expanded` 空白区接
  `windowManager.startDragging()` 承担窗口拖拽；右侧依次
  **主题切换 / 在线状态 / 电量+时间 / 用户按钮**。
- 关闭与最小化**不再留在顶部**：并入侧栏底部按钮，点开是三选一对话框
  `bpm_exit_sheet.dart` —— 退出大屏模式 / 关闭软件 / 最小化。
  关闭软件复用 `CustomTitleBar.performCleanExit`，保证与桌面同一套清理逻辑。
- 电量：FFI `GetSystemPowerStatus`（kernel32），`lib/big_picture/services/bpm_system_status.dart`
  （新增）。**零新增依赖**——`ffi` 早已在 pubspec。20s tick，`start()/stop()` 由 shell 生命周期调用。

### 11.2 大屏模式持久化（需求②）

- `big_picture_manager.dart`：新增 `prefKey = 'bpm_mode_enabled'`；
  `enter()/exit()` 增加 `persist` 参数并写盘；新增 `restoreFromPrefs()`。
- `lib/main.dart`：`setPreventClose(true)` 之后调用
  `BpmThemeController.instance.load()` + `BigPictureManager.instance.restoreFromPrefs()`。
- 注意：`restoreFromPrefs()` 内部走 `enter(persist: false)`，避免启动时又写一遍。

### 11.3 双主题：Cinema 深 + 地海蔚蓝浅（需求③）

- `bpm_theme_controller.dart`（新增）：`BpmThemeMode{cinemaDark, oceanLight}`、
  `BpmPalette`（`dark` / `light` 两个 const 实例）、`BpmThemeController`（单例
  ChangeNotifier + SharedPreferences 键 `bpm_theme_mode`）。
- 🔴 **关键改造（勿回退）**：`big_picture_theme.dart` 的 `BpmColors` 从
  `static const Color` 全部改为 `static Color get` → 转发
  `BpmThemeController.instance.palette`。这样既有约 **300 处** `BpmColors.*`
  引用**一行不改**就跟随主题。
  - 副作用：所有 `const BoxDecoration(... color: BpmColors.x ...)` 必须去掉 `const`
    （5 处：shell / home / backdrop_tuner / detail_panel / edit_dialog）。
  - 收益：原 `focus_glow_test` 的 10 个存量失败**随之消除**（见 §11.9）。
- 浅色调色板：QQ 地海蔚蓝风格 —— 底 `#F1F8FF`、主文字 `#11395C`、
  强调蓝 `#2E9BE6`/`#1F87D6`、渐变 `#F8FCFF → #E6F2FE → #DCECFB` + 微光 `#4FC3F7`。
  深色保留 v3 原值，另加 `baseGradientColors` + `glowColor` 做「渐变发微光」。
- 切换入口：**仅 BPM 内部**（顶部栏主题按钮），不联动桌面主题（用户拍板）。

### 11.4 侧边栏重设计（需求④）

- `widgets/big_picture_nav_bar.dart` 整体重写：`BackdropFilter` blur 24 +
  `railGlass` 玻璃底 + 径向 `railGlow`；阴影为**中心向外渐隐**；
  按钮**无边框**（激活才填色 + 微光 + 左侧指示条）；logo 上移放大。
- 宽度 `railWidth` 88 → **104**，logo 34。

### 11.5 主页布局与底部栏（需求⑤）

- `pages/big_picture_home.dart`：卡片 `196×276 → 224×316`，货架区高
  `368 → 420`；右上角游戏统计**移入底部栏**为胶囊行（`_buildShelfStats`）；
  底部栏渐变首段**全透明**（`shelfScrim`），栏边界消失。
- 顶部各区偏移改用 `BpmColors.topBarHeight`（56）而不是原系统栏高度。

### 11.6 两个严重 BUG（需求⑥）

**a) 我的库右键菜单第二次弹不出**
- 根因：`big_picture_library_page.dart` 的 `_contextMenuEntry` 在菜单**自身关闭**
  时未置空；第二次右键对已 `remove()` 的 entry 再 `remove()` 抛异常，
  异常发生在 `show()` **之前** → 表现为「再也不弹」。
- 修复：`_dismissContextMenu` 先置空引用再 remove；新增 `onClosed` 回调
  （`bpm_context_menu.dart`），关闭后由页面侧 `_onContextMenuClosed` 清理。
- 🔴 模式价值：任何 `OverlayEntry` 自管生命周期的地方都必须「置空在先」。

**b) 主页货架选中态与实际不符**
- 根因三重叠加：① `autofocus: index == 0` 让首卡天生带焦；② `FocusGlow`
  焦点环取 `AppColors.selectedAccent`（**跟随桌面主题冷蓝**，与 BPM 暖色调打架）；
  ③ 选中时还有位移抬升动画，视觉焦点与逻辑选中错位。
- 修复：**焦点即选中**（`bpm_interactive_wrapper` 新增 `onFocusChange`，
  home 用它触发 `onSelected`）；焦点环改用 `BpmColors.selectedAccent`；
  去掉抬升动画，仅保留选中描边（cherryRose，宽 2 vs 未选中 1）。
- 附带：`focus_glow.dart` 新增 `showRing` / `ringWidth` 参数并移除
  `app_colors.dart` 依赖——**BPM 组件不再读桌面主题色**。

### 11.7 背景遮罩减重（需求⑦）

- `backdropScrimV`：`0x6B/0xDB` 级别整体下调为 `0x3D/0xA6`；
  `backdropScrimH` 同步下调。画面不再发灰，仍保证文字可读。
- `_buildBackdrop` 解码宽度按**物理分辨率** `clamp(1280, 4096)`，
  高分屏不再为 4K 原图付出解码与内存代价。

### 11.8 导入窗口适配 BPM 主题（需求⑧）

- 稳定区 `lib/theme/app_colors.dart` 增加**作用域覆盖层**：
  静态 `_overrideStack` + `pushOverride/popOverride`；所有 getter 改读 `_active`
  （栈顶优先）。**栈空时行为与改动前完全一致**，桌面模式零影响。
- `BpmPalette.toCTThemeData()` 把调色板映射为 `CTThemeData`；
  `big_picture_shell.dart` 新增 `_BpmAppColorsScope`（StatefulWidget），
  在 `initState` push、`dispose` pop，包住内嵌的 `JoinPage`。
- 这样 `lib/pages/join/**` 约 350 处 `AppColors.*` **一行不用改**，
  却能在 BPM 窗口内跟随 BPM 主题。
- 🔴 铁律：push/pop 必须成对，`popOverride` 用 `identical` 匹配 + 兜底
  `removeLast`。若将来新增第二个覆盖点，必须仍然成对。

### 11.9 验证

- `flutter analyze lib`：**0 error**（550 条均为存量 info/warning，基线约 565）。
- `flutter test`：**342 通过 / 0 失败**。基线原为 331/10，其中 10 个
  `focus_glow_test` 存量失败**随 BpmColors 收口一并消除**（不再依赖
  `ThemeRegistry` 注册），另新增 1 例。
- `flutter test test/big_picture`：**32/32 全通过**。

### 11.10 遗留（真机走查清单）

- 双主题配色观感（尤其浅色地海蔚蓝：对比度、backdrop 上文字可读性）。
- 顶部栏左侧空白区拖拽窗口是否顺滑、双击最大化是否仍可用。
- 侧栏毛玻璃与「中心向外渐隐阴影」的实际观感（blur 24 是否有性能压力）。
- 电量显示：插电 / 无电池台式机上的表现（`GetSystemPowerStatus` 的
  `BatteryFlag == 128` 表示无电池，需走"不显示电量"分支）。
- 退出三选一：关闭软件是否走全清理、最小化后托盘恢复是否正常。
- 底部栏统计胶囊在窄窗口下的换行/溢出。
- 导入窗口内 `JoinPage` 在浅色主题下是否有硬编码深色残留。

## 12. v3.6-re — 侧边栏重做：字形发光 + 轻量羽化玻璃 + 环境阴影团（2026-09-10 深夜）

> 背景：v3.6/v3.7 两轮侧边栏改造由 DS 模型会话完成，用户判定不符合 7 条要求，
> 已整体回滚到 v3.5 基线（commit `8c35301`）。本节是**重新实现**的记录
> （commit `2320705`），替代原 §12/§13 中关于侧边栏形态的描述。
> （v3.7 的启动恢复修复与侧边栏无关，已重新应用，见 commit `93a1309`。）

### 12.1 与被否决版本的关键差异

| 维度 | 被否决的 DS 版 | v3.6-re |
|---|---|---|
| 模糊强度 | 三段 σ5/10/18 | **两段 σ3.5/σ7**（段差小、无高频莫尔风险，原画更清晰） |
| 玻璃底色 | 深色 11% | **8%**，且水平渐变衰减到 0 |
| 选中辉光 | 透明圆形 BoxShadow 两档（中心叠加不透明度 ~64% → **实心蓝圆底块**，正是用户禁止的"背景块"） | **字形自身发光**：`Icon.shadows` / SVG 底层同色模糊双层叠加，光晕跟随字形，零底块 |
| 阴影浓度 | 中段 ~30% / 底部 ~45%（偏重发闷） | 中段 **~13%** / 底部 **~32%**（轻量悬浮） |
| 逐像素跳变 | 平板背景实测 +19~+20 | **+6**（8-bit 量化级别，无硬边） |

### 12.2 实现要点（勿回退）

- **两层羽化玻璃**（`_buildFeatheredGlass`）：本体 0..railWidth σ7 + 外扩段
  +32px σ3.5。底色是**渐变**（左实→右 0，`withAlpha` 相乘缩放，勿用
  `withOpacity` —— 它是替换不是相乘）。
- **环境阴影团** `_RailAmbientPainter`（画在玻璃**之上**，盖羽化带台阶 +
  造体积感）：8 组径向渐变（主体椭圆/上下柔化/底部半凸圆×2/底部左外扩/
  舞台侧扩散/顶部收口），4 段 stops 非线性衰减。`railShadowSpreadRight=200`
  保证所有渐变（最大半径 1.8×railWidth）在画布右缘前归零。
- **无底板图标**：`FocusGlow.idleShadow` 必须传 `false`（该组件非焦点态
  常驻 `0x33000000/blur 8` 矩形投影，会在每按钮后留 68px 等宽暗块）；
  去激活填充方块/指示条/右边框。
- **选中辉光**：`Icon(shadows: [0.50/10, 0.22/26])`；SVG 无 shadows，
  用 `ImageFiltered(blur 5)` 同色底层 + 清晰顶层叠放。颜色 =
  `BpmColors.navGlowBlue`（深色 `0xFF6FB4F0` / 浅色 `0xFF2E9BE6`）。
- **Stack 必须 `clipBehavior: Clip.none`**：阴影画布与玻璃外扩段溢出
  railWidth 绘制；内容列必须包 `Positioned.fill`（非定位子节点收缩到
  内容宽度 → 整列贴左）。
- **令牌**：`railGlow` 更名 `railShadow`；新增 `navGlowBlue`；
  `railShadowSpreadRight/Top`、`railFeatherExtents/Sigmas`；`topBarHeight` 64。
  ⚠️ `toCTThemeData()` 映射表的 `navActiveBg` 用 `identical(this, dark)`
  取显式旧值 —— 导入窗口 JoinPage 的激活底色不跟随侧栏轻量化。

### 12.3 顶栏（需求 6/7）

底部 1px 分隔线删除；height 56→64；主题按钮 36→44（图标 21）、
用户按钮 36→44（头像 37）、在线点 10 / 文案 14、电量图标 23 / 15、
时间 23、间距 38 / 右距 26。

### 12.4 验证

- golden 三场景（平板/深色伪原画/浅色伪原画）目检 + PIL 逐像素扫描：
  全图最大跳变 +6、羽化带专项 +6、剖面单调平滑；选中图标为纯字形蓝光。
  临时测试与 goldens 已删除。
- `analyze lib` 0 error（550 条存量与基线一致）；全量 test **342/0**
  （watch_folder 单跑失败为 Temp 残留锁，清理后 23/23）；Release 70.0s。
- ⚠️ 未真机走查：深/浅主题下阴影与辉光浓度、底部半凸圆在 1080p/4K 的
  比例、σ7 毛玻璃在真实封面墙上的观感。

---

## 13. 全屏启动修复 v2 — FFI 物理铺屏（2026-09-10 深夜后）

### 13.1 问题
用户真机反馈：BPM 进入/恢复时窗口卡在桌面左上角（高 DPI 屏上占约 2/3），非全屏。

### 13.2 根因链（插件源码实证）
1. `main.dart:452` `setAsFrameless()`（4K 白边修复）→ 插件 native
   `SetFullScreen(true)` 在 `is_frameless_` 时只发 `SC_MAXIMIZE`、跳过铺屏
   分支（window_manager.cpp:592-607 `if (!is_frameless_)`）。
2. 旧补刀（`93a1309`）用 `PlatformDispatcher.displays.first.size`（逻辑像素）
   传 `windowManager.setBounds` —— 但插件 native SetBounds 会把 Dart 值
   **乘以 `window.devicePixelRatio`**（window_manager.dart:374
   getDevicePixelRatio → window_manager.cpp:742-747）再 SetWindowPos。
3. 启动恢复场景 `implicitView.devicePixelRatio` 不可靠（可能读到 1.0），
   `displays` API 在 Windows 的上报语义也存疑 —— 逻辑值 ×1.0 按物理落地，
   4K/150% 屏上窗口 = 约 2/3 屏大 @ (0,0) = 左上角小窗。

### 13.3 修复（`lib/big_picture/big_picture_manager.dart` 唯一改动）
补刀改为 `_fillWindowMonitor()`：FFI（user32）四步，与插件原生铺屏分支
（window_manager.cpp:599-607）完全同源：
1. `FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW")` 取主窗口 hwnd（runner 类名
   全进程唯一，win32_window.cpp:43）；
2. `MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)`；
3. `GetMonitorInfoW` → `rcMonitor`（**物理像素**）；
4. `SetWindowPos(hwnd, HWND_TOP, rcMonitor, SWP_NOOWNERZORDER | SWP_FRAMECHANGED)`。
零 DPR 换算；非 Windows / 任一环节失败 → 返回 false，退化为最大化状态（不抛出）。
退出路径不动（插件 `SetFullScreen(false)` 的恢复分支自身完好：Restore() +
SetWindowLongPtr + g_frame_before_fullscreen）。

### 13.4 验证与遗留
- analyze 改动文件 0 issue；全量 test 342/0；Release 构建通过。
- ⚠️ 待真机验证：BPM 手动进入、保持大屏重进两条路径是否直接全屏无小窗；
  多显示器 / 副屏启动场景未覆盖（MonitorFromWindow(NEAREST) 理论上已覆盖
  窗口所在屏）。
- 🔴 勿回退成 displays/setBounds 方案（理由见 §13.2）。

## 14. v3.8 — 浅色主题重调 / 全局按钮加大 / 手柄适配（2026-09-11，commit `80206f9` + `5ef247b`）

### 14.1 视觉层（`80206f9`，7 文件）
**浅色「刺眼不融合」根因**：
- `bpm_theme_controller.dart` light palette：glowColor 0x4D4FC3F7（30% 亮青蓝）
  / backdropScrimV 底部 0x99（60% 白）/ H 左 0x99 / micaSheen 0x66 —— 全部
  超过深色侧对应值，背景原画被白化；
- `big_picture_home.dart` 五处文字阴影硬编码深色（0xE0111620/0x38E89AA8），
  palette 的 heroTextShadow/Glow/subTextShadow 令牌定义了但**零使用** ——
  浅色下白字拖黑影。

**修复**：glowColor→0x2E5FA8D6、scrimV 底→0x6B、scrimH 左→0x61、
micaSheen→0x3D、navGlowBlue→0xFF5AA7E6；主页阴影接令牌（深色值不变 =
零视觉变化）；焦点环辉光浅色 45%→28%/blur 16；主题按钮浅色态地海蓝渐变底。

**尺寸（触屏/手柄可点性）**：railWidth 128 / railItemSize 72 / railIconSize 34
/ railItemSpacing 22 / railLogoSize 38 / detailPanelWidth 520 /
heroButtonHeight 76（字号 24）/ 详情钮 58 / 库页操作区 56 / chips 44。
🔴 railWidth 加大后 `_RailAmbientPainter` 底部主 blob（1.8×rw）右缘超出
画布 → railShadowSpreadRight 必须 200→240，否则切硬边。

**侧栏四按钮统一**：`_RailGlyphButton`（StatefulWidget）三层字形辉光
（6/16/34px，0.62/0.34/0.15 非线性）+ AnimatedScale 1.12；hover/焦点预览
同款 0.38 系数 —— 添加/退出按钮此前零 hover 反馈是「不统一」根因；
辉光颜色跟随字形自身色（导航=navGlowBlue、添加=rose、退出=mistBlue），
浅色整体再乘 0.75。

### 14.2 手柄适配（`5ef247b`，新增 service + 测试）
**架构**：`services/bpm_gamepad_service.dart` 只做 XInput→语义事件；
`big_picture_shell.dart` 实现语义层；组件层提供焦点结构。零新增依赖
（dart:ffi 直调 xinput1_4.dll→xinput9_1_0.dll，calloc 来自 package:ffi）。

**输入映射**：
| 输入 | 语义 |
|---|---|
| A | 面板开→焦点锁进面板启动按钮；库页焦点在操作区→锁定操作区；其他→激活控件 |
| B | 锁定态→退回浏览态并回锚点；面板开→关面板；其余忽略（不误退 BPM） |
| LB/RB | 页面切换（主页⇄库），面板开先收 |
| 十字键/左摇杆 | 焦点移动：**锁定态区内隔离**（findFirstFocusInDirection，边缘停）；浏览态区内优先、找不到才跨区 |
| 右摇杆 | 滚动轴流：面板开滚面板（scrollController），否则滚焦点所在 Scrollable |

**轮询细节**：16ms 间隔；圆形死区（左 7849/右 8689）取主轴防斜推连发；
方向重复 initial 380ms / repeat 130ms；每 tick 最多 fire 一个方向；
断连 4 帧休眠、重连首帧只建基线；packet 不变只跳过按钮 edge（重复节奏
仍推进）。后端抽象 `BpmGamepadBackend` 可注入，11 个状态机单测。

**焦点结构**：库页上方操作区（toolZoneKey）/海报墙各成 FocusTraversalGroup；
海报墙首卡 autofocus（AnimatedSwitcher 重建页面时重放=「进库页默认落
海报墙」）+ wallAnchorFocusNode（B 退回锚点）；面板整体一组 +
primaryFocusNode（footer 启动按钮 = 内容操作入口）+ scrollController。
B 键关面板恢复 `_zoneAnchor`（锁定前焦点）。

### 14.3 验证与遗留
- analyze 0 新增 error；全量 test 353/0（342 基线 + 11 手柄；watch_folder
  1 例为 Temp 残留，清理后 23/23）；Release 构建通过。
- ⚠️ 待真机：XInput 手柄实测（A/B/LB/RB/摇杆节奏/断连恢复）；浅色观感、
  侧栏/阴影浓度、半凸圆比例待用户回归。
- 🔴 手柄方向锁定态不许回退成跨区派发（会破坏「操作区与其他主要区操作的
  隔离」需求）。

### 14.4 v3.9 — 手柄全链路适配修复（2026-09-19）

**根因（真机证据）**：`xinput1_4.dll` 已被 `chrono_tide.exe` 加载 → 服务确实启动；
DInput 探针枚举到的唯一手柄是 `Xbox 360 for Windows Controller`（与 XInput 槽0
同一台）；用户现象为「**部分按键有反应**」→ 根因＝**映射层覆盖不全**，不是输入源
缺失。（旧版本自述「手柄真机未实测」，属写完未跑通。）

**修复前缺陷**：① XInput 只读槽位 0；② 仅 XInput，DInput 手柄完全不可见；
③ `onConnectionChanged` 未注入、连接状态无 UI 消费；④ X/Y/Start/Back/LT/RT
六键零消费；⑤ 右摇杆滚动轴向错配（dy 被喂给最近的横向 shelf）。

**输入映射（v3.9 完整表，括号内为 PS / Switch 对应键）**：

| 输入 | 语义 |
|---|---|
| A (×/B) | 面板开→焦点锁进面板启动按钮；库页焦点在操作区→锁定操作区；其他→激活控件 |
| B (○/A) | 锁定态→退回浏览态并回锚点；面板开→关面板；其余忽略（不误退 BPM） |
| **X (□/Y)** | **当前项动作菜单（等价卡片长按/右键）** |
| **Y (△/X)** | **切换当前项标记/收藏** |
| **Start (Options/+)** | **BPM 系统菜单（退出大屏/关闭软件/最小化）** |
| **Back (Create/−)** | **视图切换（主页 ⇄ 我的库）** |
| LB/RB | 页面切换（主页⇄库），面板开先收 |
| **LT/RT (L2/R2)** | **快速翻屏（面板内容或焦点所在滚动视图翻一屏，留 10% 重叠）** |
| 十字键/左摇杆 | 焦点移动：**锁定态区内隔离**（边缘停）；浏览态区内优先、找不到才跨区 |
| 右摇杆 | 滚动轴流：面板开滚面板；否则按**主轴方向**滚**轴向匹配**的 Scrollable |

**X/Y 的作用对象**＝「焦点即作用对象」：详情面板 > 当前页焦点游戏
（主页用舞台焦点 `_stageGame`；库页由 `_PosterCard.onFocusChange` 上报
`onGameFocused`）。手柄没有鼠标指针，缺此锚点就会表现为「按了没反应」。

**多后端仲裁**：`BpmGamepadService` 按序尝试后端列表，取首个返回帧者为活跃后端。
后端须暴露 `sourceKey`（当前数据源标识）—— XInput 换槽 / DInput 换设备时变化，
服务据此**重建基线**；否则新设备的 packet 序列会被拿去和旧设备比较，接入瞬间
会乱触发按钮边缘。

**XInput 多槽位（`selectSlot` 纯函数）**：粘住槽有实际输入 → 用它；粘住槽空闲 →
扫描其它槽，谁有输入谁生效；全无输入 → 回落「已连接但空闲」的槽（否则"手柄连着
但没按键"会被判成未连接）。这样既不会被"占位却不报按键"的虚拟设备永久挡住，
也不至于因多手柄抢焦而乱跳。

**DirectInput 后端三个实测坑**（`services/bpm_dinput_backend.dart`）：
1. `dinput8.dll` **不导出** `c_dfDIJoystick2`（GetProcAddress 实测 null）→
   自建 DIDATAFORMAT：6 轴 + 1 POV + 16 按钮，状态结构 44B，偏移严格对应；
2. `GetModuleHandleW` / `GetDesktopWindow` 返回值**必须按指针宽度声明**
   （`ffi.IntPtr`），否则 64 位句柄被截断 → `DirectInput8Create` 返回
   `E_INVALIDARG`(0x80070057)；
3. `Pointer<NativeFunction<T>>` 在 Dart 侧**不能直接调用**，调用点必须
   `.asFunction<DartFn>()`；而 `asFunction` 的类型参数要求编译期常量，
   因此不能把它收进泛型 helper（否则报 `non_constant_type_argument`）。
   另：DirectInput 无 packet 概念，后端合成 packet（状态变化才自增）。

**滚动轴修复**：`_scrollPositionInAxis` 从焦点 context 逐级上溯，用 `identical`
跳过重复命中，返回**轴向匹配**的 `ScrollPosition`。原实现只取"最近的 Scrollable"，
而主页 shelf 是横向的 —— 于是右摇杆上下推会把 shelf 左右拽、水平推被整段丢弃。

### 真机走查清单（§14.4 遗留，必须逐项确认）
1. A/B/X/Y/Start/Back 六键各自语义；
2. LB/RB 切页、LT/RT 翻屏；
3. **右摇杆**：横推滚主页 shelf、竖推滚库页海报墙（原实现此处是错的）；
4. 手柄拔插 → 是否出现「手柄已连接 / 已断开」提示；无手柄时按动手柄无反应的
   原因是否可从日志（`[BPM][Gamepad]` 前缀）判断；
5. ⚠️ 如能拿到 **PS4/PS5 或 Switch Pro 直连**，重点验按钮序号 ——
   DirectInput 不做跨厂商标准化，错位时在 `_buttonLayouts` 按产品名登记。

**关键约束（勿回退）**：
- 🔴 方向锁定态不许回退成跨区派发；
- 🔴 `selectSlot` 的「空闲回落」语义：全无输入时要回落到已连接槽的空闲帧；
- 🔴 DInput 的 Win32 句柄必须按 `ffi.IntPtr` 声明；`asFunction` 不可泛型化。

### v3.8.1 桌面⇄BPM 切换动画（71fa7fb，main_container.dart:811）

> ⚠️ **已于 2026-10-03 整体替换** —— 该 420ms 对称 fade+scale 方案被判定为
> 「生硬、不连贯」（全屏切换先于切壳下发 + 两棵全屏树同时逐帧重绘）。
> 现行方案见 [`bpm_mode_transition.md`](./bpm_mode_transition.md)（幕布两段式）。
> 以下为历史记录，勿据此改代码。

- 「镜头推近」：AnimatedSwitcher 420ms，入场壳 1.05→1.0 缩放回落 + 淡入
  （easeOutCubic 落座感），出场壳共享同一 tween 反向播放 = 1.0→1.05 微放大
  + 淡出（被推过的透视感），双向对称。
- 🔴 出场曲线保持 easeInCubic：CurvedAnimation 的 reverseCurve 按反向进度
  套曲线，easeIn 读作"先快让位、尾段轻收"；换 easeOut 会恋战到最后一刻
  突然消失。勿"顺手改对称"。
- 桌面侧无保活依赖（fade 完即销毁重建），动画不引入状态丢失回归。

---

## 15. v3.10 — BPM 分层板块焦点系统（2026-09-20）

### 15.1 用户规范（原文摘要）

一级 3 个板块（左侧导航栏 / 顶部状态栏 / 中间主内容区）+ 页面二级板块
（主页：搜索栏 / 操作按钮 / 卡片列表；库页：顶部筛选操作 / 卡片列表）；
两模式（板块选择 = 高亮整块 / 组件操作 = 高亮单组件）；A 进入板块或点击组件、
B 层级回退；方向键在**层级内**切换且**边界停**；卡片列表顶/底不跳别的板块，
须先 B 退出；**保留原有鼠标操作，手柄交互独立实现，用状态机管理焦点层级**。

### 15.2 三层架构（状态机与焦点树解耦）

| 层 | 文件 | 职责 |
|---|---|---|
| 状态机 | `lib/big_picture/focus/bpm_zone_focus_controller.dart`（**新增**） | 三级转移纯逻辑（可脱离 widget 单测）+ `BpmZoneFocusScope`（`InheritedNotifier`） |
| 语义层 | `lib/big_picture/big_picture_shell.dart` | 把转移结果落到 `FocusNode`；用焦点组 key 把 `primaryFocus` 反查回板块 |
| 视觉层 | `lib/big_picture/widgets/bpm_focus_zone.dart`（**新增**） | 板块高亮容器 |

状态 = `(level, mode, zone)`：
`BpmFocusLevel{global, page}` · `BpmFocusMode{zone, component}` ·
`BpmZoneId{rail, topBar, stage, homeSearch, homeActions, homeShelf, libraryTools, libraryWall, panel}`

**一级方向键 = 空间邻接表**：`rail{↑topBar, →stage}` / `topBar{↓stage, ←rail}` /
`stage{↑topBar, ←rail}`；无邻接 → 停（不跨级）。
**二级方向键**：↑/↓ 在页内板块间切换，首/尾停；←/→ 无操作。

**转移**：A（板块模式）→ 一级 rail/topBar 进组件模式、`stage` **下钻**到二级板块层
（仍板块模式、不动焦点）、二级板块进组件模式；B（组件模式）→ 板块模式，
（二级板块模式）→ 一级板块模式 + 高亮回 rail，（一级板块模式）→ **不消费**
（保持「B 不误退大屏」）。`landOnCardList(page)` = 进入页面后的落点（卡片列表 + 组件模式）。

### 15.3 视觉区分（规范第 6 条）

- **板块模式**：`BpmFocusZone` 樱粉 `cherryRose` 2px 圆角边框 + 外辉光 + 5% 底色，
  **包住整个板块容器**；
- **组件模式**：`FocusGlow` 雾蓝 `selectedAccent` 焦点环 + `focusScale` 放大，只包单个控件；
- 高亮层用 `Positioned` **负偏移**外扩（`Padding` 不允许负值），因此
  **不参与布局、不拦截命中测试**（`IgnorePointer`）；外层 `Stack` 必须
  `clipBehavior: Clip.none`，否则外扩部分被削掉。

### 15.4 🔴 手柄 / 鼠标·键盘的边界（本设计最关键的一条）

**板块模式只在手柄侧生效**：手柄在板块模式下**刻意不动 Flutter 焦点**。由此得到：

1. 状态机收到的任何焦点变化，必来自鼠标 / 键盘 / 程序化 `requestFocus` →
   shell 的 `_onPrimaryFocusChanged` 可安全据此把状态切回组件模式（焦点环恢复）；
2. **「保留原有鼠标操作」成为机械保证**（鼠标动作路径一行未改），而不是口头约定；
3. 右摇杆 / LT·RT 在板块模式下改用**当前高亮板块的入口节点**找 Scrollable
   （`_gamepadScrollContext`）—— 仍按 `primaryFocus` 找会滚到上一个板块去。

🔴 **启动期闸门 `_userInputSeen`**：首页 shelf 首卡有 `autofocus`，首帧即请求焦点。
若不加闸门，`_onPrimaryFocusChanged` 会把状态直接切成组件模式，启动落点就不再是
「左侧导航栏板块模式」（违反规范第 1 条）。只有 pointer down / `HardwareKeyboard`
任一键才置位该闸门 —— 手柄不经这两条通道，故不会自我打断。

### 15.5 关键实现（🔴 勿回退）

- 🔴 `_zoneOf(node)` 必须 `visitAncestorElements` **由近及远**取首个命中：一级 `stage`
  的焦点组包住整页、页面二级板块的焦点组嵌在其中，**内层优先**才能把「焦点在 shelf
  卡上」判成 `homeShelf` 而非 `stage`。
- 🔴 `BpmZoneFocusScope.maybeZoneMode` 返回 **null**（非 BPM 子树）时，
  `FocusGlow` / `BpmInteractiveWrapper` 必须与改动前**逐位一致** —— 这是既有组件测试
  与桌面模式零回归的保证。
- 🔴 组件模式方向键**不再** fallback 跨板块（v3.9 的「浏览态找不到就跨区」已删除）：
  规范第 4 条要求换板块必须先 B。
- 🔴 落点优先「上次落点」再入口节点（`focusTargetOf`）；`rememberFocus` 在板块模式下
  **拒写**，否则切板块瞬间会把旧板块焦点写成新板块落点。
- 面板 `BpmZoneId.panel` 不进任何层级：`openPanel` 快照 `(level, zone)`、
  `closePanel` 恢复；面板打开期间 `back()` 不消费（交 shell 关面板）；
  面板内部方向隔离仍由 `bpm_game_detail_panel.dart` 自带的 `FocusTraversalGroup` 保证
  —— **该文件本次零改动**。

### 15.6 验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib/big_picture` | ✅ **0 error**（16 条 info/warning；其中 `big_picture_shell.dart:29 unused_import` 经核对为 HEAD 存量，非本次引入，按最小变更未动） |
| `flutter test test/big_picture` | ✅ **60 → 108 全通过**（新增 48 例：状态机 41 + 板块高亮 7） |
| 全量 `flutter test` | ✅ **720 → 767 全通过，零失败** |
| 真机走查 | ⚠️ **未做**（见 §15.7） |

### 15.7 ⚠️ 真机走查清单（必须逐项确认）

1. **启动默认落点**＝左侧导航栏板块模式（板块高亮可见、组件无焦点环）；
2. **rail**：A 进入 → ↑↓ 选项 → A 进页面 → **自动落卡片列表组件模式**（规范第 2 条）；
3. 一级方向键三块互达；`rail↓` / `stage↓` / `topBar→` 无反应（边界停）；
4. 主页二级：↑↓ 在 搜索栏 / 操作按钮 / 卡片列表 间切换，首尾停；
5. 卡片列表组件模式：顶/底边缘停，**不跳别的板块**，须先 B 退出（规范第 4 条）；
6. **B 三级回退**：组件 → 二级板块 → 一级板块；一级再按 B 无反应（不误退大屏）；
7. 鼠标 / 键盘任意操作后板块高亮消失、组件焦点环恢复；
8. 浅色（地海蔚蓝）主题下樱粉板块框的对比度与观感；
9. 详情面板：打开期间 A 先落面板启动钮、方向键面板内隔离、B 关面板后回到原层级；
10. 右摇杆：板块模式下滚**当前高亮板块**（横推滚主页 shelf / 竖推滚库页海报墙）；
11. ⚠️ **盖世小鸡拉伸手柄**若工作在 DInput 模式，按钮序号可能错位（DirectInput 不做
    跨厂商标准化）→ 在 `bpm_dinput_backend.dart` 的 `_buttonLayouts` 按产品名登记，
    **映射主干不必改**。

---

## 16. v3.10.1 — 真机手柄 BUG 全面修复 + 覆盖度补齐（2026-09-20）

用户真机反馈（v3.10 提交 `c5a8cdb` 之后）：**侧边栏选不中「我的库」、主页卡片列表
左右键换不了游戏、按 X 或 Y 会卡死**，且手柄覆盖度远低于鼠标。

### 16.1 根因（Flutter 3.24.3 源码 + 探针实测，非猜测）

**① 用错了方向遍历 API。** `FocusTraversalPolicy` 有两个方向入口：

| API | 行为（源码实测） |
|---|---|
| `inDirection(node, dir)` | 框架方向键用的**正确**实现：在 `node.nearestScope.traversalDescendants` 内按几何筛选，候选为空 → 返回 false（＝**边缘停**）；优先留在同一 Scrollable 内；落焦经 `requestFocusCallback`，**自带 `Scrollable.ensureVisible`** |
| `findFirstFocusInDirection(node, dir)` | **完全不做方向过滤**（`focus_traversal.dart:707-733`）：把整个 scope 的可聚焦节点按前缘排序后 `return sorted.firstOrNull` |

探针实测（3 个不同位置节点）：从左侧节点按 `down` → **屏幕最上方**那个节点；
按 `right` → **最左边**那个节点（＝它自己）；按 `up` → **屏幕最下方**那个。
v3.8–v3.10 一直用的是后者 → 真机上「↓ 从主页导航项」跳到顶部栏
（**永远选不中「我的库」**）、「←/→ 在海报墙」跳到侧栏（**永远换不了游戏**）。

**② 同一个 FocusNode 被挂到两个 widget 上。** v3.10 让 shell 持有一个
`_railEntryNode` 并挂到「当前页对应的那一项」；但 `BpmInteractiveWrapper._focusNode`
是 `late final`（只在 `initState` 赋值）→ 切页后**旧项不会释放该节点**，同一个
FocusNode 同时挂在新旧两个 `Focus` 上 → 焦点树被污染（`_zoneOf` 反查到错误板块、
`requestFocus` 目标错乱），并被 X/Y 触发的重建放大成「卡死」。

**③ Y 键标记被切换两次。** shell 先自己调 `LocalGameRegistry.toggleMark`，又调
`widget.onToggleMark`（MainContainer 内部同样调 `toggleMark`）→ 互相抵消，
真机表现为「Y 按了没反应，只闪一下」。

**④ 模态打开时手柄仍作用于背后页面。** 动作表打开时按 X 会**再叠一层动作表**、
LB/RB 会在背后偷偷切页、A 会激活模态背后的卡片。

### 16.2 修法

1. **每个板块一个 `FocusScope`**（新增 `widgets/bpm_focus_domain.dart` 的
   `BpmFocusDomain`）。`inDirection` 只认 `nearestScope` → 域内候选恰好＝本板块组件，
   于是「板块内移动 / 边缘停 / 不跨板块」由**框架语义**直接保证，不再自己拼判断。
2. 组件模式方向键**改走 `inDirection`**。
3. **删掉全部入口 FocusNode / 焦点组 GlobalKey 插桩**（根因②的载体）：进入板块的
   落点由 `policy.findFirstFocus(scope)` 现算 —— 优先域内 `focusedChild`（框架维护＝
   **天然的位置记忆**），否则域内第一个可聚焦组件；落焦走
   `policy.requestFocusCallback`，一并解决「焦点移到视口外不滚动」。
   各板块的 `FocusScopeNode` 由 `BpmFocusDomain` 自持并注册进控制器，
   `zoneOfScope(nearestScope)` 反查归属（不再遍历 element 树）。
   ⚠️ `unregisterDomain` 必须比对 scope 身份 —— 切页时 `AnimatedSwitcher` 过渡期内
   新旧页共存，按 zone 直接删会把新页刚登记的域误删。
4. **模态门控**：`_modalOpen`（`ModalRoute.isCurrent == false`）时 X/Y/LB/RB/Start
   一律忽略、B 关模态、A 与方向键**只作用于模态**（模态无人持焦时先补焦到第一个
   可聚焦控件）→ 动作表 / 确认框 / 导入窗口 / 用户面板**全部可手柄操作**。
5. **Y 键只切换一次**（统一交给宿主回调，无回调才自己兜底）。
6. **X 动作菜单与桌面右键菜单对齐**：补 详情 / 加入收藏夹 / 存档备份
   （原 4 项 → **7 项**）；收藏夹弹窗抽成 `BpmCollectionPicker` 供库页与动作菜单共用；
   条目变多后整表可滚（`maxHeight: 82%` 屏高）。

### 16.3 验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib` | ✅ **0 error**（550 条存量 info/warning 不变） |
| `flutter test test/big_picture` | ✅ **108 → 125 全通过** |
| 新增回归测试 | `test/big_picture/focus/bpm_direction_navigation_test.dart`（**17 例**）—— 4 个板块 + 2×2 网格复刻真机布局，逐条锁死「侧栏 ↓ 必须进到第 2 项」「海报墙 → 必须换卡、行尾停」「↓ 不跨板块」等。**这些用例在旧实现下必然失败**（探针已实测旧 API 的返回值） |
| 全量 `flutter test` | ✅ **768 → 785 全通过，零失败** |

### 16.4 ⚠️ 仍未覆盖（诚实标注）

- **文字输入**：搜索框 / 重命名收藏夹 / 游戏编辑弹窗的文本字段无法用手柄输入
  （需软键盘；本项目 Windows 桌面优先）。
- **拖拽排序**：库页管理模式的拖拽、收藏夹内排序，手柄无对应手势。
- **NSFW 揭示手势**（长按查看被模糊的图）无手柄映射。

### 16.5 真机走查清单（v3.10.1）

1. **侧边栏**：A 进 rail → ↓ 到「我的库」→ A 进库页并自动落海报墙（规范第 2 条）；
2. **主页卡片列表**：A 两次进入 shelf 组件模式 → ←/→ 换游戏、舞台背景跟随、
   卡片自动滚动到可见；
3. **库页海报墙**：↑↓←→ 在网格内移动，行尾 / 末行停住，**不跳侧栏 / 顶部筛选区**；
4. **X**：动作表 7 项齐全；打开后方向键切换条目、A 激活、**B 关闭**；
   再按 X **不再叠加**弹窗；
5. **Y**：标记真的切换（星标出现 / 消失），不再只是闪一下；
6. **LB/RB**：切页并落新页卡片列表；**模态打开时不响应**；
7. **B 三级回退**：组件 → 二级板块 → 一级板块；一级再按不误退大屏；
8. **模态全覆盖**：退出三选一 / 导入模式选择 / 导入窗口（JoinPage）/ 删除确认 /
   管理收藏夹 / 用户面板 —— 打开后方向键能移动、A 能激活、B 能关闭；
9. **右摇杆**：板块模式下滚**当前高亮板块**；LT/RT 翻屏；
10. 浅色（地海蔚蓝）主题下板块高亮与组件焦点环的观感；
11. ⚠️ **盖世小鸡**若工作在 DInput 模式，按钮序号可能错位
    （在 `bpm_dinput_backend.dart` 的 `_buttonLayouts` 按产品名登记）。

---

## 17. v3.10.2 — 摇杆轴向 / 主页板块缺焦点域 / 双击 A 启动 / X 卡死（2026-09-20）

用户真机反馈（v3.10.1 提交 `c8bc2dc` 之后）：**① 摇杆上下反向**（向上拉杆界面却向下）；
**② 主页仍无法用手柄操作**（左右翻不了游戏列表、不能直接在列表里启动）；
**③ X 键仍会卡死**，且启动方式要求改成「**双击 A 启动**」而不是 X。

### 17.1 根因

**① 左摇杆竖直轴极性写反 —— 同一文件里两套相反约定（P0）**

`bpm_gamepad_service.dart` 的 `_thumbDirections()` 原为
`yield ly < 0 ? TraversalDirection.up : TraversalDirection.down;`，而 XInput 规范里
`sThumbLY` 的**正值＝上**。铁证是同文件 `_handleRightStickScroll()`：那里的注释与代码
都是「摇杆上推 `ry > 0`」，`dy = -ny * …` —— 同一个 `GamepadFrame` 里两个摇杆用了
**互相矛盾**的轴向约定，左摇杆那一路就是反的。

反向的成因可复现推演：用户看到「上推→界面下走」，说明其活跃后端上报的是
**上＝正**（若上报经典的「上＝负」，旧代码恰好是对的、也就不会有这条反馈）。
因此正解是把**服务层统一到「正＝上/右」**，两个后端都不做额外翻转
（`GamepadFrame` 的字段语义即 XInput 规范）。

**② 主页「游戏卡片列表」板块漏装焦点域（P0，装配漏项）**

v3.10.1 给每个二级板块都加了 `BpmFocusDomain`（独立 `FocusScopeNode`），
但 `big_picture_home.dart` 的第三个板块**只包了 `BpmFocusZone`（视觉高亮），
漏了 `BpmFocusDomain`**（库页两个板块是齐的）。双重后果：
1. `inDirection` 只认 `currentNode.nearestScope` → 卡片的最近 scope 变成整个 stage，
   候选集合 = 搜索框 + chips + 操作按钮 + 所有卡片 → 「左右键在列表里乱走」；
2. `BpmZoneFocusController.entryFocusOf(homeShelf)` 恒为 null →
   `focusEntryOf` 恒 false → **A 键连板块都进不去** → 「主页无法用手柄操作」。

**③ X 卡死：`ModalRoute.isCurrent` 存在 250ms 门控空窗（P1）**

`_modalOpen` 用 `ModalRoute.isCurrent == false` 判断模态，但
**`Navigator.pop` 会立刻把路由移出 history**（`isCurrent` 马上回到 true），而
`showGeneralDialog` 的反向过渡还要跑 **250ms**，弹窗 widget 这段时间仍在树上。
于是「连按 X」会在这 250ms 内**在正在关闭的弹窗上再叠一层**，快速连按叠出多层
全屏动作表（每层含全屏遮罩 + 可滚动列表）→ 真机表现为卡死。

同时发现：**关闭态的详情面板仍可聚焦** —— 面板关闭只是 `right` 变成负值滑出屏幕，
widget 一直在树上且装了 `BpmFocusDomain`，方向键能把焦点移进看不见的面板，
再按 A 就激活了不可见控件（启动 / 删除），这是「按键作用在莫名其妙的地方」的来源。

**④ X 曾被当成启动捷径**：v3.10.1 的动作表把「启动游戏」放在**第一项且 autofocus**，
而桌面右键菜单 `LibraryContextMenu` 里**根本没有这一项**（5 项：详情 / 启动管理 /
加入收藏夹 / 存档备份 / 删除）。于是「打开菜单随手一按 A」直接启动游戏，
既破坏同构，也放大了「按 X 就出事」的观感。

### 17.2 修法

| # | 改动 | 文件 |
|---|---|---|
| 1 | `_thumbDirections` 改为 `ly > 0 ? up : down`、`lx > 0 ? right : left`，并在文档里写明「正＝上/右，与 XInput 规范及右摇杆同约定」 | `services/bpm_gamepad_service.dart` |
| 2 | 给 `homeShelf` 补 `BpmFocusDomain`（三个二级板块一一对应装域） | `pages/big_picture_home.dart` |
| 3 | `FocusGlow` 新增 `onDoubleTap`：**有它时第一次按下不立即触发 `onSelect`，而是等满 300ms 双击窗口**，窗内再来一次即判双击 —— 与 `GestureDetector` 同时给 `onTap`+`onDoubleTap` 的语义一致；失焦丢弃挂起的单击。`BpmInteractiveWrapper` 透传 `onDoubleTap` | `widgets/focus_glow.dart`、`widgets/bpm_interactive_wrapper.dart` |
| 4 | 动作表**删除「启动游戏」**（回到与桌面右键菜单同构），初始焦点改落「详情」 | `widgets/big_picture_action_sheet.dart` |
| 5 | 自持模态锁 `_bpmModalDepth`：打开时同步 +1、Future 完成 -1，不依赖 `ModalRoute`；X/Y/Start/LB·RB/A/B 全部按 `_gamepadModalBlocked` 门控 → 关闭动画期间不许叠层、不许激活 | `big_picture_shell.dart` |
| 6 | 模态 pop 加路由守卫 `_popTopModalRoute()`（对齐 `app_dialog.dart` 的既有事故教训：无守卫的连续 pop 会弹掉下一条路由 → 路由栈错乱 → 卡死） | `big_picture_shell.dart` |
| 7 | 关闭态详情面板包 `ExcludeFocus(excluding: _panelGame == null)` | `big_picture_shell.dart` |
| 8 | 启动即时反馈：`_launchGame` 一进来就 `AppSnackBar.info('正在启动《…》…')`，避免启动耗时被误判为卡死 | `big_picture_shell.dart` |

**启动入口收敛为两处**（符合用户要求）：**卡片上双击 A**、**操作按钮板块的启动胶囊**（单击 A）。
「手柄启动」的鼠标对应物就是双击卡片，两者现在逐位一致。

### 17.3 验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib test/big_picture` | ✅ **0 error**（存量 553 → 552，无新增） |
| `flutter test test/big_picture` | ✅ **125 → 134** |
| 新增 `test/big_picture/focus/bpm_page_zone_wiring_test.dart`（**4 例**） | ✅ **挂真页面**（`BigPictureHome` / `BigPictureLibraryPage`）逐个断言 `kBpmHomeZones` / `kBpmLibraryZones` 每个板块都注册了焦点域且能算出落点焦点；并端到端验证「列表里 ←/→ 换卡且不跨板块」「连按两次 A → 触发 `onGameLaunch` 一次、不触发 `onTap`」 |
| 反向验证 | ✅ 临时摘掉 `homeShelf` 的 `BpmFocusDomain` 后，该文件 **2 例立刻失败**，报错信息正是「只包了 BpmFocusZone 没包 BpmFocusDomain」与 `focusEntryOf == false`（已还原） |
| `focus_glow_test.dart` +4 例 | ✅ 无 `onDoubleTap` 时单击**零延迟**（零回归）／窗内两按→`onDoubleTap` 且 `onSelect` 不落地／单击在窗后落地／失焦作废挂起单击 |
| `bpm_gamepad_service_test.dart` +1 例 | ✅ 上推(ly>0)→`up`、下推→`down`、右推/左推极性一起锁死 |

### 17.4 已知取舍与未验证项（诚实标注）

- **单击 A 在卡片上会延迟 300ms 才落地**（库页海报墙的「开详情」）。这是**必要的**：
  不延迟则单击会先占掉双击的机会，「双击 A 启动」永远不可能发生。这个延迟与鼠标在
  同一张卡上的行为**完全相同**（`GestureDetector` 同时给 `onTap`+`onDoubleTap` 时
  同样延迟 `kDoubleTapTimeout`）。主页 shelf 卡片感受不到延迟 —— 它的舞台切换由
  `onFocusChange` 驱动，不经过 A。
- **X 卡死的机理是源码推断 + 时间窗计算，未在真机复现**（无法在此环境连手柄）。
  第 5/6/7 条都是**结构性**封堵（自持计数 + 路由守卫 + 焦点排除），不依赖对机理的判断。
- **空板块边界**：板块若一个可聚焦组件都没有（如 `homeActions` 在 `stageGame == null`
  时返回 `SizedBox.shrink()`），`focusEntryOf` 返回 false，A 进不去。真机上
  `_loadGames()` 必先把最近游玩设为舞台游戏，因此不可达；未做额外兜底（最小变更）。
- ⚠️ **真机走查仍未做**（清单见 §17.5）。
- **DInput 的竖直轴极性未在真机确认**：本次依据「用户既报上推反向＝其活跃后端上报上为正」
  统一约定为正＝上，**未对 DInput 做额外翻转**。若真机上 DInput 模式的手柄竖直反向，
  修法是 `bpm_dinput_backend.dart` 的 `mapRaw` 里把 `thumbLY: ly` 改为 `-ly`
  （不要动服务层，那会连带影响 XInput）。

### 17.5 真机走查清单（v3.10.2）

1. **摇杆方向**：向上推左摇杆 → 焦点/板块**向上**走（与十字键一致）；
   横推 → 左右走。XInput 与 DInput 两种模式各试一次。
2. **主页**：LB/RB 或侧栏进入主页后自动落卡片列表（组件模式）；
   ←/→ 换游戏且舞台背景跟随、卡片自动滚到可见；**行首/行尾停住**。
3. **启动**：卡片上**连按两次 A** → 启动，且没有先弹出详情面板；
   单击 A（等 0.3 秒）→ 库页开详情面板、主页无副作用；
   操作按钮板块的「启动」胶囊单击 A 也能启动。
4. **X**：菜单只有 5 项（详情/加入收藏夹/标记切换/启动管理/存档备份/删除，**无启动游戏**）；
   打开后方向键切换、A 激活、B 关闭；**连续快速按 X 不再叠加、不再卡死**。
5. **关闭动画期**：关掉任一弹窗后立刻连按 A / B / X —— 不应重新打开刚关掉的面板、
   不应把底层页面一起弹掉。
6. **详情面板**：面板关闭后，方向键**不能**把焦点移进右侧屏外区域（不应出现
   「按 A 触发了看不见的按钮」）。
7. **B 三级回退**：组件 → 二级板块 → 一级板块；一级再按不误退大屏。
8. **Y / Start / Back / LT·RT / 右摇杆**：与 §16.5 同。
9. ⚠️ 盖世小鸡：先确认走 XInput 还是 DInput；若键位错位按产品名登记
   `_buttonLayouts`；若**仅竖直轴**反向，见 §17.4 末尾的 `-ly` 改法。

---

## 18. v3.11 — 自定义背景图 + OP 视频背景播放（2026-09-27）

> 完整方案：`docs/DEV/features/bpm_custom_backdrop_and_op_video_plan.md`
> 用户决策（2026-09-26 拍板）：视频方案 `video_player_win`｜音频开关**默认静音**｜
> 重播开关**默认每次选中都播**｜范围**仅 BPM 大屏**｜设置入口在**桌面设置页**｜
> NSFW **照常播放**｜重播入口在**详情面板操作区**｜最小化**暂停**｜门槛 **500MB / 1080p**。

### 18.1 新增能力

| 能力 | 实现位置 |
|---|---|
| 每游戏自定义背景展示图（替代封面作 backdrop） | `bpm_custom_backdrop` 字段 + `bpm_game_edit_dialog` 上传区块 |
| 每游戏 OP 视频：选中停留 3s → 封面淡出 → 视频在 UI 背后播放 → 播完淡出恢复 | `bpm_backdrop_media_controller` + `bpm_op_video_layer` + `_buildBackdrop` |
| 详情面板「播放 OP」手动重播 | `BpmGameDetailPanel.onReplayOp`（**仅当有视频时显示**） |
| 桌面设置页「大屏模式」栏 | `settings_tab.dart` + `settings_modal._buildBigPictureContent` |
| 窗口最小化暂停背景视频 | `WidgetsBindingObserver.didChangeAppLifecycleState` |

### 18.2 🔴 关键约束（勿回退）

- **零迁移**：`bpm_custom_backdrop` / `bpm_op_video` 走 `updateGameJson` merge，
  不升 `format_version`（依据：`GameJsonData.toJson()` 全库无生产调用方，不存在全量序列化写回）。
  **若将来引入全量写回，必须同时把这两个字段补进 `GameJsonData`。**
- **世代号防竞态**：`initialize()` 异步，3 秒计时内用户可能换 N 次游戏 →
  `_generation` 递增 + 异步落地校验 + 不匹配立即 `dispose`，绝不 `play()`。
- **预热放在 arming 期**：把「打开文件 + 首帧解码」挪进这 3 秒，计时到点直接 `play()`。
- **播放态遮罩**：`backdropScrimVPlaying` / `backdropScrimHPlaying` 比静态态更轻
  （深色底段 `0xA6`→`0x5A`、浅色 `0x6B`→`0x3D`），否则视频被压暗（与「尽可能清晰」冲突）。
- **视频层位置**：`_buildBackdrop` 的图片层**之上**、遮罩**之下**；
  `FittedBox(cover)` 铺满（不能 contain，会留黑边）；`IgnorePointer` 包裹（不拦截 pointer）。
- **无视频时逐位不变**：`videoActive == false` 时视频层不挂载、`imageOpacity` 恒 `1.0`。

### 18.3 验证与遗留

- ✅ `dart analyze`：**0 error**，41 项全为存量告警，本次新增/修改零新增。
  🔴 **本环境请用 `dart analyze` 而非 `flutter analyze`** —— 后者会卡在隐式 `pub get`
  （日志停在 `Analyzing N items...` 长时间无进展）。
- ✅ 单测：`test/services/bpm_op_video_preference_test.dart`（6 例）、
  `test/big_picture/services/bpm_backdrop_media_test.dart`（11 例）、
  `test/big_picture/services/bpm_backdrop_media_controller_test.dart`（13 例）。
- ✅ **`flutter build windows --debug` 已通过**（2026-09-27）：产物含
  `video_player_win_plugin.dll`（约 1.4MB）。用户开启 Windows「开发者模式」后
  本环境成功创建**真符号链接**（`reparse_tag=0xA000000C`），Flutter 的
  `_createPlatformPluginSymlinks` 检测到链接已存在即跳过创建，CMake 正常配置。
  🔴 **环境修复记录（复用价值高，工具在 `.workbuddy/`）**：
  ① 本沙箱曾把 `.flutter-plugins-dependencies` 的全部 path 写成**双反斜杠**
  （`C:\\Users\\...`），导致符号链接 / CMake 目标解析报 errno=2 —— 已用
  `fix_plugins_deps.py` 规范化 51 个字段（复现症状：`Link.createSync` 报
  `PathNotFoundException ... errno = 2`）；
  ② `.plugin_symlinks` 里的残留物（空目录 / 真实目录 / 旧链接）会让后续构建报
  `PathExistsException` —— 用 `safe_remove.py` 清理（junction 安全的递归删除，
  **禁止** `shutil.rmtree` 直删，会穿透 junction 删掉 pub cache）；
  ③ `video_player_win` 的 CMake 需 `ProgramFiles(x86)` 变量（Git Bash 不继承，
  需 `env` 显式注入）并联网下载 nuget.exe + WIL 包（含 SHA256 校验）。
- ⚠️ **未真机走查**：视频实际播放与清晰度、3s 停留手感、播完淡出恢复、
  切换游戏/开面板/切页的即时打断、最小化暂停、深/浅主题下遮罩观感、1080p 解码开销。

### 18.4 v3.11.1 — 体验修复 + 背景管理窗口（2026-09-27 午，用户三问题反馈）

| 问题 | 根因 | 修复 |
|---|---|---|
| ① 刚进 BPM 不播、切游戏无效（开详情/切库才恢复） | `initState` 漏调 `_syncBackdropPlayable()`，`_canPlay` 恒 false | initState 补初始同步 |
| ③ 开详情面板视频强停恢复背景图、关面板 3s 重播 | 面板开合走 `setCanPlay(false)`（=cancel） | **面板与视频完全解耦**：`setCanPlay` 只看页面；视频只在换游戏/离开主页/退出时停 |
| ② 管理入口迁移 + 多素材 | v3.11.0 单值字段只支持一张图/一个视频 | 背景管理窗口（见下） |

**背景管理窗口**（`bpm_background_manager.dart`，详情面板「背景」按钮弹出）：
- **背景图板块**：封面 + 多张已上传图（点选即设为背景），支持删除（连带删文件）/改名/多选上传；
- **背景视频板块**：多视频（游戏OP / 动画OP / ED…）+ 命名 + 「不使用」卡；上传含文件头校验 + 500MB；
- 「调整背景图位置」内嵌（复用 `BpmBackdropTuner`，**预览图改用当前所选背景图**）；
- **全部变更即时落盘即时生效**（`onChanged` → shell `_reloadBackdropAdj()` +
  `_backdropMedia.refresh()` 按新选中视频重新计时）。

**数据模型 v2（仍零迁移，ADR-015 延续）**：新增 `bpm_backdrop_images`（`[{file,name}]`）、
`bpm_backdrop_selected_image`（''=封面）、`bpm_backdrop_videos`、`bpm_backdrop_selected_video`
（''=不自动播）。**旧单值字段只读兼容**（并入列表，用户资产不丢），任何写操作顺带清空
旧字段完成一次性迁移。controller：取视频改 `resolveSelectedVideo`，新增 `refresh()`。

**编辑窗口**：背景图/背景视频区块改**只读展示所选**（管理入口提示指向「背景」窗口）；
【OP 视频】→【背景视频】；旧上传逻辑删除（约 -140 行）。

⚠️ 真机走查点（叠加 §18.3）：进入 BPM 首页 3s 即应起播（无需开详情/切库）；
开/关详情面板视频**不受影响**（不再强停/重播）；背景窗口两板块点选即时生效；
多视频命名 / 删除 / 切选；v3.11.0 传过的旧素材自动并入列表。



## v3.22 — 主页键鼠两段式交互 + 键盘适配（2026-10-03）

**背景**：开发者实机发现两个交互问题——① 主页 shelf 卡片单击直接进二级详情
（v3.14 把「选中」与「进详情」绑在同一次点击上，属设计漏洞）；② 键盘基本
无法操作（多处焦点悬空断点）。

### 鼠标两段式（用户拍板：先选中、再操作）

| 操作 | 行为 |
|---|---|
| 点击**未选中**卡片 | 只选中（落焦点 → `onFocusChange` → 切舞台，樱粉选中环浮现） |
| 点击**已选中**卡片 | 进二级详情 |
| 双击 | 启动游戏（双击第一击同样只落焦点，第二击构成 doubleTap） |
| 长按 | 动作表（不变） |

实现：`BpmInteractiveWrapper` 🆕 `focusToActivate` 参数（默认 false 旧行为逐位
不变）——`onTapDown`（即时，不等 300ms 双击判定窗口）检测组件无焦点时落焦 +
置 `_skipNextTap`，`_handleTap` 消费标志跳过 onTap；`onTapCancel` 清标志防拖动
残留。`requestFocus` 非同步生效，必须 `applyFocusChangesIfNeeded` 强制落定。
落点：`big_picture_home.dart` `_ShelfCard`（onTap 只剩 onOpenDetail）。

### 键盘适配

1. **连按两次 Enter/Space = 启动**：`FocusGlow` 🆕 `synthesizedDoubleTap`
   （手柄**合成** Enter 是否参与连按判定）+ wrapper 🆕 `keyboardDoubleTap`
   （真实键盘参与）。主页组合 `enableKeyDoubleTap:false + keyboardDoubleTap:true`
   → **手柄 A 仍是单击立即进详情（v3.14 决策保持），键盘连按两次 Enter 获得
   与鼠标双击一致的启动**。`_activate(allowDoubleTap:)` 按
   `event.synthesized` 分流。
2. **键鼠进二级详情自动落焦**：`_showGamePanel` 键鼠模式（`!_gamepadInputMode`）
   post-frame 落焦面板「游玩」主按钮（`_panelPrimaryNode`）——此前 stage 被
   `ExcludeFocus` 撤出后键盘焦点悬空，方向键/Enter 全灭（键盘闭环断裂点）。
   关详情 `_dismissPanel` 回锚触发卡片（条件放宽为
   `_panelLocked || !_gamepadInputMode`，加 `canRequestFocus/context` 防护防
   动作表项已销毁）。手柄两段式锁定语义零改动。
3. **搜索框 Esc 修复**：`_searchFocus` 挂 `onKeyEvent` —— 查询非空 → 清空并
   消费；为空 → 不消费（保留 Esc 退出大屏）。此前按 Esc 直接**退出大屏模式**
   （冒泡到 BpmShortcuts `_EscapeIntent`），与 v3.21 提示文案「Esc 清空」相反。

### 键盘操作流（完整闭环）

方向键 ←/→ 切换卡片（焦点即选中，自带滚动到可见）→ Enter 进详情（自动聚焦
「游玩」）→ 详情内方向键/Tab 浏览 → Enter 启动；或卡片上连按两次 Enter 直接
启动；Esc 返回。

### 明确不改（用户拍板）

- 库页海报墙「单击进详情」同款交互**不做两段式**（库页无舞台选中语义）。
- 手柄全部语义（A 进详情 / X 启动 / 面板两段式锁定）零改动。

### 已知边界

- 拖动 shelf 时按下位置卡片会落焦点（= 选中切舞台）——低频场景，符合
  「点按即选中」直觉，可接受。
- 键盘跨板块移动仅 Tab；主页搜索框无键盘入口（Ctrl+F 仅库页生效）——遗留。
- 真实键盘 Enter 单击进详情有 300ms 双击判定延迟（与鼠标单击一致，既有行为）。

### 验证

- 进程内 analyzer（`.workbuddy/analyze_probe/`）：5 文件 errors=0（3 条 warning
  均为存量：`big_picture_home.dart:104` 误挂 @override、`:584/:597` 未引用私有
  方法）。
- 🆕 测试 5 例（`bpm_interactive_wrapper_test.dart`）：两段式 3（未选中点击只
  落焦点 / 已选中点击触发 onTap / 未选中双击只触发 onDoubleTap）+ 连按分流 2
  （真实键盘 Enter ×2 = onDoubleTap；合成 Enter ×2 = 两次单击不构成双击）。
- ⚠️ `flutter test` / 真机走查待开发者终端补跑（本环境 CreateFile failed 231）。

## 19. 主页货架两端卡片选中放大被视口裁剪修复 + 库页海报墙同类审计（2026-10-04）

### 现象与根因

- 现象：选中**第 0 张**卡放大后，卡片左缘（樱粉描边 + 圆角）被竖直硬切；选中**最后一张**
  卡时右缘同理。逐像素验证截图（125% 缩放）：裁剪线 = 舞台左缘 + 32px（物理 200 = (128+32)×1.25）。
- 根因：货架 `Container` 水平 padding 32 与 `ListView` **无水平 padding** 叠加
  ⇒ 第 0 张卡布局左缘 == ListView 视口左缘；选中放大 `shelfFocusScale=1.06`
  ⇒ 单侧画出去 224×0.06/2 = **6.72px**，被视口默认 `Clip.hardEdge` 裁掉。
  竖直方向实测无裁剪（顶/底描边完整），不动。

### 修复（3 处布局数值 + 2 常量，卡片静止几何零变化）

| 位置 | 改法 |
|---|---|
| `big_picture_theme.dart` | 新增 `shelfPageInset = 32`（静止内缩语义）、`shelfViewportBleed = 12`（视口裁剪边界外扩，> 6.72） |
| `big_picture_home.dart` 货架 Container | 水平 padding `32 → shelfViewportBleed(12)` |
| `big_picture_home.dart` 标题行 | 外包 `Padding(horizontal: 20)`，标题行视觉位置不变（仍 32） |
| `big_picture_home.dart` ListView | 水平 padding `20`，与标题行对齐 |

净效果：卡片静止位置（内缩 32）、标题行位置（32）、间距、滚动/滚轮逻辑全部不变；
只有裁剪线从「距舞台 32」外扩到「距舞台 12」。代价：滚动时卡片改在距舞台 12px 处消失（原 32px），
LT/RT 键帽提示随视口外移 20px，观感几乎无差。

### 库页海报墙同类审计（实测推翻静态预估，不改代码）

- 静态估算 1.04 放大单侧溢出 ≈4.2px 会被裁——**实测否**：库页海报卡 FocusGlow
  自带 **4px 焦点环**（`cardFocusGlowWidth`），放大溢出 4.085px 几乎全被环吸收，
  真正落在视口外的仅 **0.085px（亚像素，不可见）**。
- 探针：`.workbuddy/probe_shelf_clip/library_wall_probe.dart`（flutter_tester 实跑）。

### 验证

- 🆕 回归测试 `test/big_picture/pages/big_picture_home_shelf_clip_test.dart`
  （断言两端静止内缩 = 32、余量 ≥ 放大溢出）：**`flutter test` 真跑 All tests passed**。
- `flutter analyze` 2 改动文件：4 条提示均为 HEAD 存量（`git show HEAD` 确认：
  `:104` 误挂 @override、`:108` dispose 缺注解、`:584/:597` 未引用私有方法），**0 新增**。
- 几何探针 `.workbuddy/probe_shelf_clip/shelf_clip_probe.dart`（flutter_tester）全绿。
- ⚠️ 未真机走查：左右两端各选中一次的观感、LT/RT 键帽新位置。
- 附：本轮 `flutter analyze` / `flutter test` 原生命令**恢复可用**（10-03 夜的
  CreateFile failed 231 为临时管道耗尽 + C 盘满，已缓解）。

## 20. 库页顶栏改造：收藏夹 chips 行移除 + 分类匣右侧滑入面板（2026-10-04）

### 需求（开发者拍板）

- 库页顶栏**第二行筛选 chips（所有游戏/准备入手/特别关注/新建）整行取消**；
- 顶栏「管理收藏夹」按钮改名「**分类匣**」；
- 点击后**不弹窗口**，与桌面版一致：**从右侧滑入分类匣面板**（三视图：
  收藏夹/标签库/会社墙），并做好 BPM UI 与手柄适配。

### 改动面

| 文件 | 内容 |
|---|---|
| `pages/big_picture_library_page.dart` | 删第二行 chips 与 `_buildCollectionChips`/`_collectionChip`；按钮改名+图标 `dashboard_customize`；`_wallGames` 扩展**会社过滤**（`SmartGroup.matches`）与**标签多选**（`concept:<id>`/`tag:<原文>`，维度内并集·维度间交集，照抄桌面 :293 口径）；三视图互斥（进其一会清另两个）；工具栏新增**活动筛选 pill**（面板收起时唯一可见筛选态，点=清除全部）；`_openCategoryBox/_closeCategoryBox`（`_zf.openPanel()/closePanel()` 状态机 + 焦点移入/回锚）；新增收藏夹重命名/删除/置顶与关注会社方法；**`_ManageCollectionsDialog`（~290 行）退役删除**（操作被面板行菜单吸收） |
| 🆕 `widgets/bpm_category_box_panel.dart` | 右侧滑入面板（420 宽，220ms easeOutCubic，与桌面同参数；BpmColors 深浅自适应）；头部三视图切换+关闭+搜索；收藏夹视图（所有游戏/各收藏夹/计数/图钉/⋯行菜单：重命名·置顶切换·删除/新建）；标签库视图（受控词表维度分区+多选 chip+「其他」）；会社墙视图（logo/衬线字标+副名+计数+关注星标）；⛔ 拖拽投放不做（鼠标特性，成员管理走卡片右键→BpmCollectionPicker，X 键语义不变） |
| `big_picture_shell.dart` | `ValueNotifier<bool> _categoryBoxOpen` 共享开关；手柄 **B=关面板**（插在 `_modalOpen` 之后、详情面板之前）；**LB/RB 切页先收面板**（`_handleGamepadPageShift`） |
| 🆕 `test/big_picture/widgets/bpm_category_box_panel_test.dart` | 7 例：三视图渲染/收藏夹回调/null 回调/标签 chip 回调/会社进入+关注/关闭/收起态零异常 |

**手柄/焦点设计**：面板打开 = `_zf.openPanel()`（复用详情面板状态机，zone=panel、
方向键由面板自身 FocusTraversalGroup 隔离、关闭恢复原板块层级）；键鼠打开后
post-frame 焦点移入面板首行（v3.22 防悬空同坑）；关闭后焦点回「分类匣」按钮
（防悬空在 0 宽 IgnorePointer 面板里——收起面板是常驻挂载而非移除）。

### 验证

- 进程内 analyzer（真实 analysis_server）5 文件：**改动 3 文件 errors=0**
  （shell 仅存量 2 warning + 1 info）；`flutter analyze`/`flutter test` 本轮再遇
  **CreateFile failed 231**（阵发性）未跑成。
- frontend_server_aot 编译探针：库页+面板链、shell 链、测试文件均 **0 error**
  （期间抓出并修复 2 个真实类型错误：页面缺 `_toggleFollowCompany`、面板 Builder
  闭包越界引用）。
- ⚠️ 未验证：`flutter test` 执行（环境恢复后补跑）、真机走查（面板滑出观感、
  手柄 B/LB-RB/A 全链路、深浅主题、长列表滚动）。

### 🔴 只报告不改：并行会话 WIP 造成工作区编译破损

工作区存在**非本任务**的未提交改动：`lib/widgets/library/category_box_sidebar.dart`
（+509/−45，未提交）与**未跟踪**的 `lib/services/tag_library_override_store.dart`
（缺 `removeWhere`/类型不匹配等 **8 error**；sidebar 引入 `onWillAcceptWithData`/
`MenuDivider` **3 error**——HEAD 版本 grep=0，即破损来自未提交 WIP）。
**当前工作区真实 build 必挂**（桌面 library_page 同样 import 该文件）。
本任务改动与 HEAD 语境自洽（编译探针剩余 error 全部位于上述两文件）。
处置建议：让并行会话把标签库写穿/隐藏这条线做完（或 `git restore` 回滚），
再全量 `flutter analyze`。

### 后记：编译破损警报解除（同日）

§20 初稿发出的「并行会话 WIP 造成工作区 build 必挂」警报**已解除**：标签库线
（sidebar 内联编辑/写穿/隐藏 + `tag_library_override_store.dart`）由并行会话
修复后提交为 `7f12c25`。进程内 analyzer 复测 sidebar / store / BPM 库页 / 面板
4 文件 **errors 全 0**，HEAD 恢复编译自洽。
另记一条工具经验：`frontend_server_aot` 离线编译探针对 `onWillAcceptWithData`/
`MenuDivider` 报过**假阳性**（进程内真实 analyzer 为 0）——该通道抓「自己文件」
的真实错误可靠（本轮 2 个真实类型错误均被抓到），但判「存量文件是否破损」
以进程内 analyzer 为准。

## v3.23 — 库页海报墙鼠标两段式「先选中再操作」（2026-10-10，需求 4）

**用户口径**（5 组优化之第 4 组）：BPM 库页鼠标**第一次点击 = 选中该游戏**；
游戏需要先选中，再进行「进入详情 / 打开游戏」操作。

**变更**：`big_picture_library_page.dart` `_PosterCard` 的 `BpmInteractiveWrapper`
新增 **`focusToActivate: true`**（唯一代码改动，+5 行）。

| 操作（库页海报卡） | 改前 | 改后 |
|---|---|---|
| 点击**未选中**卡片 | 直接进二级详情 | **只选中**：落焦点 → 辉光环 + 操作角标浮现 + `onFocusChange` → `onGameFocused(game)` |
| 点击**已选中**卡片 | — | 进二级详情（`onOpen`） |
| 双击 | 启动 | 启动（首击同样只落焦点，二击构成 `onDoubleTap`） |
| 长按 / 右键 | 动作表 / 上下文菜单 | 不变 |

> ⚠️ **本变更推翻了 v3.22「明确不改」的第 1 条**（「库页海报墙单击进详情同款交互不做
> 两段式（库页无舞台选中语义）」）——用户明确要求库页也要「先选中再操作」，故采纳。
> 机制与主页 `_ShelfCard`（`big_picture_home.dart:899`）**逐位同款**，无新代码路径。

**验证**：进程内分析器 2 文件 **0 error / 0 warning**；
离线 widget 探针 `.workbuddy/probe_bpm_focus/`（flutter_tester 真跑）**7 PASS / 0 FAIL**：
S1 未聚焦首击 → `onTap` 不触发但 `onFocusChange(true)`；S2 已聚焦再击 → `onTap` 触发；
S3 未聚焦双击 → `onDoubleTap` 触发、`onTap` 不触发、首击已落焦点；
S4 对照组 `focusToActivate=false` 首击直接触发 `onTap`（旧行为）。
⏳ 未真机走查。

### 🔴 探针实测的新知：`onTapDown` 并非总是「即时」

`focusToActivate` 的落焦点挂在 `onTapDown`。实测（S1 首轮失败 → 修正手势时长后通过）：
手势树里同时存在 `DoubleTapGestureRecognizer` 时它会 `hold` 竞技场约 `kDoubleTapTimeout`
(300ms)，而 `TapGestureRecognizer.onTapDown` 只在以下两种时机触发：

1. 按下时长跨越 `kPressTimeout`（**100ms**）→ `didExceedDeadline` 立即 `_checkDown()`；
2. tap 赢下竞技场（双击窗口过期后）→ `acceptGesture` → `_checkDown()`。

⇒ **一次很快的点击（<100ms 按下即抬起）的「选中」反馈要等 ~300ms 才出现**；
按住 ≥100ms 的点击则约 100ms 就有反馈。属 `v3.22` 引入的既有特性（主页同款），
本次未改（改需动共享组件 `bpm_interactive_wrapper`，超出本需求范围）——**已记录待评估**：
若要「按下即选中」，应改用 `Listener.onPointerDown` 做落焦点判定，而非 `onTapDown`。

### 关联发现（未改，仅报告）

- 库页海报卡宽仅 **140px**（`BigPictureTheme.posterCardWidth`），操作角标
  `BpmActionHintBadge` 文案「[左键] 进详情 / [左键双击] 启动」在改为两段式后**精度不足**
  （实际是「单击选中，再单击进详情」），但**已无横向空间**再补「选中」二字，故保持原文案。
- ⚠️ `lib/big_picture/widgets/bpm_action_hint_badge.dart`（及其同族 `bpm_key_cap.dart` /
  `bpm_page_switch_hint.dart` / `bpm_trigger_page_hint.dart`）**仍未纳入 git**（被
  `big_picture_home.dart` / `big_picture_library_page.dart` 引用）⇒ 新克隆无法编译。
  本次**未触碰**（存量问题，已在上轮报告）。
