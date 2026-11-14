# 探索板块免责协议门禁（进入前弹窗 + 可拒绝）

> 2026-10-10 · 需求 2 · 涉及 `lib/main_container.dart`、`lib/pages/discover_page.dart`、
> `lib/widgets/discover_disclaimer_dialog.dart`

## 1. 口径（用户原话）

> 用户在初次准备进入与探索库相关内容时就弹协议窗口，所以应该是在进入探索库前弹协议而不是在进入了
> 探索库后再弹协议窗口，该协议窗口允许用户拒绝，拒绝后不进入探索库内容，下次仍准备进入与探索库
> 相关内容时就继续弹协议窗口。

## 2. 改前

- 探索板块 = 侧边栏【探索】→ `NavPage.discover` → `ExploreHallPage`（探索大厅），
  大厅内「开始探索」再进 `DiscoverPage`（原探索库）。
- 免责弹窗由 `DiscoverPage.initState`（`_showDisclaimerIfNeeded`，原 `:196` / `:204`）在
  **页面已构建之后**触发 ⇒ 视觉上「先看到探索库、再被弹窗盖住」，即用户抱怨的
  「进入了探索库后再弹协议窗口」。
- `showIfNeeded` 返回 `void`，弹窗只有「勾选同意 → 进入探索页」一条路，**没有拒绝路径**。

## 3. 改后

> ⚠️ **本节的门禁位置（挂在 `_onPageChanged` / `_onGoDiscover`）已于同日被 §6 修订**，
> 现下沉到探索大厅的两个「探索行为」出口。本节其余内容（弹窗双键、拒绝不写 prefs）
> 仍然有效。

| 文件 | 改动 |
|---|---|
| `widgets/discover_disclaimer_dialog.dart` | 新增静态 `ensureAgreed({context}) -> Future<bool>`（替换 `showIfNeeded`）；弹窗新增可选 `onRejected` + 「暂不进入」按钮；footer 改「拒绝 / 同意」并排双键 |
| `main_container.dart` | `_onPageChanged` / `_onGoDiscover` 改为 `async`，进入 `NavPage.discover` 前先过 `_ensureDiscoverAccess()` |
| `pages/discover_page.dart` | 摘除 `_showDisclaimerIfNeeded`（定义 + 两处调用）与对应 import |

- **门禁位置**：`_ensureDiscoverAccess()` = `await DiscoverDisclaimerDialog.ensureAgreed(context: ...)`；
  返回 false（拒绝 / 未同意）→ **直接 return，不切页**。
- **两个入口全覆盖**：侧边栏 `_onPageChanged(NavPage.discover)`；库页「探索」按钮 `_onGoDiscover()`。
  （全局只有这两处把 `_currentPage` 设为 `NavPage.discover`。）
- **拒绝不写 prefs**：`ensureAgreed` 只在勾选同意并点「进入探索页」时 `markAsAgreed()`；
  拒绝 / 关闭仅 `pop(false)` ⇒ 下次准备进入仍会弹（符合口径）。
- **已同意**：`hasAgreed()`（`_versionKey` ≥ `_disclaimerVersion = 2`）→ 不弹窗，直接返回 true。
- 「进入探索页」按钮未勾选时 `onTap == null`（禁用态，底色 `AppColors.placeholderText`），
  勾选后转为 `AppColors.border`。

## 4. 验证

- 进程内分析器 3 文件 **errors=0**（`discover_page.dart` 3 条 warning 均为存量：
  `pb_config` / `global_install_center` 未用导入、`_isSearching` 未用字段）。
- 离线 widget 探针 `.workbuddy/probe_discover_gate/`（`flutter_tester` 真跑）**24 PASS / 0 FAIL**：
  S0 页面真实点击 sanity；S1 双键 + 未勾选禁用 + 勾选转可用 + 拒绝触发 `onRejected` / 关窗 / 不写 prefs；
  S2 未勾选确认键 `onTap == null` + 同意写 prefs；S3 `ensureAgreed` 拒绝 → false；
  S4 已同意 → true 且不弹窗；S5 `ensureAgreed` 同意 → true 且写 prefs。
- ⏳ **未真机走查**：侧边栏点【探索】/ 库页点「探索」→ 协议窗在内容之前出现；点「暂不进入」→ 停在原页；
  再次准备进入 → 仍会弹。

## 5. 探针环境踩坑（供复用）

1. 必须 `ThemeRegistry.registerBuiltinThemes()`，否则 `AppColors` 读 `AppThemeManager.current`
   （null）→ 弹窗 `build` 抛 `Null check operator used on a null value`。
2. 对「应用 Future」直接 `await` 在 fake-async 下可能挂死 → 一律 `.then((v) => cap = v)` + pump 冲刷微任务。
3. 🔴 **对话框路由内的真实指针事件在本 harness 里落不到弹窗内容**：实测拒绝按钮中心的命中路径以
   `_RenderColoredBox`（ModalBarrier）为叶、祖先含 `BlockSemantics/ExcludeSemantics`，即命中了遮罩层；
   而页面级 `InteractiveWrapper` 的真实点击（S0）正常。故弹窗内交互改用
   「取按钮 `GestureDetector.onTap` 直接调用」的确定性断言方式验证接线。

## 6. ⚠️ 触发点修订（2026-10-10 同日，用户反馈）

**§3 的「门禁位置」与 §4 的验证结论已被本节取代。**

**用户口径**：协议应在**首次探索行为前**弹——「点击相关话题内游戏、点击系列游戏等进入探索游戏的
游戏详情前，或点击探索按钮准备进入探索库前」；而「进入探索大厅就弹」是错的（大厅本身可自由浏览）。

**根因**：探索板块 = `NavPage.discover` → `ExploreHallPage`（**探索大厅**，默认首界面）；
探索库（`DiscoverPage`）只是大厅内部的 `_showLibrary` 状态视图（`_enterLibrary()` 切换、
Offstage 保活）。§3 把门禁挂在「切到 `NavPage.discover`」上 ⇒ 等于一进大厅就弹。

> 附带：§3 提到的库页入口 `_onGoDiscover` 其实是**死参数** —— `LibraryPage.onGoDiscover`
> 全库只有声明与传参、**无任何调用点**（需求 2 之前就存在）。本次仅移除其门禁，未删参数。

**修订后**：

| 文件 | 改动 |
|---|---|
| `pages/explore_hall_page.dart` | 新增可选注入 `ensureDiscoverAgreed`（null = 放行，测试/预览可独立构造）+ `_ensureExploreAccess()` 探询 + `_guardedGameTap()` / `_guardedEnterLibrary()` 两个守卫；**6 个出口全部收口** |
| `main_container.dart` | `_onPageChanged` 删除门禁并**恢复同步**、`_onGoDiscover` 恢复一行 `setState`；改由 `ExploreHallPage(ensureDiscoverAgreed: _ensureDiscoverAccess)` 注入 |
| `pages/library_page.dart` | 顶栏按钮文案「收藏夹」→「分类匣」（对齐 BPM 既有命名） |

- 出口全景（🔴 其中「系列合集」与「探索库内卡片」原先**绕过**统一通道、直连 `widget.onGameTap`，
  本次一并收口）：

  | # | 出口 | 行为 |
  |---|---|---|
  | ① | 月历条目·命中本地库 | 进游戏详情 |
  | ② | 相关话题卡片 | 进游戏详情 |
  | ③ | 系列合集作品（原先绕过） | 进游戏详情 |
  | ④ | 文档区·发布判重命中 | 进游戏详情 |
  | ⑤ | ⑦开始探索 / 文档区「进库查看」 | 进探索库 |
  | ⑥ | 探索库内点作品（原先绕过） | 进游戏详情 |

- **不弹的行为**（边界）：月历条目未命中本地库 → 打开 KUNGAL 外链；常用站点外链；文档区本地库
  启动。均属「访问外部站点 / 本地启动」，非「进入游戏详情」。
- 拒绝 → 该次行为不执行、用户停留在大厅；已同意 → `hasAgreed()` 直接放行（§3 的 prefs 语义不变）。

**验证**（取代 §4 的探针结论）：进程内分析器 `explore_hall_page.dart` / `main_container.dart`
**0/0/0**，`library_page.dart` **0 error**（4 条 warning/info 全存量）；离线 widget 探针
`.workbuddy/probe_discover_gate2/`（`flutter_tester` **真实渲染 `ExploreHallPage`**）
**22 PASS / 0 FAIL**：S1 进大厅 `gateCalls==0` 且 `DiscoverPage` 未创建；S2 系列作品经门禁且拒绝不转发；
S3 文档「进库查看」经门禁且拒绝不进库；S4 「开始探索」经门禁且拒绝不进库；S5 同意后进库；
S6 库内点作品经门禁并转发；S7 话题板块接线非空。⏳ 未真机走查。

**探针新知**：给页面留一道「门禁注入缝隙」后，「是否弹协议」被压缩成一个**可断言的计数器**
（`gateCalls`）——比去驱动真实对话框稳健得多。凡「时机类」需求都建议照此留缝。

## 7. 库页顶栏「收藏夹」→「分类匣」命名对齐（2026-10-10）

- `lib/pages/library_page.dart` `_buildCollectionsButton`：Tooltip / 注释「收藏夹」→「分类匣」。
- 依据：该按钮打开的就是 `CategoryBoxSidebar`（**分类匣**三视图：收藏夹 / 标签库 / 会社墙），
  且 **BPM 库页同款按钮早已叫「分类匣」**（`big_picture_library_page.dart` 的
  `semanticsLabel: '打开分类匣'` 与按钮文本 `'分类匣'`）⇒ 本次是桌面 / BPM 命名对齐。
- 图标**未改**（保留 `Icons.collections_bookmark_outlined`）。
