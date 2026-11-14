# 云端标签自由输入（games.tags）

> 2026-10-06 落地并部署上线。状态：✅ 本地 15/15、✅ 线上 12/12 + 路由验证通过、🟡 真机交互未走查。

## 1. 问题

| 现象 | 根因 |
|---|---|
| 新建一个云端游戏标签，必须先去 PocketBase 后台 `games` → settings → 给 `tags` 字段的 select 选项表加一个值 | `games.tags` 是 PB 的 `select(multiple, maxSelect=14)`，PB 会校验「值必须在集合定义的 `values` 内」，不在就 400 |
| 发布分享功能只能选云端已有的标签，无法自定义 | 双重限制：① 服务端同上白名单校验；② 客户端 `publish_game_dialog.dart` 把 96 个标签**硬编码**为候选（`_tagOptions`），`DarkMultiSelectField` 根本没有输入口 |

线上实况（2026-10-06 实测）：

- `games` 共 **299** 条记录，去重标签 **87** 个；
- 集合定义里 `tags.values` = **93** 个（本地快照 `.workbuddy/pb_backup/games_collection_final.json`）；
- 客户端硬编码 **96** 个 —— 已经与线上不同步。

## 2. 为什么不做「改字段类型」

直觉方案是把 `select` 改成 `json`（PB json 字段可存任意数组）。**实测否决**：

- 用 superuser API `PATCH /api/collections/games` 把 `tags.type` 改成 `json` → **HTTP 200，但类型仍是 `select`**，PB 静默忽略已有字段的类型变更（Admin UI 里类型下拉是灰的，同一原因）；
- 改 `[7]` 写自定义标签仍返回 `validation_invalid_value`，`[10]` 写 20 个仍报 `Select no more than 14` —— 校验走的还是旧 select 语义。

真要改类型就得「删字段 + 新建 + 回填 299 条」，属于高风险迁移，收益不比下面的方案高，故不采用。

探针脚本：`.workbuddy/tmp_probe/probe_tags_json.py`、`probe_tags_write.py`。

## 3. 方案：校验前自动登记新词（hook）

PB 的 `onRecordCreateRequest` / `onRecordUpdateRequest` 触发在**字段校验之前**，
因此可以在 hook 里把本次提交出现的新标签追加进集合的 `values`，`$app.save(collection)`
后校验随即放行。

新 hook：**`tags_autovalues.pb.js`**

```
onRecordCreateRequest(games)  ┐
onRecordUpdateRequest(games)  ┴→ 清洗 tags → 校验 → 新词登记进 values → e.next()
GET /api/ct/game-tags         → 返回当前词表（公开，供客户端取候选）
```

### 3.1 清洗与治理（防灌垃圾）

| 规则 | 值 | 行为 |
|---|---|---|
| 单条最多标签数 | 14 | 沿用 `maxSelect`，超限 400 + 中文提示 |
| 单标签长度 | ≤ 12 字 | 超限 400 + 中文提示 |
| 单次请求最多新增新词 | 5 | 超限 400 |
| 词表总量上限 | 500 | 满则 400 |
| 未登录 | 不允许新增词 | 400（已存在的词仍可选） |
| 空串 / 纯空白 / 重复 | trim 后丢弃、去重 | 静默修正，不报错 |

`e.record.set("tags", cleaned)` 会把清洗结果写回，用户传 `["", " ", "拔作", "拔作"]`
最终落库为 `["拔作"]`。

### 3.2 goja 纪律（本项目血泪）

- **文件顶层零声明**，常量与工具函数全部定义在 handler 函数体内部；
- 🔴 **`e.collection.schema` 是 `undefined`** —— PB 0.23 起字段叫 **`fields`**（`e.collection.fields`）。
  踩这个坑的表现是 `TypeError: Cannot read property 'length' of undefined` → PB 转通用 400；
- 用 `BadRequestError(msg)` 抛错才能把中文原因带回客户端；**不要在 try 内直接抛**，
  否则会被自己的 catch 兜底吞成「标签处理失败」——本 hook 用 `failMsg` 变量暂存、
  在 catch 里统一 `throw new BadRequestError(failMsg)`。

## 4. 客户端改动

| 文件 | 改动 |
|---|---|
| `lib/widgets/game_detail/upload_resource_dialog.dart` | `DarkMultiSelectField` 新增 `allowCustom` / `customHint` / `onCustomAdded`，默认 `false`（其余 3 处调用点行为不变）；展开面板里 chip 区改为「options ∪ selected」并集，保证自定义词可见、可再次点掉 |
| `lib/widgets/game_detail/publish_game_dialog.dart` | 标签候选改为「云端词表 + 内置兜底」；开窗时异步拉 `GamePublishService.fetchCloudTags()`（失败静默回退）；编辑回填与元数据回填**不再按本地白名单过滤**；标签字段开 `allowCustom` |
| `lib/services/game_publish_service.dart` | 新增 `fetchCloudTags()`（`GET /api/ct/game-tags`，8s 超时，失败返回空）；`_translate()` 400/其他分支优先透传**服务端中文**原因（PB 的英文通用消息仍走原映射） |

## 5. 验证

本地实例（`.workbuddy/pb_dev`，PB 0.34.2，同线上版本）探针
`.workbuddy/tmp_probe/probe_tags_final.py` —— **15 PASS / 0 FAIL**：

```
路由 /api/ct/game-tags                  200，n=96
超管 create 带新标签                     200，tags=['自定义词A1709','拔作']，values 96→97
清洗空值+去重 ["", "  ", "拔作", "拔作"] → 200，tags=['拔作']
超长标签                                400「单个标签不超过 12 个字：…太长」
一次新增 6 词                           400「一次最多新增 5 个新标签，本次 6 个（…）」
15 个标签                               400「最多只能选 14 个标签，当前 15 个」
普通用户 create 带新标签                 200，tags=['用户词B1709']
未登录新增词                            400
环境复原（values / 记录 / 探针账号）      全部零残留
```

客户端：`flutter analyze` 三个改动文件 **0 error 0 warning 0 info**（进程内 analyzer，
本机 `flutter analyze` 子进程通道当时报 231，见 MEMORY §1）；
新增 `test/widgets/dark_multi_select_field_test.dart`（3 例）覆盖自由输入。

### 5.1 线上验收（2026-10-06 部署后实测，117.72.115.30:8090）

探针 `.workbuddy/tmp_probe/probe_online_tags.py` —— **12 PASS / 0 FAIL**：

```
读取线上 tags values              n=93 maxSelect=14
路由 /api/ct/game-tags（未登录）   200，n=93（与 values 完全同源）
create 带新标签                    200，tags=['验收新词3532','拔作']
  values 自动 +1（hook 生效）      93→94  ← 核心机制在线上成立
清洗空值+去重 ["", "  ", "拔作"]   200，tags=['拔作']
超长标签                          400「单个标签不超过 12 个字：…太长」
一次新增 6 词                      400「一次最多新增 5 个新标签，本次 6 个（…）」
15 个标签                         400「最多只能选 14 个标签，当前 15 个」
环境复原                          values 94→93，探针记录零残留
```

补充验证 `.workbuddy/tmp_probe/probe_online_tags_route.py`：
create 带新词后 `/api/ct/game-tags` 由 93 → 94 且**含该新词**
（客户端候选列表就是读这个路由，证明"用户自创的标签下次会出现在候选里"），
验证后同样复原到 93。

线上 `games` 集合必填字段仅 `title`，投稿不再需要后台手工加任何标签选项。

## 6. 部署（✅ 2026-10-06 已完成）

1. 把 `.workbuddy/pb_hooks/tags_autovalues.pb.js` 拷到服务器 `pb_hooks/`；
2. 重启 PocketBase（hook 无热加载），日志见 `Server started`；
3. 验收：`curl http://<host>/api/ct/game-tags` 应返回 `{"tags":[…],"count":N}`；
4. 客户端发布一个作品，故意填一个新标签，应提交成功且该词出现在此后的 `/api/ct/game-tags` 里。

以上 3、4 已于 2026-10-06 实测通过（见 §5.1）。

⚠️ 未部署 hook 时客户端**不报错**：`fetchCloudTags()` 返回空 → 回退内置候选；
提交新标签仍会被 PB 的 select 校验拒绝（400），此时 `_translate` 会把服务端英文消息
映射成通用中文提示（不会有乱码或崩溃）。

## 7. 已知取舍

- 新标签**即时进入词表**，不经过审核。若后来出现垃圾词，需管理员在后台 `games` → settings 里手工删（相比以前「每个词都要手工加」，已大幅减少）。
- 词表只增不减（`values` 不会因某条记录删标签而移除）。总量上限 500 兜底。
- 并发写入两个不同新词时存在极小概率的读-改-写竞态，hook 内已做一次 save 重试；最坏情况是用户看到「新标签登记失败，请稍后重试」。
