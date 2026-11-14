import 'dart:math' as math;

/// 补丁结果区的网格度量（**两列**，宽窗口才考虑三列）。
///
/// ## 为什么单独抽出来
///
/// v5 之前卡片列数是拿 `_PanelMetrics.width` 算的 —— 那个值是**面板**宽，
/// 但结果区外面还套着滚动视图的内边距，一旦两者算叉，`Wrap` 就会
/// 「一张卡占一行、右边留一大片空白」（用户实测截图就是这个现象）。
/// 现在改成：**由 `LayoutBuilder` 拿真实可用宽再算**，并强制恒等式
///
/// ```
/// columns × cardWidth + (columns − 1) × gap == innerWidth
/// ```
///
/// 这样「整行刚好铺满、不留残列」是算出来的，不是碰运气。
///
/// ## 列数怎么定
///
/// 从 [maxColumns] 往下试，取第一个「每列不窄于 [minCardWidth]」的方案；
/// 都不满足就退回一列 —— **一列时卡片宽度 = 整行**，所以永远不会出现
/// 「只有一张卡却只占半行」的空洞。
class PatchGridMetrics {
  const PatchGridMetrics({
    required this.columns,
    required this.cardWidth,
    required this.gap,
    required this.innerWidth,
  });

  /// 列数（1 起）
  final int columns;

  /// 单张卡的宽度（由恒等式反推，不写死）
  final double cardWidth;

  /// 列间距 / 行间距
  final double gap;

  /// 参与计算的可用宽（已扣掉左右内边距）
  final double innerWidth;

  /// 卡片再窄就放不下「站名 + 徽章 + 大小」那一行，会挤成两行
  static const double minCardWidth = 236;

  /// 面板最宽 700 ⇒ 三列时每列只有 ~218，所以实际到不了 3 列；
  /// 保留 3 是为了将来面板变宽不用再改这里。
  static const int maxColumns = 3;

  static PatchGridMetrics resolve({
    required double innerWidth,
    double gap = 10,
  }) {
    if (!innerWidth.isFinite || innerWidth <= 0) {
      return PatchGridMetrics(
        columns: 1,
        cardWidth: math.max(0, innerWidth),
        gap: gap,
        innerWidth: math.max(0, innerWidth),
      );
    }

    var columns = 1;
    for (var c = maxColumns; c >= 1; c--) {
      final w = (innerWidth - gap * (c - 1)) / c;
      if (w >= minCardWidth) {
        columns = c;
        break;
      }
    }

    final cardWidth = (innerWidth - gap * (columns - 1)) / columns;
    return PatchGridMetrics(
      columns: columns,
      cardWidth: cardWidth.isFinite && cardWidth > 0 ? cardWidth : 0,
      gap: gap,
      innerWidth: innerWidth,
    );
  }
}
