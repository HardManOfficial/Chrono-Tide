/// 用系统默认浏览器打开外部 URL（Windows 实现，可裸 Dart VM 探针）。
///
/// 🔴🔴 **⛔ 绝不要用 `cmd /c start "" <url>` 打开带参数的地址**：
/// `cmd` 把 `&` 当命令分隔符，`…?response_type=code&client_id=…&state=…`
/// 真正到达浏览器的只剩第一个参数。2026-11-13 真机翻车现场：
/// NextMoe 授权页报 `ClientID/RedirectURI/State failed on the 'required' tag`、
/// Hikarinagi 报 `login is not supported` —— 看着像「站点不支持我们登录」，
/// 其实是我们自己把地址在 `&` 处截断了。
///
/// 所以主路径改为 `ShellExecuteW`（Win32 官方拉起方式，全程不经 shell，
/// `&` / `%` / `#` / 中文都原样保留），失败再退
/// `rundll32 url.dll,FileProtocolHandler` —— 它由 CreateProcess 直接拉起，
/// 同样不经过命令解释器。
///
/// ⛔ 刻意只依赖 `dart:ffi` / `dart:io` / `package:ffi`，不 import Flutter，
/// 好让 `dev_probe/external_url_launcher_probe.dart` 在裸 VM 里跑真值断言。
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

/// `ShellExecuteW` 的 native / dart 签名（hwnd, op, file, params, dir, show）。
typedef _ShellExecuteWNative = ffi.IntPtr Function(ffi.IntPtr,
    ffi.Pointer<Utf16>, ffi.Pointer<Utf16>, ffi.Pointer<Utf16>,
    ffi.Pointer<Utf16>, ffi.Int32);

typedef _ShellExecuteWDart = int Function(
    int,
    ffi.Pointer<Utf16>,
    ffi.Pointer<Utf16>,
    ffi.Pointer<Utf16>,
    ffi.Pointer<Utf16>,
    int);

/// `SW_SHOWNORMAL`
const int _kShowNormal = 1;

/// `ShellExecuteW` 的成功判据：返回值 > 32。
/// （≤32 是 `SE_ERR_*` 错误码，例如 `SE_ERR_NOASSOC` = 31 表示没有关联程序。）
const int _kShellExecuteMinSuccess = 32;

ffi.DynamicLibrary? _shell32;
bool _shell32Resolved = false;

ffi.DynamicLibrary? _shell32Lib() {
  if (!_shell32Resolved) {
    _shell32Resolved = true;
    try {
      _shell32 = ffi.DynamicLibrary.open('shell32.dll');
    } catch (_) {
      _shell32 = null;
    }
  }
  return _shell32;
}

/// 用 `ShellExecuteW` 打开 URL。成功返回 true。
///
/// 非 Windows 平台或 shell32 不可用时返回 false（由调用方退到别的路径）。
bool shellExecuteOpen(String url) {
  if (!Platform.isWindows || url.isEmpty) return false;
  final ffi.DynamicLibrary? lib = _shell32Lib();
  if (lib == null) return false;
  try {
    final _ShellExecuteWDart shellExecute =
        lib.lookupFunction<_ShellExecuteWNative, _ShellExecuteWDart>(
            'ShellExecuteW');
    final ffi.Pointer<Utf16> operation = 'open'.toNativeUtf16();
    final ffi.Pointer<Utf16> file = url.toNativeUtf16();
    try {
      final int result = shellExecute(
        0, // hwnd：没有父窗口
        operation,
        file, // lpFile：URL 原样传入，不做任何转义
        ffi.nullptr, // lpParameters
        ffi.nullptr, // lpDirectory
        _kShowNormal,
      );
      return result > _kShellExecuteMinSuccess;
    } finally {
      malloc.free(operation);
      malloc.free(file);
    }
  } catch (_) {
    // 拿不到符号 / 调用异常都只是「这条路不通」，交给上层换路。
    return false;
  }
}

/// 兜底：`rundll32 url.dll,FileProtocolHandler <url>`。
///
/// 与 `cmd` 的关键差别——`Process.start` 直接 CreateProcess，
/// URL 里的 `&` 不会被任何 shell 解析掉。
Future<bool> rundll32Open(String url) async {
  if (!Platform.isWindows || url.isEmpty) return false;
  try {
    final Process process = await Process.start(
      'rundll32',
      <String>['url.dll,FileProtocolHandler', url],
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
    return process.pid > 0;
  } catch (_) {
    return false;
  }
}

/// 用系统默认程序打开 URL。返回 false 表示所有路径都失败。
///
/// 顺序：`ShellExecuteW` → `rundll32` → 非 Windows 的 `xdg-open` / `open`。
Future<bool> launchExternalUrl(String url) async {
  if (url.trim().isEmpty) return false;
  if (Platform.isWindows) {
    if (shellExecuteOpen(url)) return true;
    return rundll32Open(url);
  }
  try {
    final String opener = Platform.isMacOS ? 'open' : 'xdg-open';
    final Process process = await Process.start(
      opener,
      <String>[url],
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
    return process.pid > 0;
  } catch (_) {
    return false;
  }
}
