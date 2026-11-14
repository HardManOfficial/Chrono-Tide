import 'dart:async';

import 'package:flutter/foundation.dart';

import 'company_alias_store.dart';
import 'game_data_format.dart';
import 'local_game_registry.dart';
import 'metadata_fetcher.dart';
import 'metadata_refresh_core.dart';

/// 批量刷新元数据的运行阶段。
enum MetadataRefreshPhase {
  /// 从未运行过 / 已重置
  idle,

  /// 正在逐条刷新
  running,

  /// 全部跑完（含「部分失败」）
  finished,

  /// 用户点了取消
  cancelled,
}

/// 单条游戏的失败记录（供「重试失败项」复用）。
class MetadataRefreshFailure {
  /// 稳定主键（老数据可能为空串，此时用标题兜底匹配）
  final String gameId;
  final String title;
  final String reason;

  const MetadataRefreshFailure({
    required this.gameId,
    required this.title,
    required this.reason,
  });

  @override
  String toString() => '$title（$reason）';
}

/// 一次刷新任务的进度快照（不可变，供 UI 直接读）。
class MetadataRefreshProgress {
  const MetadataRefreshProgress({
    this.phase = MetadataRefreshPhase.idle,
    this.total = 0,
    this.done = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.failed = 0,
    this.currentTitle = '',
    this.failures = const <MetadataRefreshFailure>[],
    this.overwrite = false,
  });

  final MetadataRefreshPhase phase;
  final int total;
  final int done;

  /// 实际写入成功的条数（有字段被更新）
  final int updated;

  /// 跑完但库里已有值且未勾选覆盖 —— 没有可写字段
  final int unchanged;

  final int failed;
  final String currentTitle;
  final List<MetadataRefreshFailure> failures;
  final bool overwrite;

  bool get isRunning => phase == MetadataRefreshPhase.running;
  bool get isFinished => phase == MetadataRefreshPhase.finished;
  bool get hasFailures => failures.isNotEmpty;

  /// 进度比例（0..1）。`total == 0` 时返回 0，避免除零。
  double get ratio => total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);

  String get percentText => '${(ratio * 100).round()}%';

  /// 一句话结论（结果行文案的唯一来源，UI 不再自己拼）
  String get summaryText {
    switch (phase) {
      case MetadataRefreshPhase.idle:
        return '尚未运行';
      case MetadataRefreshPhase.running:
        return '正在刷新 $done/$total · $currentTitle';
      case MetadataRefreshPhase.cancelled:
        return '已取消 · 完成 $done/$total · 更新 $updated · 失败 $failed';
      case MetadataRefreshPhase.finished:
        if (total == 0) return '库里没有可刷新的游戏';
        return '完成 $done/$total · 更新 $updated · 无变化 $unchanged · 失败 $failed';
    }
  }
}

/// 批量刷新全库元数据。
///
/// ## 为什么要有它
/// 抓取源、字段优先级、代理策略、平台凭证 —— 这四件事全都会改变
/// 「同一条游戏能抓到什么」。改完设置如果只能一条条进详情页手动重抓，
/// 用户实际不会去用。这个服务把「重新抓一遍全库」做成一次性动作。
///
/// ## 语义（刻意保守）
/// - **不改标题**：标题是用户的资产，刷新只补数据，绝不改名。
///   标题相关字段（`title` / `original_title` / `subtitle`）一概不碰。
/// - **默认只补空字段**（`overwrite=false`）：简介被用户手改过、标签被整理过，
///   一次误点就全没了 —— 这种事没有 undo。想要覆盖必须显式勾选。
/// - **不碰封面/截图**：那两条各有自己的后台机制
///   （`CoverDownloadService` / `ScreenshotFetchService`），
///   混进来会让「刷新元数据」变成不可预期的长任务。
/// - **串行 + 间隔**：抓取平台是别人的公共服务，并发轰炸换来的只是封 IP。
///
/// ## 写盘
/// 唯一路径 `GameDataFormat.updateGameJsonAtomic`（写队列 + 原子写 +
/// 主键护栏），与详情页/批量导入共用同一条链路，不另开写盘口子。
class MetadataRefreshService extends ChangeNotifier {
  MetadataRefreshService._();

  static final MetadataRefreshService instance = MetadataRefreshService._();

  /// 两条请求之间的最小间隔（毫秒）。串行爬取，避免把元数据平台打成压力源。
  static const int kDefaultIntervalMs = 400;

  MetadataRefreshProgress _progress = const MetadataRefreshProgress();
  MetadataRefreshProgress get progress => _progress;

  bool _running = false;
  bool _cancelled = false;

  /// 测试用：跳过请求间隔（`Future.delayed` 在 flutter_tester 的
  /// 绑定环境下会永久挂起，探针里必须能关掉）。
  static bool _skipIntervalForTest = false;

  @visibleForTesting
  static void configureForTesting({bool skipInterval = true}) {
    _skipIntervalForTest = skipInterval;
  }

  /// 重置为 idle（仅测试/「清空结果」用，运行中调用无效）。
  @visibleForTesting
  void resetForTest() {
    if (_running) return;
    _progress = const MetadataRefreshProgress();
    notifyListeners();
  }

  /// 直接注入一个进度快照（仅测试用）。
  ///
  /// 存在的理由：进度条 + 失败清单是「运行时才会出现」的分支，
  /// 只渲染 idle 态等于没验证过它们 —— 而它们恰恰是最容易溢出的部分。
  @visibleForTesting
  void emitForTest(MetadataRefreshProgress snapshot) {
    _progress = snapshot;
    notifyListeners();
  }

  void _emit(MetadataRefreshProgress next) {
    _progress = next;
    notifyListeners();
  }

  /// 开始全量刷新。
  ///
  /// [overwrite] true = 连已有值也覆盖（用户显式勾选）；
  /// false（默认）= 只补空字段。
  ///
  /// [intervalMs] 仅供测试/特殊场景，默认 [kDefaultIntervalMs]。
  ///
  /// 运行中重复调用直接忽略（返回当前 future 的完成态不是本方法职责，
  /// 调用方用 [progress] 判断）。
  Future<void> start({
    bool overwrite = false,
    int intervalMs = kDefaultIntervalMs,
  }) async {
    if (_running) return;

    final List<LibraryGame> games = LocalGameRegistry.instance.allGames
        .where((LibraryGame g) =>
            g.title.trim().isNotEmpty && g.metaDataDir.trim().isNotEmpty)
        .toList(growable: false);

    _running = true;
    _cancelled = false;
    _emit(MetadataRefreshProgress(
      phase: MetadataRefreshPhase.running,
      total: games.length,
      overwrite: overwrite,
    ));

    await _run(games, overwrite: overwrite, intervalMs: intervalMs);
  }

  /// 重试上一轮失败的条目（保留失败清单里的对象，不重扫全库）。
  Future<void> retryFailed({
    bool overwrite = false,
    int intervalMs = kDefaultIntervalMs,
  }) async {
    if (_running) return;
    final failed = _progress.failures;
    if (failed.isEmpty) return;

    final List<LibraryGame> games = <LibraryGame>[];
    for (final MetadataRefreshFailure f in failed) {
      LibraryGame? game;
      if (f.gameId.isNotEmpty) {
        game = LocalGameRegistry.instance.getGameById(f.gameId);
      }
      game ??= LocalGameRegistry.instance.getGameByTitle(f.title);
      if (game != null) games.add(game);
    }
    if (games.isEmpty) return;

    _running = true;
    _cancelled = false;
    _emit(MetadataRefreshProgress(
      phase: MetadataRefreshPhase.running,
      total: games.length,
      overwrite: overwrite,
    ));

    await _run(games, overwrite: overwrite, intervalMs: intervalMs);
  }

  /// 请求取消：当前这条跑完就停（不做硬中断，避免半截写盘）。
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    notifyListeners();
  }

  Future<void> _run(
    List<LibraryGame> games, {
    required bool overwrite,
    required int intervalMs,
  }) async {
    int done = 0;
    int updated = 0;
    int unchanged = 0;
    int failed = 0;
    final List<MetadataRefreshFailure> failures = <MetadataRefreshFailure>[];

    try {
      for (final LibraryGame game in games) {
        if (_cancelled) break;

        _emit(MetadataRefreshProgress(
          phase: MetadataRefreshPhase.running,
          total: games.length,
          done: done,
          updated: updated,
          unchanged: unchanged,
          failed: failed,
          currentTitle: game.title,
          failures: List<MetadataRefreshFailure>.unmodifiable(failures),
          overwrite: overwrite,
        ));

        final _SingleOutcome outcome =
            await _refreshOne(game, overwrite: overwrite);

        done++;
        switch (outcome.kind) {
          case _OutcomeKind.updated:
            updated++;
            break;
          case _OutcomeKind.unchanged:
            unchanged++;
            break;
          case _OutcomeKind.failed:
            failed++;
            failures.add(MetadataRefreshFailure(
              gameId: game.gameId,
              title: game.title,
              reason: outcome.reason,
            ));
            break;
        }

        if (intervalMs > 0 && !_skipIntervalForTest && done < games.length) {
          await Future<void>.delayed(Duration(milliseconds: intervalMs));
        }
      }
    } finally {
      // 内存对象已被逐条改过，收尾统一广播一次派生索引失效 + 视图刷新。
      // （逐条 notify 会让 2000 条规模下库页重建 2000 次，得不偿失。）
      if (updated > 0) {
        LocalGameRegistry.instance.notifyDataChanged();
      }

      _running = false;
      final bool cancelled = _cancelled;
      _cancelled = false;
      _emit(MetadataRefreshProgress(
        phase: cancelled
            ? MetadataRefreshPhase.cancelled
            : MetadataRefreshPhase.finished,
        total: games.length,
        done: done,
        updated: updated,
        unchanged: unchanged,
        failed: failed,
        currentTitle: '',
        failures: List<MetadataRefreshFailure>.unmodifiable(failures),
        overwrite: overwrite,
      ));
    }
  }

  Future<_SingleOutcome> _refreshOne(
    LibraryGame game, {
    required bool overwrite,
  }) async {
    Map<String, dynamic>? fetched;
    try {
      // useCache=false：刷新的意义就是重新问一遍源。缓存命中会让
      // 「改了优先级/换了代理」的用户看起来毫无变化。
      fetched = await MetadataFetcher.fetchGameMixed(game.title, useCache: false);
    } catch (e) {
      return _SingleOutcome.failed('抓取异常：$e');
    }
    if (fetched == null) {
      return const _SingleOutcome.failed('各平台均无匹配条目');
    }

    // 字段规整 / 空值归一 / 只补空字段 or 覆盖 —— 全部在纯 Dart 核心
    // （metadata_refresh_core.dart）里做，能被裸 VM 探针直接断言。
    final MetadataRefreshCandidate candidate =
        MetadataRefreshCandidate.fromFetched(fetched);
    if (!candidate.hasAnyField) {
      return const _SingleOutcome.failed('抓到的条目没有任何可用字段');
    }

    // 会社归一化：与 setGameDeveloper 同口径（原文 + company_id 一起落盘）
    final String? developer = candidate.developer;
    final int? companyId = developer == null
        ? null
        : CompanyAliasStore.instanceOrNull
            ?.resolve(developer)
            ?.record
            .companyId;

    // 先读一遍当前值再决定写什么 —— 这样「没有可写字段」时能干净地
    // 跳过，不给 game.json 刷一个无意义的 updated_at。
    final GameJsonData? current =
        await GameDataFormat.readGameJson(game.metaDataDir);
    if (current == null) {
      return const _SingleOutcome.failed('game.json 读取失败');
    }

    final Map<String, dynamic> updates = computeRefreshUpdates(
      existing: MetadataExistingValues(
        description: current.description,
        developer: current.developer,
        releaseDate: current.releaseDate,
        metadataSource: current.metadataSource,
        metadataSourceId: current.metadataSourceId,
        tags: current.tags,
        rating: current.rating,
        ratingCount: current.ratingCount,
        estimatedMinutes: current.estimatedMinutes,
        companyId: current.companyId,
      ),
      fetched: candidate,
      overwrite: overwrite,
      companyId: companyId,
    );

    if (updates.isEmpty) return const _SingleOutcome.unchanged();

    final bool ok = await GameDataFormat.updateGameJsonAtomic(
      game.metaDataDir,
      (Map<String, dynamic> _) => updates,
    );
    if (!ok) return const _SingleOutcome.failed('game.json 写入失败');

    // 内存对象同步（注册表读的是内存，不同步会「写成功但界面没变」）
    final String? newDescription = updates['description'] as String?;
    if (newDescription != null) game.description = newDescription;
    final String? newDeveloper = updates['developer'] as String?;
    if (newDeveloper != null) game.developer = newDeveloper;
    final String? newRelease = updates['release_date'] as String?;
    if (newRelease != null) game.releaseDate = newRelease;
    final String? newSource = updates['metadata_source'] as String?;
    if (newSource != null) game.metadataSource = newSource;
    final String? newSourceId = updates['metadata_source_id'] as String?;
    if (newSourceId != null) game.metadataSourceId = newSourceId;
    final List<String>? newTags = updates['tags'] as List<String>?;
    if (newTags != null) game.tags = newTags;
    final int? newCompanyId = updates['company_id'] as int?;
    if (newCompanyId != null) game.companyId = newCompanyId;

    return _SingleOutcome.updated();
  }
}

enum _OutcomeKind { updated, unchanged, failed }

class _SingleOutcome {
  final _OutcomeKind kind;
  final String reason;

  const _SingleOutcome.updated()
      : kind = _OutcomeKind.updated,
        reason = '';

  const _SingleOutcome.unchanged()
      : kind = _OutcomeKind.unchanged,
        reason = '';

  const _SingleOutcome.failed(this.reason)
      : kind = _OutcomeKind.failed;
}
