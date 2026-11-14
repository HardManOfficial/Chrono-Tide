/// <reference path="../pb_data/types.d.ts" />
// ============================================================================
// require_otp_on_register.pb.js —— 新用户注册必须过邮箱验证码（OTP）
// ----------------------------------------------------------------------------
// 策略（开发者 2026-09-29 指定）：
//   · 老用户（现有 181 个）不做任何处理：不验证、不要求重新验证，照常登录。
//   · 新用户（正式开放后注册的）必须走邮箱验证码流程。
//
// 🔴 为什么不开启 PB 全局的「必须验证邮箱才能登录」开关（authRule）：
//   PB 的 authRule 是全局的。一旦开启，现有 181 个 verified=false 的老账号
//   会立刻全部无法登录 —— 直接违反「老用户不做处理」。
//   因此改为「只在注册路径做 OTP 校验」：老用户不走注册路径，天然不受影响。
//
// ----------------------------------------------------------------------------
// 🔴🔴 为什么不用 PB 内置的 /api/collections/users/request-otp（2026-09-30 实测）
//
//   实测铁证：该接口**只对「已存在的用户」发码**。
//     · 已注册邮箱  → _otps 表写入记录且 sentTo 有值 → 邮件真发出 ✅
//     · 未注册邮箱  → 返回 200 + 一个「空壳 otpId」，但 **不写 _otps、不发信** ❌
//       服务端日志：`missing or invalid users OTP auth record with email xxx`
//
//   而「新用户注册」时邮箱**必然不存在** → 走内置接口永远收不到码 → 注册死锁。
//   ⇒ 因此本 Hook **自建注册验证码通道**：自己生成码、自己存、自己发信。
//     数据落独立集合 `register_otps`（不复用 system 集合 _otps，
//     因为 _otps.recordRef 是必填且指向已存在的 user，未注册用户没有 record）。
//
// ----------------------------------------------------------------------------
// 🔴 架构要点（本仓踩过坑，务必遵守）：
//
// 1) **Handler 隔离**：PB 的每个 handler 在独立上下文执行，
//    **无法访问 handler 外部声明的变量/函数**（官方文档 js-overview
//    "Handlers scope"）。因此每个 handler 内部都**自带一份常量**，不要提取到顶层。
//
// 2) **集合 tag 用 name 而非 id**：onRecordCreateRequest 的集合参数必须是
//    集合 name（"users"），传 id（"_pb_users_auth_"）会导致钩子永不触发。
//
// 3) 🔴 **超管判定的正确写法**（2026-09-30 实测纠错 —— 本条是对原「第四坑」的**更正**）：
//    ✅ `e.hasSuperuserAuth()`                     ← RequestEvent 上直接就有（types.d.ts:9141）
//    ✅ `e.requestInfo().hasSuperuserAuth()`       ← RequestInfo 上的同名方法，**必须带括号**
//    ⛔ `e.requestInfo.hasSuperuserAuth()`         ← 漏括号！`requestInfo` 是方法不是属性
//         （types.d.ts:9150 `requestInfo(): RequestInfo`），在方法对象上调用会抛错，
//         若外层有 try/catch 兜底 → **静默恒判 false**（超管后台建号被自己挡住）。
//
// 4) **读请求头必须用 e.requestInfo().headers[...]**（_TygojaDict，键全小写、只含首值），
//    ⛔ 不可用 e.request.header.get(...)：e.request 是 Go *http.Request，
//    其 Header 是 map[string][]string，JSVM 不暴露 Go 的 Get() 方法 → 恒读不到。
//
// ----------------------------------------------------------------------------
// 流程（客户端三阶段）：
//   ① POST /api/ct/request-register-otp      { email }
//      → 本 Hook 生成 6 位码 → 存 register_otps（存 HMAC 摘要）→ 真实发信
//      → 返回 { otpId, expiresInSeconds }
//   ② POST /api/ct/verify-register-otp       { otpId, code }
//      → 比对 code_hash，通过则签发短时效「注册令牌」regToken
//   ③ POST /api/collections/users/records
//      { email, password, passwordConfirm, regToken }
//      → 本 Hook 校验令牌与邮箱匹配，才允许落库
//
// API 依据（均已对照 v0.34.2 官方 types.d.ts 核实）：
//   · $app.newMailClient() → mailer.Mailer；Mailer.send(MailerMessage)
//     （官方示例见 types.d.ts:516-528）
//   · new MailerMessage({ from:{address,name}, to:[{address}], subject, html })
//   · $app.findCollectionByNameOrId(name) → Collection
//   · new Record(collection, {data})；$app.save(record)；$app.delete(record)
//   · $app.findFirstRecordByFilter(name, filter, ...params) → Record（查无结果会抛错）
//   · $security.hs256(text, secret) → string（HMAC-SHA256 十六进制签名）
//   · $security.randomStringWithAlphabet(length, alphabet) → string
//   · routerAdd("POST", path, (e) => e.json(...))
//   · e.requestInfo().body / .headers / .remoteIP
//   🔴 刻意**不使用**任何 DateTime 类型转换：过期时间以「Unix 秒数字文本」存储，
//      冷却判断用 expires_at 反推创建时刻（纯整数算术）。
//      ⛔ 绝不用 new Date(PB 的 created 文本) —— 实测在 Goja 里返回 Invalid Date（见 handler 内注释）。
//   · onRecordCreateRequest(handler, "users")
//
// 🔴 为什么不用 $security.newJWT 签发注册令牌：
//   它的 duration 参数类型是 time.Duration（Go 纳秒数，js 里就是 Number）。
//   传 600 会被当成 600 纳秒 → 令牌瞬间过期。为避免这个类型坑，
//   改用 hs256 自签「email|exp|签名」格式的令牌。
// ============================================================================

// ---------- ① 自定义路由：注册专用「请求验证码」（自建发信通道） ----------
routerAdd("POST", "/api/ct/request-register-otp", (e) => {
  const OTP_TTL_SEC = 180; // 验证码有效时长
  const RESEND_COOLDOWN_SEC = 60; // 同邮箱重发冷却
  const HASH_SECRET = "<REDACTED>";
  const OTP_LEN = 6;

  const body = e.requestInfo().body || {};
  const email = String(body.email || "").trim().toLowerCase();

  // ── 邮箱格式基础校验（与客户端保持一致的简化 RFC 规则） ──
  if (!email) {
    return e.json(400, { message: "请输入邮箱地址。" });
  }
  if (email.length > 254) {
    return e.json(400, { message: "邮箱地址过长。" });
  }
  const emailOk = /^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/.test(email);
  if (!emailOk) {
    return e.json(400, { message: "邮箱格式不正确。" });
  }

  // ── 🔴 决策 A（开发者 2026-09-30 确认）：已注册则明确提示 ──
  // 体验优先：用户已注册时直接引导登录，而不是让他白等一条不会来的验证码。
  try {
    const existing = $app.findFirstRecordByFilter(
      "users",
      "email = {:email}",
      { email: email }
    );
    if (existing) {
      return e.json(409, {
        message: "该邮箱已被注册，请直接登录。",
        code: "email_already_exists",
      });
    }
  } catch (err) {
    // findFirstRecordByFilter 查无结果时会抛错 → 视为「未注册」，继续流程
  }

  // ── 清理该邮箱的旧记录（唯一索引，必须删旧再建新） + 冷却判断 ──
  let oldRecord = null;
  try {
    oldRecord = $app.findFirstRecordByFilter(
      "register_otps",
      "email = {:email}",
      { email: email }
    );
  } catch (err) {
    oldRecord = null;
  }

  if (oldRecord) {
    // 冷却：距上次创建不足 RESEND_COOLDOWN_SEC 秒则拒绝重发
    // 🔴 实测踩坑（2026-09-30）：⛔ 不可解析 created —— PB 的 autodate 文本是
    //    "YYYY-MM-DD HH:mm:ss.sssZ"（**空格**分隔），不符合 ISO 8601（标准要求 "T"），
    //    Goja（PB 的 JS 引擎）的 new Date() 对它会得到 Invalid Date → NaN →
    //    冷却判断被静默跳过（实测 1 秒内连发两次均返回 200）。
    //    ✅ 改用本 handler 自己写入的 expires_at（Unix 秒数字文本）反推创建时刻，
    //       纯整数算术，零日期解析、零类型转换风险。
    let ageSec = null;
    try {
      const expSec = parseInt(String(oldRecord.get("expires_at") || ""), 10);
      if (expSec) {
        const createdSec = expSec - OTP_TTL_SEC;   // 创建时刻 = 过期时刻 - TTL
        ageSec = Math.floor(Date.now() / 1000) - createdSec;
      }
    } catch (err) {
      ageSec = null;
    }
    if (ageSec !== null && ageSec >= 0 && ageSec < RESEND_COOLDOWN_SEC) {
      return e.json(429, {
        message: "请求过于频繁，请 " + (RESEND_COOLDOWN_SEC - ageSec) + " 秒后再试。",
        code: "too_many_requests",
        retryAfterSeconds: RESEND_COOLDOWN_SEC - ageSec,
      });
    }
    // 超过冷却 → 删掉旧记录，稍后重建
    try {
      $app.delete(oldRecord);
    } catch (err) {
      // 删除失败不阻断（唯一索引冲突会在 save 时暴露）
    }
  }

  // ── 生成本次验证码（纯数字 6 位，密码学随机） ──
  let code = "";
  try {
    code = $security.randomStringWithAlphabet(OTP_LEN, "0123456789");
  } catch (err) {
    return e.json(500, { message: "验证码生成失败，请稍后重试。" });
  }
  if (!code || code.length !== OTP_LEN) {
    return e.json(500, { message: "验证码生成失败，请稍后重试。" });
  }

  const codeHash = $security.hs256(email + "|" + code, HASH_SECRET);
  const nowSec = Math.floor(Date.now() / 1000);
  const expSec = nowSec + OTP_TTL_SEC;

  // ── 落库 ──
  // 🔴 过期时间存「Unix 秒的数字文本」（expires_at 是 text 字段），
  //    刻意避开 DateTime 类型转换 —— 本仓曾因类型专用 getter 踩坑
  //    （见 MEMORY.md：禁 getString/getNumber/getBool 写回）。
  //    纯文本比较 + parseInt 最稳，且不依赖任何 PB 类型行为。
  let record;
  try {
    const collection = $app.findCollectionByNameOrId("register_otps");
    record = new Record(collection, {
      email: email,
      code_hash: codeHash,
      expires_at: String(expSec),
      attempts: 0,
    });
    try {
      record.set("request_ip", e.requestInfo().remoteIP || "");
    } catch (err) {
      // remoteIP 不可用时不阻断
    }
    $app.save(record);
  } catch (err) {
    return e.json(500, { message: "验证码保存失败，请稍后重试。" });
  }

  // ── 🔴 真实发信（官方示例 types.d.ts:516-528） ──
  // 发信失败必须明确报错，⛔ 不能静默放过（否则又变成「无报错但没发信」）
  try {
    const settings = $app.settings();
    const message = new MailerMessage({
      from: {
        address: settings.meta.senderAddress,
        name: settings.meta.senderName,
      },
      to: [{ address: email }],
      subject: "OTP for Chrono Tide",
      html: "<p>Hello,</p>" +
        "<p>Your one-time password is: <b>" + code + "</b></p>" +
        "<p><i>If you didn't ask for the one-time password, you can ignore this email.</i></p>" +
        "<p>Thanks,<br>Chrono Tide team</p>",
    });
    $app.newMailClient().send(message);
  } catch (err) {
    // 发信失败 → 删掉刚写的记录，避免用户拿到一个永远收不到的 otpId
    try {
      $app.delete(record);
    } catch (e2) {}
    return e.json(500, {
      message: "验证码邮件发送失败，请稍后重试或联系管理员。",
      code: "mail_send_failed",
    });
  }

  return e.json(200, {
    otpId: record.id,
    expiresInSeconds: OTP_TTL_SEC,
  });
});

// ---------- ② 自定义路由：校验验证码 → 签发注册令牌 ----------
routerAdd("POST", "/api/ct/verify-register-otp", (e) => {
  const REGISTER_TOKEN_SECRET = "<REDACTED>";
  const REGISTER_TOKEN_TTL_SEC = 600;
  const HASH_SECRET = "<REDACTED>";
  const OTP_MAX_ATTEMPTS = 5;

  const body = e.requestInfo().body || {};
  const otpId = String(body.otpId || "").trim();
  const code = String(body.code || "").trim();

  if (!otpId || !code) {
    return e.json(400, { message: "缺少参数：otpId / code 均为必填。" });
  }

  // ── 取记录（数据源 = register_otps） ──
  let rec;
  try {
    rec = $app.findRecordById("register_otps", otpId);
  } catch (err) {
    return e.json(400, { message: "验证码不正确或已过期，请重新获取。" });
  }
  if (!rec) {
    return e.json(400, { message: "验证码不正确或已过期，请重新获取。" });
  }

  // ── 过期判断（expires_at 存的是 Unix 秒的数字文本） ──
  try {
    const expSec = parseInt(String(rec.get("expires_at") || ""), 10);
    const nowSec = Math.floor(Date.now() / 1000);
    if (!expSec || expSec < nowSec) {
      try { $app.delete(rec); } catch (e2) {}
      return e.json(400, { message: "验证码已过期，请重新获取。" });
    }
  } catch (err) {
    // 时间读取失败不拦截（宁可放过过期，也不误杀正常用户）
  }

  // ── 尝试次数防爆破 ──
  let attempts = 0;
  try {
    attempts = parseInt(rec.get("attempts"), 10) || 0;
  } catch (err) {
    attempts = 0;
  }
  if (attempts >= OTP_MAX_ATTEMPTS) {
    try { $app.delete(rec); } catch (e2) {}
    return e.json(400, { message: "验证码错误次数过多，请重新获取。" });
  }

  const email = String(rec.get("email") || "").toLowerCase();
  if (!email) {
    return e.json(400, { message: "验证码记录异常，请重新获取。" });
  }

  // ── 比对摘要 ──
  const expectHash = $security.hs256(email + "|" + code, HASH_SECRET);
  const storedHash = String(rec.get("code_hash") || "");
  if (expectHash !== storedHash) {
    // 错误 → attempts + 1
    try {
      rec.set("attempts", attempts + 1);
      $app.save(rec);
    } catch (err) {}
    return e.json(400, { message: "验证码不正确或已过期，请重新获取。" });
  }

  // ── 校验通过 → 消费掉这条记录（一次性） ──
  try {
    $app.delete(rec);
  } catch (err) {}

  // ── 内联签发令牌 ──
  const nowSec = Math.floor(Date.now() / 1000);
  const expSec = nowSec + REGISTER_TOKEN_TTL_SEC;
  const base = email + "|" + expSec;
  const sig = $security.hs256(base, REGISTER_TOKEN_SECRET);
  const token = base + "|" + sig;

  return e.json(200, {
    regToken: token,
    email: email,
    expiresInSeconds: REGISTER_TOKEN_TTL_SEC,
  });
});

// ---------- ③ 拦截注册：校验注册令牌 ----------
onRecordCreateRequest((e) => {
  // handler 内自带常量（顶层变量在此上下文不可见）
  const REGISTER_TOKEN_SECRET = "<REDACTED>";
  const OTP_REQUIRED = true;

  // 🟡 超管后台手动建号：直接放行
  // 🔴 第四坑更正（2026-09-30 实测）：必须用 **`e.requestInfo().hasSuperuserAuth()`**（带括号）
  //    或 **`e.hasSuperuserAuth()`**（RequestEvent 上直接就有，types.d.ts:9141）。
  //    ⛔ 写成 `e.requestInfo.hasSuperuserAuth()`（漏括号）→ `requestInfo` 在 JSVM 里是
  //    **方法**（types.d.ts:9150 `requestInfo(): RequestInfo`），在方法对象上调用会抛
  //    "not a function" → 被下方 catch 吞掉 → **恒判非超管** →
  //    连超管在后台都建不了用户（管理员新建账号被自己的注册拦截挡住）。
  //    症状极具迷惑性：**不报错、只是永远走非超管分支**。
  let isSuperuser = false;
  try {
    isSuperuser = e.hasSuperuserAuth(); // 首选：RequestEvent 上的直调
  } catch (err) {
    isSuperuser = false;
  }
  if (!isSuperuser) {
    try {
      isSuperuser = e.requestInfo().hasSuperuserAuth(); // 兜底：RequestInfo 上的同名方法
    } catch (err) {
      isSuperuser = false;
    }
  }
  if (isSuperuser) {
    return e.next();
  }

  if (!OTP_REQUIRED) {
    return e.next();
  }

  // 取注册令牌（优先请求头，其次请求体字段 regToken）
  // ⚠️ 读请求头必须用 e.requestInfo().headers（_TygojaDict，键为全小写，只含首值）
  //    ⛔ 不可用 e.request.header.get(...)：e.request 是 Go *http.Request，
  //       其 Header 是 map[string][]string，JSVM 不暴露 Go 的 Get() 方法 → 恒读不到
  let token = "";
  try {
    const hdrs = e.requestInfo().headers || {};
    token = hdrs["x-register-token"] || "";
  } catch (err) {
    token = "";
  }
  if (!token) {
    try {
      const body = e.requestInfo().body || {};
      token = body.regToken || "";
    } catch (err) {
      token = "";
    }
  }

  if (!token) {
    throw new BadRequestError(
      "注册需要邮箱验证码：请先获取验证码并完成校验后再提交注册。"
    );
  }

  // 内联校验令牌：格式 <email>|<exp>|<sig>
  const parts = String(token).split("|");
  if (parts.length !== 3) {
    throw new BadRequestError("注册令牌无效，请重新获取验证码。");
  }
  const tokenEmail = (parts[0] || "").toLowerCase();
  const expSec = parseInt(parts[1], 10);
  const sig = parts[2];
  const expectSig = $security.hs256(parts[0] + "|" + parts[1], REGISTER_TOKEN_SECRET);

  if (sig !== expectSig) {
    throw new BadRequestError("注册令牌无效，请重新获取验证码。");
  }
  const nowSec = Math.floor(Date.now() / 1000);
  if (!expSec || expSec < nowSec) {
    throw new BadRequestError("注册令牌已过期，请重新获取验证码。");
  }

  // 令牌里的邮箱必须与本次注册邮箱一致
  const regEmail = (e.record.email() || "").toLowerCase();
  if (!tokenEmail || tokenEmail !== regEmail) {
    throw new BadRequestError("注册令牌与邮箱不匹配，请重新获取验证码。");
  }

  return e.next();
}, "users");
