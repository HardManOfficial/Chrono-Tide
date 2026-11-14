# BPM 背景 OP 视频「自动抓取」（BPM-OP-AUTOFETCH）

> 状态：**已上线（默认关闭）**，2026-10-17。
> 用户拍板：*"做吧，默认关闭。现在开始动手，一次完成收尾。"*
> **同日修订**：*"PV 其实也可以算的……只要是有相关游戏内容的视频，我们都是可以作为
> 这个背景使用。没有 OP 就用 PV。"* —— 名称闸从「硬排除」改成「分级选片」（见 §4.5）。
> 研究底稿：`bpm_op_video_autofetch_research.md`（Phase 0，含全部实测数据）。
> 决策条款：`DECISIONS.md` **ADR-018**。

---

## 1. 这个功能补的是什么缺口

ADR-015 之后，BPM 背景已经支持「每游戏自选 MP4 背景视频」并有一条完整播放链路
（`BpmBackdropMedia` 存池 → `BpmBackdropMediaController` 状态机 → `BpmOpVideoLayer` 渲染）。
**唯一的缺口是素材**：视频只能由用户手动放进 `metaDataDir`，没有任何自动获取。

本功能补的就是这一处 —— 不新建播放链路，只给已有链路**増加一个素材来源**。

## 2. 产品语义（用户拍板的边界）

| 问题 | 结论 |
|---|---|
| 默认开还是关 | **默认关闭**（每个 30–45MB，且「替用户下载完整 OP」需用户知情） |
| 触发时机 | 大屏模式里**真正选中过**的游戏（`_onStageGameChanged`），懒触发 |
| 已有视频的游戏 | **跳过**（不管视频是用户放的还是以前抓的） |
| 素材范围 | **不局限于 OP**：OP > ED > PV > 其它相关条目，分级取最靠前的一条（§4.5） |
| **确认方式（v3.22.1）** | 探到素材**先弹窗问用户**拉不拉，确认才下载（§4.6）；静默后台抓被用户否决 |
| 抓到后要不要自动选中 | **池里没有选中视频时接管**，否则不动（见 §5.1） |
| 桌面主页 | 不接入（OP 背景是 BPM 专属） |
| 手动入口 | 无（与标题图同款：全自动） |

## 3. 链路

```
BPM 换游戏（big_picture_shell._onStageGameChanged）
  → GameOpVideoService.requestAutoFetch()          [开关关 / 熔断 / 池非空 / 本会话已问过 → 立即返回]
  → GameTitleLogoService.resolveSteamAppIds()      [复用标题图的锚点纪律]
  → OpVideoCore.probe(appIds)                      [只查列表，不下载]
  │    ├─ 逐 appid 查 movies；发现 OP 即早停（PV 不挡路）
  │    └─ 候选按 OP > ED > PV > 其它 排序
  ├─ 无候选（noMovie / noUsableMovie / networkError）→ 记负缓存，**静默返回，不弹窗**
  ├─ 有候选 → shell._onOpVideoCandidates → BpmOpVideoAskDialog 弹窗   [v3.22.1]
  │    ├─ 用户点「拉取」→ confirmFetch → downloadMovie（3 并发 / 拼接 / 校验）
  │    │     → BpmBackdropMedia.addVideos(autoSelect: false) → controller.refresh()
  │    └─ 用户点「不拉取」/ 关窗 → decline（userDeclined 负缓存 7 天）
```

## 4. 为什么不需要 ffmpeg / 为什么 Media Foundation 能播

- Steam 的 HLS 分片是 **fMP4（CMAF）**：init 段 = `ftyp` + `moov(mvex)`，
  每片 = `styp` + `sidx` + `moof` + `mdat`。**按顺序字节拼接即为合法的分片式 MP4**。
  实测 AOKANA OP1：50 片 / 44.50MB / box 链 46,664,013 字节精确解析到末尾。
- `video_player_win` 走 `IMFMediaEngine::SetSource`，**不支持 HLS**（因此必须下载拼接），
  但 **MF 从 Windows 8 起原生支持 `moof` 分片**，所以拼接产物可以直接播。
- 现有 `BpmBackdropMedia.looksLikeMp4()` 检查第 4..8 字节 == `ftyp`，而 fMP4 的 init 段
  正是 `ftyp` 开头 ⇒ **校验不会误杀拼接产物，无需改动**。

### 4.5 分级选片（2026-10-17 修订，取代原「名称闸」）

**用户原话**：*"PV 其实也可以算的……这个视频素材不局限于 OP，它有 OP ED PV 或者是
其他相关视频，只要是可以介绍有相关游戏内容的视频，我们都是可以作为这个背景使用。
没有 OP 就用 PV。"*

实现（`OpVideoCore.classify` + `pickMovie`）：

| 分级 | 判定 | 例子 |
|---|---|---|
| ① OP | 归一化后含 `opening` / `オープニング` / `片头` / `主题歌`，**或含 `op`** | `OP1-CN` `ENOP` `STEAMOP1` |
| ② ED | 含 `ending` / `エンディング` / `片尾`，或**词边界**命中 `ed` / `end` | `ED1` `END1` `TRUE END` |
| ③ PV | 含 `pv` / `trailer` / `teaser` / `promo` / `preview` / `预告` 等，或词边界命中 `cm` | `Official PV` `Announcement Trailer` |
| ④ 其它 | 没标注类型但确实挂在本作商店页 | `Movie 1` `Gameplay` |

- 同级多条取**商店页顺序第一条**；跨级**永远选 rank 最小的**（没有 OP 就用 ED）。
- 🔴 `ED` / `CM` 两字母缩写**必须词边界判定**（原始串正则），归一化串直接
  `contains` 会把 `edited` / `commercial` 全误伤；`OP` 保留包含即命中（真实命名
  粘连太多：`ENOP` / `STEAMOP1`）。
- 🔴 为什么可以放开 PV：条目**全部挂在本作自己的商店页**，是厂商发布的本作视频；
  「贴错」只剩 appid 锚错作品一种可能，由标题图的锚点纪律兜住。
- 仍然跳过无 `hls_h264` 源的条目；全部无源 → `noUsableMovie`。
- 一次仍只抓**一条**（最靠前的），不做 45MB × N 的全量收集。

### 4.6 弹窗确认流程（v3.22.1，用户拍板）

**用户原话**：*"我明明开了自动抓取，但是没有任何的反应……如果识别到了该游戏有视频
素材，那弹一个窗口，提示用户该游戏可以抓取的视频数，然后让用户选择是否拉取。
如果说没有抓到素材，那么什么都不用干，也不需要给什么提示。"*

- **为什么**：首轮的静默后台抓取让用户完全无法感知功能是否生效（他遇到的正是
  「探不到素材被静默吞掉」，但没法区分是没素材、网不通还是功能坏了）。
- **引擎**：`fetch()`（探测+下载一条龙）拆成 `probe()`（只查列表）+ `downloadMovie()`
  （下载单条）；服务层走 `probe → onCandidates 回调 → 用户确认 → downloadMovie`。
- **弹窗**（`bpm_op_video_ask_dialog.dart`）：列候选条目（名称 + 类型），说明
  「将拉取最优先的一条（约 30–45MB，720p，仅存本机）」；「拉取」按钮 autofocus，
  手柄 A/Enter 确认、B/Esc 关窗。
- 🔴 **弹窗前必须校验仍是当前舞台游戏**：探测要几秒，用户可能已翻页，弹错对象就是干扰。
- 🔴 **拒绝也记负缓存**（`userDeclined`，**7 天**）：比素材类（30 天）短，给用户反悔窗口；
  同一游戏本次启动只弹一次（会话内 `_askedThisSession`）。
- 🔴 **无候选 / 网络失败一律静默**——这是用户明确要求的，不要画蛇添足加失败提示。
- 「拉取失败」走 `activity` 状态行（设置页可见），也不弹窗。
- `fetch()` 保留给探针做端到端验证（等价于 probe + 自动下最优先一条）。

## 5. 关键约束（改动这块必读）

### 5.1 🔴 不抢用户选中 —— 但也不是「永不选中」

`addVideos()` 老语义是「无条件把最后一个设为当前视频」（手动上传后要立刻看到效果）。
自动抓取传 `autoSelect: false`，其语义是**「只在当前没有选中视频时才接管」**：

- 用户已经挑过视频 → 抓来的视频只进池，不动选中位；
- 用户什么都没选（最常见）→ 抓来的视频接管，否则功能对用户不可见。

### 5.2 🔴 串行队列 + 会话上限 + 网络熔断

| 机制 | 值 | 为什么 |
|---|---|---|
| 串行队列 | 一次只抓一条 | 快速翻页时不会并发打满 Steam CDN |
| 会话上限 | `maxPerSession = 5` | 浏览上百个游戏不至于下 3–4GB |
| 网络熔断 | 连续 2 次 `networkError` → 本次启动停止 | `store.steampowered.com` 在国内网络会时好时坏，不熔断的话每换一个游戏都白等 12 秒连接超时 |
| 幂等 | 池非空 / 产物已存在 → 跳过 | 45MB 不重复下 |

### 5.3 负缓存 TTL 必须按状态区分

`data/op_video_attempts.json` 记 `{gameId: {t, s}}`：

| 状态 | 冷却 | 理由 |
|---|---|---|
| `downloadFailed` / `networkError` | **1 天** | 网络抖动，明天可能就好了 |
| `userDeclined` | **7 天** | 用户亲口拒绝过，别烦他；比素材类短留反悔窗口 |
| `noAnchor` / `noMovie` / `noUsableMovie`（含旧名 `noOpening`） | **30 天** | 库里有没有这条作品几乎不会变 |

⇒ 引擎里 `_listMovies` 返回 `null`（请求失败）与 `[]`（确实没有影片）**必须分开**，
合并会把「今天网断了」记成「这游戏一个月内别再试」。

### 5.4 版权红线（比标题图更硬）

完整 OP 动画比一张 logo 敏感得多：产物**只落本机游戏元数据目录**，
不进云端、不上传 PB、不参与任何分发。与 ADR-017 同一条红线。

### 5.5 🔴 必须显式 `exit()` 的探针

`HttpClient` 的挂起连接会让 Dart VM 事件循环一直有事做，`main` 返回后进程不退，
输出卡在管道里 —— 第一次跑真机探针就"假死"了 5 分钟。探针末尾必须 `exit(...)`。

## 6. 为什么是「纯 Dart 引擎 + 宿主接线」两文件

与 `openlist_update_core.dart` 同因：本机 `CreateFile failed 231`，
`flutter test` 不可用；且 flutter_tester 里 `Directory.create(recursive:true)` /
`Future.delayed` 会**永久挂起**。抓取逻辑全是「真 HTTP + 真异步 IO + 大文件落盘」，
只有抽成零 Flutter 依赖的纯 Dart 才能用 `dart.exe` 直跑端到端探针。

| 文件 | 职责 |
|---|---|
| `lib/services/game_op_video_core.dart` | 纯 Dart 引擎（零 Flutter）：appdetails / 名称闸 / m3u8 / 下载 / 拼接 / 校验 |
| `lib/services/game_op_video_service.dart` | 宿主接线：开关判据、appid 解析、串行队列、会话上限、熔断、负缓存、写池、清理 |

`OpVideoCore` 有 `storeApiBase` 注入点（默认生产地址），探针指向本地 fixture server
—— 这就是「Steam 不可达时也能端到端验证」的关键。

## 7. 验证

### 已完成

- **进程内 analyzer**：改动 6 文件 **errors = 0**（存量 warning 与本次无关）。
- **纯 Dart 端到端探针** `.workbuddy/probe_op_video/probe_op_video.dart`
  （`dart.exe` 直跑，本地 fixture server 模拟 Steam）：**15/15 全绿**。
  覆盖：分级 4 类正例（OP 13 名 / ED 7 名 / PV 8 名 / 其它）+ 误伤反例
  （`Edited` / `Animated Menu`）+ 5 组优先级选片；遍历 appid（无影片→全无源→才有 OP）；
  **probe 跨 appid**（首个锚点只有 PV 时不早停，继续找到 OP，候选 OP 排最前）；
  **选档必须落在 720p**（1080 档只给 3 片，选错立刻断言失败）；
  **3 并发下载后分片顺序仍为 0001…0012**（fixture 故意让先发的分片后到）；
  box 链 `{ftyp:1, moov:1, moof:12, mdat:12}` 精确到文件末尾；`.part` 无残留；
  幂等（不再请求任何 m3u8/分片）；只有 PV → 照抓（kind=pv）；无 OP 有 ED → 选 ED；
  全无源 → `noUsableMovie`；无影片 → `noMovie`；空锚点 → `noAnchor`；
  API 不可达 → `networkError`（与 `noMovie` 区分）；体积超限 → 放弃且不留半成品。

### 未完成（必须补）

1. **真实 Steam 端到端**：本机 `store.steampowered.com` 实测 **000 / 12s 连接超时**
   （研究阶段曾 200 可用 —— 该域名在国内网络时好时坏）。有网时跑：
   `dart.exe ... probe_op_video.dart --real --appid=1044620 [--proxy=127.0.0.1:7890]`
2. **MF 真机播放**：文档层面成立（Win8+ 支持 moof），实际解码仍需一次真机走查。
3. **`flutter test` / `build`**：本机 231 未恢复，全程未编译。

## 8. 文档/代码索引

| 位置 | 内容 |
|---|---|
| `lib/services/game_op_video_core.dart` | 引擎（含分级选片、选档、拼接的全部判据注释） |
| `lib/services/game_op_video_service.dart` | 宿主接线（开关/队列/熔断/负缓存/清理） |
| `lib/widgets/settings/op_video_autofetch_card.dart` | 设置页三件套：开关 / 实时状态 / 已抓取统计+清理 |
| `lib/big_picture/widgets/bpm_op_video_ask_dialog.dart` | 「发现可拉取的背景视频」确认弹窗（v3.22.1） |
| `lib/services/bpm_op_video_preference.dart` | `autoFetchEnabled`（默认 `false`） |
| `lib/big_picture/services/bpm_backdrop_media.dart` | `addVideos({autoSelect})` |
| `lib/big_picture/big_picture_shell.dart` | 触发点 `_onStageGameChanged` + `_onOpVideoStored` |

## 9. 明确不做

- ❌ 1080p（体积翻倍，背景板看不出差别）
- ❌ 流式播放（MF 不支持 HLS）
- ❌ YouTube 源（需 yt-dlp + cookies，与打包瘦身冲突）
- ❌ 全库预抓（只抓用户实际浏览到的游戏）
- ❌ 上传/镜像到 PB（版权红线）
