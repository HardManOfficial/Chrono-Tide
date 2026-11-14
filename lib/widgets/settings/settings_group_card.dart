import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';

/// 一组设置共用的卡片容器（2026-11-13「设置页 UI 统一」）。
///
/// ## 为什么需要它
///
/// 改造前每个设置项各自是一张卡（`settings_modal.dart` 里有 12 处手写
/// `Container + Border.all + BoxShadow`），一屏能摞 5–6 个等权方框，
/// 眼睛找不到落点。本组件的职责是把**粒度下沉一层**：
/// 一张卡承载「一组设置」（2–5 行），行与行之间用发丝分隔线。
///
/// ## 视觉参数
///
/// 全部走 `AppStyle` 风格档，不写死颜色/线宽：
/// - 经典档（暖阳等 handdrawn）：卡面 = `sidebarBackground`，1.6px `border`，`e1` 硬影
/// - 极光档（frost / obsidian）：卡面 = `buttonBackground`，`wHairline` 发丝线，`e1` 软影
///
/// ## 硬约束
///
/// 卡内**不得**再出现带边框/阴影的子块（消除「框中框」）。
/// 需要强调的子块请用 `AppColors.placeholderBg` 填充 + 圆角 8、无边框。
class SettingsGroupCard extends StatelessWidget {
  const SettingsGroupCard({
    super.key,
    required this.children,
    this.dividerIndent = _kDividerIndent,
  });

  /// 卡内直接子项；相邻两项之间自动插入一条分隔线（最后一项之后没有）。
  final List<Widget> children;

  /// 分隔线左缩进。默认 60 = 行内边距 16 + 图标 32 + 间距 12，
  /// 让分隔线起点对齐**文字**起点而不是图标起点。
  final double dividerIndent;

  static const double _kDividerIndent = 60;

  @override
  Widget build(BuildContext context) {
    final bool modern = AppStyle.isModern;
    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: modern ? AppColors.buttonBackground : AppColors.sidebarBackground,
        borderRadius: BorderRadius.circular(AppStyle.rMd),
        border: Border.all(
          color: modern ? AppColors.borderLight : AppColors.border,
          width: modern ? AppStyle.wHairline : 1.6,
        ),
        boxShadow: AppStyle.e1,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _withDividers(),
      ),
    );
  }

  List<Widget> _withDividers() {
    if (children.length <= 1) return children;
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) {
        out.add(
          Padding(
            padding: EdgeInsets.only(left: dividerIndent),
            child: Container(height: 1, color: AppColors.borderLight),
          ),
        );
      }
      out.add(children[i]);
    }
    return out;
  }
}

/// 卡内的一段纯文字说明（不是可点的设置行，无 hover、不等高）。
///
/// 用于「快捷窗口手势」这类需要多行、又不适合塞进 56px 行的补充说明。
/// 左侧缩进与 [SettingsGroupCard.dividerIndent] 对齐，视觉上挂在上一行下面。
class SettingsCardNote extends StatelessWidget {
  const SettingsCardNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SettingsGroupCard._kDividerIndent,
        4,
        16,
        12,
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 18 / 12,
          color: AppColors.secondaryText,
        ),
      ),
    );
  }
}
