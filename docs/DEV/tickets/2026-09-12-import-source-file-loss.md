# 事故调查：导入功能疑似转移/删除/破坏用户本地游戏源文件

| 项 | 值 |
|----|-----|
| **类型** | Bug 调查（未改代码） |
| **优先级** | P0（数据丢失） |
| **提出日期** | 2026-09-12 |
| **状态** | 待评估（需在受影响机器上取证确认） |
| **关联功能档案** | 无（导入链路尚无 features 档案） |

> 用户报告：智能导入多个游戏（合计约 300GB）过程中软件未响应，用户强制关闭软件后，
> 发现本地游戏源文件疑似被转移、删除或破坏，游戏文件夹"无法找到或已完全损坏"。
> 本文只做**只读审计**，不含任何代码改动。

> **【2026-09-12 修复状态更新】** 本单 §4 的删除路径已部分处置（详见
> `2026-09-12-import-audit-summary.md` §7）：
> - ✅ 已修复：**§4.1**（`deleteGame` 本体删除护栏，批 1 / IMP-01）、
>   **§4.2**（退出清理归属护栏 + 递归游戏数据判定，批 1 / IMP-02）、
>   **§4.4**（`cleanupTempCover` 封面归属护栏，批 1 / IMP-03）。
> - ⏸ 待排期：§4.3（失败回滚删压缩包，IMP-06）、§4.5（孤儿压缩包，IMP-08）、
>   §4.6（元数据目录与源目录冲突，IMP-05）、§3 未响应根因（IMP-12）。
> - §6 取证清单仍然有效——若需要定位历史事故，请照单执行。

---

## 0. 结论（先行）

1. **智能导入对源目录本身是"只读"的**——扫描、识别、抓元数据都不写源目录（见 §2 的写清单）。
   但这条只读保证**建立在"元数据目录 ≠ 源目录"这个前提上**，代码里没有任何断言保护它（§4.6）。
2. **应用确实拥有"递归删除用户源目录"的能力，且没有任何目录归属护栏**：
   `LocalGameRegistry.deleteGame()` 会对 `game.directoryPath` 执行
   `Directory.delete(recursive: true)`（`lib/services/local_game_registry.dart:1220-1223`）。
   而三条导入链路存入的 `directoryPath` **就是用户的原始游戏文件夹**
   （智能导入 `candidate.dirPath`、批量导入 `game.folderPath`、单文件导入用户所选路径）。
   仓库里明明有现成的护栏工具 `PathHelper.isInsideAppStorage`（`lib/core/path_helper.dart:170`），
   但它只被用在"临时封面"这种低危场景，**没被用在最危险的删除上**。
3. 除 `deleteGame` 外，另有 4 条能触达用户文件的删除路径（§4.2–§4.5），
   其中 2 条会在**退出/异常中断**时被自动触发，校验条件都过弱。
4. "软件未响应"有确定的代码原因：**UI isolate 上的同步全树扫描 + 每候选整份设置文件同步重写**（§3）。
   300GB 规模下这是分钟到小时级的冻结，不是偶发卡顿。
5. 强制关闭本身不删除文件，但它**抹掉了唯一的现场**：正常退出的清理流程没跑、
   解压子进程变成孤儿继续写盘、审计日志缺覆盖（§5）。
   → **这就是为什么现在无法回溯到底是谁删的**，所以取证清单（§6）必须先做。

**最可能的三种解释，按可能性排序：**

| # | 假说 | 支撑证据 | 反证/条件 |
|---|------|---------|-----------|
| H1 | 用户在处理"导入失败"的残留时，从库中删除游戏并勾选了"同时删除本地文件" → `deleteGame` 递归删掉源目录 | 代码事实确凿（§4.1）；对话框默认不勾选但文案无法区分"应用安装的游戏"与"用户自己的源目录" | 需要用户确认是否点过删除 |
| H2 | 源目录与应用 `Games` 目录重叠（watch root == `<exeDir>/Games`）→ 元数据写进源目录；`updateGameTitle` 把该目录**重命名**（=移动 300GB 文件夹） | `metaDataDir = gamesDir/safeName`（§4.6）；`updateGameTitle` 执行 `oldDir.rename(newMetaDataDir)`（`local_game_registry.dart:1113`） | 需要确认用户的收藏目录位置 |
| H3 | 事件其实是"应用里找不到游戏"而非磁盘被删：`game.json` / `.ctgame` 被覆盖或删除后，库页报"目录不存在，请确认游戏文件夹已移动到该位置" | `path_validator.dart:145` 的原文提示就是这个措辞 | 需要用户用资源管理器确认文件夹是否真的不在 |

---

## 1. 调查范围

| 链路 | 入口 | 关键实现 |
|------|------|----------|
| 单文件导入 | `lib/pages/join_page.dart` → `join/join_controller.dart` | `submitAddGame` / `startCopyFlow` / `startExtractFlow` |
| 批量导入 | `join/batch_import_controller.dart` | `autoProcessNewGames` / `importSingleGame` |
| 智能导入 | `services/watch_folder_service.dart` + `services/auto_import_pipeline.dart` | `_scanWatchFolder` / `enrichCandidate` / `importCandidate` |
| 共用底座 | `pages/join/utils/game_folder_scanner.dart`、`utils/gal_game_detector.dart`、`services/game_data_format.dart`、`services/local_game_registry.dart` | 识别 / 写元数据 / 注册 |

---

## 2. 智能导入的磁盘写清单（"只读边界"证明）

逐条核对后，智能导入全流程**只会写下列位置**：

| 写操作 | 位置 | 代码 |
|--------|------|------|
| `.ctgame` / `game.json` / `cover.*` / `screenshots/*` | `<exeDir>/Games/<safeName>/`（元数据目录） | `auto_import_pipeline.dart:212,221`；`game_data_format.dart:125-160` |
| 临时封面 | `Directory.systemTemp`（`smart_cover_<hash>.<ext>`） | `auto_import_pipeline.dart:304-325` |
| 候选队列持久化 | `data/prefs/shared_preferences.json` | `watch_folder_service.dart:212-220` |
| 截图 | `<元数据目录>/screenshots/` | `screenshot_fetch_service.dart:155` |
| 日志 | `logs/`、`data/cleanup_log.jsonl` | — |

**关键：`candidate.dirPath`（用户源目录）只被读取**——`GameFolderScanner` 用 `dir.list` /
`entity.lengthSync`，`GalGameDetector` 用 `listSync`，`detectLaunchExe` 用 `listSync(recursive: true)`，
全是只读调用。

> ⚠️ 因此"智能导入直接把源文件删了"在代码上不成立。真正的问题在 §4：
> 应用把源目录当成"游戏本体目录"登记进库，之后**对"本体目录"这个概念的任何操作都会落到用户源文件上**。

---

## 3. "软件未响应"的根因（可确证）

300GB 收藏 + 数百个候选时，以下几件事**全部跑在 UI isolate 上且是同步阻塞调用**：

1. **`GameFolderScanner.detectLaunchExe`** —— `dir.listSync(recursive: true)`，
   **无深度/数量上限**，对一个 300GB 游戏目录就是几万个文件的整树遍历
   （`game_folder_scanner.dart:418`）。
   - 每识别出一款游戏，富化阶段再扫一次（`auto_import_pipeline.dart:95`）；
   - 阶段五 `_hasSameParentGame` **对每对父子关系各扫 2 次**
     （`game_folder_scanner.dart:552-570`）→ O(n²) 次全树扫描。
2. **`GalGameDetector._collectEntriesSeparate`** —— 同步 `listSync` 两层
   （`gal_game_detector.dart:737-788`），每个候选一次；上限（2000 文件/500 目录）只是防内存，不防耗时。
3. **`WatchFolderService._saveCandidates()` 每个候选一次**（`watch_folder_service.dart:644`）：
   `jsonEncode(整个候选队列)` + `PortableSharedPreferencesStore._save()` 里的
   **`tmp.writeAsStringSync(整份设置文件, flush: true)`**（`core/portable_shared_preferences_store.dart:75`）
   —— 同步写盘，在 UI isolate 上。队列里每个候选还带完整 `metadata` 映射，
   于是写盘量随队列长度线性增长、累计成 O(n²)。
4. `GameFolderScanner.scanGames` 仅**每 25 个候选** `await Future.delayed(Duration.zero)`
   让出事件循环（`game_folder_scanner.dart:154`）——单个候选自身耗时几秒时完全无效。

**结论：300GB 场景下窗口"未响应"是必然会发生的，不是偶发。** 用户看到的就是这个。

---

## 4. 能真正删除/移动用户文件的全部路径

### 4.1 🔴 P0 `deleteGame` —— 递归删除用户原始游戏目录（最危险）

```dart
// lib/services/local_game_registry.dart:1220-1223
final bodyDir = Directory(game.directoryPath);
if (await bodyDir.exists()) {
  await bodyDir.delete(recursive: true);   // ← 递归删除"游戏本体目录"
}
```

- `game.directoryPath` 对三条导入链路而言**都是用户自己的文件夹**：
  - 智能导入：`directoryPath: candidate.dirPath`（`auto_import_pipeline.dart:229`），
    `candidate.dirPath = game.path` = 监控路径下的真实游戏目录（`watch_folder_service.dart:629`）
  - 批量导入：`directoryPath: game.folderPath`（用户添加的文件夹）
  - 单文件导入：`directoryPath: sourcePath / actualDirectoryPath`（用户所选路径）
- 触发入口（3 个）：库页右键 → `main_container.dart:368 _onDeleteGame`；
  库页批量删除 → `library_page.dart:371`；BPM 动作表 → `big_shell.dart:480`
  → 最终都走 `main_container.dart:492/522`。
- **缺陷清单**：
  1. 没有任何目录归属校验（就算 `directoryPath` 位于应用自有目录之外也照删）；
  2. 对话框只有一个"同时删除本地文件"复选框（默认未勾选，`main_container.dart:369`），
     **文案完全不区分"应用云端安装的游戏"与"用户自己的源目录"**，
     用户很容易理解为"把导入时产生的文件也删掉"；
  3. 删除是**永久删除**，不进回收站；
  4. 单条删除 / 批量删除都**没有审计日志**（`deleteGame` 用的是裸 `Directory.delete`，
     不经过 `CleanupUtils` → 不会写入 `data/cleanup_log.jsonl`）。

> 对本事故而言：用户强制关闭后重开，若看到一堆"导入不完整"的游戏条目，
> 很可能全选 → 删除。此时勾上那个复选框，300GB 源文件会被原地抹除，
> 且**事后无法从日志证明是这一步干的**。这与"游戏文件夹直接无法找到"完全吻合。

### 4.2 🔴 P0 `InterruptCleanup` 退出清理 —— 递归删除解压本体目录

```dart
// lib/services/interrupt_cleanup.dart:278-311
if (actualGameDir != null && actualGameDir.isNotEmpty) {
  final dir = Directory(actualGameDir);
  final entities = await dir.list().toList();        // ← 只看顶层
  bool hasGameData = false;
  for (final e in entities) {                        // ← 只认 4 种扩展名
    if (e is File && (name.endsWith('.exe') || name.endsWith('.ctgame')
        || name.endsWith('.xp3') || name.endsWith('.ks'))) hasGameData = true;
  }
  if (!hasGameData) {
    await CleanupUtils.deleteWithRetry(dir, ...);    // → Directory.delete(recursive: true)
  }
}
```

- 触发点：`widgets/custom_title_bar.dart:44-51`，条件
  `DownloadCore.hasActiveTask || ExtractManager.hasActiveTask`，即**正常退出**时。
- `actualGameDir` = `ExtractManager._actualGameDir` = 解压本体目录
  （`extract_manager.dart:252`），在有自定义安装位置时是**用户自己选的目录**。
- 缺陷：校验只看**顶层**有无 4 种扩展名。一个"exe 在 `bin/`、数据在子目录"的
  游戏目录（GAL 常见结构）会被判定为"没有游戏数据" → **整目录递归删除**。
- 紧邻的 item 3（`interrupt_cleanup.dart:314-326`）删 `targetGameDir`
  时**连校验都没有**，直接 `deleteWithRetry`。

### 4.3 🟠 P1 `extract_manager._cleanupOnFailure` —— 删目录内所有压缩包 / 删空目录

- 步骤 3（`extract_manager.dart:1786-1812`）：遍历 `targetDir` 顶层，
  **删除所有 `.rar/.zip/.7z/.tar`**（只排除"当前正在用的那个压缩包"），
  不比对文件大小/修改时间/来源。若 `targetDir` 恰是用户目录 → 用户放在里面的原始压缩包被清空。
- 步骤 6（`:1875-1900+`）：`extractionTargetDir` 若无游戏数据 → 递归删除
  （这个校验是递归的，比 §4.2 好，但仍只认部分扩展名）。

### 4.4 🟠 P1 `AutoImportPipeline.cleanupTempCover` —— 删用户选的封面原图

```dart
// lib/services/auto_import_pipeline.dart:283-291
static void cleanupTempCover(ImportCandidate candidate) {
  final file = File(candidate.coverFilePath!);
  if (file.existsSync()) file.deleteSync();   // ← 无任何归属校验
}
```
链：`field_lock_button.dart:64` 封面区点击 → `join_controller.pickCover()` 存**用户磁盘原图绝对路径**
→ `join_page.dart:226-230 _saveSingleToCandidate` 回写 `candidate.coverFilePath`
→ 入库/忽略/全部忽略/清空队列都会 `deleteSync` 掉它。
（注：批量导入对同场景有 `PathHelper.isInsideAppStorage` 护栏，
`batch_import_controller.dart:637-659`——智能导入这处漏了。）

### 4.5 🟡 P2 `GlobalInstallCenter` 删"孤儿压缩包" —— 按文件名模糊匹配

```dart
// lib/services/global_install_center.dart:792-812
final matchesTask = name.contains(gameId.toLowerCase()) ||
                    name.contains(title.toLowerCase());
if (!matchesTask) continue;
if (now.difference(stat.modified).inHours < 24) await entity.delete();
```
只作用于 `<exeDir>/downloads/`，但它是**按标题子串匹配 + 24h 时间窗**删压缩包，
用户若把自己的原始压缩包放在该目录（应用本身也用这个目录放压缩包），会被误删。

### 4.6 🟠 P1 元数据目录与源目录"同名重叠"（前提性缺陷）

- `metaDataDir = PathHelper.gamesDir/safeName`（`auto_import_pipeline.dart:211-212`），
  `safeName = TitleCleaner.clean(文件夹名)` 去掉了 `[汉化组]`、`v1.2`、`chs/汉化` 等后缀。
- **若监控路径就是应用的 `Games` 目录**（用户把游戏放在应用目录下是自然行为），
  且清洗后的标题与某个已存在的游戏文件夹同名 → 元数据目录 == 用户源目录，于是：
  1. `writeGameDir` 往**用户游戏目录里**写 `.ctgame`（还被 `attrib +h` 设为隐藏，
     `game_data_format.dart:930`）、`game.json`、`cover.*`
     —— `_saveCoverFile` 用 `copy` 覆盖同名 `cover.png`（`game_data_format.dart:958`）；
  2. `ScreenshotFetchService` 往该目录写 `screenshots/`；
  3. **`updateGameTitle` 会 `oldDir.rename(newMetaDataDir)`**
     （`local_game_registry.dart:1113`）——等于把用户的 300GB 文件夹**改名/移动**；
  4. `removeGameRecordOnly`（"仅删除数据记录"）会删掉该目录里的 `cover.*`
     （`local_game_registry.dart:1330-1342`）；
  5. §4.3 步骤 3 会删掉该目录里的所有压缩包。
- 代码里**没有任何断言或警告**阻止 `metaDataDir` 落到 `directoryPath` 之外/之内的冲突情形。

---

## 5. 强制关闭在其中的作用（放大器，非元凶）

| 正常退出会做的事 | 强制关闭后 |
|------------------|-----------|
| `ProcessCleanupService.cleanupAll()` 杀 `7z.exe/7za.exe/LRProc.exe`（`process_cleanup_service.dart:42-53`） | 不执行 → **解压子进程变孤儿**，`7z` 带 `-y`（自动覆盖，`extract_manager.dart:1121-1122`）继续往目标目录写盘，用户会看到文件"自己出现/被覆盖" |
| `InterruptCleanup.cleanupActiveTaskResidue()` | 不执行（这一次是好事：§4.2 的删除不会发生；但反过来说明**下次正常退出时它可能执行**） |
| 写队列 `GameDataFormat._writeQueues` 串行落盘 | 丢失；`_atomicWriteFile` 走 tmp+rename，`game.json` 本身不会半写 |
| `LogRotationService.rotateAll()` | 不执行 → 日志停在上一次轮转 |
| 清理 `data/lock/` 与 `_isScanning` 残留 | 残留由下次启动的 `_cleanupCrashedImportState()` 兜（`watch_folder_service.dart:409-434`） |

**审计盲区**：`deleteGame`（§4.1）与 `InterruptCleanup.cleanupExtraction/startupScan`
用的是裸 `Directory.delete`，**不写 `data/cleanup_log.jsonl`**
（只有走 `CleanupUtils.deleteWithRetry` 的路径会写，带 `reason` 字段）。
即：最危险的两条删除路径恰好没有审计日志。

---

## 6. 取证清单（请在受影响机器上按序执行）

1. **`<exeDir>/data/cleanup_log.jsonl`** —— 搜 `delete_dir`；
   若有 `reason: exit_cleanup_actual_dir` / `exit_cleanup_target_dir`，
   则 §4.2 命中，`target` 就是被删目录。
2. **`<exeDir>/logs/extract_*.txt`** —— 搜 `步骤3` / `步骤4` / `步骤6` / `已删除临时压缩文件`，
   确认 §4.3 是否执行过、`targetDir` 是什么。
3. **`<exeDir>/data/prefs/shared_preferences.json`** —— 检查：
   `watch_folders`（监控路径是否等于 `Games` 目录）、`watch_folder_candidates`
   （队列大小/是否有大量 `failed`）、`default_game_location`（自定义安装路径）。
4. **判断被删目录的位置**：
   - 在 `<exeDir>/Games/` 之内 → 指向 §4.2 / `cleanupExtraction` / 元数据目录冲突（§4.6）；
   - 在监控路径之下 → 指向 §4.1（`deleteGame`）。
5. **在"缺失"的游戏文件夹里看有没有 `.ctgame`（隐藏文件）** ——
   有 `.ctgame` + `game.json` ⇒ 该目录曾被当作**元数据目录**写入过，即 §4.6 命中。
6. **文件名是否变了**：若游戏目录变成"元数据标题"形态（例如 `CLANNAD` 变成
   `CLANNAD ～クラナド～`），是 §4.6 的 `updateGameTitle` 重命名，不是删除。
7. `fsutil usn readjournal <盘符>: csv` 或回收站 —— 区分"删除"与"改名/移动"。
8. 用户操作复盘：强制关闭重开后是否点过「删除」（含批量删除），是否勾了"同时删除本地文件"。

---

## 7. 修复建议（待批准后另行执行，本单不含代码改动）

| 级别 | 建议 |
|------|------|
| P0 | `deleteGame` / `removeGameRecordOnly` / `InterruptCleanup` / `_cleanupOnFailure` 四个删除点统一加 `PathHelper.isInsideAppStorage` 护栏：**应用自有目录之外一律不自动删除**，改为提示用户手动处理 |
| P0 | 删除对话框区分来源：`game.source == 'local_import' / 'smart_import'` 时明确警告"将删除你本地的游戏文件夹（$path，约 N GB）"，并要求二次确认（输入标题/路径二次确认更佳） |
| P0 | 所有递归删除进回收站（`SHFileOperation` / `IFileOperation`）而非永久删除，并统一写入 `data/cleanup_log.jsonl`（含 reason、路径、大小） |
| P1 | `_determineExtractionTarget` / `importCandidate` 增加断言：`metaDataDir != directoryPath` 且二者不互为子目录；冲突时改用 `_1` 后缀（与 `_resolveGameDir` 行为一致） |
| P1 | `detectLaunchExe` 加深度/数量上限 + 结果缓存；`_hasSameParentGame` 复用缓存，去掉 O(n²) 全树扫描；候选队列持久化防抖（如 2s 合并 + 只写增量）以消除 UI 冻结 |
| P1 | 正常退出前先 `ProcessCleanupService` 杀子进程并将"活动任务目录"落盘，下次启动只清理**有明确任务记录**的目录 |
| P2 | `_cleanupOnFailure` 步骤 3 删除压缩包前，比对"是否为本任务下载的压缩包"（记录路径+大小+mtime） |

---

## 8. 本次未验证的部分（如实声明）

- 全部结论均来自**静态代码审阅**，未在本机复现，也没有受影响用户的日志/磁盘现场。
- §0 的 H1/H2/H3 是**假说**，需要 §6 的取证材料才能定案。
- 未审计：云安装（`install_center_page` / `global_install_center` 全量）、
  `save_*`（存档备份/迁移）、Magpie 超分链路的磁盘操作；如需可另立调查单。
