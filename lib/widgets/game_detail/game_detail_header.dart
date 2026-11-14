import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import 'alias_pill.dart';

/// 探索详情页顶部「游戏数据区」。
///
/// 设计（`素材/新建文件夹 (2)/Shell.png`，1281×721 = 窗口 1:1，可直接当 dp 读）：
/// ```
/// [←] [面包屑]
/// ┌────────┐  大标题（35dp，F1 得意黑，字距 2.0）
/// │        │  [别名胶囊]
/// │ 封面   │  ⌂会社  📅发售日  ★评分(人数)  ⛁来源
/// │135×205 │  #标签 #标签 #标签
/// │        │  ─────────────────────────────
/// │        │  [⬇获取][分享][⬆上传]  ▏ ♡ 💬
/// └────────┘
/// ```
///
/// ⚠️ 与旧版差异（本轮重构的**核心视觉变化**）：
/// - 封面 216×323 → **135×205**（设计实测：边框 x 240→378、y 81→283，
///   含约 2.4° 旋转，正交化后 ≈ 138×202）
/// - 大标题 32 → **35**，仍用 F1 得意黑、字距 2.0（AGENTS 禁止 w700）
/// - 右列大「获取作品」安装按钮**移除**，改为本区下方的一行操作按钮
///   （安装状态与进度改由「Chrono Tide 下载」浮层承载）
/// - 右列内容底部的强调分割线（设计 #2B2B2B → `AppColors.dividerStrong`）
class GameDetailHeader extends StatelessWidget {
  const GameDetailHeader({
    super.key,
    required this.cover,
    required this.title,
    required this.aliases,
    required this.metaItems,
    required this.tags,
    required this.leading,
    required this.onGet,
    required this.onShare,
    required this.onUpload,
    required this.onLike,
    required this.onFeedback,
    this.onPatch,
    this.patchEnabled = true,
    this.patchButtonKey,
    this.onOpenKungal,
    this.actionRowKey,
    this.getLabel = '获取',
    this.getEnabled = true,
    this.getBusy = false,
    this.shareEnabled = true,
    this.uploadEnabled = true,
    this.liked = false,
    this.likeCount = 0,
    this.likeEnabled = true,
    this.feedbackEnabled = true,
  });

  /// 封面（由页面传入，保持既有旋转/阴影/NSFW 处理逻辑不变）
  final Widget cover;

  final String title;

  /// 别名列表（除主标题外的全部名称：日文原名 / 英文名 / 繁中名）。
  ///
  /// ★ 2026-10-10 需求 3：由单个拼接串改为**列表**，展示时一个名字一个框。
  /// 为空则不显示（由调用方先剔除主标题与重复项，见 `SubtitleComposer.resolve`）。
  final List<String> aliases;

  /// 元数据条目（会社 / 发售日 / 星级 / 热度 / 数据来源），
  /// 由页面复用既有 `_buildMetadataChips()` 生成，样式零改动
  final List<Widget> metaItems;

  final Widget tags;

  /// 返回键 + 分级面包屑（沿用页面既有实现）
  final Widget leading;

  /// 操作按钮行的测量锚点：页面据此把「下载 / 分享」浮层贴到按钮旁
  final Key? actionRowKey;

  final VoidCallback? onGet;
  final VoidCallback? onShare;
  final VoidCallback? onUpload;
  final VoidCallback onLike;
  final VoidCallback onFeedback;

  /// 打开补丁站（PATCH-STATION，用户 2026-11-10 指定）。
  ///
  /// 位置：**「分享」与「上传」之间**（20:16 改口；原定「获取/分享」之间作废）。
  /// 语义：与「分享」同为次要动作，故用中性灰描边胶囊，不与「获取」抢主色。
  /// ⚠️ 与 `getEnabled` **不联动**：补丁查询只依赖作品身份，不依赖本地是否
  /// 已安装，未获取的作品也应该能查补丁。
  final VoidCallback? onPatch;
  final bool patchEnabled;

  /// 「补丁」按钮的定位锚点（页面据此把补丁站横条贴到按钮下方）
  final Key? patchButtonKey;

  /// 一键跳 KUNGAL 站内详情页（需求 2026-10-24）。
  ///
  /// ⚠️ 为 null 时**不渲染这个入口**——由页面决定「该作品有没有 KUNGAL 页」，
  /// 未确定前一律不显示，避免出现点了无处可去的死按钮。
  ///
  /// ★ 2026-10-24 改版后入口是**纯图标**（与「喜欢 / 反馈」同规格），
  /// 故不再有文案参数。
  final VoidCallback? onOpenKungal;

  /// 「获取」按钮文案（按安装状态变形：获取 / 已安装 / 安装中 / 排队中）
  final String getLabel;
  final bool getEnabled;
  final bool getBusy;
  final bool shareEnabled;
  final bool uploadEnabled;

  /// 「喜欢」点亮态 + 作品级点赞数（主线补完 §14.2-P2）：
  /// liked=true 显示实心心形；likeCount>0 时图标旁显示计数
  final bool liked;
  final int likeCount;

  /// 「喜欢」是否可点。false = 灰置（半透明 + 不可点 + 基本光标），
  /// 供站外作品详情（SITE-SEARCH）等无点赞能力的场景复用本头部。
  /// 默认 true —— 原生详情页不传此参，行为零变化。
  final bool likeEnabled;

  /// 「反馈」是否可点。语义同 [likeEnabled]。
  final bool feedbackEnabled;

  static const double coverWidth = 135;
  static const double coverHeight = 205;

  /// 封面 → 右列的横向间距
  ///
  /// 设计实测（`Shell.png`）：封面右边框 x≈378（含 2.4° 旋转，在分割线所在的
  /// y=213 处为 378.4），右列（分割线 / 别名胶囊 / 元数据 / 标签 / 按钮行）统一
  /// 左起 x=388 ⇒ **间距 10**。
  static const double _coverGap = 10;
  static const double _actionHeight = 38;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        leading,
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: _coverGap),
            Expanded(child: _buildRightColumn(context)),
          ],
        ),
      ],
    );
  }

  /// 右列纵向排布。
  ///
  /// 设计实测（`Shell.png` 右列 x 388..1000，逐行非背景扫描；
  /// 封面顶 y=81 与标题**行盒**顶对齐 ⟹ 标题 lineHeight = 42/35 ≈ 1.2，
  /// 据此把「ink 边界」换算成「行盒边界」）：
  /// ```
  /// 大标题   行盒 81..122   ink  85..119（字号 35，字距 2.0，F1 得意黑）
  /// 别名胶囊 125..149  h25  ← 间距 3（行盒底 122 → 胶囊顶 125）
  /// 元数据行 ink 164..175   ← 间距 12（胶囊底 149 → 行盒顶 161）
  /// 标签行   186..204  h19  ← 间距 8
  /// 分割线   213..214  2px  ← 间距 9
  /// 按钮行   223..260  h38  ← 间距 8
  /// [截图/系列] 279..       ← 间距 18（由外层页面控制）
  /// ```
  Widget _buildRightColumn(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppStyles.titleLarge.copyWith(
            fontSize: 35,
            letterSpacing: 2.0,
            height: 1.18, // 设计 1.2
          ),
        ),
        if (aliases.isNotEmpty) ...[
          const SizedBox(height: 3),
          AliasPillWrap(aliases: aliases),
        ],
        if (metaItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metaItems,
          ),
        ],
        const SizedBox(height: 8),
        tags,
        const SizedBox(height: 9),
        _buildDivider(),
        const SizedBox(height: 8),
        _buildActionRow(),
      ],
    );
  }

  /// 强调分割线（设计 #2B2B2B；走主题令牌随主题明暗自适应）
  Widget _buildDivider() {
    return Container(
      height: 2,
      decoration: BoxDecoration(
        color: AppColors.dividerStrong,
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  // ---------- 操作按钮行 ----------
  //
  // 设计实测（`Shell.png` 1:1 像素采样，y 223..260）：
  // ```
  // |获取 86|9|分享 82|9|上传 88|22|▏|29|♡|33|💬        (388 → 774)
  // ```
  // - 获取：底 #2DA6D4 / 内容纯白 / 图标 = 下箭头入托盘
  // - 分享：底 #262626 / **内容与 1px 描边均为 #2DA6D4**（不是白字）
  // - 上传：底 #6841C4 / 图标 = 上箭头出托盘
  // - ▏：2×36 竖线，色 #454544
  // - ♡ / 💬：**裸描边图标**（无 38×38 描边框），色 #DD1B24 / #00AD38
  //
  // ⚠️ 一处**有意偏离设计原值**：设计稿里「上传」的内容色实测为 #2A5FA5
  //    （暗蓝），落在 #6841C4 底上对比度仅 ~2.1:1，肉眼近乎糊掉；同排的
  //    「获取」用的是纯白。判定为设计稿笔误，故此处统一取纯白。
  //    如需严格复刻，把 `AppColors.onAccentSolid` 换成 `Color(0xFF2A5FA5)` 即可。
  Widget _buildActionRow() {
    // Wrap 的 spacing 会插在所有子项之间，故用「目标间距 − spacing」的
    // 无高占位块补齐设计间距（9 / 22 / 29 / 33）。
    const gap = 9.0;
    return KeyedSubtree(
      key: actionRowKey,
      child: Wrap(
        spacing: gap,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // 文案随安装状态变形（获取 / 已安装 / 安装中 / 排队中），
          // 由页面通过 getLabel 传入（`_getButtonLabel`）。
          _buildPrimary(
            getLabel,
            Icons.download_rounded,
            onGet,
            background: AppColors.accentCyan,
            foreground: AppColors.onAccentSolid,
            enabled: getEnabled,
            busy: getBusy,
          ),
          _buildPrimary(
            '分享',
            Icons.account_tree_outlined,
            onShare,
            background: AppColors.accentInk,
            foreground: AppColors.accentCyan,
            borderColor: AppColors.accentCyan,
            enabled: shareEnabled,
          ),
          // 补丁站（PATCH-STATION）：位置＝「分享」与「上传」之间（用户指定）。
          // 中性灰描边，与「分享」同构的次要动作语法，不抢「获取」的青色主色。
          if (onPatch != null)
            KeyedSubtree(
              key: patchButtonKey,
              child: _buildPrimary(
                '补丁',
                Icons.auto_fix_high_rounded,
                onPatch,
                background: AppColors.accentInk,
                foreground: AppColors.secondaryText,
                borderColor: AppColors.secondaryText.withOpacity(0.55),
                enabled: patchEnabled,
              ),
            ),
          _buildPrimary(
            '上传',
            Icons.upload_rounded,
            onUpload,
            background: AppColors.accentViolet,
            foreground: AppColors.onAccentSolid,
            enabled: uploadEnabled,
          ),
          const SizedBox(width: 22 - gap),
          _buildActionSeparator(),
          const SizedBox(width: 29 - gap),
          _buildIconAction(
              liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              '喜欢', AppColors.heartRed, onLike,
              count: likeCount,
              enabled: likeEnabled),
          const SizedBox(width: 33 - gap),
          // KUNGAL 外跳：插在「喜欢」与「反馈」之间（用户指定位置）。
          // 裸图标后宽度仅 24（原胶囊为 84+），不再有挤行的风险。
          if (onOpenKungal != null) ...[
            _buildKungalLink(onOpenKungal!),
            const SizedBox(width: 33 - gap),
          ],
          _buildIconAction(Icons.chat_bubble_outline_rounded, '反馈',
              AppColors.feedbackGreen, onFeedback,
              enabled: feedbackEnabled),
        ],
      ),
    );
  }

  /// KUNGAL 站内详情外跳 —— **裸图标**，与「♡ 喜欢」「💬 反馈」同一规格。
  ///
  /// 位置：「喜欢」与「反馈」两枚图标之间（用户指定）。原本 33 的图标间距被它
  /// 分成 33 / 33 两段，右侧锚点（反馈图标）的 x 坐标不变。
  ///
  /// ★ 2026-10-24 改版：此前是带文字+描边的胶囊，用户要求改为纯图标，与相邻
  /// 两枚图标样式一致 —— 直接复用 [_buildIconAction]（同为 20px 图标、38 高
  /// 命中区、hover 手型、Tooltip），不再自绘容器。颜色用 `secondaryText`，
  /// 与红/绿两枚图标并列时保持中性，不抢「喜欢/反馈」的语义色。
  Widget _buildKungalLink(VoidCallback onTap) {
    return _buildIconAction(
      Icons.open_in_new_rounded,
      '在 KUNGAL 查看更完整的资料',
      AppColors.secondaryText,
      onTap,
    );
  }

  /// 竖线分隔（设计 2×36，#454544）
  Widget _buildActionSeparator() {
    return Container(
      width: 2,
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.dividerStrong.withOpacity(0.55),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  /// 实底主按钮。
  ///
  /// ⚠️ 刻意**不用 `alignment:`** —— `Container` 一旦设了 `alignment`，在
  /// `Wrap`（传入 maxWidth 的松约束）里会**撑满整行**，三个按钮就会各占一行。
  /// 改为 `Center(widthFactor: 1.0)` + `minWidth` 让按钮按内容定宽。
  Widget _buildPrimary(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    required Color background,
    required Color foreground,
    Color? borderColor,
    bool enabled = true,
    bool busy = false,
  }) {
    final active = enabled && !busy && onTap != null;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.5,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: _actionHeight,
            constraints: const BoxConstraints(minWidth: 82),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: borderColor == null
                  ? null
                  : Border.all(color: borderColor, width: 1),
            ),
            child: Center(
              widthFactor: 1.0,
              child: busy
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(foreground),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 17, color: foreground),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: AppStyles.bodyRegular.copyWith(
                            fontSize: 13.5,
                            color: foreground,
                            fontWeight: FontWeight.w600,
                            fontStyle: FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 裸描边图标按钮（无外框、无底板，仅图标本身；设计 17×17 / 15×15）。
  /// [count] 非空且 >0 时图标右侧显示计数文字（「喜欢」作品级点赞数），
  /// null / 0 时渲染与旧版完全一致（零回归）。
  ///
  /// [enabled] = false 时灰置：半透明 + 不可点 + 基本光标（站外详情复用）。
  /// 与 `_buildPrimary` 的灰置口径一致（opacity 0.5 档改为图标更淡的 0.35，
  /// 因为裸图标没有底色，0.5 在浅主题下仍显得像可点）。
  Widget _buildIconAction(
    IconData icon,
    String tooltip,
    Color color,
    VoidCallback onTap, {
    int? count,
    bool enabled = true,
  }) {
    final effectiveColor = enabled ? color : color.withOpacity(0.35);
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          // 命中区保持 38 高（与按钮行等高），视觉只有图标（+可选计数）
          child: SizedBox(
            height: _actionHeight,
            child: Center(
              widthFactor: 1.0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: effectiveColor),
                  if (count != null && count > 0 && enabled) ...[
                    const SizedBox(width: 4),
                    Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        color: effectiveColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
