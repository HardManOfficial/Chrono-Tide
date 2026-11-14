/// Phase 4.5（钥匙统一）端到端探针 —— 归档库布局迁移 + 同名游戏隔离。
///
/// 背景：提交 `20e1671` 把库页卡片 GlobalKey 的钥匙从 directoryPath 换成
/// `game_id`，并明确「同名不同路径」重复导入是合法场景。归档库 v1 布局按
/// 「标题清洗名」组织游戏根，两个同名游戏会共用一个根（串库）。本次统一到
/// `game_id` 根 + 旧布局按需迁移。
///
/// 被测对象：`lib/services/archive_layout_migrate.dart`（纯 Dart，真实文件系统）。
///
/// 运行：`dart.exe --packages="D:/CTLIB/.dart_tool/package_config.json"
///        dev_probe/phase4_key_unify_probe.dart`
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lib/services/archive_layout_migrate.dart';

int _pass = 0;
int _fail = 0;

void check(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  ✅ $label');
  } else {
    _fail++;
    print('  ❌ $label');
  }
}

/// 写一份最小但合法的归档（meta.json 可被 tryParse 解析出 gameId）。
void seedArchive(String dir, String gameId, String title) {
  Directory(dir).createSync(recursive: true);
  File(p.join(dir, 'meta.json')).writeAsStringSync(const JsonEncoder.withIndent('  ')
      .convert({
    'schema': 1,
    'game_id': gameId,
    'title': title,
    'state': 'sealed',
    'created_at': '2026-10-03T10:00:00.000',
  }));
  File(p.join(dir, 'appdata.7z')).writeAsBytesSync(List.generate(64, (i) => i));
}

Future<void> main() async {
  final tmp = Directory(
      '${Directory.systemTemp.path}/phase4_key_unify_${DateTime.now().millisecondsSinceEpoch}');
  tmp.createSync(recursive: true);
  final libRoot = p.join(tmp.path, 'archives');

  print('=== 探针根目录: ${tmp.path} ===\n');

  // ---------- ① 新布局解析 ----------
  print('【① 新布局：game_id 根】');
  final r1 = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: 'aaaaaaaa-1111-4222-8333-444444444444',
    title: 'ATRI',
  );
  check(
      r1.root == p.join(libRoot, 'aaaaaaaa-1111-4222-8333-444444444444'),
      'root = <libRoot>/<game_id>');
  check(r1.moved == 0 && r1.kept == 0, '无旧数据 → 不迁移');
  check(!Directory(p.join(libRoot, 'ATRI')).existsSync(), '不创建任何目录');

  // ---------- ② 空 gameId 兜底 ----------
  print('\n【② 空 game_id 兜底：标题清洗名根（历史脏数据）】');
  final r2 = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: '',
    title: 'ATRI: My Dear Moments!',
  );
  check(r2.root == p.join(libRoot, 'ATRI_ My Dear Moments!'),
      '非法字符清洗后作根名（与 GameKey.dirNameFromTitle 同规则）');
  check(r2.moved == 0, '兜底路径不迁移');

  // ---------- ③ 旧布局迁移 + 同名隔离（混杂旧根：A 两份 + B 一份） ----------
  // 真实时序：v1 时代两个同名游戏都往 <ATRI>/ 写；用户先开 A 的弹窗 →
  // A 认领全部自己的份；再开 B → B 认领剩下的 → 旧根空了删除。
  print('\n【③ 旧布局迁移 + 同名隔离】');
  final idA = 'aaaaaaaa-1111-4222-8333-444444444444';
  final idB = 'bbbbbbbb-1111-4222-8333-444444444444';
  final legacy = p.join(libRoot, 'ATRI');
  seedArchive(p.join(legacy, '2026-10-02_10-00-00_sealed'), idA, 'ATRI');
  seedArchive(p.join(legacy, '2026-10-02_11-00-00_packed'), idA, 'ATRI');
  seedArchive(p.join(legacy, '2026-10-03_09-00-00_packed'), idB, 'ATRI');
  File(p.join(legacy, 'latest.json')).writeAsStringSync(
      jsonEncode({'latest': '2026-10-02_10-00-00_sealed'}));

  final rA = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: idA,
    title: 'ATRI',
  );
  check(rA.moved == 2 && rA.kept == 1, 'A 认领自己的 2 份，B 的留在旧根');
  check(rA.root == p.join(libRoot, idA), 'A 返回新根');
  check(
      Directory(p.join(rA.root, '2026-10-02_10-00-00_sealed')).existsSync() &&
          Directory(p.join(rA.root, '2026-10-02_11-00-00_packed'))
              .existsSync(),
      'A 的两份都落新根');
  check(
      !Directory(p.join(rA.root, '2026-10-03_09-00-00_packed')).existsSync(),
      'A 根里没有 B 的归档');
  check(File(p.join(rA.root, 'latest.json')).existsSync(), 'latest.json 随迁');
  check(
      Directory(p.join(legacy, '2026-10-03_09-00-00_packed')).existsSync(),
      'B 的归档留在旧根待认领（旧根未删）');

  final rB = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: idB,
    title: 'ATRI',
  );
  check(rB.moved == 1, 'B 认领剩下的 1 份');
  check(
      Directory(p.join(rB.root, '2026-10-03_09-00-00_packed')).existsSync() &&
          !Directory(p.join(rB.root, '2026-10-02_10-00-00_sealed'))
              .existsSync(),
      'B 根里只有 B 的归档');
  check(!Directory(legacy).existsSync(), '两份都认领后旧根删除');

  // ---------- ④ 幂等：再调一次 ----------
  print('\n【④ 幂等：新根已存在 → 不重复迁移】');
  final r4 = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: idA,
    title: 'ATRI',
  );
  check(r4.moved == 0 && r4.kept == 0, '第二次调用零迁移');
  check(
      Directory(p.join(r4.root, '2026-10-02_10-00-00_sealed')).existsSync() &&
          Directory(p.join(r4.root, '2026-10-02_11-00-00_packed'))
              .existsSync(),
      '数据完好');

  // ---------- ⑥ 半成品随迁 ----------
  print('\n【⑥ .partial 半成品随迁（无 meta.json）】');
  final legacyC = p.join(libRoot, 'ATRI'); // 又一个同名游戏的旧根
  Directory(p.join(legacyC, '2026-10-03_09-59-00_sealed.partial'))
      .createSync(recursive: true);
  final idC = 'cccccccc-1111-4222-8333-444444444444';
  final rC = await ArchiveLayoutMigrator.resolveGameRoot(
    libraryRoot: libRoot,
    gameId: idC,
    title: 'ATRI',
  );
  check(
      Directory(p.join(rC.root, '2026-10-03_09-59-00_sealed.partial'))
          .existsSync(),
      '半成品迁入新根（待 seal/pack 续写或清理）');
  check(!Directory(legacyC).existsSync(), '旧根删除');

  // ---------- 清理 ----------
  tmp.deleteSync(recursive: true);

  print('\n========== 结果: $_pass PASS / $_fail FAIL ==========');
  exit(_fail == 0 ? 0 : 1);
}
