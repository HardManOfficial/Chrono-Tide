# 开机自启「静默进托盘」修复（--silent 启动不再显示窗口）

**状态**：✅ 代码已落地（待重建 exe + 真机走查）
**日期**：2026-10-03
**触发**：开发者反馈「每次开机，软件会暂时停在桌面上；鼠标一点它就消失回到托盘。
希望开机时直接静默在托盘启动，不要在桌面闪现」。
**改动面**：1 个文件（`windows/runner/flutter_window.cpp`），零 Dart 改动。

---

## 1. 现象与根因链

原设计是有的：`AutoStartService` 写注册表时带 `--silent`，Dart 侧也有静默分支。
**问题出在原生 runner 的模板遗留代码把窗口又掀开了。**

```
lib/services/autostart_service.dart:56   注册表 Run 值 = "chrono_tide.exe" --silent   ✅ 正确
        ↓
lib/main.dart:362                        isSilentMode = true
        ↓
lib/main.dart:493-507                    waitUntilReadyToShow 回调：hide() + setSkipTaskbar(true)   ✅ 正确
        ↓                                ⚠️ 但该回调**在 runApp(:540) 之前就同步执行完了**，
        ↓                                   它不等待首帧（见 window_manager-0.4.3
        ↓                                   lib/src/window_manager.dart:113-153，callback 在末尾直接调用）
windows/runner/flutter_window.cpp:30-32  模板遗留：SetNextFrameCallback([&]{ this->Show(); })   ❌ 元凶
        ↓
windows/runner/win32_window.cpp:178-180  ShowWindow(hwnd, SW_SHOWNORMAL) → 窗口出现在桌面
        ↓
登录阶段前台锁使这次 Show() 未能激活窗口 → 收不到 WM_NCACTIVATE
        ↓                                → 无 focus 事件 → 窗口就一直挂在桌面上不动
用户点击窗口 → 激活 → window_manager_plugin.cpp:208-212 发 "focus"
        ↓
lib/main.dart:842-855                    onWindowFocus()：isSilentMode && !userRequestedWindow → hide()
        ↓                                → 退回托盘（这就是「点一下才消失」）
```

**结论**：`hide()` 跑在 `Show()` 之前，所以被覆盖。「点一下才消失」不是另一个 bug，
是同一个链条的第 6 环（`onWindowFocus` 的焦点窃取拦截本意是对的，只是被当成了兜底触发器）。

**官方依据**：`window_manager-0.4.3/README.md:454-464` 明确要求删掉 `flutter_window.cpp`
里的 `this->Show()`（"Since flutter 3.7 new windows project" 一节）。
本仓 `win32_window.cpp:161-165` 的 `CreateWindow` 早已不带 `WS_VISIBLE`，
所以 `flutter_window.cpp:30-32` 是**全流程唯一**会显示窗口的地方。

## 2. 为什么不能在 Dart 侧解决

- Dart 的 `hide()` 在 `runApp()` 之前执行，必然早于首帧 → 早于 `Show()`，**抢不过**。
- Dart 侧收不到 `show`/`hide` 事件（`window_manager-0.4.3/lib/src/window_manager.dart:52-71`
  的 funcMap 里没有 `kWindowEventShow`），无法在「窗口被显示」时响应。
- 首帧后再 `hide()` 只能把「停留到点击」缩短成「闪一帧」，**不能保证零闪现**
  （平台线程 `ShowWindow` 与 UI 线程 hide 存在竞争）。
  → 故最终方案落在原生侧：**静默启动时根本不调用 `Show()`**。

## 3. 实现（改了什么）

`windows/runner/flutter_window.cpp`：

1. `:1` 加 **UTF-8 BOM**（见 §4 陷阱），`:3` 加 `#include <algorithm>`，`:7` 加 `#include "utils.h"`
   （复用 `utils.cpp:24-42` 的 `GetCommandLineArguments()`）。
2. `OnCreate()` 内（`:32-53`）先解析启动参数，命中 `--silent` / `-s` 时首帧回调不再 `Show()`：

```cpp
const std::vector<std::string> startup_args = GetCommandLineArguments();
const bool silent_start =
    std::find(startup_args.begin(), startup_args.end(), "--silent") != startup_args.end() ||
    std::find(startup_args.begin(), startup_args.end(), "-s") != startup_args.end();

flutter_controller_->engine()->SetNextFrameCallback([&, silent_start]() {
  if (!silent_start) {
    this->Show();
  }
});
```

参数写法与 Dart 侧 `lib/main.dart:307-309` 的 `_parseSilentArg`（`--silent` / `-s`）保持一致
——**两处必须同步改**，代码里已互相注明。

> 为什么不干脆删掉 `Show()` 让 Dart 自己 show：`lib/main.dart:504` 的 `windowManager.show()`
> 跑在 `runApp()` 之前，窗口会提前显示成空白窗 → 正常启动反而变差。条件化才是最小变更。

## 4. 🔴 关键陷阱：`/WX` + 无 BOM 的中文注释 = 编译失败

`windows/CMakeLists.txt:42` 是 `target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")`
—— **`/WX` 把警告当错误**。`flutter_window.cpp` 原本没有 BOM，MSVC 按 CP936 读文件，
一旦新增的中文注释里出现「CP936 无法表示的字节对」，就会报 **C4819 → error C2220** 直接失败。

实测（`Zs` 语法检查，带 `/W4 /WX`）：

| 版本 | 结果 |
|------|------|
| 原模板版 | `EXITCODE=0` |
| 加中文注释但无 BOM | `error C2220: 以下警告被视为错误` + `warning C4819` → `EXITCODE=2` ❌ |
| 加中文注释 + **UTF-8 BOM** | `EXITCODE=0` ✅ |

同目录 `win32_window.cpp` 就是「BOM + 中文注释」，可作对照；`quick_window.cpp` 同为中文注释
但恰好没有触发 C4819，属**随机性陷阱**，别赌。

**维护约定**：以后往 `windows/runner/*.cpp` 写中文注释，先确认该文件有 UTF-8 BOM。

## 5. 影响面

| 路径 | 变化 |
|------|------|
| 注册表自启（`--silent`） | 窗口**完全不出现**，只进托盘（本次目标） |
| 双击 exe / 开始菜单 / `flutter run`（无参数） | 完全不走新分支，行为字节级不变 |
| `--launch-game "标题"` 快捷启动 | 不含 `--silent` → 照旧显示窗口后启动游戏（符合原设计） |
| `onWindowFocus` 焦点窃取拦截（`main.dart:842-855`） | **保留未动** —— 仍是「游戏退出后隐藏窗口被顶到前台」的防线 |
| 托盘、单实例锁、「显示窗口」请求文件链路 | 不受影响 |

附带收益：静默启动时不再有 `ShowWindow` 抢前台，开机时不会突然跳到别的程序前面。

## 6. 验证记录

- ✅ **语法编译通过**：`cl /Zs /std:c++17 /W4 /WX /wd4100 /EHsc`（对齐 CMakeLists 设置）
  + 与 CMake 一致的 INCLUDE（`windows`、`windows/runner`、`windows/flutter/ephemeral*`），
  改后版 `EXITCODE=0`、零 warning；改前版同样 `EXITCODE=0`（基线干净，无新增诊断）。
  工具：`.workbuddy/syntax_check.bat`。
- ⚠️ **未做**完整构建（`chrono_tide.exe` 当时正在运行 PID 25232，重建会撞文件锁 LNK1104，
  且可能干扰开发者正在使用的实例）→ 需开发者关掉软件后在自己终端重建。
- ⚠️ **未做**真机走查（见 §7 清单）。

## 7. 待办 / 走查清单

1. 关闭正在运行的 `chrono_tide.exe` → `flutter\bin\flutter.bat build windows --release` → 打包。
2. 命令行直接验：`"<exe>" --silent` → 期望：桌面上**没有任何窗口**、托盘图标在、
   任务管理器有进程；点托盘图标 → 窗口正常出现且渲染正常；再关 → 回托盘。
3. 无参数启动 → 窗口照旧在首帧后出现（不能出现"提前露出空白窗"的回归）。
4. `--launch-game "<游戏标题>"` → 窗口正常显示 + 游戏启动。
5. **真机重启一次**（唯一能覆盖「登录阶段前台锁」场景的验证）。
6. `reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v ChronoTide`
   → 值应仍为 `"<路径>" --silent`。

## 8. 已知风险

- **R1（中）**：窗口「从未被 Show 过」是否影响托盘/渲染。缓解：当前代码在 `hide()` 之前
  窗口也从未显示过，整个启动期本来就在「未显示」状态下跑通，风险可控；走查第 2 条覆盖。
- **R2（中，未处理，待拍板）**：静默启动时 `lib/main.dart:547 → :556 restoreFromPrefs()`
  会在**隐藏窗口**上执行 `setFullScreen` + FFI 铺屏（`lib/big_picture/big_picture_manager.dart:34-63`）。
  修复前窗口是可见的，所以全屏切换发生在可见窗口上；现在改为隐藏窗口上有潜在不确定性
  （`main.dart:518-523` 的注释警告过「未就绪窗口上 setFullScreen → 客户区异常」）。
  开发者拍板：**先不改，重建后真机验证再定** → 走查时请把「上次退出时处于大屏模式」列为必测项。
- **R3（低）**：参数解析在两处（Dart `_parseSilentArg` ↔ 原生 `--silent/-s`），需同步维护
  （已在两处代码注释中互相指路）。
- **R4（低）**：必须重建 exe 才生效；不重建时行为与修复前完全一致（不会更糟）。

## 9. 明确不改

`lib/main.dart:842-855`（焦点守卫）、`win32_window.cpp`、`main.cpp`、
`lib/services/autostart_service.dart`、`lib/services/tray_service.dart`、
`lib/services/app_state.dart`、`lib/big_picture/big_picture_manager.dart`、
`chrono-tide-opensource/` 镜像。

## 10. 只报告未处理（P2，既有行为）

`lib/main.dart:669-681` 在首帧后 100ms **无条件**调 `_showUpdateDialogIfNeeded()`
（`:610-626`，恒传 `silent: false`）。静默启动时会往隐藏窗口的 Navigator 上压一个更新对话框，
用户点开窗口才会看到。非本次引入；若要收敛，可在静默模式下改走静默检查、
等窗口首次显示再弹 —— 另行评估。
