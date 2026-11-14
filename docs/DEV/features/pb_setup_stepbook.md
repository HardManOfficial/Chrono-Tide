# PocketBase 后台配置操作手册（第 2/3/4/6 步）

> **配套文档**：`explore_resource_sources_plan.md` v4
> **PB 版本**：0.34.2（已确认支持 `pb_hooks`）
> **服务器**：`http://117.72.115.30:8090`
> **生成时间**：2026-09-29
>
> **使用方式**：本文是**纯操作手册**。每一步都给出"点哪里 / 填什么 / 粘贴什么",
> 你按顺序照做即可。所有字段名、选项值、规则文本都已在下方给出**可直接复制**的原文。

---

## 🟢 执行状态（2026-09-29 深夜 · 第二次更新）

> 开发者已授权 AI 代做后台配置。**第 1/2/3/4/5/6 步已全部完成并验收**。
> 本手册保留作为**操作说明与事后追溯依据**；如需重做或换环境，可直接照抄。

| 步骤 | 状态 | 实际结果 |
|---|---|---|
| 0 版本探测 | ✅ | 0.34.2，`pb_hooks` 可用 |
| 1 备份 | ✅ | `.workbuddy/pb_backup/`（12 个文件） |
| 2 建 `game_resources` | ✅ | `pbc_439050043`，21 字段 |
| 3 `games` 加 7 字段 | ✅ | 20 → 27 字段 |
| 3b 回填 298 条 | ✅ | `origin='official'` + `review_status='approved'`（298/298） |
| 4 配规则 | ✅ | `games`/`game_resources` 共 10 条 |
| 5 加固 `users` | ✅ | 5 条规则，修复越权 P0 |
| **5b 收紧用户名录** | ✅ | **本轮新增**：`listRule` → `id = @request.auth.id` |
| **5c 启用限流** | ✅ | **本轮新增**：`rateLimits.enabled = true`（原为 false） |
| **5d 配置 OTP** | ✅ | **本轮新增**：`otp` 6 位 / 180 秒（**受 SMTP 阻塞**） |
| 6 部署 Hook | ✅ | 开发者已部署；**但实测发现 bug，需重新部署 v2**（见下） |

---

### 🔴 第 6 步 Hook 的 bug（v1 → v2，必须重新部署）

**现象**：`game_resources` 的任何 PATCH 都返回
`400 {"data":{},"message":"Something went wrong while processing your request."}`
——**连超管也一样报错**，因此极易被误判成"权限问题"。

**根因**：v1 对字段用了**类型专用 getter**：

```js
e.record.set("owner", orig.getString("owner"));      // ❌ owner 是 relation 字段
e.record.set("created", orig.getString("created"));  // ❌ created 是 autodate 字段
```

`relation` / `select` / `json` / `number` 等类型用错 getter 会在 Hook 内部**抛异常**，
整个请求变成 400。`games` 侧因为恰好都用了对口的 getter 才没暴露。

**v2 修复**：统一改用**类型无关**的写法：

```js
const lock = (name) => { e.record.set(name, orig.get(name)); };
lock("owner");   // ✅ 不关心类型
lock("created");
```

> 📌 **可复用规则**：在 pb_hooks 里还原字段值，一律用 `orig.get(name)` + `e.record.set(name, v)`，
> **不要用 `getString` / `getNumber` / `getBool` 等类型专用 getter**。

**验证结果（v2 部署后）**：

| 测试 | 结果 | 说明 |
|---|---|---|
| `games` 改 `review_status: approved` | 被还原为 `pending` ✅ | 自审通过被拦 |
| `games` 改 `title` | 正常生效 ✅ | 正常字段不受影响 |
| `game_resources` 必填字段核对 | — | `kind` ∈ {official, community}、`status` ∈ {pending, published, rejected, hidden}、`title` 必填 |

**v2 部署后完整实测（2026-09-29 深夜，用临时探针账号，测完即删）**：

| 测试 | 结果 | 说明 |
|---|---|---|
| `games` 探针改 `review_status: approved` | HTTP 200，落盘仍 `pending` ✅ | **自审通过被拦** |
| `games` 探针改 `origin: official` | HTTP 200，落盘仍 `user` ✅ | 提权被拦 |
| `games` 探针改 `title` | HTTP 200，新值生效 ✅ | 普通字段不受影响 |
| `game_resources` 探针改 `status: published` | HTTP 200，落盘仍 `pending` ✅ | 自审通过被拦 |
| `game_resources` 探针改 `kind: official` | HTTP 200，落盘仍 `community` ✅ | 提权被拦 |
| `game_resources` 探针改 `title` | HTTP 200，新值生效 ✅ | **v1 的 400 已消失** |
| 数据复核 | games 298 / game_resources 0 / users 180 ✅ | 探针全部清理，无残留 |

> ✅ **结论：Hook v2 已确认生效**。`game_resources` 的 400 已彻底消失，受保护字段
> 无论通过什么身份提交都会被还原为原值，普通字段正常放行。

> 📌 **探测方法学（本仓踩过的坑）**：
> ① 用**临时探针账号**（可逆、用完即删），不要用真实账号做实验；
> ② 必须让**探针自己创建**目标记录 —— 超管创建的记录 `owner=超管`，探针改它会先被
> `updateRule` 拒成 **404**，请求根本进不到 Hook，测不出 Hook 行为（本轮第一版脚本就踩了这个坑）；
> ③ 建记录必须填**必填字段**（`games.downloadUrl`、`game_resources.title`），否则 400 是校验错误而非权限问题。

---

### 🔴 用户名录三连加固（本轮新增）

**问题**：`users.listRule` 原为 `@request.auth.id != ""` —— 任何登录用户可拉取**全部 180 个
用户的 ID / 昵称 / 头像 / 注册时间**。

**为什么是问题**：① 用户 ID 是 `game_resources.owner` / `games.owner` 的关联靶子；
② 180 条昵称+头像 = 一份可被爬走的社区名册；③ **本功能不需要它** ——
来源展示读的是 `game_resources.owner_name` 冗余字段，不查 users 表。

**依赖核查（收紧前必做，已做）**：

| 客户端调用点 | 身份 | 是否受影响 |
|---|---|---|
| `auth_service.dart:266` 邮箱查重 | 超管 token | ❌ 超管绕过规则 |
| `auth_service.dart:383` 重置密码 | 超管 token | ❌ |
| `auth_service.dart:556/570` 昵称查重 | 超管 token | ❌ |
| `auth_service.dart:1023` 上传自己头像 | 本人 token | ✅ 需 `viewRule` 允许看自己 —— 已满足 |

**已收紧**：`listRule` = `viewRule` = `updateRule` = `deleteRule` = `id = @request.auth.id`

**限流（本轮新增启用）**：

| 规则 | 值 | 作用 |
|---|---|---|
| `*:auth` | 5 次 / 10 秒 | 防暴力撞库 |
| `*:create` | **3 次 / 60 秒** | **防批量刷号** |
| `/api/batch` | 3 次 / 1 秒 | 防批量操作 |
| `/api/` | 300 次 / 10 秒 | 全局兜底 |

实测：连续注册第 4 次起返回 `429` ✅

---

### ⚠️ 验证码现状：**能力已就绪，但被 SMTP 阻塞**

#### 先讲人话：SMTP 是什么，为什么会"卡住"

- **SMTP** 就是"**发邮件的通道**"（可以理解成邮局）。PB 要把验证码发到用户邮箱，
  必须走你家自己的一个邮箱去发，而"允许程序替你发信"的钥匙叫 **授权码**。
- **现在的状态**：PB 这台服务器上，"邮局"这一栏**还没填**（host 仍是占位的
  `smtp.example.com`，`enabled: false`）。
- **"卡住"是什么意思**：PB 的验证码功能（生成 6 位数、保存 180 秒）**本身是好的**，
  接口 `/request-otp` 也**正常返回 200**。所以从外部看像"发成功了"，
  但**实际上邮件根本没寄出去**——因为邮局栏是空的。这种"看着成功、实际没发"的状态，
  就叫"卡在 SMTP 上"。
- **换句话说**：现在注册流程**不能马上对外放开**。必须先填上邮局这一格。

#### 三层现状表

| 项 | 状态 |
|---|---|
| PB OTP 能力 | ✅ 已启用（6 位 / 180 秒），`POST /api/collections/users/request-otp` 返回 `otpId` |
| SMTP 邮件服务 | ❌ **未配置**（`enabled: false`，host 仍是 `smtp.example.com`） |
| 实际发信 | ❌ **失败**（PB 日志 `lvl=8` 报错，但接口对客户端仍返回 200） |

> 🔴 **两个必知事实**：
> 1. **现有 180 个用户全部 `verified: false`** —— 因此**绝不能**开启"必须邮箱验证才能登录"，
>    否则整批老用户会被锁死（且 SMTP 未配，他们也收不到验证邮件）。
> 2. **SMTP 未配时 `request-otp` 静默失败**：接口返回 200，但邮件发不出去。
>    客户端若不校验后续步骤，会给用户"验证码已发送"的假象。

---

### 🎯 老用户 / 新用户策略（开发者 2026-09-29 指定，已确证可实现）

> 开发者原话：**"针对这个老用户，我们不做处理……不用做验证，不用再让它重新去做验证，
> 就默认它这个账户是已经建立成功；但是新用户，也就是在我们开放完之后，这个新用户
> 就走我们的验证码流程。"**

| 用户群 | 规模 | 处理方式 | 技术手段 |
|---|---|---|---|
| **老用户** | 现有 180 个 | **完全不动**：无需验证、无需重新验证，照常登录 | `authRule` **保持为空**，`verified` 保持 `false` 也不影响登录 |
| **新用户** | 开放后注册 | **必须过邮箱验证码** | 注册流程改为两步（先拿 OTP → 再注册），并在 create 阶段做服务端兜底 |

🔴 **关键取舍（为什么不能用 PB 自带的"必须验证才能登录"开关）**：
PB 的 `authRule` 是**全局**的。一旦把邮箱设成"必须已验证才能登录"，
**现有 180 个 `verified=false` 的老账号会立刻全部无法登录** —— 直接违反"老用户不做处理"。
因此**正确做法是不开这个全局开关**，而是**只在注册路径上做 OTP 校验**：
老用户不经过注册路径，天然不受影响。

> 👉 **验证码落地的前置条件（唯一需要开发者做的事）**：
> 提供一个支持 SMTP 的发件邮箱（QQ 邮箱 / 163 / 企业邮均可），
> 在其邮箱后台**开启 SMTP 服务并取得"授权码"**，把
> **邮箱地址 + 授权码** 发给 AI。取得后 AI 可全自动配置 PB 并**实测发一封真邮件**验证。

---

### ⚠️ 补充章节：`users` 集合的 P0 漏洞

**发现**：`users` 集合 5 条规则**原本全为空** ⇒ 任何注册用户可**修改/删除任意他人账号**。
实测已确证（改他人 200、删他人 204），并进行了修复。

**当前 5 条规则（已在后台生效）**：

| 规则栏 | 值 | 说明 |
|---|---|---|
| List/Search | `id = @request.auth.id` | **本轮收紧**，名录不再可见 |
| View | `id = @request.auth.id` | 单条只能看自己 |
| Create | *(留空)* | **有意开放注册**（App 需要注册入口） |
| Update | `id = @request.auth.id` | 只能改自己 |
| Delete | `id = @request.auth.id` | 只能删自己 |

> 🔴 **关键机制（避免误判为"没生效"）**：在 `updateRule = id = @request.auth.id` 下，
> **改他人记录会返回 404 而不是 403**。原因：PB 先按规则解析出"你能看到的记录集"，
> 他人记录对你不可见 ⇒ 视同"不存在" ⇒ 404。
> **404 = 已拦住**；403 只在"记录可见但操作被拒"时出现。

### ⚠️ 语法修正（本轮实测踩坑）

| 坑 | 正确做法 |
|---|---|
| 规则里引用请求体字段 | **0.34.2 必须用 `@request.body.xxx`**；写成 `@request.data.xxx` 报 `invalid left operand` |
| 创建集合时带 `@request.body.*` 规则 | **创建时会解析失败** → 必须**先建集合（不带规则）→ 再 PATCH 补规则** |
| relation 字段 | `collectionId` **必填**真实 id：users 为 `_pb_users_auth_`，games 为 `pbc_879072730` |
| 新增字段的既有记录 | PB **不会**自动填默认值 → 会得到 `''`，**必须手动回填**（本轮已回填 298 条） |
| 判定规则是否生效 | 规则拒绝 → `400` + `data:{}` **空**；已放行进业务层 → `400` + `data` 含字段级 `Cannot be blank` |
| **pb_hooks 中还原字段值** | **必须用 `orig.get(name)`**，⛔ 不要用 `getString` / `getNumber` / `getBool`（类型不符即整请求 400） |
| 探测写权限 | ⛔ 「不存在的 id」**无效**（PB 一律先返 404）；✅ 用**临时探针账号**做可逆操作 |

---

## ⚠️ 前置：`games` 规则原文（✅ 已取得，结论如下）

**开发者从 PB 后台抄回的原文（PB 0.34.2）**：

| 规则栏 | 原文 |
|---|---|
| **List/Search** | `@request.auth.id != ""` |
| **View** | *(空)* |
| Create | *(空)* |
| Update | *(空)* |
| Delete | *(空)* |

### 🔴 由此确认两件事

**① v3/v4 稿子里「`games` 公开可读」是错的**
List 规则 `@request.auth.id != ""` → **未登录只能看到空列表**（与实测 0 条吻合）。

**② `games` 当前「匿名可写」——这是 P0 漏洞**

实测（只读探测，未产生任何数据）：

```bash
$ curl -X POST ".../api/collections/games/records" \
       -H "Content-Type: application/json" -d '{}'
{"data":{"downloadUrl":{"code":"validation_required","message":"Cannot be blank."},
         "title":{"code":"validation_required","message":"Cannot be blank."}},
 "message":"Failed to create record.","status":400}
```

**判定**：返回 **400（字段校验失败）而非 403（无权限）** → 请求**已被规则放行**。
按 PB 语义，**规则留空 = 对所有人生效**，因此：

> 🔴 **任何人（含未登录）目前都可以创建 / 修改 / 删除 `games` 的全部 298 条数据。**

| 项 | 说明 |
|---|---|
| 为什么现在没出事 | 大概率只是接口地址未公开，**不是因为有防护** |
| 为什么必须现在修 | 本功能会让客户端调用这个接口，**App 一发出去，地址就不再保密** |
| 修复成本 | **零**——第 4 步填规则时顺手补上 |

> ⚠️ 本节不阻塞你继续做第 2、3 步，但**第 4 步必须认真做完**。

---

## 第 1 步：备份 PB 数据

| 项 | 内容 |
|---|---|
| **`users`** | ✅ **已由 AI 通过只读 API 导出**（180 条）→ `.workbuddy/pb_backup/users_anon.json`（31.7KB，含 id/name/avatar/verified/created/updated，**不含邮箱等敏感字段**） |
| **`games`** | ⚠️ **AI 无法代导出**——`games` 的 List 规则限制了匿名读取（实测 0 条），必须你在后台操作 |

### 1.1 `games` 的两条备份路径（任选，**推荐第 2 条**）

**路径 A：单集合 Export（快）**

PB 后台 → `games` 集合 → 右上 `⋯` → `Export` → 得到 `games.json`

**路径 B：导出集合定义（推荐）**

PB 后台 → **Settings** → **Export collections** → 勾选 `games` → Export

> 💡 **推荐 B 的理由**：它导出的是**集合定义（含 5 条规则原文）**，
> 既完成数据备份，**又留档了"改规则前的原始状态"**——一旦改错，可据此精确回滚。
> 这正是第 4 步改规则前最需要的保险。

### 1.2 交付

放本地任意目录即可，**只需告诉我"已备份 + 路径 + 用的是 A 还是 B"**（不必发我，含隐私数据）。

---

## 第 2 步：新建 `game_resources` 集合

### 2.1 创建集合

PB 后台 → 左侧 `+ New collection` → 类型选 **Base collection** → Name 填：

```
game_resources
```

> ⚠️ **不要勾选** "Auth collection"。这是普通数据表。

### 2.2 添加字段（逐条照抄）

点 `+ New field`，按下表逐条添加。**类型列**是 PB 界面里的下拉选项名。

| # | Name | Type | 配置 |
|---|---|---|---|
| 1 | `game` | **Relation** | Collection: `games`；**Max select: 1**；**Cascade delete: 勾选** |
| 2 | `kind` | **Select** | Values 填 **3 行**：`official` / `community`；Max select: **1** |
| 3 | `title` | **Plain text** | Max length: **200**；**Required: 勾选** |
| 4 | `download_path` | **Plain text** | Max length: **1000** |
| 5 | `version` | **Plain text** | Max length: **60** |
| 6 | `version_note` | **Plain text** | Max length: **300** |
| 7 | `url` | **URL** | — |
| 8 | `link_type` | **Select** | Values 填 **3 行**：`netdisk` / `direct` / `other`；Max select: **1** |
| 9 | `netdisk_provider` | **Select** | Values 填 **9 行**（见 2.3）；Max select: **1** |
| 10 | `extract_code` | **Plain text** | Max length: **30** |
| 11 | `file_size` | **Plain text** | Max length: **60** |
| 12 | `owner` | **Relation** | Collection: `users`；**Max select: 1** |
| 13 | `owner_name` | **Plain text** | Max length: **60** |
| 14 | `source_note` | **Plain text** | Max length: **200** |
| 15 | `note` | **Plain text** | Max length: **500** |
| 16 | `status` | **Select** | Values 填 **4 行**：`pending` / `published` / `rejected` / `hidden`；Max select: **1**；**Required: 勾选** |
| 17 | `reject_reason` | **Plain text** | Max length: **300** |
| 18 | `report_count` | **Number** | 默认 **0**；Only int: 勾选 |

### 2.3 `netdisk_provider` 的 9 个值（逐行填）

```
baidu
quark
aliyun
xunlei
115
onedrive
mega
google_drive
other
```

### 2.4 保存

点右上 `Save changes`。

> 📌 **`created` / `updated` 是 PB 自动带的**，不要手动加——它们就是"上传时间"的数据来源。
> ⚠️ 若界面上看到系统字段区，确认 `created` 是 **Create** 类型（服务端生成、不可改）。

---

## 第 3 步：为 `games` 补 7 个字段

> 从截图看，`games` 现有字段：`id` / `title` / `description` / `coverUrl` / `tags` /
> `downloadUrl` / `Developer` / `screenshots` / `file_size` / `created` / `updated`。
> **以下 7 个全部是新增，不修改任何现有字段。**

PB 后台 → Collections → `games` → 点集合名进入编辑 → `Fields` 标签页 → `+ New field`。

| # | Name | Type | 配置（重要） |
|---|---|---|---|
| 1 | `origin` | **Select** | Values: `official` / `user`；Max select: 1；**默认值填 `official`**（见下方说明） |
| 2 | `owner` | **Relation** | Collection: `users`；Max select: 1 |
| 3 | `creator_name` | **Plain text** | Max length: **60** |
| 4 | `contributors` | **JSON** | Max size: **100000**（留空即可，默认写 `[]`） |
| 5 | `review_status` | **Select** | Values: `approved` / `pending` / `rejected`；Max select: 1；**默认值填 `approved`** |
| 6 | `has_official` | **Bool** | 默认不勾（false） |
| 7 | `community_count` | **Number** | 默认 **0**；Only int: 勾选 |

### 3.1 如何设置"默认值"（PB 0.34.2）

Select 字段的默认值设置位置：字段编辑面板 → 展开 **`Options`** →
找到 **`Default`** 或勾选 **`Required`** 后出现的默认下拉 → 选 `official` / `approved`。

> 🔴 **这两个默认值极其重要**：
> - `origin` 默认 `official` → **298 条既有记录自动全部视为官方作品**，行为不变；
> - `review_status` 默认 `approved` → 既有作品**立刻可见**，不会被"待审核"挡住。
>
> 若 PB 在保存时提示"已有记录需回填"，选择**用默认值批量填充**即可。

### 3.2 保存后立即自检（重要）

保存后，**在 PB 后台 `games` 列表页**确认：

1. 总数仍是 **298**（没有记录消失）；
2. 随便点开 1 条记录，能看到 `origin` = `official`、`review_status` = `approved`、`contributors` = `[]`。

> ⚠️ 若 `contributors` 显示为空而非 `[]`，属正常（PB JSON 空值渲染差异），
> 只要不报错即可。

---

## 第 4 步：配置访问规则

### 4.1 ⚠️ 两个先决条件（顺序不可颠倒）

1. **第 3 步必须先完成**——下方 List 规则引用了 `review_status` 字段。
   **字段不存在时 PB 会报规则解析错误**，可能使集合进入异常状态。
2. **`games` 必须先备份**——见第 1 步的 Export 操作。

### 4.2 `games` 规则（**五栏全填**）

进入 `games` → `API Rules` 标签页。**逐栏粘贴下方内容**：

**List/Search rule**（替换现有的 `@request.auth.id != ""`）：

```
@request.auth.id != "" || review_status = "approved"
```

**View rule**（现在为空，填上）：

```
@request.auth.id != "" || review_status = "approved"
```

**Create rule**（现在为空 🔴 **必填**）：

```
@request.auth.id != "" && @request.data.origin = "user" && @request.data.owner = @request.auth.id && @request.data.review_status = "pending"
```

**Update rule**（现在为空 🔴 **必填**）：

```
owner = @request.auth.id && origin = "user" && review_status != "approved"
```

**Delete rule**（现在为空 🔴 **必填**）：

```
owner = @request.auth.id && origin = "user"
```

> ✅ **`Set Superusers only` 按钮不要点**。它是"仅超管可访问"的快捷方式，
> 会把该规则**替换**为超管专属，普通用户将完全无法使用——与我们的设计不符。

**逐条语义**：

| 规则 | 语义 | 防的是什么 |
|---|---|---|
| List/View | 登录用户看全部（含自己 pending 的）；**未登录只能看 `approved`** | 未登录不可见待审内容 |
| Create | 必须登录 + 只能建 `user` 来源 + 只能挂自己 + **强制 `pending`** | ① **匿名建记录（修现漏洞）**；② 投稿者写 `approved` **自审通过** |
| Update | 只能改自己的、只能改 `user` 作品、**已通过的不能再改** | ① **匿名篡改任意记录（修现漏洞）**；② 审核通过后偷换 `downloadUrl`（投毒） |
| Delete | 只能删自己的 `user` 作品 | **匿名删除任意记录（修现漏洞）** |

### 4.3 `game_resources` 规则（**五栏全填**）

进入 `game_resources` → `API Rules` 标签页：

**List 规则**（与 View 完全相同）：

```
kind = "official" || (kind = "community" && status = "published") || owner = @request.auth.id
```

**View 规则**：

```
kind = "official" || (kind = "community" && status = "published") || owner = @request.auth.id
```

**Create 规则**：

```
@request.auth.id != "" && @request.data.kind = "community" && @request.data.owner = @request.auth.id && @request.data.status = "pending"
```

**Update 规则**：

```
owner = @request.auth.id && kind = "community" && status != "published"
```

**Delete 规则**：

```
owner = @request.auth.id && kind = "community"
```

**逐条解释**：

| 规则 | 含义 |
|---|---|
| List/View | 官方来源**任何人可见**；社区来源**只有已发布的**对他人可见；**提交者自己**能看自己的（含 pending） |
| Create | **必须登录** + 只能建 `community` + **只能挂自己** + 强制 `pending`（防止绕过审核直接公开） |
| Update | 只能改自己的、只能改 community、**已发布的不能再改**（防"审核通过后偷换链接"） |
| Delete | 只能删自己的 community 来源 |

> 🔴 **Create 里的 `@request.data.kind = "community"` 是硬边界**：
> 它保证了**任何登录用户都无法创建官方来源**。官方来源只能由你在后台手工建。
>
> 📌 **注意**：`game_resources` 的 List/View **不要**加 `@request.auth.id != ""`，
> 否则未登录用户看不到别人分享的资源（与"分享要曝光"的初衷相悖）。

### 4.4 保存

点 `Save changes`（两集合各保存一次）。

### 4.5 ✅ 保存后自检（我会做，你也可以先自查）

保存后告诉我，**我会用匿名 `curl` 复测**：

```bash
# 预期：从 400 变成 403（说明匿名创建已被拦住）
curl -s -X POST ".../api/collections/games/records" -H "Content-Type: application/json" -d '{}'
```

| 返回 | 含义 |
|---|---|
| **403** | ✅ 修复成功，匿名已无法写入 |
| **400** | ❌ 规则未生效（检查是否点错 `Set Superusers only` 或未保存） |

---

## 第 6 步：部署 Hook（防提权）

### 6.1 版本确认

PB 0.34.2 **支持** `pb_hooks`（v0.23+ 引入 JSVM 插件机制）。✅ 可用。

### 6.2 创建 Hook 文件

在你服务器上 PB 可执行文件所在目录（即 `pocketbase.exe` 同级），创建目录 `pb_hooks`，
在其中新建文件：

```
pb_hooks/lock_fields.pb.js
```

内容（**完整复制粘贴，一行都不要改**）—— **v2（已修复类型 getter bug）**：

```js
/// <reference path="../pb_data/types.d.ts" />
onRecordUpdateRequest((e) => {
  const c = e.collection.name;
  const orig = e.record.original();

  // 类型无关的锁定写法 —— 不要用 getString/getNumber/getBool
  const lock = (name) => {
    e.record.set(name, orig.get(name));
  };

  if (c === "games") {
    lock("origin");
    lock("review_status");
    lock("has_official");
    lock("contributors");
  }

  if (c === "game_resources") {
    lock("kind");
    lock("status");
    lock("report_count");
    lock("owner");
    lock("created");
  }

  e.next();
}, "games", "game_resources");
```

> 🔴 **v1 的致命写法（勿再使用）**：
> `orig.getString("owner")` —— `owner` 是 relation 字段，`getString` 会在 Hook 内部抛异常，
> **导致该集合的所有 PATCH 一律返回 400**，且**超管也同样报错**（极易误判为权限问题）。

> ⚠️ **注意首行注释**：`/// <reference path="../pb_data/types.d.ts" />` 不能删，
> 它是 PB 的类型提示声明，删掉不影响运行但会失去编辑器补全。

### 6.3 重启 PB

```bash
# 在 PB 目录下
./pocketbase.exe serve --http=0.0.0.0:8090
```

> 若你用 Windows 服务 / 计划任务方式托管，**重启该服务**即可。

### 6.4 验证 Hook 生效

重启后，PB 控制台会打印类似：

```
[lock_fields] loaded
```

或至少**不报错**。若报错（如 `syntax error`），把控制台输出发我。

---

## 完成情况回报清单（2026-09-29 深夜最终版）

| # | 步骤 | 执行方 | 结果 | 状态 |
|---|---|---|---|---|
| 0 | PB 版本探测 | AI | 0.34.2，`pb_hooks` 可用 | ✅ |
| 1 | 备份 | AI | `.workbuddy/pb_backup/` 5 个文件（含 298 条 games、180 条 users） | ✅ |
| 2 | 建 `game_resources` | AI | `pbc_439050043`，**21 字段** | ✅ |
| 3 | `games` 补 7 字段 | AI | **20 → 27 字段** | ✅ |
| 3b | 回填 298 条 | AI | `official` + `approved`，**298/298** | ✅ |
| 4 | 配规则 | AI | `games`+`game_resources` **10 条** | ✅ |
| 5 | **加固 `users`** | AI | **本轮新增，5 条规则**（修 P0 越权） | ✅ |
| 6 | **部署 Hook v2** | **开发者** | 已重新部署 | ✅ **实测已生效**（见上表） |
| 7/8/9 | 文案 / 造数据 / 定验收 | AI | 随后进行 | ⬜ |
| **10** | **配置 SMTP** | AI | ✅ **已打通**：`465 + tls=true`，开发者亲眼确认收到 `OTP for Chrono Tide`（验证码 095774，2026-09-30 00:10） | ✅ **已闭环** |
| **11** | **注册验证码（新用户）** | 开发者+AI | Hook v2 开发者已重新部署，AI **实测拦截已生效**（无令牌/伪令牌注册均被拒） | ✅ **实测已生效** |

### ✅ 已完成：Hook 部署（第 6 步）

无需再操作。AI 已用探针账号实测确认 v2 生效（受保护字段被还原、普通字段放行、400 消失）。

### 🟢 第 10 步：SMTP —— 根因查实并已修正（2026-09-30 凌晨）

| 项 | 值 |
|---|---|
| 发件邮箱 | `3195541266@qq.com` |
| SMTP 主机 | `smtp.qq.com` |
| 端口 / 加密 | **465 / 隐式 TLS**（`tls=true`）← 已修正 |
| 应用名 | `Chrono Tide` |

#### 🔴 根因（修正上一轮的"服务器网络阻断"误判）

**`SMTPConfig.tls` 的真实语义**（对照官方 v0.34.2 `types.d.ts:13308-13315`）：

> `tls`: Whether to enforce TLS encryption for the mail server connection.
> **When set to `false` StartTLS command is send**, leaving the server to decide whether to upgrade.

即：
- `tls = true` → **强制隐式 TLS**（一连接就 TLS）→ 对应 **465**
- `tls = false` → **发 STARTTLS 命令**（先明文后升级）→ 对应 **587**

**上一轮的配置 `587 + tls=true` 是错的** —— 用"一连接就 TLS"去连一个"期待 STARTTLS"的端口，
对端返回的是明文 SMTP 问候语，PB 却按 TLS 解析 → 必然报
`tls: first record does not look like a TLS handshake`。

**修正动作**：改 `port=465, tls=true`（QQ 邮箱官方推荐组合）。

#### ✅ 修正后实测（2026-09-30 00:10）—— **端到端确认送达**

| 时间 | 配置 | 结果 |
|---|---|---|
| 16:10:29 | **465 + tls=true** | 无任何错误日志 |
| 16:10:54 | **465 + tls=true**（复测） | 无任何错误日志 |

判定依据：`level>=4` 日志查询返回 **0 条**（不再出现 `Failed to send OTP email`）。
7 条历史失败日志的时间全部早于配置修正（15:48–16:08）。

> ✅ **最终闭环证据（开发者截图确认，2026-09-30 00:17）**：
> 收件箱收到 **`OTP for Chrono Tide`**，发件人 `3195541266@qq.com`，
> 时间 **2026-09-30 00:10**（正对应 16:10 UTC 那次修正后测试），
> 正文：`Your one-time password is: 095774` / 署名 `Chrono Tide team`。
>
> ⇒ **SMTP 发信链路完全打通，"无报错"经送达确认坐实。第 10 步闭环。**

#### 📌 附：历史失败矩阵（配置错误时期，仅供参考）

| 端口 | tls | 结果 |
|---|---|---|
| 587 | **true** | `tls: first record does not look like a TLS handshake` ← **错误组合** |
| 587 | false | `EOF`（未复测，现配置已改） |
| 465 | true | 修正前为 `EOF`（当时密码/配置混杂） |
| 25 | any | `read tcp ...:25: wsarecv: forcibly closed` ← 京东云**确**封 25 出站 |

#### 📌 京东云 25 端口政策（已查实，备查）

京东云官方公告《关于华南区云主机25端口限制通知》
（`jdcloud.com/cn/notice/detail/204`）明确：
**为防垃圾邮件，云主机 25 端口出站被限制**，且"其他区域将会按计划陆续执行"。
- 官方建议：改用**企业邮箱**，或**提交工单申请解封**（需企业实名 + 说明用途）。
- 影响：**不影响** 465/587 —— 那两条是客户端提交端口，不在封禁范围。

> ✅ **故"改用云厂商邮件推送服务"的建议作废** —— 465 既然能用，无需换方案。

### ✅ 第 11 步：注册验证码 —— 开发者已部署，AI **实测拦截生效**

#### 实测结果（2026-09-30 00:06）

| # | 用例 | 期望 | 实测 | 结论 |
|---|---|---|---|---|
| 1 | `POST /api/ct/verify-register-otp` 空参 | 400 自定义消息 | `缺少参数：otpId / code 均为必填。` | ✅ 路由已加载 |
| 2 | 伪 `otpId` | 400 | `验证码不正确或已过期，请重新获取。` | ✅ 校验链正常 |
| 3 | **无令牌注册** | 拒绝 | `注册需要邮箱验证码…` | ✅ **拦截生效** |
| 4 | 无效令牌（body 传） | 拒绝 | `注册令牌无效，请重新获取验证码。` | ✅ 令牌校验生效 |
| 5 | 老用户登录（错误密码） | `Failed to authenticate.` | 一致 | ✅ 未被误锁 |

#### 🔴 第六坑（本轮新发现）：`X-Register-Token` **请求头读不到**

用例 4 用 **请求头** `X-Register-Token` 传伪令牌时，返回的是"**缺少令牌**"而非"**令牌无效**"
—— 说明**请求头没被读到**，落在了 body 兜底路径上。

**原因**：`e.request.header.get(...)` 里的 `e.request` 是 Go `*http.Request`，
其 `Header` 字段类型为 `map[string][]string`，JSVM 不暴露 Go 的 `Get()` 方法。

**正确写法**（对照 `types.d.ts:9158-9165`，`RequestInfo.headers` 是 `_TygojaDict`，
**且只含每个 header 的第一个值**）：

```js
// ✅ 推荐
const token = (e.requestInfo().headers["x-register-token"] || "").trim();
```

> ⚠️ **当前 Hook 版本**：header 路径失效，**依赖 body `regToken` 兜底**（实测可用）。
> 若客户端走 body 传令牌则功能完整；若走请求头则会被判为"缺少令牌"而拒绝
> （**安全上偏保守，不会误放行**）。
> **建议**：下次改 Hook 时补上 `requestInfo().headers` 读取。

---

### 🔴 第 12 步（本轮）：P0 架构缺陷 —— 内置 `request-otp` 只对已注册用户发码

#### 现象（2026-09-30 实测定证）

用**未注册邮箱** `brand_new_user_never_registered@example.com` 调
`POST /api/collections/users/request-otp`：

- 返回 **200 + 空壳 `otpId`**（形如 `agoer7rwjtn4xmx`）——**看起来成功了**；
- **但 `_otps` 表无任何记录**、**邮箱收不到信**；
- PB 日志：`lvl=8 missing or invalid users OTP auth record with email brand_new_user...`；
- 拿该 `otpId` 调 `/api/ct/verify-register-otp` → 400。

对照：**已注册邮箱** `3195541266@qq.com` → `sentTo` 有值、**真发信**（开发者已收到）。

#### 根因

PB 0.34.2 的 `request-otp` 是**为「已有用户」设计的登录/重置场景**：
`_otps` 记录的 `recordRef` 必填且必须指向一个**已存在的 users 记录**。
新用户注册时邮箱**必然不存在**于 users → 无 record 可挂 → PB 静默跳过建码与发信，
却仍返 200（**这是 PB 的行为缺陷，不是配置问题**）。

后果：**新用户注册流程天然死锁**——收不到码，就永远拿不到注册令牌。

#### 解法：Hook 自建发信通道（已实现，待部署）

绕开内置接口，自己建码 + 自己发信：

1. **新集合 `register_otps`**（id `pbc_3399060580`）
   字段：`email`(text, 唯一索引 `idx_register_otps_email`) / `code_hash`(text) /
   `expires_at`(**text**，存 Unix 秒数字文本) / `attempts`(number) / `request_ip`(text)；
   规则**全部 `None`**（仅服务端 Hook 可读写，客户端完全不可见）。

2. **`POST /api/ct/request-register-otp`**（新路由）
   ```
   入参：{ email }
   流程：邮箱格式校验
      → 🔴 决策 A：查 users，已注册 → 409 { code: "email_already_exists",
                                              message: "该邮箱已被注册，请直接登录。" }
      → 清该邮箱旧记录（唯一索引，必须先删）
      → 冷却判断：距上次不足 60s → 429 { retryAfterSeconds }
      → 生成 6 位纯数字码 $security.randomStringWithAlphabet(6, "0123456789")
      → code_hash = $security.hs256(email + "|" + code, HASH_SECRET)
      → 落库 register_otps（expires_at = nowSec + 180，存文本）
      → $app.newMailClient().send(new MailerMessage({
           from: { address: settings.meta.senderAddress, name: settings.meta.senderName },
           to:   [{ address: email }],
           subject: "OTP for Chrono Tide",
           html: "...<b>" + code + "</b>..."
         }))
      → 200 { otpId: record.id, expiresInSeconds: 180 }
   发信失败：明确报错 + 回删刚建的记录（不留下永远收不到的码）
   ```

3. **`POST /api/ct/verify-register-otp`**（改造：数据源不再用 `$app.findOTPById`）
   ```
   入参：{ otpId, code }
   流程：$app.findRecordById("register_otps", otpId)
      → 过期判断（expires_at 文本 → parseInt 比对 nowSec；过期则删记录 + 400）
      → 尝试次数（attempts >= OTP_MAX_ATTEMPTS → 删记录 + 400）
      → 摘要比对 hs256(email|code)（不符 → attempts+1 存回 + 400）
      → 通过 → 消费记录（一次性删除）
      → 签发自签令牌 token = email + "|" + exp + "|" + hs256(email|exp, SECRET)
      → 200 { regToken: token, email }
   ```

4. **`onRecordCreateRequest(handler, "users")`**（补 header 读取）
   注册必须带令牌；**双通道**读取：先 `e.requestInfo().headers["x-register-token"]`，
   失败回退 `e.requestInfo().body.regToken`。校验签名 + 过期 + 邮箱与本次注册一致。

#### 🔴 设计取舍：刻意规避 DateTime 类型

`expires_at` **存 text 型 Unix 秒数字**，而非 `date` 型 —— 因为本仓曾因
「类型专用 getter」踩坑（见第 6 步 v1 bug：`game_resources` 全部 PATCH 400）。
读取一律 `parseInt(String(rec.get("expires_at")))`；冷却判断用
`expires_at - OTP_TTL_SEC` 反推创建时刻（见下方第七坑），
**全程不碰任何 DateTime 转换**。

#### 🔴 第七坑（本轮实测踩出）：⛔ 不可 `new Date(PB 的 created 文本)`

**现象**：同邮箱 1 秒内连发两次验证码，**两次都返回 200**（应第二次返回 429）
→ **冷却机制静默失效**。

**根因**：PB 的 autodate 文本格式是 **`2026-04-25 09:41:47.922Z`**——日期与时间
用**空格**分隔，**不符合 ISO 8601**（标准要求 `T`）。Goja（PB 的 JS 引擎）对
`new Date("2026-04-25 09:41:47.922Z")` 返回 **Invalid Date** → `NaN`
→ 冷却判断被 `isNaN` 分支默默跳过。

**修法**（已落地）：**不解析任何时间文本**，改用本 handler 自己写入的
`expires_at`（Unix 秒文本）做纯整数算术：

```js
const expSec = parseInt(String(oldRecord.get("expires_at") || ""), 10);
const createdSec = expSec - OTP_TTL_SEC;          // 创建时刻 = 过期时刻 - TTL
const ageSec = Math.floor(Date.now() / 1000) - createdSec;
if (ageSec >= 0 && ageSec < RESEND_COOLDOWN_SEC) { /* 429 */ }
```

> 📌 **通用教训**：在 PB 的 pb_hooks 里，**任何需要"解析时间"的逻辑都不要碰
> `new Date(...)`**。要时间就自己存 / 自己算 Unix 秒（`Math.floor(Date.now()/1000)`）。

#### 🔴 第四坑【更正】（2026-09-30 发现）：超管判定的写法**原记录是错的**

> 这条不是新坑，是**对上文"超管判定"那条旧结论的更正** —— 旧写法实测**恒判 false**。

**原记录（错）**：`e.requestInfo.hasSuperuserAuth()`，
理由是"`e.hasSuperuserAuth()` 在 RecordRequestEvent 上不存在"。
**结论：两条都错。**

**实测现象**：超管用 API 建用户 → 被自己的注册 Hook 拦下，返回
`注册需要邮箱验证码：请先获取验证码并完成校验后再提交注册。`
⇒ **管理员在 PB 后台也建不了账号**（后台 UI 同样走 API）。
症状极具迷惑性：**不报错、不 500，只是永远走"非超管"分支**。

**根因**（对照官方 v0.34.2 `types.d.ts`）：

| 写法 | 是否存在 | 说明 |
|---|---|---|
| `e.hasSuperuserAuth()` | ✅ **存在** | `interface RequestEvent { hasSuperuserAuth(): boolean }`（`types.d.ts:9141`）——旧记录说它"不存在"是错的 |
| `e.requestInfo().hasSuperuserAuth()` | ✅ 存在 | `RequestInfo` 上也有同名方法（`types.d.ts:9171`）；**`requestInfo` 是方法**（`types.d.ts:9150` `requestInfo(): RequestInfo`） |
| `e.requestInfo.hasSuperuserAuth()` | ❌ **会抛错** | 在**方法对象**上调用 → Goja 报 "not a function" → 被外层 `try/catch` 吞掉 → **`isSuperuser` 恒为 false** |

**修法（已落地）**：双通道 + 兜底，任一可用即可：

```js
let isSuperuser = false;
try { isSuperuser = e.hasSuperuserAuth(); } catch (err) { isSuperuser = false; }
if (!isSuperuser) {
  try { isSuperuser = e.requestInfo().hasSuperuserAuth(); } catch (err) { isSuperuser = false; }
}
if (isSuperuser) { return e.next(); }   // 超管放行
```

> 📌 **通用教训**：`e.requestInfo` 是**方法**，凡是要读 body / headers / 超管态，
> 一律写成 **`e.requestInfo().xxx`**（**别漏括号**）。
> 更隐蔽的是：**包在 `try/catch` 里的 API 误用 = 静默失效**——
> 建议凡 `try/catch` 兜底的判定，都要在真机上验证"该为 true 时确实为 true"，
> 而不是"没报错就放心"。

#### ✅ 实测结果（2026-09-30 00:45，开发者部署后）

| # | 用例 | 期望 | 实测 | 结论 |
|---|---|---|---|---|
| 1 | 空邮箱 | 400 自定义 | `请输入邮箱地址。` | ✅ 路由已加载 |
| 2 | 非法邮箱格式 | 400 | `邮箱格式不正确。` | ✅ |
| 3 | **已注册邮箱** | 409 | `{"code":"email_already_exists",...}` | ✅ 决策 A 生效 |
| 4 | **未注册邮箱** | 200 + otpId | `{"expiresInSeconds":180,"otpId":"g6u6..."}` | ✅ 建码 + **发信未抛错** |
| 5 | 伪 otpId 验码 | 400 | `验证码不正确或已过期…` | ✅ |
| 6 | 无令牌注册 | 400 | `注册需要邮箱验证码…` | ✅ 拦截回归通过 |
| 7 | 匿名查 `register_otps` | 403 | `Only superusers can perform this action.` | ✅ 规则全 None 生效 |
| 8 | 令牌 2 段（格式错） | 400 | `注册令牌无效…` | ✅ |
| 9 | 令牌签名被篡改 | 400 | `注册令牌无效…` | ✅ |
| 10 | 令牌已过期（合法签名） | 400 | `注册令牌已过期…` | ✅ **签名算法交叉验证通过** |
| 11 | 错码连打 6 次 | 第 6 次拒绝 | 前 5 次"不正确"，第 6 次"错误次数过多" | ✅ `OTP_MAX_ATTEMPTS=5` 精确 |
| 12 | 1 秒内重发同邮箱 | 429 | **200** ❌ → 见第七坑（已修） | 🔴 修复待再部署 |

> ⚠️ **用例 10 说明**：AI 用 Hook 内明文密钥自行签发了一个**已过期**的合法令牌 →
> 服务端返回「已过期」而非「无效」，**反证**签名算法与 Hook 完全一致
> （若算法不符会落到「无效」分支）。这是低成本高价值的交叉验证手法。

> ⚠️ **未覆盖**：**"验码通过 → 拿令牌 → 注册成功"** 全链路需**真实邮箱收码**，
> 尚未做（留给开发者真机走查）。此外 `*:create` 限流（3 次/60 秒/IP）
> 在测试中被触发过一次 429 —— 正常用户不受影响，但若用户多次失败重试
> 有被限流风险，**记录为观察项，未擅自放宽**。

#### ⏱ 接口耗时特性（补充实测）

| 接口 | 常态耗时 | 最坏观测 | 说明 |
|---|---|---|---|
| `/api/ct/request-register-otp` | 1.7–4.5s（均 2.93s） | **51.8s** | 服务端**同步**发信（`$app.newMailClient().send()`），偶发 SMTP 抖动 |
| `/api/ct/verify-register-otp` | 0.14s | — | 不涉及发信，纯本地校验 |
| `/api/collections/users/records` | 快 | — | 不涉及发信 |

> 🔴 **由此定下客户端超时契约**：`requestRegisterOtp` 的超时**必须 ≥90 秒**。
> 原先设 30s —— 在服务端**最终发信成功**的情况下客户端会先报超时 →
> 用户以为失败、实际收到邮件，重试还会撞上 60s 冷却（体验灾难）。
> 落点：`lib/modules/auth/auth_service.dart:686`（**已改为 90s**）。
>
> 📌 另观察：采样中出现过 1 次 **500**（SMTP 临时失败）。这是**预期行为** ——
> Hook 会回删记录并返回 `mail_send_failed`，客户端提示"验证码发送失败，请稍后重试"。

#### 部署清单（修订版）

- [x] 部署 `require_otp_on_register.pb.js` + 重启 PB（开发者 2026-09-30 00:45 完成）
- [x] 确认 `register_otps` 集合存在
- [x] 后端 12 项用例实测（上表）
- [x] ✅ **重新部署含冷却修复版**（394 行）→ 复测「同邮箱 1 秒内重发 → **429**」通过
- [x] ✅ 客户端超时契约修正（30s → 90s，见上「接口耗时特性」）
- [x] ✅ **超管判定修正（第四坑更正）已随修订版上线并实测通过**（2026-09-30 12:2x 复核）：
      超管直建用户 → **200**（此前被自己的注册拦截挡住）；匿名无令牌注册 → **400**
      `注册需要邮箱验证码…`（拦截仍生效）。两路行为均符合预期。
- [x] ✅ **部署 `lock_fields.pb.js` v3（补超管豁免）** —— 开发者 2026-09-30 21:0x 部署完成。
      探针**三组对照全部生效**（`title` / `has_official` / `origin` 均可写），探针字段已完全还原；
      随后重跑 `has_official` 回填 **298/298 成功**且**读回复核生效**
- [ ] 🔴 **真实邮箱端到端**：获取码 → 收码 → 注册 → 自动登录（开发者真机，**唯一剩余项**）
- [ ] 老用户登录 / 重置密码回归

> ### 🔴 版本一致性警告（2026-09-30 实测发现）
>
> **线上部署的 `require_otp_on_register.pb.js` ≠ 仓库内的副本**，两者**行为不同**：
>
> - 仓库内 `.workbuddy/pb_hooks/require_otp_on_register.pb.js` 仍是**漏括号旧版**
>   （`:327` 写作 `e.requestInfo.hasSuperuserAuth()`）；
> - 但线上实测：超管直建用户 → **401/200 级放行并返回 PB 字段校验错误**
>   （`{"data":{"password":{...}},"message":"Failed to create record."}` = Hook 放行），
>   匿名 → **自定义消息**「注册需要邮箱验证码…」= Hook 拦截
>   ⇒ **线上跑的是修复后的版本**，仓库副本已落后。
> - ⛔ ⇒ **绝不要用 `.workbuddy/pb_hooks_deploy_20260930/` 整目录覆盖线上** ——
>   那会把已验证的超管判定修复**回退成「恒判 false」**（后果见下文第四坑）。
> - ✅ 正确做法：**只替换需要更新的单个 `.pb.js` 文件**；
>   或先从线上取回最新文件、同步进仓库再改。

#### 🧪 部署后验证方法论（可复用 —— 下次改 PB Hook / 后端接口直接照用）

1. **先探「路由是否加载」**：用必然失败的入参（空邮箱）调用。
   返回**自定义中文 400** = Hook 已加载；返回 **404** = 还没部署（别急着查别的）。
2. **用「未注册邮箱」测核心分支** —— 这是本次 P0 缺陷的教训：上一轮只用
   已注册邮箱验证，「未注册」这条**真实主路径整个漏掉了**。
   → **验证矩阵必须覆盖真实主用例，而不是最容易构造的那个。**
3. **用明文密钥做交叉验证**：Hook 里的密钥是可读的，可以自己签发令牌。
   签一个**已过期**的合法令牌 → 若服务端回「已过期」（而非「无效」），
   说明**签名算法两边完全一致** —— 比"看起来对"强得多的证据。
4. **只走「应被拒绝」路径**：所有用例用 `@example.com` 或不存在的 id，
   保证**零数据副作用**。本次全程 `users` 恒为 181，未创建任何测试用户。
5. **同参数连打两次**：「报成功但行为不对」的坑（如冷却静默失效）**不会报错**，
   只有对比两次结果才能发现。**单次调用无法暴露这类缺陷。**
6. **按最坏情况定超时**：同步发信接口常态 2.9s、偶发 51.8s，
   客户端超时必须按**偶发值**设（90s），不能按均值设。
7. 🔴 **判断「规则是否生效」要用两侧对照校准状态码**：PB 的写规则被拒时返回的是
   **400 `Failed to create record.`（`data:{}` 空）**，**不是 403**。
   单看一个 400 **无法判断**是"规则拦住了"还是"规则放行但字段校验失败"。
   ✅ **正确做法**：同一次探测里放一个**已知会被规则放行**的集合做对照 ——
   本次用 `users`（注册必须公开）匿名 create → **直达 Hook 返回自定义消息**（证明放行），
   而 `games` / `game_resources` 匿名 create → **400 通用消息**（证明被拦）。
   两侧一组对照，结论才成立。
   > 📌 本仓曾因缺少这组对照，把"匿名 `POST {}` → 400 非 403"误读成
   > **"规则全空、匿名可写"**，据此把一条并不存在的 P0 写进了风险表。

> 📌 **一句话**：后端验证的重点不是「成功路径能跑通」，而是
> **「失败路径该拒的都拒了」+「重复调用行为是否正确」**。
> 前者靠"应被拒绝"用例，后者靠"同参数连打两次"。

---

**方案（开发者已选"先验码、再注册"）**：客户端两阶段 + 服务端 Hook 兜底。

```
① POST /api/ct/request-register-otp          { email }
     → 邮箱收到 6 位验证码，响应带 otpId
     （⚠️ 不再用内置 /api/collections/users/request-otp —— 见第 12 步 P0）
② POST /api/ct/verify-register-otp           { otpId, code }
     → 校验通过 → 返回一次性注册令牌 regToken
③ POST /api/collections/users/records        { email, password, passwordConfirm, regToken }
     → Hook 校验令牌有效且邮箱匹配，才允许落库
     （令牌走 **请求体** `regToken`；请求头 X-Register-Token 为可选优先通道）
```

**文件**：`docs/DEV/features/pb_hooks/require_otp_on_register.pb.js`（已修订 v2 版）

#### 🔴 pb_hooks 坑清单（截至 2026-09-30，共 7 条 + 1 条更正）

> ⚠️ 本表**已按实测逐条校正**；下方旧"诚实标注"段落保留作历史记录，其结论已被后续实测取代。

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | **handler 隔离** | 每个 handler 在独立上下文，**访问不到顶层变量/常量/函数** → 所有常量与工具函数必须**内联进 handler** |
| 2 | 集合参数用 **id** | `onRecordCreateRequest(h, "users")` 必须用**集合 name**，传 id `_pb_users_auth_` → **钩子永不触发** |
| 3 | 还原字段 | 用 `orig.get(name)`，⛔ 禁 `getString/getNumber/getBool`（类型不符→该集合**全部 PATCH 400，超管也报错**） |
| 4 | **超管判定** | 🔴 **2026-09-30 更正**：✅ `e.hasSuperuserAuth()` 或 ✅ `e.requestInfo().hasSuperuserAuth()`（**别漏括号**）；⛔ `e.requestInfo.hasSuperuserAuth()` → **恒判 false**（详见下文「第四坑【更正】」） |
| 5 | `$security.newJWT` | duration 是 **Go 纳秒**（`Duration extends Number`），传 600 = 600ns → 令牌立即过期 → **改用 `hs256` 自签** |
| 6 | 读请求头 | ✅ `e.requestInfo().headers["x-foo"]`（`_TygojaDict`，键**全小写**、只含首值）；⛔ `e.request.header.get()` **恒读不到** |
| 7 | 解析时间 | ⛔ 禁 `new Date(PB 的 created 文本)`（空格分隔，非 ISO 8601 → Goja 返回 **Invalid Date**，判断**静默失效**）→ 自己存/算 Unix 秒 |

> ### 🆕 字段锁定 Hook 的「自伤」：无差别还原连超管也拦（2026-09-30）
>
> **现象**：超管 PATCH `games/{id} {has_official:true}` → **HTTP 200**，但读回**仍为 `false`**；
> 全程无任何报错 —— 属**静默失效**（与第七坑同类，单次调用无法发现）。
>
> **定性（两侧对照，零副作用）**：同一测试记录 PATCH `title`（**非**锁定字段）→ ✅ 生效；
> PATCH `has_official` / `origin`（在 `lock` 列表内）→ ❌ 被还原。
> ⇒ `lock_fields.pb.js` **v2 的字段还原对超管无差别生效**。
>
> **为什么是 bug**：该 Hook 自己的注释写「只能由**超管**（后台/服务端）变更」，
> 但实现**没有超管豁免** ⇒ 管理后台 UI 同样改不动（后台也走 record update API）。
> **影响面**：整条投稿审核链路（`origin` / `review_status` / `contributors`）
> ＋ 存量数据回填（`has_official`）**全部瘫痪** → **P1**。
>
> **修复（v3）** —— 在 handler 开头加超管豁免（**双通道兜底**，防单一写法抛错被吞）：
>
> ```js
> let isSuperuser = false;
> try { isSuperuser = e.hasSuperuserAuth(); } catch (err) { isSuperuser = false; }
> if (!isSuperuser) {
>   try { isSuperuser = e.requestInfo().hasSuperuserAuth(); } catch (err) { isSuperuser = false; }
> }
> if (isSuperuser) { return e.next(); }
> ```
>
> **教训**：**「锁字段」类 Hook 必须显式给管理员开豁免口子**；
> 否则它会静默吃掉所有服务端写入，而因为**返回 200**，客户端侧几乎不可能发现。

#### ✅ 已核实 API（对照官方 v0.34.2 `types.d.ts`）

- `$app.findCollectionByNameOrId(name)` / `$app.findFirstRecordByFilter(name, filter, params)`（**查无结果会抛错**）
- `new Record(collection, {data})` / `$app.save(record)` / `$app.delete(record)`
- `$app.newMailClient().send(new MailerMessage({...}))`（自建发信通道）
- `$security.hs256(text, secret)`；`$security.randomStringWithAlphabet(len, alphabet)`
- `routerAdd("POST", path, (e) => e.json(...))`
- `e.requestInfo().body` / `e.requestInfo().headers` / `e.requestInfo().remoteIP`
  ⛔ `e.request.header.get()` **不可用**（Go `*http.Request` 的 `Get()` 未暴露给 JSVM）
- `e.hasSuperuserAuth()` / `e.requestInfo().hasSuperuserAuth()`
- `types.d.ts` 参考行号：`newMailClient` :5773 / `Mailer.send` :19798 / `requestInfo()` :9150 /
  `RequestEvent.hasSuperuserAuth` :9141 / `RequestInfo.hasSuperuserAuth` :9171

> 📌 **历史标注（已被取代，仅存档）**：
> 1. 自定义路由已确认可加载；
> 2. create 拦截曾因集合参数用了 id 而未生效，已修正为 `"users"`；
> 3. 修正版已部署并实测通过（拦截 / 令牌校验 / 老用户登录全部符合预期）；
> 4. ⚠️ 现存 **1 处待重新部署**：第四坑更正（超管判定）。

> 作用（Hook）：规则层挡不住"用户更新自己的记录"时顺手改 `review_status` / `status` 自审通过，
> 也挡不住篡改 `owner` / `contributors` / `created` / `report_count`，必须由 Hook 兜底。

### 🔴 建议立即做：修改超管密码

超管账号密码已在聊天记录中明文出现，建议尽快在 PB 后台 `_superusers` 中修改。

### 原始推荐执行顺序（保留供追溯）

```
① games 后台 Export 备份        ← 第 1 步收尾
   ↓
② 建 game_resources（18 字段）   ← 第 2 步
   ↓
③ games 补 7 字段               ← 第 3 步（⚠️ 默认值别填错）
   ↓  核对后台总数仍为 298
④ 填两集合的 5+5 条规则          ← 第 4 步（🔴 含修补匿名写入漏洞）
   ↓
⑤ 加固 users 集合（5 条规则）    ← 🔴 本轮新增，修 P0 越权
   ↓
⑥ 部署 Hook + 重启 PB           ← 第 6 步（唯一需人工）
   ↓
第 7/8/9 步（文案确认 / 造数据 / 定验收）→ 由 AI 驱动，随后进入开发
```
