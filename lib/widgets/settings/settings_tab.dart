/// 设置窗口的顶层分类 + 侧栏分簇。
///
/// 历史：
/// - 2026-09-08 IA 重构：由 3 个（个人资料 / 偏好设置 / 关于应用）拆分为 6 个；
/// - 2026-11-13 新增「元数据」（第 8 个）；
/// - 2026-11-13 UI 统一：8 项平铺改为 **4 簇**，每簇带小标题（见 [SettingsCluster]）。
///
/// 详见 `docs/DEV/features/settings_preference_ia_redesign_plan.md`
/// 与 `docs/DEV/features/settings_ui_unification_plan.md`。
library;

enum SettingsTab {
  profile,
  appearance,
  gameLaunch,

  /// 元数据（2026-11-13 新增）：平台账号/凭证 + 拉取来源 + 字段优先级 +
  /// 大标题素材 + 全量更新。归属设置页而不是入库页，因为它是**全局**偏好，
  /// 原先只藏在入库页齿轮弹窗里，用户根本找不到。
  metadata,
  bigPicture,
  networkStorage,
  contentSafety,
  about,
}

/// 侧栏分簇（4 簇）。顺序即渲染顺序。
///
/// 分簇的原则是「用户会去哪儿找」，不是「代码在哪个模块」：
/// - 我的：只有账号资料，放最上面当身份锚点
/// - 界面：看得见的东西（主题、大屏）
/// - 游戏：玩的东西（启动、元数据、内容保护）
/// - 系统：跑起来的东西（网络、存储、关于）
enum SettingsCluster {
  mine('我的'),
  look('界面'),
  play('游戏'),
  system('系统');

  const SettingsCluster(this.label);

  /// 簇标题文案。
  final String label;
}

/// 侧边栏每一项所需的展示元数据。
class SettingsTabMeta {
  const SettingsTabMeta({
    required this.tab,
    required this.label,
    required this.iconPath,
    required this.cluster,
    required this.description,
  });

  final SettingsTab tab;

  /// 侧栏与页头标题。
  final String label;

  /// 图标复用 `assets/images/` 下既有资源；若后续补充专属图标只改本文件。
  final String iconPath;

  /// 归属簇（决定侧栏分组）。
  final SettingsCluster cluster;

  /// 页头下的一句话说明（「这页能干什么」，≤ 2 行 ≈ 40 字）。
  final String description;

  /// 侧边栏展示顺序（即 tab 顺序，按 [cluster] 成组）。
  static const List<SettingsTabMeta> items = <SettingsTabMeta>[
    SettingsTabMeta(
      tab: SettingsTab.profile,
      label: '个人资料',
      iconPath: 'assets/images/tab_profile_icon.svg',
      cluster: SettingsCluster.mine,
      description: '头像、昵称与个人简介。可以给自己换个顺眼的头像。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.appearance,
      label: '外观',
      iconPath: 'assets/images/tab_preference_icon.svg',
      cluster: SettingsCluster.look,
      description: '系统配色、特色主题、自定义背景图，以及减少动效。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.bigPicture,
      label: '大屏模式',
      iconPath: 'assets/images/library_icon_new.svg',
      cluster: SettingsCluster.look,
      description: '大屏主页的背景视频、操作引导，以及手柄按键映射。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.gameLaunch,
      label: '游戏与启动',
      iconPath: 'assets/images/lightning_icon.svg',
      cluster: SettingsCluster.play,
      description: '开机自启、启动兼容性、游戏窗口控制、超分增强与游玩统计。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.metadata,
      label: '元数据',
      iconPath: 'assets/images/discover_icon.svg',
      cluster: SettingsCluster.play,
      description: '各平台的账号凭证、抓取来源、字段优先级与全量更新。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.contentSafety,
      label: '内容保护',
      iconPath: 'assets/images/lock_icon.svg',
      cluster: SettingsCluster.play,
      description: '本地 AI 识别敏感内容后模糊或隐藏，原图字节不变、全程不联网。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.networkStorage,
      label: '网络与存储',
      iconPath: 'assets/images/download_icon.svg',
      cluster: SettingsCluster.system,
      description: '代理与下载、游戏库位置、归档与云备份、缓存清理。',
    ),
    SettingsTabMeta(
      tab: SettingsTab.about,
      label: '关于应用',
      iconPath: 'assets/images/tab_about_icon.svg',
      cluster: SettingsCluster.system,
      description: '版本与更新、项目链接、开源组件致谢。',
    ),
  ];

  /// 取某一 tab 的元数据。
  static SettingsTabMeta of(SettingsTab tab) =>
      items.firstWhere((SettingsTabMeta e) => e.tab == tab);

  /// 取某簇下的所有 tab（保持 [items] 内的相对顺序）。
  static List<SettingsTabMeta> ofCluster(SettingsCluster cluster) =>
      items.where((SettingsTabMeta e) => e.cluster == cluster).toList();
}
