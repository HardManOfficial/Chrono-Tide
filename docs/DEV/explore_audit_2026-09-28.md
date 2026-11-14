# 探索库代码审查报告（安全 / 性能 / 功能扩展）

> **审查类型**：只读审计，未改动任何业务代码。  
> **审查范围**：探索大厅（Explore Hall）全链 —— 页面、4 个服务、8 个板块 UI、模型、仓库、原探索库页。  
> **审查日期**：2026-09-28  
> **基线**：工作区 HEAD + 未提交改动 `lib/big_picture/widgets/focus_glow.dart`（与本次审查无关）。  
> **结论分级**：P0 阻断 / P1 严重 / P2 一般 / P3 建议。  
> **未验证项**：全部结论基于静态代码阅读，**未做真机验证、未跑 analyze/test**（沙箱内 Dart VM 无法创建子进程）。标注 ⚠️ 的条目需真机复现确认。

---

## 0. 结论先行

**总体判断：探索库的安全基线是及格的，性能有一处结构性瓶颈，功能扩展空间很大。**

| 维度 | 评级     | 一句话                                                         |
| -- | ------ | ----------------------------------------------------------- |
| 安全 | **B**  | 无 P0；1 个 P1（命令注入面）+ 1 个 P1（密钥硬编码）；URL 白名单、filter 转义、原子写都做得对 |
| 性能 | **C+** | 无 P0；**1 个 P1 结构性瓶颈**（预热串行 × 全量遍历）+ 若干 P2 重复计算              |
| 功能 | **C**  | 骨架完整但深度不足：7 板块中 2 个是只读展示、1 个是静态文本；缺搜索/筛选/分页等基础能力            |

**最该动的三件事（按性价比排序）**：

1. 🔴 **`_reaggregate()` 每次全量遍历 + 预热串行 6000 次**（P1，性能）——探索库规模上到 2000+ 时首屏卡顿的主要来源。
2. 🔴 **`openExternal` 的 `cmd /c start` 二次解析**（P1，安全）——虽然被 scheme 白名单收窄，但 Windows 上仍是命令注入面。
3. 🟡 **探索大厅缺搜索/筛选**（P2，功能）——用户进大厅看到 7 个板块，但想找特定游戏必须点进探索库，动线割裂。

---

## 1. 安全漏洞

### 1.1 🔴 P1：`openExternal` 的 `cmd /c start` 存在命令注入面

**位置**：`lib/services/website_bookmark_service.dart:190-205`

```dart
static Future<bool> openExternal(String url) async {
  final normalized = normalizeUrl(url);
  if (normalized == null) return false;
  await Process.start(
    'cmd',
    ['/c', 'start', '', normalized],   // ← normalized 交给 cmd 二次解析
    runInShell: false,
    mode: ProcessStartMode.detached,
  );
```

**为什么有风险**：`runInShell: false` 只保证 Dart 不把参数拼成命令行字符串——但 `cmd.exe` 本身会**再次解析**它收到的参数。`cmd` 的元字符（`&`、`|`、`^`、`<`、`>`、`%VAR%`）在其解析阶段仍然生效。`normalizeUrl` 只校验 scheme 与 host 非空，**不剔除 URL 中的元字符**：

```dart
static String? normalizeUrl(String raw) {
  ...
  return uri.toString();   // 原样返回，未做元字符清洗
}
```

**可达路径**：

- `lib/widgets/explore_hall/website_section.dart:294` —— 点击站点卡片
- `lib/widgets/explore_hall/website_section.dart:470` —— 菜单「打开」
- `lib/pages/explore_hall_page.dart:117` —— 月历条目未匹配本地库时外跳 KUNGAL

前两条的 URL 来自**用户自己添加**（`data/websites.json`）——威胁模型较弱；但第三条的 URL 来自**远程数据**，见下条。

**影响范围**：任意构造出 `https://x.com/?a=1&b=2` 形态的 URL 时，`cmd` 会把 `&` 解释为命令分隔符。⚠️ 实际触发需构造出在 `start` 语义下能逃逸的 payload（`start` 对第一个带引号参数的处理有特殊性），**未做真机验证**——但这是公认的危险模式，不应保留。

**改进建议**（按推荐度）：

1. **改用 `explorer.exe` 或 `rundll32`**：`Process.start('explorer', [normalized])` —— `explorer` 不做 shell 元字符解析，语义等价（都是「用默认程序打开」）。
2. **用 ShellExecute 的 Dart 封装**：`url_launcher` 包（但这违反项目零新依赖策略）。
3. **最低成本缓解**：在 `normalizeUrl` 增加元字符拒绝：
   ```dart
   if (RegExp(r'[&|^<>"\r\n]').hasMatch(v)) return null;
   ```
   注意 `&` 在正常 URL query 里合法（`?a=1&b=2`）——**这会误伤合法 URL**。所以方案 3 只在「参数交给 cmd」这个前提下才成立，本质是治标。**推荐方案 1。**

> 方案的 §10 已把此项登记为 P2 风险。本次审查认为应**升为 P1**——因为 `explore_hall_page.dart:117` 把**远程数据**（KUNGAL `detailUrl`）也送进了这条链路。

---

### 1.2 🔴 P1：NextMoe 生产密钥硬编码在 SDK 源码常量中

**位置**：`lib/packages/luna_metadata_sdk/lib/services/nextmoe_service.dart:60`

```dart
static const String apiKey = '<REDACTED>';
```

**消费点**：`lib/services/kungal_calendar_service.dart:496` —— 月历每次请求都带这个 Bearer。

**影响范围**：

- 该密钥**已随源码分发**（`chrono-tide-opensource/` 镜像、打包 exe 内嵌）。任何解包 exe 或拉取镜像的人都拿到生产密钥。
- 密钥权限是 `catalog:read`（只读），泄露后果限于**配额被刷爆**（free 档 60 次/分 · 5 万次/日）→ 全体用户月历失效。
- SDK 注释（第 27 行）明确写了「桌面应用无服务端，与 TouchGal/Hikarinagi 同款做法」——**这是有意识的取舍，不是疏漏**。

**改进建议**（需权衡，不宜单方面改动）：

1. **短期**：向 NextMoe 申请**配额隔离**（如按 UA 或按 IP 限流），降低单密钥被刷爆的爆炸半径。
2. **中期**：增加**客户端侧限流器**（`kungal_calendar_service.dart` 已有 `limitPages` 防御，但无跨进程频控）。当前 24h 磁盘缓存实际上已把频率压得很低——**风险主要是恶意的**，不是设计缺陷。
3. **长期**：若 NextMoe 支持，改为**按设备签发短期 token**。

> 这条属「已知取舍」，**建议不动代码**，改为与 NextMoe 侧沟通配额策略。列出是因为审查需要完整暴露。

---

### 1.3 🟡 P2：`website_icon_service` 的 SSRF 面（有限）

**位置**：`lib/services/website_icon_service.dart:52-80`

```dart
Future<String?> fetchSiteIcon(String url) async {
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return null;
  ...
  final fromHtml = await _extractIconUrlFromHomepage(host);  // 抓 https://$host/
```

**风险**：

- `_extractIconUrlFromHomepage` 对**任意 host** 发起 GET（第 271-278 行），并 `uri.resolve(href)` 解析出**任意 URL**（第 298 行）再下载（第 68 行）——理论上可指向内网地址（`http://192.168.1.1/`）或 `file://`。
  - 实际缓解：`_downloadBytes` 走 Dio，`file://` 不被支持；URL 只能经 `normalizeUrl` 从用户输入进入，用户是自己的攻击者。
- **真正的问题是无上限的响应体**：`_downloadBytes`（第 251-266 行）先**完整下载**再判断大小：

```dart
final data = resp.data;
if (data == null || data.isEmpty || data.length > _maxBytes) return null;  // ← 已经下载完了
```

**影响范围**：恶意/异常站点返回 500MB 响应 → Dio 先全量读进内存 → 才判断超限。6s `receiveTimeout` 能兜住大部分情况，但**慢速大文件**仍可撑爆内存。首页 HTML 抓取（第 271 行）同样无大小上限。

**改进建议**：

1. `_downloadBytes` 改用 `ResponseType.stream` + 累积到 `_maxBytes` 即 `cancel`：
   ```dart
   final resp = await _dio.get<ResponseBody>(url, options: Options(
     responseType: ResponseType.stream,
     validateStatus: (s) => s != null && s >= 200 && s < 400,
   ));
   final bytes = <int>[];
   await for (final chunk in resp.data!.stream) {
     bytes.addAll(chunk);
     if (bytes.length > _maxBytes) return null;   // 提前中断
   }
   ```
2. 首页 HTML 抓取加 `Options(headers: {'Range': 'bytes=0-262143'})` 或用 stream 限定 256KB。

---

### 1.4 🟡 P2：`_extractIconUrlFromHomepage` 正则无长度限制，存在 ReDoS 面

**位置**：`lib/services/website_icon_service.dart:283-291`

```dart
final re = RegExp(
  '<link[^>]+rel\\s*=\\s*["\']?[^"\'>]*icon[^"\'>]*["\']?[^>]*href\\s*=\\s*["\']([^"\']+)["\']',
  caseSensitive: false,
);
```

**风险**：`[^>]+` 与 `[^>]*` 在同一字符类上重复，遇到**大量 `<link` 但无 `>`** 的畸形 HTML 会退化为回溯爆炸。`re2` 是第二个正则（第 288 行），同样形态。

**影响范围**：仅当抓取到恶意 HTML 时触发；6s `receiveTimeout` 限制了输入量。**实际风险低**。⚠️ 未做 ReDoS 压测验证。

**改进建议**：

1. 抓取前截断 HTML：`final html = resp.data!.substring(0, min(resp.data!.length, 512 * 1024));`
2. 或把 `[^>]+` 改为 `[^>]{0,512}` 加显式上限。

---

### 1.5 🟢 P3：`website_icon_service.dart:86` 上方残留重复注释（代码卫生）

**位置**：`lib/services/website_icon_service.dart:82-92`

```dart
  /// 清除失败标记（用户手动点「自动获取」重试时用）
  void clearFailure(String url) =>
      _failedHosts.remove(Uri.tryParse(url)?.host ?? '');

  /// 清除失败标记（用户手动点「自动获取」重试时用）      ← 重复
  /// ICO 转可解码图片：返回 PNG 字节（图标内嵌 PNG 时直接切片）或
  @visibleForTesting
  static List<int>? decodeIco(List<int> bytes) {
```

**影响**：无功能影响，`decodeIco` 自己的文档注释第一行被上一段的重复行挤占，可读性受损。

**改进建议**：删掉第 86 行的重复注释。

---

### 1.6 ✅ 做对了的部分（避免误改）

审查中确认以下安全措施**实现正确，不要动**：

| 项              | 位置                                                                                             | 说明                                                                                            |
| -------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| PB filter 转义   | `game_repository.dart:66, 275`                                                                 | `PbFilter.containsFilter('title', searchQuery)` 统一转义，防布尔盲注 ✅                                  |
| URL scheme 白名单 | `website_bookmark_service.dart:176-186`                                                        | 只放行 http/https，拒绝 `javascript:` / `file:` ✅（单测 `website_bookmark_service_test.dart:45-53` 覆盖） |
| 原子写            | 全链 5 处（websites / daily_recommendation / kungal_calendar / explore_warmup / discover_metadata） | 一律 `tmp → rename`，Windows 上 rename 覆盖目标 ✅                                                     |
| 路径安全           | `PathHelper.dataDir` 统一拼装                                                                      | 无用户可控路径拼接 ✅                                                                                   |
| `data:` URL 拒绝 | `website_icon_service.dart:295`                                                                | 防 data URI 撑爆 ✅                                                                               |
| ICO 解码边界       | `website_icon_service.dart:94-186`                                                             | 每处 `sublist` 前都有 `> bytes.length` 检查 ✅（单测覆盖）                                                  |
| NSFW 打码        | `hall_cover_image.dart:47`                                                                     | 走 `NsfwImage.network`，但**见 §3.4 的缺口**                                                         |

---

## 2. 性能优化

### 2.1 🔴 P1：预热期间 `_reaggregate()` 全量遍历，且预热是串行的

**位置**：`lib/services/explore_calendar_service.dart:141-153, 194-209`

```dart
void _reaggregate() {
  _byDate.clear();
  _undated.clear();
  for (final g in _games) {                       // ← 每次全量遍历
    final meta = DiscoverMetadataService.instance.getMetadata(g.id);
    final date = CalendarGrid.parseIsoDate(meta?.releaseDate);
    ...
  }
}

for (final g in missing) {
  ...
  _warmFilled++;
  if (_warmFilled % 5 == 0 || _warmFilled == _warmTotal) {
    _reaggregate();          // ← 每 5 个游戏重跑一次全量 O(N)
    notifyListeners();
  }
}
```

**复杂度**：`O(N/5) × O(N)` = **O(N²/5)**。

| 探索库规模   | `_reaggregate` 调用次数 | 总遍历次数   |
| ------- | ------------------- | ------- |
| 250 部   | 50                  | 12,500  |
| 1,000 部 | 200                 | 200,000 |
| 2,000 部 | 400                 | 800,000 |

**叠加串行预热**：`missing` 循环里 `await DiscoverMetadataService.instance.ensureMetadata(...)` —— `DiscoverMetadataService._fetchWithGlobalLock`（`discover_metadata_service.dart:233-253`）是**全局并发=1**，每个游戏要跑 5 源抓取。1000 个缺失 → 1000 次串行网络抓取，**每 5 个还插一次 O(N) 遍历 + 全树 notifyListeners**。

**影响范围**：`startWarmup` 由 `explore_hall_page.dart:90` 在 `initState` 触发，**大厅首次进入就启动**。同时：

- `_reaggregate` 的重建 `_byDate` 会让 `gamesByDate`、`undatedGames`、`datedCount` getter 全部失效
- `notifyListeners()` 触发 `RelatedTopicsSection`（`related_topics_section.dart:185` 监听 `widget.service`）与 `DailyRecommendationService._onCalendarChanged` 双双重建
- 每次 notify 都是全树 rebuild

**改进建议**（分三层，可独立落地）：

**(a) 增量聚合替代全量重算** —— 预热时只处理新拿到日期的那一个游戏：

```dart
void _aggregateOne(GameModel g, DateTime? date) {
  if (date == null) { if (!_undated.contains(g)) _undated.add(g); return; }
  _byDate.putIfAbsent(date, () => []).add(g);
}
```

预热循环里对 `gained` 的那几个调用 `_aggregateOne`，把 `notifyListeners` 改成**节流**（如 500ms 一次）而非每 5 个一次。

**(b) 提高预热批次**：`'% 5'` → `'% 25'` 或按时间节流，把 O(N²/5) 降到 O(N²/25)。

**(c) 预热并发化（收益最大、风险最高）**：`DiscoverMetadataService._fetchWithGlobalLock` 的「全局并发=1」是为**避免打爆源站**（见其类注释）。若改并发，需配合：

- 每源站独立限流（而非全局一把锁）
- 预热优先级低于用户主动触发的抓取

> ⚠️ **建议先做 (a)+(b)**——纯本地计算优化，零网络风险；(c) 需评估源站承受能力后再动。

---

### 2.2 🟡 P2：`DailyRecommendationService._generate` 同步构造全量候选

**位置**：`lib/services/daily_recommendation_service.dart:136-162`

```dart
void _generate(ExploreCalendarService calendar) {
  final meta = DiscoverMetadataService.instance;
  final candidates = [
    for (final g in calendar.games)                    // ← 全量 O(N)
      RecommendedCandidate(
        ...
        rating: meta.getMetadata(g.id)?.rating,        // ← 每次 Map 查找
        voteCount: meta.getMetadata(g.id)?.voteCount,  // ← 重复查找
      )
  ];
  final plan = DailyRecommendationPlanner.plan(candidates: candidates, day: DateTime.now());
```

**问题**：

1. `getMetadata(g.id)` 被**调用两次**（第 146、147 行），可合一次。
2. 整个 `_generate` 在主 isolate **同步执行**，`DailyRecommendationPlanner._buildPool` 还要再遍历一遍（构建 tag/dev 频次表）。
3. 触发时机是**任何** `notifyListeners`（`_onCalendarChanged`），虽有 `!_hasToday` 前置门，但预热结束时那次 notify 一定会跑完整流程。

**影响范围**：2000 部游戏 → 2000 次对象构造 + 2 次 Map 查找 + 2 遍遍历。单次耗时估计 **< 50ms**，真实场景下**不构成卡顿**。⚠️ 未实测。

**改进建议**（低成本）：

- 合并两次 `getMetadata` 调用为一次局部变量。
- 若实测有卡顿，再考虑挪到 `compute()`。

---

### 2.3 🟡 P2：`RelatedTopicsSection` 每次 build 重建全量 `byId` 映射

**位置**：`lib/widgets/explore_hall/related_topics_section.dart:190`

```dart
builder: (context, _) {
  final plan = _daily.plan;
  final items = plan?.items ?? const <RecommendedGame>[];
  final byId = {for (final g in widget.service.games) g.id: g};   // ← 每次 build 重建
```


**问题**：`widget.service.games` 是 `List.unmodifiable(_games)`（`explore_calendar_service.dart:53`），**每次 getter 调用都新建一个不可变包装**；然后这里再全量遍历建 Map。

**叠加效应**：这个 builder 监听 `Listenable.merge([_daily, widget.service])`——**两个服务任一 notify 都会重建**。预热期间每秒可能 notify 多次 → 每次 O(N) 建 Map。

**改进建议**：

- `ExploreCalendarService` 暴露一个**缓存好的** `Map<String, GameModel> gamesById`，在 `_reaggregate` 时一并构建（一次 O(N)，之后复用）。
- 或本组件用 `useMemo` 式缓存（Flutter 里靠 State 字段 + 显式失效）。

---

### 2.4 🟡 P2：`GameRepository.getAllGames` 的 `Future.wait` 缺并发上限保护

**位置**：`lib/repositories/game_repository.dart:164-191`

```dart
for (var i = 0; i < remainingPages.length; i += maxConcurrent) {
  final batch = remainingPages.skip(i).take(maxConcurrent).toList();
  final results = await Future.wait(batch.map((p) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 2));   // ← 阻塞整批
      ...
```

**问题**：`maxConcurrent = 3` 的批次内，任一页失败会 `await 2s` 退避——而这 2 秒**阻塞了整个批次**（`Future.wait` 等所有）。最坏情况：每批都有一页失败 → N/3 批 × 2s 纯等待。

**影响范围**：探索库全量加载（`explore_calendar_service.dart:121` 与 `discover_page.dart:330` 都用）。1000 部 = 10 页 = 4 批；若每批都退避，多等 8s。

**改进建议**：

- 失败页从批次里**摘出来**放进「重试队列」，批次其余页正常推进；全部批次跑完后统一重试。
- 或把退避改成 `Future.delayed` 与后续页请求并行（需要重构为任务队列而非批次）。

---

### 2.5 🟡 P2：`debugPrint` 密度过高（真机 release 下是 no-op，debug 下拖慢）

**统计**（探索链路）：

| 文件                               | `debugPrint` 条数     |
| -------------------------------- | ------------------- |
| `game_repository.dart`           | 37                  |
| `game_model.dart`                | **19**（含**逐条**解析日志） |
| `discover_metadata_service.dart` | 12                  |
| `explore_calendar_service.dart`  | 6                   |

**典型问题**：`game_model.dart:54-86` 的 `fromPBRecord` 对**每条记录**打印 8 行日志：

```dart
debugPrint('   🔍 解析游戏记录: id=${record.id}');
debugPrint('      → title: "$title"');
... // 共 8 条
```

**影响范围**：全量加载 2000 条 → **16,000 行 debugPrint**。`debugPrint` 在 release 下确实被裁剪（`kReleaseMode` 时是空实现）——所以**不影响生产**。但在 **debug 模式下**，2000 次字符串插值 + 控制台 IO 是**实打实的开销**。

`game_repository.dart:85-90` 已经注意到这个问题并做了「只打前 3 条」的优化——但 `game_model.dart` 没有。

**改进建议**：

- 给 `fromPBRecord` 的逐条日志套上层开关（如 `if (_verboseParseLog)`），或直接降为批量汇总。
- 至少把 8 行压到 2 行。

---

### 2.6 🟢 P3：`kungal_calendar_service.ensureUpcoming` 逐月串行

**位置**：`lib/services/kungal_calendar_service.dart:141-151`

```dart
for (var i = 0; i < _upcomingMonths; i++) {       // 6 个月
  final ym = monthKey(DateTime(today.year, today.month + i, 1));
  await ensureMonth(ym, force: force);             // ← 串行 await
  ...
}
```

**影响范围**：首次点开「未发售」桶 → 6 次串行网络（有 24h 磁盘缓存时是 6 次文件读取）。有缓存时耗时可忽略；无缓存时约 6 × 500ms = 3s。

**改进建议**：`await Future.wait([for (...) ensureMonth(ym)])` —— 6 个月之间无依赖。注意 `_ensure` 的 `_fetching` 集合能防重复，并发安全。

---

### 2.7 🟢 P3：`kungal_calendar_service` 的 `_getNextmoe` 每次新建 `HttpClient`

**位置**：`lib/services/kungal_calendar_service.dart:490-512`（与 `_fetchBody:258-278` 同款）

```dart
HttpClient? client;
try {
  client = HttpClient();
  ...
} finally {
  client?.close();
}
```

**影响**：每次请求新建 + 关闭 `HttpClient`，丢失连接池复用（TLS 握手重来）。月历请求频率低（24h 缓存），**实际影响很小**。

**改进建议**：抽成单例 `HttpClient` 或静态懒加载。**优先级低**。

---

### 2.8 ✅ 做对了的部分

| 项        | 位置                                    | 说明                                               |
| -------- | ------------------------------------- | ------------------------------------------------ |
| 列表去重     | `game_repository.dart:195-200`        | 并发完成顺序不定 → 按 id 去重再排序，正确 ✅                       |
| 分页驱动     | `game_repository.dart:153`            | 用服务端 `totalPages` 而非「返回条数==perPage」，免疫钳制 ✅       |
| 预渲染窗口    | `discover_page.dart:1254`             | `cacheExtent: 1200`（从 4000 降下来，避免占满 download 槽）✅ |
| 元数据通知去抖  | `discover_page.dart:207-214`          | 500ms 去抖，避免 250 次 notify → 250 次 filter ✅        |
| 焦点轮播隔离   | `related_topics_section.dart:123-131` | Timer 回调 try/catch，异常不冒到 UI ✅                    |
| 磁盘缓存 TTL | 各级 24h / 7d / 30min 分层                | 合理 ✅                                             |

---

## 3. 功能扩展

### 3.1 🟡 P2：探索大厅缺搜索/筛选，与探索库动线割裂

**现状**：大厅 7 板块全是**浏览型**（月历 / 每日推荐 / 站点 / 系列 / 文档 / 随机一作 / 入口），**没有任何「搜一部游戏」的入口**。

**用户路径问题**：

```
想找"某部gal" → 大厅没有搜索框 → 必须点【开始探索】→ 进探索库 → 用搜索
```

而探索库的搜索实现（`discover_page.dart:418-500`）是**纯内存 filter**，已经具备完整能力（多关键词 AND、匹配标题/原标题/英文名/标签/会社）。**只是入口藏了一层。**

**改进建议**（性价比极高）：

1. 大厅顶部**大标题行右侧**（`explore_hall_page.dart:183` 的 `Spacer` 后）加一个搜索框，输入后自动 `_enterLibrary()` 并把 query 透传给 `DiscoverPage`。
2. `DiscoverPage` 已是 `StatefulWidget`，可加 `initialQuery` 参数（**注意：`discover_page.dart` 要求零改动**——若严格遵守，则改为大厅侧维护一个共享的搜索状态，进大厅时调用）。
3. 或者更轻量：大厅加个「搜索」快捷 chip，`onTap` 只调 `_enterLibrary()` + 聚焦搜索框。

> ⚠️ 这涉及 `discover_page.dart` 的改动边界，需先与开发者确认「零改动」是否可放宽。

---

### 3.2 🟡 P2：月历条目与本地库的匹配是 O(N) 线性扫，且只按标题精确匹配

**位置**：`lib/pages/explore_hall_page.dart:121-131`

```dart
GameModel? _matchLibraryGame(KungalCalendarGame item) {
  GameModel? find(String key) {
    if (key.isEmpty) return null;
    for (final g in _calendar.games) {                          // ← 每次 O(N)
      if (KungalCalendarGame.normalizeTitle(g.title) == key) return g;   // ← 每次重算 normalize
    }
    return null;
  }
  return find(item.normalizedKey) ?? find(item.normalizedOriginalKey);   // ← 最多 2 轮 O(N)
}
```

**问题**：

1. 每个条目最多 **2 次 O(N) 遍历**，且 `normalizeTitle` 对**每个游戏都重新计算**（含正则替换，不便宜）。
2. 只做**完全精确匹配**——「谜路2 人鱼传说」能匹配「谜路2人鱼传说」，但「人鱼传说」匹配不上「谜路2 人鱼传说」。

**影响范围**：每次点月历条目触发。2000 部 × 2 轮 × 正则归一化 ≈ 可感知的延迟（⚠️ 未实测）。

**改进建议**：

1. **预建索引**：`ExploreCalendarService` 里维护 `Map<String, GameModel>`（normalizedTitle → game），在 `_reaggregate` 时一并构建。查询降到 O(1)。
2. **降级匹配**：精确未命中时尝试 `contains` 兜底（注意可能误匹配，需谨慎）。

---

### 3.3 🟡 P2：系列合集只有「消费」没有「参与」

**位置**：`lib/widgets/explore_hall/series_section.dart`（整块）

**现状**：整表拉取 `fetchAllSeries()`（`series_repository.dart:116-136`）→ 横向卡片 → 点开看成员。**纯只读**。

**缺失的能力**：

- 系列卡片点了只弹成员列表，**成员条目点击无反应**（`series_section.dart:252-296` 的成员行**没有 onTap**）——用户看到自己有的游戏也不能跳进详情页。
- 「全部」弹层（`series_section.dart:363-413`）同样只展示，点选后只是打开成员弹层。

**改进建议**（按价值）：

1. **成员条目可点击 → 进详情页**：把 `_SeriesMembersDialog` 的每行接上 `onGameTap`（复用 `SeriesEntryModel.gameId`，与 `main_container._onNavigateToGameFromDetail` 同款通路）。**成本低、体验提升明显。**
2. 系列卡片加「我拥有的 / 共 N 部」角标 —— 需要 `LocalGameRegistry` 交叉查询。
3. 支持按系列名搜索（「全部」弹层已有 `_query` 过滤，`series_section.dart:328-333`，✅ 已实现）。

> 第 1 条是**明确的缺口**，不是增强——成员列表不可点是功能不完整。

---

### 3.4 🟡 P2：NSFW 打码在探索大厅**大面积缺席**

**位置**：`lib/widgets/explore_hall/hall_cover_image.dart:47-61`

```dart
return NsfwImage.network(
  networkUrl,
  contentKind: NsfwContentKind.cover,
  fit: fit, width: width, height: height,
  child: CachedNetworkImage(
    imageUrl: networkUrl,
    fit: fit, memCacheWidth: 200,          // ← 无 cacheManager
    ...
```

对比探索库的正确写法（`discover_page.dart:1414-1441`）：

```dart
return NsfwImage.network(
  coverUrl,
  contentKind: NsfwContentKind.cover,
  detectOnDemand: true,        // ← 关键：开启按需检测
  decodeWidth: 480,
  diskCacheWidth: 800,
  child: CachedNetworkImage(
    cacheManager: PortableImageCacheManager(),   // ← 关键：检测靠它查落盘文件
    ...
```

**三处缺口**：

| 缺口                                                  | 后果                                                                                                                                      |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 缺 `detectOnDemand: true`                            | 网络图**永远不会入队检测**（`nsfw_image.dart:549`: `if (!widget.detectOnDemand && widget.isNetwork) return;` + `:637` `_hasAutoDetectPath` 为 false） |
| child 缺 `cacheManager: PortableImageCacheManager()` | 落盘走系统盘 `DefaultCacheManager`，检测服务查不到文件                                                                                                  |
| 无 `decodeWidth`/`diskCacheWidth`                    | 与检测侧的解码尺寸口径不一致                                                                                                                          |

**影响范围**：**所有走 `HallCoverImage.network` 的地方** ——

- 月历条目封面（`calendar_section.dart:515`）
- 每日推荐大卡 + 列表行（`related_topics_section.dart:293, 481`）
- 系列合集卡片（`series_section.dart:153, 268, 389`）
- 文档区随机一作（`docs_section.dart:336`）

**结果**：探索大厅里**所有云端封面都不打码**（除 `NsfwImage` 自带的整图模糊路径，但那条路径需要 `_detection != null`，而从未入队 → 永不触发）。

> ⚠️ **本条是本次审查最重要的功能发现**。探索大厅是**默认首界面**，用户一进来就面对未处理的云端封面 —— 与「纯净模式」的产品承诺不一致。**建议按 P1 处理**（虽然归类在「功能扩展」，因为它表现为功能未生效而非崩溃）。

**改进建议**：把 `hall_cover_image.dart` 的 `NsfwImage.network` 调用对齐 `discover_page.dart:1414` 的三个参数（`detectOnDemand` / `cacheManager` / `decodeWidth+diskCacheWidth`）。**一行改动，一处修复，全场生效。**

---

### 3.5 🟢 P3：月历无「只看本地已有」过滤

**现状**：`calendar_section.dart` 的四桶视图全部展示 KUNGAL 全量数据。用户看到 20 部当周发售，但**不知道自己库里有没有**。

**改进建议**：面板标题行加一个筛选 chip「仅显示已入库」。数据侧复用 §3.2 的匹配索引。与「点击已入库条目进详情」形成闭环。

---

### 3.6 🟢 P3：每日推荐无「为什么推荐给我」的解释入口

**现状**：副标题显示 `plan.label`（如「「恋爱」标签 · 按星级排序」，`related_topics_section.dart:198`）——**机制已对用户透明**，做得不错。

**但缺**：点击标签无法**看该维度的完整排名**（当前只展示 Top 8，`today_recommendation.dart:156` `takeCount = 8`）。

**改进建议**：副标题的 `plan.label` 做成可点击 → 弹出该维度 Top 50 列表。数据侧 `DailyRecommendationPlanner.planFor` 已支持任意 `take`，只需 UI 加参数。

---

### 3.7 🟢 P3：文档区「动态」tab 是硬编码占位

**位置**：`lib/widgets/explore_hall/docs_section.dart:176-179`

```dart
Center(child: Text('用户动态 · 敬请期待（二期上线）', style: AppStyles.microCaption)),
```

**现状**：明确标注「二期」，属**已知规划**，非缺陷。

**若要做**：数据侧可复用 `UpdateService`（其他三个 tab 已用它，见 `docs_section.dart:73`）或接 PB 的公告集合。

---

### 3.8 ✅ 已经做好的功能（不要重复造）

| 功能       | 位置                                  | 状态                                |
| -------- | ----------------------------------- | --------------------------------- |
| 系列名搜索    | `series_section.dart:328-333`       | ✅ 已有                              |
| 站点图标三级回落 | `website_icon_service.dart:60-66`   | ✅ HTML → favicon.ico → DuckDuckGo |
| 用户上传图标   | `website_icon_service.dart:219-244` | ✅ 有                               |
| ICO 解码   | `website_icon_service.dart:94-186`  | ✅ 含内嵌 PNG + DIB 包装                |
| 四桶月历视图   | `calendar_section.dart:34`          | ✅ 对齐 KUNGAL 四视图                   |
| 每日推荐确定性  | `today_recommendation.dart:164-193` | ✅ 同数据同结果                          |
| 失败点击重试   | 全链多处                                | ✅ 月历/推荐/探索库都有                     |
| 通知 tab   | `docs_section.dart:194-211`         | ✅ 走 UpdateService                 |

---

## 4. 建议的落地顺序

### 第一批（本周，低风险高收益）

1. **§3.4 NSFW 打码缺口** —— 改 `hall_cover_image.dart` 3 个参数，**一处修复全场生效**。最高优先级。
2. **§1.5 重复注释清理** —— 1 行删除。
3. **§2.5 `game_model.dart` 日志降噪** —— 8 行压 2 行，debug 模式提速。
4. **§3.3 系列成员可点击** —— 补 `onTap` 接详情页。

### 第二批（需评估）

1. **§1.1 `openExternal` 改 `explorer.exe`** —— 需真机验证 `explorer` 对各形态 URL 的行为。
2. **§2.1 增量聚合 + 批次调大** —— 改 `_reaggregate` 为增量，`'% 5'` → `'% 25'`。**纯本地计算，零网络风险。**
3. **§3.2 匹配索引** —— `ExploreCalendarService` 加 `gamesById` / `normalizedTitleIndex`，顺带修 §2.3。

### 第三批（需产品决策）

1. **§3.1 大厅搜索入口** —— 涉及 `discover_page.dart` 零改动边界，需先确认。
2. **§1.2 NextMoe 配额策略** —— 需与 NextMoe 侧沟通。
3. **§2.1(c) 预热并发化** —— 需评估源站承受能力。

---

## 5. 未验证项清单（诚实标注）

以下结论**基于静态代码阅读，未做验证**：

- ⚠️ §1.1 `cmd /c start` 的**实际可利用性**——未构造 payload 实测。
- ⚠️ §1.4 ReDoS 的**实际触发条件与耗时**——未压测。
- ⚠️ §2.1 预热在 **2000 部规模下的实际耗时**——未真机跑。
- ⚠️ §2.2 / §2.3 的**实际耗时量级**——估算值，未 profile。
- ⚠️ §3.2 匹配延迟的**可感知性**——未真机测。
- ⚠️ §3.4 NSFW 缺口的**实际表现**——未在纯净模式开关下真机确认「探索大厅封面确实不打码」。**这是本条最大的不确定性**：理论上分析成立（`detectOnDemand` 默认 false + `_hasAutoDetectPath` 为 false），但需真机确认是否还有其他打码路径兜底。
- ⚠️ 全部条目**未跑 `analyze` / `test`**（沙箱内 Dart VM 无法创建子进程，见 `SESSION_HANDOFF.md`）。

---

## 6. 附：本次审查覆盖的文件清单

**核心逻辑（通读）**

- `lib/pages/explore_hall_page.dart`（385）
- `lib/pages/discover_page.dart`（1842，重点段）
- `lib/services/explore_calendar_service.dart`（238）
- `lib/services/kungal_calendar_service.dart`（609）
- `lib/services/daily_recommendation_service.dart`（171）
- `lib/services/discover_metadata_service.dart`（395）
- `lib/services/website_bookmark_service.dart`（206）
- `lib/services/website_icon_service.dart`（391）
- `lib/repositories/game_repository.dart`（391）
- `lib/repositories/series_repository.dart`（194）

**UI 板块（通读）**

- `lib/widgets/explore_hall/` 全 10 个文件（calendar_section / calendar_grid / docs_section / hall_cover_image / hall_section_shell / hall_visuals / related_topics_section / series_section / today_recommendation / website_section）

**模型与配置**

- `lib/models/website_entry.dart`、`lib/models/kungal_calendar_game.dart`、`lib/models/game_model.dart`
- `lib/core/pb_config.dart`
- `lib/packages/luna_metadata_sdk/lib/services/nextmoe_service.dart`（密钥部分）

**测试（参考）**

- `test/explore_hall/` 全 9 个文件（1639 行）

**未通读（时间预算外，已确认无直接影响）**

- `lib/services/metadata_fetcher.dart`（1068，仅读了并发模型与缓存段）
- `lib/widgets/nsfw/nsfw_image.dart`（933，仅读了 `detectOnDemand` / `_hasAutoDetectPath` 相关段）
