/// 补丁落盘的**路径安全护栏**（纯 Dart，零 Flutter / 零 IO 依赖）。
///
/// ## 为什么必须单独一层
///
/// 补丁包来自第三方（鲲 / 2DFan / 社区），包内路径**完全不可信**：
/// `../../../Windows/System32/x.dll`（zip slip）、`C:\Windows\...` 绝对路径、
/// `CON`/`NUL` 保留名、`aux.txt`（Windows 下等价 `aux`）都能把文件写到
/// 我们没打算写的地方。方案移植自 GalGear `patches.rs:69-123`，但**判定更严**：
/// 参考项目只挡 `..` 与绝对路径，我们连保留名一起挡。
///
/// ## 为什么不"跳过不安全条目"而是"整包拒绝"
///
/// 一个包里出现穿越路径，只有两种可能：打包出错，或是恶意包。
/// 两种情况下**半装进去**都比不装更糟（用户以为装好了，实际缺文件）。
/// 所以 [validateEntryPaths] 一旦发现非法项就返回清单，调用方**整包拒绝**。
///
/// ⛔ 本文件只放纯函数，**不要** import flutter / dart:io。

/// Windows 保留设备名（不分大小写，**带扩展名也保留**：`con.txt` 同样非法）
const Set<String> _reservedNames = <String>{
  'con', 'prn', 'aux', 'nul', //
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// 单段与整体路径的长度上限（留出盘符与缓存目录余量，避免撞 MAX_PATH 260）
const int kMaxSegmentLength = 100;
const int kMaxEntryPathLength = 220;

final RegExp _illegalChars = RegExp(r'[<>:"|?*\x00-\x1F]');
final RegExp _drivePrefix = RegExp(r'^[A-Za-z]:');

/// 是否 Windows 保留设备名
bool isReservedWindowsName(String segment) {
  final base = segment.split('.').first.trim().toLowerCase();
  return _reservedNames.contains(base);
}

/// 清洗单段路径。返回 `''` 表示该段应被丢弃（空段 / `.`）。
///
/// - 非法字符 → `_`
/// - 结尾的点与空格剥掉（Windows 会静默丢弃，导致"写了但找不到"）
/// - 保留名 → 前面加 `_`（`con` → `_con`），⛔ 不拒绝，因为确实存在叫这个名字的补丁文件
/// - 超长 → 截断
String sanitizeSegment(String segment) {
  var s = segment.replaceAll(_illegalChars, '_').trim();
  // Windows 不接受结尾的 `.` 或空格
  while (s.isNotEmpty && (s.endsWith('.') || s.endsWith(' '))) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty || s == '.') return '';
  if (isReservedWindowsName(s)) s = '_$s';
  if (s.length > kMaxSegmentLength) {
    final dot = s.lastIndexOf('.');
    final ext = (dot > 0 && s.length - dot <= 8) ? s.substring(dot) : '';
    final stem = ext.isEmpty ? s : s.substring(0, dot);
    final keep = kMaxSegmentLength - ext.length;
    s = (keep > 0 ? stem.substring(0, keep) : stem) + ext;
  }
  return s;
}

/// 把包内原始条目名规范成 `/` 分隔的相对路径。
///
/// 返回 `null` = **不安全，必须拒绝**。判定表：
/// | 输入 | 结果 | 理由 |
/// |---|---|---|
/// | `a/b/c.txt` | `a/b/c.txt` | 正常 |
/// | `a\b\c.txt` | `a/b/c.txt` | 反斜杠归一 |
/// | `./a/b` | `a/b` | `.` 段丢弃 |
/// | `../a` | `null` | 穿越 |
/// | `a/../../b` | `null` | 中间穿越 |
/// | `/etc/x` | `null` | 绝对路径 |
/// | `C:\x` | `null` | 盘符 |
/// | `\\srv\share\x` | `null` | UNC |
/// | `CON` | `_CON` | 保留名（清洗，不拒） |
String? normalizeEntryPath(String raw) {
  var s = raw.replaceAll('\\', '/').trim();
  if (s.isEmpty) return null;
  // UNC：以 // 开头（反斜杠已归一）
  if (s.startsWith('//')) return null;
  if (_drivePrefix.hasMatch(s)) return null;
  // 前导 / 视为绝对路径
  if (s.startsWith('/')) return null;

  final out = <String>[];
  for (final seg in s.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null; // 穿越 —— 整包拒绝的触发点
    final clean = sanitizeSegment(seg);
    if (clean.isEmpty) continue;
    out.add(clean);
  }
  if (out.isEmpty) return null;

  final joined = out.join('/');
  if (joined.length > kMaxEntryPathLength) return null;
  return joined;
}

/// 是否安全（[normalizeEntryPath] 的非空判定）
bool isSafeEntryPath(String raw) => normalizeEntryPath(raw) != null;

/// 校验一批条目，返回**不安全项原文**（空列表 = 全部安全）
List<String> validateEntryPaths(Iterable<String> rawPaths) {
  final bad = <String>[];
  for (final p in rawPaths) {
    if (normalizeEntryPath(p) == null) bad.add(p);
  }
  return bad;
}

// ==================== 外层目录剥离 ====================

/// 剥壳结果
class PatchEntryLayout {
  const PatchEntryLayout({required this.wrapper, required this.paths});

  /// 被剥掉的外层目录名（`null` = 本来就没有外层目录）
  ///
  /// 🔴 P0-4 实测：4/4 真实补丁包都套了一层作者自起的目录
  /// （`hoshiori_patch_v102` / `【樱空汉化组】…Ver1.0`）。不剥就是
  /// `patch/<补丁名>/<作者目录>/…` 双层嵌套，用户得点两层才见到文件。
  final String? wrapper;

  /// 剥壳后的相对路径（已归一、已去掉空目录条目、已排序）
  final List<String> paths;
}

/// 解析包内条目布局并剥掉**唯一的**外层目录。
///
/// 剥壳条件（三条同时满足才剥，宁可少剥不可错剥）：
/// 1. 所有条目都在同一个顶层段下（统一前缀）
/// 2. 没有任何条目**等于**那个顶层段（说明它确实是目录，不是单个文件）
/// 3. 剥完之后至少还剩 1 条
///
/// 反例（不该剥）：包内只有一个文件 `patch.zip` —— 顶层段唯一但它是文件，
/// 剥了就什么都不剩。
PatchEntryLayout resolveLayout(Iterable<String> rawPaths) {
  final norm = <String>[];
  for (final raw in rawPaths) {
    final n = normalizeEntryPath(raw);
    if (n == null) continue;
    // 目录条目（原文以 / 或 \ 结尾）只用来判断结构，不进文件列表
    if (raw.endsWith('/') || raw.endsWith('\\')) continue;
    norm.add(n);
  }
  norm.sort();

  if (norm.isEmpty) {
    return PatchEntryLayout(wrapper: null, paths: norm);
  }

  String? wrapper;
  final firstSeg = norm.first.split('/').first;
  if (norm.every((p) => p.startsWith('$firstSeg/'))) {
    // 没有条目正好等于 firstSeg ⇒ 它是目录
    final isDir = !norm.contains(firstSeg);
    if (isDir) wrapper = firstSeg;
  }

  if (wrapper == null) {
    return PatchEntryLayout(wrapper: null, paths: norm);
  }

  final stripped = norm
      .map((p) => p.substring(wrapper!.length + 1))
      .where((p) => p.isNotEmpty)
      .toList()
    ..sort();

  // 剥完不能空
  if (stripped.isEmpty) {
    return PatchEntryLayout(wrapper: null, paths: norm);
  }
  return PatchEntryLayout(wrapper: wrapper, paths: stripped);
}
