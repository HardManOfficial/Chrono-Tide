# 设置 · 元数据板块（GLOBAL-METADATA）

> 状态：**代码已完成（2026-11-13 三版：账号区改为 OAuth 一键登录），待真机走查**
> 入口：设置 → 「元数据」（第 8 个 tab，图标 `assets/images/discover_icon.svg`）
> 相关代码：
> - 页面：`lib/widgets/settings/metadata/`（6 个文件，见 §6）
> - 服务：`metadata_field_priority.dart`、`metadata_credentials.dart`、
>   `metadata_refresh_core.dart`（纯 Dart）、`metadata_refresh_service.dart`、
>   `metadata_login_service.dart`、`oauth/`（5 个文件，见 §6）
> - 数据层接入：`metadata_fetcher.dart`、SDK 的 `kun_cookie.dart` + `kun_service.dart`、
>   `two_dfan_cookie.dart` + `two_dfan_service.dart`、
>   `hikarinagi_service.dart` / `nextmoe_service.dart`（可选 `userToken`）
> 决策：ADR-023（字段优先级 / 批量口径）、ADR-024（四平台登录态 + 鲲 Cookie 透传）、
>   ADR-025（OAuth 快捷登录 + 复用公共客户端 + 端口约束）
> 探针：`oauth_pkce_probe.dart`（49）、`oauth_loopback_probe.dart`（22，均裸 VM）、
>   `metadata_refresh_core_probe.dart`（30，裸 VM）、
>   `settings_modal_metadata_probe.dart`（63，整屏渲染）
> 参考：`D:\CTLIB\ref\third-party\ReinaManager-main`（账号页结构 + OAuth 参数）、
> `D:\CTLIB\ref\third-party\LunaBox-main`（来源网格视觉 + 鲲走 v2 的证据）

---

## 1. 需求来源

用户原话（2026-11-13，节选）：

> 我们应该要做好跟这个相似的功能，把这个账号功能给它做好……在我们原先的设置页中
> 新增一个板块叫做「元数据」……四大平台，第一是 Bangumi，第二个是 Hikarinagi，
> 第三个是 KunGal，第四个是 2DFan 的授权。

> 这个截图数据第一优先级到底是 VNDB 更好呢，还是 KunGal 更好呢……这些都交给用户
> 自行决定，我们仅做初始推荐。

> LunaBox 这里有一个批评空间网址。因为我们把私密空间给移除掉了，所以这个功能也就不需要。

> 我们要严格的、尽可能的贴合着我们软件的去设计来走。（≠ 一对一模仿）

二版补充（同日）：

> 这个账号凭证功能的设计应该与 ReinaManager / LunaBox 的账号凭证授权一致，
> 是用于让用户**登入站点**来实现更好的元数据服务的。需登入凭证的平台有
> kungal（与 NextMoe 本质是一个站点）、Hikarinagi、Bangumi、2DFan，
> 其他平台就暂时不做账号凭证。……NEXTMOE 与鲲 galgame 合并可以用「鲲GAL/NextMoe」
> 表示，而 CT 探索库的图标直接使用我们软件的图标。

## 2. 四个分组

| # | 分组 | 作用 | 落点 |
|---|---|---|---|
| 1 | 平台账号与凭证 | 抓取时的**身份**（额度 / 登录态可见内容） | `MetadataCredentialService` + `KunCookieStore` + `TwoDFanCookieStore` |
| 2 | 元数据拉取来源 | 用哪些平台；MIX 整合范围 | `MetadataFetcher.setEnabledSources` |
| 3 | 字段优先级 | 每个字段先看哪家 | `MetadataFieldPriority` → `MetadataFetcher` |
| 4 | 全量更新元数据 | 把上面三块的设置应用到整个库 | `MetadataRefreshService` |

### 2.1 实测结论（真发请求验证，不是推测）

| 站点 | 结论 | 证据 |
|---|---|---|
| **Hikarinagi** | **不需要用户登录** | `POST https://id.hikarinagi.org/oidc/token`（Basic = 内置 `hkn_*`:`hks_*`，`grant_type=client_credentials&scope=catalog:read`）→ 200 + access_token（`open_throttle_limit=600`）；带该 token 搜「缘之空」→ 正确返回 `id=563` |
| 同上（网络） | 直连被 reset，走代理即通 | 无代理 `curl: (35) Recv failure: Connection was reset`；`-x 127.0.0.1:7892` 后 200 |
| **鲲 kungal.com** | **需要登录**，匿名一条都拿不到 | `GET /api/search?q=test` → `{"code":205,"message":"用户登录失效"}`（HTTP **200**）；`GET /api/galgame/1` → 401；整站 `/api/**` 共用一道门禁 |
| **NextMoe** | 免登录可读 | `GET https://api.nextmoe.dev/v2/catalog/search?object=work&q=test&nsfw=true` 不带 Authorization 也返 200 + items |
| **2DFan** | 免登录可抓公开条目，登录后读得到账号内内容 | 站点 301 到镜像；Cookie 只提高命中率 |

🔴 关键推论：用户先前判断「Hikarinagi 需要登录、以前以为是代理问题」，实际方向是反的 ——
真正「必须登录否则完全不可用」的是**鲲的旧接口**；Hikarinagi 是**网络**问题（需要代理），
凭据一直是够的。

### 2.1.1 OAuth 可行性实测（第二轮，2026-11-13）

| 检查项 | 结果 |
|---|---|
| NextMoe 发现文档 | `GET https://account.nextmoe.com/.well-known/openid-configuration` → 200，`grant_types_supported=[authorization_code, refresh_token]`，**`token_endpoint_auth_methods_supported` 含 `none`**（PKCE 公共客户端，无 secret） |
| Hikarinagi 发现文档 | `GET https://id.hikarinagi.org/oidc/.well-known/openid-configuration` → 200（注意：根路径 `/.well-known/...` 返回的是 SPA 的 HTML，不是 JSON） |
| 是否支持动态注册 | **不支持**（两家都没有 `registration_endpoint`；`id.hikarinagi.org/oidc/register` → 404） |
| 回调地址是否严格白名单 | **是**。同一 client 换成 `127.0.0.1:39001/callback` → NextMoe `{"code":15002,"message":"无效的回调地址"}`（400）；Hikarinagi 400「oops! something went wrong」 |
| 原配回调是否可用 | **可用**。NextMoe `127.0.0.1:23380/callback/nextmoe` → 303；Hikarinagi `127.0.0.1:23380/callback/hikarinagi` → 303 到 `/interaction/…`（Ory 授权流） |
| 鲲元数据实际来自哪 | **`api.nextmoe.dev/v2`**（LunaBox `metadata_kungal.go` 的 `kungalAPIBaseURL` 就是它）。`www.kungal.com/api` 是老论坛接口 |
| 鲲旧接口能否用 Bearer 救 | **不能**。匿名与带 `Authorization: Bearer <任意值>` 都回 `{"code":205}`，站点用的是 Cookie 会话 |
| NextMoe 带假 Bearer | `401 {"title":"Invalid credential"}` ⇒ 只在**确实有令牌**时才加这个头，否则把能用的请求也弄坏 |

结论：**真 OAuth 可以做**，代价是必须复用已注册的公共客户端（`client_id` + 固定回调端口）。
ReinaManager 的注册值（PKCE 公共客户端、无 secret）：
`nextmoe → 741bebbd…@127.0.0.1:23380/callback/nextmoe`、
`hikarinagi → hkn_hVbw2qChqzo2avRl@127.0.0.1:23380/callback/hikarinagi`。
两者都在 `lib/services/oauth/oauth_providers.dart` 里，且**只在那里**。

⚠️ 这留下两个必须知道的约束：
1. **端口 23380 是共享的**。ReinaManager 常驻监听它（实测本机 `netstat` 命中
   `ReinaManager.exe`），两家同开时我们绑不上 —— 已做成明确提示「关闭它后再点登录」；
2. 授权页显示的应用名是注册方（ReinaManager）。要彻底干净，需要我们自己到
   `developer.nextmoe.dev/dashboard` 注册「Chrono Tide」应用（有 `ClientId` /
   `RedirectUri` 字段），拿到后**改 `oauth_providers.dart` 的 3 行即可**，代码无需其他改动。

鲲的旧登录形态（保留说明，避免下次又去翻）：NextMoe 账户中心 OAuth 授权码，
回调写死 `https://www.kungal.com/auth/callback`，第三方拿不到 ⇒
对 `www.kungal.com/api/**` 一期仍只能**透传用户浏览器 Cookie**
（站点自身用 Cookie 维持会话，`maxAge: 604800`）。

### 2.2 凭证模型的五种形态

| 形态 | 站点 | UI |
|---|---|---|
| `oauth` | 鲲GAL/NextMoe、Hikarinagi | 「使用 X 账号登录」→ 浏览器授权 → 自动回来；已登录显示昵称 + 有效期 + 「退出登录」 |
| `personalToken` | Bangumi | 单行令牌 + 「保存并验证」（真发 `GET /v0/me`）+「获取令牌 ↗」+ 显示/隐藏 |
| `cookie` | 鲲GAL/NextMoe（后备）、2DFan | 两行 Cookie + 「保存并验证」/「保存」+「清除」；鲲的入口折叠在「登录不成功？改用 Cookie 手动登录」下 |
| `builtIn` | Hikarinagi（后备） | 无输入框，只给「测试连通性」（真跑取令牌 + 搜索，分开报错） |
| `none` | VNDB / CT 探索库 / Steam / 月幕 GAL | 不建卡，页面底部一句「其余平台走公开接口」 |

状态胶囊：`未登录`（灰）/ `已保存`（琥珀，本次打开未校验）/ `已登录`（绿，OAuth 令牌或刚校验通过）/
`内置凭据`（绿）。凭据只写 `SharedPreferences`，不上传、不打印、不进云备份。

🔴 所有「验证」都**真的发请求**，必须区分「凭据无效（401/403、code 205）」与
「连不上（超时 / reset）」——把后者说成凭据错会让人白折腾，反过来更糟。

**Bangumi 为什么没有一键登录**：它的 OAuth 是 confidential client，换令牌必须带
`client_secret`（ReinaManager 的 `BGM_APP_SECRET` 在构建时注入，仓库里没有值）。
第三方软件把这个密钥硬编进发行包等于公开泄漏，所以用官方**个人访问令牌（PAT）**替代，
能力等价（ReinaManager 也把「Access Token 登录」列为并列选项）。卡片上写明这一点，
免得用户以为我们少做了一个按钮。

### 2.3 字段优先级（7 项 × 平台组）

`cover_url` / `screenshot_urls` / `rating` / `summary` / `tags` / `developer` / `game_name`

- 下拉项是**平台组**（8 个），不是 `SourceType`：选「鲲GAL/NextMoe」时 `nextmoe` + `kun`
  一起提到链首且保持组内顺序（`MetadataFieldPriority.resolveChain` 接受 `List<SourceType>`）；
- 下拉里**没有「只从这家取」**；链 = `[覆盖项] + 内置链（去掉重复）`；
- 每行回显「当前顺序：A → B → C …」，展示名按平台组去重（`metadataChainTitleText`）；
- 落盘键 `metadata_field_priority`，值为 `{"cover_url":["vndb"]}`；**兼容旧单值**
  `{"cover_url":"vndb"}`；改完 `clearCache()` 立即生效。

### 2.4 全量更新（语义必须写清，见 ADR-023）

| 项 | 规则 |
|---|---|
| 默认口径 | **只补空字段**（`overwrite=false`） |
| 覆盖 | 需勾选 + `AlertDialog` 二次确认 |
| 写哪些字段 | `description` / `developer` / `release_date` / `metadata_source` / `metadata_source_id` / `rating` / `rating_count` / `estimated_minutes` / `tags` / `company_id`（10 个，白名单恒定） |
| 绝不写 | `title` / `original_title` / `subtitle` / `cover_file` / `screenshot_urls` / `screenshot_files` |
| 空值 | 空串 / 空表 / 0 一律视为「无数据」，**不会用空值冲掉已有值** |
| 标签 | 集合语义：只换顺序不算变化（否则每次刷新都写盘） |
| 无字段可写 | **不写盘**（不刷 `updated_at`） |
| 写盘 | 唯一出口 `GameDataFormat.updateGameJsonAtomic` |
| 节奏 | 串行 + 400ms 间隔 + 可取消 + 失败项单独重试 |

### 2.5 OAuth 快捷登录（授权码 + PKCE）

```
点「使用 X 账号登录」
  → 绑定 127.0.0.1:23380（占用则直接给「关掉 ReinaManager」的提示）
  → 生成 verifier / state，拼授权地址，开系统浏览器
  → 用户在站点登录并同意
  → 站点 302 回 http://127.0.0.1:23380/callback/<name>?code=…&state=…
  → 本地页显示「登录成功，可以关闭此页面」并立刻关监听
  → 回传 code + state 校验（不符即拒绝）
  → POST token 端点（grant_type=authorization_code + code_verifier）换令牌
  → GET userinfo 取昵称 → 落盘 → 卡片变成「已登录：汐」
```

| 环节 | 关键决定 | 理由 |
|---|---|---|
| 令牌存储 | `oauth_token_v1_<provider>`，JSON `{access_token, refresh_token, expires_at, scope, account_name}` | 只存本机；`access_token` 才算「已登录」 |
| 提前刷新 | 剩 ≤60s 就刷新（`needsRefresh`） | 站点签发 1 小时，留 1 分钟余量避免边界 401 |
| refresh 轮换 | 刷新后**原地覆盖**；站点没返回新的就保留旧的 | 轮换型 refresh token 不覆盖 = 下次刷新必失败 |
| 抓取层接入 | Hikarinagi 用户令牌优先；NextMoe 用 **Dio 拦截器**按请求注入 | 构造时写死 header 会在刷新/退出后继续发旧令牌 |
| 过期兜底 | `cachedAccessToken()` 对「将过期」返回 null → 回退内置凭据/应用密钥 | 抓取层是同步的，不能为刷新把整链变异步 |
| 代理 | 换令牌 / userinfo 都走 `NetworkProxyPolicy` | Hikarinagi 直连被 reset，登录同样需要代理 |
| 超时 | 5 分钟（与 ReinaManager 一致） | 用户可能还要注册/找回密码，太短会白等 |

登录后的**实际收益**（别夸大）：请求改用用户自己的额度（不再挤全软件共享的
`client_credentials` / `nmk_live_*` 应用密钥），并为后续「收藏 / 状态同步」留好入口。
元数据本身**不依赖登录**——这一点在卡片说明里如实写了。

## 3. 为什么不做「收藏 / 游玩状态同步」

两个参考项目都有这块（Bangumi 收藏状态双向同步）。本项目**没有云端状态模型**：
收藏夹是本地 `collection_ids`，`play_status` 只在 game.json 里。做出来只会是一排永远灰着
的开关，或者一条会覆盖本地进度的单向同步。探针里有负向断言（A11）钉死这一点。

## 4. 鲲 + NextMoe 为什么合并成一张卡

用户视角上它们是**一个站**（鲲的 Galgame 资料库就是 NextMoe 生态的论坛端）。拆成两张卡会出现
「关掉鲲但 NextMoe 还在偷偷用」的老问题。实现上：

- `MetadataSiteInfo.sources` 是 `List<SourceType>`（多数平台长度为 1）；
- 来源卡的开关一次增删整组；`_onGroupCount` 按**组**统计，保证「至少保留一个来源」；
- 账号卡、优先级下拉同样按组显示；
- 抓取层不变：`SourceType` 仍是独立条目（`_enabledSources` / `_mixSources` 都按单源）。

## 5. 与参考项目的差异

| 参考项目 | 我们 | 原因 |
|---|---|---|
| ReinaManager / LunaBox 的 OAuth 快捷登录 | **已对齐**（PKCE + 本地回调），复用其注册的公共客户端 | 两家都不支持动态注册；自有注册见 §10 |
| Bangumi 也是 OAuth | 用 PAT | Bangumi OAuth 需 `client_secret`，硬编进发行包即泄漏 |
| LunaBox 有「批评空间网址」输入 | 不做 | 我们的批评空间功能已移除，留着是死输入 |
| LunaBox 来源卡 3 列 | 2 列 | 最小窗 820px 下 3 列的简介会挤成两行截断 |
| LunaBox 批量更新直接覆盖 | 默认只补空 | 覆盖是不可逆的；我们给二次确认 |
| 两家的「同步收藏/游玩状态」 | 不做 | 本项目没有云端状态模型（见 §3） |
| LunaBox 账户区是横向小卡 | 整行大卡 | 我们的设置内容区仅 ~530px 宽，横排塞不下令牌输入框 |

## 6. 文件清单

| 文件 | 职责 |
|---|---|
| `metadata_site_catalog.dart` | 8 个平台组的唯一事实源（`sources` 列表 / 名称 / 简介 / 登录说明 / 凭证形态 / 主色 / 图标）+ `MetadataSiteLogo` + `metadataChainTitleText` |
| `metadata_accounts_card.dart` | 分组 1：四张账号卡（Bangumi / 鲲GAL/NextMoe / Hikarinagi / 2DFan）+ 其余平台一句说明 |
| `metadata_sources_card.dart` | 分组 2：MIX 卡 + 2 列平台卡（按组开关） |
| `metadata_priority_card.dart` | 分组 3：7 行字段优先级下拉（按组）+ 当前链回显 |
| `metadata_refresh_card.dart` | 分组 4：覆盖开关 / 主按钮 / 进度条 / 失败清单 |
| `metadata_settings_page.dart` | 四个 `SettingsSection` 挂载（仅此职责） |
| `metadata_refresh_core.dart` | **纯 Dart**：空值归一 + `computeRefreshUpdates` |
| `metadata_refresh_service.dart` | 单例 `ChangeNotifier`：遍历 / 进度 / 取消 / 重试 |
| SDK `kun_cookie.dart` | 鲲登录 Cookie 持久化 + 进程内缓存（`kun_galgame_cookie`） |
| SDK `kun_service.dart` | 每次请求注入 `Cookie`；识别 `code 205` 并在 `fetchLog` 里明说「需要登录」 |
| `oauth/oauth_pkce.dart` | **纯 Dart**：verifier / challenge / state / 授权地址构造 |
| `oauth/oauth_providers.dart` | 两家参数**唯一事实源**（client_id、回调端口与路径、端点、scope） |
| `oauth/oauth_loopback.dart` | 本地回调服务器（按路径分发、超时、取消、端口占用识别、结果页） |
| `oauth/oauth_token.dart` | **纯 Dart**：令牌模型、过期判定、token 响应解析、userinfo 昵称取值 |
| `oauth/oauth_token_store.dart` | 令牌持久化（`oauth_token_v1_<provider>`）+ 内存副本供同步读取 |
| `metadata_login_service.dart` | 登录编排（绑端口 → 开浏览器 → 等回调 → 换令牌 → 拉昵称）+ 刷新 + 退出 |
| SDK `hikarinagi_service.dart` | 新增可选 `userToken`：有用户令牌优先，没有回退 `client_credentials` |
| SDK `nextmoe_service.dart` | 新增可选 `userToken`：Dio **拦截器** 按请求覆盖 `Authorization` |

## 7. 坑（改之前先读）

1. 🔴 **侧栏 8 项在最小窗口会溢出**。`_kMinHeight=520` 时可用高 448px，8×40 + 7×8 = 376
   本来够，但加分组间距/边框后实测溢出 41px。已改成「tab 区 `Expanded` +
   `SingleChildScrollView`，返回按钮固定底部」；大窗视觉与旧版完全一致。
2. 🔴 **`TextField` 的 `obscureText` 与 `maxLines>1` 互斥**：Cookie 是多行框，
   必须 `obscureText: obscure && lines == 1`，否则 `!obscureText || maxLines == 1` 断言崩。
3. 🔴 **平台卡上的开关不能再包 `InteractiveWrapper`**：会与 `Switch.onChanged` 双重触发，
   表现是「点一下没反应」。只让 Switch 自己响应。
4. 🔴 **`MetadataCredentialKind` 必须放在 service 层**：放到 widget 文件里，
   `metadata_credentials.dart` 反向 import 会转成循环依赖。
5. 🔴 **鲲的「未登录」是 HTTP 200**：判据只能看 body 的 `code == 205`。只看状态码会把
   「登录失效」显示成「连接正常」（`KunService.testConnection` 也因此要看 code）。
6. 🔴 **探针里不能直接数文案出现次数**：`Text` 会构出 `RichText` 子节点，收集器把两者各记
   一次（翻倍）；`DropdownButton` 又用 `IndexedStack` 把**所有 items** 建在树里（只是不绘制）。
   要计数就用只认 `Text` 的 `countText()`。
7. 🔴 **空态判据**：批量刷新在库里没有游戏时必须**立即**进入 finished（`total=0`）。
8. 🔴 `metadata_site_catalog.dart` 的 SVG **不要加 `BlendMode.srcIn` 染色**：官方图标是多色的。
9. 🔴 全量刷新的 `useCache` 必须 **false**：命中旧缓存会让「改了优先级/换了代理」看起来毫无变化。
10. 🔴 **鲲 Cookie 只透传不改写**：`KunCookieStore` 里存什么就发什么，不解析、不拼接；
    这样站点换 Cookie 名也不用改代码。
11. 🔴🔴 **回调服务器必须「先写响应，再 complete，再 close」**。顺序反了，
    `waitFor` 的 `finally` 会立刻 `close(force: true)`，把还在飞的回调页掐断，
    浏览器显示连接重置 —— 用户看到的是「登录失败」，其实是我们的时序 bug。
    探针 `oauth_loopback_probe` A7 就是钉这个（断言响应体完整到 `</html>`）。
12. 🔴🔴 **回调端口 23380 与 client_id 绑定，且会被 ReinaManager 占住**（实测本机常驻）。
    不要「顺手换个端口试试」——NextMoe 直接 `15002 无效的回调地址`。
    绑不上要给「关掉 ReinaManager」的具体提示。
13. 🔴 **refresh_token 会轮换**：刷新成功但没覆盖保存 → 下一次刷新必失败。
    `copyWith(refreshToken: null)` 是**保留旧值**（探针 E6 钉死），别写成清空。
14. 🔴 **令牌不能写死在 Dio 构造里**：运行期会刷新/退出，NextMoe 因此改用拦截器。
15. 🔴 **nextmoe 只在有令牌时才加 `Authorization`**：带假 token 会 401，
    比「用应用密钥正常返回」更糟。
16. 🔴 写探针读回调页时要用 `utf8.decoder`：`SystemEncoding` 在中文 Windows 上按 GBK 解，
    中文全乱码，会误判成「页面没渲染」。
17. 🔴🔴 **打开浏览器 ⛔ 不能用 `cmd /c start "" <url>`**（2026-11-13 真机翻车）：
    `cmd` 把 `&` 当命令分隔符，`…?response_type=code&client_id=…&redirect_uri=…&state=…`
    到浏览器只剩**第一个参数**。两家站点的报错都极具误导性——
    NextMoe 回 JSON `ClientID / RedirectURI / State failed on the 'required' tag`，
    Hikarinagi 回 `login is not supported`，看着都像「站点不支持我们这种方式登录」。
    现在统一走 `core/external_url_launcher.dart`：`ShellExecuteW`（CreateProcess 直拉，
    不经任何 shell）为主，`rundll32 url.dll,FileProtocolHandler` 兜底。
    `dev_probe/external_url_launcher_probe.dart` 真开一次浏览器打到本地回环，
    断言**浏览器实际收到的参数个数 = 7**，少一个即回归。
    另：`metadata_login_service` 会把授权地址 `debugPrint` 出来，排查先看那行。
18. 🔴🔴 **授权页的应用名＝client_id 在站点注册时填的名字**，本地改不了、也没有
    `client_name` 参数可覆盖。当前两个 client_id 都是 ReinaManager 的，所以用户会看到
    「ReinaManager 请求访问你的账户」——**这不是 bug，但必须换成自家应用**（§11）。
    换成自家应用后回调端口还能设 `0`（NextMoe 环回回调**端口无关匹配**，RFC 8252 §7.3），
    顺带解决「23380 被 ReinaManager 常驻占用」。

## 8. 验证

| 探针 | 断言 | 结果 |
|---|---|---|
| `oauth_pkce_probe.dart`（裸 VM） | 49 | ✅ 全绿 |
| `oauth_loopback_probe.dart`（裸 VM，真起真停） | 29 | ✅ 全绿 |
| `metadata_refresh_core_probe.dart`（裸 VM） | 30 | ✅ 全绿 |
| `settings_modal_metadata_probe.dart`（flutter_tester 整屏） | 63 | ✅ 全绿 |
| `settings_modal_proxy_probe.dart`（回归） | 26 | ✅ 全绿 |
| `external_url_launcher_probe.dart`（裸 VM，真开一次浏览器） | 15 | ✅ 全绿 |

整屏探针覆盖：1280×720 / 820×520 最小窗 / 「关于应用」往返切换 / 运行中态 / 完成态 + 失败清单 /
**已登录态**（预置令牌 → 胶囊变绿、显示昵称、出现「退出登录」）；E 段为纯函数判据
（`resolveChain` 六种组合、`interpretKunProbe` 五种响应、Cookie 形态）；A5c 实测
「点『改用 Cookie 手动登录』才展开输入框」。

`oauth_pkce_probe` 含 **RFC 7636 附录 B 官方向量**（verifier→challenge），
S256 实现被改错时这里必红；`oauth_loopback_probe` 覆盖 favicon 不抢单、取消、超时、
端口占用、连续开关不泄漏端口、响应体完整。

## 9. ⏳ 真机待走查

1. **OAuth 一键登录（头号项）**：关掉 ReinaManager → 设置 → 元数据 → 「使用
   NextMoe 账号登录」→ 应弹出系统浏览器授权页 → 同意后浏览器显示「登录成功」→
   回到软件卡片变成「已登录：<昵称>」，胶囊变绿；
2. 同上，测 **Hikarinagi**；如果浏览器里显示「拒绝」，卡片应显示「你在授权页点了拒绝」；
3. **端口占用**：先开着 ReinaManager 再点登录 → 应显示「端口 23380 被占用…请关闭它」，
   而不是笼统的失败；
4. **登录后抓取**：登录 Hikarinagi 后抓任意作品，日志里 `[Hikarinagi]` 请求应带你的令牌
   （额度是自己的）；退出登录后再抓，应自动回退内置凭据且不报错；
5. **令牌过期**：等 1 小时（或改系统时间）后再抓，`cachedAccessToken()` 返回 null 应回退，
   不出现 401 反复重试；
6. Bangumi PAT 校验在**开/关代理**两种网络下的提示是否准确（401 与超时不能混）；
7. **鲲**：浏览器登录 kungal.com → 复制整行 Cookie → 「登录不成功？改用 Cookie 手动登录」
   →「保存并验证」应显示有效，然后抓任意作品 `[KunGal]` 不再报「需要登录」；
8. 2DFan Cookie 填了之后检索结果是否真的变多；
9. 字段优先级选「鲲GAL/NextMoe」后，进任意游戏触发抓取，详情页评分/截图是否换源；
10. 全量刷新跑 20 条：进度条是否平滑、取消是否及时停、失败重试是否只跑失败项；
11. 覆盖口径跑一条：先手改简介 → 不勾覆盖 → 简介不变；勾覆盖 → 简介被替换；
12. 最小窗 820×520 下侧栏能滚到第 8 项、返回按钮始终可见。

## 10. 后续（需单独批准）

- ⏸ **注册自家 OAuth 应用（已挂起，2026-11-13 用户裁决「登录暂时先不做」，见 §12）**：
  现在两家用的都是 ReinaManager 注册的 client_id，所以授权页写的是
  「ReinaManager 请求访问你的账户」。换成自家应用后：授权页显示「Chrono Tide」、
  回调端口可以随机（不再和 ReinaManager 抢 23380）。代码已就绪（§11），
  等恢复登录时再做。
- **2DFan 积分下载**：用户希望「登录后在补丁站直接用自己账号的积分下载」。这涉及真实扣积分
  （不可逆消费），需要先确认 2DFan 附件的请求形态与费用提示，必须单独出方案再动手；
  当前账号卡的话术已如实写成「补丁资源仍走原站，本软件不代扣积分」。
- **鲲元数据迁移到 v2**：`KunService` 现在打的是 `www.kungal.com/api`（老接口 + 登录门禁），
  而 `api.nextmoe.dev/v2` 才是同一份数据的现代入口（补丁站已经在用 v2）。
  迁移后「鲲」与「NextMoe」会真正同源，届时可评估是否直接合并为一个 `SourceType`
  （会让 MIX 少跑一轮、少一套重复字段），但这属于数据层重构，需单独批准。

## 11. 换成我们自己的 OAuth 应用（消除「别的软件在登录」）

**现象**：点「使用 NextMoe 账号登录」，授权页写的是
「**ReinaManager** 请求访问你的账户」。Hikarinagi 同理。

**原因**：OAuth 授权页展示的应用名＝ **client_id 在站点注册时填的名字**，本地无法覆盖
（没有 `client_name` 参数可用，站点也不支持动态注册）。当前两个 client_id 来自
ReinaManager 的注册——当初判断「不能注册」时的妥协。功能上无害（`code` 只回给
`127.0.0.1` 上我们自己的监听；端口被我们独占时 ReinaManager 起不来），但名义上确实是别人的应用。

### NextMoe（可自助，无需联系管理员）

1. 打开 `https://developer.nextmoe.dev/dashboard`，登录 → 新建应用，名字填 **Chrono Tide**。
2. 进应用详情页的「**用户登录**」卡片（配置键 `user_login`），填：
   - `redirect_uris`: `["http://127.0.0.1/callback"]`
     🔴 **只收环回**：`http://127.0.0.1/...` 或 `http://[::1]/...`；
     `localhost` 按名拒（能被 hosts 指到别处）、自定义 scheme 也拒。
   - `scopes`: `["openid","profile","catalog:read"]`（将来做收藏夹同步再加
     `folder:read` / `folder:write`）。
3. 复制应用详情页给的 **client_id**，改 `lib/services/oauth/oauth_providers.dart` 里
   `kOAuthNextMoe` 的三个值：
   ```dart
   clientId: '<新的 client_id>',
   callbackPort: 0,                 // 0 = 内核随机分配，端口无关匹配
   callbackPath: '/callback',       // 必须与注册的 path 一致
   ```
   ⛔ 别再写死 23380 —— 那是 ReinaManager 的端口。
4. 构建后点登录：授权页应显示「Chrono Tide」，且不再需要关掉 ReinaManager。

官方文档：`https://developer.nextmoe.dev/docs/native-app`（专门写给 Tauri/Wails
这类桌面客户端的，我们这套 PKCE + 环回回调与它逐条对齐）。

### Hikarinagi

入口 `https://id.hikarinagi.org/developer/apps`（需先登录账号）。
⚠️ 它没有 `registration_endpoint`（`/oidc/register` 实测 404），不能程序化注册；
如果该页面不提供自助建应用，只能找站长申请，届时把 client_id 填进
`kOAuthHikarinagi` 同样三行。

### 关键约束（都来自站点文档或实测）

- 🔴 **端口无关匹配**（RFC 8252 §7.3）：注册时写不写端口都行，服务端比对环回回调
  **忽略端口**，所以 `callbackPort: 0` 可用。但复用别人注册的 client 时仍必须用它的端口
  （实测报 `15002 无效的回调地址`）。
- 🔴 **`redirect_uri` 换码时必须与授权那一步逐字节相同**，否则 `invalid_grant`。
  代码已改成用**实际监听端口**算一次、一路传下去（`redirectUriFor(actualPort)`），
  探针 F 段钉这条。
- 🔴 **别多要 scope**：请求应用侧没注册的 scope，授权时直接 `15006`。
  `catalog:read` 例外——文档明说它每个应用无需注册即可请求。
  所以 NextMoe 现在是 `openid profile catalog:read`，`folder:*` 等做同步时再要。
- 🔴 配额按**用户**计（同一用户授权多个管理器共享一个桶），不按应用——
  这也意味着「多注册几个应用」绕不开额度，别往那个方向设计。

## 12. 2026-11-13 裁决：快捷登录暂时关闭（只做基础凭证）

**用户原话**：「像这种凭证啊登录啊快捷登录啥的，我们就暂时先不做，你先把所有入口
都给它关闭吧……就做基础凭证 Token 写入或者是 API 写入之类的就行。」

### 关闭范围（`kOAuthQuickLoginEnabled = false`，唯一开关）

`lib/services/oauth/oauth_providers.dart` 里的 `const bool kOAuthQuickLoginEnabled`，
UI 与 service 两处都只看它：

| 位置 | 关闭后的行为 |
|---|---|
| 鲲GAL/NextMoe 卡 | 不出现「使用 NextMoe 账号登录」；Cookie 输入**直接展开**（不再藏在折叠链接后），并给一句「快捷登录暂未开放：请粘贴登录 kungal.com 后的 Cookie」 |
| Hikarinagi 卡 | 不出现「使用 Hikarinagi 账号登录」；保留「测试连通性」+ 一句「本平台凭据已内置，不登录也能正常抓取」 |
| `MetadataLoginService.login()` | 直接返回 false（防别的调用方绕过 UI） |
| 已存在的令牌 | **照常用于抓取**；卡片仍显示「已登录：昵称 · 令牌只存在本机」+「退出登录」——否则令牌永远删不掉 |

保留的基础凭证通道（本来就是手填，不受影响）：Bangumi 个人令牌（PAT）、
鲲 Cookie、2DFan Cookie、Hikarinagi 内置凭据。

### 恢复登录时要做的事

1. `kOAuthQuickLoginEnabled` 改 `true`（一处）。
2. 按 §11 注册自家应用（否则授权页还是写「ReinaManager」），改 client_id 等 3 个值。
3. 整屏探针 `settings_modal_metadata_probe` 的 A5/A5c/A5d/A6/F4 断言要改回
   「有一键登录 + Cookie 折叠」的形态（现在钉的是「关得干净」）。

### 为什么这么关，而不是删代码

登录链路（PKCE / 回环回调 / 令牌刷新轮换 / 换自家应用的能力）都验证过且全绿，
删掉等于把 190+ 条断言的知识扔掉；将来要恢复，改一个 bool 就能回来。
