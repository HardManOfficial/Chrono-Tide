// P4 只读/纯逻辑部分的离线验证（不写任何游戏目录）
//
// 覆盖三块：
//   A. 路径护栏（zip slip / 绝对路径 / 盘符 / 保留名 / 剥壳）
//   B. 落点预览规则（对照 P0-4 采到的 4 种真实形态）
//   C. 真实包解压到隔离区（用 D:\CTLIB\.workbuddy\tmp\patch_sample 的 4 个样本）
//
// 运行：
//   set FLUTTER_ROOT=D:\CTLIB\env\toolchains\flutter
//   set PUB_CACHE=D:\CTLIB\env\cache\pub
//   <dart-sdk>\dart.exe dev_probe/patch_install_probe.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../lib/services/patch/patch_download_core.dart';
import '../lib/services/patch/patch_extract_service.dart';
import '../lib/services/patch/patch_path_guard.dart';
import '../lib/services/patch/patch_preview.dart';

const String _sampleDir = r'D:\CTLIB\.workbuddy\tmp\patch_sample';
const String _workDir = r'D:\CTLIB\.workbuddy\tmp\patch_extract';

int _pass = 0;
int _fail = 0;

void _ok(String what, [String extra = '']) {
  _pass++;
  final suffix = extra.isEmpty ? '' : ' | ' + extra;
  stdout.writeln('  PASS | ' + what + suffix);
}

void _no(String what, [String extra = '']) {
  _fail++;
  final suffix = extra.isEmpty ? '' : ' | ' + extra;
  stdout.writeln('  FAIL | ' + what + suffix);
}

void _section(String s) => stdout.writeln('\n=== $s ===');

Future<void> main() async {
  _section('A. 路径护栏');
  _guardTests();

  _section('B. 落点预览规则（对照 4 种真实形态）');
  _previewTests();

  _section('C. 真实包解压到隔离区');
  await _extractTests();

  _section('D. 保存到用户选定目录（纯下载语义）');
  await _saveToUserDirTests();

  stdout.writeln('\n结果: ${_fail == 0 ? '全部通过' : '$_fail 项失败'}'
      '  (PASS=$_pass FAIL=$_fail)');
  exitCode = _fail == 0 ? 0 : 1;
}

// ==================== A ====================

void _guardTests() {
  // 正常
  _eq('普通路径', normalizeEntryPath('a/b/c.txt'), 'a/b/c.txt');
  _eq('反斜杠归一', normalizeEntryPath(r'a\b\c.txt'), 'a/b/c.txt');
  _eq('点段丢弃', normalizeEntryPath('./a/b'), 'a/b');
  _eq('前导斜杠丢弃后仍算绝对', normalizeEntryPath('/etc/x'), null);

  // 穿越 —— 必须全部 null
  _eq('穿越 ..', normalizeEntryPath('../a'), null);
  _eq('中间穿越', normalizeEntryPath('a/../../b'), null);
  _eq('深层穿越', normalizeEntryPath('a/b/../../../c'), null);
  _eq('反斜杠穿越', normalizeEntryPath(r'a\..\..\..\c'), null);

  // 绝对 / 盘符 / UNC
  _eq('盘符', normalizeEntryPath(r'C:\Windows\x.dll'), null);
  _eq('盘符正斜杠', normalizeEntryPath('D:/x'), null);
  _eq('UNC', normalizeEntryPath(r'\\server\share\x'), null);

  // 保留名（清洗而非拒绝）
  final con = normalizeEntryPath('dir/CON.txt');
  _ok('保留名被改写', 'CON.txt → ${con!.split('/').last}');
  _bool('保留名加前缀', con.split('/').last.startsWith('_'));

  // 非法字符
  final bad = normalizeEntryPath('a/b<c>d?.txt');
  _ok('非法字符替换', bad.toString());
  _bool('不含尖括号', !bad!.contains('<') && !bad.contains('?'));

  // 空 / 纯点
  _eq('空串', normalizeEntryPath('   '), null);
  _eq('纯点', normalizeEntryPath('.'), null);

  // validateEntryPaths
  final badList = validateEntryPaths(<String>[
    'ok/a.txt',
    '../evil.dll',
    r'C:\x.exe',
    'ok/b.txt',
  ]);
  _eq('validate 抓出 2 个非法', badList.length, 2);
  _eq('validate 保留原文', badList.first, '../evil.dll');

  // ---- 剥壳 ----
  final wrapped = resolveLayout(<String>[
    'hoshiori_patch_v102/update.exe',
    'hoshiori_patch_v102/update.ini',
    'hoshiori_patch_v102/GameData/Scene.pck',
  ]);
  _eq('剥掉唯一外层目录', wrapped.wrapper, 'hoshiori_patch_v102');
  _eq('剥壳后条目数', wrapped.paths.length, 3);
  _bool('剥壳后首条不含外层', !wrapped.paths.any((p) => p.contains('hoshiori')));

  // 单文件包：顶层段是文件，⛔ 不能剥
  final single = resolveLayout(<String>['Setup.exe']);
  _eq('单文件不剥壳', single.wrapper, null);
  _eq('单文件保留原名', single.paths.single, 'Setup.exe');

  // 无统一前缀：不剥
  final flat = resolveLayout(<String>['a/x.txt', 'b/y.txt']);
  _eq('多顶层不剥壳', flat.wrapper, null);
  _eq('多顶层条目数', flat.paths.length, 2);

  // 带显式目录条目
  final withDirs = resolveLayout(<String>[
    'PATCH/',
    'PATCH/readme.txt',
    'PATCH/bin/x.dll',
  ]);
  _eq('目录条目不计入文件', withDirs.paths.length, 2);
  _eq('目录条目不影响剥壳', withDirs.wrapper, 'PATCH');

  // 剥完为空 ⇒ 不剥（防呆）
  final onlyDir = resolveLayout(<String>['X/']);
  _eq('只有空目录不剥壳', onlyDir.wrapper, null);
  _eq('只有空目录无条目', onlyDir.paths.length, 0);
}

// ==================== B ====================

void _previewTests() {
  // --- 形态 1：换 exe 型（Humanity：exe + script.dcn）---
  final form1NoGame = previewFromRawPaths(<String>[
    'Humanity_CN_@ic/Humanity_CN_@ic.exe',
    'Humanity_CN_@ic/script.dcn',
  ]);
  _eq('换exe型/无游戏信息 → 保守放子目录', form1NoGame.advice,
      PatchTargetAdvice.patchSubdir);
  _eq('换exe型/剥壳', form1NoGame.wrapper, 'Humanity_CN_@ic');

  final form1 = previewFromRawPaths(
    <String>[
      'Humanity_CN_@ic/Humanity_CN_@ic.exe',
      'Humanity_CN_@ic/script.dcn',
    ],
    gameExeNames: <String>['humanity_cn_@ic.exe'],
  );
  _eq('换exe型/给了游戏exe名 → 游戏根', form1.advice, PatchTargetAdvice.gameRoot);
  _bool('换exe型有替换告警', form1.warnings.any((w) => w.contains('替换')));

  // --- 形态 2：DLL 注入型（パニカル：winmm.dll 等）---
  final form2 = previewFromRawPaths(
    <String>[
      'パニカル翻訳补丁/winmm.dll',
      'パニカル翻訳补丁/LoaderDll.dll',
      'パニカル翻訳补丁/LocaleEmulator.dll',
      'パニカル翻訳补丁/FONTCHANGER.dll',
      'パニカル翻訳补丁/hook.ini',
      'パニカル翻訳补丁/font.ttf',
      'パニカル翻訳补丁/configure.exe',
      'パニカル翻訳补丁/パニカルコンフュージョン_CN.exe',
      'パニカル翻訳补丁/パニカルコンフュージョン_CN.bin',
      'パニカル翻訳补丁/先看我.txt',
    ],
  );
  _eq('DLL型 → 游戏根', form2.advice, PatchTargetAdvice.gameRoot);
  _eq('DLL型识别出 4 个库', form2.libraries.length, 4);
  _eq('DLL型识别出 1 个说明文件', form2.readmes.length, 1);
  _eq('DLL型说明文件名', form2.readmes.single.name, '先看我.txt');
  _bool('DLL型有「放子目录不生效」告警', form2.warnings.any((w) => w.contains('不会生效')));

  // --- 形态 3：覆盖式（星織：GameData 树 + update.exe）---
  final form3 = previewFromRawPaths(
    <String>[
      'hoshiori_patch_v102/GameData/Gameexe.dat',
      'hoshiori_patch_v102/GameData/Scene.pck',
      'hoshiori_patch_v102/GameData/g00/_smh_ls_mr.g00',
      'hoshiori_patch_v102/GameData/koe/z9990.ovk',
      'hoshiori_patch_v102/update.exe',
      'hoshiori_patch_v102/update.ini',
      'hoshiori_patch_v102/★はじめにお読み下さい.txt',
    ],
    gameTopDirs: <String>['gamedata'],
  );
  _eq('覆盖式 → 游戏根', form3.advice, PatchTargetAdvice.gameRoot);
  _eq('覆盖式识别数据文件 4 个', form3.dataFiles.length, 4);
  _eq('覆盖式识别配置 1 个', form3.configs.length, 1);
  _bool('覆盖式理由提到 gamedata', form3.reason.contains('GameData'));

  // --- 形态 4：单文件安装器 ---
  final form4 = previewFromRawPaths(<String>[
    '【樱空汉化组】9-nine-…Ver1.0/Setup.exe',
  ]);
  _eq('安装器型 → 只引导', form4.advice, PatchTargetAdvice.installerOnly);
  _bool('安装器型有「不代跑」告警', form4.warnings.any((w) => w.contains('不会代跑')));

  // --- 非法包 → blocked ---
  final evil = previewFromRawPaths(<String>[
    'ok/patch.dll',
    '../../../Windows/System32/evil.dll',
  ]);
  _eq('穿越包 → blocked', evil.advice, PatchTargetAdvice.blocked);
  _eq('穿越包无文件', evil.files.length, 0);
  _bool('穿越包告警里带原文', evil.warnings.any((w) => w.contains('evil.dll')));

  // --- 空包 → blocked ---
  final empty = previewFromRawPaths(<String>[]);
  _eq('空包 → blocked', empty.advice, PatchTargetAdvice.blocked);

  // --- 兜底：纯资源包 → 子目录 ---
  final safe = previewFromRawPaths(<String>[
    'extras/cg/cg01.png',
    'extras/cg/cg02.png',
  ]);
  _eq('纯资源包 → 补丁目录', safe.advice, PatchTargetAdvice.patchSubdir);
  _eq('纯资源包总数正确', safe.files.length, 2);

  // --- 体积汇总 ---
  final sized = previewFromRawPaths(
    <String>['p/a.bin', 'p/b.bin'],
    sizes: <String, int>{'a.bin': 1024 * 1024, 'b.bin': 2 * 1024 * 1024},
  );
  _ok('体积汇总（剥壳后按原路径取）', '${sized.totalBytes}');
  _bool('体积不为 0', sized.totalBytes > 0);
}

// ==================== C ====================

Future<void> _extractTests() async {
  final samples = Directory(_sampleDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.zip'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (samples.isEmpty) {
    _no('样本目录里没有 zip', _sampleDir);
    return;
  }
  _ok('找到样本', '${samples.length} 个');

  const svc = PatchExtractService();

  // 反例先跑：进程内造一个含穿越路径的 zip，证明护栏真的拦得住
  await _traversalArchiveCase(svc);

  for (final f in samples) {
    final name = f.path.split(RegExp(r'[\\/]')).last;
    stdout.writeln('\n  -- ' + name);
    final dest = patchExtractDirFor(_workDir, name);

    // 0) 容器嗅探
    final container = PatchExtractService.sniffContainer(f.path);
    _eq('容器识别为 zip', container, 'zip');

    // 1) 列条目
    List<PatchEntry> listed;
    try {
      listed = await svc.listEntries(f.path);
    } catch (e) {
      _no('列条目失败', e.toString());
      continue;
    }
    _bool('列出条目非空', listed.isNotEmpty, '${listed.length} 条');

    // 2) 护栏
    final bad = validateEntryPaths(listed.map((e) => e.path));
    _eq('真实包无非法路径', bad.length, 0);

    // 3) 解压
    PatchExtractResult res;
    try {
      res = await svc.extractTo(archivePath: f.path, destDir: dest);
    } catch (e) {
      _no('解压失败', e.toString());
      continue;
    }
    _bool('剥掉了外层目录', res.wrapper != null, '${res.wrapper}');
    _bool('解压出文件', res.entries.isNotEmpty, '${res.entries.length} 个');
    _bool('extracted 目录存在', Directory(res.rootPath).existsSync());
    // 只看「被当作目录前缀」的情况：包内可能存在与目录同名的文件
    // （Humanity 包里就有 Humanity_CN_@ic/Humanity_CN_@ic.exe），那不算残留
    _bool(
        '外层目录不再作为前缀出现',
        !res.entries
            .any((e) => e.path.startsWith((res.wrapper ?? '\u0000') + '/')));

    // 4) 实际树 == 清单
    final onDisk = <String>[];
    await for (final e
        in Directory(res.rootPath).list(recursive: true, followLinks: false)) {
      if (e is File) {
        onDisk.add(
            e.path.substring(res.rootPath.length + 1).replaceAll('\\', '/'));
      }
    }
    final a = onDisk.toSet();
    final b = res.entries.map((e) => e.path).toSet();
    _eq('磁盘文件数 == 清单数', a.length, b.length);
    _bool('磁盘内容 == 清单内容', a.difference(b).isEmpty && b.difference(a).isEmpty,
        '差异 ${a.difference(b).length}/${b.difference(a).length}');

    // 5) 体积不为 0（剥壳后按原路径取体积的回归点）
    _bool('体积汇总不为 0', res.totalBytes > 0, '${res.totalBytes}');

    // 6) 再解一次：不能残留叠加（幂等）
    final again = await svc.extractTo(archivePath: f.path, destDir: dest);
    _eq('二次解压文件数不变', again.entries.length, res.entries.length);

    // 7) 预览能跑出结论
    final pv = res.toPreview();
    _ok('预览落点', '${pv.advice.name} — ${pv.reason}');
    _bool('预览文件数一致', pv.files.length == res.entries.length);
  }
}

/// 进程内造一个含穿越路径的 zip，验证「整包拒绝」
Future<void> _traversalArchiveCase(PatchExtractService svc) async {
  final dir = Directory('$_workDir\\_evil');
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create(recursive: true);

  final archive = Archive();
  final payload = Uint8List.fromList(List<int>.filled(32, 0x41));
  archive.addFile(ArchiveFile('ok/patch.dll', payload.length, payload));
  final evil = Uint8List.fromList(List<int>.filled(32, 0x42));
  // 名字里带 .. 的条目（zip slip 的经典形态）
  archive.addFile(ArchiveFile('../../../evil.dll', evil.length, evil));

  final bytes = ZipEncoder().encode(archive)!;
  final zipPath = '${dir.path}\\evil.zip';
  await File(zipPath).writeAsBytes(bytes);

  // 包外不能有 evil.dll 的基线
  final outside = File('$_workDir\\evil.dll');
  if (outside.existsSync()) await outside.delete();

  final dest = patchExtractDirFor(_workDir, '_evil');
  try {
    await svc.extractTo(archivePath: zipPath, destDir: dest);
    _no('穿越包居然解压成功了');
  } on PatchExtractException catch (e) {
    _bool('穿越包被整包拒绝', e.rejectedEntries.isNotEmpty,
        '拒 ${e.rejectedEntries.length} 项：${e.message}');
  } catch (e) {
    _no('穿越包抛出非预期异常', e.toString());
  }

  _bool('包外未被写入', !outside.existsSync());
  _bool('解压产物已清理', !Directory('$dest\\extracted').existsSync());
}

// ==================== D ====================

/// 纯下载器语义（2026-11-10 用户定调）：
/// 下到用户选定的目录 → 原地解压一份 → 结束。⛔ 不碰游戏目录。
Future<void> _saveToUserDirTests() async {
  // ---- D1 包名 → 解压目录基名 ----
  _eq('去扩展名', archiveBaseName('鲲_12345_汉化补丁.zip'), '鲲_12345_汉化补丁');
  _eq('无扩展名原样', archiveBaseName('patchfile'), 'patchfile');
  _eq('只去最后一个扩展名', archiveBaseName('a.b.zip'), 'a.b');
  _eq('路径前缀被剥掉', archiveBaseName(r'C:\x\y\p.zip'), 'p');

  // ---- D2 重名不合并（两个补丁都带 GameData/ 时必须各自独立）----
  _eq('无冲突用基名', uniqueExtractDirName('p.zip', <String>['other']), 'p');
  _eq('冲突加 _2', uniqueExtractDirName('p.zip', <String>['p']), 'p_2');
  _eq('再冲突加 _3', uniqueExtractDirName('p.zip', <String>['p', 'p_2']), 'p_3');
  _eq('大小写也算冲突', uniqueExtractDirName('P.zip', <String>['p']), 'P_2');

  // ---- D3 扁平解压：不要 extracted 这层，压缩包必须还在 ----
  final samples = Directory(_sampleDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.zip'))
      .toList();
  if (samples.isEmpty) {
    _no('扁平解压无样本可用', _sampleDir);
    return;
  }
  final src = samples.first;
  final saveDir = Directory(p.join(_workDir, 'user_pick'));
  if (saveDir.existsSync()) saveDir.deleteSync(recursive: true);
  saveDir.createSync(recursive: true);

  final archive = File(p.join(saveDir.path, p.basename(src.path)));
  await src.copy(archive.path);
  _ok('模拟「下到用户选的目录」', p.basename(archive.path));

  final baseName = uniqueExtractDirName(p.basename(archive.path), <String>[]);
  final target = p.join(saveDir.path, baseName);
  final res = await const PatchExtractService()
      .extractTo(archivePath: archive.path, destDir: target, outDirName: '');
  _eq('解压根 == 落点目录（没有 extracted 层）', res.rootPath, target);
  _bool('落点目录里直接是文件', res.entries.isNotEmpty, '${res.entries.length} 个');
  _bool('压缩包仍在（解压不能动到成品）', archive.existsSync());
  final hint = res.toPreview().usageHint ?? '';
  _bool('包形态提示非空', hint.isNotEmpty, hint);

  // ---- D4 第二次解压换独立目录，绝不叠进同一个 ----
  final existing = saveDir
      .listSync()
      .whereType<Directory>()
      .map((d) => p.basename(d.path))
      .toList();
  final second = uniqueExtractDirName(p.basename(archive.path), existing);
  _bool('第二次解压换到独立目录', second != baseName, second);

  // ---- D5 四种形态的「以后怎么用」提示（软件唯一能帮到用户的地方）----
  final dll = previewFromRawPaths(<String>['winmm.dll', 'hook.ini']);
  _bool('DLL 型提示要求 exe 同目录', (dll.usageHint ?? '').contains('同一目录'),
      dll.usageHint ?? '');

  // 覆盖式：喂**剥壳后**的条目（真实链路就是先解压剥壳再判形态，
  // 否则 `GameData/` 会被当成外层目录剥掉，永远判不出"同构"）
  final cov = buildPatchPreview(
    entries: const <PatchEntry>[
      PatchEntry(path: 'GameData/Scene.pck', size: 1),
      PatchEntry(path: 'GameData/g00/a.pck', size: 1),
    ],
    gameTopDirs: <String>['gamedata'],
  );
  _bool(
      '覆盖式提示提到原文覆盖', (cov.usageHint ?? '').contains('覆盖'), cov.usageHint ?? '');

  final inst = previewFromRawPaths(<String>['Setup.exe']);
  _bool('安装器提示让用户自己双击', (inst.usageHint ?? '').contains('双击'),
      inst.usageHint ?? '');

  final empty = previewFromRawPaths(<String>[]);
  _bool('空包提示不空', (empty.usageHint ?? '').isNotEmpty, empty.usageHint ?? '');
}

// ==================== 断言小工具 ====================

void _eq(String what, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    _ok(what, '$actual');
  } else {
    _no(what, '期望 $expected / 实际 $actual');
  }
}

void _bool(String what, bool cond, [String extra = '']) {
  if (cond) {
    _ok(what, extra);
  } else {
    _no(what, extra);
  }
}
