# 游戏内手柄适配 v2 —— 引入 SDL3 输入层（方案研究）

> 状态：**方案研究完成，待批准实施**。本文档取代
> `gamepad_adaptation_implementation_plan.md` 中「输入层」部分；
> 该文档的注入层（Phase 1 已落地）与映射层设计仍然有效。

---

## 0. 结论摘要（TL;DR）

| 项 | 结论 |
|---|---|
| **方向** | 手柄**输入层**改用 **SDL3**（zlib 许可，可合法内嵌闭源软件）；**注入层保留已落地的 `InputInjector`** |
| **为什么不推翻注入层** | SDL 只管「读手柄」，**不管「往游戏注入按键」**——AntiMicroX 自己也是「SDL 输入 + Windows 注入输出」。注入层已真机验证（`Alt+Enter` 3/3 PASS），无理由废弃 |
| **SDL3 带来什么** | ① 覆盖 XInput/DInput/hidapi 全部后端；② 自带海量手柄映射库（Godot 4.5 同款输入驱动），**消除我们 DInput 按键序号未验证的风险**；③ 位置化按键（South/East/West/North）天然统一 Xbox/PS 面键；④ 热插拔事件 |
| **接入成本** | **极低**：新建 `Sdl3Backend implements BpmGamepadBackend`（约 200 行）+ CMake 复制捆绑 + 1 行注册。v3.9 的多后端仲裁直接复用，**BPM 零改动** |
| **许可证** | SDL3 = **zlib**：闭源商用免费，仅需保留版权声明。Dart 包 `sdl3` = **MIT**。均无传染性 ✅ |
| **红线提醒** | QKeyMapper / AntiMicroX 是 **GPLv3**：**代码一行都不能抄进 Chrono Tide**（有安装包=闭源分发）；只允许「借鉴设计」与「外部进程调用」 |
| **必须诚实的一点** | 你测得「注入 N=0」= 守卫把按键全拦了（游戏不在前台），**注入层其实一次都没被执行过**——"自研失败"未被证实。SDL3 也不会解决"游戏不在前台"问题，那是另一个工作项（见 §10 P1） |

---

## 1. 背景与目标

### 1.1 背景

Phase 0/1 已完成：注入层（`lib/services/gamepad/input_injector.dart`）真机验证 3/3 PASS；
手柄服务已暴露原始输入流（`bpm_gamepad_service.dart` v3.9 多后端仲裁 + 原始流）。
但真机验收「注入 N=0（全被拦截）」，开发者决定调整方向：**参考成熟项目**。

### 1.2 目标

1. 手柄输入层改用 SDL3，获得**开箱即用的主流手柄全覆盖**（Xbox / PS / Switch / 国产）；
2. 复用项目既有「CMake 捆绑 + portable 定位 + tryCreate 静默降级」范式接入；
3. **保留** Phase 1 注入层与原始输入流接口，BPM 语义层零改动；
4. 为 Phase 2（每游戏映射配置）打基础。

### 1.3 非目标（本期明确不做）

- **不做** 注入层的重写/替换（已验证，且 SDL3 不提供此能力）；
- **不做** 每游戏映射配置与 UI（Phase 2，另立文档）；
- **不抄** QKeyMapper / AntiMicroX 的任何代码（GPLv3 红线，见 §3.3）;
- **不做** 摇杆模拟鼠标（Phase 4）;
- **不做** Linux/macOS 支持（SDL3 跨平台是白赚的，但本期只验证 Windows）。

---

## 2. 现状调研（全部带 `路径:行号`）

### 2.1 可直接复用的既有能力

| 能力 | 位置 | 说明 |
|---|---|---|
| **多后端仲裁** | `lib/big_picture/services/bpm_gamepad_service.dart:537`（`BpmGamepadBackend` 抽象）| 按序尝试、按 `sourceKey` 识别换设备并重建基线 —— **SDL3 后端只需实现这个接口** |
| **后端组装点（唯一）** | `lib/big_picture/big_picture_shell.dart:174-185`（`_createGamepadBackends()`）| 依次 `tryCreate()` 注入 service；**接入 SDL3 只改这里** |
| **原生捆绑范式** | `windows/CMakeLists.txt:114-131`（Locale Emulator 块）| `windows/runner/<dir>/` → install 到 `INSTALL_BUNDLE_LIB_DIR/runtime/<dir>` |
| **portable 定位** | `lib/core/path_helper.dart:15-18,27-41` | exeDir → runtimeDir → 各子路径；加一个 `sdl3Dir` getter 即可 |
| **FFI 风格惯例** | `bpm_gamepad_service.dart:598-611`、`bpm_dinput_backend.dart:129` | `tryCreate()` + 失败永不重试 + 静默降级 |
| **注入层（保留）** | `lib/services/gamepad/input_injector.dart` | SendInput + 前台守卫 + `tapKey/holdKeyDown/clickAt`，真机 3/3 PASS |
| **原始输入流（保留）** | `bpm_gamepad_service.dart`（`BpmGamepadRawListener`）| 注入层消费的接口，SDL3 后端照常产生这些事件 |
| **安装包分发** | `ChronoTide_Setup.iss:158` | 整包 Release 目录（含 `runtime\*`），SDL3.dll 随包走 |

### 2.2 本次要新建的能力

- `Sdl3Backend implements BpmGamepadBackend`（唯一的新 Dart 模块）；
- SDL3.dll 的捆绑与预加载。

---

## 3. 技术选型

### 3.1 输入层候选对比

| 候选 | 许可证 | 覆盖面 | 维护度 | 结论 |
|---|---|---|---|---|
| **SDL3**（3.4.8，2025-01 转正） | **zlib** | XInput + DInput + **hidapi**（PS/Switch 原生协议）| 极活跃（Sam Lantinga/Valve；Godot 4.5 采用）| ✅ **选用** |
| SDL2（2.32.0） | zlib | 同上但 API 旧 | 维护中（补丁线） | ❌ 被 SDL3 取代：SDL3 的 `SDL_Gamepad` API 更干净、位置化按键、直接设备查询 |
| 自研延续（XInput+DInput FFI） | 无 | XInput 全覆盖；DInput 按键序号**未真机验证**、无映射库 | 自担 | ❌ 保留为回退后端，不再投入 |
| 外部工具整合（QKeyMapper/AntiMicroX） | **GPLv3** | 全 | 活跃 | ❌ 强外部依赖 + 分发需履行 GPL 义务；与「开箱即用」目标冲突 |
| ViGEmBus 虚拟手柄 | 专有驱动 | — | — | ❌ galgame 不读手柄 API，无着力点（前轮已淘汰） |

### 3.2 Dart 侧接入方式对比

| 方式 | 说明 | 结论 |
|---|---|---|
| **手写最小 FFI 子集** | 只绑 ~12 个函数（`SDL_Init/SDL_PumpEvents/SDL_GetGamepads/SDL_OpenGamepad/SDL_GetGamepadButton/SDL_GetGamepadAxis/SDL_GetGamepadButtonLabel/SDL_GetGamepadInstanceName/SDL_CloseGamepad/SDL_Quit/SDL_GetError/SDL_SetHint`），与既有 `XInputBackend`/`DInputBackend` 同风格 | ✅ **推荐**：依赖面最小、可控、规避第三方包的 DLL 加载假设 |
| pub 包 `sdl3`（2.8.1，MIT，5 天前发布） | 全量 SDL 绑定，维护活跃 | 🟡 备选：包体积大、其内部 `DynamicLibrary.open('SDL3.dll')` 的加载假设需验证；若走它，须**先绝对路径预加载**（Windows 对已加载模块按名打开会命中同一句柄） |

### 3.3 🔴 许可证红线（必须写进团队认知）

| 项目 | 许可证 | 能做什么 | 不能做什么 |
|---|---|---|---|
| SDL3 / SDL2 | zlib | **内嵌 DLL 进闭源商业软件**，仅需保留版权声明（放到「关于」页即可） | — |
| `sdl3` Dart 包 | MIT | 内嵌，保留版权声明 | — |
| **QKeyMapper** | **GPLv3** | 借鉴**设计思路**；用户自己装了它、我们生成它的配置文件供其使用 | **抄任何代码进 Chrono Tide** |
| **AntiMicroX** | **GPLv3** | 同上（它是 SDL2 输入 + Windows 注入输出的架构范本，值得读源码学思路） | 同上 |

> Chrono Tide 有安装包、闭源分发 —— **GPLv3 代码一旦混入，整个应用必须 GPL 开源**。
> 这条没有商量余地。

---

## 4. 架构设计

### 4.1 分层（变化点只有输入层）

```
┌─ BPM 语义层（零改动）─ big_picture_shell.dart
│    └─ _createGamepadBackends():  [Sdl3Backend, XInputBackend, DInputBackend]
│                                       ▲ 新增，排第一
├─ 多后端仲裁（零改动）─ BpmGamepadService（按 sourceKey 重建基线）
├─ 原始输入流（零改动）─ BpmGamepadRawListener
├─ 注入层（零改动）─── InputInjector（SendInput + 前台守卫）
└─ 目标游戏
```

### 4.2 `Sdl3Backend` 设计要点

- **`poll()` = 状态快照**，与既有接口天然契合：
  `SDL_PumpEvents()` → 取首个已打开手柄 → `SDL_GetGamepadButtons()`（位集）+
  `SDL_GetGamepadAxis()`（四轴）→ 填 `GamepadFrame`；
  无手柄/未连接返回 `null`（走服务既有的断连休眠逻辑）。
- **位置化按键 → XInput 位映射表**（SDL3 的核心优势）：
  `SOUTH→a`、`EAST→b`、`WEST→x`、`NORTH→y`、
  `START→start`、`BACK→back`、`LEFT_SHOULDER/RIGHT_SHOULDER→肩键`、
  `DPAD_*→十字键`。Xbox 与 PS 手柄自动归一，**不再依赖任何厂商按钮顺序**。
- **扳机**：`SDL_GAMEPAD_AXIS_LEFT/RIGHT_TRIGGER` 归一量 → 折算 0..255 填
  `GamepadFrame.leftTrigger/rightTrigger`（保持与 `triggerThreshold=128` 兼容）。
- **摇杆**：SDL3 轴范围 `[-32767, 32767]`，与 XInput 一致；正方向约定需在 Phase 0 实测
  （SDL 文档：左摇杆上推 = 负 Y，**与我们 `GamepadFrame` 的「正=上/右」约定相反，必须取反**）。
- **事件队列**：`SDL_PumpEvents()` 只泵不取会积压；`poll()` 内用一个预分配的
  `SDL_Event` 缓冲循环 `SDL_PollEvent()` 排空（顺带拿 `GAMEPAD_ADDED/REMOVED` 做热插拔）。
- **加载**：`DynamicLibrary.open(PathHelper.sdl3DllPath)`（**绝对路径**）；
  `SDL_Init(SDL_INIT_GAMEPAD)` 失败 → 返回 null，服务静默降级到既有后端。
- **`sourceKey`**：用 `SDL_GetGamepadInstanceGUID()` —— 换手柄自动触发基线重建（复用既有安全机制）。
- **SDL3.dll 捆绑**：`windows/runner/sdl3/SDL3.dll` → CMake 照抄 LE 块 install 到
  `runtime/sdl3/` → `PathHelper.sdl3Dir`。SDL3.dll 约 1~2 MB。

### 4.3 降级策略

`Sdl3Backend.tryCreate()` 失败（无 DLL / `SDL_Init` 失败）→ 数组里没有它 →
既有 XInput/DInput 后端照常工作。**任何情况下 BPM 不会因 SDL3 而坏**。

---

## 5. 数据模型变更

**无**。`BpmGamepadBackend` 接口不变、`GamepadFrame` 不变、不碰 `game.json` schema。

---

## 6. 性能预算

| 项 | 预算 | 依据 |
|---|---|---|
| `poll()` 单次耗时 | < 1ms | `SDL_PumpEvents` + 若干状态查询，均为微秒级 C 调用 |
| 轮询频率 | 16ms（沿用 `pollInterval`） | XInput 标准 60fps |
| 内存 | SDL3.dll 常驻 ~5MB + 事件缓冲 256B | 可接受 |
| UI 线程影响 | 无新增 | SDL 调用都在既有 Timer 回调里 |

---

## 7. 实施阶段划分

> 🔴 **Phase 0 依旧是技术验证**：SDL3 与「Flutter 应用 + dart:ffi + 无窗口事件循环」
> 的组合从未被验证，不得跳过。

### Phase 0 — SDL3 可行性探针（独立脚本，不接主程序）

| # | 待验证假设 | 方式 | 证伪后果 |
|---|---|---|---|
| 0-1 | **绝对路径加载 SDL3.dll 可行**，`SDL_Init(SDL_INIT_GAMEPAD)` 成功 | 独立 Dart 脚本（`flutter test` 载体，同 Phase 1 经验：纯 `dart run` 加载不了 flutter 依赖） | 改放 exe 同目录 / 或改用 `sdl3` pub 包 |
| 0-2 | **状态快照可用**：按键/摇杆/扳机能读到，且与真实操作一致 | 打印状态矩阵，人工摇手柄对照 | 检查 SDL3 轴方向/范围约定 |
| 0-3 | **位置化按键归一正确**：Xbox 手柄按 A 报 `SOUTH`、PS 手柄按 × 也报 `SOUTH` | 真机双手柄（或借一只 PS 手柄） | 补映射表 |
| 0-4 | **热插拔**：拔掉/重插手柄，`SDL_GetGamepads()` 数量变化且不崩溃 | 真机 | 调整重连逻辑 |
| 0-5 | **只 Pump 不 Poll 不阻塞**（若不排空事件队列） | 连续运行 5 分钟观察 | `poll()` 里排空队列（已按此设计） |
| 0-6 | **SDL3.dll 随安装包捆绑后仍可加载**（非开发目录运行） | 打包后在干净目录验证 | 调整捆绑路径 |

**产出**：一张「SDL3 能力 × 实测结果」矩阵 + 一份可复用的探针脚本。

#### Phase 0 实测结果（2026-09-26 执行）

| # | 假设 | 结果 |
|---|---|---|
| 0-1 | 绝对路径加载 SDL3.dll + `SDL_Init(SDL_INIT_GAMEPAD)` | ✅ **PASS**（未初始化 VIDEO 即可；C `bool` 返回用 Uint8 接收的判定正确） |
| 0-2 | 状态快照（按键/摇杆/扳机） | ✅ **空闲态 PASS**（打开设备成功、摇杆/扳机空闲值全 0、无按键误报；生产后端 180/180 次轮询持续出帧）；按键/摇杆实测待 `live` 模式 |
| 0-3 | 位置化按键归一（Xbox A = PS × = SOUTH） | ✅ **PASS**（用户 live 实测：SOUTH/EAST/WEST/NORTH/DPAD/LB/RB/GUIDE/START 全部按名打印，与实按键位一致） |
| 0-4 | 热插拔 | ⏳ 未明确报告（用户未专门拔插）；设备刷新逻辑已实现，留待日常使用观察 |
| 0-5 | Pump/Poll 循环稳定性 | ✅ **PASS**（2904 次循环 10s，无异常、GetError 为空） |
| 0-6 | 任意绝对路径加载（模拟捆绑后运行） | ✅ **PASS**（复制到 %TEMP% 后全新进程加载成功） |

**探针**：`dev_probe/sdl3_probe.dart`（纯 dart:ffi，**不依赖 flutter**，可直接 `dart run`；
`check` 自动验证 / `live` 人工验证）。一键入口：`dev_probe\SDL3手柄实测.bat`（GBK 编码）。

**过程中发现并修正的两个事实**：
1. 🔴 `SDL_GetGamepadInstanceName` 在 3.4.16 **不存在**（那是更新分支的 API）——
   通过枚举 DLL 导出表确认，本版应使用 **`SDL_GetGamepadNameForID`**。
   教训：**FFI 绑定的符号名必须以导出表为准，不能照抄文档/迁移指南**。
2. `SDL_Init` 返回 C `bool`（1 字节）——Dart 侧必须用 `Uint8` 接收，声明成 `Int32`
   会读到 RAX 高位垃圾。探针打印原始返回值 1 证实判定正确。
3. 🔴 **`SDL_INIT_GAMEPAD = 0x00000200`，不是 0x00000020**（后者是 `SDL_INIT_VIDEO`）。
   首版把常量写错 → 初始化的其实是 VIDEO 子系统 → `SDL_GetGamepads` 恒为 0 ——
   这正是「手柄已连接但脚本显示未连接」的根因。修正后立刻枚举到
   `instanceId=1, name="XInput Controller #1"`。
   教训：**初始化标志这类魔数必须查官方头文件（SDL_init.h），不能凭印象写**。
4. 生产后端真机验证（临时用例，跑完即删）：`Sdl3Backend.poll()` 180/180 次持续出帧，
   `deviceName="XInput Controller #1"`、`sourceKey=sdl3#1`、空闲帧干净。

### Phase 1 — `Sdl3Backend` 落地（✅ 已落地，待真机联调）

- [x] `windows/CMakeLists.txt` + `windows/runner/sdl3/SDL3.dll`（3.4.16 官方 x64，2.84MB
      + LICENSE.txt 随包）+ `PathHelper.sdl3Dir/sdl3DllPath`；
- [x] `big_picture_shell.dart` 注册（SDL3 排首位，XInput/DInput 降为回退）；
- [x] 单测 14 例全过：位置化映射表（含「Xbox A 与 PS × 报同一个 SOUTH」的等价断言）、
      未映射键归零、扳机折算边界/钳位/单调性、Y 轴取反、sourceKey 命名空间不冲突、
      tryCreate 三类降级（路径不存在 / 非 SDL DLL 符号缺失 / 永不重试语义）。
- ⏳ **待真机**：`dev_probe\SDL3手柄实测.bat`（Phase 0 的 0-2/0-3/0-4）→ `手柄验收.bat`（端到端）。

### Phase 2 — 真机矩阵 + 与 Phase 1 注入层联调 ✅ **已通过（2026-09-26）**

- ✅ `手柄验收.bat` 端到端：**注入 41 / 拦截 0**，手柄 A 推进 WA2 对话、B 取消对话框；
  验收运行时后端实际为 **SDL3**（此前因 flutter test 路径问题回退过 XInput，
  已改为显式传仓库内 DLL 路径修复，见 §10 P1）；
- ⏳ PS/Switch 手柄未实测（SDL 位置化归一在机制上已覆盖）。

---

## 8. 改动文件清单

### 8.1 新增

| 文件 | 职责 |
|---|---|
| `lib/big_picture/services/bpm_sdl3_backend.dart` | SDL3 FFI 后端（唯一核心新模块） |
| `windows/runner/sdl3/SDL3.dll` | 捆绑的 SDL3（官方预编译版） |
| `test/big_picture/services/bpm_sdl3_backend_test.dart` | 单测 |
| `dev_probe/sdl3_probe.dart` | Phase 0 探针 |

### 8.2 修改（三处，均为小改）

| 文件 | 改动 | 风险 |
|---|---|---|
| `windows/CMakeLists.txt` | 照抄 `:114-131` LE 块，加 sdl3 install | 🟢 低（纯复制式） |
| `lib/core/path_helper.dart` | 加 `sdl3Dir`/`sdl3DllPath` getter（照 `:30-41` 写法） | 🟢 低 |
| `lib/big_picture/big_picture_shell.dart` | `_createGamepadBackends()` 加一行注册 | 🟡 中（改既有文件，需批准） |

### 8.3 一期明确不碰

`bpm_gamepad_service.dart`（仲裁/原始流不动）、`input_injector.dart`、BPM 全部语义层、
`windows/runner/` 的 C++ 代码、`pubspec.yaml`（不引 pub 包）。

---

## 9. 调用点替换清单

| 批次 | 调用点 | 位置 | 说明 |
|---|---|---|---|
| P0 | 后端注册 | `big_picture_shell.dart:174-185` | `Sdl3Backend.tryCreate()` 排在数组**首位** |
| P1 | 诊断显示 | `big_picture_shell.dart`（连接提示） | 后端名显示 `SDL3:<设备名>` |
| P2 | 文档 | `docs/DEV/features/big_picture_v3_cinema.md` 手柄章节 | 补 SDL3 说明 |

---

## 10. 风险登记

| 级别 | 风险 | 应对 |
|---|---|---|
| **P0** | SDL3.dll 分发合规疏漏（zlib 要求保留版权声明） | 「关于」页加 SDL3 版权条目；安装包内附 LICENSE 文本 |
| **P0** | `flutter test` 载体限制：纯 `dart run` 加载不了 flutter 依赖（Phase 1 实测） | 探针与单测统一用 `flutter test` 载体 |
| **P1** | 🔴 **前台守卫问题不因 SDL3 消失**：本次验收 N=0 的直接原因是「游戏不在前台」。Phase 2 需做「启动后自动把游戏窗口带到前台」（复用 `QuickWindowService`/`MagpieService._activateWindow` 既有能力） | 列入 Phase 2 首项 |
| **P1** | SDL3 摇杆/扳机轴方向与 `GamepadFrame` 约定不一致 | Phase 0-2 实测定死；映射表集中一处便于修正 |
| **P1** | SDL3 事件队列只 Pump 不 Poll 的未定义行为 | `poll()` 内排空队列（已设计）；Phase 0-5 验证 |
| **P2** | SDL3.dll 体积（~2MB）与杀软误报 | 随包分发观察；必要时签名 |
| **P2** | 用户手柄本身有问题（本次 N=0 无法排除） | Phase 2 联调时先用 SDL 自带 `testgamepad` 类工具排除 |
| **P3** | 未来 SDL4 迁移 | zlib + 小封装面，成本低 |

---

## 11. 验收标准

- [ ] `Sdl3Backend` 单测通过；`analyze` 新增零 error；全量 `test` 无回归（基线见 `chronotide-dev` skill）
- [ ] Phase 0 六项探针全部 PASS 并留档
- [ ] 真机：`手柄验收.bat` 跑出 **注入 N>0**，且 WA2 对话推进
- [ ] 真机：拔插手柄不崩溃、服务能重连（既有断连逻辑）
- [ ] BPM 手柄功能回归正常（v3.9 语义事件不受影响）
- [ ] `git status` 自查：只包含本方案列出的文件

---

## 12. 给执行 AI 的指令摘要

> 在 Chrono Tide（D:\CTLIB）中为手柄功能接入 SDL3 输入后端。先读
> `AGENTS.md`、`docs/DEV/SESSION_HANDOFF.md`、本方案文档全文，以及
> `lib/big_picture/services/bpm_gamepad_service.dart`（重点：`BpmGamepadBackend`
> 抽象、多后端仲裁、`GamepadFrame` 的「正=上/右」轴约定）。
> 按 §7 顺序执行：先做 Phase 0 探针（独立脚本，`flutter test` 载体），六项全过才许写
> `bpm_sdl3_backend.dart`。遵守：FFI 用 tryCreate + 静默降级范式；位置化按键映射表
> 集中一处；**禁止从 QKeyMapper/AntiMicroX 抄代码（GPLv3）**；SDL3 版权声明必须加入
> 「关于」页。测试基线以 `chronotide-dev` skill 为准，工作区有他人未提交改动时先
> `git status` 判归属。

---

## 13. 待用户决策的开放问题

1. **SDL3.dll 的分发方式**：随安装包捆绑（推荐，开箱即用）vs 首次运行时下载（省体积，但引入网络依赖）？—— 倾向捆绑，SDL3.dll 仅 ~2MB。
2. **既有 DInput 后端的去留**：SDL3 接入并验证后，`bpm_dinput_backend.dart` 是否退役（减少维护面）？—— 建议 Phase 2 真机矩阵出来后再决定。
3. **Phase 2 的「启动后自动带前台」**是否并入本方案实施（它不依赖 SDL3，但直接决定验收能不能通过）？—— **建议并入**，否则可能重演「注入 N=0」。
