# 横幅封面（Banner Cover）—— 游戏第二封面系统

> 状态：**Phase 1 已落地（2026-10-04）**，⏳ 待环境恢复补跑 flutter test + 真机走查。

## 1. 目标

竖向 2:3 封面在 BPM 大屏背景 / 主页大图上是**破坏性放大裁切**，显示不完整且模糊。
为每个游戏引入第二套标准数据：**横幅封面（横向大图）**——来自元数据抓取
（对标 Luna Box 的原数据抓取行为）。使用优先级：

- **BPM 背景**：用户自定义背景图（既有 `BpmBackdropMedia`）→ **横幅** → 竖向封面 → 主题背景
- **桌面主页**：详情预览面板模糊背景层与封面卡**横幅优先**，无横幅回退竖向封面

⚠️ 横幅是**封面图**（高清官方横版 key visual），**不是游戏截图**，二者语义严格区分。

## 2. 数据层

- game.json 新增可空字段 **`banner_file`**（相对元数据目录的文件名，如
  `banner_7.jpg`；空串 = 无横幅）。**不升 format_version**（保持 4）——
  纯新增可空字段 `?? ''` 读取即兼容（ADR-012 例外先例：storage_state 三字段，
  game_data_format.dart 头注释 2026-10-04 条目）。
- 落盘文件：元数据目录根 `banner_<nonce>.<ext>`（与 cover 同一套
  CoverDownloadService：缓存优先 + 3 次重试 + NSFW 检测入队）。
- `banner_file` 列入 `_overwritableFields`（抓取派生数据，与 `cover_file`
  同类）：重复入库以本次为准；本次无横幅 → 落空串（UI 回退竖封面）。
- `GameJsonData.toJson` 仅在非默认值时输出（老游戏 game.json 保持字节级旧形态）。
- 新增 `GameDataFormat.findBannerFile(dirPath, {bannerFileName})`，探测顺序：
  ① 传入已解析值（热路径）→ ② game.json `banner_file` 键 → ③ 目录内
  `banner.*` 扫描；找不到返回 null。
- 删除清理：随元数据目录递归删除，零新增代码（与 cover 同路径）。

## 3. 模型与抓取链

- `LibraryGame.bannerUrl`（绝对路径内存缓存）：scan 两个分支同步填充 +
  `registerExtractionComplete` 即时探测（免等下次 scan）。
- SDK `Game.bannerUrl`：
  - **NextMoe**：解析详情响应的 `covers[]` 数组（include 已请求 `covers`
    块，旧代码只读单数 `cover` 把数组丢掉了）——`_pickLandscapeBanner`：
    只收宽>高、多张取面积最大、跳过与竖封面相同 URL、缺宽高保守跳过。
  - **KunGal**：`effective_banner_url ?? banner_url` 直通（kun v2 该字段本就是
    横版大图；coverUrl 原值不动，最小变更）。
  - **VNDB**：kana API vn 端点无横幅字段（如实记录），不参与横幅供给。
- MIX 整合（metadata_fetcher.dart）：`_mixFieldPriority` 新增 `banner_url`
  链（NextMoe → KunGal）；`_convertToLegacyFormat` 透传 `banner_url`。
- 入库链透传 `writeGameDir(bannerUrl:)`：智能导入 / 批量导入 / 详情窗抓取。
  下载/解压安装链（extract_manager）暂不透传——云端资源记录无横幅数据源（P2）。
- 详情窗「抓取」：`_applyScrapeResult` 透传 `banner_url` →
  `_downloadBannerFromUrl`（落盘 + 写 `banner_file` + 同步 registry + 广播刷新）。

## 4. UI 接入

- **BPM**（big_picture_shell.dart）：`_resolveBackdropPath` 插入横幅层
  （自定义背景 → `_resolveBannerPath` → `_resolveCoverPath`）；
  `_resolveBannerPath` 与 `_resolveCoverPath` 同构。
- **主页**（home_page.dart）：
  - `_bannerPathCache` 并行缓存（结构性变化时随封面缓存一起清空）；
  - `_buildBannerImage`（结构与封面同构，解码限宽 960，横图不传 decodeHeight）；
  - 模糊背景层横幅优先（有横幅用横幅，无横幅回退竖封面）；
  - 封面卡**恒定竖版 3:4（180×240）**，始终显示竖封面——2026-10-09 起回退
    原横版 3:2（180×120）方案，见 §10。

## 5. 验证

- ✅ 进程内 analyzer 探针（231 环境降级通道）：全部改动 lib 文件 errors=0
  （含 SDK 嵌套包，需独立分析根 `ct_analyze_probe_sdk.dart`）；warning/info
  均为存量行。
- ✅ 回归测试 `test/services/game_banner_cover_test.dart` 5 例（老文件兼容 /
  toJson 输出策略 / findBannerFile 四路探测 / 重复入库覆盖语义 / 坏 URL），
  静态分析 0 error。
- ⏳ `flutter test` 因阵发 231（C 盘 99% 满）无法运行；flutter_tester 离线
  探针实测**异步 dart:io IO 会静默死亡**（连 `await File.readAsString()` 都
  不返回），运行时验证只能等环境恢复补跑。已实测记录：探针编译 0 error。
- ⏳ 真机走查：BPM 背景 / 主页卡片 / 详情窗抓取横幅 / 深浅主题。

## 6. 遗留 / 后续

- P1：环境恢复后补跑 `flutter test test/services/game_banner_cover_test.dart`。
- P2：存量游戏横幅回填（参照 CompanyLogoService.autoFetchMissingLogos 的
  后台自动补齐模式，负缓存防限流）。
- P2：下载/解压安装链接入横幅（依赖云端资源记录增加横幅字段）。
- P3：BPM 库页卡片横幅展示；主页卡片 3:2 比例按观感调参。


---

## §7 封面管理浮层（2026-10-04 深夜，LunaBox 风格参照）

**入口**：详情窗封面上的相册小按钮（查看态右下角 / 编辑态右上角）。

**交互**（开发者提供的 LunaBox 截图为基准）：
- 全屏磨砂遮罩（深浅主题自适应），图片直接浮在其上；单击空白/Esc 关闭
- 图片**可自由拖拽**（InteractiveViewer + 无边界 margin）——与截图查看器的
  核心差异，趣味性/观赏性
- 缩放按钮仅预览用途（TransformationController 中心锚点缩放 0.5–5.0，
  双击复位），不动真实文件
- 底部胶囊工具条：浏览组（缩小/放大/下一张/上传）+ 编辑组（设为竖屏封面/
  设为横幅封面/删除/抓取），忙碌态转圈、禁用态置灰

**数据面**（`game_data_format.dart`）：
- `listCoverGallery(dir)`：canonical 竖封面（cover_file→cover.*）→ 横幅
  （banner_file→banner.*）→ `covers/` 子目录自定义图（排序、去重、滤非图片）
- `coversDirName = 'covers'`（护栏：改名会破坏删除前缀守卫，有测试钉住）

**操作语义**（`game_detail_dialog.dart`）：
| 操作 | 实现 |
|---|---|
| 上传 | file_picker 多选 → 复制为 `covers/custom_<stamp>_<i>.{ext}`（对齐 screenshots/ 先例，无 json 写入） |
| 设为竖屏封面 | 复制为 `cover.{ext}` + updateGameJson('cover_file') + registry.coverUrl + 缓存失效 + 广播（复用 _downloadCoverFromUrl 同步链） |
| 设为横幅封面 | 复制为 `banner.{ext}` + updateGameJson('banner_file') + registry.bannerUrl + 广播 |
| 删除 | 仅 `covers/` 前缀 + `PathHelper.isInsideAppStorage` 双守卫；canonical 图不可删（置灰，可被替换） |
| 抓取 | 先关浮层 → 查看态自动 `_enterEditMode()` → `_fetchMetadata()`（结果面板只在编辑态渲染 :2207） |

**护栏**：IMP-05 沿用——元数据目录在应用存储外时，「设为」不覆盖既有
cover.*/banner.*，改时间戳替代名（护数据，不拦意图）。

**设计理由（为什么不用 game.json 存封面列表）**：covers/ 目录即真相，
零 schema 变更、零迁移；canonical 竖/横封面保持单字段语义，BPM/主页/
库页所有既有读取路径零改动。

**遗留**：P2 BPM 侧上传/管理入口（BPM 结构不变量约束，待开发者确认）；
P2 存量横幅回填；⏳ 真机走查。

**测试**：`test/services/cover_gallery_test.dart` 4 例（顺序/身份标记、
json 指定名优先、空目录、coversDirName 护栏）——**4/4 PASS**。


---

## §8 横幅抓取全链路加固 + 相册交互改版 + 添加页相册（2026-10-05）

### 8.1 横幅抓取修复（P0）

**症状**：① 部分游戏未抓取到横幅；② KunGal 抓成音乐盘图。

**根因与修复**（四环节）：

| 环节 | 根因 | 修复 |
|---|---|---|
| Hikarinagi | covers[] 一直在响应里但从未解析横幅（只按 votes 选竖封面） | _parseDetail 接入横版挑选（与 NextMoe 同口径） |
| NextMoe | 缺宽高元数据的真横幅被直接跳过 | 两轮策略：无已确认横版时回退「无尺寸候选」 |
| MIX 链 | kun 论坛头图混入音乐盘图 | banner_url 链 nextmoe→hikarinagi→kun 链尾 |
| 下载侧 | 源数据无尺寸校验，假横幅直落盘 | downloadCover(minAspectRatio) / downloadBanner：解码校验 ≥1.15，不达标删文件拒收（缓存+网络两路径） |

**平台名确认**：开发者口述「EXTeMOE」与六源显示名均对不上。按 LunaBox 血统
（hikarinagi 注释标注「参考 LunaBox metadata_hikarinagi.go」）与数据形态判定为
**Hikarinagi**；若实指其他平台，需补接该源。

### 8.2 相册浮层交互改版（详情窗）

- 图片区 Positioned.fill **全窗口**自由拖动（取消上下边框遮挡，顶栏/工具条浮于图上）
- 第三按钮「下一张」→「恢复初始居中」；新增上一张/下一张按钮（←/→ 键同步）
- **抓取入口移除（纯相册）**：onFetch 回调链全清；抓取走详情窗编辑态

### 8.3 添加页相册系统

- metadata_section.dart 头部「相册 N」入口（N = 选中结果竖版+横幅计数，0 张禁用）
- 新组件 cover_preview_overlay.dart：磨砂全屏 + 竖/横切换 + 拖拽缩放 +
  网络图预览（NsfwImage.network + CachedNetworkImage，对齐卡片模式）
- 双类型抓取：抓取链已同时输出 cover_url + banner_url（§6 MIX 链），无需新增

### 8.4 验证

- ✅ flutter analyze 9 改动文件 0 error
- ⏳ flutter test 被阵发 231 拦死（两轮退避重试均 231）；本轮未动
  listCoverGallery 等既有测试覆盖的 API
- ⏳ 未真机走查


---

## §9 探索库云端横幅封面（2026-10-05，games.bannerUrl）

### 9.1 云端 schema

线上 PB `games` 集合新增 `bannerUrl` file 字段（id file3258191437）：
maxSelect=1、maxSize 5MB、mime png/jpeg/webp/gif——镜像 `coverUrl` 定义。
文件 URL 与封面同构：`{pb}/api/files/games/{id}/{filename}`（games 列表
规则公开 → 匿名可读）。hook 锁字段（review_status/origin/has_official/
contributors/like_count）不含 bannerUrl。

### 9.2 Dart 数据面（8 文件）

| 环节 | 改动 |
|---|---|
| 模型 | `GameModel.bannerUrl` + `_extractBannerUrl`（缺字段安全回退空串） |
| 发布 | `publishGame`/`updateMyGame` 加 `bannerFilePath`；create 复用 multipart `_createWithFiles`，update 新增 `_updateWithFiles`（multipart PATCH） |
| 发布窗 | `publish_game_dialog` 横幅选择卡（全宽 88 高、可选、可删；编辑模式不重选即保留线上原横幅） |
| 下载同步 | 详情页 → CloudInstallFlow.submit(bannerUrl:) → InstallTask.bannerUrl → GlobalInstallCenter → DownloadCore._gameBannerUrl → ExtractManager(gameBannerUrl) → _writeGameInfo → `writeGameDir(bannerUrl:)` 落本地 `banner_file` |

下载链横幅**完全跟随封面同路径**；计划窗延迟入库路径与封面行为一致。

### 9.3 全量回填（dev_probe/backfill_banner_cloud.py）

流程：拉全量 → NextMoe 搜索（originalTitle→title→englishTitle，弱匹配
宁缺毋滥）→ covers[] 两轮横幅挑选（与 SDK 同口径）→ 下载 + PIL 裁决
（宽高比 ≥1.15、宽 ≥480、拒 gif）→ multipart PATCH 上传。断点续传 +
429 退避 + dry-run/live 两档（dry 结果可直接转 live 上传）。

**结果**：300 条 → dry-run 命中 159 → live 上传 **159/159 零失败**；
云端复核 159 条带 bannerUrl、匿名访问 200。141 条无候选（NextMoe 单源
覆盖限制）。

**🔴 环境事实**：NextMoe WAF 拦 urllib 默认 UA（403），伪装 curl UA 可过；
TouchGal（developer.touchgal.com）与 Hikarinagi（*.hikarinagi.org）本机直连
TLS 被重置——脚本支持 `--proxy http://127.0.0.1:PORT` 带代理重跑，可扩大
覆盖（TouchGal 详情有 bannerUrl 字段，值得补跑）。

### 9.4 验证

- ✅ flutter analyze 8 改动文件 0 error（新增行无 issue）
- ✅ 云端复核 159 条 + 匿名文件访问 200
- ⏳ 未真机走查：下载一部带横幅作品 → 本地 BPM/主页大图直接显示横幅


---

## §10 主页封面卡回退竖版（2026-10-09，用户真机反馈）

**用户口径**：主页横幅适配保持不变的整体设计，**仅**做到——「左侧游戏面板的
**背景**用横幅（类似 BPM），左下角**封面卡**用竖版封面，其他不变」。

**审计结论（阶段 A）**：现状（commit `446074d`）中
- `_buildBlurredBackground`（`home_page.dart:488`）**已经是**「横幅优先 → 无横幅回退
  竖封面」⇒ 符合口径，**不动**；
- `_buildCoverCard`（`home_page.dart:754`）**有横幅时把卡片切成横版 3:2（180×120）
  并显示横幅** ⇒ 与口径不符，本次唯一改动点。

**改动（最小变更，`lib/pages/home_page.dart` 单文件，+7/-11）**：
- 删除 `_buildCoverCard` 内的 `useBanner` 分支；卡片高度恒 `180 × 4/3 = 240`（3:4）；
  图片源恒 `_buildCoverImage`（竖封面），`isBlurred`（NSFW 模糊）逻辑不变。
- `_buildBannerImage` / `_hasBanner` / `_bannerPathCache` **全部保留**——仍服务于
  背景层与路径缓存，无死代码。
- 与 BPM 一致：**背景=横幅、卡片=竖封面**。主页整体设计（模糊背景层、封面卡边框/
  阴影/圆角、其余布局）零改动；卡片恒 240 高即回到横幅功能引入前的原始观感。

**验证**：
- ⚠️ `flutter analyze` / `flutter test` 本机复现 **231**（ERROR_PIPE_BUSY，
  C 盘 12G / D 盘 20G 空闲，与磁盘无关）→ 走进程内分析器降级通道：
  `lib/pages/home_page.dart` **errors=0 / warnings=0 / infos=0**。
- ✅ `git diff --stat`：仅 `home_page.dart` 7 增 11 删，改动面与计划一致。
- ⏳ **未真机走查**（231 下无法构建/渲染）：待确认「有横幅的游戏 → 背景显示横幅、
  左下卡片显示竖封面」。`flutter test` 恢复后补跑。

**为什么不做大改**：横幅是横版、封面是竖版，以「背景层铺满（裁切可接受）」承接
横幅、「卡片按原比例完整呈现」承接竖封面，是零新增布局风险的最小解；用户明确
「整体设计不变」，故不引入新的横幅展示位。

---

## 7. 单游戏手动导入链横幅丢失修复（2026-10-10）

**现象**（用户实机）：添加页导入（CT 数据）**导入前**抓取结果卡显示 2 张图
（竖封面 + 横幅封面），**入库后**只剩 1 张竖封面 → 横版封面未落盘。

**根因**：`GameDataFormat.writeGameDir` 早已支持 `bannerUrl`（下载 + 宽高比校验，
见 §3），批量导入 / 智能导入也已透传；**唯独单游戏手动导入链漏传**：
- `JoinController.startExtractFlow` 构造 `InstallTask` 时未传 `bannerUrl`；
- `JoinController.createStandardGameDirectory` / `writeStandardGameInfo`
  调 `writeGameDir` 时未传 `bannerUrl`。

**修法**（3 处，最小改动，`join_controller.dart`）：
```dart
// startExtractFlow → InstallTask(...)
bannerUrl: selected?['banner_url']?.toString(),
// createStandardGameDirectory / writeStandardGameInfo → writeGameDir(...)
bannerUrl: _selectedResult?['banner_url']?.toString(),
```
`_selectedResult['banner_url']` 源自 CT 记录 `bannerUrl`（`importFromCtLibrary`
已透传，`GameModel.bannerUrl`）或抓取结果 `banner_url`。

**明确不改**：横幅下载/校验逻辑、`listCoverGallery`、主页/BPM 显示。

**验证**：`flutter analyze` 改动文件 0 新增；⏳ 待真机走查——CT 数据导入后
`game.json` 的 `banner_file` 非空、`listCoverGallery` 返回 2 张。
