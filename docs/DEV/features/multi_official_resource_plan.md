# 一个作品多个官方资源 + 上传工具「更新」模式 —— 变更计划

> 状态：**已实施**（2026-11-03 用户「批准」→ 代码完成 + 离线探针 25/25 PASS；
> ⏳ 真机走查与真云端联调待做，`flutter analyze/test` 仍被 231 阻断）
> 日期：2026-11-03
> 涉及两端：主管理器 `D:\CTLIB`（客户端消费）+ `D:\CTLIB\gametool\ct_cloud_admin`（灵光管理平台·生产）

---

## 0. 一句话结论

**数据库不用改。** 云端 `game_resources` 集合结构上已支持一个作品挂多条 `kind=official` 记录
（`game` 是单值 relation，无唯一约束）。卡点只在两处：

1. 上传工具的表单把「官方下载资源」写死成**一组输入框 + 一个记录 id**；
2. 客户端「获取」弹窗把官方资源的取值写死成 **`games.downloadUrl` 单条**。

因此本次是纯 UI / 同步逻辑改造，不触碰 PocketBase schema，也不触碰安装链路。

---

## 1. 现状核实（证据）

| 环节 | 位置 | 事实 |
|---|---|---|
| 云端集合 | `.workbuddy/pb_dev/pb_migrations/1790860521_created_game_resources.js:6-402` | 字段齐全（`download_path` / `version` / `version_note` / `file_size` / `resource_type` / `platforms` / `unzip_code`），`game` 关系 `maxSelect:1` 但**不唯一**，一作多记录合法 |
| 上传工具表单 | `gametool/ct_cloud_admin/lib/pages/game_editor_page.dart:1264-1377` | 「官方下载资源」= 固定 5 个输入框 + 3 个标签编辑器，只能表达一条 |
| 上传工具加载 | 同上 `:237-276` `_loadOfficialResource` | `perPage: 1`，只取最新一条回填 |
| 上传工具保存 | 同上 `:589-629` `_syncOfficialResource` | 单个 `_officialResourceId`，有则 update、无则 create，**永远只维护一条** |
| 上传工具权限 | `lib/services/auth_service.dart:25-27` | 走 `_superusers` 超管认证 ⇒ 不受 `createRule`（只允许 community）限制，可直接建 official |
| 客户端取数 | `lib/pages/game_detail_page.dart:974` | `GameResourceService.fetchOfficial(gameId)` **已经能拿到全部 official 记录**，但只被 `_primaryOfficial` 取了 first |
| 客户端视图 | 同上 `:1015-1028` | `_officialResource` 只认 `games.downloadUrl`，有才返回单条 |
| 下载弹窗 | `lib/widgets/game_detail/ct_download_dialog.dart:87-133` | 单卡单按钮，`onDownload` 无参 |
| 弹窗尺寸约束 | `lib/widgets/game_detail/dark_surface.dart:831-837` | 已给 `maxHeight = 可用高`，但内容是 `Column(mainAxisSize.min)` ⇒ 条目多了会**溢出被裁** |
| 旧客户端兼容 | `ct_download_dialog.dart:78-81` 注释 | 旧客户端只认 `games.downloadUrl` ⇒ 该字段必须继续写「主资源」 |

---

## 2. 已确认的产品决策（2026-11-03 用户拍板）

| 决策点 | 结论 |
|---|---|
| 「更新」语义 | **覆盖更新·同一作品**：作品 id 不变，元数据被新数据覆盖，官方资源列表**整体重建**（旧记录删除、新记录创建）。不引入版本快照表。 |
| 「更新」必须保留的数据 | ① 下载量与点赞数（数值）② 上架与审核状态（`review_status` / `origin`） |
| 客户端弹窗形态 | **列表式**：纵向列出全部版本，每行「版本徽章 + 名称 + 大小 + 下载按钮」，条目多时弹窗内部滚动 |
| 上传工具录入位置 | **作品编辑器内嵌可增删的资源列表**（不新增独立页面） |

---

## 3. 「保存」vs「更新」字段对照（这是本次需求 2 的验收基准）

| 数据 | 保存（现状保留） | 更新（新增） |
|---|---|---|
| 作品记录 id | 保留 | 保留 |
| 标题/别名/简介/标签/发售日/来源/预计时长 | 用表单值覆盖 | 用表单值覆盖 |
| `review_status` / `origin` / `has_official` | 保留（`game_editor_page.dart:505-527` 已如此） | 保留 |
| `installCount` / `rating` / `voteCount` | 用表单值（默认带回原值） | 用表单值（默认带回原值） |
| 封面 / 横幅 / 截图 | 未选新图则保留旧图 | 未选新图则保留旧图（否则更新完没图） |
| `created` | 不变（PB autodate，PATCH 改不动） | 不变（同上，技术上无法改） |
| **官方资源记录** | **增量同步**：有 id → update，无 id → create，列表里被移除的 → 删除 | **全部删除重建**：先删该作品全部 official 记录，再按表单逐条 create；下载量/点赞数按「标题+版本号」匹配旧记录后迁回新记录 |

> ⚠️ **必须让用户知道的代价**：更新时资源记录被删除重建 ⇒ 记录 id 变化 ⇒
> `resource_likes`（点赞明细，关系级联删除）会随之清空。`like_count` / `download_count`
> 的**数值**会被迁移保留，但"谁点过赞"的明细无法恢复。这是"真替换"不可避免的取舍。
>
> 另：`created` 用户未选「保留」，但 PB 的 autodate 字段在 PATCH 下不可修改，
> 因此实际结果与「保留」一致，不冲突。

---

## 4. 改动清单

### 阶段一：上传工具（先做，能造出多资源数据）

#### 4.1 新增 `gametool/ct_cloud_admin/lib/models/official_resource_draft.dart`

一条可编辑的官方资源草稿。字段与云端 `game_resources` 一一对应：

```
String? id;              // null = 新建
String title;            // 资源标题，如「原版」「重制版」「汉化版」
String downloadPath;     // download_path
String version;          // version
String versionNote;      // version_note
String fileSize;         // file_size
String unzipCode;        // unzip_code
List<String> resourceTypes;  // resource_type
List<String> languages;
List<String> platforms;
int downloadCount;       // 只读，仅用于「更新」时迁移
int likeCount;           // 只读，同上
bool isPrimary;          // 是否主资源（写回 games.downloadUrl）
```

#### 4.2 新增 `gametool/ct_cloud_admin/lib/widgets/official_resource_editor.dart`

把资源列表的 UI 从 `game_editor_page` 抽出来（**新增文件，不改既有组件**）：

- 每行一个 `ExpansionTile` 风格卡片：折叠态显示「标题 · 版本号 · 路径摘要 · 大小」+ 删除按钮；
- 展开态显示现有那套输入框（路径 / 版本号 / 大小 / 版本说明 / 解压码 / 类型 / 语言 / 平台）；
- 第 1 条标记「主资源（客户端主下载）」徽章；
- 底部「+ 添加资源版本」按钮；
- 空态提示：「未填写资源路径：客户端不会显示『获取』按钮」。

#### 4.3 改 `gametool/ct_cloud_admin/lib/pages/game_editor_page.dart`

| 行号 | 改法 |
|---|---|
| `51-60` | 删掉 `_tResourcePath/_tVersion/_tVersionNote/_tFileSize/_tUnzipCode/_resourceTypes/_languages/_platforms/_officialResourceId` 这组单条状态；替换为 `List<OfficialResourceDraft> _resources = []` |
| `189-191` | 编辑回填时不再直接塞 `g.downloadUrl` 等，改为构造一条主资源草稿 |
| `237-276` `_loadOfficialResource` | 改名为 `_loadOfficialResources`：`perPage` 1 → 200，`sort: '-created'` 保留；逐条转 `OfficialResourceDraft`；若 `games.downloadUrl` 不在其中，则补一条主资源草稿放在首位 |
| `497-587` `_save` | 拆成 `_submit({required bool isUpdate})`；`body` 里的 `downloadUrl` / `version` / `versionNote` 改为从**主资源草稿**取（兼容旧客户端）；`_isEdit ? update : create` 逻辑不变 |
| `589-629` `_syncOfficialResource` | 改为 `_syncOfficialResources(gameId, title, {required bool rebuild})`：<br>· `rebuild=false`（保存）：拉取云端现有 official 列表 → 逐条 diff（草稿有 id 的 update、无 id 的 create、云端多余且不在草稿里的 delete）<br>· `rebuild=true`（更新）：先读旧记录快照 → 全部 delete → 逐条 create，并按 `title + version` 匹配把 `download_count` / `like_count` 回填到新记录<br>· 统计字段被 `lock_fields.pb.js` 锁定时，超管 token 可直接写；若被拒则降级为不迁移并提示 |
| `670-686` 顶栏 actions | 编辑模式下新增「更新」按钮（`OutlinedButton.icon`，图标 `Icons.cloud_upload_outlined`）；新建模式不显示 |
| `1264-1377` `_resourceCard` | 整块替换为 `OfficialResourceEditorCard(value: _resources, onChanged: ...)`；`subtitle` 改为「一个作品可挂多个版本（原版 / 重制版 / 社区魔改版），客户端会全部列出」 |
| `202-224` `dispose` | 同步清理删掉的 controller |

新增确认弹窗 `_confirmUpdate()`：
> 标题：确认「更新」？
> 内容：将用当前表单内容**整体替换**云端数据。
> · 保留：作品 id、上架/审核状态、下载量与点赞数（数值）
> · 重建：官方资源记录全部删除后重新创建，**点赞明细会清空**
> · 不可撤销
> [取消] [确认更新]

#### 4.4 改 `gametool/ct_cloud_admin/lib/services/resource_service.dart`

只**新增**方法，不动既有 `officialBody` / `create` / `update` / `delete`：

- `static Future<List<GameResource>> listOfficial(String gameId)` —— 按 game 拉全部 official（供 diff 与迁移匹配）；
- `static Future<Map<String, ({int downloadCount, int likeCount})>> snapshotStats(...)` —— 可选，若页面直接处理则不新增。

#### 4.5 改 `gametool/ct_cloud_admin/lib/pages/resources_page.dart`

**不改逻辑**。仅确认 `_ResourceEditorDialog`（`:503`）仍可单独维护某条 official 资源，保证多资源场景下仍能单条修/删。

---

### 阶段二：主管理器（消费多资源）

#### 4.6 改 `lib/models/game_resource_model.dart`

`OfficialResourceView`（`:582-676`）新增工厂：

```dart
/// 从 game_resources 的 official 记录构造（多资源列表用）。
factory OfficialResourceView.fromRecord(GameResourceModel r, {DateTime? fallbackCreated}) 
```
- `downloadPath: r.downloadPath`
- `title: r.title.isEmpty ? '游戏本体' : r.title`
- `version/versionNote/fileSize/downloadCount/resourceTypes/platforms` 取记录值
- `created: fallbackCreated ?? r.created`
- `record: r`

保留既有 `fromGame`（`:647`）不变 —— 它继续负责「`games` 原生单资源」的兜底。

新增便捷 getter：`String get id => record?.id ?? ''`（去重与打点用）。

#### 4.7 改 `lib/pages/game_detail_page.dart`

| 行号 | 改法 |
|---|---|
| `994-1003` `_primaryOfficial` | 保留不动（其他位置仍在用） |
| `1015-1028` `_officialResource` | 保留不动 —— 它仍是「本作是否有官方资源」与安装状态判定的唯一依据 |
| 新增 `_officialResourceList` | 合并逻辑：<br>① 遍历 `_officialResources`，凡 `hasDownloadPath` 的转 `fromRecord`；<br>② 若 `games.downloadUrl` 非空且**没有任何记录的 download_path 与之相同**，在最前面插入一条 `fromGame`（主资源）；<br>③ 若相同，把匹配上那条的记录信息覆盖到主资源视图上并提到首位；<br>④ 结果按「主资源优先，其余 `created` 倒序」排序 |
| `741-816` `_handleInstallTap` | 签名改为 `Future<CtDownloadOutcome> _handleInstallTap(OfficialResourceView res)`；`gamePath` 改取 `res.downloadPath`；统计打点用 `res.id` |
| `1108-1136` `_handleGetTap` | 传 `resources: _officialResourceList`；`onDownload: _handleInstallTap` |
| `1031-1041` `_installState` | 不改（仍按 gameId 判定，见 §6 已知限制） |
| `1095-1105` `_resolveGetBlockReason` | 「暂无官方下载」的判据加一层：`_officialResourceList.isEmpty`（原来只看单条） |

#### 4.8 改 `lib/widgets/game_detail/ct_download_dialog.dart`

| 行号 | 改法 |
|---|---|
| `87-133` 构造参数 | `resource`（单条）改为 `resources`（`List<OfficialResourceView>`，非空）＋ 保留 `resource` 作为 **单条快捷构造**（`resources = resource == null ? const [] : [resource]`，内部统一走列表）⇒ 既有 7 个测试的挂载方式不用改 |
| `125` `onDownload` | 签名扩参：`Future<CtDownloadOutcome> Function(OfficialResourceView resource)?` |
| `220-263` `build` | 列表模式：`Column(mainAxisSize:min)` 里把「单卡」换成 `Flexible(child: SingleChildScrollView(child: Column(children: [每行一条])))`，避免条目多时被 `dark_surface.dart:831-837` 的 maxHeight 裁掉 |
| `241-255` 单卡 | 抽成 `_buildResourceRow(res, index)`：<br>· 第一行 `[资源类型][平台][版本号]` 徽章（沿用 `_buildBadgeRow` 的配色）<br>· 第二行 `名称（title）` + 右对齐「大小 + 下载按钮」<br>· 有 `versionNote` 时第三行整行换行展示<br>· 行间 6px 分隔线 |
| 弹窗标题区 | 右上角显示 `共 N 个版本` 小徽章（N>1 时） |
| `_busy` / `_error` | 改为按资源 id 记录：`String? _busyId; Map<String,String> _errors`，避免点 A 版本时 B 版本按钮也转圈 |
| `_handleDownloadTap` | 带上被点的 `resource` |
| 弹窗宽度 | `DarkPalette.downloadBarWidth` 515 → 列表模式用 560（新增常量 `downloadListWidth`），保证「版本徽章 + 名称 + 大小 + 按钮」一行不挤 |

#### 4.9 改 `test/widgets/game_detail/ct_download_dialog_test.dart`

- `:137/:162/:174/:204` 等处 `() async => ...` 补一个 `(_) async => ...` 参数；
- 新增用例：
  1. 两条资源 → 两行都渲染、两个下载按钮、点第二个回调拿到第二条；
  2. 八条资源 → 无溢出异常（`takeException()` 为 null），且弹窗高度不超可用高；
  3. 单条资源的既有 7 个用例全部保持通过（向后兼容验证）。

---

## 5. 影响面

| 模块 | 影响 |
|---|---|
| PocketBase schema | **无改动** |
| `games.downloadUrl` / `version` / `versionNote` | 语义收窄为「主资源镜像」，仍由上传工具写入，旧客户端行为不变 |
| 安装链路 `CloudInstallFlow` / `GlobalInstallCenter` | **不改**，只是传入的 `downloadPath` 从固定一条变成用户所选那条 |
| 探索库 / 详情页布局 | 弹窗从单卡变列表；详情页其余区域不动 |
| BPM 模式 | 无下载入口，不受影响（已 grep 确认 `lib/big_picture/` 无 `downloadUrl` 引用） |
| 旧数据 | 只有一条 official 记录的作品，列表长度 = 1，UI 退化为现在的样子 |

---

## 6. 风险点与已知限制

| 级别 | 风险 | 处置 |
|---|---|---|
| P0 | 更新时删除资源记录导致 `resource_likes` 明细级联删除 | 确认弹窗明写「点赞明细会清空」，数值迁移保留 |
| P0 | 弹窗列表多了之后超出 `maxHeight` 被裁（项目历史高频坑） | 用 `Flexible + SingleChildScrollView`，并配「8 条资源不溢出」测试 |
| P1 | `installCount` / `download_count` 被 `lock_fields.pb.js` 锁定，更新时写入被拒 | 超管 token 通常可绕过；若被拒则捕获后跳过并提示，不中断整体更新 |
| P1 | 同一作品多版本安装：`GlobalInstallCenter` 与 `_isLocallyInstalled` 都按 `gameId` 去重 | **本次不改**。已安装后仍可再点下载其他版本（tooltip 已是「已安装 · 点击重新下载」），安装目录冲突由用户在选择安装位置时决定。列入后续独立需求 |
| P1 | `FileSizePrefetchService` 缓存 key 是 `file_size_$gameId`，多资源会串大小 | 多资源行的大小优先取 `game_resources.file_size`（后台手填）；为空则不显示，**不**按 gameId 预取 |
| P2 | 保存时列表里被删掉的资源 → 云端删除，误删无回收站 | 保存前若检测到「将删除 N 条资源」，弹二次确认列出标题 |
| P2 | 上传工具无任何测试（`gametool/ct_cloud_admin/test/` 为空） | 本次不强行补全，改为：改造后手动跑通「新建 1 作品 + 3 资源 → 客户端可见 3 条」验收 |

---

## 7. 验证方式

**上传工具**
1. 新建作品，添加 3 条资源（原版 / 重制版 / 汉化版，其中主资源放第一位）→ 保存 → 到 PB 后台确认 `game_resources` 有 3 条 `kind=official`、`games.downloadUrl` = 主资源路径；
2. 重新打开该作品编辑页 → 3 条都回填、顺序与主资源标记正确；
3. 删除中间一条 → 保存 → 云端剩 2 条；
4. 点「更新」（改标题 + 改资源列表）→ 确认云端 `download_count` / `like_count` 数值保留、`review_status` 未回退、资源条数正确。

**主管理器**
1. `./flutter/bin/flutter.bat analyze lib/widgets/game_detail/ct_download_dialog.dart lib/pages/game_detail_page.dart lib/models/game_resource_model.dart`
2. `./flutter/bin/flutter.bat test test/widgets/game_detail/ct_download_dialog_test.dart`
3. 手动：打开上述作品详情 → 点「获取」→ 看到 3 个版本 → 分别点下载，确认传给 `CloudInstallFlow` 的 `downloadPath` 是各自那条（看日志 `[DETAIL] 经共享安装流提交...` 前的路径）；
4. 只有 1 条 official 记录的旧作品 → 弹窗与改动前视觉一致。

**回归**
- `./flutter/bin/flutter.bat test test/widgets/game_detail/`

---

## 8. 明确不做（本次范围外）

- ❌ 不新建 PB 集合、不改任何 `pb_migrations`、不改 `pb_hooks`
- ❌ 不改 `CloudInstallFlow` / `GlobalInstallCenter` / `InstallConfirmationDialog`（多版本安装去重是独立需求）
- ❌ 不改 `pubspec.yaml`、不改 `lib/main.dart`、`main_container.dart`、`lib/theme/`
- ❌ 不改 `resources_page.dart` 的审核/删除逻辑
- ❌ 不做版本快照 / 回滚（用户已选「覆盖更新」）
- ❌ 不让客户端展示"更新历史"

---

## 9. 提交计划（一个任务一个 commit）

1. `feat(admin): 官方资源支持一个作品多版本（内嵌列表 + 增量同步）`
2. `feat(admin): 新增「更新」模式——资源整体重建并迁移下载量/点赞数`
3. `feat(explore): 详情页「获取」弹窗支持多官方资源列表（MULTI-RESOURCE）`
4. `test(explore): 多资源弹窗用例 + 既有 7 用例兼容验证`
5. `docs: 记录 MULTI-RESOURCE 与 ADMIN-UPDATE 决策`

---

## 10. 实施结果（2026-11-03，与计划的差异）

### 已落地

| 文件 | 状态 |
|---|---|
| `gametool/ct_cloud_admin/lib/models/official_resource_draft.dart` | 新增 |
| `gametool/ct_cloud_admin/lib/widgets/official_resource_editor.dart` | 新增 |
| `gametool/ct_cloud_admin/lib/pages/game_editor_page.dart` | 改（资源状态 / `_submit` / `_syncOfficialResources` / 顶栏「更新」/ `_resourceCard`） |
| `gametool/ct_cloud_admin/lib/services/resource_service.dart` | 改（+`listOfficial`） |
| `lib/models/game_resource_model.dart` | 改（+`fromRecord` / `id`） |
| `lib/pages/game_detail_page.dart` | 改（+`_officialResourceList`、`_handleInstallTap(res)`、`_handleGetTap`、两处判据） |
| `lib/widgets/game_detail/ct_download_dialog.dart` | 改（单卡 → 列表，向后兼容单条） |
| `lib/widgets/game_detail/dark_surface.dart` | 改（+`downloadListWidth = 560`） |
| `test/widgets/game_detail/ct_download_dialog_test.dart` | 改（7 例适配签名 + 3 例新增） |

### 与计划不一致的两处（有意为之）

1. **列表状态标识改用「下标」而不是 `listKey`（路径 / 记录 id）**。
   原因：两条不同版本完全可能被填成同一个 `download_path`，按路径做 key 会让点赞数、
   转圈态、错误文案串到另一行。下标在浮层生命周期内稳定（列表不会重排），更可靠。
2. **弹窗顶部增加资源标题徽章**（粉底 `Icons.sell_outlined`）。
   原因：`version` 是版本号（v1.0），用户口中的「原版 / 重制版 / 社区魔改版」实际存在
   `title` 字段，而原实现根本没渲染 `title` —— 不补这一枚徽章，列表里两行会长得一模一样。
   与类型徽章里的「游戏本体」同名时自动去重。

### 验证结果

- 进程内静态分析（231 环境）：管理台 4 文件、客户端 5 文件 **0 error**。
- 离线 widget 探针（kernel + `flutter_tester.exe`，落点 `.workbuddy/probe_multi/`）：
  - 客户端 13/13 PASS
  - 管理台 12/12 PASS
- ⏳ 待补：`flutter analyze lib`、`flutter test test/widgets/game_detail/`、真机走查、真云端联调。

### 提交状态

**未提交。** 原因：`lib/pages/game_detail_page.dart` 的工作区版本混有他人未提交的
KUNGAL 相关改动（`_kungalId` / `_resolveKungalLink` / `_handleOpenKungal`），整文件
`git add` 会把他人的改动一并带走；而 `ct_download_dialog.dart` 的签名变更与
`game_detail_page.dart` 的调用点必须同一次提交才能编译通过，故整体暂缓。
`gametool/` 目录本身未被 Git 跟踪（`?? gametool/`），其改动不进版本库。
