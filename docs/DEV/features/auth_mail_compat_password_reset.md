# 验证码邮件兼容修复 + 找回密码邮箱验证码 OTP（2026-10-02）

> 状态：**v10 定版包待部署**（本地 37/37 全绿）。包：`.workbuddy/pb_hooks_deploy_20261002_auth_mail_v10.zip`
> （2 文件：`require_otp_on_register.pb.js` 改 + `password_reset_otp.pb.js` 新增，零 schema/零规则变更）。

## 1. 问题与根因

**现象**：注册验证码 QQ 邮箱正常；163 邮箱只收到「通知提醒」，通知与正文均看不到验证码；
推测 Outlook 同样受影响。

**根因**（`require_otp_on_register.pb.js` 原发信实现）：
| # | 缺陷 | 影响 |
|---|---|---|
| 1 | 主题固定英文 `OTP for Chrono Tide`，不含验证码 | 163/126 通知栏、列表摘要取自主题 → 永远看不到码 |
| 2 | 只传 `html`，无 `text` 纯文本 part | 邮件为 text/html 单 part；163 通知解析/降级视图只取 plain part → 空（QQ 客户端优先渲染 HTML 才正常） |
| 3 | HTML 为 `<p>/<b>/<i>` 简单结构 | Outlook 桌面版 Word 引擎兼容性差；无 plain part 在各家垃圾评分里吃亏 |

**修复 = 邮件三件套（零服务商分支，全邮箱通用）**：
1. 主题携带验证码：`【Chrono Tide】注册验证码 XXXXXX（3 分钟内有效）`
2. `text` + `html` 双 part（gomail 实际生成 multipart/mixed → alternative → plain+html，已探针实证）
3. HTML 换单 `<table>` + 全内联样式保守模板 + 中文文案 + 大字号验证码 + 有效期提示

## 2. 找回密码改造（顺带消灭 P0 安全漏洞）

**原状**：客户端 `auth_service.dart` 内置混淆 superuser 账密（`_e()/_p()` 拆分拼接——
实际可还原），找回密码/找回账号均以 superuser 身份走 HTTP 明文 API 直查直改。
**任何人抓包/逆向即可完全接管 PocketBase**（P0）。

**新流程**（服务端 hook `password_reset_otp.pb.js`，与注册 OTP 同构）：
```
① POST /api/ct/request-reset-otp   { email }      → 必须已注册（未注册 404 明确提示）
        复用 register_otps 集合（60s 冷却 + HMAC 摘要 + 180s 有效）→ 发码
② POST /api/ct/verify-reset-otp    { otpId, code } → 防爆破(attempts≤5) + 一次性消费
        → 签发 resetToken（hs256 email|exp|sig，独立密钥，TTL 600s）
③ POST /api/ct/reset-password      { resetToken, newPassword, passwordConfirm }
        → 服务端超管通道 record.setPassword() + 轮换 tokenKey（踢掉该账号所有旧会话）
④ POST /api/ct/lookup-email-by-name { name }      → 找回账号：服务端查询+脱敏（首字符***@域名）
```
客户端：`auth_service.dart` 删除 superuser 全家（凭证/token 缓存/旧三方法），新增
`requestResetOtp / verifyResetOtp / resetPasswordWithToken`（timeout 90s，同注册）；
`user_model.dart` 结果类同构替换；`forgot_password_dialog.dart` 找回密码改三步
（邮箱 → 验证码（60s 倒计时重发）→ 设新密码 → 成功），找回账号 Tab 保留。

## 3. 探针抓到并修复的 2 个线上现存 bug

1. **超管建号被 OTP 拦死**：`e.requestInfo.hasSuperuserAuth()` 少调用括号——在函数对象上
   找方法 → TypeError → 恒 false。线上 Admin UI 手动建号同受影响（2026-09-30 上线即存在）。
   修：`e.requestInfo().hasSuperuserAuth()`。
2. **60s 重发冷却静默失效**：`getString("created")` 返回 PB autodate 的空格分隔格式
   （`2006-01-02 15:04:05.000Z`），goja 的 `new Date` 按 ECMA 规范只认 T 分隔 → 恒 NaN →
   `ageSec=null` → 冷却被跳过。修：改用 `expires_at`（自存 Unix 秒文本）反推创建时刻
   （= exp − TTL），彻底绕开日期解析。两个 hook 同步修。

## 4. 验证

- **本地端到端**：`pb_dev/_smtp_catch.py`（零依赖手写 SMTP 捕获服务，2525）+
  `pb_dev/probe_local_auth_mail.py` **37/37 全绿**——邮件 MIME 断言（主题含码/双 part/
  plain+html 均含码/table+内联样式）、注册码 verify 可用、重置全流程（旧会话被踢、
  新旧密码登录）、错误分支（未注册 404/冷却 429/防爆破/伪 token/篡改签名）、找回账号
  正反例、零残留。
- **客户端**：进程内 analyzer 3 文件 errors=0。
- **线上探针**：`pb_tmp/probe_prod_auth_mail.py`（发信分支容错——真实 QQ SMTP 拒收
  test.local 假域名 → 500 mail_send_failed 亦算路由正常 + 回滚断言）。**待 v10 部署后跑**。
- ⚠️ 线上 hardening 限流 `*:create`=60s/3 次 → 线上探针已内置 429 退避（21s×10）。

## 5. 部署与走查清单（待用户）

1. 部署 v10 包（覆盖 2 文件 → 重启 PB）→ 通知 AI 跑线上探针。
2. 真实邮箱实测：QQ / 163 / 126 / Outlook 各注册一次——**通知栏与邮件正文都应看到验证码**；
   （若 163 仍进垃圾箱属 IP 信誉问题，与内容无关，可引导用户加白名单/标记非垃圾）。
3. 重构建 exe → 走查：注册验证码邮件观感 / 忘记密码三步流（收码→设新密码→旧密码失效→
   新密码登录）/ 找回账号脱敏显示 / 未注册邮箱明确提示。

## 6. 邮件稳定性加固（2026-10-03 傍晚，v12 重打并入）

### 6.1 空白邮件 "Login from a new location"（用户手机截图报障）

- **根因**：PB 内置 users.authAlert 登录位置提醒（默认开启，快照
  `pb_backup/users_collection_final.json:170-176`：enabled=true + 默认英文模板）。
  账号在新 IP/设备登录成功后 PB 自发提醒（10-02 线上邮件探针从京东云 IP 的登录
  测试即会触发，非业务发信）。该邮件**仅 html 单 part**（PB 内置模板机制只有
  body 字段，无法做 text+html 双 part），只取 text/plain 的手机邮件客户端正文
  整片空白——与 §1 的 163 通知栏兼容性同根因，但此路无法用三件套修复。
- **修复**：迁移 `pb_dev/pb_migrations/1790991100_disable_users_auth_alert.js`
  关闭 `authAlert.enabled`（带 down 回滚）。产品决策：桌面管理器场景登录提醒
  价值极低（密码找回已有 OTP 兜底）且技术上无法兼容化 → 直接关闭。

### 6.2 验证码发送不稳定（用户实测 3 试 1 成）

- 链路：hook 同步 `$app.newMailClient().send()` → `smtp.qq.com:465`（京东云跨云）。
  常态 1.7–4.5s、最坏 51.79s（§4/`auth_service.dart` 注释既有实证）；用户看到的
  「卡在发送中」= 服务端死等 SMTP，「网络错误」= 前端 90s 超时文案误导。
- 服务端缺陷：发信失败 catch **无日志**（线上诊断盲区）+ **零重试**。
- 修复（两 hook 同构，`require_otp_on_register.pb.js` / `password_reset_otp.pb.js`）：
  **带预算重试**——失败且耗时 <10s（瞬时抖动）→ 立即重试最多 3 次（同一 message，
  最坏用户收到重复邮件但码相同，无害）；≥10s（通道卡死）→ 快速失败，防请求无限挂长；
  每次失败 `console.log`（attempt/耗时/错误）。
- 🔴 **PB 0.34.2 实测**：JSVM `console.log/error/warn/info` 全部写 **stdout**（带时间戳），
  不进 auxiliary 日志库；全局 `print` 不存在。服务端日志诊断认准 PB 进程 stdout。
- **本地探针** `pb_dev/probe_local_mail_retry.py` **18/18 PASS**：迁移生效（authAlert
  =false）/ 正常路径收信 / 失败重试（stdout 3 条 attempt + 500 mail_send_failed +
  register_otps 零残留）/ 重置同构 / smtp 恢复后再通。
- 🔴 **流程坑**：改 hook 后必须 `cp` 同步到 `pb_dev/pb_hooks/`（本地实例加载的是
  部署副本，源码目录 `.workbuddy/pb_hooks/` 的改动对本地实例不生效）——本轮曾因此
  日志断言假 FAIL，浪费一轮排查。

### 6.3 前端预期管理（随 App 版本发布）

- `lib/modules/auth/auth_service.dart`：+`import 'dart:async'`；
  `requestRegisterOtp` / `requestResetOtp` 各加 `on TimeoutException` 分支——超时 ≠
  网络断，文案不再误导（「邮件发送超时，请稍等片刻后点重新获取再试」），避免用户
  误判后立刻重试撞 60s 冷却（重新获取会签发新码，旧码 3 分钟自然过期，安全）。
- 四处「获取验证码」调用点（`auth_modal.dart:143` / `register_page.dart:115` /
  `forgot_password_dialog.dart:144`、`:220`）发起前 `AppSnackBar.info`：
  「验证邮件发送中，网络较慢时可能需要约 1 分钟，请耐心等待…」。
- analyzer 4 文件 **errors=0**（3 warnings/6 infos 均为存量，行号不在改动区）。

### 6.4 部署与走查（待用户）

- 服务端：并入 **v12 重打包**（2 迁移 + 2 hook，见 `.workbuddy/DEPLOY_HOOK_20261003_
  resource_likes_rules_v12.md`），部署后跑线上回归（resource_likes 19 断言 +
  auth_mail 38 断言）。
- 客户端：flutter test / 真机走查待开发者终端补跑；线上稳定性观察 1–2 周，
  仍差则评估换 HTTP API 邮件通道（腾讯云 SES / 阿里云邮件推送，443 出站）。
