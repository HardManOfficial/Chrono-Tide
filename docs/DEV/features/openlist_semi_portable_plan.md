# OpenList 半移植化：安装包瘦身 + 应用内按需对接

> 状态：✅ 已实施（2026-10-02 客户端 / 2026-10-04 旧内置迁移 / 2026-10-16 自动更新）
> 关联：`local_account_mode.md`（权限矩阵）、`discover_install_and_download_fixes.md`（下载链路）
> 验证：进程内 analyzer 0 error；纯 Dart 端到端探针 54/54 PASS；⚠️ 真机走查待开发者
> 最后更新：2026-10-16（§13 自动更新对接服务；§12 PB 配置通道废弃）

## 1. 背景与决策

OpenList 是官方下载的本地网关（148MB Go 二进制 + data 配置，占安装包体积大头）。
用户产品决策（2026-10-02）：**并非所有账号都必需它**——

- 本地用户：纯本地游戏管理器，与云端下载无关，永远不需要 OpenList；
- 在线用户：部分只用在线功能不下载；部分需要下载。

因此安装包不再内置，改为**半移植**：需要它的用户在应用内一键「对接」，
从官方服务器下载整合包自动装配。

## 2. 对接链路

```
入口 A：用户窗口「对接」按钮（在线态且未对接时显示）
入口 B：探索详情页「获取」→ CloudInstallFlow.submit → 未对接前置拦截
                    │
                    ▼
        OpenListPairDialog（说明 → 确认 → 进度条 → 成功/失败+重试）
                    │ 确认
                    ▼
        OpenListProvision.pair()
          ① 前置检查内置 7z（runtime/tools/7z.exe）
          ② 下载 http://117.72.115.30:8000/openlist.zip（52.7MB）
             → data/tmp/openlist.zip 中转（直连不走代理，失败即清理）
          ③ 7z x -o<runtimeDir> -y（zip 顶层即 openlist/ → 路径吻合；
             -y 全量覆盖 = 重复对接即修复）
          ④ 校验 openlist.exe 存在 → 清理临时包
                    │
                    ▼
        之后 OpenListService.boot 照常工作（_syncConfig 从 PB 同步配置的
        通道原样保留，端口 5244，按需启动+空闲自关）
```

## 3. 关键设计

| 决策 | 结论 |
|---|---|
| 「已对接」判定 | `openlist.exe` 文件存在（`OpenListProvision.isPaired`）——与 boot 文件检查同源，幂等，零新持久化状态 |
| 取消对接 | `submit()` 返回 `cancelled`，桌面与 BPM 两个调用方对该分支本就静默，**零调用方改动** |
| 未对接时的启动防护 | `OpenListService.ensureRunning()` 开头短路（boot 唯一调用方；`getGameDownloadUrl` 经 ensureRunning 天然短路返 null） |
| 本地用户 | 详情页既有 gate（§2.4 权限矩阵）拦住「获取」，到不了下载；用户窗口不显示对接按钮——全程无感 |
| 体积预取 | OpenList 未启动时连接失败 → `FileSizePrefetchService` 返回 null 不阻断（既有容错） |
| iss 安装脚本 | **零改动**：打包 Release 目录产物，源不复制后安装包自然瘦身 |

## 4. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/services/openlist_provision.dart` | **新增**：isPaired/isPairedSync + pair(onProgress, onStage) |
| `lib/widgets/openlist/openlist_pair_dialog.dart` | **新增**：对接窗口（intro/working/done/error 状态机，硬边像素风进度条） |
| `lib/services/cloud_install_flow.dart:60-67` | submit ⓪ 步前置拦截 |
| `lib/services/openlist_service.dart:46-50` | ensureRunning 未对接短路 |
| `lib/widgets/user_profile_modal.dart:52-65,336` | 在线态未对接时第三「对接」按钮；Overlay 快照组件内 setState 自刷新（v1.4 教训） |
| `打包脚本/一键打包.ps1:305-315` | 5.1 OpenList 复制段 → 跳过说明（保留目录骨架+日志清理段，Test-Path 守卫安全）；⚠️ 该目录被 .gitignore 忽略不入库 |

## 5. 真机走查清单（待开发者）

1. 未对接在线用户：详情页点「获取」→ 应弹对接窗 → 对接（观察进度条）→ 完成后继续安装流程正常；
2. 对接中关闭窗口应被阻止（working 阶段无关闭按钮、barrier 不可点）；
3. 用户窗口：在线账号在底部按钮区上方显示小胶囊（未对接「对接」/已对接「更新对接」），本地账户不显示；底栏恒定双按钮（个人设置/登录或退出登录）；
4. 断网/错误 URL 重试路径：对接窗失败态 → 重试；
5. 本地用户：详情页「获取」被登录 gate 拦（既有行为），用户窗口无对接按钮；
6. 重新打包：Release 无 `runtime/openlist`，安装包体积显著下降（约 -148MB）；
7. 未对接时探索库卡片大小列留空（体积预取短路容错，不报错）。

## 6. 更新稳定性（2026-10-02 追加：打包脚本与 iss 修复）

用户需求：**对接后保持稳定，不随更新被改动**（除非新版本本身有意变更）。

审计发现旧内置时代的更新语义会破坏对接，已修三处：

| # | 位置 | 原行为（内置时代） | 修复 |
|---|---|---|---|
| 1 | `ChronoTide_Setup.iss` [InstallDelete] | 更新时删除 `{app}\runtime\openlist\openlist.exe`（"删旧装新"），新包已装不回 → **更新即解除对接** | **删除该行**——exe 视为用户对接资产，更新必须保留；`data/` 由 [Files] Excludes 保护不变 |
| 2 | `一键打包.ps1` 5.1 | 仅"跳过复制" | 升级为**清理 Release 中残留的 `runtime\openlist`**——上一版打包复制进去的残留若不删，会被 iss 打进新安装包/混入便携包（白带 149MB） |
| 3 | `一键打包.ps1` Step 7 校验 | 要求 `Release\runtime\openlist\openlist.exe` 存在，缺失 → `$allPassed=false` → **静默跳过 Inno Setup 装包步骤** | 移除该校验项 |

**更新行为推演（修复后）**：

- 已对接用户（安装包更新）：InstallDelete 不碰 exe → 新包无 openlist 文件 → data/log、data/temp 由 Excludes 保护 → **exe+data 完整保留，更新后直接可用**；
- 已对接用户（便携版）：解压覆盖只覆盖新包内文件，runtime/openlist 不在包内 → 保留；
- 未对接用户：无该目录，更新后照常显示对接入口；
- 卸载：[UninstallDelete] 仅 dirifempty + [Dirs] uninsneveruninstall → openlist 保留，重装后 isPaired=true 直接可用；
- iss 进程清理列表（ProcessList 含 openlist.exe）**保留**——更新/卸载前杀进程与"不删文件"不冲突（不杀进程反而锁文件）。

**边界**：若未来某版本需要**强制升级 OpenList 本体**，需应用内有意识地触发（如版本检查后引导重新对接——pair 的 `-y` 全量覆盖即修复语义），不得再走 InstallDelete 路径。

## 7. 对接入口 v2（2026-10-02 追加：轻量化 + 服务文案 + 多连接下载）

用户四点反馈一次落地（`d1597ab`，3 文件 +261/−57）：

| # | 需求 | 落地 |
|---|---|---|
| 1 | 对接按钮降级为轻量入口 | 底栏第三按钮退役；底部按钮区上方**小胶囊**（`Icons.link` + 文字，高 30、全圆角，靠右对齐「退出登录」正上方），仅在线账号显示（探测中不显示防闪现） |
| 2 | 文案去 OpenList 化 | 弹窗标题「对接服务 / 更新服务」、引导文案「依赖一个本地服务组件」、错误文案不再提 openlist.exe；`runtime/openlist` 路径提示保留（面向愿意手动的用户） |
| 3 | 双态按钮 | 未对接 = 「对接」；已对接 = 「更新对接」→ 弹窗 `isUpdate` 参数切换全套文案（引导语义变为修复/更新） |
| 4 | 下载提速 | `_download` 先发 `Range: bytes=0-0` 探测：**206 → 6 连接分块并行**（每块独立分片 `.p0~.p5` + 单块重试 2 次 + 按偏移合并，进度 150ms 节流）；**200 → 服务器忽略 Range，直接复用该响应单线程兜底**（连接不浪费）。整体失败/合并后统一清理分片 |

**设计说明**：

- 分块并行 = 并发 HTTP 连接（IO 密集），对单连接限速的服务器收益最大；服务器（8000 端口静态服务）若不支持 Range 自动退回单线程，可用性优先；
- 「更新对接」走同一 `pair()`：zip `-y` 全量覆盖即修复/升级语义，与 §6 边界一致（未来强制升级 OpenList 本体 = 服务器换 zip + 用户点更新对接，无需新通道）；
- 用户窗口胶囊布局代价：charge 区与底栏间距 73 → 56，总高仍在 600 内（585）。

## 8. 遗留与边界

- 旧版本升级用户（已内置 openlist/）：`isPaired()` = true，行为与从前完全一致，无感；
- 服务器整合包内容与项目根 `openlist/` 源目录需保持同步（源更新后须重新上传 zip）；
- PB `openlist_configs` 配置同步通道（boot 时 data.zip 拉取）原样保留，未触碰。

## 9. 对接窗口层级修复（2026-10-03 追加：用户窗口遮挡）

**现象**：用户窗口点「对接/更新对接」，对接窗口被用户窗口完全遮挡，须先退出用户窗口。

**根因**：两个浮层不在同一层级体系——用户窗口 = 手动 `Overlay.of(context).insert(entry)`
（`_showAuthOverlay`），追加在 root Overlay 末尾 = 钉顶层，**恒在一切路由之上**（与
09-27 设置窗口 Dropdown 被压是同一物理规律）；对接窗口 = 组件内 `OpenListPairDialog.show`
（`_openPair`）→ showDialog → route 条目被 Navigator 排在钉顶 entry 之下。

**修复**（沿「登录按钮」同款模式：关用户窗口 → 弹窗 → 重开）：

- `user_profile_modal.dart`：新增 `onOpenPair(bool isUpdate)` 回调（组件内探测的对接状态
  传宿主）；未注入时兜底保留原组件内 showDialog 路径。
- `main_container.dart`：`_handleOpenPair(isUpdate)` = `_closeAuthOverlay()` → 延时 250ms
  （AnimatedOverlay 退场 200ms，等 entry 移除）→ `OpenListPairDialog.show` → `finally`
  重开用户窗口。重开实例 `initState` 自动重新探测 `openlist.exe`，对接成功后按钮自动切
  「更新对接」，无需回传结果。
- `_pairInFlight` 守卫：250ms 间隙内 `_showAuthOverlay()` 直接跳过，防用户窗口抢回顶层
  再盖住对接窗口。

**影响面**：官方下载前置拦截入口（CloudInstallFlow，弹出时用户窗口未开）不受影响；
桌面/BPM 同路径受益（BPM 模态本就全 showDialog 同层）。

**验证**：进程内 analyzer 2 文件 errors=0（存量 import 告警与本次无关）；⏳ 真机走查待
开发者（对接/更新对接窗口应在最上层；取消或完成后用户窗口自动重开）。

## 10. 旧内置迁移（2026-10-04 追加：升级清除 + 重新对接）

**需求**：2026-10-02 之前的旧版安装包**硬内置** `runtime/openlist/`（148MB）。
这批用户升级后 `openlist.exe` 仍在 → `isPaired()` 误判「已对接」。产品决策：
**旧内置遗留统一清除，要求走新流程重新对接**（下载 52.7MB 整合包）。

**关键矛盾**：不能在 iss/更新时「统一删」——§6 承诺新流程已对接用户更新时保留，
且旧内置与新 zip 内容同源（§8），文件层面无法区分两类用户。

**方案：文件标记 + 应用侧一次性迁移**（不动 iss / 打包脚本）：

| 组件 | 实现 |
|---|---|
| 标记 | `runtime/openlist/.provisioned`（0 字节，`path_helper.dart:57-61`）——**标记生命周期与资产目录完全一致**（目录删标记消失、目录在标记就在），避免 prefs 类标记「data 丢失但 OpenList 在」的判定错位 |
| 写标记 | `OpenListProvision.pair()` 校验通过后写入（`openlist_provision.dart:104-116`）；写失败不影响对接（下次「更新对接」补写） |
| 迁移 | `OpenListProvision.migrateLegacyIfNeeded()`（`openlist_provision.dart:126-158`）：exe 存在 && 无标记 → `OpenListService.stop()` 杀进程 → `deleteSync(recursive)` 整目录清除 |
| 调用点 | `main_container.dart` initState（`_loadSidebarState()` 后）fire-and-forget，失败只留日志不阻断启动 |

**迁移后行为**：旧内置用户下次启动被清除 → 既有机制自动要求重新对接
（详情页「获取」弹对接窗、用户窗口显示「对接」胶囊、`ensureRunning` 短路）；
重新对接后有标记 → **此后每次更新永久保留**（§6 语义保住）。本地用户（不用
OpenList）顺手少 148MB 死重量，无功能影响。安装器语义不变（InstallDelete 不碰
exe、data/ Excludes 保护），安装包/便携两条更新通道统一由应用侧迁移覆盖。

**实现备注**：migrate 内部用**同步 IO**（`existsSync/deleteSync`）——启动序列
一次性微操作，无并发竞争；同步实现同时免疫 flutter_tester 直跑通道「异步 IO
完成回调永不返回」的怪癖（2026-10-04 实测：`File.exists()` 卡死，与
`ui.Image.toByteData` 同类；探针 `.workbuddy/probe_ol_migrate/`）。

**验证**：探针 5 断言全 PASS（无 exe 不动 / 旧内置整删 / 新流程资产保留×2 /
标记在目录内）；进程内 analyzer 4 文件 errors=0；⏳ 原生 `flutter test
test/services/openlist_provision_migration_test.dart`（新文件，同断言）与真机
走查待环境恢复/开发者——真实 analyze（lint 全量）同样待补。

## 11. 网盘基本路径迁移（2026-10-16 追加：`/quark/GAL` → `/quark/Chrono Tide数据/GM/GAL`）

**背景**：官方夸克网盘目录调整——旧挂载根 `/quark/GAL` **已不存在**（网盘根 27 项中无 GAL），
游戏库整体迁至 `/quark/Chrono Tide数据/GM/GAL`。OpenList 侧真实路径 =
`x_users.base_path`（guest / user）+ 存储 `x_storages`（driver=Quark、mount_path=/quark、
root_folder_id=0）拼接，故**只需更新 data.db 的 base_path 与夸克 cookie，客户端代码零改动**。

**实测（本地 data.db 副本实例，全程只读，未触碰运行目录原件）**：

| 配置 | `POST /api/fs/list {"path":"/"}` | PB 全量 434 条 `downloadUrl` |
|---|---|---|
| 旧（base_path=`/quark/GAL` + 旧 cookie） | ❌ 失败（目录不存在） | — |
| 新（base_path=`/quark/Chrono Tide数据/GM/GAL` + 新 cookie） | ✅ 200，215 项 | **394 OK / 39 FAIL / 1 EMPTY（91.0%）** |

⇒ **配置方向正确且已生效**；旧配置已彻底不可用。剩余 9% 全部是 **PB 记录路径与网盘实际名不一致**，
与配置无关（修正见 `discover_install_and_download_fixes.md` §5）。

**四个必须同步的位置**：

| # | 位置 | 现状（2026-10-16） |
|---|---|---|
| ① | 用户机 `runtime/openlist/data/` | 由「更新对接」（§6）或 PB 通道更新 |
| ② | 服务器 `http://117.72.115.30:8000/openlist.zip` | 🔴 **顶层必须是 `openlist/`**（见下） |
| ③ | PB `openlist_configs.data_zip` 附件 | ✅ 已换定版（顶层 `data/`） |
| ④ | 项目根 `openlist/`（打包源） | ✅ 已同步定版（`data.db` md5 `cd7d3a73`） |

🔴 **踩坑记录**：直接把 **OpenList 官方发行包**上传到 ② 是**错的**——官方 zip 顶层是**扁平**的
`openlist.exe` + `data/`；而 `OpenListProvision.pair()` 解压到 `runtime/` 后要求
`runtime/openlist/openlist.exe`（`PathHelper.openlistExePath`，`path_helper.dart:49`）。
扁平包会解出 `runtime/openlist.exe` + `runtime/data/` ⇒ `isPaired()` 失败 ⇒ 对接报
「解压完成但服务组件不完整」。
**正确打包**：`openlist/` 目录内含 `openlist.exe` + `data/`，再
`7z a -tzip openlist.zip openlist`（顶层即 `openlist/`）。

> ⚠️ **2026-10-16 复核**：线上 ② 的包**仍然是扁平结构**（实测 `size=55460511`、
> md5 `e56267e2682500dde35627f735980f8a`、顶层元素 `['data', 'openlist.exe']`）。
> 客户端侧已由 §13 的**布局归一化**兜住（形态 B），不再报错；但服务器包本身建议
> 仍改回正确结构——否则**老版本客户端**（3.0.6 及以前，无归一化）的「对接」依旧失败。
> 已交付修正包：`.workbuddy/probe_ol_update/out/openlist_fixed.zip`
> （顶层 `openlist/`，内含 `data.db` md5 `cd7d3a73b4317d905ea0346763dc426d`，与 ①③④ 定版一致）。

## 12. `_syncConfig` 的 `data_zip` 数组解析 bug（2026-10-16 修复）

`openlist_service.dart:131` 原实现：

```dart
final zipUrl = data['dataZip'] ?? data['data_zip'] ?? data['zipUrl'] ?? '';
...
String fullZipUrl = zipUrl;   // ← 抛 TypeError
```

PB 的 **file 类型字段实际返回数组**（实测 `data_zip: ["data_4kr3fuwzui.zip"]`），
`List` 赋给 `String` 抛 `TypeError` → 被本方法外层 `catch` 吞掉只留一行日志
⇒ **PB 配置下发通道从未成功过**（这正是本地 cookie 过期后无法自动修复的原因）。

修复：归一化取首元素 —— `zipRaw is List ? (zipRaw.isEmpty ? '' : zipRaw.first.toString())
: (zipRaw?.toString() ?? '')`。

⚠️ **遗留（本次未改，待产品决策）**：`_needsDataExtraction()` 在 `data/` 已存在且
`data.db > 1KB` 时返回 `false` ⇒ 即使通道修好，**存量用户的本地 data 也不会被覆盖**。
存量用户更新配置的**现成手段 = 用户窗口「更新对接」**（`pair()` 的 `-y` 全量覆盖语义）。
若希望配置变更能自动下发，需另行设计「版本化强制刷新」。

> 🔴 **2026-10-16 结论：本节的「修好 PB 通道」路线已被放弃**。
> 既然判定要改成**指纹比对**（而非「文件是否存在」），继续走 PB 附件只会多一跳依赖、
> 多一个失效点。配置包改为与组件包**同源**（服务器静态文件 `data.zip`），通道整体废弃
> ——PB 的 `openlist_configs` 记录与字段**保留不删**，但客户端不再读取。
> 详见 §13。

## 13. 自动更新对接服务（2026-10-16）

**需求**：对接完成后，服务配置与组件不应再依赖用户手动点「更新对接」——应自动跟进
服务器版本。用户批准的执行口径：**两包都自动**（T1 配置热更、T2 组件静默安装）。

### 13.1 数据源切换（架构级）

| # | 包 | 旧数据源 | 新数据源 | 体积 |
|---|---|---|---|---|
| T1 | 配置 `data.zip` | PB `openlist_configs.data_zip` 附件 | **`http://117.72.115.30:8000/data.zip`** | ≈71KB |
| T2 | 组件 `openlist.zip` | 服务器静态文件（不变） | 同左 | ≈53MB |

理由：① PB 通道**从未真正生效**（§12 的 `List→String` TypeError 被外层 catch 吞掉）；
② 改为指纹比对后，「文件是否存在」不再是判据，PB 附件的唯一价值（下发新配置）也可由
静态文件承担；③ 配置与组件同源后**版本口径统一、少一个失效点**。
PB 的 `PBConfig` 本身与 `openlist_configs` 记录**均不动**（不删服务端数据）。

### 13.2 三级版本化

| 层 | 管什么 | 包 | 指纹 | 策略 |
|---|---|---|---|---|
| T1 | `data/{config.json,data.db}` | `data.zip`（≈71KB） | HEAD `ETag` | 静默自动；**服务在跑则挂起**，停服后补 |
| T2 | `{openlist.exe,data/}` | `openlist.zip`（≈53MB） | HEAD `ETag` | 静默自动；**下载完等安全窗口**再换目录 |
| T3 | 包内目录结构 | — | — | 解压后**运行时归一化**（形态 A/B/C） |

指纹 = `HEAD` 响应的 `etag`；服务器无 ETag 时退化用 `last-modified`；两者皆无则该次
探测跳过（不算失败）。实测线上 simple-http-server 两类头**都完整提供**，且支持
`Range`（分块下载可继续用）。

### 13.3 架构：纯 Dart 引擎 + 宿主接线层

| 文件 | 角色 | 规模 |
|---|---|---|
| `lib/services/openlist_update_core.dart` | **新增**：纯 Dart 引擎（零 Flutter 依赖），逻辑全在这里 | ~1040 行 |
| `lib/services/openlist_provision.dart` | **重写**为宿主接线层：注入路径 / 日志 / 服务运行态 / 安装忙碌态 / 阶段回调 | ~160 行 |
| `lib/services/openlist_service.dart` | `_syncConfig()` 重写为转调 `ensureConfigFresh()`；**删除 780 行旧逻辑** | 1340 → 486 行 |
| `lib/core/path_helper.dart` | **新增** 3 个 getter（状态文件 / 暂存目录 / 备份目录） | +18 行 |
| `lib/main_container.dart` | 启动后延迟 8s 触发一次探测 + 结果 SnackBar | +25 行 |
| `lib/widgets/user_profile_modal.dart` | 打开窗口即探测 + 对接按钮忙碌态（`ValueListenableBuilder`） | +30 行 |

**为什么要抽成纯 Dart**：本机 `flutter analyze` / `flutter test` 长期被
`CreateFile failed 231` 阻塞，只能靠 `flutter_tester` 探针；而实测 **flutter_tester 下
`Directory.create(recursive: true)` / `Future.delayed` 会永久挂起**（异步 IO 与 Timer
不可靠）⇒ 引擎根本没法在 flutter_tester 里被端到端验证。抽成纯 Dart 后可用
`dart.exe` 直跑探针：**真 HTTP、真异步 IO、真 7z 子进程**全部可用。

对外 API 保持兼容（`isPaired` / `isPairedSync` / `pair` / `checkAndApply` /
`ensureConfigFresh` / `applyPendingConfig` / `packageUrl` / `migrateLegacyIfNeeded`），
故 `openlist_service.dart`、`main_container.dart`、`user_profile_modal.dart`、
`openlist_pair_dialog.dart` 的既有调用点**无需改动**。

### 13.4 触发时机

| 时机 | 调用 | 说明 |
|---|---|---|
| 启动后 8s | `checkAndApply()` | 避开首帧渲染 / 登录 / 首屏网络竞争；fire-and-forget |
| `OpenListService.boot()` 前置 | `ensureConfigFresh()` | 此刻服务必然未运行 → 配置可直接落盘 |
| 打开用户窗口 | `checkAndApply()` | 用户此刻最关心有没有新版（手动入口顺手探测） |
| `OpenListService.stop()` 后 | `applyPendingConfig()` | 补上因「服务在跑」挂起的配置更新（只 71KB，不触发 53MB） |

### 13.5 安全窗口与挂起

- **配置包**：落盘前判 `isServiceRunning()`。运行中 → 写 `pendingConfig` 记账并返回
  `deferred`，等 `stop()` 后由 `applyPendingConfig()` 补上（否则覆盖中的 `data.db`
  会被正在运行的 OpenList 写回，形成竞争）。
- **组件包**：先下载 + 解压 + 归一化到 `runtime/.openlist_staging/openlist`，**再**判
  `!isServiceRunning() && !GlobalInstallCenter.instance.isBusy` 才做整目录替换。
  不满足则保留暂存包，下次探测**直接复用**（不重复下 53MB）。
- **手动对接（`pair()`）**：用户明确要求 → `force = true`，不等安全窗口。

### 13.6 失败退避

连续失败按 `15min → 1h → 6h` 递增（成功即清零，写 `lastCheckAt`）。离线时不会空转刷日志。
`checkAndApply` 另有一层 `_busy` 单例锁：并发调用直接返回 `skipped: '已在检查中'`。

**未对接 → 直接跳过**（`skipped: '未对接，跳过自动更新'`）：53MB 组件的下载必须由用户在
「对接」弹窗里明确同意，不能替他决定；此时也没有 `openlist/` 可言，提前落配置只会留下
孤立目录。对接后的首次配置同步由 `boot() → ensureConfigFresh()` 完成。

### 13.7 布局归一化（T3）

线上 `openlist.zip` 实测为**扁平结构**（顶层 `openlist.exe` + `data/`，见 §11 复核），
直接解压到 `runtime/` 会得到 `runtime/openlist.exe` ⇒ `isPaired()` 失败。
`normalizeComponentLayout(stagingPath)` 把任意解压形态整理成
`stagingPath/openlist/{openlist.exe,data/}`：

| 形态 | 解压结果 | 处理 |
|---|---|---|
| A | `openlist/openlist.exe` + `openlist/data/` | 正确，直通 |
| B | `openlist.exe` + `data/`（扁平） | 自动包进 `openlist/` |
| C | `openlist/openlist/openlist.exe` | 自动展平一层 |
| 未知 | 其他 | 返回 `null`，**不移动任何文件**（安全兜底 → 本次更新放弃） |

⚠️ 形态 C 的判定**不能**嵌在「`inner` 含 exe」分支内——形态 C 下 `staging/openlist`
本身不含 exe，exe 在再下一层；已踩过此坑（探针 S1 抓到）。

### 13.8 记账与标记（两个文件，职责分离）

| 文件 | 位置 | 职责 |
|---|---|---|
| `.provisioned` | `runtime/openlist/` **内** | 对接归属（§10）；生命周期随资产目录 |
| `.openlist_state.json` | `runtime/` **下** | 已应用指纹 + pending + 失败退避 |

🔴 **状态文件必须在 `runtime/` 而不是 `runtime/openlist/` 内**：组件更新是「整目录替换」
（`openlist` → `.openlist_backup` → 新目录改名过去），放在里面的记账会在每次更新后丢失
⇒ 「已应用版本」永远记不住 ⇒ 无限重复更新。

🔴 **组件切换后必须补写 `.provisioned`**：整合包内不含该标记，若不补写，
`migrateLegacyIfNeeded()`（§10）会把刚装好的新目录当「旧内置遗留」**整删**。

### 13.9 明确不做

- 不动 `update_service.dart`（应用自身更新）与 `PBConfig` 本身；
- 不删服务端 PB 数据（`openlist_configs` 记录 / 字段保留）；
- 不新增设置开关（自动更新恒开；失败只留日志 + 退避，不弹窗）；
- 不动 OpenList 自身逻辑与端口（5244）；
- 保留 `pair()` 作为手动兜底。

### 13.10 验证

| 手段 | 结果 |
|---|---|
| 进程内分析器（绕 231） | `openlist_update_core.dart` / `openlist_provision.dart` / `path_helper.dart` **0 error 0 warning**；`openlist_service.dart` 0 error（`_readCredentials` 未引用为存量 info） |
| 纯 Dart 端到端探针 | **54/54 PASS**（`.workbuddy/probe_ol_update/probe_dart.dart`，日志 `probe_dart.txt`） |

探针覆盖（`dart.exe` 直跑，真 HTTP + 真 7z 子进程）：

| # | 场景 | 关键断言 |
|---|---|---|
| S0 | 沙盒路径布局 | 状态/暂存在 `runtime/` 下、与 `openlist/` 同父目录（rename 必成） |
| S1 | 布局归一化 | 形态 A/B/C 各自正确 + 未知形态**不动文件** |
| S2 | 未对接 | 跳过且**不创建** `runtime/openlist` |
| S3 | 只检测模式 | 配置已应用 / 探到组件新版 / **未下载 53MB**（无暂存目录）+ 指纹幂等 |
| S4 | 无 ETag 服务器 | 退化用 Last-Modified 当指纹，跨次稳定不重复应用 |
| S5 | 组件切换 | 复用暂存包（未下载）、整目录替换、**`.provisioned` 已补写**、暂存/备份清理 |
| S6 | 失败退避 | 连不上 → `problem` 非空 + 写 `nextRetryAt` + 立即重试被跳闸 |
| S7 | 阶段复位 | 结束时 phase 回 `idle`（按钮忙碌态不卡住） |
| S8 | 配置挂起 | 服务在跑 → `deferred` + 写 `pendingConfig`；停服后 `applyPendingConfig` 补上并清 pending |
| S9 | 手动 `pair()` 端到端 | 分块下载 + 真实 7z 解压 + 归一化 + 切换 + 标记 + 清理 + 阶段回调 ≥3 次 |
| S10 | **形态 B 扁平包端到端** | 复现线上真实形态：安装成功、顶层**无**残留 `openlist.exe`/`data/`、标记已补写 |

### 13.11 真机走查清单（待开发者）

1. 已对接用户启动 → 8s 后应无打扰；若服务器换了配置包，应弹一条「服务配置已自动更新」；
2. 服务器换组件包 → 下次启动/打开用户窗口应弹「服务组件已自动更新」，且 `runtime/openlist/`
   内 exe 时间戳更新、`runtime/.openlist_state.json` 记下新指纹；
3. 下载组件期间点「更新对接」按钮 → 应显示转圈忙碌态、不可点击；
4. 服务运行中触发配置更新 → 日志出现「配置更新挂起」；等 OpenList 空闲自关后应自动补上；
5. 断网启动 → 不弹任何东西，日志有退避记录，`nextRetryAt` 写入；
6. 未对接用户 → 启动**不应**产生任何 `runtime/openlist` 目录、不下载任何东西。

### 13.12 服务端配套（✅ 已完成，2026-10-16）

线上 `http://117.72.115.30:8000/openlist.zip` 原为**扁平结构**（§11 复核），已由开发者
重传为正确结构并通过验收。

🔴 **上传件必须精确命名为 `openlist.zip`** —— 客户端下载地址硬编码
`$serverBase/openlist.zip`，名字不对（如 `openlist_fixed.zip`）会直接 404。
交付件已改名放在 `C:\Users\SteinsGate\Desktop\openlist.zip`
（同一字节的另一份在 `.workbuddy/probe_ol_update/out/openlist_fixed.zip`）。

### 13.13 线上验收结果（2026-10-16 18:0x，只读验证）

| 校验项 | 线上实测 | 判定 |
|---|---|---|
| `openlist.zip` content-length | 53529508 | ✅ 新包（旧 55460511） |
| `openlist.zip` etag | `W/"330cba4-6ad1df98.0"` | ✅ 已变（旧 `W/"34e429f-6ad1aa7d.0"`） |
| `openlist.zip` 顶层元素 | `['openlist']` | ✅ 结构正确 |
| `openlist.zip` 8 个条目 CRC/size | 与本地定版**逐条全等** | ✅ 同一份字节 |
| `data.zip` 整包 md5 | `bfa02a9ff1dcb05c08afbb8e3c2bbb1e` | ✅ 定版 |
| `data.zip` 内 `data.db` md5 | `cd7d3a73b4317d905ea0346763dc426d` | ✅ 定版 |

🔑 **附带确认**：`data.zip` 内 `config.json`（2846B, crc `53e671b8`）、`data.db`
（73728B, crc `e24d6185`）、`log/log.log`（697275B, crc `8623d3f9`）的 CRC
与组件包 `openlist/data/` 下**同名条目完全相同** ⇒ 配置热更覆盖后的内容与组件包
自带的一致，**不存在「热更把配置改坏」的风险**。

**验收脚本（只读，可复用，须用 system Python313 跑）**：
- `.workbuddy/probe_ol_update/verify_remote_pkg.py` —— HEAD 取三元组 +
  一次 Range 抓尾部 64KB → 解析 ZIP **中央目录** → 列出线上全部条目并与本地
  定版逐条比 CRC。**无需下载 53MB**，几秒完成；
- `.workbuddy/probe_ol_update/verify_remote_datazip.py` —— 71KB 全量 md5 +
  内部条目 CRC。

⏭️ 客户端改动需**重新构建 exe** 才能做 §13.11 真机走查（构建前确认磁盘余量）。

---

## 14. 版本升级对齐（2026-10-18：修「更新完仍然取不到下载链接」）

### 14.1 现象与真正的根因

3.1.2 打包发布后，老用户更新到最新版，**下载服务仍然不可用**（点下载拿不到链接）。
最初判断是「安装包不内置 OpenList，所以更新带不上它」——这只说对了一半。

真正的根因是**判据把自己锁死了**：所有自动机制的**唯一前提**都是
`runtime/openlist/openlist.exe` 存在，一旦不成立，三层同时静默短路：

| 位置 | 判据 | 不满足时 |
|---|---|---|
| `openlist_service.dart:44` `ensureRunning()` | `!isPaired()` | 直接 return，**服务不启动** |
| `openlist_update_core.dart:221`（旧） `checkAndApply()` | `!isPaired()` | `skipped`，**既不下组件也不同步配置** |
| `ensureConfigFresh()` | 只被 `boot()` 调用，而 `boot()` 只被 `ensureRunning()` 调用 | 进不去 |

调用链：用户点下载 → `getGameDownloadUrl()`（`openlist_service.dart:355`）
→ `ensureRunning()` → 返回 `null` →「获取不了链接」。

**老用户为什么会缺 exe**：安装包不内置只是其一；更硬的原因是 §10 的
`migrateLegacyIfNeeded()` ——「有 `openlist.exe` 但无 `.provisioned` ⇒ 整目录
`deleteSync`」。标记一旦丢失（换机 / 手动搬 `runtime/` / 旧内置残留 / 异常中断），
服务被清空，而**补回来的前提正是「exe 存在」** ⇒ 永久损坏。
3.1.2 又是老用户第一次跑到自动更新代码的版本，但他们在门口就被挡住了。

### 14.2 判据：从「已对接」放宽为「有痕迹」

新增 `OpenListUpdateCore.hasProvisionTrace()`，**五条判据任一命中**即视为
「这台机器曾经有过 OpenList」（不要求可运行）：

1. `runtime/openlist/` 目录存在（哪怕空 / 不完整）；
2. 扁平遗留 `runtime/openlist.exe`（形态 B 解压残留）；
3. 扁平遗留 `runtime/data/data.db`（`runtime/` 下只有 OpenList 会用 `data/`）；
4. `.provisioned` 对接标记；
5. 状态文件里曾有成功的 `component` / `config` 记录。

全部不命中 = **真·从未对接** ⇒ 一律不下载、不动盘（产品决策：53MB 必须由用户
在「对接」弹窗里明确同意）。

配套新增 `isInstallSound()`：`openlist.exe` + `data/data.db` + `data/config.json`
三者齐全才算健全 —— 用来识别「exe 在、data 丢了」的半残状态（服务起得来、
界面正常，但所有取链接请求都失败）。

### 14.3 升级事件与「智能对齐」

- **升级识别**：`.openlist_state.json` 新增 `appVersion` 字段，与
  `PackageInfo.version` 不等 ⇒ 本次是版本升级。状态文件不存在但痕迹命中
  （老用户首次跑新代码）同样进对齐。
- **智能对齐**（不做无谓流量）：本地健全且指纹与服务器一致 → 不下载，只记账；
  缺失 / 损坏 / 指纹不符 → 拉组件包覆盖。
- **不受退避闸约束**：旧版本留下的 `nextRetryAt` 不能挡住升级对齐，否则
  「升级到修复版」反而因为上次失败而不动作。
- **失败不记账版本号**：只有完全成功才写 `appVersion`，失败保持旧值 ⇒ 下次
  启动会再次进入对齐。
- **扁平遗留清理**：组件切换成功后清掉 `runtime/openlist.exe` 与
  `runtime/data/`（后者必须内含 `data.db` 才认作残留），避免「痕迹」永久命中
  和旧 exe 被误用。
- 🔴 **组件先于配置**：组件是**整目录替换**，会把 `data/` 里刚落盘的
  `config.json` 一起换掉。若先落配置再换组件，切换后 `isInstallSound()` 因缺
  `config.json` 判为不健全 ⇒ 下次启动又「强制重装」⇒ **每次启动白下 53MB 的
  死循环**。因此 `checkAndApply` 调整为 **T2 组件在前、T1 配置在后**，并在组件
  真的换过时清掉配置指纹、强制重新落盘一次（只多 71KB），保证「组件包内配置」
  与「服务器下发配置」口径一致。（2026-10-18 探针 S12 实测复现并修正。）

### 14.4 🔴 已知边界（无法用代码消除）

已被 3.1.2 的 `migrateLegacyIfNeeded()` **清空过**、且从没跑过自动更新
（所以没有状态文件）的用户，磁盘上**一点痕迹都不剩** ⇒ 会被判为「从未对接」
⇒ 不自动装 ⇒ 升级后仍需**手动点一次「对接」**。

可选的未来补法（本次未做）：在偏好里落一个「曾成功用过 OpenList」标记，
从本版起写入 —— 对已清空的存量用户无效，只能防未来。

### 14.5 改动清单

| 文件 | 改动 |
|---|---|
| `lib/services/openlist_update_core.dart` | 新增 `currentAppVersion` 注入、`hasProvisionTrace(+Sync)`、`isInstallSound()`、`reconcileOnUpgrade()`、`_cleanFlatLegacy()`；`checkAndApply` 加 `upgradeAlign`（跳过退避闸 + 完整性校验）、判据改「已对接 or 有痕迹」、成功才写 `appVersion` |
| `lib/services/openlist_provision.dart` | 新增 `primeAppVersion()` / `appVersion` / `reconcileOnUpgrade()` / `hasProvisionTrace(+Sync)` / `isInstallSound()` / `ensureReadyForUse()`；core 单例注入版本；**`migrateLegacyIfNeeded()` 语义反转：补标记保留，不再整目录删除** |
| `lib/services/openlist_service.dart` | `ensureRunning()` 未对接时先 `ensureReadyForUse()`（有痕迹则现场补齐），不再是「直接 return」 |
| `lib/main_container.dart` | 启动后 **1.5s** 触发 `reconcileOnUpgrade()`（纯本地判定，零网络）；保留 8s 的常规 `checkAndApply()` |

### 14.6 验证

- 进程内分析器：4 文件 **0 error / 0 warning**（`_readCredentials` 未引用为存量）。
- 纯 Dart 端到端探针 `.workbuddy/probe_ol_update/probe_dart.dart`：
  **61 PASS / 0 FAIL / 2 SKIP**。新增 S11~S15：
  | 用例 | 验证什么 |
  |---|---|
  | S11 | 有痕迹但 exe 丢失 → 自动重建组件并记账新版本号 |
  | S12 | 已完整且指纹一致 → **不重复下载**（智能对齐） |
  | S13 | 扁平遗留 `openlist.exe` + `data/` → 装新版本后被清理 |
  | S14 | 无痕迹 → **零下载、零落盘**，只记账版本号 |
  | S15 | 升级对齐**跳过退避闸**（旧版遗留的 nextRetryAt 挡不住） |
- 🔴 探针本轮抓到一个真实隐患并已修：**T1/T2 顺序**导致组件替换冲掉
  `config.json` ⇒ 会陷入「每次启动强制重装 53MB」死循环（S12 复现）。
- ⚠️ 本机 2026-10-18 再次发作 231（ERROR_PIPE_BUSY）⇒ 7z 子进程完全不可用，
  S9/S10（下载+解压）被标记 **SKIP**（该链路 2026-10-16 已端到端验证过、本次
  未改动），S11~S15 改用「预置暂存包」覆盖判据层与切换层。

### 14.7 真机走查（3.1.3）

1. 3.1.2 老用户（有 `runtime/openlist`）升级 3.1.3 → 首次启动 1.5s 后应
   自动补齐并弹一条「下载服务已随版本更新同步就绪」；
2. 组件被删到只剩 `data/data.db` 的老用户 → 同上，`openlist.exe` 被重建；
3. 真·未对接用户 → 启动不产生任何 `runtime/openlist`、不下载任何东西；
4. 已有最新组件且完整 → 不动盘、不下载，只在 state 里记下新版本号；
5. 断网升级 → 无弹窗，失败不写 `appVersion` ⇒ 下次启动重试；
6. 旧 `.provisioned` 丢失的用户 → 启动日志出现「已补写 .provisioned，
   纳入自动对齐」，**不再出现「旧内置 OpenList 已清除」**。
