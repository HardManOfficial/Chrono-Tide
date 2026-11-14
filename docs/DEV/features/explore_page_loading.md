# 探索页加载机制优化（v2.1.16）

> 状态：**代码完成、NSFW 专项 102/102 全过，待真机走查**。
> 日期：2026-09-09　关联：`network_reliability.md`（上轮网络韧性）、
> `nsfw_filter_implementation_plan.md`（检测链路）

## 1. 用户原始反馈

「探索页游戏列表的各种加载非常不稳定，经常卡加载，莫名将加载好的封面重加载。」

## 2. 审计定位的根因（三条独立问题互相放大）

### P0-A 封面"莫名重加载"（实为清晰后回模糊的循环）

探索页封面是网络图 + `detectOnDemand: true`（`discover_page.dart:1390-1417`），
NSFW 默认开启（enabled=true + clean，`nsfw_settings.dart`）→ 未判定图走模糊预览。
旧按需检测链路（`nsfw_image.dart` 网络分支）：

1. 组件内轮询 `PortableImageCacheManager().getFileFromCache(url)` 查"是否已落盘"，
   重试窗口仅 **2 次 / 1.5s**；
2. 封面从 VPS 下载普遍 >1.5s → 两次都查不到 → 置 `_detectionGaveUp` 放行原图，
   **全程从未调用 enqueueFile** → 判定缓存（store）永远没有这张图；
3. GridView 滚动回收销毁组件 State（gaveUp 是局部变量）→ 滚回来重建 →
   又一遍「模糊预览 → 1.5s 轮询 → 放弃」→ **每次滚动往返都重现模糊**。

SESSION_HANDOFF 2026-09-08 记录的遗留「gaveUp 放行图（store 无记录）在滚动
回收/切页等 State 重建场景仍会重现模糊；根治需放行状态上移到 store 层」——
本条即该遗留的落地。注意**没有**把 gaveUp 状态持久化（fail-open 持久化会让
敏感图永久裸奔），而是根治"从未入队"这个上游洞：判定结果一旦落库，
重建后 `_readStore` 秒命中，模糊循环自然消失。

### P1-B 预渲染区挤占下载并发槽

`discover_page.dart` 原为 `cacheExtent: 4000`（视口外约 10 行预渲染）→
几十张视口外封面提前进入下载队列；`flutter_cache_manager 3.4.1` 的下载并发
上限为 **10**（`file_service.dart:17` `concurrentFetches = 10`，FIFO 队列）→
可见卡片的封面只能在视口外请求后面排队（"卡加载"）。

### P1-C 全量数据加载"一页失败 → 整轮重拉"循环

`game_repository.dart` `getAllGames` 分页并发抓取时单页失败直接跳过 →
`isComplete=false` → 调用方 15s 自愈重拉整轮（60s 超时）。VPS 慢响应抖动
常见时反复循环，表现为列表加载时好时坏。

## 3. 改动（4 文件）

| 文件 | 改动 |
|------|------|
| `lib/services/nsfw/nsfw_detection_service.dart` | 新增 `ensureUrlDetection(url)` + `_waitCacheAndEnqueue`（:315-352）：服务级"等落盘 → 入队"。`getFileStream` 与 child 的下载走同一 CacheManager 单例，WebHelper `_memCache` 对同 URL 并发下载合并（**不产生第二次请求**，已核对 3.4.1 源码 `web_helper.dart:36-44`）；落盘后 `enqueueFile(aliasUrl: url, highPriority: true)` 双键写入（文件路径主键 + URL 别名键）；去重集合 `_urlDetectionInFlight` 防滚动重建重复发起；下载失败仅移除标记，组件重建时自然重试（有界循环） |
| `lib/widgets/nsfw/nsfw_image.dart` | 网络分支（:543-566）改为一次性调用 `ensureUrlDetection`；删除 `_onDemandAttempts` 计数 + 1.5s Timer 轮询 + 2 次封顶 gaveUp 块；删无用 `flutter_cache_manager` import。**本地文件重试链（`_localRetries`）零改动**；模糊看门狗（800ms 插队 / 30s 放行兜底）保留，服务不可用时兜底不变 |
| `lib/repositories/game_repository.dart` | `getAllGames` 单页失败重试 1 次（2s 退避）再跳过（:155-172），减少 isComplete=false 触发的整轮自愈重拉 |
| `lib/pages/discover_page.dart` | `cacheExtent` 4000 → **1200**（:1232-1235，约上下各 1.5 行）；快速滚动空档由占位底色渐入兜底 |

## 4. 效果与不变量

- **判定结果必然落库** → 滚动回收重建后秒清晰，"已清晰封面滚回来又模糊"根治；
- 安全性不降级：敏感图判定照常打码；30s 看门狗放行仅是运行时兜底（组件存活期内），
  不持久化 fail-open 状态；
- 本地文件图的按需检测行为完全不变（NSFW 专项 102 用例零改动全过）。

## 5. 验证

- ✅ `flutter analyze` 4 文件：0 error（11 条均为存量 lint，远离改动行）；
- ✅ NSFW 专项 `test/widgets/nsfw/ + test/services/nsfw/`：**102/102 通过**；
- ✅ 全量 `flutter test test/`：基线一致零新增失败（13 个失败 = big_picture/
  widgets 存量）；
- ⚠️ **未做真机验证**，走查清单：
  1. NSFW 开启（纯净模式）下探索页首次加载：封面模糊 → 数秒内批量清晰
     （此前部分封面清晰后又回模糊）；
  2. **滚动到深处再滚回来**：已清晰的封面立即清晰（不重现模糊）；
  3. 快速滚动观察：新进入卡片灰底占位渐入是否可接受（改动 3 的权衡项，
     不可接受可回调 2000）；
  4. 正常网络下列表加载不再反复"闪加载"（全量自愈重拉减少）；
  5. 敏感封面仍被模糊 + NSFW 角标（判定打码路径未受影响）。

## 6. 遗留 / 未做

- Flutter 内存图片缓存（默认 100MB）回收后滚回视口会从磁盘重新解码，
  有短暂占位——属引擎行为，扩容需动 `main.dart`（稳定区），本轮未做；
- BPM 大屏探索页 `big_picture_discover.dart:582` 未解析直链（P0，另行批准）；
- 网络图入队仍为 highPriority（现状语义保留），库页大批封面场景与截图
  判定的优先级竞争未调整。

---

## 8. 数据新鲜度：进程不退出就看不到新作品（2026-10-24 修复）

> 关联需求：管理员在管理器运行期间上传官方作品 → 回探索库看不到，必须重启。
> 代码：`lib/pages/discover_page.dart`、`lib/widgets/game_detail/upload_publish_dialog.dart`

### 8.1 三处叠加的根因

| # | 位置 | 事实 |
|---|------|------|
| 1 | `explore_hall_page.dart:224-227` | 大厅/探索库 `Offstage` 双保活，切回不重建 State，`initState` 不跑 |
| 2 | `discover_page.dart` `initState` 快照分支 | 有 `static _cachedAllGames` 就 `return`，**不发请求** |
| 3 | 同处 | 恢复快照时写 `_cacheTime = DateTime.now()` ⇒ 30 分钟 TTL 从「页面重建」起算 |

叠加后：进程活着 ⇒ 快照永不过期。上传链路还完全没有刷新信号（只 `onClose()`）。

### 8.2 现行机制（改后的契约，别退化）

1. **首帧快照**：`static _cachedAllGames` 仍用于首帧渲染 —— 保证进库不闪白，
   **不要**为了「拿最新数据」改成先请求后渲染。
2. **静默增量**：`postFrameCallback` 里跑 `_refreshIncremental()`，拉
   `getGameList(page:1, perPage:20)`（仓库固定 `sort=-created`，新作必在第一页）。
   - 按 gameId 去重，**只有存在新 id 才 `setState`**；纯更新场景零重建
   - 新条目**前插**，不动 `_allGames` 其余部分与滚动位置
   - `_isLoadingAll` / `_isLoadingMore` 进行中让路；**await 后二次校验**
     （期间全量加载已接管则丢弃本次，否则会把已删条目插回）
   - 失败静默
3. **TTL 只由真实拉取刷新**：`_cacheTime` 只在「首屏拉取成功」与「增量拉取成功」
   两处赋值。🔴 再从别处赋值就会退回到本次修复前的 bug。
4. **外部变更通知**：`_refreshAfterExternalChange()`（作废 TTL + 立即增量）
   经 `UploadPublishDialog.onPublished` 接到发布成功回调。
   🔴 回调顺序必须是**先 `onPublished` 再 `onClose`**，颠倒会丢刷新。

### 8.3 已知边界

- 一次增量最多覆盖 20 部新作；更多增量由既有全量加载 / 滚动加载补齐。
- `Offstage` 保活结构**故意不改成重建**：改成每次重建会丢滚动位置与大厅状态。
- 用户明确要求**不加任何「已更新 N 部」提示**，全程静默。
