/// 批量刷新元数据 · **纯 Dart** 判定核心行为探针（裸 Dart VM 可跑）。
///
/// 运行：dart dev_probe/metadata_refresh_core_probe.dart
///
/// 为什么必须单独测这块：`computeRefreshUpdates` 决定「哪些字段会被写」。
/// 规则写反（默认覆盖、或把空值写进去）不会报错，只会**静默改坏用户数据**，
/// 要等用户发现手改的简介消失才暴露。render 探针只验证界面，查不出这个。
import 'dart:io';

import '../lib/services/metadata_refresh_core.dart';

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

/// game.json 里刷新**允许**写的键（白名单）。
/// 任何越界键都意味着我们在偷偷改与元数据无关的字段。
const Set<String> _allowedKeys = <String>{
  'description',
  'developer',
  'release_date',
  'metadata_source',
  'metadata_source_id',
  'rating',
  'rating_count',
  'estimated_minutes',
  'tags',
  'company_id',
};

Map<String, dynamic> _fullFetched() => <String, dynamic>{
      'game_name': '千恋万花',
      'summary': '源里来的简介',
      'developer': 'ゆずソフト',
      'release_date': '2016-07-29',
      'platform': 'MIX源',
      'platform_id': 'v123',
      'tags': <String>['和风', '恋爱'],
      'rating': 8.6,
      'vote_count': 4210,
      'length_minutes': 1800,
    };

void main() {
  // ═══════════════ 1. 空现状：全量补齐 ═══════════════
  L('== 1. 空现状（新入库/老数据）==');
  {
    final c = MetadataRefreshCandidate.fromFetched(_fullFetched());
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(),
      fetched: c,
      overwrite: false,
      companyId: 42,
    );
    check('1.1 空现状写入全部字段', u.length == 10, '实际=${u.length} ${u.keys}');
    check('1.2 键名与 game.json 一致',
        u['description'] == '源里来的简介' &&
            u['developer'] == 'ゆずソフト' &&
            u['release_date'] == '2016-07-29' &&
            u['metadata_source'] == 'MIX源' &&
            u['metadata_source_id'] == 'v123' &&
            u['rating'] == 8.6 &&
            u['rating_count'] == 4210 &&
            u['estimated_minutes'] == 1800 &&
            u['company_id'] == 42);
    check('1.3 tags 是 List<String>', u['tags'] is List<String>);
  }

  // ═══════════════ 2. 只补空字段（默认口径）═══════════════
  L('== 2. overwrite=false：不碰已有值 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(_fullFetched());
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(
        description: '用户手改过的简介',
        developer: '用户填的会社',
        releaseDate: '2020-01-01',
        metadataSource: 'VNDB',
        metadataSourceId: 'v1',
        tags: <String>['用户标签'],
        rating: 5.0,
        ratingCount: 10,
        estimatedMinutes: 60,
        companyId: 7,
      ),
      fetched: c,
      overwrite: false,
      companyId: 42,
    );
    check('2.1 全部字段已满 → 空更新表', u.isEmpty, '实际=$u');
  }

  // ═══════════════ 3. overwrite=true：覆盖 ═══════════════
  L('== 3. overwrite=true：覆盖已有值 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(_fullFetched());
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(
        description: '用户手改过的简介',
        developer: '用户填的会社',
        releaseDate: '2020-01-01',
        metadataSource: 'VNDB',
        metadataSourceId: 'v1',
        tags: <String>['用户标签'],
        rating: 5.0,
        ratingCount: 10,
        estimatedMinutes: 60,
        companyId: 7,
      ),
      fetched: c,
      overwrite: true,
      companyId: 42,
    );
    check('3.1 覆盖后全字段都被替换', u.length == 10, '实际=${u.keys}');
    check('3.2 简介确实被替换', u['description'] == '源里来的简介');
    check('3.3 company_id 被替换', u['company_id'] == 42);
    // 负向对照：如果 overwrite 分支被写成「永远跳过已有值」，
    // 上一条会退化成空表 —— 这条用来防止整体假绿。
    check('3.4 负向对照：覆盖口径 ≠ 补齐口径',
        u.length > 0 && u.containsKey('description'));
  }

  // ═══════════════ 4. 混合：部分空、部分有值 ═══════════════
  L('== 4. 混合现状 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(_fullFetched());
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(
        description: '用户手改过的简介',
        tags: <String>['和风', '恋爱'],
      ),
      fetched: c,
      overwrite: false,
      companyId: null,
    );
    check('4.1 已有的 description 不写', !u.containsKey('description'));
    check('4.2 空的 developer 补上', u['developer'] == 'ゆずソフト');
    check('4.3 标签集合相同 → 不写', !u.containsKey('tags'));
    check('4.4 无数值变化冲突 → 评分写入', u['rating'] == 8.6);
    check('4.5 companyId 为 null → 不写 company_id', !u.containsKey('company_id'));
  }

  // ═══════════════ 5. 标签比较是集合语义 ═══════════════
  L('== 5. 标签 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(<String, dynamic>{
      'tags': <String>['恋爱', '和风'],
    });
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(tags: <String>['和风', '恋爱']),
      fetched: c,
      overwrite: true,
    );
    check('5.1 仅顺序不同 → 不写盘', u.isEmpty, '实际=$u');
  }
  {
    final c = MetadataRefreshCandidate.fromFetched(<String, dynamic>{
      'tags': <String>['和风', '新标签'],
    });
    final no = computeRefreshUpdates(
      existing: const MetadataExistingValues(tags: <String>['和风', '恋爱']),
      fetched: c,
      overwrite: false,
    );
    final yes = computeRefreshUpdates(
      existing: const MetadataExistingValues(tags: <String>['和风', '恋爱']),
      fetched: c,
      overwrite: true,
    );
    check('5.2 已有标签 + 非覆盖 → 不写', !no.containsKey('tags'));
    // Dart 的 List == 是同一性比较，写得比内容就会假红 —— 这里比内容
    check('5.3 已有标签 + 覆盖 → 写',
        yes['tags'] is List<String> &&
            (yes['tags'] as List<String>).join('|') == c.tags.join('|'),
        '实际=${yes['tags']}');
  }

  // ═══════════════ 6. 空值归一：绝不写入空串 / 0 ═══════════════
  L('== 6. 空值归一 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(<String, dynamic>{
      'summary': '   ',
      'developer': '',
      'release_date': null,
      'tags': <String>['', '  ', '有效', '有效'],
      'rating': 0,
      'vote_count': 0,
      'length_minutes': 0,
      'platform': '',
      'platform_id': '  ',
    });
    check('6.1 空白字符串归一为 null', c.summary == null && c.developer == null);
    check('6.2 空 platform 归一为 null',
        c.platform == null && c.platformId == null);
    check('6.3 0 值视为无数据',
        c.rating == null && c.ratingCount == null && c.estimatedMinutes == null);
    check('6.4 tags 去空去重', c.tags.length == 1 && c.tags.first == '有效',
        '实际=${c.tags}');
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(),
      fetched: c,
      overwrite: true,
    );
    check('6.5 归一后只剩 tags 一条更新', u.length == 1 && u.containsKey('tags'),
        '实际=$u');
  }

  // ═══════════════ 7. 字符串数值兼容 ═══════════════
  L('== 7. 字符串形态的数值 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(<String, dynamic>{
      'rating': '8.5',
      'vote_count': '120',
      'length_minutes': '600',
    });
    check('7.1 字符串评分可解析', c.rating == 8.5);
    check('7.2 字符串计数可解析', c.ratingCount == 120);
    check('7.3 字符串时长可解析', c.estimatedMinutes == 600);
  }

  // ═══════════════ 8. hasAnyField ═══════════════
  L('== 8. 空结果判定 ==');
  {
    final empty = MetadataRefreshCandidate.fromFetched(<String, dynamic>{});
    final onlyTags =
        MetadataRefreshCandidate.fromFetched(<String, dynamic>{
      'tags': <String>['x'],
    });
    check('8.1 全空 → hasAnyField=false', !empty.hasAnyField);
    check('8.2 只有标签 → hasAnyField=true', onlyTags.hasAnyField);
  }

  // ═══════════════ 9. 越界键防护（负向）═══════════════
  L('== 9. 不许碰标题 / 封面 / 截图 ==');
  {
    final c = MetadataRefreshCandidate.fromFetched(_fullFetched());
    final u = computeRefreshUpdates(
      existing: const MetadataExistingValues(),
      fetched: c,
      overwrite: true,
      companyId: 1,
    );
    final illegal = u.keys.where((String k) => !_allowedKeys.contains(k));
    check('9.1 更新表只含白名单键', illegal.isEmpty, '越界=${illegal.toList()}');
    check('9.2 不含 title/副标题', !u.containsKey('title') &&
        !u.containsKey('original_title') &&
        !u.containsKey('subtitle'));
    check('9.3 不含封面/截图',
        !u.containsKey('cover_file') &&
            !u.containsKey('screenshot_urls') &&
            !u.containsKey('screenshot_files'));
    check('9.4 抓取结果里的 game_name 不会被当成标题写入',
        !u.containsKey('game_name'));
  }

  L('TOTAL PASS=$_pass FAIL=$_fail');
  if (_fail > 0) exitCode = 1;
}
