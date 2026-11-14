# 副标题 = 除主标题外的全部别名（2026-10-10）

## 1. 需求

用户实机反馈：CT 数据导入后，添加页左侧「副标题」为空；且软件的标题系统只把副标题
当作「日文原名」。

新语义（用户明确要求）：

> **副标题不再只是游戏原名，而是代指除主标题外的所有其他名称**
> 例如日文原名、中文别名、英文别名等。

**UI 要求**：游戏名称的显示要「完整」——即显示该游戏的全部名称数据。
展示范围（用户拍板）：
- **完整展示（多行、不截断）**：探索详情页（`game_detail_page` 头部别名胶囊）、
  探索库卡片（`ct_library_picker_dialog`）；
- **保持一行**：库页卡片 / BPM / 主页 / 本地游戏数据弹窗（`game_detail_dialog`）。

连接与顺序（用户拍板）：按 **日文原名 → 英文名 → 繁中名** 顺序，以 ` / ` 连接；
去重（归一化比较）、剔除与主标题相同者。

## 2. 数据来源

| 来源 | 别名字段 |
|---|---|
| CT 探索库（`GameModel`） | `originalTitle` / `englishTitle` / `traditionalChineseTitle`（`aliasTitles`） |
| 一键抓取（legacy map） | `alias_names`（新增，List）→ 回退 `original_title` |
| SDK `Game` | `aliasNames`（新增，可空；CT 源汇总三个名称字段） |

## 3. 实现

### 3.1 SDK（`lib/packages/luna_metadata_sdk/`）
- `models/game.dart`：新增可空 `List<String>? aliasNames`（constructor / fromJson /
  toJson / copyWith 全量补全；纯新增，零破坏）。
- `services/ct_service.dart`：`_collectAliasNames()` 汇总
  `originalTitle/englishTitle/traditionalChineseTitle`（去重、剔除与主标题相同者、
  保序），写入 `Game.aliasNames`；无别名时为 `null`。

### 3.2 调度层（`services/metadata_fetcher.dart`）
- `_convertToLegacyFormat`：新增 `'alias_names': game.aliasNames ?? const []`。
- `_mixFieldPriority`：新增 `'alias_names': [ct, nextmoe, vndb, kun]`
  （仅 CT 提供多别名，故列首位；其余源该键为空列表 → `pick()` 自动跳过；
  全部为空时 merged 不含该键 → 上游回退 `original_title`）。
- `_cacheVersion` **5 → 6**。

### 3.3 合成工具（`services/subtitle_composer.dart`，新增）
```dart
SubtitleComposer.fromResult(result, mainTitles: [...]) // → "日文 / 英文 / 繁中"
SubtitleComposer.compose(aliases, mainTitles: [...])
SubtitleComposer.aliasesFromResult(result)             // alias_names 优先 → original_title 回退
```
归一化口径复用 `CTService.normalizeForSearch`。

### 3.4 三条导入链路（统一走 `SubtitleComposer`）
- `JoinController.selectScrapeResult`（添加页一键抓取 / CT 弹窗导入共用）：
  删除「仅含 CJK 的 original_title」旧逻辑，改由 `SubtitleComposer.fromResult`
  汇总全部别名；`mainTitles` = 元数据标题 / 当前标题输入 / 导入原标题。
- `JoinController.importFromCtLibrary`：补传 `'alias_names': game.aliasTitles`。
- `BatchImportController`（批量导入）：同上，`mainTitles` = 元数据标题 / 导入标题 / 原标题。
- `AutoImportPipeline`（智能导入）：同上，仅在 `candidate.subtitle` 为空时填充。

> 持久化仍写 `game.json.subtitle` 单字段（纯语义扩展，**不升 format_version**，
> 零 schema 变更）。

### 3.5 UI
- `game_detail_page.dart` `_headerAlias()` → `SubtitleComposer.compose(game.aliasTitles, mainTitles: [title])`；
- `widgets/game_detail/game_detail_header.dart` `_buildAliasPill` → **去掉 maxLines:1/ellipsis**（允许换行完整展示）；
- `ct_library_picker_dialog.dart` 别名行 → 去掉 `maxLines:1`（多行完整展示）；
- `form_inputs.dart` 副标题 hint → 「副标题（全部别名，抓取后自动填充）」。
- **不改**：库页卡片 / BPM 主页 / BPM 详情 / 本地游戏数据弹窗（保持一行）。

## 4. 验证

- ✅ `flutter analyze` 改动文件 **0 新增 error / warning**。
- ✅ `test/services/subtitle_composer_test.dart` 8 例全绿（新增）；
  `test/services/ct_service_test.dart` 24 例全绿（含别名解析新断言）。
- ⏳ 未真机走查：CT 数据导入后副标题自动填入多别名、详情页/探索库卡片完整展示。

## 5. 非目标

- 不新增 `game.json` 字段 / 不升 `format_version`；
- 不改 MIX 其它字段优先级、`kSourceOrder`、探索页搜索；
- 库页/BPM/主页布局不变（保持一行）。

## 6. 需求 3（2026-10-10）：展示端改为「一个名字一个框」+ 探索库详情只读封面相册

用户口径：探索库游戏数据 UI 与库详情数据 UI 等 UI 的别名展示改为**一个名字一个框**；
探索库游戏详情也对应为封面做好相册（**仅预览**）。覆盖范围（用户拍板）：**三处统一** —
探索详情页 + 库详情弹窗 + CT 选择器。

### 6.1 新共享组件

`lib/widgets/game_detail/alias_pill.dart`（新增）：

- `AliasPill`：单个别名胶囊（浅底 + 描边 + 全圆角 `BorderRadius.circular(999)`），
  可调 `fontSize` / `padding` / `maxWidth`（超长名 `maxLines:1 + ellipsis`，不撑破布局）；
- `AliasPillWrap`：`Wrap(spacing/runSpacing)`，**一个名字一个框** + 自动换行；
  三处展示点共用本组件，只是密度档不同（详情页 12.5 / 弹窗 12 / CT 卡片 10.5）。

### 6.2 数据层：`SubtitleComposer` 列表化

`lib/services/subtitle_composer.dart`：

- 新增 `resolve(aliases, {mainTitles}) -> List<String>` —— 原 `compose` 的筛选逻辑
  （剔空 / 剔主标题 / 归一化去重，保序）抽成列表返回；`compose` 改为 `resolve(...).join(separator)`，
  **写入口径与产物逐字节不变**（4 个写入链路零影响）。
- 新增 `split(composed) -> List<String>` —— 按分隔符 `' / '` 拆回列表，供「历史单字段
  `subtitle`（game.json）已存拼接串」的展示端使用。🔴 **不可用 `RegExp(r'[/／]')` 拆**：
  英文名如 `Fate/stay night` 内含 `/` 会被误拆（探针 S3 有断言）。

### 6.3 三个展示点

| 展示点 | 改前 | 改后 |
|---|---|---|
| `game_detail_header.dart` | `alias: String`，单个胶囊内 ` / ` 串接 | `aliases: List<String>` + `AliasPillWrap`（删除 `_buildAliasPill`） |
| `game_detail_page.dart` | `_headerAlias() -> String`（compose） | `_headerAlias() -> List<String>`（`SubtitleComposer.resolve`） |
| `game_detail_dialog.dart` | `_subtitle` 单行 `Text`（`Row + Flexible + ellipsis`） | `SubtitleComposer.split(_subtitle)` → `AliasPill` 组 + 评分徽章同放 `Wrap` |
| `ct_library_picker_dialog.dart` | `aliases.join(' / ')` 单行 `Text` | `AliasPillWrap`（紧凑档 10.5px / `maxWidth 240`） |

### 6.4 探索库详情封面相册（仅预览）

- `game_detail_page.dart` `_buildGameCover()`：封面 `Stack` 内右下角新增相册按钮
  （`Icons.photo_library_outlined`，外框 -2° 倾斜 ⇒ 按钮反补 +2° 保持水平），
  Tooltip「封面相册（仅预览）」。
- `_openCoverAlbum()` → `showGeneralDialog` + `CoverPreviewOverlay`，**不传任何动作回调**
  ⇒ `_hasActions == false`，工具条只有缩放/翻页/复位（无上传/设为封面/删除）。
- 候选：竖版封面（`coverUrl`）+ 横幅封面（`bannerUrl`）+ 已加载截图（`_screenshotUrls`）。

### 6.5 验证

- 进程内分析器 6 文件 **errors=0**（`game_detail_page.dart` 5 条 / `game_detail_dialog.dart` 1 条
  warning 均为**存量**，位于未触及的截图加载与 `success` 变量处）。
- 离线 widget 探针 `.workbuddy/probe_alias_pill/`（flutter_tester 真跑）**20 PASS / 0 FAIL**：
  S1 `AliasPillWrap` 3 别名 → 3 框且无 ` / ` 拼接串；S2 `GameDetailHeader` 同上；
  S3 `split/resolve/compose` 语义（含 `Fate/stay night` 不被误拆、剔主标题去重、compose 口径不变）；
  S4 `CoverPreviewOverlay` 只读无三动作图标但保留缩放，带回调时三图标齐全。
- ⏳ 未真机走查：详情页/库详情弹窗/CT 卡片三处别名拆框观感；探索库详情封面相册按钮与只读浮层。
