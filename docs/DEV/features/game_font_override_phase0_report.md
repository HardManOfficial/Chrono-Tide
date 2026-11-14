# 游戏字体替换 — Phase 0 技术验证报告

> **状态**：✅ 已完成（2026-10-17）。**门禁通过**：V1 / V2 / V6 三项地基全部 PASS。
> **配套**：`game_font_override_implementation_plan.md`（方案，权威）、
> `game_font_hook_research.md` / `game_font_hook_decision.md`（2026-10-09 旧稿，原理参考）。
> **探针源码**：`.workbuddy/probe_fonthook/`（5 个纯 Dart 探针，`dart.exe` 直跑）。
> **载荷**：`D:\CTLIB\FontHook\CTFontHook`（VERSION=0.1.1，
> `dist/CTFontHook-0.1.1-20261016-2056/{32bit,64bit}/winmm.dll`）。

---

## 0. 结论摘要

| # | 验证项 | 结果 | 证据 |
|---|---|---|---|
| **V1** | 🔴 手写 ini 能否静默生效 | ✅ **PASS** | trace 出现 `epoch begin font='SimSun' face=1`，可见窗口 0 个 |
| **V2** | 🔴 LE 转区与 winmm 代理共存 | ✅ **PASS**（**推翻 P0 风险**） | `LEProc.exe <exe>` 下 trace 23124 B，`epoch begin=2` |
| **V3** | Magpie 超分共存 | ⚠️ **逻辑层判定低风险**（留真机） | winmm 于进程初始化即加载，早于 Magpie 的窗口缩放 |
| **V4** | 架构放错的表现 | ✅ **PASS** | 错配 DLL **不被加载**、**进程不崩**（静默无效果） ⇒ 必须提前拦截 |
| **V5** | 中文 / 全角 / 空格路径 | ✅ **PASS** | `测试 全角（吧）！【游戏】\子目录` 下 trace 22956 B |
| **V6** | 🔴 FFI 字体枚举 | ✅ **PASS** | 520 个族名，含中日文，**5 ms** |
| **V7** | 运行中写 DLL | ✅ **PASS** | 已加载时覆盖/删除**均失败**；`FreeLibrary` 后恢复 |
| **V8** | 只读目录 | ✅ **PASS** | `C:\Program Files` 写入 → 错误码 5「拒绝访问」 |
| **V9** | 载荷加壳状况 | 🔴 **纠正**：**确实 UPX 加壳** | 节表 `UPX0`/`UPX1`（方案 §2.1.6 原结论**错误**） |
| **V10** | 与原工具互认 | ✅ **PASS** | manifest UTF-16LE+BOM 双向解析正确 |

**门禁判定**：V1（手写 ini 生效）/ V2（LE 共存）/ V6（FFI 枚举）三项地基**全部 PASS**
⇒ **允许进入 Phase 1**。

---

## 1. 验证方法（重要：如何在不碰真实游戏的情况下验证）

方案原设计 V1/V2/V3 需要「拿真实 galgame 手工观测」。本次改为**隔离沙箱法**，
既不碰用户的真实游戏，又能拿到**机器可判读的硬证据**：

**核心洞察**：劫持是否成立，不需要"看字体变了没有"，只需要证明
① 进程**实际加载的 `winmm.dll` 来自我方投放目录**；② 替换引擎**真的启动**。
这两点在 CTFontHook 自己的 `FontHook.trace.log` 里有明确记录。

**宿主选择**：用一个 Windows 自带的、**静态导入 `winmm.dll`** 的 GUI 小 exe 当靶子，
整体复制到临时目录，旁边放我方 DLL 与手写 ini：

| 宿主 | 结果 |
|---|---|
| `C:\Windows\System32\ProximityUxHost.exe`（286 KB，x64，静态导入 winmm） | ✅ 采用（能驻留） |
| `C:\Windows\System32\mblctr.exe`（843 KB，x64） | ✅ trace 生成（进程随后自退） |
| `C:\Windows\System32\osk.exe` | ❌ 需要提升权限，不可用 |

选宿主的依据：扫描 `C:\Windows\System32` / `SysWOW64` 全部 exe 的导入表，
只有 4 个静态导入 `winmm.dll`（`ProximityUxHost.exe` / `osk.exe` / `mblctr.exe` / `WinSAT.exe`）。

⚠️ **环境坑（重要）**：本机 `ProcessStartMode.normal` 会报
`CreateFile failed 231 / 所有的管道范例都在使用中`；探针一律改用
`ProcessStartMode.inheritStdio` 或 `detached`。（真实启动链路用的是 `detached`，不受影响。）

---

## 2. 逐项证据

### V1 — 手写 ini 能否静默生效 ✅ PASS

探针：`.workbuddy/probe_fonthook/probe_dll_hijack.dart`、`probe_font_apply.dart`

**① DLL 劫持成立**（`probe_dll_hijack.dart`）：沙箱内 `ProximityUxHost.exe` 已加载模块里同时出现

```
D:\CTLIB\.workbuddy\probe_fonthook\v1run\ProximityUxHost.exe\WINMM.dll   ← 我方（沙箱目录）
C:\Windows\System32\winmm.DLL                                            ← 系统（被代理转发）
```

⇒ **「exe 所在目录优先」在真实 Windows 上成立**；代理转发到系统 `winmm` 也正常。
**这是整个方案的地基，已坐实。**

**② 手写 ini 被正确读取并应用**：`FontHook.trace.log` 里的关键行（原样摘录）：

```
[TRACE] process attach module=00007FF987AD0000 exe pid=54080
[DEBUG][HookInstall] FontCreation CreateFontA=on CreateFontIndirectA=on CreateFontW=on CreateFontIndirectW=on CreateFontIndirectExA=on CreateFontIndirectExW=on
[DEBUG][HookInstall] FontResources AddFontResourceA/W=on RemoveFontResourceA/W=on
[DEBUG][HookInstall] CodepageConversion MultiByteToWideChar=on WideCharToMultiByte=on
[TRACE][v0] epoch begin font='SimSun' face=1 charset=0 sizeH=0 scale=1.000 weightOn=0 weight=400 spoof=0 debug=1 slowMs=50
[TRACE][v1] ForceGameRedraw requested font='SimSun' height=1.000 width=1.000 gap=0 asc=880 desc=-120 line=0 weightOn=0 weight=400
```

- `font='SimSun'` = 我方手写 ini 的 `FontNameW` ⇒ **ini 被解析**
- `face=1` = `EnableFaceNameReplace=1` 生效；`charset=0` = `EnableCharsetReplace=0`
- `epoch begin` / `ForceGameRedraw` = **替换引擎真的启动并请求重绘**

**③ 面板未弹出**：枚举该进程可见窗口 → **0 个**（`PickerShowOnStartup=0` 生效）。

> **结论**：方案 §5.3 的「🔴 必须显式写 `PickerShowOnStartup=0`」得到实测支持；
> 我方生成的 ini 口径（UTF-8 **带 BOM** + `[FontHook]` 节 + 上述键集）**可用**。

### V2 — LE 转区与 winmm 代理共存 ✅ PASS（推翻 P0 风险）

探针：`probe_le_magpie.dart` + `probe_le2.dart`

方案原判（P0-3）：LE 用 `SetWindowsHookEx`+`LdrLoadDll`，CTFontHook 用 Detours，
两者都是进程注入，**无互斥声明**，存在冲突风险。

**实测**：用**生产口径**（`lib/services/locale_service.dart:160-171` 的写法，
即 `LEProc.exe <exe>`，**不带任何 flag**）启动沙箱宿主：

```
LEProc.exe "D:\...\lemag\le\host.exe"
第 1s: trace 已生成 23124 B
epoch begin=2
```

⇒ LE 注入的进程里，我方 `winmm.dll` **照常加载、替换引擎照常启动**。
**P0-3 风险证伪，转区游戏无需列入不支持清单。**

> 排查痕迹（供追溯）：`-runas <locale名>` / `-runas <GUID>` / `-run` 三种写法**均无效**
> （LEProc 是 GUI 子系统、静默失败）；只有项目生产代码用的「裸传 exe 路径」口径成功。

### V3 — Magpie 超分共存 ⚠️ 逻辑层判定低风险

Magpie 的作用域是**窗口缩放**（拿到已存在的窗口再放大），而 `winmm.dll` 是
**进程加载期**就被 loader 解析的静态导入 ⇒ Magpie 触碰到窗口时，劫持早已完成。
`Magpie.exe --help` 可正常调起（未阻塞）。

⇒ 判定**低风险**，但**未在真机上用真实游戏 + 真超分跑过**，故不标 PASS。

### V4 — 架构放错的表现 ✅ PASS

探针：`probe_font_apply.dart`（V4b 段）

64 位宿主 + **32 位** `winmm.dll`：进程**正常启动并存活**（4s 内未退出），
`FontHook.trace.log` **未生成** ⇒ DLL **根本没被加载**，游戏表现为**「字体没变」**，
**不会崩溃**。

> **对实现的直接要求**：静默无效果比崩溃更隐蔽 ⇒ **必须在管理器侧用 PE 头拦截**，
> 绝不能让错配 DLL 落到游戏目录。（`LocaleService.detectPeArchitecture` 已具备此能力。）

### V5 — 中文 / 全角 / 空格路径 ✅ PASS

路径：`D:\...\matrix\测试 全角（吧）！【游戏】\子目录\host.exe`
⇒ 投放成功、trace 22956 B、`epoch begin=2`。**中文与全角路径无障碍。**

### V6 — FFI 字体枚举 ✅ PASS

探针：`probe_font_enum.dart`

| 口径 | 结果 |
|---|---|
| `lfCharSet=1`（DEFAULT_CHARSET） | **520 族**（正式采用） |
| `lfCharSet=0`（ANSI） | 469 族 |
| `lfCharSet=134`（GB2312） | 148 族 |
| `lfCharSet=128`（Shift-JIS） | 96 族 |
| `lfCharSet=136`（BIG5） | 70 族 |
| `lfCharSet=255`（OEM） | **4 族**（只有 Terminal/Modern/Roman/Script） |

- **耗时 4–10 ms**（远优于方案预算的 30–250 ms）
- `@` 开头竖排变体 **69 个** ⇒ **过滤确有必要**
- 命中中文字体：`Microsoft YaHei` / `SimSun` / `Microsoft JhengHei` / `MingLiU`
- 命中日文字体：`MS Gothic` / `Yu Gothic` / `MS PGothic`
- 结构体口径：`LOGFONTW`(=92B) / `ENUMLOGFONTEXW`(=348B) 与 C 定义一致
- `NativeCallable<...>.isolateLocal` **必须传 `exceptionalReturn`**（否则编译报错）

> 🔴 **修正方案 §4.5**：`lfCharSet` 必须取 **1（DEFAULT_CHARSET）**，
> 方案里写的 `0xFF` **是错的**（只返回 4 个 OEM 光栅字体）。

### V7 — 运行中写 DLL ✅ PASS

探针：`probe_manifest_and_lock.dart`

| 场景 | 结果 |
|---|---|
| 未加载时覆盖同名 DLL | ✅ 成功（基线） |
| **已加载时覆盖** | ❌ **失败**（`当文件已存在时，无法创建该文件。`） |
| **已加载时删除** | ❌ **失败**（`拒绝访问。`） |
| `FreeLibrary` 后再删 | ✅ 成功 ⇒ 证明是**加载锁**而非权限问题 |

⇒ 「游戏运行中拒写」守卫**必要且有效**。
⚠️ 注意覆盖失败的报错文案是 `ERROR_ALREADY_EXISTS` 风格，**不是**「拒绝访问」，
不能只靠错误码字符串做判断。

### V8 — 只读目录 ✅ PASS

`C:\Program Files\CTLIB_FontHook_Probe` 写入 → **错误码 5「拒绝访问。」**
⇒ 需预检可写性 + 给出可读提示（按方案 §4.7：**不自动提权**）。

### V9 — 载荷加壳状况 🔴 **纠正方案的错误结论**

方案 §2.1.6 依据「文件体积 590 KB / 620 KB、看起来像未压缩版」判定
**「UPX 误报风险已天然满足」**。**本次实读节表，结论相反**：

```
32bit/winmm.dll 节表: UPX0(565248) UPX1(479232) .rsrc(114688)
64bit/winmm.dll 节表: UPX0(606208) UPX1(507904) .rsrc(114688)
```

⇒ **两个 DLL 都是 UPX 加壳**。方案 §0 结论 #7 与 §2.3 表格里
「0.1.1 产物已是大体积未压缩版，无需自构建」**作废**。

**影响与处置**：
- 功能不受影响（V1 已证明能正常加载并工作）；
- 但 `game_font_hook_decision.md` 的 **F2（避免 UPX 壳被国内杀软误报）确实未满足**；
- 处置选项（留给用户决定，见 §4 开放项）：
  ① 接受现状（CTFontHook 原生用户本来就在用加壳版）；
  ② 请 CTFontHook 侧用 `SIMPLEFONTHOOK_SKIP_PACK=1`（或等价开关）产一份**未加壳** DLL；
  ③ 我方自行 UPX 解包后再分发（⚠️ 涉及修改第三方二进制，不推荐）。

### V10 — 与原工具互认 ✅ PASS

按 CTFontHook `WriteManifest` 口径合成 `manifest.ini`（UTF-16LE + BOM），
我方解析器（前缀匹配 `key=`）读取 4 个字段全部正确；
追加 `ManagedBy` / `ManagedByVersion` / `DllSha256` 三个扩展键后，
**原工具口径仍能读到 `DllArch`**（不受影响）。

> ⚠️ **实现提醒**：`dart:convert` **没有** UTF-16LE codec，需手写
> `utf16leEncode/Decode`（按 `String.codeUnits` 逐单元 2 字节小端）。

---

## 3. 对实现方案的修订（Phase 0 产出）

| # | 修订点 | 依据 |
|---|---|---|
| R1 | `EnumFontFamiliesExW` 的 `lfCharSet` 取 **1**（不是 `0xFF`） | V6 |
| R2 | INI 口径确认为 **UTF-8 带 BOM** + `[FontHook]` 节 + `PickerShowOnStartup=0`，**实测可用**，无需退路 | V1 |
| R3 | 载荷**是 UPX 加壳**，方案 §2.1.6 / §0-#7 结论作废 | V9 |
| R4 | 架构错配是**静默无效果**（不崩）⇒ 拦截必须由管理器在**安装前**做 | V4 |
| R5 | 转区（LE）游戏**无需**列入不支持清单 | V2 |
| R6 | manifest 解析需自备 UTF-16LE 编解码 | V10 |
| R7 | 探针/测试环境里 `Process.start` 用 `inheritStdio`/`detached`，**禁用 `normal`** | 环境 |

---

## 4. 仍未验证 / 留给用户的部分（诚实声明）

| # | 事项 | 为什么没做 | 建议 |
|---|---|---|---|
| U1 | **真实 galgame 上的字体目视确认** | 需人眼判断字形变化；沙箱宿主无法反映 galgame 的字体调用特性 | 建议用户拿 1 款游戏（如 `E:\GAL\GAL\白日梦的构想图（白昼夢の青写真）\cs2_cn.exe`，x86）实测一次 |
| U2 | **Magpie 真机超分** | 需真实窗口 + 超分链路 | 建议用户在开超分的情况下启动一次已装补丁的游戏 |
| U3 | **UNC / NAS 路径** | 本机无 NAS 挂载 | 待有 NAS 环境时复验 |
| U4 | **杀软误报实测** | 需装国内杀软 | 关注 UPX 载荷（V9） |
| U5 | 引擎级高级项（伪装 / 映射 / 转码 / 17 引擎开关） | 一期范围外 | 二期 |

**沙箱残留**：`.workbuddy/probe_fonthook/{v1b,lemag,matrix}/` 保留供人工核对，可手动删除。
（`v1run/` 已在探针内自清。）

---

## 5. 附录：探针清单与跑法

| 探针 | 覆盖 | 跑法 |
|---|---|---|
| `probe_font_enum.dart` | V6 | `dart.exe --packages=.dart_tool/package_config.json .workbuddy/probe_fonthook/probe_font_enum.dart` |
| `probe_manifest_and_lock.dart` | V7 / V10 | 同上（换文件名） |
| `probe_dll_hijack.dart` | V1① / V4 | 同上 |
| `probe_font_apply.dart` | V1②③ / V4b | 同上 |
| `probe_le_magpie.dart` / `probe_le2.dart` | V2 / V3 | 同上 |
| `probe_v8.dart` | V8 | 同上 |
| `probe_env_matrix.dart` | V5（+V2/V3/V8 的早期版本） | 同上 |

> 全部为**纯 Dart 探针**（`dart.exe` 直跑，无 Flutter），因为实测
> **`flutter_tester` 下异步文件 IO 与 `Future.delayed` 会挂起**（见 `MEMORY.md` §11）。
