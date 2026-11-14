# 游戏字体替换（换字体）— 接入 CTFontHook 实施方案

> **状态**：方案稿 v1.0（2026-10-16）；**v1.1 改版（2026-10-17 实机反馈后）**：
> 管理器回归「安装器」定位，UI 形态整体重做 —— 详见文末**附录 C**。该节**覆盖**
> §7 Phase 3 的 UI 描述（对话框 → 浮层面板、去掉右键/详情菜单入口、面板改为
> 对齐原工具的字体选择器）；其余章节（机制 / 数据层 / 边界）仍然有效。
> Phase 0 见 `game_font_override_phase0_report.md`（V1/V2/V6 三项地基全 PASS）；
> Phase 1/2/3/4 与 v1.1 见 `DEV_LOG.md` / `SESSION_HANDOFF.md` 的 FONT-HOOK-* 条目。
> 提交：`647da52`(P0) / `28698bb`(P1) / `32653ee`(P2) / `b48475d`(P3) /
> `2625c68`(P4.3) / v1.1 见随后一条 commit。
> 剩余：**真机走查**（真实 galgame 上验证字体生效 / 引导落地 / 批量安装）。
> **配套文档**：`game_font_hook_research.md`（SimpleFontHook 原理调研，2026-10-09）、
> `game_font_hook_decision.md`（决策建议稿，2026-10-09）。
> ⚠️ 上述两份基于 **SimpleFontHook**，本方案基于用户自研分支 **CTFontHook 0.1.1**，
> 结论有实质差异，见 §2.3。**接手前请以本文为准，两份旧稿仅作原理参考。**
> **参考载荷**：`D:\CTLIB\FontHook\CTFontHook`（独立 Git 仓库，MIT，VERSION=0.1.1）
> **适用目录**：`D:\CTLIB`

---

## 0. 结论摘要（TL;DR）

| # | 结论 | 依据 |
|---|---|---|
| 1 | 🔴 **旧调研里最难的「注入通道」整个不需要了**。CTFontHook 的机制就是**把 `winmm.dll` 投放进游戏 exe 同目录**（同名代理劫持），不依赖搜索路径注入 ⇒ 不需要 FFI `CreateProcessW`、不需要 `SetDllDirectory`、不需要 `CREATE_SUSPENDED`、不需要沙箱 | `CTFontHook/README.md:11,29-30`、`CTFontHook/AGENTS.md` |
| 2 | 🔴 **启动链路「零改动」**。DLL 躺在 exe 旁边，游戏自己会加载 ⇒ 6 处 `Process.start` 落点（含 Magpie 超分、LE 转区、托盘逃逸口）**全都不需要改** | `local_game_registry.dart:2716,2736`、`magpie_service.dart:1470`、`locale_service.dart:160`、`tray_service.dart:338` |
| 3 | **已有能力可直接复用**：32/64 位 PE 识别（`locale_service.dart:68`）、进程存活检测（`win32_process_service.dart:370-453`）、备份/还原范式、`game.json` 用户状态字段范式 | 见 §2.2 |
| 4 | 🔴 **必须显式写 `PickerShowOnStartup=0`**，否则游戏内字体面板每次启动都会弹出挡住游戏 | `utils.cpp:29`（默认 true）、`utils.cpp:1109`（默认 1）、`font_picker_lifecycle.cppinc:245` |
| 5 | 🔴 **「导入字体文件（ttf/otf/ttc）」一期做不了**——`FontFileName` 不是 INI 键，`LoadCustomFont` 在它为空时直接 return FALSE | `docs/configuration.md:31-33`、`utils.cpp:599` |
| 6 | **真正需要从零写的只有 3 块**：① 部署编排服务（~300 行 Dart）② INI 生成/解析器 ③ 系统字体枚举 FFI（~200 行） | — |
| 7 | **载荷体积 ≈ 1.2MB**（32bit 590,848B / 64bit 620,544B） | `dist/.../32bit|64bit/winmm.dll` |
| 7b | ⚠️ **【2026-10-17 更正】**两个 DLL **确实是 UPX 加壳**（节表 `UPX0`/`UPX1`）⇒ 旧稿 F2「避免 UPX 误报」**未满足**。见 `game_font_override_phase0_report.md` §2-V9 | Phase 0 实读节表 |
| 8 | **一期范围（用户已拍板）**：标准档；**部署由管理器 Dart 自实现**；**字体枚举走 FFI GDI**；**逐游戏开关、默认关** | 本轮决策 |

### 用户已拍板的四个决策

| 决策项 | 选择 | 含义 |
|---|---|---|
| 部署执行者 | **管理器 Dart 自实现** | 免 UAC；磁盘布局与 CTFontHook 保持一致以便互认；只读目录只提示不自动提权 |
| 一期范围 | **标准档** | 字体族 + 字符集 + 排版微调 + 预览 + 开关 + 一键还原 + 配置回读；**不含**字体文件导入、不含伪装/映射/转码、不含引擎开关 |
| 字体枚举 | **FFI GDI `EnumFontFamiliesExW`** | 与 CTFontHook 内部口径一致，拿到真族名 |
| 生效方式 | **逐游戏开关，默认关** | 与「装了补丁才生效」语义一致 |

---

## 1. 背景与目标

### 1.1 背景

`D:\CTLIB\FontHook\CTFontHook` 是一个面向 Windows 游戏的字体兼容与替换 DLL（`winmm.dll`
代理劫持），已由用户在 SimpleFontHook 基础上独立演进出 0.1.1：具备 17 个引擎适配器、
独立安装器、右键菜单启动器、每游戏清单与备份还原。用户希望把它的能力植入 Chrono Tide，
让玩家在库页就能给游戏换字体，覆盖「游戏启动」与「游戏字体管理」。

### 1.2 目标（一期）

1. 在**库页**给单个游戏开启「字体替换」，之后普通双击启动即静默生效。
2. 在管理器内完成 CTFontHook 字体面板的**主要**配置项：字体族、字符集、排版微调、预览。
3. 完整支持**一键还原**（回到安装前状态，可验证）。
4. 与 CTFontHook 原生工具**互认**：管理器装过的游戏，原工具能看到；原工具装过的游戏，管理器能识别且能还原。

### 1.3 非目标（一期明确不做）

- ❌ 不做沙箱 / 远程注入 / `CREATE_SUSPENDED`（CTFontHook 机制不支持，也无需）。
- ❌ 不做伪装（`EnableCodepageSpoof`）、文字映射（`EnableTextSubstitution`）、
  代码页重定向（`EnableCodepageRedirect`）的 UI。
- ❌ 不做 17 个引擎适配器开关的 UI（保留默认值）。
- ❌ 不做**字体文件导入**（ttf/otf/ttc）——见 §2.4 空白 B1，依赖 CTFontHook 侧小改造。
- ❌ 不改 `magpie_service.dart` / `locale_service.dart` / `tray_service.dart` / `game_launch_service.dart`
  的 spawn 落点。
- ❌ 不改 `windows/runner/` 原生层、不动 `chrono-tide-opensource/`、不动 `lib_backup_*/`。
- ❌ 不自动提权（沿用项目既有惯例）。
- ❌ 不做「全员自动投放」的全局开关。

---

## 2. 现状调研

### 2.1 CTFontHook 侧：机制与可复用面

#### 2.1.1 部署形态（核心事实）

产物名**固定为 `winmm.dll`，不随项目改名**（`CTFontHook/README.md:11`、ADR-0002）——
这是同名代理劫持的硬要求。投放后的游戏目录形态（`installer/main.cpp:591-689`）：

```
<游戏目录>/
├─ <游戏>.exe                  （原有）
├─ winmm.dll                   ← CTFontHook 投放（代理转发到系统 winmm）
├─ FontHook.ini                ← UTF-8 带 BOM，[FontHook] 节
└─ .CTFontHook/                ← 备份目录（常量 kBakDirName，installer/main.cpp:34）
   ├─ manifest.ini             ← UTF-16LE + BOM
   └─ backup/
      ├─ winmm.dll             （仅当原本存在）
      └─ FontHook.ini          （仅当原本存在）
```

`manifest.ini` 字段（`installer/main.cpp:261-278`）：`InstalledAt` / `DllArch`
（`32bit`/`64bit`）/ `HadWinmm`（`0`/`1`）/ `HadIni`（`0`/`1`）。
读取用前缀匹配（`ReadManifestValue`，`installer/main.cpp:280-314`）⇒ **追加自定义键不会
破坏 CTFontHook 的卸载逻辑**，这是我方加 `ManagedBy`/`Sha256` 的合法性依据。

安装前置守卫（`installer/main.cpp:600-689`）：PE 架构识别 → 已有 manifest 则拒装 →
`IsFileLocked` 检测占用（`:244-255`）→ 建备份目录 → 备份原文件 → 投放 → 写 manifest。
卸载（`installer/main.cpp:691-744`）：按 manifest 的 `HadWinmm`/`HadIni` 决定还原还是删除，
然后清空 `.CTFontHook` 目录，**但保留 `FontHook.ini`**（内含玩家设置）。

跨游戏登记：`%APPDATA%\CTFontHook\games.ini`（UTF-16LE + BOM，
`installer/main.cpp:320-517`），字段 `Name`/`Exe`/`Dir`/`DllArch`/`InstalledAt`。

#### 2.1.2 启动器提供的两个关键动词（`launcher/main.cpp`）

| 动词 | 行为 | 对本文的价值 |
|---|---|---|
| `--launch "<exe>" [--show-picker]` | 未安装则先静默调安装器 → `CreateProcessW(游戏exe, cwd=游戏目录)`；`--show-picker` 时给子进程注入环境变量 `CTFONTHOOK_SHOW_PICKER=1` | **证明「环境变量可控制面板是否强制弹出」是官方支持路径**（`:36`、`:128-147`、`:180-186`） |
| `--install` / `--uninstall` | 转交 `CTFontHook-Setup.exe` 静默 CLI（`--quiet` 时只回退出码，`installer/main.cpp:909-939`） | 备选路线（本次未采用，见 §3.1） |

`CTFONTHOOK_SHOW_PICKER` 的消费点：`readonly` 于
`src/ui/internal/font_picker_lifecycle.cppinc:243-253`。

#### 2.1.3 字体面板的显隐判定（🔴 最关键的细节）

`src/ui/internal/font_picker_lifecycle.cppinc:243-253`：

```cpp
bool forceShowPicker = GetEnvironmentVariableW(L"CTFONTHOOK_SHOW_PICKER", ...) > 0;
if (hasSavedConfig && !Config::PickerShowOnStartup && g_toggleHotkeyRegistered && !forceShowPicker) {
    ShowWindow(g_hWnd, SW_HIDE);   // 静默，靠 Insert/Pause/ScrollLock 呼出
} else {
    ShowPickerWindowAnimated(g_hWnd);  // 弹出窗口，抢焦点
}
```

其中 `hasSavedConfig = Utils::LoadConfig(hModule)`（`:211`），而 `LoadConfig` 要求
`FontNameW` 存在，否则返回 false（`utils.cpp:1057-1058`）。

**推论（必须落进实现）**：

| 我方写入的 ini | 判定结果 | 后果 |
|---|---|---|
| 无 `FontNameW` | `hasSavedConfig=false` | 配置不应用 → **换字体完全无效** |
| 有 `FontNameW`，`PickerShowOnStartup=1`（默认） | `!PickerShowOnStartup` 为假 | 🔴 **每次启动都弹出面板挡住游戏** |
| 有 `FontNameW`，`PickerShowOnStartup=0`，热键注册成功 | 隐藏 | ✅ 期望行为 |
| 有 `FontNameW`，`PickerShowOnStartup=0`，**三个热键全被占用** | `g_toggleHotkeyRegistered` 为假 | ⚠️ 还是会弹出（这是 CTFontHook 的 P0-2 兜底设计） |

热键优先级 `Insert` → `Pause` → `Scroll Lock`（`ui/README.md:53`）。

#### 2.1.4 INI 键集（我方需要生成的子集）

键名与默认值的权威来源：`CTFontHook/docs/configuration.md`。要点：

- 解析器**忽略空行、`;`/`#` 注释与节标题**；布尔为整数（`0` 关 / 非 `0` 开）；
  重复键取最后一个；缺失键用源码默认值（`configuration.md:5-12`）。
- **BOM 可选**：读取时跳过存在的 BOM（`utils.cpp:1049-1052`），但 CTFontHook 自己写盘带 BOM
  （`docs/configuration.md:3`）。⇒ 我方写带 BOM 的 UTF-8 以求一致。
- `FontNameW` 是**必需键**（`configuration.md:7`）。
- `FontNameA` 缺失时由 `FontNameW` 转换（`configuration.md:19`）。
- **空的 `FontNameW` 会同时关闭 `EnableFontHook` 与 `EnableFaceNameReplace`**
  （`utils.cpp:1066-1069`、`configuration.md:69`）。

生成子集（另见 §5.3 完整清单）：

```ini
[FontHook]
FontNameW=<族名>
FontNameA=<族名>
EnableFontHook=1
EnableFaceNameReplace=1
EnableCharsetReplace=<0|1>
ForcedCharset=<1|128|129|134|136>
EnableFontHeightScale=.. / FontHeightScale1000=..
EnableFontWidthScale=..  / FontWidthScale1000=..
EnableFontCharSpacing=.. / FontCharSpacing=..
EnableFontLineSpacing=.. / FontLineSpacing=..
EnableFontVerticalMetrics=.. / FontAscentPermille=.. / FontDescentPermille=..
EnableFontWeight=.. / FontWeight=..
PickerShowOnStartup=0     ; 🔴 不可省
EnableDebugLog=0
DebugTraceSampleLimit=0
DebugPickerThreadLogLimit=0
```

字符集常用值（`configuration.md:26`）：`1`=默认、`128`=Shift-JIS、`129`=韩文、
`134`=GB2312、`136`=Big5。

#### 2.1.5 单键控制语义（`configuration.md:37`）

**每项度量都由独立开关控制；数值存在但开关为 `0` 时不应用。** ⇒ 我方 UI 上的
「未修改」状态应写成 `EnableXxx=0`，而不是只写默认数值。

#### 2.1.6 载荷体积与加壳状况（🔴 2026-10-17 更正）

| 产物 | 大小 |
|---|---|
| `dist/CTFontHook-0.1.1-20261016-2056/32bit/winmm.dll` | 590,848 B |
| `dist/CTFontHook-0.1.1-20261016-2056/64bit/winmm.dll` | 620,544 B |
| `dist/CTFontHook-Setup-0.1.1.exe` | 1,674,752 B |

🔴 **更正**：本方案 v1.0 曾按体积推断「未压缩版、无 UPX 误报风险」，**实测节表发现两者
均被 UPX 加壳**（`UPX0`/`UPX1` 节）。⇒ 旧稿 `game_font_hook_decision.md` 的
**F2 决策（避免 UPX 壳被国内杀软误报）并未满足**，需用户决定处置（见 Phase 0 报告 §4-U4）。

### 2.2 Chrono Tide 侧现状

#### 2.2.1 启动链路（结论：**本特性几乎不需要碰**）

| 层 | 位置 | 说明 |
|---|---|---|
| UI 层统一入口 | `lib/services/game_launch_service.dart:253` `executeLaunch` | 7 个入口汇聚于此 |
| 内部编排 | `game_launch_service.dart:318` `_executeLaunchInternal` | — |
| 真正 spawn | `lib/services/local_game_registry.dart:2716-2717`、`:2736-2737` | `Process.start(exe, [], workingDirectory: workDir, mode: detached)` |
| cmd 回退 | `local_game_registry.dart:2723-2724`、`:2744-2745` | UNC 路径不传 cwd |
| Magpie 超分 | `lib/services/magpie_service.dart:1470-1471` | 同上形态 |
| LE 转区 | `lib/services/locale_service.dart:160-171` | `Process.run(LEProc.exe ...)` |
| 托盘逃逸口 | `lib/services/tray_service.dart:338` | ❌ 绕过 `executeLaunch`，直连 `launchGame` |
| 工作目录 | `local_game_registry.dart:2645` | `workDir = exeFile.parent.path` = **游戏 exe 目录** |

🔴 **关键推论**：`workDir` 就是游戏 exe 所在目录，即 `winmm.dll` 的投放目标目录。
游戏加载 `winmm.dll` 走的是「exe 所在目录优先」的 DLL 搜索顺序，
**与谁创建进程无关** ⇒ **Magpie / LE / 托盘 / 快捷方式 / 命令行 全部自动生效，无需任何改动**。

`tray_service.dart:338` 的逃逸口对本特性**无害**（因为注入不在启动路径发生）。
**接手者请勿顺手去修它**——那是独立议题。

#### 2.2.2 已可复用的能力（不要重复造）

| 能力 | 位置 | 复用方式 |
|---|---|---|
| 32/64 位 PE 识别 | `lib/services/locale_service.dart:6`（`enum PeArchitecture{x86,x64,unknown}`）、`:68-112`（`detectPeArchitecture`） | 直接调用；⚠️ 见 §6 性能隐患 |
| PE 常量 | `locale_service.dart:14-18`（`0x014C`/`0x8664`） | — |
| 进程存活 / 目录内进程 | `lib/services/win32_process_service.dart:370-408`（`isProcessAlive`）、`:423-453`（`getProcessesInDirectory`） | 做「游戏运行中拒写」守卫 |
| 备份目录+清单+还原范式 | `lib/services/save_backup_service.dart:75`（`backup.json` 清单）、`:97-179`、`:186-232` | 思路参考（语义不同，见 §2.4-A3） |
| 带重试删除 + 审计日志 | `lib/services/storage/cleanup_utils.dart:24-82`、`:137-203`（`data/cleanup_log.jsonl`） | 卸载/清理用 |
| 移入回收站 | `lib/services/recycle_bin_service.dart:77-139` | 清理我方目录时 |
| 归属护栏 | `lib/core/path_helper.dart:260-281` `isInsideAppStorage` | 我方目录删除前必过 |
| 外部 exe 部署范式 | `打包脚本/一键打包.ps1:353-365`（Locale Emulator）、`:376-391`（Magpie） | 载荷部署照抄 |
| 路径常量范式 | `lib/core/path_helper.dart:27`（`runtimeDir`）、`:79`（`toolsDir`） | 新增 `fontHookDir` |
| 设置类对话框范式 | `lib/widgets/game_detail_dialog.dart:4537`（`_MoveLocationDialog`） | 新对话框照抄三段式 |
| 右键菜单范式 | `lib/widgets/library_context_menu.dart:7,84-112`、`game_detail_dialog.dart:5949`（`_DirectoryActionMenu`） | 加菜单项 |

#### 2.2.3 数据模型

| 项 | 位置 |
|---|---|
| 读写实现 | `lib/services/game_data_format.dart`（`updateGameJson:570`、`updateGameJsonAtomic:632`、`readGameJson:1171`） |
| 字段全集 | `game_data_format.dart:2005-2064`（`toJson`） |
| `_overwritableFields` | `game_data_format.dart:215-263` |
| `format_version` | **`game_data_format.dart:52` → `currentVersion = 4`**（实读，非引用历史文档） |
| `launch_path` 写入/解析 | `:462`、`_toRelativePath:1231-1250`、`resolveLaunchPath:1252-1263` |
| 目录路径语义 | `directory_path`（盘符形态）/ `source_path`（UNC 兜底），`normalizeStoredDirectory:305-342` |
| 解析器 | `lib/utils/game_path_resolver.dart:113`，盘符→UNC→5s 重试→offline（`:185-248`） |
| 存储形态 | **全 JSON，无 SQLite**；游戏数据在 `<exeDir>/Games/<安全标题>/`（`path_helper.dart:88`、`:90`） |

🔴 **`font_override` 绝不能进 `_overwritableFields`**（`game_data_format.dart:251-262` 已列出
必须保留的字段清单），否则「重新抓取元数据」会清空用户的字体设置。
既有同族字段可参照：`storage_state` / `archive_dir` / `archive_at`（`:1836-1855`、`:2057-2059`）。

#### 2.2.4 载荷分发

- `assets/` 清单在 `pubspec.yaml:51-69`；现有二进制有 `assets/tools/{bz.exe,UnRAR.exe,ark.x64*.dll}`。
  **没有**任何 FontHook 产物。
- 两种部署范式并存的既有事实（`打包脚本/一键打包.ps1:315-337` 的注释写得很清楚）：
  - **asset + 运行时释放**（`bz.exe`/`UnRAR.exe`）：`pubspec.yaml` 声明 →
    `extract_manager.dart:303-326` / `rar_lz4_unzip_service.dart:29-63` 首次用时释放到 `runtime/tools/`。
  - **打包脚本直接部署**（`7z.exe`、Locale Emulator、Magpie）：`一键打包.ps1` 复制到 `runtime/<name>/`。
- `runtime/` 不在仓库内，打包期生成。

### 2.3 与 2026-10-09 旧调研的实质差异（务必先读）

| 议题 | 旧调研结论（基于 SimpleFontHook） | 本次结论（基于 CTFontHook 0.1.1） |
|---|---|---|
| 注入通道 | 🔴 **最难一环**：必须自研 FFI `CreateProcessW` + `SetDllDirectory` 沙箱方案，并实测 4 项不确定性 | ✅ **不存在**。CTFontHook 就是投放模式，沙箱方案直接废弃 |
| 沙箱目录 | 建议 `{数据根}/game_sandbox/{game_id}/`，并讨论 NAS 上放哪 | ✅ **不需要**。改为投放进游戏目录 + `.CTFontHook` 备份 |
| 安装/卸载 | 需我方自行设计并实现 | ✅ **已有完整实现**（`installer/main.cpp:600-744`），我方照抄语义即可 |
| 每游戏记账 | 需我方设计 | ✅ 已有 `.CTFontHook/manifest.ini`，且可安全扩展字段 |
| 配置唯一耦合面 | 「INI 键集合」 | ✅ 结论一致，且已收敛到 `docs/configuration.md` 一份文档 |
| UPX 误报（F2） | 需我方用 `SIMPLEFONTHOOK_SKIP_PACK=1` 自构建 | 🔴 **仍未满足**：0.1.1 产物**实为 UPX 加壳**（Phase 0 V9 更正） |
| 字体面板 | 「我方大概率不用」（`game_font_hook_research.md:404`） | ⚠️ **改建制复用**：面板既可在管理器内自建，也可用 `CTFONTHOOK_SHOW_PICKER=1` 调出原面板做高级项兜底 |

> **一句话**：旧调研把 80% 的篇幅花在「怎么把 DLL 弄进进程」，而 CTFontHook 已经把这件事
> 连同安装、备份、还原、登记一起做完了。一期真正的工作量在 **UI + 配置生成 + 字体枚举**。

### 2.4 明确空白（现有能力做不到什么）

**A. Chrono Tide 侧**

| # | 空白 | 影响 | 处置 |
|---|---|---|---|
| A1 | **无任何系统字体枚举能力**（`lib/` 下 `EnumFontFamilies` / `availableFonts` / `systemFonts` 零命中） | 无法给用户列字体 | 新写 FFI，见 §4.5 |
| A2 | 无向游戏目录「就地覆盖 + 记录原文件存在性/哈希 + 原子还原」的现成实现 | — | 新写，语义照抄 `installer/main.cpp:600-744` |
| A3 | `save_backup_service.dart` **语义不同**（它备份的是游戏存档到「按游戏名的备份目录」，不是备份游戏目录里的某个文件） | 误复用它会把语义搞混 | 只借「清单 JSON + 记录原始绝对路径」的结构，不共用代码 |
| A4 | 无 FFI `CopyFileW` / `CreateProcessW` / `SetDllDirectoryW` | — | **本方案不需要**（Dart `File.copy` 足够） |
| A5 | 无注册表**写**能力（只有 `reg.exe` 子进程这一条，仅用于自启，`autostart_service.dart:58`） | — | 本方案不需要（不做 shell 右键菜单） |
| A6 | 无提权能力；游戏启动不提权 | 装到 `Program Files` 的游戏无法投放 | 只提示不自动提权（§7 降级策略） |

**B. CTFontHook 侧（跨仓库协作项，见 §8.4）**

| # | 空白 | 影响 | 建议 |
|---|---|---|---|
| B1 | 🔴 `FontFileName` **不是 INI 键**（`configuration.md:31-33`），且 `LoadCustomFont` 在它为空时直接 `return FALSE`（`utils.cpp:599`） | **管理器无法仅靠写 ini 让游戏使用「用户导入的字体文件」** | **一期不做该功能**；如需，CTFontHook 侧新增 `FontFileName=` 键（约 10 行，见 §8.4-T1） |
| B2 | 无「只读 JSON 状态查询」CLI | 管理器需自己解析 `manifest.ini`（UTF-16LE，不难） | 可选，见 §8.4-T2 |
| B3 | 发布包不含机器可读的 INI 键清单 | 「INI 键集合」这一耦合面只能靠人读文档同步 | 建议 CTFontHook 产出 `config_schema.json`，见 §8.4-T3 |
| B4 | 引擎适配器可通过 `EngineCommon::FindLocalFontFile` **自动**拾取游戏目录里的 `*.ttf/*.otf/*.ttc`（`engine_common.cpp:367-395`） | 说明「丢一个字体文件进目录」对 Artemis/CatSystem2/Mirai/Ren'Py 等引擎**是**有效的，但**通用 GDI 路径无效** | 记入知识库；一期不做 UI |

**C. 未验证项（✅ 2026-10-17 已由 Phase 0 实测，详见 `game_font_override_phase0_report.md`）**

| # | 假设 | 结论 | 对应 Phase 0 |
|---|---|---|---|
| C1 | 管理器手写的 `FontHook.ini`（`PickerShowOnStartup=0`）能让字体静默生效且面板不弹 | ✅ **PASS**（trace 出现 `epoch begin font='…' face=1`，可见窗口 0） | **V1** |
| C2 | Locale Emulator 的注入与 Detours 代理可共存 | ✅ **PASS**（`LEProc.exe <exe>` 下 trace 正常）⇒ **P0-3 证伪** | **V2** |
| C3 | Magpie 超分启动下 `winmm.dll` 代理正常加载 | ⚠️ 逻辑层低风险（加载期早于窗口缩放），留真机 | **V3** |
| C4 | 32/64 位 DLL 放错时的表现可预期 | ✅ **PASS**：**静默无效果、不崩** ⇒ 必须管理器侧拦截 | **V4** |
| C5 | `EnumFontFamiliesExW` 能在 Dart FFI 下正常回调 | ✅ **PASS**（520 族，5 ms） | **V6** |
| C6 | 游戏运行中写 `winmm.dll` 会被系统拒绝 | ✅ **PASS**（覆盖/删除均失败） | **V7** |

**门禁**：V1 / V2 / V6 全 PASS ⇒ 允许进入 Phase 1。

---

## 3. 技术选型

### 3.1 部署执行者：管理器自实现 vs 转交 Setup.exe

| 方案 | 优点 | 缺点 | 判定 |
|---|---|---|---|
| **① 管理器 Dart 自实现**（**采用**） | 常见情况（游戏在 D 盘）**免 UAC**；进度/错误可原生呈现；磁盘布局可与 CTFontHook 完全一致以互认；无外部进程可被阻断 | 需同步维护约 300 行安装逻辑；只读目录需优雅降级 | ✅ **采用** |
| ② 转交 `CTFontHook-Setup.exe` 静默 CLI（`installer/main.cpp:909-939`） | 单一事实源，上游升级即生效 | 🔴 安装器清单为 `requireAdministrator`（`installer/main.cpp:9`）⇒ **每次安装/卸载都必弹 UAC**；进度只能靠退出码；`--quiet` 关闭的只是结果对话框，不是提权 | ❌ 不采用（一期） |
| ③ 混合（默认自实现，不可写时降级调 Setup） | 覆盖最全 | 两条路径都要维护，行为分支变多 | ⏸ 二期可选（§14-Q1） |

**为什么不担心「与 CTFontHook 安装逻辑分裂」**：CTFontHook 的安装逻辑本身极简
（备份 → 复制 → 写 4 个字段的 manifest），且**磁盘布局是唯一的契约**。只要布局一致，
两个工具就能互认；逻辑实现重复的风险可控。

### 3.2 载荷分发：打包脚本部署 vs assets vs 服务器通道

| 方案 | 优点 | 缺点 | 判定 |
|---|---|---|---|
| **① 打包脚本部署到 `runtime/fonthook/`**（**采用**） | 与 Locale Emulator / Magpie **同族范式**（`一键打包.ps1:353-391`）；不占安装包双份体积；改动仅 10 行 | 源码运行（`flutter run`）时载荷不存在，需降级提示 | ✅ **采用**（+ 开发期回退到 `D:\CTLIB\FontHook\CTFontHook\dist\`） |
| ② 进 `assets/` 后运行时释放 | 源码运行也有；与 `bz.exe` 范式一致 | 🔴 安装包**双份携带**（assets 副本 + runtime 副本）= 多付 ~1.2MB；`bz.exe` 那次的注释明确说这是被优化掉的（`一键打包.ps1:316-320`） | ❌ |
| ③ 走服务器静态通道（仿 OpenList） | 可独立更新 DLL，无需发版 | 需把 `openlist_update_core.dart` 从 OpenList 语义抽象成通用组件通道（`componentPackageName` 写死，`:1021`），工作量大；离线不可用 | ⏸ 二期可选（§14-Q2） |

### 3.3 字体枚举：FFI GDI vs 注册表 vs 不做

| 方案 | 优点 | 缺点 | 判定 |
|---|---|---|---|
| **① FFI `gdi32!EnumFontFamiliesExW`**（**采用**） | 拿到的是**真族名**（`FontNameW` 匹配的就是族名）；可按 `lfCharSet` 分组；与 CTFontHook 内部口径一致 | 需写 FFI 结构体 + 回调（~200 行）；回调跨 FFI 边界需谨慎 | ✅ **采用** |
| ② 读 `HKLM\...\Windows NT\CurrentVersion\Fonts` | 零 FFI，实现极简 | 🔴 注册表里是**显示名**（如「微软雅黑」）而非族名（`Microsoft YaHei`）；多重字重/本地化名不一致 ⇒ **用户选完可能静默失效** | ❌ |
| ③ 不做枚举，只支持导入字体文件 | 零 FFI | 与「标准档」目标不符；且导入路径本身一期做不了（§2.4-B1） | ❌ |

参考先例（FFI + 回调类）：`lib/services/gamepad/gamepad_key_recorder.dart:82-91`、
`lib/services/win32_process_service.dart:167-192`。
⚠️ 原生层（`windows/runner/`）虽已有 `quick_window.cpp` 的 `qw_*` 先例
（`CMakeLists.txt:9-18`），但那是**稳定区**，改动需显式批准 ⇒ 一期走 FFI。

---

## 4. 架构设计

### 4.1 分层图

```
┌──────────────────────────────────────────────────────────────────────┐
│ L4 UI 层                                                             │
│  · LibraryContextMenu 新增「更换字体」   lib/widgets/library_context_menu.dart │
│  · _DirectoryActionMenu 新增「更换字体」 lib/widgets/game_detail_dialog.dart:5949│
│  · 新增 GameFontDialog（照抄 _MoveLocationDialog:4537 三段式）        │
└───────────────┬──────────────────────────────────────────────────────┘
                │ 读/写
┌───────────────▼──────────────────────────────────────────────────────┐
│ L2 配置层  GameFontOverride（语义模型） ⇄ FontHookIniCodec（生成/解析）│
│  · 事实源 = game.json 的 font_override（我方语义模型，非 INI 正文）    │
│  · 落盘物 = <游戏目录>/FontHook.ini（派生产物，每次生成）              │
└───────────────┬──────────────────────────────────────────────────────┘
                │ 部署/还原
┌───────────────▼──────────────────────────────────────────────────────┐
│ L1 部署层  GameFontPatchService                                      │
│  probe / install / uninstall / writeConfig / readConfig              │
│  守卫：游戏运行中拒写 · 目录可写性 · 归属护栏 · 架构匹配               │
└───────────────┬──────────────────────────────────────────────────────┘
                │ 读载荷
┌───────────────▼──────────────────────────────────────────────────────┐
│ L0 载荷层  runtime/fonthook/{32bit,64bit}/winmm.dll + version.json    │
│  · 打包脚本部署（仿 Locale Emulator，一键打包.ps1:353-365）           │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ L5 独立能力  Win32FontEnumerator（FFI gdi32!EnumFontFamiliesExW）     │
│  · 独立 isolate + 磁盘缓存 data/cache/system_fonts.json               │
└──────────────────────────────────────────────────────────────────────┘

★ 启动层：零改动。winmm.dll 躺在游戏 exe 旁 ⇒ 游戏自己加载。
  唯一用到环境变量的场景是「打开游戏内面板」（CTFONTHOOK_SHOW_PICKER=1），
  由 L2/L4 自己起进程，不经过既有启动链（§4.6）。
```

### 4.2 L0 载荷层

新增 `PathHelper` 常量（`lib/core/path_helper.dart`，仿 `:27`/`:48`/`:79` 组）：

```dart
// --- CTFontHook 字体替换载荷 ---
static String get fontHookDir      => path.join(runtimeDir, 'fonthook');
static String get fontHookDll32    => path.join(fontHookDir, '32bit', 'winmm.dll');
static String get fontHookDll64    => path.join(fontHookDir, '64bit', 'winmm.dll');
static String get fontHookVersionFile => path.join(fontHookDir, 'version.json');
```

`runtime/fonthook/version.json`（我方元数据，**不是** CTFontHook 的文件）：

```json
{
  "upstream": "CTFontHook",
  "version": "0.1.1",
  "obtained_at": "2026-10-16",
  "license": "MIT",
  "dll": {
    "32bit": { "size": 590848, "sha256": "<构建时填入>" },
    "64bit": { "size": 620544, "sha256": "<构建时填入>" }
  }
}
```

> MIT 合规：我方需在「第三方开源许可」页列出 `CTFontHook (MIT)` 与
> `Microsoft Detours (MIT)`，并保留上游 `LICENSE.txt` 全文。
> （Detours 授权细节见旧稿 `game_font_hook_decision.md` §核查结果 1。）

### 4.3 L1 部署层（`GameFontPatchService`）

**磁盘布局 = 与 `installer/main.cpp:591-744` 逐字节一致**，外加我方扩展键。

| 方法 | 职责 | 关键守卫 |
|---|---|---|
| `Future<PatchProbeResult> probe(String gameDir, String? exePath)` | 判定状态：`notInstalled` / `installedByUs` / `installedByExternal`（有 manifest 但无 `ManagedBy`）/ `staleOrDamaged`（有 manifest 但 `winmm.dll` 缺失或尺寸不符） | 只读，无副作用 |
| `Future<void> install(String gameDir, String exePath)` | 架构探测 → 占用检测 → 建 `.CTFontHook/backup` → 备份 → 投放 → 写 manifest | ① `getProcessesInDirectory` 命中即拒；② 目录可写性预检；③ 架构必须 x86/x64 |
| `Future<void> uninstall(String gameDir)` | 按 manifest 的 `HadWinmm`/`HadIni` 还原或删除 → 清 `.CTFontHook` → **保留 `FontHook.ini`** | 同名文件运行中拒写 |
| `Future<void> writeConfig(String gameDir, GameFontOverride cfg)` | 生成 UTF-8 **带 BOM** 的 `FontHook.ini` | 运行中拒写 |
| `Future<Map<String,String>?> readConfig(String gameDir)` | 解析 `FontHook.ini`（供「游戏内面板改过后回读」） | 只读 |

**`manifest.ini` 写法（UTF-16LE + BOM，与 `WriteManifest` 同格式）**：

```ini
[CTFontHook]
InstalledAt=2026-10-16 23:xx:xx
DllArch=64bit
HadWinmm=1
HadIni=0
ManagedBy=Chrono_Tide          ← 我方扩展键（ReadManifestValue 前缀匹配，不影响 CTFontHook）
ManagedByVersion=1
DllSha256=<投放 DLL 的 sha256>
```

**为什么加 `ManagedBy`**：`probe` 要区分「我方装的」与「用户用原工具装的」，
以决定 UI 文案（「由时汐字体器安装」）。CTFontHook 的 `ReadManifestValue`
只按 `key=` 前缀逐行匹配（`installer/main.cpp:298-312`），多出的键**完全不影响**它。

**卸载后刻意保留 `FontHook.ini`**：与 CTFontHook 行为一致（`installer/main.cpp:735` 的注释
「`FontHook.ini` 若是本工具生成的则保留（内含玩家设置）」）。但**我方需额外把
`font_override.enabled` 置 false**，避免下次自动重装。

### 4.4 L2 配置层

**事实源原则**：`game.json.font_override` = 我方语义模型（唯一事实源）；
`FontHook.ini` = **派生产物**，每次生成，不存内容（避免双份事实源）。

**双向同步策略**（解决「游戏内面板改了，管理器还显示旧值」）：

```
打开 GameFontDialog
  → 读 game.json.font_override（我方模型的兜底）
  → 读 <游戏目录>/FontHook.ini（若存在，以它为准覆盖显示值）
  → 用户改动 → 写 game.json.font_override + 重新生成 FontHook.ini
```

⚠️ INI → 我方模型的**反向映射不是满射**（INI 里可能有引擎专有键、伪装/映射等一期
不呈现的键）。策略：**只回读一期呈现的键，其余键在重新生成时原样保留**（读-改-写，
不做全量覆盖）。这一条是「用户的高级设置在管理器里点一次就被抹掉」的唯一防线。

### 4.5 L5 字体枚举（`Win32FontEnumerator`）

- 符号：`gdi32!EnumFontFamiliesExW`。
- 🔴 **`lfCharSet` 必须取 `1`（DEFAULT_CHARSET）** —— 取 `0xFF` 只返回 4 个 OEM 光栅字体
  （Terminal/Modern/Roman/Script），是本方案 v1.0 的笔误，Phase 0 V6 已实测纠正。
- 结构体：`LOGFONTW`（`LF_FACESIZE=32` ⇒ 结构体 92 字节）、`ENUMLOGFONTEXW`（348 字节）、
  `NEWTEXTMETRICEXW`。一期**只需读 `ENUMLOGFONTEXW.elfLogFont.lfFaceName` 与 `lfCharSet`**。
- 回调：`NativeCallable<...>.isolateLocal`，**必须传 `exceptionalReturn`**（否则编译报错）；
  收集到 Dart `List`，**回调内不得抛异常**（异常穿越 FFI 边界是未定义行为）。
- 实测性能：520 个族名 **4–10 ms**（远优于预算）。
- 过滤：
  - 跳过以 `@` 开头的族名（竖排变体，共 ~40 个，混进列表会让用户困惑）。
  - 按 `lfCharSet` 分组：`134`(GB2312/简中) / `128`(Shift-JIS/日) / `136`(Big5/繁) /
    `1`(DEFAULT，多半是拉丁字体) / `129`(韩)。
- 去重后**排序**，并缓存到 `data/cache/system_fonts.json`，指纹可用
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` 键的最后写入时间；
  一期可简化为「按会话缓存 + 手动刷新按钮」。
- **在独立 isolate 里跑**（`Isolate.run`），结果回填，避免阻塞首帧。

### 4.6 启动层：为什么零改动 + 唯一的例外

**零改动的论证**：

1. `winmm.dll` 被投放进 `<游戏目录>`，即 `workDir`（`local_game_registry.dart:2645`），
   而 `workDir` 也正是 exe 所在目录。
2. Windows DLL 搜索顺序里「**应用程序所在目录**」优先 ⇒ 无论进程由谁创建
   （Dart `Process.start` / `cmd /c start` / `LEProc.exe` / `Magpie.exe`），
   `winmm.dll` 都会被优先加载。
3. ⇒ `magpie_service.dart:1470`、`locale_service.dart:160`、`tray_service.dart:338`
   的 spawn 落点**全都不需要改**。

**唯一的例外：打开游戏内面板**。需要给子进程环境变量 `CTFONTHOOK_SHOW_PICKER=1`
（`font_picker_lifecycle.cppinc:243`）。为严守最小变更，一期**不给既有启动链加参数**，
而是由 `GameFontPatchService.showPickerFor(game)` 自己 `Process.start`：

```dart
await Process.start(
  exePath, const [],
  workingDirectory: exeDir,
  environment: {'CTFONTHOOK_SHOW_PICKER': '1'},  // 与父进程环境合并（默认 includeParentEnvironment=true）
  mode: ProcessStartMode.detached,
);
```

**明确的代价（必须写在 UI 上或注释里）**：这样启动**不记录游戏时长、不登记「运行中」横幅**。
理由：这是低频的「配置」动作而非「游玩」动作，用户往往配置完就退出；
且它换来的是「既有启动链零侵入」。若后续认为不可接受，二期再考虑给
`LocalGameRegistry.launchGame` 加可选 `extraEnv` 参数（§14-Q3）。

### 4.7 降级策略

| 场景 | 行为 |
|---|---|
| 载荷缺失（`runtime/fonthook/` 为空，例如源码运行） | 对话框内显示「字体组件未就绪」，禁用「应用」，不报错 |
| 游戏运行中 | 禁用「应用/还原」按钮，提示「请先关闭游戏」；文案用 `AppSnackBar`（不用 `showDialog`） |
| 游戏目录不可写（`Program Files` 等） | 应用失败后明确提示「无法写入游戏目录，可尝试以管理员身份运行管理器」；**不自动提权**（§1.3） |
| 架构识别为 `unknown`（非 PE / ARM64） | 拒绝安装，提示「无法识别该程序架构」 |
| INI 解析失败 / `FontNameW` 缺失 | 按「未配置」处理，**不覆盖**已有 ini（避免抹掉用户设置） |
| 系统字体枚举失败/超时（>3s） | 列表回退为「手动输入族名」+ 提示「字体列表获取失败」 |
| 游戏以管理员运行而管理器不是 | 沿用既有检测思路（`gamepad_adaptation_session.dart:658-747` 的 `_isProcessElevated`），提示用户 |

---

## 5. 数据模型变更

### 5.1 新增字段：`game.json.font_override`

```json
{
  "font_override": {
    "enabled": true,
    "font_name": "思源黑体 CN",
    "charset": 134,
    "charset_replace": true,
    "metrics": {
      "height_scale": 1000,
      "width_scale": 1000,
      "char_spacing": 0,
      "line_spacing": 0,
      "weight": 400,
      "ascent_permille": 880,
      "descent_permille": -120,
      "enabled": {
        "height": false,
        "width": false,
        "char_spacing": false,
        "line_spacing": false,
        "weight": false,
        "vertical": false
      }
    },
    "patched_at": "2026-10-16T23:30:00+08:00",
    "dll_arch": "64bit",
    "managed_by_us": true
  }
}
```

- 整体可空：缺失 ⇒ 视为「未启用」。
- 内部字段一律可空 + `?? 默认值` 读取。

### 5.2 迁移与版本（🔴 重点，接手者勿改）

| 项 | 决定 | 理由 |
|---|---|---|
| 是否升 `format_version` | **不升**（保持 4，`game_data_format.dart:52`） | `font_override` 是**纯新增、可空**对象字段；老版本读到会忽略；新版本缺失时按「未启用」处理 ⇒ 语义完全兼容。依 **ADR-012**（「纯新增可空字段可不升版本」） |
| ⚠️ 显式例外声明 | **必须在代码注释 + 本文件写明** | ADR-012 字面要求「改 schema 就升版 + 补迁移 + 补测试」。**不升版属显式例外**，写明理由以免后人以为漏做 |
| 是否进 `_overwritableFields` | 🔴 **绝对不进**（`game_data_format.dart:215-263`） | 否则「重新抓取元数据」会清空用户的字体设置。参照既有 `storage_state`（`:251-262` 已明确在保留清单里） |
| 是否需要迁移函数 | 不需要 | 旧文件无该字段，读时 `?? null` 即可 |
| 补测试 | ✅ 需要 | ① 老 `game.json`（无 `font_override`）读写往返不破坏原内容；② `_overwritableFields` 更新后该字段仍保留 |

### 5.3 `FontHookIniCodec`：INI 生成口径（权威表）

生成时**必须**包含下表全部键（缺键会用源码默认值，导致行为不确定）：

| INI 键 | 我方取值 | 默认值（上游） |
|---|---|---|
| `FontNameW` | `font_name`（族名，**必需**） | `galgame` |
| `FontNameA` | 与 `FontNameW` 相同 | `galgame` |
| `EnableFontHook` | `enabled ? 1 : 0` | `0` |
| `EnableFaceNameReplace` | `enabled ? 1 : 0` | `0` |
| `EnableCharsetReplace` | `charset_replace ? 1 : 0` | `0` |
| `ForcedCharset` | `charset`（`1`/`128`/`129`/`134`/`136`） | `1` |
| `EnableFontHeightScale` / `FontHeightScale1000` | `metrics.enabled.height ? 1 : 0` / 值 | `0` / `1000` |
| `EnableFontWidthScale` / `FontWidthScale1000` | 同上 | `0` / `1000` |
| `EnableFontCharSpacing` / `FontCharSpacing` | 同上 | `0` / `0` |
| `EnableFontLineSpacing` / `FontLineSpacing` | 同上 | `0` / `0` |
| `EnableFontWeight` / `FontWeight` | 同上 | `0` / `400` |
| `EnableFontVerticalMetrics` / `FontAscentPermille` / `FontDescentPermille` | 同上 | `0` / `880` / `-120` |
| 🔴 `PickerShowOnStartup` | **恒为 `0`** | `1` |
| `EnableDebugLog` | `0` | `0` |
| `DebugTraceSampleLimit` | `0` | `0` |
| `DebugPickerThreadLogLimit` | `0` | `0` |
| `PreviewTextW` | 可选，**不写**（一期） | — |

**写入格式**：UTF-8 **带 BOM**（`EF BB BF`）、`[FontHook]` 节、`key=value`、`CRLF`。
（读取方跳过 BOM，见 `utils.cpp:1049-1052`；但为与 CTFontHook 的 `SaveConfig`
口径一致，我方也写 BOM。）

**语义陷阱**：
- 每项度量「数值存在但开关为 `0` 时不应用」（`configuration.md:37`）
  ⇒ UI 未修改的项写 `EnableXxx=0`，不要只写默认数值。
- 空 `FontNameW` 会**同时**关闭 `EnableFontHook` 与 `EnableFaceNameReplace`
  （`utils.cpp:1066-1069`）⇒ 「关闭字体替换」的可靠做法是 `EnableFontHook=0` + 保留 `FontNameW`，
  **不要**写空 `FontNameW`（那会让 `LoadConfig` 直接失败）。

### 5.4 我方记录的全局状态

`data/fonthook_state.json`（可选，一期可省略）：

```json
{ "payload_version": "0.1.1", "last_probe_at": "...", "external_games_detected": 3 }
```

> 若需要「读取 `%APPDATA%\CTFontHook\games.ini` 发现用户已用原工具装过的游戏」，
> **只读不写**——避免与原工具形成双写者（这是我方与该文件的关系原则）。

---

## 6. 性能预算

| 操作 | 预算 | 硬要求 |
|---|---|---|
| 载荷存在性检查 | < 5 ms | 同步可接受 |
| PE 架构识别 | < 15 ms | ⚠️ 见下方隐患 |
| 补丁安装（备份 + 复制 ~600KB × 2） | < 120 ms | async，UI 显示进度/禁用按钮 |
| 补丁卸载（还原/删除 + 清目录） | < 120 ms | async |
| 生成 `FontHook.ini`（~30 行） | < 5 ms | 同步可接受 |
| 解析 `FontHook.ini` | < 5 ms | 同步可接受 |
| 系统字体枚举（~200-800 族） | **30–250 ms** | 🔴 **必须在独立 isolate**，禁阻塞首帧；对话内先渲染骨架 + 「正在加载字体…」 |
| `GameFontDialog` 首帧 | < 16 ms | 🔴 硬要求：进对话框时**不做**任何文件 IO 之外的重活；INI 读取 < 5ms 可接受，字体枚举异步 |

**🔴 性能隐患（P1，建议顺手修但需批准）**：
`LocaleService.detectPeArchitecture`（`locale_service.dart:79`）用
`file.readAsBytesSync()` **把整个 exe 读进内存**——只为了读偏移 `0x3C` 处的 4 字节和
`+0x3C+4` 处的 2 字节。对一个 1GB 的 exe，这是 ~1GB 内存峰值 + 数百毫秒。
**建议**：新增（而非修改）只读前 4KB 的变体，例如
`detectPeArchitectureFromHeader(String path)`，FE 直接调新方法；
`LocaleService` 的既有调用点**不动**（避免影响转区链路）。是否改动 `LocaleService` 本体
由用户决定（§14-Q4）。

---

## 7. 实施阶段划分

> **Phase 0 是「技术验证」，先证伪再落地。所有假设均未实测，见 §2.4-C。**

### Phase 0 — 技术验证（不写业务代码，产出「探针报告」）

**方式**：手工把 `dist/CTFontHook-0.1.1-20261016-2056/` 的 DLL 与手写 ini 放进
1-3 个**真实 galgame** 目录，观测结果。**不需要 UI，不需要 Dart 代码。**

| # | 验证项 | 操作 | 判定标准 | 证伪后的退路 |
|---|---|---|---|---|
| **V1** | 🔴 **管理器手写 ini 能否静默生效** | 手写含 `FontNameW` + `PickerShowOnStartup=0` 的 `FontHook.ini`，投放 DLL，直接启动游戏 | ① 字体真的变了 ② 面板**没有**弹出 ③ `FontHook.trace.log`（需 `EnableDebugLog=1`）生成 | 若面板仍弹 ⇒ 改为 `PickerShowOnStartup=0` + 不写 `[FontHook]` 节标题？或引导用户勾选一次；若字体无效 ⇒ 检查 `FontNameW` 是否为**真族名** |
| **V2** | 🔴 **LE 转区 + winmm 代理共存** | 对同一游戏用「日语转区」启动 | 字体生效且无乱码/无崩溃 | 若冲突 ⇒ 转区游戏走「投放 + 引导用户手动点转区」，或列入不支持清单 |
| **V3** | Magpie 超分启动 | 开启超分启动 | 字体生效 | 同理列入不支持清单 |
| **V4** | 架构放错的表现 | 故意给 64 位游戏放 32bit DLL | 观测是「无效果」还是「崩溃」 | 决定拦截强度与文案 |
| **V5** | 路径边界 | 全角/中文路径游戏、NAS(UNC) 路径游戏 | 均正常 | UNC 可能受限 ⇒ 提示用户 |
| **V6** | 🔴 FFI 字体枚举 | 写最小 FFI 探针，`EnumFontFamiliesExW` 取族名 | 能拿到 >100 个族名，含中日文字体 | 退路：改走 `windows/runner` 原生层（需批准）；或临时用注册表方案 |
| **V7** | 运行中写 DLL | 游戏运行中尝试 `File.copy` 覆盖 `winmm.dll` | 应失败（被系统拒绝） | 若成功 ⇒ 守卫必须更严格（加哈希校验） |
| **V8** | 只读目录 | 把测试游戏放到 `C:\Program Files\` 下 | 失败且错误信息可读 | 确认提示文案 |
| **V9** | 载荷加壳状况 | `dumpbin` 或直接看体积判断是否 UPX | 已确认**未压缩**（590KB/620KB） | — （已通过） |
| **V10** | 互认 | 用原工具装一个游戏，再用我方 `probe` 读它的 manifest | 能正确识别为 `installedByExternal` | — |

**Phase 0 的产出**：`docs/DEV/features/game_font_override_phase0_report.md`
（格式参照既有的 `game_storage_state_phase0_report.md`）。

**⛔ 门禁**：V1 / V2 / V6 三项任一证伪，**必须停下来重新评估**，不得进入 Phase 1。

### Phase 1 — 载荷 + 部署层（无 UI，可命令行验证）

1. `PathHelper` 新增 4 个路径常量。
2. `一键打包.ps1` 新增 `--- 5.6 FontHook ---` 节（仿 LE，`:353-365`）：从
   `D:\CTLIB\FontHook\CTFontHook\dist\CTFontHook-<版本>/` 复制
   `32bit/winmm.dll`、`64bit/winmm.dll`，并生成本项目 `version.json`。
3. `GameFontPatchService`：`probe` / `install` / `uninstall` / `writeConfig` / `readConfig`。
4. `FontHookIniCodec`：生成 + 解析（§5.3 口径）。
5. `GameFontOverride` 模型 + `game.json` 读写接线（不进 `_overwritableFields`）。
6. 单元测试（**需开发者在自己的终端补跑**，见 §11）。

### Phase 2 — 字体枚举

1. `Win32FontEnumerator`（FFI）+ 隔离 isolate + 磁盘缓存。
2. 降级路径（枚举失败 → 手动输入族名）。

### Phase 3 — UI（✅ 已完成 2026-10-17）

1. `LibraryContextMenu`（`lib/widgets/library_context_menu.dart`）+ `_DirectoryActionMenu`
   （`game_detail_dialog.dart:5949`）各加一项「更换字体」。
2. `GameFontDialog`（`lib/widgets/game_font_dialog.dart`，三段式，照抄 `_MoveLocationDialog:4537`）：
   状态区（补丁状态 / 架构 / 安装时间 / 运行中·不可写告警 / 载荷版本） / 字体族（可搜索，188px
   虚拟滚动，**用该字体自身渲染样例行**） / 字符集药丸（默认·简中·日文·繁中·韩文）+ 强制替换开关 /
   排版步进器（字高·字宽·字间距·行距·字重，每项独立开关，范围钳制与服务层一致） / 中英日预览 /
   应用 / 还原 / 「打开游戏内面板（高级）」。
3. 首次开启该游戏的确认弹窗 —— 落地为 **入口①**（见下）。

#### 🆕 用户 2026-10-17 新增的两个入口（超出原 §Phase 3 范围，已实现）

**入口① 游戏启动侧「是否安装改字体程序」**（`lib/widgets/font_hook_gate_dialog.dart`）
- 出现时机：**首次启动**某游戏且 `probe == notInstalled` 且未被标记「已决定过」
  （`FontOverridePrefs.isGateAnswered`）且 `gatePromptEnabled` 为真。
- 形态：双勾选（**为「XX」安装改字体程序** / **不再提示**）+ 反作弊·杀软风险告知；
  按钮「暂不使用 / 安装并配置」。
- 勾选后：自动用 `game.json.launch_path` 解析启动程序 → 服务层按 PE 头判位数安装 →
  **装完直接打开「更换字体」对话框**（本次不启动游戏，因为用户还要选字体）。
- 同族入口：`LaunchManagerDialog` 的「字体替换」开关节 + 库页右键菜单「更换字体」+
  详情页目录菜单「更换字体」。
- 🔴 **边界**：`staleOrDamaged`（补丁残缺）**不进**本引导（方案 §10-P2-3 禁「启动路径自动补装」）；
  引导内任何异常一律吞掉并放行启动。

**入口② 库页顶栏「字体」按钮 → 全库字体管理器**（`lib/widgets/library_font_manager_dialog.dart`）
- 位置：`library_page._buildManageButton()` 内、**「筛选」按钮右侧**，**仅编辑模式可见**
  （用户原话「在筛选按钮的右侧」+ 拍板「仅编辑模式可见」）。
- 能力：游戏清单（每行：补丁状态胶囊 / 当前字体（用该字体渲染）/ 「配置」打开单游戏对话框）
  + 顶部批量操作栏（**统一字体**（`FontOverridePrefs` 持久化）/ 统一字符集 / 全选 / 清空 /
  批量还原 / 批量安装并应用）+ 搜索 + 逐台串行执行与结果汇总（失败不阻断后续，
  运行中 / 未设启动程序 / 补丁残缺 / 路径无效 四类跳过原因分别记账）。

### Phase 4 — 收尾与文档（✅ 已完成 2026-10-17）

1. ✅ 更新 `docs/DEV/DEV_LOG.md`、`SESSION_HANDOFF.md`、本文件状态。
2. ✅ 「第三方开源许可」页补 `CTFontHook` + `Microsoft Detours`（`settings_modal.dart`）。
3. ✅ 不兼容游戏清单机制（§10-P0-4）—— 落地形态见下。

#### Phase 4.3 落地形态（用户 2026-10-17 拍板：**纯本地 / 不上报 / 不阻断**）

- **数据源**：`resources/fonthook/incompatible.json`（随包内置；打包脚本
  `--- 5.5 FontHook ---` 节复制到 `runtime/fonthook/`）。当前 `entries` 为**空**
  —— 尚无已知不兼容游戏，不伪造条目。
- **服务**：`lib/services/font_compatibility_service.dart`（进程内单例 + 懒加载，不接
  `main.dart` 稳定区）。匹配规则：标题先过 `TitleCleaner.normalizeForCompare`
  （折叠全半角 / 忽略大小写与标点）后查索引；标题未命中再按 exe 文件名（basename、小写）兜底。
  清单缺失 / 非法 JSON 一律按「无清单」处理，**绝不抛异常、绝不阻断**。
- **接入三处**（全部只读、只提示）：
  1. 单游戏「更换字体」对话框 → 内容区顶部黄色（warn）/ 蓝色（info）提示条；
  2. 全库字体管理器 → 行内游戏名后警告图标 + Tooltip（原因 + 参考链接）；
  3. 首次启动引导 → 「请留意」卡片上方的「已知不兼容」卡片。
- 🔴 **不阻断**：命中的游戏仍可勾选、仍可安装、仍可批量操作；提示文案明确写「仍可继续安装，
  遇到问题可在『更换字体 → 还原』一键恢复」。
- **明确不做**（用户拍板）：不联网拉清单、不向任何后端上报、无「报告不兼容」入口。

---

## 8. 改动文件清单

### 8.1 新增

| 文件 | 职责 | 预估规模 |
|---|---|---|
| `lib/services/game_font_patch_service.dart` | L1 部署编排 | ~300 行 |
| `lib/services/font_hook_ini_codec.dart` | INI 生成/解析 | ~180 行 |
| `lib/models/game_font_override.dart` | L2 语义模型 + JSON 序列化 | ~150 行 |
| `lib/services/win32_font_enumerator.dart` | L5 系统字体枚举 FFI | ~220 行 |
| `lib/widgets/game_font_dialog.dart` | L4 单游戏主对话框 | ~600 行（实交付 ~900） |
| `lib/services/font_override_prefs.dart` | 跨游戏**本机偏好**（统一字体 / 引导决策记录，懒加载） | 🆕 Phase 3（入口①/② 需要） |
| `lib/widgets/library_font_manager_dialog.dart` | L4 全库批量字体管理器（**入口②**） | 🆕 Phase 3 |
| `lib/widgets/font_hook_gate_dialog.dart` | 首次启动安装引导（**入口①**） | 🆕 Phase 3 |
| `lib/services/font_compatibility_service.dart` | 本地「不兼容游戏清单」读取与匹配（只读、不联网、不上报） | 🆕 Phase 4.3（~280 行） |
| `resources/fonthook/incompatible.json` | 清单数据（打包时复制到 `runtime/fonthook/`；当前为空骨架） | 🆕 Phase 4.3 |
| `test/services/font_hook_ini_codec_test.dart` | INI 往返测试 | — |
| `test/services/game_font_patch_service_test.dart` | 部署/还原测试（用临时目录） | — |
| `test/services/font_compatibility_service_test.dart` | 清单解析 / 匹配单测 | 🆕 Phase 4.3 |
| `docs/DEV/features/game_font_override_phase0_report.md` | Phase 0 报告（Phase 0 产出） | — |

### 8.2 修改

| 文件 | 改动 | 说明 |
|---|---|---|
| `lib/core/path_helper.dart` | 新增 `fontHookDir` / `fontHookDll32` / `fontHookDll64` / `fontHookVersionFile`；Phase 4.3 追加 `fontHookCompatFilePath` | 仿 `:48-68` 组 |
| `lib/services/game_data_format.dart` | `toJson`/`fromJson` 增加 `font_override`（**不进** `_overwritableFields:215-263`） | 不升 `format_version`（§5.2） |
| `lib/widgets/library_context_menu.dart` | 新增菜单项 + 回调参数 | `:84-112` 处追加 |
| `lib/pages/library_page.dart` | 转发新菜单回调、挂载 `GameFontDialog` | 参照 `_showContextMenu:2074` 与详情弹窗路径 |
| `lib/widgets/game_detail_dialog.dart` | `_DirectoryActionMenu`（`:5949`）加一项 + `GameDetailDialog` 转发 | 同族语义（与「移动游戏位置」并列） |
| `lib/widgets/launch_manager_dialog.dart` | 「字体替换」开关节（状态 / 开关 / 当前字体 / 「字体设置…」） | 🆕 入口①「启动管理」处 |
| `lib/widgets/settings_modal.dart` | 「开源组件致谢」补 CTFontHook 0.1.1 / Microsoft Detours 4.0.1（均 MIT） | 🆕 Phase 4.2 |
| `打包脚本/一键打包.ps1` | 新增 `--- 5.5 FontHook ---` 部署节（含许可文件复制 + Phase 4.3 的 `incompatible.json` 复制） | **该目录在 `.gitignore:88` 内，本地生效不入库** |
| `pubspec.yaml` | **无改动**（不进 assets，§3.2） | — |

### 8.3 一期**明确不碰**（接手者请勿越界）

| 文件 / 目录 | 原因 |
|---|---|
| `lib/services/local_game_registry.dart`（含 `:2716`/`:2736` spawn 落点） | 投放模式使注入零改动 |
| `lib/services/magpie_service.dart:1470` | 同上 |
| `lib/services/locale_service.dart`（含 `:68` `detectPeArchitecture` 本体） | 复用不改；只读头部变体作为**独立新方法**（§6） |
| `lib/services/tray_service.dart:338` | 逃逸口对本特性无害，**独立议题** |
| `lib/services/game_launch_service.dart` | 同上 |
| `lib/theme/`、`lib/main.dart`、`lib/main_container.dart`、`lib/core/portable_*.dart`、`lib/services/app_state.dart`、`windows/runner/` | 🔴 **稳定区**（`AGENTS.md` §2.4） |
| `chrono-tide-opensource/`、`lib_backup_*/`、`FontHook/CTFontHook/**` | 🔴 禁止（`AGENTS.md` §2.3） |

### 8.4 跨仓库协作项（CTFontHook 侧，用户自有项目）

> 这些**不是**本仓库的改动，是给 CTFontHook 提的需求，用于解除 §2.4-B 的空白。

| # | 需求 | 规模 | 优先级 |
|---|---|---|---|
| **T1** | 新增 INI 键 `FontFileName=`：在 `Config` 声明（`framework.h:86`）、`LoadConfig` 读取（`utils.cpp:1057+`）、`SaveConfig` 写入（`utils.cpp:889` 附近）、`LoadCustomFont` 的 `:599` 判空改为「INI 值非空即可」。**解除 §2.4-B1**，让「导入字体文件」可行 | ~10 行 | 二期前置 |
| **T2** | 新增只读 CLI `--status "<exe>" --json`，输出 `{installed, arch, hadWinmm, hadIni, fontName}` | ~40 行 | 低（我方自己解析 manifest 即可） |
| **T3** | 打包时额外产出 `config_schema.json`（INI 键名/类型/默认值/分组/是否必需/上游版本），我方直接消费 → 把「INI 键集合」这一唯一耦合面变成**数据**而非文档 | ~60 行 | 中（降低长期升级成本） |
| **T4** | `dist/` 直接产出管理器可直接部署的布局（`32bit/`、`64bit/`），或在 `版本.txt` 里给出 SHA-256 | ~5 行 | 低（打包脚本已生成 `32bit/`/`64bit/`，只需补哈希） |

---

## 9. 调用点替换清单

> 🔴 **本清单接近于空，这是设计目标而非遗漏。** 接手者请勿「顺手」去统一启动链路。

| 优先级 | 调用点 | 是否需要改 | 理由 |
|---|---|---|---|
| — | `local_game_registry.dart:2716-2717`（普通启动 `Process.start`） | ❌ **不改** | 投放模式：DLL 已在 exe 旁 |
| — | `local_game_registry.dart:2736-2737`（转区回退 `Process.start`） | ❌ **不改** | 同上 |
| — | `local_game_registry.dart:2723-2724` / `:2744-2745`（cmd 回退） | ❌ **不改** | 同上 |
| — | `magpie_service.dart:1470-1471`（超分） | ❌ **不改** | 同上 |
| — | `locale_service.dart:160-171`（LE 转区） | ❌ **不改** | 同上 |
| — | `tray_service.dart:338`（托盘逃逸口） | ❌ **不改** | 逃逸口影响的是「是否走 `executeLaunch`」，与注入无关 |
| — | `main.dart:790`/`:869`、`shortcut_service.dart:89`、`big_picture_shell.dart:1290` | ❌ **不改** | 同上 |
| **P0** | `library_page.dart:2074`（`_showContextMenu`） | ✅ **改** | 挂新菜单项 → 开 `GameFontDialog` |
| **P0** | `library_context_menu.dart:84-112` | ✅ **改** | 加「更换字体」项 + 新回调参数 |
| **P0** | `game_detail_dialog.dart:5949`（`_DirectoryActionMenu`） | ✅ **改** | 加「更换字体」项 |
| **P1** | `game_data_format.dart:2005-2064` / `:1926` | ✅ **改** | `font_override` 序列化 |
| **P1** | `path_helper.dart` | ✅ **改** | 4 个新常量 |
| **P2** | `一键打包.ps1` | ✅ **改** | 载荷部署节 |

**易漏的非 Widget 路径**：本特性**没有**。因为配置入口只从库页/详情页发起，
配置写盘发生在对话框内，与启动路径解耦。

---

## 10. 风险登记（P0–P3）

| # | 级别 | 风险 | 依据 | 应对 |
|---|---|---|---|---|
| **P0-1** | 🔴 P0 | **忘记写 `PickerShowOnStartup=0`** ⇒ 每次启动都弹出字体面板挡住游戏 | `utils.cpp:29`、`utils.cpp:1109`、`font_picker_lifecycle.cppinc:245` | ① §5.3 把该键标为「恒为 0」；② INI 生成器**硬编码**该值，不暴露给 UI；③ Phase 0 V1 专门验证 |
| **P0-2** | 🔴 P0 | **架构放错 DLL** ⇒ 游戏可能崩溃或静默无效果 | `installer/main.cpp:606-611` 原生工具即据此拒绝 | 严格用 `detectPeArchitecture` 拦截 `unknown`；Phase 0 V4 实测放错表现并据实写文案 |
| **P0-3** | 🔴 P0 | **LE 转区 与 winmm 代理共存未验证**（同为进程注入：LE 用 `SetWindowsHookEx`+`LdrLoadDll`，CTFontHook 用 Detours） | 旧稿 `game_font_hook_decision.md` §核查结果 3；两侧代码均无互斥声明 | Phase 0 **V2**；证伪则转区游戏列入不支持清单并明示 |
| **P0-4** | 🔴 P0 | **杀软 / DRM / 反作弊**：向游戏目录投放同名 DLL 是典型「劫持」特征，可能被误报或触发完整性校验 | `installer/main.cpp:1338` 的提示原文「联网 / 反作弊游戏请谨慎使用」 | ① 首次开启的确认弹窗明确告知（§10-E1）；② 建立不兼容清单收集用户反馈；③ 一键还原必须可靠 |
| **P1-1** | 🟠 P1 | `detectPeArchitecture` 读**整个 exe** 进内存（`locale_service.dart:79`） | 实测代码 | §6 建议新增只读头部变体；由用户决定是否改本体（§14-Q4） |
| **P1-2** | 🟠 P1 | **ini 双向覆盖冲突**：游戏内面板改过后，管理器用旧值全量重写会抹掉用户设置 | — | §4.4「读-改-写 + 只回读一期呈现的键」；§4.3 卸载时保留 `FontHook.ini` |
| **P1-3** | 🟠 P1 | 游戏目录不可写（`Program Files`） | — | 预检 + 明确提示，**不自动提权**（沿用项目惯例） |
| **P1-4** | 🟠 P1 | 热键全被占用时面板会「最小化」而非「隐藏」 | `ui/README.md:53`、`font_picker_lifecycle.cppinc:245` | 在对话框状态区提示「按 Insert / Pause / Scroll Lock 呼出」；Phase 0 V1 一并观测 |
| **P2-1** | 🟡 P2 | 字体**显示名**与**族名**混淆 ⇒ 用户选完静默失效 | `configuration.md` 明确 `FontNameW` 是族名 | 用 `EnumFontFamiliesExW` 拿真族名（§3.3）；不提供「手打族名」以外的自由输入 |
| **P2-2** | 🟡 P2 | 卸载残留审计 | ADR-007 精神 | `.CTFontHook` 目录删除前过 `PathHelper.isInsideAppStorage` 之外，还要**明示真实绝对路径**；清理写 `data/cleanup_log.jsonl` |
| **P2-3** | 🟡 P2 | 用户手动删了 `winmm.dll` / 游戏更新覆盖了它 | — | `probe` 返回 `staleOrDamaged`，详情页显示「补丁缺失」；**启动路径不做自动补装**（避免启动时突发写盘/UAC 失败） |
| **P2-4** | 🟡 P2 | 管理器与原工具双写 `%APPDATA%\CTFontHook\games.ini` | — | 我方**只读不写**该文件（§5.4） |
| **P3-1** | 🟢 P3 | 载荷增加 ~1.2MB | 实测体积 | 可接受；如需减小，二期走服务器通道（§3.2-③） |
| **P3-2** | 🟢 P3 | 上游 CTFontHook 升级需同步 INI 键集 | `game_font_hook_decision.md` §F1 | 固定版本 + 有意识升级；`version.json` 记 SHA-256；建议 CTFontHook 出 `config_schema.json`（§8.4-T3） |
| **P3-3** | 🟢 P3 | 引擎适配器自动拾取游戏目录里的 `*.ttf`（`engine_common.cpp:367-395`）可能让用户困惑「我没配字体但生效了」 | 实读代码 | 记入知识库/FAQ；一期不做 UI |

---

## 11. 验收标准

### 11.1 功能验收

| # | 场景 | 预期 |
|---|---|---|
| F1 | 对一个 64 位 galgame 开启字体替换 → 启动游戏 | 字体变为所选族；**面板不弹出** |
| F2 | 同一游戏，按 `Insert` | 游戏内面板出现（可做高级调整） |
| F3 | 一键还原 | `winmm.dll` 回到原文（存在则还原，不存在则删除）；`FontHook.ini` 保留；`.CTFontHook` 清空 |
| F4 | 用 CTFontHook 原生工具装过的游戏 | 管理器显示「由时汐字体器安装」，且能一键还原 |
| F5 | 管理器装过的游戏 → 打开 CTFontHook-Setup 面板 | 列表里能看到该游戏 |
| F6 | 游戏运行中点「应用」 | 按钮禁用 + 提示先关游戏 |
| F7 | 关掉游戏内面板的字体设置后（或手动改 ini）再打开管理器对话框 | 显示值与 ini 一致（回读生效） |
| F8 | 转区启动 / 超分启动 | 若 Phase 0 通过则字体生效；否则给出明确不支持提示 |
| F9 | 只读目录游戏 | 明确失败提示，不崩不卡 |
| F10 | 非 32/64 位 exe | 拒绝并提示 |

### 11.2 技术验收

```bash
# ① 静态分析（只针对改动的文件；关注**新增的 error**，存量 info/warning 数百条属正常）
./flutter/bin/flutter.bat analyze lib/services/game_font_patch_service.dart \
    lib/services/font_hook_ini_codec.dart lib/models/game_font_override.dart \
    lib/services/win32_font_enumerator.dart lib/widgets/game_font_dialog.dart \
    lib/core/path_helper.dart lib/services/game_data_format.dart

# ② 测试
./flutter/bin/flutter.bat test test/services/

# ③ 改动面自查（关键，防越界）
git status --short
git diff --stat
```

⚠️ **本环境限制**：本机 `flutter test` 可能报 `CreateFile failed 231`（Dart 匿名管道受限，
阵发性、会自愈）⇒ **测试需开发者在自己的终端补跑**。
**跑不了的测试 = 没有测试**，不得记为「已验证」。

**验收基线（不要引用历史数字，当场跑）**：

- `analyze lib` 存量 info/warning 有**数百条**（`AGENTS.md` §4 记录 2026-09-26 实测 543，
  已过时）⇒ **只关注新增 error**。
- 测试基线：先 `git status` 确认工作区是否有他人未提交改动（有则基线必然漂移）。
- 已知在 HEAD 上也失败、**勿当回归**的用例：
  `cover_preview_overlay_test`、`cover_gallery_overlay_test`、`bpm_page_zone_wiring_test`；
  以及 `test/smart_import/`、`game_move_service_test`（flaky）。

### 11.3 git 自查

```bash
git status --short && git diff --stat
# 确认未动 §8.3 的任何文件
```

提交：**一任务一 commit**，只 `git add` 显式文件（**禁 `-A`**）。
⚠️ 本仓 CRLF，`git add` 时 `LF will be replaced by CRLF` 警告属正常。

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
你在 D:\CTLIB（Chrono Tide）工作。开工前必须先完整读：
  1. AGENTS.md（AI 行为宪法：两段式流程、稳定区、最小变更原则）
  2. docs/DEV/SESSION_HANDOFF.md
  3. docs/DEV/features/game_font_override_implementation_plan.md  ← 本任务方案，权威
  4. docs/DEV/features/game_storage_state_implementation_plan.md（照抄它的文档/收尾风格）

任务：按方案实现「游戏字体替换（换字体）」。参考载荷在
D:\CTLIB\FontHook\CTFontHook（独立 Git 仓库，只读，禁止修改）。

铁律（违反即返工）：
- 两段式：先只读审计出《变更计划》等用户批准，再动手。不得扩大范围。
- 🔴 启动链路零改动：不要动 local_game_registry.dart / magpie_service.dart /
  locale_service.dart / tray_service.dart / game_launch_service.dart 的 spawn 落点。
  （方案 §4.6 已论证不需要；tray_service.dart:338 的逃逸口是独立议题，别顺手修。）
- 🔴 FontHook.ini 必须写 PickerShowOnStartup=0，否则每次启动都弹面板挡游戏。
- 🔴 font_override 绝不进 game_data_format.dart 的 _overwritableFields（:215-263）。
- 🔴 不升 format_version（保持 4）；例外理由必须写进代码注释。
- 🔴 不进 pubspec.yaml 的 assets（载荷由打包脚本部署到 runtime/fonthook/）。
- 🔴 稳定区（lib/theme/、main.dart、main_container.dart、lib/core/portable_*.dart、
  app_state.dart、windows/runner/）不动；禁 git gc。
- 引用代码必须给「文件路径:行号」；交付物用简体中文；只报告不改无关隐患。

执行顺序：Phase 0（技术验证，先做 §7 的 V1/V2/V6 三项，产出
docs/DEV/features/game_font_override_phase0_report.md）→ 用户确认 → Phase 1 → 2 → 3 → 4。
V1/V2/V6 任一证伪必须停下来报告，不得继续。

收尾（每阶段都要做）：analyze 只看新增 error → git status/diff 自查 →
DEV_LOG（新条目插在文件头部说明块之后，不是底部 LOG-ENTRIES）→ SESSION_HANDOFF
（更新开头「最后更新」+ 头部插入新 ## 🆕 最新 区块 + 原区块降级为 ## 📦 前一轮）→
features 档案更新 → .workbuddy/memory/YYYY-MM-DD.md 追加（append-only）→
一任务一 commit（只 add 显式文件）→ 诚实地写明「未验证的部分」。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 选项 | 影响 |
|---|---|---|---|
| **Q1** | 「配置字体」这次启动要不要记录游戏时长？ | ① 不记录（一期默认，零侵入）② 给既有启动链加 `extraEnv` 透传参数（改 3-4 个签名） | 一期已按 ① 设计（§4.6）；若用户认为必须记录，需先批准改 ② |
| **Q2** | 载荷更新走哪条路？ | ① 随包固定（一期默认）② 走服务器静态通道（复用 OpenList 通道，需抽象出通用组件层） | 影响二期范围与是否要先重构 `openlist_update_core.dart` |
| **Q3** | 是否要 Phase 0 完成后**先只做「基础档」**上线观察，再补预览与字体文件导入？ | ① 分两步 ② 一次做完标准档 | 影响发版节奏 |
| **Q4** | 是否允许修 `LocaleService.detectPeArchitecture` 读整文件的问题？ | ① 新增只读头部变体，不动本体（默认，最保守）② 直接改本体（更干净，但碰非任务代码） | §6 / §10-P1-1 |
| **Q5** | 转区（LE）游戏若 Phase 0 V2 证伪，产品策略？ | ① 列入不支持清单 ② 引导用户「先关换字体再转区」 ③ 继续投入研究兼容方案 | §10-P0-3 |
| **Q6** | 是否要做「字体文件导入」？ | ① 一期不做（默认）② 先做 CTFontHook 侧 T1 改造（§8.4）再做 | 一期已排除（§1.3）；②会引入跨仓库改动 |
| **Q7** | 是否在「第三方开源许可」页正式列出 CTFontHook + Detours？ | 建议 ✅ | MIT 合规要求保留版权与许可声明 |
| **Q8** | 是否顺带支持「导入字体文件后自动装到系统字体」（Windows 10+ 支持免管理员 per-user 安装）？ | ① 不做 ② 作为「导入字体文件」的替代方案 | 与 CTFontHook 无关，属独立特性 |

---

## 附录 A：本轮核对的关键事实（供追溯）

| 事实 | 出处 |
|---|---|
| 产物名固定 `winmm.dll` | `CTFontHook/README.md:11`、`docs/DEV/DECISIONS.md` ADR-0002 |
| 备份目录 `.CTFontHook`、清单 `manifest.ini` | `installer/main.cpp:34-35` |
| manifest 字段与格式（UTF-16LE+BOM） | `installer/main.cpp:261-278` |
| manifest 读取为前缀匹配（可扩展键） | `installer/main.cpp:280-314` |
| 安装流程与守卫 | `installer/main.cpp:600-689`（占用检测 `:244-255`） |
| 卸载流程（保留 FontHook.ini） | `installer/main.cpp:691-744` |
| 跨游戏登记 `games.ini` | `installer/main.cpp:320-517` |
| CLI 动词与 `--quiet` | `installer/main.cpp:909-939` |
| 启动器注入 `CTFONTHOOK_SHOW_PICKER` | `launcher/main.cpp:36,128-147,180-186` |
| `CTFONTHOOK_SHOW_PICKER` 消费 | `src/ui/internal/font_picker_lifecycle.cppinc:243-253` |
| `PickerShowOnStartup` 默认 1 / 默认 true | `utils.cpp:1109` / `utils.cpp:29` |
| `LoadConfig` 跳过 BOM、要求 `FontNameW` | `utils.cpp:1049-1058` |
| 空 `FontNameW` 关闭两个开关 | `utils.cpp:1066-1069` |
| `FontFileName` 非 INI 键 | `docs/configuration.md:31-33` |
| `LoadCustomFont` 在 `FontFileName` 空时直接返回 | `utils.cpp:599` |
| `FindLocalFontFile` 空参时扫 `*.ttf/*.otf/*.ttc` | `engine_common.cpp:367-395` |
| 度量「开关为 0 不应用」 | `docs/configuration.md:37` |
| 字符集值（1/128/129/134/136） | `docs/configuration.md:26` |
| 热键 Insert→Pause→ScrollLock | `ui/README.md:53` |
| 载荷体积 590,848 / 620,544 B | `dist/CTFontHook-0.1.1-20261016-2056/{32bit,64bit}/winmm.dll` |
| `format_version = 4` | `game_data_format.dart:52`（实读） |
| `_overwritableFields` 位置 | `game_data_format.dart:215-263` |
| PE 识别实现 | `locale_service.dart:6,68-112` |
| 启动 spawn 落点 | `local_game_registry.dart:2716,2736`、`magpie_service.dart:1470`、`locale_service.dart:160` |
| 托盘逃逸口 | `tray_service.dart:338` |
| 进程存活检测 | `win32_process_service.dart:370-408,423-453` |
| 归属护栏 | `path_helper.dart:260-281` |
| 载荷部署范式（LE / Magpie） | `一键打包.ps1:353-365`、`:376-391` |

## 附录 B：本轮**未做**的事（诚实声明）

- ❌ **未写任何业务代码**（本任务为研究/方案，属 `AGENTS.md` §2.2 阶段 A）。
- ❌ **未跑任何测试**（`flutter test` 在本环境受限；且尚未有被测代码）。
- ❌ **未运行 `flutter analyze`**（无新增代码可分析）。
- ❌ **未实测** §2.4-C 的 C1–C6 全部假设 —— 这正是 **Phase 0** 的唯一目的。
  其中 **C1（手写 ini 能否静默生效）** 是整个方案的地基，若为假则方案需重做。
- ❌ **未验证 CTFontHook 的右键菜单功能**（其自身 `docs/DEV/USER_FLOW.md:143` 亦标注
  「已编译通过但尚未真机验证」）。
- ❌ **未核对 `%APPDATA%\CTFontHook\games.ini` 与 CTFontHook-Setup GUI 的实际交互**。
- ⚠️ 本文引用的 CTFontHook 行号基于工作区当前工作树（VERSION=0.1.1，
  `dist` 最新包 `CTFontHook-0.1.1-20261016-2056`）。

---

## 附录 C：v1.1 改版 —— 管理器 = 安装器（2026-10-17 实机反馈后）

### C.1 为什么改

用户实机跑完 Phase 3 后的原话与结论：

1. **定位错了** —— 原版把管理器做成了「字体配置器」，而它本来应当承担
   **安装器**的职责（备份原 `winmm.dll` → 投放正确位数 → 生成 `FontHook.ini`）。
   字体选择与微调的**正路是游戏内字体面板**（启动后按 `Insert`），
   管理器内的面板只是「不用进游戏也能改」的便捷补充。
2. **面板尺寸/形态错了** —— 模态大窗口「碍手碍脚」，与库页「管理」浮层的
   交互语言不一致。
3. **入口太多** —— 右键菜单与详情页目录菜单各挂一个「更换字体」，
   与「安装/管理」的语义混淆。

### C.2 用户拍板的五条改动

| # | 改动 | 落点 |
|---|------|------|
| 1 | 单游戏字体面板**参考 CTFontHook 原生面板**重做（搜索 / 字符集药丸 / 字体列表用自身渲染 / 兼容设置 / 字形微调 / 预览），改成贴按钮展开的浮层（同库页筛选面板） | `lib/widgets/font_picker_panel.dart`（⚠️ v1.2 已按附录 D **改回独立窗口**，文件改名 `font_picker_dialog.dart`） |
| 2 | **移除右键菜单**的「更换字体」项（详情页目录菜单同步移除）；单游戏字体安装管理**全部收进「启动管理」及其延伸的首次启动窗口** | `library_context_menu.dart`、`game_detail_dialog.dart`、`library_page.dart` |
| 3 | 启动管理的字体区块：**不用拉杆**，改「安装 / 恢复」按钮；提示文移到**标题与操作区之间**；从左到右 = 安装/恢复 → 当前字体（未使用显示「原游戏字体」）→ 字体设置（装好后出现） | `launch_manager_dialog.dart` |
| 4 | 启动管理的**程序选择列表显示每个 exe 的组件架构**（32 位 / 64 位），避免装完才发现位数不匹配 | 同上，`_exeArch` |
| 5 | 顶栏「字体」= 全库**字体器管理**（清单 + 批量安装/恢复），**去掉「统一字体」全局配置**概念，改成与批量管理同构的浮层 | `lib/widgets/font_library_panel.dart` |

### C.3 术语约定

- **字体器** = 管理器侧的「字体替换能力」整体（安装 / 恢复 / 管理）。
- **字体程序** = 实际生效的 `winmm.dll`。
- UI 文案统一用「字体器」，不再出现「改字体程序」「字体组件」。

### C.4 兼容设置九键（新增）

原面板「兼容设置」区的三组开关此前未移植，本次补齐并写进 `FontHook.ini`：

| 组 | 键 | 说明 |
|---|---|---|
| 调用 | `EnableCodepageSpoof` / `SpoofFromCharset` / `SpoofToCharset` | 字符集能力伪装（默认 134→128） |
| 映射 | `EnableTextSubstitution` / `TextSubstitutionMode` / `TextSubstitutionCodepage` | 0 日繁 / 1 繁>简 / 2 简>繁；回退代码页 932/936 |
| 转码 | `EnableCodepageRedirect` / `CodepageRedirectFrom` / `CodepageRedirectTo` | 五条预设，见 `FontCompatPresets.redirectPresets` |

- 模型：`FontCompatSettings`（`game.json.font_override.compat`），**纯新增可空字段**，不升 `format_version`。
- 🔴 **越界 `TextSubstitutionMode` 归一化为 0**（不是钳到 2）—— 与 CTFontHook 解析矩阵一致，
  否则回读后会写回 2，把用户手改的 INI 悄悄变成「简>繁」。

### C.5 行为变化（与 v1.0 的差异）

| 场景 | v1.0 | v1.1 |
|---|---|---|
| 首次启动引导勾选安装 | 装完**不启动**，直接弹字体对话框 | 装完**直接放行启动**（字体交给游戏内面板） |
| 安装时写什么字体 | 若没设「统一字体」⇒ 只装 DLL，配置留空 | `FontOverridePrefs.suggestFontName()`：用户默认 → `Microsoft YaHei` → 首个简中 → 首个东亚 → 首个可用 |
| 恢复 | 保留 `fontName`、`enabled=false` | 不变（空 `FontNameW` 会让 `LoadConfig` 整体失败） |
| 全库面板 | 统一字体 + 批量改字形 | 只做安装 / 恢复 / 逐台「字体设置」 |

### C.6 文件变更

**新增**
- `lib/widgets/font_picker_panel.dart`（单游戏字体设置浮层）
- `lib/widgets/font_library_panel.dart`（全库字体器管理浮层）

**删除**
- `lib/widgets/game_font_dialog.dart`
- `lib/widgets/library_font_manager_dialog.dart`

**修改**
- `lib/models/game_font_override.dart`（+`FontCompatSettings` / `FontCompatPresets` / `CodepagePreset` / `FontCharset.pickerLabel`）
- `lib/services/font_hook_ini_codec.dart`（九键读写 + 越界归一化）
- `lib/services/font_override_prefs.dart`（+`suggestFontName()`；`buildDefaultOverride` 保留给单测）
- `lib/widgets/launch_manager_dialog.dart`（字体区块重做 + 程序架构显示）
- `lib/widgets/library_context_menu.dart`（-1 项，高度 248→200）
- `lib/widgets/game_detail_dialog.dart`（目录菜单 -1 项，高度 140→96）
- `lib/widgets/font_hook_gate_dialog.dart`（文案改「字体器」/「安装并启动」）
- `lib/pages/library_page.dart`（顶栏接新面板、引导改为装完即启动、删 `_showGameFontDialog`）

### C.7 验证（本机 `CreateFile failed 231`，走离线双通道）

| 通道 | 结果 |
|---|---|
| 进程内 analyzer（11 文件，含新增单测） | **errors = 0**；4 warning + 1 info **全为存量**（逐条比对 HEAD） |
| 纯 Dart 探针 `ini_compat_probe.dart` | **58 PASS / 0 FAIL** |
| flutter_tester 探针 `probe2.dart` | **46 PASS / 0 FAIL**（W1–W7） |

🔴 **测试专用种子**：`FontPickerSeed` / `FontLibraryPanel.debugSkipLoad` /
`LaunchManagerDialog.debugSkipScan` 三个 `@visibleForTesting` 钩子，原因是
**flutter_tester 的 fake-async 不推进真实文件 IO** ⇒ 异步 bootstrap 永不落地、
正文渲染不出来。生产路径从不传。

### C.8 仍未做

- ⏳ **真机走查**：字体是否真的在游戏里生效、批量安装真实表现、架构徽标是否与
  实际位数一致、游戏内 `Insert` 面板是否正常。
- ⏳ `flutter analyze` / `flutter test`（环境恢复后补跑
  `test/services/font_hook_ini_codec_test.dart` 新增的「兼容设置九键」组）。
- 🟠 存量隐患仍在（未修，待批准）：`library_context_menu.dart` 的 4/5 字标签溢出
  （实测 20px / 38px，Release 下静默错位）、`library_page.dart` 重复的
  `_buildPlaceholderCover()` 死代码。

---

## 附录 D：v1.2 —— 字体选择器改回「窗口」，完全对齐原工具

> 触发：2026-10-17 实机走查（用户带图反馈）。附录 C 的浮层方案被判定失败。

### D.1 三条问题与结论

| # | 用户反馈 | 判定 |
|---|---|---|
| 1 | 浮层「视觉上太丑、太突兀，面板内容设计不合理」 | 贴边浮层把两栏内容压在启动管理面板旁边，互相干扰；左右分栏还把「兼容设置 / 字形微调」挤进窄列 |
| 2 | 「还是设计成窗口，完全按照原工具的字体面板设计」 | 回到**独立窗口**，版式照 CTFontHook 原生字体选择器（单栏竖排） |
| 3 | 「字体设置里不需要恢复按钮」 | 卸载/还原是**安装器**职责，统一收在「启动管理 → 字体替换 → 安装/恢复」 |

### D.2 版式（照原工具，自上而下）

1. 标题栏：`A` 标识 + 「字体选择器」+ 游戏名 + 安装状态 chip + 关闭
2. 搜索框（全宽）
3. 字符集药丸（默认 / 中文 / 日文 / 繁体 / 韩文）+ 右侧「N 款」
4. 字体列表（250 高、正好 5 行）：族名用**该字体自身**渲染 + 字符集小字；当前项左侧蓝条 + 「✓ 已应用」
5. 提示行：点「应用」设为当前方案 · 游戏内 `Insert` 可呼出原生面板实时调
6. 兼容设置（右标 `COMPATIBILITY`）：调用 / 映射 + 转码（后两者同行，与原面板一致）
7. 字形微调 + 「清空调整」：3×3 网格（字宽 / 字高 / 字距、上行 / 下行 / 行距、粗细）
8. 文字预览 + `A-` / `22 px` / `A+` + 蓝框预览区
9. 底栏：字符集 + 当前字体 + 「关闭」/「应用」

### D.3 🔴 字形微调必须带**逐项勾选框**

CTFontHook 的每项度量由独立 `EnableFont*` 开关控制，**数值存在但开关为 false 时不应用**
（`docs/configuration.md:37`）。原面板把开关藏在别处，管理器若只给数值输入框，
用户改完点「应用」= 静默失效。因此网格每格左侧加一个小勾选框，并在第三行右侧写明
「勾选的项目才会生效」。上行 / 下行共用 `vertical`（`EnableFontVerticalMetrics`）。

### D.4 交互口径

- `barrierDismissible: false` —— 点外部不关窗，避免误关丢掉未应用的调整。
- **应用成功后立即回调宿主** `onChanged`（不等关窗），Esc / × 退出也不会漏刷新。
- 关闭即放弃未应用的改动（与原工具一致）；**不再有**「恢复」按钮。
- 字符集药丸写的是 `game.json.font_override.charset`，与兼容设置的「调用」是两件事。
- 窗口尺寸：宽 420–600、高 420–900（随屏幕 clamp），正文可滚动。

### D.5 库页批量管理：勾选角标回到最左侧

v2.7.1 为了让位给左上角的 NSFW 揭示角标，把编辑模式的勾选圈从 `left: 6` 挪到了
`left: 30`（`library_page.dart`），视觉上「明显右移」。v1.2 的处理：

- 编辑模式下 **`NsfwImage(showBadge: false)`**（编辑态不需要揭示能力）；
- 勾选圈回到 `left: 6`，与左下「游玩状态」等角标同一内边距；
- `didUpdateWidget` 增加 `isEditMode` 判据 —— 否则 `_cachedCover` 不重建，`showBadge` 不生效。

### D.6 文件变更（v1.2）

**新增** `lib/widgets/font_picker_dialog.dart`（`FontPickerDialog.open(...)`）

**删除** `lib/widgets/font_picker_panel.dart`

**修改**
- `lib/widgets/launch_manager_dialog.dart`（`_openFontSettings` 去 anchor）
- `lib/widgets/font_library_panel.dart`（`_openPicker` 去 anchor、`_rowBtn` 去掉 `onTapWithBox` 死分支）
- `lib/pages/library_page.dart`（编辑模式勾选角标 + `showBadge`）

### D.7 验证

| 通道 | 结果 |
|---|---|
| 进程内 analyzer（11 文件） | **errors = 0**；4 warning + 1 info 全为存量 |
| flutter_tester 探针 `probe3.dart`（P1–P6） | **22 PASS / 0 FAIL**，并产出窗口实拍 PNG |
| 真机走查 | ⏳ 待用户确认视觉与手感 |

---

## 附录 E：v1.3 —— 两栏布局 + 压缩标题栏（一屏不滚动）

> 触发：2026-10-17 实机走查（用户带图反馈）。附录 D 的单栏竖排被判定
> 「整个窗口需要滚动」，且标题栏占高过多。

### E.1 三条改动

| # | 用户反馈 | 处理 |
|---|---|---|
| 1 | 「缩小顶部标题栏」 | `_header()` 50 → **34**；`A` 标识 22→18、标题 14.5→12.5、状态 chip 与关闭按钮同步收小 |
| 2 | 「兼容设置和字体微调整合在一起左侧一栏」 | 主体由单栏 `SingleChildScrollView` 改 **`Row` 两栏**：左 300 宽 = 兼容设置 + 字形微调；右 = 搜索 + 字符集 + 字体列表 + 预览 |
| 3 | 「整个窗口的内容不需要滑动使用」 | 去掉整页滚动；字体列表高度交给 `Expanded` 自适应；窗口 `730–860 × 470–530` |

### E.2 版式（v1.3）

```
┌ 标题栏 34 ───────────────────────────────────────────┐
│ A 字体选择器 <游戏名>                          [已安装] × │
├───────────────┬──────────────────────────────────────┤
│ 兼容设置 COMPAT│ [搜索]                                │
│  调用 关 中→日  │ 默认 中文 日文 繁体 韩文        N 款   │
│  映射 关 繁简 日│ ┌ 字体列表（Expanded，自滚动）──────┐ │
│  转码 关 UTF-8 │ └──────────────────────────────┘ │
│ 字形微调 清空   │ 提示行                                │
│  字宽 字高      │ 文字预览  A- 22px A+                  │
│  字距 行距      │ ┌─────────────────────────────┐     │
│  上行 下行      │ └─────────────────────────────┘     │
│  [说明卡]       │                                      │
├───────────────┴──────────────────────────────────────┤
│ 字符集 中文(134)   <字体>            [关闭] [应用]      │
└──────────────────────────────────────────────────────┘
```

各段落高度预算（窗口 530 高）：标题 34 + 主体 448 + 底栏 46。
左栏固定内容约 358（兼容 78 + 微调 165 + 说明 62 + 两个标题），余量由
`MainAxisAlignment.spaceBetween` 均分到两处间隙。

### E.3 🔴 三条实现坑

1. **`spaceBetween` 必须先把内容包成「块」**。左栏原本是 7 个平铺 child，
   直接上 `spaceBetween` 会把「标题↔内容」的 4~12px 间距也一起均分，
   标题会被拉离自己的内容。正确做法：`compatBlock` / `metricsBlock` /
   `_leftFootnote()` 三个子项再交给 `spaceBetween`。
2. **列表高度不能写死**。原 `_fontList()` 是 `Container(height: 250)`，
   放进 `Expanded` 会与之冲突；去掉 `height` 后由父级 tight 约束决定。
   代价是必然露半行 —— 用底部 14px 渐变（`_C.bg` 0% → 92%）让它看起来
   是「还有更多」而不是裁切事故。
3. **兼容设置从「映射+转码同行」拆成三行**。原面板一行放得下是因为
   面板更宽；左栏 300 时该行实测溢出。拆分后三组各占一行，语义更清楚。

### E.4 文件变更（v1.3）

**修改** `lib/widgets/font_picker_dialog.dart`
- `build()`：窗口尺寸 + `Row` 两栏
- 新增 `_leftColumn()` / `_rightColumn()` / `_leftFootnote()`
- `_header()` 50 → 34；`_statusChip()` / `_iconBtn()` 同步收小
- `_compatSection()` 三组各占一行
- `_metricsGrid()` 3 列 × 3 行 → **2 列 × 4 行**（第 4 行右侧放「勾选后才生效」）
- `_fontList()` 去掉固定高度 + 底部渐隐；`_metricBox()` 32 → 30

### E.5 验证

| 通道 | 结果 |
|---|---|
| 进程内 analyzer（11 文件） | **errors = 0**；4 warning + 1 info 全为存量 |
| flutter_tester 探针 `probe3.dart` | **22 PASS / 0 FAIL**，`run3.log` 无 overflow / RenderFlex 异常 |
| 窗口实拍 `out_picker.png` | 860×530 逻辑尺寸，两栏对齐、无整页滚动 |
| 真机走查 | ⏳ 待用户确认 |
