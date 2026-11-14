# 本地账号体系重构 —— 设计与变更计划

> 状态：**✅ 已实施（2026-10-02，开发者批准后按阶段 B 执行完毕）**。实施记录见文末 §7。
> 目标：软件从「强制注册登录」回归本地化，分为**本地状态**（本地账户）与**在线状态**（已登录账号）。
> 术语约定（需求 1）：**本地** = 本地账户（仅存于本机，无 PocketBase 记录、无 token）；
> **账号** = 已登录账户（PocketBase `users` 记录）。
> 创建：2026-10-02　审计人：潮汐

---

## 1. 现状结论（审计要点，均含 文件:行号 证据）

### 1.1 登录为什么是强制的
| 环节 | 位置 | 行为 |
|---|---|---|
| 启动守卫 | `lib/main.dart:895-906` `_checkAuthState` → `AuthService.checkAutoLogin()` | 失败即停留登录窗口 |
| 页面分支 | `lib/main.dart:1042-1056` | `_isLoggedIn ? MainContainer : LoginPage/RegisterPage` |
| 自动登录 | `lib/modules/auth/auth_service.dart:963-1000` | 本地恢复 token + JWT exp 校验 + 后台 authRefresh |
| 登录态唯一来源 | `lib/core/pb_config.dart:18` | `pb.authStore.isValid`（token 在 SharedPreferences 4 个 key） |

### 1.2 对本地化有利的事实
- **探索页客户端本就不 gate 登录**：`discover_page.dart` 全文无 `PBConfig.isLoggedIn`，只 gate `NetworkStatusService.isOnline`（`:341`、`:925`、`:222-245`）。
- **服务端已允许匿名只读**：games List/View = `@request.auth.id != "" || review_status = "approved"`（`features/pb_setup_stepbook.md:397-407`）；game_resources List/View = `kind="official" || (kind="community" && status="published") || owner=@request.auth.id`（同档 `:445-453`）。
  → **需求 3（匿名只读浏览）服务端零改动、探索页零改动。**
- **下载本体不经过 PB**：`download_core.dart` 无任何 PB 引用；`global_install_center.dart` 仅安装成功后统计上报（`:551-555`）。
- **添加页/库页/主页/BPM 全部本地功能**：`join_page.dart` 及 `join/` 无 PB / 登录依赖（grep 0 命中）；BPM 产品决策即整体本地。
- **写操作全部已有登录 gate**（本地用户不写 token 即自动被拦，逻辑无需逐个改）：
  - 元数据回传 `lib/repositories/game_repository.dart:309`（`canUploadMetadata => PBConfig.isLoggedIn`）
  - 安装统计 `lib/services/install_stats_service.dart:62-66`
  - 官方下载入口 `lib/pages/game_detail_page.dart:1000`
  - 上传资源入口 `lib/pages/game_detail_page.dart:1089`
  - 报告失效入口 `lib/pages/game_detail_page.dart:1145`
  - 统计路由（下载计数/点赞/举报）`lib/services/game_resource_service.dart:336`（未登录静默 false）
  - 我的点赞回显 `lib/services/game_resource_service.dart:356`
  - 发布/编辑/删除作品 `lib/services/game_publish_service.dart:101-104 / 210-213 / 252-254`
  - 文档板块发布/我的 `lib/widgets/explore_hall/docs_publish_tab.dart:55,67`、`docs_my_tab.dart:57,140`

### 1.3 用户入口与浮层结构
- 桌面态：右下角 `FloatingUserButton`（`lib/widgets/floating_user_button.dart`）→ `main_container.dart:586-609` `_showAuthOverlay` → `:604` `_isLoggedIn ? UserProfileModal : AuthModal`。
- BPM 态：`bpm_top_bar.dart:22-29` 用户按钮与桌面**完全同源**（同一 Overlay、同一 UserProfileModal）→ 改一处自动覆盖 BPM。
- 用户窗口现状：`lib/widgets/user_profile_modal.dart:310`（退出登录按钮硬编码 `:311`）；名字兜底 'Kiyoko' `:42`。
- 应用内登录浮层：`lib/widgets/auth_modal.dart`（登录+注册二合一）。
- 设置窗口账号区块：`lib/widgets/settings_modal.dart:310 / 361-367 / 5045-5050`（读用户 / 改资料 / 传头像，均直连 AuthService → **本地态需分支**）。

### 1.4 已发现的隐患（顺带报告，不擅自改）
- `lib/pages/game_detail_page.dart:512-513` 截图回传 PATCH 手动拼 `Bearer ${PBConfig.token}`，无客户端登录前置 → 本地用户触发会带空 Bearer（服务端会拒，失败表现待查）。
- `AuthService.logout()`（`auth_service.dart:957`）调 `UserCacheService.clearAll()` → 本地账户资料若与云端缓存共用 key 会被误删，**必须独立 key**。

---

## 2. 设计

### 2.1 状态机
```
启动
 ├─ checkAutoLogin() 成功 ──────────────→ 在线态进入主界面
 ├─ 本地账户存在 ──────────────────────→ 本地态进入主界面（不再见登录窗口）
 └─ 两者皆无 ──→ 登录窗口（新增【以本地游客进入】）
                    └─ 点击 → 基础信息填写窗（名字必填 / 头像·简介可选）
                            → 创建本地账户 → 本地态进入主界面

运行中
 本地态 --用户窗口【登录】→ AuthModal --登录成功--> 在线态（本地资料保留不删）
 在线态 --用户窗口【退出登录】→ AuthService.logout()
        ├─ 存在本地账户 → 回到本地态（软件不退出）
        └─ 无本地账户   → 登录窗口（现状行为）
 在线态 --token 被吊销(401/403, onForceLogout)→ 同上二分支
 断线/恢复：现有 NetworkStatusService 机制不变；本地态与网络状态解耦
```

### 2.2 身份模型
- 本地账户 id：`local_` + 8 位随机串；`UserModel.isLoggedIn = false`。
- `UserModel` 增加只读 getter `bool get isLocalAccount => !isLoggedIn && id.startsWith('local_');`
- **云端视角 = 匿名**：本地态下 authStore 无 token，一切 PB 请求自然匿名（只读 approved/published）；云端无此用户记录，「匿名本地用户」即指这一云端身份。
- 本地资料与云端缓存**完全隔离**（独立 key 前缀，见 2.3），登录正式账号不覆盖本地资料，退出登录后本地身份原样恢复。

### 2.3 本地存储（新增 `lib/modules/auth/local_account_service.dart`）
SharedPreferences key（与 `UserCacheService` 的 `user_*`、`AuthService` 的 `pb_*` 隔离）：
| key | 内容 |
|---|---|
| `local_account_id` | `local_xxxxxxxx` |
| `local_account_name` | 名字（必填） |
| `local_account_bio` | 简介（可选） |
| `local_account_avatar_b64` | 头像 base64（可选，与现有云端头像缓存同量级） |
| `local_account_created_at` | ISO 时间 |

API：`exists() / create({name,bio,avatarBytes}) / load() → UserModel? / updateProfile(...) / updateAvatar(bytes) / clear()`（clear 本期不挂 UI，预留）。
本地头像在构造 UserModel 时直接解码进 `avatarBytes`，绕开 `_CachedAvatarWidget` 的云端 key，避免歧义。

### 2.4 权限矩阵（目标态）
| 功能 | 在线态 | 本地态 | 实现 |
|---|---|---|---|
| 库页 / 添加页 / 主页 / BPM | ✅ | ✅ | 本地功能，零改动 |
| 探索页浏览（游戏/系列/月历/推荐/分享列表/资源详情） | ✅ | ✅ | 匿名只读，零改动 |
| 元数据回传 / 安装统计上报 | ✅ | 静默跳过 | 既有 gate 自动生效 |
| 获取（官方下载）· 分享 · 发布 · 上传 · 点赞 · 报告失效 | ✅ | ❌ + 引导注册 | 既有 gate 保留，文案统一 |
| 用户资料编辑（用户窗口/设置窗口） | 写云端 | 写本地 | 需改造（2.5） |

### 2.5 UI 改动
1. **`login_page.dart`**：新增次级按钮【以本地游客进入】（登入按钮下方、去注册链接上方），新回调 `onLocalGuest`。
2. **新增 `lib/pages/login/local_account_setup_dialog.dart`**：名字必填校验；头像可选（本地选图 → base64）；简介可选。确认后 `LocalAccountService.create` → 进入主界面。
3. **`user_profile_modal.dart` 双态**：
   - 本地态：头像/名字/简介显示本地资料；UID 行显示「本地用户」；底部按钮 =【登录】（打开 AuthModal）+【个人设置】；头部轻提示一行（文案见 §5-2）。
   - 在线态：现状不变（退出登录 + 个人设置）。
4. **`main_container.dart`**：
   - `:604` 浮层改为**总是弹 UserProfileModal**（本地/在线由内部态决定），本地态【登录】→ 关闭当前浮层 → 打开 AuthModal；
   - `_onLogout` / `_onForceLogout` 重构为二分支（有本地账户 → 重载本地身份，不退软件；无 → `widget.onLogout` 现状行为）；
   - 本地态 `_loadCurrentUser` 走 `LocalAccountService.load()`。
5. **`main.dart`**：`_checkAuthState` 增加本地账户分支；`_buildBody` 增加「本地态 → MainContainer」；新增 `_onLocalGuestCreate` 回调链。
6. **`settings_modal.dart`** 账号区块三处调用点（`:310/:361/:5045`）：本地态改走 LocalAccountService（改名/简介/头像写本地），在线态不变。
7. **权限提示文案统一**：被拦功能的 snackbar 文案统一为「该功能需要登录账号后使用」（替换现有「请先在左侧边栏登录账号…」三处：detail 页 1001/1090/1146）。第一版仅改文案，不做「直达登录浮层」交互（见 §5-3）。

### 2.6 明确不改
- **PocketBase 服务端与全部 Hook（零改动）**；`discover_page.dart`；`join/` 添加页；库页/主页/BPM 页面；`download_core.dart` / `global_install_center.dart`；`register_page.dart`（正式注册流程不变）；`auth_service.dart` 主体（login/logout/autoLogin 原样，仅调用方分支变化）。

---

## 3. 影响面与风险

| # | 风险 | 缓解 |
|---|---|---|
| 1 | `main.dart` / `main_container.dart` 属稳定区 | 本计划即审批载体；改动点已逐一列出（预计 main.dart ~40 行、main_container ~60 行） |
| 2 | logout 误删本地资料 | 独立 key 前缀 + 隔离测试 |
| 3 | BPM 用户面板回归 | 与桌面同源（`bpm_top_bar.dart:22`），改一处自动覆盖；真机走查确认 |
| 4 | FloatingUserButton 状态圆点语义 | 继续表示网络状态（本地态也可联网浏览），不改 |
| 5 | detail 页空 Bearer 隐患（§1.4） | Phase 3 顺带给 `_handleScreenshotUpload` 类路径补客户端 gate |
| 6 | `flutter test` 本环境跑不了（管道 231） | analyze 用 `.workbuddy/analyze_probe/`；test 由开发者终端补跑；**跑不了的测试 = 没有测试**，新增服务层带单测（本地账户 CRUD、隔离性） |

## 4. 实施步骤（每 Phase 一个 commit）
- **Phase 1 数据层 + 启动流**：新增 `local_account_service.dart`（含单测）、`local_account_setup_dialog.dart`；改 `user_model.dart`(+getter)、`login_page.dart`(+按钮)、`main.dart`（启动三分支）。
- **Phase 2 用户窗口双态**：改 `user_profile_modal.dart`、`main_container.dart`（浮层/登出/强登出/本地身份加载）。
- **Phase 3 权限边界**：改 `settings_modal.dart` 三处分支、`game_detail_page.dart` 三处文案 + 截图回传 gate、`game_resource_service.dart` 提示语核对。
- **Phase 4 收尾**：analyze probe 0 新增 error → 开发者终端 `flutter\bin\flutter.bat analyze test` → 真机走查（§6 清单）→ features/DEV_LOG/SESSION_HANDOFF 更新。

## 5. 待开发者拍板的保守默认
1. **「匿名本地用户」呈现**：推荐——用户窗口与各 UI 显示用户自填的名字，UID 行显示「本地用户」；「匿名」仅描述云端视角（无身份记录）。备选：UI 直接显示「匿名本地用户」。
2. **本地态头部提示文案**：推荐「以本地身份使用中 · 登录后可获取与分享资源」。
3. **引导强度**：第一版被拦功能仅统一文案提示；「点击直达登录浮层」留待下一轮（涉及 detail 页跨层调 main_container 浮层）。
4. **在线 → 本地后再次登录**：本地资料保留、云端资料恢复显示，两套并存互不覆盖——确认此行为。
5. **本地头像**：允许，base64 存 SharedPreferences（与现有云端头像缓存同量级）。

## 6. 真机走查清单（Phase 4 用）
- [ ] 首次启动（无 token 无本地账户）→ 登录窗口出现游客按钮 → 填写窗 → 本地态进主界面
- [ ] 重启软件 → 直接本地态进入（不见登录窗口）
- [ ] 本地态：库页/添加页/主页/BPM 正常；探索页可浏览、分享列表可看
- [ ] 本地态：获取/分享/上传/发布被拦且提示正确；点赞/报告失效静默或提示
- [ ] 本地态：用户窗口显示本地资料 +【登录】；设置窗口改名字/头像写本地
- [ ] 本地 → 登录正式账号 → 云端资料显示；退出登录 → 本地资料原样恢复
- [ ] 无本地账户的纯在线用户退出登录 → 回登录窗口（现状不变）
- [ ] BPM 模式用户按钮双态正确

---

## 7. 实施记录（2026-10-02）

**改动 7 文件（+339/-54）+ 新增 2 lib 文件 + 1 测试**，全部在批准范围内：

| 文件 | 改动 |
|---|---|
| `lib/modules/auth/local_account_service.dart` 🆕 | 本地账户 CRUD（`local_account_*` 独立 key，与 `pb_*`/`user_*` 隔离） |
| `lib/pages/login/local_account_setup_dialog.dart` 🆕 | 基础信息填写窗（名字必填/头像·简介可选，不可关闭，FilePicker 选图 ≤2MB JPG/PNG） |
| `test/modules/auth/local_account_service_test.dart` 🆕 | 8 用例：CRUD 往返 / base64 损坏容错 / **隔离性红测**（清 pb_*/user_* 不影响 local_*）/ fail-fast |
| `lib/modules/auth/user_model.dart` | +`isLocalAccount` getter（:78） |
| `lib/pages/login/login_page.dart` | +`onLocalGuest` 回调 +【以本地游客进入】次级按钮 |
| `lib/main.dart` | init 注册、启动三分支（`_checkAuthState` 本地账户分支）、`_onLocalGuest`、MainContainer 新参传参、`_handleLogout` 重置本地态 |
| `lib/main_container.dart` | 新参 `startInLocalMode`/`showLocalSetupOnFirstFrame`/`onLocalSetupCompleted`；浮层**总是弹用户窗口**；新增 `_showLoginOverlay`；`_onLogout`/`_handleCloudSessionLost` 二分支；`_loadCurrentUser` 本地分支；本地游客首帧弹填写窗；⚠️ 删除 `_isLoggedIn` 字段（唯一读取点被取代，unused warning） |
| `lib/widgets/user_profile_modal.dart` | 双态：本地态 UID 行「本地用户 · 登录后可获取与分享资源」+【登录】accent 按钮；名字列包 Expanded 防 wrap 溢出 |
| `lib/widgets/settings_modal.dart` | 账号区块三处本地分支：`_loadUserData` 本地回退 / `_handleSave` 写 `LocalAccountService.updateProfile` / `_handleAvatarUpload` 写本地头像不上传 |
| `lib/pages/game_detail_page.dart` | 三处权限文案统一「该功能需要登录账号后使用」+ `_uploadScreenshotsToPB` 补登录 gate（消除空 Bearer） |

**验证**：进程内 analyzer 全 lib **errors=0**（304 文件，`.workbuddy/analyze_probe/`）；改动文件逐个 0 error。
**未验证**：`flutter test`（本环境管道 231，开发者终端补跑）；真机走查（§6 清单）。
**实施偏离**：commit 粒度由「每 Phase 一个」合并为**一个 commit**（Phase 1/2 文件相互依赖，
中间 commit 编译不过；符合 AGENTS.md「一任务一提交」）。

## 8. v1.4 修复（2026-10-02 真机反馈）

真机走查发现两个缺陷，已修（`user_profile_modal.dart` / `main_container.dart`）：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 本地态用户窗口 UID 行「本地用户 · 登录后可获取与分享资源」与右上角 NSFW 快捷开关叠字 | `_buildHeader` 为嵌套结构：外层 Row(spaceBetween) 的左 Row 内含 `Expanded` → 左 Row 被撑满 449，外层总宽溢出，spaceBetween 负间隙把右列拉回与 UID 行重叠 | 头部改为**扁平 flex**：`Row[头像, 16, Expanded(名字列), 12, 右列]`；UID 行补 `maxLines: 2 + ellipsis` |
| 2 | 本地态点【登录】→ 登录成功后浮层跳回但**仍显示本地资料**，而右下角按钮已是登录态 | `_onLoginSuccess` 未 `await _loadCurrentUser()` 就延时 350ms 重开浮层；**OverlayEntry.builder 是一次性快照**，不随 MainContainer.setState 重建——350ms 时云端资料还在路上，浮层定格旧本地资料；右下角按钮在普通树内随 setState 刷新，故先变 | `_onLoginSuccess` 改 async：`await _loadCurrentUser()` 就位后再延时重开（350ms > 登录浮层退场动画 200ms，槽位已清空） |

**验证**：进程内 analyzer 两文件 errors=0（user_profile_modal 另有存量 warning
`unused import: dart:convert`，系更早遗留，按规范只报告未顺手改）。
**未验证**：真机走查（叠加与切换两场景需开发者复测）。

## 9. v1.5 补漏：分享资源获取出口 gate（2026-10-02 用户实测反馈）

用户实测：本地用户可以完整走通「分享列表 → 获取资源 → 打开链接」拿到分享资源，
违反 §2.4 权限矩阵（获取 ❌）。全量审计后定位唯一漏洞并修复：

| 入口 | 位置 | 修复前 | 修复后 |
|---|---|---|---|
| 🔴 分享「打开链接」（资源获取实际出口） | `game_detail_page.dart` `_openResourceLink` | **无 gate**——分享列表「获取资源」按钮两条路径（进详情开链 / fallback 直接开链）的唯一汇聚点，本地用户全通 | 加 `PBConfig.isLoggedIn` gate + 统一文案「该功能需要登录账号后使用」 |
| ⚠️ 文案不一致 | `docs_publish_tab.dart` `_handleNext` | 「请先在左侧边栏登录账号，再发布作品」（§2.5-7 统一文案的遗漏处） | 统一为「该功能需要登录账号后使用」 |

审计确认**既有 gate 全部正常**（本地用户均被拦）：详情页「获取」`:1006`、
「上传」`:1096`、「报告失效」`:1153`、顶栏「发布/上传」选择器
（`upload_publish_dialog.dart:40`）、文档板块「发布」`docs_publish_tab.dart:70`、
「我的」`docs_my_tab.dart:100`、服务层兜底（publish/resource service 抛「请先登录」）。

**设计不变式**：分享列表/详情**浏览**仍对本地用户开放（§2.4 矩阵 ✅ 匿名只读）；
「喜欢」按钮维持本地标记语义（`:1139` 文案已注明「暂未同步云端」）。
gate 判定复用 `PBConfig.isLoggedIn`（本地用户与未登录在 authStore 层面等价），
零稳定区改动、无新状态传递。

**验证**：进程内 analyzer 2 文件 errors=0（game_detail_page 5 warning 为存量，
stash 对照确认）；旧文案全库 grep 零残留。**未验证**：真机走查（本地态登录前/
后分别点「获取资源」→「打开链接」应被拦并提示）。

## 10. 线上补漏：系列数据匿名只读开放（2026-10-03 用户实测反馈）

用户反馈本地用户读不到「系列」数据。根因：`series` / `series_entries`
`listRule = '@request.auth.id != ""'`——本地态无 token，list 被规则过滤为
**空集**（200 + items=0），静默无系列。§2.4 矩阵「系列 ✅ 匿名只读」与线上
实际不符（建表时遗漏）。

**线上 PATCH**（探针 `pb_tmp/probe_series_fix.py`）：
- 两表 `listRule` → `''`（匿名只读；登录用户不受影响）；
- 🔴 两表 create/update/deleteRule 原为 `''`（=**公开可写**，任何人可篡改
  全部系列数据）→ 收紧 `None`（仅 superuser）。客户端系列仅 4 处只读调用
  （`series_repository.dart:39,110,123,171`），零功能损失。

**验证**：匿名 list series 200/43 条、series_entries 200/173 条、
expand=game,series 正常、客户端同款 filter 流程 200、匿名写全 403。
