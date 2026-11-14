# 系列整理规范重构 — 研究报告与方案（Phase A 只读审计）

> 日期：2026-10-04　状态：**待批准**
> 范围：云端作品系列/集合的整理机制（模型 + 数据 + 客户端展示）
> 结论：现状问题不在渲染层，而在 **数据模型把「归属 / 结构 / 语义」三种职责压在一张表里** + **录入无规范导致语义漂移**。建议按 P0→P3 分层重构，推荐落地方案 B（地位与关系分离）。

---

## 1. 现状机制盘点

| 层 | 文件 | 现状 |
|---|---|---|
| 数据模型 | `lib/models/series_model.dart` | `series`（容器：title/description/cover/mode）+ `series_entries`（条目：game + **单亲树 parent** + relationType 9 种 + sortOrder）；`game` 字段 UNIQUE（一作最多属一个系列，`series_repository.dart:8-9` 注释证实） |
| 数据访问 | `lib/repositories/series_repository.dart` | 两步查询 + 10min TTL 缓存；失败静默 |
| 详情页展示 | `lib/widgets/series_strip.dart` / `lib/widgets/series_panel.dart` | 主线编号 ①②③ + 分支缩进挂靠 + 角标（本篇/续作N/关系标签） |
| 大厅板块 | `lib/widgets/explore_hall/series_section.dart` | 系列封面横滑 → 成员弹层按 `displayOrder` 平铺 |
| 录入端 | PB 管理后台手工 | **无任何录入规范文档** |

## 2. 线上数据审计（2026-10-04 实拉全量）

总量：**43 系列 / 173 条目**。逐系列树结构校验 + 条目级抽查（探针：`dev_probe/series_audit*.py`）。

### 2.1 结构性错误（模型语义被录入数据踩爆）

| # | 问题 | 证据 | 客户端实际表现 |
|---|---|---|---|
| 1 | 正统编号续作被标 `standalone` 独立根 | 甜蜜女友系列：2/3/SS 三个 `standalone` 根 | `hasParallelMainlines` 触发（`series_model.dart:177`），面板提示「**各条线互相独立，可任选一条开始**」（`series_panel.dart:184-185`）——游玩顺序建议**直接错误** |
| 2 | 无关 crossover 标 `main` 第二根 | 兰斯系列：夏娃年代记兰斯版 = 第二个 `main` 根 | 同上，渲染成平行主线 |
| 3 | 根节点 relationType 三种混杂 | 全局根分布：main ×42、standalone ×29、side_story ×2 | 「地位」语义混进「关系」字段，录入者只能靠猜 |
| 4 | mode 未填 | 命运石之门系列、恋姬†系列 mode 为空 | 兜底按 tree 渲染，行为侥幸正确但属隐患 |
| 5 | 元数据缺失 | 43/43 系列**全部无 description**；封面 0 缺失 | 面板头部无简介可显示 |
| 6 | collection 模式被滥用 | 罚抄（Rewrite + FD Harvest festa + Rewrite+ 增强版）、年上系列（年上彼女 1/2 正统续作）、Vens系列（VenusBlood 正统续作）均为**正统作品群**却标了 collection | 正统续作被渲染成"相互独立、无先后依赖"——与问题 1 同性质，只是方向相反 |

### 2.2 结构健康但暴露模型天花板

- **一作只能属一个系列**（UNIQUE 索引）：命运石之门无法同时进「命运石之门系列」和「科学ADV世界观系列」；九宫格合集与其成员的各自正统系列互斥。
- **单亲树表达不了多关系**：一部 FD 可能同时是本篇和重制版的 FD；`parent` 只有一个。
- `mainlineLabel`（`series_model.dart:240-241`）的「本篇/续作一/续作二」链内编号与真实作品编号脱节（用户看到的「续作一」实际叫「0」）。

### 2.3 没问题的部分（避免误伤）

- 43 系列无空系列、无悬空 parent、无环、无 game 悬空、无一部多属——树防御逻辑（`series_model.dart:279-376`）工作正常。
- 「无主线链」的 9 个系列（AIR/借恋/星之梦等）实际是「main 根 + 分支」的健康结构，不是错误。
- collection 模式 5 个（十二神器/九宫格等）渲染正确。

## 3. 根因诊断

1. **一张表三种职责**：`series_entries` 同时承担归属（game↔series）、结构（parent 树）、语义（relationType）。
2. **relationType 语义混载**：`main`/`standalone` 是「地位」，`sequel`/`fan_disc` 是「关系」，混在一个字段 → 根节点语义被迫发明「standalone=平行系列根」这种黑话（`series_model.dart:5-7` 注释自己都在解释这个 workaround）。
3. **录入无规范**：9 种关系、mode、根节点规则全凭录入者理解，无判定标准 → 问题 2.1 全部由此产生。
4. **游玩顺序靠手工 sortOrder**：无发售日期兜底、无校验，错排不可发现（命运石之门 main 根 sortOrder=2）。

## 4. 业界参照

**VNDB**（社区事实标准，本项目 `luna_metadata_sdk` 已有 VNDB 数据通道）：
- 关系是**作品↔作品的有向边**，不是树；每种关系有定义好的逆关系（sequel↔prequel、fan_disc↔original、side_story↔parent_story），录一边自动生成另一边。
- 词表：Sequel / Prequel / Same setting（同世界观不同角色）/ Alternative setting（同角色不同世界线）/ Alternative version（重制）/ Side story / Parent story / Fandisc / Original / Same series / Shares characters / Summary / Other。
- 关键纪律：**只录直接关系**（A→B→C 不录 A→C）；不确定时选最接近的一项，而不是发明新语义。
- 「同一系列」是关系图的**推导视图**，不是手工维护的成员表。

**对我们的启示**：VNDB 的图模型是最强表达，但它的 UI（关系图）对「定位作品地位 / 游玩顺序」反而不直观。我们要的不是照搬 VNDB，而是 **图的数据模型 + 我们现有的「编号主轴 + 挂靠分支」展示**——两者正好互补。

### 4.1 VNDB 实测（2026-10-04，探针 `dev_probe/vndb_probe.py`）

| 实验 | 结果 | 结论 |
|---|---|---|
| 拉取 STEINS;GATE 关系 | **16 条有向边**：Fandisc ×3（官方）、side ×4、alt 重制 ×1、set（同一系列）×2（CHAOS;HEAD NOAH / ROBOTICS;NOTES，官方）、char ×2、每条带 `official` 官方标记 | 图模型成熟；**科学ADV世界观系可以直接由 `set` 边自动推出**——命运石之门、混沌之头、机器人笔记会自动聚成一个世界观系列 |
| 搜索「十二神器」「九宫格」 | **0 条结果** | VNDB 根本不存在社区合集概念 |
| euphoria（神器成员）关系数 | **0 条** | 十二神器成员在关系图中互不可见——社区梗合集在 VNDB 数据里天然不存在 |
| 中文标题搜索（重生萝莉岛/媚肉之香/魔女恋爱日记/杀恋） | 0 条，但按罗马音/日文标题**全部命中**（Okinawa Slave Island / Biniku no Kaori / Majo Koi Nikki / Satsukoi） | 作品覆盖度本身没问题（43k+ VNs，主流+冷门都有），**瓶颈在匹配策略：不能拿中文名去搜，必须依赖导入时落库的 vndb_id 或日文原题匹配** |

**判定**：VNDB 能自动化的 = 正统系列（seq/fan/alt/side/orig 边）+ 世界观系列（set 边）；**永远不能自动化的 = 十二神器/九宫格这类社区梗合集**——它们不存在于任何数据库，只能人工维护。这正是方案 B 里 `kind` 三分法的价值所在。

## 5. 方案对比

| 方案 | 内容 | 优点 | 代价 | 判断 |
|---|---|---|---|---|
| A：只修数据 + 写规范 | 修 2.1 全部数据错误；写《系列录入规范》；不动结构 | 零代码风险，1 次任务可完成 | 树模型天花板仍在：多归属、多关系永远做不了 | 不够，用户已明确要系统重构 |
| **B：地位与关系分离（推荐）** | 拆三张表（见 §6）；多归属；VNDB 词表；客户端按能力探测新旧双兼容 | 表达力对齐业界；渲染层 UX 保留；43 系列迁移成本极低 | PB 加集合 + 迁移脚本 + 客户端 `SeriesData.build` v2 | ✅ 推荐 |
| C：VNDB 全库关系图 | 所有作品级 relations 边 + 图渲染 | 最强表达 | 录入成本高、客户端大改、图 UI 对非硬核用户不友好 | 不做；其数据可作为 B 的自动化来源（P3） |

## 6. 方案 B 详细设计

### 6.1 数据层（PB，三个集合）

```
series（容器）                      ——改造现有
  ├─ title / description / coverUrl（description 必填，进录入规范）
  ├─ kind: story_line(正典故事线) / worldview(世界观系列) / anthology(主题合集)
  │         （替代现 mode；anthology ≈ 现 collection，平铺渲染）
  └─ playOrderPolicy: manual / release_date

series_members（归属层，多对多）     ——替代 series_entries 的归属职责
  ├─ series / game        （⛔ 去掉 game UNIQUE → 一作可属多个系列）
  ├─ role: main_axis(主轴) / branch(支线) / extra(收录)   ←「地位」在这里
  ├─ playOrder: int        ←主轴内推荐游玩顺序（manual 时）
  └─ releaseDate: 快照     ←release_date 模式或 playOrder 缺失时的兜底排序

game_relations（语义层，有向边）     ——替代 series_entries 的关系职责
  ├─ from / to / relation  ←VNDB 词表（sequel/prequel/fan_disc/…）
  ├─ official: bool
  └─ note: string
```

核心原则：**地位（role + playOrder）回答「我在集合里排第几」；关系（relation 边）回答「我和谁、是什么关系」**。二者彻底解耦，`standalone` 根这种 workaround 不复存在。

### 6.2 客户端（改动集中在数据构建，渲染层基本保留）

- `SeriesData.build` v2：主轴 = members(role=main_axis) 按 playOrder 排序；分支挂靠 = relation 边推断锚点（fan_disc/remake/side_story 的 from 指向谁就挂谁）；`kind=anthology` 平铺。
- 渲染组件 `series_panel.dart` / `series_strip.dart` / `series_section.dart` 的「编号主轴 + 缩进分支 + 角标」结构**保留**，只换数据来源与角标词。
- 「平行主线」提示仅在 kind=story_line 且数据上确有多主轴时出现（由 role 保证语义正确）。
- 兼容策略：客户端启动探测 `series_members` 是否存在 → 有走 v2，无回退 v1 树。**零破坏迁移**。

### 6.3 迁移

- 脚本：读现有 173 条 series_entries → parent 链展开为 members.playOrder（链内序号）+ parent→child 边转 game_relations(relation=child 的 relationType)。43 系列量小，一次性跑完。
- PB 规则沿用匿名只读（`listRule=''`），写规则仅管理端。

## 7. 自动化目标（2026-10-04 用户新增，定为项目目标）

> 目标一句话：**正统系列与世界观系列全自动生成（人工只做确认），社区合集保持人工；系列整理从"纯手工录入"升级为"机器提案 + 人工确认"。**

### 7.1 自动化边界（按 kind 硬性划分）

| kind | 自动化程度 | 数据源 |
|---|---|---|
| story_line 正统故事线 | **全自动**：VNDB seq/fan/alt/side/orig 官方边 → 连通分量 + 主线链推导 | VNDB relations（official=true 优先） |
| worldview 世界观系列 | **全自动**：VNDB `set`（Same series）边聚类（科学ADV 实测可行，见 §4.1） | VNDB relations |
| anthology 社区/主题合集 | **纯人工**（十二神器/九宫格在 VNDB 中不存在，实测 0 结果） | 人工录入 + 录入规范 |

### 7.2 自动化管道（P3 展开）

```
① vndb_id 匹配层：云端游戏记录补齐 vndb_id
   （导入时由 luna_metadata_sdk 落库；存量作品批量跑日文原题/罗马音匹配——
    ⚠️ 实测中文名搜不到，禁止拿中文名直接匹配，歧义人工裁决）
        ↓
② 关系拉取层：按 vndb_id 批量拉 VNDB relations（Kana API，免费无鉴权，注意速率限制）
        ↓
③ 推导层（纯函数，可测试）：
   - 官方边图 → 连通分量（同故事线聚类）
   - 分量内沿 official seq 边推导主线 playOrder；
     fan/alt/side 按指向锚定 branch 角色
   - set 边聚类 → worldview 候选系列
        ↓
④ 确认队列层：候选系列/关系进入"待确认"状态（新增 status 字段：candidate / confirmed）
   → 管理端逐个人工过目（改动仅是点确认，不再手工建树）
        ↓
⑤ 入库：confirmed 数据写入 series_members / game_relations，客户端正常消费
```

- 现有 43 系列同样走一遍确认队列：机器提案 vs 人工现状逐条 diff，差异点就是 §2.1 那些错误，一次清理到位。
- VNDB 数据更新（出新作）后重跑 ②③，增量出现在确认队列——系列整理从此**可持续**，不依赖某次性的大整理。

### 7.3 分级路线（更新版）

| 级别 | 内容 | 依赖 |
|---|---|---|
| **P0 数据急救** | 修 §2.1 的 6 类数据错误（新增：罚抄/年上/Vens 三个 collection 误标 → 改 story_line）；客户端小修：「平行主线」提示加守卫（≥2 条链且每链 ≥2 部主线作品才显示） | 无，可立即做 |
| **P1 录入规范** | 《系列整理规范》文档：kind 判定树、relation 词表对照（VNDB 中文译名）、根节点/主轴规则、游玩顺序原则、「只录直接关系」纪律；**合集类（anthology）保留人工录入通道** | 无 |
| **P2 模型 v2** | §6 三表 + 迁移脚本 + 客户端 build v2 + 能力探测；**表结构按自动化优先设计**（members/game_relations 从第一天起就是机器可写形状，含 status 字段） | P0 完成；需批准 |
| **P3 自动化管道** | §7.2 五层管道；管理端确认队列 UI；VNDB 增量更新接入 | P2 |

## 8. 待批准事项

1. 方案选择：是否按 **B** 执行？
2. P0 数据急救 + P1 规范文档是否先行（两者不依赖 PB 结构变更，可与 P2 拆开批准）？
3. 「平行主线」提示守卫的小代码改动（`series_panel.dart:184` 一处条件）是否随 P0 一起做？
4. **自动化目标已按用户要求写入 §7**（正统+世界观自动生成、合集人工、机器提案+人工确认）——确认此边界划分是否符合预期？

—— 批准后按批准范围进入阶段 B。


## 9. 前端落地：定位系统前端化 + 展示 UI 重构（2026-10-05，已实施）

用户批准的《变更计划》四项全部落地：

| # | 要求 | 实现 |
|---|---|---|
| 1 | 定位系统前端化 | `SeriesEntryModel` 增 `v2Role`/`v2Relation`/`releaseDate`；`v2RelationLabel` 十二值词表→中文（seq 正统治作 / preq 前传 / fan FD / orig 原作 / alt 重制版 / altsetting 衍生世界线 / side 外传 / par 本篇 / set 同世界观 / same 同系列 / char 共通角色 / ot 其他）；`preciseLabel` v2 优先回落旧枚举；仓库层 `v2RecordsToSeriesData` 透传 role/原始边/发售日期（member 优先回落 game）。旧表路径零影响（新字段默认 ''） |
| 2 | 详情页系列卡重构 | 新组件 `lib/widgets/explore_hall/series_game_card.dart`：大厅 `_SeriesChip` 同款「全幅封面 + 底部渐变信息栏（作品名+发售日期）+ 左上定位胶囊」；当前作品强调描边 + 右上「当前」 |
| 3 | 相关作品收紧 | `SeriesData.relatedSelection`（纯函数）：紧邻前作 1 → 焦点 → 紧邻续作 1 → 焦点直接分支，合计 <3 按「先后续再前作」补足；collection 平铺全量无角标。UI 条目数再按宽度自适应 2–6 |
| 4 | 全部系列面板升级 | `_SeriesMembersDialog` 删除 → 复用详情页 `SeriesPanel`（currentGameId='' 无当前作品模式），面板内点作品经 `onOpenGame` 走 main_container 详情页通道；`SeriesPanel` 本体升级：640 宽、节点卡 52×74 封面+发售日期+精确定位徽章、合集模式 Wrap 卡片网格、头部显示 description |

🔴 探针抓真 bug：分支作品的相关选取曾丢失主线锚点（currentInChain=false 分支跳过焦点节点）——锚点是分支作品最相关作品，修为恒加。

验证：离线探针 61/61（.workbuddy/probe_series_v2/）；进程内 analyzer 7 文件 0 error。
flutter analyze/test 被 231 拦（C 盘 1.2G）。⏳ 真机走查：详情页系列框 / 详情页完整面板 / 大厅全部系列点入。

### 离线探针运行配方（本次实测修正）

```
dartaotruntime.exe <flutter>/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot \
  --sdk-root <flutter>/bin/cache/artifacts/engine/common/flutter_patched_sdk \
  --target=flutter --enable-asserts --packages=.dart_tool/package_config.json \
  --output-dill=out.dill probe.dart
flutter_tester.exe out.dill
```

⚠️ `--sdk-root` 必须指向 `flutter_patched_sdk`（dart-sdk/ 下没有 platform_strong.dill，实测会编译失败）。
