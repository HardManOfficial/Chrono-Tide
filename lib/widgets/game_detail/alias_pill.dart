import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';

/// 单个别名胶囊（2026-10-10 需求 3）。
///
/// 需求口径：别名展示改为**一个名字一个框**（原先是多个别名用 ` / ` 串在同一
/// 个胶囊里）。视觉沿用详情页头部原有的胶囊样式（浅底 + 描边 + 全圆角）。
class AliasPill extends StatelessWidget {
  const AliasPill({
    super.key,
    required this.text,
    this.fontSize = 12.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    this.maxWidth = 420,
  });

  final String text;
  final double fontSize;
  final EdgeInsets padding;

  /// 单框最大宽度（超长别名仍单行、不换行撑破布局）
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.placeholderBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border.withOpacity(0.55), width: 1),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppStyles.bodyRegular.copyWith(
          fontSize: fontSize,
          color: AppColors.secondaryText,
          fontStyle: FontStyle.normal,
        ),
      ),
    );
  }
}

/// 一组别名胶囊：**一个名字一个框** + 自动换行。
///
/// 三个展示点统一走本组件（详情页头部 / 库详情弹窗 / CT 选择器），
/// 通过 [fontSize] / [padding] / [maxWidth] 适配各自密度。
class AliasPillWrap extends StatelessWidget {
  const AliasPillWrap({
    super.key,
    required this.aliases,
    this.fontSize = 12.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    this.maxWidth = 420,
    this.spacing = 6,
    this.runSpacing = 6,
    this.crossAxisAlignment = WrapCrossAlignment.center,
  });

  final List<String> aliases;
  final double fontSize;
  final EdgeInsets padding;
  final double maxWidth;
  final double spacing;
  final double runSpacing;
  final WrapCrossAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    if (aliases.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      crossAxisAlignment: crossAxisAlignment,
      children: <Widget>[
        for (final a in aliases)
          AliasPill(
            text: a,
            fontSize: fontSize,
            padding: padding,
            maxWidth: maxWidth,
          ),
      ],
    );
  }
}
