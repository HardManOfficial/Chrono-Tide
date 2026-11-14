/// 官方/社群链接常量（单一事实源）
///
/// 背景（2026-10-23）：原先这些地址散落在各页面里（官网、更新日志、反馈按钮
/// 各写一份）。用户新增「社群入口 + 官方链接直达」后，需要出现在
/// ① 用户资料面板的 QQ 群弹窗  ② 设置→关于应用左下角  ③ 探索大厅·介绍 tab
/// 三处；集中到本文件，避免三份字面量漂移。
///
/// 打开方式统一走 `WebsiteBookmarkService.openExternal`（零依赖系统调用 +
/// http/https 白名单），不要各自 Process.start。
class AppLinks {
  AppLinks._();

  /// GitHub 仓库（反馈 / Issue 入口与官网社区区同源）
  static const String githubRepo = 'https://github.com/HardManOfficial/Chrono-Tide';

  /// 项目官网
  static const String officialWebsite = 'http://www.chronotide.site';

  /// QQ 交流群「时之汐社」邀请链接（官网社区区同源）
  static const String qqGroupInvite = 'https://qm.qq.com/q/bfBwMSBiJU';

  /// QQ 交流群群号（仅展示）
  static const String qqGroupNumber = '1091837834';

  /// QQ 交流群群名（仅展示）
  static const String qqGroupName = '时之汐社';

  /// 群二维码图片（官网同源素材，316×364）
  static const String qqGroupQrAsset = 'assets/images/qq_group_qr.png';
}
