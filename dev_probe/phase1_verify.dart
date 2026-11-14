// Phase 1 端到端验证探针（**加载 lib/ 里的真实类**，不是复制品）
//
// 为什么需要它：本环境 `flutter test` 因 Dart 匿名管道受限跑不通
// （`.workbuddy/memory/MEMORY.md` §1），但 `dart.exe` 本身能跑 —— 因此把
// Phase 1 的四个核心模块刻意写成**纯 Dart**（不 import flutter），
// 就能在这里被真实执行。这满足「跑不了的测试 = 没有测试」的纪律。
//
// 用法：
//   unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY NO_PROXY no_proxy
//   flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages="D:/CTLIB/.dart_tool/package_config.json" \
//     dev_probe/phase1_verify.dart
//
// 覆盖：
//   A) SevenZipProgressParser 对 Phase 0 捕获的真实 7z stdout 的命中率（新旧正则对照）
//   B) ArchiveCompressor 真实端到端：压缩 → 7z t → 解包 → 逐文件字节比对
//   C) ArchiveManifest 序列化往返
//   D) GameStorageStateController 四态判定真值表（含真实临时目录）
//   E) SHA256 对 RFC 标准向量
//   F) 半成品（.partial）行为
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chrono_tide/models/archive_manifest.dart';
import 'package:chrono_tide/services/archive_compressor.dart';
import 'package:chrono_tide/services/game_storage_state_controller.dart';
import 'package:chrono_tide/services/seven_zip_progress.dart';
import 'package:path/path.dart' as p;

const String sevenZip = r'D:\CTLIB\windows\runner\tools\7z.exe';
final String tmpRoot = p.join(Directory.current.path, '.workbuddy', 'tmp', 'phase1');

int passed = 0;
int failed = 0;

final String _shaA = List.filled(64, 'a').join();
final String _shaB = List.filled(64, 'b').join();
final String _shaC = List.filled(64, 'c').join();

void ok(String label, [String extra = '']) {
  passed++;
  print('  [PASS] $label${extra.isEmpty ? '' : '  $extra'}');
}

void bad(String label, [String extra = '']) {
  failed++;
  print('  [FAIL] $label${extra.isEmpty ? '' : '  $extra'}');
}

void check(bool cond, String label, [String extra = '']) =>
    cond ? ok(label, extra) : bad(label, extra);

// ============ 旧正则（extract_manager.dart 改动前）============
final _oldRe = RegExp(r'^\s*(\d+)\s');
int? _oldParse(String line) {
  final m = _oldRe.firstMatch(line.trimLeft());
  if (m == null) return null;
  final v = int.tryParse(m.group(1)!);
  if (v == null || v > 100) return null;
  return v;
}

/// 还原 Phase 0 探针文件里的 python repr 转义（`\r`、`\n` 等字面两字符）
String _unescapeRepr(String s) {
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      const map = {'r': '\r', 'n': '\n', 't': '\t', '\\': r'\', "'": "'"};
      if (map.containsKey(n)) {
        buf.write(map[n]);
        i++;
        continue;
      }
      if (n == 'x' && i + 3 < s.length) {
        final v = int.tryParse(s.substring(i + 2, i + 4), radix: 16);
        if (v != null) {
          buf.writeCharCode(v);
          i += 3;
          continue;
        }
      }
    }
    buf.write(c);
  }
  return buf.toString();
}

Future<void> main() async {
  print('=== Phase 1 端到端验证（真实类）===');
  print('7z = $sevenZip');
  print('exists = ${File(sevenZip).existsSync()}');
  print('');

  await partA_progressParser();
  await partE_sha256();
  partC_manifestRoundTrip();
  await partD_stateMachine();
  await partB_endToEnd();
  await partF_partialMarker();

  print('');
  print('==============================');
  print('PASS = $passed   FAIL = $failed');
  print('==============================');
  if (failed > 0) exitCode = 1;
}

// ---------------------------------------------------------------- A
Future<void> partA_progressParser() async {
  print('--- A) 进度解析器 vs Phase 0 捕获的真实 7z stdout ---');
  for (final f in [
    'dev_probe/phase0_out_v1_bsp1.txt', // 压缩（7z a -bsp1）
    'dev_probe/phase0_out_x_bsp1.txt', // 解压（7z x -bsp1）
  ]) {
    final file = File(f);
    if (!file.existsSync()) {
      bad('$f 不存在（Phase 0 产物缺失）');
      continue;
    }
    final raw = file.readAsStringSync();
    final idx = raw.indexOf('===== STDOUT');
    final text =
        _unescapeRepr(idx >= 0 ? raw.substring(idx) : raw).replaceAll('\r\n', '\n');
    final lines = const LineSplitter().convert(text);
    final oldHits = lines.map(_oldParse).where((e) => e != null).length;
    final newVals =
        lines.map(SevenZipProgressParser.parse).whereType<int>().toList();

    var monotonic = true;
    for (var i = 1; i < newVals.length; i++) {
      if (newVals[i] < newVals[i - 1]) monotonic = false;
    }

    final tag = p.basename(f);
    print('  [$tag] 段数=${lines.length}  旧正则命中=$oldHits  新正则命中=${newVals.length}');
    check(newVals.length > oldHits * 2,
        '$tag 新正则命中显著高于旧正则',
        '$oldHits -> ${newVals.length}');
    check(monotonic, '$tag 解析出的百分比单调不减');
    check(newVals.isEmpty || newVals.last >= 90,
        '$tag 末值达到 90% 以上', '末值=${newVals.isEmpty ? "n/a" : newVals.last}');
  }
  // 反例：普通信息行不该被判成进度
  const noise = [
    '1 file, 135716363 bytes (130 MiB)',
    'Compressed: 135716363',
    'Everything is Ok',
    '                    ',
    '',
  ];
  final falsePositives =
      noise.where((l) => SevenZipProgressParser.parse(l) != null).toList();
  check(falsePositives.isEmpty, '信息行零误判', '$falsePositives');

  // 文件名里带百分号也不该被误判（正则锚定行首）
  check(SevenZipProgressParser.parse('- src\\year50%_off.dat') == null,
      '文件名含 % 不误判为进度');
  check(SevenZipProgressParser.parse('  5% 1 + a.dat') == 5, '标准压缩进度行 = 5');
  check(SevenZipProgressParser.parse('\r 94% 31 - a.dat') == 94,
      '带前导 \\r 的解压进度行 = 94（容错）');
  print('');
}

// ---------------------------------------------------------------- B
Future<void> partB_endToEnd() async {
  print('--- B) ArchiveCompressor 真实端到端 ---');
  final src = p.join(tmpRoot, 'src');
  final outDir = p.join(tmpRoot, 'out');
  final round = p.join(tmpRoot, 'roundtrip');
  await _rmrf(tmpRoot);

  // 构造覆盖边界的源树
  final rnd = Random(20261002);
  await Directory(p.join(src, '中文目录_日本語', 'nested 深层')).create(recursive: true);
  await Directory(p.join(src, 'empty_dir')).create(recursive: true);
  await File(p.join(src, 'ascii.txt')).writeAsString('hello-chronotide');
  await File(p.join(src, '0字节文件.dat')).writeAsBytes(<int>[]);
  await File(p.join(src, '中文目录_日本語', '测试文件.xp3'))
      .writeAsString('存档与剧本数据' * 100);
  await File(p.join(src, '中文目录_日本語', 'nested 深层', 'deep.txt'))
      .writeAsString('深层文件');
  // 2MB 随机数据：制造真实进度输出
  final big = List<int>.generate(2 * 1024 * 1024, (_) => rnd.nextInt(256));
  await File(p.join(src, 'big_random.bin')).writeAsBytes(big);
  for (var i = 0; i < 24; i++) {
    await File(p.join(src, 'many', 'f${i.toString().padLeft(3, '0')}.txt'))
        .create(recursive: true)
        .then((f) => f.writeAsString('f$i' * 50));
  }

  final before = <String, int>{};
  await for (final e in Directory(src).list(recursive: true, followLinks: false)) {
    if (e is File) before[p.relative(e.path, from: src)] = await e.length();
  }
  print('  源树: ${before.length} 文件, ${before.values.fold<int>(0, (a, b) => a + b)} 字节');

  // --- 压缩 ---
  final progress = <int>[];
  final compressor = ArchiveCompressor(
    sevenZipPath: sevenZip,
    onLog: (_) {},
  );
  // 想在压缩时同时看到原始行 → 用 toPercentStream 的 onLine 旁路；
  // 这里直接给 onProgress 收百分比（端到端只验证行为）
  final archive = p.join(outDir, 'appdata.7z');
  final res = await compressor.compressDirectory(
    sourceDir: src,
    outputArchive: archive,
    onProgress: progress.add,
    throttle: const Duration(milliseconds: 30),
  );

  check(res.ok, '压缩成功', res.ok ? '${res.bytes}B fileCount=${res.fileCount}' : '${res.error}');
  if (!res.ok) {
    print('');
    return;
  }
  check(File(res.archivePath).existsSync(), '归档文件已生成');
  check(!File('${res.archivePath}.partial').existsSync(), '成功后无 .partial 残留');
  check(progress.isNotEmpty, '收到进度事件', '${progress.length} 次, 末值=${progress.last}');
  check(progress.length < 2 || _isMonotonic(progress), '进度单调不减');
  check(res.sha256.length == 64, 'SHA256 已计算', res.sha256);
  check(res.fileCount == before.length,
      '压缩时统计的文件数与源一致', '${res.fileCount} vs ${before.length}');

  // --- 7z t 校验 ---
  final t = await compressor.testArchive(res.archivePath);
  check(t.ok, '7z t 校验通过', 'exit=${t.exitCode} files=${t.fileCount} folders=${t.folderCount}');
  check(t.fileCount == before.length, '7z t 报的文件数正确',
      '${t.fileCount} vs ${before.length}');

  // --- 解包 ---
  final ex = await compressor.extractArchive(
    archivePath: res.archivePath,
    outputDir: round,
  );
  check(ex.ok, '解包成功', ex.ok ? '' : '${ex.error}');

  final after = <String, int>{};
  await for (final e in Directory(round).list(recursive: true, followLinks: false)) {
    if (e is File) after[p.relative(e.path, from: round)] = await e.length();
  }

  final missing = before.keys.where((k) => !after.containsKey(k)).toList();
  final extra = after.keys.where((k) => !before.containsKey(k)).toList();
  final sizeDiff =
      before.keys.where((k) => after[k] != null && after[k] != before[k]).toList();
  check(missing.isEmpty, '往返无缺失', '$missing');
  check(extra.isEmpty, '往返无多出', '$extra');
  check(sizeDiff.isEmpty, '往返尺寸一致', '$sizeDiff');

  // 内容逐字节比对
  var contentMismatch = 0;
  for (final k in before.keys) {
    if (!after.containsKey(k)) continue;
    final a = await File(p.join(src, k)).readAsBytes();
    final b = await File(p.join(round, k)).readAsBytes();
    if (a.length != b.length) {
      contentMismatch++;
      continue;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        contentMismatch++;
        break;
      }
    }
  }
  check(contentMismatch == 0, '往返内容逐字节一致',
      '${before.length} 个文件, 不符 $contentMismatch');

  // 空目录是否保留（7z 默认存目录条目）
  check(Directory(p.join(round, 'empty_dir')).existsSync(), '空目录已还原');

  // --- 排除开关 ---
  await File(p.join(src, '.ctgame')).writeAsString('');
  await Directory(p.join(src, 'saves')).create(recursive: true);
  await File(p.join(src, 'saves', 'x.dat')).writeAsString('should-be-excluded');
  final archive2 = p.join(outDir, 'appdata2.7z');
  final res2 = await compressor.compressDirectory(
    sourceDir: src,
    outputArchive: archive2,
    recursiveExcludes: const ['.ctgame'],
    topLevelExcludes: const ['saves'],
  );
  if (res2.ok) {
    final round2 = p.join(tmpRoot, 'roundtrip2');
    await compressor.extractArchive(archivePath: archive2, outputDir: round2);
    check(!File(p.join(round2, '.ctgame')).existsSync(), 'recursiveExcludes 生效（排除 .ctgame）');
    check(!Directory(p.join(round2, 'saves')).existsSync(), 'topLevelExcludes 生效（排除 saves/）');
  } else {
    bad('排除测试压缩失败', '${res2.error}');
  }

  // --- 自包含防护 ---
  final self = await compressor.compressDirectory(
    sourceDir: src,
    outputArchive: p.join(src, 'inside.7z'),
  );
  check(!self.ok && (self.error ?? '').contains('不能位于源目录内部'),
      '拒绝自包含归档（输出落在源目录内）');

  // --- 不存在的源 ---
  final noSrc = await compressor.compressDirectory(
    sourceDir: p.join(tmpRoot, 'not-exist'),
    outputArchive: p.join(outDir, 'x.7z'),
  );
  check(!noSrc.ok, '源目录不存在时拒绝');

  // --- 取消 ---
  final cancelArchive = p.join(outDir, 'cancel.7z');
  final fut = compressor.compressDirectory(
    sourceDir: src,
    outputArchive: cancelArchive,
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await compressor.cancel();
  final cancelled = await fut;
  check(cancelled.cancelled || !cancelled.ok, '取消能中断任务',
      'cancelled=${cancelled.cancelled} ok=${cancelled.ok}');
  check(!File(cancelArchive).existsSync(), '取消后没有生成正式归档');
  check(!File('$cancelArchive.partial').existsSync(), '取消后 .partial 已清理');

  print('  耗时/体积: 归档 ${res.bytes}B / 源 ${before.values.fold<int>(0, (a, b) => a + b)}B');
  print('');
}

// ---------------------------------------------------------------- C
void partC_manifestRoundTrip() {
  print('--- C) ArchiveManifest 序列化往返 ---');
  final m = ArchiveManifest(
    gameId: 'e2c1aaaa-bbbb-4ccc-8ddd-eeeeffff0000',
    title: 'サンプルゲーム 中文标题',
    state: ArchiveManifest.statePacked,
    createdAt: '2026-10-02T20:45:11.000+08:00',
    appVersion: '2.5.3',
    appdata: ArchivePartInfo(
      archive: 'appdata.7z',
      bytes: 1234567,
      fileCount: 42,
      sha256: _shaA,
      root: 'Games/sample',
      excluded: ['.ctgame', 'saves/'],
    ),
    saves: ArchivePartInfo(
      archive: 'saves.7z',
      bytes: 123456,
      fileCount: 12,
      sha256: _shaB,
      entries: [
        SaveEntryRef(
          path: r'C:\Users\x\AppData\Roaming\Game\save.dat',
          size: 111,
          stage: 'f0/save.dat',
        ),
        SaveEntryRef(
            path: r'D:\Games\x\savedata', size: 222, stage: 'd1', isDir: true),
      ],
    ),
    body: ArchiveBodyInfo(
      archive: 'body.7z',
      bytes: 3200000000,
      unpackedBytes: 8100000000,
      fileCount: 1234,
      sha256: _shaC,
      originalDir: r'D:\Games\sample',
      launchPath: 'sample.exe',
    ),
  );

  final text = m.toPrettyJson();
  final back = ArchiveManifest.tryParse(text);
  check(back != null, '清单可解析');
  if (back == null) return;

  check(back.gameId == m.gameId, 'gameId 往返');
  check(back.title == m.title, 'title 往返（含中日文）');
  check(back.state == m.state, 'state 往返');
  check(back.appdata?.fileCount == 42, 'appdata.fileCount 往返');
  check(back.appdata?.excluded.length == 2, 'appdata.excluded 往返');
  check(back.saves?.entries.length == 2, 'saves.entries 往返');
  check(back.saves?.entries[1].isDir == true, 'isDir 标志往返');
  check(back.saves?.entries[0].path.contains(r'AppData\Roaming') ?? false,
      '原始绝对路径完整保留');
  check(back.body?.unpackedBytes == 8100000000, 'body.unpackedBytes 往返（大数）');
  check(back.declaredFileCount == 42 + 12 + 1234, 'declaredFileCount 汇总');
  check(back.partArchives.length == 3, 'partArchives 三段齐全');
  check(back.validate().isEmpty, '自洽校验通过', '${back.validate()}');

  // 损坏 / 缺失场景
  check(ArchiveManifest.tryParse('{ not json') == null, '非法 JSON 返回 null（不抛）');
  check(ArchiveManifest.tryParse('') == null, '空串返回 null');
  check(ArchiveManifest.tryParse('{"schema":1}') == null, '缺 state 视为无效清单');
  final noBody = ArchiveManifest.tryParse(
      '{"schema":1,"game_id":"x","title":"t","state":"packed","created_at":"2026-10-02"}');
  check(noBody != null && noBody.validate().isNotEmpty,
      'packed 但缺 body 段 → 校验报错', '${noBody?.validate()}');

  // 默认值兼容（模拟"老文件"场景：字段全缺）
  final minimal = ArchiveManifest.fromJson(const {});
  check(minimal.schema == ArchiveManifest.currentSchema, 'schema 默认值');
  check(minimal.state.isEmpty, 'state 缺失为空串（供判无效）');
  print('');
}

// ---------------------------------------------------------------- D
Future<void> partD_stateMachine() async {
  print('--- D) GameStorageStateController 四态判定 ---');
  // 快判（零磁盘 I/O）
  check(GameStorageStateController.resolveFast(null) == GameStorageState.normal,
      'resolveFast(null) = normal（老数据兼容）');
  check(GameStorageStateController.resolveFast('') == GameStorageState.normal,
      'resolveFast("") = normal');
  check(GameStorageStateController.resolveFast('sealed') == GameStorageState.sealed,
      'resolveFast(sealed)');
  check(GameStorageStateController.resolveFast('packed') == GameStorageState.packed,
      'resolveFast(packed)');
  check(
      GameStorageStateController.resolveFast('garbage') == GameStorageState.normal,
      'resolveFast(未知值) = normal（宽松解析）');
  check(GameStorageState.displayOnly.isDerived, 'display_only 是派生态');
  check(!GameStorageState.normal.hasArchive, 'normal 无归档');

  // 核验判定（真实临时目录）
  final base = p.join(tmpRoot, 'state');
  await _rmrf(base);
  final body = p.join(base, 'body');
  final archOk = p.join(base, 'arch_ok');
  final archNoMeta = p.join(base, 'arch_no_meta');
  final archMissingPart = p.join(base, 'arch_missing_part');

  await Directory(body).create(recursive: true);
  await File(p.join(body, 'game.exe')).writeAsString('x');

  // 一份健康的 sealed 归档
  final sealedManifest = ArchiveManifest(
    gameId: 'g1',
    title: 't',
    state: ArchiveManifest.stateSealed,
    createdAt: '2026-10-02T20:00:00+08:00',
    appdata: const ArchivePartInfo(
        archive: 'appdata.7z', bytes: 10, fileCount: 1),
  );
  await Directory(archOk).create(recursive: true);
  await File(p.join(archOk, ArchiveManifest.fileName))
      .writeAsString(sealedManifest.toPrettyJson());
  await File(p.join(archOk, 'appdata.7z')).writeAsBytes(List.filled(10, 1));

  // 缺 meta.json 的半成品
  await Directory(archNoMeta).create(recursive: true);
  await File(p.join(archNoMeta, 'appdata.7z')).writeAsBytes(List.filled(10, 1));

  // meta 声明了 appdata.7z 但文件不在
  await Directory(archMissingPart).create(recursive: true);
  await File(p.join(archMissingPart, ArchiveManifest.fileName))
      .writeAsString(sealedManifest.toPrettyJson());

  Future<GameStorageResolution> rv(String? state, String dir, String arch) =>
      GameStorageStateController.resolveVerified(
          storedStorageState: state, directoryPath: dir, archiveDir: arch);

  var r = await rv(null, body, '');
  check(r.state == GameStorageState.normal, 'normal 态 + 本体在 → normal');
  check(r.bodyExists, 'bodyExists=true');

  r = await rv(null, p.join(base, 'ghost'), '');
  check(r.state == GameStorageState.displayOnly, '本体不在 → display_only');
  check(!r.bodyExists, 'bodyExists=false');

  r = await rv('sealed', p.join(base, 'ghost'), archOk);
  check(r.state == GameStorageState.sealed, 'sealed + 归档健康 + 本体不在 → sealed');
  check(!r.degraded, '未降级');
  check(r.manifest != null, '返回清单');

  r = await rv('sealed', body, archOk);
  check(r.state == GameStorageState.normal, 'sealed + 本体回来了 → normal');

  r = await rv('sealed', p.join(base, 'ghost'), archNoMeta);
  check(r.state == GameStorageState.displayOnly, 'sealed + 归档缺 meta → 降级 display_only');
  check(r.degraded, '标记降级');
  check(r.reason.contains('meta.json'), '降级原因指明 meta.json', r.reason);

  r = await rv('sealed', body, archNoMeta);
  check(r.state == GameStorageState.normal, 'sealed + 归档坏 + 本体在 → normal（降级但可玩）');
  check(r.degraded, '标记降级');

  r = await rv('sealed', p.join(base, 'ghost'), archMissingPart);
  check(r.state == GameStorageState.displayOnly, 'sealed + 分片缺失 → 降级');
  check(r.reason.contains('分片缺失'), '降级原因指明分片', r.reason);

  r = await rv('packed', p.join(base, 'ghost'), archOk);
  check(r.state == GameStorageState.displayOnly, 'packed + 归档无 body 段 → 降级');
  check(r.degraded, 'packed 降级标记');

  r = await rv('packed', p.join(base, 'ghost'), '');
  check(r.state == GameStorageState.displayOnly, 'packed 但没记归档目录 → 降级');

  r = await rv('packed', p.join(base, 'ghost'), p.join(base, 'nope'));
  check(r.state == GameStorageState.displayOnly, 'packed + 归档目录不存在 → 降级');

  // packed 健康路径
  final packedDir = p.join(base, 'arch_packed');
  final packedManifest = ArchiveManifest(
    gameId: 'g2',
    title: 't',
    state: ArchiveManifest.statePacked,
    createdAt: '2026-10-02T21:00:00+08:00',
    appdata: const ArchivePartInfo(archive: 'appdata.7z', bytes: 10, fileCount: 1),
    body: const ArchiveBodyInfo(
        archive: 'body.7z', bytes: 100, unpackedBytes: 500, fileCount: 3),
  );
  await Directory(packedDir).create(recursive: true);
  await File(p.join(packedDir, ArchiveManifest.fileName))
      .writeAsString(packedManifest.toPrettyJson());
  await File(p.join(packedDir, 'appdata.7z')).writeAsBytes(List.filled(10, 1));
  await File(p.join(packedDir, 'body.7z')).writeAsBytes(List.filled(100, 1));

  r = await rv('packed', p.join(base, 'ghost'), packedDir);
  check(r.state == GameStorageState.packed, 'packed 健康 → packed');
  check(!r.degraded, 'packed 未降级');

  print('');
}

// ---------------------------------------------------------------- E
Future<void> partE_sha256() async {
  print('--- E) SHA256（复用内置 7z，对齐 RFC 标准向量）---');
  final dir = p.join(tmpRoot, 'sha');
  await Directory(dir).create(recursive: true);
  final f = File(p.join(dir, 'abc.txt'));
  await f.writeAsBytes(utf8.encode('abc'));

  final c = ArchiveCompressor(sevenZipPath: sevenZip);
  final got = await c.sha256OfFile(f.path);
  const expect = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
  check(got == expect, 'SHA256("abc") 命中 RFC 向量', got.isEmpty ? '(空)' : got);

  final missing = await c.sha256OfFile(p.join(dir, 'nope.txt'));
  check(missing.isEmpty, '文件不存在时返回空串（不抛）');
  print('');
}

// ---------------------------------------------------------------- F
Future<void> partF_partialMarker() async {
  print('--- F) 半成品（.partial）行为 ---');
  final src = p.join(tmpRoot, 'psrc');
  await _rmrf(src);
  await Directory(src).create(recursive: true);
  await File(p.join(src, 'a.txt')).writeAsString('a');

  final c = ArchiveCompressor(sevenZipPath: sevenZip);

  // 预置一个同名 .partial 残留 → 应被清掉后重新压缩
  final out = p.join(tmpRoot, 'pout', 'x.7z');
  await Directory(p.dirname(out)).create(recursive: true);
  await File('$out.partial').writeAsString('stale-partial');

  final r = await c.compressDirectory(sourceDir: src, outputArchive: out);
  check(r.ok, '覆盖已有 .partial 后压缩成功', r.ok ? '' : '${r.error}');
  check(!File('$out.partial').existsSync(), '旧 .partial 已被替换/清除');
  check(File(out).existsSync(), '正式产物存在');
  print('');
}

bool _isMonotonic(List<int> v) {
  for (var i = 1; i < v.length; i++) {
    if (v[i] < v[i - 1]) return false;
  }
  return true;
}

Future<void> _rmrf(String path) async {
  final d = Directory(path);
  if (await d.exists()) {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }
}
