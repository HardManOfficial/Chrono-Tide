/// PATCH-VAULT 数据模型（纯 Dart，零 Flutter / 零 IO）。
///
/// ## 设计口径
///
/// - 身份键恒为 `gameId`（ADR-011），⛔ 不用标题 / 目录名 / `pathForCover`。
/// - 登记是**免搬运**的：只索引补丁原路径，不复制、不移动、不解压。
/// - `data/patch_vault/index.json` 只存**补丁记录**与「事务摘要」；
///   🔴 逐文件备份映射的**唯一真值**是游戏目录里的 `.CTPatch/manifest.json`，
///   它跟随游戏搬家，不在应用数据目录留第二份绝对路径副本（防双写漂移）。
/// - 所有枚举以字符串落盘并带兜底解析，索引版本演进时不能让旧数据把面板炸掉。

/// 补丁记录在面板里的状态。
///
/// 🔴 `applied` 只是**展示态**，真值看 manifest 里有没有对应 installed 事务。
/// 🔴 文案禁止出现「已备份 / 可回滚」这类承诺（对齐 patch_preview 的克制）。
enum PatchVaultStatus {
  registered('registered', '已登记'),
  applied('applied', '已应用'),
  missing('missing', '路径失效'),
  manual('manual', '需手动处理');

  const PatchVaultStatus(this.key, this.label);

  final String key;
  final String label;

  static PatchVaultStatus fromKey(String? s) => switch (s) {
        'applied' => PatchVaultStatus.applied,
        'missing' => PatchVaultStatus.missing,
        'manual' => PatchVaultStatus.manual,
        _ => PatchVaultStatus.registered,
      };
}

/// 容器 / 文件形态（只读识别出的**标签**，不是能力承诺）。
enum PatchContainer {
  zip('zip', 'ZIP 压缩包'),
  sevenZip('7z', '7z 压缩包'),
  rar('rar', 'RAR 压缩包'),
  exe('exe', 'EXE 安装器'),
  directory('directory', '文件夹'),
  singleFile('file', '单文件'),
  unknown('unknown', '未知格式');

  const PatchContainer(this.key, this.label);

  final String key;
  final String label;

  static PatchContainer fromKey(String? s) {
    for (final v in PatchContainer.values) {
      if (v.key == s) return v;
    }
    return PatchContainer.unknown;
  }

  /// 本功能能自动铺进游戏目录的只有 zip 与已解压文件夹。
  bool get canApply =>
      this == PatchContainer.zip || this == PatchContainer.directory;

  /// 7z / rar：只登记，提示用户自行解压后以文件夹形式导入。
  bool get needsManualExtract =>
      this == PatchContainer.sevenZip || this == PatchContainer.rar;

  /// EXE 安装器：⛔ 不代跑，且**无法自动回退**。
  bool get isInstaller => this == PatchContainer.exe;
}

/// 补丁形态标签（来源：patch_preview 的只读树摘要）。
enum PatchKind {
  replaceExe('replace_exe', '替换主程序'),
  dllInject('dll_inject', 'DLL 注入'),
  overlay('overlay', '覆盖式'),
  installer('installer', '安装器'),
  unknown('unknown', '形态未知');

  const PatchKind(this.key, this.label);

  final String key;
  final String label;

  static PatchKind fromKey(String? s) {
    for (final v in PatchKind.values) {
      if (v.key == s) return v;
    }
    return PatchKind.unknown;
  }
}

/// 一条本地补丁登记。
class PatchRecord {
  const PatchRecord({
    required this.id,
    required this.gameId,
    required this.sourcePath,
    required this.fileName,
    required this.sizeBytes,
    required this.mtimeMs,
    required this.sha256,
    required this.container,
    required this.kind,
    required this.hasReadme,
    required this.hasExe,
    required this.status,
    required this.addedAt,
    this.isDirectory = false,
    this.note = '',
  });

  final String id;
  final String gameId;

  /// 补丁文件的**原始绝对路径**（免搬运登记，转移后同步更新）。
  final String sourcePath;
  final String fileName;
  final int sizeBytes;

  /// 登记时的修改时间（毫秒）。打开面板时用它 + size 做轻量失效检测。
  final int mtimeMs;

  /// 登记时流式计算的 sha256；应用前重算比对。
  /// 目录形态为空串（目录不整体哈希，应用前逐文件重校验）。
  final String sha256;

  final PatchContainer container;
  final PatchKind kind;
  final bool hasReadme;
  final bool hasExe;
  final PatchVaultStatus status;
  final String addedAt;
  final bool isDirectory;

  /// 用户可编辑备注（例如「汉化 v1.2，先装本体再装这个」）。
  final String note;

  bool get canApplyNow =>
      status != PatchVaultStatus.missing && container.canApply;

  PatchRecord copyWith({
    String? sourcePath,
    String? fileName,
    int? sizeBytes,
    int? mtimeMs,
    String? sha256,
    PatchContainer? container,
    PatchKind? kind,
    bool? hasReadme,
    bool? hasExe,
    PatchVaultStatus? status,
    bool? isDirectory,
    String? note,
  }) =>
      PatchRecord(
        id: id,
        gameId: gameId,
        sourcePath: sourcePath ?? this.sourcePath,
        fileName: fileName ?? this.fileName,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        mtimeMs: mtimeMs ?? this.mtimeMs,
        sha256: sha256 ?? this.sha256,
        container: container ?? this.container,
        kind: kind ?? this.kind,
        hasReadme: hasReadme ?? this.hasReadme,
        hasExe: hasExe ?? this.hasExe,
        status: status ?? this.status,
        addedAt: addedAt,
        isDirectory: isDirectory ?? this.isDirectory,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'gameId': gameId,
        'sourcePath': sourcePath,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'mtimeMs': mtimeMs,
        'sha256': sha256,
        'container': container.key,
        'kind': kind.key,
        'hasReadme': hasReadme,
        'hasExe': hasExe,
        'status': status.key,
        'addedAt': addedAt,
        'isDirectory': isDirectory,
        'note': note,
      };

  static PatchRecord fromJson(Map<String, dynamic> j) => PatchRecord(
        id: _str(j['id']),
        gameId: _str(j['gameId']),
        sourcePath: _str(j['sourcePath']),
        fileName: _str(j['fileName']),
        sizeBytes: _int(j['sizeBytes']),
        mtimeMs: _int(j['mtimeMs']),
        sha256: _str(j['sha256']),
        container: PatchContainer.fromKey(_str(j['container'])),
        kind: PatchKind.fromKey(_str(j['kind'])),
        hasReadme: j['hasReadme'] == true,
        hasExe: j['hasExe'] == true,
        status: PatchVaultStatus.fromKey(_str(j['status'])),
        addedAt: _str(j['addedAt']),
        isDirectory: j['isDirectory'] == true,
        note: _str(j['note']),
      );
}

/// 事务里的一条文件映射。
class PatchTxEntry {
  const PatchTxEntry({
    required this.relativePath,
    required this.targetPath,
    required this.backupPath,
    required this.beforeSha256,
    required this.afterSha256,
    required this.existedBefore,
    required this.sizeBytes,
  });

  /// 相对落点根的路径（展示用，`/` 分隔，已过路径护栏）。
  final String relativePath;

  /// 实际写入的绝对路径（manifest 记绝对路径 ⇒ 备份与落点不同根也能还原）。
  final String targetPath;

  /// 备份文件绝对路径；空串 = 原本不存在该文件，撤销时删除即可。
  final String backupPath;

  /// 应用前哈希；空串 = 原本不存在。
  final String beforeSha256;

  /// 应用后哈希；还原前用它比对，**不一致说明用户后来手动改过**。
  final String afterSha256;

  final bool existedBefore;
  final int sizeBytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'relativePath': relativePath,
        'targetPath': targetPath,
        'backupPath': backupPath,
        'beforeSha256': beforeSha256,
        'afterSha256': afterSha256,
        'existedBefore': existedBefore,
        'sizeBytes': sizeBytes,
      };

  static PatchTxEntry fromJson(Map<String, dynamic> j) => PatchTxEntry(
        relativePath: _str(j['relativePath']),
        targetPath: _str(j['targetPath']),
        backupPath: _str(j['backupPath']),
        beforeSha256: _str(j['beforeSha256']),
        afterSha256: _str(j['afterSha256']),
        existedBefore: j['existedBefore'] == true,
        sizeBytes: _int(j['sizeBytes']),
      );
}

enum PatchTxState {
  applying('applying'),
  installed('installed'),
  rollingBack('rolling_back'),
  restoring('restoring');

  const PatchTxState(this.key);

  final String key;

  static PatchTxState fromKey(String? s) {
    for (final v in PatchTxState.values) {
      if (v.key == s) return v;
    }
    return PatchTxState.applying;
  }
}

/// 一次「应用补丁」事务，逐文件备份映射的载体。
class PatchTransaction {
  const PatchTransaction({
    required this.txId,
    required this.patchId,
    required this.gameId,
    required this.appliedAt,
    required this.targetRoot,
    required this.backupDir,
    required this.state,
    required this.entries,
  });

  final String txId;
  final String patchId;
  final String gameId;

  /// ISO8601；一键还原按它**严格逆序**（重叠补丁必须逆序卸载）。
  final String appliedAt;

  /// 用户最终确认的落点根（启动目录 / 本体根 / 自定义子目录）。
  final String targetRoot;

  /// `<launchDir>/.CTPatch/backup/<txId>/`
  final String backupDir;

  final PatchTxState state;
  final List<PatchTxEntry> entries;

  bool get isInstalled => state == PatchTxState.installed;

  PatchTransaction copyWith({
    PatchTxState? state,
    List<PatchTxEntry>? entries,
  }) =>
      PatchTransaction(
        txId: txId,
        patchId: patchId,
        gameId: gameId,
        appliedAt: appliedAt,
        targetRoot: targetRoot,
        backupDir: backupDir,
        state: state ?? this.state,
        entries: entries ?? this.entries,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'txId': txId,
        'patchId': patchId,
        'gameId': gameId,
        'appliedAt': appliedAt,
        'targetRoot': targetRoot,
        'backupDir': backupDir,
        'state': state.key,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  static PatchTransaction fromJson(Map<String, dynamic> j) => PatchTransaction(
        txId: _str(j['txId']),
        patchId: _str(j['patchId']),
        gameId: _str(j['gameId']),
        appliedAt: _str(j['appliedAt']),
        targetRoot: _str(j['targetRoot']),
        backupDir: _str(j['backupDir']),
        state: PatchTxState.fromKey(_str(j['state'])),
        entries: _mapList(j['entries'])
            .map((e) => PatchTxEntry.fromJson(e))
            .toList(),
      );
}

/// 写在应用数据目录索引里的事务**摘要**（不含逐文件映射）。
///
/// 用途：面板快速显示「这个游戏装过几个补丁」、以及游戏搬家后给用户的
/// 线索。🔴 回退动作只读游戏目录 manifest，绝不依赖这里的缓存。
class PatchTxSummary {
  const PatchTxSummary({
    required this.txId,
    required this.patchId,
    required this.appliedAt,
    required this.targetRoot,
  });

  final String txId;
  final String patchId;
  final String appliedAt;
  final String targetRoot;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'txId': txId,
        'patchId': patchId,
        'appliedAt': appliedAt,
        'targetRoot': targetRoot,
      };

  static PatchTxSummary fromJson(Map<String, dynamic> j) => PatchTxSummary(
        txId: _str(j['txId']),
        patchId: _str(j['patchId']),
        appliedAt: _str(j['appliedAt']),
        targetRoot: _str(j['targetRoot']),
      );
}

class PatchVaultGameState {
  const PatchVaultGameState({
    required this.patches,
    required this.txSummaries,
  });

  final List<PatchRecord> patches;
  final List<PatchTxSummary> txSummaries;

  static PatchVaultGameState get empty => const PatchVaultGameState(
        patches: <PatchRecord>[],
        txSummaries: <PatchTxSummary>[],
      );

  PatchVaultGameState copyWith({
    List<PatchRecord>? patches,
    List<PatchTxSummary>? txSummaries,
  }) =>
      PatchVaultGameState(
        patches: patches ?? this.patches,
        txSummaries: txSummaries ?? this.txSummaries,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'patches': patches.map((e) => e.toJson()).toList(),
        'txSummaries': txSummaries.map((e) => e.toJson()).toList(),
      };

  static PatchVaultGameState fromJson(Map<String, dynamic> j) =>
      PatchVaultGameState(
        patches: _mapList(j['patches'])
            .map((e) => PatchRecord.fromJson(e))
            .toList(),
        txSummaries: _mapList(j['txSummaries'])
            .map((e) => PatchTxSummary.fromJson(e))
            .toList(),
      );
}

/// `data/patch_vault/index.json` 顶层结构（零 schema 迁移：不碰 game.json）。
class PatchVaultData {
  const PatchVaultData({
    this.version = 1,
    required this.games,
  });

  static const int currentVersion = 1;
  final int version;
  final Map<String, PatchVaultGameState> games;

  static PatchVaultData get empty =>
      const PatchVaultData(games: <String, PatchVaultGameState>{});

  PatchVaultGameState of(String gameId) =>
      games[gameId] ?? PatchVaultGameState.empty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'games': <String, dynamic>{
          for (final e in games.entries) e.key: e.value.toJson(),
        },
      };

  static PatchVaultData fromJson(Map<String, dynamic> j) {
    final rawGames = j['games'];
    final out = <String, PatchVaultGameState>{};
    if (rawGames is Map) {
      rawGames.forEach((k, v) {
        if (v is Map) {
          out[k.toString()] =
              PatchVaultGameState.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    return PatchVaultData(
      version: _int(j['version'], fallback: currentVersion),
      games: out,
    );
  }
}

/// 游戏目录 `.CTPatch/manifest.json` 顶层结构。
class PatchVaultManifest {
  const PatchVaultManifest({
    this.version = 1,
    required this.gameId,
    required this.transactions,
  });

  static const int currentVersion = 1;
  final int version;
  final String gameId;
  final List<PatchTransaction> transactions;

  static PatchVaultManifest empty(String gameId) => PatchVaultManifest(
        gameId: gameId,
        transactions: <PatchTransaction>[],
      );

  /// 已生效事务，按应用时间**升序**（调用方 `reversed` 即得逆序卸载顺序）。
  List<PatchTransaction> get installed => transactions
      .where((t) => t.isInstalled)
      .toList()
    ..sort((a, b) => a.appliedAt.compareTo(b.appliedAt));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'gameId': gameId,
        'transactions': transactions.map((e) => e.toJson()).toList(),
      };

  static PatchVaultManifest fromJson(Map<String, dynamic> j) =>
      PatchVaultManifest(
        version: _int(j['version'], fallback: currentVersion),
        gameId: _str(j['gameId']),
        transactions: _mapList(j['transactions'])
            .map((e) => PatchTransaction.fromJson(e))
            .toList(),
      );
}

// ==================== 容错解析小工具 ====================

String _str(dynamic v) => v is String ? v : '';

int _int(dynamic v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

List<Map<String, dynamic>> _mapList(dynamic v) {
  if (v is! List) return <Map<String, dynamic>>[];
  return v
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}
