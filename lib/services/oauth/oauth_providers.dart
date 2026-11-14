/// 支持「快捷登录」的两家平台参数（单一事实源）。
///
/// 🔴🔴 **授权页显示的「XXX 请求访问你的账户」＝ client_id 在站点注册时的
/// 应用名，本地改不了**。下面两个 client_id 都来自 ReinaManager 的注册
/// （早期判断「不能注册」时的妥协），所以登录时站点会说
/// 「ReinaManager 请求访问你的账户」。功能上无害（授权码只回给
/// `127.0.0.1` 上我们自己的监听，且端口被我们独占时 ReinaManager 也起不来），
/// 但**名义上是别人的应用** —— 要显示「Chrono Tide」，必须自己注册。
///
/// ## 怎么换成我们自己的（两家都自助，无需联系管理员）
/// NextMoe：`developer.nextmoe.dev/dashboard` 建应用 → 应用详情页
///   「用户登录」卡片（`user_login`）→ 填 `redirect_uris: ["http://127.0.0.1/callback"]`
///   + 勾 `openid` / `profile` / `catalog:read`（要收藏夹再加 `folder:read`/`folder:write`）。
///   文档：`developer.nextmoe.dev/docs/native-app`（专门写给桌面客户端的一节）。
/// Hikarinagi：`id.hikarinagi.org/developer/apps`（需先登录账号）。
/// 拿到自己的 client_id 后，改本文件对应 provider 的
/// `clientId` / `callbackPort` / `callbackPath` 三个值即可，别处不用动。
///
/// 🔴 **回调只收环回**：`http://127.0.0.1/...` 或 `http://[::1]/...`，
/// `localhost` 按名拒（能被 hosts 指到别处），自定义 scheme 也拒。
/// 🔴 **NextMoe 端口无关匹配**（RFC 8252 §7.3）：注册时写不写端口都行，
/// 运行时随便挑临时端口。所以我们自己注册后可以用 `callbackPort: 0`
/// （内核分配）——顺手解决「23380 被 ReinaManager 常驻占用」。
/// ⚠️ 复用别人注册的 client 时**不能**随便换端口（实测报 `15002 无效的回调地址`）。
///
/// 🔴 换令牌不需要 client_secret：两家都是 **PKCE 公共客户端**
/// （`token_endpoint_auth_methods_supported` 含 `none`），也都没有
/// `registration_endpoint`（不能程序化动态注册，只能人工建一次应用）。
library;

/// 一个可登录平台的静态参数。
class OAuthProviderConfig {
  const OAuthProviderConfig({
    required this.id,
    required this.displayName,
    required this.siteName,
    required this.clientId,
    required this.callbackPort,
    required this.callbackPath,
    required this.authorizeEndpoint,
    required this.tokenEndpoint,
    required this.userInfoEndpoint,
    required this.scopes,
    required this.siteUrl,
    this.prompt,
  });

  /// 存储键（[AccessTokenStore] 的 provider 名）。
  final String id;

  /// 卡片上显示的名字。
  final String displayName;

  /// 站点名（错误话术用）。
  final String siteName;

  /// PKCE 公共客户端 id。
  final String clientId;

  final int callbackPort;
  final String callbackPath;

  final String authorizeEndpoint;
  final String tokenEndpoint;
  final String userInfoEndpoint;

  /// 空格分隔的 scope。
  final String scopes;

  /// 站点主页（「打开站点」链接）。
  final String siteUrl;

  /// 需要每次强制同意页时为 `consent`（Hikarinagi 用）。
  final String? prompt;

  /// 注册时绑定的回调地址（固定端口时用；探针/文档引用它）。
  String get redirectUri => redirectUriFor(callbackPort);

  /// 按**实际**监听端口拼回调地址。
  ///
  /// 🔴 `callbackPort == 0`（内核随机分配）时只能用这个，
  /// 且换令牌时 `redirect_uri` 必须与授权时**逐字节相同**，
  /// 否则 `invalid_grant`。所以 [MetadataLoginService] 把这里的返回值
  /// 一路传下去，不在两处各自拼一次。
  String redirectUriFor(int port) => 'http://127.0.0.1:$port$callbackPath';
}

/// 鲲 GAL / NextMoe 账户中心（同一套账号）。
///
/// 实测：`token_endpoint_auth_methods_supported` 含 `none` ⇒ 换令牌不用 secret；
/// 元数据本身走 `api.nextmoe.dev/v2` 用应用密钥即可（不登录也能抓），
/// 登录换来的是**用户态数据**（我的记录 / 文件夹 / 分级）与独立额度。
const OAuthProviderConfig kOAuthNextMoe = OAuthProviderConfig(
  id: 'nextmoe',
  displayName: '鲲GAL/NextMoe',
  siteName: 'NextMoe',
  clientId: '741bebbd822505a5e13c13e711fb8801',
  // ⚠️ 复用 ReinaManager 注册的 client，所以端口必须与它注册的一致。
  // 换成我们自己的应用后改成 `0`（随机端口、端口无关匹配），
  // 就不再和 ReinaManager 抢 23380。
  callbackPort: 23380,
  callbackPath: '/callback/nextmoe',
  authorizeEndpoint: 'https://account.nextmoe.com/api/v1/oauth/authorize',
  tokenEndpoint: 'https://account.nextmoe.com/api/v1/oauth/token',
  userInfoEndpoint: 'https://account.nextmoe.com/api/v1/oauth/userinfo',
  // 🔴 只请求确实用得上、且应用侧注册了的：多要一个未注册的 scope，
  // 授权时会直接 `15006`（文档「常见错误」里点名了这条）。
  // `catalog:read` 例外——文档明说每个应用无需注册即可请求。
  // 收藏夹（`folder:read`/`folder:write`）一期没做同步，别提前索取。
  scopes: 'openid profile catalog:read',
  siteUrl: 'https://www.kungal.com/',
);

/// Hikarinagi。
///
/// 实测：**不需要用户登录也能抓元数据**（内置 `client_credentials` 换令牌），
/// 但直连会被 reset、走代理才通——它的问题在网络不在凭据。
/// 登录只加「个人额度 + 用户态数据」，所以卡片上要如实说明。
const OAuthProviderConfig kOAuthHikarinagi = OAuthProviderConfig(
  id: 'hikarinagi',
  displayName: 'Hikarinagi',
  siteName: 'Hikarinagi',
  clientId: 'hkn_hVbw2qChqzo2avRl',
  callbackPort: 23380,
  callbackPath: '/callback/hikarinagi',
  authorizeEndpoint: 'https://id.hikarinagi.org/oidc/auth',
  tokenEndpoint: 'https://id.hikarinagi.org/oidc/token',
  userInfoEndpoint: 'https://id.hikarinagi.org/oidc/me',
  // 🔴 刻意只要「读 + 离线刷新」：ReinaManager 还要 status:write（它做状态同步），
  // 我们不写用户数据就不该索取；将来真做同步时旧授权需重新同意，这是对的。
  scopes: 'openid user:read catalog:full offline_access',
  siteUrl: 'https://www.hikarinagi.org/',
  prompt: 'consent',
);

/// 快捷登录（浏览器 OAuth）总开关。
///
/// 🔴 **2026-11-13 用户裁决：暂时不做登录**，只保留基础凭证
/// （Bangumi 个人令牌 / 鲲 Cookie / 2DFan Cookie / Hikarinagi 内置凭据）。
/// 关掉时：设置页不出现任何「使用 X 账号登录」入口，`login()` 直接拒绝，
/// 但**已存在的令牌仍照常用于抓取**（只是不能再新登），
/// 并保留「已登录：昵称 + 退出登录」——否则令牌永远删不掉。
///
/// 恢复时把这里改成 `true` 即可，UI 与 service 两处都只看这一个值。
const bool kOAuthQuickLoginEnabled = false;

/// 支持快捷登录的全部平台（顺序即设置页顺序）。
const List<OAuthProviderConfig> kOAuthProviders = <OAuthProviderConfig>[
  kOAuthNextMoe,
  kOAuthHikarinagi,
];

/// 按 id 取配置，没有则 null。
OAuthProviderConfig? oauthProviderOf(String id) {
  for (final OAuthProviderConfig p in kOAuthProviders) {
    if (p.id == id) return p;
  }
  return null;
}
