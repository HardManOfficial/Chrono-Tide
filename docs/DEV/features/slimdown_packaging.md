# 打包产物瘦身（P0/P1 已落地）—— 体积账本与数据混入治理

> 2026-10-03 · commit `16c67f3` · 状态：**P0/P1 已实施**，P2（onnx 按需下载 /
> split-debug-info / UPX XAML / effects 裁剪 / 双样式合并）经开发者拍板**本次不做**。

## 1. 背景与目标

安装包 v2.1.14 实测 92.7MB（88.4MiB），目标：用户拿到全新干净状态、体积尽可能小、功能无损。
审计口径：LZMA 压缩前原始体积（Release 部署后 + 安装向导资源）≈ 94MB。

## 2. 已落地改动（P0/P1）

| # | 改动 | 文件:位置 | 省幅（原始） |
|---|---|---|---|
| 1 | 安装向导 BMP→PNG（像素级无损，逐像素验证） | `ChronoTide_Setup.iss:33-37`；`Install_bg.png` 2.74MB + `Install_icon.png` 2.70MB（原 BMP 15.3MB 已删） | **9.9MB** |
| 2 | bz/UnRAR/ark 停止复制进 runtime/tools（仅保留 Flutter asset 一份，运行时 `rar_lz4_unzip_service.dart:_ensureToolsExist` 首次解压时释放） | `打包脚本/一键打包.ps1` 5.2 段 | **~3.9MB** |
| 3 | iss Excludes 追加 data 根级 6 个运行时 JSON（此前**直接随包分发**：collections.json 用户收藏、watch_candidates、company_alias_pending、daily_recommendation、company_wall、cleanup_log） | `ChronoTide_Setup.iss:161` | 隐私修复 |
| 4 | 打包清理列表追加 `models`（NSFW 模型释放副本 17MB）与同 6 个 JSON | `一键打包.ps1:427-444` | 打包目录洁净 |
| 5 | 移除 Mali-Regular.ttf 打包（2018 旧字体，代码零引用；[InstallDelete] 保留旧残留清理行） | `ChronoTide_Setup.iss`（原 :162-163 删） | 106KB |
| 6 | 删除零引用资产 `assets/data/vndb_tags_zh_cn.json`（全仓 0 命中）+ pubspec 行 | `pubspec.yaml`（原 :59） | 235KB |
| 7 | PNG 无损重压（PIL optimize level 9，逐像素比对一致） | mode_single −79K / nsfw_work_placeholder −40K / mode_batch −10K / reward_default −11K / dark_emerald_gold −4K；blue_sky、sakura、kanban_shino 已是优化态保留 | 144KB |
| 8 | 死代码删除（16 文件 4503 行，import 闭包 + kernel 编译清单双重验证**不在编译输入**）：BPM 探索页死簇 8 文件（`big_picture_shell.dart:69` 注释自证）、旧 `metadata_service.dart`+`game_metadata.dart`、孤儿 widget 6 个 | 见 commit 文件清单 | 仓库卫生（app.so 不变） |
| 9 | 删除 `.fix_backup_20260809_playtime_magpie/` 隐藏备份目录（3 文件 4223 行，git 已跟踪可恢复） | 同上 | 同上 |
| 10 | 删除 `setCompleted()` 废弃 API（全仓 0 调用方，`@Deprecated` 自证） | `game_data_format.dart`（原 :1056-1064） | 同上 |
| 11 | **P1** Magpie 配置源统一：`windows/runner/magpie/config/config.json` 由 11 模式旧版重置为 assets 模板 15 模式（与代码 `builtInPresets` 逐名一致、顺序一致）。修复既有 bug：旧 config 缺 4 个预设且命名漂移，运行时 `magpie_service.dart:1374-1380` 每次超分启动都会向用户机器 config.json **追加缺失预设**（最多膨胀到 26 模式）；重置后 index 精确匹配、无追加 | `windows/runner/magpie/config/config.json` | 行为修复 |

### 预期效果

- 安装包：92.7MB → **约 79-82MB**（BMP 9.9MB + 工具 3.9MB + 杂项 ~0.5MB，LZMA 后折算）
- 数据混入：超分模板（prefs，10-02 已堵）+ data 根 JSON（本次堵）双链闭合；
  超分出厂预设收敛为与代码一致的 15 档位。

## 3. 未落地（P2，用户拍板暂缓）

1. NSFW onnx 模型（16.8MB）+ onnxruntime.dll（9.2MB）改首次使用按需下载 —— 违背 NSFW 纯本地定位，需产品决策
2. `flutter build --split-debug-info`（app.so 预计省 1.5-3MB，需真机验证符号回溯）
3. UPX 压 `Microsoft.UI.Xaml.dll`（5.6MB，WinRT dll 有崩溃风险，需真机验证）
4. magpie effects 裁剪（~0.7MB，自定义模板兼容风险）
5. `app_style.dart` vs `app_styles.dart` 双样式系统合并（结构性重写，另立项）

## 4. 验证记录

- ✅ 进程内 analyzer（管道 231 环境）：全 lib 312 文件 **errors=0**（warnings=92/infos=36）；全 test 96 文件 **errors=0**
- ✅ stash 基线对照：HEAD 331 文件 vs 改动后 312 文件，warnings/infos 完全一致（92/36）——**零新增诊断**
- ✅ PNG/ICO 逐像素比对；BMP→PNG 逐像素比对
- ⚠️ 未验证：flutter test 终端补跑、真机走查（rar.lz4 解压首次释放路径、超分 15 档位、托盘图标）、**重新打包实测安装包体积**

## 5. 打包脚本的既有事实（本次审计确认，防再误判）

- `一键打包.ps1` 5.6 清理列表**原本就含 cache**；Release 里偶见的大 data/cache
  是「上次打包之后开发者跑了软件」产生，下次打包自动清，非缺陷。
- `打包脚本/` 整目录在 .gitignore（:88），脚本改动不进 git，属项目既有约定。
- `assets/fonts/` 三个字体只经 pubspec `fonts:` 段声明（自动进 flutter_assets/assets/fonts/），无双份。
- `flutter_assets/fonts/` 里是 MaterialIcons-Regular.otf（1.6MB），代码真实使用 Icons.*，保留。
