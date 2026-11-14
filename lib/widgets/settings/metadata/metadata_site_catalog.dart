import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../services/metadata_credentials.dart';

/// 一个元数据平台在设置页里的展示元数据。
///
/// 🔴 单一事实源：新增平台只改 [kMetadataSites]，来源卡片、账号卡片、
/// 字段优先级下拉全部从这里取，避免三处各写一份名称/简介而漂移。
///
/// [sources] 是**一组** [SourceType]：绝大多数平台一对一，但 NextMoe 与
/// 鲲 Galgame 是同一套生态的两条接口（NextMoe 是公共目录、鲲是论坛站），
/// 用户视角上它们是「一个平台」，因此合并成一张卡、一个开关。
@immutable
class MetadataSiteInfo {
  const MetadataSiteInfo({
    required this.sources,
    required this.title,
    required this.subtitle,
    required this.hint,
    required this.credential,
    required this.accent,
    this.assetPath,
    this.loginNote,
    this.loginUrl,
  });

  /// 该卡片代表的抓取源（≥1 个）。顺序即「组内优先级」。
  final List<SourceType> sources;

  /// 主标题（如「Bangumi」「鲲GAL/NextMoe」）。
  final String title;

  /// 副标题（域名或英文名），字号更小、颜色更浅。
  final String subtitle;

  /// 一句简介，对齐 LunaBox 的卡片第二行。
  final String hint;

  final MetadataCredentialKind credential;

  /// 平台主色，用于卡片强调与图标底。
  final Color accent;

  /// 图标资源路径（png / webp / svg）。为 null 时用 [title] 首字母做文字标。
  final String? assetPath;

  /// 「登录能拿到什么」——账号卡里的一句副说明。
  final String? loginNote;

  /// 「打开站点」按钮的目标（登录页优先）。
  final String? loginUrl;

  /// 组内首个源（单源平台就是它自己）。落盘/回显仍按单源粒度。
  SourceType get source => sources.first;

  /// 是否是多源合并的「一组」（目前只有鲲GAL/NextMoe）。
  bool get isGroup => sources.length > 1;

  bool get hasAsset => assetPath != null && assetPath!.isNotEmpty;

  bool get isSvg => hasAsset && assetPath!.toLowerCase().endsWith('.svg');

  /// 该组是否「需要用户自己登录」——`builtIn`/`none` 都不需要。
  bool get needsUserLogin =>
      credential == MetadataCredentialKind.personalToken ||
      credential == MetadataCredentialKind.cookie;
}

/// 所有可配置的元数据平台，顺序即设置页展示顺序。
///
/// 顺序刻意把「需要登录的四家」排在前面（与 ReinaManager / LunaBox 的
/// 账号区一致），免登录的排在后面。
///
/// ⚠️ 不含 [SourceType.mix]（它不是真实平台，是字段级整合结果）与
/// [SourceType.local]（本地库，不作为抓取源）。
const List<MetadataSiteInfo> kMetadataSites = <MetadataSiteInfo>[
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.bangumi],
    title: 'Bangumi',
    subtitle: 'bgm.tv',
    hint: '中文 ACG 条目库，标签与译名最全；填写个人令牌后请求额度从匿名提到个人配额。',
    loginNote: '登录后：请求额度提升，抓取更少被限流。',
    credential: MetadataCredentialKind.personalToken,
    accent: Color(0xFFF09199),
    assetPath: 'assets/images/site_bangumi.png',
    loginUrl: 'https://bgm.tv/',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.nextmoe, SourceType.kun],
    title: '鲲GAL/NextMoe',
    subtitle: 'kungal.com · nextmoe.dev',
    hint: '同一套 NextMoe 生态：公共目录免登录可读（六源对齐），鲲论坛接口需登录后才返回数据。',
    loginNote: '登录后：鲲论坛接口恢复可用（评分/截图/会社更完整），并可读取登录态内容。',
    credential: MetadataCredentialKind.cookie,
    accent: Color(0xFFE85D9E),
    assetPath: 'assets/images/site_kungal.webp',
    loginUrl: 'https://www.kungal.com/user/login',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.hikarinagi],
    title: 'Hikarinagi',
    subtitle: 'hikarinagi.org',
    hint: '横幅封面数据最全；已内置应用级 OAuth 凭据，免登录即可抓取。',
    loginNote: '无需登录；抓取失败多半是网络问题（可在「网络与存储」确认代理生效）。',
    credential: MetadataCredentialKind.builtIn,
    accent: Color(0xFF6EC6E6),
    assetPath: 'assets/images/site_hikarinagi.svg',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.twoDfan],
    title: '2DFan',
    subtitle: '2dfan.com',
    hint: '中文 Galgame 资料站，中文译名与别名最全；登录后可读取需要账号的条目。',
    loginNote: '登录后：需要账号的条目也能抓；补丁资源仍走原站，本软件不代扣积分。',
    credential: MetadataCredentialKind.cookie,
    accent: Color(0xFFD96B3C),
    assetPath: 'assets/patch_sites/two_dfan.png',
    loginUrl: 'https://www.2dfan.com/',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.ct],
    title: 'CT 探索库',
    subtitle: 'Chrono Tide',
    hint: '本软件自建平台，社区共建的中文元数据；随账号同步，免登录即可读取。',
    credential: MetadataCredentialKind.none,
    accent: Color(0xFFC9506B),
    // 自建平台就用软件自己的图标，不另造一个「站点 logo」
    assetPath: 'assets/images/app_icon.png',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.vndb],
    title: 'VNDB',
    subtitle: 'the visual novel database',
    hint: '视觉小说综合数据库，评分与投票数最权威；公开接口免登录。',
    credential: MetadataCredentialKind.none,
    accent: Color(0xFF4A72A5),
    assetPath: 'assets/images/site_vndb.svg',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.steam],
    title: 'Steam',
    subtitle: 'store.steampowered.com',
    hint: 'Valve 官方商店，适合 Steam 平台发行的作品；无需凭证。',
    credential: MetadataCredentialKind.none,
    accent: Color(0xFF1B2838),
    assetPath: 'assets/images/site_steam.png',
  ),
  MetadataSiteInfo(
    sources: <SourceType>[SourceType.ymgal],
    title: '月幕 GAL',
    subtitle: 'ymgal.games',
    hint: '中文 GALGAME 社区，标签为中文；无需凭证。',
    credential: MetadataCredentialKind.none,
    accent: Color(0xFF5CC47A),
    assetPath: 'assets/images/site_ymgal.png',
  ),
];

/// 账号区只列「有登录价值」的平台（其余公开接口，写一行说明即可）。
List<MetadataSiteInfo> get kMetadataCredentialSites => kMetadataSites
    .where((MetadataSiteInfo s) =>
        s.credential != MetadataCredentialKind.none)
    .toList(growable: false);

/// 按 [SourceType] 取展示元数据（合并组内的任一源都能命中）；未收录
/// （如 mix/local）返回 null。
MetadataSiteInfo? metadataSiteOf(SourceType source) {
  for (final MetadataSiteInfo site in kMetadataSites) {
    if (site.sources.contains(source)) return site;
  }
  return null;
}

/// 源 → 展示名（合并组统一显示组名，避免「鲲GAL/NextMoe」在链里出现两次）。
String metadataSiteTitleOf(SourceType source) =>
    metadataSiteOf(source)?.title ?? source.displayName;

/// 把一条优先级链折成「按平台分组、去重保序」的展示文本。
///
/// 例：`nextmoe, kun, ct, vndb` → `鲲GAL/NextMoe → CT 探索库 → VNDB`
String metadataChainTitleText(List<SourceType> chain) {
  final List<String> out = <String>[];
  for (final SourceType s in chain) {
    final String t = metadataSiteTitleOf(s);
    if (out.isNotEmpty && out.last == t) continue;
    if (out.contains(t)) continue;
    out.add(t);
  }
  return out.join(' → ');
}

/// 平台图标：png/webp 走 `Image.asset`，svg 走 `SvgPicture.asset`，
/// 无资源时退化为「标题文字标」（不新增图标文件也能看）。
class MetadataSiteLogo extends StatelessWidget {
  const MetadataSiteLogo({
    super.key,
    required this.site,
    this.height = 22,
  });

  final MetadataSiteInfo site;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (!site.hasAsset) {
      return Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: site.accent.withOpacity(0.14),
          border: Border.all(color: site.accent.withOpacity(0.6), width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          site.title,
          style: TextStyle(
            fontSize: height * 0.52,
            fontWeight: FontWeight.w700,
            color: site.accent,
            height: 1,
          ),
        ),
      );
    }

    if (site.isSvg) {
      // 🔴 不染色：官方 SVG 多为透明底深色字，`BlendMode.srcIn` 会把
      // 多色 logo 压成单色块（LunaBox 用剪影是因为它自绘 UI 需要统一，
      // 我们保留官方配色更接近用户对「平台图标」的预期）。
      return SvgPicture.asset(
        site.assetPath!,
        height: height,
        fit: BoxFit.contain,
      );
    }

    return Image.asset(
      site.assetPath!,
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
        // 🔴 资源缺失不能让整页塌成灰块（release 下 ErrorWidget 就是灰底）
        return Text(
          site.title,
          style: TextStyle(
            fontSize: height * 0.52,
            fontWeight: FontWeight.w700,
            color: site.accent,
            height: 1,
          ),
        );
      },
    );
  }
}
