/// PATCH-VAULT 应用计划（纯 Dart，有 IO；⛔ 不写游戏目录）。
///
/// 「预览 → 确认 → 应用」三段里的第一段：把补丁源摊平成
/// 「哪个源文件 → 写到哪个绝对路径 → 会覆盖什么」的清单，供 UI 逐条展示。
///
/// 🔴 本文件只读 + 只写**临时隔离区**（zip 解压），绝不碰游戏本体。
/// 🔴 落点推荐只是**默认值**，最终由用户在预览页确认（方案 §3.3）。

import 'dart:io';

import 'package:path/path.dart' as path;

import '../patch/patch_extract_service.dart';
import '../patch/patch_path_guard.dart';
import '../patch/patch_preview.dart';
import 'game_dirs.dart';
import 'patch_vault_index.dart';

/// 落点选项（UI 下拉）。
enum PatchTargetChoice {
  launchDir('launch', '启动程序所在目录'),
  bodyRoot('body', '游戏本体根'),
  custom('custom', '自定义目录');

  const PatchTargetChoice(this.key, this.label);

  final String key;
  final String label;
}

/// 摊平后的补丁源。
class PatchApplySource {
  const PatchApplySource({
    required this.rootDir,
    required this.relativePaths,
    required this.preview,
    required this.stagingDir,
  });

  /// 内容所在目录（zip 已解压到临时隔离区；目录形态就是原目录）。
  final String rootDir;

  /// 归一 / 剥壳后的相对路径（`/` 分隔）。
  final List<String> relativePaths;
  final PatchPreview preview;

  /// 需要调用方在结束（成功或失败）后清理的临时目录；空串 = 无。
  final String stagingDir;

  String absoluteOf(String rel) =>
      path.joinAll(<String>[rootDir, ...rel.split('/')]);
}

/// 计划里的一条文件映射。
class PatchPlanEntry {
  const PatchPlanEntry({
    required this.relativePath,
    required this.sourcePath,
    required this.targetPath,
    required this.existed,
    required this.beforeSha256,
    required this.sourceSha256,
    required this.sizeBytes,
  });

  final String relativePath;
  final String sourcePath;

  /// 实际写入的绝对路径。
  final String targetPath;
  final bool existed;

  /// 原本存在时的当前哈希；空串 = 新增文件。
  final String beforeSha256;
  final String sourceSha256;
  final int sizeBytes;

  bool get isOverwrite => existed;
}

class PatchPlan {
  const PatchPlan({
    required this.targetRoot,
    required this.entries,
    required this.totalBytes,
    required this.backupBytes,
    required this.overwriteCount,
    required this.warnings,
    required this.blockedReasons,
  });

  final String targetRoot;
  final List<PatchPlanEntry> entries;
  final int totalBytes;

  /// 备份被覆盖原文件所需的大致体积（确认页如实显示）。
  final int backupBytes;
  final int overwriteCount;
  final List<String> warnings;
  final List<String> blockedReasons;

  bool get isBlocked => blockedReasons.isNotEmpty;
  bool get isEmpty => entries.isEmpty;
}

/// 按形态给**默认推荐落点**（null = 不推荐，交给用户）。
///
/// | 形态 | 推荐 | 理由 |
/// |---|---|---|
/// | DLL 注入 / 换 exe | 启动目录 | 必须与启动程序同目录才生效 |
/// | 覆盖式（与本体子目录同构） | 本体根 | `GameData/` 等须与本体结构同构 |
/// | 安装器 / 未知 / 隔离型 | null | 不猜，让用户自己选 |
String? recommendTargetRoot(PatchPreview preview, GameDirs dirs) {
  if (!dirs.isValid) return null;
  switch (preview.advice) {
    case PatchTargetAdvice.installerOnly:
    case PatchTargetAdvice.blocked:
    case PatchTargetAdvice.patchSubdir:
      return null;
    case PatchTargetAdvice.gameRoot:
      if (preview.libraries.isNotEmpty) return dirs.launchDir;
      if (preview.reason.contains('覆盖式') ||
          preview.reason.contains('同构') ||
          preview.reason.contains('按原目录结构')) {
        return dirs.bodyRoot;
      }
      // 换 exe 型：exe 在启动目录
      return dirs.launchDir;
  }
}

/// 把落点选项解析为绝对路径。
String resolveTargetRoot(
  PatchTargetChoice choice,
  GameDirs dirs, {
  String customDir = '',
}) {
  switch (choice) {
    case PatchTargetChoice.launchDir:
      return dirs.launchDir;
    case PatchTargetChoice.bodyRoot:
      return dirs.bodyRoot;
    case PatchTargetChoice.custom:
      return customDir.trim();
  }
}

/// 准备补丁源：目录直接用；zip 解到 `<stagingRoot>/<txId>/`（隔离区）。
///
/// 🔴 7z / rar / exe 在识别阶段就被挡下，这里遇到一律抛异常。
/// 🔴 返回后调用方**必须**在 finally 里清理 [PatchApplySource.stagingDir]。
Future<PatchApplySource> prepareApplySource({
  required String sourcePath,
  required bool isDirectory,
  required String stagingRoot,
  required String txId,
  List<String> gameExeNames = const <String>[],
  List<String> gameTopDirs = const <String>[],
  required PatchPreview preview,
  required List<String> relativePaths,
}) async {
  if (isDirectory) {
    return PatchApplySource(
      rootDir: sourcePath,
      relativePaths: relativePaths,
      preview: preview,
      stagingDir: '',
    );
  }

  final magic = PatchExtractService.sniffContainer(sourcePath);
  if (magic == '7z' || magic == 'rar' || magic == 'exe') {
    throw StateError('该补丁格式需先自行解压，或以文件夹形式导入');
  }
  if (magic != 'zip' && magic != 'zip-empty') {
    throw StateError('无法识别的补丁包格式');
  }

  final stage = Directory(path.join(stagingRoot, _safe(txId)));
  if (stage.existsSync()) await stage.delete(recursive: true);
  await stage.create(recursive: true);
  try {
    final result = await const PatchExtractService().extractTo(
      archivePath: sourcePath,
      destDir: stage.path,
      outDirName: null, // → <stage>/extracted/
    );
    return PatchApplySource(
      rootDir: result.rootPath,
      relativePaths: result.entries.map((e) => e.path).toList(),
      preview: result.toPreview(
        gameExeNames: gameExeNames,
        gameTopDirs: gameTopDirs,
      ),
      stagingDir: stage.path,
    );
  } catch (_) {
    if (stage.existsSync()) {
      try {
        await stage.delete(recursive: true);
      } catch (_) {}
    }
    rethrow;
  }
}

/// 生成应用计划（只读目标目录）。
///
/// [dirs] 用于排除名单；传 null 时跳过排除检查（仅探针使用）。
Future<PatchPlan> buildApplyPlan({
  required PatchApplySource source,
  required String targetRoot,
  GameDirs? dirs,
}) async {
  final blocked = <String>[];
  final warnings = <String>[];

  if (targetRoot.trim().isEmpty) {
    blocked.add('尚未选择落点目录');
  } else if (!Directory(targetRoot).existsSync()) {
    blocked.add('落点目录不存在：$targetRoot');
  }
  if (dirs?.isOffline == true) {
    blocked.add('游戏目录当前不可访问，禁止写入');
  }
  if (source.relativePaths.isEmpty) {
    blocked.add('补丁源里没有可应用的文件');
  }

  final bad = validateEntryPaths(source.relativePaths);
  if (bad.isNotEmpty) {
    blocked.add('补丁含 ${bad.length} 个非法路径，整批拒绝：${bad.first}');
  }

  final entries = <PatchPlanEntry>[];
  var total = 0;
  var backupBytes = 0;
  var overwriteCount = 0;
  final normRoot = _norm(targetRoot);

  if (blocked.isEmpty) {
    for (final rel in source.relativePaths) {
      final n = normalizeEntryPath(rel);
      if (n == null) {
        blocked.add('非法条目：$rel');
        continue;
      }
      final src = source.absoluteOf(rel);
      final srcFile = File(src);
      if (!srcFile.existsSync()) {
        blocked.add('源文件缺失：$rel');
        continue;
      }
      final target = path.joinAll(<String>[targetRoot, ...n.split('/')]);
      // 双保险：拼完还要确认仍在落点根内（防 path.join 被绝对段绕开）。
      if (!_isInside(normRoot, _norm(target))) {
        blocked.add('目标路径越出落点目录：$rel');
        continue;
      }
      if (dirs != null && dirs.isExcluded(target)) {
        blocked.add('目标落在补丁／备份内部目录，已拒绝：$rel');
        continue;
      }
      final targetFile = File(target);
      final existed = targetFile.existsSync();
      final size = await srcFile.length();
      String beforeSha = '';
      if (existed) {
        try {
          beforeSha = await PatchVaultIndex.sha256(target);
        } catch (_) {
          blocked.add('无法读取待覆盖文件：$rel');
          continue;
        }
        backupBytes += await targetFile.length();
        overwriteCount++;
      }
      entries.add(PatchPlanEntry(
        relativePath: n,
        sourcePath: src,
        targetPath: target,
        existed: existed,
        beforeSha256: beforeSha,
        sourceSha256: await PatchVaultIndex.sha256(src),
        sizeBytes: size,
      ));
      total += size;
    }
  }

  if (overwriteCount > 0) {
    warnings.add('将覆盖 $overwriteCount 个已有文件，应用前会自动备份原文件');
  }
  if (source.preview.readmes.isNotEmpty) {
    warnings.add('包内有说明文件（${source.preview.readmes.first.name}），'
        '打补丁前请先到游戏目录查看说明');
  }
  if (source.preview.libraries.isNotEmpty) {
    warnings.add('此补丁依赖 DLL 劫持，放到子目录不会生效，'
        '请确认落点是启动程序所在目录');
  }
  if (source.preview.installers.isNotEmpty) {
    warnings.add('包内含可执行程序，替换后可能影响游戏启动');
  }

  return PatchPlan(
    targetRoot: targetRoot,
    entries: entries,
    totalBytes: total,
    backupBytes: backupBytes,
    overwriteCount: overwriteCount,
    warnings: warnings,
    blockedReasons: blocked,
  );
}

/// 清理 [prepareApplySource] 产生的临时隔离区。
Future<void> disposeApplySource(PatchApplySource source) async {
  if (source.stagingDir.isEmpty) return;
  final d = Directory(source.stagingDir);
  if (d.existsSync()) {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }
}

// ---------------- helpers ----------------

String _safe(String s) =>
    s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');

String _norm(String p) => p.trim().isEmpty
    ? ''
    : path.normalize(p).replaceAll('/', '\\').toLowerCase();

bool _isInside(String root, String child) {
  if (root.isEmpty || child.isEmpty) return false;
  return path.isWithin(root, child) || child.startsWith('$root\\');
}

