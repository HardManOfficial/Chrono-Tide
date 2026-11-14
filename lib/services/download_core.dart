import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'extract_manager.dart';
import 'download_acceleration.dart';
import 'download_intensity.dart';
import 'download_cache_dir.dart';
import 'download_space_budget.dart';
import 'path_validator.dart';

enum DownloadStatus {
  idle,
  downloading,
  completed,
  failed,
  cancelled,
}

/// 差网络自适应分档：好网保持并发，差网降低并发 + 缩小分片。
enum _DownloadTier { high, mid, low }

/// ★ DL-SINGLE-STREAM（2026-11-14）：一次下载实际采用的传输策略。
///
/// 独立成公开枚举 + [DownloadCore.resolveStrategy] 纯函数，是为了让探针能
/// 直接锁死「什么条件下走哪条路」——完整 [DownloadCore.start] 在
/// flutter_tester 里跑不起来（内部 `Directory.create` 会永久挂起），
/// 分支判定就成了唯一可自动化回归的部分。
enum DownloadStrategy {
  /// 缓存里已有完整包，直接跳过下载进入解压
  skipExisting,

  /// 单连接直链（用户指定，或服务器不支持 Range）
  singleStream,

  /// 分片并发（按下载强度分档）
  chunked,
}

/// Isolate 合并参数
class _MergeParams {
  final List<String> chunkPaths;
  final String finalPath;
  final int expectedSize;
  final int bufferSize;

  const _MergeParams({
    required this.chunkPaths,
    required this.finalPath,
    required this.expectedSize,
    required this.bufferSize,
  });
}

/// Isolate 合并结果
class _MergeResult {
  final bool success;
  final String? error;

  const _MergeResult({required this.success, this.error});
}

/// 在独立 Isolate 中执行分片合并，避免同步 I/O 阻塞主 Isolate
_MergeResult _mergeChunksInIsolate(_MergeParams params) {
  try {
    final outFile = File(params.finalPath);
    final outRaf = outFile.openSync(mode: FileMode.write);

    try {
      for (int i = 0; i < params.chunkPaths.length; i++) {
        final chunkFile = File(params.chunkPaths[i]);
        if (!chunkFile.existsSync()) {
          throw Exception('分片$i临时文件无法合并');
        }

        final inRaf = chunkFile.openSync(mode: FileMode.read);
        try {
          final buffer = List<int>.filled(params.bufferSize, 0);
          int bytesRead;

          while ((bytesRead = inRaf.readIntoSync(buffer)) > 0) {
            if (bytesRead < buffer.length) {
              outRaf.writeFromSync(buffer.sublist(0, bytesRead));
            } else {
              outRaf.writeFromSync(buffer);
            }
          }
        } finally {
          inRaf.closeSync();
        }
      }

      outRaf.flushSync();

      final mergedLength = outRaf.lengthSync();
      if (mergedLength != params.expectedSize) {
        if (mergedLength > params.expectedSize) {
          outRaf.truncateSync(params.expectedSize);
        }
        outRaf.flushSync();
      }

      outRaf.closeSync();
    } catch (e) {
      outRaf.closeSync();
      return _MergeResult(success: false, error: e.toString());
    }

    final finalSize = outFile.lengthSync();
    if (finalSize != params.expectedSize) {
      return _MergeResult(
        success: false,
        error: '文件大小校验失败: 最终$finalSize ≠ 预期${params.expectedSize}',
      );
    }

    return const _MergeResult(success: true);
  } catch (e) {
    return _MergeResult(success: false, error: e.toString());
  }
}

class DownloadProgress {
  final double percent;
  final int downloadedBytes;
  final int totalBytes;
  final String speed;

  /// ★ 2026-09-26 稳定性批B2：看门狗等内部自愈事件对用户可见的说明文案。
  /// null = 常规进度（上层显示默认文案）。
  final String? statusMessage;

  const DownloadProgress({
    required this.percent,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speed,
    this.statusMessage,
  });
}

/// 吞吐探测结果（2026-09-26 稳定性批C5）：
/// [totalSizeFromContentRange] 取自探测响应的 `Content-Range: bytes s-e/total`。
/// HEAD 的 Content-Length 对部分网盘不可信（±5% 容差注释即踩坑证据），
/// 分片计划的总长以该值为准。
class _ProbeOutcome {
  final _DownloadTier tier;
  final int? totalSizeFromContentRange;

  const _ProbeOutcome(this.tier, this.totalSizeFromContentRange);
}

class _ChunkTask {
  final int index;
  final int startByte;
  final int endByte;
  String tempPath;
  int receivedBytes = 0;
  bool completed = false;
  CancelToken? cancelToken;

  _ChunkTask({
    required this.index,
    required this.startByte,
    required this.endByte,
    required this.tempPath,
  });

  int get totalBytes => endByte - startByte + 1;
}

/// ★ DL-DISK-GUARD（2026-11-03）：**不可重试**的写入类错误
/// （磁盘写满 / 无写权限 / 写盘挂死）。
///
/// 与普通异常分开的原因：旧实现把 `writeFrom failed ... (OS Error: 磁盘空间不足,
/// errno = 112)` 当作普通网络抖动，退避重试 15 轮，每轮都重新拉几十 MB 的 Range
/// 再写失败一次 —— 用户看到的就是「速度 0 B/s、永远正在下载」，而磁盘早就满了。
class _FatalWriteException implements Exception {
  final String message;
  const _FatalWriteException(this.message);

  @override
  String toString() => message;
}

class DownloadCore {
  // ── 差网络自适应分档（P2）：好网保持并发，差网降并发 + 缩小分片 ──
  static const int _probeBytes = 4 * 1024 * 1024;            // 探测下载量：4MB
  static const Duration _probeTimeout = Duration(seconds: 8); // 探测整体兜底超时
  static const Duration _probeBudget = Duration(seconds: 4);  // 探测时间预算
  static const double _tierHighBps = 2 * 1024 * 1024;         // ≥2MB/s → 高档
  static const double _tierMidBps = 512 * 1024;               // ≥512KB/s → 中档
  static const int _tierHighConcurrency = 4;
  static const int _tierMidConcurrency = 3;
  static const int _tierLowConcurrency = 2;
  static const int _tierHighChunkSize = 64 * 1024 * 1024;      // 快网 64MB/片
  static const int _tierMidChunkSize = 32 * 1024 * 1024;       // 中 32MB/片
  static const int _tierLowChunkSize = 16 * 1024 * 1024;       // 差网 16MB/片

  // ── 下载强度三档（2026-09-26 批D，用户批准方案）──
  static const int _tierLightChunkSize = 8 * 1024 * 1024;      // 轻量 8MB/片
  static const int _tierLightConcurrency = 1;                  // 轻量单连接
  static const int _tierFullConcurrency = 6;                   // 全速 6 连接（网盘单 IP 限 8 内留余量）
  /// 自动档档位记忆有效期：24h 内命中免重复探测（省 4MB 流量与等待）。
  static const Duration _tierCacheTtl = Duration(hours: 24);
  static const String _kTierCacheKey = 'download_tier_cache';
  static const String _kTierCacheAtKey = 'download_tier_cache_at';

  static const double _downloadMaxPercent = 95.0;
  static const double _mergeStartPercent = 95.0;
  static const int _speedWindowSize = 5;
  static const int _progressThrottleMs = 500;
  static const int _logThrottlePercent = 5;
  static const int _ioBufferSize = 1024 * 1024;
  static const int _mergeBufferSize = 4 * 1024 * 1024; // 4MB，减少 I/O 调用次数

  // ── 写入 / 磁盘护栏（DL-DISK-GUARD，2026-11-03）──
  /// 单次「等待写盘落定」的上限。磁盘写满时 `IOSink` 的 flush/close 可能永不
  /// 完成（写错误只经 sink.done 上报，没人监听），表现为整块下载永久挂死；
  /// 超过该时长即判写入侧异常，直接失败而不是无限等。
  static const Duration _writeStallTimeout = Duration(seconds: 30);

  /// 下载期磁盘安全余量：剩余空间低于「未完成字节 + 该值」即中止。
  static const int _diskReserveBytes = 512 * 1024 * 1024;

  /// 下载期磁盘巡检间隔（挂在 1s 进度 tick 上，即每 5s 一次）。
  static const int _diskCheckEveryTicks = 5;

  static int _activeTaskCount = 0;
  static bool get hasActiveTask => _activeTaskCount > 0;

  static Dio? _sharedDio;
  static Dio get _dio {
    if (_sharedDio == null) {
      _sharedDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        // ★ P2 弱网修复（2026-09-18）：无数据超时 300s→45s。旧值在差网络连接
        // 半开（服务器停发但 TCP 未断）时要等 5 分钟才重连，表现就是「下载卡在中途
        // 不动」。45s 内无新数据即判定半开 → 走分片续传重试，慢啃把大文件啃完。
        receiveTimeout: const Duration(seconds: 45),
        sendTimeout: const Duration(seconds: 30),
        receiveDataWhenStatusError: true,
        headers: {
          'User-Agent': 'ChronoTide/2.0',
          'Connection': 'keep-alive',
          'Keep-Alive': 'timeout=120, max=100',
        },
      ));
    }
    return _sharedDio!;
  }

  DownloadStatus _status = DownloadStatus.idle;
  DownloadProgress? _progress;
  String? _savedPath;
  String? _errorMessage;
  String _currentGameId = '';

  /// ★ DL-ACCEL（2026-11-14）：本次任务要走的代理（`http://127.0.0.1:7892`）。
  /// null = 沿用共享 [_dio]（跟随全局代理策略），行为与改动前完全一致。
  /// 由 [start] 的 `proxyUrl` 写入，每个任务独立、不写全局。
  String? _taskProxyUrl;

  String? _gameTitle;
  String? _gameDescription;
  String? _gameCoverUrl;
  String? _gameBannerUrl;
  List<String>? _gameTags;
  String? _gameDeveloper;
  String? _gameSubtitle;
  String? _customGameLocation;
  List<String>? _screenshotUrls;

  final ExtractManager _extractManager = ExtractManager();

  /// ★ DL-SPACE-BUDGET：本实例在全局磁盘预留表里的身份。
  ///
  /// 安装中心与主页任务管理器各持一个 DownloadCore，可同时下载；预留必须按实例
  /// 区分，否则两个任务会互相覆盖对方的承诺量。
  static int _budgetSeq = 0;
  final String _budgetId = 'dl-${++_budgetSeq}';

  /// ★ P0-4：云盘签名直链会过期。提供该回调后，重试遇到 401/403/404/416 时
  /// 会重新解析直链再重试；否则重试永远复用同一个已失效的 URL，必然失败。
  Future<String?> Function()? _urlResolver;

  /// 当前实际使用的下载直链（可被 [_urlResolver] 刷新）。
  String _currentUrl = '';

  final List<_ChunkTask> _chunks = [];
  int _singleStreamReceived = 0; // 单流下载的已接收字节数
  int _lastReceivedBytes = 0;
  DateTime? _lastSpeedTime;
  DateTime? _lastProgressEmitTime;
  DateTime? _lastLogTime;
  double _lastLoggedPercent = -1;

  final List<int> _speedWindow = [];
  int _speedWindowSum = 0;

  // ── 2026-09-26 稳定性批B/C 状态 ──
  /// 连续「普通异常」（非取消、非 HTTP 状态错误）计数；收到数据即清零。
  /// ≥2 时强制重解析直链（批B3：普通异常往往同样是签名直链失效的表现）。
  int _scopeFailStreak = 0;
  /// 连续 HTTP 4xx 计数；刷新直链后仍 4xx（≥2）立即失败（批C7）。
  int _badResponseStreak = 0;
  /// 单流路径的半成品文件路径（批B4：单流无分片，续传量 = 该文件大小）。
  String? _singleStreamFilePath;
  /// 云端来源主键（探索库 PB record.id），入库时写入 game.json 的
  /// `cloud_game_id`（安装审计 P1-4）。由 [start] 的调用方传入。
  String? _cloudGameId;

  Timer? _progressTimer;
  Completer<void>? _extractionCompleter;

  // ── DL-DISK-GUARD 状态（2026-11-03）──
  /// 本次任务实际使用的缓存目录（下载期磁盘巡检的查询目标）。
  String? _cacheDir;
  /// 致命错误（磁盘满等）只上报一次：巡检中止后主流程还会走到 size 校验，
  /// 不复位会把同一次失败报两遍（第二遍还会覆盖掉更准确的文案）。
  bool _fatalReported = false;
  /// 进度 tick 计数，用于把磁盘巡检降频到每 [_diskCheckEveryTicks] 秒。
  int _diskTick = 0;
  /// 磁盘巡检重入闸：查询是异步的，1s tick 可能叠加。
  bool _diskCheckInFlight = false;

  final List<void Function(DownloadStatus)> _statusListeners = [];
  final List<void Function(DownloadProgress)> _progressListeners = [];
  final List<void Function(String path)> _completeListeners = [];
  final List<void Function(String message)> _errorListeners = [];

  DownloadStatus get status => _status;
  DownloadProgress? get progress => _progress;
  String? get savedPath => _savedPath;
  String? get errorMessage => _errorMessage;

  void addStatusListener(void Function(DownloadStatus) listener) {
    _statusListeners.add(listener);
  }

  void addProgressListener(void Function(DownloadProgress) listener) {
    _progressListeners.add(listener);
  }

  void addCompleteListener(void Function(String) listener) {
    _completeListeners.add(listener);
  }

  void addErrorListener(void Function(String) listener) {
    _errorListeners.add(listener);
  }

  void removeAllListeners() {
    _statusListeners.clear();
    _progressListeners.clear();
    _completeListeners.clear();
    _errorListeners.clear();
  }

  void _emitStatus(DownloadStatus s) {
    _status = s;
    for (final l in _statusListeners) {
      l(s);
    }
  }

  void _emitProgress(DownloadProgress p) {
    _progress = p;
    for (final l in _progressListeners) {
      l(p);
    }
  }

  void _emitComplete(String path) {
    _savedPath = path;
    for (final l in _completeListeners) {
      l(path);
    }
  }

  void _emitError(String msg) {
    _errorMessage = msg;
    for (final l in _errorListeners) {
      l(msg);
    }
  }

  /// 解析本次下载的落盘目录。
  ///
  /// ★ DL-CACHE-FOLLOW-INSTALL（2026-11-03）：缓存目录跟随「本体安装位置所在
  /// 磁盘」，不再固定为 exe 同级 downloads。旧行为恰好坑到「因为软件所在盘不够
  /// 才把游戏装到别的盘」的用户：缓存仍写回那块窄盘，大文件必然写满。
  /// 解析器自身带三级候选与回退，这里不需要额外兜底。
  Future<String> _resolveSaveDir(String gameId) async {
    final resolved = await DownloadCacheDir.resolveFor(
      installTargetDir: _customGameLocation,
    );
    final dir = Directory(resolved);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir.path;
    debugPrint('[DOWNLOAD-CORE]   缓存目录: ${dir.path}'
        '（安装位置: ${_customGameLocation ?? "默认 Games/"}）');
    return dir.path;
  }

  /// ★ DL-DISK-GUARD：下载开始前的磁盘准入。
  ///
  /// 旧实现只在安装中心查一次「下载包体积」，且体积未知（`expectedSizeBytes`
  /// 为 null）时整条跳过；进到下载段后全程无人再看磁盘 —— 实测 14GB 的包把
  /// D 盘写满（0 字节剩余）后，才在 `writeFrom` 里炸 `errno = 112`。
  ///
  /// 预留量：分片模式 = 2 倍文件大小（32 个 `*.part_N.tmp` 与合并出的整包会
  /// 同时存在），单流模式 = 1 倍；另加 [_diskReserveBytes] 余量。
  Future<void> _ensureDiskSpaceEnough(String dir, int totalSize,
      {required bool multiChunk}) async {
    final need = totalSize * (multiChunk ? 2 : 1) + _diskReserveBytes;
    final info = await PathValidator.getDiskSpaceInfo(dir);
    if (!info.isAvailable || info.freeSpaceBytes < 0) {
      // 查不到空间（网络卷 / FFI 不可用）→ 按「未知放行」，与旧语义一致。
      debugPrint('[DOWNLOAD-CORE]   ⚠️ 无法查询缓存盘空间，跳过准入校验'
          '${info.error == null ? "" : "（${info.error}）"}');
      return;
    }
    // ★ DL-SPACE-BUDGET：扣掉**其他任务**在同一块盘上的承诺量。
    //   两个 DownloadCore 并存时，各自按 2 倍体积独立判断，都以为够 ——
    //   结果一起下到一半同时写满。
    final others = DownloadSpaceBudget.reservedByOthers(dir, _budgetId);
    final usable = info.freeSpaceBytes - others;
    if (usable < need) {
      final basis = multiChunk
          ? '分片与合并文件同时存在，按 2 倍体积 + ${_formatBytes(_diskReserveBytes)} 余量预留'
          : '按 1 倍体积 + ${_formatBytes(_diskReserveBytes)} 余量预留';
      throw _FatalWriteException('磁盘空间不足：本次下载需要约 ${_formatBytes(need)}'
          '（$basis），'
          '缓存盘可用 ${_formatBytes(usable)}'
          '${others > 0 ? "（另有任务已占用 ${_formatBytes(others)}）" : ""}'
          '（$dir）。'
          '请清理该磁盘，或把本体安装位置改到空间充足的磁盘后重试');
    }
    DownloadSpaceBudget.reserve(dir, _budgetId, need);
    debugPrint('[DOWNLOAD-CORE]   磁盘准入通过: 需要 ${_formatBytes(need)}，'
        '可用 ${_formatBytes(usable)}'
        '${others > 0 ? "（已扣除其他任务 ${_formatBytes(others)}）" : ""}');
  }

  /// ★ DL-DISK-GUARD：下载期磁盘巡检（每 [_diskCheckEveryTicks] 秒一次）。
  ///
  /// 写盘失败是最后一道防线（错误出现时盘已经满了、本轮 Range 白拉）；
  /// 巡检能提前一个梯度发现「快满了」，并给出「还剩多少 / 还差多少」的可操作
  /// 文案，而不是让用户对着 0 B/s 猜。
  void _monitorDiskSpace(int received, int totalSize) {
    final dir = _cacheDir;
    if (dir == null || _diskCheckInFlight || _fatalReported) return;
    if (_status != DownloadStatus.downloading) return;
    _diskCheckInFlight = true;
    unawaited(() async {
      try {
        final info = await PathValidator.getDiskSpaceInfo(dir);
        if (!info.isAvailable || info.freeSpaceBytes < 0) return;
        final remaining = (totalSize - received).clamp(0, totalSize);
        // ★ DL-DISK-GUARD-2（2026-11-03）：分片模式在**合并阶段**还要再产出一份
        // 完整文件（分片 P + 合并 P），此刻峰值仍是 2 倍体积。旧逻辑只留
        // 「剩余下载量 + 512MB」：下到 90% 时只需 0.1P，巡检必然放行，结果
        // 合并刚开始就炸 —— 用户看到的是「下载到 99% 突然失败」。
        final mergeReserve = _chunks.isEmpty ? 0 : totalSize;
        final need = remaining + mergeReserve + _diskReserveBytes;
        // 与准入同口径：可用空间要扣掉其他任务在同一块盘上的承诺量。
        final usable =
            info.freeSpaceBytes - DownloadSpaceBudget.reservedByOthers(dir, _budgetId);
        if (usable < need && _status == DownloadStatus.downloading) {
          _abortOnDiskFull('磁盘空间不足：缓存盘（$dir）可用 '
              '${_formatBytes(usable)}，完成下载还需约 '
              '${_formatBytes(need)}（已下载 ${_formatBytes(received)}）');
        }
      } catch (e) {
        debugPrint('[DOWNLOAD-CORE] ⚠️ 磁盘巡检异常: $e');
      } finally {
        _diskCheckInFlight = false;
      }
    }());
  }

  /// ★ DL-SKIP-REDOWNLOAD：缓存里是否已经有一份**完整**的同一个包。
  ///
  /// 判据只用「文件存在 + 长度与声明大小一致（±1% 容差，与后续校验同口径）」。
  /// 刻意不去读魔数/哈希：GB 级包做一次全量哈希要几十秒，与「省下重下」的收益
  /// 不成比例；而包若损坏，解压阶段会明确失败，用户删掉缓存再试即可。
  Future<bool> _hasCompletePackage(String filePath, int totalSize) async {
    if (totalSize <= 0) return false;
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final len = await file.length();
      if (len <= 0) return false;
      final diff = (len - totalSize).abs();
      return diff == 0 || diff / totalSize <= 0.01;
    } catch (_) {
      return false;
    }
  }

  /// 磁盘满时的统一中止：停表 → 取消所有分片 → 一次性报错。
  ///
  /// 必须显式收口：磁盘满时网络读流是好的，看门狗（只测「无数据」）永远不会
  /// 命中，不主动中止就会一直挂在「正在下载 0 B/s」。
  void _abortOnDiskFull(String message) {
    if (_fatalReported) return;
    _fatalReported = true;
    debugPrint('[DOWNLOAD-CORE] ⛔ $message');
    _stopProgressTimer();
    for (final chunk in _chunks) {
      chunk.cancelToken?.cancel('磁盘空间不足');
    }
    _emitProgress(DownloadProgress(
      percent: _progress?.percent ?? 0,
      downloadedBytes: _progress?.downloadedBytes ?? 0,
      totalBytes: _progress?.totalBytes ?? 0,
      speed: '0 B/s',
      statusMessage: '磁盘空间不足，已停止下载',
    ));
    _handleError(message);
  }

  /// 写盘（可感知错误）。
  ///
  /// `RandomAccessFile.writeFrom` 的 await 一定会把写错误抛回本次 attempt。
  /// 旧写法 `IOSink.add` 则不一定：写错误经 `_FileStreamConsumer.addStream` 的
  /// 异步链路抛到 zone，`flush()`/`close()` 未必接得住 —— 现场日志里它就是这样
  /// 直接落到 `PlatformDispatcher.onError`（`app_log_helper.dart:143`，`return
  /// true` 吞掉），于是磁盘早就满了，下载器却以为还在正常下载。
  /// （实测对照见 `dev_probe/verify_disk_guard.dart` ④：同一路径下
  /// RandomAccessFile 稳定抛出 FileSystemException + errCode。）
  Future<void> _writeToFile(
      RandomAccessFile raf, List<int> data, String path) async {
    try {
      await raf.writeFrom(data).timeout(_writeStallTimeout);
    } on TimeoutException {
      throw _FatalWriteException(
          '写入磁盘超时（${_writeStallTimeout.inSeconds} 秒未落盘），可能是磁盘空间不足或磁盘异常：$path');
    } on FileSystemException catch (e) {
      throw _classifyWriteError(e, path);
    }
  }

  Future<void> _flushFile(RandomAccessFile raf, String path) async {
    try {
      await raf.flush().timeout(_writeStallTimeout);
    } on TimeoutException {
      throw _FatalWriteException(
          '写入磁盘超时（${_writeStallTimeout.inSeconds} 秒未落盘），可能是磁盘空间不足或磁盘异常：$path');
    } on FileSystemException catch (e) {
      throw _classifyWriteError(e, path);
    }
  }

  /// 打开（或创建）分片文件用于写入。
  ///
  /// ★ DL-DISK-GUARD：`File.open` 自己也会抛 `FileSystemException` ——
  /// 实测「目标路径是目录」「无写权限」都是 `errCode = 5 拒绝访问`、「父目录
  /// 不存在」是 `errCode = 3`。这里必须一并过 [_classifyWriteError]，否则
  /// 这类错误会被当成普通网络抖动退避重试 15 轮（≈3 分钟），用户看到的就是
  /// 「永远正在下载」（探针 D 复现过）。
  Future<RandomAccessFile> _openFileForWrite(File file,
      {FileMode mode = FileMode.append}) async {
    try {
      return await file.open(mode: mode).timeout(_writeStallTimeout);
    } on TimeoutException {
      throw _FatalWriteException(
          '打开缓存文件超时（${_writeStallTimeout.inSeconds} 秒），磁盘可能异常：${file.path}');
    } on FileSystemException catch (e) {
      throw _classifyWriteError(e, file.path);
    }
  }

  Future<void> _closeFile(RandomAccessFile raf) async {
    try {
      await raf.close().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 关闭文件句柄异常: $e');
    }
  }

  /// 把写盘异常翻译成「致命 / 可重试」两类。
  ///
  /// Windows 错误码：112 = ERROR_DISK_FULL、39 = ERROR_HANDLE_DISK_FULL、
  /// 5 = 拒绝访问。中文系统的消息是「磁盘空间不足。」—— 旧 [_standardizeError]
  /// 只匹配英文 `no space`/`disk`，连文案都映射不上。
  Exception _classifyWriteError(FileSystemException e, String path) {
    final code = e.osError?.errorCode;
    final detail = e.osError?.message ?? e.message;
    final lower = '$detail $path'.toLowerCase();
    final diskFull = code == 112 ||
        code == 39 ||
        lower.contains('磁盘空间不足') ||
        lower.contains('no space') ||
        lower.contains('disk full') ||
        lower.contains('not enough space');
    if (diskFull) {
      return _FatalWriteException(
          '磁盘空间不足：缓存盘已写满，写入失败（$detail）→ $path');
    }
    final denied = code == 5 ||
        lower.contains('拒绝访问') ||
        lower.contains('access denied') ||
        lower.contains('permission');
    if (denied) {
      return _FatalWriteException('文件写入失败：权限不足（$path）');
    }
    return Exception('写入缓存文件失败: $detail ($path)');
  }

  /// ★ DL-SINGLE-STREAM（2026-11-14）：判定本次下载走哪条传输路径。
  ///
  /// 优先级：缓存已有完整包 → 强制单流 → 服务器支持 Range（分片）→ 单流兜底。
  /// 纯函数、无 IO，探针直接锁死全部组合。
  static DownloadStrategy resolveStrategy({
    required bool hasCompletePackage,
    required bool preferSingleStream,
    required bool supportsRange,
  }) {
    if (hasCompletePackage) return DownloadStrategy.skipExisting;
    if (preferSingleStream) return DownloadStrategy.singleStream;
    if (supportsRange) return DownloadStrategy.chunked;
    return DownloadStrategy.singleStream;
  }

  Future<void> start({
    required String url,
    required String gameId,
    String? fileName,
    String? title,
    String? description,
    String? coverUrl,
    String? bannerUrl,
    List<String>? tags,
    String? developer,
    String? customGameLocation,
    List<String>? screenshotUrls,
    String? subtitle,
    Future<String?> Function()? urlResolver,
    bool autoExtract = true,
    String? cloudGameId,
    String? proxyUrl,
    bool preferSingleStream = false,
  }) async {
    debugPrint(
        '[DOWNLOAD-CORE] 发起智能下载 | 游戏ID=$gameId | 直链=${url.length > 60 ? "${url.substring(0, 60)}..." : url}');

    if (_status == DownloadStatus.downloading) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 已有任务在执行，忽略重复请求');
      return;
    }

    _urlResolver = urlResolver;
    _currentUrl = url;
    _taskProxyUrl = (proxyUrl == null || proxyUrl.trim().isEmpty)
        ? null
        : proxyUrl.trim();

    _currentGameId = gameId;
    _gameTitle = title;
    _gameDescription = description;
    _gameCoverUrl = coverUrl;
    _gameBannerUrl = bannerUrl;
    _gameTags = tags;
    _gameDeveloper = developer;
    _gameSubtitle = subtitle;
    _customGameLocation = customGameLocation;
    _screenshotUrls = screenshotUrls;
    _scopeFailStreak = 0;
    _badResponseStreak = 0;
    _singleStreamFilePath = null;
    _cloudGameId = cloudGameId;
    _errorMessage = null;
    _savedPath = null;
    _extractionCompleter = Completer<void>();
    _lastReceivedBytes = 0;
    _lastSpeedTime = DateTime.now();
    _lastProgressEmitTime = DateTime.now();
    _lastLogTime = DateTime.now();
    _lastLoggedPercent = -1;
    _speedWindow.clear();
    _speedWindowSum = 0;
    _chunks.clear();
    _singleStreamReceived = 0;
    _fatalReported = false;
    _diskTick = 0;
    _diskCheckInFlight = false;
    _cacheDir = null;
    _emitStatus(DownloadStatus.downloading);
    _activeTaskCount++;

    // ★ DL-ACCEL：用户显式选了代理时，本次任务用独立 Dio（只走该代理）；
    //   否则沿用共享实例（跟随全局策略）。独立实例必须在任务结束时关闭，
    //   否则连接池悬挂（共享实例 ⛔ 绝不能 close）。
    Dio? ownedDio;

    try {
      final saveDir = await _resolveSaveDir(gameId);
      final Dio dio;
      if (_taskProxyUrl != null) {
        ownedDio = DownloadAcceleration.dioFor(_taskProxyUrl!);
        dio = ownedDio;
        debugPrint('[DOWNLOAD-CORE] 🌐 使用指定代理加速通道: $_taskProxyUrl');
      } else {
        dio = _dio;
      }

      // ★ P0-3：HEAD 原本零重试，一次抖动就让整次安装失败（还没开始下就失败）。
      // 改为带退避的重试，并在 401/403/404/416 时刷新直链。
      final headResponse = await _headWithRetry(dio);
      final contentLength = headResponse.headers.value('content-length');
      if (contentLength == null || contentLength.isEmpty) {
        throw Exception('无法获取文件大小 服务器未返回Content-Length');
      }
      final totalSize = int.tryParse(contentLength);
      if (totalSize == null) {
        throw Exception('文件大小解析失败：$contentLength');
      }

      if (totalSize <= 0) {
        throw Exception('文件大小无效：$totalSize');
      }

      final acceptRanges =
          headResponse.headers.value('accept-ranges')?.toLowerCase() ?? '';
      final supportsRange = acceptRanges == 'bytes';

      // ★ 2026-09-26 稳定性批C5：effectiveTotal 会在分片分支内被探测响应的
      // Content-Range 总长校准覆写（HEAD 的 Content-Length 不可信）。
      var effectiveTotal = totalSize;

      final name =
          _extractFileName(headResponse, url, fileName) ?? '$gameId.bin';
      final filePath = '$saveDir/$name';

      debugPrint('[DOWNLOAD-CORE]   保存路径: $filePath');
      debugPrint(
          '[DOWNLOAD-CORE]   文件大小: ${_formatBytes(totalSize)} | Range支持: $supportsRange');

      // ★ DL-SKIP-REDOWNLOAD（2026-11-03）：缓存里已有**完整**的同一个包时不再重下。
      //
      // 典型场景：上次 14GB 下完了、解压阶段失败（压缩包按既定策略保留在缓存里），
      // 用户点重试 —— 旧实现会把 14GB 从头再下一遍，而盘上那份还占着空间，
      // 等于用 28GB 的读写换一份早就存在的文件，甚至直接因空间不足再失败一次。
      final skipDownload = await _hasCompletePackage(filePath, totalSize);
      final strategy = resolveStrategy(
        hasCompletePackage: skipDownload,
        preferSingleStream: preferSingleStream,
        supportsRange: supportsRange,
      );
      if (strategy == DownloadStrategy.skipExisting) {
        debugPrint('[DOWNLOAD-CORE] ⏩ 缓存中已有完整包（${_formatBytes(totalSize)}），'
            '跳过下载直接进入解压');
        _emitProgress(DownloadProgress(
          percent: 100.0,
          downloadedBytes: totalSize,
          totalBytes: totalSize,
          speed: '已完成',
          statusMessage: '使用已下载的安装包',
        ));
      } else if (strategy == DownloadStrategy.singleStream) {
        // ★ 单流不参与分档，但**必须**尊重全局限速：`DownloadThrottle` 是
        //   进程级静态令牌桶，不同步一次就会沿用上一个任务残留的速率
        //   （或首次运行时恒为 0 = 不限速），用户设的限速等于失效。
        await DownloadIntensityPrefs.applySpeedLimitToThrottle();
        if (preferSingleStream) {
          // ★ DL-SINGLE-STREAM（2026-11-14）：全站库（letmoe 托管直链）刻意
          //   走**单连接直链**，不切分片、也不做档位探测。
          //
          // 用户拍板的取舍：稳定性/安全性优先于峰值吞吐。
          // - 少一次 4MB 探测 + 一次校准请求 ⇒ 启动更快、不白耗流量；
          // - 全程一个连接一条流，不会出现「多分片并发写同名 `.part_N.tmp`」
          //   与「分片完成但合并失败」这两类最难复现的故障；
          // - 续传粒度是「已落盘的字节数」，续传不依赖分片索引，跨重启也能用。
          // 代价：失去多连接叠加（直连单连接实测 0.2MB/s vs 4 路 0.8–2.1MB/s），
          // 所以这条路径建议配合「代理加速通道」或全局代理。
          //
          // 仍保留一次 1 字节 Range 校准 totalSize：单流以落盘字节数判完成，
          // HEAD 的 Content-Length 若偏差就会误判（分片路径同样有这一步）。
          final crTotal = await _calibrateTotalViaRange(dio);
          if (crTotal != null && crTotal > 0 && crTotal != totalSize) {
            debugPrint(
                '[DOWNLOAD-CORE]   ⚠️ HEAD 与 Content-Range 总长不一致（HEAD=$totalSize, Content-Range=$crTotal），以后者为准');
            effectiveTotal = crTotal;
          }
          debugPrint('[DOWNLOAD-CORE]   策略: 单流直连（本任务指定，跳过分片与档位探测）');
        } else {
          debugPrint('[DOWNLOAD-CORE]   策略: 单流直连 (服务器不支持Range)');
        }
        await _ensureDiskSpaceEnough(saveDir, effectiveTotal, multiChunk: false);
        await _startSingleStreamDownload(dio, filePath, effectiveTotal);
      } else {
        // ★ 2026-09-26 批D 下载强度三档（用户批准方案）：
        //   自动 = 探测分档（档位结果记忆 24h 免重复探测）；
        //   轻量 = 单连接 × 8MB（跳过探测，弱网/低配友好）；
        //   全速 = 6 连接 × 64MB（跳过探测，大带宽用户）。
        //   轻量/全速与档位记忆命中时，用 1 字节 Range 请求补 Content-Range
        //   总长校准（替代探测的 C5 校准，几乎零成本）。
        //   限速（DownloadThrottle）只作用于正式下载读流，不约束探测——
        //   否则限速会把探测吞吐压到限速值，档位判断失真。
        final intensity = await DownloadIntensityPrefs.load();
        await DownloadIntensityPrefs.applySpeedLimitToThrottle();
        _DownloadTier tier;
        int? forceChunkSize;
        int? forceConcurrency;
        int? crTotal;
        switch (intensity) {
          case DownloadIntensity.light:
            tier = _DownloadTier.low;
            forceChunkSize = _tierLightChunkSize;
            forceConcurrency = _tierLightConcurrency;
            debugPrint('[DOWNLOAD-CORE]   策略: 轻量档（8MB × 并发1，跳过探测）');
            break;
          case DownloadIntensity.full:
            tier = _DownloadTier.high;
            forceChunkSize = _tierHighChunkSize;
            forceConcurrency = _tierFullConcurrency;
            debugPrint('[DOWNLOAD-CORE]   策略: 全速档（64MB × 并发6，跳过探测）');
            break;
          case DownloadIntensity.auto:
            final cached = await _loadCachedTier();
            if (cached != null) {
              tier = cached;
              debugPrint(
                  '[DOWNLOAD-CORE]   策略: 档位记忆命中（${tier.name}，24h 内免探测）');
            } else {
              // ★ P2 差网络自适应：先小分片探测实际吞吐 → 分档（快网高并发、
              //   差网降并发 + 缩小分片），降低 GB 级文件在弱网下的失败率。
              final probe = await _probeTier(dio);
              tier = probe.tier;
              crTotal = probe.totalSizeFromContentRange;
              await _saveTierCache(tier);
            }
            break;
        }
        crTotal ??= await _calibrateTotalViaRange(dio);
        if (crTotal != null && crTotal > 0 && crTotal != totalSize) {
          debugPrint(
              '[DOWNLOAD-CORE]   ⚠️ HEAD 与 Content-Range 总长不一致（HEAD=$totalSize, Content-Range=$crTotal），以后者为准');
          effectiveTotal = crTotal;
        }
        debugPrint(
            '[DOWNLOAD-CORE]   策略: 分片下载（分档 ${tier.name}，总长 ${_formatBytes(effectiveTotal)}）');
        // ★ DL-DISK-GUARD：开下之前先把磁盘准入做完（2 倍体积，见方法注释）。
        await _ensureDiskSpaceEnough(saveDir, effectiveTotal,
            multiChunk: true);
        await _startMultiChunkDownload(
          dio,
          filePath,
          effectiveTotal,
          tier,
          forceChunkSize: forceChunkSize,
          forceConcurrency: forceConcurrency,
        );
      }

      // ★ DL-DISK-GUARD：下载段可能已被「磁盘满 / 用户取消」中止。旧实现此时
      // 仍会往下走大小校验，得到 0 字节再抛「下载后文件大小为0」，把真实原因
      // （磁盘写满）覆盖成一条无关错误。
      if (_status != DownloadStatus.downloading) {
        debugPrint('[DOWNLOAD-CORE] ⏹ 下载段已中止（状态: ${_status.name}），跳过后续校验');
        _stopProgressTimer();
        // ★ 取消时 [_handleCancel] 的清理早于分片句柄关闭 —— Windows 删不掉
        // 仍被占用的文件，几 GB 的 `.part_*.tmp` 会一直留在用户硬盘上（实测
        // 探针 C 就复现了）。此刻所有 worker 已退出、句柄已关，补删一次。
        if (_status == DownloadStatus.cancelled) {
          await _cleanupTempFilesWithRetry();
        }
        return;
      }

      final size = await File(filePath).length();
      if (size == 0) {
        throw Exception('下载后文件大小为0');
      }

      // 文件大小容差校验：夸克云盘等网盘的 Content-Length 可能不准确
      // 允许 ±1% 误差，仅当差异超过 5% 时才判定失败
      // （批C5：比对基准用 Content-Range 校准后的 effectiveTotal）
      if (effectiveTotal > 0 && size > 0) {
        final diffRatio = (size - effectiveTotal).abs() / effectiveTotal;
        if (diffRatio > 0.05) {
          throw Exception(
              '文件大小差异过大: 实际${_formatBytes(size)} vs 预期${_formatBytes(effectiveTotal)} (差异${(diffRatio * 100).toStringAsFixed(1)}%)');
        } else if (diffRatio > 0.01) {
          debugPrint(
              '[DOWNLOAD-CORE] ⚠️ 文件大小存在轻微差异(${(diffRatio * 100).toStringAsFixed(2)}%)，在容差范围内，继续处理');
        }
      }

      debugPrint(
          '[DOWNLOAD-CORE] ✅ 下载成功 | 本地路径: $filePath | 大小: ${_formatBytes(size)}');

      _emitProgress(DownloadProgress(
        percent: 100.0,
        downloadedBytes: size,
        totalBytes: size,
        speed: '0 B/s',
      ));

      // 先减少活跃任务计数，确保 completed 状态不会被后续异常覆盖
      if (_activeTaskCount > 0) _activeTaskCount--;

      // 发出 completed 状态 — 这是不可逆的，下载已确认成功
      _emitStatus(DownloadStatus.completed);
      _emitComplete(filePath);

      // 触发解压 — 即使解压失败，下载状态仍保持 completed
      // 之前的 bug：_triggerExtraction 抛异常会被 catch 捕获并覆盖 completed 为 failed
      // ★ 2026-09-26 安装审计 P1-5：解压此前被触发两次（这里 + 安装中心
      //   _startExtraction 各一次，第二次对同一压缩包空跑并互相覆盖回调）。
      //   现由调用方声明编排权：GlobalInstallCenter 传 autoExtract=false 自行
      //   编排；GlobalTaskManager 不传（默认 true）行为不变。
      if (autoExtract) {
        try {
          await _triggerExtraction(filePath);
          debugPrint('[DOWNLOAD-CORE] ✅ 下载+解压流程全部完成');
        } catch (extractErr) {
          debugPrint(
              '[DOWNLOAD-CORE] ⚠️ 解压流程异常，但下载状态保持 completed | 错误: $extractErr');
          // 不覆盖 completed 状态，解压失败由 ExtractManager 自身的状态管理处理
        }
      }
    } on DioException catch (e) {
      _stopProgressTimer();
      if (e.type == DioExceptionType.cancel) {
        _handleCancel();
        return;
      }
      _handleError(_mapDioError(e));
    } catch (e) {
      _stopProgressTimer();
      _handleError(e.toString());
    } finally {
      // ★ DL-ACCEL：只关本次任务自己创建的代理 Dio。
      ownedDio?.close(force: true);
      // ★ DL-SPACE-BUDGET：无条件释放预留。漏放会让后续下载被永久误拦，
      // 比不拦更糟 —— [DownloadSpaceBudget.release] 按 taskId 全盘清理，
      // 不依赖本实例算出的盘符是否正确。
      DownloadSpaceBudget.release(_budgetId);
    }
  }

  /// 单流下载（服务器不支持多连接 Range → 无法分片）。
  ///
  /// ★ 2026-09-26 稳定性批C6：旧实现有三个硬伤——
  /// ① 无看门狗：body 流挂起时 `await for` 永久卡死（与分片路径同一根因，
  ///   但看门狗此前只加在分片路径上）；
  /// ② 每次重试 `delete` 整个文件重下：>1GB 的源几乎必败；
  /// ③ maxRetries=3 与分片路径（15）不一致。
  /// 现改为「单连接 Range 续传 + 看门狗 + 重试对齐」：服务器若忽略 Range
  /// 返回 200 全量，则退回整文件重下（本 attempt 内直接消费该响应，不浪费）。
  Future<void> _startSingleStreamDownload(
      Dio dio, String filePath, int totalSize) async {
    _startProgressTimer(totalSize);
    _singleStreamFilePath = filePath;

    const maxRetries = 15;
    const noDataTimeout = Duration(seconds: 45);
    var lastDataTime = DateTime.now();
    var watchdogHit = false;
    var noProgressStreak = 0;
    var lastAttemptBytes = 0;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      final outFile = File(filePath);
      // 续传起点：半成品文件大小（跨重试/跨任务复用；服务器不支持 Range 时清零）
      int existing = 0;
      if (await outFile.exists()) {
        existing = await outFile.length();
        if (existing > totalSize) {
          await outFile.delete();
          existing = 0;
        }
      }
      _singleStreamReceived = existing;
      if (existing > 0) {
        debugPrint(
            '[DOWNLOAD-CORE]   ↻ 单流续传自 ${_formatBytes(existing)}/${_formatBytes(totalSize)}');
      }

      // 应用层看门狗：receiveTimeout 不约束 body 流读取（见 _downloadChunk 注释），
      // 连接半开时 `await for` 会永久挂起 —— 45s 无新字节即中断转为续传重试。
      final attemptToken = CancelToken();
      Timer? watchdog;
      watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_status == DownloadStatus.downloading &&
            DateTime.now().difference(lastDataTime) > noDataTimeout) {
          if (!watchdogHit) {
            watchdogHit = true;
            debugPrint(
                '[DOWNLOAD-CORE]   ⏹ 单流长时间无数据(>45s)，看门狗中断，转为续传');
            _emitWatchdogNotice(null);
          }
          attemptToken.cancel();
        }
      });

      RandomAccessFile? raf;
      try {
        Response<ResponseBody>? response;
        var resumed = false;
        if (existing > 0) {
          response = await dio.get<ResponseBody>(
            _currentUrl,
            options: Options(
              headers: {'Range': 'bytes=$existing-'},
              responseType: ResponseType.stream,
            ),
            cancelToken: attemptToken,
          );
          if (response.statusCode != 206) {
            // 服务器不支持/忽略 Range（200 全量）→ 只能整文件重下。
            // 直接消费本次响应，不再浪费一次往返。
            await outFile.delete();
            existing = 0;
            _singleStreamReceived = 0;
            response = await dio.get<ResponseBody>(
              _currentUrl,
              options: Options(responseType: ResponseType.stream),
              cancelToken: attemptToken,
            );
          } else {
            resumed = true;
          }
        } else {
          response = await dio.get<ResponseBody>(
            _currentUrl,
            options: Options(responseType: ResponseType.stream),
            cancelToken: attemptToken,
          );
        }

        // ★ DL-DISK-GUARD：改直写 RandomAccessFile —— IOSink.add 的写错误可能
        // 经 addStream 异步链路逃逸到 zone（被全局 onError 吞掉），磁盘满时
        // 表现为「界面正常、磁盘 0 字节、永不结束」。
        raf = await _openFileForWrite(outFile,
            mode: resumed ? FileMode.append : FileMode.write);
        await for (final data in response.data!.stream) {
          if (_status != DownloadStatus.downloading) break;
          lastDataTime = DateTime.now();
          // ★ 2026-09-26 批D：单流路径同样受全局限速约束
          await DownloadThrottle.acquire(data.length);
          await _writeToFile(raf, data, filePath);
          _singleStreamReceived += data.length;
        }
        await _flushFile(raf, filePath);
        await raf.close();
        raf = null;

        if (_status != DownloadStatus.downloading) {
          _stopProgressTimer();
          return;
        }

        // 以实际落盘字节数为准；不足则续传重试（与分片路径 P0-2 同语义）。
        final got = await outFile.length();
        if (got >= totalSize) break;
        if (attempt >= maxRetries) break; // 交给外层 ±5% 容差裁决
        if (got <= lastAttemptBytes) {
          noProgressStreak++;
          if (noProgressStreak >= 2) {
            debugPrint(
                '[DOWNLOAD-CORE]   ⚠️ 单流连续 2 轮无进展（$got 字节），停止重试交由大小校验裁决');
            break;
          }
        } else {
          noProgressStreak = 0;
        }
        lastAttemptBytes = got;
        await _backoff(attempt);
        if (_status != DownloadStatus.downloading) {
          _stopProgressTimer();
          return;
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel && !watchdogHit) {
          _stopProgressTimer();
          rethrow;
        }
        // 看门狗取消 → 续传重试（批B2 已在触发时透出进度事件）
        watchdogHit = false;
        if (attempt >= maxRetries) {
          _stopProgressTimer();
          rethrow;
        }
        if (e.type == DioExceptionType.badResponse) {
          await _refreshUrlIfNeeded(e);
          final code = e.response?.statusCode ?? 0;
          if (code >= 400 && code < 500) {
            _badResponseStreak++;
            if (_badResponseStreak >= 2) {
              _stopProgressTimer();
              rethrow;
            }
          }
        }
        await _backoff(attempt);
        if (_status != DownloadStatus.downloading) {
          _stopProgressTimer();
          return;
        }
      } catch (e) {
        // ★ DL-DISK-GUARD：磁盘满 / 无写权限 / 写盘挂死是不可重试的，
        // 直接抛给上层（否则会白拉 15 轮 Range 再写失败 15 次）。
        if (e is _FatalWriteException) {
          _stopProgressTimer();
          rethrow;
        }
        if (attempt >= maxRetries) {
          _stopProgressTimer();
          rethrow;
        }
        _scopeFailStreak++;
        if (_scopeFailStreak >= 2) {
          _scopeFailStreak = 0;
          await _refreshUrl(reason: '单流连续普通异常');
        }
        await _backoff(attempt);
        if (_status != DownloadStatus.downloading) {
          _stopProgressTimer();
          return;
        }
      } finally {
        watchdog.cancel();
        if (raf != null) {
          await _closeFile(raf);
        }
      }
    }

    _stopProgressTimer();
  }

  /// ★ P2 差网络自适应分片下载。
  ///
  /// 相比旧的「固定 4 分片 + totalSize/4」：
  /// ① 分片按档位固定大小切分（快网 64MB / 差网 16MB）——抖动只影响单个小块，
  ///    断点续传的恢复成本从「1.25GB」降到「一个分片」，弱网大文件不再轻易失败；
  /// ② 并发窗口按档位限流（快网 4 / 差网 2）——弱网下降低「多连接同时保持稳定」
  ///    的门槛，从源头减小整批失败概率；
  /// ③ 单分片失败**不再取消同批其余分片**——已完成分片保留落盘，整体失败时
  ///    重试断点续传覆盖率更高（不白掉队友进度）。
  Future<void> _startMultiChunkDownload(
      Dio dio, String filePath, int totalSize, _DownloadTier tier,
      {int? forceChunkSize, int? forceConcurrency}) async {
    int chunkSize;
    int concurrency;
    if (forceChunkSize != null && forceConcurrency != null) {
      // ★ 批D：轻量/全速档显式指定分片计划，不走档位 switch。
      chunkSize = forceChunkSize;
      concurrency = forceConcurrency;
    } else {
      switch (tier) {
        case _DownloadTier.high:
          chunkSize = _tierHighChunkSize;
          concurrency = _tierHighConcurrency;
          break;
        case _DownloadTier.mid:
          chunkSize = _tierMidChunkSize;
          concurrency = _tierMidConcurrency;
          break;
        case _DownloadTier.low:
          chunkSize = _tierLowChunkSize;
          concurrency = _tierLowConcurrency;
          break;
      }
    }

    // ★ P2 分片数 clamp：差网 16MB 分片在大文件下会爆出上百片（1.8GB→112 片），
    // 分片过多导致 .part_*.tmp 文件暴增、进度难观感（用户实测反馈）。限定分片数
    // ≤kMaxChunks，超量时按需放大分片尺寸（断点续传仍逐字节可用，代价只是重试粒度变粗）。
    const int kMaxChunks = 32;
    const int kMinChunkSize = 8 * 1024 * 1024;
    var chunkCount = (totalSize / chunkSize).ceil();
    if (chunkCount > kMaxChunks) {
      chunkSize = (totalSize / kMaxChunks).ceil();
      if (chunkSize < kMinChunkSize) chunkSize = kMinChunkSize;
      chunkCount = (totalSize / chunkSize).ceil();
      debugPrint(
          '[DOWNLOAD-CORE]   ⚠️ 分片数超上限，放大分片: ${_formatBytes(chunkSize)}/片，共$chunkCount片');
    }
    _chunks.clear();
    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? totalSize - 1 : start + chunkSize - 1;
      _chunks.add(_ChunkTask(
        index: i,
        startByte: start,
        endByte: end,
        tempPath: '${filePath}.part_$i.tmp',
      ));
    }

    debugPrint(
        '[DOWNLOAD-CORE]   分片计划 (${chunkCount}片 × ${_formatBytes(chunkSize)}，并发$concurrency):');
    for (final c in _chunks) {
      debugPrint(
          '[DOWNLOAD-CORE]     分片${c.index}: ${_formatBytes(c.startByte)}-${_formatBytes(c.endByte)} (${_formatBytes(c.totalBytes)})');
    }

    _startProgressTimer(totalSize);

    // 并发窗口限流：最多 concurrency 个分片并行。
    // 单分片失败只记录错误、不取消队友（保留其余已完成分片供断点续传）。
    final errors = <Object>[];
    var next = 0;
    Future<void> worker() async {
      while (_status == DownloadStatus.downloading) {
        final idx = next++;
        if (idx >= _chunks.length) return;
        try {
          await _downloadChunk(dio, _chunks[idx]);
        } catch (e) {
          if (e is DioException && e.type == DioExceptionType.cancel) return;
          errors.add(e);
          // ★ DL-DISK-GUARD：磁盘满/权限类致命错误不再领新分片 —— 旧实现会
          // 继续把剩下十几个分片挨个试一遍，每个都白拉一段 Range 再失败。
          if (e is _FatalWriteException) return;
        }
      }
    }

    final workerCount = concurrency.clamp(1, _chunks.length).toInt();
    await Future.wait(
      List.generate(workerCount, (_) => worker()),
      eagerError: false,
    );

    _stopProgressTimer();

    if (errors.isNotEmpty) throw errors.first;

    if (_status != DownloadStatus.downloading) return;

    debugPrint('[DOWNLOAD-CORE]   所有分片下载完成，开始合并...');

    _savedPath = filePath;
    await _mergeChunks(filePath, totalSize);
  }

  /// 小分片探测当前实际吞吐，用于分片下载分档。
  ///
  /// 只读 4MB 即结束（读够即 break），避免拖慢开始下载。
  /// 探测失败/超时不阻塞任务，回落最稳的低档（并发最小、失败面最小）。
  Future<_ProbeOutcome> _probeTier(Dio dio) async {
    final sw = Stopwatch()..start();
    var got = 0;
    int? totalFromContentRange;
    try {
      final resp = await dio.get<ResponseBody>(
        _currentUrl,
        options: Options(
          headers: {'Range': 'bytes=0-${_probeBytes - 1}'},
          responseType: ResponseType.stream,
        ),
      ).timeout(_probeTimeout);

      // ★ 2026-09-26 稳定性批C5：探测响应顺便校准总长 ——
      // `Content-Range: bytes 0-4194303/2147483648` 的末段即文件真实总长。
      // HEAD 的 Content-Length 对部分网盘不可信，分片计划以此为准。
      final cr = resp.headers.value('content-range');
      if (cr != null) {
        final m = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(cr);
        if (m != null) {
          totalFromContentRange = int.tryParse(m.group(1)!);
        }
      }

      await for (final data in resp.data!.stream) {
        if (_status != DownloadStatus.downloading) break;
        got += data.length;
        if (got >= _probeBytes) break;
        if (sw.elapsedMilliseconds > _probeBudget.inMilliseconds) break;
      }
    } catch (_) {
      debugPrint('[DOWNLOAD-CORE]   ⚠️ 吞吐探测失败，回落低档');
      return const _ProbeOutcome(_DownloadTier.low, null);
    }

    sw.stop();
    final bps = sw.elapsedMilliseconds <= 0
        ? 0
        : got * 1000.0 / sw.elapsedMilliseconds;
    debugPrint(
        '[DOWNLOAD-CORE]   📶 探测吞吐: ${_formatSpeed(bps.toInt())} ($got B / ${sw.elapsedMilliseconds}ms)');
    if (bps >= _tierHighBps) {
      return _ProbeOutcome(_DownloadTier.high, totalFromContentRange);
    }
    if (bps >= _tierMidBps) {
      return _ProbeOutcome(_DownloadTier.mid, totalFromContentRange);
    }
    return _ProbeOutcome(_DownloadTier.low, totalFromContentRange);
  }

  /// ★ 2026-09-26 批D：自动档档位记忆。24h 内命中免重复探测（省 4MB 流量与等待）。
  /// 命中后总长校准走 1 字节 Range 请求（[_calibrateTotalViaRange]），校准能力不丢。
  Future<_DownloadTier?> _loadCachedTier() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_kTierCacheKey);
      final at = prefs.getInt(_kTierCacheAtKey);
      if (name == null || at == null) return null;
      if (DateTime.now().millisecondsSinceEpoch - at >
          _tierCacheTtl.inMilliseconds) {
        return null;
      }
      for (final t in _DownloadTier.values) {
        if (t.name == name) return t;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveTierCache(_DownloadTier tier) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTierCacheKey, tier.name);
      await prefs.setInt(
          _kTierCacheAtKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // 缓存写失败不影响主流程
    }
  }

  /// ★ 2026-09-26 批D：1 字节 Range 请求校准总长（C5 校准的非探测版本）。
  ///
  /// 轻量/全速档与档位记忆命中时跳过了 4MB 探测，用 `Range: bytes=0-0`
  /// 的 `Content-Range` 末段拿真实总长，几乎零成本；失败返回 null 不影响主流程
  /// （此时沿用 HEAD 的 Content-Length，另有完成时 size 容差校验兜底）。
  Future<int?> _calibrateTotalViaRange(Dio dio) async {
    try {
      final resp = await dio.get<ResponseBody>(
        _currentUrl,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
        ),
      ).timeout(const Duration(seconds: 10));
      int? total;
      final cr = resp.headers.value('content-range');
      if (cr != null) {
        final m = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(cr);
        if (m != null) total = int.tryParse(m.group(1)!);
      }
      // 消费流，避免连接泄漏（1 字节响应立即结束）
      try {
        await for (final _ in resp.data!.stream) {
          break;
        }
      } catch (_) {}
      return (total != null && total > 0) ? total : null;
    } catch (_) {
      return null;
    }
  }

  /// 下载单个分片。
  ///
  /// ★ P0-1 断点续传：重试时**保留**已落盘的临时文件，以已收字节为起点继续请求
  ///   Range。旧实现每次重试先 delete 再请求完整区间，GB 级分片一旦中途抖动就
  ///   丢弃全部进度，重试 3 次几乎必然失败。
  /// ★ P0-2 字节校验：流正常结束也必须校验落盘字节数等于分片大小才标记完成。
  ///   旧实现只要流结束就 completed=true，服务器提前断流并不抛异常 → 合并后
  ///   大小不符，整次安装失败且流量全部浪费。
  /// ★ P0-4 直链刷新：云盘签名直链会过期，遇 401/403/404/416 重新解析再重试。
  Future<void> _downloadChunk(Dio dio, _ChunkTask chunk) async {
    const maxRetries = 15;
    // ★ P2 应用层无数据看门狗：Dio 的 receiveTimeout **只**作用于连接/响应头阶段，
    // 不约束 ResponseBody.stream 的 body 逐块读取。弱网连接半开时 body 被卡住，
    // `await for` 会永久挂起（实测分片 .tmp 大小完全停住、进度长时间不动）。
    // 由独立 Timer 监测「无新字节」时长，超时主动 cancel 该分片 → 转为续传重试。
    const noDataTimeout = Duration(seconds: 45);
    var lastDataTime = DateTime.now();
    final watchdogHit = <_ChunkTask>{};
    final watchdog =
        Timer.periodic(const Duration(seconds: 5), (_) {
          if (_status == DownloadStatus.downloading &&
              DateTime.now().difference(lastDataTime) > noDataTimeout) {
            watchdogHit.add(chunk);
            debugPrint(
                '[DOWNLOAD-CORE]   ⏹ 分片${chunk.index} 长时间无数据(>45s)，看门狗中断，转为续传');
            // ★ 2026-09-26 稳定性批B2：把自愈动作透出到 UI —— 否则「自动恢复」
            // 在用户眼里与「卡死」不可区分（速度数值冻结、进度停滞）。
            _emitWatchdogNotice(chunk);
            chunk.cancelToken?.cancel();
          }
        });
    try {
      for (int attempt = 0; attempt <= maxRetries; attempt++) {
        try {
          chunk.cancelToken = CancelToken();
          lastDataTime = DateTime.now();

          // 续传起点：已落盘字节数（跨重试复用；同名临时文件也支持跨任务续传）
          final tmp = File(chunk.tempPath);
          int existing = 0;
          if (await tmp.exists()) {
            existing = await tmp.length();
            if (existing > chunk.totalBytes) {
              await tmp.delete();
              existing = 0;
            }
          }
          chunk.receivedBytes = existing;
          if (existing >= chunk.totalBytes) {
            chunk.completed = true;
            return;
          }
          if (existing > 0) {
            debugPrint(
                '[DOWNLOAD-CORE]   ↻ 分片${chunk.index} 续传自 ${_formatBytes(existing)}/${_formatBytes(chunk.totalBytes)}');
          }

          final rangeStart = chunk.startByte + existing;
          final remaining = chunk.totalBytes - existing;

          final response = await dio.get<ResponseBody>(
            _currentUrl,
            options: Options(
              headers: {
                'Range': 'bytes=$rangeStart-${chunk.endByte}',
              },
              responseType: ResponseType.stream,
            ),
            cancelToken: chunk.cancelToken,
          );

          // 服务器忽略 Range 返回全量时（常见 200 + Content-Length=整文件大小），
          // 若直接写入会把整个文件灌进单个分片，必须判失败。
          final respLength =
              int.tryParse(response.headers.value('content-length') ?? '');
          if (response.statusCode != 206 && respLength != remaining) {
            throw Exception(
                '服务器未按分片范围响应 (HTTP ${response.statusCode}, 期望$remaining字节, 实际${respLength ?? "未知"})');
          }

          // append 模式追加写入，实现续传。
          // ★ DL-DISK-GUARD：改直写 RandomAccessFile —— `IOSink.add` 的写错误
          // 会经 `_FileStreamConsumer.addStream` 异步链路逃逸到 zone，被全局
          // onError（`app_log_helper.dart:143`，return true）吞掉：磁盘写满时
          // 循环照旧读网络、进度照旧涨，磁盘上 0 字节。实测现场：磁盘 7.0GiB /
          // 界面 53.4% / 四个分片冻结在同一毫秒、6 分钟零增长。
          final raf = await _openFileForWrite(tmp);
          try {
            await for (final data in response.data!.stream) {
              if (_status != DownloadStatus.downloading) break;
              lastDataTime = DateTime.now(); // 有数据到达即刷新看门狗计时
              _scopeFailStreak = 0;
              _badResponseStreak = 0;
              // ★ 2026-09-26 批D：全局限速令牌桶（0=不限速直通），所有分片共享一个桶
              await DownloadThrottle.acquire(data.length);
              await _writeToFile(raf, data, chunk.tempPath);
              chunk.receivedBytes += data.length;
            }
            await _flushFile(raf, chunk.tempPath);
          } finally {
            await _closeFile(raf);
          }

          if (_status != DownloadStatus.downloading) return;

          // ★ P0-2：以实际落盘字节数为准校验，不足则进入续传重试
          final got = await tmp.length();
          if (got == chunk.totalBytes) {
            chunk.completed = true;
            return;
          }
          throw Exception(
              '分片${chunk.index}数据不完整: 已收${_formatBytes(got)}/${_formatBytes(chunk.totalBytes)}');
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            // 区分「应用看门狗取消」与「用户取消」：
            // 看门狗取消 → 转普通失败，退避后进入下一轮（续传重试）；
            // 用户取消 → 原样透传，停止整个任务。
            if (watchdogHit.contains(chunk)) {
              watchdogHit.remove(chunk);
              if (attempt >= maxRetries) rethrow;
              await _backoff(attempt);
              if (_status != DownloadStatus.downloading) return;
            } else {
              rethrow;
            }
          } else {
            if (attempt >= maxRetries) rethrow;
            if (e.type == DioExceptionType.badResponse) {
              await _refreshUrlIfNeeded(e);
              // ★ 2026-09-26 稳定性批C7：4xx 不属于网络抖动 —— 刷新直链已给过
              //   一次新 URL 机会，仍失败说明是权限/资源层面问题（403 无权限、
              //   416 范围越界等），烧满 15 次重试只会让任务挂起更久。
              final code = e.response?.statusCode ?? 0;
              if (code >= 400 && code < 500) {
                _badResponseStreak++;
                if (_badResponseStreak >= 2) rethrow;
              } else {
                _badResponseStreak = 0;
              }
            }
            await _backoff(attempt);
            if (_status != DownloadStatus.downloading) return;
          }
        } catch (e) {
          // ★ DL-DISK-GUARD：写盘类致命错误（磁盘满 / 无权限 / 写盘挂死）不重试
          // 也不退避 —— 重试只会再拉一遍几十 MB 的 Range 再写失败一次。
          if (e is _FatalWriteException) rethrow;
          if (attempt >= maxRetries) rethrow;
          // ★ 2026-09-26 稳定性批B3：「服务器未按分片范围响应」「数据不完整」
          // 这类普通异常往往同样是签名直链过期/失效的表现（服务器对过期签名
          // 返回 200 全量或错误页），旧逻辑不换 URL，会烧光全部重试。
          // 连续 2 次普通异常即强制重解析直链一次。
          _scopeFailStreak++;
          if (_scopeFailStreak >= 2) {
            _scopeFailStreak = 0;
            await _refreshUrl(reason: '分片连续普通异常');
          }
          await _backoff(attempt);
          if (_status != DownloadStatus.downloading) return;
        }
      }
    } finally {
      watchdog.cancel();
    }
  }

  /// 重试退避：1s → 2s → 4s → 8s → 15s（上限）。
  Future<void> _backoff(int attempt) async {
    final ms = min(1000 * pow(2, attempt), 15000).toInt();
    debugPrint('[DOWNLOAD-CORE]   ⏳ ${ms}ms 后退避重试（第 ${attempt + 1} 次）');
    await Future.delayed(Duration(milliseconds: ms));
  }

  /// HEAD 带退避重试（P0-3）。旧实现单次 HEAD 失败即整次安装失败。
  Future<Response<dynamic>> _headWithRetry(Dio dio) async {
    const maxAttempts = 4;
    Object? lastError;
    for (int i = 0; i < maxAttempts; i++) {
      try {
        return await dio.head(_currentUrl);
      } catch (e) {
        lastError = e;
        if (i < maxAttempts - 1) {
          if (e is DioException && e.type == DioExceptionType.badResponse) {
            await _refreshUrlIfNeeded(e);
          }
          final ms = 500 * (i + 1);
          debugPrint('[DOWNLOAD-CORE]   ⏳ HEAD 失败，$ms ms 后重试（${i + 1}/$maxAttempts）');
          await Future.delayed(Duration(milliseconds: ms));
        }
      }
    }
    throw lastError!;
  }

  /// ★ P0-4：云盘签名直链会过期。提供 urlResolver 时，遇 401/403/404/416
  /// 重新解析直链，避免重试永远复用同一个已失效 URL。
  Future<void> _refreshUrlIfNeeded(DioException e) async {
    final code = e.response?.statusCode;
    if (code != 401 && code != 403 && code != 404 && code != 416) return;
    await _refreshUrl(reason: 'HTTP $code');
  }

  /// 重解析直链（2026-09-26 稳定性批B3：自 [_refreshUrlIfNeeded] 拆出，
  /// 供「连续普通异常」等无状态码场景复用）。
  Future<void> _refreshUrl({String? reason}) async {
    final resolver = _urlResolver;
    if (resolver == null) return;
    try {
      final fresh = await resolver();
      if (fresh != null && fresh.isNotEmpty && fresh != _currentUrl) {
        _currentUrl = fresh;
        debugPrint('[DOWNLOAD-CORE] 🔄 直链已刷新（${reason ?? "手动"}），重新尝试');
      }
    } catch (err) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 直链刷新失败: $err');
    }
  }

  /// ★ 2026-09-26 稳定性批B2：看门狗命中时向 UI 透出一条进度事件，
  /// 携带说明文案与当前已保住字节，避免「自动恢复」被误读为卡死。
  void _emitWatchdogNotice(_ChunkTask? chunk) {
    final p = _progress;
    final saved = _resumableBytes();
    _emitProgress(DownloadProgress(
      percent: p?.percent ?? 0,
      downloadedBytes: p?.downloadedBytes ?? 0,
      totalBytes: p?.totalBytes ?? 0,
      speed: '0 B/s',
      statusMessage: chunk == null
          ? '网络停滞，正在自动续传（已保住 ${_formatBytes(saved)}）'
          : '网络停滞，正在自动续传「分片${chunk.index}」（已保住 ${_formatBytes(saved)}）',
    ));
  }

  Future<void> _mergeChunks(String finalPath, int expectedSize) async {
    final outFile = File(finalPath);
    if (await outFile.exists()) {
      await outFile.delete();
    }

    try {
      debugPrint('[DOWNLOAD-CORE] 开始 Isolate 合并（不阻塞 UI）...');

      // 使用 Isolate 执行合并，避免同步 I/O 阻塞主 Isolate
      final chunkPaths = _chunks.map((c) => c.tempPath).toList();
      final mergeResult = await compute(
        _mergeChunksInIsolate,
        _MergeParams(
          chunkPaths: chunkPaths,
          finalPath: finalPath,
          expectedSize: expectedSize,
          bufferSize: _mergeBufferSize,
        ),
      );

      if (!mergeResult.success) {
        throw Exception(mergeResult.error);
      }

      // 清理临时分片文件
      for (final c in _chunks) {
        final tmp = File(c.tempPath);
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      }

      // 发送合并完成进度
      _emitProgress(DownloadProgress(
        percent: 99.9,
        downloadedBytes: expectedSize,
        totalBytes: expectedSize,
        speed: '合并完成',
      ));

      final finalSize = await outFile.length();
      debugPrint('[DOWNLOAD-CORE] ✅ 合并完成 | 大小: ${_formatBytes(finalSize)}');
    } catch (e) {
      if (await outFile.exists()) {
        try {
          await outFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  void _startProgressTimer(int totalSize) {
    _progressTimer?.cancel();
    // 性能优化：从 500ms 降低到 1000ms，减少 50% 的 UI 重建
    // 在 20MB/s 下，1秒间隔足以提供流畅的进度反馈
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) {
        if (_status != DownloadStatus.downloading) return;

        // 同时计算分片下载和单流下载的已接收字节数
        int totalReceived = _singleStreamReceived;
        bool allDone = _chunks.isEmpty ? false : true;
        for (final c in _chunks) {
          totalReceived += c.receivedBytes;
          if (!c.completed) allDone = false;
        }
        // 单流下载模式下，allDone 由 totalReceived >= totalSize 判定
        if (_chunks.isEmpty && totalReceived >= totalSize) {
          allDone = true;
        }

        // ★ DL-DISK-GUARD：每 5 个 tick（5s）巡检一次缓存盘剩余空间。
        // 这里的 `totalReceived` 已经是「真正写进磁盘的字节」（写盘改为
        // await RandomAccessFile.writeFrom），所以「还差多少」是准的。
        _diskTick++;
        if (_diskTick % _diskCheckEveryTicks == 0) {
          _monitorDiskSpace(totalReceived, totalSize);
        }

        final now = DateTime.now();
        final timeDelta = now.difference(_lastSpeedTime ?? now).inMilliseconds;
        final byteDelta = totalReceived - _lastReceivedBytes;

        int instantBps = 0;
        if (timeDelta >= 500 && byteDelta >= 0) {
          instantBps = (byteDelta / timeDelta * 1000).toInt();
          _pushSpeedSample(instantBps);
          _lastReceivedBytes = totalReceived;
          _lastSpeedTime = now;
        } else if (_speedWindow.isNotEmpty) {
          instantBps = (_speedWindowSum ~/ _speedWindow.length);
        }

        final smoothBps = _getSmoothedSpeed();
        final speedStr = _formatSpeed(smoothBps);

        final rawPct = (totalReceived / totalSize * 100).clamp(0.0, 100.0);
        final pct = (rawPct / 100.0 * _downloadMaxPercent)
            .clamp(0.0, _downloadMaxPercent);

        // 性能优化：仅当百分比变化 >=1% 或下载完成时才发射进度
        // 避免微小变化触发不必要的 UI 重建
        // ★ 2026-09-26 稳定性批B1：**速度/字节的发射与百分比门控解耦**。
        // >1GB 时 1% = 10MB+，弱网下十几秒甚至几分钟才跨一次门控 —— 期间 UI
        // 一直显示最后一次事件的旧速度，用户看到的正是「速度数值不再变化」。
        // 现在即便百分比没变，也每 2s 强制发射一次（1s tick，最多补发 1 次）。
        final lastEmitPct = _progress?.percent ?? -1.0;
        final pctChanged = (pct - lastEmitPct).abs() >= 1.0;
        final lastEmit = _lastProgressEmitTime;
        final emitDue = lastEmit == null ||
            now.difference(lastEmit).inMilliseconds >= 2000;

        if (pctChanged || emitDue || pct >= 99.9 || allDone) {
          _lastProgressEmitTime = now;
          _emitProgress(DownloadProgress(
            percent: pct,
            downloadedBytes: totalReceived,
            totalBytes: totalSize,
            speed: speedStr,
          ));
        }
      },
    );
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _pushSpeedSample(int bps) {
    if (_speedWindow.length >= _speedWindowSize) {
      _speedWindowSum -= _speedWindow.removeAt(0);
    }
    _speedWindow.add(bps);
    _speedWindowSum += bps;
  }

  int _getSmoothedSpeed() {
    if (_speedWindow.isEmpty) return 0;
    return (_speedWindowSum ~/ _speedWindow.length).clamp(0, 104857600);
  }

  void cancel() {
    if (_status != DownloadStatus.downloading) {
      debugPrint('[DOWNLOAD-CORE] ⚠️ 当前无下载任务，无法取消');
      return;
    }

    debugPrint('[DOWNLOAD-CORE] 取消下载｜终止所有分片请求...');
    _stopProgressTimer();

    _handleCancel();
  }

  void _handleCancel() {
    // 防止重复处理：如果已经处于 cancelled 状态，直接返回
    if (_status == DownloadStatus.cancelled) return;

    if (_activeTaskCount > 0) _activeTaskCount--;
    _emitStatus(DownloadStatus.cancelled);

    _emitProgress(const DownloadProgress(
      percent: 0,
      downloadedBytes: 0,
      totalBytes: 0,
      speed: '0 B/s',
    ));

    for (final c in _chunks) {
      c.cancelToken?.cancel('用户主动取消');
    }

    // ★ DL-CACHE-CLEANUP：带重试删除，避免句柄未释放导致分片残留在盘上。
    unawaited(_cleanupTempFilesWithRetry());
  }

  /// 仅清理**本任务**的分片临时文件。
  ///
  /// ★ P1：旧实现递归扫描整个下载目录删除所有 `.part_*`/`.chunk_*`，
  /// 而 GlobalTaskManager 与 GlobalInstallCenter 可并存运行，会误删其他
  /// 正在下载任务的分片。
  Future<void> _cleanupTempFiles() async {
    debugPrint('[DOWNLOAD-CORE] 清理本任务临时文件...');

    int deletedCount = 0;
    for (final c in _chunks) {
      try {
        final f = File(c.tempPath);
        if (await f.exists()) {
          await f.delete();
          deletedCount++;
        }
      } catch (_) {}
    }
    if (deletedCount > 0) {
      debugPrint('[DOWNLOAD-CORE] ✅ 已删除 $deletedCount 个临时文件');
    }
  }

  /// ★ DL-CACHE-CLEANUP（2026-11-03）：带重试地清干净本任务的分片 + 空缓存目录。
  ///
  /// Windows 上文件句柄释放比状态切换晚一步：一次性删往往只删掉一部分，几 GB
  /// 的 `.part_*.tmp` 会永久留在用户硬盘（实测取消后残留）。这里按「删 → 复查
  /// → 退避重试」最多四轮；最后无论删没删净，都尝试把变空的缓存目录去掉。
  Future<void> _cleanupTempFilesWithRetry() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      await _cleanupTempFiles();
      var remain = 0;
      for (final c in _chunks) {
        try {
          if (File(c.tempPath).existsSync()) remain++;
        } catch (_) {
          // 查不到就当已清掉，避免无意义地卡在重试上
        }
      }
      if (remain == 0) break;
      if (attempt < 3) {
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    await DownloadCacheDir.cleanupIfEmpty(_cacheDir);
  }

  /// 已成功落盘的可续传字节数（用于失败时提示与诊断）。
  int _resumableBytes() {
    var total = 0;
    for (final c in _chunks) {
      try {
        final f = File(c.tempPath);
        if (f.existsSync()) total += f.lengthSync();
      } catch (_) {}
    }
    // ★ 2026-09-26 稳定性批B4：单流路径无分片，续传量 = 半成品文件本身。
    if (_chunks.isEmpty && _singleStreamFilePath != null) {
      try {
        final f = File(_singleStreamFilePath!);
        if (f.existsSync()) total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  /// 供上层（安装中心）在错误提示中附加「已保住 X，重试从断点继续」。
  int get resumableBytes => _resumableBytes();

  void _handleError(String rawMsg) {
    // 防止覆盖已设置的 cancelled / completed / failed 状态。
    // ★ DL-DISK-GUARD：failed 也要拦 —— 磁盘巡检先报错，主流程随后还会走到
    // size 校验再报一次，双报会把 `_activeTaskCount` 多减一次、并用更差的
    // 文案覆盖掉「还差多少空间」这条可操作信息。
    if (_status == DownloadStatus.cancelled ||
        _status == DownloadStatus.completed ||
        _status == DownloadStatus.failed) {
      return;
    }

    if (_activeTaskCount > 0) _activeTaskCount--;
    // 已是可读业务文案（磁盘满 / 权限）直接透传：[_standardizeError] 会把它们
    // 拍平成一模一样的一句「磁盘空间不足」，丢掉「哪个盘、还剩多少、还差多少」。
    final cnMsg =
        (rawMsg.startsWith('磁盘空间不足') || rawMsg.startsWith('文件写入失败'))
            ? rawMsg
            : _standardizeError(rawMsg);
    _emitStatus(DownloadStatus.failed);
    // ★ P0-1：失败时刻意**保留**分片临时文件，用户重试时自动续传，不丢进度。
    // ★ 2026-09-26 稳定性批B4：把「已保住多少、重试从断点继续」直接写进错误
    // 消息 —— 旧实现只打 debugPrint，用户看到的失败提示完全没提进度没丢，
    // 这是不稳定感的放大器。仅清理已合并的半成品文件（可能不完整）。
    final resumable = _resumableBytes();
    // ★ DL-DISK-GUARD：磁盘满时「重试将从断点继续」是误导 —— 不腾空间重试
    // 必然再失败，所以这类错误只报事实。
    final diskFull = cnMsg.contains('磁盘空间不足');
    // ★ DL-CACHE-CLEANUP（2026-11-03）：磁盘满 / 写入被拒属于**不可续传**的
    // 失败 —— 不腾空间、不换盘，重试必然再失败，留着几个 GB 分片只是白占用户
    // 硬盘。这两类错误直接清干净并把空间立刻还回去；网络类失败仍保留以续传。
    final nonResumable = diskFull || cnMsg.contains('文件写入失败');
    _emitError((resumable > 0 && !nonResumable)
        ? '$cnMsg（已保住 ${_formatBytes(resumable)}，重试将从断点继续）'
        : cnMsg);
    if (nonResumable && resumable > 0) {
      debugPrint('[DOWNLOAD-CORE] 🧹 该失败不可续传，清理已下的 '
          '${_formatBytes(resumable)} 分片，立刻释放磁盘');
      unawaited(_cleanupTempFilesWithRetry());
    } else if (resumable > 0) {
      debugPrint(
          '[DOWNLOAD-CORE] 💾 保留已下载 ${_formatBytes(resumable)}，重试时自动续传');
    }
    if (_savedPath != null) {
      try {
        final f = File(_savedPath!);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
      _savedPath = null;
    }
  }

  Future<void> _triggerExtraction(String filePath) async {
    debugPrint('[DOWNLOAD-CORE] 📦 下载完成，开始解压流程...');

    try {
      _extractManager.start(
        archivePath: filePath,
        gameTitle: _gameTitle ?? _currentGameId,
        gameDescription: _gameDescription,
        gameCoverUrl: _gameCoverUrl,
        gameBannerUrl: _gameBannerUrl,
        gameTags: _gameTags,
        gameDeveloper: _gameDeveloper,
        gameSubtitle: _gameSubtitle,
        customGameLocation: _customGameLocation,
        screenshotUrls: _screenshotUrls,
        cloudGameId: _cloudGameId,
      );

      while (_extractManager.status == ExtractStatus.extracting) {
        await Future.delayed(const Duration(milliseconds: 200));
      }

      if (_extractManager.status == ExtractStatus.failed) {
        debugPrint('[DOWNLOAD-CORE] ❌ 解压失败: ${_extractManager.errorMessage}');
      } else {
        debugPrint('[DOWNLOAD-CORE] ✅ 解压流程已结束');
      }
    } catch (e) {
      debugPrint('[DOWNLOAD-CORE] ❌ 解压触发异常: $e');
    }

    if (!_extractionCompleter!.isCompleted) {
      _extractionCompleter!.complete();
    }
  }

  Future<void> waitForExtraction() async {
    return _extractionCompleter?.future ?? Future.value();
  }

  ExtractManager get extractManager => _extractManager;

  void reset() {
    _status = DownloadStatus.idle;
    _progress = null;
    _savedPath = null;
    _errorMessage = null;
    _currentGameId = '';
    _lastReceivedBytes = 0;
    _lastSpeedTime = null;
    _lastProgressEmitTime = null;
    _lastLogTime = null;
    _lastLoggedPercent = -1;
    _speedWindow.clear();
    _speedWindowSum = 0;
    _chunks.clear();
    _extractionCompleter = null;
    _cacheDir = null;
    _fatalReported = false;
    _diskTick = 0;
    _diskCheckInFlight = false;
    _stopProgressTimer();
    debugPrint('[DOWNLOAD-CORE] 状态已重置为空闲');
  }

  String _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '网络连接超时';
      case DioExceptionType.sendTimeout:
        return '请求发送超时';
      case DioExceptionType.receiveTimeout:
        return '服务器响应超时';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code >= 500) return '服务器内部错误 ($code)';
        if (code == 404) return '下载链接已失效 (404)';
        if (code == 403) return '没有下载权限 (403)';
        if (code == 416) return '服务器不支持分片下载 (Range请求失败)';
        return '请求失败 (HTTP $code)';
      case DioExceptionType.connectionError:
        return '无法连接到服务器';
      default:
        return e.message ?? '未知网络错误';
    }
  }

  String _standardizeError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('permission') || lower.contains('denied')) {
      return '文件写入失败：权限不足';
    }
    // ★ DL-DISK-GUARD：Windows 中文系统的 OS 消息是「磁盘空间不足。」，
    // 旧实现只匹配英文 `no space`/`disk` ⇒ errno 112 连文案都映射不上。
    if (lower.contains('no space') ||
        lower.contains('disk') ||
        lower.contains('磁盘空间不足') ||
        lower.contains('errno = 112') ||
        lower.contains('errno 112') ||
        lower.contains('112') && lower.contains('writefrom')) {
      return '磁盘空间不足';
    }
    if (lower.contains('socket') && lower.contains('refused')) {
      return '连接被拒绝，请检查OpenList服务是否运行';
    }
    if (lower.contains('connection closed') ||
        lower.contains('reset by peer') ||
        lower.contains('httpexception')) {
      return '下载过程中连接中断，网络不稳定';
    }
    if (lower.contains('大小不符') || lower.contains('临时文件丢失')) {
      return '分片数据不完整，下载可能被中断，请重新下载';
    }
    return raw;
  }

  String _extractFileName(Response headResponse, String url, String? fallback) {
    final uri = Uri.tryParse(url);
    String name = '';
    if (uri != null && uri.pathSegments.isNotEmpty) {
      name = uri.pathSegments.last;
    }
    if (name.isEmpty || !name.contains('.')) {
      final parts = url.split('/');
      for (var i = parts.length - 1; i >= 0; i--) {
        final seg = parts[i].split('?').first;
        if (seg.contains('.') && seg.isNotEmpty) {
          name = seg;
          break;
        }
      }
    }
    if (name.isEmpty || !name.contains('.')) {
      if (fallback != null && fallback.isNotEmpty) {
        name = fallback;
      } else {
        name = 'download.bin';
      }
    }

    final safeName = _sanitizeFileName(name);
    debugPrint('[DOWNLOAD-CORE]   提取文件名: $safeName');
    return safeName;
  }

  /// ★ 2026-09-26 安装审计 P2-3：下载文件名清洗。
  ///
  /// 文件名有两个来源：URL 末段（`Uri.pathSegments.last` 会对 `%2F` 解码，
  /// 理论上可携带路径分隔符）与 `task.title` 兜底（云端数据，非本地可控）。
  /// 结果直接拼 `'$saveDir/$name'` 落盘 —— 不清洗存在路径穿越/写坏目录的风险。
  String _sanitizeFileName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 保留扩展名端，限制长度（Windows MAX_PATH 压力）
    if (n.length > 120) {
      final dot = n.lastIndexOf('.');
      final ext = (dot > 0 && dot >= n.length - 12) ? n.substring(dot) : '';
      n = n.substring(0, 120 - ext.length) + ext;
    }
    if (n.isEmpty || n == '.' || n == '..') n = 'download.bin';
    return n;
  }

  String _formatSpeed(int bytes) {
    if (bytes < 1024) return '$bytes B/s';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytes / 1048576).toStringAsFixed(2)} MB/s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
}
