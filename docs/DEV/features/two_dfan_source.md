# 功能档案：2Dfan 元数据源接入（2026-11-04）

> 同批变更：移除 DLsite / ErogameScape / TouchGal 三个平台（见 `metadata_platforms_overview.md` v2）。

## 1. 需求与来源

用户在实际使用与用户反馈中确认：DLsite、ErogameScape、TouchGal **用不上**（且三者都需代理），
决定直接移除；同时新增 **2Dfan** 作为主力中文刮削源。

选型依据：同行项目 **GalGear**（`其他开发者的项目用于本项目参考/GalGear-main`）把 2Dfan 作为
主刮削平台，实测数据覆盖广、质量好。其实现位于 `crates/core/src/providers.rs:169-336`
（`search_fan` / `fan_metadata` / `parse_metadata`），本项目据此落地并按实际页面校正。

**优先级（用户明示）**：`NextMoe → CT 探索库 → 2Dfan → VNDB → KunGal → Hikarinagi → …`

## 2. 站点实测（2026-11-04，决定实现方式）

| 探测 | 结果 |
|---|---|
| `https://2dfan.com` 直连 | ❌ 21s 超时（不可达） |
| `https://2dfmax.top` / `fan2d.top` / `acgfan.top` / `2dfdf.de` | ✅ 全部 200 |
| `GET /search?keyword=美少女万華鏡` | ✅ 200，20 张 `.subject-card` |
| `GET /subjects/11612` | ✅ 200，含 h1 / 封面 / 简介 / 元数据表 / 标签 / 评分数据岛 |

结论：站点**没有公开 API**，只能 HTML 抓取；且**必须做多域名回退**。

## 3. 实现位置

| 文件 | 内容 |
|---|---|
| `lib/packages/luna_metadata_sdk/lib/services/two_dfan_service.dart`（新建） | `TwoDFanService implements MetadataSourceService`：域名回退、搜索页解析、详情页解析、评分归一、别名提取、资源标签过滤；另暴露 `parseSearchResultsForTest` / `parseDetailForTest`（`@visibleForTesting`，离线测试用） |
| `lib/packages/luna_metadata_sdk/lib/models/game.dart` | `SourceType.twoDfan`（位于 `ct` 与 `mix` 之间），`displayName = '2Dfan'`；同时删除 `dlsite / erogamescape / touchgal` |
| `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart` | 工厂加 `twoDfan` 分支；删除 `DLsiteService`（原 649-982 行）与 `ErogameScapeService`（原 983-1343 行）及 `html_parser` import |
| `lib/packages/luna_metadata_sdk/lib/services/rate_limiter.dart` | 新增 2Dfan 档（500ms / 60 每 60s）；删除三平台档位 |
| `lib/packages/luna_metadata_sdk/lib/services/tag_translator.dart` | 2Dfan 归入「中文源，不翻译」；日文源分支随 DLsite/EGS 下线而移除（`jaToZh` 表保留） |
| `lib/packages/luna_metadata_sdk/lib/luna_metadata_sdk.dart` | export 换成 `two_dfan_service.dart`，删除 touchgal |
| `lib/packages/luna_metadata_sdk/lib/services/touchgal_service.dart` | **整文件删除** |
| `lib/services/metadata_fetcher.dart` | `kSourceOrder` / `_enabledSources` / `_instantiateService` / 删除 `kTouchGalApiToken`+`touchGalToken` / `_mixSources` / `_mixFieldPriority` 9 条链 / `_cacheVersion` 6→**7**；**默认开启 + 存量迁移**（详见 §3.1） |
| `lib/core/image_referer.dart`（新建） | 图床 Referer 映射表 + 浏览器 UA（详见 §6.5） |
| `lib/core/portable_image_cache_manager.dart` | 自定义 `fileService` 注入防盗链请求头（所有远程图片的唯一入口） |
| `lib/services/cover_download_service.dart` | 落盘下载的 Referer 改为「显式 > 图床推导 > bgm.tv」 |
| `lib/pages/join/widgets/metadata_source_settings_dialog.dart` | 描述与配色分支更新；删除 TouchGal「Token 未接入」警告块与 `_hasTouchGalToken` |
| `lib/pages/join/widgets/platform_badge.dart` | 新增 `2dfan` 徽章（#D96B3C），删除三平台分支 |
| `lib/widgets/editor_preview_builder.dart` | mock 徽章 `DLsite/ErogameScape` → `2Dfan` |
| `test/services/two_dfan_service_test.dart`（新建） | 离线 HTML 夹具：搜索页/详情页解析、中文优先、会社回退、日期归一、评分归一、标签过滤、空页降级、域名常量 |
| `test/services/metadata_source_order_test.dart` | 顺序期望更新 + 新增「2Dfan 夹在 CT 与 VNDB 之间」「MIX 底层含 2Dfan 且全字段链紧随 CT」两条 |

### 3.1 默认开启与存量迁移（用户要求：2Dfan 是默认源之一）

- **新装用户**：`_enabledSources` 的出厂默认列表本就含 `SourceType.twoDfan`，无需额外处理。
- **存量用户**：`enabled_metadata_sources`（prefs）里存的是**上一次保存的旧列表**，
  代码里的默认值改动**不会**自动生效——不迁移的话，老用户升级后 2Dfan 仍是未勾选状态。
- **实现**：沿用 `mix_source_migrated` / `nextmoe_source_migrated` / `ct_source_migrated`
  的既有惯例，新增一次性闸 `two_dfan_source_migrated`：
  首次启动若列表不含 `twoDfan` 则补入并落盘，之后**用户手动关闭不会被再次打开**。

> 判据提醒：以后再加「默认源」时，**只改默认列表是不够的**，必须同时加一条一次性迁移闸，
> 否则只有干净安装的机器能看到新源。

## 4. 抓取与解析细节

### 4.1 域名回退（含运行期自愈）

```dart
static const List<String> kFanDomains = [
  'https://2dfmax.top',
  'https://fan2d.top',
  'https://acgfan.top',
  'https://2dfdf.de',
  'https://2dfan.com',   // 污染主域，垫底兜底
];
```

#### 🔴 为什么主域必须垫底（2026-11-04 事故）

`2dfan.com` 在中国大陆网络下 **DNS 被污染**（解析到 `128.242.250.148`），且处于
**「半通」**状态——实测同一台机器两次探测结果不同：

| 探测序 | `GET /` | 随后的 `/search` |
|---|---|---|
| 第 1 次 | **200**，113KB | **全部 6s 连接超时** |
| 第 2 次 | 6s 超时 | — |

它原本排在第一位，`_resolveBase()` 只看「首页 200」就锁定，于是**整个会话**
所有搜索/详情请求全部超时 → `fetchByName` 逐个返回空 → 用户看到的就是
「2Dfan 突然什么都搜不到了」。而 `_resolvedBase` 是 static、会话内不复探，
只能重启 app 再赌一次。

**两个修法叠加**：

1. **顺序**：4 个镜像实测 0.8–2.5s 稳定 200，主域降到末位只作兜底。
2. **运行期自愈**（`_getHtml`）：不再依赖一次性探测的运气。每次请求失败（超时 /
   5xx）即 `_markBadDomain()` 把域名计入 `_badDomains` 并撤销锁定，**立刻换下一个
   重试**，单次调用最多切 5 次。第二个游戏起直接复用已锁定域名。

**配套细节**：

- 探测校验不止看 200，还要求首页含 `subject-card` 或 `2dfan` 字样（防 DNS 污染 /
  运营商停靠页返回 200）。
- 全部域名失败只做**软记忆**：`_allFailedAt` + 2 分钟冷却，冷却期内立即返回空，
  不再逐域名重探（避免每个游戏卡 5×4s）；过期自动恢复探测。
- `connectTimeout` 6s → **4s**（镜像实测 <2.5s）。
- `resetResolvedBaseForTest()` 同时清空 `_resolvedBase` / `_badDomains` / `_allFailedAt`。

### 4.2 搜索页 → 详情页

| 步骤 | 选择器 / 字段 |
|---|---|
| 卡片容器 | `#subject-list .subject-card`（兜底 `.subject-card`），id 来自 `subject_card_{n}` |
| 标题 + 链接 | `.subject-card-title a`（href `/subjects/{n}`，非数字的链接剔除） |
| 评分 / 评价数 | `.subject-card-score-value` / `.subject-card-score-count`（"197人评价"） |
| 品牌 / 发售日 | `.subject-card-meta-item` 按 `.subject-card-meta-label` 匹配，日期优先 `time[datetime]` |
| 详情标题 | `h1.subject-title` |
| 封面 | `img.subject-cover-img`（CDN `img.achost.top`，绝对地址） |
| 简介 | `.intro-content`（兜底 `.subject-description`）→ `<br>`/`</p>` 转换行、剥标签、反实体 |
| 会社 | `.subject-meta-list .meta-row`：**开发商 → 品牌 → 发行商 → 发行 → 发行品牌** 逐级回退；dd 内多 `<a class="nexus-inline-link">`，取**首个 `<a>`** 文本（`dd.text` 会无分隔符拼接） |
| 发售日 | 同表 `发售日期` / `发行日期`，正则归一 `YYYY-MM-DD`（支持 `2024年4月26日`） |
| 标签 | `.subject-tags-inline a.nexus-tag`，过滤资源属性标签，`weight=1`、`source='2Dfan'` |
| 评分/投票数 | `[data-island="SubjectRatingPanel"]` 的 `data-props` JSON → `score`（0–5）、`ranksCount` |

### 4.3 评分口径

站点是 **5 分制**（`score: 4.6`，分布 abysmal/poor/fair/great/essential）。
实现：`rating = normalizeRating(score * 2)`（4.6 → 9.2），`voteCount = ranksCount`（197）。
数据岛缺失时回退 `.rating-score` 文本，同样 ×2。

### 4.4 主标题「中文优先」（用户决策）

`<title>` 形如 `美少女万華鏡異聞 雪おんな_美少女万华镜异闻 雪女_美少女万华镜6_…_2DFan`：

1. 按 `_` 切分，剔除空段与尾部 `2DFan`，去重；
2. **主标题 = 第一个「含 CJK 且不含假名」的片段**（即中文译名）；
3. `h1` 原文（多为日文原名）→ `originalTitle`（副标题）；
4. 其余片段 → `aliasNames`（剔除与主标题/副标题重复者）。

无中文片段时回退 `h1` 作主标题、`originalTitle` 置 null。

### 4.5 标签过滤（用户决策）

丢弃 `kJunkTagPatterns` 命中的标签：汉化 / 漢化 / 机翻 / 機翻 / AI翻译 / ai翻译 / AI漢化 /
官方中文 / 生肉 / 精翻 / 云翻 / 人工翻译 / 官中。
理由：这些描述的是**搬运补丁的语言状态**，不是作品属性，混进标签体系会污染筛选与统计。

### 4.6 候选匹配

`_pickBestMatch`：归一化（小写、去空白/标点）后 精确 100 / 前缀 40 / 包含 20。
**与 Bangumi/CT 的「低分即放弃」不同**：无任何分时**回退站点首个候选**——站点搜索本身按相关度排序，
而 h1 多为日文、用户多打中文，字面匹配必然落空，若照搬「宁可空结果」会让中文查询永远 0 命中。

## 5. MIX 接入

- `_mixSources`：`nextmoe, ct, **twoDfan**, vndb, hikarinagi, kun, steam, ymgal`（8 源，2Dfan 第 3 位）
- `_mixFieldPriority`：**9 条链**（cover_url / original_title / alias_names / banner_url / tags /
  developer / summary / game_name / rating）均在 `ct` 之后插入 `twoDfan`；
  `screenshot_urls` **不插入**（2Dfan 不产截图）
- `_cacheVersion` 6 → **7**（源集合与字段链变更，旧缓存整体失效）
- 出厂默认启用（`_enabledSources` 含 2Dfan）

## 6. 验证

- ✅ 进程内 analyzer（231 期间替代 `flutter analyze`）：SDK 6 文件 **0 error / 0 warning**；
  主工程 9 文件 **0 error**（残余 warning 均为存量）。
- ✅ 离线探针 `.workbuddy/probe_fan/`（frontend_server_aot 编译 kernel → `flutter_tester.exe` 直跑）：
  **65 PASS / 0 FAIL** —— 覆盖枚举与顺序、搜索页 8 项、详情页 26 项、会社/日期回退、空页降级、
  MIX 底层与全字段链位置、旧平台已从枚举消失。
- ✅ 线上只读探测：搜索页与详情页各 1 次真实 GET（仅读取，无写入）。
- ⚠️ **未做**：`flutter analyze` / `flutter test` 全量（231 管道耗尽，跨 bash/PowerShell 均失败）、
  真机走查（添加页一键抓取 2Dfan 条目 / MIX 条目字段来源 / 设置弹窗勾选）。

## 6.5 图片防盗链（Referer 白名单）—— 2026-11-04 修复

**现象**：2Dfan 条目的封面（以及所有 `img.achost.top` 图床图）在本软件里**几乎必定加载失败**，
而同一张图在浏览器、在同行项目 GalGear 里都正常。

**实测证据（curl 直连，非推测）**

| 请求 | 响应 |
|---|---|
| 无 Referer | **404** |
| `Referer: https://example.com/` | **404** |
| `Referer: https://2dfmax.top/` | 200（194 KB，image/jpeg） |
| 其余镜像域名作 Referer（`2dfan.com` / `fan2d.top` / `acgfan.top` / `2dfdf.de`） | 全 200 |

**根因**：图床是 **Referer 白名单**校验，且失败返回 **404 而非 403**（极易被误读成"图不存在"）。
Flutter 侧 `CachedNetworkImage` / `Image.network` **默认不发 Referer**，于是必然 404。

第二条断链在落盘：`CoverDownloadService.downloadCover()` 的默认 Referer 是 `https://bgm.tv/`，
对 2Dfan 图床同样 404 ⇒ 入库时封面也存不下来（这正是"导入后还是没封面"的原因，
不仅仅是预览失败）。

参考项目佐证：`GalGear-main/crates/core/src/providers.rs::cover_bytes()` 显式
`.header(REFERER, referrer)`，且白名单里就有 `img.achost.top`。

**修法（注入点收敛为 2 处，不动任何 UI 调用点）**

1. 新增 `lib/core/image_referer.dart`：host 后缀 → Referer 的映射表（当前只有
   `achost.top → https://2dfmax.top/`），同时补浏览器 UA；未登记的 host **原样透传**。
2. `lib/core/portable_image_cache_manager.dart`：`Config(fileService: _HotlinkAwareFileService())`
   —— `CachedNetworkImage` / `NsfwImage` 全部经此 CacheManager，一处生效。
3. `lib/services/cover_download_service.dart`：Referer 解析改为
   `显式传入 > 按图床推导 > 兜底 bgm.tv`（保持 Bangumi 行为不变）。

顺带补的漏洞：`lib/widgets/explore_hall/hall_cover_image.dart` 之前**没传** `cacheManager`，
会绕开本项目 CacheManager 走 `DefaultCacheManager`（也就绕开防盗链适配），已补上。

**验证**：`/workbuddy/probe_fan/image_referer_probe.dart` —— **11 PASS / 0 FAIL**，
含真实网络往返：带修复头取图 = 200 且拿到 >10KB 真实 image 字节；
不带 Referer = 非 200（根因复现）；vndb / steam / bangumi 三类图床不注入任何头（不误伤）。

**边界**：图片下载走 `package:http`，**不经过 app 的代理配置**（只有元数据请求的 dio 走代理）。
2Dfan 国内可直连，无影响；若日后要给图床走代理需另做。

**升级后建议**：若旧版本已经缓存过失败记录，让用户在「设置 → 存储」清理一次图片缓存即可。

## 7. 已知边界

- HTML 无契约，站点改版即失效；靠 `metadata_fetch.log` 的 `[2Dfan]` 前缀定位
  （域名切换会打 `⚠️ 域名不可用，切换下一个`）。
- 镜像域名失效需改 `kFanDomains` 并**发版**（无用户配置项，刻意保持零配置）。
- `2dfan.com` 是 **DNS 污染的半通域名**，只作末位兜底。若日后网络环境变化导致它
  完全可用，也不要挪回首位——运行时自愈已经能覆盖，挪回去只会让首帧多等 4s。
- 不提供截图/横幅（站点没有这两类素材），故 BPM 全屏背景与截图补全链路无收益。
- 旧 `game.json` 里 `metadata_source: "DLsite" / "ErogameScape" / "TouchGal"` 的字符串仍可读，
  只是徽章退化为默认样式（`platform_badge` 的 else 分支）；`SourceType.fromJson` 有 `orElse` 兜底。
- ⛔ 不要动：`kungal_calendar_service.dart` / `nextmoe_service_test.dart` / `kungal_ssr_test.dart`
  里的 `'erogamescape'` 字符串——那是 **NextMoe 上游源标签**（100 分制归一用），不是本项目的平台。
