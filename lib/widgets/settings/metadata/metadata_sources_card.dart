import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../services/metadata_fetcher.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import 'metadata_site_catalog.dart';

/// 「元数据拉取来源」卡片组：2 列平台卡片 + 一个 MIX 整合卡。
///
/// 视觉对标 LunaBox 的来源网格（站点图标 + 名称 + 一句简介 + 右侧开关），
/// 但沿用本项目既有卡片语言（1.4px 描边、直角、`AppColors.border`）。
///
/// 🔴 一张卡＝一个「平台」而不是一个 [SourceType]：鲲GAL/NextMoe 是同生态的
/// 两个接口，用户视角上是一个站，所以开关一次改两个源，不留半开半关的
/// 中间态（那会让「关掉鲲但 NextMoe 还在偷偷用」的老问题以另一种形式回来）。
///
/// 🔴 开关直接落到 [MetadataFetcher.setEnabledSources]，而 MIX 的整合范围
/// 在 `fetchGameMixed()` 里与启用列表取交集 —— 关掉即不参与，不留暗门。
class MetadataSourcesCard extends StatefulWidget {
  const MetadataSourcesCard({super.key});

  @override
  State<MetadataSourcesCard> createState() => _MetadataSourcesCardState();
}

class _MetadataSourcesCardState extends State<MetadataSourcesCard> {
  late Set<SourceType> _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _enabled = MetadataFetcher.getEnabledSources().toSet();
  }

  /// 某张平台卡对应的开关状态：整组都启用才算开（历史偏好可能只存了半个组）。
  bool _isOn(MetadataSiteInfo site) =>
      site.sources.every((SourceType s) => _enabled.contains(s));

  /// 已启用的平台卡数量（用于「至少保留一个」判据）。
  int get _onGroupCount =>
      kMetadataSites.where((MetadataSiteInfo s) => _isOn(s)).length;

  /// 平台开关切换。
  Future<void> _toggleSite(MetadataSiteInfo site, bool on) async {
    if (_saving) return;
    final next = Set<SourceType>.of(_enabled);
    if (on) {
      next.addAll(site.sources);
    } else {
      next.removeAll(site.sources);
      final bool anyGroupLeft = kMetadataSites
          .any((MetadataSiteInfo s) => s.sources.any(next.contains));
      if (!anyGroupLeft) {
        _toast('至少保留一个元数据来源');
        return;
      }
    }
    await _commit(next);
  }

  /// MIX 开关：它不是一个平台，单独处理。
  Future<void> _toggleMix(bool on) async {
    if (_saving) return;
    final next = Set<SourceType>.of(_enabled);
    if (on) {
      next.add(SourceType.mix);
    } else {
      next.remove(SourceType.mix);
    }
    await _commit(next);
  }

  Future<void> _commit(Set<SourceType> next) async {
    setState(() {
      _enabled = next;
      _saving = true;
    });
    try {
      // 按 catalog 顺序落盘，避免 UI 顺序与抓取顺序漂移
      final ordered = <SourceType>[
        SourceType.mix,
        for (final MetadataSiteInfo s in kMetadataSites) ...s.sources,
      ].where(next.contains).toList(growable: false);
      await MetadataFetcher.setEnabledSources(ordered);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int activeMixCount = MetadataFetcher.getEffectiveMixSources().length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildMixCard(activeMixCount),
        const SizedBox(height: AppSpacing.sm),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 2 列等宽：恒等式 cols×宽 + (cols−1)×gap == 可用宽
            const double gap = AppSpacing.sm;
            final double cardWidth =
                ((constraints.maxWidth - gap) / 2).clamp(220.0, 640.0);
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final MetadataSiteInfo site in kMetadataSites)
                  SizedBox(
                    width: cardWidth,
                    child: _buildSiteCard(site),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// MIX 卡片：说明它是「整合结果」而不是独立平台，并显示当前实际整合了几个源。
  Widget _buildMixCard(int activeCount) {
    final bool on = _enabled.contains(SourceType.mix);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        border: Border.all(color: AppColors.border, width: 1.4),
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF8E6CD9), width: 1),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text(
              'MIX',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF8E6CD9),
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '整合源（MIX）',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.primaryText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '按字段优先级合并下方各平台的结果，批量导入默认使用它。'
                  '当前整合 $activeCount 个已启用平台；关掉某个平台后它不会再参与合并。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 17 / 12,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: on,
            activeColor: AppColors.successGreen,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: _toggleMix,
          ),
        ],
      ),
    );
  }

  Widget _buildSiteCard(MetadataSiteInfo site) {
    final bool on = _isOn(site);
    // 最后一个启用项不可关（关掉会让整条抓取链空转）
    final bool isLastOne = on && _onGroupCount <= 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: on ? AppColors.buttonBackground : AppColors.background,
        border: Border.all(
          color: on ? site.accent.withOpacity(0.75) : AppColors.border,
          width: on ? 1.6 : 1.4,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    MetadataSiteLogo(site: site, height: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        site.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: on
                              ? AppColors.primaryText
                              : AppColors.secondaryText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  site.hint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 16 / 11,
                    color: AppColors.placeholderText,
                  ),
                ),
                if (isLastOne)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '至少保留一个来源',
                      style: TextStyle(
                        fontSize: 10,
                        fontStyle: FontStyle.italic,
                        color: AppColors.placeholderText,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // 只留 Switch 自己响应点击：外面再套 InteractiveWrapper 会和
          // Switch 的 onChanged 双重触发（点一下切两次 = 看起来没反应）
          Opacity(
            opacity: isLastOne ? 0.55 : 1,
            child: Switch.adaptive(
              value: on,
              activeColor: site.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: isLastOne ? null : (bool v) => _toggleSite(site, v),
            ),
          ),
        ],
      ),
    );
  }
}
