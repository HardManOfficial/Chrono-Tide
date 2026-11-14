// 全站库结果条（SiteSearchResultBar）渲染 + 交互探针（flutter_tester）
//
// 为什么单独探它：这条 bar 只在「有站外结果」时出现，探索页整屏探针拿不到
// 该状态（站外结果必须真打网络才产生）。所以把它抽成独立组件后，用夹具
// 直接渲染 —— 本项目吃过「改动落在某个 build、探针覆盖不到、release 里整块
// 灰底」的亏，凡是新写的 build 必须有一屏探针。
//
// 覆盖：
//   A. 布局：1280 / 1024 / 900 三个宽度不溢出、无零尺寸文本、无异常
//   B. 文案：关键词 / 源计数胶囊 / 差额说明 / 失败提示
//   C. 交互：点源胶囊回调带对源、点重新搜索、点关闭、搜索中隐藏胶囊
//
// 编译（⛔ platform dill 在 engine/common/flutter_patched_sdk/）：
//   dartaotruntime.exe gen_kernel_aot.dart.snapshot ^
//     --platform .../platform_strong.dill --target flutter ^
//     --packages .dart_tool/package_config.json ^
//     --output x.dill dev_probe/site_search_result_bar_probe.dart
//   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill
//
// 退出码：0 = 全绿；1 = 有失败。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/site_search/site_search_result_bar.dart';

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

/// 收集子树里所有 Text 的内容（含零尺寸文本检测）
List<String> _texts(Element root, {void Function(String, Size)? onZero}) {
  final out = <String>[];
  void visit(Element el) {
    final w = el.widget;
    if (w is Text && (w.data ?? '').isNotEmpty) {
      out.add(w.data!);
      final r = el.renderObject;
      if (r is RenderBox && r.hasSize && onZero != null) {
        if (r.size.width <= 0.5 || r.size.height <= 0.5) {
          onZero(w.data!, r.size);
        }
      }
    }
    el.visitChildren(visit);
  }

  root.visitChildren(visit);
  return out;
}

/// 顶层 Element（attachRootWidget 的根）
Element? _rootEl(GlobalKey key) => key.currentContext as Element?;

Future<void> main() async {
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  ThemeRegistry.registerBuiltinThemes();

  // 捕获 build/paint 期异常（CustomPainter 异常会被静默吞帧，必须自己接）
  final errors = <String>[];
  final prevOnError = FlutterError.onError;
  FlutterError.onError = (d) {
    errors.add(d.exceptionAsString());
    prevOnError?.call(d);
  };

  await binding.runTest(() async {
    Future<GlobalKey> mount(
      Widget bar,
      double width, {
      List<void Function()>? hovers,
    }) async {
      final key = GlobalKey();
      await binding.setSurfaceSize(Size(width, 400));
      binding.attachRootWidget(
        binding.wrapWithDefaultView(
          MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: width - 24,
                    child: RepaintBoundary(key: key, child: bar),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      return key;
    }

    // ===== A/B. 结果态：两源 + 差额 + 失败 =====
    var toggled = <SiteSearchSource>[];
    var refreshed = 0;
    var closed = 0;
    Widget bar({
      bool searching = false,
      SiteSearchSource? active,
      String? failure,
    }) =>
        SiteSearchResultBar(
          keyword: 'chronobox',
          searching: searching,
          sourceCounts: const {
            SiteSearchSource.moyu: 1,
            SiteSearchSource.twoDfan: 3,
          },
          activeSource: active,
          notes: const ['已滤除 6 条标题不匹配的模糊匹配', '已隐藏 2 条与库内重复的作品'],
          failureText: failure,
          onToggleSource: (s) => toggled.add(s),
          onRefresh: () => refreshed++,
          onClose: () => closed++,
        );

    for (final w in <double>[1280, 1024, 900]) {
      final key = await mount(bar(failure: null), w);
      final el = _rootEl(key);
      check('A${w.toInt()} 挂载成功', el != null);
      final zeros = <String>[];
      final texts = _texts(el!, onZero: (t, s) => zeros.add('$t $s'));
      check('A${w.toInt()} 无零尺寸文本', zeros.isEmpty, zeros.join(' / '));
      check('A${w.toInt()} 全站库标识', texts.contains('全站库'), texts.length.toString());
      check('A${w.toInt()} 关键词上屏', texts.contains('「chronobox」'));
      check('A${w.toInt()} 源计数胶囊', texts.contains('鲲 1') && texts.contains('2DFan 3'),
          texts.join(','));
      check('A${w.toInt()} 重新搜索按钮', texts.contains('重新搜索'));
      check('A${w.toInt()} 高度恒 32', () {
        final box = el.findRenderObject();
        return box is RenderBox && box.hasSize && box.size.height == 32;
      }());
    }

    // ===== B2. 搜索中：显示进度，隐藏胶囊与刷新 =====
    {
      final key = await mount(bar(searching: true), 1280);
      final texts = _texts(_rootEl(key)!);
      check('B2 搜索中文案', texts.any((t) => t.contains('正在搜索「chronobox」')),
          texts.join(','));
      check('B2 搜索中不出源胶囊', !texts.contains('鲲 1'));
      check('B2 搜索中不出重新搜索', !texts.contains('重新搜索'));
    }

    // ===== C. 交互：点「鲲 1」胶囊 → 回调带 moyu =====
    {
      toggled = [];
      final key = await mount(bar(failure: null), 1280);
      final el = _rootEl(key)!;
      final hit = _centerOfText(el, '鲲 1');
      check('C1 找到胶囊命中点', hit != null, '$hit');
      if (hit != null) {
        await _tap(binding, hit);
        check('C2 点击回调源 = moyu', toggled.length == 1 && toggled.first == SiteSearchSource.moyu,
            toggled.toString());
      }
      final refreshHit = _centerOfText(el, '重新搜索');
      if (refreshHit != null) {
        await _tap(binding, refreshHit);
        check('C3 重新搜索回调触发', refreshed == 1, '$refreshed');
      } else {
        check('C3 找到重新搜索命中点', false);
      }
    }

    // ===== C4. 关闭按钮 =====
    {
      final key = await mount(bar(failure: null), 1280);
      final before = closed;
      final hit = _iconCenter(_rootEl(key)!, Icons.close_rounded);
      if (hit != null) {
        await _tap(binding, hit);
        check('C4 关闭回调触发', closed == before + 1, '$closed');
      } else {
        check('C4 找到关闭按钮', false);
      }
    }

    // ===== D. 失败态：错误图标在（Tooltip 承载文案，不进正文）=====
    {
      final key = await mount(bar(failure: '鲲：请求超时'), 1280);
      final el = _rootEl(key)!;
      check('D1 失败图标存在', _iconCenter(el, Icons.error_outline_rounded) != null);
      final texts = _texts(el);
      check('D1 失败文案不占正文（交给 Tooltip）',
          !texts.any((t) => t.contains('请求超时')));
    }

    // ===== E. 空计数：所有源 0 条时不渲染胶囊 =====
    {
      final key = await mount(
        SiteSearchResultBar(
          keyword: 'zzz',
          searching: false,
          sourceCounts: const {SiteSearchSource.moyu: 0, SiteSearchSource.twoDfan: 0},
          onClose: () {},
        ),
        1280,
      );
      final texts = _texts(_rootEl(key)!);
      check('E1 0 条不出胶囊', !texts.contains('鲲 0') && !texts.contains('2DFan 0'));
      check('E2 关键词仍在', texts.contains('「zzz」'));
    }
  }, () {});

  check('Z1 无 Flutter 异常', errors.isEmpty, errors.join(' / '));

  L('\n--- 结果: $_pass 通过 / $_fail 失败 ---');
  exitCode = _fail == 0 ? 0 : 1;
}

/// 找到文本所在 RenderBox 的全局中心
Offset? _centerOfText(Element root, String data) {
  Offset? out;
  void visit(Element el) {
    if (out != null) return;
    final w = el.widget;
    if (w is Text && w.data == data) {
      final r = el.renderObject;
      if (r is RenderBox && r.hasSize) {
        out = r.localToGlobal(r.size.center(Offset.zero));
        return;
      }
    }
    el.visitChildren(visit);
  }

  root.visitChildren(visit);
  return out;
}

/// 找到图标所在的全局中心
Offset? _iconCenter(Element root, IconData icon) {
  Offset? out;
  void visit(Element el) {
    if (out != null) return;
    final w = el.widget;
    if (w is Icon && w.icon == icon) {
      final r = el.renderObject;
      if (r is RenderBox && r.hasSize) {
        out = r.localToGlobal(r.size.center(Offset.zero));
        return;
      }
    }
    el.visitChildren(visit);
  }

  root.visitChildren(visit);
  return out;
}

/// 在指定位置做一次完整点击（down → up；`handlePointerEvent` 返回 void）
Future<void> _tap(AutomatedTestWidgetsFlutterBinding binding, Offset at) async {
  binding.handlePointerEvent(PointerDownEvent(position: at));
  binding.handlePointerEvent(PointerUpEvent(position: at));
  await binding.pump();
  await binding.pump(const Duration(milliseconds: 40));
}
