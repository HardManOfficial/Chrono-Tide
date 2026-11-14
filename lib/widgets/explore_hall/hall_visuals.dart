/// 探索大厅共享装饰组件（纯视觉层，无业务逻辑）
///
/// 设计口径（features/explore_hall_implementation_plan.md §17）：
/// - 所有取色走 [AppColors] 主题 getter（深/浅双分支），不硬编码深色——
///   浅色主题与背景图模式下必须同样可读（v3.8 教训）；
/// - 辉光/光斑一律用径向渐变贴形，禁止圆形 BoxShadow 底块；
/// - 封面压字 scrim 固定用黑色渐变（白字在深浅主题的图片上都需要暗底），
///   属于图片压字惯例，不受主题分支约束。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../../theme/app_theme_manager.dart';

/// 品牌渐变工具：主色 → 主色偏绿（青），随主题令牌联动。
class HallGradients {
  HallGradients._();

  /// 主双色（brandBlue → 青绿），用于强调条 / 开始按钮 / 字母徽章
  static List<Color> get accent => [
        AppColors.brandBlue,
        Color.lerp(AppColors.brandBlue, AppColors.successGreen, 0.55)!,
      ];

  static LinearGradient get accentLinear => LinearGradient(
        colors: accent,
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

  /// 封面底部信息条渐变（透明 → 黑 70%），压白字用，主题无关
  static const LinearGradient coverScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x00000000), Color(0xB3000000)],
  );
}

/// 板块 / 内嵌面板统一装饰（深浅双分支集中在这里，避免各板块散落硬编码）
class HallDecor {
  HallDecor._();

  /// 板块大卡片面：垂直微渐变 + 暖调描边 + 柔和投影（xl 圆角）
  ///
  /// 浅色主题把 titleBrown 以 5% 掺入白色得到「暖纸」底色，
  /// 呼应设计稿的奶油纸面；深色主题用白的高透明度微渐变。
  static BoxDecoration get card {
    final cream = Color.lerp(Colors.white, AppColors.titleBrown, 0.05)!;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: AppColors.isDark
            ? [Colors.white.withOpacity(0.055), Colors.white.withOpacity(0.028)]
            : [cream.withOpacity(0.72), cream.withOpacity(0.46)],
      ),
      border: Border.all(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.09)
            : AppColors.titleBrown.withOpacity(0.22),
      ),
      borderRadius: BorderRadius.circular(AppRadius.xl),
      boxShadow: [
        BoxShadow(
          color: AppColors.shadowColor
              .withOpacity(AppColors.isDark ? 0.32 : 0.08),
          blurRadius: 16,
          offset: const Offset(0, 5),
        ),
      ],
    );
  }

  /// 板块内嵌小面板（日期面板 / 随机面板 / 列表行底）
  static BoxDecoration get panel => BoxDecoration(
        color: AppColors.isDark
            ? Colors.white.withOpacity(0.035)
            : Colors.black.withOpacity(0.025),
        border: Border.all(
          color: (AppColors.isDark ? Colors.white : Colors.black)
              .withOpacity(0.05),
        ),
        borderRadius: BorderRadius.circular(AppRadius.md + 2),
      );
}

/// 页面级氛围光：左上主色 + 右下暖色两团径向光斑垫底（BPM 侧栏同思路）。
///
/// 用户设置了背景图时自动关闭（[CTThemeData.hasBackgroundImage]），
/// 不与背景图打架；光斑是径向渐变淡出，不是 BoxShadow 圆块。
class HallAmbientBackdrop extends StatelessWidget {
  final Widget child;

  const HallAmbientBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (AppThemeManager.colors.hasBackgroundImage) {
      // 背景图模式：只保留页面底色（pageBackground 此时为透明）
      return Container(color: AppColors.pageBackground, child: child);
    }
    return Container(
      color: AppColors.pageBackground,
      child: Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: const Alignment(-0.9, -1.05),
                  child: _blob(AppColors.brandBlue, 0.10, 360),
                ),
                Align(
                  alignment: const Alignment(0.95, 1.1),
                  child: _blob(AppColors.titleBrown, 0.09, 320),
                ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  static Widget _blob(Color color, double alpha, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withOpacity(alpha), color.withOpacity(0)],
        ),
      ),
    );
  }
}

/// 板块标题图标徽章：圆角方块 + 主题色淡底 + 主题色图标
class HallIconBadge extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final double size;

  const HallIconBadge({
    super.key,
    required this.icon,
    required this.accent,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accent.withOpacity(0.13),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(color: accent.withOpacity(0.25)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.62, color: accent),
    );
  }
}

/// 站点首字母渐变徽章（无 favicon 场景的站点标识，取标题首字符）
class HallLetterAvatar extends StatelessWidget {
  final String title;
  final List<Color>? colors;
  final double size;

  const HallLetterAvatar({
    super.key,
    required this.title,
    this.colors,
    this.size = 20,
  });

  static String _letterOf(String title) {
    final t = title.trim();
    if (t.isEmpty) return '?';
    return String.fromCharCode(t.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors ?? HallGradients.accent,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      alignment: Alignment.center,
      child: Text(
        _letterOf(title),
        style: TextStyle(
          fontFamily: AppStyles.enDecorativeFont,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w600,
          height: 1,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 月历格子的发售圆点（1-3 颗，超出截断；呼应设计稿的日期下小点）
class HallReleaseDots extends StatelessWidget {
  final int count;
  final Color color;

  const HallReleaseDots({
    super.key,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final n = count.clamp(1, 3);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Container(
            width: 3.2,
            height: 3.2,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
        ],
      ],
    );
  }
}

/// 标题渐变下划线条（笔触感，F1 标题的固定搭档）
class HallAccentUnderline extends StatelessWidget {
  final double width;

  const HallAccentUnderline({super.key, this.width = 46});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 3,
      decoration: BoxDecoration(
        gradient: HallGradients.accentLinear,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// 横向列表的桌面鼠标拖拽支持：Flutter 桌面默认 dragDevices 不含鼠标，
/// 横向 ListView 无法用鼠标拖动——包一层放开（左键长按 / 中键拖动，
/// 触屏不受影响；拖动超过 slop 自动取消 tap，子项点击不受干扰）。
class HallHScroll extends StatelessWidget {
  final Widget child;

  const HallHScroll({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: <PointerDeviceKind>{
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: child,
    );
  }
}

/// 「整行填满」度量结果：几行 + 每行实际高度。
class HallRowsFit {
  /// 能完整放下的行数（≥ 1）
  final int rows;

  /// 实际行高：`(可用高 - (rows-1)×gap) / rows`，保证 rows 行**正好**填满可用高
  final double rowHeight;

  const HallRowsFit({required this.rows, required this.rowHeight});
}

/// 整行填满：把可用高切成「rows 行 + rows-1 个间距」，行高吃掉余量。
///
/// 🔴 为什么不能「固定行高 + 向下取整」（2026-10-25 第二轮真机事故）：
/// 上一版的做法是「行高固定 48，可用高向下取整到整行」，余量留在列表底部。
/// 1280×720 下余量只有 1.3px 看不出问题，但窗口一变矮就掉进坑里 ——
/// 例如可用高 205 时向下取整成 4 行 204（没事），而可用高 255 时同样只放
/// 4 行 ⇒ 底部空出 **51px（整整一行）**，用户看到的就是「这里应该有卡片，
/// 却是一块黑色留白」。
///
/// 正确做法是反过来：行数由「最小行高」定，**行高吃掉余量**。这样：
/// - 永远填满，底部不留任何残行空白；
/// - 行高只会在 [minRowHeight, minRowHeight + step/rows] 区间轻微浮动
///   （48 → 最多约 74），行内内容居中，视觉上看不出拉伸。
HallRowsFit hallFitRows({
  required double availableHeight,
  required double minRowHeight,
  required double gap,
}) {
  if (!availableHeight.isFinite || availableHeight <= 0) {
    return HallRowsFit(rows: 1, rowHeight: minRowHeight);
  }
  int rows = ((availableHeight + gap) / (minRowHeight + gap)).floor();
  if (rows < 1) rows = 1;
  // 可用高连一行最小高都不到时，行高直接等于可用高（宁可压扁也不留黑边）
  final double rowHeight = (availableHeight - (rows - 1) * gap) / rows;
  return HallRowsFit(rows: rows, rowHeight: rowHeight);
}

/// 「整卡等分」度量：每屏整卡数 + 实际卡宽。
class HallCardMetrics {
  /// 每屏完整可见的卡片数（≥ 1）
  final int perView;

  /// 实际卡宽：`(可用宽 - 间距×(perView-1)) / perView`
  final double cardWidth;

  const HallCardMetrics({required this.perView, required this.cardWidth});

  /// 纯函数：由可用宽反推整卡布局，**保证 N 张整卡正好等于可用宽**。
  ///
  /// 🔴 为什么必须这样算（2026-10-25 真机事故）：站点/系列原先写死卡宽
  /// （152 / 132）+ 固定间距 8，而 1280×720 下右栏内宽只有 ≈423：
  /// - 站点 3 张需 472 ⇒ 第 3 张被裁掉 49px；
  /// - 系列 3 张需 412 ⇒ 第 3 张切边、第 4 张还露出 11px 一条。
  /// 用户原话「有部分的界面就一直[半截]在那」。固定像素排版永远对不上可用宽，
  /// 必须反过来算：先定「每屏几张」（按最小可读卡宽推），再让卡宽吃掉余量。
  ///
  /// 因为 `perView × cardWidth + (perView-1) × gap == availableWidth` 恒等，
  /// 第 perView+1 张卡**正好从可用宽处开始** ⇒ 永远不露半张。
  static HallCardMetrics resolve({
    required double availableWidth,
    required double minCardWidth,
    double gap = 8,
  }) {
    if (!availableWidth.isFinite || availableWidth <= 0) {
      // 未被约束 / 尺寸未知：退回最小卡宽，不猜多张
      return HallCardMetrics(perView: 1, cardWidth: minCardWidth);
    }
    int perView = ((availableWidth + gap) / (minCardWidth + gap)).floor();
    if (perView < 1) perView = 1;
    final double w = (availableWidth - gap * (perView - 1)) / perView;
    return HallCardMetrics(perView: perView, cardWidth: w < 1 ? 1 : w);
  }
}

/// 横向卡片行：每屏只放**整张**卡，宽度按可用空间等分。
///
/// 与直接写 `ListView.separated` + 固定卡宽的区别：卡宽由 [minCardWidth]
/// 与当前可用宽实时反推（见 [HallCardMetrics.resolve]），任何窗口宽度下
/// 都不会出现「半张卡被裁」；超出每屏数量的卡片仍可横向拖动/滚动查看。
class HallCardRow extends StatelessWidget {
  final int itemCount;

  /// 卡片可接受的最小宽度（决定每屏张数的下限）；也是未被约束时的兜底宽度
  final double minCardWidth;

  /// 卡间距
  final double gap;

  /// `cardWidth` 为该卡应占的宽度，调用方把它喂给卡片自身的宽度约束
  final Widget Function(BuildContext context, int index, double cardWidth)
      itemBuilder;

  const HallCardRow({
    super.key,
    required this.itemCount,
    required this.minCardWidth,
    required this.itemBuilder,
    this.gap = 8,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final HallCardMetrics m = HallCardMetrics.resolve(
          availableWidth: constraints.maxWidth,
          minCardWidth: minCardWidth,
          gap: gap,
        );
        return HallHScroll(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: itemCount,
            separatorBuilder: (_, __) => SizedBox(width: gap),
            itemBuilder: (BuildContext context, int i) => SizedBox(
              width: m.cardWidth,
              child: itemBuilder(context, i, m.cardWidth),
            ),
          ),
        );
      },
    );
  }
}
