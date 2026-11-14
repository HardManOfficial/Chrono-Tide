import 'package:flutter/foundation.dart';

/// ★ DL-SPACE-BUDGET（2026-11-03）：跨实例的磁盘预留登记。
///
/// ## 为什么需要
///
/// `GlobalInstallCenter` 与 `GlobalTaskManager` 各持一个 `DownloadCore`，两者
/// 可以同时下载不同的游戏（前者装云端资源，后者是主页快速获取）。而磁盘准入
/// 是**各自独立**计算的 —— 两个任务若落在同一块盘，各自都按「2 倍体积」判断，
/// 都觉得空间够，结果一起写到一半同时满。用户看到的是「两个都失败」，且各自
/// 的报错都说「磁盘空间不足」，但谁都说不清是谁吃掉的。
///
/// 这里按**盘符**登记「每个任务已承诺占用的字节数」，准入时从可用空间里扣掉
/// 其他任务的承诺量，让后来的任务看见真实可支配空间。
///
/// ## 纪律
///
/// - 登记必须成对：`reserve()` 之后一定在 `finally` 里 `release()`，否则预留
///   泄漏会让后续下载被永久误拦（这比不拦更糟，所以 [release] 按 taskId 全盘清理，
///   不依赖盘符是否算对）。
/// - 进程内状态，不持久化：预留只在「正在下载」期间有意义，崩溃后由启动清理兜底。
class DownloadSpaceBudget {
  DownloadSpaceBudget._();

  /// 盘符 → (taskId → 预留字节)。
  static final Map<String, Map<String, int>> _byDrive = {};

  static String _keyOf(String dir) {
    final m = RegExp(r'^([A-Za-z]):').firstMatch(dir.trim());
    if (m != null) return m.group(1)!.toUpperCase();
    // UNC / 相对路径：用原串做键（同一网络位置仍能互斥）
    return dir.trim().toLowerCase();
  }

  /// 其他任务在同一块盘上已经承诺出去的字节数。
  static int reservedByOthers(String dir, String taskId) {
    final entry = _byDrive[_keyOf(dir)];
    if (entry == null) return 0;
    var sum = 0;
    entry.forEach((id, bytes) {
      if (id != taskId) sum += bytes;
    });
    return sum;
  }

  /// 登记本任务的预留量（同一 taskId 重复登记会覆盖，天然幂等）。
  static void reserve(String dir, String taskId, int bytes) {
    if (taskId.isEmpty || bytes <= 0) return;
    final key = _keyOf(dir);
    _byDrive.putIfAbsent(key, () => <String, int>{})[taskId] = bytes;
    debugPrint('[DL-SPACE] 预留 $key: $taskId → ${_fmt(bytes)}，'
        '该盘其他任务已承诺 ${_fmt(reservedByOthers(dir, taskId))}');
  }

  /// 释放该任务在所有盘上的预留（任务结束时无条件调用）。
  static void release(String taskId) {
    if (taskId.isEmpty) return;
    var touched = false;
    for (final entry in _byDrive.values) {
      if (entry.remove(taskId) != null) touched = true;
    }
    _byDrive.removeWhere((_, v) => v.isEmpty);
    if (touched) debugPrint('[DL-SPACE] 已释放预留: $taskId');
  }

  /// 仅供测试：清空全部登记。
  @visibleForTesting
  static void resetForTest() => _byDrive.clear();

  static String _fmt(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(0)}MB';
}
