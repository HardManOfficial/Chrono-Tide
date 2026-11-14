/// PATCH-VAULT 补丁文件转移（纯 Dart，有 IO）。
///
/// 用户口述：「觉得补丁杂乱无章想换个统一存放路径，但又不想回资源管理器自己拖」。
/// 所以这里做的是**单文件 / 单文件夹**的轻量搬运：
///
/// - 默认目标由 UI 预填 `<启动程序目录>/补丁/`（常量见 `game_dirs.dart`）；
/// - 语义默认**移动**（用户 2026-11-11 拍板），可选「改为复制」；
/// - 同盘优先 `rename`（原子）；跨盘退化为流式 copy + 校验 + 删源；
/// - 目标同名 ⛔ 不覆盖，自动加 `_2` / `_3`；
/// - 失败不留半成品；成功后调用方**必须**同步更新索引里的 `sourcePath`。
///
/// ⛔ 不复用 `GameMoveService`：它是目录级重事务，会改 `game.json` /
/// 快捷方式 / Magpie / 存档清单，与「搬几个补丁文件」语义不匹配。

import 'dart:io';

import 'package:path/path.dart' as path;

import 'patch_vault_index.dart';

class PatchTransferException implements Exception {
  const PatchTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PatchTransferResult {
  const PatchTransferResult({
    required this.newPath,
    required this.moved,
    required this.verified,
    required this.message,
  });

  final String newPath;
  final bool moved;
  final bool verified;
  final String message;
}

class PatchTransferService {
  const PatchTransferService();

  /// [move] = true 时成功后删除源；false 时保留源（复制）。
  /// [expectedSha256] 仅单文件形态传登记时的哈希，用于转移前后一致性校验。
  Future<PatchTransferResult> transfer({
    required String sourcePath,
    required String targetDir,
    required bool move,
    String expectedSha256 = '',
  }) async {
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw const PatchTransferException('源文件已不存在，请重新定位或移除登记');
    }
    if (type == FileSystemEntityType.link) {
      throw const PatchTransferException('快捷方式 / 符号链接不支持转移');
    }
    final isDir = type == FileSystemEntityType.directory;
    if (targetDir.trim().isEmpty) {
      throw const PatchTransferException('请先选择目标目录');
    }

    final destRoot = Directory(targetDir);
    final destRootExisted = destRoot.existsSync();
    try {
      if (!destRootExisted) await destRoot.create(recursive: true);
    } catch (e) {
      throw PatchTransferException('无法创建目标目录：$e');
    }

    final name = path.basename(sourcePath);
    final dest = _uniquePath(path.join(targetDir, name));
    final created = <String>[];

    try {
      // ---------- ① 同盘优先 rename（原子，零拷贝） ----------
      var renamed = false;
      if (move) {
        try {
          if (isDir) {
            await Directory(sourcePath).rename(dest);
          } else {
            await File(sourcePath).rename(dest);
          }
          renamed = true;
        } on FileSystemException catch (_) {
          // 跨卷 / 目标被占用 → 退化到 copy + verify + delete
          renamed = false;
        }
      }

      if (!renamed) {
        if (isDir) {
          await _copyDirectory(Directory(sourcePath), Directory(dest), created);
        } else {
          await _copyFile(File(sourcePath), File(dest));
          created.add(dest);
        }

        // ---------- ② 校验通过才允许删源 ----------
        final verified = isDir
            ? await _verifyDirectory(Directory(sourcePath), Directory(dest))
            : await _verifyFile(File(sourcePath), File(dest), expectedSha256);
        if (!verified) {
          throw const PatchTransferException(
              '转移后校验未通过（文件大小或哈希不一致），已保留源文件');
        }

        if (move) {
          if (isDir) {
            await Directory(sourcePath).delete(recursive: true);
          } else {
            await File(sourcePath).delete();
          }
        }
      }

      final finalSha = isDir || !move
          ? ''
          : await PatchVaultIndex.sha256(dest);
      if (!isDir && move && expectedSha256.isNotEmpty) {
        // rename 分支没走过逐字节校验，这里补一次：登记哈希不变才可继续用。
        if (finalSha != expectedSha256) {
          throw const PatchTransferException('转移后哈希与登记值不一致，请重新校验补丁');
        }
      }

      return PatchTransferResult(
        newPath: dest,
        moved: move,
        verified: true,
        message: move ? '已移动到 $dest' : '已复制到 $dest',
      );
    } catch (e) {
      // ---------- 失败清理：只删本次新建的目标，绝不碰用户已有文件 ----------
      await _cleanup(dest, created, isDir);
      if (!destRootExisted && destRoot.existsSync()) {
        try {
          // 仅当空目录才删，避免误删他人文件
          if (await destRoot.list().isEmpty) await destRoot.delete();
        } catch (_) {}
      }
      if (e is PatchTransferException) rethrow;
      throw PatchTransferException('转移失败：$e');
    }
  }

  /// 目标同名不覆盖：`foo.zip` → `foo_2.zip` → `foo_3.zip`。
  static String _uniquePath(String wanted) {
    if (!File(wanted).existsSync() && !Directory(wanted).existsSync()) {
      return wanted;
    }
    final dir = path.dirname(wanted);
    final ext = path.extension(wanted);
    final stem = path.basenameWithoutExtension(wanted);
    for (var i = 2; i < 1000; i++) {
      final candidate = path.join(dir, '${stem}_$i$ext');
      if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
        return candidate;
      }
    }
    return path.join(dir, '${stem}_${DateTime.now().microsecondsSinceEpoch}$ext');
  }

  static Future<void> _copyFile(File src, File dst) async {
    await Directory(path.dirname(dst.path)).create(recursive: true);
    final sink = dst.openWrite();
    try {
      await sink.addStream(src.openRead());
    } finally {
      await sink.close();
    }
  }

  static Future<void> _copyDirectory(
    Directory src,
    Directory dst,
    List<String> created,
  ) async {
    await dst.create(recursive: true);
    created.add(dst.path);
    await for (final e in src.list(recursive: false, followLinks: false)) {
      final name = path.basename(e.path);
      if (e is Directory) {
        await _copyDirectory(e, Directory(path.join(dst.path, name)), created);
      } else if (e is File) {
        final target = File(path.join(dst.path, name));
        await _copyFile(e, target);
        created.add(target.path);
      }
      // Link 只跳过（⛔ 不跟随、不复制链接本身，避免越界）
    }
  }

  static Future<bool> _verifyFile(
      File src, File dst, String expectedSha) async {
    if (!dst.existsSync()) return false;
    if (await src.length() != await dst.length()) return false;
    final a = await PatchVaultIndex.sha256(src.path);
    final b = await PatchVaultIndex.sha256(dst.path);
    if (a != b) return false;
    return expectedSha.isEmpty || b == expectedSha;
  }

  static Future<bool> _verifyDirectory(Directory src, Directory dst) async {
    if (!dst.existsSync()) return false;
    final srcRels = <String>[];
    await for (final e in src.list(recursive: true, followLinks: false)) {
      if (e is File) {
        srcRels.add(path.relative(e.path, from: src.path));
      }
    }
    for (final rel in srcRels) {
      final a = File(path.join(src.path, rel));
      final b = File(path.join(dst.path, rel));
      if (!b.existsSync()) return false;
      if (await a.length() != await b.length()) return false;
      if (await PatchVaultIndex.sha256(a.path) !=
          await PatchVaultIndex.sha256(b.path)) {
        return false;
      }
    }
    return true;
  }

  static Future<void> _cleanup(
      String dest, List<String> created, bool isDir) async {
    if (isDir && Directory(dest).existsSync()) {
      try {
        await Directory(dest).delete(recursive: true);
      } catch (_) {}
      return;
    }
    // 单文件：只删本次确实新建的那个目标
    for (final p in created) {
      try {
        final f = File(p);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }
}
