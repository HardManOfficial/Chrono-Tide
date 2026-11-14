import 'package:flutter/material.dart';

import '../../models/patch_resource.dart';
import '../../services/patch/patch_download_service.dart';
import '../../services/patch/patch_save_location.dart';
import '../../services/patch/patch_search_service.dart';
import '../../services/website_bookmark_service.dart';
import '../game_detail/dark_surface.dart';
import 'patch_delivery_loader.dart';
import 'patch_download_confirm.dart';
import 'patch_site_logo.dart';
import 'patch_station_panel.dart' show PatchGameRef;

/// 详情页「补丁」浮层（PATCH-STATION 第二入口，恒深色锚定栏）。
///
/// ## 为什么与探索库那块长得不一样
///
/// 用户定调：详情页的「补丁」应该和旁边的「获取（官方下载）」「分享（资源
/// 分享）」**同款面板** —— 那三个是恒深色的锚定栏（`DarkPalette`，不跟主题）。
/// 探索库那块是页面内的浅色大下拉条，两者外壳不同但**数据、卡片语义、
/// 详情浮层、下载链路完全共用**。
///
/// ## 锁定态
///
/// 这里只出**当前这一部作品**的补丁。锚定对象由详情页决定，⛔ 不提供
/// 「换一部作品」—— 用户想换就去探索库那个入口。
class PatchStationDarkPanel extends StatefulWidget {
  const PatchStationDarkPanel({
    super.key,
    required this.game,
    this.onClose,
  });

  final PatchGameRef game;
  final VoidCallback? onClose;

  /// 打开浮层（锚在「补丁」按钮下方，宽度对齐资源分享栏）
  ///
  /// 🔴 `stickBelow: true`（v5.1）：这块面板自然高 ~530px，1280×720 下按钮
  /// 下方只剩 ~360px，若走默认的「放不下就翻到上方」，整块会被顶到标题区上，
  /// 看起来像"点击后弹到上面去了"。打开后高度上限＝按钮下方剩余空间，
  /// 面板自己内部滚动，位置恒在按钮之下（与「获取 / 分享」同一观感）。
  static Future<void> show({
    required BuildContext context,
    required Rect anchor,
    required PatchGameRef game,
  }) {
    return showDarkAnchoredPanel<void>(
      context: context,
      anchor: anchor,
      preferredWidth: DarkPalette.shareListWidth,
      stickBelow: true,
      builder: (ctx) => PatchStationDarkPanel(
        game: game,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  @override
  State<PatchStationDarkPanel> createState() => _PatchStationDarkPanelState();
}

class _PatchStationDarkPanelState extends State<PatchStationDarkPanel> {
  bool _loading = true;
  PatchQueryResult? _result;
  String? _error;
  PatchSite? _activeSite;
  int _runId = 0;

  /// 行内展开的补丁（null = 全部收起）
  String? _expandedKey;

  /// 每条补丁上一次实际用过的直链（key → url）。
  /// 2DFan 的直链只存在于展开时解析出来的详情里，「重试」需要它。
  final Map<String, String> _lastDirectUrl = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runSearch();
    });
  }

  Future<void> _runSearch({bool forceRefresh = false}) async {
    if (!mounted) return;
    final runId = ++_runId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await PatchSearchService().search(
        keyword: widget.game.title,
        gameId: widget.game.id,
        candidateTitles: widget.game.candidateTitles,
        // SITE-LIBRARY 全站库命中：workId 已知，跳过身份解析直接锚定
        knownWorkId: widget.game.catalogWorkId,
        forceRefresh: forceRefresh,
      );
      if (!mounted || runId != _runId) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || runId != _runId) return;
      setState(() {
        _error = '检索失败：$e';
        _loading = false;
      });
    }
  }

  Future<String?> _storedDir() async {
    try {
      return await PatchSaveLocation.instance.stored();
    } catch (_) {
      return null;
    }
  }

  /// [directUrl] 是展开位刚解析到的真实直链（2DFan 兑换后才有；
  /// 模型里的 `directUrl` 对 2DFan 恒为空）。
  Future<void> _startDownload(PatchResource r, {String? directUrl}) async {
    final url =
        (directUrl ?? _lastDirectUrl[r.key] ?? r.directUrl ?? '').trim();
    if (url.isNotEmpty) _lastDirectUrl[r.key] = url;
    final target = url.isEmpty
        ? r
        : r.copyWith(delivery: PatchDelivery.direct, directUrl: url);
    final initial = await _storedDir();
    if (!mounted) return;
    final dir = await PatchDownloadConfirm.show(
      context: context,
      resource: target,
      initialDir: initial,
    );
    if (dir == null) return;
    try {
      await PatchSaveLocation.instance.set(dir);
    } catch (_) {
      // 记不住不影响本次下载
    }
    await PatchDownloadService.instance.download(target, saveDir: dir);
  }

  /// 点「查看下载」→ **行内展开**（与浅色横条同一套语义，不另开窗口）
  void _toggleExpand(PatchResource r) {
    setState(() {
      _expandedKey = _expandedKey == r.key ? null : r.key;
    });
  }

  List<PatchResource> _visible() {
    final result = _result;
    if (result == null) return const <PatchResource>[];
    final site = _activeSite;
    if (site == null) return result.resources;
    return result.resources.where((r) => r.site == site).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DarkShell(
      width: DarkPalette.shareListWidth,
      padding: const EdgeInsets.fromLTRB(12, 13, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 10),
          _buildSiteTabs(),
          const SizedBox(height: 10),
          Flexible(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Row(
        children: [
          const Text(
            '补丁站',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: DarkPalette.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              widget.game.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: DarkPalette.textMuted,
              ),
            ),
          ),
          const Spacer(),
          DarkGhostButton(
            label: '刷新',
            onTap: _loading ? null : () => _runSearch(forceRefresh: true),
            foreground: DarkPalette.textDim,
            fontSize: 11,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (widget.onClose != null)
            DarkGhostButton(
              label: '关闭',
              onTap: widget.onClose,
              foreground: DarkPalette.textMuted,
              fontSize: 11,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }

  Widget _buildSiteTabs() {
    final counts = _result?.countsBySite ?? const <PatchSite, int>{};
    final failures = _result?.failures ?? const <PatchSite, String>{};
    final total = _result?.resources.length ?? 0;

    final chips = <Widget>[
      _chip(
        site: null,
        label: '全部',
        count: total,
        active: _activeSite == null,
        onTap: () => setState(() => _activeSite = null),
      ),
      for (final s in PatchSite.values)
        _chip(
          site: s,
          label: s.displayName,
          count: counts[s] ?? 0,
          active: _activeSite == s,
          failed: failures.containsKey(s),
          onTap: () => setState(() => _activeSite = s),
        ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            chips[i],
          ],
        ],
      ),
    );
  }

  Widget _chip({
    required PatchSite? site,
    required String label,
    required int count,
    required bool active,
    required VoidCallback onTap,
    bool failed = false,
  }) {
    final accent = site == null
        ? DarkPalette.primaryBlue
        : PatchSiteLogo.colorOf(site, onDark: true);
    final fg = failed
        ? DarkPalette.pink
        : (active ? DarkPalette.textPrimary : DarkPalette.textMuted);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color:
                active ? accent.withOpacity(0.16) : DarkPalette.badgeNeutralBg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? accent.withOpacity(0.7)
                  : DarkPalette.cardBorder.withOpacity(0.7),
              width: active ? 1 : 0.6,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (site != null) ...[
                PatchSiteLogo(site: site, size: 12, onDark: true),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                ),
              ),
              if (count > 0 || failed) ...[
                const SizedBox(width: 4),
                Text(
                  failed ? '!' : '$count',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: (failed ? DarkPalette.pink : fg).withOpacity(0.8),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _result == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 30),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(DarkPalette.primaryBlue),
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return _empty(_error!);
    }
    final result = _result;
    if (result == null) {
      return _empty('正在准备…');
    }
    final items = _visible();
    if (items.isEmpty) {
      return _empty(result.allFailed
          ? '所有补丁源都不可用'
          : (_activeSite == null
              ? '这部作品暂时没有补丁'
              : '${_activeSite!.displayName} 没有这部作品的补丁'));
    }
    // 🔴 降级提示行必须放进滚动内容里当**首项**，⛔ 不能再包一层 Column：
    // 贴下方模式下可用高只有按钮下方那点空间，包一层 Column 会让列表变成
    // 非弹性子项（拿到的是无界高度）→ 既压不下去也滚不动，直接溢出。
    return _buildList(
      items,
      leading: result.hasAnyFailure ? _failureLine(result) : null,
    );
  }

  Widget _failureLine(PatchQueryResult result) {
    final text = result.failures.entries
        .map((e) => '${e.key.displayName}：${e.value}')
        .join('；');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: DarkPalette.pink.withOpacity(0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10,
          height: 1.4,
          color: DarkPalette.pink,
        ),
      ),
    );
  }

  Widget _buildList(List<PatchResource> items, {Widget? leading}) {
    return ConstrainedBox(
      // 与资源分享栏一致：超过 3 条即内部滚动，浮层不无限长。
      // 贴下方模式下外层的 maxHeight 更小，ConstrainedBox 会被父约束收紧，
      // 所以这里只是「自然高度的上限」，不是硬性占用。
      constraints: const BoxConstraints(maxHeight: 430),
      child: AnimatedBuilder(
        animation: PatchDownloadService.instance,
        builder: (_, __) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(height: 8),
              ],
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _PatchRow(
                  resource: items[i],
                  download: PatchDownloadService.instance.stateOf(
                    items[i].key,
                  ),
                  expanded: _expandedKey == items[i].key,
                  onOpenInfo: () => _toggleExpand(items[i]),
                  onCollapse: () => _toggleExpand(items[i]),
                  onOpenPage: items[i].webUrl.trim().isEmpty
                      ? null
                      : () => WebsiteBookmarkService.openExternal(
                            items[i].webUrl,
                          ),
                  onDownload: () => _startDownload(items[i]),
                  onDownloadDirect: (url) =>
                      _startDownload(items[i], directUrl: url),
                  onCancel: PatchDownloadService.instance.cancel,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            color: DarkPalette.textMuted,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

/// 单条补丁行（深色）：图标 + 标题 + 元信息 + [查看下载][原页] / 下载进度
class _PatchRow extends StatelessWidget {
  const _PatchRow({
    required this.resource,
    required this.onOpenInfo,
    required this.onDownload,
    this.onDownloadDirect,
    this.onOpenPage,
    this.onCancel,
    this.onCollapse,
    this.download,
    this.expanded = false,
  });

  final PatchResource resource;

  /// 行内展开状态（true 时把下载详情铺在本行里）
  final bool expanded;

  final VoidCallback? onOpenInfo;
  final VoidCallback? onCollapse;
  final VoidCallback? onDownload;

  /// 展开位里点「下载」：带投递详情解析出来的真实直链
  final Future<void> Function(String url)? onDownloadDirect;
  final VoidCallback? onOpenPage;
  final VoidCallback? onCancel;
  final PatchDownloadState? download;

  @override
  Widget build(BuildContext context) {
    final r = resource;
    final dl = download;
    final running = dl != null && dl.phase != PatchDownloadPhase.idle;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
      decoration: BoxDecoration(
        color: DarkPalette.badgeNeutralBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: expanded ? DarkPalette.primaryBlue : DarkPalette.cardBorder,
          width: expanded ? 1 : 0.6,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PatchSiteLogo(site: r.site, size: 22, onDark: true),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: DarkPalette.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _metaLine(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: DarkPalette.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (expanded)
                DarkGhostButton(
                  label: '收起',
                  onTap: onCollapse,
                  foreground: DarkPalette.textDim,
                  fontSize: 10.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                )
              else if (!running) ...[
                DarkPrimaryButton(
                  label: '查看下载',
                  icon: const Icon(Icons.download_for_offline_outlined),
                  fontSize: 10.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  radius: 999,
                  onTap: onOpenInfo,
                ),
                const SizedBox(width: 4),
                DarkGhostButton(
                  label: '原页',
                  onTap: onOpenPage,
                  foreground: DarkPalette.textDim,
                  fontSize: 10.5,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                ),
              ],
            ],
          ),
          // 展开：把三方投递信息 + 下载动作铺在本行里（⛔ 不另开窗口）
          if (expanded) ...[
            const SizedBox(height: 9),
            Divider(
              height: 1,
              thickness: 0.6,
              color: DarkPalette.cardBorder,
            ),
            const SizedBox(height: 9),
            PatchDeliveryLoader(
              resource: r,
              onDark: true,
              dense: true,
              download: dl,
              onDownloadDirect: onDownloadDirect,
              onCancel: onCancel,
            ),
          ] else if (running) ...[
            const SizedBox(height: 8),
            _buildProgress(dl),
          ],
        ],
      ),
    );
  }

  String _metaLine() {
    final parts = <String>[
      resource.site.displayName,
      for (final k in resource.badgeLabels.take(2)) k,
      if (resource.sizeLabel.isNotEmpty) resource.sizeLabel,
      if (resource.author.trim().isNotEmpty) resource.author.trim(),
    ];
    switch (resource.delivery) {
      case PatchDelivery.direct:
        parts.add('直链可下载');
        break;
      case PatchDelivery.netdisk:
        final provider = resource.netdiskProvider?.displayName ?? '网盘';
        final code = (resource.extractCode ?? '').trim();
        parts
            .add(code.isEmpty ? '$provider · 提取码见原页' : '$provider · 提取码 $code');
        break;
      case PatchDelivery.web:
        parts.add('需在原站下载');
        break;
    }
    return parts.join(' · ');
  }

  Widget _buildProgress(PatchDownloadState dl) {
    final failed = dl.phase == PatchDownloadPhase.failed;
    final done = dl.phase == PatchDownloadPhase.done;
    final String text;
    switch (dl.phase) {
      case PatchDownloadPhase.downloading:
        final pct = dl.fraction == null
            ? ''
            : '${(dl.fraction! * 100).toStringAsFixed(0)}%  ';
        text =
            '$pct${dl.sizeLabel}${dl.speedLabel.isEmpty ? '' : ' · ${dl.speedLabel}'}';
        break;
      case PatchDownloadPhase.verifying:
        text = '校验中…';
        break;
      case PatchDownloadPhase.extracting:
        text = '解压中…';
        break;
      case PatchDownloadPhase.done:
        text = dl.extractedCount > 0
            ? '已下载 · 解压出 ${dl.extractedCount} 个文件'
            : '已下载';
        break;
      case PatchDownloadPhase.canceled:
        text = dl.message ?? '已取消';
        break;
      case PatchDownloadPhase.failed:
        text = dl.message ?? '下载失败';
        break;
      case PatchDownloadPhase.idle:
        text = '';
        break;
    }

    Widget action;
    if (dl.phase == PatchDownloadPhase.done) {
      final extract = (dl.extractDir ?? '').trim();
      final saved = (dl.saveDir ?? '').trim();
      final dir = extract.isNotEmpty ? extract : saved;
      action = DarkGhostButton(
        label: '打开文件夹',
        onTap:
            dir.isEmpty ? null : () => PatchDownloadService.openInExplorer(dir),
        foreground: DarkPalette.green,
        fontSize: 10.5,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      );
    } else if (dl.phase == PatchDownloadPhase.extracting) {
      action = const SizedBox.shrink();
    } else if (failed || dl.phase == PatchDownloadPhase.canceled) {
      action = DarkGhostButton(
        label: '重试',
        onTap: onDownload,
        foreground: DarkPalette.lightBlue,
        fontSize: 10.5,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      );
    } else {
      action = DarkGhostButton(
        label: '取消',
        onTap: onCancel,
        foreground: DarkPalette.textDim,
        fontSize: 10.5,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (dl.phase == PatchDownloadPhase.verifying ||
                    dl.phase == PatchDownloadPhase.extracting)
                ? null
                : (done ? 1.0 : dl.fraction),
            minHeight: 3,
            backgroundColor: DarkPalette.border,
            valueColor: AlwaysStoppedAnimation(
              failed ? DarkPalette.pink : DarkPalette.green,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: failed ? DarkPalette.pink : DarkPalette.textMuted,
                ),
              ),
            ),
            action,
          ],
        ),
      ],
    );
  }
}
