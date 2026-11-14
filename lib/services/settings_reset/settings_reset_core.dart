/// 「恢复默认设置」的纯 Dart 核心：**域定义 + 键清单 + 编排**。
///
/// ## 为什么单独成文件、且不 import Flutter
///
/// ① 探针要能用 `dart.exe` 直跑（`dev_probe/settings_reset_probe.dart` A 段），
///    做「键清单体检」：每个键必须**真的**出现在 lib 源码里（防手打错一个字母
///    ⇒ 静默不生效）、四个域两两不重叠、不碰任何凭据/用户数据键；
/// ② 编排（逐个 `remove` + 统计）与持久化、UI 解耦，可注入假实现。
///
/// ## 恢复语义（关键设计口径）
///
/// **恢复 = 把这些键从 `SharedPreferences` 里删掉，而不是写入一堆"默认值"。**
/// 全项目所有偏好服务都是「键缺失 ⇒ 用字段初始值」的读法，所以「键不存在」
/// 就是全新安装的状态 —— 这是唯一不会随版本漂移的定义（新增默认值时不需要
/// 回来改本文件）。写入显式默认值反而会在下一次改默认值后变成"假的默认"。
///
/// ## 硬边界：只删设置，不删用户资产
///
/// 下列内容**绝不**在清理范围内（[kSettingsResetNeverTouchKeys] /
/// [kSettingsResetNeverTouchPrefixes] 是给探针用的机器可读版本）：
/// - 游戏与游戏数据（`game.json`、`Games/`、时长统计、收藏、自定义标签…）
/// - 账号与所有平台凭证（PB token、Bangumi PAT、鲲/2DFan Cookie、OAuth 令牌）
/// - 用户作品（自定义主题 JSON、上传的背景图、Magpie 自定义模板、手柄档案）
/// - 一次性提示的记忆标记（否则恢复完又把弹窗全看一遍）
/// - 迁移闸（`*_migrated` / `storage_migration_v1_*`，删了会重跑数据迁移）
/// - 动态命名的按游戏键（`default_exe_<游戏名>` 等）
///
/// 详见 `docs/DEV/features/settings_restore_defaults.md`。
library;

import 'dart:async';

/// 恢复范围（4 类，与设置页 8 个 tab 的归属对齐）。
///
/// 为什么是 4 类而不是 8 个 tab 各一类：用户心智里「改坏的东西」只有四种来源
/// —— 看着不对（界面）、玩起来不对（游戏与启动）、抓不到资料（元数据）、
/// 连不上/存不下（网络与存储）。按 tab 拆会让勾选列表变长，反而不知道该选谁。
enum SettingsResetDomain {
  /// 界面：主题、动效、大屏模式、窗口与列表布局。
  appearance(
    id: 'appearance',
    label: '界面设置',
    summary: '主题与背景、减少动效、大屏模式、窗口位置与列表布局排序',
    note: '自定义主题与上传的背景图文件不会被删除，只是不再被选中。',
  ),

  /// 游戏与启动：自启、兼容性、窗口、超分、统计、内容保护、自动导入、字体默认值。
  gameLaunch(
    id: 'game_launch',
    label: '游戏与启动',
    summary: '开机自启、启动兼容性、快捷窗口、超分增强、游玩统计、'
        '内容保护、自动导入、字体默认值',
    note: '各游戏自己的启动路径 / 兼容性 / 时长记录不受影响。',
  ),

  /// 元数据：拉取来源开关 + 字段优先级。
  metadata(
    id: 'metadata',
    label: '元数据设置',
    summary: '抓取来源开关、字段优先级（哪些站优先提供简介 / 封面 / 标签）',
    note: '已填写的凭证不会清除：Bangumi Token、鲲 / 2DFan Cookie、'
        'SteamGridDB Key 都会保留。',
  ),

  /// 网络与存储：代理、下载、库目录、归档、云备份、补丁保存位置。
  networkStorage(
    id: 'network_storage',
    label: '网络与存储',
    summary: '网络代理、下载档位与限速、游戏库目录、归档库、'
        '云备份、补丁保存位置、下载缓存目录',
    note: '云备份的 WebDAV 账号与密码属于本类设置，会被一并清除（需重新填写）。',
  );

  const SettingsResetDomain({
    required this.id,
    required this.label,
    required this.summary,
    required this.note,
  });

  /// 稳定标识（⛔ 用于落盘/日志，不要用 [Enum.name]：裸 VM 与混淆环境下不可靠）。
  final String id;

  /// 面板上的标题。
  final String label;

  /// 一句话说明「这一类包含什么」。
  final String summary;

  /// 该类的额外提醒（会删除什么 / 不会删除什么）。
  final String note;

  /// 按 [id] 反查（日志/恢复默认值用）。
  static SettingsResetDomain? byId(String id) {
    for (final SettingsResetDomain d in SettingsResetDomain.values) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// 每个域要删除的 prefs 键。
///
/// ⚠️ 维护约定：**这里出现的键必须与源码里的字面量逐字符一致**（探针 A 段会
/// 逐个 grep 校验）。键名统一不加 `flutter.` 前缀 —— 前缀由
/// `PortableSharedPreferencesStore` 在存储层统一处理，`SharedPreferences` 的
/// 公开 API 收发的都是裸键名。
const Map<SettingsResetDomain, List<String>> kSettingsResetKeys =
    <SettingsResetDomain, List<String>>{
  // ───────────── 界面 ─────────────
  SettingsResetDomain.appearance: <String>[
    // 主题（lib/theme/theme_storage.dart）
    'app_theme',
    'theme_follow_system',
    // 动效（lib/services/motion_preference.dart）
    'reduce_motion_background',
    // 大屏模式（lib/big_picture/**、lib/services/bpm_*.dart）
    'bpm_mode_enabled',
    'bpm_theme_mode',
    'bpm_guide_enabled',
    'bpm_op_video_sound_enabled',
    'bpm_op_video_autoplay_always',
    'bpm_op_video_auto_fetch',
    // 外壳（lib/main.dart / main_container.dart / 本文件同目录的 settings_modal）
    'sidebar_collapsed',
    'settings_modal_size_w',
    'settings_modal_size_h',
    // 窗口几何（lib/services/window_geometry_service.dart）
    'win_geom_x',
    'win_geom_y',
    'win_geom_w',
    'win_geom_h',
    'win_geom_dpi',
    'win_geom_maximized',
    // 库页列表记忆（lib/pages/library_page.dart）
    'library_game_order',
    'library_panel_sort',
    'library_panel_dev_filter',
    'library_panel_search',
    'library_panel_layout',
    // 关闭按钮行为记忆（lib/widgets/custom_title_bar.dart）
    'close_remember_choice',
    'close_remembered_action',
  ],

  // ───────────── 游戏与启动 ─────────────
  SettingsResetDomain.gameLaunch: <String>[
    // 开机自启（lib/services/autostart_service.dart）
    // ⚠️ 光删键不够：注册表 Run 项由服务层负责删除（见 settings_reset_service）
    'autostart_enabled',
    // 首次启动自动建快捷方式（lib/services/auto_shortcut_preference.dart）
    'auto_create_shortcut_first_launch',
    // 启动兼容性（lib/services/compat_preference.dart）
    'compat_auto_config_enabled',
    'launch_tools_run_as_admin',
    // 快捷窗口（lib/services/quick_window_service.dart）
    'quick_window_auto_enable',
    // 超分增强 Magpie（lib/services/magpie_service.dart）
    // ⛔ 不含 magpie_custom_templates：那是用户自建的配置模板
    'magpie_mode',
    'magpie_external_path',
    'magpie_default_preset',
    'magpie_auto_close',
    'magpie_fallback_on_fail',
    'magpie_classname_cache',
    // 游玩统计（lib/services/local_game_registry.dart）
    'time_tracking_mode',
    // 内容保护 NSFW（lib/services/nsfw/nsfw_settings.dart）
    'nsfw_filter_enabled',
    'nsfw_display_mode',
    'nsfw_conf_threshold',
    'nsfw_allow_reveal',
    'nsfw_box_expand_ratio',
    'nsfw_full_scan_done_at',
    // 自动导入 / 监控目录（lib/services/watch_folder_service.dart）
    'watch_folders',
    'auto_import_mode',
    'auto_import_interval',
    'auto_import_lock_title',
    'auto_import_threshold',
    'watch_folder_ignored',
    'watch_folder_is_importing',
    // 字体注入默认值（lib/services/font_override_prefs.dart）
    'font_override_default_font_name',
    'font_override_default_charset',
    'font_override_default_charset_replace',
    'font_override_default_metrics',
    'font_override_gate_prompt_enabled',
    'font_override_gate_answered_ids',
  ],

  // ───────────── 元数据 ─────────────
  SettingsResetDomain.metadata: <String>[
    // 拉取来源开关（lib/services/metadata_fetcher.dart）
    // ⛔ 不含 *_source_migrated：迁移闸删掉会重跑默认源迁移
    'enabled_metadata_sources',
    // 字段优先级（lib/services/metadata_field_priority.dart）
    'metadata_field_priority',
  ],

  // ───────────── 网络与存储 ─────────────
  SettingsResetDomain.networkStorage: <String>[
    // 网络代理（lib/services/network_proxy_policy.dart）
    'network_proxy_mode',
    'proxy_url',
    // 下载档位与限速（lib/services/download_intensity.dart）
    'download_intensity',
    'download_speed_limit_mbps',
    // 探测档位缓存（lib/services/download_core.dart）
    'download_tier_cache',
    'download_tier_cache_at',
    // 下载缓存目录（lib/services/download_cache_dir.dart）
    'download_cache_dir',
    'download_cache_dir_history',
    // 游戏库目录（lib/services/install_path_preference.dart）
    'default_game_location',
    'last_used_location',
    // 归档库（lib/services/archive_library_preference.dart）
    'archive_library_path',
    'archive_retention',
    'archive_compression_level',
    // 云备份（lib/services/cloud_backup/cloud_backup_service.dart）
    'cloud_backup_config_v1',
    // 补丁保存位置（lib/services/patch/patch_save_location.dart）
    'patch_save_location',
  ],
};

/// **绝不清理**的具体键（凭据、用户数据、统计明细、一次性提示标记、迁移闸）。
///
/// 生产代码不读这个常量 —— 它是**机器可读的边界声明**，用途有两个：
/// ① `settings_reset_probe` 断言它和 [kSettingsResetKeys] 无交集（防手滑把
///    凭据键加进某域的清理清单里）；
/// ② 后来者加新设置时能一眼看到「哪些键属于禁区」。
const List<String> kSettingsResetNeverTouchKeys = <String>[
  // —— 账号 / 平台凭证 ——
  'pb_auth_token',
  'pb_user_id',
  'pb_user_name',
  'pb_user_email',
  'local_account_id',
  'local_account_name',
  'local_account_bio',
  'local_account_avatar_b64',
  'local_account_created_at',
  'local_account_avatar_preset',
  'user_id',
  'user_name',
  'user_bio',
  'user_avatar_base64',
  'bangumi_personal_access_token',
  'kun_galgame_cookie',
  'two_dfan_cookie',
  'sgdb_api_key',
  // —— 用户作品 ——
  'magpie_custom_templates',
  // —— 统计 / 上报明细 ——
  'reported_install_game_ids',
  // —— 迁移闸与主题 schema ——
  'ct_source_migrated',
  'mix_source_migrated',
  'nextmoe_source_migrated',
  'two_dfan_source_migrated',
  'theme_schema_version',
  // —— 一次性提示的记忆标记（恢复完不该又被弹一遍）——
  'theme_default_user_created',
  'compat_elevation_hint_shown',
  'floating_button_hint_shown',
  'discover_disclaimer_agreed_version',
];

/// **绝不清理**的键前缀（动态命名、每个游戏一份、或框架内部状态）。
const List<String> kSettingsResetNeverTouchPrefixes = <String>[
  // OAuth 令牌（lib/services/oauth/oauth_token_store.dart）
  'oauth_token_v1_',
  // 存储迁移标记（lib/services/storage/migration_markers.dart）
  'storage_migration_v1_',
  // 按游戏名命名（lib/services/game_launch_service.dart 等）
  'default_exe_',
  'save_custom_paths_',
  // 每个游戏一份的文件体积缓存（lib/services/file_size_service.dart）
  'file_size_',
];

/// 合并多个域的键清单（保持域声明顺序 + 域内声明顺序，自动去重）。
List<String> settingsResetKeysFor(Iterable<SettingsResetDomain> domains) {
  final Set<SettingsResetDomain> wanted = domains.toSet();
  final List<String> out = <String>[];
  final Set<String> seen = <String>{};
  for (final SettingsResetDomain domain in SettingsResetDomain.values) {
    if (!wanted.contains(domain)) continue;
    for (final String key in kSettingsResetKeys[domain] ?? const <String>[]) {
      if (seen.add(key)) out.add(key);
    }
  }
  return out;
}

/// 某一类「包含多少项设置」—— 面板上显示 `24 项` 用。
int settingsResetItemCount(SettingsResetDomain domain) =>
    (kSettingsResetKeys[domain] ?? const <String>[]).length;

/// 恢复结果报告。
class SettingsResetReport {
  SettingsResetReport({required this.domains});

  /// 本次选中的域（快照，避免 UI 侧后续改动影响展示）。
  final Set<SettingsResetDomain> domains;

  /// 真的被删掉的键。
  final List<String> removedKeys = <String>[];

  /// 本来就不存在（早已是默认值）的键。
  final List<String> absentKeys = <String>[];

  /// 删除失败（读/写异常）的键。
  final List<String> failedKeys = <String>[];

  /// 服务层追加的副作用说明（如「已关闭开机自启（含注册表项）」）。
  final List<String> sideEffects = <String>[];

  /// 致命错误（拿不到 prefs 等），非 null 时 [removedKeys] 一定为空。
  String? fatalError;

  bool get hasFailure => fatalError != null || failedKeys.isNotEmpty;

  int get removedCount => removedKeys.length;

  int get absentCount => absentKeys.length;

  /// 面板结果页的「已恢复 N 项（另有 M 项本来即是默认）」。
  String get summaryLine {
    if (removedCount == 0 && absentCount > 0) {
      return '这 $absentCount 项本来就已经是默认状态，没有需要改动的内容。';
    }
    final String base = '已恢复 $removedCount 项设置';
    return absentCount > 0 ? '$base（另有 $absentCount 项本来即是默认）' : base;
  }

  @override
  String toString() => 'SettingsResetReport(domains=${domains.map((d) => d.id).toList()}, '
      'removed=$removedCount, absent=$absentCount, failed=${failedKeys.length}, '
      'side=${sideEffects.length}, fatal=$fatalError)';
}

/// 编排：按域顺序逐个 key 判断存在性并删除，全程**不抛出**（异常计入报告）。
///
/// [contains] / [remove] 由调用方注入（生产注入 `SharedPreferences`，
/// 探针注入内存假实现），因此本文件保持零依赖、可裸 VM 直跑。
Future<SettingsResetReport> runSettingsReset({
  required Set<SettingsResetDomain> domains,
  required Future<bool> Function(String key) contains,
  required Future<bool> Function(String key) remove,
}) async {
  final SettingsResetReport report = SettingsResetReport(domains: domains.toSet());
  for (final String key in settingsResetKeysFor(domains)) {
    try {
      if (!await contains(key)) {
        report.absentKeys.add(key);
        continue;
      }
      if (await remove(key)) {
        report.removedKeys.add(key);
      } else {
        report.failedKeys.add(key);
      }
    } catch (_) {
      report.failedKeys.add(key);
    }
  }
  return report;
}
