# 游戏数据保存（存储状态）实现方案

> **文件定位**：本文件是给执行 AI（Trae / 其他）的**开发说明书**，不是已完成记录。
> **研究日期**：2026-10-02　**研究方式**：只读审计（未改任何业务代码）
> **Phase 0 状态**：✅ **已完成并通过**（2026-10-02）→ 报告
> `docs/DEV/features/game_storage_state_phase0_report.md`（**三项必改见其 §1.3**）
> **决策来源**：开发者口述需求 + 四轮决策问答（见 §0.3）
> **参考项目**：`D:\CTLIB\其他开发者的项目用于本项目参考\LunaBox-main`（云端备份设计借鉴）

---

## 0. 结论摘要

### 0.1 一句话结论

**这不是从零造功能，而是「接线 + 补三块空白」。** 存档定位/提取/还原、解压调度、7z 二进制、游戏重新定位、磁盘预检——项目里全都有；缺的只有三样：**压缩**（7z 只被当解压器用）、**归档服务**（谁把数据打包、放哪、怎么还原）、**状态机**（`game.json` 里没有任何字段能表达"这游戏被封装/打包了"）。

### 0.2 关键结论表

| # | 结论 | 证据 |
|---|---|---|
| 1 | 「存档备份」已有**定位→提取→落地→还原**闭环，但**落地是 `File.copy` 纯复制，全仓零压缩** | `lib/services/save_backup_service.dart:467-474` |
| 2 | **7z.exe 已随包内置**（821KB，`windows/runner/tools/7z.exe` → 运行时 `runtime/tools/7z.exe`），解压侧已用 `-bsp1` 解析进度 ⇒ **压缩可零新依赖复用整套基建** | `lib/core/path_helper.dart:57`；`lib/services/extract_manager.dart:1302` |
| 3 | `game.json` 的 `format_version` 实际是 **4**（不是文档里写的 3），迁移链已含 V3→V4 | `lib/services/game_data_format.dart:36`、`:46-51` |
| 4 | `game.json` **没有任何字段**能表达「是否封装/打包/本体是否存在」，一切靠运行时磁盘探测 | 全字段清单见 `lib/services/game_data_format.dart:1596-1656` |
| 5 | 软件**目前不认「本体丢失」**：卡片照常显示、无灰化无角标，双击才失败并弹 exe 选择器，且**不自动清理记录** | `lib/pages/library_page.dart:3992-4047`；`lib/services/local_game_registry.dart:1037-1051` |
| 6 | 🔴 **`.ctgame` 是游戏在库的识别标记** —— 归档时若把元数据目录一起删掉，卡片会从库里**静默消失**（连带 play_time / 会话记录） | `lib/services/local_game_registry.dart:882-920`、`:1037-1051` |
| 7 | ✅ 「重新定位游戏本体」**已有现成能力**，解封可直接复用 | `lib/services/local_game_registry.dart:1399-1505`；对话框 `lib/widgets/game_detail_dialog.dart:623-678` |
| 8 | 云备份**当前是零**：PB 文件字段默认上限 **5MB**、`game_resources` 只存外链文本、OpenList 只被用来**下载** | `lib/services/game_resource_service.dart:130`；`lib/services/openlist_service.dart:1198` |
| 9 | ✅ **OpenList 服务端支持上传**（`PUT /api/fs/put` 流式 / `/api/fs/form` 表单，支持 `As-Task` 异步任务与 `X-File-Sha256` 校验）⚠️ *原结论「二期云备份不需要自己写 Provider」已随 Q10 作废（2026-10-03：OpenList 改按需对接，不再作为云备份通道）* | OpenList 官方 HTTP API 文档 |
| 10 | LunaBox 的云备份是**自己写 3 个 Provider**（S3 / OneDrive / Umbra），**未内嵌 rclone**，压缩用 Go 标准库 ZIP | `LunaBox-main/internal/service/cloudprovider/factory.go:20-24`；`internal/utils/archiveutils/archive_zip.go:13` |

### 0.3 四轮决策已定（开发者确认）

| # | 决策点 | 结论 |
|---|---|---|
| 1 | 一期范围 | **本地三态闭环**（封装 / 打包 + 解封解包），云备份留二期，但数据模型与 UI 位置预留 |
| 2 | 云通道 | **用户自己对接网盘**（仿 LunaBox 模式）。技术路径**走已内置的 OpenList 做聚合层**，不自造 Provider |
| 3 | 本体删除 | **备份成功 + `7z t` 校验归档 + 二次确认（明示真实绝对路径）后才删**，且**移入回收站而非永久删除** |
| 4 | 归档落点 | **用户可配置的「归档库」目录**（默认 app 内，可指向其他盘 / 移动硬盘 / NAS 映射盘） |

### 0.4 2026-10-02 深夜追加（开发者拍板 + Phase 0 实测结论）

| # | 决策点 | 结论 |
|---|---|---|
| 5 | 详情页按钮文案 | **保持「备份」**，不改为「游戏数据」（§13 Q1 被开发者否决） |
| 6 | 是否升 `format_version` | **不升**，保持 **4**（§13 Q5 采纳建议；纯新增可空字段 + `?? 默认值` 即兼容） |
| 7 | 归档本地是否留副本 | **只存一份**（§13 Q2 采纳建议；本地仅保留让卡片不消失的元数据） |
| 8 | 压缩进度解析 | 🔴 **必须改正则** `^\s*(\d+)\s` → `^\s*(\d+)%`（Phase 0 实测，报告 M1） |
| 9 | 压缩命令形式 | 🔴 用 **cwd + `*`**（`"<srcDir>\*"` 会使归档内多一层目录名前缀） |
| 10 | 分卷 / `-sdel` | **都不用**（分卷：`extract_manager` 不认 `.7z.001`；`-sdel`：会连源目录删光） |
| 11 | 半成品标记 | 🔴 `.partial` 由 **Dart 侧**实现（实测 7z 直接写最终名、无 `.tmp`，报告 M3） |

---

## 1. 背景与目标

### 1.1 要解决的问题

用户把游戏导入 Chrono Tide 并游玩通关后，面临处置困境：**想留数据、想删本体省磁盘**。当前软件只能做"备份一个存档然后用户自己找地方放"，既不压缩、也不帮用户管理本体。

### 1.2 术语统一（🔴 全文必须一致）

开发者已明确统一叫法：

> **「游戏数据」= 软件侧游戏数据（`game.json` + 封面 + 截图 + 统计等）＋ 游戏存档的「提取并压缩后的产物」。**

⚠️ **本方案中「存档」不指游戏本体文件夹里的散装存档文件，而指 `SaveScanner` 定位提取、`SaveBackupService` 落地、并且**（本次新增）**压缩后的存档包。** 读代码时不要混淆。

### 1.3 四种存储状态

| 状态值 | 中文 | 含义 | 本体 | 游戏数据 | 存档 |
|---|---|---|---|---|---|
| `normal` | 正常 | 三件套齐全，可正常游玩 | ✅ | ✅ | ✅ |
| `sealed` | 封装 | 已保存游戏数据，本体可能已被删除，想玩需重新定位本体 | ⚠️可能缺 | ✅ | ✅ |
| `packed` | 打包 | 三件套齐全，但**本体与存档都已压缩**，想玩需先解包 | 已压缩 | ✅ | ✅ |
| `display_only` | 仅展示 | 用户自行删除了本体与存档，软件只剩元数据 | ❌ | ⚠️仅元数据 | ❌ |

### 1.4 状态机

```
                        ┌──────────── ② 解封（重新定位本体 + 还原数据）
                        ▼
   ┌──────────┐  ①封装  ┌──────────┐
   │  normal  │────────▶│  sealed  │
   │  正常    │◀────────│  封装    │
   └──────────┘  ②解封  └──────────┘
        │  ▲
   ③打包│  │④解包
        ▼  │
   ┌──────────┐
   │  packed  │
   │  打包    │
   └──────────┘

   ┌──────────────┐
   │ display_only │  ← 兜底派生态：无归档 && 本体目录不存在
   │   仅展示     │
   └──────────────┘
```

### 1.5 非目标（一期明确不做）

| 不做 | 原因 |
|---|---|
| **云端上传/下载的完整实现** | 开发者已定为二期。一期只做数据模型与 UI 位置的**预留**（见 §7 Phase 5） |
| **为 `display_only` 做专门的保存/恢复流程** | 开发者明确"这个仅展示状态，我们不做研究"。但它仍需作为**兜底派生态**存在（否则状态机有洞），详见 §4.4 |
| **增量备份 / 内容去重 / manifest 差分同步** | LunaBox 的备份功能本身也没做（只有元数据云同步才做 manifest）。一期用「按数量保留 N 份 + latest 指针」即可 |
| **加密归档** | 存档+元数据体量小、社区游戏的"保密"需求弱；7z 支持 `-p` 密码与 `-mhe` 头加密，留作二期可选开关 |
| **BPM 大屏侧的完整状态管理界面** | 项目既有产品决策：BPM 整体走本地纯沉浸，不做云端功能/探索页界面。BPM 侧**只做状态只读展示** |
| **跨设备归档库迁移（换机恢复）** | 依赖云通道，二期随云备份一起做 |

---

## 2. 现状调研

### 2.1 存档链路（本功能的核心依赖）

| 环节 | 现状 | 证据 |
|---|---|---|
| **定位** | `SaveScanner` 三种来源：① Ludusavi manifest 的 `files` 模式 ② 无 manifest 时扫固定子目录名 + `%APPDATA%`/`Documents` 按游戏名匹配 ③ 用户自定义路径 | `save_scanner.dart:186-196`（入口）、`:199-226`（manifest）、`:231-318`（通用模式）、`:404-420`（自定义） |
| **提取** | 产出 `DetectedSaveFile{filePath, size, lastModified, isDirectory, tag}`；目录会递归统计大小 | `save_scanner.dart:7-34`、`:590-631` |
| **压缩** | ❌ **完全没有**。`_copyFileWithDirs` 只做 `File.copy` | `save_backup_service.dart:467-474` |
| **落地** | `Games/<sanitizedGameName>/saves/<时间戳>/`，含 `backup.json` | `save_backup_service.dart:82-85`、`:110-113` |
| **还原** | `restoreSave(gameName, backupId, specificFiles)`，按 `backup.json` 的 files 映射写回原始绝对路径 | `save_backup_service.dart:186-232` |
| **清单结构** | `backup.json`：`id` / `name` / `display_name` / `timestamp`(UTC ISO) / `is_auto_backup` / `file_count` / `total_size` / `files`(相对路径→原始绝对路径) | `save_backup_service.dart:41-67` |
| **自动备份** | 有（游玩累计 ≥ 900 秒触发），**阈值硬编码**，UI 只能看不能关 | `local_game_registry.dart:3013-3017`、`save_backup_service.dart:76` |

### 2.2 已有但未被消费的能力（🔴 本方案的主要抓手）

| 能力 | 位置 | 现状 | 本方案怎么用 |
|---|---|---|---|
| **7z 二进制** | `path_helper.dart:57`（`runtime/tools/7z.exe`） | **只当解压器用**，全仓无 `7z a` 调用 | Phase 0 验证后用于**压缩本体与游戏数据** |
| **7z 进度解析** | `extract_manager.dart:1302` `_parse7zLine` | 绑定在解压流程里 | 抽为公共工具，压缩复用（`-bsp1` 输出格式同构） |
| **解压调度** | `extract_manager.dart:196` `start()`、`:1989` `cancel()`、`:1739` `_cleanupOnFailure` | 只接受 `archivePath` 输入 | **打包态解包直接用**（`start()` 本来就是"归档→目录"） |
| **重新定位本体** | `local_game_registry.dart:1399-1505` `relinkGameLocation` | 已有，入口在详情弹窗目录行下拉 | **解封流程直接复用** |
| **目录校验** | `path_validator.dart:122` `validateExistingGameLocation` | 已有，不建目录、不测写权限 | 解封前置校验 |
| **磁盘空间预检** | `path_validator.dart:212` `getDiskSpaceInfo`；`game_move_service.dart:131` 用 1.05 系数 | 已有成熟范式 | 压缩/解包前预检 |
| **目录体积统计** | `file_size_service.dart:199` `calculateDirectorySize` | 已有，带 prefs 缓存 | 归档前算体积（需 isolate 化，见 §6） |
| **OpenList 客户端** | `openlist_service.dart:39` `ensureRunning()`、`:1058` `_login()`、`:1131` 取 token、`:1013` 端口 5244 | **只用来下载** | ~~二期云备份的传输层~~ → **Q10 修正：云备份改学 LunaBox 直连 Provider（§7 Phase 5），OpenList 不参与** |
| **全局任务进度展示** | `install_center_page.dart` + `global_task_manager.dart` | 已有成熟 UI | 压缩/解包任务挂这里 |

### 2.3 游戏存在性判定（决定了状态机要怎么落地）

| 步骤 | 校验点 | 证据 |
|---|---|---|
| 加载 | `scan()` 遍历 `Games/` 下子目录，**要求存在 `.ctgame`** 才纳入，**不校验 `directory_path`** | `local_game_registry.dart:882-920` |
| 收尾清理 | 仅对"元数据目录名不在本次扫描集合"的项，检查 `Directory(game.directoryPath).exists()`，不在则**从内存移除** | `local_game_registry.dart:1037-1051` |
| 卡片渲染 | `_LibraryCardWidget` **只判封面文件存在**，**无目录存在性判定、无灰化、无角标** | `library_page.dart:3992-4047` |
| 双击启动 | `launch_path` 解析失败 → **弹 exe 选择器**（不是"重新定位"） | `library_page.dart:2593-2620`、`game_launch_service.dart:116-158` |
| 旁路清理 | `refreshStaleEntries()` 真正校验 `directory_path`，但**库页启动链路不调它**（只有 `discover_page` / `game_detail_page` 调） | `local_game_registry.dart:821-874` |

**关键推论**：删掉本体目录 → 卡片仍在（仅展示态的自然形态）；删掉元数据目录 → 卡片静默消失。**所以封装态必须保留元数据目录里的 `.ctgame` 与 `game.json`。**

### 2.4 压缩与云端能力（选型依据）

| 能力 | 现状 | 证据 |
|---|---|---|
| 目录→归档 | ❌ 无通用能力。唯一压缩原语是主题包的 `ZipEncoder().encode`，**全内存 + 硬上限 20MB** | `lib/theme/ct_theme_package.dart:84`、`:42` |
| 归档→目录 | ✅ `ExtractManager` 支持 17 种格式、分卷 RAR、7z 进度/取消 | `extract_manager.dart:698`、`:889`、`:737-777` |
| 压缩产出分卷 | ❌ 无 | 同左（只能识别、不能产出） |
| 中断恢复 | ❌ 无，失败即 `_cleanupOnFailure` 回滚 | `extract_manager.dart:1739` |
| 内容哈希 | ❌ 无（`crypto` 仅是传递依赖，业务代码零引用） | `pubspec.lock:100-108` |
| PB 文件上传 | ⚠️ 仅头像/封面/截图，**默认上限 5MB**（可调 `maxSize`，官方警告大文件会拖垮实例） | `game_publish_service.dart:372-408`；PocketBase 官方文档 |
| `game_resources` | ❌ 只存**外链文本 + 提取码 + 体积自由文本**，不承载文件 | `game_resource_service.dart:130` |
| OpenList 上传 | ⚠️ 客户端未实现，**服务端支持**（`PUT /api/fs/put`、`/api/fs/form`） | 官方 API 文档 |

### 2.5 LunaBox 借鉴要点（只取思路，不抄代码）

> LunaBox 是 Go(Wails) + React，技术栈不同；备份用 Go 标准库 ZIP；**未内嵌 rclone**；云端 Provider 自己写了 3 个（S3 / OneDrive / Umbra）。

| LunaBox 做法 | 证据 | 对 Chrono Tide 的取舍 |
|---|---|---|
| 备份 / 云同步拆成**两条独立产品线** | `internal/service/backup_service.go` vs `cloud_sync_service.go` | ✅ **照搬这个分层**：备份管文件，同步管元数据，不混在一起 |
| 备份内容分**三种粒度**：单游戏存档 / 数据库 / 全量 | `backup_service.go:597`、`:963`、`:1104` | ✅ 我们对应：单游戏「游戏数据」/ 全库元数据 / 全量迁移包（一期只做第一个） |
| **按数量保留 N 份 + `latest` 指针**，无增量无去重 | `backup_service.go:648`、`:939`、`:806` | ✅ 照搬。别一上来做增量 |
| **恢复前先自动备份当前存档**（`pre_restore`） | `backup_service.go:697-705` | ✅ 照搬。这是防"恢复把现有存档冲掉"的关键 |
| DB/全量恢复**延迟到下次启动执行**（文件占用） | `backup_service.go:1382`、`:1496` | ✅ 照搬。我们恢复 `game.json` 时同理 |
| 云端路径用**稳定 UserID 命名空间**隔离 | `backup_crypto.go:9-12` | ⚠️ 二期再定；我们已有 PB 账号体系，不必用"密码 hash 派生 UserID"这种不可重置的设计 |
| 凭据加密（仅 Umbra 用 Windows DPAPI，S3/OneDrive **明文存 JSON**） | `umbra/store_windows.go:163-186`；`appconf/config.go:90-95` | 🔴 **反面教材**：我们若存网盘凭据，必须走 DPAPI / 凭据管理器，**禁止明文落 JSON** |
| UI 流程骨架：启用开关 → 选存储源 → 身份 → 凭据表单 + 测试连接 → 授权 → 配额展示 → 保留数量 | `CloudBackupSettingsPanel.tsx` | ✅ 二期 UI 照这个骨架 |
| 自动备份触发：**应用退出时备份 DB / 游戏退出时备份存档** | `AutoBackupSettingsPanel.tsx` | ✅ 我们已有"游玩 15 分钟自动备份存档"，可加"游戏退出时" |

---

## 3. 技术选型

### 3.1 压缩方案

| 方案 | 结论 | 理由 |
|---|---|---|
| **7z.exe `a` 子命令（选用）** | ✅ **采用** | ① 二进制**已在包内**，零新增依赖 ② 解压侧已有 `-bsp1` 进度解析可复用 ③ 压缩率显著优于 ZIP（游戏本体大量重复资源）④ 支持 `-v` 分卷、`-p` 密码、`-sdel` 压后删源 ⑤ 与项目"外置工具链"风格一致（`bz.exe`/`UnRAR.exe` 同款） |
| `archive` 包（Dart 纯内存 ZIP） | ❌ 淘汰 | 已在 `pubspec.yaml:30`，但**全内存**——主题包用它只有 20MB 上限（`ct_theme_package.dart:42`）。GB 级游戏本体必然 OOM |
| 自写 FFI 接 7z.dll | ❌ 淘汰 | 复杂度远超收益；项目已有稳定的"调 exe + 解析 stdout"范式，没必要引入 FFI 生命周期管理 |
| Windows 自带 `tar.exe`/`Compress-Archive` | ❌ 淘汰 | 压缩率差（ZIP/Deflate）、大目录性能差、PowerShell 有编码坑（项目 `openlist_service.dart:546` 已有踩坑记录） |
| rclone（LunaBox 参考方向） | ❌ 淘汰 | ① LunaBox **自己也没用**（全仓 grep 零命中）② OpenList 已是同类的多网盘聚合层且**已内置**，重复引入没意义 |

**推荐命令行**（✅ 已由 Phase 0 实测校正，见报告 §3）：

```bash
# 游戏本体压缩（平衡档）—— 🔴 用「工作目录 + *」形式，避免归档内多一层源目录名前缀
#   Process.start(exe, ['a','-t7z','-mx=5','-md=64m','-mmt=2','-bsp1','-y', archive, '*'],
#                 workingDirectory: srcDir)
7z a -t7z -mx=5 -md=64m -mmt=2 -bsp1 -y "<out>.7z" *

# 半成品标记：先压到 .partial，7z t 通过后再 rename（7z 不会自己做 → 报告 M3）
7z a -t7z -mx=5 -md=64m -mmt=2 -y "<out>.7z.partial" *

# 极致档（可选；⚠️ 吞吐未实测，且 -mmt=on 会拖满 CPU）
7z a -t7z -m0=lzma2 -mx=9 -md=128m -mfb=273 -ms=on -mmt=2 -bsp1 -y "<out>.7z" *

# 校验（🔴 删除本体前必须执行）—— 实测 129.4MB 仅 0.26s，成本可忽略
7z t "<archive>.7z"
```

⚠️ `-mmt` 建议**限 2 线程**：压缩是 CPU 密集任务，不限线程会把机器拖到无法使用（本项目开发者常在压缩时继续操作软件）。

🔴 **不要用 `-sdel`**：实测（Phase 0 §3.4）它会把源目录**连目录一起删光**（805 → 0 文件）。删除本源应交给 Dart 侧，在 `7z t` 校验通过 + 用户二次确认后移入回收站。

🔴 **不要用 `-v` 分卷**：7z 侧能力正常（`.001` 可自动连接，实测通过），但 `extract_manager.dart:737-779` 的格式表**不识别 `.7z.001`**，会直接无法解压。

⚠️ **进度解析正则必须改**：7z 输出 `  5% 1 + file`（`%` 紧跟数字），现有 `^\s*(\d+)\s` 解析率仅 **1/29** ⇒ 改为 `^\s*(\d+)%`（报告 M1）。

### 3.2 云端方案（二期，本期只做技术预研）

| 方案 | 结论 | 理由 |
|---|---|---|
| **自建 Provider（LunaBox 路线）** | ✅ **采用（2026-10-03 修正）** | 见下方修正说明 |
| ~~OpenList 做聚合层~~ | ❌ **淘汰（2026-10-03 修正）** | 🔴 **原决策前提已失效**：原判定「OpenList 已内置」，但项目已于 2026-10-02 改为**按需对接**（`openlist_provision.dart:8-12`：安装包不再内置 openlist.exe，用户需主动点「对接」才下载 53MB 整合包）。备份功能面向**全体用户**，不能强依赖需要额外对接动作的通道；且备份链路 = 对接 OpenList → 登录 → 挂载网盘 → 回来备份，步骤过长 |
| ~~PB 直存文件~~ | ❌ 淘汰 | 默认上限 5MB，官方明确警告大文件拖垮实例；自建服务器（京东云）磁盘与带宽都要开发者自掏。而且存档包动辄几十~几百 MB |
| 只做本地/NAS | ⚠️ 降级为兜底 | 归档库本身可指向 NAS 映射盘（`network_path.dart` 已有卷可达性探测），云备份另行走 Provider |

> **2026-10-03 修正说明（Q10）**：开发者指出「LunaBox 没有用 OpenList，备份要给所有用户用」，
> 经复核属实。Phase 5 改学 LunaBox 方法（见 §7 Phase 5 重写后的设计）。

---

## 4. 架构设计

### 4.1 分层

```
┌──────────────────────────────────────────────────────────────────┐
│ UI 层                                                             │
│  · 详情窗口左栏「备份」按钮（game_detail_dialog.dart:1560）         │
│  · 游戏数据弹窗（新）  · 库页卡片状态角标（新）  · 设置页「归档库」（新）│
├──────────────────────────────────────────────────────────────────┤
│ 状态机层  GameStorageStateController（新）                          │
│  · 读状态 → 决策可用操作 → 派发任务 → 回写 game.json                 │
├──────────────────────────────────────────────────────────────────┤
│ 归档服务层  GameArchiveService（新）                                │
│  · seal() / unseal() / pack() / unpack() / verify() / listArchives()│
│  · 编排下面三个既有模块，自己不碰文件细节                             │
├───────────────┬────────────────────┬─────────────────────────────┤
│ 存档链路(既有) │ 压缩链路(新+既有)   │ 数据链路(既有)                │
│ SaveScanner    │ 7z.exe 压缩(新)     │ readonly game.json 读写       │
│ SaveBackupSvc  │ ExtractManager(既有)│ LocalGameRegistry             │
│ (需加压缩)     │ _parse7zLine(复用)  │ relinkGameLocation            │
├───────────────┴────────────────────┴─────────────────────────────┤
│ 二期：云传输层 OpenListService.uploadFile()（新）                    │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 归档库目录布局

```
<归档库根目录>/                       ← 用户可配置，默认 PathHelper.exeDir/archives
  <dirNameFromTitle(标题)>/
    latest.json                       ← 指向最新归档的指针（借鉴 LunaBox latest.zip）
    <时间戳>_<state>/                 ← 例：2026-10-02_20-45-11_packed
      meta.json                       ← 归档清单（唯一事实源，见 §4.3）
      appdata.7z                      ← 软件侧游戏数据
      saves.7z                        ← 提取并压缩后的存档
      body.7z                         ← 游戏本体（仅 padded 态存在）
```

### 4.3 归档清单 `meta.json`（建议结构）

```jsonc
{
  "schema": 1,
  "game_id": "e2c1...",             // 稳定主键，跨改名可用
  "title": "原标题",                 // 展示用
  "state": "packed",                // "sealed" | "packed"
  "created_at": "2026-10-02T20:45:11+08:00",
  "app_version": "2.5.3",

  "appdata": {                      // 软件侧游戏数据
    "archive": "appdata.7z",
    "bytes": 1234567,
    "file_count": 42,
    "sha256": "...",
    "root": "Games/<目录名>",         // 归档时的源根（相对 exeDir）
    "excluded": ["saves/"]          // 单独打包的部分，避免双份
  },

  "saves": {                        // 提取并压缩的存档
    "archive": "saves.7z",
    "bytes": 123456,
    "file_count": 12,
    "sha256": "...",
    "entries": [                    // 🔴 还原用：原始绝对路径必须完整保留
      { "path": "C:\\Users\\x\\AppData\\Roaming\\Game\\save.dat", "size": 123456 }
    ]
  },

  "body": {                         // 仅 packed 态
    "archive": "body.7z",
    "bytes": 3_200_000_000,
    "unpacked_bytes": 8_100_000_000,
    "file_count": 1234,
    "sha256": "...",
    "original_dir": "D:\\Games\\xxx",   // 🔴 解包目标默认位置
    "launch_path": "xxx.exe",           // 相对路径
    "volumes": ["body.7z.001"]          // 若使用分卷则列出
  }
}
```

### 4.4 状态判定逻辑（关键设计）

```dart
// 建议实现位置：GameStorageStateController.resolveState(game)
//
// 优先读 game.json 的 storage_state 显式值；
// 显式值不可信时（归档文件被用户手动删了）降级为派生判定。

if (storageState == 'packed') {
  if (archiveDir 存在 && meta.json 可解析 && body.7z 存在) return packed;
  // 归档丢了 → 降级
  return Directory(directoryPath).exists() ? normal : displayOnly;
}
if (storageState == 'sealed') {
  if (archiveDir 存在 && meta.json 可解析) {
    return Directory(directoryPath).exists() ? normal : sealed;
  }
  return Directory(directoryPath).exists() ? normal : displayOnly;
}
// storageState == 'normal' 或缺失
if (!Directory(directoryPath).exists()) return displayOnly;
return normal;
```

⚠️ **`display_only` 是派生态，不写盘**。一旦用户重新定位了本体，它自动回到 `normal`——这正好满足"仅展示不做研究"的要求，同时让状态机没有洞。

### 4.5 各状态下的操作可用性

| 操作 | normal | sealed | packed | display_only |
|---|:---:|:---:|:---:|:---:|
| 打开游戏 | ✅ | ❌（引导重新定位） | ❌（引导解包） | ❌ |
| 打开目录 | ✅ | ⚠️（若本体不存在则打开归档库） | ⚠️ 同左 | ⚠️ |
| **保存游戏数据（封装）** | ✅ | ⚠️（重新封装，覆盖/新增一份） | ➖ | ➖ |
| **打包** | ✅ | ❌ | ❌ | ❌ |
| **解封** | ➖ | ✅ | ➖ | ➖ |
| **解包** | ➖ | ➖ | ✅ | ➖ |
| 重新定位本体 | ✅ | ✅ | ⚠️（仅改 `directory_path`） | ✅ |
| 编辑元数据 | ✅ | ✅ | ✅ | ✅ |
| 删除游戏 | ✅ | ✅ | ✅ | ✅ |

### 4.6 降级策略（每层的失败方向）

| 层 | 失败场景 | 降级行为 | 原则 |
|---|---|---|---|
| 压缩 | 7z.exe 缺失 / 退出码非 0 | **中止归档，回滚已建目录，写审计日志**，明确提示 | 宁可不做，不留半成品 |
| 压缩 | 中途磁盘满 / 用户关机 | 归档目录标记 `.partial`，启动时清理；**绝不删除源** | 源永远最后删 |
| 校验 | `7z t` 失败或文件数不符 | **阻止后续流程**（尤其阻止"删本体"） | 校验不过 = 没备份成功 |
| 还原 | 目标路径不可写 | 提示 + 列出失败清单，成功项保留 | 部分成功要如实告知 |
| 状态 | 归档被用户手动删了 | 派生态降级为 `normal`/`display_only`，卡片如实呈现 | 不猜测，不自动清理 |
| 删除本体 | 路径不在 app storage 内 | **不自动删** → 走二次确认 + 明示绝对路径 + 移回收站 | ADR-007 铁律 |

---

## 5. 数据模型变更

### 5.1 新增字段（`game.json`）

| 字段 | 类型 | 默认值 | 语义 |
|---|---|---|---|
| `storage_state` | `String` | `"normal"` | `normal` / `sealed` / `packed`（`display_only` **不写盘**） |
| `archive_dir` | `String` | `""` | 当前生效归档目录的**绝对路径**（指向 `<归档库>/<目录名>/<时间戳>_<state>`） |
| `archive_at` | `String` (ISO) | `""` | 归档时间戳 |

> **只存"指针 + 状态"，归档的详细元数据放 `meta.json`。** 理由：① `game.json` 被高频读写，不该塞大结构 ② 归档包要能独立迁移到别的机器，清单必须跟着包走。

### 5.2 是否升版本？（🔴 需要判断）

项目存在两条并行的纪律：

- **ADR-012**（`docs/DEV/DECISIONS.md:405-446`）："字段新增/改名/语义变更时，必须①追加迁移 ②提升 `currentVersion` ③补回归测试"
- **项目既有实践**：新字段优先用 `?? 默认值` 读取，老文件零破坏（`game_data_format.dart:1596-1656`）

**建议：不升版本，仅做读时容错。** 理由：本次是**纯新增可空字段**，旧文件没有这三个键，用 `?? 默认值` 读取即完全兼容；升版本会触发一次全库写回（有 I/O 成本与风险），收益为零。

⚠️ **但必须在文档与代码注释里写清楚这个例外判断**，避免后人误以为漏做迁移。若开发者倾向严格遵守 ADR-012，则改为 `currentVersion: 4 → 5` + 新增 `_migrateV4ToV5`（空变换或补默认值）。

### 5.3 落地位置（精确到行号）

| 文件 | 动作 | 行号 |
|---|---|---|
| `lib/services/game_data_format.dart` | `GameJsonData` 加 3 个 final 字段 + 构造默认值 | `:1449-1586` 区域 |
| 同上 | `fromJson` 加 `?? 默认值` 读取 | `:1596-1656` |
| 同上 | `toJson` 加输出（非默认值时才写，减少 diff 噪声） | `:1658-1700` |
| 同上 | 🔴 **绝对不要**加入 `_overwritableFields` | `:199-234` |
| `lib/services/local_game_registry.dart` | `LibraryGame` 加 3 个字段 | `:221-333` |
| 同上 | `scan()` 两处映射（已存在项 / 新建项） | `:927-970`、`:990-1022` |
| 同上 | 新增 setter（照 `setPlayStatus` 的"内存改 + 原子写 + 失败回滚"模式） | `:547-577` |
| `test/services/` | 补字段解析 + 状态流转回归测试 | 新增文件 |

### 5.4 `_overwritableFields` 陷阱（🔴 P0）

`storage_state` / `archive_dir` / `archive_at` 属于**用户状态**，语义与 `play_status` 同类。若被列入 `_overwritableFields`（`game_data_format.dart:199-234`），**重新导入同一游戏会清掉封装/打包状态**，用户会以为数据丢了。参照同处已有注释："用户累积型字段**不列入**（重复入库保留旧值）"。

### 5.5 归档库路径偏好

| 存储 | key | 默认值 |
|---|---|---|
| 归档库根目录 | `archive_library_path`（SharedPreferences，经 `PortableSharedPreferencesStore`） | `PathHelper.exeDir/archives` |
| 保留份数 | `archive_retention`（int） | `5` |
| 压缩档位 | `archive_compression_level`（`balanced` / `max`） | `balanced` |

---

## 6. 性能预算

| 项 | 目标 | 做法 |
|---|---|---|
| **UI 主线程阻塞** | **恒为 0ms**（硬要求） | 压缩/解包全走 `Process.start` + 流式 stdout，进度经 Stream 回传 |
| 进度回传节流 | ≤ 150ms/次 | 项目已有先例（`openlist_provision.dart` 进度 150ms 节流） |
| 游戏本体大小统计 | 后台 isolate | `calculateDirectorySize`（`file_size_service.dart:199`）是纯遍历，10 万文件可能 10–60s，**不得在 UI 线程跑**；优先读 `file_size_<gameId>` 缓存 |
| 压缩吞吐（参考）✅ **已实测校正** | **5–20 MB/s**（LZMA2 `-mx=5 -mmt=2`）。实测：可压数据 61 MB/s ↔ **随机数据 4.9 MB/s**；真实游戏资源多已压缩 ⇒ 接近下沿 | 8GB 游戏约 **7–28 分钟**；100GB 约 1.5–5.5 小时 —— **必须可取消 + 断点提示**。UI 预计时间建议按 **10 MB/s** 中位值给，宁高勿低（原稿 30–80 MB/s / 2–5 分钟**过于乐观**） |
| 压缩期间 CPU 占用 | ≤ 2 核 | `-mmt=2`。**不要用 `-mmt=on`**，会把机器拖到没法用 |
| 压缩空间预检 | 压缩前必查 | 预估产出 = 源大小 × 0.65，余量 × 1.05（复用 `game_move_service.dart:131` 的范式），不足则拒绝启动并给出精确数字 |
| 解包空间预检 | 解包前必查 | 用 `meta.json.body.unpacked_bytes` 精确值 |
| 归档清单读取 | < 50ms | `meta.json` 只有几 KB，同步读即可；**但 `7z t` 校验是长任务，必须后台** |
| 库页渲染 | 零额外开销 | 状态角标读内存里的 `LibraryGame.storageState`，**不要**在卡片构建期做任何磁盘探测（会毁掉列表滚动性能） |

---

## 7. 实施阶段划分

> 🔴 **Phase 0 必须先做且必须先证伪。** 后面所有设计都建立在"7z 压缩可被现有解压链路无损还原"这个假设上——这个假设**从未被验证过**。

### Phase 0 · 技术验证（产出证据，不改业务代码）　✅ **已完成并通过（2026-10-02）**

> **执行结果见 `docs/DEV/features/game_storage_state_phase0_report.md`。**
> **门禁判定：通过** —— 0.2 往返 **100% 无损**（815/815 文件、0 尺寸/0 内容差异、291 字符长路径全过）；
> 0.1 原假设不成立，但已按方案授权给出新规则（`^\s*(\d+)%`）。
> **三项必改（M1 正则 / M2 吞吐 / M3 `.partial`）已写入报告 §1.3，Phase 1 必须一并落地。**
> 下表保留为**原始验证清单**，各项实测结论以报告为准。

| # | 要验证的假设 | 方法 | 通过标准 |
|---|---|---|---|
| 0.1 | `7z a` 的输出进度与解压侧 `_parse7zLine`（`extract_manager.dart:1302`）**格式同构** | 拿一个 1–2GB 真实游戏目录跑 `7z a ... -bsp1`，抓 stdout 逐行比对 | 能解析出百分比，或明确记录差异并给出新解析规则 |
| 0.2 | 压缩 → `ExtractManager.start()` 解压 → **往返一致** | 对文件数 / 总字节 / 抽样 SHA256 做三方对比 | 完全一致（**必须含中文/日文文件名、长路径 >260 字符、只读文件、0 字节文件**） |
| 0.3 | 大目录（>4GB）与超长路径表现 | 真实 GB 级游戏 + 深层嵌套目录 | 不崩溃、不截断、进度单调递增 |
| 0.4 | `-sdel`（压后删源）是否可安全使用 | 对比手动删除 | 建议**不用 `-sdel`**，由 Dart 侧在 `7z t` 校验通过后自己删（可控性更高） |
| 0.5 | 删除到**回收站**的可行性 | 验证 FFI `SHFileOperationW(FO_DELETE \| FOF_ALLOWUNDO)` 或 PowerShell `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory` | 能进回收站、能还原 |
| 0.6 | 中断/磁盘满的行为 | 压缩中途 kill 进程 / 填满磁盘 | 归档目录可被识别为半成品并清理，**源目录零损伤** |
| 0.7 | 分卷（`-v`）是否需要 | 评估目标网盘单文件上限 | 给出"是否需要分卷"的结论 |

**产出**：`docs/DEV/features/game_storage_state_phase0_report.md`（含实测命令、原始输出、结论、与原设计的偏差）
**纪律**：若 0.1 或 0.2 不通过 → **停下来报告**，重新评估选型（可回退到 ZIP 方案），不得带病进入 Phase 1。

### Phase 1 · 数据模型 + 归档服务（无 UI）　✅ **已完成（2026-10-02）**

> **执行结果见本文件 §16。** 6 个新源码 + 3 个新单测 + 3 处既有文件改动；
> 探针 `dev_probe/phase1_verify.dart` 实跑 **84/84 PASS**；进程内 analyzer errors=0、
> 改动文件新增 warning = 0。**M1 / M2 / M3 已落地，另发现并修掉 M4（7z 输出 GBK 编码）。**
> ⚠️ `flutter test` 与真机走查待开发者补做。
> 下表保留为**原始任务清单**，实际交付以 §16 为准。

- `game.json` 加 3 字段（§5）+ `LibraryGame` 同步 + setter + 回归测试
- 新增 `lib/services/game_archive_service.dart`：`seal()` / `pack()` / `verify()` / `listArchives()` / `restoreAppData()`
- 新增 `lib/services/archive_compressor.dart`：7z 压缩封装（`Process.start` + 进度 Stream + cancel）
- 抽出公共 `SevenZipProgressParser`（从 `extract_manager.dart:1302` 抽，解压侧改为调用它，**行为不变**）
- 归档库路径偏好（§5.5）
- 单测覆盖：状态判定、清单序列化、保留份数清理

### Phase 2 · 「游戏数据」弹窗（封装 / 解封）　✅ **已完成（2026-10-02）**

> **执行结果见本文件 §17。** 抽出 `SaveBackupPanel` + 新增 `GameDataDialog`
> （Tab 1 游戏数据 / Tab 2 存档备份）+ 详情窗口按钮改指向新弹窗；进程内 analyzer
> errors=0、**零新增 warning**（全库 warnings 90→89）。⚠️ 真机走查与 `flutter test`
> 待开发者补做。下表保留为**原始任务清单**，实际交付以 §17 为准。

- `save_backup_dialog.dart` 的 body 抽为**可嵌入 widget** `SaveBackupPanel`，`SaveBackupDialog.show()` 保留为薄包装（**现有调用点零改动**）
- 新增 `lib/widgets/game_data_dialog.dart`：
  - Tab 1「游戏数据」：当前状态卡片 / 保存游戏数据 / 解封 / 归档列表（恢复·删除·打开目录·重命名）/ 保留份数设置
  - Tab 2「存档备份」：内嵌 `SaveBackupPanel`（原功能原样保留）
- 详情窗口左栏按钮（`game_detail_dialog.dart:1560`）的 `onTap` 改为打开新弹窗
- 删除本体的二次确认（含 `7z t` 校验前置 + 明示绝对路径 + 移回收站 + 审计日志）

### Phase 3 · 打包 / 解包　✅ **已完成（2026-10-02，§18）**

- ✅ `pack()`：压缩本体 → 写 `meta.json` → `7z t` 校验 → 二次确认后删原本体目录（回收站）→ 回写 `storage_state = packed`
- ✅ `unpack()`：磁盘预检 → `7z t` 校验 → 解压回 `original_dir`（Q4）→ UI 回写 `normal`
- ⏸ 挂到全局任务中心（`global_task_manager.dart`）、打包态点「打开游戏」→ 引导解包：**有意偏差**，见 §18.2（弹窗内进度与 seal 同模式先行，启动链路改造归后续评估）

### Phase 4 · 状态可视化　✅ **已完成（2026-10-03，§19）**

- ✅ 库页卡片状态角标（`library_page.dart` 卡片构建区，**读内存字段，零磁盘探测**）
- ✅ 详情窗口信息区显示状态 + 归档体积（仅封装/打包态显示该行）
- ✅ BPM 侧**只读展示**（不提供管理操作，项目决策）
- ✅ 设置页新增「归档库」分组（路径选择 / 保留份数 / 压缩档位）

### Phase 5 · 云备份　✅ **一期已实施（2026-10-03，`fbff7ad`/`dad0819`，见 §25）**　🔄 2026-10-03 方案修正：改学 LunaBox

> **修正原因**：原设计走 OpenList 聚合层，前提是「OpenList 已内置」——该前提已于
> 2026-10-02 失效（OpenList 改为按需对接，`openlist_provision.dart:8-12`）。
> 备份功能面向全体用户，改学 LunaBox 的直连 Provider 模式（开发者 Q10 拍板）。

**LunaBox 参考实现**（`其他开发者的项目用于本项目参考/LunaBox-main/`）：

- Provider 接口 7 方法（`internal/service/cloudprovider/cloud_storage.go:9-17`）：
  `UploadFile` / `DownloadFile` / `ListObjects` / `DeleteObject` / `TestConnection` / `EnsureDir` / `GetCloudPath`
- 3 个实现：S3（任意兼容端点）/ OneDrive（OAuth 设备码）/ Umbra（LunaBox 自家服务，**我们不学**）
- 设置面板（`CloudBackupSettingsPanel.tsx`）：启用开关 → 存储源下拉 → 按源渲染表单 →
  **测试连接** → 备份密码（S3/OneDrive 强制客户端加密后才上传）→ 保留数量
- 凭据：Umbra 走 Windows DPAPI（✅ 学）；S3/OneDrive 明文 JSON（🔴 反面教材，我们不学）
- 触发：手动 `SyncNow` / 启动同步 / 定时同步（`cloud_sync_service.go:54-126`）

**我们的设计（LunaBox 式，Flutter 版）**：

- 新增 `lib/services/cloud_backup/cloud_storage_provider.dart`：抽象类，方法对齐 LunaBox 7 方法
  （+`uploadProgress` 回调，Dart 侧补强）
- **一期 Provider 选择**（国内 Galgame 用户可达性优先）：
  1. **WebDAV**（首选：坚果云免费可用、纯 HTTP PUT/GET 实现最简单）
  2. **S3 兼容**（阿里云 OSS / 腾讯 COS / Cloudflare R2 / MinIO 全兼容；需实现 SigV4 签名）
  3. OneDrive（需用户自填 client_id，同 LunaBox；OAuth 设备码流）—— 后续版本
- 设置页新增「云备份」分组（照 LunaBox 骨架：启用开关 → 存储源下拉 → 按源表单 →
  测试连接 → 备份密码（可选客户端加密）→ 保留数量）
- 🔴 凭据**必须**用 Windows DPAPI 加密（FFI `CryptProtectData`；参照 `recycle_bin_service.dart`
  的 FFI 先例），**禁止明文落 JSON**（不学 LunaBox 的 S3/OneDrive 明文存储）
- 备份入口：GameDataDialog 归档条目新增「上传云端」；触发一期仅手动（定时/启动同步后续）
- 云端结构：`/<备份根>/<游戏目录名>/<归档id>/`（与本地归档库同构，`meta.json` 一并上传）

---

## 8. 改动文件清单

### 8.1 新增文件

| 文件 | 职责 |
|---|---|
| `lib/services/game_archive_service.dart` | 归档编排：seal / unseal / pack / unpack / verify / listArchives |
| `lib/services/archive_compressor.dart` | 7z 压缩封装（进程 + 进度 + 取消 + 清理） |
| `lib/services/seven_zip_progress.dart` | 7z stdout 进度解析（从 `extract_manager.dart` 抽出共用） |
| `lib/services/game_storage_state_controller.dart` | 状态判定与流转（§4.4） |
| `lib/widgets/game_data_dialog.dart` | 「游戏数据」管理弹窗 |
| `lib/widgets/save_backup_panel.dart` | `SaveBackupDialog` body 抽出的可嵌入面板 |
| `lib/models/archive_manifest.dart` | `meta.json` 的数据模型与序列化 |
| `test/services/game_archive_service_test.dart` | 归档服务单测 |
| `test/services/game_storage_state_test.dart` | 状态判定单测 |

### 8.2 修改文件

| 文件 | 改动 | 风险 |
|---|---|---|
| `lib/services/game_data_format.dart` | 加 3 字段 + `fromJson`/`toJson`（`:1449-1586`、`:1596-1700`） | 🟡 数据核心，必跑单测 |
| `lib/services/local_game_registry.dart` | `LibraryGame` 加字段 + `scan()` 两处映射 + setter | 🔴 2965 行巨型文件 |
| `lib/services/extract_manager.dart` | 进度解析改为调用抽出的公共类（**行为不变**） | 🔴 2029 行，改前先跑解压相关测试 |
| `lib/widgets/save_backup_dialog.dart` | body 抽为 `SaveBackupPanel`，`show()` 变薄包装 | 🟡 1499 行 |
| `lib/widgets/game_detail_dialog.dart` | 左栏按钮 `onTap` 改为打开新弹窗（`:1560`、`:898`） | 🔴 5432 行巨型文件，只做局部修改 |
| `lib/pages/library_page.dart` | 卡片状态角标 | 🔴 3643 行 |
| `lib/widgets/settings_modal.dart` | 新增「归档库」分组 | 🔴 4096 行 |
| `lib/core/path_helper.dart` | 🔴 **稳定区**，新增 `archivesDir` getter 需显式批准 | 🔴 稳定区 |

### 8.3 一期明确不碰

- `lib/main.dart`、`lib/main_container.dart`、`lib/theme/`、`lib/core/portable_*.dart`、`lib/services/app_state.dart`、`windows/runner/`、`lib/packages/luna_metadata_sdk/` —— **全部稳定区**
- `lib/services/save_scanner.dart`（除非 Phase 0 发现定位缺陷）
- `lib/services/save_manifest.dart`（Ludusavi manifest 解析，与此功能无关）
- 库页右键菜单（上一轮刚把「存档备份」从里面删掉，不要再加回去）
- BPM 侧的操作入口（项目决策：BPM 不做云端/管理界面）

---

## 9. 调用点替换清单

### P0（不做功能不成立）

| 位置 | 现状 | 改为 |
|---|---|---|
| `game_detail_dialog.dart:1560`（按钮 `onTap`） | `_openSaveBackup`（`:898`）打开 `SaveBackupDialog` | 打开 `GameDataDialog` |
| `game_data_format.dart:199-234`（`_overwritableFields`） | — | 🔴 **确认新字段不在其中** |
| `local_game_registry.dart:1037-1051`（stale 清理） | 元数据目录不在扫描集合时，用 `Directory(directoryPath).exists()` 判定移除 | **加状态门禁**：`storage_state != normal` 时不得移除 |

### P1

| 位置 | 现状 | 改为 |
|---|---|---|
| `library_page.dart:3992-4047`（卡片渲染） | 无状态呈现 | 加角标（读内存，零磁盘 I/O） |
| `game_detail_dialog.dart:623-678`（目录行下拉） | 「更换游戏目录」 | 保留，并在 `sealed` 态下作为「解封」的入口之一 |
| `library_page.dart:2593-2620`（双击启动） | 失败即弹 exe 选择器 | 先按状态分流：`packed` 引导解包、`sealed` 引导重新定位 |

### P2（易漏的非 Widget 路径 🔴）

| 位置 | 为什么容易漏 |
|---|---|
| `game_launch_service.dart:116-158` `resolveUserChoice` | 非 Widget 层，启动失败兜底逻辑在此 |
| `game_launch_service.dart:388-408` `executeLaunch` 失败分支 | 同上，错误文案要区分"本体不存在"与"游戏已打包" |
| `local_game_registry.dart:2319-2369` `launchGame` | 启动总入口，Phase 0 的 `directoryPath` 语义变更必须先在这里兜住 |
| `interrupt_cleanup.dart`（退出清理） | 进程退出时会对解压目标目录做递归删除，**新增的归档目录必须纳入归属判定**，否则可能误删（ADR-007 明确点过这个文件） |
| `game_detail_page.dart:310`（调 `refreshStaleEntries`） | 探索详情页会触发 stale 清理，可能把 `sealed` 条目误移出内存库 |
| `discover_page.dart:191,201`（同左） | 同上 |
| `main.dart:422`（启动 `scan()`） | 启动链路，状态字段必须在这里就被正确读入 |
| 托盘/退出钩子 | 若加"退出时自动备份"，需接入现有退出流程 |

---

## 10. 风险登记

| 级别 | 风险 | 影响 | 应对 |
|---|---|---|---|
| **P0** | **误删用户游戏本体**（压缩损坏 / 校验被跳过 / 用户目录越界） | 不可逆数据丢失 | ① 删前必过 `7z t` + 文件数比对 ② 二次确认框**明示真实绝对路径** ③ **移回收站而非永久删除** ④ 写 `data/cleanup_log.jsonl` ⑤ 严格按 ADR-007（`docs/DEV/DECISIONS.md:166-203`） |
| **P0** | **`.ctgame` 被一起归档删除** ⇒ 卡片从库中静默消失，游玩时长/会话记录全丢 | 用户以为数据没了 | 封装/打包**一律保留元数据目录**（至少 `.ctgame` + `game.json`）；`appdata.7z` 打包时排除 `.ctgame`，不改动磁盘上的原件 |
| **P0** | **`interrupt_cleanup` 误删归档目录** | 备份全灭 | 归档目录必须纳入 `PathHelper.isInsideAppStorage` 归属判定；若归档库配到 app storage 外，退出清理**必须跳过** |
| **P0** | 新字段被误列入 `_overwritableFields` | 重新导入清空状态 | §5.4，加单测锁死 |
| **P1** | **压缩期间机器不可用**（CPU 打满 / 磁盘 I/O 打满） | 用户体验崩坏，可能触发用户强杀进程导致归档半成品 | `-mmt=2` 限流；进度可取消；`.partial` 标记 + 启动清理 |
| **P1** | 7z 在**超长路径**（>260 字符）或**中文/日文文件名**下出错 | 归档不完整 | Phase 0.2 必须专门覆盖这两个场景；必要时加 `\\?\` 前缀 |
| **P1** | 大目录压缩**耗时以小时计**，用户中途关闭软件 | 归档半成品残留 | 归档目录带 `.partial`；启动时清理；UI 明确显示"预计剩余时间" |
| **P1** | 磁盘空间预检不准（NTFS 压缩/稀疏文件/符号链接） | 写到一半磁盘满 | 预检余量放大到 1.05+；写满时**中止并回滚，绝不删源** |
| **P1** | 存档还原**写回原始绝对路径**（`backup.json.files` 里的绝对路径可能已失效） | 还原到错误位置或失败 | 还原前逐条校验父目录；失效项列清单让用户确认目标；**还原前先自动备份当前存档**（借鉴 LunaBox `pre_restore`） |
| **P2** | `storage_state` 与磁盘实际不符（用户手动删了归档 / 手动拷回了本体） | UI 显示与实际不一致 | §4.4 派生降级判定；提供"重新检测状态"入口 |
| **P2** | 归档库指向 NAS 映射盘，断连时误判为"归档丢失" | 状态被错误降级 | 复用 `network_path.dart:92-202` 的卷可达性探测；**不可达时保留状态并标记"离线"**（参照 `local_game_registry.dart:829-841` 的既有做法） |
| **P2** | 上一轮的「备份」按钮文案与本次功能范围不符（现在要管封装/打包了） | 用户不知道点进去能干这么多 | 建议文案改「游戏数据」（见 §13 开放问题 1） |
| **P2** | 全项目 **16 处重复的目录名清洗实现**（`replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim()`），与"唯一实现 `GameKey.dirNameFromTitle`"的既有纪律矛盾 | 未来某处改规则会漏改其余 15 处 | 🔴 **只报告，本次不改**（超出任务范围）。已核对：16 处**正则字节级一致**，当前行为无分歧，属技术债而非 bug |

---

## 11. 验收标准

### 11.1 功能验收（真机走查，必须人工）

| # | 场景 | 通过标准 |
|---|---|---|
| 1 | 正常游戏 → 封装 | 归档目录生成 `meta.json` + `appdata.7z` + `saves.7z`；`game.json.storage_state == "sealed"`；卡片显示「封装」角标 |
| 2 | 封装后删本体 → 打开软件 | 卡片仍存在（`.ctgame` 在）、显示「封装」、不报错、不自动清理记录 |
| 3 | 封装态 → 重新定位本体 → 解封 | 存档被还原到原位、`game.json` 恢复、状态回 `normal`、能正常启动游戏 |
| 4 | 正常游戏 → 打包 | 归档目录多出 `body.7z`；`storage_state == "packed"`；可选二次确认后原本体目录进回收站 |
| 5 | 打包态 → 解包 | 本体完整还原到 `original_dir`、能直接启动；文件数与压缩前一致 |
| 6 | 打包态点「打开游戏」 | 弹解包确认（显示体积与预计时间）→ 后台解包 → 完成后自动启动（✅ **已落地**：库页双击主路径，`e56ef40`；主页/BPM/快捷方式入口待批，见 §23.2） |
| 7 | 删除本体确认框 | **显示真实绝对路径**；勾选后才执行；执行后可在回收站找到 |
| 8 | 压缩中途取消 | 任务停止、`.partial` 残留被清理、**源目录完好无损** |
| 9 | 归档库配到另一个盘 | 归档写到新位置；原位置不再产生新归档 |
| 10 | 手动删掉归档目录后打开软件 | 状态如实降级（`normal` 或 `display_only`），不崩溃、不误导 |
| 11 | 仅展示态（本体+归档都不在） | 卡片灰化/角标、点击给明确引导、**不自动删记录** |
| 12 | 窄窗口（960×540） | 「游戏数据」弹窗不溢出（本项目已知右栏窄宽坑） |
| 13 | 库页滚动性能（1000 部游戏） | 状态角标**不引入**卡片构建期磁盘 I/O，滚动不掉帧 |

### 11.2 技术验收

| 项 | 命令 / 方法 | 基线 |
|---|---|---|
| 静态分析 | 本环境用 `.workbuddy/analyze_probe/` 进程内 analyzer（详见 `flutter-analyze-without-subprocess` skill） | **新增 error = 0**；新增 warning 需逐条对照 stash 前后 |
| 单测 | 开发者在**自己终端**跑 `flutter\bin\flutter.bat test --exclude-tags network`（2026-10-03 起全仓唯一联网测试 `nextmoe_integration_test.dart` 已打 `@Tags(['network'])`，排除后离线跑不受网络/代理拖累；联网集成需验证时单独 `--tags network`） | 离线全量全绿；联网集成测试因无代理连不上 API 的失败**不算回归** |
| 改动面自查 | `git status --short` / `git diff --stat` | 仅动 §8 清单内的文件 |
| 稳定性专测 | 连跑 3 次"压缩→解压→哈希比对" | 3/3 一致 |
| 大目录实测 | ≥ 8GB 真实游戏 | 不崩溃、进度单调、可取消 |

> ⚠️ **本环境 `flutter test` 跑不通**（Dart 匿名管道受限，`CreateFile failed 231`），必须由开发者在正常终端补跑。**跑不了的测试 = 没有测试。**
>
> ⚠️ **已知存量 flaky（与本功能无关，2026-10-03 用户实跑观测）**：
> ① `test/big_picture/focus/bpm_page_zone_wiring_test.dart` 的 `(tearDownAll)`
> 曾观测挂起 6 分钟+（tearDownAll 本身仅三行清理代码，嫌疑为进程退出阶段
> pending Timer/Isolate，属并行会话区域测试）；复现时按文件排除单跑排查。
> ② 项目根 `env-prefix_flutter_check.bat`：一键补跑脚本（清代理 → pub get →
> analyze → `test --exclude-tags network`），双击即用，输出全部发 AI 判读。

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
你是 Chrono Tide（D:\CTLIB，Flutter Windows Galgame 管理器）的开发 AI。

开工前必读（不得跳过）：
  AGENTS.md（AI 行为宪法）、docs/DEV/SESSION_HANDOFF.md、docs/DEV/STATUS_MAP.md、
  docs/DEV/DECISIONS.md（重点 ADR-007 / ADR-008 / ADR-012）、
  docs/DEV/features/game_storage_state_implementation_plan.md（本方案，你的任务书）

任务：实现「游戏数据保存（存储状态）」，按方案 §7 的阶段顺序推进。

硬约束：
1. 两段式流程：先只读审计出《变更计划》等批准，再按批准执行。禁止从零重设计。
2. 最小变更：只改方案 §8 清单内的文件；发现清单外才是正解 → 停下来报告。
3. 🔴 稳定区（lib/main.dart、main_container.dart、lib/theme/、lib/core/portable_*.dart、
   app_state.dart、windows/runner/、packages/luna_metadata_sdk/）未经显式批准不得触碰。
4. 🔴 删除类操作必须先过 PathHelper.isInsideAppStorage（ADR-007）；
   用户可见路径的删除必须在确认框明示真实绝对路径，且优先移入回收站。
5. 🔴 禁止 git gc。禁止 dart format 整个 lib/。禁止改 pubspec 依赖版本。
6. 🔴 本仓 CRLF，Edit 偶尔"报成功但不落盘" → 每次编辑后必须 grep/Read 验证。
7. 只读审计阶段不得修改任何文件。

不要做的事（一期非目标）：
  · 不要实现云端上传/下载（Phase 5 是二期，本期只预留数据模型与 UI 位置）
  · 不要为 display_only 写专门的保存/恢复流程（它只是兜底派生态，不写盘）
  · 不要做增量备份 / 内容去重 / manifest 差分同步
  · 不要重新设计状态机，不要给 lib/ 加新依赖

必须先做 Phase 0 技术验证（方案 §7），产出
docs/DEV/features/game_storage_state_phase0_report.md。
若 0.1（7z 压缩进度可复用现有解析）或 0.2（压缩→解压往返一致）不通过，
立即停止并报告，不得带病进入 Phase 1。

收尾（每次改动后）：
  进程内 analyzer（errors=0）→ 开发者终端补跑 flutter test
  → git status/diff 自查改动面 → 更新 DEV_LOG / SESSION_HANDOFF / 本方案文件
  → 一个任务一个 commit（只 git add 显式文件）→ 报告（✅改了什么 / ✅验证了什么 / ⚠️没验证什么 / 📌遗留）

环境事实：
  · flutter 在项目内：./flutter/bin/flutter.bat（3.24.3 / Dart 3.5.3），不用全局命令
  · 跑 flutter 前同 shell unset 全部代理变量（带 http_proxy 时测试会全量假失败）
  · 本环境 flutter test 跑不通（Dart 匿名管道受限），analyze 用进程内 analyzer 方案
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 建议 |
|---|---|---|
| 1 | 详情窗口那个按钮现在叫「备份」，但功能要扩到封装/打包/解封/解包，**文案是否改为「游戏数据」**？ | 建议改。与开发者统一的术语一致，也让用户预期到里面是完整的数据管理 |
| 2 | 「封装」后**本地是否还保留一份归档副本**？还是只保留元数据目录、归档只存一份在归档库？ | 建议**只存一份**（在归档库）。本地保留元数据目录仅为让卡片不消失（`.ctgame` + `game.json` + 封面），截图等大件进归档 |
| 3 | 「打包」完成后**原本体目录是删还是留**？ | 建议按决策 3 走二次确认；默认勾选框**不预选**，强制用户主动勾 |
| 4 | 解包时是否支持**解到别的盘**（原盘空间不够）？ | 建议一期**只解回 `original_dir`**，空间不够则明确报错；跨盘解包留二期 |
| 5 | 是否要**升 `format_version` 到 5**？ | 建议**不升**（纯新增可空字段，`?? 默认值` 即兼容）。但需开发者确认是否接受这个 ADR-012 例外 |
| 6 | 归档**保留份数默认值**？ | 建议 5 份（LunaBox 云端存档默认也是 5） |
| 7 | 「游戏数据」弹窗的 Tab 结构：是把现有存档备份**内嵌为 Tab 2**，还是**分开两个入口**？ | 建议内嵌（`SaveBackupPanel` 抽出为可嵌入 widget），入口收成一个 |
| 8 | 是否加「**游戏退出时自动封装**」的开关（借鉴 LunaBox）？ | 建议**不加**。封装/打包是重型操作（分钟级），不该在退出时静默触发；保留手动 |
| 9 | **解封还原存档时，目标位置已有文件**（如封存期间又玩出新档）怎么办？当前实现是**静默覆盖**（`restoreSaves`，§22.2） | 建议**预检 + 询问替换**：有冲突才弹确认框，旧档先移入回收站再还原（§22.3 Q13）→ **已按建议实施（`56cc763`，§23.1）** |

---

## 14. 决策记录（2026-10-02 已拍板）

| # | 问题 | 开发者决定 | 时间 |
|---|---|---|---|
| **Q1** | 详情页按钮文案是否改为「游戏数据」？ | ❌ **不改，保持「备份」** | 2026-10-02 深夜 |
| **Q5** | 是否升 `format_version` 到 5？ | ✅ **不升**，保持 4（接受 ADR-012 显式例外：纯新增可空字段 + `?? 默认值` 即完全兼容） | 2026-10-02 深夜 |
| **Q2** | 「封装」后本地是否保留归档副本？ | ✅ **只存一份**（在归档库；本地仅保留让卡片不消失的元数据 `.ctgame` + `game.json` + 封面） | 2026-10-02 深夜 |
| **Q3** | 「打包」完成后原本体目录是删还是留？ | ✅ **按决策 3 走二次确认；默认勾选框不预选**，强制用户主动勾 | 2026-10-02（Phase 2 前） |
| **Q4** | 解包时是否支持解到别的盘？ | ✅ **一期只解回 `original_dir`**，空间不够明确报错；跨盘留二期 | 同上 |
| **Q6** | 归档保留份数默认值？ | ✅ **5 份**（已落 `ArchiveLibraryPreference.defaultRetention = 5`） | 同上 |
| **Q7** | 「游戏数据」弹窗的 Tab 结构？ | ✅ **内嵌**（抽出 `SaveBackupPanel` 作为 Tab 2），入口收成一个 | 同上 |
| **Q8** | 是否加「游戏退出时自动封装」开关？ | ✅ **不加**（封装是分钟级重型操作，不该在退出时静默触发） | 同上 |
| **Q9** | 归档列表的「重命名」功能做不做？ | ✅ **砍掉**（归档目录名即 id，改名会让 `game.json.archive_dir` 指针失效；若确需"标记"，二期在 `meta.json` 加独立 `label` 字段，不改目录名） | 2026-10-02（Phase 3 前，原话「全都按照你建议的来走」） |
| **Q10** | 云备份通道：继续走 OpenList 聚合层，还是学 LunaBox 直连 Provider？ | ✅ **改学 LunaBox**（🔴 原决策「OpenList 已内置」前提已失效——2026-10-02 起 OpenList 改为按需对接；备份面向全体用户不能强依赖需额外对接的通道） | 2026-10-03（Phase 4 后，原话「学习 LunaBox 的那种方法就行」） |
| **Q11** | 弹窗按钮「保存游戏数据」与状态词「封装」不一致导致误解（用户以为封装无 UI） | ✅ **统一为「封装」词系**（按钮/确认框/进度/提示全部对齐状态词；确认框写明内容=软件侧数据+提取的存档） | 2026-10-03（Phase 4 后，用户反馈术语混乱） |
| **Q12** | 归档库游戏根的钥匙：标题清洗名 → **game_id**（对齐 `20e1671` 卡片钥匙统一 + 同名不同路径合法化；旧布局按需迁移，混杂旧根逐份认领） | ✅ **采用** | 2026-10-03（用户修复重复导入后要求归档链路同步，原话「不要混乱了」） |
| **Q13** | 解封还原存档时目标已有文件怎么办？ | ✅ **预检 + 替换询问**（旧档先移入回收站可反悔；appdata 侧 `game.json` 保留本地版，防 `launch_path` 被封存前快照打回；不提供「合并」） | 2026-10-03（原话「开始我们的继续开发，把这个收尾了」） |
| **Q14** | 封装/打包压缩前要不要让用户确认存档清单？（自动检测会扫错/漏扫；面板自定义路径归档流程没利用） | ✅ **确认框前置**：自动检测 + 面板自定义路径合并，可勾选/添加/删除，默认全选；服务层 savePaths 参数（null=自动兼容旧调用） | 2026-10-03（真机走查反馈，「让用户可以确定游戏的这个存档是否是他想要的那个存档」） |
| **Q15** | 归档名只有时间戳+状态，用户分不清哪个归档是哪个游戏 | ✅ **id 改 游戏名_时间_状态**：清洗 Windows 非法字符 + 截断 40 + 空标题回退旧格式；旧归档零影响 | 2026-10-03（同上，「封装的时间；封装的游戏名你总要有吧」） |
| **Q16** | 功能缺引导，需要使用说明 | ✅ **弹窗 Tab1 顶部可展开说明区**（默认收起）：功能定位/四动作/存档确认/与存档备份区别/首次使用建议 | 2026-10-03（同上，「放一个使用说明详细介绍一下这个功能」） |

> **Q3–Q9 全部采纳建议** —— 开发者 2026-10-02 原话「都按你建议的走」。
> 其中 **Q6 / Q7 已在 Phase 2 落地**（§17）；**Q3 / Q4 / Q9 已在 Phase 3 落地**（§18，
> Q4 按"只解回 original_dir"实现、Q9 按砍掉执行）；
> **Q8 维持不做**。

---

## 15. Phase 0 实测对方案的修正（速查）

> 完整证据见 `docs/DEV/features/game_storage_state_phase0_report.md`。

| 方案原文 | 实测结论 | 处理 |
|---|---|---|
| §3.1「解压侧已有 `-bsp1` 进度解析可复用」 | ❌ 正则**不匹配**，从未生效（既有 bug） | M1：改 `^\s*(\d+)%` |
| §6「30–80 MB/s，8GB 约 2–5 分钟」 | ⚠️ 实测 5–20 MB/s，8GB 约 7–28 分钟 | M2：已改 §6 |
| §4.2 归档布局含 `.partial` | ⚠️ 7z **不自带**该行为（写最终名、无 `.tmp`） | M3：Dart 侧实现 |
| §4.2 命令 `"<srcDir>\*"` | ⚠️ 会带一层目录名前缀 | 改 cwd + `*` |
| §7「`-sdel` 是否可用」 | ❌ 连源目录删光 | 结论：不用 |
| §7「是否需要分卷」 | ⚠️ `extract_manager` 不认 `.7z.001` | 结论：一期不用 |
| §10 P1「7z 在 >260 路径可能出错」 | ✅ **未复现**，291 字符路径正常 | 风险降级，无需 `\\?\` |
| （未预见）| 🔴 **7z 管道输出是 GBK 字节**，`utf8.decoder` 抛 FormatException 并中止整条流 | **M4**：新增 `-sccUTF-8` + `allowMalformed` 双保险（Phase 1 已修） |
| （未预见）| ⚠️ 进度节流把**末值吃掉**（小任务在同一窗口内跑完）→ UI 停在 53% | 已在流 `onDone` 补发末值 + 成功时补 100（Phase 1 已修） |

---

## 16. Phase 1 实施记录（2026-10-02）

### 16.1 交付清单

**新增（6 源码 + 3 单测 + 2 探针）**

| 文件 | 行数级 | 职责 |
|---|---|---|
| `lib/services/seven_zip_progress.dart` | ~140 | 公共 7z 进度解析 + 节流流 |
| `lib/models/archive_manifest.dart` | ~340 | `meta.json` 模型 + `validate()` |
| `lib/services/archive_compressor.dart` | ~430 | `7z a/x/t/h` 进程封装 |
| `lib/services/game_storage_state_controller.dart` | ~230 | 四态判定 |
| `lib/services/archive_library_preference.dart` | ~190 | 归档库偏好 |
| `lib/services/game_archive_service.dart` | ~700 | 归档编排 |
| `test/services/seven_zip_progress_test.dart`<br>`test/services/archive_manifest_test.dart`<br>`test/services/game_storage_state_test.dart` | — | 单测（**待开发者终端跑**） |
| `dev_probe/phase1_verify.dart` | ~560 | 端到端探针（**已实跑 84/84**） |

**修改（3 个既有文件）**

| 文件 | 改动 |
|---|---|
| `lib/services/game_data_format.dart` | `GameJsonData` +3 字段；`fromJson` `?? 默认值`；`toJson` 仅非默认值输出；`currentVersion` 保持 4 + ADR-012 例外注释；`_overwritableFields` 未动 |
| `lib/services/local_game_registry.dart` | `LibraryGame` +3 字段；`scan()` 两处映射；`setStorageState()`；**stale 清理状态门禁** |
| `lib/services/extract_manager.dart` | `_parse7zLine` 委托公共解析器；2 处补 `-sccUTF-8`；4 处解码器补 `allowMalformed` |

### 16.2 关键设计取舍（与 §4/§5 的偏差）

| 项 | 方案原文 | 实际实现 | 理由 |
|---|---|---|---|
| 归档库目录常量 | `path_helper.dart` 加 `archivesDir` | **不加**，常量落在 `ArchiveLibraryPreference.defaultRootPath` | `path_helper.dart` 是**稳定区**；开发者 2026-10-02 拍板不开例外 |
| 存档如何进归档 | 未指定 | 先**暂存**到 `<workDir>/.stage/saves`（`f{i}/` `d{i}/` 无盘符结构），再整体压缩 | 存档散落在 `C:\Users\...` 与游戏目录两处；直接多路径压缩会让归档内路径不可控，还原时无法干净映射回原始绝对路径 |
| `.ctgame` 是否进 `appdata.7z` | 排除 | 排除，但 `restoreAppData()` **按需重建** | 排除可避免"别处冒出重复标记"；重建则补上"元数据目录丢失后还原、卡片回不来"的洞 |
| `pack()` 删本体 | Phase 3 做 | Phase 1 **不做**，`pack()` 只产出归档 | 破坏性动作必须先有二次确认 UI；Phase 0 已验证 `SHFileOperationW` 技术路径 |
| `saves.7z` 无存档时 | 未指定 | 跳过该段 + **warning 如实告知** | 「未检测到存档」不能静默吞掉，用户要知道备份里到底有什么 |

### 16.3 新增的防御性护栏（方案未写，但不做会出事）

1. **自包含拒绝**：归档输出路径落在源目录内部时直接拒绝 —— 否则 7z 会把自己装进去。
2. **归档库位置校验**：`ArchiveLibraryPreference.validateRoot()` 拒绝 `Games/` 与 `downloads/`
   之内的路径（前者会污染游戏扫描并被 `InterruptCleanup` 误判，后者与下载清理冲突）。
3. **stale 门禁**：`storage_state != normal` 的条目在扫描时**不得因本体目录缺失而移除**
   （否则封装完一刷新，卡片连归档入口一起消失）。
4. **回到 normal 时强制清空归档指针**：避免留下悬空 `archive_dir`。
5. **进度末值补齐**：见 §15。

### 16.4 未验证（诚实标注）

- ⚠️ **`flutter test` 未跑** —— 本环境 Dart 匿名管道受限；3 个单测只过 analyzer（errors=0），
  需开发者在终端补跑。
- ⚠️ **GB 级真实游戏未跑** —— D 盘余量不足（Phase 1 结束时仅 **6.3G**）。
  Phase 0 已给外推值（5–20 MB/s），但真实游戏目录的 `seal()` 全链路未实测。
- ⚠️ **`seal()` / `pack()` 的真实调用在 Phase 2 才接 UI** —— 本 Phase 只验证了它依赖的
  每一层（压缩、清单、状态、存档扫描）。
- ⚠️ **`pruneArchives()` 未做端到端实测**（需造多份归档；逻辑已被单测覆盖到判定层）。

### 16.5 下一步（Phase 2）　✅ **已完成（2026-10-02）**

`SaveBackupDialog` body 抽为可嵌入 `SaveBackupPanel` → 新增 `game_data_dialog.dart`
（Tab 1 游戏数据 / Tab 2 存档备份）→ 详情窗口按钮 `onTap` 改指向新弹窗。

**Q3 / Q4 / Q6 / Q7 / Q8 已由开发者采纳建议**（「都按你建议的走」，见 §14）。
执行结果见 **§17**。

---

## 17. Phase 2 实施记录（2026-10-02）

### 17.1 交付清单

**新增（2 源码 + 1 测试）**

| 文件 | 行数级 | 职责 |
|---|---|---|
| `lib/widgets/save_backup_panel.dart` | ~1420 | 从 `SaveBackupDialog` 抽出的可嵌入面板（三张子 Tab + 全部业务状态，**不含**外层框体） |
| `lib/widgets/game_data_dialog.dart` | ~1230 | 「游戏数据」弹窗（Tab1 游戏数据 / Tab2 存档备份） |
| `test/widgets/game_data_dialog_test.dart` | ~90 | 布局溢出哨兵（960×540 / 1280×720）+ 抽取后结构不变（**待开发者终端跑**） |

**修改（3 个既有文件）**

| 文件 | 改动 |
|---|---|
| `lib/widgets/save_backup_dialog.dart` | **1499 → 134 行**：降为薄包装（外层框体 + 标题栏），body 改嵌 `SaveBackupPanel`；`show()` 签名与行为不变 |
| `lib/widgets/game_detail_dialog.dart` | `_openSaveBackup()` → `_openGameData()`（改开 `GameDataDialog`）；import 由 `save_backup_dialog.dart` 换为 `game_data_dialog.dart`；按钮 `onTap` 改指向（`:1565`） |
| `lib/services/game_archive_service.dart` | 新增 `deleteArchive(record, {allowOutsideAppStorage})` —— 越界护栏 + `CleanupLog` 审计，供弹窗归档列表的「删除」 |

### 17.2 与方案 §7 / §16.5 的偏差（🔴 全部为有意为之）

| 项 | 方案原文 | 实际实现 | 理由 |
|---|---|---|---|
| **打包 / 解包** | §7 Phase 2 弹窗内含 | **未做** | §7 划归 Phase 3；涉及压缩 GB 级本体 + 删本体确认 + 回收站，破坏性最强。Phase 2 只做「只保存不删源」的封装 / 解封 |
| **归档重命名** | §7 Phase 2 归档列表含 | **未做** | 归档目录名即 id（含时间戳），改名会让 `game.json.archive_dir` 指针失效；收益低风险高。**建议直接砍掉** —— 若确需"标记"，应在 `meta.json` 加独立 `label` 字段（Phase 3+），而不是改目录名 |
| **删除本体二次确认** | §7 Phase 2 | **未做** | 与 `pack()` 强耦合，随 Phase 3 落地（Phase 2 的弹窗已备好承载位置） |
| 「归档库」设置页 | §7 Phase 4 | 未做 | 但 Phase 2 弹窗内已提供**保留份数**设置（Q6）；归档库**路径选择**仍留 Phase 4 |
| 打开归档目录 | — | `Process.start('explorer', [dir])` | 复用 `game_detail_dialog.dart:940` 的既有范式，不新造 |

### 17.3 新增的防御性护栏（方案未写，但不做会出事）

1. **解封前置守卫**：`_resolution.bodyExists != true` 时**拒绝解封**并提示「先重新定位本体」
   —— 否则还原完把状态写成 `normal` 而本体仍缺失，状态当场自相矛盾。
2. **窗口自适应尺寸**：用 `MediaQuery` 算 `w/h`（clamp 到 360–640 / 360–680），
   直接消灭 §11.1 #12 的窄窗口（960×540）溢出风险（不重蹈固定 560×640 的覆辙）。
3. **删除归档越界拒绝**：`deleteArchive` 要求目标必须在归档库根**之下**
   （防删到根或上层目录）；且归档库在应用目录之外时需 `allowOutsideAppStorage: true`
   —— 由确认框明示绝对路径后放行（ADR-007）。
4. **自动清理失败如实告知**：`pruneArchives` 因归档库在应用目录之外被拒时，
   弹窗明确提示「已跳过自动清理」，**不静默吞掉**。
5. **部分失败如实列出**：`restoreSaves` 的 `failures` 逐条展示给用户（方案 §4.6）。

### 17.4 未验证（诚实标注）

- ⚠️ **`flutter test` 未跑** —— 本环境 Dart 匿名管道受限（`CreateFile failed 231`）；
  新增的 widget 测试只过 analyzer（errors=0），需开发者终端补跑：
  `flutter\bin\flutter.bat test test/widgets/game_data_dialog_test.dart`。
- ⚠️ **真机走查未做** —— 弹窗在两个窗口尺寸下的观感、归档列表滚动、`explorer` 打开归档目录、
  封装 / 解封的按钮态流转，均需人工确认。
- ⚠️ **`seal()` 未在真实游戏上端到端跑过** —— 受磁盘限制（Phase 1 结束时 D 盘仅 6.3G）。
- ⚠️ **BPM 侧入口未动** —— `big_picture_shell.dart` / `big_picture_library_page.dart` 仍走老的
  `SaveBackupDialog`（项目决策：BPM 只做只读展示与最小改动）。
- ⚠️ **自动化清理在外部归档库下失效** —— 归档库配到应用目录之外时，自动清理会被
  ADR-007 护栏拒绝（弹窗有提示）。Phase 3 需引入回收站 / 显式授权路径。

### 17.5 下一步（Phase 3）　→ ✅ 已完成，见 §18

打包 / 解包已落地（2026-10-02，§18）。原计划中的「挂全局任务中心」与
「打包态点『打开游戏』→ 引导解包」为有意偏差（§18.2），归后续评估。

---

## 18. Phase 3 实施记录（2026-10-02）

### 18.1 交付

| 文件 | 变化 |
|---|---|
| `lib/services/recycle_bin_service.dart` 🆕 | FFI `SHFileOperationW(FO_DELETE \| FOF_ALLOWUNDO \| SILENT \| NOCONFIRMATION \| NOERRORUI)`，把 Phase 0 探针路径提升为正式服务。**零 flutter 依赖**（探针可加载）；不做归属判断（那是确认框 + 审计的职责），只负责"删得可恢复" |
| `lib/services/game_archive_service.dart` | ① `pack({removeBody})`：归档校验通过且状态回写成功后，本体移入回收站（失败**不致命**，写入 warnings + `bodyRemoved=false`，UI 如实告知）；成功/失败均写 `CleanupLog`（op=`archive_body_recycle`）。② 新增 `unpack({record})`：状态必须 packed → 目标=`original_dir`（Q4）→ 目标已存在**即拒绝**（不覆盖）→ 目标不得在归档库内 → 空间预检（不足明确报错）→ `7z t` 全量校验先行 → 解压 → 文件数交叉比对（不符仅警告）。③ `ArchiveOperationResult` 加 `bodyRemoved` 字段；`_precheckSpace` 加 `label` 参数（解包报错指"解包目标"而非"归档库"） |
| `lib/widgets/game_data_dialog.dart` | 按钮区按状态分流：normal→[保存游戏数据][打包]、sealed→[解封]、packed→[解包]。`_confirmPack`：**Q3 落地**——「移入回收站」复选框默认不预选，勾选后确认按钮变警示色 + 展开明示绝对路径的后果说明；取消返回 null 与"仅打包"三分。`_unpack` 确认框明示解压目标绝对路径 + 空间需求 |
| `dev_probe/phase3_recycle_unpack_probe.dart` 🆕 | **17/17 PASS**：回收站往返（含不存在/空路径拒绝）；压缩→校验→回收站删源→解压回原目录→**逐字节一致（含中日文路径）**+ 文件数交叉比对；实证"解压是合并而非干净还原"⇒ 服务层目标存在即拒绝的守卫必要 |

### 18.2 有意偏差（非遗漏）

| 项 | 原计划 | 实际 | 原因 |
|---|---|---|---|
| 挂全局任务中心 | §7 Phase 3 | **未做** | 弹窗内进度展示与 seal/unseal 同模式已够用；任务中心改造涉及全局调度，归后续评估 |
| 打包态点「打开游戏」→ 引导解包 | §7 Phase 3 | **未做** | 涉及 `GameLaunchService` 启动链路（敏感区），与状态机解耦后单独做更稳 |
| 解包还原存档 | §7 原文「还原存档」 | **未做** | seal/pack 从不删除本地存档/游戏数据（只增归档），解包只需还原本体；存档若被用户手动清理过，走弹窗已有「从归档恢复」按钮 |

### 18.3 关键设计决定

- **删本体失败不致命**：归档已完成、状态已 packed，回收站失败只追加 warning —— 不让"清理失败"毁掉"归档成功"。
- **解包拒绝覆盖已有目录**：探针实证 7z 覆盖解压是「合并」（归档外的残留文件会存活），对旧目录解压得到的是混合体而非干净还原；宁可让用户手动移走，绝不静默污染。
- **状态回写留在 UI 层**（unpack 与 _unseal 一致）：拿到 ok 才写 normal，失败时状态绝不先变。

### 18.4 验证

- 进程内 analyzer：全 lib **318 文件 errors=0**、test **97 文件 errors=0**；warnings=89 / infos=34 与 Phase 2 基线完全一致（零新增）。
- 探针 17/17 PASS（真实 7z + 真实回收站，会向回收站放入 1 个几 KB 的小目录，与 Phase 0 探针同代价）。
- ⚠️ 未验证：`flutter test`（环境管道受限，待开发者终端补跑）；真机走查（打包/解包按钮态流转、GB 级本体实测——磁盘空间仍是硬约束）。

---

## 19. Phase 4 实施记录（2026-10-03）

### 19.1 交付

| 文件 | 变化 |
|---|---|
| `lib/pages/library_page.dart` | 库页卡片 Stack 加**存储状态角标**（左上角，与编辑勾选互斥、收藏角标/游玩标识错位）。`GameStorageState.fromWire(widget.game.storageState).hasArchive` 才显示 —— **读内存字段，零磁盘探测**（网格可能渲染上百张卡片，任何 I/O 都会卡滚动） |
| `lib/widgets/game_detail_dialog.dart` | 信息区新增「存储状态」行：仅封装/打包态显示（normal 信息量为零不加行），右侧异步显示归档体积（`_calculateArchiveSize`，仿既有 `_calculateDirectorySize` 模式；归档库纯 .7z 目录，单窗口算一次可接受）。状态直接取 `_loadGameData` 已读的 `GameJsonData.storageState`，**无需查注册表** |
| `lib/big_picture/pages/big_picture_library_page.dart` | BPM 海报卡右下角同款只读胶囊（BPM 暗色系配色）。**Positioned 必须是 Stack 直接子级** —— 条件判断写在 `if` 上而不是包 Builder（否则 Positioned 失效）。项目决策：BPM 只读、不提供管理操作 |
| `lib/widgets/settings/archive_library_settings_card.dart` 🆕 | 「归档库」卡片：位置（FilePicker + `setRootPath` 内含 validateRoot 拒绝 Games/downloads）· 保留份数（Slider 1..50 直连 `setRetention`）· 压缩档位（均衡/极限双 chip 直连 `setCompressionLevel`）。**AnimatedBuilder 直连偏好单例**，卡片不持业务状态副本（同「减少动效」先例）。反馈条提示「已有归档不会移动，仍可从原位置访问」 |
| `lib/widgets/settings_modal.dart` | 仅挂载：网络与存储页「游戏库目录」后新增 `SettingsSection(title: '归档库')`；面板独立成文件，避免 5000+ 行文件继续膨胀 |

### 19.2 关键设计

- **零磁盘探测红线**：库页角标只读 `LibraryGame.storageState` 内存字段；详情窗口是单实例才允许异步算归档体积。
- **设置面板零状态副本**：三项设置全走 `ArchiveLibraryPreference`（ChangeNotifier），AnimatedBuilder 自动刷新 —— 不会出现「UI 值与持久化值漂移」。
- **PathHelper 稳定区不碰**：归档库常量仍在 `ArchiveLibraryPreference.defaultRootPath`（Phase 1 决策延续）。

### 19.3 验证

- 进程内 analyzer：全 lib **319 文件 errors=0**、test **97 文件 errors=0**；warnings=89 / infos=34 与 Phase 3 基线完全一致（零新增）。
- 改动文件定点扫描：`library_page.dart` 4 条 warning 经 HEAD 对照全为存量（`_buildPlaceholderCover` 双定义在 HEAD 即存在，:3691 那个属未引用类 —— 按纪律只报告不改）；`big_picture_library_page.dart` 0/0/0。
- ⚠️ 未验证：`flutter test`（开发者终端补跑）；真机走查（角标观感 / Slider 触控 / 960×540 窄窗下设置卡片）。

---

## 20. 术语统一 + 云备份方案修正（2026-10-03，Phase 4 后）

开发者实际走查后提出三点：① 云备份为什么用 OpenList（LunaBox 没用，且备份要给
所有用户用，而 OpenList 已改按需对接）；② 「封装」为什么没有 UI 过程；③
「保存数据 / 备份存档 / 打包」太混乱。

### 20.1 术语混乱的根因与修正（Q11）

根因：方案 §4.6 的操作名是「**保存游戏数据（封装）**」，实现时按钮只写了
「保存游戏数据」——状态卡片显示「存储状态：封装」，用户拿着「封装」去找按钮，
界面上却只有「保存游戏数据」，自然以为封装功能缺失（其实确认框+进度条一直都有，
与打包共用 `_buildProgressBar`）。

修正后的统一词系（`game_data_dialog.dart` 8 处文案）：

| 状态词（卡片显示） | 操作按钮 | 确认框 / 进度 / 提示 |
|---|---|---|
| 正常 normal | **封装**（primary）+ **打包** | 「封装」/「正在封装」/「已封装，游戏数据已存入归档库」 |
| 封装 sealed | **解封** | 不变 |
| 打包 packed | **解包** | 不变 |

内容构成写进封装确认框：**游戏数据 = 软件侧游戏数据（appdata）+ 已提取的存档
（saves）**——即开发者需求定义的「游戏数据」概念，与 Tab2「存档备份」（原始存档
文件的独立备份功能）是两回事，弹窗内两个 Tab 各司其职不再混淆。

### 20.2 云备份方案修正（Q10）

见 §7 Phase 5（已重写）与 §6 决策表（已更新）。要点：
OpenList 聚合层 ❌ 淘汰（前提「已内置」于 2026-10-02 失效）→ 自建
`CloudStorageProvider` 抽象（对齐 LunaBox `cloud_storage.go:9-17` 七方法），
一期 WebDAV（坚果云可达性最好）+ S3 兼容，凭据强制 DPAPI（FFI `CryptProtectData`）。

## 21. 归档库钥匙统一：标题清洗名 → game_id（2026-10-03，Phase 4 后）

### 21.1 触发与问题

用户修复「重复导入同一游戏导致 Duplicate GlobalKey」（`20e1671`）时做了两个
关键决策：① 库页卡片 key 从 `directoryPath` 改为 `game_id`（`game.json`
稳定主键，UUID v4）；② 「同名不同路径」重复导入是**合法场景**（不再拦截）。
归档链路 Phase 1–4 的内部组织键是「标题清洗名」（`GameKey.dirNameFromTitle`），
与新钥匙体系冲突：

- **串库（P0）**：两个同名游戏的归档会共用 `<归档库>/<标题清洗名>/`，
  latest 指针互相覆盖、保留份数清理互删对方的归档、列表互相可见。
- **错位**：`GameDataDialog` 按 title 查库条目（`getGameByTitle`），同名
  两游戏时命中不确定。

### 21.2 修正（Q12）

- **新布局**：游戏根 = `<归档库>/<game_id>/`（UUID 文件系统安全）；
  `game_id` 为空的历史脏数据兜底回标题清洗名（与卡片 key 同策略）。
  新增纯 Dart 模块 `lib/services/archive_layout_migrate.dart`
  （不 import flutter，探针可实测——同 `seven_zip_progress` 惯例）：
  `ArchiveLayoutMigrator.resolveGameRoot()`。
- **旧布局按需迁移**（保守，只动确认属于这个游戏的数据）：逐归档子目录读
  `meta.json`，`gameId` 一致才同盘 rename 到新根（原子）；无 meta 的
  `.partial` 半成品随迁；**gameId 不一致的其他游戏归档留在旧根**，等它们
  自己的 `listArchives` 认领（同名隔离的核心）；旧根搬空才连 `latest.json`
  一起收走并删除；任何失败不阻塞（新归档仍进新根，旧数据可经
  `game.json.archive_dir` 绝对路径还原）。
- **签名换钥匙**：`GameArchiveService.listArchives / pruneArchives /
  cleanupPartials / readLatestPointer / _writeLatestPointer` 参数从
  `String title` 改为 `LibraryGame game`（内部走 `_resolveRoot(game)`）。
- **弹窗链路**：`GameDataDialog.show()` 新增 `gameId` 参数，`_game` 优先
  `getGameById`（`local_game_registry.dart:786`，既有 API）回退 byTitle；
  详情窗口 `_loadGameData` 缓存 `data.gameId` 并传给弹窗。

### 21.3 验证

- 探针 `dev_probe/phase4_key_unify_probe.dart` **18/18 PASS**（真实文件系统）：
  新根解析 / 空 id 兜底 / 混杂旧根逐份认领（A 2 份 + B 1 份）/ 同名互不串库 /
  latest 随迁 / 幂等 / 半成品随迁 / 旧根搬空删除。
- 全 lib 320 文件 errors=0、test 97 errors=0，warnings=89 / infos=34 与基线
  一致（零新增）。
- ⚠️ 未验证：`flutter test`（终端补跑）；真机走查（同名双条目的归档隔离观感）。

## 22. 解封语义澄清与 Q13：存档还原的「替换询问」（2026-10-03）

> 触发：开发者走查后描述了对「恢复」的产品预期（原话要点）：封装保存了游戏数据 +
> 存档的压缩包；恢复 = 把压缩包解压**放回游戏里**，让游戏回到曾经游玩的状态，
> 且**「还可能要询问一下用户是否替换掉游戏本体的存档」**。

### 22.1 术语对位（澄清一次，杜绝继续混叫）

| 开发者口中的 | 实现里的动作 | 压缩内容 | 还原目标 |
|---|---|---|---|
| 封装 / 恢复 | 封装 seal / **解封 unseal** | `appdata.7z`（软件侧数据）+ `saves.7z`（提取的存档） | 各自的**原始位置** |
| 打包 / 解包 | 打包 pack / **解包 unpack** | `body.7z`（游戏本体） | `original_dir` |

开发者说的「解包（恢复存档进游戏）」= 实现里的**解封**。界面文案已按 Q11 统一
（按钮就叫「解封」），后续沟通以界面词为准。

### 22.2 现状核实（开发者的直觉命中真实缺口）

- 解封的还原目标**不是**「统一塞进本体目录」，而是**当初提取存档时记录的原始绝对
  路径**：`game_archive_service.dart:808` `restoreSaves` 按 manifest `saves.entries[].path`
  逐条写回 —— 存档原本在游戏目录内的就回游戏目录内，在「我的文档 / AppData」的
  就回原处。**效果上等价于开发者说的「让游戏完全回到曾经游玩的状态」**，理解大方向一致。
- 🔴 但「询问是否替换」**确实没有**：`restoreSaves` 对文件走 `File.copy`（`:849`，
  Dart 语义 = 覆盖同名目标）、目录走 `_copyDirectory(overwrite: true)`（`:841`、
  `:1145-1163`）—— 对目标位置已存在的同路径文件**静默覆盖**，无预检、无确认框。
- 对照之下，解包（本体）反而是「目标已存在即拒绝」（`:878`、`:908`）—— 两个还原
  操作的安全策略不一致。
- 风险场景：封装后（本体还在、存档已收走）用户又开游戏从零玩出了**新存档** →
  此时解封，旧档静默盖掉新档，新进度**无提示丢失**。

### 22.3 Q13 建议方案：解封前预检 + 冲突清单 + 旧档进回收站

1. **解封前预检**：逐条检查 `saves.entries[].path` 是否已存在于磁盘（appdata 目标
   目录同理检查残留）。服务层新增纯查询 API `checkRestoreConflicts(record)`。
2. **无冲突** → 直接还原，流程与现状一致（不打扰用户）。
3. **有冲突** → 确认框列出冲突条目（前 5 条 + 汇总数），两个选择：
   - **「替换」**：旧文件/目录**先移入回收站**（复用 `RecycleBinService`，可反悔）
     → 再照常还原；
   - **「取消」**：什么都不动。
4. **不提供「合并」**：7z / 目录复制的覆盖语义是合并（新旧混杂），正是 unpack
   「目标存在即拒绝」要防的污染，存档侧同样不给这个选项。
5. UI 落点：`game_data_dialog.dart` `_unseal`（`:229`）在现有确认框之后、
   `_startBusy` 之前插入预检 + 冲突确认步骤。
6. 落地后 §11.1 场景 3 的走查追加分支：「目标已有存档时出现替换询问，替换后旧档可在回收站找回」。

> **状态：✅ 已按建议落地（2026-10-03，`56cc763`，实施细节见 §23.1）。**

## 23. Q13 + 打包态引导解包实施记录（2026-10-03）

> 开发者原话「开始我们的继续开发，把这个收尾了」= 批准两项收尾开发。
> 终端 flutter test 验证按开发者指示跳过（两次实跑分别被联网测试与
> `bpm_page_zone_wiring_test` tearDownAll 拖住；联网测试已打
> `@Tags(['network'])` 分离，见 `00d299b`）。

### 23.1 Q13 解封替换询问（`56cc763`）

| 层 | 交付 |
|---|---|
| `game_archive_service.dart` | ① 🆕 `checkRestoreConflicts(record)`：基于 `saves.entries[].path` 逐条查磁盘的**纯查询**预检（不解压不写盘）。② `restoreSaves` 加 `replaceOld`：**默认拒绝覆盖**（冲突即 fail，防绕过 UI）；`replaceOld=true` 时旧实体**先移入回收站**（复用 `RecycleBinService`），回收站失败的条目**跳过还原**并计入 `failures`。③ `restoreAppData` 伴生保护：解压前暂存本地 `game.json`、解压后写回 —— 本地版是封存期间仍会更新的**超集**（relink 的 `launch_path`、用户编辑），归档内是封存前快照 |
| `game_data_dialog.dart` | 🆕 `_resolveRestoreConflicts(rec)`（解封 / 从归档恢复共用）：无冲突直接还原；有冲突弹确认框（前 5 条 + 汇总数），「替换并继续」（danger 色）/ 取消。两处旧文案「同名的现有文件会被覆盖」移除 |

关键设计：**不提供「合并」**（7z/目录复制覆盖语义是合并=新旧混杂，§22.3 第 4 条）；「替换」的旧档先进回收站，绝不把「替换」做成「丢档」。

### 23.2 打包态引导解包（`e56ef40`）

| 项 | 内容 |
|---|---|
| 落点 | **库页双击主路径**（`library_page.dart` `_handleDoubleTap`，非稳定区） |
| 流程 | `GameStorageState.packed` → 取最新 packed 归档 → 确认框（解包目标**绝对路径** + 归档体积 + 所需空间 + 预计耗时，吞吐按 §6 预算 5–20 MB/s）→ 不可关闭的进度对话框 → `unpack`（服务层守卫：目标存在即拒绝、空间预检、`7z t` 先行）→ 回写 `normal` → 继续既有启动流程 |
| 🆕 | `_unpackPackedGame` + `_unpackEta`；闭包内不可依赖可空局部变量类型提升（`rec.bodyBytes` 在 builder 外先取值，analyzer 抓出后修正） |

🔴 **范围（有意最小化）**：主页/BPM/快捷方式启动入口（`main_container.dart` / `main.dart` —— 均为稳定区；BPM 侧另有只读原则边界）**未接入**。需要开发者显式批准后单独做。

### 23.3 验证

- 进程内 analyzer：全 lib **320 文件 errors=0**，warnings=89 / infos=34 与基线一致（零新增）。
- ⚠️ 未验证：`flutter test`（开发者指示跳过）；真机走查（替换询问观感 / 回收站找回旧档 / 引导解包确认框与进度 / 解包后自动启动闭环）。

## 24. 存档确认 + 归档命名 + 使用说明实施记录（2026-10-03，`b3d1abb`/`7e83576`）

> 开发者真机走查第二轮反馈落地。三项决策 **Q14 / Q15 / Q16**（§14）。

### 24.1 Q14 存档确认（`b3d1abb`）

- **服务层**：`seal()`/`pack()` 加可选参数 `savePaths` —— `null`=沿用自动检测
  （既有调用/测试零破坏）；非 `null`=用户清单照单全收（空=明确不含存档）。
  `_resolveUserPickedPaths`：不存在/读取失败记 warning 跳过不中止，同路径去重。
- **UI**：`_confirmSaveSelection` 在封装/打包确认后、压缩前弹出 —— 自动检测 +
  面板自定义路径（`save_custom_paths_<游戏名>`，此前归档流程从未利用）合并，
  列出路径/标签/大小，默认全选（保持「检测到就压」现状语义），支持勾选 /
  手动添加（校验存在 + 去重）；全不勾 = 明示「本次归档将不包含存档」。
- 封装确认框加「下一步将让你确认要打包的存档」提示。

### 24.2 Q15 归档命名（`7e83576`）

- `newArchiveId(now, state, {title})`：id = `<游戏名>_<时间戳>_<state>`；
  `sanitizeTitleForId` 清洗 `\ / : * ? " < > |`→`_`、截断 40、剔除末尾点/空格；
  空/缺省回退旧格式。旧归档零影响（id 从目录名动态读，不解析格式）。
- 新增 `dev_probe/q15_archive_id_probe.dart`：**源码提取式探针**（sed/python 抽取
  两个静态方法真实实现装配执行，绕开 flutter 依赖）——**6/6 PASS**。

### 24.3 Q16 使用说明（`7e83576`）

- Tab1 顶部可展开说明区（ExpansionTile 默认收起）：功能定位、四动作逐条
  （含 Q13 替换询问提示）、存档确认玩法、与「存档备份」区别、首次使用建议。

### 24.4 验证

- 进程内 analyzer：全 lib **320 文件 errors=0**，warnings=89 / infos=34 基线一致。
- 命名探针 6/6 PASS。注意：未验证 flutter test；真机走查（确认框观感 / 新归档名 / 说明区折叠交互）。

## 25. Phase 5 云备份一期实施记录（2026-10-03，`fbff7ad`/`dad0819`）

> 开发者第三轮反馈「云端上传还没看到」→ 按 §7 Phase 5 定稿开工。

### 25.1 服务层（`fbff7ad`，lib/services/cloud_backup/ 4 文件）

| 文件 | 交付 |
|---|---|
| `cloud_storage_provider.dart` | 抽象接口：对齐 LunaBox 七方法（+onProgress 补强）；CloudObject/CloudStorageException；⛔ 无 flutter 依赖（探针可实测） |
| `webdav_provider.dart` | 一期首选：dart:io HttpClient 原生 PUT/GET/PROPFIND/MKCOL/DELETE + Basic Auth，零第三方依赖；分块上传边发边报进度 |
| `dpapi_helper.dart` | FFI crypt32 DPAPI（per-user 绑定，CRYPTPROTECT_UI_FORBIDDEN）；凭据落盘保护，⛔ 不学 LunaBox 明文 JSON |
| `cloud_backup_service.dart` | 编排：配置持久化（密码恒 DPAPI 密文）/ 上传（云端结构与本地同构 `<备份根>/<gameId>/<归档id>/`，meta.json 重试一次、其余单文件失败即中止防不完整归档）/ 云端列表/删除（幂等）/ 下载回本地归档库（目标已存在即拒绝）/ 云端保留份数清理 |

🔴 **探针抓出生产 bug**：WebDAV PROPFIND 的 href 含 baseUrl 路径段（坚果云
`/dav/`、Nextcloud `/remote.php/webdav/`），解析必须在段序列中**定位
remoteDir 对齐位置**，不能假设直接前缀 —— 回环探针先 FAIL 后修复再全绿。

探针：`phase5_dpapi_probe.dart` **5/5**（往返/随机密钥/base64/篡改必失败）；
`phase5_webdav_probe.dart` **10/10**（本地 HttpServer 模拟 WebDAV 全链路）。

### 25.2 UI 层（`dad0819`）

- 🆕 `settings/cloud_backup_settings_card.dart`：启用开关 → WebDAV 表单
  （地址/账号/密码/备份根）→ 测试连接（用当前表单值，不要求先保存）→ 保存
  → 保留份数 Slider 1..50（50=不清理）。密码框留空 = 保留已存密码。
- settings_modal：「云备份」分组挂载（归档库之后）。
- game_data_dialog：归档条目「上传云端」按钮 → 未配置引导去设置页；
  gameId 空拒绝（云端钥匙 = game_id，Q12 口径）；加法操作无确认框。

### 25.3 一期边界与二期清单（✅ 二期已于同日全部落地，见 §26）

- ✅ 自动同步 → 二期已落地（§26.4，`da64637`/`19602e1`）。（原：一期仅手动触发）
- ✅ S3 兼容 Provider → 二期已落地（§26.1/§26.2，SigV4 官方向量锁定）。
- ✅ 客户端备份密码（二次加密）→ 二期已落地（§26.3，7z 加密外壳）。
- ❌ OneDrive → **评估后不做**：需 Azure 应用注册（client_id 个人开发者
  难维护），且 S3 兼容源已覆盖 OSS/COS/R2/B2 全主流对象存储（§26.5）。
- ✅ 云端归档「下载恢复」UI 入口 → 已落地：落点拍板 = **游戏数据弹窗
  Tab1「云端归档」可展开区块**（云端按 game_id 组织，弹窗正是该游戏
  上下文，下载后与既有「恢复」按钮闭环）（`19602e1`）。

### 25.4 验证

- analyzer 全 lib **325 文件 errors=0**；云备份相关零新增 warning。
- 探针 DPAPI 5/5 + WebDAV 10/10。⚠️ 未验证：真机连坚果云（需真实凭据）；
  flutter test；真机走查（设置卡片表单 / 上传进度 / 云端保留清理）。

## 26. Phase 5 云备份二期实施记录（2026-10-03，`da64637`/`19602e1`）

> 开发者拍板：①「下载恢复」入口落点授权 AI 定 → 游戏数据弹窗云端区块；
> ② 二期清单继续开发、一次收尾。OneDrive 评估后不做（§26.5）。

### 26.1 密码学基座（`sha256_hmac.dart` + `sigv4.dart`）

- pubspec **零新依赖**：SHA-256 + HMAC-SHA256 纯 Dart 自实现（为签名引
  crypto 包不值得，还带 pub get 风险）。
- 探针 `phase5_sha_probe.dart` **9/9 PASS**：NIST FIPS 180-4（空串/abc/
  448bit/1e6 长消息）+ RFC 4231 TC1/2/6/7（含 key>block 先 hash 路径）。
- SigV4 探针 `phase5_s3sig_probe.dart` **9/9 PASS**：**AWS 官方 PUT Object
  测试向量 Authorization 全串逐字节一致**；uriEncode 行为（path 段不编码
  `/`、query 编码、空格 %20 非 +、中文 UTF-8）。
- 决策：`x-amz-content-sha256` 恒 UNSIGNED-PAYLOAD（GB 级流式上传不可逐
  字节 hash）；header 值 trim 不做 URI 编码（boto3 行为；官方 GET+range
  示例的编码写法有争议，不采纳）。

### 26.2 S3 兼容 Provider（`s3_provider.dart`）

- path-style（对 MinIO/R2/自建最友好），PUT/GET/DELETE/ListObjectsV2
  分页循环 + 轻量正则 XML 解析（实体解码）。
- S3 语义差异：目录=key 前缀 → `ensureDir` no-op；递归删除=列全前缀逐个
  DELETE；目录列表 `delimiter=/` 用 CommonPrefixes。
- 🔴 回环探针（`phase5_s3_loop_probe.dart` **10/10 PASS**，本地 HttpServer
  模拟服务端）抓出生产 bug：**真实 S3 的 CommonPrefixes 恒带尾 `/`**，
  目录 path 约定不带尾斜杠，必须剥掉 —— 真机上会导致云端归档目录匹配
  全部失效。

### 26.3 客户端加密（`archive_cryptor.dart`）

- 方案：上传前把归档目录打成**加密 7z**（`-mx=0` 仅存储 + `-mhe=on` 头
  加密），云端单对象 `enc_backup.7z`；下载后自动解密还原。
- 为什么不用 `archive` 包 Zip 加密：全内存，GB 级 OOM；7z 磁盘到磁盘。
- 数据主权：云端物是标准 7z，忘掉本应用也能拿密码用任意 7-Zip 解开。
- 探针 `phase5_crypt_probe.dart` **12/12 PASS**：中文文件名/emoji/嵌套
  子目录/二进制字节级一致/错密码 wrongPassword 语义/进度回调。
- 已知边缘：密码含英文双引号在 Windows 命令行传参有 CRT 转义歧义，
  UI 已提示避免。

### 26.4 自动同步 + UI（`da64637`/`19602e1`）

- `autoSyncIfDue`：对比本地归档库与云端（每游戏最新 keepCount 份），
  差集补传**只增不删**；窗口 startup=每天一次 / 24h / 7d；跑完回写
  lastAutoSyncAt（含全失败 —— 避免每次启动重打失败的网络）。
- 触发点：**库页 initState 延迟 12s**（非稳定区软钩子；🔴 刻意不进
  main.dart/main_container 稳定区）。失败静默，有上传才 snack。
- 设置卡片重写：通道双选 chip（WebDAV/S3）+ S3 表单 + 客户端加密折叠组
  + 自动同步折叠组（频率/立即同步/上次时间）。密码留空=保留已存密文。
- 游戏数据弹窗 Tab1「云端归档」区块：按需加载、下载（带进度）/删除
  （确认框），下载成功刷新本地归档列表与既有「恢复」闭环。

### 26.5 OneDrive 评估结论：不做

- 需要 Azure 应用注册拿 client_id（个人开发者难维护、审核流程不透明）；
- OAuth 设备码流 + refresh token 生命周期管理重；
- S3 兼容源已覆盖 AWS/R2/OSS/COS/B2/MinIO，坚果云 WebDAV 免费且国内
  可达性最好 —— 通道覆盖已足够。

### 26.6 验证

- 进程内 analyzer：全 lib **331 文件 errors=0**；云备份相关零新增
  warning/info（总量 92/35 的 +1/+1 归属并行会话）。
- 探针累计：SHA/HMAC 9/9 + SigV4 9/9 + S3 回环 10/10 + 加密 12/12。
- ⚠️ 未验证：真机连真实 WebDAV（坚果云）/真实 S3（需凭据）；flutter
  test；真机走查（卡片两通道切换 / 云端区块 / 自动同步触发）。

## 附：本方案引用的关键文件索引

| 主题 | 文件 |
|---|---|
| 存档定位/提取 | `lib/services/save_scanner.dart` |
| 存档备份/还原 | `lib/services/save_backup_service.dart` |
| 存档清单（Ludusavi） | `lib/services/save_manifest.dart` |
| 存档备份 UI | `lib/widgets/save_backup_dialog.dart` |
| 解压调度 | `lib/services/extract_manager.dart` |
| 压缩二进制 | `lib/core/path_helper.dart:57` → `runtime/tools/7z.exe` |
| 游戏数据格式/迁移 | `lib/services/game_data_format.dart` |
| 本地注册表 | `lib/services/local_game_registry.dart` |
| 游戏模型（PB 侧，勿混用） | `lib/models/game_model.dart` |
| 本地游戏模型（运行时） | `lib/services/local_game_registry.dart` 的 `LibraryGame` |
| 路径中枢/护栏 | `lib/core/path_helper.dart` |
| 路径校验/磁盘空间 | `lib/services/path_validator.dart` |
| 网络路径/NAS | `lib/utils/network_path.dart` |
| OpenList 客户端 | `lib/services/openlist_service.dart` |
| 体积统计 | `lib/services/file_size_service.dart` |
| 全局任务中心 | `lib/services/global_task_manager.dart` + `lib/pages/install_center_page.dart` |
| 详情窗口 | `lib/widgets/game_detail_dialog.dart` |
| 库页 | `lib/pages/library_page.dart` |
| 设置页 | `lib/widgets/settings_modal.dart` |
| 参考项目 | `其他开发者的项目用于本项目参考/LunaBox-main/` |
