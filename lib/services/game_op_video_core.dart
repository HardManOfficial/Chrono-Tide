/// Steam OP 视频抓取引擎 —— **纯 Dart 核心**（零 Flutter 依赖）。
///
/// ## 为什么单独成文件（与 `openlist_update_core.dart` 同因）
/// 这段逻辑要真 HTTP、真异步 IO、几十 MB 的落盘 —— 在 `flutter_tester` 下
/// `Directory.create(recursive:true)` / `Future.delayed` 会**永久挂起**，
/// 根本没法用 widget test 验证。抽成纯 Dart 后可以用 `dart.exe` 直跑端到端
/// 探针（`.workbuddy/probe_op_video/`），真下载、真拼接、真校验 box 链。
///
/// 宿主接线（`game_op_video_service.dart`）只负责「什么时候抓、抓到后写哪里」，
/// 抓取本身全部在这里，可独立测试。
///
/// ## 链路（实测来源，见 `docs/DEV/features/bpm_op_video_autofetch.md`）
/// ```
/// appdetails?filters=movies  → movies[]（含 hls_h264）
///   → 分期：按 OP > ED > PV > 其它相关视频 分级，取最靠前的一条
///   → hls_h264 主播放列表 → 选 720p 档 → 媒体播放列表
///   → #EXT-X-MAP init 段 + 全部分片（fMP4/CMAF）顺序字节拼接
///   → op_video_<movieId>.mp4（.part 中转，成功后原子改名）
/// ```
///
/// 🔴 **不需要 ffmpeg**：Steam 的 HLS 分片本身就是 fMP4，init 段（`ftyp`+`moov`）
/// 后面直接追加 `moof`+`mdat` 分片即为合法的分片式 MP4，Windows 8 起
/// Media Foundation 原生支持（`video_player_win` 走 MF，因此能直接播）。
/// 实测 AOKANA OP1：148 秒 / 50 片 / 44.5MB，box 链 46,664,013 字节精确解析到末尾。
///
/// ## 不做的事
/// - ❌ 1080p（体积翻倍，当背景板看不出差别）
/// - ❌ 流式播放（MF 不支持 HLS，`video_player_win` 绕不开）
/// - ❌ 跨批次断点续传（单次运行内分片级重试已足够；失败整批丢弃，下次重抓）
/// - ❌ 一次抓多条（只取最靠前的一条，避免 45MB × N）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 引擎日志回调（宿主注入：Flutter 层传 `debugPrint`，探针传 `print`）。
typedef OpLog = void Function(String message);

/// 一个 Steam 商店影片条目（只保留本引擎用得上的字段）。
class OpMovie {
  const OpMovie({
    required this.id,
    required this.name,
    required this.hlsUrl,
    this.thumbnail = '',
    this.highlight = false,
  });

  /// Steam 影片 id（用作落盘文件名，保证同一部影片抓多少次都是同一个文件）。
  final int id;

  /// 影片名（`OP1-CN` / `Opening Movie` / `Official PV` …）。
  final String name;

  /// `hls_h264`（m3u8 主播放列表地址）；空串 = 该条目没有可下载的 HLS 源。
  final String hlsUrl;

  final String thumbnail;

  /// Steam 自称的「高亮」影片（通常就是厂商主推的那条，仅供参考，不参与判定）。
  final bool highlight;

  @override
  String toString() => 'OpMovie($id, $name)';
}

/// 影片素材类型 —— **决定「先抓哪一条」的优先级**。
///
/// 🔴 产品语义（用户 2026-10-17 补充）：背景素材不局限于 OP，
/// ED / PV / 其它介绍游戏的官方视频都能用，**没有 OP 就用 ED，再没有就用 PV**。
/// 所以这里不再是「收 / 不收」的硬闸，而是一个**排序**：
/// `opening < ending < pv < other`，同级取商店页顺序里的第一条。
enum OpMovieKind {
  /// 片头动画（`OP1-CN` / `Opening Movie` / `オープニング`）。
  opening('OP', 0),

  /// 片尾动画（`ED1` / `Ending` / `エンディング`）。
  ending('ED', 1),

  /// 宣传 / 预告片（`Official PV` / `Trailer` / `Teaser` / `CM` / 预告）。
  pv('PV', 2),

  /// 没标注类型、但确实挂在本作商店页上的影片 —— 同样是本作相关素材。
  other('相关视频', 3);

  const OpMovieKind(this.label, this.rank);

  /// 展示 / 日志用的短标签。
  final String label;

  /// 优先级，数值越小越优先。
  final int rank;
}

/// 探测出的一条可下载候选（见 [OpVideoCore.probe]）。
class OpCandidate {
  const OpCandidate({
    required this.movie,
    required this.kind,
    required this.steamAppId,
  });

  final OpMovie movie;
  final OpMovieKind kind;
  final String steamAppId;
}

/// 探测结果（`probe` 的返回值）。
class OpProbeResult {
  const OpProbeResult({
    required this.sawAnyMovie,
    required this.sawNetworkError,
    required this.candidates,
  });

  /// 任一 appid 返回过影片列表（哪怕一条都下不了）。
  final bool sawAnyMovie;

  /// 任一 appid 的商店请求失败（连不上 / 非 200 / JSON 坏）。
  final bool sawNetworkError;

  /// 可下载候选，**已按 OP > ED > PV > 其它 排序**（同级保持收集顺序）。
  final List<OpCandidate> candidates;
}

/// 抓取结果状态。
enum OpFetchStatus {
  /// 成功：已落盘。
  ok,

  /// 目标文件已存在（幂等命中，未发起网络请求）。
  alreadyExists,

  /// 没有任何 Steam appid（非 Steam 发行 / 目录未收录）。
  noAnchor,

  /// appid 拿不到影片列表（商店 API 无数据 / 该区不可见）。
  noMovie,

  /// 有影片条目，但一条都没有可下载的 `hls_h264` 源（全都没法用）。
  ///
  /// 注意语义已变化：**不再是「只有 PV 所以不给」** —— PV 现在也是合法素材。
  noUsableMovie,

  /// 下载或拼接失败（网络抖动、分片缺失、体积超限、产物不是合法 mp4）。
  downloadFailed,

  /// 网络 / 解析异常（含商店 API 不可达）。
  networkError,
}

/// 一次抓取的结果（引擎不抛异常，失败一律以状态返回）。
class OpFetchResult {
  const OpFetchResult({
    required this.status,
    this.filePath,
    this.movieName = '',
    this.movieId = 0,
    this.kind = OpMovieKind.other,
    this.bytes = 0,
    this.segments = 0,
    this.steamAppId = '',
    this.message,
  });

  final OpFetchStatus status;

  /// 落盘绝对路径（成功 / 已存在时非空）。
  final String? filePath;

  final String movieName;
  final int movieId;

  /// 命中的素材类型（OP / ED / PV / 其它），宿主用于文案。
  final OpMovieKind kind;

  /// 产物字节数。
  final int bytes;

  /// 分片数（不含 init 段）。
  final int segments;

  /// 命中的 Steam appid（排查用）。
  final String steamAppId;

  final String? message;

  bool get isOk =>
      status == OpFetchStatus.ok || status == OpFetchStatus.alreadyExists;
}

/// Steam OP 视频抓取引擎。
///
/// 一个实例 = 一次抓取上下文（持有 HttpClient 与代理设置），**用后即弃**：
/// 调用方每次抓取新建一个，`fetch` 返回后内部自动关闭连接。
class OpVideoCore {
  OpVideoCore({
    OpLog? log,
    this.proxy = '',
    this.concurrency = 3,
    this.maxBytes = 200 * 1024 * 1024,
    this.movieListTimeout = const Duration(seconds: 15),
    this.segmentTimeout = const Duration(seconds: 45),
    this.maxSegmentAttempts = 3,
    this.storeApiBase = defaultStoreApiBase,
    this.onProgress,
  })  : _log = log,
        assert(concurrency >= 1 && concurrency <= 8, '并发只允许 1..8');

  /// Steam 商店 appdetails 端点。生产固定为 [defaultStoreApiBase]；
  /// 探针可以指向本地 fixture server（`.workbuddy/probe_op_video/`），
  /// 这样在「Steam 不可达」的网络环境下依然能端到端验证整条链路。
  final String storeApiBase;

  /// 代理（`127.0.0.1:7890` 形态，不带 scheme；空串 = 用环境变量/直连）。
  final String proxy;

  /// 分片下载并发上限。3 是实测折中：再高对 Steam CDN 不礼貌，再低 45MB 要 5 分钟+。
  final int concurrency;

  /// 产物体积上限。超过直接放弃（防止选错档位把 100MB+ 拖下来）。
  final int maxBytes;

  final Duration movieListTimeout;
  final Duration segmentTimeout;

  /// 单个分片最多试几次（实测出现过单次连接 000，重试即成功）。
  final int maxSegmentAttempts;

  /// 进度回调：`(已完成分片数, 总分片数)`。宿主用它刷设置页状态行。
  final void Function(int done, int total)? onProgress;

  final OpLog? _log;

  static const String _storeApiBase =
      'https://store.steampowered.com/api/appdetails';

  /// 生产环境的商店 appdetails 端点（探针可覆盖）。
  static const String defaultStoreApiBase = _storeApiBase;

  static const String _ua = 'ChronoTide/1.0 (OP Video Fetcher)';

  /// 落盘文件名前缀。**自动抓取的产物一律带这个前缀** ——
  /// ① 幂等判据；② 清理时只删自己抓的，绝不碰用户手放的视频。
  static const String fileNamePrefix = 'op_video_';

  HttpClient? _client;

  void _emit(String msg) => _log?.call(msg);

  // ===========================================================================
  // 对外主入口
  // ===========================================================================

  /// 依次尝试 [appIds]，抓到素材就返回（探测 + 下载一条龙）。
  ///
  /// [metaDataDir] 游戏元数据目录（产物落在该目录下，与背景图/视频池同处）。
  ///
  /// 🔴 必须逐个 appid 试：NextMoe 一个作品常挂多个 steam 锚点，首个经常是
  /// DLC / 试玩版 / 旧包，其 `movies` 为空（与标题图踩过的坑同源）——
  /// 探测阶段的早停规则见 [probe]。
  Future<OpFetchResult> fetch({
    required List<String> appIds,
    required String metaDataDir,
  }) async {
    if (appIds.isEmpty) {
      return const OpFetchResult(
        status: OpFetchStatus.noAnchor,
        message: '没有 Steam appid',
      );
    }
    if (metaDataDir.isEmpty) {
      return const OpFetchResult(
        status: OpFetchStatus.networkError,
        message: '元数据目录为空',
      );
    }
    final Directory dir = Directory(metaDataDir);
    if (!await dir.exists()) {
      return const OpFetchResult(
        status: OpFetchStatus.networkError,
        message: '元数据目录不存在',
      );
    }

    try {
      _client = _buildClient();
      final OpProbeResult pr = await probe(appIds: appIds);

      if (pr.candidates.isEmpty) {
        // 🔴 三个状态的判定顺序不能乱 —— 它们在宿主侧的负缓存冷却不同：
        //    networkError 1 天 / noUsableMovie 与 noMovie 30 天。
        //    网络挂了就必须报 networkError，绝不能因为「有条目但没源」
        //    把「今天网断了」记成「这游戏一个月内别再试」。
        if (pr.sawNetworkError) {
          return const OpFetchResult(
            status: OpFetchStatus.networkError,
            message: '商店 API 不可达',
          );
        }
        if (pr.sawAnyMovie) {
          return const OpFetchResult(
            status: OpFetchStatus.noUsableMovie,
            message: '影片条目都没有可下载的 HLS 源',
          );
        }
        return const OpFetchResult(status: OpFetchStatus.noMovie);
      }

      // 下载排序最靠前的一条。下载失败不再回退到低级素材：
      // 弹窗确认流程下用户看到的就是这条，静默换成别的反而说不清。
      final OpCandidate best = pr.candidates.first;
      return await downloadMovie(
        best.movie,
        metaDataDir: metaDataDir,
        steamAppId: best.steamAppId,
      );
    } catch (e) {
      return OpFetchResult(
        status: OpFetchStatus.networkError,
        message: '$e',
      );
    } finally {
      _client?.close(force: true);
      _client = null;
    }
  }

  /// 探测可下载的候选素材（**只查商店列表，不下载任何视频**）。
  ///
  /// 这是「弹窗询问用户」模式（用户 2026-10-17 拍板）的第一步：
  /// 服务层拿到 [OpProbeResult.candidates] 交给宿主弹窗，用户确认后才走
  /// [downloadMovie]。
  ///
  /// 🔴 早停规则：**一旦在某个 appid 上发现 OP 就收手**（后面的锚点多半是
  /// DLC / 旧包，没必要再请求）；若只发现 PV / 其它，则继续往后翻 ——
  /// 「首个锚点只有 PV、第二个才有 OP」是真实存在的路径（NextMoe 首锚点
  /// 经常是 DLC/试玩版），被 PV 挡住就漏掉真 OP 了。
  Future<OpProbeResult> probe({required List<String> appIds}) async {
    bool sawAnyMovie = false;
    bool sawNetworkError = false;
    final List<OpCandidate> candidates = <OpCandidate>[];
    final Set<int> seenMovieIds = <int>{};

    if (_client == null) _client = _buildClient();

    for (final String appId in appIds) {
      final List<OpMovie>? movies = await _listMovies(appId);
      // 🔴 null 与 [] 必须分开：`null` = 请求本身失败（网络/限流），
      //    `[]` = 请求成功但该 appid 没有影片。二者在宿主侧的负缓存
      //    冷却时长差 30 倍（网络错误 1 天，没有素材一个月）。
      if (movies == null) {
        sawNetworkError = true;
        continue;
      }
      if (movies.isEmpty) continue;
      sawAnyMovie = true;

      bool foundOpeningHere = false;
      for (final OpMovie m in movies) {
        if (m.hlsUrl.isEmpty) continue;
        if (!seenMovieIds.add(m.id)) continue; // 两个锚点挂了同一部影片
        final OpMovieKind kind = classify(m.name);
        if (kind == OpMovieKind.opening) foundOpeningHere = true;
        candidates.add(
          OpCandidate(movie: m, kind: kind, steamAppId: appId),
        );
      }
      if (foundOpeningHere) break; // 早停：已经找到 OP，后面的锚点不用看了
    }

    // 按 rank 升序；同级保持收集顺序。
    // 🔴 Dart 的 List.sort 不是稳定排序，必须显式带上收集下标做第二键。
    final Map<OpCandidate, int> order = <OpCandidate, int>{
      for (int i = 0; i < candidates.length; i++) candidates[i]: i,
    };
    candidates.sort((OpCandidate a, OpCandidate b) {
      final int r = a.kind.rank.compareTo(b.kind.rank);
      return r != 0 ? r : order[a]!.compareTo(order[b]!);
    });

    return OpProbeResult(
      sawAnyMovie: sawAnyMovie,
      sawNetworkError: sawNetworkError,
      candidates: candidates,
    );
  }

  /// 下载单条候选到 [metaDataDir]（探测 → 用户确认后的实际落盘步骤）。
  ///
  /// 与 [fetch] 不同：只处理这一条，失败也不回退别的素材（用户选的就是它）。
  /// 幂等：同名产物已在盘且是合法 mp4 → `alreadyExists`，不重复下载 45MB。
  Future<OpFetchResult> downloadMovie(
    OpMovie op, {
    required String metaDataDir,
    String steamAppId = '',
  }) async {
    if (metaDataDir.isEmpty) {
      return const OpFetchResult(
        status: OpFetchStatus.networkError,
        message: '元数据目录为空',
      );
    }

    final OpMovieKind kind = classify(op.name);
    final String destPath =
        '$metaDataDir${Platform.pathSeparator}$fileNamePrefix${op.id}.mp4';
    final File dest = File(destPath);

    // 只有自己建的客户端才由自己关（fetch 复用时由 fetch 的 finally 统一关）
    final bool ownsClient = _client == null;
    if (ownsClient) _client = _buildClient();
    try {
      if (await dest.exists() && await dest.length() > 1024 * 1024) {
        if (await _looksLikeMp4(dest)) {
          return OpFetchResult(
            status: OpFetchStatus.alreadyExists,
            filePath: destPath,
            movieName: op.name,
            movieId: op.id,
            kind: kind,
            bytes: await dest.length(),
            steamAppId: steamAppId,
          );
        }
        // 尺寸够但不是 mp4（上次写坏了）→ 删掉重下
        _emit('[OP-VIDEO] ♻️ 已有产物不是合法 mp4，重新抓取: $destPath');
        await _deleteQuietly(dest);
      }

      _emit('[OP-VIDEO] 🎬 命中 ${kind.label}：${op.name}'
          '（appid=$steamAppId, movie=${op.id}）');
      final _Downloaded done =
          await _download(op, dest, appId: steamAppId);
      return OpFetchResult(
        status: OpFetchStatus.ok,
        filePath: destPath,
        movieName: op.name,
        movieId: op.id,
        kind: kind,
        bytes: done.bytes,
        segments: done.segments,
        steamAppId: steamAppId,
      );
    } catch (e) {
      _emit('[OP-VIDEO] ⚠️ 下载失败（movie=${op.id}）: $e');
      return OpFetchResult(
        status: OpFetchStatus.downloadFailed,
        movieName: op.name,
        movieId: op.id,
        kind: kind,
        steamAppId: steamAppId,
        message: '$e',
      );
    } finally {
      if (ownsClient) {
        _client?.close(force: true);
        _client = null;
      }
    }
  }

  /// 从影片列表里挑出**最适合当背景的一条**；没有可用条目则返回 null。
  ///
  /// ## 判定规则（分级，不再硬排除）
  /// 1. 先按 [classify] 把每条标成 `OP / ED / PV / 其它相关视频`；
  /// 2. 按 `rank` 升序取最靠前的那一类 —— **没有 OP 就用 ED，再没有就用 PV**；
  /// 3. 同类有多条时取**商店页顺序里的第一条**（AOKANA 有 OP1/OP2），
  ///    不按 `highlight` 排序（`highlight` 常指向 PV）。
  ///
  /// 🔴 为什么可以放开 PV：这些条目**全部挂在本作自己的商店页上**，
  /// 是厂商发布的、介绍本作的视频；用户也明确说过「只要是有相关游戏内容的
  /// 视频都能当背景」。以前把 PV 一律排除，等于把四成覆盖率白白让掉。
  /// 贴错的风险只剩「appid 锚到了别的作品」—— 那由调用方的锚点纪律兜住。
  ///
  /// 仍然跳过 `hlsUrl` 为空的条目（Steam 上存在只有缩略图没有源的条目）。
  OpMovie? pickMovie(List<OpMovie> movies) {
    OpMovie? best;
    OpMovieKind? bestKind;
    for (final OpMovie m in movies) {
      if (m.hlsUrl.isEmpty) continue;
      final OpMovieKind kind = classify(m.name);
      if (best == null || kind.rank < bestKind!.rank) {
        best = m;
        bestKind = kind;
      }
    }
    return best;
  }

  /// 归一化：小写 + 只留字母 / 数字 / 中日文（去掉空格、连字符、下划线、括号）。
  static String _normalize(String raw) {
    final StringBuffer sb = StringBuffer();
    for (final int code in raw.toLowerCase().runes) {
      final bool keep = (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x61 && code <= 0x7A) || // a-z
          code > 0x2E80; // 中日文
      if (keep) sb.writeCharCode(code);
    }
    return sb.toString();
  }

  /// 给一条影片名分类。**判定顺序：OP → ED → PV → 其它**（先命中先算）。
  ///
  /// 归一化会**去掉空格与连字符**，所以 `ED` / `CM` 这类两字母缩写不能直接
  /// 用 `contains`（`edited` / `animated` / `commercial` 全会误伤），
  /// 必须在**原始小写串**上用词边界判（见 [_hasToken]）。
  ///
  /// `OP` 是唯一保留「包含即命中」的缩写：Steam 上的真实命名是
  /// `OP1-CN` / `ENOP` / `STEAMOP1` / `Diesirae_OP` —— `OP` 常粘在作品名后面，
  /// 分词会漏掉一大片。误伤面（`loop` / `shop`）在 galgame 影片名里可忽略。
  static OpMovieKind classify(String raw) {
    final String key = _normalize(raw);
    if (key.isEmpty) return OpMovieKind.other;

    // ① OP
    if (key.contains('opening') ||
        key.contains('オープニング') ||
        key.contains('オープニングテーマ') ||
        key.contains('片头') ||
        key.contains('片頭') ||
        key.contains('主题歌') ||
        key.contains('主題歌') ||
        key.contains('op')) {
      return OpMovieKind.opening;
    }
    // ② ED（必须在原始串上判边界）
    if (key.contains('ending') ||
        key.contains('エンディング') ||
        key.contains('片尾') ||
        _hasToken(raw, 'ed') ||
        _hasToken(raw, 'end')) {
      return OpMovieKind.ending;
    }
    // ③ PV / 预告片（同属「介绍本作的官方视频」，优先级最低）
    if (key.contains('pv') ||
        key.contains('trailer') ||
        key.contains('teaser') ||
        key.contains('promo') ||
        key.contains('preview') ||
        key.contains('commercial') ||
        key.contains('预告') ||
        key.contains('宣傳') ||
        key.contains('宣传') ||
        _hasToken(raw, 'cm')) {
      return OpMovieKind.pv;
    }
    // ④ 其它（没标注类型，但确实挂在本作商店页）
    return OpMovieKind.other;
  }

  /// 原始串里是否有**独立**的 [token]（`ed` / `cm` 这种两字母缩写专用）。
  ///
  /// 边界定义：左侧不能是字母/数字，右侧允许跟一串数字（`ED1` / `CM2`），
  /// 但再往后不能是字母。这样 `ED1` / `ED Movie` / `PV_ED-2` 命中，而
  /// `edited` / `animated` / `commercial` 不会误伤。中文两侧天然算边界。
  static bool _hasToken(String raw, String token) {
    final RegExp re = RegExp(
      '(^|[^a-z0-9])${RegExp.escape(token)}\\d*([^a-z0-9]|\$)',
      caseSensitive: false,
    );
    return re.hasMatch(raw);
  }

  // ===========================================================================
  // 商店 API：影片列表
  // ===========================================================================

  /// 拉取某 appid 的影片列表。
  ///
  /// 返回 `null` = **请求失败**（连不上 / 非 200 / JSON 坏掉）；
  /// 返回空列表 = 请求成功但该作品没有影片。
  /// 这个区分决定宿主的负缓存冷却时长，不能合并（见调用处注释）。
  Future<List<OpMovie>?> _listMovies(String appId) async {
    final HttpClient? client = _client;
    if (client == null) return null;

    final Uri uri = Uri.parse(
      '$storeApiBase?appids=$appId&filters=movies&cc=us&l=english',
    );

    Map<String, dynamic> body;
    try {
      final HttpClientRequest req = await client
          .getUrl(uri)
          .timeout(movieListTimeout);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse res = await req.close().timeout(movieListTimeout);
      if (res.statusCode != 200) {
        _emit('[OP-VIDEO] ⚠️ 商店 API 返回 ${res.statusCode}（appid=$appId）');
        await res.drain<void>();
        return null;
      }
      final String text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(movieListTimeout);
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      body = decoded.cast<String, dynamic>();
    } catch (e) {
      _emit('[OP-VIDEO] ⚠️ 商店 API 失败（appid=$appId）: $e');
      return null;
    }

    // 响应形态：{ "<appid>": { "success": true, "data": { "movies": [...] } } }
    final Object? entry = body[appId] ?? body[appId.toString()];
    if (entry is! Map) return const <OpMovie>[];
    final Map<Object?, Object?> entryMap = entry;
    if (entryMap['success'] != true) return const <OpMovie>[];
    final Object? data = entryMap['data'];
    if (data is! Map) return const <OpMovie>[];
    final Object? movies = data['movies'];
    if (movies is! List) return const <OpMovie>[];

    final List<OpMovie> out = <OpMovie>[];
    for (final Object? raw in movies) {
      if (raw is! Map) continue;
      final Object? id = raw['id'];
      final String name = raw['name']?.toString().trim() ?? '';
      final String hls = raw['hls_h264']?.toString().trim() ?? '';
      if (id is! num || name.isEmpty) continue;
      out.add(OpMovie(
        id: id.toInt(),
        name: name,
        hlsUrl: hls,
        thumbnail: raw['thumbnail']?.toString() ?? '',
        highlight: raw['highlight'] == true,
      ));
    }
    _emit('[OP-VIDEO] 📋 appid=$appId 影片 ${out.length} 个: '
        '${out.map((OpMovie m) => m.name).join(' | ')}');
    return out;
  }

  // ===========================================================================
  // m3u8
  // ===========================================================================

  /// 下载 + 拼接一条影片。
  Future<_Downloaded> _download(
    OpMovie movie,
    File dest, {
    required String appId,
  }) async {
    final Uri masterUri = Uri.parse(movie.hlsUrl);
    final String masterText = await _getText(masterUri);

    // ① 主播放列表 → 选档 → 媒体播放列表
    String mediaText = masterText;
    Uri mediaUri = masterUri;
    final Uri? variant = _pickVariant(masterUri, masterText);
    if (variant != null) {
      mediaUri = variant;
      _emit('[OP-VIDEO] 🎚️ 选档: $variant');
      mediaText = await _getText(variant);
    }

    // ② 解析媒体播放列表
    final _MediaPlaylist pl = _parseMediaPlaylist(mediaUri, mediaText);
    if (pl.segments.isEmpty) {
      throw const _DownloadError('播放列表没有任何分片');
    }
    _emit('[OP-VIDEO] 📦 init=${pl.mapUri?.pathSegments.last ?? "(无)"} '
        '分片=${pl.segments.length}');

    // ③ 分片下载 → 顺序写 .part
    final File part = File('${dest.path}.part');
    RandomAccessFile? raf;
    int written = 0;
    try {
      await part.parent.create(recursive: true);
      raf = await part.open(mode: FileMode.write);
      written = 0;

      // init 段（ftyp + moov）：Media Foundation 要靠它初始化解码器
      if (pl.mapUri != null) {
        final Uint8ListBytes init =
            await _getBytes(pl.mapUri!, rangeStart: null, rangeLength: null);
        await raf.writeFrom(init.bytes);
        written += init.bytes.length;
      }

      final int total = pl.segments.length;
      for (int i = 0; i < total; i += concurrency) {
        final int end = (i + concurrency) > total ? total : i + concurrency;
        final List<Future<Uint8ListBytes>> batch = <Future<Uint8ListBytes>>[
          for (int k = i; k < end; k++)
            _getBytes(
              pl.segments[k].uri,
              rangeStart: pl.segments[k].rangeStart,
              rangeLength: pl.segments[k].rangeLength,
            ),
        ];
        final List<Uint8ListBytes> done =
            await Future.wait<Uint8ListBytes>(batch);

        // 🔴 必须按**分片顺序**写盘：fMP4 的 moof/mdat 顺序即播放顺序，
        //    并发只是下载手段，落盘顺序错了视频会乱帧。
        for (final Uint8ListBytes b in done) {
          if (b.bytes.isEmpty) throw const _DownloadError('分片内容为空');
          written += b.bytes.length;
          if (written > maxBytes) {
            throw const _SizeLimitExceeded();
          }
          await raf.writeFrom(b.bytes);
        }
        onProgress?.call(end, total);
      }
      await raf.flush();
      await raf.close();
      raf = null;

      // ④ 产物校验：第 4..8 字节必须是 `ftyp`（`BpmBackdropMedia.looksLikeMp4` 同款判据）
      if (written < 1024 * 1024) {
        throw _DownloadError('产物过小（$written B）');
      }
      if (!await _looksLikeMp4(part)) {
        throw const _DownloadError('产物不是合法 mp4（缺 ftyp）');
      }

      // ⑤ 原子改名（Windows 上 rename 不能覆盖已存在文件 → 先删）
      if (await dest.exists()) await _deleteQuietly(dest);
      await part.rename(dest.path);
      _emit('[OP-VIDEO] ✅ 已落盘 ${dest.path} '
          '（${(written / 1024 / 1024).toStringAsFixed(2)} MB, '
          '$total 片, appid=$appId）');
      return _Downloaded(bytes: written, segments: total);
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      await _deleteQuietly(part);
      rethrow;
    }
  }

  /// 解析主播放列表，返回选中的档位地址；不是主播放列表（没有 STREAM-INF）时返回 null。
  ///
  /// 选档：优先 **720p**（高度 ≤720 里最大的）；全高于 720 时取最矮的；
  /// 没有 RESOLUTION 信息时按带宽选（优先 1.5–3Mbps 区间里最小的）。
  Uri? _pickVariant(Uri masterUri, String text) {
    final List<String> lines = const LineSplitter().convert(text);
    final List<_Variant> variants = <_Variant>[];
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
      final Map<String, String> attrs = _parseAttrs(line.substring(18));
      String? uriLine;
      for (int j = i + 1; j < lines.length; j++) {
        final String cand = lines[j].trim();
        if (cand.isEmpty || cand.startsWith('#')) continue;
        uriLine = cand;
        break;
      }
      if (uriLine == null) continue;
      int height = 0;
      final String res = attrs['RESOLUTION'] ?? '';
      final int x = res.indexOf('x');
      if (x > 0) height = int.tryParse(res.substring(x + 1)) ?? 0;
      final int bandwidth =
          int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
      variants.add(_Variant(
        uri: masterUri.resolve(uriLine),
        height: height,
        bandwidth: bandwidth,
      ));
    }
    if (variants.isEmpty) return null;

    final List<_Variant> withHeight =
        variants.where((_Variant v) => v.height > 0).toList();
    if (withHeight.isNotEmpty) {
      final List<_Variant> le720 =
          withHeight.where((_Variant v) => v.height <= 720).toList();
      if (le720.isNotEmpty) {
        le720.sort((_Variant a, _Variant b) => b.height.compareTo(a.height));
        return le720.first.uri;
      }
      withHeight.sort((_Variant a, _Variant b) => a.height.compareTo(b.height));
      return withHeight.first.uri;
    }

    variants.sort((_Variant a, _Variant b) => a.bandwidth.compareTo(b.bandwidth));
    // 目标 2.6Mbps（720p 档实测值）：取不超过 3.2Mbps 的最大档，否则取最低档
    for (int i = variants.length - 1; i >= 0; i--) {
      if (variants[i].bandwidth > 0 && variants[i].bandwidth <= 3200000) {
        return variants[i].uri;
      }
    }
    return variants.first.uri;
  }

  /// 解析媒体播放列表（`#EXT-X-MAP` + 分片 + 可选 BYTERANGE）。
  _MediaPlaylist _parseMediaPlaylist(Uri baseUri, String text) {
    final List<String> lines = const LineSplitter().convert(text);
    Uri? mapUri;
    final List<_Segment> segments = <_Segment>[];
    int? pendingRangeLength;
    int? pendingRangeStart;
    int cursor = 0; // BYTERANGE 省略 offset 时接上一片末尾

    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-MAP:')) {
        final Map<String, String> attrs = _parseAttrs(line.substring(11));
        final String uri = attrs['URI'] ?? '';
        if (uri.isNotEmpty) mapUri = baseUri.resolve(uri);
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final String spec = line.substring(17).trim();
        final int at = spec.indexOf('@');
        if (at >= 0) {
          pendingRangeLength = int.tryParse(spec.substring(0, at));
          pendingRangeStart = int.tryParse(spec.substring(at + 1));
        } else {
          pendingRangeLength = int.tryParse(spec);
          pendingRangeStart = null;
        }
        continue;
      }
      if (line.startsWith('#')) continue;

      // 分片 URI
      final Uri segUri = baseUri.resolve(line);
      int? start = pendingRangeStart;
      if (pendingRangeLength != null && start == null) start = cursor;
      segments.add(_Segment(
        uri: segUri,
        rangeStart: start,
        rangeLength: pendingRangeLength,
      ));
      if (pendingRangeLength != null) {
        cursor = (start ?? 0) + pendingRangeLength;
      }
      pendingRangeLength = null;
      pendingRangeStart = null;
    }

    return _MediaPlaylist(mapUri: mapUri, segments: segments);
  }

  /// 解析 `KEY=VALUE,KEY="VALUE"` 形态的属性串。
  static Map<String, String> _parseAttrs(String raw) {
    final Map<String, String> out = <String, String>{};
    // 引号内的逗号不能当分隔符（URI 属性里可能带查询串）
    final StringBuffer cur = StringBuffer();
    final List<String> parts = <String>[];
    bool inQuote = false;
    for (final int code in raw.runes) {
      if (code == 0x22) {
        inQuote = !inQuote;
        cur.writeCharCode(code);
        continue;
      }
      if (code == 0x2C && !inQuote) {
        parts.add(cur.toString());
        cur.clear();
        continue;
      }
      cur.writeCharCode(code);
    }
    if (cur.isNotEmpty) parts.add(cur.toString());

    for (final String p in parts) {
      final int eq = p.indexOf('=');
      if (eq <= 0) continue;
      final String k = p.substring(0, eq).trim().toUpperCase();
      String v = p.substring(eq + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      out[k] = v;
    }
    return out;
  }

  // ===========================================================================
  // HTTP
  // ===========================================================================

  HttpClient _buildClient() {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..userAgent = _ua
      ..idleTimeout = const Duration(seconds: 10);
    if (proxy.isNotEmpty) {
      client.findProxy = (Uri _) => 'PROXY $proxy';
    }
    // proxy 为空时不覆写 findProxy ⇒ 继承全局 HttpOverrides 注入的统一策略
    return client;
  }

  Future<String> _getText(Uri uri) async {
    final Uint8ListBytes bytes =
        await _getBytes(uri, rangeStart: null, rangeLength: null);
    return utf8.decode(bytes.bytes, allowMalformed: true);
  }

  /// 下载一个 URL（可带 Range），失败按 [maxSegmentAttempts] 重试。
  Future<Uint8ListBytes> _getBytes(
    Uri uri, {
    required int? rangeStart,
    required int? rangeLength,
  }) async {
    Object? lastError;
    for (int attempt = 1; attempt <= maxSegmentAttempts; attempt++) {
      try {
        return await _getBytesOnce(uri, rangeStart, rangeLength);
      } catch (e) {
        lastError = e;
        if (attempt < maxSegmentAttempts) {
          // 400ms → 900ms 退避；实测连接级失败（000）一次重试就能过
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt + 100));
        }
      }
    }
    throw _DownloadError('$uri 重试 $maxSegmentAttempts 次仍失败: $lastError');
  }

  Future<Uint8ListBytes> _getBytesOnce(
    Uri uri,
    int? rangeStart,
    int? rangeLength,
  ) async {
    final HttpClient? client = _client;
    if (client == null) throw StateError('HTTP client 已关闭');

    final HttpClientRequest req =
        await client.getUrl(uri).timeout(segmentTimeout);
    req.headers.set(HttpHeaders.userAgentHeader, _ua);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (rangeLength != null) {
      final int start = rangeStart ?? 0;
      req.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-${start + rangeLength - 1}',
      );
    }
    final HttpClientResponse res = await req.close().timeout(segmentTimeout);
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.drain<void>();
      throw _DownloadError('HTTP ${res.statusCode}（$uri）');
    }
    final List<int> raw = await res
        .fold<List<int>>(<int>[], (List<int> acc, List<int> chunk) {
      acc.addAll(chunk);
      return acc;
    }).timeout(segmentTimeout);
    return Uint8ListBytes(raw);
  }

  // ===========================================================================
  // 校验 / 清理
  // ===========================================================================

  /// 轻量 mp4 文件头校验：第 4..8 字节为 `ftyp` box 类型。
  Future<bool> _looksLikeMp4(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final List<int> head = await raf.read(12);
      if (head.length < 12) return false;
      return String.fromCharCodes(head.sublist(4, 8)) == 'ftyp';
    } catch (_) {
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

// ===========================================================================
// 内部数据类型
// ===========================================================================

/// 字节容器（避免在纯 Dart 里依赖 `dart:typed_data` 之外的东西，同时给出长度）。
class Uint8ListBytes {
  Uint8ListBytes(List<int> raw) : bytes = raw is Uint8List ? raw : _toU8(raw);

  final Uint8List bytes;

  static Uint8List _toU8(List<int> raw) {
    final Uint8List out = Uint8List(raw.length);
    out.setRange(0, raw.length, raw);
    return out;
  }
}

class _Variant {
  const _Variant({
    required this.uri,
    required this.height,
    required this.bandwidth,
  });

  final Uri uri;
  final int height;
  final int bandwidth;
}

class _Segment {
  const _Segment({
    required this.uri,
    required this.rangeStart,
    required this.rangeLength,
  });

  final Uri uri;
  final int? rangeStart;
  final int? rangeLength;
}

class _MediaPlaylist {
  const _MediaPlaylist({required this.mapUri, required this.segments});

  final Uri? mapUri;
  final List<_Segment> segments;
}

class _Downloaded {
  const _Downloaded({required this.bytes, required this.segments});

  final int bytes;
  final int segments;
}

class _DownloadError implements Exception {
  const _DownloadError(this.message);

  final String message;

  @override
  String toString() => 'DownloadError: $message';
}

class _SizeLimitExceeded implements Exception {
  const _SizeLimitExceeded();

  @override
  String toString() => 'SizeLimitExceeded: 超过体积上限';
}
