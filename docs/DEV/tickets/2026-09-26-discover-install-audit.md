# 探索库「安装」功能设计审计（只读审计，未改任何业务代码）

> 日期：2026-09-26　执行：AI（阶段 A 只读审计）　状态：**待用户批准修复**
> 范围：探索库 / BPM 探索页 → 云端（OpenList 网盘）下载安装游戏的全链路
> 前提：用户怀疑「探索库的安装功能有严重设计漏洞」。本单给出核实结果。
> ⚠️ 结论来自**静态阅读**，未跑 analyze/test、未真机验证。
> ⚠️ 行号基于**当前工作区**；`lib/services/download_core.dart` 存在他人未提交改动
> （+236/-95），其行号可能与 HEAD 不一致。

## 0. 结论摘要（TL;DR）

用户的感觉是对的，但问题不在「某个按钮写错了」，而在**结构**：同一个动作有**两套并行实现**，
只有桌面那套接齐了必需步骤；同时安装链路上**几项本该有的能力是空转的**（空间预检是桩、
体积信息没接、已安装判定用错口径）。

| 级别 | 问题 | 位置（工作区行号） | 后果 |
|------|------|--------------------|------|
| P0 | BPM 探索页安装把**网盘路径**当下载直链，且不传 `urlResolver` | `big_picture/pages/big_picture_discover.dart:576-589` | BPM 探索页安装**必然失败** |
| P1 | 磁盘空间预检是**空实现（桩）**，且默认路径根本不预检 | `services/path_validator.dart:181-206`；`services/global_install_center.dart:232-260` | 盘不够时写到一半才失败 |
| P1 | 「文件大小」能力已有，却没接进安装流程 | `services/file_size_service.dart:58` vs `widgets/install_confirmation_dialog.dart:492-528` | 确认弹窗只给路径，不给体积/剩余空间 |
| P1 | BPM 侧安装无确认、无路径选择，与桌面侧两套流程 | `big_picture_discover.dart:570-618` vs `pages/game_detail_page.dart:613-668` | 大屏用户无路径控制权 |
| P1 | 「是否已安装」用**标题精确匹配**，与 ADR-011 稳定主键冲突 | `services/local_game_registry.dart:633-637`（已有 `:644` 的 id 版未用） | 改过标题即可重复安装、产生重复目录 |
| P1 | 解压被**两层各触发一次**，职责重叠 | `download_core.dart:421` + `global_install_center.dart:278` | 状态回调被覆盖、失败归因困难 |
| P2 | 异常被「兜底验证」吞掉，可能报成功但文件不全 | `global_install_center.dart:298-316`、`:671` | 用户启动游戏才发现坏了 |
| P2 | 强杀/断电后无续传入口，也不可见 | `download_core.dart:996-1012`（正常取消会清）、`:1015` | 孤儿分片占空间 |
| P2 | 下载文件名取自 URL 末段 / 游戏标题，未做路径清洗（**推断，未实测**） | `download_core.dart:1158-1184`、`:365-366` | 理论上可写出目标目录 |
| P2 | 安装提交无网络/登录前置校验 | `global_install_center.dart:196` 起 | 离线时白等一轮 |
| P3 | 两处 UI 各自复制 InstallTask 组装与提示 | `big_picture_discover.dart:576-612` vs `game_detail_page.dart:654-700` | 字段新增必漏一处（本次已漏两项） |

## 1. 现状链路（已核实）

| 入口 | 中间环节 | 最终服务方法 |
|------|----------|--------------|
| 桌面探索库卡片 `pages/discover_page.dart:1286`(onTap) | `main_container.dart:202` `_onGameTap` → 详情页 | `pages/game_detail_page.dart:613` `_handleInstallTap` → `:647` 解析直链 → `:654` `InstallTask`（含 `:667` `urlResolver`）→ `global_install_center.dart:196` `submitTask` |
| BPM 探索页卡片 `big_picture_discover.dart:345` `_handleGameTap` → `:359` `_DiscoverDetailDialog` | `:570` `_startDownload` | `:576-589` `InstallTask`（**`downloadUrl` 直接用云端路径、无 `urlResolver`**）→ `global_install_center.dart:196` `submitTask` |
| 两路汇聚 | `global_install_center.dart:222` `_executeTask` | `:364` `_startDownload` → `services/download_core.dart:291` `start` |

数据语义：云端表的 `downloadUrl` 字段由 `models/game_model.dart:61` 读入，是**网盘路径**而非直链；
必须经 `services/openlist_service.dart:1191` `getGameDownloadUrl(path)` 换取会过期的签名直链
（`download_core.dart:313` 保存 `urlResolver`，`:808` 只在 401/403/404/416 时重解析）。

## 2. 问题清单

### P0-1　BPM 探索页安装必失败（路径未解析为直链）

- BPM：`big_picture_discover.dart:582` `downloadUrl: widget.game.downloadUrl`，且整段 `:576-589`
  **未设置** `urlResolver`。
- 桌面（正确实现）：`game_detail_page.dart:647` `await OpenListService.getGameDownloadUrl(gamePath)`
  → `:660` `downloadUrl: proxyUrl`、`:667` `urlResolver: () => OpenListService.getGameDownloadUrl(gamePath)`。
- `download_core.start`（`:291`）**不会**自动把路径解析成直链，只把传入值交给 Dio。
- 影响：大屏探索页点「下载游戏」后必然拿不到数据（用户侧表现为失败提示或长时间零进度）。
- 这是**已知项**：`SESSION_HANDOFF.md`「下一步计划」已登记「待你批准：修复
  `big_picture_discover.dart:582`（约 5 行，照搬 `game_detail_page.dart:612,645`）」，本单予以复核确认。
- 设计层判断：真正的问题不是这一行，而是**桌面侧在 09-08 刚修过同一个坑**（`game_detail_page.dart:666`
  留有「★ P0-4」注释），BPM 这份复制实现没有同步 —— 复制式实现必然漂移。

### P1-1　磁盘空间预检是桩实现，默认路径连桩都不走

- `services/path_validator.dart:181-206` `getDiskSpaceInfo`：恒返回
  `isAvailable: true, freeSpaceBytes: -1, totalSpaceBytes: -1` —— **根本没有查真实磁盘**。
- `path_validator.dart:255-257` `hasEnoughSpace`：`freeSpaceBytes < 0 || ...` → 负值一律判「够」。
- `global_install_center.dart:232-260`：只有 `customGameLocation` 非空才进校验分支，且只判
  `!diskSpace.isAvailable`（恒 false，等于不拦）；默认路径走 `:258-260` 直接跳过。
- BPM 侧不传 `customGameLocation`（`big_picture_discover.dart:576-589`）→ 完全没有任何空间检查。
- 连带同源缺陷：`services/game_move_service.dart:128-136` 的跨盘移动空间校验因
  `space.freeSpaceBytes >= 0` 恒 false 而**永不触发**。
- 影响：用户无法在下载前知道「要下多大、盘够不够」，只能在写到一半时失败并触发回滚清理。

### P1-2　「文件大小」能力已存在但没接进安装流程

- `services/file_size_service.dart:58` `FileSizePrefetchService.prefetchSize` 已经会
  `getGameDownloadUrl`（`:93`）+ HEAD 取 `content-length`（`:109`），并做内存/磁盘双缓存（7 天）。
- 探索库为「按大小排序/筛选」**已经在用它**（`pages/discover_page.dart:591` 后台补抓）。
- 但安装侧完全没用：`widgets/install_confirmation_dialog.dart:144-149` 只拼路径，
  `:492-528` 只展示「完整安装路径预览」——**既无下载体积，也无目标盘剩余空间**；
  `GlobalInstallCenter` 也未查询大小。
- 判断：典型「能力已有、未被消费」。修完 P1-1 后把大小接进确认弹窗即可形成闭环。

### P1-3　BPM 安装缺确认步骤，两套前置流程

- 桌面：`game_detail_page.dart:620-626` 先弹 `InstallConfirmationDialog`，`:632-638` 解析
  上次/默认安装位置，再提交。
- BPM：`big_picture_discover.dart:570-618` **直接提交**，无确认、无路径选择、不传自定义位置。
- 判断：同一功能两套前置。建议抽一个共享的「安装前置」方法/对话框，两个入口都走它，
  否则以后每加一项前置（体积、空间、登录、重复校验）都要改两处。

### P1-4　「是否已安装」用标题精确匹配，与 ADR-011 冲突

- 调用点：`discover_page.dart:476`、`:1341`、`:1376`；`game_detail_page.dart:263`、`:282`；
  `big_picture_discover.dart:335`、`:623` —— 全部是 `LocalGameRegistry.isTitleInstalled(title)`。
- 实现 `local_game_registry.dart:633-637` → `:690-697`：按 `title` 精确命中 `_byTitleIndex`，
  未命中再回退 `_games[GameKey.dirNameFromTitle(title)]`。
- 同一文件已有 `isGameIdInstalled`（`:644-648`，查 `_byIdIndex`），其注释明确记录旧实现是错的。
- 影响：本地改过标题、或云端标题与本地标题有细微差异（全角/空格/译名/副标题）时判定失效 →
  已入库的游戏仍显示可安装并可再次安装，产生重复目录、重复统计。与 ADR-011「身份 = game_id」的目标直接冲突。
- ⚠️ 改之前需先确认一个前提（见 §5 未验证项）：PB `record.id` 与本地 `game.json.game_id` 是否同源。

### P1-5　解压被触发两次

- `download_core.dart:421`：下载完成后自行 `await _triggerExtraction(filePath)`。
- `global_install_center.dart:278`：下载返回后**又** `await _startExtraction()`（实现见 `:388-431`，
  用的是同一个 `_activeDlCore!.extractManager`，`:393`）。
- 判断：先下载器内触发、再安装中心触发，第二次对同一压缩包空跑，结果靠
  `_ultimateSuccessVerification`（`:671`）与注册表校验掩盖。职责应单点化。

### P2-1　异常被「兜底验证」吞掉

- `global_install_center.dart:298-316`：catch 到**任何**异常后，只要 `:302` `_ultimateSuccessVerification()`
  为真就当安装成功、走完成回调，异常被忽略。
- `:671` 起的验证判据偏弱（`local_game_registry` 查到目录存在、或目标目录内 entity ≥ 2）。
- 影响：真实失败可能被显示为「安装完成」。**该项为推断，未实测**。

### P2-2　强杀/断电后无续传入口

- 正常取消：`download_core.dart:970` `_handleCancel` → `:988` `_cleanupTempFiles` →
  `:996-1012` 删除**本任务**分片（旧实现会误删其他任务分片，已修）。**取消路径本身没问题**。
- 但进程被强杀/断电时 `.part_*.tmp` 残留（`:560` 命名），且**没有任何启动级恢复入口**；
  `:1015` `_resumableBytes()` 只用于提示文案，不驱动续传。
- 推断（未实测）：跨重启续传还会因 `:375` `_probeTier` 网络分档变化导致分片边界变化而失效。

### P2-3　下载文件名未清洗（**推断，未实测**）

- `download_core.dart:1158-1184` `_extractFileName`：优先取 `Uri.tryParse(url).pathSegments.last`，
  否则回退 `fallback`（调用点 `:365` 传的是 `task.title`，即云端/用户可见标题）。
- 结果在 `:366` 拼成 `'$saveDir/$name'`。
- 推断：`Uri.pathSegments` 会对 `%2F` 解码，理论上可构造出含路径分隔符的名字；title 若含 `..`
  也存在写出 `saveDir` 的可能。因 URL 由本地 OpenList 返回、title 由云端提供，**实际可利用性未验证**，
  故不夸大，标 P2 待实测。

### P2-4　安装提交无网络/登录前置校验

- 探索库本身有离线视图与网络监听（`discover_page.dart:127`、`:181`、`:260`、`:1060`），
  但提交路径 `global_install_center.submitTask`（`:196`）不做任何网络/登录校验，文件内也无相关引用。
- 影响：离线时点安装会直接进入下载阶段再失败，而不是提前告知。

### P3-1　可维护性

- 两处安装 UI 各自复制了 `InstallTask` 组装与成功/失败提示：
  `big_picture_discover.dart:576-612` vs `game_detail_page.dart:654-700`。新增字段必须改两处，
  本次 BPM 侧就已漏了 `urlResolver` 与 `customGameLocation`。
- 去重有两层且口径不同：`global_install_center.dart:196-204`（按 `gameId`）与
  `extract_manager` 的内存去重集（`_registeredGames`），不一致时会互相掩盖。

## 3. 定性结论

用户说的「严重漏洞」成立，但**根因是结构而非单点**：

1. **同一动作两套实现**（桌面详情页 / BPM 详情对话框），只有一套接齐了必需步骤 → 必然漂移
   （已发生：直链解析、自定义安装位置、确认弹窗三项 BPM 全缺）。
2. **能力空转**：磁盘空间预检是桩、文件大小已能取但没接、`isGameIdInstalled` 已存在却仍用标题匹配。
   这三项都不是「没做」，而是「做了没接上」，属于典型的"看起来有、实际不生效"。

因此本文不建议只修 P0 那一行 —— 只修那一行，BPM 能装上了，但空间、体积、重复安装三个坑仍在。

## 4. 建议批次（**待批准，本单不含任何代码改动**）

| 批次 | 内容 | 依据 |
|------|------|------|
| 批 1（P0，建议先做） | BPM 探索页补直链解析 + `urlResolver`（照搬桌面实现） | §P0-1；HANDOFF 已登记待批准 |
| 批 2（P1） | 抽共享「安装前置」（确认 + 路径 + 体积 + 空间校验），两入口共用；`path_validator` 查真实空间 | §P1-1/1-2/1-3 |
| 批 3（P1） | 解压单点化；「已安装」判定改 `isGameIdInstalled`（需先确认 id 同源） | §P1-4/1-5 |
| 批 4（P2） | 兜底验证收窄；启动级恢复/清理入口；文件名清洗（先实测）；网络前置 | §P2-1/2-2/2-3/2-4 |

## 5. 未验证项（不要当成已验证的事实）

1. **本单全部结论来自静态阅读**，未跑 `flutter analyze` / `flutter test`，未真机验证。
2. `lib/services/download_core.dart` 存在**他人未提交**改动（+236/-95），其行号仅对当前工作区成立。
3. P2-3（路径穿越）**纯推断**，未构造用例实测。
4. P2-2 中「跨重启续传因分档变化失效」为推断。
5. P1-4 的修复前提未核实：PB `record.id` 与本地 `game.json.game_id` 是否同源
   （若不同源，改 `isGameIdInstalled` 前需要先建映射，不能直接换）。
