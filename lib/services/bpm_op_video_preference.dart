/// BPM OP 视频（背景播放）的全局偏好。
///
/// 两个开关（用户 2026-09-26 拍板）：
/// - [soundEnabled]：播放 OP 时是否出声 —— **默认 `false`（静音）**；
/// - [autoplayAlways]：同一游戏反复被选中时是否**每次都自动播** —— **默认 `true`**。
///
/// 持久化走项目既有的 `shared_preferences`（已被
/// `PortableSharedPreferencesStore` 重定向到 `data/prefs/shared_preferences.json`），
/// 便携版拷走整个目录即可带走设置。
///
/// 与 `lib/services/motion_preference.dart` 同构：`ChangeNotifier` 单例 +
/// **首帧前 `load()`**（在 `main.dart` 与 `MotionPreference.load()` 同层调用），
/// 避免首屏先按默认值渲染再跳变。
///
/// 新增文件，不触碰任何既有代码；消费方是
/// `lib/big_picture/services/bpm_backdrop_media_controller.dart`
/// 与桌面设置页的「大屏模式」栏。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BpmOpVideoPreference extends ChangeNotifier {
  /// 出声开关（默认关）。
  static const String _kSoundEnabled = 'bpm_op_video_sound_enabled';

  /// 每次选中都自动播放（默认开）。
  static const String _kAutoplayAlways = 'bpm_op_video_autoplay_always';

  /// 自动抓取 OP 视频（默认关，用户 2026-10-17 拍板）。
  static const String _kAutoFetch = 'bpm_op_video_auto_fetch';

  static BpmOpVideoPreference? _instance;
  static BpmOpVideoPreference get instance =>
      _instance ??= BpmOpVideoPreference._();
  BpmOpVideoPreference._();

  bool _loaded = false;
  bool get loaded => _loaded;

  bool _soundEnabled = false;
  bool _autoplayAlways = true;

  /// 是否自动从 Steam 抓取 OP 视频。**默认 `false`（不抓）**。
  ///
  /// 关着的时候行为与「自动抓取」上线前完全一致：池里有什么就播什么。
  /// 打开后，大屏模式里选中过、且**一条视频都没有**的游戏会在后台抓一次
  /// 片头动画（720p，单个 30–45MB）。为什么默认关：
  /// 覆盖率只有约四成、每条约 40MB、且属于「替用户下载完整 OP 动画」这种
  /// 需要用户知情的行为 —— 不能默认替他决定（详见 ADR-018）。
  bool _autoFetchEnabled = false;

  /// 是否出声。默认 `false` = 静音。
  bool get soundEnabled => _soundEnabled;

  /// 是否每次选中都自动播放。默认 `true`。
  ///
  /// `false` 时语义为「本次进入大屏模式后，每个游戏最多自动播一次」；
  /// 播过的游戏在当前会话内只显示静态背景（详情面板的「重播 OP」仍可手动触发）。
  bool get autoplayAlways => _autoplayAlways;

  /// 是否自动抓取 OP 视频（默认 `false`）。
  ///
  /// 消费方是 `GameOpVideoService.requestAutoFetch` —— 关闭时它第一行就返回，
  /// 因此关闭状态零网络、零磁盘开销。
  bool get autoFetchEnabled => _autoFetchEnabled;

  /// 背景视频**出声时**的播放音量（0..1）。
  ///
  /// 🔴 v3.18：与 [soundEnabled] 解耦。设置页开关只负责「新游戏默认开/关声」，
  /// 一旦用户在二级详情把某游戏拨到「开声」，就必须按这个音量真的出声 ——
  /// 不能因为全局默认关而被压成 0。取偏低的 0.35，背景视频不该盖过环境音。
  static const double audibleVolume = 0.35;

  /// 兼容旧调用方（= [audibleVolume]，不再是「静音时 0」）。
  double get volume => audibleVolume;

  /// 从 `SharedPreferences` 读取。幂等：已加载过则直接返回。
  ///
  /// 必须在 `runApp` 之前调用（与 `MotionPreference.load()` 同层）。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _soundEnabled = prefs.getBool(_kSoundEnabled) ?? false;
      _autoplayAlways = prefs.getBool(_kAutoplayAlways) ?? true;
      _autoFetchEnabled = prefs.getBool(_kAutoFetch) ?? false;
    } catch (e) {
      debugPrint('[BPM-OP-VIDEO] 读取设置失败，使用默认值: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool value) async {
    if (_soundEnabled == value) return;
    _soundEnabled = value;
    // 先通知再落盘：开关要立刻生效（背景层重建不依赖写盘结果）
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSoundEnabled, value);
    } catch (e) {
      debugPrint('[BPM-OP-VIDEO] 写入设置失败: $e');
    }
  }

  Future<void> setAutoplayAlways(bool value) async {
    if (_autoplayAlways == value) return;
    _autoplayAlways = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoplayAlways, value);
    } catch (e) {
      debugPrint('[BPM-OP-VIDEO] 写入设置失败: $e');
    }
  }

  /// 开关「自动抓取 OP 视频」。
  ///
  /// 关闭时正在跑的抓取**不会**被强杀（它会自己跑完这一条，已下载的分片
  /// 白白浪费更糟）；但队列里后续的请求会在 [autoFetchEnabled] 检查处退出。
  Future<void> setAutoFetchEnabled(bool value) async {
    if (_autoFetchEnabled == value) return;
    _autoFetchEnabled = value;
    notifyListeners();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoFetch, value);
    } catch (e) {
      debugPrint('[BPM-OP-VIDEO] 写入设置失败: $e');
    }
  }

  /// 仅供单测重置单例。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// 仅供单测注入设置值，绕过 `SharedPreferences`。
  @visibleForTesting
  void seedForTest({
    bool? soundEnabled,
    bool? autoplayAlways,
    bool? autoFetchEnabled,
  }) {
    _loaded = true;
    if (soundEnabled != null) _soundEnabled = soundEnabled;
    if (autoplayAlways != null) _autoplayAlways = autoplayAlways;
    if (autoFetchEnabled != null) _autoFetchEnabled = autoFetchEnabled;
    notifyListeners();
  }
}
