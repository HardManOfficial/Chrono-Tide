# 库页体验治理与智能归纳板块 · 实施方案

> **文档性质**：阶段 A 只读审计产出（本方案未改动任何业务代码）。
> **审计方式**：治理文件全读 + 双链路并行子代理摸底 + 关键病灶逐处亲核（下文区分「已亲核」与「子代理报告」）。
> **用户已拍板决策**：① 换位机制**保留并修复**（所见即所得语义）；② 新游在手动排序下**顶置最前**；③ 智能归纳 v1 仅做**标签 + 会社**。
> **创建**：2026-09-14

---

## 0.5 实施状态（2026-09-14 执行完毕）

**状态：✅ Phase 0 → Phase 5b 全部代码完成；`analyze` 0 新增 error；全量测试 `595 通过 / 0 失败`
（519 → 570 → 595 的增长全部来自本方案新增用例，零回归）。真机走查（§11）待执行。**

| 阶段 | commit | 内容 | 测试基线 |
|------|--------|------|---------|
| 0 技术验证 | `5ff334e` | 顺序语义纯函数 + `game_order` 字段 + key 身份化机制实验 | 30/30（新）|
| 1 P0 修复 | `da1a110` | installedAt 覆写删除 / 最近游玩口径 / 拖拽索引错位根治 / 重载守卫 | 556/0 |
| 2 管理模式 | `1873603` | 底栏常驻 + 批量钮禁用态 + 勾选随视图清空 + 批量模糊集合语义 | 556/0 |
| 3 收藏夹内排序 | `4b56808` | `game_order` API + `applyCollectionOrder` + 拖拽解禁 + 重置入口 | 570/0 |
| 4 key 身份化 | `61eeff6` | `Map<游戏键, GlobalKey>` + `findChildIndexCallback` | 570/0 |
| 5a 智能归纳板块 | `8a131ec` | 派生分组服务 + 侧栏分区 + 写穿 API + 编辑弹窗 | 595/0 |
| 5b 拖拽写穿 | `613f666` | 拖卡片到归纳组 → 加标签 / 设会社 | 595/0 |
| 6 收尾 | 本文档 + DEV_LOG + HANDOFF | 档案/交接/记忆 + 真机清单 | — |

### 执行中的决策与偏离（如实记录）
1. **Phase 1 先禁拖、Phase 3 解禁**：拖拽门控的 `collectionReorderEnabled` 在 Phase 1 传
   `false`（收藏夹视图与筛选视图一样禁拖），Phase 3 落地 `game_order` 后翻为 `true`。
   这样**任何中间提交点都不会出现"能拖但写错地方"的状态**。
2. **Phase 5 拆成 5a/5b**：服务+视图（5a）与拖拽写穿（5b）分开提交，便于回归定位。
3. **「未填会社」组默认显示**（采纳 §13-Q2 的建议；用户可在编辑弹窗里隐藏）。
4. **服务加载放库页 `initState` 懒加载**，未改 `main.dart`——本功能只被库页消费，
   避免触碰稳定区（AGENTS.md §2.4）。
5. **成员写穿走 `LocalGameRegistry` 新增 API**（`setGameTag` / `setGameDeveloper`），
   与既有 `setGameCollection` 同款（原子写 game.json + 失败回滚内存 + structural 通知），
   未在库页直接操作 game.json。
6. **新增 `findChildIndexCallback`**（原方案未列）：key 身份化后，懒加载网格在元素换位时
   需要该回调才能定位新下标，否则可能重建元素（State 丢失）或触发重复 GlobalKey 异常。
7. **批量「模糊」语义修正**（原方案 §9 把 R5 列为"报告不改"，但其语义缺陷就是用户反馈的
   第 3 条问题本体）：改为集合语义——只要还有未模糊的 → 全部模糊，否则 → 全部取消模糊。

### 本方案仍未实施（明确保留）
- **§13-Q1 稳定 gameId**：手动顺序键仍是 `directoryPath`，目录真迁移 / 标题改名后
  手动顺序会失效（R3 未解决，建议单独立项）；
- **§13-Q3** 智能组视图内的组内拖拽排序（v1 不做）；
- **§13-Q4** 库页 keep-alive（需动稳定区 `main_container.dart`）；
- **R2** 单击/双击手势仲裁、**R4** 窄窗管理面板越界、**R5**「模糊」按钮命名（报告不改）。

---

## 0. 结论摘要（TL;DR）

| # | 用户反馈 | 真实根因（已核实） | 方案一句话 | 优先级 | 阶段 |
|---|---------|------------------|-----------|--------|------|
| 1 | 卡片位置不稳定（导入/编辑后刷新） | ① 原地更新覆写 `installedAt`（`local_game_registry.dart:796`）；② 手动排序无保存记录的新游 `?? -1` 恒顶置（`library_page.dart:845`，**用户拍板保留**） | 删除原地更新对 `installedAt` 的覆写；新游之间加次级排序保稳定 | P0 | Phase 1 |
| 2 | 换位体验差、机制不合理 | 🔴 拖拽索引取自**筛选后网格**、收尾却套用**主表 `_games`**（`:1023`→`:1517`）并立即落盘 prefs（`:1682`）——收藏夹/搜索/筛选下拖拽**静默写乱全局顺序**；且拖的是全局序而非所见视图序 | 「渲染列表 = 操作列表」原则重构 `_endDrag`；搜索/筛选激活时禁拖；收藏夹视图拖拽写**收藏夹内独立顺序** | P0 | Phase 1+3 |
| 3 | 管理模式问题（不选游戏不弹底栏、批量模糊） | 底栏条件 `_isEditMode && _selectedGamePaths.isNotEmpty`（`:1978`）；批量操作作用于**全局勾选**（`:2588/:2598/:2604`）而全选只选**当前可见**（`:271`）——跨视图勾选累积、语义分裂 | 底栏进入管理模式即常驻、0 勾选时批量钮禁用；勾选集随视图切换清空 | P1 | Phase 2 |
| 4 | 收藏夹内项目不可改位置 | 收藏夹无成员顺序字段，成员序跟随全局序（`collection_service.dart:11-13`） | `collections.json` 增 `game_order` 字段（`?? 默认值` 零迁移） | P1 | Phase 3 |
| 5 | 无按数据自动归纳的板块 | 无此功能；可复用素材充足（见 §2.4） | 派生式智能组（标签/会社）+ 手动编辑写穿回游戏数据 | P1 | Phase 5 |
| 6 | （深查发现）「最近游玩」排序错误 | `recently_played` 分支按 `playTime` 排（`library_page.dart:221`），与 `play_time`（`:224`）完全相同；`lastOpenedAt` 字段早已存在但未被消费（`local_game_registry.dart:234`） | 改按 `lastOpenedAt` 降序（空值沉底） | P1 | Phase 1 |
| 7 | （深查发现）卡片 State 串台隐患 | 卡片 GlobalKey 按位置分配（`_cardKeys[index]`，`:877-885` 同步、`:2376` 挂载），筛选/重排后同位置 key 绑到不同游戏 | key 改按游戏身份（`Map<游戏键, GlobalKey>` + `ValueKey`） | P1 | Phase 4 |

---

## 1. 背景与目标

### 1.1 背景

用户对库页（`lib/pages/library_page.dart`，3643 行，🔴 高危巨型文件）提出 5 项体验问题，并要求深查其他隐患。本次审计确认：5 项问题全部有真实代码根因，其中 2 项达到 P0（数据级写坏），另发现 5 项用户未提及的缺陷（§0 表 #6/#7 + §2.5）。

### 1.2 目标

1. 导入/编辑游戏**不再扰动**既有卡片位置；
2. 拖拽换位**所见即所得**：在哪个视图拖就只改哪个视图的顺序，且任何视图下都不会写坏其他视图的顺序；
3. 管理模式语义清晰：底栏随管理模式常驻、勾选集不跨视图残留、批量作用范围无歧义；
4. 收藏夹内可独立排序；
5. 新增「智能归纳」板块：系统按库内数据（v1：标签、会社）自动聚合分组，支持用户编辑（重命名/置顶/隐藏 + 成员增删**写穿**回游戏数据）。

### 1.3 非目标（本期明确不做）

- ❌ 不动 BPM 大屏库页（`lib/big_picture/`）——桌面库页验证通过后是否同步另立任务；
- ❌ 不动 `main_container.dart` 的页面保活结构（切页丢滚动位置问题只报告，见 §2.5-R1，涉及稳定区）；
- ❌ 不引入稳定 gameId（UUID）体系——手动顺序键仍是 `directoryPath`，其失效场景见 §10-R4 与 §13-Q1；
- ❌ 不扩充画师/声优/系列/发行日期字段（智能归纳 v2 再议，用户已拍板）；
- ❌ 不做 `dart format`、不重构无关代码、不顺手修 §2.5 之外的存量 analyze info。

---

## 2. 现状调研

> 行号标注：**【核】**=本次审计亲自读码核实；**【代】**=并行子代理报告（执行前需复核行号）。

### 2.1 顺序数据链路

| 事实 | 位置 | 核 |
|------|------|----|
| 排序选项 5 种：手动 `''`（默认）/ 最近添加 / 最近游玩 / 游玩时长 / 游玩状态 | `library_page.dart:216-236`（默认值 `:117/:695`） | 【核】 |
| 「最近游玩」按 `playTime` 排，与「游玩时长」分支完全相同 | `library_page.dart:221` vs `:224` | 【核】 |
| `LibraryGame.lastOpenedAt` 字段存在但排序未消费 | `local_game_registry.dart:234` | 【核】 |
| 手动顺序存 SharedPreferences（键 `directoryPath` 列表），加载时 `orderMap[...] ?? -1` → **新游恒顶置** | `library_page.dart:832-875`（`?? -1` 在 `:845-846`） | 【核】 |
| 保存顺序 `_saveGameOrder` 持久化 `_games` 的 `directoryPath` 列表 | `library_page.dart:1680-1689` | 【核】 |
| **原地更新覆写 `installedAt = DateTime.now()`**（新建分支 `:820` 不受影响） | `local_game_registry.dart:790-796` | 【核】 |
| 数据变更通知：注册表 ChangeNotifier → 库页 `_onRegistryChanged`（structural→`_loadGames`→`_applyCustomOrder`） | `local_game_registry.dart:766/:836`、`library_page.dart:547` | 【代】 |
| 无手动顺序时回退 `allGames`（`installedAt` 降序） | `local_game_registry.dart:434-438` | 【代】 |

### 2.2 拖拽换位链路（P0 病灶）

| 事实 | 位置 | 核 |
|------|------|----|
| 长按 300ms 起拖（`_dragDelay`），**仅 `_activeSort.isEmpty`（手动排序）门控**，未检查搜索/筛选/收藏夹视图 | `library_page.dart:81`、门控 `:2412/:2422/:2434` | 【核】 |
| 网格渲染的是筛选后列表（`itemCount: filteredGames.length`） | `library_page.dart:2242` 附近 | 【代】 |
| 起拖记录 `_originalIndex = index`（**筛选后列表的索引**） | `library_page.dart:1023` | 【核】 |
| 浮动卡取游戏用 `_filteredAndSortedGames[_originalIndex!]` | `library_page.dart:1462` | 【代】 |
| 🔴 收尾却对 `_games`（主表）做交换/插入并 `_saveGameOrder()` 落盘 | `library_page.dart:1512-1544` | 【核】 |
| 卡片 GlobalKey 按位置分配（`_cardKeys[index]`），`_syncCardKeys` 只做长度增删 | `library_page.dart:877-885`、挂载 `:2376` | 【核】（`:2376` 为【代】） |

**结论**：筛选/搜索/收藏夹视图下拖拽 = 用「可见列表索引」改「全量列表」，且立即持久化——**这是用户「换位机制不合理」体感的直接来源，也是手动顺序数据被写乱的源头**。

### 2.3 管理模式与批量链路

| 事实 | 位置 | 核 |
|------|------|----|
| 进入/退出：顶栏「管理」按钮 → `_toggleEditMode` | `library_page.dart:2518`、状态 `:247` | 【代】 |
| 底栏显示条件 = 编辑模式 **且** 至少勾选 1 个 | `library_page.dart:1978` | 【核】 |
| 底栏按钮：全选/取消/模糊/删除/快捷方式；`_editBarBtn` **无禁用态参数** | `library_page.dart:2584-2608`、`_editBarBtn :2615` | 【核】 |
| 批量操作取 `_games.where(勾选)` = 全局勾选集 | `library_page.dart:2588/:2598/:2604` | 【核】 |
| 全选 `_selectAll` 只选当前可见（`_filteredAndSortedGames`） | `library_page.dart:271` | 【核】 |
| 勾选集跨筛选/收藏夹/排序切换**不清空**（仅退出编辑/删除/全选/取消时清） | `library_page.dart:251/:475/:269/:277` | 【代】 |
| 右键批量菜单（改游玩状态/加收藏夹）另成一套入口 | `library_page.dart:323-366` | 【代】 |

### 2.4 收藏夹与可复用能力（已有但未被消费的能力）

| 能力 | 位置 | 对本方案的意义 |
|------|------|--------------|
| 收藏夹本体（名称/颜色/图标/顺序/pinned）集中存 `data/collections.json`；成员关系存各游戏 `game.json` 的 `collection_ids` | `collection_service.dart:9-13` | **收藏夹内顺序**加 `game_order` 字段即零迁移（与 ADR「新字段优先 `?? 默认值` 读取」一致） |
| 收藏夹三级排序（预设→置顶→普通）+ 写入时规整 | `collection_service.dart`（ADR-003） | 智能组的置顶/隐藏可照搬同一套「写入时规整」思路 |
| 探索页标签聚合：遍历 `game.tags` 收 Set + `DiscoverAllTagsDialog` 多选弹窗 | `discover_page.dart:660-664`（【代】）、`discover_all_tags_dialog.dart` | 智能组的「标签」维度可直接复用该聚合模式 |
| `LibraryGame.tags / developer / playStatus / source / mark / lastOpenedAt` 字段齐备 | `local_game_registry.dart:218-276` | 智能归纳 v1（标签+会社）**零 schema 变更** |
| `didUpdateWidget` 每次父重建即 `_loadGames` 全量重扫重排 | `library_page.dart:888-893` 附近 | 【代】Phase 1 顺手加变更守卫（低风险） |

### 2.5 深查发现的其他问题（只报告，本期处理与否见 §9 分批）

| ID | 严重度 | 现象 | 位置 | 核 |
|----|--------|------|------|----|
| R1 | P2 | 库页切换后**无 keep-alive**：切页回来滚动位置/编辑模式状态丢失（`main_container.dart:774-784` 重建 `LibraryPage`，无 Offstage 保活）——涉及**稳定区**，仅报告 | `main_container.dart:774-784` | 【代】 |
| R2 | P2 | 单击（弹详情 `:922`【代】）与双击（启动）共存时，Flutter 手势仲裁会让单击延迟 ~300ms 触发；偶发吞双击的体感需真机确认 | `library_page.dart:2403` 附近 | 【代】 |
| R3 | P2 | 手动顺序键 = `directoryPath`，**目录真迁移 / 标题改名（重命名目录）后手动顺序整体失效**（键全部失配 → 全部 `?? -1` 顶置） | `library_page.dart:1682/:845` | 【核】 |
| R4 | P3 | 管理面板固定偏移 `dx-260`，窄窗口越界 | `library_page.dart:290` | 【代】 |
| R5 | P2 | 批量「模糊」按钮实为切换 `isBlurred`（封面模糊标记），按钮名与 NSFW「模糊」易混淆，且作用于全局勾选（见 §2.3） | `library_page.dart:2587-2596` | 【核】 |

---

## 3. 技术选型

### 3.1 拖拽换位实现路线

| 候选 | 结论 | 理由 |
|------|------|------|
| **A. 修复现有自研拖拽**（选定） | ✅ | 现有实现已具备悬停确认（交换模式 200ms 停留 `:1502-1510`）、插入预览、飞行动画等定制特性；病灶集中在「索引数据源」一处，修复面小且可控 |
| B. `flutter_reorderable_grid_view` 5.7.0 | ❌ | 组件本身优质（160/160 pub points、BSD-3、活跃维护、支持 Windows、Dart ≥3.3 兼容本项目 3.5.3），但：① 无法覆盖上述定制交互；② 替换 = 3643 行文件内大范围改造 + 全套真机回归，违反最小变更；③ 新增依赖需走 pubspec 审批 |
| C. Flutter 内置 `ReorderableListView` | ❌ | 仅支持列表，不支持 GridView 网格语义 |

### 3.2 收藏夹内顺序存储

| 候选 | 结论 | 理由 |
|------|------|------|
| **A. `collections.json` 的 `GameCollection` 增 `game_order` 字段**（选定） | ✅ | 收藏夹元数据本就集中在此；成员关系在 game.json 不动（保持「每游戏目录自包含」哲学）；读取 `?? <String>[]` 零迁移 |
| B. 成员顺序写进各游戏 `game.json` | ❌ | 顺序是「收藏夹维度」属性，分散到 N 个游戏文件既难维护也无法表达「只属于一个收藏夹的排序」 |
| C. 新建独立 JSON 文件 | ❌ | 多一个存储文件与加载时序，收益为零 |

### 3.3 智能组（标签/会社）的成员模型

| 候选 | 结论 | 理由 |
|------|------|------|
| **A. 派生式分组 + 编辑写穿**（选定） | ✅ | 成员永远实时派生自 `tags`/`developer`（单一事实来源，不会出现「分组显示与数据脱节」）；用户增删成员 = 直接改游戏数据的对应字段（加标签/改会社），符合「针对数据本身归纳」的定位；仅显示名/置顶/隐藏等**展示层覆盖项**落盘 |
| B. 快照式分组（把成员列表持久化） | ❌ | 数据一变快照即过期，要么频繁同步要么显示脏数据，与「系统自动归纳」目标相悖 |

### 3.4 卡片 key 策略

| 候选 | 结论 | 理由 |
|------|------|------|
| **A. `Map<游戏键, GlobalKey>`（按身份）+ 网格子项 `ValueKey`**（选定） | ✅ | 根治「同位置 key 绑到不同游戏」的 State 串台；拖拽测距（`_cardKeys[index]` → `:1010`）同步改为按游戏键查表 |
| B. 保持位置型 GlobalKey | ❌ | 筛选/重排后 hover 动画、封面态、拖拽命中（`:1010`）都可能落到错误的卡片上 |

---

## 4. 架构设计

### 4.1 顺序语义层（核心原则：渲染列表 = 操作列表）

```
┌─ 数据层 ──────────────────────────────────────────────┐
│ 全局手动顺序: prefs `_kGameOrderKey`（键 directoryPath）  │ ← 仅「全部游戏」视图拖拽写入
│ 收藏夹内顺序: collections.json `game_order`（Phase 3）   │ ← 仅「收藏夹」视图拖拽写入
│ 智能组成员: 派生自 tags/developer，不落盘                │ ← 不支持拖拽
└──────────────────────────────────────────────────────┘
              ↓ 组装（_computeFilteredAndSortedGames 扩展）
┌─ 显示层 ──────────────────────────────────────────────┐
│ _filteredAndSortedGames = 唯一渲染源 = 唯一拖拽操作源     │
│   全部视图 + 手动序 → 全局顺序；收藏夹视图 + 手动序 →     │
│   game_order 优先、缺失者按全局顺序追加在尾              │
└──────────────────────────────────────────────────────┘
```

**拖拽门控矩阵**（重构后）：

| 当前视图 | 手动排序 | 搜索/会社筛选激活 | 拖拽行为 |
|---------|---------|----------------|---------|
| 全部游戏 | ✅ | 否 | 改全局顺序 → `_saveGameOrder()` |
| 全部游戏 | ✅ | **是** | **禁用**（长按无响应；首次提示 SnackBar「筛选状态下不可调整顺序」） |
| 收藏夹 | ✅ | 否 | 改收藏夹内 `game_order`（Phase 3 前：同搜索一样禁用） |
| 任意 | 非手动 | — | 禁用（现状一致，`:2412` 门控保留） |

**实现要点**：`_endDrag`（`:1512-1544`）改为对 `_filteredAndSortedGames`（渲染列表）生成新顺序，再按上表路由持久化。索引错配由构造上消除——不再存在「A 列表取索引、B 列表套用」。

### 4.2 管理模式状态机

```
进入管理模式（底栏滑入，0 勾选：全选/取消可用、批量钮禁用+置灰）
  ├─ 勾选 ≥1 → 批量钮启用，底栏显示「已选 N / 本页 M」
  ├─ 切换收藏夹 / 搜索词变化 / 会社筛选变化 → 清空勾选集（防跨视图残留）
  ├─ 全选 = 当前可见（现状保留 :271）
  └─ 退出管理模式 → 清空勾选 + 底栏滑出
```

### 4.3 智能归纳板块（v1：标签 + 会社）

```
派生（每次注册表 structural 通知后重算，memo 化）:
  tag 组  = game.tags 每个非空值 → 组键 "tag:<值>"
  dev 组  = game.developer 非空 → 组键 "dev:<值>"；空值聚合为「未填会社」组
展示覆盖（持久化 data/smart_groups.json）:
  { "<组键>": { "displayName": "覆盖显示名(可空)", "hidden": false, "pinned": false } }
编辑写穿（组视图内）:
  对游戏加/移除标签  → 写 LibraryGame.tags（走既有保存链路，自动触发通知刷新）
  会社改组/清空会社  → 写 LibraryGame.developer
```

- 入口：收藏夹侧边栏（`collection_sidebar.dart`）下方新增「智能归纳」分区，组条目带成员计数徽章；置顶组在上、隐藏组不显示（可在管理入口恢复）。
- 组视图：复用库页网格（新增 `_activeSmartGroupKey` 状态，与 `_activeCollectionId` 互斥），筛选谓词 = 组键匹配；顶部显示组名与计数；排序选项照常生效（手动序时按全局顺序）。
- 降级策略：`smart_groups.json` 读取失败 → 全部按默认展示（等同无覆盖项），不影响库正常运行。

---

## 5. 数据模型变更

| 变更 | 位置 | 迁移 |
|------|------|------|
| `GameCollection` 增 `List<String> gameOrder`（JSON 键 `game_order`，元素为游戏 `directoryPath`） | `collection_service.dart`（`fromJson :69-79` 加 `?? <String>[]` 读取；`toJson` 加写出） | **无**（缺字段读默认值，不升 `format_version`） |
| 新文件 `data/smart_groups.json`（展示覆盖项） | 新增 `lib/services/library_smart_group_service.dart` | **无**（首启无文件 = 全默认） |
| `LibraryGame.installedAt`：原地更新分支**不再覆写** | `local_game_registry.dart:796`（删除该行；`:820` 新建分支保留） | **无**（字段不变，仅写入时机收紧） |
| prefs 手动顺序键与格式不变 | `library_page.dart:1680` | **无** |

---

## 6. 性能预算

| 项 | 预算 | 说明 |
|----|------|------|
| 智能组派生（500 游戏 × 均 15 标签） | < 5 ms | O(n·t) Set 归并，仅注册表 structural 通知后重算 + memo |
| `game_order` 查表 | < 1 ms | 进入收藏夹视图时预构建 `Map<String,int>`，O(n) |
| 拖拽重排 | 0 新增逐帧成本 | 沿用现有 `_cachedCardRects` 缓存机制 |
| 底栏常驻 | < 2 ms/帧（过渡期） | AnimatedSize/Slide 一次性布局；静止零成本 |
| key 方案切换 | 无预算变化 | Map 查表 O(1)，网格构建路径不变 |
| 总体 | 不引入 isolate | 数据量级（数百游戏）全部主 isolate 内可完成 |

---

## 7. 实施阶段划分（每阶段一个 commit，独立可回滚）

### Phase 0 · 技术验证（先证伪再落地）
- T0-1 `collection_service` 单测：`game_order` 往返序列化 + 老数据缺字段读取默认值 + 与 pinned 规整共存不互踩。
- T0-2 顺序纯函数单测：抽出 `reorderDisplayList(list, from, to)`（插入模式含索引收缩语义，对齐 `:1528-1536`）+ 属性测试「收藏夹/筛选视图下的重排结果不改变全局顺序列表」。
- T0-3 key 身份化冒烟：网格在「筛选前后切换」场景无 Duplicate GlobalKey 异常（widget 测试；若现有测试基建不便起 widget 泵，降级为逻辑层单测 + 真机走查项，如实记录）。

### Phase 1 · P0 位置稳定性修复
1. `local_game_registry.dart:796`：删除原地更新对 `installedAt` 的覆写。
2. `library_page.dart:220-222`：「最近游玩」改按 `lastOpenedAt` 降序（空串沉底）。
3. `library_page.dart:844-848`：`?? -1` 顶置语义**保留**（用户拍板），但新游之间加次级键 `installedAt` 降序，保证多个新游相对次序确定。
4. 🔴 拖拽安全化（第一步只堵不扩）：门控（`:2412/:2422/:2434`）增加「搜索激活 || 会社筛选激活 || 收藏夹视图 → 禁拖」；`_endDrag`（`:1512-1544`）改为操作渲染列表——本阶段仅「全部游戏 + 无筛选」可达拖拽，索引错配在构造上消失。
5. `didUpdateWidget` 加变更守卫（【代】`:888-893`，避免父每次重建全量重扫）。

### Phase 2 · 管理模式语义
1. `:1978` 底栏条件改为 `_isEditMode`；`_editBarBtn`（`:2615`）加 `enabled` 参数；0 勾选时「模糊/删除/快捷方式」禁用置灰，「全选/取消」可用。
2. 勾选集随视图切换清空：接入点 = `_enterCollection`、搜索词变更、会社筛选变更（【代】`:608` 等，执行时定位）。
3. 底栏文案改「已选 N / 本页 M」。

### Phase 3 · 收藏夹内独立排序
1. `GameCollection.gameOrder` + `CollectionService.moveGameInCollection(id, path, newIndex)` / `resetCollectionOrder(id)`（写入走 `_save()`，与 ADR-003 规整共存）。
2. `_computeFilteredAndSortedGames`：收藏夹视图 + 手动序 → `game_order` 优先、未登记者按全局顺序追加尾部。
3. 收藏夹视图拖拽解禁 → 写 `game_order`（不再触碰全局顺序）。
4. 收藏夹管理入口加「重置排序」（删除 `game_order`，回到全局序）。

### Phase 4 · 卡片 key 身份化
`_cardKeys`（`List<GlobalKey>` + `_syncCardKeys :877-885`）→ `Map<String, GlobalKey>`（键 `directoryPath`）；网格子项（`:2376`）加 `ValueKey<String>(game.directoryPath)`；拖拽测距（`:1010`）改按游戏键查表。

### Phase 5 · 智能归纳板块 v1（标签 + 会社）
1. 新增 `lib/services/library_smart_group_service.dart`（派生 + 覆盖项持久化 + 写穿 API）。
2. `collection_sidebar.dart` 新增「智能归纳」分区（计数徽章/置顶分组/管理入口）。
3. 库页组视图（`_activeSmartGroupKey`，与收藏夹互斥）+ 组内右键「添加标签/移除标签/将会社改为…/清空会社」（写穿）。
4. 组覆盖编辑：重命名/置顶/隐藏。

### Phase 6 · 收尾
档案更新、DEV_LOG、全量测试基线核对、真机走查清单（§11）执行。

---

## 8. 改动文件清单

**修改**
| 文件 | 阶段 | 风险提示 |
|------|------|---------|
| `lib/pages/library_page.dart`（3643 行 🔴 巨型文件） | 1/2/3/4/5 | 只做局部修改，禁整体重写；每阶段 `git diff --stat` 自查 |
| `lib/services/local_game_registry.dart` | 1 | 仅 `:796` 一行级改动 + `didUpdateWidget` 守卫在 library_page 侧 |
| `lib/services/collection_service.dart` | 3 | 新字段 `?? 默认值` 读取，不碰 ADR-003 排序逻辑 |
| `lib/widgets/library/collection_sidebar.dart` | 5 | 新增分区，不动既有收藏夹条目结构 |

**新增**
| 文件 | 阶段 |
|------|------|
| `lib/services/library_smart_group_service.dart` | 5 |
| `test/services/collection_game_order_test.dart` | 0/3 |
| `test/services/library_order_semantics_test.dart` | 0/1 |
| `test/services/library_smart_group_test.dart` | 0/5 |
| 本方案文档 `docs/DEV/features/library_page_experience_overhaul_plan.md` | 0 |

**一期明确不碰**：`lib/main.dart`、`lib/main_container.dart`（R1 仅报告）、`lib/theme/**`、`lib/core/portable_*.dart`、`lib/services/app_state.dart`、`windows/runner/**`、`lib/big_picture/**`、`lib/widgets/game_detail_dialog.dart`、`lib/models/game_model.dart`。

---

## 9. 调用点 / 改动点分批清单

| 批次 | 内容 | 级别 |
|------|------|------|
| 批 A（Phase 1） | `local_game_registry.dart:796` installedAt；`library_page.dart:221` 最近游玩；`:844-848` 次级排序；`:2412/:2422/:2434` 拖拽门控；`:1512-1544` `_endDrag` 重构；`didUpdateWidget` 守卫 | P0 |
| 批 B（Phase 2） | `:1978` 底栏条件；`:2615` `_editBarBtn` enabled；视图切换清空勾选（`_enterCollection` 等入口）；底栏文案 | P1 |
| 批 C（Phase 3） | `collection_service.dart` gameOrder API；`_computeFilteredAndSortedGames`（`:184-239`）收藏夹排序分支；收藏夹拖拽解禁 | P1 |
| 批 D（Phase 4） | `_cardKeys` 全面身份化（`:877-885`/`:1010`/`:2376` 三处 + 其余引用点执行时 grep `_cardKeys` 全列） | P1 |
| 批 E（Phase 5） | 智能组服务 + 侧栏分区 + 组视图 + 写穿菜单 | P1 |
| 报告不改 | R1 keep-alive（稳定区）、R2 单双击（真机确认后另议）、R3 顺序键失稳（§13-Q1）、R4 窄窗越界、R5 模糊按钮命名 | P2/P3 |

---

## 10. 风险登记

| 级别 | 风险 | 应对 |
|------|------|------|
| P0 | `_endDrag` 重构引入新错配（改了操作列表但持久化路由错） | T0-2 属性测试锁死「视图隔离」语义；Phase 1 先禁后放（收藏夹拖拽 Phase 3 才解禁） |
| P0 | 删 `installedAt` 覆写影响导入链路其他消费方（如按 installedAt 的展示） | 只动原地更新分支；`grep installedAt` 全列核对消费点；全量测试守门 |
| P1 | `game_order` 与收藏夹成员变动脱节（移出收藏夹后残留键） | 读取时过滤不存在成员；移出收藏夹时顺带清理键（写穿点） |
| P1 | 底栏常驻后 0 勾选误触批量操作 | 批量钮禁用 + 置灰；`_editBarBtn` 单点改造 |
| P2 | 勾选集清空策略牺牲「跨收藏夹批量操作」场景 | 接受（现 UI 本就无跨视图批量动线）；右键单游戏菜单仍可跨视图操作 |
| P2 | key 身份化遗漏引用点（`_cardKeys` 散布多处） | 执行前 `grep -n "_cardKeys"` 列全所有引用，逐一迁移；T0-3 冒烟 |
| P2 | 智能组写穿误改数据（改会社覆盖原值） | 菜单文案明示「将会社改为 X」；清空需二次确认 |
| P3 | 真机观感（底栏滑入动画、组分区样式） | Phase 6 真机走查统一调 |

---

## 11. 验收标准

### 自动化
- `./flutter/bin/flutter.bat analyze`（仅改动文件）0 新增 error；
- `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test`：全量 ≥519 通过 / 0 新增失败（当前基线 523/3→525/1 的 flaky 签名除外）；
- 新增三个测试文件全绿；`git status --short` 无计划外文件。

### 真机走查清单（Phase 6）
1. 编辑任意游戏数据（改标题/封面/标签）→ 保存后**库内其他卡片位置纹丝不动**，「最近添加」下该游戏不跳顶；
2. 手动排序下导入新游戏 → 顶置最前，多个新游相对次序确定；
3. 「最近游玩」排序 → 按真实最近游玩时间（玩过的在前、从未游玩的沉底）；
4. 全部游戏 + 手动序 → 拖拽换位，重启后保持；
5. 激活搜索或会社筛选 → 长按不触发拖拽（首次有提示）；
6. 收藏夹视图内拖拽 → 只改收藏夹内顺序；退出收藏夹 → 全局顺序与进入前完全一致（P0 回归项）；
7. 进入管理模式 → 底栏立即滑入，0 勾选时批量钮置灰；勾选后启用并显示「已选 N / 本页 M」；
8. 勾选 2 个游戏后切换收藏夹/输入搜索 → 勾选被清空，无隐形勾选残留；
9. 全选 → 恰好选中当前可见数量；
10. 侧栏「智能归纳」分区 → 标签组/会社组与计数正确；点进组视图网格过滤正确；
11. 组内对游戏「添加标签/移除标签/改会社」→ 游戏数据真实变更、组成员与计数即时刷新；
12. 组重命名/置顶/隐藏 → 重启后保持；隐藏的组可在管理入口恢复。

---

## 12. 给执行 AI 的指令摘要

> 直接复制以下内容作为执行会话的开场 prompt：

```
你在 D:\CTLIB（Flutter Windows 项目，必读 AGENTS.md 并遵守两段式流程）。
本次执行「库页体验治理与智能归纳板块」，方案文档：
docs/DEV/features/library_page_experience_overhaul_plan.md —— 全文读完再动手，
严格按 §7 阶段顺序逐 Phase 执行，每个 Phase 一个 commit。
铁律：
1. library_page.dart 是 3643 行高危文件，只做局部修改；动手前先 grep 核实文档所引行号
   （标注【代】的行号未经亲核，必须先复核再改）。
2. 每阶段收尾：analyze 只跑改动文件（0 新增 error）+ 跑相关测试 + 全量测试
   （必须加 env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy 前缀，
   基线 519+/0 不允许新增失败）+ git status 自查越界 + 更新 DEV_LOG/HANDOFF/本档案。
3. §8「一期明确不碰」清单内文件一行都不许动；§9「报告不改」项只报告。
4. 计划外改动 = 立即停下报告，等用户确认。
5. 新字段读取一律 ?? 默认值，不升 format_version。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 背景 | 建议 |
|---|------|------|------|
| Q1 | 是否引入**稳定 gameId**（UUID）替代 `directoryPath` 作为手动顺序键？ | 手动顺序键在「目录真迁移」「标题改名重命名目录」后全部失配 → 手动顺序整体失效（R3，【核】）。真迁移功能已上线，踩中概率真实存在。引入 UUID 需动 game.json schema | 建议单独立项（本方案先用现状键把语义修对，换键只是存储替换） |
| Q2 | 智能归纳中「未填会社」组是否默认显示？ | 空会社游戏会聚合为一组 | 建议默认显示，用户可隐藏（隐藏状态持久化） |
| Q3 | 智能组视图内是否需要组内拖拽排序？ | v1 设计为不支持（成员是派生的，排序无持久层） | v1 不做；若要，等 Q1 稳定键落地后按收藏夹模式扩展 |
| Q4 | R1（库页切页丢滚动位置/状态，需动稳定区 `main_container.dart`）是否立项？ | 库页无 keep-alive，每次切页重建 | 建议 BPM 保活机制（Stack+Offstage）验证成熟后再照搬，单独立项 |

## 库页顶部栏按钮鼠标引导 Tooltip（2026-10-10，需求 5）

**用户口径**：库页顶部栏按钮没有引导，需**鼠标停留显示对应按钮名称**（如侧边栏那样）。

**实现**：`library_page.dart` 新增私有帮助方法 `_topBarTip(message, child,
{selected, semanticButton})` —— 与侧边栏 UX-25（`sidebar.dart` `_buildNavItemExpanded`）
逐位同款：`Tooltip(waitDuration: 400ms)` + `Semantics(button: true, selected, label)`
（hover 显示名称 + 屏幕阅读器播报）。`semanticButton: false` 用于文本框这类
**不该被标成 button** 的宿主。

| 位置 | 引导文案 | 备注 |
|---|---|---|
| 搜索框 | `搜索游戏（名称 / 会社 / 标签）` | 输入框，`semanticButton: false` |
| 搜索框清空（×） | `清空搜索` | 仅输入框有内容时存在 |
| 管理按钮 | `管理` / `退出管理` | 随编辑模式动态变化，`selected: _isEditMode` |
| 筛选面板按钮 | `筛选` | 仅编辑模式存在，`selected: _managementPanel != null` |
| 收藏夹按钮 | `收藏夹` | `selected: _collectionSidebarOpen` |

- 底部编辑模式操作栏（全选 / 取消 / 模糊 / 删除 / 快捷方式）已带**可见文字标签**，
  不属于「无引导的图标按钮」，本次未加 Tooltip。
- 面包屑 chips 同样带可见文字，未改。

**验证**：进程内分析器 1 文件 **0 error**（3 warning + 1 info 均为存量：`path` 未用导入、
`_layoutPresets` 未用字段、`_buildPlaceholderCover` 未被引用、`showHighlight` 未用局部变量）。
离线 widget 探针 `.workbuddy/probe_library_tips/`（flutter_tester **真实渲染 LibraryPage**）
**9 PASS / 0 FAIL**：
S1 默认态 tooltips = `[搜索游戏（名称 / 会社 / 标签）, 管理, 收藏夹]`；
S2 点管理进编辑态 → `[..., 筛选, 退出管理, 收藏夹]`（文案动态切换生效）；
S3 搜索框输入内容 → 追加 `清空搜索`。整页渲染过程无 unexpected exception。
⏳ 未真机走查（hover 悬停 400ms 弹出、深浅主题下气泡样式）。
