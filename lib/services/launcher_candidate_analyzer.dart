import 'dart:io';
import 'dart:typed_data';

/// 启动程序智能推荐 · 规则层（LAUNCH-RECOMMEND，2026-10-26）
///
/// 在做选择启动程序的界面里，同一个游戏目录往往扫出十几个 exe：`vcredist_x64`、
/// `config`、`cg回収`、`SofthouseChs`、`Softhouse`、`SofthouseHD`…… 用户根本
/// 分不清哪个是"点下去就能玩"的。本分析器把整张表分成两类，并只挑 1 个推荐：
///
/// 1. **分类**：`LauncherKind.tool`（无关程序）/ `LauncherKind.game`（游戏相关）
/// 2. **版本标签**：汉化 / HD / 魔改 / 其它语言 / 原版（互斥推断）
/// 3. **唯一推荐**：汉化优先，且必须是 PE 头有效、体积正常的真程序
///
/// ## 与 `game_launcher_detector.dart` 的分工（⛔ 勿混用、勿合并）
/// 那个是**导入期**用的，只输出**单个**结论，且关键词表里 `patch` 被当成汉化
/// 正信号 —— 无法表达"分类"，也无法区分"汉化补丁安装器"与"汉化后的游戏本体"。
/// 本文件是**展示期**用的，输出整表分类 + 标签 + 一个推荐。两者独立演进。
///
/// ## 🔴 只依赖 `dart:io`，禁止 import `package:flutter/*`
/// 231（ERROR_PIPE_BUSY）环境下 `flutter test` 跑不了，但本文件因为零 flutter
/// 依赖，可以用**裸 Dart VM** 直接跑真机探针
/// （`dev_probe/launcher_recommend_probe.dart`）。一旦引入 flutter/foundation，
/// 就会连带 `dart:ui`，探针只能退回 flutter_tester，成本高一个数量级。
///
/// ## 判定哲学
/// 不靠单一关键词判死：短标记（`sc`/`cn`/`tc`）歧义极大 —— `sc` 是 `scene`、
/// `disc`、`muscle` 的子串，做子串匹配会大面积误判。所以每条证据都有明确的
/// **匹配粒度**（整 token / 粘连后缀 / 子串），并在 [LauncherCandidate.reasons]
/// 里留下人类可读的依据，方便出问题时一眼定位是哪条规则动的。
class LauncherCandidateAnalyzer {
  LauncherCandidateAnalyzer._();

  // ═══════════════════════════════════════════════════════════
  // 阈值
  // ═══════════════════════════════════════════════════════════

  /// 总分 ≥ 此值判为「游戏相关」，否则「无关程序」
  static const int gameMinScore = 30;

  /// 推荐门槛：低于此分宁可不标角标，也不误导用户
  static const int recommendMinScore = 50;

  /// 汉化标签门槛（H 分独立累计，不进主分后再参与排序）
  static const int hanhuaThreshold = 45;

  /// 补丁/破解器减分只对「小体积」生效 —— 3MB 以上的 `*patch.exe`
  /// 基本是打过补丁的**游戏本体**，不是安装器。
  static const int patcherSizeLimit = 3 * 1024 * 1024;

  // ═══════════════════════════════════════════════════════════
  // 证据表
  // ═══════════════════════════════════════════════════════════

  /// 硬排除：出现即判「无关」，不再看后续分数。
  /// 用 `contains` 而非 `startsWith` —— 真实文件名常带前缀，
  /// 如 `Microsoft Visual C++ 2015 Redistributable (x64).exe`。
  static const List<String> _hardExcludeKeywords = <String>[
    // 卸载器
    'unins', 'uninst', 'uninstall', '卸载',
    // 运行库 / 运行环境
    'vcredist', 'vc_redist', 'vcrun', 'dxsetup', 'dxwebsetup', 'directx',
    'oalinst', 'openal', 'physx', 'dotnet', 'ndp', 'xnafx', 'msvcr', 'msvcp',
    // 安装器
    'setup', 'install',
    // 通用工具
    '7z', 'winrar', 'unrar', 'ffmpeg',
  ];

  /// 硬排除：路径中任意一层子目录命中即判「无关」。
  /// `_CommonRedist` 是 Steam 系游戏的标准结构，命中率很高。
  static const List<String> _hardExcludeDirKeywords = <String>[
    'redist',
    'directx',
    'vcredist',
    'dotnet',
    'installer',
  ];

  /// 通用启动词（弱正信号）
  static const Set<String> _genericLaunchTokens = <String>{
    'game',
    'start',
    'launch',
    'launcher',
    'play',
    'run',
    'main',
    'boot',
    'app',
  };

  /// 引擎名（强正信号）：出现基本可以确信是本体的入口
  static const List<String> _engineNames = <String>[
    'siglus',
    'bgi',
    'avg32',
    'reallive',
    'kirikiri',
    'krkr',
    'nscripter',
    'artemis',
    'majiro',
    'ethornell',
    'cmvs',
    'sys40',
    'system40',
    'advhd',
    'whale',
    'escude',
    'minori',
    'unityplayer',
    'rpgmaker',
    'rmvxa',
    'ai6win',
    'xsystem',
    'ysl',
    'nexas',
    'ryu',
    'shiina',
  ];

  /// 工具类命名（负信号）：这些几乎一定是配套工具，不是启动游戏
  static const Set<String> _toolTokens = <String>{
    'config',
    'configs',
    'setting',
    'settings',
    'save',
    'savedata',
    'cg',
    'gallery',
    'readme',
    'manual',
    'help',
    'editor',
    'viewer',
    'extract',
    'extractor',
    'unpack',
    'bench',
    'benchmark',
    'crash',
    'report',
    'verify',
  };

  /// 工具类中文/日文词（负信号）
  static const List<String> _toolCjkWords = <String>[
    '设定',
    '設定',
    '环境设定',
    'コンフィグ',
    '存档',
    '回想',
    '说明',
    '手册',
    '修改器',
    '查看器',
    '解包',
  ];

  /// 补丁器 / 破解器命名（负信号，且要求小体积）
  static const Set<String> _patcherTokens = <String>{
    'crack',
    'crackfix',
    'patch',
    'patcher',
    'update',
    'updater',
    'fix',
  };

  /// 补丁器中文词
  static const List<String> _patcherCjkWords = <String>[
    '汉化补丁',
    '补丁',
    '修正',
    '升级',
    '破解',
  ];

  /// HD / 超清版标记
  static const Set<String> _hdTokens = <String>{
    'hd',
    'fhd',
    'uhd',
    '4k',
    'hdremaster',
    'widescreen',
    'wide',
  };

  static const List<String> _hdCjkWords = <String>['高清', '超清', '高解像度'];

  /// 魔改 / 整合版标记
  static const Set<String> _modTokens = <String>{
    'mod',
    'mods',
    'modded',
    'hack',
    'hacked',
    'custom',
    'plus',
    'ex',
  };

  static const List<String> _modCjkWords = <String>['魔改', '整合', '修改', '增强'];

  /// 其它语言标记（必须整 token 相等，`en`/`jp` 做子串会撞烂）
  static const Set<String> _otherLangTokens = <String>{
    'jp',
    'jpn',
    'japanese',
    'ja',
    'en',
    'eng',
    'english',
    'tw',
    'kr',
    'ko',
    'ru',
    'de',
    'fr',
    'es',
    'it',
  };

  /// 汉化标记 · 强（ASCII），允许与文件名粘连（`XYZCHS.exe`）
  static const Set<String> _hanhuaStrongTokens = <String>{
    'chs',
    'chinese',
    'hanhua',
    'zhcn',
    'zh',
  };

  /// 汉化标记 · 强 · 允许粘连的后缀。⛔ 只放 3 个高辨识度的：
  /// `sc`/`tc`/`cht` 会撞 `scene`/`disc`/`yacht`，绝不能参与粘连匹配。
  static const List<String> _hanhuaGlueSuffixes = <String>['chs', 'cn', 'zh'];

  /// 汉化标记 · 标准（亚洲区常用简写），**必须整 token 相等**
  static const Set<String> _hanhuaWeakTokens = <String>{
    'cn',
    'zho',
    'sc',
    'cht',
    'tc',
  };

  /// 汉化标记 · 中文词（子串匹配，汉字无歧义）
  static const List<String> _hanhuaStrongCjk = <String>[
    '汉化',
    '简体',
    '简中',
    '中文',
  ];

  static const List<String> _hanhuaWeakCjk = <String>['繁中', '繁体', '繁體'];

  /// 中文「启动」类动词 —— 名字里出现这些，基本可确定是中文使用者起的启动器名
  static const List<String> _cjkStarterWords = <String>[
    '启动',
    '运行',
    '开始',
    '进入',
    '打开',
    '游玩',
  ];

  /// 游戏资源特征扩展名：同目录出现 ≥3 个，说明这个目录是游戏本体目录
  static const Set<String> _resourceExts = <String>{
    'xp3',
    'arc',
    'pac',
    'pak',
    'cpz',
    'pfs',
    'sli',
    'gxp',
    'nsa',
    'nsc',
    'ks',
    'scn',
    'dat',
    'rgssad',
    'ypf',
    'grp',
    'bin',
    'ogg',
    'wav',
  };

  static final RegExp _hanRe = RegExp(r'[\u4e00-\u9fff]');
  static final RegExp _kanaRe = RegExp(r'[\u3040-\u30ff]');
  static final RegExp _sepRe = RegExp(r'[\s\-_.·,，、()（）\[\]【】「」『』!！?？~～#&+]+');
  static final RegExp _archSuffixRe =
      RegExp(r'(_x86|_x64|win32|win64|_32|_64|\(32\)|\(64\))$');

  // ═══════════════════════════════════════════════════════════
  // 对外入口
  // ═══════════════════════════════════════════════════════════

  /// 扫完后调用：给每个文件算分类/标签/推荐。
  ///
  /// 内部用**同步 IO**（`statSync` / `listSync` / PE 头读取）：候选规模上限
  /// 200，每个目录只 `listSync` 一次并缓存，实测量级在几十毫秒。同步是为了
  /// 避开 `flutter_tester` 的 FakeAsync 环境下 `await` 真实 IO 永久挂起的老坑。
  static LauncherAnalysis analyzeSync({
    required List<File> files,
    required String gameDirectory,
    String gameTitle = '',
    List<String> gameAliases = const <String>[],
  }) {
    // 每个父目录只列一次，数资源文件个数（E5 证据）
    final resourceCache = <String, int>{};

    final candidates = <LauncherCandidate>[];
    for (final file in files) {
      final parent = _parentOf(file.path);
      final parentKey = parent.toLowerCase();
      int resources = resourceCache[parentKey] ?? -1;
      if (resources < 0) {
        resources = _countResourceFiles(parent);
        resourceCache[parentKey] = resources;
      }

      int size = 0;
      try {
        size = file.statSync().size;
      } catch (_) {
        size = 0;
      }

      candidates.add(classify(
        path: file.path,
        fileName: _fileNameOf(file.path),
        sizeBytes: size,
        depth: _depthOf(file.path, gameDirectory),
        resourceFilesInDir: resources,
        gameDirectory: gameDirectory,
        gameTitle: gameTitle,
        gameAliases: gameAliases,
      ));
    }

    return _recommend(candidates);
  }

  /// 纯规则入口：不碰文件系统，只吃已经采集好的事实。
  ///
  /// 这样单测可以逐条覆盖规则表（含 `scene` 不命中 `sc` 这类边界），
  /// 不需要先造一堆真文件。
  static LauncherCandidate classify({
    required String path,
    required String fileName,
    required int sizeBytes,
    required int depth,
    required int resourceFilesInDir,
    required String gameDirectory,
    String gameTitle = '',
    List<String> gameAliases = const <String>[],
  }) {
    final base = _stripExe(fileName);
    final lowerBase = base.toLowerCase();
    final tokens = _asciiTokens(lowerBase);
    final reasons = <String>[];

    // ---------- 0. 硬排除 ----------
    final hitHardKeyword =
        _hardExcludeKeywords.any((k) => lowerBase.contains(k));
    final subDirs = _subDirsOf(path, gameDirectory);
    final hitHardDir =
        subDirs.any((d) => _hardExcludeDirKeywords.any((k) => d.contains(k)));
    if (hitHardKeyword || hitHardDir) {
      return LauncherCandidate(
        path: path,
        fileName: fileName,
        sizeBytes: sizeBytes,
        depth: depth,
        kind: LauncherKind.tool,
        versions: const <LauncherVersion>[],
        score: -100,
        hanhuaScore: 0,
        reasons: <String>[
          hitHardDir ? '位于运行库/安装器目录' : '卸载器 / 运行库 / 安装包',
        ],
      );
    }

    final titleNorm = _normalizeName(gameTitle);
    final dirNorm = _normalizeName(_lastSegment(gameDirectory));
    final baseNorm = _normalizeName(base);
    final cjkBase = _cjkOnly(base);
    final cjkTitle = _cjkOnly(gameTitle);

    int score = 0;
    int hanhua = 0;

    // ---------- 1. 加分证据 ----------
    // E1 名字就是本体（= 游戏标题 或 = 目录名）
    //    「以标题开头 + 少量后缀」也算：`野良与皇女与流浪猫之心CN.exe`、
    //    `SofthouseCHS.exe` 这类命名极其常见，只做等值比较会全部漏掉。
    if (baseNorm.isNotEmpty) {
      final byTitle = _nameMatches(baseNorm, titleNorm);
      final byDir = _nameMatches(baseNorm, dirNorm);
      if (byTitle == 2 || byDir == 2) {
        score += 50;
        reasons.add(byTitle == 2 ? '与游戏标题一致' : '与游戏目录同名');
      } else if (byTitle == 1) {
        score += 45;
        reasons.add('以游戏标题命名');
      } else if (byDir == 1) {
        score += 45;
        reasons.add('以游戏目录名命名');
      }
    }

    // E2 中文启动词
    final hasCjk = _hanRe.hasMatch(base);
    final starterHit =
        cjkBase.isNotEmpty && _cjkStarterWords.any((w) => base.contains(w));
    if (hasCjk && starterHit) {
      score += 45;
      reasons.add('中文启动词命名');
    }

    // E3 与游戏中文名有 ≥3 连续汉字重合
    final commonCjk = _longestCommonSubstring(cjkBase, cjkTitle);
    if (commonCjk >= 3) {
      score += 35;
      reasons.add('与游戏中文名重合 $commonCjk 字');
    }

    // E4 与别名（日文原名 / 英文名 / 罗马字）有 ≥5 连续字符重合
    for (final alias in _expandAliases(gameAliases)) {
      final aliasNorm = _normalizeName(alias);
      if (aliasNorm.length < 4) continue;
      if (_longestCommonSubstring(baseNorm, aliasNorm) >= 5) {
        score += 25;
        reasons.add('与别名「$alias」相似');
        break;
      }
    }

    // E5 同目录有游戏资源
    if (resourceFilesInDir >= 3) {
      score += 25;
      reasons.add('同目录 $resourceFilesInDir 个游戏资源');
    }

    // E6 位于游戏根目录
    if (depth == 0) score += 15;

    // E7 体积达标（小体积 exe 多半是壳/工具）
    if (sizeBytes >= 1024 * 1024) score += 15;

    // E8 通用启动词
    if (tokens.any(_genericLaunchTokens.contains)) score += 12;

    // E9 引擎名
    for (final engine in _engineNames) {
      if (lowerBase.contains(engine)) {
        score += 20;
        reasons.add('引擎名「$engine」');
        break;
      }
    }

    // ---------- 2. 减分证据 ----------
    // N1 工具词
    final toolHit = tokens.any(_toolTokens.contains) ||
        _toolCjkWords.any((w) => base.contains(w));
    if (toolHit) {
      score -= 45;
      reasons.add('工具类命名');
    }

    // N2 补丁器 / 破解器（限小体积）
    final patcherHit = tokens.any(_patcherTokens.contains) ||
        _patcherCjkWords.any((w) => base.contains(w));
    if (patcherHit && sizeBytes < patcherSizeLimit) {
      score -= 50;
      reasons.add('补丁 / 破解器');
    }

    // N3 过小
    if (sizeBytes < 256 * 1024) score -= 20;

    // N4 深层目录
    if (depth >= 2) score -= 15;

    // N5 位数后缀（`xxx_x64.exe` 这类成对存在的，多半是运行库或工具）
    if (_archSuffixRe.hasMatch(lowerBase)) score -= 10;

    // ---------- 3. 汉化信号（H 分独立累计）----------
    if (_hanhuaStrongCjk.any(base.contains) ||
        tokens.any(_hanhuaStrongTokens.contains) ||
        _hasHanhuaGlue(tokens)) {
      hanhua += 60;
      reasons.add('文件名含汉化标记');
    } else if (_hanhuaWeakCjk.any(base.contains) ||
        tokens.any(_hanhuaWeakTokens.contains)) {
      hanhua += 45;
      reasons.add('文件名含中文标记');
    }

    // H3 中文文件名：含汉字、不含假名，且带中文启动词或「版」字
    //    ⛔ 必须先排除假名：`恋愛零キロメートル.exe` 也是汉字开头，
    //    不排除就会把日文原名判成中文版。
    //    带中文启动词的给 45（够独立过阈值）——「启动游戏.exe」这种名字本身就是
    //    最强的汉化证据；只带「版」字的给 35，需要别的信号配合。
    if (hasCjk &&
        !_kanaRe.hasMatch(base) &&
        (starterHit || base.contains('版'))) {
      hanhua += starterHit ? 45 : 35;
    }

    // H4 与游戏中文名重合
    if (commonCjk >= 3 && cjkTitle.isNotEmpty && _hanRe.hasMatch(gameTitle)) {
      hanhua += 30;
    }

    // H5 本地化英文词
    if (tokens.any((t) => t.startsWith('localiz'))) hanhua += 25;

    final localized = hanhua >= hanhuaThreshold;
    if (localized) score += 20;

    // ---------- 4. 版本标签 ----------
    final versions = <LauncherVersion>[];
    if (localized) versions.add(LauncherVersion.localized);

    if (tokens.any(_hdTokens.contains) ||
        _hasGluedMarker(tokens, const <String>['hd', 'fhd', 'uhd']) ||
        tokens.any((t) => t.startsWith('remaster') || t.startsWith('remake')) ||
        _hdCjkWords.any(base.contains)) {
      versions.add(LauncherVersion.hd);
    }

    if (tokens.any(_modTokens.contains) || _modCjkWords.any(base.contains)) {
      versions.add(LauncherVersion.modded);
    }

    final japaneseName = _kanaRe.hasMatch(base);
    if (japaneseName || tokens.any(_otherLangTokens.contains)) {
      versions.add(LauncherVersion.otherLanguage);
    }
    // 已经是汉化版就不必再标「其它语言」——标签互斥，汉化优先
    if (localized) versions.remove(LauncherVersion.otherLanguage);

    if (versions.isEmpty) versions.add(LauncherVersion.original);

    final kind = (toolHit || score < gameMinScore)
        ? LauncherKind.tool
        : LauncherKind.game;

    return LauncherCandidate(
      path: path,
      fileName: fileName,
      sizeBytes: sizeBytes,
      depth: depth,
      kind: kind,
      versions: List<LauncherVersion>.unmodifiable(versions),
      score: score,
      hanhuaScore: hanhua,
      reasons: List<String>.unmodifiable(reasons),
      japaneseName: japaneseName,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 推荐排序
  // ═══════════════════════════════════════════════════════════

  /// 在「游戏相关」里挑唯一推荐：汉化优先，其次 HD，再其次原版。
  ///
  /// 校验顺序：先按 tier/分数/体积排，然后**依次校验 PE 头**，第一个通过的
  /// 才算推荐 —— 「推荐的程序必须能点得开」是硬要求，宁可一个都不标，
  /// 也不能推荐一个坏文件。
  static LauncherAnalysis _recommend(List<LauncherCandidate> candidates) {
    final games = candidates.where((c) => !c.isTool).toList();
    games.sort((a, b) {
      final tierCompare = _rankTier(a).compareTo(_rankTier(b));
      if (tierCompare != 0) return tierCompare;
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      return b.sizeBytes.compareTo(a.sizeBytes);
    });

    LauncherCandidate? chosen;
    for (final cand in games.take(3)) {
      // 用 continue 而非 break：排序是「先分层后比分」，分数并不单调递减，
      // break 会误伤后面的高分候选
      if (cand.score < recommendMinScore) continue;
      final pe = _probePe(cand.path);
      cand.peChecked = true;
      cand.peValid = pe.valid;
      cand.archLabel = pe.archLabel;
      if (pe.valid && chosen == null) {
        chosen = cand;
        // 只认第一个通过校验的，继续跑完前 3 个只为把架构标签补上
      }
    }

    return LauncherAnalysis(
      candidates: List<LauncherCandidate>.unmodifiable(candidates),
      recommendedPath: chosen?.path,
      recommendReason: chosen == null ? null : chosen.reasons.join(' · '),
    );
  }

  /// 推荐优先级分层：数字越小越优先
  static int _rankTier(LauncherCandidate c) {
    if (c.isLocalized && c.isHd) return 0;
    if (c.isLocalized) return 1;
    if (c.isHd) return 2;
    if (c.versions.contains(LauncherVersion.original)) return 3;
    if (c.isModded) return 4;
    return 5; // 只剩「其它语言」
  }

  // ═══════════════════════════════════════════════════════════
  // PE 头校验
  // ═══════════════════════════════════════════════════════════

  /// 读前 4KB 验 `MZ` + `PE\0\0` + machine，判"这是不是一个真能点开的程序"。
  ///
  /// 刻意不复用 `GameFontPatchService.detectPeArchFromHeader`：那个服务带着
  /// 字体组件的资产负载，把 UI 路径上的分析器绑上去不值当，且它把"不是 PE"
  /// 与"PE 但机器码未知"都归成 `unknown`，这里需要区分。
  static ({bool valid, String archLabel}) _probePe(String path) {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return (valid: false, archLabel: '');
      if (file.lengthSync() < 64) return (valid: false, archLabel: '');

      raf = file.openSync();
      final head = raf.readSync(4096);
      if (head.length < 64) return (valid: false, archLabel: '');
      if (head[0] != 0x4D || head[1] != 0x5A) {
        return (valid: false, archLabel: ''); // 'MZ'
      }
      final data = ByteData.sublistView(head);
      final peOffset = data.getUint32(0x3C, Endian.little);
      if (peOffset + 6 > head.length) return (valid: false, archLabel: '');
      if (head[peOffset] != 0x50 ||
          head[peOffset + 1] != 0x45 ||
          head[peOffset + 2] != 0x00 ||
          head[peOffset + 3] != 0x00) {
        return (valid: false, archLabel: ''); // 'PE\0\0'
      }
      final machine = data.getUint16(peOffset + 4, Endian.little);
      final arch = switch (machine) {
        0x014C => '32 位',
        0x8664 => '64 位',
        _ => '',
      };
      return (valid: true, archLabel: arch);
    } catch (_) {
      return (valid: false, archLabel: '');
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 小工具
  // ═══════════════════════════════════════════════════════════

  /// 名字与标题/目录名的匹配强度：2 = 完全相等，1 = 以之开头且后缀很短，0 = 不匹配
  ///
  /// 后缀长度上限 6 是经验值：`CN`(2) / `CHS`(3) / `汉化版`(3) / `_hd`(2) 都在内，
  /// 而 `野良与皇女…之心 完全版 汉化硬盘版` 这种超长尾巴不会误判成同一个游戏。
  static int _nameMatches(String baseNorm, String targetNorm) {
    if (targetNorm.isEmpty) return 0;
    if (baseNorm == targetNorm) return 2;
    if (targetNorm.length >= 3 &&
        baseNorm.length > targetNorm.length &&
        baseNorm.startsWith(targetNorm) &&
        baseNorm.length - targetNorm.length <= 6) {
      return 1;
    }
    return 0;
  }

  static String _fileNameOf(String path) {
    final s = path.replaceAll('\\', '/');
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }

  static String _parentOf(String path) {
    final s = path.replaceAll('\\', '/');
    final i = s.lastIndexOf('/');
    return i <= 0 ? s : s.substring(0, i);
  }

  static String _lastSegment(String dir) {
    var s = dir.replaceAll('\\', '/');
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }

  static String _stripExe(String fileName) =>
      fileName.replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');

  /// 归一化：小写 + 去掉分隔符。用于「名字 == 标题」这类等值比较。
  static String _normalizeName(String s) =>
      s.toLowerCase().replaceAll(_sepRe, '').replaceAll(RegExp(r'\.exe$'), '');

  /// ASCII 字母数字 token（CJK 由 `_hanRe` 单独处理）
  static List<String> _asciiTokens(String lower) =>
      lower.split(RegExp(r'[^a-z0-9]+')).where((t) => t.isNotEmpty).toList();

  static String _cjkOnly(String s) {
    final buffer = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 汉化标记与文件名粘连（`XYZCHS.exe` / `GameCN.exe`）。
  ///
  /// ⚠️ 已知极小概率误判：`techs` / `archs` 也以 `chs` 结尾。这类名字在
  /// galgame 目录里基本不存在，且真误判也只是多给 H 分，仍要过
  /// `score >= 50` 的推荐门槛才会变成角标。
  static bool _hasHanhuaGlue(List<String> tokens) {
    for (final token in tokens) {
      if (token.length < 4) continue;
      for (final suffix in _hanhuaGlueSuffixes) {
        if (token.endsWith(suffix)) return true;
      }
    }
    return false;
  }

  /// 标记与文件名粘连（`SofthouseHD.exe` / `GameHD.exe`）。
  ///
  /// 与 [_hasHanhuaGlue] 同一套路，但长度下限更严（≥5）：`hd` 只有两个字母，
  /// 太容易撞上普通单词结尾。
  static bool _hasGluedMarker(List<String> tokens, List<String> markers) {
    for (final token in tokens) {
      if (token.length < 5) continue;
      for (final marker in markers) {
        if (token.endsWith(marker)) return true;
      }
    }
    return false;
  }

  /// 别名展开：`subtitle` 字段是 ` / ` 连接的拼接串，这里拆成多条。
  static List<String> _expandAliases(List<String> raw) {
    final out = <String>[];
    for (final item in raw) {
      final trimmed = item.trim();
      if (trimmed.isEmpty) continue;
      for (final part in trimmed.split(RegExp(r'[/／]'))) {
        final p = part.trim();
        if (p.isNotEmpty) out.add(p);
      }
    }
    return out;
  }

  /// 最长公共**连续**子串长度（CJK 重合判定与别名相似度都用它）
  static int _longestCommonSubstring(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var best = 0;
    var prev = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      for (var j = 1; j <= b.length; j++) {
        if (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1)) {
          cur[j] = prev[j - 1] + 1;
          if (cur[j] > best) best = cur[j];
        }
      }
      prev = cur;
    }
    return best;
  }

  /// 文件相对游戏根目录的深度（0 = 根目录直接子文件）
  static int _depthOf(String filePath, String gameDirectory) {
    final segs = _relativeSegments(filePath, gameDirectory);
    if (segs == null) return 99;
    return segs.length - 1;
  }

  /// 文件与游戏根之间的**中间目录名**（不含文件名）
  static List<String> _subDirsOf(String filePath, String gameDirectory) {
    final segs = _relativeSegments(filePath, gameDirectory);
    if (segs == null || segs.length <= 1) return const <String>[];
    return segs.sublist(0, segs.length - 1);
  }

  static List<String>? _relativeSegments(
      String filePath, String gameDirectory) {
    final f = filePath.replaceAll('\\', '/').toLowerCase();
    var d = gameDirectory.replaceAll('\\', '/').toLowerCase();
    while (d.endsWith('/')) {
      d = d.substring(0, d.length - 1);
    }
    if (d.isEmpty || !f.startsWith('$d/')) return null;
    return f.substring(d.length + 1).split('/');
  }

  static int _countResourceFiles(String dirPath) {
    try {
      var count = 0;
      for (final entity in Directory(dirPath).listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = _fileNameOf(entity.path);
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final ext = name.substring(dot + 1).toLowerCase();
        if (_resourceExts.contains(ext)) count++;
        if (count >= 50) break; // 只要够判"是资源目录"就行，别数完
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}

/// 候选分类
enum LauncherKind {
  /// 游戏相关启动程序
  game,

  /// 无关程序：运行库 / 安装器 / 工具 / 补丁器
  tool,
}

/// 版本标签。⚠️ [original] 是**互斥推断**的结果（以上皆无），不是匹配出来的。
enum LauncherVersion { localized, hd, modded, otherLanguage, original }

/// 单个候选的分析结果
class LauncherCandidate {
  final String path;
  final String fileName;
  final int sizeBytes;

  /// 相对游戏根目录的深度（0 = 根目录）
  final int depth;

  final LauncherKind kind;

  /// 命中的版本标签（至少含 [LauncherVersion.original]）
  final List<LauncherVersion> versions;

  /// 分类总分
  final int score;

  /// 汉化信号分（独立累计，≥ [LauncherCandidateAnalyzer.hanhuaThreshold]
  /// 才打「汉化版」标签）
  final int hanhuaScore;

  /// 人类可读的判定依据，用于 tooltip 与排查
  final List<String> reasons;

  /// 文件名含日文假名（用来把「日文版」与「其它语言版」区分开）
  final bool japaneseName;

  /// 是否已做 PE 头校验（只有推荐候选的前几名会被校验）
  bool peChecked = false;

  /// PE 头是否有效（能点得开的硬保证）
  bool peValid = false;

  /// `32 位` / `64 位` / 空串
  String archLabel = '';

  LauncherCandidate({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
    required this.depth,
    required this.kind,
    required this.versions,
    required this.score,
    required this.hanhuaScore,
    required this.reasons,
    this.japaneseName = false,
  });

  bool get isTool => kind == LauncherKind.tool;
  bool get isGame => kind == LauncherKind.game;
  bool get isLocalized => versions.contains(LauncherVersion.localized);
  bool get isHd => versions.contains(LauncherVersion.hd);
  bool get isModded => versions.contains(LauncherVersion.modded);

  /// 列表第二行用的短标签：`汉化版` / `汉化 HD 版` / `HD 版` / `原版` ...
  String get versionLabel {
    if (isTool) return '';
    if (isLocalized && isHd) return '汉化 HD 版';
    if (isLocalized) return '汉化版';
    if (isHd) return 'HD 版';
    if (versions.contains(LauncherVersion.original)) return '原版';
    if (isModded) return '魔改版';
    if (japaneseName) return '日文版';
    return '其它语言版';
  }

  /// 角标 tooltip 全文
  String get recommendTooltip {
    final label = versionLabel;
    final why = reasons.take(3).join(' · ');
    final head = label.isEmpty ? '这可能是你需要的启动程序' : '这可能是你需要的启动程序（$label）';
    return why.isEmpty ? head : '$head\n$why';
  }
}

/// 整表分析结果
class LauncherAnalysis {
  /// 与输入同序 —— 列表展示顺序**不允许**因为分析而改变
  final List<LauncherCandidate> candidates;

  /// 唯一推荐的 exe 路径；null = 没有足够可信的候选，不标角标
  final String? recommendedPath;

  final String? recommendReason;

  const LauncherAnalysis({
    required this.candidates,
    this.recommendedPath,
    this.recommendReason,
  });

  LauncherCandidate? forPath(String? path) {
    if (path == null || path.isEmpty) return null;
    for (final c in candidates) {
      if (c.path == path) return c;
    }
    return null;
  }

  bool isRecommended(String? path) =>
      path != null && path.isNotEmpty && path == recommendedPath;

  LauncherCandidate? get recommended => forPath(recommendedPath);

  int get gameCount => candidates.where((c) => c.isGame).length;
  int get toolCount => candidates.where((c) => c.isTool).length;
}
