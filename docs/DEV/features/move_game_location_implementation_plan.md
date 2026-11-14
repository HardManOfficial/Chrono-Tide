# 游戏目录真迁移（移动游戏位置 v2）实施计划

> **文档性质**：方案研究文档（阶段 A 产出）→ **已批准实施**
> **产出日期**：2026-09-12　**状态**：✅ Phase 0-4 全部代码完成（含注册表扫描 UI 闭环），单测 12/12（09-12 深夜），待真机走查
> **需求来源**：用户反馈——「移动游戏位置」执行时实际是复制粘贴到目标位置，并未真正转移文件。
> **用户已拍板的三项决策**（2026-09-12 AskUserQuestion 确认）：
> ① 旧目录：移动成功后**自动删除**（校验通过后清源）；② 注册表：**修应用自身引用 + 只读检测报告**（不自动改写游戏注册表项）；③ 校验与依赖：**零新增依赖**（不碰 pubspec.yaml）。
>
> **实施记录（2026-09-12）**：
> - Phase 0 四项验证**全部通过**：同卷 rename 4ms 原子（含中文/只读/深层嵌套；目标已存在抛 osError=183 两端无损）；跨卷 rename 抛 osError=17 可捕获；杀进程后源完好/目标半成品/登记可读；FFI advapi32 Open/Query/Enum 正确；PowerShell HKCU 读改写通过。
> - 新增 `lib/services/game_move_service.dart`（五阶段事务 + debugForceCrossVolume/debugFailAtRelativePath 测试接缝）、`lib/services/registry_path_scanner.dart`（FFI 只读扫描，isolate 执行，深度 10/键数 5000/30s 超时防护）。
> - 修改：`local_game_registry.dart`（+finalizeGameMove 聚合，紧随 relink）、`magpie_service.dart`（+updateGamePaths：DPI 注册表值改名 + 类名缓存键迁移）、`save_backup_service.dart`（+rewriteOriginalPathsPrefix）、`interrupt_cleanup.dart`（startupScan 尾部接入启动检测）、`game_detail_dialog.dart`（move 流程改调服务 + `_MoveProgressDialog` 三态：进度 → **完成页（结果概要 + "扫描仍引用旧路径的注册表项"按钮 + 命中列表/未发现提示 + 截断警告）** + 删 _copyDirectory + 确认框明示删除原目录 + 运行中守卫 + 启动残留提示）。
> - `MoveResult` 含 `sourcePath`（供完成页扫描使用）；所有返回点均已填充。
> - 测试：`test/services/game_move_service_test.dart` **10/10**（同卷 rename / 跨卷 copy / 注入失败回滚 / M0 三守卫 / 登记与启动检测 / 互斥复位 / sourcePath 断言）+ `test/services/registry_path_scanner_test.dart` **2/2**（空路径早退 / 随机 needle 真实扫描）。实施中新发现：相对路径会使同卷判定失效且卷空间查询返回 -1 → 服务入口已做绝对路径归一化 + 预检仅在数据可信时执行。
> - 待办：**真机走查 §11 清单 10 项**（注册表扫描 UI 已接通，第 ⑨ 项可直接走查）。

---

## 0. 结论摘要（TL;DR）

| 维度 | 结论 |
|------|------|
| 根因 | move 的"复制语义"是**当初有意设计**（`local_game_registry.dart:889-913` 注释明写"移动是复制而非剪切，旧文件仍存在"），且复制逻辑放在 **UI 层**（`game_detail_dialog.dart:760-778` + `_copyDirectory` :820-838），service 层只改引用 |
| 核心方案 | 新增 `GameMoveService`（service 层迁移引擎）：**同卷 = `Directory.rename` 原子移动**（O(1) 瞬时）；**跨卷 = isolate 流式 copy + 逐文件字节数校验 + 通过后清源**。五阶段事务状态机（校验→计划→搬运→引用切换→收尾），失败只清目标、源永不动 |
| 回滚机制 | 跨卷 copy 失败/中断/取消 → 删除"本任务自建"的目标目录（显式登记 + 照搬 `_rollback` 先保源范式）；`data/move_in_progress.json` 事务登记落盘，启动时检测半成品并提示 |
| 注册表 | 应用自身：Magpie 注册表键用现有 PowerShell 范式修正 + 快捷方式重生成 + `default_exe` 配置 resync + 存档清单 `originalPaths` 前缀改写；游戏自身：**只读扫描检测**（FFI 直调 advapi32，零依赖），报告不自动改写 |
| 改动面 | 新增 3 文件（service + 注册表扫描器 + 测试）；修改 5 文件（dialog / registry / magpie / save_backup / interrupt_cleanup）；**不碰** BPM、pubspec、windows/runner、relink 流程、稳定区 |
| 性能 | 同卷 <100ms；跨卷受磁盘吞吐限制（300GB HDD 约 35min+）→ isolate 后台 + 进度回调 + 可取消，UI 零卡顿（吸取 IMP-12 教训） |
| 最大风险 | P0 = **删除源目录的数据安全**（与 ADR-007"应用外目录不自动删除"的边界处理）：删除属于用户显式批准的移动语义，确认框明示真实路径 + 删除前二次校验 + 审计日志 |

---

## 1. 背景与目标

### 1.1 背景

详情弹窗「移动游戏位置」功能当前行为：把游戏文件**逐个复制**到目标目录，然后更新 `game.json` 的路径引用，**旧目录原封不动**。用户预期是"移动"——文件整体转移、旧位置不再占用空间。实际效果等于"备份一份"，大体积游戏（数十至数百 GB）浪费一倍磁盘空间，且复制期间 UI isolate 同步跑大 IO，存在卡顿风险（IMP-12 同类问题）。

### 1.2 目标

1. 「移动游戏位置」语义改为**真迁移**：全部本地文件完整转移到目标目录，成功后旧目录被清理；
2. 迁移过程**不损坏游戏本体与存档**：逐文件校验 + 失败自动回滚 + 中断可恢复；
3. 迁移后**所有路径引用同步更新**：game.json、启动配置、桌面快捷方式、Magpie 超分键、存档备份清单；
4. 迁移全程**进度可视、可取消**，UI 不卡顿。

### 1.3 非目标（本期明确不做）

- ❌ 不为 BPM 大屏 / 库页 / 主页新增移动入口（现状唯一入口在详情弹窗，维持）；
- ❌ 不自动改写游戏自身写入注册表的路径项（只检测报告）；
- ❌ 不做批量移动（一次一个游戏）；
- ❌ 不动「更换游戏目录」（relink）功能——它恰好是本方案的**失败修复兜底工具**；
- ❌ 不新增 pubspec 依赖（win32_registry 3.x 需 Dart ≥3.11，本项目 Dart 3.5.3 不兼容；FFI 零依赖方案已验证有项目先例）;
- ❌ 不做 junction（目录联接）留痕方案（用户已否决该项）；
- ❌ 不碰 `windows/runner/`、`lib/theme/`、`lib/main*.dart` 等稳定区。

---

## 2. 现状调研（全部带路径:行号，2026-09-12 核实）

### 2.1 现有调用链与根因定位

| 环节 | 位置 | 现状 |
|------|------|------|
| 唯一 UI 入口 | `lib/widgets/game_detail_dialog.dart:2626` | 目录行 onTap → `_showDirectoryActionMenu`（:614） |
| 入口菜单 | `game_detail_dialog.dart:614-658` | 「更换游戏目录 / 移动游戏位置」二选一（relink 与 move 共菜单，4803/4809 行分发） |
| move 弹窗 | `game_detail_dialog.dart:657→747` | `_showMoveLocationDialog`，确认后 `pop(targetFullPath)`（`_MoveLocationDialog._confirmMove` :4233-4244） |
| **复制发生地（根因）** | `game_detail_dialog.dart:760-778` + `_copyDirectory` :820-838 | `source.list(recursive: true)` 拉全树 + 逐文件 `entity.copy`，**在 UI isolate 同步 await**，无 isolate、无进度回调、无校验 |
| 引用更新 | `local_game_registry.dart:879-936` `updateGameLocation` | 重算 launchPath（:889-913）、写 `directory_path`/`launch_path` 进 game.json（:918-924）、`refreshActiveSessionExes`（:927） |
| **不删源（根因）** | `game_detail_dialog.dart:760-818` 全函数 | 无任何 `delete`/`remove` 调用；`registry:889-913` 注释明写"移动是复制而非剪切，旧文件仍存在" |
| 启动配置同步 | `game_detail_dialog.dart:844-872` `_resyncLauncherConfig` | move/relink 共用，从注册表重读 launchPath 同步 GameConfigManager + prefs（`default_exe_$title` 存**绝对路径**） |
| relink（已实施） | `local_game_registry.dart:961-1055` `relinkGameLocation`；`game_detail_dialog.dart:4267-4750` `_RelinkLocationDialog`；`path_validator.dart:103` `validateExistingGameLocation` | 只改引用不搬文件，要求新目录已存在，`GameLauncherDetector.detect` 兜底（:1021） |
| 运行中守卫 | — | **无**。move/relink 全链路不检查游戏是否运行（`activeSessionDirs` 仅 `running_tasks_service.dart:407` 用于任务栏判定） |
| UI 刷新 | `library_page.dart:745-752` `_silentRefresh`；`registry:1050` | relink 故意不调 `_notifyStructural`，复用 move 的 `then(_silentRefresh)` 链路 |

**根因结论**：
1. "复制不删源"是历史上有意的设计（安全优先），但与用户对"移动"的预期不符——需要重新定义语义并补齐安全工程（校验、回滚、审计）；
2. 文件搬运放在 UI 层是结构性缺陷：无法接入 isolate、进度、事务、中断恢复，必须下沉 service 层。

### 2.2 迁移后需要同步的引用面（已逐个核实）

| 消费方 | 位置 | 存储形态 | 迁移影响 | 处理 |
|--------|------|----------|----------|------|
| game.json | `game_data_format.dart:1171-1172`（定义）、`:1302-1303`（写）、`:1255-1256`（读）、`:153`（launchPath 转相对）、`:158-159`（directoryPath 存绝对） | directoryPath=绝对 / launchPath=相对 | 失效 | `updateGameLocation`（现成） |
| 启动配置 | `game_launch_service.dart:103,115,143,147` | `default_exe_$title` 绝对路径（prefs + GameConfigManager） | 失效 | `_resyncLauncherConfig`（现成，需复用） |
| 桌面快捷方式 | `shortcut_service.dart:203-216` | .lnk 内嵌绝对 exe + gameDirectory | 失效 | 重生成（service 有现成创建能力，P1） |
| Magpie 超分 | `magpie_service.dart:765-788` | **注册表键（HKCU）**，PowerShell `Set-ItemProperty` 写游戏 exe 绝对路径 | 窗口匹配失效 | 新增"键值路径替换"公开方法（复用现有 PowerShell 范式） |
| Magpie 缓存 | `magpie_service.dart:658` | `classNameCache` 以 exePath 为键存 prefs | 失效 | 键迁移或清除（下次启动自动重建） |
| 存档备份 | `save_backup_service.dart:82-85`（备份目录 `Games/{safeName}/saves/` 按游戏名键）、`:22`（`originalPaths` 相对→绝对映射） | 与本体目录**解耦**；但若存档原位于本体目录内（portable galgame 常见），`originalPaths` 指向旧绝对路径 | 恢复/再备份找不到旧路径 | 新增 `originalPaths` 前缀改写方法（P1） |
| 截图 | `game_data_format.dart:1029`、`game_detail_page.dart:356-357` | 存 `metaDataDir/screenshots/`（应用自有目录） | **不受影响** | 无 |
| 体积统计 | `file_size_service.dart:200` | 实时扫描无持久化 | 自动跟随 | 无 |
| watch_folder / 转区 | `watch_folder.dart:43,226`、`locale_service.dart:131-134` | 导入监控路径 / 运行时参数 | 不受影响 | 无 |
| 存档扫描 | `save_scanner.dart` 等 | 扫描时机运行态 | 不受影响 | 无 |

**metaDataDir 与本体天然解耦**（`PathHelper.gamesDir/$safeName`，`local_game_registry.dart:328`），元数据/封面/截图不受迁移影响；仅 `local_game_registry.dart:1114` `_metaFallsInsideBodyDir` 的特例布局需留意。

### 2.3 可复用的安全基础设施

| 能力 | 位置 | 复用方式 |
|------|------|----------|
| 路径归属护栏 | `path_helper.dart:170-191` `isInsideAppStorage` | 目标目录合法性校验；源目录删除的边界判定 |
| 审计日志 | `storage/cleanup_utils.dart:15` `deleteWithRetry` → `:135-144` 写 `data/cleanup_log.jsonl` | 清源操作强制走它 |
| 回滚先例 | `global_install_center.dart:761-873` `_rollback`（先保源、失败只清目标 :849,873）；`extract_manager.dart:1733-1777` `_cleanupOnFailure` | 状态机骨架照搬 |
| 显式登记范式 | `extract_manager._taskOwnedTempArchives`（IMP-06/08 引入） | "本任务自建目标目录"的回滚依据，**不用时间戳判归属**（ADR-008） |
| 中断恢复先例 | `interrupt_cleanup.dart`（退出清理 + 归属护栏） | 启动/退出时检测进行中迁移事务 |
| 零依赖 FFI 范式 | `big_picture/services/bpm_gamepad_service.dart:315-328`（`DynamicLibrary.open` 多 DLL 回退 + `lookupFunction` + 失败静默降级） | advapi32.dll 注册表 API 直调 |
| 校验能力现状 | — | **无哈希**（lib 内 md5/sha 仅 pubspec.lock 命中）；最细为 `save_backup_service.dart:133` 字节累计 → 本方案用**逐文件字节数对比** |
| 服务级互斥先例 | IMP-10/11（批量入库互斥 + UI 守卫） | MoveService 单飞互斥 |

---

## 3. 技术选型（含被淘汰项）

### 3.1 同卷移动

| 方案 | 结论 | 理由 |
|------|------|------|
| **`Directory.rename`** | ✅ 采用 | 同卷目录改名 = `MoveFile` 元数据操作，O(1) 瞬时完成、原子性天然保证完整（无校验需求、无源清理步骤）。已联网确认：Dart `rename` 同文件系统可靠，跨文件系统抛 `FileSystemException (Cross-device link)`（dart-api 文档 + dcli/dbas_filesystem 均采用"rename 优先、失败 copy+delete"范式） |
| copy + verify + delete（跨卷范式用于同卷） | ❌ 淘汰 | 白白消耗整盘 IO 与时间，且引入不必要的中间态 |
| 外部 Robocopy /Move | ❌ 淘汰（一期） | 进程外依赖、输出解析脆弱、失败语义不透明；列为 P2 优化候选 |

### 3.2 跨卷移动

| 方案 | 结论 | 理由 |
|------|------|------|
| **isolate 流式 copy + 逐文件字节校验** | ✅ 采用 | 零依赖；`Isolate.run` 承载 IO，UI 零卡顿；每文件 copy 后 `length()` 对比，异常即中断回滚 |
| dcli `move` / dbas_filesystem | ❌ 淘汰 | 引入重依赖；无逐文件进度粒度；违反零新增依赖决策 |
| 全文件哈希（crypto 包） | ❌ 淘汰（用户已拍板） | 大目录耗时近翻倍 + pubspec 新增依赖；字节数校验 + 关键文件（启动 exe）存在性/大小确认已覆盖"复制损坏"主风险 |

### 3.3 注册表读取/修正

| 方案 | 结论 | 理由 |
|------|------|------|
| **FFI 直调 advapi32.dll**（RegOpenKeyEx / RegEnumKeyEx / RegEnumValue / RegQueryValueEx / RegCloseKey） | ✅ 采用（只读检测） | 零依赖；照搬 `bpm_gamepad_service.dart:315-328` 范式；只读权限打开（KEY_READ），无写风险 |
| win32 / win32_registry 包 | ❌ 淘汰 | 新增依赖；win32_registry 3.x 需 Dart ≥3.11 > 本项目 3.5.3，旧版 API 已大改 |
| PowerShell | ✅ 沿用（仅 Magpie 键修正） | 与 `magpie_service.dart:770,788` 现有写键范式一致，改动最小；不引入新的系统交互方式 |
| 自动改写 HKCU 匹配项 | ❌ 淘汰（用户已拍板） | 注册表误改不可逆；改为只读扫描 + 报告 |

### 3.4 进度 UI

复用现有下载进度条组件的视觉风格（`lib/widgets/download_progress_bar.dart`），在移动确认后弹出**不可误关的进度对话框**（字节进度 + 当前文件名 + 取消按钮）。取消语义：跨卷 copy 收到取消信号 → 停止后续文件 → 走回滚（删自建目标）→ 报告"已取消，源文件未受影响"。

---

## 4. 架构设计

### 4.1 分层与组件

```
┌─ UI 层（game_detail_dialog.dart，最小改动）
│    _showMoveLocationDialog ──改为──▶ 调 MoveService.move() + 订阅进度流
│    进度对话框（新增私有 widget）＋运行中守卫提示 ＋结果页（含注册表扫描入口）
│
├─ 引擎层（新增 lib/services/game_move_service.dart）
│    GameMoveService（单例，服务级互斥）
│      ├─ Phase M0 前置校验：运行中守卫 / 源存在 / 目标合法 / 磁盘空间
│      ├─ Phase M1 事务登记：data/move_in_progress.json 落盘
│      ├─ Phase M2 搬运：同卷 rename（原子）｜跨卷 isolate 流式 copy+校验
│      ├─ Phase M3 清源（跨卷）：CleanupUtils.deleteWithRetry + 审计日志
│      ├─ Phase M4 引用切换：updateGameLocation → resync 配置 → 快捷方式
│      │                      → Magpie 键 → 存档清单改写（逐项 best-effort）
│      └─ Phase M5 收尾：清事务登记 + _notifyStructural + MoveResult
│    GameMoveProgress（进度快照：字节/总量/当前文件/阶段）   ← ChangeNotifier
│
├─ 支撑层（修改现有服务，各加一个公开方法）
│    magpie_service：修正注册表键中的旧 exe 路径
│    save_backup_service：originalPaths 旧前缀改写
│    local_game_registry：暴露"迁移后引用切换"聚合入口（复用 updateGameLocation）
│    interrupt_cleanup：启动/退出检测 move_in_progress 残留
│
└─ 检测层（新增 lib/services/registry_path_scanner.dart）
     RegistryPathScanner：FFI 只读扫描 HKCU（+Uninstall/App Paths 常见位置）
     → 返回「键路径 + 值名 + 值内容」命中列表，仅报告
```

### 4.2 状态机与触发时机

```
[M0 校验失败] ──▶ FAILED(源/目标/空间/运行中原因)         ← 未落盘，无残留
[M2 rename 失败] ─▶ FAILED(原子失败，源目标均无变化)       ← 同卷路径
[M2 copy 中失败/取消/进程被杀] ─▶ ROLLBACK：删自建目标目录  ← 源完好；登记文件保证
                                  （仅删 M1 登记过的路径）     重启后仍可检测半成品
[M3 清源失败(占用)] ─▶ PARTIAL：新目录完整可用，报告旧目录残留  ← 不回滚文件
[M4 引用切换部分失败] ─▶ PARTIAL：文件已迁移，逐项报告失败项，
                                   引导用「更换游戏目录」修复  ← 绝不回滚文件
[M5 完成] ─▶ SUCCESS（审计日志完整记录事务）
```

关键原则（继承 ADR-007 / ADR-008 / `_rollback` 先例）：
1. **先保源**：任何失败路径下源目录要么完好、要么已在确认后显式删除；永远不会出现"两边都不完整"；
2. **回滚只删自己建的东西**：目标目录路径在 M1 落盘登记，回滚只删登记过的路径——不猜、不按时间戳判归属；
3. **引用切换失败不回滚文件**：文件迁移已验证完整，relink 是现成修复工具；
4. **删除必审计**：清源走 `CleanupUtils.deleteWithRetry` → `cleanup_log.jsonl`。

### 4.3 四大风险点的处理方案（对应用户四问）

#### 风险 1：游戏文件与存档的完整性保障

- **同卷**：`Directory.rename` 原子操作，文件系统保证要么完整要么没动；
- **跨卷**：isolate 内逐文件流式 copy（`File.copy` 内部即流式）→ 每文件完成后 `source.length() == target.length()` 立即校验 → 失败重试 1 次 → 再失败**整体中断并回滚**（已复制的部分随自建目标目录一起删除）；
- **全树校验通过**才允许进入 M3 清源——"先验证后删除"，杜绝"删了旧的、新的却是坏的"；
- **存档**：存档目录与应用 Games/ 元数据解耦（§2.2），本体迁移不动存档；若存档位于本体目录内，它作为本体文件一起被迁移（rename 或 copy 均携带），`originalPaths` 引用在 M4 改写；
- **引用切换（M4）在文件验证完成后进行**：游戏从旧路径切到新路径时，新路径的可启动性已由文件完整性保证。

#### 风险 2：注册表路径引用的检测与修正

分两层，与用户决策一致：
- **应用自身引用（自动修，M4）**：
  - Magpie 注册表键：照 `magpie_service.dart:765-788` 的 PowerShell 范式新增 `updateRegistryPaths(oldExe, newExe)`——读取现值 → 值中包含旧 exe 路径则替换为新路径 → 写回；失败仅告警不阻断（Magpie 下次窗口匹配失败可重建）；
  - Magpie `classNameCache`（prefs，:658）：删除旧 exePath 键（下次启动重建）；
  - 快捷方式：检测旧 .lnk（`shortcut_service` 现有生成逻辑反查），存在则重生成；
  - 启动配置：`_resyncLauncherConfig` 现成逻辑复用。
- **游戏自身注册表依赖（只读检测报告）**：
  - 新增 `RegistryPathScanner`：FFI 打开 `advapi32.dll`，以 KEY_READ 遍历 `HKCU\Software`（深度/条目数上限 + 30s 超时可取消）+ `HKCU\...\Uninstall`、`App Paths` 常见位置（行业可靠位置范式），枚举 REG_SZ / REG_EXPAND_SZ 值，对旧路径做**归一化大小写不敏感包含匹配**；
  - 命中项在迁移结果页列出（键路径、值名、值内容），由用户自行判断处理——**绝不自动改写**；
  - 扫描放 isolate、为迁移结果页的**可选按钮**，不阻塞主流程。

#### 风险 3：原目录清理策略（用户已拍板：校验通过后自动删除）

- 同卷 rename：无残留（rename 本身即转移）；
- 跨卷：M2 全文件校验通过后，M3 删源（`CleanupUtils.deleteWithRetry` + 审计日志 + 确认框已明示）；
- 个别文件被占用（杀毒/索引/手柄残留句柄）删不掉：重试一次后**如实报告残留**，新目录已完整可用，不视为整体失败；
- ADR-007 边界处理（本方案最重要的合规点）：ADR-007 规定"应用自有目录之外一律不自动删除"——迁移清源是**用户显式批准的移动语义的一部分**（确认框中明示"移动完成后将删除原目录：`<真实路径>`"，用户点确认即为显式批准），且满足 ADR-007 第 3 条（确认框明示真实路径 + 审计日志 + 归属确证：源路径 == `game.directoryPath` 当前值，目标目录为本任务登记自建）。此外删除前**再次验证**新目录文件计数与总字节数与计划一致。

#### 风险 4：失败/中断的回滚与数据安全

| 中断点 | 后果 | 保障 |
|--------|------|------|
| M0/M1 | 无任何落盘变更 | 无残留 |
| M2 同卷 rename 失败 | 原子失败，两端无损 | 报错重试 |
| M2 跨卷 copy 中失败/取消 | 源完好、目标半成品 | 立即回滚删自建目标（登记路径） |
| M2 期间进程被杀/断电 | 源完好、目标半成品、登记文件留存 | 下次启动 `move_in_progress.json` 检测 → 提示用户清理半成品（不自动删，遵循 ADR-007"无法确认时保留"方向；但登记文件本身就是显式归属证据，可在用户确认后删） |
| M3 清源失败 | 新目录完整、旧目录残留 | 报告 PARTIAL + 审计日志，不回滚 |
| M4 引用切换失败 | 文件已迁移、引用未切 | 逐项 best-effort + 报告 + relink 修复引导 |
| M4 期间进程被杀 | 文件已迁移、引用未切、登记文件留存 | 同上启动检测；`directoryPath` 指旧路径 → 打开目录失败 → 用户可用 relink 修复（现有功能正好覆盖） |

并发防护：MoveService 服务级互斥（同一时刻仅一个迁移任务）；迁移期间详情弹窗的移动/更换/删除入口置灰（UI 守卫，照 IMP-09/11 范式）。

---

## 5. 数据模型变更

| 项 | 变更 | 是否触发迁移 |
|----|------|--------------|
| `Game` 运行时类（`local_game_registry.dart:117,219`） | **无新字段**（directoryPath/launchPath 已有） | 否 |
| game.json schema（`game_data_format.dart:1171-1172`） | **无 schema 变更**（`directory_path`/`launch_path` 既有） | 否，`format_version` 不动 |
| 事务登记 `data/move_in_progress.json` | **新增独立文件**（非 schema 字段）：`{taskId, gameTitle, sourcePath, targetPath, phase, startedAt}` | 否，新文件零迁移；读取用 `?? 默认值` 容错脏数据 |
| `data/cleanup_log.jsonl` | 复用现有审计格式 | 否 |

---

## 6. 性能预算

| 操作 | 预算 | 手段 |
|------|------|------|
| 同卷移动 | < 100ms | rename 元数据操作 |
| 跨卷搬运 | 受磁盘吞吐限制（HDD ~100-150MB/s → 300GB ≈ 35min+） | isolate 后台 + 字节级进度流 + 可取消；**UI isolate 零同步 IO**（IMP-12 教训） |
| M1 目录枚举 | 与 M2 并行边传边计，不单独全树预扫阻塞 | 流式枚举（**不用** `list(recursive: true)` 一次性拉全树——现有 `_copyDirectory` :820-838 的做法对几十万文件有内存与不一致风险，弃用） |
| M4 引用切换 | < 1s | 本地 JSON/prefs/注册表少量操作 |
| 注册表扫描 | 上限 30s，isolate，可取消，可跳过 | 仅用户点击时触发 |
| 启动检测登记文件 | < 10ms | 读一个 JSON |

---

## 7. 实施阶段划分

### Phase 0 —— 技术验证（先行证伪，1 个 spike 脚本 + 手工验证，不改业务代码）

1. **同卷 rename**：Dart `Directory.rename` 在 Windows 对深层嵌套目录 / 含只读文件 / 目标父目录存在但最终目录不存在的真实行为（重点：目标已存在时的异常类型；超长路径表现）；
2. **跨卷失败注入**：copy 中途 TaskManager 杀进程 → 确认源完好、目标半成品、登记文件可检测；
3. **FFI advapi32 最小原型**：RegOpenKeyEx → RegEnumValue 枚举 HKCU 某键的 REG_SZ 值（缓冲区管理是易错点）；
4. **Magpie 键修正**：PowerShell 读取 → 替换路径 → 写回 → Magpie 实测仍能匹配窗口。

### Phase 1 —— 迁移引擎（service 层，可独立验证）

- 新增 `lib/services/game_move_service.dart`：五阶段状态机 + 互斥 + 进度流 + 回滚 + 事务登记；
- 新增 `test/services/game_move_service_test.dart`：成功（同卷/跨卷）/ copy 失败回滚 / 取消 / 校验失败 / 清源占用 PARTIAL / 登记文件写读清 / 互斥拒绝并发，全部基于临时目录（照 `import_data_safety_guard_test.dart` 的"应用外目录"用例范式——⚠️ 用项目内 `.dart_tool/` 而非 systemTemp，见 MEMORY 已知坑）。

### Phase 2 —— 引用同步链

- `magpie_service.dart`：新增 `updateRegistryPaths()`（PowerShell 范式）+ `classNameCache` 旧键清除；
- `save_backup_service.dart`：新增 `rewriteOriginalPathsPrefix()`；
- `local_game_registry.dart`：新增"迁移收尾聚合"公开方法（内部调 `updateGameLocation` + 暴露给 MoveService 的 resync 钩子），**不改动 updateGameLocation 本体**；
- `shortcut_service.dart`：MoveService 直接调用现有生成方法（不改动该文件，除非缺"判断已有快捷方式"的查询能力）。

### Phase 3 —— UI 接线

- `game_detail_dialog.dart`：`_showMoveLocationDialog` 复制段（:760-778）替换为 MoveService 调用；新增进度对话框（字节进度 + 当前文件 + 取消）与结果页（成功 / PARTIAL 残留报告 / 注册表扫描按钮）；**删除 `_copyDirectory`**（:820-838，唯一调用方即 move 流程）；
- 运行中守卫提示（入口前置检查 + 确认框内文案）；
- 确认框明示："移动完成后将删除原目录：`<真实路径>`"。

### Phase 4 —— 中断恢复

- `interrupt_cleanup.dart`：启动时读 `move_in_progress.json` → 存在则弹提示（含登记路径）→ 用户确认后清理半成品并清登记；正常 M5 完成时清登记；
- 退出时不做额外清理（迁移是显式长任务，中途退出按崩溃路径处理）。

### Phase 5 —— 回归与真机走查

见 §11。

---

## 8. 改动文件清单

### 新增

| 文件 | 内容 |
|------|------|
| `lib/services/game_move_service.dart` | 迁移引擎：状态机 / isolate 搬运 / 校验 / 回滚 / 事务登记 / 进度流 |
| `lib/services/registry_path_scanner.dart` | FFI 只读注册表路径扫描（advapi32，失败静默降级返回空报告） |
| `test/services/game_move_service_test.dart` | 迁移引擎单测（含回滚/取消/PARTIAL 路径） |

### 修改

| 文件 | 改动 | 风险级 |
|------|------|--------|
| `lib/widgets/game_detail_dialog.dart` | move 流程改调 service；删 `_copyDirectory`；新增进度对话框 + 结果页 + 守卫提示 | 🟡 巨型文件（4810 行），局部修改 |
| `lib/services/local_game_registry.dart` | 新增迁移收尾聚合方法（紧跟 relink 之后）；**不动** updateGameLocation/relinkGameLocation 本体 | 🟡 数据核心 |
| `lib/services/magpie_service.dart` | 新增 `updateRegistryPaths()` 公开方法 | 🟡 |
| `lib/services/save_backup_service.dart` | 新增 `rewriteOriginalPathsPrefix()` | ⚪ |
| `lib/services/interrupt_cleanup.dart` | 启动检测迁移登记残留 | ⚪ |

### 一期明确不碰

| 范围 | 理由 |
|------|------|
| `pubspec.yaml` | 零新增依赖（用户拍板） |
| `windows/runner/`、`lib/main.dart`、`main_container.dart`、`lib/theme/`、`app_state.dart` | 稳定区；FFI 在 Dart 层解决 |
| `lib/big_picture/`、`game_detail_page.dart`、`home_page.dart`、`library_page.dart` | 无移动入口；`_silentRefresh` 链路复用无需改 |
| relink 全链路（`relinkGameLocation` / `_RelinkLocationDialog` / `validateExistingGameLocation`） | 保持不动，且作为 M4 失败修复兜底 |
| `PathValidator` | 目标校验语义（可创建）恰好是 move 需要的，现用 `validateCustomGameLocation` 不变 |
| BPM 探索页直链（big_picture_discover.dart:582）等既存 P0 | 与本任务无关，不顺手修 |

---

## 9. 调用点替换清单

| 批次 | 位置 | 改法 |
|------|------|------|
| P0 | `game_detail_dialog.dart:760-778`（复制段）+ `:820-838`（`_copyDirectory`） | 整段替换为 `GameMoveService.instance.move(...)` + 订阅进度流；`_copyDirectory` 删除（先 grep 证明仅 move 流程调用） |
| P0 | `game_detail_dialog.dart:657-747` `_showMoveLocationDialog` | 前置：运行中守卫（`activeSessionDirs` 查询）；确认框补"将删除原目录"明示；确认后弹进度对话框 |
| P0 | `local_game_registry.dart:879-936` | **不修改本体**；MoveService M4 调用之 |
| P1 | `game_detail_dialog.dart:844-872` `_resyncLauncherConfig` | M4 复用：逻辑下沉至 registry 聚合方法或 dialog 保留原函数由结果流回调调用（执行 AI 按最小改动取舍，报告取舍） |
| P1 | `magpie_service.dart:765-788` | 新增键修正方法；M4 调用 |
| P1 | `save_backup_service.dart:22` | 新增前缀改写；M4 调用 |
| P2 | `interrupt_cleanup.dart` | Phase 4 启动检测接入 |
| P2 | `game_detail_dialog.dart:2626` | 入口行无需改结构；仅 move 分发路径加守卫 |

**非 Widget 易漏路径提醒**：`main.dart:724` / `main_container.dart:341` / `game_launch_service.dart:476` 均消费 directoryPath——它们**不需要改动**（读方，跟随 game.json 即自动跟随），但回归测试必须覆盖启动链路。

---

## 10. 风险登记（P0–P3）

| 级别 | 风险 | 应对 |
|------|------|------|
| **P0** | 清源删错目录 / 误删用户数据 | 四重防护：①确认框明示真实源路径（用户显式批准）；②源路径必须 == `game.directoryPath` 当前值（防并发改写后错位）；③删除前重验目标完整性（文件计数 + 总字节）；④`CleanupUtils` 审计日志。回滚依据用 M1 事务登记，不用时间戳（ADR-008） |
| **P0** | 迁移中应用被杀 → 半成品 + 引用错位 | M1 登记先于任何落盘动作；启动检测提示清理；源目录在 M3 之前永不改动 |
| **P1** | 游戏运行中迁移 → 文件占用失败 | M0 运行中守卫（`activeSessionDirs` + RunningTasksService）；占用失败统一给出"关闭游戏后重试"明确报错 |
| **P1** | 目标盘空间不足 | M0 预检目标卷剩余空间（FFI `GetDiskFreeSpaceExW`，零依赖）≥ 源目录字节数 + 5% 余量 |
| **P1** | 只读/隐藏属性文件 copy 后属性丢失 | Dart `File.copy` 不复制 Windows 属性——记录为已知限制（galgame 实测影响概率低）；M2 对只读属性文件 `setReadOnly` 补偿 |
| **P1** | UI isolate 卡顿（大目录枚举/搬运） | 枚举与搬运全在 isolate；进度经 SendPort/`Isolate.run` 返回值传递；照 IMP-12 教训禁止 UI isolate 同步 IO |
| **P2** | 注册表扫描误报（值含旧路径子串但语义无关） | 只报告不改写，展示完整值内容由用户判断；扫描可选可跳过 |
| **P2** | 超长路径（>260 字符）rename/copy 失败 | 报错带明确指引；不主动启用 \\?\ 前缀改写（风险大于收益），列为已知限制 |
| **P3** | 并发会话/并发任务冲突 | 服务级互斥 + UI 守卫；开工前 `git log` 确认基线（09-12 曾有并发会话提交 8f949d9） |

---

## 11. 验收标准

### 自动验证

- `flutter analyze lib/services/game_move_service.dart lib/services/registry_path_scanner.dart lib/widgets/game_detail_dialog.dart lib/services/local_game_registry.dart lib/services/magpie_service.dart lib/services/save_backup_service.dart lib/services/interrupt_cleanup.dart` → **0 新增 error**（存量 ~565 条 info 基线不动）；
- `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test test/services/game_move_service_test.dart` 全过；全量测试 **458/0 基线不新增失败**（🔴 必须带 env -u 前缀，否则 WebSocket 被代理劫持假失败）;
- `git status --short` 自查：改动仅限 §8 清单文件。

### 真机走查清单

1. **同盘移动**：小体积游戏同盘移动 → 秒级完成、进度正常闪过、**源目录消失**、启动正常、打开目录指向新位置；
2. **跨盘移动**：跨盘移动中等体积游戏（≥1GB）→ 进度条推进、完成后源目录消失、新目录可启动；
3. **移动后引用**：桌面快捷方式仍能启动；开启 Magpie 超分的游戏移动后超分仍生效；启动配置无"自动检测"回退日志；
4. **存档**：本体目录内存档的游戏移动后，存档备份/恢复仍指向新位置；
5. **失败回滚**：迁移中（进度 >30% 时）TaskManager 杀进程 → 重启应用 → 弹"检测到未完成的迁移"提示 → 源目录完好、目标半成品经确认后清理；
6. **取消**：跨盘移动中点取消 → 源完好、目标自建目录被清理、库数据无变化；
7. **运行中守卫**：游戏运行中尝试移动 → 明确提示阻断；
8. **空间预检**：目标盘剩余空间不足 → 确认前即报错；
9. **注册表扫描**：迁移成功页点"扫描旧路径引用" → 报告列表展示（有 Magpie 等已修正项不再出现旧路径）；
10. **relink 回归**：「更换游戏目录」流程不受影响（共用菜单入口正常）。

---

## 12. 给执行 AI 的指令摘要（可直接复制的 prompt）

```
在 D:\CTLIB 实现「游戏目录真迁移」功能。开工前：读 AGENTS.md、SESSION_HANDOFF.md、
docs/DEV/features/move_game_location_implementation_plan.md（本方案，按它执行）、git log 确认基线。

任务：把详情弹窗「移动游戏位置」从"复制+改引用"改为真迁移。
1) 先跑 Phase 0 技术验证四项（方案 §7），任何一项证伪立即停下报告；
2) Phase 1 新增 lib/services/game_move_service.dart（五阶段状态机：M0 校验含运行中守卫
   与磁盘空间、M1 事务登记 data/move_in_progress.json、M2 同卷 Directory.rename /
   跨卷 isolate 流式 copy+逐文件字节校验、M3 校验通过后 CleanupUtils 清源+审计日志、
   M4 引用切换逐项 best-effort、M5 收尾）+ test/services/game_move_service_test.dart；
3) Phase 2 按 §9 清单接线 magpie/save_backup/registry；
4) Phase 3 改 game_detail_dialog.dart move 流程（删 _copyDirectory，:760-778/:820-838），
   新增进度对话框与结果页（含注册表扫描按钮），确认框明示"将删除原目录：<真实路径>"；
5) Phase 4 interrupt_cleanup 启动检测迁移登记残留。

硬约束：零新增 pubspec 依赖；注册表只读扫描不改写；回滚只删 M1 登记过的自建目录；
引用切换失败绝不回滚文件；源路径必须 == game.directoryPath 当前值才允许清源；
不碰稳定区与 relink 全链路；测试命令必须带 env -u HTTP_PROXY -u HTTPS_PROXY
-u http_proxy -u https_proxy 前缀；完成后 analyze（0 新增 error）+ 全量测试（458/0
基线）+ git status 自查 + 更新 DEV_LOG/HANDOFF/本档案 + 单独 commit。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 默认建议 |
|---|------|----------|
| 1 | M4 引用切换中 `_resyncLauncherConfig` 的归属：下沉 service 层（dialog 函数保留薄封装）vs dialog 保留原函数由 MoveService 结果回调触发 | 下沉（可测性好），执行 AI 按最小改动原则取舍后报告 |
| 2 | 目标盘剩余空间预检的 FFI `GetDiskFreeSpaceExW` 若 Phase 0 验证遇阻，是否接受降级为"依赖系统报错（ERROR_DISK_FULL）+ 友好提示" | 接受降级 |
| 3 | 注册表扫描的默认范围（仅 HKCU\Software 全树 vs 含 HKLM Uninstall/App Paths 只读枚举） | 含后者（只读、有上限、可取消，成本低价值高） |

---

## 附：本方案的既有约定依赖

- ADR-007（删除护栏）：清源是"用户显式批准的移动语义"，确认框明示路径 + 审计日志满足其第 3 条要求；
- ADR-008（时间戳不可判归属）：回滚依据 = M1 事务登记（显式登记范式，同 `extract_manager._taskOwnedTempArchives`）；
- IMP-06/08（只删自建产物）、IMP-10/11（服务级互斥 + UI 守卫）、IMP-12（UI isolate 禁同步重 IO）；
- 本方案不推翻任何既有 ADR；若获批实施，建议实施完成后在 DECISIONS.md 追加 ADR-009「迁移类操作的先验证后删除与事务登记约定」。
