import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../services/download_core.dart';
import '../../services/global_install_center.dart';
import '../../services/site_search/site_library_install_flow.dart';
import '../../services/site_search/site_library_resource_service.dart';
import '../../services/website_bookmark_service.dart';
import '../app_snack_bar.dart';
import '../game_detail/dark_surface.dart';

/// 全站库资源面板（SITE-LIBRARY，2026-11-13 用户拍板的「获取 / 分享」新语义）。
///
/// ## 术语
///
/// - **探索库** = 原生游戏库；**全站库** = 全站搜索结果总称（含探索库）。
/// - 全站库作品的「获取」= 对应站点的下载指令：letmoe 托管直链 + 「本体+补丁」
///   组合包，**直接走软件原生安装**（下载 → 解压 → 自动入库，见
///   [SiteLibraryInstallFlow]）；「分享」= 网盘下载（复制链接 + 提取码后外跳
///   浏览器——夸克/百度必须用他家客户端，软件内下不了）。
///
/// ## 结构
///
/// 与「获取（官方下载）」「分享（资源分享）」「补丁站」同款外壳：
/// 恒深色锚定栏（`DarkPalette`），`stickBelow: true`（🔴 高面板必须贴下方，
/// 默认的「放不下翻上去」会被顶进标题区——PATCH-STATION v5.1 的教训）。
///
/// 获取 / 分享是**两个互斥模式**（[SiteLibraryResourceMode]，2026-11-14 用户
/// 拍板「彻底分开、不可切换」）：获取只列直链资源、展开只见直链镜像；分享
/// 只列网盘资源、展开只见网盘镜像。⛔ 不再有「全部 / 可下载 / 网盘」chips。
///
/// ## 数据契约
///
/// - 资源列表：`letmoe/works/{id}/resources`（TTL 缓存，面板反复开关不重打）；
/// - 下载方式：`letmoe/resources/{id}/file` —— **官方 no-store + 下载计数**，
///   ⛔ 只在用户展开该资源时才调，绝不预取（`LetmoeResourceService` 已约定）。
class SiteLibraryResourcePanel extends StatefulWidget {
  const SiteLibraryResourcePanel({
    super.key,
    required this.hit,
    this.mode = SiteLibraryResourceMode.direct,
    this.initialContext,
    this.onClose,
  });

  final SiteSearchHit hit;

  /// 面板模式（获取 = 直链 / 分享 = 网盘）；同一部作品两种资源分开检索。
  final SiteLibraryResourceMode mode;

  /// 预注入的解析结果（探针/单测专用）：非 null 时**跳过网络解析**直接渲染。
  /// 生产路径恒为 null（面板自己经 [SiteLibraryResourceResolver] 拉取）。
  final SiteLibraryResourceContext? initialContext;

  final VoidCallback? onClose;

  /// 打开浮层（锚在「获取 / 分享」按钮所在操作行下方）。
  ///
  /// 🔴 `stickBelow: true`：资源卡展开后自然高度可观，1280×720 下必须贴下方
  /// 内部滚动，与补丁站深色面板同一观感。
  static Future<void> show({
    required BuildContext context,
    required Rect anchor,
    required SiteSearchHit hit,
    SiteLibraryResourceMode mode = SiteLibraryResourceMode.direct,
  }) {
    return showDarkAnchoredPanel<void>(
      context: context,
      anchor: anchor,
      preferredWidth: DarkPalette.shareListWidth,
      stickBelow: true,
      builder: (ctx) => SiteLibraryResourcePanel(
        hit: hit,
        mode: mode,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  @override
  State<SiteLibraryResourcePanel> createState() =>
      _SiteLibraryResourcePanelState();
}

/// 面板模式（用户 2026-11-14 拍板：**彻底分开、不可切换**）
///
/// - [direct] = 详情页「获取」：只列**有 letmoe 托管直链**的资源，展开后只显示
///   直链镜像（软件内下载）；
/// - [netdisk] = 详情页「分享」：只列**有网盘渠道**的资源，展开后只显示网盘
///   镜像（复制链接 + 提取码 + 外跳）。
///
/// ⛔ 不做「全部」视图：两种资源的用法完全不同（一个在本软件里下、一个必须
/// 去网盘客户端），混在一屏只会让人以为「获取」里那些夸克链接也能直接下。
enum SiteLibraryResourceMode { direct, netdisk }

class _SiteLibraryResourcePanelState extends State<SiteLibraryResourcePanel> {
  final SiteLibraryResourceResolver _resolver =
      SiteLibraryResourceResolver.instance;

  bool _loading = true;
  SiteLibraryResourceContext? _ctx;
  int _runId = 0;

  /// 行内展开的资源（resourceId；null = 全部收起）
  String? _expandedId;

  /// 每个已展开资源的下载方式（懒加载，⛔ 不预取）
  final Map<String, LetmoeResourceFiles> _files = <String, LetmoeResourceFiles>{};
  final Set<String> _filesLoading = <String>{};
  final Set<String> _filesFailed = <String>{};

  /// 已提交安装的镜像 id（mirrorId）：
  /// 只用于按钮态，真正的下载/解压进度在左下角任务按钮与安装中心——
  /// 直链下载接原生安装后，进度由安装中心的单一活动实例统一持有
  /// （顺带根治了「关面板再点会新建 DownloadCore，两条实例争写同名分片」）。
  final Set<String> _installSubmitted = <String>{};

  /// 本 State 已绑定监听的镜像 id（重开面板时同一任务要重新挂监听）
  final Set<String> _boundDownloads = <String>{};

  /// 复制成功的按钮 key → 时间戳（1.2s 后还原「已复制」态）
  final Map<String, DateTime> _copiedAt = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    // 安装失败/完成（相位回到 idle 或 failed）后复位「已提交安装」，
    // 否则按钮会一直灰着，用户没法重试。
    GlobalInstallCenter.instance.addListener(phase: _onInstallPhase);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reload();
    });
  }

  void _onInstallPhase(InstallPhase phase) {
    if (!mounted) return;
    if (phase != InstallPhase.idle && phase != InstallPhase.failed) return;
    if (_installSubmitted.isEmpty) return;
    setState(_installSubmitted.clear);
  }

  @override
  void dispose() {
    GlobalInstallCenter.instance.removeListener(phase: _onInstallPhase);
    // 只摘监听、⛔ 不 cancel：用户关面板不应该掐掉已经下到一半的大包。
    // 下载任务本体放在进程级表 [_siteDownloadTasks] 里，重开面板能接上同一条。
    for (final id in _boundDownloads) {
      _siteDownloadTasks[id]?.core.removeAllListeners();
    }
    _boundDownloads.clear();
    _revertTimer?.cancel();
    super.dispose();
  }

  Future<void> _reload({bool forceRefresh = false}) async {
    // 探针注入：不走网络，直接渲染夹具（reload/刷新也回到同一份注入数据）
    final injected = widget.initialContext;
    if (injected != null) {
      setState(() {
        _ctx = injected;
        _loading = false;
        _expandedId = null;
        _files.clear();
        _filesLoading.clear();
        _filesFailed.clear();
      });
      return;
    }
    final runId = ++_runId;
    setState(() {
      _loading = true;
    });
    final ctx = await _resolver.resolve(
      widget.hit,
      forceRefresh: forceRefresh,
    );
    if (!mounted || runId != _runId) return;
    setState(() {
      _ctx = ctx;
      _loading = false;
      _expandedId = null;
      _files.clear();
      _filesLoading.clear();
      _filesFailed.clear();
    });
  }

  Timer? _revertTimer;
  void _markCopied(String key) {
    setState(() => _copiedAt[key] = DateTime.now());
    _revertTimer?.cancel();
    _revertTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _copiedAt.remove(key));
    });
  }

  bool _isCopied(String key) => _copiedAt.containsKey(key);

  void _copy(String key, String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    _markCopied(key);
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return DarkShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          Flexible(
            child: _loading
                ? _buildLoadingBody()
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  // ---------------- 头部 ----------------

  Widget _buildHeader() {
    final source = widget.hit.source;
    final direct = widget.mode == SiteLibraryResourceMode.direct;
    final total = _ctx == null ? 0 : _modeResources(_ctx!.resources).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DarkPalette.border, width: 1)),
      ),
      child: Row(
        children: [
          Text(
            direct ? '下载并安装' : '网盘分享',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: DarkPalette.textPrimary,
            ),
          ),
          if (total > 0) ...[
            const SizedBox(width: 8),
            DarkBadge.plain(
              label: '$total 条',
              background: direct
                  ? DarkPalette.badgeGreenBg
                  : DarkPalette.badgeBlueBg,
              foreground: direct ? DarkPalette.green : DarkPalette.lightBlue,
            ),
          ],
          const SizedBox(width: 10),
          DarkBadge.plain(
            label: '数据来自 ${source.displayName}',
            background: DarkPalette.badgeNeutralBg,
            foreground: DarkPalette.textDim,
          ),
          const Spacer(),
          DarkGhostButton(
            label: _isCopied('refresh') ? '已刷新' : '刷新',
            fontSize: 12,
            onTap: _loading ? null : () => _reload(forceRefresh: true),
          ),
          const SizedBox(width: 4),
          DarkCloseButton(onTap: widget.onClose ?? () {}),
        ],
      ),
    );
  }

  // ---------------- 主体状态 ----------------

  Widget _buildLoadingBody() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
          const SizedBox(height: 12),
          Text(
            '正在检索全站库资源…',
            style: TextStyle(fontSize: 13, color: DarkPalette.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final ctx = _ctx;
    if (ctx == null) return const SizedBox.shrink();

    // 2DFan 命中未能定位到 catalog 作品 → 获取/分享无从谈起，兜底外跳
    if (!ctx.resolved) {
      return _buildStateBody(
        icon: Icons.travel_explore_rounded,
        title: '未能在鲲生态定位到这部作品',
        detail: '「获取 / 分享」依赖鲲生态（letmoe）的官方资源链接；'
            '2DFan 命中需要标题精确反查，这部作品没有可信匹配。\n'
            '补丁不受影响（走 2DFan 关键词检索），也可以去原站找资源。',
        actionLabel: '打开 2DFan 作品页',
        onAction: _openSourceSite,
      );
    }

    if (ctx.resources.isEmpty) {
      return _buildStateBody(
        icon: Icons.inventory_2_outlined,
        title: '该作品暂无资源',
        detail: '已在鲲生态（letmoe）定位到本作品（work id ${ctx.workId}），'
            '但目前还没有收录游戏本体资源。可以稍后再试，或去网页端查看。',
        actionLabel: '打开 letmoe 页面',
        onAction: () => WebsiteBookmarkService.openExternal(
          'https://www.letmoe.com/game/${ctx.workId}',
        ),
      );
    }

    final direct = widget.mode == SiteLibraryResourceMode.direct;
    final filtered = _modeResources(ctx.resources);
    if (filtered.isEmpty) {
      // 两模式彻底分开（用户拍板）：这里必须明确告诉用户「另一种资源存在，
      // 但要去另一个入口」，否则会以为这部作品根本没有资源。
      final hasOther = direct
          ? ctx.resources.any((r) => r.hasNetdiskProviders)
          : ctx.resources.any((r) => r.directDownload);
      return _buildStateBody(
        icon: direct
            ? Icons.cloud_download_outlined
            : Icons.share_outlined,
        title: direct ? '没有可直链下载的资源' : '没有网盘资源',
        detail: hasOther
            ? (direct
                ? 'letmoe 上这部作品只有网盘资源。关掉本面板后点「分享」，'
                    '复制网盘链接 + 提取码去对应客户端下载。'
                : 'letmoe 上这部作品只提供直链。关掉本面板后点「获取」，'
                    '可以由本软件直接下载、解压并自动入库。')
            : 'letmoe 上这部作品暂时没有收录游戏本体资源。',
        actionLabel: '打开 letmoe 页面',
        onAction: () => WebsiteBookmarkService.openExternal(
          'https://www.letmoe.com/game/${ctx.workId}',
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in filtered) ...[
            _buildResourceCard(r),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  /// 当前模式下的资源（获取 = 有直链 / 分享 = 有网盘）。
  ///
  /// 依据是列表端点的 `direct_download` / `providers` 摘要字段——只为**挑资源**，
  /// 具体镜像仍在展开时由 `/file` 决定（⛔ 不预取、不缓存）。
  ///
  /// 🔴 「分享」用 [LetmoeResource.hasNetdiskProviders] 而不是
  /// `providers.isNotEmpty`：纯直链资源的 providers 是占位值 `['direct']`，
  /// 按非空判定会被网盘模式误收（展开后一条链接都没有）。
  List<LetmoeResource> _modeResources(List<LetmoeResource> all) {
    switch (widget.mode) {
      case SiteLibraryResourceMode.direct:
        return all.where((r) => r.directDownload).toList();
      case SiteLibraryResourceMode.netdisk:
        return all.where((r) => r.hasNetdiskProviders).toList();
    }
  }

  /// 当前模式下的镜像（获取 = 托管直链 + 组合包；分享 = 真网盘外链）
  List<LetmoeMirror> _modeMirrors(LetmoeResourceFiles files) {
    switch (widget.mode) {
      case SiteLibraryResourceMode.direct:
        // downloadableArchives 已把「本体+汉化补丁」组合包算进来——它是
        // dl.imoe.uk 托管直链，最该走原生安装的一类（一步到位）。
        return files.downloadableArchives;
      case SiteLibraryResourceMode.netdisk:
        return files.netdiskLinks;
    }
  }

  Widget _buildStateBody({
    required IconData icon,
    required String title,
    required String detail,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: DarkPalette.textMuted),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: DarkPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: DarkPalette.textMuted,
            ),
          ),
          const SizedBox(height: 14),
          DarkPrimaryButton(label: actionLabel, onTap: onAction),
        ],
      ),
    );
  }

  // ---------------- 资源卡 ----------------

  Widget _buildResourceCard(LetmoeResource r) {
    final expanded = _expandedId == r.id;
    final direct = widget.mode == SiteLibraryResourceMode.direct;
    return DarkCard(
      background: DarkPalette.linkCardBg,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  r.title.isEmpty ? '（未命名资源）' : r.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                    color: DarkPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DarkPrimaryButton(
                label: expanded
                    ? '收起'
                    : (direct ? '直链下载' : '查看网盘'),
                background: expanded
                    ? DarkPalette.badgeNeutralBg
                    : DarkPalette.primaryBlue,
                foreground:
                    expanded ? DarkPalette.textSecondary : Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                fontSize: 12,
                onTap: () => _toggleResource(r),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              // 角标只展示**本模式相关**的信息：获取面板里列一堆「夸克网盘」
              // 会让人以为点了就能在软件里下（用户 2026-11-14 的反馈）。
              if (direct)
                DarkBadge.plain(
                  label: '可直链下载',
                  background: DarkPalette.badgeGreenBg,
                  foreground: DarkPalette.green,
                )
              else
                for (final p in r.providers.take(4))
                  DarkBadge.plain(
                    label: _providerName(p),
                    background: DarkPalette.badgeBlueBg,
                    foreground: DarkPalette.lightBlue,
                  ),
              if (r.size.isNotEmpty)
                DarkBadge.plain(
                  label: r.size,
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textDim,
                ),
              for (final pf in r.platform.take(3))
                DarkBadge.plain(
                  label: pf.toUpperCase(),
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textDim,
                ),
              if (r.mirrorCount > 0)
                DarkBadge.plain(
                  label: '${r.mirrorCount} 个下载方式',
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textDim,
                ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 10),
            _buildExpandedBody(r),
          ],
        ],
      ),
    );
  }

  /// 展开体：懒加载 /file（⛔ 官方 no-store，点开才算一次下载）
  Widget _buildExpandedBody(LetmoeResource r) {
    if (_filesLoading.contains(r.id)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              '正在解析下载方式…',
              style: TextStyle(fontSize: 12.5, color: DarkPalette.textMuted),
            ),
          ],
        ),
      );
    }
    if (_filesFailed.contains(r.id)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: DarkGhostButton(
          label: '解析失败 · 点击重试',
          foreground: DarkPalette.yellow,
          onTap: () => _loadFiles(r),
        ),
      );
    }
    final files = _files[r.id];
    if (files == null) return const SizedBox.shrink();

    final mirrors = _modeMirrors(files);
    if (mirrors.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          widget.mode == SiteLibraryResourceMode.direct
              ? '这条资源没有可用的直链（网盘渠道请用「分享」）'
              : '这条资源没有可用的网盘链接',
          style: TextStyle(fontSize: 12.5, color: DarkPalette.textMuted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in mirrors) ...[
          _buildMirrorRow(r, m),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Future<void> _toggleResource(LetmoeResource r) async {
    if (_expandedId == r.id) {
      setState(() => _expandedId = null);
      return;
    }
    setState(() => _expandedId = r.id);
    if (!_files.containsKey(r.id) && !_filesFailed.contains(r.id)) {
      await _loadFiles(r);
    }
  }

  Future<void> _loadFiles(LetmoeResource r) async {
    setState(() {
      _filesLoading.add(r.id);
      _filesFailed.remove(r.id);
    });
    final files = await LetmoeResourceService().getResourceFile(r.id);
    if (!mounted) return;
    setState(() {
      _filesLoading.remove(r.id);
      _files[r.id] = files;
      // 完全空结果视为失败（可重试），有内容才算成功
      if (files.mirrors.isEmpty && files.composites.isEmpty) {
        _filesFailed.add(r.id);
      }
    });
  }

  // ---------------- 镜像行 ----------------

  Widget _buildMirrorRow(LetmoeResource r, LetmoeMirror m) {
    final isExternal = m.isExternalLink;
    // 任务表是进程级的（同一镜像只有一个 DownloadCore），这里只查不建
    final download = isExternal ? null : _siteDownloadTasks[m.id];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DarkPalette.bg,
        borderRadius: BorderRadius.circular(DarkPalette.radiusField),
        border: Border.all(color: DarkPalette.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DarkBadge.plain(
                label: isExternal
                    ? _providerName(m.provider)
                    : '直链下载',
                background:
                    isExternal ? DarkPalette.badgeBlueBg : DarkPalette.badgeGreenBg,
                foreground:
                    isExternal ? DarkPalette.lightBlue : DarkPalette.green,
              ),
              if (m.isComposite) ...[
                const SizedBox(width: 6),
                DarkBadge.plain(
                  label: '本体+汉化',
                  background: DarkPalette.badgeGreenBg,
                  foreground: DarkPalette.green,
                ),
              ],
              if (m.isPrimary) ...[
                const SizedBox(width: 6),
                DarkBadge.plain(
                  label: '主镜像',
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textDim,
                ),
              ],
              const Spacer(),
              if (isExternal) ...[
                DarkGhostButton(
                  label: _isCopied('link-${m.id}') ? '已复制' : '复制链接',
                  fontSize: 12,
                  onTap: () => _copy(
                    'link-${m.id}',
                    m.url,
                  ),
                ),
                DarkGhostButton(
                  label: '打开网盘',
                  foreground: DarkPalette.lightBlue,
                  fontSize: 12,
                  onTap: () => WebsiteBookmarkService.openExternal(m.url),
                ),
              ] else
                _buildGetAction(r, m, download),
            ],
          ),
          // 组合包自带补丁名：说清「这一份装完就带汉化」，用户不用再跑补丁站
          if (m.isComposite && m.patchName.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '内含补丁：${m.patchName}',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: DarkPalette.textDim,
              ),
            ),
          ],
          if (m.extractCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildSecretRow(
              key: 'code-${m.id}',
              label: '提取码',
              value: m.extractCode,
            ),
          ],
          if (m.archivePassword.isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildSecretRow(
              key: 'pwd-${m.id}',
              label: '解压密码',
              value: m.archivePassword,
            ),
          ],
          if (m.note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              m.note,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: DarkPalette.textDim,
              ),
            ),
          ],
          if (!isExternal && r.isGame && _installSubmitted.contains(m.id)) ...[
            const SizedBox(height: 8),
            _buildInstallSubmittedHint(),
          ],
          if (!isExternal && !r.isGame && download != null) ...[
            const SizedBox(height: 8),
            _buildDownloadProgress(r, download),
          ],
        ],
      ),
    );
  }

  Widget _buildSecretRow({
    required String key,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Text(
          '$label：',
          style: TextStyle(fontSize: 12, color: DarkPalette.textDim),
        ),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: DarkPalette.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        DarkGhostButton(
          label: _isCopied(key) ? '已复制' : '复制',
          fontSize: 11.5,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          onTap: () => _copy(key, value),
        ),
      ],
    );
  }

  // ---------------- 获取：原生安装 / 纯下载 ----------------

  /// 「获取」按钮的两种语义（2026-11-14 用户拍板 A 案）：
  ///
  /// - **游戏本体**（`type == game`）→ 「下载并安装」：交给安装中心跑
  ///   下载 → 解压 → 自动入库，进度在左下角任务按钮。⛔ 不再有「仅下载到
  ///   本地」——用户的原话是「使用我们软件的原生安装功能」。
  /// - **非本体**（特典 / 广播剧 / 补丁包）→ 「下载到本地」：包内没有可执行
  ///   本体，进安装管线会触发「未找到本体」决策弹窗，只下到缓存目录。
  Widget _buildGetAction(
      LetmoeResource r, LetmoeMirror m, _SiteDownloadTask? task) {
    if (r.isGame) {
      final submitted = _installSubmitted.contains(m.id);
      return DarkPrimaryButton(
        label: submitted ? '已提交安装' : '下载并安装',
        background:
            submitted ? DarkPalette.badgeNeutralBg : DarkPalette.actionBlue,
        foreground: submitted ? DarkPalette.textSecondary : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        fontSize: 12,
        busy: false,
        onTap: submitted ? null : () => _startInstall(r, m),
      );
    }

    final busy = task != null && task.status == DownloadStatus.downloading;
    if (task?.status == DownloadStatus.completed) {
      return DarkGhostButton(
        label: '重新下载',
        fontSize: 12,
        onTap: () => _startLocalDownload(r, m),
      );
    }
    return DarkPrimaryButton(
      label: busy ? '下载中…' : (task != null ? '续传下载' : '下载到本地'),
      background: DarkPalette.actionBlue,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      fontSize: 12,
      busy: false,
      onTap: busy ? null : () => _startLocalDownload(r, m),
    );
  }

  /// 游戏本体 → 原生安装（下载 + 解压 + 入库）。
  Future<void> _startInstall(LetmoeResource r, LetmoeMirror m) async {
    final result = await SiteLibraryInstallFlow.submit(
      context: context,
      hit: widget.hit,
      resource: r,
      mirror: m,
    );
    if (!mounted) return;

    switch (result) {
      case SiteLibraryInstallResult.submitted:
        setState(() => _installSubmitted.add(m.id));
        AppSnackBar.success(
          context,
          '已提交安装：下载 → 解压 → 自动入库，进度见左下角任务按钮',
        );
        break;
      case SiteLibraryInstallResult.duplicate:
        AppSnackBar.info(context, '这部作品已经在安装队列中，请等它装完');
        break;
      case SiteLibraryInstallResult.linkFailed:
        AppSnackBar.error(context, '下载地址无效（仅支持 http/https）');
        break;
      case SiteLibraryInstallResult.cancelled:
        break;
    }
  }

  /// 非本体资源 → 只下载到缓存目录（不进安装管线）。
  ///
  /// 任务放进进程级表 [_siteDownloadTasks]：同一镜像永远只有一个
  /// DownloadCore，关面板再点不会新建实例争写同名分片。
  Future<void> _startLocalDownload(LetmoeResource r, LetmoeMirror m) async {
    final existing = _siteDownloadTasks[m.id];
    if (existing != null && existing.status == DownloadStatus.downloading) {
      return;
    }

    // 🔴 安全闸：下载 URL 来自远端 API（可能被污染/被劫持），⛔ 不能直接喂给
    // HttpClient——只放行 http/https，file:// / 自定义 scheme 一律拒绝并就地报错。
    final uri = Uri.tryParse(m.url);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (uri == null || (scheme != 'http' && scheme != 'https')) {
      AppSnackBar.error(context, '下载地址无效（仅支持 http/https）');
      return;
    }

    final workId = _ctx?.workId ?? 0;
    final task = _SiteDownloadTask(mirrorId: m.id);
    _siteDownloadTasks[m.id] = task;
    // 新实例 = 新 core，旧监听随旧实例作废
    _boundDownloads.remove(m.id);
    _bindTask(task);
    setState(() {});

    // autoExtract = false：只下载到缓存目录，完成由用户手动导入。
    // ★ DL-SINGLE-STREAM：非本体资源同样走单连接（与本体的「下载并安装」
    //   保持一致），不留分片碎片，也没有分片合并失败这一类故障面。
    await task.core.start(
      url: m.url,
      gameId: 'site-$workId-r${r.id}',
      fileName: null,
      title: r.title,
      autoExtract: false,
      preferSingleStream: true,
    );
  }

  /// 把本 State 挂到进程级任务上（重开面板时同一条任务要重新挂监听）
  void _bindTask(_SiteDownloadTask task) {
    if (!_boundDownloads.add(task.mirrorId)) return;
    task.core.addStatusListener((s) {
      if (!mounted) return;
      setState(() => task.status = s);
    });
    task.core.addProgressListener((p) {
      if (!mounted) return;
      setState(() => task.progress = p);
    });
    task.core.addErrorListener((msg) {
      if (!mounted) return;
      setState(() => task.error = msg);
    });
    task.core.addCompleteListener((path) {
      if (!mounted) return;
      setState(() => task.savedPath = path);
    });
  }

  /// 「已提交安装」提示行：进度不在这里画，指到左下角任务按钮
  Widget _buildInstallSubmittedHint() {
    return Row(
      children: [
        Icon(Icons.download_done_rounded, size: 14, color: DarkPalette.green),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '已提交安装：下载 → 解压 → 自动入库，进度见左下角任务按钮',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: DarkPalette.green),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadProgress(
      LetmoeResource r, _SiteDownloadTask task) {
    final p = task.progress;
    final status = task.status;

    if (status == DownloadStatus.completed) {
      final path = task.savedPath ?? '';
      return Row(
        children: [
          Icon(Icons.check_circle_outline_rounded,
              size: 14, color: DarkPalette.green),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '已保存到 $path（可在「添加游戏」时导入）',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: DarkPalette.green),
            ),
          ),
          DarkGhostButton(
            label: _isCopied('path-${r.id}') ? '已复制' : '复制路径',
            fontSize: 11.5,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            onTap: () => _copy('path-${r.id}', path),
          ),
        ],
      );
    }

    if (status == DownloadStatus.failed) {
      return Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: DarkPalette.yellow),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              task.error ?? '下载失败',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: DarkPalette.yellow),
            ),
          ),
        ],
      );
    }

    if (status == DownloadStatus.cancelled) {
      return Text(
        '已取消',
        style: TextStyle(fontSize: 12, color: DarkPalette.textMuted),
      );
    }

    final percent = p?.percent ?? 0;
    final speed = p?.speed ?? '';
    final received = p?.downloadedBytes ?? 0;
    final total = p?.totalBytes ?? 0;
    final msg = p?.statusMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: total > 0 ? (percent / 100).clamp(0.0, 1.0) : null,
                  minHeight: 4,
                  backgroundColor: DarkPalette.badgeNeutralBg,
                  valueColor:
                      AlwaysStoppedAnimation(DarkPalette.primaryBlue),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${percent.toStringAsFixed(1)}%  $speed',
              style: TextStyle(fontSize: 12, color: DarkPalette.textBody),
            ),
            const SizedBox(width: 8),
            DarkGhostButton(
              label: '取消',
              foreground: DarkPalette.textMuted,
              fontSize: 12,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              onTap: task.core.cancel,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          msg ??
              '${_fmtBytes(received)} / ${_fmtBytes(total)}'
              ' · 下载到软件缓存目录，完成后可导入',
          style: TextStyle(fontSize: 11.5, color: DarkPalette.textMuted),
        ),
      ],
    );
  }

  // ---------------- 动作 ----------------

  void _openSourceSite() {
    final url = widget.hit.detailUrl;
    if (url == null || url.isEmpty) return;
    WebsiteBookmarkService.openExternal(url);
  }

  // ---------------- 工具 ----------------

  String _providerName(String raw) {
    switch (raw.toLowerCase()) {
      case 'quark':
        return '夸克网盘';
      case 'baidu':
        return '百度网盘';
      case 'aliyun':
      case 'alipan':
        return '阿里云盘';
      case 'uc':
        return 'UC 网盘';
      case 'xunlei':
        return '迅雷网盘';
      case '123':
        return '123 网盘';
      case 'magnet':
        return '磁力链接';
      case 'direct':
        return '直链';
      default:
        return raw.isEmpty ? '网盘' : raw;
    }
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}

/// 进程级「站外直链 → 本地缓存」下载任务表（mirrorId → 任务）。
///
/// 🔴 旧实现把任务放在 State 里：关面板再点会新建一个 [DownloadCore]，两条
/// 实例对**同名 `.part_N.tmp`** 并发写 ⇒ 分片互相踩、文件必然损坏。改为
/// 进程级表后，同一镜像永远只有一个 core，重开面板能接上同一条任务。
final Map<String, _SiteDownloadTask> _siteDownloadTasks =
    <String, _SiteDownloadTask>{};

/// 面板内跟踪的一个软件内下载任务（letmoe 托管直链，非本体资源专用）。
class _SiteDownloadTask {
  _SiteDownloadTask({required this.mirrorId}) : core = DownloadCore();

  /// 镜像 id（注册表键）
  final String mirrorId;

  final DownloadCore core;
  DownloadStatus status = DownloadStatus.idle;
  DownloadProgress? progress;
  String? error;
  String? savedPath;
}
