// INSTALL-CONFIRM-PROXY 探针（flutter_tester）
//
// 验证「使用本机代理加速下载」这一行在安装确认弹窗里的渲染与交互：
//   A. 传 proxySuggestion → 该行出现、文案带上代理地址、默认未勾选；
//   B. 点击整行 → onProxyChanged(true)、图标变实心、再点回 false；
//   C. 不传 proxySuggestion → 该行完全不出现（旧调用点零回归）；
//   D. 全程无 FlutterError（弹窗根部 Material 已有，不会踩红字/黄下划线）。
//
// 编译（⛔ platform dill 在 engine/common/flutter_patched_sdk/）：
//   dartaotruntime.exe gen_kernel_aot.dart.snapshot ^
//     --platform ...\common\flutter_patched_sdk\platform_strong.dill ^
//     --target flutter --packages .dart_tool/package_config.json ^
//     --output x.dill dev_probe\install_confirm_proxy_probe.dart
//   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill
//
// 退出码：0 = 全绿；1 = 有失败。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/install_confirmation_dialog.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('✅ PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('❌ FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

const String _proxy = 'http://127.0.0.1:7892';

/// 承载 showDialog 的宿主：挂载后自动弹窗。
class _DialogHost extends StatefulWidget {
  final String? proxySuggestion;
  final ValueChanged<bool>? onProxyChanged;

  const _DialogHost({this.proxySuggestion, this.onProxyChanged});

  @override
  State<_DialogHost> createState() => _DialogHostState();
}

class _DialogHostState extends State<_DialogHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      InstallConfirmationDialog.show(
        context: context,
        gameTitle: 'ChronoBox -时空匣-',
        gameDescription: '测试用简介',
        gameTags: const ['科幻', '悬疑'],
        knownSizeBytes: 1024 * 1024 * 100,
        proxySuggestion: widget.proxySuggestion,
        onProxyChanged: widget.onProxyChanged,
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Color(0xFF1E1E1E),
        body: SizedBox.shrink(),
      );
}

Future<void> _mount(
  AutomatedTestWidgetsFlutterBinding binding, {
  String? proxySuggestion,
  ValueChanged<bool>? onProxyChanged,
}) async {
  // 🔴 flutter_tester 里 renderView 默认 0×0 → 布局无约束，坐标会跑到几千 px，
  //    点击必然落空。必须先定视口尺寸。
  await binding.setSurfaceSize(const Size(1280, 800));
  binding.attachRootWidget(binding.wrapWithDefaultView(MaterialApp(
    // 🔴 每次换 key，避免 Element 复用到上一个弹窗的 Overlay
    key: UniqueKey(),
    debugShowCheckedModeBanner: false,
    // 🔴 默认测试视口只有 800×600，弹窗高 700 会把加速行挤出可视区，
    //    点击坐标落到屏幕外必然无效。按主壳实际尺寸给视口。
    builder: (context, inner) {
      final base = MediaQuery.of(context);
      return MediaQuery(
        data: base.copyWith(size: const Size(1280, 800)),
        child: inner ?? const SizedBox.shrink(),
      );
    },
    home: _DialogHost(
      proxySuggestion: proxySuggestion,
      onProxyChanged: onProxyChanged,
    ),
  )));
  await binding.pump();
  await binding.pump(const Duration(milliseconds: 60));
  // 弹窗进场动画
  await binding.pump(const Duration(milliseconds: 300));
}

Offset? _textCenter(String label) {
  for (final e in find.text(label).evaluate()) {
    final box = e.renderObject;
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
  }
  return null;
}

Future<void> _tapAt(
    AutomatedTestWidgetsFlutterBinding binding, Offset at) async {
  binding.handlePointerEvent(PointerDownEvent(position: at));
  binding.handlePointerEvent(PointerUpEvent(position: at));
  await binding.pump();
  await binding.pump(const Duration(milliseconds: 60));
}

bool _hasIcon(IconData icon) => find.byIcon(icon).evaluate().isNotEmpty;

Future<void> main() async {
  // 🔴 AppColors 走 AppThemeManager.current，未注册主题会空指针炸 build。
  ThemeRegistry.registerBuiltinThemes();
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();

  final errors = <String>[];
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString());
  };

  bool? flag;

  await binding.runTest(() async {
    // ===== A. 有代理建议：行出现且默认未勾选 =====
    flag = null;
    await _mount(binding,
        proxySuggestion: _proxy, onProxyChanged: (v) => flag = v);

    check('A1 加速行文案存在', find.text('使用本机代理加速下载').evaluate().isNotEmpty);
    check('A2 说明里带出代理地址',
        find.textContaining('127.0.0.1:7892').evaluate().isNotEmpty);
    check('A3 默认未勾选（空框图标在）',
        _hasIcon(Icons.check_box_outline_blank));
    check('A4 默认未勾选（实心框不在）', !_hasIcon(Icons.check_box));
    check('A5 未触发回调', flag == null, '$flag');
    check('A6 原有内容仍在（体积行）',
        find.textContaining('下载包体积').evaluate().isNotEmpty);

    // ===== B. 点击整行 → 勾选 =====
    final tapAt = _textCenter('使用本机代理加速下载');
    if (tapAt == null) {
      check('B0 找到加速行命中点', false);
    } else {
      await _tapAt(binding, tapAt);
      check('B1 回调收到 true', flag == true, '$flag');
      check('B2 图标切换到实心', _hasIcon(Icons.check_box));
      check('B3 空框已消失', !_hasIcon(Icons.check_box_outline_blank));

      // 再点一次 → 取消勾选
      final again = _textCenter('使用本机代理加速下载');
      if (again != null) {
        await _tapAt(binding, again);
        check('B4 再点回 false', flag == false, '$flag');
      } else {
        check('B4 再点回 false', false, '找不到命中点');
      }
    }

    // ===== C. 无代理建议：整行不渲染（旧调用点零回归）=====
    await _mount(binding);
    check('C1 无代理时不出现加速行',
        find.text('使用本机代理加速下载').evaluate().isEmpty);
    check('C2 弹窗主体仍正常（标题在）',
        find.text('确认安装').evaluate().isNotEmpty);
    check('C3 开始安装按钮在', find.text('开始安装').evaluate().isNotEmpty);
  }, () {});

  // ===== D. 渲染期未抛异常 =====
  check('D1 无 FlutterError', errors.isEmpty, errors.take(2).join(' | '));

  FlutterError.onError = prevOnError;

  print('\n=== 结果: $_pass PASS / $_fail FAIL ===');
}
