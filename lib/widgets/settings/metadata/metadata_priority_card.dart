import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../services/metadata_fetcher.dart';
import '../../../services/metadata_field_priority.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import 'metadata_site_catalog.dart';

/// 「字段优先级」卡片组：每个可抓字段选一个「首选平台」。
///
/// 语义（用户拍板）：**只决定先看哪家**，其余平台继续按内置链后备。
/// 所以下拉里没有「只从这个平台取」这种破坏性选项 —— 选完仍然是
/// 「首选 → 内置顺序」的完整降级链，只是把选中的源提到最前。
///
/// 下拉项按**平台**而不是按 [SourceType] 列：鲲GAL/NextMoe 是一张卡，
/// 选中它等于把 nextmoe + kun 一起提前（组内顺序不变）。
class MetadataPriorityCard extends StatefulWidget {
  const MetadataPriorityCard({super.key});

  @override
  State<MetadataPriorityCard> createState() => _MetadataPriorityCardState();
}

class _MetadataPriorityCardState extends State<MetadataPriorityCard> {
  /// DropdownButton 不允许 null 作为可选中值（会被当成「未选中」），
  /// 用哨兵字符串代表「内置默认」。
  static const String _kBuiltin = '__builtin__';

  late Map<String, List<SourceType>> _overrides;

  @override
  void initState() {
    super.initState();
    _overrides = Map<String, List<SourceType>>.of(
        MetadataFetcher.getFieldPriorityOverrides());
  }

  /// 平台卡 → 下拉值（组内多个源用 `+` 连接，稳定且可逆）。
  static String _keyOfSite(MetadataSiteInfo site) =>
      site.sources.map((SourceType s) => s.name).join('+');

  static MetadataSiteInfo? _siteByKey(String key) {
    for (final MetadataSiteInfo site in kMetadataSites) {
      if (_keyOfSite(site) == key) return site;
    }
    // 兼容历史/脏数据：值里只有一个源时按单源平台命中
    for (final MetadataSiteInfo site in kMetadataSites) {
      if (site.source.name == key) return site;
    }
    return null;
  }

  /// 当前值对应的下拉 key；未配置或找不到平台时回落到「内置默认」。
  String _dropdownValue(String field) {
    final List<SourceType>? sel = _overrides[field];
    if (sel == null || sel.isEmpty) return _kBuiltin;
    final MetadataSiteInfo? site = metadataSiteOf(sel.first);
    if (site == null) return _kBuiltin;
    // 只认「整组」或「组内首源」两种合法状态，避免脏数据让下拉显示空
    return _keyOfSite(site);
  }

  Future<void> _onChanged(String field, String value) async {
    final MetadataSiteInfo? site = value == _kBuiltin ? null : _siteByKey(value);
    final List<SourceType>? sources = site?.sources;
    setState(() {
      if (sources == null) {
        _overrides.remove(field);
      } else {
        _overrides[field] = sources;
      }
    });
    await MetadataFetcher.setFieldPriority(field, sources);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.buttonBackground,
            border: Border.all(color: AppColors.border, width: 1.4),
          ),
          child: Text(
            '这里只决定「先看哪家」：选中的平台排到最前，取不到数据时仍按内置顺序'
            '（NextMoe → CT → 2Dfan → VNDB → …）继续向后找。改完立即生效，'
            '下一次抓取就用新顺序。',
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final String field in MetadataFieldPriority.fields)
          Padding(
            padding: EdgeInsets.only(
              bottom: field == MetadataFieldPriority.fields.last
                  ? 0
                  : AppSpacing.xs,
            ),
            child: _buildFieldRow(field),
          ),
      ],
    );
  }

  Widget _buildFieldRow(String field) {
    final String value = _dropdownValue(field);
    final bool custom = value != _kBuiltin;
    final List<SourceType> chain = MetadataFetcher.getEffectiveFieldChain(field);
    final String chainText = chain.isEmpty
        ? '（无可用平台）'
        : '${metadataChainTitleText(chain.take(6).toList(growable: false))}'
            '${chain.length > 6 ? " → …" : ""}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(
          color: custom ? AppColors.borderLight : AppColors.border,
          width: custom ? 1.8 : 1.4,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      MetadataFieldPriority.labelOf(field),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.primaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (custom)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.successGreen.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '已自定义',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.successGreen,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  MetadataFieldPriority.hintOf(field),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.placeholderText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '当前顺序：$chainText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.secondaryText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 176,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1.2),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: value,
                  isExpanded: true,
                  isDense: true,
                  style: TextStyle(fontSize: 12, color: AppColors.primaryText),
                  icon: Icon(Icons.expand_more,
                      size: 16, color: AppColors.secondaryText),
                  items: <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: _kBuiltin,
                      child: Text(
                        '内置默认',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.secondaryText),
                      ),
                    ),
                    for (final MetadataSiteInfo site in kMetadataSites)
                      DropdownMenuItem<String>(
                        value: _keyOfSite(site),
                        child: Text(
                          site.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: AppColors.primaryText),
                        ),
                      ),
                  ],
                  onChanged: (String? v) {
                    if (v != null) _onChanged(field, v);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
