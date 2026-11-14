/// <reference path="../pb_data/types.d.ts" />

// ChronoTide — 字段锁定 Hook
// 目的：防止用户通过 Update 自审通过 / 篡改归属 / 伪造上传时间 / 刷举报数
// 部署位置：PB 可执行文件同级的 pb_hooks/ 目录
// 生效方式：保存后重启 PocketBase
//
// ⚠️ 实现要点（v2，2026-09-29 修复）：
// 不要对字段调用"特定类型"的 getter（如 getString / getNumber / getBool）——
// relation / select / json / number 等不同类型字段用错 getter 会在 Hook 内部抛异常，
// 表现为整个 PATCH 返回 400 "Something went wrong while processing your request."
// （超管也同样报错，因此极易被误判为"权限问题"）。
// 统一用 orig.get(name) 取原始值，e.record.set(name, v) 写回，类型无关，安全。
//
// ⚠️ 实现要点（v3，2026-09-30 修复）：**补超管豁免**。
// 本 Hook 的目的是「防普通用户自审通过 / 篡改归属」，不是防管理员；
// 但 v2 实现是无条件还原，导致超管（后台 UI / 服务端 API）同样改不动
// origin / review_status / has_official → 投稿审核链路整体瘫痪、
// 存量数据回填也无法执行。
//
// 超管判定写法：e.hasSuperuserAuth()（RecordRequestEvent 继承 RequestEvent，types.d.ts:9141）
// 双通道兜底，避免单一写法在 JSVM 中抛异常被 try/catch 吞掉后恒判 false。
//
// ⚠️ 实现要点（v4，2026-10-01）：**补计数锁**。
// game_resources 新增 download_count / like_count 两个系统累加字段，
// 与 report_count 同类——必须一并锁定，否则用户可自行 PATCH 刷下载数 / 点赞数。
//
// ⚠️ 实现要点（v5/v5.1，2026-10-01）：**status 白名单转换（rejected→pending）**。
// 客户端编辑「已驳回」投稿后重提，管理员要能在待审队列看到。
// 所有比较值 String() 收窄（防 goja 值包装 === 失败），fail-closed。
//
// ⚠️ 实现要点（v6，2026-10-02）：**统一审核机制白名单（方案 unified_review_mechanism_plan）**。
// 需求：published 资源「编辑即重新上传」+ 删除须审核 + 发布/编辑/删除统一审核。
// 两个集合的状态字段从「全锁/单白名单」升级为「owner 本人白名单矩阵」：
//
//   game_resources.status：
//     rejected→pending           （v5 已有，重提）
//     published→editing          （发起编辑：下架暂存，数据/统计保留）
//     editing→pending            （修改后重新提交审核）
//     pending_delete→published   （作者撤回删除申请：恢复审核过的原内容）
//
//   games.review_status（games 用 approved 表达"已进库"）：
//     rejected→pending           （🔴 修现存 bug：rejected 作品编辑后重提信号此前丢失）
//     approved→editing           （发起编辑）
//     editing→pending            （修改后重新提交审核）
//     pending_delete→approved    （作者撤回删除申请）
//
// 关键安全语义：
//   - editing→published / editing→approved **不开白名单**（editing 下字段可能已改，
//     直通会造成未审先上架）；
//   - pending_delete→published/approved 恢复的是**审核过的原内容**（该状态下
//     updateRule 已禁改字段），语义安全；
//   - 全部转换要求请求者 == 记录 owner，任一判定异常 ⇒ 保守锁死（fail-closed）；
//   - 删除保护由集合 deleteRule 承担（published/pending_delete 禁 owner 删），
//     本 Hook 不涉及 DELETE。
//
// ⚠️ 注意 `e.auth` 与 `e.requestInfo()` 在 JSVM 中的差异（本项目踩过的坑）：
//   - `e.requestInfo` 是**方法**，必须写成 `e.requestInfo()`；写成属性会抛错。
//   - 只读请求头必须走 `e.requestInfo().headers["x-ct-uid"]`（键全小写、只含首值）。
// 故请求者 id 同样走**三通道兜底**，两者都拿不到就保守锁死。
//
// ⚠️ 实现要点（v7，2026-10-02）：**games.like_count 计数锁**。
// games 新增 like_count（作品级点赞计数，主线补完 Phase 2 / §14.2），
// 与 game_resources 的三个计数同性质——只允许 game_stats.pb.js 的 hook 路由
// 经超管通道累加，客户端直改在此锁回，防止刷数。

onRecordUpdateRequest((e) => {
  // ---- 超管豁免：管理员后台 / 服务端 API 必须能改锁定字段 ----
  let isSuperuser = false;
  try {
    isSuperuser = e.hasSuperuserAuth();
  } catch (err) {
    isSuperuser = false;
  }
  if (!isSuperuser) {
    try {
      isSuperuser = e.requestInfo().hasSuperuserAuth();
    } catch (err) {
      isSuperuser = false;
    }
  }
  if (isSuperuser) {
    return e.next();
  }

  const c = e.collection.name;
  const orig = e.record.original();

  // 锁定 helper：把字段强制还原为更新前的值
  const lock = (name) => {
    e.record.set(name, orig.get(name));
  };

  // 取当前请求者 id（三通道，失败返回空串；全部 String() 收窄）
  const requesterId = () => {
    try {
      if (e.auth && e.auth.id) return String(e.auth.id);
    } catch (err) {
      // 落到下一通道
    }
    try {
      const info = e.requestInfo();
      if (info && info.auth && info.auth.id) return String(info.auth.id);
    } catch (err) {
      // 拿不到
    }
    try {
      const h = e.requestInfo().headers["x-ct-uid"];
      if (h) return String(h);
    } catch (err) {
      // 拿不到
    }
    return "";
  };

  // ---- v6：状态字段 owner 白名单矩阵（两个集合同构处理） ----
  // key = "<原状态>><新状态>"；命中且请求者==owner 才放行，否则锁回。
  const stateCfg = {
    game_resources: { field: "status", allows: [
      "rejected>pending",
      "published>editing",
      "published>pending_delete",
      "editing>pending",
      "pending_delete>published",
    ] },
    games: { field: "review_status", allows: [
      "rejected>pending",
      "approved>editing",
      "approved>pending_delete",
      "editing>pending",
      "pending_delete>approved",
    ] },
  };

  const cfg = stateCfg[c];
  if (cfg) {
    let allow = false;
    let diag = "";
    try {
      const uid = requesterId();
      const owner = String(orig.get("owner") || "");
      const st0 = String(orig.get(cfg.field) || "");
      const st1 = String(e.record.get(cfg.field) || "");
      const key = st0 + ">" + st1;
      allow = uid !== "" &&
        owner === uid &&
        cfg.allows.indexOf(key) !== -1;
      diag = "uid=" + uid + " owner=" + owner + " " + cfg.field + ": " +
        st0 + "->" + st1 + " allow=" + allow;
    } catch (err) {
      allow = false; // 任何异常一律保守锁死
      diag = "whitelist judge error: " + err;
    }
    console.log("[lock_fields v6] " + c + " update " + diag);
    if (!allow) {
      lock(cfg.field);
    }
  }

  if (c === "games") {
    // 投稿来源：只能由超管（后台/服务端）变更，防止自改来源
    lock("origin");
    // has_official：官方标记只能由超管维护
    lock("has_official");
    // 分享者归属快照：防止投稿者抹掉他人贡献记录
    lock("contributors");
    // v7：作品级点赞计数——只允许 game-stats hook 路由累加，防止刷数
    lock("like_count");
    // （v6 起 review_status 不再无条件锁死，改走上方白名单矩阵）
  }

  if (c === "game_resources") {
    // 获取方式：防止用户把 community 改成 official
    lock("kind");

    // （v6 起 status 改走上方白名单矩阵）

    // 举报计数：只允许系统累加
    lock("report_count");
    // 下载次数 / 点赞数（v4 新增字段）：只允许系统累加，防止用户刷数
    lock("download_count");
    lock("like_count");
    // 归属：防止把别人的资源转嫁到自己名下，或反之
    lock("owner");
    // 上传时间：确保"分享于 YYYY-MM-DD"不可伪造
    lock("created");
  }

  e.next();
}, "games", "game_resources");
