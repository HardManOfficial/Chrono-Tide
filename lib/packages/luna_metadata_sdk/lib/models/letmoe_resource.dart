/// letmoe 下载资源链接面（SITE-LIBRARY 资源能力）的数据模型。
///
/// ## 端点（base `https://api.nextmoe.dev/v2/letmoe`，2026-11-13 实测）
///
/// - `GET /works/{id}/resources?nsfw=true` → 资源列表（[LetmoeResource]）
/// - `GET /resources/{id}/file` → 一条资源的全部下载方式（[LetmoeResourceFiles]）
/// - `GET /works?ids=` → 批量问哪些作品有资源（[LetmoeWorkSummary]）
///
/// ## 身份体系（重大利好，2026-11-13 curl 实测确认）
///
/// **作品 id 就是 catalog 作品 id**——与全站搜索（SITE-SEARCH）鲲命中的
/// `SiteSearchHit.siteId`、补丁站鲲源（moyu）的 `refs=catalog:<workId>`
/// 是同一个数。鲲命中查资源零映射成本。
///
/// ## 鉴权
///
/// 任意有效 `nmk_` 应用密钥即可读元数据；**下载直链/网盘链接/提取码/解压
/// 密码只在 `/file` 上给持有 `letmoe:files` scope 的密钥**——该 scope 在密钥
/// 创建时自动带上，无需勾选。
///
/// ## nsfw 契约
///
/// 列表端点缺省 `nsfw=false`（成人作品不出现在列表里，其资源单条读取 404）。
/// 我们是 Galgame 管理软件，**必须显式 `nsfw=true`**。
///
/// ## 直链时效
///
/// `/file` 的答案一律 `no-store`，每次成功都会给资源记一次下载——官方明确
/// 要求「读者点下载时再调，不要预取」。我们照办：展开某条资源的镜像时才调。
class LetmoeResource {
  const LetmoeResource({
    required this.id,
    required this.workId,
    required this.title,
    required this.type,
    this.version = '',
    this.language = const <String>[],
    this.platform = const <String>[],
    this.size = '',
    this.bytes = 0,
    this.description = '',
    this.providers = const <String>[],
    this.directDownload = false,
    this.mirrorCount = 0,
    this.webUrl = '',
  });

  /// 资源 id（十进制字符串；`/resources/{id}/file` 用它取下载方式）
  final String id;

  /// 所属作品 id（= catalog work id）
  final String workId;

  /// 资源标题（如「丸子与银河龙 Windows 电脑版 / 安卓手机版 简体中文游戏本体资源下载」）
  final String title;

  /// 资源类型：`game`（游戏本体）/ 补丁等
  final String type;

  /// 适用游戏版本（常为空）
  final String version;

  /// 语言标签（如 `zh-cn`）
  final List<String> language;

  /// 平台标签（`win` / `and` / …）
  final List<String> platform;

  /// 人类可读体积（"9.8 GB"）
  final String size;

  /// 精确字节数（0 = 未知）
  final int bytes;

  /// 资源说明（markdown；常含解压方法/解压密码等关键信息）
  final String description;

  /// 网盘渠道（`baidu` / `quark` / …）
  final List<String> providers;

  /// 是否有 letmoe 托管直链（true = 「获取」可软件内下载）
  final bool directDownload;

  /// 是否有**真网盘**渠道。
  ///
  /// 🔴 `providers` 里会出现占位值 `direct`（纯直链资源就是 `['direct']`），
  /// 它不是网盘。2026-11-14 实测 work 2222 的资源 8205 即 `['direct']`——
  /// 若按「providers 非空」判定，这类资源会被「分享」模式误收，展开却一条
  /// 网盘链接都没有。
  bool get hasNetdiskProviders => providers.any((p) {
        final v = p.trim().toLowerCase();
        return v.isNotEmpty && v != 'direct';
      });

  /// 纯直链资源（只有托管直链、没有任何网盘渠道）
  bool get isDirectOnly => directDownload && !hasNetdiskProviders;

  /// 镜像数（提示「N 个下载方式」）
  final int mirrorCount;

  /// letmoe 网页端资源页直链（兜底外跳）
  final String webUrl;

  static LetmoeResource fromJson(Map<String, dynamic> j) {
    String s(String k, [String d = '']) {
      final v = j[k];
      return v == null ? d : v.toString();
    }

    List<String> list(String k) {
      final v = j[k];
      if (v is! List) return const <String>[];
      return v.map((e) => e.toString()).toList();
    }

    return LetmoeResource(
      id: s('id'),
      workId: s('work_id'),
      title: s('title'),
      type: s('type', 'game'),
      version: s('version'),
      language: list('language'),
      platform: list('platform'),
      size: s('size'),
      bytes: (j['bytes'] is num) ? (j['bytes'] as num).toInt() : 0,
      description: s('description'),
      providers: list('providers'),
      directDownload: j['direct_download'] == true,
      mirrorCount: (j['mirror_count'] is num)
          ? (j['mirror_count'] as num).toInt()
          : 0,
      webUrl: s('web_url'),
    );
  }

  /// 是否游戏本体资源（补丁走补丁站，这里只展示 game；其他类型不隐藏）
  bool get isGame => type == 'game';
}

/// 一条资源的**全部下载方式**（`GET /resources/{id}/file` 响应）。
class LetmoeResourceFiles {
  const LetmoeResourceFiles({
    required this.resourceId,
    this.mirrors = const <LetmoeMirror>[],
    this.composites = const <LetmoeMirror>[],
  });

  final String resourceId;

  /// 镜像列表：letmoe 托管直链（kind=hosted）+ 外部网盘（kind=external_link）
  final List<LetmoeMirror> mirrors;

  /// 与 moyu 补丁合并的下载（**组合包**：本体 + 汉化补丁一步到位）。
  ///
  /// 🔴 2026-11-14 实测纠正：组合包**同样是 letmoe 托管直链**
  /// （`https://dl.imoe.uk/c/letmoe/<hash>.zip`，带 `filename` / `bytes`），
  /// 只是响应里**没有 `kind` 字段**。此前依赖 `kind` 的兜底值（`external_link`）
  /// 把它误判成网盘——塞进「分享」、按「打开网盘」还会外跳一个 zip 文件。
  /// 现在在 [fromJson] 里显式按 `hosted` 解析。
  final List<LetmoeMirror> composites;

  static LetmoeResourceFiles fromJson(Map<String, dynamic> j) {
    String s(String k, [String d = '']) {
      final v = j[k];
      return v == null ? d : v.toString();
    }

    List<LetmoeMirror> parse(String k, {String defaultKind = 'external_link'}) {
      final v = j[k];
      if (v is! List) return const <LetmoeMirror>[];
      return v
          .whereType<Map>()
          .map((m) => LetmoeMirror.fromJson(
                Map<String, dynamic>.from(m),
                defaultKind: defaultKind,
              ))
          .toList();
    }

    return LetmoeResourceFiles(
      resourceId: s('resource_id'),
      mirrors: parse('mirrors'),
      // composites 不给 kind，但它是托管直链（见字段注释）
      composites: parse('composites', defaultKind: 'hosted'),
    );
  }

  /// 是否有软件内可直接下载的托管直链
  bool get hasHostedDirect =>
      mirrors.any((m) => m.isHostedDirect && m.url.isNotEmpty);

  /// 软件内可下载的全部归档（托管直链 + 组合包）。
  ///
  /// 「获取」面板列这个；组合包排后面（它是增强项，不是唯一选择）。
  List<LetmoeMirror> get downloadableArchives => <LetmoeMirror>[
        for (final m in mirrors)
          if (m.isHostedDirect && m.url.isNotEmpty) m,
        for (final c in composites)
          if (c.url.isNotEmpty) c,
      ];

  /// 「分享」面板列这个：真网盘外链（组合包不是网盘，已剔除）
  List<LetmoeMirror> get netdiskLinks => <LetmoeMirror>[
        for (final m in mirrors)
          if (m.isExternalLink && m.url.isNotEmpty) m,
      ];
}

/// 单条下载方式。
class LetmoeMirror {
  const LetmoeMirror({
    required this.id,
    required this.kind,
    required this.provider,
    required this.url,
    this.extractCode = '',
    this.archivePassword = '',
    this.note = '',
    this.isPrimary = false,
    this.fileName = '',
    this.bytes = 0,
    this.patchName = '',
  });

  /// 镜像 id（十进制字符串）
  final String id;

  /// 类型：`external_link`（外部网盘）/ `hosted`（letmoe 托管文件的直链）
  final String kind;

  /// 网盘渠道（`quark` / `baidu` / …；托管直链可能为空）
  final String provider;

  /// 下载 URL（网盘分享链接或托管直链）
  final String url;

  /// 提取码（网盘用；空 = 无）
  final String extractCode;

  /// 解压密码（资源压缩包用；空 = 无）
  final String archivePassword;

  /// 备注
  final String note;

  /// 是否主镜像
  final bool isPrimary;

  /// 真实文件名（组合包带 `filename`；普通镜像常为空，从 Content-Disposition 取）
  final String fileName;

  /// 精确字节数（组合包带 `bytes`；0 = 未知）
  final int bytes;

  /// 组合包内嵌的补丁名（`patch.name`；普通镜像为空）
  final String patchName;

  static LetmoeMirror fromJson(
    Map<String, dynamic> j, {
    String defaultKind = 'external_link',
  }) {
    String s(String k, [String d = '']) {
      final v = j[k];
      return v == null ? d : v.toString();
    }

    // 组合包把补丁信息放在 `patch: {name, language, publisher, …}`
    var patchName = '';
    final patch = j['patch'];
    if (patch is Map) {
      patchName = patch['name']?.toString() ?? '';
    }

    return LetmoeMirror(
      id: s('id'),
      kind: s('kind', defaultKind),
      provider: s('provider'),
      url: s('url'),
      extractCode: s('extract_code'),
      archivePassword: s('archive_password'),
      note: s('note'),
      isPrimary: j['is_primary'] == true,
      fileName: s('filename'),
      bytes: (j['bytes'] is num) ? (j['bytes'] as num).toInt() : 0,
      patchName: patchName,
    );
  }

  /// 外部网盘（夸克/百度等，只能复制链接+提取码后外跳浏览器）
  bool get isExternalLink => kind == 'external_link';

  /// letmoe 托管直链（HTTP 可下，走软件内置下载管线）
  bool get isHostedDirect => kind != 'external_link' && url.isNotEmpty;

  /// 是否「本体 + 补丁」组合包（同一份压缩包内含游戏本体）
  bool get isComposite => patchName.isNotEmpty;
}

/// `GET /works?ids=` 的单条摘要（批量问「哪些作品有资源」）。
class LetmoeWorkSummary {
  const LetmoeWorkSummary({
    required this.id,
    this.resourceCount = 0,
    this.hasDirectDownload = false,
    this.hasChineseResource = false,
    this.webUrl = '',
  });

  final String id;
  final int resourceCount;
  final bool hasDirectDownload;
  final bool hasChineseResource;
  final String webUrl;

  static LetmoeWorkSummary? tryFromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return LetmoeWorkSummary(
      id: id,
      resourceCount:
          (j['resource_count'] is num) ? (j['resource_count'] as num).toInt() : 0,
      hasDirectDownload: j['has_direct_download'] == true,
      hasChineseResource: j['has_chinese_resource'] == true,
      webUrl: j['web_url']?.toString() ?? '',
    );
  }
}
