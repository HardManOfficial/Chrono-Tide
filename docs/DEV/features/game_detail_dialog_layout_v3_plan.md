# 库页详情窗口 v3 改造方案（布局加宽 + 日期重排 + 站点/攻略双外跳）

> 状态：**阶段 B 已实施 · 已验证**（用户 2026-11-11 22:03 批准，按 AGENTS.md §2.2 两段式流程）
> 日期：2026-11-11　|　需求来源：用户截图（Dialog.png + 蓝框 / 黄紫框标注 + KUNGAL 站长攻略 API 群消息）
> §0–§6 是阶段 A 的只读审计与变更计划，**原样保留**便于对照；实际落地结论见 **§7 实施记录**。
> 涉及主文件：`lib/widgets/game_detail_dialog.dart`（改造前 6069 行，🔴 巨型文件，只做局部改动）

---

## 0. 需求拆解（用户原话 → 可执行项）

| # | 需求 | 落点 |
|---|---|---|
| A | 右侧信息区**横向**加大面积；**窗口高度不变**；组件间隙保持一致，只为让内部数据显示更宽裕 | `build()` 的 dialog 宽度 |
| B | 「开发日期」移到「会社」下方，「安装日期」放到「来源」下方（截图为**目标**布局） | `_buildMetaGrid` |
| C1 | 黄色框位置加「跳转站点网页」按钮（对齐探索详情页「打开原站」） | 「来源」行右侧 |
| C2 | 紫色框位置加「攻略」按钮，点击跳转该作品在 KUNGAL 的攻略网页（站长新开放的攻略 API） | 「来源」行右侧 |

### 🔴 必须先确认的一处语义差
**当前代码与截图不一致**：`_buildDateRow()`（:3372-3407）现在是
「**开发日期 + 安装日期同行并列**」（64px 标签 ×2），这是 2026-10-04
`features/game_detail_explore_metadata.md` §5 为省高度做的设计；
而截图里两个日期是**分两行**（安装日期紧跟来源、开发日期紧跟会社）。
本方案按**截图 = 目标状态**执行（拆行）。若截图其实是「改造前」，请批准时说明，我会反转。

---

## 1. 审计事实（代码 + 接口实测）

### 1.1 布局现状（`game_detail_dialog.dart`）
| 位置 | 现状 |
|---|---|
| `:1594-1604` | `Dialog(insetPadding: 24)` → `Container(width: **960**)`，`constraints: maxHeight = 屏高 * 0.90` |
| `:1634-1652` | `_buildContent()` = `Row[ _buildLeftPanel() , SizedBox(width: **32**) , Expanded(SingleChildScrollView(右栏, padding LTRB(0,28,28,28))) ]` |
| `:1897-1900` | 左栏 `Container(width: **280**)`（封面 + 启动/打开目录/备份/编辑四按钮） |
| `:2502-2528` | 右栏 = `Column[ 标题区 , 18 , 元数据卡片 , 14 , 标签行 , 14 , 简介/截图两栏 ]` |
| `:3163-3259` | `_buildMetaGrid()` 顺序：**来源 → 日期并列行 → 目录 → 占用空间 → 会社 → 启动信息 → 存储状态 → 游玩记录小框**；行间恒 `SizedBox(height: 10)` |
| `:3409-3465` | `_metaRowWithRightWidget(...)`：标签 72px + `Expanded(值)` + `rightWidget`（目录行放下拉箭头、占用空间/会社行放小图标） |
| `:2931-2993` | 简介/截图 `LayoutBuilder` 按 `constraints.maxWidth` 反推列宽（5:5 + gap 14），**本来就自适应** |

**右栏净宽** = 960 − 280 − 32 − 28 = **620**。

### 1.2 右栏为什么「只改一个数字」就够
元数据卡片、标签 `Wrap`、简介/截图 `LayoutBuilder` 都已经按可用宽度自适应（`Expanded` / `LayoutBuilder` / `Row`），
把窗口加宽后多出来的宽度会自动摊到这些信息区，**不需要改拉伸逻辑、不需要动任何一个间隙**。
（用户说的「修改右侧信息区域的拉伸」= 让右栏更宽，不是改 `Expanded` 结构。）

### 1.3 外跳基建（已存在，直接复用）
- `services/kungal_link_service.dart`：`KungalLinkService.lookup/resolve(gameId, 候选标题)` → KUNGAL 站内 id；
  带会话缓存 + 30 天磁盘缓存 + 并发 Future 合并；`detailUrlOf(id)` = `/galgame/{id}`，
  `searchUrlOf(title)` = 站内搜索兜底。`game_detail_page.dart:337-343` 已有同款「常驻入口 + 兜底」实现。
- `services/website_bookmark_service.dart:190`：`openExternal(url)`（`cmd /c start`，零依赖，
  `normalizeUrl` 只校验 http(s) + host，**无域名白名单**，kungal.com 可通行）。
  ⛔ 项目没装 `url_launcher`，不引入。
- `NextMoeService.apiKey`（SDK `lib/services/nextmoe_service.dart:61`）供开放 API 鉴权。

### 1.4 攻略 API 实测（curl，2026-11-11，非猜测）
| 探测 | 结果 |
|---|---|
| `GET https://api.nextmoe.dev/v2/catalog/walkthroughs?work_id=198&limit=20` | 200，`items=[{"id":"3970","work_id":"198",...}]`，`next_cursor=null`（该作品 1 篇攻略） |
| `GET .../v2/catalog/walkthroughs?work_id=231772&limit=3` | 200，`items[0].id = "737"` |
| `GET .../v2/catalog/walkthroughs/3970` | 200，`work_id = "198"`，`source = seiya` |
| `https://www.kungal.com/galgame/198/walkthrough/3970` | **200**（Rewrite 攻略，与群消息 URL 一致） |
| `https://www.kungal.com/galgame/231772/walkthrough/737` | **200**（证明 URL 模板通用） |
| `https://www.kungal.com/galgame/198/walkthrough` | **404**（无攻略列表页 ⇒ 必须拿到攻略 id） |
| `https://www.kungal.com/walkthrough` | **404** |
| `GET .../v2/catalog/works/198` | `claim = {site:kungal, site_work_id:"198"}`，**work.id == site_work_id** |
| `/v2/catalog/works?limit=6` 抽查 | 6 个作品 `work.id` 与 `claim.site_work_id` **全部相等**（4/10/12/23/38/41） |

**结论（关键）**：
1. 攻略网页模板 = `https://www.kungal.com/galgame/{work_id}/walkthrough/{walkthrough_id}`；
2. `KungalLinkService` 解析出的 KUNGAL 站内 id **可直接当攻略 API 的 `work_id` 用**，无需二次换算；
3. 攻略 API 匿名可调用（200，无凭据），带应用密钥更稳；
4. 文档站 `developer.nextmoe.dev/docs/v2` 列有 `GET /v2/catalog/walkthroughs`（列出攻略）与
   `GET /v2/catalog/walkthroughs/{id}`（获取一份攻略），即站长说的「攻略 API」。

---

## 2. 变更计划（阶段 B 待批准后执行）

### A. 右栏横向加宽 · 窗口高度不变
**文件**：`lib/widgets/game_detail_dialog.dart:1592-1604`

```diff
- child: Container(
-   width: 960,
+ child: Container(
+   // 目标 1120；按可用宽度反推，防高 DPI / 小逻辑分辨率溢出
+   width: (MediaQuery.of(context).size.width - 48) < 1120
+       ? (MediaQuery.of(context).size.width - 48)
+       : 1120,
    constraints: BoxConstraints(
-       maxHeight: MediaQuery.of(context).size.height * 0.90),
+       maxHeight: MediaQuery.of(context).size.height * 0.90),  // ⛔ 不动
```

- 目标宽 **960 → 1120**（`insetPadding` 左右各 24，故可用宽 = 屏宽 − 48）。
  主窗口 1280 时可用 1232 > 1120，取 1120；高 DPI 逻辑宽度 1024 时取 976，永不溢出。
- **不动**：`maxHeight`、左栏 280、栏间距 32、右栏 padding `(0,28,28,28)`、所有行间 `10` / 栏间 `14`。
- 效果：右栏净宽 **620 → 780（+160 / +25.8%）**，全部给到元数据值、标签行、简介与截图；
  竖向高度一字不改。

### B. 两个日期拆行（按截图顺序）
**文件**：`:3163-3228`（`_buildMetaGrid`）、`:3372-3407`（`_buildDateRow`，grep 确认仅 :3179 一处调用）

目标顺序：
```
来源 → 安装日期 → 目录 → 占用空间 → 会社 → 开发日期 → 启动信息 → 存储状态 → 游玩记录小框
```

改法（**零删除**，不重写 `_buildMetaGrid`）：
1. `:3374` `_buildDateRow()` 内部改为**只渲染「安装日期」单行**
   （即保留原 `devDate.isEmpty` 分支的 `_metaRowWithRightWidget(leftLabel:'安装日期', leftValue:_formattedDate, rightWidget: SizedBox.shrink())`），
   方法名与调用点 :3179 保持不变，仅更新方法注释。
   ⛔ 不删方法、不删现有分支代码以外的东西。
2. `:3218-3221` 会社行之后插入：
   ```dart
   if (_formattedReleaseDate.isNotEmpty) ...[
     const SizedBox(height: 10),
     _metaRowWithRightWidget(
       leftLabel: '开发日期',
       leftValue: _formattedReleaseDate,
       rightWidget: const SizedBox.shrink(),
     ),
   ],
   ```
3. 「开发日期」显示条件**独立于会社行**（会社行是 `_developer.isNotEmpty || _isEditing`），
   避免「会社为空但有发售日」时数据凭空消失。
4. 行间 `SizedBox(height: 10)` 全部维持 10。结果：元数据卡片比现状**多一行（约 30px）**；
   窗口高度仍不变，右栏本来就是 `SingleChildScrollView`，超高时滚动（与现状一致）。

### C1. 「站点网页」按钮（黄色框）
**位置**：`:3173-3177`「来源」行的 `rightWidget`（现为 `SizedBox.shrink()`）→ 换成 `Row[按钮1, SizedBox(8), 按钮2]`。
不新增行、不改任何垂直间隙；与「目录」行下拉箭头、「占用空间」行小图标同一视觉层级。

**新增状态/依赖**（`:1-42` import 区 + `:91-` 状态区）：
- `import '../services/kungal_link_service.dart';`
- `import '../services/website_bookmark_service.dart';`
- `int? _kungalId;`

**解析**（`:367` `_loadGameData()` 成功之后追加一次后台调用）：
```dart
void _resolveKungalLink() {
  final svc = KungalLinkService.instance;
  final cached = svc.lookup(_gameId);          // 首帧同步命中，零网络
  if (cached != null && cached > 0) { if (mounted) setState(() => _kungalId = cached); return; }
  if (svc.hasResolved(_gameId) || _kungalResolving) return;   // 单飞闸
  _kungalResolving = true;
  svc.resolve(_gameId, [_title, _subtitle, data.originalTitle]).then((id) {
    _kungalResolving = false;
    if (!mounted || id == null || id <= 0) return;
    setState(() => _kungalId = id);
  });
}
```
候选标题用 `_title`（中文主标题）+ `_subtitle`（通常是日文原名）+ `data.originalTitle`（`GameJsonData:1883` 已有，只读）。

**点击**：
```dart
final id = _kungalId;
final url = (id != null && id > 0)
    ? KungalLinkService.detailUrlOf(id)
    : KungalLinkService.searchUrlOf(_title);   // 与 game_detail_page._handleOpenKungal 同款兜底
WebsiteBookmarkService.openExternal(url);
```

### C2. 「攻略」按钮（紫色框）
**新增文件**：`lib/services/kungal_walkthrough_service.dart`（纯新增，约 80 行，零既有代码改动）

```dart
class KungalWalkthroughService {
  static const _apiBase = 'https://api.nextmoe.dev/v2';
  static const _host = KungalLinkService.host;   // 复用单一域名真值，不新增第二个常量

  /// 攻略网页直链（curl 实测 198/3970、231772/737 均 200）
  static String pageUrlOf(int workId, int walkthroughId) =>
      workId > 0 && walkthroughId > 0
          ? '$_host/galgame/$workId/walkthrough/$walkthroughId'
          : '';

  /// 按作品取第一篇攻略 id；会话缓存含负结果、并发合并、失败静默 null
  Future<int?> resolveWalkthroughId(int workId) async { ... }
  // GET /v2/catalog/walkthroughs?work_id={workId}&limit=1
  // → items[0].id（int.tryParse）；Dio connect 6s / receive 10s，
  //   headers 沿用 NextMoeService.apiKey（匿名亦可）
}
```
- ⛔ 不做「多篇攻略选择器」（当前实测每作品 1 篇），保持最小变更。
- ⛔ 不落盘缓存（攻略 id 会新增，会话缓存足够，避免脏数据锁死）。

**点击流程**（单飞闸 `_walkthroughBusy`，按钮内短暂 14px 转圈）：
1. 无 `_kungalId` → 与 C1 同款站内搜索兜底 + 提示「未定位到该作品」；
2. 有 id → `resolveWalkthroughId(id)`：
   - 命中 → `WebsiteBookmarkService.openExternal(pageUrlOf(id, wid))`；
   - 无攻略 / 请求失败 → `AppSnackBar.warning(context, '该作品暂无站内攻略')`
     并打开 `KungalLinkService.detailUrlOf(id)`（**保证点了必有反馈**）。

### C3. 按钮视觉（待用户确认，见 §5）
默认按截图画的**小方形**做：28×24 圆角 6 的图标按钮，
`Icons.open_in_new_rounded` / `Icons.menu_book_rounded`（16px，`AppColors.brandBlue`），
`Tooltip`（「打开 KUNGAL 作品页」/「查看该作品攻略」）、`MouseRegion` click 光标、
hover 底 `AppColors.placeholderCover`、边框 `AppColors.borderLight`。
两按钮并排 + 8px 间距，总宽约 64px；**不撑高行**（≤ 行高 20px 时按 24px 计，元数据卡片最多 +4px）。

---

## 3. 影响面 / 风险点

| 风险 | 说明与对策 |
|---|---|
| 🔴 高 DPI 下硬写 1120 会溢出 | 主窗口最小 1280×720，但 125%/150% 缩放下逻辑宽度可能 < 1168 ⇒ **必须 `min(1120, 屏宽−48)`**，见 §2.A |
| 元数据多一行 → 内容变高 | 窗口高度不变，右栏可滚；但简介/截图会被往下推 ⇒ 渲染探针必须整屏量尺寸，**不能只查 `takeException()`**（会漏「被压扁」） |
| 按钮挤占「来源」行 | `rightWidget` 在 `Expanded(值)` 之后，是标准 Row 写法；长来源值会 ellipsis，需探针注入长路径数据 |
| 后台解析在飞时窗口关闭 | `mounted` 判定 + 单飞标志；controller/异步赋值一律移出 `setState` 之外（MEMORY 铁律） |
| 攻略 API 依赖 `work_id == site_work_id` | 已 curl 抽查一致；若将来 NextMoe 拆 id，最坏是走「暂无攻略」兜底，**不会崩、不会写脏数据** |
| 🔴 `build()` 抛异常 = release 整页灰块 | 改动落在 `GameDetailDialog.build`，**必须把该窗口整屏渲染一次**，并加「必然存在文案」断言防假绿 |
| 231 环境问题 | `flutter analyze` / `flutter test` / `Process.run` 在工具进程树必挂 ⇒ 用进程内 analyzer 探针（只收具体文件路径）+ flutter_tester 渲染探针；构建仍须用户自己跑 |
| 🔴 工作区有 282 个未提交文件 | 收尾提交必须**显式 `git add` 本任务文件**，⛔ 禁 `-A`；`game_detail_dialog.dart` 目前**无未提交改动**，行号可靠 |

**数据 / 依赖零改动**：不改 `game.json`、不升 `format_version`、不动 `pubspec.yaml`、不新增第三方依赖。
**网络**：只新增 1 个只读 GET（攻略列表），失败静默；站点 id 解析完全复用既有缓存服务。

---

## 4. 验证方式（阶段 B 收尾）

1. **静态检查**：`.workbuddy/analyze_probe/ct_analyze_probe.dart` 传具体文件路径
   （`game_detail_dialog.dart` + 新增 `kungal_walkthrough_service.dart`），只看**新增 error**。
2. **纯 Dart 行为探针**：`pageUrlOf` 拼装、`work_id` 过滤解析、负缓存、并发合并；
   断言 `pageUrlOf(198, 3970) == 'https://www.kungal.com/galgame/198/walkthrough/3970'`。
3. **flutter_tester 渲染探针（必做）**：挂载 `GameDetailDialog` **整屏**，注入真实数据（含长目录路径），
   用例至少：
   - 有发售日 / 无发售日两种 → 断言行顺序 `来源→安装日期→目录→占用空间→会社→开发日期→启动信息`；
   - 两个按钮存在（Tooltip 文案）+ 「必然存在文案」断言（防整树塌掉假绿）；
   - 1120 宽与窄逻辑宽度（976）两档下：**0 溢出 + 没有被压扁**，元数据值/标签/简介/截图尺寸合理；
   - 编辑态不被破坏。
4. **自查改动面**：`git status --short` / `git diff --stat`，确认只动计划内文件。
5. **收尾**：追加 `DEV_LOG.md`、更新本档案状态、更新 `SESSION_HANDOFF.md`、一个 commit（显式 `git add`）。
6. ⏳ **真机走查（用户执行）**：构建后看窗口观感、两个按钮落点、无攻略作品兜底、高 DPI 下不溢出。

---

## 5. 明确不改（越界自查用）

- 窗口高度 `maxHeight`、左栏 280、栏间距 32、右栏 padding、行间 10、栏间 14/28 —— **一个间隙都不动**。
- 标题区 / 评分徽章 / 目录下拉 / 占用空间与会社右侧图标 / 启动信息徽章 / 游玩记录小框 / 标签行 /
  简介·截图 `LayoutBuilder` 逻辑 / 编辑态表单与抓取链路 / 数据落盘。
- `game_detail_page.dart`（探索详情页）、`site_game_detail_page.dart`、`game_detail_header.dart`、
  `KungalLinkService`、`WebsiteBookmarkService`、`NextMoeService`、主题系统、`main.dart`、
  所有稳定区文件、`pubspec.yaml`、`.gitignore`、构建脚本、任何数据文件。
- ⛔ 不顺手重构 6069 行巨型文件、不格式化、不重命名无关变量、不删「看着没用」的代码。

---

## 6. 待用户确认（3 点，批准后即按默认值执行）

1. **目标宽度**：建议 960 → **1120**（右栏 620→780）。想更宽可给数字，但不能超过「屏宽−48」。
2. **按钮样式**：默认 **28×24 纯图标 + Tooltip**（贴近截图画的方框）；
   若要 **图标 + 文字（站点 / 攻略）** 的小胶囊，批准时说一声（加宽后完全放得下）。
3. **无攻略 / 未定位时**：默认 **提示 + 打开 KUNGAL 作品页**（点了必有反馈）；
   若要 **按钮置灰/隐藏**，批准时说一声。

另请顺带确认 §0 的语义差：**截图是目标状态**（当前代码是两个日期同行并列）。

> 回复「批准 / 按这个改」即进入阶段 B；上面 3 点不回复则按默认值执行。

---

## 7. 实施记录（阶段 B，2026-11-11 22:03 批准）

### 7.1 用户裁决（3 点）

| 问 | 答复 | 落地 |
|---|---|---|
| 宽度 | 未指定 ⇒ 默认 **1120** | `min(1120, 屏宽−48)` |
| 按钮样式 | **28×24 纯图标 + Tooltip** | `_MetaLinkButton`（带 hover 底色的小 StatefulWidget） |
| 无攻略 / 未定位 | **改按钮置灰**（⛔ 不要「提示 + 打开作品页」兜底） | 见 §7.2，这是与阶段 A 计划**唯一的实质性偏差** |
| 截图语义 | 未反转 ⇒ **截图 = 目标状态**（两日期分两行） | 按 §2.B 执行 |

### 7.2 「置灰」对设计的连锁改动（重要）

阶段 A 的 C2 是「点击时才查攻略 id，失败给提示 + 打开作品页」。改成**置灰**后，
按钮必须在**点击之前**就知道该不该可用，因此：

1. 打开详情时，在 `_resolveKungalLink()` 拿到 KUNGAL id 后**预取攻略 id**
   （`_prefetchWalkthrough` → `KungalWalkthroughService.resolveWalkthroughId`），
   结果写进 `_walkthroughId` + `_walkthroughResolved`；
2. 三态判据：
   - **站点按钮**：`_kungalId > 0` 才可点（未定位 ⇒ 置灰，⛔ 不再走站内搜索兜底 ——
     用户选「置灰」即覆盖了阶段 A C1 的兜底设计）；
   - **攻略按钮**：站点 id 有效 + 攻略查询已出结论 + 攻略 id > 0 才可点；
     查询中 / 无攻略 / 请求失败一律置灰，Tooltip 分别说明
     「正在查询该作品攻略…」/「该作品暂无站内攻略」/「未定位到该作品，无法查看攻略」；
3. 置灰态：`onTap = null`、图标 `AppColors.border.withOpacity(0.55)`、弱边框、
   `SystemMouseCursors.basic`；**不弹任何提示、不打开任何兜底页面**；
4. 攻略服务负结果只进**会话缓存**，⛔ 不落盘（攻略会新增，落盘会把「暂无」锁死）。

### 7.3 实际改动文件

| 文件 | 改动 |
|---|---|
| `lib/widgets/game_detail_dialog.dart` | `build()` 宽度 `min(1120, 屏宽−48)`；`_buildMetaGrid` 来源行挂双按钮 + 会社行后插「开发日期」；`_buildDateRow` 收敛为「安装日期」单行；新增 `_buildExternalLinkButtons` / 两个 `_handleOpen*` / `_resolveKungalLink` / `_prefetchWalkthrough` / `_applyDebugSeed`；新增顶层 `_MetaLinkButton`；3 个 `@visibleForTesting` 注入参数 |
| `lib/services/kungal_walkthrough_service.dart` | **纯新增** 133 行：`pageUrlOf` / `parseFirstId` / 会话缓存（含负结果）/ 并发 Future 合并 / 失败静默；零落盘、零新依赖 |
| `dev_probe/game_detail_dialog_v3_probe.dart` | **纯新增**：服务逻辑 + `GameDetailDialog` 整屏渲染综合探针 |
| 本档案 / `DEV_LOG.md` / `SESSION_HANDOFF.md` | 状态、实施记录、交接 |

**未动**：窗口高度 `maxHeight`、左栏 280、栏间距 32、右栏 padding、行间 10 / 栏间 14、
探索详情页 / 站外详情页 / 主题 / `main.dart` / `game.json` / `format_version=4` / `pubspec.yaml`。

### 7.4 为什么给生产 widget 加了 `debugSeedData`

`GameDataFormat.readGameJson` 走异步 `dart:io`，在 flutter_tester 的 `FakeAsync` 下
**永久挂起**，详情窗口会永远停在 loading 圈 ⇒「整屏渲染」探针假绿（MEMORY §4 灰块事故同源）。
故照 `PatchVaultDialog.debugSkipLoad` 的既有惯例，加一条**零 IO 的测试注入路径**：
`debugSeedData` 同步填充展示字段，`debugKungalId` / `debugWalkthroughId` 覆盖按钮三态。
生产路径不传这三个参数，`_loadGameData()` 原逻辑一行未改（只在开头多了 4 行分支）。

### 7.5 验证结果（2026-11-11 22:16）

- 进程内 analyzer（3 个文件）：**0 error**；仅 1 条既有存量 warning
  （`game_detail_dialog.dart:5451` 的 `success` 未使用，非本次改动）。
- `dev_probe/game_detail_dialog_v3_probe.dart`（gen_kernel + flutter_tester）：
  **56 PASS / 0 FAIL**：
  - 服务逻辑 16 条（URL 模板与 curl 实测网页一致、响应解析、负缓存、并发合并）；
  - 三档逻辑宽度 **1280×720 / 1600×900 / 1024×768** 整屏渲染：
    「必然存在文案」+ 行顺序 `来源→安装日期→目录→占用空间→会社→开发日期→启动信息`
    + 0 异常 / 0 溢出；
  - 窗口外壳实测 `1120×648` / `1120×810` / `976×691.2`（高度恒 = 屏高×0.90，**未变**）；
    右栏净宽 `780 / 780 / 636`，未被压扁；
  - 无发售日 ⇒ 开发日期行消失、安装日期仍在；
  - 按钮三态 Tooltip 与置灰图标数 `2 / 1 / 0` 全部命中；
  - 编辑态（触发左栏编辑按钮）0 异常、文案仍在。
- 编译期曾暴露并修正 3 个探针自身问题（Type 对象不能调静态成员、`WidgetController`
  抽象类、本版 `runTest` 需 `invariantTester` 位置参数）+ 1 个高度断言判据过宽，
  **均非产品代码缺陷**。

### 7.6 ⏳ 真机待走查（用户执行）

231 只在工具进程树侧复现，构建仍须用户自己跑。构建后请确认：
① 窗口观感与右栏宽裕度；② 两个按钮落点、hover 与 Tooltip；
③ 有攻略作品 → 直达攻略页；④ 无攻略 / 未定位作品 → 按钮确实置灰且点不动；
⑤ 高 DPI（125% / 150%）下窗口不溢出；⑥ 多行元数据时右栏可滚、简介与截图不被压扁。

> 提交范围说明：`DEV_LOG.md` / `SESSION_HANDOFF.md` 在工作树里含**其它任务累积的
> 大量未提交改动**（1863 / 341 行 diff），为避免一把梭，本任务 commit 只显式纳入
> 代码、新服务、探针与本档案；两份累积文档的本次条目已写入工作树，**未纳入本任务提交**。
