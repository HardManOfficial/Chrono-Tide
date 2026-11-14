import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/sidebar.dart';

/// 侧边栏等比缩放布局哨兵（SIDEBAR-SCALE）
///
/// 背景（真实缺陷）：展开态侧栏此前全部是固定像素
/// （侧栏 224 / 卡片 175×144 / 间距 32 / 主页 56），纵向固定需求恒为 698 逻辑 px。
/// 窗口可用高不足时 `Expanded` 只拿到剩余高度、子项又是固定高 ⇒ `RenderFlex`
/// **不压缩子项**，超出部分被裁掉。真机表现为：三张卡按 176 步进往下堆，
/// 「添加」只剩顶部一截图标、「主页」被顶到底部且文字裁到窗口外。
///
/// 本测试锁死三件事：
/// 1. 各档窗口高下 **无 RenderFlex 溢出**（takeException 为 null）；
/// 2. 三张导航卡 + 主页按钮的矩形**完整落在窗口内**（用户能点到的前提）；
/// 3. 卡片**宽高同比缩放**（高宽比恒为 144/175），即「不同窗口尺寸下视觉统一」。
///
/// 🔴 测量口径（本文件踩过的两个坑，改动前务必读完）：
///
/// (1) `find.byType(AnimatedContainer)` 命中的 Element 的 renderObject 是
///     **含 margin 的外层 RenderPadding**（AnimatedContainer 内部结构为
///     `Padding(margin) > DecoratedBox`）。导航卡写了
///     `margin: EdgeInsets.only(bottom: 32*s)`，所以外层 box 高 = 卡片高 + 32*s。
///     直接用 box.size.height 会读成 128（= 104.8 + 23.3），
///     得出"卡片被撑成正方形"的假象 ⇒ **必须减去 gap**。
///     主页按钮相反：它的 `Padding(bottom: 20*s)` 在 AnimatedContainer **外部**，
///     所以读到的就是本体高 56*s，不需要减。
///
/// (2) 坐标系原点不是 0。侧栏从标题栏下沿 y=32 开始铺到窗口底部，
///     所以"不出界"的下界是 **window.height**，不是 `window.height - 32`。
///     用后者会让所有小窗口档位误报"主页底边出界 17px"。
void main() {
  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题时
    // _themes 为空会抛 null check（与 explore_hall / big_picture 测试同款处理）
    ThemeRegistry.registerBuiltinThemes();
  });

  /// 在指定窗口尺寸（逻辑 px）下渲染侧栏。
  ///
  /// 结构必须复现真实主壳：`CustomTitleBar(child: SizedBox.expand(Row(Sidebar, ...)))`
  /// ⇒ 用 `Column(SizedBox(32), Expanded(Row(...)))` 表达，让 Sidebar 拿到的
  /// `constraints.maxHeight` 精确等于 `window.height - 32`。
  /// 若简写成 `Row(stretch) > SizedBox(height: h-32) > Sidebar`，
  /// Sidebar 会拿到整窗高，测出的 scale 比真实大一档。
  Future<void> pumpSidebar(
    WidgetTester tester, {
    required Size window,
    bool collapsed = false,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double titleBar = 32.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: titleBar),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Sidebar(
                      currentPage: NavPage.library,
                      onPageChanged: (_) {},
                      isCollapsed: collapsed,
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // 卡片与侧栏宽都是 200~250ms 的 AnimatedContainer 补间，
    // 必须推到动画收敛后再量，否则读到中间帧尺寸。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
  }

  /// 三张导航卡的本体矩形（已扣除底部 gap margin），按 y 升序。
  List<Rect> cardRects(WidgetTester tester, double scale) {
    final double expectW = 175 * scale;
    final double expectH = 144 * scale;
    final double gap = 32 * scale;
    final rects = <Rect>[];
    for (final element in find.byType(AnimatedContainer).evaluate()) {
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox) continue;
      final size = renderObject.size;
      // 外层 box 宽 = 卡片宽；外层 box 高 = 卡片高 + gap
      if ((size.width - expectW).abs() > 1.5) continue;
      if ((size.height - (expectH + gap)).abs() > 1.5) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      rects.add(Rect.fromLTWH(
        origin.dx,
        origin.dy,
        size.width,
        size.height - gap,
      ));
    }
    rects.sort((a, b) => a.top.compareTo(b.top));
    return rects;
  }

  /// 主页按钮矩形（本体高即 56*s，外部的 Padding 不影响这里读到的 box）。
  Rect? homeRect(WidgetTester tester, double scale) {
    final double expectW = 175 * scale;
    final double expectH = 56 * scale;
    for (final element in find.byType(AnimatedContainer).evaluate()) {
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox) continue;
      final size = renderObject.size;
      if ((size.width - expectW).abs() > 1.5) continue;
      if ((size.height - expectH).abs() > 1.5) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
    }
    return null;
  }

  group('展开态：各档窗口高都必须完整可见', () {
    // 覆盖：应用最小窗口(960×540) / 截图实测故障档(960×600=1200×750@125%)
    //       / 默认窗口 / 常见档 / 大屏
    for (final window in <Size>[
      const Size(960, 540),
      const Size(960, 600),
      const Size(1280, 720),
      const Size(1366, 768),
      const Size(1920, 1080),
      const Size(2560, 1440),
      // 低于最小窗口的越界档：验证 minScale 触底时不崩、不溢出
      const Size(900, 500),
    ]) {
      final tag = '${window.width.toInt()}×${window.height.toInt()}';
      testWidgets('$tag：无溢出且全部可见', (tester) async {
        await pumpSidebar(tester, window: window);

        // ① 无 RenderFlex 溢出（这是原缺陷的直接症状）
        expect(tester.takeException(), isNull, reason: '$tag 出现布局溢出');

        final double usable = window.height - 32;
        final double s = Sidebar.scaleFor(usable);
        // ② 下界是窗口底（侧栏从 y=32 开始铺到底），不是 usable
        final double bottomLimit = window.height;

        // ③ 三张导航卡全部渲染且完整在窗口内
        final cards = cardRects(tester, s);
        expect(cards.length, 3, reason: '$tag 导航卡数量不对');
        for (var i = 0; i < cards.length; i++) {
          final r = cards[i];
          expect(r.top, greaterThanOrEqualTo(-0.5),
              reason: '$tag 卡${i + 1} 顶边出界: $r');
          expect(r.bottom, lessThanOrEqualTo(bottomLimit + 0.5),
              reason: '$tag 卡${i + 1} 底边被裁: $r（窗口底 $bottomLimit）');
        }

        // ④ 主页按钮完整在窗口内，且不被标题栏遮住
        final home = homeRect(tester, s);
        expect(home, isNotNull, reason: '$tag 主页按钮未渲染');
        expect(home!.bottom, lessThanOrEqualTo(bottomLimit + 0.5),
            reason: '$tag 主页按钮底边被裁: $home（窗口底 $bottomLimit）');
        expect(home.top, greaterThanOrEqualTo(32 - 0.5),
            reason: '$tag 主页按钮被标题栏遮住: $home');

        // ⑤ 四个入口的文字都在（渲染性检查；不做位置断言——
        //    find.text 会同时命中 Tooltip 里的影子文本）
        for (final label in ['库', '探索', '添加', '主页']) {
          expect(find.text(label), findsOneWidget, reason: '缺少「$label」');
        }
      });
    }
  });

  group('等比缩放：卡片高宽比恒定（视觉统一）', () {
    testWidgets('不同窗口高下卡片高宽比一致', (tester) async {
      // 基准比值（设计稿 144 / 175 ≈ 0.8229）
      const double baseRatio = 144 / 175;
      final ratios = <String, double>{};

      for (final window in <Size>[
        const Size(960, 600),
        const Size(1280, 720),
        const Size(1920, 1080),
        const Size(2560, 1440),
      ]) {
        await pumpSidebar(tester, window: window);
        final s = Sidebar.scaleFor(window.height - 32);
        final cards = cardRects(tester, s);
        expect(cards.length, 3, reason: '导航卡数量不对');
        ratios['${window.width.toInt()}×${window.height.toInt()}'] =
            cards.first.height / cards.first.width;
      }

      ratios.forEach((tag, r) {
        expect(r, closeTo(baseRatio, 0.01),
            reason: '$tag 卡片高宽比 $r 偏离设计稿 $baseRatio（全部：$ratios）');
      });
    });

    testWidgets('缩放系数随可用高单调变化（大窗口更大、小窗口更小）', (_) async {
      final small = Sidebar.scaleFor(568); // 960×600 的可用高
      final mid = Sidebar.scaleFor(688); // 1280×720
      final large = Sidebar.scaleFor(1408); // 2560×1440
      expect(small, lessThan(mid));
      expect(mid, lessThan(large));
      // 未约束（无边界）时视为不缩放
      expect(Sidebar.scaleFor(double.infinity), 1.0);
      // 极矮窗口触底到可读下限，不无限缩小
      expect(Sidebar.scaleFor(0), Sidebar.scaleFor(50));
      expect(Sidebar.scaleFor(0), 0.55);
      // 基准高 698 恰好 scale = 1.0
      expect(Sidebar.scaleFor(698), closeTo(1.0, 1e-9));
    });

    testWidgets('宽度与缩放口径一致（供外层定位切换按钮复用）', (_) async {
      expect(Sidebar.widthFor(isCollapsed: true, availableHeight: 600), 71.0);
      final w = Sidebar.widthFor(isCollapsed: false, availableHeight: 568);
      // 568 / 698 ≈ 0.8138 → 224 × 0.8138 ≈ 182.3
      expect(w, closeTo(224 * Sidebar.scaleFor(568), 0.01));
      // 大窗口下侧栏变宽（等比，不设上限）
      final wide = Sidebar.widthFor(isCollapsed: false, availableHeight: 1408);
      expect(wide, greaterThan(224));
    });
  });

  group('收起态不受影响', () {
    testWidgets('960×540 收起态无溢出', (tester) async {
      await pumpSidebar(
        tester,
        window: const Size(960, 540),
        collapsed: true,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('CT'), findsOneWidget);
    });
  });

  group('内外宽度口径必须对齐（切换按钮不错位）', () {
    testWidgets('外层按窗口高算的宽度 == 侧栏实际渲染宽', (tester) async {
      // 生产链路：
      //   main_container._buildDesktopShell 的 LayoutBuilder 在 CustomTitleBar **外面**
      //   ⇒ 拿到的是整窗高，必须先减 kTitleBarHeight 才能与 Sidebar 内部口径一致。
      // 这里直接对同一档窗口，分别用「减 32」与「不减」算宽度并比对实际渲染宽，
      // 锁死"减 32"这个约定——漏减会让切换按钮偏出约 10px（1280×720 档）。
      for (final window in <Size>[
        const Size(960, 540),
        const Size(1280, 720),
        const Size(2560, 1440),
      ]) {
        await pumpSidebar(tester, window: window);

        // 侧栏根 AnimatedContainer 的实际宽度
        final rootBox = tester
            .firstRenderObject<RenderBox>(find.byType(AnimatedContainer).first);
        final double actual = rootBox.size.width;

        final double withTitleBar = Sidebar.widthFor(
          isCollapsed: false,
          availableHeight: window.height - 32,
        );
        final double withoutTitleBar = Sidebar.widthFor(
          isCollapsed: false,
          availableHeight: window.height,
        );

        expect(actual, closeTo(withTitleBar, 0.5),
            reason: '${window.width}×${window.height}：实际宽 $actual 与'
                '「减标题栏」口径 $withTitleBar 不符');
        // 若两者恰好相等（极巧合的档位）则该断言无意义，跳过
        if ((withTitleBar - withoutTitleBar).abs() > 1.0) {
          expect(actual, isNot(closeTo(withoutTitleBar, 0.5)),
              reason: '${window.width}×${window.height}：外层疑似漏减标题栏，'
                  '按整窗高算出 $withoutTitleBar');
        }
      }
    });
  });
}
