# 导入稳定性与性能专项审计（2000+ 游戏规模）

| 项 | 值 |
|---|---|
| **单号** | 2026-09-16-import-stability-audit |
| **提出人** | 用户 |
| **现象** | 导入 2000+ 游戏时软件崩溃/卡死（未响应）；导入或其他功能出现异常时直接拖垮全局 |
| **审查方式** | 静态代码审阅 + 逐环节成本推演（**只读，未改代码、未跑基准、未真机复现**） |
| **结论** | 三层根因：**① 共享持久化底座（prefs 单文件全量同步重写）② 导入全链路跑在 UI isolate ③ O(n²) 复杂度 + 列表非虚拟化**。另有 4 条独立崩溃路径。 |
| **关联** | `2026-09-12-import-audit-summary.md`（IMP-12 批 B「isolate 化」本单正式立项）；`2026-09-12-import-source-file-loss.md` |

> ⚠️ 本单为**阶段 A 只读审计**，未做任何代码改动。第 6 节的方案需批准后执行。

---

## 0. 结论先行

**"2000 个游戏就崩"不是某一个 bug，而是四条设计债在同一时刻叠加：**

| # | 根因 | 性质 | 量级（2000 条时） |
|---|---|---|---|
| **R1** | `PortableSharedPreferencesStore.setValue` 每次写入都 **json.encode(整个 prefs) + `writeAsStringSync(flush:true)`**，而候选队列（含元数据）就存在 prefs 里 | 🔴 全局性 | 单次写入 = 数 MB 编码 + fsync；批量入库时**每游戏 2 次全量写** → 约 4000 次 ≈ 10GB+ 写盘 |
| **R2** | 导入全链路（扫描识别/JSON 编码/写盘/进程调用）**全在 UI isolate**，`Isolate`/`compute` 在导入链路 0 处使用 | 🔴 架构性 | 任何一段重活 → 掉帧 → 系统"未响应" |
| **R3** | 关键路径 **O(n²)** 且每对比较都做重量级字符串规范化；候选列表**非虚拟化**渲染 | 🔴 算法/UI | 约 1200 万次 `forCompare` + 每次通知重建 2000 个 Item |
| **R4** | 网络/队列**无全局背压**：富化并发 3、截图队列无上限、`list(recursive:true).toList()` 无上限 | 🟠 资源 | 富化最坏 4–5 小时；无界物化可 OOM |

**用户感知 = R1/R3 把 UI 线程占满（卡死）→ R2 让卡死扩散到全应用（任何功能都卡）→ R4 提供崩溃（OOM/进程）→ 错误被静默吞掉（`app_log_helper.dart:143-146` 返回 `true`），事后无法诊断。**

---

## 1. 影响链路总览（点 → 阶段）

```
[选择文件夹] → 扫描识别(阶段一~五) → 富化(MIX 抓取/封面) → 入库(写 game.json/注册/截图)
                       ↑                       ↑                      ↑
              R3 O(n²) 同步遍历          R4 无背压网络          R1 逐条全量落盘
              R2 UI isolate              R2 UI isolate          R1 attrib 进程 ×2/游戏
                       └────────────── 候选列表非虚拟化（R3）──────────────┘
                                    任何 notify → 全量重建（R2/R3）
```

---

## 2. 逐环节问题清单（P0 = 直接导致卡死/崩溃）

### 2.1 持久化底座（R1，全局性最强）

| # | 位置 | 问题 |
|---|---|---|
| **S-01** | `lib/core/portable_shared_preferences_store.dart:91-95` + `:64-81` | `setValue` → `_save()` → `json.encode(全部 prefs)` + `tmp.writeAsStringSync(encoded, flush: true)`（同步 + fsync）。**每一次任意 key 的写入都重写整份文件。** 队列越大，所有功能越慢 —— 这是"其他功能也被拖垮"的共性根因 |
| **S-02** | `lib/services/watch_folder_service.dart:217-224`（`_saveCandidates`）、`:1150` | `confirmAllCandidates` 循环内 **每入库一条就 `await _saveCandidates()`**：序列化整个剩余候选队列（含 `metadata`：简介/标签/封面/截图 URL）。2000 条 → 2000 次全量编码；单条 ~1.5KB 时总编码量 ≈ 3GB |
| **S-03** | `lib/services/watch_folder_service.dart:1141` → `:1226-1240` | 同一循环内 `_refreshGameCountForPath` → `_countGamesUnderPath`（O(全库) 遍历）+ 命中变化即 `_saveSettings()`（又一次全量 prefs 写）。**每游戏 2 次全量写盘** |
| **S-04** | 候选队列本身（`_candidatesKey`） | 把"大对象队列"塞进 prefs：`watch_folder_candidates` 可膨胀到数 MB~数十 MB，且是**双层 JSON**（JSON 字符串再被转义进 prefs）→ 体积 ×2 |
| **S-05** | `lib/services/watch_folder_service.dart:479`（本轮新代码） | 🔴 **自曝**：09-13 IMP-22 引入的 `_compactQueueOnStartup` 对每条候选调 `dedupIndex.check()`，而 `check()` 内部是 O(全库) 且每 ref 3 次 `forCompare` → 队列 2000 + 库 2000 时 ≈ 1200 万次规范化，**启动期 UI isolate 上纯 CPU 数十秒** |

### 2.2 扫描识别阶段（R2 + R3）

| # | 位置 | 问题 |
|---|---|---|
| **S-06** | `lib/pages/join/utils/game_folder_scanner.dart:527-543`（`_detectIndependentGame`）→ `gal_game_detector.dart:438-439, 744-792` | 每个候选目录 `detect()` 做**同步** `listSync`（自身 + 每个一级子目录 2 层展开），并为每个文件构造 `File` 对象（上限 2000/500）。2000 个游戏 × 约 30 子目录 ≈ 6 万次同步 `listSync` + 数百万对象分配，全部在 UI isolate |
| **S-07** | `import_dedup_index.dart:138-161`（`check`） | 阶段 2a 对每个候选做**路径包含线性扫描**：`for (ref in _refs) forCompare(ref.directoryPath)`，且 `_pathContains → isSubdirectory → forCompare` 再各调 2 次 → **每候选 ≈ 3×库大小 次字符串规范化**；2000×2000 ≈ 1200 万次 |
| **S-08** | `game_folder_scanner.dart:608-636`（`_hasSameParentGame`） | 阶段五对每个游戏遍历已接受集合，每对 2 次 `isSubdirectory`（=4 次 `forCompare`）→ 约 400 万次；exe 已加缓存（IMP-12 批A），**路径比较仍未优化** |
| **S-09** | `game_folder_scanner.dart:323-420`（IMP-22 新增 4a/4b/4c） | 🔴 **自曝**：4c 对每个游戏再遍历 `kept` 两次，且**每对都调用 `TitleCleaner.cleanFromDirPath` + `normalizeForCompare`（正则）** → 2000 条时约 800 万次正则；4b 的 `deduped.any(isSubdirectory)` 同为 O(n²) |
| **S-10** | `watch_folder_service.dart:707-743`（`_collectCandidateDirs`） | 每次扫描（含 watcher 事件触发的重扫）都重走整棵树收集候选；虽有 TTL 过滤评估，但**收集本身**是 O(全树目录数) 的异步 list |
| **S-11** | `watch_folder_service.dart:485-499` | Windows 上 `dir.watch(recursive: true)` 对大目录树（目录数万级）是句柄/缓冲压力源；事件风暴下 30s 重连逻辑会反复重扫 |

### 2.3 富化阶段（R4）

| # | 位置 | 问题 |
|---|---|---|
| **S-12** | `watch_folder_service.dart:814-838`（`_pumpEnrichmentQueue`，并发 3）→ `auto_import_pipeline.dart:85-192` | 每候选一次 MIX 多源抓取（多源 `Future.wait`，单源 connect 10s / receive 15s，另有 2s 端口探测 `metadata_fetcher.dart:255`）。**2000 条 × 单条 1–30s ÷ 并发 3 ≈ 11 分钟 ~ 5.5 小时**；用户看到的是"进度条几乎不动"，中途必然操作 → 交互压力 |
| **S-13** | `auto_import_pipeline.dart:118` | `dedupIndex ?? ImportDedupIndex.fromRegistry()` —— 富化调用方未传 index（`watch_folder_service._enrichOne`）→ **每候选重建一次全库索引**（O(库) × 2000） |
| **S-14** | `auto_import_pipeline.dart:316-337`（封面下载） | 封面下载 fire-and-forget，无全局并发上限；与元数据抓取抢带宽 |
| **S-15** | `screenshot_fetch_service.dart:123,155-197,213` | 截图任务入队无上限（2000 条 = 2000 任务）；`_queue.removeAt(0)` + 每任务 `notifyListeners()`；串行下载 + 每任务网络与写盘 |

### 2.4 入库阶段（R1 + 进程开销）

| # | 位置 | 问题 |
|---|---|---|
| **S-16** | `game_data_format.dart:912-935`（`_writeCtgame`） | 每个游戏 **2 次 `Process.run('attrib', runInShell: true)`**（`-r -h` 再 `+h`）→ 2000 游戏 = **4000 次进程创建**（每次经 cmd shell），外加 `writeAsString(flush: true)` 强制 fsync |
| **S-17** | `game_data_format.dart:144-150` | 入库时若无本地封面 → `_downloadAndSaveCover`（网络）**在导入管道内 await**，并发 2 → 2000 次网络往返串在关键路径上 |
| **S-18** | `batch_import_controller.dart:1298-1345` | 批量入库 `batchSize = 2` + **每批一次 `notifyListeners()`**（2000 条 = 1000 次通知，每次触发整页重建，见 2.5） |
| **S-19** | `batch_import_controller.dart:186, 1478-1510` | 批量任务状态**仅在内存**（无持久化、无断点）→ 崩溃即全丢，但已写入的 `game.json` 残留 → 重导后出现"半截库"（与 09-12 源文件丢失事故同一现场） |

### 2.5 UI 渲染（R3，用户直接感知的"卡死"）

| # | 位置 | 问题 |
|---|---|---|
| **S-20** | `smart_import_section.dart:118-133, 639-860` | 🔴 **候选列表非虚拟化**：`SingleChildScrollView` + `Column(...candidates.map(_buildCandidateItem))`，无 `ListView.builder`。2000 条 = 一次性构建/布局 2000 个 Item（每个含 Container/InkWell/装饰/文本/可能图片）。**每次 `notifyListeners` 全量重建**，而通知源包括：每候选入队、每富化完成、扫描进度（500ms 节流）、`_saveCandidates` 后 …… 单次重建数百 ms~秒级，通知成百上千次 → UI 线程饱和 = 未响应 |
| **S-21** | `batch_import_section.dart:503` | 批量列表已用 `ListView.builder` ✅（**对照组**：说明问题只在智能导入侧） |
| **S-22** | `library_page.dart:225-341, 658` | 库页在挂载时监听 registry；每次结构变更重建 → `List.from + sort`（2000 条）。当前 `main_container.dart:763-790` 是"单页切换"，**导入时库页不在树上**（缓解），但导入后首次进入库页仍有全量排序 + 卡片构建成本 |
| **S-23** | `watch_folder_service.dart:1030-1047`（通知节流 500ms） | 仅扫描评估路径做了节流；**入队 / 富化完成 / 入库收尾**路径无节流，通知频率与候选数线性相关（IMP-12 批A 只治了写盘，没治通知） |

### 2.6 崩溃（非卡死）路径

| # | 位置 | 风险 |
|---|---|---|
| **S-24** | `extract_manager.dart:354, 519, 1287, 1898`（游戏目录，**已修**）；`openlist_service.dart:492, 807, 866`（仅统计应用自管 `runtime/openlist/data`，条目数很小，**不构成 OOM 风险**）；`openlist_service.dart:616` 本就是流式 | `list(recursive: true).toList()` **无上限物化**。大型游戏目录（几十万~百万文件）→ 一次性数百 MB~GB 级 `FileSystemEntity` → **OOM 原生崩溃（Dart 层不可捕获）**。这正是"导入 300GB"场景。⚠️ 复核修正：openlist 三处作用于应用自管的 data 目录（非游戏目录），风险等级下调 |
| **S-25** | `app_log_helper.dart:137-147` | `PlatformDispatcher.onError` **返回 true**（吞掉）+ 只写日志 → 失败静默、状态不一致；用户侧表现为"卡住/少了几个游戏"，无任何可见反馈 |
| **S-26** | `portable_shared_preferences_store.dart:37-61` | prefs 文件损坏/被截断（非本次 write 路径）→ `_ensureLoaded` 静默以**空数据启动** → 队列/设置/忽略列表全丢（用户以为"数据没了"） |
| **S-27** | `interrupt_cleanup.dart` + `watch_folder_service.dart:431-456` | 崩溃恢复只依赖 `_isImportingKey` 布尔位 + 磁盘比对；导入中断后的**队列与磁盘不一致**无完整修复流程（部分已由 IMP-13/14 缓解） |

---

## 3. 量级推演（为什么"2000"是引爆点）

假设：2000 个游戏、其中 60% 富化成功、单条候选 JSON ≈ 1.5KB、库规模同为 2000。

| 项 | 估算 | 说明 |
|---|---|---|
| prefs 全量写次数 | **≈ 4000+ 次**（入库期） | S-02 + S-03 每游戏各 1 次 |
| prefs 写入总量 | **≈ 10 GB+** | 每次编码整份 prefs（含数 MB 队列串）× 4000 |
| 同步 `listSync` 次数 | **≈ 6 万次** + 数百万对象 | S-06 |
| 字符串规范化次数 | **≈ 2000 万次** | S-07/S-08/S-09/S-05 相加 |
| 正则调用 | **≈ 800 万次** | S-09（IMP-22 新增） |
| 候选列表单次重建成本 | **数百 ms ~ 秒** | S-20（2000 个 Item） |
| 通知次数 | **1000+ 次**（扫描 + 富化 + 入库 + 进度） | S-23/S-18 |
| 富化墙钟时间 | **11 分钟 ~ 5.5 小时** | S-12 |
| 进程创建 | **4000 次** | S-16 |

→ 只要 R1/R3 任一存在，UI 线程就会被占满；两者叠加时"未响应"必然发生，且**磁盘写入量级（GB 级）× fsync** 会让机械盘/占用中的盘直接卡死。

---

## 4. 架构层共性因素（"为什么任何功能异常都拖垮全局"）

1. **共享持久化后端把全局状态耦合在一起**：单 JSON 文件 + 全量同步重写 ⇒ 任何功能的一次写操作，成本 = 整份应用状态（S-01/S-04）。
2. **状态中枢过粗**：`LocalGameRegistry` / `WatchFolderService` / `BatchImportController` 都是粗粒度 `ChangeNotifier` 单例，只有"结构变更/游玩时长"两档；一次小变化广播给所有监听者，无差分、无按 id 订阅（S-22/S-23）。
3. **没有"重活"边界**：全应用只有 5 处用了 isolate/compute（迁移复制 / NSFW / 路径扫描 / 封面对齐 / 分卷合并），**导入/扫描/序列化一律在 UI isolate**（R2）。
4. **逐条事务 + 无批量合并**：每条游戏独立 `game.json`、独立 `attrib`、独立保存队列、独立截图入队 ⇒ 成本随条目线性叠加且带常数放大（S-02/S-16/S-18）。
5. **无背压/无上限**：截图队列、封面下载、富化队列、`list(recursive)`、watch 事件都无与数据规模无关的上限（S-15/S-24/S-11）。
6. **错误被吞没**：`onError → true` + debugPrint ⇒ 静默失败、无用户可见诊断、无失败清单（S-25）。
7. **无断点/无幂等**：批量状态在内存；导入中断后"磁盘 vs 队列 vs 库"三处状态可以互相不一致（S-19/S-27）。
8. **规模假设缺失**：所有设计默认"库/队列 ≤ 数百"（TTL 缓存、通知节流、去重索引、UI 列表都按小规模写），无"大批量模式"分支。

---

## 5. 明确不改（本单范围外）

- `luna_metadata_sdk/`（独立 SDK，抓取逻辑）；`windows/runner/`（原生层）。
- 抓取源合法性/限流策略本身（只加客户端并发与超时，不改源）。
- 既有存量：`test/big_picture/widgets/` 的失败用例。
- 09-12/09-13 已修的数据安全护栏（ADR-007/008）不回退。

---

## 6. 改进方案与优先级

> 原则：P0 只做"止血"（小改动、确定性收益、不动业务语义）；结构性改造走 P1/P2 分批。

### P0（止血，建议本轮）

| # | 措施 | 落点 | 预期收益 |
|---|---|---|---|
| **P0-1** | **候选列表虚拟化**：`SingleChildScrollView + Column(map)` → `ListView.builder`（含"忽略列表"同改） | `smart_import_section.dart:118-133, 639-860` | 单次重建从 O(2000) → O(视口)；卡死主因之一消除 |
| **P0-2** | **批量落盘/批量通知**：`confirmAllCandidates` 循环内 `_saveCandidates/notifyListeners/_refreshGameCountForPath` 改为**每 N 条（如 20）或收尾一次**；进度通知节流 200–500ms | `watch_folder_service.dart:1128-1165, 1226-1240` | 入库期全量写盘 4000 次 → 数次数；通知 1000 次 → 数十次 |
| **P0-3** | **prefs 写合并与去抖**：在 `PortableSharedPreferencesStore` 增加"微任务合并 + 250ms 去抖写"（同一帧多次 set 只落一次盘）；**并把候选队列迁出 prefs** 到 `data/watch_candidates.json`（独立文件 + 同样的去抖 + 原子 rename） | `portable_shared_preferences_store.dart:64-95`；`watch_folder_service.dart:217-224` | 全局任意写操作的常数成本从"数 MB"降到"KB 级"；直接缓解"其他功能也卡" |
| **P0-4** | **O(n²) 路径判定预计算**：`ImportDedupIndex` 构建时缓存 `forCompare` 结果；`check()` 内循环零规范化；`_enrichOne` 复用同一 index（不要逐条 `fromRegistry()`）；`_compactQueueOnStartup` 改用该索引 | `import_dedup_index.dart:86-179`；`auto_import_pipeline.dart:118`；`watch_folder_service.dart:472-530` | 2000 万次规范化 → 数万次；启动期数十秒 → 亚秒 |
| **P0-5** | **扫描阶段缓存标题键**：`_DetectedGame` 增加惰性 `titleKey`，4a/4b/4c 复用（消除 800 万次正则）；`_hasSameParentGame` 预计算规范化路径前缀 | `game_folder_scanner.dart:323-420, 608-636` | 识别阶段 CPU 降低 1–2 个数量级 |
| **P0-6** | **`attrib` 去进程化**：改用 FFI `SetFileAttributesW`（项目已有 FFI 先例），或每批一次性 attrib | `game_data_format.dart:912-935` | 4000 次进程创建 → 0；每游戏省 20–100ms |
| **P0-7** | **无界物化有界化**：`list(recursive:true).toList()` → `await for` 流式 + 计数上限 + 早停（或移入 isolate） | `extract_manager.dart:354,519,1287,1898`；`openlist_service.dart:492,616,807,866` | 消除 OOM 崩溃路径（S-24） |

### P1（结构性，建议紧随其后）

| # | 措施 | 说明 |
|---|---|---|
| **P1-1** | **扫描/识别/序列化移出 UI isolate**（= IMP-12 批 B 正式立项）：扫描在 isolate 内完成并回传 DTO；`GalGameDetector.detect` 的同步 IO 随之迁走 | 根治 R2；需要真机性能回归 |
| **P1-2** | **prefs 写入器异步化**：单写者队列 + 合并 + 后台 isolate 执行编码与写盘（UI 只入队） | 与 P0-3 组合成"任何写入都不阻塞 UI" |
| **P1-3** | **批量导入事务化**：每 N 条一次 `game.json` 落盘 + 一次注册通知；导入会话持久化（已处理集合/队列）支持崩溃续跑与幂等重入 | 治 S-19/S-27；崩溃后不再"半截库" |
| **P1-4** | **网络背压**：元数据/封面/截图共享全局限流（并发 + 令牌桶 + 单条总超时 20s），失败快速标记不重试风暴 | 治 S-12/S-14/S-15 |
| **P1-5** | **watch 策略重构**：限制递归深度/目录数；事件只标记"脏子树"按需重扫；失败降级为轮询 | 治 S-11/S-10 |

### P2（可观测与容错）

| # | 措施 |
|---|---|
| **P2-1** | 错误不再静默：导入每轮生成**用户可见**的失败/跳过清单（`data/logs/import_run_<ts>.json`），`onError` 保留上报 |
| **P2-2** | UI 心跳看门狗：帧间隔 > N 秒写日志 + 提示（把"未响应"变成可诊断） |
| **P2-3** | 资源水位：磁盘 < 阈值暂停写入类操作；prefs 体积 > 阈值告警并迁移大对象 |
| **P2-4** | 导入前**预检**：候选数 > 阈值 → 弹"大批量模式"提示（降低并发、关闭截图抓取、分批落盘） |

### P3（长期架构）

| # | 措施 |
|---|---|
| **P3-1** | 统一 **Job/作业抽象**（队列 + 背压 + 取消 + 进度 + 断点 + 幂等），导入/安装/迁移/截图/封面全部接入 —— 治"任何功能异常拖垮全局" |
| **P3-2** | 状态中枢细粒度化：结构变更**批量合并通知**（事务结束才广播）+ 按游戏 id 的 `ValueListenable` |
| **P3-3** | 存储层升级：sqlite（或分片 JSON + 追加日志）替代"单文件全量重写"，支持增量与事务 |

---

## 7. 验收与基准（每批执行后）

1. **基准脚本**（新增，测试基建）：构造 2000 个假游戏目录（kiriKiri/unity 各半），跑：
   - 扫描识别耗时、`forCompare` 调用计数（可加临时计数器）；
   - 批量入库 2000 条的墙钟时间与 prefs 写入次数/字节数；
   - 候选列表首帧与滚动帧率（`flutter test` + golden 不适用，**必须真机**）。
2. **门槛（已定，依据用户要求"稳定优先、速度尽可能快"）**：
   - 扫描识别（2000 条，含富化前的识别段）：**≤ 90s**，期间窗口可拖动/可切页；
   - 批量入库（2000 条，含元数据与封面）：**≤ 20min**，进度条持续推进；
   - **全程无"未响应"**（单次卡顿 > 500ms 视为不达标）；
   - prefs 单次写盘 ≤ 100KB（候选队列已迁出）；
   - 导入期间内存峰值无异常增长（无 OOM）。
   > 说明：富化（网络抓取）本身受数据源限速，2000 条天然需要数十分钟；用户要求是
   > "一个完整任务一次性跑完、期间软件可用"，因此门槛以**不卡死**为硬指标、以时长为软指标。
3. **回归**：`flutter test` 零新增失败（当前 **519 通过 / 0 失败**）；改 UI 必真机走查（候选列表 2000 条滚动、批量入库期间切页）。
4. **真机走查清单**：① 2000 条扫描期间窗口可拖动/可点按钮；② 批量入库期间切到库页再回来不崩；③ 强制结束进程后重启，队列/库状态自洽；④ 断网场景（全部富化失败）不卡死。

---

## 8. 待用户确认

1. **主战场**：2000 条是**一次性导入**（要求全部完成）还是允许**分批/流式**（先入库再后台补齐元数据）？这决定 P1-3/P2-4 的形态。
2. **性能目标**：可接受的扫描与入库时长上限（用于设定门槛）。
3. **执行范围**：先执行 P0-1~P0-7（止血，改动集中在 6 个文件），还是合并 P1-1（isolate 化）一起做？

---

## 9. 执行记录（2026-09-16，本单 P0 全量落地）

> 用户批准范围：**"一次完成所有相关开发"**，并明确"稳定性优先、速度尽可能快"。

### 9.1 已完成（P0 七条 + P1 两项）

| 编号 | 措施 | 落点 | 结果 |
|---|---|---|---|
| P0-1 | 候选列表虚拟化（含忽略列表） | `smart_import_section.dart` | `ListView.builder` + 固定视口（屏幕高 55%，260–640）；2000 条每次重建从 O(n) → O(视口) |
| P0-2 | 批量入库落盘/通知合并 | `watch_folder_service.dart` | 每 **20 条**落盘+通知（原 2000 次 → ≤100 次）；`_refreshAllGameCounts()` 收尾一次刷新（原 O(n²) 遍历 + 上千次 prefs 写） |
| P0-3 | prefs 同轮写合并 + 异步落盘；候选队列迁出 prefs | `portable_shared_preferences_store.dart`、`watch_candidates_store.dart`（新）、`path_helper.dart`、`watch_folder_service.dart` | 同轮多次 set* → **1 次**编码+写盘；写盘改 `await`（非阻塞）+ 串行化；队列迁到 `data/watch_candidates.json`（原子写/写合并/容错）+ prefs 旧键一次性迁移删除 |
| P0-4 | 排重索引预计算 + 零重规范化 | `import_dedup_index.dart` | 构建时缓存规范化路径；`check()` 内比较改前缀判定（原每候选 ≈3×库大小 次 `forCompare`，2000×2000 ≈ 1200 万次 → 0） |
| P0-5 | 扫描键缓存 + 消除 O(n²) 重量级比较 | `game_folder_scanner.dart` | `_DetectedGame` 缓存 `normalizedPath/segCount/titleKey`；阶段 3/4a/4b/4c/五 全改前缀比较（含自曝的 ≈800 万次正则 → ≈2000 次） |
| P0-6 | attrib 进程 → FFI `SetFileAttributesW` | `win32_file_attributes.dart`（新）、`game_data_format.dart` | 每游戏 2 次进程创建 → 0（FFI 失败自动回退 attrib，双保险） |
| P0-7 | 无界物化 → 流式 | `fs_scan.dart`（新）、`extract_manager.dart` | 解压链路 4 处改流式/提前中断，OOM 崩溃路径关闭 |
| P1-2（部分） | prefs 异步写 + 合并 | 同 P0-3 | 已达成 |
| P1-4（部分） | 截图队列背压上限 | `screenshot_fetch_service.dart` | 待处理任务 > 200 时跳过入队（改由闲时回填批次处理） |

### 9.2 验证结果

| 项 | 结果 |
|---|---|
| 静态检查（12 lib 文件 + 4 test 文件） | ✅ **0 新增问题**（28 条均为 `extract_manager`/`game_data_format` 存量） |
| 新增用例 | ✅ **14/14 通过**：prefs 写合并 3、候选队列存储 4、流式遍历 4、Win32 属性 FFI 3（真实 Windows 内核调用） |
| 全量回归 | ✅ **609 通过 / 0 失败**（零新增失败） |
| 语义保持 | ✅ `test/smart_import/` **93/93** 通过（P0-5 重构未改判定语义） |

### 9.3 未做（明确列出，非"遗忘"）

| 项 | 原因 |
|---|---|
| **P1-1 扫描/识别 isolate 化** | 需要回调重放 + 跨 isolate 数据搬运的重构，改动面大、回归风险高。**本轮已完成 P0-4/P0-5 把扫描的 O(n²) 与重量级字符串工作量降到可忽略，剩余成本是 `GalGameDetector.detect` 的同步 IO（约 6 万次 listSync）**。仍建议下一步单独立项（有 `_isUnderNorm` 前缀比较与缓存键打底，届时风险显著降低） |
| P1-3 批量事务化 + 断点续跑 | 涉及导入会话持久化与幂等设计，属独立功能 |
| P1-5 watch 策略重构 | 涉及监视语义变更（事件→脏子树），需真机长跑验证 |
| P2-1~P2-4 可观测性（失败清单/心跳看门狗/水位/大批量模式） | 属新增能力，非止血项；建议下一批 |
| P3-1~P3-3（统一 Job / 细粒度状态 / sqlite） | **架构级重写**。按 AGENTS.md「最小变更」与"稳定优先"，不建议与本轮止血混做 |

### 9.4 风险与回滚

- 所有改动均为**行为等价或更保守**的实现替换（合并写盘、前缀比较、流式遍历、FFI 带回退），未改变识别/去重/入库的业务语义。
- 回滚粒度：单文件 `git restore`；候选队列迁移为**一次性且向后兼容**（文件缺失时回退读 prefs 旧键）。
- 需真机验证项（自动化测不到）：2000 条扫描期间窗口流畅度、批量入库期间切页/切主题、导入中断后重启的队列自洽。
