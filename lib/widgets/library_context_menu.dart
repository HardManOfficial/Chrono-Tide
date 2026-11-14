import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import 'interactive_wrapper.dart';

class LibraryContextMenu extends StatelessWidget {
  final Offset position;
  final VoidCallback onDetails;
  final VoidCallback onLaunchManager;

  /// PATCH-VAULT：库页按单个游戏管理本地补丁的唯一核心入口。
  final VoidCallback onPatchVault;
  final VoidCallback onCollection;
  final VoidCallback onDelete;
  final VoidCallback onClose;

  const LibraryContextMenu({
    super.key,
    required this.position,
    required this.onDetails,
    required this.onLaunchManager,
    required this.onPatchVault,
    required this.onCollection,
    required this.onDelete,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    // UX-19: 边界检测，菜单不溢出屏幕右侧或底部
    final screenSize = MediaQuery.sizeOf(context);
    const menuWidth = 160.0;
    // PATCH-VAULT 新增第 5 项「补丁管理」：高度必须同步，否则底部上翻边界算错。
    // 🔴 flutter_tester 实测 5 项菜单实高 251px；估成 248 会让上翻后底部
    // 仍溢出屏幕 5px（menuHeight 只能高估、不能低估）。
    const menuHeight = 256.0;
    const margin = 8.0;

    final maxLeft = math.max(margin, screenSize.width - menuWidth - margin);
    final left = position.dx.clamp(margin, maxLeft);

    double top;
    if (position.dy + menuHeight > screenSize.height - margin) {
      // 底部放不下时上翻至点击点上方
      top = math.max(margin, position.dy - menuHeight);
    } else {
      top = position.dy;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                // v3.9 Aurora：白卡面 + e3 浮层阴影 + 发丝边 + 大圆角
                border: AppStyle.isModern
                    ? Border.all(
                        color: AppColors.borderLight, width: AppStyle.wHairline)
                    : Border.all(color: AppColors.border, width: 2),
                boxShadow: AppStyle.isModern
                    ? AppStyle.e3
                    : [
                        BoxShadow(
                          color: AppColors.border.withOpacity(0.13),
                          offset: const Offset(4, 5),
                          blurRadius: 0,
                        ),
                      ],
                color: AppStyle.isModern
                    ? AppColors.buttonBackground
                    : AppColors.background,
                borderRadius: AppStyle.isModern
                    ? BorderRadius.circular(AppStyle.rMd)
                    : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildMenuItem(
                    icon: Icons.info_outline_rounded,
                    label: '详 情',
                    labelColor: AppColors.titleBrown,
                    onTap: onDetails,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.tune_rounded,
                    label: '启动管理',
                    labelColor: AppColors.titleBrown,
                    onTap: onLaunchManager,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.extension_outlined,
                    label: '补丁管理',
                    labelColor: AppColors.titleBrown,
                    onTap: onPatchVault,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.collections_bookmark_outlined,
                    label: '加入收藏夹',
                    labelColor: AppColors.titleBrown,
                    onTap: onCollection,
                    showDivider: true,
                  ),
                  _buildMenuItem(
                    icon: Icons.delete_outline_rounded,
                    label: '删 除',
                    labelColor: AppColors.dangerRed,
                    onTap: onDelete,
                    showDivider: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color labelColor,
    required VoidCallback onTap,
    required bool showDivider,
  }) {
    return InteractiveWrapper(
      onTap: () {
        onClose();
        onTap();
      },
      child: Container(
        // 🔴 PATCH-VAULT 渲染探针实测：原右内边距 71 会让 160px 宽的菜单项
        // 只剩 73px 给 Row（Icon 18 + 「加入收藏夹」约 89 = 107），
        // 横向溢出约 20px。收到 32 后可用 112px，5 项均不再溢出。
        padding: const EdgeInsets.fromLTRB(16, 11, 32, 13),
        decoration: showDivider
            ? BoxDecoration(
                border: Border(
                  bottom:
                      BorderSide(color: AppColors.placeholderCover, width: 1),
                ),
              )
            : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppColors.border),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 24 / 16,
                letterSpacing: 1.8,
                color: labelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
