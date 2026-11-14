import 'dart:io' show Platform;

/// 图片防盗链（Referer / UA 白名单）适配层
///
/// **背景（2026-11-04 实测，非推测）**：2Dfan 的图床 `img.achost.top`
/// 采用 **Referer 白名单**校验，且失败时返回 **404**（不是 403，极易被
/// 误判成"图片真的不存在"）：
///
/// | 请求 | 响应 |
/// |---|---|
/// | 不带 Referer | 404 |
/// | `Referer: https://example.com/` | 404 |
/// | `Referer: https://2dfmax.top/`（任一 2dfan 系域名） | 200 |
///
/// 而 Flutter 侧 `CachedNetworkImage` / `Image.network` 默认**不带 Referer**，
/// 所以 2Dfan 的封面/横幅在我们这里必然 404 —— 这是用户反馈
/// "2Dfan 的图片经常加载失败"的根因（同源写法在浏览器里正常，
/// 在同行项目里正常，只有我们的 App 里失败）。
///
/// **注入点只有两处**（保持单点，避免散落到十几个 UI 文件）：
/// 1. [PortableImageCacheManager] 的 `fileService`
///    —— 所有 `CachedNetworkImage` 与 `NsfwImage` 都经过它；
/// 2. `CoverDownloadService.downloadCover()` 的落盘下载。
///
/// 新增需要防盗链适配的源时，只在 [_hostReferers] 里加一行即可。
class ImageReferer {
  ImageReferer._();

  /// 图床 host（按后缀匹配）→ 该站接受的 Referer
  ///
  /// 2Dfan 的图床挂在 `achost.top` 下（`img.achost.top`），
  /// 白名单接受任意 2dfan 系域名，这里固定用主镜像 `2dfmax.top`
  /// （`2dfan.com` 在部分网络不可达，用它做 Referer 虽然也能过，
  /// 但换成可达域名更稳）。
  static const Map<String, String> _hostReferers = {
    'achost.top': 'https://2dfmax.top/',
  };

  /// 浏览器 UA：部分图床在卡 Referer 的同时也卡 UA
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 该 URL 需要的 Referer；不需要防盗链适配时返回 null
  static String? refererFor(String url) {
    final host = _hostOf(url);
    if (host.isEmpty) return null;
    for (final entry in _hostReferers.entries) {
      if (host == entry.key || host.endsWith('.${entry.key}')) {
        return entry.value;
      }
    }
    return null;
  }

  /// 该 URL 需要附加的请求头（不需要适配时返回空 Map）
  ///
  /// 返回值可直接合并进 `CachedNetworkImage.httpHeaders` 或 dio 的 headers。
  static Map<String, String> headersFor(String url) {
    final referer = refererFor(url);
    if (referer == null) return const {};
    return {'Referer': referer, 'User-Agent': browserUserAgent};
  }

  /// 是否属于需要防盗链适配的图床
  static bool needsReferer(String url) => refererFor(url) != null;

  static String _hostOf(String url) {
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme) return '';
      return uri.host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

  /// 供调试日志：当前平台标识（保留占位，移动端如需区分可在此扩展）
  static String get platformTag => Platform.operatingSystem;
}
