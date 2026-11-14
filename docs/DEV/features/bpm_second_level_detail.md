# 功能档案：BPM 二级游戏详情（全屏整页）

| 项 | 值 |
|----|-----|
| **状态** | 开发中（代码已落地并通过测试，**未真机走查**） |
| **优先级** | P1 |
| **创建日期** | 2026-09-28 |
| **最后更新** | 2026-09-28 |
| **关联需求单** | —（用户口头需求 + B 站参考视频 BV1mZH7eCE8v「最好看的 Gal 启动器主题 ubiquity」+ 参考截图） |
| **关联决策** | 见 §5（本次 4 项口头拍板） |
| **关联功能档** | `big_picture_v3_cinema.md`（BPM 总档）／`bpm_custom_backdrop_and_op_video_plan.md`（背景图与 OP 视频） |

---

## 1. 目标：解决什么问题

用户 2026-09-28 拍板「**彻底改造** BPM 的游戏详情」：废弃 v3.3 的 520px 右侧滑出浮窗
（`widgets/bpm_game_detail_panel.dart`），改为对标 Playnite 全屏主题 **(u)biquity** 的
Galgame 大屏风格的**二级详情整页**。

旧面板的问题：它是「隔着背景浮在右下角的一块面板」，与 ubiquity 那种
「全屏艺术图 + 左侧信息压在上面」的沉浸式观感完全不同。

---

## 2. 页面结构（三层）

```
┌─────────────────────────────────────────────────────────────┐
│ 层1 全屏背景：游戏 OP 视频 / 艺术图 + 暗色渐变蒙板（不随滚动移动）│
│ ┌───────────────────────────┐                               │
│ │ 层2 左侧悬浮信息面板       │  层3 右侧纯背景区             │
│ │ （全屏高度 / 固定 / 磨砂   │  （无任何 UI，留给艺术图/视频）│
│ │   模糊 / 右缘渐变消散 /    │                               │
│ │   弥散外阴影 / 无硬边框）  │                               │
│ │ ① 大号标题·会社·标签组     │                               │
│ │ ② 简介 + 截图（L 型排版）  │ ← 唯一垂直滚动视口            │
│ │ ③ 游玩统计（时长/上次/状态）│                               │
│ │ ④ 底部常驻按钮行           │                               │
│ └───────────────────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

- 层 1 **不是**本功能新建的：直接复用 shell 的 `_buildBackdrop()`
  （艺术图 / OP 视频 / 遮罩 / 微光全在同一处，换游戏即换背景）。
- 层 2 = 本功能全部内容（`BpmGameDetailPage`）。
- 层 3 为空：用户明确「右侧纯留给背景大图 / 视频」。

### 2.1 左侧面板内部排布（面板整体**不滚动**）

| 区 | 内容 | 是否滚动 |
|---|---|---|
| ① 游戏数据区 | 大号标题（得意黑 40px）／制作会社／副标题／标签组 | 固定 |
| ② 游戏介绍 | 「简介」+ 截图滚页图，**保持 L 型环绕排版**（与桌面 `GameDetailDialog` 同构） | **唯一滚动视口** |
| ③ 游玩统计 | 游玩时长 ／ 上次游玩 ／ 游玩状态（点击循环切换） | 固定 |
| ④ 底部按钮行 | 游玩（左上角 M / L 两个指示灯）→ 编辑·目录·删除 → 背景 → 播放（正上方为隐藏 UI 按钮） | 固定 |

---

## 3. 关键实现约束（🔴 勿回退）

### 3.1 挂载点：仍走「面板」这套既有状态机

新页面**不是** stage 里的第三个页面，而是替换掉 shell Stack 里原
`BpmGameDetailPanel` 的位置（`big_picture_shell.dart` 第 5 项子节点）。原因：
`_zf.openPanel()` / `BpmZoneId.panel` / ExcludeFocus / A 键两段式 /
`_panelScrollController`（右摇杆·LT/RT 的滚动落点）这一整套手柄语义是既有且经过
真机验证的，换页面不必动它们。

因此**必须保留**：
- `_panelGame != null` 时才 `IgnorePointer` 放行；
- `ExcludeFocus(excluding: _panelGame == null)` —— 关闭态 widget 仍在树上做退场，
  不排除焦点就能把焦点移进看不见的面板（v3.10.2 的老坑）；
- `primaryFocusNode` 挂在「游玩」按钮上（A 键第二段的落点）；
- `scrollController` 挂在②的滚动视口上。

### 3.2 🔴 rail / stage / 顶栏在二级详情期间**整体撤出绘制**

用户明确要求「进二级详情时侧边栏、底栏、顶栏都看不到」。而新页面只有左侧面板是不透明的，
其余区域**透明**（直接露出底层背景）—— rail / stage 若仍在绘制就会从透明区域透出来。

实现：`Visibility(visible: !detailOpen, maintainState: true)` + `ExcludeFocus`。
- 用 `maintainState`（`Offstage`）而**非条件卸载**：区域内页面状态（库页滚动位置 / 搜索词）
  与焦点域注册必须原样保留；条件卸载会让它们全部丢失。
- `detailOpen = _lastPanelGame != null`（含进出场动画窗口），用 `_panelGame != null`
  会让动画那 300ms 看到 rail 在详情底下闪一下。
- 副作用（可接受）：`Visibility(maintainState)` 默认关 TickerMode，被覆盖期间的
  页面内动画暂停 —— 正好省 CPU，恢复时继续。

### 3.3 背景跟随：进详情即把舞台游戏切到「正在看的这部」

`_showGamePanel` 里追加 `_onStageGameChanged(game)`。否则从库页进详情会看到
「别人的」背景与 OP 视频。该函数自带同游戏幂等（标题 + 目录双比对），
从主页进当前舞台游戏时不会重置 OP 的 3 秒计时。

### 3.4 磨砂玻璃：三段羽化 + 右缘渐变消散到全透明（无硬边框）

与 `big_picture_nav_bar.dart::_buildFeatheredGlass` 同构：本体贴左（blur sigma 7 + 底色渐变），
向右依次两条**递减模糊强度**的窄带（sigma 4.5 / 2.2）把「sigma 7 → 0」的锐利跳变摊成过渡带。

🔴 **外扩带的宽度只等于带本身** —— rail 那版写的是 `railWidth + extents[i]`，对 128px 宽的 rail
只是多糊 160px 背景；对 520px 宽的**全高面板**会变成右侧近 550px 一大片异常模糊。
🔴 底色必须**渐变且衰减到 0**：平涂底色的裁剪边就是色块边（rail 侧实测过 11 级台阶）。
⚠️ 调浓度用 `withAlpha((alpha * k).round())`，`withOpacity(x)` 是**替换** alpha 而非相乘。

外阴影用 `CustomPainter` 沿右缘撒一串 4 段非线性衰减的径向柔光斑
（与 `_RailAmbientPainter` 同款手法，比 `BoxShadow` 更容易做到无硬边不成块）。
🔴 柔光斑半径必须 ≤ 画布外扩量（`_shadowSpread`），否则渐变尚未归零就被裁掉 → 右缘硬切线。

### 3.5 结构：`Positioned` 只能挂在 `Stack` 直接子级

面板层是 `Positioned.fill → AnimatedSlide → AnimatedOpacity → Stack(内层)`。
**不能**把 `Positioned` 直接塞进 `AnimatedSlide` 下面 —— 中间隔着 pass-through 渲染对象时
ParentDataWidget 的父级约定会在**运行期**炸（analyze 全绿也照样崩）。
这条已由一个 widget 测试锁死。

---

## 4. 隐藏 UI（欣赏背景）

「播放」按钮正上方是**隐藏 UI** 按钮：面板整块淡出，只剩背景图 / OP 视频。

| 输入 | 处理方 | 说明 |
|---|---|---|
| 鼠标移动 / 点击、键盘任意键 | 页面内「唤回层」 | `HitTestBehavior.opaque` —— 否则点击会穿透到 shell 的面板外屏障，**想唤回却把详情关了** |
| 手柄任意键 | **shell** | 手柄事件走 FFI 轮询、不经 Flutter 键盘通道，页面侧收不到；在 9 个手柄语义入口 + `_onEscape` 各加一道 `_consumeDetailUiHiddenInput()` |
| ESC | shell | 隐藏态下只唤回，不退出详情 / 大屏 |

✅ **已修（2026-09-28 本轮）**：`handleGamepadDirection / TriggerShift / Scroll / PageShift /
ContextMenu / Mark / SystemMenu / Confirm / Back` 共 **9 个入口 + ESC** 全部接入闸门。
接闸门之前，隐藏态下按 X / Start 会在**看不见的界面**上叠加动作表、退出面板 —— 用户感知为「软件卡死」。
（属本轮自查发现并当场修复，未外泄成线上问题。）

---

## 5. 用户口头拍板（2026-09-28）

| 问题 | 结论 |
|---|---|
| 二级详情的覆盖范围 | **全屏覆盖整页**（rail / 顶栏 / 底栏一律不可见） |
| 「简介 + 截图」滚动容器位置 | **在左面板内，仅该区块可滚**；右侧纯留给背景 |
| 旧 520px 滑出面板 | **保留文件但不再引用**（标注已废止，功能稳定后单独提交删除） |
| 统计区「占用空间」 | **本期不做**（项目无该数据字段，不引入目录遍历开销） |

---

## 6. 涉及文件

| 文件 | 说明 |
|---|---|
| `lib/big_picture/pages/bpm_game_detail_page.dart` | **新增**，全屏二级详情页 + 截图轮播 / 灯箱 + 外阴影 painter |
| `lib/big_picture/big_picture_shell.dart` | 挂载点替换、rail/stage/顶栏撤出绘制、`_detailUiHidden` 状态与手柄闸门、`_showGamePanel` 切舞台游戏 |
| `test/big_picture/pages/bpm_game_detail_page_test.dart` | **新增**，9 例 widget 测试 |
| `lib/big_picture/widgets/bpm_game_detail_panel.dart` | 旧面板，**已废止引用**（文件保留，勿新增调用方） |

---

## 7. 验证

- ✅ `dart analyze lib/big_picture/pages/bpm_game_detail_page.dart lib/big_picture/big_picture_shell.dart`
  → **0 error**，仅 3 条**存量**告警（`bpm_context_menu` 未用导入、`_openBackdropTuner` 未引用、
  1 条 async-gap info），均为 HEAD 版本既有，与本次无关。
- ✅ `flutter test test/big_picture/pages/bpm_game_detail_page_test.dart` → **9/9 通过**。
  其中「1280×720 不溢出」这条**当场抓到真 BUG**：底部按钮行在 440px 内容宽下溢出 14px，
  已改为「游玩按钮组 `Expanded` 吸收余量、右侧按钮固定宽」。
- ✅ `flutter test`（全量）→ 见 DEV_LOG 同日条目。
- ⚠️ **未真机走查**（本会话无法启动 Windows 真机）：见 §8。

---

## 8. ⚠️ 未验证项（真机走查清单）

1. 磨砂玻璃观感：右缘消散是否够柔、有无可见硬竖线 / 台阶；深浅两套主题下都要看。
2. 弥散外阴影是否「无硬边不成块」，右侧背景是否被糊得过头。
3. 内容可读性：内容区右半落在底色消散段（alpha 0.55 → 0）之上，亮色艺术图下是否糊字。
4. 隐藏 UI → 各种输入唤回（鼠标移动 / 点击 / 键盘 / 手柄 A·B·X·Start·方向 / ESC）。
5. 手柄全流程：A 两段式进入（第一次进面板、第二次激活）、B 逐级回退、右摇杆 / LT·RT 只滚简介区、
   方向键不窜到已撤出的 rail / 卡片墙。
6. 进出场动画期间 rail / 顶栏不闪现；关闭后焦点是否落到合理位置。
7. 从**库页**进详情：背景与 OP 视频是否为目标游戏；关闭后回到库页状态（滚动位置 / 搜索词）是否完好。

---

## 9. 已知问题 / 待办

| # | 项 | 级别 | 说明 |
|---|---|---|---|
| 1 | 旧面板与 OP 视频的「可播」裁决未打通 | P2 | `_syncBackdropPlayable()` 只在 `_currentPage == 0`（主页）放行背景视频。从**库页**进二级详情时 OP 不会自动播（艺术图照常）。该裁决属并行会话 OP 视频功能的领域（其改动尚未提交），本次**刻意不改**，只报告。 |
| 2 | 旧面板文件与截图轮播 / 灯箱的临时重复 | P3 | 新页面复制了 `_BpmShotCarousel` / `_BpmLightbox`（旧面板同名私有件）。待旧面板删除时随之清理（同一提交删两边）。 |
| 3 | 游玩统计不再显示「启动次数 / 播放历史列表」 | P3 | 用户新规格的统计区只有时长 / 上次游玩 / 状态；`BpmPlayHistory` 数据照常记录（`big_picture_shell.dart` 启动埋点未动），只是二级详情不再展示。需要可加回。 |
| 4 | 游玩状态用「点击循环切换」而非下拉 | P3 | 刻意不用 PopupMenu：弹出层是路由，会触发 shell 的模态吞键，且手柄事件无法桥接到 popup 内部（既有「询问框手柄桥接」教训）。如真机手感不好可改分段选择器。 |
| 5 | `big_picture_v3_cinema.md` 未回写指针 | P3 | BPM 总档当前有并行会话未提交的 §18（自定义背景图 + OP 视频）改动，本次不便同文件混改；待其提交后补一行指向本档案的索引。 |

---

## 10. v3.13 二次重构（2026-09-28 晚，用户实机走查否定 v3.12 观感）

**用户结论**：v3.12 的「磨砂玻璃侧牌」=「僵硬的侧边牌子」，毫无设计感；
且**退出详情后界面直接卡死**。要求按桌面《详情面板设计.md》+ PN 实机截图复刻。

### 10.1 卡死根因（P0，已修）

`detailOpen`（驱动 rail/stage/顶栏 `Visibility(maintainState)` + `ExcludeFocus`）
此前绑的是 `_lastPanelGame != null`，而该字段**关闭后永不清空**（只为退场动画保留）→
关闭详情后 rail/stage/顶栏**永远 offstage**，屏幕只剩背景层，鼠标点不到任何东西。
修复：改绑 `_panelGame != null`（关闭瞬间恢复绘制与可聚焦，详情页在其上淡出）。
连带修复：`_dismissPanel` 的锚点焦点恢复改到 **post-frame**（此刻 stage 的
`ExcludeFocus` 才翻转，同步 requestFocus 会被「不可聚焦祖先」吞掉 → 焦点悬空）。

### 10.2 视觉重写（对齐《详情面板设计.md》两层遮罩）

- **删除**磨砂玻璃牌（3 层 BackdropFilter 全部移除）——「面板」不复存在。
- **Layer 1**：左→右线性暗色体积遮罩（`_BaseMask`），宽 = 屏宽 × 0.58；
  深黑 0.95 → 半透明灰 0.0，stops [0, .50, .68, .85, 1.0]，尾段衰减平缓；
  颜色取 `deepBase`/`deepPanel`（深浅主题各自成立）。
- **Layer 2**：`_EdgeDissolvePainter` 沿遮罩右缘铺 **16 + 2 个固定伪随机（LCG）
  径向柔光斑**，大小/浓度各异 → 非规则「水墨晕染」边缘，无 GPU 模糊开销。
- 底部 34% 高度的轻压暗渐变（衬按钮行）。
- 文本带 `heroTextShadow` 阴影 → 内容「浮」在背景上。

### 10.3 排版（对齐 PN 实机）

- 标题块顶部留白 = 屏高 × 0.27 → 标题垂直中心 ≈ 1/3 屏高；**水平沿用 PN 的左对齐**。
- 统计与按钮行不贴底：底部留白 = 屏高 × 0.065。
- 底部按钮行 = 游玩（`Expanded`，左上角 M/L 指示灯）→ **⋯**（`更多操作`）→ 背景 →
  播放（上方隐藏 UI 按钮）。
- **编辑 / 目录 / 删除收进「⋯」菜单**（`BpmDetailMenuSheet`）：由 shell 弹出
  （那里有 `_bpmModalDepth` 门禁与手柄模态路由）；条目把回调作为路由结果带回，
  shell 在**模态计数归零后**再执行，避免「菜单没关干净就开下一个弹窗被门禁拦掉」。
  删除防误触两段式随之移除（shell 的 `_deleteGame` 自带确认框）。

### 10.4 验证

- ✅ `dart analyze lib` → **0 error**（554 条存量 info/warning）。
- ✅ 详情页 widget 测试 **10/10**（新增「⋯ 触发 onOpenMenu」与「三个独立功能钮不允许回潮」）。
- ✅ 全量 `flutter test` → 见 DEV_LOG 同日条目。
- ⚠️ 未真机走查：晕染边缘观感、遮罩宽度/浓度、标题 1/3 落位、浅色主题下的白色遮罩观感、
  退出详情后 rail/stage 是否正常恢复且焦点归位。

---

## 11. v3.14 内容放大 + 整体右移（2026-09-28 晚，第二次实机走查反馈）

**用户结论**：内容展示与 PN 差距仍大 —— 内容太小、太靠左，没有成为二级详情的主体。

### 11.1 参数（对照 v3.13）

| 项 | v3.13 | v3.14 |
|---|---|---|
| 内容列宽 | 固定 520（屏宽 27%） | **屏宽 × 0.32（≈1/3）** |
| 内容列左缘 | 56（屏宽 3%） | **屏宽 × 0.075**（对齐 PN 的 ~8%，整体右移） |
| 大标题 | 固定 42 | **随列宽缩放 `cw*0.088`（clamp 38~60）** |
| 标题垂直中心 | ≈1/3 屏高 | **≈1/4 屏高**（顶部留白 0.27h → 0.20h） |
| 会社 / 标签 | 14 / 11.5，距标题 10/14 | **16.5 / 13，距标题 18/22** |
| 简介区顶标 | 无（小字「简介」） | **「Introduction」大顶标（24，得意黑）** |
| 简介正文 | 12.5 / 1.62 | **15 / 1.7** |
| 截图列 | 与文字列 50/50 | **58 / 42（截图面积放大）** |
| 统计 | 11.5 / 15 | **13 / 17** |
| 按钮 | 游玩 44 高、图标钮 40 | **游玩 50 高、图标钮 44、M/L 灯 24** |
| 遮罩 | —— | **未动**（用户明确「背后的遮罩可以先不调整」） |

### 11.2 结构变化

- 简介区小标题「简介」移除（与大顶标重复），L 型排版的 `titleHeight` 归零，
  截图列改为 `Expanded(flex: 42/58)` 比例分配。
- 「Introduction」顶标放在滚动视口**内部**（随内容滚动）。
- 字号/尺寸多数改为**随列宽（cw）或屏宽（w）缩放**，不同分辨率下比例一致。

### 11.3 验证与未走查项

- ✅ `dart analyze`（页面文件）→ **No issues found**；页面 widget 测试 **10/10**。
- ⚠️ 未真机走查：放大后的观感（标题 52px 是否够大 / 简介区在 720p 下是否过挤）、
  内容右移后与遮罩带的相对位置（遮罩带右缘 = 0.58 屏宽，内容右缘 ≈ 0.395 屏宽，仍在暗区内）。

---

## 12. v3.15 按钮区 PN 化 + 交互调整（2026-09-28 晚，第四次实机反馈）

### 12.1 详情页按钮区（PN 样式）

| 项 | 说明 |
|---|---|
| 描边按钮 | 除「游玩」外全部改为 PN 式**描边钮**：透明底（deepBase 0.45）+ 细亮边（white 0.30）+ 圆角 10；封装为 `_PnButton` |
| 选中交互色 | 鼠标悬停 / 手柄键盘选中 → **cherryRose**（「游玩」按钮的调色）：边框 rose 0.85 + 底 rose 0.16；用 `_PnButton` 自身的 MouseRegion + `onFocusChange` 驱动，并关掉 BpmInteractiveWrapper 的焦点环（避免双高亮） |
| 游玩按钮 | 不再 `Expanded` 拉满 → **固定宽 200、高 52**（圆角也从胶囊改 12） |
| 按钮行 | 游玩 → **手柄**（`GamepadGameConfigDialog.showForTitle`，与主页原「手柄」按钮同链路）→ **⋯** → **声音**（🔊/🔇）→ 背景 → 播放（上方隐藏钮）；整行 `FittedBox(scaleDown)`（窄窗口等比缩小，防溢出） |
| ⋯ 菜单 | **拉出式面板**（锚定 ⋯ 按钮正上方，页面自身 Stack 内），不再是路由弹窗；菜单外点击 = 只关菜单；shell 持有 `menuOpen` ValueNotifier → **B 只关菜单不关详情**、**A 直接激活菜单项**（不走两段式） |
| 声音开关 | 新增：写 game.json `bpm_op_video_muted`（零迁移 merge），`BpmBackdropMediaController.applyGameMuted()` 对**当前播放**即时生效；换游戏时由 shell 随 `_onStageGameChanged` 应用 |
| 播放按钮 | **不再收起详情**，原地重播（右侧露出背景区域可见） |
| 统计区 | **新增「启动次数」**（`BpmPlayHistory` 条数），四项 = 时长/启动次数/上次游玩/状态；与按钮行间距 18 → 10 |
| 标签框 | 胶囊 → **圆角方框（radius 6）** |

### 12.2 主页右侧按钮区移除 + 交互改动

- **移除**：hero 右侧「启动 / 手柄 / 详情」三钮 + `homeActions` 焦点域
  （`kBpmHomeZones` 同步移除；`BpmZoneId.homeActions` 枚举保留，状态机单测仍覆盖）。
- **鼠标**：shelf 卡片**单击 = 选中并进二级详情**；双击启动不变。
- **手柄**：A = 进详情（`enableKeyDoubleTap: false` → 单击立即生效，
  **移除「连按两次 A 启动」**，鼠标双击保留）；**X = 启动**当前目标游戏
  （原「X = 动作菜单」在实机卡屏，且入口已随按钮区移除；动作菜单保留鼠标长按入口）。
- 🔴 共享件 `BpmInteractiveWrapper` 新增 `enableKeyDoubleTap`（默认 true，
  关闭时只保留鼠标双击，FocusGlow 的键盘/手柄双击路径置空）。

### 12.3 验证与未走查项

- ✅ `dart analyze lib` → **0 error**（553 条存量）。
- ✅ 详情页 widget 测试 **12/12**（新增：拉出菜单开合/外点关闭/条目回调、声音钮、手柄钮）。
- ✅ 全量 `flutter test` → 见 DEV_LOG 同日条目。
- ⚠️ 未真机走查：PN 描边钮观感与 rose 高亮、拉出菜单位置/手柄 B 关菜单、
  声音开关对当前播放的实际生效、X 启动（原卡屏路径已绕开，需确认）、
  单击进详情的手感（原单击仅选中）、移除 hero 按钮后主页构图。

---

## 14. v3.17 按钮行统一规格 + 声音拉杆 + 手柄输入适配（2026-09-29 凌晨，第六次实机反馈）

### 14.1 按钮行

| 项 | v3.16 → v3.17 |
|---|---|
| 高度 | 各不相同 → **全部 44** |
| 游玩 | 200x52 渐变底 → **160x44 透明描边**（同设计语言；M/L 灯保留左上角） |
| 手柄 | 图标+文字胶囊 → **44 方钮纯图标** |
| 声音 | 独立方钮 → **拉杆开关**（44x24 胶囊滑杆 `_SoundToggle`），**仅有背景视频时出现**，挂在**背景按钮正上方**（与「隐藏钮在播放上方」同构） |
| 播放 | 不变（有视频才出现，隐藏钮在其上方） |

### 14.2 手柄适配

- **编辑弹窗**：标题框 `autofocus`（弹窗打开焦点即入模态）；截图删除钮
  裸 InkWell → BpmInteractiveWrapper；shell `_ensureModalFocus` 补
  「焦点在模态之下页面」的下探逻辑（方向键/A 曾继续作用于看不见的页面）。
- **文本输入**：A 落在可编辑控件（`findAncestorStateOfType<EditableTextState>`
  判定）→ `SoftKeyboardLauncher.show()` 拉起系统屏幕键盘（osk → TabTip 回落，
  3s 去抖，detached，静默失败）。搜索框 / 编辑窗输入框全覆盖；
  刻意不在鼠标点入时拉起（桌面用户有物理键盘）。

### 14.3 验证与未走查

- ✅ 四文件 `dart analyze` **0 error**；详情页 widget 测试 **13/13**。
- ⚠️ 未真机走查：拉杆观感与滑动动画、游玩 160 宽下的文字密度、
  编辑弹窗手柄全流程（方向→输入框→A 唤键盘→软键盘键入→保存）、
  搜索框 A 唤键盘、无视频游戏的按钮行构图。

---

## 15. v3.18 四项修正（2026-09-29 凌晨）

| # | 项 | 处理 |
|---|---|---|
| 1 | 按钮宽度 | 方钮统一 **60**（此前 width=null 实际只 ~20px）；卫星钮 60x24 对齐；游玩 160 不变 |
| 2 | 声音优先级 | 每游戏开关说了算；未设置过才跟随设置页全局默认；出声音量改常量 0.35（不再被全局压成 0） |
| 3 | 文本输入 | 软键盘启动不强依赖命令解释器（osk 直启 → 解释器 start → TabTip + 最佳努力启用触摸键盘服务）；B 键在输入框内完整退出输入态（关键盘 + unfocus + 回板块模式） |
| 4 | 手柄模式热判定 | ① 已连接 ② 实际输入，依次满足才进手柄模式；断开 / 键鼠介入立即回键鼠模式并清理残留状态 |

### 15.1 模式切换的清理清单（不留尾巴）

`_leaveGamepadMode()`：收起 ⋯ 拉出菜单 → 解除面板锁定（`_panelLocked` /
`_panelAnchor`）→ 恢复隐藏 UI（否则键鼠用户屏幕上只剩背景、无可点控件）
→ 退出板块模式 → 关闭软键盘。进入侧 `_enterGamepadMode()` 只在
「已连接 + 首次真实输入」时触发，首次输入既切模式也照常执行。

### 15.2 验证状态

- ✅ 七文件 `dart analyze` **0 error**。
- ⚠️ **全量测试本轮未跑成**：系统级命令解释器失效（`CreateFile failed 231`
  / 「所有的管道范例都在使用中」），flutter 工具启动即退出。待环境恢复补跑。
- ⚠️ 未真机走查：60 宽按钮行构图与 1280 窄窗缩放、声音优先级实际听感、
  A 唤键盘（依赖 Windows 触摸键盘服务）、B 退出输入框后 A 恢复、
  手柄连接后首次输入切模式与键鼠切回。

---

## 16. v3.19 焦点模式归属手柄 + 自绘虚拟键盘 + 数据链路修复（2026-09-29 下午）

### 16.1 输入模式判定（最终语义）

| 模式 | 焦点体系 | 进入条件 |
|---|---|---|
| 键鼠 | **无**焦点区域划分（板块高亮不出现，组件 hover/点击常规反馈） | 默认 |
| 手柄 | 有焦点（板块高亮 + 焦点导航） | ① 手柄已连接 ② 真实手柄输入，依次满足 |

实现：`BpmZoneFocusController._enabled`（默认 false）+ `enableFocusMode() /
disableFocusMode()`；`isZoneMode/isComponentMode` 均含 enabled 守卫。
`_enterGamepadMode` 启用、`_leaveGamepadMode` 停用、键鼠切页不抢焦点
（`landOnCardList` 只复位状态机坐标，不落焦）。

### 16.2 自绘虚拟键盘（`widgets/bpm_virtual_keyboard.dart`）

- 根因：osk/TabTip 是**独立系统窗口**，手柄 FFI 输入到不了 → 必须自绘。
- 挂载：rootOverlay OverlayEntry（编辑弹窗等 route 之上）；shell dispose 摘除。
- 键位导航：行列矩阵 + 边缘停；A = 按键；B = 关键盘（再按 B 才退出输入态）；
  鼠标/触摸同源；「系统键盘」按钮保留 TabTip 入口（中文 IME 配合物理键盘）。
- 注入：TextEditingController 直写（selection 感知插入、代理对退格），
  TextField 零改动。
- ⚠️ 中文正文输入：粘贴键 / 系统键盘+IME；拼音软键盘不在本轮范围。

### 16.3 数据链路（视图-模型脱节的三处）

| # | 位置 | 问题 | 修复 |
|---|---|---|---|
| 1 | BPM 编辑弹窗 `_save` | `updateGameJson` 只写文件，内存 LocalGame 旧值 → 界面显示旧简介（**文件实际已写入**，ATRI 12:07 实证） | 补 `regGame.description/tags` 就地同步 + notify |
| 2 | `join_controller.startCopyFlow` | 注册进内存的 LocalGame 漏传 description → 添加导入后简介空白 | 补传 `description` |
| 3 | 详情页截图区 | files 空且 urls 有值（后台下载未完成）显示「暂无简介」误导 | 显示「截图正在后台获取」占位 |

### 16.4 验证与未走查

- ✅ 六文件 dart analyze **0 error**；焦点 61/61、声音优先级 4/4、详情页 13/13。
- ⚠️ 未真机走查：进 BPM 无板块高亮（键鼠）→ 手柄输入后高亮出现 → 键鼠介入
  高亮消失；虚拟键盘手柄全流程（方向导航→A 键入→B 关闭→B 退出输入态）；
  编辑弹窗简介保存后详情页立即可见；新导入游戏简介立即可见。

## 17. v3.20 详情页焦点保持（2026-09-28 晚）

### 17.1 问题与根因

用户反馈：详情页隐藏/播放等按钮，无论手柄还是鼠标点击后，选中高亮被重置
回「游玩」。两条独立机制：

1. **指针点击不移动焦点**：`BpmInteractiveWrapper` 的鼠标/触屏点击走
   `GestureDetector`，FocusGlow 的 Focus 节点不会被请求 —— 点完焦点仍留
   在旧落点（「游玩」），观感即「高亮被重置」。
2. **唤回一律跳回面板入口**：`_setDetailUiHidden(false)` 的 post-frame
   一律 `_panelPrimaryNode.requestFocus()`（v3.18 语义：唤回层卸载后焦点
   悬空需补焦）—— 补的是「游玩」而非隐藏前的按钮。

### 17.2 改动

- **`widgets/bpm_interactive_wrapper.dart`**：新增 opt-in
  `requestFocusOnTap`（默认 false，既有调用点零回归）。`_handleTap`：
  `requestFocus()` 后必须 **`FocusManager.instance.applyFocusChangesIfNeeded()`**
  —— 🔴 requestFocus 挂起到 FocusManager 微任务队列（focus_manager.dart
  `_markNeedsFocusUpdate` → `scheduleMicrotask`），不强制落定的话，同帧
  内同步读 `primaryFocus` 的后续逻辑（本例 = shell 记录触发按钮）拿到
  的是旧焦点。
- **`pages/bpm_game_detail_page.dart`**：9 处自持控件启用 —— `_PnButton`
  （游玩/菜单/手柄映射/背景/重播 OP 全体）、`_SoundToggle`、
  `_hideUiButton`、`_modeLight`（M·L）、游玩状态切换、截图轮播箭头、
  大图预览关闭/下一张/箭头。手柄 A / 键盘 Enter 激活路径无需改动
  （激活本就发生在持焦节点上）。
- **`big_picture_shell.dart`**：`_detailFocusBeforeHide` 字段；
  `_setDetailUiHidden(true)` 同步捕获 `primaryFocus`（requestFocusOnTap
  已 apply 落定 → 拿到的就是触发按钮；手柄 A 激活时焦点本在按钮，同样
  成立）；唤回 post-frame 归还：`prev.context != null && prev.canRequestFocus`
  判存活（隐藏期间主 UI 只是 AnimatedOpacity 淡出、子树不卸载，节点存活）
  → 归还；否则回退 `_panelPrimaryNode`（详情已关/节点销毁）。
  `_showGamePanel` / `_dismissPanel` 清空焦点记忆。

### 17.3 验证与未走查

- ✅ 三文件 `dart format --output=none` 语法通过；`applyFocusChangesIfNeeded`
  对本仓 Flutter 3.24.3 SDK 源码确认存在（focus_manager.dart:1827，
  且断言禁止 build 阶段调用 —— 本调用在 tap 事件中，安全）。
- ⚠️ **analyze / flutter test 本轮未执行**：本机 Dart VM spawn 任意子进程
  报 `CreateFile failed 231`（管道耗尽，`cmd /c echo` 探针复现，系统级，
  非沙箱/SDK 问题）。环境恢复后补跑：analyze 三文件 + 详情页相关测试。
- ⚠️ 未真机走查：鼠标点隐藏钮 → 唤回后焦点应停在隐藏钮；手柄 A 隐藏 →
  任意键唤回 → 焦点仍在隐藏钮；点重播 OP 焦点不跳；唤回层「任意键唤回」
  语义不变（唤回层 Focus(autofocus) 保留，仅唤回后焦点归还原按钮）。
