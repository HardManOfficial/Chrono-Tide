# 探索库安装与下载内核修复档案（2026-09-26）

> 依据：`tickets/2026-09-26-discover-install-audit.md`（安装功能 P0/P1/P2 审计）+
> `tickets/2026-09-26-download-stability-analysis.md`（下载内核三项症状分析）。
> 状态：**代码完成，analyze 0 error，相关单测 16/16，全量回归见 DEV_LOG；待真机走查**。
> 范围说明：`download_core.dart` 的提交同时包含工作区既有的「自适应分片」未提交工作
> （2026-09-18，+236/-95），两者无法拆分提交。

## 1. 改动总览（按问题编号）

| 审计编号 | 问题 | 解法 | 落点 |
|----------|------|------|------|
| P0-1 | BPM 探索页把网盘路径当直链提交，无 urlResolver → 安装必失败 | 新建 `CloudInstallFlow` 统一入口（确认→体积→直链解析→提交），BPM `_startDownload` 与桌面 `_handleInstallTap` 都改走它 | `services/cloud_install_flow.dart`（新）、`big_picture/pages/big_picture_discover.dart`、`pages/game_detail_page.dart` |
| P1-1 | 空间预检是桩（恒 -1）且默认路径不预检 | ① `getDiskSpaceInfo` 经 Win32 `GetDiskFreeSpaceExW` 查真实空间（盘符/UNC 卷根解析，失败降级 -1 旧行为）；② 安装中心对「实际落盘盘符」统一校验（含默认路径），配合 `InstallTask.expectedSizeBytes` 做体积门槛 | `services/path_validator.dart`、`services/global_install_center.dart` |
| P1-2 | 体积能力已有未接线 | 确认弹窗新增「下载包体积 / 目标盘可用」行（缓存优先 + 后台预取），空间不足红色警告（不禁用确认：压缩包体积 ≠ 解压体积） | `widgets/install_confirmation_dialog.dart` |
| P1-3 | BPM 安装无确认/无路径选择 | 两个入口共用 `CloudInstallFlow` → BPM 也有确认弹窗、路径选择、路径预览 | 同 P0-1 |
| P1-4 | 已安装判定用标题精确匹配 | 入库写入 `cloud_game_id`（game.json 新键，`?? ''` 读取，不升 format_version，进覆盖黑名单）；注册表新增第 4 张惰性索引 `_byCloudIdIndex` + `getGameByCloudId`/`isCloudGameInstalled`（cloud 命中优先，老数据回退标题）；7 处调用点替换 | `game_data_format.dart`、`extract_manager.dart`、`local_game_registry.dart`、三个页面 |
| P1-5 | 解压被两层各触发一次 | `DownloadCore.start` 新增 `autoExtract` 参数（默认 true，GlobalTaskManager 不受影响）；安装中心传 `false`，解压编排权单点化 | `download_core.dart`、`global_install_center.dart` |
| P2-1 | 兜底验证吞异常 | OR 判据保留（AND 会让「解压成功但注册失败」被回滚删目录）；命中时进度文案明示「解压环节回报过异常，已按目录与注册表校验确认」 | `global_install_center.dart:298-316` |
| P2-2 | .part 分片残留无人管理 | 「下载残留」单元纳入 `.part_*.tmp`（统计+清理），仅当 `!DownloadCore.hasActiveTask`（有任务在跑时 .tmp 正被写，避免竞态） | `storage/storage_cleanup_service.dart` |
| P2-3 | 下载文件名未清洗 | `_sanitizeFileName`：路径分隔符/非法字符→`_`、压缩空白、保留扩展名限长 120、空/`.`/`..` 兜底 `download.bin` | `download_core.dart` |
| P2-4 | 安装提交无网络前置 | `_executeTask` 开头校验 `NetworkStatusService.instance.isOnline`，离线直接失败并说明 | `global_install_center.dart` |
| 稳定-B1 | >1GB 进度事件被 1% 门控 → UI 速度冻结 | 发射与门控解耦：百分比 ≥1% **或** 距上次发射 ≥2s 即发射 | `download_core.dart _startProgressTimer` |
| 稳定-B2 | 看门狗自愈对用户不可见 | 命中时发进度事件（`DownloadProgress.statusMessage` 新字段），安装中心转发为状态文案「网络停滞，正在自动续传（已保住 X）」 | `download_core.dart`、`global_install_center.dart` |
| 稳定-B3 | 直链刷新只覆盖 4xx | `_refreshUrl` 独立入口；分片/单流连续 2 次普通异常（未按范围响应/数据不完整）强制重解析 | `download_core.dart` |
| 稳定-B4 | 失败不告知可续传 | `_handleError` 错误消息附加「（已保住 X，重试将从断点继续）」；`_resumableBytes` 扩展单流半成品 + 公开 getter | `download_core.dart` |
| 稳定-C5 | totalSize 只信 HEAD | `_probeTier` 探测响应解析 `Content-Range` 总长校准（`_ProbeOutcome`），分片计划与 ±5% 容差均以校准值为准；零额外请求 | `download_core.dart` |
| 稳定-C6 | 单流路径无看门狗 + 整文件重下 + 重试 3 | 重写：单连接 Range 续传（206 判定，200 退回全量重下）、45s 看门狗、无进展保护（连续 2 轮无增长交给外层容差）、maxRetries 15 对齐 | `download_core.dart _startSingleStreamDownload` |
| 稳定-C7 | 重试不分失败类别 | badResponse 刷新直链后仍 4xx（≥2 次）立即失败；网络/5xx 类走满退避重试；收到数据清零计数 | `download_core.dart` |

## 2. 明确不做（边界）

- ~~**下载强度用户设定（批 D）**：按用户要求暂停，预设方案见下方 §4，待批准后实施。~~
  → **2026-09-26 用户批准，已实施**（见 §4，commit 记录见 DEV_LOG 当日第二条）。
- 兜底验证判据**不收窄为 AND**（P2-1 仅做透明化）。
- discover_page 的 `pb_config` / `global_install_center` unused import 为**存量警告**（本档案改动
  之前已存在），按「无关隐患只报告」未动。
- `download_core.dart` 的 `_mergeStartPercent`/`_progressThrottleMs` 等 unused_field 警告来自
  09-18 自适应分片工作区的遗留死字段，未顺手清理（最小变更）。

## 3. 验证状态

- `flutter analyze`（12 个改动文件）：**0 error**（新增 warning 仅排查后确认为存量/工作区遗留）。
- 相关单测：`download_core_resilience_test` + `game_data_overwrite_safety_test` +
  `registry_path_scanner_test` = **16/16 通过**。
- ⚠️ **未真机走查**（清单见 SESSION_HANDOFF 当日行）。
- ⚠️ `Content-Range` 校准 / 单流续传 / 看门狗透出均无真机回归。

## 4. 下载强度三档（2026-09-26 批D，用户批准后**已实施**）

**新增 `lib/services/download_intensity.dart`**：
- `DownloadIntensity`（auto/light/full）+ `DownloadIntensityPrefs`
  （prefs 两键：`download_intensity`、`download_speed_limit_mbps`，0=不限速）
- `DownloadThrottle`：全局令牌桶限速（所有任务共享一个桶；rate≤0 直通零开销；
  桶容量 max(2MB, rate)；单次等待上限 500ms，防极低速率长阻塞进度发射）

**档位语义**：

| 档 | 并发 | 单片 | 探测 | 限速 |
|---|---|---|---|---|
| 自动（默认） | 2–4 | 16/32/64MB | 4MB 探测，结果记忆 24h | 不限 |
| 轻量 | 1 | 8MB | 跳过 | 切档时未配置则自动 2MB/s |
| 全速 | 6 | 64MB | 跳过 | 不限 |

- 6 连接依据：OpenList 类网盘对单 IP 通常限 8 连接以内，留余量避免 429
- 轻量/全速与档位记忆命中时，用 1 字节 Range 请求
  （`download_core._calibrateTotalViaRange`）补 Content-Range 总长校准，
  C5 校准能力不丢；档位记忆过期自动重新探测
- 限速只约束正式下载读流（分片 + 单流两处 `DownloadThrottle.acquire`），
  **不约束探测**——否则限速值会压低探测吞吐导致档位判断失真
- 轻量/全速不走档位 switch：`_startMultiChunkDownload` 增加
  `forceChunkSize:/forceConcurrency:` 显式指定分片计划

**设置页**：`settings_modal.dart`「网络」分组新卡「下载强度」：三档单选 +
全局限速滑条（0–100 MB/s，步进 0.5，0=不限）；修改对下一次下载任务生效。

## 5. PB `games.downloadUrl` 路径对账（2026-10-16：39 条失败 → 修正 26 条）

**触发**：夸克网盘游戏库迁移（见 `openlist_semi_portable_plan.md` §11）后全量回归，
PB 434 条中 39 条 `fs/get` 报 `object not found`（1 条为空）。

**判定口径**：逐段 `ls` 归一化匹配（NFKC 全角折叠 → 小写 → 去空格）+ 同族记录穷举；
每条候选都先 `fs/get` 确认返回真实体积后才写入。回滚件
`.workbuddy/_ol_pb_dlurl_bak_*.json`（含 26 条 old 值）。

**已修正 26 条**：

| 作品 | 旧值 | 新值 |
|---|---|---|
| 近月少女的礼仪2.2 | `/JYSN/2.2` | `/JYSN/2.2.zip` |
| 少女理论及其之后的周边 | `/JYSN/G1` | `/JYSN/G1.zip` |
| 少女理论及其周边 -École de Paris- | `/YJSN/G2.zip` | `/JYSN/G2.zip` |
| Rewrite+ | `/key/Rewrite/Rewrite+.zip` | `/key/Rewrite/[160729][Key] Rewrite+.zip` |
| Friend to Lover | `/FTL/FTL..zip` | `/FTL/FTL.zip` |
| VenusBlood Frontier | `/VenusBlood/VenusBlood -FRONTIER.zip` | `/Venusblood/VenusBlood -FRONTIER.zip` |
| VenusBlood -RAGNAROK | `/VenusBlood/VenusBlood -RAGNAROK.zip` | `/Venusblood/VenusBlood -RAGNAROK.zip` |
| GINKA-银花 | `/GINKA.zip` | `/Ginka.zip` |
| 恋爱少不了撒娇～番外篇FD1 | `/恋爱少不了撒娇/恋にはあまえが必要ですFD1` | `/恋爱少不了撒娇/恋にはあまえが必要ですFD1.zip` |
| 仰望夜空的星辰 | `/抬头看看吧看那天上的繁星/抬头看看吧看那天上的繁星.zip` | `/抬头看看吧看那天上的繁星/【官中】抬头看看吧，看那天上的繁星.zip` |
| FLOWERS 春篇 | `/FLOWER/FLOWERS春.zip` | `/Flower/FLOWERS春.zip` |
| FLOWERS 夏篇 | `/FLOWER/FLOWERS夏.zip` | `/Flower/FLOWERS夏.zip` |
| FLOWERS 秋篇 | `/FLOWER/FLOWERS秋.zip` | `/Flower/FLOWERS秋.zip` |
| FLOWERS 冬篇 | `/FLOWER/FLOWERS冬.zip` | `/Flower/FLOWERS冬.zip` |
| Muv-Luv Alternative | `/Muv-Luv/Muv-Luv Alternative.zip` | `/Muv-luv/Muv-Luv Alternative.zip` |
| Sugar*Style …Happiness Pack | `/Sugar＊Style/Sugar＊Style Music and Happiness Pack` | `/Sugar＊Style/Sugar＊Style Music and Happiness Pack.7z` |
| 苍之彼方的四重奏：交予世界的答卷 | `/CZBF/CZBFDJ.rar.lz4` | `/CZBF/CZBFGJ.rar.lz4` |
| Dark Blue | `/十二神器/DB.zip` | `/十二神器/BD.zip` |
| 星空列车与白的旅行 | `/星空列车与白的旅行.zip` | `/星空铁道与白的旅行.zip` |
| 月姬-A piece of blue glass moon- | `/型月/月姬Remark.zip` | `/型月/月姬Remakke.7z` |
| 青空下的加缪 | `/青空下的加缪。zip` | `/青空下的加缪.zip` |
| 夏空彼方 | `/夏空彼方/夏空彼方.zip` | `/夏空彼方.zip` |
| 夏空彼方：塔弦之雪 | `/夏空彼方/塔弦之雪.zip` | `/塔弦之雪.zip` |
| 魔女恋爱日记 Dragon×Caravan | `/魔女恋爱日记/魔女恋爱日记FD.zip` | `/魔女恋爱日记/魔女恋爱日记Dragon×Caravan.zip` |
| 恋色空模样 | `/恋色/恋色空模样｜恋色空模様.zip` | `/恋/恋色空模样｜恋色空模様.zip` |
| 【第26作】神楽黎明記 紫之章～参 | `神乐黎明记 26～紫之章～ 叁｜神楽黎明記～紫の章～ 参.zip` | `/神楽黎明記/神乐黎明记 26～紫之章～ 叁｜神楽黎明記～紫の章～ 参.zip` |

**明确不修 13 条（网盘无对应文件，需你决定）**：

| 作品 | 原因 |
|---|---|
| 巨乳幻想1 / 巨乳幻想外传 | `koyu系列/koyu正/koyu` 下 **一代目录整体不存在** |
| 巨乳幻想2 / 巨乳幻想2 if | 二代目录内无 `【2】…HD AI.zip` / `【2IF】…AI.zip`（仅剩 2.01/2.1/2.2/2IF.1/2IF.2） |
| 巨乳幻想外传2 / 外传2 after ×2 | 二代目录内**无** `【巨乳ファンタジー 外伝 2 (二代外传  After)】` 子目录 |
| 巨乳幻想3 / 3 if / 3 if _s | 三代目录仅剩 `巨乳ファンタジー3 数字小说.zip` |
| 巨乳幻想 4 ～修道士阿斯特鲁～ | **四代目录不存在** |
| 巨乳幻想5-王子里恩- | 五代下只剩**空目录** `巨乳ファンタジー5-王子リーン` |
| 恋爱~宣告！ | 根级无 `/らぶでれーしょん！.zip` |

> 另注：`koyu系列/巨乳幻想2ifHDcode@vieira/` 下有 `kf2if.part1~4.rar` **分卷**，单文件下载语义不兼容（应用只取一个 URL），故未映射。


## 6. 下载「取链接失败」静默无提示修复（2026-10-16：CtDownloadOutcome 三分）

**触发**：真机反馈「未获取到链接无法开始下载时没有报提示，全程无反应」。

**定位**（只读审计）：云端下载只有一条入口 —— 桌面详情页「获取」→「Chrono Tide 下载」
浮层（`widgets/game_detail/ct_download_dialog.dart`）→ 浮层内 ⬇ →
`game_detail_page._handleInstallTap` → `CloudInstallFlow.submit`。第 ④ 步
`OpenListService.getGameDownloadUrl(downloadPath)` 返回 null 时上层返回
`CloudInstallResult.linkFailed`，而 `_handleInstallTap` 只 `setState(_linkError = true)`；
**渲染该位的 `_buildIdleUI()` 在 v4.0 重构后已无调用点**（文件内
`// ignore: unused_element` 自证）⇒ 失败提示是死代码。浮层 `state` 又是打开时的快照，
页面 `setState` 不会重建浮层内容 ⇒ 观感为「按钮毫无变化、全程无反应」。

> 与 §5 的关系：§5 修正了 26 条 `games.downloadUrl` 路径错误，但**仍会失败的路径**
> 此前是静默的 —— 本节修的是「失败必须可见」这一层，与数据侧修正互补。

**改动**：

| 文件 | 改动 |
|------|------|
| `lib/widgets/game_detail/ct_download_dialog.dart` | 新增 `CtDownloadOutcome`（`started`/`cancelled`/`failed(message)`）；`onDownload` 由 `VoidCallback` → `Future<CtDownloadOutcome> Function()`；浮层自管 `_busy`/`_error`：进行态按钮转圈 + 拒重复点、失败内联红字可原地重试、`started` → `maybePop()` 关浮层、`cancelled` → 保持不提示 |
| `lib/pages/game_detail_page.dart` | `_handleInstallTap` 改返回 `CtDownloadOutcome` 并四分支映射（submitted/duplicate → started；cancelled → cancelled；linkFailed/catch → failed）；`_getButtonBusy` 加 `|| _isSubmitting` |

**为什么失败提示走浮层内联而非全局提示**：`AppSnackBar` 已迁到顶层
`SystemNoticeLayer`（`main.dart` 挂 `MaterialApp.builder` 最顶层，**不会被深色浮层遮住**），
但气泡位置在窗口右上角；用户刚点的是浮层里的 ⬇，视线在同一处 ⇒ 内联红字更直观、且可
原地重试。成功类提示（已提交 / 已在队列）仍走 `AppSnackBar`。

**验证**：进程内 analyzer 3 文件 **0 error**（5 warning 为既有 `_gameData!.title!` 行，不在
diff 区块）；✅ `flutter test`：`ct_download_dialog_test` **8/8**（新增 4 例）、
`test/widgets/game_detail/` + `bpm_game_detail_page_test` **21/21**。⏳ 真机走查待做。

**明确不改**：`CloudInstallFlow` 直链语义与重试、`GlobalInstallCenter`、`OpenListService`
取链逻辑、NSFW、BPM。保留 `_linkError` 与废弃方法不删（AGENTS §2.3）。

---

## DL-DISK-GUARD / DL-CACHE-FOLLOW-INSTALL（2026-11-03）

> 本节修的是「下载段在磁盘写不下时会假装还在下载」与「缓存目录写死在软件盘」两件事，
> 与上文的链路过期 / 失败可见性互补。

### 现场（用户 2026-11-03 实测）

14GB 的包下到 53.4% 停在 `0 B/s`，界面一直「正在下载」。
`Release/logs/CT_2026-11-03_运行日志.txt:60-77`：

```
FileSystemException: writeFrom failed, path = '...\downloads/TouhouOfficialLauncher_v3.4.zip.part_15.tmp'
(OS Error: 磁盘空间不足。, errno = 112)
```

- D 盘 326G 用满，剩 632K；`downloads/` 18 个 `.part_*.tmp` 共 6.99GiB，
  四个仍在写的分片在 `21:46:01.645` **同一毫秒**冻结，之后 6 分钟零增长。
- 进度 53.4% 是假数：`8.46G ÷ 15.05G × 0.95`（HEAD 报 15,048,210,816，32 片 ×
  470,256,588），而磁盘上只有 7.0GiB —— 因为 `receivedBytes` 记的是**网络读到的字节**。

### 四层护栏

| 层 | 位置 | 行为 |
|----|------|------|
| 目录 | `services/download_cache_dir.dart` | 缓存跟随本体安装盘：同盘不改；跨盘 → `<安装盘>:\ChronoTide_Cache\downloads`，写 1 字节探测 + 剩余 ≥512MB，三级回退；结果持久化 `download_cache_dir` |
| 准入 | `download_core._ensureDiskSpaceEnough` | 分片需 `2×文件 + 512MB`（分片与合并文件同时存在），单流 `1×+512MB`；查不到空间按未知放行 |
| 巡检 | `download_core._monitorDiskSpace` | 每 5s 查一次，低于「未完成字节 + 512MB」→ 停表 + 取消分片 + 报「还剩多少/还差多少/哪个盘」 |
| 写入 | `download_core._writeToFile` / `_openFileForWrite` | `RandomAccessFile.writeFrom`（错误一定抛回本次 attempt）；112/39（磁盘满）、5（拒绝访问）→ `_FatalWriteException`，**不重试不退避** |

### 关键坑

- 🔴 `IOSink.add` 的写错误会经 `_FileStreamConsumer.addStream` **异步链路逃逸到 zone**，
  被 `app_log_helper.dart:143` 的 `PlatformDispatcher.onError`（`return true`）吞掉 ⇒
  `await for` 与循环末尾的 `flush()` 都未必接得住。实测对照：`dev_probe/verify_disk_guard.dart` ④。
- 🔴 `File.open` 自己也会抛 `FileSystemException`（目录/无权限 = errno 5、路径不存在 = 3），
  必须一并走分类，否则「打不开分片文件」会被当网络抖动重试 15 轮 ≈ 3 分钟。
  实测：`dev_probe/verify_open_error.dart`。
- 🔴 取消时 `_handleCancel` 的清理早于分片句柄关闭，Windows 删不掉被占用文件 ⇒
  实测会残留 `.part`；`start()` 在下载段中止后补一次 `_cleanupTempFiles()`。
- 🔴 `flutter_tester` 下**异步 `Directory.create(recursive: true)` 会永久挂起**
  （event loop 抽干后进程静默 exit 0）⇒ 探针里目标目录一律先 `createSync`。

### 验证

- `dev_probe/dl_guard_e2e_probe.dart` 16/16、`dl_cache_dir_probe.dart` 8/8、
  `verify_disk_guard.dart` 10/10；进程内 analyzer 5 文件 0 error。
- ⏳ 未做：`flutter analyze` / `flutter test` 全量（231）、真机走查、Release 重打包。

---

## DL-CACHE-PER-INSTALL（2026-11-03 第二轮）· 缓存跟随安装位置 + 全生命周期清理

> 上一节（DL-DISK-GUARD）解决了「磁盘满了还在假装下载」。本节解决**缓存放错地方**
> 和**垃圾永远不清**：用户把游戏装到别的盘，结果缓存仍写回软件所在盘；装完之后
> 十几个 GB 的压缩包永远躺在盘上。

### 目录分工（用户明确定义，不要再合并回去）

| 用途 | 目录 | 说明 |
|------|------|------|
| 游戏本体下载缓存 | `<库根>\ChronoTide_Cache\downloads` | 跟随用户选择的安装位置 |
| 软件自身资产（App 更新包等） | `exe\downloads`（`PathHelper.defaultDownloadsDir`） | **不再承载任何游戏安装包** |

**库根** 的定义：
- 自定义安装 `E:/Games/SomeGame` → 库根 = `E:/Games` → 缓存 `E:/Games/ChronoTide_Cache/downloads`
- 默认安装（未选位置，落 `exe\Games\<游戏名>`）→ 库根 = `exe` → 缓存 `exe\ChronoTide_Cache\downloads`

候选顺序：`<库根>\ChronoTide_Cache\downloads` → `<安装盘>:\ChronoTide_Cache\downloads` →
出厂 `exe\downloads`（全失败才回退，下载不至于打不开）。

### 为什么不直接塞进游戏目录

`customGameLocation` 是**游戏本体最终目录**，解压输出也落在这里。缓存塞进去会让
解压产物与下载残留混在同一棵树里，安装完删缓存又容易连本体一起误伤。所以取
**父目录**（库根）——同盘、同区域，但不同层。

### 全生命周期清理

| 时机 | 行为 | 位置 |
|------|------|------|
| 成功 | 删缓存里的原压缩包（**只删托管缓存内的**，用户本地自选的包绝不动）+ 空缓存根一并收掉 | `extract_manager._cleanupManagedArchive` |
| 取消 | `_cleanupTempFilesWithRetry`（删→复查→退避重试最多 4 轮，句柄晚释放也能删净）+ 空目录收掉 | `download_core._handleCancel` |
| 失败（磁盘满 / 写入被拒） | **不可续传** → 立刻删已下分片把空间还回去，提示不再说「重试从断点继续」 | `download_core._handleError` |
| 失败（网络类） | 保留分片以续传（这是特性，不是漏清理） | 同上 |
| 启动 | 扫 `scanDirs`（出厂 + 当前 + **历史用过的**，去重）清 `.part_*` / `.chunk_*` / `.tmp` | `interrupt_cleanup` |
| 用户手动 | 设置页「下载残留」+ 存储清理，同样扫 `scanDirs` | `storage_cleanup_service` |

### 关键坑

- 🔴 `extract_manager.dart` 的 `static final _downloadsDir = PathHelper.downloadsDir`
  是**定时炸弹**：缓存目录现在按安装位置动态解析，`static final` 会在首次访问时
  把旧值永久固化 ⇒「下载写到 E 盘、解压却去 D 盘找包」。已改 getter。
- 🔴 **历史目录必须记账**：用户换一个盘装游戏，缓存目录就换一处，上一处的失败分片
  再没人管。已加 `download_cache_dir_history`（prefs，最多 8 条）。
- 🔴 判断「能不能删这个包」不能只看文件名：必须 `isManagedCachePath`
  （落在缓存目录内 or 路径含 `ChronoTide_Cache` 段），否则会删掉用户自己的存档包。
- 🔴 `flutter_tester` 下异步 `Directory.create(recursive: true)` 会永久挂起 ⇒
  `DownloadCacheDir._probe` 与 `cleanupIfEmpty` 改为**同步 IO**（都是微秒级操作），
  否则探针根本测不到这段逻辑（第一版探针就在这里静默 exit 0）。
- 🔴 `deleteManagedArchive` 用同步 `deleteSync`：解压成功回调里没有别的 await 竞争，
  同步删能保证「返回时文件一定已经不在」。

### 验证

- `dev_probe/dl_cache_dir_probe.dart` **18/18**：默认/同盘/跨盘三种落点、appAssetsDir
  分家、`isManagedCachePath` 三向判定、空目录清理、删包/不删用户包/文件不存在。
- `dev_probe/dl_guard_e2e_probe.dart` **16/16**（回归，缓存目录已落到探针临时目录下的
  `ChronoTide_Cache`）。
- 进程内 analyzer 6 文件 **0 error**。
- ⏳ 未做：解压成功后删包的**端到端**验证（需真实 7z 环境，flutter_tester 下
  `toolsDir/7z.exe` 不存在）；`flutter analyze` / `flutter test` 全量（231）；真机走查。

---

## STORAGE-DL-AUDIT（2026-11-03 第三轮）· 存储 / 下载全链路审计

> 用户要求「检查存储系统和下载系统还有没有明显漏洞」。逐条走完两条链路，修了 8 处。

### 修掉的（按严重度）

| # | 严重度 | 位置 | 问题 |
|---|--------|------|------|
| 1 | **P0** | `download_core._monitorDiskSpace` | 分片模式**合并阶段**还要再产出一份完整文件，峰值仍是 2×P；旧巡检只留「剩余下载量 + 512MB」⇒ 下到 90% 时必过，合并刚开始就炸（用户看到的是「99% 突然失败」） |
| 2 | **P0** | `extract_manager` | **完全没有解压前空间检查**。下载准入 2×P 通过 → 合并后只剩 1×P → 解压产物写不下 → 解压到一半失败并回滚，用户白下几十 GB |
| 3 | **P0** | `download_core.start` | 解压失败后压缩包按策略保留，但用户点重试会**把整包从头再下一遍**（盘上那份还占着）⇒ 用 28GB 读写换一份已存在的文件 |
| 4 | P1 | `download_core` 多实例 | 安装中心与主页任务管理器各持一个 `DownloadCore`，可同时下载；两者按 2×P **各自独立**判断，同盘时都以为够 ⇒ 一起写满 |
| 5 | P1 | `storage_cleanup._clearDirectoryContents` | `list()` 默认 `followLinks: true`，目录里的符号链接/junction 会被当真实目录**递归删到链接目标** |
| 6 | P1 | `CleanupUtils.deleteWithRetry` | 不认 `Link` 类型，落进 `Directory.delete(recursive: true)` 分支同样会顺链接删目标 |
| 7 | P1 | 5 处清理/扫描 | 用 `contains('_temp_layer_')` 判定临时层并**递归删除** ⇒ 名字里恰好含该片段的真实游戏目录会被误删 |
| 8 | P2 | `path_validator._isSystemDirectory` | 只硬编码 4 个 `C:/` 前缀，漏了**盘根**（`D:/` —— 清理逻辑对盘根一律跳过，装进去收不回）、其他盘/其他语言的系统目录、回收站 |

另外补了一处体验漏洞：`storage_cleanup._clearTempFiles` 在下载/解压进行中会清空 `data/tmp`（智能导入封面、发布预览图、更新包分片都在这儿），改为有活跃任务时跳过。

### 修法

- **合并预留**：巡检 `need = remaining + (分片模式 ? P : 0) + 512MB`。
- **解压准入**：`ExtractManager._precheckExtractSpace` —— 目标盘剩余 < `包体积 × 1.15 + 256MB` 时直接失败，文案明确「压缩包已保留在 X，腾出空间后可直接重试解压，不必重新下载」。
- **跳过重下**：`_hasCompletePackage` 判定「缓存里已有同长度（±1%）的完整包」→ 跳过下载直接进解压。刻意不做全量哈希（GB 级包几十秒，与收益不成比例）；包若损坏，解压会明确失败，用户删缓存再试。
- **全局预留**：新增 `download_space_budget.dart`，按盘符登记每个任务的承诺量，准入口径 `可用 = free - 其他任务已承诺`，`start()` 的 `finally` 无条件释放（按 taskId 全盘清理，防泄漏成永久误拦）。
- **链接安全**：`_clearDirectoryContents` 加 `isInsideAppStorage` 护栏 + `followLinks: false` + `Link` 分支（只删链接本身）；`CleanupUtils` 同样补 `Link` 分支。
- **临时层判定**：统一 `PathHelper.isTempLayerDirName`（正则 `_temp_layer_\d+$`），5 处调用点全部替换；扫描器/迁移器额外跳过 `ChronoTide_Cache`（自定义安装选在 `Games/` 内时缓存根会出现在那里）。
- **系统目录**：改用「盘根正则 + 环境变量（SystemRoot / ProgramFiles / ProgramData…）+ 回收站」判定，跨盘符跨语言都成立；有意**不**挡 `%USERPROFILE%`（很多人就把游戏放在 `C:/Users/xxx/Games`，挡掉属误伤）。

### 关键坑

- 🔴 `while (lower.length > 3 && endsWith('\\'))` 会漏掉 `d:/`（长度正好 3，反斜杠没被剥掉，盘根正则失配）。边界必须是 `> 2` —— 探针第一条就把这个抓出来了。
- 🔴 预留表只记「其他任务」：`reservedByOthers` 必须排除自己，否则本任务会自己扣自己，第二次重试就被误拦。
- 🔴 跳过重下后仍要走后面的「大小校验 → completed → 解压」原路径，不要另开一条返回分支，否则状态机与 UI 回调会分叉。

### 验证

- `dev_probe/storage_download_audit_probe.dart` **20/20**：临时层判定 6 向、预留登记/释放/盘符归一、系统目录 6 向（盘根 / `D:` / Windows / Program Files / `%ProgramData%` 跨盘 / 普通目录不误伤）。
- `dev_probe/dl_guard_e2e_probe.dart` **20/20**（新增用例 F：第二次 start **147ms** 直接 completed，服务端 body 请求数 `before=2 after=2` —— 确实一个字节都没重下）。
- `dev_probe/dl_cache_dir_probe.dart` **18/18** 回归。
- 进程内 analyzer 12 文件 **0 error**。
- ⏳ 未做：解压准入的真机验证（需真实 7z 环境）；`flutter analyze` / `flutter test` 全量（231）；Release 重打包。
