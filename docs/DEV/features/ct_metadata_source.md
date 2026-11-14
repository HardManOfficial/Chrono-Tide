# CT 探索库元数据源接入（2026-10-05）

## 1. 需求

将自有云端探索库（CT 探索库，PocketBase `games` 集合）作为内部元数据平台接入软件：

1. **元数据抓取接入**：所有元数据抓取功能（添加页一键抓取等）将 CT 与其他平台同等对待；抓取优先级 **NextMoe 之下、VNDB 之上**。
2. **作品选择入口**：一键抓取旁设定按钮旁新增「CT 探索库」按钮 → 弹窗展示全部作品 + 搜索 → 选中自动导入添加页左侧数据板块。

## 2. 实现

### 2.1 SDK 源（lib/packages/luna_metadata_sdk/）

| 文件 | 内容 |
|------|------|
| `lib/services/ct_service.dart`（新建） | `CTService implements MetadataSourceService`。Dio 直调 PB REST：`GET /api/collections/games/records?filter=(title~'kw')`（转义规则对齐 `lib/utils/pb_filter.dart`：控制字符折叠→截断64→先反斜杠后单引号）。文件字段拼 `{base}/api/files/games/{id}/{file}`。**强制直连**（`applyProxyConfig(null, _dio)` → 显式 DIRECT）：PB 在京东云（国内），不走用户代理，与探索页 PB 客户端行为一致。`apiBase` 常量与 `lib/core/pb_config.dart` 保持一致（SDK 不依赖主程序代码）。评分走 `normalizeRating`（云端 0-10 直通，100 分制兜底归一）；标签已是中文直通不走 TagTranslator；会社兼容旧字段 `Developer`（与 GameModel 同策略）。 |
| `lib/models/game.dart` | `SourceType.ct`（nextmoe 与 mix 之间），displayName `'CT'` |
| `lib/services/metadata_services.dart` | factory 加 ct 分支 |
| `lib/services/rate_limiter.dart` | ct 限流宽松（200ms / 100窗口，自建服务器） |
| `lib/luna_metadata_sdk.dart` | export ct_service.dart |

### 2.2 调度（lib/services/metadata_fetcher.dart）

- `kSourceOrder`：mix → nextmoe → **ct** → vndb → …（设置弹窗顺序、结果条目顺序唯一来源）。
- `_enabledSources` 默认含 ct；一次性迁移 `ct_source_migrated`（老配置默认补开，仅一次，对齐 nextmoe 迁移模式）。
- `_mixSources` 加入 ct；`_mixFieldPriority` **全部 9 个字段链**在 nextmoe 后插入 ct（CT 有 bannerUrl，`banner_url` 链同样生效）。
- `_instantiateService` 加 ct 分支；`_cacheVersion` 4→**5**（源解析变更，旧缓存整体失效）。
- 新增 `@visibleForTesting` 只读出口 `mixSourcesForTest` / `mixFieldPriorityForTest`（探针断言用）。

### 2.3 UI（lib/pages/join/）

| 文件 | 内容 |
|------|------|
| `metadata_section.dart` | 按钮组：相册 → 齿轮 → **「CT 探索库」**（travel_explore 图标）→ 一键抓取 |
| `ct_library_picker_dialog.dart`（新建） | 作品选择弹窗。数据走 `GameRepository.getAllGames()`（探索页同源：服务端分页驱动 + 单页重试 + id 去重）；本地搜索（标题/日文原名/英文名/繁中别名，大小写不敏感）；封面复用 `NsfwImage.network`（NSFW 检测与抓取卡片同款）；行内含别名/会社·年份/标签前4/评分角标；加载/失败重试/空结果三态。 |
| `join_controller.dart` | `importFromCtLibrary(GameModel)`：云端记录 → legacy map（对齐 `_convertToLegacyFormat` 字段名）→ 复用 `selectScrapeResult` 完整导入管线（标题/副标题/标签/简介/会社/截图/封面下载、字段锁定语义一致）。入库时 `metadataSource='CT'`、`metadataSourceId=云端作品id` 自动持久化。 |
| `platform_badge.dart` | `'ct'` 徽章（樱红 #C9506B，label 'CT'） |
| `metadata_source_settings_dialog.dart` | CT 描述 + 主色调；MIX 描述同步更新 |

## 3. 验证

- ✅ 静态检查：进程内 analyzer 探针 11 文件 **0 error**（warning/info 均为存量：deprecated adapter、unused field、metadata_services.dart:263 always-true 均非本次触碰区域）。231 期间 `flutter analyze`/`flutter test` 无法 spawn，按预案走进程内探针 + flutter_tester 离线探针。
- ✅ 离线探针 `.workbuddy/probe_ct/ct_probe.dart`（frontend_server_aot 编译 → flutter_tester 直跑）：**28 PASS / 0 FAIL**——覆盖解析（标题/副标题/URL 拼接/会社兼容/评分归一/标签双形态/缺字段降级）+ 调度优先级（kSourceOrder NextMoe<CT<VNDB、MIX 含 CT、全部字段链 CT 紧随 NextMoe）。
- ✅ `test/services/ct_service_test.dart`（新建，9 用例）与探针同断言集，待 `flutter test` 恢复后补跑。
- ⚠️ **未真机走查**（弹窗 UI / 搜索 / 选中导入 / 一键抓取 CT 条目 / MIX 条目字段来源）。

## 4. 已知边界与遗留

- ~~CT 搜索只做 `title` 服务端模糊匹配~~ → **已修复**（见 §5：四字段 OR + 全角折叠重试）。
- 匿名可读依赖 games 集合 listRule（与探索页同源）；服务端规则收紧会直接表现为 CT 源空结果（fetchLog 有 `[CT]` 前缀日志）。
- 工作区存在他人未提交改动（game_model.dart / game_publish_service.dart / publish_game_dialog.dart 等 9 文件），本任务提交只含显式列出的 12 个文件。

## 5. 搜索索引与别名（2026-10-05 第二轮：模糊搜索 + 别名识别）

### 5.1 问题与实证

用户反馈：一键抓取与探索库搜索"仅支持完全匹配游戏大标题"，别名/部分名称检索不到。
只读审计 + 线上实测（games 集合全量 299 条）：

| 实验组 | 结果 |
|--------|------|
| 仅 `title ~ '美少女万華鏡'`（日文原名搜简体标题库） | **0 命中** |
| 仅 `title ~ 'Mangekyou'`（英文名） | **0 命中** |
| `title/originalTitle/englishTitle/traditionalChineseTitle` 四字段 OR | **7 命中** |
| 全角关键词 `ＢＩＳＨＯＵＪＯＵ…` 原文 LIKE | **0 命中**（PB `~`=SQLite LIKE，不做全半角折叠） |
| 折叠为半角后重试 | **7 命中** |

字段映射排查（需求③）：`importFromCtLibrary`（join_controller.dart:610）与
`_convertToLegacyFormat`（metadata_fetcher.dart:1047）逐字段比对**无缺失错位**；
`Developer` 大写兼容（ct_service.dart:204）、coverUrl 文件名拼接均正确。
"部分数据未填入"的真实机制 = 搜索失败链（别名搜不到 → CT 空结果）+ 旧版
perPage=20 截断漏候选。

### 5.2 客户端改动

| 文件 | 改法 |
|------|------|
| `ct_service.dart` | ① `_nameSearchFilter`：四字段 OR filter（`_containsFilter` 重构为 `_escapePbLiteral` + 拼接）；② `fetchByName` perPage 20→**60** + **0 命中时全角→半角折叠重试**（`_foldFullWidth`/`_searchRecords` 抽取）；③ 新增 `static normalizeForSearch`（小写+全角折叠+去空白标点），`_pickBestMatch` 改用它；④ `nameSearchFilterForTesting` 测试出口 |
| `pb_filter.dart` | 新增 `PbFilter.nameSearchFilter`（同规则四字段 OR，SDK 不依赖主程序故两处内联） |
| `game_repository.dart` | `getGameList`/`getGameCount` 的 title 单字段 filter → `nameSearchFilter`（当前调用方未传 searchQuery，语义修正备将来） |
| `ct_library_picker_dialog.dart` | 本地搜索改走 `CTService.normalizeForSearch`（全半角/标点/大小写归一） |
| `test/services/ct_service_test.dart` | +5 用例：filter 四字段/转义/空输入/归一化/变体同键（共 15 例） |

探索页本地搜索（discover_page.dart:567-577）此前已覆盖标题/日文原名/英文/标签/会社，未动。

### 5.3 云端名称配置评估（需求②，结论：暂不改 schema）

全库 299 条统计：`originalTitle` 填充 **94.6%**、`englishTitle` **83.3%**、
`traditionalChineseTitle` **0%**、`title` 无重名。

- 当前结构 = 4 个固定命名槽位，无自由别名字段（VNDB 有 aliases 多值列表）。
- 四槽位 + 客户端四字段索引已覆盖 ~95% 记录的别名检索需求，**当前规模下达标**。
- 繁中字段 0/299 说明社区尚未使用该槽位；此时加 `aliases`（json list）字段
  属于"提前建空槽"，收益为零。
- **建议**（待社区数据量/管理员运营到位再落地）：PB games 集合新增
  `aliases`（JSON 多值）字段，收录缩写/罗马字/通称（如「万华镜」「白昼夢の青空」
  的通称）；客户端索引按字段清单实现，届时只需在 `_nameSearchFilter` /
  `PbFilter.nameSearchFilter` / 弹窗 haystack 各加一个字段名。

### 5.4 验证

- ✅ `flutter analyze`（原生恢复）5 改动文件 0 error；复验 ct_service+test **No issues found**。
- ✅ `flutter test test/services/ct_service_test.dart` **15/15 全绿**。
- ✅ 线上端到端：四字段 OR 7 命中、全角折叠重试 0→7 命中（curl 实测）。
- ⚠️ 未真机走查：添加页一键抓取别名搜索、CT 弹窗归一化搜索、探索页搜索。

---

## 6. 名称索引能力修复（2026-10-10）

### 6.1 现象与根因（线上只读探测坐实）

用户实测：**探索页搜索能命中**的名称，填入添加页「一键抓取」后 CT 源却**索引不到**。

| 线上检索词 | 修复前 | 说明 |
|---|---|---|
| `突然＊恋人` | 命中 1 | 与库内标题字面一致 |
| `突然恋人`（去＊，用户自然会这么打） | **0 命中** | |
| `Making Lovers`（英文带空格） | **0 命中** | 该记录 `englishTitle = "Making * Lovers FHD Deluxe Edition"` |

根因：PB 的 `~` 是 SQLite LIKE，**只做全半角折叠、不剥标点/空格**；而探索页/CT 弹窗
走本机 `normalizeForSearch`（剥标点 + 全半角 + 小写）→ 两套口径不一致。
且 `normalizeForSearch` 当时**不剥 `*`**，与分词口径亦不一致（最后一环）。

### 6.2 修法（`ct_service.dart` 为主）

1. **分词多查询召回** `_recallRecords`：整串 + 逐段（CJK≥4 字滑窗 2-gram / 拉丁词≥3 字）
   四字段 OR 并集去重（单段 `perPage=60`、候选上限 120、分词上限 6）。
   `突然恋人 → [突然,然恋,恋人]` 即可召回 `突然＊恋人`。
2. **精度闸** `_pickBestMatch`：候选须**包含全部关键词段**（归一化 AND 门）才入选；
   某名称与查询**完全相等**时直接采用；**删除「全 0 分回退第一条」**（张冠李戴根因）。
3. **噪声集合补符号**：`normalizeForSearch` 的噪声集补入 `*＊×✕✖☆★♪♫※|｜`；
   补后 CT 弹窗本地搜索同受益（口径统一）。
4. **别名透传**：SDK `Game` 新增可空 `aliasNames`（CT 汇总
   `originalTitle/englishTitle/traditionalChineseTitle`，去重、剔主标题、保序）；
   `_convertToLegacyFormat` 增 `alias_names`；MIX 优先级 `alias_names: [ct, nextmoe, vndb, kun]`。
5. `metadata_fetcher._cacheVersion` **5 → 6**（旧缓存整体失效）。

### 6.3 验证

- ✅ `flutter analyze` 改动文件 **0 新增 error / warning**；`ct_service_test` 24 例 +
  `test/services/subtitle_composer_test.dart` 8 例**全绿**。
- ✅ **线上只读回归**（`.workbuddy/tmp_probe/ct_index_probe.py`，纯 GET 无写操作）：
  `突然恋人`→HIT(score 100)、`Making Lovers`→HIT(score 100)、`突然＊恋人`→HIT、
  负例 `zzz不存在的游戏qqq`→**NO MATCH**（不再误选）。
- ⏳ 未真机走查：添加页一键抓取（CT 源）别名/去标点搜索、CT 弹窗搜索。
