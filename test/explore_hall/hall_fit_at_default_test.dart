import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/series_model.dart';
import 'package:chrono_tide/pages/explore_hall_page.dart';
import 'package:chrono_tide/services/daily_recommendation_service.dart';
import 'package:chrono_tide/services/explore_calendar_service.dart';
import 'package:chrono_tide/services/kungal_calendar_service.dart';
import 'package:chrono_tide/services/website_bookmark_service.dart';
import 'package:chrono_tide/services/startup_window_size.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/explore_hall/docs_section.dart';
import 'package:chrono_tide/widgets/explore_hall/hall_visuals.dart';
import 'package:chrono_tide/widgets/explore_hall/series_section.dart';
import 'package:chrono_tide/widgets/explore_hall/website_section.dart';

/// 探索大厅「默认尺寸下整份可见」哨兵（2026-10-25）。
///
/// 🔴 事故背景：用户「默认 1280×720 下必须用鼠标拖才能看全整个大厅」。
/// 真机取证结论是**页面级没有滚动**，真正的问题是四处面板内容比面板大、被硬裁：
///   ① 常用站点：卡宽写死 152，3 张需 472，内宽 ≈423 ⇒ 第 3 张切 49px
///   ② 系列合集：卡宽写死 132，3 张需 412，内宽 ≈407 ⇒ 第 3 张切边 + 第 4 张露条
///   ③ 相关话题：列表吃满 217 高，行距 52 ⇒ 4.25 行，第 5 行拦腰切
///   ④ 文档与趣味：正文 + 「了解我们」两枚胶囊 217，视口仅 122.5 ⇒ 溢出 94.5
/// 修法不是加滚动，是让每处尺寸由可用空间反推（见 HallCardMetrics / hallFitRows）
/// 并给文档面板留够高度。本文件把这四条钉成断言。
///
/// 🔴 2026-10-25 第三轮（用户第二次复查）追加四条：
///   ⑤ 站点卡「介绍」被裁 18px —— 根因是 ⋯ 按钮的 M3 默认 48×48 触控区把
///      标题行撑到 48（内容需 78，面板只给 62）；修完实测卡高 61.5、零溢出。
///   ⑥ 相关话题底部一整行黑留白 —— 旧实现「行高固定 48 + 向下取整」，可用高
///      落进 (204, 255] 区间就只放 4 行、底部空出最多 51px。改 hallFitRows。
///   ⑦ 站点/系列被压成扁条 —— 右栏配比 12/12/29 时两块只有 120.2；
///      改 13/14/28 + 外壳 padding 10→8 后为 125.5 / 135.2，卡高 61.5 / 71.2。
///   ⑧ 文档与趣味过高 —— 290.5 → 270.3，正文视口 156.3 仍零滚动。
void main() {
  late Directory tempDir;

  /// 默认窗口 1280×720 下的内容区尺寸（= 窗口宽 - 侧栏 224，窗口高 - 标题栏 32）
  const Size kDefaultContent = Size(1056, 688);

  setUp(() {
    ThemeRegistry.registerBuiltinThemes();
  });

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('chrono_hall_fit_test');
    PathHelper.exeDirOverride = tempDir.path;
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 当日推荐快照（version 2，否则被判旧格式丢弃）
  String snapshot({required int count}) {
    final DateTime n = DateTime.now();
    final String day = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
    final List<String> items = <String>[
      for (var i = 0; i < count; i++)
        '{"gameId":"g$i","title":"游戏$i","coverUrl":"","tags":["t$i"],'
            '"developer":"会社$i","score":${(9 - i / 10).toStringAsFixed(1)}}'
    ];
    return '{"version":2,"day":"$day","dimension":"rating","dimensionValue":null,'
        '"label":"全库高星 · 按星级排序","items":[${items.join(',')}]}';
  }

  /// 注入 3 个站点（带简介）——站点面板只有在有数据时才渲染卡片，
  /// 空态走 HallEmptyHint，永远不会暴露「卡片内容溢出」这类问题。
  void injectSites() {
    for (final String n in <String>['KunGal', 'www.y', 'shion']) {
      // 🔴 不能 await：add() 内部 await 真实文件 IO，在 FakeAsync 里会永久挂起
      unawaited(WebsiteBookmarkService.instance.add(
        title: n,
        url: 'https://$n.example.com',
        note: '$n 的站点简介（用于验证卡片内第二行是否被裁）',
      ));
    }
  }

  const List<SeriesModel> kSeries = <SeriesModel>[
    SeriesModel(id: 's1', title: '命运石之门系列'),
    SeriesModel(id: 's2', title: '恋姬†系列'),
    SeriesModel(id: 's3', title: '秋天的怀抱十二神器'),
  ];

  Future<void> pumpHall(
    WidgetTester tester,
    Size size, {
    int topicCount = 0,
    List<SeriesModel> series = kSeries,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExploreHallPage(
            autoWarmup: false,
            calendarService: ExploreCalendarService.forTest(),
            kungalService: KungalCalendarService.forTest(),
            dailyService: DailyRecommendationService.forTest(
              reader: topicCount > 0 ? () => snapshot(count: topicCount) : null,
            ),
            seriesLoader: () async => series,
            noticeLoader: () async => '测试通知文本',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('默认 1280×720：大厅无任何页面级滚动，也无布局溢出',
      (WidgetTester tester) async {
    await pumpHall(tester, kDefaultContent);

    expect(tester.takeException(), isNull,
        reason: '默认尺寸下出现了 RenderFlex 溢出');

    // 页面级滚动 = 视口高度接近整个内容区且仍可滚。修完后这里必须是 0。
    final List<String> offenders = <String>[];
    for (final Element e in find.byType(Scrollable).evaluate()) {
      final ScrollableState st = (e as StatefulElement).state as ScrollableState;
      final RenderBox rb = e.renderObject! as RenderBox;
      final double max = st.position.maxScrollExtent;
      // 面板内的小列表（文档正文/话题轮播）不在本条断言范围：
      // 只抓「高度≈内容区、可滚 > 0」的整页滚动容器。
      if (rb.size.height >= kDefaultContent.height - 1 && max > 0) {
        offenders.add('${rb.size} 可滚=$max');
      }
    }
    expect(offenders, isEmpty,
        reason: '默认尺寸下出现整页滚动容器（大厅应恒定装在一屏内）：$offenders');
  });

  testWidgets('默认 1280×720：文档与趣味·介绍正文整份可见（零滚动）',
      (WidgetTester tester) async {
    await pumpHall(tester, kDefaultContent);
    expect(tester.takeException(), isNull);

    final Finder docs = find.byType(DocsSection);
    expect(docs, findsOneWidget);

    for (final Element e in find
        .descendant(of: docs, matching: find.byType(Scrollable))
        .evaluate()) {
      final ScrollableState st = (e as StatefulElement).state as ScrollableState;
      expect(st.position.maxScrollExtent, 0,
          reason: '文档面板正文需要滚动 ${st.position.maxScrollExtent}px '
              '⇒ 溢出回归（正文应整份落在视口内）');
    }
  });

  testWidgets('默认 1280×720：文档一级标签单行（5 个同一 top）',
      (WidgetTester tester) async {
    await pumpHall(tester, kDefaultContent);
    expect(tester.takeException(), isNull);

    double? top;
    for (int i = 0; i < 5; i++) {
      final Finder f = find.byKey(ValueKey<String>('docsTab_$i'));
      expect(f, findsOneWidget, reason: '一级标签 docsTab_$i 缺失');
      final double t = tester.getRect(f).top;
      top ??= t;
      expect(t, top,
          reason: 'docsTab_$i 折到第二行 ⇒ 标签行占两行，会挤掉正文视口高度');
    }
  });


  // ───────── 2026-10-25 第三轮：用户第二次复查的四个"奇怪的地方" ─────────

  group('第三轮：卡片完整、列表填满、三块均衡', () {
    testWidgets('默认 1280×720：站点卡简介不被裁（⋯ 按钮不再虚占 48px）',
        (WidgetTester tester) async {
      injectSites();
      await pumpHall(tester, kDefaultContent, topicCount: 10);
      expect(tester.takeException(), isNull,
          reason: '站点卡片内容溢出 ⇒ 卡片下方的简介被裁掉（用户截图的首要问题）');

      final List<double> heights = <double>[];
      for (final Element e in find
          .descendant(
              of: find.byType(WebsiteSection),
              matching: find.byType(AnimatedContainer))
          .evaluate()) {
        final RenderBox rb = e.renderObject! as RenderBox;
        // 排除标题行右侧「+ 添加」小按钮（22 高）
        if (rb.size.height > 40) heights.add(rb.size.height);
      }
      expect(heights.length, 3,
          reason: '应渲染 3 张站点卡，实际 ${heights.length} 张');
      for (final double h in heights) {
        expect(h, greaterThanOrEqualTo(55),
            reason: '站点卡高 $h < 55 ⇒ 简介行贴边（内容自然高 50 + 呼吸）');
        expect(h, lessThanOrEqualTo(84),
            reason: '站点卡高 $h > 84 ⇒ 卡片被拉成方块，宽高比失衡');
      }
    });

    testWidgets('默认 1280×720：相关话题列表整份填满，底部无黑色残行',
        (WidgetTester tester) async {
      await pumpHall(tester, kDefaultContent, topicCount: 10);
      expect(tester.takeException(), isNull);

      final Rect list = tester.getRect(find.byKey(const Key('topicList')));
      double lastBottom = double.negativeInfinity;
      int built = 0;
      for (var i = 0; i < 10; i++) {
        final Finder f = find.byKey(ValueKey<String>('topicRow_$i'));
        if (f.evaluate().isEmpty) continue;
        built++;
        final Rect r = tester.getRect(f);
        if (r.bottom > lastBottom) lastBottom = r.bottom;
      }
      expect(built, greaterThanOrEqualTo(3), reason: '列表渲染行数异常');
      expect(lastBottom, closeTo(list.bottom, 1.0),
          reason: '最后一行底边 $lastBottom ≠ 列表底边 ${list.bottom} ⇒ '
              '底部留了黑色残条（用户原话「这里应该要有游戏卡片」）');
    });

    testWidgets('默认 1280×720：右栏三块回到设计高度、文档正文零滚动',
        (WidgetTester tester) async {
      injectSites();
      await pumpHall(tester, kDefaultContent, topicCount: 10);
      expect(tester.takeException(), isNull);

      final double siteH = tester.getRect(find.byType(WebsiteSection)).height;
      final double seriesH = tester.getRect(find.byType(SeriesSection)).height;
      final double docsH = tester.getRect(find.byType(DocsSection)).height;

      expect(siteH, greaterThanOrEqualTo(124),
          reason: '站点面板 $siteH 过矮（用户原话「又矮又长、显得拥挤」）');
      expect(seriesH, greaterThanOrEqualTo(133),
          reason: '系列面板 $seriesH 过矮');
      expect(docsH, lessThanOrEqualTo(275),
          reason: '文档面板 $docsH 过高（应把高度让给上面两块）');

      for (final Element e in find
          .descendant(
              of: find.byType(DocsSection), matching: find.byType(Scrollable))
          .evaluate()) {
        final ScrollableState st =
            (e as StatefulElement).state as ScrollableState;
        expect(st.position.maxScrollExtent, 0,
            reason: '文档正文需滚动 ${st.position.maxScrollExtent}px ⇒ 介绍读不完');
      }
    });

    testWidgets('工作区被钳到 869×534（1366×768@125%）：卡片等比缩小而不是被裁',
        (WidgetTester tester) async {
      injectSites();
      await pumpHall(tester, const Size(869, 534), topicCount: 10);
      expect(tester.takeException(), isNull,
          reason: '极端小窗出现布局溢出（应整体等比缩小 + 列表填满）');
    });
  });

  group('HallCardMetrics：整卡等分', () {
    test('423.4 内宽 / 最小卡宽 132 ⇒ 3 张整卡正好等于可用宽', () {
      final HallCardMetrics m = HallCardMetrics.resolve(
        availableWidth: 423.4,
        minCardWidth: 132,
      );
      expect(m.perView, 3);
      expect(m.cardWidth * 3 + 8 * 2, closeTo(423.4, 1e-9),
          reason: '3 张卡 + 2 个间距必须精确等于可用宽，否则第 4 张会露出半截');
    });

    test('任意宽度下都不留半张卡（第 perView+1 张正好从可用宽处开始）', () {
      for (double w = 220; w <= 1200; w += 7.3) {
        final HallCardMetrics m =
            HallCardMetrics.resolve(availableWidth: w, minCardWidth: 132);
        final double used = m.cardWidth * m.perView + 8 * (m.perView - 1);
        expect(used, closeTo(w, 1e-9),
            reason: '宽度 $w 下卡片占用 $used ≠ 可用宽 ⇒ 会露半张');
        expect(m.cardWidth, greaterThanOrEqualTo(132),
            reason: '宽度 $w 下卡宽 ${m.cardWidth} 小于最小可读卡宽');
      }
    });

    test('宽度未知（infinity）时退回 1 张、宽 = 最小卡宽', () {
      final HallCardMetrics m = HallCardMetrics.resolve(
        availableWidth: double.infinity,
        minCardWidth: 132,
      );
      expect(m.perView, 1);
      expect(m.cardWidth, 132);
    });
  });

  group('hallFitRows：整行填满（行高吃余量）', () {
    test('209.3 高、最小行高 48 + 间距 4 ⇒ 4 行 × 49.325 正好填满', () {
      final HallRowsFit fit =
          hallFitRows(availableHeight: 209.3, minRowHeight: 48, gap: 4);
      expect(fit.rows, 4);
      expect(fit.rowHeight * 4 + 4 * 3, closeTo(209.3, 1e-9),
          reason: '4 行 + 3 个间距必须精确等于可用高，否则底部会空出残行');
    });

    test('任何高度都填满：行数×(行高) + 间距 == 可用高', () {
      for (double h = 100; h <= 900; h += 3.7) {
        final HallRowsFit fit =
            hallFitRows(availableHeight: h, minRowHeight: 48, gap: 4);
        final double used = fit.rowHeight * fit.rows + (fit.rows - 1) * 4;
        expect(used, closeTo(h, 1e-9),
            reason: '高度 $h 下只用了 $used ⇒ 底部会留黑边（用户看到的"黑色留白"）');
        expect(fit.rowHeight, greaterThanOrEqualTo(48),
            reason: '高度 $h 下行高 ${fit.rowHeight} 低于最小可读行高');
      }
    });

    test('旧实现的坑：可用高 260 时放 5 行填满（而不是 4 行 + 52 黑边）', () {
      final HallRowsFit fit =
          hallFitRows(availableHeight: 260, minRowHeight: 48, gap: 4);
      expect(fit.rows, 5);
      final double used = fit.rowHeight * fit.rows + (fit.rows - 1) * 4;
      expect(used, closeTo(260, 1e-9),
          reason: '旧实现固定 48 行高向下取整 ⇒ 4 行 204，底部空 56px');
      expect(fit.rowHeight, closeTo(48.8, 1e-9));
    });
  });

  group('窗口尺寸常量：设计 = 默认 = 最小 = 恢复下限', () {
    test('四个数收敛成同一个 1280×720', () {
      expect(kRequestedMinWindowWidth, kRequestedWindowWidth);
      expect(kRequestedMinWindowHeight, kRequestedWindowHeight);
      expect(kRestoreMinLogicalWidth, kRequestedWindowWidth);
      expect(kRestoreMinLogicalHeight, kRequestedWindowHeight);
      expect(kRequestedWindowWidth, 1280);
      expect(kRequestedWindowHeight, 720);
    });
  });
}
