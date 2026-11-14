# 第三方组件声明

本项目的源码以 MIT 许可开源。以下第三方组件随仓库提供或由程序在运行时调用，
其权利归各自所有者所有；再分发时请以各上游项目的许可条款为准。

## 随仓库提供的运行时依赖

| 组件 | 用途 | 位置 | 说明 |
| --- | --- | --- | --- |
| 7-Zip (`7z.exe` / `7z.dll` / `7za.exe`) | 压缩包解压 | `assets/tools/`、`windows/runner/tools/` | LGPL / BSD 混合，见 7-Zip 官方许可 |
| UnRAR / RAR 工具 | RAR 格式解压 | `assets/tools/` | RARLAB 许可，请确认是否允许再分发 |
| `rar_lz4_unzip.exe` 及配套 DLL | LZ4 / 复合层解压 | `assets/tools/` | 见上游项目许可 |
| Locale Emulator | 日文游戏转区启动 | `windows/runner/locale_emulator/` | 见上游项目许可 |
| Magpie / SDL3.dll | 超分与手柄输入 | `windows/runner/magpie/`、`windows/runner/sdl3/` | Magpie 见上游许可；SDL3 为 zlib |
| Mali / 钟齐志莽行书 | 界面字体 | 仓库根目录 `.ttf` | 请按字体自带许可使用 |
| Flutter / Dart / Skia 等 | 应用框架 | 由 Flutter SDK 提供 | BSD-3 及各自许可 |

> 上述二进制仅用于方便本地构建与运行。若你的分发场景不允许再分发其中某些组件，
> 请自行移除并从上游获取；移除后不影响源码编译。

## 未随仓库提供、运行时按需获取的组件

| 组件 | 用途 | 说明 |
| --- | --- | --- |
| OpenList | 云端存储对接 | 由程序运行时下载，未包含在本仓库 |
| Umi-OCR | OCR 能力（历史素材） | 未包含在本仓库 |
| VC++ x64 运行库 | 安装包运行库 | 由安装包内置，未包含在本仓库 |
| 各元数据平台 API | 游戏资料抓取 | 仅调用公开接口；部分平台需使用者自己的账号凭证 |

## 许可冲突说明

历史开源镜像曾出现 `LICENSE`（MIT）与 README badge（GPL-3.0）不一致的情况；
**本仓库统一为 MIT**，以根目录 `LICENSE` 为准。
