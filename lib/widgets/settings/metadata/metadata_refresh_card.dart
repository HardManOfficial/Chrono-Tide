import 'package:flutter/material.dart';

import '../../../services/metadata_refresh_service.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';

/// 「全量更新元数据」卡片。
///
/// 学习自 LunaBox 的「更新全部游戏原数据」——但我们按自己的数据模型重做：
///
/// - 默认**只补空字段**（`overwrite = false`）。简介/标签很可能被用户手改过，
///   一次误点就全没了，且没有 undo。想覆盖必须显式勾选。
/// - **不改标题**、**不碰封面与截图**（各自有独立的后台补全机制）。
/// - 长任务必须可取消、可看进度、可只重试失败项 —— 否则用户只能盯着干等，
///   失败了还得从头再来一遍。
class MetadataRefreshCard extends StatefulWidget {
  const MetadataRefreshCard({super.key});

  @override
  State<MetadataRefreshCard> createState() => _MetadataRefreshCardState();
}

class _MetadataRefreshCardState extends State<MetadataRefreshCard> {
  bool _overwrite = false;

  MetadataRefreshService get _service => MetadataRefreshService.instance;

  Future<void> _start() async {
    if (_overwrite) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: AppColors.background,
          title: Text(
            '覆盖已有数据？',
            style: TextStyle(fontSize: 15, color: AppColors.primaryText),
          ),
          content: Text(
            '勾选了「覆盖已有字段」：库里已经有值的简介、标签、会社、评分等'
            '会被抓取结果替换。手工改过的内容无法恢复。',
            style: TextStyle(
              fontSize: 13,
              height: 19 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: AppColors.secondaryText)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('确认覆盖',
                  style: TextStyle(color: AppColors.dangerRed)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _service.start(overwrite: _overwrite);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (BuildContext context, Widget? _) {
        final MetadataRefreshProgress p = _service.progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildIntro(),
            const SizedBox(height: AppSpacing.sm),
            _buildControls(p),
            if (p.phase != MetadataRefreshPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _buildProgress(p),
            ],
            if (p.hasFailures) ...<Widget>[
              const SizedBox(height: AppSpacing.sm),
              _buildFailures(p),
            ],
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 说明

  Widget _buildIntro() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '改完来源、优先级或凭证之后，用这里把新设置应用到整个库。'
            '逐条重新抓取「简介 / 标签 / 会社 / 评分 / 发售日 / 时长 / 来源标识」。',
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '不会动：标题、副标题、封面文件、截图文件、游玩记录。'
            '封面与截图由各自的后台补全机制负责，不在这里重复下载。',
            style: TextStyle(
              fontSize: 11,
              height: 16 / 11,
              color: AppColors.placeholderText,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 控件

  Widget _buildControls(MetadataRefreshProgress p) {
    final bool running = p.isRunning;
    return Row(
      children: <Widget>[
        // 覆盖开关：运行中禁用（改一半任务的口径会让人以为是 bug）
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: _overwrite,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: AppColors.border, width: 1.4),
            activeColor: AppColors.dangerRed,
            onChanged: running
                ? null
                : (bool? v) => setState(() => _overwrite = v ?? false),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '覆盖已有字段',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: _overwrite ? AppColors.dangerRed : AppColors.secondaryText,
            ),
          ),
        ),
        const SizedBox(width: 12),
        if (p.hasFailures && !running) ...<Widget>[
          _buildButton(
            label: '重试失败项（${p.failures.length}）',
            onTap: () => _service.retryFailed(overwrite: _overwrite),
            primary: false,
          ),
          const SizedBox(width: 8),
        ],
        _buildButton(
          label: running ? '取消' : '更新全部游戏元数据',
          onTap: running ? _service.cancel : _start,
          primary: !running,
          danger: running,
        ),
      ],
    );
  }

  Widget _buildButton({
    required String label,
    required VoidCallback onTap,
    required bool primary,
    bool danger = false,
  }) {
    final Color borderColor = danger
        ? AppColors.dangerRed
        : (primary ? AppColors.successGreen : AppColors.border);
    final Color textColor = danger
        ? AppColors.dangerRed
        : (primary ? AppColors.successGreen : AppColors.secondaryText);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: primary
                ? AppColors.successGreen.withOpacity(0.10)
                : AppColors.background,
            border: Border.all(color: borderColor, width: 1.4),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 进度

  Widget _buildProgress(MetadataRefreshProgress p) {
    final bool done = p.isFinished || p.phase == MetadataRefreshPhase.cancelled;
    final Color barColor = p.failed > 0 && done
        ? AppColors.warningAmber
        : (done ? AppColors.successGreen : AppColors.infoBlue);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  p.summaryText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 17 / 12,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                p.percentText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: barColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRect(
            child: LinearProgressIndicator(
              value: p.ratio,
              minHeight: 4,
              backgroundColor: AppColors.border,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 失败项

  Widget _buildFailures(MetadataRefreshProgress p) {
    // 清单可能很长（几百条），限高 + 独立滚动，避免把设置页拉成一条线
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.errorBg,
        border: Border.all(color: AppColors.dangerRed.withOpacity(0.5), width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '未成功（${p.failures.length}）',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.dangerRed,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 132),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final MetadataRefreshFailure f in p.failures)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '${f.title} · ${f.reason}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
