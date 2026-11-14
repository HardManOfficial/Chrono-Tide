import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';

/// 行尾的两三选项分段选择器（替代历史上的「两个等宽大按钮」）。
///
/// 用法：塞进 [SettingsTile.trailing]。宽度按选项数自适应，
/// 选项文案请控制在 2–4 个字（「精准」「宽松」「跟随」「直连」），
/// 否则在 820 最小窗口下会被挤。
class SettingsSegmented extends StatelessWidget {
  const SettingsSegmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.enabled = true,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: AppColors.placeholderBg,
          borderRadius: BorderRadius.circular(AppStyle.rLg),
          border: Border.all(
            color: AppColors.borderLight,
            width: AppStyle.isModern ? AppStyle.wHairline : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < labels.length; i++)
              _buildItem(i),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(int i) {
    final bool on = i == index;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: enabled ? () => onChanged(i) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: on ? AppColors.buttonBackground : Colors.transparent,
            borderRadius: BorderRadius.circular(AppStyle.rMd),
            border: Border.all(
              color: on ? AppColors.border : Colors.transparent,
              width: on ? 1.2 : 0,
            ),
          ),
          child: Text(
            labels[i],
            style: TextStyle(
              fontSize: 12,
              fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              height: 16 / 12,
              color: on ? AppColors.primaryText : AppColors.secondaryText,
            ),
          ),
        ),
      ),
    );
  }
}
