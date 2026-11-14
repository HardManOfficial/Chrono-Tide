// elevation_service.dart
// 管理员权限相关的 Win32 能力
//
// 三件事：
// 1. 判断当前进程 / 指定进程是否已提权（TokenElevation）
// 2. 以管理员身份拉起一个子进程（ShellExecuteExW + "runas" 动词）
// 3. 以管理员身份重启管理器自身（供"建议以管理员重启"入口使用）
//
// ⚠️ Windows 的硬边界（写在这里免得后人重复踩）：
//   · 从**未提权**进程启动需要提权的程序，`CreateProcess` 必然失败
//     （ERROR_ELEVATION_REQUIRED = 740），唯一通道是 ShellExecuteEx 的 runas 动词。
//   · runas 会弹 UAC，**无法绕过**。想全程静默只有一条路：管理器自己已提权，
//     此时用普通 CreateProcess 启动的子进程会继承提权令牌，零弹窗。
//   · runas 启动的进程与我们**没有父子关系**（由 shell 代为创建），
//     只能靠 PID / 进程名追踪，不能靠 Process 对象。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════
// 常量
// ═══════════════════════════════════════════════════════════════

/// ERROR_CANCELLED：用户在 UAC 对话框点了「否」
const int kErrorCancelled = 1223;

/// ERROR_ELEVATION_REQUIRED：需要提权才能启动
const int kErrorElevationRequired = 740;

const int _seeMaskNoCloseProcess = 0x00000040;
const int _seeMaskNoAsync = 0x00000100;
const int _seeMaskFlagNoUi = 0x00000400;

const int _swHide = 0;
const int _swShownormal = 1;

const int _tokenQuery = 0x0008;
const int _tokenElevation = 20;
const int _processQueryLimitedInformation = 0x1000;

// ═══════════════════════════════════════════════════════════════
// SHELLEXECUTEINFOW（x64 = 112 字节，字段顺序必须与 SDK 一致）
// ═══════════════════════════════════════════════════════════════

final class _ShellExecuteInfoW extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int fMask;

  @IntPtr()
  external int hwnd;

  external Pointer<Utf16> lpVerb;

  external Pointer<Utf16> lpFile;

  external Pointer<Utf16> lpParameters;

  external Pointer<Utf16> lpDirectory;

  @Int32()
  external int nShow;

  @IntPtr()
  external int hInstApp;

  external Pointer<Void> lpIDList;

  external Pointer<Utf16> lpClass;

  @IntPtr()
  external int hkeyClass;

  @Uint32()
  external int dwHotKey;

  @IntPtr()
  external int hIcon;

  @IntPtr()
  external int hProcess;
}

// ═══════════════════════════════════════════════════════════════
// FFI 绑定
// ═══════════════════════════════════════════════════════════════

typedef _ShellExecuteExWNative = Int32 Function(Pointer<_ShellExecuteInfoW>);
typedef _ShellExecuteExWDart = int Function(Pointer<_ShellExecuteInfoW>);

typedef _GetProcessIdNative = Uint32 Function(IntPtr hProcess);
typedef _GetProcessIdDart = int Function(int hProcess);

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _OpenProcessTokenNative = Int32 Function(
    IntPtr, Uint32, Pointer<IntPtr>);
typedef _OpenProcessTokenDart = int Function(int, int, Pointer<IntPtr>);

typedef _GetTokenInformationNative = Int32 Function(
    IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _GetTokenInformationDart = int Function(
    int, int, Pointer<Void>, int, Pointer<Uint32>);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

class ElevationService {
  ElevationService._();

  static bool _initialized = false;

  static _ShellExecuteExWDart? _shellExecuteExW;
  static _GetProcessIdDart? _getProcessId;
  static _CloseHandleDart? _closeHandle;
  static _OpenProcessDart? _openProcess;
  static _GetCurrentProcessDart? _getCurrentProcess;
  static _OpenProcessTokenDart? _openProcessToken;
  static _GetTokenInformationDart? _getTokenInformation;
  static _GetLastErrorDart? _getLastError;

  /// 最近一次 [shellExecuteRunAs] 的 Win32 错误码（0 = 成功）
  static int lastShellExecuteError = 0;

  static bool get isAvailable {
    _ensureInitialized();
    return _shellExecuteExW != null && _openProcessToken != null;
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) return;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final advapi32 = DynamicLibrary.open('advapi32.dll');

      _shellExecuteExW =
          shell32.lookupFunction<_ShellExecuteExWNative, _ShellExecuteExWDart>(
              'ShellExecuteExW');
      _getProcessId =
          kernel32.lookupFunction<_GetProcessIdNative, _GetProcessIdDart>(
              'GetProcessId');
      _closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
      _openProcess = kernel32
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      _getCurrentProcess = kernel32.lookupFunction<_GetCurrentProcessNative,
          _GetCurrentProcessDart>('GetCurrentProcess');
      _getLastError =
          kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
              'GetLastError');
      _openProcessToken = advapi32.lookupFunction<_OpenProcessTokenNative,
          _OpenProcessTokenDart>('OpenProcessToken');
      _getTokenInformation = advapi32.lookupFunction<_GetTokenInformationNative,
          _GetTokenInformationDart>('GetTokenInformation');
    } catch (e) {
      debugPrint('[ELEVATION] ⚠️ FFI 初始化失败，提权功能不可用: $e');
      _shellExecuteExW = null;
      _openProcessToken = null;
    }
  }

  // ══════════════════════════════════════════════
  // 权限检测
  // ══════════════════════════════════════════════

  static bool? _selfElevatedCache;

  /// 当前进程是否以管理员身份运行。
  ///
  /// 返回 null 表示检测失败（调用方应保守按"未提权"处理）。
  static bool? isSelfElevated({bool useCache = true}) {
    if (useCache && _selfElevatedCache != null) return _selfElevatedCache;
    _ensureInitialized();
    final openToken = _openProcessToken;
    final getInfo = _getTokenInformation;
    final getCurrent = _getCurrentProcess;
    final close = _closeHandle;
    if (openToken == null || getInfo == null || getCurrent == null) return null;

    final token = calloc<IntPtr>();
    final elevated = calloc<Uint32>();
    final retLen = calloc<Uint32>();
    try {
      if (openToken(getCurrent(), _tokenQuery, token) == 0) return null;
      if (token.value == 0) return null;
      if (getInfo(
              token.value, _tokenElevation, elevated.cast<Void>(), 4, retLen) ==
          0) {
        return null;
      }
      final result = elevated.value != 0;
      _selfElevatedCache = result;
      return result;
    } catch (_) {
      return null;
    } finally {
      if (token.value != 0 && close != null) {
        try {
          close(token.value);
        } catch (_) {}
      }
      calloc.free(retLen);
      calloc.free(elevated);
      calloc.free(token);
    }
  }

  /// 指定进程是否以管理员身份运行
  static bool? isProcessElevated(int pid) {
    _ensureInitialized();
    if (pid <= 0) return null;
    final openProcess = _openProcess;
    final openToken = _openProcessToken;
    final getInfo = _getTokenInformation;
    final close = _closeHandle;
    if (openProcess == null ||
        openToken == null ||
        getInfo == null ||
        close == null) {
      return null;
    }

    final hProc = openProcess(_processQueryLimitedInformation, 0, pid);
    if (hProc == 0) return null;
    final token = calloc<IntPtr>();
    final elevated = calloc<Uint32>();
    final retLen = calloc<Uint32>();
    try {
      if (openToken(hProc, _tokenQuery, token) == 0) return null;
      if (token.value == 0) return null;
      if (getInfo(
              token.value, _tokenElevation, elevated.cast<Void>(), 4, retLen) ==
          0) {
        return null;
      }
      return elevated.value != 0;
    } catch (_) {
      return null;
    } finally {
      if (token.value != 0) {
        try {
          close(token.value);
        } catch (_) {}
      }
      calloc.free(retLen);
      calloc.free(elevated);
      calloc.free(token);
      try {
        close(hProc);
      } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════
  // 提权启动
  // ══════════════════════════════════════════════

  /// 以管理员身份启动 [file]，返回新进程 PID（拿不到返回 null）。
  ///
  /// - 用户点「否」取消 UAC：返回 null，[lastShellExecuteError] = 1223。
  /// - 如果当前进程已提权，runas 不会弹窗，等同于普通启动。
  ///
  /// ⚠️ 该通道**不等待**进程退出（`SEE_MASK_NOCLOSEPROCESS` 只保证句柄，
  /// 我们取完 PID 就关闭句柄），以免拖住调用方的启动流程。
  static Future<int?> shellExecuteRunAs({
    required String file,
    String? parameters,
    String? workingDirectory,
    bool hidden = false,
  }) async {
    _ensureInitialized();
    final shellExecute = _shellExecuteExW;
    final getProcessId = _getProcessId;
    final close = _closeHandle;
    final getLastError = _getLastError;
    lastShellExecuteError = 0;

    if (shellExecute == null) {
      debugPrint('[ELEVATION] ⚠️ ShellExecuteExW 不可用');
      return null;
    }
    if (!File(file).existsSync()) {
      debugPrint('[ELEVATION] ⚠️ 目标文件不存在: $file');
      return null;
    }

    final verbPtr = 'runas'.toNativeUtf16();
    final filePtr = file.toNativeUtf16();
    final paramsPtr = parameters == null ? nullptr : parameters.toNativeUtf16();
    final dirPtr =
        workingDirectory == null ? nullptr : workingDirectory.toNativeUtf16();
    final info = calloc<_ShellExecuteInfoW>();
    try {
      info.ref
        ..cbSize = sizeOf<_ShellExecuteInfoW>()
        ..fMask = _seeMaskNoCloseProcess | _seeMaskNoAsync | _seeMaskFlagNoUi
        ..hwnd = 0
        ..lpVerb = verbPtr
        ..lpFile = filePtr
        ..lpParameters = paramsPtr
        ..lpDirectory = dirPtr
        ..nShow = hidden ? _swHide : _swShownormal
        ..hInstApp = 0
        ..lpIDList = nullptr
        ..lpClass = nullptr
        ..hkeyClass = 0
        ..dwHotKey = 0
        ..hIcon = 0
        ..hProcess = 0;

      // ⚠️ 这两个调用必须紧邻：中间插入任何 FFI 都可能冲掉 GetLastError
      final ok = shellExecute(info);
      final err = getLastError == null ? 0 : getLastError();
      if (ok == 0) {
        lastShellExecuteError = err;
        debugPrint('[ELEVATION] ❌ 提权启动失败: $file (错误码 $err'
            '${err == kErrorCancelled ? " = 用户取消 UAC" : ""})');
        return null;
      }

      final hProcess = info.ref.hProcess;
      if (hProcess == 0) {
        // 没有进程句柄：可能走了 DDE/COM 委托，无法拿 PID
        debugPrint('[ELEVATION] ⚠️ 已提权启动但未取得进程句柄: $file');
        return null;
      }
      int pid = 0;
      if (getProcessId != null) {
        try {
          pid = getProcessId(hProcess);
        } catch (_) {}
      }
      if (close != null) {
        try {
          close(hProcess);
        } catch (_) {}
      }
      debugPrint('[ELEVATION] ✅ 已提权启动: $file (PID=$pid)');
      return pid > 0 ? pid : null;
    } catch (e) {
      debugPrint('[ELEVATION] ❌ 提权启动异常: $e');
      return null;
    } finally {
      calloc.free(info);
      if (paramsPtr != nullptr) calloc.free(paramsPtr);
      if (dirPtr != nullptr) calloc.free(dirPtr);
      calloc.free(filePtr);
      calloc.free(verbPtr);
    }
  }

  /// 以管理员身份重启管理器自身。
  ///
  /// 返回 true 表示新实例已拉起（调用方应随后退出当前实例）。
  /// 若当前已是管理员，仍然会拉起新实例（调用方需自行判断是否真的需要）。
  static Future<bool> relaunchSelfAsAdmin({String? arguments}) async {
    final exe = Platform.resolvedExecutable;
    final pid = await shellExecuteRunAs(
      file: exe,
      parameters: arguments,
      workingDirectory: File(exe).parent.path,
    );
    return pid != null;
  }

  /// 仅供单测重置
  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _selfElevatedCache = null;
    lastShellExecuteError = 0;
    _shellExecuteExW = null;
    _openProcessToken = null;
    _getTokenInformation = null;
  }
}
