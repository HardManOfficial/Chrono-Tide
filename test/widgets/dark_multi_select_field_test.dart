import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/widgets/game_detail/upload_resource_dialog.dart';

/// `DarkMultiSelectField` 的自由输入（allowCustom）回归测试。
///
/// 背景：云端 `games.tags` 此前只能选客户端硬编码的既有标签。2026-10-06 起
/// 服务端 `tags_autovalues.pb.js` 会自动登记新词，组件新增自由输入能力。
/// 本用例锁住两条行为：默认不带输入框（其余 3 处调用点行为不变）、
/// 开启后自定义词能进选中集并回调外部。
void main() {
  testWidgets('默认不显示自定义输入框', (tester) async {
    Set<String> selected = {'日常'};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => DarkMultiSelectField(
            label: '标签',
            options: const ['日常', '校园'],
            selected: selected,
            onChanged: (v) => selected = v,
          ),
        ),
      ),
    ));

    // 展开（折叠头是唯一的 GestureDetector）
    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('添加'), findsNothing);
  });

  testWidgets('allowCustom：输入新词后加入选中集并回调', (tester) async {
    Set<String> selected = {};
    String? added;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => DarkMultiSelectField(
            label: '标签（可选，最多 14 个，可自定义）',
            options: const ['日常', '校园'],
            selected: selected,
            allowCustom: true,
            customHint: '输入新标签，回车添加',
            onCustomAdded: (s) => added = s,
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();

    // 输入自定义词并点「添加」
    await tester.enterText(find.byType(TextField), '自创标签');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(selected.contains('自创标签'), isTrue);
    expect(added, '自创标签');
    // 输入框已清空（折叠头摘要与 chip 都会显示该词，故直接查 controller）
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.controller?.text, isEmpty);
  });

  testWidgets('allowCustom：空白输入不产生空标签', (tester) async {
    Set<String> selected = {};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => DarkMultiSelectField(
            label: '标签',
            options: const ['日常'],
            selected: selected,
            allowCustom: true,
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(selected.isEmpty, isTrue);
  });
}
