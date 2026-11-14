# DECISIONS — 架构决策记录（ADR）

> **记录「为什么这么设计」，而不只是「设计成什么样」。**
> 目的是防止 AI（或未来的你）在不知情的情况下推翻一个当初有意做出的决定。
>
> 格式：背景 → 决策 → 理由 → 影响。**只追加，不修改历史条目。**
> 若某条决策被推翻，新增一条注明「取代 ADR-00X」，不要删掉旧的。

---

## ADR-001 · 所有游戏启动入口收敛到 `GameLaunchService.executeLaunch`

- **日期**：2026-08-30
- **状态**：✅ 生效

**背景**
此前存在多条启动路径。`lib/widgets/game_detail_dialog.dart` 的 `_performLaunch` 实现了一条
绕过 `GameLaunchService` 的私有分支：显示假进度覆盖层 → 空转 1.2s → 直接调用
`MagpieService.startGameWithUpscaling`。该分支缺失时间戳更新与桌面快捷方式创建，
且 Magpie 链路内的 PowerShell 等待可能长时间挂起，导致覆盖层永久压窗、路由栈错乱、主窗口卡死。

**决策**
删除所有私有启动分支，四个入口（主页 / 库页双击 / BPM 详情页 / 详情窗口）统一调用
`GameLaunchService.executeLaunch`。超分/转区分支由 `game.json` 的
`upscaling_mode` / `locale_mode` 字段决定。

**理由**
1. 统一链路后自动获得旧分支缺失的时间戳更新与快捷方式创建；
2. 弹窗在启动前即关闭，避免任何挂起导致的压窗与卡死；
3. 单一入口让后续修复只需改一处。

**影响**
- 不再有启动提示窗口（产品行为变更，需确认可接受）
- 新增启动方式时必须走 `GameLaunchService`，**不得再开旁路**

---

## ADR-002 · 数据源顺序以 `kSourceOrder` 为唯一来源

- **日期**：2026-08-30
- **状态**：✅ 生效
- **位置**：`lib/services/metadata_fetcher.dart`

**背景**
弹窗中勾选数据源的顺序与实际抓取结果的顺序不一致，老用户已保存的顺序配置可能是乱序的。

**决策**
在 `metadata_fetcher.dart` 中定义 `kSourceOrder` 常量作为顺序的**唯一来源**，
并新增 `sortSourcesByDisplayOrder()`。`getAvailableSources()`、`_loadEnabledSources()`、
`setEnabledSources()` 三处统一按此顺序规范化。未登记的新源按枚举序追加到末尾（不会丢源）。

**理由**
单一数据源避免多处定义不一致；在 `_loadEnabledSources()` 里做规范化，
可以让老用户的历史乱序配置被自动纠正，无需写迁移代码。

**影响**
新增数据源时必须同步登记到 `kSourceOrder`，否则会被排到末尾。

---

## ADR-003 · 收藏夹置顶采用三级排序 + 写入时规整脏数据

- **日期**：2026-08-30
- **状态**：✅ 生效
- **位置**：`lib/services/collection_service.dart`

**背景**
预设收藏夹（准备入手 / 特别关注）依赖 `sortOrder` 取值来置顶，
但历史脏数据（普通收藏夹占用了 0/1、负数序号）会导致置顶失效、排序退化成 id 字典序。

**决策**
1. `GameCollection` 增加 `pinned` 字段（持久化），`isPreset` / `isPinnedTop` 为 getter；
2. 排序改为三级：`_groupRank`（预设 0 → 置顶 1 → 普通 2）→ `_presetRank` → `sortOrder` → `id`；
3. 新增 `_normalizePinnedOrder()`，在 `_save()` 内统一调用，任何写入路径都落盘规范顺序；
4. `create()` 的 `sortOrder` 由 `_collections.length` 改为 `_nextSortOrder()`（max+1），规避删除后撞号。

**理由**
**不依赖 sortOrder 的具体取值**来做置顶判断，是从根本上免疫脏数据；
而在写入时规整（`_save()` 内调用）比读取时规整更可靠——任何写入路径都会被覆盖到，
不会漏掉某条新增的写入分支。

**影响**
预设收藏夹不可取消置顶（`setPinned()` 会拒绝）。

---

## ADR-004 · 项目引入 Git 版本控制（此前完全没有）

- **日期**：2026-09-01
- **状态**：✅ 生效

**背景**
主项目 `D:\CTLIB` 此前**完全没有版本控制**。AI 改动无法 diff、无法回滚，
主人只能靠手工复制 `lib_backup_20260601`、`lib_backup_sidebar_*`、`lib_backup_theme_*`
三个目录来保命。这直接导致两个问题：
1. AI 越界改坏了无法低成本回退；
2. 无法回答「上次这行代码是谁、因为什么改的」，项目越开发越陌生。

**决策**
初始化 Git 仓库，并作为所有 AI 协作流程的**兜底机制**：
- 每个任务一个 commit，信息写清「为什么改」；
- 改完必须 `git status` + `git diff --stat` 自查是否越界；
- 回滚用 `git restore`，废弃手工复制备份目录的做法。

**理由**
版本控制是唯一能同时解决「可回滚」与「可追溯」的机制，且成本最低。

**影响**
- 三个 `lib_backup_*` 目录成为历史遗留，可考虑清理（删除前需确认无遗漏改动）
- 开源镜像 `chrono-tide-opensource/` 有自己的 Git，不嵌套进主仓

---

## ADR-005 · 主仓只跟踪源码与文档，排除 SDK / 第三方工具 / 构建产物

- **日期**：2026-09-01
- **状态**：✅ 生效
- **位置**：`.gitignore`

**背景**
项目根目录下混杂了大量非源码内容：Flutter SDK（3.1G）、安装包输出（4G）、
打包脚本（1.3G）、开源镜像仓库（553M）、他人项目参考（115M）、
Magpie / Sunshine / Locale.Emulator 等第三方工具、以及 `build/`（837M）。
若不排除，仓库会臃肿到无法正常使用。

**决策**
`.gitignore` 采用「只跟踪源码 + 文档 + 配置」策略，排除上述全部内容。
最终仓库规模：**1908 个文件 / 约 16 MB**。

**理由**
仓库的价值在于**可追溯的源码历史**，不在于是项目目录的完整镜像。
第三方工具与构建产物随时可重建，纳入只会拖慢 `git status` / `git diff` 的速度，
进而降低「每次改动都自查 diff」这一核心习惯的执行率。

**影响 / 注意**
- ⚠️ **`.gitignore` 不支持行尾注释**（`#` 只在行首才是注释）。
  2026-09-01 曾因此导致整批忽略规则静默失效，Flutter SDK 被误加入索引。
  新增规则时说明必须单独成行。
- ⚠️ **禁止运行 `git gc`**，在受限环境下曾损坏 `.git` 目录。

---

## ADR-006 · AI 协作采用「只读审计 → 变更计划 → 批准 → 执行」两段式流程

- **日期**：2026-09-01
- **状态**：✅ 生效
- **位置**：`AGENTS.md`

**背景**
历史痛点：AI 经常修改主人没有要求的部分、顺手重构、修一个问题引发多个无关 bug。

**决策**
强制两段式：阶段 A 只读审计并输出《变更计划》（含要改的文件+行号、影响面、风险、
验证方式、**明确不改的清单**），等待批准；阶段 B 严格按批准范围执行，
计划外如需改动必须停下报告。

**理由**
把「要不要改」和「怎么改」拆成两个决策点，让主人在成本最低的时刻（改代码之前）
就能拦住越界行为。这比事后 review diff 高效得多——后者往往要等 AI 改完 10 个文件才发现方向错了。

**影响**
单次交互会多一轮确认，但换来的是改动范围可控。纯新增文件且不触碰既有代码时可跳过批准。

---

## ADR-007 · 删除类操作以 `PathHelper.isInsideAppStorage` 为强制前置护栏

- **日期**：2026-09-12
- **状态**：✅ 生效（批 1 已落地三处；其余删除点待补齐）

**背景**
2026-09-12 的导入功能审查发现：三条导入链路（单文件 / 批量 / 智能）都把**用户自己的
游戏文件夹**写入 `game.directoryPath`（"本体目录"），而 `LocalGameRegistry.deleteGame`
对该路径裸执行 `Directory.delete(recursive: true)`（`lib/services/local_game_registry.dart:1220-1223`）；
`InterruptCleanup` 的退出清理同样会递归删除解压目标目录
（`lib/services/interrupt_cleanup.dart:278-326`，且"是否含游戏数据"只看顶层 4 种扩展名）。
两者都没有"这个目录是不是应用自己的"这一层校验。后果是用户勾选"同时删除本地文件"
或正常退出时，用户 300GB 级源目录可能被原地删除且不可恢复
（详见 `tickets/2026-09-12-import-source-file-loss.md`）。
仓库里其实早有 `PathHelper.isInsideAppStorage`（`lib/core/path_helper.dart:170`），
但此前只用于"临时封面"这类低危场景。

**决策**
1. 任何**删除 / 清理**（递归删除目录、删除文件）在落盘前必须先过
   `PathHelper.isInsideAppStorage`；应用自有目录之外**一律不自动删除**，
   改为跳过 + 记录 + 由 UI 如实告知用户手动处理。
2. 无法确认归属时方向永远是**保留**（宁可磁盘残留，不可误删）。
3. 新增删除入口必须同时补齐：归属护栏 + 审计日志（`data/cleanup_log.jsonl`）；
   触及用户可见路径的删除还必须在确认框明示真实路径。

**理由**
1. 数据丢失不可逆（应用尚无回收站机制），代价远高于残留垃圾；
2. `directoryPath` 语义天然指向"用户的目录"，任何以它为目标的删除都可能越界；
3. 统一走同一判定函数，避免各处重复实现导致规则漂移——本项目历史上曾有三套
   互不兼容的路径规范化实现并存。

**影响**
- `deleteGame` / `removeGameRecordOnly` / `InterruptCleanup` / `_cleanupOnFailure`
  / `GlobalInstallCenter` 孤儿压缩包清理等删除点需逐一补齐（批 1 已完成前三处，
  其余列入 IMP-06 / IMP-08 待排期）；
- 用户自定义安装位置的半成品残留，退出时不再自动清理（接受为安全代价）；
- 「按 `source` 分级的二次确认」与「删除进回收站」列为后续批次任务。

---

## ADR-008 · 文件系统时间戳不可作为"目录新旧"的判定依据

- **日期**：2026-09-12
- **状态**：✅ 生效

**背景**
修 `IMP-04`（单文件解压同名重复导入把元数据写到旧目录）时，为"解压器状态已被
reset"的兜底路径设计了"在 `Games/<名>` 与 `Games/<名>_1..99` 中取**修改时间最新**
的一个"。项目内的回归测试随即失败：三个相隔 40ms 创建的目录，前两个的
`stat().modified` 完全相同。用一次性探针脚本在 Windows 上实证（脚本不入库，
输出如下）：

```
A  modified=2026-09-12T19:43:09.000
B  modified=2026-09-12T19:43:09.000   ← 与 A 同秒，无法区分
C  modified=2026-09-12T19:43:10.000
```

即 **Windows 目录时间戳的有效精度只有 1 秒**（NTFS 还会延迟更新目录时间戳）。
"同秒内产生的多个副本"在导入场景是常态（一次导入会在毫秒级内创建目录），
因此 mtime 判据不仅无效，还可能把更旧的副本判成更新 —— 比"不判"更危险。

**决策**
1. 不得用 `FileStat.modified`（或 `changed`）来判定"哪个目录是本次新产生的"；
   目录级时间戳在 Windows 上不可作为判据。
2. 需要"本次产物"的确定性标识时，优先让**产生方回传路径**（如
   `ExtractManager.targetGameDir`），并在**回调发生的瞬间**捕获（状态可能随后被
   `reset()` 清空）。
3. 无法获得确定性标识时，**宁可不做（跳过并提示用户），也不要猜测**——
   写错目录会破坏已有游戏数据，而"少写一次元数据"只需用户重新导入一次。

**理由**
1. 猜测的失败方向是"覆盖用户/既有游戏的数据"，代价不可逆；
2. 秒级精度使"最新"在同秒副本间退化为"列表第一个"，等价于旧实现的老 bug；
3. 单测应当能复现该判据的失效（本项目的回归测试正是这样发现问题的）。

**影响**
- `join_controller.handleExtractSuccess` 改为"捕获值 → 回传值 → null"，取不到可信目录
  时提示用户去库页确认（`lib/pages/join/join_controller.dart`）；
- 后续凡涉及"识别新产生的文件/目录"，一律改用**显式登记**（如
  `extract_manager._taskOwnedTempArchives`）而非时间戳比较；
- `test/services/import_pipeline_fix_test.dart` 固定该行为（`resolveExtractionTargetDir`
  三个用例），防止回退。

---

## ADR-009 · 动态背景图（GIF）用零依赖原生 `Image` 播放，且「是否动图」用**派生值**判定

- **日期**：2026-09-17
- **状态**：✅ 生效

**背景**
主题背景图原本「允许上传 GIF」（`theme_storage.dart:372` 白名单里一直有 `gif`），
但全链路**没有任何一处知道它是动图**：模型无格式字段、渲染无动图分支、上传无分辨率/帧数校验。
即「用户能传、Flutter 会播，但系统对它一无所知」—— 于是模糊背景按帧重栅格化、
高分辨率 GIF 无上限、主题切换时新旧两个解码器同时活着，都会静默发生。

实现前做了 Phase 0 八项实测（`dev_probe/RESULTS.md`），其中三项**推翻了原方案的假设**：

| 实测 | 结论 | 后果 |
|------|------|------|
| `cacheWidth` / `ResizeImage` 对多帧图 | **不生效**（引擎 + 真机双重确认） | 无法靠降采样解码限制内存 → 分辨率门槛只能从 4096² 下调到 1920×1080；动图分支**不许传 `cacheWidth`** |
| `ImageCache` 对多帧图的计费 | **只算首帧**（500×500×20 帧仅计 1MB） | 缓存淘汰完全看不见动图的真实内存 → **必须主动 evict** |
| `precacheImage` 对动图 | **正常**（真机 27ms） | 原方案怀疑的存量 bug 不存在 → 该链路保持不动 |

**决策**
1. **播放走零依赖原生 `Image`**（`MultiFrameImageStreamCompleter` 驱动，按 GIF 自身帧延迟
   无限循环）。**不引入 `gif_view` 等第三方包**，`pubspec.yaml` 依赖零变更。
2. **「是否动图」用派生 getter `BackgroundImageConfig.isAnimated` 判定，不落盘**：
   不参与 `toJson` / `fromJson` / `==` / `hashCode`，`schemaVersion` 不动 → **零迁移**。
3. 动图的 provider **必须经 `AnimatedBackgroundImage.providerFor` 统一构造**，
   且**不得传 `cacheWidth`**（会把 provider 变成 `ResizeImage` 形态，使三个共用渲染点
   各起一个解码器 —— 同一张 GIF 被解码多份并各自播放）。
4. 门槛由**文件内容**裁决（`BackgroundMediaInspector`：魔数 + 尺寸 + GIF 块级扫帧），
   越限**拒绝**而不是静默降级：体积 ≤10MB、静态 ≤4096²、动图单帧 ≤1920×1080、帧数 ≤600。
5. 运行时降级规则：**R1 动图 + 模糊 → 静态首帧**（σ20 实测 raster p95 尖峰 = 基线 8.2 倍）；
   **R7 只在配置变更时延迟 evict**，**不在 `dispose` 里 evict**。

**理由**
1. **零依赖是硬约束**：动图是这个应用上的一条支线功能，为它引入一个第三方播放器
   （且其 file 构造在 Windows 桌面端未经证实）不划算；原生路径的播放能力经 Phase 0 实测足够。
2. **派生而非落盘**：扩展名可作身份判据的**前提**是落盘前做了「魔数 == 扩展名」交叉校验
   ——这个前提由决策 4 保证。用派生值换掉了整个 schema 迁移。
3. **门槛拒绝 > 静默降级**：用户选了一张 8K 的 GIF，静默帮他降级会让他以为功能坏了；
   精确到维度的拒绝（体积/分辨率/帧数/伪装扩展名）才能指导他换一张。
4. **主动 evict 是实测逼出来的**：ImageCache 看不见动图内存，不主动释放就是内存单调上涨。

**影响**
- **零 schema 变更、零数据迁移**：存量 `.gif` 背景升级后**自动按动图播放**（无需用户操作）；
- 🔴 **已知且不可绕过的代价**：原生 `Image` 没有暂停 / seek / 只播一次 / 限帧的公开 API。
  性能只能靠「上传门槛 + 运行时降级」兜底，**不能靠播放时调速**。若将来要求这些能力，
  必须改选型（届时新增 ADR 取代本条），不要试图在原生化路径上打补丁；
- 白名单新增 `webp` / `bmp` 会**连带放开 `.cttheme` 主题包导入**
  （`ct_theme_package.dart:177` 复用 `ThemeStorage.validateImageExtension`，已与用户确认接受）。
  该通道只做扩展名 + 解压后大小校验，**不做魔数校验**，伪造扩展名的背景由渲染层
  `errorBuilder` 兜底为空白；
- 新增文件 `lib/theme/background_media.dart`（校验层）与 `lib/theme/animated_background_image.dart`
  （唯一渲染出口）；改动落在 🔴 稳定区 `lib/theme/**`（已获用户批准）；
- 后续维护**不得回退**：① 动图分支加回 `cacheWidth`；② 把 `isAnimated` 改成序列化字段；
  ③ 在 `dispose` 里 evict；④ 绕过 `providerFor` 自行拼装 provider。


## ADR-010 · 「减少动效」做成 `lib/services` 下的全局偏好，且作用范围**仅限动态背景图**

- **日期**：2026-09-17
- **状态**：✅ 生效

**背景**
ADR-009 选定的零依赖原生 `Image` 播放路径**没有任何限帧 / 暂停 / 只播一次的公开 API**
（`MultiFrameImageStreamCompleter` 按 GIF 自身帧延迟无限循环）。这是选型的固有上限，
方案 §L4 因此安排了两条运行时限流手段：R3（运行时掉帧自动降级）与 R4（用户手动「减少动效」）。

本决策只针对 **R4**（用户 2026-09-17 拍板「做 R4」）。**R3 确认不做**：
`SchedulerBinding.addTimingsCallback` 给出的是**整帧 build + raster 耗时**，无法归因到
背景图本身，而库页滚动与批量导入（本项目最重的两个场景）本来就常态超 16ms ——
按该口径判定会**误判并把背景永久降级**。要做就得换口径（只测图像流自身帧间隔），
那已经不是方案里那条 R3 了。

**决策**
1. 「减少动效」实现为 **`lib/services/motion_preference.dart` 的 `ChangeNotifier` 单例**，
   pref key `reduce_motion_background`，**默认 `false`**（存量用户零行为变化）。
2. **作用范围锁定「仅 GIF 动态背景图」**：开启后动图降级为静态首帧，
   **不包含**界面过渡动效（`AnimatedSwitcher` 交叉淡入淡出等）。UI 文案必须与该范围一致。
3. 持久化**不进 `lib/theme` 的 schema**（不碰 `BackgroundImageConfig` 的
   `toJson/fromJson/==/hashCode/schemaVersion`）→ 仍是零迁移。
4. 消费方式：`BackgroundImageResolver` **订阅该单例**（`initState` 订阅 / `dispose` 退订），
   其三个调用点（`custom_title_bar` / `big_picture_shell` / `editor_preview_builder`）**一行不改**。
5. 偏好**必须在 `main.dart` 首帧前 `load()`**，不能靠 resolver 懒加载。

**理由**
1. **偏好放 `lib/services/`**：本项目偏好类单例一律住这里（`install_path_preference.dart`、
   `nsfw_settings.dart`），且它是「设备能力 / 使用习惯」维度的开关，不属于主题数据。
   代价是新增一条 `lib/theme → lib/services` 的 import 边 —— 代码库本就有反方向的
   `services/quick_window_service.dart:9 → theme/app_theme_manager.dart`，并非单向架构。
2. **不做进 schema**：写进 `BackgroundImageConfig` 就要动 schema、存量主题需迁移，
   而 ADR-009 的全部价值就建立在「零迁移」上。
3. **订阅而非参数注入**：改成给 `BackgroundImageResolver` 加参数，就要在三个调用点各包一层
   `ListenableBuilder`，改动面扩大 3 倍而收益为零（三个调用点都想要同一份全局策略）。
4. **首帧前加载**：动态背景在首帧就渲染，若此时偏好还没读出，开启该开关的用户会先看到
   GIF 播几帧再静止 —— 可见闪现，正是这个开关要消除的东西。

**影响**
- 新增文件 `lib/services/motion_preference.dart`（非稳定区）+ `test/services/motion_preference_test.dart`；
  修改 🔴 稳定区 `lib/theme/background_image_resolver.dart`（+17 行）与 `lib/main.dart`（+2 行，已获用户批准）；
- 降级时旧的多帧 completer 会因失去监听**自行停表**（`flutter/.../image_stream.dart:1118-1122`），
  紧接着的 `evict` 只是把常驻解码内存一并清掉（Phase 0 实测 ImageCache 只按首帧计费）；
- ⚠️ **渲染侧接线无法自动化验证**：需要 `ThemeStorage` 落盘 + `ImageProvider` 真实解码，
  flutter_tester 假 async 驱动不了（Phase 0 RESULTS §7）。验收依赖真机走查清单第 ⑦ 项；
- 后续维护**不得回退**：① 把「减少动效」扩义为「关闭全部界面动效」而不改文案与测试范围；
  ② 把它写进 `BackgroundImageConfig` 落盘；③ 去掉 `main.dart` 的首帧前 `load()`；
  ④ 在三个渲染调用点各存一份开关副本（会与全局偏好状态不一致）。


---

## ADR-011 · 游戏身份用稳定主键 `game_id`（UUID v4），一经生成禁止改写

- **日期**：2026-09-19
- **状态**：✅ 生效

**背景**
`docs/DEV/tickets/2026-09-17-game-data-schema-audit.md` P0-1 指出：同一个游戏在系统里有
**4 套身份键** —— 内存 `_games` 用目录名、全局手动序与收藏夹 `game_order` 用
`directoryPath`、启动配置用**标题**、排重用 `title + path + sourceId`。
更糟的是清洗规则还分叉：`GameConfigManager._sanitizeGameId` 会把空白替换成 `_`，
而注册表的三处正则保留空白 —— 同一个游戏能算出两个 key，出现重复卡片、时长重复计入。

**决策**
1. `game.json` 增加 `game_id`（UUID v4），在 `writeGameDir` 首次入库时生成。
2. **一经生成终身不变**：`game_id` 刻意**不在** `_overwritableFields` 内，
   且 `updateGameJson` / `updateGameJsonAtomic` 内有 `_guardGameIdUpdates` 护栏，
   拒绝把它改成不同值或空值。
3. 标题 → 目录名的清洗规则收敛到 `lib/utils/game_key.dart` 的
   `GameKey.dirNameFromTitle`，全项目禁止再自写正则；UUID 生成也统一到
   `GameKey.generateId`。
4. 老数据由 schema 迁移链（ADR-012）补发。

**理由**
1. **目录名/`directoryPath`/标题都不够格做身份**：目录名会随标题改动而重命名；
   `directoryPath` 会随用户搬移游戏而变；标题本来就允许改。
   只有"入库时随机生成、写进文件、永不改写"的 id 才满足"终身不变"。
2. **护栏放在 API 而不是调用点**：与 `title_locked` 同一思路 ——
   让错误的主键改写**在构造上不可能发生**，而不是靠每个调用点自觉。
3. **不迁移 `_games` 的 key**：评估后认为不值得。目录名在 `Games/` 下是稳定的
   物理身份，`game_id` 已足以承担"跨重命名/迁移不变"的职责；改造 3415 行文件里的
   全部读写点，收益与风险不成比例。

**影响**
- 新增文件 `lib/utils/game_key.dart`；`game_data_format.dart` 与
  `local_game_registry.dart` 各自新增字段 / 索引 / 护栏；
- 注册表新增三张派生索引 `_byIdIndex` / `_byTitleIndex` / `_byDirPathNormIndex`
  与 `getGameById` / `getGameByDirectoryPath`（同时解决 P1-1 的 O(n²) 查询）；
- 后续做 index 数据库（P3-1）时，`game_id` 就是天然的索引主键；
- 维护**不得回退**：① 把 `game_id` 加进 `_overwritableFields`；
  ② 去掉 `_guardGameIdUpdates`；③ 让某处直接赋值 `game.gameId` 而绕过检查。


---

## ADR-012 · `game.json` 的 schema 演进走「版本链 + 读时迁移 + 一次写回」

- **日期**：2026-09-19
- **状态**：✅ 生效

**背景**
`game_data_format.dart` 的 `currentVersion` 从项目建立起**一直是 1**，
而 `sessions` / `daily_play_log` / `title_locked` / `collection_ids` /
`metadata_source*` 都是后期追加的字段 —— schema 一直在演进，版本号却停摆。
后果：任何"老文件缺新字段"的情况都只能靠读取代码的 `?? 默认值` 兜着，
没人知道某份 `game.json` 到底是哪个年代的产物，也没有地方挂"升级时要做什么"。

**决策**
1. `_migrations: Map<int, Map<String,dynamic> Function(Map)>` 版本链，
   key = 磁盘上的版本号，value = 升到 key+1 的**纯变换**（不落盘、不抛异常）。
2. `migrateGameJsonMap` 从旧版本逐级应用直到 `currentVersion`，
   返回 `(json, changed)`；`changed` 是"是否与磁盘不一致"的判据。
3. 迁移发生在 **`readGameJson`**：升级后若 `changed` 为真，用 `_atomicWriteFile`
   **就地写回**。写回必须绕开写队列 —— 此时已持有该目录的队列锁，
   再调 `updateGameJson` 会等待自己（死锁）。
4. 无论版本号如何，都会自愈缺失的 `game_id`。
5. 🔴 纪律：字段新增 / 改名 / 语义变更时，必须同时
   ① 追加一条迁移 ② 提升 `currentVersion` ③ 补一条回归测试。

**理由**
1. **版本号必须有承载点**：否则"schema 演进"这件事在代码里是不可见的，
   新人（或 AI）看到 `format_version: 1` 会以为数据格式从未变过。
2. **读时迁移而不是启动时全量迁移**：启动时全量扫 2000 个目录会把首屏拖慢；
   读时迁移是"用到才升"，且天然覆盖"手动拷进来的老目录"（它可能任何一次
   启动扫描都没赶上）。
3. **一次写回**：读路径不做重复 IO —— 写回后版本号即为当前值，不再触发；
   漏掉写回则每次读取都会重新补发 `game_id`（id 每次都变，等于没有主键）。
4. **纯变换、不落盘**：让迁移函数可单测（给定输入 map → 断言输出 map），
   不必构造文件系统。

**影响**
- `currentVersion` 1 → 3（v1→v2 补发 `game_id`；v2→v3 收敛标题槽位，见 ADR-013 相关）；
- ⚠️ **老库首次升级有一次写放大**：每个老 `game.json` 被重写一次。
  这是**一次性**成本，且 `scan()` 逐条 `await`，UI 不会卡死；
- `GameJsonMigrationResult` 是新增的公开类型；
- 维护**不得回退**：① 把 `format_version` 写死成常量；② 在迁移函数里做 IO；
  ③ 用 `updateGameJson` 做迁移写回（会死锁）。


---

## ADR-013 · 启动 exe 路径以 `game.json.launch_path` 为唯一事实源

- **日期**：2026-09-19
- **状态**：✅ 生效

**背景**
启动 exe 路径曾同时存在三处：
A `game.json.launch_path`（权威本体）/
B `data/game_configs/game_<标题>_config.json`（代码注释自称"主存储"）/
C prefs `default_exe_<标题>`。
`persistUserChoice` 一次写三处，而读取侧**三个入口的优先级各不相同**
（`GameLaunchService` 是 B→A，库页启动管理弹窗是 B→C，BPM 走前者）。
后果：「改了启动程序却不生效」；改标题后 B/C 变成孤儿文件，越积越多，
只能靠 `game_detail_dialog.dart` 里一段"改名时顺手迁移配置"的补丁救场。

**决策**
1. `game.json.launch_path` 是**唯一事实源**，语义为"相对 `directory_path` 的相对路径"
   （绝对路径仅作兼容读取）。
2. B / C 降级为**只读兼容**：`GameLaunchService.resolveUserChoice` 统一按
   **A → B → C** 解析，命中 B/C 时把值搬进 A 并**删除**旧存储。
3. **删除**"配置跟着标题搬家"的补丁 —— `launch_path` 相对 `directory_path`，
   改标题本就不影响它；这个补丁的存在本身就是"身份键选错"的症状。
4. 所有需要"该用哪个 exe 启动"的地方都必须走 `resolveUserChoice`，
   不允许各自拼读取顺序。

**理由**
1. **同一事实三处存储 + 三套优先级 = 必然分叉**。只要还留着任何一个写入方，
   就迟早会出现"两个入口读到不同 exe"。
2. **迁移后删掉旧存储，而不是留作兜底**：留着的话，一旦用户在启动管理里清空
   `launch_path`（"我要重选"），遗留值会把过期的 exe 悄悄复活 —— 表现为"清不掉"。
   宁可删掉，让"没有启动程序"是个明确状态。
3. **不去给 B 的文件名换 `game_id`**：既然 B 本身正在被淘汰，
   再给它做一轮键迁移是纯浪费（搬一个即将拆掉的仓库）。

**影响**
- `game_launch_service.dart` 的 `resolveUserChoice` / `persistUserChoice` 重写，
  新增 `_adoptLegacyPath` / `_removeLegacyStores`；
- `library_page.dart:2271`、`game_detail_dialog.dart`（改名块 + `_resyncLauncherConfig`）、
  `local_game_registry.dart`（`finalizeGameMove` ②）全部改为只读写 A；
- `GameConfigManager` 整体进入"历史存储、只读兼容期"，`saveLaunchPath` /
  `saveConfig` 已无生产调用方；下一个大版本可整类删除；
- 维护**不得回退**：① 恢复向 B/C 写入；② 在某个入口自建一套读取顺序；
  ③ 迁移时保留旧存储作为兜底。

---

## ADR-014 · 「首次启动自动生成桌面快捷方式」由每游戏字段改为全局偏好，且默认关闭

- **日期**：2026-09-27
- **状态**：✅ 生效

**背景**
该能力原实现是「两处入口 + 一份每游戏状态」：状态存在**每个游戏**的
`game.json.auto_create_shortcut`（默认 `true`）；UI 入口有两处 ——
库页右键「启动管理」弹窗的「首次启动自动生成」开关，以及
「选择启动程序」弹窗的「生成桌面快捷方式」勾选框。后者通过
`userShortcutChoice` 参数透传给 `GameLaunchService`，历史上出过
"弹窗取消勾选仍被强制创建"的 Bug，为此在 `_maybeCreateDesktopShortcut`
里又加了一层"用户选择优先于 game.json"的覆盖逻辑。

用户 2026-09-27 拍板三件事：① 默认改为**关闭**；② 开关入口迁到设置窗口；
③「选择启动程序」弹窗里的同功能勾选框一并移除。

**决策**
1. 新增全局偏好 `AutoShortcutPreference`
   （`lib/services/auto_shortcut_preference.dart`，prefs key
   `auto_create_shortcut_first_launch`，**默认 `false`**），与
   `MotionPreference` / `BpmOpVideoPreference` 同构；首帧前在
   `main.dart` 与 `MotionPreference.load()` 同层 `load()`。
2. 决策依据从「每游戏」改为「全局唯一」：
   `_maybeCreateDesktopShortcut` 只读 `AutoShortcutPreference.instance.enabled`。
3. **移除**启动管理弹窗的每游戏开关，以及「选择启动程序」弹窗的
   「生成桌面快捷方式」勾选框（含整条 `userShortcutChoice` 参数链）。
4. `game.json.auto_create_shortcut` 字段**保留但不再读取**（不删数据、不做迁移）。

**理由**
1. **"是否在桌面留图标"是设备/使用习惯维度的开关**，与 `MotionPreference`
   （ADR-010）同类，不属于单个游戏的数据，因此适合做全局偏好而不是游戏字段。
2. **保留每游戏覆盖 = 保留旧 Bug 的土壤**：两处入口 + 一层覆盖逻辑正是
   "用户改了不生效"的来源。语义越简单越不会分叉。
3. **不删字段**：`game.json` 属用户数据，删字段要动 schema 并走版本链迁移
   （ADR-012），收益只是一个死字段，不值当。

**影响**
- 新增 `lib/services/auto_shortcut_preference.dart`；
- `lib/main.dart` 首帧前 `load()`；`lib/widgets/settings_modal.dart`
  「游戏与启动 → 系统」分组新增开关卡片（与「开机自启动」同款）；
- 删除：`launch_manager_dialog` 的开关 UI 与写入、
  `exe_selector_dialog` 的勾选框及 `gameTitle` / `metaDataDir` /
  `initialGenerateShortcut` / `onGenerateShortcutChanged` 参数、
  `library_page` 的 `_readAutoCreateShortcutSync` 与透传、
  `game_launch_service` 的 `userShortcutChoice` 参数链；
- **既有行为变更**：此前依赖默认开启的用户，升级后首次启动不再自动生成
  桌面快捷方式（即本次需求本身）；
- 维护**不得回退**：① 在任一弹窗里再开一处快捷方式开关；
  ② 重新把 `game.json.auto_create_shortcut` 当作决策依据。

---

## ADR-015 · BPM 背景新增「每游戏自定义背景图 + OP 视频」，视频选 `video_player_win`（仅 Windows / 零 GPL）

- **日期**：2026-09-27
- **状态**：✅ 生效（代码已完成；`flutter build windows` 与真机走查待补）

**背景**
用户要复刻 Playnite 的 Galgame 主题（ubiquity）观感：BPM 主页除封面背景外，还要支持
①用户自行上传图片作为该游戏的背景展示图；②上传 OP 视频（mp4），选中停留 3 秒后
封面淡出、视频在 UI 背后播放，播完淡出恢复原背景。

项目此前**零视频依赖**（全库 grep `video_player|media_kit|fvp|dart_vlc` 零命中）。
既有的「动态背景」只有 ADR-009 的 GIF 路径，而那条路径**没有暂停 / seek /
只播一次**的公开 API（ADR-009 影响段已明确记载），无法支撑「完整播放一次后恢复」。

**决策**
1. **视频后端选 `video_player_win`**（配官方 `video_player` 作 app-facing API）：
   基于 Windows 自带 Media Foundation，**只增加约 130KB** dll，
   **BSD-3 许可、零 GPL/LGPL**，MP4/H.264/AAC 原生支持。
   **不选 `media_kit`**（捆绑 libmpv，安装包 +约 40MB，与项目体积克制冲突）；
   **不选 `fvp`**（+约 10MB 且生态小众）。
2. **仅 Windows、仅 BPM 大屏**：自定义背景图与 OP 视频只服务大屏模式，桌面链路零改动。
3. **数据字段走 `updateGameJson` merge，不升 schema**：新增 `bpm_custom_backdrop` /
   `bpm_op_video` 两个**相对 `metaDataDir`** 的路径字段，与既有 `bpm_backdrop_x/y/zoom` 同构。
   **依据**：`GameJsonData.toJson()` 全库**无生产调用方**（`fromJson` 唯一调用方在读路径），
   即当前不存在「全量序列化写回 game.json」的路径，未建模字段不会被静默写没；
   而 `_mergePreservedFields` 天然保留不在 `_overwritableFields` 内的字段。
   → **零迁移、零写放大**。
4. **新增播放态遮罩令牌**：视频播放时改用 `backdropScrimVPlaying` /
   `backdropScrimHPlaying`（比静态态更轻，深色底段 `0xA6`→`0x5A`、浅色 `0x6B`→`0x3D`），
   否则既有遮罩会把视频压暗到 65%，与用户「视频尽可能清晰」的硬要求直接冲突。
5. **音频默认静音、重播默认每次选中都播**，两者做成全局偏好
   （`BpmOpVideoPreference`，与 `MotionPreference` 同构），开关入口放**桌面设置页**
   新增的「大屏模式」栏（不占 BPM 顶部栏）。

**理由**
1. **体积与许可优先于格式通用性**：OP 视频绝大多数是 MP4/H.264，MF 原生覆盖；
   为极少数冷门编码付出 40MB 安装包不划算。项目此前已有明确的许可红线意识
   （手柄适配曾因 GPLv3 排除 QKeyMapper 的方案）。
2. **不与 ADR-009 抢路径**：GIF 动图属于「主题背景图」（可上传到主题），
   而 OP 视频是**每游戏**的媒体资产 —— 生命周期、粒度、播放语义都不同，
   强行复用会让"短视频"需求污染主题系统。
3. **零迁移是本功能的价值支点**：一次 schema 升级会让全库 `game.json` 各重写一遍
   （ADR-012 已记载该代价），这里没有必要付。

**影响**
- 新增 `lib/big_picture/services/bpm_backdrop_media.dart`（字段 + 门槛常量）、
  `bpm_backdrop_media_controller.dart`（状态机 + 世代号防竞态）、
  `lib/big_picture/widgets/bpm_op_video_layer.dart`、`lib/services/bpm_op_video_preference.dart`；
  修改 `lib/big_picture/big_picture_shell.dart`（backdrop 拆层 + 视频层 + 5 处接线）、
  `bpm_theme_controller.dart`（+2 令牌 × 深浅）、`big_picture_theme.dart`、
  `bpm_game_detail_panel.dart`、`bpm_game_edit_dialog.dart`、`settings_tab.dart`、
  `settings_modal.dart`、**🔴 稳定区 `lib/main.dart`**
  （`WindowsVideoPlayer.registerWith()` + 偏好首帧前 `load()`，已获用户批准）、
  `pubspec.yaml`（+`video_player` + `video_player_win`，已获批准）；
- **构建前提**：`video_player_win` 的 CMake 需要 `ProgramFiles(x86)` 环境变量，
  并会联网下载 nuget.exe + `Microsoft.Windows.ImplementationLibrary`（含 SHA256 校验）；
  且 Flutter 构建本身需要**符号链接特权**（Windows 开发者模式或管理员权限）；
- 后续维护**不得回退**：① 把这两个字段加入 `_overwritableFields`；
  ② 视频层改回 `contain`（会留黑边）；③ 去掉世代号竞态防护；
  ④ 播放态仍用静态遮罩令牌；⑤ 引入 `GameJsonData` 全量写回却不同步补这两个字段。

---

## ADR-016 · 静默自启（`--silent`）由**原生 runner** 决定是否显示窗口，不在 Dart 侧补救

**背景**：开机自启时窗口会在桌面闪出，鼠标点击后才退回托盘。Dart 侧静默分支
（`lib/main.dart:493-507`）在 `runApp()` 之前就已 `hide()`，但原生 runner 的模板遗留
`SetNextFrameCallback([&]{ this->Show(); })`（`windows/runner/flutter_window.cpp:30-32`）
在首帧又把窗口显示出来。

**决策**：把「是否显示窗口」的最终决定权放在**原生侧** —— `OnCreate()` 解析启动参数，
命中 `--silent` / `-s` 时首帧回调不调用 `Show()`。

**理由**：
1. Dart 的 `hide()` 必然早于首帧、也就早于 `Show()`，**时序上抢不过**；
2. Dart 收不到 `show` / `hide` 事件（window_manager 的 funcMap 里没有 `kWindowEventShow`），
   无法对「窗口被显示」做出反应；
3. 首帧后再 `hide()` 只能把「停留到点击」缩短为「闪一帧」，**不能保证零闪现**
   （平台线程 `ShowWindow` 与 UI 线程 hide 存在竞争）。

**约束**：启动参数解析在 Dart（`_parseSilentArg`）与原生各一份，**必须同步维护**
（两处代码已互相注释指路）。
**另注**：`windows/CMakeLists.txt:42` 的 `/WX` 使「无 BOM 文件 + 中文注释」直接编译失败
（C4819 → C2220）；`windows/runner/*.cpp` 新增中文注释前必须确认文件带 UTF-8 BOM。

**影响**：`windows/runner/flutter_window.cpp`（+23/−2，含补 BOM）；零 Dart 改动。
无参数启动 / `--launch-game` 路径不变；`onWindowFocus` 焦点窃取守卫保留不动。
详见 `docs/DEV/features/autostart_silent_startup.md`。

---

## ADR-017 · 游戏标题图只做「全自动双源抓取」，不引入手动入口 / 内置 Key / 服务端代查

**背景**：BPM 与桌面主页的大标题原本只有加粗文字（`heroTitleSize` + 得意黑）。
用户在 Playnite 全屏主题截图里看到厂商绘制的艺术字标题（透明 PNG clear logo），
提出我们能否做到。核查确认 Playnite 用的是游戏对象上独立的 `Logo` 字段，
**不是**把文字渲染得更大 —— 所以补的是"标题图资产"这条新维度。

围绕"资产从哪来"讨论了四条路，最终只采纳第一条：

1. Steam CDN `logo.png`（经 NextMoe 的 steam 锚点定位）+ SteamGridDB 补缺（**采纳**）；
2. 从用户封面图自动识别并抠出标题（**否决**）；
3. 客户端内置一个共用 Key（**否决**）；
4. Key 只放 PB 服务端代查（**否决**）。

**决策**：

- 抓取**全自动、懒触发**（切到某游戏且它没有标题图时才抓），无任何手动入口；
- 主源零密钥：`NextMoe → refs/sources 的 steam:<appid> → CDN logo.png`
  （遍历全部候选 appid，实测 70% 覆盖）；
- 次源 SteamGridDB：**Key 纯可选、由用户自填、只存本机**
  （`SharedPreferences['sgdb_api_key']`），未填时该级静默跳过；
- 两级都拿不到 → 回退文字大标题，与改造前渲染零差异。

**理由**：

1. 抠封面图标题是**物理不可逆**（标题压在角色身上，被遮像素已不存在）、
   定位不可靠（6 张里 1 张直接命中角色脸）、且**语义错位**
   （封面印的是日文标题 + CERO 分级标，不是要显示的英文 logo）；
2. 内置 Key 必然泄露 —— 本项目有已推送 GitHub 的开源镜像 `chrono-tide-opensource/`，
   含完整 `lib/`；且全体共用同一限流额度，被封后用户无自有 Key 可换；
3. 服务端代查的技术前提**从未验证**：PB 现有 8 个 hook 零外部 URL、零 `$http.send`，
   京东云能否连 `steamgriddb.com` 未知；为验一个装饰性增强而改线上不值；
4. 手动入口与"用户零操作"的产品取向冲突，且会引入"改了标题但 logo 不跟着变"的错位。

**约束**：

- 🔴 Steam CDN / SGDB 资产**只可客户端本地缓存自用**，禁止镜像到 PB 分发；
- `logo_file` / `logo_origin` **不进 `_overwritableFields`**，否则重复入库会清掉已有的图；
- 固定文件名必须是 `title_logo.png`（`logo.png` 会撞上 galgame 本体自带资源）；
- `normalizeLogoPng` 的两道闸（宽扁比例、非全幅不透明）是自动链路唯一的质量保证，
  **不可为了"提高命中率"放宽**。

**影响**：新增 `lib/services/game_title_logo_service.dart`、`lib/widgets/game_title_logo.dart`、
`lib/widgets/settings/title_logo_settings_card.dart`；修改 `game_data_format.dart`、
`local_game_registry.dart`、`home_page.dart`、`big_picture_home.dart`、`settings_modal.dart`。
`game.json` 纯新增可空字段，**不升 `format_version`**（ADR-012 显式例外）。
详见 `docs/DEV/features/game_title_logo.md`。

---

## ADR-018 · BPM 背景 OP 视频「自动抓取」默认关闭，且只做客户端本地缓存

**背景**：用户看到 Playnite 大屏主题能自动给游戏配 OP 动画当背景板，问我们能否实现。
核查确认 Playnite 靠社区扩展 **Extra Metadata Loader**（Steam trailer + YouTube/yt-dlp），
不是核心功能、也不是静默全自动。我们的播放链路（ADR-015）已有，缺的只是素材来源。

实测结论（20 个 galgame 抽样，详见 `features/bpm_op_video_autofetch_research.md`）：

| 维度 | 实测 |
|---|---|
| 真 OP 覆盖率 | **9/20（45%）**（其余只有 PV 或 Steam 上根本没有条目） |
| 单条体积 | 720p 97–148 秒 ≈ **30–45MB**（1080p 约 107MB，否决） |
| 格式 | 只有 HLS/fMP4，**没有 mp4 直链**；init + 分片顺序拼接即合法 MP4，**不需要 ffmpeg** |
| 播放 | MF 不支持 HLS ⇒ 必须下载拼接；但 Win8+ 原生支持 `moof` 分片 ⇒ 拼完能直接播 |

**决策**：

1. **做**，但**默认关闭**（设置页「大屏模式 → 背景 OP 视频 → 自动抓取」）；
2. 只从 **Steam 商店 API** 抓（`appdetails?filters=movies` → 只认 OP/OPENING 条目）；
3. 懒触发：只抓用户在大屏模式里**实际选中过**的游戏，不做全库预抓；
4. 抓到的视频**不抢用户已选的视频**（`addVideos(autoSelect: false)` =
   「只在当前没有选中视频时才接管」）；
5. 🔴 产物**只在客户端本地缓存自用**，禁止上传 / 镜像到 PB 或任何服务器。

**理由**：

1. 覆盖率不足一半、单条 30–45MB、且属于「替用户下载完整 OP 动画」——
   需要用户知情，不能默认替他决定；默认关 = 用户主动打开才发生流量与磁盘占用；
2. 背景板看不出 1080p 与 720p 的差别，体积却翻倍，**只做 720p**；
3. 完整 OP 动画的版权敏感性**显著高于**标题图（ADR-017），
   本地缓存自用与服务器分发是两条完全不同的线，后者一步都不能迈；
4. 「宁可没有也不贴错」在视频上同样成立：名称闸硬排除 PV/预告片 ——
   把一段宣传片当 OP 播，比没有视频更难看。

**约束**：

- 引擎必须是**纯 Dart**（`game_op_video_core.dart`，零 Flutter 依赖），
  否则本机 231 故障 + flutter_tester 的异步 IO 挂起会让它**完全无法验证**；
- 负缓存 TTL 必须按状态区分：网络类失败 1 天，素材不存在 30 天；
- 必须带网络熔断（连续 2 次不可达即本次启动停止），否则商店被墙时每换一个游戏
  白等 12 秒连接超时；
- 文件名固定前缀 `op_video_`（幂等判据 + 清理时只删自己抓的，绝不碰用户手放的视频）；
- 抓取与清理都必须走 `BpmBackdropMedia` 的公开 API，不得直接改 `game.json`。

**影响**：新增 `lib/services/game_op_video_core.dart`、`lib/services/game_op_video_service.dart`、
`lib/widgets/settings/op_video_autofetch_card.dart`；修改 `bpm_op_video_preference.dart`（新增
`autoFetchEnabled`，默认 `false`）、`bpm_backdrop_media.dart`（`addVideos` 新增 `autoSelect`）、
`game_title_logo_service.dart`（暴露 `resolveSteamAppIds`）、`big_picture_shell.dart`、
`settings_modal.dart`。`game.json` 无新增字段（视频走既有的 `bpm_backdrop_videos` 池），
**不升 `format_version`**。详见 `docs/DEV/features/bpm_op_video_autofetch.md`。

**2026-10-17 修订（同日）**：素材范围从「只收 OP」放开为 **OP > ED > PV > 其它相关条目
分级取最靠前的一条**。用户原话：*"PV 其实也可以算的……只要是有相关游戏内容的视频，
我们都是可以作为这个背景使用。没有 OP 就用 PV。"* 实现：`OpVideoCore.classify()` +
`pickMovie()`（原 `pickOpening` 硬排除逻辑废弃），状态 `noOpening` 更名
`noUsableMovie`（语义收窄为「条目都在但全无 HLS 源」）。决策第 4 条
「宁可没有也不贴错」的适用面随之收窄：贴错只剩 appid 锚错作品一种可能，
由锚点纪律兜住；厂商挂在本作商店页上的 PV 属于「有相关游戏内容的视频」，
不再视为错误素材。其余条款（默认关闭 / 只抓一条 / 本地缓存 / 熔断 / 负缓存分档）不变。

**2026-10-17 修订 2（同日，用户实测反馈）**：交互从「静默后台抓」改为
**「探测 → 弹窗确认 → 拉取」**。用户实测后反馈：*"我明明开了自动抓取，但是没有任何
的反应……如果识别到了该游戏有视频素材，就弹一个窗口提示该游戏可以抓取的视频数，
让用户选择是否拉取；没抓到素材就什么都不用干，也不需要提示。"* 实现：引擎拆出
`probe()`（只查列表不下载）与 `downloadMovie()`（下载单条）；服务层探到候选后经
`onCandidates` 回调交 shell 弹 `BpmOpVideoAskDialog`；用户确认才下载。拒绝记
`userDeclined` 负缓存 **7 天**（比素材类短，留反悔窗口）；同一游戏本会话只弹一次；
无候选 / 网络失败**保持静默**（用户明确要求）。其余条款不变。
## ADR-019 · 启动兼容性走 HKCU 兼容性层 + 提权收敛到唯一执行器

- **日期**：2026-10-24
- **状态**：✅ 生效

**背景**
用户要求：① 自动给游戏 exe 配好 Windows 兼容性属性（Win8 兼容 / 禁用全屏优化 /
替代高 DPI 缩放），除「以管理员身份运行」外全静默；② 超分与转区**功能本身**以管理员
权限运行；③ 统一梳理启动流程。

核查发现启动链路已经裂成四份（普通 / 超分 / 转区 / 托盘），每份各写一套
`Process.start` + `cmd /c start` 兜底，对提权与 UNC 工作目录的处理互不相同。
并且 `magpie_service._setDpiCompatibility` 已经在用 PowerShell 写同一个注册表值
——若再加一个写方，两套写方必然互相覆盖，用户会看到属性页勾选状态「自己变来变去」。

**决策**

1. 兼容性属性**只写 HKCU 兼容性层**（`AppCompatFlags\Layers`），不修改 exe、不注入
   环境变量；写 HKCU 不需要管理员权限 ⇒ 天然静默。
2. **每次启动前幂等 upsert**（算差集后写），不做「仅首次写入」。
3. 差集只增删**本应用负责的四项标志**；用户手设的其它项与兼容版本**一律保留**
   （已是 `WIN7RTM` 时不夺回为 `WIN8RTM`）。
4. 关闭总开关时按记账文件 `data/compat/managed.json` **精确回滚自己写的**，
   不动用户手设项。
5. 注册表读写改 **FFI 直调 `advapi32`**，废弃 PowerShell / `reg.exe`。
6. 提权收敛到`LaunchProcessLauncher` 唯一裁决（direct / elevated / shellFallback），
   `740` 自动转提权通道。
7. 「以管理员身份运行」作为**与超分/转区同级的每游戏独立开关**，不受兼容性总开关管辖。
8. 管理器未提权时**一生只提示一次**「建议以管理员重启」，拒绝后走 `runas` 逐次 UAC。

**理由**

1. 兼容性层是 Windows 官方机制，属性页可见可复原，不是黑盒；改 exe manifest 会破坏
   文件完整性且游戏更新即失效；`__COMPAT_LAYER` 只对直接子进程生效，游戏再拉 launcher 就断。
2. 用户会手改属性页、游戏目录会迁移、换启动程序会变 —— 维护「我写过了」的状态一定会过期。
   每次校验 < 5ms，比维护会过期的状态可靠。
3. 用户把版本改成 Win7 往往正是因为 Win8 跑不起来；夺回等于把他刚修好的环境再弄坏。
4. 没有记账就无法区分「我加的」与「用户加的」，总开关要么关不干净、要么删掉用户设置。
5/6. 见下面「约束」。

**约束（Windows 硬边界，别再试）**

- 🔴 `HKEY_CURRENT_USER` 必须写成 **-2147483647**（符号扩展的 32 位值），
  传 `0x80000001` 会被零扩展成无效句柄。
- 🔴 非提权进程用 `CreateProcess` 起提权目标**必然** 740，`cmd /c start` 同样 740
  ——唯一通道是 `ShellExecuteExW` + `runas`。想全程零 UAC 只能让管理器自己提权。
- 🔴 `runas` 拉起的进程与当前进程**无父子关系**，拿不到 Dart `Process`，只能拿 PID。
- 🔴 超分场景 **Magpie 必须跟随游戏提权**，否则普通权限的 Magpie 捕获不到提权窗口
  （UIPI），超分静默失效。
- 🔴 转区场景 `LEProc.exe` 是游戏**父进程**，它提权后游戏必然继承管理员令牌。
  这是转区提权的固有代价，不做降权 token 注入。

**影响**

- 新增 `win32_registry_service` / `game_compatibility_service` / `compat_preference` /
  `elevation_service` / `launch_process_launcher` / `elevation_hint_dialog`。
- `magpie_service` 的 PowerShell DPI 设置与注册表迁移**删除**，改为委托兼容性层
  （写方从两处收敛为一处）。
- `game.json` 新增 `run_as_admin`（**不升** `format_version`，**不进** `_overwritableFields`）。
- 托盘启动改走新增的 `GameLaunchService.launchByTitle`（原直调 `launchGame` 会跳过超分）。
- **取代** ADR-001 的隐含前提：启动入口仍必须收敛到 `executeLaunch`，本 ADR 只补
  「只有标题的入口」这一条缺口的统一方法。
- 详见 `docs/DEV/features/launch_compatibility_upgrade.md`。

---

## ADR-020 · 应用目录之外的游戏本体：从「一律不删」改为「移入回收站（可还原）」

- **日期**：2026-10-26
- **状态**：✅ 生效
- **修订**：ADR-007 决策 1 的「一律不自动删除」→ 拆分出「可恢复删除」通道

**背景**

ADR-007 落地后，库页删除确认框里的「同时删除本地游戏文件」对本地导入游戏变成了
**空承诺**：`directoryPath` 就是用户自己的文件夹，归属护栏必然拒绝，`deleteGame`
只写 `_skippedBodyPaths` 然后回一条 warning。用户实测报「勾了却什么都没删」。

ADR-007 的影响段其实已把「删除进回收站」列为后续批次任务；`RecycleBinService`
（Phase 0 已验证）与 `game_archive_service`（打包后删本体）都已在使用它。

**决策**

1. 应用自有目录（`PathHelper.isInsideAppStorage`）内 → 维持永久删除（可重建，无恢复语义需求）。
2. 应用目录之外、本地磁盘上的普通用户目录 → **移入回收站**（`FOF_ALLOWUNDO`，可还原），
   且必须先过 `GameBodyRecyclePolicy` 安全边界。
3. 以下情况仍然**跳过删除**，并在回执中给出具体原因：
   网络位置（`FOF_ALLOWUNDO` 对 UNC / 映射盘无效，会退化为永久删除）、
   磁盘根目录、应用目录本身及其祖先、`SystemRoot` / `ProgramFiles(x86)` / `ProgramData`
   等系统子树、用户主目录本体与其一级子目录。
4. 每次回收/拒绝都写 `data/cleanup_log.jsonl`（`op=delete_game_body_recycle`）。

**理由**

1. 「可恢复」把 ADR-007 担心的「不可逆数据丢失」这一最坏后果消掉了，剩下的风险是
   用户误操作清空回收站——这是系统级通用心智，应用无需再兜。
2. 保留护栏而不是放行裸删：`directoryPath` 语义仍天然指向用户目录，安全边界必须存在。
3. 判定收敛到单一实现（`GameBodyRecyclePolicy`），避免又出现「三套路径规则并存」。

**影响**

- `local_game_registry.deleteGame` 本体分支四路化；新增 `_recycledBodyPaths` /
  `_skippedBodyReasons` / `canRecycleGameBody()` / `gameBodyRecycleBlockReason()`。
- 库页单条与批量删除的确认框文案、回执全部按「永久删除 / 移入回收站 / 受保护」三分支。
- 云端安装游戏行为不变（仍永久删除）。
- 未做真机走查；`test/services/game_body_recycle_policy_test.dart` 待 `flutter test` 恢复后回归。

## ADR-021 · 启动程序推荐做在展示层，与导入期检测器彻底分离

**日期：** 2026-10-26　**状态：** 已采纳

### 背景

「选择启动程序」与「启动管理」两个界面只把 `ExeScanner` 扫出来的 exe 按路径字母序
罗列。一个 galgame 目录常见 10~20 个 exe（运行库、config、CG 回収、本体、HD 版、
汉化版、补丁器、卸载器），用户分不清点哪个能进游戏。需求是**分类 + 识别版本 + 推荐汉化版**。

项目里已有一套"挑一个 exe"的规则 `game_launcher_detector.dart`（汉化关键词 → 体积最大 →
与文件夹同名），但它不能直接用：

1. 只输出**单个**结论，无法表达"分类"；
2. `_localizationKeywords` 里 `patch` 被当成**汉化正信号**，而展示层必须区分
   「汉化补丁安装器」与「汉化后的游戏本体」——两个语义相反的东西；
3. 它是**导入期**调用的（自动导入 / 批量导入共用 `detect()`）。

### 决策

1. **新建** `lib/services/launcher_candidate_analyzer.dart` 作为展示期分类器，
   `game_launcher_detector.dart` **一行不动**。两套命名规则并存是**有意接受的代价**。
2. 分析器**只依赖 `dart:io`**，禁止 import `package:flutter/*`。这样 231
   （ERROR_PIPE_BUSY）环境下可以用裸 Dart VM 跑真机探针，不必上
   `gen_kernel_aot` + `flutter_tester`。
3. 推荐是**建议**不是**决定**：不重排列表、不隐藏无关程序、不改默认选中项。
   （用户明确要求"默认仍显示灰工具标签，不隐藏不折叠""默认不自动选中只标角标"。）
4. 匹配粒度分级写进代码常量：短标记（`sc`/`tc`/`cht`/`hd`）一律**整 token 相等**，
   只有 `cn`/`chs`/`zh` 开放粘连后缀。理由见下。
5. 推荐候选必须过 **PE 头校验**（前 4KB 验 `MZ` + `PE  ` + machine）才算数；
   前 3 名都不通过就一个都不标。

### 理由 / 被否决的方案

- **扩展 `GameLauncherDetector` 输出多候选** → 否决：它会动摇自动导入与批量导入，
  回归面不可控，且两套语义（补丁器算正信号 / 算负信号）无法塞进同一张关键词表。
- **隐藏无关程序（只显示推荐的）** → 否决：用户明确要求不隐藏；且隐藏会掩盖
  "目录里其实没扫到本体"这类异常。
- **用云端/AI 判定** → 否决：离线不可用，且判定结果无法解释。
- **统一两套规则** → 本次不做（宜单独一轮，需覆盖导入链路回归）。

### 后果

- 好处：规则可解释（每步都往 `reasons` 里记依据）、可纯函数单测、可裸 Dart VM 探针、
  完全不参与启动链路，出问题最大损失是"角标标错"，不会导致游戏起不来。
- 代价：同一个 exe 在导入期与展示期可能得到不同结论（已知，记录在功能档案 §10）。
- 新增硬事实：**分类分与汉化分必须解耦**。`汉化补丁.exe` 的 H 分高达 60，但
  N2(−50) + N3(−20) 把它压回 `tool`。若把汉化分直接并进分类分，补丁器会被推荐。

---

## ADR-022 · 网络代理收敛为单例三态策略，并用全局 `HttpOverrides` 兜底

- **日期**：2026-11-13
- **状态**：✅ 生效

**背景**
代理在改前由四条链路各自实现「app 配置代理 > Windows 系统代理 > 环境变量」三级解析，且
只在 `MetadataFetcher.init()` 时解析一次。用户实测两个症状：开了代理软件后本程序无感（要重启），
开了代理后元数据抓取反而时好时坏。审计发现除时序问题外还有两个真 bug：手动 URL 会永久压过
系统代理；`PROXY $url` 未剥 `http://` 前缀，不是合法 `findProxy` 语法。

**决策**
1. 新增 `NetworkProxyPolicy`（单例）作为**唯一事实源**，三态 `system / manual / direct`；
2. 运行期跟随靠 **TTL + 请求前刷新**，不靠定时器、不靠重启：
   `findProxyFor` 是同步回调，按 10s TTL 触发一次后台刷新；接了 `attachTo(dio)` 的 Dio
   还会在请求前 `await refresh()`，保证当次请求即生效；
3. 「彻底全局」用一次性 `HttpOverrides.global` 注入：所有未显式设置 `findProxy` 的
   `HttpClient`（图片、下载、更新检查、PB 云同步）自动跟随同一策略；
4. 存量迁移靠偏好推断：`network_proxy_mode` 缺失时，`proxy_url` 有值判 `manual`、都空判
   `system` ⇒ 老用户升级零行为突变；
5. `MetadataFetcher.init()` 里触发 `load()`，**`main.dart` 一行不改**。

**理由**
1. 用户报障的根因是「解析时机」而非「解析能力」，`SystemProxyDetector` 本来就够用，
   所以不重写探测层、只重做时序与收敛；
2. 三态是一句话能讲清的模型，比「优先/回退」链更容易排查；
3. 全局钩子是唯一能覆盖「图片/下载/更新」这些不走 `MetadataFetcher` 出口的办法；
   逐个改调用方要动十几个文件，且以后新增出口还得记得接。

**影响 / 约束**
- `installGlobalOverrides()` 必须在 `FLUTTER_TEST=true` 下跳过，否则覆盖 flutter binding
  的 mock HttpClient，`test/` 里的 `HttpOverrides` 用例会发真实请求；
- 显式设了 `findProxy = 'DIRECT'` 的调用方（`openlist_service.dart` 本地 127.0.0.1）
  不受影响，这是**有意**的：本地服务走代理反而连不上；
- 全局钩子有固有时间窗：`init()` 之前创建的 `HttpClient` 仍走环境变量默认行为
  （启动顺序 `main.dart:568 runApp` → `:626 init`）；
- 只读静态系统代理注册表，PAC / WPAD / 纯 TUN 识别不了 —— 这条边界必须如实告知用户，
  不承诺「什么代理都能跟」；
- 死代理用 2s TCP 存活验证兜住（继承自旧的 `_validateProxy`），最坏每个 TTL 周期加 2s。

**否决的替代方案**
- **只收敛现有 4 条链路，不装全局钩子** → 否：图片/下载/更新仍会绕开，用户下次报障的还是
  「有的地方走代理有的不走」，等于没解决体感问题。
- **保留「app 配置 > 系统 > 环境变量」优先链，只加运行期刷新** → 否：优先链本身就是
  「填过一次就永久压过系统」的根源，用户无法表达「我要回到自动跟随」。
- **定时器轮询系统代理** → 否：空闲时也在跑 `reg query`，且刷新时机与请求无关。

---

## ADR-023 · 元数据字段优先级交给用户，批量刷新「默认只补空字段」

- **日期**：2026-11-13
- **状态**：✅ 生效

**背景**
设置页原本没有「元数据」板块：抓哪些源、哪个字段先看哪家，全是代码里的常量
（`MetadataFetcher._mixFieldPriority`）。用户报障的是体感问题——「截图到底该优先 VNDB
还是 KunGal，我们说了算，但用户觉得 VNDB 更准」。同时平台开关与 MIX 整合曾经脱钩：
关掉某平台后 MIX 仍然偷偷用它，开关看起来完全没生效。

**决策**
1. 新增设置页第 8 个 tab「元数据」，四个分组：平台账号与凭证 / 拉取来源 / 字段优先级 / 全量更新；
2. **字段优先级只做「提到链首」**：用户选的平台排到最前，其余仍按内置顺序后备
   （`MetadataFieldPriority.resolveChain`），不提供「只从这个源取」的破坏性选项；
3. **MIX 整合范围跟随平台开关**：`fetchGameMixed` 里与 `_enabledSources` 取交集；
   用户把源全关（偏好被写坏）时兜底回退到全部内置源，避免 MIX 直接失效；
4. 批量刷新 **默认 `overwrite=false`（只补空字段）**，想覆盖必须显式勾选并二次确认；
5. 刷新**绝不碰**标题（`title` / `original_title` / `subtitle`）、封面文件、截图文件；
6. 账号一期只做**凭据管理**，不做真 OAuth：Bangumi PAT 走在线校验（真发请求，
   区分 401/403 与网络不可达），2DFan 存登录 Cookie，其余站点免登录/内置凭据只做说明。

**理由**
1. 优先级是**口味问题**不是正确性问题：不同作品在不同源上的完整度差异很大，
   没有一个内置顺序能对所有作品都最优，交给用户 + 给一个合理初值才对；
2. 「只提链首」是**非破坏性**的：即使首选源这条没数据，用户仍能拿到结果，
   不会因为选错而变空——这比「只从这家取」宽容得多；
3. 批量刷新是「改完设置后的收尾动作」。不给这个入口，用户改完优先级只能一条条
   进详情页重抓，实际上等于没人会用；但**默认覆盖**等于把用户手改的简介/标签
   一次抹掉且无 undo，所以默认必须是最保守的「只补空」。

**影响 / 约束**
- `computeRefreshUpdates` 抽成纯 Dart（`metadata_refresh_core.dart`），键名白名单固定为
  10 个 game.json 字段；探针断言「越界键为空」，防止有人顺手把标题/封面写进去；
- 空值归一（空串 / 空表 / 0）在 `MetadataRefreshCandidate.fromFetched` 做一次，
  下游不再散落 `isNotEmpty` 判断——那是「某源返回空串把已有值冲成空」的经典来源；
- 标签比较用**集合语义**：只换顺序不算变化，否则每次刷新都写一遍盘；
- 写盘唯一出口仍是 `GameDataFormat.updateGameJsonAtomic`（写队列 + 原子写 + 主键护栏），
  不另开写盘口子；无字段可写时**不写盘**，不给 `updated_at` 刷无意义的时间戳；
- 刷新串行 + 400ms 间隔：抓取平台是别人的公共服务，并发轰炸只会换封 IP；
- 刻意**不做**「收藏/游玩状态同步」：本项目没有云端状态模型，做了也只有永远灰着的开关。

**否决的替代方案**
- **一对一照抄 LunaBox 的元数据页**（含批评空间网址输入）→ 否：我们的批评空间功能已移除，
  照抄会留一个填了也没用的输入框；
- **字段优先级做成「只从这家取」** → 否：选错一次该字段就永远空着，用户只会觉得「坏了」，
  且无法自查；
- **批量刷新默认覆盖** → 否：不可逆的数据损坏，且用户点之前不会想到这一点；
- **把批量刷新做成一次性 `for` 循环 + 转圈** → 否：全库几百条要跑十几分钟，
  没有进度/取消/失败重试等于让用户干等。

---

## ADR-024 · 账号凭证只做「四平台登录态」，鲲走 Cookie 透传

- **日期**：2026-11-13
- **状态**：✅ 生效

**背景**
一版把 9 个站点全列成「账号卡」，其中 7 个是免登录/内置凭据，只写说明不放假输入框。
用户指出这与 ReinaManager / LunaBox 的「账号授权」语义不一致：账号区应当是**登入站点**
换更好的服务，而不是一张站点清单。同时用户判断「Hikarinagi 需要登录才能用」，
要求我们研究。

**实测（真发请求，不是推断）**
1. Hikarinagi **不需要用户登录**：内置 `client_credentials` 能换到 access_token
   （`open_throttle_limit=600`），带该 token 搜「缘之空」正常返回；但**直连被 reset、
   走代理即通** —— 它的问题在网络，不在凭据。
2. 鲲 kungal.com 的 `/api/**` 自 2026-11 起整站登录门禁：匿名一律
   `{"code":205,"message":"用户登录失效"}`（HTTP 200），`/api/galgame/{id}` 401。
   **这才是「元数据里鲲一条都搜不到」的真因**（旧代码把 205 当「没数据」静默吞掉）。
3. NextMoe 公共目录免登录可读，因此鲲未登录时这一组的另一半仍然可用。
4. 鲲的 OAuth：授权码流程 + 回调写死 `https://www.kungal.com/auth/callback`，
   第三方拿不到；LunaBox 是自建 public client 并在构建时注入 client_id，仓库里没有该值。

**决策**
1. 账号区只保留四家：Bangumi（PAT）/ 鲲GAL/NextMoe（Cookie）/ Hikarinagi（内置凭据，
   提供「测试连通性」）/ 2DFan（Cookie）；其余平台改为页脚一句说明；
2. 鲲 + NextMoe **合并为一张「鲲GAL/NextMoe」卡片**，来源开关、账号卡、优先级下拉
   全部按平台组呈现，抓取层仍是独立 `SourceType`；
3. 鲲一期用**透传浏览器 Cookie**（`KunCookieStore`，prefs `kun_galgame_cookie`），
   `KunService` 每次请求带 `Cookie` 头；**识别 `code 205` 并在 `fetchLog` 明说「需要登录」**，
   不再伪装成「没数据」；
4. CT 探索库图标改用软件自身 `assets/images/app_icon.png`；
5. 字段优先级的值升级为**列表**（平台组），兼容旧单值 JSON。

**理由**
1. 账号区的价值是「登录能多拿到什么」，把免登录站点也列进来只会让用户以为「不登录就用不了」；
2. 鲲的登录不可省：不登录等于该源彻底失效，必须给用户一条可执行的路径，
   而 Cookie 是唯一不需要站点配合的方式；
3. 合并卡片消灭了「关掉鲲但 NextMoe 还在用」的中间态，也和用户对「一个站」的认知一致；
4. 让 `fetchLog` 说出「需要登录」，是把「静默失败」变成「可诊断」的关键 —— 否则用户/我们
   都会继续怀疑代理。

**影响 / 约束**
- 凭据只落 `SharedPreferences`，不上传、不打印；Cookie 原样透传，不解析键名（站点改名也不用改代码）；
- 所有「验证」都是真请求，且必须区分「凭据无效」与「连不上」；
- 2DFan 的**积分下载**不在本轮范围：真实扣积分不可逆，需单独方案（见 features §10），
  当前话术如实写「补丁资源仍走原站，本软件不代扣积分」。

**否决的替代方案**
- **照抄 LunaBox 的鲲 OAuth** → 否：client_id 是人家注册的，回调也在站点侧，我们拿不到；
- **给免登录站点也留空输入框** → 否：用户会以为不填就不完整，实际填了也没用；
- **把 205 当普通空结果** → 否：这正是「鲲搜不到」被误判成代理问题的原因；
- **鲲/NextMoe 保持两张卡** → 否：同生态两个开关，用户无法理解为何关了一个还有数据。

---

## ADR-025 · 平台账号走「浏览器 OAuth + 本地回环回调」，复用已注册的公共客户端

- **日期**：2026-11-13
- **状态**：✅ 生效

**背景**
ADR-024 把账号区收成「四平台登录态」，但一期只做凭据管理（用户手抄 Cookie / PAT）。
用户随后指出：LunaBox 与 ReinaManager 都是「点一下 → 跳浏览器 → 回来就登好了」，
并直接给出了真实的 authorize URL（含 `client_id` / `redirect_uri` / `code_challenge`）。
问题因此变成：**我们能不能也做真 OAuth？**

**实测（curl 真发请求）**
1. 两家都是 **PKCE 公共客户端**：NextMoe 发现文档里
   `token_endpoint_auth_methods_supported` 含 `none`，换令牌不需要 secret；
2. **没有动态注册**：两家都没有 `registration_endpoint`，`id.hikarinagi.org/oidc/register` 404；
3. **回调地址严格白名单**：同一 client 换端口 → NextMoe `{"code":15002,"message":"无效的回调地址"}`、
   Hikarinagi 400；用原配地址 → 303 进授权页（Hikarinagi 跳到 `/interaction/…`，Ory 授权流）；
4. 鲲的元数据实际来自 `api.nextmoe.dev/v2`（LunaBox `metadata_kungal.go` 的 base 就是它），
   而 `www.kungal.com/api` 是老接口：匿名与带 Bearer 都回 `{"code":205}`（站点用 Cookie 会话）。

**决策**
1. 实现完整 OAuth 授权码 + PKCE：本地 `HttpServer` 绑 `127.0.0.1:23380`，按路径分发
   `/callback/nextmoe`、`/callback/hikarinagi`，`state` 校验，5 分钟超时，可取消；
2. **复用 ReinaManager 已注册的公共客户端**（`client_id` + 固定回调），参数集中在
   `lib/services/oauth/oauth_providers.dart`，其他代码不出现字面量；
3. 令牌只存本机 `SharedPreferences`（`oauth_token_v1_<provider>`），提前 60s 刷新，
   refresh 轮换**原地覆盖**；
4. 抓取层真正接入：Hikarinagi 用户令牌优先（不再挤全软件共享的 `client_credentials`）；
   NextMoe 用 Dio 拦截器按请求注入（登录后用用户自己的额度）；
5. Bangumi 保持 PAT（OAuth 需 `client_secret`，硬编进发行包即泄漏）；
   鲲旧接口保持 Cookie（令牌对它无效），账号区以 OAuth 为主入口、Cookie 折叠为后备；
6. 端口被占用时给出点名提示（ReinaManager 常驻 23380），不做「换端口重试」。

**理由**
1. 用户的诉求是「像参考项目那样点一下就登进去」，凭据管理只是权宜；现在证据表明
   技术上完全可行，且不需要我们持有任何密钥；
2. 复用公共客户端虽然会让授权页显示别人的应用名，但它是**无 secret 的 PKCE 客户端**，
   令牌仍受 verifier 保护，风险可接受；且这是当前唯一不依赖站点配合的路径；
3. 把 client 参数收在一处，将来自己注册「Chrono Tide」应用只改 3 行 —— 决策成本前置；
4. 令牌真的接进抓取层才算「登录有用」，否则用户登录完发现抓取毫无变化，会认为功能是假的。

**影响 / 约束**
- 🔴 回调端口与 client 绑定，**不能换端口**；且 23380 与 ReinaManager 冲突（实测本机常驻）。
  这是本轮明确接受的限制，靠「点名提示 + 建议自行注册应用」缓解；
- 🔴 回调服务器必须「先写响应 → 再 complete → 再 close」，否则 `waitFor` 的 `finally`
  会 `close(force: true)` 掐断回调页；
- 🔴 抓取层的令牌取值必须**同步**（`cachedAccessToken()`，将过期即返回 null 回退），
  不能为了刷新把整条请求链变异步；
- 令牌不入日志、不进云备份；退出登录只清本机，不调站点 revoke（避免误撤其他设备）。

**否决的替代方案**
- **内嵌 WebView 登录** → 否：要引新依赖，且拦截 `127.0.0.1` 回调比直接开系统浏览器更脆；
- **自己注册普通 public client 并写死 secret** → 否：public client 没有 secret；
  confidential client 的 secret 写进发行包等于公开；
- **给 23380 做「换端口重试」** → 否：站点会直接拒（15002），重试只是把错误延后；
- **只存令牌不改抓取层** → 否：登录变成纯装饰，属于欺骗性 UI；
- **把 Bangumi 也改成 OAuth** → 否：拿不到 `client_secret`，而且 PAT 是官方等价方案。
