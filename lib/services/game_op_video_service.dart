/// BPM 背景 OP 视频「自动抓取」—— 宿主接线层（Flutter 侧）。
///
/// 抓取逻辑本身在 [OpVideoCore]（纯 Dart，可用 `dart.exe` 探针验证）；
/// 这里只负责**什么时候抓、抓到之后写到哪、失败怎么退避**。
///
/// ## 产品语义（用户 2026-10-17 拍板：默认关 + 弹窗确认）
/// - 设置页「大屏模式 → 背景 OP 视频 → 自动抓取」**默认关**；
/// - 开启后：在大屏模式里真正选中过的游戏，若**池里一条视频都没有**，
///   就后台**探测**一次（只查列表不下载）；探到素材就**弹窗询问用户**拉不拉，
///   用户确认后才真正下载 —— 首轮的「静默后台抓」被用户否决了：
///   开关开了却毫无反馈，用户不知道功能有没有生效；
/// - 探不到素材 / 网络失败 → **什么都不显示**（用户明确：没有素材不用提示）；
/// - 只在用户实际浏览到的游戏上花流量，不做全库预抓。
///
/// ## 🔴 三条硬约束
/// 1. **不抢用户选中**：[BpmBackdropMedia.addVideos] 以 `autoSelect: false`
///    调用 —— 只在「当前没有选中视频」时才接管选中位，用户手放的视频永不被换；
/// 2. **池里已有视频直接跳过**（不管谁放的）—— 用户已经挑过素材，不再花 40MB；
/// 3. **串行队列 + 会话上限**：候选再多也只一条一条抓（同时翻页不会并发打满），
///    单次启动最多抓 [maxPerSession] 条，防止浏览百来个游戏把磁盘塞满。
///
/// ## 版权
/// 产物只落在**本机游戏元数据目录**（`metaDataDir/op_video_<movieId>.mp4`），
/// 不进云端、不上传 PB、不参与任何分发。与 ADR-017 同一条红线。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../big_picture/services/bpm_backdrop_media.dart';
import '../core/path_helper.dart';
import 'bpm_op_video_preference.dart';
import 'game_op_video_core.dart';
import 'game_title_logo_service.dart';
import 'local_game_registry.dart';
import 'network_proxy_policy.dart';

/// 自动抓取的统计（设置页展示用）。
@immutable
class OpVideoCacheStats {
  const OpVideoCacheStats({required this.files, required this.bytes});

  /// 已自动抓取的视频条数。
  final int files;

  /// 合计占用字节数。
  final int bytes;

  double get megabytes => bytes / 1024 / 1024;

  static const OpVideoCacheStats empty =
      OpVideoCacheStats(files: 0, bytes: 0);
}

/// 负缓存条目（记住「抓过但没抓到」，避免每次选中都去撞同一个必然失败的条目）。
@immutable
class _Attempt {
  const _Attempt({required this.at, required this.status});

  /// 毫秒时间戳。
  final int at;

  /// 当时的失败状态名（`noUsableMovie` / `networkError` …）。
  final String status;

  /// 该状态对应的冷却时长。
  Duration get ttl {
    switch (status) {
      // 网络抖动 / 下载失败 → 一天后再试
      case 'downloadFailed':
      case 'networkError':
        return const Duration(days: 1);
      // 用户亲口说过「不拉取」→ 7 天内别再烦他（比素材类短，给他反悔窗口）
      case 'userDeclined':
        return const Duration(days: 7);
      // 库里没有可用素材 / 没有 Steam 条目 → 数据几乎不会变，一个月后再看
      // （含旧版本写下的 `noOpening`：语义已并入 noUsableMovie，同样 30 天）
      default:
        return const Duration(days: 30);
    }
  }

  bool isFresh(int nowMs) => nowMs - at < ttl.inMilliseconds;
}

class GameOpVideoService {
  GameOpVideoService._();

  static final GameOpVideoService instance = GameOpVideoService._();

  /// 文件名前缀（与引擎共用同一个常量，避免两处写歪）。
  static const String fileNamePrefix = OpVideoCore.fileNamePrefix;

  /// 单次启动最多抓几条（串行执行，实际很难跑满）。
  static const int maxPerSession = 5;

  /// 分片并发（Steam CDN 实测值）。
  static const int _chunkConcurrency = 3;

  /// 抓取成功 / 进度变化的回调（BPM shell 用来重新起播）。
  ///
  /// 传参是该游戏的 `metaDataDir`。宿主必须在 dispose 里置 null。
  void Function(String metaDataDir)? onStored;

  /// 探测到可拉取素材的回调（BPM shell 弹确认框用）。
  ///
  /// 只在「探到至少一条可用素材」时回调；宿主必须先校验该 `metaDataDir`
  /// 仍是当前舞台游戏再弹窗，用户点「拉取」后调 [confirmFetch]，
  /// 点「不拉取」（或直接关掉弹窗）后调 [decline]。dispose 里置 null。
  void Function(String metaDataDir, String title, List<OpCandidate> candidates)?
      onCandidates;

  /// 设置页状态行文本（空串 = 空闲）。供 `ValueListenableBuilder` 监听。
  final ValueNotifier<String> activity = ValueNotifier<String>('');

  final Set<String> _inFlight = <String>{};

  /// 本次启动内已经问过用户的游戏（无论答了什么）——同一款游戏只弹一次窗。
  final Set<String> _askedThisSession = <String>{};
  final Map<String, _Attempt> _attempts = <String, _Attempt>{};
  bool _cacheLoaded = false;
  Future<void> _saveQueue = Future<void>.value();
  Future<void> _queue = Future<void>.value();
  int _fetchedThisSession = 0;

  /// 连续「网络/商店 API 不可达」次数。达到 [maxConsecutiveNetworkErrors] 后
  /// 本次启动内不再尝试 —— 否则 Steam 商店被墙时，用户每换一个游戏都要
  /// 白等 12 秒连接超时，后台队列还会串起来堵住后续所有抓取。
  int _netFailStreak = 0;

  /// 熔断打开（本次启动内停止自动抓取）。
  bool _circuitOpen = false;

  static const int maxConsecutiveNetworkErrors = 2;

  /// 设置页用：本次启动已抓到的条数。
  int get fetchedThisSession => _fetchedThisSession;

  static String get _attemptFilePath =>
      '${PathHelper.dataDir}${Platform.pathSeparator}op_video_attempts.json';

  // ===========================================================================
  // 对外主入口
  // ===========================================================================

  /// 请求后台**探测**某游戏可拉取的背景视频（幂等、可重复触发、永不抛异常）。
  ///
  /// 素材按 OP > ED > PV > 其它相关条目分级（用户明确：视频素材不局限于 OP，
  /// 只要能介绍游戏内容都能当背景）。探到素材后经 [onCandidates] 交宿主弹窗，
  /// **不会直接下载** —— 静默下载是首轮设计，因「开了开关毫无反馈」被用户否决。
  ///
  /// 调用点：大屏模式换游戏（`_onStageGameChanged`）。开关关闭时**立即返回**，
  /// 因此默认配置下的行为与改动前完全一致。
  void requestAutoFetch({
    required String gameId,
    required String metaDataDir,
    required String title,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) {
    if (!BpmOpVideoPreference.instance.autoFetchEnabled) return;
    if (_circuitOpen) return;
    if (metaDataDir.isEmpty || title.trim().isEmpty) return;

    // 池里已有视频（用户手放的或以前抓的）→ 一律不问
    if (BpmBackdropMedia.readVideos(metaDataDir).isNotEmpty) return;

    // 同一款游戏本次启动只问一次
    final String key = gameId.isNotEmpty ? gameId : metaDataDir;
    if (_askedThisSession.contains(key)) return;
    if (_inFlight.contains(key)) return;
    _inFlight.add(key);

    _queue = _queue.then((_) async {
      try {
        await _loadCache();
        final int now = DateTime.now().millisecondsSinceEpoch;
        final _Attempt? last = _attempts[key];
        if (last != null && last.isFresh(now)) {
          debugPrint('[OP-VIDEO] ⏸️ 负缓存命中（${last.status}），跳过 $title');
          return;
        }
        await _runProbe(
          key: key,
          metaDataDir: metaDataDir,
          title: title,
          subtitle: subtitle,
          metadataSource: metadataSource,
          metadataSourceId: metadataSourceId,
        );
      } catch (e) {
        debugPrint('[OP-VIDEO] ⚠️ 自动探测异常（忽略）: $e');
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// 用户在确认框点了「拉取」：下载所选候选并入池（串行队列，不抛异常）。
  ///
  /// 只下用户确认的这一条 —— 弹窗里写的就是它，失败也不静默换别的。
  void confirmFetch({
    required String gameId,
    required String metaDataDir,
    required String title,
    required OpCandidate candidate,
  }) {
    if (metaDataDir.isEmpty) return;
    if (_fetchedThisSession >= maxPerSession) {
      activity.value = '本次启动已拉取 $maxPerSession 条，达到上限';
      return;
    }
    final String key = gameId.isNotEmpty ? gameId : metaDataDir;
    if (_inFlight.contains(key)) return;
    _inFlight.add(key);

    _queue = _queue.then((_) async {
      try {
        await _downloadAndStore(
          key: key,
          metaDataDir: metaDataDir,
          title: title,
          candidate: candidate,
        );
      } catch (e) {
        debugPrint('[OP-VIDEO] ⚠️ 拉取异常（忽略）: $e');
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// 用户点了「不拉取」（或直接关掉弹窗）：7 天内不再问这款游戏。
  void decline({required String gameId, required String metaDataDir}) {
    final String key = gameId.isNotEmpty ? gameId : metaDataDir;
    _askedThisSession.add(key);
    _recordFailure(key, 'userDeclined');
    debugPrint('[OP-VIDEO] 🙅 用户选择不拉取，7 天内不再询问');
  }

  /// 清掉所有「自动抓取」的产物（设置页按钮）。返回清理的条数。
  ///
  /// 🔴 只删 `op_video_*` 前缀的文件 —— 用户手放的视频一律不碰。
  Future<int> clearAllAutoFetched() async {
    await _loadCache();
    int removed = 0;
    for (final LibraryGame game in LocalGameRegistry.instance.allGames) {
      final String dir = game.metaDataDir;
      if (dir.isEmpty) continue;
      final List<BpmBackdropVideoAsset> pool = BpmBackdropMedia.readVideos(dir);
      for (final BpmBackdropVideoAsset a in pool) {
        if (!a.file.startsWith(fileNamePrefix)) continue;
        // 先摘清单（removeVideo 会把「正被选中」的选中位置空，停止自动播）
        await BpmBackdropMedia.removeVideo(dir, a.file);
        try {
          final File f = File('$dir${Platform.pathSeparator}${a.file}');
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('[OP-VIDEO] ⚠️ 删除失败（忽略）${a.file}: $e');
        }
        removed++;
      }
    }
    // 顺带清负缓存：用户清空后可能想立刻重抓
    _attempts.clear();
    _scheduleSave();
    activity.value = removed == 0 ? '没有可清理的自动抓取视频' : '已清理 $removed 条';
    debugPrint('[OP-VIDEO] 🧹 清理完成，共 $removed 条');
    return removed;
  }

  /// 扫库统计已自动抓取的条数与体积（设置页展示用）。
  Future<OpVideoCacheStats> stats() async {
    int files = 0;
    int bytes = 0;
    for (final LibraryGame game in LocalGameRegistry.instance.allGames) {
      final String dir = game.metaDataDir;
      if (dir.isEmpty) continue;
      for (final BpmBackdropVideoAsset a in BpmBackdropMedia.readVideos(dir)) {
        if (!a.file.startsWith(fileNamePrefix)) continue;
        try {
          final File f = File('$dir${Platform.pathSeparator}${a.file}');
          if (!await f.exists()) continue;
          files++;
          bytes += await f.length();
        } catch (_) {
          // 单个文件读不到不影响整体统计
        }
      }
      // 让出一帧，避免几百个游戏时设置页打开卡顿
      await Future<void>.delayed(Duration.zero);
    }
    return OpVideoCacheStats(files: files, bytes: bytes);
  }

  // ===========================================================================
  // 内部流程
  // ===========================================================================

  Future<void> _runProbe({
    required String key,
    required String metaDataDir,
    required String title,
    String? subtitle,
    String? metadataSource,
    String? metadataSourceId,
  }) async {
    activity.value = '正在查找《$title》的可用视频…';
    debugPrint('[OP-VIDEO] 🔍 开始探测《$title》');

    // ① 复用标题图那套锚点解析，拿到候选 Steam appid（可能为空）
    final List<String> appIds;
    try {
      appIds = await GameTitleLogoService.instance.resolveSteamAppIds(
        title: title,
        subtitle: subtitle,
        metadataSource: metadataSource,
        metadataSourceId: metadataSourceId,
      );
    } catch (e) {
      debugPrint('[OP-VIDEO] ⚠️ appid 解析失败: $e');
      _recordFailure(key, 'networkError');
      _noteNetworkResult(true);
      activity.value = '';
      return;
    }

    if (appIds.isEmpty) {
      debugPrint('[OP-VIDEO] ✋ 《$title》没有 Steam 锚点，无法取视频');
      _recordFailure(key, 'noAnchor');
      activity.value = '';
      return;
    }

    // ② 探测（只查列表，不下载）
    final String proxy = await _resolveProxy();
    final OpVideoCore core = OpVideoCore(
      log: (String m) => debugPrint(m),
      proxy: proxy,
      concurrency: _chunkConcurrency,
    );
    final OpProbeResult pr = await core.probe(appIds: appIds);
    // 网络熔断只看「请求失败且一无所获」：部分失败但拿到了候选时，
    // 弹窗照常走，别把功能掐死。
    _noteNetworkResult(pr.sawNetworkError && pr.candidates.isEmpty);

    // ③ 无候选 → 按状态记负缓存，静默返回（用户明确：没素材不用提示）
    if (pr.candidates.isEmpty) {
      final String status = pr.sawNetworkError
          ? 'networkError'
          : (pr.sawAnyMovie ? 'noUsableMovie' : 'noMovie');
      _recordFailure(key, status);
      debugPrint('[OP-VIDEO] ✋ 《$title》未探到可用视频: $status');
      activity.value = '';
      return;
    }
    activity.value = '';

    // ④ 过滤已在盘上的产物（上次写入池失败的残留等）——盘上已有的不进弹窗
    final List<OpCandidate> fresh = <OpCandidate>[];
    for (final OpCandidate c in pr.candidates) {
      final File f = File(
        '$metaDataDir${Platform.pathSeparator}'
        '${OpVideoCore.fileNamePrefix}${c.movie.id}.mp4',
      );
      if (!await f.exists()) fresh.add(c);
    }
    if (fresh.isEmpty) {
      // 全都在盘上：把最优先那条静默补登记进池（修复残留），不打扰用户
      final OpCandidate c0 = pr.candidates.first;
      final String fileName =
          '${OpVideoCore.fileNamePrefix}${c0.movie.id}.mp4';
      await BpmBackdropMedia.addVideos(
        metaDataDir,
        <BpmBackdropVideoAsset>[
          BpmBackdropVideoAsset(file: fileName, name: c0.movie.name),
        ],
        autoSelect: false,
      );
      debugPrint('[OP-VIDEO] 🩹 产物已在盘上，补登记入池: $fileName');
      return;
    }

    // ⑤ 交宿主弹窗询问。这一路是「探测成功」的正路，不写任何负缓存 ——
    //    答案（拉/不拉）由用户在 confirmFetch / decline 里给出。
    _askedThisSession.add(key);
    debugPrint('[OP-VIDEO] 💡 《$title》探到 ${fresh.length} 条候选，交弹窗确认');
    try {
      onCandidates?.call(metaDataDir, title, fresh);
    } catch (e) {
      debugPrint('[OP-VIDEO] ⚠️ 弹窗回调异常（忽略）: $e');
    }
  }

  /// 用户确认后的实际下载 + 入池（`confirmFetch` 的队列体）。
  Future<void> _downloadAndStore({
    required String key,
    required String metaDataDir,
    required String title,
    required OpCandidate candidate,
  }) async {
    activity.value = '正在下载《$title》的背景视频…';
    debugPrint('[OP-VIDEO] ⬇️ 开始拉取《$title》：${candidate.movie.name}');

    final String proxy = await _resolveProxy();
    final OpVideoCore core = OpVideoCore(
      log: (String m) => debugPrint(m),
      proxy: proxy,
      concurrency: _chunkConcurrency,
      onProgress: (int done, int total) {
        activity.value = '正在下载《$title》的背景视频… $done/$total';
      },
    );

    final OpFetchResult r = await core.downloadMovie(
      candidate.movie,
      metaDataDir: metaDataDir,
      steamAppId: candidate.steamAppId,
    );

    if (!r.isOk) {
      _recordFailure(key, r.status.name);
      _noteNetworkResult(r.status == OpFetchStatus.networkError);
      debugPrint('[OP-VIDEO] ✋ 《$title》拉取失败: ${r.status.name}');
      activity.value = '《$title》拉取失败（${r.kind.label}），稍后再试';
      return;
    }

    // 进池（不抢用户选中）
    final String fileName = r.filePath!.split(Platform.pathSeparator).last;
    final String label = r.movieName.isNotEmpty ? r.movieName : r.kind.label;
    final bool wrote = await BpmBackdropMedia.addVideos(
      metaDataDir,
      <BpmBackdropVideoAsset>[
        BpmBackdropVideoAsset(file: fileName, name: label),
      ],
      // 🔴 自动抓取必须走 false：只在「当前没有选中视频」时接管选中位
      autoSelect: false,
    );

    if (!wrote) {
      debugPrint('[OP-VIDEO] ⚠️ 视频已落盘但写入视频池失败: $fileName');
      activity.value = '';
      return;
    }

    _attempts.remove(key);
    _scheduleSave();
    _fetchedThisSession++;
    _noteNetworkResult(false);
    activity.value = '已获取《$title》${r.kind.label}：$label';
    debugPrint('[OP-VIDEO] ✅ 《$title》${r.kind.label} 已入池：$fileName（$label）');

    // ④ 通知宿主重新起播（当前舞台就是这个游戏时，用户能直接看到）
    try {
      final String dir = metaDataDir;
      onStored?.call(dir);
    } catch (e) {
      debugPrint('[OP-VIDEO] ⚠️ 宿主回调异常（忽略）: $e');
    }
  }

  /// 代理：委托全局统一策略，每次下载前刷新一次（运行期开/关系统代理可跟随）。
  Future<String> _resolveProxy() async {
    final policy = NetworkProxyPolicy.instance;
    await policy.refresh();
    return policy.effectiveProxy ?? '';
  }

  /// 记一次「是不是网络类失败」，连着两次就把本次启动的自动抓取停掉。
  void _noteNetworkResult(bool isNetworkError) {
    if (!isNetworkError) {
      _netFailStreak = 0;
      return;
    }
    _netFailStreak++;
    if (_netFailStreak >= maxConsecutiveNetworkErrors && !_circuitOpen) {
      _circuitOpen = true;
      debugPrint('[OP-VIDEO] 🔌 商店 API 连续不可达，本次启动内暂停自动抓取 '
          '（不写负缓存，重启/上次成功即恢复）');
      activity.value = 'Steam 商店暂时连不上，本次已暂停自动抓取';
    }
  }

  void _recordFailure(String key, String status) {
    _attempts[key] = _Attempt(
      at: DateTime.now().millisecondsSinceEpoch,
      status: status,
    );
    _scheduleSave();
  }

  // ===========================================================================
  // 负缓存持久化
  // ===========================================================================

  Future<void> _loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final File f = File(_attemptFilePath);
      if (!await f.exists()) return;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return;
      decoded.forEach((Object? k, Object? v) {
        if (k is! String || k.isEmpty || v is! Map) return;
        final Object? at = v['t'];
        final int? ts = at is int ? at : int.tryParse('$at');
        if (ts == null) return;
        _attempts[k] = _Attempt(at: ts, status: v['s']?.toString() ?? '');
      });
    } catch (e) {
      debugPrint('[OP-VIDEO] ⚠️ 负缓存读取失败（忽略）: $e');
    }
  }

  void _scheduleSave() {
    final Future<void> previous = _saveQueue;
    _saveQueue = () async {
      await previous;
      try {
        final File f = File(_attemptFilePath);
        final Directory dir = f.parent;
        if (!await dir.exists()) await dir.create(recursive: true);
        final Map<String, dynamic> out = <String, dynamic>{
          for (final MapEntry<String, _Attempt> e in _attempts.entries)
            e.key: <String, dynamic>{'t': e.value.at, 's': e.value.status},
        };
        await f.writeAsString(jsonEncode(out), flush: true);
      } catch (e) {
        debugPrint('[OP-VIDEO] ⚠️ 负缓存写入失败（忽略）: $e');
      }
    }();
  }

  /// 测试专用：重置内部状态。
  @visibleForTesting
  void resetForTest() {
    _inFlight.clear();
    _askedThisSession.clear();
    _attempts.clear();
    _cacheLoaded = false;
    _saveQueue = Future<void>.value();
    _queue = Future<void>.value();
    _fetchedThisSession = 0;
    _netFailStreak = 0;
    _circuitOpen = false;
    onStored = null;
    activity.value = '';
  }
}
