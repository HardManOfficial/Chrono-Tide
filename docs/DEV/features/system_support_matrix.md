# 系统支持矩阵与 Windows 版本兼容口径

> 建立：2026-11-14　状态：已生效（安装器门禁 + 官网文案）　适用：Chrono Tide 3.1.8 及后续 Windows 版
> 本文是「支持哪些系统、为什么、报障怎么判」的**唯一口径**。改动 iss 门禁或官网文案前先读这里。

## 1. 结论

| 项目 | 结论 |
|------|------|
| 官方支持 | **Windows 10 / 11，64 位（x64）** |
| 不支持 | Windows 7 / 8 / 8.1、Windows 10/11 的 32 位版本、Windows Server 2008 R2 及更早 |
| 32 位兼容包 | **不做**（2026-11-14 裁决，见 §6） |
| Win11 ARM64 | 靠系统 x64 模拟可运行，安装器放行（`x64compatible`），但未做专项测试 |
| 最低运行库 | Visual C++ 2015-2022 **x64** 运行库（VCRUNTIME140 / VCRUNTIME140_1 / MSVCP140 / UCRT） |

**这不是打包 bug，是产品既定边界。** 之前的真实现象是「安装器没有版本门禁 → Win7 用户能一路装完 → 最后一步启动主程序时被加载器拦下报缺 DLL」，用户主观感受变成「连安装都完成不了」。

## 2. 硬证据

1. **产品自述**：`CHANGELOG.md`、官网 `CTWEB/index.html`、`docs/DEV/release_notes_v3.1.0.md` 均写「Windows 10 / 11（64 位）」；`windows/runner/runner.exe.manifest:10-11` 的 `supportedOS` 只声明 Win10/11（含 Win10 才有的 PerMonitorV2）。
2. **引擎**：`env/toolchains/flutter/version` = **3.24.3**。Flutter 官方支持矩阵 Windows 只列 10/11；**3.22 起停止支持 Win7/8**，Dart 3.3 / Flutter 3.19 是最后支持的版本。RustDesk 对 3.24.x 的实操结论是必须改引擎（`GetHostNameW`、`PathCchCombineEx` 等 Win8+ API）才能跑 Win7。
3. **本机 Release PE 导入表实测**（Python 解析 `build/windows/x64/runner/Release`）：
   - `chrono_tide.exe` 与全部插件 DLL → `VCRUNTIME140.dll`、`VCRUNTIME140_1.dll`、`MSVCP140.dll`、`api-ms-win-crt-*`
   - `flutter_windows.dll` → **`api-ms-win-core-path-l1-1-0.dll`**（PathCch API set，Win8+ 才有）
   - `onnxruntime.dll` → 30+ 个 `api-ms-win-core-*`；`video_player_win_plugin.dll` → `MFPlat.DLL` / `d3d11.dll`；Magpie 的 `Microsoft.UI.Xaml.dll` → WinRT 组件
   - 所有 PE 均为 **PE32+（x64）**
4. **工具链无 x86 目标**：Flutter 3.24.3 的 `commands/build_windows.dart:27` 不提供 `--target-platform`（`flutter_command.dart:1043-1060` 无该选项，仅 apk/aab/bundle/aar/linux 有）；`build_info.dart:758-778` 只认 `windows-x64` / `windows-arm64`；`windows/build_windows.dart:169-174` 的 `getCmakeWindowsArch` 只返回 `x64` / `ARM64`；引擎缓存只有 `windows-x64{,-release,-profile}`。

## 3. 两类「缺 DLL」必须分开判

| 报错 DLL | 归属 | Win10/11 精简系统 | Win7 / 8 / 8.1 |
|---------|------|------------------|----------------|
| `VCRUNTIME140.dll`、`VCRUNTIME140_1.dll`、`MSVCP140.dll`、`api-ms-win-crt-*` | VC++ 2015-2022 x64 运行库 / UCRT | **可修**：装 `vc_redist.x64.exe` | 可补这一层，但**补完仍起不来**（见下一行） |
| `api-ms-win-core-path-l1-1-0.dll` | Win8+ 核心 OS API set（PathCch*），由 `flutter_windows.dll` 引入 | 系统自带，不会缺 | **不可修**：KB2999226 / VC++ 运行库都**不提供**这个 API set，微软无官方可再分发包 |

🔴 **KB2999226 的作用范围常被搞混**：它只补 UCRT（`api-ms-win-crt-*` / `ucrtbase.dll`），不补 `api-ms-win-core-path-*`。网上把两者混为一谈的「修复教程」不可信；本项目**禁止**从第三方网站下载 DLL 塞进系统或安装目录。

结论：**Win7 上是引擎级不兼容，装任何运行库都只是把报错往后推**。真要支持 Win7 需降 Flutter ≤3.19 并移植引擎补丁，同时替换 ONNX Runtime、Magpie、video_player_win 等插件，等价于另开一条产品线，已否决。

## 4. 安装器实现（`ChronoTide_Setup.iss`）

| 位置 | 改动 | 原因 |
|------|------|------|
| `[Setup]` | `MinVersion=10.0` | 不设时 Inno Setup 6 默认 `6.1sp1`，会放行 Win7 SP1 |
| `[Setup]` | `ArchitecturesAllowed=x64compatible` | 不设时 32 位安装器默认 `x86compatible`，会放行 **32 位 Win10**（装上却跑不起来）；`x64compatible` 同时放行 Win11 ARM64 的 x64 模拟 |
| `[Messages]` `WelcomeLabel2` | 追加系统要求提示 | 让用户在安装前就看到边界 |
| `[Files]` | `redist\vc_redist.x64.exe` → `{tmp}`，`deleteafterinstall` | 微软官方分发包，只在安装期存在，不留在安装目录 |
| `[Run]` | 运行库静默安装 `/install /quiet /norestart`，`Check: NeedsVCRedist`，排在启动主程序之前 | 消除 Win10/11 精简系统的 `VCRUNTIME140_1.dll` 报错 |
| `[Code]` | `NeedsVCRedist()`：检查 `{win}\System32\vcruntime140_1.dll` 是否存在 | 用 `{win}` 而非 `{sys}`，避免 32 位安装器被重定向到 SysWOW64；已装则跳过，升级安装不重复跑 |

运行库文件：`redist/vc_redist.x64.exe`，来源 `https://aka.ms/vs/17/release/vc_redist.x64.exe`，25,635,768 字节，SHA256 `cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b`，Authenticode 签名 `Microsoft Corporation`（Microsoft Code Signing PCA）。**升级运行库时替换该文件并更新这三个校验值**，不要改用第三方镜像。

`redist/` 位于项目根且 `pubspec.yaml` 的 assets 是逐项声明（无整目录 `- assets/`），因此**不会被打进 `flutter_assets`**。打包脚本 `Dev/scripts/package.ps1` 不需要改动。

## 5. 已知遗留

- 🔴 **便携版 7z 不受 iss 门禁保护**，也没有自动装运行库的步骤。便携版用户在 Win7 上双击 exe 仍会报缺 DLL，只能靠官网文案与下载页提示。若后续要给便携版加保护，需在其打包链路单独做（本次未做）。
- **已分发的旧安装包**（含 2026-11-14 00:35 构建的 `ChronoTide_Installer_v3.1.8.exe`）不含新门禁与运行库，必须重新执行打包才生效。
- **官网下载卡片仍写 v3.0.0 / 约 51 MB**，属既有的过时信息，本次未改（不在任务范围）。
- 未做真机验证：Win7 / Win10 32 位上双击安装包应显示 `WindowsVersionNotSupported`；Win10/11 无运行库环境应自动装好并正常启动。

## 6. x86 32 位兼容版的裁决（2026-11-14）

曾计划「x86 32 位附带兼容包」（同步主线源码 → `flutter build windows --target-platform=windows-x86` → 独立 Inno 包）。只读审计后确认**前提不成立**：该命令在本工具链不存在（§2.4），且用户约定的 Win7 兼容方案对 §3 第二行 DLL 无效。用户裁决**取消 x86 方向**，改为本次的 x64 兼容加固。x86 分工规则随之作废，不再同步/编译/打包 32 位包。

## 7. 客服答复话术

> 感谢反馈。Chrono Tide 目前仅支持 **Windows 10 / 11 64 位**，Windows 7 / 8 / 8.1 与 32 位系统无法运行。您截图里的 `api-ms-win-core-path-l1-1-0.dll` 属于 Windows 8 以上系统的组件，无法通过安装运行库补齐，建议升级系统后重新下载最新版安装包。
>
> 若您已经是 Win10/11 且报的是 `VCRUNTIME140_1.dll` / `MSVCP140.dll`，请安装 [VC++ 2015-2022 x64 运行库](https://aka.ms/vs/17/release/vc_redist.x64.exe)（注意必须是 64 位版）；新版安装包已内置，会自动补齐。

收集信息建议固定三项：**系统版本（含是否 SP1）**、**报错里完整的 DLL 名**、**安装版还是便携版**。

## 8. 待办（交回主线维护者）

主项目以下文件在 2026-11-14 存在他人未提交改动，本次**未触碰**，其中「无需额外安装，安装包已内置全部依赖」与新版实际口径（依赖系统 VC++ 运行库，安装版自动补齐）不一致，请自行更正或统一：

- `CHANGELOG.md` 第 105 / 198 / 329 / 416 行
- `docs/DEV/release_notes_v3.1.0.md:33`（「无需额外运行时」）
- `docs/DEV/更新日志_20260913-20261003.md:31`、`更新日志_20260913-20261005.md:33`、`更新日志_20261018-20261027_v3.1.8.md:32`
- `docs/RELEASE_NOTES_v2.0.0.md:21`

历史版本归档是否改写由维护者决定（按最小变更原则本次未改）。另建议：反馈表单增加「系统版本 / 具体 DLL 名 / 安装版或便携版」三个字段；`docs/DEV/DECISIONS.md` 含 2 个 NUL 字节，若要追加 ADR 需先清理编码，本矩阵文档暂代其职。
