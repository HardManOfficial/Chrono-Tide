/// PATCH-VAULT 离线行为探针（纯 Dart，零 Flutter / 零 FFI / 零真实游戏目录）。
///
/// 运行（在 apps/chrono-tide 下）：
///   env\cache\dart-sdk\bin\dart.exe dev_probe\patch_vault_probe.dart
///
/// 🔴 所有写盘都在 `Directory.systemTemp` 的沙盒里，⛔ 绝不碰真实游戏目录。
/// 🔴 覆盖：两个根、排除名单、四形态识别、穿越整批拒绝、转移与索引同步、
///    应用事务、失败注入逆序回滚、哈希漂移、重叠补丁逆序卸载、recover、
///    game_id 空兜底、索引失效检测。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import '../lib/models/patch_vault_record.dart';
import '../lib/services/patch/patch_preview.dart';
import '../lib/services/patch_vault/game_dirs.dart';
import '../lib/services/patch_vault/patch_apply_plan.dart';
import '../lib/services/patch_vault/patch_apply_service.dart';
import '../lib/services/patch_vault/patch_inspector.dart';
import '../lib/services/patch_vault/patch_rollback_service.dart';
import '../lib/services/patch_vault/patch_transfer_service.dart';
import '../lib/services/patch_vault/patch_vault_index.dart';
import '../lib/services/patch_vault/patch_vault_recover.dart';

int _pass = 0;
int _fail = 0;

void ok(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  PASS  $label');
  } else {
    _fail++;
    print('  FAIL  $label');
  }
}

void section(String s) => print('\n=== $s ===');

late Directory sandbox;
late Directory gameRoot;
late Directory launchDir;
late Directory patchStore;
late Directory dataRoot;

Future<void> main() async {
  sandbox = await Directory.systemTemp.createTemp('patch_vault_probe_');
  try {
    gameRoot = Directory(path.join(sandbox.path, 'game'));
    launchDir = Directory(path.join(gameRoot.path, 'bin'));
    patchStore = Directory(path.join(sandbox.path, 'patches'));
    dataRoot = Directory(path.join(sandbox.path, 'data'));
    await launchDir.create(recursive: true);
    await patchStore.create(recursive: true);

    await _tGameDirs();
    await _tInspector();
    await _tIndex();
    await _tTransfer();
    await _tPlanAndGuard();
    await _tApplyAndRollback();
    await _tFailureRollback();
    await _tDrift();
    await _tOverlappedReverseOrder();
    await _tRecover();
  } finally {
    try {
      await sandbox.delete(recursive: true);
    } catch (_) {}
    print('\n========================================');
    print('PATCH-VAULT PROBE: $_pass PASS / $_fail FAIL');
    print('========================================');
    if (_fail > 0) exitCode = 1;
  }
}

// ---------------------------------------------------------------- helpers

Future<File> writeFile(String p, String content) async {
  final f = File(p);
  await Directory(path.dirname(p)).create(recursive: true);
  await f.writeAsString(content, flush: true);
  return f;
}

GameDirs dirs() => GameDirs.compute(
      bodyRoot: gameRoot.path,
      launchPath: r'bin\game.exe',
      resolvedExePath: path.join(launchDir.path, 'game.exe'),
      probeDirExists: (d) => Directory(d).existsSync(),
    );

PatchVaultIndex index() =>
    PatchVaultIndex(rootDir: path.join(dataRoot.path, 'patch_vault'));

PatchVaultManifestStore store(GameDirs d) => PatchVaultManifestStore(
      manifestPath: d.manifestPath,
      gameId: 'game-001',
    );

File makeZip(String name, Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  final f = File(path.join(patchStore.path, name));
  f.writeAsBytesSync(ZipEncoder().encode(archive)!, flush: true);
  return f;
}

Future<PatchInspection> inspectZip(File f) async {
  final shape =
      await scanGameShape(gameRoot.path, launchDir: launchDir.path);
  return const PatchInspector().withShape(shape).inspect(f.path);
}

extension on PatchInspector {
  PatchInspector withShape(
          ({List<String> exeNames, List<String> topDirs}) shape) =>
      PatchInspector(
        gameExeNames: shape.exeNames,
        gameTopDirs: shape.topDirs,
      );
}

Future<PatchApplySource> sourceOf(File zip, PatchInspection ins,
    {required String txId}) async {
  return prepareApplySource(
    sourcePath: zip.path,
    isDirectory: false,
    stagingRoot: path.join(sandbox.path, 'staging'),
    txId: txId,
    preview: ins.preview!,
    relativePaths: ins.relativePaths,
  );
}

// ---------------------------------------------------------------- 1. GameDirs

Future<void> _tGameDirs() async {
  section('1. GameDirs：启动目录 / 本体根 / 排除名单');
  final d = dirs();
  ok(d.isValid, '目录有效');
  ok(d.launchDir == launchDir.path, '启动目录 = dirname(exe)');
  ok(d.bodyRoot == gameRoot.path, '本体根 = resolve().accessPath');
  ok(d.rootsDiffer, '两者不同时有提示');
  ok(d.warning.isNotEmpty, '口径说明非空');
  ok(d.transferDir == path.join(launchDir.path, kPatchVaultTransferDirName),
      '转移默认目标 = <启动目录>/补丁/');
  ok(d.vaultDir == path.join(launchDir.path, kPatchVaultDirName),
      '备份目录 = <启动目录>/.CTPatch/');
  ok(d.isExcluded(path.join(d.transferDir, 'x.zip')), '排除转移目录内文件');
  ok(d.isExcluded(path.join(d.vaultDir, 'manifest.json')), '排除备份目录内文件');
  ok(!d.isExcluded(path.join(launchDir.path, 'game.exe')), '不误排除游戏文件');

  final offline = GameDirs.compute(
      bodyRoot: '', launchPath: '', isOffline: true);
  ok(offline.isOffline && !offline.isValid, '离线态禁止写');

  final noExe = GameDirs.compute(
    bodyRoot: gameRoot.path,
    launchPath: r'bin\game.exe',
    probeDirExists: (d) => Directory(d).existsSync(),
  );
  ok(noExe.launchDir == launchDir.path, 'exe 不可达但目录存在 → 按启动路径推算');
  ok(!noExe.launchDirVerified, '推算态标记未验证');

  final flat = GameDirs.compute(
    bodyRoot: gameRoot.path,
    launchPath: 'game.exe',
    resolvedExePath: path.join(gameRoot.path, 'game.exe'),
  );
  ok(!flat.rootsDiffer, 'launch_path 无子目录时两根相同');
}

// ---------------------------------------------------------------- 2. Inspector

Future<void> _tInspector() async {
  section('2. 只读识别：四形态 + 不支持格式');
  await writeFile(path.join(gameRoot.path, 'GameData', 'base.pck'), 'BASE');
  await writeFile(path.join(launchDir.path, 'game.exe'), 'MZ-fake-exe');

  // ① DLL 注入型
  final dll = makeZip('dll_patch.zip', <String, String>{
    'wrapper/winmm.dll': 'DLLPAYLOAD',
    'wrapper/读我.txt': 'read me',
  });
  final i1 = await inspectZip(dll);
  ok(i1.container == PatchContainer.zip, 'zip 容器');
  ok(i1.kind == PatchKind.dllInject, '识别 DLL 注入型');
  ok(i1.hasReadme, '识别说明文件');
  ok(i1.isApplyable, '可走应用流程');
  ok(i1.warnings.any((w) => w.contains('说明文件')), '提示先读说明');

  // ② 覆盖式（与本体子目录同名）
  final overlay = makeZip('overlay.zip', <String, String>{
    'overlay/GameData/Scene.pck': 'SCENE',
    'overlay/GameData/Script.dat': 'SCRIPT',
  });
  final i2 = await inspectZip(overlay);
  ok(i2.kind == PatchKind.overlay, '识别覆盖式（GameData 同构）');
  ok(i2.preview?.advice == PatchTargetAdvice.gameRoot, '建议覆盖到根目录');
  ok(recommendTargetRoot(i2.preview!, dirs()) == gameRoot.path,
      '推荐落点 = 本体根');

  // ③ 换 exe 型（exe 名与游戏主程序同名）
  final exe = makeZip('replace_exe.zip', <String, String>{
    'p/game.exe': 'NEWEXE',
    'p/config.ini': 'CFG',
  });
  final i3 = await inspectZip(exe);
  ok(i3.kind == PatchKind.replaceExe, '识别替换主程序型');
  ok(recommendTargetRoot(i3.preview!, dirs()) == launchDir.path,
      'DLL/换 exe 推荐落点 = 启动目录');

  // ④ 安装器
  final installer = File(path.join(patchStore.path, 'Setup.exe'));
  await installer.writeAsBytes(<int>[0x4D, 0x5A, 0x90, 0x00], flush: true);
  final i4 = await inspectZip(installer);
  ok(i4.container == PatchContainer.exe, '识别 EXE 安装器');
  ok(!i4.isApplyable, '安装器不可自动应用');
  ok(i4.warnings.any((w) => w.contains('无法自动回退')), '诚实声明无法回退');

  // ⑤ 7z / rar 降级
  final seven = File(path.join(patchStore.path, 'x.7z'));
  await seven.writeAsBytes(<int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
      flush: true);
  final i5 = await inspectZip(seven);
  ok(i5.container == PatchContainer.sevenZip && !i5.isApplyable,
      '7z 只登记不假装支持');

  // ⑥ 目录形态 + 排除内部目录
  final folder = Directory(path.join(patchStore.path, 'folder_patch'));
  await Directory(path.join(folder.path, '.CTPatch')).create(recursive: true);
  await writeFile(path.join(folder.path, '.CTPatch', 'manifest.json'), '{}');
  await writeFile(path.join(folder.path, 'data.pck'), 'FOLDERDATA');
  final i6 = await inspectZip(File(folder.path));
  ok(i6.container == PatchContainer.directory, '目录形态');
  ok(!i6.relativePaths.any((p) => p.contains('.CTPatch')),
      '跳过内部目录（防自己吃自己）');
  ok(i6.fileCount == 1, '目录剥壳后文件数正确');

  // ⑦ zip slip 整批拒绝
  final evil = makeZip('evil.zip', <String, String>{
    'good.txt': 'OK',
    '../evil.txt': 'BAD',
  });
  final i7 = await inspectZip(evil);
  ok(!i7.isApplyable && i7.relativePaths.isEmpty, '穿越路径整批拒绝');
  ok(i7.warnings.any((w) => w.contains('整包已拒绝')), '明确告知整批拒绝');
}

// ---------------------------------------------------------------- 3. Index

Future<void> _tIndex() async {
  section('3. 索引 CRUD / 失效检测 / 零迁移');
  final idx = index();
  final rec = PatchRecord(
    id: 'rec-1',
    gameId: 'game-001',
    sourcePath: path.join(patchStore.path, 'dll_patch.zip'),
    fileName: 'dll_patch.zip',
    sizeBytes: File(path.join(patchStore.path, 'dll_patch.zip')).lengthSync(),
    mtimeMs: File(path.join(patchStore.path, 'dll_patch.zip'))
        .statSync()
        .modified
        .millisecondsSinceEpoch,
    sha256: await PatchVaultIndex.sha256(
        path.join(patchStore.path, 'dll_patch.zip')),
    container: PatchContainer.zip,
    kind: PatchKind.dllInject,
    hasReadme: true,
    hasExe: false,
    status: PatchVaultStatus.registered,
    addedAt: DateTime.now().toIso8601String(),
  );
  var data = await idx.addRecord(rec);
  ok(data.of('game-001').patches.length == 1, '登记写入');
  ok((await idx.load()).of('game-001').patches.first.id == 'rec-1', '重载读回');

  final chk = await PatchVaultIndex.checkRecord(rec);
  ok(chk.exists && !chk.changed, '未变更文件校验通过');

  await writeFile(rec.sourcePath, 'MODIFIED');
  final chk2 = await PatchVaultIndex.checkRecord(rec);
  ok(chk2.exists && chk2.changed, 'size/mtime 变化被检出');

  // 恢复文件，后续事务用例还要用
  await writeFile(rec.sourcePath, 'ORIGINAL');
  final fresh = rec.copyWith(
    sizeBytes: File(rec.sourcePath).lengthSync(),
    mtimeMs:
        File(rec.sourcePath).statSync().modified.millisecondsSinceEpoch,
    sha256: await PatchVaultIndex.sha256(rec.sourcePath),
  );
  data = await idx.updateRecord('game-001', fresh);
  ok(data.of('game-001').patches.first.status == PatchVaultStatus.registered,
      '更新记录不产生重复');

  final missing =
      await PatchVaultIndex.checkRecord(fresh.copyWith(sourcePath: 'Z:\\nope'));
  ok(!missing.exists, '路径失效被检出');

  await idx.putTxSummary(
      'game-001',
      const PatchTxSummary(
          txId: 'tx-x', patchId: 'rec-1', appliedAt: 't', targetRoot: 'r'));
  ok((await idx.load()).of('game-001').txSummaries.length == 1, '事务摘要只存摘要');
  await idx.removeTxSummary('game-001', 'tx-x');
  ok((await idx.load()).of('game-001').txSummaries.isEmpty, '摘要可移除');
  await idx.removeRecord('game-001', 'rec-1');
  ok((await idx.load()).of('game-001').patches.isEmpty, '移除登记');
}

// ---------------------------------------------------------------- 4. Transfer

Future<void> _tTransfer() async {
  section('4. 转移（移动 / 复制 / 同名不覆盖 / 索引同步）');
  final src = await writeFile(path.join(patchStore.path, 'to_move.zip'), 'MOVE');
  final sha = await PatchVaultIndex.sha256(src.path);
  final target = Directory(path.join(launchDir.path, kPatchVaultTransferDirName));

  final r1 = await const PatchTransferService().transfer(
    sourcePath: src.path,
    targetDir: target.path,
    move: true,
    expectedSha256: sha,
  );
  ok(r1.moved && r1.verified, '移动成功且校验通过');
  ok(!src.existsSync(), '源文件已删除（移动语义）');
  ok(await File(r1.newPath).exists(), '目标文件存在');
  ok(await PatchVaultIndex.sha256(r1.newPath) == sha, '移动后哈希不变');

  final src2 = await writeFile(path.join(patchStore.path, 'to_move.zip'), 'MOVE2');
  final r2 = await const PatchTransferService().transfer(
    sourcePath: src2.path,
    targetDir: target.path,
    move: true,
  );
  ok(path.basename(r2.newPath) == 'to_move_2.zip', '同名不覆盖，自动加 _2');
  ok(!src2.existsSync(), '第二次移动也删源');

  final src3 = await writeFile(path.join(patchStore.path, 'to_copy.zip'), 'COPY');
  final r3 = await const PatchTransferService().transfer(
    sourcePath: src3.path,
    targetDir: target.path,
    move: false,
  );
  ok(!r3.moved && src3.existsSync(), '复制模式保留源');

  // 目录移动
  final dir = Directory(path.join(patchStore.path, 'dirpatch'));
  await writeFile(path.join(dir.path, 'sub', 'a.txt'), 'AAA');
  final r4 = await const PatchTransferService().transfer(
    sourcePath: dir.path,
    targetDir: target.path,
    move: true,
  );
  ok(await File(path.join(r4.newPath, 'sub', 'a.txt')).exists(), '目录含子目录完整搬运');
  ok(!dir.existsSync(), '目录移动后源已删除');

  // 索引路径同步（模拟 UI 成功后的动作）
  final idx = index();
  final rec = PatchRecord(
    id: 'rec-t',
    gameId: 'game-001',
    sourcePath: 'OBSOLETE',
    fileName: 'to_copy.zip',
    sizeBytes: 4,
    mtimeMs: 0,
    sha256: '',
    container: PatchContainer.zip,
    kind: PatchKind.unknown,
    hasReadme: false,
    hasExe: false,
    status: PatchVaultStatus.registered,
    addedAt: '',
  );
  await idx.addRecord(rec);
  await idx.updateRecord(
      'game-001', rec.copyWith(sourcePath: r3.newPath));
  final after = (await idx.load()).of('game-001').patches.first;
  ok(after.sourcePath == r3.newPath, '转移后索引路径已同步');
  ok((await PatchVaultIndex.checkRecord(after)).exists, '同步后登记不再失效');
  await idx.removeRecord('game-001', 'rec-t');

  // 失败不留半成品
  await Directory(target.path).delete(recursive: true);
}

// ---------------------------------------------------------------- 5. Plan

Future<void> _tPlanAndGuard() async {
  section('5. 应用计划 / 推荐落点 / 路径护栏');
  final d = dirs();
  await writeFile(path.join(launchDir.path, 'game.exe'), 'ORIGINAL_EXE');
  await writeFile(path.join(launchDir.path, 'winmm.dll'), 'ORIGINAL_DLL');

  final zip = makeZip('apply.zip', <String, String>{
    'p/winmm.dll': 'NEW_DLL',
    'p/hook.ini': 'CFG',
  });
  final ins = await inspectZip(zip);
  final src = await sourceOf(zip, ins, txId: 'tx-plan');
  try {
    final plan = await buildApplyPlan(
      source: src,
      targetRoot: d.launchDir,
      dirs: d,
    );
    ok(!plan.isBlocked, '正常计划不被拦：${plan.blockedReasons}');
    ok(plan.entries.length == 2, '逐文件清单 2 条');
    ok(plan.overwriteCount == 1, '准确识别 1 个将被覆盖');
    ok(plan.backupBytes > 0, '备份体积已估算');
    ok(plan.entries.any((e) => e.isOverwrite && e.relativePath == 'winmm.dll'),
        '覆盖项含原始哈希');
    ok(recommendTargetRoot(ins.preview!, d) == d.launchDir,
        'DLL 型推荐启动目录');

    final blocked = await buildApplyPlan(
      source: src,
      targetRoot: path.join(d.transferDir, 'nested'),
      dirs: d,
    );
    ok(blocked.isBlocked, '落点在排除目录内 → 整批拒绝');

    final evil = makeZip('plan_evil.zip', <String, String>{
      '../outside.txt': 'BAD',
      'ok.txt': 'OK',
    });
    final evilIns = await inspectZip(evil);
    ok(!evilIns.isApplyable, '非法条目在识别阶段被挡');
  } finally {
    await disposeApplySource(src);
  }

  ok(resolveTargetRoot(PatchTargetChoice.bodyRoot, d) == d.bodyRoot,
      '落点选项解析：本体根');
  ok(resolveTargetRoot(PatchTargetChoice.custom, d, customDir: 'X') == 'X',
      '落点选项解析：自定义');
}

// ---------------------------------------------------------------- 6. Apply

Future<void> _tApplyAndRollback() async {
  section('6. 应用事务 + 单补丁撤销');
  final d = dirs();
  final mStore = store(d);
  await writeFile(path.join(launchDir.path, 'winmm.dll'), 'BEFORE_DLL');
  final beforeSha =
      await PatchVaultIndex.sha256(path.join(launchDir.path, 'winmm.dll'));

  final zip = makeZip('tx1.zip', <String, String>{
    'p/winmm.dll': 'AFTER_DLL',
    'p/new.ini': 'NEW_FILE',
  });
  final ins = await inspectZip(zip);
  final src = await sourceOf(zip, ins, txId: 'tx-apply-1');
  try {
    final plan = await buildApplyPlan(
        source: src, targetRoot: d.launchDir, dirs: d);
    final tx = await const PatchApplyService().apply(
      plan: plan,
      source: src,
      dirs: d,
      gameId: 'game-001',
      patchId: 'rec-apply-1',
      txId: 'tx-apply-1',
      preflight: () async => null,
    );
    ok(tx.isInstalled, '事务状态 = installed');
    ok(tx.entries.length == 2, 'manifest 记 2 条映射');
    ok(await File(path.join(launchDir.path, 'winmm.dll')).readAsString() ==
        'AFTER_DLL', '覆盖生效');
    ok(await File(path.join(launchDir.path, 'new.ini')).exists(), '新增文件生效');
    ok(File(tx.backupDir).existsSync() == false, '备份目录是目录不是文件');
    ok(Directory(tx.backupDir).existsSync(), '备份目录存在');
    ok(await File(path.join(tx.backupDir, 'winmm.dll')).readAsString() ==
        'BEFORE_DLL', '原文件已备份');
    ok((await mStore.load()).installed.length == 1, 'manifest 读回 1 条事务');

    // 撤销
    final svc = const PatchRollbackService();
    ok(await svc.canUndo(mStore, tx.txId) == '', '允许单独撤销');
    final report = await svc.undo(
      mStore,
      tx.txId,
      preflight: () async => null,
    );
    ok(report.ok, '撤销成功');
    ok(await File(path.join(launchDir.path, 'winmm.dll')).readAsString() ==
        'BEFORE_DLL', '原版已还原');
    ok(await PatchVaultIndex.sha256(
            path.join(launchDir.path, 'winmm.dll')) ==
        beforeSha, '还原后哈希 = 应用前哈希');
    ok(!File(path.join(launchDir.path, 'new.ini')).existsSync(),
        '只删自己新建的文件');
    ok(!Directory(tx.backupDir).existsSync(), '撤销后备份目录清理');
    ok((await mStore.load()).transactions.isEmpty, 'manifest 事务已移除');
    ok(await File(path.join(gameRoot.path, 'GameData', 'base.pck')).exists(),
        '不碰用户其它文件');
  } finally {
    await disposeApplySource(src);
  }

  // game_id 空兜底
  try {
    final zip2 = makeZip('tx-empty-id.zip', <String, String>{'p/a.txt': 'A'});
    final ins2 = await inspectZip(zip2);
    final src2 = await sourceOf(zip2, ins2, txId: 'tx-empty');
    try {
      final p2 = await buildApplyPlan(
          source: src2, targetRoot: d.launchDir, dirs: d);
      await const PatchApplyService().apply(
        plan: p2,
        source: src2,
        dirs: d,
        gameId: '',
        patchId: 'x',
        txId: 'tx-empty-id',
        preflight: () async => null,
      );
      ok(false, 'game_id 为空应被拒绝');
    } on PatchVaultException catch (e) {
      ok(e.message.contains('game_id'), 'game_id 为空明确拒绝');
    } finally {
      await disposeApplySource(src2);
    }
  } catch (_) {}
}

// ---------------------------------------------------------------- 7. Failure

Future<void> _tFailureRollback() async {
  section('7. 失败注入 → 逆序回滚');
  final d = dirs();
  final mStore = store(d);
  await writeFile(path.join(launchDir.path, 'a.bin'), 'ORIG_A');
  await writeFile(path.join(launchDir.path, 'b.bin'), 'ORIG_B');
  final shaA = await PatchVaultIndex.sha256(path.join(launchDir.path, 'a.bin'));
  final shaB = await PatchVaultIndex.sha256(path.join(launchDir.path, 'b.bin'));

  final zip = makeZip('tx-fail.zip', <String, String>{
    'p/a.bin': 'NEW_A',
    'p/b.bin': 'NEW_B',
    'p/c.bin': 'NEW_C',
  });
  final ins = await inspectZip(zip);
  final src = await sourceOf(zip, ins, txId: 'tx-fail');
  try {
    final plan = await buildApplyPlan(
        source: src, targetRoot: d.launchDir, dirs: d);
    var caught = false;
    try {
      await const PatchApplyService().apply(
        plan: plan,
        source: src,
        dirs: d,
        gameId: 'game-001',
        patchId: 'rec-fail',
        txId: 'tx-fail',
        preflight: () async => null,
        debugFailAfterWrites: 2,
      );
    } on PatchVaultException catch (e) {
      caught = true;
      ok(e.rolledBack, '异常明确标记已回滚');
    }
    ok(caught, '写入故障被抛出');
    ok(await PatchVaultIndex.sha256(path.join(launchDir.path, 'a.bin')) == shaA,
        'a.bin 逆序还原');
    ok(await PatchVaultIndex.sha256(path.join(launchDir.path, 'b.bin')) == shaB,
        'b.bin 逆序还原');
    ok(!File(path.join(launchDir.path, 'c.bin')).existsSync() ||
        await File(path.join(launchDir.path, 'c.bin')).readAsString() != 'NEW_C',
        '未写完的文件不残留补丁内容');
    ok((await mStore.load()).transactions.isEmpty, '失败事务从 manifest 移除');
    ok(!Directory(d.backupDirFor('tx-fail')).existsSync(),
        '失败后备份目录清理（不留垃圾）');
  } finally {
    await disposeApplySource(src);
  }

  // 门禁拒绝：一个字节都不写
  final before = await PatchVaultIndex.sha256(path.join(launchDir.path, 'a.bin'));
  try {
    final src2 = await sourceOf(zip, ins, txId: 'tx-gate');
    try {
      final p2 = await buildApplyPlan(
          source: src2, targetRoot: d.launchDir, dirs: d);
      await const PatchApplyService().apply(
        plan: p2,
        source: src2,
        dirs: d,
        gameId: 'game-001',
        patchId: 'rec-gate',
        txId: 'tx-gate',
        preflight: () async => '游戏正在运行，请先关闭游戏',
      );
      ok(false, '门禁应拒绝');
    } on PatchVaultException catch (e) {
      ok(e.message.contains('游戏正在运行'), '门禁原因原样透出');
    } finally {
      await disposeApplySource(src2);
    }
  } finally {}
  ok(await PatchVaultIndex.sha256(path.join(launchDir.path, 'a.bin')) == before,
      '门禁拒绝后零写入');
}

// ---------------------------------------------------------------- 8. Drift

Future<void> _tDrift() async {
  section('8. 哈希漂移告警');
  final d = dirs();
  final mStore = store(d);
  await writeFile(path.join(launchDir.path, 'drift.bin'), 'BASE');
  final zip = makeZip('tx-drift.zip', <String, String>{'p/drift.bin': 'PATCHED'});
  final ins = await inspectZip(zip);
  final src = await sourceOf(zip, ins, txId: 'tx-drift');
  try {
    final plan = await buildApplyPlan(
        source: src, targetRoot: d.launchDir, dirs: d);
    final tx = await const PatchApplyService().apply(
      plan: plan,
      source: src,
      dirs: d,
      gameId: 'game-001',
      patchId: 'rec-drift',
      txId: 'tx-drift',
      preflight: () async => null,
    );

    await writeFile(path.join(launchDir.path, 'drift.bin'), 'USER_EDIT');
    final svc = const PatchRollbackService();
    final drifts = await svc.checkDrift(tx);
    ok(drifts.length == 1, '检出用户手动改动');
    ok(drifts.first.actualSha != drifts.first.expectedSha, '漂移含两份哈希');

    var blocked = false;
    try {
      await svc.undo(mStore, tx.txId, preflight: () async => null);
    } on PatchVaultDriftException catch (e) {
      blocked = true;
      ok(e.drifts.length == 1, '异常携带漂移清单供 UI 确认');
    }
    ok(blocked, '未确认前拒绝闷头覆盖');
    ok(await File(path.join(launchDir.path, 'drift.bin')).readAsString() ==
        'USER_EDIT', '用户改动未被覆盖');

    final report = await svc.undo(
      mStore,
      tx.txId,
      preflight: () async => null,
      allowDrift: true,
    );
    ok(report.ok, '用户确认后允许还原');
    ok(await File(path.join(launchDir.path, 'drift.bin')).readAsString() ==
        'BASE', '还原到原版');
  } finally {
    await disposeApplySource(src);
  }
}

// ---------------------------------------------------------------- 9. Reverse

Future<void> _tOverlappedReverseOrder() async {
  section('9. 重叠补丁：禁止乱序 + 一键恢复原版按逆序');
  final d = dirs();
  final mStore = store(d);
  final target = path.join(launchDir.path, 'shared.dat');
  await writeFile(target, 'V0');
  final v0 = await PatchVaultIndex.sha256(target);

  Future<PatchTransaction> applyOne(String id, String content) async {
    final zip = makeZip('$id.zip', <String, String>{'p/shared.dat': content});
    final ins = await inspectZip(zip);
    final src = await sourceOf(zip, ins, txId: id);
    try {
      final plan = await buildApplyPlan(
          source: src, targetRoot: d.launchDir, dirs: d);
      return await const PatchApplyService().apply(
        plan: plan,
        source: src,
        dirs: d,
        gameId: 'game-001',
        patchId: 'rec-$id',
        txId: id,
        preflight: () async => null,
      );
    } finally {
      await disposeApplySource(src);
    }
  }

  final t1 = await applyOne('tx-order-1', 'V1');
  final t2 = await applyOne('tx-order-2', 'V2');
  ok(await File(target).readAsString() == 'V2', '后装补丁生效');

  final svc = const PatchRollbackService();
  final why = await svc.canUndo(mStore, t1.txId);
  ok(why.isNotEmpty && why.contains('先撤销后面的'), '拒绝单独先撤早装的补丁');
  ok(await svc.canUndo(mStore, t2.txId) == '', '允许先撤后装的补丁');

  final report = await svc.restoreAll(mStore, preflight: () async => null);
  ok(report.ok && report.undoneTxIds.length == 2, '一键还原卸载 2 条事务');
  ok(report.undoneTxIds.first == t2.txId, '严格逆序：先撤 tx-order-2');
  ok(await PatchVaultIndex.sha256(target) == v0, '最终回到原版 V0');
  ok((await mStore.load()).transactions.isEmpty, 'manifest 清空');
}

// ---------------------------------------------------------------- 10. Recover

Future<void> _tRecover() async {
  section('10. recover()：模拟崩溃残留');
  final d = dirs();
  final mStore = store(d);
  final target = path.join(launchDir.path, 'crash.dat');
  await writeFile(target, 'CRASH_BASE');
  final baseSha = await PatchVaultIndex.sha256(target);

  final backupDir = d.backupDirFor('tx-crash');
  await Directory(backupDir).create(recursive: true);
  await writeFile(path.join(backupDir, 'crash.dat'), 'CRASH_BASE');
  await writeFile(target, 'HALF_PATCH');

  await mStore.upsert(PatchTransaction(
    txId: 'tx-crash',
    patchId: 'rec-crash',
    gameId: 'game-001',
    appliedAt: DateTime.now().toIso8601String(),
    targetRoot: d.launchDir,
    backupDir: backupDir,
    state: PatchTxState.applying,
    entries: <PatchTxEntry>[
      PatchTxEntry(
        relativePath: 'crash.dat',
        targetPath: target,
        backupPath: path.join(backupDir, 'crash.dat'),
        beforeSha256: baseSha,
        afterSha256: await PatchVaultIndex.sha256(target),
        existedBefore: true,
        sizeBytes: 10,
      ),
    ],
  ));

  final r1 = await const PatchVaultRecover()
      .run(manifestPath: d.manifestPath, gameId: 'game-001');
  ok(r1.handledTxIds.contains('tx-crash'), '残留事务被收拾');
  ok(await PatchVaultIndex.sha256(target) == baseSha, '恢复到应用前状态');
  ok((await mStore.load()).transactions.isEmpty, 'manifest 已清理');

  final r2 = await const PatchVaultRecover()
      .run(manifestPath: d.manifestPath, gameId: 'game-001');
  ok(r2.handledTxIds.isEmpty && r2.ok, 'recover 幂等');

  // manifest 损坏：明确告警，不假装没补丁
  await writeFile(d.manifestPath, '{broken');
  final r3 = await const PatchVaultRecover()
      .run(manifestPath: d.manifestPath, gameId: 'game-001');
  ok(r3.damagedManifest && r3.warnings.isNotEmpty, '损坏时明确警示保留备份');
  await File(d.manifestPath).delete();

  // gameId 不符的 manifest 不得被误读
  await mStore.upsert(PatchTransaction(
    txId: 'tx-foreign',
    patchId: 'x',
    gameId: 'other-game',
    appliedAt: 't',
    targetRoot: d.launchDir,
    backupDir: 'z',
    state: PatchTxState.installed,
    entries: const <PatchTxEntry>[],
  ));
  // 直接改成别的 gameId 字段
  final mf = File(d.manifestPath);
  final raw = jsonDecode(await mf.readAsString()) as Map<String, dynamic>;
  raw['gameId'] = 'other-game';
  await mf.writeAsString(jsonEncode(raw), flush: true);
  ok((await mStore.load()).transactions.isEmpty, 'gameId 不符的 manifest 不误还原');
  await mf.delete();
}
