# 记住登录 + 会话续期（remember_login.md）

> 创建：2026-10-03　提交：`0119b18`　状态：✅ 已实施，⚠️ 待真机走查

## 1. 背景与需求

用户反馈：一段时间不使用软件后总被要求重新登录（重新输邮箱+密码）。两点需求：

1. **本地持久化以月为周期**——不轻易掉线；
2. **记住登录**——即使失去登录态，也能快速/无感地重新登录。

## 2. 根因（「掉线」的真相）

`auth_service.dart` 的 `verifyTokenInBackground()`：

- 启动时后台 `authRefresh()` 签发**新 token**（有效期重新计起），但此前新 token
  **只存在于内存 authStore，未回写 SharedPreferences**；
- 下次启动 `_restoreFromLocal()` 恢复的是**首次登录时**的旧 token；
- 一旦距离上次持久化超过服务端 authDuration（PB 默认 14 天），本地 JWT exp
  校验（`_isLocalTokenValid()`）即拦截 → 强制要求重新登录。

即：**旧实现下用户每次打开软件时服务端会话其实一直在续，但续期结果没有落地。**

## 3. 修复与实现

### 3.1 会话续期落地（治本）

`verifyTokenInBackground()` 中 `authRefresh()` 成功后，把新 token 回写 prefs
（`_keyToken`）。此后每次打开软件都续期并落盘——**只要两个 authDuration 周期
内打开过一次软件就永不断线**。

### 3.2 RememberMeStore（记住凭证，`lib/modules/auth/remember_me_store.dart`）

| 项 | 设计 |
|---|---|
| 存储 | `data/prefs/remember_me.bin`（DPAPI 密文二进制，随便携化目录体系） |
| 加密 | **Windows DPAPI**（advapi32 `CryptProtectData`），密文绑定当前 Windows 用户——data/ 拷到别的机器/账户无法解密 |
| 应用熵 | `ChronoTide.Auth.v1`：其他进程即使用同用户 DPAPI 也解不开（Chrome 同款思路） |
| 降级 | 非 Windows / FFI 失败 / 解密失败 → 静默返回 null/false，**永不抛异常打断登录流程** |
| 明文密码 | 永不写日志（日志中邮箱脱敏 `a***@qq.com`） |

### 3.3 流程接线（`auth_service.dart`）

- `login(email, password, {remember = true})`：成功后勾选 → `RememberMeStore.save`；未勾选 → `clear()`（不留残留）。注册自动登录同走此路径（默认记住）；
- `logout()`：**清除凭证**——主动退出 = 明确不想保持登录，与 token 过期场景区分；
- `checkAutoLogin()`：token 过期分支 → `_trySilentRelogin()`：
  - 离线 → 跳过（保持本地游客态，下次联网启动再试）；
  - 成功 → **无感恢复在线态**（用户全程无感知）；
  - 凭证失效（密码已改/账号已删：invalidCredentials/userNotFound）→ 清除凭证，走普通登录；
  - 网络等临时错误 → **保留凭证**，下次再试。

### 3.4 登录 UI（`login_page.dart` + `auth_modal.dart`，两处同构）

- 密码框下一行：**「记住登录」勾选框**（`RememberMeCheckbox`，硬边像素风，默认勾选）与「忘记密码？」同行；
- 表单顶部：**「快速登录」条**（⚡ + 记住的邮箱 + →，整条可点）——一键免输入登录，仅本地有凭证时显示；
- 快速登录失败且凭证确定失效 → 清除凭证并隐藏快捷条。

## 4. 「月为周期」的完整满足链

```
每次打开软件 → authRefresh 续期 + 新 token 落盘（3.1）
   ↓ 只要两个周期内开过一次 → 永不断线
超期未开（token 过期）→ 记住的凭证静默重登（3.2/3.3）→ 依旧无感
凭证也失效（改过密码）→ 清凭证，走普通登录（或登录页快速登录条一键）
```

## 5. 真机走查清单（待开发者）

1. 登录勾选「记住登录」→ 登出 → 登录页应出现「快速登录」条 → 一键登录成功；
2. 取消勾选登录 → 登出 → 登录页**无**快捷条；
3. 登录后登出 → 凭证应被清除（主动登出不出快捷条，与 1 对照）；
4. 静默重登模拟：手动把 `data/prefs` 里 token 改成过期值（或等超期）→ 启动应无感恢复在线态；
5. 改密码后（另一端）→ 静默重登应失败并清凭证 → 正常显示登录页；
6. `remember_me.bin` 拷贝到另一台机器应解密失败（回退普通登录，不崩溃）。

## 6. 边界与说明

- 服务器侧 `authDuration`（PB 默认 14 天）未改动——客户端双通道（续期落盘 + 静默重登）已覆盖；若想进一步拉长可后续在 PB Admin → settings 调整；
- 凭证文件随 data/ 迁移到新机器会解密失败（设计如此），回退普通登录；
- DPAPI 实现零新增依赖（dart:ffi + advapi32，项目已有 FFI 先例）。
