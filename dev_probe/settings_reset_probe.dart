/// 「恢复默认设置」探针（2026-11-14）。
///
/// 这个功能最容易出的错**不在 UI**，而是「键名写错一个字母」——界面照常跑、
/// 点击也"成功"，但那个设置根本没被清掉。所以本探针 A 段做的是**键清单体检**：
/// 每个键必须能在 `lib/` 源码里找到字面量，且四类互不重叠、不碰凭据与动态键。
///
/// 覆盖：
///   A. 键清单静态体检（读 lib 源码，排除 `lib/services/settings_reset/` 自身）
///   B. 编排行为（内存假 prefs：删除 / 缺失 / 失败 / 异常 / 空域）
///   C. 面板渲染（1280×720 与 820×520 × 暖阳 / 极光，0 溢出 0 异常）
///   D. 交互（默认全选 → 取消一类 → 计数联动 → 全选/取消全选）
///   E. 负向（勾选态不许提前进结果页；「不会删除」清单必须在场）
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dartaotruntime <flutter>/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
///     --platform <flutter>/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
///     --target flutter --packages .dart_tool/package_config.json \
///     --output dev_probe/settings_reset.dill dev_probe/settings_reset_probe.dart
///   <flutter>/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
///     --disable-vm-service --enable-checked-mode dev_probe/settings_reset.dill
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/services/settings_reset/settings_reset_core.dart';
import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/settings/settings_group_card.dart';
import 'package:chrono_tide/widgets/settings/settings_reset_dialog.dart';

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
      builder: (BuildContext context, Widget? inner) {
        final MediaQueryData base = MediaQuery.of(context);
        final Size? s = _probeSize;
        return MediaQuery(
          data: s == null ? base : base.copyWith(size: s),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(body: Center(child: child)),
    );

void _collectText(Element e, List<String> out) {
  final Widget w = e.widget;
  if (w is Text && w.data != null) out.add(w.data!);
  if (w is RichText && w.text is TextSpan) {
    out.add((w.text as TextSpan).toPlainText());
  }
  e.visitChildren((Element c) => _collectText(c, out));
}

/// 全部键的并集（按域顺序）。
List<String> _allKeys() =>
    settingsResetKeysFor(SettingsResetDomain.values);

int _totalItems() {
  int n = 0;
  for (final SettingsResetDomain d in SettingsResetDomain.values) {
    n += settingsResetItemCount(d);
  }
  return n;
}

Future<void> main() async {
  final AutomatedTestWidgetsFlutterBinding binding =
      AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  // 探针在扮演「测试」，两处 @visibleForTesting 的用法是正当的
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});
  ThemeRegistry.registerBuiltinThemes();

  // ═════════════════════ A. 键清单静态体检 ═════════════════════

  L('=== A. 键清单静态体检 ===');

  // 收集 lib/ 下的全部 Dart 源码（排除 settings_reset 目录 —— 那里就写着键名，
  // 拿它自己当证据等于没验）。
  final String skip = 'lib\\services\\settings_reset';
  final StringBuffer blob = StringBuffer();
  int scannedFiles = 0;
  final Directory libDir = Directory('lib');
  void walk(Directory d) {
    if (!d.existsSync()) return;
    for (final FileSystemEntity e in d.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      if (e.path.replaceAll('/', '\\').contains(skip)) continue;
      blob.write('${e.readAsStringSync()}\n');
      scannedFiles++;
    }
  }

  walk(libDir);
  check('A0 扫到 lib 源码（相对路径 cwd=apps/chrono-tide）', scannedFiles > 300,
      '文件数=$scannedFiles');

  final String source = blob.toString();
  final List<String> all = _allKeys();

  for (final SettingsResetDomain d in SettingsResetDomain.values) {
    check('A1 「${d.label}」键清单非空',
        (kSettingsResetKeys[d] ?? const <String>[]).isNotEmpty,
        '${settingsResetItemCount(d)} 项');
  }

  final List<String> missing = <String>[
    for (final String k in all)
      if (!source.contains("'$k'")) k,
  ];
  check('A2 每个键都能在 lib 源码里找到字面量', missing.isEmpty,
      '缺失=${missing.join(",")}（共 ${all.length} 键）');

  // 一个键只能属于一个恢复类别：否则"只恢复界面"会顺手改掉别的域。
  final List<String> overlaps = <String>[];
  for (int i = 0; i < SettingsResetDomain.values.length; i++) {
    for (int j = i + 1; j < SettingsResetDomain.values.length; j++) {
      final SettingsResetDomain a = SettingsResetDomain.values[i];
      final SettingsResetDomain b = SettingsResetDomain.values[j];
      for (final String k in kSettingsResetKeys[a] ?? const <String>[]) {
        if ((kSettingsResetKeys[b] ?? const <String>[]).contains(k)) {
          overlaps.add('$k(${a.id}/${b.id})');
        }
      }
    }
  }
  check('A3 四类键清单两两无交集', overlaps.isEmpty, '重叠=${overlaps.join(",")}');

  final RegExp snake = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)*$');
  final List<String> badName = <String>[
    for (final String k in all)
      if (!snake.hasMatch(k) || k.startsWith('flutter.')) k,
  ];
  check('A4 键名全是裸 snake_case（无 flutter. 前缀）', badName.isEmpty,
      '异常=${badName.join(",")}');

  final List<String> credentialCollision = <String>[
    for (final String k in all)
      if (kSettingsResetNeverTouchKeys.contains(k)) k,
  ];
  check('A5 与「绝不清理」清单无交集', credentialCollision.isEmpty,
      '冲突=${credentialCollision.join(",")}');

  final List<String> prefixCollision = <String>[
    for (final String k in all)
      for (final String p in kSettingsResetNeverTouchPrefixes)
        if (k.startsWith(p)) k,
  ];
  check('A6 无键命中「绝不清理」前缀', prefixCollision.isEmpty,
      '冲突=${prefixCollision.join(",")}');

  // 反向抽样：最容易手滑加进来的键
  const List<String> mustPreserve = <String>[
    'oauth_token_v1_',
    'storage_migration_v1_',
    'default_exe_',
    'save_custom_paths_',
    'file_size_',
  ];
  check(
    'A7 凭据 / 迁移闸 / 按游戏键都不在清理范围',
    all.every((String k) => mustPreserve.every((String p) => !k.startsWith(p))),
  );

  final Set<String> ids = <String>{};
  bool idOk = true;
  bool textOk = true;
  for (final SettingsResetDomain d in SettingsResetDomain.values) {
    if (!ids.add(d.id) || SettingsResetDomain.byId(d.id) != d) idOk = false;
    if (d.label.isEmpty || d.summary.isEmpty || d.note.isEmpty) textOk = false;
  }
  check('A8 域 id 唯一且 byId 可往返', idOk);
  check('A9 每类的标题/说明/提醒都不为空', textOk);

  check('A10 合并函数去重且总数 = 各类之和',
      all.toSet().length == all.length && all.length == _totalItems(),
      '合并=${all.length} 相加=${_totalItems()}');

  // ═════════════════════ B. 编排行为 ═════════════════════

  L('');
  L('=== B. 编排行为（内存假 prefs）===');

  Future<SettingsResetReport> runWith(
    Set<SettingsResetDomain> domains,
    Map<String, String> store, {
    Set<String>? failOn,
    Set<String>? throwOn,
  }) async {
    return runSettingsReset(
      domains: domains,
      contains: (String k) async {
        if (throwOn != null && throwOn.contains(k)) {
          throw StateError('boom: $k');
        }
        return store.containsKey(k);
      },
      remove: (String k) async {
        if (failOn != null && failOn.contains(k)) return false;
        store.remove(k);
        return true;
      },
    );
  }

  final SettingsResetReport empty = await runWith(
    <SettingsResetDomain>{},
    <String, String>{'app_theme': 'frost'},
  );
  check('B0 不选任何类别 ⇒ 一个键都不动',
      empty.removedCount == 0 && empty.absentCount == 0);

  final Map<String, String> store1 = <String, String>{
    'app_theme': 'frost',
    'reduce_motion_background': 'true',
    'win_geom_w': '1600',
  };
  final SettingsResetReport r1 = await runWith(
    <SettingsResetDomain>{SettingsResetDomain.appearance},
    store1,
  );
  check('B1 只恢复「界面」：存在的 3 个键被删',
      r1.removedCount == 3 && store1.isEmpty, r1.toString());
  check('B1b 其余键记为「本来即是默认」',
      r1.absentCount == settingsResetItemCount(SettingsResetDomain.appearance) - 3,
      'absent=${r1.absentCount}');
  // 没选的类别绝不被动到
  final Map<String, String> store2 = <String, String>{
    'app_theme': 'frost',
    'proxy_url': 'http://127.0.0.1:7890',
  };
  await runWith(<SettingsResetDomain>{SettingsResetDomain.appearance}, store2);
  check('B2 未勾选的类别不受影响', store2.containsKey('proxy_url'));

  final Map<String, String> store3 = <String, String>{'app_theme': 'frost'};
  final SettingsResetReport r3 = await runWith(
    <SettingsResetDomain>{SettingsResetDomain.appearance},
    store3,
    failOn: <String>{'app_theme'},
  );
  check('B3 remove 失败 ⇒ 计入 failedKeys 而不是静默',
      r3.failedKeys.length == 1 && store3.containsKey('app_theme'),
      r3.toString());

  final SettingsResetReport r4 = await runWith(
    <SettingsResetDomain>{SettingsResetDomain.metadata},
    <String, String>{'metadata_field_priority': 'x'},
    throwOn: <String>{'enabled_metadata_sources'},
  );
  check('B4 contains 抛异常 ⇒ 记账不冒泡',
      r4.failedKeys.length == 1 && r4.removedCount == 1, r4.toString());

  final Map<String, String> store5 = <String, String>{
    for (final String k in all) k: 'x',
  };
  final SettingsResetReport r5 = await runWith(
    SettingsResetDomain.values.toSet(),
    store5,
  );
  check('B5 恢复全部 ⇒ 每个键都有归属，store 清空',
      r5.removedCount == all.length &&
          store5.isEmpty &&
          r5.removedCount + r5.absentCount + r5.failedKeys.length == all.length,
      r5.toString());

  final SettingsResetReport r6 = await runWith(
    <SettingsResetDomain>{SettingsResetDomain.metadata},
    <String, String>{},
  );
  check('B6 全都不存在时文案不撒谎',
      r6.removedCount == 0 && r6.summaryLine.contains('本来就'), r6.summaryLine);
  check('B7 有删除时文案带条数',
      r1.summaryLine.startsWith('已恢复 3 项'), r1.summaryLine);

  // ═════════════════════ C. 渲染 ═════════════════════

  await binding.runTest(() async {
    final List<FlutterErrorDetails> details = <FlutterErrorDetails>[];
    final ErrorWidgetBuilder prevBuilder = ErrorWidget.builder;
    ErrorWidget.builder = (FlutterErrorDetails d) {
      details.add(d);
      return prevBuilder(d);
    };
    FlutterError.onError = (FlutterErrorDetails d) => details.add(d);

    Future<void> mount(Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      details.clear();
      binding.attachRootWidget(
          binding.wrapWithDefaultView(_app(const SettingsResetPanel())));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      await binding.pump(const Duration(milliseconds: 120));
    }

    List<String> texts() {
      final List<String> out = <String>[];
      final Element? root = binding.renderViewElement;
      if (root != null) _collectText(root, out);
      return out;
    }

    bool has(String needle) =>
        texts().any((String t) => t.contains(needle));

    /// ⚠️ 只数 `Text` 组件：`texts()` 里每个 `Text` 会同时出现一次（`Text`）和
    /// 一次（`RichText`），拿 `texts()` 计数必然翻倍。
    int countText(String exact) {
      int n = 0;
      void walk(Element e) {
        final Widget w = e.widget;
        if (w is Text && (w.data ?? '').trim() == exact) n++;
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return n;
    }

    int countIcon(IconData icon) {
      int n = 0;
      void walk(Element e) {
        final Widget w = e.widget;
        if (w is Icon && w.icon == icon) n++;
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return n;
    }

    int countWidget<T extends Widget>() {
      int n = 0;
      void walk(Element e) {
        if (e.widget is T) n++;
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return n;
    }

    /// 点某个文案所在的可点区域（`_DomainRow` / 全选按钮都是 GestureDetector）。
    bool tapOn(String label) {
      final Element? root = binding.renderViewElement;
      if (root == null) return false;
      bool tapped = false;
      void walk(Element e) {
        if (tapped) return;
        final Widget w = e.widget;
        if (w is Text && (w.data ?? '').trim() == label) {
          final GestureDetector? gd =
              e.findAncestorWidgetOfExactType<GestureDetector>();
          if (gd?.onTap != null) {
            gd!.onTap!.call();
            tapped = true;
            return;
          }
        }
        e.visitChildren(walk);
      }

      walk(root);
      return tapped;
    }

    String firstErr() {
      if (details.isEmpty) return '';
      final String e = details.first.exception.toString();
      return e.length > 200 ? e.substring(0, 200) : e;
    }

    final int total = _totalItems();
    final int appearanceCount = settingsResetItemCount(
        SettingsResetDomain.appearance);

    L('');
    L('=== C. 渲染 ===');

    // ── C1 1280×720 暖阳 ──
    await AppThemeManager.instance.setThemeById('warmSun');
    await mount(const Size(1280, 720));
    check('C1 1280×720 挂载成功（防 ErrorWidget 假绿）',
        has('恢复默认设置'), '文本数=${texts().length}');
    check('C2 四类标题全在',
        SettingsResetDomain.values.every((SettingsResetDomain d) => has(d.label)),
        '缺=${SettingsResetDomain.values.where((SettingsResetDomain d) => !has(d.label)).map((SettingsResetDomain d) => d.label).join(",")}');
    check('C3 每类都带「N 项」计数', countText('${appearanceCount} 项') == 1,
        '出现次数=${countText('${appearanceCount} 项')}');
    check('C4 默认全选：总计文案正确', has('共 $total 项'), '期望共 $total 项');
    check('C5 危险提示在场', has('恢复后无法撤销'));
    check('C6 「不会删除」清单在场', has('不会被删除'));
    check('C7 底部按钮齐（取消 / 恢复选中项）',
        countText('取消') == 1 && countText('恢复选中项') == 1);
    check('C8 用组卡承载四类', countWidget<SettingsGroupCard>() == 1);
    check('C9 1280×720 无溢出/无异常', details.isEmpty, firstErr());

    // ── C10 820×520（设置窗口最小尺寸，正文应当可滚而不溢出）──
    await mount(const Size(820, 520));
    double overflowCount() => details
        .where((FlutterErrorDetails d) =>
            d.exception.toString().contains('overflowed'))
        .length
        .toDouble();
    check('C10 820×520 无溢出', overflowCount() == 0, firstErr());
    check('C11 820×520 仍显示标题与按钮',
        has('恢复默认设置') && countText('恢复选中项') == 1);

    // ── C12 极光档 ──
    await AppThemeManager.instance.setThemeById('frost');
    await mount(const Size(1280, 720));
    check('C12 frost 下挂载成功', has('恢复默认设置'));
    check('C13 frost 下无溢出/无异常', details.isEmpty, firstErr());
    await mount(const Size(820, 520));
    check('C14 frost + 820×520 无溢出', overflowCount() == 0, firstErr());
    await AppThemeManager.instance.setThemeById('warmSun');

    // ═════════════════════ D. 交互 ═════════════════════

    L('');
    L('=== D. 交互 ===');
    await mount(const Size(1280, 720));
    check('D0 默认全选（按钮显示「取消全选」）', countText('取消全选') == 1);

    final bool t1 = tapOn('界面设置');
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    check('D1 点「界面设置」可取消勾选', t1);
    check('D2 取消一类后总数扣减',
        has('共 ${total - appearanceCount} 项'),
        '文本=${texts().where((String t) => t.startsWith('共 ')).join(",")}');

    // 少选一类时右上角按钮变成「全选」（点它 = 重新全选）
    final bool t2 = tapOn('全选');
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    check('D3 少选一类后按钮变为「全选」，点它回到全选',
        t2 && has('共 $total 项') && countText('取消全选') == 1);

    final bool t3 = tapOn('取消全选');
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    check('D4 「取消全选」可清空到 0 项', t3 && has('共 0 项'));

    final bool t4 = tapOn('全选');
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    check('D5 清空后再「全选」恢复全选', t4 && has('共 $total 项'));

    // ═════════════════════ E. 负向 ═════════════════════

    L('');
    L('=== E. 负向 ===');
    check('E0 勾选态不会提前跳到结果页', !has('恢复完成') && !has('立即重启'));
    check('E1 关闭图标在场（面板右上角）', countIcon(Icons.close_rounded) == 1);
    check('E2 没有出现「恢复中…」残留（未触发恢复）', !has('恢复中…'));

    // ═════════════════════ F. 结果页 ═════════════════════
    // 结果页高度随「副作用条目」变化，是最容易溢出的那一屏，单独渲染验证。
    L('');
    L('=== F. 结果页 ===');
    final SettingsResetReport fakeReport =
        SettingsResetReport(domains: SettingsResetDomain.values.toSet())
          ..removedKeys.addAll(<String>['app_theme', 'proxy_url', 'nsfw_filter_enabled'])
          ..absentKeys.addAll(<String>['theme_follow_system', 'metadata_field_priority'])
          ..sideEffects.addAll(<String>[
            '已关闭开机自启（含注册表启动项）',
            '主题已切回默认（暖阳）',
            '已解除本次会话的下载限速',
          ]);
    Future<void> mountReport(Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      details.clear();
      binding.attachRootWidget(binding.wrapWithDefaultView(
          _app(SettingsResetPanel(debugInitialReport: fakeReport))));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      await binding.pump(const Duration(milliseconds: 120));
    }

    await mountReport(const Size(1280, 720));
    check('F0 结果页标题换成「恢复完成」', has('恢复完成'));
    check('F1 结果页报出条数', has('已恢复 3 项设置'), fakeReport.summaryLine);
    check('F2 副作用逐条上屏',
        has('已关闭开机自启') && has('已切回默认') && has('已解除本次会话的下载限速'));
    check('F3 结果页主按钮是「立即重启」', countText('立即重启') == 1);
    check('F4 结果页不再显示「恢复选中项」', countText('恢复选中项') == 0);
    check('F5 结果页 1280×720 无溢出/无异常', details.isEmpty, firstErr());

    await mountReport(const Size(820, 520));
    check('F6 结果页 820×520 无溢出', overflowCount() == 0, firstErr());
    check('F7 结果页 820×520 仍能点到重启按钮', countText('立即重启') == 1);

    await AppThemeManager.instance.setThemeById('frost');
    await mountReport(const Size(1280, 720));
    check('F8 frost 下结果页无异常', details.isEmpty && has('恢复完成'), firstErr());
    await AppThemeManager.instance.setThemeById('warmSun');

    L('');
    L('TOTAL PASS=$_pass FAIL=$_fail');
    if (_fail > 0) exitCode = 1;
  }, () {});
}
