import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../theme/app_style.dart';
import '../modules/auth/user_model.dart';
import '../services/current_user_store.dart';
import '../services/network_status_service.dart';
import 'interactive_wrapper.dart';
import 'user_avatar_view.dart';

/// 用户头像悬浮按钮。
///
/// 位于内容区右下角。除原有头像点击入口外，新增网络状态提示：
/// - 持久小圆点（QQ 式）：头像右下角 10px 状态圆点，始终可见。
/// - 悬停浮动气泡（微信式）：鼠标悬停 ~300ms 后在头像上方弹出气泡，
///   显示在线/离线状态 + 下指三角指针。
/// 两种提示均监听 [NetworkStatusService] 实时刷新，收起/展开侧边栏态均生效。
class FloatingUserButton extends StatefulWidget {
  final VoidCallback onTap;
  final UserModel? user;

  const FloatingUserButton({super.key, required this.onTap, this.user});

  @override
  State<FloatingUserButton> createState() => _FloatingUserButtonState();
}

class _FloatingUserButtonState extends State<FloatingUserButton> {
  Timer? _bubbleTimer;
  bool _showBubble = false;

  /// 首启动一次性提示气泡（说明「这里是账户窗口」）。
  ///
  /// 🔴 LOCAL-AVATAR-ENTRY（2026-10-23）：本按钮**只做头像展示 + 打开用户窗口**，
  /// 不提供任何改头像能力（改头像唯一入口 = 设置 → 个人资料 / 注册表单）。
  /// 因此这里的提示只能指向「账户窗口」本身，且**自动消失、无按钮、无箭头指引**。
  bool _hintVisible = false;

  /// 提示气泡自动收起定时器（用户不需要点任何东西）。
  Timer? _hintTimer;

  /// prefs key：账户窗口提示是否已展示过（写一次即不再打扰）。
  static const String _kHintShownKey = 'floating_button_hint_shown';

  /// 提示停留时长：够读完一行，又不至于一直挡着界面。
  static const Duration _hintDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _loadHint();
  }

  Future<void> _loadHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final shown = prefs.getBool(_kHintShownKey) ?? false;
    if (shown) return;
    setState(() => _hintVisible = true);
    // 到点自动收起 + 落盘，不需要用户点「知道了」。
    _hintTimer = Timer(_hintDuration, _dismissHint);
  }

  /// 收起提示并记账（自动超时 / 点击头像都会走到这里，幂等）。
  Future<void> _dismissHint() async {
    _hintTimer?.cancel();
    _hintTimer = null;
    if (_hintVisible) {
      if (mounted) setState(() => _hintVisible = false);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHintShownKey, true);
  }

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    _hintTimer?.cancel();
    super.dispose();
  }

  void _onEnter(dynamic _) {
    // 延迟显示气泡，避免鼠标快速划过时闪烁
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _showBubble = true);
    });
  }

  void _onExit(dynamic _) {
    setState(() => _showBubble = false);
    _bubbleTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 40,
      bottom: 40,
      // 外层 MouseRegion 检测 hover 用于气泡显隐；与内层 InteractiveWrapper 的
      // MouseRegion 共存（Flutter 中祖先与后代 MouseRegion 都收 enter/exit）。
      child: MouseRegion(
        onEnter: _onEnter,
        onExit: _onExit,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            InteractiveWrapper(
              // 点开用户窗口即视为「已经发现这个入口」，顺手收掉提示
              onTap: () {
                _dismissHint();
                widget.onTap();
              },
              hoverScale: 1.08,
              child: _buildAvatar(),
            ),
            // 持久状态圆点（QQ 式）
            _buildStatusBadge(),
            // 首启动提示与悬停状态气泡共用同一槽位（AnimatedSwitcher 交叉淡入淡出，
            // 提示超时消失时是「淡出」而不是「瞬间消失」）。
            Positioned(
              right: 0,
              bottom: 66,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: _hintVisible
                    ? IgnorePointer(
                        key: const ValueKey('account-hint'),
                        child: _buildAccountHint(),
                      )
                    // 悬停浮动气泡（微信式）
                    : AnimatedOpacity(
                        key: const ValueKey('status-bubble'),
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        opacity: _showBubble ? 1.0 : 0.0,
                        child: AnimatedSlide(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                          offset:
                              _showBubble ? Offset.zero : const Offset(0, 0.3),
                          child: IgnorePointer(
                            // 气泡不拦截鼠标事件，避免影响头像 hover
                            ignoring: !_showBubble,
                            child: _buildStatusBubble(),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // v3.9 Aurora：发丝边 + 柔光海拔（经典档硬影保留）
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e2
            : [
                BoxShadow(
                  color: AppColors.border,
                  offset: const Offset(2, 3),
                  blurRadius: 0,
                ),
              ],
        color: AppColors.placeholderCover,
      ),
      padding: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border, width: 1),
          color: AppColors.sidebarBackground,
        ),
        alignment: Alignment.center,
        child: ClipOval(
          // 内部订阅 CurrentUserStore：换头像后本处自动跟随，无需父级 setState
          child: const CtUserAvatar(size: 44),
        ),
      ),
    );
  }

  /// 持久状态圆点（头像右下角），始终可见，监听 NetworkStatusService 实时刷新。
  Widget _buildStatusBadge() {
    return AnimatedBuilder(
      animation: NetworkStatusService.instance,
      builder: (context, _) {
        final online = NetworkStatusService.instance.isOnline;
        final color = online ? AppColors.successGreen : AppColors.dangerRed;
        return Positioned(
          right: 2,
          bottom: 2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: AppColors.sidebarBackground,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: color.withOpacity(0.5), blurRadius: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 悬停浮动气泡：圆点 + 文字 + 下指三角指针。
  Widget _buildStatusBubble() {
    return AnimatedBuilder(
      animation: NetworkStatusService.instance,
      builder: (context, _) {
        final online = NetworkStatusService.instance.isOnline;
        final color = online ? AppColors.successGreen : AppColors.dangerRed;
        final label = online ? '在线' : '离线';
        return Semantics(
          label: online ? '在线' : '离线',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.buttonBackground,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withOpacity(0.4), width: 1),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.border.withOpacity(0.15),
                      offset: const Offset(0, 2),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: color.withOpacity(0.5), blurRadius: 3),
                        ],
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
              // 下指三角指针（朝向头像）
              CustomPaint(
                size: const Size(10, 5),
                painter: _BubbleTailPainter(
                  color: AppColors.buttonBackground,
                  borderColor: color.withOpacity(0.4),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 首启动一次性提示：**只说「这里是账户窗口」**，不涉及头像。
  ///
  /// 交互约束（用户明确要求）：无按钮、无关闭叉、不指向任何具体按钮，
  /// 5 秒后自动淡出并记账，之后永不再现。
  Widget _buildAccountHint() {
    final isLocal =
        widget.user?.isLocalAccount ?? CurrentUserStore.instance.isLocal;
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 220),
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            decoration: BoxDecoration(
              color: AppColors.buttonBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.selectedAccent.withOpacity(0.5),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border.withOpacity(0.15),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '账户窗口',
                  style: TextStyle(
                    fontSize: 13,
                    height: 18 / 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  isLocal ? '点这里查看资料、登录或退出' : '点这里查看资料与账号设置',
                  style: TextStyle(
                    fontSize: 12,
                    height: 17 / 12,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          CustomPaint(
            size: const Size(10, 5),
            painter: _BubbleTailPainter(
              color: AppColors.buttonBackground,
              borderColor: AppColors.selectedAccent.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 气泡下指三角指针绘制器。指针朝下，对齐头像中心。
class _BubbleTailPainter extends CustomPainter {
  final Color color;
  final Color borderColor;

  const _BubbleTailPainter({required this.color, required this.borderColor});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 填充三角
    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w, 0)
      ..lineTo(w / 2, h)
      ..close();
    canvas.drawPath(path, fillPaint);
    // 左右两边描边（与气泡边框衔接，底边不描边避免与头像重叠）
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final leftPath = Path()..moveTo(0, 0)..lineTo(w / 2, h);
    final rightPath = Path()..moveTo(w, 0)..lineTo(w / 2, h);
    canvas.drawPath(leftPath, borderPaint);
    canvas.drawPath(rightPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter oldDelegate) =>
      color != oldDelegate.color || borderColor != oldDelegate.borderColor;
}
