/// 设置页「自动抓取背景视频」卡片。
///
/// ## 为什么默认关（用户 2026-10-17 拍板）
/// 从 Steam 商店抓游戏的官方视频存到本地，覆盖率约四成、单条 30–45MB。
/// 「替用户下载完整 OP/PV 动画」是需要用户知情的行为，不能默认替他决定 ——
/// 详见 ADR-018 与 `docs/DEV/features/bpm_op_video_autofetch.md`。
///
/// ## 素材范围（用户 2026-10-17 补充）
/// 不局限于 OP：ED / PV / 其它能介绍游戏内容的官方视频都能当背景，
/// 没有 OP 就用 ED，再没有就用 PV（优先级在引擎 `classify` 里）。
///
/// ## 三个部件
/// 1. 开关（关着时零网络、零磁盘）；
/// 2. 实时状态行（只在抓取进行时有文字，平时不占位）；
/// 3. 已抓取统计 + 清理（只删 `op_video_*` 前缀，用户手放的视频一律不碰）。
///
/// 不持有任何抓取逻辑：全部委派给 `GameOpVideoService`。
library;

import 'package:flutter/material.dart';

import '../../services/bpm_op_video_preference.dart';
import '../../services/game_op_video_service.dart';
import '../../theme/app_colors.dart';
import 'settings_switch_tile.dart';
import 'settings_tile.dart';

class OpVideoAutofetchCard extends StatefulWidget {
  const OpVideoAutofetchCard({super.key});

  @override
  State<OpVideoAutofetchCard> createState() => _OpVideoAutofetchCardState();
}

class _OpVideoAutofetchCardState extends State<OpVideoAutofetchCard> {
  OpVideoCacheStats? _stats;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final OpVideoCacheStats s = await GameOpVideoService.instance.stats();
      if (!mounted) return;
      setState(() => _stats = s);
    } catch (_) {
      if (!mounted) return;
      setState(() => _stats = OpVideoCacheStats.empty);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final int n = await GameOpVideoService.instance.clearAllAutoFetched();
      if (!mounted) return;
      setState(() {
        _message = n == 0 ? '没有可清理的自动抓取视频' : '已清理 $n 条';
      });
      await _loadStats();
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = '清理失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        AnimatedBuilder(
          animation: BpmOpVideoPreference.instance,
          builder: (BuildContext context, Widget? _) {
            final bool on = BpmOpVideoPreference.instance.autoFetchEnabled;
            return SettingsSwitchTile(
              title: '自动抓取背景视频（OP / ED / PV）',
              icon: Icons.download_for_offline_rounded,
              value: on,
              statusText: on
                  ? '已开启 · 大屏模式选中没有视频的游戏时，会先探测 Steam 素材，'
                      '探到就弹窗问你拉不拉（探不到不打扰）'
                  : '已关闭 · 不联网、不占磁盘（默认）',
              onChanged: (bool value) async {
                await BpmOpVideoPreference.instance.setAutoFetchEnabled(value);
                if (value) _loadStats();
              },
            );
          },
        ),

        // 实时状态行：只有抓取进行中才有内容，空闲时整行不出现
        ValueListenableBuilder<String>(
          valueListenable: GameOpVideoService.instance.activity,
          builder: (BuildContext context, String activity, Widget? _) {
            if (activity.isEmpty) return const SizedBox.shrink();
            return SettingsTile(
              title: '抓取中',
              icon: Icons.sync_rounded,
              iconColor: AppColors.secondaryText,
              subtitle: activity,
            );
          },
        ),

        SettingsTile(
          title: '已抓取的视频',
          icon: Icons.video_library_rounded,
          subtitle: _stats == null
              ? '统计中…'
              : (_message ??
                  (_stats!.files == 0
                      ? '还没有自动抓取的视频'
                      : '${_stats!.files} 条 · '
                          '${_stats!.megabytes.toStringAsFixed(1)} MB')),
          trailing: _stats == null || _stats!.files == 0
              ? null
              : GestureDetector(
                  onTap: _busy ? null : _clear,
                  child: Opacity(
                    opacity: _busy ? 0.5 : 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        border: Border.all(color: AppColors.border, width: 1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _busy ? '清理中…' : '清理',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primaryText,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
