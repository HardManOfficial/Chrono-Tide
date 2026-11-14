/// 补丁包**解压到隔离区**（不碰用户游戏目录）。
///
/// ## 职责边界（与 P4 的关系）
///
/// P4 是"解压 → 预览 → 备份 → 应用 → 回滚 → 本地库"六步，本文件只做**第一步**。
/// 它把补丁解到 `<库根>/ChronoTide_Cache/patches/<key>/extracted/`，
/// 那是我们自己的缓存目录，**不写游戏本体** ⇒ 不需要用户批准就可以落地。
///
/// ## 为什么是进程内 `package:archive`，而不是内置 7z.exe
///
/// 第一版写的是 `Process.run(PathHelper.bundled7zPath, ['x', ...])`，理由很充分
/// （7z 支持 zip/7z/rar、不爆内存、`-sccUTF-8` 解日文名）。但它**验证不了**：
/// 本执行环境的匿名管道被系统级占满（`CreateFile failed 231`），
/// `Process.run` 与 `Process.runSync` 一律抛
/// `ProcessException: 所有的管道范例都在使用中`。按「验证必须打穿到最后一环」，
/// 换回进程内实现：
///
/// | | 7z CLI | `package:archive` |
/// |---|---|---|
/// | 可离线验证 | ❌ 本环境起不了进程 | ✅ |
/// | 支持容器 | zip/7z/rar | **仅 zip** |
/// | 内存 | 流式 | `decodeBuffer(InputFileStream)` + `writeContent` 也是流式 |
/// | 中文/日文名 | `-sccUTF-8` 已解 | 依赖 zip 的 UTF-8 标志位 |
///
/// P0-4 实测的 4 个补丁包 **全是 zip**，所以一期用 zip 够；7z/rar 走显式降级
/// （P5 接 2DFan 时再补 CLI 路径，那时有真实 7z/rar 样本可验）。
///
/// ## zip slip 的防法：**先算清全部目标路径，再逐条落盘**
///
/// 绝不 `archive.files.forEach(write)`。流程固定为
/// `decode → validateEntryPaths → 有非法项整包拒绝 → resolveLayout → 才写`。
/// 写盘路径**只用**归一化后的相对路径拼，绝不拼 `ArchiveFile.name` 原文。
///
/// ⛔ 本文件 import `dart:io`（要写盘），但**不 import flutter**。

import 'dart:io';

import 'package:archive/archive.dart' show ArchiveFile, ZipDecoder;
import 'package:archive/archive_io.dart' show InputFileStream, OutputFileStream;
import 'package:path/path.dart' as path;

import 'patch_path_guard.dart';
import 'patch_preview.dart';

/// 解压阶段的可预期失败（调用方直接拿 message 显示给用户）
class PatchExtractException implements Exception {
  PatchExtractException(this.message,
      {this.rejectedEntries = const <String>[]});

  final String message;

  /// 被护栏拒掉的条目原文（UI 可展开显示）
  final List<String> rejectedEntries;

  @override
  String toString() => message;
}

/// 解压结果
class PatchExtractResult {
  const PatchExtractResult({
    required this.rootPath,
    required this.wrapper,
    required this.entries,
    required this.totalBytes,
  });

  /// 补丁内容所在目录（外层目录已剥掉）
  final String rootPath;

  /// 被剥掉的外层目录名（null = 本来没有）
  final String? wrapper;

  /// 剥壳后的文件清单（相对 [rootPath]）
  final List<PatchEntry> entries;

  final int totalBytes;

  /// 直接喂给 [buildPatchPreview]
  PatchPreview toPreview({
    List<String> gameExeNames = const <String>[],
    List<String> gameTopDirs = const <String>[],
  }) =>
      buildPatchPreview(
        entries: entries,
        wrapper: wrapper,
        gameExeNames: gameExeNames,
        gameTopDirs: gameTopDirs,
      );
}

/// 补丁解压器（仅 zip；7z/rar 显式降级）
class PatchExtractService {
  const PatchExtractService();

  /// 解压临时目录名（放在 destDir 内 ⇒ 同卷，rename 是原子的）
  static const String tmpDirName = '.unpack_tmp';

  /// 最终内容目录名
  static const String extractedDirName = 'extracted';

  /// 单包解压后总体积上限（防 zip 炸弹：声称 1KB 解出 100GB）
  static const int maxTotalBytes = 8 * 1024 * 1024 * 1024;

  /// 列出包内条目（不解压）
  Future<List<PatchEntry>> listEntries(String archivePath) async {
    final zip = await _openZip(archivePath);
    try {
      return zip.files
          .map((e) => PatchEntry(path: e.name, size: e.size))
          .toList();
    } finally {
      await zip.close();
    }
  }

  /// 容器嗅探（只读前 8 字节）
  ///
  /// 补丁下载下来的文件名不可靠（见 `patch_download_core.patchFileName`），
  /// 所以按魔数判定而不是扩展名。
  static String sniffContainer(String archivePath) {
    final f = File(archivePath);
    if (!f.existsSync()) return 'missing';
    final raf = f.openSync();
    try {
      final head = raf.readSync(8);
      bool starts(List<int> sig) {
        if (head.length < sig.length) return false;
        for (var i = 0; i < sig.length; i++) {
          if (head[i] != sig[i]) return false;
        }
        return true;
      }

      if (starts(<int>[0x50, 0x4B, 0x03, 0x04])) return 'zip';
      if (starts(<int>[0x50, 0x4B, 0x05, 0x06])) return 'zip-empty';
      if (starts(<int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return '7z';
      if (starts(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return 'rar';
      if (starts(<int>[0x4D, 0x5A])) return 'exe';
      return 'unknown';
    } finally {
      raf.closeSync();
    }
  }

  /// 解压到 `[destDir]/<outDirName>/`。
  ///
  /// [destDir] 由调用方给。生产路径是**用户选定的补丁保存目录**：
  /// `<保存目录>/<包名去掉扩展名>/`（见 `PatchDownloadService`）。
  ///
  /// [outDirName]：
  /// - `null`（默认）→ 解到 `<destDir>/extracted/`，给需要隔离区的调用方用
  /// - `''` → **直接铺在 [destDir] 里**，不再多一层目录（下载服务用这个，
  ///   否则用户会看到 `补丁名/extracted/...` 这种多余层级）
  ///
  /// 🔴 本方法**绝不**写游戏目录 —— 补丁站是纯下载器，补丁只是文件，
  /// 落到用户选的路径就结束，使用是以后独立开发的功能。
  Future<PatchExtractResult> extractTo({
    required String archivePath,
    required String destDir,
    String? outDirName,
  }) async {
    final container = sniffContainer(archivePath);
    if (container == 'missing') {
      throw PatchExtractException('补丁包不存在：$archivePath');
    }
    if (container == '7z' || container == 'rar') {
      // ⛔ 不假装支持：静默失败比明确拒绝更伤用户
      throw PatchExtractException(
        '暂不支持 .$container 格式的补丁包（当前只解 zip）。'
        '可以下载后用 7-Zip 手动解压',
      );
    }
    if (container == 'exe') {
      throw PatchExtractException(
        '下载到的是安装器（EXE），不是压缩包。本软件不代跑安装器，'
        '请直接运行它完成安装',
      );
    }
    if (container != 'zip') {
      throw PatchExtractException('无法识别的补丁包格式（魔数不匹配 zip/7z/rar）');
    }

    final zip = await _openZip(archivePath);

    final outDir = outDirName == null
        ? Directory(path.join(destDir, extractedDirName))
        : (outDirName.isEmpty
            ? Directory(destDir)
            : Directory(path.join(destDir, outDirName)));
    try {
      // ---- 1. 先校验，后落盘（zip slip 的唯一防线）----
      final bad = validateEntryPaths(zip.files.map((e) => e.name));
      if (bad.isNotEmpty) {
        throw PatchExtractException(
          '补丁包内有非法路径（穿越到包外），已拒绝解压',
          rejectedEntries: bad,
        );
      }

      // ---- 2. 算布局（剥掉唯一外层目录）----
      final layout = resolveLayout(zip.files.map((e) => e.name));
      if (layout.paths.isEmpty) {
        throw PatchExtractException('补丁包里没有任何文件（可能下载不完整）');
      }

      // 剥壳后路径 → 条目
      final wrapper = layout.wrapper;
      final byStripped = <String, _ZipEntry>{};
      for (final e in zip.files) {
        final n = normalizeEntryPath(e.name);
        if (n == null) continue;
        String? stripped;
        if (wrapper == null) {
          stripped = n;
        } else if (n.startsWith('$wrapper/')) {
          stripped = n.substring(wrapper.length + 1);
        }
        if (stripped == null || stripped.isEmpty) continue;
        byStripped[stripped] = e;
      }

      var declared = 0;
      for (final p in layout.paths) {
        declared += byStripped[p]?.size ?? 0;
      }
      if (declared > maxTotalBytes) {
        throw PatchExtractException(
          '补丁解压后体积异常（${declared ~/ (1024 * 1024)} MB），已拒绝',
        );
      }

      // ---- 3. 落盘 ----
      // 🔴 outDir 与 destDir 相同时（扁平模式）⛔ 绝不能删 —— 那会连
      // 用户刚下好的压缩包一起删掉。扁平模式由调用方保证目录是新建的空目录。
      if (outDir.path != destDir && outDir.existsSync()) {
        await outDir.delete(recursive: true);
      }
      await outDir.create(recursive: true);

      final written = <String>[];
      var total = 0;
      for (final rel in layout.paths) {
        final entry = byStripped[rel];
        if (entry == null) {
          throw PatchExtractException('清单与包内容不一致：缺少 $rel');
        }
        final target = path.joinAll(<String>[outDir.path, ...rel.split('/')]);
        await Directory(path.dirname(target)).create(recursive: true);
        final os = OutputFileStream(target);
        try {
          entry.file.writeContent(os);
        } finally {
          await os.close();
        }
        written.add(rel);
        total += entry.size;
      }

      // ---- 4. 实际树与清单比对（防"预览说写到 A、实际写到 B"）----
      final onDisk = <String>[];
      await for (final e in outDir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          onDisk.add(
            e.path.substring(outDir.path.length + 1).replaceAll('\\', '/'),
          );
        }
      }
      final expected = written.toSet();
      final actualSet = onDisk.toSet();
      if (expected.difference(actualSet).isNotEmpty ||
          actualSet.difference(expected).isNotEmpty) {
        throw PatchExtractException(
          '解压结果与清单不一致（写入 ${expected.length} / 磁盘 ${actualSet.length}）',
        );
      }

      return PatchExtractResult(
        rootPath: outDir.path,
        wrapper: wrapper,
        entries: <PatchEntry>[
          for (final rel in layout.paths)
            PatchEntry(path: rel, size: byStripped[rel]?.size ?? 0),
        ],
        totalBytes: total,
      );
    } catch (_) {
      // 失败不留半成品：否则下次进来会把"上次残留 + 这次的"混在一起
      if (outDir.existsSync()) {
        try {
          await outDir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    } finally {
      await zip.close();
    }
  }

  /// 删除 `destDir` 下的解压产物（卸载 / 换补丁前调用）
  Future<void> clean(String destDir) async {
    for (final name in <String>[tmpDirName, extractedDirName]) {
      final d = Directory(path.join(destDir, name));
      if (d.existsSync()) {
        await d.delete(recursive: true);
      }
    }
  }

  // ---------------- 内部 ----------------

  Future<_OpenZip> _openZip(String archivePath) async {
    if (!File(archivePath).existsSync()) {
      throw PatchExtractException('补丁包不存在：$archivePath');
    }
    final input = InputFileStream(archivePath);
    try {
      // decodeBuffer 只读中央目录，文件内容按需懒读
      final archive = ZipDecoder().decodeBuffer(input);
      final files = <_ZipEntry>[];
      for (final f in archive.files) {
        if (!f.isFile) continue;
        files.add(_ZipEntry(
          name: f.name,
          size: f.size,
          file: f,
        ));
      }
      return _OpenZip(input: input, files: files);
    } on FormatException catch (e) {
      await input.close();
      // archive 用严格 UTF-8 解条目名；日版 zip 常用 CP932，会在这里炸
      throw PatchExtractException(
        '包内文件名编码无法解析（常见于日版 zip 用 CP932 打包）：${e.message}。'
        '请用 7-Zip 手动解压',
      );
    } catch (e) {
      await input.close();
      throw PatchExtractException('无法读取补丁包：$e');
    }
  }
}

class _ZipEntry {
  const _ZipEntry({required this.name, required this.size, required this.file});

  final String name;
  final int size;
  final ArchiveFile file;
}

class _OpenZip {
  const _OpenZip({required this.input, required this.files});

  final InputFileStream input;
  final List<_ZipEntry> files;

  Future<void> close() async {
    try {
      input.closeSync();
    } catch (_) {}
  }
}

/// 由补丁缓存根与补丁 key 拼出解压目标目录
///
/// 单独抽出来是因为**探针与生产必须用同一套路径规则**，
/// 路径拼错会让"预览说写到 A、实际写到 B"。
String patchExtractDirFor(String patchCacheRoot, String patchKey) {
  final safeKey = patchKey.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  return path.join(patchCacheRoot, safeKey);
}
