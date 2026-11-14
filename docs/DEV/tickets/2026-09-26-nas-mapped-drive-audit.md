# 2026-09-26 · NAS 映射网络驱动器（SMB → 盘符）适配审计与实施方案

> **任务来源**：用户报告——部分 NAS 用户把 SMB 共享映射成本地盘符（如 `Z:`）后
> 把游戏库放在上面，导入环节频繁出现「路径解析错误 / 文件与目录无法识别 /
> 功能启动失败」。
>
> **结论**：现有路径与文件系统逻辑**确实是按「本地磁盘」写死的**，共定位到
> **9 条根因**（N-01…N-09）。**N-01…N-08 当轮修复；N-09（启动期，属稳定区）
> 经用户批准后同日修复** —— 9 条全部落地。
>
> **本轮改动**：新增 1 文件、修改 12 文件、新增单测 26 例。
> `analyze` 改动文件 **0 error**；相关测试套件 **全绿**（详见 §7）。
> ⚠️ **未做真机映射盘走查**（无 NAS 环境），验证场景清单见 §6（含 §6.8 启动期场景）。

---

## 0. 一句话结论

映射网络盘在 Windows 上表现为一个**普通盘符**，但对它的访问有三条与本地盘
**本质不同**的语义，而项目原有代码全部假设了本地盘的语义：

| 本地盘语义 | 映射网络盘实际语义 | 代码里的后果 |
|---|---|---|
| 盘符 = 卷的唯一身份 | 同一共享可以同时是 `Z:` 和 `\\host\share` | 排重/同卷判定失效 |
| 访问失败会抛异常 | 离线时返回 `false` / `0`，不抛异常 | 判定静默降级为「可用」 |
| IO 是微秒级、不弹窗 | 每次往返数百毫秒；离线盘弹系统对话框并阻塞线程 | 「软件未响应」 |

---

## 1. 根因清单

> 严重度：P0 = 导致功能不可用/数据被误清；P1 = 明显异常；P2 = 体验/边界。

| ID | 严重度 | 位置 | 现象 | 为什么在映射盘上失效 | 状态 |
|----|--------|------|------|----------------------|------|
| **N-01** | P0 | `lib/services/path_validator.dart`（旧 `getDiskSpaceInfo` :201） | 目标盘空间显示未知/为 0；安装在下载完成后才失败 | ① 查询前会 `dir.create(recursive:true)` —— 只读 SMB 共享上抛异常 → 整个查询被判「不可用」；② `Z:` 离线时 `GetDiskFreeSpaceExW` 返回 0 → `-1` → `hasEnoughSpace` 对 `-1` **一律放行**，空间校验形同虚设 | ✅ 已修 |
| **N-02** | P0 | `lib/services/game_move_service.dart:586`（旧 `_isSameVolume`/`_volumeRoot`） | 「移动游戏位置」从 UNC 迁到同一共享的映射盘时变成慢速整树 copy + 删源 | 只比较盘符字母；UNC 侧解析为 `null` → **恒判跨卷**。跨卷路径会走 isolate copy + 清源，只读共享上清源还会失败 | ✅ 已修 |
| **N-03** | P0 | `lib/services/local_game_registry.dart:791`（`refreshStaleEntries`） | 断开 NAS 后启动软件 → NAS 上的游戏**从库里消失**；重新连接也不回来 | 网络位置离线时 `exists()` 返回 `false`（不是抛异常），旧逻辑把「false」当作「用户删了」并**移除条目** | ✅ 已修 |
| **N-04** | P0 | `lib/services/watch_folder_service.dart:641/683/298` | 监控文件夹「不工作」；点「添加监控目录」后软件假死 | ① `Directory.watch`（`ReadDirectoryChangesW`）在 SMB 上事件静默丢失；② `existsSync()` 在离线/高延迟盘上**同步阻塞 UI isolate**（健康检查每 5 分钟一次） | ✅ 已修 |
| **N-05** | P1 | `lib/pages/join/utils/game_folder_scanner.dart:552`（`detectLaunchExe`） | 大目录/慢网盘下扫描卡住（「未响应」） | 同步整树 `listSync` + `lengthSync`；虽有 20000 条 / 8 层预算，但 SMB 上**每个条目都是一次网络往返**，条数预算拦不住墙钟时间 | ✅ 已修 |
| **N-06** | P1 | `lib/pages/join/join_controller.dart:1065`（旧 `detectLaunchExe`） | 「0 个程序」（目录名含 `Install Patch` 时）；大目录卡死 | ① `listSync(recursive:true)` **完全无上限**（比 N-05 更严重）；② 排除关键字对**整条路径** `contains` —— 2026-09-13 已在其余四处修过，**此处是漏网的一处** | ✅ 已修 |
| **N-07** | P1 | `lib/utils/path_normalizer.dart:24` | 排重失效（同一游戏被识别两份）；UNC 与盘符混用时判定不一致 | `forCompare` 只统一分隔符/大小写，不统一**卷身份**，`Z:\Games\X` ≠ `\\host\share\Games\X`；`\\?\` 长路径前缀也未剥离 | ✅ 已修 |
| **N-08** | P2 | `lib/services/path_validator.dart:9,32,127` | 深层网络目录被误判「路径过长（超过260字符）」 | UNC 形式天然比等价的盘符形式长；上限按**字符串字符数**卡 260，且不生成 `\\?\` 前缀 | ✅ 已修（本地 260 不变） |
| **N-09** | P2 | `lib/main.dart:50`、`lib/core/path_helper.dart:105`；`lib/services/autostart_service.dart` | （仅在「软件本体装在映射盘上」时）启动期阻塞；开机自启失败 | 锁文件/便携目录探针在 `runApp` 前**同步**写盘；注册表 Run 写入 `Z:\...exe`，开机时盘符尚未映射 | ✅ 已修（用户批准后同日完成，🔴 稳定区） |

### 补充说明（审计中确认的**非问题**，避免重复排查）

- **无盘符/卷枚举代码**：`lib/` 下不存在 `GetLogicalDrives` / `GetDriveType` /
  A–Z 盘符遍历，也没有自绘的「磁盘下拉框」——目录选择全部走系统原生对话框
  （`FilePicker.platform.getDirectoryPath`），由 Windows 自己枚举驱动器。
  因此「盘符与卷枚举」这一类问题在本项目**不存在**，无需适配。
- **导入不复制游戏本体**：导入只登记原目录 + 写本地 `Games/<名>/game.json`，
  不存在「大文件跨盘拷贝」在导入链路上的超时问题（跨盘拷贝只出现在
  「移动游戏位置」，已由 N-02 覆盖）。
- **图片/封面缓存不以本地路径为 key**：`portable_image_cache_manager` 以 URL 为 key，
  `metadata_fetcher` 以「源:游戏名」为 key —— 盘符变化不会导致缓存错乱。
- **`refreshStaleEntries` 的异常分支本来就是对的**（`local_game_registry.dart:807-813`），
  缺的只是「`false` 的情况」（N-03）。

---

## 2. 已实施改动（本轮）

### 新增 `lib/utils/network_path.dart`

网络路径能力的**唯一实现**，供各处复用。全部 Win32 调用失败时返回中性结果
（`false` / `null` / 原路径），即**在非 Windows 或受限环境下等价于「全部按本地盘处理」**。

| API | 作用 |
|-----|------|
| `stripLongPathPrefix` | `\\?\UNC\host\share\x` → `\\host\share\x`；`\\?\C:\x` → `C:\x` |
| `volumeRoot` | `Z:\a` → `Z:\`；`\\host\share\a` → `\\host\share` |
| `isNetwork` | UNC 或映射网络驱动器（`GetDriveTypeW == DRIVE_REMOTE`） |
| `volumeIdentity` / `isSameVolume` | 映射盘盘符经 `WNetGetUniversalNameW`（mpr.dll）解析为 UNC 后比较 |
| `canonicalizeVolume` | 映射盘路径 → UNC 形态；**本地路径恒等** |
| `isVolumeReachableAsync` | 带超时的卷根可达性探测（不阻塞调用方 isolate） |

另：首次使用时会 `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX)`，
**避免访问离线盘时弹出系统「无磁盘」对话框并阻塞线程**（进程级、幂等）。

### 逐文件改动

| 文件 | 改动 | 对应 |
|------|------|------|
| `lib/utils/path_normalizer.dart` | `forCompare` 增加「剥离 `\\?\` 前缀」+「网络盘卷规范化」两步；对本地盘为恒等变换 | N-07 |
| `lib/services/path_validator.dart` | `_resolveVolumeRoot` 改走 `NetworkPath`（支持 UNC 与 `\\?\`）；`getDiskSpaceInfo` 不再盲目 `mkdir`、网络卷不可达时明确 `isAvailable:false` + 可读原因；路径长度上限对网络路径放宽到 1024（本地 260 逐字不变） | N-01 / N-08 |
| `lib/services/game_move_service.dart` | `_isSameVolume` 改走 `NetworkPath.isSameVolume`，删除只认盘符字母的私有 `_volumeRoot` | N-02 |
| `lib/services/local_game_registry.dart` | `refreshStaleEntries`：`exists()==false` 且网络卷根不可达时**保留条目** | N-03 |
| `lib/services/watch_folder_service.dart` | 网络路径**不做** `Directory.watch`，登记为纯轮询（新增 `_pollOnlyPaths`）；`addWatchFolder` 与健康检查中的同步 `existsSync` 去掉/跳过 | N-04 |
| `lib/pages/join/utils/game_folder_scanner.dart` | `detectLaunchExe` 去掉阻塞 `existsSync`；网络路径加 5s 墙钟预算（本地不加） | N-05 |
| `lib/pages/join/join_controller.dart` | `detectLaunchExe` 委托有界实现（同时修掉「整条路径 contains 排除关键字」的漏网 bug） | N-06 |
| `lib/main.dart` 🔴 | 新增 `_usePortableInfraPaths = !isNetwork(dataDir) && isPortableWritableSync`（**先判网络再判可写**，`&&` 短路 → 网络位置永不触发同步写探针）；网络安装的锁文件与启动请求目录一律落系统临时目录；锁目录创建改用实际锁路径的父目录 | N-09 |
| `lib/core/path_helper.dart` 🔴 | `isPortableWritable()` 改为：本地复用同步探针（行为逐字不变）；网络位置走**带 8s 超时的异步写探针**（不阻塞 UI isolate，且能如实返回 false 让便携存储降级）；`ensurePortableDirs` 的 `existsSync` → `await exists()`；同步 getter 加「网络位置勿调用」的显式警告 | N-09 |
| `lib/services/autostart_service.dart` | 软件位于映射盘时把注册表 `Run` 值改写为该共享的 **UNC 等价路径**（不依赖盘符映射）；解析失败沿用原路径 | N-09 |
| `lib/utils/network_path.dart` | 新增 `toUniversalPath`（= `canonicalizeVolume`，用于「需要位置无关形态」的场景，名称表达用途） | N-09 |
| `test/utils/network_path_test.dart` | **新增** 26 例纯逻辑单测（长路径前缀、卷根、卷身份、同卷、`forCompare` 本地语义不变、可达性降级、`toUniversalPath`） | — |

**N-09 的设计取舍（为什么锁路径不放在网络位置）**：单实例锁与启动请求目录是**本机**
的单实例仲裁基础设施，真正需要共享的是数据目录 `data/`。把它们放在网络位置没有收益，
却会让 `main` 顶层求值（`runApp` 之前）触发 SMB 往返 —— 盘离线时同步 IO 阻塞数十秒。
「先判网络」的短路顺序是关键：若先求 `isPortableWritableSync`，短路失效、阻塞照旧。

### 性能影响（回答「不引入性能回退」）

- **本地磁盘路径**：`forCompare` 对本地路径零改写；`canonicalizeVolume` 只做一次
  `GetDriveTypeW`（**按盘符缓存**，会话内至多 26 次）；`detectLaunchExe` 唯一变化是
  省掉一次 `existsSync`（更快）；`watch_folder_service` 本地分支**一行未改**。
- **网络路径**：判重从「恒不相等」变为「正确相等」（减少重复导入 = 减少工作量）；
  同卷移动从「整树 copy」变为「原子 rename」（数量级提升）；扫描增加 5s 上限
  （以「可能少扫到深层 exe」换取「不卡死」，符合本项目「稳定性 > 速度」的取舍）。

---

## 3. 明确不改（及理由）

| 项 | 理由 |
|----|------|
| `lib/pages/join/utils/gal_game_detector.dart` 的同步两层 `listSync` | 它是**有界**的（只扫 depth0/1）且已有 try 兜底；真正的根治是 IMP-12 **批 B（扫描 isolate 化）**，属单独立项，不在本轮 |
| `lib/services/game_data_format.dart` 的 `_normalizeQueueKey` | 只用于写队列串行化；UNC/盘符混用同一目录才会撞车，概率低且后果是「多一把队列锁」而非数据损坏 |
| `lib/services/extract_manager.dart:_isWithinGamesBaseDirectory` 的前缀比较 | 同上，属于「混用形态」下的边界；改动会触及 🔴 2029 行文件的核心分支，收益/风险不划算 |
| 任何「把 `Z:` 自动改写为 UNC 再落盘」的行为 | 落盘必须尊重用户选择（可读性 + 盘符变化时的可恢复性），只在**比较**时做等价 |

---

## 4. 本轮遗留（诚实标注）

1. **⚠️ 未做真机映射盘走查**：开发机无 NAS/SMB 环境。§6 全部场景**均未实测**。
2. **高延迟下仍有残余阻塞**：`GameFolderScanner` / `GalGameDetector` 的扫描仍是
   **同步**的（跑在 UI isolate），本轮只加了「网络路径 5s 墙钟预算」与「去掉多余
   同步调用」。**彻底解决需要 IMP-12 批 B（扫描/富化 isolate 化）**。
3. **网络路径的变更延迟 = 轮询周期**：项目默认 5 分钟（设置页可调 1–60 分钟）。
   NAS 库的「新游戏自动发现」最坏会晚一个周期。这是「SMB 实时事件不可靠」的固有代价。
4. **`\\?\` 长路径不支持**：只做了「剥离前缀以正确比较」与「放宽长度上限」；
   应用**不生成** `\\?\` 前缀，故超过 260 字符的路径在 IO 层仍可能失败，
   届时会得到 `CREATE_FAILED` / `NOT_EXISTS` 的**真实**错误（而不是误报「路径过长」）。
5. `NetworkPath` 的盘符→UNC 解析依赖 `mpr.dll`；若被安全策略拦截会静默退化为
   「按本地盘处理」（不会更糟，只是 UNC/盘符不统一）。

---

## 5. N-09 · 启动期适配（🔴 稳定区，用户批准后已实施）

**问题链**（只有「把 Chrono Tide 装在映射盘上」的用户会遇到；装在本地盘完全不受影响）：
`main.dart` 顶层的 `_lockFilePath` / `_launchRequestDir` 两个 `final` 在 `runApp` **之前**
求值，内部依赖 `PathHelper.isPortableWritableSync` 的**同步**写探针 —— 写的是
`Z:\CTLIB\data`。盘离线时该探针阻塞在 SMB 超时上数十秒 → 「双击图标后长时间无响应」；
`main.dart:301` 的 `await PathHelper.isPortableWritable()` 同样是同步探针（只是被 await），
窗口出现前照样卡住。

**已实施**（4 文件，见 §2 表格）：

1. **锁与启动请求目录不再落网络位置**：`_usePortableInfraPaths` **先判网络再判可写**，
   网络安装一律用系统临时目录。短路顺序是关键——先求 `isPortableWritableSync` 就等于
   没改。
2. **数据落点判定改异步带超时**：`isPortableWritable()` 对网络位置走 8s 超时的异步
   写探针。既不在 UI isolate 上等 SMB，又能在「盘离线 / 共享只读」时**如实**返回
   false，让便携存储正确降级到系统目录（旧实现是先卡数十秒再靠异常降级）。
   本地安装目录的同步分支**逐字未改**。
3. **`ensurePortableDirs` 的 `existsSync` → `await exists()`**：去掉网络位置上的同步往返。
4. **开机自启改记 UNC**：软件在映射盘上时，注册表 `Run` 值改写为该共享的 UNC 等价
   路径（`WNetGetUniversalNameW` 解析），不依赖开机时盘符是否已映射。

**刻意未做**：不把单实例锁改成异步获取、不加「锁失败回退」逻辑。理由：`isPortableWritable`
的同步结果被全应用的数据落点共用，改动它风险外溢；而「网络安装用本机锁」本身语义更正确
（真正共享的是 `data/`，不是锁）。

---

## 6. 验证场景清单（待真机覆盖）

> 前置：准备一台 SMB 服务器（群晖/威联通/Windows 共享均可）与一个共享目录，
> 内含若干 galgame 目录（含中文名、含 `Install Patch` 字样目录、含深层嵌套）。

### 6.1 在线映射盘（基础等价性）—— 目标：与本地盘**行为一致**

| # | 场景 | 预期 |
|---|------|------|
| 1 | 把 `Z:` 加为监控文件夹 → 往 `Z:` 里拷一个新游戏 | 轮询周期内出现在候选队列（日志含 `🌐 网络路径改用轮询监听`） |
| 2 | 手动「添加游戏」→ 从 `Z:` 选目录导入 | 正常识别、正常入库，启动程序 **非空** |
| 3 | 目录名含 `Install Patch` 的游戏从 `Z:` 导入 | 启动管理显示 **≥1 个程序**（回归 N-06） |
| 4 | 启动一个exe在 `Z:` 上的游戏 | 正常启动、计时正常 |
| 5 | 「移动游戏位置」：`Z:\A\x` → `Z:\A\y`（同共享） | **秒级完成**（走 rename），源消失 |
| 6 | 「移动游戏位置」：源 `\\host\share\A\x` → 目标 `Z:\A\y`（同一共享两种写法） | **秒级完成**（判为同卷），日志 `viaRename=true`（回归 N-02） |
| 7 | 「移动游戏位置」：`Z:\A\x` → `Y:\B\y`（不同共享） | 进度条走 copy、校验通过、清源成功 |

### 6.2 离线 / 断连映射盘 —— 目标：**不卡死、不误清、不误删**

| # | 场景 | 预期 |
|---|------|------|
| 8 | 库里有 `Z:` 上的游戏 → 断开 NAS（或 `net use Z: /delete`）→ 重启软件 | 软件**正常启动**；库页 NAS 游戏**仍在**（回归 N-03）；日志 `⏸️ 网络位置暂不可达，保留条目` |
| 9 | 上一步状态下重启后，重新挂载 `Z:`（同一共享） | 游戏可正常启动（条目未被清） |
| 10 | 离线状态下打开「设置 → 安装位置」并选 `Z:` | 提示「网络位置不可访问（未映射 / 已断连 / 无权限）」，**不是**「空间未知」；**不出现系统「无磁盘」对话框**（回归 N-01） |
| 11 | 离线状态下点「添加监控目录」并输入 `Z:\...` | **立刻**报错返回，界面不假死（回归 N-04） |
| 12 | 离线状态下等待 5 分钟健康检查 | 无 UI 冻结（回归 N-04） |
| 13 | 断连瞬间正在轮询扫描 | 该轮扫描静默跳过，UI 不冻结 |

### 6.3 只读共享 —— 目标：**不往用户存储写垃圾、不误判失败**

| # | 场景 | 预期 |
|---|------|------|
| 14 | 把 `Z:\Games` 设为共享的**只读**权限 → 打开安装位置选择 `Z:\Games` | 报「没有写入权限」，且 **`Z:\Games` 下没有多出 `.write_test_*` 残留**（能写则残留应被删除） |
| 15 | 只读共享上点「安装位置空间检查」 | 显示真实剩余空间或明确不可用；**不因盲建目录而报「无法访问」** |
| 16 | 只读共享上的游戏执行「移动游戏位置」 | 明确报错（新位置写入失败），**源目录完好** |

### 6.4 深层目录 / 长路径 —— 目标：**不误报「路径过长」**

| # | 场景 | 预期 |
|---|------|------|
| 17 | 把游戏放在 `Z:\A\B\C\D\E\F\G\H\I\J\...`（总长 300+ 字符） | 不被判「路径过长」；能识别；若 IO 层确实失败，错误应是真实的文件系统错误（回归 N-08） |
| 18 | 用 UNC 直接选深层目录（`\\host\share\...`）做「更换游戏目录」 | 校验通过（网络路径上限 1024） |
| 19 | 同一路径分别以 `Z:\...` 与 `\\host\share\...` 导入同一游戏 | **只入库一份**（不出现重复卡片）（回归 N-07） |
| 20 | 同一路径分别以 `\\?\Z:\...` 与 `Z:\...` 引用 | 视为同一路径（回归 N-07 前缀剥离） |

### 6.5 中文 / 特殊字符 —— 目标：**编码与匹配不受影响**

| # | 场景 | 预期 |
|---|------|------|
| 21 | 游戏目录名与 exe 名为中文（如 `千恋万花`、`汉化版.exe`） | 正常识别与启动；启动程序优先中文版 |
| 22 | 目录名含 `#`、`&`、`+`、空格、`（）`、`～` | 正常识别、正常入库、正常启动 |
| 23 | 目录名含日文汉字但不含「中文/chs」字样 | **不**误判为汉化版（回归既有 bug 语义） |
| 24 | 共享根目录为中文名（如 `\\host\游戏库\`，实际为 SMB 共享名或子目录） | 正常解析卷根、正常读写 |

### 6.6 大文件与高延迟网络 —— 目标：**不卡死**

| # | 场景 | 预期 |
|---|------|------|
| 25 | 共享目录含 500+ 子目录（每个含 20+ 文件）→ 触发扫描 | 扫描期间窗口可交互；`detectLaunchExe` 网络预算生效时日志出现 `⏱️ 网络目录扫描超出 5s 预算`（回归 N-05） |
| 26 | 用限速工具把 SMB 限到 1 MB/s / 高延迟（100ms+） | 扫描变慢但**不冻结**；导入可完成 |
| 27 | 共享内有 >4GB 单文件（游戏 iso） | 体积统计、空间检查正常（不溢出） |
| 28 | 弱网：扫描过程中拔网线 5 秒再插回 | 该轮扫描失败/跳过，下一轮恢复 |
| 29 | `Z:` 上做「移动游戏位置」到另一共享（跨卷 copy），中途拔网线 | 明确失败并**回滚清理目标半成品**，**源目录完好** |
| 30 | 上一步后重启软件 | 若登记文件残留，弹出「检测到未完成的迁移任务」提示 |

### 6.7 与本地盘的一致性回归（防性能回退）

| # | 场景 | 预期 |
|---|------|------|
| 31 | 本地磁盘（`C:`/`D:`）重复 1–7 全部场景 | 行为与改动前**完全一致**，速度不下降 |
| 32 | 本地磁盘导入 200 个游戏（批量） | 耗时与改动前无明显差异（±5% 以内） |
| 33 | 本地磁盘游戏移动（同盘 / 跨盘） | 同盘仍走 rename（秒级）；跨盘仍走 copy + 校验 |
| 34 | 本地监控文件夹的**实时**监听仍生效 | 存入文件后**秒级**出现候选（未被降级为轮询） |

### 6.8 启动期（软件本体装在映射盘上）—— N-09

> 前置：把 Chrono Tide 整个目录**拷贝到映射盘** `Z:\CTLIB\` 并从那里启动。

| # | 场景 | 预期 |
|---|------|------|
| 35 | `Z:` **在线**时双击 `Z:\CTLIB\chrono_tide.exe` | 正常启动；可用的便携数据仍读自 `Z:\CTLIB\data\`（prefs / 主题 / 游戏配置） |
| 36 | **断开** `Z:`（`net use Z: /delete`）后双击启动 | **不再长时间无响应**：日志出现「安装目录不可写，便携化降级」，数据落系统目录；窗口正常出现 |
| 37 | 上一步状态下**再启动一次** | 第二次应快速退出并把「显示窗口」请求交给已运行实例（单实例锁生效，走系统临时目录的锁） |
| 38 | 重新挂载 `Z:` 后重启软件 | prefs / 主题 / 游戏配置从 `Z:\CTLIB\data\` 恢复（未被前一次的降级写坏） |
| 39 | 从 `Z:` 启动 → 设置里开启「开机自启」 | 注册表 `HKCU\...\Run` 的 `ChronoTide` 值应为 **UNC 路径**（`\\host\share\...\chrono_tide.exe" --silent`），不是 `Z:\...` |
| 40 | 上一步后重启电脑（登录时盘符已映射） | 自启成功、静默进托盘 |
| 41 | 把软件装到**只读**位置（如 `C:\Program Files\`）后启动 | 与改动前一致：数据落系统目录，不卡死（回归保护） |
| 42 | 本地盘安装 + 正常启动 | 行为与改动前完全一致（单实例锁仍在 `data\lock\`，双开第二次激活已有窗口） |

---

## 7. 验证记录（本轮实测）

| 项目 | 命令 | 结果 |
|------|------|------|
| 静态分析（N-01…N-08） | `analyze <9 个改动文件>` | **0 error**；29 条 info/warning **全部为存量**（含 `join_controller`/`local_game_registry`/`path_validator` 的既有告警，行号因新增代码而位移） |
| 静态分析（N-09） | `analyze lib/utils/network_path.dart lib/core/path_helper.dart lib/main.dart lib/services/autostart_service.dart test/utils/network_path_test.dart` | **0 error**；6 条 info/warning — 其中 2 条 `unused_import`（`main.dart` 的 `openlist_service`、`autostart_service` 的 `path_helper`）已用 `git show HEAD:` 核对为**存量**（HEAD 版本同样存在），其余 4 条为存量 info |
| 新增单测 | `flutter test test/utils/network_path_test.dart` | **26/26 通过** |
| 受影响套件 | `flutter test test/utils/network_path_test.dart test/smart_import/path_normalizer_test.dart test/services/game_move_service_test.dart test/services/registry_path_scanner_test.dart` | **59/59 通过**（N-09 前，当时新增 23 例） |
| 受影响套件（二） | `flutter test test/utils/network_path_test.dart test/smart_import/watch_folder_service_test.dart test/smart_import/scan_title_dedup_test.dart test/services/exe_scanner_test.dart` | **65/65 通过** |
| core（N-09 相关） | `flutter test test/utils/network_path_test.dart test/core` | **29/29 通过**（含 `portable_prefs_coalesce_test`，验证 `PathHelper` 改动未破坏便携 prefs） |
| 全量（N-01…N-08 后） | `flutter test` | **825 通过 / 0 失败**（9m49s） |
| 全量（N-09 后） | `flutter test` | **846 通过 / 0 失败**（9m28s） |

**未验证**：§6 全部 42 项真机场景（无 NAS 环境）；`Directory.watch` 在具体 SMB
实现上的事件丢失率（仅依据 Windows/Win32 文档与既有工程经验）；
`WNetGetUniversalNameW` 对「已映射但服务器不可达」盘符的返回值（未在真机确认，
解析失败时全部按本地盘语义降级，方向安全）。
