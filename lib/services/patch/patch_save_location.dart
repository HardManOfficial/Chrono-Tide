import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/path_helper.dart';

/// 补丁保存位置（PATCH-STATION，2026-11-10 用户定调）。
///
/// ## 语义边界（🔴 改代码前先读这段）
///
/// 补丁站**只是下载器**，和「下载游戏本体」同构：
///
/// - ✅ 下载到她/他自己选的目录
/// - ✅ 顺手把 zip 解压到同一个目录旁边
/// - ✅ 告诉她/他包里是什么、以后怎么用
/// - ⛔ **不往游戏目录写任何东西**
/// - ⛔ **不覆盖、不备份、不回滚、不启动游戏**
///
/// 「把补丁套用到游戏上」是以后独立开发的功能，不属于这里。
/// 因此本类只做一件事：**记住用户选的目录**。
///
/// ## 为什么默认值不是 `ChronoTide_Cache/patches`
///
/// 缓存目录会被「启动与手动扫缓存」的清理逻辑扫到，而补丁**下完就是成品**，
/// 不是可以随时重下的中间产物（有的直链会失效）。所以默认值放在库根下
/// 一个**不会被清理**的独立目录 `ChronoTide_Patches`。
class PatchSaveLocation {
  PatchSaveLocation._();

  static final PatchSaveLocation instance = PatchSaveLocation._();

  /// prefs 键：用户选定的补丁保存目录
  static const String prefsKey = 'patch_save_location';

  /// 默认建议目录名（库根下）
  static const String fallbackDirName = 'ChronoTide_Patches';

  /// 库根：游戏库/缓存所在的根目录。
  ///
  /// `downloadsDir` 正常是 `<库根>/ChronoTide_Cache/downloads`，但也可能是
  /// 未启用自定义安装时的 `<exe>/downloads`（见 `PathHelper.defaultDownloadsDir`）。
  /// 两种都要判对，否则默认保存目录会落进 `ChronoTide_Cache` 里被清理逻辑扫掉。
  static String get libraryRoot {
    final downloads = PathHelper.downloadsDir;
    final parent = path.dirname(downloads);
    final parentName = path.basename(parent).toLowerCase();
    if (parentName == PathHelper.downloadCacheFolderName.toLowerCase()) {
      return path.dirname(parent);
    }
    return parent;
  }

  /// 默认建议目录：`<库根>/ChronoTide_Patches`。
  ///
  /// 🔴 必须是 getter 而不是 `static final`：库根随用户的「安装位置」设置
  /// 变化（见 MEMORY 里 DL-CACHE-PER-INSTALL 那条），固化成常量会指到旧盘。
  static String get suggestedDir {
    return path.join(libraryRoot, fallbackDirName);
  }

  /// 用户选过的目录；`null` = 从没选过（UI 据此决定要不要弹选择框）
  Future<String?> stored() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(prefsKey)?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 实际生效的目录：用户选的 → 默认建议
  Future<String> resolve() async {
    final s = await stored();
    if (s != null) return s;
    return suggestedDir;
  }

  /// 记住目录。写入前会建目录并做一次写权限探测。
  Future<bool> set(String dir) async {
    final trimmed = dir.trim();
    if (trimmed.isEmpty) return false;
    if (!await ensureDir(trimmed)) return false;
    if (!await isWritable(trimmed)) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.setString(prefsKey, path.normalize(trimmed));
  }

  /// 忘掉用户选的目录（回到默认建议）
  Future<bool> clear() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.remove(prefsKey);
  }

  /// 建目录（已存在也算成功）
  Future<bool> ensureDir(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 写权限探测：真的写一个文件再删掉。
  ///
  /// ⛔ 不要用「目录存在 + 无异常」判断可写 —— 只读盘 / 权限受限目录
  /// 都能通过那种检查，然后在真正下载时才炸。
  Future<bool> isWritable(String dir) async {
    try {
      final probe = File(path.join(
          dir, '.ct_write_probe_${DateTime.now().microsecondsSinceEpoch}'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 弹系统目录选择框。
  ///
  /// [initialDir] 给了就用（上次的位置）；否则让系统记住上次位置。
  /// 返回 `null` = 用户取消。
  Future<String?> pick({
    String? title,
    String? initialDir,
  }) async {
    try {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: title ?? '选择补丁保存位置',
        initialDirectory: initialDir,
      );
      if (picked == null) return null;
      if (!await ensureDir(picked)) return null;
      return picked;
    } catch (_) {
      return null;
    }
  }
}
