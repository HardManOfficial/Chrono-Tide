# 汇总单：导入功能漏洞与 Bug 审查（问题清单 + 修复方案 + 状态）

| 项 | 值 |
|----|-----|
| **任务** | 审查导入功能的漏洞与 Bug（添加页单文件 / 批量 / 智能三条链路） |
| **审查方式** | 静态代码审阅 + 逐行交叉核对（**未改代码、未跑测试、未做真机复现**） |
| **提出日期** | 2026-09-12 |
| **状态** | 批 1–4（IMP-01/02/03/04/05/06/07/09/10/11/13/14/15/16/17/18/19/20/21）**已执行并通过验证**（§5.1.1–§5.1.4 / §7）；IMP-22（09-13 用户报告的排重缺陷）**当日修复**；余 1 项：IMP-12 批 B（isolate 化）待单独立项 |
| **关联文档** | `2026-09-12-import-source-file-loss.md`（源文件丢失事故专项调查） |
| **涉及文件** | `join_page.dart`、`join/join_controller.dart`、`join/batch_import_controller.dart`、`join/widgets/smart_import_section.dart`、`join/widgets/action_buttons.dart`、`join/utils/game_folder_scanner.dart`、`join/utils/gal_game_detector.dart`、`services/auto_import_pipeline.dart`、`services/watch_folder_service.dart`、`services/local_game_registry.dart`、`services/interrupt_cleanup.dart`、`services/extract_manager.dart`、`services/global_install_center.dart`、`core/portable_shared_preferences_store.dart`、`main_container.dart`、`pages/library_page.dart` |

---

## 0. 结论先行

- 共发现 **20 条问题**：数据安全类 8 条（含 **3 条 P0**）、功能正确性类 11 条、代码卫生类 1 条。
- **3 条 P0 全部与"用户本地文件"有关**，其中 `IMP-01` 能让应用**原地递归删除用户的游戏源目录**——这是本次审查的最高危发现。
- **20 条均已给出可落地修复方案**，并逐条说明验证方式（§4 覆盖确认、§5 验证结果）。
- ⚠️ **代码尚未改动**：本单只做汇总与方案。任何"已修复/已验证"的结论必须以执行后的 `analyze` + 测试 + 真机结果为准，本单不会编造测试结果。

---

## 1. 问题总览表

| ID | 级别 | 位置 | 现象 | 影响 |
|----|------|------|------|------|
| **IMP-01** | 🔴P0 | `local_game_registry.dart:1220-1223`；入口 `main_container.dart:368/492/522`、`library_page.dart:371`、`big_picture_shell.dart:480` | 库页/批量/BPM 删除游戏时勾选"同时删除本地文件"，对 `game.directoryPath` 裸执行 `Directory.delete(recursive: true)`；该路径对三条导入链路都是**用户自己的游戏文件夹** | **用户 300GB 级源目录被永久删除**（不进回收站、无归属校验、无审计日志）；对话框文案无法区分"应用安装的游戏"与"用户源目录" |
| **IMP-02** | 🔴P0 | `interrupt_cleanup.dart:278-311`（item2）、`:314-326`（item3）；触发 `custom_title_bar.dart:44-51` | 正常退出且有活动任务时，递归删除 `ExtractManager.actualGameDir`；校验**只看顶层** 4 种扩展名（`.exe/.ctgame/.xp3/.ks`）。item3 删 `targetGameDir` 时**完全无校验** | exe 位于 `bin/` 子目录的 GAL 目录会被误判"无游戏数据"→ **整目录递归删除**；自定义安装位置指向用户目录时后果同上 |
| **IMP-03** | 🔴P0 | `auto_import_pipeline.dart:283-291`；链 `join_controller.dart:334-347` → `join_page.dart:226-230`；调用点 `importCandidate:272`、`ignoreCandidate`、`ignoreAllCandidates`、`clearCandidates` | `cleanupTempCover` 对 `candidate.coverFilePath` 无条件下 `deleteSync()`；该字段可能是用户表单里选的**磁盘原图绝对路径** | 智能导入点 ✓入库 / ✗忽略 / 全部忽略 / 清空队列，会**删掉用户桌面或图片目录里的原图**。（批量导入同场景已有护栏，此处漏了） |
| **IMP-04** | 🟠P1 | `join_controller.dart:804-843`；对照 `extract_manager.dart:863-871` | `handleExtractSuccess` 在 `Games/<safeName>` 存在时**选它**当目标，只有不存在时才找 `_1.._99`；而解压器命名规则相反（base 存在→产物是 `_1`） | 同名压缩包二次导入：元数据写进**上一个**游戏目录（覆盖其简介/封面/标签），新解压目录无 `game.json` → **入库静默失败**；`_1.._99` 分支实为死代码 |
| **IMP-05** | 🟠P1 | `auto_import_pipeline.dart:211-212`；`local_game_registry.dart:1113`；`game_data_format.dart:930/958` | `metaDataDir = Games/<清洗后标题>`：若监控路径就是应用 `Games` 目录且标题与已有文件夹同名，则元数据目录 == 用户游戏目录；`updateGameTitle` 会对该目录 `rename` | 往用户游戏目录写 `.ctgame`(隐藏)/`game.json`/`cover.*`（**覆盖同名 cover.png**）；改标题时**把用户 300GB 文件夹改名搬走**（=用户口中的"被转移"） |
| **IMP-06** | 🟠P1 | `extract_manager.dart:1786-1812` | `_cleanupOnFailure` 步骤3 遍历 `targetDir` 顶层，删除**所有** `.rar/.zip/.7z/.tar`（仅排除当前压缩包），不比对来源/大小/mtime | 目标目录若与用户目录重叠，用户放在里面的原始压缩包被清空 |
| **IMP-07** | 🟠P1 | `process_cleanup_service.dart:42-53` 仅供正常退出调用；审计缺口见 `cleanup_utils.dart:140-145` | 强制关闭不执行 `ProcessCleanupService` → `7z/-y` 等子进程变孤儿继续写盘；且 `deleteGame` 与 `cleanupExtraction/startupScan` 用裸 `Directory.delete`，**不写 `data/cleanup_log.jsonl`** | 数据损坏无法归因、无法回溯；事故后没有现场证据 |
| **IMP-08** | 🟡P2 | `global_install_center.dart:792-812` | 清理"孤儿压缩包"时按 `文件名包含 gameId 或标题` + 24h 时间窗删除 `downloads/` 下压缩包 | 用户放在该目录、名字恰好撞上任务标题的原始压缩包被误删 |
| **IMP-09** | 🟠P1 | `join_page.dart:558-573`；按钮恒可用 `action_buttons.dart:80-84`；`batch_import_controller.dart:1370` | 处理队列仍在跑时可点"批量入库"；方法无 `isProcessingQueue` 守卫，末尾 `clearAll()` 置 `_isDisposed=true` 掐断处理循环 | 未处理完的游戏**既不入库也无任何提示**，队列被清空 |
| **IMP-10** | 🟠P1 | `join_controller.dart:80-98 / 274-278 / 763 / 923` | `_archiveExts`（17 项，含 `.iso`）驱动接受逻辑，`isArchiveType` 只认 5 项（`zip/rar/7z/tar/gz`） | `.iso/.xz/.bz2/.lz4/.zst/.cab/.arj/.lzma/.tar.bz2` **被 UI 接受、点入库必抛"不支持的文件类型"**（.iso 镜像在 GAL 中很常见） |
| **IMP-11** | 🟠P1 | `smart_import_section.dart:1384 / 1411`；`watch_folder_service.dart:913-972` | 入库与"全部入库"无重入守卫；`confirmAllCandidates` 在入口**同步快照** `toConfirm` 后才 await | 双击 → 对同一批候选各跑一遍 `importCandidate` → **重复写 game.json、重复注册库条目** |
| **IMP-12** | 🟠P1 | `game_folder_scanner.dart:418 / 552-570`；`gal_game_detector.dart:737`；`watch_folder_service.dart:644`；`portable_shared_preferences_store.dart:75` | UI isolate 上的同步阻塞：`detectLaunchExe` 的 `listSync(recursive:true)` 无上限；阶段五 `_hasSameParentGame` 对每对父子各扫 2 次（O(n²)）；每新增候选就 `jsonEncode` 全队列 + `writeAsStringSync` 整份设置文件 | 300GB 收藏 + 数百候选时窗口**长时间"未响应"**（分钟~小时级），用户只能强制关闭 → 触发 IMP-07 |
| **IMP-13** | 🟡P2 | `batch_import_controller.dart:1286-1295` | `for (int i=0; i<len; i+=2)` 循环体内做 `gamesToImport.removeWhere(...)` | 被删项位于 `i` 之前时后续元素前移，`skip(i)` **跳过一项** → 该游戏既不导入也不报告失败（随后被 `clearAll` 抹掉） |
| **IMP-14** | 🟡P2 | `batch_import_controller.dart:1370` | `submitBatchImport` 无论成败都 `clearAll()` | 失败/未完成的游戏无法重试，只能重新扫描 |
| **IMP-15** | 🟡P2 | `join_page.dart:83-97`（匿名闭包 addListener）；`:101-110`（dispose 未 removeListener） | 全局 `_batchImportController`（`main_container.dart:760` 传入）生命周期长于页面 | 离开添加页后其 notify 打到已卸载 State：`setState after dispose`、在废表单上触发网络封面下载、State 泄漏 |
| **IMP-16** | 🟡P2 | `smart_import_section.dart:1420-1432` | 提示语分母用 `actionableCandidates.length`（= ready **+ failed**），而实际只处理 `ready && !isHardDuplicate` | "批量入库完成 X/Y 成功"数字误导，用户以为失败项已被处理 |
| **IMP-17** | 🟡P2 | `batch_import_controller.dart:741-746`（注释）vs `:1093-1094`（实现） | 注释称"清除错误元数据，允许重新抓取"，实际 `metadata` 原样保留，而抓取函数见非空即 return | `retryGame` 不会重新抓取元数据，与 UI 预期不符 |
| **IMP-18** | ⚪P3 | `batch_import_controller.dart:440`、`:776-779`、`:753-755` | 处理中追加游戏也会置 `_isAwaitingConfirmation=true`，之后 `autoProcessNewGames` 永久早退 | `retryGame` 静默失效；预览确认条常驻不消失 |
| **IMP-19** | ⚪P3 | `gal_game_detector.dart:419-423` + `:259-274` | 负信号用**整条路径** `contains` 匹配（`origin`/`windows`/`microsoft`…） | 路径含 `Original`/`Origin` 等的合法游戏被记负信号扣分，可能漏识别 |
| **IMP-20** | ⚪P3 | `batch_import_controller.dart:1535`；`swipe_switcher.dart:151-173` | `_cleanupCompletedTasksCache` 无调用点；`_animateReset` 每次新建 AnimationController 且仅在动画完成时 dispose | 死代码；页面中途销毁会漏 ticker，debug 下触发断言 |
| **IMP-21** | 🟠P1 | `global_install_center.dart` `_rollback()` 步骤 3 | 云安装失败回滚会递归删除 `actualDir`（**只看顶层扩展名**）与 `targetDir`（**完全无校验**） | 与 IMP-02 同类：自定义安装位置指向用户目录时，失败回滚可整目录删除用户数据。⚠️ 批 3 期间新发现（批 2 审查时的遗漏项） |
| **IMP-22** | 🟠P1 | `game_folder_scanner.dart` 阶段四/五；`watch_folder_service.dart` 入队与启动 | 排重全部是**路径维度**：①同名但互不包含的目录零排重（`E:\GAL\远月少女的礼仪.1` 与 `远月少女的礼仪.2.1\远月少女的礼仪.1` 双双入队）；②阶段 2.5 救援父目录 append 在末尾，"子先父后"使父子重叠去重失效；③候选队列持久化且跨轮次只重评估 TTL 过期目录，入队防重无同名维度，历史重复**永久残留无自愈** | 同一游戏在不同嵌套层级被重复识别、重复入库（用户 09-13 报告 + 截图：ATRI 同名嵌套 65%/100% 两份、远月同题两份、子目录"1"与父同框）。⚠️ 09-13 用户报告后新发现，当日修复（见 DEV_LOG 同日条目） |

> **修复状态速览**：✅ **已修复并验证 19 条 + IMP-12 批 A + IMP-22** ——
> 批 1（`IMP-01`/`02`/`03`，§7.1）、批 2（`IMP-04`/`05`/`06`/`07`/`09`/`10`/`11`，§7.4）、
> 批 3（`IMP-08`/`13`/`14`/`15`/`16`/`17`/`21`，§7.6）、
> 批 4（`IMP-12` 批A + `IMP-18`/`19`/`20`，§7.7）、
> IMP-22（09-13 智能导入排重，独立提交，见 DEV_LOG 09-13）；
> ⏸ 唯一遗留：`IMP-12` 批 B（扫描/富化 isolate 化，需真机性能回归，单独立项）。

---

## 2. 逐条详情与修复方案

> 约定：所有方案均遵循 AGENTS.md「最小变更」——只改必要行，不动无关代码。
> 涉及 `lib/services/local_game_registry.dart`、`lib/main_container.dart` 等准稳定区的改动，执行前单独确认。

### IMP-01 🔴P0 `deleteGame` 递归删除用户源目录

**现象**：`deleteGame(title)` 取 `game.directoryPath` 做 `Directory.delete(recursive: true)`（`local_game_registry.dart:1220-1223`）。而 `directoryPath` 对三条导入链路分别是：智能导入 `candidate.dirPath`（`auto_import_pipeline.dart:229`）、批量导入 `game.folderPath`、单文件导入用户所选路径——**全部是用户自己的目录**。入口对话框（`main_container.dart:368-460`）只有一个默认未勾选的"同时删除本地文件"复选框，文案不区分来源，也不显示真实路径/大小。

**影响**：用户清理"导入残留"时勾选该框，300GB 源目录原地永久删除，且事后无法从日志证明（不走 `CleanupUtils`，无 `CleanupLog` 记录）；不进回收站。

**修复方案**
1. `deleteGame` / `removeGameRecordOnly` 落盘前统一加归属守卫：
   `if (!PathHelper.isInsideAppStorage(路径)) → 跳过自动删除`，返回"需用户手动处理"的结果并在 UI 明示路径。
2. 对话框按 `game.source`（`local_import` / `smart_import` / `download`）差异化：本地导入时标题改为「删除本地游戏文件」，正文列出**真实路径 + 目录大小**，并要求输入目录名二次确认。
3. 递归删除改走回收站（`SHFileOperation` + `FOF_ALLOWUNDO`），并写入 `CleanupLog`（`reason: user_delete_game_body`）。

**验证**：单测（守卫：应用目录内/外的分支）+ 真机：对一款本地导入游戏执行删除，确认源目录进回收站、`cleanup_log.jsonl` 有记录、应用外目录被拒绝自动删除。

---

### IMP-02 🔴P0 退出清理递归删除解压本体目录

**现象**：`InterruptCleanup._doCleanupActiveTaskResidue` item2（`interrupt_cleanup.dart:278-311`）对 `actualGameDir` 做"顶层有无 4 种扩展名"判断，不满足即 `CleanupUtils.deleteWithRetry`（→ `Directory.delete(recursive:true)`）；item3（`:314-326`）删 `targetGameDir` 时**无任何校验**。触发条件：正常退出且 `DownloadCore.hasActiveTask || ExtractManager.hasActiveTask`（`custom_title_bar.dart:44-51`）。

**影响**：exe 在 `bin/`、数据在子目录的 GAL 目录（结构常见）会被判"无游戏数据"→ 整目录删除；自定义安装位置指向用户目录时同理。

**修复方案**
1. item2：校验改**递归**（复用 `extract_manager` 的扩展名集合 + 体积阈值），并加 `PathHelper.isInsideAppStorage` 归属判定；不在应用自有目录内的**一律不删**。
2. item3：同样加归属判定（当前完全无校验）。
3. 退而求其次的更稳方案：退出清理只清理"本次会话明确登记过的任务路径"（落盘 `data/task_guard.json`），路径不匹配则跳过。
4. 删除动作写 `CleanupLog`。

**验证**：单测（构造"exe 在子目录"的假目录 → 断言不被删除）；真机：构造中断任务后正常退出，确认非应用目录不被触碰。

---

### IMP-03 🔴P0 `cleanupTempCover` 删除用户封面原图

**现象**：`auto_import_pipeline.dart:283-291` 对 `candidate.coverFilePath` 无条件下 `deleteSync()`；该字段可被 `join_page.dart:226-230 _saveSingleToCandidate` 写成用户表单里选的**原图绝对路径**（`join_controller.dart:334-347 pickCover` 不做复制、不校验归属）。

**影响**：智能导入的 ✓入库 / ✗忽略 / 全部忽略 / 清空队列 → 删掉用户桌面或图片目录里的原图，不可恢复。

**修复方案**
1. `cleanupTempCover` 加 `PathHelper.isInsideAppStorage(path)` 守卫（与 `batch_import_controller.dart:637-659` 完全对齐）。
2. 更彻底：`_saveSingleToCandidate` 回写前把用户选的封面**复制**到 `systemTemp/smart_cover_*` 再写入候选，使候选只持有临时副本。

**验证**：单测（候选 coverFilePath 指向应用外 → 断言文件仍存在）；真机：选一张桌面图片 → 入库 → 确认原图未被删。

---

### IMP-04 🟠P1 单文件解压同名重复导入元数据写错目录

**现象**：`join_controller.dart:804-843`——`Games/<safeName>` 存在就直接选它，反了（`extract_manager.dart:863-871 _resolveGameDir` 在 base 存在时产物是 `<name>_1`）；`_1.._99` 分支只有在 base 不存在时才进入，实为死代码。

**影响**：二次导入同名压缩包 → 元数据写进旧目录（覆盖其 description/cover/tags/developer），新目录无 `game.json` → 库页看不到，**入库静默失败**。

**修复方案**：不再猜路径。让 `ExtractManager` 在成功回调中回传 `_actualGameDir`，`handleExtractSuccess` 直接使用；过渡期可改为「取 `safeName` / `safeName_N` 中 mtime 最新、且晚于本次任务开始时间的目录」。

**验证**：单测（模拟 base 已存在 → 断言元数据落在 `_1`）；真机：同一压缩包连续导入两次，确认两次都能在库中看到且互不覆盖。

---

### IMP-05 🟠P1 元数据目录与源目录重叠（含 `updateGameTitle` 改名搬移）

**现象**：`metaDataDir` 由清洗后的标题拼成（`auto_import_pipeline.dart:211-212`），无任何"不得等于 `directoryPath`"的断言；`local_game_registry.dart:1113` 的 `oldDir.rename(newMetaDataDir)` 会重命名该目录；`game_data_format.dart:930` 还会给写入的 `.ctgame` 加隐藏属性。

**影响**：监控路径落在应用 `Games` 目录内且标题撞名时 → 向用户游戏目录写 `.ctgame`/`game.json`/`cover.*`（覆盖同名 `cover.png`）、写 `screenshots/`；改标题时把用户文件夹**改名搬走**（用户感知为"被转移"）。

**修复方案**：在 `importCandidate` / `createStandardGameDirectory` / `writeStandardGameInfo` 三处写入前加断言：`metaDataDir != directoryPath` 且二者不互为子目录；冲突时给 `metaDataDir` 追加 `_N`（与 `_resolveGameDir` 行为一致）。`updateGameTitle` 的 rename 前加同一断言，命中则拒绝 rename 并告警（保留游戏标题变更）。

**验证**：单测（构造 `metaDataDir == directoryPath` → 断言改用 `_1`）；真机：把监控路径指向 `Games` 目录导入一款游戏，确认源目录内不出现 `.ctgame`。

---

### IMP-06 🟠P1 失败回滚删除目标目录内所有压缩包

**现象**：`extract_manager.dart:1786-1812` 删除 `targetDir` 顶层所有 `.rar/.zip/.7z/.tar`，仅排除 `_currentArchivePath`。

**影响**：目标目录与用户目录重叠时清空用户压缩包；即使不重叠，也可能删掉用户自己放进元数据目录的原始压缩包。

**修复方案**：步骤3 改为只清理"本任务下载的压缩包"（比对记录中的绝对路径 + 大小 + mtime）；无法确认来源的一律保留并在日志中提示。

**验证**：单测（在目标目录放一个无关压缩包 → 断言保留）；真机：解压失败一次，检查目录内无关压缩包仍在。

---

### IMP-07 🟠P1 强制关闭孤儿进程 + 审计日志缺覆盖

**现象**：`ProcessCleanupService.cleanupAll()` 只在正常退出被调用（`custom_title_bar.dart:57-61`）；`deleteGame`、`InterruptCleanup.cleanupExtraction/startupScan` 使用裸 `Directory.delete`，不写 `data/cleanup_log.jsonl`。

**影响**：强制关闭后 `7z -y` 等子进程继续写盘（用户看到文件"自己变化/被覆盖"）；数据丢失无法归因，事故无法复盘。

**修复方案**
1. 启动时也执行一次残留进程清理（`taskkill` 同名 7z/bz/UnRAR/LRProc/openlist），与 `startupScan` 合并；
2. 所有删除路径统一经 `CleanupUtils`（或补 `CleanupLog.append`），记录 `target / bytes / reason`，`reason` 用固定枚举（`user_delete_game_body` / `exit_cleanup_*` / `startup_scan_*` / `rollback_*`）。

**验证**：单测（删除动作产生日志行）；真机：执行一次删除后在 `data/cleanup_log.jsonl` 中能查到该路径。

---

### IMP-08 🟡P2 孤儿压缩包按标题子串匹配删除

**现象**：`global_install_center.dart:792-812` 用 `name.contains(gameId) || name.contains(title)` + 24h 时间窗删除 `downloads/` 下的压缩包。

**影响**：用户放在该目录、名字撞上任务标题的原始压缩包被误删（应用自身也用该目录存压缩包，撞名概率不低）。

**修复方案**：改为比对"本任务下载记录中的确切文件名（含扩展名与大小）"，取消标题子串匹配。

**验证**：单测（同名文件但大小不符 → 不删）；真机：模拟重试一次，确认目录内无关压缩包保留。

---

### IMP-09 🟠P1 处理中可点"批量入库"，队列被掐断

**现象**：`action_buttons.dart:80-84` 批量模式 `canSubmit` 恒为 true；`join_page.dart:558-573` 无 `isProcessingQueue` 守卫；`batch_import_controller.dart:1370` 的 `clearAll()` 置 `_isDisposed=true`，掐断仍在跑的 `autoProcessNewGames`。

**影响**：未处理完的游戏既不入库也无提示，队列被清空。

**修复方案**：`_submitBatchImport` 入口加 `if (_batchController.isProcessingQueue) { 提示"正在处理中，请稍候" ; return; }`；`ActionButtons` 增加 `enabled` 参数，处理中禁用提交（灰化 + Tooltip 说明）。

**验证**：单测/真机：处理中点击"批量入库"，确认弹出提示且队列与处理流程不受影响。

---

### IMP-10 🟠P1 压缩包白名单不一致（`.iso` 等必失败）

**现象**：`_archiveExts`（`join_controller.dart:80-98`，17 项含 `.iso`）驱动 `isArchiveExt`/`detectFileType`，`isArchiveType`（`:274-278`）只认 5 项；`submitAddGame:763` 用后者分流，最终 `:923` 抛"不支持的文件类型"。

**影响**：`.iso/.xz/.bz2/.lz4/.zst/.cab/.arj/.lzma/.tar.bz2` 被 UI 接受（标题都填好了），点入库必失败且提示误导。

**修复方案**：抽出唯一常量 `kArchiveExtensions`（含全部受支持格式），`isArchiveExt` / `isArchiveType` / `detectFileType` 共用；对**解压器不支持的格式**（如 iso 未接入）在**选择文件时**即提示，不再等到提交。

**验证**：单测（各扩展名 → 三个函数判定一致）；真机：选一个 `.iso`，确认即时给出明确提示。

---

### IMP-11 🟠P1 智能导入入库无重入守卫

**现象**：`smart_import_section.dart:1384 _confirmCandidate` / `:1411 _confirmAllCandidates` 无 in-flight 标志；`WatchFolderService.confirmAllCandidates`（`:913-972`）在入口同步快照 `toConfirm` 后 await。

**影响**：双击 → 同一批候选被 `importCandidate` 跑两遍（重复写 `game.json`、`registerExtractionComplete` 两次）。

**修复方案**：`_SmartImportSectionState` 加 `bool _confirming`（入口置位、`finally` 复位，按钮禁用）；服务侧 `confirmAllCandidates` 加 `_isImportingAll` 互斥，重入直接返回 0。

**验证**：单测（并发调用只处理一次）；真机：快速双击"全部入库"，确认库中无重复条目。

---

### IMP-12 🟠P1 "未响应"：UI isolate 同步全树扫描 + 整份设置同步重写

**现象**：
- `game_folder_scanner.dart:418` `listSync(recursive: true)` 无上限；
- `:552-570 _hasSameParentGame` 对每对父子各扫 2 次 → O(n²)；
- `gal_game_detector.dart:737` 同步两层 `listSync`；
- `watch_folder_service.dart:644` 每个候选一次 `_saveCandidates()` → `portable_shared_preferences_store.dart:75` 的 `writeAsStringSync` 重写整份 prefs（候选队列含完整 metadata）。

**影响**：300GB 收藏 + 数百候选 → 窗口分钟~小时级冻结，用户只能强制关闭（进而触发 IMP-07）。

**修复方案**（分两批，先低风险）
- 批 A：`detectLaunchExe` 加**深度/条数上限** + 结果缓存（按目录 mtime 失效）；`_hasSameParentGame` 复用缓存；候选持久化加 2s 防抖并改 `writeAsString`（异步）；`GalGameDetector` 上限提前生效。
- 批 B（单独排期）：把扫描/富化搬出 UI isolate（`Isolate.run`），主 isolate 只收结果。

**验证**：新增性能回归单测（构造大目录 → 断言耗时/调用次数上限）+ 可观测计数；真机：300GB 级目录导入时不出现长时间"未响应"。

---

### IMP-13 🟡P2 `submitBatchImport` 循环内 `removeWhere` 跳项

**现象**：`batch_import_controller.dart:1286-1295` 在按索引推进的循环体内删除元素。

**影响**：删项位于 `i` 之前时后续元素前移 → `skip(i)` 跳过一个游戏，既不导入也无失败记录（随后被 `clearAll` 抹掉）。

**修复方案**：改为在循环开始前一次性 `gamesToImport.removeWhere(...)`（或在循环外先冻结 `_cancelledTasks` 快照并按 id 过滤），循环体不再修改列表。

**验证**：单测（3 个游戏、分批 2、循环中取消第 1 个 → 断言全部被处理且无跳项）。

---

### IMP-14 🟡P2 入库后 `clearAll()` 抹掉失败项

**现象**：`batch_import_controller.dart:1370` 无论成败都清空。

**影响**：失败项无法重试，用户只能重扫整个监控目录。

**修复方案**：`clearAll()` 改为只移除"已成功入库"的条目；失败/未处理项保留并在总结中明示（"保留 N 个失败项，可重试"）。

**验证**：单测（1 成功 1 失败 → 断言列表剩 1 条且 `taskStatus==failed`）。

---

### IMP-15 🟡P2 JoinPage 泄漏全局批量控制器监听

**现象**：`join_page.dart:83-97` 用匿名闭包 `addListener`，`dispose`（`:101-110`）未 `removeListener`；控制器由 `main_container.dart:760` 持有。

**影响**：离开添加页后控制器 notify → 已卸载 State 收到回调：`setState after dispose`、在废表单上发起网络封面下载、State 无法回收。

**修复方案**：把闭包提为字段 `_onBatchChanged`，`dispose` 中 `_batchController.removeListener(_onBatchChanged)`。

**验证**：单测（页面 dispose 后触发 notify → 无异常、无网络调用）；真机：切页后批量任务继续跑，观察无异常日志。

---

### IMP-16 🟡P2 "批量入库完成 X/Y" 分母含失败项

**现象**：`smart_import_section.dart:1420-1432` 分母用 `actionableCandidates.length`（ready + failed），实际处理的是 `ready && !isHardDuplicate`。

**影响**：数字误导（例：3 就绪 + 5 失败 → 提示"3/8 成功"，用户以为 5 个失败项已被处理）。

**修复方案**：分母改用"本次实际尝试数"（由服务返回 `(success, attempted)`，或此前先算 `ready && !isHardDuplicate` 的数量），并在文案中说明"失败项请逐个重试"。

**验证**：单测（断言返回的 attempted 数）；真机：混合 ready/failed 场景核对提示数字。

---

### IMP-17 🟡P2 `retryGame` 注释与实现不符

**现象**：`batch_import_controller.dart:741-746` 注释称"清除错误元数据，允许重新抓取"，实际 `metadata` 原样保留；`fetchSingleGameMetadata:1093-1094` 见非空即 return。

**影响**：重试不会重新抓取，与用户预期不符（点重试后数据纹丝不动）。

**修复方案**：二选一并保持一致——(a) `retryGame` 清空 `metadata`/`metadataTitle`/`isHardDuplicate` 以真正重抓（推荐，与智能导入 `retryCandidate` 行为对齐）；(b) 保留现行为并改正注释与按钮文案。

**验证**：单测（重试后 `metadata == null` → 触发抓取）；真机：对失败项点重试，确认重新请求元数据。

---

### IMP-18 ⚪P3 `_isAwaitingConfirmation` 可能永久为 true

**现象**：`batch_import_controller.dart:440` 处理中追加游戏也会置位；`autoProcessNewGames:776-779` 入口早退；`retryGame:753-755` 因此静默失效。

**影响**：重试无效；预览确认条常驻。

**修复方案**：`confirmAndProcess` 完成后复位该标志；或把早退条件改为"存在待处理游戏则继续"。同时在预览条只在 `!isProcessingQueue && hasGames` 时显示。

**验证**：单测（追加游戏 → 处理完成 → 断言标志复位、retry 生效）。

---

### IMP-19 ⚪P3 识别器系统路径负信号整串匹配

**现象**：`gal_game_detector.dart:419-423` 用 `fullPathLower.contains(pattern)`（`origin`/`windows`/`microsoft`/`.git`…）。

**影响**：路径含 `Original`/`Origin`/`Windows` 字样的合法游戏被扣分，可能漏识别。

**修复方案**：改为按路径**分段**匹配（`p.split(path)` → 段级 `startsWith`/精确比较）；`origin` 等易误伤的关键词改精确段匹配。

**验证**：单测（`D:\GAL\Original\…`、`D:\games\windows_no_naka\…` → 断言负信号不成立）。

---

### IMP-20 ⚪P3 死代码与 ticker 泄漏

**现象**：`batch_import_controller.dart:1462 _cleanupCompletedTasksCache` 无调用点；`swipe_switcher.dart:151-173 _animateReset` 每次新建 `AnimationController`，仅靠 `AnimationStatus.completed` 释放。

**影响**：死代码堆积；页面在 200ms 动画中销毁 → ticker 泄漏，debug 下断言报错。

**修复方案**：删除无调用的私有方法（先全库确认 0 引用）；`_animateReset` 复用成员 `_animationController` 或在 `dispose` 中兜底释放。

**验证**：`flutter analyze` 无新增告警；单测（在动画中 dispose → 无异常）。

---

## 3. 执行批次建议（供批准时选择）

| 批次 | 内容 | 风险 | 说明 |
|------|------|------|------|
| **批 1（P0 数据安全）** | IMP-01 / 02 / 03 | 低（均为加守卫与文案，逻辑不变） | 直接消除"删用户文件"的三条路径，**建议最先做** |
| **批 2（P1 数据安全 + 正确性）** | IMP-04 / 05 / 06 / 07 / 09 / 10 / 11 | 中（IMP-05 涉及注册表断言、IMP-04 需回传路径） | 一次一条，逐条提交 |
| **批 3（P2）** | IMP-08 / 13 / 14 / 15 / 16 / 17 | 低 | 可合并为 2–3 个提交 |
| **批 4（P3 + 性能）** | IMP-19 / 20 + IMP-12 批A | 低 | 与功能修复解耦 |
| **批 5（架构）** | IMP-12 批B（isolate 化） | 中高 | **单独立项**，需真机性能回归 |

---

## 4. 覆盖确认（逐条确认"方案是否闭环"）

| ID | 方案闭环 | 残留风险 / 备注 |
|----|----------|-----------------|
| IMP-01 | ✅ 闭环（守卫 + 差异化确认 + 回收站 + 审计） | 回收站在某些受限环境不可用时降级为"拒绝删除"，需用户手动处理 |
| IMP-02 | ✅ 闭环（递归校验 + 归属守卫 + 任务登记） | 任务登记依赖正常退出时落盘；异常退出仍靠"归属守卫"兜底 |
| IMP-03 | ✅ 闭环（守卫 + 复制到临时目录） | 用户原图保留；应用临时封面可能残留（可接受，与既有约定一致） |
| IMP-04 | ✅ 闭环（回传实际目录） | 过渡期 mtime 方案在极端时钟漂移下可能选错，回传方案无此问题 |
| IMP-05 | ✅ 闭环（写入前断言 + rename 前断言） | 已存在的历史冲突目录不会被自动修复，需提供一次性检查工具（可另立） |
| IMP-06 | ✅ 闭环（只删本任务压缩包） | 若历史记录缺失，退化为"不删"，安全侧 |
| IMP-07 | ✅ 闭环（启动补清理 + 全路径审计） | 启动清理需避免误杀用户自行运行的 7z（限本应用 runtime 目录下的副本） |
| IMP-08 | ✅ 闭环（改为确切实名匹配） | 旧版本产生的孤儿压缩包不再被自动清理（需手动） |
| IMP-09 | ✅ 闭环（守卫 + 按钮禁用） | — |
| IMP-10 | ✅ 闭环（单一白名单 + 提前报错） | 若后续接入 iso 解压，需同步扩展白名单与解压分支 |
| IMP-11 | ✅ 闭环（双层互斥） | — |
| IMP-12 | ⚠️ 部分闭环（批A 缓解，批B 才根治） | 批A 后仍有"单目录超大树"导致的秒级卡顿，需 isolate 化彻底解决 |
| IMP-13 | ✅ 闭环（循环外过滤） | — |
| IMP-14 | ✅ 闭环（只清成功项） | 需同步调整批量取消按钮语义（"清空列表"改为"清空已完成"） |
| IMP-15 | ✅ 闭环（精确 removeListener） | — |
| IMP-16 | ✅ 闭环（分母改为实际尝试数） | — |
| IMP-17 | ✅ 闭环（行为与注释二选一，推荐重抓） | 重抓会覆盖用户已手改的字段，需仅在未锁定字段上生效 |
| IMP-18 | ✅ 闭环（标志复位） | — |
| IMP-19 | ✅ 闭环（段级匹配） | 需回归验证误拦率不上升 |
| IMP-20 | ✅ 闭环（删死代码 + 释放控制器） | 删除前需 grep 确认 0 引用 |

**总计：20/20 已给出闭环方案，其中 IMP-12 明确标注为"需两批、批B 根治"。**

---

## 5. 验证结果

### 5.1 本轮（审查轮）实际做了什么验证

| 项 | 结果 |
|----|------|
| 代码级交叉核对 | ✅ 已完成：报告中引用的每条结论均以 `文件:行号` 复核过（如 `local_game_registry.dart:1220-1223`、`interrupt_cleanup.dart:278-311`、`extract_manager.dart:1786-1812`、`auto_import_pipeline.dart:283-291`） |
| `flutter analyze` | ❌ 未执行（未改代码，无新增 error 可言） |
| `flutter test` | ❌ 未执行 |
| 真机复现 | ❌ 未执行（本机无 300GB 素材与用户现场） |
| 事故取证 | ❌ 未进行（需在受影响机器上取 `cleanup_log.jsonl` / `extract_*.txt` / prefs） |

> **因此：本单不含任何"已验证修复"的结论。** 20 条问题的性质是"静态审阅确认的代码缺陷"，其运行时表现需按 §5.2 验收。

### 5.1.1 批 1 执行后的验证结果（2026-09-12，已完成）

| 验证项 | 命令 / 方式 | 结果 |
|--------|-------------|------|
| 静态检查 | `flutter analyze`（4 个改动文件） | ✅ **0 新增问题**：报出 18 条全部位于本次未触碰的行（含 2 条 `main_container.dart:567` 的存量 info、`local_game_registry.dart` 的存量 warning），无新增 error |
| 新增用例 | `flutter test test/services/import_data_safety_guard_test.dart` | ✅ **10/10 通过**（IMP-01 三条、IMP-02 三条、IMP-03 三条 + 1 条前提断言） |
| 全量回归 | `env -u HTTP_PROXY … flutter test` | ✅ **432 通过 / 0 失败**（含新增 10 条；跑前基线 422/0，**零新增失败**） |
| 运行期日志实证 | 测试输出 | ✅ 三条护栏日志各命中一次：<br>`[删除]   ⛔ 跳过删除游戏本体(位于应用自有目录之外…)`<br>`[INTERRUPT-CLEANUP]   ⛔ 跳过删除实际解压目录(位于应用自有目录之外)`<br>`[AUTO-IMPORT] ⏭️ 跳过非应用目录封面(可能是用户原图)` |
| 行为不回退 | 同文件正向用例 | ✅ 应用目录内的本体照常删除；`bin/Game.exe` 结构被递归判定为"含游戏数据"而保留；无游戏数据的半成品残留仍被清理；应用目录内的临时封面仍被清理 |
| 改动面 | `git status --short` + `git diff --stat` | ✅ 仅 4 个代码文件 +135/-18，无计划外文件 |

新增测试文件：`test/services/import_data_safety_guard_test.dart`（路径隔离用 `PathHelper.exeDirOverride`；
"应用外目录"建在 `.dart_tool/` 下，因为 `isInsideAppStorage` 白名单包含系统临时目录，
且测试内先断言该前提成立）。

> ⚠️ **仍未做**：真机验证（本机无 300GB 素材）与事故现场取证。
> 三项护栏均为"拒绝删除"型改动，无法通过单测覆盖真机的交互路径（确认框文案、SnackBar 回执）。

### 5.1.2 批 2 执行后的验证结果（2026-09-12，已完成）

| 验证项 | 命令 / 方式 | 结果 |
|--------|-------------|------|
| 静态检查 | `flutter analyze`（10 个改动文件） | ✅ **0 新增问题**：报出 50 条全部位于本次未触碰的行；且批 1 遗留的 `join_controller.dart:859 unnecessary_non_null_assertion` 因结构简化而**消失** |
| 新增用例 | `flutter test test/services/import_pipeline_fix_test.dart` | ✅ **11/11 通过**（IMP-04 三条、IMP-05 四条、IMP-09 两条、IMP-10 一条、IMP-11 一条） |
| 全量回归 | `env -u HTTP_PROXY … flutter test` | ✅ **443 通过 / 0 失败**（含批 1 的 10 条 + 批 2 的 11 条；跑前基线 432/0，**零新增失败**） |
| 关键行为实证 | 测试日志 | ✅ IMP-11 并发调用：日志出现 `[WATCH] ⚠️ 批量入库已在进行中，忽略重复请求`，结果一为 `1`（真正入库）一为 `0`（被互斥挡下）；<br>✅ IMP-05：冲突场景下用户目录**未被改名**、非冲突场景仍照常重命名；<br>✅ IMP-05：应用目录外的既有 `cover.png` 内容保持不变 |
| 改动面 | `git status --short` + `git diff --stat` | ✅ 仅 10 个代码文件 + 1 个测试文件，无计划外文件 |

新增测试文件：`test/services/import_pipeline_fix_test.dart`。

> ⚠️ **无自动化用例的 2 条（如实说明）**：
> - `IMP-06`（失败回滚不再扫目录删压缩包）：依赖解压失败流程与私有任务状态，单测需真实压缩包与子进程，成本远高于收益 → 以**代码审阅**确认（`_taskOwnedTempArchives` 仅登记本任务自建中间包，集合为空则什么都不删）。
> - `IMP-07` 的"启动时清理残留解压进程"部分：依赖真实孤儿进程，无法在单测中构造 → 以**代码审阅**确认（仅终止 `PathHelper.runtimeDir` 下的副本）。
> 其余仍**未做真机验证**。

### 5.1.3 批 3 执行后的验证结果（2026-09-12，已完成）

| 验证项 | 命令 / 方式 | 结果 |
|--------|-------------|------|
| 静态检查 | `flutter analyze`（5 个改动文件） | ✅ **0 新增问题**：报出 13 条全部位于未触碰的行（`join_page.dart` / `smart_import_section.dart` / `interrupt_cleanup.dart` 均为 0 条） |
| 新增用例 | `flutter test test/services/import_batch_fix_test.dart` | ✅ **4/4 通过**（IMP-13 三条、IMP-16 服务层口径一条） |
| 全量回归 | `env -u HTTP_PROXY … flutter test` | ✅ **447 通过 / 0 失败**（跑前基线 443/0，零新增失败；首轮曾出现 1 次 flaky，见下） |
| 改动面 | `git status --short` + `git diff --stat` | ✅ 5 个代码文件 + 1 个测试文件，无计划外文件 |

> ⚠️ **flaky 说明（非本次改动引入）**：批 3 首轮全量出现过 1 次失败（`test/smart_import/`
> 目录，446/1），复跑全绿（447/0）。定向复测：`watch_folder_service_test.dart` **单跑
> 3×23 全绿**、该文件不触及任何批 1/2/3 修改的代码路径（`confirmAllCandidates` /
> `isImportingAll` 不在其中），且与 2026-09-07 起既有记录的
> 「watch_folder 并发全量下偶发 flaky，单跑全过」签名一致 → 判定为**既有测试隔离问题**。
> 已在 §7.6 列为批 5 后的改进项（测试隔离/去 flaky，单独排期）。

> ⚠️ **无自动化用例的 4 条（如实说明）**：`IMP-08`、`IMP-15`、`IMP-17`、`IMP-21` 依赖
> 私有任务状态（`_games` / `_rollback` 私有方法 / 页面 widget 树）或真实回滚流程，
> 现有代码没有测试注入口 → 以**代码审阅**确认，并把「`BatchImportController` 缺少
> 测试接缝」记入 §7.6 遗留。`IMP-13` 通过提取纯函数 `takeNextImportBatch` 获得可测性。

### 5.1.4 批 4 执行后的验证结果（2026-09-12，已完成）

| 验证项 | 命令 / 方式 | 结果 |
|--------|-------------|------|
| 静态检查 | `flutter analyze`（5 个改动文件 + 1 个测试文件） | ✅ **0 新增问题**（9 条均为存量，且与批 3 轮相同） |
| 新增用例 | `gal_game_detector_test.dart` 新增 IMP-19 组（2 条） | ✅ **34/34 通过**（原 32 条 + 新 2 条），连续两轮全绿 |
| 导入区回归 | 4 个导入相关测试文件合跑 | ✅ 10/11/4/34 全部通过 |
| 全量回归 | `env -u HTTP_PROXY … flutter test` | ✅ **458 通过 / 0 失败**（新基线） |
| 改动面 | `git status --short` + `git diff --stat` | ✅ 5 个代码文件 + 1 个测试文件（含 1 处测试基建修复），无计划外文件 |

**基线计数说明**：批 3 的 447 中，`gal_game_detector_test.dart` 因固定共享路径的
跨运行删除竞态（setUpAll 报 `PathNotFoundException`）未能完整计入其 34 条用例；
批 4 修复该测试基建问题（改为每次运行唯一目录）后，基线为 **458/0**。

> ⚠️ **IMP-12 批 A 的验证边界（如实说明）**：性能缓解效果（缓存命中、防抖合并）
> 需要 300GB 级真实目录才能量化，**本机未做性能实测** —— 单测只能验证行为正确性
> （缓存命中后结果一致、防抖后仍会落盘）与回归保护。真机性能对比列入验收清单。
> `IMP-18`（标志复位）与 `IMP-20`（ticker 释放）同样依赖私有状态/页面销毁时序，
> 无自动化用例，以代码审阅确认。

### 5.2 修复后的验收流程（每批执行后必须走完）

1. **静态检查**（只针对改动文件）：
   `./flutter/bin/flutter.bat analyze lib/services/local_game_registry.dart lib/services/interrupt_cleanup.dart …`
   要求：**0 新增 error**（基线 ~565 条 info/warning 属正常）。
2. **单元测试**（必须加 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy` 前缀，否则 flutter_tester 的 WebSocket 会被代理劫持导致假失败）：
   `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test test/`
   基线：**458 通过 / 0 失败**（2026-09-12 执行批 4 后的新基线；批 3 后名义 447/0，
   但其中 `gal_game_detector_test` 因测试基建竞态少计约 11 条 → 实际 447 已含该缺口；
   批 2 后 443/0、批 1 后 432/0、最早 422/0）。
   要求：零新增失败 + 每条 IMP 至少 1 个针对性用例。
3. **改动面自查**：`git status --short` + `git diff --stat`，确认没有计划外文件。
4. **真机验收点**（按批次挑选）：
   - 批1：① 删除本地导入游戏并勾选"同时删除本地文件" → **源目录原封不动**；确认框应出现"应用不会删除该目录（应用目录之外）"提示，删除后回执变为"本地文件未删除…请手动处理"；② 智能导入选桌面图片当封面 → 入库后原图仍在；③ 构造中断任务后正常退出 → 用户目录未被触碰。
   - 批2：④ 同一压缩包连续导入两次 → 两次都入库且互不覆盖；⑤ 监控路径指向 `Games` 目录导入 → 源目录内不出现 `.ctgame`；⑥ 处理中禁用"批量入库"；⑦ 选 `.iso` 得到明确提示；⑧ 快速双击"全部入库" → 无重复条目。
   - 批4：⑨ 300GB 级目录导入期间窗口保持可响应（对比修复前表现）。
5. **记录更新**：`docs/DEV/DEV_LOG.md` 追加条目、`docs/DEV/SESSION_HANDOFF.md` 更新进度、必要时补功能档案；一个批次一个提交（只 `git add` 显式文件）。

---

## 6. 执行状态

| 项 | 状态 |
|----|------|
| 问题定位 | ✅ 20/20 完成 |
| 修复方案 | ✅ 20/20 已给出 |
| 方案闭环确认 | ✅ 19 条完全闭环，IMP-12 需两批（已标注） |
| **批 1 代码修改（IMP-01/02/03）** | ✅ **已执行**（4 文件 +135/-18，详见 §7.1） |
| **批 2 代码修改（IMP-04/05/06/07/09/10/11）** | ✅ **已执行**（10 文件，详见 §7.4） |
| **批 3 代码修改（IMP-08/13/14/15/16/17/21）** | ✅ **已执行**（5 文件，详见 §7.6） |
| **批 4 代码修改（IMP-12 批A + IMP-18/19/20）** | ✅ **已执行**（5 文件，详见 §7.7） |
| **批 1+2+3+4 验证** | ✅ analyze 0 新增 / 新增用例 27 条全过 / 全量 458 通过 0 失败 |
| 真机验收 | ⏸ 待你在真机走一遍 §5.2 各批验收点（重点：批 4 的性能对比） |
| 批 5（IMP-12 批B：isolate 化） | ⏸ 单独立项，需真机性能回归 |

> 依据 AGENTS.md §2.2「两段式流程」，阶段 B 需在你批准后执行；
> 且 §2.1 要求"一次任务只解决一个问题"，故建议按 §3 的批次推进，而不是一次性全改。

---

## 7. 批 1 执行记录与偏差说明（2026-09-12）

### 7.1 改动清单

| 文件 | 改动 | 对应问题 |
|------|------|----------|
| `lib/services/local_game_registry.dart` | 新增 `_skippedBodyPaths` / `skippedBodyPaths` / `canDeleteGameBody()` / `gameBodyPath()`；`deleteGame` 在删除"游戏本体"前加 `PathHelper.isInsideAppStorage` 护栏，越界即跳过并记录；`removeGameRecordOnly` 清空跳过记录避免陈旧值 | IMP-01 |
| `lib/main_container.dart` | 删除确认框新增"本体在应用目录之外 → 应用不会删除该目录"红色提示（含真实路径）；单条删除回执按"是否被跳过"区分 warning / success；批量删除汇总同样区分 | IMP-01 |
| `lib/services/interrupt_cleanup.dart` | 退出清理 item2/item3 均加 `PathHelper.isInsideAppStorage` 护栏；新增 `_gameDataExtensions` 白名单与 `_hasGameDataRecursively()`，游戏数据判定由"顶层 4 种扩展名"改为**递归**判定，异常时保守保留 | IMP-02 |
| `lib/services/auto_import_pipeline.dart` | `cleanupTempCover` 加 `PathHelper.isInsideAppStorage` 护栏，非应用目录封面只解除引用不删除 | IMP-03 |
| `test/services/import_data_safety_guard_test.dart` | 新增 10 条护栏回归用例（含正向"行为不回退"对照） | 全部 |

### 7.2 与方案文档的偏差（如实说明）

| 项 | 方案原文 | 实际做法 | 原因 |
|----|----------|----------|------|
| IMP-01 回收站 | §7 建议改用 `SHFileOperation` + `FOF_ALLOWUNDO` | ❌ **未实现**，改为"应用目录之外一律拒绝删除" | 引入 FFI/COM 属非最小变更且失败路径难验证；护栏已从根本上消除"应用删用户文件"的路径（比回收站更强，回收站仍会移动用户文件） |
| IMP-01 文案差异化 | §7 建议按 `game.source` 区分并二次确认 | ⚠️ **部分实现**：加了"应用目录之外不会删除"的路径级提示；未按 `source` 分级、未加输入型二次确认 | 路径级判定比 `source` 更准确（同源游戏也可能装在应用目录内）；输入型二次确认留待批 2 与 IMP-05 一并做 |
| IMP-03 复制到临时目录 | §7 建议"候选只持有临时副本" | ❌ **未实现**，仅做归属护栏 | 护栏已消除数据丢失；封面入库路径（`writeGameDir` 复制）不受影响，属可选加固 |
| IMP-02 影响面 | — | ⚠️ **行为变化**：用户自定义安装位置（应用目录之外）的半成品残留，退出时不再自动清理 | 这是 P0 修复的必然代价（宁可残留，不可误删），已在 §4 覆盖确认中标注 |

### 7.3 结论

- 批 1 的 3 条 P0 已**从代码层面关闭**：应用不再存在"自动递归删除用户自有目录"的路径。
- 遗留的两类风险已在文档中明示：① 真机交互未验证；② IMP-01 的"按来源分级 + 二次确认"、IMP-03 的"临时副本"属可选加固，未在批 1 实施。

---

## 7.4 批 2 执行记录（2026-09-12）

### 7.4.1 改动清单

| 文件 | 改动 | 对应问题 |
|------|------|----------|
| `lib/pages/join/join_controller.dart` | ① 新增 `_lastExtractTargetDir`：在**解压成功回调瞬间**捕获 `ExtractManager.targetGameDir`；② 新增静态 `resolveExtractionTargetDir()`（捕获值 → 回传值 → **null 不猜测**），`handleExtractSuccess` 以其替代"猜 base / `_1..99`"，取不到可信目录时**跳过写入并提示用户**；③ `isArchiveType` 改为复用 `isArchiveExt`（统一 17 项白名单） | IMP-04、IMP-10 |
| `lib/services/watch_folder_service.dart` | 新增 `_isImportingAll` 互斥锁，`confirmAllCandidates` 用 try/finally 包裹（异常也释放），重入直接返回 0 | IMP-11 |
| `lib/pages/join/widgets/smart_import_section.dart` | 新增 `_isConfirming` 标志：`_confirmCandidate` / `_confirmAllCandidates` 入口守卫 + "全部入库"按钮进入进行中态（禁用 + 半透明） | IMP-11 |
| `lib/pages/join/widgets/action_buttons.dart` + `lib/pages/join_page.dart` | `ActionButtons` 新增 `submitEnabled`（默认 true）；批量模式提交可用性由该参数决定；`_submitBatchImport` 增加 `isProcessingQueue` 守卫并提示"正在抓取元数据" | IMP-09 |
| `lib/services/game_data_format.dart` | `_saveCoverFile` 增加护栏：目标目录在应用自有目录之外（=与用户源目录重叠）时**不覆盖既有封面** | IMP-05 |
| `lib/services/local_game_registry.dart` | 新增 `_metaFallsInsideBodyDir()`（**只判"元数据目录在本体目录内或相同"，刻意不反向**，以免误伤云端安装"本体在元数据目录之下"的合法布局）；`updateGameTitle` 命中即跳过目录重命名；`removeGameRecordOnly` 命中即跳过删除 `.ctgame/game.json/cover.*`；`deleteGame` 本体删除改走 `CleanupUtils`（补审计） | IMP-05、IMP-07 |
| `lib/services/extract_manager.dart` | 新增 `_taskOwnedTempArchives`：`_extractLz4` 登记自建中间包；失败回滚"步骤3"由"扫目录删所有 `.rar/.zip/.7z/.tar`"改为**只删登记项**（为空则什么都不删） | IMP-06 |
| `lib/services/interrupt_cleanup.dart` | 5 处目录删除改走 `CleanupUtils.deleteWithRetry` 并带 `reason`（落 `data/cleanup_log.jsonl`）；`startupScan` 开头 fire-and-forget 调用残留进程清理 | IMP-07 |
| `lib/services/process_cleanup_service.dart` | 新增 `killResidueFromAppDir()`：按**可执行文件路径**过滤，只终止 `PathHelper.runtimeDir` 下的 `7z/7za/bz/UnRAR/lz4`（不会误杀用户自装的解压工具） | IMP-07 |
| `test/services/import_pipeline_fix_test.dart` | 新增 11 条回归用例 | 全部 |

### 7.4.2 与方案文档的偏差（如实说明）

| 项 | 方案原文 | 实际做法 | 原因 |
|----|----------|----------|------|
| IMP-04 兜底 | §7 建议"取 `safeName`/`safeName_N` 中 mtime 最新" | ❌ **改为不猜测**：捕获值 → 回传值 → null（提示用户） | **实测 Windows 目录时间戳只有秒级精度**（`.dart_tool/probe_mtime.dart` 实证：40ms 间隔的三个目录，前两个时间戳完全相同）→ mtime 判据在同秒副本间完全失效，会把元数据写到错误目录。宁可不写也不写错 |
| IMP-04 主路径 | 由 `ExtractManager` 回传 `_actualGameDir` | ⚠️ **用 `targetGameDir`**（元数据目录） | `_actualGameDir` 是**游戏本体**目录（默认位于 `<元数据目录>/<标题>` 之下），而这里要写的是元数据目录 |
| IMP-05 | §7 建议"冲突时给 metaDataDir 追加 `_N`" | ❌ 未采用；改为**禁止冲突时的危险操作**（重命名 / 覆盖封面 / 删元数据文件） | 注册表以 `metaDataDir == Games/<safeName(title)>` 为不变量（`_games` 的 key 即目录名），单独改目录名会让 `scan()` 重新注册出重复条目 |
| IMP-07 审计 | §7 建议"所有删除路径统一写 CleanupLog" | ⚠️ **覆盖了目录级删除**（`deleteGame` 本体 + `interrupt_cleanup` 的 5 处目录删除）；`cleanupDownloads` 的临时文件删除未改 | 后者只作用于应用自己的 `downloads/` 且仅删 `.tmp`/分片，风险与价值都低，避免扩大改动面 |
| IMP-09 取消按钮 | §7 只提到提交 | ⚠️ 未处理"处理中点取消"（仍会 `clearAll` 掐断队列） | 取消是用户的明确中止意图，与"误点"不同；已在 §7.5 列为遗留 |

### 7.5 批 2 结论与遗留

- 批 2 的 7 条 P1 已**从代码层面关闭**：解压目标目录不再靠猜、元数据目录与用户目录重叠时不再改名/覆盖、失败回滚不再清空目录内压缩包、孤儿解压进程启动时定向回收、最危险的删除路径已入审计日志、批量入库的提交与并发均已加守卫。
- 遗留（未在批 2 实施，已标注）：
  1. **真机验证未做**（交互层：提示文案、按钮禁用观感、导入全链路）；
  2. 处理队列运行中点"取消"仍会掐断队列（可归入批 3 或单独立项）；
  3. `IMP-12` 的 UI 冻结根因（同步全树扫描 + 整份 prefs 同步重写）属批 4，**当前仍是"软件未响应"的成因，未处理**；
  4. `ScreenshotFetchService` 在"元数据目录与源目录重叠"场景仍会往用户目录写 `screenshots/`（只增不改，未造成破坏，未处理）。

---

## 7.6 批 3 执行记录（2026-09-12）

### 7.6.1 新增发现：IMP-21（批 2 审查遗漏项）

批 3 处理 `GlobalInstallCenter` 时发现 `_rollback()` 步骤 3 存在与 IMP-02 **完全同类**
的缺陷（此前审查列为"另 4 条删除路径"时遗漏了这一处）：云安装失败回滚会
① 对 `actualDir` 做"顶层扩展名"判定后递归删除（exe 在 `bin/` 的目录会被误判）；
② 对 `targetDir` **无条件**递归删除。两处都无 `PathHelper.isInsideAppStorage` 归属护栏
→ 自定义安装位置指向用户目录时，失败回滚可整目录删除用户数据。已随批 3 一并修复。

### 7.6.2 改动清单

| 文件 | 改动 | 对应问题 |
|------|------|----------|
| `lib/services/global_install_center.dart` | `_rollback` 步骤 2.5：孤儿压缩包由"文件名包含 gameId/标题 + 24h"改为**只删与本任务下载文件同基名的变体**，拿不到下载路径一律不删；步骤 3：`actualDir` 加归属护栏 + 游戏数据判定改用 `InterruptCleanup.hasGameDataRecursively`（递归），`targetDir` 加归属护栏；两处删除改走 `CleanupUtils`（补审计） | IMP-08、IMP-21 |
| `lib/pages/join/batch_import_controller.dart` | ① 新增静态 `takeNextImportBatch()`（取批次时过滤已取消项、**不修改列表**），替代循环内 `removeWhere`；② 新增 `_removeImportedGames()`：入库收尾**只移除成功项**，失败项保留并标记 `failed`（UI 显示"重试"）；③ `retryGame` 真正清空 `metadata/metadataTitle/isHardDuplicate/duplicateWarning`（直改字段，`copyWith` 的 `??` 语义无法置空） | IMP-13、IMP-14、IMP-17 |
| `lib/pages/join_page.dart` | 批量控制器监听改为具名方法 `_onBatchControllerChanged`，`dispose` 中 `removeListener`（并加 `mounted` 守卫） | IMP-15 |
| `lib/pages/join/widgets/smart_import_section.dart` | `_confirmAllCandidates` 的分母改为"ready 且非硬重复"（与 `confirmAllCandidates` 的处理集合一致） | IMP-16 |
| `lib/services/interrupt_cleanup.dart` | `_hasGameDataRecursively` 改为公开 `hasGameDataRecursively`（供 `GlobalInstallCenter` 复用，避免规则漂移） | IMP-21 |
| `test/services/import_batch_fix_test.dart` | 新增 4 条回归用例 | IMP-13、IMP-16 |

### 7.6.3 与方案文档的偏差（如实说明）

| 项 | 方案原文 | 实际做法 | 原因 |
|----|----------|----------|------|
| IMP-14 | §7 建议"失败项保留并可重试" | ✅ 按方案；额外把失败项标记为 `failed`（原状态是 `completed`，UI 不显示重试按钮） | 不标记则"保留"没有实际意义 |
| IMP-17 | §7 建议"(a) 清空元数据重新抓取" | ✅ 按 (a) 执行 | 与智能导入 `retryCandidate` 行为对齐 |
| IMP-13/14/15/17 测试 | §5.2 要求"每条 IMP 至少 1 个针对性用例" | ❌ **未达成**：`batch_import_controller` 的入库循环依赖私有 `_games` 与网络抓取，现无测试注入口 | 仅 IMP-13 通过提取纯函数 `takeNextImportBatch` 获得可测性；「补充测试接缝」列入 §7.6.4 遗留 |

### 7.6.4 结论与遗留

- 批 3 的 6 条 P2 + 1 条新发现 P1（IMP-21）已**从代码层面关闭**。
- 遗留：
  1. **真机验证未做**（交互层：删除失败项后的重试入口、批量入库提示文案）；
  2. `BatchImportController` 缺少测试接缝（私有 `_games` 不可注入），IMP-13 之外的循环行为仍只能靠真机回归 → 建议后续在批 5 后补一个 `@visibleForTesting` 注入口；
  3. 既有 flaky（`test/smart_import/` 并发全量偶发失败、单跑全绿）为**测试隔离问题**，与 2026-09-07 起的既有记录签名一致，非本次引入 → 单独排期处理；
  4. `IMP-12`（软件未响应根因）仍未处理（批 4）。

---

## 7.7 批 4 执行记录（2026-09-12）

### 7.7.1 改动清单

| 文件 | 改动 | 对应问题 |
|------|------|----------|
| `lib/pages/join/utils/game_folder_scanner.dart` | ① `detectLaunchExe` 拆为 `detectLaunchExe(path, {cache})` + `_detectLaunchExeUncached` + `_collectExeFiles`（**条数 20000 / 深度 8 上限**的有界递归，替代无界 `listSync(recursive: true)`）+ `_pickLaunchExe`；② `scanGames` 创建本次扫描私有的 `launchExeCache` 并传入 `_hasSameParentGame` —— 阶段五的 O(n²) 整树扫描降为每目录至多 1 次 | IMP-12 批A |
| `lib/services/watch_folder_service.dart` | 新增 `_schedulePersistCandidates()`（2s 防抖）：仅"候选入队"与"富化完成"两条高频路径改走防抖；确认/忽略/重试/移除等影响崩溃恢复语义的路径仍立即落盘 | IMP-12 批A |
| `lib/pages/join/batch_import_controller.dart` | `autoProcessNewGames` 正常收尾与异常分支均复位 `_isAwaitingConfirmation`（旧实现：处理中新增游戏置位后永不复位 → 预览条常驻、`retryGame` 静默失效）；删除无调用点的 `_cleanupCompletedTasksCache`（死代码，护栏逻辑已由 `_cleanupSingleGameCache`/`_cleanupAllCache` 覆盖） | IMP-18、IMP-20 |
| `lib/pages/join/utils/gal_game_detector.dart` | 系统路径负信号由**整条路径 contains** 改为**路径分段精确匹配**（`D:\GAL\Original` 不再被误记为系统路径）；顺带移除因此不再使用的 `fullPathLower` 局部变量 | IMP-19 |
| `lib/pages/join/widgets/swipe_switcher.dart` | `_animateReset` 复用单个 `_resetController`（旧实现每次回弹 new 一个、仅完成时释放，页面 200ms 内销毁即泄漏 ticker）+ `dispose` 兜底释放 + 监听器 `mounted` 守卫 | IMP-20 |
| `test/smart_import/gal_game_detector_test.dart` | 新增 IMP-19 组 2 条；**测试基建修复**：固定路径 `D:\gal_detector_test_temp` 改为每次运行唯一（时间戳后缀），消除跨运行删除竞态 | IMP-19 |

### 7.7.2 与方案文档的偏差（如实说明）

| 项 | 方案原文 | 实际做法 | 原因 |
|----|----------|----------|------|
| IMP-12 批A prefs 写入 | §7 建议"改 `writeAsString`（异步）" | ❌ **未改** `PortableSharedPreferencesStore` | 同步写是当前唯一的写入串行化保证；改异步会引入并发乱序覆盖风险，需要先补写队列。防抖已把高频路径的写盘次数从 O(n) 降到 O(n/2s)，收益占大头；写入器异步化列入批 5 一并设计 |
| IMP-12 批A 检测器上限 | §7 建议"上限提前生效" | ⚠️ 未改 `GalGameDetector` | 复查后确认其两层扫描已有 2000 文件/500 目录上限，越界成本可忽略；仅 `detectLaunchExe` 是真正的无界扫描 |
| IMP-12 批A 缓存失效 | §7 建议"按目录 mtime 失效" | ❌ 改为**扫描会话内缓存**（随 `scanGames` 创建、结束即弃） | ADR-008：Windows 目录时间戳仅秒级精度，mtime 失效判据不可靠；会话内缓存无过期问题且语义等价 |
| IMP-12 批A 验证 | — | ⚠️ 无性能量化 | 需要 300GB 级真实目录，本机未做；行为正确性由既有测试保障 |
| IMP-18 测试 | §5.2"每条 IMP ≥1 用例" | ❌ 无 | 标志为控制器私有状态，无测试接缝（同批 3 的说明） |

### 7.7.3 结论与遗留

- 批 4 完成：`IMP-18`/`19`/`20` 关闭；`IMP-12` 完成**批 A 缓解**（去 O(n²) 整树扫描、
  高频写盘防抖），"未响应"主因已大幅削弱，但**彻底根治需批 B（isolate 化）**。
- 遗留：
  1. **真机性能对比未做**（验收点：300GB 级目录导入期间窗口是否仍长时间未响应）；
  2. `PortableSharedPreferencesStore` 写入器异步化 + 写队列（批 5 一并设计）；
  3. `IMP-12` 批 B：扫描/富化移出 UI isolate（单独立项，需真机性能回归）；
  4. 测试隔离去 flaky（`test/smart_import/` 并发偶发）单独排期。
