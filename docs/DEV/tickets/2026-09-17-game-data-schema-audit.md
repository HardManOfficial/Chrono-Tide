# 游戏数据结构审查报告（2026-09-17）

> 类型：**只读审计**（未改动任何业务代码）
> 范围：`GameJsonData` / `LibraryGame` / `LocalGameRegistry` / `GameDataFormat` /
> `CollectionService` / `SmartGroupService` / `GameConfigManager` / `NsfwDetectionStore` /
> `GameModel`(PB) / `Game`(SDK) / `DiscoverGameMetadata`
> 方法：静态走查 + grep 调用点统计（83 处 `getGameByTitle` / 65 处 `allGames`）
> ⚠️ 本文中的性能数字均为**估算**（未做真机 profile），已逐条标注。

---

## 0. 结论先行

整体判断：**存储哲学（每个游戏目录自包含 game.json）是对的，问题出在"关系层"和"索引层"从没被设计过。**

三个结构性缺陷，其余问题大多是它们的派生：

1. **没有稳定主键。** 同一个游戏在系统里有 4 套身份键：内存 `_games` 用**目录名**、
   全局手动序 prefs 与收藏夹 `game_order` 用 **directoryPath**、启动配置用**标题**、
   排重用 **title + path + sourceId**。改标题 / 迁移目录 = 四处手工补丁。
2. **同一事实多处存储且无单一事实源。** 启动 exe 路径存了 3 份、游玩时长存了 3 份
   （`play_time` / `sessions` / `daily_play_log`）、截图存了 2 份。
3. **零索引 + 零版本化。** 全库查询靠 O(n) 遍历与反复全量排序；`format_version`
   恒为 1，schema 变更无承载点，覆盖写入靠一份**白名单常量**保命。

优先级总览：

| 级别 | 条数 | 一句话 |
|------|------|--------|
| P0 | 3 | 会静默丢数据 / 静默读错数据 |
| P1 | 4 | 规模上到 1000~2000 条时的性能与一致性 |
| P2 | 5 | 字段定义、僵尸字段、命名误导 |
| P3 | 2 | 架构级演进方向（不必现在做） |

---

## 0.5 处置状态（2026-09-19 全部批次已执行）

**批 1**（提交 `96b5ccb`）

| 项 | 状态 | 落点 |
|----|------|------|
| P0-3 覆盖写入语义翻转（保留白名单 → 覆盖黑名单） | ✅ 已改 | `game_data_format.dart`（`_overwritableFields` + 合并逻辑） |
| P0-3b `GameJsonData` 补齐 `sessions` / `daily_play_log` / `title_locked` | ✅ 已改 | `game_data_format.dart`（字段 / 构造 / fromJson / toJson） |
| P1-2 `findCoverFile` 支持传入已解析的 `cover_file` | ✅ 已改 | `game_data_format.dart`（签名）、`local_game_registry.dart`（scan 两处传参） |
| P1-3 `incrementDailyPlayCount` 补 90 天裁剪 | ✅ 已改 | `game_data_format.dart` |
| 回归测试 | ✅ 11/11 | `test/services/game_data_overwrite_safety_test.dart`（新增） |

**批 2 / 3 / 4**（本次执行，覆盖剩余全部条目）

| 项 | 状态 | 落点 |
|----|------|------|
| P0-1 稳定主键 `game_id` + 统一 sanitize | ✅ 已改 | 新增 `lib/utils/game_key.dart`；`game_data_format.dart`（生成 / 落盘 / 护栏）；`local_game_registry.dart`（`LibraryGame.gameId` / `_readOrCreateGameId`） |
| P0-1 三张派生索引 | ✅ 已改 | `local_game_registry.dart`（`_byIdIndex` / `_byTitleIndex` / `_byDirPathNormIndex` + `getGameById` / `getGameByDirectoryPath`） |
| P1-1 `getGameByTitle` 去 O(n)（83 处调用点） | ✅ 已改 | `local_game_registry.dart`（查索引，保留 safeName 兼容分支） |
| P1-1 `allGames` 排序缓存（65 处引用） | ✅ 已改 | `local_game_registry.dart`（`_cachedSortedGames`，返回副本） |
| P1-1 BPM 收藏夹计数改一次遍历 | ✅ 已改 | `big_picture_library_page.dart`（侧栏 chips + 管理对话框） |
| P0-2 启动路径收敛为唯一事实源 | ✅ 已改 | `game_launch_service.dart`（A→B→C + 一次性迁移 + 清旧存储）、`library_page.dart`、`game_detail_dialog.dart`、`local_game_registry.dart`（`finalizeGameMove`） |
| P1-4 NSFW 缓存 LRU + 过期 + 按目录清理 | ✅ 已改 | `nsfw_detection_store.dart`（`maxItems=5000` / `maxAge=180d` / `_prune` / `removeUnderDirectory`） |
| P2-1 僵尸字段 | ✅ 已改 | `setCompleted` 标 `@Deprecated`；`GameJsonData.completed` 标注；`GameMark.favorite` 加保留理由；删 `GameDataMigration._migratedFlag` |
| P2-2 `format_version` 版本化迁移链 | ✅ 已改 | `game_data_format.dart`：`currentVersion` 1→3、`_migrations`、`migrateGameJsonMap`、`readGameJson` 读时迁移 + 写回 |
| P2-3 命名误导 | ⚠️ 部分 | `_installedTitles` → `_installedDirNames`（✅）；`coverUrl` **刻意未改名**（232 处引用 + 跨类同名字段，见下方说明）；截图字段加语义注释 |
| P2-4 标题四件套收敛 | ✅ 已改 | v2→v3 迁移把 `metadata_title` 并入 `original_title` 后删键；`writeGameDir` 只写 `original_title`；`toJson` 不再输出 |
| P2-5 `installedAt` 排序口径 | ✅ 已改 | `local_game_registry.dart`（`_compareByInstalledAtDesc` 用 `DateTime.tryParse`） |
| 批 2/3/4 回归测试 | ✅ 43 例新增 | `game_identity_test.dart`(23) / `game_launch_path_convergence_test.dart`(7) / `game_title_slots_test.dart`(6) / `nsfw_store_retention_test.dart`(7)；另修正 `nsfw_detection_store_test.dart` 的时间戳夹具（见下） |
| P3-1 索引数据库 / P3-2 会话 append-only | ⏸ 不本次做 | P3-1 的前置（P0-1）已具备，可单独立项 |

**验证**：8 个改动文件逐文件与 `git show HEAD:` 基线按 issue 集合对比，**0 新增**
（`local_game_registry.dart` 还顺带 16→15）；全量测试 **720 通过 / 0 失败**。
⚠️ **未做真机走查**（三条真实路径：重复导入同名游戏 / 删游戏后确认 NSFW 缓存被清 /
老库首次启动的 v1→v3 迁移）。

**两处需要知道的偏差（如实标注）**
1. **P2-3 的 `coverUrl` 未改名**：它实际存的是本地封面绝对路径，改名 `coverFilePath`
   更准确。但该字段有 **232 处引用**，且 `WatchFolder` / `GameModel` / 元数据 SDK
   都有同名字段 —— 机械替换会误伤，而收益仅是"读起来更顺"。
   现处理方式：在字段上写明真实语义，并以 `coverPath` 作为别名 getter。
2. **`nsfw_detection_store_test.dart` 的夹具时间戳被修改**（`1700000000000` → 运行时刻）：
   P1-4 引入 180 天有效期后，原夹具（2023-11-14）本身成了"过期数据"，
   会让"put → flush → load 往返"这类用例假失败（实测 7 例）。改的是夹具数据、
   没有改任何断言口径；淘汰逻辑本身由 `nsfw_store_retention_test.dart` 正向锁定。

---

## 1. 数据资产清单（审计基线）

| 存储 | 位置 | 内容 | 规模风险 |
|------|------|------|----------|
| 游戏主档 | `<Games>/<safeName>/game.json` | 34 个字段（见 §2） | 随 sessions/daily_log 增长 |
| 会话归档 | `<Games>/<safeName>/sessions_archive.json` | 超过 100 条后归档的会话 | 有界（阈值 100/保留 50） |
| 内存注册表 | `LocalGameRegistry._games` | `Map<dirName, LibraryGame>` | 全量常驻 |
| 收藏夹本体 | `data/collections.json` | 含 `game_order`（成员顺序） | 小 |
| 智能归纳覆盖项 | `data/smart_groups.json` | 仅展示层（重命名/隐藏/置顶） | 小（成员派生，设计良好） |
| 全局手动序 | prefs `library_game_order` | 键 = directoryPath | 中 |
| 启动配置 | `data/game_configs/game_<safeTitle>_config.json` | `launch_exe_path` | **与 game.json 重复** |
| 启动配置(旧) | prefs `default_exe_<title>` | exe 绝对路径 | **与 game.json 重复** |
| 探索元数据缓存 | `data/cache/discover_metadata.json` | rating/releaseDate 等，7 天 TTL | 有 TTL，可控 |
| NSFW 判定缓存 | `data/cache/nsfw_detections.json` | 每张图一条，**无上限无 LRU** | **无界** |
| 导入候选队列 | `data/watch_candidates.json` | 已迁出 prefs（09-16 已修） | 有界 |

---

## 2. P0：会静默丢数据 / 读错数据

### P0-1 没有稳定主键，身份标识 4 套并存 🔴

**位置**
- `lib/services/local_game_registry.dart:332` `_games` 的 key = **目录名（dirName）**
- `lib/services/local_game_registry.dart:333,501,758,895` `_installedTitles` 名字叫 titles，实际装的是 **dirName**
- `lib/pages/library_page.dart:66` prefs `library_game_order` 键 = **directoryPath**
- `lib/services/collection_service.dart:44-49` `game_order` 键 = **directoryPath**
- `lib/utils/game_config_manager.dart:63-68` 配置文件名 = `game_<sanitize(title)>_config.json`
- `lib/services/game_launch_service.dart:115` prefs `default_exe_<title>`
- `lib/services/local_game_registry.dart:513-522` `getGameByTitle` 靠**遍历 title** 再回退 safeName

**现象**：改一次标题要同步 5 处（注册表 key、元数据目录名、GameConfigManager 文件名、
prefs 键、Magpie/快捷方式/存档清单）；迁移一次目录要同步 2 处（全局序、收藏夹序）。
补丁散落在 `lib/widgets/game_detail_dialog.dart:476-490`（改标题时手工迁移配置）
与 `local_game_registry.dart:1160-1238`（改路径时五阶段迁移）。

**更糟的分叉**：两处 sanitize 规则不一致——
`game_config_manager.dart:63` 会把空白替换成 `_`，
`local_game_registry.dart:509`（`getGameByTitle` 回退分支）与 `895`（`registerExtractionComplete`）
只替换非法字符、**保留空格**。同一次入库用两个规则算出的 key 不同，
`_games[safeName]` 与 scan 产出的 `dirName` 条目可能同时存在 → 同一游戏两张卡片、
时长统计重复计入。

**影响**：改标题后启动程序"变回默认"、快捷方式失效、自定义 exe 丢失；重名/空格场景下
库里出现幽灵重复条目。这类 bug 很难复现，因为要"改过标题"才触发。

**建议**
1. 在 `game.json` 增加 `game_id`（UUID v4，入库时生成一次，永不变更），
   写入点 `GameDataFormat.writeGameDir`（`game_data_format.dart:180` 附近）。
2. 建立 `LocalGameRegistry` 内三张索引：`_byId` / `_byTitleNorm` / `_byDirPathNorm`，
   `getGameByTitle` 改为查索引（见 P1-1）。
3. 新引用一律用 `game_id`；`game_configs` 文件名改 `game_<gameId>_config.json`，
   prefs 键改 `default_exe_<gameId>`；保留一次启动时的一次性迁移（读旧键 → 写新键 → 删旧键）。
4. 统一 sanitize 到**一个**工具函数（建议 `utils/game_key.dart`），禁止各处自写正则。

**预期效果**：改标题 / 迁移目录不再需要任何手工补丁；消除重复条目；为索引化与
未来的 sqlite 迁移铺路。改造面约 8~12 文件，但可分两步（先加 id + 索引，再迁键）。

---

### P0-2 启动 exe 路径三套存储，且优先级互相矛盾 🔴

**位置**
- A：`game.json → launch_path`（`game_data_format.dart:1297`），权威本体
- B：`data/game_configs/game_<safeTitle>_config.json → launch_exe_path`
  （`game_config_manager.dart:9`），注释自称"**主存储**"（`game_launch_service.dart:94`）
- C：prefs `default_exe_<title>`（`game_launch_service.dart:115,147`）

**现象**：`persistUserChoice`（`game_launch_service.dart:139-148`）同时写 B 和 C；
`game_launch_service.dart:103` 解析时"优先 B，回退 A"；而库页
`library_page.dart:2270-2276` 又是"先 B，再 C"。三个入口的读取顺序并不一致，
且 B/C 都以**标题**为键 —— 标题一改就断链，只能靠 `game_detail_dialog.dart:476-490`
那段"改名时顺手迁移"的补丁救场。

**影响**：用户在 A 处改了启动程序，B 里还是旧值 → 不同入口读到不同 exe；
改标题后旧配置变成孤儿文件，越积越多。

**建议**：确立 `game.json.launch_path` 为**唯一事实源**。
B/C 改为只读兼容（启动时若命中且与 A 冲突，以 A 为准并清理 B/C），
在两个版本后彻底删除。同时 `launch_path` 明确"相对 directoryPath 的相对路径，
绝对路径仅作兼容读取"（现在两种形态混存，`local_game_registry.dart:1002 _toRelative`）。

**预期效果**：消除"改了又不生效"的启动类工单；每个游戏少 1 个配置文件 + 1 个 prefs 键。

---

### P0-3 覆盖写入靠"白名单保命"，漏一个字段就是静默数据丢失 🔴

**位置**
- `lib/services/game_data_format.dart:58-87` `_preservedFieldsOnOverwrite`（20 个字段）
- `lib/services/game_data_format.dart:122-232` `writeGameDir`：先构造一份**不含**
  `sessions` / `daily_play_log` / `title_locked` 的 freshData，再靠白名单从旧文件捞回来
- `lib/services/game_data_format.dart:1174-1215` `GameJsonData` **没有** `sessions` /
  `daily_play_log` / `title_locked` 三个字段

**现象**：这是"黑名单思维"的反面——任何新增的、由用户行为累积的字段，
只要忘了加进 `_preservedFieldsOnOverwrite`，重复入库 / 覆盖安装 / 批量导入同名目录
就会把它清零，且**没有任何日志**。
更危险的是 `GameJsonData.toJson()`（`:1306`）是不含这三个字段的，
任何走 `GameJsonData` 全量序列化的路径都可能把 sessions 整表写没
（目前 `writeGameDir` 用的是手写 Map + 白名单，侥幸绕开了，但这是脆弱平衡）。

**影响**：游玩时长、会话历史、每日统计这类**不可重建的**用户数据丢失。
历史上"重复入库后时长归零"就是这个模式的典型后果。

**建议**
1. 把保留清单从**白名单**翻转为**黑名单**：`writeGameDir` 默认保留旧文件所有字段，
   只显式列出"本次写入必须覆盖"的字段（title/description/tags/cover/launch_path/
   directory_path/source/metadata_* 等约 12 个）。漏写黑名单的后果是"旧值没更新"，
   远比"新数据被清零"安全。
2. `GameJsonData` 补齐 `sessions` / `dailyPlayLog` / `titleLocked` 字段，
   让磁盘 schema 与模型**一一对应**，禁止在模型外手写 Map。
3. 补一条单测：构造含 play_time/sessions/daily_play_log 的旧 game.json →
   调 `writeGameDir` → 断言三个字段仍在。

**预期效果**：这一类数据丢失事故结构性归零；新增字段不再有"忘加白名单"的心智负担。

---

## 3. P1：规模上去后的性能与一致性

### P1-1 零索引：83 处 O(n) 遍历 + 65 处"每次排序" 🟠

**位置**
- `local_game_registry.dart:513-522` `getGameByTitle`：**线性遍历** `_games.values`（83 处调用）
- `local_game_registry.dart:492-496` `allGames` getter：每次调用都 `toList()` + `sort()`
  （65 处引用，含 `big_picture_library_page.dart:99,325,337,738`、`home_page.dart:91`）
- `big_picture_library_page.dart:337` 每个收藏夹一次 `_allGames.where(...)` →
  收藏夹数 × 游戏数
- `local_game_registry.dart:1270-1276` `updateGameTitle` 里又一次遍历找 key

**现象**：单次调用看不出问题，但叠加在导入（每条候选 × 排重索引）、
库页重建、BPM 侧栏计数上就是 O(n²)。2000 游戏规模下，
一次全库刷新 = 数千次字符串比较 + 数十次全量排序，全在 UI isolate。

**建议**
1. 注册表内维护三张派生索引：`_byId`、`_byTitleNorm`（用 `TitleCleaner.normalizeForCompare`）、
   `_byDirPathNorm`（`PathNormalizer.forCompare`），在任何结构性变更处统一维护。
2. `allGames` 改为**缓存列表**（`_cachedSorted`，结构性变更时置空重建），
   `playTimeUpdate` 不改顺序则复用。
3. BPM 侧栏计数改为一次遍历建 `Map<collectionId, int>`，而不是每个收藏夹过滤一遍。

**预期效果**（估算，未实测）：2000 游戏下库页重建与导入排重的常数时间显著下降，
O(n²) 降为 O(n)；`allGames` 的重复排序从"每帧多次"降为"每次结构性变更一次"。

---

### P1-2 `scan()` 串行全量 IO，且每个游戏解析两遍 JSON 🟠

**位置**
- `local_game_registry.dart:618-786` `scan()`：`for` 循环内 `await` 每个目录
- `local_game_registry.dart:673,679` 每个游戏先 `await GameDataFormat.readGameJson(...)`
- `local_game_registry.dart:726` 再 `GameDataFormat.findCoverFile(entity.path)`
- `game_data_format.dart:1122-1138` `findCoverFile` **又同步读了一遍 game.json 并 jsonDecode**
- `game_data_format.dart:836-859` `readGameJson` 也进了 `_writeQueues` 写队列

**现象**：每个游戏 2 次文件读 + 2 次 JSON 解析，其中第二次完全可以复用第一次的结果；
读取被写队列串行化（游玩中每 ~10s 落盘一次会阻塞该目录的扫描读）；
整体无任何并发，1000 游戏 = 1000 次串行 await。

**建议**
1. `findCoverFile` 增加可选参数 `Map<String,dynamic>? parsedJson`，
   命中时不再重复读文件（改 1 处，收益最快）。
2. `readGameJson` **移出写队列**：读操作不需要与写互斥（写本身已是原子 rename），
   只需保证"读到的是完整文件"——原子写已保证。可另设读并发上限（如 8）。
3. 扫描改为 `Future.wait` 分批（每批 32）；长期按已立项的 P1-1 做 isolate 化。

**预期效果**（估算）：JSON 解析量减半；扫描墙钟时间预计下降 30%~50%，
且游玩中的游戏不再被扫描阻塞。

---

### P1-3 时长三份存储无自动对账；`incrementDailyPlayCount` 未裁剪 🟠

> ⚠️ **勘误（2026-09-19 执行批 1 时发现）**：原文称「`addDailyPlaySeconds` 只累加、
> 从不裁剪」——**该判断错误**。`addDailyPlaySeconds`（`game_data_format.dart:381-386`）
> 本来就带 90 天裁剪，是本次审计读代码时漏读了后半段。
> 真实缺口是同文件的 `incrementDailyPlayCount`（:393-420）**没有**裁剪分支。
> 已在批 1 补上。

**位置**
- `game_data_format.dart:427-430` 设计注释：sessions 是事实表，play_time / daily_play_log
  是派生投影，损坏时可自愈 —— **设计是对的**
- `game_data_format.dart:381-386` `addDailyPlaySeconds`：**已有** 90 天裁剪（✅ 无问题）
- `game_data_format.dart:393-420` `incrementDailyPlayCount`：**缺**裁剪分支（真实缺口）
- `game_data_format.dart:709-713` `rebuildPlayTimeFromSessions` 内含 90 天裁剪，
  但该方法需**手动**触发
- `game_data_format.dart:641` 同上

**现象**：日常写入路径的裁剪只覆盖"加秒数"这一条；只累加次数时（短会话等）
旧条目不会被清理。三份数据之间没有对账，`play_time` 若被异常写入覆盖
（历史上发生过），除非用户手动触发重建，否则永远错下去。

**建议**
1. `incrementDailyPlayCount` 补上 90 天裁剪（与 `addDailyPlaySeconds` 对齐），成本极低。
   ~~`addDailyPlaySeconds` 加裁剪~~（勘误：已有，**不需要改**）
2. 启动时或每周做一次轻量对账：`Σsessions.duration` vs `play_time`，
   偏差 > 1% 或 > 300s 时自动调用 `rebuildPlayTimeFromSessions` 并写
   `data/cleanup_log.jsonl`（复用既有审计日志）。
3. 可选：把 `play_time` 标为纯派生（不再独立写），只维护 sessions + daily_log。

**预期效果**：game.json 体积可控；统计数据具备自愈能力，不再需要用户手删重建。

---

### P1-4 NSFW 判定缓存无上限、无 LRU、无过期 🟠

**位置**
- `lib/services/nsfw/nsfw_detection_store.dart:37` `final Map<String, NsfwDetection> _items`
  （全文无 `removeWhere` / 无容量上限 / 无按时间淘汰，只有 `clear()` 全清）

**现象**：封面 + 截图逐张累积，1000 游戏 × 6 张截图 = 6000 条，
全部常驻内存并全量写入 `nsfw_detections.json`；每次启动全量 jsonDecode。
文件只增不减，且删除游戏后其判定记录仍是孤儿。

**建议**
1. 加 LRU 上限（建议 5000 条）+ 按 `detectedAtMs` 过期（建议 180 天），
   淘汰在 `load()` 后与 `save()` 前各跑一次。
2. 按游戏分片存储（`nsfw/<gameId>.json`），避免单文件全量读写；
   至少要做到删除游戏时清理该游戏的记录。
3. 与 `modelSignature` 失效机制配合：签名变化时整表作废已是既有逻辑，别动。

**预期效果**：缓存文件大小有上界；启动加载时间不再随使用时长线性增长。

---

## 4. P2：字段定义与冗余

### P2-1 僵尸字段：`completed` 与 `play_status` 语义重叠 🟡

`game_data_format.dart:186,814` 有 `completed: bool` 与 `setCompleted()`；
`game_data_format.dart:190,818` 又有 `play_status`。
**全库 grep：`setCompleted` 无任何调用者**（`completed` 只在入库时写死 `false`），
`LibraryGame` 里根本没有 `completed` 字段。
→ 建议：标记 deprecated，迁移脚本清理，UI 一律只读 `play_status`。

同类：`GameMark.favorite`（`local_game_registry.dart:80`）枚举存在但 UI 只有 star
（`toggleMark` 只在 none/star 间翻转，`:529-540`）；
`GameDataMigration._migratedFlag`（`:8`）定义后从未使用。

### P2-2 `format_version` 恒为 1，schema 演进无承载点 🟡

`game_data_format.dart:15` `currentVersion = 1`；但 `sessions`、`daily_play_log`、
`title_locked`、`collection_ids`、`metadata_source*` 都是后期追加的字段，
从未升版本，也没有"按版本跑迁移"的框架（`GameDataMigration` 只处理
`game_info.json` → `game.json` 的一次历史迁移）。
→ 建议：建立 `migrations: Map<int, Function(Map)>` 版本链，
启动时按 `format_version` 逐级升级并写审计日志；下一次加字段必须同时加迁移 + 升版本号。

### P2-3 命名误导：字段类型与名字不符 🟡

- `LibraryGame.coverUrl`（`:224`）实际存的是**本地文件绝对路径**，
  `coverPath` getter 直接返回它（`:278`）→ 建议改名 `coverFilePath`。
- `LocalGameRegistry._installedTitles`（`:333`）装的是**目录名**不是标题 →
  建议改名 `_installedDirNames` 或直接并入索引。
- `GameJsonData.screenshotFiles` / `screenshotUrls` 是"已下载"与"待下载"两份数据，
  下载完成后 `urls` 仍全量保留（无清理），语义容易误读为"当前应显示的截图"。
  → 建议：明确 `urls` 为"源清单（只读）"、`files` 为"本地产物（派生）"，
    下载成功后允许从 urls 移除已落地项，或至少加注释固化语义。

### P2-4 标题四件套语义重叠 🟡

`title` / `original_title`（导入时的文件夹名）/ `metadata_title`（抓取到的标准名）/
`subtitle`（用户自定义副标题，通常日文原名）。
`original_title` 与 `metadata_title` 在多数路径下是同一份数据的两个副本
（`game_data_format.dart:198-200` 同时写入）。
→ 建议：收敛为三个语义清晰的槽位——`title`（展示用，用户可改）、
`original_title`（数据源原名，只读）、`subtitle`（用户自定义副标题，唯一可编辑项）；
`metadata_title` 标记为 `original_title` 的别名并在读取时合并。

### P2-5 `installedAt` 用字符串比较排序 🟡

`local_game_registry.dart:494` `list.sort((a,b) => b.installedAt.compareTo(a.installedAt))`，
值是 `DateTime.now().toIso8601String()`（本地时区、无 Z）。
若历史数据混入 UTC 带 Z 的值（迁移/外部工具写入），字符串比较会错序。
→ 建议：排序时 `DateTime.tryParse(...)` 后比较，空值统一归到末尾；
顺便把"最近添加"口径固化成测试用例（当前存量语义：首次入库时间，不可被编辑覆写）。

---

## 5. P3：架构级方向（不必现在做，但要知道）

### P3-1 "文件夹即数据库"的边界已到 ⚪

1000 游戏 = 1000 次目录列举 + 1000 个 JSON 全量读。任何跨游戏查询
（排序 / 筛选 / 聚合 / 搜索）都只能全量扫一遍，无法增量。
→ 方向：引入 `data/library_index.db`（sqlite 或自研），
存 `(game_id, title, title_norm, directory_path, developer, play_time, last_opened_at, installed_at)`，
`game.json` 降级为"可重建的权威源"，索引损坏时由 game.json 全量重建。
这能把"库页首屏 = 全盘扫描"变成"读一个索引文件"。
**前提**：先完成 P0-1（稳定主键），否则索引无从建立。

### P3-2 会话落盘写放大 ⚪

`updateGameJsonAtomic` 每次都全量重写整个 game.json（含 50 条 sessions +
daily_play_log），且用 `JsonEncoder.withIndent('  ')` 带缩进（体积 +30%~50%）。
游玩中每 ~10s 一次。
→ 方向：会话写入改 append-only `sessions.jsonl`，定期合并进 game.json；
落盘用紧凑编码（无缩进）。当前规模下可接受，2000 游戏 + 长时间挂机后值得做。

---

## 6. 明确**不**建议动的（设计良好，别被"优化"带偏）

- **智能归纳成员不落盘**（`library_smart_group_service.dart:20-31`）：
  分组派生自 `tags`/`developer`，只持久化展示层覆盖项。这是本项目里
  "避免双份事实"的正面样板，保持。
- **每个游戏目录自包含 game.json**：便于备份/迁移/手工修复，是优势不是债。
- **`_writeQueues` 按目录串行化 + `_atomicWriteFile` 原子 rename**（`game_data_format.dart:29,42`）：
  解决并发覆盖与崩溃截断，别为了"性能"拆掉（P1-2 建议移出的是**读**，不是写）。
- **覆盖写入保留用户累积数据**这个意图本身（P0-3 只改实现方式，不改意图）。

---

## 7. 建议落地顺序

| 批次 | 内容 | 依赖 | 风险 |
|------|------|------|------|
| 批 1 | P0-3（白名单→黑名单 + 补齐模型 + 单测） | 无 | 低，纯加固 |
| 批 1 | P1-2 之一（`findCoverFile` 复用已解析 JSON） | 无 | 极低 |
| 批 1 | P1-3 之一（daily_log 每日裁剪） | 无 | 低 |
| 批 2 | P0-1（`game_id` + 三张索引 + 统一 sanitize） | 批 1 | 中，涉及键迁移 |
| 批 2 | P1-1（allGames 缓存 + BPM 计数一次遍历） | P0-1 索引 | 低 |
| 批 3 | P0-2（启动路径收敛到单一事实源 + 旧键清理） | P0-1 | 中，需兼容期 |
| 批 3 | P1-4（NSFW LRU + 过期） | 无 | 低 |
| 批 4 | P2 全部（僵尸字段清理 + 版本化迁移框架 + 改名） | 批 2 | 低但面广 |
| 未来 | P3-1（索引数据库） | P0-1 完成 | 高，需单独立项 |

---

## 8. 未验证事项（如实标注）

1. 所有性能数字均为**静态估算**，未做真机 profile / 未构造 2000 条数据集实测。
2. P0-1 的"key 分叉导致重复条目"是**静态推演**（两处 sanitize 规则确凿不同），
   未在真机复现出重复卡片。
3. `GameJsonData.toJson()` 是否真的存在"把 sessions 写没"的调用路径，
   本次只确认了模型缺字段 + `writeGameDir` 幸运绕开，**未穷举全部调用点**。
4. P1-4 的 NSFW 缓存实际文件大小未采集（真实数据目录不在本仓库内）。
