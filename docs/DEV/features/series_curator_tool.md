# 系列整理工具（series_curator）

> 日期：2026-10-04　状态：**v1.1 可用**（用户实测反馈后修复 4 个写入路径 bug + 交互引导完善）
> 位置：`dev_tools/series_curator/`（完全独立，不 import 主项目代码，主项目零改动）

## 定位（用户决策）

- 系列整理的**自动化与人工编辑全部外置**到本工具，主软件保持纯读取云端，
  不引入任何自动化逻辑（体积零压力）。
- 云端 v2 数据结构重建（地位/关系分离），旧的 `series`/`series_entries` 原样保留，
  主软件切换数据源前不受任何影响——零破坏。

## 架构

- `curator.py`：Python 标准库 HTTP 服务（127.0.0.1:8092，零依赖）+
  PB REST 客户端（超管写入）+ VNDB Kana 客户端（礼貌限速 0.35s）+ 推导/迁移纯函数。
- `web/`：单页前端（vanilla JS），四个工作区：旧数据浏览 / v2 编辑器 / VNDB 自动整理 / 设置。
- `start_curator.bat`：双击启动，自动开浏览器。
- 凭据存 `curator_config.local.json`（已 gitignore，不入库）。

## 云端 v2 三表（init 按需创建，匿名只读、仅超管可写）

| 表 | 字段要点 |
|---|---|
| `series_meta` | title(UNIQUE)/description/coverUrl/kind(story_line,worldview,anthology)/status(draft,confirmed)/note |
| `series_members` | series→meta / game→games / role(main_axis,branch,extra) / playOrder / vndbId / releaseDate；(series,game) UNIQUE |
| `series_relations` | series / fromGame / toGame / relation(seq,preq,fan,orig,alt,altsetting,side,par,set,same,char,ot) / official / note |

核心原则：**地位（role+playOrder）回答"排第几"；关系（边）回答"和谁是什
么关系"**，彻底解耦旧模型的语义混载（standalone 根等 workaround 消失）。

## 自动化边界（2026-10-04 与用户确认）

- story_line / worldview：VNDB 官方边自动推导提案 → 人工确认入库。
  - 🔴 主轴只收**官方** seq/preq 边（实测 v2002 有非官方 seq 同人错标，会污染主轴）。
  - 🔴 VNDB 的"关系"≠"游玩顺序"：S;G0 在 VNDB 是官方 side 而非 seq——
    推导提案后必须在编辑器里人工定地位。
- anthology（十二神器/九宫格类社区梗合集）：VNDB 不存在（实测 0 结果），纯人工。
- 匹配：云端 games 无 vndbId 字段 → 首次人工点选匹配（工具内搜索/弹窗），
  vndbId 记入成员，增量更新免重复匹配。中文名在 VNDB 搜不到，用日文原题/罗马音。

## 实测记录（2026-10-04）

- 43 旧系列整表读取 ✓；games 中文搜索 ✓；VNDB 搜索/关系/推导 ✓（v2002 全链路）。
- 迁移换算：命运石之门系列 → main_axis ①本篇 ②0 + 分支正确锚定 ✓。
- 🔴 踩坑：PB 空关系字段返回 `''` 非 null → 迁移根判定必须 `e.get('parent') or None`。

## v1.1（用户实测反馈修复，2026-10-04）

用户首次实操后反馈「迁移后不知道干什么」+ 界面只看到手动编辑 → 排查发现
写入路径 4 个真实 bug（首次凭据实测才暴露）：

| # | Bug | 根因 | 修复 |
|---|---|---|---|
| 1 | 服务重启后写入全 502 | token 只在 /api/config 时获取，重启即丢 | `ensure_admin()`：已存凭据时每请求静默重登 |
| 2 | 二次保存 series_meta 404 | PB 更新是 **PATCH**，代码发 POST | `PB.update` → method='PATCH' |
| 3 | 旧成员/关系从未删除（关系边累积 15） | PB 删除是 **DELETE**，代码发 POST 且结果被忽略 | `PB.delete` → method='DELETE'；保存=全量替换语义恢复 |
| 4 | app.js 残留 3 处 `.` 写成 `/`（`r.self/vndbId` 等） | 首轮批量替换漏网 | 全部修正（node --check + grep 双验证） |

交互完善（v1.1）：
- **迁移 = 自动换算 + 自动存云端草稿**（原版只进内存，切走即丢——用户困惑的根源）。
- 迁移现在**自动生成关系边**：主轴链 → seq 边；分支按旧 relationType 词表映射
  （LEGACY_REL_MAP）→ 锚点边；standalone/other 不生成。
- 重复迁移同一系列幂等：按 title 查找覆盖，不再撞 UNIQUE 报错。
- 编辑器空态放三步使用说明；标签加步骤编号；「迁移」按钮旁写明会发生什么；
  按钮改名「保存草稿」/「✓ 核对无误，发布」；分支成员行显示锚点与旧关系提示。
- 回归实测：命运石之门系列迁移→保存×2 幂等（同 id）→ 云端 6 成员(主轴2)/5 关系边 ✓。


## v1.2 未收录雷达（2026-10-04）

- 编辑器侧栏新增「未收录雷达」：一键列出云端 games 中**还没进任何 v2 系列**的作品
  （GET /api/v2/unassigned = games 全集 − series_members 已归属集）。
- 用途：新作品上架后的发现机制——探索库来了新游戏，点雷达即可看到它还无家可归，
  再用 VNDB 自动整理或编辑器手动归入系列。实测当前 294 部未收录（v2 仅命运石之门 6 部）。
- 工作流语义定稿：**整理是快照不是订阅**——迁移/推导产生的是当下草稿，云端新作品
  不会自动进系列，必须经雷达发现 → 推导/手动 → 人工确认发布。

## v1.3 系列封面自动补全（2026-10-04）

- 背景：系列封面图难收集 → 采纳用户方案：**用系列第一个游戏的封面当系列封面**。
- 规则：第一个游戏 = main_axis 中 playOrder 最小者（无 main_axis 时取全体成员中最小）；
  封面取该游戏 `coverUrl`/`cover` 字段 → `{PB}/api/files/games/{id}/{文件名}`。
- 入口：⚙ 设置页「系列封面自动补全」卡片——「一键补全封面」（只填空缺，默认）/
  「覆盖全部」（danger，需确认）→ POST /api/v2/autocover `{override}`。
- 全量实跑（2026-10-04）：**43 系列全部填充 ✓**（0 已有封面被跳过=原本全空、0 失败）。
  抽查 3 个 URL 匿名 GET 全 200（含 1 个特殊长文件名）；云端 series_meta.coverUrl 落库复核 ✓。
- 客户端零改动：series_section.dart:153/390 的 HallCoverImage(networkUrl:) 直接吃全 URL。
- 语义注意：coverUrl 存的是**生成时的游戏封面引用**，源游戏日后删图/换图不会联动
  （快照语义，与「整理是快照不是订阅」一致）；需要时对单个系列手动修正后「覆盖全部」重跑。


## 后续（待定）

- 主软件切换到 v2 数据源（客户端 `SeriesData.build` v2 + 能力探测，见
  `series_curation_rebuild_plan.md` §6.2/§7）。
- worldview（set 边）聚类一键建系（科学ADV 实测可聚）。
- VNDB 增量重跑：比对成员 vndbId 关系变化 → 出差异清单。
