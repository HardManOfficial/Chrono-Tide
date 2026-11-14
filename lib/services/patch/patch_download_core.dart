import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:pointycastle/export.dart' show SHA256Digest;

import '../../models/patch_resource.dart';

/// 补丁下载的**纯逻辑**部分（不依赖 Flutter / FFI）。
///
/// 抽出来的理由和 `openlist_update_core.dart` 一样：文件 IO 与 sha256 的
/// 正确性必须能**离线验证**。`patch_download_service.dart` 依赖
/// `flutter/foundation`（ChangeNotifier）与 `path_validator`（FFI 查磁盘），
/// 在纯 Dart 探针里跑不起来 —— 而这两块恰恰是最容易写错、也最需要跑测试的。
///
/// ⛔ 这里只放纯函数与纯 IO，**不要**引入任何 Flutter 依赖。

/// 可读字节数（`total > 0` 时带进度形式）
String formatPatchBytes(int bytes, [int total = 0]) {
  String human(double v) {
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (v >= 1024 * 1024) return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(0)} KB';
    return '${v.toStringAsFixed(0)} B';
  }

  if (total > 0) {
    return '${human(bytes.toDouble())} / ${human(total.toDouble())}';
  }
  return human(bytes.toDouble());
}

/// 补丁落盘文件名：`<站点标记>_<站内id>_<清洗后的标题>.<ext>`
///
/// 带站点与 id 前缀是**故意**的：只看文件名就知道它从哪来、对应哪条记录，
/// 用户手动翻缓存目录时不至于面对一堆 `patch.zip`。
///
/// 清洗规则（Windows 全量非法字符 + 长度上限）：
/// - `\ / : * ? " < > |` 与换行制表 → `_`
/// - 连续空白折叠成单个空格
/// - 标题截断到 60 字（避免超 MAX_PATH）
/// - 扩展名缺失或异常长 → 退回 `.zip`
String patchFileName(PatchResource resource, String url) {
  final uri = Uri.tryParse(url);
  var ext = uri == null ? '' : path.extension(uri.path);
  if (ext.isEmpty || ext.length > 6) ext = '.zip';

  final rawName = resource.title.trim();
  final safe = rawName
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final clipped = safe.length > 60 ? safe.substring(0, 60).trim() : safe;
  final stem = clipped.isEmpty ? 'patch' : clipped;

  return '${resource.site.tag}_${resource.id}_$stem$ext';
}

/// 压缩包名 → 解压目录的基名（去扩展名）。
///
/// `鲲_12345_汉化补丁.zip` → `鲲_12345_汉化补丁`
String archiveBaseName(String archiveFileName) {
  final name = path.basename(archiveFileName.trim());
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name.isEmpty ? 'patch' : name;
  final stem = name.substring(0, dot).trim();
  return stem.isEmpty ? 'patch' : stem;
}

/// 解压目标目录名：基名 + 去重后缀（`_2`、`_3`…）。
///
/// 🔴 **不能**直接复用已有目录：补丁包里常带与游戏同构的
/// `GameData/` 之类的树，两个补丁叠进同一个目录后用户根本无法分辨
/// 「这个文件是哪个补丁带的」。每次解压必须是**一个新的独立目录**。
String uniqueExtractDirName(
  String archiveFileName,
  Iterable<String> existingDirNames,
) {
  final base = archiveBaseName(archiveFileName);
  final taken = existingDirNames.map((e) => e.toLowerCase()).toSet();
  if (!taken.contains(base.toLowerCase())) return base;
  for (var i = 2; i < 1000; i++) {
    final candidate = '${base}_$i';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
  return '${base}_${DateTime.now().millisecondsSinceEpoch}';
}

/// 流式 sha256。
///
/// 🔴 补丁包动辄上 GB，⛔ **不能** `readAsBytes()` 整份读进内存
/// （`game_font_patch_service._sha256Of` 是全量读，那里只处理几 MB 的字体文件，
/// 这里不行）。
Future<String> sha256OfFile(String filePath) async {
  final digest = SHA256Digest();
  await for (final chunk in File(filePath).openRead()) {
    // openRead 给的是 List<int>，pointycastle 要 Uint8List
    final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    digest.update(data, 0, data.length);
  }
  final out = Uint8List(digest.digestSize);
  digest.doFinal(out, 0);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
