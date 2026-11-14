# Chrono Tide 元数据平台对接总览

> **性质**：只读梳理文档（不涉及代码变更）。所有结论均按 `HEAD` 源码逐文件核对。  
> **生成日期**：2026-11-04  
> **适用读者**：需要新增/排查/验收元数据抓取功能的开发者与运维。  
> **一句话结论**：项目当前对接 **11 个真实元数据平台 + 1 个虚拟整合源（MIX）+ 1 个本地源**，  
> 全部收敛在同一套 `MetadataSourceService` 接口下，由 `MetadataFetcher` 统一负责并发调度、  
> 限流、代理、缓存与字段整合。

---

## 目录

1. [分层架构与数据流](#1-分层架构与数据流)
2. [平台清单总表](#2-平台清单总表)
3. [逐平台接入详解](#3-逐平台接入详解)
4. [MIX 整合源与字段优先级](#4-mix-整合源与字段优先级)
5. [横向对比：支持范围与使用机制](#5-横向对比支持范围与使用机制)
6. [网络连接：代理、可达性与限流](#6-网络连接代理可达性与限流)
7. [缓存、日志与配置入口](#7-缓存日志与配置入口)
8. [派生抓取：同一批平台的二次利用](#8-派生抓取同一批平台的二次利用)
9. [已知限制与风险清单](#9-已知限制与风险清单)
10. [源码索引](#10-源码索引)

---

## 1. 分层架构与数据流

### 1.1 四层结构

| 层          | 位置                                                                                                                                                         | 职责                                                                                                                                                                                                              |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **接口层**    | `lib/packages/luna_metadata_sdk/lib/services/metadata_base.dart`                                                                                           | `MetadataSourceService` 抽象：`fetchByName` / `fetchByIds` / `testConnection` / `sourceType` / `sourceName`；外加 `executeRateLimited`（429 退避）、`applyProxyConfig`（代理继承）、`normalizeRating`（评分归一 0–10）、`fetchLog`（落盘日志） |
| **实现层**    | 同上目录 `bangumi_* / ct_* / hikarinagi_* / kun_* / nextmoe_* / touchgal_*` + `metadata_services.dart`（VNDB / Steam / DLsite / ErogameScape / 月幕GAL 五个类也在该文件内） | 每个平台一个类，自己建 Dio（含专属 headers），自己解析响应                                                                                                                                                                             |
| **调度层**    | `lib/services/metadata_fetcher.dart`                                                                                                                       | 源注册与顺序、默认启用、并发抓取 `Future.wait`、单源隔离、MIX 合并、24h 磁盘缓存、三级代理、服务实例缓存                                                                                                                                                 |
| **展示/落地层** | `lib/pages/join/`（添加页一键抓取）、`lib/services/discover_metadata_service.dart`（探索页）                                                                              | 结果卡片选择、字段锁定、写入 `game.json`、封面/截图下载                                                                                                                                                                              |

**枚举（唯一事实源）**：`lib/models/game.dart` 同款的 `SourceType`，13 个值：  
`local, bangumi, vndb, ymgal, steam, dlsite, erogamescape, touchgal, hikarinagi, kun, nextmoe, ct, mix`。

### 1.2 一次「一键抓取」的完整链路

```
加入/添加页 点「一键抓取」
  → MetadataFetcher.fetchGame(name)                    // lib/services/metadata_fetcher.dart:472
      ├─ 缓存命中？(key = "<源>:<名称>"，TTL 24h，磁盘 metadata_cache.json)
      ├─ fetchSet = 已启用的独立源 ∪ (MIX 开启时的全部 MIX 底层源)
      ├─ Future.wait 并发：每源 _createService() → fetchByName()
      │     每源都有独立 try/catch + Stopwatch 计时 + fetchLog 记录
      ├─ 仅「已启用的独立源」返回条目；MIX 专用补充源只供整合
      ├─ MIX 条目由本轮已抓结果合成（零额外请求）并插到列表首位
      └─ 写缓存 → 返回 List<Map>
  → UI 让用户选一条 → 字段锁定 → 写 game.json + 下载封面/截图
```

**关键设计**：单源异常/超时**不会**影响其它源（`Future.wait` 内每源 reject 被吞），  
所以「某平台抓不到」表现为「结果卡片少一张」，不会整体失败。

---

## 2. 平台清单总表

| #  | 平台               | `SourceType`   | 接入形态                     | 认证方式                                  | 单次抓取请求数                    | 默认启用 | 国内直连         |
| -- | ---------------- | -------------- | ------------------------ | ------------------------------------- | -------------------------- | ---- | ------------ |
| —  | **MIX（整合源）**     | `mix`          | 虚拟源，无网络                  | —                                     | 0（复用底层结果）                  | ✅    | —            |
| 1  | **NextMoe·未萌**   | `nextmoe`      | JSON REST（v2 开放 API）     | 内置应用密钥 `Bearer nmk_live_…`            | 2（搜索+详情）                   | ✅    | ✅            |
| 2  | **CT 探索库**       | `ct`           | PocketBase REST          | 无（匿名只读）                               | 1–7（分词召回）                  | ✅    | ✅（强制直连）      |
| 3  | **VNDB**         | `vndb`         | JSON REST（Kana API）      | 无                                     | 1（检索即详情）                   | ✅    | ✅            |
| 4  | **KunGal**       | `kun`          | JSON REST（公开 API）        | 无                                     | 2（+0~1 次 VNDB 补全）          | ✅    | ✅            |
| 5  | **Hikarinagi**   | `hikarinagi`   | JSON REST（v3 open）       | **OIDC client_credentials** 换 token   | 3（token+搜索+详情，token 缓存 1h） | ✅    | ✅            |
| 6  | **月幕GAL**        | `ymgal`        | JSON REST                | **OAuth2 client_credentials** 换 token | 2（token+搜索，token 缓存）       | ✅    | ✅            |
| 7  | **Steam**        | `steam`        | 商店公开 JSON                | 无                                     | 2（storesearch→appdetails）  | ✅    | ⚠️ 时通时断      |
| 8  | **Bangumi**      | `bangumi`      | JSON REST（api.bgm.tv v0） | 可选「个人访问令牌」PAT，401 自动降级匿名              | 1（搜索即详情）                   | ✅    | ❌ 需代理        |
| 9  | **DLsite**       | `dlsite`       | **HTML 抓取**              | 无（靠 Cookie `adultchecked=1` 过年龄门）     | 2（搜索页→作品页）                 | ❌    | ❌ 需代理        |
| 10 | **ErogameScape** | `erogamescape` | **HTML 抓取**              | 无（靠 UA + Referer）                     | 2（kensaku→game.php）        | ❌    | ❌ 需代理        |
| 11 | **TouchGal**     | `touchgal`     | JSON REST（v1）            | 内置 `Bearer tgal_live_…`               | 2（search→detail）           | ❌    | ❌ SNI 阻断，需代理 |
| —  | **本地**           | `local`        | 无网络                      | —                                     | 0                          | —    | —            |

> 「默认启用」= `MetadataFetcher._enabledSources` 出厂值（`metadata_fetcher.dart:117-127`）。  
> 「国内直连」为工程经验口径，代码里只有 CT 做了**强制直连**的硬约束，其余全靠代理层。

---

## 3. 逐平台接入详解

每个平台统一按 **端点 → 流程 → 认证 → 数据范围 → 限流/超时 → 特殊坑** 展开。

### 3.1 VNDB（`vndb`）

| 项    | 内容                                                                                                                                                                                                                                                                                                              |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `POST https://api.vndb.org/kana/vn`（JSON body）                                                                                                                                                                                                                                                                  |
| 流程   | **单请求完成检索+详情**：`filters: ["search","=",名称]` + `fields` 一次性点名 + `sort: searchrank`，返回 `results[]` 后在本地二次打分 `_pickBestMatch`（精确 +100 / 前缀 +40 / 包含 +20，候选名取自 `title` 与 `titles[].latin/title`），未命中则回退第一条                                                                                                          |
| 认证   | 无（仅自定义 UA `LunaBox/2.0 (Metadata Scraper)`，历史遗留）                                                                                                                                                                                                                                                                |
| 数据范围 | 多语言标题链 `zh-hans→zh-hant→zh→ja→en`；`ja` 作副标题；封面 `image.url`；截图 `screenshots{url}` 取 6；会社 `developers{name}` 取 5；评分 `rating`（0–10，归一）；`votecount`；`released`；**`length_minutes`/`length_votes`（全项目唯一提供预计游玩时的源）**；标签 `tags{name,rating,spoiler,lie}`，过滤 `rating≥1.5 且 spoiler<2`，按 rating 降序取 10，weight=`rating/3` |
| 限流   | 200ms 最小间隔 / 200 次每 60s                                                                                                                                                                                                                                                                                         |
| 特殊   | 支持 `fetchByIds`（100 ID/批，当前无消费方，为跨源补全预留）；`fields` 必须显式列出子字段（`developers.id` 之类），否则 400；`id` filter 不支持数组以外形态                                                                                                                                                                                                    |

### 3.2 Bangumi（`bangumi`，类名保留 `BangumiMirrorService`）

| 项    | 内容                                                                                                                                                              |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `POST https://api.bgm.tv/v0/search/subjects?limit=10&offset=0`                                                                                                  |
| 流程   | 单请求：`filter: {type:[4], nsfw:true}`（只搜游戏载体）+ `sort: rank`；本地 `_pickBestMatch` 用 `name_cn`+`name` 双候选打分，**低于 20 分直接放弃**（宁可空结果不给错结果）                              |
| 认证   | **可选个人访问令牌（PAT）**：用户在「抓取数据源设定」弹窗的 Bangumi 行下方输入框粘贴，存于 `SharedPreferences.bangumi_personal_access_token`。有 token 走 `Authorization: Bearer`，遇 401 自动降级匿名重试        |
| 数据范围 | 主标题 `name_cn` 优先；原名 `name`（仅在含 CJK 时作副标题）；封面 `images.large→common`（走 `lain.bgm.tv`，不再替换镜像）；简介 `summary`；会社从 `infobox` 提取；评分；发售日 `date`；标签（已是中文，不翻译）。**无截图、无横幅** |
| 限流   | 1000ms 最小间隔 / 30 次每 60s（最保守的一档，匿名限额所致）                                                                                                                          |
| 特殊   | 类注释明确「直接使用原站，已废弃镜像站」；国内访问原站需代理                                                                                                                                  |

### 3.3 Steam（`steam`）

| 项    | 内容                                                                                                                                                                                                                                       |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `GET https://store.steampowered.com/api/storesearch/?term=&l=schinese&cc=CN` → `GET .../api/appdetails?appids=&l=schinese&cc=CN`                                                                                                         |
| 流程   | 两步：搜索拿 `appid`（本地 `_pickBestMatch` 打分）→ appdetails 取详情；`l=schinese` 让返回文本本身就是中文                                                                                                                                                          |
| 认证   | 无（商店端公开接口）                                                                                                                                                                                                                               |
| 数据范围 | 标题 `name`；简介 `short_description`；封面 `header_image`；截图 `screenshots[].path_full` 取 6；会社 `developers` 取 3；评分取 `metacritic.score`（100 分制 → ÷10）；发售日 `release_date.date` 正则归一为 `YYYY-MM-DD`；标签 `genres[].description`（中文）。**无原名、无投票数、无游玩时长** |
| 限流   | 500ms / 100 次每 60s                                                                                                                                                                                                                       |
| 特殊   | 对 Galgame 覆盖极低（只有上架 Steam 的作品），实际主要靠 MIX 里作补充位                                                                                                                                                                                           |

### 3.4 月幕GAL（`ymgal`）

| 项    | 内容                                                                                                                                                                                                                      |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | token：`GET https://www.ymgal.games/oauth/token`；业务：`GET https://www.ymgal.games/open/archive/search-game`                                                                                                               |
| 流程   | ① `client_credentials` 换 `access_token`（`client_id=ymgal`，`client_secret=luna0327` 硬编码，`scope=public`）→ 内存缓存并在到期前 60s 刷新；② `mode=accurate&similarity=70` 搜索，响应 `data.game` **直接就是详情**，无第二次请求                            |
| 认证   | OAuth2 client_credentials 换短时 token（非长期 Bearer）                                                                                                                                                                         |
| 数据范围 | 标题 `chineseName` 优先→`name`；封面 `mainImg/cover_url/image`；会社 `brand_name/company/developer_name`；简介 `introduction/summary`；评分 `score`（归一）；发售日 `release_date/publish_date`；截图兼容 `screenshots/imgs/images/gallery` 四种键；标签中文 |
| 限流   | 500ms / 60 次每 60s（token 端点同样限流）                                                                                                                                                                                         |
| 特殊   | **必须带 `version: 1` + `Accept: application/json;charset=utf-8` 头**，否则返回 HTML / `{"code":404,"msg":"Not found or incorrect version."}`。这是最容易被误判为「站点下线」的坑                                                                  |

### 3.5 KunGal（`kun`）

| 项    | 内容                                                                                                                                                                                                                                                                            |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `GET https://www.kungal.com/api/search?keywords=&type=galgame&page=1&limit=10` → `GET .../api/galgame/{id}?galgame_id={id}`                                                                                                                                                   |
| 流程   | 两步，公开 API **无需认证**（移植自 ReinaManager `api/kun.ts`）                                                                                                                                                                                                                             |
| 数据范围 | v2 结构：`name` + `name_original`；简介 `introduction[]`（lang+HTML）或 `intro_text`；`rating`/`rating_count`/`external_ratings[]`（含 VNDB 跨站评分）；`screenshots[].cdn_url`；`official[].roles`（developer/publisher）；`tag[]`；**双重 NSFW 标记 `content_limit`(sfw/nsfw) + `age_limit`(all/r18)** |
| 跨源补全 | 详情带 `vndb_id` 且自身缺评分/投票数/截图/发售日时，**额外发一次 VNDB POST** 补齐（`_enrichFromVndb`，走 VNDB 的限流通道）。v2 详情自带这些字段时不再请求                                                                                                                                                                      |
| 限流   | 400ms / 60 次每 60s                                                                                                                                                                                                                                                             |
| 特殊   | 2026-08 站点改版为 v2，代码同时兼容旧多语言 Map 结构（`zh-cn/ja-jp/en-us/zh-tw`）                                                                                                                                                                                                                 |

### 3.6 Hikarinagi（`hikarinagi`）

| 项    | 内容                                                                                                                                                                                          |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | token：`POST https://id.hikarinagi.org/oidc/token`；业务：`https://www.hikarinagi.org/api/v3/open` 下 `/search`、`/galgames/{id}`                                                                  |
| 流程   | 三步：① HTTP Basic（`client_id:client_secret`）+ `grant_type=client_credentials&scope=catalog:read` 换 `access_token`；② `GET /search?q=&types=galgame&page_size=5` 取候选；③ `GET /galgames/{id}` 取详情 |
| 认证   | OIDC client_credentials；token 有效期约 1h，缓存并在到期前 1 分钟刷新；遇 401 废弃缓存并重试一次                                                                                                                        |
| 数据范围 | `origin_title`/`trans_title`（原名+译名）；`origin_intro`/`trans_intro`；`covers[]`（**含横幅**，开发者实测该平台横幅数据最完整）；`release_date`；`tags[{name,likes}]`（中文）；`nsfw`。搜索结果额外给 `developer`、`cover`             |
| 限流   | 300ms / 100 次每 60s                                                                                                                                                                          |
| 特殊   | 响应带 `{success, data, message, error, request_id}` 信封；凭据以 `kHikarinagiClientId` / `kHikarinagiClientSecret` 常量硬编码，轮换需改源码                                                                     |

### 3.7 NextMoe·未萌（`nextmoe`）

| 项    | 内容                                                                                                                                                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `GET https://api.nextmoe.dev/v2/catalog/search?object=work&q=&nsfw=true` → `GET .../v2/catalog/works/{id}?nsfw=true&include=titles,intros,covers,screenshots,companies,tags,ratings`                                                                                      |
| 流程   | 两步。详情接口**默认瘦身**，不写 `include=` 则除身份内核外字段全空                                                                                                                                                                                                                                 |
| 认证   | 内置应用密钥 `Authorization: Bearer nmk_live_…`（scope `catalog:read`，源码常量 `NextMoeService.apiKey`）                                                                                                                                                                              |
| 数据范围 | **覆盖面最广**：`titles`（多语言，含 ja 官方标题）、`intros`（多语言）、`covers`（含横幅）、`screenshots`、`companies`（含 `attribution_role=developer`）、`tags`（剔除 `tier=hidden`/`tag_kind=meta` 的平台元标签与剧透标签）、`ratings[]`（**多源并列**：vndb/bangumi/erogamescape，刻度保持原生，代码优先取 vndb 再 bangumi 再归一 erogamescape） |
| 限流   | 1100ms / 55 次每 60s（官方 free 档 60 次/分 · 50,000 次/日，每游戏耗 2 次，留余量取 55）                                                                                                                                                                                                        |
| 特殊   | 响应**无信封**（body 即集合/对象）；`id` 是十进制字符串（int64 直发 JSON number 会失真）；`nsfw` 只接受 `true`，写别的值是 400；翻页只有 `next_cursor`。连接测试用匿名可调的 `/catalog/stats`，不消耗密钥配额                                                                                                                          |
| 定位   | 官方六源对齐目录（VNDB / Bangumi / DLsite / ErogameScape / Ci-en / Getchu 逐字段裁定），是 **MIX 全字段第一优先级**                                                                                                                                                                                |

### 3.8 CT 探索库（`ct`）

| 项    | 内容                                                                                                                                                                                                                                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `GET http://117.72.115.30:8090/api/collections/games/records?filter=…&perPage=60`；文件 `{base}/api/files/games/{recordId}/{filename}`                                                                                                                                 |
| 流程   | 自建 PocketBase `games` 集合，Dio 直调 REST（SDK 不依赖 pocketbase 客户端库）。搜索分两步走：① **分词多查询召回** `_recallRecords`：整串先查一次 → 再按 CJK 2-gram / 拉丁词（≥3 字）逐段查，四字段 OR 并集去重（分词上限 6、单段 perPage 60、候选上限 120）；② **精度闸** `_pickBestMatch`：候选须包含全部关键词段（归一化 AND 门），完全相等直接采用，**不允许「全 0 分回退第一条」** |
| 认证   | 无（`games` 集合匿名只读，与探索页同源）                                                                                                                                                                                                                                            |
| 数据范围 | `title`（社区裁定中文名）、`originalTitle`/`englishTitle`/`traditionalChineseTitle`（三者汇总为别名列表）、`description`、`developer`（兼容旧 `Developer` 大写）、`cover` + `bannerUrl`（竖版+横幅）、`screenshots`（多文件）、`tags`、`rating`(0–10)、`voteCount`、`releaseDate`                                  |
| 限流   | 200ms / 100 次每 60s（自有服务器，最宽松）                                                                                                                                                                                                                                       |
| 特殊   | **强制直连**：构造时 `applyProxyConfig(null, _dio)` → `findProxy = DIRECT`，绕开用户代理（国内 PB 走海外代理反而失败）。0 命中时做**全角→半角折叠重试**（PB 的 `~` 是 SQLite LIKE，只折叠全半角、**不剥标点空格**）。标签已是中文，不走翻译器                                                                                               |
| 定位   | MIX 中**全部字段第二优先级**（NextMoe 之下、VNDB 之上）；同时是「探索库」板块的数据源，另有独立入口「CT 探索库」弹窗可浏览全库并一键导入                                                                                                                                                                                    |


### 3.9 TouchGal（`touchgal`）

| 项    | 内容                                                                                                                                                         |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | `GET https://developer.touchgal.com/api/v1/games/search?limit=1` → `GET .../v1/games/{uniqueId}?allowNsfw=true`                                            |
| 流程   | 两步；`uniqueId` 为 8 位字母数字                                                                                                                                    |
| 认证   | 内置 `Authorization: Bearer tgal_live_…`（源码常量 `MetadataFetcher.kTouchGalApiToken`，非空才启用）                                                                     |
| 数据范围 | `name`（中文）、`bannerUrl`（**只有横幅作封面**）、`companies[0].name`、`introduction`、`rating.average`（10 分制直用）、`releaseDate`、`tags`（纯字符串数组，weight 恒 1，无剧透标记）。**无截图、无原名** |
| 限流   | 500ms / 60 次每 60s                                                                                                                                          |
| 特殊   | 默认**不启用**：注释写明「国内 SNI 阻断需代理，未配代理时开启只会增加超时」；`testConnection` 在无 token 时直接 false                                                                             |

### 3.10 DLsite（`dlsite`）

| 项    | 内容                                                                                                                                                                                                                                      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | 搜索 `https://www.dlsite.com/maniax/fsr/=/language/jp/keyword/{kw}/`；详情 `.../{maniax\|pro}/work/=/product_id/{ID}.html`                                                                                                                   |
| 流程   | **HTML 抓取**（`package:html`）：搜索页取 `.search_result_img_box_inner` 的 `data-list_item_product_id`（失败则从链接正则 `(RJ\|RE\|VJ)\d{4,}` 提取）→ 详情页按 CSS 选择器取 `#work_name`、`[itemprop=description]`、`.maker_name a`、`.main_genre a`、`th` 标签定位「販売日/発売日」 |
| 认证   | 无账号；靠请求头 `Cookie: adultchecked=1; locale=ja` 跳过年龄验证页 + 浏览器 UA + `Accept-Language: ja`                                                                                                                                                   |
| 数据范围 | 日文标题、简介、封面（优先 `_img_main`，退 `_img_smp`）、会社、发售日（日文日期归一）、截图（`.work_slider` → `.work_sample_images` → 全页 `_sample/_smp` 三级兜底）、标签（`.main_genre` 日→中翻译）。**无评分**                                                                              |
| 限流   | 800ms / 60 次每 60s                                                                                                                                                                                                                       |
| 特殊   | `VJ` 前缀走 `pro/` 分支，其余走 `maniax/`；页面结构一变即整体失效（最脆的一档）                                                                                                                                                                                     |

### 3.11 ErogameScape（`erogamescape`）

| 项    | 内容                                                                                                                                                                                                                                        |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 端点   | 搜索 `https://erogamescape.org/~ap2/ero/toukei_kaiseki/kensaku.php?category=game&word_category=name&mode=normal&word=`；详情 `.../game.php?game={id}`                                                                                          |
| 流程   | **HTML 抓取**：`#result tr` 表格按表头「ゲーム名」列宽态定位名称列 → 正则 `[?&#/]game=(\d+)` 取 id → 详情页 `#soft-title span.bold`、`#main_image img`、`#brand td`、`#sellday td`、`#median/#average td`、`#att_pov_table`（标签白名单表头：公式ジャンル / ジャンル / タグ / シチュエーション / エロシーン） |
| 认证   | 无；靠浏览器 UA + `Referer: 站点根`                                                                                                                                                                                                                |
| 数据范围 | 日文标题、封面、会社、发售日 `sellday`、评分 `median`→`average`（归一）、标签（含 `18禁/非18禁/抜きゲー…` 六个 token + 白名单表头下链接）、简介（`#comment`→`.review`→`#intro`→`#content_text` 四级兜底）、截图（`#game_images` → `table a img` 两级）                                                |
| 限流   | 1000ms / 30 次每 60s                                                                                                                                                                                                                        |
| 特殊   | 站点为老式 PHP 页面（无 API）；简介字段是后期补上的（原实现完全缺失）                                                                                                                                                                                                   |

---

## 4. MIX 整合源与字段优先级

**定义**：`mix` 不是网络平台，是调度层合成的虚拟源（`metadata_fetcher.dart:608-621`）。  
它并发抓取固定 7 个底层平台，然后**逐字段**取「第一个非空值」。

**整合范围固定，不随平台开关变化**——用户关掉 VNDB 只是让 VNDB 不出现在独立条目列表里，  
MIX 依旧会拉它，避免「关几个源后 MIX 退化成单源」。

**底层平台（7）**：`nextmoe, ct, vndb, hikarinagi, kun, steam, ymgal`  
（注意：Bangumi / DLsite / ErogameScape 只在独立条目位，不参与 MIX。）

**字段优先级链**（高 → 低）：

| 字段                                                                | 优先级链                                                      |
| ----------------------------------------------------------------- | --------------------------------------------------------- |
| `cover_url` 封面                                                    | NextMoe → CT → VNDB → Hikarinagi → KunGal → Steam → 月幕GAL |
| `banner_url` 横幅                                                   | NextMoe → CT → Hikarinagi → KunGal（其余平台恒空，自动跳过）           |
| `original_title` 原名                                               | NextMoe → CT → VNDB → KunGal                              |
| `alias_names` 别名列表                                                | **CT →** NextMoe → VNDB → KunGal（仅 CT 提供多别名）              |
| `game_name` 主标题                                                   | NextMoe → CT → KunGal → VNDB → Hikarinagi → Steam → 月幕GAL |
| `summary` 简介                                                      | NextMoe → CT → KunGal → Hikarinagi → VNDB → Steam → 月幕GAL |
| `developer` 会社                                                    | NextMoe → CT → VNDB → KunGal → Hikarinagi → Steam         |
| `tags` 标签                                                         | NextMoe → CT → Hikarinagi → KunGal → VNDB → Steam         |
| `screenshot_urls` 截图                                              | NextMoe → CT → KunGal → Hikarinagi → VNDB                 |
| `rating` 评分                                                       | NextMoe → CT → VNDB → KunGal → Hikarinagi → Steam → 月幕GAL |
| `vote_count` / `release_date` / `length_minutes` / `length_votes` | 未单独配置 ⇒ **复用 `rating` 链**                                 |

**输出附加字段**：

- `platform = "MIX源"`（固定展示名）
- `platform_id` = 主标题提供平台的 ID
- `source_platforms` = `{平台名: 平台ID}` 映射 → 批量导入据此做**跨源排重**（任一底层平台 ID 撞车即判重复）

---

## 5. 横向对比：支持范围与使用机制

### 5.1 字段覆盖矩阵

| 字段     | NextMoe | CT   | VNDB     | Kun     | Hikarinagi | 月幕GAL | Steam           | Bangumi   | DLsite | EGS   | TouchGal |
| ------ | ------- | ---- | -------- | ------- | ---------- | ----- | --------------- | --------- | ------ | ----- | -------- |
| 中文主标题  | ✅       | ✅    | ✅ 多语言链   | ✅       | ✅          | ✅     | ✅               | ✅         | ❌ 日文   | ❌ 日文  | ✅        |
| 原名/副标题 | ✅       | ✅    | ✅ ja     | ✅       | ✅          | ⚠️ 部分 | ❌               | ✅         | ❌      | ❌     | ❌        |
| 多别名列表  | ❌       | ✅    | ❌        | ❌       | ❌          | ❌     | ❌               | ❌         | ❌      | ❌     | ❌        |
| 简介     | ✅ 多语言   | ✅    | ⚠️ 英文    | ✅       | ✅          | ✅     | ✅               | ✅         | ✅      | ✅     | ✅        |
| 竖版封面   | ✅       | ✅    | ✅        | ⚠️      | ✅          | ✅     | ✅               | ✅         | ✅      | ✅     | ❌        |
| 横幅     | ✅       | ✅    | ❌        | ⚠️ 论坛头图 | ✅ 最全       | ❌     | ❌               | ❌         | ❌      | ❌     | ✅ 实为横幅   |
| 截图     | ✅       | ✅    | ✅ 6      | ✅       | ❌          | ✅     | ✅ 6             | ❌         | ✅ 6    | ✅ 6   | ❌        |
| 会社     | ✅ 带角色   | ✅    | ✅ 多值     | ✅       | ✅          | ✅     | ✅               | ✅ infobox | ✅      | ✅     | ✅        |
| 评分     | ✅ 多源并列  | ✅    | ✅        | ✅ + 跨站  | ❌          | ✅     | ⚠️ 仅 Metacritic | ✅         | ❌      | ✅     | ✅        |
| 投票数/热度 | ✅       | ✅    | ✅        | ✅       | ❌          | ❌     | ❌               | ⚠️        | ❌      | ❌     | ❌        |
| 发售日    | ✅       | ✅    | ✅        | ✅       | ✅          | ✅     | ✅               | ✅         | ✅      | ✅     | ✅        |
| 游玩时长   | ❌       | ❌    | ✅ **唯一** | ❌       | ❌          | ❌     | ❌               | ❌         | ❌      | ❌     | ❌        |
| 分类标签   | ✅ 已净化   | ✅ 中文 | ✅ 英→中    | ✅       | ✅          | ✅     | ✅ 中文            | ✅ 中文      | ✅ 日→中  | ✅ 日→中 | ✅ 中文     |

### 5.2 机制差异一览

| 维度       | 结论                                                                                                                                                                                    |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **协议**   | JSON REST 9 个（VNDB/Steam/Kun/月幕/Bangumi/TouchGal/Hikarinagi/NextMoe/CT-PB）；HTML 抓取 2 个（DLsite/EGS）                                                                                    |
| **鉴权**   | 完全匿名 5 个（VNDB/Steam/Kun/CT + EGS/DLsite 靠 UA/Cookie）；**内置应用密钥 2 个**（TouchGal 静态 Bearer、NextMoe 静态 Bearer）；**OAuth2/OIDC 换短时 token 2 个**（月幕、Hikarinagi）；**用户自备令牌 1 个**（Bangumi PAT，可选） |
| **请求数**  | 单请求：VNDB、Bangumi（检索即详情，最省）；两步：Steam/DLsite/EGS/月幕/TouchGal/Hikarinagi/Kun/NextMoe；1~7 步：CT（分词召回）                                                                                      |
| **凭据落点** | 硬编码源码常量（TouchGal / NextMoe / Hikarinagi / 月幕）；`SharedPreferences`（Bangumi PAT、代理地址）；**都没有服务端代持**——桌面应用无后端，轮换必须发版                                                                      |
| **中文能力** | 原生中文：NextMoe / CT / Kun / Hikarinagi / 月幕 / Bangumi / Steam(`l=schinese`) / TouchGal；需翻译：VNDB（英）、DLsite/EGS（日）                                                                        |
| **标签翻译** | 统一由 `TagTranslator` 处理：VNDB 走 `assets/data/vndb_tags_zh_cn.json`（~2990 条英→中，MIT，来自 VNDBTranslatorLib）；DLsite/EGS 走内置 ~200 条日→中映射；未命中原样保留                                              |
| **严格度**  | 最严格：Bangumi（匹配分 <20 直接放弃）；最宽松：DLsite/EGS/Steam（0 分也回退第一条候选）；CT 已改为「宁可空结果」                                                                                                             |

---

## 6. 网络连接：代理、可达性与限流

### 6.1 三级代理解析（`_initDio`，`metadata_fetcher.dart:176-226`）

```
优先级 1：app 配置（SharedPreferences.proxy_url，设置页手填）   ← 最高
优先级 2：Windows 系统代理（读注册表 HKCU\...\Internet Settings 的
          ProxyEnable / ProxyServer，用 `reg query` 实现）
优先级 3：环境变量 HTTP_PROXY / HTTPS_PROXY（Dart findProxyFromEnvironment 兜底）
        ↓
2 秒 TCP 存活验证（_validateProxy）
        ↓
连通 → 全部服务走 PROXY host:port
不通 → 判定「死代理」（多见于关了 Clash 但注册表残留）→ 放弃代理走直连
```

**为什么必须自己读注册表**：Dart 的 `HttpClient.findProxyFromEnvironment` **只读环境变量**，  
不读 Windows 系统代理；而 Clash / V2Ray 的「系统代理」模式是写注册表的。  
不补这一层，就会出现「浏览器能开、软件打不开」。

### 6.2 直连例外：CT 探索库

`CTService` 构造时 `applyProxyConfig(null, _dio)` → 显式 `findProxy = DIRECT`，  
**无视全局代理配置**。理由：PB 部署在京东云（国内），走海外代理反而绕远/失败。

同理，`applyProxyConfig` 在**源 Dio 为 null 或缺回调**时也强制 DIRECT，  
避免 Dart `HttpClient()` 在 Windows 上默认读系统代理注册表、  
导致「用户关了 VPN 但注册表残留」时所有直连平台集体失败。

### 6.3 可达性分类（工程经验）

| 分类          | 平台                                      | 说明                                   |
| ----------- | --------------------------------------- | ------------------------------------ |
| 国内可直连       | CT、NextMoe、KunGal、VNDB、Hikarinagi、月幕GAL | 无代理也能用（Hikarinagi/NextMoe 依赖 CDN 质量） |
| 需代理（稳定）     | Bangumi（api.bgm.tv）、ErogameScape        | 原站国内直连不稳                             |
| 需代理（SNI 阻断） | TouchGal、DLsite                         | TouchGal 代码注释明确「SNI 阻断」，故默认不启用       |
| 时通时断        | Steam 商店接口                              | 地区差异大，作为补充位                          |

### 6.4 超时与并发

| 层                     | 值                                                 |
| --------------------- | ------------------------------------------------- |
| 全局 Dio（`_initDio`）    | connect 10s / receive 15s                         |
| Bangumi               | 8s / 12s（单独收紧）                                    |
| DLsite / ErogameScape | 12s / 20s（HTML 页面较重）                              |
| TouchGal              | 20s / 25s（最宽松）                                    |
| 其余                    | 10s / 15s                                         |
| 并发                    | `Future.wait` 全源同时发；单源最坏 ~15s 决定整体耗时（串行时代为 ~200s） |

### 6.5 限流与 429

每个 `SourceType` 一个独立 `RateLimiter` 单例，双层限流：**最小间隔** + **滑动窗口配额**。  
429 处理：优先读 `Retry-After` 头，否则指数退避 1→2→4→8→16→32s（上限 30s），**只重试一次**。

| 源                      | 最小间隔   | 窗口配额    | 依据                     |
| ---------------------- | ------ | ------- | ---------------------- |
| CT                     | 200ms  | 100/60s | 自有服务器，宽松               |
| VNDB                   | 200ms  | 200/60s | 官方较宽松                  |
| Hikarinagi             | 300ms  | 100/60s | —                      |
| Kun                    | 400ms  | 60/60s  | —                      |
| Steam                  | 500ms  | 100/60s | —                      |
| 月幕GAL / TouchGal       | 500ms  | 60/60s  | —                      |
| DLsite                 | 800ms  | 60/60s  | 页面重，防封                 |
| Bangumi / ErogameScape | 1000ms | 30/60s  | 最保守                    |
| NextMoe                | 1100ms | 55/60s  | 官方 60/分、50k/日，每游戏耗 2 次 |

### 6.6 排障要点

1. **先看日志**：`<应用数据目录>/metadata_fetch.log`（`setFetchLogPath`，release 也可用）。  
   每行带 ISO 时间戳，含 `[源] ✅ 成功 (ms)` / `⚠️ 无效结果` / `❌ 异常`，以及最终  
   「字段提供=cover_url=NextMoe, …」的来源诊断。`debugPrint` 在 GUI release 不输出，所以必须看文件。
2. **代理变更不必重启**：`MetadataFetcher.updateProxy()` 会清空服务实例缓存（否则旧 Dio 配置残留）并重建。
3. **代理「假开启」**：注册表残留 → `_validateProxy` 2s TCP 探测拦截 → 自动直连。
4. **CT 搜不到但探索页搜得到**：两套召回口径不同（服务端 SQLite LIKE vs 客户端归一化），  
   已用「分词多查询 + 精度闸」对齐；若再复现，先看 `[CT]` 前缀日志的候选数。
5. **NextMoe 详情字段全空**：`include=` 漏写数据块（v2 默认瘦身）。
6. **月幕GAL 返回 HTML**：`version: 1` 头丢了。

---

## 7. 缓存、日志与配置入口

| 项           | 值                                                                                                               |
| ----------- | --------------------------------------------------------------------------------------------------------------- |
| 内存缓存        | `Map<String, Map>`，键 `<源>:<名称>` 或 `mix:<名称>`                                                                    |
| TTL         | 24 小时                                                                                                           |
| 磁盘缓存        | `<dataDir>/cache/metadata_cache.json`（启动加载、写入异步不阻塞）                                                             |
| 缓存版本        | `_cacheVersion = 6`。**任何解析/召回逻辑变更都必须自增**，否则旧缓存让新逻辑不生效（v3 起依次因 MIX 共存、NextMoe、CT、CT 索引修复而升级）                     |
| 抓取日志        | `<dataDir>/metadata_fetch.log`                                                                                  |
| 启用源偏好       | `SharedPreferences.enabled_metadata_sources`（源名列表），另有一次性的 `nextmoe_source_migrated` / `ct_source_migrated` 补开迁移 |
| 代理          | `SharedPreferences.proxy_url`；UI 在设置页（`settings_modal.dart` → `updateProxy`）                                    |
| Bangumi PAT | `SharedPreferences.bangumi_personal_access_token`；UI 在「抓取数据源设定」弹窗 Bangumi 行内                                    |
| 源开关 UI      | 添加页「一键抓取」旁齿轮 → 「抓取数据源设定」弹窗（列出全部源 + 顺序说明 + Bangumi token 输入，至少保留一个源）                                             |
| CT 独立入口     | 同一按钮组里的「CT 探索库」（`travel_explore` 图标）→ 作品选择弹窗，浏览全库后一键导入                                                          |

---

## 8. 派生抓取：同一批平台的二次利用

元数据抓取之外，同一批平台还被这些功能复用（同一套代理/限流）：

| 功能               | 数据来源                                                                                             | 位置                                          |
| ---------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| **标题图（透明 logo）** | NextMoe 目录搜索取 `steam:<appid>` 锚点 → **Steam 官方 CDN `logo.png`**；缺口由 **SteamGridDB**（需用户自备免费 Key）补 | `lib/services/game_title_logo_service.dart` |
| **会社图标**         | NextMoe 会社目录 `/v2/catalog/companies/{id}`                                                        | `lib/services/company_logo_service.dart`    |
| **封面/横幅下载**      | 抓取结果里的 URL（不限定源），下载侧做**宽高比 ≥1.15** 校验剔除伪横幅                                                       | `lib/services/cover_download_service.dart`  |
| **截图补全**         | 多源并发 `fetchScreenshots`，默认链 NextMoe → Kun → Hikarinagi → VNDB，支持备选标题回退                           | `metadata_fetcher.dart:916`                 |
| **探索页评分/热度/时长**  | `DiscoverMetadataService` 调 `MetadataFetcher`，并在抓到后**回传 PB `games` 沉淀**，供其他用户直接复用                | `discover_metadata_service.dart`            |

---

## 9. 已知限制与风险清单

| 级别     | 项                            | 说明                                                                                  |
| ------ | ---------------------------- | ----------------------------------------------------------------------------------- |
| **P1** | 内置密钥全部硬编码在客户端                | TouchGal / NextMoe / Hikarinagi / 月幕 四个应用密钥以源码常量分发，可被反编译提取；官方吊销即全体客户端失效，且**只能发版修复** |
| **P1** | 无服务端代持/中转                    | 桌面应用无后端，所有平台请求直连用户网络 ⇒ 国内可达性完全依赖用户代理环境                                              |
| **P1** | CT 匿名只读依赖服务端规则               | `games` 集合 listRule 一旦收紧，CT 源与探索页同时空结果（表现为「静默无数据」）                                  |
| **P1** | HTML 抓取两源无契约                 | DLsite / ErogameScape 页面结构一变即整体失效，只能靠日志发现                                           |
| **P2** | Bangumi 匹配过严                 | 匹配分 <20 直接放弃 → 用户输入轻微变体就 0 结果（有意为之，避免张冠李戴）                                          |
| **P2** | NextMoe 日配额                  | free 档 50,000 次/日、60 次/分；批量导入千级游戏会逼近配额（每游戏 2 次）                                     |
| **P2** | Kun 隐式多发请求                   | 详情带 `vndb_id` 且缺字段时会额外打 VNDB，批量场景下 VNDB 实际 QPS 高于表面                                 |
| **P2** | 缓存版本漏升                       | 改解析逻辑但忘升 `_cacheVersion` ⇒ 老用户看不到改动（历史上已踩过）                                         |
| **P3** | `fetchByIds` 无消费方            | 只有 VNDB 实现（100/批），其余源返回空列表，为跨源补全预留                                                  |
| **P3** | `testAllConnections` 无 UI 入口 | 调度层有批量连通性测试能力，但设置页没有按钮，目前靠日志判断                                                      |
| **P3** | 默认不启用 DLsite/EGS/TouchGal    | 三者都需要代理，出厂关闭以免新用户首次抓取满屏超时                                                           |

---

## 10. 源码索引

| 主题                                           | 文件                                                                                                      |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| 接口与通用工具（限流/代理/评分归一/日志）                       | `lib/packages/luna_metadata_sdk/lib/services/metadata_base.dart`                                        |
| 限流策略表                                        | `lib/packages/luna_metadata_sdk/lib/services/rate_limiter.dart`                                         |
| 服务工厂                                         | `metadata_services.dart` → `MetadataServiceFactory.getService`                                          |
| VNDB / Steam / DLsite / ErogameScape / 月幕GAL | `metadata_services.dart`（五个类同文件）                                                                        |
| Bangumi + PAT 存储                             | `bangumi_service.dart` / `bangumi_oauth.dart`                                                           |
| Hikarinagi                                   | `hikarinagi_service.dart`                                                                               |
| KunGal                                       | `kun_service.dart`                                                                                      |
| NextMoe                                      | `nextmoe_service.dart`                                                                                  |
| TouchGal                                     | `touchgal_service.dart`                                                                                 |
| CT 探索库                                       | `ct_service.dart`                                                                                       |
| 标签翻译                                         | `tag_translator.dart` + `assets/data/vndb_tags_zh_cn.json`                                              |
| 调度/优先级/缓存/代理                                 | `lib/services/metadata_fetcher.dart`                                                                    |
| 系统代理探测                                       | `lib/services/system_proxy_detector.dart`                                                               |
| 源开关 UI                                       | `lib/pages/join/widgets/metadata_source_settings_dialog.dart`                                           |
| 探索页元数据 + 云端沉淀                                | `lib/services/discover_metadata_service.dart`、`lib/repositories/game_repository.dart`                   |
| 功能档案                                         | `docs/DEV/features/{ct_metadata_source,nextmoe_source,cloud_game_metadata_sync,network_reliability}.md` |
