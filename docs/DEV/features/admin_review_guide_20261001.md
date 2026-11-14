# 管理员审核操作指南 — 分享投稿的过审 / 驳回 / 编辑重提 / 删除裁决（2026-10-01，v9 更新 10-02）

> 适用：探索扩展方案 Phase 2/3 + 统一审核机制（v9）上线后的日常运营。审核动作 = 改一条
> 记录的状态字段，目前**没有客户端审核界面**，两条路：① 浏览器开 PocketBase 后台自己点
> （推荐，本文主讲）；② 把投稿标题告诉我，我用超管接口代办。

---

## 一、先搞清两个"审核"（别混淆）

| 你审的东西 | 存哪 | 状态字段 | 用户端入口 |
|---|---|---|---|
| **分享投稿**（资源：网盘/汉化/补丁…） | `game_resources` | `status`: pending / published / rejected / **editing / pending_delete** | 详情页【分享】发布 →【我的】投稿 |
| **用户自建游戏条目**（整部作品） | `games` | `review_status`: pending / approved / rejected / **editing / pending_delete** | 用户发布新作品时产生 |

日常最高频的是**第一种**。下文以第一种为例，第二种操作完全同理（`published` ↔ `approved` 互换）。

## 二、状态机（服务端已锁死，你只管改状态；v9 全景）

```
pending（待审核，用户提交后）
  ├─ 你过审 → published（已发布：分享列表可见，可下载/点赞/举报）
  └─ 你驳回 → rejected（已驳回：仅投稿人自己可见）
         └─ 投稿人自己重提 → pending   ← 自助通道（v6 白名单）

published ──作者发起编辑──► editing（下架暂存：字段可改、数据/统计保留）
                              └─作者提交──► pending ──你过审/驳回──► published / rejected

published ──作者申请删除──► pending_delete（下架，数据/统计保留）
                              ├─ 你通过 = 直接 Delete 记录（⚠️ 作品会级联删名下资源）
                              ├─ 你拒绝 = 状态改回 published
                              └─ 作者自己撤回 → published（随时可撤，数据零丢失）
```

- 白名单（`lock_fields` v6）只放行**作者本人的**：rejected→pending、published→editing、
  editing→pending、published→pending_delete、pending_delete→published（games 用 approved 互换）。
  `editing→published` **故意不放行**——编辑内容必须过审才能上架，不用担心未审先上。
- `download_count` / `like_count` / `report_count` 同样被锁；editing / pending_delete 期间
  **数据与统计全部保留**，拒绝删除/撤回后继续累计。

## 三、操作步骤（浏览器，约 30 秒一条）

1. 打开 **http://117.72.115.30:8090/_/**（PocketBase 管理后台）。
2. 登录超管：`<REDACTED>` / `Bb1314520`（与你部署 PB 用的同一套，勿外传）。
3. 左侧 **Collections → `game_resources`**。
4. 顶部筛选：**Filter** 输入 `status='pending'`（首发审核）、`status='editing'`（编辑重提审核）、
   `status='pending_delete'`（删除裁决）。
5. 点开目标记录 → **`status` 下拉框**：
   - 首发/编辑重提：过审 → `published`；驳回 → `rejected`
   - 删除裁决：**同意删除 → 右上角齿轮/删除按钮直接 Delete 记录**；拒绝 → 状态改回 `published`
6. 右上 **Save**。生效即时。

**查看举报**：同页左侧切到 `resource_reports` 集合（当前为空）；每条含被举报资源、举报人、时间。
**查看转正归属**：`games` 记录的 `contributors` 字段（JSON 数组）——你在某作品下**新建 kind=official
的来源**时才触发自动写入（过审投稿不触发）。

## ⭐ v9 新增：两类新队列怎么裁（2026-10-02）

| 队列 | 过滤条件 | 含义 | 你的动作 |
|---|---|---|---|
| 编辑重提 | `status='pending'`（与首发混在一起） | 作者改过的已进库内容重新送审 | 与首发同样过审/驳回；⚠️ 重提通过后**原内容不再保留**（作者已被客户端提示） |
| 删除裁决 | `status='pending_delete'` | 已进库内容请求删除 | 同意 → 直接 Delete；拒绝 → 改回 `published`/`approved` |

> 区分首发与编辑重提：pending 记录若此前有过 published 历史（`updated` 时间晚于 `created`
> 且 `download_count`/`like_count` > 0）大概率是编辑重提——不确定就问我，我查服务端日志。

## 四、当前审核台快照（2026-10-01 22:46）

| 状态 | 条数 | 明细 |
|---|---|---|
| pending | 5 | **《游戏本体》id=8ufvanfezybnxja（你自己刚发，22:46）** + 9/29 测试账号旧投稿 4 条 |
| published | 0 | — |
| rejected | 0 | — |
| 举报 | 0 | — |

> 那 4 条 9/29【测试】投稿（ct_test_sharer_a/b@example.invalid）是 Phase 2 验收留下的测试数据，
> 可过审当展示样例、也可删掉，你定。

## 五、建议的走查配合（接着走查清单 ③④⑤）

1. 你现在自己在后台把 **《游戏本体》8ufvanfezybnxja 改成 `rejected`**（练手驳回）。
2. 回 app【我的】→ 该投稿显示「已驳回」→ 编辑重提 → 变「待审核」（走查 ③ ✅）。
3. 回后台把它改成 `published`（练手过审）。
4. 回 app 测下载/点赞计数（走查 ④）和「报告失效」举报（走查 ⑤）。

## 六、已知缺口（不阻塞，列为可选增强）

- **驳回无理由**：投稿人只看到「已驳回」，不知道原因。可加 `review_note` 字段 +
  客户端【我的】展示一行驳回理由（约半天工作量，要做说一声，照两段式流程走）。
- 审核无客户端界面：目前浏览器后台够用；投稿量大后再考虑做「审核队列」页。
