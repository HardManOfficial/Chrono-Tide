import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../services/metadata_credentials.dart';
import '../../../services/metadata_login_service.dart';
import '../../../services/oauth/oauth_providers.dart';
import '../../../services/oauth/oauth_token.dart';
import '../../../services/patch/patch_delivery_service.dart';
import '../../../services/website_bookmark_service.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../widgets/interactive_wrapper.dart';
import 'metadata_site_catalog.dart';

/// 「平台账号与凭证」卡片组。
///
/// 设计取向对齐 ReinaManager「账号与同步」+ LunaBox「账户授权」：
///   品牌行（图标 + 名称 + 域名 + 状态胶囊）
///   → 一句能力说明 + 一句「填了能拿到什么」
///   → 粘贴凭据 / 校验结果
///
/// 🔴 2026-11-13 用户裁决「登录暂时先不做」：一键登录入口由
/// [kOAuthQuickLoginEnabled] 统一关闭，这里只保留**基础凭证**
/// （Bangumi 个人令牌 / 鲲 Cookie / 2DFan Cookie / Hikarinagi 内置凭据）。
/// 恢复登录只需把那个常量改成 true —— 本文件里所有 OAuth 相关分支都看它。
///
/// 只列**有登录价值**的四家（[kMetadataCredentialSites]）：Bangumi /
/// 鲲GAL/NextMoe / Hikarinagi / 2DFan。其余平台是公开接口，写一行说明即可，
/// 给它们放假输入框只会让用户以为「不登录就用不了」。
///
/// 🔴 我们**不做**收藏/游玩状态同步：本项目没有云端状态模型，硬抄会得到
/// 一堆永远灰色的开关。详见 features/global_metadata_settings.md。
class MetadataAccountsCard extends StatefulWidget {
  const MetadataAccountsCard({super.key});

  @override
  State<MetadataAccountsCard> createState() => _MetadataAccountsCardState();
}

class _MetadataAccountsCardState extends State<MetadataAccountsCard> {
  final TextEditingController _bangumiController = TextEditingController();
  final TextEditingController _kunController = TextEditingController();
  final TextEditingController _fanController = TextEditingController();

  bool _loading = true;
  bool _obscureBangumi = true;

  /// 鲲卡片默认只给「一键登录」，Cookie 是后备通道，默认收起。
  /// 🔴 快捷登录关掉后反过来：Cookie 是**唯一**通道，必须直接展开。
  bool _showKunCookie = !kOAuthQuickLoginEnabled;

  /// 最近一次登录动作落在哪个平台 + 结果文案（失败要留在卡片上，
  /// 不能只弹一个 3 秒就消失的提示）。
  String _lastLoginProvider = '';
  String? _loginMessage;
  bool _loginFailed = false;

  bool _busyBangumi = false;
  bool _busyKun = false;
  bool _busyFan = false;
  bool _busyHikari = false;

  bool _savedBangumi = false;
  bool _savedKun = false;
  bool _savedFan = false;

  CredentialCheck? _checkBangumi;
  CredentialCheck? _checkKun;
  CredentialCheck? _checkFan;
  CredentialCheck? _checkHikari;

  @override
  void initState() {
    super.initState();
    // 登录状态变化要立刻反映到胶囊/按钮上（授权在浏览器里完成，
    // 回来后只有这条通知能把 UI 叫醒）。
    MetadataLoginService.instance.addListener(_onLoginChanged);
    _loadSaved();
  }

  void _onLoginChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    MetadataLoginService.instance.removeListener(_onLoginChanged);
    _bangumiController.dispose();
    _kunController.dispose();
    _fanController.dispose();
    super.dispose();
  }

  /// 该卡片对应的 OAuth 平台（没有则是 null）。
  OAuthProviderConfig? _oauthOf(MetadataSiteInfo site) {
    if (site.sources.contains(SourceType.hikarinagi)) return kOAuthHikarinagi;
    if (site.sources.contains(SourceType.kun) ||
        site.sources.contains(SourceType.nextmoe)) {
      return kOAuthNextMoe;
    }
    return null;
  }

  /// 已保存的令牌（未登录为 null）。
  OAuthToken? _oauthTokenOf(MetadataSiteInfo site) {
    final OAuthProviderConfig? provider = _oauthOf(site);
    if (provider == null) return null;
    return MetadataLoginService.instance.tokenOf(provider.id);
  }

  Future<void> _loadSaved() async {
    String? token;
    String? kun;
    String? fan;
    try {
      await MetadataLoginService.instance.hydrate();
      token = await BangumiTokenStore.loadToken();
      kun = await KunCookieStore.load();
      fan = await TwoDFanCookieStore.load();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (token != null && token.isNotEmpty) {
        _bangumiController.text = token;
        _savedBangumi = true;
      }
      if (kun != null && kun.isNotEmpty) {
        _kunController.text = kun;
        _savedKun = true;
      }
      if (fan != null && fan.isNotEmpty) {
        _fanController.text = fan;
        _savedFan = true;
      }
    });
  }

  // ─────────────────────── Bangumi ───────────────────────

  /// 先落盘再校验：网络不通时令牌本身可能仍是对的，不该因为校验失败
  /// 就让用户白填一次。
  Future<void> _saveAndVerifyBangumi() async {
    final String token = _bangumiController.text.trim();
    if (token.isEmpty) {
      await BangumiTokenStore.clearToken();
      if (!mounted) return;
      setState(() {
        _savedBangumi = false;
        _checkBangumi = null;
      });
      return;
    }

    setState(() {
      _busyBangumi = true;
      _checkBangumi = null;
    });
    await BangumiTokenStore.saveToken(token);
    CredentialCheck check;
    try {
      check = await MetadataCredentialService.verifyBangumiToken(token);
    } catch (e) {
      check = CredentialCheck(ok: false, message: '校验失败：$e');
    }
    if (!mounted) return;
    setState(() {
      _busyBangumi = false;
      _savedBangumi = true;
      _checkBangumi = check;
    });
  }

  // ─────────────────────── 鲲GAL/NextMoe ───────────────────────

  Future<void> _saveAndVerifyKun() async {
    final String raw = _kunController.text.trim();
    if (raw.isEmpty) {
      await _clearKun();
      return;
    }
    final String? shapeError =
        MetadataCredentialService.validateCookieShape(raw);
    if (shapeError != null) {
      setState(() => _checkKun = CredentialCheck(ok: false, message: shapeError));
      return;
    }

    setState(() {
      _busyKun = true;
      _checkKun = null;
    });
    await KunCookieStore.save(raw);
    CredentialCheck check;
    try {
      check = await MetadataCredentialService.verifyKunCookie(raw);
    } catch (e) {
      check = CredentialCheck(ok: false, message: '校验失败：$e');
    }
    if (!mounted) return;
    setState(() {
      _busyKun = false;
      _savedKun = true;
      _checkKun = check;
    });
  }

  Future<void> _clearKun() async {
    _kunController.clear();
    await KunCookieStore.clear();
    if (!mounted) return;
    setState(() {
      _savedKun = false;
      _checkKun = null;
    });
  }

  // ─────────────────────── 2DFan ───────────────────────

  Future<void> _saveFan() async {
    final String raw = _fanController.text.trim();
    if (raw.isEmpty) {
      await _clearFan();
      return;
    }
    final String? shapeError =
        MetadataCredentialService.validateCookieShape(raw);
    if (shapeError != null) {
      setState(() => _checkFan = CredentialCheck(ok: false, message: shapeError));
      return;
    }
    setState(() => _busyFan = true);
    await TwoDFanCookieStore.save(raw);
    // 🔴 先落盘再校验：Cookie 可能是对的，只是这一刻镜像抽风 ——
    //    不能因为校验失败就让用户白填一次（与 Bangumi 同一套口径）。
    CredentialCheck check;
    try {
      check = await MetadataCredentialService.verifyTwoDFanCookie(raw);
    } catch (e) {
      check = CredentialCheck(ok: false, message: '校验失败：$e');
    }
    if (!mounted) return;
    // 身份变了 ⇒ 展开位里的价格/余额必须重新读，否则显示的是上一个账号
    PatchDeliveryService.instance.invalidateAll();
    setState(() {
      _busyFan = false;
      _savedFan = true;
      _checkFan = check;
    });
  }

  Future<void> _clearFan() async {
    _fanController.clear();
    await TwoDFanCookieStore.clear();
    PatchDeliveryService.instance.invalidateAll();
    if (!mounted) return;
    setState(() {
      _savedFan = false;
      _checkFan = null;
    });
  }

  // ─────────────────────── Hikarinagi ───────────────────────

  Future<void> _testHikarinagi() async {
    setState(() {
      _busyHikari = true;
      _checkHikari = null;
    });
    CredentialCheck check;
    try {
      check = await MetadataCredentialService.testHikarinagi();
    } catch (e) {
      check = CredentialCheck(ok: false, message: '测试失败：$e');
    }
    if (!mounted) return;
    setState(() {
      _busyHikari = false;
      _checkHikari = check;
    });
  }

  // ─────────────────────── 构建 ───────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.secondaryText),
            ),
          ),
        ),
      );
    }

    final List<MetadataSiteInfo> sites = kMetadataCredentialSites;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MetadataSiteInfo site in sites)
          Padding(
            padding: EdgeInsets.only(
              bottom: site == sites.last ? 0 : AppSpacing.sm,
            ),
            child: _buildSiteCard(site),
          ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '其余平台（VNDB / CT 探索库 / Steam / 月幕 GAL）走公开接口，无需任何凭证；'
          '想关掉它们请到下方「元数据拉取来源」。',
          style: TextStyle(
            fontSize: 11,
            height: 16 / 11,
            color: AppColors.placeholderText,
          ),
        ),
      ],
    );
  }

  Widget _buildSiteCard(MetadataSiteInfo site) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _buildLogoTile(site),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      site.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      site.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.placeholderText,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildStatusBadge(site),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            site.hint,
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          if (site.loginNote != null) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              site.loginNote!,
              style: TextStyle(
                fontSize: 11,
                height: 16 / 11,
                color: AppColors.placeholderText,
              ),
            ),
          ],
          const SizedBox(height: 10),
          ..._buildCredentialArea(site),
        ],
      ),
    );
  }

  /// 平台图标底座：品牌色浅底 + 细描边，让 png/svg 混杂的 logo 看起来齐整。
  Widget _buildLogoTile(MetadataSiteInfo site) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: site.accent.withOpacity(0.10),
        border: Border.all(color: site.accent.withOpacity(0.35), width: 1),
      ),
      child: MetadataSiteLogo(site: site, height: 18),
    );
  }

  Widget _buildStatusBadge(MetadataSiteInfo site) {
    Color color;
    String label;
    // OAuth 登录态优先：它是「真的登进去了」，比「已保存 Cookie」强一档。
    if (_oauthTokenOf(site) != null) {
      color = AppColors.successGreen;
      label = '已登录';
    } else if (site.credential == MetadataCredentialKind.builtIn) {
      color = AppColors.successGreen;
      label = '内置凭据';
    } else if (_isVerified(site)) {
      color = AppColors.successGreen;
      label = '已登录';
    } else if (_isSaved(site)) {
      color = AppColors.warningAmber;
      label = '已保存';
    } else {
      color = AppColors.placeholderText;
      label = '未登录';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        border: Border.all(color: color.withOpacity(0.55), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  bool _isVerified(MetadataSiteInfo site) {
    if (site.sources.contains(SourceType.bangumi)) {
      return _checkBangumi?.ok == true;
    }
    if (site.sources.contains(SourceType.kun) ||
        site.sources.contains(SourceType.nextmoe)) {
      return _checkKun?.ok == true;
    }
    if (site.sources.contains(SourceType.twoDfan)) {
      return _checkFan?.ok == true;
    }
    return false;
  }

  bool _isSaved(MetadataSiteInfo site) {
    if (site.sources.contains(SourceType.bangumi)) return _savedBangumi;
    if (site.sources.contains(SourceType.kun) ||
        site.sources.contains(SourceType.nextmoe)) {
      return _savedKun;
    }
    if (site.sources.contains(SourceType.twoDfan)) return _savedFan;
    return false;
  }

  List<Widget> _buildCredentialArea(MetadataSiteInfo site) {
    if (site.sources.contains(SourceType.bangumi)) {
      return _buildBangumiArea();
    }
    if (site.sources.contains(SourceType.kun) ||
        site.sources.contains(SourceType.nextmoe)) {
      return _buildKunArea(site);
    }
    if (site.sources.contains(SourceType.hikarinagi)) {
      return _buildHikarinagiArea(site);
    }
    return _buildCookieArea(
      controller: _fanController,
      hint: '粘贴 2dfan.com 的 Cookie（整行，形如 a=1; b=2）',
      busy: _busyFan,
      saved: _savedFan,
      check: _checkFan,
      primaryLabel: '保存',
      emptyHint: '不填也能抓公开条目，只是命中率较低；登录后需要账号的内容才读得到。',
      onPrimary: _saveFan,
      onClear: _clearFan,
      loginUrl: site.loginUrl,
      loginLabel: '打开站点 ↗',
    );
  }

  // ─────────────────────── OAuth 快捷登录 ───────────────────────

  Future<void> _startLogin(OAuthProviderConfig provider) async {
    _lastLoginProvider = provider.id;
    setState(() {
      _loginMessage = null;
      _loginFailed = false;
    });
    final bool ok = await MetadataLoginService.instance.login(provider);
    if (!mounted) return;
    setState(() {
      _loginMessage = MetadataLoginService.instance.statusText;
      _loginFailed = !ok;
    });
  }

  /// 一键登录行：未登录 → 「使用 X 账号登录」；授权中 → 取消；已登录 → 昵称 + 退出。
  ///
  /// 🔴 受 [kOAuthQuickLoginEnabled] 总开关控制：关掉时**一个登录入口都不出现**，
  /// 但「已经登录过」要如实显示并留退出按钮 —— 否则令牌永远删不掉。
  List<Widget> _buildOAuthRow(OAuthProviderConfig provider) {
    final MetadataLoginService login = MetadataLoginService.instance;
    final OAuthToken? token = login.tokenOf(provider.id);
    final bool busyHere = login.activeProviderId == provider.id;

    if (token != null && !busyHere) {
      return _buildLoggedInRows(provider, token, login);
    }
    if (!kOAuthQuickLoginEnabled) return const <Widget>[];

    if (busyHere) {
      return <Widget>[
        Row(
          children: <Widget>[
            _buildActionButton(
              label: '取消登录',
              primary: false,
              onTap: () => login.cancel(),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '请在浏览器里完成 ${provider.siteName} 授权，成功后会自动跳回来',
                maxLines: 2,
                style: TextStyle(
                  fontSize: 11,
                  height: 15 / 11,
                  color: AppColors.brandBlue,
                ),
              ),
            ),
          ],
        ),
      ];
    }

    return <Widget>[
      Row(
        children: <Widget>[
          _buildActionButton(
            label: '使用 ${provider.siteName} 账号登录',
            primary: true,
            onTap: login.isBusy ? null : () => _startLogin(provider),
          ),
          const SizedBox(width: 12),
          _buildLink(
            '打开站点 ↗',
            () => WebsiteBookmarkService.openExternal(provider.siteUrl),
          ),
        ],
      ),
    ];
  }

  /// 已登录行：昵称 + 过期时间 + 退出。
  List<Widget> _buildLoggedInRows(
    OAuthProviderConfig provider,
    OAuthToken token,
    MetadataLoginService login,
  ) {
    final String name =
        token.accountName.isEmpty ? provider.displayName : token.accountName;
    return <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '已登录：$name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.successGreen,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${token.expiryLabel} · 令牌只存在本机',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.placeholderText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            label: '退出登录',
            primary: false,
            onTap: () => login.logout(provider.id),
          ),
        ],
      ),
    ];
  }

  /// 快捷登录关闭时给一句说明，免得用户以为按钮丢了。
  Widget _buildLoginClosedNote(String detail) {
    return Text(
      detail,
      style: TextStyle(
        fontSize: 11,
        height: 16 / 11,
        color: AppColors.placeholderText,
      ),
    );
  }

  /// 登录结束后的结果行（成功/失败都以人话显示）。
  Widget? _buildLoginStatus(OAuthProviderConfig provider) {
    final MetadataLoginService login = MetadataLoginService.instance;
    // 授权进行中由「取消登录」那行负责，避免两句话说同一件事。
    if (login.activeProviderId == provider.id) return null;
    final String? text =
        _lastLoginProvider == provider.id ? _loginMessage : null;
    if (text == null || text.isEmpty) return null;
    return Text(
      text,
      maxLines: 2,
      style: TextStyle(
        fontSize: 11,
        height: 15 / 11,
        color: _loginFailed ? AppColors.dangerRed : AppColors.successGreen,
      ),
    );
  }

  List<Widget> _buildKunArea(MetadataSiteInfo site) {
    final List<Widget> rows = <Widget>[..._buildOAuthRow(kOAuthNextMoe)];
    final Widget? status = _buildLoginStatus(kOAuthNextMoe);
    final MetadataLoginService login = MetadataLoginService.instance;
    if (status != null) {
      rows
        ..add(const SizedBox(height: 6))
        ..add(status);
    }
    if (!kOAuthQuickLoginEnabled) {
      rows
        ..add(const SizedBox(height: 6))
        ..add(_buildLoginClosedNote(
            '快捷登录暂未开放：请粘贴登录 kungal.com 后的 Cookie（下方即是）。'));
    }
    // 登录没成功时给一条手动通道（企业网络拦浏览器跳转、Cookie 还在回忆里…）
    if (kOAuthQuickLoginEnabled &&
        !login.isLoggedIn(kOAuthNextMoe.id) &&
        !login.isBusy) {
      rows
        ..add(const SizedBox(height: 8))
        ..add(_buildLink(
          _showKunCookie ? '收起手动登录' : '登录不成功？改用 Cookie 手动登录',
          () => setState(() => _showKunCookie = !_showKunCookie),
        ));
    }
    // 已登录就优先用令牌，Cookie 框不再占地方；
    // 未登录时它才是主通道（快捷登录关闭时尤其如此，所以不再折叠）。
    final bool showCookie = !login.isLoggedIn(kOAuthNextMoe.id) &&
        (_showKunCookie || !kOAuthQuickLoginEnabled);
    if (showCookie) {
      rows
        ..add(const SizedBox(height: 8))
        ..addAll(_buildCookieArea(
          controller: _kunController,
          hint: '粘贴 kungal.com 的 Cookie（整行，形如 a=1; b=2）',
          busy: _busyKun,
          saved: _savedKun,
          check: _checkKun,
          primaryLabel: '保存并验证',
          emptyHint: '未登录时站点只回「用户登录失效」；NextMoe 公共目录不受影响。',
          onPrimary: _saveAndVerifyKun,
          onClear: _clearKun,
          loginUrl: null,
          loginLabel: '',
        ));
    }
    return rows;
  }

  List<Widget> _buildHikarinagiArea(MetadataSiteInfo site) {
    final List<Widget> rows = <Widget>[..._buildOAuthRow(kOAuthHikarinagi)];
    final Widget? status = _buildLoginStatus(kOAuthHikarinagi);
    if (status != null) {
      rows
        ..add(const SizedBox(height: 6))
        ..add(status);
    }
    if (!kOAuthQuickLoginEnabled) {
      rows
        ..add(const SizedBox(height: 6))
        ..add(_buildLoginClosedNote(
            '快捷登录暂未开放；本平台凭据已内置，不登录也能正常抓取。'));
    }
    rows
      ..add(const SizedBox(height: 8))
      ..addAll(_buildBuiltInArea(site));
    return rows;
  }

  /// 连通性实测（Hikarinagi 不登录也能抓，所以「能不能用」比「有没有登录」更关键）。
  List<Widget> _buildBuiltInArea(MetadataSiteInfo site) {
    final CredentialCheck? check = _checkHikari;
    return <Widget>[
      Row(
        children: <Widget>[
          _buildActionButton(
            label: _busyHikari ? '测试中…' : '测试连通性',
            primary: false,
            onTap: _busyHikari ? null : _testHikarinagi,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              check?.message ?? '凭据已内置，无需填写；点这里可以实测当前网络下能否抓取。',
              maxLines: 2,
              style: TextStyle(
                fontSize: 11,
                height: 15 / 11,
                color: check == null
                    ? AppColors.placeholderText
                    : (check.ok ? AppColors.successGreen : AppColors.dangerRed),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildBangumiArea() {
    return <Widget>[
      Text(
        'Bangumi 的 OAuth 需要应用密钥（client_secret），第三方软件拿不到，'
        '因此这里用官方「个人访问令牌」，效果等价。',
        style: TextStyle(
          fontSize: 11,
          height: 16 / 11,
          color: AppColors.placeholderText,
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(
            child: _buildSecretField(
              _bangumiController,
              hint: '粘贴 bgm.tv 个人访问令牌',
              lines: 1,
              obscure: _obscureBangumi,
            ),
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            label: _busyBangumi ? '校验中…' : '保存并验证',
            primary: true,
            onTap: _busyBangumi ? null : _saveAndVerifyBangumi,
          ),
        ],
      ),
      const SizedBox(height: 6),
      Row(
        children: <Widget>[
          _buildLink(
            '获取令牌 ↗',
            () => WebsiteBookmarkService.openExternal(
                'https://next.bgm.tv/demo/access-token/create'),
          ),
          const SizedBox(width: 12),
          _buildLink(
            _obscureBangumi ? '显示' : '隐藏',
            () => setState(() => _obscureBangumi = !_obscureBangumi),
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildCheckLine(_checkBangumi, _savedBangumi, '未校验')),
        ],
      ),
    ];
  }

  List<Widget> _buildCookieArea({
    required TextEditingController controller,
    required String hint,
    required bool busy,
    required bool saved,
    required CredentialCheck? check,
    required String primaryLabel,
    required String emptyHint,
    required Future<void> Function() onPrimary,
    required Future<void> Function() onClear,
    required String? loginUrl,
    required String loginLabel,
  }) {
    return <Widget>[
      _buildSecretField(controller, hint: hint, lines: 2, obscure: false),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          _buildActionButton(
            label: busy ? '校验中…' : primaryLabel,
            primary: true,
            onTap: busy ? null : onPrimary,
          ),
          const SizedBox(width: 8),
          _buildActionButton(
            label: '清除',
            primary: false,
            onTap: busy ? null : onClear,
          ),
          if (loginUrl != null) ...<Widget>[
            const SizedBox(width: 12),
            _buildLink(
              loginLabel,
              () => WebsiteBookmarkService.openExternal(loginUrl),
            ),
          ],
        ],
      ),
      const SizedBox(height: 6),
      _buildCheckLine(check, saved, emptyHint),
    ];
  }

  Widget _buildCheckLine(
      CredentialCheck? check, bool saved, String emptyHint) {
    final String text;
    final Color color;
    if (check != null) {
      final String id = (check.identity ?? '').trim();
      text = check.ok && id.isNotEmpty
          ? '${check.message} · $id'
          : check.message;
      color = check.ok ? AppColors.successGreen : AppColors.dangerRed;
    } else if (saved) {
      text = '已保存（本次打开未校验）';
      color = AppColors.secondaryText;
    } else {
      text = emptyHint;
      color = AppColors.placeholderText;
    }
    return Text(
      text,
      maxLines: 2,
      style: TextStyle(fontSize: 11, height: 15 / 11, color: color),
    );
  }

  Widget _buildLink(String label, VoidCallback onTap) {
    return InteractiveWrapper(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: AppColors.brandBlue,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.brandBlue.withOpacity(0.5),
        ),
      ),
    );
  }

  Widget _buildSecretField(
    TextEditingController controller, {
    required String hint,
    int lines = 1,
    bool obscure = true,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: TextField(
        controller: controller,
        // 🔴 TextField 断言 `!obscureText || maxLines == 1`：
        // 多行遮蔽会直接抛异常把整页变灰块。Cookie 需要多行可读，
        // 因此只在单行令牌框里遮蔽。
        obscureText: obscure && lines == 1,
        minLines: lines,
        maxLines: lines,
        style: TextStyle(fontSize: 12, color: AppColors.primaryText),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 12, color: AppColors.inputHint),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required bool primary,
    VoidCallback? onTap,
  }) {
    final Color textColor = primary ? Colors.white : AppColors.secondaryText;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: InteractiveWrapper(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: primary ? AppColors.buttonBackground : AppColors.background,
            border: Border.all(
              color: primary ? AppColors.borderLight : AppColors.border,
              width: primary ? 2 : 1.4,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}
