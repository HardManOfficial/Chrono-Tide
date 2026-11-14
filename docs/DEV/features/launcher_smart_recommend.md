# 功能档案：启动程序智能推荐

| 项 | 值 |
|----|-----|
| **状态** | 已上线（代码 + 规则探针全绿；缺真机 UI 走查） |
| **优先级** | P1 |
| **创建日期** | 2026-10-26 |
| **最后更新** | 2026-10-26 |
| **关联需求单** | —（用户口头需求，原文见 §1） |
| **关联决策** | ADR-021 |

---

## 1. 目标：解决什么问题

用户原话：

> 在游戏启动程序选择界面中，自动扫描并识别游戏目录下的所有可执行启动程序，将其分类为两类
> ——无关程序（如运行库补全/删除工具、其他辅助程序）与游戏相关启动程序；对于游戏相关程序，
> 需区分不同版本（如 HD 超清版与原版、原版与魔改版、汉化版与其他语言版）。系统应重点判断并
> 推荐汉化版本……最终在原有启动程序列表的对应位置上以推荐角标形式提示用户"这可能是你需要的
> 启动程序"，且推荐的程序必须为可正常点击运行的有效启动程序。

真实痛点：一个 galgame 目录常常扫出 10~20 个 exe（`vcredist_x64`、`config`、`cg回収`、
`Softhouse`、`SofthouseHD`、`SofthouseChs`、`汉化补丁`、`unins000`……），列表按路径字母序
排列，用户根本分不清点哪个能进游戏，更别说分辨"HD 版 / 原版 / 汉化版"。

## 2. 用户可见行为

- 打开「选择启动程序」或「启动管理」后，列表**顺序与改动前完全一致**（仍按路径字典序）。
- 被判定为「游戏相关且最可能是本体」的那**一个**程序，文件名右侧出现琥珀色 `★ 推荐` 角标。
- 列表顶部多一行提示：`已为你标出 1 个最可能是你需要的启动程序（汉化版）`。
- 每行第二行（相对路径）尾部追加版本词缀：`· 汉化版` / `· HD 版` / `· 原版` / `· 魔改版` / `· 日文版`。
- 被判定为「无关」的程序，文件名右侧出现灰色 `工具` 角标（**不隐藏、不折叠、不移位**）。
- 鼠标悬停角标显示完整判定依据（如「这可能是你需要的启动程序（汉化版）／文件名含汉化标记 · 与别名「Softhouse」相似 · 同目录 5 个游戏资源」）。
- **不改变默认选中项**：选中逻辑仍是原来的「已保存路径 → 否则第一个」，推荐只是提示。

## 3. 设计思路：为什么这么做

### 3.1 四层单向流水线

```
① 有界扫描（复用 ExeScanner）→ ② 证据提取（打分）→ ③ 分类与版本 → ④ 推荐与校验
```

每层只依赖上一层，**没有回环、没有学习、没有云端**：离线可用、结果可解释、可单测。

### 3.2 为什么不扩展 `game_launcher_detector.dart`

项目里已有一套"挑一个 exe"的规则（`game_launcher_detector.dart:109-195`），但它三个硬伤：

1. **只输出单个结论** —— 无法表达"分类"，拿不到"哪些是工具"。
2. **`patch` 被当成汉化正信号**（`:5-15` 的 `_localizationKeywords`）—— 而在展示层必须能区分
   「汉化补丁安装器」与「汉化后的游戏本体」，两者同名同词，语义相反。
3. **它是导入期调用的**（自动导入 / 批量导入共用 `detect()`）—— 改它会动摇导入链路。

所以**新建独立分类器，原检测器一行不动**。代价是两套命名规则并存，见 ADR-021 的权衡。

### 3.3 匹配粒度必须分级（本功能最容易踩的坑）

短标记歧义极大，绝不能用统一的「contains」判：

| 标记 | 正确粒度 | 用子串匹配会怎样 |
|---|---|---|
| `sc` | **整 token 相等** | `scene.exe` / `disc.exe` / `muscle.exe` 全部误判汉化 |
| `cn` | 整 token 相等 **或** 粘连后缀 | `encyclopedia`（不含 cn，安全）；但 `techs`/`archs` 以 `chs` 结尾会误判 |
| `chs` | 整 token 相等 **或** 粘连后缀 | — |
| `cht` | 整 token 相等 | `yacht` 会误判 |
| `hd` | 整 token 相等 **或** 粘连（token 长度 ≥5） | `method` / `thread` 会误判 |

粘连后缀只开放 `cn` / `chs` / `zh` 三个（`_hanhuaGlueSuffixes`），其余短标记一律整 token 比较。
`techs` / `archs` 这类极小概率误判由 `score >= 50` 的推荐门槛兜住，已在代码注释里写明。

### 3.4 中文名 vs 日文汉字名

`恋愛零キロメートル.exe` 也是汉字开头，直接用"含汉字"判中文会大面积误判。判据是**假名排除**：
文件名含平假名/片假名（U+3040–U+30FF）⇒ 判日文，中文信号一条都不给。

### 3.5 分析器只依赖 `dart:io`

本机 `flutter test` 长期受 `ERROR_PIPE_BUSY(231)` 阻断（`.workbuddy/analyze_probe/README.md`
已确认为环境性不可用）。把分析器写成零 flutter 依赖后，可以直接用**裸 Dart VM** 跑真机探针
（`dev_probe/launcher_recommend_probe.dart`），不必上 `gen_kernel_aot` + `flutter_tester`
那一套。项目里中大型服务第一次这么做，后续新服务建议照此办理。

## 4. 实现位置

| 文件 | 职责 | 备注 |
|------|------|------|
| `lib/services/launcher_candidate_analyzer.dart` | **规则层**：分类 / 版本 / 汉化分 / 唯一推荐 / PE 头校验 | 新增，只依赖 `dart:io` |
| `lib/widgets/launcher_badges.dart` | 角标组件：`LauncherRecommendBadge` / `LauncherToolBadge` | 新增，两处弹窗共用 |
| `lib/widgets/exe_selector_dialog.dart` | 「选择启动程序」：跑分析 + 顶部提示行 + 列表角标 | 新增 `gameTitle` / `gameSubtitles` 参数 |
| `lib/widgets/launch_manager_dialog.dart` | 「启动管理」：同上（与已有的架构 pill 并排） | 新增 `gameSubtitles` 参数 |
| `lib/pages/library_page.dart` | 两处调用点传入 `game.title` / `[game.subtitle]` | 桌面库页 |
| `lib/main_container.dart` | 首次启动门禁弹窗传别名 | 🔴 稳定区，改动 2 行 |
| `lib/big_picture/big_picture_shell.dart` | BPM 启动管理传别名 | 改动 2 行 |
| `test/services/launcher_candidate_analyzer_test.dart` | 纯规则断言 33 条 | 231 环境下未执行 |
| `dev_probe/launcher_recommend_probe.dart` | 规则 50 条 + 端到端真目录 | 裸 Dart VM 可跑 |

## 5. 关键数据结构

```dart
enum LauncherKind { game, tool }
enum LauncherVersion { localized, hd, modded, otherLanguage, original }

class LauncherCandidate {
  String path; String fileName; int sizeBytes; int depth;
  LauncherKind kind;
  List<LauncherVersion> versions;   // 至少含 original
  int score;                        // 分类总分
  int hanhuaScore;                  // 汉化信号分（独立累计）
  List<String> reasons;             // 人类可读依据 → tooltip
  bool peChecked; bool peValid; String archLabel;  // 只对推荐前几名校验
  String get versionLabel;          // '汉化 HD 版' / '汉化版' / 'HD 版' / '原版' ...
}

class LauncherAnalysis {
  List<LauncherCandidate> candidates;  // 与输入同序，禁止重排
  String? recommendedPath;             // null = 一个都不标
  LauncherCandidate? get recommended;
  bool isRecommended(String? path);
}
```

## 6. 判定规则全表

### 6.1 硬性排除（一票否决，直接判「无关」，不再看分数）

| 类别 | 关键词（`contains`） |
|---|---|
| 卸载器 | `unins` `uninst` `uninstall` `卸载` |
| 运行库补全 | `vcredist` `vc_redist` `vcrun` `dxsetup` `dxwebsetup` `directx` `oalinst` `openal` `physx` `dotnet` `ndp` `xnafx` `msvcr` `msvcp` |
| 安装包 | `setup` `install` |
| 通用工具 | `7z` `winrar` `unrar` `ffmpeg` |
| **路径祖先目录** | 任意中间目录名含 `redist` / `directx` / `vcredist` / `dotnet` / `installer` |

> 用 `contains` 而非 `startsWith`：真实文件名常带前缀，如
> `Microsoft Visual C++ 2015 Redistributable (x64).exe`。

### 6.2 加分证据

| 代号 | 分 | 判据 |
|---|---|---|
| E1 | +50 / +45 | 归一化名 **完全等于** 游戏标题或目录名（+50）；**以之开头且后缀 ≤6 字符**（+45） |
| E2 | +45 | 含汉字 且 含中文启动词（启动/运行/开始/进入/打开/游玩） |
| E3 | +35 | 与游戏中文名有 ≥3 连续汉字重合 |
| E4 | +25 | 与任一别名（日文原名/英文名/罗马字）有 ≥5 连续 ASCII 字符重合 |
| E5 | +25 | 同目录存在 ≥3 个游戏资源文件（`xp3 arc pac pak cpz pfs sli gxp nsa nsc ks scn dat rgssad ypf grp bin ogg wav`） |
| E6 | +15 | 位于游戏根目录 |
| E7 | +15 | 体积 ≥ 1MB |
| E8 | +12 | 含通用启动词（game/start/launch/launcher/play/run/main/boot/app） |
| E9 | +20 | 含引擎名（Siglus/BGI/AVG32/RealLive/KiriKiri/NScripter/Majiro/Ethornell/CMVS/System40/ADVHD/UnityPlayer…） |

### 6.3 减分证据

| 代号 | 分 | 判据 |
|---|---|---|
| N1 | −45 | 工具词（config/setting/save/savedata/cg/gallery/readme/manual/editor/viewer/extract/unpack/bench/crash/report/verify 或 设定/存档/回想/说明/手册/修改器/查看器/解包） |
| N2 | −50 | 补丁器词（crack/patch/patcher/update/updater/fix 或 汉化补丁/补丁/修正/升级/破解）**且体积 < 3MB** |
| N3 | −20 | 体积 < 256KB |
| N4 | −15 | 深度 ≥ 2 |
| N5 | −10 | 名字以 `_x86/_x64/win32/win64/_32/_64/(32)/(64)` 结尾 |

> N2 的体积门槛是关键：3MB 以上的 `*patch.exe` 基本是**打过补丁的本体**，不是安装器。

### 6.4 汉化判定（H 分独立累计，**≥45** 打「汉化版」标签，并给主分 +20）

| 代号 | 分 | 判据 |
|---|---|---|
| H1 | +60 | 中文词 `汉化/简体/简中/中文`；或整 token `chs/chinese/hanhua/zhcn/zh`；或粘连后缀 `chs/cn/zh`（token 长度 ≥4） |
| H2 | +45 | 中文词 `繁中/繁体/繁體`；或整 token `cn/zho/sc/cht/tc` |
| H3 | +45 / +35 | 含汉字且**不含假名**：带中文启动词 +45；只带「版」字 +35 |
| H4 | +30 | 与游戏中文名有 ≥3 连续汉字重合 |
| H5 | +25 | token 以 `localiz` 开头 |

> H1 与 H2 是 `else if` 关系（互斥），避免 `汉化版_CN.exe` 重复计分。

### 6.5 分类与推荐

- 分类：`命中硬排除` 或 `score < 30` 或 `命中 N1` ⇒ `tool`，否则 `game`。
- 推荐分层（数字小优先）：`汉化+HD(0)` → `汉化(1)` → `HD(2)` → `原版(3)` → `魔改(4)` → `其它语言(5)`。
- 同层按 `score` 降序，再按体积降序。
- 依次校验前 3 名的 **PE 头**（读前 4KB 验 `MZ` + `PE\0\0` + machine），**第一个有效且 score ≥50** 的才成为推荐。
- 一个都不满足 ⇒ `recommendedPath = null`，界面不出现任何推荐角标（宁缺毋滥）。

## 7. 历史决策与踩过的坑

1. **`sc` 做子串匹配会毁掉一切**（2026-10-26 设计期发现）：`scene`/`disc`/`muscle` 全含 `sc`。
   → 结论：短标记一律整 token 比较，只有 `cn/chs/zh` 开放粘连后缀。
2. **日文原名也是汉字开头**（同日）：`恋愛零キロメートル.exe` 若不排除假名会被判成中文版。
   → 结论：假名（U+3040–U+30FF）是"不是中文名"的硬判据。
3. **`汉化补丁.exe` 不能因为含"汉化"就被推荐**（同日）：H1 给 60 分，但 N2 −50 + N3 −20 把
   总分压到 30 以下 ⇒ 仍是 `tool`。**汉化分与分类分必须解耦**，这就是 `hanhuaScore` 独立的原因。
4. **`SofthouseHD.exe` 这种粘连写法很普遍**：`_hdTokens.contains('softhousehd')` 是 false。
   → 结论：HD 增加粘连后缀判定（token 长度 ≥5，阈值比汉化更严）。
5. **`野良与皇女与流浪猫之心CN.exe` 不等于标题**：只做等值比较会漏掉最常见的命名方式。
   → 结论：E1 增加「以标题/目录名开头 + 后缀 ≤6 字符」的次级匹配（+45）。
6. **角标撑破行是本项目的老债**（HALL-FIT-CARDS，2026-10-25）：M3 默认 48×48 触控区曾把
   20px 标题行撑到 48px，导致卡片简介被裁 18px。→ 结论：角标固定 18px、不设最小触控尺寸、
   文件名必须包 `Flexible` + 省略号。

## 8. 当前进度

| 项 | 结果 |
|---|---|
| 规则层实现 | ✅ 完成（`launcher_candidate_analyzer.dart`，约 700 行） |
| 角标组件 | ✅ 完成（`launcher_badges.dart`） |
| 两处弹窗接入 | ✅ 完成 |
| 四处调用点传参 | ✅ 完成 |
| 进程内静态分析 | ✅ 8 文件 **errors = 0**（warning 全部为存量） |
| 裸 Dart VM 真机探针 | ✅ **50/50 PASS**（含端到端：造 9 个 exe 的真实目录 + 合法 PE 头桩文件） |
| `flutter test` | ❌ **未执行**（环境 `ERROR_PIPE_BUSY(231)`，README 已确认本环境不可用） |
| 真机 UI 走查 | ❌ **未做** |

## 9. 需要人工验收的清单

1. 打开一个有多个版本 exe 的游戏（如 `Softhouse` / `SofthouseHD` / `SofthouseChs`）
   → 「选择启动程序」里应只有 1 个 `★ 推荐`，且落在汉化版上。
2. 列表顺序应与你印象中的字母序一致（**没有被重排**）。
3. 无关程序（config / cg回収 / vcredist / unins000）应带灰色 `工具` 标签且仍可见。
4. 直接把 `.exe` 改名成中文（如 `启动游戏.exe`）再打开选择器 → 应被推荐。
5. 造一个坏 exe（0 字节或纯文本改名）→ 不应被推荐。
6. 「启动管理」弹窗里的角标不应把文件名挤出容器（可先压窄窗口）。
7. 悬停角标应显示判定依据全文。

## 10. 待办

- ⏳ 231 解除后跑 `flutter test test/services/launcher_candidate_analyzer_test.dart`（33 条）。
- ⏳ 真机走查上面 7 项。
- 🟡 两套命名规则并存（导入期 `game_launcher_detector` 仍可能选中"体积最大的补丁器"）。
  若要统一，需单独一轮并覆盖自动导入/批量导入回归，**不在本功能范围内**。
- 🟡 `ExeScanner.excludeKeywords` 里有 `install` / `setup`，被它过滤掉的 exe **不会出现在
  列表里**，因此这部分"无关程序"用户看不到（属于选择器上游行为，本次未改）。
