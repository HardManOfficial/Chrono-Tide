/// 补丁资源统一模型（PATCH-STATION）
///
/// 跨三个来源归一化：鲲（NextMoe v2 结构化 + moyu 资源页直链）、
/// 2DFan（HTML 抓取）、自家社区（PB `game_resources` + OpenList）。
///
/// 🔴 **设计前提（2026-11-10 实测结论，别再改回两态）**：
/// 补丁有**三种投递形态**，不是"能下 / 不能下"两态 ——
/// 9 条样本里 6 条有直连文件、3 条只有网盘分享（夸克 / 百度）。
/// 所以 [PatchDelivery] 必须三值，UI 的主按钮随之变形。
///
/// 🔴 **本文件不 import flutter**：保持纯 Dart，便于 `dart run` 离线验证
/// 与单测（项目里 `dart analyze` 在本机稳定性差，纯 Dart 出口是唯一可靠的
/// 自检手段）。
library;

// ==================== 站点 ====================

/// 补丁来源站点。
///
/// ⚠️ 鲲与 NextMoe **是同一个站**（NextMoe v2 是鲲的官方 API 上游，
/// `www.moyu.moe` 是它的前端页面），故合并为一个 [kunlun] 值：
/// 列表/元数据走 v2（字段全），直链走资源页 HTML（v2 的 `/file` 要 scope）。
/// 这样从根上不会出现"同一补丁两条记录"，不需要任何去重键。
enum PatchSite {
  /// 鲲（NextMoe v2 + moyu 资源页）
  kunlun,

  /// 2DFan
  twoDfan,

  /// 自家社区（PB `game_resources` + OpenList）
  community;

  /// UI 显示名（来源 tab、卡片角标都用它）
  String get displayName {
    switch (this) {
      case PatchSite.kunlun:
        return '鲲';
      case PatchSite.twoDfan:
        return '2DFan';
      case PatchSite.community:
        return '社区';
    }
  }

  /// 缓存/去重键前缀（历史键名沿用 moyu，避免与既有缓存撞车）
  String get tag {
    switch (this) {
      case PatchSite.kunlun:
        return 'moyu';
      case PatchSite.twoDfan:
        return '2dfan';
      case PatchSite.community:
        return 'pb';
    }
  }

  /// 单一来源（"全部"不在此枚举里，由聚合层用 null 表示）
  static PatchSite? tryParse(String raw) {
    final key = raw.trim().toLowerCase();
    for (final s in PatchSite.values) {
      if (s.name.toLowerCase() == key || s.tag == key) return s;
    }
    return null;
  }
}

// ==================== 投递形态 ====================

/// 补丁投递形态（决定卡片主按钮做什么）。
enum PatchDelivery {
  /// 有可直连文件（鲲的 `dl.imoe.uk` / 社区 OpenList）→ 软件内下载
  direct,

  /// 只有网盘分享（夸克 / 百度）→ 展示链接 + 提取码 + 一键复制
  netdisk,

  /// 只能跳转原站（2DFan 未登录、直链解析失败、无可用链接）
  web,
}

/// 一个具体可用的下载入口（可能是直链，也可能是某个网盘）。
///
/// ## 为什么需要「列表」而不是单个字段
///
/// 实测两个站都常见「一个资源挂多个下载点」：
/// - 2DFan：`网盘载点1`（百度）+ `海外直连`（`d1.acgxp.com`）
/// - 鲲：`共 N 个` 下载链接，可能是直链 + 夸克 + 百度并存
///
/// 旧模型只有 `directUrl` + 一个 `netdiskUrl`，多出来的入口**被直接丢掉**，
/// 用户在详情里看不到、只能回原页翻 —— 与「不打开原页就能下载」的目标相反。
class PatchDeliveryLink {
  final String url;

  /// 直链 / 网盘（[PatchDelivery.web] 不会出现在列表里）
  final PatchDelivery kind;

  /// 展示用标签：「海外直连」「网盘载点1」「夸克网盘」…
  final String label;

  /// 网盘提取码（有就展示，没有就写「原页未公开」）
  final String? extractCode;

  /// 网盘服务商（百度网盘 / 夸克网盘…）；直链为 null
  final String? provider;

  const PatchDeliveryLink({
    required this.url,
    required this.kind,
    this.label = '',
    this.extractCode,
    this.provider,
  });

  bool get isDirect => kind == PatchDelivery.direct;

  /// 是否能「软件内直接下载」（只有直链可以）
  bool get downloadable => isDirect && url.trim().isNotEmpty;

  @override
  String toString() => '${kind.name}($label):$url';
}

// ==================== 补丁类型归一化 ====================

/// 跨站类型标签（鲲 `type[]` 英文枚举 / 2DFan 中文徽章 / PB `resource_type` 中文）。
///
/// 归一化只做"能对上的对上一部分"，⛔ 不要为了分类齐全而发明新类别：
/// 对不上的进 [other]，UI 直接显示原文（[PatchResource.rawKinds]）。
enum PatchKind {
  /// 人工汉化
  translation,

  /// AI 翻译
  aiTranslation,

  /// 机翻 / 机翻润色
  machine,

  /// 全 CG 存档 / 存档
  save,

  /// 无码 / 内容还原
  decensor,

  /// 破解 / 免安装
  crack,

  /// 修正 / 修复 / bug fix
  fix,

  /// MOD / 魔改
  mod,

  /// 全年龄补丁（把 R18 内容替换成全年龄版）
  allAges,

  /// R18 补丁（成人内容补丁）
  r18,

  /// 图像相关（立绘 / CG 替换等）
  image,

  /// 其他（显示原文）
  other;

  /// 徽章显示名（中文短标签，卡片上直接显示）
  String get displayName {
    switch (this) {
      case PatchKind.translation:
        return '汉化';
      case PatchKind.aiTranslation:
        return 'AI翻译';
      case PatchKind.machine:
        return '机翻';
      case PatchKind.save:
        return '存档';
      case PatchKind.decensor:
        return '无码';
      case PatchKind.crack:
        return '破解';
      case PatchKind.fix:
        return '修正';
      case PatchKind.mod:
        return 'MOD';
      case PatchKind.allAges:
        return '全年龄';
      case PatchKind.r18:
        return 'R18';
      case PatchKind.image:
        return 'CG';
      case PatchKind.other:
        return '其他';
    }
  }

  /// 从任意站点的原始标签串归一化。
  ///
  /// 覆盖三站真实出现过的写法（大小写、全半角已统一处理）。
  static PatchKind fromRaw(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) return PatchKind.other;

    // 顺序敏感：AI 翻译必须先判，否则 'machine' / '翻译' 会抢先命中。
    // 🔴 不能裸用 `s.contains('ai')`：'detail' / 'available' 都含 'ai'，
    //    必须按词边界匹配（鲲的 type 里确实存在**单独的** `ai` 值）。
    if (_looksLikeAi(s)) return PatchKind.aiTranslation;
    if (s.contains('machine') || s.contains('机翻')) {
      return PatchKind.machine;
    }
    if (s.contains('translat') ||
        s.contains('manual') ||
        s.contains('汉化') ||
        s.contains('翻译')) {
      return PatchKind.translation;
    }
    if (s.contains('save') || s.contains('存档')) {
      return PatchKind.save;
    }
    if (s.contains('decensor') ||
        s.contains('无码') ||
        s.contains('去码') ||
        s.contains('内容还原')) {
      return PatchKind.decensor;
    }
    if (s.contains('crack') || s.contains('破解') || s.contains('免安装')) {
      return PatchKind.crack;
    }
    if (s.contains('fix') || s.contains('修正') || s.contains('修复')) {
      return PatchKind.fix;
    }
    if (s.contains('mod') || s.contains('魔改')) {
      return PatchKind.mod;
    }
    // 🔴 顺序敏感：'全年龄' 必须先于 'r18' 判 —— 某些站把它写成
    //    「R18→全年龄补丁」，先判 r18 会归错。
    if (s.contains('全年龄')) {
      return PatchKind.allAges;
    }
    if (s.contains('r18')) {
      return PatchKind.r18;
    }
    if (s.contains('image') || s.contains('cg') || s.contains('立绘')) {
      return PatchKind.image;
    }
    return PatchKind.other;
  }

  /// 批量归一化并去重（保持首次出现顺序）。
  static List<PatchKind> fromRawList(Iterable<String> raw) {
    final out = <PatchKind>[];
    for (final r in raw) {
      final k = fromRaw(r);
      if (!out.contains(k)) out.add(k);
    }
    return out;
  }

  /// `ai` 作为独立词出现（鲲的 type 枚举里就是裸 `ai`）。
  ///
  /// 用词边界而不是 `contains('ai')`：否则 `detail` / `available` / `main`
  /// 都会被误判成 AI 翻译。
  static final RegExp _aiToken = RegExp(r'(^|[^a-z])ai([^a-z]|$)');

  static bool _looksLikeAi(String s) {
    if (s == 'ai') return true;
    if (s.contains('ai翻译') || s.contains('ai汉化')) return true;
    if (s.contains('ai translat') ||
        s.contains('ai-trans') ||
        s.contains('aitrans')) {
      return true;
    }
    if (!_aiToken.hasMatch(s)) return false;
    return s.contains('trans') || s.contains('翻译') || s.contains('汉化');
  }
}

// ==================== 大小解析 ====================

/// 把 `"102.537 MB"` / `"5.2 MB"` / `"1.7 KB"` / `` 解析成字节数。
///
/// 三站的大小都是**人类可读字符串**（鲲 `size`、2DFan `.download-card-size`），
/// 模型内部一律存 `int?` 字节数，展示层再格式化 —— 避免 UI 里到处做字符串运算。
/// 解析不了返回 null（不猜、不填 0）。
int? parseHumanSizeToBytes(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;

  final m = RegExp(r'([\d.,]+)\s*([KMGTP]?)i?B', caseSensitive: false)
      .firstMatch(s);
  if (m == null) {
    // 纯数字（少数源直接给字节数）
    final plain = double.tryParse(s.replaceAll(',', ''));
    if (plain == null) return null;
    return plain.round();
  }

  final value = double.tryParse(m.group(1)!.replaceAll(',', ''));
  if (value == null) return null;

  final unit = (m.group(2) ?? '').toUpperCase();
  const factors = <String, int>{
    '': 1,
    'K': 1024,
    'M': 1024 * 1024,
    'G': 1024 * 1024 * 1024,
    'T': 1024 * 1024 * 1024 * 1024,
    'P': 1024 * 1024 * 1024 * 1024 * 1024,
  };
  final factor = factors[unit];
  if (factor == null) return null;
  return (value * factor).round();
}

/// 字节数 → 展示串（1 位小数；< 1 MB 用 KB；<= 0 返回空串）
String formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

// ==================== 网盘识别 ====================

/// 网盘类型（用于卡片徽章「网盘·夸克」与复制提示）
enum NetdiskProvider {
  quark('夸克'),
  baidu('百度'),
  lanzou('蓝奏'),
  pan123('123盘'),
  mega('MEGA'),
  unknown('网盘');

  final String displayName;
  const NetdiskProvider(this.displayName);

  /// 从链接识别；识别不了返回 [unknown]（不返回 null —— 调用方已知它是网盘型）
  static NetdiskProvider fromUrl(String url) {
    final u = url.toLowerCase();
    if (u.contains('quark.cn') || u.contains('quark')) {
      return NetdiskProvider.quark;
    }
    if (u.contains('pan.baidu.com') || u.contains('baidu')) {
      return NetdiskProvider.baidu;
    }
    if (u.contains('lanzou') || u.contains('lan.zou')) {
      return NetdiskProvider.lanzou;
    }
    if (u.contains('123pan') || u.contains('123684') || u.contains('123865')) {
      return NetdiskProvider.pan123;
    }
    if (u.contains('mega.nz')) return NetdiskProvider.mega;
    return NetdiskProvider.unknown;
  }
}

// ==================== 资源实体 ====================

/// 一条补丁资源（跨三站的统一视图）。
///
/// 不可变 + `copyWith`：直链解析是**后置**的（鲲要先抓资源页 HTML 才知道
/// 有没有 `dl.imoe.uk` 直链），所以先构造 `delivery=web`，解析完再
/// `copyWith(delivery: direct, directUrl: ...)`，避免可变对象在并发里打架。
class PatchResource {
  /// 全局唯一键：`<site.tag>:<站内 id>`，如 `moyu:5459` / `2dfan:15801` / `pb:rec123`
  final String key;

  final PatchSite site;

  /// 站内 id（鲲=资源 id；2DFan=download id；社区=PB record id）
  final String id;

  /// 上游补丁分组 id（鲲的 patch id）。仅用于「同一补丁多资源」的弱关联展示，
  /// 不参与去重。可为空。
  final String? groupId;

  /// 补丁名
  final String title;

  /// 所属游戏标题（来源侧给的原文，可能与探索库标题不同）
  final String gameTitle;

  /// 归一化类型（卡片徽章）
  final List<PatchKind> kinds;

  /// 类型原始标签（对不上的类别在 UI 上显示原文，不丢信息）
  final List<String> rawKinds;

  /// 语言（归一化：zh-Hans / zh-Hant / ja / en；未知为空）
  final List<String> languages;

  /// 平台（pc / windows / android…，多数源为空）
  final List<String> platforms;

  /// 文件字节数（null = 未知，不填 0）
  final int? sizeBytes;

  /// SHA-256（仅鲲有；社区有 `sha256` 字段时也会带）。空串 = 未知
  final String sha256;

  /// 安装说明（可含换行，长文本；卡片不显示，详情浮层显示）
  final String note;

  /// 原站页面地址（兜底动作：永远可点）
  final String webUrl;

  /// 投递形态
  final PatchDelivery delivery;

  /// 直链（delivery == direct 时非空）
  final String? directUrl;

  /// 网盘分享链接（delivery == netdisk 时非空）
  final String? netdiskUrl;

  /// 网盘提取码（可能为空）
  final String? extractCode;

  /// 站点**全部**可用下载入口（直链 + 每一个网盘）。
  ///
  /// 🔴 为什么不能只有 [directUrl] / [netdiskUrl] 两个字段：
  /// 一个资源页经常挂着**多个**网盘（`网盘载点1` / `网盘载点2`…），
  /// 旧实现只留第一个，用户看不到其余的，只能回原页翻 —— 体验倒退。
  /// 现在统一收进 [links]，[delivery] / [directUrl] / [netdiskUrl] 只作为
  /// 「主入口」的便捷视图（卡片徽章与主按钮用它）。
  final List<PatchDeliveryLink> links;

  /// 作者 / 上传者（可能为空）
  final String author;

  final int downloadCount;

  final DateTime? updatedAt;

  const PatchResource({
    required this.key,
    required this.site,
    required this.id,
    this.groupId,
    required this.title,
    this.gameTitle = '',
    this.kinds = const <PatchKind>[],
    this.rawKinds = const <String>[],
    this.languages = const <String>[],
    this.platforms = const <String>[],
    this.sizeBytes,
    this.sha256 = '',
    this.note = '',
    this.webUrl = '',
    this.delivery = PatchDelivery.web,
    this.directUrl,
    this.netdiskUrl,
    this.extractCode,
    this.links = const <PatchDeliveryLink>[],
    this.author = '',
    this.downloadCount = 0,
    this.updatedAt,
  });

  /// 是否可在软件内直接下载
  bool get downloadable =>
      delivery == PatchDelivery.direct && (directUrl ?? '').trim().isNotEmpty;

  /// 是否只能复制网盘链接
  bool get isNetdisk =>
      delivery == PatchDelivery.netdisk && (netdiskUrl ?? '').trim().isNotEmpty;

  /// 网盘类型（非网盘型返回 null）
  NetdiskProvider? get netdiskProvider {
    final u = netdiskUrl?.trim() ?? '';
    if (u.isEmpty) return null;
    return NetdiskProvider.fromUrl(u);
  }

  /// 展示用大小串
  String get sizeLabel => formatBytes(sizeBytes);

  /// 徽章文本：归一化类型名；若是「其他」则回落原文（最多 2 个）
  List<String> get badgeLabels {
    final out = <String>[];
    for (final k in kinds) {
      if (k == PatchKind.other) {
        for (final r in rawKinds) {
          final t = r.trim();
          if (t.isEmpty) continue;
          if (!out.contains(t)) out.add(t);
          if (out.length >= 2) break;
        }
      } else {
        if (!out.contains(k.displayName)) out.add(k.displayName);
      }
      if (out.length >= 2) break;
    }
    return out;
  }

  PatchResource copyWith({
    String? key,
    PatchSite? site,
    String? id,
    String? groupId,
    String? title,
    String? gameTitle,
    List<PatchKind>? kinds,
    List<String>? rawKinds,
    List<String>? languages,
    List<String>? platforms,
    int? sizeBytes,
    String? sha256,
    String? note,
    String? webUrl,
    PatchDelivery? delivery,
    String? directUrl,
    String? netdiskUrl,
    String? extractCode,
    List<PatchDeliveryLink>? links,
    String? author,
    int? downloadCount,
    DateTime? updatedAt,
  }) {
    return PatchResource(
      key: key ?? this.key,
      site: site ?? this.site,
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      title: title ?? this.title,
      gameTitle: gameTitle ?? this.gameTitle,
      kinds: kinds ?? this.kinds,
      rawKinds: rawKinds ?? this.rawKinds,
      languages: languages ?? this.languages,
      platforms: platforms ?? this.platforms,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      sha256: sha256 ?? this.sha256,
      note: note ?? this.note,
      webUrl: webUrl ?? this.webUrl,
      delivery: delivery ?? this.delivery,
      directUrl: directUrl ?? this.directUrl,
      netdiskUrl: netdiskUrl ?? this.netdiskUrl,
      extractCode: extractCode ?? this.extractCode,
      links: links ?? this.links,
      author: author ?? this.author,
      downloadCount: downloadCount ?? this.downloadCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

// ==================== 检索结果 ====================

/// 一次补丁检索的聚合结果。
///
/// 🔴 **不伪造条目**：某源失败时只进 [failures]，列表里绝不出现占位/假数据
/// （参考项目 GalGear 在 2DFan `/downloads` 抓失败时会伪造一条"作品级资源"，
/// 这是反面做法，我们不复刻）。
class PatchQueryResult {
  /// 归一化后的关键词（游戏名或补丁名）
  final String keyword;

  /// 命中的游戏标题（走了身份解析时非空，用于 UI 显示「正在查『XXX』的补丁」）
  final String? resolvedGameTitle;

  /// 各源资源合集（已按 [PatchResource.key] 去重，按来源顺序排列）
  final List<PatchResource> resources;

  /// 源 → 失败原因（UI 显示"该源暂时不可用"，不出假条目）
  final Map<PatchSite, String> failures;

  /// 各源命中条数（来源 tab 的计数徽章用；失败源不出现）
  final Map<PatchSite, int> countsBySite;

  /// 是否走的是标题兜底（没能锚定到作品 id，精度可能偏低 —— UI 可提示）
  final bool resolvedByTitle;

  /// 结果来自磁盘缓存的时间（null = 本次实时查询）
  final DateTime? cachedAt;

  const PatchQueryResult({
    required this.keyword,
    this.resolvedGameTitle,
    this.resources = const <PatchResource>[],
    this.failures = const <PatchSite, String>{},
    this.countsBySite = const <PatchSite, int>{},
    this.resolvedByTitle = false,
    this.cachedAt,
  });

  bool get isEmpty => resources.isEmpty;
  bool get hasAnyFailure => failures.isNotEmpty;
  int get total => resources.length;

  /// 全部源都失败（UI 走"都连不上"空态，而不是"没找到"）
  bool get allFailed =>
      resources.isEmpty && failures.length == PatchSite.values.length;

  /// 按来源过滤（来源 tab 切换用，零网络）
  List<PatchResource> filterBySite(PatchSite? site) {
    if (site == null) return resources;
    return resources.where((r) => r.site == site).toList(growable: false);
  }

  static const PatchQueryResult empty = PatchQueryResult(keyword: '');
}
