# 发布窗「自动填充元数据」修复（封面 / 横幅 / 截图 2026-10-06）

> 状态：🚧 **2026-10-07 第四轮：交互重构为「候选数据源选择」**（§8，用户拍板：与添加页同款），并移除 §7 的诊断插桩。§7 的锚守门被 §8 取代（显式选择取代自动拒绝）。

## 8. 第四轮：候选数据源选择模式（2026-10-07，用户拍板）

用户需求原话：点完一键抓取后应出现「让用户选择他想要的原数据平台」的板块，选完之后原数据自动填入——文字进输入框、图片进预览区，要求与添加页完全类似，UI 稳定、体验优秀。

### 8.1 交互重构（publish_game_dialog.dart）

| 旧 | 新 |
|---|---|
| 一键抓取 → 自动择优 + merge → 直接填表单（用户全程无选择权） | 一键抓取 → **只检索** → 候选板块列出各数据源结果卡片（平台徽章 + 封面缩略 46×62 + 标题 + 原名 + 发售日） |
| 锚不中直接拒绝填充（§7-B） | 取消自动拒绝：用户自己看卡片挑（相关度排序：命中检索词身份的在前，同组按完整度降序） |
| 图片在抓取时就下载 | 图片下载移到**点选候选后**（`_selectCandidate`），以所选结果为 `base` 调 `mergeForPublishMetadata`（新增 `base` 参数），同作品其余来源只补缺失字段 |

- 卡片点选语义与添加页 `JoinController.selectScrapeResult` 一致；换选其它卡片可覆盖上次自动填充的内容（`_autoFilledFields` 机制保留），手动编辑过的字段永不覆盖。
- 填充进度显示在板块头部（「下载封面…」等），应用中禁止切换卡片（`_applyingResult`）。
- 板块可折叠（chevron）；候选封面缩略用 `CachedNetworkImage`（**不包 NsfwImage**——其 ImageFiltered 模糊层在本窗口实测诱发合成错位）。
- 复用 `resolvePlatformBadge`（join/widgets/platform_badge.dart）渲染平台徽章。

### 8.2 渲染鬼影：拿到实锤 + 结构性规避

- 诊断快照（`publish_debug_1791348001758.png`）实锤：**简介多行 TextField 的文本被画到表单顶部**（覆盖抓取按钮与标题区），封面卡/步骤胶囊叠印上一帧内容——局部重绘 damage 错位。
- 结构性规避：**移除 `IntrinsicHeight`**（封面卡改固定高 280，原「随右列撑满」），IntrinsicHeight + 多行 TextField 同帧内容变更的组合是主要嫌疑。
- §7.3 的 RepaintBoundary/快照插桩全部移除（已达成使命，且弹提示伤 UX）。

### 8.3 验证

- 离线探针：`test/widgets/publish_metadata_merge_test.dart` 新增 `base` 参数回归（用户点选来源优先于自动择优、异身份宁缺勿抄）。
- 🟡 待真机复验：搜缘之空 → 抓取 → 应见多张候选卡（含 MIX），点选后文字/图片正确填入；换选另一张可纠正；鬼影不再复现。

## 7. 第三轮修复（2026-10-07，用户复测仍乱后）

真机复测（构建含 a1f666e，app.so 12:00:53）仍见乱 → 重新审计，推翻部分旧结论：

### 7.1 误判更正（重要）

- **「英文名被填 Senren * Banka」是 hint 误读**：数据源根本没有英文名/繁中名字段
  （`metadata_fetcher.dart` 无 `english/romaji/title_tc` 键，`_applyMetadata` 也不写
  `_enCtrl/_tcCtrl`）；`Senren * Banka`/`千恋＊万花` 是 `dark_surface.dart` 的输入框
  **灰色 hint 示例文字**，与真实填充值在截图里无法区分。§6 把它当实锤根因是错的。
- 截图 2 里真实填充的值全部正确（原名 ヨスガノソラ ✓、简介 ✓）。
- **渲染鬼影是真问题且 a1f666e 未修复**（NsfwImage 模糊层推断被证伪），帧级根因
  仍未锁定 → 本轮加 `RepaintBoundary.toImage` 插桩（§7.3）。

### 7.2 本轮确定性修复（全部在 publish_game_dialog.dart）

| # | 修复 | 说明 |
|---|---|---|
| A | **图片删除时序** | 旧逻辑在下载新图**前**删旧目录，而界面还显示旧图 → 下载窗口期内 Image.file 重新加载已删文件 → 空白。改为：新路径全部 setState 生效**后**才清理旧目录；全失败则保留旧图 |
| B | **锚守门** | 检索词归一化后与任何候选名字集都无交集 → 拒绝填充，提示「没有与「X」匹配的作品」（旧逻辑按完整度择优填入陌生作品，搜「YOU」被填千恋＊万花原名/简介） |
| C | **自动填充可覆盖** | 记录上次抓取填过的字段（`_autoFilledFields`），二次抓取可覆盖纠正；用户手动编辑过的字段（`_humanEditedFields`，controller listener 判定 + `_autoFilling` 抑制误标）永不覆盖 |
| D | **errorBuilder** | 三处 Image.file 加显式「图片加载失败」占位，不再静默空白 |
| E | **hint 去误导** | 日语原名/英文名/繁中名 hint 改空串 |

### 7.3 渲染快照插桩（临时，定位后移除）

- 弹窗外层包 `RepaintBoundary(key: _debugRepaintKey)`；
- 抓取完成 500ms 后**自动**导出 PNG 到 `dataDir/tmp/publish_debug_*.png` 并提示；
- 手动补拍：点击抓取按钮左侧的说明文字。
- 快照是**真机真实渲染内容**（与屏幕所见逐像素一致），拿它直接看鬼影在渲染树里的
  形态，不再靠用户截图猜。

### 7.4 待办

- 🟡 真机复验（构建由 AI 侧完成后通知开发者）：搜缘之空抓取 → ①数据应全对 ②看快照
  是否复现鬼影 → 复现则分析 PNG 定位，未复现则对比观察。
- 定位完成后移除插桩。

## 6. 真机踩坑二次修复（2026-10-07）

> ⚠️ **本节结论已被 §7 部分推翻**：6.1 的「英文名混流」实为 hint 误读（见 §7.1）；
> 6.2 的「NsfwImage 模糊层」推断被复测证伪（移除后鬼影仍在）。身份过滤代码无害保留。

首版上线后真机走查（搜《缘之空》）暴露两个新问题：

### 6.1 数据张冠李戴（确定性 bug）

| 症状 | 根因 |
|---|---|
| 《缘之空》被填入英文名 `Senren * Banka`（千恋＊万花的罗马字） | `mergeForPublishMetadata` 从**所有**其余候选补字段，不校验身份；搜索候选列表混入《千恋＊万花》 |

**修复**（三层）：
1. **同作品过滤**：`publishSameWork()`——候选与主结果的「身份名字集」（原名 + 标题分别 `TitleCleaner.normalizeForCompare` 归一化）有交集才算同作品；异身份候选**一律不补**（宁缺勿错）。
2. **身份锚择优**：`pickPublishBestResult` 新增 `queryHint`（用户输入的检索词）——无 MIX 时优先在「与检索词共享任一名字」的候选里择优。否则字段最全的**陌生作品**会直接抢走主结果（探针实测：千恋万花完整度 7 分 vs 缘之空 3 分）。
3. `_fetchMetadata` 调用处传 `queryHint: name`。

⚠️ 身份匹配必须**名字集相交**而非单键相等：检索词常等于候选 title 而不等于原名（缘之空 vs ヨスガノソラ），单键永远失配（探针抓出后返工）。

⚠️ 残余风险（文档化）：检索词与任何候选都对不上时，回退全量完整度择优——主结果仍可能是陌生作品（与修复前行为一致，不比之前更差）。

### 6.2 渲染错乱（高置信推断，待真机复验）

| 症状 | 推断根因 |
|---|---|
| 抓取后表单文字互相叠加、下半字段消失；滚动时残留物**不随内容移动**（画在固定层） | 发布窗预览图接入 `NsfwImage`（4b3e310 首次引入）→ 抓取下载的新图必然「未判定」→ fail-closed 规则立即进 `ClipRect+ImageFiltered` 模糊层（`nsfw_image.dart:727/969`）→ 同帧 6 个 TextField 批量填文本 + `IntrinsicHeight` 全表单重排 → Windows 上 ImageFilterLayer 合成期间下层内容错位绘制 |

**修复**（两处）：
1. **预览去 `NsfwImage`**：封面/横幅/截图缩略图改回普通 `Image.file`（参数不变）。语义上也更对——预览自己刚下载、马上要上传的图被打码反而无法核对；上传后的展示端打码由探索库负责。
2. **拆帧**：`_applyMetadata` 的 6 个 controller 文本赋值移出 `setState`（TextField 自监听 controller），`setState` 只装标签/来源等真实 UI 状态——避免「结构重建 + 文本重排」同帧布局风暴。

**未改**：`nsfw_image.dart` 本体、添加页（那边手动选图节奏不同，未出现问题）。

### 6.3 验证

- 离线等价探针（231 期间）：`.workbuddy/tmp_probe/pub_merge_probe.dart` → `flutter_tester` **25 PASS / 0 FAIL**，含：身份锚锁定主结果、异身份五字段宁缺、名字集回退、双无名宁缺、无锚文档化旧行为。
- 进程内 analyzer 两文件 0 error（原生通道 231 阵发，恢复后补跑）。
- ⏳ **真机复验（必须）**：重新搜《缘之空》→ 自动填充 → ① 英文名应为空而非 Senren*Banka；② 表单不再错乱；③ 封面清晰无模糊层。若仍错乱，下一步用 `RepaintBoundary.toImage` 黄金画面测试直接看渲染（flutter-golden-visual-verify 流程）。

## 1. 现象与根因

用户反馈：发布功能里的元数据抓取「体验非常糟糕，很多数据没能导入发布窗口，尤其是游戏封面图、横版封面、截图」。

| 症状 | 根因 | 证据 |
|---|---|---|
| **封面 / 横幅 / 截图永远填不进来** | `_applyMetadata()` 只读 8 个文本字段，**完全没读 `cover_url` / `banner_url` / `screenshot_urls`** | `publish_game_dialog.dart`（修复前 `:1023-1060`）；而数据源确实返回这三个字段 `metadata_fetcher.dart:1075/1078/1081` |
| 文本字段也常常缺 | 只取 `list.first`，不做择优、也不做跨源补齐 | （修复前 `:1012`） |
| 抓取结果里出现空标签 | tags 只 trim 没判空，空串会进选中集 | （修复前 `:1054-1056`） |
| 不知道抓取到底成功了没 | 只有一句「元数据已填充」，无进度、无成败明细 | （修复前 `:1013`） |

**已排除的怀疑**：
- 不是数据源问题 —— MIX 整合源有完整字段优先级链，含横幅（`metadata_fetcher.dart:632-719`）；
- 不是下载能力问题 —— 统一服务 `CoverDownloadService`（`cover_download_service.dart:90/223`）已具备缓存优先 + 重试 + 扩展名识别 + 横幅宽高比校验，添加页 `game_detail_dialog.dart:1305-1330` 一直在用它回填封面/横幅/截图。

**结论：纯粹是发布窗漏接了图片字段。** 抓到了，没用。

## 2. 方案（已拍板）

1. **择优**：MIX 整合条目优先（`platform == 'MIX源'`）；否则按关键字段完整度打分（封面 +3、横幅 +2、截图 +2，其余各 +1）。
2. **字段级补齐**：以最佳结果为底，空字段从其余数据源结果取首个非空（截图跨源去重补齐至上限 6 张）。
3. **文本只填空**：已手写的原名 / 简介 / 开发商 / 发售日 / 评分 / 投票数 / 标签一律保留（2026-10-06 用户拍板）。
4. **图片覆盖式回填**：抓取的图是用户主动要的，直接替换已有选择。
5. **图片下载**：复用 `CoverDownloadService`，落到 `PathHelper.portableTmpDir/publish_meta_<ms>/`；封面 1 张 → 横幅 1 张（含 ≥1.15 宽高比校验）→ 截图并发 3、最多 6 张。
6. **反馈**：按钮显示阶段进度（检索中… → 下载封面… → 下载截图 3/6…），结束提示「已填充：封面、横幅、截图 6 张、简介…；未获取到：横幅」。

### 2.1 为什么发布窗必须自己下载

发布上传（`game_publish_service.dart:403-425`）走 multipart，只接受**本地文件路径**；而抓取结果是网络 URL。添加页那套是先写 URL 到 `game.json` 再交给后台 `ScreenshotFetchService` 队列异步下载 —— 发布窗等不起，必须同步落盘。

### 2.2 临时文件治理

每轮抓取一个独立子目录，重复抓取时清理上一轮。🔴 双重护栏才删：路径必须含本窗口自己的 `publish_meta_` 标记 **且** `PathHelper.isInsideAppStorage()` 为真（ADR-007）。窗口关闭**不清理**（避免误删正在上传的文件）—— 代价是 `dataDir/tmp` 会留一份，等用户拍板是否要加 dispose 清理。

## 3. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/widgets/game_detail/publish_game_dialog.dart` | 新增 `pickPublishBestResult` / `publishCompletenessScore` / `mergeForPublishMetadata`（**文件级 public，为可单测**）；`_fetchMetadata` 改编排（择优→补齐→填文本→下载图片→汇总提示）；`_applyMetadata` 改「只填空」并返回填充明细；新增 `_applyMetadataImages`；按钮加阶段进度；新增 `_maxTags` / `_metaImageConcurrency` / `_fetchStage` / `_lastMetaImageDir` |
| `test/widgets/publish_metadata_merge_test.dart`（新增） | 7 例：MIX 优先、完整度择优、跨源补齐、截图上限与去重、非 http 过滤、空输入不炸 |

**未改动**：`metadata_fetcher.dart`、luna SDK、`cover_download_service.dart`、添加页、pubspec。

## 4. 验证

- 进程内 analyzer：`publish_game_dialog.dart` **0 error / 0 warning / 0 info**
  （本机 `flutter analyze` 子进程通道本轮报 231，cmd.exe 管道耗尽，见 MEMORY §1）
- 单测 `test/widgets/publish_metadata_merge_test.dart` —— 待 231 恢复后补跑
- ⏳ **真机走查（必须）**：发布窗填游戏名 → 自动填充 → 确认封面/横幅/截图出现预览、进度文案正常、提交成功；再测一个冷门游戏（验证"未获取到：xx"的降级提示）

## 5. 已知取舍

- 抓取会**同步等待**图片下载（最多 8 张）。网络差时按钮会停在进度文案上几秒；失败只降级不阻断提交。
- 新标签即时进云端词表（沿用 `tags_autovalues` hook 行为，不再本地过滤）。
- 临时图片目录关闭窗口后残留，需后续决定是否清理。
