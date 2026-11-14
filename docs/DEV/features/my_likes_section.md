# 「我的喜欢」二级分段 —— 设计与变更计划

> 状态：**已批准并实施完毕（2026-10-03）**。Phase 1 作品级（commit `59daf5c`）+
> Phase 2 资源级（本 commit）。**Phase 2 依赖 v12 迁移部署**（见下）。
> 需求（开发者 2026-10-03）：详情页「喜欢」功能已上线（v11 线上验收 29/29）但
> **没有查看端闭环**——喜欢了没地方看。在探索页文档板块【我的】tab 增加二级分段
> 「我的喜欢」，展示喜欢的**作品**与喜欢的**资源**。三项拍板均按推荐：
> 两 Phase 都做 / 列表项带取消按钮 / 分段内子胶囊。
> 创建：2026-10-03　审计人：潮汐

---

## 0. 实施状态（2026-10-03）

| Phase | 内容 | 状态 |
|---|---|---|
| P1 作品级 | `fetchMyLikedGames()` + 「我的喜欢」分段 + 取消喜欢 | ✅ commit `59daf5c`，analyzer errors=0 |
| P2 服务端 | 迁移 `1790991000_updated_resource_likes_rules.js`（resource_likes list/view → 本人可见，写侧不动）；本地探针 **19/19 全绿** | ✅ 已定版：`pb_hooks_deploy_20261003_resource_likes_rules_v12.zip`（仅 1 迁移文件） |
| P2 客户端 | `fetchMyLikedResources()` + 分段内「作品/资源」子胶囊 + 资源级取消喜欢 | ✅ 本 commit；**v12 部署前资源列表静默空**（规则 null = 普通用户空集），部署后自动生效 |
| 线上验收 | `pb_tmp/probe_prod_resource_likes.py`（19 断言，与本地同套件） | ⏳ 待开发者部署 v12 后执行 |

---

## 1. 现状审计结论

### 1.1 详情页「喜欢」链路本身是通的

| 环节 | 位置 | 状态 |
|---|---|---|
| 点亮/取消 + 乐观更新 + 失败回滚 | `game_detail_page.dart:1139` `_handleLikeTap` | ✅ |
| 进页回显点亮态 | `game_detail_page.dart:144` initState `_loadLikeState` → `:1173` | ✅ |
| 服务端 like/unlike 路由 | `game_stats.pb.js`（v11 已部署，线上探针 29/29） | ✅ |
| **查看自己的喜欢列表** | **全库不存在** | ❌ **唯一断点** |

结论：所谓「没完全走通」= 闭环缺了查看端，而非按钮失灵。

### 1.2 数据侧能力（决定两个 Phase 的拆分）

| 维度 | 作品级（games 级） | 资源级（resource 级） |
|---|---|---|
| 点赞集合 | `game_likes`（pbc_1167737315） | `resource_likes`（pbc_1167737304） |
| 读规则 | list/view = `user = @request.auth.id` **本人可查** ✅ | **5 规则全 null** ⇒ 本人无法查询 ❌ |
| 关联字段 | `game` 是 relation → games（`1790990010_created_game_likes.js:29-41`）⇒ **`expand=game` 一跳拿全** | 同构 relation ⇒ 修规则后同样可 expand |
| 服务端改动 | **零** | 需 v12 部署（只改 resource_likes 读规则） |

> 🔴 `resource_likes` 规则全 null 正是 §14.4 记录过的软缺陷根源（它的客户端回显
> 静默失效）。「喜欢的资源」要成立，必须先修它的 list/view 规则。

### 1.3 「我的」tab 现有结构（改动落点）

- 分段控件：`docs_my_tab.dart:177` `_segment(index, label)`，`_section` 现 0=我的作品 / 1=我的资源（`:162-163`）；
- 数据加载：`_load()`（`:62`）登录后双查询 + 错误累加；
- 跳详情：`onOpenDiscoverGame` 回调（`:34`）→ 宿主 `docs_section.dart:216-218` → `explore_hall_page.dart:259`，作品卡片跳探索详情**链路现成**；
- 刷新：宿主切回【我的】tab 自动 `reload()`（`docs_section.dart:193`）——从详情页取消喜欢回来切一下 tab 即刷新，**零改动**；
- 解析器：`GameModel.fromPBRecord`（`game_publish_service.dart:179` 在用），expand 子记录可直接喂。

---

## 2. 变更计划

### Phase 1 —— 喜欢的作品（纯客户端，一个 commit，零服务端改动）

**改 1**：`lib/services/game_resource_service.dart` 新增 `fetchMyLikedGames()`

```
game_likes.getFullList(sort: '-created', expand: 'game')
```
- listRule 已限定本人可见，**无需 user filter**；
- expand 缺失项跳过（作品已删/驳回不可见——PB 对不满足规则的关联记录直接丢弃）；
- 返回 `List<({GameModel game, DateTime likedAt})>`（Dart record，喜欢时间用于列表展示）；
- 个人点赞量级（几十~几百）远低于 perPage 上限，一次拉全，不做分页。

**改 2**：`lib/widgets/explore_hall/docs_my_tab.dart`

| 位置 | 改法 |
|---|---|
| `:45-49` 状态区 | +`_likedGames` 列表 |
| `:62` `_load()` | 并入第三查询 `fetchMyLikedGames()`（try/catch 与现有错误累加一致） |
| `:162-163` | +`_segment(2, '我的喜欢 (${_likedGames.length})')` |
| `:119` 分支 | `_section == 2` → `_likeList()` |
| 新增 `_likeList()` | 空态：「还没有喜欢的作品。到作品详情页点 ♡ 收藏吧」；列表项 = 标题 + likeCount + 开发者 · 喜欢日期 + **右侧取消喜欢心形按钮**（`setGameLike(id, false)` 成功后本地移除）；点击项 → `widget.onOpenDiscoverGame?.call(g)` |
| `:140` `_loginHint` | 文案补「、查看喜欢的作品」 |

**明确不改**：详情页喜欢逻辑（已通）；`game_stats.pb.js` / `lock_fields.pb.js`（零变更）；games 任何规则；宿主 `docs_section.dart`（reload 已具备）。

### Phase 2 —— 喜欢的资源（需 v12 部署，与 Phase 1 分开提交）

**服务端（1 个迁移文件 + v12 包）**：
- `pb_migrations/1790991000_updated_resource_likes_rules.js`：`resource_likes` 的
  listRule/viewRule → `user = @request.auth.id`；**写侧 create/update/delete 保持
  全 null**（hook 超管通道，零 hook 变更）；
- 本地 8091 实例迁移 + 探针（本人可查 / 他人查不到 / 匿名查不到 / expand 正常）→
  定版包 `pb_hooks_deploy_20261003_resource_likes_rules_v12.zip`（仅 1 迁移文件）。

**客户端**：
- `game_resource_service.dart` +`fetchMyLikedResources()`（`expand=resource`，形态对齐改 1）；
- 「我的喜欢」分段内顶部两个**子胶囊**「作品 (n) / 资源 (m)」（复用 `_segment` 样式缩小）；
- 部署前安全性：查询失败静默空列表（catch + debugPrint，与现有容错一致），**部署前后都安全**。

### 风险点

| # | 风险 | 对策 |
|---|---|---|
| 1 | expand 丢记录 → 分段计数与实际不符 | 计数取**实际列表长度**（可展示的），不取 like 记录数 |
| 2 | 取消喜欢与详情页点亮态不一致 | 无共享状态（详情页每次进页自查），天然一致 |
| 3 | Phase 2 部署前资源查询 404 | 静默空列表（写明于代码注释），不阻塞作品级 |
| 4 | `setGameLike` 取消失败 | 按钮恢复原态 + SnackBar（乐观更新模式，与详情页一致） |

### 验证方式

- Phase 1：进程内 analyzer（改动文件）；真机走查清单（§3）。
- Phase 2：本地实例探针（本人可见/他人不可见/匿名不可见/expand）→ 线上探针（部署后）。

## 3. 真机走查清单（实施后）

- [ ] 详情页点 ♡ → 切到【我的】→「我的喜欢」出现该作品，计数正确
- [ ] 「我的喜欢」列表点击作品 → 跳探索详情页
- [ ] 列表内取消喜欢 → 项消失；进详情页确认未点亮
- [ ] 取消喜欢后切走再切回【我的】→ 列表已刷新（宿主 reload）
- [ ] 未登录 → 登录提示文案含「喜欢的作品」；本地态同
- [ ] （Phase 2 部署后）资源子胶囊：上传资源详情页点赞 → 列表出现
