// elevation_hint_dialog.dart
// 「建议以管理员身份重启管理器」提示 —— 只弹一次，之后走 runas 逐次 UAC
//
// 背景（2026-10-24 启动兼容性升级，推荐项 4）：
// UAC 无法绕过。想全程静默只有一条路 —— **管理器自己已提权**，此时子进程
// 通过 CreateProcess 自动继承提权令牌，零弹窗。反之则每启动一个提权目标就
// 弹一次 UAC（超分还要为 Magpie 再弹一次）。
//
// 但「每次都弹提示」比弹 UAC 更烦，所以本提示**一生只弹一次**
// （`CompatPreference.elevationHintShown`），用户拒绝后不再打扰，
// 启动照样成功，只是每次要亲手点一次「是」。
//
// 🔴 一键重启的顺序陷阱：本应用有**单实例文件锁**（main.dart
// `_acquireSingleInstanceLock`）。若先拉起提权实例、再退出自己，
// 新实例会因拿不到锁而写入"显示窗口"请求后自杀 —— 结果是旧实例（仍然
// 非提权）被叫醒，什么都没变。所以必须**先安排延迟启动、再退出自己**：
// 由 detached 的 PowerShell 等 1.5s（等锁释放）再 `Start-Process -Verb RunAs`。
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/compat_preference.dart';
import '../services/elevation_service.dart';
import 'app_snack_bar.dart';
import 'confirm_dialog.dart';
import 'custom_title_bar.dart';

/// 提权重启的延迟毫秒数。
///
/// 必须留出「本进程退出 + 文件锁释放」的时间窗。1.5s 对 `exit(0)` 足够宽裕；
/// 太短会撞上单实例锁（见文件头注释），太长则用户感到迟滞。
const int _kRelaunchDelayMs = 1500;

/// 在需要提权、但管理器自身未提权时，弹一次「建议以管理员身份重启」。
///
/// [needsElevation] 为 false 时直接返回（不会读偏好、不会弹窗），
/// 因此可以在 UI 里无条件调用。
///
/// 静默跳过的情况：
/// - 已提权（无需建议）
/// - 提权状态未知（`isSelfElevated()` 返回 null，读取失败 ⇒ 不打扰用户）
/// - 本次安装已提示过（一生一次）
Future<void> maybeShowElevationHint(
  BuildContext context, {
  required bool needsElevation,
}) async {
  if (!needsElevation) return;

  if (ElevationService.isSelfElevated() != false) {
    debugPrint('[ELEVATION-HINT] 已提权或状态未知，跳过提示');
    return;
  }

  await CompatPreference.instance.ensureLoaded();
  if (CompatPreference.instance.elevationHintShown) return;

  // 先落账再弹：用户直接关掉弹窗（点遮罩 / ESC）也算已提示，不反复打扰
  await CompatPreference.instance.markElevationHintShown();

  if (!context.mounted) return;
  debugPrint('[ELEVATION-HINT] 管理器未提权，提示用户可重启以消除 UAC');

  final confirmed = await showConfirmDialog(
    context: context,
    title: '建议以管理员身份重启',
    message: '已开启「以管理员身份运行」。但当前 Chrono Tide 本身不是管理员，'
        'Windows 的权限模型决定了每次启动都要弹一次 UAC —— 启动游戏弹一次，'
        '超分启动还要为 Magpie 再弹一次。\n\n'
        '现在以管理员身份重启 Chrono Tide，本次开机内就不会再有任何 UAC 弹窗。',
    confirmText: '立即重启',
    cancelText: '暂不重启',
    hint: '不重启也能正常启动，只是每次都要手动点「是」。本提示只出现这一次。',
  );
  if (!confirmed) {
    debugPrint('[ELEVATION-HINT] 用户选择暂不重启，后续走 runas 逐次 UAC');
    return;
  }
  if (!context.mounted) return;
  await _relaunchElevatedThenExit(context);
}

/// 安排「延迟提权重启」并退出当前实例。
///
/// 顺序不可交换：先 spawn 延迟器 → 再 `performCleanExit`（内部 `exit(0)`）。
Future<void> _relaunchElevatedThenExit(BuildContext context) async {
  try {
    await _spawnDeferredElevatedLaunch();
    debugPrint('[ELEVATION-HINT] 已安排 ${_kRelaunchDelayMs}ms 后以管理员身份重启');
  } catch (e) {
    // PowerShell 被组策略禁用 / 被杀软拦截时兜底：明确告知手动操作方式
    debugPrint('[ELEVATION-HINT] ❌ 安排提权重启失败: $e');
    if (context.mounted) {
      AppSnackBar.error(context, '无法自动重启，请关闭本程序后右键「以管理员身份运行」');
    }
    return;
  }
  await CustomTitleBar.performCleanExit(context);
}

/// 用 detached 的 PowerShell 在延迟后以 runas 动词拉起自身。
///
/// 为什么必须借 PowerShell：`Process.start` 只能走 CreateProcess，
/// 而 CreateProcess **无法提权**（非提权父进程拉起提权目标 ⇒ 740）；
/// `ShellExecuteExW + runas` 虽然能提权，但它是**立即执行**的，
/// 无法等我们退出后再跑。延迟 + runas 两者都要 ⇒ 只能交给外部命令。
///
/// `ProcessStartMode.detached`：不建管道、不跟随父进程生命周期，
/// 本进程 `exit(0)` 后延迟器仍然存活。
Future<void> _spawnDeferredElevatedLaunch() async {
  final exe = Platform.resolvedExecutable;
  // PowerShell 单引号字符串内转义：' → ''
  final escaped = exe.replaceAll("'", "''");
  final script = 'Start-Sleep -Milliseconds $_kRelaunchDelayMs; '
      "Start-Process -FilePath '$escaped' -Verb RunAs";

  await Process.start(
    'powershell',
    <String>[
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-Command',
      script,
    ],
    mode: ProcessStartMode.detached,
  );
}
