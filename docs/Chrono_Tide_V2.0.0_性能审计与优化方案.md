# Chrono Tide V2.0.0 性能审计与优化方案

- **日期**：2026-08-29
- **执行人**：架构师（高见远 / Bob）
- **性质**：只读审计 + 方案设计。**未修改任何 lib/ 代码**，本报告是唯一产出文件。
- **前置约束**：不升级依赖、不换技术栈、不提服务端改造、保证功能完整、不破坏《上线前核查报告》中的 24 处修复。
- **基线数据**：直接采信主理人实测（产物 230MB / 安装包 74.2MB，Inno lzma/ultra + solid 压缩，见 `ChronoTide_Setup.iss:22-23`）。

---

# 第一部分　产物体积裁剪方案

## 1. openlist.exe（149MB，占产物 65%）

**调研结论**：官方 OpenList Windows release 体积远小于当前这份。
OpenListTeam/OpenList 官方 release（GitHub，2025-06 起）：
`openlist-windows-amd64.zip` ≈ **30MB**（v4.0.0，2025-06-21）/ 47MB（v4.1.1，2025-08-18，含完整 web 资源），lite 版 zip ≈ 26MB。zip 内单 exe 解压后典型 **50~90MB**。

而项目内 `openlist/openlist.exe` 实测 **155,284,992 字节（≈148MB）**，文件时间 **2025-04-09** —— 早于 OpenList 项目存在的时间（2025-06 AList 事件后才 fork）。**判断：这不是官方 release 产物**，大概率是（a）自编译且未 strip（未加 `-ldflags "-s -w"`）、或（b）AList 时代的 dev/调试构建、或（c）内嵌了未压缩的调试信息与完整 web dist。**结论：当前这份属于异常体积，替换为官方精简版有充分依据。**

### 四选项对比

| 选项 | 预期收益（产物 / 安装包） | 风险 | 成本 | 开箱即用 | 建议 |
|---|---|---|---|---|---|
| A. 换官方 release exe | **−85~105MB / −30~45MB** | 中：版本兼容需验证（见下） | 2~4 人时 | 不变（仍是本地文件随包分发） | **推荐（激进档）** |
| B. 自行 strip 重编译 | −40~60MB / −15~25MB | 高：需要 Go 工具链与源码版本对齐，且"不升级依赖"约束下复现原构建环境成本高 | 8+ 人时 | 不变 | 不推荐 |
| C. 首次使用时按需远程下载 | −149MB / −65MB（安装包侧收益最大） | 中高：改变分发方式；更新下载通道当前无完整性校验（与 P0-5 同类风险，劫持即向用户磁盘投放可执行文件）；离线用户功能缺失 | 6~10 人时 | **受损**：远程安装功能首用时需联网等待 | 暂缓，待更新校验（P0-5）落地后再评估 |
| D. 保持现状 | 0 | 0 | 0 | 不变 | 保守档默认 |

**选项 A 的回归验证点**（OpenList 是本地子进程，替换二进制属客户端行为，不违反"服务端不动"）：
1. `lib/services/openlist_service.dart` 的启动参数、端口、健康检查与新版兼容；
2. 远程下发配置（核查报告 P0-6 遗留项）在新版上仍能生效；
3. 已有 `runtime/openlist/data/`（配置和数据库）能被新版读取——**先在测试机用旧 data 目录实测**，`[InstallDelete]` 已明确该目录绝不清理（`ChronoTide_Setup.iss:116`）。

## 2. manifest.yaml（16.7MB，flutter_assets 内）

**证据**：`pubspec.yaml:57`（asset 声明）；`lib/services/manifest_service.dart:41`（`rootBundle.loadString` 全量读入）；`lib/services/save_manifest.dart:797`（`fromYaml` 同步解析 5 万+ 条目）。**关键问题：`main.dart:474` 在 `runApp` 之前 `await ManifestService.instance.init()`** —— 16.7MB 字符串读取 + YAML 解析发生在首帧之前的启动串行链上。

### 选项对比

| 选项 | 体积收益 | 启动收益 | 风险 | 成本 | 建议 |
|---|---|---|---|---|---|
| 启动后台加载（延后到首帧后） | 0 | **高**（主 isolate 让出 0.3~1.5s） | 低：`SaveScanner` 在 `isReady=false` 时回退通用检测（`manifest_service.dart:11`，设计内建） | 1~2 人时 | **P0，强烈推荐** |
| 压缩为 zip/gz asset，加载时解压 | 产物 −13~14MB；安装包 ≈0（yaml 文本 lzma 已压到 ~3MB，见 §6 说明） | 略负（解压耗 CPU，但可配合后台加载抵消） | 低 | 2~3 人时 | 激进档可选 |
| 拆分索引 / 按需从服务器拉取 | 产物 −15MB | — | 高：需要服务端配合（**违反约束**）；首用需联网；离线存档识别退化 | — | **否决** |
| 保持内置 + 保持首帧前 await | 0 | 0 | 0 | 0 | 不推荐（白白拖慢首帧） |

**如实评估懒加载代价**：manifest 是 SaveScanner 存档识别的数据源（`lib/services/save_scanner.dart`）。延后加载后，若用户在启动后极短时间内（<2~3s）就触发存档备份/扫描，会走通用检测分支，识别精度暂时下降；随 `init()` 完成自动恢复精确识别。存档扫描不是首屏功能，此代价可接受。

## 3. Magpie effects 目录（17MB）

**依赖关系核查**（`lib/services/magpie_service.dart`）：
- 内接模式只要求 `runtime/magpie/Magpie.exe` 存在（`magpie_service.dart:670-671`）；效果目录 `internalMagpieEffectsDir = runtime/magpie/effects`（`:737-738`）。
- 应用侧所有缩放模式的效果引用只有两处来源：内置模式表（`magpie_service.dart:107-300`）与随包模板（`assets/magpie/scaling_modes_template.json`，15 个模式）。全库 grep（CuNNy/RAVU/NNEDI3/xBRZ/SMAA/FXAA/NIS/CAS/Sharpen/Jinc 等在 lib/ 下零命中）确认：**应用只会引用 17 个效果**：
  `Anime4K\`（Upscale/Restore 系列）、`FSR\FSR_EASU`、`FSR\FSR_RCAS`、`FSRCNNX\FSRCNNX`、`ACNet`、`CRT\CRT_Geom`、`Bicubic`、`Lanczos`、`Nearest`。

**实测体积**（Magpie-v0.12.1-x64/effects，与打包的 runtime/magpie 同源，16,762KB）：

| 分类 | 体积 | 说明 |
|---|---|---|
| 被引用（必须保留） | **≈3.3MB** | Anime4K + FSR + FSRCNNX + ACNet.hlsl + CRT_Geom + Bicubic/Lanczos/Nearest |
| **未被引用（可裁剪）** | **≈13.4MB** | CuNNy 4952K + CuNNy2 2400K + RAVU 2804K + NNEDI3 2540K + SMAA 412K + xBRZ 100K + NIS 60K + Sharpen 48K + CAS 36K + FXAA 24K + SSimDownscaler 12K + Deband/ImageAdjustment/Jinc + CRT 其余 4 个 hlsl ≈40K |

另有 `TouchHelper.exe`（432KB）与 `Updater.exe`（508KB）随 Magpie 分发，内接场景用不到（Magpie 嵌入使用时不做自更新、无触屏需求），可一并移除 ≈1MB。`Microsoft.UI.Xaml.dll`（5.6MB）与 `resources.pri`（2.4MB）是 Magpie（WinUI3）运行硬依赖，**必须保留**。

- **预期收益**：产物 **−14.4MB**；安装包 −5~7MB（.dds 是块压缩纹理，lzma 对它收益有限，.hlsl 文本收益好）。
- **风险**：低-中。用户手动改 `runtime/magpie/config/config.json` 引用被裁效果 → 该模式启动时报错（Magpie 对缺失效果的处理是模式不可用，不影响其他功能）。缓解：裁剪清单写入文档；后续可提供"完整效果包"可选下载。
- **成本**：1~2 人时（改打包脚本 [Files] 排除清单 + 一次冒烟：内置 15 个模式逐个启动验证）。
- **是否影响功能**：不影响应用内任何已有功能入口。

## 4. app.so（13MB，Dart AOT）

| 选项 | 说明 | 收益 | 风险 | 建议 |
|---|---|---|---|---|
| `--obfuscate --split-debug-info` | 构建命令参数，不改代码。剥离符号后 AOT 体积典型降 10~15% | 产物 −1~2MB，安装包 −0.5~1MB | 中低：混淆后崩溃堆栈不可读，必须按 release 归档保存 `.symbols` 文件，用 `flutter symbolize` 还原（团队已有日志排查习惯，流程可承接） | **P0 推荐**，一次性收益且随版本持续 |
| `--split-per-abi` | **不适用**。该参数仅对 Android 多 ABI（armeabi-v7a/arm64/x86_64 分包）有意义；Windows 只有单一 x64 产物，无可拆分对象 | 0 | — | 否决 |

**注意**：混淆是全局开关，开启后需完整跑一遍核心回归（启动、启动游戏、入库、云端登录），因为所有 `debugPrint` 之外的异常文本排查都依赖 symbols 归档纪律。与核查报告"全局错误处理合并"修复（`main.dart:364-371`）无冲突。

## 5. 字体 / 图片 / 工具 DLL

| 项 | 现状 | 核查结论 | 建议 | 收益（产物/安装包） | 风险 |
|---|---|---|---|---|---|
| 志莽行书 TTF 3.9MB | `pubspec.yaml:60-62`，`ZhiMangXing` 在 lib/ 下 **35+ 个文件**引用（标题、卡片、手柄模式等装饰文本），**不是**单标题字体，不能删 | 用 [fonttools/pyftsubset](https://fonttools.readthedocs.io/) 子集化到 GB2312 常用 3500 字 + ASCII + 常用标点 | 激进档：子集化后 ≈1.2~1.5MB | −2.4~2.7MB / −1.5~2MB | 低-中：用户自定义游戏标题含生僻字时回退默认字体（视觉不一致但可用）。保守档不动 |
| app_icon.ico 0.8MB | 托盘图标用（`lib/services/tray_service.dart:107-109`） | .ico 内嵌了全尺寸多分辨率位图，过度 | 重制为 256/48/32/16 四档，≈120KB | −0.7MB / −0.6MB | 低 |
| 主题 PNG 2.3MB | `assets/images/themes/`：blue_sky 744K、dark_emerald_gold 756K、sakura 688K、ink_green 104K | 照片型背景图，WebP q85 体积 ≈1/4 | 转 WebP + 全局替换引用路径（`assets/images/` 声明是目录级，pubspec 无需改） | −1.6~1.8MB / −1~1.5MB | 低（Flutter Windows 原生支持 WebP） |
| assets/tools/ ≈4.6MB | bz.exe 544K、UnRAR.exe 560K、ark.x64.dll 2.2M、ark.x64.lgpl.dll 760K、bdzshl.x64.dll 564K | **五个全部必需**：`lib/services/rar_lz4_unzip_service.dart:17-23` 明确列出 Bandizip 运行时全套依赖（bz.exe 解 LZ4 外层 + UnRAR.exe 解 RAR 内层 + ark DLL 是 bz.exe 的运行库）；`lib/services/extract_manager.dart:157` 运行时释放 | **保留，不可裁** | 0 | — |
| runtime/tools 5.1MB | 7z.exe 等 | extract_manager 通用解压依赖 | 保留 | 0 | — |

## 6. 两档汇总

> **压缩比折扣说明**：Inno lzma/ultra + solid 对"已压缩数据"（Go exe、.dds 纹理、WebP、视频）收益显著低于文本（yaml/hlsl/json）。产物每减 1MB，安装包通常只减 0.4~0.8MB，需逐项估算，不能按总压缩比 0.32 线性外推。

| 档位 | 包含项 | 产物 | 安装包 |
|---|---|---|---|
| 现状 | — | 230MB | 74.2MB |
| **保守裁剪** | effects 裁剪（−13.4）+ TouchHelper/Updater（−1）+ 主题 WebP（−1.7）+ ico 重制（−0.7）+ app.so 混淆（−1~2） | **≈211~213MB** | **≈65~67MB** |
| **激进裁剪** | 保守档全部 + 换官方 openlist（−85~105）+ manifest gz 化（−13，安装包收益≈0）+ 字体子集化（−2.4~2.7） | **≈108~125MB** | **≈28~38MB** |

（激进档安装包区间宽，主要来自 openlist 换版收益的不确定性：旧 exe 的可压缩性与官方版不同，需实打包验证。）

---

# 第二部分　运行时性能审计（静态分析）

## R1. 首屏加载：启动串行 await 链过长，manifest 解压/解析阻塞首帧 【影响：高】

**现象**：`main.dart:358-506` 在 `runApp()` 前有 **约 22 个串行 await**：
便携化存储（含整库迁移，`main.dart:358`）→ 日志初始化 → `InterruptCleanup.startupScan()`（遍历 downloads/ 与 games/ 目录做中断清理，`interrupt_cleanup.dart:157-215`）→ 日志轮转 → 数据迁移 → `LocalGameRegistry.scan()`（N 个游戏逐个读 game.json）→ 追踪模式 → 截图任务恢复 → 会话恢复 → QuickWindow → windowManager/主题/托盘 → UserCache → NetworkStatus → Magpie init → **`ManifestService.init()`（16.7MB YAML 读取+解析，`main.dart:474`）** → MetadataFetcher.init（VNDB 字典）→ DiscoverMetadata init → WatchFolder startAll → `runApp`。

**耗时构成估算**（SSD、50 个游戏）：`LocalGameRegistry.scan` 50~300ms；`ManifestService.init` **300~1500ms**（主 isolate 同步解析，直接推迟首帧）；MetadataFetcher + DiscoverMetadata（磁盘缓存加载）50~200ms；storage 迁移仅首次/有变化时显著；其余合计 100~300ms。**manifest 一项通常占冷启动 UI 前耗时的 1/3 以上。**

**建议**（按性价比排序）：
1. `ManifestService.init()` 移到首帧后（`WidgetsBinding.instance.endOfFrame.then` 或启动 3s 延迟），回退机制现成（R1 证据见 manifest_service.dart:11）；
2. `MetadataFetcher.init()` / `DiscoverMetadataService.init()` 延后到探索页/详情页首次进入时懒初始化（二者均有 try-catch，`main.dart:486-501`，失败本就不阻断）；
3. `startupScan` 与 `GameDataMigration.migrateAll` 保持串行（有顺序语义），但 `ScreenshotFetchService.scanPendingGames` 可与 scan 并行（`Future.wait`）。

**风险**：低。均为时序调整，不改数据语义。**与 24 处修复交集**：`main.dart`（全局错误处理合并修复，`main.dart:364-371`）——回归点：启动期人为抛错验证日志仍落盘。

## R2. `didChangeDependencies` 全量重扫（窗口 resize 触发）【影响：高，问题仍在】

**证据**：`lib/pages/library_page.dart:750-753`——`didChangeDependencies` 无条件调用 `_refreshFromDisk()` → `LocalGameRegistry.instance.scan()`（全量磁盘扫描，`library_page.dart:726-736`）。**核查报告未列入修复项，该问题仍然存在**。窗口拖拽缩放、MediaQuery 变化（系统缩放/文字缩放，`main.dart:886-898` 的 builder 也会引发依赖变化）都会触发整库重扫 + `_loadGames` + 网格重建。50 个游戏时单次 scan 数百 ms，resize 过程中连续触发即造成明显卡顿。

**建议**：加 `_didInitialDependenciesRefresh` 标志只保留首次；后续数据变化已由 `_onRegistryChanged`（`library_page.dart:756-771`，区分 structural/playTimeUpdate 通知）覆盖，`didChangeDependencies` 里的重扫是冗余路径。另：`_silentRefresh()` 每次 `_coverPathCache.clear()`（`library_page.dart:744`）导致全部封面重新 `existsSync`/`findCoverFile` 扫描，可改为按 directoryPath 增量失效。

**风险**：低。**与 24 处修复交集**：`library_page.dart`（拖拽 RangeError 修复 `:1101`、搜索防抖）——回归点：过滤态拖拽、搜索后卡片数量变化时 `_cardKeys` 同步。

## R3. 每次结构刷新 O(N) 读 game.json（`_loadLaunchModes`）【影响：中】

**证据**：`library_page.dart:795-809`——对每个游戏 `await GameDataFormat.readGameJson()`，读取转区/超分模式；在 `_applyCustomOrder` 的两条路径被调用（`library_page.dart:835/843`），即每次载入/结构变更都全量读盘。卡片 build 内无逐帧重读（封面走 `_coverPathCache`，`library_page.dart:2254` 等；封面解码已限宽 `cacheWidth: 480`，`library_page.dart:2914-2932`，这部分是好的）。

**建议**：转区/超分模式本就持久在 `LibraryGame` 内存对象或可并入 registry 首次 scan 时读取；至少按 title 做进程内缓存 + 详情页修改时失效。

## R4. 常驻定时器负载【影响：低-中】

| 定时器 | 周期 | 位置 | 空闲成本 | 评估 |
|---|---|---|---|---|
| 启动请求检查 | 500ms | `main.dart:756` | 每 tick `dir.list()` 一次（通常空目录）≈0.1ms | 可接受；可优化为有请求目录存在时才降频到 200ms（现反了） |
| 游玩时长监控 | 2s（仅会话期间） | `local_game_registry.dart:2061-2064` | **无会话时自取消**（`:2109-2121`），设计良好 | 每 tick Win32 FFI 枚举进程 1~3ms，占比 <0.2% |
| 前台检测 | 500ms（仅会话期间） | `local_game_registry.dart:2069` | GetForegroundWindow FFI，微秒级 | 忽略不计；PowerShell 回退已有 60s 节流（`foreground_window_service.dart:115`，已修复项） |
| 快捷窗口轮询 | 2s（启用时） | `quick_window_service.dart:259` | 窗口枚举，毫秒级 | 可接受 |
| 网络探测 | 周期可变 | `network_status_service.dart:74` | HTTP 探测 | 低频，可接受 |
| WatchFolder 健康/轮询 | 5min / 配置 | `watch_folder_service.dart:495/766` | — | 可接受 |
| 详情窗口时长刷新 | 10s（窗口打开期间） | `game_detail_dialog.dart:181` | — | 可接受 |

**结论**：定时器体系总体健康（会话定时器自取消 + C1 互斥 `local_game_registry.dart:2124-2128` 已修复并发），空闲 CPU 可忽略。唯一注意点：`_checkActiveSessions` 每 tick 全量枚举系统所有进程（FFI `enumerateProcesses`），在 200+ 进程的机器上 2~5ms/tick，游戏运行中叠加游戏本身负载可感知但 <1%。

## R5. 游玩时长每 2s 全量重写 game.json【影响：中（磁盘写放大）】

**证据**：`local_game_registry.dart:2573-2613` `_writePlayTimeDirect` → `GameDataFormat.updateGameJsonAtomic`：每 tick **读入整个 game.json → 修改 → 写 .tmp（flush:true，即 fsync）→ rename**（`game_data_format.dart:42-46`）。写盘量 = 整文件大小 × 30 次/分钟。game.json 含 `sessions` 事实表（每会话追加一条，`local_game_registry.dart:2346-2350`，未见裁剪逻辑）与 `daily_play_log`（90 天滚动，`:2607-2612`）。估算：game.json 10~50KB（历史多的可达 100KB+）→ 精准模式前台游玩时 **18~90MB/小时** 写放大；每天 4h 游戏 ≈ 70~360MB；月 ≈ 2~10GB。对 SSD 寿命影响小但非零，对 HDD 是持续随机小写。

**建议**：将写盘周期 2s → 10~15s（内存照常每 2s 累加，落盘降频），崩溃丢失上限从 2s 变 15s——注意**这正是核查报告 P2-6 clamp 修复的同一片代码**，`lastSettledTime`/容忍窗口逻辑（`local_game_registry.dart:2247-2271`）在降频后仍自洽（delta 按真实间隔补计，宽松模式上限 600s 足够）。另外建议给 `sessions` 数组加保留策略（如保留最近 200 条 + 聚合进 stats），控制 game.json 无限增长。

**回归验证点**（与修复交集）：核查报告阶段2"clamp(0,4) 少计"修复——降频后需验证：游戏运行 1 分钟，时长统计误差 ≤±5s；睡眠唤醒不多计。

## R6. 截图/大图全分辨率解码【影响：中（内存尖峰）】

**证据**：
- `lib/widgets/screenshot_carousel.dart:457-459`——本地截图 `Image.file` **无 `cacheWidth`**。4K 截图解码 = 3840×2160×4B ≈ **33MB/张**，轮播 5 张即 150MB+ 内存尖峰，快速滑动时解码也在 UI 线程队列排队造成掉帧；
- `lib/big_picture/` 下 5 处 `Image.file`（big_picture_home.dart:205/922、big_picture_detail.dart:500、big_picture_game_card.dart:186、bpm_metadata_section.dart:194）同样未限宽；
- 对照组（正确做法）：library 卡片 `cacheWidth: 480`（`library_page.dart:2927-2932`）、探索页 `memCacheWidth: 480`（`discover_page.dart:1363`）。

**建议**：统一补 `cacheWidth`（轮播按视口宽度 × DPR，通常 1920~2560）；这是纯参数添加，零功能风险。

## R7. 内存与缓存上限

- 磁盘图片缓存：`PortableImageCacheManager`（`core/portable_image_cache_manager.dart:20-21`）沿用默认 200 对象/30 天清理，有上限，健康；但**网络大图未指定解码尺寸的调用点**与 R6 同理需检查（`game_detail_dialog.dart` 内截图片区沿用 carousel）。
- Flutter 全局图片内存缓存：未显式配置（默认 ~100MB/1000 张），桌面端合理，可不动。
- `_coverPathCache`/`_games`：字符串与对象引用，量级随库大小线性、单条极小，无泄漏风险。
- Stream/Timer/Controller 泄漏：QA 报告已列清单，此处不重复；与性能直接相关的只有 R6（解码缓存放大泄漏后果）。

## R8. 日志写入

启动链含日志轮转（`log_rotation_service.dart:257` 周期 Timer）；运行期 `[PLAYTIME]` 每 2s 一条 debugPrint + 游戏启动/退出日志，`debugPrint` 在 release 下走 `kDebugMode` 判空的开销极低且日志有轮转上限——可接受，不再展开。

---

# 第三部分　设备资源影响评估

| 场景 | CPU | 内存增量 | 磁盘 |
|---|---|---|---|
| 空闲（托盘挂后台，无会话） | <0.5%（500ms 目录检查 + 低频探测） | 常驻 ≈120~200MB（Flutter 引擎 + 图片缓存） | ≈0（日志轮转周期写） |
| 主界面浏览 | 1~3%（滚动时渲染） | +图片缓存至默认上限 ≈100MB | 封面缓存首次下载 |
| 游戏运行中（时长追踪开启） | +0.5~1.5%（FFI 枚举 0.5Hz + 前台查询 2Hz） | +30~80MB（截图预载，若详情窗口开着可达 +150MB，见 R6） | **18~90MB/h 写放大**（R5） |
| OpenList 运行时（按需启动） | Go 服务 ≈1% | +50~150MB 子进程 | 下载流量直写 downloads/ |
| Magpie 超分运行时 | GPU 为主 | +100~300MB（游戏分辨率相关） | ≈0 |
| 7z 解压入库 | 单核满载（预期行为） | 低 | 大量顺序写（预期行为） |

**结论**：
- **现代设备（8GB+ / SSD）**：不构成过度负担。唯一实质问题是 R5 写放大（月 GB 级）与 R2 resize 重扫的瞬时卡顿，均为体验问题而非负担问题。
- **低端设备（4GB / HDD）**：短板依次为——① 冷启动串行 IO 链（HDD 随机读 + 16.7MB manifest 解析，R1，可拖慢首帧 2s+）；② R5 在 HDD 上是持续寻道写，游戏本身也在这块盘时会互相拖累；③ 4GB 内存下 Flutter 100MB 图片缓存 + 33MB/张的未限宽解码（R6）容易触发系统级换页。**R1/R5/R6 恰好也是低端设备友好性最关键的三项。**

---

# 第四部分　优先级排序实施方案

| 编号 | 优化项 | 预期收益 | 风险 | 成本 | 优先级 | 批次 | 与 24 处修复交集 |
|---|---|---|---|---|---|---|---|
| O1 | Magpie effects 裁剪至被引用的 17 项 + 移除 TouchHelper/Updater | 产物 −14.4MB / 安装包 −5~7MB | 低-中 | 1~2 人时 | **P0** | B1 | 无（game_detail_dialog 的 Magpie 弹窗修复不涉及 effects）|
| O2 | ManifestService.init 移出首帧前启动链 | 冷启动首帧提前 0.3~1.5s | 低 | 1~2 人时 | **P0** | B1 | 无 |
| O3 | `didChangeDependencies` 重扫加首启守卫；`_silentRefresh` 封面缓存增量失效 | resize/依赖变化不再全库重扫 | 低 | 2~3 人时 | **P0** | B1 | ⚠️ library_page（拖拽修复 :1101、搜索防抖）→ 回归：过滤态拖拽、搜索切换后拖拽 |
| O4 | screenshot_carousel + big_picture 全部 `Image.file` 补 `cacheWidth` | 内存尖峰 −100MB+ 级；滑动更稳 | 低 | 1~2 人时 | **P0** | B1 | 无 |
| O5 | 主题 PNG → WebP；app_icon.ico 重制 | 产物 −2.3~2.5MB / 安装包 −1.5~2MB | 低 | 1~2 人时 | **P0** | B1 | 无 |
| O6 | app.so `--obfuscate --split-debug-info`（建 symbols 归档规范） | 产物 −1~2MB / 安装包 −0.5~1MB | 中低 | 1 人时 + 流程 | **P0** | B1 | ⚠️ main.dart 全局错误处理 → 回归：异常日志可读性（symbols 还原演练 1 次）|
| O7 | 游玩时长落盘 2s→10~15s；sessions 数组加保留策略 | 写放大降 5~7 倍（月省 2~8GB） | 中 | 2~3 人时 | **P1** | B2 | ⚠️ local_game_registry（clamp 修复、refreshStaleEntries）→ 回归：时长精度 ±5s、睡眠唤醒、移动盘热插拔 |
| O8 | 启动链并行化/延后：MetadataFetcher、DiscoverMetadata 懒加载；截图恢复并行 | 冷启动再省 0.1~0.3s | 低 | 2~3 人时 | **P1** | B2 | ⚠️ main.dart 错误处理合并 → 回归：启动异常落日志 |
| O9 | `_loadLaunchModes` 结果缓存化 | 结构刷新少 N 次读盘 | 低 | 2 人时 | **P1** | B2 | ⚠️ library_page 同 O3 |
| O10 | 换官方 OpenList release exe | 产物 −85~105MB / 安装包 −30~45MB | 中 | 2~4 人时 + 测试 | **P1**（收益最大，需兼容性验证先行） | B2 | 无；⚠️ 需验证 P0-6 遗留的远程配置下发链路 |
| O11 | manifest.yaml → gz asset 后台加载 | 产物 −13MB（安装包 ≈0） | 低 | 2~3 人时 | **P2** | B3 | 无 |
| O12 | 志莽行书字体子集化 | 产物 −2.4~2.7MB | 低-中 | 1~2 人时 | **P2** | B3 | 无（big_picture 多处用该字体，需全量视觉走查）|
| O13 | 500ms 启动请求检查器自适应降频 | 空闲唤醒减半 | 低 | 1 人时 | **P2** | B3 | ⚠️ 涉及 M11 并发保护逻辑（main.dart `_isLaunching`）→ 回归：快捷方式秒启游戏 |

**P0 共 6 项**（O1~O6）：全部为高收益低风险，合计产物 −19~21MB、安装包 −8~12MB，且冷启动/内存体验立竿见影。
**批次建议**：B1（P0，随 2.0.1 补丁）→ B2（P1，2.1.0，O10 需先在测试机完成 OpenList data 兼容验证）→ B3（P2，随任意版本）。
**约束自查**：全部 13 项不升级依赖、不换栈、不触服务端；O1/O5/O11/O12 需在打包脚本层面确认"开箱即用"不受影响（均为随包内容替换，非按需下载——O10 换版后仍随包分发）。

---

# 第五部分　长效机制

## 1. 体积防劣化（CI 阈值检查，无代码，流程方案）

1. **产物清单基线**：每次 release 打包后生成 `build_manifest.json`（顶层条目 + 大小，PowerShell 单脚本即可），随发布归档。
2. **阈值规则**：CI（或本地打包脚本末尾）对比上一版 manifest：单条目增长 >10% 或 >2MB、总量增长 >5% → 打包失败并打印 Top5 增量条目。重点盯 `data/flutter_assets/`（manifest.yaml 意外变大、新 asset 混入）与 `runtime/`（openlist/magpie 被误替换为 full 版）。
3. **白名单豁免**：功能性新增（如新效果包）在 PR 描述中声明并更新基线，基线文件入库评审。
4. 打包脚本是单点（`ChronoTide_Setup.iss`），在 `[Files]` 处维护 runtime 排除清单，与 O1 的效果裁剪清单同一处维护，避免两处漂移。

## 2. 性能监控（轻量采集）

- **冷启动**：在启动链关键节点（现有 `debugPrint('[INIT] ...')` 处）打时间戳，release 下以低频采样写入应用日志（`DateTime.now().difference(startTime)`），定义指标 = `runApp` 时刻 − 进程启动时刻 + 首帧回调时刻；每次发布前后对比。改动量 ≈10 行。
- **帧耗时**：`SchedulerBinding.instance.addTimingsCallback` 采集最近 N 帧的 build+raster 耗时，P95 > 16ms 持续时记一条日志（仅记录，不弹 UI）；可定位 resize 卡顿（O3 验证用）。
- **内存水位**：定时（如每 60s，仅游戏会话期间）读取 Flutter 图片缓存 `currentSizeBytes` 与 `dart:developer` 的堆信息写日志，观察 R6 优化前后尖峰。
- 采集全部走现有日志轮转体系（`log_rotation_service.dart` 已有上限），不新增文件、不上报网络（契合本地工具定位）。

---

# 附：审计覆盖说明

- 静态分析覆盖：main.dart（全）、library_page.dart（关键段）、local_game_registry.dart（定时器/写盘段全读）、manifest_service.dart（全）、save_manifest.dart（结构）、magpie_service.dart（依赖段）、extract_manager/rar_lz4_unzip_service（工具依赖）、portable_image_cache_manager（全）、foreground_window_service、interrupt_cleanup、screenshot_carousel（全）、discover_page、game_detail_dialog、big_picture（抽样）、pubspec.yaml、ChronoTide_Setup.iss、assets 与 runtime 实测体积。
- game_detail_dialog.dart（4978 行）为抽样审计（定时器/动画/图片段），未逐行；其单文件体积本身是可维护性问题但非性能瓶颈，不在本报告范围。
