// Phase 3 · 端到端探针：打包（含回收站删本体）→ 解包还原 全链路
//
// 覆盖 GameArchiveService.pack(removeBody:true) / unpack() 的全部底层原语
// （这些编排层 import flutter，探针无法直接加载；这里按相同顺序调用同一批
// flutter-free 原语类，验证真实行为而非 mock）：
//   1. ArchiveCompressor.compressDirectory   —— 压缩假本体（含中日文文件名）
//   2. ArchiveCompressor.testArchive         —— 7z t 全量校验
//   3. RecycleBinService.moveToRecycleBin    —— FFI 回收站删源（Phase 0 路径）
//   4. ArchiveCompressor.extractArchive      —— 解压回原目录（unpack 核心）
//   5. 逐文件字节比对 + countFilesRecursive 交叉比对
//
// ⚠️ 会向真实回收站放入 1 个小目录（.workbuddy/tmp/phase3/...，几 KB），
//    与 Phase 0 探针同等代价；可随时在系统回收站清掉。
// 运行：
//   ./flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages=D:/CTLIB/.dart_tool/package_config.json \
//     dev_probe/phase3_recycle_unpack_probe.dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lib/services/archive_compressor.dart';
import '../lib/services/recycle_bin_service.dart';
import '../lib/services/seven_zip_progress.dart';

const String sevenZip = r'D:\CTLIB\windows\runner\tools\7z.exe';
const String root = r'D:\CTLIB\.workbuddy\tmp\phase3';

int passed = 0, failed = 0;
final failures = <String>[];

void check(bool cond, String name) {
  if (cond) {
    passed++;
    print('  PASS  $name');
  } else {
    failed++;
    failures.add(name);
    print('  FAIL  $name');
  }
}

final Map<String, List<int>> _fileMap = {};

void writeFile(String path, List<int> bytes) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  _fileMap[path] = bytes;
}

/// 以 [dir] 为基准逐文件字节比对 [_fileMap]（注意：调用方需保证 _fileMap
/// 只含本段用例的文件 —— 用 [resetMap] 清场）。
void resetMap() => _fileMap.clear();

void seedBody(String dir) {
  resetMap();
  writeFile('$dir\\boot.exe', List.generate(4096, (i) => i & 0xFF));
  writeFile('$dir\\data\\scripts\\main.dat',
      List.generate(1024 * 33, (i) => (i * 7) & 0xFF));
  writeFile('$dir\\data\\中文目录\\说明.txt', utf8.encode('中文内容验证'));
  writeFile('$dir\\data\\中文目录\\日文ファイル.cfg', utf8.encode('セーブデータ'));
  Directory('$dir\\empty_dir').createSync(recursive: true);
}

bool verifyRestored(String dir) {
  for (final e in _fileMap.entries) {
    final rel = p.relative(e.key, from: dir);
    final f = File(p.join(dir, rel));
    if (!f.existsSync()) {
      print('        缺文件: $rel');
      return false;
    }
    final got = f.readAsBytesSync();
    final want = e.value;
    if (got.length != want.length) {
      print('        长度不符: $rel (${got.length} vs ${want.length})');
      return false;
    }
    for (var i = 0; i < want.length; i++) {
      if (got[i] != want[i]) {
        print('        字节不符: $rel @#$i');
        return false;
      }
    }
  }
  return true;
}

Future<void> main() async {
  final base = Directory(root);
  if (base.existsSync()) base.deleteSync(recursive: true);
  base.createSync(recursive: true);

  final compressor = ArchiveCompressor(sevenZipPath: sevenZip);

  // ========== 1. 回收站服务单测（小目录） ==========
  print('\n[1] RecycleBinService —— 回收站往返');
  {
    final victim = p.join(root, 'recycle_victim');
    writeFile('$victim\\a.txt', 'hello'.codeUnits);
    Directory('$victim\\sub').createSync(recursive: true);
    writeFile('$victim\\sub\\b.txt', 'world'.codeUnits);

    final missing = await RecycleBinService.moveToRecycleBin('$victim\\nope.txt');
    check(!missing.ok, '目标不存在时拒绝并报错');

    final out = await RecycleBinService.moveToRecycleBin(victim);
    check(out.ok, 'moveToRecycleBin 成功（$out）');
    check(!Directory(victim).existsSync(), '源目录已消失');
    final empty = await RecycleBinService.moveToRecycleBin('');
    check(!empty.ok, '空路径拒绝');
  }

  // ========== 2. pack(removeBody) → unpack 全链路 ==========
  print('\n[2] 打包→回收站删本体→解包还原（含中日文文件名）');
  {
    final bodyDir = p.join(root, 'game_body');
    seedBody(bodyDir);
    final expectedFiles = await ArchiveCompressor.countFilesRecursive(bodyDir);

    // --- pack: 压缩 ---
    final archive = p.join(root, 'body.7z');
    final c = await compressor.compressDirectory(
      sourceDir: bodyDir,
      outputArchive: archive,
      onProgress: (_) {},
    );
    check(c.ok, 'compressDirectory 成功（${c.error ?? ''}）');
    check(File(archive).existsSync(), 'body.7z 已生成');
    check(SevenZipProgressParser.isSuccessCode(c.exitCode), 'exit code = 0');
    // --- pack: 校验 ---
    final t = await compressor.testArchive(archive);
    check(t.ok, 'testArchive 通过');

    // --- pack: 回收站删源 ---
    final rb = await RecycleBinService.moveToRecycleBin(bodyDir);
    check(rb.ok, '本体移入回收站（$rb）');
    check(!Directory(bodyDir).existsSync(), '原本体目录已消失');

    // --- unpack: 空间预检通过后解回原目录（服务同款流程） ---
    final target = Directory(bodyDir);
    final existsBefore = target.existsSync();
    check(!existsBefore, 'unpack 前置：目标目录不存在（服务会拒绝已存在目标）');
    target.createSync(recursive: true);
    final x = await compressor.extractArchive(
      archivePath: archive,
      outputDir: bodyDir,
      onProgress: (_) {},
    );
    check(x.ok, 'extractArchive 解回原目录（${x.error ?? ''}）');
    check(verifyRestored(bodyDir), '逐文件字节比对全部一致（含中日文路径）');

    final actual = await ArchiveCompressor.countFilesRecursive(bodyDir);
    check(actual == expectedFiles, '文件数交叉比对（$actual == $expectedFiles）');
  }

  // ========== 3. 拒绝覆盖语义（服务 unpack 守卫的底层依据） ==========
  print('\n[3] 目标已存在时的行为');
  {
    final src = p.join(root, 'src2');
    seedBody(src);
    final archive2 = p.join(root, 'body2.7z');
    final c2 = await compressor.compressDirectory(
      sourceDir: src,
      outputArchive: archive2,
    );
    check(c2.ok, '第二次压缩成功');

    // 模拟「目标目录已存在」：往里放一个哨兵文件再解压 —— 7z 覆盖模式只覆盖
    // 归档内存在的文件、**不清理额外文件**（哨兵会存活）。这正是服务层
    // unpack 必须坚持「目标已存在即拒绝」的原因：对旧目录解压得到的是
    // 「归档 ∪ 残留」的混合体，不是干净还原。
    File('$src\\sentinel.txt').writeAsStringSync('user-data');
    final x2 = await compressor.extractArchive(
      archivePath: archive2,
      outputDir: src,
    );
    check(x2.ok, 'extractArchive(overwrite) 技术上可行');
    check(File('$src\\sentinel.txt').existsSync(),
        '哨兵文件存活 ⇒ 解压是「合并」而非「干净还原」⇒ 服务层目标存在即拒绝的守卫必要');
  }

  print('\n========== 结果: $passed PASS / $failed FAIL ==========');
  if (failures.isNotEmpty) {
    print('失败项:');
    for (final f in failures) {
      print('  - $f');
    }
    exitCode = 1;
  }
}
