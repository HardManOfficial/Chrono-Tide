# 补丁查找（PATCH-FINDER）实施方案

> ⚠️ **本文件已被 `patch_station_docking_plan.md`（2026-11-10）取代并扩展。**
> 保留价值：§3.2 的 NextMoe moyu 接口实测记录、§2.1 的既有能力盘点。
> 已知过时结论：本文认为"补丁拿不到直链只能跳转"——2026-11-10 实测推翻
> （资源网页 HTML 内含 `dl.imoe.uk` 公开直链，可直下）。
> 本文的 O-1（PB 补 `vndb_id`）也已降级：`/v2/catalog/search` 直接给 catalog work id，
> 用 `refs=catalog:<id>` 锚定，一期无需 schema 变更。

**状态**：方案待批准（阶段 A 完成，未写代码）
**日期**：2026-11-04
**参考项目**：`其他开发者的项目用于本项目参考/GalGear-main`（Tauri/Rust）
**本轮范围**：**只做「查找 + 展示 + 跳转原站」**。文件下载、打补丁、回滚**不在本期**。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 功能名 | **补丁查找（PATCH-FINDER）** |
| 落点 | **探索库**：`lib/pages/discover_page.dart`（不是 `library_page.dart`，"我的库"是另一套） |
| 一期能力 | 按游戏名 / 补丁名搜索 → 列表展示 → 点卡片打开浏览器到原站 |
| 一期**不做** | 文件下载、解压、自动打补丁、备份回滚、2DFan 登录与积分 |
| 主数据源 | **NextMoe moyu 补丁面** `/v2/moyu`（结构化 JSON，**已实测可用**） |
| 次数据源 | 2DFan HTML 抓取（仅搜索+跳转） |
| 第三源 | 自家 PB `game_resources`（`resource_type` 已含补丁类型） |
| 🔴 最重要的发现 | **不需要抓 2DFan 就能拿到干净的补丁数据**——NextMoe 有官方补丁 API，带 SHA-256、安装说明、类型分类 |
| 🔴 最大技术风险 | 探索库游戏条目**没有 vndb / catalog id**，只能靠标题解析 → 命中率未实测 |
| 🔴 最大产品约束 | moyu 直链需运营发放 `moyu:files` scope（实测 403）；一期只跳转，符合已定范围 |

---

## 1. 背景与目标

### 1.1 用户诉求原话要点

1. 现有软件**只提供游戏本体下载，没有补丁下载**；
2. 作为管理器，**缺少补丁文件的管理**；
3. 打补丁有门槛（要放到正确位置替换文件）；
4. 补丁可能导致游戏错误，**必须能恢复**；
5. 一期先做**补丁查找**，UI 后续由用户提供设计稿。

### 1.2 参考项目 GalGear 实际做了什么

纯客户端抓取，无自建后端：

- **2DFan**：`GET /search?keyword=` → 取前 5 个 subject → 逐个 `GET /subjects/{id}/downloads` → 抓 `.download-card-title`（`crates/core/src/providers.rs:419-449`）
- **鲲 Galgame**：`GET https://www.moyu.moe/api/v1/search/quick?keywords=&content_limit=sfw`（`providers.rs:476-482`）→ **只给原站链接，无直链**
- **打补丁**：下载到 `game/patch/<名>/`，SHA-256 备份原文件，原子写入，失败回滚，启动 `recover`（`crates/core/src/patches.rs:434-529`）
- **它的三个短板**（我们要避开）：
  1. **不做补丁↔游戏匹配**，只有查询串精确等于库中标题才归到该游戏（`crates/ui/src/patches.rs:385-395`）
  2. **不推断补丁该放哪个子目录**，直接按包内相对路径落到游戏根（`patches.rs:193-216`）
  3. 2DFan 硬编码域名白名单，站点换域就得改代码（`providers.rs:128-139`）

### 1.3 本期目标（可验收）

- [ ] 探索库内可按**游戏名**或**补丁名**搜索，返回补丁列表
- [ ] 列表项含：补丁名、来源站、类型（汉化/AI/机翻/无码/存档/破解…）、语言、大小、下载量、更新时间
- [ ] 点条目**打开系统浏览器**到原站页面（`web_url`）
- [ ] 展示补丁的**安装说明**（moyu 的 `note` 字段，含"解压到根目录覆盖同名文件"这类关键信息）
- [ ] 双源失败可降级：moyu 挂 → 仍能出 2DFan 结果；2DFan 挂 → 仍能出 moyu 结果
- [ ] 全链路失败时**不阻塞**探索库其他功能，只给一行提示

### 1.4 非目标（一期明确不碰，防止接手者扩大范围）

| 不做 | 原因 |
|---|---|
| 补丁文件下载 | 用户已定：一期只跳转。moyu 直链需 `moyu:files` scope（实测 403） |
| 打补丁 / 解压到游戏目录 | 用户已定：后续再做 |
| 备份 / 回滚 | 同上。已确认 `game_font_patch_service.dart` 有可照抄的范式，二期直接用 |
| 2DFan 登录 / Cookie / 积分购买 | 用户已定：只做搜索+跳转 |
| 补丁 ↔ 游戏自动关联入库 | 一期只做"查"，不做"记"。不写 `game.json` |
| PB 后台改表 / 新增集合 | 一期零 schema 变更 |
| 修改 `lib/packages/luna_metadata_sdk/` | 稳定区，改动需另行批准 |

---

## 2. 现状调研

### 2.1 🔴 已有但未被消费的能力（本项目最大浪费点，先盘后建）

| 已有能力 | 位置 | 现状 |
|---|---|---|
| 2DFan 抓取基础设施（5 域名回退 / UA / 代理 / 超时） | `lib/packages/luna_metadata_sdk/lib/services/two_dfan_service.dart:57`（`kFanDomains`）、`:203`（`_getHtml`） | **注释里就写着"参考同行项目 GalGear 的 providers.rs"**——当年只搬了元数据，**没搬补丁** |
| NextMoe 开放 API 密钥 | `lib/packages/luna_metadata_sdk/lib/services/nextmoe_service.dart:60`（`apiKey`）、`:54`（`apiBase`） | 只用于 catalog（元数据），**moyu 补丁面从未被调用** |
| 「标题 → NextMoe work → 站内 id」解析链 | `lib/services/kungal_link_service.dart:193`（`claimIdOf`）、`:226`（`_searchKungalId`）、`:87`（2 路并发预取） | 已生产可用，但只服务于 KUNGAL 外跳。**这正是补丁查找要的匹配能力** |
| 标题归一化 | `lib/models/kungal_calendar_game.dart`（`normalizeTitle`） | 发售日历在用，补丁匹配可直接复用 |
| 社区资源体系（含"全年龄补丁/修正补丁"类型） | `lib/models/game_resource_model.dart:187`（`resourceTypes`） | PB 侧 `resource_type` 枚举**早就有补丁分类**，但 UI 无独立板块——真实空白 |
| 外链打开 | `lib/big_picture/big_picture_shell.dart:1581`（`Process.start('explorer', [url])`） | 项目当前惯例（**无 `url_launcher` 依赖**，`pubspec.yaml` 里没有） |
| 补丁事务范式（备份 + 安装 + 安全回滚 + manifest） | `lib/services/game_font_patch_service.dart:429`（install）/`:513`（`_safeRollbackInstall`）/`:545`（uninstall） | 字体补丁已跑通。**二期做打补丁/回滚时照抄它，不要另发明** |
| 通用解压（带进度、可取消） | `lib/services/archive_compressor.dart:389`（`extractArchive`） | 注释写"仅供应用自有数据"，**二期用于补丁解压需重新评估边界** |

### 2.2 探索库的真实结构（落点确认）

```
explore_hall_page.dart:224  Offstage(offstage: _showLibrary, child: _buildHall())
explore_hall_page.dart:226  Offstage(offstage: !_showLibrary, child: _buildLibraryView())
explore_hall_page.dart:463  _buildLibraryView() → DiscoverPage(onGameTap: _guardedGameTap)
```

- **探索库 = `lib/pages/discover_page.dart`（2775 行）**，不是 `library_page.dart`
- 已有 `_searchController`（`:127`），搜索匹配标题/日文原名/英文名/标签/会社，多关键词 AND（`:619-670`）
- 顶栏 v3 已有来源/评分/发售日期/排序筛选
- 详情页 = `lib/pages/game_detail_page.dart:49`，「获取」按钮 `:741` → `CtDownloadDialog`
- 探索协议门禁在 `_guardedGameTap` / `_guardedEnterLibrary`（`explore_hall_page.dart:138`）收口，**新入口必须走同一门禁**

### 2.3 明确空白

1. 无任何"补丁"业务代码（`grep 补丁 lib/` 只命中注释）
2. 无统一的"外部资源获取"抽象（封面 / 更新 / 元数据各有一套 Dio）
3. `GameModel`（`lib/models/game_model.dart`）**只有 `metaSource`（`:32`），没有任何外部 id 字段**
4. 无 `url_launcher` 依赖

---

## 3. 技术选型

### 3.1 数据源对比（实测支撑）

| 方案 | 结构化程度 | 匹配精度 | 直链 | 稳定性 | 结论 |
|---|---|---|---|---|---|
| **NextMoe `/v2/moyu`** | JSON，字段完整（含 SHA-256、`note` 安装说明、`type[]`） | 可用 `refs=catalog:<id>` / `refs=vndb:v<id>` **精确锚定**，支持批量 100 条 | 需 `moyu:files` scope | 官方 API，有 187+6 端点文档、限流契约 | ✅ **主源** |
| 2DFan HTML 抓取 | DOM 解析，脆弱 | 只能"搜标题取前 5 个"猜 | 大多要积分 + 登录 | 站点换域/改版即失效（GalGear 自己就坏过） | ⚠️ 次源，仅搜索+跳转 |
| 鲲 Galgame 旧接口 `moyu.moe/api/v1/search/quick` | JSON 但只有外链 | 标题模糊 | 无 | 非公开契约，随时可变 | ❌ 淘汰：**NextMoe 的 moyu 面是它的正式上游**，没理由绕过 |
| 自家 PB `game_resources` | 已是自家模型 | 已关联到作品 | 走 OpenList | 完全可控 | ✅ 第三源，免费增量 |

### 3.2 🔴 实测记录（本轮真实执行，可复现）

**① 补丁列表** `GET /v2/moyu/patches?limit=2`

```json
{"object":"list","items":[{"object":"patch","id":"87","vndb_id":"v66","catalog_work_id":"87",
"content_limit":"sfw","release_date":"2003-09-26","type":["save","manual","r18","decensor"],
"language":["ja","zh-Hans"],"platform":["windows"],"resource_count":4,"download_count":567,
"view_count":2897,"favorite_count":10,"comment_count":0,
"web_url":"https://www.moyu.moe/galgame/87", ...}],"next_cursor":"cur_Mg"}
```

**② 资源列表** `GET /v2/moyu/patches/87/resources`（真实字段）

```json
{"object":"patch_resource","id":"11425","patch_id":"87","name":"Steam版内容还原+汉化补丁v0.6.0",
"storage":"s3","size":"128.156 MB",
"hash":"d3d0494013cc897aede635346fe92c8291b3a4301afd3436897350891c5e4971",
"model_name":"","localization_group_name":"",
"note":"…安装器会依次执行…3. 列出将被修改的文件，等待确认…",
"type":["manual","r18"],"language":["zh-Hans"],"platform":["windows"],
"download_count":35,"like_count":0,"web_url":"https://www.moyu.moe/resource/11425", ...}
```

另一条 `note` 原话即"**解压到根目录覆盖同名文件**"——**这就是二期自动打补丁要的落点信息**。

**③ refs 反查（两种锚都通）**

- `?refs=vndb:v66` → 命中 patch 87 ✅
- `?refs=catalog:87` → 命中 patch 87 ✅
- `?refs=vndb:v66,vndb:v19658,vndb:v99999999` → 命中 2 条，未命中回 `"missing":["vndb:v99999999"]` ✅

**④ 直链（一期用不到，记录以便二期）** `GET /v2/moyu/resources/5459/file`

```
HTTP 403  {"code":"SCOPE_REQUIRED","detail":"this operation needs the moyu:files scope, which an operator grants"}
```

**⑤ `type` 枚举（资源类型，接口原样返回）**

`manual | ai | machine_polishing | machine | save | crack | fix | mod | r18 | decensor | image | other`

**⑥ 契约约束（来自官方文档，必须遵守）**

- 任意有效 `nmk_` 密钥可调 mouy 面，**无需额外 scope**（`/file` 除外）
- 限流：free 档 60 次/分 · 50,000 次/日，超限 429 + `Retry-After`
- **不带下载直链、提取码、解压密码**——这是契约写死的取舍，不是遗漏
- 每行都给 `web_url`，设计意图就是"把读者送过去"
- 只带 `catalog_work_id`，游戏名/封面/标签归 catalog，需另查
- **只能服务端/客户端直连调用**：网关对含 OPTIONS 的每个方法都验密钥，浏览器直连必 401。我们 Dart 直连 HTTP 不受影响

### 3.3 被淘汰的方案及理由

| 淘汰项 | 理由 |
|---|---|
| 复刻 GalGear 的 `moyu.moe/api/v1/search/quick` | NextMoe 的 `/v2/moyu` 就是它的正式上游，且字段更全、有文档、有配额承诺 |
| 自建后端聚合 | 项目无服务端；NextMoe 已承担聚合角色 |
| 引入 `url_launcher` | 项目现有惯例是 `Process.start('explorer', [url])`（`big_picture_shell.dart:1581`）。**新增依赖需用户批准**，一期不引入 |
| 抓 2DFan 的 `/downloads/{id}` 页 | 一期只跳转，不碰积分/登录，没必要解析详情页 |

---

## 4. 架构设计

```
┌──────────────────────── 探索库 UI（discover_page.dart / game_detail_page.dart）
│  ① 顶栏「补丁查找」入口 → 搜索浮层（按补丁名）
│  ② 游戏详情「补丁」区（按该游戏）
└───────────────┬──────────────────────────────────────
                ▼
      PatchFinderService（聚合 / 缓存 / 去重 / 失败降级）
                │
      ┌─────────┼──────────────┬─────────────────────
      ▼         ▼              ▼
 MoyuPatch    TwoDFanPatch   CommunityPatchSource
 Source       Source         （读 PB game_resources）
 (JSON API)   (HTML 抓取)     （已有基础设施）
      │
      ▼
 NextMoeIdentityResolver（标题 → catalog_work_id → 补丁页）
   · 照抄 kungal_link_service 的解析链与会话/磁盘缓存
   · 独立缓存文件，二期再考虑与 KungalLinkService 合并
```

**关键设计决策**

1. **匹配优先走 id，不优先走标题**
   `refs=catalog:<id>` 是精确锚；标题搜索只作兜底。这与 GalGear「只按标题猜」有本质区别。

2. **批量反查做列表徽章**
   一次 `refs=vndb:a,vndb:b,...`（上限 100）就能给整屏游戏标"有 N 个补丁"。**这是单次请求的收益**，比逐条解析便宜两个数量级。**前提是有 vndb id**——当前没有，见 §13 开放问题 O-1。

3. **缓存与限流必须复用既有设施**
   - 磁盘缓存：`data/cache/moyu_patch.json`，TTL 对齐 `KungalLinkService._diskTtl`（30 天）
   - 限流：走 `lib/packages/luna_metadata_sdk/lib/services/rate_limiter.dart` 的 `executeRateLimited(SourceType.nextmoe, ...)`

4. **失败降级是硬要求**
   单源失败只记 warning（对齐 GalGear `providers.rs:451-474`），但**不许伪造条目凑数**——GalGear 在下载页失败时伪造一条"资源"（`providers.rs:439-445`），这是反面教材。

5. **不阻塞 UI**
   搜索浮层立即打开并显示 loading，结果异步追加（对齐 `CtDownloadDialog` 的三分回调范式，`ct_download_dialog.dart:26-49`）。

---

## 5. 数据模型变更

### 5.1 🔴 结论：不写 `game.json`，零迁移

一期**只读不写**，不碰 `format_version = 4`（`lib/services/game_data_format.dart:52`），不碰 `_overwritableFields`（`:215-276`）。

⚠️ 二期若要把"已装补丁"写进 `game.json`：必须**加在用户累积状态区**（`:1960-1971`，与 `fontOverride`/`homeHidden` 同区），**绝不能加入 `_overwritableFields`**，否则重新导入会清空。

### 5.2 新增纯内存模型

`lib/models/patch_resource.dart`（新文件）

```dart
enum PatchSource { moyu, twoDfan, community }

class PatchResource {
  final String id;            // moyu: patch_resource.id；2dfan: downloads/{id}
  final PatchSource source;
  final String title;         // 补丁名
  final String gameTitle;     // 来源站标注的对应游戏名（仅供展示，不用于匹配）
  final List<String> types;   // manual/ai/machine/save/crack/decensor...
  final List<String> languages;
  final List<String> platforms;
  final String size;          // "128.156 MB"（字符串，展示用；格式化交给 UI）
  final String sha256;        // moyu hash；2dfan 为空
  final String note;          // 安装说明（含落点提示）
  final int downloadCount;
  final String webUrl;        // 唯一动作目标
  final DateTime? updatedAt;
}
```

### 5.3 缓存文件（新增，不属 schema）

`data/cache/moyu_patch_index.json`

```json
{ "version": 1,
  "byGameId": { "<gameId>": { "catalogWorkId": "87", "patchId": "87", "resolvedAt": "..." } },
  "resolvedAt": { "<gameId>": "2026-11-04T..." } }
```

负缓存（查无结果）也要存，避免每次进详情都打网络——对齐 `KungalLinkService` 的做法。

---

## 6. 性能预算

| 动作 | 预算 | 说明 |
|---|---|---|
| 打开搜索浮层（首帧） | < 16 ms | 只 setState，不发网络 |
| 首条结果出现 | < 1.5 s | NextMoe 单次请求实测 1.1~1.2 s（`kungal_link_service.dart:224` 注释引用同源实测） |
| 双源合并完成 | < 3.5 s | moyu 与 2DFan 并发；2DFan 域名回退最坏 5×4 s，**因此必须有 3.5 s 软超时并先出 moyu 结果** |
| 列表徽章预热 | 后台，2 路并发 | 照抄 `KungalLinkService._prefetchConcurrency = 2` |
| 磁盘缓存读 | < 5 ms | 同步读几 KB，对齐 `KungalLinkService._ensureDisk` 的首帧策略 |

**硬要求**：网络一律不进 `build()`；搜索框输入去抖 ≥ 300 ms（对齐 `library_page.dart` 的 `_searchSaveDebounce` 惯例）。

---

## 7. 实施阶段划分

### Phase 0 —— 技术验证（先证伪，再写业务代码）

| 编号 | 假设 | 方法 | 状态 |
|---|---|---|---|
| P0-1 | NextMoe moyu 面带密钥可达，且 `refs` 两种锚都能用 | 直接 curl 验证 | ✅ **已完成**（见 §3.2 ①②③） |
| P0-2 | 探索库真实标题 → NextMoe catalog 命中率可接受 | 取探索库 50 条真实 `title`，跑解析，统计命中率 | ⏳ **未做，最关键** |
| P0-3 | 2DFan `/subjects/{id}/downloads` 页面可解析 | 用真实 UA 抓 1 个页面，确认 `.download-card-title` / `a[href^="/downloads/"]` 存在 | ⏳ **未做**（本轮 WebFetch 返回空内容，疑似反爬或需真实 UA） |
| P0-4 | `refs=` 批量 100 条真的可以 | 传 100 个 vndb id | ⏳ 未做（3 条已验证上限内行为） |
| P0-5 | 新入口塞进探索库顶栏不溢出 | 按 `RESPONSIVE-CONTENT` 规则做 1280×720 与最小窗双尺寸渲染 | ⏳ 未做 |
| P0-6 | 社区资源里 `resource_type` 真含补丁分类且有数据 | 查 PB `game_resources` 实际记录 | ⏳ 未做 |

**Phase 0 出口判据**：P0-2 命中率 < 50% ⇒ 标题匹配不可作为主路径，必须回到 §13 O-1（拿 vndb id）；P0-3 失败 ⇒ **砍掉 2DFan**，本期只做 moyu + 社区。

### Phase 1 —— 数据层（纯 Dart，可离线探针）

1. `lib/models/patch_resource.dart` —— 模型
2. `lib/services/patch_sources/moyu_patch_source.dart` —— moyu 源（含 `@visibleForTesting` 静态解析出口，照 `TwoDFanService.parseSearchResultsForTest` 的范式）
3. `lib/services/nextmoe_identity_resolver.dart` —— 标题 → catalog id（照抄 `kungal_link_service.dart:226`）
4. `lib/services/patch_finder_service.dart` —— 聚合 + 缓存 + 降级

**出口**：`dev_probe/patch_finder_probe.dart` 跑通，不碰 UI。

### Phase 2 —— 2DFan 源（**P0-3 通过才做**）

5. `lib/services/patch_sources/two_dfan_patch_source.dart`
   - 复用 `TwoDFanService.kFanDomains`（**只读引用常量，不改那个包**）
   - 自建 Dio（连接 4 s / 接收 15 s + 代理），照 `two_dfan_service.dart:82-98`

### Phase 3 —— 社区源

6. `lib/services/patch_sources/community_patch_source.dart` —— 读 `game_resources`，按 `resourceTypes` 过滤补丁类

### Phase 4 —— UI（**等用户设计稿**）

7. 探索库顶栏入口 + 搜索浮层
8. 游戏详情「补丁」区

---

## 8. 改动文件清单

### 新增

| 文件 | 职责 |
|---|---|
| `lib/models/patch_resource.dart` | 统一补丁模型 |
| `lib/services/patch_sources/patch_source.dart` | 源抽象接口 |
| `lib/services/patch_sources/moyu_patch_source.dart` | NextMoe moyu 面 |
| `lib/services/patch_sources/two_dfan_patch_source.dart` | 2DFan 抓取（Phase 2） |
| `lib/services/patch_sources/community_patch_source.dart` | PB 社区资源（Phase 3） |
| `lib/services/nextmoe_identity_resolver.dart` | 标题 → catalog_work_id |
| `lib/services/patch_finder_service.dart` | 聚合 / 缓存 / 降级 |
| `dev_probe/patch_finder_probe.dart` | 离线探针 |
| `test/services/patch_finder_service_test.dart` | 单测（夹具驱动） |

### 修改（Phase 4，等设计稿）

| 文件 | 改什么 |
|---|---|
| `lib/pages/discover_page.dart` | 顶栏加入口（**不得破坏现有 `_searchController` 语义与顶栏 v3 筛选**） |
| `lib/pages/game_detail_page.dart` | 加补丁区 |

### 一期明确不碰

`lib/main.dart`、`lib/main_container.dart`、`lib/theme/`、`lib/core/portable_*.dart`、`lib/services/app_state.dart`、`windows/runner/`、`lib/packages/luna_metadata_sdk/`（**只 import 常量，零修改**）、`pubspec.yaml`（不新增依赖）、`lib/services/download_core.dart`、`lib/services/extract_manager.dart`、`lib/services/game_data_format.dart`

---

## 9. 调用点清单

| 优先级 | 调用点 | 动作 |
|---|---|---|
| P0 | `discover_page.dart` 顶栏 | 加「补丁查找」按钮；点击前**必须走 `_guardedGameTap` 同款协议门禁**（`explore_hall_page.dart:138`） |
| P0 | `game_detail_page.dart:741` 附近（「获取」按钮同级） | 加「补丁」入口 |
| P1 | 探索库列表卡片 | 后台预热徽章（Phase 0 P0-2/P0-4 通过后） |
| P2 | 全局搜索 | **不做**，避免与现有本地搜索语义混淆 |

🔴 **易漏的非 Widget 路径**：`_guardedGameTap` 有 6 个出口收口（见 `SESSION_HANDOFF`），新入口**不要自己再写一遍门禁判断**，直接调既有封装。

---

## 10. 风险登记

| 级别 | 风险 | 应对 |
|---|---|---|
| **P0** | 探索库游戏**没有 vndb/catalog id**，标题匹配命中率未知 | Phase 0 P0-2 实测；低于 50% 则必须先在 PB 侧补 `vndb_id` 字段（需用户批准，涉及云端 schema） |
| **P0** | 2DFan 抓取可能被反爬（本轮 WebFetch 返回空） | Phase 0 P0-3 用真实 UA 实测；失败即砍 2DFan，本期只留 moyu + 社区 |
| **P0** | 新入口撑破探索库顶栏（本项目高频坑：`PopupMenuButton` 默认 48×48） | 按钮必须显式 `minimumSize: Size(20,20)` + `tapTargetSize: shrinkWrap`；按 `RESPONSIVE-CONTENT` 做双尺寸渲染 |
| **P1** | 密钥 `nmk_live_...` 在源码常量里，泄漏风险 | 沿用既有处理（`nextmoe_service.dart:57-59` 已说明轮换流程），一期不新增泄漏面 |
| **P1** | 配额打爆（60/分） | 必须走 `executeRateLimited`；列表徽章只在可见 30 条预热，2 路并发 |
| **P1** | myou 契约变更（字段/端点） | 解析全部走 `safeString`/`safeList` 容错（对齐 `nextmoe_service.dart` 既有写法），**缺字段不许抛异常** |
| **P2** | 与 `KungalLinkService` 重复请求同一 work，浪费配额 | 一期各自缓存（最小变更）；二期抽 `NextMoeIdentityResolver` 共用 |
| **P2** | 用户误以为"补丁查找"能一键装 | UI 文案必须写明"打开原站下载"；二期再接下载 |
| **P2** | 内容分级 / NSFW | 沿用现有 `nsfw=true` 与 NSFW 检测机制；补丁列表按 `content_limit` 处理 |
| **P3** | 2DFan 换域名 | 复用 `kFanDomains` 常量（5 域名），不硬编码 |

---

## 11. 验收标准

**功能**

1. 搜"千恋万花"能出补丁列表，字段完整
2. 搜补丁名（如"汉化补丁"）能出结果
3. 点条目打开浏览器到正确 `web_url`
4. `note` 安装说明完整展示（含换行，长度可达数百字）
5. 断网 / 单源 404 → 有明确提示，探索库其他功能不受影响

**技术**

1. `./flutter/bin/flutter.bat analyze` 只关注**新增 error**（存量 info/warning 数百条，不要当指标）
2. 新增单测全绿；`test/` 全量基线**当场跑一次**，不引用历史数字
3. `git status` 确认无计划外文件
4. 1280×720 与最小窗双尺寸 `takeException() isNull` **且无被压扁**（`RESPONSIVE-CONTENT` 明确：0 溢出 ≠ 没问题）

---

## 12. 给执行 AI 的指令摘要

```
在 D:\CTLIB 实现「补丁查找（PATCH-FINDER）」Phase 1，严格按
docs/DEV/features/patch_finder_implementation_plan.md 执行。

必须遵守：
1. 先读 AGENTS.md 与 SESSION_HANDOFF.md；只做 Phase 1（数据层），不碰 UI。
2. 不改 lib/packages/luna_metadata_sdk/ 下任何文件，只 import NextMoeService.apiKey /
   apiBase 与 TwoDFanService.kFanDomains 这些 public 常量。
3. 不新增 pubspec 依赖（无 url_launcher、无新 http 库；用现有 dio）。
4. 不写 game.json，不改 format_version（保持 4）。
5. 每个网络解析都必须有 @visibleForTesting 静态纯函数出口，便于离线夹具测试。
6. 缺字段一律容错（safeString/safeList 风格），不许抛异常。
7. 限流必须走 executeRateLimited(SourceType.nextmoe, ...)。
8. 改完：analyze 只看新增 error → 写 dev_probe → 更新 DEV_LOG / SESSION_HANDOFF /
   features 文档 → 一任务一 commit（git add 显式文件，禁 -A）。

不要做：下载、解压、打补丁、回滚、2DFan 登录、PB 表结构变更。
```

---

## 13. 待用户决策的开放问题

| 编号 | 问题 | 为什么必须问 |
|---|---|---|
| **O-1** | **要不要给 PB `games` 表补一个 `vndb_id` 字段？** | 这是本期**最大的技术不确定性**。有 id → `refs=vndb:v<id>` 精确锚定 + 一次批量反查给整屏打徽章；没 id → 只能标题解析（贵、可能不准）。补字段属云端 schema 变更，需你批准 |
| O-2 | 社区资源（PB `game_resources`）的补丁要不要进一期？ | 你选了三源，但社区源走 OpenList 可下载，语义与"跳转原站"不同，可能要单独的下载链路 |
| O-3 | 补丁列表里 2DFan 与 moyu 重复（同一个补丁两边都有）怎么处理？ | 合并展示 / 分开列 / 只显示 moyu |
| O-4 | 是否申请 `moyu:files` scope？ | 不申请则二期"软件内下载补丁"依然做不到；申请需与 NextMoe 运营沟通 |

---

## 附：本轮未验证的部分（诚实声明）

- ❌ 未写任何业务代码，未跑 analyze / test
- ❌ 2DFan 补丁页可解析性未验证（WebFetch 返回空内容，原因未查明）
- ❌ 探索库真实标题 → NextMoe 命中率未测（Phase 0 的核心任务）
- ❌ `refs=` 批量 100 条上限未压测
- ❌ UI 未做，尺寸/溢出行为未知
- ✅ 已验证：moyu 面可达、两种 refs 锚、资源字段完整性、`/file` 的 403 门槛、批量反查的 `missing` 回执
