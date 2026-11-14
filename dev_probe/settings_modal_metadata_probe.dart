/// 「设置 → 元数据」整屏渲染探针（flutter_tester）。
///
/// 🔴 项目铁律：改动落在哪个页面的 build，就必须把**那个页面整屏渲染一次**，
/// 且必须断言「必然存在的文案」——整树塌成 ErrorWidget 时文本数=0 也会假绿。
///
/// 覆盖：1280×720 正常窗 + 820×520 最小窗（_kMinHeight=520）不溢出，
/// 以及负向对照（不该出现的旧文案 / 其他 tab 的卡片）。
///
/// 编译 / 运行（apps/chrono-tide 下）：
///   dartaotruntime <gen_kernel_aot.dart.snapshot> --platform \
///     <engine/common/flutter_patched_sdk>/platform_strong.dill --target flutter \
///     --packages .dart_tool/package_config.json --output x.dill 本文件
///   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/services/metadata_credentials.dart';
import 'package:chrono_tide/services/metadata_field_priority.dart';
import 'package:chrono_tide/services/metadata_refresh_service.dart';
import 'package:chrono_tide/widgets/interactive_wrapper.dart';
import 'package:chrono_tide/widgets/settings_modal.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

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

/// 顺序敏感的列表比较（优先级链只关心「谁在前」）。
bool _sameOrder(List<SourceType> a, List<SourceType> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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

  final prevOnError = FlutterError.onError;
  await binding.runTest(() async {
    FlutterError.onError = (FlutterErrorDetails d) => details.add(d);

    void clearErr() => details.clear();
    String firstErr() {
      if (details.isEmpty) return '';
      final String e = details.first.exception.toString();
      return e.length > 200 ? e.substring(0, 200) : e;
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
      // 账号卡 initState 里读 prefs 是异步的，再 pump 两轮让列表出来
      await binding.pump(const Duration(milliseconds: 120));
      await binding.pump(const Duration(milliseconds: 120));
    }

    List<String> texts() {
      final out = <String>[];
      final Element? root = binding.renderViewElement;
      if (root != null) _collectText(root, out);
      return out;
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
      check('切到「$label」找到侧栏入口', ok);
      await binding.pump();
      await binding.pump(const Duration(milliseconds: 80));
      await binding.pump(const Duration(milliseconds: 120));
    }

    bool has(String needle) => texts().any((String t) => t.contains(needle));

    /// 精确统计「Text 控件」出现次数。
    ///
    /// 🔴 不能用 texts() 计数：`Text` 会构出 `RichText` 子节点，
    /// 收集器把两者都记一次 ⇒ 每个文案都会翻倍；而且 `DropdownButton`
    /// 会把所有 items 放进 IndexedStack（都建在树里，只是不绘制），
    /// 所以「平台名」出现次数天然大于卡片数。判据只落在 Text 上。
    int countText(String exact) {
      int n = 0;
      void walk(Element e) {
        final Widget w = e.widget;
        if (w is Text && w.data == exact) n++;
        e.visitChildren(walk);
      }

      final Element? root = binding.renderViewElement;
      if (root != null) walk(root);
      return n;
    }

    // ═══════════ A. 元数据页 · 1280×720 ═══════════
    L('=== A. 元数据页 1280×720 ===');
    await mount(const Size(1280, 720));
    check('A0 设置窗口挂载成功（防 ErrorWidget 假绿）',
        has('设置 / Settings') || has('个人资料'), '文本数=${texts().length}');

    await switchTab('元数据');
    final List<String> a = texts();
    bool hasAll(List<String> needles) =>
        needles.every((String n) => a.any((String t) => t.contains(n)));

    check('A1 四个分组标题齐全', hasAll(<String>['平台账号与凭证', '元数据拉取来源', '字段优先级', '全量更新元数据']));
    check('A2 账号区只列四家有登录价值的平台',
        hasAll(<String>['Bangumi', '鲲GAL/NextMoe', 'Hikarinagi', '2DFan']));
    // 四张卡 ⇒ 三个「未登录」胶囊 + 一个「内置凭据」。用全等匹配，
    // 避免把说明文案里的「未登录时站点只回…」也算进去。
    final int notLoginBadges = countText('未登录');
    final int builtInBadges = countText('内置凭据');
    check('A3 账号卡数量＝4（状态胶囊计数）',
        notLoginBadges == 3 && builtInBadges == 1,
        '未登录=$notLoginBadges 内置=$builtInBadges');
    check('A3b 免登录平台改为一句话说明（不再放假输入框）',
        has('其余平台（VNDB / CT 探索库 / Steam / 月幕 GAL）走公开接口'));
    check('A3c 鲲GAL 与 NextMoe 合并成一张卡（旧标题不再出现）',
        countText('鲲GAL/NextMoe') >= 2 &&
            countText('鲲 Galgame') == 0 &&
            countText('NextMoe') == 0,
        '鲲GAL/NextMoe=${countText('鲲GAL/NextMoe')}');
    check('A4 Bangumi 凭证控件', has('保存并验证') && has('获取令牌'));
    check('A5 Bangumi 说明为何不用 OAuth（拿不到 client_secret）',
        has('OAuth 需要应用密钥'));
    // 🔴 2026-11-13 用户裁决「登录暂时先不做」：一键登录入口全部关闭，
    // 只留基础凭证（Bangumi 令牌 / 鲲 Cookie / 2DFan Cookie / Hikarinagi 内置）。
    // 这里钉的是「关得干净」——按钮不残留、但用户看得懂为什么没有。
    check('A5 快捷登录入口全部关闭（用户裁决：暂时不做登录）',
        countText('使用 NextMoe 账号登录') == 0 &&
            countText('使用 Hikarinagi 账号登录') == 0 &&
            !has('登录不成功？改用 Cookie 手动登录'),
        'NextMoe=${countText('使用 NextMoe 账号登录')} '
        'Hikari=${countText('使用 Hikarinagi 账号登录')}');
    check('A5b 2DFan 仍是 Cookie：保存 + 清除 + 打开站点',
        has('保存') && has('清除') && has('打开站点'));
    check('A5c 鲲 Cookie 直接展开（不再藏在折叠链接后）',
        has('粘贴 kungal.com 的 Cookie') && has('保存并验证'));
    check('A5d 关闭时给一句交代（不是白丢按钮）',
        has('快捷登录暂未开放'));
    check('A6 Hikarinagi 保留连通性测试 + 内置凭据说明',
        has('测试连通性') &&
            has('快捷登录暂未开放；本平台凭据已内置'));
    check('A7 MIX 整合卡', has('整合源（MIX）'));
    check('A8 字段优先级 7 项', hasAll(<String>[
          '封面',
          '截图',
          '评分 / 投票数',
          '简介',
          '标签',
          '会社（开发商）',
          '主标题（中文名）',
        ]));
    check('A9 每项有「当前顺序」说明', has('当前顺序：'));
    check('A10 构建无异常 / 无溢出', details.isEmpty, firstErr());

    // 负向对照：不再有「同步」语义（我们不做云端状态同步）
    check('A11 负向：没有收藏/游玩状态同步开关',
        !a.any((String t) => t.contains('收藏同步')) &&
            !a.any((String t) => t.contains('游玩状态同步')));
    // 负向对照：切页正确（网络页的卡片不该出现在这里）
    check('A12 负向：没有网络代理设置卡片',
        !a.any((String t) => t.contains('网络代理设置')));

    // 全量更新卡（idle 态）
    check('A13 全量更新卡：主动作与覆盖开关',
        has('更新全部游戏元数据') && has('覆盖已有字段'), '文本数=${a.length}');
    check('A14 全量更新卡：明确「不会动什么」',
        has('不会动：标题') && has('封面与截图由各自的后台补全机制负责'));
    // 负向对照：LunaBox 的「批评空间网址」输入我们不做（该功能已移除）。
    // 注意不能直接用 contains('ErogameScape') 判定 —— NextMoe 卡片的一句简介
    // 里本来就写着「六源对齐目录（VNDB / Bangumi / DLsite / ErogameScape 等）」，
    // 那是**事实描述**，不是被移除的网址输入控件。判据要落在「网址输入」上。
    check(
        'A15 负向：没有批评空间 / ErogameScape 网址输入',
        !a.any((String t) => t.contains('批评空间')) &&
            !a.any((String t) =>
                t.contains('ErogameScape 网址') || t.contains('ErogameScape网址')),
        '命中=${a.where((String t) => t.contains('批评空间')).join(" | ")}');

    // ═══════════ B. 最小窗口 820×520 ═══════════
    L('=== B. 元数据页 820×520（最小窗口）===');
    await mount(const Size(820, 520));
    await switchTab('元数据');
    final List<String> b = texts();
    check('B1 最小窗口下四组标题仍在',
        b.any((String t) => t.contains('平台账号与凭证')) &&
            b.any((String t) => t.contains('元数据拉取来源')) &&
            b.any((String t) => t.contains('全量更新元数据')));
    check('B2 最小窗口下 Bangumi 卡片可见', b.any((String t) => t.contains('Bangumi')));
    check('B3 构建无异常 / 无 RenderFlex 溢出', details.isEmpty, firstErr());

    // ═══════════ C. 切走再切回（状态不崩）═══════════
    L('=== C. 切到「关于应用」再切回「元数据」===');
    await mount(const Size(1280, 720));
    await switchTab('关于应用');
    check('C0 关于页仍正常', has('开源组件致谢'));
    await switchTab('元数据');
    check('C1 切回元数据页仍完整',
        has('平台账号与凭证') && has('整合源（MIX）'));
    check('C2 构建无异常', details.isEmpty, firstErr());

    // ═══════════ D. 全量更新卡 · 运行时分支 ═══════════
    // 进度条与失败清单是「只有跑起来才会出现」的分支，只渲染 idle 态
    // 等于没验证过它们 —— 而它们恰恰是最容易横向溢出的部分。
    L('=== D. 全量更新卡 · 运行中 / 失败态 ===');
    const String longTitle =
        'この大空に、翼をひろげて GIRLS AIRPLANE 完全生産限定版 中文补丁版';
    final List<MetadataRefreshFailure> fails = <MetadataRefreshFailure>[
      for (int i = 0; i < 6; i++)
        MetadataRefreshFailure(
          gameId: 'id-$i',
          title: '$longTitle #$i',
          reason: '各平台均无匹配条目',
        ),
    ];

    // D1–D3：运行中
    void emit(MetadataRefreshProgress p) {
      // ignore: invalid_use_of_visible_for_testing_member
      MetadataRefreshService.instance.emitForTest(p);
    }

    emit(MetadataRefreshProgress(
      phase: MetadataRefreshPhase.running,
      total: 128,
      done: 42,
      updated: 30,
      unchanged: 9,
      failed: 3,
      currentTitle: longTitle,
    ));
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    final List<String> d = texts();
    check('D1 运行中：进度文案与百分比',
        d.any((String t) => t.contains('正在刷新 42/128')) && has('%'));
    check('D2 运行中：按钮变「取消」', has('取消'));
    check('D3 运行中：长标题不溢出、无异常', details.isEmpty, firstErr());

    // D4–D6：跑完且有失败项
    emit(MetadataRefreshProgress(
      phase: MetadataRefreshPhase.finished,
      total: 128,
      done: 128,
      updated: 90,
      unchanged: 33,
      failed: 5,
      failures: fails,
    ));
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    final List<String> d2 = texts();
    check('D4 完成态：汇总行含更新/失败计数',
        d2.any((String t) => t.contains('更新 90') && t.contains('失败 5')));
    check('D5 失败清单与重试入口',
        d2.any((String t) => t.contains('未成功（6）')) && has('重试失败项（6）'),
        '重试文案=${d2.where((String t) => t.contains('重试失败项')).join("|")}');
    check('D6 完成态：无 RenderFlex 溢出', details.isEmpty, firstErr());

    // D7：最小窗口下的失败态（最容易溢出的组合）
    await mount(const Size(820, 520));
    await switchTab('元数据');
    emit(MetadataRefreshProgress(
      phase: MetadataRefreshPhase.finished,
      total: 128,
      done: 128,
      updated: 90,
      unchanged: 33,
      failed: 5,
      failures: fails,
    ));
    await binding.pump();
    await binding.pump(const Duration(milliseconds: 60));
    check('D7 最小窗口 + 失败清单：无溢出', details.isEmpty, firstErr());
    MetadataRefreshService.instance.resetForTest();

    // ═══════════ E. 纯函数：优先级链 / 鲲探测判据 / Cookie 形态 ═══════════
    // 这三处是「静默失效」高发区：错了不报错，只是数据悄悄从别的源来。
    L('=== E. 纯函数判据 ===');
    const Map<String, List<SourceType>> builtinPrio = <String, List<SourceType>>{
      'cover_url': <SourceType>[
        SourceType.nextmoe,
        SourceType.ct,
        SourceType.twoDfan,
        SourceType.vndb,
        SourceType.kun,
      ],
    };

    List<SourceType> chain(List<SourceType>? override) =>
        MetadataFieldPriority.resolveChain(
            'cover_url', override, builtinPrio);

    check('E1 无覆盖 → 内置链原样',
        _sameOrder(
            chain(null),
            <SourceType>[
              SourceType.nextmoe,
              SourceType.ct,
              SourceType.twoDfan,
              SourceType.vndb,
              SourceType.kun,
            ]));
    check('E2 空列表覆盖 → 视为无覆盖（脏数据不炸）',
        _sameOrder(chain(<SourceType>[]), builtinPrio['cover_url']!));
    check('E3 单源覆盖 → 提到首位，其余顺序不变、不重复',
        _sameOrder(
            chain(<SourceType>[SourceType.vndb]),
            <SourceType>[
              SourceType.vndb,
              SourceType.nextmoe,
              SourceType.ct,
              SourceType.twoDfan,
              SourceType.kun,
            ]));
    check('E4 组覆盖（鲲GAL/NextMoe）→ 两个源一起提前且保持组内顺序',
        _sameOrder(
            chain(<SourceType>[SourceType.nextmoe, SourceType.kun]),
            <SourceType>[
              SourceType.nextmoe,
              SourceType.kun,
              SourceType.ct,
              SourceType.twoDfan,
              SourceType.vndb,
            ]));
    check('E5 覆盖已在链首 → 链不变',
        _sameOrder(chain(<SourceType>[SourceType.nextmoe]),
            builtinPrio['cover_url']!));
    check('E6 覆盖不在链内 → 插到首位，其余一个都不丢',
        MetadataFieldPriority.resolveChain('cover_url',
                <SourceType>[SourceType.steam], builtinPrio)
            .length ==
            6);

    // 鲲：200 也可能是「未登录」，必须看 code
    check(
        'E7 鲲 200 + code 205 → 判为需要登录（不是成功）',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 200, body: <String, dynamic>{'code': 205})
            ==
            KunProbeVerdict.loginRequired);
    check(
        'E8 鲲 401 → 判为需要登录',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 401, body: null) ==
            KunProbeVerdict.loginRequired);
    check(
        'E9 鲲 200 + code 0 → 通过',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 200,
                body: <String, dynamic>{
                  'code': 0,
                  'data': <String, dynamic>{'items': <dynamic>[]}
                }) ==
            KunProbeVerdict.ok);
    check(
        'E10 鲲 200 + 其它 code → 明确拒绝',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 200,
                body: <String, dynamic>{'code': 403, 'message': '封禁'}) ==
            KunProbeVerdict.rejected);
    check(
        'E11 鲲 非 JSON → 无法判断（不假装成功）',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 200, body: '<html>') ==
            KunProbeVerdict.unknown);

    check('E12 Cookie 形态：正常单行通过',
        MetadataCredentialService.validateCookieShape('a=1; b=2') == null);
    check('E13 Cookie 形态：多行 / 无等号 / 过短都要拒绝',
        MetadataCredentialService.validateCookieShape('a=1\nb=2') != null &&
            MetadataCredentialService.validateCookieShape('abcdefgh') !=
                null &&
            MetadataCredentialService.validateCookieShape('a=1') != null);
    check('E14 负向：鲲的空 Cookie 不当作已登录',
        MetadataCredentialService.interpretKunProbe(
                statusCode: 200, body: <String, dynamic>{'code': 205}) !=
            KunProbeVerdict.ok);

    // ═══════════ F. 已登录态（预置令牌 → UI 必须真的变）═══════════
    // 登录态只在「浏览器里授权成功」后才出现，靠手点无法复现；
    // 这里直接把令牌写进 mock prefs，走 hydrate 的真实读盘路径。
    L('=== F. 已登录态 ===');
    final int futureMs =
        DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch;
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{
      'oauth_token_v1_nextmoe': jsonEncode(<String, dynamic>{
        'access_token': 'at-nextmoe',
        'refresh_token': 'rt-nextmoe',
        'expires_at': futureMs,
        'scope': 'openid profile catalog:read',
        'account_name': '汐',
      }),
      'oauth_token_v1_hikarinagi': jsonEncode(<String, dynamic>{
        'access_token': 'at-hikari',
        'refresh_token': 'rt-hikari',
        'expires_at': futureMs,
        'scope': 'openid user:read',
        'account_name': 'Hikari',
      }),
    });
    await mount(const Size(1280, 720));
    await switchTab('元数据');
    check('F1 两个平台都显示「已登录」胶囊',
        countText('已登录') == 2, 'count=${countText('已登录')}');
    check('F2 显示账号昵称（不是只显示平台名）',
        has('已登录：汐') && has('已登录：Hikari'));
    check('F3 已登录后不再出现一键登录按钮',
        countText('使用 NextMoe 账号登录') == 0 &&
            countText('使用 Hikarinagi 账号登录') == 0);
    check('F4 已登录后鲲的 Cookie 输入收起（令牌优先）',
        !has('粘贴 kungal.com 的 Cookie'));
    check('F5 两个「退出登录」+ 令牌只存本机提示',
        countText('退出登录') == 2 && has('令牌只存在本机'),
        'count=${countText('退出登录')}');
    check('F6 已登录态无溢出', details.isEmpty, firstErr());

    await mount(const Size(820, 520));
    await switchTab('元数据');
    check('F7 最小窗口下已登录态无溢出', details.isEmpty, firstErr());

    FlutterError.onError = prevOnError;
  }, () {});

  ErrorWidget.builder = prevBuilder;
  L('TOTAL PASS=$_pass FAIL=$_fail');
  if (_fail > 0) exitCode = 1;
}
