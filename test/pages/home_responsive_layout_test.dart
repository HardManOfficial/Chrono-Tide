// 主页「窄窗被压扁」回归哨兵（RESPONSIVE-LIST）
//
// 锁死的真机现象（用户截图 960×600 逻辑分辨率，笔记本 1920×1080@125%）：
// 主页右边是固定 320 的「游戏库」列表，左边详情是按 830×640 设计画布
// 等比缩放的 FittedBox。960×600 时内容区只有 778 宽，detail 可用宽
// 778-320-32 = 426 ⇒ 缩放 min(426/830, 536/640) = 0.513，正文 14px 渲染成
// 7.2px，整页看起来「糊成一团、被挤压」。
//
// 修法：内容区容不下「830 画布 + 320 列表」时（判定见
// HomePage._useCompactLayout），列表改为右侧常驻 34px 竖条，点开后
// 独占全宽。960×600 下正文回到 11.7px。
//
// 🔴 测量口径（三个坑，改断言前务必读）：
//   ① Container(width:34) 的 RenderBox.size **含 margin**（RenderPadding）
//      ⇒ 竖条实测 44 = 本体 34 + margin(4+6)。
//   ② 缩放比不能取 find.byType(FittedBox).first —— 侧栏图标/徽章里也有
//      FittedBox，会命中 20px 小盒子算出 0.02 的假值。必须沿「画布
//      SizedBox（≥830×640）的祖先」定位，那个 FittedBox 是 Positioned.fill，
//      矩形即详情可用区，缩放比 = min(w/830, h/640)（上限 1）。
//   ③ 测试宿主要复现主壳：Column[32px 标题栏, Expanded(Row[侧栏, 内容])]，
//      且侧栏宽度必须用 LayoutBuilder 按当前高度实时算（Sidebar.widthFor）。
//      写死挂载时的侧栏宽度会让内容区窄 46px，1280×720 档误判成紧凑布局。
//
// ⚠️ HomePage.initState 会 await LocalGameRegistry.scan()（真实磁盘 IO），
//    在 flutter_tester 的 FakeAsync 下**永不完成**。所以本测试必须
//    「先挂载、后注入」：挂载进加载态，再 registerExtractionComplete 触发
//    注册表通知 → _onRegistryChanged → _loadGames() 同步填充 _allGames。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/pages/home_page.dart';
import 'package:chrono_tide/services/local_game_registry.dart';
import 'package:chrono_tide/widgets/sidebar.dart';

/// 详情面板画布 SizedBox（宽 = 可用宽 / scale，恒 ≥ 830×640）
Finder _canvasFinder() => find.byWidgetPredicate((Widget w) {
      if (w is! SizedBox) return false;
      final double? wd = w.width;
      final double? ht = w.height;
      return wd != null && ht != null && wd >= 829.0 && ht >= 639.0;
    });

/// 紧凑布局的「游戏库」竖条（本体 34 + 左右 margin 4/6 = 44）
Finder _railFinder() => find.byWidgetPredicate((Widget w) {
      if (w is! Container) return false;
      final BoxConstraints? c = w.constraints;
      return c != null && c.maxWidth == 34 && c.minWidth == 34;
    });

/// 详情内容实际缩放比（口径见文件头 ②）
double _detailScale(WidgetTester tester) {
  final Finder cv = _canvasFinder();
  if (cv.evaluate().isEmpty) return 1.0; // 空间充足，走原始布局
  final Finder fb =
      find.ancestor(of: cv.first, matching: find.byType(FittedBox)).first;
  final Rect r = tester.getRect(fb);
  final double s = (r.width / 830.0) < (r.height / 640.0)
      ? r.width / 830.0
      : r.height / 640.0;
  return s > 1.0 ? 1.0 : s;
}

/// 与 HomePage._useCompactLayout 同口径（入参是内容区尺寸）
bool _expectCompact(double contentW, double contentH) {
  const double kListWidth = 320;
  const double dw = 830;
  const double dh = 640;
  const double minScale = 0.82;
  final double detailWidth = contentW - kListWidth - 32;
  final double detailHeight = contentH - 32;
  if (detailWidth <= 0 || detailHeight <= 0) return true;
  final double s1 = detailWidth / dw;
  final double s2 = detailHeight / dh;
  return (s1 < s2 ? s1 : s2) < minScale;
}

void main() {
  late Directory appRoot;
  int seq = 0;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_home_responsive_');
    // 必须在任何 PathHelper 路径 getter / 注册表静态字段解析之前
    PathHelper.exeDirOverride = appRoot.path;
    // 预建 Games 目录：scan() 在目录缺失时会 await Directory.create(recursive)
    Directory(p.join(appRoot.path, 'Games')).createSync(recursive: true);
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 挂载主壳（复现 Column[标题栏, Row[侧栏, 内容]]），尺寸由 tester.view 决定
  Future<void> pumpShell(WidgetTester tester, Size window) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              // 复现 CustomTitleBar 的 32px 占位
              const SizedBox(height: 32),
              Expanded(
                child: LayoutBuilder(
                  builder: (BuildContext ctx, BoxConstraints outer) {
                    final double sbw = Sidebar.widthFor(
                      isCollapsed: false,
                      availableHeight: outer.maxHeight,
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          width: sbw,
                          child: Sidebar(
                            currentPage: NavPage.home,
                            onPageChanged: (_) {},
                            isCollapsed: false,
                          ),
                        ),
                        const Expanded(child: HomePage()),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 挂载后注入：靠注册表通知同步填充数据（不碰磁盘 scan）
  Future<void> seedAfterMount(WidgetTester tester, int n) async {
    final LocalGameRegistry reg = LocalGameRegistry.instance;
    for (int i = 0; i < n; i++) {
      final String title = '布局哨兵作品_${seq++}';
      reg.registerExtractionComplete(
        gameTitle: title,
        directoryPath: p.join(appRoot.path, 'Games', title),
        gameId: 'home-resp-$seq',
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('主页：窄窗改竖条后不溢出，且详情不再被压到 7px', (tester) async {
    await pumpShell(tester, const Size(1536, 864));
    await seedAfterMount(tester, 12);
    expect(tester.takeException(), isNull);

    // 数据必须真的进来了，否则后面量的是空态
    expect(
      _railFinder().evaluate().isNotEmpty ||
          find.text('游戏库').evaluate().isNotEmpty,
      isTrue,
      reason: '主页未进入有数据分支，后续几何断言无意义',
    );

    for (final Size w in <Size>[
      const Size(960, 540),
      const Size(960, 600),
      const Size(1092, 582),
      const Size(1280, 720),
      const Size(1366, 768),
      const Size(1536, 864),
      const Size(1920, 1048),
      const Size(2560, 1440),
    ]) {
      final String tag = '${w.width.toInt()}x${w.height.toInt()}';
      tester.view.physicalSize = w;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull, reason: '$tag 出现布局异常');

      final double sidebarW = Sidebar.widthFor(
        isCollapsed: false,
        availableHeight: w.height - 32,
      );
      final double contentW = w.width - sidebarW;
      final double contentH = w.height - 32;
      final bool expectCompact = _expectCompact(contentW, contentH);

      expect(
        _railFinder().evaluate().isNotEmpty,
        expectCompact,
        reason: '$tag 竖条出现与否应与 _useCompactLayout 一致',
      );
      expect(
        find.text('游戏库').evaluate().isNotEmpty,
        !expectCompact,
        reason: '$tag 并排列表只该在宽档出现',
      );

      if (expectCompact) {
        // 口径 ①：本体 34 + margin 10
        expect(tester.getSize(_railFinder()).width, closeTo(44, 1.0),
            reason: '$tag 竖条总宽');
        final Rect rr = tester.getRect(_railFinder());
        expect(rr.bottom, lessThanOrEqualTo(w.height + 0.5),
            reason: '$tag 竖条越出窗口底边');
        expect(rr.right, closeTo(w.width, 1.5),
            reason: '$tag 竖条应贴窗口右缘');
      }

      final double sc = _detailScale(tester);
      // 960×540 是最小窗口且「高度受限」（476/640=0.744），10.4px 已是上限
      expect(14 * sc, greaterThanOrEqualTo(10.0),
          reason: '$tag 正文字号 ${(14 * sc).toStringAsFixed(1)}px 过小');

      // 与旧的「详情 + 320 并排列表」逐档对照，保证只会更好不会更差
      final double o1 = (contentW - 320 - 32) / 830.0;
      final double o2 = (contentH - 32) / 640.0;
      final double oldScale = (o1 < o2 ? o1 : o2) > 1.0 ? 1.0 : (o1 < o2 ? o1 : o2);
      expect(sc, greaterThanOrEqualTo(oldScale - 0.001),
          reason: '$tag 详情比旧并排布局更小（回归）');
    }
  });

  testWidgets('主页：窄窗点竖条 → 列表独占全宽 → 可收起', (tester) async {
    await pumpShell(tester, const Size(1536, 864));
    await seedAfterMount(tester, 8);

    tester.view.physicalSize = const Size(960, 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_railFinder(), findsOneWidget);

    await tester.tap(_railFinder());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('游戏库'), findsOneWidget, reason: '点开后应显示列表标题');
    expect(_railFinder(), findsNothing, reason: '点开后列表独占全宽，竖条应消失');
    // 列表从内容区左侧开始，说明真的占满了整宽
    expect(tester.getRect(find.text('游戏库')).left, lessThan(400));

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(_railFinder(), findsOneWidget, reason: '收起后应回到竖条');
  });
}
