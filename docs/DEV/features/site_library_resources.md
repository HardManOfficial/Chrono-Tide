# SITE-LIBRARY · 全站库资源能力（获取 / 分享 / 补丁点亮）

> 2026-11-13。前置：SITE-SEARCH（全站搜索）、PATCH-STATION v5.3（补丁站）。
> 术语为用户 2026-11-13 拍板：**探索库** = 原生游戏库；**全站库** = 全站搜索
> 结果的总称（含探索库 + 鲲 + 2DFan，在探索库界面列表展示）。

## 1. 需求语义（用户拍板，2026-11-13）

全站库命中详情页的六个动作不再一律灰置：

| 按钮 | 新语义 | 实现载体 |
|------|--------|----------|
| **获取** | **只列有 letmoe 托管直链的资源**，展开只见直链镜像 → 软件内下载到缓存目录（完成后手动导入） | `SiteLibraryResourcePanel(mode: direct)` |
| **分享** | **只列有网盘渠道的资源**，展开只见网盘镜像（链接/提取码/解压密码 + 外跳） | 同上（`mode: netdisk`） |
| **补丁** | 沿用补丁站（PATCH-STATION），鲲+2DFan 都可用；鲲命中直接传 catalog id 零误配 | `PatchStationDarkPanel` + knownWorkId 旁路 |
| 上传 / 喜欢 / 反馈 | **仍灰置**（社区功能绑定 PB 记录，站外作品没有） | — |

用户点明：全站库里的「获取/分享」**不代表**官方获取/软件内用户分享，是站点
侧资源的查询与下载出口。网盘资源（夸克/百度）必须用他家客户端，软件内只能
复制链接+提取码后外跳浏览器——已在面板中如实呈现（用户批准该边界）。

## 2. 数据源：letmoe 下载资源链接面（2026-11-13 全部 curl 实测）

`https://api.nextmoe.dev/v2/letmoe`（一起萌，鲲生态官方上游，文档
developer.nextmoe.dev/docs/letmoe）：

- `GET /works/{id}/resources?nsfw=true` → 资源列表（title/type/size/
  language/platform/providers/direct_download/解压说明/web_url）
- `GET /resources/{id}/file` → mirrors[]（kind=external_link 或托管直链、
  provider、url、**extract_code、archive_password**、is_primary）+ composites
- `GET /works?ids=` → 批量问哪些作品有资源（resource_count/has_direct_download）

🔴 **身份体系**：作品 id == catalog 作品 id == 全站搜索鲲命中的
`SiteSearchHit.siteId` == 补丁站 moyu 源的 `refs=catalog:<id>` 同一个数。
密钥创建自动带 `letmoe:files` scope（`/file` 必需）。

🔴 **官方契约**：
- `/file` 答案一律 no-store + 每次成功记一次下载 ⇒ **只在用户展开资源时调，
  绝不预取、绝不缓存**（`LetmoeResourceService.getResourceFile`）；
- 列表端点缺省 `nsfw=false`（成人作品直接消失）⇒ 必须显式 `nsfw=true`；
- 批量端点返回顺序 ≠ 传入顺序 ⇒ 按传入 id 重排。

⛔ 匿名/错误命名探测结果（别再试）：`kungal.com/api/**` 一律 `{"code":205}`；
`v2/moyu/resources|galgames|games|downloads|links` 全 404——游戏本体资源
只在 letmoe 面，不在 moyu 面。

## 3. 实现

| 文件 | 角色 |
|------|------|
| `luna_metadata_sdk/lib/models/letmoe_resource.dart` | 新模型（Resource/Files/Mirror/WorkSummary） |
| `luna_metadata_sdk/lib/services/letmoe_resource_service.dart` | 新服务：列表（TTL 10min 缓存）/ file（不缓存）/ 批量摘要 |
| `luna_metadata_sdk/lib/services/nextmoe_service.dart` | 新增 `resolveWorkIdByTitle`（只打 /catalog/search，归一化全等才算命中，宁缺毋滥）+ `normalizeWorkTitle` |
| `lib/services/site_search/site_library_resource_service.dart` | 解析器：鲲命中 siteId 直连；2DFan 命中标题反查（查不到 = unresolved） |
| `lib/widgets/site_library/site_library_resource_panel.dart` | 深色锚定面板（DarkPalette + stickBelow:true，与补丁站同外壳）：**双互斥模式**（direct/netdisk，⛔ 无 chips、不可切换）、资源卡、懒加载镜像行、复制链接/提取码/解压密码、外跳、**软件内下载**（含 http/https 安全闸） |
| `lib/pages/site_game_detail_page.dart` | 三按钮点亮 + 「站外作品 · 只读」→「全站库作品」+ 补丁传 catalogWorkId |
| `patch_station_panel.dart` | `PatchGameRef` 新增可选 `catalogWorkId` |
| `patch_search_service.dart` | `search()` 新增 `knownWorkId`：非 null 跳过身份解析直接锚定（confidence 1.0） |
| `patch_station_dark_panel.dart` | 透传 knownWorkId |

### 获取 → 软件原生安装（2026-11-14）

**游戏本体（`type == 'game'`）的直链不再「只下载」**，直接走安装中心：
下载 → 解压 → 自动入库（写 game.json、扫 exe、登记注册表），进度在左下角
任务按钮。实现在 `lib/services/site_search/site_library_install_flow.dart`：

| 步骤 | 做法 |
|------|------|
| 安全闸 | 只放行 `http`/`https`，`file://` 与自定义 scheme 一律拒绝 |
| 去重 | `GlobalInstallCenter.isQueuedOrRunning(gameId)`，`gameId = site:<源key>:<站点id>` |
| 同标题已在库 | `showConfirmDialog` 明确告知会生成第二个同名条目（不静默拦截，也不覆盖原目录） |
| 体积 | 组合包用自带 `bytes`；其余现量一次 HEAD（8s 超时，失败退 `Range: bytes=0-0` 取 `Content-Range`），仍失败则体积显示「未知」不阻断 |
| 确认弹窗 | 复用 `InstallConfirmationDialog`，新增 `knownSizeBytes` 入参（不走 OpenList 网盘路径的体积预取） |
| 提交 | `GlobalInstallCenter.submitTask(task)`，`unawaited`（Fire-and-forget 语义同 `CloudInstallFlow`） |

⛔ **不走 `CloudInstallFlow`**：那条链要先 OpenList 配对、再把网盘**路径**换成
会过期的签名直链；letmoe 托管直链（`dl.imoe.uk/letmoe/<uuid>.zip`）不签名
不过期，因此也**不需要 `urlResolver`**。

非本体资源（特典 / 广播剧 / 补丁包）保留「下载到本地」：包内没有可执行本体，
进安装管线会触发「未找到本体」决策弹窗。这条路径的 `DownloadCore` 任务改为
**进程级表**（`_siteDownloadTasks`，key = mirrorId）——旧实现放在 State 里，
关面板再点会新建 core，两条实例对同名 `.part_N.tmp` 并发写、分片必然损坏。

### 面板状态机

loading → resolved(资源列表) / **unresolved**(2DFan 反查失败：文案 + 打开
2DFan 作品页兜底) / **空资源**(定位到但 letmoe 没收录：文案 + 打开 letmoe
页面)。资源展开后懒加载 /file，失败可重试。按钮恒可点（不做预检），状态
全部在面板内呈现。

## 4. 验证

- **探针**：`dev_probe/site_library_resource_probe.dart`（flutter_tester dill）
  —— **53 PASS / 0 FAIL**（2026-11-14 原生安装接入后复跑）：
  - A 段真 HTTP e2e（binding 之前，真 HttpClient 直连官方 API）：资源列表
    4 条 / /file 镜像（夸克直链 + 百度提取码 j34b + 解压密码 game）/
    works 批量 missing / 反查正例（中文名+日文原名→2222）+ 负例→null /
    解析器鲲命中直连；**A20–A26 为原生安装新增**：组合包解析（缺 `kind`
    不再误判网盘）、`isComposite`/`patchName`/`bytes`/`filename`、
    `downloadableArchives` 与 `netdiskLinks` 的互斥归属、
    `buildGameId` 合成 id、`providers:['direct']` 不算网盘渠道；
  - B 段渲染（离线注入，`initialContext` 参数）：详情页三按钮点亮 + 灰置项 +
    双 key 挂载 + 「全站库作品」文案；面板**直链模式**（标题「下载并安装」、
    只出直链资源、不显示网盘徽章、无旧 chips）/ **网盘模式**（标题、徽章、
    计数）/ 直链空态引导去「分享」/ 未定位 / 无资源。
- **analyzer**：SDK 根（ct_analyze_probe_sdk_ct.dart，根路径已修正为
  apps/chrono-tide/...）+ 应用根，改动文件全 0 error。
- ⏳ 真机待走查：搜「ChronoBox」→详情→获取→**下载并安装**（确认弹窗体积/
  剩余空间 → 左下角进度 → 解压 → 自动入库）→ 分享（网盘视图）→ 补丁。

## 5. 边界与后续

- 2DFan 命中的资源能力受限于反查命中率：标题全等（归一化后）才认，查不到
  即灰置兜底——比串错资源更可取。
- 磁力链接：kungal 网页资源页有磁力，但 letmoe API 不提供（只有托管直链 +
  网盘）；若将来要磁力，得走 kungal Cookie 抓站内页（另立项）。
- 本体资源装完**自动入库**（`gameId = site:<源key>:<站点id>`，写进 game.json
  的 `cloud_game_id`，同时作为安装队列去重键）；非本体资源仍只下载到缓存目录，
  由用户从「添加游戏」手动导入。
- 站外作品不参与云端安装统计（`InstallStatsService.reportInstall` 对
  `site:` 前缀直接跳过）——否则 PocketBase 里会留下指向不存在作品的记录。
- 🔴 已知遗留：日版 zip 包内文件名多为 CP932，`7z x` 未带 `-mcp=932` 时在
  中文 Windows 上可能解压成乱码。**与本地压缩包导入同一问题**（不是本次引入），
  且全局加 `-mcp=932` 会反过来打坏 GBK 命名的中文包，故暂不改。
- 🟡 待真机确认：站外安装提交的是 `unpackPlan: null`（无解压计划直解一层）。
  若某些 letmoe 托管包是「zip 套分卷/套 rar」的双层结构，第一层解完只会得到
  内层压缩包——需要真机跑一个样本确认是否要给站外安装补一次格式探测并把
  `UnpackPlan` 带进 `InstallTask`（既有本地导入的计划窗那条路）。

## 6. 2026-11-14 改版（用户拍板）

### 6.1 获取 / 分享彻底分开（不可切换）

上一版是「同一面板 + 全部/可下载/网盘三个 chips」，实测观感与用户要求不符：
「获取」里照样列着一堆夸克链接，用户以为点进去就能在软件里下。改为两个
**互斥模式**（`SiteLibraryResourceMode`）：

| 模式 | 入口 | 资源筛选 | 镜像筛选 | 空态 |
|------|------|----------|----------|------|
| `direct` | 获取 | `resource.direct_download == true` | `files.downloadableArchives`（托管直链 + 组合包） | 「没有可直链下载的资源」+ 指引去「分享」 |
| `netdisk` | 分享 | `resource.hasNetdiskProviders` | `files.netdiskLinks`（只有真网盘外链） | 「没有网盘资源」+ 指引去「获取」 |

🔴 资源卡角标也按模式过滤：直链模式不当众列「夸克网盘」，网盘模式不显示
「可直链下载」——否则一个角标就把「分开」的意义抵消了。
🔴 空态必须点明「另一种资源存在但要去另一个入口」，否则用户以为这部作品
根本没有资源。

### 6.2 全站库结果条重做（`SiteSearchResultBar`）

原为 28px 高的一行长文本（`站外「x」· 鲲 1 · 2DFan 1（已滤除 N 条）`），
信息挤在一起且不可操作。新设计：

- 32px 单行，与 `_contentTopPadding` 预留的 32 对齐；
- 左：`全站库` 标识 + 关键词；中：**每个源一个计数胶囊**（点击 = 只看该源，
  再点 = 取消；0 条不出胶囊）；差额（滤除/与库内重复）与失败原因进 Tooltip；
- 右：`重新搜索`（`forceRefresh: true` 跳缓存）+ `关闭`。
- 🔴 计数口径 = **去重后实际能上屏的条数**（`_displaySiteHits`），不是原始命中
  数——否则会出现「写着 鲲 3，点下去只剩 0 张」。
- 🔴 抽成独立组件（`lib/widgets/site_search/site_search_result_bar.dart`）的
  唯一原因：它只在有站外结果时出现，页面级探针拿不到该状态，抽出来才能被
  `dev_probe/site_search_result_bar_probe.dart` 直接覆盖（33 PASS）。

### 6.3 直链下载接原生安装 + 两个真 bug 修复

用户 2026-11-14 拍板 A 案：「获取」里的直链按钮直接变成「下载并安装」，
彻底不要「仅下载到本地」；范围只对 `type == 'game'` 的本体资源。

顺手修掉两个会让这个功能「看起来能用、实际恒失败」的既有 bug：

| # | Bug | 根因 | 修法 |
|---|-----|------|------|
| 1 | 一大批资源恒显示「解析失败」 | `GET /resources/{id}/file` **必须带 `?nsfw=true`**，不带时 nsfw 资源直接 404 `no visible resource with id` | `getResourceFile({bool nsfw = true})`，默认带上 |
| 2 | 「本体+汉化补丁」组合包被当成网盘 | composites 响应里**没有 `kind` 字段**，`LetmoeMirror.fromJson` 兜底成 `external_link` ⇒ 进「分享」、点「打开网盘」外跳一个 zip | `fromJson` 支持 `defaultKind`，composites 显式按 `hosted` 解析；新增 `isComposite`/`patchName`/`bytes`/`fileName` |

第三个 bug 是并发的：面板内 `DownloadCore` 实例随面板开关重建，同名
`.part_N.tmp` 被两条实例同时写。现在本体走安装中心（全局单活动实例），
非本体下载改为进程级任务表，两条路都不会再出现双实例。

「获取」面板里现在会显示：

- 托管直链行 + 「下载并安装」（绿色 `本体+汉化` 角标表示组合包，下方一行
  「内含补丁：<补丁名>」）；
- 提交后按钮转「已提交安装」并 toast 指路左下角任务按钮；安装相位回到
  `idle`/`failed` 时自动复位，失败可原地重试。

### 6.4 下载加速通道（本机代理）

**为什么有这一节**：用户报「接入原生安装后只有 1.18 MB/s，浏览器有 20 MB/s」。
本机实测结论是**不是软件问题**：

| 通道 | 单连接 | 4 路并发合计 |
|------|--------|--------------|
| 直连 `dl.imoe.uk` | 0.10–0.23 MB/s（连测 8 次） | 0.8–2.1 MB/s |
| 本机代理 `127.0.0.1:7892` | 2.0–2.7 MB/s | 12.7 MB/s |

软件显示 1.18 MB/s 正是「直连 4 路并发」的量级。用户的
`download_intensity=auto` / `download_speed_limit_mbps=0.0` / 档位记忆 `high`
说明既没限速也没降档；`network_proxy_mode` 键不存在 ⇒ 默认跟随系统代理 ⇒
注册表 `ProxyEnable=0` ⇒ 全程直连。浏览器走了本机代理所以快。

**实现**（`lib/services/download_acceleration.dart`，纯 Dart）：

- `detect({probeUrl})`：并行探 14 个常见本地代理端口，再对前 2 个用
  `Range: bytes=0-0` 验证「真能拉通这条直链」；最坏等待 ≤ 6s。
- `dioFor(proxyUrl)`：只走该代理的 Dio（`findProxy = PROXY host:port`）。

**接线四处，默认行为零变化**：

| 位置 | 作用 |
|------|------|
| `DownloadCore.start(proxyUrl:)` | 非空 → 独立 Dio（任务结束 `close(force:true)`）；空 → 沿用共享实例 |
| `InstallTask.proxyUrl` + `_startDownload` | 任务级透传 |
| `InstallConfirmationDialog(proxySuggestion:)` | 体积行下方「使用本机代理加速下载」，**默认不勾** |
| `SiteLibraryInstallFlow` | 已有全局代理 ⇒ 跳过探测（防双重代理） |

**硬约束**：

- 默认不勾 —— 走代理消耗用户流量，必须显式选择；文案里写明会消耗代理流量、
  并指路「设置里可改全局代理」。
- 只作用于本次下载，不写全局策略，不碰元数据/图片/更新。
- 🔴 代理不可用时请求**直接失败**，绝不静默回退直连（否则用户以为在走代理，
  实际还是 0.2 MB/s 直连）。探针 `E1` 锁死这一条。

**验证**：

- `dev_probe/download_accel_probe.dart`（裸 VM，自建 CONNECT 代理）：
  **7 PASS / 0 FAIL / 2 SKIP**；
- `dev_probe/install_confirm_proxy_probe.dart`（flutter_tester）：
  **14 PASS / 0 FAIL**；
- 回归 `site_library_resource_probe.dart`：53 通过 / 0 失败。

**已知边界**：只能识别 HTTP(S) 代理端口；SOCKS-only 或纯 TUN 模式的加速器
探不到（TUN 会让直连本身也变快，无需探测）。彻底解决仍推荐用户在
「设置 → 网络与存储 → 网络代理」里配一次全局代理。

### 6.5 全站库直链改为单连接下载（DL-SINGLE-STREAM）

用户 2026-11-14 拍板：**全站库的下载不要分片并发，直接单连接直链，稳定安全优先。**

**实现**：`DownloadCore.start(preferSingleStream: true)`。

| 位置 | 作用 |
|------|------|
| `DownloadCore.resolveStrategy(hasCompletePackage, preferSingleStream, supportsRange)` | 纯函数，判定 `skipExisting / singleStream / chunked`；四路组合全部由探针锁死 |
| `DownloadCore.start(preferSingleStream:)` | 为 true 时**跳过档位探测**，直接 `_startSingleStreamDownload`，磁盘准入按 1 倍体积 |
| `InstallTask.singleStream` | 任务级透传，默认 `false`（探索库/网盘行为完全不变） |
| `SiteLibraryInstallFlow` | 组装任务时置 `singleStream: true` |
| 资源面板 `_startLocalDownload` | 非本体资源（特典/广播剧）同样单流 |

**为什么这样更稳**（这是用户要的点）：单流路径本身已经具备
`Range: bytes=N-` 断点续传、45s 无数据看门狗、15 次重试、逐块 `writeFrom`
落盘、磁盘满/无权限快速失败——也就是「稳定性」并不依赖分片。分片反而多出
两个故障面：多个 `.part_N.tmp` 并发写同一目录、以及最后一步的分片合并
（合并失败 = 全部重来，且合并期需要 2 倍空间）。

**代价（必须讲清楚）**：失去多连接叠加。

| 通道 | 单连接 | 4 路并发 |
|------|--------|----------|
| 直连 `dl.imoe.uk` | 0.10–0.23 MB/s | 0.8–2.1 MB/s |
| 本机代理 | 2.0–2.7 MB/s | 12.7 MB/s |

⇒ 一个 10 GB 的包：直连单流约 12 小时，代理单流约 1 小时。**所以单流必须
配合「代理加速通道」或全局代理使用**（见 6.4），否则会比改之前更慢。

**取消后的残留**：单流写入的是目标文件本身（不是 `.part_*.tmp`），取消时
**刻意保留**半成品——下次点同一个资源会从已落盘字节续传。想彻底放弃就手动
删缓存目录里的那个 zip。

**验证**：`dev_probe/single_stream_probe.dart` **9 PASS / 0 FAIL**
（A1–A6 锁死六种分支组合，含「缓存命中优先于单流」「支持 Range 也必须走
单流」；B1–B3 锁死 `InstallTask` 默认值）；回归
`site_library_resource_probe.dart` 53 通过、`install_confirm_proxy_probe.dart`
14 通过、`download_accel_probe.dart` 7 通过。

⚠️ 完整下载链路（真下载 → 解压 → 入库）**无法在探针里端到端跑**：
`DownloadCacheDir.resolveFor` 内的 `Directory.create(recursive: true)` 在
flutter_tester 里永久挂起，裸 VM 又加载不了 `dart:ui`。所以真实链路要靠
真机走查确认。
