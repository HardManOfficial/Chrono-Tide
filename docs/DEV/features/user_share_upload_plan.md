# 用户上传与分享 — 开发方案（v1，部分作废）

> 🔴 **2026-09-29 更新：本方案的数据结构部分已作废**，请以
> **`docs/DEV/features/explore_resource_sources_plan.md`（v2）为准**。
>
> **作废原因**：v1 将用户分享设计为独立作品表 `shared_games`（两条互不交叉的数据流）；
> 新需求要求「同一作品下的不同资源来源」，故 v2 改为
> **统一 `games` 作品表 + `game_resources` 来源表（1:N）**。
>
> **v1 中仍然有效的部分**（已被 v2 整合）：上传表单三段式设计、字段校验规则表、
> PB 后台配置清单写法、风险表结构、状态配色方案。阅读时请以 v2 为准。

---

# 用户上传与分享 — 开发方案

> **状态**：方案设计（未开发）　**日期**：2026-09-29　**适用目录**：`D:\CTLIB`
> **性质**：纯新增模块，不改动探索库既有安装/下载链路。
> **前置阅读**：`AGENTS.md`（协作规范）、`DECISIONS.md`（ADR-011 游戏身份 / ADR-007 删清护栏）

---

## 0. 结论先行

| 项 | 结论 |
|---|---|
| 集合设计 | 新增 **3 张表**：`shared_games`（条目）、`shared_resources`（资源）、`share_reports`（举报，可选 Phase 2）。**不动 `games` 表**，避免污染应用内安装数据 |
| 存储分离 | 文件走 **`share_covers` / `share_screenshots` 两张独立 storage collection**，不混入 `games` 的封面桶 |
| 本质隔离 | 分享条目 **不进 `DiscoverPage` 的 `_allGames`**，不参与 `_performFilter`，点击不触发 `onGameTap`，只走 `WebsiteBookmarkService.openExternal` |
| 权限 | PB 集合 API Rules 兜底（`@request.auth.id != ''` 创建 / `owner = @request.auth.id` 管理），前端只做体验层拦截 |
| 风险最高点 | 外链合法性校验（scheme 白名单 + 网盘域名识别 + 反 SSRF/跳转陷阱），必须**服务端复校** |
| 工作量 | Phase 1（上传+我的分享+展示）≈ 新增 1 服务 + 1 模型 + 2 页面 + 1 弹窗；探索库改动 ≤ 60 行 |
| 实施顺序 | 见 §7（PB 建表 → 模型/服务 → 上传表单 → 我的分享 → 探索库入口 → 校验加固） |

---

## 1. 现状盘点（方案的事实基础）

### 1.1 已确认的关键事实

| 事实 | 出处 | 对方案的影响 |
|---|---|---|
| PB 地址 `http://117.72.115.30:8090`，单例 `PBConfig.pb` | `lib/core/pb_config.dart:7-11` | 复用同一实例，不新建 PocketBase 客户端 |
| 登录态 = `pb.authStore.isValid` | `pb_config.dart:18` | 上传前置判断直接用它 |
| 用户集合 `users`，字段 `email/name/description(bio)/avatar` | `lib/modules/auth/user_model.dart:8-11,34` | `owner` 关联 `users`；头像 URL 拼法可复用 |
| `AuthService.getCurrentUser()` 已存在 | `auth_service.dart:804` | 不再自造取用户逻辑 |
| 探索库游戏来自 `games`，`GameModel.fromPBRecord` 解析 | `game_repository.dart:68-77` | 分享条目**不能**复用该解析器（字段语义不同） |
| 探索库点卡片 → `onGameTap` → `main_container._onGameTap` → 详情页（安装下载） | `discover_page.dart:1948`、`main_container.dart:202` | 分享条目必须**绕开**这条链 |
| 外链打开已有现成能力 `openExternal`（scheme 白名单 http/https + detached 拉起） | `website_bookmark_service.dart:176-205` | 直接复用，零依赖 |
| 项目**无 PB 迁移目录**，集合靠 PB 后台手工建 | 仓库内无 `pb_migrations/` | 方案须给出**可复制的后台配置清单**（§3.5） |
| 无 `url_launcher` 依赖 | 全仓 grep 无该包 | 不引入新依赖（符合项目零新依赖习惯） |

### 1.2 一个必须澄清的历史包袱

仓库里存在 `assets/data/company_aliases.json`（会社别名归一化，36 家）与 `CompanyAliasStore`。
**分享条目的「会社」字段建议直接存 `text`（自由文本）**，不走归一化词典：

- 理由：用户上传内容不可控，强行归一化会产生大量 pending 记录；词典是给**预置数据**用的；
- 展示层可**只读**用 `CompanyAliasStore.resolve` 做别名命中的视觉提示（不写入）。

---

## 2. 领域模型设计

### 2.1 为什么不复用 `games` 表（核心决策）

| 维度 | `games`（预置作品） | `shared_games`（用户分享） |
|---|---|---|
| 数据来源 | 开发者导入，质量可控 | 用户提交，需审核 |
| 可否安装 | 可（走下载→解压→入库） | **不可**，只跳外链 |
| 下载字段 | `downloadUrl` 指向 OSS/CDN 直链 | **无下载字段**，资源在 `shared_resources` |
| 审核 | 无 | `pending / published / rejected` |
| 所有权 | 平台 | 用户（`owner`） |
| 展示位 | 探索库网格主列表 | 探索库**独立入口/第二列表** |

**结论**：物理分表。同一个 galgame（如《ATRI》）允许同时存在一条 `games` 记录（可安装）与 N 条 `shared_games` 记录（不同用户分享的不同网盘资源），二者**通过 `title` 弱关联**，不建外键（避免预置数据被用户数据绑定）。

### 2.2 实体关系

```
users ──1:N──> shared_games ──1:N──> shared_resources
                    │
                    └──1:N──> share_reports (Phase 2，举报)
```

`shared_games : shared_resources = 1:N` 的理由：同一部作品可以有多份分享（百度网盘 / 夸克 / 迅雷 / 直链），
每份资源有独立的提取码、有效期、补充说明、审核状态与上传者（**资源也带 owner**，便于"我分享的资源"粒度管理）。

---

## 3. PocketBase 集合与字段设计

### 3.1 `shared_games` — 用户分享的游戏条目

| 字段名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `title` | text | ✅ | 游戏标题；`min:1, max:200` |
| `subtitle` | text | | 副标题 |
| `description` | text(editor/plain) | | 简介；`max:5000` |
| `developer` | text | | 会社（自由文本，见 §1.2） |
| `release_date` | text | | 发售日期 `YYYY-MM-DD`（或 `YYYY`），控件用输入框+格式校验，不用 date 字段以兼容"仅年份" |
| `tags` | select(multiple) | | 标签；**PB 的 select 需要预定义选项**，若希望用户自由输入则用 `text` + 逗号分隔（见 §3.6 选型建议） |
| `cover` | file(single) | | 封面；`maxSize: 5MB`，限 `jpg/png/webp` |
| `screenshots` | file(multiple) | | 截图；`maxSelect: 8`，单张 `maxSize: 5MB` |
| `status` | select(single) | ✅ | `pending` / `published` / `rejected` / `hidden`；默认 `pending` |
| `reject_reason` | text | | 审核驳回理由（仅 `rejected` 时有值） |
| `owner` | relation(users) | ✅ | 上传者；`maxSelect: 1, cascadeDelete: true` |
| `owner_name` | text | | 冗余存上传者昵称，**列表展示免 expand**（PB list 内 expand 有性能成本） |
| `view_count` | number | | 浏览量（Phase 2 统计） |
| `resource_count` | number | | 冗余资源数，列表页免二次查询（写资源时同步维护） |
| `created` / `updated` | auto | | PB 内置 |

**索引建议**：`title`（搜索）、`status`（过滤）、`owner`（我的分享）、`created DESC`（排序）。

### 3.2 `shared_resources` — 分享资源（外链）

| 字段名 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `game` | relation(shared_games) | ✅ | 关联条目；`maxSelect: 1, cascadeDelete: true`（删条目连带删资源） |
| `link_type` | select(single) | ✅ | `netdisk`（网盘）/ `direct`（直链）/ `other`；**区分类型是需求明确的** |
| `url` | url | ✅ | 外链；**PB 的 `url` 字段自带格式校验**（不收 `javascript:` 等） |
| `netdisk_provider` | select(single) | | `baidu` / `quark` / `aliyun` / `xunlei` / `115` / `onedrive` / `mega` / `google_drive` / `other`；`link_type=netdisk` 时必填（前端强校验） |
| `extract_code` | text | | 网盘提取码；`link_type=netdisk` 时可选 |
| `note` | text | | 补充说明（版本/汉化组/是否有解压密码等）；`max:2000` |
| `file_size` | text | | 体积描述（自由文本，如 "≈7GB"，不存字节数——外链体积无法核实） |
| `status` | select(single) | ✅ | `pending` / `published` / `rejected`；默认 `pending` |
| `owner` | relation(users) | ✅ | 上传者；`cascadeDelete: true` |
| `owner_name` | text | | 冗余昵称 |
| `report_count` | number | | 举报计数（Phase 2 自动隐藏阈值） |

### 3.3 `share_reports` — 举报（Phase 2，可选）

| 字段名 | 类型 | 说明 |
|---|---|---|
| `resource` | relation(shared_resources) ✅ | 被举报资源 |
| `reason` | select | `invalid_link` / `malware` / `copyright` / `wrong_content` / `other` |
| `detail` | text | 补充说明 |
| `reporter` | relation(users) ✅ | 举报人 |
| `handled` | bool | 是否已处理 |

### 3.4 API Rules（**权限的真正实现层**）

PB 里前端校验只是体验，**规则必须写在这里**：

**`shared_games`**
```
List/Search : status = "published" || owner = @request.auth.id
View        : status = "published" || owner = @request.auth.id
Create      : @request.auth.id != "" && @request.data.owner = @request.auth.id
Update      : owner = @request.auth.id && status != "published"
Delete      : owner = @request.auth.id
```

**`shared_resources`**
```
List/Search : (game.status = "published" && status = "published") || owner = @request.auth.id
View        : (game.status = "published" && status = "published") || owner = @request.auth.id
Create      : @request.auth.id != "" && @request.data.owner = @request.auth.id
Update      : owner = @request.auth.id && status != "published"
Delete      : owner = @request.auth.id
```

> **⚠️ 关键点 1**：`Update: status != "published"` —— 防止用户提交后自行把状态改回/改成 `published` 绕过审核。
> 但 PB 规则**无法阻止用户在更新时改 `status` 字段本身**（规则是记录级，不是字段级）。
> **因此必须在 `shared_games` 上挂 `onRecordUpdateRequest` Hook**（PB JS 扩展）强制回写 `status`/`reject_reason` 字段，见 §3.5。
>
> **⚠️ 关键点 2**：`owner` 由前端传（`@request.data.owner`）而非服务端自动赋值，是因为 PB 的 `owner` 不是内置字段。
> 若担心前端漏传，可改用 `@request.auth.id = @request.data.owner` 双向约束（上面写法已含）。

### 3.5 PB 后台配置清单（可直接照做）

项目**没有迁移目录**，全部在 PB Admin UI（`http://117.72.115.30:8090/_/`）手动建。建议按此顺序：

```
1. Collections → New collection → Base collection
   name: shared_games        id: 留空（PB 自动生成 15 位）
   ☑ 勾选 "Only admins can list..." 先全关，建完字段再填 Rules

2. 按 §3.1 表逐字段添加（Type 列严格照抄）
   - owner 字段：Type=Relation，Collection=users，Max select=1，☑ Cascade delete
   - cover 字段：Type=File，Max select=1，Max size=5242880，Mime types: image/jpeg,image/png,image/webp
   - screenshots：Type=File，Max select=8，同上尺寸
   - status：Type=Select，Values 逐行填 pending/published/rejected/hidden，Max select=1

3. Indexes → 新建 4 条（§3.1 索引建议），表达式例如：
   CREATE INDEX idx_shared_games_status_created ON shared_games (status, created DESC)

4. API Rules → 粘贴 §3.4 的 shared_games 规则

5. 重复 1-4 建 shared_resources（game 字段 Cascade delete 勾上）

6. 文件权限：PB v0.23+ 若开了「Protect file access」，
   cover/screenshots 需要在 View rule 之外单独放行，否则封面 404 —— 建完上传一张自测
```

**PB JS Hook（`pb_hooks/main.pb.js`，若服务器支持扩展）**：

```js
// 阻止用户通过 update 提权 status / reject_reason
onRecordUpdateRequest((e) => {
  if (e.collection.name === "shared_games") {
    const orig = e.record.original();
    // 非管理员：状态字段一律回滚为原值
    e.record.set("status", orig.getString("status"));
    e.record.set("reject_reason", orig.getString("reject_reason"));
  }
  if (e.collection.name === "shared_resources") {
    e.record.set("status", e.record.original().getString("status"));
    e.record.set("report_count", e.record.original().getNumber("report_count"));
  }
  e.next();
}, "shared_games", "shared_resources");
```

> 若服务器是纯 exe 无 hooks 目录，退路：**审核改由管理员用 superuser 操作**，
> 并在客户端「我的分享」页**只读展示 status**（不提供编辑已发布条目），
> 写入冲突由后端拒绝（403）→ 前端提示。这是可接受的降级。

### 3.6 一个选型建议：`tags` 用什么类型

| 方案 | 优点 | 缺点 | 建议 |
|---|---|---|---|
| `select(multiple)` 预定义选项 | PB 原生多选、可直接 filter | 用户无法添加新标签，与"用户上传"矛盾 | ❌ |
| `text` 逗号分隔 | 自由输入，与现有 `games.tags` 解析兼容（`GameModel._parseTags` 支持字符串分支） | 无法用 PB filter 直接匹配 | ✅ **推荐 Phase 1** |
| 独立 `shared_tags` 表 + 关联 | 最规范、可统计 | 表数量翻倍、上传表单复杂度上升 | Phase 3 再考虑 |

---

## 4. 前端改动方案

### 4.1 新增文件清单

| 文件 | 作用 | 预估行数 |
|---|---|---|
| `lib/models/shared_game_model.dart` | `SharedGameModel` + `SharedResourceModel` + 枚举 | ~220 |
| `lib/services/shared_share_service.dart` | CRUD / 上传 / 我的分享 / 列表查询 | ~380 |
| `lib/pages/my_shares_page.dart` | 「我的分享」管理列表 | ~350 |
| `lib/widgets/share_upload_dialog.dart` | 上传/编辑表单（三步） | ~520 |
| `lib/widgets/share_detail_dialog.dart` | 分享条目详情（只跳外链） | ~280 |
| `lib/widgets/explore_hall/shared_section.dart` | 探索大厅入口卡片 | ~120 |
| `lib/widgets/panel_unavailable_notice.dart` | 空态/未登录/审核中提示 | ~80 |

**改动既有文件**：`discover_page.dart`（+约 60 行：分享模式切换 + 卡片渲染分支）、
`explore_hall_page.dart`（+约 20 行：入口卡）。

### 4.2 数据模型（`shared_game_model.dart`）

```dart
enum ShareStatus { pending, published, rejected, hidden }
enum ShareLinkType { netdisk, direct, other }

class SharedResourceModel {
  final String id, gameId, url, note, extractCode, fileSize, ownerId, ownerName;
  final ShareLinkType linkType;
  final ShareNetdiskProvider? provider;
  final ShareStatus status;
  // fromPBRecord：与 GameModel 同样用 _safeGetString 风格做防御式解析
}

class SharedGameModel {
  final String id, title, subtitle, description, developer, releaseDate;
  final List<String> tags, screenshotUrls;
  final String coverUrl;   // 由 pb 文件名拼 ${PBConfig.baseUrl}/api/files/shared_games/$id/$file
  final ShareStatus status;
  final String ownerId, ownerName, rejectReason;
  final int resourceCount;
  final List<SharedResourceModel> resources; // 详情页 expand 时填充，列表为空
  final DateTime created, updated;
}
```

**⚠️ 文件 URL 拼接**：`GameModel._extractCoverUrl` 硬编码了 `api/files/games/`，
分享表**必须用 `shared_games` 作为 collection 名**，不能复用该方法（这是最容易踩的坑）。

### 4.3 服务层（`shared_share_service.dart`）

```dart
class SharedShareService {
  static const collection = 'shared_games';
  static const resourceCollection = 'shared_resources';

  /// 列表：按状态与关键词；published 对所有人可见，pending/rejected 仅 owner
  static Future<SharedPageResult> listShared({
    int page = 1, int perPage = 24,
    String keyword = '', String tagFilter = '', SortOption sort,
  });

  /// 我的分享：owner = 当前用户，含 pending/rejected
  static Future<List<SharedGameModel>> listMine({ShareStatus? status});

  /// 创建条目（含封面上传）
  static Future<SharedGameModel> createShared({
    required String title, /* ... */
    File? coverFile, List<File> screenshots,
  });

  /// 为条目添加资源
  static Future<SharedResourceModel> addResource({...});

  static Future<void> updateShared(String id, {...});
  static Future<void> deleteShared(String id);      // 仅 owner，PB 规则兜底
  static Future<void> deleteResource(String id);
}
```

**实现要点**：
1. **必须先转义**：关键词走 `PbFilter.containsFilter`（`utils/pb_filter.dart`，与 `game_repository.dart:66` 同款），禁止字符串拼接；
2. **文件上传用 `MultipartFile`**：`pb.collection('shared_games').create(body: {...}, files: [http.MultipartFile.fromBytes(...)])`；
3. **状态门禁**：`createShared` 开头判 `PBConfig.isLoggedIn`，未登录直接抛业务异常（前端弹登录引导）；
4. **失败翻译**：复用 `game_repository.dart:212 _translateListError` 的写法（网络错误→中文提示）。

### 4.4 上传/编辑表单（`share_upload_dialog.dart`）

三步式（与项目现有弹窗风格一致，参考 `discover_filter_dialog.dart` 的分段+底部双按钮布局）：

```
┌─ 步骤 1/3  游戏信息 ──────────────────────────┐
│ 标题*          [________________]  200 字上限  │
│ 副标题         [________________]              │
│ 会社           [________________] (可选联想)   │
│ 发售日期       [YYYY-MM-DD]  ← 正则校验        │
│ 标签           [逗号分隔，如 恋爱, 校园]        │
│ 简介           [多行文本域]        5000 字上限  │
│ 封面           [＋ 拖拽/点击上传]   ≤5MB       │
│ 截图           [＋ 最多 8 张]                  │
├───────────────────────────────────────────────┤
│              [取消]  [下一步 →]                │
└───────────────────────────────────────────────┘

步骤 2/3  分享资源（可加多条）
│ 链接类型*   ( ) 网盘  ( ) 直链  ( ) 其他        │
│ 网盘平台*   [百度/夸克/阿里/迅雷/115/...▾]     │
│ 分享链接*   [https://...]  ← 实时校验          │
│ 提取码      [____]                             │
│ 体积        [≈7GB]                             │
│ 补充说明    [多行]                             │
│ [+ 再添加一条资源]

步骤 3/3  预览与提交
│ （渲染一张与探索库同风格的卡片 + 资源列表）      │
│ ☑ 我确认分享内容合法，不包含违规/侵权内容        │
│ [上一步]  [提交审核]
```

**校验规则表**（前端 + 服务端双层）：

| 字段 | 规则 | 提示 |
|---|---|---|
| `title` | 非空、trim 后 1–200 | 「请输入游戏标题」 |
| `description` | ≤5000 | 「简介过长」 |
| `release_date` | 空 或 `YYYY` 或 `YYYY-MM-DD` | 「日期格式应为 2004 或 2004-05-28」 |
| `url` | `WebsiteBookmarkService.normalizeUrl` 通过（http/https + 有 host） | 「链接格式不正确，需以 http(s):// 开头」 |
| `url` 二次 | **不出现 `http://` 内网地址**（`127.`/`192.168.`/`10.`/`localhost`） | 「不支持内网地址」 |
| `extract_code` | `link_type=netdisk` 时 ≤20 字符 | 「提取码过长」 |
| `file_size` | ≤50 字符 | |
| 至少一条资源 | 提交时资源列表非空 | 「请至少添加一条分享资源」 |
| 版权勾选 | 必须勾 | 「请确认内容合法性」 |

### 4.5 「我的分享」管理列表（`my_shares_page.dart`）

布局与库页 `library_page.dart` 一致的网格 + 顶部状态筛选 Tab：

```
[全部] [审核中 N] [已发布 N] [未通过 N]        [+ 新建分享]

┌────────┐ ┌────────┐ ┌────────┐
│ 封面    │ │ 封面    │ │ 封面    │
│ 标题    │ │ 标题    │ │ 标题    │
│ 🟡审核中 │ │ 🟢已发布 │ │ 🔴未通过 │  ← 状态角标
│ 3 个资源 │ │ 3 个资源 │ │ 驳回理由 │
└────────┘ └────────┘ └────────┘
   点卡片 → 详情弹窗（编辑 / 删除 / 管理资源）
```

**状态角标配色**（沿用主题令牌，不硬编码）：

| 状态 | 令牌 | 色值语义 |
|---|---|---|
| `pending` | `AppColors.warningAmber` | 琥珀（审核中） |
| `published` | `AppColors.successGreen` | 绿（已发布） |
| `rejected` | `AppColors.dangerRed` | 红（未通过） |

**删除确认**：复用项目既有确认弹窗风格；删除走 PB 规则校验，非 owner 会 403。

### 4.6 探索库中的分享入口（对 `discover_page.dart` 的最小改动）

**方案选择**：在现有顶部栏加一个「作品 / 分享」双态切换 chip（**不改动现有搜索/评分/年份/排序/标签/会社任何逻辑**）：

```
上级区：[搜索框] [评分] [年份] [排序]
次级：  [作品 | 分享]  ← 新增（Segment 风格，与顶栏控件同族）
下级区：切换为「作品」时 = 现有的 标签/会社 双板块（完全不变）
        切换为「分享」时 = 分享专用筛选（链接类型 / 网盘平台 / 审核状态=已发布）
```

**分享态下的卡片**：
- 右上角加 `外链` 角标（区别于可安装作品）
- 卡片本身视觉沿用 `_DiscoverCardWidget`，仅数据源换成 `listShared()`
- **点击行为改变**：不走 `onGameTap`，而是打开 `share_detail_dialog.dart`

**关键隔离约束（必须遵守）**：
```dart
// ❌ 禁止：把分享条目塞进探索库主列表
_allGames.addAll(sharedGames);

// ✅ 正确：独立的 _sharedGames 列表 + 独立渲染分支
enum DiscoverMode { games, shared }
DiscoverMode _mode = DiscoverMode.games;
List<SharedGameModel> _sharedGames = [];
```

这样 `_performFilter`（依赖 `GameModel`）、`_selectedTags`、`_selectedDevelopers`、
`_cachedFilterState` 等**全部不受影响**，风险可控。

### 4.7 分享详情弹窗（`share_detail_dialog.dart`）— 需求「本质区别」的落地点

```
┌─ 《ATRI -My Dear Moments-》         [外链] ─┐
│  [封面]     会社：Frontwing                │
│            发售：2020-06-19                │
│            标签：恋爱 / 科幻 / 全年龄        │
│ ─────────────────────────────────────────  │
│ ⚠️ 本条为「用户分享」，非应用内可安装作品    │
│    下载、解压、安装均在外部完成              │
│ ─────────────────────────────────────────  │
│ 分享资源 (2)                                │
│ ┌──────────────────────────────────────┐  │
│ │ 百度网盘  提取码 1234    ≈7GB         │  │
│ │ 说明：汉化版 v1.2，无解压密码          │  │
│ │ [ 打开链接 ↗ ]                        │  │
│ ├──────────────────────────────────────┤  │
│ │ 夸克网盘  无提取码       ≈7GB         │  │
│ │ [ 打开链接 ↗ ]                        │  │
│ └──────────────────────────────────────┘  │
│            [关闭]                          │
└────────────────────────────────────────────┘
```

**「打开链接」实现**（严格复用现有能力，不自造）：

```dart
final ok = await WebsiteBookmarkService.openExternal(resource.url);
if (!ok) {
  // 白名单拦截或启动失败 → SnackBar 提示，不静默失败
}
```

**按钮文案要求**：不得出现「下载」「安装」「立即游玩」等词——一律「打开链接」，
与探索库作品详情页的按钮形成**明确的词汇区分**。

### 4.8 探索大厅入口（`explore_hall_page.dart` +20 行）

在右栏「⑦ 开始探索」旁边新增一张「📤 分享资源 / 我的分享」卡片：

- 未登录 → 点击弹出 `panel_unavailable_notice`「登录后即可上传与分享」+ 跳登录；
- 已登录 → 打开 `my_shares_page.dart`。

> ⚠️ 探索大厅属稳定区之外的普通页面，但本项目铁律要求**改动前说明**。
> 建议：**Phase 1 先不加此入口**，改从探索库的「分享」态右上角进「我的分享」，
> 待方案验证后再决定是否上大厅（降低首期改动面）。

---

## 5. 交互与视觉规范（与现有探索库保持一致）

| 元素 | 复用来源 | 说明 |
|---|---|---|
| 弹窗容器 | `discover_filter_dialog.dart` | 圆角 `AppRadius.lg`、背景 `AppColors.background`、发丝边框 |
| 按钮 | `InteractiveWrapper` + `AppColors.buttonBackground` | 统一 hover 缩放 |
| 输入框 | 探索库搜索框样式 | 高 40、`AppRadius.md`、激活态 `selectedAccent` 边框 |
| 标签 chip | `discover_page.dart::_TagChip` | 直接复用（含弹性动画） |
| 状态色 | `warningAmber / successGreen / dangerRed` | 见 §4.5 |
| 空态 | 参考 `discover_page._buildEmptyView` | 图标 + 主副文案 |
| 加载态 | `GridView` + `CircularProgressIndicator(strokeWidth: 2)` | 与 `_buildLoadingGrid` 同款 |

**必须避免**：引入任何新的 UI 库、图标库、状态管理库（项目当前只用 `ChangeNotifier` +
`AnimatedBuilder`，禁止引入 Provider/Riverpod）。

---

## 6. 安全与合规设计

### 6.1 已在方案内覆盖

| 风险 | 对策 |
|---|---|
| Filter 注入 | 全部走 `PbFilter.containsFilter` 转义 |
| 越权改状态 | PB Rules + JS Hook 双保险（§3.4/§3.5） |
| 越权删改他人内容 | `owner = @request.auth.id` 规则 |
| 恶意 scheme（`javascript:`/`file:`/`ms-*:`） | `normalizeUrl` 白名单（现有实现已拦） |
| 内网地址探测 | 前端复校 + 建议服务端 Hook 再校 |
| 上传超大文件 | PB 字段级 `maxSize`（封面 5MB / 截图 5MB×8） |
| 恶意图片（伪装扩展名） | PB `Mime types` 白名单 |
| 版权/违规内容 | `status=pending` 默认待审 + 举报入口（Phase 2） |

### 6.2 需要额外决策的点（**须开发者拍板**）

1. **审核谁来审？** 方案假设"管理员在 PB Admin UI 手动改 `status`"。
   若希望 App 内有审核页 → 需新增 `is_admin` 角色字段 + 管理页（工作量 +1 个页面）。
2. **是否允许「直链」类型？** 直链可被用来挂载非 galgame 文件，风险高于网盘。
   建议：Phase 1 **只开 `netdisk` + `other`**，跑通后再评估 `direct`。
3. **提取码是否明文存？** 建议明文（用户本来就写在评论区的信息，非机密），
   但**详情页复制按钮**要提示"提取码仅用于网盘"。
4. **是否做外链存活检测？** PB 无此能力，需定时任务 HEAD 请求 → Phase 3。

---

## 7. 实施计划（分 Phase，每 Phase 一个提交）

### Phase 1 — 地基与只读展示（可独立验收）
1. PB 后台按 §3.5 建 2 张集合并填 Rules；手工造 2 条测试数据
2. 新增 `shared_game_model.dart`（含防御式解析 + 文件 URL 拼接）
3. 新增 `shared_share_service.dart` 的**只读方法**（`listShared`）
4. 探索库加「作品/分享」切换 + 分享态网格 + 外链角标
5. 新增 `share_detail_dialog.dart`（打开外链）
- **验收**：能浏览分享条目、点开只跳外链、探索库原有功能零回归

### Phase 2 — 上传与我的分享
6. `createShared` / `addResource` / `update` / `delete`
7. `share_upload_dialog.dart` 三步表单 + 全量校验
8. `my_shares_page.dart`（状态 Tab + 角标 + 编辑/删除）
9. 探索大厅入口卡（可选）
- **验收**：登录用户可上传（状态=审核中）、可在「我的分享」看到并编辑/删除；未登录被拦

### Phase 3 — 审核与加固
10. PB JS Hook（状态防提权）+ 服务端链接复校
11. `share_reports` 举报 + `report_count` 自动隐藏
12. 外链存活检测（定时任务，可选）

### 收尾（每个 Phase 都要做，按 `AGENTS.md` §3）
- `./flutter/bin/flutter.bat analyze` 只看新增 error
- 新增单元测试：`test/models/shared_game_model_test.dart`（解析）、
  `test/utils/share_validation_test.dart`（链接校验边界）
- 更新 `DEV_LOG.md` / `STATUS_MAP.md`（新增模块条目）/ `features/user_share_upload.md`（本文件转状态）
- 一任务一 commit

---

## 8. 风险与未决项

| # | 风险/未决 | 等级 | 建议 |
|---|---|---|---|
| 1 | PB 服务器是否支持 `pb_hooks`（状态防提权依赖它） | 🔴 P0 | 建表前先探测服务器版本与 hooks 目录；不支持则走 §3.5 降级方案 |
| 2 | 分享条目与预置作品**标题重复**时的展示歧义 | 🟡 P1 | 分享态独立 tab 展示，不混排，天然规避；若将来混排需加视觉区分 |
| 3 | 上传图片无压缩 → 流量/存储成本 | 🟡 P1 | 客户端上传前压缩到 ≤1920px（可复用 `PortableImageCacheManager` 的解码能力） |
| 4 | 用户删除账号后内容归属 | 🟢 P2 | `cascadeDelete` 会连带删除分享内容；若需保留应改 `SetNull` + 匿名化 |
| 5 | 「会社」自由文本与 `CompanyAliasStore` 口径不一致 | 🟢 P2 | 展示层只读归一化提示，不写入 |
| 6 | 分享列表与作品列表的**搜索/排序语义不同** | 🟡 P1 | 分享态独立维护筛选状态，不复用 `DiscoverFilterState` |

---

## 9. 附：与「主流 GAL 资源站」的对照（设计参考）

| 站点惯例 | 本方案的对应设计 |
|---|---|
| 条目页（作品信息）+ 资源列表（多网盘）分离 | `shared_games` : `shared_resources` = 1:N |
| 网盘类型标签化（百度/夸克/阿里…） | `netdisk_provider` select |
| 提取码单独展示 + 一键复制 | `extract_code` + 详情页复制按钮 |
| 「已失效」标记 | `report_count` + 举报（Phase 3） |
| 上传需登录、内容先审后发 | `status=pending` + PB Rules |
| 明确"本站不存储资源"免责 | 详情页顶部 ⚠️ 提示条（§4.7） |

---

## 10. 建议的第一步

在动手写任何 Dart 代码前，**先做一件事**：

```bash
# 探测 PB 服务器能力（决定 Phase 3 能否做状态防提权）
curl -s http://117.72.115.30:8090/api/health
# 确认版本；v0.22+ 才有 pb_hooks，v0.23+ 才有文件访问保护开关
```

拿到版本号后，§3.5 的配置清单可 100% 落地，本方案即进入 Phase 1 实施。

---

## 附录 · 2026-10-02 分享/发布窗口 UI 优化与顶栏双通道（已实施）

- **分享列表卡头像放大**：`share_list_dialog.dart` `_buildHeader` 头像 16→25、
  边框 0.5→0.6、名字 11→11.5(w600)、时间 9.5→10，对齐「获取」窗口用户面板
  （`ct_download_dialog._buildMainRow`：AvatarCircle 25 + 名字 11.5 + 「分享于」10）。
- **发布窗口封面预览与必选**：`publish_game_dialog.dart`——封面上传与预览区移到
  游戏名称左侧（`_coverPickerCard()` 96×144，NsfwImage.file 直接预览 + 右上角删除，
  形态同「添加」页 `CoverSectionWithLock`，配色适配深色面）；名称输入框相应缩短；
  封面可选改**必选**（`_validateGameForm` 仅 `!_isEditing` 强制——编辑模式未重选封面
  保留线上原封面，updateMyGame 不传 coverFilePath 即不改）；截图保留最底部并新增
  `_screenshotPreviewStrip()` 96×54 缩略图条（NsfwImage + 单张删除）；原封面
  「选择文件」行删除。
- **顶栏「上传 / 发布」双通道**：新增 `lib/widgets/game_detail/upload_publish_dialog.dart`
  ——搜索判重（`GamePublishService.searchByTitle`）：命中列表（封面缩略 48×64 + 标题 +
  会社 + 「上传资源」）选中 → `GameDetailPage.pendingAutoUploadGameId` 一次性信号 +
  `onGameTap` 跳详情页自动弹上传（与文档板块判重命中同一机制，零稳定区改动）；
  未命中 → 绿底面板「自行发布这部作品」→ `PublishGameDialog.show(initialTitle: 查询词)`，
  发布成功自动关闭选择器。未登录 `UploadPublishDialog.show` 内 SnackBar 拦截。
- 验证：进程内 analyzer 3 文件 errors=0；真机走查待开发者（走查清单见 DEV_LOG 同日条目）。

### 附录补记 · 同日二次调整（用户拍板：按钮合一 + 名字组归拢）

- **顶栏双按钮合一**：`discover_page.dart` 顶栏「发布」「上传」两按钮本就打开同一个
  选择器（同一 `_openUploadPublish`），合并为单个**【发布上传】**按钮（rocket 图标）；
  选择器窗口标题同步改「发布 / 上传」。
- **发布表单名字组归拢 + 封面加大**：`publish_game_dialog.dart` `_buildGameForm` ——
  游戏名称 / 日语原名 / 英语名 / 繁中名同属游戏名，归组为封面右侧**竖排输入区**
  （`IntrinsicHeight` + `CrossAxisAlignment.stretch`）；封面卡宽 96→**148**、高度随
  输入区撑满（原固定 96×144 预览太小），decodeWidth/cacheWidth 192→320 匹配新尺寸。
  原日/英两列行与繁中独立行删除，表单纵向更紧凑。
- 验证：进程内 analyzer 3 文件 errors=0（discover_page 3 个 warning 均存量遗留）；
  真机走查待开发者（顶栏单按钮 / 发布表单新布局 / 编辑模式资料回填）。
