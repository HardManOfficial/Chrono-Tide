# 单文件导入「智能解压」实施方案（join_archive_smart_unpack）

> 阶段 A 产物（只读审计已完成，本文档为《变更计划》）。经开发者确认三项决策后编写：
> ① .enc 分两期走；② 交互形态 = 解压计划确认弹窗；③ 密码 = 内置密码表 + 手动兜底 + 本地记忆库。
> **状态：v3（2026-10-04 12:26 开发者批准，追加决策：解压位置默认 = 源文件所在文件夹 + 完成后确认删除源包，§4.7b）。**
> **执行进度（2026-10-04）：Phase 0 ✅（`761494b`）/ Phase 1 ✅（`761494b`）/ Phase 2 ✅（`6415784`）/ Phase 3 ✅（`85903d2`）/ Phase 3.5 补完 ✅：`waiting_for_input` 补输弹窗（队列全败 → 暂停 → 补输 → 清垃圾重试 → 成功写记忆库）+ 最终文件夹名确认（§4.7，与 §4.7b 删源包合并为「解压完成确认弹窗」，改名走非法字符清洗 + `_N` 避让 + 内存库 directoryPath 同步）。**
> **第四轮（真机反馈重构）：① 解压计划窗重构为两板块——「解压设定」（预设管理 + 分层密码加一层式自定义（每层密码 + 格式选择，支持 LZ4+ZIP/RAR/7Z 双嵌套复合层）+ 分层后缀映射（同一后缀不同层可映射不同格式））+「解压策略」（实际执行流程预览 + 解压位置）；② 预设与习惯记忆：手动预设 + 解压成功自动记录的习惯（同结构去重、LRU 10 条，打开计划窗按首层格式匹配预填），存 `unpack_settings.json` presets 键；③ 🔴 解压-入库解耦：解压完成后表单**接管**解压产物（置入板块切到游戏本体文件夹），extract_manager 计划路径**不再自动注册**（registerExtractionComplete 是不存在即创建的 upsert）且**不落 game.json**（元数据延后到确认入库时写入），用户点「确认入库」才注册+写元数据（_finalizeAdoptedExtraction），修复「解压完自动入库/表单停留在源 .mp4」。④ Phase 4 .enc 程序化解密 ✅（`join_enc_decryptor.md`：SSE v4 容器 Dart 原生解密——Skein-1024 自移植 + pointycastle(Argon2id/HKDF/SHA3/AES)，计划层 'enc' 解密产物 zip 续链，探针 8/8 全绿）。**
> ⏳ 待办：真机走查（全链：伪装包→两板块计划窗→预设保存→解压→完成确认→表单接管→完善资料→确认入库；真实 .enc 样本权威验证）。原生 analyze 阵发 231 不可用，进程内探针 0 error；IMP-11 存量失败与本次无关（前轮已判定）。

---

## 0. 结论摘要（TL;DR）

| 项 | 结论 |
|----|------|
| 目标 | 用户拖入任意「社区魔改」压缩包（多层嵌套 / 改后缀伪装 / 加密）→ 弹窗展示解压计划（层级树 + 逐层密码）→ 一键全自动逐层解压 → 直接进入现有入库流程 |
| 一期范围 | 系统级拖拽修复、魔数识别+改后缀自动修复、解压计划确认弹窗、密码表+记忆库、任意深度递归解压、lz4 断链修复 |
| 二期范围（独立 Phase 0 先行） | .enc（Paranoia Works）程序化解密 |
| 核心新增 | `ArchiveInspector`（魔数嗅探 + 7z l 探测）、`UnpackPlan` 模型、`ArchivePlanDialog`、`UnpackPasswordStore` |
| 核心改造 | `join_controller.dart` 分流、`extract_manager.dart` 接收显式计划 + 产物重扫递归 + 删包时机后移 |
| 最大风险 | .enc 的 KDF 链移植（二期）；一期主要是加密文件名探测行为与磁盘空间 |

---

## 1. 背景与目标

### 1.1 用户场景（社区调研实证）

galgame 社区资源分享者的典型保护链（鲲 Galgame 论坛、galgame.dev 等多站实测帖）：

```
游戏文件夹
  → 第1层加密：Paranoia Works 工具加密为 .enc（密码 A，如「拒绝倒勾,有能力请支持正版」）
  → 第2层伪装：.enc 改后缀为 .mp4 / .mov
  （用户下载后：.mp4 → 改名 .enc → enc 工具输密码 A → 得 .zip.lz4）
  → 第3层压缩：.zip.lz4 双格式嵌套（无密码）
  → 第4层压缩：.zip 加密（密码 B，如 0721 / galgamex.com）
```

不熟悉的新用户需要：改后缀名、装 enc 工具、装 Bandizip/7-Zip、识别每层格式、分别输对密码——任何一步错都失败。本功能把整条链压缩成「拖进来 → 看一眼 → 填密码 → 完成」。

### 1.2 目标

1. 拖入/选择压缩包后，自动识别真实格式（含改后缀伪装），生成**解压计划**；
2. 弹窗可视化层级树，逐层可输密码（含记忆库自动填充）；
3. 确认后全自动逐层解压；解压产物中若仍有压缩包，**递归**继续解压；
4. 解压完成无缝衔接现有入库流程（元数据表单），全程无需用户理解压缩格式。

### 1.3 非目标（一期明确不做）

- ❌ .enc 程序化解密（二期，见 §7 Phase 4；一期检测到 .enc 时弹窗明确提示「暂不支持自动解密」）；
- ❌ 批量导入 / 智能导入支持压缩包（另行立项）；
- ❌ extract_manager 格式表插件化重构（过度设计）；
- ❌ 云端 / 分享侧联动（本地纯功能）。

---

## 2. 现状调研（全部实测，路径:行号）

### 2.1 现有链路

| 环节 | 现状 | 位置 |
|------|------|------|
| 单文件导入分流 | `isArchiveType` 三元分叉 → `startExtractFlow` / `startCopyFlow` | `lib/pages/join/join_controller.dart:807-812`、`:820-847` |
| 压缩包白名单 | 17 种扩展名 `_archiveExts`，纯后缀判定 | `join_controller.dart:87-105`、`:457-476` |
| 解压执行 | 内置 7z.exe 23.01 子进程；多层格式逐层解压到 `<target>._temp_layer_N` | `lib/services/extract_manager.dart:300-349`、工具路径 `lib/core/path_helper.dart:61-63` |
| 双格式嵌套 | `.rar.lz4/.zip.lz4/.zip.7z` 等 13 种文件名链；`.rar.lz4` 专用通道（bz.exe + UnRAR.exe） | `extract_manager.dart:699-736`、`:282-298`、`lib/services/rar_lz4_unzip_service.dart:120-177` |
| 密码 | 仅硬编码默认密码 `Bilibili_Slpeey`（`_defaultPassword`）失败重试一次，靠错误文本启发式；**无用户密码通路** | `extract_manager.dart:42`、`:977-993`、`:1008-1028`；`rar_lz4_unzip_service.dart:27` |
| 解压成功后 | **立即删除原压缩包**，回传目标目录 → `handleExtractSuccess` 写元数据入库 | `extract_manager.dart:393-396`；`join_controller.dart:874-966` |
| 进度 UI | `JoinProgressDialog`（Overlay 三态） | `lib/pages/join/widgets/progress_dialog.dart:7` |

### 2.2 缺口清单（本方案要补的洞）

| # | 缺口 | 证据 | P |
|---|------|------|---|
| G1 | **用户密码通路为零**：无参数、无 UI，用户密码的包必然失败 | `extract_manager.dart:197-208`（start 无 password 形参）、`:331-338`（调用点恒传 null） | P0 |
| G2 | **改后缀伪装直接被拒**：纯扩展名判定，`.zip`→`.mp4` 拖入走 copy 分支抛「不支持的文件类型」 | `join_controller.dart:468-476`、`:999-1001` | P0 |
| G3 | **解压产物无递归检查**：内容里的嵌套包当普通文件留在游戏目录 | `extract_manager.dart:356-389`（最终校验只数文件/找 exe） | P0 |
| G4 | **3 层以上文件名链拆不全**（`_detectFormatsFromName` 单层只返回 1 格式）；产物后缀偏离链条即报「无法识别」 | `extract_manager.dart:759-766`、`:247-252` | P0 |
| G5 | 🔴 **存量 bug：独立 .lz4 必炸**——`_extractLz4` 要释放 `assets/tools/lz4.exe`，但 assets 里根本没有此文件（只有 5 个 Bandizip 系文件）；目前只有 `.rar.lz4` 走 bz.exe 能活 | `extract_manager.dart:1416` vs `pubspec.yaml:53-57` + assets/tools 实况 | P0 |
| G6 | **单文件拖放区收不到系统级拖拽**：用 Flutter 原生 `DragTarget`（仅应用内 Draggable），`desktop_drop` 只装在批量模式 → 从资源管理器拖压缩包到单文件区无反应 | `lib/pages/join/widgets/file_drop_zone.dart:26-31`；`batch_import_section.dart:6,:434` | P0 |
| G7 | 解压前无完整性预检（`7z t` 能力已在 `archive_compressor.dart:310-323` 现成，未消费） | — | P1 |
| G8 | 解压成功即删原包，中途失败无回退余地 | `extract_manager.dart:393-396` | P1 |
| G9 | `.enc` 零支持（格式表无此格式，无魔数探测） | 全 lib 无 .enc 命中 | P2（二期） |

### 2.3 已有但未被消费的资产（直接复用，不引新依赖）

| 资产 | 位置 | 用途 |
|------|------|------|
| `7z l`（列内容） | 7z.exe 已内置，全仓未使用 | **ArchiveInspector 探测嵌套内容的核心** |
| `7z t`（完整性测试） | `lib/services/archive_compressor.dart:310-323` | 解压前预检（G7） |
| 魔数校验范式 | `lib/theme/background_media.dart:92`（「魔数与扩展名交叉核对：防改名伪装」）、`lib/big_picture/services/bpm_backdrop_media.dart:325` | 压缩包魔数嗅探的实现参照 |
| bz.exe（Bandizip CLI） | assets 按需释放（`rar_lz4_unzip_service.dart:30-63`） | 支持 lz4 格式 → **替代缺失的 lz4.exe 修 G5** |
| 魔数表素材 | zip `PK\x03\x04`、7z `37 7A BC AF 27 1C`、RAR `52 61 72 21`、ISO `CD 001`、LZ4 frame `\x04\x22\x4D\x18` | 自建嗅探表 |
| `showAppDialog` 弹窗范式 | `lib/widgets/app_dialog.dart:27-67`（Material(transparent) 惯例） | 计划弹窗容器 |
| 步进 Pill 向导范式 | `lib/widgets/game_detail/publish_game_dialog.dart:245-254` | 层级树 UI 参照 |
| `desktop_drop` 依赖 | 批量模式已用 | G6 修复直接复用，不新增依赖 |

---

## 3. 技术选型（含被淘汰项）

### 3.1 格式/伪装识别

| 候选 | 结论 | 理由 |
|------|------|------|
| **自建魔数嗅探表（选定）** | ✅ | 零依赖；只覆盖压缩格式头部（≤10 种），实现量小；项目内已有同款范式可抄 |
| 5MB 全文件试解（用 7z 对无后缀文件盲解） | ❌ | 7z 会拷贝/临时落盘，大文件（GB 级 galgame 包）成本高；且 7z 对非压缩文件报错慢 |
| 引入 Dart archive 包做头部解析 | ❌ | archive 包头部判断能力与手写魔数表等价，引入依赖违反最小变更 |
| libmagic / file 命令移植 | ❌ | 体积与维护成本完全不成比例 |

### 3.2 嵌套探测

| 候选 | 结论 | 理由 |
|------|------|------|
| **`7z l -p<密码> -slt` 列内容（选定）** | ✅ | 已内置 7z.exe；`-slt` 输出结构化字段（含每文件属性）；对加密文件名包传 `-p` 探测 |
| 解压一小层再扫描 | ❌ | 会真的落盘 GB 级数据，探测不应有副作用 |
| Dart archive 包读中央目录 | ❌ | 只支持 zip；rar/7z 无法覆盖；双实现维护 |

### 3.3 .enc（二期预研结论，本期只做识别）

.enc 实为 **Paranoia Works File & Text Encryption（PFTE/SSE File Encryptor）** 的加密容器（社区「enc 解压工具」即此），**MIT 开源 + 官方格式规范**：

- 格式 v4：Zip64 内容 → CTR 模式加密；头部明文含版本字段（=4）+ 算法代码（0=AES-256 / 1=RC6 / 2=Serpent / 3=Blowfish-256 / 4=Twofish / 5=GOST / 6=Blowfish-448…）；随机数据块（快速密码验证）；BLAKE3 MAC（Encrypt-then-MAC）；
- KDF 链（复杂点）：Skein-1024 HKDF → Argon2id（t=10, m=10240kB）→ SHA3-512 HKDF ×3；密码 ASCII 32-126 特殊转换规则；
- 官方规范：https://paranoiaworks.mobi/sse/file_encryption_specifications.html

淘汰项：
- ❌ 内置 PFTE CLI（需 Java 运行时，安装包体积 +100MB 级，直接违反瘦身线）；
- ❌ 调用 Web 版 pteo.paranoiaworks.mobi（GB 级文件、离线场景、依赖外部服务，均不可行）；
- ✅ 二期路线：**Dart 原生移植**（pointycastle 有 AES/RC6/Serpent/Blowfish/Twofish/GOST/SHA3/Argon2；Skein-1024 与 BLAKE3 需移植或找包），先 Phase 0 用自造样本往返验证，再落地。旧版格式（v1–v3，无 Argon2id）兼容性在 Phase 0 一并确认。

### 3.4 独立 .lz4 解压（修 G5）

| 候选 | 结论 | 理由 |
|------|------|------|
| **bz.exe 解 lz4（选定）** | ✅ | Bandizip CLI 原生支持 lz4；工具已在 assets 释放体系内；顺带删除 `_extractLz4` 的 lz4.exe 断链分支 |
| 补发 lz4.exe 进 assets | ❌ | 多维护一个二进制；lz4 原版 CLI 的 frame/skippable 变体覆盖不如 Bandizip 全 |

---

## 4. 架构设计

### 4.1 数据流总览

```
拖入/选择文件 (file_drop_zone + desktop_drop 系统级拖拽 ← 修 G6)
      │
      ▼
JoinController.handleFileSelected
      │  ArchiveInspector.sniff(path)：魔数嗅探（真实格式）+ 扩展名交叉比对
      ▼
  伪装包？ ──是──► 修复建议入 plan（.mp4 → 实为 .zip）
      │（压缩包/伪装包均继续；普通 exe/文件夹走原 copy 流程不变）
      ▼
ArchiveInspector.buildPlan(path, maxDepth)
      │  逐层：7z l -slt 列内容 → 产物嗅探 → 下一层……产出 UnpackPlan（层级树）
      ▼
ArchivePlanDialog（showAppDialog 范式）
      │  展示层级树（每层：格式徽章 / 大小 / 密码框 / 伪装修复提示）
      │  + 后缀映射策略区（§4.6）+ 密码策略区（§4.4）
      │  UnpackPasswordStore 按来源记忆自动填充 → 用户确认
      ▼
ExtractManager.start(unpackPlan)  ← 改造：接收显式计划
      │  逐层解压（沿用 _temp_layer_N 机制 + 每层密码候选队列 §4.4）
      │  每层完成后 ArchiveInspector.rescan 产物 ──发现压缩包──► 并入计划继续（递归，受 maxDepth/maxExtractBytes 护栏）
      │  计划外新层：有预设策略（后缀映射/密码）→ 自动应用；无 → 状态机转 waiting_for_input → 暂停弹窗补选（§4.5）
      ▼
全部层完成 → 7z t 语义的成功校验（现有 exe/非空判定保留）
      │
      ▼
删除原包时机后移：整个计划全部成功 + 游戏校验通过后才删（修 G8；失败保留原包供重试）
      │
      ▼
最终文件夹名确认：弹窗展示「游戏 exe 上一级目录名」供用户编辑（§4.7），确认后入库
      │
      ▼
handleExtractSuccess（现有入库链路零改动）
```

### 4.2 新增组件

| 组件 | 文件 | 职责 |
|------|------|------|
| `ArchiveInspector` | `lib/services/archive_inspector.dart`（纯新增） | ① `sniff(path)`：读前 16 字节魔数 + 扩展名交叉比对，返回真实格式枚举；② `buildPlan()`：`7z l -slt -p<候选密码>` 逐层探测内容（只读，零落盘），输出 `UnpackPlan`；③ `rescan()`：供解压后重扫产物 |
| `UnpackPlan` 模型 | `lib/services/unpack_plan.dart`（纯新增） | `UnpackPlan{source, layers: List<ArchiveLayer>, suffixMappings: List<SuffixMapping>, passwordSequence: List<String>, warnings}`；`ArchiveLayer{realFormat, declaredExt, needsPassword?, password?, sizeBytes}`；`SuffixMapping{fromExt, toFormat, isDefault}`（后缀映射策略，**逻辑映射不改盘上文件名**，见 §4.6） |
| `UnpackPasswordStore` | `lib/services/unpack_password_store.dart`（纯新增） | 密码记忆库：`data/unpack_passwords.json`（键 = 源文件名规范化 + 层格式；值 = 密码 + 最后使用时间；上限 100 条 LRU）。独立文件，**不进 game.json、不升 format_version** |
| `ArchivePlanDialog` | `lib/pages/join/widgets/archive_plan_dialog.dart`（纯新增） | 解压计划确认弹窗（**三区块**，对齐 §4.5）：① 层级树（步进 Pill 范式，含伪装修复提示）；② 后缀映射策略区（预设表编辑 + 默认项）；③ 密码策略区（按层预设 + 记忆库自动填充）+「开始处理」；执行中复用为 `waiting_for_input` 暂停弹窗；走 `showAppDialog` + `Material(transparent)` 惯例 |

### 4.3 改造点

| 文件 | 改法 |
|------|------|
| `lib/pages/join/join_controller.dart` | ① `handleFileSelected:399-455`：先 `ArchiveInspector.sniff`，魔数判为压缩包（含伪装）→ 类型归为 archive 并记录 `renamedFrom`；② `submitAddGame:807-812`：压缩包分支改为「先 `buildPlan` → 弹 `ArchivePlanDialog` → 用户确认后带 plan 调 `startExtractFlow`」；③ 新增 `waiting_for_input` 暂停态回调接线（暂停弹窗 → 用户补密码/补策略 → 恢复解压）；④ 解压成功后「最终文件夹名确认」步骤（§4.7），编辑后走护栏重命名 |
| `lib/services/extract_manager.dart` | ① `start()` 增加可选 `UnpackPlan? plan` 形参（默认 null = 走现有文件名链逻辑，**老路径行为不变**）；② 有 plan 时每层按 §4.4 密码候选队列尝试（内置密码表启发式重试降级为队列一环）；③ 每层解压完 `ArchiveInspector.rescan`：产物含压缩包 → 追加层继续（上限 `maxDepth=6`、`maxExtractBytes` 总解压预算，默认 60GB 可配置）；计划外新层无预设 → 转入 `waiting_for_input` 暂停（状态机 §4.5）；④ 删原包 `:393-396` 后移到全部层成功 + 校验通过后；⑤ `_extractLz4:1410-1531` 改走 bz.exe（删 lz4.exe 断链分支，修 G5） |
| `lib/pages/join/widgets/file_drop_zone.dart` | 叠加 `desktop_drop` 的 `DropTarget`（与批量模式 `batch_import_section.dart:434` 同款），系统级拖入 → `handleFileSelected`（修 G6） |
| `lib/services/rar_lz4_unzip_service.dart` | `:27` 内层 RAR 密码 const 参数化（默认值不变，可被 plan 覆盖）——属密码策略一部分 |

### 4.4 密码策略（决策 ③ + 用户构思 ②：按层预设 + 轮换回退）

解压每层时按**统一密码候选队列**逐个尝试（首个成功即用，全败 → 暂停弹窗）：

1. **用户按层预设的密码序列**（`passwordSequence`）：计划弹窗里按层序号填写——第 1 层密码、第 2 层密码……对应「不同层不同密码」的常见分享；
2. **本层记忆库候选**：`UnpackPasswordStore` 按源文件名 + 格式召回的历史成功密码；
3. **内置密码表**（常量，按命中顺序）：现有 `Bilibili_Slpeey` + 社区高频默认密码（`0721`、`galgamex.com` 等，Phase 0 实测后定稿，注释注明出处类别）；
4. **轮换回退**：候选队列对**所有已填层序密码做全队列轮换**（不限本层预设）——覆盖用户描述的「同一密码用两次」「1,2,1,2 交替」「层数与密码数对不上」等乱序情形；
5. **手动兜底**：队列全败 → 状态机转 `waiting_for_password` → 弹窗暂停该层（复用 ArchivePlanDialog 密码输入形态）→ 用户输入后继续，成功写入记忆库；
6. 密码不落明文日志（沿用 `extract_manager.dart:1076-1079` 约定）。

⚠️ 技术边界：7z 对错误密码的「失败判定」因格式而异——RAR/7z 有头部校验会明确报错；**zip 传统加密（ZipCrypto）无密码校验位，错密码可能解出垃圾数据最后报 CRC 错**（见 §10 风险 R-P1b），轮换重试的失败判定须综合 exitCode + CRC 错误文本，Phase 0 实测定稿。

### 4.5 交互流程（用户构思对齐）与状态机

解压计划窗口 = 一个弹窗、三个设置区块（非多个弹窗）；解压执行阶段支持**动态补充计划**：

- **状态机**：`planning → awaiting_confirm → extracting ⇄ waiting_for_input → renaming → done / failed`
  （`waiting_for_input` 覆盖两种暂停：某层密码队列全败 `waiting_for_password`、计划外新层且无预设策略 `waiting_for_strategy`；恢复后继续原计划）
- **拖入时**：探测能摸清的层 → 弹计划窗口一次性配置（层级树 + 后缀映射策略 + 密码预设）；**摸不穿的加密层在树中显示为「加密压缩包（内容待解压后确认）」**；
- **解压中**：每层解压完重扫产物——发现计划外新层时：后缀映射表能判 → 自动应用；映射表也判不了 → `waiting_for_strategy` 暂停弹窗让用户选格式（对齐用户构思「继续弹出一个窗口让用户进行策略上的选择」）；
- 全部自动可用时全程无感知，只在必须人工决策时打断。

### 4.6 后缀映射策略（用户构思 ①，逻辑映射实现）

**设计理由（前后对比）**：手动时代改后缀是因为 7-Zip 等工具**靠后缀猜格式**；我们的 `ArchiveInspector` 直接读文件头，**解压不依赖文件名**。故「改后缀」降级为「逻辑映射」：plan 中每层记录 `declaredExt → toFormat`，展示与判定全部走映射结果，**不真实重命名盘上文件**。收益：少一步磁盘 IO、零改名失败残留、伪装层在弹窗中仍显示原名（`.mp4 → 按 .zip 处理`）可追溯。若开发者坚持真实改名可后续加开关，默认不做。

- **预设映射表**（持久化，用户可编辑）：`{fromExt: '.mp4', toFormat: zip}` 一条映射一种目标格式，允许多条同源不同目标（`.mp4→zip` 与 `.mp4→rar` 并存，命中时由用户当场二选一或设默认）；
- **默认策略**：每条映射可标记 `isDefault`（如 `.mov` 默认 → `.zip`、`.mp4` 默认 → `.enc`（二期 enc 落地前暂判为未知伪装包））；
- **命中顺序**：魔数识别（主）→ 映射表（兜底 1）→ `waiting_for_strategy` 弹窗（兜底 2）；
- 映射表持久化进 `data/unpack_settings.json`（与密码记忆库分文件，同不进 game.json）。

### 4.7 最终文件夹名确认（用户构思 ③）

- 全部层解压成功后，定位游戏启动 exe（现有 `GameLauncherDetector.detect`）→ 取其上一级目录名；
- `renaming` 状态：在入库确认弹窗中展示该目录名供编辑；用户修改后**真实重命名**该目录（走 `PathHelper.isInsideAppStorage` 护栏校验 + 重名 `_1/_2` 递增避让，复用 `extract_manager.dart:842-859` 命名规则）；
- 不修改则按原名直接进入现有 `handleExtractSuccess` 入库（与现状零差异）。

### 4.7b 解压位置（开发者 2026-10-04 批准时补充决策）

- **默认解压位置 = 用户导入的源文件所在文件夹**（成品与源压缩包同目录），计划弹窗「解压位置」区块展示实际目标路径，可一键切回现有默认（`InstallPathPreference` 安装偏好，行为同现状）；
- 选源文件夹时目标目录命名沿用现有 `<标题>` / `<标题>_N` 规则（`extract_manager.dart:842-859`），入库注册无特殊处理（游戏目录本就支持任意位置）；
- ⚠️ 若源文件夹在网盘同步目录，弹窗提示「该位置可能被网盘同步」但不阻止；
- **删除源压缩包改为显式确认**：全部层成功后，在完成态弹窗中提供「删除源压缩包 / 保留」按钮，用户确认才删（默认保留）；计划弹窗不再预置删除勾选。删除动作走现有护栏（应用自有目录判定 + 失败保留）。

### 4.8 护栏

- **zip 炸弹 / 磁盘**：`maxExtractBytes` 总预算（默认 60GB）+ 每层 `7z l` 申报体积预检（超预算直接在计划弹窗报错，不开始解压）；
- **递归深度**：`maxDepth = 6`（社区实测最深 4 层：enc→lz4→zip→文件夹层）；
- **删除护栏**：删原包/临时层沿用现有 `PathHelper.isInsideAppStorage` 侧护栏（`interrupt_cleanup.dart:311-317`）与 `_cleanupOnFailure`（`extract_manager.dart:1760-1973`）不变；失败时**保留原包**；
- **伪装误判**：魔数表只认压缩格式头部；`.exe`/媒体文件即使内部含 zip 记录也不误判（嗅探按「前 16 字节」判定，非全文扫描）；
- ADR-007 不涉及（本功能不新增删除逻辑面，删的仍是应用自有目录内产物 + 用户主动拖入的源包，删源包时机后移且失败保留）。

---

## 5. 数据模型变更

- `game.json`：**零变更**（不升 format_version，不动 `_overwritableFields`）；
- 新增独立文件 `data/unpack_passwords.json`（密码记忆库，读写走新 `UnpackPasswordStore`，JSON 结构 `{version:1, entries:[{key,password,lastUsedAt}]}`；含 `version` 字段为将来演进留位）；
- 新增独立文件 `data/unpack_settings.json`（后缀映射预设表：`{version:1, mappings:[{fromExt,toFormat,isDefault}]}`，见 §4.6）；
- `pubspec.yaml`：**零变更**（desktop_drop 已有）。

---

## 6. 性能预算

| 项 | 预算 | 手段 |
|----|------|------|
| 魔数嗅探 | <10ms | 读前 16 字节 |
| 计划探测（每层 `7z l`） | <2s/层（GB 级包） | `7z l` 只读中央目录不碰数据体；`-slt` 流式解析（参照 `_parse7zLine` 模式，`seven_zip_progress.dart`） |
| 弹窗出现时机 | 拖入后 <3s | 探测放 `Future`，弹窗先出骨架态再填层级树 |
| 递归重扫 | 每层完成一次，<2s | 仅对「解压出的顶层条目」逐个 sniff，命中压缩格式才 `7z l` |
| UI 不阻塞 | 硬要求 | 全部 7z 调用走 `Process.start` 流式（沿用 `extract_manager.dart:1153-1158` 约定），禁同步等待 |

---

## 7. 实施阶段划分

| Phase | 内容 | 产出 / 证伪目标 |
|-------|------|----------------|
| **Phase 0（技术验证，✅ 2026-10-04 完成，探针 `dev_probe/probe_unpack_phase0.py`，结果 `dev_probe/probe_unpack_phase0_out.txt`，样本自造 8 种 + 15 测试）** | ① bz.exe 对独立 `.lz4`/`.zip.lz4` **rc=0 全通过**（G5 修复方案成立）；② `7z l` 对加密文件名 7z：无密码报 `Cannot open encrypted archive. Wrong password?`（rc=2）→ **证实动态计划必要**；对 ZipCrypto/AES zip：无密码也能列文件名 → 计划弹窗可预览加密 zip 内容；③ 错密码：7z 23.01 对 ZipCrypto 也明确报 `Wrong password`（**无 CRC 假解密**，R-P1b 风险降级），但错密码解压会把垃圾文件落盘 → 失败清理必须走 `_cleanupOnFailure`；④ 魔数表 8 样本全命中（加密不影响魔数）；⑤ 意外收获：7z 对伪装 `.mp4` 完全免疫（正常识别为 zip）；7z 23.01 不支持 lz4（证实必须 bz.exe）；bz 解 `.zip.lz4` 产物名 = 输入名去 `.lz4`（中间文件名可预测） |
| **Phase 1（识别与修复）** | `ArchiveInspector.sniff` + join_controller 分流改造 + file_drop_zone 系统级拖拽（G6）+ extract_manager 删 lz4.exe 断链分支 | 伪装 .mp4 包拖入被正确识别为压缩包 |
| **Phase 2（计划与弹窗）** | `UnpackPlan` + `buildPlan` + `ArchivePlanDialog`（三区块）+ `UnpackPasswordStore` + 后缀映射持久化 | 拖入嵌套包弹层级树、可编辑映射与逐层密码 |
| **Phase 3（执行与递归）** | extract_manager 接收 plan + 密码候选队列 + 产物重扫递归 + `waiting_for_input` 状态机与暂停弹窗 + 删包时机后移 + 最终文件夹名确认 | E2E：enc 伪装链（除 enc 解密外）→ lz4 → 加密 zip 全自动走通；密码错→暂停补输→续解走通 |
| **Phase 4（二期，单独立项）** | .enc 程序化解密：Phase 0b 先自造样本验证 KDF 移植（Skein-1024/BLAKE3 缺件确认）→ `enc_decryptor.dart` → 并入 plan 的第 0 层 | 社区真实 .enc 样本解密成功率 ≥ 主流 v4 格式 |

每 Phase 一个 commit；Phase 0 不改业务代码（探针脚本进 `dev_probe/`）。

---

## 8. 改动文件清单

**新增**：
- `lib/services/archive_inspector.dart`
- `lib/services/unpack_plan.dart`
- `lib/services/unpack_password_store.dart`
- `lib/pages/join/widgets/archive_plan_dialog.dart`
- `dev_probe/probe_bz_lz4.py` 等 Phase 0 探针（不入包）

**修改**：
- `lib/pages/join/join_controller.dart`（分流 + 弹窗接线）
- `lib/services/extract_manager.dart`（plan 形参 / 密码注入 / 递归重扫 / 删包后移 / lz4 分支）
- `lib/pages/join/widgets/file_drop_zone.dart`（desktop_drop）
- `lib/services/rar_lz4_unzip_service.dart`（密码参数化）

**一期明确不碰**：`batch_import_controller.dart`、`auto_import_pipeline.dart`、`main.dart`/`main_container.dart`/`lib/theme/`/`app_state.dart`（稳定区全部不在改动面）、`game_data_format.dart`、`interrupt_cleanup.dart`（现有护栏已够用）、`pubspec.yaml`。

---

## 9. 调用点替换清单

| 调用点 | 分期 | 说明 |
|--------|------|------|
| `join_controller.dart:807-812`（submitAddGame 分叉） | P0 | 压缩包分支接入计划弹窗 |
| `join_controller.dart:399-455`（handleFileSelected 分类） | P0 | 魔数嗅探前置 |
| `join_controller.dart:820-847`（startExtractFlow） | P0 | 透传 plan |
| `file_drop_zone.dart:26-31`（DragTarget） | P0 | 叠加 desktop_drop |
| `extract_manager.dart:331-338`（_extractSingleFormat 调用） | P0 | 密码从 plan 注入 |
| `extract_manager.dart:393-396`（删原包） | P0 | 时机后移 |
| `extract_manager.dart:1410-1531`（_extractLz4） | P0 | 改 bz.exe |
| 安装中心下载落地的解压路径（`global_install_center` → extract_manager） | 一期不改 | plan=null 走老逻辑，行为不变；二期再评估是否接入 |
| 批量导入压缩包 | 明确不做 | 见 §1.3 |

---

## 10. 风险登记

| 级别 | 风险 | 应对 |
|------|------|------|
| P0 | `7z l` 对「加密文件名」的 zip/7z 拿不到内容清单，计划树断链 | Phase 0 实测；降级 = 该层只展示「加密压缩包（内容未知）」，密码由用户填，解压后靠递归重扫续链 |
| P0 | D 盘空间（当前余 ~34.5GB）被多层解压叠加吃满 | `7z l` 申报体积预检 + `maxExtractBytes` 预算；磁盘 <10G 禁写盘为项目既有铁律，弹窗内显式报「磁盘空间不足」 |
| P1 | 魔数误判（自解压 exe、含 zip 头的其他格式） | 嗅探表只认压缩格式前 16 字节；exe 一律走原 copy 流程；Phase 0 用真实样本验证 |
| P1 | 密码记忆库明文落盘 | 本地单机场景风险可接受；文件权限跟随应用目录；**不做** DPAPI 加密（复杂度不成比例），文档明示 |
| P1→P2（降级） | ~~ZipCrypto 假解密~~：**Phase 0 实测证伪**——7z 23.01 对 ZipCrypto 错密码同样明确报 `Wrong password`（T6/T8），无垃圾静默成功；保留的残余风险仅是「垃圾文件落盘」，由现有 `_cleanupOnFailure` 覆盖 | 失败判定统一 rc≠0 + `wrong password` 文本匹配 |
| P1 | 删包时机后移 → 解压成功但用户中途关窗，原包与游戏目录并存占用双份空间 | 关窗/取消确认弹窗提示；下次启动 `interrupt_cleanup` 已有不完整目录清理（无 .ctgame 的目录），原包不动 |
| P2 | 递归把游戏内部资源包（如 .pfs/.arc 自定义格式）误当压缩包 | 嗅探表白名单只含标准压缩格式；`7z l` 能列但不在我表的格式不解 |
| P2 | 递归重扫产物巨大（数千文件）拖慢 | 只 sniff 顶层条目；命中才深查；sniff 为 O(1) 读 |
| 二期 | .enc KDF 移植失败（Skein-1024 无现成 Dart 实现） | Phase 4 自带 Phase 0b 证伪点；失败则维持「识别 + 引导外部工具」 |

---

## 11. 验收标准

**功能（真机走查，开发者执行）**：
1. 从资源管理器拖 `.zip.lz4`（外层无密码/内层密码 0721）→ 弹窗显示两层树 → 填一个密码 → 全自动解压 → 进入入库表单 ✅
2. 把 `.zip` 改名 `.mp4` 拖入 → 被识别为压缩包，弹窗显示「后缀伪装已修复：mp4 → zip」✅
3. 三层嵌套（文件夹套 zip 套加密 rar）→ 递归全部解开 ✅
4. 密码全错 → 弹窗暂停要密码 → 输入正确密码继续 → 下次同源包自动填充 ✅
5. 按层预设两套密码（1 层 A / 2 层 B）+ 故意把 A 填错 → 队列轮换到 B 续解成功 ✅
6. `.mp4` 伪装包 + 预设映射 `.mp4→zip` → 弹窗显示逻辑映射，不解包直接自动处理 ✅；删掉映射再拖入 → 弹窗让用户选目标格式 ✅
7. 解压完成后弹「最终文件夹名确认」，改名后游戏目录以新名入库 ✅
8. 普通 exe / 文件夹拖入 → 行为与现在完全一致（回归）✅
9. 安装中心下载→解压老路径回归无变化 ✅

**技术**：
- `./flutter/bin/flutter.bat analyze` 改动文件 **0 新增 error**（存量 ~543 info 不计入）；
- 相关 `flutter test`（join / extract 相关目录）在开发者终端补跑，不新增失败；本会话未跑（见 §13）；
- `git status --short` 自查改动面 = §8 清单，无越界文件。

---

## 12. 给执行 AI 的指令摘要

> 在 D:\CTLIB 按 `docs/DEV/features/join_archive_smart_unpack_plan.md` 实施单文件导入智能解压。先读 AGENTS.md 与该方案全文。从 Phase 0 探针开始（只写 dev_probe/，不改业务代码），把 ① bz.exe 对独立 .lz4 的支持、② 7z l -slt 对加密包的行为、③ 魔数表样本 三个假设实测后，按 Phase 1→3 顺序落地，每 Phase 一个 commit。严守：不改批量/智能导入；plan=null 老路径行为不变；game.json 零变更；密码不落日志；改动文件以方案 §8 清单为准，超出范围立即停下报告。

---

## 13. 待确认与未验证项（诚实标注）

- **本文档为研究产物：未写任何业务代码、未跑 analyze/test**；§2 现状结论来自只读审计（三路并行探查，路径行号已核对），但 **7z l / bz.exe 行为均属假设，Phase 0 就是用来证伪它们的**；
- 内置密码表的具体清单需 Phase 0 后定稿（涉及社区高频密码的收集口径，默认只收「公开教程中广泛出现的通用默认密码」，不收录任何需特定资源帖才能获得的密码）；
- 弹窗视觉稿（紧凑布局、层级树样式）按项目惯例在实现后以真机截图迭代，不在本文档定稿。
