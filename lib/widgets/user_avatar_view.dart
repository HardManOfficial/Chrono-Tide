import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../modules/auth/user_model.dart';
import '../services/avatar_preset_service.dart';
import '../services/current_user_store.dart';
import '../services/user_cache_service.dart';
import '../theme/app_colors.dart';

/// 统一的用户头像渲染组件 —— 全软件**唯一**的圆形头像实现。
///
/// 设计文档：`docs/DEV/features/local_first_account_and_avatar_plan.md` §3.3 / §4.2。
///
/// 改造前「当前用户头像」有 4 个显示点各写一份，且刷新依赖父级 `setState` +
/// 构造参数下发 —— 用户资料浮窗在 `OverlayEntry` 里（一次性快照）根本收不到。
/// 本组件把订阅放进 Widget 内部（[AnimatedBuilder] 监听 [CurrentUserStore]），
/// 于是「换头像 → 全部显示点自动跟随」不再依赖任何父级传参。
///
/// 优先级（方案 §3.2）：
/// `previewBytes`（设置页临时预览）> `avatarBytes`（用户上传）>
/// `avatarUrl`（云端图，带 Bearer 下载）> `avatarPreset`（内置池）> 默认 SVG 图标。
class CtUserAvatar extends StatelessWidget {
  final double size;

  /// 显式指定身份。为 `null` 时**自动订阅** [CurrentUserStore]（推荐用法）。
  final UserModel? user;

  /// 临时预览字节（设置页刚选完图、尚未保存时用）。优先级最高。
  final Uint8List? previewBytes;

  const CtUserAvatar({
    super.key,
    required this.size,
    this.user,
    this.previewBytes,
  });

  /// 默认头像图标的两处引用点统一走这里（原先 3 份函数 + 2 份内联）。
  static Widget buildDefaultIcon({
    required double iconSize,
    Color? color,
  }) {
    return Center(
      child: SvgPicture.asset(
        'assets/images/user_avatar_icon.svg',
        width: iconSize,
        height: iconSize,
        colorFilter: ColorFilter.mode(
          color ?? AppColors.inputHint,
          BlendMode.srcIn,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final explicit = user;
    if (explicit != null) {
      return _buildContent(context, explicit, previewBytes);
    }
    if (previewBytes != null) {
      return _buildContent(context, null, previewBytes);
    }
    return AnimatedBuilder(
      animation: CurrentUserStore.instance,
      builder: (context, _) =>
          _buildContent(context, CurrentUserStore.instance.user, null),
    );
  }

  Widget _buildContent(
      BuildContext context, UserModel? identity, Uint8List? preview) {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
    // 44px 显示位不得按 396px 原图解码（方案 §6 内存预算）。
    final cachePx = (size * dpr).round().clamp(16, 1024);

    Widget child;
    if (preview != null && preview.isNotEmpty) {
      child = _memory(preview, cachePx, () => _fallback(identity));
    } else if (identity != null && identity.hasAvatarBytes) {
      child = _memory(identity.avatarBytes!, cachePx, () => _fallback(identity));
    } else if (identity != null && identity.avatarUrl.isNotEmpty) {
      // 复用既有下载器（带 Bearer + 本地缓存），默认头像槽位传「内置头像」，
      // 于是「下载失败」会优雅落到 preset 而不是灰图标。
      child = UserCacheService.buildUserAvatar(
        size: size,
        defaultAvatar: _fallback(identity),
        avatarUrl: identity.avatarUrl,
      );
    } else {
      child = _fallback(identity);
    }

    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          // 换头像要有可见的变化反馈（无二次确认，方案 §13-Q6）。
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(
            key: ValueKey(_signature(identity, preview)),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _memory(Uint8List bytes, int cachePx, Widget Function() onError) {
    return Image.memory(
      bytes,
      width: size,
      height: size,
      cacheWidth: cachePx,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => onError(),
    );
  }

  /// 兜底链的最后一环：内置头像池 → 默认 SVG 图标。
  Widget _fallback(UserModel? identity) {
    final preset = identity?.avatarPreset ?? '';
    if (preset.isNotEmpty) {
      return Image.asset(
        AvatarPresetService.pathOf(preset),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => buildDefaultIcon(iconSize: size * 0.45),
      );
    }
    return buildDefaultIcon(iconSize: size * 0.45);
  }

  /// 动画切换的身份签名：`AnimatedSwitcher` 只在签名变化时播淡入淡出。
  ///
  /// 用「字节长度」而非 identityHashCode：`LocalAccountService.load()` 每次都重新
  /// base64 解码出新对象，用对象身份会导致每次 reload 都白播一次动画。
  String _signature(UserModel? identity, Uint8List? preview) {
    return '${identity?.id}|${identity?.avatarPreset}|'
        '${identity?.avatarUrl}|${identity?.avatarBytes?.length ?? 0}|'
        '${preview?.length ?? 0}';
  }
}
