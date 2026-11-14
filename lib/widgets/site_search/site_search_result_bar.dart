import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../theme/app_colors.dart';

/// 全站库结果条（SITE-SEARCH，2026-11-14 用户拍板重做）。
///
/// ## 为什么单独成组件
///
/// 它只在「有站外结果」时出现，而探索页整屏探针拿不到该状态（站外结果必须
/// 真打网络才会产生）。抽出来才能被渲染探针直接覆盖——本项目吃过「改动落在
/// 某个 build、探针覆盖不到、release 整块灰底」的亏。
///
/// ## 设计
///
/// 32px 单行（与 `discover_page._contentTopPadding` 预留的 32 完全对齐）：
/// - 左：`全站库` 标识 + 关键词；
/// - 中：**每个源一个计数胶囊**（点击 = 只看该源，再点 = 取消）；
/// - 差额（滤除 / 与库内重复）与失败原因收进悬浮提示，不占正文；
/// - 右：`重新搜索` + `关闭`。
///
/// ⛔ 不要在这里做任何网络/状态逻辑：纯展示，回调全部由页面给。
class SiteSearchResultBar extends StatelessWidget {
  const SiteSearchResultBar({
    super.key,
    required this.keyword,
    required this.searching,
    this.sourceCounts = const <SiteSearchSource, int>{},
    this.activeSource,
    this.notes = const <String>[],
    this.failureText,
    this.onToggleSource,
    this.onRefresh,
    required this.onClose,
  });

  /// 本次检索的关键词
  final String keyword;

  /// 正在检索（显示进度点，隐藏源胶囊与刷新）
  final bool searching;

  /// 每个源**可展示**的条数（点下去必须真有这么多张卡）
  final Map<SiteSearchSource, int> sourceCounts;

  /// 当前只看哪个源（null = 全部）
  final SiteSearchSource? activeSource;

  /// 差额说明（已滤除 / 已隐藏重复），为空则不显示信息图标
  final List<String> notes;

  /// 失败源描述（null = 全部成功）
  final String? failureText;

  final ValueChanged<SiteSearchSource>? onToggleSource;
  final VoidCallback? onRefresh;
  final VoidCallback onClose;

  static const double barHeight = 32;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: barHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border, width: 1),
      ),
      child: Row(
        children: [
          Icon(Icons.public_rounded,
              size: 13, color: AppColors.selectedAccent.withOpacity(0.85)),
          const SizedBox(width: 6),
          Text(
            '全站库',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              searching ? '正在搜索「$keyword」…' : '「$keyword」',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.secondaryText.withOpacity(0.9),
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (searching)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else ...[
            for (final e in sourceCounts.entries)
              if (e.value > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Pill(
                    label: '${e.key.displayName} ${e.value}',
                    active: activeSource == e.key,
                    onTap: onToggleSource == null
                        ? null
                        : () => onToggleSource!(e.key),
                  ),
                ),
            if (notes.isNotEmpty)
              Tooltip(
                message: notes.join('\n'),
                child: MouseRegion(
                  cursor: SystemMouseCursors.help,
                  child: Icon(Icons.info_outline_rounded,
                      size: 13, color: AppColors.secondaryText.withOpacity(0.6)),
                ),
              ),
          ],
          const Spacer(),
          if (failureText != null && !searching)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Tooltip(
                message: failureText!,
                child: MouseRegion(
                  cursor: SystemMouseCursors.help,
                  child: Icon(Icons.error_outline_rounded,
                      size: 13, color: AppColors.selectedAccent),
                ),
              ),
            ),
          if (!searching && onRefresh != null)
            _Pill(
              label: '重新搜索',
              active: false,
              icon: Icons.refresh_rounded,
              onTap: onRefresh,
            ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onClose,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Icon(Icons.close_rounded,
                  size: 14, color: AppColors.secondaryText.withOpacity(0.7)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 胶囊按钮：计数 / 刷新共用。比 Material `Chip` 轻得多（无动效、无内边距
/// 默认值），在 32px 行里不会把行撑破。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.active,
    this.icon,
    this.onTap,
  });

  final String label;
  final bool active;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? AppColors.selectedAccent
        : AppColors.borderLight.withOpacity(0.55);
    final fg = active ? Colors.white : AppColors.secondaryText;
    return MouseRegion(
      cursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 11, color: fg),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
