/// 补丁包**落盘预览**（纯函数，零 IO / 零 Flutter）。
///
/// ## 它要解决什么问题
///
/// P0-4 实测 4 个真实补丁包，得到 4 种完全不同的形态：
///
/// | 形态 | 包内特征 | 正确落点 |
/// |---|---|---|
/// | 换 exe 型 | 一份与游戏主程序同名的 exe + 资源 | 游戏根目录（覆盖主程序） |
/// | DLL 注入型 | `winmm.dll` `LoaderDll.dll` `hook.ini` `font.ttf` | 游戏根目录（**子目录无效**） |
/// | 覆盖式 | `GameData/Scene.pck` 等与游戏目录同构的树 | 游戏根目录（整棵覆盖） |
/// | 自解压安装器 | 单个 `Setup.exe` | 不铺，引导用户手动运行 |
///
/// 所以「统一解到 `patch/<补丁名>/`」只对最后一种成立。本文件负责从
/// **树摘要**推出 [PatchTargetAdvice]，UI 拿它当**默认选项**，
/// 🔴 但最终落点必须由用户确认 —— 猜错就是覆盖玩家的游戏本体。
///
/// ⛔ 本文件不做任何 IO：探测目标目录里有哪些同名文件是落盘阶段的事。

import 'patch_path_guard.dart';

/// 包内一个文件（剥壳后的相对路径 + 体积）
class PatchEntry {
  const PatchEntry({required this.path, required this.size});

  final String path;
  final int size;

  String get name => path.split('/').last;

  String get extension {
    final n = name.toLowerCase();
    final dot = n.lastIndexOf('.');
    return dot <= 0 ? '' : n.substring(dot);
  }

  String get topDir => path.contains('/') ? path.split('/').first : '';
}

/// 落点建议
enum PatchTargetAdvice {
  /// 铺到游戏根目录（覆盖式 / DLL 注入 / 换 exe）
  gameRoot,

  /// 隔离存到 `patch/<补丁名>/`，不碰游戏本体
  patchSubdir,

  /// 单文件安装器：不铺，引导用户自己运行
  installerOnly,

  /// 包不可用（空包 / 有非法条目 / 无法解析）
  blocked,
}

extension PatchTargetAdviceLabel on PatchTargetAdvice {
  String get label => switch (this) {
        PatchTargetAdvice.gameRoot => '安装到游戏根目录',
        PatchTargetAdvice.patchSubdir => '释放到补丁目录',
        PatchTargetAdvice.installerOnly => '需要手动运行安装器',
        PatchTargetAdvice.blocked => '无法安装',
      };
}

/// 「这个补丁以后怎么用」的提示。
///
/// 🔴 补丁站**只下载不安装**（2026-11-10 用户定调），所以这段文案是软件
/// 唯一能帮到用户的地方：不告诉他包形态，他拿到一堆 `winmm.dll` 会懵。
/// 文案只描述**用法**，⛔ 不出现"自动安装/一键应用"这类承诺。
extension PatchUsageHint on PatchPreview {
  String? get usageHint {
    switch (advice) {
      case PatchTargetAdvice.gameRoot:
        if (libraries.isNotEmpty) {
          return 'DLL 注入型：使用时必须和游戏 exe 放在同一目录，放子目录不生效';
        }
        return '覆盖式补丁：使用时按原目录结构覆盖到游戏目录';
      case PatchTargetAdvice.patchSubdir:
        return '使用时把里面的文件放到游戏目录对应位置';
      case PatchTargetAdvice.installerOnly:
        return '这是安装器（EXE），双击运行它完成安装';
      case PatchTargetAdvice.blocked:
        return warnings.isNotEmpty ? warnings.first : '包内容异常，使用前请自行确认';
    }
  }
}

/// 包内文件分类（给 UI 分组 + 给 install 决策）
class PatchPreview {
  const PatchPreview({
    required this.advice,
    required this.reason,
    required this.wrapper,
    required this.files,
    required this.readmes,
    required this.installers,
    required this.libraries,
    required this.configs,
    required this.dataFiles,
    required this.totalBytes,
    required this.warnings,
  });

  final PatchTargetAdvice advice;

  /// 一句话理由（直接显示在「为什么建议这样装」下面，别让用户猜）
  final String reason;

  /// 被剥掉的外层目录（null = 本来没有）
  final String? wrapper;

  /// 剥壳后的**全部**文件
  final List<PatchEntry> files;

  /// 说明文件（`先看我.txt` / `★はじめにお読み下さい.txt` / README.md …）
  ///
  /// 🔴 P0-4：3/4 的包带说明文件，安装顺序与配置要求全在里面，必须显式列出
  final List<PatchEntry> readmes;

  /// 可执行（.exe/.msi/.bat/.cmd）—— 包含 DLL 型补丁里的 `configure.exe`
  final List<PatchEntry> installers;

  /// 动态库（.dll/.asi）—— DLL 劫持型补丁的标志
  final List<PatchEntry> libraries;

  /// 配置（.ini/.cfg/.json/.yaml/.xml）
  final List<PatchEntry> configs;

  /// 游戏数据（.pck/.dat/.arc/.pak/.xp3/.bin/.ovk/.g00/.grp）
  final List<PatchEntry> dataFiles;

  final int totalBytes;

  /// 必须显示给用户的告警（含"放子目录不生效"这类硬约束）
  final List<String> warnings;

  bool get isEmpty => files.isEmpty;

  /// 包内最高的顶层目录名（剥壳后）
  ///
  /// 用来说明"这个包会长成什么样"。⚠️ 作者自起的名字（`hoshiori_patch_v102`）
  /// ⛔ 不能当补丁显示名，显示名仍用站上的 `title`。
  String get topLevelHint {
    final tops = <String>{};
    for (final f in files) {
      if (f.topDir.isNotEmpty) tops.add(f.topDir);
    }
    if (tops.isEmpty) return '';
    if (tops.length == 1) return tops.first;
    return '${tops.length} 个子目录';
  }
}

// ==================== 分类谓词 ====================

const Set<String> _readmeExts = <String>{
  '.txt',
  '.md',
  '.nfo',
  '.pdf',
  '.doc',
  '.docx',
  '.rtf',
  '.htm',
  '.html',
};
const Set<String> _installerExts = <String>{'.exe', '.msi', '.bat', '.cmd'};
const Set<String> _libraryExts = <String>{'.dll', '.asi', '.ocx'};
const Set<String> _configExts = <String>{
  '.ini',
  '.cfg',
  '.conf',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.toml',
};
const Set<String> _dataExts = <String>{
  '.pck',
  '.dat',
  '.arc',
  '.pak',
  '.xp3',
  '.bin',
  '.ovk',
  '.g00',
  '.grp',
  '.nsa',
  '.nsc',
  '.cpz',
  '.pac',
  '.vfs',
  '.cid',
  '.gxp',
  '.ypf',
};

// ==================== 主入口 ====================

/// 从树摘要生成预览。
///
/// [entries] 必须是**已剥壳**的相对路径（先过 [resolveLayout]）。
/// [gameExeNames] 游戏目录里的 exe 文件名（小写），用来识别"换 exe 型"。
/// [gameTopDirs] 游戏目录的顶层子目录名（小写），用来识别"覆盖式"。
PatchPreview buildPatchPreview({
  required List<PatchEntry> entries,
  String? wrapper,
  List<String> gameExeNames = const <String>[],
  List<String> gameTopDirs = const <String>[],
}) {
  if (entries.isEmpty) {
    return const PatchPreview(
      advice: PatchTargetAdvice.blocked,
      reason: '包内没有任何文件',
      wrapper: null,
      files: <PatchEntry>[],
      readmes: <PatchEntry>[],
      installers: <PatchEntry>[],
      libraries: <PatchEntry>[],
      configs: <PatchEntry>[],
      dataFiles: <PatchEntry>[],
      totalBytes: 0,
      warnings: <String>['补丁包是空的，可能是下载不完整'],
    );
  }

  final files = List<PatchEntry>.from(entries)
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

  final readmes = <PatchEntry>[];
  final installers = <PatchEntry>[];
  final libraries = <PatchEntry>[];
  final configs = <PatchEntry>[];
  final dataFiles = <PatchEntry>[];
  var total = 0;

  final gameExeSet = gameExeNames.map((e) => e.toLowerCase()).toSet();
  final gameDirSet = gameTopDirs.map((e) => e.toLowerCase()).toSet();
  var shipsGameExe = false;
  var overlayDirHit = '';

  for (final f in files) {
    total += f.size;
    final ext = f.extension;
    if (_readmeExts.contains(ext)) readmes.add(f);
    if (_installerExts.contains(ext)) {
      installers.add(f);
      if (gameExeSet.contains(f.name.toLowerCase())) shipsGameExe = true;
    }
    if (_libraryExts.contains(ext)) libraries.add(f);
    if (_configExts.contains(ext)) configs.add(f);
    if (_dataExts.contains(ext)) dataFiles.add(f);

    // 覆盖式：顶层子目录与游戏目录同名
    final top = f.topDir.toLowerCase();
    if (top.isNotEmpty && gameDirSet.contains(top)) overlayDirHit = f.topDir;
  }

  // ---------- 落点判定（**顺序即优先级**，改动前先想清楚）----------
  PatchTargetAdvice advice;
  String reason;

  final onlySingleInstaller =
      files.length == 1 && _installerExts.contains(files.first.extension);

  if (onlySingleInstaller) {
    advice = PatchTargetAdvice.installerOnly;
    reason = '包内只有一个安装器 ${files.first.name}，需要你自己运行它完成安装';
  } else if (shipsGameExe) {
    advice = PatchTargetAdvice.gameRoot;
    reason = '包内含与游戏主程序同名的 exe（替换型补丁），必须覆盖到游戏根目录';
  } else if (libraries.isNotEmpty) {
    advice = PatchTargetAdvice.gameRoot;
    reason = '包内含 ${libraries.first.name} 等动态库，靠 DLL 劫持生效，'
        '必须与游戏主程序同目录';
  } else if (overlayDirHit.isNotEmpty) {
    advice = PatchTargetAdvice.gameRoot;
    reason = '包内目录 "$overlayDirHit" 与游戏目录同构（覆盖式补丁），'
        '需要整棵覆盖到游戏根目录';
  } else if (dataFiles.isNotEmpty && configs.isNotEmpty) {
    advice = PatchTargetAdvice.gameRoot;
    reason = '包内是游戏数据 + 配置（${dataFiles.first.name} 等），按覆盖式处理';
  } else {
    advice = PatchTargetAdvice.patchSubdir;
    reason = '没有识别到需要覆盖游戏本体的文件，释放到补丁目录最安全';
  }

  // ---------- 告警 ----------
  //
  // 🔴 全部是**用法提示**，不是安装承诺：补丁站只下载，软件不会动游戏目录，
  // 所以文案里不能出现"已备份/可回滚/自动安装"这类会误导用户放心覆盖的话。
  final warnings = <String>[];
  if (advice == PatchTargetAdvice.installerOnly) {
    warnings.add('本软件不会代跑安装器（EXE 补丁一律不代跑），下载后请手动运行');
  }
  if (libraries.isNotEmpty) {
    warnings.add('此补丁依赖 DLL 劫持，⛔ 放到子目录不会生效，必须与游戏 exe 同目录');
  }
  if (advice == PatchTargetAdvice.gameRoot && files.isNotEmpty) {
    warnings.add('使用时按原目录结构覆盖到游戏目录，同名文件会被替换，'
        '建议先自己备份游戏目录');
  }
  if (shipsGameExe) {
    warnings.add('包内含游戏主程序（exe），替换前请留一份原主程序');
  }
  if (readmes.isNotEmpty) {
    warnings.add('包内有说明文件（${readmes.first.name}），用之前先读一遍');
  }

  return PatchPreview(
    advice: advice,
    reason: reason,
    wrapper: wrapper,
    files: files,
    readmes: readmes,
    installers: installers,
    libraries: libraries,
    configs: configs,
    dataFiles: dataFiles,
    totalBytes: total,
    warnings: warnings,
  );
}

/// 便捷入口：直接从原始（未归一）条目名生成预览。
///
/// 内部会先过 [resolveLayout] 剥壳 + 归一；有非法条目时返回 `blocked`，
/// 并把非法路径原文放进 warnings（⛔ 不静默跳过 —— 半装比不装更糟）。
PatchPreview previewFromRawPaths(
  List<String> rawPaths, {
  Map<String, int> sizes = const <String, int>{},
  List<String> gameExeNames = const <String>[],
  List<String> gameTopDirs = const <String>[],
}) {
  final bad = validateEntryPaths(rawPaths);
  if (bad.isNotEmpty) {
    return PatchPreview(
      advice: PatchTargetAdvice.blocked,
      reason: '补丁包内有非法路径，已拒绝解压',
      wrapper: null,
      files: const <PatchEntry>[],
      readmes: const <PatchEntry>[],
      installers: const <PatchEntry>[],
      libraries: const <PatchEntry>[],
      configs: const <PatchEntry>[],
      dataFiles: const <PatchEntry>[],
      totalBytes: 0,
      warnings: <String>[
        '含 ${bad.length} 个非法路径（穿越/绝对路径/盘符），首个：${bad.first}',
        '整包已拒绝：半装进去比不装更糟',
      ],
    );
  }

  final layout = resolveLayout(rawPaths);
  final entries = <PatchEntry>[
    for (final p in layout.paths) PatchEntry(path: p, size: sizes[p] ?? 0),
  ];

  return buildPatchPreview(
    entries: entries,
    wrapper: layout.wrapper,
    gameExeNames: gameExeNames,
    gameTopDirs: gameTopDirs,
  );
}

/// 体积格式化（预览里显示"将写入 12.3 MB"）
String formatPatchPreviewBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024)
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}
