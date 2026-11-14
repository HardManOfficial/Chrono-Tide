/// 设置窗口整屏渲染探针（flutter_tester）。
///
/// 🔴 项目铁律：改动落在哪个页面的 build，就必须把**那个页面整屏渲染一次**。
/// 本探针挂真实的 `SettingsModal`，切到「网络与存储」与「关于应用」两屏，
/// 断言必含文案存在（整树塌成 ErrorWidget 时文本数=0 也会假绿）、
/// 无构建异常、无 RenderFlex 溢出；关于页额外按最小窗口 820×520 复核。
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dart <gen_kernel_aot>.snapshot --platform <flutter_patched_sdk>/platform_strong.dill \
///     --target flutter --packages .dart_tool/package_config.json \
///     --output settings_modal_proxy.dill dev_probe/settings_modal_proxy_probe.dart
///   flutter_tester.exe --disable-vm-service --enable-checked-mode settings_modal_proxy.dill

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/interactive_wrapper.dart';
import 'package:chrono_tide/widgets/settings_modal.dart';

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

void _noop() {}

Size? _probeSize;

Widget _app(Widget child) => MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      builder: (BuildContext context, Widget? inner) {
        final MediaQueryData base = MediaQuery.of(context);
        final Size? s = _probeSize;
        return MediaQuery(
          data: s == null ? base : base.copyWith(size: s),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(body: child),
    );

void _collectText(Element e, List<String> out) {
  final Widget w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  if (w is RichText && w.text is TextSpan) {
    out.add((w.text as TextSpan).toPlainText());
  }
  e.visitChildren((Element c) => _collectText(c, out));
}

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  ThemeRegistry.registerBuiltinThemes();

  final details = <FlutterErrorDetails>[];
  final prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (FlutterErrorDetails d) {
    details.add(d);
    return prevBuilder(d);
  };

  final prevOnError = FlutterError.onError;
  await binding.runTest(() async {
    FlutterError.onError = (FlutterErrorDetails d) => details.add(d);

    void clearErr() => details.clear();
    String firstErr() {
      if (details.isEmpty) return '';
      final String e = details.first.exception.toString();
      return e.length > 160 ? e.substring(0, 160) : e;
    }

    Future<void> mount(Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      clearErr();
      binding.attachRootWidget(binding.wrapWithDefaultView(
          _app(SettingsModal(onClose: _noop))));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
    }

    List<String> texts() {
      final out = <String>[];
      final Element? root = binding.renderViewElement;
      if (root != null) _collectText(root, out);
      return out;
    }

    /// 通过 Element 树找到侧栏标签对应的 InteractiveWrapper 并触发 onTap，
    /// 避开 flutter_tester 里 handlePointerEvent 无法 await 的坑。
    bool tapTab(String label) {
      final Element? root = binding.renderViewElement;
      if (root == null) return false;
      bool tapped = false;
      void walk(Element e) {
        final Widget w = e.widget;
        if (!tapped && w is Text && w.data == label) {
          final InteractiveWrapper? wrap =
              e.findAncestorWidgetOfExactType<InteractiveWrapper>();
          if (wrap?.onTap != null) {
            wrap!.onTap!.call();
            tapped = true;
          }
        }
        e.visitChildren(walk);
      }

      walk(root);
      return tapped;
    }

    Future<void> switchTab(String label) async {
      final bool ok = tapTab(label);
      check('切到「$label」找到侧栏入口', ok);
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
    }

    bool has(String needle) => texts().any((String t) => t.contains(needle));

    // ═══════════ A. 网络与存储（默认 1280×720）═══════════
    L('=== A. 网络与存储 · 全局网络代理三态 ===');
    await mount(const Size(1280, 720));
    check('A0 整窗挂载后必要文案存在（防 ErrorWidget 假绿）',
        has('设置 / Settings') || has('个人资料'), '文本数=${texts().length}');
    await switchTab('网络与存储');
    final List<String> a = texts();
    check('A1 网络代理设置卡片', a.any((String t) => t.contains('网络代理设置')));
    check('A2 全局网络代理标签', a.any((String t) => t.contains('全局网络代理')));
    check('A3 自动跟随系统代理选项',
        a.any((String t) => t.contains('自动跟随系统代理')));
    check('A4 手动代理 URL 区', a.any((String t) => t.contains('手动代理 URL')));
    check('A5 保存 / 清除按钮',
        a.any((String t) => t == '保存') && a.any((String t) => t == '清除'));
    check('A6 致谢已搬离本页',
        !a.any((String t) => t.contains('开源组件致谢')));
    check('A7 构建无异常 / 无溢出', details.isEmpty, firstErr());

    // ═══════════ B. 关于应用（默认 1280×720）═══════════
    L('=== B. 关于应用 · 右下角致谢 ===');
    await mount(const Size(1280, 720));
    await switchTab('关于应用');
    final List<String> b = texts();
    check('B1 Chrono Tide 标题', b.any((String t) => t.contains('Chrono Tide')));
    check('B2 版本号', b.any((String t) => t.contains('Version')));
    check('B3 检查更新按钮', b.any((String t) => t.contains('检查更新')));
    check('B4 左下角「了解我们」仍在',
        b.any((String t) => t.contains('了解我们')) &&
            b.any((String t) => t.contains('GitHub 仓库')));
    check('B5 右下角致谢标题', b.any((String t) => t.contains('开源组件致谢')));
    check('B6 SDL3 精简行', b.any((String t) => t.contains('SDL3 · zlib')));
    check('B7 CTFontHook 精简行',
        b.any((String t) => t.contains('CTFontHook 0.1.1 · MIT')));
    check('B8 Detours 精简行',
        b.any((String t) => t.contains('Microsoft Detours 4.0.1 · MIT')));
    check('B9 完整许可指向安装目录',
        b.any((String t) => t.contains('完整许可见安装目录')));
    check('B10 本页无代理卡片',
        !b.any((String t) => t.contains('网络代理设置')));
    check('B11 构建无异常 / 无溢出', details.isEmpty, firstErr());

    // ═══════════ C. 关于应用（最小窗口 820×520）═══════════
    L('=== C. 关于应用 · 最小窗口不溢出 ===');
    await mount(const Size(820, 520));
    await switchTab('关于应用');
    final List<String> c = texts();
    check('C1 致谢仍在右下角（未被压掉）',
        c.any((String t) => t.contains('开源组件致谢')) &&
            c.any((String t) => t.contains('SDL3 · zlib')));
    check('C2 左下角链接仍在', c.any((String t) => t.contains('GitHub 仓库')));
    check('C3 检查更新按钮仍在', c.any((String t) => t.contains('检查更新')));
    check('C4 构建无异常 / 无 RenderFlex 溢出', details.isEmpty, firstErr());

    FlutterError.onError = prevOnError;
  }, () {});
  ErrorWidget.builder = prevBuilder;
  L('TOTAL PASS=$_pass FAIL=$_fail');
  if (_fail > 0) exitCode = 1;
}
