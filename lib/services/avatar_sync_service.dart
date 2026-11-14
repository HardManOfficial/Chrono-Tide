import 'package:flutter/foundation.dart';

import '../modules/auth/auth_service.dart';
import '../modules/auth/local_account_service.dart';
import '../modules/auth/user_model.dart';
import 'avatar_preset_service.dart';

/// 登录后的头像对齐 —— 把「本地选的那张头像」推成云端账号头像。
///
/// 设计文档：`docs/DEV/features/local_first_account_and_avatar_plan.md` §1.2 G7。
///
/// 🔴 铁律：**只在云端没有头像时上传**。云端已有头像（老账号）一律保留，
/// 绝不允许本机的随机内置头像把人家原来的头像悄悄覆盖掉（方案 §1.2 用户决策）。
class AvatarSyncService {
  AvatarSyncService._();

  /// 返回是否真的上传了（调用方据此决定要不要重新拉一次云端用户资料）。
  ///
  /// [cloud] 已知的登录用户（可省一次 `getCurrentUser` 请求）。
  static Future<bool> uploadLocalPresetIfCloudEmpty({
    UserModel? cloud,
  }) async {
    try {
      final user = cloud ?? await AuthService.getCurrentUser();
      if (user == null || !user.isLoggedIn) return false;

      // ① 云端已有头像 → 保留云端，什么都不做
      if (user.hasAvatar) {
        debugPrint('[AVATAR-SYNC] 云端已有头像，保留云端（不上传本地）');
        return false;
      }

      // ② 本地账户不存在 / 头像来源不是内置池 → 跳过
      if (!LocalAccountService.exists) return false;
      final preset = LocalAccountService.avatarPreset;
      if (preset.isEmpty) {
        // 本地是「用户上传的自定义图」时不自动上传：原始文件名/扩展名未留存，
        // 无法保证 PB 端 content-type 正确（本期非目标，用户可在设置页重传）。
        debugPrint('[AVATAR-SYNC] 本地无内置头像（自定义图不自动上传），跳过');
        return false;
      }

      // ③ 读内置头像字节并上传（此处允许 IO：明确需要字节的路径）
      final bytes = await AvatarPresetService.loadBytes(preset);
      if (bytes == null || bytes.isEmpty) return false;

      final result = await AuthService.uploadAvatar(
        fileName: '$preset.webp',
        bytes: bytes,
      );
      if (result.code == AuthResultCode.success) {
        debugPrint('[AVATAR-SYNC] ✅ 本地头像 $preset 已同步到云端账号');
        return true;
      }
      debugPrint('[AVATAR-SYNC] ⚠️ 头像上传失败（不阻断登录）: ${result.message}');
      return false;
    } catch (e) {
      // 失败静默：头像不是登录的必要环节（方案 §4.4 降级策略）
      debugPrint('[AVATAR-SYNC] ⚠️ 头像同步异常（已忽略）: $e');
      return false;
    }
  }
}
