import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_styles.dart';

/// 每个设置 tab 顶部的一级页头：标题 + 一句话说明。
///
/// ## 为什么加它
///
/// 改造前窗口页头是 30px 装饰字（`设置 / Settings`），组标题 14px、行标题 14px，
/// 中间只有一个层级差，扫视时没有落点，打开设置不知道自己在哪一页。
/// 页头把「我在哪 + 这页能干什么」补上，同时把层级拉开：
///
///     窗口标题(22 装饰字) > 页面标题(20/600) > 分组标题(13/600) > 行标题(14/600)
///
/// 注意：行标题字号与分组标题接近是**刻意**的——行靠缩进和图标区分层级，
/// 不靠字号堆叠（字号档位越少越整洁，见方案 §2.1）。
class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({
    super.key,
    required this.title,
    this.description,
    this.trailing,
  });

  /// 页面标题，通常就是侧栏的 tab 名。
  final String title;

  /// 一句话说清这页能干什么（≤ 2 行）。
  final String? description;

  /// 标题右侧的附加控件（目前未使用，留给后续「本页操作」按钮）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final bool hasDesc = description != null && description!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 28 / 20,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.md),
                trailing!,
              ],
            ],
          ),
          if (hasDesc) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(
              description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 18 / 12,
                color: AppColors.secondaryText,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
