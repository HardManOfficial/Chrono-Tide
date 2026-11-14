# 游戏补丁管理（PATCH-VAULT）实施方案 — v2 目标对齐版

**状态**：✅ **用户 2026-11-11 20:40 批准「一次完成 P0–P3 / 转移用移动」并已实施**；
　　　　实施记录见 **§11**；代码、探针、验证均已落地
**日期**：2026-11-11（v1 19:5x → v2 20:19 用户校准 → 20:40 批准 → 21:1x 实施完成）
**接手说明**：本方案取代 2026-11-11 19:5x 的 v1 对话方案。v1 的「顶栏全库浮层为主入口 + 高自动化落点判断」
口径已被用户 20:19 口述推翻，**以本文件为准**。
**工作代号**：PATCH-VAULT（可改名）
**前置档案**：`patch_station_docking_plan.md`（尤其 §7 P4、§11 P4-B 取消原因）、
`patch_finder_implementation_plan.md`、`DECISIONS.md` ADR-007 / 011 / 013 / 019 / 020、
`SESSION_HANDOFF.md` 2026-11-10 补丁站 v3 条目。

> 本文件所有相对路径均相对 `D:\CTLIB\apps\chrono-tide`。

---

## 0. 一页结论

| 项 | 结论 |
| --- | --- |
| 是什么 | 库页内、**按单个游戏**组织的本地补丁文件管理器 + 辅助打补丁 + 回退原版 |
| 不是什么 | ⛔ 不是补丁站（下载器）的延续；⛔ 不是「自动识别并自动安装」的工具 |
| 核心基调 | **不替用户决定**。程序负责「摆清楚信息、给建议、把繁琐操作变简单」，最终选择权永远在用户 |
| 唯一核心入口 | 库页**卡片右键菜单**新增「补丁管理」（`library_context_menu.dart`） |
| 网络 | 不联网。与补丁站**单向松耦合**：只读其保存目录当来源之一，不改补丁站任何代码与语义 |
| 数据 | ⛔ 不写 `game.json`、不动 `format_version=4`、不加 pubspec 依赖；独立索引 `data/patch_vault/index.json` |
| 备份位置 | `<启动程序所在目录>/.CTPatch/`（用户 20:19 拍板，与字体补丁「放游戏那边」的做法一致） |
| 收纳 | 免搬运登记（只索引，不复制不移动不解压）；另提供「转移」功能由用户主动改路径 |
| 应用与回退 | **必须同一期交付**。只上「能打补丁」不上「能回退」＝用户最担心的风险状态 |
| 历史资产 | 复活 2026-11-10 作废的 P4-B 三个文件语义（`patch_install_service` / `patch_library_service` / `patch_preview_sheet`）与 `.ct_backup` 事务模型，**按本项目 `game_font_patch_service.dart` 范式落地** |

---

## 1. 目标对齐（用户 2026-11-11 20:19 口述）

### 1.1 总基调

> 「不需要实现那么的智能，那么的自动化，因为确实这个本身并不是很好管理，还是要主要依赖用户自己决定」
> 「在尽可能减少复杂操作的情况下给玩家带来一个无痛的补丁管理功能」

⇒ 设计取舍：**降低操作成本 ≠ 替用户做判断**。凡是「猜错会破坏游戏」的决策，一律展示信息 + 给默认值 + 要用户确认。

### 1.2 三个目标

| # | 用户目标 | 落地形态 |
| --- | --- | --- |
| 一 | 管理杂乱的本地补丁文件 | 卡片右键「补丁管理」→ 面板主体＝本地补丁文件管理：用户自行导入、程序只读识别类型、可视化列表、可转移路径 |
| 二 | 帮助用户打补丁 | 同一面板辅助可视化打补丁：**不完全自动化**，按常见补丁习惯**推荐位置**；特殊情况交给用户；面板固定提示「打补丁前先去游戏目录看说明」 |
| 三 | 无痛／回退 | 应用前备份原文件并记账，用户不想要时**回退原版**；避免「只能重装游戏」 |

### 1.3 四项拍板结果

| # | 问题 | 用户答复 | 本方案采用 |
| --- | --- | --- | --- |
| 1 | 收纳策略 | **免搬运登记**；另要一个类似详情页「游戏文件转移」的**补丁文件转移**功能，默认路径 `/游戏/补丁/要转移的补丁文件` | ✅ 登记只读；新增转移功能（§3.2.4） |
| 2 | 备份位置 | **直接放游戏目录**，且明确「游戏目录＝用户打开游戏的启动程序所在目录」，与字体补丁一致 | ✅ `<launchDir>/.CTPatch/`（§2 有口径澄清） |
| 3 | 绑定强度 | **绑定 GameID** | ✅ 索引以 `game_id` 为键，应用前校验一致性 |
| 4 | 一期范围 | ✅ **20:40 拍板：一次完成 P0–P3**，不再分期交付 | 应用与回退仍同批落地，无「能打不能回」中间态 |

### 1.4 与 v1 的差异对照（🔴 执行前必看）

| 维度 | v1（19:5x） | **v2（本方案）** |
| --- | --- | --- |
| 核心入口 | 库页顶栏「补丁」→ 全库浮层（主）+ 详情弹窗 + 右键（可选） | **只有卡片右键「补丁管理」**；取消全库浮层与详情弹窗入口 |
| 面板主体 | 补丁库 + 应用/回滚并重 | **以本地补丁文件管理为主体**，辅助打补丁是附加能力 |
| 补丁来源 | 扫描发现为主 | **用户自行导入**（选本地文件／文件夹）为主 |
| 智能化 | 自动落点判断 + 一键应用 | 只**识别类型标签** + **推荐位置**，用户可改、可忽略、必须确认 |
| 说明提示 | 有 | 显式升级为固定提示条 + 「打开游戏目录」按钮（§3.2.5） |
| 转移功能 | 无 | **新增**（§3.2.4） |
| 备份目录 | `<本体根>/.CTPatch/` | **`<启动目录>/.CTPatch/`** |
| 分期 | P0–P4 | P0–P3，且**应用与回退合并同一期** |

---

## 2. 🔴 必须先钉死的口径：两个「游戏目录」

### 2.1 定义（项目里没有现成 helper，本功能需新增）

| 名称 | 取值 | 依据 |
| --- | --- | --- |
| **本体根 `bodyRoot`** | `GamePathResolver.resolve(directoryPath: game.directoryPath, sourcePath: game.sourcePath).accessPath` | `game_path_resolver.dart:113`、`DECISIONS.md` ADR-013；离线时 `accessPath==''` ⇒ 禁止任何写操作 |
| **启动目录 `launchDir`** | `path.dirname(GameDataFormat.resolveLaunchPath(game.launchPath, bodyRoot))` | `game_data_format.dart:1267-1278` 返回的是 **exe 文件绝对路径**，需再取 `dirname`；返回空串时降级 `bodyRoot` 并提示 |

项目里三个 helper 都只给 **exe 文件路径**，不给目录：
`GameFontPatchService.resolveExePath`（`game_font_patch_service.dart:712-717`）、
`GameDataFormat.resolveLaunchPath`（`:1267-1278`）、
`GameLaunchService.resolveUserChoice`（`game_launch_service.dart:132-157`）。
全库搜 `exeDir` 命中的都是 `PathHelper.exeDir`（**应用自身安装目录**），与游戏无关。

⇒ 新增纯 Dart 值对象 `GameDirs { bodyRoot, launchDir, isOffline }`，**集中唯一实现**，UI 不得各自拼接。

🔴 **`game.pathForCover` 不是本体根**（`local_game_registry.dart:382-383` 是 `metaDataDir` 优先）。
`library_page.dart:2083` 打开详情弹窗传的正是它 —— 本功能定位目录**只能**用 `game.directoryPath` + `game.launchPath`。

### 2.2 字体补丁的实际行为与分歧（重要发现）

`game_font_patch_service.dart:7-10` 注释称「把 `winmm.dll` 投放进游戏 exe 同目录」，
但 `install(gameDir, {exePath})` 的 `gameDir` 落盘路径全部基于本体根（`:330-336`、`:472-475`），
调用方传的也都是 **`game.directoryPath`（本体根）**：

- `font_library_panel.dart:203-208`（`probe(r.game.directoryPath, ...)`）、`:251-252`、`:346-347`、`:795-801`
- `font_picker_dialog.dart:152-153`、`:185-187`、`:242`
- `launch_manager_dialog.dart:233-237`

`exePath` 在 `install` 里只用于一行 PE 架构识别（`:444`），`probe` 里甚至完全未使用。
⇒ 当 `launch_path` 带子目录时，字体补丁实际投放位置**不是** exe 同目录，注释与实现不一致。

**本功能处理**：⛔ **不改字体补丁**（最小变更，属稳定行为，动它要单独提需求）；
只在 PATCH-VAULT 内把两个根显式区分并记录此分歧。

### 2.3 本功能采用

- **备份**：`<launchDir>/.CTPatch/`（按用户拍板）
- **转移默认目标**：`<launchDir>/补丁/`（用户口述的 `/游戏/补丁/`；「常见习惯是把补丁转移到对应游戏的文件夹内」）
- **落点推荐**：DLL 注入型／换 exe 型 → `launchDir`；覆盖式（与 `bodyRoot` 子目录同构）→ `bodyRoot`（§3.3）
- 备份在 `launchDir`、补丁落在 `bodyRoot` 时仍能还原，因为 manifest 记的是**绝对路径**；但 UI 要如实显示两者不同，别让用户以为备份贴在补丁旁边

### 2.4 ✅ 已确认（20:40「批准」，按建议值执行）

`launchDir ≠ bodyRoot` 时备份仍按**启动目录**放（用户定义的「游戏目录」）。
UI 在 `_pathRow` 与预览页显式显示两个根的绝对路径，不隐瞒差异；
manifest 记绝对路径，落点在本体根也能准确回退。字体补丁实现未改动。

---

## 3. 功能设计

### 3.1 唯一核心入口：卡片右键「补丁管理」

- `lib/widgets/library_context_menu.dart:7-23` 加 `onPatchVault` 回调
- `:81-112` 的 `Column` 加一枚菜单项（建议置于「启动管理」之后、「加入收藏夹」之前）
- 🔴 `:30` 的 `const menuHeight = 200.0; // 4 项` 必须同步改为 **5 项约 248.0**，否则 `:37-42` 的底部上翻边界检测会算错
- `lib/pages/library_page.dart:2096-2125` `_showContextMenu` 加回调闭包，把当前 `LibraryGame game` 传入面板
- 面板形态：独立**居中对话框** `PatchVaultDialog.show(context, game)`（参考 `save_backup_dialog.dart` / `font_library_panel.dart` 外壳），
  因为要同时容纳文件列表、预览确认、转移进度
- ⛔ **取消** v1 的库页顶栏按钮与全库浮层；⛔ 不改 `GameDetailDialog`；
  ⛔ 编辑模式的 `_showEditModeContextMenu`（`library_page.dart:574`）不加，避免扩大范围

进入时天然带游戏上下文 ⇒ 「打错游戏」在入口层就被结构性削弱，无需靠算法猜补丁归属。

### 3.2 面板主体：本地补丁文件管理（目标一）

#### 3.2.1 导入（免搬运）

- 两个入口：「导入补丁文件」（`FilePicker.pickFiles(allowMultiple: true)`）、「导入补丁文件夹」（`getDirectoryPath()`）
- 接受：zip / 7z / rar / exe / 任意单文件 / 已解压目录
- **导入＝只登记**：⛔ 不复制、不移动、不解压、不写游戏目录
- 记录：原路径、文件名、体积、mtime、流式 sha256（复用 `patch_download_core.dart:96 sha256OfFile`）、容器类型、`gameId`

#### 3.2.2 类型识别（只读 sniff，纯 Dart）

分两路，**识别 ≠ 解压**：

| 输入 | 处理 | 产出 |
| --- | --- | --- |
| zip | `sniffContainer`（`patch_extract_service.dart:121`）→ `listEntries`（`:106`，**不解压**）→ `previewFromRawPaths`（`patch_preview.dart:329`） | 形态 + 说明文件 / EXE / DLL / 数据文件清单 |
| 已解压目录 | 递归只读列文件 → 同一套 `buildPatchPreview` | 同上 |
| 7z / rar / exe / 单文件 / 未知 | 只按魔数 + 扩展名给格式标签，形态标「未知，需自行查看」 | ⛔ 不尝试解析、不假装支持 |

标签维度：补丁形态（换 exe / DLL 注入 / 覆盖式 / 安装器 / 未知）、容器格式、是否含说明文件、是否含 EXE、总体积。
分类谓词直接复用 `patch_preview.dart:155-196`（`_readmeExts` / `_installerExts` / `_libraryExts` / `_dataExts`）。

🔴 **识别结果只是标签与建议，用户可改、可忽略**；⛔ 不自动归档、不自动应用、不自动判定「这个补丁属于哪个游戏」。

#### 3.2.3 可视化

每条记录展示：名称 / 形态标签 / 格式 / 体积 / 路径 / 状态（已登记 / 已应用 / 路径失效 / 手动待处理）+ 操作（转移 / 预览应用 / 撤销 / 移除登记）。
打开面板时校验路径存在性 + size/mtime（大文件不每次全量重算 sha256，应用前再算）。
🔴 状态文案不给「已备份 / 可回滚」这类会误导用户放心覆盖的承诺（对齐 `patch_preview.dart:290-291` 的克制）。

#### 3.2.4 转移功能（新增，用户明确要求）

- **交互骨架**对齐详情页「移动游戏位置」：`game_detail_dialog.dart:819-887`（守卫 → 选目标 → 二次确认 → 独立进度框 → 结果提示）、
  `_MoveLocationDialog:4537-5004`、`_MoveProgressDialog:5009+`
- **差异**：本功能**预填默认目标** `<launchDir>/补丁/`（原流程 `_newLocation` 初始为 null、无预填，`:4553`），用户可改
- **语义**：默认**移动**（用户口述「转移到」「不想回资源管理器拖」＝移动），提供「改为复制」选项
- **轻量实现**：同盘 `rename`；跨盘 流式 copy + sha256 校验通过 + 删源；目标同名 ⛔ 不覆盖，自动加 `_2`
- ⛔ **不复用 `GameMoveService`**：它是目录级重事务，`moveGame`（`game_move_service.dart:64-70`）会改 `game.json` /
  快捷方式 / Magpie / 存档清单（`local_game_registry.dart:1832-1858 finalizeGameMove`），与「搬几个补丁文件」语义不匹配
- 🔴 转移成功后**同步更新索引里的路径**，否则登记立刻失效
- 二次确认文案对齐 `:4766-4794` 蓝色提示块

#### 3.2.5 打补丁前的固定提示条（用户明确要求）

- 面板常驻提示：「打补丁前，建议先到游戏目录查看是否有游戏或补丁的说明文件，按其要求操作」
- 配一枚「打开游戏目录」按钮（复用 `game_detail_dialog.dart:1024` 的 explorer 调用；🔴 需剥 `\\?\` 前缀，否则 explorer 打不开）
- 若识别到说明文件（`patch_preview.dart:155 _readmeExts`），额外列出并支持直接打开
- 安装器型补丁明确标注：「本软件不代跑安装器，也不会记录它做的改动，**这类补丁无法自动回退**」

### 3.3 辅助打补丁：推荐，不代决（目标二）

点「应用补丁」进**预览页**（不自动执行）：

1. **推荐落点**（复用 `buildPatchPreview` 的 `advice` 作默认值，`patch_preview.dart:259-286`）
   | 形态 | 推荐 | 理由 |
   | --- | --- | --- |
   | DLL 注入型 / 换 exe 型 | `launchDir` | DLL 劫持、同名 exe 替换，必须与启动程序同目录才生效 |
   | 覆盖式（包内顶层目录与 `bodyRoot` 子目录同名） | `bodyRoot` | `GameData/` 等须与本体结构同构 |
   | 安装器 | 不推荐落点 | 只给手动引导，⛔ 不代跑 |
   | 未知 | 不推荐 | 让用户自己选 |
   🔴 推荐**只是默认选中**，下拉可改为启动目录 / 本体根 / 自定义子目录
2. 逐文件清单：「将被覆盖 / 将被新增」+ 目标绝对路径，默认展开
3. **二次确认**：显示目标游戏名 + `gameId` + 落点，防「打错游戏／打错位置」
4. 执行：zip 走 `patch_extract_service.dart:158 extractTo`（先校验后落盘、防穿越、剥外层目录、失败清半成品）；
   7z/rar 明确提示「请先自行解压后以文件夹形式导入」；EXE 不代跑
5. ⛔ 全程不静默写盘、不替用户决定补丁该放哪

### 3.4 回退原版：一等公民（目标三）

- 应用前把**被覆盖的原文件**（存在才备份）复制到 `<launchDir>/.CTPatch/backup/<txId>/`
- `<launchDir>/.CTPatch/manifest.json` 记账：`txId` / `gameId` / 补丁记录 id / 时间 / 「原路径 → 备份路径」映射 /
  应用前后 sha256 / 落点 / 应用顺序
- 面板提供「撤销此补丁」与「一键恢复原版」（该游戏全部补丁按 manifest **严格逆序卸载**）
- 🔴 **还原前比对当前文件 sha256 与 manifest 的应用后值**：不一致说明用户后来手动改过 ⇒ 先警告并让用户选择，不闷头覆盖
- **只删／只还原自己写过的文件**（ADR-019 精确回滚范式），不碰用户其它文件 ⇒ 不触发 ADR-007 / ADR-020 回收站删除链路
- 任一步失败 → 逆序回滚；启动时 `recover()` 收拾残留事务；重叠补丁必须逆序卸载（对齐 `patches.rs:601-616` 结论）
- **诚实边界**：EXE 安装器、以及用户在本功能之外手动打过的补丁，没有基线 ⇒ **无法回退**，UI 必须明说，不制造虚假安全感

---

## 4. 数据与落盘

### 4.1 索引（零迁移）

`data/patch_vault/index.json`（`PathHelper.dataDir`，`path_helper.dart:156`）

```
{
  "version": 1,
  "games": {
    "<game_id>": {
      "patches": [ { id, sourcePath, fileName, sizeBytes, mtime, sha256, container,
                     kind, hasReadme, hasExe, status } ],
      "transactions": [ { txId, patchId, appliedAt, targetRoot, entries: [...] } ]
    }
  }
}
```

- 以 `game_id` 为键（ADR-011，稳定主键永不改写）
- 🔴 老数据 `gameId` 可能为空串（`local_game_registry.dart:229-236` 注释）⇒ 兜底：面板提示「该游戏缺少标识，无法绑定补丁」，
  ⛔ **不写回 game.json**、不拿目录名 / 标题当身份键
- ⛔ 不写 `game.json`、不动 `format_version=4`、不加 pubspec 依赖（现有 `file_picker` / `path` / `archive` / `crypto` 已够）

### 4.2 目录布局

```
<launchDir>/                        ← 启动程序所在目录（用户定义）
├─ 补丁/                            ← 转移功能默认目标，用户可改
│   └─ <补丁文件>
├─ .CTPatch/                        ← 备份与事务（隐藏）
│   ├─ manifest.json
│   └─ backup/<txId>/<原相对路径>
└─ <游戏原有文件>
```

🔴 **排除名单**：`<launchDir>/补丁/` 与 `.CTPatch/` 必须列入应用／备份扫描排除项，
否则转移进来的补丁文件会被当成游戏文件备份或覆盖（自己吃自己）。
🔴 默认目标不放 `ChronoTide_Cache`（会被缓存清理扫掉）——放游戏目录天然规避此坑。
🔴 转移目录名「补丁」是**用户口述的默认值**，需做成常量并允许改，⛔ 不能硬编码散落各处。

---

## 5. 事务与门禁

应用前依次过（任一不过即中止，不写盘）：

1. `GamePathResolver` 未离线、`bodyRoot` / `launchDir` 均存在
2. 游戏未运行（`Win32ProcessService.getProcessesInDirectory`，范式 `game_font_patch_service.dart:461`）
3. 可写性**真探测**（写 1 字节再删，范式 `patch_save_location.dart:108`）；Program Files / NAS 只读要有明确文案
4. 磁盘预检（×1.15 + 256MB，对齐项目既有空间账）
5. 补丁记录路径仍存在且 sha256 与登记值一致
6. `gameId` 与当前游戏一致
7. 路径护栏 `patch_path_guard.dart` 全量校验，有非法项**整批拒绝**
8. 写前重校验每个目标与暂存文件哈希（GalGear `Files changed since preview`）
9. 用户二次确认

状态机：`idle → preview → backingUp → applying → installed`；
失败 `→ rollingBack → restored`；用户撤销 `→ restoring → restored`；启动 `recover()` 收拾残留事务。
事务实现以 `game_font_patch_service.dart:429`（install）/ `:513`（失败回滚）/ `:545`（uninstall）为范式，
比 GalGear 的 Rust 事务更贴本项目。

---

## 6. 分期与验收（每期独立可交付、独立 commit）

| 期 | 内容 | 写游戏目录 | 验收 |
| --- | --- | --- | --- |
| **P0** | 契约与纯函数：`GameDirs`、索引模型、只读识别、落点推荐、事务计划 | ⛔ 否 | 离线夹具探针全绿（四形态包、穿越路径、失败注入、哈希漂移、逆序卸载） |
| **P1** | **目标一**：右键入口 + 导入 + 识别 + 可视化 + 转移 + 提示条 | ⛔ 否 | 面板渲染探针；转移后索引路径同步；路径失效检出 |
| **P2** | **目标二＋三（必须同批）**：预览确认、备份、应用、撤销、一键还原、recover() | ✅ 是 | 沙盒事务全绿；⛔ 不得单独上线「能打不能回」 |
| **P3** | 边界打磨（EXE 安装器、说明文件、离线目录）+ 真机走查 | — | 用户真机确认 |

🔴 **P2 不可再拆**：应用与回退分两期交付，中间态正是用户口述「只能重装游戏」的风险状态。

---

## 7. 改动文件清单（精确到行号）

### 7.1 新增

| 路径 | 职责 |
| --- | --- |
| `lib/services/patch_vault/game_dirs.dart` | `bodyRoot` / `launchDir` / `isOffline` 唯一实现（§2.1） |
| `lib/services/patch_vault/patch_vault_index.dart` | `index.json` 读写、CRUD、失效检测 |
| `lib/services/patch_vault/patch_inspector.dart` | 只读 sniff + 类型标签（§3.2.2） |
| `lib/services/patch_vault/patch_transfer_service.dart` | 单文件／单目录转移（§3.2.4） |
| `lib/services/patch_vault/patch_apply_service.dart` | 门禁 + 预览落点 + 备份 + 应用（§3.3 / §5） |
| `lib/services/patch_vault/patch_rollback_service.dart` | 撤销 / 一键还原 / 逆序卸载 |
| `lib/services/patch_vault/patch_vault_recover.dart` | 启动残留事务收拾 |
| `lib/models/patch_vault_record.dart` | 记录与事务模型 |
| `lib/widgets/patch_vault/patch_vault_dialog.dart` | 面板外壳（右键入口打开） |
| `lib/widgets/patch_vault/patch_record_card.dart` | 单条补丁卡片 + 状态 |
| `lib/widgets/patch_vault/patch_apply_preview.dart` | 推荐落点 + 逐文件清单 + 确认 |
| `lib/widgets/patch_vault/patch_transfer_dialog.dart` | 转移交互（骨架对齐 `_MoveLocationDialog`） |
| `dev_probe/patch_vault_probe.dart` | 离线行为探针 |

### 7.2 修改（仅 2 个既有文件）

| 文件 | 行号 | 改法 |
| --- | --- | --- |
| `lib/widgets/library_context_menu.dart` | `:7-23` | 加 `onPatchVault` 回调参数 |
| 同上 | `:30` | `menuHeight` 200.0 → **248.0**（5 项；不改会导致底部上翻判定错误） |
| 同上 | `:81-112` | `Column` 加一枚 `_buildMenuItem`（建议置于「启动管理」之后） |
| `lib/pages/library_page.dart` | `:2096-2125` | `_showContextMenu` 加回调闭包，传 `game` 给 `PatchVaultDialog.show` |
| 同上 | 文件头 | 新增一条 import |

`library_page.dart` 是 3643 行巨型文件：**只加一个回调 + 一条 import**，不碰其它逻辑。

### 7.3 明确不改（红线）

- 补丁站全部：`lib/services/patch/**`、`lib/widgets/patch_station/**`（⛔ 只 import 只读纯函数，不改语义）
- 探索侧：`discover_page.dart`、`game_detail_page.dart`、`game_detail/game_detail_header.dart`、`explore_hall_page.dart`
- 库页详情弹窗 `game_detail_dialog.dart`、编辑模式 `_showEditModeContextMenu`（`library_page.dart:574`）
- `library_page.dart` 的 `_buildTopBar` / `_filteredAndSortedGames` / `_buildGameGrid` / `_showContextMenu` 既有四个回调
- 数据核心：`game.json` / `GameDataFormat` / `local_game_registry.dart` / `format_version`
- 字体补丁：`game_font_patch_service.dart`、`font_library_panel.dart`、`font_picker_dialog.dart`（§2.2 分歧只记录，不修）
- 稳定区：`main.dart`、`main_container.dart`、`lib/theme/`、`app_state.dart`、`portable_*.dart`、`windows/runner/`、
  `lib/packages/luna_metadata_sdk/`
- `pubspec.yaml`（不新增依赖）、`.gitignore`、构建与打包脚本
- `GameMoveService` / `GameBodyRecyclePolicy` / `RecycleBinService`（只对齐 UI 范式，不调用）

---

## 8. 风险登记

| 级别 | 风险 | 应对 |
| --- | --- | --- |
| **P0** | 覆盖游戏本体是破坏性写，猜错即坏游戏 | 推荐仅默认值 + 二次确认 + 备份先行 + 写前重校验 + 失败逆序回滚 |
| **P0** | 用户不想要补丁却回不了原版 | 应用与回退**同批交付**；manifest 记账；一键还原 + 单补丁撤销 |
| **P0** | 「启动目录 ≠ 本体根」被搞混 ⇒ 备份／落点放错 | `GameDirs` 唯一实现 + UI 显式显示落点绝对路径（§2） |
| **P1** | 转移进 `<launchDir>/补丁/` 的补丁被当成游戏文件覆盖／备份 | 硬排除名单（§4.2） |
| **P1** | 备份占盘（覆盖式补丁可能数百 MB） | 预检 ×1.15 + 256MB；确认页显示备份体积 |
| **P1** | 游戏运行中 / 目录只读 / NAS 离线 | 门禁 1–4，失败给具体原因，⛔ 不静默降级 |
| **P1** | 还原覆盖用户后来的手动改动 | 还原前 sha256 比对 + 警告 + 用户选择 |
| **P1** | 重叠补丁卸载顺序错导致残留 | manifest 记顺序，严格逆序 |
| **P1** | 老游戏 `game_id` 为空 ⇒ 绑定失效 | 面板明确提示，⛔ 不造身份键、不写 game.json |
| **P2** | 7z / rar / EXE 不支持被误认为「已管理」 | 只登记 + 明确「需自行解压／不代跑／无法回退」，不假装支持 |
| **P2** | 巨型文件里加菜单项撑破边界检测 | 同步 `menuHeight`；渲染探针覆盖 1280×720 与最小窗 |

---

## 9. 验证方式（按本项目 231 环境现实）

1. **纯 Dart 行为探针**（离线夹具）：四形态包识别、zip 穿越整批拒绝、失败注入回滚、哈希漂移告警、
   逆序卸载、转移后索引同步、`game_id` 空值兜底、两个根的取值
2. **进程内 analyzer**：只看新增 error（`.workbuddy/analyze_probe/ct_analyze_probe.dart`，只收具体文件路径）
3. **`flutter_tester` 渲染探针**：🔴 **必须整屏渲染 `LibraryPage` 本身 + 新面板**，
   且加「必然存在的文案」断言（2026-11-11 灰屏事故铁律：只探子页面会假绿）；
   双尺寸 1280×720 / 最小窗，`FlutterError.onError` 自设捕获，`takeException()` 不足以发现被压扁
4. **危险用例一律跑在临时沙盒游戏目录**，⛔ 绝不拿真实游戏目录验证
5. **`git status --short` / `git diff --stat`** 自查改动面，确认无计划外文件
6. ⏳ **真机构建与走查由用户执行**（231 只在工具进程树侧复现，`Start-Process` detach 被拦）

---

## 10. 拍板结果（2026-11-11 20:40 用户批准）

| # | 问题 | 结果 |
| --- | --- | --- |
| 1 | 一期范围 | ✅ **一次完成 P0–P3**，不分期交付（应用与回退同批落地） |
| 2 | §2.4 启动目录口径 | ✅ 按用户定义：备份放**启动目录** |
| 3 | 转移语义 | ✅ **移动**（删源）；对话框内保留「取消勾选＝改为复制」 |
| 4 | 编辑模式右键 | ✅ 按建议：不加 |
| 5 | 面板形态 | ✅ 按建议：居中大对话框 |
| 6 | 工作代号 | ✅ `PATCH-VAULT` 定名 |

---

## 11. 实施结果（2026-11-11 21:1x）

### 11.1 实际落地的文件

**新增 15 个**（`apps/chrono-tide` 相对路径）：

| 层 | 文件 |
| --- | --- |
| 模型 | `lib/models/patch_vault_record.dart` |
| 服务 | `lib/services/patch_vault/game_dirs.dart`、`patch_vault_index.dart`、`patch_inspector.dart`、`patch_apply_plan.dart`、`patch_apply_service.dart`、`patch_rollback_service.dart`、`patch_transfer_service.dart`、`patch_vault_recover.dart` |
| UI | `lib/widgets/patch_vault/patch_vault_dialog.dart`、`patch_record_card.dart`、`patch_apply_preview.dart`、`patch_transfer_dialog.dart` |
| 探针 | `dev_probe/patch_vault_probe.dart`、`dev_probe/patch_vault_ui_probe.dart` |

**修改 2 个既有代码文件**：`lib/widgets/library_context_menu.dart`（回调 + 第 5 项 + 高度/内边距），
`lib/pages/library_page.dart`（一条 import + `_showContextMenu` 一个回调闭包）。
**文档**：本文件、`docs/DEV/DEV_LOG.md`、`docs/DEV/SESSION_HANDOFF.md`。

### 11.2 与方案的 6 处受控偏差（均为更保守，非范围扩张）

1. **`PatchVaultManifestStore` 并入 `patch_vault_index.dart`**（未单列文件）：两者都是 JSON 存储层，合并后 `lib/services/patch_vault/` 共 8 个文件。
2. **新增 `patch_apply_plan.dart`**：把「摊平补丁源 / 推荐落点 / 逐文件计划」从应用服务里抽成可离线探针的纯函数层，是 §6 P0 的落实。
3. **索引只存事务摘要，逐文件映射唯一真值在游戏目录 `manifest.json`**：避免应用数据目录与游戏目录双写绝对路径、游戏搬家后漂移；面板快速显示用摘要，回退只读 manifest。
4. **zip 暂存区放应用数据目录 `data/patch_vault/tmp/`，不是游戏目录**：预览页因此**零写游戏目录**，只有用户点「确认应用」才开始写。
5. **`recover()` 改为打开面板时对当前游戏懒执行**：`main.dart` / `main_container.dart` 属未批准禁动的稳定区，不做启动钩子；用户再次接触补丁功能前残留一定已被收拾（详见 `patch_vault_recover.dart` 文件头）。
6. **磁盘预检同时查启动目录与落点根**（两个根可能跨盘），×1.15 + 256MB。

### 11.3 渲染探针照出的两个既有菜单缺陷（已修）

- `menuHeight` 由 248 估成 **256**：flutter_tester 实测 5 项菜单实高 **251px**，估值偏低会让上翻后底部仍溢出屏幕 5px。
- 菜单项右内边距 **71 → 32**：160px 宽只剩 73px 给 `Row(Icon 18 + 「加入收藏夹」约 89)`，横向溢出约 20px（4 项时已存在，本次探针首次照出）。

### 11.4 验证（全部在临时沙盒 / 纯 Dart 探针，⛔ 未碰任何真实游戏目录）

| 项 | 结果 |
| --- | --- |
| `dev_probe/patch_vault_probe.dart` | **109 PASS / 0 FAIL**（两个根、排除名单、四形态识别、zip 穿越整批拒绝、转移与索引同步、失效检测、应用事务、失败注入逆序回滚、哈希漂移、重叠补丁逆序卸载、recover 幂等、game_id 空兜底） |
| `dev_probe/patch_vault_ui_probe.dart` | **28 PASS / 0 FAIL**（`LibraryPage` 整屏 + 5 项右键菜单双尺寸上翻 + 主面板 + 预览页 + 转移框 + 记录卡片；含「必然存在文案」断言） |
| 进程内 analyzer（17 个文件） | **0 error**（新增文件 0 warning；`library_page.dart` 3 条既有 warning 未动） |
| `git status` | 改动面限定在上述文件，⛔ 未触碰补丁站 / 探索侧 / `game.json` / 稳定区 / `pubspec.yaml` |

🔴 **探针期间踩到并修掉的真 bug**：`scanGameShape` 原先只从本体根扫 exe，`launch_path` 带子目录时会把「替换主程序型」误判成隔离型 → 改为 exe 名从**启动目录**扫、顶层子目录从**本体根**扫（§2 两个根分开的意义）。

### 11.5 ⏳ 待用户真机走查（231 只在工具进程树侧复现，构建须用户自己跑）

1. 库页卡片右键「补丁管理」→ 面板打开、提示条与「打开游戏目录」可用。
2. 导入 zip / 文件夹 → 形态标签、说明文件清单、体积是否正确。
3. 转移：默认目标 `<启动目录>/补丁/`、移动后原文件消失、登记路径自动更新。
4. 应用：推荐落点是否符合该游戏实际结构、逐文件清单、二次确认、备份落在 `.CTPatch/backup/<txId>/`。
5. 回退：单补丁撤销 / 一键恢复原版 / 哈希漂移确认框 / 重叠补丁逆序。
6. 边界：EXE 安装器、7z/RAR、NAS 离线、Program Files 只读、游戏运行中。

### 11.6 诚实边界（UI 已明说，不制造虚假安全感）

EXE 安装器不代跑、7z/RAR 需自行解压；这两类以及用户在本功能之外手动打过的补丁**没有基线，无法自动回退**。
撤销只还原本功能写过的文件；`launchDir ≠ bodyRoot` 时备份与落点不在同一目录，UI 显式显示两者路径。

---

## 附：阶段 A（方案期）诚实声明 — 保留作历史记录

- ✅ 阶段 A 已完成：只读审计（必读清单、补丁站档案、库页 / 右键 / 字体补丁 / 移动位置 / 数据层 / 路径体系全部核实到行号）；目标对齐与方案 v2
- ❌ 阶段 A 当时未写业务代码、未跑探针、未改既有文件 —— **该状态已被 §11 的实施取代**
- ⏳ 真机构建与走查仍待用户执行（见 §11.5）
