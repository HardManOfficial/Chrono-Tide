# 探索库资源来源扩展 — 开发方案

> **状态**：**🏆 全案收官（2026-10-01 深夜）**——Phase 1 终验 ✅ / Phase 2 服务端验收（v6）✅ / Phase 3 上线验收（v7 探针 22/22）✅ / v8 署名修复上线验收（探针 12/12）✅ / 真机走查通过（开发者实测确认）✅。**产品决策：BPM 大屏模式整体走本地、纯沉浸式游玩，不做云端功能（含探索页界面）⇒ 原 BPM 探索页直链 P0 作废**　**版本**：v4.9
> **日期**：2026-09-29（v4.2 修订 2026-10-01）　**适用目录**：`D:\CTLIB`
> **前置阅读**：`AGENTS.md`、`DECISIONS.md`（ADR-011 游戏身份）
>
> **版本演进**：
> - v1 `user_share_upload_plan.md` —— 独立分表 `shared_games`（**数据结构部分已作废**）
> - v2 `explore_resource_sources_plan.md` —— 统一作品 + 多来源
> - v3 —— 纳入四点确认意见，修正 v2 的 6 处逻辑冲突
> - v4 —— ①三项配置拍板定值（可见性 B / 开放范围全量 / 分享者权益暂不实现）
>   ②来源展示需求落地到字段与文案　③新增《开发前置准备清单》（§12）
> - **v4.2（2026-10-01）** —— **详情页 UI 重设计落地**：①新增 4 个固定深色弹窗
>   （获取 / 分享 / 分享详情 / 上传），安装入口从右列大按钮移入「获取」弹窗；
>   ②`game_resources` 扩表 **21→27 字段**；③看板娘「时之 汐乃」建成（§2.4.1）；
>   ④**§6.4.2 的「左列追加 `CommunitySourcesSection`」已被新设计取代**（见该节横幅）；
>   ⑤§6.1 卡片角标已接线。明细见 **§8.2**。
> - **v4.3（2026-10-01）** —— ①新增 **§8.5《浮层兜底清扫清单》**（P0，承接真机走查
>   「标线不止 3 个窗口」；根因已定位为 `MaterialApp._errorTextStyle` 兜底样式，
>   修复 commit `0c00ad2`）；②新增 **§8.6《Phase 2 变更计划》**（阶段 A 只读审计产出，
>   **待批准**）；③§8.2-⑥ 待办的 Phase 2 缺口已精确到文件与行号（见 §8.6-①）。
> - **v4.4（2026-10-01 下午）** —— **纳入开发者补充需求：用户上传分「上传 / 发布」两类**。
>   ①新增 **§8.7【发布】链路设计**（文档板块内三步：游戏名判重 → 发布 Galgame 窗口 →
>   资源上传）；②新增 **§8.8【我的】管理页**（我发布的游戏 + 我上传的资源，两分区）；
>   ③新增 **§8.9 服务端增量清单**（新增 `traditionalChineseTitle`；`downloadUrl` 改非必需；
>   `lock_fields` 扩展）—— 🔴 **关键好消息：`games.createRule/updateRule/deleteRule`
>   早已按「用户发布」写好，无需改动**；④新增 **§8.10 实施顺序与决策点**（累计 5 项待决）。
> - **v4.5（2026-10-01 下午）** —— **开发者答复「批准 1、2、5 + 同一窗口分页」后一次性落地**。
>   ①**服务端**：`games` 27 → **28 字段**（新增 `traditionalChineseTitle`）+
>   `downloadUrl.required` 改 `false`（已执行，既有 298 条零变化）；
>   ②**浮层清扫**：`animated_overlay.dart` 一处兜底 8 个浮层（`bd1673d`），
>   §8.5② 的 19 处经精确核查**全部安全、无需补 ⇒ 本节收口**；
>   ③**【发布】三步链路 +【我的】管理页**实施完毕（`21f54cf` / `f7a99dd`），
>   第 2/3 步为**同一窗口分页**；④🔴 修一个本轮自引入的**标签行溢出回归**
>   （4 → 6 个标签在 960×540 下必溢出，改 `Wrap` + 补回归用例）。
>   明细见 **§8.12**。仍未做：统计路由 · 编辑已驳回投稿的状态复位 · Phase 3。
> - **v4.6（2026-10-01 傍晚）** —— 🔴 **开发者真机反馈「文档板块彻底崩坏」后的修复与推进**。
>   ①**修复崩坏**（`c867cb8`）：根因是我在 v4.5 把标签行 `Row` → `Wrap`，而子项
>   `InteractiveWrapper` 的 `AnimatedContainer` 带 `alignment`，在 `Wrap` 的**有界松约束**
>   下被撑满整行（`Row` 安全是因传 `maxWidth: ∞`）⇒ 6 个标签各占一行竖排、撑爆内容区。
>   修法：4 个胶囊组件内部包 `IntrinsicWidth`（tight 宽度 = 内容宽）。此坑项目内**早有
>   明文注释**（`game_detail/upload_resource_dialog.dart:627-630`），属**已知约定被漏用**；
>   并补「标签宽度哨兵」回归断言（<120px）。
>   ②**【发布】交互对齐开发者澄清**：判重**未命中不再自动弹窗**（改为面板内「继续发布」入口，
>   点击才弹）；判重**命中**时点「前往上传资源」→ 进该作品详情页**并自动弹出【上传】窗口**
>   （走 `GameDetailPage.pendingAutoUploadGameId` 一次性静态信号，**零稳定区改动**）。
>   ③**A 方案落地**（客户端 `1c83f2e` + 服务端 `c27a113`）：`lock_fields` 升 **v5**，
>   只放行**唯一白名单转换** `owner 本人 && rejected → pending`（fail-closed）；
>   客户端 `updateMine` 增 `resubmit` 具名参数**显式发送**该转换
>   （⚠️ `toSubmitBody()` 本身不含 `status`，不显式发则白名单永不触发）。
>   ④**统计路由开发**：新建 `resource_stats.pb.js`（`download` / `like` / `unlike` 三路由，
>   `$apis.requireAuth()`）+ 新建 **`resource_likes` 集合**（`pbc_1167737304`，唯一索引
>   `(resource,user)` 去重，5 条规则全锁死）+ 客户端接线
>   （`setLike` 乐观更新失败回滚 / `registerDownload` 打点 / `fetchMyLikedResourceIds` 回显）。
>   ⑤🔴 **`pb_hooks/` 首次纳入版本控制**（此前从未提交 ⇒ 服务端 hook 无历史、回滚无据）。
>   明细见 **§8.13**。仍未做：Phase 3（`contributors` / 举报）。
> - **v4.7（2026-10-01 深夜）** —— ①**统计路由五轮失败根因定案 + 修复**：真凶 =
>   **goja 顶层 `const` 在回调执行时不可见**（v1~v5 每版必炸），v6 零顶层声明全内联，
>   本地开发实例 26/26 → **线上探针全绿**（见 §8.14）⇒ Phase 2 服务端收官。
>   ②**本地 PocketBase 开发实例工作流上线**（`.workbuddy/pb_dev/`）：
>   部署-测试循环内化，开发者只部署「本地全绿」的定版包。
>   ③**Phase 3 按 §13.1 计划实施完毕**：`promote_contributors.pb.js`（转正归属自动写入）
>   + `resource_report.pb.js`（举报路由，`resource_reports` 集合**懒创建**）+
>   客户端 `reportResource` / 分享详情「报告失效」接线；本地实例 **23/23 全绿**、
>   analyzer errors=0（见 §13.2）。
>   明细见 **§8.14 / §13.1 / §13.2**。✅ 已全部完成：v7 线上验收 22/22 · v8 署名修复 12/12 · 真机走查通过 —— **全案收官**。

---

## 0. 结论先行

| 项 | 结论 |
|---|---|
| 核心模型 | **作品（Game）+ 资源来源（Resource Source）= 1:N**；来源分 `official` / `community` |
| 数据落点 | `games` 表**仍是作品主表**（+7 字段），新增 **`game_resources`** 一张来源表 |
| 作品层级 | 用户作品与预设作品**同级同权**（同一 `games` 表、同一探索库、同一详情页） |
| **可见性（已拍板）** | **方案 B**，拆分后取 **B1（`List/View` 放宽为 `\|\| review_status="approved"`）** —— 详见 §4.2.1 |
| **用户上传（v4.4 扩充）** | **分两类**：作品**已存在** → 【上传】只写 `game_resources`；作品**不存在** → 【发布】先写 `games` 再写 `game_resources`（§8.7） |
| **开放范围（已拍板）** | **全量**：`link_type` 含 `netdisk`/`direct`/`other` 全开，后台可随时收回 |
| **分享者权益（已拍板）** | **暂不实现**，仅保留 `contributors` 数据结构作为能力预留 |
| 审核 | **管理员（你本人）在 PB 后台手工完成**，无自动审核流程 |
| 来源共存 | 官方与用户来源**长期共存、互不排斥**；补官方**不得**隐藏或删除已有用户分享 |
| 归属保留 | 作品"转正"后**必须保留原分享者归属信息**（§5.3） |
| **来源展示（v4 新增）** | 个人分享的**每条来源**必须标注**提供者 + 上传时间**（§6.4） |
| 环境实况 | PB **0.34.2** / `pb_hooks` **可用** / `game_resources`、`app_config` **尚不存在** |
| 🔴 已确认的既有漏洞 | **`games` 匿名可写**（Create/Update/Delete 三栏为空，实测 `POST {}` 返回 400 而非 403）——本任务上线前**必须**修复（§3.1③ / §3.2.4） |

> 🟢 **实测带来的三个好消息**：
> ① PB 0.34.2 → **Hook 机制可用**，防提权有保障，无需降级；
> ② `users` 匿名可读（180 条）→ 显示"提供者昵称"**无需 expand 权限**，`owner_name` 冗余方案成立；
> ③ `game_resources`/`app_config` 不存在（404）→ 可安全新建。
>
> 🔴 **一个已确认的严重问题（P0）**：`games` 的 **Create/Update/Delete 三栏规则为空**，
> 实测证实**匿名可写**（返回 400 字段校验失败，而非 403 无权限）。
> **本功能上线必然暴露该接口**，因此 §3.2 的规则变更**不是可选项，而是前置条件**。
> 详见 §3.1③ 与 §3.2.4。

---

## 1. 三项配置的最终定义（v4 核心变化）

你已对方案里的三个可配置项拍板。本节是它们的**唯一权威定义**，后文一律以此为准。

### 1.1 配置项一览

| # | 配置项 | 取值（v4 定值） | 默认值 | 影响面 | 后续扩展位 |
|---|---|---|---|---|---|
| 1 | **作品可见性** | **B — 只读开放，写入需登录** | **B** | PB `games` 规则、用户未登录体验 | 可升 A（全站需登录）/ 降 C（折中） |
| 2 | **指令类型开放范围** | **全量**（`netdisk`+`direct`+`other`） | **全量** | PB `game_resources.link_type` Values、上传表单类型选项 | 可删 Values 中任一项即时收回 |
| 3 | **转正后分享者权益** | **暂不实现**（仅保留数据结构） | **不实现** | 无运行时影响 | `contributors` 已预留，可升级为贡献榜 |

### 1.2 配置 1：作品可见性的三个选项（**已选 B**）

| 方案 | `games` 规则 | 未登录体验 | 代价 |
|---|---|---|---|
| A. 全站需登录 | 收紧为需认证 | 探索库**完全不可用** | 🔴 需改 §7.2 的 4 处调用点 |
| **B. 只读开放（✅ 已选）** | **保持公开可读** | **可正常浏览**，仅上传/分享时引导登录 | 🟢 **零回归** |
| C. 折中 | 公开可读，但用户投稿作品需登录可见 | 预设作品可浏览 | 🟡 规则复杂度上升 |

**选 B 的直接结果**：

- `games` 的 List/View 规则**维持现状不改** → 探索库、BPM 探索页、月历、详情页**全部零改动**；
- 登录门槛**只落在 `game_resources` 的 Create/Update/Delete**（见 §3.3）；
- 未登录用户点「分享资源」按钮 → 弹登录引导，而不是整页报错。

> 📌 **扩展位（保留升级路径）**：若将来要改为 A，只需在 PB 后台把 §3.2 的 View 规则
> 加一行 `@request.auth.id != ""`，并**同时**完成 §7.2 的 4 处前端 403 兜底。
> 本方案不预先实现这些兜底——因为选 B 后再加反而是"未使用代码"，违反最小变更原则。

### 1.3 配置 2：指令类型开放范围 = **全量**

```jsonc
// PB game_resources.link_type 字段的 Values（v4 定值）
["netdisk", "direct", "other"]
```

| 层级 | 位置 | 作用 | 改动方式 |
|---|---|---|---|
| ① 客户端展示 | 新建集合 `app_config`（单记录）字段 `allowed_link_types` | 客户端**动态渲染**上传表单的类型选项，避免硬编码 | 改单条记录 |
| ② 服务端约束 | Admin UI → `game_resources` → `link_type` → **Values** | **真正生效**的白名单 | 改字段定义 |

**运营方式（无需改代码、无需重新发版）**：

- 想临时关闭直链 → Admin UI 把 `direct` 从 Values 删掉（已存在记录不受影响，仅新提交受限）；
- 想彻底关闭某个类型 → 同时从 `app_config.allowed_link_types` 移除（前端立即不显示该选项）。

> ⚠️ **`direct` 的固有风险（已确认接受）**：直链可指向任意文件（含可执行文件），是恶意内容主要入口。
> 本方案按你的决定**不设代码级拦截**，把关完全落在后台人工审核。建议审核 `direct` 时**重点核对
> 域名与文件扩展名**；一旦发现问题，删 Values 即可零代码止损。

### 1.4 配置 3：转正后分享者权益 = **暂不实现**

**当前阶段对作品只做"预设处理"**，含义明确为：

| 会做的 | 不会做的 |
|---|---|
| 管理员补官方来源后，**原社区来源记录一条不动** | ❌ 不发称号、不发积分、不做等级 |
| `contributors` 字段**照常写入并长期保留** | ❌ 不做「贡献榜」页面 |
| 详情页归属区**只做静默/轻量展示**（§5.3） | ❌ 不做用户侧可见的权益标识 |
| 数据层保留 `resources` 关联 | ❌ 不做按用户聚合查询接口 |

> 📌 **扩展位**：将来要启用权益，**数据已就绪**，只需新增读取 `contributors` 的展示页面，
> **无需任何数据迁移**。这是当前"只写不显"设计的价值所在。

---

## 2. 结构设计

### 2.1 实体关系

```
                    ┌──────────────────────────────┐
                    │  games（作品，唯一定义）        │
                    │  title / 会社 / 简介 / 封面    │
                    │  origin: official|user        │  ← 仅用于展示与归属，不用于权限
                    │  contributors: 分享者归属信息   │  ← 长期保留，v4 暂不展示权益
                    └──────────────┬───────────────┘
                                   │ 1
                                   │ N
                    ┌──────────────▼───────────────┐
                    │  game_resources（资源来源）     │
                    │  kind: official | community   │
                    │  owner / owner_name           │  ← v4：来源展示的数据源
                    │  created（PB 内置）             │  ← v4：上传时间的数据源
                    │  OpenList 路径  或  外链        │
                    └──────────────────────────────┘
```

### 2.2 为什么坚持"作品单表 + 来源分表"

| 设计 | 理由 |
|---|---|
| 作品仍存 `games` | 探索库/搜索/标签/会社/排序/详情页**零改动**继续工作；用户作品自然进同一网格 |
| 来源独立成表 | 一作品挂 N 来源（换版本、多网盘、官方+用户并存）；字段语义清晰（路径 vs 外链） |
| `games.downloadUrl` 保留 | 向后兼容的"官方主来源"缓存；也是 §5.3 升级路径的落点，避免大规模数据迁移 |
| 来源带 `kind` | 官方的**点击行为**与用户不同（安装 vs 跳转），必须可区分 |
| 来源带 `owner`/`created` | **v4 来源展示需求的数据基础**——不额外建表即可标注"谁在何时分享" |

> ⚠️ **注意区分两个概念**：
> - `kind` 区分的是**获取方式**（可安装 / 只能跳转）——**必须保留**；
> - `origin` 区分的是**投稿来源**（管理员上传 / 用户投稿）——**仅用于展示与归属**，
>   **不参与任何权限判断**（"同级同权"的技术落实）。

### 2.3 `games` 表新增字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `origin` | select | `official`（默认，管理员上传）/ `user`（用户投稿）。**仅展示用途** |
| `owner` | relation(users) | 用户投稿作品的首位投稿人；预设作品为空 |
| `creator_name` | text | 冗余昵称，列表展示免 expand |
| `contributors` | json | **分享者归属清单**（§5.3），转正后长期保留；**v4 暂不对外展示权益** |
| `review_status` | select | `approved`（默认）/ `pending` / `rejected`。**审核状态，由管理员手改** |
| `has_official` | bool | 是否存在官方来源（冗余，列表快速判断"可安装"角标） |
| `community_count` | number | 用户分享来源数量（冗余，避免列表页 N+1） |

> **向后兼容**：既有记录 `origin` 自动 `official`、`review_status` 自动 `approved`，
> 行为与改造前完全一致。

### 2.4 `game_resources` 表

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `game` | relation(games) | ✅ | `maxSelect:1, cascadeDelete:true` |
| `kind` | select | ✅ | `official` / `community` |
| `title` | text | ✅ | 来源名称（"百度网盘 · 汉化版"） |
| **official 专用** | | | |
| `download_path` | text | | OpenList 网盘**路径**（`kind=official` 必填） |
| `version` / `version_note` | text | | 版本名 / 说明 |
| **community 专用** | | | |
| `url` | url | | 外链（`kind=community` 必填） |
| `link_type` | select | | `netdisk` / **`direct`** / `other`（**全量开放**，§1.3） |
| `netdisk_provider` | select | | `baidu`/`quark`/`aliyun`/`xunlei`/`115`/`onedrive`/`mega`/`google_drive`/`other` |
| `extract_code` | text | | 提取码 |
| `file_size` | text | | 体积描述 |
| **官方 / 用户共用（v4 UI 复刻新增，2026-10-01 已上表）** | | | |
| `resource_type` | select（多选） | | 资源类型：`游戏本体`/`民间汉化`/`官方中文`/`全年龄补丁`/`修正补丁`/`特典`/`音声·音乐`/`CG·素材`/`攻略·手册`/`其他` |
| `languages` | select（多选） | | 语言：`简体中文`/`繁體中文`/`日本語`/`English`/`한국어`/`Tiếng Việt`/`其他` |
| `platforms` | select（多选） | | 平台：`Windows`/`Android`/`macOS`/`Linux`/`iOS`/`其他` |
| `unzip_code` | text（≤120） | | 解压码（与 `extract_code` 提取码**是两个不同字段**） |
| `download_count` | number | | 下载次数（系统累加，Hook 锁定） |
| `like_count` | number | | 点赞数（系统累加，Hook 锁定） |
| **来源展示专用（v4 新增说明）** | | | |
| `owner` | relation(users) | | 上传者——**永久保留**，详情页"提供者"数据源。<br>🔴 **official 资源指向看板娘 `0fw0trcd3dbmqow`（「时之 汐乃」），不再为空**（见下方 §2.4.1） |
| `owner_name` | text | | 冗余昵称，**列表/详情免 expand 直接展示** |
| `source_note` | text | | **来源说明**（v4 扩展位）：如"自购分享""汉化组授权转载" |
| **公共** | | | |
| `note` | text | | 补充说明 |
| `status` | select | ✅ | `pending` / `published` / `rejected` / `hidden` |
| `reject_reason` | text | | 驳回理由 |
| `report_count` | number | | 举报计数（Phase 3） |

> **上传时间不需要新字段**：PocketBase 每张表**内置 `created`**，
> 且是服务端生成、**客户端不可篡改**（写入时由 PB 自动赋值）。
> 详情页直接读 `record.created` 即可，无需新增 `uploaded_at`。
> **这一点很关键**：它让"上传时间"天然可信，不必依赖前端传参。

#### 2.4.1 看板娘「时之 汐乃」（official 默认分享者）

**决策（2026-10-01，替代原稿"official 的 owner 为空"）**：

| 项 | 值 |
|---|---|
| 集合 | `users`（**必须**——`game_resources.owner` 是 relation→users，超管账号无法被引用） |
| id | `0fw0trcd3dbmqow` |
| name | `时之 汐乃`（同时冗余写进 `owner_name`） |
| email | `kanban-shino@chronotide.app`（无实际意义，仅占位） |
| avatar | `kanban_shino_oq9qmeubp0.png`（由 `素材/新建文件夹 (2)/图层 14.png` 裁方 512×512） |
| 建号脚本 | `.workbuddy/pb_tmp/pb_kanban_02_create.py`（幂等，按 email 查重） |
| 回滚 | `.workbuddy/pb_tmp/kanban_manifest.json` → `DELETE /api/collections/_pb_users_auth_/records/0fw0trcd3dbmqow` |

**客户端头像策略（离线优先）**：
- **一律用内置资源 `assets/images/kanban_shino.png`**（与 PB 头像同一张图）；
- **不**在客户端拉 PB 头像，原因：
  ① `users.listRule = id = @request.auth.id` ⟹ 普通用户**查不到看板娘记录**；
  ② PB 上传给文件名加随机后缀，硬编码直链在换头像后**静默失效**。
- 常量集中在 `lib/widgets/game_detail/kanban_identity.dart`
  （`name` / `assetPath` / `pbUserId` / `pbAvatarFile`）。

> 现状（2026-10-01）：`game_resources` 里 **official 记录为 0**（仅有 4 条测试 community），
> 故本次**无需回填**；待第一条 official 落库时，写入方按上表带 `owner`/`owner_name` 即可。

---

## 3. PocketBase 配置

### 3.1 🔴 关键前提修正（2026-09-29 22:1x 拿到规则原文，确认实测推断）

**v3/v4 原文写的是**："`games` 当前的 List/View 规则是公开可读"。**实测与规则原文均证明：错误。**

#### ① 规则原文（开发者从 PB 后台 `API Rules` 抄回，PB 0.34.2）

| 规则栏 | 原文 | 语义 |
|---|---|---|
| **List/Search** | `@request.auth.id != ""` | **仅登录用户可见列表** → 未登录拿到 0 条 |
| **View** | *(空)* | PB 界面提示 "Leave empty to grant everyone access..." |
| Create | *(空)* | 🔴 **空 = 所有人可创建** |
| Update | *(空)* | 🔴 **空 = 所有人可修改** |
| Delete | *(空)* | 🔴 **空 = 所有人可删除** |

#### ② 与实测的互证（四条 `curl` 证据）

```bash
# ① games 匿名列表：200 但 0 条（List 规则过滤掉全部）
$ curl -s ".../api/collections/games/records?perPage=500"
{"items":[],"page":1,"perPage":500,"totalItems":0}      # 后台 UI 显示 298

# ② users 对照：公开可读（180 条）
$ curl -s ".../api/collections/users/records?perPage=1"
{"items":[{...}],"totalItems":180}

# ③ 匿名单条读：404（非 403）——记录被 List 规则筛掉后统一按"不存在"处理
$ curl -s ".../api/collections/games/records/nonexistent123"
{"message":"The requested resource wasn't found.","status":404}
```

> ⚠️ **一处看似矛盾、实为一致**：View 规则为**空（对所有人开放）**，
> 但匿名单条读仍返回 404。原因是 PB 0.23+ 起，
> **`getOne` 会先过 View 规则、再校验该记录是否落在 List 规则的可见范围内**；
> 未登录时 List 规则筛掉全部记录 → 单条读也按 404 返回。
> **List 规则实质上决定了未登录能看到什么**，View 规则为空的"开放"被 List 覆盖。
>
> 📌 **实践含义**：**只需改 List 规则**即可控制未登录可见性；View 建议同步填上
> （见 §3.2），避免"看起来开放实际受限"的语义混乱。

#### ③ 🔴 新发现（P0）：`games` 当前**匿名可写**

```bash
$ curl -X POST ".../api/collections/games/records" -H "Content-Type: application/json" -d '{}'
{"data":{"downloadUrl":{"code":"validation_required","message":"Cannot be blank."},
         "title":{"code":"validation_required","message":"Cannot be blank."}},
 "message":"Failed to create record.","status":400}
```

**判定依据**：返回 **HTTP 400（字段校验失败）而非 403（无权限）** →
说明请求**已被规则放行、进入了业务校验层**。若匿名创建被拦，PB 返回 403。

**结论**：`games` 的 **Create / Update / Delete 三栏为空 = 任何人（含未登录）可增删改全部 298 条数据**。

| 项 | 评估 |
|---|---|
| **现状严重性** | 🔴 **P0**——`title`/`downloadUrl` 为必填，攻击者填入这两个字段即可污染数据；同样可删除任意记录 |
| **为何尚未出事** | 大概率仅因"接口地址未公开"，**不是因为有防护** |
| **与本任务的关系** | 🔴 **强相关**——本功能必然要让客户端调用该接口，**App 一旦发布，地址不再保密，漏洞会立刻可利用** |
| **修复成本** | **零**——第 4 步填规则时顺手补上（§3.2） |

> ⚠️ **声明**：本次仅做**只读探测**（`POST {}` 空体、`DELETE` 不存在 id），
> **未写入、未修改、未删除任何真实数据**。上述 400 响应不会产生记录。

> 🔴 **修正后的准确表述**：`games` **List 要求认证**（未登录看不到任何作品），
> **写入三栏完全开放**（未登录可增删改）。"方案 B（只读开放）"若要实现，
> 需**主动放宽 List 规则**并**同时收紧写入规则**。

**v4 的决策调整**：

| 项 | 原表述（错） | 修正后 |
|---|---|---|
| 现状 | `games` 公开可读 | **List 需登录；写入三栏全开放（可被未登录篡改）** |
| 选 B 的代价 | "零改动" | **必须改规则**——但无论选 B1 还是 B2，**写入三栏都必须补** |
| 可见性选型 | 推荐 B2（零改动） | 🔴 **改为推荐 B1**（理由见 §4.2.1） |

> ✅ **"5 处调用点零改动"的结论仍然成立**（§7.2）：
> 现状已经如此，它们是**存量情况**；且 B1 是"加法"（只让更多数据可见），
> **不会让已登录用户少看任何东西**。

### 3.2 `games` 表规则（**定稿，可直接粘贴**）

> 🔴 **执行顺序不可颠倒**：**必须先完成 §2.3 的 7 个新增字段，再改规则**。
> 因为下方 List/View 规则引用了 `review_status`；字段不存在时 PB 会报
> 规则解析错误，可能使集合进入异常状态。

#### 3.2.1 五栏规则定稿

| 栏位 | 现状 | 定稿（**粘这一行**） |
|---|---|---|
| **List/Search** | `@request.auth.id != ""` | `@request.auth.id != "" \|\| review_status = "approved"` |
| **View** | *(空)* | `@request.auth.id != "" \|\| review_status = "approved"` |
| **Create** | *(空)* 🔴 危险 | `@request.auth.id != "" && @request.data.origin = "user" && @request.data.owner = @request.auth.id && @request.data.review_status = "pending"` |
| **Update** | *(空)* 🔴 危险 | `owner = @request.auth.id && origin = "user" && review_status != "approved"` |
| **Delete** | *(空)* 🔴 危险 | `owner = @request.auth.id && origin = "user"` |

> ⚠️ **上表的 List/View 两行对应「方案 B1（放宽）」**。若你选 **B2（维持现状）**，
> List 保持 `@request.auth.id != ""` 不动、View 留空即可——
> **但 Create/Update/Delete 三栏无论选哪个都必须填**（修补 §3.1③ 的匿名写入漏洞）。
>
> ✅ **本方案推荐 B1**，理由见 §4.2.1。

#### 3.2.2 逐条语义

| 规则 | 语义 | 防的是什么 |
|---|---|---|
| **List/View** | 登录用户看全部（含自己 pending 的投稿）；未登录**只能看 `approved` 的** | 未登录不可见待审内容 |
| **Create** | 必须登录 + 只能建 `user` 来源 + 只能挂自己 + **强制 `pending`** | ① 匿名建记录（修补现漏洞）；② 投稿者直接写 `approved` **自审通过** |
| **Update** | 只能改自己的、只能改 `user` 作品、**已通过的不能再改** | ① 匿名篡改任意记录（修补现漏洞）；② 审核通过后偷换 `downloadUrl`（投毒） |
| **Delete** | 只能删自己的 `user` 作品 | 匿名删除任意记录（修补现漏洞） |

> ⚠️ **与 v2 的差异（保留 v3 修正）**：删去了 v2 里的 `@request.auth.role = "admin"` 分支——
> PB 的 `users` 集合默认**没有** `role` 字段，该写法会**静默失效**。
> 管理员的 Update/Delete 由 **Admin UI 的 superuser 身份**绕过规则，无需在规则里表达。

#### 3.2.3 为什么 List 与 View 都填同一表达式

PB 0.23+ 起，`getOne` **同时受 View 与 List 约束**（详见 §3.1②）。
两栏填同一表达式可消除"View 开放但 List 受限"的语义混乱，
也让"未登录能看到什么"这件事只有一个答案（`review_status = "approved"`），便于排查。

---

### 3.2.4 🔴 附带修复：`games` 匿名写入漏洞（P0）

本次规则变更**不是可选配置**——它同时修复 §3.1③ 发现的既有漏洞：

| 漏洞 | 当前后果 | 填入规则后 |
|---|---|---|
| Create 为空 | 任何人可创建作品记录（污染探索库） | 仅登录用户可建，且强制 `pending` |
| Update 为空 | 任何人可篡改 298 条作品的标题/下载路径 | 仅作者可改未通过的自己的作品 |
| Delete 为空 | 任何人可删除全部作品数据 | 仅作者可删自己的 |

> 📌 **必须写进交付说明**：这不是"顺手优化"，而是**本功能上线的前置条件**——
> 一旦客户端开始调用 `games` 接口，地址就不再保密，漏洞会立刻可被利用。

---

### 3.2.5 备份要求（改规则前必做）

| 集合 | 状态 |
|---|---|
| `users` | ✅ 已由 AI 通过只读 API 导出 180 条 → `.workbuddy/pb_backup/users_anon.json`（不含邮箱等敏感字段） |
| `games` | ⚠️ **无法代导出**（List 规则限制，匿名读 0 条）→ **必须由开发者后台 Export** |

**操作**：PB 后台 → `games` → 右上 `⋯` → `Export`（或 Settings → Export collections 勾选 `games`）。

> 💡 **Settings → Export collections 更好**：它导出的是**集合定义（含规则原文）**，
> 既完成备份，又能留档"改规则前的原始状态"，便于回滚。

### 3.3 `game_resources` 表规则（**登录门槛只在这里**）

```
List/Search : kind = "official"
              || (kind = "community" && status = "published")
              || owner = @request.auth.id
View        : 同上
Create      : @request.auth.id != ""
              && @request.data.kind = "community"
              && @request.data.owner = @request.auth.id
              && @request.data.status = "pending"
Update      : owner = @request.auth.id && kind = "community" && status != "published"
Delete      : owner = @request.auth.id && kind = "community"
```

> **读公开、写需登录**：List/View **不要求认证**（未登录也能看到已发布的用户分享，
> 与作品可见性一致）；Create/Update/Delete **强制 `@request.auth.id`** → 未登录必然被拦。
>
> **权限级保证**：规则**不允许**任何登录用户创建 `kind = "official"` 的来源。
> 官方来源只能由管理员（superuser）在后台创建 —— 这是"官方/用户"分野的硬边界。

### 3.4 审核流程（纯后台手工）

```
用户提交 → status = pending（前端不可见给他人）
              │
              │  你（管理员）在 PB Admin UI：
              │   · 打开 game_resources / games 集合
              │   · 核对内容（含 direct 链接风险）
              │   · 改 status → published  或  rejected + 填 reject_reason
              ▼
        全站可见 / 退回（提交者可见驳回理由）
```

**方案不包含**：自动审核规则、审核页面、审核队列 UI、通知系统。
**字段与规则已为其预留**（若将来要加审核页，只需新增一个读取 `pending` 的管理界面）。

### 3.5 服务端 Hook（防状态自审）

```js
onRecordUpdateRequest((e) => {
  const c = e.collection.name;
  const orig = e.record.original();
  if (c === "games") {
    e.record.set("origin", orig.getString("origin"));
    e.record.set("review_status", orig.getString("review_status"));
    e.record.set("has_official", orig.getBool("has_official"));
    e.record.set("contributors", orig.get("contributors")); // 防篡改归属
  }
  if (c === "game_resources") {
    e.record.set("kind", orig.getString("kind"));
    e.record.set("status", orig.getString("status"));
    e.record.set("report_count", orig.getNumber("report_count"));
    e.record.set("owner", orig.getString("owner"));          // 防转嫁归属
    e.record.set("created", orig.getString("created"));       // v4：防篡改上传时间
  }
  e.next();
}, "games", "game_resources");
```

> ⚠️ **v4 新增一行**：锁定 `created`。虽然 PB 默认不允许客户端改 `created`，
> 但显式锁定可确保**"上传时间"在任何情况下都不可伪造**——这正是来源展示可信度的基础。
>
> **降级方案**（若服务器不支持 `pb_hooks`）：接受"用户理论上可自审"的风险，
> 依赖**事后抽查**兜底。**动手前先探版本**：`curl -s http://117.72.115.30:8090/api/health`

---

## 4. 可见性设计（配置项 1 的完整回应）

### 4.1 三个层次必须分清

| 层次 | 内容 | 结论 |
|---|---|---|
| **业务层级** | 用户作品 vs 预设作品 | **同级、同权、无差别**——`origin` 只影响展示文案，不影响任何权限 |
| **获取方式** | 可安装 vs 只能跳转 | **有差别**——由 `kind` 决定，这是功能本质差异，非人为区分 |
| **访问门槛** | 谁能看到探索库 | **方案 B：任何人都能看**，仅写入需登录 |

### 4.2 未登录用户的体验（方案 B 落地后）

> ⚠️ **修正**：v4 初稿曾写"当前未登录可浏览"。**实测为否**——`games` 匿名读 0 条，
> 未登录用户**当前就是看不到探索库的**（详见 §3.1）。因此下表是**方案 B 落地后**的目标态，
> **不是现状**。

| 场景 | 方案 B 落地后 | 当前（实测） |
|---|---|---|
| 浏览探索库 / 搜索 / 筛选 / 排序 | ✅ 可用（仅含 `review_status=approved`） | ⛔ 空列表 |
| 查看作品详情页 | ✅ 可用，含官方「一键安装」 | ⛔ 404 |
| 查看「用户分享」区 | ✅ 可见（`status=published`） | ✅ **可见**（`game_resources` 规则独立，无需登录） |
| 点「打开链接」 | ✅ 可用 | ✅ 可用 |
| 点「分享我的资源」/「上传作品」 | ⛔ 弹登录引导 | ⛔ 弹登录引导 |

> 📌 **注意第 3/4 行**：`game_resources` 的 List/View **不设认证要求**，
> 所以**即使 `games` 保持收紧，用户分享区对未登录用户也是可见的**。
> 这带来一个额外的实现选择（见下方"两种落地方式"）。

#### 4.2.1 两种落地方式（**已定：推荐 B1**）

| 方式 | `games` List/View 规则 | 未登录体验 | 规则改动量 |
|---|---|---|---|
| **B1. 放宽到未登录可浏览**（✅ **推荐**） | `@request.auth.id != "" \|\| review_status = "approved"` | 可浏览已审核作品 | 2 栏（List + View） |
| B2. 维持现状收紧 | List 不动、View 留空 | 探索库空 | 0 栏 |

> ✅ **为什么最终推荐 B1**（拿到规则原文后从 B2 改判）：
>
> 1. **B2 的"零改动"是假象**——§3.1③ 发现 Create/Update/Delete **三栏为空 = 匿名可写**。
>    **无论选哪个，这三栏都必须填**（否则漏洞留着）。既然本就要动这个集合的规则，
>    **再加 2 栏读规则的成本是零**。
> 2. **B1 顺带修复既有缺陷**——未登录用户打开探索库看到空列表且无友好提示
>    （原列为 P2 既有问题）。B1 之后他们能看到已审核作品，**该问题自动消失**。
> 3. **B1 对本次功能是必要的**——若 `games` 读规则维持"需登录"，
>    未登录用户**连用户分享的作品详情页都打不开**，我们花力气做的
>    「来源信息展示」（提供者/时间/说明，§6.4）**将无人可见**。
>
> 🟢 **B1 的风险几乎为零**：`|| review_status = "approved"` 是**纯加法**——
> ① 只会让**更多**数据对未登录可见，**不会让已登录用户少看任何东西**；
> ② 298 条既有记录因 `review_status` 默认 `approved`，**行为完全不变**；
> ③ 待审（`pending`）投稿**依然只有作者本人可见**，不外泄。

### 4.3 前端唯一的新增登录处理（唯一必要改动）

只需在**写入入口**做登录预判，避免用户填完表单才被拒：

```dart
// 伪代码，位于「分享资源」按钮 onTap 首行
if (!PBConfig.isLoggedIn) {          // pb_config.dart:18 已有此 getter
  showLoginGuide();                   // 复用既有登录页/弹窗入口
  return;
}
```

> 📌 这是选 B 后**唯一**涉及"登录态"的前端改动，成本极低，且不影响任何既有读路径。

---

## 5. 流程设计

### 5.1 来源解析流程

```
进入详情页
   │
   ▼
GameRepository.getGameById(id) ──► GameModel（作品信息）
   │
   ├─► GameResourceService.listForGame(id)
   │      ├─ kind=official  → ResolvedSource.official(path, version)   → 走 CloudInstallFlow
   │      └─ kind=community → ResolvedSource.community(url, provider)  → 走 openExternal
   │
   ▼
UI 分层渲染：
   ├─ 存在 official  → 主区域：一键安装（既有行为，零改动）
   │                  ⚠️ 但**不隐藏**下方 community 区
   └─ 存在 community → 下方「用户分享」区，**永远渲染**（有内容时）
```

**硬性约束（v2 的漏洞，已修正）**：

| 场景 | ~~v2 的错误设计~~ | **v3/v4 修正** |
|---|---|---|
| 官方来源存在时 | 用户分享区"降为补充来源"（含糊，可能被理解为隐藏） | **明确定义：完整渲染，仅视觉次位**，条目数一个不少 |
| 作品转正时 | 未说明 community 记录去向 | **强制保留全部 community 记录**，禁止删除/隐藏 |

### 5.2 场景 1：已有预设作品（《命运石之门》）

```
┌──────────────────────────────────────────────┐
│  [封面]  命运石之门                           │
│  ──────────────────────────────────────────  │
│  【内置下载】 ← 主区域，行为完全不变            │
│   版本：Steam 版 v1.0     ≈8.2GB              │
│   [ 一键安装 ]                                │
│  ──────────────────────────────────────────  │
│  【用户分享】 (2)  ← 永远渲染，不因有官方而隐藏  │
│   PS3 版 · 百度网盘    提取码 8x2k  ≈6.4GB     │
│   @某用户 分享于 2026-09-28      [ 打开链接 ↗ ] │
│   ├──────────────────────────────────────────┤│
│   中文版 v1.5 · 夸克网盘  ≈8.1GB               │
│   @另一用户 分享于 2026-09-29    [ 打开链接 ↗ ] │
└──────────────────────────────────────────────┘
```

> 上图中的"`@某用户 分享于 2026-09-28`"即 §6.4 的来源展示，**v4 新增的硬需求**。

### 5.3 场景 2 → 转正：**归属保留机制**

**触发**：你在后台为某个用户作品补 `downloadUrl` / 新建 `kind=official` 来源。

**必须执行的动作（顺序不可颠倒）**：

```
1. 写入 official 来源（新增记录）        ← 是 Add，绝不 Update/Delete 已有记录
2. games.has_official = true             ← 冗余标记
3. games.contributors 追加归属信息         ← 见下
4. ⛔ 禁止：删除/隐藏/替换任何 community 来源记录
5. ⛔ 禁止：修改 games.owner（原首位投稿人）
```

**`contributors` 字段结构**（json，长期保留；**v4 暂不对外展示权益**）：

```json
[
  {
    "user_id": "abc123",
    "user_name": "某用户",
    "role": "first_submitter",
    "contributed_at": "2026-09-29 10:00:00",
    "resources": ["资源记录id1", "资源记录id2"]
  },
  {
    "user_id": "def456",
    "user_name": "另一用户",
    "role": "contributor",
    "contributed_at": "2026-10-01 12:00:00",
    "resources": ["资源记录id3"]
  }
]
```

> ⚠️ **注意 `role` 字段的局限**：这里的 `role` 是**我们自定义的 json 内部字段**，
> 与 PB `users` 集合**无关**（PB 的 users 没有 role 字段，这一点 v3 已澄清）。
> 它只是归属清单里的一个标签值，取值为 `first_submitter` / `contributor`。

**v4 的展示策略（重要变化）**：

| 阶段 | 作品级归属区（contributors） | 来源级展示（owner/created） |
|---|---|---|
| **v4 当前** | **不渲染**（权益暂不实现，避免"荣誉展示≠权益"的语义模糊） | ✅ **必须渲染**（§6.4 硬需求） |
| 将来启用权益 | 渲染"本作品由以下用户贡献过资源" | 不变 |

**为什么 v4 不渲染作品级归属区**：你明确"暂不实现权益"。而作品级贡献墙在无权益体系时，
会让人误以为"贡献有回报"却找不到任何说明——属于**语义债**。数据照常写入，
展示留到权益体系成型时一起做。**来源级展示不受影响**，因为它是"信息透明度"需求，不是"荣誉"需求。

### 5.4 用户提交与审核流程（含指令类型把关）

```
[未登录] → 点「分享资源」→ 登录引导（§4.3）
   │
   ▼
上传表单（三段式）
   ① 选择作品：○ 关联已有作品（搜索）  ○ 创建新作品
   ② 作品信息（仅"创建新作品"）：标题/会社/简介/封面/标签
   ③ 分享资源：链接类型（读 app_config 动态渲染，v4 = 三种全开）
              / 网盘平台 / URL / 提取码 / 体积 / 来源说明(source_note)
   │
   ▼
前端校验（链接合法性 / 必填 / 长度）+ 写入
   · 场景 1：game_resources（kind=community, status=pending）
   · 场景 2：games（origin=user, review_status=pending）
           + game_resources（关联）
   │
   ▼
pending ──►  你在 PB Admin UI 审核
              ├─ netdisk → 核对链接有效性
              ├─ direct  → **重点核对域名与文件类型**
              └─ 改 status → published / rejected
   │
   ▼
published → 全站可见（含未登录用户，方案 B）
```

---

## 6. 页面呈现与状态区分

### 6.1 卡片角标（探索库网格）

> 🔴 **已整体移除（2026-10-23，用户决策）**：开发者认为右上角来源角标「有点多余」——
> 探索库几乎每张卡都有官方来源、恒显「可安装」，没有信息增量，属视觉噪音。
> 现**三种状态全部不再渲染**，卡片右上角永久留空，「已安装」徽章（左上）、
> 发售年份（左下）、评分（右下）保留。
>
> 连带清理（避免死代码）：`_buildSourceBadge()` 函数、`_DiscoverCardWidget.communityCount`
> 字段与构造参数均已删除。⚠️ **数据层未动**：`_communityCounts` / `communityCountBatch`
> 仍服务于顶栏「资源来源 → 个人分享」筛选（`discover_page.dart` 的 `_applyFilters`），
> **不要因为角标没了就删掉这套请求链路**。若日后要恢复角标，需把上面三者加回。

以下为原始设计（**已被移除，勿照此重做**）：

| 作品状态 | 角标 |
|---|---|
| 有官方来源 | `可安装` |
| 仅用户分享 | `用户分享` |
| 两者都有 | `可安装 · N 分享` |

> ✅ **已实现（2026-10-01）**：`lib/pages/discover_page.dart` —— 角标在封面**右上角**
> （与左上「已安装」错角），样式沿用年份/评分角标的半透明深色药丸。
> **判定数据源（与原稿的偏离，重要）**：
> - 「有官方来源」读 `games.has_official`（`GameModel.hasOfficial`，§2.3 的冗余字段，已回填 298 条）；
>   ⛔ 不能用 `downloadUrl` 非空代替（必填，用户作品也非空 → §9.5 已排除）。
> - 「N 分享」**不读 `games.community_count`**（该字段全库恒为 0、未维护，§9 风险 #8）→
>   改为 `GameResourceService.communityCountBatch(gameIds)` 按当前列表**分批现算**，
>   去抖 400ms + 终身缓存（只查未查过的 id），失败静默降级为不显示角标。
> - 待办：`community_count` 在写入链路上的同步维护补齐后，可改回读冗余字段（省一次网络往返）。


### 6.2 详情页状态矩阵

| 官方来源 | 用户来源 | 内置下载区 | 用户分享区 | 作品级归属区(v4) |
|---|---|---|---|---|
| ✅ | 无 | 渲染（一键安装） | 不渲染 | 不渲染 |
| ✅ | ✅ | 渲染 | **渲染（视觉次位，条目不减）** | 不渲染 |
| ❌ | ✅ | **不渲染** | 渲染（主位） | 不渲染 |
| ❌ | 无 | 不渲染 | 渲染空态「暂无可用资源」 | — |

### 6.3 文案规范（强制）

| 场景 | 允许 | 禁止 |
|---|---|---|
| 官方来源按钮 | 一键安装 / 安装 | — |
| 用户来源按钮 | **打开链接** | ❌ 下载 / 安装 / 立即游玩 |
| 用户分享区标题 | 用户分享 / 其他用户分享的资源 | ❌ 下载资源 / 资源库 |
| 外部流程提示 | 「下载、解压、安装均在站外完成」 | — |
| `direct` 类型提示 | 「直链资源，请自行确认文件安全」 | — |

### 6.4 🆕 来源信息展示（v4 核心新增需求）

> **需求原文**：个人用户在资源详情页（即其提交分享链接的详情页）**必须标注资源来源信息**，
> 至少包括**提供者的账号/身份标识**、**上传时间**，并可扩展**资源来源说明**。

#### 6.4.1 字段归属表

| 展示项 | 数据源 | 类型 | 归属层级 | 谁写入 | 可否篡改 |
|---|---|---|---|---|---|
| **提供者账号标识** | `game_resources.owner_name`（显示用）+ `owner`（关系，凭据） | text + relation | **来源级**（每条来源独立） | 客户端写入时取当前登录用户 | ❌ Hook 锁定 |
| **上传时间** | **`game_resources.created`（PB 内置）** | datetime | **来源级** | **PB 服务端自动** | ❌ PB 内置只读 |
| **来源说明**（扩展） | `game_resources.source_note` | text | **来源级** | 提交者自填（可选） | ✅ 本人可改 |

**三个字段的设计理由**：

1. **`owner_name` 冗余而非 expand**：列表页若靠 `expand=owner` 取昵称会引发 N+1 请求
   （每条来源一次关联查询）。冗余一个 `owner_name` 字段，**一次查询直出**。
   ⚠️ 冗余的代价：用户改昵称后旧记录不变——**这是可接受的**，因为"当时的署名"本身
   也是历史信息；且 PB 有 `users` 昵称变更时的批量更新 Hook 可作为后续增强（**Phase 3 可选**）。
2. **`created` 而非新增 `uploaded_at`**：PB 内置字段，服务端生成、客户端不可写，
   **天然防伪**。新增字段反而要自己保证不被前端伪造（还要写 Hook 锁定）。
3. **`source_note` 独立于 `note`**：`note` 是"资源本身的补充说明"（如"含全 CG 存档"），
   `source_note` 是"来源的可信度说明"（如"自购分享""汉化组授权转载"）。
   **两者语义不同**，混用会让审核与展示都变含糊。

> **归属层级说明**：这三个字段都在 `game_resources`（**来源级**），不在 `games`（作品级）。
> 因为同一作品下可能有 3 个不同用户的分享，**提供者与时间必须逐条标注**，
> 不能记在作品上。这也正是 §2.2 选择"来源独立成表"的直接收益。

#### 6.4.2 展示位置（精确到现有代码结构）

> 🔴 **已被取代（2026-10-01）**：开发者用 Figma 重设计了整个探索详情页——
> 用户分享**不再作为左列区块**，而是由「**分享**」弹窗（`share_list_dialog.dart`，锚定对话栏）
> 承载，点其右下角按钮再进「**分享详情**」弹窗看链接/提取码/解压码。
> 因此**本节下述「左列 Column 末尾追加 `CommunitySourcesSection`」的方案作废**，
> `lib/widgets/community_sources_section.dart` 也不再需要新建。
> 现状：`game_detail_page.dart` 拉 `_communityResources`（已发布用户分享）后
> 经 `_handleShareTap` → `ShareListDialog(resources: _communityResources)` 展示。
> **§6.4.1 的字段归属表仍然有效**（提供者 `owner_name` / 时间 `created` / 说明 `source_note`），
> 只是渲染位置从「详情页左列」改为「分享弹窗 + 分享详情弹窗」。
> 下文保留作历史记录。

详情页的现成结构是**左右两列**（`game_detail_page.dart:715-732`）：

```
Stack
 └─ Row
     ├─ Expanded(flex:5, child: _buildLeftSection())   ← 左列
     └─ Expanded(flex:6, child: _buildRightSection())  ← 右列（含安装按钮）
```

| 内容 | 归属列 | 插入位置 | 原因 |
|---|---|---|---|
| 「用户分享」区（含每条来源的展示） | **左列** | `_buildLeftSection()` 的 `Column`（:1146-1162）中，**简介块（:1158-1161）之后** | 左列整列已可滚动（`SingleChildScrollView`），**天然支持来源条数增长**；右列是安装操作区，塞列表会挤压主按钮 |
| 单条来源内的「提供者 + 时间」 | — | 每条来源卡片内，**按钮左侧**（同 `Row`，按钮靠右） | 视觉上"信息在左、动作在右"，符合已确认的文案规范 |

**左列插入点示意**（现有代码 + 3 行）：

```dart
// game_detail_page.dart:1146 附近
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Row(...封面 + 信息...),            // :1149-1156  不动
    const SizedBox(height: 24),         // :1157       不动
    SizedBox(height: descriptionHeight, child: _buildDescription()),  // :1158-1161 不动
    // ↓↓↓ v4 新增：用户分享区（有 community 来源时才渲染）
    CommunitySourcesSection(gameId: widget.gameId),
  ],
)
```

> **零侵入**：新增内容追加在 `Column` **末尾**，既有三个子项**一行不改**。
> 这与 AGENTS.md 的最小变更原则一致。

#### 6.4.3 展示文案（可直接使用）

> ⚠️ **2026-09-30 状态更新**：本表**降级为「暂定 v0」**——开发者表示会参考 KUNGAL 的
> 资源分享展示，且**有尚未表达的想法**，故先做大概设计。**最终形态见 §6.4.5**，
> 其中列出的 7 个可替换点即你的想法可落地的位置。本表内容仍可直接用于 Phase 1 开发。

**推荐样式（每条来源）**：

```
┌────────────────────────────────────────────────┐
│  PS3 版 · 百度网盘              提取码 8x2k     │
│  ≈6.4GB · 直链资源，请自行确认文件安全            │
│                                                │
│  @某用户  分享于 2026-09-28          [打开链接↗] │
└────────────────────────────────────────────────┘
```

**文案对照表（强制）**：

| 元素 | 文案 | 备注 |
|---|---|---|
| 提供者前缀 | `@` + 昵称（如 `@某用户`） | 与站内其他用户提及一致 |
| 提供者兜底 | `匿名用户` | `owner_name` 为空时（如管理员代录） |
| 时间前缀 | `分享于` | **不用**"上传于"——"分享"贴合本功能的用户语言 |
| 时间格式 | `YYYY-MM-DD`（如 `2026-09-28`） | 同年可省年份显示 `09-28`；**不显示时分秒**（信息过载） |
| 来源说明 | 直接展示 `source_note` 原文，**不加前缀** | 为空则整行不渲染 |
| 分隔符 | 提供者与时间之间用**两个空格**（不用 `·`） | 避免与上方"版本 · 网盘"的 `·` 混淆 |
| 悬停提示 | 提供者 `Tooltip` 显示"该资源由用户分享" | 桌面端可用 |

**示例渲染（不同字段组合）**：

| 数据情况 | 渲染结果 |
|---|---|
| 全有 | `@某用户  分享于 2026-09-28`（下行）`自购分享`（说明行） |
| 无 `source_note` | `@某用户  分享于 2026-09-28`（仅一行） |
| `owner_name` 为空 | `匿名用户  分享于 2026-09-28` |
| 极窄窗口 | 整行 `Wrap` 换行，`[打开链接]` 按钮保持右下独立 |

#### 6.4.4 主题适配（必须遵守 `AppColors`）

| 元素 | 色值来源 | 说明 |
|---|---|---|
| 提供者昵称 | `AppColors.primaryText` | 需要一点视觉重量 |
| `分享于` 与时间 | `AppColors.secondaryText.withOpacity(0.7)` | 弱化，不抢主体 |
| `source_note` | `AppColors.secondaryText.withOpacity(0.85)` | 中等权重 |
| 字号 | 昵称/时间 `12`，说明 `12` | 与 `_buildInstallCountHint()`（:1711-1731）的 12 号保持一致 |

> ⚠️ 该区**不做 hover 高亮、不做动效**——它是信息展示，不是交互入口。

#### 6.4.5 🆕 参考基准与**暂定设计 v0**（2026-09-30 · 待定稿）

> **背景**：开发者指示「可以参考 KUNGAL 的资源分享的展示方式，但我有点自己的想法，
> 现在不方便讲述，**现在做大概设计即可**」。
> 因此本节是**占位稿**：把展示层做成**可低成本替换**的形态，等你的想法给出后只改一处。

**① 参考基准（KUNGAL 资源分享）**

观察到的共性模式（我实际访问 kungal.com 首页核对，未逐页拆解其资源详情页 DOM，
故只取**跨站通用的条列模式**，细节以你的想法为准）：

| 共性特征 | 本方案对应 |
|---|---|
| 同一作品下**多来源逐条并列**（不是合并成一行） | ✅ 与 §5.1「永远渲染、条目不减」一致 |
| 每条内**网盘名 + 提取码同排**（提取码靠右、等宽感） | ✅ 见 v0 行 1 |
| **体积 / 类型提示**独立成行，颜色弱化 | ✅ 见 v0 行 2 |
| **提供者与时间**附在条目尾部，动作按钮独立单列 | ✅ 见 v0 行 3 |
| **说明**（若有）单独一行，不加前缀 | ✅ 见 v0 行 4 |

**② 暂定设计 v0（每条来源一张卡）**

```
┌────────────────────────────────────────────────────────┐
│ PS3 版 · 百度网盘                       提取码 8x2k     │ 行1 来源名(主色) + 提取码(次色,右)
│ ≈6.4GB · 直链资源，请自行确认文件安全                    │ 行2 体积 · 类型提示(次色 0.7)
│ @CT测试分享者A  分享于 2026-09-30         [打开链接 ↗]   │ 行3 提供者+时间(左) / 按钮(右)
│ 自购分享                                                │ 行4 source_note(有才渲染)
└────────────────────────────────────────────────────────┘
```

- **分节标题**：`用户分享 (N)`——N = 该作品 community 来源数（§6.2 矩阵要求"条目不减"）。
- **排列**：纵向 `Column` + 条目间 12px；窗口过窄时行 3 自动 `Wrap`。
- **字号**：全部 12（与 `_buildInstallCountHint()` 同规格）；行 1 用 `AppColors.primaryText` +
  `FontWeight.w500`；行 2/3/4 用 `secondaryText`（0.7 / 0.7 / 0.85）。
- **按钮**：沿用既有次要按钮样式，文案固定 **`打开链接`**（§6.3 强制，不随 v0 变）。

**③ 为「你的想法」预留的 7 个可替换点**（改哪一处、成本多低）

| # | 决策点 | v0 取值 | 换掉的成本 |
|---|---|---|---|
| 1 | 整体形态 | **卡片**（带边框/圆角背景） | 低：`CommunitySourceCard` 内单个 `Container` 装饰 |
| 2 | 与内置下载区的相对位置 | 左列**简介下方**、整区在官方上方或下方？ | 低：`_buildLeftSection()` 的插入点一处 |
| 3 | 是否显示网盘图标 | v0 **不显示**（只有文字网盘名） | 低：行 1 加 `Row` + icon map |
| 4 | 提取码呈现 | 直接文本 `提取码 8x2k` | 中：可换"点击复制"chip |
| 5 | 超过 N 条是否折叠 | v0 **不折叠**（全展示） | 中：外层加 `_expanded` 状态 |
| 6 | 时间粒度 | `分享于 2026-09-30`（同年可省年份） | 低：一个 `_fmtDate()` 函数 |
| 7 | 条目点击行为 | 仅按钮可点（整卡不可点） | 低：包一层 `InkWell` 即可 |

> 🔴 **工程上的关键决定（请留意）**：以上 7 点全部收敛在**一个文件、一个 widget**里 ——
> 新建 `lib/widgets/community_sources_section.dart`，内含
> `CommunitySourcesSection`（数据/状态）+ `CommunitySourceCard`（单条渲染）+
> 文件顶部一组 `const` 样式常量（间距/字号/透明度）。
> **你的想法落地时只改这一个文件**，不牵动 `game_detail_page.dart`、模型层或服务层。

**④ 明确不在 v0 范围的**（避免你之后发现少东西）

- 排序规则（官方/用户、时间倒序/正序）：v0 按 **`created` 倒序**（最新在前）。
- 举报入口、点赞、评论：Phase 3 或更后，v0 不做。
- 网盘可达性检测（"链接失效"标记）：v0 不做。
- 匿名/未登录态下的差异：§4.2 已定义，v0 不额外处理。

---

## 7. 改动清单与回归风险

### 7.1 新增文件

| 文件 | 作用 | Phase |
|---|---|---|
| `lib/models/game_resource_model.dart` | 模型 + 枚举 + `ResolvedSource` 统一抽象 | 1 |
| `lib/services/game_resource_service.dart` | 来源查询/创建/更新/删除 | 1/2 |
| `lib/widgets/game_detail/community_sources_section.dart` | 详情页「用户分享」区 | 1 |
| `lib/widgets/share_resource_card.dart` | 单条来源卡片（**含 §6.4 来源信息行**） | 1 |
| `lib/widgets/share_submit_dialog.dart` | 上传表单（三段式） | 2 |
| `lib/pages/my_contributions_page.dart` | 「我的分享」管理列表 | 2 |
| `lib/widgets/game_detail/contributors_section.dart` | 归属展示区（§5.3）—— **v4 暂不接入**，仅备将来 | 3 |

### 7.2 受影响的既有调用点（**结论：零改动，但理由已修正**）

| 文件:行 | 调用 | 状态 |
|---|---|---|
| `discover_page.dart:304` | 首屏 `getGameList` | ✅ **零改动** |
| `discover_page.dart:352` | 全量 `getAllGames` | ✅ **零改动** |
| `big_picture_discover.dart:89,116` | BPM 探索页分页 | ✅ **零改动** |
| `explore_calendar_service.dart:121` | 月历预热 | ✅ **零改动** |
| `game_detail_page.dart:196` | `getGameById` | ✅ **零改动** |

> 🔴 **理由修正（重要）**：v4 初稿说"因选 B 而零改动，因为 `games` 公开可读"。
> **实测证明 `games` 并非公开可读**（§3.1）。那为什么仍然零改动？
> **因为线上现状已经如此**——这 5 处调用点**在当前版本就已经处于"匿名拿空"的状态**，
> 它们是**存量情况，不是本次开发引入的回归**。
>
> 📌 无论选 B1（放宽）还是 B2（维持），**这 5 处都不需要改**：
> - 选 B2 → 完全不动，行为与现在一致；
> - 选 B1 → 规则放宽后**只会拿到更多数据**（从 0 条变正常），更不需要改。
>
> ⚠️ **既有的独立问题**：未登录用户当前打开探索库会看到空列表/失败，
> 界面无友好提示。**这属于既有缺陷，建议独立排期**（P2），不混入本方案。

### 7.3 既有文件的改动点（精确到行）

| 文件:行 | 改动 | 行数 | 风险 |
|---|---|---|---|
| `game_detail_page.dart:1146-1162` | 左列 `Column` **末尾追加** `CommunitySourcesSection` | +2 | 🟢 追加式，零侵入 |
| `game_detail_page.dart:1230+` | **不改** | 0 | — |
| `game_model.dart:54-110` | 新增 `origin`/`owner`/`creator_name`/`contributors`/`review_status`/`has_official`/`community_count` 的解析 | +9 | 🟢 纯新增字段 |
| `pb_config.dart` | **不改**（已有 `isLoggedIn` getter，:18） | 0 | — |
| 分享入口按钮所在文件 | `onTap` 首行加登录判定（§4.3） | +4 | 🟢 局部 |

### 7.4 明确不改（保护既有链路）

- ❌ `CloudInstallFlow` —— 官方安装入口**零改动**
- ❌ `OpenListService.getGameDownloadUrl` —— **零改动**
- ❌ `GlobalInstallCenter` / 下载 / 解压 —— **零改动**
- ❌ 探索库 `_performFilter` 及筛选逻辑 —— **零改动**
- ❌ ADR-011 身份体系（`game.json.game_id`）—— **零改动**
- ❌ `games` 的 List/View PB 规则 —— **零改动**（方案 B）

### 7.5 ADR-011 兼容性（用户作品被安装时）

用户作品在**首次被安装到本地**时才会产生 `game.json` 与 `game_id`：
- 目录名清洗**必须**走 `GameKey.dirNameFromTitle`（唯一实现），禁止另写；
- 与既有本地目录冲突时走既有后缀逻辑，**禁止覆盖**；
- 未安装的用户作品**不预生成 `game_id`**（避免与本地身份体系冲突）。

---

## 8. 实施计划

> ✅ **验收标准已被开发者接受（2026-09-30）**，另追加一条质量门：
> **每 Phase 收尾须附 `flutter analyze` 结果（只看新增 error）**；环境不许可时
> 必须显式标注并说明替代验证手段。

| Phase | 内容 | 验收 |
|---|---|---|
| **1. 数据层与只读展示** | PB 建表+规则（含备份）；模型+服务只读；详情页用户分享区（**含 §6.4 来源信息**）；卡片角标 | 手工造数据可正确并列显示；提供者/时间/说明三项齐全；官方安装链路零回归 |
| **2. 提交与我的分享** | 创建/更新/删除；三段式表单；我的分享页；**写入入口登录预判** | 登录用户可提交（场景 1/2）；未登录被拦且提示友好 |
| **3. 归属与加固** | `contributors` 写入；Hook 防提权；举报机制（可选）；`contributors_section` 接入（**待权益体系定案**） | 转正后归属信息完整保留 |

**每 Phase 收尾**（按 `AGENTS.md` §3）：analyze 只看新增 error → 新增单测 → 更新
`DEV_LOG`/`STATUS_MAP`/本文件 → 一任务一 commit。

### 8.1 Phase 1《变更计划》（阶段 A 只读审计产出 · 2026-09-30）

> 依据 `AGENTS.md` §2.2：**本计划未获批前不写任何代码**。
> 审计基准：`git HEAD = 72d2d01`；工作区另有 11 个文件的未提交改动（见下方 ⑤-2 冲突项）。

#### ① 服务端前置（只读，不改任何结构）

已实测确认（2026-09-30）：

| 项 | 实测值 | 对 Phase 1 的意义 |
|---|---|---|
| `game_resources` List/View | `kind="official" \|\| (kind="community" && status="published") \|\| owner=@request.auth.id` | **公开读** → 未登录也能看到已发布的用户分享 ✅ |
| `game_resources` Create | `@request.auth.id != "" && @request.body.kind="community" && ...` | 用 `@request.body.*`（坑 ① 已规避）✅ |
| `games` 读 | 已放宽（方案 B1） | 298+1 条可读 ✅ |
| 测试数据 | 4 条（全 `status=pending`） | 匿名 0 条 / 测试账号 A 3 条 ✅ |

**结论：Phase 1 无需任何服务端改动**（建表、字段、规则、Hook 均已在第 0–5 步完成）。

#### ② 新增文件（4 个）

| # | 文件 | 内容 | 估计行数 |
|---|---|---|---|
| 1 | `lib/models/game_resource_model.dart` | 3 枚举（`ResourceKind` / `ResourceStatus` / `ResourceLinkType`）+ `GameResourceModel` + `fromPBRecord`。取值一律走 `record.data[...]` + 空值兜底（沿用 `GameModel._safeGetString` 风格，**避开类型专用 getter**） | ~120 |
| 2 | `lib/services/game_resource_service.dart` | Phase 1 仅 **2 个只读方法**：`listPublishedByGame(gameId)`（filter `game="<id>" && kind="community" && status="published"`，sort `-created`）、`countPublishedByGame(gameId)`（取 `totalItems`，供角标）。**失败一律返回空列表**（静默降级，不阻塞详情页） | ~90 |
| 3 | `lib/widgets/game_detail/community_sources_section.dart` | 区标题 `用户分享 (N)` + 列表 + 空态；文件顶部一组 v0 样式常量（§6.4.5） | ~130 |
| 4 | `lib/widgets/game_detail/community_source_card.dart` | 单条来源卡（§6.4.5 v0 四行结构：来源名+提取码 / 体积·类型提示 / 提供者+时间·按钮 / 说明） | ~150 |

> ⚠️ **与 §7.1 的一处文件名偏差，请确认**：§7.1 列的是
> `lib/widgets/game_detail/community_sources_section.dart` + **`lib/widgets/share_resource_card.dart`**
> （后者放在 `lib/widgets/` 根目录，理由是 **Phase 2「我的分享」页要复用**）。
> 本计划把单卡也放进 `game_detail/` 子目录 —— 依据是 §6.4.5 刚定的
> 「你的想法落地只改一个文件」，同目录更便于整块替换。
> **若你更看重 Phase 2 复用，我改回 §7.1 的路径（成本 0，仅路径差异）。**

#### ③ 既有文件改动（3 个文件、4 处）

| 文件:行 | 改法 | 行数 |
|---|---|---|
| `lib/models/game_model.dart:4-52 / 54-110 / 270-314` | 新增 7 字段（`origin`/`owner`/`creator_name`/`contributors`/`review_status`/`has_official`/`community_count`）→ 字段声明 + 构造默认值 + `fromPBRecord` 解析 + `copyWith` | ~+35 |
| `lib/pages/game_detail_page.dart:1161` | 左列 `Column` 中 `SizedBox(..._buildDescription())` **之后**追加 `CommunitySourcesSection(gameId: widget.gameId)` | +1 |
| `lib/pages/discover_page.dart:25-50` | `GameCardData` 加 `origin` / `hasOfficial` / `communityCount`（+ `fromModel` 映射） | ~+10 |
| `lib/pages/discover_page.dart:_DiscoverCardWidget` | 卡片角标（§6.1）：`可安装` / `用户分享` / `可安装 · N 分享` | ~+25 |

#### ④ 影响面

- **详情页左列**：纯**追加**，既有 3 个子项（封面行 / 24px 间距 / 简介块）**一行不改**。
- **探索库卡片**：仅新增角标层，不动既有 hover、已安装徽章、元数据懒加载。
- **`GameModel` 是全站共用模型**（探索页 / BPM 大屏 / 月历 / 详情 / 安装链路）——
  7 个新字段全部为**可选参数 + 默认值**，`fromPBRecord` 为纯新增解析 →
  对既有调用点**零破坏**；最坏情况是某处忘了传新字段，取值落到默认值。
- **新服务独立**：`game_resource_service` 不触碰 `game_repository`，官方安装链路不受影响。

#### ⑤ 🔴 三个必须先定的点

**（1）`has_official` 回填 —— 阻塞角标与详情页矩阵（P0）**（详见 §9.5）

- 现状：298 条遗留作品 `has_official` **全 `false`**，但 `downloadUrl` **全非空**（都有内置下载）。
- 不改的后果：298 条全被判成「**无**官方来源」→ 角标全部退化为「用户分享」、
  详情页**官方安装区不渲染** ⇒ 这是**回归**（现网正常功能被新逻辑关掉）。
- **建议 A（推荐）**：回填 298 条 `has_official = true`，
  改前改后各复核一次 `games.totalItems` 仍为 298。**需你点头。**

**（2）`discover_page.dart` 未提交改动冲突（P0 · 流程）**

- 该文件当前有 **873 行未提交改动**（探索库顶栏 v2/v2.1/v2.2：标签 / 会社双板块、
  内联评分·年份·排序）。**Phase 1 的卡片角标也要改这个文件** →
  两套改动会混在同一工作区，**无法干净地「一任务一提交」**。
- **建议**：先单独把顶栏 v2 那批 work 提交掉；或明确授权我把角标改动单独成一次提交
  （用 `git add -p` 拆开）。⚠️ 顶栏 work 自身也卡在 `flutter analyze` 环境故障上。

**（3）`flutter analyze` 环境故障 —— ✅ 已恢复（2026-09-30 12:32）**

- 故障现象（曾持续多轮）：子进程创建报 `CreateFile failed 231`（Windows 命名管道/句柄耗尽），
  沙箱内外均失败，连 `cmd.exe /c ver` 都起不来。
- **现已自愈**：`dart analyze` 与 `flutter.bat` 均正常工作。补跑结果：
  - 注册验证码相关 5 文件 → **0 error**（13 warning/info，其中 `auth_service.dart:86/124/873`
    三条属既有代码风格，非新增缺陷）；
  - 工作区未提交改动相关文件（`discover_page.dart` / `big_picture/` / `main.dart` 等）
    → **0 error**（86 warning/info）；
  - `flutter test` 全量 → **1049 passed / 1 skipped / 0 failed**。
- **结论**：质量门（§8 已接受「每 Phase 附 analyze」）**现在可以满足**；
  开工不再受此阻塞。

#### ⑥ 一个 UX 副作用，需你拍板（P2）

左列 `descriptionHeight = (constraints.maxHeight - 371).clamp(160, …)`（`game_detail_page.dart:1141-1143`）
让**简介吃掉全部剩余高度**。因此在简介之后追加的来源区，**永远落在首屏之外**，用户须滚动才可见。

| 选项 | 代价 |
|---|---|
| **保持现状**（推荐先行） | 符合 §6.4.2 已定方案，零额外改动 |
| 给简介加高度上限（如 `min(240, …)`） | 属**改动既有布局**，需你明确同意后再做 |

#### ⑦ 明确不改（保护既有链路）

`CloudInstallFlow` / `OpenListService.getGameDownloadUrl` / `GlobalInstallCenter` /
`explore_calendar_service` / ADR-011 身份体系（`game.json.game_id`）/
`games` 与 `game_resources` 的 PB 规则 / 探索库 `_performFilter` 筛选逻辑。

#### ⑧ 验证方式

1. `flutter analyze`（4 新文件 + 3 改文件，只看**新增 error**）—— **当前环境不许可**。
2. 新增单测：`test/models/game_resource_model_test.dart`（`fromPBRecord` 字段映射 + 空值兜底）。
3. 服务端联调：用测试账号 A 拉命运石之门（`721jt6r0bivadwh`）来源 → 期望 **3 条**；匿名 → **0 条**。
4. 真机走查：详情页出现「用户分享 (3)」且**提供者/时间/说明三要素齐全**；
   探索库卡片角标正确；**官方安装链路零回归**。
5. 数据复核：`games` **298** / `game_resources` **4** / `users` **183**。

---

### 8.2 Phase 1 实施记录（2026-10-01 · 授权后执行）

> **授权依据**：开发者「确定授权，请继续」——批准一次做完「详情页重构 + 4 弹窗 + 数据层 + 看板娘账号」。
> **回档保障**：commit `8b16216` + tag `pre-explore-redesign` + 源码 zip `D:\CTLIB\__recover\pre-explore-redesign-src.zip`。

#### ① 服务端

| 项 | 结果 |
|---|---|
| `game_resources` 扩表 | **21 → 27 字段**：+`resource_type` / `languages` / `platforms`（select **多选，`maxSelect:0`**）、`unzip_code`（text ≤120）、`download_count` / `like_count`（number） |
| 备份 / 回滚 | 扩表前基线 `.workbuddy/pb_backup/pre-extend-20261001-085607/`；脚本 `.workbuddy/pb_tmp/pb_extend_02_apply.py`（备份→读线上比对→**只追加**→rollback manifest→PATCH） |
| `lock_fields.pb.js` **v4** | 新增锁定 `download_count` / `like_count`。🔴 **待开发者部署到 PB 同级目录并重启**（否则这两个计数可被客户端直接 PATCH） |
| 看板娘账号 | 见 §2.4.1（id `0fw0trcd3dbmqow`） |
| 现状 | official 记录 **= 0** ⇒ 无需回填 |

#### ② 客户端（新增 11 / 改动 6）

| 层 | 文件 | 说明 |
|---|---|---|
| 数据 | `lib/models/game_resource_model.dart` | 27 字段 + 3 枚举 + `fromPBRecord`（类型无关取值）+ `toSubmitBody()`（**排除** `kind`/`status`/`owner`/计数字段）+ `createdAgeLabel()` 相对时间 |
| 数据 | `lib/services/game_resource_service.dart` | 读 4 方法 + `communityCountBatch` + `createCommunityResource` + `registerDownload`/`setLike`（走 `/api/ct/resource/...`，未部署静默 false） |
| 主题 | `lib/theme/{app_colors,app_theme_manager,theme_registry}.dart` | `CTThemeData` +6 可空字段（`accentCyan` #2DA6D4 / `accentInk` / `accentViolet` #6841C4 / `dividerStrong` #2B2B2B / `heartRed` #DD1B24 / `feedbackGreen` #00AD38）；**6 个内置主题各补一份**，暖阳取设计原值；8 处同步（声明/构造/`lerp`/`toJson`/`fromJson`/`withColor`/`_copyWith`/`asUserThemeCopy`） |
| 共享层 | `lib/widgets/game_detail/dark_surface.dart` | `DarkPalette`（固定色值 + 尺寸常量）+ 原子组件 + `showDarkCenteredDialog` / `showDarkAnchoredPanel`（`CustomSingleChildLayout` + `SingleChildLayoutDelegate`） |
| 弹窗 | `ct_download_dialog.dart` | 【获取】锚定对话栏 515dp；标题「Chrono Tide 下载」；**分享者恒为看板娘**；顶部徽章行 =「游戏本体 / Windows」+ **版本号**（`version`，2026-10-09 起）；底部 = **版本说明**（`versionNote`，整行换行完整展示）+ 体积；下载区右侧按钮 + 下载人数 |
| 弹窗 | `share_list_dialog.dart` | 【分享】锚定 600dp；右上上传者；每卡相对时间（`createdAgeLabel`，对齐设计「4 个月前」）；右下角药丸按钮**「获取资源」+ 云图标**（→ 分享详情） |
| 弹窗 | `share_detail_dialog.dart` | 【分享详情】居中 725×915；资源详情 + 链接 + 提取码 + **解压码** |
| 弹窗 | `upload_resource_dialog.dart` | 【上传】居中 679×1083；三段式表单；入口加**登录守卫** |
| 头部 | `game_detail_header.dart` | 封面 135×205、标题/别名/元数据/标签；操作行 `获取 / 分享 / 上传 | 喜欢 / 反馈` |
| 身份 | `kanban_identity.dart` | 看板娘常量；**头像离线优先**（用内置 `assets/images/kanban_shino.png`，不拉 PB） |
| 详情页 | `lib/pages/game_detail_page.dart` | 右列大安装按钮**删除** → 移入获取弹窗；顶部「获取」按钮**按状态变形**（获取/已安装/安装中带进度/排队中） |
| 角标 | `lib/pages/discover_page.dart` + `lib/models/game_model.dart` | §6.1 已接线（详见 §6.1 注） |

#### ③ 顺带修掉的真实缺陷（同源，非「顺手优化」）

`Container(alignment: Alignment.center)` 被放进 `Wrap`（传松约束）时会**撑满整行**：
① `game_detail_header` 的「获取/分享/上传」各占一行；② `upload_resource_dialog` 的 14 个 Markdown
工具按钮全部竖排。统一改 `Center(widthFactor: 1.0)` 包裹内容、去掉 `alignment`；已 grep 全量确认无第三处。

#### ④ 与设计稿的**有意偏离**（3 处，均已标注在代码注释）

| # | 设计值 | 实现 | 理由 |
|---|---|---|---|
| 1 | 「上传」按钮内容色 `#2A5FA5` | 纯白 | 在 `#6841C4` 底上对比度仅 ~2.1:1，判定为设计笔误 |
| 2 | 标签字号 ≈9.5px | 12px（紧凑档） | 现无 dense 档；宽度偏大约 14px |
| 3 | ~~分享卡同容器 + 分隔线~~ | 每卡独立描边 | **保持现状**（开发者走查未提异议） |
| 4 | 「获取」按钮无官方资源时的表现 | **可点 + 明确提示** | 设计未定义该态。原实现直接置灰禁用 ⇒ 真机表现为「点不动且无提示」（2026-10-01 反馈）。⚠️ 该修复当时仍误用 `game_resources` 判据，**真实根因与最终修法见 §8.4** |

#### ⑤ 验证

| 项 | 结果 |
|---|---|
| `flutter analyze lib` | **0 error**（585 条存量 warning/info） |
| 改动文件单独 analyze | 0 error；10 条告警与 `HEAD` 逐条比对确认**全为存量** |
| `flutter test` | **1070 passed / 1 skipped / 0 failed**（基线 1063 + 7 条 `has_official` 用例） |
| ⚠️ 首轮全量 `-1` | **复跑全绿** ⇒ 既知 flaky（全量并发偶发），非本轮引入 |
| 设计比对 | 5 组件离屏渲染 + 逐像素/逐行扫描：**配色逐像素一致**、几何偏差收敛；证据 `.workbuddy/outputs/explore-redesign-preview/` |

#### ⑥ 未完成 / 待办

| 级别 | 项 |
|---|---|
| 🔴 P0 | 开发者部署 `lock_fields.pb.js` **v4** 并重启 PB |
| 🟠 P1 | **真机走查**（锚定浮层 `showDarkAnchoredPanel` 实际落点、头部像素级还原） |
| 🟡 P2 | 分享卡右下角按钮文案待开发者确认（设计稿约 9px 无法 OCR，现为「获取资源」） |
| 🟡 P2 | `games.community_count` 写入链路同步维护（当前恒 0，角标已用现算绕过） |
| ⬜ | Phase 2（用户提交表单与「我的分享」页）、Phase 3（`contributors` 接入） |

---

### 8.3 真机走查反馈修复（2026-10-01）

> 开发者部署 Hook v4 并完成真机走查，反馈 3 项，全部处理。

#### ✅ Hook v4 部署已验证

探针两侧对照（详见 `DEV_LOG` 同日条目）：基线 `title` 生效 + 锁定字段
`download_count`/`like_count` **超管通道亦生效** ⇒ v4 已部署、超管豁免有效。
⚠️ 探针注意：`owner` 是 relation 到 **`users`**，超管 id 不在 users 表 →
必须用真实 users 记录（用看板娘，勿污染真实用户）。

#### 🔴 反馈 1：「获取」按钮点不动（真缺陷）

- **根因**：`_getButtonEnabled` 原为 `_installState != disabled`，而 `disabled`
  由 `_primaryOfficial == null` 触发 ⇒ 按钮 `onTap: null` + 置灰，
  **点不动且无任何提示**。official 记录当前为 0 条，真机必然命中。
- **修复**：仅**安装中**禁用；其余可点，由新增 `_resolveGetBlockReason()` 分四种
  原因给可执行提示（未登录 / 加载失败 / 加载中 / 无官方资源）。
  > 🔴 **本节当时的"无官方资源"判据是错的**（用了 `game_resources` 的 official 记录）。
  > 正确判据是原生 `games.downloadUrl`，修复见 **§8.4**。本节其余内容仍有效。
- **文件**：`lib/pages/game_detail_page.dart`

#### 🟠 反馈 2：上传窗口底部有「设计中不存在的标线」

- **根因**：`DarkShell` 的 `clipBehavior: Clip.antiAlias` **只裁切直接子级 layer**；
  弹窗内 `Column → Flexible → SingleChildScrollView` 的滚动内容在**独立 layer** 合成，
  不受 shell 裁剪 ⇒ 滚动时溢出圆角边框，底部/两侧露出横线。
- **修复**：`SingleChildScrollView` 加 `clipBehavior: Clip.hardEdge`。
- **同时按设计移除**：「`N` 字」字符数统计、「特殊语法…」长提示（设计稿中没有，
  且前者随输入实时变化，也是底部跳动的来源）；「Markdown 支持」胶囊保留并
  移到**工具栏下方**（`_MdSupportPill`）。
- **文件**：`lib/widgets/game_detail/upload_resource_dialog.dart`

#### ✅ 反馈 3：分享卡右下角按钮文案 = 「获取资源」（已确认）

#### ⚠️ 验证状态

`git diff` 已精确核对（仅上述 2 文件，+73 −43）。但 `flutter analyze` / `flutter test`
**未能执行** —— 环境故障复发（`CreateFile failed 231`，non-code，本仓历史多次记录）。
已做离线结构级自检过渡。**环境恢复后须补跑，再提交。**

---

### 8.4 🔴 官方下载通道澄清与修复（2026-10-01，**必读**）

**结论先行**：上一轮我把「获取」按钮的数据源错接成 `game_resources` 的
`kind=official` 记录，而该表是**新表、official 记录为 0 条** ⇒ 真机上所有作品都显示
「暂无官方资源」，尽管原生下载一直都在。**已修正**：官方下载的依据回到
**原生 `games` 记录**，`game_resources` 的 official 记录降级为**可选补充**。

#### 开发者意图（唯一权威表述，勿再演绎）

| 项 | 说明 |
|---|---|
| 「获取」= | **官方下载**，即**软件原生下载方式**，与以前**完全一致** |
| 数据 | 以前所有官方下载的作品**全部沿用**；PB 里的资源大小、版本信息等**保持不变** |
| 看板娘的作用 | **仅仅是 owner / 署名** —— 让官方上传有个人格化来源，顺便宣传角色 |
| ⛔ **不是** | **不是**新建一条官方资源渠道，**不是**要求在 `game_resources` 里重建记录 |

#### 两套通道的边界

| 通道 | 数据来源 | 弹窗 | 行为 |
|---|---|---|---|
| **官方 / 原生** | **`games.downloadUrl`** + `version` / `versionNote` / `installCount` | 【获取】 | 可直接安装（OpenList 路径解析 → `CloudInstallFlow`） |
| **用户分享** | `game_resources`：`kind=community & status=published` | 【分享】 | 外链，只能跳转 |

> `game_resources` 里的 `kind=official` 记录**不是第三条通道**，它只是同一套官方资源的
> "资源级"表达（承载 `resource_type` / `platforms` / `download_count`）。
> **有它 → 补充展示；没它 → 一切照旧。**

#### 根因（两个错误叠加）

1. `_primaryOfficial` 只读 `game_resources` 的 `kind=official` → 该表 **0 条**；
2. `_installState` 与「获取」弹窗都以它为准 ⇒ 一律判「无资源」。

#### 修复

- 新增 **`OfficialResourceView`**（`lib/models/game_resource_model.dart`）：官方资源统一视图。
  `fromGame(...)` **以 `games` 为准**，`game_resources` 的 official 记录仅**补充**
  `resource_type` / `platforms` / `download_count` / `like_count` / `file_size`。
- `_installState` / `_resolveGetBlockReason` 改判 `_officialResource`（原生路径）；
  返回 null **仅当 `downloadUrl` 也为空**。
- `CtDownloadDialog.resource`：`GameResourceModel?` → **`OfficialResourceView?`**；
  新增 `fallbackFileSize`（原生无大小字段 → 用本地 `FileSizePrefetchService` 预取结果）。
- `_loadResources()` 失败**不再阻断「获取」**（它只是补充通道），仅影响分享弹窗列表。
- 分享者展示恒定回退看板娘（默认「时之 汐乃」），不依赖记录是否存在。

#### ⚠️ 验证状态

结构级自检通过（3 文件括号全平衡；`CtDownloadDialog.resource` 类型与调用方一致；
无 `_primaryOfficial` 直传残留）。`flutter analyze` / `flutter test` 因**环境故障**
（`CreateFile failed 231`）**未执行**，需环境恢复后补跑。

---

### 8.5 浮层兜底清扫清单（P0 · 承接 2026-10-01 真机反馈）

> **背景**：标线根因已定位并修复 3 处（commit `0c00ad2`）。开发者反馈「**不止 3 个窗口**」，
> 故本节给出**全量候选清单**作为 P0 扫尾项。
>
> **唯一判据**：浮层**没有 `Material` 祖先**，且内部存在**未显式设置 `style` 的 `Text`**
> ⇒ 该文本继承 `MaterialApp` 的兜底 `_errorTextStyle`
> （`decorationColor: 0xFFFFFF00` + `decorationStyle: double`，见
> `flutter/packages/flutter/lib/src/material/app.dart:33`）。
> ⚠️ 静态分析**判不准**（`style` 可能来自局部变量 / `DefaultTextStyle` / 主题继承），
> 故本清单是**候选**，最终以真机走查锁定。

#### ① 一次性修法（改 1 个文件覆盖 8 处）

`lib/widgets/animated_overlay.dart` 的 `build()`（:104-164）内「内容层」
`Align → FadeTransition → child` **外面包一层 `Material(type: MaterialType.transparency)`**
⇒ 所有经 `AnimatedOverlay` 的浮层一并兜底。

| 调用方 | 备注 |
|---|---|
| `main_container.dart:287 / 597 / 681 / 720` | 🔴 **稳定区调用方** —— 本修法**不修改 `main_container.dart` 本身**，但会改变这 4 个浮层的渲染环境 ⇒ **需单独批准**（见 §8.6-⑤-2） |
| `background_image_editor_dialog.dart:43` | 背景图编辑 |
| `name_dialog.dart:36` | 命名弹窗 |
| `series_panel.dart:42` | 已在 `:65` 自查补过透明 Material ⇒ 双保险 |
| `theme_editor_dialog.dart:62` | 主题编辑 |

⚠️ **风险**：`Material` 会给子树提供 `Ink` 语义。若某浮层内按钮依赖 `InkWell` 水波纹，
此前无 Material 祖先时本应 debug 抛错 ⇒ 推断其已自带 Material，本次包裹属**纯兜底**。
但仍须真机走查这 5 个窗口，确认水波纹 / 点击态无变化。

#### ② 逐个核查清单（裸 `OverlayEntry` 直插，合计 **19 处**）

| # | 位置 | 现状 / 用途 |
|---|---|---|
| 1 | `smart_import_notification.dart:193` | ✅ 已修（`0c00ad2`） |
| 2 | `game_detail_page.dart:1375` | ✅ 已在 `:1387` 自查包透明 Material —— 复核即可 |
| 3–7 | `library_page.dart:448 / 496 / 994 / 1330 / 1443` | ⬜ 待核（管理面板 / 右键菜单 / 拖拽层） |
| 8–9 | `join_page.dart:413 / 435` | ⬜ 待核（导入浮层 / 进度浮层） |
| 10 | `discover_page.dart:1494` | ⬜ 待核（探索库菜单） |
| 11 | `game_detail_dialog.dart:664` | ⬜ 待核（目录菜单） |
| 12 | `my_themes_section.dart:456` | ⬜ 待核（主题右键菜单） |
| 13 | `tags_popup_menu.dart:73` | ⬜ 待核（标签弹窗） |
| 14 | `bpm_context_menu.dart:60` | ⬜ 待核（BPM 右键菜单） |
| 15 | `experience_calendar_picker.dart:38` | ⬜ 待核（日期选择） |
| 16 | `big_picture_shell.dart:262` | ⬜ 待核（虚拟键盘浮层） |
| 17 | `exit_overlay.dart:15` | ⬜ 待核（退出确认） |
| 18 | `update_dialog.dart:40` | ⬜ 待核（更新提示） |
| 19 | `eyedropper_overlay.dart:51` | ⬜ 待核（取色器，疑无文本 ⇒ 无风险） |

> **建议顺序**：先做 ①（1 文件 / 8 处）→ 真机走查开发者截图里的窗口是否**全部无线** →
> 再按 ② 清单逐条确认。②中多数是**右键菜单 / 轻量浮层**，若走查仍有线再逐一包。

#### ③ 防回归约定（建议补进 `AGENTS.md` UI 章节）

> 任何挂在 `OverlayEntry` / `showGeneralDialog` 上、且不经 `Material` 的浮层，
> **必须在根部包 `Material(type: MaterialType.transparency)`**。

---

### 8.6 Phase 2《变更计划》（阶段 A 只读审计产出 · 2026-10-01，**待批准**）

> 依据 `AGENTS.md` §2.2：**本计划未获批前不写任何代码**。
> 审计基准：`git HEAD = 0c00ad2`，**源码工作区干净**（未提交项仅 `.workbuddy/`、`dev_probe/`、
> `docs/DEV/` 下新增文档等非源码内容）。
> 前置状态：Phase 1 ✅ 终验通过（进程内 analyzer 0 error / `test` 1070 passed）。

#### ① 现状核对（读代码得出，非推测）

| 项 | 位置 | 现状 |
|---|---|---|
| 提交资源 | `lib/services/game_resource_service.dart:130` `createCommunityResource` | ✅ 已实现 |
| 详情页上传入口 + 登录守卫 | `lib/pages/game_detail_page.dart:1059-1063` | ✅ 已就位 |
| 三段式表单 | `lib/widgets/game_detail/upload_resource_dialog.dart`（`ResourceDraft` :10、`onSubmit` :750） | ✅ 已就位，**可复用为编辑模式** |
| 按作品查我的投稿 | `game_resource_service.dart:67` `fetchMine(gameId)` | ⚠️ 已实现，但**全 `lib/` 零调用点** |
| 跨作品查我的投稿 | — | 🔴 **不存在** |
| 编辑 / 删除投稿 | — | 🔴 **不存在** |
| 「我的分享」界面 | — | 🔴 **不存在**（`lib/pages/my_contributions_page.dart` 缺失） |
| 统计路由 | `.workbuddy/pb_hooks/` 仅 `lock_fields` / `require_otp_on_register` | 🔴 未部署 ⇒ `registerDownload` / `setLike` 静默 false |
| `contributors` 写入 | `lib/models/game_model.dart` 有字段，无写入方 | ⬜ Phase 3 |

#### ② 服务端约束（**本轮不改任何规则**，但决定实现边界）

| 操作 | 规则原文（本文件 §3.3） | 实现约束 |
|---|---|---|
| Update | `owner = @request.auth.id && kind = "community" && status != "published"` | 🔴 **只有「待审核 / 已驳回」可编辑**；编辑已发布记录得 **404** |
| Delete | `owner = @request.auth.id && kind = "community"` | 三种状态均可删（已发布删除 = 撤下） |
| `lock_fields.pb.js`（线上 v4） | 锁定 `kind` / `status` / `owner` / `created` / `report_count` / `download_count` / `like_count` | 🔴 **客户端改不动 `status`** ⇒ 见 ⑤-1 |

#### ③ 新增文件（3 个）

| # | 文件 | 内容 | 估计行数 |
|---|---|---|---|
| 1 | `lib/pages/my_contributions_page.dart` | 「我的分享」列表：状态徽章（审核中 / 有效 / 已驳回 / 已隐藏）+ 驳回理由 + 作品名 + 提交时间 + 编辑 / 删除 | ~230 |
| 2 | `lib/widgets/game_detail/my_resource_tile.dart` | 单条投稿卡（若 Phase 3 不复用可合并进 1） | ~120 |
| 3 | `test/services/game_resource_service_mine_test.dart` | `fetchAllMine` / `updateMine` / `deleteMine` 的 filter 构造与错误翻译 | ~90 |

#### ④ 既有文件改动（3 个文件、5 处）

| 文件:行 | 改法 | 行数 |
|---|---|---|
| `game_resource_service.dart:233`（`_query`） | 增可选参 `expand` 与 `perPage`（列表页需跨作品取全量、并带出作品名） | ~+8 |
| `game_resource_service.dart`（`_query` 之后） | 新增 3 方法：`fetchAllMine()`（filter `owner='$uid'`、`sort '-created'`、`expand: 'game'`）/ `updateMine(id, draft)`（PATCH `toSubmitBody()`）/ `deleteMine(id)`（DELETE） | ~+95 |
| `game_resource_model.dart:104` | 增 `gameTitle` 派生字段（从 `expand.game` 取；取不到留空，由 UI 回退显示短 id） | ~+12 |
| `upload_resource_dialog.dart:45` | 增可选 `initial: ResourceDraft?`（预填 :64-81 的 7 个 controller + 3 个 Set）与 `submitLabel`；**无 `initial` 时行为与现在完全一致** | ~+45 |
| `share_list_dialog.dart`（header 区） | 右上角增「我的分享」入口按钮（**仅登录时显示**） | ~+18 |

> ⛔ **不新增独立页路由**：`main_container` 属稳定区（`_buildCurrentPage` 常驻 Stack + Offstage 保活）。
> 「我的分享」以**居中深色弹窗**呈现（复用 `showDarkCenteredDialog`，与【上传】679×1083 同族）
> ⇒ **零稳定区改动**。

> ⚠️ **`expand: 'game'` 的规则依赖**：PB 的 `expand` 需要 `games` 的 **View** 规则放行该记录。
> 现规则为 `@request.auth.id != "" || review_status = "approved"` —— 本页**要求登录**，
> 故恒满足。若取不到（老数据 / 规则收紧），UI 回退显示 `gameId` 短 id，**不报错**。

#### ⑤ 🔴 三个必须先定的点

> ✅ **三点均已定案（2026-10-01 傍晚）**：
> （1）**选 A**；（2）§8.5① **已批准并落地**（`bd1673d`）；（3）统计路由 **本轮做并已完成**（`c27a113`）。
> 以下原文保留为决策依据。

**（1）「编辑已驳回投稿」需要服务端配合（P0，否则功能半残）**

- 现状：`status` 被 `lock_fields.pb.js` 锁定 ⇒ 用户编辑后 `status` 仍为 `rejected`，
  管理员**看不到「已重新提交」的信号**，该投稿永远卡死。
- **方案 A（推荐 → ✅ 已采用）**：`lock_fields.pb.js` 升 **v5** —— `game_resources` 分支对 `status`
  增加**唯一白名单转换**：`orig.status === "rejected"` 且新值 `"pending"` 且
  `owner = 当前登录用户` 时放行。成本：1 个 Hook + 1 次部署；收益：编辑链路闭环。
- **方案 B（零服务端改动）**：不做编辑，只做**删除 + 重新提交**，UI 文案明确
  「已驳回的投稿请删除后重新提交」。
- ⇒ ✅ **已选 A**（2026-10-01 傍晚，开发者批准）；服务端 v5 与客户端 `resubmit` 均已实施。详见 §8.13-③。

**（2）§8.5① 会间接影响 4 个稳定区入口 ⇒ 需显式批准**

- 修改 `animated_overlay.dart` 会改变 `main_container.dart:287/597/681/720` 托管的
  4 个浮层的渲染环境。文件本身不在稳定区，但**影响面落在稳定区**。
- ⇒ ✅ **已批准并落地**（`bd1673d`）。

**（3）统计路由是否本轮一并做（P1）** → ✅ **本轮做，已完成开发**

- 新建 `.workbuddy/pb_hooks/resource_stats.pb.js`，暴露
  `POST /api/ct/resource/{id}/download` 与 `/like` `/unlike`，在 Hook 内以**超管通道**
  写 `download_count` / `like_count`（这两个字段已被锁，客户端直改无效）。
- 与 Phase 2 **无依赖**，可并行、也可延后。⇒ 请指定是否本轮做。

#### ⑥ 明确不改（保护既有链路）

`games` / `game_resources` 的 PB 规则 · `CloudInstallFlow` · `OpenListService.getGameDownloadUrl` ·
`lib/repositories/game_repository.dart` · `main_container.dart` · BPM 相关 · ADR-011 身份体系。

#### ⑦ 验收标准（对齐本文件 §8 表格 Phase 2 行）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 未登录点「上传」/「我的分享」 | 被拦 + 友好提示（上传入口**已实现**，复核） |
| 2 | 登录 → 上传 → 提交成功 | 弹「已提交，审核通过后对所有用户可见」；「我的分享」立即可见该条、状态「审核中」 |
| 3 | 管理员后台改 `rejected` 并填 `reject_reason` | 「我的分享」显示「已驳回」+ 理由 |
| 4 | 编辑一条「审核中 / 已驳回」投稿 | 表单预填原值；保存后列表刷新（状态按 ⑤-1 决策） |
| 5 | 删除一条自己的投稿 | 二次确认 → 列表移除；记录消失 |
| 6 | 对**已发布**的投稿 | 编辑：不可进入（按钮禁用 + 说明原因，**不做静默禁用**）；删除：允许（= 撤下） |
| 7 | 官方「获取」安装链路 | **零回归** |

#### ⑧ 验证方式

1. **进程内 analyzer 探针**（`D:\CTLIB\.workbuddy\analyze_probe\`）覆盖全 `lib` + 新增 `test`，
   只看**新增 error**。⚠️ 本环境禁建匿名管道（`CreateFile failed 231` = `ERROR_PIPE_BUSY`），
   `flutter analyze` 子进程不可用。
2. `flutter test` —— **由开发者执行**（你终端可用）。
3. 服务端联调：测试账号 A → 「我的分享」应列其全部投稿；匿名调用应返回空。
4. 真机走查：⑦ 的 7 个场景。

#### ⑨ 稳定区影响声明

| 稳定区文件 | 本轮是否改动 | 说明 |
|---|---|---|
| `main_container.dart` | ⛔ **不直接改** | 但 §8.5① 会改变其托管的 4 个浮层渲染环境 ⇒ 需批准 |
| `main.dart` / `lib/theme/` / `lib/core/portable_*.dart` / `app_state.dart` / `windows/runner/` / `packages/luna_metadata_sdk/` | ⛔ 不涉及 | — |

---

### 8.7 【发布】链路设计（新需求 · 2026-10-01 开发者补充）

> **需求来源**：开发者明确补充 —— 用户上传分享**分两种类型**。
> 本节是该需求的唯一权威落地设计。

#### ① 两种类型的边界（最易混淆，先钉死）

| 类型 | 触发前提 | 入口 | 目标集合 | 命名 |
|---|---|---|---|---|
| **A. 资源投稿** | 作品**已存在于探索库**（官方或他人发布） | 探索详情页 → 【上传】 | 仅 `game_resources` | 「上传」 |
| **B. 作品发布** | 作品**不存在于探索库** | 探索大厅 → 文档板块 → 【发布】 | 先 `games`，再 `game_resources` | 「**发布**」 |

> 🔴 **数据落点完全不同，不可混用**：A 只写 `game_resources`；B 先写 `games` 再写 `game_resources`。
> 但**第三步的表单与提交逻辑完全一样**（同一个 `UploadResourceDialog` + `createCommunityResource`）
> —— 这正是「B 的第三步 = 探索详情页上传」的实现方式。

#### ② 三步流程

| 步 | 内容 | 落点 | 说明 |
|---|---|---|---|
| **1. 输入游戏名** | **完全在文档板块内**完成（**不弹窗**）。输入名称 → 点「下一步」 | 无（仅查询） | 🔴 调 `games` list，filter `title ~ "<输入>"`（PB `~` = 模糊包含）<br>**命中** → 提示「探索库中已有《X》」+「前往上传资源」按钮（进该作品详情页 → 【上传】）<br>**未命中** → 继续第 2 步 |
| **2. 填写游戏数据** | 弹「**发布 Galgame**」窗口。第 1 步的游戏名作 `title`；别名（中文 / 英语 / 日语 / 繁中，**均选填**）；简介；封面；截图；会社；评分；评分人数；发售日期 | — | 复用 `MetadataSection` 一键抓取回填 |
| **3. 上传资源** | 资源链接 / 资源标题 / 体积 / 提取码 / 解压码 / 资源类型 / 语言 / 平台 | `game_resources` | **直接复用** `UploadResourceDialog` |

**提交顺序（不做跨集合事务，理由见下）**：

```
1) POST games          body = { origin:"user", owner:<uid>, review_status:"pending",
                                has_official:false, title, downloadUrl:"" , … }
2) POST game_resources body = createCommunityResource(game: <上一步返回的 id>, …)
   ⚠️ 第 2 步失败 → 不回滚作品，改提示
      「作品已提交，但资源上传失败，可在【我的】中补传」
```

> **为什么不做回滚**：PB 无跨集合事务；且「作品在、资源待补」是**合法状态**
> （与官方作品可以有作品无资源同构）。回滚反而会丢掉用户填好的整份游戏资料。

#### ③ 字段映射（第 2 步 → `games`）

| 表单字段 | PB 字段 | 现状 |
|---|---|---|
| 游戏名（第 1 步） | `title` | ✅ 已存在（required） |
| 日语名 | `originalTitle` | ✅ 已存在（`game_model.dart:14` 注释即「日语原标题」） |
| 英语名 | `englishTitle` | ✅ 已存在 |
| **繁中名** | **`traditionalChineseTitle`** | 🔴 **需新增字段**（§8.9-1） |
| 中文名（若与 `title` 不同） | — | ⛔ **不新增**：`title` 即中文名，避免同义字段 |
| 简介 | `description` | ✅ 已存在（editor） |
| 封面图 | `coverUrl` | ✅ 已存在（file，单） |
| 截图 | `screenshots` | ✅ 已存在（file，多） |
| 会社 | `Developer` | ✅ 已存在（⚠️ PB 里是**大写 D**） |
| 评分 / 评分人数 | `rating` / `voteCount` | ✅ 已存在（number） |
| 发售日期 | `releaseDate` | ✅ 已存在（text，`YYYY-MM-DD`） |
| 标签 | `tags` | ✅ 已存在（select 多选，`maxSelect:14`） |
| 元数据来源 | `metaSource` | ✅ 已存在 |

**客户端钉死的受控字段**（与 `createRule` 严格一致，思路同 `createCommunityResource`）：

```dart
'origin': 'user', 'owner': <当前用户 id>,
'review_status': 'pending', 'has_official': false,
```

#### ④ 入口：探索大厅「文档与趣味」板块

- **审计现状**：`lib/widgets/explore_hall/docs_section.dart`（`DocsSection` :21）为
  **左 4 tab（介绍 / 使用说明 / 通知 / 动态）+ 右随机一作**，**纯静态硬编码，无条目列表**。
- 新增【**发布**】与【**我的**】两个入口。
- 🔴 **第一步必须在板块内联完成**（不是弹窗）：板块内需内联一个「输入游戏名 + 下一步」小表单；
  仅当判重通过后才弹「发布 Galgame」窗口。
- ⚠️ 大厅页**不是跨 tab 常驻**（`main_container.dart:806` 在 `switch` 里直接 return），
  且**全仓无 `Navigator.push` 先例**（只有弹窗先例，如 `docs_section.dart:323`
  `GameDetailDialog.show`）⇒ **发布向导一律做成弹窗 / Overlay，不引入新路由**。

#### ⑤ 复用清单（审计得出，避免重复造轮子）

| 复用对象 | 位置 | 用途 |
|---|---|---|
| `MetadataFetcher.fetchGame(name)` | `lib/services/metadata_fetcher.dart:452` | 一键抓取元数据（返回 legacy Map，含 rating / vote_count / release_date / cover / summary / tags / developer） |
| `JoinController.selectScrapeResult` | `lib/pages/join/join_controller.dart:592` | 抓取结果回填表单的写法可照搬 |
| `showDarkCenteredDialog` | `lib/widgets/game_detail/dark_surface.dart:669` | 「发布 Galgame」窗口外壳 |
| `DarkShell` / `DarkField` / `DarkTextInput` | `dark_surface.dart:140/580/608` | 深色表单控件 |
| `_MultiSelectField` | `upload_resource_dialog.dart:866` | 标签 / 多选字段（现为私有，需提升为公共或复制） |
| `UploadResourceDialog` | `upload_resource_dialog.dart:45` | **第三步直接复用** |
| `createCommunityResource` | `lib/services/game_resource_service.dart:130` | 第三步提交 |

**需新建**：全仓无日期选择器（无 `showDatePicker`）⇒ `releaseDate` 用**文本输入 + `YYYY-MM-DD` 格式校验**
（与 PB 字段类型为 text 的事实一致，最小改动）。

---

### 8.8 【我的】管理页设计（新需求）

**入口**：探索大厅 → 文档板块 →【我的】（与【发布】并列）。

| 分区 | 数据源 | 可执行操作 |
|---|---|---|
| **我发布的游戏** | `games` filter `owner='<uid>' && origin='user'` | 编辑（规则放行：`owner=自己 && origin=user && review_status != approved`）／删除（`owner=自己 && origin=user`） |
| **我上传的资源** | `game_resources` filter `owner='<uid>'` | 编辑 / 删除（约束见 §8.6-②） |

**展示**：两个分区各自显示状态徽章（审核中 / 已通过 / 已驳回 + 驳回理由）。

> ⚠️ **与 §8.6 的关系**：【我的】是 §8.6 原「我的分享页」的**超集** ——
> 原计划只做「我上传的资源」，现扩展为「我发布的游戏 **+** 我上传的资源」两分区。
> ⇒ §8.6-③ 的 `lib/pages/my_contributions_page.dart` 改名为 **`lib/pages/my_works_page.dart`**，
> 内容按上表扩展。

---

### 8.9 服务端增量清单（发布所需 · **待批准执行**）

> ⚠️ 依据「动线上即需批准」的铁律，本节改动**需开发者确认后再执行**；执行前照例先 `Export` 备份
> （备份落 `.workbuddy/pb_backup/`）。

| # | 改动 | 现状 | 目标 | 风险 |
|---|---|---|---|---|
| 1 | `games` 新增 `traditionalChineseTitle`（text） | 不存在 | 承载「繁中名」 | 🟢 纯新增，零破坏 |
| 2 | `games.downloadUrl` **`required: true` → `false`** | **必需** | 可空 | 🔴 **不改则用户发布必 400** —— 用户作品本就没有官方下载路径；既有 298 条均已填值，行为不变 |
| 3 | `lock_fields.pb.js` 扩展 | 仅锁 `contributors` 等 | `games` 分支**增锁 `origin` / `review_status` / `has_official` / `owner` / `creator_name`** | 🟠 建议与 v5（§8.6-⑤-1）**合并成一次部署** |

**已就绪、无需改动**（重要发现）：`games` 的 `createRule` / `updateRule` / `deleteRule`
**早已按「用户发布」写好**（原文见本文件 §3.2）：

```
createRule = @request.auth.id != "" && @request.body.origin = "user"
          && @request.body.owner = @request.auth.id && @request.body.review_status = "pending"
updateRule = owner = @request.auth.id && origin = "user" && review_status != "approved"
deleteRule = owner = @request.auth.id && origin = "user"
```

> 🔴 `updateRule`：**`review_status` 一旦 `approved`，用户就不能再编辑**（改则 404）
> —— 与 `game_resources` 的「已发布不可编辑」完全同构。
> 【我的】页必须据此**禁用编辑入口并说明原因**（⛔ 不做静默禁用）。

---

### 8.10 实施顺序与决策点（并入原 §8.6 三步走）

| 序 | 任务 | 依赖 | 状态 |
|---|---|---|---|
| 0 | 标线修复 | — | ✅ `0c00ad2` |
| 1 | 浮层兜底清扫（§8.5①） | ✅ 已批准（2026-10-01 下午） | ✅ `bd1673d`（`animated_overlay` 一处兜底 8 个浮层；§8.5② 19 处经精确核查全部安全，无需补） |
| 2 | 数据层：`GameModel` 补字段 + `GameResourceService` 增方法 | 无 | ✅ `f9f33bb` |
| 3 | 服务端增量（§8.9 三项） | ✅ 已批准 | ✅ **已执行**：`games` 27 → **28 字段**（新增 `traditionalChineseTitle`）+ `downloadUrl.required` → `false`；既有数据 `totalItems` 仍 298，零字段丢失 |
| 4 | 【发布】三步链路（§8.7） | 2 + 3 | ✅ `21f54cf`（组件）+ `f7a99dd`（接线） |
| 5 | 【我的】管理页（§8.8） | 2 | ✅ `21f54cf` + `f7a99dd` |
| 6 | 统计路由（§8.6-⑤-3） | 无 | ✅ **已上线验收通过**（开发 `c27a113` → 根因修复 v6 `f49f351` → 2026-10-01 深夜线上探针全绿，见 §8.13-⑥ / §8.14） |
| 6.5 | 🔴 **文档板块崩坏修复**（v4.6 新增 · 开发者真机反馈） | 4 + 5 | ✅ `c867cb8`（详见 §8.13-①） |
| 7 | Phase 3：`contributors` 归属 + 举报 | 4 | ⏸（开发者明确本轮不做） |

**待决点处置结果（一 · 2026-10-01 下午，开发者答复：批准 1、2、5 + 同一窗口分页）**：

| # | 决策 | 结论 | 落地 |
|---|---|---|---|
| 1 | 编辑**已驳回投稿**的状态复位 | ✅ **走 A 方案**（2026-10-01 傍晚批准并实施） | 服务端 `lock_fields` v5 加唯一白名单转换；客户端 `updateMine(resubmit: true)` 显式补 `status: 'pending'`。见 §8.13-③ |
| 2 | §8.5① 浮层清扫 | ✅ **批准** | `bd1673d` |
| 3 | 统计路由是否本轮做 | ✅ **本轮做**（2026-10-01 傍晚批准并实施） | `c27a113`；🟡 待部署，见 §8.13-④ / §8.10-序 6 |
| 4 | `games.downloadUrl` 改非必需 | ✅ **批准** | 已执行（见序 3） |
| 5 | 【发布】第 2 / 3 步承载 | ✅ **同一窗口分页** | `publish_game_dialog.dart` 内 `_step` 0/1 分页，`UploadResourceDialog(embedded: true)` |

**待决点处置结果（二 · 2026-10-01 傍晚，开发者答复：「批准，现在实施并部署」）**：

| # | 决策 | 结论 | 依据 / 落地 |
|---|---|---|---|
| 1 | 编辑**已驳回投稿**的状态复位 | ✅ **跟着建议走 A** | 见上表 #1；服务端 v5 白名单是**唯一放行**，其余一律锁死（fail-closed） |
| 3 | 统计路由是否本轮做 | ✅ **本轮做**（"修复完文档功能之后就可以开始") | 本轮已完成开发（`c27a113`），**部署由开发者执行** |
| — | 🔴 **文档板块崩坏** | ✅ **已修** | 开发者强烈反馈后的最高优先级；`c867cb8`，见 §8.13-① |

> 📌 **A 方案对两侧的实际效果（开发者批准前已确认）**：
> - **对用户**：被驳回的投稿「编辑 → 保存」后**自动重新进入审核**（状态 `rejected → pending`），
>   无需删了重发；除此之外**任何**自己对 `status` 的改动仍会被服务端还原（包括控制台改包）。
> - **对开发者/管理员**：后台仍可任意改 `status`（超管豁免双通道不受影响）；
>   审核队列多一条「重提」来源，`updated` 时间变化即可识别。**无新增运维动作**。

---

### 8.11 实施记录（2026-10-01 下午 · 数据层 + 发布服务）

> **范围**：只写**不依赖服务端改动**的部分（§8.9 字段变更**待批准**，未执行）。
> 因此本轮**不含任何 UI**，也**未触碰稳定区**。

| 文件 | 改动 | 估计行数 |
|---|---|---|
| `lib/models/game_model.dart` | 新增 6 字段（`origin` / `ownerId` / `creatorName` / `reviewStatus` / `communityCount` / `traditionalChineseTitle`）+ 7 个语义 getter（`isUserWork` / `isReviewApproved` / `isReviewPending` / `isReviewRejected` / `canEditAsOwner` / `canDeleteAsOwner` / `aliasTitles`）；`fromPBRecord` 与 `copyWith` 同步补齐 | ~+110 |
| `lib/models/game_resource_model.dart` | 新增 `gameTitle`（从 `expand.game` 取，**兼容单条 / 列表两种形态**） | ~+30 |
| `lib/services/game_publish_service.dart` | **新建**：【发布】层 —— `searchByTitle`（判重）/ `publishGame`（含 multipart 文件上传，写法对齐 `game_detail_page` 截图回传）/ `fetchMyGames` / `updateMyGame` / `deleteMyGame` / `currentUserId` / `currentUserName` | ~370 |
| `lib/services/game_resource_service.dart` | 新增 `fetchAllMine`（跨作品 + `expand:'game'`）/ `updateMine` / `deleteMine`；`_query` 增 `perPage` / `expand` 参数 | ~+100 |
| `test/models/game_publish_fields_test.dart` | **新建**：覆盖来源 / 审核默认值、三态、**权限预判与 PB 规则逐条同构**、别名去重、expand 四种形态 | ~200 |

**设计要点（易漏）**：

1. `GameModel` 对 `origin` / `review_status` 缺字段时**兜底为 `official` / `approved`**
   ⇒ 既有 298 条记录行为**逐字节不变**。
2. `canEditAsOwner` / `canDeleteAsOwner` 与 `games` 的两条 PB 规则**逐条同构** ——
   因为规则不满足时 PB 返 **404 而非 403**，客户端必须预判。
3. `publishGame` 走两条通道：**有文件 → multipart POST；无文件 → SDK JSON create**。
   ⚠️ multipart 里 `bool` / `number` / `list` 必须自行序列化成字符串（PB multipart 只收 string）。
4. `updateMine` 直接复用 `GameResourceModel.toSubmitBody()` —— 它**刻意排除**
   被 `lock_fields` 锁定的 `kind` / `status` / `owner` / 三个计数字段。

**验证**（进程内 analyzer 探针；本环境禁建匿名管道，`flutter analyze` 不可用）：

| 范围 | 文件数 | errors |
|---|---|---|
| 本次改动 4 文件 | 4 | **0** ✅ |
| 全 `lib/` | 295 | **0** ✅（warnings 91，与改动前**同为 91** ⇒ 全为存量） |
| 全 `test/` + 新增用例 | 91 | **0** ✅ |

> ⚠️ `flutter test` **未执行**（本环境不可用，已知限制）⇒ **需开发者跑一次**确认新增用例通过。

**未做（等决策，见 §8.10-表）**：§8.9 服务端三项（不做则 `publishGame` 必 400）·
§8.5① 浮层清扫 ·【发布】三步 UI ·【我的】管理页 UI。

---

### 8.12 实施记录（2026-10-01 下午 · 服务端增量 + 浮层清扫 + 【发布】/【我的】UI）

> **批准依据**：开发者答复「批准 1、2、5。同一窗口分页」（§8.10-表）。
> **稳定区**：本条**未触碰**任何稳定区文件（`main.dart` / `main_container.dart` /
> `lib/theme/` / `portable_*.dart` / `app_state.dart` / `windows/runner/` / `luna_metadata_sdk/`）。

#### ① 服务端增量（§8.9 两项，已执行）

| 项 | 变更 | 结果 |
|---|---|---|
| 1 | `games` 新增 `traditionalChineseTitle`（`text`，非必需） | 27 → **28 字段** |
| 2 | `games.downloadUrl`：`required: true` → **`false`** | 用户作品无官方下载路径也能落库 |

- 执行前已 Export 备份：`.workbuddy/pb_backup/pre-publish-20261001-144053/games.json`。
- 按 id 保留既有字段，**零字段丢失**；变更后复核既有数据 `totalItems` 仍 **298**（匿名可见）。
- 脚本：`.workbuddy/pb_tmp/pb_publish_01_backup.py` / `pb_publish_02_apply.py`。

#### ② 浮层兜底清扫（§8.5①，已执行）

- `lib/widgets/animated_overlay.dart` 的 `build` 包一层 `Material(type: MaterialType.transparency)`
  —— 一处覆盖 **8 个调用方**（`main_container.dart:287/597/681/720` 安装中心 / 登录 / 设置 / 支付，
  以及 `background_image_editor_dialog` / `name_dialog` / `series_panel` / `theme_editor_dialog`）。
- 回源确认根因范围：`flutter/src/material/app.dart:1057` 把 `_errorTextStyle` 作为
  `WidgetsApp.textStyle` 传入，而 `WidgetsApp` 用它构造的 `DefaultTextStyle` 位于
  **Navigator / Overlay 之上** ⇒ 影响面覆盖**全部**浮层，不止最初发现的 3 处。
- §8.5② 的 **19 处裸 `OverlayEntry` 经括号配平精确核查，无一处需要补**（其内部 `Text` 要么显式带
  `style`，要么位于自带 `Material` 的 `SnackBar` / `AlertDialog` / `SimpleDialog` 内）。脚本：
  `.workbuddy/pb_tmp/check_naked_text.py`。**结论：本节收口，不再有残留。**

#### ③ 【发布】/【我的】UI（已实施）

| 文件 | 类型 | 内容 |
|---|---|---|
| `lib/widgets/game_detail/publish_game_dialog.dart` | 新建 | 「发布 Galgame」窗口：第 2 步（游戏资料）+ 第 3 步（资源）**同窗口分页**；含编辑模式 `showEdit` |
| `lib/widgets/explore_hall/docs_publish_tab.dart` | 新建 | 文档板块内联**第 1 步判重**（命中 → 引导去详情页【上传】；未命中 → 弹发布窗口） |
| `lib/widgets/explore_hall/docs_my_tab.dart` | 新建 | 【我的】：我发布的游戏 / 我上传的资源，两分区，支持编辑 + 删除 |
| `lib/widgets/game_detail/upload_resource_dialog.dart` | 改 | State 公共化 + `embedded` / `initial` / `submitLabel` 三个**可选**参数（默认值使既有【上传】行为逐字节不变） |
| `lib/widgets/explore_hall/docs_section.dart` | 改 | 标签 4 → 6；`_visitedTabs` 延迟构建；标签行 **`Row` → `Wrap`** |
| `lib/pages/explore_hall_page.dart` | 改 | 透传 `onOpenDiscoverGame: _forwardGameTap` |
| `test/explore_hall/explore_hall_layout_test.dart` | 改 | 新增 960×540 下 6 标签 + 【发布】/【我的】可进入的**溢出回归用例** |

**🔴 本节最重要的两点（踩坑记录）**：

1. **零稳定区改动**：判重命中要「跳到该作品探索详情页」，本以为必须动 `main_container`，
   实际 `ExploreHallPage` 早已有 `onGameTap → main_container` 详情页通道，
   新增一个 `onOpenDiscoverGame` 透传 `_forwardGameTap` 即可 ⇒ **不需要碰稳定区**。
   凡是遇到「感觉要动稳定区」的需求，先穷举是否已有透传通道。
2. **标签行溢出（本轮自引入的回归）**：左区内容宽度在最小窗口 960×540
   （`main.dart:488` 的 `minimumSize`）下仅 **≈194px**
   （右栏 flex 9/20 ⇒ 412px，减右区 40% ≈165px、两道 12px 间距与 1px 分隔线、板块外壳 14×2 内边距）
   ⇒ 原来 4 个标签刚好占满 ≈190px，**加两个必然 `RenderFlex` 溢出**。
   处理：标签行 / 卡片动作行 / 【我的】工具条**全部改 `Wrap`**；
   并补一条 960×540 的回归用例把「不溢出」钉死
   —— 既有 `explore_hall_layout_test.dart` 本就断言 `takeException() == null`，
   `RenderFlex` 溢出在 widget test 里会经 `FlutterError.reportError` 被 `takeException()` 捕获，
   **它正是现成的溢出探测器**。

**验证**（进程内 analyzer 探针；本环境禁建匿名管道，`flutter analyze` 不可用）：

| 范围 | 文件数 | errors | warnings |
|---|---|---|---|
| 发布链路 6 文件 | 6 | **0** ✅ | 0 |
| 全 `lib/` | **298** | **0** ✅ | 91（与改动前**同为 91** ⇒ 全为存量） |
| 全 `test/` | **90** | **0** ✅ | — |

> ⚠️ `flutter test` **未执行**（本环境不可用）⇒ **需开发者跑一次**，重点看新增的
> 960×540 文档板块用例与 `test/models/game_publish_fields_test.dart` 的 17 条。
> ⚠️ 真机走查未做：需确认【发布】三步链路、标线是否全消。

**未做（仍待决策）**：统计路由（`pb_hooks/resource_stats.pb.js`，不做则 `download_count` /
`like_count` 静默失败）· 编辑已驳回投稿的状态复位（方案 A / B）· Phase 3（`contributors` / 举报）。

---

### 8.13 实施记录（2026-10-01 傍晚 · 崩坏修复 + A 方案 + 统计路由）

#### ① 文档板块「彻底崩坏」的根因与修复（`c867cb8`）

**现象**：开发者真机反馈文档板块完全无法使用。

**根因（一行）**：v4.5 把标签行 `Row` → `Wrap`，但子项 `_SegmentPill` 内部是
`InteractiveWrapper`，其 `AnimatedContainer` 带 `alignment: Alignment.center`。
`Wrap` 传给子项的是**有界松约束**（`maxWidth: mainAxisLimit`），`Align` 会**直接撑满** ⇒
6 个标签各占一行、竖排 6 行，撑爆板块内容区（`RenderFlex` 溢出）。
`Row` 之所以安全，是因为它给非 flex 子项传 `maxWidth: infinity`。

> 🔴 **这个坑项目里早有明文注释** —— `game_detail/upload_resource_dialog.dart:627-630`
> 写着「不能写 `alignment: Alignment.center` …… 在 `Wrap` 里会撑满整行……用
> `Center(widthFactor: 1.0)` 让按钮按自身内容定宽」。**属于已知约定被漏用，不是新发现。**

**修法**：4 个胶囊组件**内部**包 `IntrinsicWidth`（tight 宽度 = 内容宽），
组件内收口后，以后谁放进 `Wrap` 都不会再崩：

| 文件 | 组件 |
|---|---|
| `docs_section.dart` | `_SegmentPill` |
| `docs_my_tab.dart` | `_segment` / `_miniAction` |
| `docs_publish_tab.dart` | `_pillButton`（在 `_notFoundPanel` 的 `Column` 里原本会被撑成通栏色块） |

**回归护栏**：`test/explore_hall/explore_hall_layout_test.dart` 增**宽度哨兵**
（`tester.getSize(pill).width < 120`；自然宽度上限约 60px、被撑满时 ≈194px）。

> ⚠️ **最重要的教训**：上一轮加的 960×540 用例**本该拦住这次崩坏**
> （溢出会让 `takeException()` 非 null），但它**从来没被跑过一次**
> （本环境禁建匿名管道，`flutter test` 不可用）。**跑不了的测试 = 没有测试。**

#### ② 【发布】交互对齐开发者澄清

| 场景 | v4.5 行为 | v4.6 行为（已改） |
|---|---|---|
| 判重**未命中** | **自动**弹出「发布 Galgame」窗口 | **不自动弹**，面板内给「继续发布」入口，点击才弹 |
| 判重**命中** | 点「前往上传资源」→ 打开详情页 | 打开详情页 **+ 自动弹出【上传】窗口** |

命中场景走 `GameDetailPage.pendingAutoUploadGameId` **一次性静态信号**
（`initState` 消费后立即清空）⇒ **零稳定区改动**，不需要动 `main_container`。

#### ③ A 方案：编辑已驳回投稿的状态复位（客户端 `1c83f2e` / 服务端 `c27a113`）

- **服务端** `lock_fields.pb.js` 升 **v5**：只放行唯一一种转换 ——
  `请求者 id 非空 && orig.owner === 请求者 && orig.status === "rejected" &&
  new.status === "pending"`；任一不成立或判定抛异常 ⇒ **保守锁死（fail-closed）**。
- **客户端** `GameResourceService.updateMine` 增具名参数 `resubmit`
  （默认 `false`）：为 `true` 时在 `toSubmitBody()` 之外**显式补 `status: 'pending'`**。
  ⚠️ `toSubmitBody()` 本身不含 `status` ⇒ **不显式发，白名单永不触发**。
- `docs_my_tab._editResource` 在 `status == rejected` 时传 `resubmit: true`，
  成功后提示「已重新提交，等待管理员审核」。

#### ④ 统计路由（服务端 + 集合 + 客户端）

**服务端能力**（`resource_stats.pb.js`，新建）：

| 路由 | 作用 |
|---|---|
| `POST /api/ct/resource/{id}/download` | `download_count += 1` |
| `POST /api/ct/resource/{id}/like` | 按 `(resource, user)` 去重后 `like_count += 1` |
| `POST /api/ct/resource/{id}/unlike` | 删除点赞记录 + `like_count -= 1`（不低于 0） |

三个路由均挂 `$apis.requireAuth()`；写库走 `$app.save()` / `$app.delete()`。
> 🔴 **「超管通道」的准确含义**：`$app.save()` 是**模型级**写入，**不经过请求级 hook**
> （`onRecordUpdateRequest`），所以不会被 `lock_fields` 拦下。

**服务端结构变更（已执行）**：新建 `resource_likes` 集合 `pbc_1167737304` ——
`resource` → `game_resources` / `user` → `users` / `created` autodate，
唯一索引 `(resource, user)`，5 条 API 规则全锁死（仅路由经超管通道写入）。
执行前全量备份 **13** 个集合定义 → `.workbuddy/pb_backup/pre-stats-20261001-155737/`；
执行后复核集合总数 **13 → 14**、既有集合**零改动**。

**客户端接线**：
- `ct_download_dialog._toggleLike`：纯本地乐观反馈 → **乐观更新 + `setLike`，失败回滚**；
  `initState` 经 `fetchMyLikedResourceIds` 回显点赞态。
- `game_detail_page._handleInstallTap`：下载前 `registerDownload` 打点（不 await、失败静默）。

> 🔴 **两处接线的前提**：`_officialResource?.record?.id` 非空。
> 官方【获取】走 `games.downloadUrl` **原生通道**，而 `game_resources` 的 official 记录
> 「有则补充、无则照旧」（当前线上 **0 条**）⇒ record id 为空时**不发请求**，
> 保持既有本地反馈行为，**零回归**；将来社区资源 UI 到位后自动生效。

#### ⑤ 🔴 `pb_hooks/` 首次纳入版本控制

此前 `.workbuddy/pb_hooks/` **从未被提交过**（`.gitignore` 只忽略 `/.workbuddy/memory/`），
导致服务端 hook 无历史、**回滚无据**。本次随 `c27a113` 一并纳入。

#### ⑥ 部署状态（✅ 2026-10-01 深夜全部验收通过）

- 我**只有 PB HTTP API 权限**，没有服务器文件系统权限 ⇒ **hook 文件必须由开发者覆盖 + 重启 PB**。
- 历轮部署（v1~v5）均失败（400 generic），**根因 = goja 顶层 `const` 在回调执行时不可见**
  （详见 §8.14）；**v6（零顶层声明全内联）本地开发实例 26/26 → 线上探针全绿**。
- 线上验收（2026-10-01 21:2x，探针 `probe_v5_stats.py`，零残留）：
  lock_fields 白名单放行 / fail-closed / 计数锁 ✅；ping 矩阵 7/7 ✅；
  download 累加 / like 去重 / unlike 回落 / 401 / 404 ✅；跨用户越权 404 拦截 ✅。
  （探针唯一 🔴 为断言过时假阳性：仍期望 v5 的"500 诊断"语义，v6 实际返显式 404——已按 v6 语义修正探针。）
- 部署包终版：`.workbuddy/pb_hooks_deploy_20261001_stats_v6.zip`（只含 `resource_stats.pb.js`）。

#### ⑦ 验证

- 进程内 analyzer 探针：改动文件 errors=0；全 `lib` **298** 文件 errors=0
  （warnings 91，与改动前持平 ⇒ 全存量）；全 `test` **90** 文件 errors=0。
- `node --check` 两个 hook 文件语法均通过。
- 服务端：建表前后复核集合总数与既有定义（见 ④）。
- ⚠️ **`flutter test` 本环境跑不了**（禁建匿名管道）⇒ 需开发者执行。
- ⚠️ **真机走查未做**：文档板块恢复、【发布】三步、A 方案重提、统计累加。

---

### 8.14 🔴 统计路由五轮失败根因定案 + 本地开发实例工作流（2026-10-01 深夜）

#### ① 根因：goja 顶层 `const` 在回调执行时不可见

- v1~v5 线上五轮全部 400 generic（`Something went wrong...`），五版行为矩阵曾误判为
  「`pathValue`/`findRecordById` Go panic 穿透」。
- **本地 PocketBase 0.34.2 开发实例**（`.workbuddy/pb_dev/`，与线上同版本二进制 +
  线上集合快照重建）首跑 7 条 ping 自诊断矩阵即复现并点名：
  `JS_ERR: RES_COLLECTION is not defined`（ping-3/4/6）——凡 handler 引用文件顶层
  `const` 必炸；ping-2/4 实测 `pathValue`/`findRecordById` 桥接**正常**（洗清嫌疑）。
- 全内联的 `lock_fields.pb.js` 一直正常 = 范本结构本来就没错，是 resource_stats 误学。
- **修复（v6 `f49f351`）**：hook 文件**零顶层声明**，常量/辅助函数全部内联进各 handler
  函数体；资源不存在改显式 404。本地 26/26 → 线上探针全绿。

#### ② 本地开发实例工作流（用户痛点解除）

- `pb_dev/`（gitignored）：`pocketbase.exe serve --http=127.0.0.1:8091 --dir=./pb_data_dev`，
  hooks 放 `pb_dev/pb_hooks/`（改后须重启）；`setup_collections.py` 一键重建集合
  （⚠️ 自引用 relation 须两段式：先建去字段版再 PATCH 补回）；`probe_local_v5.py` 全链路 26 断言。
- **部署-测试循环已内化**：今后 hook/服务端改动一律先本地全绿再出定版包，
  开发者只做「最后一次部署」。已沉淀技能 `pocketbase-local-dev`。

#### ③ Phase 2 服务端至此收官

| 服务端功能 | 状态 |
|---|---|
| lock_fields v5.1（A 方案状态复位 + 计数锁 + 越权防护） | ✅ 线上验收 |
| resource_stats v6（download/like/unlike 计数） | ✅ 线上验收 |
| 注册验证码（request/verify-register-otp + SMTP 465） | ✅ 线上运行 |

剩余 ⇒ 见 §13「主线收官清单」。

---

## 13. 主线收官清单（2026-10-01 深夜 · Phase 2 验收后）

| # | 事项 | 执行者 | 状态 |
|---|---|---|---|
| 1 | 真机走查：文档板块 / 【发布】三步流 / 驳回投稿重提（A 方案）/ 下载+点赞计数 / 「报告失效」举报 | 开发者 | ✅ **用户完成**（2026-10-01 深夜实测确认；走查发现署名缺失 → v8 修复，见 §13.2） |
| 2 | Phase 3：`contributors` 归属 + 举报（§5.3 归属保留机制） | AI 审计→批准→执行 | ✅ **已上线验收**（2026-10-01 线上探针 22/22 全绿：转正写入/幂等/举报全语义/懒建集合/计数锁/零残留，见 §13.2） |
| 3 | ~~`big_picture_discover.dart:582` 未解析直链（BPM 探索页安装必失败，P0）~~ | — | ⛔ **产品决策作废（2026-10-01）**：BPM 大屏模式**整体走本地、纯沉浸式游玩，不做云端功能/探索页界面** ⇒ 不属本方案；BPM 内云端入口精简为后续独立优化，待用户提出 |

### 13.1 Phase 3《变更计划》（2026-10-01 深夜 · 阶段 A 只读审计产出）

> ✅ **已按推荐实施（2026-10-01 深夜批准并执行完毕）**：
> 服务端两 hook 本地实例 **23/23 全绿**（含 resource_reports 懒创建实测）；
> 客户端 `reportResource` + 分享详情「报告失效」接线，进程内 analyzer **errors=0**（5 warning 全存量）。
> ✅ v7 已部署并**线上验收通过**（2026-10-01，`probe_phase3_prod.py` 22/22：official 创建触发
> contributors 写入且二次转正幂等、举报计数/去重/幂等/401/404/400、`resource_reports` 集合
> **懒创建线上实证**（部署后 ABSENT → 首次举报后 EXISTS）、report_count 计数锁、探针数据零残留
> 且基线复核一致 298 games 不变）。

> 依据 `AGENTS.md` §2.2：审计产出原文如下（决策点 3 项均按推荐落地）。
> 审计基准：线上 v6 已验收（§8.13-⑥）；本地 pb_dev 实例 26/26 可用；git HEAD = `844de87`。

#### ① 现状盘点（只读审计结论）

| 项 | 现状 |
|---|---|
| `games.contributors`（json） | ✅ 字段已在（28 字段内）；`lock_fields` 已锁；**全库无写入方** |
| `game_resources.report_count` | ✅ 字段已在；`lock_fields` 已锁；**无路由、无 UI**（grep 零命中） |
| `GameResourceModel.ownerName` | ✅ 已解析（`displayOwnerName` 已区分看板娘署名语义） |
| 客户端 contributors 渲染 | 按方案 §5.3 定案 **v4 不接入**（权益未定案，避免语义债）⇒ Phase 3 客户端零渲染改动 |

#### ② 任务 A：contributors 转正自动写入（服务端 hook · 对应 §5.3）

- 新文件 `promote_contributors.pb.js`：`onRecordCreateRequest("game_resources")`
  且 `kind == "official"` 时，在 `e.next()` 落库之后：
  1. 查该 game 的全部 community 来源（**范围 = 仅 `published`** —— 决策点 1）；
  2. 收集 owner 集合 → 按 §5.3 结构组装（最早 `created` 者标 `first_submitter`，
     其余 `contributor`；`contributed_at` 取各自记录 `created`；`resources` = 记录 id 清单）；
  3. 与现有 `contributors` json **合并去重**（同 user 已在 ⇒ 仅追加 resources，不重复加人）；
  4. `$app.save()` 模型级写回 `games.contributors`（**超管通道**，不触发 lock_fields，天然合规）。
- 失败仅 `console.log`，不影响创建响应（转正主流程零阻塞）。
- ⛔ 纪律：**零顶层声明**（§8.14 教训）；本地实例探针先行。
- 客户端：**零改动**。

#### ③ 任务 B：举报机制（字段已在，补路由 + 防重 + 入口）

- 服务端：
  - 新集合 `resource_reports`（resource+user 唯一索引、5 规则锁死，仿 `resource_likes`）—— 决策点 2；
  - 新文件 `resource_report.pb.js`（独立文件，单一职责）：`POST /api/ct/resource-report?id=<资源id>`
    （登录）：查重 ⇒ 已举报幂等 200；新举报 ⇒ 建记录 + `report_count` 原子自增（dbx SQL）。
- 客户端：
  - `GameResourceService.reportResource(resourceId)`；
  - UI：分享详情页（`share_detail_dialog.dart`）加「举报」入口——最小实现：
    图标入口 + 确认弹窗 + `SnackBar` 反馈 + 会话内已举报禁用（决策点 3）。
- 举报数 v0 **不展示**（仅管理后台参考）。

#### ④ 决策点（3 个 · 附推荐，批准时可直接说「按推荐」）

| # | 决策 | 推荐 | 理由 |
|---|---|---|---|
| 1 | contributors 统计的 community 来源范围 | **仅 `published`** | 审核通过 = 有效贡献；pending 可能被拒、rejected 是未通过；个案可后台手工补 |
| 2 | 举报防重 | **建 `resource_reports` 集合** | 服务端硬防重 + 可审计（谁举报了什么）；仅靠客户端禁用不可靠 |
| 3 | 举报 UI 范围 | **最小实现**（详情页入口+确认+幂等反馈） | v0 够用；"我的举报"列表等一律不做 |

#### ⑤ 实施顺序（批准后）

1. 本地实例：建 `resource_reports` 集合 + 写两个 hook → 探针扩断言 → 本地全绿；
2. 客户端：service 方法 + 举报 UI → 进程内 analyzer → 开发者终端跑 `test`；
3. 一任务一 commit → 定版包 v7（`promote_contributors.pb.js` + `resource_report.pb.js` + README）；
4. 开发者**一次性部署** → 线上探针验收 → 方案全案收官。

#### ⑥ 实施记录（2026-10-01 深夜 · 已按推荐执行完毕）

| 项 | 落地 |
|---|---|
| 决策 1/2/3 | 全部按推荐：published-only / 建 `resource_reports` 集合 / 举报 UI 最小实现 |
| `promote_contributors.pb.js` | `onRecordCreateRequest("game_resources")` 且 kind=official → 查该 game 全部 `published` community 来源（sort=`created` 升序）→ contributors 合并去重（同 user 仅追加 resources）→ 首位无 `first_submitter` 时补标 → `$app.save()` 模型级写回；无贡献者不写回；异常仅 `console.log` |
| `resource_report.pb.js` | `POST /api/ct/resource-report?id=`（requireAuth + uid 双通道 + query 取参）：查重 → 重复幂等 200 `duplicate:true` 不计数；新建记录 + `report_count` dbx 原子自增；404/400 显式语义；**集合懒创建**（`ensureReportsCollection`：查不到即 `new Collection` + save，线上零手工建表） |
| 客户端 | `game_resource_service.dart` +`reportResource`（复用 `_postStatRoute`）；`game_detail_page.dart` 分享详情「报告失效」→ `_handleResourceReport`（登录预判 + `showConfirmDialog` + SnackBar；`CtDownloadDialog`「反馈」保持占位） |
| 本地验证 | `probe_local_phase3.py` **23/23**：转正写入（A=first_submitter/B=contributor）· 二次 official 幂等不重复 · 举报计数/去重/幂等/401/404/缺 id 400 · 计数锁 · 清理零残留；**懒创建实测**：删除集合后首次举报自动重建（服务端日志 `auto-created collection resource_reports`） |
| 静态检查 | 进程内 analyzer：两改动文件 **errors=0**（5 warning 全为存量，位于 306-371 行历史代码） |
| 探针踩坑修正 | `findRecordsByFilter` sort 参数是 PB 语法 `"created"`（非 SQL `"created asc"`，服务端日志直接点名）；published 资源被 `updateRule` 拦 404 ⇒ 计数锁用例改用独立 pending 资源 |

> ✅ **已上线验收**（2026-10-01）：v7 部署后 `probe_phase3_prod.py` **22/22 全绿**
> （转正写入/二次幂等、举报全语义、`resource_reports` 懒创建线上实证、计数锁、零残留、基线一致）。

### 13.2 真机走查 · 署名修复 v8 · BPM 产品决策（2026-10-01 深夜 · 收官记录）

- **真机走查**：开发者完成走查并确认通过（分享弹窗 / 发布 / 驳回重提 / 计数 / 举报主流程；
  剩余打磨后续另行提出）。
- **走查发现并修复（`c59547f`，v8）**：分享弹窗显示「匿名分享者」——根因三连：
  ① 发布流提交体漏传 `owner_name`；② 头像从未接线（`AvatarCircle` 写死 null）；
  ③ 实测普通用户视角 `expand=owner` 被 users 规则拦成空 ⇒ 署名/头像只能走**发布时快照**。
  修复：新 hook `resource_owner_name.pb.js`（创建时空快照自动回填、显式传值不覆盖）+
  `game_resources` 加 `owner_avatar` 快照字段（线上已加、原定义已备份）+
  客户端提交快照与两个分享弹窗接线；存量《游戏本体》已补 HardMan + 头像。
  **v8 线上验收 `probe_v8_signature_prod.py` 12/12 全绿**（自动回填/显式保留/零残留）。
- **🔴 产品决策（开发者 2026-10-01 明确）**：**BPM 大屏模式整体走本地，主打沉浸式游玩体验，
  不做云端功能、不做探索页（云端界面）功能**。⇒ 原挂账「BPM 探索页直链 P0」**作废**；
  BPM 内若残留云端入口，其精简/移除属后续独立优化，待用户另行提出。

---

## 14. 主线补完：界面功能缺口审计与变更计划（2026-10-02 · 已批准实施完毕，Phase 2 已上线验收 ✅）

> 背景：全案收官后开发者真机实测发现「界面上很多功能并未实现」——点赞无反馈、个人分享
> 无下载次数。本节为全面排查结论与修复计划。**开发者补充的产品定义**：
> **个人分享的「下载次数」= 该资源「获取链接」（打开链接）的点击次数，点一次 +1。**

### 14.1 审计结论（缺口清单，均含 文件:行号 证据）

| # | 缺口 | 证据 | 服务端依赖 |
|---|---|---|---|
| 1 | 详情页头部**「喜欢」按钮纯本地反馈**：不落库、无计数、刷新即丢 | `game_detail_page.dart:124`（注释「本轮仅本地乐观反馈，不落库」）、`:1134-1141`、`game_detail_header.dart:260` | 🔴 **有**（见下） |
| 2 | 社区分享**「打开链接」点击不上报 download 计数** | 全库 `registerDownload` 唯一调用点 = `game_detail_page.dart:682`（官方安装链路）；`_openResourceLink`（`:1176-1185`，分享列表/分享详情/分享区「打开链接」的**唯一汇聚点**）无打点 | ❌ 无（路由已线上验收，纯客户端接线） |
| 3 | **「我的」tab 不显示**每条分享的下载量 / 点赞数 | `docs_my_tab.dart` 全文无 `downloadCount/likeCount` 数值 UI（仅 :441/:705/:786 三处文案提及）；资源卡 `:387-423` 只有状态徽章+标题+日期 | ❌ 无（字段已有，列表 API 已返回） |
| 4 | 详情页**「反馈」按钮为占位** | `game_detail_page.dart:1144-1146`「反馈入口开发中」 | 视产品决策 |
| 5 | 官方安装链路 `registerDownload`（`:682`）**实为死代码** | 🔴 线上实测 `game_resources` **official 记录 = 0 条**（2026-10-02 匿名 API 实查）——`_officialResource?.record?.id` 恒空 | 无害，保留（未来补建官方记录即自动生效） |

> 🔴 **缺口 1 的根因是产品级**：点赞/计数挂在 `game_resources` 上，而**298 条官方作品全部
> 没有资源记录**（official 记录 0 条，官方「获取」走 `games.downloadUrl` 原生通道）。
> ⇒ 详情页「喜欢」要真实落库，必须做 **games 级点赞**（服务端扩容）。

### 14.2 变更计划

#### Phase 1（纯客户端，立即可做，一个 commit）

| # | 改动 | 文件 | 说明 |
|---|---|---|---|
| 1 | 「打开链接」点击上报计数 | `game_detail_page.dart` `_openResourceLink` | 入口统一汇聚点，**一处接线覆盖分享列表卡 / 分享详情 / 详情页分享区**全部入口；`registerDownload(r.id)` 静默失败不阻塞（服务端 401 语义 = 未登录不计，登录用户点一次 +1，符合开发者定义） |
| 2 | 「我的」tab 资源卡加计数显示 | `docs_my_tab.dart:414-423` 附近 | meta 行加「下载 n · 点赞 m」（数据 `r.downloadCount` / `r.likeCount`，模型已解析）；显示样式对齐卡片现有 10.5-11px 弱化文字 |

#### Phase 2（games 级点赞——**需服务端**，走本地实例工作流）

服务端（本地 8091 实例开发 → 探针全绿 → 定版包 → 开发者部署 → 线上探针）：

1. `games` 加 `like_count`（number，默认 0）；`lock_fields` v10 锁定（fail-closed，超管豁免通道照旧）。
2. 新建 `game_likes` 集合（`user` + `game` 唯一对；list/view 规则 = 本人可见——与 `resource_likes` 同策略）。
3. Hook 路由扩展：`/api/ct/game-stats/like?id=<games id>` / `.../unlike`（形态对齐 resource_stats v6：
   零顶层声明、requestInfo().query、dbx 原子自增、显式 404、ping 自诊断）。语义同资源级：
   按 (user, game) 去重、重复 like 幂等、unlike 回落、未登录 401。
4. 定版包 + 线上探针脚本（对齐 §8.14 流程）。

客户端（Phase 2 服务端上线验收后）：

5. `game_resource_service.dart` 加 `setGameLike(gameId, liked)` / `fetchMyLikedGameIds([ids])`（形态对齐资源级 :391/:415）。
6. `game_detail_page.dart` `_handleLikeTap`（`:1134`）接线：登录/本地态守卫（统一文案「该功能需要登录账号后使用」）→ 乐观更新 + 失败回滚；`initState` 回显点亮态；头部「喜欢」图标旁显示 like_count（`game_detail_header.dart:259-260` 最小改动：数字徽标或计数文字）。
7. 删除「本地标记，暂未同步云端」临时文案（`:1139`）。

#### 明确不做 / 不动

- 获取弹窗的**资源级**点赞（`ct_download_dialog`）不动——与作品级「喜欢」语义不同（赞这条分享 vs 喜欢这部作品），并存。
- 缺口 5 死代码保留；缺口 4「反馈」按钮待拍板（见下）。
- BPM 侧零改动（产品决策：纯本地）。

### 14.3 待开发者拍板（3 项）

1. **「喜欢」做 games 级**（Phase 2 的存在理由）——不做则按钮永远无真实反馈。**推荐做**。
2. **「反馈」按钮**：a) 本轮接官网反馈入口（跳转官网对应页面）b) 保持占位 c) 移除按钮。**推荐 a**（成本一行 launchUrl，语义成立）。
3. **未登录/本地态点「喜欢」**：统一提示文案（现状策略，不主动弹登录框）还是引导直达登录浮层（本地账号方案的遗留增强）？**推荐前者**（本轮保持一致，引导增强另行排期）。

### 14.4 实施状态（✅ 2026-10-02 16:1x 开发者批准，按推荐默认执行）

> **拍板结果**：三项均按推荐——①做 games 级点赞；②「反馈」接官网反馈通道；
> ③未登录/本地态统一提示文案。

**Phase 1（纯客户端）——✅ 已实施**

| # | 改动 | 落点 | 状态 |
|---|---|---|---|
| 1 | 「打开链接」计数打点 | `game_detail_page.dart:1198-1204` `_openResourceLink`：openExternal 成功后 fire-and-forget `GameResourceService.registerDownload(r.id)`（风格对齐 `:682` 官方链路打点；不 await、失败静默） | ✅ |
| 2 | 「我的」tab 计数显示 | `docs_my_tab.dart:426` meta 行追加「下载 n · 赞 m」（`r.downloadCount`/`r.likeCount` 模型已有） | ✅ |
| 3 | 「反馈」按钮接线 | `game_detail_page.dart:1146-1153` `_handleFeedbackTap`：跳 `https://github.com/HardManOfficial/Chrono-Tide/issues`（**官网 faq.html 的用户引导即此地址**，语义对齐）；官方下载浮层 `onReport`（`:1048`）同方法自动受益 | ✅ |

> ⚠️ **并行会话撞车记录**：改动 #1/#3 落盘后、Phase 1 提交前，并行会话（本地账号
> 权限补漏）于 16:21 提交 `3f5a5d0` 时把 `game_detail_page.dart` **整文件 git add**，
> 两处改动随之入库。**不回滚**（避免影响并行会话）；该 commit 信息未提及此二改动，
> 在此补记。Phase 1 实际 commit 只含 `docs_my_tab.dart` + 本文档 + DEV_LOG。

**Phase 2（games 级点赞）——✅ 已上线验收通过（2026-10-02 16:4x 实施 → 16:5x 部署 → 线上探针 29/29 全绿）**

| 层 | 产物 | 状态 |
|---|---|---|
| 迁移 | `.workbuddy/pb_migrations/1790990000_updated_games_like_count.js`（games 加 like_count，number 默认 0，存量自动 0——列定义 `NUMERIC NOT NULL DEFAULT '0'` 已实测）+ `1790990010_created_game_likes.js`（game_likes：id `pbc_1167737315`，(game,user) 唯一索引） | ✅ 本地迁移跑通 |
| Hook | `.workbuddy/pb_hooks/game_stats.pb.js`（🆕 like/unlike 路由 + gstats-ping 1..7，零顶层声明，形态对齐 resource_stats v6）；`lock_fields.pb.js` v7（games 块 `lock("like_count")`） | ✅ 本地 29/29 探针全绿（`pb_dev/probe_local_game_likes.py`） |
| 定版包 | `.workbuddy/pb_hooks_deploy_20261002_game_likes_v11.zip`（4 文件 + README；编号接 v9 统一审核 / v10 邮件——§14.2 原文写"v10 锁定"与已占用编号撞车，顺延 v11） | ✅ 开发者 2026-10-02 已部署 |
| 线上探针 | `.workbuddy/pb_tmp/probe_prod_game_likes.py`（28 断言：schema/ping/主流程/回显/401/404/零残留；对真实作品临时 ±1 断言复原） | ✅ **29/29 全绿**（2026-10-02）：迁移生效（like_count=29 字段/number、game_likes 规则正确）、ping 1..7、对真实作品 hyzaww1e（base=0）like→count=1&liked→幂等→unlike→复原→幂等、回显 total 1→0、401×2/404 分支、探针账号删除 204 + 计数/点赞零残留 |
| 客户端 | `game_model.dart` +likeCount 解析/copyWith；`game_resource_service.dart` +`setGameLike`/`fetchMyLikedGameIds`（:442/:451）；`game_detail_page.dart` `_handleLikeTap` 重写（:1140 守卫→乐观±1→失败回滚）+ `_loadLikeState` 回显（:1177）+ 临时文案删除；`game_detail_header.dart` liked/likeCount 参数（:260 点亮实心 + 计数显示，`_buildIconAction` 可选 count 参数零回归） | ✅ analyzer 4 文件 errors=0 |

> 🔴 **与 §14.2 原计划的一处有意偏差**：`game_likes` 的 list/view 规则定为
> `user = @request.auth.id`（本人可见，供客户端回显），而非"与 resource_likes
> 同策略"（5 规则全 null）——resource_likes 全 null 导致其客户端回显静默失效
> （软缺陷），本轮不重蹈。写侧 create/update/delete 仍全 null（hook 超管通道）。
>
> ⚠️ 部署依赖：**hooks 与 migrations 必须一起部署**（README 已标注）；
> BPM 零改动（产品决策纯本地）；资源级点赞（ct_download_dialog）不动（语义并存）。

---

## 9. 风险与未决项

| # | 风险/未决 | 等级 | 建议 |
|---|---|---|---|
| 1 | ~~`games` 写入三栏为空 = 匿名可增删改全部 298 条数据~~ | ✅ **已闭环** | 规则已按 §3.2 填入。**2026-09-30 差分实测确认**：`games` 与 `game_resources` 匿名 `POST {}` 均返 `400 "Failed to create record."`，而规则放行的 `users` 匿名 create 能直达 Hook（返自定义消息）⇒ **400 = 规则拦截**，匿名写入已被挡住。 |
| 2 | ~~`games` 新增字段的默认值回填（298 条）~~ | ✅ **已闭环** | 已回填 `origin='official'` + `review_status='approved'`（298/298）；实测 `totalItems` 仍 **298** ✅ |
| 3 | ~~必须先加字段再改规则~~ | ✅ **已闭环** | 已按 3（字段）→ 4（规则）顺序执行，PB 无规则解析错误 |
| 4 | ~~`games` 规则改动前必须备份~~ | ✅ **已闭环** | 备份在 `.workbuddy/pb_backup/`（12 个文件，含集合定义 + 规则原文） |
| 5 | `direct` 直链的恶意内容风险 | 🔴 P0 | 已全量开放；**审核时重点核对域名/扩展名**；可删 Values 随时收回 |
| 6 | 未登录打开探索库看到空列表（既有缺陷） | 🟡 P1 | ✅ **选 B1 后自动解决**；若选 B2 则需独立排期补登录引导 |
| 7 | `owner_name` 冗余与昵称变更不同步 | 🟡 P1 | 可接受（历史署名语义）；如需同步，Phase 3 加 `users` 更新 Hook |
| 8 | `community_count`/`has_official` 冗余一致性 | 🟡 P1 | 写入时同步维护 |
| 9 | ~~`users` 集合的写入规则未核验~~ | ✅ **已闭环** | 实测确证原 5 条规则**全为空** ⇒ 可改/删任意他人账号。**已写入 5 条修复**（§9.1）；`listRule` 也已于 2026-09-29 深夜收紧为 `id = @request.auth.id` |
| 10 | `contributors` 用 json 的查询局限 | 🟢 P2 | 当前仅存储；如需按用户查贡献再升级为表 |
| 11 | 用户作品与预设作品**同名**展示歧义 | 🟢 P2 | 角标区分；详情页来源区明确 |
| 12 | 用户上传图片无压缩 | 🟢 P2 | 客户端压到 ≤1920px |
| 13 | 时间显示时区 | 🟢 P2 | `created` 是 UTC，展示前转本地（`toLocal()`） |
| 14 | ~~注册验证码（受 SMTP 阻塞）~~ | ✅ **已闭环** | SMTP 已打通（`smtp.qq.com:465 + tls=true`，已收到真邮件）；**并绕开 PB 内置 `request-otp` 的 P0 缺陷**（只对已注册用户发码）自建 `/api/ct/request-register-otp` + `register_otps` 集合。详见 `features/pb_setup_stepbook.md` 第 10–12 步。 |
| 15 | ~~Hook 未部署 / v2 未验证~~ | ✅ **已闭环** | v1 类型 getter bug → v2 已修复；**开发者重新部署后 AI 已实测确认生效**（§9.3） |
| 18 | ~~老用户 / 新用户分流（开发者策略）~~ | ✅ **已落地** | 老 180 用户**未动**、照常登录（实测错密码仍返 `Failed to authenticate.` 而非"未验证"）；新用户走 OTP，`require_otp_on_register` Hook **实测拦截无令牌注册**。详见 §9.4。 |
| 16 | **无请求限流**（原 `enabled:false`，5 秒可建 20 个号） | ✅ **已修** | 已启用：`*:create` = 3 次/60 秒；实测第 4 次起 `429` |
| 17 | 超管账号密码已明文出现在对话中 | 🟡 P2 | **建议立即改密码**（开发者已明确暂不处理） |
| 19 | ~~`has_official` 未回填，无法区分「有无官方来源」~~ | ✅ **已解决（2026-09-30 21:0x）** | 原 P0：298 条遗留作品全 `false` 但 `downloadUrl` 全非空 ⇒ 分不出"有无官方来源"。**方案 A 已执行完毕**：298 条 `origin=official` 置 `true`，`totalItems` 恒 299，唯一 `false` = 测试作品（`origin=user`）⇒ `has_official` 成为唯一的「可否一键安装」判据。 |
| 20 | ~~pb_hooks 超管判定失效（管理员建不了号）~~ | ✅ **已修，待重新部署** | 原「第四坑」的写法**是错的**：`e.requestInfo.hasSuperuserAuth()` 漏括号 → 恒判 false。已改为 `e.hasSuperuserAuth()` + `e.requestInfo().hasSuperuserAuth()` 双通道兜底。详见 `pb_setup_stepbook.md`。 |
| 21 | 🔴 **统计路由 + Hook v5 未部署**（线上仍跑 v3） | 🟡 **P1 · 待开发者操作** | 我已无服务器文件系统权限 ⇒ 部署包 `.workbuddy/pb_hooks_deploy_20261001_v5_stats_only.zip`（只含 2 文件）+ 指引 `.workbuddy/DEPLOY_HOOK_20261001_v5_stats.md`。**部署前**：`download_count` / `like_count` 静默失败（`lock_fields` 拦下）、A 方案白名单不生效（重提不复位）。**部署后**须做两侧对照探针实测（指引 §三）。 |
| 22 | 🔴 **Wrap 内 `InteractiveWrapper` 撑满整行**（曾致文档板块崩坏） | ✅ **已修 + 已加护栏** | `c867cb8`：4 个胶囊组件内部包 `IntrinsicWidth`。⚠️ **根因是已知坑被漏用**（`upload_resource_dialog.dart:627-630` 早有注释）⇒ 新增 UI 放进 `Wrap`/`Column` 前先确认子项不自撑宽。 |
| 23 | ⚠️ **回归护栏从未被执行**（跑不了的测试 = 没有测试） | 🟡 **P1 · 环境性** | 本环境禁建 Dart 匿名管道（`CreateFile failed 231` = `ERROR_PIPE_BUSY`）⇒ `flutter test` / `flutter analyze` 均不可用。**唯一可行解**：开发者在自己的终端跑 `flutter\bin\flutter.bat test`。 |

### 9.1 `users` 集合：实测确证的 P0 越权（2026-09-29 深夜）

**原状（改前）**：`listRule` / `viewRule` / `createRule` / `updateRule` / `deleteRule` **五条全为空**。

**探测方法（方法学修正，重要）**

| 方法 | 是否有效 | 原因 |
|---|---|---|
| 用「不存在的 id」测写操作 | ❌ **无效** | PB 对不存在的 id **一律先返回 404**，无法区分"规则拦"与"记录不存在" |
| 用「真实存在的他人 id」测 | ✅ 有效 | 能区分 `200`（放行）/ `404`（被规则拦）；**但有破坏性** |
| 用「探针账号可逆操作」 | ✅ 推荐 | 匿名注册临时账号 → 测它**本就有权做**的事（改自己/删自己）+ 越权动作 → 用完即删 |

**证据链**：匿名注册 → `201`（180→181）；该账号改自己 → `200`；**该账号改他人 → `200`（`description` 被写入）**；
**该账号删他人 → `204`**；匿名读名单 → `200` / 180 条。
⇒ **`updateRule` 与 `deleteRule` 均为空，越权成立**。

**修复后的 5 条规则（已生效）**

```
listRule    = @request.auth.id != ""    // 登录后可见名录（P1，待定是否收紧）
viewRule    = id = @request.auth.id     // 单条只能看自己
createRule  = (留空)                     // 有意开放注册
updateRule  = id = @request.auth.id     // 只能改自己
deleteRule  = id = @request.auth.id     // 只能删自己
```

**修复后复测**：改他人 `404` ✅ / 删他人 `404` ✅ / 读他人 `404` ✅ / 改自己 `200` ✅ / 读自己 `200` ✅ / 匿名读 `0 条` ✅

> 🔴 **必须理解的机制**：在 `updateRule = id = @request.auth.id` 下，改他人返回 **404 而非 403**。
> PB 是"**先按规则算出可见记录集，再施加操作**"——他人记录对你不可见 ⇒ 视同不存在 ⇒ 404。
> **404 = 已拦住**。所以**验收时不要等 403**。

**⚠️ 探测过程的事故记录**：为验证 `deleteRule`，探测账号**真的删除了真实用户 `HardMan`（`4j7g76vnbtfaa6t`）**。
已用超管按**原 id / 原 name / 原 emailVisibility** 重建；`description` 已清空。
**未能完全还原**：`created`（被重置为 2026-09-29，原 2026-04-25；autodate 字段 PATCH 无效）、
`avatar`（原为文件名，文件需重传）。**这是操作失误**——正确做法应是对**探测账号自身**做反向验证。
教训：**破坏性探测不得指向真实用户数据**。

### 9.2 注册验证码：能力已就绪，被 SMTP 阻塞（2026-09-29 深夜）

**已确认的服务器事实**：

| 项 | 值 | 影响 |
|---|---|---|
| PB OTP 能力 | `otp = {enabled: true, duration: 180, length: 6}` | ✅ 服务端就绪，`request-otp` 返回 `otpId` |
| SMTP | `smtp.enabled = false`，host 仍是 `smtp.example.com` | ❌ **邮件发不出** |
| 未配 SMTP 时 OTP 行为 | 接口对客户端返回 **200**，但 PB 日志 `lvl=8`（error） | 🔴 **静默失败** |
| 现有用户 `verified` | **180 / 180 全部为 `false`** | 🔴 **绝不能**开启"必须验证才能登录" |

> 🔴 **两条硬约束**：
> 1. **不得开启"必须邮箱验证才能登录"** —— 180 个老用户会**全部被锁死**，
>    且 SMTP 未配、他们收不到验证邮件。这等于**封禁整个用户群**。
> 2. **客户端必须校验 OTP 后续步骤**，不可因为 `request-otp` 返回 200 就认为"已发送"。

**落地方案（方案 C，开发者已选）**：验证码 UI 与"用户注册功能"一起做。
**届时唯一前置**：开发者提供一个支持 SMTP 的发件邮箱。

| 邮箱类型 | 需做的事 |
|---|---|
| QQ 邮箱 | 设置 → 账户 → 开启 **IMAP/SMTP 服务** → 获取**授权码**（16 位，**不是登录密码**） |
| 163 邮箱 | 设置 → POP3/SMTP/IMAP → 开启服务 → 获取授权码 |
| 企业邮箱 | 一般直接有 SMTP 地址 + 密码 |

拿到后我全自动配完并**实测发信**（配完会真发一封到指定邮箱验证）。

**同时已做的兜底**：启用**请求限流** —— `*:create` = 3 次/60 秒（实测第 4 次起 `429`），
把"无限刷号"降到"每分钟 3 个"，在验证码落地前先止血。

### 9.4 老用户 / 新用户分流策略（2026-09-29 深夜，开发者指定）

> **开发者原话**："针对这个老用户，我们不做处理……不用做验证，不用再让它重新去做验证，
> 就默认它这个账户是已经建立成功；但是新用户，也就是在我们开放完之后，这个新用户
> 就走我们的验证码流程。"

| 用户群 | 规模 | 处理方式 | 技术手段 |
|---|---|---|---|
| **老用户** | 现有 180 | **完全不动**，照常登录 | `authRule` **保持为空**；`verified=false` 不影响登录 |
| **新用户** | 开放后注册 | **必须过邮箱验证码** | 注册改两步（先 OTP → 再落库）+ create 阶段服务端兜底 |

🔴 **核心取舍（必读）**：PB 的 `authRule` 是**全局**开关。若开启"必须邮箱已验证才能登录"，
180 个 `verified=false` 的老账号会**立刻全部被锁死** → 直接违反策略。
**因此不开全局开关**，改为**只在注册路径做 OTP 校验**：老用户不走注册路径，天然不受影响。

**落地三步（SMTP 到位后由 AI 执行）**：

1. 配置 SMTP 并实测发信成功；
2. `users.createRule` 收紧 + `pb_hooks` 校验"注册请求必须携带有效 OTP 凭证"；
3. 客户端注册页改为两步：请求验证码 → 输入验证码 → 完成注册。

> ⚠️ **本策略的验收要点**：改完后需**同时**验证 ——
> ① 老用户（任抽 1 个既有账号）仍能正常登录；② 新注册不带验证码会被拒；③ 带正确验证码可注册成功。

### 9.3 pb_hooks 的 v1 bug 与修复（2026-09-29 深夜）

**现象**：`game_resources` 的**任何 PATCH 一律 `400 Something went wrong while processing
your request.`**，且**超管也同样报错** → 极易被误判为"权限问题"。

**根因**：v1 对字段用了**类型专用 getter**：

```js
e.record.set("owner", orig.getString("owner"));      // ❌ owner 是 relation 字段
e.record.set("created", orig.getString("created"));  // ❌ created 是 autodate 字段
```

`relation` / `select` / `json` / `number` 等类型用错 getter 会在 Hook 内部**抛异常**，
整个请求返回 400。`games` 侧恰好都用对口 getter，才没暴露。

**v2 修复**：统一改用**类型无关**写法：

```js
const lock = (name) => { e.record.set(name, orig.get(name)); };
lock("owner");
lock("created");
```

> 📌 **可复用规则**：pb_hooks 中还原字段值，一律用 `orig.get(name)` + `e.record.set(name, v)`；
> ⛔ **禁用** `getString` / `getNumber` / `getBool` 等类型专用 getter。

**v2 验证结果（2026-09-29 深夜，开发者重新部署后 AI 实测）**：

| 测试 | 结果 |
|---|---|
| `games` 探针改 `review_status: approved` | HTTP 200，落盘仍 `pending` ✅（自审通过被拦） |
| `games` 探针改 `origin: official` | HTTP 200，落盘仍 `user` ✅（提权被拦） |
| `games` 探针改 `title` | HTTP 200，正常生效 ✅（普通字段不受影响） |
| `game_resources` 探针改 `status: published` | HTTP 200，落盘仍 `pending` ✅（**v1 的 400 已彻底消失**） |
| `game_resources` 探针改 `kind: official` | HTTP 200，落盘仍 `community` ✅（提权被拦） |
| `game_resources` 探针改 `title` | HTTP 200，正常生效 ✅ |
| 数据复核 | games 298 / game_resources 0 / users 180 ✅（探针全清理） |

> ✅ **Hook v2 已确认生效**，第 6 步闭环。

> 📌 **探测方法学（两轮踩坑后总结）**：
> ① 用**临时探针账号**做可逆实验，测完即删；
> ② 必须让**探针自己创建**目标记录 —— 超管创建的记录 `owner=超管`，探针改它会被 `updateRule`
> 先拒成 **404**，请求根本进不到 Hook（本轮第一版脚本即因此全部返回 404，误判）；
> ③ 建记录须填**必填字段**（`games.downloadUrl`、`game_resources.title`），
> 否则 400 是**校验错误**而非权限问题，会误导结论。

### 9.5 🔴 `has_official` 未回填 —— 阶段一开工前必须定案（2026-09-30 发现）

**现象（实测）**：

| 事实 | 值 |
|---|---|
| 298 条遗留作品的 `has_official` | **全部 `false`** |
| 298 条遗留作品的 `downloadUrl` | **全部非空**（即全都有内置下载） |
| `games.downloadUrl` 是否必填 | **是**（`required: true`） |

**为什么这是阻塞项**：Phase 1 要按 §6.2 矩阵决定「渲染内置下载区 / 渲染用户分享区 /
卡片角标是『可安装』还是『用户分享』」，而矩阵的判定依据是**"有无官方来源"**。
现在两个候选判据都不可用：

- 用 `has_official` ⇒ 298 条全被判成"**无**官方来源" → 矩阵取错整行、角标全变「用户分享」；
- 用 `downloadUrl` 非空 ⇒ 因为该字段**必填**，用户作品也必然非空 → 分不出"纯用户作品"。

**根因**：第 3 步加字段时只做了 `origin` / `review_status` 的回填，
**漏掉了 `has_official`**（§2.3 明确它是"是否存在官方来源（冗余，列表快速判断'可安装'角标）"）。

**建议解法（二选一，推荐 A）**：

| 方案 | 动作 | 影响面 | 评价 |
|---|---|---|---|
| **A（推荐）** | 把 298 条遗留作品的 `has_official` 回填为 **`true`** | 仅 1 个布尔字段 × 298 条；不动 schema、不动 `origin`（保持§2.3 的"仅展示用途"语义） | ✅ 与 §2.3 字段设计意图一致；`has_official` 成为**唯一**的"可否一键安装"判据；用户作品保持 `false` 天然区分 |
| B | 客户端改用 `origin == 'official'` 当渲染门 | 零写库 | ⚠️ 与 §2.3「`origin` 仅展示用途」冲突；且"转正"时需改 `origin`，与 §5.3「新增 official 来源、不动既有记录」的流程不吻合 |

**✅ 定案：2026-09-30 20:4x 开发者批准 A 方案。**

**执行状态：✅ 已完成（2026-09-30 21:0x）**

**过程（含一次被拦 → 修复 → 重跑）**：

| 轮 | 步骤 | 结果 |
|---|---|---|
| ① | 超管令牌 PATCH 298 条 `has_official = true` | HTTP **200 × 298 / 失败 0**（32s） |
| ① | 立即读回复核 | 🔴 **仍全为 `false`** —— 写入被**静默还原**，无任何报错 |
| ① | 两侧对照（测试记录 `y6o7s8oa2dve8pz`） | PATCH `title`（非锁定字段）→ ✅ 生效；`has_official` / `origin`（锁定字段）→ ❌ 被还原 |
| — | ⇒ 定性 | `lock_fields.pb.js` **v2 对超管也无差别还原**，与它自身注释写的「只能由**超管**（后台/服务端）变更」**直接矛盾**。影响面**不止回填**：整条投稿审核链路（`origin` / `review_status` / `contributors`）均无法变更（含超管、含管理后台 UI）→ **P1** |
| ② | 修复 **v3**（双通道超管豁免）→ 开发者部署 → 探针复验 | ✅ 三组对照**全部生效**（`has_official` / `origin` / `title` 均可写），探针字段已完全还原 |
| ② | **重跑回填** | **HTTP 200 × 298 / 失败 0**（61s） |
| ② | **读回复核** | ✅ `has_official` = **{true: 298, false: 1}**；`totalItems` 恒 **299**；唯一 `false` 者 = 测试作品 `y6o7s8oa2dve8pz`（`origin=user`）—— **完全符合方案 A** |

> 📌 教训：**「锁字段」类 Hook 必须显式给管理员开豁免口子**，否则它会静默吃掉所有
> 服务端写入（**返回 200**），客户端侧几乎不可能发现。

**回填细则（不变，脚本已就绪）**：
- 脚本：`.workbuddy/pb_tmp/backfill_has_official.py --apply`（含干跑模式与回滚清单
  `backfill_has_official_manifest.json`）；
- 范围：**仅** `origin = "official"` 的 298 条 → `has_official = true`；
- 用户作品（`origin = "user"`，测试数据 `y6o7s8oa2dve8pz`）**保持 `false`**；
- 执行前后各复核一次 `games.totalItems`（须恒为 299，含 1 条测试作品）；
- 备份与回滚清单均已落盘于 `.workbuddy/pb_backup/` 与 `.workbuddy/pb_tmp/`。

> ⚠️ 这条**必须在 Phase 1 写"渲染分支"之前落地**，否则等代码写完再来回改判定依据，
> 等于把返工引到 UI 层。

---

## 10. 版本修正记录

### v4.9 → v4.10（2026-10-09 版本信息双字段展示修正）

| # | 变更 | 类型 |
|---|---|---|
| 1 | 🔴 **版本信息是两项而非一项**：云端 `games.version`（版本号）+ `games.versionNote`（版本说明）。此前弹窗只取 `versionLabel`（说明优先）⇒ 版本号永不显示 | **事实纠正** |
| 2 | 长「版本说明」原来塞进单行 `DarkBadge`（无宽度约束）⇒ 超宽被 `DarkShell` 裁掉右侧（真机反馈「显示不完整」）。改为 `Row + Expanded + Text` 整行换行完整展示 | **缺陷修复** |
| 3 | 版本号徽章上移到顶部徽章行、紧邻平台徽章（用户口径「放在 Windows 旁边」），颜色沿用紫（`badgeVioletBg`/`violet`） | 设计调整 |
| 4 | 验证通道：`flutter analyze` / `flutter test` 本机 231 → 进程内分析器（2 文件 0/0/0）+ 离线 flutter_tester 渲染探针（`.workbuddy/probe_version_info/`，13 PASS / 0 FAIL） | 验证方式 |
| 5 | 新增 `test/widgets/game_detail/ct_download_dialog_test.dart`（4 例） | 测试新增 |

> `OfficialResourceView.versionLabel`（`game_resource_model.dart:590`）改造后无调用点，保留待清理（不删公开 API）。

### v4 初稿 → v4.1（2026-09-29 22:0x 实测修正）

| # | 变更 | 类型 |
|---|---|---|
| 1 | 🔴 **修正 §3.1 关键事实**：`games` **并非公开可读**，实测匿名读 0 条（200 非 403）、`users` 180 条对照、错误码 404 | **事实纠错** |
| 2 | §3.2 改为"**先取规则原文再改**"，给出 B1（放宽）/B2（维持）两种落地方式 | 设计修正 |
| 3 | §4.2 表格拆为"方案 B 落地后 / 当前实测"两列，澄清现状 ≠ 目标态 | 表述修正 |
| 4 | §7.2 "零改动"结论**保留但理由重写**——因线上本就如此，非本次引入 | 逻辑修正 |
| 5 | §9 风险表重排：新增 #1（规则原文未知 P0）、#2（未登录空列表 P1）、#3（字段默认值回填 P0）；`pb_hooks` 风险已确认消除 | 风险更新 |
| 6 | 新增配套文档 `pb_setup_stepbook.md`（第 2/3/4/6 步逐条操作手册） | 交付物 |
| 7 | 已实测：`game_resources` / `app_config` 集合**不存在**（404），可安全新建 | 环境确认 |
| 8 | 已实测：PB 版本 **0.34.2** → `pb_hooks` 可用（第 6 步 Hook 无障碍） | 环境确认 |

### v3 → v4

| # | 变更 | 类型 |
|---|---|---|
| 1 | 三项配置**拍板定值**（可见性 B / 开放范围全量 / 权益暂不实现），新增 §1 集中定义 | 需求落实 |
| 2 | 风险面收敛：方案 B 使 §7.2 五处调用点零改动，P0 降级 | 风险下降 |
| 3 | 新增 §6.4「来源信息展示」：字段归属表 + 展示位置 + 文案对照 + 主题适配 | **新增需求** |
| 4 | `game_resources` 新增 `source_note` 字段（来源说明扩展位） | 字段新增 |
| 5 | `created` 明确为上传时间来源（不新增 `uploaded_at`），Hook 显式锁定 | 设计澄清 |
| 6 | `contributors_section` 在 v4 **不接入**（权益未定案，避免语义债） | 范围收窄 |
| 7 | 新增 §12《开发前置准备清单》 | **新增需求** |
| 8 | 新增时区处理未决项（风险 #11） | 遗漏补充 |

### v2 → v3

| # | v2 的问题 | 类型 | v3 处理 |
|---|---|---|---|
| 1 | 规则写了 `@request.auth.role = "admin"` | **逻辑冲突** | PB `users` 默认无 `role` 字段，静默失效 → **删除** |
| 2 | "未登录无法访问"被当作既有事实 | **事实错误** | 实测 `games` **公开可读** → 明确区分现状与目标 |
| 3 | 官方来源出现时用户分享"降为补充" | **表述含糊** | 改为 **"条目不减、永远渲染"** 硬约束 |
| 4 | 转正时未说明 community 记录去向 | **遗漏** | 新增 §5.3 归属保留机制 |
| 5 | 转正未限定"Add 而非 Replace" | **遗漏** | §5.3 明确禁止删除/替换/改 owner |
| 6 | `link_type` 未给出可配置方式 | **遗漏** | 新增可配置两级控制 |
| 7 | 未列出规则收紧的回归影响面 | **遗漏** | 新增调用点清单 |
| 8 | 审核依赖"未说明的自动化" | **遗漏** | 明确纯后台手工 |

---

## 11. 方案已定结论速查

以下为**已拍板、无需再议**的结论，作为后续开发的直接依据：

| # | 结论 |
|---|---|
| 1 | 可见性 = **B1**（`games` 的 List/View 放宽为 `@request.auth.id != "" \|\| review_status = "approved"`）—— 未登录可浏览已审核作品 |
| 2 | 指令类型 = **全量开放**（`netdisk`+`direct`+`other`），后台可删 Values 收回 |
| 3 | 分享者权益 = **暂不实现**，仅保留 `contributors` 数据能力 |
| 4 | 审核 = **管理员 PB 后台手工**，无自动流程、无审核页 |
| 5 | 来源共存 = **Add 不 Replace**，community 记录永不删除/隐藏 |
| 6 | 来源展示 = **每条来源标注 `@提供者` + `分享于 YYYY-MM-DD` + 可选说明** |
| 7 | 归属层级 = 提供者/时间/说明均为**来源级**（`game_resources`） |
| 8 | 上传时间 = **PB 内置 `created`**，不新增字段，Hook 锁定 |
| 9 | 展示位置 = 详情页**左列尾部**（`game_detail_page.dart:1146-1162` 后追加） |
| 10 | PB 版本 = **0.34.2**，`pb_hooks` **可用** |
| 11 | 🔴 **`games` 写入三栏必须填**（修补匿名可写漏洞，P0，上线前置条件） |
| 12 | 🔴 **顺序**：先加字段（第 3 步）→ 再改规则（第 4 步） |
| 13 | 🔴 **改规则前**：`games` 必须后台 Export 备份 |

---

## 12. 🆕 开发前置准备清单（你只需照做）

> ### 🟢 执行状态速览（2026-09-30 更新 · 实测核对）
>
> **第 0–5、7、8 步已全部完成并实测验收**；第 6 步为**暂定稿已出、待你的想法定稿**。
> **✅ Phase 1 UI 主体已于 2026-10-01 实施完毕（见 §8.2）** ——
> 详情页重构 + 4 个深色弹窗 + 数据层 + 主题令牌 + 看板娘账号 + 探索库角标全部落地，
> `analyze lib` 0 error、`test` 1070/1skip/0fail。**剩余：🔴 开发者部署 `lock_fields.pb.js` v4；
> 🟠 真机走查。**
> §9.5 已**定案为 A**（2026-09-30 20:4x 批准）；§8.1-⑤-2 的 `discover_page.dart` 冲突**已解决**
> （作为独立任务提交 `2da1e06`）。**两项阻塞均已解除**：`lock_fields.pb.js` **v3 已部署**、
> `has_official` **回填已完成**（§9.5）。**➡️ 前置工作全部就绪，可开工 Phase 1。**
>
> | 步 | 内容 | 状态 | 证据 |
> |---|---|---|---|
> | 0 | 环境预检 | ✅ | PB 0.34.2，`pb_hooks` 可用 |
> | 1 | 备份 PB 数据 | ✅ | `.workbuddy/pb_backup/`（12 文件，含集合定义+规则原文） |
> | 2 | 建 `game_resources` | ✅ | `pbc_439050043`，21 字段，实测存在（0 条） |
> | 3 | `games` 补字段 | ✅ | 已加 7 字段；实测单条含 `origin`/`review_status`/`community_count`/`contributors`/`has_official` 等 |
> | 3b | 回填 298 条 | ✅ | 实测 `totalItems = 298`，`origin='official'` + `review_status='approved'` |
> | 4 | 配置访问规则 | ✅ | 实测匿名读 `games` 返 200（B1 放宽）；匿名写 `games`/`game_resources` 均被拦（400） |
> | 5 | 部署 Hook | ✅ | `lock_fields.pb.js` v2 实测生效（自审/提权被拦，普通字段可改） |
> | 5e | **Hook 第四坑更正**（超管判定漏括号） | ✅ **已上线并实测** | 2026-09-30 12:2x 复核：超管直建用户 **200**（此前被自己的注册拦截挡住）；匿名无令牌注册 **400** |
> | **5b–5d** | 收紧名录 / 限流 / OTP | ✅ | `listRule=id=@request.auth.id`；`*:create` 3 次/60 秒；OTP 6 位/180 秒 |
> | **6** | **文案与视觉基准确认** | 🟡 **暂定稿已出，待你的想法定稿** | §6.4.5「暂定设计 v0」；已按「参考 KUNGAL + 先做大概设计」产出，7 个可替换点留给你的想法 |
> | **7** | **准备测试数据** | ✅ **已完成（AI 代做，2026-09-30 01:20）** | 2 测试账号 + 1 用户作品 + 4 条来源；**匿名可见 0 条**（零曝光）；见下方第 7 步 |
> | **8** | **明确验收标准** | ✅ **已接受（2026-09-30）** | 开发者确认接受 §8 三 Phase 验收条目 |
> | **A1** | **`has_official` 回填（§9.5 方案 A）** | ✅ **已完成（2026-09-30 21:0x）** | 298 条置 `true`；`totalItems` 恒 299，唯一 `false` = 测试作品。曾受阻于 `lock_fields` v2，修复 v3 部署后重跑成功 |
> | **A2** | **`discover_page.dart` 未提交改动（§8.1-⑤-2）** | ✅ **已解决（2026-09-30）** | 独立提交 `2da1e06`：`discover_page.dart` + `tags_popup_menu.dart`（2 文件 / +797 −108） |
> | **P1** | **Phase 1 UI 主体实施**（详情页重构 + 4 深色弹窗 + 数据层 + 主题令牌 + 看板娘 + 角标） | ✅ **已完成（2026-10-01）** | 见 **§8.2**；新增 11 文件 / 改动 6 文件；`analyze lib` **0 error**、`test` **1070/1skip/0fail**。🔴 待开发者部署 `lock_fields.pb.js` v4 |
>
> 📄 第 1–5 步的**逐条操作原文与实测记录**见
> `docs/DEV/features/pb_setup_stepbook.md`（含第 10–12 步的注册验证码闭环与验证方法论）。
> 🔴 **注意两套编号不同**：stepbook 的"第 6 步"= 部署 Hook；本清单的"第 6 步"= 文案确认。


> **使用说明**：以下 9 项按**执行顺序**排列。每项标注了 **交付物**、**格式**、
> **给我什么**（你完成后把该产物发我 / 或告诉我已完成）。全部完成后，
> **后续开发工作由我接手**，你只需在关键节点（Phase 收尾）验收。

### 第 0 步：环境预检（✅ **已完成**）

| 项 | 内容 |
|---|---|
| **结论** | ✅ PB = **0.34.2**（`{"message":"API is healthy.","code":200}`） |
| **推论** | **`pb_hooks` 可用**（v0.23+ 支持）→ 第 6 步 Hook 无障碍 |
| **附带给出的实测结论** | ① `game_resources` / `app_config` 集合**不存在**（404），可安全新建；② 🔴 `games` **匿名读 0 条** —— 规则**要求认证**，与稿子里的"公开可读"不符，**需你提供规则原文**（见第 2 步前置） |

### 第 1 步：备份 PB 数据（🟡 **部分自动完成**）

| 项 | 内容 |
|---|---|
| **已完成** | `users` 集合 **180 条**已由我方通过只读 API 导出至 `.workbuddy/pb_backup/users_anon.json`（31.7KB，含 id/name/avatar/verified/created/updated，**不含邮箱等敏感字段**） |
| **待你完成** | `games` 的备份——**因为 `games` 匿名读不到，我无法导出**，必须你在后台点 Export |
| **位置** | PB Admin UI → Collections → `games` → 右上 `Export` |
| **交付物** | `games` 集合的 JSON 导出文件 |
| **格式** | `.json` |
| **给什么** | 放本地即可，**只需告诉我"已备份 + 路径"** |

### 第 2 步：新建 `game_resources` 集合

| 项 | 内容 |
|---|---|
| **做什么** | 按 `pb_setup_stepbook.md` §2 的 18 个字段逐条添加 |
| **前置** | ✅ 已确认集合不存在（404），可安全新建 |
| **交付物** | 集合建成 |
| **给什么** | "已建好，字段 18 个"（或截图字段列表） |
| **验收** | 我据字段表逐项比对，无遗漏/类型错误 |

### 第 3 步：为 `games` 补齐新增字段（🔴 **必须先于第 4 步**）

| 项 | 内容 |
|---|---|
| **做什么** | 按 `pb_setup_stepbook.md` §3 新增 7 个字段 |
| **🔴 关键** | `origin` 默认值 `official`、`review_status` 默认 `approved`（保证 298 条既有记录行为不变） |
| **交付物** | 字段已加 + 后台总数仍为 **298** |
| **给什么** | "已加好，总数 298 未变" |
| **验收** | 我核对字段与默认值 |
| **⚠️ 阻塞关系** | 未完成本步**不得**进入第 4 步（List 规则引用 `review_status`，字段不存在会报解析错误） |

### 第 4 步：配置访问规则（🔴 **含修补 P0 漏洞**）

| 项 | 内容 |
|---|---|
| **前置** | ① 第 3 步已完成；② `games` **已后台 Export 备份**（§3.2.5） |
| **做什么** | 按 `pb_setup_stepbook.md` §4 填规则 |
| **🔴 重点** | `games` 的 **Create/Update/Delete 三栏当前为空 = 匿名可写**（实测确认），**必须填**；List/View 按 B1 放宽 |
| **交付物** | 两集合规则已保存 |
| **给什么** | 截图两集合的规则页 |
| **验收** | ① 我逐条比对；② 我用匿名 `curl` 复测「写入是否已被拦」（应返回 403） |

### 第 5 步：部署 Hook（✅ 版本已确认支持）

| 项 | 内容 |
|---|---|
| **做什么** | 把 `pb_setup_stepbook.md` §6.2 的 JS 代码放入 `pb_hooks/lock_fields.pb.js`，重启 PB |
| **交付物** | Hook 文件已部署 + PB 已重启 |
| **给什么** | "已部署" + 控制台是否报错 |
| **若不支持** | 已确认支持，无此分支 |

### 第 6 步：准备文案与视觉基准（🟡 **暂定稿已出，待你的想法定稿**）

| 项 | 内容 |
|---|---|
| **2026-09-30 结论** | 开发者：「可以参考 KUNGAL 的资源分享的展示方式，但我有点自己的想法，**现在做大概设计即可**」 |
| **已产出** | §6.4.5「参考基准与**暂定设计 v0**」：KUNGAL 共性模式对照表 + 单条卡片四行结构 + **7 个可替换点**（含替换成本） |
| **工程护栏** | 全部展示决策收敛在**新建的单文件** `lib/widgets/community_sources_section.dart`（含样式常量）→ **你的想法落地时只改这一个文件** |
| **仍待你** | 方便时讲你的想法；§6.4.5 表格即"菜单"，可直接对着其中某几项说要改成什么 |
| **不阻塞开发** | v0 可直接进入 Phase 1 编码；想法后到也不返工（改单文件） |

### 第 7 步：准备测试数据（✅ **2026-09-30 01:20 已完成，AI 代做**）

> 开发者已授权「写入线上」，并选定「新建 2 个测试账号」作为提供者。
> 生成脚本：`.workbuddy/pb_tmp/make_test_data.py`；清单：`.workbuddy/pb_tmp/test_data_manifest.json`；
> 一键回滚：`.workbuddy/pb_tmp/cleanup_test_data.py`（先干跑，确认后加 `--apply`）。

| 类别 | 内容 | id |
|---|---|---|
| 测试账号 | `CT测试分享者A` | `ocsjxk4ny05azi7` |
| 测试账号 | `CT测试分享者B` | `lp62t2spcmwwh5o` |
| **① 命运石之门**（官方+用户并存） | `【测试】PS3 版 · 百度网盘`（netdisk/百度/**有 source_note**） | `1um98miq85m2kri` |
| 同上 | `【测试】PC 汉化版 · 直链`（direct/**无 source_note**） | `n1g9qfynztd29uc` |
| 同上 | `【测试】中文版 · 夸克网盘`（**另一提供者 B**） | `93aewjt0e7e5xui` |
| **② 纯用户作品**（origin=user） | `【测试】用户分享作品（可忽略）` | `y6o7s8oa2dve8pz` |
| 同上来源 | `【测试】用户作品 · 唯一来源` | `fh1ez1q8jrcactb` |

**曝光控制（实测确认）**：

| 视角 | 可见来源数 | 说明 |
|---|---|---|
| **匿名（未登录）** | **0 条** ✅ | 全部 `status=pending` → listRule 过滤，**零公开曝光** |
| 测试账号 A 登录 | **3 条** | 覆盖「同作品 2 条并列」+「说明有/无」+「用户作品」 |
| 测试账号 B 登录 | 1 条 | 覆盖「不同提供者」署名 |
| 超管 | 4 条 | — |

⚠️ **一处已知曝光**：`games.listRule = @request.auth.id != "" || review_status = "approved"`，
所以**登录状态的真实用户**会在探索库看到那条 `【测试】用户分享作品`（`review_status=pending`
只挡住了匿名，挡不住登录）。**Phase 1 验收后立即清理**，回滚脚本已就绪。
若你想立刻消除，我可以现在就把这条作品连同来源删掉，Phase 1 验收时再重建（1 分钟）。

⚠️ **与原稿的一处偏离（已知情）**：原稿要求两条来源"分别挂不同 owner"，
但 `game_resources` 的可见规则是 `... || owner = @request.auth.id` ——
pending 状态下**只有作者本人**能读，因此"同作品 2 条并列可见"必须由**同一 owner**持有。
故 R1/R2 都挂给 A（保证并列布局可验证），"不同提供者"改由 R3（B）覆盖。
**如需在一次视图里看到"两个不同提供者并列"**：验收时把 R3 临时改 `published`
（曝光窗口 = 你点击的那几分钟），你看完我立刻改回 `pending`。

### 第 8 步：明确验收标准（✅ **2026-09-30 已接受**）

| 项 | 内容 |
|---|---|
| **你的确认** | 「接受」——按 §8 表格三 Phase 验收条目执行 |
| **§8 原文** | Phase 1：手工造数据可正确并列显示；提供者/时间/说明三项齐全；官方安装链路零回归<br>Phase 2：登录用户可提交（场景 1/2）；未登录被拦且提示友好<br>Phase 3：转正后归属信息完整保留 |
| **补充约定（AI 加严）** | 每 Phase 收尾附 `flutter analyze` 结果（只看**新增** error）；环境不许可时须**显式标注**并说明替代验证手段（如本轮的子进程故障） |

---

### 12.1 完成后的交接边界（我的承诺）

第 0–8 步完成后，以下工作**全部由我接手**，无需你参与编码：

| 我负责 | 说明 |
|---|---|
| 模型与服务层 | `game_resource_model.dart`、`game_resource_service.dart` |
| UI 组件 | 用户分享区、来源卡片（含 §6.4 信息行）、上传表单、我的分享页 |
| 既有文件改动 | `game_detail_page.dart` 左列追加、`game_model.dart` 字段解析 |
| 单测 | 新增用例 + 跑既有测试确认无回归 |
| 文档 | `DEV_LOG` / `SESSION_HANDOFF` / 本方案文档 |
| 提交 | 一任务一 commit |

**你只需在以下 3 个节点参与**：

1. **Phase 1 收尾**：我给出可运行版本，你**真机走查**「用户分享区」的展示（尤其来源信息三项）；
2. **Phase 2 收尾**：你验收提交表单与"我的分享"页；
3. **Phase 3 收尾**：你验收归属保留（转正后原分享记录完好）。

---

### 12.2 阻塞点提示

> 🔴 **必须先做第 0 步与第 1 步**——不探 PB 版本无法定 Hook 方案，不备份则建表出错无法回滚。
> 其余步骤可按你时间灵活安排，**但建议 2→3→4 连续完成**（字段与规则需一起验证）。

---

## 附录 A：给后续 AI 的接手指引

若由其他 AI 接手开发，按以下顺序读：

1. 本文件（全文）
2. `AGENTS.md`（协作铁律）
3. `docs/DEV/DECISIONS.md` → ADR-011（游戏身份体系）
4. `lib/models/game_model.dart`（字段解析范式）
5. `lib/pages/game_detail_page.dart:715-732`（左右列结构）、`:1135-1166`（左列可滚动）
6. `lib/repositories/game_repository.dart:68/118/277`（PB 查询范式）
7. `lib/core/pb_config.dart`（`isLoggedIn` getter :18）

**先决条件**：§12 前置清单已全部完成。
