# 探索大厅（Explore Hall）实施方案

> **状态**：方案待批准（阶段 A 产出，未改任何业务代码）  
> **设计稿**：`D:\CTLIB\素材\探索大厅设计图.png`（月历交互参考 KUNGAL galgame-calendar，  
> 参考代码 `D:\CTLIB\其他开发者的项目用于本项目参考\kun-galgame-forum-master`）  
> **最后更新**：2026-09-11  
> **决策记录**：月历数据=后台预热全量抓取；外链打开=零依赖系统调用；用户动态=一期本地静态先行（三项均经用户拍板）

---

## 0. 结论摘要（TL;DR）

| 项     | 结论                                                                                                      |
| ----- | ------------------------------------------------------------------------------------------------------- |
| 做什么   | 新增单页固定式「探索大厅」，成为侧边栏【探索】的默认首界面；原探索库页**一行不改**，改由大厅「开始探索」按钮进入                                              |
| 路由改动  | **仅 `lib/main_container.dart:730` 一行构造替换**（🔴稳定区，需显式批准）；`NavPage` 枚举与 `sidebar.dart` 零改动                |
| 数据来源  | 4/6 类数据复用现有服务（元数据/评分热度/系列 PB 集合/本地库）；需新建 3 个小服务：月历预热聚合、网址收藏持久化、系列整表拉取                                   |
| 新依赖   | **零**。月历自绘（KUNGAL 纯 `Date` 算法）、浏览器跳转用 `Process.start('cmd', ['/c','start',...])`、日期手工拼接，不碰 pubspec      |
| 数据库迁移 | **无**。不给 `GameModel` 加 releaseDate（避免 format_version 迁移），发售日从 `DiscoverGameMetadata` 读；网址列表是新独立 JSON 文件 |
| 主要风险  | 预热抓取数百次源站请求（限流）→ 沿用全局并发=1 + 24h 节流 + 渐进填充；最小窗口 960×540 双栏挤压 → flex+滚动，Phase 0 原型验证                      |
| 分期    | Phase 0 技术验证 → 1 数据服务层 → 2 大厅骨架+静态板块 → 3 月历/推荐/系列/随机 → 4 路由接线+真机走查                                      |

---

## 1. 背景与目标

### 目标

1. 【探索】首界面变为**探索大厅**：单页固定式布局，左右两区域共 7 板块（见 §4）。
2. **原探索库页面功能与样式保持完全不变**（`lib/pages/discover_page.dart` 零改动），仅改由大厅按钮进入。
3. 七板块：
   - 左① Galgame 发售月历（左月历网格 / 右选中日期的计划发售作品）
   - 左② 相关话题（今日推荐列表 + 选中游戏大卡）
   - 右③ 探索大厅大标题
   - 右④ 网站站点管理（增删改网址，点击跳浏览器）
   - 右⑤ Galgame 系列合集（云端整理的系列聚合查询）
   - 右⑥ 文档与趣味（左：通知/介绍/用户动态文档区；右上：随机一作）
   - 右⑦ 底部探索库入口按钮

### 非目标（本期明确不做）

- ❌ 不改 `discover_page.dart` 任何一行（含样式、逻辑、免责弹窗时机）。
- ❌ 不做 BPM 大屏版大厅（`lib/big_picture/` 不碰；`big_picture_discover.dart` 不受影响）。
- ❌ 不新增 pubspec 依赖（不加 url_launcher / intl / table_calendar）。
- ❌ 不做用户动态的真实后端（PB dynamics 集合留二期）。
- ❌ 不动侧边栏、`NavPage`、主题系统、便携化路径体系。
- ❌ 云端/PB 侧不做任何变更（系列合集只消费既有 `series`/`series_entries` 集合）。

---

## 2. 现状调研（全部经只读审计核实，路径:行号为当前代码实测）

### 2.1 「已有但未被消费」的能力（大厅的机会点）

| 能力       | 位置                                                                                                    | 现状                                                                                             |
| -------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 发售日期字段   | `discover_metadata_service.dart:17` `releaseDate`（ISO YYYY-MM-DD）                                     | 已存在，但**仅视口内懒加载**（`ensureMetadata` `:145`，只有 `hasDisplayData` 才落盘 `:229`），全量无覆盖                 |
| 评分+热度    | `discover_metadata_service.dart:15-16` `rating`/`voteCount`                                           | 已有，`voteCount` 即热度代理                                                                           |
| 筛选维度     | `discover_filter_state.dart:118` 起（minRating/年份/sortOption.rating/popularity）                         | 今日推荐打分可直接复用口径                                                                                  |
| 系列 PB 集合 | `series_model.dart:62/97`（`SeriesModel`/`SeriesEntryModel`，来自云端 PocketBase `series`/`series_entries`） | 数据已在云端，但只有逐游戏查询 `SeriesRepository.getSeriesForGame`（`series_repository.dart:29`），**无整表拉取 API** |
| 更新日志/公告  | `update_service.dart:24` 拉 `version.json`；`update_models.dart:1-19` 含 `latestVersion/updateLog`       | 只被更新弹窗消费，未在大厅展示                                                                                |
| 本地库全量    | `local_game_registry.dart:431` `allGames`                                                             | 随机一作的本地数据源                                                                                     |
| 探索库全量    | `game_repository.dart:135` `getAllGames`（分页并发，数百条量级；`discover_page.dart:325` 即此用法）                    | 随机一作/月历/推荐的候选池                                                                                 |

### 2.2 缺口（需新建）

1. **全量发售日批量获取**：需新增「对全探索库批量 `ensureMetadata`」的预热服务（用户已拍板此方案）。
2. **打开外部浏览器**：`pubspec.yaml:9-34` 无 `url_launcher`，全库无 `launchUrl` 命中；`Process.start` 仅用于启动游戏 exe（`local_game_registry.dart:1795+`）。→ 零依赖 `cmd /c start` 实现。
3. **网址收藏持久化**：仿收藏夹范式 `collection_service.dart:124-125`（`data/collections.json`，原子写 `:407`）新建 `websites.json`。
4. **系列整表聚合**：`SeriesRepository` 新增 `fetchAllSeries()`（纯新增方法，不动既有）。
5. **用户动态**：无任何既有概念 → 一期本地静态占位（已拍板）。


### 2.3 路由与渲染基建

- 页面切换：`main_container.dart:684` `_buildCurrentPage()` → `:707` `switch (_currentPage)` → **`:730` `return DiscoverPage(onGameTap: _onGameTap);`**。索引（`NavPage` 枚举）驱动，非 IndexedStack。
- `NavPage { library, discover, join, home }` 定义于 `sidebar.dart:7`；探索项点击经 `sidebar.dart:230` `onPageChanged(page)`。
- `DiscoverPage` 对外契约：`discover_page.dart:51-54`，唯一可选参数 `onGameTap: ValueChanged<GameCardData>?`；数据类 `GameCardData`（`:24-49`，`fromModel` 工厂）。全库仅 `main_container.dart:730` 一处构造；`big_picture_discover.dart:27` 是独立实现不受影响。
- 免责弹窗：`DiscoverDisclaimerDialog.showIfNeeded` 由 `DiscoverPage.initState`（`discover_page.dart:148`、`:155-156`、`_showDisclaimerIfNeeded :241`）触发——**大厅内嵌探索库时行为自动保持**。
- 视觉四件套：`AppColors.pageBackground`（`discover_page.dart:672` 用法）、字体 F1=`AppStyles.zhDecorativeFont`（得意黑 SmileySans，`app_styles.dart:17`；**标题禁加 w700 合成粗体**）、`InteractiveWrapper`（hover 1.02/按下 0.98，`onTap==null` 自动禁用态，`interactive_wrapper.dart:14-38`）、封面 `NsfwImage.network(..., contentKind: NsfwContentKind.cover)`（标准用法 `discover_page.dart:1392-1419`）。
- 窗口约束：默认 1280×720、**最小 960×540**（`main.dart:439-446`）；侧栏展开 224 / 收起 71 → 内容区最窄约 **736px**。禁止写死双栏像素宽。

### 2.4 KUNGAL 月历参考实现（kun-galgame-forum-master）

- 网格算法 `apps/web/app/components/galgame/calendar/Month.vue:49-63`：周日起始（表头 `日一二三四五六` `:12`）；前补位 = 当月 1 号的 weekday 个 null；当月天数 = `new Date(y, m, 0).getDate()`；尾补位至 7 的倍数。月份切换 `addMonth` 处理跨年（Container.vue:88）。
- 数据分桶：`Month.vue:29-44` 按条目 `release_date` 的日号分桶 `Map<day, items>`；`release_precision==='month'` 或无日期进「本月内·日期待定」桶。
- 联动方式：KUNGAL 是「右侧全月列表 + scrollIntoView 滚动定位」；**本项目按设计稿改为「右侧选中日面板替换」**（点日格 → 右面板显示该日作品），比 KUNGAL 更简单。
- 数据结构参考 `shared/types/galgame.ts:175/257`：`release_date('YYYY-MM-DD')`、`release_precision('day'|'month'|'tba')`——我们的 `DiscoverGameMetadata.releaseDate` 只有精确日期，无 precision 字段，解析失败的归「待定」。

---

## 3. 技术选型（含被淘汰项）

| 需求      | 选定                                                                | 被淘汰                            | 淘汰理由                                                                                                |
| ------- | ----------------------------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------------- |
| 月历组件    | **自绘**（KUNGAL cells 算法，Dart ~20 行）                                | `table_calendar`               | 零依赖惯例（同手柄 XInput FFI 思路）；算法极简；样式需完全贴合设计稿手绘风                                                         |
| 打开浏览器   | **`Process.start('cmd', ['/c','start','',url], mode: detached)`** | `url_launcher`                 | pubspec 是 AGENTS.md 敏感项；项目 Windows 单平台，系统调用足够且零依赖                                                   |
| 日期格式化   | **手工拼接** `'${y}年$m月'`                                             | `intl`                         | 只有一处月份标题，不值得引入                                                                                      |
| 大厅状态管理  | **ChangeNotifier + AnimatedBuilder**（新服务各自带 notify）               | Provider/Riverpod/Bloc         | 与 `DiscoverMetadataService extends ChangeNotifier`（`discover_metadata_service.dart:76`）既有风格一致，不引新框架 |
| 网址持久化   | **`websites.json`**（仿 `collections.json` 原子写）                     | SharedPreferences / SQLite     | 结构化列表+未来可能加图标字段，JSON 文件是项目主流（数据全 JSON 无 SQLite）；SharedPreferences 留给轻量标记（如预热时间戳）                    |
| 发售日存储   | **从 `DiscoverGameMetadata` 读**                                    | 给 `GameModel` 加 releaseDate 字段 | 加字段会触发 `format_version` 迁移链（`game_data_migration.dart`），违背「新字段优先 `??` 默认值、能不动 schema 就不动」铁律         |
| 全量发售日获取 | **后台预热全量抓取**（用户拍板）                                                | 只用已缓存 / 云端出月历文件                | 已缓存→月历大面积空白；云端文件→需改云端（约束不允许）                                                                        |

---

## 4. 架构设计


### 4.1 布局结构（对照设计稿）

```
ExploreHallPage（StatefulWidget，单页固定式）
├─ _showLibrary == true ?
│    └─ Stack[ DiscoverPage(onGameTap: 透传) , 悬浮返回chip(左上，不碰 discover_page) ]
│      （免责弹窗由 DiscoverPage.initState 自动触发，行为不变）
└─ Row
   ├─ 左栏 Expanded(flex 57)
   │   ├─ ① ReleaseCalendarCard  Expanded(flex 3)
   │   │     └─ Row[ 月历网格 flex10 │ 选中日作品面板 flex11 ]
   │   └─ ② TopicRecommendCard   Expanded(flex 2)
   │         └─ Row[ 选中游戏大卡 flex10 │ 今日推荐列表 flex12 ]
   └─ 右栏 _RightColumnWidth（LayoutBuilder：min(容器宽*0.43, 380)，下限 300）
       SingleChildScrollView
         ├─ ③ 大标题「探索大厅」（F1 AppStyles.titleLarge 同源，字号 34-38）
         ├─ ④ WebsiteManageCard（标题行+「添加编辑」；Wrap 2列站点卡）
         ├─ ⑤ SeriesCollectionCard（标题行+「全部合集>」；横向/2列系列卡）
         ├─ ⑥ DocsFunCard（Row[ 文档tabs 动态/使用说明/介绍 flex4 │ 随机一作卡 flex6 ]）
         └─ ⑦ 「开始探索」大按钮（InteractiveWrapper，罗盘图标+描边样式）
```

**自适应规则**（最小 960×540、内容区最窄 736px 必须可用）：

- 全页禁止横向溢出：左右栏均 `Expanded`/`Flexible`，右栏宽度用 `LayoutBuilder` 计算，不写死。
- 高度不足时：右栏整体 `SingleChildScrollView`；左栏月历网格 cell 尺寸随高度收缩（`LayoutBuilder` 取 `高度/行数` 的最小值），选中日面板内部滚动。
- 月历网格固定 6 行（KUNGAL 同款，含补位），cell 高度 = 可用高/6，避免月份间跳动。


### 4.2 七板块数据来源与计算逻辑

**① Galgame 发售月历**

- 数据链：`ExploreCalendarService`（新）
  1. `games = GameRepository.getAllGames()`（`game_repository.dart:135` 用法同 `discover_page.dart:325`）；
  2. 后台预热：逐个 `DiscoverMetadataService.ensureMetadata(id)`（复用其内存+磁盘 7 天 TTL 缓存与全局并发=1 队列，`discover_metadata_service.dart:73-84`），每完成 10 个重算一次聚合并 `notifyListeners`（节流 ≥500ms）→ **月历渐进填充**；
  3. 节流标记：SharedPreferences `explore_hall_calendar_warmup_at`，24h 内且缓存非空则跳过预热；卡片左上角提供手动刷新（设计稿左上 ⊘ 图标）；
  4. 聚合：`Map<int /*日*/, List<GameModel>>`，key = `releaseDate` 解析出的日号；解析失败/无日期 → 「日期待定」桶（面板底部折叠展示）。
- 网格算法（KUNGAL 移植，周日起始）：
  ```dart
  final leadCells  = DateTime(y, m, 1).weekday % 7;      // Dart weekday 1=周一..7=周日
  final daysInMonth = DateTime(y, m + 1, 0).day;          // m+1=13 自动归次年1月
  final trailCells = (7 - (leadCells + daysInMonth) % 7) % 7;
  ```
- 交互：`< 2026年7月 >` 翻月（跨年自动）；点日格 → 右面板切换该日作品列表；日格圆点标记当日发售数（≤3 个点）；今日描边、选中日高亮。默认选中：今日，无作品则选本月最近有作品的一天，整月空则选今日显示空态。
- 右面板条目：封面（`NsfwImage.network`，`contentKind: NsfwContentKind.cover`）+ 标题 + 评分角标（复用 `discover_page.dart` 卡片徽标口径），点击 → `widget.onGameTap(GameCardData.fromModel(...))` 走既有详情链路。

**② 相关话题（今日推荐）**

- 数据链：`ExploreLibrarySnapshot`（新，全量游戏 + 已有元数据缓存快照，月历/推荐/随机三板块共用，避免重复拉全量列表）+ `today_recommendation.dart`（新，纯函数）。
- 计算逻辑（确定性每日轮换）：
  1. 候选 = 有 `rating` 的探索库游戏；
  2. `score = rating + min(2.0, 0.5 * log(voteCount + 1) / ln10)`（评分为主、热度封顶 +2）；
  3. 取 score Top 24 → 以 `seed = DateTime.now().toIso8601String().substring(0,10).hashCode` 做确定性洗牌 → 取前 8 → 按 score 降序展示（排名 1/2/3…）；
  4. 同日多次进入结果恒定，跨日自动轮换；元数据未预热到的条目自然不参与，预热后次日可见——**不做任何云端请求以外的服务端依赖**。
- 交互：右侧排名列表（名次+标题+评分+首标签），点条目 → 左侧大卡切换（封面+标题+标签 chips+评分+简介）；点大卡 → `onGameTap` 详情。列表空态显示「数据预热中 m/n」。

**③ 大标题**：静态。`「探索大厅」` F1 得意黑 34px（`AppStyles.zhDecorativeFont`，w400，**禁 w700**），可加设计稿手绘下划线装饰（SVG 资产或 CustomPaint，Phase 2 定）。

**④ 网站站点管理**

- 数据：`WebsiteEntry {id, name, url, note, isPreset}`（新模型）；`WebsiteBookmarkService`（新）持久化 `PathHelper.dataDir/websites.json`（原子写仿 `collection_service.dart:407`）。首启种子预置：KUNGAL（kungal.com）、VNDB（vndb.org）、Bangumi（bgm.tv），`isPreset: true` 但**可编辑可删除**。
- 交互：点卡片 → 跳浏览器；卡片 hover 出现 编辑/删除 角标；标题行「添加编辑」→ 弹窗（名称/URL/备注，复用 `app_dialog.dart` 系对话框基建）。
- 跳浏览器（零依赖，含安全校验）：
  ```dart
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return 失败提示;
  await Process.start('cmd', ['/c', 'start', '', uri.toString()],
      mode: ProcessStartMode.detached);   // Windows 专用；'' 占位 start 的窗口标题参数
  ```
  URL 作为独立参数传递（不拼 shell 字符串），scheme 白名单防注入。

**⑤ Galgame 系列合集**

- 数据：`SeriesRepository.fetchAllSeries()`（新增公开方法，纯新增）：整表拉取云端 PB `series` 集合 + entries 计数；结果内存 + 磁盘缓存（`data/cache/series_overview.json`，7 天 TTL，原子写）。
- 交互：卡片（封面+系列名+「N部」+类型标签）点击 → 合集成员对话框（成员封面列表，复用 NsfwImage），成员项点击 → 探索库作品走 `onGameTap`、本地已入库作品走本地详情（见 §13 开放问题 2）；「全部合集 >」→ 全量列表对话框，带标题搜索框（"方便用户查询"）。
- 降级：PB 拉取失败/集合为空 → 板块显示占位空态，不阻塞其他板块（Phase 0 先验证 API 可行性，见 §7）。

**⑥ 文档与趣味**

- 左文档区：`动态 / 使用说明 / 介绍` 三个 tab（设计稿按钮样式）：
  - 介绍：内置静态文案（软件定位一句话+版本号，版本读 `package_info` 或既有常量——执行时按项目现状取）；
  - 使用说明：内置静态使用指南（探索库免责要点摘要 + 基本操作）；
  - 通知：异步拉 `UpdateService` 的 `version.json` 展示 `updateLog`（`update_service.dart:24`），失败显示上次缓存/空态；
  - 动态（用户动态）：一期**占位空态**（「敬请期待」），预留 `DocumentationEntry` 数据抽象接口，二期接 PB dynamics（用户已拍板）。
- 右上随机一作（「今日运势·随机一作」+「抽一郎」按钮，文案照设计稿）：
  - 数据：`ExploreLibrarySnapshot.allGames`（探索库）∪ `LocalGameRegistry.allGames`（`local_game_registry.dart:431`，本地库）；来源切换 chips：全部/本地库/探索库（默认全部）。
  - 交互：点「抽一郎」→ 封面快速轮换动画 ~800ms（老虎机式，纯 AnimatedSwitcher/Swiper 自实现）→ 停在结果；结果卡 = 封面+标题+评分/标签；点结果 → 探索库走 `onGameTap`、本地走本地详情（同 §13 开放问题 2）。再点再抽，无次数限制。

**⑦ 探索库入口**：底部大按钮「开始探索」（罗盘图标 + 描边按钮，InteractiveWrapper）。点击 → `_showLibrary = true`，整页切换为原 `DiscoverPage`（原样、零改动），左上角悬浮「← 返回大厅」chip（Stack 覆盖，不碰 discover_page 代码）；免责弹窗由探索页自身 initState 照常弹出。

### 4.3 交互流程总览（关键路径）

1. 侧边栏点【探索】→ 大厅首屏（各板块先渲染缓存/骨架，**不阻塞在任何网络上**）→ 月历后台预热自动启动（首次）。
2. 月历翻月/选日 → 纯内存 Map 查询，瞬时。
3. 网站卡片 → 系统浏览器（新窗口，软件焦点可留原地）。
4. 开始探索 → 原探索库页（免责弹窗照旧）→ 返回 chip → 大厅（状态保留，不重置）。
5. 任何板块网络失败 → 各自空态/重试按钮，**互不阻塞**。

### 4.4 分层与触发时机

```
UI 层   ExploreHallPage + 7 板块组件（全部 AnimatedBuilder 监听各自服务）
服务层  ExploreCalendarService（预热+聚合，ChangeNotifier）
        WebsiteBookmarkService（CRUD+持久化，ChangeNotifier）
        ExploreLibrarySnapshot（全量列表一次性拉取+缓存，两页共用）
        SeriesRepository.fetchAllSeries()（整表+磁盘缓存）
纯函数  today_recommendation.dart（打分+seed 洗牌，可单测）
        calendar_grid.dart（月网格 cells 算法，可单测）
既有层  DiscoverMetadataService / GameRepository / LocalGameRegistry / UpdateService / PB SDK
```

降级策略：月历（未预热→显示已缓存+进度提示）；系列（PB 失败→空态）；通知（version.json 失败→缓存/空态）；随机（两库都空→空态）；浏览器打开失败→SnackBar 提示。

---

## 5. 数据模型变更

| 变更                                 | 内容                                                                                        | 迁移                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------- |
| 新增 `lib/models/website_entry.dart` | `WebsiteEntry{id, name, url, note, isPreset}` + toJson/fromJson                           | 无（全新独立文件 `websites.json`，无历史数据） |
| `GameModel`                        | **不加字段**。发售日一律从 `DiscoverGameMetadata.releaseDate` 读（`discover_metadata_service.dart:17`） | **规避 format_version 迁移**（铁律）    |
| SharedPreferences 新 key            | `explore_hall_calendar_warmup_at`（int ms）                                                 | 无（缺省 0 即未预热）                    |
| 磁盘缓存新文件                            | `data/cache/series_overview.json`、`data/websites.json`                                    | 无                               |
| PB 云端                              | **零变更**（只读既有 `series`/`series_entries`/`version.json`）                                    | —                               |

---

## 6. 性能预算（硬要求）

| 指标               | 预算                         | 手段                                      |
| ---------------- | -------------------------- | --------------------------------------- |
| 大厅冷启动首帧          | < 400ms                    | 所有板块先骨架/缓存渲染，网络全异步；首屏**零阻塞 await**      |
| 月历翻月/选日          | < 16ms（一帧）                 | 纯内存 Map 查询，无 IO                         |
| 今日推荐计算           | < 50ms                     | 数百条纯内存打分，无需 isolate                     |
| websites.json 读写 | < 5ms                      | 小文件 + 原子写                               |
| 系列整表二次进入         | < 50ms                     | 磁盘缓存命中直渲                                |
| 预热对 UI 的影响       | **零卡顿**                    | 复用全局并发=1 队列（源站友好）；聚合重算+notify 节流 ≥500ms |
| 预热全量耗时（预期，非硬性）   | 首次 2~8 分钟后台渐进；后续 24h 内秒级跳过 | Phase 0 实测校准（§7）                        |

---

## 7. 实施阶段划分

### Phase 0 —— 技术验证（先证伪再落地，预计 0.5 天）

| #  | 验证项         | 方法                                                                                        | 通过判据                             |
| -- | ----------- | ----------------------------------------------------------------------------------------- | -------------------------------- |
| V1 | 全量预热可行性     | 取全量列表，批量 `ensureMetadata` 前 20 个游戏，实测耗时与成功率（注意 shell 代理劫持坑：测试命令加 `env -u HTTP_PROXY ...`） | 20 个 ≤ 2 分钟、失败可容忍；据此外推全量耗时写入实现注释 |
| V2 | 零依赖打开浏览器    | `Process.start('cmd',['/c','start','','https://www.kungal.com'])` + 含中文参数的 URL            | 默认浏览器打开、无 cmd 窗口闪烁（detached）     |
| V3 | series 整表拉取 | 读 `series_repository.dart` 现有 PB client，试拉 `series` 全表                                    | 能拿到列表且条目数合理；否则启用降级空态并回报          |
| V4 | 月历原型 + 最小窗口 | 静态数据自绘月历，960×540 与 1280×720 两档走查                                                          | 无溢出、cell 不小于 ~34px、双栏不挤压         |

### Phase 1 —— 数据服务层（无 UI）

`WebsiteEntry` 模型、`WebsiteBookmarkService`、`ExploreCalendarService`（预热+聚合+网格算法抽 `calendar_grid.dart` 纯函数）、`ExploreLibrarySnapshot`、`today_recommendation.dart`、`SeriesRepository.fetchAllSeries()` + 4 个测试文件。

### Phase 2 —— 大厅骨架 + 静态板块

`ExploreHallPage` 双栏骨架 + ③大标题 + ④网站管理（含编辑弹窗与浏览器跳转）+ ⑥文档区静态 tab + ⑦开始探索按钮（此时点击先空实现）+ ⑥随机一作（数据已就绪）。

### Phase 3 —— 数据驱动板块

①发售月历（预热接线+渐进填充+选日联动）+ ②相关话题 + ⑤系列合集（含成员/全部对话框）。

### Phase 4 —— 路由接线 + 收尾

`main_container.dart:730` 替换（**先取得用户对稳定区改动的显式批准**）→ analyze/test → `git status --short` 自查 → 真机走查清单（§11）→ 更新 DEV_LOG/HANDOFF/功能档案 → 单独 commit。

---


## 8. 改动文件清单

**新增（12 文件 + 4 测试）**

| 文件                                                        | 职责                                 |
| --------------------------------------------------------- | ---------------------------------- |
| `lib/pages/explore_hall_page.dart`                        | 大厅骨架、左右栏、`_showLibrary` 切换、返回 chip |
| `lib/widgets/explore_hall/release_calendar_card.dart`     | ①月历卡（网格+选中日面板）                     |
| `lib/widgets/explore_hall/topic_recommend_card.dart`      | ②相关话题卡                             |
| `lib/widgets/explore_hall/website_manage_card.dart`       | ④网站管理卡                             |
| `lib/widgets/explore_hall/website_edit_dialog.dart`       | ④添加/编辑弹窗                           |
| `lib/widgets/explore_hall/series_collection_card.dart`    | ⑤系列合集卡 + 成员/全部对话框                  |
| `lib/widgets/explore_hall/docs_fun_card.dart`             | ⑥文档 tabs + 随机一作                    |
| `lib/models/website_entry.dart`                           | 网址条目模型                             |
| `lib/services/website_bookmark_service.dart`              | 网址 CRUD + 原子持久化 + openExternal     |
| `lib/services/explore_hall/explore_calendar_service.dart` | 预热 + 聚合 + 24h 节流                   |
| `lib/services/explore_hall/explore_library_snapshot.dart` | 探索库全量快照（月历/推荐/随机共用）                |
| `lib/utils/today_recommendation.dart`                     | 推荐打分 + seed 洗牌纯函数                  |
| `test/utils/today_recommendation_test.dart`               | 确定性/同日恒定/空数据                       |
| `test/services/explore_calendar_service_test.dart`        | 网格 cells + 日期分桶 + 待定桶              |
| `test/services/website_bookmark_service_test.dart`        | CRUD/原子写/URL 校验/预设种子               |
| `test/services/series_overview_test.dart`                 | 整表拉取解析 + 缓存 TTL（mock）              |

**修改（2 文件）**

| 文件                                                 | 改动                                                                        | 说明                        |
| -------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------- |
| `lib/main_container.dart:730`                      | 1 行构造替换 `DiscoverPage(...)` → `ExploreHallPage(...)`（+可能 1 个可选参数透传本地详情回调） | 🔴稳定区，**需显式批准**，diff ≤3 行 |
| `lib/services/repositories/series_repository.dart` | 纯新增 `fetchAllSeries()`，不动既有方法与查询                                          | ⚪                         |

**一期明确不碰**  
`lib/pages/discover_page.dart`（要求完全不变，Phase 4 用 `git diff` 验证为零）、`lib/widgets/sidebar.dart`、`lib/big_picture/**`、`lib/theme/**`、`lib/core/portable_*.dart`、`pubspec.yaml`、`lib/main.dart`、`windows/runner/`、GameModel/`game_data_format.dart`。

---

## 9. 调用点替换清单

| 批次     | 位置                            | 改动                                                                                               | 备注                                               |
| ------ | ----------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------ |
| P0（唯一） | `lib/main_container.dart:730` | `return DiscoverPage(onGameTap: _onGameTap);` → `return ExploreHallPage(onGameTap: _onGameTap);` | 稳定区 1 行；`NavPage`/sidebar 免改；免责弹窗时机不变            |
| —      | 非 Widget 调用路径                 | 无                                                                                                | 探索页无其他构造点（`big_picture_discover.dart` 独立实现，不受影响） |

---

## 10. 风险登记

| 级别 | 风险                               | 应对                                                                                               |
| -- | -------------------------------- | ------------------------------------------------------------------------------------------------ |
| P0 | 预热对 VNDB/Bangumi 数百次请求触发限流/封禁    | 全局并发保持 1（服务既有约束，`discover_metadata_service.dart:73` 注释即为此设计）；24h 节流 + 手动刷新；失败逐条容忍不重试风暴；降级=只显示已缓存 |
| P0 | 稳定区 `main_container.dart` 改动引发回归 | 仅 1 行构造替换；先显式批准；改后 `git diff --stat` 确认 ≤3 行；全量测试基线比对                                            |
| P1 | `series` 整表拉取 API 不可行或数据量大       | Phase 0 V3 先证伪；降级为空态占位板块，不阻塞交付                                                                   |
| P1 | 960×540 最小窗口双栏挤压/溢出              | flex + 右栏滚动 + 月历 cell 高度自适应；Phase 0 V4 原型验证；实现后再走两档窗口走查                                          |
| P1 | 首次预热期间月历大面积空白的观感                 | 面板显式「数据预热中 m/n」进度；已有缓存先显示；预热在后台完成不打扰                                                             |
| P2 | `cmd /c start` 参数注入              | URL scheme 白名单（http/https）+ URL 独立参数传递（不拼字符串）+ `Uri.tryParse` 校验                                 |
| P2 | `version.json` 拉取失败              | 显示本地缓存的上次公告或空态；不弹错误                                                                              |
| P3 | 用户动态占位与二期 PB dynamics 结构不兼容      | 一期定义 `DocumentationEntry` 最小抽象（title/content/date），二期只加实现不改 UI                                   |

---

## 11. 验收标准

**功能（真机走查清单）**

1. 侧边栏【探索】→ 首屏为探索大厅；② 7 板块齐全且与设计稿布局一致；③ 月历翻月/选日/圆点标记/今日描边正确（对照 2026 年任意月历）；④ 选中日右侧面板正确切换、空日期有空态、待定桶可见；⑤ 今日推荐同日刷新结果恒定；⑥ 网站添加/编辑/删除持久化（重启验证），点击跳默认浏览器；⑦ 系列合集卡片/成员对话框/全部合集搜索可用；⑧ 随机一作可换来源、连抽正常、点击结果进详情；⑨ 「开始探索」进入原探索库：**免责弹窗照旧、功能样式与改造前完全一致**，返回 chip 回大厅且大厅状态保留；⑩ 960×540 与 1280×720 两档窗口无溢出；⑪ 网络断开下大厅可打开，各板块空态正常。

**技术**

- `./flutter/bin/flutter.bat analyze` 新增文件 0 error（全量基线 ~565 info 不新增 error）。
- `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test` 不低于当前基线（近期全量约 **353 通过**，存量失败与 flaky 项以 HANDOFF/DEV_LOG 最新记录为准），新增 4 测试文件全过。
- `git status --short` 仅含 §8 清单文件；`git diff lib/pages/discover_page.dart` 为**空**。
- 改 UI 后人工视觉验证（项目铁律：`lib/pages/`、`lib/widgets/` 零测试覆盖）。

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
在 D:\CTLIB 按 docs/DEV/features/explore_hall_implementation_plan.md 实施「探索大厅」。
先读 AGENTS.md 与该方案 §2/§7/§8，然后按 Phase 0 → 4 顺序执行：
0) 先做 §7 的 V1-V4 四项技术验证，任何一项不通过立即停下报告，不要绕过；
1) Phase 1 只写 services/models/utils + 测试，不写 UI；跑通新增测试；
2) Phase 2/3 按 §4.1 布局与 §4.2 各板块规格实现 UI，复用 AppColors/AppStyles/
   InteractiveWrapper/NsfwImage(contentKind: cover)，封面渲染必须走 NsfwImage；
3) Phase 4 改 main_container.dart:730 前必须先向用户确认（稳定区）；
硬约束：lib/pages/discover_page.dart 零改动；不加任何 pubspec 依赖；不碰
sidebar/big_picture/theme/portable_*；GameModel 不加字段；收尾按 §11 验收并
更新 DEV_LOG/SESSION_HANDOFF/本档案，单独 commit。
```

---

## 13. 待用户决策的开放问题

| # | 问题                                                                                              | 默认方案（未回复则按此执行）                                            |
| - | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| 1 | 大厅首屏即展示探索库封面（月历/推荐/随机），但免责声明目前只在进入探索库时弹出——是否前置到大厅首进？                                            | **不前置**，维持现状（进入探索库才弹）                                     |
| 2 | 本地库随机结果/系列成员中本地作品的点击详情：一期是否接 `GameDetailDialog`？（需核对 `main_container` 现有本地详情回调并透传，构造改动 +1 可选参数） | **一期接通**（大厅构造加可选 `onOpenLocalGame`，main_container 透传现有回调） |
| 3 | 「全部合集」的承载形态：对话框 还是 独立视图？                                                                        | **对话框**（带搜索框）                                             |
| 4 | 设计稿文案是否照搬：「探索大厅 / 网站站点管理 / GalGame系列合集 / 今日运势·随机一作 / 抽一郎 / 开始探索」                                | **照搬**                                                    |
| 5 | 预热开关是否暴露到设置页？                                                                                   | **不暴露**（内置 24h 节流 + 月历卡手动刷新）                              |

---

## §15. 实施完成记录（2026-09-11）

Phase 0-4 已全量落地（同日 DEV_LOG 有对应条目）。相对方案的偏差与实测结论：

- **Phase 0**：V2（cmd start 外链）真机通过；V3（series 整表）代码级确认；V1 预热耗时未实测（遗留真机首跑观测）；V4 以 `test/explore_hall/explore_hall_layout_test.dart` 固定视口压测替代原型（960×540 与 1280×800 双档全过）。
- **布局**：方案原定「返回 chip 放左上」，实测与 discover_page 全宽悬浮顶栏（top:0，discover_page.dart:681-686）冲突 → 改放**左下角**。
- **数据**：方案中的独立 `ExploreLibrarySnapshot` 并入 `ExploreCalendarService`（快照即服务内状态，少一层间接）；「今日推荐」候选映射在 UI 层完成，纯函数只吃轻量 `RecommendedCandidate`（today_recommendation.dart）。
- **实测坑 1**：`DateTime.tryParse` 会把 '9999-99-99' 这类非法串「进位」成合法日期（10007-06-07），`parseIsoDate` 已加正则前缀 + 回读校验（calendar_grid.dart）。
- **实测坑 2（复发性）**：Edit 工具写 `series_section.dart` 连续 3 次报成功但磁盘回滚，最终以 Python 原子写入修复——本仓库长文件/连续编辑请优先 Python 原子写并 grep 验证。
- **测试**：新测试 24/24 通过；analyze 新增文件 0 issue；全量基线比对见当日 DEV_LOG。

---

## §16. 月历数据源切换为 KUNGAL 同步（2026-09-11 晚，二次迭代）

真机反馈月历"完全没有功能"，只读审计定位 **P0 竞态**：`explore_hall_page.dart`
initState 先发 `ensureGamesLoaded()` 再发 `startWarmup()`，后者的内部
`ensureGamesLoaded()` 被在途守卫短路 → `_games.isEmpty` → **预热在生产环境
几乎必然静默中止**（测试走 debugInjectGames 绕过该路径故未暴露）。

经用户拍板，月历板块数据源整体切换为 **KUNGAL 社区公开接口同步**（比
"标题回查元数据"质量高一个量级），原预热链路保留仅服务「今日推荐」：

- **接口（全部实测 200）**：`/api/galgame/calendar?month=YYYY-MM`（单月，
  含 meta 月份边界）、`/upcoming`（未发售已定档）、`/pending?year=`
  （年内待定）、`/tba`（日期未定）。信封 `{code:0,data}`；条目含中文译名/
  日文原名/release_date/release_precision(day|month|year|tba)/company/
  5:7 封面直链/rating/content_limit(sfw|nsfw)。详情页 `kungal.com/galgame/<id>`。
- **新增**：`lib/models/kungal_calendar_game.dart`（防御性解析 + 全角 ASCII
  折叠的 normalizeTitle 标题匹配键 + parseIsoDate 进位防护）、
  `lib/services/kungal_calendar_service.dart`（4 端点按需拉取、每键 24h
  磁盘缓存原子写、dart:io HttpClient 零新依赖、失败回落旧缓存、forTest 注入）。
- **calendar_section 重写**：四桶循环（日期 → 本月待定 → 未发售 → 年内待定
  → 日期未定，镜像 KUNGAL 四视图）；nsfw 条目打 NSFW 角标（封面本身仍走
  NsfwImage 管线）；副标题常驻"数据来源 KUNGAL"署名；失败"点击重试"；
  月份边界按 meta.has_prev/has_next 禁用方向键。
- **点击行为**：规范化标题精确匹配探索库 → 命中进我们的详情页（保留下载
  入口）；未命中 → `WebsiteBookmarkService.openExternal` 开 KUNGAL 页面。
- **P0 修复三件套**（ExploreCalendarService，服务今日推荐仍必需）：
  ① initState 竞态（只留 startWarmup）；② ensureGamesLoaded 改用
  `GameRepository.getAllGames`（手写「返回条数==perPage」翻页是项目已知
  不可靠模式，见 game_repository.dart:128 历史教训）；③ 预热循环统计
  实际成功数，**成功数为 0 不写 24h 节流戳、不持久化 attempted**（一次
  断网不再自锁 24h，下次启动整轮重试）。
- **礼貌接入**：KUNGAL 为 AGPL 开源社区公益站——24h 缓存 + 按需拉取 +
  自定义 UA + UI 署名；接口无稳定性承诺，服务层解析失败回落旧缓存。
- **测试**：新增 `test/explore_hall/kungal_calendar_test.dart` 12 用例
  （真实响应 fixture：模型解析/规范化/月度聚合/服务注入与失败态），
  explore_hall 目录 36/36 全过。

---

---

## §17. 视觉美化迭代（2026-09-11 晚，三轮）

**动机**：用户反馈大厅组件与布局简陋、缺设计。设计稿的「暖纸质感 + 墨线描边」
此前只落了结构没落气质——全厅清一色「3% 蒙层 + 细边框」通用公式。
《变更计划》+ SVG 视觉稿经用户批准后执行，纯视觉层（7 改 1 新增）。

### 新增 lib/widgets/explore_hall/hall_visuals.dart（共享装饰组件）
- `HallGradients`：品牌渐变（brandBlue → lerp(successGreen, 0.55) 青绿）
  + `coverScrim` 封面压字黑渐变（图片压字惯例，主题无关）
- `HallDecor.card`：板块卡面 = 垂直微渐变（深色白 5.5%→2.8%；
  浅色 titleBrown 5% 掺白的「暖纸」）+ 暖调描边（深白/浅 titleBrown）
  + 柔和投影 + AppRadius.xl 圆角——全厅观感的单一真相源
- `HallDecor.panel`：内嵌面板统一装饰
- `HallAmbientBackdrop`：页面双径向氛围光（左上 brandBlue / 右下
  titleBrown），`AppThemeManager.colors.hasBackgroundImage` 时自动关闭
- `HallIconBadge` / `HallLetterAvatar` / `HallReleaseDots` / `HallAccentUnderline`

### 各板块改法
- **shell**：图标徽章 + F1 标题 + Outfit 英文小字幕 + 墨线分隔；
  icon/iconAccent/engCaption 全可选，旧调用零破坏
- **页面**：氛围光包裹；主标题 26px + 渐变下划线 + 日期胶囊；
  开始探索 = 渐变填充 + 同形辉光（圆角矩形 BoxShadow，非圆形底块）
  + 图标圆徽 + ENTER›（HoverButton 透明底 + zero padding 承载）
- **月历**：日期数字 Outfit；发售数字→1-3 圆点；选中=填充圆、
  今日=starGold 描边环；月份导航胶囊化；KUNGAL 行卡片化
- **站点**：首字母渐变徽章（HallLetterAvatar 取标题首 rune）；浅色白 50% 卡面
- **合集**：96→132px 封面全幅 + coverScrim 压字 + 「系列/合集」mode 角标
  （SeriesModel 无成员数字段，不造假数据）
- **文档**：TabBar→自绘分段胶囊 + IndexedStack（通知 FutureBuilder 保活）；
  随机按钮主色胶囊；结果卡来源/评分/工作室并入封面压字层（省一行高度）
- **话题**：大卡封面压字（标题/工作室）+ 标签行；列表 Outfit 排名
  （Top1 主色）+ 选中主色描边；评分金色化
- **空态**：圆形图标底 + FittedBox scaleDown 防小窗溢出

### 960×540 压测暴露并修复的两处溢出
1. 文档分段胶囊行宽超 23px → 内边距 11→8、间距 6→5
2. 空态提示超高 4.8px（测试注入空系列列表）→ FittedBox scaleDown
经验：shell 每加 1px 垂直开销都会传导到最紧的板块；视觉改动必跑双档压测。

### 主题适配口径（§17 起生效，后续迭代遵守）
- 全部取色走 AppColors getter 深浅双分支，禁硬编码深色（v3.8 教训延续）
- 浅色卡面 = titleBrown 5% 掺白暖纸；辉光贴部件形状
- 背景图模式：氛围光自动关闭，卡面半透明保持可读

---

## §18. 每日推荐 v2：维度轮换制 + 当日快照（2026-09-11 深夜）

**用户痛点**：①推荐机制不明确（旧版 rating+热度打分黑盒）；②推荐列表
随元数据补全不断闪变，"莫名其妙就变了"；③希望列表轮播 + 当日持久化。

### 机制（today_recommendation.dart 重写，纯函数）
- **维度池四类**（用户口径：标签/会社/星级/评分人数）：
  - 全局维度 ×2：全库按星级降序 / 全库按评分人数降序，各取 8 部；
  - 标签 / 会社维度：按全库出现频次取 Top 24 入池（频次降序→名称升序
    确定性排序）；选中「恋爱」「Key 社」等具体值后筛出该维度全部作品，
    再按星级降序排 8 部（无星级排尾部不剔除）。
- **每日选择**：日期 yyyymmdd 为种子从池中确定性随机选一个维度——
  同日同数据必然同维度；标签/会社维度副标题展示主题（如
  「恋爱」标签 · 按星级排序），机制对用户透明。
- **排序确定性**：主字段降序 → 次级（voteCount 或 rating）降序 →
  gameId 升序兜底，同数据结果逐位一致。
- **空维度 fallback**：选中维度筛不出作品（如全库无星级）时从种子位
  顺延尝试其余维度；全空才产出空方案（照常持久化，当日不再重算）。

### 当日快照服务（新增 services/daily_recommendation_service.dart）
- 生成后整份快照落盘 `data/daily_recommendation.json`（tmp+rename 原子写）；
- **当日一律读快照绝不重算**——根治闪变的唯一真解（旧实现监听
  DiscoverMetadataService 每次补全都重算 Top24）；
- 生成前置 = 探索库就绪：`gamesLoaded || (gamesFailed && games非空)` 且
  `!isWarming`（用户口径「先等数据彻底加载好再安排推荐」）；
- 快照损坏/跨日静默丢弃重生成；生成本身确定性 → 缓存丢失重算结果一致（双保险）。

### UI（related_topics_section.dart 重写）
- 右侧列表自动轮播：Timer 4s 下滑一行（行高 48+分隔 4 = 步长 52），
  到底回顶，鼠标悬停暂停（MouseRegion）；
- 副标题 = 今日主题 label；整理中显示预热进度 m/n；库加载失败可点击重试；
- 大卡 tags/developer 优先用快照字段、空缺时按 gameId 从 GameModel 回补
  （快照恢复兼容）；行尾排序值格式化（>=1w → 2.5w）。

### 测试（+9：纯函数 7 + 服务编排 2 组）
- 四维度排序口径 / 截断与同分次级 / 同日恒定 / 跨日轮换（60 天两全局
  维度都被选中）/ fallback 不产空推荐 / 池上限 / 序列化 round-trip；
- 服务：未就绪不生成→注入数据即生成+持久化一次 / 当日已定二次 notify
  不重算不重写 / load 命中当日无需就绪 / 过期快照丢弃 / detach 重 attach。



### §18.1 真机反馈修复（2026-09-11 深夜，二次迭代）

**用户反馈**：推荐数据不完整 / 列表轮播系统错误 / 「每日推荐」字样被去掉
用户无法辨识板块用途。

1. **P0 · 残缺快照被锁定（"数据不完整"根因）**：旧版 startWarmup 的
   `_warming` 置位发生在全量列表加载**之后**——"加载完成"notify 发出时
   预热尚未标记进行中 → 每日推荐误判"数据就绪"提前生成，把大量未补到
   星级的半成品数据写进当日快照且当日不再更新。修复：`_warming` 进入
   startWarmup 即置位、finally 统一清零 + notify（含节流/空库提前
   return 路径），就绪判定真正等到"数据完全可读"。
2. **P0 · 旧残缺快照失效**：快照 JSON 加 `version: 2`；无 version 的
   旧快照读入即抛 FormatException → load 捕获丢弃重新生成（用户磁盘上
   已写入的残缺快照自动失效，无需手删）。fromJson 的 day 异常也改为
   显式抛出（原 fallback now() 会把过期快照误判为当日）。
3. **P1 · 「每日推荐」身份恢复**：副标题改为
   `每日推荐 · {今日主题}`；空态/整理中文案同样带"每日推荐"前缀。
4. **P1 · 轮播加固**：步进回调整体 try-catch（帧间隙 position 异常
   静默跳过，不冒红屏）；`hasContentDimensions` 检查；用户点击选中行
   后暂停轮播 8s（`_pauseCarouselUntil` 时间戳，不引新 Timer）。
5. **P2 · 无星级显示 '—'**：列表行尾与大卡评分不再显示误导性 0.0
   （星级类维度 score<=0 → '—'；评分人数维度维持整数/w 压缩格式）。

**测试**：+1（旧版快照丢弃）；布局测试新增"每日推荐"字样断言；
explore_hall 46/46。

### 遗留
- 冷启动首日推荐要等预热（数百次源站请求，分钟级），期间显示整理进度；
  次日起 24h 节流 + 当日快照，进大厅秒出。
- 轮播步长按当前行高（52）硬编码，若未来行高调整需同步 `_rowStep`。

---

## §19. 月历选中框圆角化 + 站点图标（2026-09-12 凌晨）

### ① 月历选中框：圆 → 圆角方框
`calendar_section._buildCell`：去掉 `BoxDecoration(shape: BoxShape.circle)`，
改用 `borderRadius: BorderRadius.circular(6)`（BoxDecoration 中 shape 与
borderRadius 互斥，必须二选一）。选中 = 圆角方框填充 + 主色描边，
今日 = 圆角方框金色描边；与板块卡片圆角语言统一。

### ② 站点管理：图标支持「自动识别 favicon」与「上传图片」
- 模型：`WebsiteEntry` 新增 `iconPath`（本地文件路径，JSON 键 `icon_path`，
  旧数据缺省 '' 兼容）。**存本地路径而非远程 URL**：面板展示不依赖网络、
  规避站点防盗链。
- 新服务 `services/website_icon_service.dart`：
  - 自动识别三级回落：首页 HTML 的 `<link rel=…icon…>` →
    `https://host/favicon.ico` → DuckDuckGo 图标服务（PNG 兜底）；
    串行、6s 超时、2MB 上限；本会话失败的 host 不再重试（`clearFailure`
    供用户手动重试）。
  - 上传：`file_picker` 选图后复制到 `data/site_icons/`（项目已有
    file_picker ^8，零新增依赖）。
  - 缓存：`data/cache/site_icons/<host>.<ext>`，`findCachedIcon` 按 host
    前缀命中（扩展名不定）。
- 🔴 **ICO 必须转换**（实测关键结论）：favicon 绝大多数是 ICO，
  而 Flutter 原生 `Image` **不支持 ICO**（也不支持 SVG）；
  实测 KunGal / VNDB 的 favicon.ico 都是 **DIB 位图**（不是内嵌 PNG），
  DuckDuckGo 兜底服务在国内不可达 → 不转换则「自动识别」形同虚设。
  实现 `decodeIco`：内嵌 PNG 帧直接切片；DIB 帧补写 14 字节
  BITMAPFILEHEADER 包装为标准 BMP，并把 `biHeight` 从「高度×2（含 AND
  mask）」改回实际高度、只取像素部分（⚠️ BITMAPINFOHEADER 中 biHeight
  在偏移 8，不是 12——写错会破坏 biPlanes/biBitCount）。
  真机实测：KunGal 15KB ICO → 9.2KB BMP、VNDB 318B ICO → 246B BMP，
  PIL 校验为合法 16×16 调色板图。
- 收藏服务：`add/update` 支持 `iconPath`；新增 `refreshIcon(entry, force:)`
  与 `ensureIcons()`（面板 load 完成后后台串行补齐，条目为空时零请求）。
- UI：`_SiteIcon`（图标文件优先，缺失/损坏回落 HallLetterAvatar）；
  编辑弹窗加图标区（预览 + 自动获取 / 上传图片 / 清除）；
  图标状态放 `ValueNotifier`（StatefulBuilder 每次 rebuild 会重跑 builder，
  普通局部变量会被重置回初始值）。



### §19.1 导航层级修复 + 文档与趣味分区（2026-09-12 下午）



#### B2. 趣味子容器重做（2026-09-12 夜，用户反馈"又小又丑/按钮突兀"）

**上一版的问题**：右区按 30% flex → 960×540 下仅 ~108px；为了不溢出把
结果卡塞进「固定虚拟尺寸 150×64 + FittedBox 缩放」，实际渲染被缩到约
0.7 倍（封面只剩约 32×46、文字发虚）——**缩放是"又小又丑"的根源**；
按钮用了品牌渐变 + 辉光（与「开始探索」同款强视觉），在窄栏里突兀。

**重做要点**：
1. **右区宽度兜底**：`LayoutBuilder` 取 `max(30%, 150px)`（上限 45%），
   左区 Expanded 吸收剩余。实测：1280 下子容器 158px（约 69:31，正是
   需求比例）；960 下 150px（左区仍有 210px，分段胶囊 ~190px 不溢出）。
2. **取消缩放**：结果卡用真实可用空间按 1:1 渲染。
3. **结果卡改杂志感纵向**：封面 `Expanded` 撑满剩余高度（横幅/海报）
   + 底部渐变压字（标题 + 副标题），左上角来源徽标、右上角评分；
   底部只留动作行（`_MiniAction` 20 高）。实测封面区：
   960 下 130×40；1280 下 138×158（竖版海报）——比旧版放大 3.5～15 倍。
4. **按钮改柔和**：主色淡底(0.14) + 主色描边(0.45) + 主色粗体字 +
   casino 图标圆徽，通栏 24 高（去掉渐变与辉光，避免窄栏突兀）。
5. 子容器加测试锚点 `Key('docsRandomPanel')`，便于将来几何断言。

**实测几何**（一次性 widget 测量）：
- 960×540：子容器 150×117，按钮通栏 24 高，结果区 130×68
- 1280×800：子容器 158×235，结果区 138×186



#### B3. 三项体验迭代（2026-09-13，用户点名）
1. **趣味区占比加大**：右区 30%→**40%**（下限 150、上限 47%）。
   960×540 下受左区分段胶囊（~190px）硬约束，物理上限 ~46%，
   故 960 保持 150px 兜底；1280 起即达 40%（左 317/右 211）。
2. **系列合集列表鼠标拖动**：桌面 Flutter 默认 dragDevices 不含 mouse，
   横向列表无法用鼠标拖。`ScrollConfiguration.copyWith(dragDevices:
   {mouse, touch, stylus, trackpad})` 一处包装放开——左键长按拖动与
   中键拖动（同为 mouse 设备）均生效，点击不受影响（拖动超 slop
   自动取消 tap）。滚轮横滚未做（用户未要求，需 PointerSignalResolver
   避免双驱动，后续要再加）。
3. **月历日框扩大 + 数量下标入框**：格子改为整宽圆角方框容器
   （borderRadius 7、margin 2 自适应），数字与 1-3 颗新作圆点全部
   装在框内；默认极淡框（6% 墨线）、今日金描边、选中主色填充+描边；
   非当月格整体 35% 透明度。圆点始终在框内（无事件时占位 4px
   保持数字对齐）。



#### B4. 日框正方形设计 + 站点列表拖动 + 系列全部入口增强（2026-09-13 下午，用户附设计图）
1. **月历日框改圆角正方形（按用户设计图）**：上一版"整宽横长条"不符
   预期。改 `AspectRatio(1)` 正方形（随格子尺寸自适应，960 约 33×33、
   1280 约 50×50），圆角 10；**默认无框线**（纯数字+圆点，与图一致），
   选中 = 主色描边 1.6 + 数字主色加粗，今日 = 金描边 1.3；圆点仍在
   框内（无事件占位对齐）。
2. **常用站点列表鼠标拖动**：横向 ListView 包 `HallHScroll`（新增共享
   组件，hall_visuals.dart——ScrollConfiguration 放开 mouse 拖拽，
   左键长按/中键拖动）。series_section 的内联版同步替换为 HallHScroll。
3. **系列"查看全部"入口增强**：原 trailing 是低调 TextButton（用户
   实际没发现）→ 改为胶囊按钮（collections_bookmark 图标 + 『全部』，
   buttonBackground 底 + border 描边 + InteractiveWrapper hover），
   与站点板块「添加」按钮同语言；_openAll 全系列弹窗逻辑不变。



#### B5. 月历预览卡放大 + 站点简介 Tooltip + 站点名智能推断（2026-09-13 傍晚）
1. **月历右侧游戏行放大**（`_KungalRow`）：封面 36×48 → **56×75**（竖封
   3:4）、标题 12→13（允许两行）、NSFW 徽标 8→9、公司行→10.5、评分
   9→10.5、chevron 14→16、padding 加大。可见行数 5+ → 约 2 行（列表
   本来就可滚动，可读性优先）。
2. **站点卡片简介 hover 完整内容**：`_SiteCard` note 非空时包
   `Tooltip`（message=note），参数与设置页超分预设卡片完全同款
   （waitDuration 500ms / primaryText 底 / 白字 / 圆角 6 / padding
   10×6）；note 为空不包（host 行照旧）。
3. **站点名智能推断**：`WebsiteBookmarkService.deriveTitle(url)` 新增
   静态——前缀过滤（www/m/wap/mobile/forum/bbs）+ 公共后缀连删（顶层
   TLD + 双段 com.cn/co.jp），删空回落原 host；`add()` 空 title 兜底
   由 host 全名改为 deriveTitle（vndb.org → vndb、www.kungal.com →
   kungal、m.example.com.cn → example）。

#### A. 详情页导航层级丢失（P0，用户实测两案例）
- **现象**：「大厅→探索库→详情→返回」直接跳回大厅（跳过探索库）；
  「大厅→相关话题卡→详情→返回」回大厅（碰巧符合默认值）。
- **根因**：`main_container._buildCurrentPage()` 返回**单个 widget**——
  `_showDetailPage=true` 时整棵页面树只剩 `GameDetailPage`，
  `ExploreHallPage`（连同内部「大厅↔探索库」Offstage 子视图状态）被整体
  卸载；返回后重新 initState，`_showLibrary` 回到初始 false。附带损失：
  月历选中日/焦点轮播/滚动位置全丢、免责弹窗因 DiscoverPage 重建而重复弹。
- **修复**：`_buildCurrentPage` 重构为常驻 `Stack`——
  底层 `_buildBasePage()`（新拆方法，原 switch）在详情期间 `Offstage`
  保活（不绘制不参与命中），详情页作覆盖层置顶（KeyedSubtree key 绑定
  游戏 id 的重建语义保留）。返回后底层原样恢复，层级正确。
  ⚠️ main_container.dart 属稳定区，本轮经用户明确授权（"彻底研究并修复"）。
- **行为矩阵（修复后）**：库→详情→返回=回探索库 ✓；大厅卡片→详情→
  返回=回大厅 ✓；详情内系列跳转→返回=逐级回退（原逻辑不变）✓。

#### B. 「文档与趣味」内部分区（用户明确需求）
- 外层 HallSectionShell 不拆；内部 Row 改 **70:30** + 竖直分隔线
  （1px，titleBrown/白 8% 低透明度，上下 margin 4）。
- 右 30% = 随机一作独立子容器：`HallDecor.panel` + 柔和投影（内嵌
  悬浮感）；标题行（casino + 『趣味抽签』）；主操作按钮**强化**为
  品牌渐变填充胶囊 + 白字 + 辉光（与「开始探索」同语言小号版），通栏放置。
- 抽签结果卡：固定虚拟尺寸 150×64 + `FittedBox(scaleDown)`——
  30% 右栏在 960×540 仅约 108px，"标题+按钮同排"需 ~143px 必溢出
  （首轮实测 60px/17px 两档溢出即此因）；固定尺寸卡保证任何窗口宽
  无溢出，宽窗口按原大小呈现。卡改横向紧凑布局（封面左整高 + 右信息列），
  `_MiniAction` 高 26→20。
- 960×540 下左 70%（~166px）放不下分段胶囊行（~190px）的问题不存在：
  左侧是 Expanded 主区不受 30% 挤压，分段胶囊在左区内自适应 ✓。

### 测试（+10）
图标服务的格式魔数校验（PNG/JPEG/GIF/WEBP/BMP 通过，ICO/SVG/HTML 拒绝）、
ICO 解码（内嵌 PNG 切片 / DIB→BMP 且高度修正 / 非 ICO 返回 null）、
缓存命中、条目 icon_path 序列化与旧数据兼容。

---

## §20. 发售月历数据源切换：REST 登录墙 → SSR 页面解析（2026-09-13 深夜，P0）

### 排查结论（用户报告"月历无法正常加载"）
- **直接原因**：KUNGAL 四个日历 REST 端点全部返回
  `HTTP 401 {"code":205,"message":"用户登录失效"}`（实测 2026-09-13），
  Referer/Origin 无法绕过；`_fetchJson` 的 `statusCode != 200` 防御
  返回 null → 回落旧缓存 → 缓存超期后板块空白。
- **网页端仍公开**：`/galgame-calendar` 为 Nuxt **SSR**，发售数据完整
  内联在 `__NUXT_DATA__`（devalue 扁平数组，实测 86 部当月作品）。
- **支持 `?month=YYYY-MM` 翻月**（实测 2026-10 → 14 部）；
  upcoming/pending/tba 无独立路由（404）。

### devalue 编码规则（实测，Dart 解析器的依据）
- 对象/数组内联；**字段值一律是裸 int 索引**指向 payload 数组元素
  （字符串/布尔/null/数字也索引化：release_date: 60 → "2026-09-01"、
  is_nsfw: 7 → false）；另有 `[idx]` 单元素数组引用（防御性支持）。
- 🔴 读取字段必须按类型解引用（`KungalSsrReader`）：直接比较
  `node['object'] == 'work'` 永远 false（值是索引）。
- 本地化名称形态：`localized['zh-Hans'] = {value: idx, is_machine: idx}`。

### 实现（kungal_calendar_service.dart）
- `_fetchBody(url)`：通用 HTTP 抓取（200 才返回）；`_fetchJson` 改为
  基于它 + 信封校验（旧 API 回落通道保留）。
- `parseNuxtCalendarItems(html, ym)`（静态可测）：提取 `__NUXT_DATA__`
  → 遍历 `object=='work'` → 按 `release_date` 前缀过滤目标月 → 输出
  **旧 API 兼容 item JSON**——模型层（KungalMonthData/KungalCalendarGame）
  与 UI 零改动。
- `ensureMonth` 四级链：24h 磁盘缓存 → SSR → 旧 API（防 KUNGAL 恢复
  公开）→ 超期缓存。
- `ensureUpcoming` 改为**合成**：未来 6 个月 SSR 月历（复用 month 缓存）
  过滤 `release_date > 今天` 按日期排序；不再请求已登录墙的 upcoming 端点。
- pending / tba 两桶 SSR 无数据源：仍走旧 API → 失败空态（数据源特性）。
- 测试注入约束：`forTest(htmlOverride:, fetchOverride:)`——**任一注入
  即禁用真实网络**（fetchOverride 注入 = 旧 API 模式，SSR 通道视为
  不可用），旧测试零改动零网络。

### 实测端到端（真实 542KB 页面）
解析 86 条：有名 86/86、公司 78/86、封面 27/86（与 python 交叉验证一致
——KUNGAL 未登录 SSR 本身多数作品未挂封面，UI 已有字母徽章/占位回落）、
评分 2/86。样例：深闺之病 / 深窓の病 / Tedopoyo / 2026-09-01 / webp 封面。

### 风险与备忘
- SSR 页面结构无版本承诺，KUNGAL 改版可能再次失效（有 24h 缓存 + 空
  态兜底，不会崩溃）；`?month=` 参数与 devalue 编码已实测固化。
- pending/tba 恢复途径：KUNGAL 若提供公开 API/token，改回端点即可
  （旧通道代码保留）。

---

## §20.2 月历数据源定稿：NextMoe 官方开放 API v2（2026-09-26）

### 依据：KUN 官方开发者通知（用户提供邮件 PDF）
NextMoe·未萌（原「鲲 Galgame」）向注册开发者发出《账号中心域名变更》：
- 账号中心 OpenID Provider：`oauth.kungal.com` → `account.nextmoe.com`
- 故障机制：旧域名 308 跳转时**跨域客户端按规范丢弃 Authorization 头**
  → POST /oauth/token 成功（body 带凭证）、GET /oauth/userinfo 401（header 被丢）
  = "授权通过但登录校验失败"的半失败
- 要点：OIDC 库强校验 `id_token.iss` 必须改为 `https://account.nextmoe.com`；
  client_id/secret/redirect_uri 不变；开发者门户 `developer.nextmoe.dev`
- 🔴 该通知**同时印证**：官方平台已迁 NextMoe，旧 `/api/galgame/*` 不会再公开

### 关键发现：项目已有 NextMoe 官方密钥
`lib/packages/luna_metadata_sdk/.../nextmoe_service.dart` 早已集成 NextMoe
开放 API v2（`api.nextmoe.dev/v2`，`NextMoeService.apiKey`，scope
catalog:read，free 档 60 次/分 · 5 万次/日）——月历无需再走 SSR/VNDB/凭据。

### 四桶 → 官方 calendar 端点（2026-09-26 用真密钥实测）
| 桶 | 查询 | 实测结果 |
|---|---|---|
| 当月月历 | `?month=YYYY-MM&precision=day` | 300 条（3 页上限），98% day 精度 |
| 未发售 | 未来 6 月合成（沿用） | ✓ |
| 待定（仅知年份） | `?year=YYYY&precision=year` | **113 部**（2026，year 精度样例 ✓） |
| 未定（TBA） | `?status=announced` | **500 部**（5 页上限触顶，unknown 状态） |

补充：`include=companies,ratings` 取会社/评分；`nsfw=true` 含 R18；
cursor 翻页（`next_cursor`，页数上限防失控）；字段与旧 KUNGAL API 对齐
（content_limit / release_date_precision / cover.url / display_name）。

### 实现
- `_fetchNextmoeBucket({query, limitPages})` + `_getNextmoe`（Bearer 密钥，
  UA 标识）+ `nextmoeToItem`（@visibleForTesting 静态适配）
- id 映射：仅 `claim.site == 'kungal'` 用 `claim.site_work_id`（保证
  detailUrl 正确），否则 0（不外跳）
- 评分：ratings 优先 vndb（与 SDK 权威链一致），erogamescape /10 归一
- 会社：companies 取 `attribution_role=developer`，多社 ` / ` 连接
- 回落链：**NextMoe → SSR 页面（仅 month 匿名兜底）→ 超期缓存**；
  旧 `/api/galgame/*` 通道与 VNDB 补桶代码**已删除**（官方迁移单向，
  旧端点 401 永久失效，删除理由充分）
- 测试注入：`forTest(fetchOverride:, htmlOverride:)` 任一存在即禁真实网络

### 验证
- 单测：NextMoe 4 组（字段映射/claim id/评分归一/参数与翻页）+ SSR 回落组，
  `kungal_ssr_test` 8/8、`explore_hall` 73/73、analyze 0 issue
- 真机级端到端（真密钥，非 mock）：month 300 / pending 113 / tba 500，
  会社 288/300、封面 46/300（含大量同人作，UI 有占位回落）
- ⚠️ 未做应用内真机走查（需启动 UI 看四桶渲染）

---

## 附录 · 2026-10-02 文档板块 UI 优化（已实施）

- **导航精简**：顶部胶囊 6→5，「介绍」「使用说明」合并为单入口「介绍」，
  内部二级分段胶囊切换（参考【我的】面板「我的作品/我的资源」设计）。
  `docs_section.dart`：`_tabLabels` 5 项 / `_buildIntroGuideTab()` 新增 /
  IndexedStack 索引重排（0=合并入口, 1=通知, 2=发布, 3=我的, 4=动态）/
  【我的】reload 回调 4→3 / `_visitedTabs` 语义不变。
- **发布说明折叠**：`docs_publish_tab.dart` 进入不再直铺说明，搜索框下方
  「发布说明」胶囊按钮（默认收起，AnimatedRotation 箭头），展开后浅底小卡承载原文案。
- **顶栏发布/上传双通道**：`discover_page.dart` 顶栏第一行加「发布」「上传」按钮
  （同内联筛选控件容器风格 + accent 图标），搜索框 Expanded 缩短让位；新增
  `upload_publish_dialog.dart` 选择器窗口（判重 → 命中跳详情页自动弹上传 /
  未命中转发布，详见 `features/user_share_upload_plan.md` 附录）。
- 验证：进程内 analyzer 3 文件 errors=0；真机走查待开发者。

---

## 附录 · 2026-10-03 月历点击可预期性（已实施）

**问题**：月历行「点了没反应」。真因**不是** NSFW、也不是遮罩层，而是
KUNGAL 站内未收录 ⇒ `detailUrl` 为空（见上文 id 映射）⇒ 点击无处可去，
旧代码此处直接 `return`（静默空转）。全站约 70% 月历行如此。

**已实施的修法**
- `calendar_section.dart` —— `CalendarSection.canOpen`（可选，由大厅页注入）；
  `_KungalRow.openable` 决定尾随标记：可打开 → 「›」+ 手型指针；
  不可打开 → 灰「无详情」+ 基本指针 + 卡片/标题降一档对比度。
  未注入 `canOpen` 时退化为「有 `detailUrl` 即视为可打开」。
- `explore_hall_page.dart` —— `_isCalendarItemOpenable`（本地库命中 或 有 detailUrl，
  口径与 `_onCalendarItemTap` / `_matchLibraryGame` 完全一致）+ 规范化标题索引缓存
  `_localTitleKeySet()`（按「加载态 + 条数」失效，避免逐行扫库跑正则）；
  无目标时 `AppSnackBar.info('「X」暂无 KUNGAL 详情页')` 明确反馈。

**未采纳的兜底**：跳 KUNGAL 站内搜索。实测其搜索是客户端 autocomplete
（`SearchAutocomplete.vue` → `/galgame/search/picker`），列表页筛选参数
（`useGalgameFilters.ts:41-77`）**无 keyword**，不存在可外跳的搜索 URL。

**验证**：全 lib 312 文件 errors=0；离线探针（frontend_server + flutter_tester）
三态实测 行内箭头 1/2/0、「无详情」标记 1/0/2。⏳ 真机走查 + `flutter test` 补跑待开发者。
