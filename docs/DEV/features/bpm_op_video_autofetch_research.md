# BPM 背景 OP 视频「自动抓取」可行性研究（Phase 0 底稿）

> 状态：**研究完成，未写任何业务代码**（2026-10-17）。
> 结论：**技术上可行，链路已实测跑通**；但有三个代价需要用户拍板，见 §6。
> 关键词：OP 视频、背景视频、Playnite 同款、Steam movies、HLS、fMP4、Extra Metadata Loader

---

## 1. Playnite 那边到底怎么做的

不是 Playnite 核心功能，而是社区扩展 **Extra Metadata Loader**（darklinkpower）：

| 能力 | 实现 |
|---|---|
| 视频来源 | **Steam**（trailer / micro-trailer）+ **YouTube**（需 yt-dlp + cookies，处理限龄） |
| 播放方式 | 支持 **Steam 流式播放**（不下载），也支持下载到本地 |
| 依赖 | 需要主题支持（`VideoPlayerControl`），且依赖系统 Windows Media Player |
| 元素 | 视频、logo 都归它管 |

关键点：**Playnite 是"按需/手动触发批量下载"或"直接流式播放"**，不是静默全自动。

## 2. 我们已经有什么（这决定了缺口只有一处）

ADR-015 已完成（2026-09-27）：BPM 背景支持**每游戏自选 MP4 背景视频**。

| 层 | 现状 |
|---|---|
| 字段 | `bpm_backdrop_videos`（`[{file,name}]` 池）+ `bpm_backdrop_selected_video` |
| 播放 | `video_player_win`（Media Foundation）→ `bpm_op_video_layer` |
| 校验 | `looksLikeMp4()` 要求第 4..8 字节为 `ftyp`；扩展名 `mp4/m4v`；单文件 ≤ 500MB |
| 触发 | 选中游戏后停留 3 秒 → 封面淡出 → 视频在 UI 背后播一次 → 淡出 |
| 缺口 | **视频只能由用户手动放入**，没有任何自动获取 |

所以这不是"从零做功能"，而是"**给已有播放链路补一个素材来源**"。

## 3. 数据源实测（决定性数据）

### 3.1 NextMoe 的 `intros` 不是视频

先排除了一个诱人的误判：NextMoe `include=intros` 返回的是**剧情简介文本**
（`{lang, value, source}`），不是 OP 视频。**这条源不存在，别再试。**

### 3.2 Steam 商店 API 可以，而且给的是真 OP

```
NextMoe 搜索 → refs/sources 的 steam:<appid>
→ https://store.steampowered.com/api/appdetails?appids=<appid>&filters=movies
```

⚠️ `store.steampowered.com` 在 2026-10-17 之前的实测里**不可达（000）**，本次复测 **200 可用**。
网络环境会变，这是运行时必须容错的前提（失败就走负缓存，不影响其它功能）。

AOKANA（appid 1044620）返回 3 个影片，名字是：

```
OP1-CN / GROUNDOP-CN / OP2-CN
```

**这是游戏 OP 动画本体，不是宣传 PV** —— 厂商上传后 Steam 直接存了。

### 3.3 覆盖率：20 个 galgame 抽样

| 游戏 | 影片名 | 是 OP？ |
|---|---|---|
| AOKANA | `OP1-CN`, `OP2-CN` | ✅ |
| Clover Day's | `ENOP` | ✅ |
| 千恋万花 | `OPEN` | ✅ |
| リトルバスターズ | `English Opening Video` | ✅ |
| G-senjou no Maou | `OP` | ✅ |
| ぬきたし | `NUKITASHI OP1` | ✅ |
| Riddle Joker | `Opening Movie` | ✅ |
| Dies irae | `Diesirae_OP` + 4 个 PV | ✅ |
| Steins;Gate | `STEINSGATEOP1/OP2` + PV | ✅ |
| Muv-Luv | `Official PV` | ❌ 只有 PV |
| Fate/stay night | `Launch PV English ver` | ❌ 只有 PV |
| ATRI / CLANNAD / 千恋万花之外多数 / Summer Pockets / サクラノ詩 / 9-nine- / 灰色系列 / Making\*Lovers / WHITE ALBUM2 / ISLAND | 无 Steam 条目或无影片 | ❌ |

**结论：真 OP 约 9/20（45%）**，另有约 10 个只有 PV 或完全没有。
低于标题图的 70% —— 因为很多 galgame 在 Steam 上根本没有页面，或只有 PV。

### 3.4 格式：只有 HLS/DASH，没有 mp4 直链

`appdetails` 返回的字段只有：

```
dash_av1 / dash_h264 / hls_h264 / thumbnail / name / id / highlight
```

**没有 `movie480.mp4` 这类单文件直链**（老接口曾有，现已不给）。
HLS 分片是 **fMP4（CMAF）**：

```
#EXT-X-MAP:URI="dash_h264/init-stream0.m4s"
dash_h264/chunk-stream0-00001.m4s   (每片 3 秒, 约 800KB)
```

档位：1080p 5.8Mbps / **720p 2.6Mbps** / 480p 1.4Mbps / 360p 1.0Mbps。

### 3.5 单个 OP 的真实体积（实测下载拼接）

AOKANA OP1，720p 档：

| 指标 | 实测值 |
|---|---|
| 时长 | **148 秒** |
| 分片 | 50 个 |
| 体积 | **44.50 MB** |
| box 结构 | `ftyp, moov(mvhd/trak/mvex/udta), [styp, sidx, moof, mdat] × 50` |
| box 链完整性 | 46,664,013 字节**精确解析到文件末尾**，50 moof / 50 mdat |

其它样本（按 m3u8 估算 720p）：97–148 秒，30–35 MB。
1080p 同片约 107MB —— **不选 1080p**，720p 已经够当背景板。

**关键好消息**：拼接**不需要 ffmpeg**。init + chunks 顺序字节拼接即可，
纯 Dart 能做（与 `openlist_update_core.dart` 同款"纯 Dart 引擎 + 宿主接线"结构）。

## 4. 播放端的硬约束（这条决定了架构）

查了 `video_player_win 3.3.0` 原生源码（`my_grabber_player.cpp:209-243`）：

```
OpenURL() → IMFMediaEngine::SetSource(url)
          （带 headers 时用自定义 MyHttpByteStream，仍是整文件渐进下载）
```

**Media Foundation 不支持 HLS/DASH**（只支持渐进式 HTTP 下载与 Smooth Streaming）。
⇒ **不能直接喂 m3u8**，必须 下载 → 拼接 → 本地文件。

**但 fMP4 本身是支持的**：微软文档明确 *"Movie fragments ('moof') is supported in
Windows 8 MPEG-4 source and sink"*（Windows 8 起，Win10/11 的 WMP / IE / Edge 均可播）。
我们的产物体积与结构完全符合该形态。

⚠️ 另一半约束：现有 `looksLikeMp4()` 检查第 4..8 字节 == `ftyp`，
而 fMP4 的 init 段正是 `ftyp` 开头 ⇒ **现有校验不会误杀拼接产物**，无需改动。

## 5. 推荐方案骨架（若决定做）

```
懒触发：切到某游戏 → 池里已有"自动"视频则跳过
  → NextMoe 锚点（复用 title-logo 的 refs/sources 解析）
  → appdetails?filters=movies
  → 只收名字含 OP / OPENING / 片头 的条目（PV/预告片不要）
  → 选 720p 档 m3u8 → init + chunks 串行/小并发下载 → 拼接
  → 落盘 metaDataDir/op_video_<movieId>.mp4
  → 写入 bpm_backdrop_videos（**不抢 selected**，用户已有选择不被覆盖）
```

必须遵守的四条：

1. **纯 Dart 引擎**（`game_op_video_core.dart` + 宿主接线）—— 与
   `openlist_update_core.dart` 同理：需要真 HTTP / 真异步 IO 的逻辑，
   在 flutter_tester 下会挂，只有纯 Dart 才能用 `dart.exe` 探针验证。
2. **后台队列 + 并发上限**（建议 3 分片并发），绝不阻塞 UI；进度只进日志/设置页。
3. **不抢选中**：`BpmBackdropMedia.addVideos()` 现有语义是"自动把最后一个设为当前"，
   自动抓取**必须新增 `select: false` 路径**，否则会覆盖用户挑的视频。
4. **版权红线**：完整 OP 动画比 logo 敏感得多 —— **只可客户端本地缓存自用**，
   绝不镜像到 PB 服务器分发。

## 6. 三个代价（需要用户拍板）

| 代价 | 数字 | 说明 |
|---|---|---|
| **覆盖率不足一半** | 约 45% | 剩下 55% 仍是"没视频"，属正常分支 |
| **磁盘** | 单个 30–45MB | 200 个游戏若全抓约 3–4GB（按 45% 覆盖算）。**必须做成可关/可按需** |
| **首次下载耗时** | 本机实测 44.5MB ≈ 3 分钟 | 取决于带宽；50 个分片，需后台跑，不可阻塞 |

另外：**版权**与**"自动下载是否该静默发生"**是产品判断，不是技术判断。

## 7. 未验证 / 待补

- 🔴 **本机 `CreateFile failed 231` 未恢复**，`flutter analyze/test/build` 全部不可用
  ⇒ 本次只有纯 Python + 字节级校验，**没有编译过、没有真机播放验证**。
- ⏳ **MF 播放 fMP4 的真机确认**（文档层面成立，实际解码仍需一次 `flutter test` 或真机）。
- ⏳ Steam 商店 API 的**限流与稳定性**（本次 20 次请求正常，未压测）。
- ⏳ 分片下载的**断点续传 / 网络抖动重试**未设计（实测出现过单次 000，重试即成功）。

## 8. 明确不做

- ❌ 用 YouTube 下载（需 yt-dlp 外部依赖 + cookies，与打包瘦身直接冲突）
- ❌ 1080p 档（体积翻倍，背景板看不出差别）
- ❌ 流式播放（MF 不支持 HLS，`video_player_win` 无法绕开）
- ❌ 封面图/截图自动抠取（同类路线已在标题图 §2.5 否决）
