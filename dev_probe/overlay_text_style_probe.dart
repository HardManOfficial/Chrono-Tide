/// 「Overlay 浮层里的文字双下划线」根因 + 修法探针（flutter_tester）。
///
/// 2026-11-13 用户在游戏库「管理」筛选面板看到每行文字下面挂着**两条线**
/// （会社筛选的每个会社名下面都有）。根因不是有人写了 `underline`：
///
///   OverlayEntry 的 builder context 若**没有 Material 祖先**，
///   `DefaultTextStyle.of()` 会落到 Flutter 的兜底样式
///   （`color: 0xD0FF0000` 红字 + `decoration: underline` +
///    `decorationColor: 0xFFFFFF00` 黄线 + `decorationStyle: double`）。
///   面板里每处 `TextStyle(fontSize: …, color: …)` 只覆盖字号与颜色，
///   `decoration` 照样继承 ⇒ 正常颜色的字 + **黄色双下划线**。
///
/// 所以本探针钉两件事：
///   A. 机制（运行时）：同一个 Text，在无 Material 的 OverlayEntry 里
///      decoration 必须是 underline/double；包了 `Material(transparency)`
///      必须变回 none。前一条证明「双横线」就是这个来源，后一条证明修法有效。
///   B. 防回归（源码级）：`library_page.dart` 的两个自建 OverlayEntry
///      （管理面板 / 拖拽浮层）必须各自包 Material —— 全页其它浮层
///      （右键菜单、收藏夹、拖拽、字体库）都委托给已自带 Material 的组件，
///      只有这两个是在 OverlayEntry 里直接构造裸 widget 的。
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dartaotruntime <gen_kernel_aot.dart.snapshot> --platform \
///     <engine/common/flutter_patched_sdk>/platform_strong.dill --target flutter \
///     --packages .dart_tool/package_config.json --output x.dill 本文件
///   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill
library;

import 'dart:io';

import 'package:chrono_tide/widgets/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// 取 `s[from]` 处 '(' 起、括号配对为止的内部文本（跳过字符串会被误伤，
/// 这里只用来读我们自己写的构造体，够用）。
String _parenBody(String s, int from) {
  int depth = 0;
  for (int i = from; i < s.length; i++) {
    final String c = s[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return s.substring(from + 1, i);
    }
  }
  return s.substring(from + 1);
}

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();

  final List<FlutterErrorDetails> details = <FlutterErrorDetails>[];
  final ErrorWidgetBuilder prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (FlutterErrorDetails d) {
    details.add(d);
    return prevBuilder(d);
  };

  await binding.runTest(() async {
    FlutterError.onError = (FlutterErrorDetails d) => details.add(d);

    const TextStyle probeStyle = TextStyle(fontSize: 12, color: Color(0xFFFFFFFF));

    // ═══════════ A. 机制验证 ═══════════
    L('=== A. Overlay 里 Text 的 decoration（根因复现）===');
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await binding.setSurfaceSize(const Size(400, 300));
    binding.attachRootWidget(binding.wrapWithDefaultView(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navKey,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    binding.scheduleFrame();
    await binding.pump();

    final OverlayState? overlay = navKey.currentState?.overlay;
    check('A0 Navigator.overlay 可用', overlay != null);
    if (overlay == null) {
      L('');
      L('TOTAL PASS=$_pass FAIL=$_fail');
      if (_fail > 0) exitCode = 1;
      return;
    }

    // A 组：裸 Text 直接塞进 OverlayEntry（= 修复前的管理面板）
    final OverlayEntry bare = OverlayEntry(
      builder: (_) => const Positioned(
        left: 8,
        top: 8,
        child: Text('PANEL_BARE', style: probeStyle),
      ),
    );
    // B 组：根部包 Material(transparency)（= 修复后），内部再 Stack + Positioned
    // ——与 library_page 的真实结构一致（Material 在最外层，Positioned 在其内部 Stack 里）
    final OverlayEntry wrapped = OverlayEntry(
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: Stack(
          children: const <Widget>[
            Positioned(
              left: 8,
              top: 40,
              child: Text('PANEL_MATERIAL', style: probeStyle),
            ),
          ],
        ),
      ),
    );
    overlay
      ..insert(bare)
      ..insert(wrapped);
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));

    /// 按文字内容找回那一处 RenderParagraph，读出**合并后**的 decoration。
    TextStyle? styleOf(String marker) {
      TextStyle? found;
      void walk(Element e) {
        if (found != null) return;
        final RenderObject? ro = e.renderObject;
        if (ro is RenderParagraph) {
          final InlineSpan span = ro.text;
          if (span is TextSpan && span.text == marker) found = span.style;
        }
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return found;
    }

    final TextStyle? bareStyle = styleOf('PANEL_BARE');
    final TextStyle? wrappedStyle = styleOf('PANEL_MATERIAL');
    check('A1 两段文字都渲染出来了', bareStyle != null && wrappedStyle != null);

    check(
      'A2 无 Material 祖先 ⇒ 继承 double 下划线（这就是「双横线」的根因）',
      bareStyle?.decoration == TextDecoration.underline &&
          bareStyle?.decorationStyle == TextDecorationStyle.double,
      'decoration=${bareStyle?.decoration} '
          'style=${bareStyle?.decorationStyle}',
    );
    check(
      'A3 包 Material(transparency) ⇒ decoration 归零（修法有效）',
      wrappedStyle?.decoration == null ||
          wrappedStyle?.decoration == TextDecoration.none,
      'decoration=${wrappedStyle?.decoration}',
    );
    check(
      'A4 包 Material 后字号/颜色不被改写',
      wrappedStyle?.fontSize == 12 && wrappedStyle?.color == probeStyle.color,
      'fontSize=${wrappedStyle?.fontSize} color=${wrappedStyle?.color}',
    );
    check('A5 过程中无渲染异常', details.isEmpty,
        details.isEmpty ? '' : details.first.exception.toString());

    bare
      ..remove()
      ..dispose();
    wrapped
      ..remove()
      ..dispose();

    // ═══════════ B. 源码防回归 ═══════════
    L('');
    L('=== B. library_page 的 OverlayEntry 必须包 Material ===');
    final File f = File('lib/pages/library_page.dart');
    check('B0 找到 library_page.dart', f.existsSync());
    if (f.existsSync()) {
      final String src = f.readAsStringSync();
      for (final String entryName in <String>[
        '_managementPanel = OverlayEntry(',
        '_dragOverlay = OverlayEntry(',
      ]) {
        final int at = src.indexOf(entryName);
        check('B 源码里有 $entryName', at >= 0);
        if (at < 0) continue;
        final String body =
            _parenBody(src, at + entryName.length - 1);
        check(
          'B $entryName 构造体里包了 Material(transparency)',
          body.contains('Material(') &&
              body.contains('MaterialType.transparency'),
          '构造体长度=${body.length}',
        );
      }
    }

    // ═══════════ C. 路由层同样没 Material（showGeneralDialog / showAppDialog）═══
    L('');
    L('=== C. 路由页面的 Text decoration（运行时）===');
    final BuildContext? hostCtx = navKey.currentContext;
    check('C0 拿到 Navigator 的 context', hostCtx != null);
    if (hostCtx != null) {
      // C 组负向对照：裸 showGeneralDialog，pageBuilder 里不给 Material
      showGeneralDialog<void>(
        context: hostCtx,
        barrierLabel: 'probe',
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) =>
            const Align(alignment: Alignment.topLeft, child: Text('DIALOG_BARE')),
      );
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 300));
      final TextStyle? bareDlg = styleOf('DIALOG_BARE');
      check('C1 裸 showGeneralDialog 里的 Text 也有 double 下划线', 
          bareDlg?.decoration == TextDecoration.underline &&
              bareDlg?.decorationStyle == TextDecorationStyle.double,
          'decoration=${bareDlg?.decoration} style=${bareDlg?.decorationStyle}');

      // C 组正向：走 showAppDialog（已包 Material），禁用所有显式 style
      showAppDialog<void>(
        context: hostCtx,
        builder: (_) => const Align(
          alignment: Alignment.topLeft,
          child: Text('DIALOG_APP'),
        ),
      );
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 300));
      final TextStyle? appDlg = styleOf('DIALOG_APP');
      check('C2 showAppDialog 里的 Text 已无下划线（修法生效）',
          appDlg != null &&
              (appDlg.decoration == null ||
                  appDlg.decoration == TextDecoration.none),
          'decoration=${appDlg?.decoration}');
      check('C3 也不再落到兜底 48px monospace', appDlg?.fontSize != 48,
          'fontSize=${appDlg?.fontSize}');
    }

    // ═══════════ D. 其余 Overlay / 路由挂载点的源码防回归 ═══════════
    L('');
    L('=== D. 其余挂载点必须包 Material ===');
    final Map<String, List<String>> sites = <String, List<String>>{
      'lib/widgets/app_dialog.dart': <String>[
        'showGeneralDialog<T>(',
      ],
      'lib/pages/join_page.dart': <String>[
        'overlayEntry = OverlayEntry(',
      ],
      'lib/big_picture/big_picture_shell.dart': <String>[
        '_vkOverlay = OverlayEntry(',
      ],
    };
    sites.forEach((String path, List<String> anchors) {
      final File file = File(path);
      if (!file.existsSync()) {
        check('D 找到 $path', false);
        return;
      }
      final String src = file.readAsStringSync();
      for (final String anchor in anchors) {
        final int at = src.indexOf(anchor);
        check('D $path 里有锚点', at >= 0, anchor);
        if (at < 0) continue;
        final String body = _parenBody(src, at + anchor.length - 1);
        check('D $path 的挂载体包了 Material(transparency)',
            body.contains('Material(') &&
                body.contains('MaterialType.transparency'),
            '长度=${body.length}');
      }
    });

    L('');
    L('TOTAL PASS=$_pass FAIL=$_fail');
    if (_fail > 0) exitCode = 1;
  }, () {});
}