# 功能档案：启动兼容性与提权升级（LAUNCH-COMPAT）

| 项 | 值 |
|----|-----|
| **状态** | 开发中（代码已全量落地，⏳ 真机端到端走查未做） |
| **优先级** | P1 |
| **创建日期** | 2026-10-24 |
| **最后更新** | 2026-10-24 |
| **关联需求单** | 用户口述需求（见 §1），无独立工单 |
| **关联决策** | ADR-019 |

---

## 1. 目标：解决什么问题

用户原话拆成三块：

1. **兼容性属性自动配置** —— 自动为游戏启动程序开启「以兼容模式运行（Windows 8）」+
   「禁止全屏优化」+「替代高 DPI 缩放行为」，除「以管理员身份运行」外**全部静默**，
   不提示不询问；启动管理页提供总开关（默认开），「以管理员身份运行」作为与超分 / 转区
   同级的独立可选项。
2. **超分 / 转区本身提权** —— 让**超分功能**和**转区功能**以管理员权限运行
   （不是「以管理员身份运行游戏进程」这件事），并保证它们在管理员权限下功能完整。
3. **整体梳理** —— 统一启动链路，保证各种启动方式在复杂场景下都稳。

真正的痛点不是「加一个勾选项」，而是**启动链路本身散成了四份**：普通启动、超分启动、
转区启动、托盘启动各写一套 `Process.start`，对「需不需要提权」「UNC 工作目录能不能
给 cmd」「失败怎么兜底」的处理各不相同。加一个「权限」维度后，如果没有唯一裁决点，
必然出现「某条路径能启动、另一条不能」——这类 bug 用户很难描述清楚。

## 2. 用户可见行为

**默认情形（什么都不用做）**
- 双击游戏 → 游戏 exe 的兼容性属性被静默写好（Win8 兼容 + 禁全屏优化 + 高 DPI 替代），
  游戏启动。属性页（右键 exe → 属性 → 兼容性）里能看到这些勾已被勾上。
- 仓库里已有的、用户手动勾别的项（256 色、禁用视觉主题等）**不会被清掉**。

**打开启动管理（右键卡片 → 启动管理 / 或选择启动程序弹窗）**
- 「转区模式」「超分模式」下方新增第三个同级开关 **「以管理员身份运行」**，默认关。
- 下方新增 **「启动兼容性」** 分组，两个开关：
  - **自动配置兼容性属性**（默认开）—— 关掉后本应用写入的注册表标志会被撤销
    （只撤自己写的，用户手设的保留）。
  - **超分 / 转区以管理员身份运行**（默认开）—— 关掉后 Magpie、LEProc 用普通权限起。
- 打开开关的瞬间：注册表立刻写入（不必等下次启动），因此**桌面快捷方式直达 exe
  也带 `RUNASADMIN`**。

**第一次开启管理员开关时（一生一次）**
- 如果管理器自己不是管理员 → 弹一次提示：「建议以管理员身份重启，之后本次开机内
  不再有 UAC」，提供「立即重启 / 暂不重启」。
- 选「暂不重启」→ 之后走 `runas` 逐次弹 UAC，游戏照常启动，只是每次要手动点「是」。
- 选「立即重启」→ 本实例保存状态并退出，1.5s 后以管理员身份自动重启。
- 本提示**只出现一次**（`compat_elevation_hint_shown`），之后永不打扰。

**设置窗口 → 游戏与启动 → 启动兼容性**
- 与弹窗内那两个开关同一份偏好（改一处两处同步）。

## 3. 设计思路：为什么这么做

### 3.1 用 HKCU 兼容性层，而不是改 exe 或做兼容性垫片

`HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers`
值名 = exe 绝对路径，值 = `~ DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE WIN8RTM`。

- 写 **HKCU 不需要管理员权限** ⇒ 天然静默，符合「不弹 UAC」的硬要求。
- 不修改游戏文件（用户明确要求不污染原程序）。
- 属性页 / 注册表双向可见可复原，用户随时能自己关掉，不会变成黑盒。

**被否决**：改 exe 的 manifest（破坏文件完整性、需重签名、游戏更新即失效）；
注入 `__COMPAT_LAYER` 环境变量（只对直接子进程生效，游戏自己再拉 launcher 就断了）。

### 3.2 每次启动前幂等 upsert，不是「仅首次写入」

用户可能在属性页手改、游戏目录会迁移、换启动程序会变。维护一份「我写过了」的状态
一定会过期。每次启动前算一次差集再写（< 5ms，同步 FFI），状态永远和现场一致。

差集规则是**只增删自己负责的标志**（`CompatFlags.outputOrder` 四项）；
`256COLOR` / `DWM8And16BitMitigation` 之类原样保留。

**`~` 不进入 token 列表**：它是「启用兼容模式」的标记，不是版本。解析时单独取
`compatModeEnabled`，序列化时按「有没有任何版本 token」决定要不要输出 ——
否则会出现 `~` 单独存活、属性页显示「以兼容模式运行 Windows 95」的怪状态。

### 3.3 不夺回用户手设的兼容版本

注册表已是 `WIN7RTM` 而我们要 `WIN8RTM` 时：**保留 WIN7RTM**，只记一条 warn。
理由：用户改成 Win7 往往正是因为 Win8 跑不起来，我们强行改回去等于把他刚修好的
环境再弄坏。同理，如果我们以前写过 Win8、被用户改成别的版本，也不再夺回。

### 3.4 记账文件（`data/compat/managed.json`）—— 让「总开关关闭」能真撤销

总开关关掉要「撤销本应用写入过的标志」，但**不能把用户手设的一起删掉**。
所以必须记住「哪些是我加的」：`{"version":1,"entries":{"<exe绝对路径>":["WIN8RTM","HIGHDPIAWARE"]}}`。

回滚只删记录在案的 token，并把 `~` 在「已无任何版本 token」时一并撤掉。

### 3.5 直接 FFI 写注册表，不用 PowerShell

原 `magpie_service._setDpiCompatibility` 用 PowerShell 调 `reg.exe`：冷启动 300–800ms
（每次启动都付）、易被杀软拦、`reg.exe` 在本机安全策略黑名单里。
改 `advapi32!RegSetValueExW` 后是 1–2ms 同步调用，且能在 isolate 之外安全执行。

🔴 `HKEY_CURRENT_USER` 必须写成 **-2147483647**（`0x80000001` 符号扩展后的 32 位值）。
Win64 的 HKEY 是符号扩展的 int32，直接传 `0x80000001` 会被零扩展成无效句柄。

### 3.6 提权：`CreateProcess` 做不到，`ShellExecuteExW + "runas"` 才行

Windows 硬边界（写在这里免得重复踩）：

| 场景 | 手段 | UAC |
|---|---|---|
| 自身已提权 → 起子进程 | `CreateProcess` | **零**（子进程继承提权令牌） |
| 自身未提权 → 起提权目标 | 只能 `ShellExecuteExW` + `runas` 动词 | 必弹一次 |
| 自身未提权 → `CreateProcess` 起提权目标 | **必然失败** `ERROR_ELEVATION_REQUIRED(740)` | — |

`SHELLEXECUTEINFOW` 在 x64 上 **sizeof = 112**（真机实测，写错就是栈破坏）。

⇒ 推论一：**想让用户全程零 UAC，只能让管理器自己提权**。这也是「建议以管理员重启」
这个提示存在的唯一理由 —— 不是强迫，是给一个一劳永逸的选项。

⇒ 推论二：`runas` 拉起的进程与当前进程**没有父子关系**，拿不到 Dart `Process` 对象。
所以提权通道只能返回 PID，不能 `await exitCode`。

### 3.7 超分 / 转区的提权对象是「工具」，但会连带游戏

用户要求是「超分 / 转区**功能本身**以管理员运行，不是游戏进程提权」。但有两处
客观限制必须说清楚（诚实优于假装做到）：

1. **转区无解**：`LEProc.exe` 是游戏的**父进程**，它提权后游戏必然继承管理员令牌。
   除非做降权 token 注入（高危、且会破坏 LE 的 hook），不做。**这是转区提权的固有代价。**
2. **超分必须跟着提权**：游戏提权后是提权窗口，普通权限的 Magpie **捕获不到**
   （`SetWinEventHook` / 窗口句柄访问被 UIPI 挡住），超分会**静默失效**。
   所以 `LaunchProcessLauncher.shouldElevateTool(toolWantsElevation, gameElevated)`
   = 「工具想提权 **或** 游戏提权了」两者取或。

### 3.8 权限裁决只有一个来源

`LaunchProcessLauncher` 是唯一裁决点（`direct` / `elevated` / `shellFallback` 三条通道），
四条启动路径全部改走它。它内部处理：

- 目标是 `.bat/.cmd` ⇒ 走 cmd 包装
- 工作目录是 UNC 且要用 `cmd /c start` ⇒ 必须置 null（cmd 不支持 UNC 作为当前目录）
- `ProcessException.errorCode == 740` ⇒ **自动改走提权通道**（不是回退 cmd，cmd 同样 740）
- 其它失败 ⇒ `cmd /c start` 兜底（历史行为，保留）

### 3.9 二道门：注册表说提权就提权

`magpie_service` 在启动游戏前**再读一次注册表**：如果最终值带 `RUNASADMIN`
（用户手动设过 / 历史残留 / 与 `game.json` 不一致），强制 `elevateGame = true`。
否则 `CreateProcess` 会以 740 失败，而用户看到的只是「超分启动失败」。

### 3.10 托盘启动也收敛到统一入口

原本 `TrayService._launchGame` 直接调 `LocalGameRegistry.launchGame(title)`，
**绕过 `executeLaunch`** —— 后果是托盘启动会**跳过超分模式**（magpie 分支在
`executeLaunch` 里），也没有启动防抖、没有任务横幅、不生成快捷方式。
新增 `GameLaunchService.launchByTitle` 收口，托盘改调它，失败用系统气泡提示
（托盘无对话框上下文）。

## 4. 实现位置

### 新增

| 文件 | 职责 | 备注 |
|------|------|------|
| `lib/services/win32_registry_service.dart` | FFI 注册表读写（仅 HKCU / 仅 REG_SZ），同步、不抛异常 | 读失败返回 null，写失败 false |
| `lib/services/game_compatibility_service.dart` | 兼容性层：解析 / 幂等 upsert / 回滚 / 路径迁移 / 记账 | 核心 |
| `lib/services/compat_preference.dart` | 三个全局偏好 + 懒加载 `ChangeNotifier` | 刻意不接 `main.dart` |
| `lib/services/elevation_service.dart` | 自身/PID 提权判定、`runas` 拉起、自提权重启 | `SHELLEXECUTEINFOW`=112B |
| `lib/services/launch_process_launcher.dart` | 统一进程执行器 + 权限裁决唯一来源 | 三条通道 |
| `lib/widgets/elevation_hint_dialog.dart` | 「建议以管理员重启」一生一次提示 + 延迟提权重启 | 复用 `showConfirmDialog` |
| `test/services/game_compatibility_service_test.dart` | 19 个用例（解析 / 差集 / 路径归一化 / 拼接 / 权限联动） | ⏳ **未跑通（231）** |

### 修改

| 文件 | 改动 |
|------|------|
| `lib/services/game_data_format.dart` | 新增 `runAsAdmin`（读 `run_as_admin`，**不升 format_version**，**不进** `_overwritableFields`） |
| `lib/services/local_game_registry.dart` | `launchGame` 增加**阶段 0.5**（启动前写兼容性）+ 阶段 1 改走执行器 / `launchWithLocale(elevate:)` |
| `lib/services/magpie_service.dart` | `_setDpiCompatibility` 从 PowerShell 改为委托兼容性层（**删除第二套写方**）；`updateGamePaths` 迁移改 `migratePath`；新增 `elevateGame` 参数 + 二道门 + Magpie 提权联动 |
| `lib/services/locale_service.dart` | `launchWithLocale` 新增 `elevate`；提权时用 `runas` 拉 LEProc |
| `lib/services/game_launch_service.dart` | 读 `runAsAdmin` 传入超分；新增 `launchByTitle`（托盘/快捷方式共用） |
| `lib/services/tray_service.dart` | 托盘启动改走 `launchByTitle`，失败弹系统气泡 |
| `lib/widgets/launch_manager_dialog.dart` | 新增「以管理员身份运行」开关 + 「启动兼容性」分组两个开关 + 提权提示接线 |
| `lib/widgets/exe_selector_dialog.dart` | 新增「以管理员身份运行」开关 |
| `lib/widgets/settings_modal.dart` | 游戏与启动 → **启动兼容性**分组（与弹窗同一份偏好） |
| `lib/pages/library_page.dart` | 两处弹窗传入 `initialRunAsAdmin` + 回写回调 |
| `lib/main_container.dart` | 首次启动门禁弹窗同上 |
| `lib/big_picture/big_picture_shell.dart` | BPM 启动管理弹窗同上 |

## 5. 关键数据结构

```dart
// 注册表值（HKCU\...\AppCompatFlags\Layers）
//   值名 = exe 绝对路径（canonicalExePath 归一化后），值 = 空格分隔的标志串
"~ DISABLEDXMAXIMIZEDWINDOWEDMODE RUNASADMIN HIGHDPIAWARE WIN8RTM"

class CompatFlags {
  static const compatModeMarker = '~';                          // 启用兼容模式（非版本！）
  static const win8 = 'WIN8RTM';
  static const disableFullscreenOptimization = 'DISABLEDXMAXIMIZEDWINDOWEDMODE';
  static const highDpiOverride = 'HIGHDPIAWARE';
  static const runAsAdmin = 'RUNASADMIN';
  static const knownCompatVersions = <String>[13 个版本];        // 含 WIN95/WIN98/WIN7RTM…
  static const outputOrder = <String>[                           // 输出顺序（稳定，便于肉眼比对）
    disableFullscreenOptimization, runAsAdmin, highDpiOverride, win8,
  ];
}

/// 目标状态。工厂保证「管理员开关不受总开关管辖」：
factory CompatDesired.resolve({
  required bool autoConfigEnabled,
  required bool runAsAdmin,
}) => CompatDesired(
  win8CompatMode: autoConfigEnabled,
  disableFullscreenOptimization: autoConfigEnabled,
  highDpiOverride: autoConfigEnabled,
  runAsAdmin: runAsAdmin,          // ← 独立，永远只看自己的开关
);

/// ensure() 的返回。action ∈ skip / update / created / fail / unavailable / no-exe
class CompatResult { bool changed; bool ok; String action; String? before, after, detail; }

// 记账：data/compat/managed.json
{"version":1,"entries":{"D:\\Games\\x\\game.exe":["WIN8RTM","HIGHDPIAWARE"]}}

// game.json 新增字段（不升 format_version）
"run_as_admin": false

// 偏好键
compat_auto_config_enabled      // 默认 true
compat_elevation_hint_shown     // 默认 false（一生一次）
launch_tools_run_as_admin       // 默认 true（超分/转区工具提权）
```

## 6. 历史决策与踩过的坑

| 现象 | 根因 | 结论 |
|---|---|---|
| 属性页勾选状态「自己变来变去」 | `magpie_service` 与兼容性层写**同一个注册表值**，各自只写自己那一部分，谁后写谁赢 | 收敛为**一处写方**，`_setDpiCompatibility` 只委托 |
| 注册表里存在永远命中不了的孤儿值 | 历史值里正反斜杠混用（`D:\Chrono Tide\Games/命运石之门/…`）、甚至整段路径重复拼接 | `canonicalExePath` 归一化 + `listValueNames` **大小写不敏感**定位真实值名 |
| `CreateProcess` 报 740 而用户只看到「启动失败」 | exe 自带 `requireAdministrator` manifest 或注册表残留 `RUNASADMIN`，管理器未提权 | 执行器捕获 740 **改走提权通道**（不能用 cmd 兜底，cmd 同样 740） |
| 超分「启动了但没超分」 | 提权游戏的窗口普通权限 Magpie 捕获不到（UIPI），静默失效 | `shouldElevateTool` 强制工具跟随游戏提权 |
| 托盘启动不走超分 | `TrayService` 绕过 `executeLaunch` 直调 `launchGame` | 新增 `launchByTitle` 收口 |
| 「一键重启」后仍是普通权限 | 单实例文件锁：先起新实例 ⇒ 它拿不到锁、写"显示窗口"请求后自杀 ⇒ 旧实例（非提权）被叫醒 | 必须**先排延迟启动、再退出自己**（1.5s 后再 `Start-Process -Verb RunAs`） |

**真机实测数据（`compat_registry_probe.dart`，全部 PASS）**

- `sizeof(SHELLEXECUTEINFOW) = 112`（x64，期望 112）
- 注册表写 → 读回一致 → 覆盖写 → 枚举（71→72）→ 删除（回到 71）
- 中文 / 日文 / 代理对（`𠮷噂`）路径原样往返一致
- 探测后**未留下任何残留**

## 7. 当前进度

- [x] FFI 注册表服务（读写 / 枚举 / 删除，真机往返验证）
- [x] 兼容性层（解析 / 幂等 upsert / 回滚 / 记账 / 路径迁移）
- [x] 偏好中心（总开关 / 工具提权 / 提示一次性）
- [x] 提权服务（判定 / `runas` / 自重启）
- [x] 统一进程执行器（740 兜底 / UNC / cmd 兜底）
- [x] 四条启动路径接入（普通 / 超分 / 转区 / 托盘）
- [x] UI：启动管理 ×2 弹窗 + 设置页 + 提权提示
- [x] 进程内静态分析：16 文件 errors = 0
- [ ] ⏳ 19 个单测用例执行（`flutter test` 被 231 阻断，**一次都没跑过**）
- [ ] ⏳ 真机端到端走查（见 §9）

## 8. 已知问题

| 问题 | 严重度 | 是否已定位 | 备注 |
|---|---|---|---|
| 单测未执行 | 中 | 是 | 环境 `ERROR_PIPE_BUSY(231)`，flutter_tools 必须建管道 ⇒ 本机不可能跑通（见 `.workbuddy/analyze_probe/README.md`） |
| 提权 Magpie 可能杀不掉 | 低 | 是 | 普通权限管理器 `taskkill /IM Magpie.exe` 对提权进程无效 ⇒ 可能残留。**未验证**，必要时改用提权通道杀 |
| 转区提权连带游戏 | 低（设计代价） | 是 | `LEProc.exe` 是父进程，游戏必然继承令牌 |
| 提权重启依赖 PowerShell | 低 | 是 | 组策略禁用 PowerShell 时降级为手动重启提示（已兜底） |

## 9. 待办

- [ ] 环境恢复后跑 `flutter test test/services/game_compatibility_service_test.dart`（19 用例）
- [ ] 真机走查清单：
  1. 双击任意游戏 → 右键 exe 属性 → 兼容性页勾选应为「Windows 8 + 禁用全屏优化 + 高 DPI 替代」
  2. 手设 256 色后再启动 → 256 色**仍在**
  3. 关总开关 → 我们写的标志被撤、用户手设的仍在
  4. 开「以管理员身份运行」→ 弹一次提示 → 选「立即重启」→ 重启后无 UAC 启动游戏
  5. 选「暂不重启」→ 启动弹一次 UAC → 游戏正常
  6. 超分 + 管理员运行 → Magpie 与游戏同权限，超分**实际生效**（不是黑屏/无缩放）
  7. 转区 + 管理员运行 → LEProc 提权、游戏继承、区码生效
  8. 托盘「最近游玩」启动一个配了超分的游戏 → 超分生效
- [ ] 补一条「提权 Magpie 残留」的清理策略

## 10. ⛔ 不要动的地方

- 🔴 **不要给 `~` 加 token 化/反 token 化的对称逻辑** —— 它不在 token 列表里，是推导值。
- 🔴 **不要把 `run_as_admin` 写进 `_overwritableFields`** —— 它是用户累积状态，重复导入不得重置
  （同 `is_blurred` / `storage_state`）。也不升 `format_version`。
- 🔴 **不要在 `magpie_service` 里重新写注册表** —— 兼容性只有 `GameCompatibilityService` 一个写方，
  多写方 = 状态打架（见 §6 第 1 行）。
- 🔴 **不要让 `ensure()` 抛异常** —— 调用点在启动链路上，兼容性配置失败**不允许**阻断启动。
- 🔴 **不要改成「仅首次写入」** —— 见 §3.2。
- 🔴 **不要用 `ShellExecuteExW` 的返回值当「进程已退出」** —— runas 拉起的进程没有父子关系。
- 🔴 **`CompatPreference` 不要接进 `main.dart`** —— 懒加载是刻意的，`main.dart` 是稳定区。
- 🔴 **提权提示的「立即重启」顺序不可交换** —— 必须先 spawn 延迟器再 `exit(0)`（单实例锁）。
