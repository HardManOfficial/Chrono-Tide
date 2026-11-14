import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 启动程序列表里的角标（LAUNCH-RECOMMEND，2026-10-26）。
///
/// 两处「选择启动程序」界面（`ExeSelectorDialog` / `LaunchManagerDialog`）
/// 共用，保证同一份分析结果在两处的视觉表达一致。
///
/// 🔴 尺寸纪律：这两个列表项本身只有 ~46px 高，且 `LaunchManagerDialog` 的
/// 标题行在 `HALL-FIT-CARDS` 一轮里被 M3 默认 48×48 触控区撑炸过。所以角标
/// 一律**固定 18px 高、不设最小触控尺寸**（纯展示，不可点），且调用方必须把
/// 文件名包进 `Flexible`，靠省略号让位——不能让角标把行撑出去。
class LauncherRecommendBadge extends StatelessWidget {
  /// 悬浮提示全文（如「这可能是你需要的启动程序（汉化版）」+ 判定依据）
  final String? tooltip;

  const LauncherRecommendBadge({super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.warningAmber;
    // 琥珀色文字压在自己的浅底上对比度不够，压暗 28% 再当字色
    final textColor =
        Color.lerp(accent, const Color(0xFF000000), 0.28) ?? accent;

    final pill = Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: accent.withOpacity(0.5), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 11, color: accent),
          const SizedBox(width: 2),
          Text(
            '推荐',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.1,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );

    final tip = tooltip;
    if (tip == null || tip.isEmpty) return pill;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 300),
      child: pill,
    );
  }
}

/// 「无关程序」角标：告诉用户这个 exe 是配套工具/运行库，不是启动游戏用的。
///
/// 刻意不隐藏这些程序——用户明确要求「不隐藏、不折叠」，保持原有列表顺序，
/// 只用一枚灰标把两类区分开。
class LauncherToolBadge extends StatelessWidget {
  final String? tooltip;

  const LauncherToolBadge({super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final color = AppColors.secondaryText;
    final pill = Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withOpacity(0.25), width: 0.8),
      ),
      child: Center(
        child: Text(
          '工具',
          style: TextStyle(
            fontSize: 10.5,
            height: 1.1,
            color: color,
          ),
        ),
      ),
    );

    final tip = tooltip;
    if (tip == null || tip.isEmpty) return pill;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 300),
      child: pill,
    );
  }
}
