// Phase 0 · 步骤 F：0.5 删除到回收站可行性（Dart FFI 直调 shell32!SHFileOperationW）
//
// 这是最终实现要走的路（项目已有大量 dart:ffi 直调系统 DLL 的先例，ffi 包已依赖）。
// 运行：
//   ./flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages=D:/CTLIB/.dart_tool/package_config.json \
//     dev_probe/phase0_recycle_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class SHFILEOPSTRUCTW extends Struct {
  external Pointer<Void> hwnd;          // HWND
  @Uint32() external int wFunc;         // UINT
  external Pointer<Uint16> pFrom;       // PCZZWSTR (double-null terminated)
  external Pointer<Uint16> pTo;         // PCZZWSTR
  @Uint16() external int fFlags;        // FILEOP_FLAGS
  @Int32() external int fAnyOperationsAborted; // BOOL
  external Pointer<Void> hNameMappings; // LPVOID
  external Pointer<Uint16> lpszProgressTitle; // PCWSTR
}

typedef _ShFileOpNative = Int32 Function(Pointer<SHFILEOPSTRUCTW>);
typedef _ShFileOpDart = int Function(Pointer<SHFILEOPSTRUCTW>);

final class SHQUERYRBINFO extends Struct {
  @Uint32() external int cbSize;
  @Int64() external int i64Size;
  @Int64() external int i64NumItems;
}

typedef _ShQueryRbNative = Int32 Function(
    Pointer<Utf16> pszRootPath, Pointer<SHQUERYRBINFO> pSHQueryRBInfo);
typedef _ShQueryRbDart = int Function(
    Pointer<Utf16> pszRootPath, Pointer<SHQUERYRBINFO> pSHQueryRBInfo);

const int FO_DELETE = 0x0003;
const int FOF_SILENT = 0x0004;
const int FOF_NOCONFIRMATION = 0x0010;
const int FOF_ALLOWUNDO = 0x0040;
const int FOF_NOERRORUI = 0x0400;
const int FOF_NOCONFIRMMKDIR = 0x0200;

Pointer<Uint16> _doubleNullUtf16(String s) {
  final units = s.codeUnits.toList()
    ..add(0)
    ..add(0);
  final p = calloc<Uint16>(units.length);
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  return p;
}

int _countFiles(String root) {
  final d = Directory(root);
  if (!d.existsSync()) return -1;
  var n = 0;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File) n++;
  }
  return n;
}

// 注：直接列 D:\$Recycle.Bin 会被 ACL 拒绝（系统目录），故回收站项数改用
//     官方接口 SHQueryRecycleBinW 查询。

void main() {
  final root = r'D:\CTLIB\.workbuddy\tmp\phase0\edge\recycle_dart';
  final d = Directory(root);
  if (d.existsSync()) d.deleteSync(recursive: true);
  d.createSync(recursive: true);
  File('$root\\a.txt').writeAsStringSync('hello-chronotide');
  File('$root\\b.txt').writeAsStringSync('second-file');
  Directory('$root\\sub').createSync();
  File('$root\\sub\\c.txt').writeAsStringSync('nested');

  print('[F] before: exists=${d.existsSync()} files=${_countFiles(root)}');
  final shell32 = DynamicLibrary.open('shell32.dll');
  final shQueryRb = shell32.lookupFunction<_ShQueryRbNative, _ShQueryRbDart>(
      'SHQueryRecycleBinW');
  final info = calloc<SHQUERYRBINFO>();
  info.ref.cbSize = sizeOf<SHQUERYRBINFO>();

  int q(DynamicLibrary _, Pointer<Utf16> drv) {
    final r = shQueryRb(drv, info);
    return r == 0 ? info.ref.i64NumItems : -1;
  }

  final dDrive = r'D:\'.toNativeUtf16();
  final cDrive = r'C:\'.toNativeUtf16();
  final beforeD = q(shell32, dDrive);
  final beforeC = q(shell32, cDrive);
  print('[F] 回收站项数 before: D=$beforeD  C=$beforeC');

  final shFileOp = shell32.lookupFunction<_ShFileOpNative, _ShFileOpDart>(
      'SHFileOperationW');

  final pFrom = _doubleNullUtf16(root);
  final st = calloc<SHFILEOPSTRUCTW>();
  st.ref.hwnd = nullptr;
  st.ref.wFunc = FO_DELETE;
  st.ref.pFrom = pFrom;
  st.ref.pTo = Pointer<Uint16>.fromAddress(0);
  st.ref.fFlags =
      FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;
  st.ref.hNameMappings = nullptr;
  st.ref.lpszProgressTitle = Pointer<Uint16>.fromAddress(0);

  final ret = shFileOp(st);
  final aborted = st.ref.fAnyOperationsAborted;
  print('[F] SHFileOperationW ret=$ret (0=成功), aborted=$aborted');

  // 给 shell 一点时间把项目落到回收站
  sleep(const Duration(milliseconds: 800));
  final after = d.existsSync();
  final afterD = q(shell32, dDrive);
  final afterC = q(shell32, cDrive);
  print('[F] after: exists=$after files=${_countFiles(root)}');
  print('[F] 回收站项数 after : D=$afterD  C=$afterC');
  print('[F] 结论: 目录已消失=${!after}  '
      'D盘回收站项数增量=${afterD - beforeD}  C盘增量=${afterC - beforeC}');

  calloc.free(st);
  calloc.free(pFrom);
  calloc.free(info);
  calloc.free(dDrive);
  calloc.free(cDrive);

  if (d.existsSync()) d.deleteSync(recursive: true);
}
