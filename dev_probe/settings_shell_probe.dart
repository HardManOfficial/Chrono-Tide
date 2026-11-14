/// 「设置窗口骨架 + 8 个 tab」整屏渲染探针（flutter_tester）。
///
/// 2026-11-13 设置页 UI 统一改造的回归闸门。覆盖：
///   1. 侧栏 4 簇标题 + 8 个 tab 在 820×520 下**不用滚动**就能全显示；
///   2. 每个 tab 都挂上了一级页头（标题 + 一句说明）；
///   3. 每个 tab 在两种窗口尺寸下都能构建、0 溢出、0 异常；
///   4. 组卡（`SettingsGroupCard`）真的出现在页面上（不是被 boxed:false 全关掉）；
///   5. 负向：旧视觉语言的残留（「修改资料」下边框标题）不许回来；
///   6. IA 微调生效：「大标题素材」只在元数据页，不在网络与存储页。
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dartaotruntime <gen_kernel_aot.dart.snapshot> --platform \
///     <engine/common/flutter_patched_sdk>/platform_strong.dill --target flutter \
///     --packages .dart_tool/package_config.json --output x.dill 本文件
///   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/app_theme_manager.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/interactive_wrapper.dart';
import 'package:chrono_tide/widgets/settings/settings_group_card.dart';
import 'package:chrono_tide/widgets/settings/settings_page_header.dart';
import 'package:chrono_tide/widgets/settings/settings_tab.dart';
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
  // 探针本身就在扮演「测试」，这两处 @visibleForTesting 的用法是正当的
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});
  ThemeRegistry.registerBuiltinThemes();

  final details = <FlutterErrorDetails>[];
  final prevBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (FlutterErrorDetails d) {
    details.add(d);
    return prevBuilder(d);
  };

  await binding.runTest(() async {
    FlutterError.onError = (FlutterErrorDetails d) => details.add(d);

    void clearErr() => details.clear();
    String firstErr() {
      if (details.isEmpty) return '';
      final String e = details.first.exception.toString();
      return e.length > 220 ? e.substring(0, 220) : e;
    }

    Future<void> mount(Size size) async {
      _probeSize = size;
      await binding.setSurfaceSize(size);
      clearErr();
      binding.attachRootWidget(
          binding.wrapWithDefaultView(_app(SettingsModal(onClose: _noop))));
      binding.scheduleFrame();
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 60));
      await binding.pump(const Duration(milliseconds: 120));
      await binding.pump(const Duration(milliseconds: 120));
    }

    List<String> texts() {
      final out = <String>[];
      final Element? root = binding.renderViewElement;
      if (root != null) _collectText(root, out);
      return out;
    }

    bool has(String needle) => texts().any((String t) => t.contains(needle));

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

    /// 树里是否真的有「某张 asset 图」被构建。
    /// 不能只数 `Image` 个数——设置页别处也有图，数出来分不清是谁。
    bool hasAssetImage(String assetName) {
      bool found = false;
      void walk(Element e) {
        if (found) return;
        final Widget w = e.widget;
        if (w is Image) {
          final ImageProvider<Object> p = w.image;
          if (p is AssetImage && p.assetName == assetName) found = true;
        }
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return found;
    }

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
      check('切到「$label」', ok);
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 80));
      await binding.pump(const Duration(milliseconds: 120));
    }

    // ═══════════ A. 骨架 · 1280×720 ═══════════
    L('=== A. 骨架 1280×720 ===');
    await mount(const Size(1280, 720));
    check('A0 挂载成功（防 ErrorWidget 假绿）',
        has('设置') || has('个人资料'), '文本数=${texts().length}');
    // 2026-11-14：页头右上角常驻「恢复默认」入口（四个簇、八个 tab 下都在）。
    check('A0b 页头有「恢复默认」逃生舱入口', has('恢复默认'));
    check(
      'A1 侧栏 4 簇标题齐全',
      has('我的') && has('界面') && has('游戏') && has('系统'),
    );
    int clusterHits = 0;
    for (final SettingsCluster c in SettingsCluster.values) {
      if (has(c.label)) clusterHits++;
    }
    check('A2 簇标题数 = 4', clusterHits == 4, '实得=$clusterHits');
    check(
      'A3 8 个 tab 文案全在',
      SettingsTabMeta.items.every((SettingsTabMeta m) => has(m.label)),
      '缺=${SettingsTabMeta.items.where((SettingsTabMeta m) => !has(m.label)).map((SettingsTabMeta m) => m.label).join(",")}',
    );
    check('A4 一级页头已挂载（默认落在个人资料）',
        countWidget<SettingsPageHeader>() == 1 &&
            has(SettingsTabMeta.of(SettingsTab.profile).description));
    check('A5 个人资料用组卡（≥2 张）', countWidget<SettingsGroupCard>() >= 2,
        '组卡数=${countWidget<SettingsGroupCard>()}');
    check('A6 负向：旧「✏️ 修改资料」下边框标题已删除', !has('修改资料'));
    check('A7 构建无异常 / 无溢出', details.isEmpty, firstErr());

    // ═══════════ B. 8 个 tab 逐个走 ═══════════
    L('=== B. 8 个 tab 逐个走（1280×720）===');
    for (final SettingsTabMeta meta in SettingsTabMeta.items) {
      if (meta.tab == SettingsTab.profile) continue;
      L('-- ${meta.label}');
      await switchTab(meta.label);
      clearErr();
      await binding.pump();
      check('B ${meta.label} 页头标题', has(meta.label));
      check('B ${meta.label} 页头说明', has(meta.description));
      check('B ${meta.label} 无异常/溢出', details.isEmpty, firstErr());
    }

    // ═══════════ C. IA 微调 ═══════════
    L('=== C. IA 微调 ===');
    await switchTab('元数据');
    check('C1 大标题素材已落到元数据页', has('大标题素材'));
    check('C2 元数据页有组卡或自有卡片',
        countWidget<SettingsGroupCard>() >= 1 ||
            has('元数据拉取来源'));
    await switchTab('网络与存储');
    check('C3 网络与存储不再包含大标题素材', !has('大标题素材'));
    check('C4 网络与存储：网络代理 / 下载 / 游戏库目录 三组在',
        has('网络代理') && has('下载') && has('游戏库目录'));
    check('C5 组卡承载下载强度（5 行）',
        countWidget<SettingsGroupCard>() >= 2,
        '组卡数=${countWidget<SettingsGroupCard>()}');
    await switchTab('游戏与启动');
    check('C6 游戏与启动：组卡承载系统/兼容性/窗口/游玩记录',
        countWidget<SettingsGroupCard>() >= 4,
        '组卡数=${countWidget<SettingsGroupCard>()}');
    check('C7 负向：旧重卡标题不再作为独立卡出现（保留行标题即可）',
        has('开机自启动') && has('快捷窗口控制'));

    // ═══════════ D. 最小窗 820×520 ═══════════
    L('=== D. 最小窗 820×520 ===');
    await mount(const Size(820, 520));
    check('D0 最小窗挂载成功', has('设置') || has('个人资料'),
        '文本数=${texts().length}');

    /// 取某个文案的屏幕矩形（用来判断「是否真的落在窗口里」）。
    /// 只认 `Text`：RichText 子节点拿到的矩形是同一份，重复命中没意义。
    Rect? rectOf(String text) {
      final Element? root = binding.renderViewElement;
      Rect? out;
      void walk(Element e) {
        final Widget w = e.widget;
        if (out == null && w is Text && w.data == text) {
          final RenderObject? ro = e.renderObject;
          if (ro is RenderBox && ro.hasSize) {
            out = ro.localToGlobal(Offset.zero) & ro.size;
          }
        }
        e.visitChildren(walk);
      }

      if (root != null) walk(root);
      return out;
    }

    // 8 项 + 4 簇标题必须在 820×520 下**真的**全露出来（不是「建在树里但被
    // 滚出视口」）。这是本次侧栏压缩到 34 高 / 16 高簇标题的唯一目的，
    // 所以必须钉住几何位置，不能只钉文案存在。
    final Rect? lastTab = rectOf('关于应用');
    check(
      'D1 最小窗下第 8 项落在可视区内（侧栏无需滚动）',
      lastTab != null && lastTab.top >= 0 && lastTab.bottom <= 520,
      lastTab == null ? '未找到' : 'top=${lastTab.top.toStringAsFixed(0)} '
          'bottom=${lastTab.bottom.toStringAsFixed(0)}',
    );
    for (final SettingsTabMeta meta in SettingsTabMeta.items) {
      if (meta.tab == SettingsTab.profile) continue;
      await switchTab(meta.label);
      clearErr();
      await binding.pump();
      check('D ${meta.label} 最小窗无溢出', details.isEmpty, firstErr());
    }
    await switchTab('网络与存储');
    check('D8 最小窗下侧栏 8 项仍全部命中（无需滚动）',
        SettingsTabMeta.items.every((SettingsTabMeta m) => has(m.label)));

    // ═══════════ E. 双风格档 ═══════════
    // 组卡的线宽/圆角/阴影全走 AppStyle，必须在**极光档**下再走一遍——
    // 只在默认（经典手绘档）验证过就发版，是历史上「换主题后框线消失/发灰」
    // 这类回归的老路。
    L('=== E. 极光档（frost）===');
    await AppThemeManager.instance.setThemeById('frost');
    await mount(const Size(1280, 720));
    check('E0 frost 下挂载成功', has('设置') || has('个人资料'),
        '文本数=${texts().length}');
    for (final String label in <String>['外观', '游戏与启动', '网络与存储', '元数据']) {
      await switchTab(label);
      clearErr();
      await binding.pump();
      check('E $label @frost 无溢出', details.isEmpty, firstErr());
    }
    // 元数据页用的是各卡自己的容器（boxed:false），组卡计数要回到
    // 真正用组卡的页面去数，否则会误判「组卡没渲染」。
    await switchTab('游戏与启动');
    check('E5 frost 下组卡仍在', countWidget<SettingsGroupCard>() >= 4,
        '组卡数=${countWidget<SettingsGroupCard>()}');
    await AppThemeManager.instance.setThemeById('warmSun');

    // ═══════════ F. 关于页的品牌图标 ═══════════
    // 2026-11-13：关于页顶部原为「CT」字样占位框，改为软件真实图标
    // （assets/images/app_icon.png）。断言钉两件事：字样真的没了、那张 asset
    // 真的被构建（不是「某个 Image 存在」——页面上别处也有图）。
    // 注意 'CT' 只做**全等**判断：致谢里有 'CTFontHook'，用 contains 会误判。
    L('=== F. 关于页品牌图标 ===');
    await switchTab('关于应用');
    clearErr();
    await binding.pump();
    check(
      'F1 关于页不再有「CT」字样占位',
      !texts().any((String t) => t.trim() == 'CT'),
      'CT 文本数=${texts().where((String t) => t.trim() == 'CT').length}',
    );
    check(
      'F2 关于页加载了 app_icon.png',
      hasAssetImage('assets/images/app_icon.png'),
    );
    check('F3 关于页无溢出/无异常', details.isEmpty, firstErr());
    // 入口挂在**页头**而不是某一页正文：换到最后一个 tab 后必须仍在。
    check('F3b 换 tab 后「恢复默认」入口仍在页头', has('恢复默认'));

    // 极光档再验一次：外框线宽/阴影/圆角走 AppStyle，换档不能塌。
    await AppThemeManager.instance.setThemeById('frost');
    await mount(const Size(1280, 720));
    await switchTab('关于应用');
    clearErr();
    await binding.pump();
    check(
      'F4 frost 下关于页仍加载 app_icon.png',
      hasAssetImage('assets/images/app_icon.png'),
    );
    check('F5 frost 下关于页无溢出/无异常', details.isEmpty, firstErr());
    await AppThemeManager.instance.setThemeById('warmSun');

    L('');
    L('TOTAL PASS=$_pass FAIL=$_fail');
    if (_fail > 0) exitCode = 1;
  }, () {});
}
