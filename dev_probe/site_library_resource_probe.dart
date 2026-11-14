// SITE-LIBRARY 全站库资源能力探针（flutter_tester）
//
// 两段：
//   A. 服务层真 HTTP e2e（binding 之前 —— dart:io 真 HttpClient，直连官方 API）
//      - letmoe 资源列表 / /file 下载方式 / works 批量摘要
//      - 2DFan 标题反查（正例 + 负例）+ 解析器直连
//   B. 渲染层（binding + 离线注入，⛔ 探针里不碰真网络 —— 测试 binding 是
//      FakeAsync，真请求永远挂起）
//      - SiteGameDetailPage：三按钮点亮 + 「全站库作品」文案 + 灰置项
//      - SiteLibraryResourcePanel：注入夹具（资源卡 / 筛选 / 未定位 / 无资源）
//
// 编译（⛔ platform dill 在 engine/common/flutter_patched_sdk/）：
//   dartaotruntime.exe gen_kernel_aot.dart.snapshot ^
//     --platform engine/common/flutter_patched_sdk/platform_strong.dill ^
//     --target flutter --packages .dart_tool/package_config.json ^
//     --output x.dill dev_probe\site_library_resource_probe.dart
//   flutter_tester.exe --disable-vm-service --enable-checked-mode x.dill
//
// 退出码：0 = 全绿；1 = 有失败。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import 'package:chrono_tide/pages/site_game_detail_page.dart';
import 'package:chrono_tide/services/site_search/site_library_install_flow.dart';
import 'package:chrono_tide/services/site_search/site_library_resource_service.dart';
import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/game_detail/game_detail_header.dart';
import 'package:chrono_tide/widgets/site_library/site_library_resource_panel.dart';

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

/// 渲染断言：Finder 有命中（不抛异常，计数继续）
void checkFound(String name, Finder f, [String detail = '']) {
  check(name, f.evaluate().isNotEmpty, detail);
}

Future<void> main() async {
  // ═══════════ A. 服务层真 HTTP e2e（binding 之前）═══════════
  L('=== A. letmoe 服务层真 HTTP ===');
  await stdout.flush();

  late final List<LetmoeResource> resources;
  try {
    L('A-pre 构造服务…');
    await stdout.flush();
    final svc = LetmoeResourceService();
    L('A-pre 发起 listWorkResources(2222)…');
    await stdout.flush();
    resources = await svc.listWorkResources('2222').timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            L('  [ABORT] listWorkResources 30s 超时');
            throw TimeoutException('listWorkResources');
          },
        );
    L('A-post 资源列表返回 ${resources.length} 条');
    await stdout.flush();
  } catch (e, st) {
    L('  [ABORT] listWorkResources 抛异常: $e');
    for (final l in st.toString().split('\n').take(12)) {
      L('      @ $l');
    }
    await stdout.flush();
    exitCode = 1;
    return;
  }
  check('A1 资源列表非空', resources.isNotEmpty, 'got ${resources.length}');
  if (resources.isNotEmpty) {
    final r0 = resources.first;
    check('A2 资源 id 为十进制字符串', int.tryParse(r0.id) != null, r0.id);
    check('A3 资源归属 work 2222', r0.workId == '2222', r0.workId);
    check('A4 有游戏本体类型', resources.any((r) => r.type == 'game'));
    check('A5 标题非空', r0.title.isNotEmpty, r0.title);
    L('      · 夹具: ${r0.title} | ${r0.size} | providers=${r0.providers}');
  }

  final files = await LetmoeResourceService().getResourceFile('12792');
  check('A6 /file 有镜像', files.mirrors.isNotEmpty,
      'mirrors=${files.mirrors.length}');
  if (files.mirrors.isNotEmpty) {
    final m0 = files.mirrors.first;
    check('A7 主镜像 URL 非空', m0.url.isNotEmpty, m0.url);
    check('A8 外链镜像分类正确', m0.isExternalLink && !m0.isHostedDirect,
        m0.kind);
    check('A9 解压密码透传',
        files.mirrors.any((m) => m.archivePassword == 'game'),
        files.mirrors.map((m) => m.archivePassword).join(','));
    check('A10 提取码透传（网盘）',
        files.mirrors.any((m) => m.extractCode.isNotEmpty),
        files.mirrors.map((m) => m.extractCode).join(','));
  }

  final summaries =
      await LetmoeResourceService().workSummaries(['2222', '999999999']);
  check('A11 works 批量：有资源的在列', summaries.any((s) => s.id == '2222'));
  check('A12 works 批量：无资源的进 missing',
      summaries.every((s) => s.id != '999999999'));
  for (final s in summaries) {
    if (s.id == '2222') {
      check('A13 摘要 resource_count>0', s.resourceCount > 0,
          '${s.resourceCount}');
    }
  }

  final nextmoe = NextMoeService();
  final resolved = await nextmoe.resolveWorkIdByTitle(['丸子与银河龙']);
  check('A14 2DFan 反查正例（中文名）→ 2222', resolved == '2222', 'got $resolved');
  final resolvedJa = await nextmoe.resolveWorkIdByTitle(['マルコと銀河竜']);
  check('A15 反查正例（日文原名）→ 2222', resolvedJa == '2222', 'got $resolvedJa');
  final resolvedNeg =
      await nextmoe.resolveWorkIdByTitle(['这个标题绝对不存在于目录QWERTY']);
  check('A16 反查负例 → null', resolvedNeg == null, 'got $resolvedNeg');
  final resolvedEmpty = await nextmoe.resolveWorkIdByTitle(<String>[]);
  check('A17 空标题链 → null', resolvedEmpty == null);

  final ctxMoyu = await SiteLibraryResourceResolver.instance
      .resolve(_detailHit(detailLoaded: true));
  check('A18 解析器：鲲命中直连 workId=2222',
      ctxMoyu.resolved && ctxMoyu.workId == 2222,
      'resolved=${ctxMoyu.resolved} workId=${ctxMoyu.workId}');
  check('A19 解析器：鲲命中拉到资源', ctxMoyu.resources.isNotEmpty,
      '${ctxMoyu.resources.length} 条');

  // ---- A20+ 组合包解析（2026-11-14 实测载荷）----
  // composites 响应里**没有 kind 字段**，旧实现按 external_link 兜底 ⇒ 被当成
  // 网盘塞进「分享」。这里锁死修复后的分类。
  final filesComposite = LetmoeResourceFiles.fromJson(<String, dynamic>{
    'resource_id': '1890',
    'mirrors': [
      {
        'id': '1890',
        'kind': 'hosted',
        'url': 'https://dl.imoe.uk/letmoe/d6cea508-f344-4783-b9b7-7f1ceaf66835.zip',
        'is_primary': true,
      }
    ],
    'composites': [
      {
        'object': 'letmoe_composite',
        'id': '261',
        'url': 'https://dl.imoe.uk/c/letmoe/22bdede256209bd86039f9a856e2dedd.zip',
        'filename': '保健室のセンセー + 【终焉汉化组】人工汉化补丁.zip',
        'bytes': 2168434204,
        'patch': {
          'moyu_resource_id': '5926',
          'name': '【终焉汉化组】保健室のセンセー - 人工汉化补丁',
          'language': ['zh-Hans'],
        },
      }
    ],
  });
  check('A20 组合包被识别为托管直链（缺 kind 不再误判网盘）',
      filesComposite.composites.length == 1 &&
          filesComposite.composites.first.isHostedDirect &&
          !filesComposite.composites.first.isExternalLink,
      filesComposite.composites.map((m) => m.kind).join(','));
  check('A21 组合包 isComposite + patchName 解析',
      filesComposite.composites.first.isComposite &&
          filesComposite.composites.first.patchName.contains('终焉汉化组'),
      filesComposite.composites.first.patchName);
  check('A22 组合包 bytes / filename 解析',
      filesComposite.composites.first.bytes == 2168434204 &&
          filesComposite.composites.first.fileName.endsWith('.zip'),
      '${filesComposite.composites.first.bytes} | '
          '${filesComposite.composites.first.fileName}');
  check('A23 「获取」清单 = 托管直链 + 组合包（共 2 条）',
      filesComposite.downloadableArchives.length == 2);
  check('A24 「分享」清单不含组合包（真网盘才进分享）',
      filesComposite.netdiskLinks.isEmpty,
      filesComposite.netdiskLinks.map((m) => m.url).join(','));

  check('A25 合成 gameId = site:<源key>:<站点id>',
      SiteLibraryInstallFlow.buildGameId(_detailHit(detailLoaded: true)) ==
          'site:moyu:2222',
      SiteLibraryInstallFlow.buildGameId(_detailHit(detailLoaded: true)));

  // 2026-11-14 实测：纯直链资源的 providers 是占位值 ['direct']（work 2222 / r8205），
  // 按「providers 非空」判定会被「分享」模式误收，展开却一条网盘链接都没有。
  final directOnly = LetmoeResource.fromJson(<String, dynamic>{
    'id': '8205',
    'work_id': '2222',
    'title': '丸子与银河龙 直链版',
    'type': 'game',
    'providers': ['direct'],
    'direct_download': true,
  });
  check('A26 纯直链资源（providers=[direct]）不算网盘渠道',
      !directOnly.hasNetdiskProviders && directOnly.isDirectOnly,
      'providers=${directOnly.providers}');

  // ═══════════ B. 渲染层（binding，离线注入）═══════════
  L('=== B. 渲染层 ===');
  final binding = AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  // 探针没走 main.dart 启动链，必须手动注册内置主题（否则 AppThemeManager 抛 null）
  ThemeRegistry.registerBuiltinThemes();

  await binding.runTest(() async {
    // ---- B1. 详情页三按钮点亮 ----
    await _pumpApp(SiteGameDetailPage(
      hit: _detailHit(detailLoaded: true),
      onBack: () {},
    ));
    checkFound('B0 「全站库作品」文案', find.text('全站库作品'));
    final header = _headerOf();
    check('B1 获取按钮点亮', header.getEnabled && header.onGet != null);
    check('B2 分享按钮点亮', header.shareEnabled && header.onShare != null);
    check('B3 补丁按钮点亮', header.patchEnabled && header.onPatch != null);
    check('B4 上传仍灰置', !header.uploadEnabled);
    check('B5 喜欢/反馈仍灰置',
        !header.likeEnabled && !header.feedbackEnabled);
    check('B6 补丁按钮 key 已挂（锚定用）', header.patchButtonKey != null);
    check('B7 操作行 key 已挂（锚定用）', header.actionRowKey != null);
    checkFound('B8 按钮行文案齐全', find.text('上传'));

    // ---- B2. 获取入口 = 直链模式（只列直链资源）----
    final hit = _detailHit(detailLoaded: true);
    final ctx = SiteLibraryResourceContext(
      hit: hit,
      workId: 2222,
      resolved: true,
      resources: [_fixtureResource(), _hostedResource()],
    );
    await _pumpApp(SiteLibraryResourcePanel(hit: hit, initialContext: ctx));
    checkFound('B9 面板标题（获取 = 下载并安装）', find.text('下载并安装'));
    checkFound('B10 直链资源上屏', find.textContaining('letmoe 托管直链'));
    check(
        'B11 网盘专属资源不进直链模式',
        find.textContaining('简体中文游戏本体资源下载').evaluate().isEmpty);
    checkFound('B12 「可直链下载」徽章', find.text('可直链下载'));
    check('B13 直链模式不显示网盘渠道徽章',
        find.text('夸克网盘').evaluate().isEmpty);
    checkFound('B14 计数徽章「1 条」', find.text('1 条'));
    check(
        'B15 旧筛选 chips 已移除（全部/可下载）',
        find.text('全部 2').evaluate().isEmpty &&
            find.text('可下载 1').evaluate().isEmpty);

    // ---- B3. 分享入口 = 网盘模式（只列网盘资源）----
    await _pumpApp(SiteLibraryResourcePanel(
      hit: hit,
      mode: SiteLibraryResourceMode.netdisk,
      initialContext: ctx,
    ));
    checkFound('B16 面板标题（分享 = 网盘分享）', find.text('网盘分享'));
    checkFound(
        'B17 网盘资源上屏（两条都有网盘渠道）',
        find.textContaining('丸子与银河龙'));
    checkFound('B18 网盘渠道徽章（夸克）', find.text('夸克网盘'));
    check('B19 网盘模式不显示「可直链下载」徽章',
        find.text('可直链下载').evaluate().isEmpty);
    checkFound('B20 计数徽章「2 条」', find.text('2 条'));

    // ---- B4. 直链模式但只有网盘资源 → 明确引导去「分享」----
    await _pumpApp(SiteLibraryResourcePanel(
      hit: hit,
      initialContext: SiteLibraryResourceContext(
        hit: hit,
        workId: 2222,
        resolved: true,
        resources: [_fixtureResource()],
      ),
    ));
    checkFound('B21 直链空态文案', find.text('没有可直链下载的资源'));
    checkFound(
        'B22 空态引导去「分享」',
        find.textContaining('点「分享」'));

    // ---- B5. 面板：未定位态（2DFan 反查失败兜底）----
    await _pumpApp(SiteLibraryResourcePanel(
      hit: hit,
      initialContext: SiteLibraryResourceContext.unresolved(hit),
    ));
    checkFound('B23 未定位文案', find.text('未能在鲲生态定位到这部作品'));
    checkFound('B24 兜底外跳按钮', find.text('打开 2DFan 作品页'));

    // ---- B6. 面板：定位到但无资源 ----
    await _pumpApp(SiteLibraryResourcePanel(
      hit: hit,
      initialContext: SiteLibraryResourceContext(
        hit: hit,
        workId: 2222,
        resolved: true,
        resources: const <LetmoeResource>[],
      ),
    ));
    checkFound('B25 无资源文案', find.text('该作品暂无资源'));
    checkFound('B26 letmoe 页面外跳按钮', find.text('打开 letmoe 页面'));
  }, () {});

  L('\n--- 结果: $_pass 通过 / $_fail 失败 ---');
  if (_fail > 0) exitCode = 1;
}

// ==================== 夹具与工具 ====================

SiteSearchHit _detailHit({required bool detailLoaded}) {
  return SiteSearchHit(
    source: SiteSearchSource.moyu,
    siteId: '2222',
    title: '丸子与银河龙',
    originalTitle: 'マルコと銀河竜',
    aliasNames: const ['Marco to Ginga Ryuu'],
    summary: '漂浮在大海上的小孤岛“天使岛”……（测试简介，探针夹具）',
    detailUrl: 'https://www.kungal.com/galgame/2222',
    detailLoaded: detailLoaded,
  );
}

/// 真实载荷裁剪夹具（2026-11-13 curl 实测 work 2222 资源 12792）
LetmoeResource _fixtureResource() {
  return LetmoeResource.fromJson(<String, dynamic>{
    'id': '12792',
    'work_id': '2222',
    'title': '丸子与银河龙 Windows 电脑版 / 安卓手机版 简体中文游戏本体资源下载',
    'type': 'game',
    'language': ['zh-cn'],
    'platform': ['win', 'and'],
    'size': '9.8 GB',
    'bytes': 10522669875,
    'description': '解压密码：game',
    'providers': ['baidu', 'quark'],
    'direct_download': false,
    'mirror_count': 2,
    'web_url': 'https://www.letmoe.com/resource/12792',
  });
}

/// 合成夹具：托管直链资源（direct_download = true）
LetmoeResource _hostedResource() {
  return LetmoeResource.fromJson(<String, dynamic>{
    'id': '30001',
    'work_id': '2222',
    'title': '丸子与银河龙 PC 汉化硬盘版（letmoe 托管直链）',
    'type': 'game',
    'platform': ['win'],
    'size': '2.1 GB',
    'providers': ['quark'],
    'direct_download': true,
    'mirror_count': 1,
    'web_url': 'https://www.letmoe.com/resource/30001',
  });
}

/// 复刻主壳挂载：MaterialApp（UniqueKey 防 Overlay 复用，patch_ui_probe 同款）
Future<void> _pumpApp(Widget child) async {
  final binding = AutomatedTestWidgetsFlutterBinding.instance;
  binding.attachRootWidget(binding.wrapWithDefaultView(_app(child)));
  await binding.pump();
  await binding.pump(const Duration(milliseconds: 80));
}

Widget _app(Widget child) => MaterialApp(
      // 🔴 每次换 key：Element 复用 MaterialApp 会连带复用 Overlay
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      builder: (context, inner) {
        final base = MediaQuery.of(context);
        return MediaQuery(
          data: base.copyWith(size: const Size(1280, 720)),
          child: inner ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(backgroundColor: const Color(0xFF1E1E1E), body: child),
    );

GameDetailHeader _headerOf() {
  final finder = find.byType(GameDetailHeader);
  return finder.evaluate().first.widget as GameDetailHeader;
}
