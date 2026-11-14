import 'package:flutter/material.dart';

import '../../models/game_resource_model.dart';
import '../../services/game_resource_service.dart';
import 'dark_surface.dart';
import 'kanban_identity.dart';

/// 资源安装状态（下载栏与详情页「获取」按钮共用同一状态源）
enum ResourceInstallState {
  /// 未安装，可获取
  idle,

  /// 已安装
  installed,

  /// 正在安装（带进度）
  installing,

  /// 排队中
  queued,

  /// 不可用（无官方来源 / 未登录等）
  disabled,
}

/// 「下载」按钮回调 [CtDownloadDialog.onDownload] 的结果。
///
/// 浮层必须能区分三种结局才能给出正确反馈（此前是不可区分的
/// `VoidCallback`，"取直链失败"被静默丢弃 —— 2026-10-16 真机反馈
/// 「没有提示、全程无反应」）：
/// - [started]：已成功发起（含排队）→ 调用方关闭浮层，让位给全局安装进度；
/// - [cancelled]：用户主动取消（确认弹窗取消 / 未对接 OpenList 时取消对接）
///   → 浮层保持打开且**不提示**（用户自己的选择，不是错误）；
/// - [failed]：取直链失败 / 抛异常 → 浮层内联红字展示 [message]，可原地重试。
class CtDownloadOutcome {
  const CtDownloadOutcome._(this.kind, this.message);

  const CtDownloadOutcome.started() : this._(_CtDownloadKind.started, null);
  const CtDownloadOutcome.cancelled() : this._(_CtDownloadKind.cancelled, null);
  const CtDownloadOutcome.failed(String message)
      : this._(_CtDownloadKind.failed, message);

  final _CtDownloadKind kind;
  final String? message;

  bool get isStarted => kind == _CtDownloadKind.started;
  bool get isCancelled => kind == _CtDownloadKind.cancelled;
  bool get isFailed => kind == _CtDownloadKind.failed;
}

enum _CtDownloadKind { started, cancelled, failed }

/// 「Chrono Tide 下载」浮层——锚定在「获取」按钮旁的对话栏。
///
/// 设计（`素材/新建文件夹 (2)/官方下载窗口栏.json` + `Shell.png`）：
/// ```
/// Chrono Tide 下载                    共 3 个版本
/// ┌───────────────────────────────────────────────┐
/// │ [游戏本体][民间汉化][Windows][版本号]          │
/// │ (汐乃) 时之 汐乃            ♥244  ↓245  [⬇]   │
/// │            2026-09-01                          │
/// │ 版本说明：…………………………（整行换行，完整展示）      │
/// │ [0.944 GB]                                     │
/// ├─────────────── 下一个版本 ────────────────────┤
/// │ [游戏本体][Windows][重制版]        [12.4 GB][⬇]│
/// └───────────────────────────────────────────────┘
/// ```
///
/// 🆕 **多资源（MULTI-RESOURCE，2026-11-03）**：一个作品可以有多个官方资源
/// （原版 / 重制版 / 社区魔改版）。云端 `game_resources` 支持一作多条
/// `kind=official` 记录，本浮层按 [resources] 逐条渲染，**每条一个下载按钮**，
/// 点哪条就把哪条的 `download_path` 交给安装流。
///
/// - 只有一条时视觉与改造前完全一致（宽度 515、单卡单按钮）；
/// - 多条时加宽到 [DarkPalette.downloadListWidth] 并在浮层内部滚动 ——
///   外层 [showDarkAnchoredPanel] 给的是 `maxHeight = 可用高`，若用
///   `Column(mainAxisSize.min)` 硬堆，条目一多就会被裁掉（项目历史高频坑）。
///
/// 🔴 **版本双字段（2026-10-09 真机修正）**：云端 `games` 的版本信息有**两项**——
/// `version`（版本号，如「模拟器版+NS」）与 `versionNote`（版本说明，长文本）。
/// 此前底部只取 [OfficialResourceView.versionLabel]（说明优先 ⇒ 版本号被丢弃），
/// 且把长说明塞进单行 [DarkBadge] ⇒ ① 版本号永不显示；② 说明徽章超宽被外壳裁掉。
/// 现改为：版本号进顶部徽章行、版本说明在底部整行换行展示。
///
/// 🔴 **数据源（2026-10-01 修正）**：官方资源 = **`games` 表自身的原生下载**
/// （`downloadUrl` / `version` / `versionNote` / `installCount`），由
/// [OfficialResourceView] 统一承载；`game_resources` 的 `kind=official`
/// 记录是**并列的多个版本**，不是"可选的补充"。切勿再写成"必须有 official
/// 记录才能下载"。
///
/// 🔴 **回调结果三分（2026-10-16）**：`onDownload` 此前是 `VoidCallback`，
/// 调用方在「取直链失败」时只 `setState` 了一个**已被 v4.0 废弃的**提示位
/// ⇒ 真机反馈「未获取到链接时没有提示、全程无反应」。现改为返回
/// [CtDownloadOutcome]，浮层据此自绘「进行中 / 失败可重试 / 成功后关闭」。
class CtDownloadDialog extends StatefulWidget {
  const CtDownloadDialog({
    super.key,
    required this.gameTitle,
    this.resource,
    this.resources = const [],
    required this.state,
    this.ownerAvatarUrl,
    this.progress = 0,
    this.installedPath,
    this.fallbackFileSize = '',
    this.onDownload,
    this.onCancel,
    this.onReport,
    this.panelWidth = DarkPalette.downloadBarWidth,
  });

  final String gameTitle;

  /// 单条资源的快捷写法（等价于 [resources] 只含这一条）。
  ///
  /// 保留它是为了不改动既有调用点与测试的挂载方式；两者都为空表示该作品
  /// 确实没有可下载的官方资源（渲染不可用态）。
  final OfficialResourceView? resource;

  /// 全部官方资源（一个作品多个版本）。非空时优先于 [resource]。
  final List<OfficialResourceView> resources;

  final ResourceInstallState state;

  /// 看板娘头像（PB users.avatar 解析后的直链，可空 → 用内置资源）
  final String? ownerAvatarUrl;

  /// 安装进度 0..1（[ResourceInstallState.installing] 时有意义）
  final double progress;

  /// 已安装时的本地路径（展示用）
  final String? installedPath;

  /// 资源大小兜底串（原生来源：`games` 无大小字段，由本地预取
  /// `FileSizePrefetchService` 得到，如 `0.944 GB`）
  final String fallbackFileSize;

  /// 「下载」按钮回调。参数是**被点的那一条**资源；
  /// 返回 [CtDownloadOutcome] 决定浮层后续行为：
  /// [CtDownloadOutcome.started]（关闭浮层）/ [CtDownloadOutcome.cancelled]
  /// （保持打开不提示）/ [CtDownloadOutcome.failed]（内联红字 + 可重试）。
  final Future<CtDownloadOutcome> Function(OfficialResourceView resource)?
      onDownload;
  final VoidCallback? onCancel;

  /// 反馈（预设入口）
  final VoidCallback? onReport;

  /// 浮层宽度。多条资源时调用方传 [DarkPalette.downloadListWidth]。
  final double panelWidth;

  @override
  State<CtDownloadDialog> createState() => _CtDownloadDialogState();
}

class _CtDownloadDialogState extends State<CtDownloadDialog> {
  /// 实际渲染的资源列表（[resources] 优先，其次 [resource] 单条）。
  List<OfficialResourceView> get _items {
    if (widget.resources.isNotEmpty) return widget.resources;
    final r = widget.resource;
    return r == null ? const [] : [r];
  }

  /// 每条资源的点赞数 / 是否已赞，**按列表下标索引**。
  ///
  /// 为什么用下标而不是资源 id / 路径：同一条云记录可能在列表里出现两次
  /// （主资源镜像 + 记录），两条不同版本也可能被填成同一个 `download_path`。
  /// 一旦按 id/路径做 key，点赞数或"转圈"状态就会串到另一行。
  final List<int> _likeCounts = [];
  final Set<int> _liked = {};

  /// 正在解析直链的资源下标（null = 无进行中）。
  ///
  /// 按条记录而不是全局布尔：多版本时点第二行时第一行不该跟着转圈。
  int? _busyIndex;

  /// 失败文案，按资源下标记录 —— 错误要贴在被点的那一行下方。
  final Map<int, String> _errors = {};

  @override
  void initState() {
    super.initState();
    for (final r in _items) {
      _likeCounts.add(r.record?.likeCount ?? 0);
    }
    _loadMyLikes();
  }

  /// 回显「我是否赞过这几条资源」（`resource_likes` 只开放本人可见）
  Future<void> _loadMyLikes() async {
    final items = _items;
    final ids = items
        .map((e) => e.id)
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return;
    final likedIds = await GameResourceService.fetchMyLikedResourceIds(ids);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < items.length; i++) {
        final id = items[i].id;
        if (id.isNotEmpty && likedIds.contains(id)) _liked.add(i);
      }
    });
  }

  void _toggleLike(int index) {
    final res = _items[index];
    final id = res.id;
    final next = !_liked.contains(index);
    // 乐观更新
    setState(() {
      if (next) {
        _liked.add(index);
      } else {
        _liked.remove(index);
      }
      final c = (_likeCounts[index]) + (next ? 1 : -1);
      _likeCounts[index] = c < 0 ? 0 : c;
    });
    if (id.isEmpty) return; // 无社区记录：保持既有本地反馈行为
    // 服务端按 (resource, user) 去重后累加（自定义路由）；失败回滚乐观更新
    GameResourceService.setLike(id, next).then((ok) {
      if (ok || !mounted) return;
      setState(() {
        if (next) {
          _liked.remove(index);
        } else {
          _liked.add(index);
        }
        final c = (_likeCounts[index]) + (next ? -1 : 1);
        _likeCounts[index] = c < 0 ? 0 : c;
      });
    });
  }

  /// 点某一行的「下载」：进入进行态 → 等回调 → 按结果关闭浮层 / 行内报错。
  Future<void> _handleDownloadTap(int index) async {
    final cb = widget.onDownload;
    if (cb == null || _busyIndex != null) return;
    setState(() {
      _busyIndex = index;
      _errors.remove(index);
    });

    CtDownloadOutcome outcome;
    try {
      outcome = await cb(_items[index]);
    } catch (_) {
      outcome = CtDownloadOutcome.failed('发起下载失败，请稍后重试');
    }
    if (!mounted) return;
    setState(() => _busyIndex = null);

    if (outcome.isStarted) {
      // 已成功发起：关闭浮层，让用户回到详情页看全局安装进度
      // （浮层是路由，直接 pop；守卫逻辑与遮罩点击一致）。
      Navigator.of(context).maybePop();
    } else if (outcome.isFailed) {
      setState(
        () => _errors[index] = outcome.message ?? '下载失败，请稍后重试',
      );
    }
    // cancelled：用户自己的选择，保持浮层打开且不提示。
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    // 外层 showDarkAnchoredPanel 给的是有界高度；测试里裸挂时是无界的。
    // 无界时不能给 Flexible（RenderFlex 会因 non-zero flex + unbounded 断言），
    // 故按约束分两条路径 —— 有界走滚动，无界走自然高度。
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final list = SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (items.isEmpty)
                _buildResourceCard(null, 0)
              else
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  _buildResourceCard(items[i], i),
                ],
            ],
          ),
        );

        return DarkShell(
          width: widget.panelWidth,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(items.length),
              if (constraints.maxHeight.isFinite)
                Flexible(child: list)
              else
                list,
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(int count) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 9),
      child: Row(
        children: [
          const Text(
            'Chrono Tide 下载',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: DarkPalette.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          if (count > 1) ...[
            const SizedBox(width: 6),
            DarkBadge(
              label: '共 $count 个版本',
              background: DarkPalette.badgeNeutralBg,
              foreground: DarkPalette.textMuted,
              fontSize: 10,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// 内联失败提示（红色）—— 与「下载」按钮同屏，用户视线所在处即可见。
  ///
  /// 不走全局 `AppSnackBar`：那个气泡在窗口右上角，用户点了浮层里的按钮后
  /// 极可能漏看；失败信息贴在按钮下方最直观。文案由调用方给出。
  Widget _buildErrorRow(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1.5),
            child: Icon(
              Icons.error_outline_rounded,
              size: 13,
              color: DarkPalette.tipCardBorder,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: DarkPalette.tipCardBorder,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------- 单条资源卡 ----------
  Widget _buildResourceCard(OfficialResourceView? res, int index) {
    final error = _errors[index];
    return DarkCard(
      padding: const EdgeInsets.all(9),
      radius: 10,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildBadgeRow(res),
          const SizedBox(height: 9),
          _buildMainRow(res, index),
          const SizedBox(height: 8),
          _buildFooterRow(res, index),
          if (error != null) ...[
            const SizedBox(height: 8),
            _buildErrorRow(error),
          ],
        ],
      ),
    );
  }

  // ---------- 顶部：资源类型 + 平台 + 版本号 ----------
  Widget _buildBadgeRow(OfficialResourceView? res) {
    final types = res?.resourceTypes.isNotEmpty == true
        ? res!.resourceTypes
        : const ['游戏本体'];
    final platforms = res?.platforms.isNotEmpty == true
        ? res!.platforms
        : const ['Windows'];
    // 版本号（`games.version` / 记录 version）：紧邻平台徽章展示，
    // 与底部「版本说明」凑齐云端版本的完整两项。
    final version = res?.version.trim() ?? '';
    final title = res?.title.trim() ?? '';

    final badges = <Widget>[
      // 版本名（原版 / 重制版 / 社区魔改版）：多资源列表主要靠它区分，
      // 必须排在类型徽章前面。与类型里的「游戏本体」同名时只留一个。
      if (title.isNotEmpty && !types.contains(title))
        DarkBadge(
          label: title,
          background: DarkPalette.badgePinkBg,
          foreground: DarkPalette.pink,
          icon: const Icon(Icons.sell_outlined),
        ),
      for (final t in types)
        DarkBadge(
          label: t,
          background: DarkPalette.badgeBlueBg,
          foreground: DarkPalette.lightBlue,
        ),
      for (final p in platforms)
        DarkBadge(
          label: p,
          background: DarkPalette.badgeGreenBg,
          foreground: DarkPalette.green,
          icon: const Icon(Icons.desktop_windows_outlined),
        ),
      if (version.isNotEmpty)
        DarkBadge(
          label: version,
          background: DarkPalette.badgeVioletBg,
          foreground: DarkPalette.violet,
          icon: const Icon(Icons.local_offer_outlined),
        ),
    ];

    return Wrap(spacing: 4.5, runSpacing: 4.5, children: badges);
  }

  // ---------- 中部：分享者 + 点赞 / 下载人数 / 下载按钮 ----------
  Widget _buildMainRow(OfficialResourceView? res, int index) {
    // 官方来源的分享者**恒为看板娘**（数据未就绪时也显示她，而非空白）
    final ownerName = (res?.ownerName.isNotEmpty ?? false)
        ? res!.ownerName
        : KanbanIdentity.name;
    final date = res?.createdDateLabel ?? '';
    final downloadCount = res?.downloadCount ?? 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AvatarCircle.kanban(
          imageUrl: widget.ownerAvatarUrl,
          size: 25,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ownerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DarkPalette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (date.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '分享于 $date',
                  style: const TextStyle(
                    fontSize: 10,
                    color: DarkPalette.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 6),
        _buildLikeChip(index),
        const SizedBox(width: 9),
        _buildDownloadCount(downloadCount),
        const SizedBox(width: 9),
        _buildActionButton(res, index),
      ],
    );
  }

  Widget _buildLikeChip(int index) {
    final canTap = index < _items.length;
    final liked = _liked.contains(index);
    final count = _likeCounts.length > index ? _likeCounts[index] : 0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: canTap ? () => _toggleLike(index) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              liked ? Icons.favorite : Icons.favorite_border,
              size: 12.5,
              color: liked ? const Color(0xFFFF5A63) : DarkPalette.textDim,
            ),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                color: liked ? const Color(0xFFFF5A63) : DarkPalette.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCount(int count) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.file_download_outlined,
          size: 12.5,
          color: DarkPalette.textDim,
        ),
        const SizedBox(width: 3),
        Text(
          '$count',
          style: const TextStyle(fontSize: 11, color: DarkPalette.textDim),
        ),
      ],
    );
  }

  Widget _buildActionButton(OfficialResourceView? res, int index) {
    switch (widget.state) {
      case ResourceInstallState.installing:
        return DarkIconButton(
          icon: const Icon(Icons.stop_rounded),
          onTap: widget.onCancel,
          size: 26,
          radius: 8,
          background: DarkPalette.badgeNeutralBg,
          foreground: DarkPalette.textSecondary,
          tooltip: '取消安装',
        );
      case ResourceInstallState.disabled:
        return const DarkIconButton(
          icon: Icon(Icons.download_rounded),
          onTap: null,
          size: 26,
          radius: 8,
          background: DarkPalette.badgeNeutralBg,
          foreground: DarkPalette.placeholder,
          tooltip: '暂无可下载的官方资源',
        );
      default:
        if (_busyIndex == index) {
          // 进行态：转圈 + 拒绝重复点击（此前按钮全程无变化＝像卡死）
          return const DarkIconButton(
            icon: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            onTap: null,
            size: 26,
            radius: 8,
            background: DarkPalette.actionBlue,
            foreground: Colors.white,
            tooltip: '正在获取下载链接…',
          );
        }
        final hasError = _errors.containsKey(index);
        return DarkIconButton(
          icon: const Icon(Icons.download_rounded),
          onTap: res == null ? null : () => _handleDownloadTap(index),
          size: 26,
          radius: 8,
          background: DarkPalette.actionBlue,
          foreground: Colors.white,
          tooltip: hasError ? '重试下载' : _actionTooltip,
        );
    }
  }

  String get _actionTooltip {
    switch (widget.state) {
      case ResourceInstallState.installed:
        return '已安装 · 点击重新下载';
      case ResourceInstallState.queued:
        return '已加入队列 · 点击查看';
      default:
        return '下载并安装';
    }
  }

  // ---------- 底部：版本说明 + 大小 ----------
  Widget _buildFooterRow(OfficialResourceView? res, int index) {
    // 版本号已移至顶部徽章行（紧邻平台）。此处承载「版本说明」长文本
    // （`games.versionNote`）与大小 / 安装状态徽章。
    // 🔴 版本说明整行换行**完整展示**——此前塞进单行 [DarkBadge] 会超出浮层
    // 宽度被外壳裁掉（真机 2026-10-09 反馈「版本信息显示不完整」）。
    // 大小：优先资源记录，为空时由调用方通过 [fallbackFileSize] 传入本地预取结果。
    final note = res?.versionNote.trim() ?? '';
    // 多资源时 [fallbackFileSize] 只对应主资源（`games` 侧没有逐资源大小），
    // 其余条目必须用记录里手填的 `file_size`，否则所有版本会显示同一个体积。
    final isPrimary = index == 0;
    final size = (res?.fileSize.isNotEmpty ?? false)
        ? res!.fileSize
        : (isPrimary ? widget.fallbackFileSize : '');
    final hasStateBadge =
        widget.state == ResourceInstallState.installed ||
            widget.state == ResourceInstallState.queued;
    final hasBadges = size.isNotEmpty || hasStateBadge;
    final hasAny = note.isNotEmpty || hasBadges;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.state == ResourceInstallState.installing) ...[
          _buildProgressBar(),
          const SizedBox(height: 8),
        ],
        if (note.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1.5),
                child: Icon(
                  Icons.notes_rounded,
                  size: 12.5,
                  color: DarkPalette.textDim,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  note,
                  style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    color: DarkPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (hasBadges) const SizedBox(height: 7),
        ],
        if (hasBadges)
          Wrap(
            spacing: 4.5,
            runSpacing: 4.5,
            children: [
              if (size.isNotEmpty)
                DarkBadge(
                  label: size,
                  background: DarkPalette.badgeNeutralBg,
                  foreground: DarkPalette.textSecondary,
                  icon: const Icon(Icons.sd_storage_outlined),
                ),
              if (widget.state == ResourceInstallState.installed)
                const DarkBadge(
                  label: '已安装',
                  background: DarkPalette.badgeGreenBg,
                  foreground: DarkPalette.green,
                  icon: Icon(Icons.check_circle_outline),
                ),
              if (widget.state == ResourceInstallState.queued)
                const DarkBadge(
                  label: '排队中',
                  background: DarkPalette.badgeYellowBg,
                  foreground: DarkPalette.yellow,
                  icon: Icon(Icons.schedule_outlined),
                ),
            ],
          ),
        if (!hasAny && widget.state == ResourceInstallState.installing) ...[
          _buildProgressLabel(),
        ],
        if (widget.onReport != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: DarkGhostButton(
              label: '反馈',
              onTap: widget.onReport,
              foreground: DarkPalette.yellow,
              icon: const Icon(Icons.flag_outlined),
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: widget.progress.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: DarkPalette.badgeNeutralBg,
            valueColor: const AlwaysStoppedAnimation(DarkPalette.primaryBlue),
          ),
        ),
        const SizedBox(height: 5),
        _buildProgressLabel(),
      ],
    );
  }

  Widget _buildProgressLabel() {
    final pct = (widget.progress.clamp(0.0, 1.0) * 100).toStringAsFixed(0);
    return Text(
      '正在下载并安装 · $pct%',
      style: const TextStyle(fontSize: 10.5, color: DarkPalette.textMuted),
    );
  }
}
