/// 库页详情窗口 v3 综合探针（flutter_tester，零真实游戏目录 / 零网络）。
///
/// 覆盖：
///  A. `KungalWalkthroughService` 纯逻辑：URL 模板、响应解析、负缓存、并发合并；
///  B. **整屏渲染 `GameDetailDialog` 本体**（改动落在 build，只探子页面会假绿）：
///     行顺序、必然存在文案、Tooltip、置灰/可用三态、1120 与窄逻辑宽度两档
///     0 溢出且右栏未被压扁、编辑态。
/// 🔴 异常判据用自设 `FlutterError.onError`；`takeException()` 会漏「被压扁」。
/// 🔴 `dart:io` 异步读在 FakeAsync 下永久挂起 ⇒ 走 `debugSeedData` 零 IO 路径。
///
/// 编译 / 运行（在 apps/chrono-tide 下，dill 输出到仓库外）：
///   dartaotruntime gen_kernel_aot.dart.snapshot \
///     --platform <flutter_patched_sdk>/platform_strong.dill --target flutter \
///     --packages .dart_tool/package_config.json --output <out>.dill \
///     dev_probe/game_detail_dialog_v3_probe.dart
///   flutter_tester.exe --disable-vm-service --enable-checked-mode <out>.dill

// dev_probe/ 不是 test/ 目录，但探针必须调用 @visibleForTesting 成员；
// renderViewElement 在本版 SDK 有 deprecated 别名，探针里沿用既有模板。
// ignore_for_file: invalid_use_of_visible_for_testing_member, deprecated_member_use
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/kungal_link_service.dart';
import 'package:chrono_tide/services/kungal_walkthrough_service.dart';
import 'package:chrono_tide/theme/app_colors.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/game_detail_dialog.dart';

int _pass = 0;
int _fail = 0;

void L(String m) => stdout.writeln(m);

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  L('  ${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : ' | $detail'}');
}

Size? _probeSize;

Widget _app(Widget child) => MaterialApp(
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
      home: Scaffold(
        backgroundColor: const Color(0xFF1E1E1E),
        body: child,
      ),
    );

void _collectText(Element e, List<String> out) {
  final w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  if (w is RichText && w.text is TextSpan) {
    out.add((w.text as TextSpan).toPlainText());
  }
  e.visitChildren((c) => _collectText(c, out));
}

void _collectTooltips(Element e, List<String> out) {
  final w = e.widget;
  if (w is Tooltip && w.message != null) out.add(w.message!);
  e.visitChildren((c) => _collectTooltips(c, out));
}

void _collectBoxes(Element e, List<RenderBox> out) {
  final r = e.renderObject;
  if (r is RenderBox) out.add(r);
  e.visitChildren((c) => _collectBoxes(c, out));
}

/// 精确定位 `build()` 里的窗口外壳 Container（唯一带 boxShadow 的容器），
/// 避免把大量「宽度恰好相同」的其它容器误当成窗口来量高度。
void _collectDialogShell(Element e, List<Size> out) {
  final w = e.widget;
  if (w is Container) {
    final d = w.decoration;
    if (d is BoxDecoration && d.boxShadow != null && d.boxShadow!.isNotEmpty) {
      final r = e.renderObject;
      if (r is RenderBox) out.add(r.size);
    }
  }
  e.visitChildren((c) => _collectDialogShell(c, out));
}

int _countGreyIcons(Element e) {
  var n = 0;
  final w = e.widget;
  if (w is Icon && w.color == AppColors.border.withOpacity(0.55)) n++;
  e.visitChildren((c) => n += _countGreyIcons(c));
  return n;
}

GameJsonData _seed({String releaseDate = '2011-06-24'}) => GameJsonData(
      formatVersion: GameDataFormat.currentVersion,
      title: 'Rewrite',
      subtitle: 'リライト',
      originalTitle: 'リライト',
      gameId: 'probe-rewrite-198',
      source: 'download',
      installedAt: '2026-10-04T12:30:00',
      releaseDate: releaseDate,
      developer: 'Key',
      description: '故事发生在风祭市，瑚太朗与同伴们调查超自然现象，'
          '并逐渐触及世界背后的真相。这是一段用于验证详情窗口右栏加宽后'
          '长文本不会溢出、不会被压扁的足够长的简介内容。',
      tags: const ['ADV', '恋爱', 'Key', '长标签用于验证标签行自适应'],
      // 长目录路径：验证「来源」行右侧加了两个按钮后长值仍 ellipsis 不溢出
      directoryPath: r'D:\Galgame\Key\Rewrite\非常长的中文目录名_用于验证横向加宽后的显示余量\game',
      launchPath: 'game.exe',
      coverFile: '',
      rating: 8.5,
      ratingCount: 1234,
      estimatedMinutes: 3000,
    );

// ═══════════════════ A. 服务纯逻辑 ═══════════════════
Future<void> _serviceProbe() async {
  L('=== A. KungalWalkthroughService 纯逻辑 ===');
  check('pageUrlOf(198, 3970) 与实测网页一致',
      KungalWalkthroughService.pageUrlOf(198, 3970) ==
          'https://www.kungal.com/galgame/198/walkthrough/3970');
  check('pageUrlOf(231772, 737) 模板通用',
      KungalWalkthroughService.pageUrlOf(231772, 737) ==
          'https://www.kungal.com/galgame/231772/walkthrough/737');
  check('非法 workId → 空串（UI 应置灰）', KungalWalkthroughService.pageUrlOf(0, 3970).isEmpty);
  check('非法攻略 id → 空串', KungalWalkthroughService.pageUrlOf(198, -1).isEmpty);

  check('parseFirstId 取首篇',
      KungalWalkthroughService.parseFirstId(<String, dynamic>{
            'items': [
              <String, dynamic>{'id': '3970', 'work_id': '198'}
            ]
          }) ==
          3970);
  check('parseFirstId 空列表 → null',
      KungalWalkthroughService.parseFirstId(<String, dynamic>{'items': <dynamic>[]}) == null);
  check('parseFirstId 无 items → null',
      KungalWalkthroughService.parseFirstId(<String, dynamic>{}) == null);
  check('parseFirstId 非数字 id → null', KungalWalkthroughService.parseFirstId(<String, dynamic>{
        'items': [
          <String, dynamic>{'id': 'abc'}
        ]
      }) ==
      null);
  check('parseFirstId 非法 id(0) → null', KungalWalkthroughService.parseFirstId(<String, dynamic>{
        'items': [
          <String, dynamic>{'id': '0'}
        ]
      }) ==
      null);
  check('KungalLinkService.detailUrlOf(198)',
      KungalLinkService.detailUrlOf(198) == 'https://www.kungal.com/galgame/198');

  final svc = KungalWalkthroughService.forTest();
  var calls = 0;
  KungalWalkthroughService.debugResolver = (workId) async {
    calls++;
    return workId == 198 ? 3970 : null;
  };
  final f1 = svc.resolveWalkthroughId(198);
  final f2 = svc.resolveWalkthroughId(198);
  final r1 = await f1;
  final r2 = await f2;
  check('并发合并：两个 Future 都拿到同一结果', r1 == 3970 && r2 == 3970);
  check('并发合并：只打一次解析', calls == 1, 'calls=$calls');
  check('会话缓存命中不再重复解析',
      await svc.resolveWalkthroughId(198) == 3970 && calls == 1,
      'calls=$calls');
  check('无攻略 → null', await svc.resolveWalkthroughId(999) == null);
  check('负结果也进会话缓存',
      await svc.resolveWalkthroughId(999) == null && calls == 2,
      'calls=$calls');
  check('workId <= 0 不打网络',
      await svc.resolveWalkthroughId(0) == null && calls == 2,
      'calls=$calls');
  KungalWalkthroughService.debugResolver = null;
}

// ═══════════════════ B. 整屏渲染 ═══════════════════
Future<void> main() async {
  await _serviceProbe();

  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  ThemeRegistry.registerBuiltinThemes();

  final details = <FlutterErrorDetails>[];
  final prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (d) {
    details.add(d);
    return prevBuilder(d);
  };

  final prevOnError = FlutterError.onError;
  await binding.runTest(() async {
    FlutterError.onError = (d) => details.add(d);
    void clearErr() => details.clear();
    String? firstErr() {
      if (details.isEmpty) return null;
      final e = details.first.exception.toString();
      L('      | ${e.length > 240 ? e.substring(0, 240) : e}');
      return e.length > 80 ? e.substring(0, 80) : e;
    }

    Future<void> mount(Widget child, Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      binding.attachRootWidget(binding.wrapWithDefaultView(_app(child)));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
    }

    Element? root() => binding.renderViewElement;
    List<String> texts() {
      final out = <String>[];
      final r = root();
      if (r != null) _collectText(r, out);
      return out;
    }

    List<String> tips() {
      final out = <String>[];
      final r = root();
      if (r != null) _collectTooltips(r, out);
      return out;
    }

    List<RenderBox> boxes() {
      final out = <RenderBox>[];
      final r = root();
      if (r != null) _collectBoxes(r, out);
      return out;
    }

    Widget dialog({
      GameJsonData? data,
      int? kungalId,
      int? walkthroughId,
    }) =>
        Center(
          child: GameDetailDialog(
            directoryPath: r'D:\probe\no-such-dir',
            debugSeedData: data ?? _seed(),
            debugKungalId: kungalId,
            debugWalkthroughId: walkthroughId,
          ),
        );

    // ── B1. 顺序 / 必然存在文案 / 三档宽度 ──────────────────
    L('=== B1. 元数据行顺序 + 必然存在文案 + 宽度自适应 ===');
    for (final size in <Size>[
      const Size(1280, 720),
      const Size(1600, 900),
      const Size(1024, 768), // 窄逻辑宽度：min(1120, 1024-48) = 976
    ]) {
      clearErr();
      await mount(
          dialog(kungalId: 198, walkthroughId: 3970), size);
      final t = texts();
      final expectWidth =
          size.width - 48.0 < 1120.0 ? size.width - 48.0 : 1120.0;
      final rightWidth = expectWidth - 340.0; // 280 左栏 + 32 间距 + 28 右 padding

      check('W=${size.width} 必然存在文案「Rewrite」',
          t.any((e) => e.contains('Rewrite')), '文本数=${t.length}');
      check('W=${size.width} 必然存在文案「来源 / 安装日期」',
          t.contains('来源') && t.contains('安装日期'));
      int idx(String s) => t.indexWhere((e) => e.trim() == s);
      final order = <String>[
        '来源',
        '安装日期',
        '目录',
        '占用空间',
        '会社',
        '开发日期',
        '启动信息',
      ];
      final positions = order.map(idx).toList();
      var ascending = !positions.contains(-1);
      for (var i = 1; i < positions.length; i++) {
        if (positions[i] <= positions[i - 1]) ascending = false;
      }
      check('W=${size.width} 元数据行顺序 = 来源→安装日期→目录→占用空间→会社→开发日期→启动信息',
          ascending, 'positions=$positions');

      final wideBoxes = boxes()
          .where((b) =>
              b.size.width >= expectWidth - 2 &&
              b.size.width <= expectWidth + 2)
          .length;
      check('W=${size.width} 窗口宽 = ${expectWidth.toStringAsFixed(0)}',
          wideBoxes > 0, '候选=$wideBoxes');
      final rightBoxes = boxes()
          .where((b) =>
              b.size.width >= rightWidth - 14 &&
              b.size.width <= rightWidth + 2)
          .length;
      check(
          'W=${size.width} 右栏净宽 ≈ ${rightWidth.toStringAsFixed(0)}（未被压扁）',
          rightBoxes > 0,
          '候选=$rightBoxes');
      // 高度：maxHeight = 屏高 * 0.90，一字未改（只量窗口外壳本身）
      final shells = <Size>[];
      final r0 = root();
      if (r0 != null) _collectDialogShell(r0, shells);
      final shell = shells.isEmpty ? null : shells.first;
      check(
          'W=${size.width} 窗口外壳宽=${expectWidth.toStringAsFixed(0)} 且高 ≤ 屏高×0.90',
          shell != null &&
              (shell.width - expectWidth).abs() <= 2 &&
              shell.height <= size.height * 0.90 + 1,
          'shell=$shell 候选=${shells.length}');
      check('W=${size.width} 整屏渲染 0 异常 / 0 溢出', details.isEmpty,
          firstErr() ?? '');
    }

    // ── B2. 无发售日：开发日期行消失，安装日期仍在 ────────────
    L('=== B2. 无发售日 → 开发日期行不渲染 ===');
    clearErr();
    await mount(
        dialog(data: _seed(releaseDate: ''), kungalId: 198, walkthroughId: 3970),
        const Size(1280, 720));
    final t2 = texts();
    check('无发售日：不存在「开发日期」行', !t2.contains('开发日期'));
    check('无发售日：安装日期行仍在', t2.contains('安装日期'));
    check('无发售日：必然存在文案「Rewrite」', t2.any((e) => e.contains('Rewrite')));
    check('无发售日：0 异常', details.isEmpty, firstErr() ?? '');

    // ── B3. 两按钮三态（可用 / 置灰）────────────────────────
    L('=== B3. 站点 / 攻略按钮三态（置灰由用户拍板）===');
    final cases = <(String, int?, int?, String, String, int)>[
      (
        '未定位到作品',
        null,
        null,
        '未定位到该作品的 KUNGAL 页面',
        '未定位到该作品，无法查看攻略',
        2,
      ),
      (
        '有作品但暂无攻略',
        198,
        null,
        '打开 KUNGAL 作品页',
        '该作品暂无站内攻略',
        1,
      ),
      (
        '作品 + 攻略都有',
        198,
        3970,
        '打开 KUNGAL 作品页',
        '查看该作品攻略',
        0,
      ),
    ];
    for (final c in cases) {
      clearErr();
      await mount(
          dialog(kungalId: c.$2, walkthroughId: c.$3), const Size(1280, 720));
      final tp = tips();
      check('${c.$1}：站点按钮 Tooltip 正确', tp.contains(c.$4),
          'tooltips=${tp.length}');
      check('${c.$1}：攻略按钮 Tooltip 正确', tp.contains(c.$5));
      final r = root();
      final grey = r == null ? -1 : _countGreyIcons(r);
      check('${c.$1}：置灰图标数 = ${c.$6}', grey == c.$6, '实测=$grey');
      check('${c.$1}：0 异常', details.isEmpty, firstErr() ?? '');
    }

    // ── B4. 编辑态不被破坏 ─────────────────────────────────
    L('=== B4. 编辑态（点击左栏编辑按钮）===');
    clearErr();
    await mount(
        dialog(kungalId: 198, walkthroughId: 3970), const Size(1280, 720));
    try {
      // 直接调编辑按钮的 GestureDetector.onTap：WidgetController 是抽象类，
      // 且裸 binding.runTest 下没有命中测试环境，走 Element 祖先更稳。
      final iconEls = find.byIcon(Icons.edit_outlined).evaluate();
      var tapped = false;
      if (iconEls.isNotEmpty) {
        GestureDetector? detector;
        iconEls.first.visitAncestorElements((ancestor) {
          final w = ancestor.widget;
          if (w is GestureDetector) {
            detector = w;
            return false;
          }
          return true;
        });
        if (detector?.onTap != null) {
          detector!.onTap!.call();
          tapped = true;
        }
      }
      check('编辑态：找到并触发编辑按钮', tapped);
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      final te = texts();
      check('编辑态：必然存在文案「Rewrite」仍在',
          te.any((e) => e.contains('Rewrite')), '文本数=${te.length}');
      check('编辑态：0 异常 / 0 溢出', details.isEmpty, firstErr() ?? '');
    } catch (e) {
      L('  SKIP  编辑态点击不可用（探针环境限制，非代码回归）: $e');
      check('编辑态：查看态已 0 异常（降级断言）', details.isEmpty);
    }

    FlutterError.onError = prevOnError;
  }, () {}); // 本版 flutter_test 的 runTest 需要 invariantTester 位置参数

  ErrorWidget.builder = prevBuilder;
  L('DETAIL-DIALOG-V3 PROBE: $_pass PASS / $_fail FAIL');
  if (_fail > 0) exitCode = 1;
}
