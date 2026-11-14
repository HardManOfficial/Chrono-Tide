/// PATCH-VAULT 的两个「游戏目录」唯一实现（纯 Dart，零 Flutter / 零 FFI）。
///
/// ## 为什么必须集中
///
/// 用户口述的「游戏目录」＝**启动程序所在目录**，但项目里
/// `game.json.directory_path` 是**游戏本体根**。当 `launch_path` 带子目录
/// （`Game/xxx.exe`）时两者不是同一个值：
///
/// | 名称 | 用途 |
/// |---|---|
/// | [bodyRoot] | 覆盖式补丁（与游戏目录同构的 `GameData/` 树）的推荐落点 |
/// | [launchDir] | DLL 注入 / 换 exe 的推荐落点；**备份目录所在**；转移默认目标所在 |
///
/// 项目里 `GameFontPatchService.resolveExePath` / `GameDataFormat.resolveLaunchPath` /
/// `GameLaunchService.resolveUserChoice` 三个 helper 都只返回 **exe 文件路径**，
/// 没有「exe 所在目录」的现成实现；且字体补丁调用方实际传的是本体根
/// （`font_library_panel.dart:203`），与它自己的注释不一致。
/// ⇒ 本文件是 PATCH-VAULT 内部唯一口径，⛔ UI 不得各自拼路径。
///
/// 🔴 `LibraryGame.pathForCover` 是 `metaDataDir` 优先，**不是**本体根，
/// 绝不能拿它当目录基准。
///
/// 🔴 本文件不 import `GamePathResolver` / `GameDataFormat`（它们带 FFI / Flutter，
/// 纯 Dart 探针跑不起来）。由 UI 层解析完把 `bodyRoot` 与 `resolvedExePath`
/// 传进来，本文件只做纯路径推导 ⇒ 离线探针可完整覆盖。

import 'package:path/path.dart' as path;

/// 转移功能的默认目标目录名（用户口述「/游戏/补丁/」）。
///
/// 🔴 做成常量，⛔ 不许硬编码散落各处；用户可在转移对话框里改成任意目录。
const String kPatchVaultTransferDirName = '补丁';

/// 备份与事务目录（隐藏，跟随游戏搬家）。
const String kPatchVaultDirName = '.CTPatch';

const String kPatchVaultManifestName = 'manifest.json';
const String kPatchVaultBackupDirName = 'backup';

class GameDirs {
  const GameDirs({
    required this.bodyRoot,
    required this.launchDir,
    required this.isOffline,
    required this.launchDirVerified,
    required this.warning,
  });

  /// 游戏本体根（`GamePathResolver.resolve(...).accessPath`）。
  /// 离线时为空串 ⇒ 调用方**禁止任何写操作**。
  final String bodyRoot;

  /// 启动程序所在目录（用户定义）。
  final String launchDir;

  final bool isOffline;

  /// true = exe 路径确实解析到了存在的文件；
  /// false = 只按 `launch_path` 推算了理论目录或降级到本体根，UI 需如实提示。
  final bool launchDirVerified;

  /// 给 UI 展示的口径说明（例如「启动目录与本体根不同」）。
  final String warning;

  bool get isValid => !isOffline && bodyRoot.isNotEmpty && launchDir.isNotEmpty;

  bool get rootsDiffer =>
      _norm(bodyRoot).isNotEmpty &&
      _norm(launchDir).isNotEmpty &&
      _norm(bodyRoot) != _norm(launchDir);

  /// 转移默认目标：`<启动目录>/补丁/`。
  String get transferDir => launchDir.isEmpty
      ? ''
      : path.join(launchDir, kPatchVaultTransferDirName);

  /// 事务根目录：`<启动目录>/.CTPatch/`。
  String get vaultDir =>
      launchDir.isEmpty ? '' : path.join(launchDir, kPatchVaultDirName);

  String get manifestPath =>
      vaultDir.isEmpty ? '' : path.join(vaultDir, kPatchVaultManifestName);

  String get backupRoot =>
      vaultDir.isEmpty ? '' : path.join(vaultDir, kPatchVaultBackupDirName);

  String backupDirFor(String txId) =>
      backupRoot.isEmpty ? '' : path.join(backupRoot, _safeTxId(txId));

  /// 从已解析好的输入推导目录（纯函数，可离线探针）。
  ///
  /// [bodyRoot] UI 层经 `GamePathResolver.resolve()` 得到；离线传空串。
  /// [resolvedExePath] UI 层经 `GameDataFormat.resolveLaunchPath()` 得到；
  /// 为空表示 exe 当前不可达（游戏被移动 / 归档 / 未解压）。
  /// [launchPath] `game.json.launch_path`（相对本体根，可能带子目录）。
  /// [probeDirExists] 可注入的存在性探测，默认用 `dart:io` 会破坏纯 Dart 层，
  /// 因此由调用方注入；不注入时按「理论目录不存在」处理并降级。
  static GameDirs compute({
    required String bodyRoot,
    required String launchPath,
    String resolvedExePath = '',
    bool isOffline = false,
    bool Function(String dir)? probeDirExists,
  }) {
    if (isOffline || bodyRoot.isEmpty) {
      return const GameDirs(
        bodyRoot: '',
        launchDir: '',
        isOffline: true,
        launchDirVerified: false,
        warning: '游戏目录当前不可访问（可能在网络盘离线或已被移动），补丁功能只读',
      );
    }

    String launchDir = bodyRoot;
    var verified = false;
    var warning = '';

    if (resolvedExePath.isNotEmpty) {
      launchDir = path.dirname(resolvedExePath);
      verified = true;
    } else if (launchPath.trim().isNotEmpty) {
      // exe 当前不可达，但仍按 launch_path 推算「启动程序应该在的目录」，
      // 只有目录确实存在才采用 —— 不让它凭空造一个不存在的备份位置。
      final candidate = path.dirname(path.join(bodyRoot, launchPath));
      if (candidate.isNotEmpty &&
          path.isWithin(path.normalize(bodyRoot), path.normalize(candidate)) &&
          (probeDirExists?.call(candidate) ?? false)) {
        launchDir = candidate;
        warning = '启动程序当前不可达，备份目录按启动路径推算（未验证）';
      } else {
        warning = '启动程序当前不可达，备份目录暂用游戏本体根';
      }
    } else {
      warning = '该游戏未记录启动程序路径，备份目录暂用游戏本体根';
    }

    final dirs = GameDirs(
      bodyRoot: bodyRoot,
      launchDir: launchDir,
      isOffline: false,
      launchDirVerified: verified,
      warning: warning,
    );
    if (dirs.rootsDiffer && warning.isEmpty) {
      return GameDirs(
        bodyRoot: dirs.bodyRoot,
        launchDir: dirs.launchDir,
        isOffline: dirs.isOffline,
        launchDirVerified: dirs.launchDirVerified,
        warning: '启动程序在子目录，备份与转移默认目录在启动目录，'
            '与游戏本体根不同；预览页会显示实际绝对路径',
      );
    }
    return dirs;
  }

  /// 应用／备份扫描的**硬排除名单**。
  ///
  /// 🔴 转移进 `<启动目录>/补丁/` 的补丁若被当成游戏文件，会出现
  /// 「自己备份自己 / 自己覆盖自己」；`.CTPatch/` 同理。
  bool isExcluded(String absolutePath) {
    final p = _norm(absolutePath);
    if (p.isEmpty) return false;
    for (final root in <String>[transferDir, vaultDir]) {
      if (root.isEmpty) continue;
      final r = _norm(root);
      if (p == r || path.isWithin(r, p)) return true;
    }
    return false;
  }

  static String _norm(String p) =>
      p.isEmpty ? '' : path.normalize(p).replaceAll('/', '\\').toLowerCase();

  static String _safeTxId(String txId) =>
      txId.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
}

/// 供未构造 [GameDirs] 的纯函数使用的排除判定（按显式目录名匹配）。
///
/// 用在遍历「补丁源目录」时：源目录里若混入 `.CTPatch` / `补丁` 子目录，
/// 不该被铺进游戏目录。
bool isPatchVaultInternalDirName(String name) {
  final n = name.toLowerCase();
  return n == kPatchVaultDirName.toLowerCase() ||
      n == kPatchVaultTransferDirName.toLowerCase();
}
