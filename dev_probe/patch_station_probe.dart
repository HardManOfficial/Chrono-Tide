// PATCH-STATION 离线探针（纯 Dart，不依赖 Flutter）
//
// 用途：模型层与解析层不依赖真机 render / 真网络就能自检。
// 项目环境里 `dart analyze` 在本机稳定性差（常挂 231），所以纯 Dart 的
// `dart run` 断言是唯一可靠的验证出口 —— 每次改完模型/解析器都跑一遍。
//
// 运行：
//   D:\CTLIB\env\toolchains\flutter\bin\cache\dart-sdk\bin\dart.exe ^
//     dev_probe\patch_station_probe.dart
//
// 退出码：0 = 全绿；1 = 有失败（CI 式判据，别用肉眼数）
import 'dart:io';

import 'package:chrono_tide/models/patch_resource.dart';
import 'package:chrono_tide/services/patch/patch_identity_matcher.dart';
import 'package:chrono_tide/services/patch/sources/moyu_query_params.dart';
import 'package:chrono_tide/services/patch/sources/moyu_resource_parser.dart';
import 'package:chrono_tide/services/patch/sources/two_dfan_page_parser.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  [OK]   $name');
  } else {
    _failed++;
    stdout.writeln('  [FAIL] $name${detail == null ? '' : ' → $detail'}');
  }
}

void _eq<T>(String name, T actual, T expected) {
  _check(name, actual == expected, 'actual=$actual expected=$expected');
}

void main() {
  stdout.writeln('=== PATCH-STATION 模型探针 ===\n');

  _probeSite();
  _probeKind();
  _probeSize();
  _probeNetdisk();
  _probeResource();
  _probeQueryResult();
  _probeMoyuHtml();
  _probeV2Mapper();
  _probeMoyuQuery();
  _probeIdentityGating();
  _probeFanParser();
  _probeLibraryPickerSource();

  stdout.writeln('\n--- 结果: $_passed 通过 / $_failed 失败 ---');
  if (_failed > 0) exitCode = 1;
}

void _probeSite() {
  stdout.writeln('[PatchSite]');
  _eq('kunlun 显示名', PatchSite.kunlun.displayName, '鲲');
  _eq('twoDfan 显示名', PatchSite.twoDfan.displayName, '2DFan');
  _eq('community 显示名', PatchSite.community.displayName, '社区');
  _eq('kunlun tag', PatchSite.kunlun.tag, 'moyu');
  _eq('tryParse(moyu)', PatchSite.tryParse('moyu'), PatchSite.kunlun);
  _eq('tryParse(2dfan)', PatchSite.tryParse('2dfan'), PatchSite.twoDfan);
  _eq('tryParse(未知)', PatchSite.tryParse('nope'), null);
  _eq('枚举只有 3 站', PatchSite.values.length, 3);
}

void _probeKind() {
  stdout.writeln('\n[PatchKind.fromRaw]');
  // 鲲的真实 type 枚举值（v2 API 实测）
  _eq('manual → 汉化', PatchKind.fromRaw('manual'), PatchKind.translation);
  _eq('ai → AI翻译', PatchKind.fromRaw('ai'), PatchKind.aiTranslation);
  _eq('machine → 机翻', PatchKind.fromRaw('machine'), PatchKind.machine);
  _eq('save → 存档', PatchKind.fromRaw('save'), PatchKind.save);
  _eq('decensor → 无码', PatchKind.fromRaw('decensor'), PatchKind.decensor);
  _eq('fix → 修正', PatchKind.fromRaw('fix'), PatchKind.fix);
  _eq('mod → MOD', PatchKind.fromRaw('mod'), PatchKind.mod);
  // 2DFan 的中文徽章
  _eq('人工汉化', PatchKind.fromRaw('人工汉化'), PatchKind.translation);
  _eq('AI翻译补丁', PatchKind.fromRaw('AI翻译补丁'), PatchKind.aiTranslation);
  _eq('全CG存档', PatchKind.fromRaw('全CG存档'), PatchKind.save);
  _eq('无码补丁', PatchKind.fromRaw('无码补丁'), PatchKind.decensor);
  _eq('内容还原', PatchKind.fromRaw('内容还原'), PatchKind.decensor);
  // PB resource_type
  _eq('民间汉化', PatchKind.fromRaw('民间汉化'), PatchKind.translation);
  _eq('全年龄补丁', PatchKind.fromRaw('全年龄补丁'), PatchKind.allAges);
  _eq('R18补丁', PatchKind.fromRaw('R18补丁'), PatchKind.r18);
  _eq('R18→全年龄 归全年龄', PatchKind.fromRaw('R18内容全年龄补丁'),
      PatchKind.allAges);
  // 未知
  _eq('乱码 → 其他', PatchKind.fromRaw('zzz-unknown'), PatchKind.other);
  _eq('空串 → 其他', PatchKind.fromRaw('  '), PatchKind.other);

  // 顺序敏感回归：'ai translation' 不能被 'translat' 抢走
  _eq('ai translation 优先', PatchKind.fromRaw('ai translation'),
      PatchKind.aiTranslation);
  // 词边界回归：含 'ai' 子串但非 AI 词，不能误判
  _eq('detail 不是 AI', PatchKind.fromRaw('detail'), PatchKind.other);
  _eq('available 不是 AI', PatchKind.fromRaw('available'), PatchKind.other);
  _eq('ai无码 走无码', PatchKind.fromRaw('ai无码补丁'), PatchKind.decensor);

  final list = PatchKind.fromRawList(['fix', 'decensor', 'fix']);
  _eq('批量去重长度', list.length, 2);
  _eq('批量首个', list.first, PatchKind.fix);
}

void _probeSize() {
  stdout.writeln('\n[parseHumanSizeToBytes]');
  _eq('102.537 MB', parseHumanSizeToBytes('102.537 MB'), 107517837);
  _eq('5.2 MB', parseHumanSizeToBytes('5.2 MB'), 5452595);
  _eq('1.7 KB', parseHumanSizeToBytes('1.7 KB'), 1741);
  _eq('2.0 GB', parseHumanSizeToBytes('2.0 GB'), 2147483648);
  _eq('带逗号 1,024 KB', parseHumanSizeToBytes('1,024 KB'), 1048576);
  _eq('纯字节 12345', parseHumanSizeToBytes('12345'), 12345);
  _eq('空串 → null', parseHumanSizeToBytes(''), null);
  _eq('null → null', parseHumanSizeToBytes(null), null);
  _eq('垃圾串 → null', parseHumanSizeToBytes('未知'), null);

  _eq('格式化 GB', formatBytes(2147483648), '2.00 GB');
  _eq('格式化 MB', formatBytes(107510251), '102.5 MB');
  _eq('格式化 KB', formatBytes(1741), '2 KB');
  _eq('格式化 0 → 空', formatBytes(0), '');
  _eq('格式化 null → 空', formatBytes(null), '');
}

void _probeNetdisk() {
  stdout.writeln('\n[NetdiskProvider]');
  _eq('夸克', NetdiskProvider.fromUrl('https://pan.quark.cn/s/abc'),
      NetdiskProvider.quark);
  _eq('百度', NetdiskProvider.fromUrl('https://pan.baidu.com/s/1xyz'),
      NetdiskProvider.baidu);
  _eq('蓝奏', NetdiskProvider.fromUrl('https://xx.lanzou.com/i123'),
      NetdiskProvider.lanzou);
  _eq('MEGA', NetdiskProvider.fromUrl('https://mega.nz/file/abc'),
      NetdiskProvider.mega);
  _eq('未知', NetdiskProvider.fromUrl('https://example.com/x'),
      NetdiskProvider.unknown);
  _eq('夸克显示名', NetdiskProvider.quark.displayName, '夸克');
}

void _probeResource() {
  stdout.writeln('\n[PatchResource]');

  // 典型：鲲直链型
  final direct = PatchResource(
    key: 'moyu:5459',
    site: PatchSite.kunlun,
    id: '5459',
    title: 'CROSS†CHANNEL 復刻版 Ai无码补丁',
    gameTitle: 'CROSS†CHANNEL',
    kinds: const [PatchKind.decensor],
    rawKinds: const ['decensor'],
    sizeBytes: parseHumanSizeToBytes('107.5 MB'),
    sha256: 'ee3eb0f',
    note: '解压到根目录覆盖同名文件。',
    webUrl: 'https://www.moyu.moe/resource/5459',
    delivery: PatchDelivery.direct,
    directUrl: 'https://dl.imoe.uk/moyu/x.zip',
    author: 'someone',
  );
  _check('直链型 downloadable', direct.downloadable);
  _check('直链型 非网盘', !direct.isNetdisk);
  _eq('直链型 网盘类型 null', direct.netdiskProvider, null);
  _eq('直链型 大小', direct.sizeLabel, '107.5 MB');
  _eq('直链型 徽章', direct.badgeLabels.join(','), '无码');

  // 典型：网盘型（实测 3/9 条是这样）
  final netdisk = PatchResource(
    key: 'moyu:9659',
    site: PatchSite.kunlun,
    id: '9659',
    title: '汉化补丁',
    delivery: PatchDelivery.netdisk,
    netdiskUrl: 'https://pan.quark.cn/s/7ccd032bc22c',
    extractCode: 'ab12',
  );
  _check('网盘型 不可直下', !netdisk.downloadable);
  _check('网盘型 isNetdisk', netdisk.isNetdisk);
  _eq('网盘型 provider', netdisk.netdiskProvider, NetdiskProvider.quark);

  // 典型：只能跳转（2DFan 未登录）
  final web = PatchResource(
    key: '2dfan:15801',
    site: PatchSite.twoDfan,
    id: '15801',
    title: 'Air 汉化补丁',
    webUrl: 'https://2dfmax.top/downloads/15801',
  );
  _check('web 型 不可直下', !web.downloadable);
  _check('web 型 非网盘', !web.isNetdisk);
  _eq('web 型 大小空', web.sizeLabel, '');

  // badgeLabels 回落原文
  final other = PatchResource(
    key: 'pb:x',
    site: PatchSite.community,
    id: 'x',
    title: 't',
    kinds: const [PatchKind.other],
    rawKinds: const ['奇怪类型'],
  );
  _eq('未知类型回落原文', other.badgeLabels.join(','), '奇怪类型');

  // copyWith：直链后置解析的关键路径
  final resolved = web.copyWith(
    delivery: PatchDelivery.direct,
    directUrl: 'https://dl.imoe.uk/moyu/y.zip',
    sizeBytes: 1024,
  );
  _check('copyWith 后可下载', resolved.downloadable);
  _eq('copyWith 保留 key', resolved.key, '2dfan:15801');
  _eq('copyWith 保留 webUrl', resolved.webUrl, web.webUrl);
}

void _probeQueryResult() {
  stdout.writeln('\n[PatchQueryResult]');

  final a = PatchResource(
    key: 'moyu:1',
    site: PatchSite.kunlun,
    id: '1',
    title: 'a',
    delivery: PatchDelivery.direct,
    directUrl: 'https://dl.imoe.uk/moyu/a.zip',
  );
  final b = PatchResource(
    key: '2dfan:2',
    site: PatchSite.twoDfan,
    id: '2',
    title: 'b',
  );
  final r = PatchQueryResult(
    keyword: '千恋万花',
    resources: [a, b],
    countsBySite: const {
      PatchSite.kunlun: 1,
      PatchSite.twoDfan: 1,
    },
    failures: const {PatchSite.community: '网络不可达'},
  );

  _eq('total', r.total, 2);
  _check('非空', !r.isEmpty);
  _check('有失败', r.hasAnyFailure);
  _check('不是全失败', !r.allFailed);
  _eq('按鲲过滤', r.filterBySite(PatchSite.kunlun).length, 1);
  _eq('按全部（null）不过滤', r.filterBySite(null).length, 2);
  _eq('按社区过滤为空', r.filterBySite(PatchSite.community).length, 0);

  // 全失败态
  final allFail = PatchQueryResult(
    keyword: 'x',
    failures: {
      for (final s in PatchSite.values) s: 'fail',
    },
  );
  _check('全失败判据', allFail.allFailed);
  _check('空结果', allFail.isEmpty);

  _check('默认空态', PatchQueryResult.empty.isEmpty);
}

// ==================== 鲲资源页 HTML 解析 ====================

/// 夹具：直链型（实测 `resource/11425` 的下载块，class 与结构原样保留）
const String _fixtureDirect = r'''
<div class="border-success/40 bg-content1 shadow-kun-sm hover:border-success focus-within:border-success space-y-3 rounded-xl border p-3 transition-colors">
  <a href="https://dl.imoe.uk/moyu/2711e3ae-2435-4fc5-8134-073782627b46.zip" target="_blank" rel="noopener noreferrer" class="hover:text-success group flex min-w-0 items-center gap-3 transition-colors">
    <span class="bg-success/10"><svg viewBox="0 0 24 24"><path d="M12 15V3m9 12v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/></svg></span>
    <span class="min-w-0 flex-1 truncate text-sm">https://dl.imoe.uk/moyu/2711e3ae-2435-4fc5-8134-073782627b46.zip</span>
  </a>
</div>
<a href="/galgame/15" class="nexus-inline-link">返回作品页</a>
<a href="https://example.com/other" target="_blank">不相关外链</a>
''';

/// 夹具：网盘型（实测 `resource/9659`，夸克 + 百度各一条，pwd 内嵌）
const String _fixtureNetdisk = r'''
<a href="https://pan.quark.cn/s/7ccd032bc22c?pwd=kUz4" target="_blank" rel="noopener noreferrer" class="hover:text-success group flex min-w-0 items-center gap-3 transition-colors">
  <span class="min-w-0 flex-1 truncate text-sm">https://pan.quark.cn/s/7ccd032bc22c?pwd=kUz4</span>
</a>
<a href="https://pan.baidu.com/s/1uEfrVRozAPq7GgXGEwgcJg?pwd=16zl" target="_blank" rel="noopener noreferrer" class="hover:text-success group flex min-w-0 items-center gap-3 transition-colors">
  <span class="min-w-0 flex-1 truncate text-sm">https://pan.baidu.com/s/1uEfrVRozAPq7GgXGEwgcJg?pwd=16zl</span>
</a>
''';

/// 夹具：站点改版把卡片 class 换掉（模拟最坏情况，验证兜底通道）
const String _fixtureClassRenamed = r'''
<a href="https://dl.imoe.uk/moyu/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.zip" target="_blank" class="download-card group">下载</a>
''';

/// 夹具：两种链接同时存在 ⇒ 应优先直链
const String _fixtureBoth = r'''
<a href="https://pan.quark.cn/s/deadbeef?pwd=zz99" target="_blank" rel="noopener noreferrer" class="hover:text-success">网盘</a>
<a href="https://dl.imoe.uk/moyu/11111111-2222-3333-4444-555555555555.7z" target="_blank" rel="noopener noreferrer" class="hover:text-success">直链</a>
''';

/// 夹具：HTML 实体转义（实测 href 里会出现 &amp;）
const String _fixtureEntity = r'''
<a href="https://pan.baidu.com/s/abc?pwd=ab12&amp;from=share" target="_blank" rel="noopener noreferrer" class="hover:text-success">百度</a>
''';

void _probeMoyuHtml() {
  stdout.writeln('\n[MoyuResourceParser]');

  // --- 直链型 ---
  final direct = MoyuResourceParser.parseDownloadLinks(_fixtureDirect);
  _eq('直链型 条数（忽略无关链接）', direct.length, 1);
  _eq('直链型 delivery', direct.first.delivery, PatchDelivery.direct);
  _check('直链型 url', direct.first.url.endsWith('.zip'));
  _eq('直链型 无提取码', direct.first.extractCode, null);

  final dInfo = MoyuResourceParser.resolveDelivery(_fixtureDirect);
  _eq('直链型 resolve', dInfo.delivery, PatchDelivery.direct);
  _check('直链型 directUrl 非空', (dInfo.directUrl ?? '').isNotEmpty);
  _eq('直链型 不带 netdiskUrl', dInfo.netdiskUrl, null);

  // --- 网盘型 ---
  final netdisk = MoyuResourceParser.parseDownloadLinks(_fixtureNetdisk);
  _eq('网盘型 条数', netdisk.length, 2);
  _check('网盘型 全为 netdisk',
      netdisk.every((l) => l.delivery == PatchDelivery.netdisk));
  _eq('网盘型 有提取码', netdisk.first.extractCode, 'kUz4');

  final nInfo = MoyuResourceParser.resolveDelivery(_fixtureNetdisk);
  _eq('网盘型 resolve', nInfo.delivery, PatchDelivery.netdisk);
  _eq('网盘型 提取码', nInfo.extractCode, 'kUz4');
  _check('网盘型 网盘 host',
      (nInfo.netdiskUrl ?? '').contains('quark.cn'));

  // --- 直链优先 ---
  final both = MoyuResourceParser.resolveDelivery(_fixtureBoth);
  _eq('两类共存 选直链', both.delivery, PatchDelivery.direct);
  _check('两类共存 直链是 7z', (both.directUrl ?? '').endsWith('.7z'));

  // --- 改版兜底 ---
  final renamed = MoyuResourceParser.parseDownloadLinks(_fixtureClassRenamed);
  _eq('class 改名 兜底仍命中', renamed.length, 1);
  _eq('class 改名 仍是直链', renamed.first.delivery, PatchDelivery.direct);

  // --- 实体转义 ---
  final entity = MoyuResourceParser.parseDownloadLinks(_fixtureEntity);
  _eq('实体 条数', entity.length, 1);
  _check('实体 &amp; 已解码', entity.first.url.contains('&from=share'));
  _eq('实体 提取码', entity.first.extractCode, 'ab12');

  // --- 空/无链接 ---
  _eq('空串 → 空列表', MoyuResourceParser.parseDownloadLinks('').length, 0);
  _eq('无链接页 → 空列表',
      MoyuResourceParser.parseDownloadLinks('<html><body>暂无</body></html>').length,
      0);
  _eq('无链接 resolve → web',
      MoyuResourceParser.resolveDelivery('<html>暂无</html>').delivery,
      PatchDelivery.web);

  // --- 去重 ---
  final dup = MoyuResourceParser.parseDownloadLinks(
    _fixtureDirect + _fixtureDirect,
  );
  _eq('同块重复出现 → 去重为 1', dup.length, 1);
}

// ==================== NextMoe v2 JSON → 模型 ====================

/// 真实响应片段（`GET /v2/moyu/patches/15/resources`，实测原样）
const Map<String, dynamic> _v2Resource9659 = {
  'object': 'patch_resource',
  'id': '9659',
  'patch_id': '15',
  'name': '',
  'storage': 'user',
  'size': '10kb',
  'hash': '',
  'model_name': '',
  'localization_group_name': '',
  'note': r'C:\Users\(UserName)\AppData\Roaming\asaproject\恋愛×ロワイアル\savedata',
  'type': ['save'],
  'language': ['zh-Hans'],
  'platform': ['windows'],
  'download_count': 805,
  'like_count': 0,
  'web_url': 'https://www.moyu.moe/resource/9659',
  'created_at': '2026-06-27T01:09:01Z',
  'updated_at': '2026-06-27T01:09:01Z',
};

const Map<String, dynamic> _v2Resource8342 = {
  'object': 'patch_resource',
  'id': '8342',
  'patch_id': '15',
  'name': 'R18补丁',
  'storage': 'user',
  'size': '2GB',
  'hash': '',
  'type': ['fix'],
  'language': ['zh-Hans'],
  'platform': ['windows'],
  'download_count': 1610,
  'like_count': 0,
  'web_url': 'https://www.moyu.moe/resource/8342',
  'created_at': '2026-03-04T05:26:17Z',
  'updated_at': '2026-03-04T05:26:17Z',
};

void _probeV2Mapper() {
  stdout.writeln('\n[MoyuV2Mapper]');

  // --- name 为空：必须兜底成「类型 #id」，不能是空白标题 ---
  final a = MoyuV2Mapper.toResource(_v2Resource9659, patchId: '15');
  _eq('空名 id', a.id, '9659');
  _eq('空名 key', a.key, 'moyu:9659');
  _eq('空名 title 兜底', a.title, '存档 #9659');
  _eq('空名 kind', a.kinds.first, PatchKind.save);
  _eq('空名 size 10kb', a.sizeBytes, 10 * 1024);
  _eq('空名 language 保留大小写', a.languages.first, 'zh-Hans');
  _eq('空名 platform', a.platforms.first, 'windows');
  _eq('空名 delivery 初始 web', a.delivery, PatchDelivery.web);
  _eq('空名 download_count', a.downloadCount, 805);
  _eq('空名 groupId', a.groupId, '15');
  _check('空名 updatedAt 已解析', a.updatedAt != null);
  _check('空名 note 已带', a.note.isNotEmpty);
  _eq('空名 webUrl', a.webUrl, 'https://www.moyu.moe/resource/9659');

  // --- 正常命名 ---
  final b = MoyuV2Mapper.toResource(_v2Resource8342, patchId: '15');
  _eq('正常 title', b.title, 'R18补丁');
  _eq('正常 size 2GB', b.sizeBytes, 2147483648);
  _eq('正常 kind fix', b.kinds.first, PatchKind.fix);

  // --- 资源无 type 时用 patch 级 type 兜底 ---
  final noType = Map<String, dynamic>.of(_v2Resource8342)..['type'] = <dynamic>[];
  final c = MoyuV2Mapper.toResource(
    noType,
    patchId: '15',
    patchTypes: const ['decensor'],
  );
  _eq('type 兜底', c.kinds.first, PatchKind.decensor);

  // --- 双 type 都空：kind 落 other，标题用「资源 #id」 ---
  final noTypeNoPatch = Map<String, dynamic>.of(_v2Resource8342)
    ..['type'] = <dynamic>[]
    ..['name'] = '';
  final d = MoyuV2Mapper.toResource(noTypeNoPatch, patchId: '15');
  _eq('全无类型 title', d.title, '资源 #8342');
  _eq('全无类型 kind', d.kinds.first, PatchKind.other);

  // --- itemsOf 解析 ---
  final items = MoyuV2Mapper.itemsOf({
    'object': 'list',
    'items': [_v2Resource9659, _v2Resource8342],
    'next_cursor': 'cur_Mg',
  });
  _eq('itemsOf 条数', items.length, 2);
  _eq('itemsOf 空响应',
      MoyuV2Mapper.itemsOf({'object': 'list', 'items': <dynamic>[]}).length, 0);
  _eq('itemsOf 非 Map', MoyuV2Mapper.itemsOf('oops').length, 0);
  _eq('itemsOf 无 items 键', MoyuV2Mapper.itemsOf({'object': 'list'}).length, 0);
}

// ==================== 鲲的查询参数（2026-11-13 补） ====================
//
// 回归的是「鲲的补丁几乎搜不到」：
//   GET /v2/moyu/patches?refs=catalog:51&limit=100
//     → {"items":[], "missing":["catalog:51"]}          ← 曾经的样子
//   GET /v2/moyu/patches?refs=catalog:51&limit=100&nsfw=true
//     → {"items":[{"id":"51","content_limit":"nsfw","resource_count":11}]}
//
// 服务端默认按 SFW 过滤，`content_limit=nsfw` 的 patch 整条被丢进 `missing`，
// 映射层只看到「items 空」⇒ 当成「这部作品没补丁」，连 failures 都不进。
void _probeMoyuQuery() {
  stdout.writeln('\n[MoyuQueryParams]');

  final on = buildMoyuPatchesQuery(workId: 51, nsfw: true, limit: 100);
  _eq('patches refs', on['refs'], 'catalog:51');
  _eq('patches limit', on['limit'], '100');
  // 🔴 这一条就是回归点：以前整个键都不存在
  _check('patches 一定带 nsfw 键', on.containsKey('nsfw'));
  _eq('patches nsfw=true', on['nsfw'], 'true');

  final off = buildMoyuPatchesQuery(workId: 7, nsfw: false, limit: 100);
  _eq('patches nsfw=false', off['nsfw'], 'false');
  _eq('patches refs 跟随 workId', off['refs'], 'catalog:7');

  // resources 端点刻意不带 nsfw（实测不带也返回完整列表）
  final res = buildMoyuResourcesQuery(limit: 100);
  _check('resources 不带 nsfw', !res.containsKey('nsfw'));
  _eq('resources limit', res['limit'], '100');
}

// ==================== 身份解析的作用域与采信门槛 ====================
void _probeIdentityGating() {
  stdout.writeln('\n[PatchIdentity · 关键词检索门禁]');

  // --- 缓存/并发键 ---
  _eq('有 gameId 时用它当键',
      patchIdentityCacheKey(gameId: 'g-123', keyword: '随便'), 'g-123');
  _eq('gameId 只有空白 ⇒ 落到关键词',
      patchIdentityCacheKey(gameId: '   ', keyword: ' 缘之空 '), 'kw:缘之空');
  _eq('gameId 为 null ⇒ 落到关键词',
      patchIdentityCacheKey(gameId: null, keyword: '缘之空'), 'kw:缘之空');
  // 归一化：全角 asterisk 折叠成半角
  _eq('关键词做归一化',
      patchIdentityCacheKey(gameId: null, keyword: '千恋＊万花'), 'kw:千恋*万花');
  // 空串 = 这次别解析（调用方据此跳过，避免拿空 key 去查）
  _eq('关键词也空 ⇒ 空串',
      patchIdentityCacheKey(gameId: null, keyword: '   '), '');

  // --- 采信门槛：没有 gameId 时只认 ≥0.8 ---
  _check(
      '置信度 1.0 采信',
      acceptKeywordWorkMatch(const PatchWorkMatch(
          workId: 51, matchedTitle: '缘之空', confidence: 1.0)));
  _check(
      '置信度 0.8（包含关系）采信',
      acceptKeywordWorkMatch(const PatchWorkMatch(
          workId: 51, matchedTitle: '缘之空', confidence: 0.8)));
  _check(
      '置信度 0.5（取首条弱匹配）丢弃',
      !acceptKeywordWorkMatch(const PatchWorkMatch(
          workId: 51, matchedTitle: '别的作品', confidence: 0.5)));
  _check('无匹配丢弃', !acceptKeywordWorkMatch(PatchWorkMatch.none));

  // --- 用真实响应形状跑一遍：catalog/search 的 item ---
  final items = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 51,
      'display_name': 'ヨスガノソラ',
      'localized': <String, dynamic>{
        'zh-Hans': <String, dynamic>{'value': '缘之空'},
      },
    },
  ];
  final m = pickWorkMatch(items, const <String>['缘之空']);
  _eq('真实响应：解析到 workId', m.workId, 51);
  _eq('真实响应：置信度', m.confidence, 1.0);
  _check('真实响应：通过关键词门禁', acceptKeywordWorkMatch(m));
}

// ==================== 2DFan 页面解析（纯 Dart，无需网络） ====================
//
// 为什么把夹具写死在探针里：2DFan 是**抓取式**实现，页面结构就是唯一依据，
// 站点一改版就整块失效。夹具是「我们以为的页面」，跑绿只说明解析器按预期
// 工作；真站是否仍长这样，只能靠实测记录（见 features/patch_station.md）。
// ⛔ 不要因为探针绿就认为线上一定通。
void _probeFanParser() {
  stdout.writeln('\n[2DFan · 账号解析]');

  _check('空串 ⇒ 匿名', !TwoDFanPageParser.parseAccount('').loggedIn);
  _check(
      '没有 NexusHeader ⇒ 匿名',
      !TwoDFanPageParser.parseAccount(
              '<html><body><main><h1>x</h1></main></body></html>')
          .loggedIn);

  // 游客态：站点会塞 id=0 / points=0，⛔ 不能当成「已登录 + 0 积分」
  final guest = TwoDFanPageParser.parseAccount(_fanPage(
    userJson: '{"user":{"id":0,"name":"","points":0}}',
  ));
  _check('游客 id=0 ⇒ 未登录', !guest.loggedIn);
  _check('游客 points 不算余额', guest.points == null, 'points=${guest.points}');

  final me = TwoDFanPageParser.parseAccount(_fanPage(
    userJson: '{"user":{"id":12345,"name":"测试用户","points":42}}',
  ));
  _check('已登录', me.loggedIn);
  _eq('昵称', me.nickname, '测试用户');
  _eq('积分', me.points, 42);
  _eq('摘要文案', me.summary, '已登录：测试用户 · 积分 42');

  stdout.writeln('\n[2DFan · 下载页解析]');

  // ---- 匿名 + 标价 7 + 一个网盘 + 两个「登录」链接 + 兑换端点 ----
  const String pageUrl = 'https://2dfmax.top/downloads/38989';
  final anon = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":0}}',
      body: '''
    <h1>缘之空 汉化补丁</h1>
    <div class="download-info-item">
      <span class="download-info-label">价格</span>
      <span class="download-info-value">7 积分</span>
    </div>
    <a href="/login" class="download-btn">登录下载</a>
    <a href="/login">登录后可见</a>
    <a href="/downloads/38989/purchase" class="download-btn" data-turbo-method="post">购买</a>
    <a href="https://pan.baidu.com/s/1abc?pwd=ep1f">网盘载点1</a>
''',
    ),
    pageUrl,
  );
  _eq('标题', anon.title, '缘之空 汉化补丁');
  _eq('价格 7 积分', anon.price, 7);
  _check('匿名读不到余额', anon.balance == null);
  _check('匿名 = 未登录', !anon.authenticated);
  _check('站点要求兑换', anon.requiresPurchase);
  _check('匿名不能兑换', !anon.canPurchase);
  _eq(
      '登录占位只记 1 条（页面有 2 个 /login）',
      anon.links.where((l) => l.kind == FanLinkKind.loginGate).length,
      1);
  final anonDisk =
      anon.links.where((l) => l.kind == FanLinkKind.netdisk).toList();
  _eq('网盘条数', anonDisk.length, 1);
  _eq('网盘服务商', anonDisk.isEmpty ? '' : anonDisk.first.provider, '百度网盘');
  _eq('网盘提取码', anonDisk.isEmpty ? '' : anonDisk.first.extractCode, 'ep1f');
  _check('兑换端点已识别',
      (anon.purchaseAction ?? '').endsWith('/downloads/38989/purchase'),
      anon.purchaseAction ?? '(null)');
  _eq('csrf 已带出', anon.csrf, 'csrf-token-value');
  _check(
      '匿名 + 有网盘 ⇒ 放行但要提示登录', anon.reason.contains('网盘'), anon.reason);
  _eq('无直链时 fileUrl 为空', anon.fileUrl, null);

  // ---- 已登录 + 余额 42 + 两个网盘（顺序必须保持） ----
  final rich = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":7,"name":"有钱人","points":42}}',
      body: '''
    <h1>千恋万花 汉化补丁</h1>
    <div class="download-info-item">
      <span class="download-info-label">价格</span>
      <span class="download-info-value">7 积分</span>
    </div>
    <a href="/downloads/15801/purchase" class="download-btn">兑换下载</a>
    <a href="https://pan.baidu.com/s/1aaa?pwd=aaa1">网盘载点1</a>
    <a href="https://pan.quark.cn/s/bbb2">网盘载点2</a>
''',
    ),
    'https://2dfmax.top/downloads/15801',
  );
  _check('已登录', rich.authenticated);
  _eq('余额', rich.balance, 42);
  _check('余额够 ⇒ 可兑换', rich.canPurchase);
  _eq('可兑换时不拦（reason 空）', rich.reason, '');
  final richDisks =
      rich.links.where((l) => l.kind == FanLinkKind.netdisk).toList();
  _eq('两个网盘都在', richDisks.length, 2);
  _eq('顺序：先百度', richDisks.isEmpty ? '' : richDisks.first.provider, '百度网盘');
  _eq('顺序：后夸克', richDisks.length < 2 ? '' : richDisks[1].provider, '夸克网盘');

  // ---- 已登录但积分不足 ----
  final poor = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":8,"name":"穷人","points":3}}',
      body: '''
    <h1>贵补丁</h1>
    <div class="download-info-item">
      <span class="download-info-label">价格</span>
      <span class="download-info-value">7 积分</span>
    </div>
    <a href="/downloads/2/purchase" class="download-btn">购买</a>
''',
    ),
    'https://2dfmax.top/downloads/2',
  );
  _check('余额不足 ⇒ 不能兑换', !poor.canPurchase);
  _check('余额不足有话说', poor.reason.contains('积分不足'), poor.reason);

  // ---- 免费（价格 0）+ 兑换表单 ⇒ 走一次免费兑换 ----
  final free = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":9,"name":"白嫖","points":0}}',
      body: '''
    <h1>免费补丁</h1>
    <div class="download-info-item">
      <span class="download-info-label">价格</span>
      <span class="download-info-value">免费</span>
    </div>
    <form method="post" action="/downloads/3/purchase">消耗 0 积分下载</form>
''',
    ),
    'https://2dfmax.top/downloads/3',
  );
  _eq('免费 ⇒ 价格 0', free.price, 0);
  _check('免费也要换一次表单', free.canAcquireFree);
  _eq('免费不拦', free.reason, '');

  // ---- 已有直链（兑换过 / 站点直给） ----
  final direct = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":10,"name":"老用户","points":5}}',
      body: '''
    <h1>已兑换补丁</h1>
    <a href="https://d1.acgxp.com/files/abc.zip" class="download-btn download-btn--primary">直连下载</a>
''',
    ),
    'https://2dfmax.top/downloads/4',
  );
  _eq('直链已提取', direct.fileUrl, 'https://d1.acgxp.com/files/abc.zip');
  _check('有直链 ⇒ 不再要求兑换', !direct.requiresPurchase);
  _eq('有直链 ⇒ 不拦', direct.reason, '');

  // ---- 跨域的 /purchase 链接不算兑换端点（防被站外链接钓鱼） ----
  final cross = TwoDFanPageParser.parseDownloadPage(
    _fanPage(
      userJson: '{"user":{"id":11,"name":"x","points":99}}',
      body: '''
    <h1>跨域链接</h1>
    <a href="https://evil.example/downloads/5/purchase">购买</a>
''',
    ),
    'https://2dfmax.top/downloads/5',
  );
  _eq('跨域 purchase 不算端点', cross.purchaseAction, null);
}

/// 造一个「带 NexusHeader + csrf + main 正文」的 2DFan 页面。
String _fanPage({required String userJson, String body = ''}) {
  return '''
<!doctype html>
<html>
<head><meta name="csrf-token" content="csrf-token-value"></head>
<body>
<header data-island="NexusHeader" data-props='$userJson'></header>
<main>
$body
</main>
</body>
</html>
''';
}

// ==================== 游戏选择器数据源（源码防回归） ====================
//
// 「从游戏库选择」的用户口径（2026-11-14 裁决）：只针对「库」页里用户导入 /
// 已下载入库的本地游戏，⛔不是探索库云端作品、⛔不含下载中或未入库的记录。
//
// 历史事故：discover_page.dart 曾给 PatchStationPanel.show 注入
// `gamePicker: () => [for (final g in _displayGames) ...]`，把云端作品塞进了
// 下拉（每行还没有本地封面 ⇒ 一片灰色占位图）。面板的默认实现
// （LocalGameRegistry.instance.allGames，与库页同源）本来就是对的，
// 生产调用必须留空；gamePicker 参数只留给探针注入假数据。
void _probeLibraryPickerSource() {
  stdout.writeln('\n[游戏选择器 · 数据源防回归]');
  final entry = _readSource('lib/pages/discover_page.dart');
  final panel =
      _readSource('lib/widgets/patch_station/patch_station_panel.dart');

  final body = _functionBody(entry, 'void _openPatchStation()');
  _check('能定位到 _openPatchStation', body != null,
      'discover_page.dart 读不到或函数被改名');
  if (body != null) {
    _check('⛔ 不注入 gamePicker', !body.contains('gamePicker'), body);
    _check('⛔ 不把探索库列表当数据源',
        !body.contains('_displayGames') && !body.contains('_allGames'), body);
    _check('保留 initialQuery（探索页带入搜索词）',
        body.contains('initialQuery'), body);
  }
  _check('面板默认仍读本地注册表',
      panel.contains('LocalGameRegistry.instance.allGames'),
      'panel 读不到或默认数据源被改');
  _check('面板仍保留 gamePicker 注入点（探针用）',
      panel.contains('List<PatchGameRef> Function()? gamePicker'),
      '别把探针注入点一起删了');
}

String _readSource(String rel) {
  try {
    return File(rel).readAsStringSync();
  } catch (_) {
    return '';
  }
}

/// 从 [signature] 起找第一对配平花括号，返回函数体（含花括号）。
/// ⛔ 不用「下一个 \n  }\n」截断：函数体里有嵌套块会截早。
String? _functionBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return null;
  final brace = src.indexOf('{', start);
  if (brace < 0) return null;
  var depth = 0;
  for (var i = brace; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(brace, i + 1);
    }
  }
  return null;
}
