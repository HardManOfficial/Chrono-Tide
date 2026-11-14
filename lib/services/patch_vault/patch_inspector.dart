/// PATCH-VAULT 只读类型识别（纯 Dart，零 Flutter）。
///
/// ## 它做什么 / 不做什么
///
/// ✅ 做：只读地看一眼用户导入的补丁，给出**形态标签**与**说明文件清单**，
///      让杂乱的本地文件在面板里可视化、可检索。
/// ⛔ 不做：不解压、不复制、不移动、不写游戏目录、不猜「这补丁属于哪个游戏」
///      （入口是某游戏的右键菜单，归属由用户选的游戏决定）、不自动应用。
///
/// 🔴 识别结果只是**标签与建议**，用户可改可忽略。猜错落点会破坏游戏本体，
/// 所以最终落点在预览页由用户确认。
///
/// zip / 目录两路都复用补丁站的纯函数（`listEntries` / `previewFromRawPaths`），
/// ⛔ 不改补丁站任何语义；7z / rar / exe / 单文件只给格式标签，不假装支持。

import 'dart:io';

import 'package:path/path.dart' as path;

import '../../models/patch_vault_record.dart';
import '../patch/patch_extract_service.dart';
import '../patch/patch_path_guard.dart';
import '../patch/patch_preview.dart';
import 'game_dirs.dart';

class PatchInspection {
  const PatchInspection({
    required this.container,
    required this.kind,
    required this.fileCount,
    required this.totalBytes,
    required this.readmeNames,
    required this.exeNames,
    required this.dllNames,
    required this.relativePaths,
    required this.warnings,
    required this.reason,
    required this.isApplyable,
    this.preview,
  });

  final PatchContainer container;
  final PatchKind kind;
  final int fileCount;
  final int totalBytes;

  /// 包内说明文件名（剥壳后的相对路径），面板可列出并提示先读。
  final List<String> readmeNames;
  final List<String> exeNames;
  final List<String> dllNames;

  /// 归一 / 剥壳后的相对路径；zip 供 subsequent 解压校验，目录供应用计划。
  final List<String> relativePaths;

  final List<String> warnings;
  final String reason;

  /// 是否可以走「辅助打补丁」流程（zip / 目录且路径全部合法）。
  final bool isApplyable;

  /// 仅 zip / 目录有值。
  final PatchPreview? preview;

  bool get hasReadme => readmeNames.isNotEmpty;
  bool get hasExe => exeNames.isNotEmpty;

  /// 落点推荐（只是默认值，UI 必须允许改）。
  PatchTargetAdvice get advice =>
      preview?.advice ?? PatchTargetAdvice.blocked;
}

class PatchInspector {
  const PatchInspector({
    this.gameExeNames = const <String>[],
    this.gameTopDirs = const <String>[],
  });

  /// 游戏目录里真实存在的 exe 名（小写），用于识别「换 exe 型」。
  final List<String> gameExeNames;

  /// 游戏目录顶层子目录名（小写），用于识别「覆盖式」。
  final List<String> gameTopDirs;

  Future<PatchInspection> inspect(String sourcePath) async {
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      return _inspectDirectory(sourcePath);
    }
    if (type == FileSystemEntityType.link) {
      return _unsupported(
        PatchContainer.unknown,
        '快捷方式 / 符号链接不参与补丁识别，请指向实际文件或文件夹',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return _unsupported(PatchContainer.unknown, '路径不存在');
    }
    return _inspectFile(sourcePath);
  }

  // ---------------- zip / 目录 ----------------

  Future<PatchInspection> _inspectFile(String sourcePath) async {
    final magic = PatchExtractService.sniffContainer(sourcePath);
    switch (magic) {
      case 'zip':
      case 'zip-empty':
        return _inspectZip(sourcePath);
      case '7z':
        return _unsupported(
          PatchContainer.sevenZip,
          '7z 补丁请先用 7-Zip 自行解压，再以「文件夹」形式导入',
        );
      case 'rar':
        return _unsupported(
          PatchContainer.rar,
          'RAR 补丁请先用 7-Zip 自行解压，再以「文件夹」形式导入',
        );
      case 'exe':
        return _installer(sourcePath);
      default:
        final ext = path.extension(sourcePath).toLowerCase();
        final container = switch (ext) {
          '.7z' => PatchContainer.sevenZip,
          '.rar' => PatchContainer.rar,
          '.exe' || '.msi' => PatchContainer.exe,
          _ => PatchContainer.singleFile,
        };
        if (container == PatchContainer.exe) return _installer(sourcePath);
        if (container == PatchContainer.sevenZip ||
            container == PatchContainer.rar) {
          return _unsupported(
            container,
            '该格式请先自行解压，再以「文件夹」形式导入',
          );
        }
        return _unsupported(
          PatchContainer.singleFile,
          '单个文件：形态未知，请自行阅读补丁说明后决定放在哪',
        );
    }
  }

  Future<PatchInspection> _inspectZip(String sourcePath) async {
    List<PatchEntry> entries;
    try {
      entries = await const PatchExtractService().listEntries(sourcePath);
    } catch (e) {
      return _unsupported(
        PatchContainer.zip,
        '无法读取 ZIP 内容（可能编码不兼容或文件损坏）：$e',
      );
    }
    final raw = entries.map((e) => e.path).toList();
    final bad = validateEntryPaths(raw);
    if (bad.isNotEmpty) {
      return PatchInspection(
        container: PatchContainer.zip,
        kind: PatchKind.unknown,
        fileCount: raw.length,
        totalBytes: entries.fold<int>(0, (s, e) => s + e.size),
        readmeNames: const <String>[],
        exeNames: const <String>[],
        dllNames: const <String>[],
        relativePaths: const <String>[],
        warnings: <String>[
          '包内含 ${bad.length} 个非法路径（穿越 / 绝对路径 / 盘符），首个：${bad.first}',
          '整包已拒绝：半装进去比不装更糟',
        ],
        reason: '补丁包内有非法路径，已拒绝应用',
        isApplyable: false,
      );
    }
    final sizes = <String, int>{
      for (final e in entries) e.path: e.size,
    };
    final preview = previewFromRawPaths(
      raw,
      sizes: sizes,
      gameExeNames: gameExeNames,
      gameTopDirs: gameTopDirs,
    );
    return _fromPreview(
      PatchContainer.zip,
      preview,
      extraWarnings: const <String>[],
    );
  }

  Future<PatchInspection> _inspectDirectory(String sourcePath) async {
    final rel = <String>[];
    final sizes = <String, int>{};
    final excluded = <String>[];
    final root = Directory(sourcePath);
    try {
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final local = path
            .relative(entity.path, from: sourcePath)
            .replaceAll('\\', '/');
        final segs = local.split('/');
        // 🔴 源目录里混进 .CTPatch / 补丁 目录时不铺进游戏目录（防自己吃自己）。
        if (segs.any(isPatchVaultInternalDirName)) {
          excluded.add(local);
          continue;
        }
        rel.add(local);
        try {
          sizes[local] = await entity.length();
        } catch (_) {
          sizes[local] = 0;
        }
      }
    } catch (e) {
      return _unsupported(PatchContainer.directory, '无法遍历文件夹：$e');
    }

    final bad = validateEntryPaths(rel);
    if (bad.isNotEmpty) {
      return PatchInspection(
        container: PatchContainer.directory,
        kind: PatchKind.unknown,
        fileCount: rel.length,
        totalBytes: _sum(sizes),
        readmeNames: const <String>[],
        exeNames: const <String>[],
        dllNames: const <String>[],
        relativePaths: const <String>[],
        warnings: <String>['文件夹内含 ${bad.length} 个非法路径，已拒绝应用'],
        reason: '路径不合法',
        isApplyable: false,
      );
    }

    final layout = resolveLayout(rel);
    final strippedSizes = <String, int>{};
    for (final e in sizes.entries) {
      final n = normalizeEntryPath(e.key);
      if (n == null) continue;
      var p = n;
      if (layout.wrapper != null && p.startsWith('${layout.wrapper!}/')) {
        p = p.substring(layout.wrapper!.length + 1);
      }
      if (p.isNotEmpty) strippedSizes[p] = e.value;
    }
    final preview = previewFromRawPaths(
      rel,
      sizes: sizes,
      gameExeNames: gameExeNames,
      gameTopDirs: gameTopDirs,
    );
    final result = _fromPreview(
      PatchContainer.directory,
      preview,
      extraWarnings: excluded.isEmpty
          ? const <String>[]
          : <String>['已跳过 ${excluded.length} 个内部目录文件（补丁/备份目录）'],
    );
    return PatchInspection(
      container: result.container,
      kind: result.kind,
      fileCount: result.fileCount,
      totalBytes: _sum(strippedSizes),
      readmeNames: result.readmeNames,
      exeNames: result.exeNames,
      dllNames: result.dllNames,
      relativePaths: layout.paths,
      warnings: result.warnings,
      reason: result.reason,
      isApplyable: result.isApplyable && layout.paths.isNotEmpty,
      preview: result.preview,
    );
  }

  PatchInspection _fromPreview(
    PatchContainer container,
    PatchPreview preview, {
    required List<String> extraWarnings,
  }) {
    final readmeNames = preview.readmes.map((e) => e.path).toList();
    final exeNames = preview.installers.map((e) => e.path).toList();
    final dllNames = preview.libraries.map((e) => e.path).toList();
    final warnings = <String>[
      ...preview.warnings.map((w) => w.replaceAll(
          '建议先自己备份游戏目录', '本功能会在应用前自动备份被覆盖的文件')),
      ...extraWarnings,
    ];
    if (readmeNames.isNotEmpty) {
      warnings.add('包内有说明文件（${readmeNames.first}），打补丁前请先读一遍');
    }
    // 🔴 补丁站的 usageHint 写「本软件不会代跑安装器」，仍成立；但本功能
    // 会备份并回退，所以这里补上诚实边界，不制造虚假安全感。
    if (preview.advice == PatchTargetAdvice.installerOnly ||
        (preview.installers.length == 1 && preview.files.length == 1)) {
      warnings.add('本软件不代跑安装器，也不会记录它做的改动 ⇒ 这类补丁无法自动回退');
    }
    return PatchInspection(
      container: container,
      kind: _kindOf(preview),
      fileCount: preview.files.length,
      totalBytes: preview.totalBytes,
      readmeNames: readmeNames,
      exeNames: exeNames,
      dllNames: dllNames,
      relativePaths: preview.files.map((e) => e.path).toList(),
      warnings: warnings,
      reason: preview.reason,
      isApplyable: preview.advice != PatchTargetAdvice.blocked &&
          preview.advice != PatchTargetAdvice.installerOnly &&
          preview.files.isNotEmpty,
      preview: preview,
    );
  }

  PatchKind _kindOf(PatchPreview p) {
    if (p.advice == PatchTargetAdvice.installerOnly) {
      return PatchKind.installer;
    }
    if (p.libraries.isNotEmpty) return PatchKind.dllInject;
    final exeSet = gameExeNames.map((e) => e.toLowerCase()).toSet();
    if (p.installers.any((e) => exeSet.contains(e.name.toLowerCase()))) {
      return PatchKind.replaceExe;
    }
    if (p.advice == PatchTargetAdvice.gameRoot &&
        (p.dataFiles.isNotEmpty || p.reason.contains('覆盖'))) {
      return PatchKind.overlay;
    }
    return PatchKind.unknown;
  }

  // ---------------- 不支持的形态 ----------------

  PatchInspection _installer(String sourcePath) => PatchInspection(
        container: PatchContainer.exe,
        kind: PatchKind.installer,
        fileCount: 1,
        totalBytes: _fileSize(sourcePath),
        readmeNames: const <String>[],
        exeNames: <String>[path.basename(sourcePath)],
        dllNames: const <String>[],
        relativePaths: const <String>[],
        warnings: const <String>[
          '本软件不代跑安装器（EXE），请自行运行',
          '安装器写入的内容没有基线记录 ⇒ 这类补丁无法自动回退',
        ],
        reason: '这是安装器，需要你自己运行',
        isApplyable: false,
      );

  PatchInspection _unsupported(PatchContainer container, String reason) =>
      PatchInspection(
        container: container,
        kind: PatchKind.unknown,
        fileCount: 0,
        totalBytes: 0,
        readmeNames: const <String>[],
        exeNames: const <String>[],
        dllNames: const <String>[],
        relativePaths: const <String>[],
        warnings: <String>[reason],
        reason: reason,
        isApplyable: false,
      );

  static int _sum(Map<String, int> m) =>
      m.values.fold<int>(0, (s, e) => s + e);

  static int _fileSize(String p) {
    try {
      return File(p).lengthSync();
    } catch (_) {
      return 0;
    }
  }
}

/// 只读扫描游戏目录，给识别器提供「换 exe 型 / 覆盖式」的判定依据。
///
/// 🔴 exe 名字必须从**启动目录**扫（换 exe / DLL 注入都发生在那里），
/// 顶层子目录名从**本体根**扫（覆盖式要与本体结构同构）。
/// 两个根混用会让「替换主程序型」被误判成隔离型（探针实测踩过）。
/// 🔴 只列**顶层**，不递归游戏本体（有的游戏几十万文件）。
Future<({List<String> exeNames, List<String> topDirs})> scanGameShape(
  String bodyRoot, {
  String launchDir = '',
}) async {
  final exeNames = <String>[];
  final topDirs = <String>[];
  try {
    await for (final e in Directory(launchDir.isNotEmpty ? launchDir : bodyRoot)
        .list(followLinks: false)) {
      if (e is File && path.extension(e.path).toLowerCase() == '.exe') {
        exeNames.add(path.basename(e.path).toLowerCase());
      }
    }
  } catch (_) {}
  try {
    await for (final e in Directory(bodyRoot).list(followLinks: false)) {
      if (e is Directory) {
        topDirs.add(path.basename(e.path).toLowerCase());
      }
    }
  } catch (_) {}
  return (exeNames: exeNames, topDirs: topDirs);
}
