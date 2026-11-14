/// 游戏本体「移入回收站」的安全边界判定。
///
/// ## 背景（ADR-007 配套，2026-10-26）
///
/// 本地导入（智能导入 / 批量导入 / 单文件导入）会把**用户自己的游戏文件夹**
/// 原样登记为 `game.directoryPath`。ADR-007 规定这类目录不自动删除，于是库页
/// 「同时删除本地游戏文件」复选框变成了一个做不到的承诺。
///
/// 本模块把 ADR-007 里早已列出的「删除进回收站」补上判定层：
/// 只有当目标是**本地磁盘上、用户自己创建、且不属于任何系统/应用关键位置**的
/// 普通目录时，才允许交给 [RecycleBinService]（可还原）处理。
///
/// 🔴 方向永远是保守：任何一条命中即拒绝，退回「跳过 + 提示手动处理」。
/// 宁可留垃圾，不可误删（ADR-007 决策 2）。
///
/// 纯 Dart（无 flutter widget 依赖），便于直接单测。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/network_path.dart';
import '../utils/path_normalizer.dart';

/// 本体目录「可回收删除」判定。
abstract final class GameBodyRecyclePolicy {
  // ==================== 拒绝原因（面向用户，简短可读） ====================

  /// 网络位置：`SHFileOperationW(FOF_ALLOWUNDO)` 对 UNC / 映射网络驱动器无效，
  /// 会**退化为永久删除**，必须整体拒绝。
  static const String reasonNetwork = '位于网络位置（UNC / 映射网络驱动器）';

  static const String reasonEmpty = '路径为空';

  static const String reasonDriveRoot = '是磁盘根目录';

  static const String reasonAppRoot = '是应用自有目录';

  static const String reasonAppAncestor = '是应用目录的上级目录';

  static const String reasonSystem = '是系统关键目录';

  static const String reasonUserProfile = '是用户主目录或其一级子目录';

  static const String reasonShallow = '目录层级过浅';

  /// 系统环境变量中不允许回收的根（整棵子树都拒绝）。
  static const List<String> _systemEnvKeys = <String>[
    'SystemRoot',
    'windir',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'ProgramW6432',
    'ProgramData',
    'SystemDrive',
  ];

  /// 判定 [target] 是否允许移入回收站。
  ///
  /// 返回 `null` 表示允许；否则返回**拒绝原因**（可直接展示给用户）。
  ///
  /// [appRoots] 应用自有根目录（exeDir / dataDir 等）。传入的根本身及其
  /// 祖先目录都会被拒绝 —— 后者是关键：如果某条记录的 `directoryPath` 被
  /// 错误登记成 `D:\`，只判「是否在应用目录内」会放行，从而删掉整个盘。
  ///
  /// [environment] 仅用于测试注入；默认读 [Platform.environment]。
  static String? blockReason(
    String target, {
    required List<String> appRoots,
    Map<String, String>? environment,
  }) {
    if (target.trim().isEmpty) return reasonEmpty;

    // 1) 网络位置（同步 FFI 判定，不会阻塞在 SMB 上）
    if (NetworkPath.isNetwork(target)) return reasonNetwork;

    // 2) 磁盘根目录（`e:` / `e:\`）—— 必须在归一化**之前**用原始串判定：
    //    `package:path` 视 `E:` 为「E 盘当前目录」的相对形式，absolute() 后
    //    会变成别的形态，正则就失配了。
    final raw = NetworkPath.stripLongPathPrefix(target.trim())
        .replaceAll('/', '\\');
    if (RegExp(r'^[A-Za-z]:\\?$').hasMatch(raw)) return reasonDriveRoot;

    final t = PathNormalizer.forCompare(target);
    if (t.isEmpty) return reasonEmpty;

    // 2b) 归一化后再兜一次（覆盖 `\\?\E:\` 之类前缀形态）
    if (RegExp(r'^[a-z]:\\?$').hasMatch(t)) return reasonDriveRoot;

    // 3) 应用自有目录：根本身、以及「根的祖先」（防止删到盘/上层目录）
    for (final root in appRoots) {
      final nr = PathNormalizer.forCompare(root);
      if (nr.isEmpty) continue;
      if (t == nr) return reasonAppRoot;
      // child(nr) 在 parent(t) 之下 ⇒ t 是应用目录的祖先
      if (PathNormalizer.isSubdirectory(t, nr)) return reasonAppAncestor;
    }

    final env = environment ?? Platform.environment;
    final userProfile = PathNormalizer.forCompare(
        NetworkPath.stripLongPathPrefix(env['USERPROFILE'] ?? ''));

    for (final key in _systemEnvKeys) {
      final raw = env[key];
      if (raw == null || raw.isEmpty) continue;
      final root = PathNormalizer.forCompare(
          NetworkPath.stripLongPathPrefix(raw));
      if (root.isEmpty) continue;
      // SystemDrive 只拒根本身（其下级交给「层级过浅」之外的常规路径判断）
      if (key == 'SystemDrive') {
        if (t == root) return reasonSystem;
        continue;
      }
      if (t == root || PathNormalizer.isSubdirectory(root, t)) {
        return reasonSystem;
      }
      // 主目录在系统盘下时，`C:\Users` 这类上级也要拒绝
      if (PathNormalizer.isSubdirectory(t, root)) {
        // t 是系统根的上层（例如 C:\），已在盘根分支拦下；这里兜底
        return reasonSystem;
      }
    }

    // 4) 用户主目录本体及其一级子目录（Desktop / Documents / Downloads …）
    if (userProfile.isNotEmpty) {
      if (t == userProfile) return reasonUserProfile;
      final depth = PathNormalizer.depthOf(t, userProfile);
      if (depth == 1) return reasonUserProfile;
    }

    // 5) 层级兜底：至少要有「盘符 + 一级目录」
    if (p.split(t).length < 2) return reasonShallow;

    return null;
  }
}
