# 单文件导入解压流水线重构 —— 安装中心承载方案（变更计划）

## 2026-10-05 智能解压去层级化：密码组体系 + 改名链 + 安装中心日志/遮挡修复（76472c4 + 5f29e60）

**需求**（用户六条）：①密码去层级化 ②密码记忆策略（本次输入→预设组→历史组→密码库，组为整体不可拆散）③后缀改名链内置+自定义 ④计划窗简化为「设定/后缀」两板块 ⑤实际解压区（密码组填写+位置选择）⑥安装中心操作日志面板 + 弹窗遮挡修复。

**实现**：
- `unpack_store.dart`：PasswordGroup（预设/历史组，签名去重 LRU 10，存 `unpack_settings.json` 'password_groups'）；`passwordLibrary` 汇总保底；内置改名链对齐需求顺序（.mp4/.mov/.exe/.txt/空后缀）+ `defaultAutoTryChains`/`customAutoTryChains` 只读视图。
- `extract_manager.dart`：候选队列 = 本次输入→预设组→历史组→本包记忆/包内提取→密码库（每层同队列）；`_encTryAllowed` 扁平组语义；补输成功整组记历史；`onOpLog` 钩子 7 处打点。
- `archive_plan_dialog.dart`：计划窗=①设定（密码组+密码库管理弹窗）②后缀（内置链展示+自定义规则）；分层密码/映射/策略预览删除；新增 `showExtractStartDialog` 实际解压区。
- `global_install_center.dart`+`install_center_page.dart`：onOpLog 环形缓冲 200 行仅内存、每任务清空；解压视图标题与进度条之间可收起日志面板。
- `main_container.dart`：**遮挡根因=框架级**（flutter navigator.dart:4429 每次 flush `rearrange` + overlay.dart:754 把非路由外来 OverlayEntry 插回最顶）→ 安装中心从根 Overlay 改挂本壳 Stack 顶层（盖页面、天然在弹窗 route 之下）。

**验证**：flutter_tester 离线探针 20/20（组存取/去重/库汇总/链默认与自定义/JSON 往返）；flutter analyze 六文件 0 error（新增 issue 已清）。⚠️ 未真机走查（计划窗/实际解压区/日志面板 UI + 遮挡实测）；UnpackPreset 分层预设模型成 UI 死代码（P2 清理项）。

---

> 2026-10-05 第二轮实机反馈（1db8fc5 + c69be82 + b450496）：① RAR5 加密文件名误报损坏 +
> 计划密码层间共享（分享者常用同一密码贯穿多层）；② **解压完成≠入库**：确认窗只收口解压流程，
> onUnpackReadyForManualImport → JoinController.pendingExtractedDir 静态信箱（Offstage 保活）
> → 添加页预填表单，数据填写与「确认入库」完全由用户手动操作；③ 三情景缺口：
> `_sniffDisguisedFiles` 散文件伪装容器复查（常规候选空时收 disguised 容器为嵌套候选，多候选走
> 歧义选择窗）+ `detectFileType` 嗅探前移（exe 实为 rar 走解压链）。flutter_tester 离线探针
> 27/27（三情景真实文件实测）；flutter test 待 C 盘腾挪后补跑，真机三情景走查待用户执行。

> 2026-10-05 实机测试修复（a4e9044 + d5676bd）：① `_startExtraction` 漏传 unpackPlan 已补
> 透传（计划窗确认的层序/密码真正生效）；② `_rollback` 先发错误再切 failed 相位（失败显示真实
> 原因）；③ 新支持网盘过审壳「视频头+尾部拼接 zip」：sniffSync 尾部 EOCD 反查（256KB 窗、两路
> 结构校验）+ `_extract7z` 退出码 >1 放行 7z 非致命警告；flutter_tester 离线探针 13/13 全绿
> （含真实样本判 zip+disguised）；flutter test 待 C 盘腾挪后补跑，真机复测待用户执行。

> 状态：**C1-C5 已落地**（0fb86d6→52932b6→2946705→7b05daf→8b9dc7a）；C6 文档同步本条。进程内探针 0 error；⏳ 未跑 flutter test、待全量真机走查。
> 日期：2026-10-05
> 上游文档：`features/join_unpack_scenarios_v2.md`（Phase A-F 六场景，已收官）
> 用户拍板结论：废弃单文件导入的进度窗与确认入库进度窗；解压全过程移入安装中心；仅保留计划窗 + 决策弹窗。

---

## 0. 用户拍板要点（原话锚点）

1. 单文件导入**废弃导入加载窗口**（JoinProgressDialog），成功/失败只提示。
2. 解压全过程移到**安装中心**（GlobalInstallCenter），复用现成安装进度 UI。
3. **废弃确认入库窗口**的进度形态：确认入库像批量导入一样快速完成 + 提示。
4. 仅保留：解压决策窗、解压计划窗、补救弹窗（密码/损坏/歧义/本体缺失）。
5. 进度条语义 = **当前段**进度（正在确定格式 → 解压 .lz4 → 扫描判定本体 → 继续解 .7z → …），不是全程总进度。
6. 流水线：计划窗决策 → 安装中心队列 → 分段解压 → 每段解完自动扫描判定游戏本体（游戏数据 + 启动程序 exe）→ 出问题弹窗补救 → 找到本体 → 确认文件夹名 → 入库 → 结束。

---

## 1. 现状审计（根因清单，全部只读验证）

### 1.1 进度窗「请稍候」十分钟无信息 —— 实锤根因

**JoinProgressDialog 的内容永不刷新。**

- `join_page.dart:503-505`：`OverlayEntry(builder: (_) => JoinProgressDialog(...))` 直接把 StatelessWidget 塞进 Overlay；
- `progress_dialog.dart:7-66`：StatelessWidget，**没有任何 Listenable 订阅**，也没有 `OverlayEntry.markNeedsBuild()`（join_page.dart 全文无 markNeedsBuild）；
- 进度事件其实一直在发：`join_controller.dart:435-439`（`_onExtractProgress` → `_progressMessage` → notifyListeners），但监听重建的 AnimatedBuilder 只包了**页面本体**（join_page.dart:515-516），Overlay 里的弹窗内容不重建；
- 页面 build 里的 :522-531 只负责「成功/失败后延迟 500ms 移除 Overlay」，弹窗内容始终冻结在初始态「请稍候...」+ 不确定进度条（progress_dialog.dart:103、:77-78）。

> 结论：无论解压进行到哪一层、有什么消息，用户看到的永远是「请稍候」。这是「十分钟无信息」的直接原因，与解压内核无关。

### 1.2 取消后窗口卡死 —— 链路脆弱点（三处）

1. **`extract_manager.dart:3380`**：`cancel()` 整个函数体包在 `if (_status == ExtractStatus.extracting)` 里——状态不在 extracting 时（start() 前置阶段、决策等待间隙等）取消**静默无效**，不产生任何终态；
2. **`extract_manager.dart:342-345`**：`start()` 遇到已有任务执行中只 `_log('WARN')` 后**静默 return**——上一个任务卡死时，后续任务全部「假启动」：无进度、无报错、无终态，进度窗永久等待；
3. **`join_controller.dart:1608-1614`**：`cancelOperation` 依赖 `isArchiveType` 守卫（:375-381）才调 `em.cancel()`；且取消语义靠复用 `failed` 终态（:3403-3404），无独立取消通道。

> 结论：取消链路「只要差一环就永久卡死」。重构后走安装中心的 `cancelCurrentTask`（每任务独立 DownloadCore/ExtractManager 实例，global_install_center.dart:92-97），状态污染问题自然消解；仍需补 cancel 的兜底终态。

### 1.3 `.7z.lz4` 双嵌套「只解一层停住」

- **计划层结构**：`archive_inspector.dart:272-275`——lz4 分支 `contentKnown=false`，计划只有 1 层，内层 .7z 依赖执行期重扫续链；
- **执行期续链逻辑存在且正确**：`extract_manager.dart:1285-1288`（`_scanForCandidates` 产物重扫）→ :1382-1383（嵌套包魔数判定 `nested.magicFormat`）→ 下一层循环；bz.exe 解 lz4 也在 Phase 1 G5 修好（:2777-2782）；
- **真正的停点候选**（无会话日志，按代码判定概率排序）：
  1. **进度窗冻结**（§1.1）让用户完全看不见「第 2 层正在解压」，大包慢解时观感 = 「停了」；
  2. `await process.exitCode`（bz.exe :2852 / 7z 同类）**无超时**——进程挂起即流程永久停在该层；
  3. 决策 Completer（`_requestDecision` :1426-1441）无兜底超时，若弹窗被忽略/未渲染即永久等待。
- **真机日志未取证**：安装目录 `logs/extract_*.txt`（path_helper.dart:72，exe 旁）可精确定位停点，待用户下次复现时取。

> 结论：重构后进度真实可见 + 每段状态消息，观感问题根治；进程看门狗列为 P1 加固（不在本计划核心范围）。

### 1.4 可复用的现成件

| 现成件 | 位置 | 复用方式 |
|---|---|---|
| 安装中心解压进度接线 | `global_install_center.dart:463-471`（`extractMgr.addProgressListener → _emitProgress`） | 解压任务直接复用同款接线 |
| 串行队列 + 终态 2s 推进 | `global_install_center.dart:77-82,1043` | 解压任务入同一队列 |
| 每任务独立 ExtractManager | `global_install_center.dart:92-97`（`_activeDlCore`） | 状态隔离，根治 §1.2-2 |
| 取消 + IMP-21 回滚 | `global_install_center.dart:966,826` | 解压任务直接用 |
| 确认文件夹名窗 | `showExtractFinishDialog`（join_page.dart:111-119 注入；改名+删源包勾选） | 完成段触发，挂到全局 |
| 批量导入快速提示样板 | `join_page.dart:481-497`（`_BatchSuccessOverlay`，3s 自动消失） | 照此做单文件导入成功/失败 toast |
| 入库注册逻辑 | `join_controller.dart:1230+`（`_finalizeAdoptedExtraction`：写元数据 + 注册） | 迁移到安装中心完成回调 |
| 习惯记忆 | `join_controller.dart:1124-1140`（`recordHabit`） | 随迁移搬入 |

---

## 2. 目标流程

```
拖入文件 → 魔数嗅探/类型判定（现状保留，17a2359 拦截普通文件）
  ├─ 文件夹 / exe → 现有拷贝/识别流程（本次不动）
  └─ 压缩包 → 解压计划窗（保留，join_page 表单上下文弹出）
        └─ 确认 → 构造 localArchive 任务提交 GlobalInstallCenter
              │   toast「已加入安装队列」（BPM 下也可见）
              ├─ 安装中心队列（与下载安装任务同队列串行）
              ├─ 解压全程（ExtractManager 计划驱动路径原样复用）：
              │     进度=当前段：「正在解压第N层(...)」→「扫描产物」→「识别游戏本体」
              │     决策弹窗（密码/strategy/ambiguity/corrupt/body）→ rootNavigator 全局弹出
              ├─ completed → 弹「确认文件夹名」窗（复用 showExtractFinishDialog）
              │     ├─ 确认 → 可选改名 + 可选删源包 + 写元数据入库
              │     │          → toast「导入成功」→ 安装中心显示安装完成 → 2s 推进队列
              │     └─ 取消 → 产物保留不入库，任务按完成收尾 + toast 说明
              └─ 失败/取消 → 现有 _rollback 清理 → 安装中心失败态 → toast「导入失败」
```

**关键语义拍板**：解压任务的「成功终态」= 确认窗处理完毕（入库或明确放弃入库），**不是**解压 completed——确认窗挂起期间队列不推进（见 §4 风险 4）。

---

## 3. 改动文件清单（批准后执行）

### Phase 1 —— 解压任务接入安装中心（核心）

**① `lib/services/global_install_center.dart`**
- `InstallTask`（:38-73）：+`kind`（`'download' | 'localArchive'`，默认 download）、+`localArchivePath`、+`unpackPlan`（UnpackPlan?）、+表单元数据已有字段复用；`downloadUrl` 改可空；
- `_executeTask`（:235+）：kind 分流——localArchive 跳过下载段（不接下载监听），直接进 extracting；
- `_startExtraction`（:450+）：输入源按 kind 取 `localArchivePath`（download 任务仍用 `_downloadedFilePath`）；执行前把 `onExtractDecision` 钩子注入该任务的 ExtractManager；
- 新增回调字段 `onUnpackNeedsConfirmation`（completed 且 kind==localArchive 时触发，带 extractedDir/sourceArchive/title）与 `onUnpackDecisionRequest`（决策弹窗）；
- 新增公开方法 `confirmUnpackImport({finalDirName?, deleteSourceArchive, 表单元数据})`：改名 → 删源包（勾选）→ 写元数据 → 习惯记忆 → 置成功终态 → 2s 推进；`cancelUnpackImport()`：产物保留、按完成收尾。

**② `lib/main_container.dart`**
- initState 注入 `GlobalInstallCenter.instance.onUnpackDecisionRequest`：password/strategy/ambiguity/corrupt/body 五种弹窗（逻辑从 join_page.dart:125-149 **迁移**，弹窗组件本体不动），用 rootNavigator showDialog 保证压在安装中心 Overlay 之上；
- 注入 `onUnpackNeedsConfirmation`：弹 `showExtractFinishDialog` → 调 `confirmUnpackImport` / `cancelUnpackImport` → 成功/失败 toast。

**③ `lib/pages/join/join_controller.dart`**
- `confirmCurrentSelection` 压缩包分支（:958-1001）：计划窗确认后**不再 `startExtractFlow`**，改为构造 InstallTask（kind=localArchive，携带 plan + 表单元数据）→ `GlobalInstallCenter.instance.submitTask`；成功 → toast「已加入安装队列，请在安装中心查看」；
- `startExtractFlow`（:1026+）执行职责整体移交，删除或留壳（grep 引用后定）。

### Phase 2 —— 废弃进度窗 + 确认入库快速化

**④ `lib/pages/join_page.dart`**
- 删 `_progressOverlay`（:79）、`_showProgress`（:500-506）、`_dismissProgress`（:508-511）、build 进度窗段（:518-531）、dispose 中 `_dismissProgress()`（:200）；
- 删已迁走的三个钩子注入（:100-149 passwordPromptProvider/confirmExtractFinish/decisionProvider；archivePlanProvider 保留）。

**⑤ `lib/pages/join/widgets/progress_dialog.dart`** → 整文件删除（全仓唯一引用即 join_page）。

**⑥ `lib/pages/join/join_controller.dart`（续）**
- 删进度状态机：`_isProgressSuccess/_isProgressFailed`（:59-60）、`progressValue/progressMessage`、`resetProgress`（:1599）、`isProgressSuccess/isProgressFailed` getter（:346-347）、`_onExtractStatusChanged/_onExtractProgress/_onExtractSuccess/_onExtractFailure`（:410-449）、`initListeners`（:383）与 dispose 对应拆卸（:398-406）；
- 删两段式接管链：`handleExtractSuccess`（:1084）、`_adoptExtractedDir`（:1217）、`_finalizeAdoptedExtraction`、`_pendingAdoptDir/_pendingAdoptMetadataDir` 系列（核心逻辑已迁移 ①⑥）；
- `cancelOperation`（:1608）简化为纯表单复位（解压执行已不归它管）。

### Phase 3 —— 安装中心 UI 补强

**⑦ `lib/pages/install_center_page.dart`**
- `_buildExtractingUI`（:658-725）**补取消按钮**（现状解压中无取消入口，下载中有 :649-652 可对照）；
- 状态徽标与文案按任务类型微调（可选）。

### ExtractManager 侧

**⑧ `lib/services/extract_manager.dart` —— 本次不动核心**
- ⛅ 仅一处最小适配：`start()` 静默 return（:342-345）——安装中心每任务独立实例后正常不会触发，不改；
- P1 加固（单独提交、可推迟）：`await process.exitCode` 看门狗 + 决策 Completer 兜底超时；
- ⛔ 层循环/密码队列/决策请求/本体识别核心逻辑（Phase A-F 收官代码）一行不动。

---

## 4. 风险点

| # | 风险 | 对策 |
|---|---|---|
| 1 | `downloadUrl` 可空化的编译影响面（全部 InstallTask 构造点 + `_startDownload`） | 先 grep 全部构造点逐一核对；`_executeTask` kind 分流后仅 download 分支触碰 downloadUrl |
| 2 | 决策弹窗层级：必须压在安装中心 OverlayEntry 之上 | main_container 最外层 context + `showDialog(useRootNavigator: true)`；真机验证 |
| 3 | JoinController 删减回归面（批量导入 `_saveSingleToBatchGame`/onAutoSave、BPM 手柄路径对表单的引用） | 删减前 grep 每个待删成员的全部引用；批量导入全流程回归测试 |
| 4 | **确认窗挂起期间队列推进**：现有终态 2s 自动推进会在用户还没确认时就跑下一个任务 | 成功终态推迟到 `confirmUnpackImport/cancelUnpackImport` 完成才置位（§2 语义拍板）；`_completeTask` 调用点相应调整 |
| 5 | 确认窗取消的收尾语义 | 产物保留 + 任务按完成收尾 + toast 说明「已解压，未入库」；不做静默回滚 |
| 6 | 习惯记忆迁移遗漏（`recordHabit` 挂在 handleExtractSuccess :1124-1140） | 迁移到 `confirmUnpackImport`，随 Phase 1 一起做 |
| 7 | BPM 下安装中心不可见 | 提交任务后必弹 toast；BPM 手柄路径回归走查 |

## 5. 验证方式

1. `flutter analyze` 改动文件——0 新增 error（对照基线只看新增）；
2. `flutter test` 现有 join/extract 相关用例全绿；
3. 真机走查清单：
   - `.7z.lz4` 双嵌套包全流程（本轮事故包）；
   - 加密包密码流程（候选队列 + 补输弹窗在安装中心之上弹出）；
   - 伪装包（.zip 改名 .mp4）；
   - 多候选歧义选择、corrupt 重试、本体缺失弹窗；
   - 解压中取消（安装中心按钮）→ 回滚 + 失败态；
   - 确认窗改名 + 删源包勾选；
   - 批量导入回归（不受影响验证）；
   - 探索页在线安装回归（downloadUrl 可空化影响验证）；
   - BPM 下提交任务 toast 可见性。

## 6. 明确不改

- ExtractManager 层循环/密码队列/决策请求/本体识别（join_unpack_scenarios_v2 Phase A-F 收官代码）；
- `archive_plan_dialog.dart` 计划窗与五种决策弹窗组件本体；
- 批量导入 / 智能导入流程；
- GlobalInstallCenter 下载任务路径、`_rollback`（IMP-21）、终极验证链。

## 7. 实施顺序与提交切分

| 提交 | 内容 | 规模 |
|---|---|---|
| C1 | ① InstallTask 扩展 + localArchive 执行分流 + 钩子字段 + confirmUnpackImport | 中 |
| C2 | ② main_container 注入决策/确认回调 | 小 |
| C3 | ③ JoinController 提交链改造（计划窗确认 → submitTask） | 中 |
| C4 | ④⑤⑥ 废弃进度窗 + JoinController 状态机删减 | 中 |
| C5 | ⑦ 安装中心解压取消按钮 | 小 |
| C6 | 文档同步（DEV_LOG / SESSION_HANDOFF / 本档案更新） | 小 |

每提交独立可编译、`analyze` 零新增 error；C3 完成即具备真机走查条件（旧进度窗尚在但不触发）。
