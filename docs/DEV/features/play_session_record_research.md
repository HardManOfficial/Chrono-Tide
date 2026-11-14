# 游玩过程 / 游玩状态记录 —— 现状调研报告

> **日期**：2026-11-13  
> **阶段**：研究（只读审计）。**未修改任何既有代码或文档**，本文件为唯一新增产物。  
> **触发**：用户提出「系统把游戏当资产管理，缺少对游玩过程本身的记录」这一方向性疑虑。  
> **依据**：`SESSION_HANDOFF.md` / `STATUS_MAP.md` / `DECISIONS.md` / `DEV_LOG.md` 最近条目、  
> `.trae/documents/` 三份游玩时长方案、`docs/游玩统计折线表升级方案_v1.0.md`，以及对  
> `lib/` 下相关模块的全量只读代码核查。所有结论均带文件 + 行号。

---

## 0. 一句话结论

**现有的不是「游玩记录系统」，而是一台精密的计时器 + 一套资产管理器。**

工程投入几乎全部花在「怎么把秒数算准」上：Win32 FFI 前台检测、候选进程集、  
会话事实表、崩溃恢复、统计重建自愈、折线图与阅历日历。而玩家真正想留下的东西  
——某次玩了什么、当时什么感受、精彩截图、何时通关 / 弃坑、通关感想——在数据模型里  
**一个字段都没有**。

反差最大的一点：地基其实已经打好了。`sessions` 的设计哲学明确写着  
「**会话是不可变的事实，统计是会话的派生投影**」（`.trae/documents/game-playtime-architecture-upgrade.md:42,72`），  
它天生就是「每次游玩一条记录」的容器。只是这条事实表至今只装了  
`session_id / start_time / end_time / duration_seconds / tracking_mode / exit_reason`  
六个纯技术字段，没有为「人」留任何位置。

---

## 1. 现状全景：数据从哪来，到哪去

```
用户点「启动」
  └─ GameLaunchService.executeLaunch                    game_launch_service.dart:253
       ├─ 普通分支 → LocalGameRegistry.launchGame        local_game_registry.dart:2587
       ├─ Magpie 分支 → startPlayTimeTracking            game_launch_service.dart:410
       └─ 外注册 / 崩溃恢复 → _startPlayTimeTrackingInternal  :3107
            ↓
       _GameSession（内存，2s tick 主动确认进程 + 500ms 前台判定）
            ↓
       ┌──────────────── 三套并存的数据源 ────────────────┐
       │ ① game.json                                      │
       │   play_time（累计秒，每 2s 写）                    │
       │   sessions（会话事实表，最近 50 条）                │
       │   daily_play_log（按日 seconds/count，90 天清理）   │
       │   play_status / first_opened_at / last_opened_at   │
       │ ② sessions_archive.json（>100 条时归档，永久累积）   │
       │ ③ bpm_play_history.json（仅 BPM 启动，上限 200 条）  │
       └──────────────────────────────────────────────────┘
            ↓
       UI 出口（全部只读展示，无内容录入）
       统计浮层 / 阅历日历 / 详情弹窗「游玩记录」小框 /
       主页 chips / 库页状态徽章 / 大屏统计胶囊 / 托盘最近游玩
```

注意：③ 是 `bpm_play_history.dart:12-18,74-104` 独立维护的，**桌面启动不埋点**，  
大屏详情页的「启动次数 / 游玩历史」（`bpm_game_detail_page.dart:718-741`）读的是它，  
与桌面统计面板的「次数」不是同一个数。

---

## 2. 已有能力清单（客观盘点）

### 2.1 数据层：`game.json` 里与游玩有关的全部字段

| 字段                             | 类型 / 默认                | 语义                                                    | 定义位置                                              |
| ------------------------------ | ---------------------- | ----------------------------------------------------- | ------------------------------------------------- |
| `play_time`                    | int 秒 / `0`            | 累计总时长                                                 | `game_data_format.dart:485,1990,2063`             |
| `sessions`                     | List，缺键                | 会话事实表，保留最近 50 条                                       | `:1943,2100-2102`                                 |
| `daily_play_log`               | Map，缺键                 | `{'YYYY-MM-DD': {'seconds':n,'count':n}}`，90 天清理      | `:1944,2103-2105`                                 |
| `play_status`                  | String / `not_started` | 4 态：`not_started / in_progress / dropped / completed` | `:494,1997,2072`；枚举 `local_game_registry.dart:41` |
| `first_opened_at`              | String / `''`          | 首次启动，仅为空时写一次                                          | `:496`                                            |
| `last_opened_at`               | String / `''`          | 最近启动，每次刷新                                             | `:497`                                            |
| `mark`                         | String / `none`        | 星标徽标，**不是游玩状态**                                       | `:484`                                            |
| `completed`                    | bool / `false`         | **已废弃**通关标记，零写入方，读取方一律忽略                              | `:486,1823-1826`                                  |
| `screenshot_files`             | List / `[]`            | 元数据宣传图 / 自定义展示截图，**非过程截图**                            | `:498,1848-1852`                                  |
| `rating` / `estimated_minutes` | double / int           | VNDB 元数据评分与预计时长，**非用户评价、非实际时长**                       | `:243-247,513-518`                                |

`sessions[]` 单条结构（`game_data_format.dart:784-812`）：  
`session_id`(UUID) / `start_time` / `end_time` / `duration_seconds` /  
`tracking_mode`(`playtime` 仅前台 | `elapsed` 墙钟) /  
`exit_reason`(`normal|crash|manual|app_shutdown|recovered|aborted`)。

`format_version = 4`（`game_data_format.dart:52`）。以上游玩字段**从未进过任何迁移链**，  
全靠 `?? 默认值` 兜底读取（ADR-012 背景段 `DECISIONS.md:410-415` 明确记载这个历史包袱）。

### 2.2 业务层已具备的能力

- 精准计时：2s 进程确认 + 500ms 前台判定；FFI 失败才降级（`local_game_registry.dart:3219-3237,3663-3734`）。
- 两种口径可切换：精准（仅前台）/ 宽松（墙钟），设置页可改（`settings_modal.dart:1661-1761`）。
- 会话事实表 + 归档（>100 条归档到 `sessions_archive.json`，`game_data_format.dart:884-947`）。
- 崩溃恢复（仅 `lastOpenedAt` 2 小时内 + 目录有进程，`local_game_registry.dart:3996-4030`）。
- 统计自愈：设置里「重建所有游戏统计」从 sessions 全量重算（`settings_modal.dart:1762-1899`）。
- 游玩状态 4 态，启动自动 `not_started → in_progress`，其余靠手动。
- 单次会话累计 ≥15 分钟自动备份存档（`save_backup_service.dart:76,418-429`）。

### 2.3 UI 层已具备的能力

| 位置                | 能看到什么                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 主页右下统计浮层          | 折线图；7/30/90/全部；总计时长 + 次数；明细弹层（`play_stats_panel.dart:334-347,488-494,612-751`）                                                |
| 阅历日历              | 月历按日时长 4 档染色；点某天看「N 款 / 总时长 / 总次数」+ 逐游戏占比（`experience_calendar_picker.dart:444-609`）                                          |
| 详情弹窗              | 「游玩记录」小框：预计时长 / 游玩时长 / 首次·最后打开时间（`game_detail_dialog.dart:3309-3395`）                                                         |
| 状态设置              | 详情弹窗下拉、库页编辑模式批量菜单、大屏循环按钮（`game_detail_dialog.dart:3618-3720`、`library_page.dart:750-781`、`bpm_game_detail_page.dart:203-219`） |
| 主页 / 库页 / 大屏 / 托盘 | 时长 chips、状态徽章、最近游玩标题、统计胶囊                                                                                                     |

**不能做的**：手动改时长、补记一次游玩、删除错误会话、修改状态变更时间、  
按游戏筛选统计、导出统计、年度总结、日历点进去跳转游戏。

---

## 3. 六个关键诊断

### 诊断 1 · 历史方案全在解决「秒」，从没讨论「人」

三份核心方案的主题依次是：全流程精准计时架构升级（53 KB）、FFI 替换 PowerShell、  
折线表等比放大与阅历回溯。检索「笔记 / 感想 / 截图 / 评价 / 二期」等词，  
命中项全部是技术术语（候选集扩展、审计标记），**无一处涉及玩家内容**  
（`game-playtime-architecture-upgrade.md` 全文、`游玩时长统计系统重构方案.md:1-13`、  
`游玩统计折线表升级方案_v1.0.md:1-14`）。

这不是实现偷懒，是**产品定义从一开始就把「游玩记录」等同于「游玩统计」**。  
最有力的佐证：设置页有一个分组叫「**游玩记录**」，里面只有两张卡——  
「游玩时长统计模式」和「统计重建（自愈）」（`settings_modal.dart:959-962,1661,1781`）。

### 诊断 2 · 地基已有，缺的是「附着点」

`sessions` 是不可变会话事实表，带 UUID 与起止时间，天然支持：  
「这次玩了多久 → 这次发生了什么」。玩家的过程内容应该**挂在会话上**，  
而不是另起一套日记表。这样做还能白拿已有能力：归档、跨日分摊、  
阅历日历、统计重建、`onGameSessionEnded` 回调（后者是「玩完弹个感想」  
的现成触发点，且**不需要碰 `main.dart` 稳定区**）。

### 诊断 3 · 状态是「当前值」，不是「事件」

`setPlayStatus` 只写 `{'play_status': status}` 一个键  
（`game_data_format.dart:1167-1169`），文件级 `updated_at` 会被任何一次写入覆盖，  
`sessions` 里也没有状态快照。

后果：

- 「何时通关 / 何时弃坑」**不是 UI 没显示，是数据根本不存在**；
- 无法回溯状态历史（「去年弃坑、今年捡回来通关」这种故事存不下来）；
- 所有自动流转都是 `if (notStarted)`，所以 `completed` / `dropped` 之后再启动，  
  状态不回退、不提示，却照常累计时长与次数，状态与时间轴自相矛盾  
  （`local_game_registry.dart:3033-3038,3193-3199`、`game_launch_service.dart:418-423`）；
- 设「已通关」「已弃坑」时无任何附加输入：不填日期、不写感想、不记进度、无确认  
  （`game_detail_dialog.dart:1103-1123`）。这正是用户说的「冰凉凉地搁置一旁」。

### 诊断 4 · 三套数据源口径互相打架

| 分叉点                                                           | 证据                                                                      |
| ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| 短跨度（≤90 天）读 `daily_play_log`，长跨度 / 全部读 sessions 重聚合           | `play_stats_panel.dart:144,177-241`                                     |
| `daily_play_log.count` = 启动次数；sessions 重聚合 count = ≥60s 有效会话数 | `game_data_format.dart:740-774` vs `stats_aggregator.dart:225-237`      |
| <60s 会话：实时投影计入时长与次数，但重建 / 聚合直接丢弃                              | `game_data_format.dart:1028-1029`、`stats_aggregator.dart:225`           |
| 实时按「写入时刻」归日，sessions 重聚合才按跨日比例分摊                              | `local_game_registry.dart:3771-3779` vs `stats_aggregator.dart:419-470` |
| 90 天清理只裁 `daily_play_log`；自定义区间若落在 90 天前但跨度 ≤90 天 → 返回 0      | `local_game_registry.dart:3781-3786`、`play_stats_panel.dart:144`        |
| BPM 启动次数来自独立的 `bpm_play_history.json`，桌面启动不埋点                 | `bpm_play_history.dart:12-18,74-107`                                    |
| `ExperienceHistoryService` 缓存永不失效（invalidate 全库零调用）           | `experience_history_service.dart:216-226`                               |

也就是说：**同一个「玩了多久 / 玩了几次」，在不同页面可能给出不同数字**。  
在往时间轴上叠加用户内容之前，这层可信度问题必须先想清楚。

### 诊断 5 · 最接近「过程截图」的现成能力，语义完全不对

详情弹窗支持「添加截图」（`game_detail_dialog.dart:2815-2933`）：  
选本地图片 → 复制到 `<metaDataDir>/screenshots/custom_<时间戳>_<序号>.<ext>`  
→ 写进 `screenshot_files`。但：

- 上限 **6 张**，且与元数据宣传图**混在同一个列表**里；
- 无配文、无说明、无会话关联、无时间线属性，文件名里的时间戳不参与任何展示；
- 全项目把它当「游戏展示图」渲染（截图轮播、探索页、BPM）；
- 元数据全量刷新明确「不会动截图文件」（`metadata_refresh_card.dart:115`），  
  所以拿它当相册用会**污染游戏展示资料**。

结论：它是「自定义宣传图」，不是「游玩过程截图」。要支持后者，需要独立的存储与索引。

### 诊断 6 · 全库确认：用户生成内容零承载

对 `lib/` 全目录（含 `widgets/ / pages/ / big_picture/ / services/ / models/ /
packages/luna_metadata_sdk/`）检索  
`note|memo|diary|journal|review|感想|吐槽|笔记|日记|timeline|comment|用户评分|
过程截图|上传截图|通关感想|年度总结|补记|删除会话|修改时长` 等 40+ 关键词，  
逐条甄别后命中项全部属于：元数据只读评分、游戏宣传截图、社区资源发布的  
「资源备注」、账号个人简介、界面静态提示，以及  
`explore_hall/docs_section.dart:256` 的「用户动态 · 敬请期待（二期上线）」占位。

**没有任何一处允许玩家针对某次游玩写文字、传过程图、打分或留下感想。**  
`game.json` 字段全集（`game_data_format.dart:464-521`）也印证这一点。

---

## 4. 与诉求的差距表

| 用户诉求              | 现状                                                             | 缺口性质            |
| ----------------- | -------------------------------------------------------------- | --------------- |
| 曾经什么时候玩过、那次玩了多久   | `sessions` 有 start/end/duration，但**只在统计图表里以聚合数字出现**，没有逐次会话列表可看 | UI 缺失（数据已有）     |
| 何时通关 / 何时弃坑       | 只有 `play_status` 当前值，无时间戳、无历史                                  | **数据缺失**        |
| 管理 / 保存自己的游玩过程    | 无任何过程字段或文件                                                     | **数据 + UI 双缺失** |
| 游戏过程的精彩截图         | 只有 ≤6 张「展示截图」，混入元数据                                            | 语义错误，需独立载体      |
| 吐槽、通关感想           | 零承载                                                            | **数据 + UI 双缺失** |
| 通关 / 弃坑作为「里程碑」被纪念 | 只是 4 选 1 下拉，点完即结束，无引导无确认                                       | 交互 / 模型缺失       |
| 统计本身可信、可回看        | 三套口径分叉，部分场景返回 0，缓存不刷新                                          | 口径错误            |

---

## 5. 影响「记录可信度」的技术缺陷（择要，按优先级）

| #  | 问题                                                                                          | 证据                                                                                                      |
| -- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| P0 | `play_time`/`daily_play_log` 与 `sessions` 是两次独立原子写，崩溃落在中间即漂移                                | `local_game_registry.dart:3747-3810` vs `game_data_format.dart:813-842`                                 |
| P0 | 归档 `_archiveSessionsIfNeeded` 不走写队列，与原子更新并发有覆盖竞态；归档文件读失败会置空重建并覆盖历史                          | `game_data_format.dart:884-947`                                                                         |
| P0 | `recoverPendingSessions` 会重复 `+1` 次数、把 `last_opened_at` 改写成恢复时刻、新会话 `startTime` 取 now 而非崩溃前 | `local_game_registry.dart:3996-4030,3115,3212`                                                          |
| P1 | 阅历缓存 `invalidateCache` / `invalidateForGame` 全库零调用，新会话不反映到日历（除非重启）                          | `experience_history_service.dart:216-226`                                                               |
| P1 | 进程检测失败结束会话时**不写 sessions**，且放弃全部 pending 时长                                                 | `local_game_registry.dart:3344-3364`                                                                    |
| P1 | `disposeAllSessions` 补 pending 时未 await 写盘就无条件累加并写会话                                        | `local_game_registry.dart:3934-3958`                                                                    |
| P1 | 自然退出不补最后一段（对比 stopTracking 会补 ≤4s）                                                          | `local_game_registry.dart:3480,3498` vs `:4057-4062`                                                    |
| P2 | `all` 区间起点依赖 `firstOpenedAt`，缺失即退化为仅今天；`gameCount` 实为「有数据的天数」                               | `stats_aggregator.dart:202-205,305-308`                                                                 |
| P2 | 30/90/全部视图不随新游玩实时刷新（仅 last7 实时）                                                             | `play_stats_panel.dart:80-88,111`                                                                       |
| P2 | Magpie 有两条独立启动实现 + 一条独立诊断监控，口径互不相干                                                          | `game_launch_service.dart:399-436`、`local_game_registry.dart:2643-2722`、`magpie_service.dart:1120-1163` |
| P2 | 全程本地时间且 ISO8601 不带时区偏移，跨时区 / 时钟回拨会使 start/end 倒挂                                            | `local_game_registry.dart:200-201,3771-3773`                                                            |
| P2 | 遗留 `completed` bool 字段读写并存但被忽略，易与 `play_status='completed'` 混淆                              | `game_data_format.dart:486,1823-1826`                                                                   |

---

## 6. 方向建议（候选，需用户拍板；本阶段不实施）

### 方向 A · 「游玩手记」——把内容挂到会话上

以 `sessions` 事实表为锚，给每次会话附加可编辑的**文字 + 过程截图 + 可选标签**，  
提供按游戏的时间轴视图。复用已有 UUID、起止时间、归档与跨日分摊；  
`onGameSessionEnded` 可作为「这次玩完了，要不要写两句」的轻量触发点。

- 优点：最贴合既有架构哲学，不动启动链路，不碰稳定区。
- 需要决策：内容挂在**会话**还是**自由日记**（前者自动带时间，后者更随意）；  
  截图落盘目录（须遵守 `PathHelper` / `GameDirs` 约定）；是否允许补记 / 删除 / 修改。

### 方向 B · 「状态事件化」——让通关与弃坑成为里程碑

把 `play_status` 从标量升级为带时间戳的事件流（`status_history`），  
在设为 `completed` / `dropped` 时可选填日期、感想、进度；  
顺带解决「状态不回退」「状态与时长矛盾」「何时通关不可查」。

- 优点：直接回答用户最具体的那句「何时通关、弃坑」。
- 需要决策：旧状态如何迁移；是否保留标量做兼容；通关感想是独立实体还是状态事件的附注。

### 方向 C · 「统计体验升级」——把已有的做对

统一三套数据源、修 90 天缺口与缓存失效、日历可跳转游戏、  
按游戏筛选、导出 / 年度总结。属于「展示层」补课，不产生新的用户内容。

### 方向 D · 「数据可信度收口」——先修地基

按第 5 节 P0/P1 逐项收口，让时间轴本身可信。  
原因是：**一旦允许玩家往某次会话写回忆，那条会话的时间错了就比没有更糟**。

### 建议的组合顺序（待确认）

> **先定产品形态（A + B 合并为「游玩手记 + 里程碑」），再在落地范围内顺带修 D 中  
> 影响该形态的几项；C 放到最后单独排期。**

不建议一上来做「统计系统全量重构」——那会重演项目最忌讳的「修 A 顺手重构 BCD」，  
也会把这次诉求重新拖回「怎么把秒算准」的老路上。

---

## 7. 既有约束与地雷（动手前必须记住）


- `format_version = 4`。ADR-012（`DECISIONS.md:405-446`）纪律要求新增字段  
  「加迁移 + 升版本 + 补回归测试」，但近期惯例是「纯新增可空字段、不升版本」  
  （ADR-017/018 显式例外，`DECISIONS.md:686`）。走哪条**需要用户拍板**。
- 稳定区：`main.dart` / `main_container.dart` / `theme/` / `app_state.dart` /  
  `portable_*.dart` / `windows/runner/` / `luna_metadata_sdk/` 改动需显式批准。  
  因此**不能加启动钩子**，优先用已有 `onGameSessionEnded` 回调。
- 写盘唯一出口仍是 `GameDataFormat.updateGameJsonAtomic`（写队列 + 原子写 + 主键护栏），  
  不另开写盘口子（ADR-023 影响段 `DECISIONS.md:1003-1004`）。
- `_overwritableFields` 覆盖黑名单：`play_time / sessions / daily_play_log /
  first_opened_at / last_opened_at / play_status` 刻意不在名单内  
  （`game_data_format.dart:251-255`）。新增字段要同步评估，否则重复入库会丢数据。
- 云同步：ADR-023 明确「**本项目没有云端状态模型**，刻意不做收藏/游玩状态同步」  
  （`DECISIONS.md:1006`）。若要跨设备保存游玩记录，是独立架构决策。
- 归档 / 解封：`GameArchiveService` 会把整个 `metaDataDir`（含 `game.json`、  
  `sessions_archive.json`）打进 `appdata.7z`，并在还原时保留本地 `game.json`  
  （`game_archive_service.dart:380-405,880-912`）。**新增的截图 / 手记文件必须一并纳入归档，  
  否则封存再解封会丢内容**。
- 验证环境：231 未解除，全量 `flutter analyze` / `flutter test` 跑不了；  
  UI 需靠 `.workbuddy/analyze_probe` 与 flutter_tester 探针，真机构建须用户自己跑。
- 工作区常年有 300+ 未提交文件（他人功能），提交前必须按具体文件核对归属。

---

## 8. 下一步需要用户拍板的问题

1. **记录粒度**：按「每次游玩会话」自动成条，还是「自由日记 / 时间轴」随时写？  
   或是两者都要？
2. **内容形态**：纯文字吐槽 → 文字 + 过程截图 → 再加评分 / 进度 / 心情标签，做到哪一档？
3. **状态是否事件化**：通关 / 弃坑要不要记日期与感想？还是只补一个时间戳就够？
4. **优先级**：先让玩家「能留下东西」（A/B），还是先修统计口径（D）？
5. **云同步**：游玩记录是否要求跨设备 / 账号同步？（会推翻 ADR-023 的前提）
6. 是否需要把「自定义展示截图」与「过程截图」在 UI 上彻底分开？

---

## 9. 关键文件索引

| 层                         | 文件                                                                                                   |
| ------------------------- | ---------------------------------------------------------------------------------------------------- |
| 数据格式 / 会话事实表              | `lib/services/game_data_format.dart`                                                                 |
| 注册表 / 计时与会话生命周期           | `lib/services/local_game_registry.dart`                                                              |
| 启动总入口                     | `lib/services/game_launch_service.dart`                                                              |
| 诊断日志（无读取方）                | `lib/services/game_launch_logger.dart`                                                               |
| 聚合算法                      | `lib/services/stats_aggregator.dart`                                                                 |
| 阅历摘要（纯内存）                 | `lib/services/experience_history_service.dart`                                                       |
| 统计浮层 / 阅历日历               | `lib/widgets/play_stats_panel.dart`、`experience_calendar_picker.dart`                                |
| 详情弹窗游玩记录小框 / 状态下拉 / 自定义截图 | `lib/widgets/game_detail_dialog.dart`                                                                |
| 设置「游玩记录」分组                | `lib/widgets/settings_modal.dart`                                                                    |
| BPM 独立游玩历史                | `lib/big_picture/services/bpm_play_history.dart`                                                     |
| 历史方案                      | `.trae/documents/game-playtime-architecture-upgrade.md`、`游玩时长统计系统重构方案.md`、`docs/游玩统计折线表升级方案_v1.0.md` |
| 架构决策                      | `docs/DEV/DECISIONS.md`（ADR-011 / 012 / 023）                                                         |
