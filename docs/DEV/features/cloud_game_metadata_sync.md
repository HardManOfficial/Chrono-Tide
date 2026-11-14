# 云端游戏数据扩展：元数据沉淀与复用（v2.1.17）

> 状态：**代码完成、单测 9/9 通过、analyze 0 新增 error；待真机验证**
> 日期：2026-09-11　提交：（本次）

---

## 0. 追记（2026-10-04）：estimatedMinutes 接通

「预计游玩时长」（VNDB `length_minutes`，多用户平均游玩时长，分钟）补进同一条
云端沉淀链路，机制与 rating/voteCount 完全一致：

| 层 | 改动 |
|------|------|
| PB `games` | 新增字段 `estimatedMinutes`(number, onlyInt)。**服务端动作**：本地 pb_dev 已加并验证（写 1420 读回一致）；**线上需后台建字段**（见 §7 同款流程），未建期间回传 400 → 熔断，rating/voteCount 不受影响（同一 PATCH，字段缺失整单被拒） |
| `GameModel` | 新增 `estimatedMinutes`（`_safeGetPositiveInt`，<=0/缺失 → null）；`hasCloudMetadata` 纳入该字段 |
| `GameRepository` | `buildMetadataBody`/`updateGameMetadata` 增参，只写有效值口径不变 |
| `DiscoverMetadataService` | 云端登记（下发）与 `_reportToCloud`（上传）透传 |
| 测试 | `cloud_game_metadata_sync_test.dart` 9→**13**（解析/0 值/字符串兼容/body 构造/云端登记） |

展示链路：云端登记 → `DiscoverGameMetadata.estimatedMinutes` → 探索详情页
chip（`game_detail_page.dart:1906`）；库详情窗口读的是 game.json 本地字段
（`game_detail_dialog.dart`），不经云端。

### 0.1 缺口回填（2026-10-04 追加，b0aed6a 之后）

**问题**：线上建字段后实测探索页无任何游戏显示预计时长（库详情窗口正常）。
根因：estimatedMinutes 晚于 rating/voteCount 上云，存量云端记录该字段全为
默认值 0（模型归一 null），而 `ensureMetadata` 对 fromCloud 条目**永不重抓**
（:223）→ 探索详情永远拿不到预计时长；库详情窗口走本地 game.json 回填，
不受影响。上一轮沉淀把评分写满云端 = 补抓路径全被「免抓取」短路。

**修复（方案 A，详情页缺口回填）**：

- `DiscoverMetadataService.ensureEstimatedMinutes(gameId, title)`（:244 附近）：
  无缓存 → 等价 ensureMetadata；fromCloud 且缺 estimatedMinutes → 补抓一次
  （全局串行锁 + 24h 缓存），抓到按「本地 > 云端」覆盖缓存并经
  `_reportToCloud` 自动回传；其余零开销返回。纯判定拆为
  `needsEstimatedMinutesBackfill`（@visibleForTesting，可离线单测）。
- `game_detail_page.dart:269`：详情加载改调新方法。
- 测试 +4 例（判定矩阵）。效果：打开探索详情 → 立即补显 + 回传云端，
  云端随使用自然补全；不需要一次性批量脚本（方案 B 备选未启用）。


---

## 1. 背景与问题

探索库（探索页 / 探索大厅）里的**星级（rating）、评分人数（voteCount）、
发售日（releaseDate）**原本**不在云端**，全部靠每台机器各自跑元数据抓取：

- `DiscoverMetadataService` 视口懒加载 + 7 天本地磁盘缓存；
- `ExploreCalendarService.startWarmup` 为月历聚合并发补抓全量缺失项（24h 节流）；
- `DailyRecommendationService` 依赖 rating/voteCount 排推荐。

后果：进入探索库即触发一轮大批量抓取，加载压力大；元数据没到位时
评分角标、评分/年份筛选、按评分/热度排序、月历聚合、每日推荐全部受影响。

## 2. 方案：照搬探索页截图机制

截图（`game_detail_page.dart` `_loadScreenshotsParallel` / `_uploadScreenshotsToPB`）
的既有机制正是：

| 步骤 | 截图 | 元数据（本次） |
|------|------|----------------|
| ① 云端有？ | 读 PB `screenshots` 字段，有则直接用 | 读 PB `rating`/`voteCount`/`releaseDate`/`metaSource` |
| ② 云端无 | 走本地已安装 → 多平台抓取 | 走既有 `MetadataFetcher` 抓取（逻辑不变） |
| ③ 回传 | 下载图片 → multipart PATCH 回 PB | 抓取成功 → PATCH 标量字段回 PB |
| ④ 失败处理 | 静默，不影响展示 | 静默，不影响展示 |

差异：截图是**文件字段**（multipart），元数据是**标量字段**（JSON body）；
回传点从「仅详情页」扩展为「所有抓取点」（用户拍板）。

## 3. 服务端前置条件（🔴 必须先做）

PB `games` 集合需新增字段（名称已与用户确认）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `rating` | number | 0-10 分制；<=0 视为无 |
| `voteCount` | number | 评分/投票人数；<=0 视为无 |
| `releaseDate` | text | ISO `YYYY-MM-DD`（用 text 而非 date：源站常只有年月） |
| `metaSource` | text | 来源平台，如 `VNDB` |

未建字段 → 回传 400 → 日志提示 + 本次运行熔断（`rejected`）。

> 注：PB 对游客不可读（实测 `getList` 返回 0 条），字段名无法从客户端自查，
> 必须与后台保持一致。

## 4. 代码改动

| 文件 | 改动 |
|------|------|
| `lib/models/game_model.dart` | 新增 4 字段 + `_safeGetPositiveDouble` / `_safeGetPositiveInt`（<=0 → null）+ `hasCloudMetadata` + copyWith |
| `lib/repositories/game_repository.dart` | `GameMetadataUploadStatus` 枚举、`buildMetadataBody`（纯函数、只写有效值、trim）、`updateGameMetadata`、`canUploadMetadata` |
| `lib/services/discover_metadata_service.dart` | `fromCloud` 标记、`registerCloudMetadata(All)`、`ensureMetadata` 云端免抓、`_reportToCloud` 回传（去重/未登录跳过/rejected 熔断）、云端条目不落盘 |
| `lib/pages/discover_page.dart` | 首屏 / 全量 / 加载更多 三处 `registerCloudMetadataAll` |
| `lib/services/explore_calendar_service.dart` | 全量加载后登记（月历预热 + 每日推荐受益） |
| `lib/pages/game_detail_page.dart` | 详情加载后 `registerCloudMetadata` |

### 优先级规则（🔴 勿回退）

**本地已抓取结果 > 云端沉淀数据**。云端只填补「还没抓过」的空洞，
不覆盖本轮真实抓取所得（避免云端脏数据压掉本地准确值）。

## 5. 关键设计点

1. **云端条目无 TTL**：`ensureMetadata` 见 `fromCloud` 直接返回，永不重抓。
2. **云端条目不落本地磁盘**：`_persistCache` 过滤 `fromCloud`，
   每次启动重新从云端读，避免本地留存过期副本。
3. **回传熔断**：400/403/404 → `_uploadDisabled = true`，本次运行不再尝试；
   网络失败不熔断（可下次再试）。
4. **回传去重**：`_uploadedIds` 保证同一 gameId 一轮只 PATCH 一次。
5. **未登录不回传**：与截图回传同一约束（`PBConfig.isLoggedIn`）。

## 6. 验证

- `test/services/cloud_game_metadata_sync_test.dart` 9/9：
  字段解析（含 0 值/字符串兼容）、body 构造只写有效值、
  云端登记与 fromCloud 标记、本地优先不被覆盖、批量只 notify 一次。
- 改动文件 `flutter analyze` 0 新增 error。
- 全量测试零回归（见 DEV_LOG 当日条目）。

## 7. 真机验证清单（🔴 待做）

1. 先在 PB 后台建 4 个字段（见 §3）。
2. 登录账号 → 打开探索页：日志应出现 `☁️ 云端元数据命中 N 条（免抓取）`（首次为 0）。
3. 打开一部云端无评分的作品详情 → 抓取成功后日志出现
   `☁️ 元数据已回传云端: <标题>`；PB 后台确认该记录 4 个字段已写入。
4. 重启应用再进探索页 → 该作品评分角标**立即显示**（无抓取等待），
   `☁️ 云端元数据命中` 计数增加。
5. 第二次启动后月历预热耗时显著下降（缺失项变少）。
6. 未登录时：回传跳过，日志 `⏭️ 未登录，抓取结果不回传云端`，展示不受影响。
7. 故意删掉 PB 某字段（模拟未建字段）→ 回传 400 → 日志提示且本次不再重试。

## 8. 遗留

- 未登录用户的抓取结果不回传（与截图一致，属刻意约束）。
- 云端数据无 TTL，字段口径变更（如评分改 5 分制）需后台自行清理/重算。
- 「加载更多」分页只登记当页增量，其余由全量加载覆盖。
