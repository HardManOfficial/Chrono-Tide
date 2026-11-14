import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';
import '../../theme/app_styles.dart';
import 'settings_group_card.dart';

/// 设置页内的一个分组（标题 + 可选描述 + 若干子项）。
///
/// 2026-09-08 IA 重构引入的分组抽象；2026-11-13 UI 统一补了 [boxed]：
///
/// - `boxed: true`  → 子项收进**一张** [SettingsGroupCard]，子项之间自动分隔。
///   适用于「若干行设置」（开关 / 路径 / 按钮行）。这是新代码的默认选择。
/// - `boxed: false` → 子项各自渲染（保持旧行为）。用于 **单个复杂块**
///   （主题设计器、Magpie、云备份表单…）——那些块自己就是一张卡，
///   再包一层会变成「框中框」。
///
/// ⚠️ 默认值是 `false` 而不是 `true`：本次改造逐页迁移，未迁移的调用点
/// 必须保持原样零变化。新写的分组请显式传 `boxed: true`。
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
    this.description,
    this.isFirst = false,
    this.boxed = false,
    this.trailing,
  });

  /// 分组标题（如「游戏窗口」）。
  final String title;

  /// 分组下的一行说明，可选。
  final String? description;

  /// 分组内的设置行/卡片。
  final List<Widget> children;

  /// 是否为内容区第一个分组（去掉顶部间距）。
  final bool isFirst;

  /// 子项是否收进一张组卡（见类文档）。
  final bool boxed;

  /// 标题右侧的附加控件（如「全部重置」），暂未使用。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: _buildTitle()),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: AppSpacing.md),
                trailing!,
              ],
            ],
          ),
          if (description != null && description!.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.xs),
            Text(description!, style: AppStyles.labelMedium),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (boxed)
            SettingsGroupCard(children: children)
          else
            ..._spaced(children),
        ],
      ),
    );
  }

  Widget _buildTitle() {
    return Text(
      title,
      style: AppStyles.labelLarge.copyWith(color: AppStyles.bodySmall.color),
    );
  }

  /// 非组卡模式下子项之间插入固定间距（行与行紧密排列，形成列表感）。
  List<Widget> _spaced(List<Widget> items) {
    if (items.isEmpty) return items;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < items.length; i++) {
      if (i > 0) out.add(const SizedBox(height: AppSpacing.xs));
      out.add(items[i]);
    }
    return out;
  }
}
