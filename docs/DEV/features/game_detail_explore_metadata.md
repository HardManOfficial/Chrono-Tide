# 游戏库详情窗口 · 探索页对齐元数据（评分/评分人数/开发日期/预计游玩时长）

> 状态：已实现（2026-10-04）　|　任务：扩展游戏库数据，使其接近探索页的数据覆盖范围
> 约束：所有新增数据**仅在详情窗口/详情页展示**，其他界面（卡片/列表/BPM）一律不展示。

## 1. 数据定义（game.json 新增 4 键，**不升 format_version**）

| 键 | 类型 | 语义 | 来源 |
|---|---|---|---|
| `release_date` | String | 发售日期 ISO YYYY-MM-DD（详情窗口标签为「开发日期」） | VNDB `released` |
| `rating` | double | 评分 0-10（<=0 视为无） | VNDB `rating`（归一化后） |
| `rating_count` | int | 评分人数（<=0 视为无） | VNDB `votecount` |
| `estimated_minutes` | int | 预计游玩时长（分钟，多用户平均） | VNDB `length_minutes` |

- 老文件无键 → 读取侧 `?? 默认值`（ADR-012 路线：纯新增字段不升版本）。
- 4 键已列入 `_overwritableFields`（抓取派生数据，与 developer/subtitle 同类，重复入库以本次为准）。
- `GameJsonData.toJson` 仅在**非默认值时输出**（避免老文件全库无意义改写）。

## 2. 抓取链路（VNDB → MIX → 探索页元数据）

1. SDK `VNDBService`：请求 fields 增加 `length_minutes, length_votes`；
   `Game` 模型新增 `lengthMinutes/lengthVotes`（fromJson/toJson/copyWith 同步）。
2. `MetadataFetcher._convertToLegacyFormat`：透传 `length_minutes/length_votes`；
   MIX 整合字段表追加这两键（自动复用 rating 优先级链，VNDB 唯一提供方）。
3. `DiscoverGameMetadata`：新增 `estimatedMinutes`（fromJson `estimated_minutes` /
   toJson / hasDisplayData / copyWith）；探索详情页元数据行新增
   「约 X 小时」chip（`Icons.schedule_rounded`，位置在热度之后、来源之前）。
4. ~~云端沉淀不含预计时长~~ ✅ **2026-10-04 已接通**：PB `games` 加
   `estimatedMinutes`(number) 字段，`GameModel`/`buildMetadataBody`/
   `updateGameMetadata`/`_reportToCloud` 全链透传（见
   `cloud_game_metadata_sync.md` §0）；线上后台建字段后即生效。

## 3. 入库写入点

| 通道 | 写入 | 说明 |
|---|---|---|
| 批量导入 `batch_import_controller.importSingleGame` | ✅ 4 字段透传 | `game.metadata` 即抓取结果 map |
| 智能导入 `auto_import_pipeline.importCandidate` | ✅ 4 字段透传 | `candidate.metadata` 即 MIX 结果 |
| 云端安装（extract_manager._writeGameInfo） | ⛔ 未接 | 链路无现成元数据，靠详情窗口懒回填兜底 |
| 手动导入 / 存量游戏 | ⛔ | 同上，懒回填兜底 |

## 4. 详情窗口懒回填（`game_detail_dialog._maybeBackfillExternalMetadata`）

- 触发：`_loadGameData` 成功后调用；四项**全空**才抓（任一有值即视为已有数据，
  局部缺失不重抓，避免每次打开都联网）。
- 抓取：`MetadataFetcher.fetchGame(title, preferredSource: vndb)` 单源（24h 磁盘缓存，
  重复打开零网络）；主标题无结果回退副标题。
- 落盘：`updateGameJson` 只写有效值（与云端回传 buildMetadataBody 同口径），
  成功后 setState 刷新 UI。失败静默，下次打开再试。

## 5. 详情窗口 UI（三处）

| 任务 | 位置 | 实现 |
|---|---|---|
| ① 开发日期 | 元数据板块，安装日期左侧同行 | `_buildDateRow`：有发售日 → 「开发日期 + 安装日期」双列（各 64px 标签）；无 → 原单行不变 |
| ② 星级 + ③ 评分人数 | 标题系统最末行，与副标题平行、紧随其右 | `_buildRatingBadge`：star(15, starGold) + 评分(13, w600) + people(15) + 人数(13, w500)；无副标题时该行保留，星级紧跟主标题下方；副标题超长 ellipsis，徽标恒可见 |
| ④ 预计游玩时长 | 游玩记录框首行，游玩时长左侧，短竖线（1×14）分隔 | 标签「预计时长」+ 值（`_formattedEstimatedTime`，14px w600 次级色）；无数据整组不占位 |

## 6. 验证与遗留

- ✅ 进程内 analyzer 探针：主工程 7 文件 `errors=0`（9 warning 全为 HEAD 存量、
  均在改动区外）；SDK 2 文件 `dart format --output=none` 通过，且 SDK 改动经
  主工程探针传递性类型检查（`game.lengthMinutes` 等引用全部解析）。
- 🔴 原生 `flutter analyze` / `flutter test` 当时不可用（231 管道耗尽 + C 盘 1.9G/99%），
  **未跑 flutter test**；环境恢复后建议补跑相关测试。
- ⚠️ 未真机走查：星级/日期/预计时长的实际观感与像素对齐（徽标与副标题的
  间距 10px、日期双列标签宽 64px 均为初始值，可能需按视觉反馈微调）。
- ⚠️ 「开发日期」标签按任务要求命名，数据实为**发售日**（VNDB 无"开发开始日期"概念）。
