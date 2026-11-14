# 功能档案：游戏运行任务状态横幅（v2.1.6 → v2.1.7 交互优化）

| 项 | 值 |
|----|-----|
| **状态** | 收起/展开交互优化已落地，待真机验证 |
| **优先级** | P1 |
| **创建日期** | 2026-09-05 |
| **最后更新** | 2026-09-05 |
| **关联决策** | 时长/BPM/位置决策见 §3；收起交互决策见 §3.1 |

---

## 1. 目标：解决什么问题

Chrono Tide 此前只能"后台默默"统计游戏时长：启动后用户在软件内**看不到**游戏正在运行、
跑了多久，也无法在软件内直接管控（停止统计 / 结束游戏）。对标 Lunabox 的可视化任务管理，
提供软件内常驻的运行任务横幅，把"监控中"这件事变成可见、可操作。

## 2. 用户可见行为

- 点击启动游戏 → 内容区顶部中央弹出磨砂半透明圆角横幅，状态「正在启动」（带 spinner）；
- 软件检测到游戏进程真正存活 → 状态切「运行中」，开始实时显示已运行时长（1s 刷新，墙钟口径）；
- **横幅在游戏完整运行周期内常驻**，不是启动瞬间的 toast；
- 右侧两个操作按钮：
  - **解除监控**（link_off）：放弃监控，游戏完全独立（时长统计随之停止）；
  - **关闭游戏**（power_settings_new）：直接终止游戏进程树；
- 游戏在游戏内手动退出 → 横幅短暂保留显示本次总时长，5 秒后平滑淡出消失；
- 启动失败 → 横幅保留并显示错误原因，由用户手动关闭；
- 多游戏同时运行 → 多条横幅自上而下堆叠，每条独立计时、独立管控；
- 冷启动纳管：应用崩溃重启后恢复的会话、或"游戏先启动、之后才打开软件"的会话，
  横幅也会接管（墙钟起点按已运行分钟数回推，分钟精度）；
- BPM 大屏模式不显示横幅（保持沉浸感）。
- **（v2.1.7 交互优化）收起 / 展开**：默认完整展示；展开态最后一条横幅下方有常驻
  「收起把手条」（chevron-up），点击收起整组横幅释放顶部空间。收起后由顶部居中
  「胶囊入口」（游戏手柄图标 + "N 款游戏运行中" + 可选未读红点）提供重新展开入口。
  收起/展开用 `AnimatedSize`（260ms）平滑过渡，高度变化不突兀跳动；任务全部清空时
  自动回到展开默认态。收起期间若发生重要状态变化（切运行中 / 游戏退出 / 启动失败），
  胶囊显示未读红点，展开即清除。

## 3. 设计思路：关键取舍

| 决策点 | 选择 | 原因（含被否决的方案） |
|--------|------|------------------------|
| 时长口径 | **墙钟** | 从进程确认存活起持续走，切后台不停。直观反映"这局开了多久"。被否决：统计口径（精准模式下切出数字会"卡住"，像 bug）；双口径副标题（信息全但横幅拥挤）。代价：精准计时模式下横幅数字 ≥ 统计页增量，属预期 |
| 位置/尺寸 | 内容区顶部居中、固定 420px | 克制不抢眼；Positioned 悬浮不挤压布局 |
| BPM | 不挂载 | BPM 是全屏沉浸 UI，有独立 shell |

### §3.1 收起/展开交互决策（v2.1.7）

| 决策点 | 选择 | 原因（含被否决方案） |
|--------|------|----------------------|
| 收起入口 | **展开态底部「把手条」**（`_CollapseHandle`，居中 64×18 细磨砂条 + chevron-up） | 常驻可见、与收起后胶囊形态连续、不遮挡内容。被否决：每条右上角收起按钮（按钮更多更繁）、仅 hover 显示（可发现性弱） |
| 收起形态（展开入口） | **居中胶囊 + 数量 + 未读红点**（`_CollapsedPill`：手柄图标 + "N 款游戏运行中" + 红点） | 信息充分、最易发现，状态变化一目了然。被否决：极简圆形小图标（看不到数量）、贴顶边把手（离视线中心远、可能与筛选栏重叠） |
| 平滑过渡 | `AnimatedSize`（260ms，alignment=topCenter）+ 内容即时切换 | 高度动画向下展开/收起，顶部锚定不跳动；避免 `AnimatedSize` 套 `AnimatedSwitcher` 在 Stack 布局下高度不随新 child 收缩的坑 |
| 未读红点数据源 | 服务侧 `bannerEventEpoch` 计数（v2.1.7 新增），横幅侧 `_lastSeenEpoch` 已读计数对比 | 不能直接监听 `notifyListeners`——1s tick 持续刷新会让红点永远亮；用独立 epoch 只在「重要变化」+1，语义清晰且可单测 |
| 红点触发范围 | 切 running / 切 exiting / 切 failed（含启动超时兜底） | 对应"进度更新 / 任务完成 / 出错"；新建 launching 不计数（数量已在胶囊可见，无需红点） |
| 空任务复位 | 任务清空时 `_collapsed` 复位为 false，且 `_lastSeenEpoch` 追平当前 epoch | 避免下次出现任务后误报红点；保持"默认展开"的产品预期 |
| 「运行中」判定 | **等注册表 `onGameSessionConfirmed` 回调，不在启动 return 点切换** | 与时长统计共用同一套进程存活检测 → 不出现"横幅说在运行、时长却没记"的口径分叉。这是本设计最关键的一条 |
| 横幅驱动 | 基于 `getActiveSessionsInfo()` 公开快照 + 新增回调，**不碰私有 `_GameSession` 内部逻辑** | 把对 2965 行高危文件 `local_game_registry.dart` 的侵入压到最低：全部纯新增，既有逻辑零改动（diff 仅 2 行删除且都是构造函数补字段） |
| 退出/失败语义 | exiting 保留 5s（`exitBannerDuration`）→ fading 320ms（`fadeOutDuration`）→ 移除；failed 常驻手动关闭 | 防错误信息一闪而过；淡出走 AnimatedOpacity/AnimatedSlide，与服务端 `fading` 标志配合避免"状态判定二次转换" |
| 解除监控写库 | `exit_reason='manual'` | 事实表能区分"用户主动放弃"与"自然退出" |

## 4. 实现位置

| 文件 | 职责 | 关键位置 |
|------|------|----------|
| `lib/services/running_tasks_service.dart` | 状态中枢（ChangeNotifier，单例 `instance`） | 四态机；1s tick（`debugTickInterval` 供测试）；`initialize()`:157 / `syncFromRegistry()`:170 / `beginTask()`:225 / `markFailed()`:244 / `detach()`:281 / `kill()`:305 / `dismiss()`:328；`launchTimeout`=60s:140；**`bannerEventEpoch` 计数 + `_bumpEvent()`（v2.1.7）在 4 处重要变化 +1** |
| `lib/widgets/running_tasks_banner.dart` | 堆叠容器 + 收起/展开 | 现为 `StatefulWidget`：`_collapsed` / `_lastSeenEpoch`；`_buildExpanded`（列 + `_CollapseHandle` 底部把手）/ `_buildCollapsedPill`（居中胶囊）；`AnimatedSize` 260ms 过渡；空列表 `SizedBox.shrink()` 零占位 |
| `lib/widgets/running_task_bar.dart` | 单条横幅 | 420px、blur sigma 18、圆角 14；缩略图 40px（无封面回退 `videogame_asset_outlined`）；按钮带单飞锁防连点 |
| `lib/services/local_game_registry.dart` | 注册表新增公开 API | `confirmed`:152 / `onGameSessionConfirmed`:1483（触发点:2281）/ `activeSessionDirs`:1489（测试覆盖:1492）/ `stopTracking`:2929 / `terminateGame`:2973 |
| `lib/services/game_launch_service.dart` | 启动接线 | `beginTask`:202（启动锁后、任何 await 前 → 防抖拦掉的重复双击不建横幅）；失败 `markFailed`:222/:234 |
| `lib/main_container.dart` | 桌面外壳挂载 | `:842` Stack 末尾 `Positioned(top:10, left:0, right:0, Center(RunningTasksBanner()))`；BPM shell 未挂载 |
| `lib/main.dart` | 初始化 | `:416` 在 `recoverPendingSessions()` **之后** `initialize()`（顺序决定冷启动纳管是否生效） |
| `test/services/running_tasks_service_test.dart` | 单测 16 用例 | 状态机流转 / 多任务独立计时 / 超时判失败 / 保留期与淡出回收 / 单飞锁 / 冷启动纳管 / **`bannerEventEpoch` 在 4 处重要变化的 +1 行为** |

## 5. 关键数据结构

```dart
enum RunningTaskStatus { launching, running, exiting, failed }

class RunningTask {
  final String metaDataDir;   // 与注册表会话、游戏库的关联键
  final LibraryGame game;
  RunningTaskStatus status;
  DateTime? runningSince;     // 墙钟起点（冷启动纳管时向前回推）
  DateTime? exitedAt;         // 进入 exiting 的时刻，驱动 5s 保留
  int finalSeconds;           // 退出后定格展示的本次总时长
  String? errorMessage;       // failed 态的错误文案
  bool fading;                // 淡出中：不再参与 _onTick 状态判定
  int elapsedSeconds(DateTime now); // 墙钟 = runningSince 起算
}
```

## 6. 历史决策与踩过的坑

- **横幅不能放非 Positioned 的 Stack child**：会被拉伸到全屏并拦截整屏点击
  （`main_container.dart:840` 附近注释记录过同类"白屏"教训）→ 必须用 `Positioned`
  + 组件内部空态返回零尺寸。
- **`beginTask` 必须放在启动锁获取之后**：`executeLaunch` 有防抖（启动锁），
  放在锁之前会让被拦掉的重复双击也创建横幅。
- **`initialize()` 必须在 `recoverPendingSessions()` 之后**：反过来调用会漏掉
  崩溃恢复出来的会话，冷启动纳管失效。
- **kill 后不要二次转换状态**：`_onTick` 里 exiting 由 `kill()`/自然退出各自收尾，
  `fading` 标志的任务直接跳过状态判定，避免定时器与用户操作竞争产生二次转换。

## 7. 当前进度

- [x] 状态中枢服务（四态机 + 计时 + 冷启动纳管）
- [x] 横幅 UI（磨砂容器 + 单条横幅 + 两操作按钮）
- [x] 注册表公开 API（onGameSessionConfirmed / stopTracking / terminateGame / activeSessionDirs）
- [x] 启动服务接线 + main_container 挂载 + main.dart 初始化
- [x] 单测 16 用例全过（v2.1.7 +5 覆盖 `bannerEventEpoch`）；analyze 0 error；全量 335 通过 / 13 存量失败（零新增）
- [x] **（v2.1.7）收起/展开交互优化**：底部把手条收起 + 居中胶囊展开入口 + `AnimatedSize` 平滑过渡 + 收起态未读红点（服务侧 epoch 计数驱动）
- [ ] **真机验证**（用户）：收起/展开动画顺滑、红点及时感知、不遮挡操作
- [ ] 真机通过后正式归档为「已上线」

## 8. 已知问题

| 问题 | 严重度 | 是否已定位 | 备注 |
|------|--------|-----------|------|
| 精准计时模式下横幅墙钟数字 > 统计页增量 | ⚪ 预期行为 | 是 | 口径差异，见 §3 决策；如用户反馈可加副标题 |
| Magpie 超分链路的进程树与普通游戏不同，`terminateGame` 可能漏杀 | 🟡 待真机确认 | 部分 | 已同时 kill bestPid + candidatePids + monitoredExes；真机用 Magpie 游戏验证 |
| 进程确认存在最长 ~2s 延迟（注册表 2s tick） | ⚪ 可接受 | 是 | launching 态有 spinner |

## 9. 待办

- [ ] 真机验证清单（§7）
- [ ] 视用户反馈决定：failed 横幅是否加"自动 30s 消失"选项

## 10. ⛔ 不要动的地方

- **`local_game_registry.dart` 的 `_checkActiveSessionsInternal` 时长累加/写入分支
  （约 :2247-2291）、`_writePlayTimeDirect`、前台检测**：横幅只读这些产物，禁止
  为了"让横幅数字与统计一致"反向改动统计逻辑——口径差异是设计决策不是 bug。
- **`game_launch_service.dart` 的 120s 安全阀与代际计数器**：与横幅无关，
  `beginTask` 位置依赖它（锁后），动它需重新推演防抖行为。
- **`main_container.dart` Stack 的既有 children 顺序**：横幅必须保持 Stack 末位
  （除 Overlay 弹窗外最上层），在它之后插入新 child 会改变层级语义。
