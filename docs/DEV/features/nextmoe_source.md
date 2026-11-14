# 功能档案：NextMoe 元数据源接入

| 项 | 值 |
|----|-----|
| **状态** | 已上线（待发布验证） |
| **优先级** | P1 |
| **创建日期** | 2026-09-05 |
| **最后更新** | 2026-09-06 |
| **关联需求单** | NextMoe元数据平台源全面接入（用户需求 2026-09-05） |

---

## 1. 目标：解决什么问题

接入 NextMoe·未萌（https://developer.nextmoe.dev）作为独立元数据源。
NextMoe 是「六源对齐目录」：同一部作品在 VNDB/Bangumi/DLsite/ErogameScape/
Ci-en/Getchu 各有一条记录，NextMoe 将其对齐成一条「裁定后」记录并逐字段标注
出处，天然提供**中英文标题/简介/标签齐全**的高质量数据。

接入后 NextMoe 成为所有数据抓取的**最高优先级**（MIX 源全字段第一优先级），
其他源在其缺失/异常时依次降级。同时它是元数据抓取设定窗口的**第二平台**
（仅次于 MIX 源）。

## 2. 用户可见行为

- 添加页「一键抓取」：结果列表出现独立的「NextMoe」条目（第二位，仅次于 MIX源）。
- MIX 源：标题/副标题/简介/会社/标签/截图/评分全部优先取自 NextMoe。
- 「抓取数据源设定」弹窗：NextMoe 排第二位，默认勾选；
  描述「NextMoe 六源对齐目录 · 中英文标题/简介/标签齐全，最高优先级」，
  强调色 `0xFFE85D9E`（品红）。
- 批量导入：默认走 MIX 源 → 自动享受 NextMoe 最高优先级。
- 老用户升级：一次性迁移自动补开 NextMoe（`nextmoe_source_migrated` 标记），
  用户手动关闭后不会再被自动打开。
- 游戏详情页截图补全：NextMoe 截图（`image.kungal.iloveren.link` CDN webp）
  优先于 KunGal/Hikarinagi/VNDB。

## 3. 设计思路：为什么这么做

### 3.1 与现有源同等架构，不做特殊处理

NextMoeService 与 KunService/VNDBService 等一样实现
`MetadataSourceService` 接口（`fetchByName`/`fetchByIds`/`testConnection`），
经 `MetadataFetcher._instantiateService` 工厂创建、走统一代理三级检测
（app配置 > Windows系统代理 > 环境变量）与 RateLimiter 限流。
唯一"特殊"处是鉴权头内置源码常量（与 TouchGal Token 同等处理方式，
桌面应用无服务端可托管密钥）。

### 3.2 MIX 优先级：NextMoe 全字段第一

`_mixFieldPriority` 中所有字段（cover_url/original_title/summary/tags/
developer/screenshot_urls/rating）都以 `SourceType.nextmoe` 开头，
其余平台保持原有相对顺序依次降级。理由：NextMoe 的数据本来就是六源
「裁定后」的标准答案，且中文数据齐全，无需再按字段挑源。

评分权威链保持 vndb 优先（NextMoe ratings[] 解析时优先取 vndb 源评分，
与既有 MIX 评分语义一致），次 bangumi（10分制）、erogamescape（100分制
经 normalizeRating 归一）。

### 3.3 被否决的方案

- **NextMoe 直接替代 MIX 的底层平台**：否决。其他源仍有 NextMoe 未收录
  的作品，降级链必须完整；且用户勾选的独立源条目（供对比选择）不能少。
- **密钥走用户输入/SharedPreferences**：否决。NextMoe 密钥是应用级密钥
  （scope: catalog:read），非个人令牌，参照 Hikarinagi/TouchGal 用源码常量。
  轮换时改 `NextMoeService.apiKey` 常量重发版即可。

## 4. 实现位置

| 文件 | 职责 | 备注 |
|------|------|------|
| `lib/packages/luna_metadata_sdk/lib/services/nextmoe_service.dart` | NextMoeService：鉴权/搜索/详情/解析 | 核心，新建 |
| `lib/packages/luna_metadata_sdk/lib/models/game.dart` | `SourceType.nextmoe` 枚举 + displayName | |
| `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart` | SDK 工厂分支（LunaBox 风格） | line ~1590 |
| `lib/packages/luna_metadata_sdk/lib/services/rate_limiter.dart` | NextMoe 限流 55/分 + 1100ms 最小间隔 | |
| `lib/packages/luna_metadata_sdk/lib/luna_metadata_sdk.dart` | 导出 nextmoe_service.dart | |
| `lib/services/metadata_fetcher.dart` | kSourceOrder 第二位 / _enabledSources 默认开 / _mixSources 首位 / _mixFieldPriority 全字段首位 / 一次性迁移 / 缓存版本 v4 / _instantiateService 工厂 / fetchScreenshots 默认源首位 | |
| `lib/pages/join/widgets/metadata_source_settings_dialog.dart` | 弹窗描述 + 强调色 | |
| `test/services/nextmoe_service_test.dart` | 单元测试（fixture 离线，18 用例） | |
| `test/services/nextmoe_integration_test.dart` | 集成测试（真实 API，7 用例） | |
| `test/services/metadata_source_order_test.dart` | 平台顺序断言更新（NextMoe 第二） | |

## 5. 关键数据结构（API 调用说明）

### 5.1 端点与鉴权

- Base：`https://api.nextmoe.dev/v2`
- 鉴权：`Authorization: Bearer nmk_live_…`（应用密钥，scope: catalog:read）
- 搜索：`GET /catalog/search?object=work&q={关键词}&nsfw=true`
- 详情：`GET /catalog/works/{id}?nsfw=true&include=titles,intros,covers,screenshots,companies,tags,ratings`
- 连接测试：`GET /catalog/stats`（匿名可调，不消耗密钥配额）

### 5.2 响应契约（v2 conventions，踩坑点）

- **无信封**：响应体就是集合/对象本身，没有 `code/message/data` 包裹。
- **id 为十进制字符串**（int64 直发 JSON number 会失真），解析时按 String 处理。
- **include 点名**：详情默认只有「身份内核」，titles/intros/tags 等数据块
  必须在 `include=` 里显式列出，否则响应里根本没有这些字段。
- **nsfw=true**：显式开启成人内容可见性；写别的值是 400 而非按默认处理。
- 翻页只有 `next_cursor`（末页不出现该键）；本服务单页搜索无需翻页。

### 5.3 字段解析链

| 目标字段 | 解析逻辑 |
|----------|----------|
| 主标题 | `localized` 按 zh-Hans → zh-Hant → 任意 zh* → display_name |
| 副标题 | `titles[]` 中 lang=ja 且 title_kind=official；无则 display_name |
| 简介 | `intros[]` 按 zh-Hans → zh-Hant → zh → ja → en → 任意 zh* |
| 评分 | `ratings[]` 多源并列：vndb → bangumi → erogamescape（归一到10分制），vote_count 同源取 |
| 会社 | `companies[]` 优先 attribution_role=developer，次 publisher |
| 标签 | 剔除 tier=hidden / tag_kind=meta（Galgame/PC 平台元标签）与剧透标签；英文(vndb源)经 TagTranslator 翻译，中文(bangumi源)直通；取前10 |
| 截图 | `screenshots[].url`（hash 命名 webp CDN 直链），取前6张 |

### 5.4 限流

- 官方 free 档：60 次/分 · 50,000 次/日，超限 429 + `Retry-After`。
- 本项目配置：55 次/分（安全余量）+ 1100ms 最小间隔
  （每游戏消耗 2 次：搜索+详情）。
- 429 退避由 `RateLimiter`/`executeRateLimited` 统一处理（指数退避 1s→2s→4s，
  上限 30s，优先读 Retry-After 头）。

## 6. 数据处理流程

```
用户输入游戏名
  │
  ├─ fetchByName(name)
  │    ├─ GET /catalog/search?q=…&nsfw=true   （限流 acquire）
  │    ├─ _pickBestMatch：display_name + localized 各语言名
  │    │   打分（精确100/前缀40/包含20），取最高分项的 id
  │    ├─ GET /catalog/works/{id}?include=…    （限流 acquire）
  │    └─ _parseDetail → MetadataResult(Game + tags)
  │
  ├─ MIX 整合（fetchGameMixed）：NextMoe 与其余 5 平台并发抓取
  │   → _mergeMixResults 按 _mixFieldPriority 逐字段取第一个非空值
  │   → NextMoe 全字段首位：其有值则用，缺失/异常自动降级到 VNDB/KunGal/…
  │
  └─ 一键抓取（fetchGame）：NextMoe 独立条目（第二位）+ MIX 条目（首位）共存
```

缓存：24h TTL 磁盘缓存；**缓存版本已升到 v4**（`_cacheVersion = 4`），
旧 MIX 结果（无 NextMoe）整体自动失效重抓。

## 7. 历史决策与踩过的坑

- **接入期「外部编辑静默回退」事故（2026-09-06）**：编辑工具写入虚拟层
  未同步真实磁盘，kSourceOrder/_enabledSources 等改动多次被回退，表现为
  集成测试持续失败（NextMoe 条目不出现）。教训：**关键编辑后必须用
  `rg`（Shell，读真实磁盘）验证落盘**，与 2026-08-09 回退事故同模式。
  后续对本项目文件的敏感编辑建议直接 Shell 直写 + 立即 rg 验证。
- **_instantiateService 缺 nextmoe 分支**：SDK 工厂加了分支但
  MetadataFetcher 侧工厂漏了，报「不支持的数据源: SourceType.nextmoe」。
  教训：新增源要同时改两处工厂（metadata_services.dart 与
  metadata_fetcher.dart 的 _instantiateService）。
- **详情接口不写 include= 则字段全空**：v2 默认瘦身响应，测试时若发现
  标题有但简介/标签全空，先检查 include 参数。
- **评分刻度**：NextMoe ratings 各源保持原生刻度（vndb 10分/bangumi 10分/
  erogamescape 100分），解析时必须 normalizeRating，否则评分语义错乱。

## 8. 当前进度

- [x] SDK：SourceType.nextmoe 枚举 + NextMoeService（鉴权/搜索/详情/解析）
- [x] SDK：限流器（55/分）/两处工厂/导出接入
- [x] MetadataFetcher：MIX 字段优先级全字段首位 / kSourceOrder 第二位 /
      默认启用 / 一次性迁移 / 缓存版本 v4 / 截图抓取首位
- [x] 设置弹窗：NextMoe 第二平台 + 描述/配色
- [x] 单元测试 18/18（fixture 离线：多语言标题/简介链、评分归一、
      标签过滤、限流配置）
- [x] 集成测试 7/7（真实 API：鉴权、中/日文名搜索、MIX 优先级、
      缓存命中 7-10ms、一键抓取第二位、截图首位）
- [x] 静态检查：新增代码 0 error 0 warning（仅存量 info）
- [ ] 真机（打包版）验证：需 `flutter build windows` 完整重建后实测

## 9. 已知问题

| 问题 | 严重度 | 是否已定位 | 备注 |
|------|--------|-----------|------|
| 集成测试偶发「连接测试」失败 | P3 | 是 | 网络抖动（NextMoe API 偶尔响应慢/超时），单独重跑即通过；产品路径有降级链兜底 |
| 编辑虚拟层与真实磁盘不同步 | P2 | 是 | 见第7节坑1；工作around=Shell直写+rg验证 |

## 10. 灰度发布策略

桌面应用无服务端流量开关，灰度按以下顺序执行：

1. **本仓库验证**（已完成）：单元/集成/静态检查全绿。
2. **打包自测**：`flutter build windows` 重建后，在打包目录实测
   一键抓取/批量导入/探索页三条路径的 NextMoe 条目与 MIX 优先级。
3. **小范围发布**：先发便携版（ChronoTide.7z）给少量用户，
   观察用户数据目录 `metadata_fetch.log` 中 `[nextmoe]` 成功率
   与 429 频率（日志含每源耗时与结果状态）。
4. **全量发布**：无异常后发安装版。回滚方案：设置弹窗手动取消勾选
   NextMoe（独立条目与 MIX 首位同时失效，降级链回到原 VNDB 优先），
   无需回退版本；极端情况回退上一版本安装包（缓存版本号会自动作废
   NextMoe 时代的 MIX 缓存）。
5. **监控指标**：`metadata_fetch.log` 的 `[SourceType.nextmoe]` 行——
   ✅ 成功率、⚠️ 无效率、❌ 异常率与耗时；429 出现说明触达限流阈值，
   需下调 RateLimiter 配置。

## 11. 维护指南

- **密钥轮换**：泄漏或到期时到 https://developer.nextmoe.dev/dashboard
  控制台吊销重铸，替换 `NextMoeService.apiKey` 常量，重发版。
- **限流档位变更**：改 `rate_limiter.dart` 中 `SourceType.nextmoe` 分支
  （当前 55/分 + 1100ms 最小间隔）。
- **API 版本升级**：NextMoe v3 若发布，改 `NextMoeService.apiBase` 并
  按新契约调整 `_parseDetail`；同步把 `_cacheVersion` +1 使旧缓存失效。
- **新增数据块**（如 staff/音乐）：在详情请求的 `include=` 追加块名，
  在 `_parseDetail` 增加解析，勿动其他字段链。
- **关闭 NextMoe**：设置弹窗取消勾选即可（产品级）；
  代码级可将 `_enabledSources`/`kSourceOrder` 中 nextmoe 移除，
  MIX 的 `_mixFieldPriority` 各字段首位去掉 nextmoe 即回到旧行为。

## 12. ⛔ 不要动的地方

- `_mixFieldPriority` 各字段中 `SourceType.nextmoe` 必须保持**首位**——
  这是本次接入的核心需求（全字段最高优先级），调整顺序=改变产品决策。
- `kSourceOrder` 中 nextmoe 固定**第二位**（mix 之后）——弹窗展示、
  默认启用、结果排序三处共用此常量，改一处即三处联动错位。
- `_cacheVersion = 4` 不要回调——v4 以下旧 MIX 缓存无 NextMoe 数据。
- `nextmoe_source_migrated` 迁移标记是一次性的，删除会导致已手动关闭
  NextMoe 的用户被再次强制打开（违反「仅此一次」承诺）。
- NextMoe 详情请求的 `include=` 列表勿删减——v2 瘦身响应下删一个块名
  就少一类字段。
