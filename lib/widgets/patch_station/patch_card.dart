import 'package:flutter/material.dart';

import '../../models/patch_resource.dart';
import '../../services/patch/patch_download_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';
import '../../theme/app_styles.dart';
import 'patch_delivery_loader.dart';
import 'patch_site_logo.dart';

/// 单张补丁卡片（横向卡片形态）。
///
/// ## 一屏看到什么
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │ (饭团) 2DFan  无码                   29.2 MB │  ← 站点图标 + 类型 + 大小
/// │ ヱスガソラ 原版 步兵补丁                       │  ← 标题（最多 2 行）
/// │ 适用于 缘之空 · yirigahama · 夸克网盘         │  ← 元信息 + 投递形态
/// │                          [查看下载] [原页]  │  ← 两个动作，与参考站一致
/// └──────────────────────────────────────────┘
/// ```
///
/// ## 为什么是「查看下载」而不是直接的「下载」
///
/// 三条投递路径（直链 / 网盘 / 只能去原站）的操作根本不同，卡片上只放
/// 一个按钮没法表达。⛔ 不要在卡片上塞三个按钮 —— 250dp 宽时会挤爆。
/// 「查看下载」把三条路径统一收口到 [PatchDownloadDetails]，那里有完整的
/// 链接、提取码、积分提示与下载按钮 —— 并且是**原地展开**在卡片位置，
/// 不再另开一个压在面板下面的窗口（v5 用户面评）。
///
/// 🔴 **补丁站只下载，不安装**（2026-11-10 用户定调）。卡片与详情浮层里
/// 都没有任何「应用 / 安装 / 套用到游戏」的动作，完成后只有「打开文件夹」。
///
/// ## 尺寸
///
/// 宽度由父级网格算好后通过 [width] 传入；高度固定 [kPatchCardHeight]
/// （网格按定高排版，否则每行会被最高那张撑高、卡片高矮不齐）。
const double kPatchCardHeight = 138;

/// 两位补零（展开卡显示更新时间用）
String _twoDigits(int v) => v < 10 ? '0$v' : '$v';

class PatchCard extends StatelessWidget {
  const PatchCard({
    super.key,
    required this.resource,
    required this.width,
    this.onOpenInfo,
    this.onOpenPage,
    this.onDownload,
    this.onCancel,
    this.download,
    this.showGameTitle = false,
  });

  final PatchResource resource;

  /// 由父级网格反推的卡片宽度（保证整行刚好铺满，不留残列）
  final double width;

  /// 「查看下载」→ 打开下载详情浮层（三条投递路径的唯一入口）
  final VoidCallback? onOpenInfo;

  /// 「原页」→ 系统浏览器打开站点页面（永远可用的兜底动作）
  final VoidCallback? onOpenPage;

  /// 详情浮层里点下载后由面板回调（[PatchCard] 自己不发请求）
  final VoidCallback? onDownload;

  /// 取消进行中的下载（`.part` 保留，可续传）
  final VoidCallback? onCancel;

  /// 本补丁的下载状态（由面板从 [PatchDownloadService] 取；null = 未开始）
  final PatchDownloadState? download;

  /// 是否展示「适用于 xxx」。通用态（未锁定游戏）下必须显示，
  /// 否则用户分不清 2DFan 按关键词召回的结果是不是同一部作品。
  final bool showGameTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: kPatchCardHeight,
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.borderLight,
          width: AppStyle.isModern ? AppStyle.wHairline : 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopRow(),
          const SizedBox(height: 6),
          Text(
            resource.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 13,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 3),
          _buildMetaLine(),
          const Spacer(),
          _buildBottomRow(),
        ],
      ),
    );
  }

  // ---------------- 顶部：站点图标 + 站点名 + 类型 + 大小 ----------------

  Widget _buildTopRow() {
    final kinds = resource.badgeLabels.take(2).toList();
    final siteColor = PatchSiteLogo.colorOf(resource.site);
    return Row(
      children: [
        PatchSiteLogo(site: resource.site, size: 16),
        const SizedBox(width: 5),
        Text(
          resource.site.displayName,
          style: AppStyles.bodyRegular.copyWith(
            fontSize: 10.5,
            height: 1.1,
            fontWeight: FontWeight.w700,
            color: siteColor,
          ),
        ),
        for (final k in kinds) ...[
          const SizedBox(width: 4),
          _badge(k, AppColors.secondaryText),
        ],
        const Spacer(),
        if (resource.sizeLabel.isNotEmpty)
          Text(
            resource.sizeLabel,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 10.5,
              color: AppColors.secondaryText.withOpacity(0.85),
            ),
          ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 9.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ---------------- 中间：适用于 / 作者 / 投递形态 ----------------

  Widget _buildMetaLine() {
    final parts = <String>[];
    if (showGameTitle && resource.gameTitle.trim().isNotEmpty) {
      parts.add('适用于 ${resource.gameTitle.trim()}');
    }
    if (resource.author.trim().isNotEmpty) {
      parts.add(resource.author.trim());
    }
    parts.add(_deliveryHint());
    if (resource.downloadCount > 0) {
      parts.add('${_compactCount(resource.downloadCount)} 次下载');
    }
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppStyles.bodyRegular.copyWith(
        fontSize: 10.5,
        color: AppColors.secondaryText.withOpacity(0.8),
      ),
    );
  }

  static String _compactCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  /// 投递形态的一句话说明（已下到本地时让位给进度行）
  String _deliveryHint() {
    switch (resource.delivery) {
      case PatchDelivery.direct:
        return '直链可下载';
      case PatchDelivery.netdisk:
        final provider = resource.netdiskProvider?.displayName ?? '网盘';
        final code = (resource.extractCode ?? '').trim();
        return code.isEmpty ? '$provider · 提取码见原页' : '$provider · 提取码 $code';
      case PatchDelivery.web:
        return '需在原站下载';
    }
  }

  // ---------------- 底部：两个动作 / 下载进度 ----------------

  Widget _buildBottomRow() {
    final dl = download;
    // 有下载记录 ⇒ 底部整行让给下载状态（进度 / 校验 / 解压 / 完成 / 失败）
    if (dl != null && dl.phase != PatchDownloadPhase.idle) {
      return _buildDownloadRow(dl);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // 左侧留空：尺寸/类型/元信息已经都在上面，这里只放动作
        const Spacer(),
        _actionButton(
          label: '查看下载',
          icon: Icons.download_for_offline_outlined,
          filled: true,
          enabled: onOpenInfo != null,
          onTap: onOpenInfo,
          tooltip: '查看直链 / 网盘 / 积分信息，并在软件内下载',
        ),
        const SizedBox(width: 6),
        _actionButton(
          label: '原页',
          icon: Icons.open_in_new_rounded,
          enabled: onOpenPage != null && resource.webUrl.trim().isNotEmpty,
          onTap: onOpenPage,
          tooltip: '在浏览器打开资源页面',
        ),
      ],
    );
  }

  /// 下载状态行：细进度条 + 一行文案 + 右侧动作
  Widget _buildDownloadRow(PatchDownloadState dl) {
    final failed = dl.phase == PatchDownloadPhase.failed;
    final done = dl.phase == PatchDownloadPhase.done;

    final String text;
    if (dl.phase == PatchDownloadPhase.downloading) {
      final pct = dl.fraction == null
          ? ''
          : '${(dl.fraction! * 100).toStringAsFixed(0)}%  ';
      final speed = dl.speedLabel.isEmpty ? '' : ' · ${dl.speedLabel}';
      text = '$pct${dl.sizeLabel}$speed';
    } else if (dl.phase == PatchDownloadPhase.verifying) {
      text = '校验中…';
    } else if (dl.phase == PatchDownloadPhase.extracting) {
      text = '解压中…';
    } else if (done) {
      // 解压成功就把件数说出来；没解压（EXE/7z/关掉了）就只说已下载
      text =
          dl.extractedCount > 0 ? '已下载 · 解压出 ${dl.extractedCount} 个文件' : '已下载';
    } else if (dl.phase == PatchDownloadPhase.canceled) {
      text = dl.message ?? '已取消';
    } else {
      text = dl.message ?? '下载失败';
    }

    Widget? action;
    if (dl.phase == PatchDownloadPhase.downloading ||
        dl.phase == PatchDownloadPhase.verifying ||
        dl.phase == PatchDownloadPhase.extracting) {
      // 解压不可中断：这一步给的是「等」，点了也没用 ⇒ 不渲染取消按钮
      action = dl.phase == PatchDownloadPhase.extracting
          ? null
          : _actionButton(
              label: '取消',
              icon: Icons.close_rounded,
              enabled: onCancel != null,
              onTap: onCancel,
            );
    } else if (done) {
      // 🔴 补丁站只下载不安装 ⇒ 完成后的唯一后续动作是「去文件夹看看」
      final dir = _doneFolder(dl);
      action = _actionButton(
        label: '打开文件夹',
        icon: Icons.folder_open_rounded,
        enabled: dir.isNotEmpty,
        onTap:
            dir.isEmpty ? null : () => PatchDownloadService.openInExplorer(dir),
      );
    } else if (failed) {
      action = _actionButton(
        label: '重试',
        icon: Icons.refresh_rounded,
        enabled: onDownload != null,
        onTap: onDownload,
      );
    } else {
      action = _actionButton(
        label: '继续',
        icon: Icons.play_arrow_rounded,
        filled: true,
        enabled: onDownload != null,
        onTap: onDownload,
      );
    }

    final hint = (dl.hint ?? '').trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 进度条：下载中显示真实进度，校验/解压中显示不确定态
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (dl.phase == PatchDownloadPhase.verifying ||
                    dl.phase == PatchDownloadPhase.extracting)
                ? null
                : (done ? 1.0 : dl.fraction),
            minHeight: 3,
            backgroundColor: AppColors.border.withOpacity(0.35),
            valueColor: AlwaysStoppedAnimation(
              failed ? AppColors.dangerRed : AppColors.accentCyan,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                // 包形态提示（"DLL 注入型需与 exe 同目录"）只在这里露出，
                // 卡片高度固定 138，⛔ 塞不下第二行
                message: hint.isEmpty ? text : '$text\n$hint',
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 10.5,
                    color: failed
                        ? AppColors.dangerRed
                        : AppColors.secondaryText.withOpacity(0.85),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (action != null) action,
          ],
        ),
      ],
    );
  }

  /// 完成后「打开文件夹」应该打开哪一层：解压目录 > 保存目录 > 文件所在目录
  String _doneFolder(PatchDownloadState dl) {
    final extract = (dl.extractDir ?? '').trim();
    if (extract.isNotEmpty) return extract;
    final saved = (dl.saveDir ?? '').trim();
    if (saved.isNotEmpty) return saved;
    final file = (dl.filePath ?? '').trim();
    if (file.isEmpty) return '';
    final i = file.lastIndexOf(RegExp(r'[\\/]'));
    return i > 0 ? file.substring(0, i) : '';
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool filled = false,
    bool enabled = true,
    String? tooltip,
  }) {
    final active = enabled && onTap != null;
    final fg =
        filled && active ? AppColors.onAccentSolid : AppColors.primaryText;
    final bg = filled && active
        ? AppColors.accentCyan
        : (active ? Colors.transparent : AppColors.buttonBackground);
    final borderColor = filled && active
        ? AppColors.accentCyan
        : AppColors.border.withOpacity(active ? 1 : 0.5);

    final button = MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.45,
          duration: const Duration(milliseconds: 140),
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: borderColor, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// 「查看下载」展开后的卡片（**原地展开，不再另开窗口**）。
///
/// ## 为什么是原地展开
///
/// 用户面评：「明明是在这张卡上点的，为什么要另开一个窗、还压在面板下面？
/// 直接在这张卡上展开不行吗？」—— 行，而且更好：信息与来源不会脱节。
///
/// ## 布局语义（对齐用户描述）
///
/// ```
/// 两列网格：  [卡A] [卡B]
///             [卡C] [卡D]
///                ↓ 点卡B的「查看下载」
///             [卡A] [卡B ← 不再画在这里]
///             [卡B 展开后占满整行 ..............]
///             [卡C] [卡D]      ← 被挤到下一行
/// ```
///
/// 实现上就是「展开项宽度 = 整行宽」，交给外层 `Wrap` 自然换行，
/// ⛔ 不要自己算 y 坐标（算不准，而且窗口一缩放就全乱）。
class PatchExpandedCard extends StatelessWidget {
  const PatchExpandedCard({
    super.key,
    required this.resource,
    required this.width,
    this.showGameTitle = false,
    this.onCollapse,
    this.onDownloadDirect,
    this.onCancel,
    this.download,
  });

  final PatchResource resource;

  /// 展开项固定占满整行（= 结果区可用宽）
  final double width;

  final bool showGameTitle;

  final VoidCallback? onCollapse;

  /// 软件内下载。**带实际直链**：2DFan 的直链兑换后才有，
  /// 模型里的 `directUrl` 恒为空 ⇒ 不能用无参回调。
  final Future<void> Function(String url)? onDownloadDirect;

  final VoidCallback? onCancel;
  final PatchDownloadState? download;

  @override
  Widget build(BuildContext context) {
    final siteColor = PatchSiteLogo.colorOf(resource.site);
    final kinds = resource.badgeLabels.take(2).toList();

    final meta = <String>[
      if (showGameTitle && resource.gameTitle.trim().isNotEmpty)
        '适用于 ${resource.gameTitle.trim()}',
      if (resource.author.trim().isNotEmpty) resource.author.trim(),
      if (resource.downloadCount > 0)
        '${PatchCard._compactCount(resource.downloadCount)} 次下载',
      if (resource.updatedAt != null)
        '${resource.updatedAt!.year}-'
            '${_twoDigits(resource.updatedAt!.month)}-'
            '${_twoDigits(resource.updatedAt!.day)}',
    ];

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.accentCyan.withOpacity(0.45),
          width: AppStyle.isModern ? 1.2 : 1.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PatchSiteLogo(site: resource.site, size: 18),
              const SizedBox(width: 6),
              Text(
                resource.site.displayName,
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 11.5,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: siteColor,
                ),
              ),
              for (final k in kinds) ...[
                const SizedBox(width: 5),
                _chip(k, AppColors.secondaryText),
              ],
              const Spacer(),
              if (resource.sizeLabel.isNotEmpty)
                Text(
                  resource.sizeLabel,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11,
                    color: AppColors.secondaryText.withOpacity(0.9),
                  ),
                ),
              if (onCollapse != null) ...[
                const SizedBox(width: 8),
                _collapse(onCollapse!),
              ],
            ],
          ),
          const SizedBox(height: 7),
          Text(
            resource.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 13.5,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              meta.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 10.5,
                color: AppColors.secondaryText.withOpacity(0.8),
              ),
            ),
          ],
          const SizedBox(height: 9),
          Divider(
            height: 1,
            thickness: 1,
            color: AppColors.border.withOpacity(0.4),
          ),
          const SizedBox(height: 10),
          PatchDeliveryLoader(
            resource: resource,
            download: download,
            onDownloadDirect: onDownloadDirect,
            onCancel: onCancel,
            dense: true,
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: AppStyles.bodyRegular.copyWith(
          fontSize: 9.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _collapse(VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Tooltip(
          message: '收起',
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(color: AppColors.border.withOpacity(0.8)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.keyboard_arrow_up_rounded,
                    size: 13, color: AppColors.secondaryText),
                const SizedBox(width: 2),
                Text(
                  '收起',
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 10,
                    height: 1.1,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
