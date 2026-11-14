import 'dart:async';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../../models/patch_resource.dart';
import '../patch_source.dart';

/// 2DFan 补丁源（HTML 抓取）。
///
/// ## 能力
///
/// - **只能按关键词检索**：`/search?keyword=` → 取前 [kMaxSubjects] 个作品
///   → 逐个 `/subjects/{id}/downloads`。2DFan 没有 id 体系，标题是唯一入口。
/// - **一期只能跳转**：单条补丁页实测是「登录下载」，无公开直链。
///   ⇒ 所有条目 `delivery = web`，用户点开在浏览器里看（要账号/积分）。
///
/// ## 镜像策略（照抄 `TwoDFanService` 的三件套，不另起炉灶）
///
/// 1. **镜像优先、`2dfan.com` 垫底**：主域被污染且"半通"，曾把整会话搜索锁死
/// 2. **运行期回退**：单个请求失败立刻换下一个域，不依赖一次性探测的运气
/// 3. **全失败软冷却 2 分钟**：⛔ 不要"永久置空串"，那会让一次抖动毁掉整会话
///
/// ## DOM 锚点（2026-11-10 实测 `2dfmax.top/subjects/3100/downloads`）
///
/// ```html
/// <div class="download-card">
///   <h4 class="download-card-title"><a href="/downloads/38989">标题</a></h4>
///   <span class="download-card-kind download-card-kind--success">无码补丁</span>
///   <span class="uploader-name">作者</span>
///   <time class="download-card-date" datetime="2025-10-16T11:54:27+08:00">…</time>
///   <span class="download-card-size">882.7 MB</span>
///   <p class="download-card-excerpt">简介…</p>
/// </div>
/// ```
class TwoDFanPatchSource implements PatchSource {
  /// 一次检索最多展开几个作品（参考项目 GalGear 用的也是 5）
  static const int kMaxSubjects = 5;

  /// 展开作品详情页的并发数（站点是 HTML 站，别打太狠）
  static const int _detailConcurrency = 2;

  /// 全部镜像失败后的软冷却（不是永久禁用！）
  static const Duration kAllFailedCooldown = Duration(minutes: 2);

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static String? _resolvedBase;
  static DateTime? _cooldownUntil;

  final Dio _dio;

  TwoDFanPatchSource({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'User-Agent': _ua,
                'Accept': 'text/html,application/xhtml+xml',
              },
            )) {
    applyProxyConfig(null, _dio);
  }

  @override
  PatchSite get site => PatchSite.twoDfan;

  @override
  PatchSourceCapabilities get capabilities => const PatchSourceCapabilities(
        byWorkId: false,
        byKeyword: true,
        byGameId: false,
        // 一期：下载必须登录 + 积分 ⇒ 只能跳转
        directDownload: false,
      );

  @override
  void dispose() {}

  @override
  Future<PatchSourceResult> search(PatchQueryContext ctx) async {
    final keyword = ctx.effectiveKeyword;
    if (keyword.isEmpty) {
      return const PatchSourceResult.failed('没有可用的检索关键词');
    }

    try {
      final base = await _ensureBase();
      if (base == null) {
        return const PatchSourceResult.failed('2DFan 所有镜像都不可达');
      }

      final subjectIds = await _searchSubjectIds(base, keyword);
      if (subjectIds.isEmpty) {
        return const PatchSourceResult.empty();
      }

      final perSubject = await _mapLimited<String, List<PatchResource>>(
        subjectIds.take(kMaxSubjects).toList(),
        _detailConcurrency,
        (sid) => _fetchDownloads(base, sid, keyword),
      );

      final all = perSubject.expand((e) => e).toList();
      if (all.isEmpty) return const PatchSourceResult.empty();
      return PatchSourceResult(resources: all);
    } on _FanUnavailable catch (e) {
      return PatchSourceResult.failed(e.message);
    } catch (e) {
      return PatchSourceResult.failed('2DFan 检索异常：$e');
    }
  }

  // ---------------- 网络 ----------------

  /// 解析可用镜像（运行期回退 + 软冷却）
  Future<String?> _ensureBase() async {
    final cooldown = _cooldownUntil;
    if (cooldown != null && DateTime.now().isBefore(cooldown)) {
      return null;
    }
    final cached = _resolvedBase;
    if (cached != null) {
      // 缓存的镜像也可能刚挂：轻量探测一次
      if (await _probe(cached)) return cached;
      _resolvedBase = null;
    }

    for (final domain in TwoDFanService.kFanDomains) {
      if (await _probe(domain)) {
        _resolvedBase = domain;
        _cooldownUntil = null;
        return domain;
      }
    }
    _cooldownUntil = DateTime.now().add(kAllFailedCooldown);
    return null;
  }

  Future<bool> _probe(String base) async {
    try {
      final resp = await _dio.get<String>(
        '$base/',
        options: Options(responseType: ResponseType.plain),
      );
      final body = resp.data ?? '';
      // 🔴 只判 200 不够：主域会返回 200 的风控/占位页。
      //    必须校验页面里真的有站内特征串（与 TwoDFanService 的探测口径一致）。
      return body.contains('2dfan') || body.contains('subject') ||
          body.contains('download');
    } catch (_) {
      return false;
    }
  }

  /// 搜索页 → 前 N 个 `subjectId`
  Future<List<String>> _searchSubjectIds(String base, String keyword) async {
    final html = await _getHtml(base, '/search', query: {'keyword': keyword});
    final doc = html_parser.parse(html);

    var cards = doc.querySelectorAll('#subject-list .subject-card');
    if (cards.isEmpty) cards = doc.querySelectorAll('.subject-card');
    if (cards.isEmpty) {
      // 再兜底：直接从链接里抠 /subjects/{id}
      final ids = <String>[];
      for (final a in doc.querySelectorAll('a[href*="/subjects/"]')) {
        final href = a.attributes['href'] ?? '';
        final m = RegExp(r'/subjects/(\d+)').firstMatch(href);
        final id = m?.group(1);
        if (id != null && !ids.contains(id)) ids.add(id);
      }
      return ids;
    }

    final ids = <String>[];
    for (final card in cards) {
      final anchor = card.querySelector('.subject-card-title a') ??
          card.querySelector('a[href*="/subjects/"]');
      final href = anchor?.attributes['href'] ?? '';
      final m = RegExp(r'/subjects/(\d+)').firstMatch(href);
      final id = m?.group(1);
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    return ids;
  }

  /// 作品下载页 → 补丁条目
  Future<List<PatchResource>> _fetchDownloads(
    String base,
    String subjectId,
    String keyword,
  ) async {
    try {
      final html =
          await _getHtml(base, '/subjects/$subjectId/downloads');
      final doc = html_parser.parse(html);
      final cards = doc.querySelectorAll('.download-card');
      if (cards.isEmpty) return const <PatchResource>[];

      final out = <PatchResource>[];
      for (final card in cards) {
        final anchor = card.querySelector('.download-card-title a');
        final href = anchor?.attributes['href'] ?? '';
        final idMatch = RegExp(r'/downloads/(\d+)').firstMatch(href);
        final id = idMatch?.group(1);
        if (id == null) continue;

        final title = (anchor?.text ?? '').trim();
        if (title.isEmpty) continue;

        final kindText =
            (card.querySelector('.download-card-kind')?.text ?? '').trim();
        final author =
            (card.querySelector('.uploader-name')?.text ?? '').trim();
        final sizeText =
            (card.querySelector('.download-card-size')?.text ?? '').trim();
        final dateEl = card.querySelector('time.download-card-date');
        final dateText = dateEl?.attributes['datetime'] ??
            dateEl?.attributes['title'] ??
            '';
        final excerpt =
            (card.querySelector('.download-card-excerpt')?.text ?? '').trim();

        final kinds = <PatchKind>[
          if (kindText.isNotEmpty) PatchKind.fromRaw(kindText),
        ];
        if (kinds.isEmpty) kinds.add(PatchKind.other);

        out.add(PatchResource(
          key: '${PatchSite.twoDfan.tag}:$id',
          site: PatchSite.twoDfan,
          id: id,
          title: title,
          gameTitle: keyword,
          kinds: kinds,
          rawKinds: <String>[if (kindText.isNotEmpty) kindText],
          sizeBytes: parseHumanSizeToBytes(sizeText),
          // 简介是列表页截断文本，只能当注释，不能当完整安装说明
          note: excerpt,
          webUrl: '$base/downloads/$id',
          delivery: PatchDelivery.web,
          author: author,
          updatedAt: DateTime.tryParse(dateText),
        ));
      }
      return out;
    } catch (_) {
      // 单个作品展开失败不影响其它作品（GalGear 会在这里伪造一条，我们不学）
      return const <PatchResource>[];
    }
  }

  Future<String> _getHtml(
    String base,
    String path, {
    Map<String, String>? query,
  }) async {
    try {
      final resp = await _dio.get<String>(
        '$base$path',
        queryParameters: query,
        options: Options(responseType: ResponseType.plain),
      );
      return resp.data ?? '';
    } on DioException catch (e) {
      // 运行期回退：当前镜像坏了就换一个，并把坏的从缓存里踢掉
      if (_resolvedBase == base) _resolvedBase = null;
      final next = await _ensureBase();
      if (next == null || next == base) {
        throw _FanUnavailable('2DFan 镜像不可用（${e.type.name}）');
      }
      final resp = await _dio.get<String>(
        '$next$path',
        queryParameters: query,
        options: Options(responseType: ResponseType.plain),
      );
      return resp.data ?? '';
    }
  }
}

class _FanUnavailable implements Exception {
  final String message;
  const _FanUnavailable(this.message);
}

/// 并发受限 map（同 MoyuPatchSource 内的实现，保持输入顺序）
Future<List<R>> _mapLimited<T, R>(
  List<T> input,
  int concurrency,
  Future<R> Function(T item) task,
) async {
  if (input.isEmpty) return <R>[];
  final results = List<R?>.filled(input.length, null, growable: false);
  var next = 0;

  Future<void> worker() async {
    while (true) {
      final index = next;
      if (index >= input.length) return;
      next++;
      results[index] = await task(input[index]);
    }
  }

  await Future.wait(<Future<void>>[
    for (var i = 0; i < concurrency.clamp(1, input.length); i++) worker(),
  ]);
  return results.cast<R>().toList(growable: false);
}
