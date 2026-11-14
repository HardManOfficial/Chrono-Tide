import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../models/patch_resource.dart';
import '../path_validator.dart';
import 'patch_download_core.dart';
import 'patch_extract_service.dart';
import 'patch_preview.dart';
import 'patch_save_location.dart';

/// 补丁下载阶段
enum PatchDownloadPhase {
  idle,

  /// 正在传输
  downloading,

  /// 传完了，正在算 sha256
  verifying,

  /// 压缩包已落地，正在解压（用户开了「下载后自动解压」时才有这一步）
  extracting,

  /// 完成（文件已落地在用户选的目录）
  done,

  /// 失败（[PatchDownloadState.message] 有原因）
  failed,

  /// 用户取消（`.part` 保留，下次可续传）
  canceled,
}

/// 一次性快照（不可变，便于 `AnimatedBuilder` 直接比较）
@immutable
class PatchDownloadState {
  const PatchDownloadState({
    required this.patchKey,
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.bytesPerSecond = 0,
    this.filePath,
    this.message,
    this.saveDir,
    this.extractDir,
    this.extractedCount = 0,
    this.hint,
  });

  /// 对应 [PatchResource.key]
  final String patchKey;
  final PatchDownloadPhase phase;
  final int received;

  /// 0 = 服务器没给 Content-Length（进度条退化为不确定态）
  final int total;
  final double bytesPerSecond;
  final String? filePath;
  final String? message;

  /// 落地目录（用户选的那个；用于「打开文件夹」和取消后的提示）
  final String? saveDir;

  /// 解压出来的目录（null = 没解压 / 解压失败，压缩包仍然在）
  final String? extractDir;

  /// 解压出多少个文件（0 = 未知）
  final int extractedCount;

  /// 包形态提示（"含 Setup.exe，请自行运行" / "DLL 注入型…"），可能为 null
  final String? hint;

  PatchDownloadState copyWith({
    PatchDownloadPhase? phase,
    int? received,
    int? total,
    double? bytesPerSecond,
    String? filePath,
    String? message,
    String? saveDir,
    String? extractDir,
    int? extractedCount,
    String? hint,
  }) =>
      PatchDownloadState(
        patchKey: patchKey,
        phase: phase ?? this.phase,
        received: received ?? this.received,
        total: total ?? this.total,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        filePath: filePath ?? this.filePath,
        message: message ?? this.message,
        saveDir: saveDir ?? this.saveDir,
        extractDir: extractDir ?? this.extractDir,
        extractedCount: extractedCount ?? this.extractedCount,
        hint: hint ?? this.hint,
      );

  bool get isRunning =>
      phase == PatchDownloadPhase.downloading ||
      phase == PatchDownloadPhase.verifying ||
      phase == PatchDownloadPhase.extracting;

  /// 0..1；未知总长时返回 null
  double? get fraction {
    if (total <= 0) return null;
    final f = received / total;
    return f.isNaN ? null : f.clamp(0.0, 1.0);
  }

  String get sizeLabel => formatPatchBytes(received, total);
  String get speedLabel => bytesPerSecond <= 0
      ? ''
      : '${formatPatchBytes(bytesPerSecond.round(), 0)}/s';
}

/// 补丁下载器（PATCH-STATION P3）。
///
/// ## 为什么不复用 `DownloadCore`
///
/// `DownloadCore` 的语义是「**安装一部游戏**」：它要 gameId、要解析游戏库
/// 落盘位置、要 `autoExtract` 解压成目录、还要写 `game.json` 登记。
/// 补丁站是「**下载一个文件**」，和下载游戏本体同构：用户选目录 → 下进去
/// → 顺手解压 → 结束。⛔ 不登记、⛔ 不覆盖游戏文件、⛔ 不启动任何东西。
/// 硬塞进 `DownloadCore` 会在 `game.json` 里造出一堆假游戏条目。
///
/// 复用的是**范式**而不是类：一次一个任务、`.part` 续传、2 倍体积的磁盘
/// 预检、进度速率滑动窗口。
///
/// ## 三条硬规则
///
/// 1. 🔴 **一次只跑一个**：与 `DownloadCore` 一致。并发下载补丁既抢带宽
///    又让「进度显示在哪个卡片上」变得不可解释。
/// 2. 🔴 **校验不符必须删文件**：sha256 对不上说明服务器给了错文件（或
///    中间被劫持），留在盘上只会被下一次续传当成"已完成前缀"，越错越远。
/// 3. 🔴 **取消保留 `.part`**：补丁包动辄上 GB，断一次就从头下是折磨。
///    只有「校验失败」「空间不足」这类**确定性损坏**才删。
/// 4. 🔴 **解压失败不删压缩包**：压缩包本身就是用户要的成品，解压只是
///    附赠。解压炸了要让文件留在原地，⛔ 绝不能「连同压缩包一起清理」。
class PatchDownloadService extends ChangeNotifier {
  PatchDownloadService._();

  static final PatchDownloadService instance = PatchDownloadService._();

  /// 默认保存目录（用户没选过时用）：`<库根>/ChronoTide_Patches`
  ///
  /// 🔴 与旧版的 `ChronoTide_Cache/patches` 不同：缓存目录会被清理逻辑扫到，
  /// 而补丁下完就是成品（有的直链会失效，删了就找不回来）。
  static String get defaultSaveDir => PatchSaveLocation.suggestedDir;

  static const int _reserveBytes = 64 * 1024 * 1024;

  /// 下载完是否顺手解压（zip 且魔数匹配时）。
  ///
  /// 用户语义是「可以帮忙下载解压，但不立刻使用」⇒ 默认开。
  /// 非 zip / EXE 安装器会被解压器显式拒绝，那时**保留文件 + 给提示**。
  bool autoExtract = true;

  /// 供探针注入假解压器（避免探针必须造真 zip / 真网络）
  @visibleForTesting
  Future<PatchExtractResult> Function(String archivePath, String destDir)?
      extractHook;

  PatchDownloadState? _state;
  PatchDownloadState? get state => _state;

  CancelToken? _cancelToken;
  bool _cancelRequested = false;

  /// 供测试注入
  @visibleForTesting
  Dio? dioOverride;

  Dio get _dio =>
      dioOverride ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        headers: const {'User-Agent': 'ChronoTide/1.0'},
        followRedirects: true,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ));

  /// 该补丁当前是否正在下载
  bool isRunningKey(String patchKey) =>
      _state?.patchKey == patchKey && _state!.isRunning;

  /// 该补丁当前状态（不是本补丁则返回 null）
  PatchDownloadState? stateOf(String patchKey) =>
      _state?.patchKey == patchKey ? _state : null;

  void _emit(PatchDownloadState s) {
    _state = s;
    notifyListeners();
  }

  /// 开始下载。[resource.directUrl] 必须非空（`direct` 形态才有）。
  ///
  /// [saveDir] = 用户在保存位置对话框里选的目录；null 时用
  /// [PatchSaveLocation.resolve]（用户上次选的 / 默认建议目录）。
  Future<void> download(PatchResource resource, {String? saveDir}) async {
    final url = (resource.directUrl ?? '').trim();
    if (url.isEmpty) {
      _emit(PatchDownloadState(
        patchKey: resource.key,
        phase: PatchDownloadPhase.failed,
        message: '这个补丁没有直链，请用「复制链接」或「打开原页」',
      ));
      return;
    }
    if (_state?.isRunning == true) {
      // 一次一个：不打断当前任务，明确告知
      _emit(_state!.copyWith(
        message: '已有补丁正在下载，请等它结束或先取消',
      ));
      return;
    }

    _cancelRequested = false;
    _cancelToken = CancelToken();
    final key = resource.key;
    _emit(PatchDownloadState(
      patchKey: key,
      phase: PatchDownloadPhase.downloading,
      total: resource.sizeBytes ?? 0,
    ));

    File? part;
    try {
      // ---- 目标目录：用户选的，不是我们的缓存 ----
      final destPath = (saveDir == null || saveDir.trim().isEmpty)
          ? await PatchSaveLocation.instance.resolve()
          : saveDir.trim();
      final dir = Directory(destPath);
      if (!await dir.exists()) await dir.create(recursive: true);

      final fileName = patchFileName(resource, url);
      final target = File(path.join(dir.path, fileName));
      part = File('${target.path}.part');

      // ---- 磁盘预检：压缩包 1 倍 + 解压预留 ——---
      // 解压后体积无法预知（zip 里可能有高度可压的脚本），所以只按
      // 「包体 × 2」这个保守口径预检，⛔ 不承诺"一定能解开"。
      await _ensureDiskSpace(dir.path, (resource.sizeBytes ?? 0) * 2);

      // ---- 续传 ----
      var already = 0;
      if (await part.exists()) {
        already = await part.length();
      }

      final headers = <String, dynamic>{};
      if (already > 0) headers['Range'] = 'bytes=$already-';

      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          // 206 = 续传命中；200 = 服务器忽略 Range，必须从头写
          validateStatus: (s) => s == 200 || s == 206,
        ),
        cancelToken: _cancelToken,
      );

      final code = resp.statusCode ?? 200;
      if (code == 200 && already > 0) {
        // 服务器不支持续传 ⇒ 已下部分作废，整份重来
        already = 0;
      }

      final contentLength =
          int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
      final total = contentLength > 0 ? already + contentLength : 0;

      final sink = part.openWrite(
        mode: already > 0 ? FileMode.append : FileMode.write,
      );

      var received = already;
      final sw = Stopwatch()..start();
      var lastTick = 0;
      var lastBytes = received;
      var lastMs = 0;

      try {
        await for (final chunk in resp.data!.stream) {
          if (_cancelRequested) {
            throw _Cancelled();
          }
          sink.add(chunk);
          received += chunk.length;

          final ms = sw.elapsedMilliseconds;
          if (ms - lastTick >= 200) {
            lastTick = ms;
            final dt = ms - lastMs;
            final speed = dt > 0 ? (received - lastBytes) * 1000 / dt : 0.0;
            lastBytes = received;
            lastMs = ms;
            _emit(PatchDownloadState(
              patchKey: key,
              phase: PatchDownloadPhase.downloading,
              received: received,
              total: total,
              bytesPerSecond: speed,
            ));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (_cancelRequested) throw _Cancelled();

      // ---- 校验 ----
      _emit(PatchDownloadState(
        patchKey: key,
        phase: PatchDownloadPhase.verifying,
        received: received,
        total: total > 0 ? total : received,
      ));

      final expected = resource.sha256.trim().toLowerCase();
      if (expected.length >= 32) {
        final actual = await sha256OfFile(part.path);
        if (actual.toLowerCase() != expected) {
          // 🔴 校验失败必须删：留着会被下次续传当成合法前缀
          await _deleteQuietly(part);
          _emit(PatchDownloadState(
            patchKey: key,
            phase: PatchDownloadPhase.failed,
            message: '校验失败，文件已删除（可能下载不完整或被替换）',
          ));
          return;
        }
      }

      // ---- 落正式文件名 ----
      if (await target.exists()) await _deleteQuietly(target);
      await part.rename(target.path);

      // ---- 顺手解压（可选；失败绝不删压缩包）----
      final container = PatchExtractService.sniffContainer(target.path);
      String? extractDir;
      var extractedCount = 0;
      String? hint;

      if (container == 'exe') {
        hint = '这是安装器（EXE），双击运行它即可；软件不代跑';
      } else if (container == '7z' || container == 'rar') {
        hint = '这个包是 .$container，需要 7-Zip 手动解压';
      } else if (container == 'zip' && autoExtract) {
        _emit(PatchDownloadState(
          patchKey: key,
          phase: PatchDownloadPhase.extracting,
          received: received,
          total: total > 0 ? total : received,
          filePath: target.path,
          saveDir: dir.path,
        ));
        try {
          final extractRoot = await _resolveExtractDir(dir.path, target.path);
          final res = extractHook != null
              ? await extractHook!(target.path, extractRoot)
              : await const PatchExtractService().extractTo(
                  archivePath: target.path,
                  destDir: extractRoot,
                  // 🔴 扁平：直接铺进 `<保存目录>/<包名>/`，⛔ 不要 `extracted/` 这层
                  outDirName: '',
                );
          extractDir = res.rootPath;
          extractedCount = res.entries.length;
          hint = res.toPreview().usageHint;
        } catch (e) {
          // 解压失败 = 压缩包本身可能有问题，但**文件是用户要的东西**，
          // 绝不能因为解不开就把它删了。留下 + 说清楚。
          hint = '解压失败（${_shortError(e)}）；压缩包已保留，可用 7-Zip 打开';
        }
      }

      _emit(PatchDownloadState(
        patchKey: key,
        phase: PatchDownloadPhase.done,
        received: received,
        total: total > 0 ? total : received,
        filePath: target.path,
        saveDir: dir.path,
        extractDir: extractDir,
        extractedCount: extractedCount,
        hint: hint,
      ));
    } on _Cancelled {
      _emit(PatchDownloadState(
        patchKey: key,
        phase: PatchDownloadPhase.canceled,
        message: '已取消，下次可续传',
      ));
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _emit(PatchDownloadState(
          patchKey: key,
          phase: PatchDownloadPhase.canceled,
          message: '已取消，下次可续传',
        ));
      } else {
        _emit(PatchDownloadState(
          patchKey: key,
          phase: PatchDownloadPhase.failed,
          message: _humanize(e),
        ));
      }
    } catch (e) {
      _emit(PatchDownloadState(
        patchKey: key,
        phase: PatchDownloadPhase.failed,
        message: '$e',
      ));
    } finally {
      _cancelToken = null;
    }
  }

  /// 取消当前任务（`.part` 保留以便续传）
  void cancel() {
    _cancelRequested = true;
    _cancelToken?.cancel('user');
  }

  /// 清掉状态显示（不删文件）
  void clearState() {
    if (_state?.isRunning == true) return;
    _state = null;
    notifyListeners();
  }

  /// 只删**未完成的** `.part`，⛔ 绝不碰已经下好的成品。
  ///
  /// 🔴 语义分界：旧版把补丁当"缓存"（可随时重下，随便删）；现在补丁是
  /// **用户要的文件**，直链随时会失效，删了可能永远补不回来。所以清理
  /// 只对 `.part` 生效，成品文件只能由用户自己在资源管理器里删。
  Future<void> discardPartial(PatchResource resource, {String? saveDir}) async {
    if (_state?.patchKey == resource.key && _state?.isRunning == true) {
      cancel();
      return;
    }
    final url = (resource.directUrl ?? '').trim();
    if (url.isEmpty) return;
    final destPath = (saveDir == null || saveDir.trim().isEmpty)
        ? await PatchSaveLocation.instance.resolve()
        : saveDir.trim();
    final dir = Directory(destPath);
    if (!await dir.exists()) return;
    final name = patchFileName(resource, url);
    await _deleteQuietly(File(path.join(dir.path, '$name.part')));
    if (_state?.patchKey == resource.key) {
      _state = null;
      notifyListeners();
    }
  }

  /// 「打开文件夹」——补丁下完的唯一后续动作。
  ///
  /// 用 `explorer` 而不是 `open_file` 之类的新依赖：项目里
  /// `game_data_dialog._openFolder` 已经是这个写法，保持一致。
  static Future<bool> openInExplorer(String dirPath) async {
    if (dirPath.trim().isEmpty) return false;
    try {
      if (!await Directory(dirPath).exists()) return false;
      await Process.start('explorer', <String>[dirPath]);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------- 内部 ----------------

  /// 解压目标目录：`<保存目录>/<包名去扩展名>`，重名就 `_2` / `_3`。
  ///
  /// 🔴 每次都新建独立目录：两个补丁都带 `GameData/` 时，叠在同一个目录里
  /// 用户分不清哪个文件是谁带的。
  Future<String> _resolveExtractDir(String saveDir, String archivePath) async {
    final existing = <String>[];
    await for (final e in Directory(saveDir).list(followLinks: false)) {
      if (e is Directory) existing.add(path.basename(e.path));
    }
    final name = uniqueExtractDirName(path.basename(archivePath), existing);
    return path.join(saveDir, name);
  }

  static String _shortError(Object e) {
    var s = e is PatchExtractException ? e.message : '$e';
    s = s.replaceAll('\n', ' ').trim();
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  Future<void> _ensureDiskSpace(String dir, int expectedSize) async {
    if (expectedSize <= 0) return; // 未知体积 → 不拦
    final need = expectedSize + _reserveBytes;
    try {
      final info = await PathValidator.getDiskSpaceInfo(dir);
      if (!info.isAvailable || info.freeSpaceBytes < 0) return;
      if (info.freeSpaceBytes < need) {
        throw Exception(
          '磁盘空间不足：需要约 ${formatPatchBytes(need)}，'
          '目标盘可用 ${formatPatchBytes(info.freeSpaceBytes)}',
        );
      }
    } catch (e) {
      // 查不到空间（网络卷 / FFI 不可用）按「未知放行」，与 DownloadCore 一致
      if (e is Exception && e.toString().contains('磁盘空间不足')) rethrow;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉就算了：不要因为清理失败把主流程搞崩
    }
  }

  static String _humanize(DioException e) {
    final code = e.response?.statusCode;
    if (code == 403) return '下载被拒绝（403），可能链接已过期，试试「打开原页」';
    if (code == 404) return '文件不存在（404），可能已被删除';
    if (code == 429) return '请求过于频繁（429），稍后再试';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return '网络超时';
      case DioExceptionType.connectionError:
        return '网络不可达';
      default:
        return '下载失败${code == null ? '' : '（$code）'}';
    }
  }
}

class _Cancelled implements Exception {}
