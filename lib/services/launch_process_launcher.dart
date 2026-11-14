// launch_process_launcher.dart
// 统一进程执行器 —— 把"到底怎么把进程拉起来"收敛成一处
//
// 为什么需要它：启动链路原本在 4 个地方各写一套 `Process.start` + 回退
// `cmd /c start`（普通启动、超分启动、转区启动、托盘启动），每处对
// 「需不需要提权」「UNC 工作目录能不能给 cmd」的处理都不一致。加了管理员
// 维度之后如果继续各写各的，必然出现"某条路径能启动、另一条不能"。
//
// 权限裁决规则（唯一来源）：
//   ┌ 自身已提权 ─→ 普通 CreateProcess：子进程继承提权，**零 UAC**
//   ├ 自身未提权 + 需要提权 ─→ ShellExecuteExW "runas"：弹一次 UAC
//   └ 自身未提权 + 不需要提权 ─→ 普通 CreateProcess
//
// ⚠️ 两个必须知道的推论：
//   ① 管理器自己以管理员运行时，**所有**子进程都会提权（token 继承），
//      无法对单个游戏降权 —— 除非注入降权 token，代价远大于收益。
//   ② 提权通道启动的进程由 shell 代为创建，与当前进程**没有父子关系**，
//      只能靠 PID / 进程名追踪，拿不到 Dart `Process` 对象。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'elevation_service.dart';

/// 启动通道
enum LaunchChannel {
  /// 普通 CreateProcess（detached）
  direct,

  /// ShellExecuteExW + runas
  elevated,

  /// 普通通道失败后的 cmd / c start 兜底
  shellFallback,
}

/// 一次进程启动的结果
class LaunchOutcome {
  final bool started;

  /// 新进程 PID（提权通道可能为 null —— 见文件头注释②）
  final int? pid;

  /// direct 通道才能拿到；提权通道恒为 null
  final Process? process;

  final LaunchChannel channel;

  /// 失败原因（成功时为 null）
  final String? error;

  /// 用户是否在 UAC 对话框点了「否」
  final bool cancelledByUser;

  const LaunchOutcome({
    required this.started,
    required this.channel,
    this.pid,
    this.process,
    this.error,
    this.cancelledByUser = false,
  });

  const LaunchOutcome.failure(
    LaunchChannel channel,
    String error, {
    bool cancelledByUser = false,
  }) : this(
          started: false,
          channel: channel,
          error: error,
          cancelledByUser: cancelledByUser,
        );

  @override
  String toString() =>
      'LaunchOutcome(${channel.name}, started=$started, pid=$pid, error=$error)';
}

class LaunchProcessLauncher {
  LaunchProcessLauncher._();

  /// 游戏进程是否应该提权。
  ///
  /// 🔴 联动规则：**游戏提权 ⇒ 超分引擎必须一起提权**。
  /// 否则 Magpie（普通权限）无法捕获管理员权限游戏的窗口，
  /// 表现是"超分开了但完全没缩放"，且不报任何错。
  static bool shouldElevateTool({
    required bool toolWantsElevation,
    required bool gameElevated,
  }) {
    return toolWantsElevation || gameElevated;
  }

  /// 启动游戏进程
  ///
  /// [elevate] = 该游戏是否勾选了「以管理员身份运行」。
  static Future<LaunchOutcome> launchGame({
    required String exePath,
    required String workingDirectory,
    required bool elevate,
  }) async {
    if (exePath.trim().isEmpty) {
      return const LaunchOutcome.failure(LaunchChannel.direct, '启动程序路径为空');
    }

    final selfElevated = ElevationService.isSelfElevated() ?? false;

    // ── 需要提权且自身未提权 → 只能走 runas（UAC） ──
    if (elevate && !selfElevated) {
      final pid = await ElevationService.shellExecuteRunAs(
        file: exePath,
        workingDirectory: workingDirectory,
      );
      if (pid == null && ElevationService.lastShellExecuteError == 0) {
        // 错误码 0 说明 ShellExecuteEx 成功但我们没拿到 PID，
        // 进程大概率已经起来了 —— 按成功处理，交给进程检测兜底
        debugPrint('[LAUNCH-EXEC] ⚠️ 提权启动未取得 PID，按已启动处理');
        return const LaunchOutcome(
          started: true,
          channel: LaunchChannel.elevated,
        );
      }
      if (pid == null) {
        final cancelled =
            ElevationService.lastShellExecuteError == kErrorCancelled;
        return LaunchOutcome.failure(
          LaunchChannel.elevated,
          cancelled ? '已取消管理员授权（UAC）' : '提权启动失败',
          cancelledByUser: cancelled,
        );
      }
      return LaunchOutcome(
        started: true,
        channel: LaunchChannel.elevated,
        pid: pid,
      );
    }

    // ── 普通通道（自身已提权时，子进程自动继承提权） ──
    try {
      final process = await Process.start(
        exePath,
        const <String>[],
        workingDirectory: workingDirectory,
        mode: ProcessStartMode.detached,
      );
      debugPrint('[LAUNCH-EXEC] ✅ 普通启动 PID=${process.pid} '
          '(自身提权=$selfElevated, 目标提权=$elevate)');
      return LaunchOutcome(
        started: true,
        channel: LaunchChannel.direct,
        pid: process.pid,
        process: process,
      );
    } on ProcessException catch (e) {
      // 🔴 ERROR_ELEVATION_REQUIRED(740)：exe 自带 requireAdministrator
      //   manifest，或注册表里残留 RUNASADMIN，而当前管理器未提权。
      //   这种情况不能用 cmd 兜底（同样会 740），唯一出路是提权通道。
      if (e.errorCode == kErrorElevationRequired && !selfElevated) {
        debugPrint('[LAUNCH-EXEC] 🔼 目标要求管理员权限(740)，改用提权通道');
        final pid = await ElevationService.shellExecuteRunAs(
          file: exePath,
          workingDirectory: workingDirectory,
        );
        if (pid == null && ElevationService.lastShellExecuteError == 0) {
          return const LaunchOutcome(
            started: true,
            channel: LaunchChannel.elevated,
          );
        }
        if (pid == null) {
          final cancelled =
              ElevationService.lastShellExecuteError == kErrorCancelled;
          return LaunchOutcome.failure(
            LaunchChannel.elevated,
            cancelled ? '已取消管理员授权（UAC）' : '提权启动失败',
            cancelledByUser: cancelled,
          );
        }
        return LaunchOutcome(
          started: true,
          channel: LaunchChannel.elevated,
          pid: pid,
        );
      }
      return _fallbackToShell(
        exePath: exePath,
        workingDirectory: workingDirectory,
        cause: e,
      );
    } catch (e) {
      return _fallbackToShell(
        exePath: exePath,
        workingDirectory: workingDirectory,
        cause: e,
      );
    }
  }

  /// 普通通道失败后的 cmd / c start 兜底
  static Future<LaunchOutcome> _fallbackToShell({
    required String exePath,
    required String workingDirectory,
    required Object cause,
  }) async {
    debugPrint('[LAUNCH-EXEC] ⚠️ Process.start 失败，回退 cmd /c start: $cause');
    // 🔴 cmd.exe 不接受 UNC 当前目录（"UNC paths are not supported"）
    final workDirForCmd =
        workingDirectory.startsWith(r'\\') ? null : workingDirectory;
    try {
      await Process.run(
        'cmd.exe',
        <String>['/c', 'start', '""', exePath],
        workingDirectory: workDirForCmd,
        runInShell: true,
      ).timeout(const Duration(seconds: 15), onTimeout: () {
        throw TimeoutException('cmd /c start timeout');
      });
      debugPrint('[LAUNCH-EXEC] ✅ 通过 cmd /c start 启动（无 PID）');
      return const LaunchOutcome(
        started: true,
        channel: LaunchChannel.shellFallback,
      );
    } catch (cmdError) {
      debugPrint('[LAUNCH-EXEC] ❌ cmd /c start 也失败: $cmdError');
      return LaunchOutcome.failure(
        LaunchChannel.shellFallback,
        '无法启动进程: $cmdError',
      );
    }
  }

  /// 启动工具进程（Magpie / LEProc）
  ///
  /// 与 [launchGame] 的差别：工具进程通常需要**保持 Process 引用**（便于 kill），
  /// 所以提权通道拿不到 Process 时要明确告诉调用方（process == null）。
  static Future<LaunchOutcome> launchTool({
    required String exePath,
    List<String> arguments = const <String>[],
    required String workingDirectory,
    required bool elevate,
  }) async {
    if (exePath.trim().isEmpty) {
      return const LaunchOutcome.failure(LaunchChannel.direct, '工具路径为空');
    }
    final selfElevated = ElevationService.isSelfElevated() ?? false;

    if (elevate && !selfElevated) {
      final pid = await ElevationService.shellExecuteRunAs(
        file: exePath,
        parameters: arguments.isEmpty ? null : _joinArguments(arguments),
        workingDirectory: workingDirectory,
      );
      if (pid == null && ElevationService.lastShellExecuteError == 0) {
        return const LaunchOutcome(
          started: true,
          channel: LaunchChannel.elevated,
        );
      }
      if (pid == null) {
        final cancelled =
            ElevationService.lastShellExecuteError == kErrorCancelled;
        return LaunchOutcome.failure(
          LaunchChannel.elevated,
          cancelled ? '已取消管理员授权（UAC）' : '提权启动失败',
          cancelledByUser: cancelled,
        );
      }
      return LaunchOutcome(
        started: true,
        channel: LaunchChannel.elevated,
        pid: pid,
      );
    }

    try {
      final process = await Process.start(
        exePath,
        arguments,
        workingDirectory: workingDirectory,
      );
      return LaunchOutcome(
        started: true,
        channel: LaunchChannel.direct,
        pid: process.pid,
        process: process,
      );
    } catch (e) {
      debugPrint('[LAUNCH-EXEC] ❌ 工具启动失败: $exePath → $e');
      return LaunchOutcome.failure(LaunchChannel.direct, '启动失败: $e');
    }
  }

  /// 把参数列表拼成命令行字符串（ShellExecuteEx 的 lpParameters 需要单个字符串）
  ///
  /// 规则与 Windows 命令行一致：含空格/制表符/引号的参数必须整体加双引号。
  static String _joinArguments(List<String> arguments) {
    return arguments.map(_quoteArgument).join(' ');
  }

  static String _quoteArgument(String arg) {
    if (arg.isEmpty) return '""';
    final needsQuote =
        arg.contains(' ') || arg.contains('\t') || arg.contains('"');
    if (!needsQuote) return arg;
    return '"${arg.replaceAll('"', r'\"')}"';
  }

  /// 仅供单测：暴露引号处理逻辑（提权通道传参正确性的关键点）
  @visibleForTesting
  static String debugJoinArguments(List<String> arguments) =>
      _joinArguments(arguments);
}
