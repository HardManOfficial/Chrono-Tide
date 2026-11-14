# 调研报告：游戏视频素材数据源可行性

| 项 | 值 |
|----|-----|
| **状态** | 调研产出（**只读，未改动任何代码**） |
| **日期** | 2026-10-06 |
| **需求** | BPM 模式的背景视频（游戏 PV / OP / ED / 宣传片）由「用户自己上网找」改为「API 自动获取 + 一键导入」 |
| **关联档案** | `bpm_custom_backdrop_and_op_video_plan.md`（BPM OP 视频方案）、`big_picture_v3_cinema.md`（BPM 演进史）、`ct_metadata_source.md`、`nextmoe_source.md` |
| **实测产物** | `dev_probe/steam_sg.json`、`dev_probe/vndb_schema.json`、`dev_probe/ct_games.json`、`dev_probe/docs/*` |

---

## 0. 结论摘要（TL;DR）

| # | 结论 | 证据强度 |
|---|------|---------|
| 1 | **项目现有 8 个数据源，无一提供视频素材。** 元数据模型 `Game` 只有 `screenshotUrls`，`lib/` 内没有任何视频 URL 解析路径 | 实测（schema/接口/代码 grep） |
| 2 | **Steam 源已经接入，但只解析了 `screenshots`，`movies[]` 从未被使用。** 这是成本最低、覆盖最好的突破口 | 实测 8 个作品全部命中 |
| 3 | Steam 的 `appdetails` 现在**只返回 DASH/HLS 清单，不再返回 mp4 直链**；但遗留 CDN 直链 `cdn.cloudflare.steamstatic.com/steam/apps/{movie_id}/movie480.mp4` **实测全部可用**，是真正的可下载 mp4 文件 | 实测 7 个 movie_id，全部 200/206 |
| 4 | **授权最干净的是 Pixabay / Pexels**（官方 API + 书面许可 + mp4 直链），但内容是通用素材，**不是游戏 PV**，只能当氛围背景 | 官方文档实测 |
| 5 | **B站 / YouTube 不具备合法下载通道**（官方 API 不给源文件、ToS 禁止下载、高清有 DRM）→ 不建议做 | 官方文档/社区文档 |
| 6 | **推荐：主方案 Steam（游戏 PV），兜底 Pixabay（氛围背景）。** 二者都能拿到 mp4 文件直链，正好落在 BPM 现有的 `mp4/m4v` 白名单内 | — |

🔴 **一句话风险**：Steam CDN 直链是「技术上可用、法律上未明示授权」。这个要不要做，**必须由开发者拍板**（见 §5 待确认 Q1）。

---

## 1. 现有数据源盘点（全部实测）

### 1.1 汇总表

| 数据源 | 接口地址 | 鉴权 | 已解析字段 | 是否含视频 |
|--------|---------|------|-----------|-----------|
| **VNDB (Kana v2)** | `POST https://api.vndb.org/kana/vn` | 登录 token（可选） | 22 个字段，含 `screenshots{url}`、`length_minutes` | ❌ **无** |
| **Bangumi** | `https://api.bgm.tv` | OAuth | 番剧元数据 + 图片 | ❌ **无**（本次网络未连通，未实测） |
| **NextMoe** | `https://api.nextmoe.dev/v2` | Bearer `nmk_live_…` | titles/intros/covers/**screenshots**/companies/tags/ratings | ❌ **无** |
| **Hikarinagi** | `https://www.hikarinagi.org/api/v3/open` | OIDC client-credentials | trans_/origin_ 标题、covers、tags、screenshots | ❌ **无** |
| **KunGal（鲲）** | `https://www.kungal.com/api` | 401（需登录） | banner、screenshots、跨源评分 | ❌ **无**（本次 401，未实测详情） |
| **TouchGal** | `https://developer.touchgal.com/api/v1` | Bearer Token | galgame 元数据 | ❌ **无**（本次网络失败，依据代码解析链判断） |
| **CT 自建库（PB）** | `http://117.72.115.30:8090/api/collections/games/records` | 匿名只读 | 34 个字段（title/cover/screenshots/downloadUrl…） | ❌ **无** |
| **Steam（已接入）** | `https://store.steampowered.com/api/storesearch/`<br>`https://store.steampowered.com/api/appdetails` | 无 | name/genres/**screenshots**/metacritic/短描述 | ⚠️ **接口有 `movies[]`，但代码没解析** |
| **DLsite** | HTML 抓取（`www.dlsite.com/maniax/…`） | 无 | 标题/封面/标签 | ❌ 无官方 API（本次网络未连通） |
| **ymgal（月幕）** | `https://www.ymgal.games/open/archive/search-game` | OAuth token | 中文元数据 | ❌ **无** |

### 1.2 关键实测记录

**① VNDB —— 权威确认无视频字段**

```
GET https://api.vndb.org/kana/schema   → HTTP 200
/vn 字段全集（22 个）：
aliases, alttitle, average, description, developers, devstatus, editions,
extlinks, id, image, languages, length, length_minutes, length_votes, olang,
platforms, popularity, rating, relations, released, screenshots, staff, tags,
title, titles, va, votecount
含 video/trailer/movie/youtube 的字段：无
screenshots 结构：{dims, id, release, sexual, thumbnail, thumbnail_dims, url, violence, votecount}  ← 全是图片
extlinks 枚举：仅 wikidata、renai.us 两种
```

**② NextMoe —— 加了 `videos` 就 400，说明数据块不存在**

```
GET /v2/catalog/works/60?include=titles,intros,covers,screenshots,companies,tags,ratings  → 200（可用块就这么几个）
GET /v2/catalog/works/60?include=…,videos,trailers,media                                 → 400 Bad Request
```

**③ 自建 PB `games` 集合（299 条记录）—— 无视频字段**

```
字段：Developer, bannerUrl, coverUrl, description, downloadUrl, englishTitle,
estimatedMinutes, file_size, has_official, installCount, like_count, metaSource,
origin, originalTitle, owner, rating, releaseDate, review_status, screenshots,
tags, title, traditionalChineseTitle, voteCount, …
含 video/movie 的字段：无
```

**④ Steam —— 已接入但视频能力被浪费（本次最重要的发现）**

```
GET /api/appdetails?appids=412830   → movies[] 存在，3 条
实测 8 个作品（STEINS;GATE / SG0 / DDLC / CLANNAD / Nekopara / 寒蝉 / 赛博朋克 / 艾尔登法环）：
  全部返回 movies[]，键固定为：id, name, thumbnail, dash_av1, dash_h264, hls_h264, highlight
  ⚠️ 无一返回 mp4 / webm 键 —— 现在的 appdetails 只给自适应流清单
```

但**遗留 CDN 直链仍然可用**（这是可行的关键）：

| movie_id | 作品 | `movie480.mp4` | `movie_max.mp4` |
|---|---|---|---|
| 256658578 | STEINS;GATE PV | 15.8 MB（853×480，实测 tkhd） | — |
| 256711577 | Steins;Gate 0 | 8.5 MB | 41.7 MB |
| 256692832 | DDLC | 7.1 MB | 35.1 MB |
| 256763568 | CLANNAD | 21.7 MB | 42.1 MB |
| 256786517 | Nekopara Vol.1 | 6.2 MB | 29.7 MB |
| 256779756 | 寒蝉鸣泣之时 | 6.3 MB | 31.3 MB |
| 257082814 | 赛博朋克 2077 | 13.1 MB | 65.8 MB |
| 256846213 | 艾尔登法环 | 24.8 MB | 123.4 MB |

```
请求：GET https://cdn.cloudflare.steamstatic.com/steam/apps/256658578/movie480.mp4
响应：HTTP/1.1 206  Content-Type: video/mp4  Content-Range: bytes 0-0/16592579
文件头：00 00 00 20 66 74 79 70 69 73 6f 6d … avc1 mp41   ← ftyp + isom + avc1 + mp41，标准 H.264 MP4
```
`cdn.akamai.steamstatic.com` 同路径同样可用（实测 206）。

**⑤ 代码侧确认**：`lib/` 内没有任何视频 URL 解析。Steam 解析只调了 `_extractSteamScreenshots`（`metadata_services.dart:620`），`movies` 从未被读取。

---

## 2. 外部平台调研

### 2.1 候选对比总表

| 平台 | 官方 API | 鉴权 | 限流 / 费用 | 可获取内容与字段 | 授权说明 | 稳定性 | 判定 |
|------|---------|------|------------|----------------|---------|--------|------|
| **Steam storefront** | ⚠️ 半官方（无公开文档、无 SLA） | 无需鉴权 | 无公开限流文档；社区经验约 200 次/5 分钟触发 429（**本次未压测**） | `movies[]`：id、name、thumbnail、highlight；经 CDN 拼出 **mp4 文件直链**（480p / max） | ❌ **无明示授权**。视频版权归发行商，Valve 未声明允许第三方下载缓存 | 高（CDN 长期稳定，10 年前的老链接仍可下载） | ✅ **主方案（需拍板版权）** |
| **Pixabay** | ✅ 有 | API key（免费注册） | **100 次 / 60 秒**（按 key），免费 | `hits[]`：`duration`、`videos.large/medium/small/tiny` 各有 `{url, width, height, size}` → **mp4 直链** | ✅ Content License：免费商用、无需署名；**禁止 hotlink**（我们是下载，合规） | 高 | ✅ **兜底方案（授权最干净）** |
| **Pexels** | ✅ 有 | API key（免费注册） | **200 次/小时、20,000 次/月** | `videos[]`：`duration`、`video_files[]{quality,width,height,link,file_type}` → mp4 直链 | ⚠️ Pexels License 免费商用，但官方 Guidelines 明确：**不得复刻 Pexels 核心功能（含做成壁纸类应用）**；须展示 "Photos provided by Pexels" 链接 | 高 | 🟡 可用但有**壁纸条款**风险，优先级低于 Pixabay |
| **IGDB** | ✅ 有（v4） | Twitch OAuth client-credentials + Client-ID | **4 次/秒 / Client-ID**；免费但**仅限非商业** | `/game_videos` → `{game, name, video_id}`，`video_id` 为**外部 ID（通常是 YouTube）** | ⚠️ 受 Twitch Developer Services Agreement 约束；商业需合作 | 高 | ❌ 只给 YouTube ID，**拿不到文件**，不能直接用于本地导入 |
| **YouTube Data API** | ✅ 有 | API key / OAuth | 配额 10,000 units/日 | 仅元数据（title/duration/thumbnails），**无文件直链** | ❌ ToS 明确**禁止下载**（本次联网核实被拦，依据既有条款认知，标注未核实原文） | — | ❌ 不可行 |
| **哔哩哔哩** | 官方开放平台有 `item_get_video`，但**明确不提供播放/源文件链接**；非官方链路需 WBI 签名 + `SESSDATA` Cookie | 企业/个人实名 + 审核 | 配额制 | 官方：基础信息（番剧等版权内容连播放链接都没有）；非官方：DASH/m4s 分离流，1080P+ 有 Widevine DRM | ❌ 官方合规要求写明「**禁止通过接口获取视频源文件进行盗播**」；非官方路径违反用户协议 + 著作权风险 | 极差（2023 起 WASM 加密 + 设备指纹，工具常态化失效） | ❌ **明确不推荐** |
| **Giant Bomb** | ✅ 有 | API key（免费） | 宽松 | 有 mp4 直链 | 非商业免费 | 中 | ❌ 欧美主机/PC 为主，**galgame 覆盖≈0** |
| **Mixkit / Coverr / Videvo** | ❌ 无公开下载 API（仅网页/有限接口） | — | — | 网页下载 mp4 | 各自许可（Mixkit 免费商用、无署名；Coverr 类似） | — | ❌ 无 API，做不了自动化 |
| **DLsite / Getchu** | ❌ 无（仅 HTML） | — | — | 页面可能有样本图，未见 PV 视频托管 | ❌ 禁止自动抓取 | 差（本次 DLsite 无法连通） | ❌ 不可行 |

### 2.2 三个关键判断的依据

- **为什么 Steam 排第一**：项目已经接入了 Steam 源（`metadata_services.dart:406-620`），搜索 → appid → appdetails 的链路全部现成，只需新增「读 `movies[]` + 拼 CDN 直链」这一步；且 galgame 上 Steam 的比例不低（STEINS;GATE、寒蝉、CLANNAD、Nekopara 均实测有 PV/OP 素材）。
- **为什么 Pixabay 排第二**：授权是唯一有保障的（Content License，官方 API 文档明示 royalty-free、可商用、不强制署名），能拿到 mp4 直链和 `duration`/`width`/`height`/`size`。代价是**内容不是游戏相关**——只能作为「找不到 PV 时的氛围背景」。
- **为什么 B站/YouTube 排除**：不是技术做不到，是**没有合法通道**。B站官方接口白纸黑字禁止取源文件；非官方链路要逆向签名 + 用户 Cookie，且项目是分发给终端用户的桌面软件，把这种风险打包进产品不合适。

---

## 3. 推荐方案

### 3.1 双源策略

| 场景 | 数据源 | 产出 |
|------|--------|------|
| 游戏在 Steam 上架且有 `movies[]` | **Steam**（主） | 真正的游戏 PV / OP / 预告片 |
| Steam 无结果（多数日系 galgame 不上 Steam） | **Pixabay**（兜底，可选） | 通用氛围视频（如「樱花」「雨」「城市夜景」），按游戏标签映射关键词 |
| 两者都没有 | 保持现状 | 用户手动上传（现有能力不变） |

> 兜底是否启用、是否引入 Pixabay，取决于开发者对 §5 Q2 的答复。只做 Steam 也是完整可用的方案。

### 3.2 自动导入流程（检索 → 筛选 → 下载 → 导入 BPM）

```
① 检索
   游戏名 → Steam storesearch（已有 _searchByName，metadata_services.dart:439）
          → appid
          → appdetails（已有 _fetchByAppID，:497）
          → 新增：读 data['movies']，取 {id, name, thumbnail, highlight}
   候选直链：https://cdn.cloudflare.steamstatic.com/steam/apps/{movie_id}/movie480.mp4
            https://cdn.cloudflare.steamstatic.com/steam/apps/{movie_id}/movie_max.mp4

② 筛选（必须让用户看得到、选得了）
   列表项：缩略图（thumbnail）+ name（Steam 给的文件名常含 OP/PV 字样，如
          "STEINSGATEOP1_Apr13rd2016"）+ 画质档位 + 预估体积
   排序建议：highlight==true 优先
   ⚠️ 名称歧义必须人工确认（日文原名 vs Steam 英文名差异大），不做静默自动绑定

③ 下载
   复用项目既有下载能力（lib/services/download_core.dart）或 Dio 流式下载
   → 先落临时目录（🔴 必须 D 盘，遵守「C 盘空间不足」的历史教训）
   → 断点/超时：单文件 6–130MB，建议超时 ≥60s、失败重试 2 次 + 指数退避
   → 代理：走 SDK 既有的三级代理检测（SystemProxyDetector），CDN 在海外

④ 校验（对照 BPM 现有门槛，bpm_backdrop_media.dart:57-77, :326）
   - 扩展名 mp4 / m4v
   - BpmBackdropMedia.looksLikeMp4() 文件头校验
   - 体积 ≤ 500MB（maxVideoBytes）
   - 建议分辨率 ≤ 1920×1080
   - 任一项不过 → 静默回退「无视频」，不弹错误打断用户

⑤ 导入 BPM（全部走既有 API，零 schema 变更）
   File.copy → Games/<safeName>/video_user_<stamp>_0.mp4
                （与 bpm_background_manager.dart:271 完全同构）
   → BpmBackdropMedia.addVideos(metaDataDir,
        [BpmBackdropVideoAsset(file: rel, name: '游戏 PV')])
        （bpm_backdrop_media.dart:274；自动把最后一个设为当前视频）
   → game.json 写入 bpm_backdrop_videos / bpm_backdrop_selected_video
     （仍走 updateGameJson merge、不升 format_version，符合 ADR-015）
```

### 3.3 体积与磁盘预算（基于 §1.2 实测）

| 档位 | 单文件体积（实测区间） | 100 部 | 1000 部 |
|------|---------------------|--------|---------|
| `movie480.mp4`（480p） | 6.2 – 24.8 MB | ≈1.5 GB | ≈15 GB |
| `movie_max.mp4`（最高画质） | 29.7 – 123.4 MB | ≈7 GB | ≈70 GB |

→ **建议默认 480p**，且**只做「单游戏手动触发」，不做全库批量拉取**。项目铁律里有「磁盘 <10G 禁写盘」。

---

## 4. 风险登记（P0–P3）

| # | 级别 | 风险 | 影响 | 建议应对 |
|---|------|------|------|---------|
| R1 | **P0** | **版权**：Steam CDN 直链无明示授权；PV 版权归发行商，缓存到用户磁盘属于复制 | 法律风险；若未来商业化更敏感 | 需开发者拍板（Q1）。折中方案：**不预下载，只在用户点击时按需下载并保留手动上传路径**；设置里加显式开关 + 免责说明 |
| R2 | **P0** | **Pexels 壁纸条款**：官方 Guidelines 禁止「做成壁纸类应用」，BPM 动态背景可能被认定 | 若选 Pexels 有条款风险 | **优先 Pixabay**（Content License 无此条款）；Pexels 仅作备选 |
| R3 | P1 | **限流 / 风控**：Steam 无 SLA 与公开限流文档，可能 429 或风控 | 抓取失败 | 复用 `RateLimiter` + 指数退避；结果进磁盘缓存（与元数据 24h 缓存同构）；失败静默降级为「无视频」 |
| R4 | P1 | **名称匹配错误**：日文原名 ↔ Steam 英文名差异大（如「ひぐらしのなく頃に」→ "Higurashi When They Cry"） | 装错视频，观感崩坏 | **不做静默自动绑定**，候选列表必须由用户确认；提供「换一个」与「移除」 |
| R5 | P1 | **编解码兼容**：`video_player_win`（Media Foundation）不支持 HLS/DASH；webm/AV1/HEVC 依赖系统扩展 | 黑屏 | 只取 **mp4** 直链（Steam 实测为 avc1/mp41，安全）；下载后仍走 `looksLikeMp4` 校验；失败静默回退封面 |
| R6 | P2 | **覆盖率不足**：大量 galgame 不上 Steam | 多数游戏无素材 | 保持手动上传；可选接 Pixabay 兜底（Q2） |
| R7 | P2 | **磁盘与并发**：批量下载可能爆盘；与中国用户网络环境（海外 CDN） | 卡顿 / 写盘失败 | 默认 480p、单游戏触发、下载前检查剩余空间（项目已有此铁律） |
| R8 | P2 | **成人内容**：Steam 含成人作品，封面/视频可能不适宜 | NSFW 策略冲突 | 与 BPM 现有 NSFW 策略对齐（clean 模式下不自动播放，见 `bpm_custom_backdrop_and_op_video_plan.md` §4.3 Q2） |
| R9 | P3 | **UI 新增**：BPM 背景管理器（`bpm_background_manager.dart`）当前**只有本地上传，无在线入口** | 需新增 UI | 新增「在线获取素材」区块，严格局部改动 |
| R10 | P3 | **API key 存放**（若接 Pixabay/Pexels）：桌面应用无服务端 | key 泄露 | 与现有 NextMoe/TouchGal 同策略：源码常量（轮换需发版）；或让用户自填（Q6） |

---

## 5. 🔴 需要开发者补充确认的清单

| # | 问题 | 我的建议默认 | 为什么必须你拍板 |
|---|------|-------------|-----------------|
| **Q1** | **Steam CDN 直链下载并缓存到用户本地磁盘，这个版权尺度接受吗？** | 接受，但限定：仅用户显式点击触发 + 仅本地个人使用 + 设置里可关闭 + 加免责说明 | 这是整个方案能不能做的**前提**。不接受的话，方案只能退化为「一键打开 Steam 商店页，用户自己下载」 |
| **Q2** | 是否要接 **Pixabay** 做「找不到 PV 时的氛围背景兜底」？ | 先不接，只做 Steam；Steam 跑通后再评估 | 引入第二个 API key + 第二套 UI 语义（"这是通用素材不是游戏 PV"），会显著扩大改动面 |
| **Q3** | 默认画质档位：**480p（6–25MB）** 还是 **max（30–123MB）**？ | **480p** | 背景用途 480p 足够；1000 部全量时磁盘差 5 倍 |
| **Q4** | 是否允许**批量**（选中多个游戏一次性拉取）？ | **不允许**，只做单游戏触发 | 1000 部 × 15GB 的磁盘与限流风险不可控 |
| **Q5** | 候选视频列表的交互形态：弹窗勾选 / 直接在背景管理页内联列表？ | 背景管理页内联列表 + 缩略图 | 影响 UI 改动范围（`bpm_background_manager.dart`） |
| **Q6** | 若接 Pixabay/Pexels：**key 用源码常量**（与 NextMoe/TouchGal 一致）还是**用户自填**？ | 源码常量 | 桌面应用无服务端，两害相权；用户自填体验差 |
| **Q7** | Steam 匹配到多个候选 / 匹配不确定时，是否允许**自动选第一条**？ | **不允许自动绑定**，必须用户确认 | 装错视频的观感代价很高（R4） |
| **Q8** | 下载的视频是否需要**纳入 NSFW 判定**（cover 已有判定链路）？ | 复用现有 clean 模式策略：需模糊的游戏不自动播放 | 视频层目前不经过 `NsfwImage`，属既有开放问题 |

---

## 6. 本次调研的「未验证项」（诚实标注）

| 项 | 状态 |
|----|------|
| Steam 的实际限流阈值（429 触发点） | **未压测**（避免对 Steam 造成压力）；仅有社区经验值 |
| Steam CDN 直链的长期可用性 | 实测 8/8 可用，其中含 2017 年的老资源；但**属未公开契约，Valve 随时可能下线** |
| Bangumi / TouchGal / DLsite 是否含视频 | **本次网络未连通**（代理 502 / SSL EOF），依据代码解析链与已知结构判断为「无」，未经实测确认 |
| YouTube ToS 禁止下载的原文 | **联网核实被拦截**，依据既有条款认知，建议法务角度二次确认 |
| Pexels「壁纸应用」条款的适用边界 | 已读到官方 Guidelines 原文，但「BPM 动态背景是否构成壁纸应用」属**解释性问题**，需人工判断 |
| Pixabay / Pexels 的中文 galgame 相关关键词命中率 | **未实测**（需先申请 API key） |

---

## 7. 下一步（若批准实施）

建议按 `bpm_custom_backdrop_and_op_video_plan.md` 的既有惯例，**先 Phase 0 技术验证，再落地**：

- **Phase 0（先证伪）**：
  1. Steam `movies[]` → CDN 直链，对 20 个真实 galgame appid 抽样，统计命中率；
  2. 下载 3 个真实 mp4，用 `video_player_win` 在 BPM 背景层实际播放，验证 H.264/AAC 解码与 480p 开销；
  3. 验证代理场景（海外 CDN）下的下载成功率与耗时；
  4. 确认无 `movies[]` 的作品（占多数）降级路径不产生任何 UI 噪声。
- **Phase 1**：新增 `lib/services/game_video_source_service.dart`（检索/拼链）+ 单测（fixture 离线）。
- **Phase 2**：BPM 背景管理页新增「在线获取」区块（局部改动）。
- **Phase 3**：下载 → 校验 → `BpmBackdropMedia.addVideos` 接线；真机走查。

> ⚠️ 本报告**未改动任何代码**。落地前需先拿到 §5 Q1 的答复，并按 AGENTS.md §2.2 走《变更计划》批准流程。

---

## 附录：本次实测命令与产物

```bash
# Steam 视频字段结构（8 个 appid）
curl "https://store.steampowered.com/api/appdetails?appids=412830&l=schinese&cc=CN"
# → dev_probe/steam_sg.json

# Steam CDN 直链可用性与体积
curl -r 0-0 "https://cdn.cloudflare.steamstatic.com/steam/apps/256658578/movie480.mp4"
# → HTTP 206, Content-Type: video/mp4, Content-Range: bytes 0-0/16592579

# VNDB 字段全集
curl -L "https://api.vndb.org/kana/schema"           # → dev_probe/vndb_schema.json

# NextMoe include 块探测
GET /v2/catalog/works/60?include=…,videos,trailers,media   # → 400（不存在该数据块）

# 自建 PB games 集合
curl "http://117.72.115.30:8090/api/collections/games/records?per_page=1"  # → dev_probe/ct_games.json

# 素材库官方文档
curl "https://pixabay.com/api/docs/"    # → dev_probe/docs/pixabay.com_api_docs_.html
curl "https://mixkit.co/license/"       # → dev_probe/docs/mixkit.co_license_.html
```

**代码落点速查（导入流程用）**

| 步骤 | 文件:行号 |
|------|----------|
| Steam 搜索（已有） | `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart:439` |
| Steam 详情（已有） | `metadata_services.dart:497`（`_fetchByAppID`） |
| Steam 截图解析（**只解析了这个**） | `metadata_services.dart:620`（`_extractSteamScreenshots`） |
| 视频白名单 / 体积上限 / 分辨率建议 | `lib/big_picture/services/bpm_backdrop_media.dart:57`、`:72`、`:76` |
| MP4 文件头校验 | `bpm_backdrop_media.dart:326`（`looksLikeMp4`） |
| 视频文件命名与落盘 | `lib/big_picture/widgets/bpm_background_manager.dart:254-273` |
| 写入 game.json 的 API | `bpm_backdrop_media.dart:274`（`addVideos`） |
| 播放状态机 | `lib/big_picture/services/bpm_backdrop_media_controller.dart` |
| 既有下载能力（待评估复用） | `lib/services/download_core.dart` |
