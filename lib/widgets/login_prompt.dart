import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 云端功能的统一拦截文案。
///
/// 改造后用户默认以**本地身份**使用软件，但「获取下载 / 点赞 / 上传资源 / 发布」
/// 这类云端功能仍必须登录。文案要说清「本地管理不受影响」，否则用户会误以为
/// 软件被阉割。见方案 §9-P1-9。
const String kCloudFeatureNeedsAccount = '该功能需要账号 · 本地管理功能不受影响';

/// 「该功能需要账号」轻量对话框 + 全局登录入口。
///
/// 为什么不复用 `AppSnackBar`：那是 `SystemNoticeService` 的通知通道，没有
/// action 参数，改它波及全软件提示（方案 §9 的 P1 约束）。这里用独立对话框
/// 提供可达的【登录】按钮，登录浮层本身仍由 `MainContainer` 的 Overlay 统一管理
/// （项目稳定区的既有设计），所以这里只放一个静态注入点，不自己开浮层。
class LoginPrompt {
  LoginPrompt._();

  /// 由 `MainContainer` 注入（打开登录浮层）。
  ///
  /// 为空时（如独立/测试环境）对话框只提示不跳转，不会崩。
  static VoidCallback? onRequestLogin;

  /// 弹出提示。返回 `true` 表示用户点了【去登录】。
  static Future<bool> show(BuildContext context) async {
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (dialogContext) => _LoginPromptDialog(),
    );
    if (go == true) {
      onRequestLogin?.call();
      return true;
    }
    return false;
  }
}

class _LoginPromptDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          width: 388,
          decoration: BoxDecoration(
            color: AppColors.sidebarBackground,
            border: Border.all(color: AppColors.border, width: 1.6),
            boxShadow: [
              BoxShadow(
                color: AppColors.border,
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '该功能需要账号',
                style: TextStyle(
                  fontSize: 18,
                  height: 26 / 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primaryText,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '登录后即可使用下载、分享、点赞等云端功能。\n'
                '本地管理功能（游戏库、启动、存档）不受任何影响。',
                style: TextStyle(
                  fontSize: 13,
                  height: 20 / 13,
                  color: AppColors.secondaryText,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _PromptButton(
                    label: '知道了',
                    color: AppColors.buttonBackground,
                    textColor: AppColors.secondaryText,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 10),
                  _PromptButton(
                    label: '去登录',
                    color: AppColors.selectedAccent,
                    textColor: AppColors.primaryText,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PromptButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  const _PromptButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: AppColors.border, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: AppColors.borderLight,
                offset: const Offset(2, 2),
                blurRadius: 0,
              ),
            ],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              height: 20 / 14,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}
