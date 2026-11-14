# 功能档案：全站搜索（SITE-SEARCH）

| 项 | 值 |
|----|-----|
| **状态** | 已实现，待真机走查（2026-11-11） |
| **优先级** | P1 |
| **创建日期** | 2026-11-11 |
| **关联需求** | 探索库搜索栏扩展全站搜索（用户 2026-11-11 口述需求 + 四项交互拍板） |

---

## 1. 解决什么问题

探索库（`discover_page.dart`）的 **CT 探索库**作品全部由我们自己收集整理，覆盖面有限。
鲲（KUNGAL / NextMoe 生态）与 2DFan 已有成熟的资源与数据体系，是天然的互补。

目标：用户**在探索库内就能搜到站外的作品**，不必先知道要去哪个网站找。

边界（用户明确要求）：
- 探索库整体界面与列表显示**保持不变**；
- 改动只发生在「搜索栏 + 搜索行为」；
- 站外作品点进去看到的是**该站点的数据**。

## 2. 用户可见行为

- 搜索框**内部右侧**多一个「全站」胶囊按钮（搜 索 游 戏... 输入框里，不占第一行宽度）。
- **一次性动作**：点一下才打站点；输入框改字**不触发**站外请求。
- 点完后：库内命中照旧在上，站外命中接在后面，同一网格混排，站外卡右上角带来源角标（鲲 / 2DFan）。
- 顶栏下方出现概览条：`站外「关键词」· 鲲 12 · 2DFan 8`（+ 失败源原因 + 关闭按钮）。
- 改字 / 点清除 / 点概览条 × → 站外结果立刻作废（避免结果与关键词不符）。
- 点站外卡 → 站内全屏详情页（只读），顶部徽章「数据来自 鲲 / 2DFan」，可达：
  「用此数据入库」（→ 跳添加页并预填标题）、「打开原站」、「返回」。
- 站外命中若与库内作品同名（归一化后），**不重复展示**（概览条会注明隐藏了几条）。

## 3. 架构（三层，刻意保持很薄）

```
UI        discover_page.dart（搜索框按钮 / 混排网格 / 概览条 / 站外卡片角标）
          site_game_detail_page.dart（站外作品详情，全屏 Overlay）
   │
聚合      lib/services/site_search/site_search_service.dart
          └ 两源并发 · 单源失败隔离 · 5 分钟缓存 · 同词防重入
   │
站点      luna_metadata_sdk：NextMoeService.searchWorks/fetchWorkById
                          TwoDFanService.searchSubjects/fetchSubjectById
```

🔴 聚合层**只做编排**：不打分、不改标题、不翻译。打分/中文优先/标签过滤全在站点服务里
（`_parseDetail`），否则同一部作品会在「添加页一键抓取」和「全站搜索」里显示成两个名字。

## 4. 两个站点的关键契约（实测，别再摸索）

### 4.1 鲲 = NextMoe catalog（**不是** kungal.com）

`www.kungal.com` 自己的 REST（`/api/search`、`/api/galgame/search`）2026-10-24 实测
**全部登录墙**（`{"code":205,"用户登录失效"}`）。鲲的正确入口是 NextMoe 开放 API
（鲲生态的官方数据上游），补丁站的鲲源走的也是它。

**必须两次请求，不能逐条打详情**：

```
GET /v2/catalog/search?object=work&q=…&nsfw=true        → items[]（只有身份内核）
GET /v2/catalog/works?ids=68,99,67&nsfw=true
      &include=titles,covers,companies,ratings,tags      → 完整卡片数据
```

- 第一条响应**没有封面/评分/发售日**，直接铺网格会得到一排没图的卡；
- 批量端点**返回顺序 ≠ 传入顺序**（实测传 68,99,67,65 回来 65 开头）⇒ 必须按搜索 id 顺序重排，
  否则「最相关」那条会随机沉底；
- 限流 1100ms / 55 次每分：两次请求 = 一页 20 条，够用且不会触顶。

### 4.2 2DFan = 一次请求

搜索页 `.subject-card` 本身就有封面 / 评分（**5 分制**，`4.6` → ×2 归一 9.2）/ 评价数
（`"197人评价"` → 正则取数字）/ 品牌 / 发售日，所以列表**不做逐条补详情**（20 条 = 20 次
100KB+ 的 HTML，既慢又容易被限流）。域名回退沿用 `_getHtml` 的运行期自愈。

## 5. 实现位置

| 文件 | 内容 |
|------|------|
| `lib/packages/luna_metadata_sdk/lib/models/site_search_hit.dart`（新） | `SiteSearchSource`（鲲/2DFan）+ `SiteSearchHit`（卡片态/详情态共用，`copyWith` 回填）+ `SiteSearchSourceResult`（失败≠没找到） |
| `nextmoe_service.dart`（改） | 新增 `searchWorks` / `fetchWorkById` / `kungalWorkUrlOf`（作品页直链） / `kungalSearchUrlOf`（兜底） / `_isNsfwWork` / `parseSearchHitForTest`。**既有方法一行未改** |
| `two_dfan_service.dart`（改） | 新增 `searchSubjects` / `fetchSubjectById` / `_hitFromSearchCard` / `parseSearchHitForTest` |
| `lib/services/site_search/site_search_service.dart`（新） | 聚合：并发、隔离、缓存（5 分钟）、防重入、`fetchDetail` 字段兜底 |
| `lib/pages/site_game_detail_page.dart`（新，**v2 改原生版式**） | 组合原生构件：`GameDetailHeader`（六动作灰置）+ 原生两栏（简介 5 / 截图 6）+ 原生封面样式 + `ScreenshotCarousel`。顶栏保留 来源徽章 / 入库 / 打开原站 |
| `game_detail_header.dart`（改，只加不改） | 新增 `likeEnabled` / `feedbackEnabled`（默认 true 零回归），`_buildIconAction` 支持 disabled |
| `discover_page.dart`（改） | 搜索框内「全站」chip、概览条、混排网格、来源角标、点击分流、站外详情覆盖层 |
| `explore_hall_page.dart`（改） | 透传 `onImportExternal` |
| `join_page.dart`（改） | 新增 `initialTitle` + `onInitialTitleConsumed`（`didUpdateWidget` 消费，State 是 Offstage 保活） |
| `main_container.dart`（改） | `_pendingJoinTitle` 一次性信箱 + `_onImportFromSiteSearch` 跳添加页 |
| `test/services/site_search_service_test.dart`（新） | 离线：模型口径、聚合隔离/缓存/防重入、两站映射（真实页面结构 fixture） |
| `lib/services/site_search/site_search_ranker.dart`（新，第二轮） | **标题相关性打分 + 过滤 + 跨源混排 + 每源 Top1 兜底**（见 §6.1） |
| `test/services/site_search_ranker_test.dart`（新，第二轮） | 重排器的离线单测（fixture 全部来自实测接口原文） |

## 6. 关键设计决策

| 决策 | 理由 |
|------|------|
| 一次性动作，不做模式开关 | 用户拍板；站外请求不该每次敲键盘都发 |
| 混排 + 来源角标（不分两区） | 用户拍板；靠角标区分来源 |
| 站外结果不受第二行筛选影响 | 用户点全站搜索就是要看站外，被标签/会社/安装态筛掉只会让人以为「站外一条都没有」 |
| 与库内同名去重 | 同一部作品画两张卡 = 用户以为有两部；库内那条有我们自己的详情与资源，更该保留 |
| 独立站点详情页，不复用 `GameDetailPage` **本体** | 那一页由 `GameRepository.getGameById`（PB 记录）驱动，拿不到就整页错误态；站外没有 PB 记录。**v2（用户拍板）：视觉复用原生构件** —— `GameDetailHeader` + 原生两栏版式，用不了的六动作统一灰置 |
| 「入库」= 跳添加页预填标题 | 用户拍板；⛔ 不新建第二条写库路径，入库仍走既有链路 |
| 详情拉失败不改 `detailLoaded` | 让 UI 能区分「加载失败（可重试）」与「这部作品真的没简介」 |
| **相关性重排在聚合层做，不改站点服务** | 站点接口没有「只搜标题」参数（实测 2026-11-11），客户端只能事后打分；放站点服务里会把「全站搜索」和「添加页一键抓取」两个场景的口径绑死 |
| **严格过滤**（用户拍板）：0 分条目直接丢弃 | 搜「缘之空」40 条 → 2 条；用户明确要精准而非「看起来满」 |
| **每源 Top1 兜底保留** | 解决「标题语言不对齐」的必然误杀：搜「缘之空」时 2DFan 那条正确结果是 `ヨスガノソラ`（日文原名，不含关键词）。实现是**该源一条都没命中时**才保留其原始第 1 名（`kScoreTop1Fallback = 1`，恒排在真命中之后），不是无条件保留 |

### 6.1 标题相关性重排（`site_search_ranker.dart`，第二轮）

**背景**（用户报障）：搜「缘之空」/「AIR」时结果五花八门。根因**不在探索库原生搜索**
（截图里噪音卡片全带站外角标），而在两个站点接口都是全文模糊匹配（见文件头注释）。

**打分**：`title / originalTitle / aliasNames` 三者取最高档 ——
完全相等 100 → 前缀 85 → 词边界包含 70 → 其余 0 分丢弃。
🔴 **拉丁关键词强制词边界**（`\bAIR\b`）：否则 `FairlyLife` 因含 "air" 冒充命中；
CJK 用子串（`AIRメイド` 仍算命中，因为 AIR 后面是假名不是拉丁字母）。

**排序**：分数降序 → 同分站点原始序号在前 → 跨源混排。
**兜底**：每源原始第 1 名无条件保留（防译名误杀）。

**实测效果**（真实接口数据，非手抄 fixture）：

| 关键词 | 站点原始 | 重排后 | 置顶 |
|---|---|---|---|
| 缘之空 | 40 条噪音 | **2 条** | 鲲「缘之空」+ 2DFan「ヨスガノソラ」 |
| AIR | 40 条噪音 | **19 条** | 鲲「鸟之诗」(原名 AIR) → 「AIR」→ 「Air」 |



## 7. 已知边界 / 风险

- **2DFan 是 HTML 抓取**：站点改版即失效，靠 `metadata_fetch.log` 的 `[2Dfan]` 前缀定位。
- **鲲的来源徽章只能到「鲲」**：NextMoe 是聚合目录，一条记录背后可能是 vndb/bangumi 等；
  我们展示的是 NextMoe 裁定后的数据，不再二次标注上游。
- **鲲的「打开原站」= 作品页直链**：实测（2026-11-11 curl）NextMoe API 的 work id
  与 kungal.com 网页 id **同一体系**——`/galgame/51`「缘之空」、`/galgame/2156`
  「鸟之诗 | AIR」。`NextMoeService.kungalWorkUrlOf(id)` 生成直链；id 缺失才兜底
  站内搜索页（`kungalSearchUrlOf`，现仅兜底用）。早期版本误落搜索页，已修
  （SITE-SEARCH-LINK，同日第四轮）。
- **站外结果无分页**：每次最多 20 条/源（v1）。要更多得加「加载更多」，需评估限流。
- **NSFW**：站外结果不按内容分级过滤（站点返回什么就显示什么），封面仍走 `NsfwImage`
  按全局设置模糊；与探索库现有行为一致。
- **概览条不显示「被筛选隐藏」的站外条数**：站外结果不参与筛选，所以不存在这回事。

## 8. 验证记录（2026-11-11）

- ✅ 进程内 analyzer：SDK 3 文件 + 主工程 6 文件 + 测试 1 文件 **0 error**
  （`discover_page` 残留 3 条**存量** warning：两个 unused import + `_isSearching` 未读，
  均非本次引入，按最小变更原则未清理）。
- ✅ 行为探针 `flutter_tester`（gen_kernel 直跑 kernel，绕开 231 的 flutter_tools）：
  **83 PASS / 0 FAIL** —— 模型口径、聚合顺序、单源失败隔离、空结果≠失败、全失败不缓存、
  缓存命中、防重入、详情兜底、两站真实结构 fixture 映射（评分 ×2 / meta 标签剔除 / R18 / 排序）。
- ✅ 布局探针（4 屏）：1280 全量 / 960 窄窗 / 极简命中 / 2DFan 无 onImport
  **0 异常、0 零尺寸文本**；2DFan 无回调那屏文本数 23 vs 全量 24（差的正是被隐藏的「入库」按钮）。
- ✅ 真实接口连通性用 `curl` 验证（NextMoe search / works?ids / 2DFan 三镜像 200 + 20 张卡）。
- ⚠️ **未做**：`flutter analyze` / `flutter test` 全量（231）、真机走查（关联网页渲染、
  滚动混排顺序、入库跳转后的标题预填）。

### 8.1 事故复盘：整页灰屏（2026-11-11 02:0x）

**现象**：真机进探索页，内容区整块**纯灰**，只剩侧栏和「返回大厅」。release 模式下
`ErrorWidget` 就是一块灰底 —— 说明 `DiscoverPage.build` 抛了异常。

**根因**：`_contentTopPadding` 写成了自引用 getter。

```dart
// ❌ 错：getter 调用自己 → 无限递归
double get _contentTopPadding =>
    _contentTopPadding + (_siteBannerVisible ? 32 : 0);

// ✅ 对：原口径是 _topBarHeight + 16
double get _contentTopPadding =>
    _topBarHeight + 16 + (_siteBannerVisible ? 32 : 0);
```

探针实测栈帧：`StackOverflowError`，`#0..#N` 全是
`_contentTopPadding (discover_page.dart:1259:7)`，在 `LayoutBuilder` 构建时抛出。
**注意：这类错误 `dart analyze` 查不出来**（分析器不把 getter 自递归当错误），
行为探针也查不出来（那是纯逻辑），只有**把页面真的渲染一遍**才会暴露。

**为什么漏了**：上一轮的布局探针只覆盖了 `SiteGameDetailPage` 的 4 屏，
**没有覆盖 `DiscoverPage` 本身**。改动落在哪个页面的 `build`，就必须把那个页面整屏渲染一次。

**补救**：新增 `.workbuddy/probe_site_search/discover_probe.dart`，复现主壳
`Column[32 标题栏, Expanded(Row[176 侧栏, 内容])]`，跑 1280×720 / 1024×720 /
1440×900 / 带 onImportExternal 四屏；除「0 异常 / 0 零尺寸文本」外，额外断言
**搜索框里的「全站」胶囊必须存在**（否则 build 整体塌掉时文本数为 0 也会被误判为通过）。

已做负向对照：把 bug 放回去 → `FAIL=8`，4 屏全部 `MISSING-SITE-CHIP`；
修复后 → `FAIL=0`，4 屏 `LAYOUT OK`。**探针不是橡皮章。**


🔴 **不要再用 flutter_tester 跑真实网络**：`AutomatedTestWidgetsFlutterBinding` 是 FakeAsync，
真实 socket / Timer 永不完成（本次 `live_probe` 实测卡在首个 `await` 后直接退出；与
2026-11-04 2Dfan 那次同一结论）。网络验证用 `curl`，解析验证用离线 fixture。

### 8.2 第二轮：相关性重排验证（2026-11-11 晚）

- ✅ 进程内 analyzer：ranker / service / discover_page / ranker_test 四文件 **0 error**。
- ✅ 重排器探针 `ranker_probe.dart`（flutter_tester 直跑 dill）：**51 PASS / 0 FAIL** ——
  打分档位（相等/前缀/词边界包含/CJK 子串）、拉丁词边界（`FairlyLife` 0 分）、
  三字段取最高（别名命中）、每源 Top1 兜底、同分稳定序、空关键词原样通过。
  **负向对照**：把 `_latinAsWord` 换成 `contains` → 7 项失败（`FairlyLife` 冒充 AIR），探针有效。
- ✅ **真实数据端到端**：Python 抓取两站原始返回生成 fixture（`gen_real_fixture.py` →
  `real_probe.dart`），跑 ranker 全链路 —— 搜「缘之空」40→2、搜「AIR」40→19，
  置顶 = 鲲「鸟之诗」(原名 AIR) → 「AIR」→ 「Air」。
- ✅ 回归：行为探针 **83 PASS / 0 FAIL**（其中「聚合顺序」断言的假数据改为标题可命中，
  语义从「按站点顺序拼接」变更为「按相关性混排」）；探索页整屏渲染探针 4 屏 `LAYOUT OK`。
- ⚠️ `flutter test` 仍被 231 挡住；`test/services/site_search_ranker_test.dart` 待环境恢复后补跑。

### 8.3 第三轮：站外详情改原生版式验证（2026-11-11 晚）

- ✅ analyzer：`site_game_detail_page.dart` + `game_detail_header.dart` **0 error / 0 warning**。
- ✅ 渲染探针 4 屏 LAYOUT OK，断言必含：六原生按钮（获取/分享/补丁/上传/喜欢/反馈，
  其中「喜欢/反馈」文案在 Tooltip 里，探针需同时收集 Tooltip.message）、
  「游戏简介」「站外作品 · 只读」、来源徽章（数据来自 鲲/2DFan）、
  元数据（会社/格式化发售日/评分/2.5k）、R18 徽章、标题。
- ✅ 负向对照：简介标题临时改词 → 4 屏各 1 条 MISSING（FAIL=4），恢复后 FAIL=0。
  🔴 教训：负向对照的改词**不能只加后缀**——断言是 `contains`，加后缀照样命中
  （首次对照 `游戏简介→游戏简介NEG` 假绿），必须换成不含原词的文案。
- ⚠️ `GameDetailHeader` 加了参数但原生页零回归（默认 true）；原生 `GameDetailPage`
  本身一行未改。

## 9. ⛔ 不要动的地方

- `searchWorks` 的**两次请求 + 按搜索顺序重排**：改成逐条详情会因 1100ms 限流卡到 20 秒；
  去掉重排会让最相关的结果随机沉底。
- `_hitFromSearchCard` 的 **×2 归一**：2DFan 列表页是 5 分制，详情页也是 5 分制，
  两处口径必须一致（改一处 = 同一作品在列表和详情评分不同）。
- 聚合层的「**空结果 ≠ 失败**」与「**全失败不写缓存**」：前者决定提示条内容，
  后者决定断网后会不会被钉住 5 分钟。
- 🔴 `SiteSearchRanker` 的**拉丁词边界**（`_latinAsWord` 的 `\b` 正则）：改回
  `contains` 就是本轮用户报障的复现（`FairlyLife` 冒充 AIR）。CJK 不启用词边界
  是刻意的（假名前后天然是边界）。
- 🔴 **每源 Top1 兜底只保留 1 条**：改成每源多条「推荐」就是「适中」方案，
  用户拍板过严格过滤，别自作主张放宽。
- 🔴 归一化口径**两套并存是刻意的**：匹配用 `SiteSearchRanker._stripAll`
  （去标点，喂相等/子串判定）；与库内去重用 `discover_page._normalizeTitle`。
  合并成一套会让某一处判定翻转，改前先跑对应探针。
- 🔴 站外详情的 `ScreenshotCarousel` **`gameTitle` 必须传 null**：传了会挂
  `ScreenshotFetchService`（按标题后台抓截图回传 PB），站外作品不该触发。
- 🔴 `GameDetailHeader` 里**补丁按钮要灰置显示**必须 `onPatch: (){}` +
  `patchEnabled: false` —— `onPatch` 为 null 时整个按钮不渲染（header 内部约定）。
- `SiteSearchHit.uid` 必须是 `site:siteId`：两个站点的数字 id 会撞车，网格 key 与去重都靠它。
- 站外卡片的封面**必须**走 `PortableImageCacheManager`（2DFan 图床 `img.achost.top` 是
  Referer 白名单，无头一律 404）。
- `main_container._pendingJoinTitle` 必须在消费后清空：否则同一部作品第二次「入库」时
  `initialTitle` 没变化，`didUpdateWidget` 不触发，标题不会被填上。
- 🔴🔴 `_contentTopPadding` **只能**由 `_topBarHeight + 16 (+ 32)` 算出，⛔ 写成
  `_contentTopPadding + …`（自引用 = 整页灰屏，见 §8.1）。所有「避开顶栏」的 padding
  共 5 处（离线视图 / 错误视图 / 空态 / 网格 / 卡片列表）都走它，改口径只改一处。

## 10. Phase 2（未做，供后续评估）

- [ ] 概览条里点某个源筛选只看它
- [ ] 站外结果「加载更多」（需先确认鲲批量端点 id 上限与限流余量）
- [ ] 站外命中标记「探索库已有」（目前是直接隐藏，用户看不到这条信息）
- [ ] 把站外命中写进 `metadata_cache` 复用（当前每次全站搜索都重新请求）

## 11. 后续小改（已做，记档）

- **空态 CTA（SITE-SEARCH-EMPTY-CTA，第五轮）**：库内搜索 0 结果且带关键词时，
  空态主按钮「查看全部游戏」换「全站搜索」（直接 `_runSiteSearch`）；纯筛选
  （无关键词）保留原按钮——站外没法空词搜。实现是 `_buildEmptyView` 里 6 行三元，
  ⚠️ 渲染探针的空态场景在本环境**不可达**（探针 PB 恒错误态），改动只靠 analyzer
  + 代码走读 + 真机走查，改这里时别信探针能兜底。
