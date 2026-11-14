// 抓取数据源排序单元测试
//
// 覆盖需求（添加页 → 抓取数据源设定窗口）：
// 1. 平台源按约定顺序展示：MIX源 → NextMoe → CT → 2Dfan → VNDB → KunGal →
//    Hikarinagi → 月幕GAL → Steam → Bangumi
//    （2026-11-04 调整：移除 DLsite/ErogameScape/TouchGal，新增 2Dfan）
// 2. 无重复、无遗漏（除 local 外的每个源恰好出现一次）
// 3. 任意乱序输入都能被规范化为同一顺序（抓取结果顺序与展示顺序一致）

import 'package:flutter_test/flutter_test.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:chrono_tide/services/metadata_fetcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 约定的展示顺序
  const expectedOrder = [
    SourceType.mix,
    SourceType.nextmoe,
    SourceType.ct,
    SourceType.twoDfan,
    SourceType.vndb,
    SourceType.kun,
    SourceType.hikarinagi,
    SourceType.ymgal,
    SourceType.steam,
    SourceType.bangumi,
  ];

  test('getAvailableSources 按约定顺序返回平台源', () {
    final available = MetadataFetcher.getAvailableSources();
    expect(available, expectedOrder,
        reason: '数据源列表顺序必须与产品约定的展示顺序一致');
  });

  test('平台源无重复、无遗漏', () {
    final available = MetadataFetcher.getAvailableSources();
    final all = SourceType.values.where((s) => s != SourceType.local);
    expect(available.length, all.length);
    expect(available.toSet().length, available.length, reason: '不应出现重复源');
    for (final source in all) {
      expect(available.contains(source), isTrue,
          reason: '源 ${source.name} 不应从列表中丢失');
    }
    expect(available.contains(SourceType.local), isFalse,
        reason: '本地源不参与抓取设定');
  });

  test('MIX源置于最顶部，NextMoe为第二平台', () {
    final available = MetadataFetcher.getAvailableSources();
    expect(available.first, SourceType.mix);
    expect(available[1], SourceType.nextmoe,
        reason: 'NextMoe 为六源对齐目录，约定排在第二平台');
  });

  test('2Dfan 位于 CT 之后、VNDB 之前', () {
    final available = MetadataFetcher.getAvailableSources();
    final ct = available.indexOf(SourceType.ct);
    final fan = available.indexOf(SourceType.twoDfan);
    final vndb = available.indexOf(SourceType.vndb);
    expect(ct, greaterThanOrEqualTo(0));
    expect(fan, ct + 1, reason: '2Dfan 紧跟 CT 之后（产品需求）');
    expect(vndb, fan + 1, reason: '2Dfan 必须在 VNDB 之前');
  });

  test('乱序输入被规范化为约定顺序', () {
    final shuffled = <SourceType>[
      SourceType.bangumi,
      SourceType.twoDfan,
      SourceType.steam,
      SourceType.vndb,
      SourceType.ct,
      SourceType.mix,
      SourceType.ymgal,
      SourceType.hikarinagi,
      SourceType.kun,
      SourceType.nextmoe,
    ];
    expect(MetadataFetcher.sortSourcesByDisplayOrder(shuffled), expectedOrder);
  });

  test('部分子集保持相对顺序，且 local 被剔除', () {
    final subset = <SourceType>[
      SourceType.local,
      SourceType.bangumi,
      SourceType.mix,
      SourceType.steam,
    ];
    expect(
      MetadataFetcher.sortSourcesByDisplayOrder(subset),
      [SourceType.mix, SourceType.steam, SourceType.bangumi],
    );
  });

  test('MIX 底层平台包含 2Dfan，且 2Dfan 为全部字段链的第三位', () {
    final mixSources = MetadataFetcher.mixSourcesForTest;
    expect(mixSources.contains(SourceType.twoDfan), isTrue);
    expect(mixSources.indexOf(SourceType.twoDfan), 2,
        reason: 'MIX 底层顺序：NextMoe → CT → 2Dfan → …');

    final priority = MetadataFetcher.mixFieldPriorityForTest;
    for (final entry in priority.entries) {
      final chain = entry.value;
      expect(chain.contains(SourceType.ct), isTrue,
          reason: '字段 ${entry.key} 的链应含 CT');
      final ctIndex = chain.indexOf(SourceType.ct);
      if (entry.key == 'screenshot_urls') {
        expect(chain.contains(SourceType.twoDfan), isFalse,
            reason: '2Dfan 无截图，不应进入截图链');
      } else {
        expect(chain.contains(SourceType.twoDfan), isTrue,
            reason: '字段 ${entry.key} 的链应含 2Dfan');
        expect(chain.indexOf(SourceType.twoDfan), ctIndex + 1,
            reason: '字段 ${entry.key}：2Dfan 必须紧跟 CT 之后');
      }
    }

    // 副标题/别名链必须收录 2Dfan（它是 2Dfan 的主力字段）
    expect(priority['original_title']!.contains(SourceType.twoDfan), isTrue);
    expect(priority['alias_names']!.contains(SourceType.twoDfan), isTrue);
  });
}
