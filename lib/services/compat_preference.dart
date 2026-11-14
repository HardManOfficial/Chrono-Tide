/// 全局「启动兼容性自动配置」总开关偏好。
///
/// 语义：开启时，每次启动游戏前把该 exe 的兼容性属性校正为
///   `~ WIN8RTM DISABLEDXMAXIMIZEDWINDOWEDMODE HIGHDPIAWARE`
/// （详见 `game_compatibility_service.dart`）；关闭时撤销**本应用写入过**的标志，
/// 用户手动勾选的其他兼容性项一律不动。
///
/// 默认**开启**（用户 2026-10-24 明确要求）。关闭后仍然保留每游戏的
/// 「以管理员身份运行」开关 —— 两者是独立维度。
///
/// 刻意**懒加载**、不接 `main.dart` 稳定区（与 `font_override_prefs.dart` 同策略）：
/// 未加载时 `enabled` 返回默认值 `true`，与语义一致，不会出现首屏跳变。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'game_compatibility_service.dart';

class CompatPreference extends ChangeNotifier {
  /// 总开关（默认 true）
  static const String _kEnabled = 'compat_auto_config_enabled';

  /// 是否已经给用户看过「建议以管理员身份重启管理器」的提示
  static const String _kElevationHintShown = 'compat_elevation_hint_shown';

  /// 超分 / 转区引擎是否以管理员身份运行（默认 true）
  static const String _kElevateTools = 'launch_tools_run_as_admin';

  static CompatPreference? _instance;
  static CompatPreference get instance => _instance ??= CompatPreference._();
  CompatPreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _enabled = true;

  /// 是否自动配置启动程序的兼容性属性（默认开启）
  bool get enabled => _enabled;

  bool _elevationHintShown = false;

  /// 「建议以管理员重启管理器」提示是否已经展示过（只提示一次）
  bool get elevationHintShown => _elevationHintShown;

  bool _elevateTools = true;

  /// 超分（Magpie）/ 转区（LEProc）**引擎自身**是否以管理员身份运行。
  ///
  /// 默认 `true`（2026-10-24 用户明确要求：把超分/转区升级为管理员运行），
  /// 用来覆盖"引擎本身需要更高权限才能正常工作"的游戏。
  ///
  /// 🔴 注意区分两件事：
  ///   · 本开关管的是**工具进程**的权限；
  ///   · `game.json.run_as_admin` 管的是**游戏进程**的权限。
  ///   两者独立，但有一条单向联动：游戏提权 ⇒ 超分引擎**必须**一起提权
  ///   （普通权限的 Magpie 捕获不到提权窗口），由
  ///   `LaunchProcessLauncher.shouldElevateTool` 强制保证。
  ///
  /// ⚠️ 管理器自身未提权时，开启本项会让每次超分/转区启动都弹一次 UAC
  ///   —— Windows 的安全边界，无法绕过。想彻底不弹只有一个办法：
  ///   以管理员身份运行管理器（此时子进程继承提权令牌，零弹窗）。
  bool get elevateTools => _elevateTools;

  /// 同步读取（启动流程用）。未加载时返回默认 `true`。
  bool get elevateToolsSync {
    if (!_loaded) ensureLoaded();
    return _elevateTools;
  }

  /// 从 `SharedPreferences` 读取。幂等。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
      _elevationHintShown = prefs.getBool(_kElevationHintShown) ?? false;
      _elevateTools = prefs.getBool(_kElevateTools) ?? true;
    } catch (e) {
      debugPrint('[COMPAT-PREF] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// 同步读取（供启动流程等不方便 await 的场景使用）
  ///
  /// 未加载时返回默认值 `true`，并在后台触发一次加载。
  bool get enabledSync {
    if (!_loaded) {
      // 后台补加载，避免启动流程等待磁盘
      ensureLoaded();
    }
    return _enabled;
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    // 先通知再落盘：开关要立刻生效
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, value);
    } catch (e) {
      debugPrint('[COMPAT-PREF] 写入设置失败: $e');
    }
    // 关闭总开关 → 撤销本应用写入过的兼容性标志（用户手设的保留）
    if (!value) {
      try {
        await GameCompatibilityService.instance.rollbackAllManaged();
      } catch (e) {
        debugPrint('[COMPAT-PREF] 撤销已写入的兼容性设置失败（不影响开关状态）: $e');
      }
    }
  }

  /// 设置超分 / 转区引擎是否以管理员身份运行
  Future<void> setElevateTools(bool value) async {
    if (_elevateTools == value) return;
    _elevateTools = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kElevateTools, value);
    } catch (e) {
      debugPrint('[COMPAT-PREF] 写入引擎提权设置失败: $e');
    }
  }

  /// 标记「已提示过以管理员重启」
  Future<void> markElevationHintShown() async {
    if (_elevationHintShown) return;
    _elevationHintShown = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kElevationHintShown, true);
    } catch (e) {
      debugPrint('[COMPAT-PREF] 写入提示标记失败: $e');
    }
  }

  /// 仅供单测重置单例
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`
  @visibleForTesting
  void seedForTest({
    bool? enabled,
    bool? elevationHintShown,
    bool? elevateTools,
  }) {
    _loaded = true;
    if (enabled != null) _enabled = enabled;
    if (elevationHintShown != null) _elevationHintShown = elevationHintShown;
    if (elevateTools != null) _elevateTools = elevateTools;
    notifyListeners();
  }
}
