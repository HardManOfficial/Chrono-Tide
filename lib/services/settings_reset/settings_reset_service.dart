/// 「恢复默认设置」服务层：真正落地清空 + 无法只靠删键完成的副作用。
///
/// 三层分工（改这个功能前先看清楚，别把逻辑混在一起）：
/// - `settings_reset_core.dart`：纯 Dart 的**域定义 + 键清单 + 编排**（可裸 VM 跑）；
/// - **本文件**：`SharedPreferences` 注入 + 注册表 / 主题这类**跨进程副作用**；
/// - `widgets/settings/settings_reset_dialog.dart`：勾选面板与结果页。
///
/// ## 为什么恢复之后要重启
///
/// 全项目 30+ 个偏好服务都是「启动时读一次、缓存在字段里」的单例
/// （`_loaded` 闸），删键只改了磁盘，内存里仍是旧值 —— 而且不少服务的 setter
/// 会把内存值**写回**磁盘，边用边把恢复结果弄脏。与其给每个服务加一个
/// `reload()`（30 处改动 + 各自的加载顺序陷阱），不如明确「恢复 → 重启」：
/// 语义干净、落地零风险，用户也只多等一次重启。
///
/// 例外：**主题**在恢复时立刻切回默认（调用公开的 `AppThemeManager.setTheme`），
/// 给用户一个「确实生效了」的即时视觉反馈，否则会以为按钮没反应。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_theme_manager.dart';
import '../autostart_service.dart';
import '../download_intensity.dart';
import 'settings_reset_core.dart';

/// 恢复默认设置的唯一入口。
class SettingsResetService {
  const SettingsResetService._();

  /// 执行恢复。[domains] 为空时直接返回空报告（不发无谓的写请求）。
  static Future<SettingsResetReport> restore({
    required Set<SettingsResetDomain> domains,
  }) async {
    if (domains.isEmpty) {
      return SettingsResetReport(domains: <SettingsResetDomain>{});
    }

    // 副作用说明统一收集，最后一次性挂到报告上（面板按顺序展示给用户）。
    final List<String> sideEffects = <String>[];

    // ① 前置副作用：开机自启的开关真身在注册表，且 `AutoStartService.disable()`
    //    自己会把 `autostart_enabled` 写成 false —— 必须在统一删键**之前**做，
    //    否则删完键又被写回一个 false，日志里就会多一条"疑似未清理"的噪音。
    if (domains.contains(SettingsResetDomain.gameLaunch)) {
      await _disableAutostart(sideEffects);
    }

    // ② 统一删键（唯一事实源在 core 的键清单里）
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('[SETTINGS-RESET] ❌ 读取偏好失败: $e');
      return SettingsResetReport(domains: domains.toSet())
        ..fatalError = '读取偏好文件失败：$e';
    }

    final SettingsResetReport report = await runSettingsReset(
      domains: domains,
      contains: (String key) async => prefs.containsKey(key),
      remove: (String key) => prefs.remove(key),
    );
    // 注意：`sideEffects` 先不挂到报告上 —— ①③ 两段的说明都要按发生顺序追加，
    // 等信息补全后（第 ③ 段末尾）一次性 addAll。

    // ③ 即时生效的少量改动（其余一律等重启）
    if (domains.contains(SettingsResetDomain.appearance)) {
      await _restoreDefaultTheme(sideEffects);
    }
    if (domains.contains(SettingsResetDomain.networkStorage)) {
      // 限速是进程内的令牌桶；不清零的话"恢复默认"后仍然被限速，用户会认为失败
      DownloadThrottle.configure(0);
      sideEffects.add('已解除本次会话的下载限速');
    }
    report.sideEffects.addAll(sideEffects);

    debugPrint('[SETTINGS-RESET] ✅ $report');
    return report;
  }

  /// 关闭开机自启（含 `HKCU\...\Run` 注册表项）。失败只记日志不阻断恢复。
  static Future<void> _disableAutostart(List<String> sideEffects) async {
    try {
      if (!await AutoStartService.instance.isEnabled()) return;
      final bool ok = await AutoStartService.instance.disable();
      if (ok) {
        sideEffects.add('已关闭开机自启（含注册表启动项）');
      } else {
        sideEffects.add('开机自启注册表项删除失败，请在「游戏与启动」页手动关闭');
      }
    } catch (e) {
      debugPrint('[SETTINGS-RESET] 关闭开机自启异常: $e');
      sideEffects.add('开机自启状态未知（读取注册表异常），请手动确认');
    }
  }

  /// 主题立刻回到默认（暖阳）。这是本功能唯一"立即看得见"的效果。
  static Future<void> _restoreDefaultTheme(List<String> sideEffects) async {
    try {
      await AppThemeManager.instance.setTheme(CTTheme.warmSun);
      sideEffects.add('主题已切回默认（暖阳）');
    } catch (e) {
      debugPrint('[SETTINGS-RESET] 切回默认主题失败: $e');
      sideEffects.add('主题将在重启后回到默认');
    }
  }

  /// 安排「延迟 1.5 秒拉起新实例」，供 UI 在 `performCleanExit` 之前调用。
  ///
  /// 🔴 必须延迟：本应用有**单实例文件锁**（`main.dart::_acquireSingleInstanceLock`）。
  /// 先拉起新实例、再退出自己 ⇒ 新实例抢不到锁，只会写入一个"显示窗口"请求后
  /// 自杀 —— 用户看到的是窗口闪一下、什么都没变。
  ///
  /// 用 detached 的 PowerShell 而不是 `Process.start(exe)`：后者没有"等一会儿"
  /// 的能力，退出与拉起之间必然重叠。`detached` 保证本进程 `exit(0)` 后
  /// 延迟器仍然存活。
  ///
  /// 返回 false 表示没安排上（PowerShell 被组策略/杀软拦），调用方应改为
  /// 提示用户手动重启。
  static Future<bool> scheduleRelaunch({int delayMs = 1500}) async {
    try {
      final String exe = Platform.resolvedExecutable;
      // PowerShell 单引号字符串内转义：' → ''
      final String escaped = exe.replaceAll("'", "''");
      final String script =
          'Start-Sleep -Milliseconds $delayMs; Start-Process -FilePath \'$escaped\'';
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
      debugPrint('[SETTINGS-RESET] 已安排 ${delayMs}ms 后重启');
      return true;
    } catch (e) {
      debugPrint('[SETTINGS-RESET] ❌ 安排重启失败: $e');
      return false;
    }
  }
}
