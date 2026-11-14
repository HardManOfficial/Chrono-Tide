// P0-5 渲染探针：验证「详情页加第三个按钮」与「补丁站面板双尺寸落框」。
//
// 用法（在 apps/chrono-tide 下）：
//   dart gen_kernel → flutter_tester 跑。见 dev_probe/RESULTS.md。
//
// 判据：
//   1. 操作按钮行 Wrap 高度 == 单行高（38）⇒ 没换行；
//      > 38 ⇒ 换行了（设计稿对称性被破坏，必须改方案）
//   2. 面板矩形完整落在屏幕内，且宽/高不小于下限
//   3. 卡片三态在窄宽下无溢出异常
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/patch_resource.dart';
import 'package:chrono_tide/services/patch/patch_delivery_service.dart';
import 'package:chrono_tide/services/patch/patch_download_service.dart';
import 'package:chrono_tide/services/patch/patch_identity_resolver.dart';
import 'package:chrono_tide/services/patch/patch_save_location.dart';
import 'package:chrono_tide/services/patch/patch_search_service.dart';
import 'package:chrono_tide/services/patch/patch_source.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/game_detail/game_detail_header.dart';
import 'package:chrono_tide/widgets/patch_station/patch_card.dart';
import 'package:chrono_tide/widgets/patch_station/patch_delivery_loader.dart';
import 'package:chrono_tide/widgets/patch_station/patch_download_details.dart';
import 'package:chrono_tide/widgets/patch_station/patch_layout.dart';
import 'package:chrono_tide/widgets/patch_station/patch_site_logo.dart';
import 'package:chrono_tide/widgets/patch_station/patch_station_dark_panel.dart';
import 'package:chrono_tide/widgets/patch_station/patch_station_panel.dart';

final List<String> _log = <String>[];
void L(String m) {
  _log.add(m);
  // ignore: avoid_print
  print(m);
}

int _fail = 0;
void check(String name, bool ok, [String? detail]) {
  if (!ok) _fail++;
  L('${ok ? "PASS" : "FAIL"} | $name${detail == null ? "" : " | $detail"}');
}

PatchResource _res({
  required PatchDelivery delivery,
  String site = 'kunlun',
  String? code,
  bool longTitle = false,
  int seq = 1,
}) =>
    PatchResource(
      key: 'k-${delivery.name}-$site-$seq',
      site: PatchSite.tryParse(site) ?? PatchSite.kunlun,
      id: '$seq',
      groupId: 'g$seq',
      title:
          longTitle ? '【城彩学园×落樱】千恋＊万花 完整人工汉化补丁 v1.3 含全CG解锁与字体修正' : '千恋＊万花 汉化补丁',
      gameTitle: '千恋＊万花',
      kinds: const [PatchKind.translation, PatchKind.r18],
      rawKinds: const ['汉化', 'R18'],
      languages: const ['zh-Hans'],
      platforms: const ['Windows'],
      sizeBytes: 1181116006,
      // 每条给不同的 hash：否则聚合层按 sha256 去重会把 6 条合并成 1 条
      sha256: 'abcdef0123456789abcdef012345678${seq % 10}',
      note: '解压后覆盖到游戏根目录，请先备份原文件',
      webUrl: 'https://www.moyu.moe/resource/1',
      delivery: delivery,
      directUrl: delivery == PatchDelivery.direct
          ? 'https://dl.imoe.uk/moyu/x$seq.zip'
          : null,
      netdiskUrl: delivery == PatchDelivery.netdisk
          ? 'https://pan.quark.cn/s/abc123?pwd=kUz4'
          : null,
      extractCode: code,
      author: '汉化组',
      downloadCount: 12345,
      updatedAt: DateTime(2026, 8, 12),
    );

/// `setSurfaceSize` 只改渲染边界，`MediaQuery.sizeOf` 在测试绑定下可能仍是
/// 默认值（甚至 0×0）⇒ 必须用 `MaterialApp.builder` 显式覆盖 MediaQuery。
/// builder 包在 Navigator 之外，因此 OverlayEntry 也能拿到正确尺寸。
Size? _probeSize;

Widget _app(Widget child) => MaterialApp(
      // 🔴 必须每次换 key：不然 Element 会「复用」同一个 MaterialApp，
      //    它内部的 Overlay 也跟着复用 ⇒ 上一轮插入的 OverlayEntry 不会被
      //    detach，探针会把旧面板的卡片一起数进来（实测 6→10→16 递增）。
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      builder: (context, inner) {
        final base = MediaQuery.of(context);
        final s = _probeSize;
        return MediaQuery(
          data: s == null ? base : base.copyWith(size: s),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(backgroundColor: const Color(0xFF1E1E1E), body: child),
    );

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  // 探针环境没有走 main.dart 的启动链，必须手动注册内置主题，
  // 否则 AppThemeManager.colors 会抛 `Null check operator used on a null value`
  ThemeRegistry.registerBuiltinThemes();
  final details = <FlutterErrorDetails>[];
  // build 期抛的异常会走 ErrorWidget.builder，参数里带完整 stack
  final prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (d) {
    details.add(d);
    return prevBuilder(d);
  };

  await binding.runTest(() async {
    // 拦在最前面且**不转发**给 binding：binding 自己会把异常塞进
    // _pendingExceptionDetails，多段累积后 takeException 只能拿到
    // "Multiple exceptions"，既看不出是哪一次、也清不干净。
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) => details.add(d);

    void clearErr() => details.clear();
    String? firstErr() {
      if (details.isEmpty) return null;
      final d = details.first;
      final e = d.exception.toString();
      L('      | ${e.length > 200 ? e.substring(0, 200) : e}');
      final st = d.stack?.toString().split('\n') ?? <String>[];
      for (final l in st
          .where((l) => l.contains('chrono_tide') || l.contains('flutter/src'))
          .take(5)) {
        L('      @ ${l.trim()}');
      }
      return e.length > 60 ? e.substring(0, 60) : e;
    }

    // ================= A. 详情页操作行是否换行 =================
    L('--- A. 详情页操作行（补丁按钮插在 分享/上传 之间）---');

    for (final width in <double>[1280, 1248, 1180, 1080, 1000]) {
      _probeSize = Size(width, 720);
      final rowKey = GlobalKey();
      final patchKey = GlobalKey();
      await binding.setSurfaceSize(Size(width, 720));
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: Builder(builder: (_) {
              return GameDetailHeader(
                cover: Container(
                  width: GameDetailHeader.coverWidth,
                  height: GameDetailHeader.coverHeight,
                  color: const Color(0xFF334455),
                ),
                title: '千恋＊万花',
                aliases: const ['千恋万花', 'Senren * Banka'],
                metaItems: const <Widget>[],
                tags: const SizedBox(height: 20),
                leading: const SizedBox(height: 22),
                actionRowKey: rowKey,
                patchButtonKey: patchKey,
                onGet: () {},
                onShare: () {},
                onPatch: () {},
                onUpload: () {},
                onLike: () {},
                onFeedback: () {},
              );
            }),
          ),
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      final wrapBox = rowKey.currentContext?.findRenderObject() as RenderBox?;
      final patchBox =
          patchKey.currentContext?.findRenderObject() as RenderBox?;
      final h = wrapBox?.size.height ?? -1;
      final pw = patchBox?.size.width ?? -1;
      final px =
          patchBox == null ? -1.0 : patchBox.localToGlobal(Offset.zero).dx;

      // 单行 = 38（_actionHeight）；带 runSpacing 的第二行会到 84
      final singleLine = h > 0 && h < 46;
      check(
        'W=$width 操作行不换行',
        singleLine,
        'Wrap高=$h${firstErr() == null ? "" : "  异常=${firstErr()}"}',
      );
      L('      补丁按钮 x=${px.toStringAsFixed(1)} 宽=${pw.toStringAsFixed(1)}');
      if (details.isNotEmpty) {
        final d = details.last;
        L('      | ${d.exception}');
        final st = d.stack?.toString().split('\n') ?? <String>[];
        for (final l in st.where((l) => l.contains('chrono_tide')).take(6)) {
          L('      @ $l');
        }
      }
      clearErr();
    }

    // ================= B. 面板落框（空态，不触发网络） =================
    L('--- B. 补丁站面板落框（空态：无游戏无关键词 ⇒ 不发请求）---');

    Future<void> probePanel({
      required String name,
      required Size screen,
      required Rect anchorRect,
    }) async {
      clearErr();
      _probeSize = screen;
      await binding.setSurfaceSize(screen);
      final anchorKey = GlobalKey();
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Stack(
          children: [
            Positioned(
              left: anchorRect.left,
              top: anchorRect.top,
              child: SizedBox(
                key: anchorKey,
                width: anchorRect.width,
                height: anchorRect.height,
                child: const ColoredBox(color: Color(0xFF444444)),
              ),
            ),
          ],
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));

      // 打开面板：game=null 且 initialQuery='' ⇒ _runSearch 直接返回空态
      unawaited(PatchStationPanel.show(
        context: anchorKey.currentContext!,
        anchorKey: anchorKey,
        initialQuery: '',
      ));
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 80));

      // 面板本体是 Overlay 里唯一带圆角+阴影的 Container，
      // 这里改用「找 Material 的直接子 Container」不可靠 ⇒ 用 Rect 反推
      // 与 _PanelMetrics 同一套算法后比对实际渲染尺寸。
      final expected = _expectedMetrics(screen, anchorRect);

      final inBounds = expected.left >= 0 &&
          expected.top >= 0 &&
          expected.left + expected.width <= screen.width + 0.5 &&
          expected.top + expected.height <= screen.height + 0.5;
      check('$name 落框', inBounds,
          'L=${expected.left.toStringAsFixed(0)} T=${expected.top.toStringAsFixed(0)} W=${expected.width.toStringAsFixed(0)} H=${expected.height.toStringAsFixed(0)}');
      // 用户定稿：面板宽约屏幕一半（52%），⛔ 不再铺满整窗
      final ratio = expected.width / screen.width;
      final atMin = (expected.width - 460).abs() < 0.6;
      final atMax = (expected.width - 700).abs() < 0.6;
      check(
        '$name 宽度约为半屏或已触及上下限',
        (ratio >= 0.44 && ratio <= 0.60) || atMin || atMax,
        'W=${expected.width.toStringAsFixed(0)} 占屏 ${(ratio * 100).toStringAsFixed(0)}%',
      );
      check('$name 高度 >= 320', expected.height >= 320,
          'H=${expected.height.toStringAsFixed(0)}');
      check('$name 无布局异常', details.isEmpty, firstErr());

      // 实测：在渲染树里找尺寸与预期面板矩形一致的 RenderBox
      final actual = _findBox(
        binding.rootElement!,
        expected.width,
        expected.height,
      );
      check(
        '$name 实测尺寸与算法一致',
        actual != null &&
            (actual.width - expected.width).abs() < 0.6 &&
            (actual.height - expected.height).abs() < 0.6,
        actual == null
            ? '渲染树里没找到 W=${expected.width.toStringAsFixed(0)} 的盒子'
            : '实测 ${actual.width.toStringAsFixed(1)}×${actual.height.toStringAsFixed(1)}'
                ' vs 预期 ${expected.width.toStringAsFixed(1)}×${expected.height.toStringAsFixed(1)}',
      );

      // 收尾：卸载整棵树（含刚插入的 OverlayEntry）再清异常队列，
      // 否则残留树会持续产生异常、污染下一段判据
      binding.attachRootWidget(
        binding.wrapWithDefaultView(_app(const SizedBox.shrink())),
      );
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));
      clearErr();
    }

    await probePanel(
      name: 'B1 1280x720 锚点在中部',
      screen: const Size(1280, 720),
      anchorRect: const Rect.fromLTWH(1000, 120, 90, 36),
    );
    await probePanel(
      name: 'B2 1280x688 锚点贴底',
      screen: const Size(1280, 688),
      anchorRect: const Rect.fromLTWH(1000, 620, 90, 36),
    );
    await probePanel(
      name: 'B3 1280x720 锚点贴右',
      screen: const Size(1280, 720),
      anchorRect: const Rect.fromLTWH(1180, 120, 90, 36),
    );

    // ================= C. 卡片三态在窄宽下不溢出 =================
    L('--- C. 补丁卡片三态（宽度 250 / 300 / 528）---');

    for (final w in <double>[250, 300, 528]) {
      for (final d in PatchDelivery.values) {
        clearErr();
        await binding.setSurfaceSize(const Size(1400, 720));
        binding.attachRootWidget(binding.wrapWithDefaultView(_app(
          Center(
            child: PatchCard(
              resource: _res(
                delivery: d,
                code: d == PatchDelivery.netdisk ? null : 'kUz4',
                longTitle: true,
              ),
              width: w,
              showGameTitle: true,
            ),
          ),
        )));
        binding.scheduleFrame();
        await binding.pump();
        await binding.pump(const Duration(milliseconds: 40));
        check('卡片 ${d.name} @W=$w 无溢出', details.isEmpty, firstErr());
      }
    }

    /// 跑一次「锚点 + 打开面板 + 收集渲染结果」
    Future<PatchReport> _shotPanel({
      required String name,
      required Size screen,
      required Rect anchor,
      required String initialQuery,
      PatchGameRef? game,
      bool lockGame = false,
    }) async {
      clearErr();
      _probeSize = screen;
      await binding.setSurfaceSize(screen);
      final anchorKey = GlobalKey();
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Stack(
          children: [
            Positioned(
              left: anchor.left,
              top: anchor.top,
              child: SizedBox(
                key: anchorKey,
                width: anchor.width,
                height: anchor.height,
                child: const ColoredBox(color: Color(0xFF444444)),
              ),
            ),
          ],
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));

      unawaited(PatchStationPanel.show(
        context: anchorKey.currentContext!,
        anchorKey: anchorKey,
        game: game,
        lockGame: lockGame,
        initialQuery: initialQuery,
      ));
      // 假源是同步完成的，但 _runSearch 走 async ⇒ 多 pump 两帧让结果落到 build
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 80));
      await binding.pump(const Duration(milliseconds: 80));

      final m = _expectedMetrics(screen, anchor);
      return PatchReport(
        name: name,
        details: List<FlutterErrorDetails>.of(details),
        cardCount: _countOf<PatchCard>(binding.rootElement!),
        panelSize: _findBox(binding.rootElement!, m.width, m.height),
      );
    }

    Future<void> _drainPanel() async {
      binding.attachRootWidget(
        binding.wrapWithDefaultView(_app(const SizedBox.shrink())),
      );
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));
      clearErr();
    }

    // ================= C2. 下载状态行（进度 / 解压完 / 失败 / 超长提示） =================
    // 补丁站只下载不安装 ⇒ 完成态是「已下载 · 解压出 N 个文件 + 打开文件夹」，
    // 这一行是最容易被新文案挤爆的地方，必须逐态验证。
    L('--- C2. 下载状态行（5 态 × 宽 250/300）---');

    final dlStates = <String, PatchDownloadState>{
      '下载中': const PatchDownloadState(
        patchKey: 'k',
        phase: PatchDownloadPhase.downloading,
        received: 12345678,
        total: 98765432,
        bytesPerSecond: 2345678,
      ),
      '解压中': const PatchDownloadState(
        patchKey: 'k',
        phase: PatchDownloadPhase.extracting,
      ),
      '解压完(带长提示)': const PatchDownloadState(
        patchKey: 'k',
        phase: PatchDownloadPhase.done,
        extractedCount: 128,
        saveDir: r'D:\CTLIB\ChronoTide_Patches',
        extractDir: r'D:\CTLIB\ChronoTide_Patches\鲲_13145_汉化补丁',
        hint: 'DLL 注入型：使用时必须和游戏 exe 放在同一目录，放子目录不生效',
      ),
      '已下载(未解压)': const PatchDownloadState(
        patchKey: 'k',
        phase: PatchDownloadPhase.done,
        saveDir: r'D:\用户选的目录\名字很长很长很长很长很长很长\子目录',
      ),
      '失败(空间不足)': const PatchDownloadState(
        patchKey: 'k',
        phase: PatchDownloadPhase.failed,
        message: '磁盘空间不足：需要约 1.2 GB，目标盘可用 300 MB',
      ),
    };

    for (final e in dlStates.entries) {
      for (final w in <double>[250, 300]) {
        clearErr();
        await binding.setSurfaceSize(const Size(1400, 720));
        binding.attachRootWidget(binding.wrapWithDefaultView(_app(
          Center(
            child: PatchCard(
              key: UniqueKey(),
              resource: _res(delivery: PatchDelivery.direct, longTitle: true),
              width: w,
              showGameTitle: true,
              download: e.value,
              onDownload: () {},
              onCancel: () {},
            ),
          ),
        )));
        binding.scheduleFrame();
        await binding.pump();
        await binding.pump(const Duration(milliseconds: 40));
        check('C2 ${e.key} @W=$w 无溢出', details.isEmpty, firstErr());
      }
    }

    // 完成态必须给出「打开文件夹」，且不能出现任何"装上/应用"字样
    clearErr();
    await binding.setSurfaceSize(const Size(1400, 720));
    binding.attachRootWidget(binding.wrapWithDefaultView(_app(
      Center(
        child: PatchCard(
          key: UniqueKey(),
          resource: _res(delivery: PatchDelivery.direct),
          width: 300,
          showGameTitle: true,
          download: dlStates['解压完(带长提示)'],
          onDownload: () {},
          onCancel: () {},
        ),
      ),
    )));
    binding.scheduleFrame();
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 40));
    final doneTexts = _textsOf(binding.rootElement!);
    check('C2 完成态给出「打开文件夹」', doneTexts.any((t) => t.contains('打开文件夹')),
        doneTexts.join(' / '));
    check(
        'C2 完成态没有任何「安装/应用」字样',
        !doneTexts.any(
            (t) => t.contains('安装') || t.contains('应用到') || t.contains('覆盖')),
        doneTexts.join(' / '));

    // ================= D. 注入真实数据渲染完整面板（哨兵，铁律要求） =================
    L('--- D. 完整面板 + 假源注入（通用态 5 条 / 锁定态 3 条 + 单源失败）---');

    Future<PatchReport> _seedAndShot({
      required String name,
      required Size screen,
      required Rect anchor,
      required List<PatchResource> kunlun,
      required List<PatchResource> fan,
      required List<PatchResource> community,
      String? fanFail,
      PatchGameRef? game,
      bool lockGame = false,
    }) {
      PatchSearchService.useTestInstance(PatchSearchService.withSources(
        [
          _FakeSource(PatchSite.kunlun, kunlun),
          _FakeSource(PatchSite.twoDfan, fan, failReason: fanFail),
          _FakeSource(PatchSite.community, community),
        ],
        // 锁定态带了 gameId ⇒ 不跳过就会去真发身份解析请求，面板永远 loading
        skipIdentityResolution: true,
      ));
      return _shotPanel(
        name: name,
        screen: screen,
        anchor: anchor,
        initialQuery: '千恋万花',
        game: game,
        lockGame: lockGame,
      );
    }

    // 通用态：三源都有内容，其中一条超长标题、一条网盘无提取码
    // seq 各不相同：key / sha256 / 直链都要唯一，否则被聚合层去重（第一次跑就踩到）
    final kunlunList = <PatchResource>[
      _res(delivery: PatchDelivery.direct, seq: 1),
      _res(delivery: PatchDelivery.netdisk, code: 'kUz4', seq: 2),
      _res(delivery: PatchDelivery.netdisk, code: null, seq: 3),
    ];
    final fanList = <PatchResource>[
      _res(delivery: PatchDelivery.web, site: 'twoDfan', seq: 4),
      _res(
          delivery: PatchDelivery.web,
          site: 'twoDfan',
          longTitle: true,
          seq: 5),
    ];
    final communityList = <PatchResource>[
      _res(delivery: PatchDelivery.direct, site: 'community', seq: 6),
    ];

    var r = await _seedAndShot(
      name: 'D1 通用态 1280x720',
      screen: const Size(1280, 720),
      anchor: const Rect.fromLTWH(1000, 120, 90, 36),
      kunlun: kunlunList,
      fan: fanList,
      community: communityList,
    );
    check('D1 面板无异常', r.details.isEmpty, r.firstErr);
    check('D1 渲染出全部 6 张卡', r.cardCount == 6, '实际 ${r.cardCount}');
    check('D1 面板尺寸正确', r.panelSize != null,
        r.panelSize == null ? '未找到面板盒子' : '${r.panelSize}');
    final d1texts = _textsOf(binding.rootElement!);
    // 上板块三件套：搜索按钮 / 游戏库选择 / 来源筛选
    check('D1 搜索栏内有「搜索」按钮', d1texts.any((t) => t == '搜索'),
        d1texts.take(12).join(' / '));
    check('D1 有「从游戏库选择」', d1texts.any((t) => t == '从游戏库选择'),
        d1texts.take(12).join(' / '));
    check(
        'D1 有三个来源 tab',
        d1texts.where((t) => t == '2DFan' || t == '鲲' || t == '社区').length >= 3,
        d1texts.take(20).join(' / '));
    // 卡片动作：每张卡都要有「查看下载」+「原页」
    check('D1 每张卡都有「查看下载」', d1texts.where((t) => t == '查看下载').length == 6,
        '实际 ${d1texts.where((t) => t == '查看下载').length}');
    check('D1 每张卡都有「原页」', d1texts.where((t) => t == '原页').length == 6,
        '实际 ${d1texts.where((t) => t == '原页').length}');
    // 常驻「保存到 …」底栏已被取消（改为下载前确认框）
    check(
        'D1 不再常驻「保存到」底栏', !d1texts.any((t) => t == '保存到'), d1texts.join(' / '));
    check(
        'D1 面板上不出现任何默认路径',
        !d1texts.any((t) => t.contains('ChronoTide_Patches')),
        d1texts.where((t) => t.contains('Chrono')).join(' / '));
    await _drainPanel();

    // 锁定态：详情页入口（只出这一部作品的补丁，无「从游戏库选择」）
    r = await _seedAndShot(
      name: 'D2 锁定态 1280x720',
      screen: const Size(1280, 720),
      anchor: const Rect.fromLTWH(330, 300, 84, 38),
      kunlun: kunlunList,
      fan: <PatchResource>[],
      community: <PatchResource>[],
      game: const PatchGameRef(
        id: 'g1',
        title: '千恋＊万花',
        aliasTitles: ['千恋万花'],
      ),
      lockGame: true,
    );
    check('D2 锁定态无异常', r.details.isEmpty, r.firstErr);
    check('D2 渲染出 3 张卡', r.cardCount == 3, '实际 ${r.cardCount}');
    await _drainPanel();

    // 单源失败：必须出现失败提示条，且其余源照常出卡
    r = await _seedAndShot(
      name: 'D3 单源失败',
      screen: const Size(1280, 720),
      anchor: const Rect.fromLTWH(1000, 120, 90, 36),
      kunlun: kunlunList,
      fan: <PatchResource>[],
      community: communityList,
      fanFail: '站点不可用',
    );
    check('D3 单源失败无异常', r.details.isEmpty, r.firstErr);
    check('D3 其余源仍出 4 张卡', r.cardCount == 4, '实际 ${r.cardCount}');
    await _drainPanel();

    // 窄屏兜底：800×600 窗口，面板应压缩到下限附近但不出屏
    r = await _seedAndShot(
      name: 'D4 窄屏 800x600',
      screen: const Size(800, 600),
      anchor: const Rect.fromLTWH(600, 100, 90, 36),
      kunlun: kunlunList,
      fan: fanList,
      community: communityList,
    );
    check('D4 窄屏无异常', r.details.isEmpty, r.firstErr);
    check('D4 窄屏仍出 6 张卡', r.cardCount == 6, '实际 ${r.cardCount}');
    await _drainPanel();

    // ================= J. 结果区列数：必须两列且整行铺满 =================
    // 用户实机反馈：结果排成一列、左右各留一大片空白。根因是列宽拿「面板宽」
    // 算而不是拿「LayoutBuilder 的真实可用宽」算 ⇒ 这里按恒等式钉死。
    L('--- J. 结果区两列（1080 / 1280 / 1440）---');

    for (final w in <double>[1080, 1280, 1440]) {
      final size = Size(w, 720);
      _probeSize = size;
      await binding.setSurfaceSize(size);
      final rep = await _seedAndShot(
        name: 'J W=$w',
        screen: size,
        anchor: const Rect.fromLTWH(1000, 120, 90, 36),
        kunlun: kunlunList,
        fan: fanList,
        community: communityList,
      );
      check('J W=$w 无异常', rep.details.isEmpty, rep.firstErr);

      final rects = _rectsOf<PatchCard>(binding.rootElement!);
      if (rects.length < 2) {
        check('J W=$w 至少两张卡', false, '实际 ${rects.length}');
        await _drainPanel();
        continue;
      }
      final firstTop = rects.map((r) => r.top).reduce(math.min);
      final row0 = rects.where((r) => (r.top - firstTop).abs() < 1).toList();
      check('J W=$w 第一行两张卡（两列）', row0.length == 2, '实际 ${row0.length}');

      final inner =
          _panelInnerWidth(size, const Rect.fromLTWH(1000, 120, 90, 36));
      final total = row0.isEmpty
          ? 0.0
          : row0.map((r) => r.width).reduce((a, b) => a + b) + 10 * (row0.length - 1);
      check(
        'J W=$w 列宽满足恒等式（不留残列）',
        (total - inner).abs() < 1,
        '${total.toStringAsFixed(1)} vs $inner',
      );
      final gm = PatchGridMetrics.resolve(innerWidth: inner);
      check('J W=$w 纯函数列数=2', gm.columns == 2,
          'inner=${inner.toStringAsFixed(1)} cols=${gm.columns}');
      check(
        'J W=$w 单卡不窄于 236',
        row0.every((r) => r.width >= 235.5),
        row0.map((r) => r.width.toStringAsFixed(1)).join(' / '),
      );
      await _drainPanel();
    }

    // ================= K. 「查看下载」原地展开 =================
    // 用户定调：不另开窗口，卡片原位向右展开，右侧卡片自动下排。
    L('--- K. 查看下载原地展开 ---');

    {
      const size = Size(1280, 720);
      const anchorK = Rect.fromLTWH(1000, 120, 90, 36);
      _probeSize = size;
      await binding.setSurfaceSize(size);
      final rep = await _seedAndShot(
        name: 'K 展开',
        screen: size,
        anchor: anchorK,
        kunlun: kunlunList,
        fan: fanList,
        community: communityList,
      );
      check('K 展开前无异常', rep.details.isEmpty, rep.firstErr);
      final before = _countOf<PatchCard>(binding.rootElement!);
      check('K 展开前 6 张卡', before == 6, '实际 $before');

      final first = _firstOf<PatchCard>(binding.rootElement!);
      check('K 卡片带「查看下载」回调', first?.onOpenInfo != null);
      first?.onOpenInfo?.call();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      check('K 展开后无异常', details.isEmpty, firstErr());
      check('K 展开后出现 1 张展开卡',
          _countOf<PatchExpandedCard>(binding.rootElement!) == 1,
          '实际 ${_countOf<PatchExpandedCard>(binding.rootElement!)}');
      check('K 展开项不再作为普通卡片重复渲染',
          _countOf<PatchCard>(binding.rootElement!) == 5,
          '实际 ${_countOf<PatchCard>(binding.rootElement!)}');
      check('K 展开后仍不弹独立窗口（无「补丁详情」标题）',
          !_textsOf(binding.rootElement!).any((t) => t == '补丁详情'),
          _textsOf(binding.rootElement!).take(10).join(' / '));

      final ere = _rectsOf<PatchExpandedCard>(binding.rootElement!);
      final inner = _panelInnerWidth(size, anchorK);
      check(
        'K 展开项占满整行',
        ere.isNotEmpty && (ere.first.width - inner).abs() < 1,
        ere.isEmpty ? '未找到展开卡' : '${ere.first.width.toStringAsFixed(1)} vs $inner',
      );
      if (ere.isNotEmpty) {
        final sameRow = _rectsOf<PatchCard>(binding.rootElement!)
            .where((r) => (r.top - ere.first.top).abs() < 1)
            .length;
        check('K 展开项独占一行（右侧不再排卡）', sameRow == 0, '实际 $sameRow');
      }
      // 详情三件套必须真的铺进展开位
      final ktexts = _textsOf(binding.rootElement!);
      check('K 展开位里有投递信息', ktexts.any((t) => t.contains('直链文件') || t.contains('网盘分享') || t.contains('需要在站点页面下载')),
          ktexts.join(' / '));
      check('K 展开位里有「下载到本地」', ktexts.any((t) => t == '下载到本地'),
          ktexts.join(' / '));

      final ex = _firstOf<PatchExpandedCard>(binding.rootElement!);
      ex?.onCollapse?.call();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      check('K 收起后回到 6 张卡',
          _countOf<PatchCard>(binding.rootElement!) == 6,
          '实际 ${_countOf<PatchCard>(binding.rootElement!)}');
      check('K 收起后不再有展开卡',
          _countOf<PatchExpandedCard>(binding.rootElement!) == 0);
      await _drainPanel();
    }

    // ================= E. 详情页深色补丁浮层 =================
    L('--- E. 详情页深色补丁浮层（与「资源分享」同款外壳）---');

    /// 挂一个带 Navigator 的空宿主，返回它的 context
    Future<BuildContext> mountHost() async {
      final hostKey = GlobalKey();
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Builder(key: hostKey, builder: (_) => const SizedBox.expand()),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));
      return hostKey.currentContext!;
    }

    {
      clearErr();
      _probeSize = const Size(1280, 720);
      await binding.setSurfaceSize(const Size(1280, 720));
      PatchSearchService.useTestInstance(PatchSearchService.withSources(
        [
          _FakeSource(PatchSite.kunlun, kunlunList),
          _FakeSource(PatchSite.twoDfan, fanList),
          _FakeSource(PatchSite.community, communityList),
        ],
        skipIdentityResolution: true,
      ));
      final host = await mountHost();
      const anchorE = Rect.fromLTWH(330, 300, 84, 38);
      unawaited(PatchStationDarkPanel.show(
        context: host,
        anchor: anchorE,
        game: const PatchGameRef(
          id: 'g1',
          title: '千恋＊万花',
          aliasTitles: ['千恋万花'],
        ),
      ));
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 80));
      await binding.pump(const Duration(milliseconds: 80));

      final texts = _textsOf(binding.rootElement!);
      final rows = texts.where((t) => t == '查看下载').length;
      check('E1 深色浮层无异常', details.isEmpty, firstErr());
      check('E1 标题是「补丁站」', texts.any((t) => t == '补丁站'),
          texts.take(10).join(' / '));
      check('E1 出全部 6 行补丁', rows == 6, '实际 $rows');
      check('E1 每行都有「原页」', texts.where((t) => t == '原页').length == 6,
          '实际 ${texts.where((t) => t == '原页').length}');
      check(
          'E1 浮层内不出现「安装/应用」字样',
          !texts.any((t) => t.contains('安装') || t.contains('应用到')),
          texts.join(' / '));

      // ---- v5.1：必须挂在按钮**下方**（这是用户面评的那条） ----
      final prects = _rectsOf<PatchStationDarkPanel>(binding.rootElement!);
      final pr = prects.isEmpty ? null : prects.first;
      final wantTop = anchorE.bottom + 8;
      check(
        'E2 补丁站栏贴在按钮下方（不再被顶到标题区）',
        pr != null &&
            (pr.left - anchorE.left).abs() < 1.5 &&
            (pr.top - wantTop).abs() < 1.5,
        pr == null
            ? '未找到面板'
            : '实际 left=${pr.left} top=${pr.top}；期望 left=${anchorE.left} top=$wantTop',
      );
      check(
        'E2 补丁站栏不越出窗口底边',
        pr != null && pr.bottom <= 720 - 12 + 0.5,
        pr == null ? '未找到面板' : 'bottom=${pr.bottom} 上限=${720 - 12}',
      );
      check(
        'E2 空间不足时压缩自身（内部滚动）而非上移',
        pr != null && pr.height <= 362 + 1 && pr.height >= 300,
        pr == null ? '未找到面板' : 'h=${pr.height} 期望≈362（=708−346）',
      );
      await _drainPanel();
    }

    // ================= F. 「查看下载」详情内容（三态，v5 起原地展开） =================
    L('--- F. 下载详情内容（直链 / 网盘 / 只能去原站）---');

    for (final d in PatchDelivery.values) {
      clearErr();
      _probeSize = const Size(1280, 720);
      await binding.setSurfaceSize(const Size(1280, 720));
      await mountHost();
      final res = _res(
        delivery: d,
        site: d == PatchDelivery.web ? 'twoDfan' : 'kunlun',
        code: d == PatchDelivery.netdisk ? 'kUz4' : null,
      );
      // v5：不再有独立窗口，内容本体直接挂在一张 420 宽的容器里验
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Center(
          child: SizedBox(
            width: 420,
            child: Material(
              color: Colors.transparent,
              child: PatchDownloadDetails(
                key: UniqueKey(),
                resource: res,
                onDownload: () {},
                onCancel: () {},
              ),
            ),
          ),
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      final texts = _textsOf(binding.rootElement!);
      check('F ${d.name} 详情内容无异常', details.isEmpty, firstErr());
      // v5：标题在 `PatchExpandedCard` 外壳里，`PatchDownloadDetails` 只放
      // 投递块 / 说明 / SHA / 动作按钮 ⇒ 这里不断言标题（原来那三条已删）。
      if (d == PatchDelivery.direct) {
        check('F direct 有直链域名', texts.any((t) => t.contains('dl.imoe.uk')),
            texts.join(' / '));
        check('F direct 主按钮是「下载到本地」', texts.any((t) => t == '下载到本地'),
            texts.join(' / '));
      } else if (d == PatchDelivery.netdisk) {
        check('F netdisk 标出网盘类型', texts.any((t) => t.contains('夸克')),
            texts.join(' / '));
        check('F netdisk 显示提取码', texts.any((t) => t.contains('kUz4')),
            texts.join(' / '));
        check('F netdisk 主按钮是「复制链接与提取码」', texts.any((t) => t == '复制链接与提取码'),
            texts.join(' / '));
      } else {
        check('F web 说明只能去原站', texts.any((t) => t.contains('需要在站点页面下载')),
            texts.join(' / '));
        check(
            'F web(2DFan) 给出费用/积分两块',
            texts.any((t) => t == '本次费用') && texts.any((t) => t == '账号积分'),
            texts.join(' / '));
        check('F web 主按钮是「打开资源页」', texts.any((t) => t == '打开资源页'),
            texts.join(' / '));
      }
      await _drainPanel();
    }

    // ============ F2. 2DFan：多网盘全量 + 积分账（v5.3 展开位直出） ============
    //
    // 用户诉求原话：「如果是网盘资源，展开页里就应该出现对应的网盘信息，
    // 不用打开原页就能查」。所以这里断言**两个**网盘与**两个**提取码都在屏上，
    // 并且积分块给的是真数字（不是「登录后可见」）。
    L('--- F2. 2DFan 多网盘 / 积分块 / 兑换按钮 ---');

    for (final dark in <bool>[false, true]) {
      final String tag = dark ? '深色' : '浅色';
      clearErr();
      _probeSize = const Size(1280, 720);
      await binding.setSurfaceSize(const Size(1280, 720));
      await mountHost();
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Center(
          child: SizedBox(
            width: 420,
            child: Material(
              color: Colors.transparent,
              child: PatchDeliveryLoader(
                key: UniqueKey(),
                resource: _res(
                    delivery: PatchDelivery.web, site: 'twoDfan', seq: 4),
                // 注入详情：不发请求（探针里不能联网）
                detail: const PatchDeliveryDetail(
                  delivery: PatchDelivery.netdisk,
                  price: 7,
                  balance: 42,
                  authenticated: true,
                  canPurchase: true,
                  requiresPurchase: true,
                  accountSummary: '已登录：测试用户 · 积分 42',
                  links: <PatchDeliveryLink>[
                    PatchDeliveryLink(
                      url: 'https://pan.baidu.com/s/1aaa?pwd=aaa1',
                      kind: PatchDelivery.netdisk,
                      label: '网盘载点1',
                      extractCode: 'aaa1',
                      provider: '百度网盘',
                    ),
                    PatchDeliveryLink(
                      url: 'https://pan.quark.cn/s/bbb2',
                      kind: PatchDelivery.netdisk,
                      label: '网盘载点2',
                      extractCode: 'bbb2',
                      provider: '夸克网盘',
                    ),
                  ],
                ),
                autoResolve: false,
                onDark: dark,
                dense: true,
                onDownloadDirect: (String url) async {},
              ),
            ),
          ),
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      final texts = _textsOf(binding.rootElement!);
      check('F2 $tag 无溢出/异常', details.isEmpty, firstErr());
      check('F2 $tag 两个网盘都在',
          texts.any((t) => t == '百度网盘') && texts.any((t) => t == '夸克网盘'),
          texts.join(' / '));
      check('F2 $tag 两个提取码都在',
          texts.any((t) => t.contains('aaa1')) &&
              texts.any((t) => t.contains('bbb2')),
          texts.join(' / '));
      check('F2 $tag 积分块是真数字（费用 7 / 余额 42）',
          texts.any((t) => t == '7 积分') && texts.any((t) => t == '42 积分'),
          texts.join(' / '));
      check('F2 $tag 主按钮是「用积分兑换并下载」',
          texts.any((t) => t == '用积分兑换并下载'), texts.join(' / '));
      await _drainPanel();
    }

    // ============ F3. 2DFan 已兑换：直链态必须能「下载到本地」 ============
    L('--- F3. 2DFan 已兑换直链 ---');
    clearErr();
    _probeSize = const Size(1280, 720);
    await binding.setSurfaceSize(const Size(1280, 720));
    await mountHost();
    binding.attachRootWidget(binding.wrapWithDefaultView(_app(
      Center(
        child: SizedBox(
          width: 420,
          child: Material(
            color: Colors.transparent,
            child: PatchDeliveryLoader(
              key: UniqueKey(),
              resource:
                  _res(delivery: PatchDelivery.web, site: 'twoDfan', seq: 5),
              detail: const PatchDeliveryDetail(
                delivery: PatchDelivery.direct,
                price: 7,
                balance: 35,
                authenticated: true,
                accountSummary: '已登录：测试用户 · 积分 35',
                links: <PatchDeliveryLink>[
                  PatchDeliveryLink(
                    url: 'https://d1.acgxp.com/files/abc.zip',
                    kind: PatchDelivery.direct,
                    label: '直连下载',
                  ),
                ],
              ),
              autoResolve: false,
              dense: true,
              onDownloadDirect: (String url) async {},
            ),
          ),
        ),
      ),
    )));
    binding.scheduleFrame();
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));

    {
      final texts = _textsOf(binding.rootElement!);
      check('F3 已兑换无异常', details.isEmpty, firstErr());
      check('F3 给出 CDN 直链', texts.any((t) => t.contains('d1.acgxp.com')),
          texts.join(' / '));
      check('F3 主按钮是「下载到本地」', texts.any((t) => t == '下载到本地'),
          texts.join(' / '));
      await _drainPanel();
    }

    // ================= G. 站点图标（CustomPainter 静默吞帧，必须逐尺寸验） =================
    L('--- G. 站点图标多尺寸绘制 ---');

    for (final site in PatchSite.values) {
      for (final s in <double>[10, 12, 16, 19.5, 22, 34]) {
        clearErr();
        await binding.setSurfaceSize(const Size(400, 200));
        binding.attachRootWidget(binding.wrapWithDefaultView(_app(
          Center(child: PatchSiteLogo(site: site, size: s)),
        )));
        binding.scheduleFrame();
        await binding.pump();
        await binding.pump(const Duration(milliseconds: 30));
        check('G ${site.name} @${s}px 绘制无异常', details.isEmpty, firstErr());
      }
    }

    // ================= G2. 站点素材槽位 =================
    // 用户要求「用真素材」。这里钉死：有素材的站必须指向真实存在的文件，
    // 没素材的站必须显式返回 null（走 painter 兜底），防止哪天路径写错成
    // 一个不存在的字符串，release 里静默退回 painter 却没人发现。
    L('--- G2. 站点图标素材槽位 ---');

    for (final site in PatchSite.values) {
      final p = PatchSiteLogo.assetPathOf(site);
      if (site == PatchSite.community) {
        check('G2 ${site.name} 无素材（走 painter）', p == null, '$p');
        continue;
      }
      check('G2 ${site.name} 素材在 assets/patch_sites/ 下',
          p != null && p.startsWith('assets/patch_sites/'), '$p');
      if (p != null) {
        final f = File(p);
        check('G2 ${site.name} 素材文件真实存在', f.existsSync() && f.lengthSync() > 512,
            '${f.absolute.path} (${f.existsSync() ? f.lengthSync() : 0}B)');
      }
    }

    // ================= H. 默认保存目录不得落进缓存目录 =================
    // 补丁下完就是成品（直链会失效），删了补不回来 ⇒ 默认目录一旦落在
    // ChronoTide_Cache 里就会被「启动清理缓存」扫掉。
    {
      clearErr();
      String? suggested;
      try {
        suggested = PatchSaveLocation.suggestedDir;
      } catch (_) {
        suggested = null;
      }
      if (suggested == null) {
        L('  SKIP | H 默认保存目录 | 探针环境取不到库根');
      } else {
        check(
          'H 默认保存目录不在 ChronoTide_Cache 内',
          !suggested.toLowerCase().contains('chronotide_cache'),
          suggested,
        );
        check('H 默认保存目录以 ChronoTide_Patches 结尾',
            suggested.toLowerCase().endsWith('chronotide_patches'), suggested);
      }
    }

    // ================= I. 游戏库下拉展开（矮面板最容易 overflow） =================
    L('--- I. 从游戏库选择：下拉展开（1280x720 / 800x600 矮面板）---');

    for (final size in <Size>[Size(1280, 720), Size(800, 600)]) {
      clearErr();
      _probeSize = size;
      await binding.setSurfaceSize(size);
      final anchorKey = GlobalKey();
      const anchor = Rect.fromLTWH(1000, 120, 90, 36);
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(
        Stack(
          children: [
            Positioned(
              left: anchor.left,
              top: anchor.top,
              child: SizedBox(
                key: anchorKey,
                width: anchor.width,
                height: anchor.height,
                child: const ColoredBox(color: Color(0xFF444444)),
              ),
            ),
          ],
        ),
      )));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 40));

      unawaited(PatchStationPanel.show(
        context: anchorKey.currentContext!,
        anchorKey: anchorKey,
        initialQuery: '千恋万花',
        gamePicker: () => const [
          PatchGameRef(id: 'a', title: '千恋＊万花'),
          PatchGameRef(id: 'b', title: '缘之空'),
          PatchGameRef(id: 'c', title: '樱之诗'),
        ],
      ));
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      // 「从游戏库选择」那一行：面板顶 + 边框 + 11 上边距 + 搜索行 36 + 8 间距
      final m = _expectedMetrics(size, anchor);
      final tapAt =
          Offset(m.left + m.width / 2, m.top + 1.6 + 11 + 36 + 8 + 17);
      binding.handlePointerEvent(PointerDownEvent(position: tapAt));
      binding.handlePointerEvent(PointerUpEvent(position: tapAt));
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));

      final texts = _textsOf(binding.rootElement!);
      // 提示文案是「筛选本地游戏库…（回车选中第一项）」⇒ 用 contains 匹配，
      // ⛔ 不要写成全等，提示语一改长就会假失败。
      check('I ${size.width.toInt()}x${size.height.toInt()} 下拉可展开',
          texts.any((t) => t.contains('筛选本地游戏库')),
          texts.take(14).join(' / '));
      check(
          'I ${size.width.toInt()}x${size.height.toInt()} 列出注入的本地游戏',
          texts.contains('缘之空') && texts.contains('樱之诗'),
          texts.take(20).join(' / '));
      check('I ${size.width.toInt()}x${size.height.toInt()} 展开后无溢出',
          details.isEmpty, firstErr());
      await _drainPanel();
    }

    // ================= L. 全局关键词检索必须真的问到鲲 =================
    // 「鲲的补丁明明有一大堆、软件里一个都搜不到」的**第二个独立原因**：
    // 聚合层原来要求 `(gameId ?? '').isNotEmpty` 才做身份解析，而探索库顶栏
    // 的补丁站在没选中游戏时 gameId 是 null ⇒ 解析被整段跳过；鲲的能力表是
    // byKeyword: false（NextMoe 没有补丁名检索，只能 refs=catalog:<id> 锚定）
    // ⇒ 鲲**一次都没被请求**，全局搜出来的自然全是 2DFan 的。
    //
    // 这里走真实的 PatchSearchService（身份解析用 debugSearchOverride 顶掉
    // 网络），断言鲲收到的 ctx.workId 非空。
    L('--- L. 关键词检索（无 gameId）→ 鲲 是否被锚定 ---');
    {
      clearErr();
      PatchIdentityResolver.debugSearchOverride = (kw) async =>
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 51,
              'display_name': 'ヨスガノソラ',
              'localized': <String, dynamic>{
                'zh-Hans': <String, dynamic>{'value': '缘之空'},
              },
            },
          ];

      final seen = <PatchQueryContext>[];
      PatchQueryResult? r;
      try {
        r = await PatchSearchService.withSources(<PatchSource>[
          _RecordingSource(PatchSite.kunlun, seen),
        ]).search(keyword: '缘之空');
      } catch (e) {
        L('      | search threw: $e');
      }
      PatchIdentityResolver.debugSearchOverride = null;

      check('L 无 gameId 时鲲也被调用', seen.isNotEmpty, 'calls=${seen.length}');
      check(
          'L 鲲拿到 workId（身份解析没被跳过）',
          seen.isNotEmpty && seen.first.workId == 51,
          'workId=${seen.isEmpty ? 'null' : seen.first.workId}');
      check('L 鲲产出的条目计入 countsBySite',
          r?.countsBySite[PatchSite.kunlun] == 1, '${r?.countsBySite}');
      check('L 无异常', details.isEmpty, firstErr());

      // 反方向：nsfw 关掉时必须真的传 false（否则「只看全年龄」形同虚设）。
      // 身份解析这时候已经缓存了 kw:缘之空，不会再发请求。
      final seen2 = <PatchQueryContext>[];
      await PatchSearchService.withSources(<PatchSource>[
        _RecordingSource(PatchSite.kunlun, seen2),
      ]).search(keyword: '缘之空', nsfw: false);
      check('L nsfw=false 透传到源上下文',
          seen2.isNotEmpty && !seen2.first.nsfw,
          'nsfw=${seen2.isEmpty ? 'null' : seen2.first.nsfw}');
    }

    // 必须还原：binding 在 runTest 收尾时会断言 onError 已被复原
    FlutterError.onError = prevOnError;

    L('');
    L(_fail == 0 ? '结果: 全部通过' : '结果: $_fail 项失败');
  }, () {}, description: 'patch ui probe');

  File('D:/CTLIB/.workbuddy/outputs/patch_ui_probe.log')
    ..createSync(recursive: true)
    ..writeAsStringSync(_log.join('\n'), flush: true);

  exit(_fail == 0 ? 0 : 1);
}

/// 一次面板渲染的采集结果
class PatchReport {
  const PatchReport({
    required this.name,
    required this.details,
    required this.cardCount,
    this.panelSize,
  });

  final String name;
  final List<FlutterErrorDetails> details;
  final int cardCount;
  final Size? panelSize;

  String? get firstErr =>
      details.isEmpty ? null : details.first.exception.toString();
}

/// 统计渲染树里某类 Widget 的实例数（数卡片最可靠的办法）
/// 收集所有 `T` 组件在屏幕坐标系下的矩形（同一行判定靠 `top`）
List<Rect> _rectsOf<T extends Widget>(Element root) {
  final out = <Rect>[];
  void walk(Element el) {
    if (el.widget is T) {
      final ro = el.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        out.add(ro.localToGlobal(Offset.zero) & ro.size);
      }
    }
    el.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// 找到第一个 `T` 组件（用于直接调它的回调，免得依赖坐标点击）
T? _firstOf<T extends Widget>(Element root) {
  T? found;
  void walk(Element el) {
    if (found != null) return;
    final w = el.widget;
    if (w is T) {
      found = w;
      return;
    }
    el.visitChildren(walk);
  }

  walk(root);
  return found;
}

int _countOf<T extends Widget>(Element root) {
  var n = 0;
  void walk(Element el) {
    if (el.widget is T) n++;
    el.visitChildren(walk);
  }

  walk(root);
  return n;
}

/// 收集渲染树里所有 Text 的字面量（验证「该出现的文案确实出现了」）
///
/// 也要收 `SelectableText`：链接 / 提取码 / sha256 用的是它（可选中复制），
/// 只认 `Text` 会让这些断言全部假红。
List<String> _textsOf(Element root) {
  final out = <String>[];
  void walk(Element el) {
    final w = el.widget;
    if (w is Text) {
      final d = w.data;
      if (d != null && d.isNotEmpty) out.add(d);
    } else if (w is SelectableText) {
      final d = w.data;
      if (d != null && d.isNotEmpty) out.add(d);
    }
    el.visitChildren(walk);
  }

  walk(root);
  return out;
}

/// 记录入参的假源：验证「聚合层到底有没有把 workId 送给鲲」。
///
/// 与 [_FakeSource] 的区别：这个只关心**收到了什么**，并模仿真源的行为
/// ——拿不到 workId 就返回 failed（鲲的 byKeyword 是 false）。
class _RecordingSource implements PatchSource {
  _RecordingSource(this.site, this.sink);

  @override
  final PatchSite site;

  final List<PatchQueryContext> sink;

  @override
  PatchSourceCapabilities get capabilities => const PatchSourceCapabilities(
        byWorkId: true,
        byKeyword: false,
        directDownload: true,
      );

  @override
  Future<PatchSourceResult> search(PatchQueryContext ctx) async {
    sink.add(ctx);
    if (ctx.workId == null) {
      return const PatchSourceResult.failed('未识别到作品，无法在鲲检索');
    }
    return PatchSourceResult(resources: <PatchResource>[
      _res(delivery: PatchDelivery.direct),
    ]);
  }

  @override
  void dispose() {}
}

/// 假源：探针专用，直接吐固定结果（不发网络）
class _FakeSource implements PatchSource {
  _FakeSource(this.site, this.items, {this.failReason});

  @override
  final PatchSite site;
  final List<PatchResource> items;
  final String? failReason;

  @override
  PatchSourceCapabilities get capabilities => const PatchSourceCapabilities();

  @override
  Future<PatchSourceResult> search(PatchQueryContext ctx) async =>
      failReason != null
          ? PatchSourceResult.failed(failReason!)
          : PatchSourceResult(resources: items);

  @override
  void dispose() {}
}

/// 在渲染树里找宽高都与预期吻合的 RenderBox（用于把「算法算出来的面板矩形」
/// 与「真正画出来的矩形」对上，防止算法和渲染各说各话）。
Size? _findBox(Element root, double w, double h) {
  Size? found;
  void walk(Element el) {
    if (found != null) return;
    final ro = el.renderObject;
    if (ro is RenderBox && ro.hasSize) {
      final s = ro.size;
      if ((s.width - w).abs() < 0.6 && (s.height - h).abs() < 0.6) {
        found = s;
        return;
      }
    }
    el.visitChildren(walk);
  }

  walk(root);
  return found;
}

/// 与 `_PanelMetrics.resolve` 同算法的镜像（探针无法访问私有类）。
class _M {
  const _M(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
}

/// 结果区真实可用宽（供恒等式断言用）。
///
/// 🔴 必须扣掉面板 `Border.all` 的宽度：`_PanelMetrics.width` 是**外框**宽，
/// 而 `Wrap` 拿到的是「外框 − 左右边框 − 左右内边距」。漏扣边框会恒差
/// `2 × 1.6 = 3.2px`（实测三个尺寸都正好差 3.2，被这条断言抓出来）。
double _panelInnerWidth(Size screen, Rect anchor, {double padH = 12}) {
  const borderWidth = 1.6; // patch_station_panel.dart: Panel Container 的 Border.all
  final m = _expectedMetrics(screen, anchor);
  return math.max(0.0, m.width - borderWidth * 2 - padH * 2);
}

_M _expectedMetrics(Size screen, Rect anchor) {
  const margin = 16.0;
  const anchorGap = 6.0;
  const minHeight = 320.0;
  const widthRatio = 0.52;
  const minWidth = 460.0;
  const maxWidth = 700.0;

  double cs(double v, double lo, double hi) {
    if (hi <= lo) return lo;
    if (v.isNaN) return lo;
    return v.clamp(lo, hi);
  }

  final usableWidth = math.max(0.0, screen.width - margin * 2);
  final width =
      math.min(usableWidth, cs(screen.width * widthRatio, minWidth, maxWidth));
  final left = math.max(margin, screen.width - width - margin);

  var top = anchor.bottom + anchorGap;
  var height = screen.height - top - margin;
  if (height < minHeight) {
    height = math.min(minHeight, math.max(0.0, screen.height - margin * 2));
    top = math.max(margin, screen.height - margin - height);
  }

  return _M(left, math.max(0, top), width, math.max(0, height));
}
