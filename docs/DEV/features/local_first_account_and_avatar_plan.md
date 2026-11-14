# 本地优先账号体系 + 系统头像池 —— 实施方案

> **状态**：📋 方案待执行（Phase 0 未跑，代码零改动）  
> **发起**：2026-10-23  
> **前置文档**：`docs/DEV/features/local_account_mode.md`（✅ 已实施 2026-10-02，本方案**推翻**其 §2.1 状态机中「两者皆无 → 登录窗口」一行）  
> **触碰稳定区**：`lib/main.dart`、`lib/main_container.dart` —— 需用户显式批准（见 §8.2）  
> **执行者注意**：本文件是唯一需求源。开工前先读 `AGENTS.md` §2.2 两段式流程。

---

## 0. 结论摘要（TL;DR）

| 维度        | 结论                                                                                                                                                             |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **本质**    | 不是重造账号系统。`LocalAccountService` 这套本地身份**早已写完并接线**（含 9 个单测），缺的只有一环：**首启动没人创建它**。本次是「补上创建 + 重建头像体系 + 修服务端可见性」                                                     |
| **首启动**   | 改 `main.dart:977` 一处判定，并在 `!_exists` 时自动 `createDefault()`。改造后 `_buildBody()` 的 `_isLoggedIn \|\| _isLocalMode` **恒为真**，`LoginPage` / `RegisterPage` 可路由永久不再挂载 |
| **默认身份**  | 名 `萌萌团`、简介空、头像从 34 张内置池随机抽一张并**落盘固化**（只抽一次，非每次启动重抽）                                                                                                            |
| **头像池**   | 34 张 webp（396–500px 方形，共 ≈1.1MB）→ 复制到 `assets/images/avatars/` 并规范命名 `av_01..av_34`；**`素材/` 原件不动**                                                             |
| **重抽**    | 头像右下角 26px 循环箭头按钮（`Icons.refresh_rounded`），点一下换一张、**即时生效即时落盘**、**自动排除当前这张**（否则用户以为按钮没反应）                                                                       |
| **全局一致**  | 现状 **7 套独立圆形头像实现 + 0 个全局通知机制 + 本地换头像后 0 处刷新**。必须新建 `CurrentUserStore`(ChangeNotifier) + `CtUserAvatar`(订阅 store) 两个收敛点                                         |
| **登录后上传** | 云端 `avatar` 为空才把本地头像推上去；非空则保留云端。**不允许无条件覆盖**                                                                                                                   |
| **服务端**   | `users.viewRule` 从 `id = @request.auth.id` → `@request.auth.id != ""`。⚠️ **`createRule` 必须保持空串**（注册依赖匿名创建，动了注册全挂）                                              |
| **工作量**   | 客户端 ~14 文件；服务端 1 条规则 + 1 次只读快照；Phase 0 五项探针                                                                                                                    |

### 一句话形态

> 新用户双击 exe → 直接看到库页（右下角已经是「萌萌团」+ 一张随机头像）→ 什么都不用做就能用。  
> 想换头像：点右下角头像 → 用户卡片里一个循环按钮，点一次换一张，满意即止，全软件同步变。  
> 想用云端功能：点【登录】，登录后云端没头像就自动把你选的那张传上去。

---

## 1. 背景与目标

### 1.1 背景（用户原话归纳）

1. 新用户下载即开 → 被一屏登录/注册挡脸，「还不知道这软件是干嘛的就要登录」；
2. 而登录与「本地管理器」这个本质**不相干**，却成了体验主要功能的门槛；
3. 本地身份已有，但信息是「用户手填」的，没有预设、没有头像体系；
4. 头像需要：系统提供一批可选、初始随机、可重抽、**一旦选定就稳定**、**全局跟随**；
5. 登录后要能把这张头像同步成线上账号的头像；别人看到我的头像也要跟着变。

### 1.2 目标（本期必达）

| #  | 目标                                  | 可验证的判据                                                               |
| -- | ----------------------------------- | -------------------------------------------------------------------- |
| G1 | 新装首次打开**不出现任何登录/注册界面**，直接进主界面       | 删 `prefs` 后启动，首帧后 200ms 内可见库页；`LoginPage` 不挂载                        |
| G2 | 首启动自动创建本地账户：名 `萌萌团`、bio 空、头像=池中随机一张 | `prefs.local_account_name == '萌萌团'`、`local_account_avatar_preset` 非空 |
| G3 | 头像在重启后**仍是同一张**（稳定，不重抽）             | 连续启动 3 次，`preset` 不变                                                 |
| G4 | 用户可一键重抽；按钮轻量（循环箭头样式）                | 按钮存在、点击后头像变化且 `preset` 变化、且**不等于**上一张                                |
| G5 | 换头像后**全软件 4 个显示点同时更新**，无需重启         | 换头像后不重启，悬浮按钮/BPM 顶栏/用户卡片/设置页四处一致                                     |
| G6 | 未登录用户点云端功能时，提示语说明「本地管理不受影响」并给出登录入口  | 6 处拦截点文案统一，存在可达的登录入口                                                 |
| G7 | 登录后，云端无头像则自动上传本地头像；云端有则保留           | 两个方向各构造一次用例                                                          |
| G8 | 他人视角头像实时跟随（已登录用户浏览分享列表时）            | A 改头像 → B 刷新分享列表 → 看到 A 的新头像（而非发布时快照）                                |

### 1.3 非目标（本期明确不做，别顺手扩）

- ❌ 多本地档案 / 账户切换 / 本地账户删除入口（`LocalAccountService.clear()` 仍不挂 UI）
- ❌ 本地账户 → 云端账号的「绑定/合并/迁移」（登录仍是切到另一个身份，本地资料保留不删）
- ❌ 云端数据同步（游戏库、收藏夹、游玩时长一律不上云，现状即如此，别动）
- ❌ 头像裁剪 / 旋转 / 滤镜
- ❌ 删除 `LoginPage`、`RegisterPage`、`LocalAccountSetupDialog` 三个文件（见 §13-Q3）
- ❌ 改造 `SystemNoticeService` / `AppSnackBar`（全局提示组件，改它波及全部提示，见 §9-P1）
- ❌ 给 `users.avatar` 加 `thumbs` 生成缩略图（优化项，见 §13-Q4）
- ❌ 未登录也能浏览他人资料（`listRule` 保持锁定，不做用户枚举）

---

## 2. 现状调研（全部实测，带 路径:行号）

### 2.1 启动链路：登录窗口只有一个触发点

没有 `AuthGate` / `SplashPage` / 路由守卫。启动是 `main.dart` 单 StatefulWidget 里的三元分支：

| 环节        | 位置                                        | 行为                                                                                       |
| --------- | ----------------------------------------- | ---------------------------------------------------------------------------------------- |
| 服务初始化     | `lib/main.dart:552-558`                   | `UserCacheService.init()` → `LocalAccountService.init()` → `NetworkStatusService.init()` |
| 判定入口      | `lib/main.dart:706` → `_checkAuthState()` | `initState` 内触发                                                                          |
| **决定性一行** | `lib/main.dart:977`                       | `_isLocalMode = !isValid && hasLocalAccount`                                             |
| 加载分支      | `lib/main.dart:1116-1137`                 | 转圈 +「正在加载...」（**这是首帧画面**，不是品牌闪屏）                                                         |
| 主界面分支     | `lib/main.dart:1138`                      | `if (_isLoggedIn \|\| _isLocalMode)` → `MainContainer`                                   |
| 登录页分支     | `lib/main.dart:1148-1155`                 | `case AuthPage.login:` → `LoginPage`                                                     |
| 注册页分支     | `lib/main.dart:1156-1160`                 | `case AuthPage.register:` → `RegisterPage`                                               |

> 🔴 **新装用户 `isValid=false`、`exists=false` → `_isLocalMode=false` → 必落登录页。全库没有任何「首启动自动创建本地账户」的代码。**

### 2.2 已存在但未被消费的能力（本次要接的就是它）

| 资产                                       | 位置                                                                                                                                                                                           | 现状                                                            |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `LocalAccountService`（全 CRUD + 独立 key）   | `lib/modules/auth/local_account_service.dart:22-151`                                                                                                                                         | ✅ 完整可用                                                        |
| prefs key 五项                             | `local_account_service.dart:25-29`                                                                                                                                                           | `local_account_id / _name / _bio / _avatar_b64 / _created_at` |
| `exists` 判据（同步可读）                        | `local_account_service.dart:51-52`                                                                                                                                                           | `local_account_id` 非空                                         |
| `create({name, bio, avatarBytes})`       | `local_account_service.dart:56-74`                                                                                                                                                           | ⚠️ **全库唯一调用方是手动填写对话框** `local_account_setup_dialog.dart:114`  |
| `load()` → `UserModel`                   | `local_account_service.dart:80-105`                                                                                                                                                          | `avatarUrl=''`（本地态无 URL）                                      |
| `updateAvatar(bytes)` / `removeAvatar()` | `local_account_service.dart:116-125`                                                                                                                                                         | `removeAvatar` 无 UI 调用方                                       |
| `clear()`                                | `local_account_service.dart:128-136`                                                                                                                                                         | 注释自承「本期不挂任何 UI」                                               |
| `UserModel.isLocalAccount`               | `lib/modules/auth/user_model.dart:78`                                                                                                                                                        | `!isLoggedIn && id.startsWith('local_')`                      |
| 6 处「本地也能用」的业务分支                          | `main_container.dart:433-442` / `1087-1105` / `401-424`、`user_profile_modal.dart:94-101` / `406-420`、`settings_modal.dart:331-334` / `379-391` / `5114-5127`、`game_detail_page.dart:465-467` | ✅ 已接线                                                         |
| 单测 9 用例                                  | `test/modules/auth/local_account_service_test.dart:21-115`                                                                                                                                   | 含「🔴 隔离性」红测 `:89`（logout 不得清 `local_account_*`）               |
| 设计文档                                     | `docs/DEV/features/local_account_mode.md`                                                                                                                                                    | ✅ 已实施，§2.1 状态机需被本方案推翻                                         |

### 2.3 头像渲染：7 套实现，0 个全局机制

**当前登录用户的 4 个显示点**（本次必须全部收敛）：

| # | 位置             | 文件:行号                                                             | 读取字段                                    | 走什么                                                           |
| - | -------------- | ----------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------- |
| 1 | 右下角悬浮按钮 56/44  | `lib/widgets/floating_user_button.dart:97-134`（调用 `:128-133`）     | `user?.avatarBytes` / `user?.avatarUrl` | `UserCacheService.buildUserAvatar`                            |
| 2 | BPM 大屏顶栏 44/37 | `lib/big_picture/widgets/bpm_top_bar.dart:252-283`（调用 `:271-280`） | 同上                                      | 同上，但默认占位是 `Icons.person_rounded`（`:273-277`，**与桌面版 SVG 不一致**） |
| 3 | 用户资料浮窗 80/71   | `lib/widgets/user_profile_modal.dart:156-194`（调用 `:185-190`）      | 同上                                      | 同上                                                            |
| 4 | 设置→资料 96/83    | `lib/widgets/settings_modal.dart:1187-1232`（调用 `:1213-1229`）      | **只传 `_avatarUrl`**（`:338`），不传 bytes    | 半统一：临时预览分支绕开封装                                                |

**头像选择/预览 2 处（裸写）**：`register_page.dart:323-409`、`local_account_setup_dialog.dart:205-270`

**他人头像 3 处（另一套组件 `AvatarCircle`）**：`share_list_dialog.dart:183-196`、`share_detail_dialog.dart:153-165`、`ct_download_dialog.dart:338-352`（调用方恒传 null：`game_detail_page.dart:1064-1068`）

**明确没有头像的区域**（别误加）：侧栏（`sidebar.dart:342` 仅注释）、自绘标题栏、探索大厅（`HallLetterAvatar` 是网站首字母徽章，`hall_visuals.dart:175-219`）。项目**没有**评论/动态/打分模块。

**重复实现计数**：圆形裁剪+渲染 **7 份**；默认头像构造 **3 份函数 + 2 份内联**；头像 URL 拼接 **4 处**（`auth_service.dart:88-90`、`:1257-1258`、`user_model.dart:47`、`game_resource_model.dart:363`）。

**默认头像**：`assets/images/user_avatar_icon.svg`（718B 线稿图标，`colorFilter: srcIn` 染色），5 处引用。**没有内置插画头像池**。

### 2.4 更新通知：4 个漏刷新点

现有唯一刷新链路：

```
settings_modal._handleAvatarUpload(cloud) (:5129-5146)
  → prefs['user_avatar_base64'] (:5134)
  → AuthService.uploadAvatar (:1161)
  → widget.onAvatarChanged?.call() (:5169)
  → MainContainer._loadCurrentUser() (:1159)
  → AuthService.getCurrentUser() → 下载 bytes (:991-1015)
  → setState(_currentUser) (:444-448)
  → 悬浮按钮/BPM 顶栏重建（构造参数变化）
```

| #  | 漏点                  | 位置                                                                     | 根因                                                                                                                  |
| -- | ------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| L1 | **本地换头像 → 0 处刷新**   | `settings_modal.dart:5116-5127`                                        | 写完 `LocalAccountService.updateAvatar` 直接 `return`，没调 `onAvatarChanged`                                              |
| L2 | 设置页重开后本地头像消失/串台     | `settings_modal.dart:338`、`:1224-1228`                                 | 只传 `avatarUrl`；本地 `avatarUrl=''` → 落到 `_CachedAvatarWidget` 读**云端** key `user_avatar_base64`                        |
| L3 | 用户卡片是 Overlay 一次性快照 | `main_container.dart:941-953`、注释 `:1067-1071`                          | `setState` 不重建 `OverlayEntry`；现在靠「改头像前先关窗」的流程巧合规避                                                                   |
| L4 | 他人视角永不刷新            | `game_resource_model.dart:359-364` + `resource_owner_name.pb.js:28-42` | `owner_avatar` 是**发布瞬间的文件名快照**；换头像后 PB 文件名变，旧 URL 直接 404，`AvatarCircle` 落回硬编码 `'汐'`（`kanban_identity.dart:116-127`） |

**没有任何** `ValueNotifier<UserModel>` / `ChangeNotifier` / `Stream` / Provider。全软件唯一用户态容器是 `MainContainer._currentUser` 私有字段，靠构造参数分发。

### 2.5 服务端事实（本次最关键的三个纠正）

只读查询 `.workbuddy/pb_dev/pb_data_dev/data.db` 的 `_collections`（PB 0.34.2）：

```
users.listRule   = 'id = @request.auth.id'
users.viewRule   = 'id = @request.auth.id'
users.updateRule = 'id = @request.auth.id'
users.createRule = ''            ← 空串 = 任何人可创建（注册必需，见下）
avatar 字段: type=file, maxSelect=1, maxSize=0, protected=false, thumbs=null
```

> ⚠️ **列顺序坑**：`_collections` 的 SQL 列顺序是 `listRule, viewRule, updateRule, createRule`。写探针时别搞反。  
> `createRule=''` 是**有意的** —— `require_otp_on_register.pb.js:68/:102/:462` 用 `onRecordCreateRequest` 校验 `regToken` 来兜住匿名创建。**改规则时绝不能碰 `createRule`，否则注册直接全挂。**

三条纠正：

1. 🔴 **PB 的普通文件默认公开可访问**（仅 `protected=true` 的字段才受 viewRule 约束 —— PB 官方文档 Files handling §Protected files 原文：*"By default all files are publicly accessible if you know their full url."*）。本项目 `avatar.protected=false` ⇒ `/api/files/users/{id}/{filename}` **任何人凭完整 URL 即可取**，不需要 Bearer。  
   ⇒ 所以「他人头像」缺的**不是**文件读取权限，而是**当前文件名**。
2. `users.viewRule = id = @request.auth.id` ⇒ 客户端读不到**他人**记录的 `avatar` 字段 ⇒ 只能靠 `owner_avatar` 快照 ⇒ 这正是 `resource_owner_name.pb.js:4-6` 注释里「实测普通用户视角 `expand=owner` 被 users 规则拦成空」的根因。
3. `emailVisibility` 是 PB 内置字段：**非本人查看时，`emailVisibility=false` 的记录的 `email` 会被 API 自动剔除**（官方 issue #376 维护者原话：*"when expanding a user relation, you'll have access to ... `email`: visible only if emailVisibility is true"*）。这是放开 `viewRule` 后不泄露邮箱的**唯一依据**，必须逐条核实。

### 2.6 资源与素材

- `pubspec.yaml:51-53` 是**目录级**声明：`assets/images/`、`assets/images/themes/`。**Flutter 目录声明不递归** ⇒ 新增 `assets/images/avatars/` 必须加一行。
- `assets/` 下 **0 个 webp**（全 png/svg/ico）⇒ 内置 webp 头像**首次引入**，需 Phase 0 验证。
- 运行时代码已支持 webp：`company_wall_store.dart:83`、`company_logo_service.dart:339-350`、`bpm_backdrop_media.dart:91`、`game_data_format.dart:1326`。
- 素材实测：`D:\CTLIB\素材\用户头像\头像\` 共 **34 张** `.webp`，VP8 有损，**方形** 396×396 ~ 500×500，单张 10–95KB，合计 ≈1.1MB。  
  文件名形如 `005 (4).webp`、`067.webp`（含空格与括号，**必须规范化后再入 assets**）。

---

## 3. 技术选型

### 3.1 首启动"绕过登录"的三种做法

| 方案                                               | 做法                                                             | 结论                                                                                                                                            |
| ------------------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| A. 改 `_buildBody()` 无条件进 `MainContainer`         | `main.dart:1138` 改成 `return MainContainer(...)`                | ❌ 淘汰。`MainContainer._currentUser` 会是空，所有本地分支判 `_user?.isLocalAccount ?? false` 得 false，落回云端语义；且 `LocalAccountService.exists` 仍 false，设置页/卡片全错 |
| **B. 在 `_checkAuthState()` 里补创建，再让判定自然成立**（✅ 采用） | `!_exists` 时 `await createDefault()`，`_isLocalMode = !isValid` | 一处补全，所有既有本地分支（6 处）**零改动**自动生效；`exists` 语义仍是唯一真理源                                                                                              |
| C. 新增 `OnboardingService` / 首启动标志位               | 新增 prefs flag + 新服务                                            | ❌ 淘汰。`LocalAccountService.exists` 已经就是"是否已完成初始化"的天然标志，再引入一个 flag 会出现两个真理源、且可能与 `clear()` 不同步                                                  |

### 3.2 头像"存什么"

| 方案                                       | 存储形态                                    | 结论                                                                                 |
| ---------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------- |
| A. 存 base64 字节（沿用 `updateAvatar`）        | prefs 里 ~20–90KB/张，base64 再 +33%        | ❌ 淘汰。① pref 体积膨胀；② 无法区分"内置头像"与"用户上传"，导致登录后无法判断该不该上传；③ 头像池换图后无法跟随                   |
| **B. 存 preset id（短 id，如 `av_07`）**（✅ 采用） | `local_account_avatar_preset` = `av_07` | ① prefs 只多 5 字节；② 来源可判别；③ 头像池更新可跟随；④ **首启动 createDefault 零 IO**（不读 asset 字节），不阻塞首帧 |
| C. 落成磁盘文件 + 存路径                          | `data/avatars/xxx.webp`                 | ❌ 淘汰。多一层文件生命周期管理，且已确认删除类改动要走 ADR-007 护栏，平白引入风险                                     |


> **优先级定案**：`avatarBytes`（用户上传）> `avatarPreset`（内置池）> 默认 SVG 图标。  
> 用户上传时**同时清空 preset**（`settings_modal` 上传分支），避免歧义。

### 3.3 全局头像同步机制

| 方案                                                                                                 | 做法     | 结论                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A. 继续靠 `MainContainer.setState` + 构造参数下发                                                           | 现状     | ❌ 淘汰。`OverlayEntry` 快照不重建（L3），且 4 个显示点分散在不同子树，必须层层传参                                                                                                         |
| **B. `CurrentUserStore extends ChangeNotifier` 单例 + `CtUserAvatar` 内部 `AnimatedBuilder` 订阅**（✅ 采用） | 见 §4.2 | ① 一处写、处处刷；② Overlay 快照问题自动消失（订阅在 Widget 内部）；③ 零新依赖（`ChangeNotifier` 是 Flutter 内置）；④ 与项目既有 `BigPictureManager` / `NetworkStatusService` 的 ChangeNotifier 惯例一致 |
| C. 引入 Provider / Riverpod                                                                          | 新依赖    | ❌ 淘汰。`pubspec.yaml` 依赖版本不得动（AGENTS.md §2.3）；且为一个用户态引入全局 DI 框架属过度设计                                                                                           |

### 3.4 他人头像实时化

| 方案                                                   | 做法                       | 成本                         | 结论                                                                         |
| ---------------------------------------------------- | ------------------------ | -------------------------- | -------------------------------------------------------------------------- |
| **A. 放开 `users.viewRule`，客户端用 `expand=owner`**（✅ 采用） | 规则改 1 条 + 分享列表加 `expand` | 最小：0 新集合 / 0 新 hook / 0 回填 | 文件本已公开，只缺文件名；`emailVisibility=false` 挡邮箱；`listRule` 保持锁定 ⇒ 无法枚举            |
| B. 新建 `ct_public_profiles` 集合（name+avatar）由 hook 同步  | 新集合 + hook + 历史回填 + 客户端改 | 大                          | ❌ 本期淘汰。**唯一优势是让「未登录用户」也看到实时头像**，以及完全不暴露 `description`。若后续有该需求再升级（见 §13-Q2） |
| C. 自定义路由 `/api/ct/avatar/{id}` 流式返回                  | 新路由                      | 中                          | ❌ 淘汰。列表 N 条 → N 次请求；且没解决 `expand` 元数据问题                                    |
| D. 客户端轮询用户记录                                         | —                        | —                          | ❌ 淘汰。N+1 请求 + 无谓流量                                                         |

> **A 的代价必须写明**：放开后，任何**已登录**用户只要知道对方 id，就能读到对方的 `name` / `description`(bio) / `created`。`email` 受 `emailVisibility` 保护。这是本次唯一的有意隐私让步，需在 §10 登记。

### 3.5 头像池枚举方式

| 方案                                                                | 做法                                     | 结论                                                                       |
| ----------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------ |
| A. 硬编码 34 个路径常量                                                   | Dart 列表                                | ❌ 淘汰。加图必须改代码，且改错/漏改无编译期保护                                                |
| **B. `AssetManifest.loadFromAssetBundle(rootBundle)` 动态列举**（✅ 采用） | 运行时列出 `assets/images/avatars/` 全部资源并排序 | 加图零改代码。⚠️ **Phase 0 必须验证**在 Windows release 与 flutter_tester 下都能列全（P-01） |
| C. 手写 `index.json`                                                | 额外清单文件                                 | ❌ 淘汰。与 assets 实际内容可能不一致，属"两个真理源"                                         |

---

## 4. 架构设计

### 4.1 身份状态机（改造后）

```
                    ┌──────────────────────────────┐
   启动              │ checkAutoLogin()             │
   ────────────────► │  · pb.authStore.isValid      │
                    │  · 本地 JWT exp              │
                    │  · DPAPI 静默重登            │
                    └───────────┬──────────────────┘
                                │
              ┌─────────────────┴──────────────────┐
        isValid=true                        isValid=false
              │                                    │
              │                          ┌─────────┴──────────┐
              │                     exists=true          exists=false
              │                          │                    │
              │                          │        ★ createDefault()
              │                          │          name=萌萌团
              │                          │          bio=''
              │                          │          preset=随机(34)
              │                          │                    │
              └──────────────┬───────────┴────────────────────┘
                             ▼
                   ┌──────────────────────┐
                   │ MainContainer        │  ← 恒达（登录页永不再挂载）
                   │ CurrentUserStore     │
                   │  · 先给本地身份      │
                   │  · 云端身份异步覆盖  │
                   └──────────────────────┘
```

### 4.2 三层结构

```
┌─ 数据层 ───────────────────────────────────────────────────────┐
│ LocalAccountService            (已存在，+1 key: avatar_preset) │
│ AuthService                    (不动)                          │
│ AvatarPresetService (新增)                                      │
│   · all()          → List<String>  (来自 AssetManifest)        │
│   · pathOf(id)     → 'assets/images/avatars/$id.webp'          │
│   · randomExcept(current) → String   ★ 必须排除当前             │
└────────────────────────────────────────────────────────────────┘
                              ▲
┌─ 状态层 ─────────────────────┴─────────────────────────────────┐
│ CurrentUserStore extends ChangeNotifier  (新增，单例)           │
│   UserModel? get user                                          │
│   bool get isLocal                                             │
│   Future<void> reload()        ← 唯一身份解析入口               │
│   Future<void> hydrateFromLocal()   ← 冷启动阶段1，零网络       │
│   Future<void> refreshFromCloud()   ← 冷启动阶段2，异步覆盖     │
│   void apply(UserModel)        ← 乐观更新 + notifyListeners     │
└────────────────────────────────────────────────────────────────┘
                              ▲ (AnimatedBuilder 订阅)
┌─ 渲染层 ─────────────────────┴─────────────────────────────────┐
│ CtUserAvatar (新增，统一 Widget)                                │
│   优先级: avatarBytes > avatarUrl(带 Bearer 下载) > preset > 默认│
│   统一: ClipOval + cacheWidth(避免 400px 图在 44px 位置原尺寸解码)│
│   替换: 悬浮按钮 / BPM 顶栏 / 用户卡片 / 设置页 / 选择器预览    │
│ AvatarCircle (他人头像，保留) — 仅补「优先用 expand.owner.avatar」│
└────────────────────────────────────────────────────────────────┘
```

### 4.3 冷启动时序（不阻塞首帧）

| 时刻       | 动作                                                                                        | 硬约束                      |
| -------- | ----------------------------------------------------------------------------------------- | ------------------------ |
| t=0      | `_checkAuthState()` 起跑（现状就是异步，已有转圈分支 `main.dart:1116-1137`）                               | —                        |
| t≈0~20ms | `checkAutoLogin()`（prefs 读 + JWT exp 校验；网络部分本来就是 fire-and-forget `auth_service.dart:894`） | 不得新增网络 await             |
| t≈20ms   | `if (!exists) createDefault()` → **仅 5 次 prefs 写 + 1 次 `Random`**，**不读 asset 字节**         | **禁止** `rootBundle.load` |
| t≈30ms   | `_isLocalMode = !isValid` → 首帧渲染库页                                                        | —                        |
| t=首帧后    | `CurrentUserStore.hydrateFromLocal()` 立即 notify（头像可能有 1 帧延迟从默认图标变 preset，可接受）             | —                        |
| t=首帧后    | `refreshFromCloud()`（若已登录）异步覆盖                                                            | 失败静默，保留本地身份              |

### 4.4 降级策略（每层都必须有）

| 场景                              | 降级                                                  |
| ------------------------------- | --------------------------------------------------- |
| `AssetManifest` 列不出头像池（P-01 失败） | 退回硬编码 34 项常量表（`AvatarPresetService` 内部兜底，外部 API 不变） |
| `preset` 指向的 asset 不存在（头像池改过）   | 视为空 → 重抽一张并落盘                                       |
| `avatarUrl` 下载失败                | 落 `preset` → 落默认 SVG 图标                             |
| 云端 `getCurrentUser()` 失败        | 保留本地身份，不弹错（现状 `auth_service.dart:1090-1094` 已有离线兜底） |
| 登录后上传头像失败                       | 静默 + 一次 `AppSnackBar`，不阻断登录；不建重试队列（本期非目标）           |
| `expand=owner` 为空（游客 / 规则未部署）   | 回退 `owner_avatar` 快照（现有行为，即"旧头像"，不报错）               |

---

## 5. 数据模型变更

### 5.1 `UserModel`（`lib/modules/auth/user_model.dart`）

新增字段（**可空带默认，纯新增**）：

```dart
final String avatarPreset;   // 内置头像池 id，如 'av_07'；非内置则为 ''
```

| 位置                             | 改法                                                       |
| ------------------------------ | -------------------------------------------------------- |
| `:6-27` 构造函数                   | 加 `this.avatarPreset = ''`（非 required）                   |
| `:29-40` `fromPBRecord`        | 不传（云端头像走 `avatarUrl`）                                    |
| `:58-70` `empty()`             | `avatarPreset: ''`                                       |
| `:72-78` getters               | 加 `bool get hasAvatarPreset => avatarPreset.isNotEmpty;` |
| `:100-122` `copyWith`          | 加 `String? avatarPreset` 参数与转发                           |
| `:81-98` `downloadAvatarBytes` | **不动**                                                   |

> ⚠️ `copyWith` 现有实现用 `x ?? this.x`，**无法把 avatarBytes 置回 null**。本次不修（属既有技术债），但在需要清空头像的路径上必须走 `LocalAccountService.removeAvatar()` 而不是 `copyWith(avatarBytes: null)`。

### 5.2 `LocalAccountService`（`lib/modules/auth/local_account_service.dart`）

| 改动                              | 位置          | 内容                                                                                                                       |
| ------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------ |
| 新增 prefs key                    | `:25-29` 后  | `static const String _keyAvatarPreset = 'local_account_avatar_preset';`                                                  |
| `create()`                      | `:56-74`    | 加可选参 `String avatarPreset = ''`；`avatarBytes` 与 `avatarPreset` **二选一**（都传则以 bytes 为准并忽略 preset）                          |
| 新增 `createDefault()`            | 新方法         | `create(name: '萌萌团', bio: '', avatarPreset: AvatarPresetService.randomExcept(null))`；**仅 `!exists` 时允许调用**（内部断言，防误覆盖老用户） |
| `load()`                        | `:80-105`   | 读 `_keyAvatarPreset` 填入 `UserModel.avatarPreset`                                                                         |
| 新增 `setAvatarPreset(String id)` | 新方法         | 写 preset **并 `remove(_keyAvatarB64)`**（切换回内置头像要清掉旧上传字节）                                                                  |
| `updateAvatar(bytes)`           | `:116-119`  | 加一句 `await _prefs.remove(_keyAvatarPreset);`（上传自定义图 → 清 preset）                                                          |
| `removeAvatar()`                | `:122-125`  | 同时清 preset                                                                                                               |
| `clear()`                       | `:128-136`  | 补 `_prefs.remove(_keyAvatarPreset)`                                                                                      |
| 🔴 隔离性铁律                        | `:17-19` 注释 | **不变**：`local_account_*` 与 `pb_*` / `user_*` 完全隔离；`AuthService.logout()` 仍不得碰本地                                          |

### 5.3 迁移与版本

| 项                                             | 结论                                                                          |
| --------------------------------------------- | --------------------------------------------------------------------------- |
| 是否触发 `game_data_format` 迁移                    | **否**。用户资料不落在 `game.json`，不涉及 `format_version`（当前常量值需执行时 `grep` 实测确认，文档不写死） |
| 是否影响 `_overwritableFields`                    | **否**。该表只覆盖游戏记录字段；用户状态类字段**绝不**加进去（`game_data_format.dart:199-234`）         |
| 老用户（已有本地账户）                                   | `avatarPreset` 读不到 → `''` → 保留其现有头像（bytes 或默认图标）。**不覆盖**                    |
| 老用户但头像完全为空（`avatarBytes==null && preset==''`） | 补抽一张 preset（仅在 `refreshFromLocal` 里做一次，判定严格）                                |
| 老用户已登录                                        | 完全不受影响，走云端 `avatarUrl`                                                      |

> **不升 `format_version` 的理由**：本次全部是「本地账户 prefs 的新增 key」+「`UserModel` 新增可空字段」，不写任何 `game.json`。ADR-012 管的是游戏数据 schema，此处不适用。**执行时须在代码注释里写明该理由**，免得后人以为漏做。

### 5.4 服务端变更（PocketBase）

| 对象                   | 现值                      | 目标值                      | 说明                                        |
| -------------------- | ----------------------- | ------------------------ | ----------------------------------------- |
| `users.viewRule`     | `id = @request.auth.id` | `@request.auth.id != ""` | 允许已登录用户按 id 读他人公开字段                       |
| `users.listRule`     | `id = @request.auth.id` | **不变**                   | 保持不可枚举                                    |
| `users.createRule`   | `''`                    | **绝对不变**                 | 注册依赖匿名创建（`require_otp_on_register.pb.js`） |
| `users.updateRule`   | `id = @request.auth.id` | **不变**                   | —                                         |
| `users.avatar` 字段    | `protected=false`       | **不变**                   | 已公开可访问，无需改                                |
| 全量 `emailVisibility` | 未知                      | 全部为 `false`              | 若存在 `true` 的记录，**先报告不擅自改**（见 §13-Q1）      |

**部署纪律**（沿用 `features/pb_setup_stepbook.md`）：

1. 本地实例 `.workbuddy/pb_dev/`（8091）先改先验；
2. `cp` 同步到 `pb_dev/pb_hooks/`（⚠️ 改 hook 必须同步，否则本地/线上不一致）；
3. 线上 `http://117.72.115.30:8090` 用**超管 PATCH**，只改 `viewRule` 一个字段，**禁止整集合覆盖**；
4. 改前 `read_values()` 快照 → 改后比对 → 不一致立刻回滚（一条 PATCH 即回滚）；
5. 凭据**不硬编码**，从 `.workbuddy/pb_tmp/probe_prod_game_likes.py` 提取；
6. 探针账号用完即删。

---

## 6. 性能预算

| 项                    | 预算                                            | 约束                                                                       |
| -------------------- | --------------------------------------------- | ------------------------------------------------------------------------ |
| 首包体积增量               | **+1.1MB**（34 张 webp 原图）                      | 若打包脚本对体积敏感，可改 256px 重压（≈400KB，见 §13-Q4）。**不得**引入 PNG（会膨胀 5–10 倍）         |
| `createDefault()` 耗时 | **< 15ms**（5 次 prefs 写 + 1 次 `Random`）        | 🔴 硬要求：**禁止** `rootBundle.load` / 图片解码                                   |
| `AssetManifest` 列举   | 首次 < 20ms，结果进程内缓存                             | 只在 `AvatarPresetService.ensureLoaded()` 里做一次                             |
| 头像解码内存               | 44px 位置 **不得**按 396px 原图解码                    | 统一 `cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round()` |
| 重抽响应                 | 点击 → 头像可见变化 **< 1 帧**（preset 是 asset 路径，无 IO） | 必须先 `apply()` 乐观更新再落盘                                                    |
| 全局刷新                 | `notifyListeners()` 后 **≤ 1 帧**完成 4 处重绘       | 订阅点各自 `AnimatedBuilder`，不得依赖父级 `setState`                                |
| `expand=owner` 开销    | 分享列表多 1 次关联查询                                 | 断网 → 立刻回退快照，不得超时卡住列表                                                     |

---

## 7. 实施阶段划分

### Phase 0 —— 技术验证（**先证伪再落地**，产出 `test/probe/` 或 `.workbuddy/probe_avatar/` 探针）

> 🔴 五项任一失败都必须先回来报告，**不得**带着未验证假设往下写业务代码。

| ID       | 假设                                                                                                                              | 验证方式                                                      | 失败后果                                                      |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------- |
| **P-01** | `AssetManifest.loadFromAssetBundle(rootBundle)` 在 **Windows release** 与 `flutter_tester` 下都能列出 `assets/images/avatars/` 全部 34 项 | 真机跑一次 + `flutter test` 各打一份清单                             | 退硬编码常量表（§4.4）                                             |
| **P-02** | 打包后 **webp asset** 能被 `Image.asset` 正常解码（本项目 assets 首次引入 webp）                                                                  | 渲染一张 396px webp 到 `RepaintBoundary`，`toImage()` 取像素数校验    | 转 PNG 重导（体积代价 ~5×），或改用 `Image.memory` + `rootBundle.load` |
| **P-03** | webp bytes 上传到 PB `users.avatar` → 下载 → `Image.memory` 解码往返成功（PB `thumbs=null` 不参与）                                             | 本地 PB 实例 + 测试账号，上传→`getOne`→下载→解码，比对像素尺寸                  | 上传前用 `ui.Image.toByteData(format: png)` 转 PNG             |
| **P-04** | 把 `users.viewRule` 改成 `@request.auth.id != ""` 后，`game_resources` 列表 `expand=owner` 能带出 `name` + `avatar` 文件名                   | 本地 PB 实例，两个账号 A/B，A 发布资源，B 列表查询                           | 升级到方案 B（独立公开资料集合，§3.4）                                    |
| **P-05** | 生产库全量 `emailVisibility` 均为 `false`                                                                                              | **只读**导出 `select emailVisibility, count(*) group by 1`，不写 | 存在 `true` → 报告用户决策（§13-Q1）                                |


**Phase 0 产出**：一份探针报告（结论 + 数据），写入本文件 §11 的验证记录区。

### Phase 1 —— 头像池与素材落地（纯新增，零既有代码风险）

1. 复制 34 张 → `assets/images/avatars/av_01.webp … av_34.webp`（**`素材/` 原件不动**，用复制不用移动）
2. `pubspec.yaml` 加 `- assets/images/avatars/`
3. 新增 `lib/services/avatar_preset_service.dart`
4. 新增 `lib/widgets/user_avatar_view.dart`（`CtUserAvatar`）
5. 新增 `test/services/avatar_preset_service_test.dart`（随机排除当前、id 稳定性、缺图回退）

> 本阶段不接线任何既有 UI ⇒ 可独立验证、可独立提交。

### Phase 2 —— 全局状态收敛（风险最高，独立提交，便于回滚）

1. 新增 `lib/services/current_user_store.dart`
2. `MainContainer` 改为写 `CurrentUserStore`（🔴 **稳定区**）
3. 4 个显示点全部换成 `CtUserAvatar`
4. 修 L1（本地换头像不刷新）、L2（设置页串台）、L3（Overlay 快照）

> 验收：**换头像后不重启，4 处全部同步**。这是本阶段唯一的核心判据。

### Phase 3 —— 首启动本地优先

1. `main.dart._checkAuthState()` 补 `createDefault()`（🔴 **稳定区**）
2. 修 `main.dart:995-997` `_onLoginSuccess` 未清 `_isLocalMode` 的状态残留
3. 加右下角头像按钮的**一次性引导气泡**（"点这里换头像"）
4. 加头像重抽按钮（右下角 26px 循环箭头）

> ⚠️ 冲突提醒：`floating_user_button.dart` 头像**右下角已占用**为网络状态圆点（`_buildStatusBadge`，`:136+`）。重抽按钮必须放**左下角**或卡片内，别叠在状态点上。

### Phase 4 —— 登录后上传 + 提示语 + 服务端

1. 登录成功后「云端无头像才上传」逻辑
2. 6 处拦截点文案统一 + 登录入口
3. 服务端 `viewRule` 变更 + 客户端 `expand=owner`
4. `AvatarCircle` 优先用 live 头像

---

## 8. 改动文件清单

### 8.1 新增（7 个）

| 文件                                              | 作用                                           |
| ----------------------------------------------- | -------------------------------------------- |
| `assets/images/avatars/av_01.webp … av_34.webp` | 34 张内置头像（复制自 `素材/用户头像/头像/`，重命名）              |
| `lib/services/avatar_preset_service.dart`       | 头像池枚举 / 路径解析 / 排除当前的随机抽取                     |
| `lib/services/current_user_store.dart`          | `CurrentUserStore extends ChangeNotifier` 单例 |
| `lib/widgets/user_avatar_view.dart`             | `CtUserAvatar` 统一头像 Widget                   |
| `lib/widgets/avatar_picker_sheet.dart`          | 内置头像网格选择器（34 张圆角方块，点选即生效）                    |
| `lib/widgets/login_prompt.dart`                 | 「该功能需要账号」轻量对话框（P1，见 §9）                      |
| `test/services/avatar_preset_service_test.dart` | 头像池单测                                        |

### 8.2 修改（14 个，含 2 个稳定区）

| 文件                                                                            | 改动                                                                         | 稳定区                  |
| ----------------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------- |
| `lib/main.dart`                                                               | `_checkAuthState()` 补 `createDefault()`；`_onLoginSuccess` 清 `_isLocalMode` | 🔴 **是**（需批准）        |
| `lib/main_container.dart`                                                     | `_currentUser` 改为读写 `CurrentUserStore`；引导气泡；登录后上传头像接线                      | 🔴 **是**（需批准）        |
| `lib/modules/auth/user_model.dart`                                            | +`avatarPreset` 字段与 `copyWith`                                             | 否                    |
| `lib/modules/auth/local_account_service.dart`                                 | +preset key、`createDefault()`、`setAvatarPreset()`、`updateAvatar` 清 preset  | 否                    |
| `lib/modules/auth/auth_service.dart`                                          | `:114-119` 补传 `avatarBytes` 进缓存（顺带修 bug，见 §10-R7）                          | 否                    |
| `lib/services/user_cache_service.dart`                                        | `buildUserAvatar` 保留但标记 deprecated；头像 key 收敛为常量                            | 否                    |
| `lib/widgets/floating_user_button.dart`                                       | 换 `CtUserAvatar`；加引导气泡；加重抽按钮（左下）                                           | 否                    |
| `lib/big_picture/widgets/bpm_top_bar.dart`                                    | 换 `CtUserAvatar`（统一默认头像）                                                   | 否                    |
| `lib/widgets/user_profile_modal.dart`                                         | 换 `CtUserAvatar`；加「换一张」；底栏【登录】保持                                           | 否                    |
| `lib/widgets/settings_modal.dart`                                             | 头像行换 `CtUserAvatar`；上传清 preset；修 `:338` 只传 url；加网格选择入口                     | 否                    |
| `lib/models/game_resource_model.dart`                                         | +`expandOwnerAvatar`（优先 live，回退快照）                                         | 否                    |
| `lib/services/game_resource_service.dart`                                     | 分享列表 `expand: 'game'` → `'game,owner'`                                     | 否                    |
| `lib/widgets/game_detail/share_list_dialog.dart` / `share_detail_dialog.dart` | 用 live 头像                                                                  | 否                    |
| `pubspec.yaml`                                                                | assets 加 `- assets/images/avatars/`                                        | 否（仅 assets，**不动依赖**） |

### 8.3 一期明确不碰

| 文件 / 区域                                                                                 | 原因                                                         |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `lib/pages/login/login_page.dart`、`lib/pages/register/register_page.dart`               | 路由不再挂载，但**不删**（AGENTS.md §2.3 禁止删现有代码；是否删除待 §13-Q3 决策）     |
| `lib/pages/login/local_account_setup_dialog.dart`                                       | 同上。且它是 `LocalAccountService.create()` 现有唯一调用方，删它等于删掉手动创建路径 |
| `lib/widgets/auth_modal.dart`                                                           | 主界面内的登录浮层，**继续使用**（用户卡片里的【登录】走它）                           |
| `lib/widgets/app_snack_bar.dart`                                                        | 全局提示组件，本期不改（见 §9-P1）                                       |
| `lib/widgets/game_detail/kanban_identity.dart`                                          | `'汐'` 硬编码兜底是既有 bug，**只报告不改**（§10-R9）                       |
| `lib/services/game_publish_service.dart` / `game_resource_service.dart` 的登录拦截           | 保持拦截（用户决策），只改 UI 提示语                                       |
| `lib/core/portable_*.dart`、`lib/theme/`、`lib/services/app_state.dart`、`windows/runner/` | 稳定区，与本次无关                                                  |
| `.workbuddy/pb_dev/pb_hooks/*.pb.js` 除 `resource_owner_name.pb.js` 外全部                  | 服务端只改一条规则，不新增 hook                                         |

---

## 9. 调用点替换清单（按优先级分批）

### P0 —— 不做就等于没做（核心体验）

| # | 位置                                  | 现状                                                | 改法                                                                                                           | 易漏点                                            |
| - | ----------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------------------- |
| 1 | `main.dart:968-983`                 | `_isLocalMode = !isValid && hasLocalAccount`      | 补 `if (!hasLocal) { await LocalAccountService.createDefault(); hasLocal = true; }`，`_isLocalMode = !isValid` | ⚠️ `createDefault` 内部必须断言 `!exists`，否则会覆盖老用户资料 |
| 2 | `main.dart:995-997`                 | `_onLoginSuccess` 只置 `_isLoggedIn=true`           | 补 `_isLocalMode = false`                                                                                     | ⚠️ 漏了会让主界面 `startInLocalMode` 残留 true          |
| 3 | `floating_user_button.dart:128-133` | `buildUserAvatar(avatarBytes, avatarUrl)`         | → `CtUserAvatar(size: 44, user: CurrentUserStore.instance.user)`                                             | ⚠️ `_buildStatusBadge` 占右下角，重抽按钮放左下            |
| 4 | `bpm_top_bar.dart:271-280`          | 同上 + `Icons.person_rounded` 默认                    | → `CtUserAvatar(size: 37)`，默认头像统一 SVG                                                                        | —                                              |
| 5 | `user_profile_modal.dart:185-190`   | 同上                                                | → `CtUserAvatar(size: 71)`                                                                                   | 本组件在 `OverlayEntry` 内，**必须靠内部订阅刷新**            |
| 6 | `settings_modal.dart:1213-1229`     | 只传 `avatarUrl`，本地态落 `_CachedAvatarWidget` 读云端 key | → `CtUserAvatar(size: 83)`；`_tempAvatarBytes` 预览作为 override 传入                                               | ⚠️ 这是 L2 串台 bug 的修复点                           |
| 7 | `settings_modal.dart:5114-5127`     | 本地写 bytes 后 `return`，无任何通知                        | 写 bytes + 清 preset + `CurrentUserStore.instance.apply(...)`                                                  | ⚠️ L1 根因                                       |
| 8 | `local_account_service.dart:56-74`  | `create` 无 preset                                 | 加 `avatarPreset` 参数 + `createDefault()`                                                                      | —                                              |

### P1 —— 体验补全

| #  | 位置                                                                                                                  | 改法                                                                                       |
| -- | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| 9  | `game_detail_page.dart:1032-1035 / 1122-1126 / 1166-1170 / 1221-1225 / 1252-1256`                                   | 5 处文案统一为常量 `kCloudFeatureNeedsAccount`，文案「该功能需要账号 · 本地管理功能不受影响」                          |
| 10 | 同上 5 处 + `docs_my_tab.dart:71/:77-80/:150-174` + `docs_publish_tab.dart:70-74` + `upload_publish_dialog.dart:40-43` | 增加可达登录入口：优先 `LoginPrompt.show(context)`（新增轻量对话框）；`docs_my_tab` 的 `_loginHint` 加【登录/注册】按钮 |
| 11 | `main_container.dart:263-277`                                                                                       | `showLocalSetupOnFirstFrame` 恒 false（首启动不再弹填写窗），参数保留不删                                   |
| 12 | 新增引导气泡                                                                                                              | 首启动在悬浮头像上方显示气泡「点这里换头像 / 你好，萌萌团」，点过即写 `prefs['local_avatar_hint_shown']=true`             |

> ⚠️ **P1-9/10 的实现约束**：`AppSnackBar` 系列（`app_snack_bar.dart:36-55`）**没有 action 参数**，底层是 `SystemNoticeService`（自定义通知，不是真正的 `SnackBar`）。**不要**为此改造 `SystemNoticeService`（那是全软件提示的通道，改它风险远大于收益）。用「独立对话框 / 列表内按钮」实现入口。

### P2 —— 他人视角 + 优化

| #  | 位置                                                              | 改法                                                                                                   |
| -- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| 13 | `game_resource_service.dart:228`                                | `expand: 'game'` → `expand: 'game,owner'`（`getFullList` 同理，见 `:479` / `:509`）                        |
| 14 | `game_resource_model.dart:359-364`                              | 加 `String? get liveOwnerAvatarUrl`：优先 `expand.owner.avatar` + `ownerId` 拼 URL，回退 `ownerAvatarUrl` 快照 |
| 15 | `share_list_dialog.dart:189` / `share_detail_dialog.dart:158`   | 改用 `liveOwnerAvatarUrl`                                                                              |
| 16 | PB 线上 `users.viewRule`                                          | 超管 PATCH 为 `@request.auth.id != ""`（见 §5.4 部署纪律）                                                     |
| 17 | `user_cache_service.dart:13` + `settings_modal.dart:5134` 等 4 处 | `'user_avatar_base64'` 字面量收敛为单一常量                                                                    |

### 非 Widget 的易漏路径（这些不是 UI，但同样会"拦人"或"读到旧头像"）

| 路径      | 位置                                                                                                           | 风险                                                            |
| ------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| 服务层兜底拦截 | `game_publish_service.dart:104/221/271/294/314/341`、`game_resource_service.dart:148/247/281/303/323/347/404` | UI 绕过也会 throw `请先登录后再…`，文案与 UI 不一致                            |
| 元数据回传   | `game_repository.dart:310/:361`                                                                              | `canUploadMetadata => PBConfig.isLoggedIn` — 本地态跳过（**正确，别改**） |
| 截图回传    | `game_detail_page.dart:465-470`                                                                              | 本地态跳过（**正确，别改**）                                              |
| 安装统计    | `install_stats_service.dart:63-66`                                                                           | 同上                                                            |
| 探索元数据   | `discover_metadata_service.dart:379`                                                                         | 同上                                                            |
| 记住登录    | `remember_me_store.dart:28`                                                                                  | 与本地账户无关，**别动**                                                |

---

## 10. 风险登记

| ID      | 级别    | 风险                                                                        | 触发条件                                    | 应对                                                                                                  |
| ------- | ----- | ------------------------------------------------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **R1**  | 🔴 P0 | **`createDefault()` 覆盖老用户资料**                                             | 老用户已有 `local_account_id` 但代码逻辑写错成无条件创建  | `createDefault()` 首行 `assert(!exists)` + 运行时 `if (exists) return load()!;` 双保险；单测覆盖「已有账户时调用不改变任何字段」 |
| **R2**  | 🔴 P0 | **碰 `users.createRule` 导致注册全挂**                                           | 执行 AI 用整集合 PATCH 更新规则                   | 部署只 PATCH `viewRule` 单字段；改后立刻跑一次注册探针                                                                |
| **R3**  | 🔴 P0 | **放开 `viewRule` 泄露邮箱**                                                    | 生产库存在 `emailVisibility=true` 的记录        | Phase 0 P-05 先快照；有 `true` 则先报告（§13-Q1），不擅自改用户数据                                                     |
| **R4**  | 🟠 P1 | 4 个显示点换 `CtUserAvatar` 时**漏换一处**                                          | `bpm_top_bar` 藏在 `lib/big_picture/`，容易漏 | §9-P0 表格逐条勾；验收必须**四处各截一张图**比对                                                                       |
| **R5**  | 🟠 P1 | `CurrentUserStore` 与 `MainContainer._currentUser` **双真理源**                | 改造时保留旧字段又新增 store                       | 改造后 `MainContainer._currentUser` 只作 getter 转发，**不得**再有自己的 setState 赋值                               |
| **R6**  | 🟠 P1 | 首启动 `createDefault()` 读了 asset 字节 → 首帧卡顿                                  | 误在 create 里 `rootBundle.load` 落 base64  | 只存 preset id（§3.2-B）；代码注释写明「此处禁止 IO」                                                                |
| **R7**  | 🟡 P2 | **既有 bug**：`auth_service.dart:114-119` `saveUserInfo` 不传 `avatarBytes`    | 冷启动离线时读到更早会话的 base64                    | 本次顺带补传（一行）；同时验证不影响登录耗时                                                                              |
| **R8**  | 🟡 P2 | 头像池 webp 打包后体积超预期                                                         | 安装包从 X MB 变 X+1.1MB                     | 预算已含；若不可接受，改 256px 重压（§13-Q4）                                                                       |
| **R9**  | 🟡 P2 | **既有 bug（只报告不改）**：`kanban_identity.dart:116-127` `_initial()` 硬编码返回 `'汐'` | 非看板娘用户无头像时显示「汐」字                        | 记入 DEV_LOG 遗留；本期若改 `AvatarCircle` 顺带修正，需单独说明                                                        |
| **R10** | 🟡 P2 | 重抽按钮与网络状态圆点**叠位**                                                         | 都在头像右下角                                 | 重抽放左下 / 卡片内；真机走查必须有这一步                                                                              |
| **R11** | 🟡 P2 | `expand=owner` 在游客态返回空                                                    | 未登录用户浏览分享                               | 回退快照（§4.4），不报错、不重试                                                                                  |
| **R12** | 🟢 P3 | `LoginPage` 成为死代码                                                         | 路由永不挂载                                  | 保留不删（§8.3），在文件头加注释说明「当前无路由挂载，保留待决策」                                                                 |

---

## 11. 验收标准

### 11.1 功能验收（必须逐条真机走查）

- [ ] **F1** 删除全部 prefs 后启动 → 直接看到库页，全程无登录/注册界面
- [ ] **F2** 库页右下角头像已是具体插画（非线稿图标）；点开卡片显示「萌萌团」，简介为空
- [ ] **F3** 重启 3 次 → 头像**完全不变**（稳定固化）
- [ ] **F4** 点重抽 → 头像变、且**不是**刚换掉的那张
- [ ] **F5** 重抽后**不重启**：悬浮按钮 / BPM 顶栏 / 用户卡片 / 设置页 四处**同步**（四处各截一张对照）
- [ ] **F6** 打开内置头像网格 → 34 张全部可见可点 → 点选立即生效且全局同步
- [ ] **F7** 上传自定义图片 → 头像变、preset 被清空（重抽回到池内仍正常）
- [ ] **F8** 未登录点「获取下载」→ 提示语含「本地管理功能不受影响」+ 有可达登录入口
- [ ] **F9** 登录一个**云端无头像**的账号 → 本地选的头像自动出现在云端（另开设备确认）
- [ ] **F10** 登录一个**云端有头像**的账号 → 云端头像保留，未被本地随机头像覆盖
- [ ] **F11** 账号 A 改头像 → 账号 B 刷新分享列表 → 看到 A 的新头像（非旧快照）
- [ ] **F12** 登出 → 回到本地身份，头像恢复为本地那张（**不是**云端那张）
- [ ] **F13** 老用户场景：手工写 `local_account_id` + name 不带 preset → 启动后**名字不被改成萌萌团**，头像按"空则补抽"规则处理

### 11.2 技术验收

| 项        | 命令 / 方式                                                                               | 通过标准                                                   |
| -------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| 静态分析     | `./flutter/bin/flutter.bat analyze <改动的每个文件>`                                         | **0 error**（存量 info/warning 不管，只看本次是否新增 error）         |
| 单测       | `./flutter/bin/flutter.bat test test/services/ test/modules/auth/`                    | 新增用例全过；`local_account_service_test.dart` 9 个老用例**不回归** |
| 全量回归     | `./flutter/bin/flutter.bat test`                                                      | **当场跑一次取真实基线**，不引用本文档任何数字（AGENTS.md §4 明令）             |
| 已知 flaky | `test/smart_import/`、`game_move_service_test`                                         | 失败属既有，非本次回归                                            |
| HEAD 已失败 | `cover_preview_overlay_test`、`cover_gallery_overlay_test`、`bpm_page_zone_wiring_test` | 同上，勿当回归                                                |
| 改动面自查    | `git status --short` + `git diff --stat`                                              | 只含 §8.1/§8.2 列出的文件；稳定区两个文件必须在批准后动                      |
| 打包       | `build_windows.bat`                                                                   | webp asset 打进包；exe 时间戳变化（不变 = 没构建）                     |
| 服务端      | 线上 `read_values()` 前后比对                                                               | 仅 `viewRule` 一个字段变化，其余字节级一致                            |


### 11.3 Phase 0 验证记录（待填）

| ID   | 结论   | 数据 |
| ---- | ---- | -- |
| P-01 | ⏳ 未跑 | —  |
| P-02 | ⏳ 未跑 | —  |
| P-03 | ⏳ 未跑 | —  |
| P-04 | ⏳ 未跑 | —  |
| P-05 | ⏳ 未跑 | —  |

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
你在 D:\CTLIB（Flutter Windows Galgame 管理器），要实现「本地优先账号 + 系统头像池」。

【唯一需求源】docs/DEV/features/local_first_account_and_avatar_plan.md —— 先完整读它，
再读 AGENTS.md、docs/DEV/SESSION_HANDOFF.md、docs/DEV/features/local_account_mode.md。

【铁律】
1. 先只读审计，出《变更计划》等批准；不得直接改代码。
2. lib/main.dart 与 lib/main_container.dart 是稳定区，动之前必须单独说明并取得明确同意。
3. Flutter 用 ./flutter/bin/flutter.bat（项目内 3.24.3），不用全局命令；跑前 unset 全部代理。
4. 一次任务只解决一个问题；禁止顺手重构 / 格式化 / 删代码 / 升依赖。
5. 收工：analyze（只看新增 error）→ git status 自查 → 更新 DEV_LOG / SESSION_HANDOFF /
   本功能文档 → 一任务一 commit（git add 显式文件，禁 -A）。
6. 禁止 git gc。

【必须按阶段走】
Phase 0：先做 5 项技术验证（P-01 到 P-05），任一失败先报告，不许带着未验证假设往下写。
Phase 1：头像池落地（纯新增，可独立提交）
Phase 2：CurrentUserStore + CtUserAvatar 收敛 4 个显示点（独立提交，核心判据=不重启全局同步）
Phase 3：首启动 createDefault + 引导气泡 + 重抽按钮
Phase 4：登录后上传 + 提示语 + 服务端 viewRule

【最容易踩的 6 个坑】
1. users.createRule 是空串（注册依赖匿名创建）——绝对不能碰，只改 viewRule。
2. 头像文件本身已是公开可访问的（avatar.protected=false），缺的只是"当前文件名"。
3. createDefault() 必须 assert(!exists)，否则覆盖老用户资料；且内部禁止任何 asset/图片 IO。
4. floating_user_button 头像右下角已被"网络状态圆点"占用，重抽按钮放左下。
5. 用户卡片在 OverlayEntry 里，setState 不会重建它 —— 刷新必须靠 Widget 内部订阅 ChangeNotifier。
6. 设置页 _avatarUrl 只传 url，本地态 avatarUrl=''，会读到云端 key —— 这是既有串号 bug 的修复点。

【不做什么】
不删 LoginPage/RegisterPage/LocalAccountSetupDialog；不改 SystemNoticeService；
不做云端数据同步；不做账户绑定迁移；不做头像裁剪；不加 thumbs 缩略图。
```

---

## 13. 待用户决策的开放问题

| ID     | 问题                                                                         | 影响                            | 建议                                                        |
| ------ | -------------------------------------------------------------------------- | ----------------------------- | --------------------------------------------------------- |
| **Q1** | 若生产库存在 `emailVisibility = true` 的用户记录，怎么办？                                 | 放开 `viewRule` 后其邮箱会暴露给已登录用户   | 建议：**只报告，不擅自改**。若数量少，由用户决定是否统一置 `false`。这是改用户数据，需单独批准     |
| **Q2** | 未登录（游客）浏览分享时，是否需要看到他人实时头像？                                                 | 需要 → 必须升级到 §3.4-B（独立公开资料集合）   | 建议本期**不做**（游客看到旧快照可接受）。若要做，单独立项                           |
| **Q3** | `LoginPage` / `RegisterPage` / `LocalAccountSetupDialog` 三个文件改完后是死代码，删还是留？ | 删 = 少 3000 行死码；留 = 违反"干净"但更安全 | 建议**本期留**（AGENTS.md 禁止删现有代码），在文件头加「当前无路由挂载」注释，下一个版本再议     |
| **Q4** | 34 张 webp 打包 +1.1MB 是否可接受？要不要压到 256px（≈400KB）？                             | 影响安装包体积与头像清晰度                 | 建议**原图打包**（96px 显示位，396px 有 4× 余量，为未来大尺寸头像留空间）；若用户对体积敏感再压 |
| **Q5** | 「萌萌团」这个名字在设置页**是否允许改**？                                                    | 允许 → 它是"默认名"；不允许 → 它是"品牌标识"   | 建议**允许改**（设置页现有资料编辑已支持），默认值保持萌萌团                          |
| **Q6** | 重抽头像是否需要二次确认？                                                              | 用户原话是"抽到满意就停"，暗示无确认           | 建议**无确认、即时生效即时落盘**，但要有动画反馈（否则用户不知道变了）                     |

---

## 14. 诚实声明：未验证的部分

- 本文件**全部内容来自只读审计**，**没有写一行业务代码、没有跑一次测试**。
- §7 Phase 0 的五项假设（webp asset 解码、AssetManifest 枚举、webp 上传往返、`expand=owner` 生效、`emailVisibility` 全量分布）**全部从未实测**。
- 服务端规则改动的**生产库实际值未查**（本次只查了本地 `pb_data_dev`，且该库 `users` 表 0 条记录）。
- §11.2 的测试基线**没有当场跑**，本文档**不提供任何数字**（AGENTS.md §4 明令不得固化）。
- 影响面判断（"改 `viewRule` 不影响既有 6 处本地分支"）是基于代码阅读的推理，未经真机验证。

---

## 16. 入口收敛修正（2026-10-23 晚，LOCAL-AVATAR-ENTRY）

用户复核 §15 的实现后指出：**头像修改口开得太多，且引导语指向了错误的东西**。
原文要求：「头像修改只允许设置页（个人资料）与注册界面，其他地方都是展示」；
「不要给头像任何提示/引导；如果硬要给，就告诉用户右下角那个按钮是账户窗口」。

### 16.1 行为改动

| 位置 | §15 的做法（已推翻） | 现在 |
|------|----------------------|------|
| 悬浮按钮 | 头像左下角有 ↻ 重抽按钮 | **删除**，只展示 |
| 悬浮按钮 | 「你好，萌萌团 / 点下面的 ↻ 就能换一张头像」+【知道了】按钮 | 改为「账户窗口 / 点这里查看资料、登录或退出」，**无按钮、5 秒自动淡出**、只显示一次 |
| 用户卡片 | 头像左下角有 ↻ 重抽按钮 | **删除**，只展示 |
| 设置 → 个人资料 | 只有「上传新头像」+「从系统头像库挑一张」 | 头像**左下角新增 ↻ 随机**（保留原来的上传与网格入口） |
| 注册表单（AuthModal） | **完全没有头像**（旧 RegisterPage 有，但该页已无挂载） | 昵称输入框右侧 +56px 圆形头像按钮，点击打开 34 张系统头像库 |
| 头像选择器 | 只有「写 store」一种模式 | 增加 `applyToStore: false` 的**纯选择**模式；头部增加「随机换一张」循环按钮 |

### 16.2 两个执行期的判断

1. **注册头像不做成独立一行，而是嵌进昵称行。** 单独一行要 +72px，而
   注册表单在 1080×608 窗口下已经接近满高（内容 ≈589px / 可用 584px），
   会把「注册账号」按钮挤到必须滚动。嵌进昵称行只 +5px（56 高 vs 输入框 51）。
   顺带把 `AuthModal` 的 `Column` 包进 `SingleChildScrollView` + `maxHeight`
   （`screenH - 24`），装得下时外观与原来完全一致，装不下时滚动而不是裁切。
2. **注册表单只给「挑系统头像」，不给「上传自己的图」。** 头像按钮只有 56px，
   塞不下第三个入口；上传能力在「设置 → 个人资料」完整存在，且注册后即登录，
   随时可去换。如日后要加，入口应放在系统头像库对话框里（带 `allowUpload` 开关），
   不要往表单里再塞一行。

### 16.3 代码落点

- `lib/widgets/floating_user_button.dart`：删 `_shuffleAvatar` / `_buildShuffleButton`；
  `_buildHintBubble` → `_buildAccountHint`；提示改为 `AnimatedSwitcher` 交叉淡入淡出 +
  `Timer(5s)` 自动收起；prefs key 由 `local_avatar_hint_shown` 改为 `floating_button_hint_shown`。
- `lib/widgets/user_profile_modal.dart`：删 `_buildShuffleBadge` 及其调用（顺带去掉
  因此失效的 `current_user_store` / `interactive_wrapper` 导入 —— 后者仍被
  `_buildChargeButton` 使用，复扫时已发现并恢复）。
- `lib/widgets/settings_modal.dart`：`_buildAvatarRow` 头像改为 `Stack` + 左下角
  `_buildShuffleAvatarButton()`（仅本地账户）；新增 `_shuffleAvatar()`（换完清预览图）。
- `lib/widgets/auth_modal.dart`：`_regAvatarPreset` 状态 + `_openRegisterAvatarPicker()` +
  `_syncRegisterAvatar()`（注册成功后先写本地 preset 再上传 webp）+ `_buildRegisterAvatarButton()`。
- `lib/widgets/avatar_picker_sheet.dart`：`applyToStore` 双模式 + `pick()` 静态入口 +
  头部 `_shuffle()`；**关闭按钮改为无参 `pop()`**（按 `String` 泛型化后 `pop(false)` 会抛类型错）。

### 16.4 验证

| 项 | 方式 | 结果 |
|----|------|------|
| 静态分析 | 进程内 analyzer，355 文件全量 | **errors=0**（改动文件 0 warning；settings/user_profile 余下均为存量） |
| 入口收敛 | `grep` 全库审计 | 改头像只剩设置页（上传/网格/随机）与注册表单（网格/随机） |
| 布局 | 算术核算（231 期间无法真机渲染） | 注册表单内容 ≈589px，`maxHeight` = 窗口高−24；608 高窗口下完整可见，更矮则滚动不裁切 |

### 16.5 仍未做

1. 🔴 **真机走查**：设置页 ↻ 位置与手感、注册表单头像按钮在 608/720 高窗口的观感、
   悬浮按钮提示气泡的 5 秒淡出节奏。
2. 🟡 **待决策（能力缺口，本次未动）**：云端已登录用户在设置页**看不到**「系统头像库」入口
   （`AvatarPickerDialog.show` 有 `isLocal` 守卫）。而用户最初的要求是「这些头像不仅运用在
   本地用户，在线账号头像也使用这套系统」。补这个缺口需要：放开守卫 → 云端用户选中后
   把 webp 上传到 `users.avatar` → 同步本地缓存。属于新能力，不在本次「入口收敛」范围内。
