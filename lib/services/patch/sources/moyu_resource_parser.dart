import '../../../models/patch_resource.dart';

/// 鲲资源页 HTML 解析（纯函数，无网络、无 Flutter 依赖）。
///
/// 为什么单独成一个文件：**这是整套方案里最脆的一环**。
/// 鲲的直链不在 v2 API 里（`/v2/moyu/resources/{id}/file` 要 `moyu:files`
/// scope），只存在于 `www.moyu.moe/resource/{id}` 的 SSR HTML 中。
/// 站点一改版就失效 ⇒ 必须能让探针离线跑、能一眼看出"是解析坏了还是网络坏了"。
///
/// 实测页面结构（2026-11-10，`resource/11425` 与 `resource/9659`）：
/// 每个可下载项都是同一个卡片模板：
/// ```html
/// <a href="https://dl.imoe.uk/moyu/xxxx.zip"
///    target="_blank" rel="noopener noreferrer"
///    class="hover:text-success group flex min-w-0 items-center gap-3 ...">
///   <span>...图标...</span>
///   <span class="min-w-0 flex-1 truncate text-sm">https://dl.imoe.uk/...</span>
/// </a>
/// ```
/// 网盘型是同一模板，只是 href 变成 `https://pan.quark.cn/s/xxx?pwd=kUz4`。
/// ⇒ **提取码就内嵌在 URL 的 `pwd` 参数里**，不需要额外解析页面文案。

/// 页面里识别出的一个下载入口。
class PatchDownloadLink {
  final String url;

  /// [PatchDelivery.direct] 或 [PatchDelivery.netdisk]
  final PatchDelivery delivery;

  /// 网盘提取码（从 URL 的 `pwd` / `password` / `code` 参数取；直链为 null）
  final String? extractCode;

  /// 网盘服务商中文名（百度网盘 / 夸克网盘…）；直链为 null
  final String? provider;

  const PatchDownloadLink({
    required this.url,
    required this.delivery,
    this.extractCode,
    this.provider,
  });

  /// 展示用标签：网盘用服务商名，直链用域名
  String get label {
    if (provider != null && provider!.isNotEmpty) return provider!;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? '直链' : host;
  }

  /// 转成模型层的统一入口
  PatchDeliveryLink toModel() => PatchDeliveryLink(
        url: url,
        kind: delivery,
        label: label,
        extractCode: extractCode,
        provider: provider,
      );

  @override
  String toString() => '${delivery.name}:$url';
}

/// HTML → 下载入口列表。
abstract final class MoyuResourceParser {
  /// 下载块卡片的特征 class（实测）
  static const String _cardClassHint = 'hover:text-success';

  /// 已知的直连托管域
  static const String _directHost = 'dl.imoe.uk';

  /// 已知的网盘域（含镜像）
  static const List<String> _netdiskHosts = <String>[
    'pan.quark.cn',
    'quark.cn',
    'pan.baidu.com',
    'lanzou',
    '123pan.com',
    '123684.com',
    '123865.com',
    'mega.nz',
    'aliyundrive.com',
    'alipan.com',
    'drive.uc.cn',
  ];

  /// 网盘域 → 中文名（顺序：先具体后泛化，`pan.quark.cn` 必须排在 `quark.cn` 前）
  static const List<List<String>> _netdiskProviders = <List<String>>[
    <String>['pan.quark.cn', '夸克网盘'],
    <String>['quark.cn', '夸克网盘'],
    <String>['pan.baidu.com', '百度网盘'],
    <String>['lanzou', '蓝奏云'],
    <String>['123pan.com', '123 网盘'],
    <String>['123684.com', '123 网盘'],
    <String>['123865.com', '123 网盘'],
    <String>['mega.nz', 'MEGA'],
    <String>['aliyundrive.com', '阿里云盘'],
    <String>['alipan.com', '阿里云盘'],
    <String>['drive.uc.cn', 'UC 网盘'],
  ];

  /// 解析出全部下载入口（已按 URL 去重；直链排在网盘前面）。
  ///
  /// 🔴 **双通道**：先用"卡片 class"精确定位；若一条都没命中（站点改版把
  /// class 名换了），退回"全页 href 按域名白名单筛"。两通道都空 ⇒ 返回空列表，
  /// 调用方据此把 delivery 降级成 [PatchDelivery.web]（只跳转），**不算失败**。
  static List<PatchDownloadLink> parseDownloadLinks(String html) {
    if (html.trim().isEmpty) return const <PatchDownloadLink>[];

    final found = <String, PatchDownloadLink>{};

    // ---- 通道 1：精确卡片（class 含 hover:text-success 的 <a>）----
    for (final m in RegExp(r'<a\b[^>]*>', caseSensitive: false).allMatches(html)) {
      final tag = m.group(0)!;
      if (!tag.contains(_cardClassHint)) continue;
      final href = _hrefOf(tag);
      if (href == null) continue;
      final link = _classify(href);
      if (link != null) found[link.url] = link;
    }

    // ---- 通道 2：兜底（全页 href 白名单）----
    if (found.isEmpty) {
      for (final m in RegExp(r'href="([^"]+)"', caseSensitive: false)
          .allMatches(html)) {
        final link = _classify(m.group(1)!);
        if (link != null) found[link.url] = link;
      }
    }

    // 通道 2 也可能只漏一部分（比如页面既有卡片又有别处硬写的链接）
    // ⇒ 直链单独再兜一次：直链最有价值，宁可多扫一遍
    if (!found.values.any((l) => l.delivery == PatchDelivery.direct)) {
      final directUrlRe = RegExp(
        r'''https?://''' + RegExp.escape(_directHost) + r'''/[^\s"'<>\\]+''',
        caseSensitive: false,
      );
      for (final m in directUrlRe.allMatches(html)) {
        final link = _classify(m.group(0)!);
        if (link != null) found[link.url] = link;
      }
    }

    // 排序：直链优先（有直连文件就该首选软件内下载），同类**保持页面原始顺序**。
    // 🔴 不要按 URL 字典序排 —— 那会把「百度」排到「夸克」前面，
    //    与用户在页面上看到的顺序不一致，显得随机。
    final all = found.values.toList();
    final directs = all.where((l) => l.delivery == PatchDelivery.direct);
    final netdisks = all.where((l) => l.delivery == PatchDelivery.netdisk);
    return <PatchDownloadLink>[...directs, ...netdisks];
  }

  /// 从页面里挑出最佳投递方式。
  ///
  /// 返回 (delivery, directUrl, netdiskUrl, extractCode) 的便捷封装 ——
  /// 供 [MoyuPatchSource] 直接 `copyWith` 到模型上。
  static PatchDeliveryInfo resolveDelivery(String html) {
    final links = parseDownloadLinks(html);
    if (links.isEmpty) {
      return const PatchDeliveryInfo(delivery: PatchDelivery.web);
    }
    // 🔴 全部入口都带上：页面上「共 N 个」经常是多个直链 / 多个网盘并存，
    //    只留第一个会让用户在详情里看不到其余的
    final all = links.map((l) => l.toModel()).toList(growable: false);

    final directLinks =
        links.where((l) => l.delivery == PatchDelivery.direct).toList();
    if (directLinks.isNotEmpty && directLinks.first.url.isNotEmpty) {
      return PatchDeliveryInfo(
        delivery: PatchDelivery.direct,
        directUrl: directLinks.first.url,
        links: all,
      );
    }
    final netdiskLinks =
        links.where((l) => l.delivery == PatchDelivery.netdisk).toList();
    if (netdiskLinks.isNotEmpty) {
      return PatchDeliveryInfo(
        delivery: PatchDelivery.netdisk,
        netdiskUrl: netdiskLinks.first.url,
        extractCode: netdiskLinks.first.extractCode,
        links: all,
      );
    }
    return const PatchDeliveryInfo(delivery: PatchDelivery.web);
  }

  // ---------------- 内部 ----------------

  static String? _hrefOf(String tag) {
    final m = RegExp(r'''href\s*=\s*["']([^"']+)["']''', caseSensitive: false)
        .firstMatch(tag);
    final raw = m?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// URL 归类；不认识的域返回 null（站内链接、评论区链接都该被忽略）
  static PatchDownloadLink? _classify(String rawUrl) {
    final url = _decodeEntities(rawUrl.trim());
    if (url.isEmpty) return null;
    final lower = url.toLowerCase();

    if (lower.contains(_directHost)) {
      return PatchDownloadLink(url: url, delivery: PatchDelivery.direct);
    }
    for (final host in _netdiskHosts) {
      if (lower.contains(host)) {
        return PatchDownloadLink(
          url: url,
          delivery: PatchDelivery.netdisk,
          extractCode: _extractCode(url),
          provider: _providerOf(lower),
        );
      }
    }
    return null;
  }

  /// 网盘中文名（认不出返回 null，UI 会退回显示域名）
  static String? _providerOf(String lowerUrl) {
    for (final pair in _netdiskProviders) {
      if (lowerUrl.contains(pair[0])) return pair[1];
    }
    return null;
  }

  /// 从 URL 查询串里取提取码（`?pwd=kUz4` / `&password=16zl` / `?code=ab12`）
  static String? _extractCode(String url) {
    final m = RegExp(
      r'[?&](?:pwd|password|code|passcode)=([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(url);
    final code = m?.group(1)?.trim();
    if (code == null || code.isEmpty) return null;
    return code;
  }

  /// HTML 实体解码（href 里实测会出现 `&amp;`）
  static String _decodeEntities(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }
}

/// [MoyuResourceParser.resolveDelivery] 的返回值。
class PatchDeliveryInfo {
  final PatchDelivery delivery;
  final String? directUrl;
  final String? netdiskUrl;
  final String? extractCode;

  /// 页面上识别出的**全部**入口（直链在前、网盘在后，各自保持页面顺序）
  final List<PatchDeliveryLink> links;

  const PatchDeliveryInfo({
    required this.delivery,
    this.directUrl,
    this.netdiskUrl,
    this.extractCode,
    this.links = const <PatchDeliveryLink>[],
  });

  bool get hasAny => directUrl != null || netdiskUrl != null;
}

/// NextMoe v2 资源 JSON → [PatchResource] 的映射（纯函数，无网络）。
///
/// 单独抽出来的理由：[MoyuPatchSource] 依赖 `luna_metadata_sdk`，而 SDK 会拉
/// `package:flutter/foundation.dart` ⇒ 纯 Dart 探针跑不了那个文件。
/// 把映射逻辑放在这里，`dart run dev_probe/patch_station_probe.dart` 就能
/// 直接对着**真实 API 响应片段**验证字段映射，不必起 Flutter。
abstract final class MoyuV2Mapper {
  /// 从 `/v2/moyu/patches/{id}/resources` 的单条 item 构造资源。
  ///
  /// [patchTypes] 是 patch 级 `type`（资源自身 `type` 为空时用它兜底）。
  static PatchResource toResource(
    Map<String, dynamic> json, {
    required String patchId,
    String gameTitle = '',
    List<String> patchTypes = const <String>[],
  }) {
    final id = _str(json['id']).trim();
    final name = _str(json['name']).trim();

    var types = _strList(json['type']);
    var kinds = PatchKind.fromRawList(types);
    // 资源自身没标类型时退回 patch 级类型（实测 name 与 type 都可能为空）
    if (types.isEmpty && patchTypes.isNotEmpty) {
      types = patchTypes;
      kinds = PatchKind.fromRawList(patchTypes);
    }
    // 🔴 kinds 必须非空：UI 会取 `kinds.first` 决定图标/颜色，
    //    空列表会让卡片直接抛 Bad state: No element。
    if (kinds.isEmpty) kinds = const <PatchKind>[PatchKind.other];

    final fallbackName =
        kinds.first == PatchKind.other ? '资源' : kinds.first.displayName;

    return PatchResource(
      key: '${PatchSite.kunlun.tag}:$id',
      site: PatchSite.kunlun,
      id: id,
      groupId: patchId,
      // 🔴 实测 `name` 可能为空串（如 resource/9659）——
      //    不许留空标题，否则卡片是一行空白；用「类型 #id」兜底。
      title: name.isEmpty ? '$fallbackName #$id' : name,
      gameTitle: gameTitle,
      kinds: kinds,
      rawKinds: types,
      languages: _normalizeLanguages(_strList(json['language'])),
      platforms: _strList(json['platform']),
      // 实测 `size` 形如 "10kb" / "2GB"（无空格），解析器已兼容
      sizeBytes: parseHumanSizeToBytes(_str(json['size'])),
      sha256: _str(json['hash']),
      note: _str(json['note']),
      webUrl: _str(json['web_url']),
      // 直链是后置补出来的，这里一律 web
      delivery: PatchDelivery.web,
      downloadCount: _int(json['download_count']),
      updatedAt: DateTime.tryParse(_str(json['updated_at'])),
    );
  }

  /// v2 响应是 `{"object":"list","items":[...]}`（无信封）
  static List<Map<String, dynamic>> itemsOf(dynamic data) {
    if (data is! Map) return const <Map<String, dynamic>>[];
    final items = data['items'];
    if (items is! List) return const <Map<String, dynamic>>[];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  static String _str(dynamic v) => v == null ? '' : v.toString();

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(_str(v)) ?? 0;
  }

  static List<String> _strList(dynamic v) {
    if (v is! List) return const <String>[];
    return v
        .map((e) => _str(e).trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  /// 语言归一化：`zh-Hans` / `zh-Hant` 保留大小写（下游 UI 直接匹配这两个值），
  /// 其余小写化
  static List<String> _normalizeLanguages(List<String> raw) {
    final out = <String>[];
    for (final r in raw) {
      final s = r.trim();
      if (s.isEmpty) continue;
      final lower = s.toLowerCase();
      final v = (lower == 'zh-hans' || lower == 'zh-hant') ? s : lower;
      if (!out.contains(v)) out.add(v);
    }
    return out;
  }
}
