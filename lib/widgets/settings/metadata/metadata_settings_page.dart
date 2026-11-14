import 'package:flutter/material.dart';

import '../../../theme/app_spacing.dart';
import '../settings_section.dart';
import '../title_logo_settings_card.dart';
import 'metadata_accounts_card.dart';
import 'metadata_priority_card.dart';
import 'metadata_refresh_card.dart';
import 'metadata_sources_card.dart';

/// 设置 → 「元数据」整页。
///
/// 四块（需求里的两个板块 + 两个扩展）：
///   1. 平台账号与凭证 —— 抓取时的身份（限额 / 登录态内容）
///   2. 元数据拉取来源 —— 用哪些平台，以及 MIX 整合范围
///   3. 字段优先级 —— 封面/截图/评分/简介/标签/会社/标题 先看哪家
///   4. 全量更新 —— 改完设置后把新口径应用到整个库
///
/// 🔴 刻意不做「收藏/游玩状态同步」：本项目没有云端状态模型，
/// 做了也只有永远灰着的开关。
class MetadataSettingsPage extends StatelessWidget {
  const MetadataSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SettingsSection(
            title: '平台账号与凭证',
            description: '填写各平台的凭据（个人令牌 / Cookie）来提额与读取登录态内容。'
                '凭据只存在本机，从浏览器复制后粘贴即可，不会上传到任何地方。',
            isFirst: true,
            children: <Widget>[const MetadataAccountsCard()],
          ),
          SettingsSection(
            title: '元数据拉取来源',
            description: '关闭的平台不会参与抓取，也不会被 MIX 整合源合并。',
            children: <Widget>[const MetadataSourcesCard()],
          ),
          SettingsSection(
            title: '字段优先级',
            description: '每项数据先看哪个平台；取不到时按内置顺序继续向后找。',
            children: <Widget>[const MetadataPriorityCard()],
          ),
          // 2026-11-13 IA 微调：原挂在「网络与存储」，但它本质是**元数据来源**
          // （SteamGridDB 的 Key 决定标题图覆盖率），跟网络代理/存储位置无关，
          // 放在这里才找得到。
          SettingsSection(
            title: '大标题素材',
            description: '主页 / BPM 主页的艺术字标题图来源。抓取全自动，'
                '此处的 Key 仅用于扩大覆盖范围。',
            children: const <Widget>[TitleLogoSettingsCard()],
          ),
          SettingsSection(
            title: '全量更新元数据',
            description: '把上面三块的设置应用到库里已有的游戏。'
                '默认只补空字段，不覆盖你手改过的内容。',
            children: <Widget>[const MetadataRefreshCard()],
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}
