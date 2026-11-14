/// BPM「发现可拉取的背景视频」确认弹窗（v3.22，用户拍板加的确认步骤）。
///
/// ## 为什么要有这一步（用户原话，2026-10-17）
/// *"我明明开了自动抓取，但是没有任何的反应"* —— 首轮的静默后台抓取让用户
/// 完全无法感知功能是否生效。现在的流程是：服务层后台**探测**（只查列表，
/// 不下载）→ 探到素材就弹这个窗，告诉用户《游戏》有几条可拉取的视频、
/// 将拉取哪条 → 用户确认才真正下载。
///
/// 🔴 探不到素材 / 网络失败时**不弹任何窗**（用户明确：没有素材不用提示），
/// 所以这个弹窗一旦出现，功能一定在工作。
///
/// 手柄 / 键盘：`autofocus` 落在「拉取」上，方向键切换、A/Enter 确认、
/// B/Esc 取消（与 BPM 其它 AlertDialog 一致，无需额外接线）。
library;

import 'package:flutter/material.dart';

import '../../services/game_op_video_core.dart';
import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';

class BpmOpVideoAskDialog extends StatelessWidget {
  const BpmOpVideoAskDialog({
    super.key,
    required this.gameTitle,
    required this.candidates,
  });

  final String gameTitle;
  final List<OpCandidate> candidates;

  /// 返回 `true` = 用户点了「拉取」；`false` / `null`（点外部 / Esc）= 不拉取。
  static Future<bool?> show(
    BuildContext context, {
    required String gameTitle,
    required List<OpCandidate> candidates,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => BpmOpVideoAskDialog(
        gameTitle: gameTitle,
        candidates: candidates,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool tooMany = candidates.length > 5;
    final List<OpCandidate> shown =
        tooMany ? candidates.sublist(0, 5) : candidates;
    final OpCandidate first = candidates.first;

    return AlertDialog(
      backgroundColor: BpmColors.deepPanel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
      ),
      title: Text(
        '发现可拉取的背景视频',
        style: TextStyle(
          fontFamily: AppStyles.zhDecorativeFont,
          fontSize: 16,
          color: BpmColors.textPrimary,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '《$gameTitle》在 Steam 商店页有 ${candidates.length} 条视频素材：',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 13,
              color: BpmColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          for (final OpCandidate c in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '· ${c.movie.name}（${c.kind.label}）',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 12.5,
                  color: BpmColors.textPrimary,
                ),
              ),
            ),
          if (tooMany)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '…等 ${candidates.length} 条',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 12.5,
                  color: BpmColors.textMuted,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            '将拉取最优先的一条「${first.movie.name}」（约 30–45MB，720p，'
            '仅存本机，不上传）',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 12,
              color: BpmColors.textMuted,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            '不拉取',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              color: BpmColors.textMuted,
            ),
          ),
        ),
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            '拉取',
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontWeight: FontWeight.w600,
              color: BpmColors.mistBlue,
            ),
          ),
        ),
      ],
    );
  }
}
