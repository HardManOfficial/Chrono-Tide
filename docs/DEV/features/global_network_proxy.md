# 全局网络代理策略（GLOBAL-PROXY）

> 状态：**代码已完成（2026-11-13），待真机走查**
> 相关代码：`lib/services/network_proxy_core.dart`（纯 Dart）、`lib/services/network_proxy_policy.dart`（唯一事实源）、
> `lib/services/system_proxy_detector.dart`（只读系统代理，本次未改）
> 接入点：`metadata_fetcher.dart`、`company_logo_service.dart`、`game_title_logo_service.dart`、
> `game_op_video_service.dart` + `game_op_video_core.dart`、`settings_modal.dart`（网络与存储页）
> 决策：ADR-022
> 探针：`dev_probe/proxy_policy_core_probe.dart`（36 断言）、`dev_probe/settings_modal_proxy_probe.dart`（26 断言）

---

## 1. 用户报障（2026-11-13）

1. 「电脑上明明开着代理，软件里就是没法立刻用出来」——要重启软件才生效；
2. 「开了代理之后元数据抓取反而时好时坏，不开也不行」。

## 2. 改前架构与四个硬伤

改前每条链路各自实现同一套「app 配置代理 > Windows 系统代理 > 环境变量」三级解析：

```
metadata_fetcher._initDio()          :143-210   ← 启动时解析一次，写死进 onHttpClientCreate
company_logo_service._ensureDio()    :126-146   ← 同一套再写一遍
game_title_logo_service._ensureDio() :190-210   ← 再写一遍
game_op_video_service._resolveProxy()/core :468-480 / :889-896  ← 再写一遍
```

| # | 硬伤 | 后果 |
|---|---|---|
| P0 | 只在 `MetadataFetcher.init()` 里解析一次 | 运行期开关 Clash/V2Ray 完全无感，必须重启 |
| P0 | 手动 URL 一旦填过就永久压过系统代理 | 用户忘了自己填过 → 「系统代理死活不生效」 |
| P0 | `_validateProxy` 端口不通时**静默**退回直连，无任何提示 | 「开了代理反而时好时坏」 |
| P1 | `PROXY $proxyUrl` 直接拼未剥 scheme 的串（`PROXY http://127.0.0.1:7890`） | 不是合法 `findProxy` 语法，手动代理可能压根没生效 |
| P1 | 4 份重复实现，策略无法统一 | 改一处漏三处 |
| P1 | UI 只有输入框，没有策略选择、没有「当前生效什么」 | 用户无法判断到底走没走代理 |

## 3. 现在的分层

```
settings_modal.dart（三态下拉 + 状态行）
        │ apply(mode, url)
        ▼
NetworkProxyPolicy（唯一事实源，单例）
  ├─ load()                 启动：读偏好 → refresh → installGlobalOverrides
  ├─ apply()                设置页保存：写偏好 → refresh(force)
  ├─ refresh()              按模式解析出 _effectiveProxy（10s TTL）
  ├─ findProxyFor(Uri)      HttpClient.findProxy 回调（同步），按 TTL 触发后台刷新
  ├─ attachTo(Dio)          加请求前 await refresh() 的拦截器 + createHttpClient
  └─ installGlobalOverrides()  一次性 HttpOverrides，覆盖未显式设 findProxy 的 client
        │
        ▼
NetworkProxyCore（纯 Dart，可裸 VM 探针）
  NetworkProxyMode{system, manual, direct} · proxyModeFromPref · normalizeProxy
  parseProxyHostPort · findProxyString · proxyStatusText · shouldRefreshProxy
        │
        ▼
SystemProxyDetector.detectProxy({forceRefresh})   ← 只读注册表 ProxyEnable/ProxyServer
```

### 三态语义

| 模式 | `_effectiveProxy` | `findProxy` 输出 |
|---|---|---|
| `system`（默认） | 系统代理，且 TCP 存活验证通过；否则 null | 有值 `PROXY h:p`，无值回落 `findProxyFromEnvironment` |
| `manual` | 规范化后手动 URL（**不做存活验证**） | 有值 `PROXY h:p`，空则回落环境变量 |
| `direct` | null | **恒 `DIRECT`**（连环境变量都不用） |

## 4. 关键约束（改之前先读）

1. **存量迁移零行为突变**：`network_proxy_mode` 缺失时——`proxy_url` 有值 ⇒ `manual`；
   两者都空 ⇒ `system`。老用户升级后行为与升级前完全一致。
2. **测试环境必须跳过全局注入**：`installGlobalOverrides()` 见 `FLUTTER_TEST=true` 直接
   return，否则会覆盖 flutter binding 的 mock `HttpClient`，让 `test/` 里的
   `HttpOverrides` 用例（见 `network_reliability.md §4`）发出真实请求。
3. **显式 `DIRECT` 的调用方不能被覆盖**：`openlist_service.dart` 的本地 127.0.0.1
   请求自己设了 `findProxy = 'DIRECT'`，全局注入只影响「没设过」的 client ⇒ 有意保留。
4. **`attachTo` 用 dio 5 的新 API**：`IOHttpClientAdapter.createHttpClient`（`onHttpClientCreate`
   已废弃、6.0 移除），并显式 `idleTimeout = 3s` 与旧写法一致。
5. **`refresh()` 有单飞闸**：`_refreshing` 期间重复调用直接 return，避免并发请求把
   `reg query` 打成风暴；`_lastRefresh` 在开始时就写，失败也等满 TTL。
6. **`_defaultAliveCheck` 超时 2s**：死代理最坏给每个 TTL 周期加 2s 延迟，不会无限等。

## 5. 已知边界（不要对外承诺）

- 只读 Windows **静态系统代理**注册表（`HKCU\...\Internet Settings` 的 `ProxyEnable`/`ProxyServer`）；
- **PAC / 自动发现（WPAD）/ 纯 TUN 模式识别不了**——用户若用 TUN，系统代理注册表往往为空；
- `PROXY` 指令只支持 HTTP CONNECT 代理，`socks5://` 会被剥成 `host:port` 按 HTTP 代理处理，UI 不承诺 SOCKS；
- `MetadataFetcher.init()` **之前**就已创建的 `HttpClient`（启动顺序 `main.dart:568 runApp` →
  `:626 MetadataFetcher.init`）仍走环境变量默认行为，属于全局钩子的固有时间窗。

## 6. 真机验证清单

- [ ] 打开 Clash（系统代理模式）→ **不重启软件**，立刻抓一次元数据 → 应走代理成功
- [ ] 关闭 Clash → 10s 后再抓 → 应仍能用（回落直连），不应长时间卡住
- [ ] 设置页切「手动代理」填 `127.0.0.1:7890` → 保存 → 状态行显示「当前生效：手动代理 127.0.0.1:7890」
- [ ] 切「不使用代理（直连）」→ 保存 → 关掉代理软件也应能抓国内源（走直连）
- [ ] 「清除」→ 模式回到「自动跟随系统代理」，URL 框清空
- [ ] 手动模式下把 URL 填成不存在的端口 → 保存不报错（有意不验证存活），请求失败即可
- [ ] 缓存旧版本时填过手动 URL 的升级用户 → 首次进设置页应显示「手动代理」而不是「自动跟随」

## 7. 待办

| 优先级 | 事项 |
|---|---|
| 🟠 | `MetadataFetcher.currentProxy` getter（`metadata_fetcher.dart:1059`）现已无调用方，仅为兼容保留；确认无外部引用后可删 |
| 🟠 | 设置页状态行不是响应式刷新（只在 rebuild 时读 `statusText`），切完模式不点保存可能显示旧状态 | 
| ⚪ | 若未来支持 SOCKS5，需要在 `findProxy` 之外另开门路（Dart 的 `PROXY` 不支持 SOCKS） |
