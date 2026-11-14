// win32_registry_service.dart
// Win32 注册表读写 FFI 服务（仅 HKCU，无需管理员权限）
//
// 为什么不用 PowerShell / reg.exe：
//   · `powershell -NoProfile` 冷启动 300~800ms，且常被杀软拦截；
//   · `reg.exe` 在部分受限环境被策略禁用（本项目沙箱即如此）。
//   · 兼容性层要在**每次启动前**校验一次，必须是毫秒级且随时可用。
//
// 只实现本项目需要的三件事：读字符串、写字符串、删值。
// 不做枚举、不做子键遍历 —— 用不到的能力不写进来（最小实现）。
//
// ⚠️ HKEY 在 Win64 上是符号扩展的 32 位值：
//   `#define HKEY_CURRENT_USER ((HKEY)(ULONG_PTR)((LONG)0x80000001))`
//   直接传 0x80000001 会被零扩展成 0x0000000080000001 → 句柄无效。
//   Dart 的 int 是 64 位有符号，因此这里必须写字面量 -2147483647。

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════════
// 常量
// ═══════════════════════════════════════════════════════════════

/// (LONG)0x80000001 作为 64 位有符号整数（符号扩展后的 HKEY_CURRENT_USER）
const int _hkeyCurrentUser = -2147483647;

/// KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_ENUMERATE_SUB_KEYS | READ_CONTROL
const int _keyReadWrite = 0x2001F;

/// REG_SZ
const int _regSz = 1;

/// ERROR_SUCCESS
const int _errorSuccess = 0;

/// ERROR_FILE_NOT_FOUND（值不存在）
const int _errorFileNotFound = 2;

/// RegCreateKeyExW 的 dwOptions
const int _regOptionNonVolatile = 0;

// ═══════════════════════════════════════════════════════════════
// FFI 绑定
// ═══════════════════════════════════════════════════════════════

typedef _RegCreateKeyExWNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpSubKey,
  Uint32 reserved,
  Pointer<Utf16> lpClass,
  Uint32 dwOptions,
  Uint32 samDesired,
  Pointer<Void> lpSecurityAttributes,
  Pointer<IntPtr> phkResult,
  Pointer<Uint32> lpdwDisposition,
);
typedef _RegCreateKeyExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpSubKey,
  int reserved,
  Pointer<Utf16> lpClass,
  int dwOptions,
  int samDesired,
  Pointer<Void> lpSecurityAttributes,
  Pointer<IntPtr> phkResult,
  Pointer<Uint32> lpdwDisposition,
);

typedef _RegOpenKeyExWNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpSubKey,
  Uint32 ulOptions,
  Uint32 samDesired,
  Pointer<IntPtr> phkResult,
);
typedef _RegOpenKeyExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpSubKey,
  int ulOptions,
  int samDesired,
  Pointer<IntPtr> phkResult,
);

typedef _RegSetValueExWNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
  Uint32 reserved,
  Uint32 dwType,
  Pointer<Uint8> lpData,
  Uint32 cbData,
);
typedef _RegSetValueExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
  int reserved,
  int dwType,
  Pointer<Uint8> lpData,
  int cbData,
);

typedef _RegQueryValueExWNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);
typedef _RegQueryValueExWDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);

typedef _RegDeleteValueWNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
);
typedef _RegDeleteValueWDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
);

typedef _RegEnumValueWNative = Int32 Function(
  IntPtr hKey,
  Uint32 dwIndex,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpcchValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);
typedef _RegEnumValueWDart = int Function(
  int hKey,
  int dwIndex,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpcchValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);

/// 注册表枚举结束
const int _errorNoMoreItems = 259;

typedef _RegCloseKeyNative = Int32 Function(IntPtr hKey);
typedef _RegCloseKeyDart = int Function(int hKey);

/// 注册表字符串值读写（仅当前用户，仅 REG_SZ）
///
/// 所有方法都是**同步**的：一次调用 1~2ms，不需要 isolate；
/// 也刻意不抛异常 —— 读失败返回 null、写失败返回 false，
/// 由调用方决定是否降级，避免注册表问题炸掉启动流程。
class Win32RegistryService {
  Win32RegistryService._();

  static bool _initialized = false;

  static _RegCreateKeyExWDart? _regCreateKeyEx;
  static _RegOpenKeyExWDart? _regOpenKeyEx;
  static _RegSetValueExWDart? _regSetValueEx;
  static _RegQueryValueExWDart? _regQueryValueEx;
  static _RegDeleteValueWDart? _regDeleteValue;
  static _RegEnumValueWDart? _regEnumValue;
  static _RegCloseKeyDart? _regCloseKey;

  /// 当前平台是否可用（仅 Windows 且 advapi32 加载成功）
  static bool get isAvailable {
    _ensureInitialized();
    return _regOpenKeyEx != null && _regSetValueEx != null;
  }

  static void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isWindows) return;
    try {
      final lib = DynamicLibrary.open('advapi32.dll');
      _regCreateKeyEx =
          lib.lookupFunction<_RegCreateKeyExWNative, _RegCreateKeyExWDart>(
              'RegCreateKeyExW');
      _regOpenKeyEx =
          lib.lookupFunction<_RegOpenKeyExWNative, _RegOpenKeyExWDart>(
              'RegOpenKeyExW');
      _regSetValueEx =
          lib.lookupFunction<_RegSetValueExWNative, _RegSetValueExWDart>(
              'RegSetValueExW');
      _regQueryValueEx =
          lib.lookupFunction<_RegQueryValueExWNative, _RegQueryValueExWDart>(
              'RegQueryValueExW');
      _regDeleteValue =
          lib.lookupFunction<_RegDeleteValueWNative, _RegDeleteValueWDart>(
              'RegDeleteValueW');
      _regEnumValue =
          lib.lookupFunction<_RegEnumValueWNative, _RegEnumValueWDart>(
              'RegEnumValueW');
      _regCloseKey = lib
          .lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>('RegCloseKey');
    } catch (e) {
      debugPrint('[REGISTRY] ⚠️ advapi32 加载失败，注册表功能不可用: $e');
      _regOpenKeyEx = null;
      _regSetValueEx = null;
      _regQueryValueEx = null;
      _regDeleteValue = null;
      _regEnumValue = null;
      _regCloseKey = null;
    }
  }

  /// 读取字符串值。值或键不存在时返回 `null`。
  static String? readString({
    required String subKey,
    required String valueName,
  }) {
    _ensureInitialized();
    final open = _regOpenKeyEx;
    final query = _regQueryValueEx;
    final close = _regCloseKey;
    if (open == null || query == null || close == null) return null;

    final subKeyPtr = subKey.toNativeUtf16();
    final valuePtr = valueName.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    final typePtr = calloc<Uint32>();
    final sizePtr = calloc<Uint32>();
    Pointer<Uint8>? dataPtr;
    try {
      if (open(_hkeyCurrentUser, subKeyPtr, 0, _keyReadWrite, hKeyPtr) !=
          _errorSuccess) {
        return null;
      }
      final hKey = hKeyPtr.value;
      if (hKey == 0) return null;

      // 第一趟：探明长度（不含 null 终止符）
      var rc = query(hKey, valuePtr, nullptr, typePtr, nullptr, sizePtr);
      if (rc != _errorSuccess) return null;
      if (typePtr.value != _regSz) {
        debugPrint(
            '[REGISTRY] ⚠️ 值 "$valueName" 不是 REG_SZ（type=${typePtr.value}），跳过');
        return null;
      }

      final byteLen = sizePtr.value;
      if (byteLen == 0) return '';
      if (byteLen > 64 * 1024) {
        debugPrint('[REGISTRY] ⚠️ 值 "$valueName" 过长($byteLen B)，跳过');
        return null;
      }

      // 第二趟：取数据（多留 2 字节兜底未终止的脏数据）
      final buf = calloc<Uint8>(byteLen + 2);
      dataPtr = buf;
      final cbPtr = calloc<Uint32>()..value = byteLen + 2;
      try {
        rc = query(hKey, valuePtr, nullptr, typePtr, buf, cbPtr);
        if (rc != _errorSuccess) return null;
      } finally {
        calloc.free(cbPtr);
      }

      // 手工解码 UTF-16LE：避免对尾部脏数据 / 未终止字符串抛出
      final units = <int>[];
      for (var i = 0; i + 1 < byteLen; i += 2) {
        final unit = buf[i] | (buf[i + 1] << 8);
        if (unit == 0) break;
        units.add(unit);
      }
      return String.fromCharCodes(units);
    } catch (e) {
      debugPrint('[REGISTRY] ⚠️ 读取失败 "$valueName": $e');
      return null;
    } finally {
      if (hKeyPtr.value != 0) {
        try {
          close(hKeyPtr.value);
        } catch (_) {}
      }
      if (dataPtr != null) calloc.free(dataPtr);
      calloc.free(sizePtr);
      calloc.free(typePtr);
      calloc.free(hKeyPtr);
      calloc.free(valuePtr);
      calloc.free(subKeyPtr);
    }
  }

  /// 写入字符串值（REG_SZ，不存在则创建键）。成功返回 true。
  static bool writeString({
    required String subKey,
    required String valueName,
    required String value,
  }) {
    _ensureInitialized();
    final create = _regCreateKeyEx;
    final setValue = _regSetValueEx;
    final close = _regCloseKey;
    if (create == null || setValue == null || close == null) return false;

    final subKeyPtr = subKey.toNativeUtf16();
    final valueNamePtr = valueName.toNativeUtf16();
    final dataPtr = value.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    final dispositionPtr = calloc<Uint32>();
    try {
      final rc = create(
        _hkeyCurrentUser,
        subKeyPtr,
        0,
        nullptr,
        _regOptionNonVolatile,
        _keyReadWrite,
        nullptr,
        hKeyPtr,
        dispositionPtr,
      );
      if (rc != _errorSuccess) {
        debugPrint('[REGISTRY] ❌ RegCreateKeyExW 失败 rc=$rc');
        return false;
      }
      final hKey = hKeyPtr.value;
      if (hKey == 0) return false;

      // REG_SZ 含 null 终止符：字符数 * 2 字节
      final charCount = value.length;
      final byteLen = (charCount + 1) * 2;
      final setRc = setValue(
        hKey,
        valueNamePtr,
        0,
        _regSz,
        dataPtr.cast<Uint8>(),
        byteLen,
      );
      if (setRc != _errorSuccess) {
        debugPrint('[REGISTRY] ❌ RegSetValueExW 失败 rc=$setRc "$valueName"');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('[REGISTRY] ⚠️ 写入异常 "$valueName": $e');
      return false;
    } finally {
      if (hKeyPtr.value != 0) {
        try {
          close(hKeyPtr.value);
        } catch (_) {}
      }
      calloc.free(dispositionPtr);
      calloc.free(hKeyPtr);
      calloc.free(dataPtr);
      calloc.free(valueNamePtr);
      calloc.free(subKeyPtr);
    }
  }

  /// 删除值。成功或值本就不存在都返回 true（幂等）。
  static bool deleteValue({
    required String subKey,
    required String valueName,
  }) {
    _ensureInitialized();
    final open = _regOpenKeyEx;
    final del = _regDeleteValue;
    final close = _regCloseKey;
    if (open == null || del == null || close == null) return false;

    final subKeyPtr = subKey.toNativeUtf16();
    final valueNamePtr = valueName.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    try {
      final rc = open(_hkeyCurrentUser, subKeyPtr, 0, _keyReadWrite, hKeyPtr);
      if (rc == _errorFileNotFound) return true;
      if (rc != _errorSuccess) return false;
      final hKey = hKeyPtr.value;
      if (hKey == 0) return false;

      final delRc = del(hKey, valueNamePtr);
      if (delRc == _errorSuccess || delRc == _errorFileNotFound) return true;
      debugPrint('[REGISTRY] ⚠️ RegDeleteValueW 失败 rc=$delRc "$valueName"');
      return false;
    } catch (e) {
      debugPrint('[REGISTRY] ⚠️ 删除异常 "$valueName": $e');
      return false;
    } finally {
      if (hKeyPtr.value != 0) {
        try {
          close(hKeyPtr.value);
        } catch (_) {}
      }
      calloc.free(hKeyPtr);
      calloc.free(valueNamePtr);
      calloc.free(subKeyPtr);
    }
  }

  /// 枚举某子键下的所有值名。
  ///
  /// 用途：兼容性层的值名是 exe 绝对路径，而 Windows 路径大小写不敏感、
  /// 用户也可能换过盘符写法 —— 只靠精确字符串读写会留下"孤儿值"，
  /// 所以回滚/迁移前必须先按大小写不敏感的方式定位真实值名。
  static List<String> listValueNames({required String subKey}) {
    _ensureInitialized();
    final open = _regOpenKeyEx;
    final enumerate = _regEnumValue;
    final close = _regCloseKey;
    if (open == null || enumerate == null || close == null) return const [];

    // 注册表值名最大 16383 字符
    const int maxNameChars = 16384;
    const int maxEntries = 8192;

    final subKeyPtr = subKey.toNativeUtf16();
    final hKeyPtr = calloc<IntPtr>();
    final nameBuf = calloc<Uint16>(maxNameChars);
    final nameLenPtr = calloc<Uint32>();
    final typePtr = calloc<Uint32>();
    final dataSizePtr = calloc<Uint32>();
    final names = <String>[];
    try {
      final rc = open(_hkeyCurrentUser, subKeyPtr, 0, _keyReadWrite, hKeyPtr);
      if (rc != _errorSuccess) return const [];
      final hKey = hKeyPtr.value;
      if (hKey == 0) return const [];

      for (var index = 0; index < maxEntries; index++) {
        nameLenPtr.value = maxNameChars;
        dataSizePtr.value = 0;
        final erc = enumerate(
          hKey,
          index,
          nameBuf.cast<Utf16>(),
          nameLenPtr,
          nullptr,
          typePtr,
          nullptr,
          dataSizePtr,
        );
        // ERROR_MORE_DATA(234)：数据缓冲为 0 时必然出现，但值名已填充
        if (erc != _errorSuccess && erc != 234) {
          if (erc == _errorNoMoreItems) break;
          break;
        }
        final len = nameLenPtr.value;
        final units = <int>[];
        for (var i = 0; i < len && i < maxNameChars; i++) {
          final unit = nameBuf[i];
          if (unit == 0) break;
          units.add(unit);
        }
        if (units.isNotEmpty) names.add(String.fromCharCodes(units));
      }
    } catch (e) {
      debugPrint('[REGISTRY] ⚠️ 枚举值名失败: $e');
    } finally {
      if (hKeyPtr.value != 0) {
        try {
          close(hKeyPtr.value);
        } catch (_) {}
      }
      calloc.free(dataSizePtr);
      calloc.free(typePtr);
      calloc.free(nameLenPtr);
      calloc.free(nameBuf);
      calloc.free(hKeyPtr);
      calloc.free(subKeyPtr);
    }
    return names;
  }

  /// 仅供单测：重置初始化状态（允许注入/重载）
  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _regCreateKeyEx = null;
    _regOpenKeyEx = null;
    _regSetValueEx = null;
    _regQueryValueEx = null;
    _regDeleteValue = null;
    _regEnumValue = null;
    _regCloseKey = null;
  }
}
