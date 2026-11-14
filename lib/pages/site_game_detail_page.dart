import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../core/portable_image_cache_manager.dart';
import '../services/site_search/site_search_service.dart';
import '../services/subtitle_composer.dart';
import '../services/website_bookmark_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../widgets/game_detail/game_detail_header.dart';
import '../widgets/patch_station/patch_station_dark_panel.dart';
import '../widgets/patch_station/patch_station_panel.dart' show PatchGameRef;
import '../widgets/nsfw/nsfw_image.dart';
import '../widgets/site_library/site_library_resource_panel.dart';
import '../widgets/screenshot_carousel.dart';

/// 站外作品详情页（SITE-SEARCH）—— **复用原生详情页的版式**。
///
/// v2（2026-11-11 用户拍板）：不再自创版式，改为**组合原生详情页的构件**：
/// - `GameDetailHeader`（封面 + 大标题 + 别名胶囊 + 元数据行 + 标签 + 按钮行）
/// —— 原生页用的就是它。v3（2026-11-13 用户拍板「全站库」）：「获取 / 分享 /
///   补丁」按新语义**点亮**（获取=letmoe 下载指令 / 分享=网盘下载 /
///   补丁=补丁站），「上传 / 喜欢 / 反馈」仍灰置，「打开原站」在顶栏；
/// - `ScreenshotCarousel` —— 截图轮播与原生同款（内含防盗链缓存管理器）；
/// - 「游戏简介」面板 —— 照抄原生 `_buildDescription` 的容器与排版样式。
///
/// 为什么**不直接进** `GameDetailPage`：那一页由 `GameRepository.getGameById`
/// （PocketBase 记录）驱动，拿不到记录就整页进错误态；站外作品没有 PB 记录。
/// 这里复用它的**视觉构件**但不复用它的数据依赖，边界清晰。
///
/// 数据流：
/// 1. 首帧直接用列表卡片态渲染（[SiteSearchHit] 已带标题/封面/评分/发售日/
///    会社），**不闪白、不阻塞**；
/// 2. 同时后台拉一次详情补简介/标签/截图；失败时在简介面板内显示「重试」
///    而不是当成「这部作品没有简介」（见 `SiteSearchService.fetchDetail` 的约定）。
class SiteGameDetailPage extends StatefulWidget {
  final SiteSearchHit hit;
  final VoidCallback onBack;

  /// 「用此数据入库」：把命中交给上层带入添加流程（预填标题）。
  /// null = 上层没接（例如单测/探针），按钮隐藏而不是点了没反应。
  final ValueChanged<SiteSearchHit>? onImport;

  const SiteGameDetailPage({
    super.key,
    required this.hit,
    required this.onBack,
    this.onImport,
  });

  @override
  State<SiteGameDetailPage> createState() => _SiteGameDetailPageState();
}

class _SiteGameDetailPageState extends State<SiteGameDetailPage> {
  late SiteSearchHit _hit = widget.hit;
  bool _loadingDetail = false;
  bool _detailFailed = false;
  bool _backHovered = false;

  /// 操作行 / 补丁按钮的锚定矩形（浮层定位用，与原生详情页同一套）
  final GlobalKey _actionRowKey = GlobalKey();
  final GlobalKey _patchButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    if (widget.hit.detailLoaded) return;
    setState(() {
      _loadingDetail = true;
      _detailFailed = false;
    });
    final full = await SiteSearchService.instance.fetchDetail(widget.hit);
    if (!mounted) return;
    setState(() {
      _hit = full;
      _loadingDetail = false;
      // detailLoaded 仍为 false ⇒ 这次没拿到（不是「没有简介」）
      _detailFailed = !full.detailLoaded;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 版式与 GameDetailPage.build 一致：
    // 顶部游戏数据区（头部）+ 下方两栏（简介 / 截图），左 5 右 6。
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(32, 18, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GameDetailHeader(
            leading: _buildLeadingRow(),
            cover: _buildCover(),
            title: _hit.title,
            aliases: _headerAlias(),
            metaItems: _buildMetaItems(),
            tags: _buildTags(),
            // 全站库新语义（2026-11-13 用户拍板）：六个动作里「获取 / 分享 /
            // 补丁」点亮，各自接对应能力；「上传 / 喜欢 / 反馈」仍灰置
            // （社区功能绑定 PB 记录，站外作品没有）。
            // - 获取 = 鲲生态（letmoe）下载指令：托管直链/组合包**软件原生安装**
            //   （下载 → 解压 → 自动入库，2026-11-14 接通）；
            // - 分享 = 网盘下载（复制链接+提取码后外跳）；
            // - 补丁 = 补丁站（PATCH-STATION），鲲命中直接用 catalog id 锚定。
            // 按钮恒可点：面板自己处理「未定位 / 无资源」状态，不做预检。
            actionRowKey: _actionRowKey,
            patchButtonKey: _patchButtonKey,
            getLabel: '获取',
            getEnabled: true,
            // 获取 = 只要直链（原生安装）；分享 = 只要网盘。两种资源彻底
            // 分开检索（用户 2026-11-14 拍板），面板内不可切换。
            onGet: () =>
                _openResourcePanel(SiteLibraryResourceMode.direct),
            shareEnabled: true,
            onShare: () =>
                _openResourcePanel(SiteLibraryResourceMode.netdisk),
            onPatch: _handlePatchTap,
            patchEnabled: true,
            uploadEnabled: false,
            onUpload: null,
            onLike: () {},
            likeEnabled: false,
            onFeedback: () {},
            feedbackEnabled: false,
            liked: false,
            likeCount: 0,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左列 flex 5 / 右列 flex 6 —— 与原生详情页比例一致
                Expanded(flex: 5, child: _buildDescription()),
                const SizedBox(width: 32),
                Expanded(flex: 6, child: _buildScreenshotSection()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 头部：leading 行 ====================
  //
  // 原生页 leading 只有返回键；站外场景在右侧补「来源徽章 / 入库 / 打开原站」，
  // 不挤占按钮行（按钮行六格已满，且那行的语法是「动作」，这两个是「页面级」）。

  Widget _buildLeadingRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _buildBackIconButton(),
        const SizedBox(width: 12),
        _buildSourceBadge(),
        const SizedBox(width: 10),
        Text(
          '全站库作品',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.secondaryText.withOpacity(0.75),
          ),
        ),
        const Spacer(),
        if (widget.onImport != null)
          _buildPageActionButton(
            icon: Icons.library_add_rounded,
            label: '用此数据入库',
            onTap: () => widget.onImport!(_hit),
            primary: true,
          ),
        const SizedBox(width: 10),
        _buildPageActionButton(
          icon: Icons.open_in_new_rounded,
          label: '打开原站',
          onTap: _openSourceSite,
        ),
      ],
    );
  }

  /// 44×44 返回图标按钮（样式与原生详情页逐像素一致）
  Widget _buildBackIconButton() {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _backHovered = true),
      onExit: (_) => setState(() => _backHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _backHovered = true),
        onTapUp: (_) => setState(() => _backHovered = false),
        onTapCancel: () => setState(() => _backHovered = false),
        onTap: widget.onBack,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _backHovered
                ? AppColors.placeholderCover
                : AppColors.background,
            border: Border.all(
              color: AppColors.border,
              width: _backHovered ? 2.0 : 1.6,
            ),
            boxShadow: _backHovered
                ? [
                    BoxShadow(
                      color: const Color(0x408B7355),
                      offset: const Offset(0, 2),
                      blurRadius: 10,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: AppColors.border,
                      offset: const Offset(2, 3),
                      blurRadius: 0,
                    ),
                  ],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 20,
              color: AppColors.border,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSourceBadge() {
    final color = Color(_hit.source.colorValue);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public_rounded, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            '数据来自 ${_hit.source.displayName}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final bg = primary ? AppColors.selectedAccent : AppColors.background;
    final fg = primary ? Colors.white : AppColors.primaryText;
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: primary ? AppColors.selectedAccent : AppColors.border,
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.2),
                offset: const Offset(2, 3),
                blurRadius: 0,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 头部：封面 ====================

  /// 封面容器：与原生 `_buildGameCover` 同款（-2° 旋转、135×205、粗边框、
  /// 硬阴影）。站外没有封面相册，右下角不放相册入口。
  Widget _buildCover() {
    return Transform.rotate(
      angle: -2 * 3.14159 / 180,
      child: Container(
        width: GameDetailHeader.coverWidth,
        height: GameDetailHeader.coverHeight,
        decoration: BoxDecoration(
          color: AppColors.placeholderCover,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 5),
                blurRadius: 0)
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: _buildCoverImage(),
      ),
    );
  }

  Widget _buildCoverImage() {
    final url = _hit.coverUrl;
    if (url == null || url.isEmpty) {
      return Container(
        color: AppColors.placeholderCover,
        child: Center(
            child: Icon(Icons.image_outlined,
                size: 48, color: AppColors.secondaryText.withOpacity(0.25))),
      );
    }
    // 🔴 必须经 PortableImageCacheManager：2DFan 图床（img.achost.top）是
    // Referer 白名单，缺头一律 404；该 CacheManager 统一注入防盗链请求头。
    return Stack(fit: StackFit.expand, children: [
      NsfwImage.network(
        url,
        contentKind: NsfwContentKind.cover,
        enableReveal: true,
        detectOnDemand: true,
        child: CachedNetworkImage(
          cacheManager: PortableImageCacheManager(),
          imageUrl: url,
          fit: BoxFit.cover,
          memCacheWidth: 480,
          maxWidthDiskCache: 800,
          fadeInDuration: Duration.zero,
          placeholder: (_, __) => Container(
            color: AppColors.placeholderCover,
            child: Center(
              child: Icon(Icons.image_outlined,
                  size: 48, color: AppColors.secondaryText.withOpacity(0.25)),
            ),
          ),
          errorWidget: (_, __, ___) => Container(
              color: AppColors.placeholderCover,
              child: Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 40,
                      color: AppColors.secondaryText.withOpacity(0.2)))),
        ),
      ),
      // 与原生同款：装饰性提亮层不参与命中测试（保住 NsfwImage 揭示角标的点击）
      IgnorePointer(
        child: Container(color: Colors.white.withOpacity(0.38)),
      ),
    ]);
  }

  // ==================== 头部：别名 / 元数据 / 标签 ====================

  /// 头部别名列表：**除主标题外的全部名称**（日文原名 / 英文名 / 繁中名），
  /// 口径与原生 `_headerAlias` 一致（SubtitleComposer 归一化剔除主标题）。
  List<String> _headerAlias() {
    final subtitle = _hit.subtitle;
    final candidates = <String>[
      if (subtitle != null && subtitle.isNotEmpty && subtitle != _hit.title)
        subtitle,
      ..._hit.aliasNames,
    ];
    return SubtitleComposer.resolve(candidates, mainTitles: [_hit.title]);
  }

  /// 元数据条目：会社 → 发售日 → 评分 → 热度 → 来源站点（样式与原生一致）
  List<Widget> _buildMetaItems() {
    final chips = <Widget>[];

    final developer = _hit.developer;
    if (developer != null && developer.isNotEmpty) {
      chips.add(_buildMetaItem(
          icon: Icons.business_rounded, text: developer));
    }

    // 发售日：与原生同款格式化（2024-01-15 → 2024年1月15日）
    final date = _hit.releaseDate;
    if (date != null && date.isNotEmpty) {
      String display;
      final match =
          RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date);
      if (match != null) {
        display =
            '${match.group(1)}年${int.parse(match.group(2)!)}月${int.parse(match.group(3)!)}日';
      } else {
        display = date;
      }
      chips.add(_buildMetaItem(icon: Icons.event_rounded, text: display));
    }

    if (_hit.rating > 0) {
      chips.add(_buildMetaItem(
        icon: Icons.star_rounded,
        text: _hit.rating.toStringAsFixed(1),
        iconColor: AppColors.starGold,
      ));
    }

    final votes = _hit.voteCount ?? 0;
    if (votes > 0) {
      chips.add(_buildMetaItem(
        icon: Icons.people_alt_rounded,
        text: _formatVoteCount(votes),
      ));
    }

    chips.add(_buildMetaItem(
      icon: Icons.language_rounded,
      text: _hit.source.displayName,
    ));

    return chips;
  }

  /// 单个元数据条目：图标 + 文字，次要色调（与原生 `_buildMetaItem` 一致）
  Widget _buildMetaItem({
    required IconData icon,
    required String text,
    Color? iconColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 13,
          color: iconColor ?? AppColors.secondaryText.withOpacity(0.6),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: AppStyles.bodyRegular.copyWith(
            fontSize: 12,
            color: AppColors.secondaryText.withOpacity(0.75),
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// 格式化投票数（与原生同款）：1000+ → 1.0k，10000+ → 10k
  String _formatVoteCount(int count) {
    if (count >= 10000) {
      return '${(count / 1000).toStringAsFixed(0)}k';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  /// 头部标签区：R18 徽章（如适用）+ 紧凑标签胶囊（与原生 `_buildHeaderTags`
  /// 同款）。tags 行由 header 固定占位，空标签时也要给个占位文案。
  Widget _buildTags() {
    final tags = _hit.tags;
    if (tags.isEmpty && !_hit.nsfw) {
      return Text(
        '暂无标签',
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 12,
          color: AppColors.secondaryText.withOpacity(0.7),
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (_hit.nsfw) _buildR18Pill(),
        for (final tag in tags.take(12)) _buildTag(tag),
      ],
    );
  }

  Widget _buildR18Pill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.selectedAccent.withOpacity(0.12),
        border: Border.all(color: AppColors.selectedAccent, width: 1),
      ),
      child: Text(
        'R18',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.selectedAccent,
        ),
      ),
    );
  }

  /// 紧凑标签胶囊（与原生 `_buildTag(compact: true)` 同款）
  Widget _buildTag(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Text(
        tag,
        overflow: TextOverflow.clip,
        style: AppStyles.bodyRegular.copyWith(fontSize: 12),
      ),
    );
  }

  // ==================== 左列：游戏简介 ====================

  /// 简介面板：容器/标题/正文样式与原生 `_buildDescription` 一致。
  /// 加载中 / 加载失败 / 无简介三种状态都在面板内呈现，不破坏两栏布局。
  Widget _buildDescription() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
          color: AppColors.placeholderBg,
          border: Border.all(color: AppColors.border, width: 2),
          boxShadow: [
            BoxShadow(
                color: AppColors.border.withOpacity(0.05),
                offset: const Offset(2, 3),
                blurRadius: 5)
          ]),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                padding: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: AppColors.placeholderCover, width: 2))),
                child: Text('游戏简介',
                    style: AppStyles.heading.copyWith(
                      fontSize: 19,
                      letterSpacing: 4,
                    ))),
            const SizedBox(height: 8),
            Expanded(
              child: _buildDescriptionBody(),
            ),
          ]),
    );
  }

  Widget _buildDescriptionBody() {
    if (_loadingDetail) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '正在获取 ${_hit.source.displayName} 详情…',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.secondaryText.withOpacity(0.8),
            ),
          ),
        ],
      );
    }

    if (_detailFailed) {
      return Center(
        child: GestureDetector(
          onTap: _loadDetail,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '详情加载失败 · 点击重试',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.selectedAccent,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final summary = _hit.summary;
    if (summary == null || summary.isEmpty) {
      return Text('暂无简介',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.secondaryText.withOpacity(0.6),
            fontStyle: FontStyle.italic,
          ));
    }

    return SingleChildScrollView(
      child: SelectableText(
        _stripMarkdown(summary),
        style: TextStyle(
          fontSize: 15,
          height: 24 / 15,
          color: AppColors.primaryText,
        ),
      ),
    );
  }

  /// 去掉站点简介里的 markdown 修饰（与原生同款清洗口径）
  String _stripMarkdown(String raw) {
    return raw
        .replaceAll(RegExp(r'\*\*\*(.+?)\*\*\*'), r'$1')
        .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
        .replaceAll(RegExp(r'\*(.+?)\*'), r'$1')
        .replaceAll(RegExp(r'~~(.+?)~~'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .trim();
  }

  // ==================== 右列：截图 ====================

  /// 截图区：与原生同款 `ScreenshotCarousel`（内部已走防盗链缓存管理器）。
  /// 🔴 `gameTitle` 刻意传 null —— 那个参数会挂到原生截图后台抓取服务
  /// （ScreenshotFetchService，按作品标题抓并回传 PB），站外作品不该触发它。
  Widget _buildScreenshotSection() {
    return ScreenshotCarousel(
      paths: _hit.screenshotUrls,
      isNetwork: true,
    );
  }

  // ==================== 动作 ====================

  /// 「获取 / 分享」→ 全站库资源面板（同一面板，差初始筛选项；用户拍板）。
  ///
  /// 锚定在操作行（`actionRowKey`）下方 —— 操作行六格已满、拿不到单独按钮
  /// 的 key，整行锚定与原生「获取浮层」的观感一致（贴下方 + 内部滚动）。
  void _openResourcePanel(SiteLibraryResourceMode mode) {
    final box =
        _actionRowKey.currentContext?.findRenderObject() as RenderBox?;
    final Rect anchor = (box != null && box.hasSize && box.size.width > 0)
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(100, 200, 400, 40);
    SiteLibraryResourcePanel.show(
      context: context,
      anchor: anchor,
      hit: _hit,
      mode: mode,
    );
  }

  /// 「补丁」→ 补丁站深色面板（PATCH-STATION 第二入口同款）。
  ///
  /// 🔴 鲲命中带 `catalogWorkId`（`siteId` 本身就是 catalog id）：补丁检索
  /// 跳过「标题→work id」身份解析直接锚定，零误配。2DFan 命中不带，照走
  /// 关键词解析路径（isConfident ≥ 0.8 才采信）。
  Future<void> _handlePatchTap() async {
    final box =
        _patchButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final Rect anchor = (box != null && box.hasSize && box.size.width > 0)
        ? box.localToGlobal(Offset.zero) & box.size
        : _actionAnchorRect();
    await PatchStationDarkPanel.show(
      context: context,
      anchor: anchor,
      game: PatchGameRef(
        // 站外作品没有 PB 记录 id；空串 = 缓存键退化为关键词维度
        id: '',
        title: _hit.title,
        aliasTitles: _headerAlias(),
        catalogWorkId: _hit.source == SiteSearchSource.moyu
            ? int.tryParse(_hit.siteId.trim())
            : null,
      ),
    );
  }

  /// 操作行的矩形（补丁按钮 key 拿不到时的兜底，与原生详情页一致）
  Rect _actionAnchorRect() {
    final box =
        _actionRowKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize && box.size.width > 0) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return const Rect.fromLTWH(100, 200, 400, 40);
  }

  /// 打开原站
  ///
  /// 统一走 [WebsiteBookmarkService.openExternal]（项目既有的零依赖系统调用，
  /// 探索大厅/详情页/补丁站都用它）。⛔ 不引入 url_launcher——本项目没装。
  /// `detailUrl` 是作品详情页直链：鲲 = `/galgame/{id}`（API work id 与网页
  /// id 同体系），2DFan = `/subjects/{id}`。id 缺失才兜底落到鲲站内搜索页。
  void _openSourceSite() {
    final url = _hit.detailUrl;
    if (url == null || url.isEmpty) return;
    WebsiteBookmarkService.openExternal(url);
  }
}
