import 'package:flutter/material.dart';

import '../services/avatar_preset_service.dart';
import '../services/current_user_store.dart';
import '../theme/app_colors.dart';
import 'interactive_wrapper.dart';

/// 内置头像选择器 —— 34 张系统头像的网格视图。
///
/// 设计文档：`docs/DEV/features/local_first_account_and_avatar_plan.md` §8.1。
///
/// 🔴 **两种模式，只允许两个入口调用**（LOCAL-AVATAR-ENTRY，2026-10-23）：
/// - [show]（`applyToStore: true`）：**设置 → 个人资料**。选中即写
///   `CurrentUserStore`，四处头像同步刷新。
/// - [pick]（`applyToStore: false`）：**注册表单**。此时还没有账户可写，
///   只把 id 返回给调用方，注册成功后才上传/落盘。
///
/// 悬浮按钮、用户卡片、BPM 顶栏一律只做**展示**，不提供服务入口。
class AvatarPickerDialog extends StatefulWidget {
  /// 网格的初始选中项（纯选择模式下由调用方传入）。
  final String initialSelection;

  /// `true` = 选中即写 store；`false` = 只返回值（注册表单）。
  final bool applyToStore;

  const AvatarPickerDialog({
    super.key,
    this.initialSelection = '',
    this.applyToStore = true,
  });

  /// 设置页入口：写 store。非本地账户直接返回 false。
  static Future<bool> show(BuildContext context) async {
    if (!CurrentUserStore.instance.isLocal) {
      return false;
    }
    final result = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => const AvatarPickerDialog(),
    );
    return result != null && result.isNotEmpty;
  }

  /// 注册表单入口：**不写 store**，返回选中的 id（取消返回 null）。
  static Future<String?> pick(BuildContext context, {String current = ''}) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => AvatarPickerDialog(
        initialSelection: current,
        applyToStore: false,
      ),
    );
  }

  @override
  State<AvatarPickerDialog> createState() => _AvatarPickerDialogState();
}

class _AvatarPickerDialogState extends State<AvatarPickerDialog> {
  String _current = '';

  @override
  void initState() {
    super.initState();
    // 调用方显式指定的优先；否则退回「当前身份正在用的那张」
    // —— 设置页走 show() 时不传参，必须靠这一步才能高亮当前头像。
    _current = widget.initialSelection.isNotEmpty
        ? widget.initialSelection
        : (CurrentUserStore.instance.user?.avatarPreset ?? '');
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          width: 588,
          height: 548,
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
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),
              Expanded(child: _buildGrid()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Text(
          '选择头像',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 20,
            height: 28 / 20,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '系统提供的头像，点一下即刻生效',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 12,
              height: 16 / 12,
              color: AppColors.secondaryText,
            ),
          ),
        ),
        // 随机换一张：轻量循环按钮（「随机抽取」入口，必然排除当前那张）。
        InteractiveWrapper(
          onTap: _shuffle,
          hoverScale: 1.12,
          cursor: SystemMouseCursors.click,
          child: Tooltip(
            message: '随机换一张',
            waitDuration: const Duration(milliseconds: 400),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.buttonBackground,
                border: Border.all(color: AppColors.borderLight, width: 1.4),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.refresh_rounded,
                size: 17,
                color: AppColors.border,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        InteractiveWrapper(
          // ⚠️ 必须不带参数 pop：本对话框按 String 返回值泛型化，
          // pop(false) 会在 `showDialog<String>` 处抛类型转换错。
          onTap: () => Navigator.of(context).pop(),
          child: Icon(Icons.close, size: 22, color: AppColors.border),
        ),
      ],
    );
  }

  Widget _buildGrid() {
    return FutureBuilder<List<String>>(
      future: AvatarPresetService.ensureLoaded(),
      builder: (context, snapshot) {
        // 列举失败时 ensureLoaded 内部已回退常量表，这里只需等它返回。
        final ids = snapshot.data;
        if (ids == null || ids.isEmpty) {
          return Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
              ),
            ),
          );
        }
        return GridView.builder(
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          itemCount: ids.length,
          itemBuilder: (context, index) {
            final id = ids[index];
            return _buildCell(id);
          },
        );
      },
    );
  }

  Widget _buildCell(String id) {
    final selected = id == _current;
    return InteractiveWrapper(
      onTap: () => _pick(id),
      hoverScale: 1.05,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.placeholderCover,
          border: Border.all(
            color: selected ? AppColors.selectedAccent : AppColors.borderLight,
            width: selected ? 2.6 : 1,
          ),
        ),
        padding: const EdgeInsets.all(3),
        child: ClipOval(
          child: Image.asset(
            AvatarPresetService.pathOf(id),
            fit: BoxFit.cover,
            // 网格单元 72px，无需按 396px 原图解码。
            cacheWidth: 160,
            errorBuilder: (_, __, ___) => Icon(
              Icons.broken_image_outlined,
              size: 18,
              color: AppColors.inputHint,
            ),
          ),
        ),
      ),
    );
  }

  /// 随机换一张并立即确认（`randomExcept` 保证不等于当前那张）。
  Future<void> _shuffle() async {
    final next = AvatarPresetService.randomExcept(_current);
    if (next.isEmpty) return;
    await _pick(next);
  }

  Future<void> _pick(String id) async {
    if (!widget.applyToStore) {
      // 注册表单：没有账户可写，只把选择交还给调用方。
      Navigator.of(context).pop(id);
      return;
    }
    await CurrentUserStore.instance.selectLocalAvatarPreset(id);
    if (!mounted) return;
    Navigator.of(context).pop(id);
  }
}
