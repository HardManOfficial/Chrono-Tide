import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/models/game_resource_model.dart';
import 'package:chrono_tide/widgets/game_detail/ct_download_dialog.dart';

/// 「Chrono Tide 下载」浮层的版本信息展示回归测试（2026-10-09 真机反馈）。
///
/// 背景：云端 `games` 的版本信息有**两项** —— `version`（版本号，如
/// 「模拟器版+NS」）与 `versionNote`（版本说明，长文本）。改造前底部只取
/// `versionLabel`（说明优先 ⇒ 版本号被丢弃），且把长说明塞进单行 `DarkBadge`
/// ⇒ ① 版本号永不显示；② 长说明横向超出浮层被裁掉（「显示不完整」）。
///
/// 本用例锁住三条行为：版本号进顶部徽章行（紧邻平台）、版本说明整行换行
/// 完整展示、超长说明不产生横向溢出（`takeException()` 为 null）。
void main() {
  OfficialResourceView _view({
    String version = '',
    String versionNote = '',
    String path = '/games/tsukihime.zip',
    String fileSize = '0.944 GB',
    String title = '游戏本体',
  }) =>
      OfficialResourceView(
        downloadPath: path,
        title: title,
        version: version,
        versionNote: versionNote,
        fileSize: '0.944 GB',
        downloadCount: 245,
        ownerName: '时之 汐乃',
        resourceTypes: const [],
        platforms: const [],
        created: DateTime(2026, 9, 1),
      );

  Future<void> _pump(WidgetTester tester, OfficialResourceView res) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CtDownloadDialog(
              gameTitle: '月姬',
              resource: res,
              state: ResourceInstallState.idle,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('版本号进顶部徽章行，版本说明完整换行展示', (tester) async {
    const note = 'Type-MOON 经典同人游戏《月姬》重制版的上半部分，本体内已内置 '
        'ryujinx 龙神模拟器，解压即玩；下半部分另册发行，两者存档不通用。';
    await _pump(
      tester,
      _view(version: '模拟器版+NS', versionNote: note),
    );

    // 平台徽章仍在（版本号要「放在 Windows 的旁边」）
    expect(find.text('Windows'), findsOneWidget);
    // 版本号徽章出现（此前被 versionLabel 吞掉）
    expect(find.text('模拟器版+NS'), findsOneWidget);
    // 版本说明整行完整出现
    final noteFinder = find.text(note);
    expect(noteFinder, findsOneWidget);

    // 长说明按多行渲染（单行高度 = 10.5 * 1.4 = 14.7，超过即已换行）
    expect(tester.getSize(noteFinder).height, greaterThan(16));
    // 且没有横向溢出（宽度不超过浮层可用内容宽 ~477）
    expect(tester.getSize(noteFinder).width, lessThanOrEqualTo(478));

    expect(tester.takeException(), isNull);
  });

  testWidgets('超长版本说明不发生横向溢出', (tester) async {
    final long = '这是一个用于验证换行的超长版本说明文本。' * 12;
    await _pump(tester, _view(version: 'v1.0', versionNote: long));

    final size = tester.getSize(find.text(long));
    expect(size.width, lessThanOrEqualTo(478));
    expect(size.height, greaterThan(16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('版本号为空时不渲染版本徽章', (tester) async {
    await _pump(tester, _view(version: '', versionNote: '仅有版本说明'));

    expect(find.text('仅有版本说明'), findsOneWidget);
    expect(find.byIcon(Icons.local_offer_outlined), findsNothing);
    expect(find.text('模拟器版+NS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('版本号与版本说明同时为空时不渲染对应行', (tester) async {
    await _pump(tester, _view());

    expect(find.byIcon(Icons.local_offer_outlined), findsNothing);
    expect(find.byIcon(Icons.notes_rounded), findsNothing);
    // 大小徽章仍在
    expect(find.text('0.944 GB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ============================================================
  // 「下载」回调三分（2026-10-16：修复取链接失败静默无提示）
  // ============================================================

  /// 带 onDownload 的挂载（浮层是 home 路由即可 —— failed/cancelled 不会 pop）。
  Future<void> pumpWith(
    WidgetTester tester,
    Future<CtDownloadOutcome> Function(OfficialResourceView)? onDownload, {
    ResourceInstallState state = ResourceInstallState.idle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CtDownloadDialog(
              gameTitle: '月姬',
              resource: _view(),
              state: state,
              onDownload: onDownload,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('failed → 浮层内联红字，且按钮恢复可点（可原地重试）',
      (tester) async {
    await pumpWith(
      tester,
      (_) async => const CtDownloadOutcome.failed('下载链接获取失败，请稍后重试'),
    );

    // 初始：无错误行、按钮可点
    expect(find.text('下载链接获取失败，请稍后重试'), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    // 失败文案内联出现，且按钮回到可点状态（tooltip 变「重试下载」）
    expect(find.text('下载链接获取失败，请稍后重试'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 再点一次：错误行先清空，再次失败后重新出现
    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();
    expect(find.text('下载链接获取失败，请稍后重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled → 不显示任何错误（用户主动取消不是错误）',
      (tester) async {
    await pumpWith(tester, (_) async => const CtDownloadOutcome.cancelled());

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('进行态：回调未返回时按钮转圈且拒绝重复点击', (tester) async {
    final completer = Completer<CtDownloadOutcome>();
    await pumpWith(tester, (_) => completer.future);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pump(); // 进入 busy 的一帧

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    // 完成 → 失败文案出现，按钮恢复
    completer.complete(const CtDownloadOutcome.failed('网络异常'));
    await tester.pumpAndSettle();
    expect(find.text('网络异常'), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('started → 不显示错误，并关闭浮层（作为路由时）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => Dialog(
                    child: CtDownloadDialog(
                      gameTitle: '月姬',
                      resource: _view(),
                      state: ResourceInstallState.idle,
                      onDownload: (_) async =>
                          const CtDownloadOutcome.started(),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    // 已发起 → 浮层关闭
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ============================================================
  // 多资源（MULTI-RESOURCE，2026-11-03）
  // ============================================================

  testWidgets('多资源：每条一个下载按钮，点哪条回调就拿到哪条', (tester) async {
    final first = _view(version: '原版', path: '/games/a.zip');
    final second = _view(
      version: '重制版',
      path: '/games/b.zip',
      // 非主资源必须显示自己的 file_size（主资源才用 fallbackFileSize 兜底）
      fileSize: '12.4 GB',
    );

    OfficialResourceView? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CtDownloadDialog(
              gameTitle: '月姬',
              resources: [first, second],
              state: ResourceInstallState.idle,
              panelWidth: 560,
              onDownload: (r) async {
                tapped = r;
                return const CtDownloadOutcome.cancelled();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.download_rounded), findsNWidgets(2));
    expect(find.text('共 2 个版本'), findsOneWidget);
    expect(find.text('原版'), findsOneWidget);
    expect(find.text('重制版'), findsOneWidget);
    // 非主资源用自己的大小，不被主资源的 fallback 覆盖
    expect(find.text('12.4 GB'), findsOneWidget);

    // 点第二个按钮 → 回调必须拿到第二条（改造前永远只有一条，无从选择）
    await tester.tap(find.byIcon(Icons.download_rounded).at(1));
    await tester.pumpAndSettle();
    expect(tapped, isNotNull);
    expect(tapped!.version, '重制版');
    expect(tapped!.downloadPath, '/games/b.zip');
    expect(tester.takeException(), isNull);
  });

  testWidgets('多资源：条数超出可用高度时内部滚动，不溢出也不被裁', (tester) async {
    final many = [
      for (var i = 0; i < 8; i++)
        _view(version: 'v${i + 1}', path: '/games/v$i.zip'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              height: 520, // 模拟 showDarkAnchoredPanel 给的 maxHeight
              child: CtDownloadDialog(
                gameTitle: '月姬',
                resources: many,
                state: ResourceInstallState.idle,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 有界高度下必须走滚动容器（否则 8 条会被 dark_surface 的 maxHeight 裁掉）
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(
      tester.getSize(find.byType(CtDownloadDialog)).height,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('单资源仍走向后兼容路径（resources 为空时用 resource）',
      (tester) async {
    await _pump(tester, _view(version: 'v1'));

    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    // 只有一条时不出现「共 N 个版本」徽章，视觉与改造前一致
    expect(find.textContaining('个版本'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
