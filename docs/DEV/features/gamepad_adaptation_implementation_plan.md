# 游戏内手柄适配（软件级）实施方案

> 目标读者：接手执行的 AI（Trae / WorkBuddy / 其他）。
> 本文档产出时间 2026-09-19。**研究阶段未改任何业务代码。**
> 相关既有实现：`services/bpm_gamepad_service.dart`、`services/bpm_dinput_backend.dart`（BPM 手柄输入，v3.9）。

---

## 0. 结论摘要（TL;DR）

| 项目 | 结论 |
|---|---|
| **是否可实现** | ✅ **可实现**，且项目已有约 70% 地基（手柄输入服务 / 启动链路 / 窗口操控 / 进程监控全部现成） |
| **技术本质** | **不是**"给游戏加手柄支持"，而是**「手柄输入 → 键鼠事件 → 注入给游戏」**。绝大多数 galgame 只读键盘、根本不调用手柄 API |
| **注入方式** | 🔴 **必须 `SendInput`**。`PostMessage` 被微软官方否定且对全屏游戏 99% 失败 |
| **最大新增点** | 「键鼠注入层」与「按键录制 UI」——项目当前**完全空白** |
| **最大风险** | `SendInput` 是**全局**注入：游戏不在前台时按键会泄漏到别的窗口。**前台守卫是 P0 级必做项** |
| **配置落盘** | 用户已拍板：独立文件 `data/gamepad_profiles.json`（**不碰** `game.json` schema，零迁移） |
| **一期范围** | 用户已拍板：**按键映射 + 摇杆模拟鼠标 + 内置 galgame 通用预设** |
| **必须先做** | **Phase 0 技术验证**：用最小脚本证明 `SendInput` 对 KiriKiri / RenPy 真的有效。**证伪则整个方案重估** |

---

## 1. 背景与目标

### 1.1 背景

项目已有 BPM 大屏幕模式并完成了手柄适配（v3.9，commit `d978deb`）。但那只覆盖**管理器自身**的操作。
**游戏本体**几乎全部没有手柄支持：galgame 的典型输入是 `Enter`/`Space`/`Ctrl`/`Esc`/方向键/鼠标滚轮，
手柄插上后按任何键都毫无反应。

### 1.2 目标

在**启动游戏时**自动挂上一层软件级手柄适配：把用户手柄的操作翻译成游戏认识的键鼠事件，
并允许用户为**每个游戏**自定义按键映射。

### 1.3 非目标（本期明确不做）

| 不做 | 原因 |
|---|---|
| ❌ 代理 DLL 注入（替换游戏目录的 `dinput8.dll` / `xinput1_3.dll`） | galgame 不调用手柄 API，替换 DLL 无从拦截。XInputPlus 那条路对本场景**无效** |
| ❌ 虚拟手柄设备（ViGEmBus / x360ce / XOutput） | 让系统出现一个假手柄，但游戏照样不读手柄 → 零收益，还要装内核驱动 |
| ❌ 内核态/驱动级注入 | 与项目「零新增依赖」传统相悖；签名、杀软拦截、蓝屏风险高 |
| ❌ 手柄震动（力反馈）回传 | 游戏不产生震动事件，无信号源 |
| ❌ 联机游戏 / 反作弊对抗 | 本项目场景为单机 galgame，且对抗反作弊属不当用途 |
| ❌ 修改游戏本体文件 | 违反 AGENTS.md 禁止清单 |

---

## 2. 现状调研（全部带 `路径:行号`）

### 2.1 可直接复用的既有能力

| 能力 | 位置 | 说明 |
|---|---|---|
| 手柄多后端轮询 | `lib/big_picture/services/bpm_gamepad_service.dart` | XInput 4 槽位仲裁 + DirectInput 8 后端；状态机/断连重建/重复节奏齐备 |
| DirectInput 后端 | `lib/big_picture/services/bpm_dinput_backend.dart` | 已用 `DISCL_BACKGROUND \| DISCL_NONEXCLUSIVE`（`:49-50`）——**非独占，天然适合后台运行** |
| 游戏启动统一入口 | `lib/services/game_launch_service.dart:227` `executeLaunch` | ADR-001 已把全部启动方式收敛到这里 |
| 启动结果结构 | `lib/services/game_launch_service.dart:15` `LaunchResult` | 含 `success`/`error`/`localeMode`/`upscalingMode`，**但不含 PID** |
| 进程枚举 / 存活 | `lib/services/win32_process_service.dart:167`（kernel32 FFI）、`:423` `getProcessesInDirectory` | 已封装进程名、路径、存活判断 |
| 前台窗口检测 | `lib/services/foreground_window_service.dart:58-64` | user32 FFI：`GetForegroundWindow` + `GetWindowThreadProcessId` |
| 游戏窗口操控 | `lib/services/quick_window_service.dart:350` `_qwFindWindow`、`:358-366` | 经 runner 原生 `qw_*` 做置顶/居中/关闭/抢焦点 |
| 抢前台 | `lib/services/magpie_service.dart:1732` `_activateWindow` | PowerShell `SetForegroundWindow` |
| 等待游戏窗口出现 | `lib/services/magpie_service.dart:1499` `_waitForGameWindow` | 40 × 250ms ≈ 10s 超时 |
| 游戏退出检测 | `lib/services/magpie_service.dart:1128-1180` `_startGameMonitor` | 每 3s 轮询进程树，连续 2 次未命中判退出 |
| 会话式进程监控 | `lib/services/magpie_service.dart:2695-2809` | 阶段 A 进程检测 + `missCount` |
| 独立 JSON 存储范式 | `lib/services/watch_candidates_store.dart` | **原子写 + 异步 + 写合并 + 容错**，本方案照抄这个模式 |
| 便携路径 API | `lib/core/path_helper.dart:63` `dataDir` | `PathHelper.dataDir` → `<exeDir>/data` |

### 2.2 必须新建的能力（项目当前空白）

| 空缺 | 证据 |
|---|---|
| **键鼠注入层** | 全仓 grep 无任何 `SendInput`/`PostMessage`/`keybd_event` 的 Dart 调用（命中的全在捆绑的第三方 Magpie 目录） |
| **原始按键/摇杆流** | `bpm_gamepad_service.dart:323-371` 只输出 10 个 **BPM 专用语义事件**（`onConfirm`/`onBack`/`onDirection`…），**无法映射成任意键**。箭头事件还带 380ms/130ms 重复节奏，直接复用会导致「按一下发一串」 |
| **按键录制 UI** | 无 `ShortcutRecorder`/`KeyRecorder` 类先例；`LogicalKeyboardKey` 仅用于 `big_picture_shell.dart:519` 的一次 Enter 合成 |
| **服务宿主** | `big_picture_shell.dart:140` 中 `BpmGamepadService` 是 shell 的私有 `late final` 字段，**只能在 BPM 模式存活**，无全局访问入口 |
| **按 PID 找 HWND** | 不存在。仅 `big_picture_manager.dart:213` 的 `FindWindowW`（只找自身窗口）、`magpie_service.dart:1656` 的 PowerShell `EnumWindows`（只取类名） |

---

## 3. 技术选型

### 3.1 注入方式对比

| 方案 | 判定 | 理由 |
|---|---|---|
| **`SendInput`** | ✅ **采用** | 微软官方设计的注入 API。合成输入**走完整输入栈**，被系统当作真实输入 —— 会正确更新键盘 shift state、会被 `GetAsyncKeyState` 读到、会触发 `WH_KEYBOARD` 钩子。对全屏 DirectX 游戏有效 |
| `PostMessage(WM_KEYDOWN)` | ❌ 淘汰 | 微软官方两次撰文否定（Raymond Chen 2005 / 2025）：① 不更新键盘 shift state，游戏调 `GetKeyState`/`GetAsyncKeyState` 读到的是**真实状态**而非伪造；② 消息来自 *posted queue* 而非 *input queue*，`WH_KEYBOARD` 钩子不会被触发，程序会「消息与钩子对不上」而错乱。中文技术社区结论：**全屏 DirectX 游戏用 PostMessage 送 WM_KEYDOWN，99% 失败** |
| `keybd_event` / `mouse_event` | ❌ 淘汰 | 官方标记过时，内部转调 `SendInput` 但参数模型更旧、跨版本行为不一致 |
| UI Automation | ❌ 淘汰 | 微软对普通程序的推荐方案，但**游戏不暴露 UIA 树** |
| 内核过滤驱动 | ❌ 淘汰 | 见 §1.3 非目标 |

### 3.2 键码格式：扫描码优先

优先使用 **扫描码（Scan Code）** 而非虚拟键码：
- `KEYBDINPUT.wScan = MapVirtualKey(wVk, MAPVK_VK_TO_VSC)` + `KEYEVENTF_SCANCODE`
- 原因：部分游戏走 **DirectInput 读键盘**，只看扫描码；虚拟键码路径对这类引擎可能无效
- ⚠️ 使用扫描码时**无法发送扩展键**（如方向键、小键盘），需注意 `KEYEVENTF_EXTENDEDKEY` 的处理

### 3.3 「galgame 只读键盘」这一事实的推论

绝大多数 galgame 引擎（KiriKiri / RenPy / Artemis / BGI / 自研）**根本不链接 XInput/DirectInput 手柄 API**。
因此一切「让游戏识别手柄」的方案（代理 DLL、虚拟手柄）都**没有着力点** —— 唯一的着力点是
**把输入翻译成游戏认识的键鼠事件**。这是本文档全部设计的出发点。

---

## 4. 架构设计

### 4.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│ L4 会话层  GamepadAdaptationSession                          │
│    游戏启动 → 等窗口 → 抢前台 → 启动会话                      │
│    游戏退出 → 停止会话（复用 Magpie 的进程轮询模式）           │
├──────────────────────────────────────────────────────────────┤
│ L3 映射层  GamepadProfile / GamepadProfileResolver            │
│    手柄输入 → 键鼠动作；每游戏配置 + 内置预设 + 全局默认       │
├──────────────────────────────────────────────────────────────┤
│ L2 注入层  InputInjector（全新，dart:ffi）                    │
│    SendInput 合成键鼠事件（扫描码）                            │
│    🔴 前台守卫：目标窗口不在前台 → 本帧全部丢弃                │
├──────────────────────────────────────────────────────────────┤
│ L1 输入层  GamepadInputHost（复用 + 改造）                    │
│    BpmGamepadService 多后端轮询 → 原始按键/轴流                │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 各层触发时机与降级策略

| 层 | 触发时机 | 降级策略 |
|---|---|---|
| L4 会话 | `executeLaunch` 成功后（拿到 PID 与 exe 路径）；游戏进程消失时结束 | 找不到窗口 → 沿用 Magpie 的 10s 超时后放弃，**不阻断游戏** |
| L3 映射 | 每帧轮询时查表 | 无该游戏配置 → 回退全局默认 → 再回退**内置 galgame 预设**（保证开箱可用） |
| L2 注入 | 映射命中时 | 前台守卫不通过 → 丢弃并记数；`SendInput` 返回 0 → 记日志（权限受限的征兆） |
| L1 输入 | 游戏会话激活期间 | 后端不可用 → 会话静默空转（与 BPM 一致） |

### 4.3 🔴 与 BPM 手柄服务的互斥（易漏但必做）

`BigPictureShell` 的手柄服务在 BPM 挂载期间**始终轮询**。游戏运行时若 BPM 仍在树上，
两套消费者会**同时**对手柄按键作出反应（用户在游戏里按 A，BPM 界面也在响应）→ 冲突。

**处理**：游戏适配会话激活期间，需要让 BPM 手柄服务**暂停语义派发**（或让会话层与 BPM 层共享同一个
`GamepadInputHost`，由它统一决定当前谁消费）。**推荐后者**：单一手柄读取源，避免两个 DLL 句柄/两套基线。

---

## 5. 数据模型变更

### 5.1 落盘位置（用户已拍板：独立文件）

新增 `PathHelper.gamepadProfilesFilePath` → `path.join(dataDir, 'gamepad_profiles.json')`
（`lib/core/path_helper.dart:63` 的 `dataDir` 已有，照 `watchCandidatesFilePath:75` 的写法补一个 getter）。

**不触碰 `game.json`** ⇒ **不触发 `format_version` 迁移**（`game_data_format.dart:31` 当前为 3）
⇒ **零 schema 回归面**。代价：游戏被删除/迁移时需单独同步这份文件（见 §10 风险 P1-3）。

### 5.2 结构

```jsonc
{
  "format_version": 1,
  "updated_at": "2026-09-19T12:00:00Z",
  "defaults": {                       // 全局默认（无专属配置的游戏用它）
    "preset": "generic_vn",
    "mappings": []
  },
  "profiles": {
    "<game_id>": {                    // 🔴 键用 ADR-011 的稳定主键 game_id，非 directoryPath
      "game_title": "命运石之门",      // 仅用于 UI 显示与调试
      "preset": "generic_vn",         // 命中的内置预设名（可为 null）
      "enabled": true,
      "mappings": [
        { "source": "button.a",     "action": { "type": "key", "vk": 13 },                 "mode": "tap"  },
        { "source": "button.b",     "action": { "type": "key", "vk": 27 },                 "mode": "tap"  },
        { "source": "button.rb",    "action": { "type": "key", "vk": 17 },                 "mode": "hold" },
        { "source": "stick.right",  "action": { "type": "mouse_move", "sensitivity": 1.0, "deadzone": 0.15 } },
        { "source": "button.lt",    "action": { "type": "mouse_button", "button": "left" },  "mode": "tap" },
        { "source": "button.rt",    "action": { "type": "mouse_button", "button": "right" }, "mode": "tap" }
      ]
    }
  }
}
```

### 5.3 关键设计说明

**键用 `game_id`**：ADR-011 规定 `game_id`（UUID v4）是稳定主键、一经生成禁止改写；
而 `directoryPath` 会被「游戏目录真迁移」改变。用后者会导致玩家迁移目录后配置失联。

**`mode` 三种语义**（缺一不可）：
- `tap`：按下即发，保持固定时长后抬起（默认 50ms，见 §6）
- `hold`：手柄按住 → 键盘按住，松开才抬起。**galgame 的 `Ctrl` 跳过对话就是按住语义，必须支持**
- `repeat`：连发（按住时按固定间隔重复，复用 `bpm_gamepad_service.dart` 已有的 380/130ms 节奏实现）

**`source` 取值**：`button.{a,b,x,y,lb,rb,lt,rt,start,back}` / `dpad.{up,down,left,right}` /
`stick.{left,right}` / `trigger.{left,right}`。

**`action.type` 取值**：`key`（键盘） / `mouse_button` / `mouse_move` / `mouse_wheel`。
（`macro` 多步序列放二期，一期不做。）

**读容错**：读取失败或 `format_version` 不认 → 返回空配置并**降级到内置预设**，**绝不抛错**（照
`watch_candidates_store.dart:47-61` 的容错范式）。写入必须 **原子写 + 写合并**（同上）。

---

## 6. 性能预算

| 项目 | 预算 | 说明 |
|---|---|---|
| 手柄轮询间隔 | 16ms | 沿用 `bpm_gamepad_service.dart:72` 的既有值 |
| 按键→游戏可见延迟 | **≤ 20ms** | 轮询 16ms + `SendInput` 微秒级调用 |
| `SendInput` 单次调用 | < 0.1ms | 纯用户态系统调用，**不需要 isolate** |
| 前台守卫检查 | < 0.05ms | 每帧一次 `GetForegroundWindow` + `GetWindowThreadProcessId` |
| **默认按键保持时长** | **50ms** | 🔴 见下方说明，可配置 |
| 配置文件读取 | 启动/会话开始时一次性读入内存 | 不在每帧读盘 |
| 配置文件写入 | 用户改动时写一次（原子 + 合并） | 不在热路径 |

🔴 **50ms 保持时长不是随意取的**：若游戏用 `GetAsyncKeyState` **轮询**（不少老引擎如此），
瞬时注入可能整帧被跳过。50ms ≈ 覆盖 3 帧 @60fps，是"足够被采到"与"不会误判成长按"之间的折中。
**Phase 0 必须实测不同引擎所需的最小时长**，并把结果写回本表。

---

## 7. 实施阶段划分

> 🔴 **Phase 0 是技术验证，不是锦上添花。核心假设没被证明之前不得进入 Phase 1。**

### Phase 0 — 技术验证（必须先做，产出判定而非功能）

用**独立最小脚本**（不接入主程序）回答 4 个问题：

| # | 待验证假设 | 验证方式 | 证伪后果 |
|---|---|---|---|
| 0-1 | `SendInput` 能让 KiriKiri 游戏收到按键 | 用 `SendInput` 发 `Enter` 到全屏 KiriKiri 游戏，观察对话是否推进 | **方案重估** |
| 0-2 | 对 RenPy 引擎同样有效 | 同上，换 RenPy 游戏 | 需按引擎分别评估 |
| 0-3 | 全屏独占（exclusive fullscreen）下仍有效 | 分别测窗口化 / 无边框全屏 / 独占全屏三种模式 | 若独占无效 → 需引导用户窗口化 |
| 0-4 | 50ms 保持时长够不够；扫描码 vs 虚拟键码哪个有效 | 各引擎交叉测试，二分找出最小时长 | 调整 §6 预算 |

**产出**：一份「引擎 × 全屏模式 × 键码格式 × 最小时长」的实测矩阵，作为 Phase 1 的实现依据。
若 0-1/0-2 任一证伪 → **停止，回本文档重构方案**。

### Phase 0 实测结果（2026-09-26 执行完毕）

**执行环境**：Windows 11 / Python 3.13.14 AMD64。
探针：`dev_probe/phase0_inject_probe.py`（机制层）、`dev_probe/phase0_game_probe.py`（真游戏 `.arc` 引擎）、
`dev_probe/phase0_wa2_*.py`（第二轮：`白色相簿2` / Leaf 引擎，补齐引擎差异与全屏）。

#### 0-4 键码格式与保持时长 —— ✅ 已实测（机制层）

| 项 | 结果 |
|---|---|
| `INPUT` 结构大小 (x64) | **40 字节** —— 与附录 B 的计算一致，结构定义正确 |
| `SendInput` 返回值 | 每次按键返回 **2**（down + up 各 1）→ **未被 UIPI 拦截** |
| 虚拟键码模式（`wVk` + flags=0） | 可被 `GetAsyncKeyState` 观测到 ✅ |
| 扫描码模式（`KEYEVENTF_SCANCODE`） | 同样可观测 ✅（两者都可用；扫描码保留为兼容 DirectInput 引擎的保险） |
| 抬起后是否残留按下态 | **无残留** ✅ |
| 最短可观测保持时长 | **1 ms**（受探针 1ms 轮询精度限制，未能更细） |

> 结论：**50ms 默认保持时长有充足余量**，后续可按游戏实测下调。§6 预算维持 50ms（保守值）。

#### 0-1 真游戏能否收到 —— ✅ 已验证成立

**被测游戏**：`D:\gal\しごカレ～エッチな女子大生`（`.arc` 打包 + `message.dat`/`params.dat`；非 KiriKiri/RenPy）。

🔴 **关键前置发现**：直接启动 `Start.exe` / `Start_4o+3.5s.exe` **均以 `0xC0000005`(ACCESS_VIOLATION) 崩溃**；
经项目内置 Locale Emulator（`runtime/locale_emulator/LEProc.exe`）**转区启动后才正常**。
→ 该游戏依赖日语转区。这印证了本方案**必须与既有 `localeMode` 启动链路协同**，不能绕开它自己启动。

| 步骤 | 结果 |
|---|---|
| 对照组（不注入，静态「起動設定」对话框） | 8×5 采样网格 **变色点 0/40，平均通道差 0.0** —— 基线完全干净 |
| 实验组（`SendInput` 发 `Enter`，hold = 50ms） | **对话框立即消失**，随后出现游戏主窗口（1034×633，标题即游戏名） |
| 判定 | ✅ **游戏确实收到了注入的按键** |

> 结论：**0-1 成立** —— `SendInput` 足以驱动真实 galgame，**不需要任何 API 代理或虚拟手柄**。

#### 0-3 全屏模式 —— ✅ 已实测（含「全屏 → 窗口化」双向验证）

**第二轮被测游戏**：`E:\GAL\白色相簿2`（**Leaf / AquaPlus 引擎**，`WA2_chs.exe` 汉化版，**免转区**直接运行；
目录内**无任何 xinput / dinput DLL**，即零原生手柄支持）。
该游戏支持 `Alt+Enter` 切换全屏，提供**不受画面动画干扰的离散信号**（窗口矩形）：

| 步骤 | 结果 |
|---|---|
| 初始 | 窗口化 `(173, 69, 1286, 769)`，屏幕 2560×1440 |
| 注入 `Alt+Enter`（第 1 次） | **全屏** `(0, 0, 2560, 1440)` → 证明窗口化下注入有效 |
| 注入 `Alt+Enter`（第 2 次） | **窗口化** `(173, 69, 1286, 769)` → **证明全屏下注入同样有效** ✅ |

> ⚠️ **边界说明**：该「全屏」是否属**独占全屏**（exclusive fullscreen）**未能确证** ——
> 分辨率未变化、窗口对象仍存在，同样符合「无边框全屏」特征。
> 已确证的是：**「窗口铺满整屏时注入有效」**。若后续遇到必须在独占全屏下运行的游戏，仍建议实测。
> 探针：`dev_probe/phase0_wa2_fullscreen.py`。

#### 0-2 引擎相关性 —— ✅ 已补一个异构引擎（Leaf / AquaPlus）

除既有 `.arc` 引擎样本外，新增 `白色相簿2`（Leaf / AquaPlus）作为第二个异构样本，三类输入全部生效：

| 输入类型 | 结果 |
|---|---|
| 鼠标左键（点击标题「开始游戏」） | ✅ 标题菜单 → 序章正文，状态发生跳转 |
| 键盘 `Enter`（正片对话） | ✅ 逐句推进（对照实验见下） |
| 键盘 `Alt+Enter` | ✅ 全屏 / 窗口化双向切换 |

**「输入驱动 vs 自动播放」对照实验**（正片对话框区域灰度，8×5 稀疏采样会漏掉文字，故改用区域灰度）：

| 段 | 输入 | 对话框区平均亮度 | 相邻帧差 |
|---|---|---|---|
| A | **无输入** | 113.4 → 113.3 → 113.3 → 113.3 → 113.3 | 0.27 / 0.20 / 0.15 / 0.15（**静止，等输入**） |
| B | `Enter` | 114.0 → 110.0 → 109.2 → 111.4 → 111.3 | **31.8 / 15.4 / 12.0 / 7.4（推进）** |
| C | 左键点击 | 105.3 → 123.2 → 123.2 → 124.3 → 121.3 | 39.8 / 31.2 / 7.6 / 9.5（推进） |

> 结论：`Enter` 与左键点击**都能推进 WA2 正片对话**；A 段 15s 完全静止证明该状态**不会自动推进**，
> 从而排除自动播放干扰。探针：`dev_probe/phase0_wa2_input.py`。

#### 🔴 WA2 实测暴露的三条「每游戏差异」（直接影响映射层设计）

1. **标题菜单是纯鼠标的** —— `↑ ↓ ← →` / `Enter` / `Space` 在标题界面**全部无响应**（0/40 变色点）。
   → **鼠标注入（或摇杆模拟鼠标）不是可选项，而是必需项**；只映射键盘会导致用户**无法从标题进入游戏**。
2. **序章是定时自动播放的** —— 进入游戏后的「序章」独白约 5s/句自动推进，**30s 不注入也换了 6 句**。
   → 这类段落**不能用「画面是否变化」判定注入是否生效**（本轮曾因此误判一次，靠控制组纠正）。
3. **正片才吃输入** —— 序章结束后进入正片，对话**完全静止等待输入**，`Enter` 可逐句推进。

> 这三条印证了方案的**核心设计假设**：galgame 的输入方式**逐游戏不同**，
> 因此「每游戏可自定义映射 + 内置预设 + 用户微调」是**必需**而非锦上添花，不能写死一套。

#### Phase 0 总结论

**✅ 方案基础假设成立，Phase 0 四项验证全部闭环，可以进入 Phase 1。**

| 验证项 | 状态 |
|---|---|
| 0-1 真游戏能否收到 | ✅ 已证（`.arc` 引擎对话框确认 + Leaf 引擎标题跳转 / 对话推进） |
| 0-2 引擎相关性 | ✅ 已补 Leaf 样本；KiriKiri / RenPy 未覆盖，但机制同源（均走系统输入栈） |
| 0-3 全屏 | ✅ 「铺满屏幕时注入有效」已确证；**是否独占全屏未确证**（见上） |
| 0-4 键码与保持时长 | ✅ 已证（`INPUT` 40B、未被 UIPI 拦截、虚拟键码与扫描码均可用、50ms 余量充足） |

**Phase 0 新增的强制约束**：
🔴 **必须与 `localeMode` 转区启动链路协同** —— 日文 galgame 未转区会直接崩溃（`0xC0000005`），
因此手柄适配的挂载点必须在**转区启动成功之后**，且目标进程应取**转区后的实际游戏进程**（不是 `LEProc.exe`）。

**方法学教训（供后续探针复用）**：动画界面下用「稀疏采样 + 像素差」极易误判，必须
① 先用**控制组（注入惰性键）**排除自然变化；② 采样区必须**覆盖真实 UI 区域**
（本轮两次踩坑：采样带漏掉居中文字、漏掉底部对话框）。

---

### Phase 1 — 注入层 + 输入层改造（打通往游戏的一条路）

- [x] 新建 `lib/services/gamepad/input_injector.dart`（`SendInput` FFI + 前台守卫）—— **已完成并真机验证**
- [x] 改造手柄服务：暴露**原始按键/摇杆流**（不经过 BPM 语义）—— **已完成**（additive，语义回调零改动）
- [x] 硬编码映射（手柄 A → `Enter`、B → `Esc`）—— 见 `test/services/gamepad/gamepad_e2e_manual_test.dart`
- [x] **真机手测** —— ✅ **2026-09-26 验收通过**：手柄 A 推进 WA2 对话、
      B 取消对话框；`注入 41 / 拦截 0`（accepted=2，系统确认接受）、服务层帧 5071、
      连接=true。链路「手柄 → SDL3 → 硬编码映射 → SendInput → 前台游戏」端到端打通。

#### Phase 1 已完成部分（2026-09-26）

**`lib/services/gamepad/input_injector.dart`**（**纯新增**，未触碰任何既有代码；
纯 Dart —— 不引 `package:flutter`，故可被 plain `dart run` 独立探针直接驱动）：

| 组件 | 职责 |
|---|---|
| `SyntheticInputSink`（抽象） | 注入写入口；生产实现 = `SendInputSink`（`user32!SendInput`） |
| `SendInputSink` | 键盘（**虚拟键码 / 扫描码双模式**）、鼠标绝对移动与左右键；`MapVirtualKeyW` 做 vk→scan |
| `ForegroundChecker`（抽象） | 前台判定；生产实现 = `User32ForegroundChecker` |
| `InputInjector` | 编排层：**前台守卫 → 合成事件 → 保持时长**；`tapKey` / `holdKeyDown` / `releaseKey` / `clickAt` |

**三条 P0 安全设计**（单测逐条断言）：
1. **未绑定目标进程 → 拒绝注入**（`noTarget`），而不是「默认注入到当前前台窗口」；
2. **目标不在前台 → 拒绝注入**（`foregroundMismatch`）——断言「守卫不通过时 sink 调用数为 **0**」；
3. **前台 PID 查询失败（null）按不安全处理**。

**真机验证**（`dev_probe/phase1_dart_injector.py` 编排+观察，`dev_probe/injector_probe.dart` 注入；
Dart 侧走**生产代码路径**，非另写一份）：

| 步骤 | 结果 |
|---|---|
| 运行时结构体布局 | `INPUT=40B` / `KEYBDINPUT=24B` / `MOUSEINPUT=32B` —— 与 Win32 x64 定义一致 |
| 控制组：注入惰性键 `F13` | 窗口矩形**不变**（排除自然变化，证明变化确实来自注入） |
| 注入 `Alt+Enter` | 窗口化 `(173,69,1286,769)` → **全屏** `(0,0,2560,1440)` |
| 再注入 `Alt+Enter` | 全屏 → **窗口化** |
| 判定 | ✅ **Dart 注入器真机验证通过 3/3**（FFI 联合体写回正确、守卫正确） |

**单测**：`test/services/gamepad/input_injector_test.dart` **18 例全通过**
（结构体布局、守卫四种分支、按键顺序与保持时长、扫描码模式、
鼠标坐标映射/越界夹取/双击/右键、诊断量）。测试**绝不真注入**，全部走 FakeSink。

**⚠️ 本阶段验证盲点**：`F13` 控制组 + `Alt+Enter` 证明的是「Dart 注入器能把键送进真实游戏
并改变其状态」；**尚未走通真实手柄的端到端链路**（手柄 → 原始流 → 映射 → 注入），
这需要开发者本人操作手柄，或在 Phase 2 接入会话后手测。

#### Phase 1 追加（2026-09-26 晚）：原始输入流 + 硬件在环验收用例

**`bpm_gamepad_service.dart` 增量改动（additive，既有语义回调零改动）**：

| 新增 | 说明 |
|---|---|
| `GamepadRawButton` | 14 个原始按键标识（12 个位掩码键 + LT/RT 模拟量），`mask` 与 `XInputButtons` 一致 |
| `BpmGamepadRawListener` | `onButton`（按下/**抬起**边缘）、`onFrame`（每帧原始快照）、`onReset`（重置通知） |
| `addRawListener` / `removeRawListener` | 多消费者注册 |

> 语义层此前**不消费按键抬起事件**（只做上升沿），原始流补齐了下降沿 ——
> 这是「按住 `Ctrl` 快进」这类映射能否正确松键的前提。

**🔴 `onReset` 的语义（安全关键）**：断连 / **已连接状态下重建基线（换设备）** / 服务销毁时广播，
消费方**必须**释放一切「按住」状态 —— 否则手柄断开时映射的按键会卡死在按下态。
**首次连接不广播**（此时不存在按住态）。

**自查修掉一处设计缺陷**：初版补丁在「首次连接的基线帧」也广播了 `onReset`，
导致 4 例单测失败（断连应恰好一次 / 换设备应一次 / 销毁应一次）—— 单测把它抓住了。

**硬件在环验收用例** `test/services/gamepad/gamepad_e2e_manual_test.dart`：
走**生产代码路径**（`BpmGamepadService` 原始流 → 硬编码映射 A→`Enter` / B→`Esc` →
`InputInjector`），自动启动游戏、绑定 PID、前台守卫自动拦截、结束自动关闭游戏；
未设置环境变量时自动 skip（不影响全量基线）。

**验收命令**（需开发者本人操作手柄，约 2 分钟交互；先关闭 Chrono Tide 避免 BPM 抢输入源）：

```sh
CT_E2E_GAME='E:\GAL\白色相簿2\WA2_chs.exe' \
  ./flutter/bin/flutter.bat test test/services/gamepad/gamepad_e2e_manual_test.dart --reporter expanded
```

步骤：鼠标点游戏窗口到前台 → 进能吃键盘的界面（WA2 标题点「开始游戏」、**等序章播完**）→
按手柄 **A** 看对话是否推进、按 **B** 看是否触发 Esc/菜单。控制台打印每次注入结果与汇总。

**测试**：`test/services/gamepad/` **33 通过 / 1 跳过**（跳过即上述手动用例）；
新增 15 例原始流单测；全量 `test` **861 通过 / 0 失败 / 1 跳过**（零回归）。

### Phase 2 — 映射层 + 配置存储

- 新建 `lib/services/gamepad/gamepad_profile.dart`（数据模型）
- 新建 `lib/services/gamepad/gamepad_profile_store.dart`（照 `watch_candidates_store.dart` 范式）
- 新建 `lib/services/gamepad/gamepad_adaptation_session.dart`（会话生命周期）
- 接入 `executeLaunch` 成功点与游戏退出检测点
- 验收：能用手改的 JSON 配置改变映射行为

### Phase 3 — UI：映射编辑器 + 按键录制

- 新建映射编辑对话框（挂到游戏详情/右键菜单入口）
- 按键录制组件：用户按手柄键 → 捕获为 `source`；按键盘键 → 捕获为 `vk`
- 内置 galgame 预设应用入口 + 「恢复默认」

### Phase 4 — 打磨

- 摇杆模拟鼠标（灵敏度 / 死区 / 加速曲线，参数可调）
- BPM 手柄服务与会话的**互斥**（§4.3）
- 诊断面板（当前是否激活 / 前台守卫是否通过 / 注入计数）

---

## 8. 改动文件清单

### 8.1 新增（全部为纯新增模块，不触碰既有代码）

| 文件 | 职责 |
|---|---|
| `lib/services/gamepad/input_injector.dart` | `SendInput` FFI 封装：键盘/鼠标合成、扫描码映射、前台守卫 |
| `lib/services/gamepad/gamepad_profile.dart` | 配置数据模型 + JSON 序列化 + 内置预设常量 |
| `lib/services/gamepad/gamepad_profile_store.dart` | 独立文件持久化（原子写 + 写合并 + 容错） |
| `lib/services/gamepad/gamepad_adaptation_session.dart` | 会话生命周期：启动/停止/与进程监控对接 |
| `lib/services/gamepad/gamepad_input_host.dart` | 手柄输入单一来源（复用服务，暴露原始流） |
| `lib/widgets/gamepad/gamepad_mapping_dialog.dart` | 映射编辑 UI + 按键录制 |
| `test/services/gamepad/*_test.dart` | 单测 |

### 8.2 修改（四处，均为接线）

| 文件 | 改动 | 风险 |
|---|---|---|
| `lib/core/path_helper.dart` | 加 `gamepadProfilesFilePath` getter（照 `:75` 写法） | ⚪ 低（纯新增 getter） |
| `lib/services/game_launch_service.dart` | 在 `executeLaunch` 成功分支挂载会话 | 🟡 中（启动链路是历史 bug 高发区，见 `STATUS_MAP.md:66`） |
| `lib/big_picture/services/bpm_gamepad_service.dart` | 暴露原始按键/摇杆回调（新增，不改既有语义） | 🟡 中（v3.9 刚落地，改动需回归 BPM 手柄） |
| `lib/big_picture/big_picture_shell.dart` | 与游戏会话互斥（§4.3） | 🟡 中 |

### 8.3 一期明确不碰

`lib/main.dart`、`lib/main_container.dart`、`lib/theme/`、`lib/core/portable_*.dart`、
`windows/runner/`、`lib/packages/luna_metadata_sdk/` —— **全部属稳定区**（AGENTS.md §2.4），
本方案**不需要**触碰它们（`SendInput` 从 `user32.dll` 直接 FFI 调用即可，无需改原生层）。

---

## 9. 调用点替换清单（按 P0/P1/P2 分批）

| 批次 | 调用点 | 位置 | 说明 |
|---|---|---|---|
| **P0** | 启动成功点挂载会话 | `game_launch_service.dart:227` `executeLaunch` 成功分支 | 🔴 **非 Widget 路径，最易漏**。注意此处 `LaunchResult` 不含 PID，需向下取（PID 捕获在 `local_game_registry.dart:2286,2306` `launchedPid`） |
| **P0** | Magpie 启动分支同步挂载 | `magpie_service.dart:892` `startGameWithUpscaling` | 🔴 **第二条启动路径，漏掉则"开超分就没有手柄适配"** |
| **P1** | 游戏退出 → 停止会话 | 复用 `magpie_service.dart:1128-1180` / `:2780` 的轮询模式 | 建议做成独立监控，避免与 Magpie 会话耦合 |
| **P1** | BPM 手柄服务互斥 | `big_picture_shell.dart:140,200` | 见 §4.3 |
| **P2** | 游戏详情 UI 入口 | `widgets/game_detail_dialog.dart`（右键菜单/详情面板） | 加「手柄映射」入口 |
| **P2** | 启动前会话预热 | `executeLaunch` 之前 | 可选：提前读配置，缩短首个按键延迟 |

---

## 10. 风险登记

| 级别 | 风险 | 影响 | 应对 |
|---|---|---|---|
| **P0** | **前台守卫失效 → 按键泄漏** | 用户在别的程序里打字时被手柄输入干扰，**体验灾难** | 双重校验：目标 HWND 既是前台窗口、且前台窗口 PID == 游戏 PID。任一不符则整帧丢弃并计数 |
| **P0** | **管理员权限（UIPI）拦截** | 游戏以管理员身份运行时，普通权限进程的 `SendInput` 被静默拒绝（`SendInput` 返回 0） | 会话启动时比对目标进程完整性级别；不一致则明确提示用户，`SendInput` 返回 0 时记日志 |
| **P0** | Phase 0 证伪（某引擎下 `SendInput` 无效） | 方案基础不成立 | 见 §7 Phase 0 的证伪分支 |
| **P1** | 按键保持时长与游戏轮询周期不匹配 | 漏触发（按了没反应）或误触发（一次按变两次） | 默认 50ms，开成可配置项；Phase 0 实测数据回填 §6 |
| **P1** | 独占全屏下无效 | 部分游戏无法适配 | 诊断日志明确区分；引导用户切窗口化/无边框 |
| **P1** | 游戏删除/迁移后配置失联 | 孤儿配置残留 | 用 `game_id` 为键（迁移不变）；游戏删除时按 `game_id` 清理 |
| **P1** | BPM 手柄服务与游戏会话争抢手柄 | 两处同时响应，误操作 | §4.3 单一输入源 + 明确归属 |
| **P2** | 配置文件损坏 | 映射全部失效 | 容错读取（返回 null）+ 降级内置预设；写盘原子化 |
| **P2** | 手柄服务在 BPM 与游戏间切换时基线错乱 | 切换瞬间乱触发 | 复用 v3.9 已建的 `sourceKey` 机制（换源即重建基线） |
| **P3** | 用户误以为"所有游戏都能完美适配" | 预期落差 | UI 里如实标注适配状态与已知不适配的引擎 |

---

## 11. 验收标准

### 功能验收（真机）

1. 从库里启动一款 KiriKiri galgame，**不配置任何东西**即可用手柄推进对话（走内置预设）
2. 手柄 A / B / 十字键 / 摇杆均按预设生效
3. 右摇杆能移动鼠标；肩键能触发鼠标左右键
4. 用户改一处映射 → 游戏内行为随之改变（无需重启管理器）
5. 游戏退出后手柄恢复为普通手柄（不再向系统注入任何按键）
6. **游戏切到后台时，按手柄不会在别的窗口产生任何输入**（前台守卫生效）
7. BPM 模式下按手柄**只**操作 BPM 界面，不会同时往游戏注入

### 技术验收

- `./flutter/bin/flutter.bat analyze lib/` → **0 新增 error**
- `./flutter/bin/flutter.bat test` → 全量通过（**基线 671/0**，2026-09-19 实测值），**不得新增失败**
- 新增单测覆盖：映射解析 / 配置读写容错 / 前台守卫判定 / 按键保持时长
- `git status --short` 自查：无计划外文件改动
- 完成后按 AGENTS.md §3 更新 `DEV_LOG.md` / `SESSION_HANDOFF.md` / 本文件状态

---

## 12. 给执行 AI 的指令摘要

```
读取 D:\CTLIB\docs\DEV\features\gamepad_adaptation_implementation_plan.md，按其中的
Phase 划分执行。铁律：

1. 先做 Phase 0 技术验证，产出「引擎 × 全屏模式 × 键码格式 × 最小时长」实测矩阵。
   若 SendInput 对 KiriKiri/RenPy 无效，立即停止并报告，不要继续往下做。
2. 严格遵守 AGENTS.md：稳定区（main.dart / main_container.dart / theme/ /
   portable_*.dart / windows/runner / luna_metadata_sdk）一期完全不碰。
3. 不要改 game.json 的 schema —— 配置写独立文件 data/gamepad_profiles.json。
4. 前台守卫是 P0 必做项：目标窗口不在前台时，整帧丢弃，绝不放行。
5. 注入只用 SendInput，不要尝试 PostMessage（对全屏游戏无效，见文档 §3.1）。
6. 新增模块放在 lib/services/gamepad/ 下；每完成一个 Phase 跑一次
   ./flutter/bin/flutter.bat analyze 与 test，不得新增失败。
7. Flutter 在项目内：./flutter/bin/flutter.bat（3.24.3 / Dart 3.5.3），不要用全局命令。
8. 跑 flutter 前先 env | grep -i proxy，有 proxy 变量就在当前 shell unset。
9. 长内容改动用 Python 脚本原子写入（本仓 .dart/.md 多为 CRLF，Edit 多行替换会静默失败）。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 备选 | 当前假设 |
|---|---|---|---|
| 1 | 内置 galgame 预设是按**引擎**匹配（KiriKiri/RenPy/Artemis…）还是只给**一套通用预设**？ | 按引擎更精准但需识别引擎；通用更简单但个别键位可能不对 | 先做一套通用预设，按引擎细分放二期 |
| 2 | 是否需要**配置导入/导出**（分享给他人）？ | 需要则配置格式要考虑可读性与版本兼容 | 一期不做，但 JSON 结构已可读 |
| 3 | 手柄断连/重连时是否要**自动暂停**会话（避免半途失效）？ | 自动暂停更稳；继续尝试可能静默失效 | 倾向自动暂停 + 提示 |
| 4 | 是否要给**非 galgame**（如模拟器、老式 PC 游戏）也用同一套机制？ | 影响产品定位与 UI 文案 | 机制天然通用，但文案先只面向 galgame |
| 5 | 是否需要「**按住某组合键临时禁用映射**」？（避免玩家想用键盘时被手柄干扰） | 常用设计（如按住 Back 3 秒） | 建议做，成本低 |

---

## 附录 A：参考项目清单

| 项目 | 许可 | 平台 | 借鉴点 | 备注 |
|---|---|---|---|---|
| **QKeyMapper** | GPLv3 | Windows (Qt) | ★★★★★ **智能进程匹配**：为每个程序配独立映射、按前台窗口自动切换 —— 与本方案产品形态几乎一致；另有连发/长按/双击/顺序触发 | 最贴近的参考 |
| **AntiMicroX** | GPLv3 | Win/Linux | 映射编辑 UI、摇杆模拟鼠标（死区/灵敏度/加速）、Auto profiles、多套可切换映射集 | ⚠️ 官方已公告**寻求新维护者**，不再加新功能；仍可读源码 |
| **JoyToKey** | 商业 | Windows | 窗口定向生效；「留一份空白默认配置防误触」的实践经验 | 闭源，只借鉴思路 |
| **Xpadder** | 商业 | Windows | 可视化手柄图 + 点选式映射交互 | 闭源 |
| **Xidi** | 开源 | Windows | 给老游戏补 DirectInput/WinMM 接口，且支持模拟按键按下 | 走 API 层，与本方案路线不同，可读其按键模拟部分 |
| **reWASD** | 商业 | Windows | 商业级映射能力与 UI 参考 | 闭源 |
| **XInputPlus** | 免费闭源 | Windows | 代理 DLL（替换游戏目录 `dinput8.dll`/`xinput1_3.dll`）注入 | ⚠️ **对本场景无效**（galgame 不调手柄 API），仅作了解 |
| **x360ce / XOutput / DS4Windows / ViGEmBus** | 混合 | Windows | DInput ↔ XInput 互转、虚拟手柄驱动 | ⚠️ **本场景不需要**（游戏不读手柄） |

## 附录 B：关键技术事实速查

- **`INPUT` 结构（x64）= 40 字节**：`DWORD type`(4) + 4 字节对齐填充 + `union`(32)
  - `MOUSEINPUT` = 32 字节：`dx,dy,mouseData,dwFlags,time`(各 4) + 4 填充 + `dwExtraInfo`(8)
  - `KEYBDINPUT` = 24 字节：`wVk,wScan`(各 2) + `dwFlags,time`(各 4) + 4 填充 + `dwExtraInfo`(8)
  - Dart 侧用 `ffi.Union` 表达联合体
- **`INPUT_KEYBOARD` = 1**、**`INPUT_MOUSE` = 0**
- **`KEYEVENTF_KEYUP = 0x0002`**、**`KEYEVENTF_SCANCODE = 0x0008`**、**`KEYEVENTF_EXTENDEDKEY = 0x0001`**
- **`MOUSEEVENTF_MOVE = 0x0001`**、**`MOUSEEVENTF_ABSOLUTE = 0x8000`**
  - ⚠️ `MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE` 时，`dx/dy` **不是像素**，而是 0–65535 的归一化坐标
- **`SendInput` 返回实际插入的事件数**：返回 0 通常意味着被 UIPI 拦截（权限不足）→ 必须记日志
- **`MapVirtualKey(vk, MAPVK_VK_TO_VSC /*=0*/)`** 用于虚拟键码 → 扫描码
---

## 14. Phase 2 接线变更计划（🟡 待批准 —— 涉及既有文件）

> 纯新增模块（profile / store / session，含 82 例单测）已落地并提交；
> 本节是让手柄适配在软件内**自动生效**的接线方案，按两段式流程待批准后执行。

### 14.1 挂载点结论

**挂在 `LocalGameRegistry` 的会话确认/结束回调，不挂 `executeLaunch`。**

理由：`executeLaunch` 返回成功 ≠ 游戏真的在跑（`game_launch_service.dart:267-272`
注释已说明横幅语义为此做过修正）；而 `local_game_registry.dart` 的进程检测
（`Win32ProcessService.getRunningProcessInfo`，:2767）与时长统计共用同一套口径，
`onGameSessionConfirmed`（:2039，触发于 :2846）即「游戏进程确认存活」。

### 14.2 需要的最小改动

| # | 文件 | 改动 | 风险 |
|---|---|---|---|
| 1 | `lib/services/local_game_registry.dart:2039` | `onGameSessionConfirmed` 签名补第 3 参 `pid`（触发处 :2846 一并传 `best_pid`） | 🟡 签名变更波及持有者 |
| 2 | `lib/services/running_tasks_service.dart:178` | 唯一持有者：同步改签名；并在此注册 `GamepadAdaptationCoordinator` | 🟢 低（同文件已注册回调） |
| 3 | `lib/services/gamepad/gamepad_adaptation_coordinator.dart` | **纯新增**：单例，监听 confirm/ended；gameTitle→gameId 解析（`LibraryGame.gameId`，local_game_registry.dart:220）；profile 解析 → 会话启停 | 🟢 纯新增 |
| 4 | 「关于」页 | 补 SDL3 版权声明（zlib 义务，P0 合规） | 🟢 低 |

### 14.3 结束路径

`onGameSessionEnded`（:2028，触发于 :2803/:2970）→ `coordinator.onSessionEnded(gameTitle)`
→ `session.stop()`（内部已含「释放按住态 → 停轮询 → 释放后端」安全阀）。

### 14.4 风险登记

| 级别 | 风险 | 应对 |
|---|---|---|
| P1 | 会话结束后手柄仍注入 | `stop()` 兜底 + 注入器前台守卫双保险 |
| P2 | gameTitle→gameId 解析失败/重名 | 记日志跳过适配，**绝不影响游戏启动** |
| P2 | 与 BPM 手柄服务并存 | 本期 BPM 语义层不消费注入；互斥策略 Phase 4 |
| P3 | 同一游戏 30s 内反复启停 | 会话加去抖（start 前若已在跑则复用） |

### 14.5 验收

- `analyze` 零 error；全量 test 无回归；
- 真机：软件内启动 WA2 → **不跑任何脚本**，手柄 A 直接推进对话；退出游戏 → 再启动不残留；
- BPM 进出各一次后再启动游戏，手柄仍正常（回归 v3.9 语义事件）。


---

## 附录：2026-10-06 前台互斥闸门 v2（玩游戏时 BPM 界面同时乱动修复）

- **现象**：BPM 启动游戏后手柄玩游戏，BPM 界面同时响应手柄（A 当确认、摇杆移动焦点）。
- **根因**：BPM 手柄是 FFI 全局轮询，不经过窗口焦点；`dispatchGate` 旧条件
  `hasActiveSession && isGameForeground` 只在「有映射会话」时生效 —— 未启用映射
  （确认弹窗选否 / 游戏无 pid / 无 game_id）时闸门恒开。
- **修法**：`GamepadAdaptationCoordinator.isAppForeground`（GetForegroundWindow
  pid == kernel32.GetCurrentProcessId，250ms 缓存；查询不可用 → 返回 true 保持旧行为）
  + 闸门总规则 `!isAppForeground → 让路`。原条件保留兜底（启动器型游戏 Guard 的
  目录级放行与本判定正交）。
- **不受影响**：raw 注入流（映射会话在游戏内的按键翻译照常）；Alt+Tab 回 Chrono Tide
  立即恢复 BPM 导航（2026-09-27 语义保留）。
- **验证**：进程内 analyzer 探针 0 error；flutter_tester 离线探针 6/6 PASS
  （`.workbuddy/probe_gate/p.dart`）。⚠️ 231 管道耗尽期间无法跑 `flutter test`，
  环境恢复后补跑 `flutter test test/services/gamepad/`；未真机走查。
