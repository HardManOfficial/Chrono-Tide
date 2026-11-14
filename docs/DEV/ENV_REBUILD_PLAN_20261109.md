# D:\CTLIB 开发环境整顿方案

> 制定日期：2026-11-09
> 状态：**✅ 已执行（方案 B：apps/ 独立目录结构）**
> 执行记录与验证结果见 `DEV_LOG.md` 2026-11-09 条目、`SESSION_HANDOFF.md` 同日条目。
> 备忘：下方 §二 2.1 的「方案 A 原地收纳」为当时推荐的保守方案，**用户最终选择了 2.2 的方案 B**，
> 因此主项目实际位置为 `D:\CTLIB\apps\chrono-tide`，而非 `D:\CTLIB` 根。

---

## 一、现状审计（事实清单）

### 1.1 D 盘空间

| 盘 | 总量 | 已用 | 剩余 |
|---|---|---|---|
| D: | 251 G | **210 G** | **41 G** |
| C: | 197 G | 83 G | 114 G |

### 1.2 D:\CTLIB 内部占用（Top 15）

| 目录 | 占用 | 性质 | 处置 |
|---|---|---|---|
| `.workbuddy/` | **3.9 G** | 探针临时目录（`tmp_s3._temp_layer_0` 672M、`probe_*` 约 1.5G…） | 清到 <200M |
| `gametool/` | 2.9 G | 分支项目（`CTDV-` 内含 3 个工具、`ct_cloud_admin`） | 迁 `projects/` |
| `打包脚本/` | 2.8 G | 其中 `output/` = 2.8G **39 个历史安装包** | 只留最近 3 版 |
| `flutter/` | 2.4 G | 项目内 Flutter SDK（**正确做法**） | 迁 `env/toolchains/` |
| `安装包输出/` | 1.5 G | 22 个历史安装包（与 `output/` **10 个重名**） | 合并去重 |
| `素材/` | 998 M | 设计素材（`新建文件夹` 一个占 533M） | 迁 `assets_src/` 待分类 |
| `shixi_extractor/` | 748 M | 独立 Flutter 工程 | 迁 `projects/` |
| `.git/` | 669 M | 主仓历史 | **保留不动** |
| `chrono-tide-opensource/` | 633 M | 独立镜像仓（自带 git） | **保留不动** |
| `openlist/` | 552 M | 第三方运行时 | 保留（已 gitignore） |
| `其他开发者的项目用于本项目参考/` | 351 M | 参考源码 + 同名 zip | 迁 `ref/` |
| `build/` | 336 M | 构建中间产物 | 可随时重建 |
| `windows/` | 265 M | 主项目原生层 | **保留不动** |
| `FontHook/` | 247 M | 分支项目（`CTFontHook` 自带 git） | 迁 `projects/` |
| `官网/` | 58 M | 独立静态站 | 迁 `projects/` |

### 1.3 D:\CTLIB 之外、但属于本项目的

| 路径 | 占用 | 问题 |
|---|---|---|
| `D:\CTLIB.rar` | **12.4 G** | 全量备份，压在盘上吃掉 30% 剩余空间 |
| `D:\Chrono Tide 工具\` | 767 M | Inno Setup 6 / 7-Zip-Zstd / RAR / LunaTranslator / Gal字体工具 —— **打包必需的编译器在项目外** |
| `D:\Chrono Tide\` | 4.9 G | 已安装的运行实例（含 `Games/` `data/` 真实用户数据） |

> `打包脚本/一键打包.ps1:64-68` 硬编码去 `D:\Chrono Tide 工具\Inno Setup 6\ISCC.exe` 找编译器 —— 这就是「工具散落在外面」的直接证据。

### 1.4 根目录污染（23 个文件）

- **0 字节垃圾**：`**创建**：2026-09-14`、`**审计方式**：治理文件全读`、`**文档性质**：阶段`、`**用户已拍板决策**：①`、`ct_build_probe.txt`
  （成因：PowerShell 重定向时中文被当成参数，写出了以 `**` 开头的空文件）
- **临时 JSON**：`st_p*.json` × 20（2026-09-29 的抓取调试残留）
- **日志/输出**：`analyze2.txt`、`analyze_nas.txt`、`analyze_nas2.txt`、`analyze_output.txt`、`analyze_r2.txt`、`build_output.txt`、`build_output2.txt`、`debug.log`、`unzip_log.txt`、`build_gallery_fix.log`
- **一次性脚本**：`dev_tmp_charset_scan.py`、`dev_tmp_charset.txt`、`dev_tmp_ico2png.py`、`dev_tmp_subset_smiley.py`、`test_full.dart`、`test_ps1.dart`、`test_simple.dart`、`__test.bat`、`__test.ps1`、`__dart_test.ps1`、`dev_rename.py`

### 1.5 历史垃圾

| 路径 | 占用 | 说明 |
|---|---|---|
| `.git_corrupted_20260904_2nd/` | 133 M | 2026-09-01 损坏的旧 .git，现有 `.git` 已健康 |
| `.git_backup_20260904/` | 86 M | 同上 |
| `__recover/` | 41 M | 一个 zip，来源不明 |
| `lib_backup_20260601/` 等 3 个 | 4 M | Git 之前的土办法备份，AGENTS.md §4 已明令废弃 |
| `docs/DEV/*.bak*` | **69 个** | `DEV_LOG.md` 24 个、`SESSION_HANDOFF.md` 27 个、features 18 个 |
| `鎵撳寘鑴氭湰/` | 1 个 log | GBK 乱码目录名（＝「打包脚本」） |
| `LunaBox-main.zip` | 51 M | 与 `其他开发者…/LunaBox-main/` 重复 |

### 1.6 C 盘依赖现状（本次重点）

| 项 | 现状 | 风险 |
|---|---|---|
| `PUB_CACHE` | **未设置** | 下次 `flutter pub get` 会把约 **1.5 G** Dart 包写进 `C:\Users\ChronoTide\AppData\Local\Pub\Cache` |
| `%LOCALAPPDATA%\Pub` | **不存在**（重置时丢失） | 所有第三方包需重新下载 |
| `~/.workbuddy` | 655 M | WorkBuddy 自身运行时，**非项目依赖，不可迁移** |
| Python / Node | 由 WorkBuddy 托管在 `C:\...\.workbuddy\binaries` | 工具运行时，**非项目依赖** |
| Flutter | **已在 `D:\CTLIB\flutter`** ✅ | 唯一做对的一项 |
| Gradle 缓存 | 未生成（Windows 构建不走 Gradle） | 设 `GRADLE_USER_HOME` 兜底 |

### 1.7 工具链可用性

| 工具 | 状态 |
|---|---|
| Flutter 3.24.3 / Dart 3.5.3 | ✅ 在项目内（本次沙箱内 `flutter --version` 报 `ERROR_PIPE_BUSY 231`，属已知环境性抖动，需你在普通终端复验） |
| Git 2.55.0 | ✅ 主仓健康，`master` 分支，HEAD=`67c959e`，有 38 项未提交改动 |
| Inno Setup 6 | ✅ 存在，但在 `D:\Chrono Tide 工具\` |
| 7-Zip / RAR | ✅ 存在，但在 `D:\Chrono Tide 工具\` |
| UPX | ✅ 在项目内 `upx-4.2.4-win64/` |
| 7-Zip（系统级） | ❌ 未安装 |
| Python 3.13 | ⚠️ 仅 WorkBuddy 托管版，无项目级 venv |

---

## 二、目标结构

### 2.1 推荐方案 A：原地收纳（根目录仍是主项目）

```
D:\CTLIB\                        ← 主项目根（Git / Flutter / 打包脚本的既有事实，不动）
│
├── lib/  assets/  test/  windows/  pubspec.yaml  …   ← 主项目源码（一行不动）
├── docs/                                             ← 开发文档（清 .bak，建索引）
├── AGENTS.md  WORKSPACE.md                           ← 规范 + 总导航（新增）
│
├── env\                        【新】开发环境（全部不进 git，可整删重建）
│   ├── toolchains\
│   │   ├── flutter\            ← 从 D:\CTLIB\flutter 移入
│   │   ├── innosetup\          ← 从 D:\Chrono Tide 工具\Inno Setup 6 移入
│   │   └── 7zip\               ← 从 D:\Chrono Tide 工具 移入
│   ├── cache\
│   │   ├── pub\                ← PUB_CACHE 指向这里（1.5G 不再进 C 盘）
│   │   ├── gradle\
│   │   └── tmp\                ← 构建临时目录
│   ├── python\                 ← 项目级 venv
│   └── bin\
│       ├── env.cmd             ← 设 PUB_CACHE / TEMP / PATH
│       └── ct.cmd              ← 统一命令入口（见 §四）
│
├── projects\                   【新】分支项目（各自独立 git，主仓 gitignore）
│   ├── ct-cloud-admin\         ← gametool\ct_cloud_admin
│   ├── ct-devtool\             ← gametool\CTDV-
│   ├── ct-font-hook\           ← FontHook\
│   ├── ct-website\             ← 官网\
│   └── shixi-extractor\        ← shixi_extractor\
│
├── ref\                        【新】他山之石（351M，只读参考）
│
├── out\                        【新】产物（gitignore）
│   ├── installers\             ← 合并 安装包输出/ + 打包脚本/output/，只留最近 3 版
│   └── builds\                 ← build/ 产物
│
└── archive\                    【新】历史归档（gitignore，可随时删）
    ├── old-installers\         ← 今年以前的安装包
    ├── broken-git\             ← .git_corrupted_* / .git_backup_*
    ├── lib_backup\             ← 3 个 lib_backup_*
    ├── doc-bak\                ← 69 个 .bak 文档
    └── root-junk\              ← 1.4 节那 23 个文件
```

**为什么主项目不搬进 `projects/`：**
`D:\CTLIB` 同时是 Flutter 工程根、Git 仓根、打包脚本推导根（`一键打包.ps1:33` `Split-Path -Parent $ScriptDir`）。
搬走要同步改至少 8 处硬编码（打包脚本、`.iss`、`AGENTS.md`、`.workbuddy/skills/*`、`dev_probe/*.py`、IDE 配置…），
而当前 `flutter` 命令在本机尚不可用（231），**改完没法回归验证**。
按 `AGENTS.md` §2.1「宁可少做」，本轮不动。等 `ct pack` 全链路跑通后，再作为独立任务做目录重构（那时有一键回归验证）。

### 2.2 备选方案 B：彻底平权结构（本轮不做）

```
D:\CTLIB\apps\chrono-tide\   ← 主项目整体迁入
D:\CTLIB\apps\ct-cloud-admin\
D:\CTLIB\env\  ref\  out\  archive\
```
好处：所有项目同级，最直观。代价：见上。**建议放到第二阶段。**

---

## 三、执行计划（分批，每批可单独回滚）

### P0 — 零风险清理（先腾空间，不碰任何代码）

| # | 动作 | 回收 | 风险 |
|---|---|---|---|
| P0-1 | 删根目录 23 个垃圾文件（先移 `archive/root-junk/`） | ~0 | 无 |
| P0-2 | 清 `.workbuddy/` 下 `tmp_*` / `probe_*` / `esrgan_probe` / `_ol_pkg` / `pb_tmp` / `_srv_zip*.zip` | **~3.7 G** | 无（一次性探针产物） |
| P0-3 | `docs/` 下 69 个 `.bak*` 移 `archive/doc-bak/` | ~10 M | 无 |
| P0-4 | `.git_corrupted_*` + `.git_backup_*` + `__recover` + 3 个 `lib_backup_*` 移 `archive/` | 260 M | 无（git 已健康） |
| P0-5 | 删 `鎵撳寘鑴氭湰/`（1 个 log 的乱码目录） | ~0 | 无 |
| P0-6 | 安装包去重：`安装包输出/` + `打包脚本/output/` 合并到 `out/installers/`，只留 v2.1.12/13/14，其余移 `archive/old-installers/` | **~3.0 G** | 低（历史安装包可再生成） |
| P0-7 | `D:\CTLIB.rar`（12.4 G）：**需要你确认** —— 验完 `rar t` 无损后是否删除 | **12.4 G** | 中（唯一全量备份，建议另存移动硬盘再删） |

> P0 合计可回收 **约 19 G**，D 盘剩余从 41 G → 约 60 G。

### P1 — 建立 env（消除 C 盘污染，本方案核心）

| # | 动作 | 说明 |
|---|---|---|
| P1-1 | 建 `env/{toolchains,cache/{pub,gradle,tmp},python,bin}` | 纯新增 |
| P1-2 | `flutter/` → `env/toolchains/flutter/` | 同步改：`打包脚本/一键打包.ps1`、`AGENTS.md`、`.workbuddy/skills/chronotide-dev/SKILL.md`、`dev_probe/*.py` 里的 `flutter` 路径 |
| P1-3 | `Inno Setup 6` → `env/toolchains/innosetup/`；`7-Zip-Zstandard` → `env/toolchains/7zip/` | 改 `一键打包.ps1:64-68` 的 `$ISCCPaths` 为 env 优先 |
| P1-4 | 写 `env/bin/env.cmd`：设 `PUB_CACHE`、`TEMP/TMP`、`PATH` 前置 | 此后所有命令先 `call env.cmd` |
| P1-5 | 首次 `flutter pub get`，包缓存落在 `env/cache/pub`（约 1.5 G，在 D 盘） | 验证 C 盘 `AppData\Local\Pub` 仍不存在 |
| P1-6 | 建 `env/python/venv`（system python 建，venv 本体在 D 盘） | 给 `dev_probe/*.py` 用 |
| P1-7 | 写 `WORKSPACE.md`：一页说明「这里是哪、每个文件夹干什么、日常只用哪 3 条命令」 | 面向非专业读者 |

### P2 — 分支项目归位

| # | 动作 | 前置检查 |
|---|---|---|
| P2-1 | `gametool/ct_cloud_admin` → `projects/ct-cloud-admin` | 非 git 仓 ⇒ 先 `git init` + 首次提交，再搬 |
| P2-2 | `gametool/CTDV-` → `projects/ct-devtool` | 含 4 个子目录，逐个确认 |
| P2-3 | `FontHook/` → `projects/ct-font-hook`（自带 git，整目录搬） | 打包脚本引用 `FontHook\CTFontHook\dist` ⇒ 同步改路径 |
| P2-4 | `官网/` → `projects/ct-website`（先 `git init`） | 官网含 `V2.0.0/V3.0.0/CTWEB-*` 多版本快照，需先分清「当前线上版」 |
| P2-5 | `shixi_extractor/` → `projects/shixi-extractor`（先 `git init`） | 确认是否仍在维护 |
| P2-6 | `其他开发者的项目用于本项目参考/` → `ref/`，删除与目录重复的 zip | 无 |
| P2-7 | 主仓 `.gitignore` 追加 `/env/ /projects/ /ref/ /out/ /archive/` | 无 |

### P3 — 流水线脚本（见 §四）

---

## 四、开发流水线（需求 → 想法 → 上线，你不碰代码）

### 4.1 六个阶段，你只需在 ★ 处说话

| 阶段 | 谁做 | 产物 | 你要做什么 |
|---|---|---|---|
| ① 提想法 | 你 | `docs/REQ/<日期>-<主题>.md` | 用大白话讲，可以只发语音转文字 ★ |
| ② 审计 + 方案 | AI | 《变更计划》：改哪些文件 / 影响面 / 风险 / 怎么验 | 看一遍，回「**批准**」或「**改这里**」 ★ |
| ③ 实现 | AI | 代码改动 | 不用管 |
| ④ 自动验证 | AI | `ct check` + `ct test` 报告 | 只看结论：红/绿 |
| ⑤ 实机测试 | AI + 你 | `ct run` 启动 + 自动截图 | 看截图说「过」或「第 2 张按钮偏了」 ★ |
| ⑥ 打包发布 | AI | `out/installers/ChronoTide_Installer_vX.Y.Z.exe` | 双击装一遍，说「OK」 ★ |

### 4.2 命令入口：`env\bin\ct.cmd`

你以后**只需要记这一条命令**（在 `D:\CTLIB` 里打开终端输入 `ct xxx`）：

| 命令 | 作用 | 何时用 |
|---|---|---|
| `ct doctor` | 环境体检：Flutter/Git/ISCC/7z/磁盘/PUB_CACHE 全查，缺什么直接告诉你 | 每周一次，或报错时第一件事 |
| `ct get` | 拉依赖（PUB_CACHE 指向 D 盘） | AI 说「依赖变了」时 |
| `ct check` | 静态检查，只报**新增 error**（与基线比） | AI 每次改完自动跑 |
| `ct test` | 跑测试（`ct test` 全量 / `ct test test/services` 定向） | 同上 |
| `ct run` | 启动开发版（不打包，秒级） | 想马上看效果时 |
| `ct pack` | 一键打包（内部调 `打包脚本\一键打包.ps1`） | 阶段 ⑥ |
| `ct publish` | 打 tag + 生成发布说明（**上传前二次确认**） | 阶段 ⑥ 之后 |

> 这些脚本藏在 `env/bin/`，你看不到也不用看。`ct.cmd` 顶部会写一行注释说明它是干什么的。

### 4.3 自动化边界（诚实说明）

- **能全自动**：静态检查、单元/Widget 测试、打包、版本号与 changelog 生成。
- **只能半自动**：UI 视觉是否符合预期（能自动截图，但「好不好看」要你判断）、游戏库真实扫描/启动、网络源抓取（受墙/限流影响）。
- **必须你手动**：安装包双击安装验证、真机长时间运行、发布到外部平台前的最终确认。

---

## 五、明确不做（本轮）

1. ❌ 不动 `lib/`、`assets/`、`test/`、`windows/`、`pubspec.yaml` 的任何一行。
2. ❌ 不动 `chrono-tide-opensource/`（独立镜像仓）。
3. ❌ 不动 `D:\Chrono Tide\`（已安装实例 + 用户真实游戏数据）。
4. ❌ 不动 `.git/`（669M 历史，不 gc、不 repack）。
5. ❌ 不重命名任何 Dart 文件、不改任何业务逻辑。
6. ❌ 不升级 Flutter / Dart / 依赖版本。
7. ❌ 不把主项目搬进 `projects/`（留到第二阶段）。
8. ❌ 不删 `D:\CTLIB.rar`（等你确认）。

---

## 六、验证方式

| 阶段 | 验证 |
|---|---|
| P0 | `du -sh` 前后对比；`git status` 无新增改动（垃圾文件本就不被跟踪） |
| P1 | `ct doctor` 全绿；`flutter pub get` 后 `%LOCALAPPDATA%\Pub` 仍不存在；`flutter analyze lib` error 数 = 0 |
| P2 | 每个项目移动后 `git status` 干净 / `flutter analyze` 通过；`ct pack` 能完整产出安装包 |
| P3 | `ct check` / `ct test` / `ct pack` 三条命令各跑通一次 |

---

## 七、风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 移动 `flutter/` 后构建脚本找不到 SDK | **高** | 先 grep 全仓 `flutter` 硬编码路径，一次性改完再移；移完立刻 `ct check` 验证 |
| 打包脚本 `$FontHookDistRoot` 路径失效 | 中 | P2-3 与脚本改动同批提交 |
| 分支项目未入 git，搬迁途中丢文件 | **高** | 搬前先 `git init` + 全量提交；或用 `robocopy /MOVE` 并对比文件数 |
| `D:\CTLIB.rar` 删了才发现备份不全 | 中 | 先 `rar t` 校验；建议另存一份到移动硬盘 |
| 环境重置导致 Flutter 依赖全丢 | 已发生 | P1-5 一次性重拉，落在 D 盘 |
| 231 错误导致无法验证 | 中 | 先在普通终端手动跑一次 `flutter --version` 确认，再执行 P1 |

---

## 八、需要你拍板的 4 件事

1. **方案 A（原地收纳）还是方案 B（彻底重构 apps/ 结构）？** —— 建议 A。
2. **`D:\CTLIB.rar`（12.4 G）怎么处理？** —— 建议校验后另存移动硬盘再删。
3. **`shixi_extractor`（748M）还在用吗？** —— 不用就进 `archive/`，能再省 748M。
4. **执行节奏**：一次性做完 P0+P1，还是先只做 P0（清空间），看效果再继续？
