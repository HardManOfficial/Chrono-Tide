# 第三方组件声明与致谢

本文件列出 Chrono Tide 使用、内置或参考的第三方组件、开源项目、字体、模型与数据服务，并说明再分发时的许可边界。

> **许可范围**：仓库根目录 `LICENSE` 的 **MIT** 许可仅覆盖 Chrono Tide 自身源码。
> 第三方组件的权利归各自所有者所有，**再分发时请以各上游许可为准**。
> 本文档为整理与致谢，不构成法律意见；如对某个组件的再分发条件存疑，请直接查阅其上游许可或咨询权利人。

---

## 1 · 随仓库源码提供的运行时二进制

以下文件随本仓库提供，仅用于方便本地构建与运行；移除后不影响源码编译。

| 组件 | 用途 | 位置 | 许可 / 说明 |
| --- | --- | --- | --- |
| **7-Zip** `7z.exe` / `7z.dll` / `7za.exe`（含 `Far/` 插件、`x64/7za*`） | 压缩包解压、归档、备份加密 | `windows/runner/tools/` | LGPL-2.1+ / BSD 混合；许可文本见 7-Zip 官网，**本仓库未随附** `License.txt` |
| **Bandizip 命令行** `bz.exe` + `ark.x64.dll` / `ark.x64.lgpl.dll` / `bdzshl.x64.dll` | `.lz4` / `.rar.lz4` 外层解压 | `assets/tools/` | 随附二进制，权利归 Bandizip 所有；再分发前请自行确认其许可 |
| **UnRAR** `UnRAR.exe` | RAR 内层解压 | `assets/tools/` | RARLAB UnRAR License，含再分发限制，请阅读上游条款 |
| **Locale Emulator** `LEProc.exe`、`LEGUI.exe`、`LEInstaller.exe` 及配套 DLL / 语言包 | 日文游戏转区启动 | `windows/runner/locale_emulator/`、`locale_remulator/` | 见上游项目许可 |
| **Magpie** `Magpie.exe`、effects / config / 运行库 | 游戏窗口超分辨率增强 | `windows/runner/magpie/` | 见上游项目许可 |
| **SDL3** `SDL3.dll` | 大屏模式手柄 / 输入层 | `windows/runner/sdl3/` | **zlib License**，许可文本随附于 `windows/runner/sdl3/LICENSE.txt` |

> ⚠️ 上述二进制中，7-Zip 的许可文本、Bandizip / UnRAR / Locale Emulator / Magpie 的许可文本**未随本仓库提供**。
> 若你的分发场景不允许再分发其中某些组件，请自行移除并从上游获取。

## 2 · 随发行版内置、但未随源码仓提供的组件

这些组件由打包脚本在构建 / 安装阶段部署到 `runtime/`，**本仓库不包含其二进制**，
但软件「关于应用」页会列出致谢（与设置页 `_buildAboutCredits()` 保持一致）。

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| **CTFontHook 0.1.1**（`winmm.dll` 代理劫持，32/64 位两套） | 游戏字体替换 | MIT License |
| **Microsoft Detours 4.0.1** | CTFontHook 的底层挂钩依赖 | MIT License |

部署逻辑见 `lib/services/game_font_patch_service.dart` 与打包脚本的 FontHook 节；
不兼容游戏清单为纯本地只读文件 `resources/fonthook/incompatible.json`。

## 3 · 字体、模型与演示素材

| 资源 | 用途 | 许可 / 来源 |
| --- | --- | --- |
| **Smiley Sans（得意黑）** | 中文装饰大标题 | SIL Open Font License |
| **Outfit** | 英文 / 数字装饰 | SIL Open Font License |
| **Noto Sans SC** | UI 正文字体 | SIL Open Font License（Adobe + Google） |
| **Mali**、**钟齐志莽行书** | 手写风格字体 | 请按字体自带许可使用 |
| **anime_dbrating**（MobilenetV3 ONNX 权重） | 本地 NSFW 判定推理 | **OpenRAIL**，来源 Hugging Face `deepghs/anime_dbrating`；来源、模型卡与本地化口径见 `assets/models/anime_dbrating_mv3_v0.LICENSE` |
| **Coverr / Mixkit** 素材许可页 | 背景视频与演示素材来源说明 | 见 `dev_probe/docs/coverr.co_license.html`、`mixkit.co_license_.html` |
| 34 张系统头像、主题背景、界面插画 | 应用内置素材 | 项目自制 |

上述字体均经子集化后随包提供，子集化不改变其原始许可。

## 4 · Dart / Flutter 开源依赖

来自 `pubspec.yaml`（版本约束以文件为准），按用途分组：

- **窗口 / 交互**：`window_manager`、`system_tray`、`desktop_drop`、`file_picker`、`flutter_svg`、`auto_size_text`、`video_player` / `video_player_win`
- **图片 / 图表 / 缓存**：`cached_network_image`、`flutter_cache_manager`、`fl_chart`
- **网络 / 数据 / 加密**：`dio`、`http`、`pocketbase`、`crypto`、`pointycastle`、`archive`
- **平台 / 存储**：`ffi`、`onnxruntime`、`path` / `path_provider`、`shared_preferences`、`package_info_plus`、`file`、`uuid`（override）
- **框架**：Flutter SDK / Dart SDK / Skia 及其依赖链

感谢 Flutter / Dart 团队与各包维护者。各包许可（多为 BSD-3 / MIT / Apache-2.0）见其上游仓库与 pub.dev 页面；
执行 `flutter pub get` 后，也可在 pub 缓存目录内查阅各包自带的 `LICENSE`。

## 5 · 未随仓库提供、运行时按需获取的服务与组件

| 组件 / 服务 | 用途 | 说明 |
| --- | --- | --- |
| **OpenList**（Alist 衍生） | 云端文件服务对接 | 程序运行时按需下载与对接，未包含在本仓库；未对接不产生任何下载 |
| **PocketBase** | 账号、云端元数据沉淀、资源与分享后端 | 由部署方自行搭建，未包含在本仓库 |
| **Umi-OCR** | 历史 OCR 素材（早期调研） | 未包含在本仓库 |
| **VC++ x64 运行库** | 安装包运行库 | 由安装包内置，未包含在本仓库 |
| 各元数据平台 API | 作品资料抓取 | 仅调用公开接口；部分平台需使用者自己的账号凭证 |

## 6 · 数据、资料与社区合作方

Chrono Tide 的作品资料与资源检索能力建立在以下开放接口与资料站点之上，在此一并致谢：

**Bangumi · VNDB · 月幕GAL · Steam · SteamGridDB · 2DFan · 鲲GAL · Kungal · NextMoe · Hikarinagi**

以及补丁与资源侧的多源站点（鲲 / 社区 / 2DFan）、各大民间汉化组，和所有提交反馈、参与测试、分享资源的用户。

> 这些站点与本项目**无隶属或背书关系**；本项目仅调用公开接口或读取公开页面，
> 使用相关能力时请遵守各站点的服务条款、速率限制与版权要求。汉化内容版权归对应汉化组所有。

## 7 · 上游项目与设计参考

| 项目 | 关系 |
| --- | --- |
| **LunaBox** | `lib/packages/luna_metadata_sdk/` 的原始 Go 实现与设计参考 |
| **Playnite** | 透明艺术字标题图等交互设计的灵感来源 |
| **Alist / OpenList** | 云端文件服务方案的上游生态 |
| **7-Zip / Bandizip / UnRAR / Locale Emulator / Magpie / SDL3 / CTFontHook / Detours / ONNX Runtime** | 见 §1、§2、§4 |

> 📌 **关于元数据 SDK 子包**：`lib/packages/luna_metadata_sdk/README.md` 提及上游 LunaBox 并写有
> `AGPL v3` 字样，但该子包**未附带独立的 LICENSE 文件**，而仓库根 `LICENSE` 为 MIT。
> 这是历史文档口径，本仓库并未据此对子包单独授权。若你计划**单独再分发该子包**，
> 请先核对其上游许可并与权利人确认；仅按本仓库整体使用 Chrono Tide 时，以根 `LICENSE` 为准。

## 8 · 许可一致性说明

历史开源镜像曾出现 `LICENSE`（MIT）与 README badge（GPL-3.0）不一致；**本仓库统一为 MIT**，以根目录 `LICENSE` 为准。
设置页「关于应用」右下角的常驻致谢（SDL3 · zlib / CTFontHook 0.1.1 · MIT / Microsoft Detours 4.0.1 · MIT）
是面向终端用户的精简版，完整清单以本文件为准。

---

如发现本清单有遗漏或许可信息有误，欢迎通过
[Issues](https://github.com/HardManOfficial/Chrono-Tide/issues) 告知，我们会及时更正。
