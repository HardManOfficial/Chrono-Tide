# 统一审核机制 — 变更计划（编辑即重新上传 + 删除审核）

> **阶段 A 只读审计产出（2026-10-02）** —— 依据 `AGENTS.md` §2.2，**本计划未获批前不写任何代码**。
> 需求：① published 资源支持「编辑即重新上传」（回收下架→改→重审，不丢数据）；
> ② 作品/资源删除须管理员审核；③ 发布 / 编辑 / 删除三类操作统一纳入审核。
>
> **状态（2026-10-02 上午）：开发者批准（"按推荐"）→ 阶段 B 实施 ⭐**
> - **B1 服务端 ✅**：本地实例 schema 扩展 + `lock_fields` v6 + 状态机全矩阵探针 **38/38 全绿**。
> - **B2 客户端 ✅**：6 文件改动，进程内 analyzer errors=0。
> - **B3 上线 🟡**：线上 schema **已直改完成**（备份 `pb_backup/*_before_unified_review.prod.json`，
>   回读校验 10/10）；定版包 **v9**（`pb_hooks_deploy_20261002_unified_review_v9.zip`，仅
>   `lock_fields.pb.js` 1 文件）——**待开发者部署 → 线上探针（`pb_tmp/probe_prod_unified_review.py`）**。
> - **B4 收尾 ⏳**：开发者重构建 exe 走查（编辑流/删除流/撤回）→ 管理员指南已更新（新队列裁决）。
>
> **实施修正记录（纸上设计 → 实测修正，3 处）**：
> 1. 计划 §2.3-A 的 updateRule「追加 `&& status != "pending_delete"`」会把 published 记录
>    整个 PATCH 拦成 404 ⇒ **published→editing 的发起根本到不了 lock_fields**。实测改为
>    完整期望式：未进库记录可改字段 + 显式放行三个 owner 转换（发起编辑 / 申请删除 /
>    撤回删除）。lock_fields 白名单同样补 `published>pending_delete` / `approved>pending_delete`。
> 2. PB 0.34 规则语法用 **`@request.body.*`**（`@request.data.*` 报
>    `validation_invalid_rule`）。
> 3. 全矩阵探针价值实证：第二轮 27/37 → 修正后 38/38；两处探针自身 bug
>    （g5 setup 未先转 approved、DELETE 复核误取状态码）亦由矩阵暴露。

---

## 1. 现状梳理（审计结论）

### 1.1 集合规则与状态集（线上现状，来源：`pb_backup/pre-stats-*/` 快照）

| 规则 | 原文 | 问题 |
|---|---|---|
| `game_resources.updateRule` | `owner=自己 && kind="community" && status != "published"` | 🔴 published 后**服务端直接不可编辑**（404） |
| `game_resources.deleteRule` | `owner=自己 && kind="community"` | 🔴 任何状态**直接真删**（含 published），无审核 |
| `games.updateRule` | `owner=自己 && origin="user" && review_status != "approved"` | approved 不可编辑（同上） |
| `games.deleteRule` | `owner=自己 && origin="user"` | 🔴 任何状态直接真删 + **级联删名下全部资源** |
| `games.listRule/viewRule` | `登录 \|\| review_status="approved"` | 登录可见他人 pending/rejected（现状）；新状态需排除 |
| `game_resources.listRule` | `official \|\| (community && published) \|\| owner=自己` | ✅ 非 published 自动下架，无需改 |

- `game_resources.status` values：`pending / published / rejected / hidden`（hidden 已有、客户端枚举已支持）
- `games.review_status` values：`approved / pending / rejected`
- `lock_fields.pb.js` v5.1：超管豁免 ✅；`games.review_status` **全锁**；`game_resources.status` 唯一白名单 `rejected→pending`（owner 本人）

### 1.2 客户端现状

- 【我的】（`docs_my_tab.dart`）：published 资源**编辑按钮禁用**（提示"如需下架请直接删除"）；删除按钮任何状态**直接真删**（仅一个确认框）；作品同理。
- `GameResourceService.updateMine` 支持 `resubmit`（rejected→pending）；`deleteMine` 直接 DELETE。
- `GamePublishService.updateMyGame` **不传 review_status**（被锁）⇒ 🔴 **现存 bug**：rejected 作品编辑保存后提示"重新进入审核队列"是**假的**——状态仍是 rejected，管理员 pending 队列看不到（`game_publish_service.dart:188-245` + 【我的】`docs_my_tab.dart:555`）。
- 探索库大厅列表（`game_repository.dart:52-110`）**不过滤审核状态**（listRule 放行）。

### 1.3 审核队列现状

管理员 = PB Admin UI（`http://117.72.115.30:8090/_/`）按 status 过滤手工改状态，已有《管理员审核指南》（`features/admin_review_guide_20261001.md`）。

---

## 2. 统一审核机制设计

### 2.1 状态集扩展（两个集合各加 2 个 select 值）

| 新状态 | 语义 | 可见性 |
|---|---|---|
| `editing` | **编辑中**（原已进库内容下架暂存，作者可改字段） | 仅作者（规则天然保证） |
| `pending_delete` | **删除待审**（下架，等管理员裁决） | 仅作者 |

### 2.2 状态流转图（以 game_resources 为例；games 同构，published↔approved 互换）

```
                         ┌────────── 管理员通过 ──────────┐
pending ────────────────────────────► published ──驳回──► rejected
   ▲                                    │                    │
   │ rejected→pending（已有白名单）       │发起编辑   修改重提──┘（已有白名单）
   │                                    ▼
   │                      editing（下架暂存，作者可改字段）
   │                                    │提交（字段+status 一起）
   └──────────── editing→pending ◄──────┘  ⇒ 回到 pending 重新审核

published ──申请删除──► pending_delete ──管理员通过──► 真删除（记录消失）
                            │  └─管理员拒绝 / 作者撤回──► published（数据统计零丢失）
pending/rejected/editing ──作者直接删──► 真删除（未进库，无需审核）
```

**关键语义**：
- `editing` / `pending_delete` 期间**记录与统计（download_count/like_count）全部保留**，拒绝删除恢复 published 后继续累计——彻底解决"删了重传数据全丢"。
- `pending_delete → published`（作者撤回）恢复的是**审核过的原内容**（该状态下 updateRule 禁改字段），语义安全。
- `editing → published` **不开白名单**（editing 下字段可能已改，直通会造成未审先上架）。

### 2.3 服务端改动（3 处）

**A. schema（线上超管 API 直改，先备份原定义；本地实例先行验证）**

| 集合 | 改动 |
|---|---|
| `game_resources` | status values += `editing`, `pending_delete` |
| `games` | review_status values += `editing`, `pending_delete` |
| `game_resources.updateRule` | += `&& status != "pending_delete"`（editing 保持可编辑） |
| `game_resources.deleteRule` | += `&& status != "published" && status != "pending_delete"` |
| `games.updateRule` | += `&& review_status != "pending_delete"` |
| `games.deleteRule` | += `&& review_status != "approved" && review_status != "pending_delete"` |
| `games.listRule/viewRule` | `review_status = "approved" \|\| (@request.auth.id != "" && review_status != "editing" && review_status != "pending_delete") \|\| owner = @request.auth.id`（大厅排除他人编辑/待删；作者恒可见自己） |

**B. `lock_fields.pb.js` v6（白名单扩展，全部要求 owner 本人 + String() 收窄 + fail-closed）**

| 集合.字段 | 放行的转换（owner 本人） |
|---|---|
| `game_resources.status` | `rejected→pending`（已有）｜ `published→editing` ｜ `editing→pending` ｜ `pending_delete→published` |
| `games.review_status` | `rejected→pending`（**修现存 bug**）｜ `approved→editing` ｜ `editing→pending` ｜ `pending_delete→approved` |

**C. 管理员操作（Admin UI，零新开发）**：pending_delete 通过 = 直接 Delete 记录；拒绝 = 状态改回 published/approved。更新《管理员审核指南》+ AI 审核台快照脚本扩展（review_desktop.py 显示 editing/pending_delete）。

### 2.4 审核不通过时的回退处理（需求点名）

| 场景 | 回退 |
|---|---|
| 首发驳回 | pending → rejected（现状不变） |
| **编辑重提驳回** | → rejected，**保留修改后数据**；可再改再提（白名单已有）或直接删（未进库）。⚠️ 如实说明：**重提后原内容不可恢复**（无版本链），发起编辑的确认弹窗将明确提示"重新提交后原内容不再保留" |
| **删除被拒 / 作者撤回** | pending_delete → published/approved，数据与统计零丢失 |
| 编辑中放弃 | 无"恢复"通道（防未审先上架）；只能提交审核或直接删除（未进库） |

---

## 3. 决策点（4 个 · 附推荐）

| # | 决策 | 推荐 | 理由 |
|---|---|---|---|
| 1 | 作品（games）是否同样纳入"编辑即重新上传" | **纳入** | 需求③"编辑云端游戏数据"涵盖作品；同构改动增量小；**顺带修复 rejected 作品重提失效的现存 bug** |
| 2 | 删除审核的发起范围 | **仅已进库**（published/approved）；未进库（pending/rejected/editing）保持直接删 | 对齐需求原文"**进入探索库后**发起删除"；未进库内容无保护价值，避免队列噪音 |
| 3 | 是否提供"撤回删除请求"（pending_delete→published 白名单） | **提供** | 恢复的是审核过的原内容，语义安全；一条白名单的成本换来反悔能力 |
| 4 | 编辑驳回后旧版是否可恢复（版本快照） | **v0 不做**，UI 明确提示 | 快照字段+恢复链路成本高；作者本人持有原链接/提取码，可手动改回 |

---

## 4. 开发计划（批准后执行）

| 步骤 | 内容 | 验证 |
|---|---|---|
| B1 服务端 | 本地实例改 schema（values+规则）→ `lock_fields.pb.js` v6 → 状态机探针（**全转换矩阵 + 越权矩阵 + 回退路径 + 清理零残留**） | 本地探针全绿 |
| B2 客户端 | 枚举/getter（`game_resource_model.dart` / `game_model.dart`）→ service 状态转换方法（`game_resource_service.dart` / `game_publish_service.dart`）→ 【我的】交互（`docs_my_tab.dart`：发起编辑两步流 / 申请删除 / 撤回删除 / 徽章文案） | 进程内 analyzer 0 新增 error |
| B3 上线 | commit → 定版包 **v9**（仅 lock_fields 1 文件）→ 线上 schema 直改（备份先行）→ 开发者部署 → 线上探针验收 | 线上探针全绿 |
| B4 收尾 | 开发者重构建 exe 走查（编辑流/删除流/撤回）→ 审核指南更新 → 文档/日志同步 | 走查确认 |

**明确不改**：探索库大厅/详情页的展示 UI、发布三步流本体、统计路由/举报路由、`hidden` 状态的既有语义、所有非本机制的集合规则。

---

## 5. 风险

| 风险 | 缓解 |
|---|---|
| 白名单开多后出现未预料的流转组合 | fail-closed 原则不变；探针跑**全矩阵**（合法转换放行 + 其余全部锁死） |
| 线上 schema 改 values/规则时失误 | 改前备份集合定义（同 owner_avatar 先例）；本地实例先行全绿 |
| 老客户端与新状态并存期 | 老客户端不认识 editing/pending_delete 时按 default 处理（pending/未知）——仅显示退化，无数据风险 |
