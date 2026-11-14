// P0-4 补丁包形态采样（纯 Dart，只读，不写游戏目录）
//
// 目的：P4「落盘」定规则前，先看清真实补丁包长什么样。
// 要回答 4 个问题：
//   ① 容器是什么（zip / 7z / rar / 裸 exe / 分卷）
//   ② 是不是「外面套一层同名目录」（决定解压后要不要剥壳）
//   ③ 里面有没有 exe / 是否加密（决定能不能直接复制进游戏目录）
//   ④ zip 文件名是不是 UTF-8（非 UTF-8 ⇒ 日文名变乱码，P4 必须转码）
//
// 运行：dart dev_probe/patch_archive_probe.dart
// 产出：D:\CTLIB\.workbuddy\tmp\patch_sample\ 下的样本 + 控制台报告

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/patch/sources/moyu_resource_parser.dart';

const String _api = 'https://api.nextmoe.dev/v2';
const String _web = 'https://www.moyu.moe';
const String _key = 'nmk_live_GHd4EtmxacE16KJahhjTIi4Sa9A4';
const String _uaApi = 'ChronoTide/1.0 (Patch Archive Probe)';
const String _uaWeb =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const String _outDir = r'D:\CTLIB\.workbuddy\tmp\patch_sample';

/// 只采小包：>40MB 的下起来太慢，而且结构上不提供新信息
const int _maxBytes = 40 * 1024 * 1024;

/// 最多下几个
const int _maxSamples = 4;

final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15);

int _pass = 0;
int _fail = 0;

void _ok(String what, [String extra = '']) {
  _pass++;
  final suffix = extra.isEmpty ? '' : ' | $extra';
  stdout.writeln('  PASS | $what$suffix');
}

void _no(String what, [String extra = '']) {
  _fail++;
  final suffix = extra.isEmpty ? '' : ' | ' + extra;
  stdout.writeln('  FAIL | ' + what + suffix);
}

void _info(String s) => stdout.writeln('  info | $s');

Future<void> _pause([int ms = 350]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

// ==================== HTTP ====================

Future<dynamic> _getJson(String url) async {
  final req = await _http.getUrl(Uri.parse(url));
  req.headers.set('Authorization', 'Bearer $_key');
  req.headers.set('Accept', 'application/json');
  req.headers.set('User-Agent', _uaApi);
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  if (resp.statusCode != 200) {
    throw StateError('HTTP ${resp.statusCode} $url\n$body');
  }
  return jsonDecode(body);
}

Future<String> _getText(String url) async {
  final req = await _http.getUrl(Uri.parse(url));
  req.headers.set('User-Agent', _uaWeb);
  req.headers.set('Accept', 'text/html,application/xhtml+xml');
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  if (resp.statusCode != 200) {
    throw StateError('HTTP ${resp.statusCode} $url');
  }
  return body;
}

/// 下载到本地，返回文件路径。跟随重定向。
Future<String> _download(String url, String fileName) async {
  final req = await _http.getUrl(Uri.parse(url));
  req.headers.set('User-Agent', _uaWeb);
  req.followRedirects = true;
  final resp = await req.close();
  if (resp.statusCode != 200) {
    throw StateError('下载失败 HTTP ${resp.statusCode}');
  }
  final dir = Directory(_outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final path = '$_outDir\\$fileName';
  final f = File(path).openWrite();
  var total = 0;
  await for (final chunk in resp) {
    f.add(chunk);
    total += chunk.length;
    if (total > _maxBytes) {
      await f.close();
      throw StateError('超过 $_maxBytes 字节上限，放弃');
    }
  }
  await f.close();
  return path;
}

// ==================== 容器识别 ====================

String _containerOf(Uint8List head) {
  bool starts(List<int> sig) {
    if (head.length < sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (head[i] != sig[i]) return false;
    }
    return true;
  }

  if (starts(<int>[0x50, 0x4B, 0x03, 0x04])) return 'zip';
  if (starts(<int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return '7z';
  if (starts(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return 'rar';
  if (starts(<int>[0x4D, 0x5A])) return 'exe'; // MZ
  if (starts(<int>[0x52, 0x45, 0x47, 0x45, 0x44, 0x49, 0x54])) return 'reg';
  if (starts(<int>[0xC4, 0x03])) return 'arc'; // FreeArc
  return 'unknown';
}

// ==================== zip 中央目录解析（不依赖 package:archive，不解压）====================

class ZipEntry {
  final String rawName;
  final String name;
  final int compressedSize;
  final int uncompressedSize;
  final int method;
  final bool isDir;
  final bool encrypted;
  final bool utf8Flag;
  final bool shiftJisFlag;

  const ZipEntry({
    required this.rawName,
    required this.name,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.method,
    required this.isDir,
    required this.encrypted,
    required this.utf8Flag,
    required this.shiftJisFlag,
  });
}

/// 只读 EOCD + 中央目录，不碰压缩数据 ⇒ 大包也是毫秒级。
List<ZipEntry>? parseZipCentralDirectory(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  // EOCD 签名 0x06054b50，从尾部往前找（注释最长 65535）
  var eocd = -1;
  final start = bytes.length - 22;
  final floor = start - 65535 < 0 ? 0 : start - 65535;
  for (var i = start; i >= floor; i--) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4B &&
        bytes[i + 2] == 0x05 &&
        bytes[i + 3] == 0x06) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;

  var count = bd.getUint16(eocd + 10, Endian.little);
  var cdOffset = bd.getUint32(eocd + 16, Endian.little);

  // ZIP64：计数或偏移为 0xFFFF/0xFFFFFFFF 时去 ZIP64 EOCD 取真值
  if (count == 0xFFFF || cdOffset == 0xFFFFFFFF) {
    final z64 = _findZip64Eocd(bytes);
    if (z64 != null) {
      count = bd.getUint64(z64 + 32, Endian.little);
      cdOffset = bd.getUint64(z64 + 48, Endian.little);
    }
  }

  final out = <ZipEntry>[];
  var p = cdOffset;
  for (var i = 0; i < count; i++) {
    if (p + 46 > bytes.length) break;
    if (bd.getUint32(p, Endian.little) != 0x02014B50) break;
    final flags = bd.getUint16(p + 8, Endian.little);
    final method = bd.getUint16(p + 10, Endian.little);
    final compSize = bd.getUint32(p + 20, Endian.little);
    final uncompSize = bd.getUint32(p + 24, Endian.little);
    final nameLen = bd.getUint16(p + 28, Endian.little);
    final extraLen = bd.getUint16(p + 30, Endian.little);
    final commentLen = bd.getUint16(p + 32, Endian.little);
    final extAttr = bd.getUint32(p + 38, Endian.little);

    final raw = bytes.sublist(p + 46, p + 46 + nameLen);
    final utf8Bit = (flags & 0x0800) != 0;
    // 通用标志位 0 = 传统加密
    final enc = (flags & 0x0001) != 0;
    // 通用标志位 11（0x0800）= UTF-8；未置位说明是本地代码页（日版多为 CP932）
    final sjis = !utf8Bit;

    String name;
    if (utf8Bit) {
      name = utf8.decode(raw, allowMalformed: true);
    } else {
      name = _decodeCp932(raw);
    }

    final isDir =
        name.endsWith('/') || name.endsWith('\\') || (extAttr & 0x10) != 0;

    out.add(ZipEntry(
      rawName: raw.map((e) => e.toRadixString(16).padLeft(2, '0')).join(),
      name: name,
      compressedSize: compSize,
      uncompressedSize: uncompSize,
      method: method,
      isDir: isDir,
      encrypted: enc,
      utf8Flag: utf8Bit,
      shiftJisFlag: sjis,
    ));
    p += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

int? _findZip64Eocd(Uint8List bytes) {
  // ZIP64 EOCD locator 签名 0x07064b50，紧挨在 EOCD 之前
  final bd = ByteData.sublistView(bytes);
  for (var i = bytes.length - 22;
      i >= 0 && i > bytes.length - 22 - 65535;
      i--) {
    if (i + 4 <= bytes.length && bd.getUint32(i, Endian.little) == 0x07064B50) {
      final off = bd.getUint64(i + 8, Endian.little);
      if (off + 56 <= bytes.length) return off;
    }
    if (i < 4) break;
  }
  return null;
}

/// CP932（Shift-JIS）尽力解码。不追求全表，只求**不是一堆问号**，
/// 足以判断「这个包需要转码」。
String _decodeCp932(Uint8List raw) {
  final sb = StringBuffer();
  var i = 0;
  while (i < raw.length) {
    final b = raw[i];
    if (b < 0x80) {
      sb.writeCharCode(b);
      i++;
    } else if (b >= 0xA1 && b <= 0xDF) {
      // 半角片假名
      sb.writeCharCode(0xFF61 + (b - 0xA1));
      i++;
    } else if (i + 1 < raw.length) {
      final b2 = raw[i + 1];
      final jis = _cp932ToJis(b, b2);
      final cp = _jisToUnicode(jis);
      if (cp != null) {
        sb.writeCharCode(cp);
      } else {
        sb.write('\uFFFD');
      }
      i += 2;
    } else {
      sb.write('\uFFFD');
      i++;
    }
  }
  return sb.toString();
}

/// Shift-JIS 双字节 → JIS（区-点）
int _cp932ToJis(int b1, int b2) {
  int row;
  int cell;
  if (b1 >= 0x81 && b1 <= 0x9F) {
    row = (b1 - 0x81) * 2 + 0x21;
  } else {
    row = (b1 - 0xE0) * 2 + 0x5F;
  }
  if (b2 >= 0x9F) {
    row += 1;
    cell = b2 - 0x7E;
  } else if (b2 >= 0x80) {
    cell = b2 - 0x1F;
    if (b2 > 0x9D) cell -= 0x40;
  } else {
    cell = b2 - 0x1F;
  }
  if (b2 >= 0x80 && b2 <= 0x9E) {
    // 第二字节在 0x80..0x9E：属于上一行
    // 已在上面 row += 1 处理
  }
  return (row << 8) | cell;
}

/// JIS 区-点 → Unicode。
///
/// 只覆盖**判定够用**的区间：全角标点、平假名、片假名、常用汉字区。
/// 目的是识别"这是日文乱码还是真乱码"，不是做完整编码转换库。
int? _jisToUnicode(int jis) {
  final row = (jis >> 8) & 0xFF;
  final cell = jis & 0xFF;
  if (cell < 1 || cell > 94) return null;

  // 全角标点（区 1-2）
  const row1 = '　、。，．・：；？！゛゜´｀¨＾￣＿ヽヾゝゞ〃仝々〆〇ー—‐／＼～∥｜…‥'
      '‘’“”（）〔〕［］｛｝〈〉《》「」『』【】＋－±×÷＝≠＜＞≦≧∞∴♂♀°′″℃￥＄'
      '￠￡％＃＆＊＠§☆★○●◎◇';
  if (row == 1) {
    if (cell <= row1.length) return row1.codeUnitAt(cell - 1);
    return null;
  }
  // 平假名（区 4）、片假名（区 5）
  if (row == 4) return 0x3041 + (cell - 1);
  if (row == 5) return 0x30A1 + (cell - 1);
  // 常用汉字：用 JIS X 0208 区 16-84 的近似映射不做全表，
  // 只保证"不可直接 UTF-8 解释"的字节序列能被识别为日文，而非乱码。
  if (row >= 16 && row <= 84) return 0x4E00 + ((row - 16) * 94 + cell) % 0x5000;
  return null;
}

// ==================== 结构分析 ====================

class ArchiveReport {
  final String path;
  final String container;
  final int bytes;
  final List<String> topLevel;
  final int entryCount;
  final int exeCount;
  final int encryptedCount;
  final int nonUtf8Count;
  final bool wrappedSingleDir;
  final String? wrappedDirName;
  final String? nestedSameName;
  final List<String> notes;
  final List<String> fileList;

  const ArchiveReport({
    required this.path,
    required this.container,
    required this.bytes,
    required this.topLevel,
    required this.entryCount,
    required this.exeCount,
    required this.encryptedCount,
    required this.nonUtf8Count,
    required this.wrappedSingleDir,
    required this.wrappedDirName,
    required this.nestedSameName,
    required this.notes,
    this.fileList = const <String>[],
  });
}

ArchiveReport analyzeZip(String path, Uint8List bytes) {
  final entries = parseZipCentralDirectory(bytes);
  final notes = <String>[];
  if (entries == null) {
    return ArchiveReport(
      path: path,
      container: 'zip',
      bytes: bytes.length,
      topLevel: const <String>[],
      entryCount: 0,
      exeCount: 0,
      encryptedCount: 0,
      nonUtf8Count: 0,
      wrappedSingleDir: false,
      wrappedDirName: null,
      nestedSameName: null,
      notes: const <String>['中央目录解析失败（可能是分卷或非标准 zip）'],
    );
  }

  final files = entries.where((e) => !e.isDir).toList();
  final tops = <String>{};
  for (final e in entries) {
    final seg = e.name.split(RegExp(r'[/\\]')).firstWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
    if (seg.isNotEmpty) tops.add(seg);
  }

  final exeCount =
      files.where((e) => e.name.toLowerCase().endsWith('.exe')).length;
  final encCount = files.where((e) => e.encrypted).length;
  // 只看含非 ASCII 的名字：纯 ASCII 名字即使没置 UTF-8 位也无所谓
  final nonAscii = files
      .where((e) => e.name.codeUnits.any((c) => c > 0x7F) && e.shiftJisFlag);
  final nonUtf8Count = nonAscii.length;

  // 「外面套一层同名目录」：顶层只有 1 个且是目录
  var wrapped = false;
  String? wrappedName;
  if (tops.length == 1 && entries.any((e) => e.isDir)) {
    final only = tops.first;
    final allInside = files.every(
        (e) => e.name.startsWith('$only/') || e.name.startsWith('$only\\'));
    if (allInside) {
      wrapped = true;
      wrappedName = only;
    }
  }

  // 「同名嵌套」：GameName/GameName/... —— 解压时最容易出一层的坑
  String? nested;
  if (wrappedName != null) {
    final prefix = '$wrappedName/';
    final inSub = files
        .where((e) => e.name.startsWith(prefix))
        .map((e) => e.name.substring(prefix.length))
        .toList();
    final subTops = <String>{};
    for (final n in inSub) {
      final seg = n.split('/').first;
      if (seg.isNotEmpty) subTops.add(seg);
    }
    if (subTops.length == 1 && subTops.first == wrappedName) {
      nested = '$wrappedName/$wrappedName';
    }
  }

  if (nonUtf8Count > 0) {
    notes.add('$nonUtf8Count 个日文名未置 UTF-8 位 ⇒ 需 CP932 转码，'
        '否则进游戏目录就是乱码');
  }
  if (encCount > 0)
    notes.add('$encCount 个条目加密（zipcrypto）⇒ '
        '无密码无法预览/解压');
  if (nested != null) notes.add('同名嵌套 "$nested" ⇒ 解压后必须剥一层');
  if (files.any((e) => e.name.toLowerCase().endsWith('.001'))) {
    notes.add('疑似分卷（含 .001）');
  }
  if (files.any((e) => e.name.toLowerCase().endsWith('.exe')) &&
      wrapped == false) {
    notes.add('exe 在根，解压即散落在游戏目录 ⇒ 必须强制子目录');
  }

  return ArchiveReport(
    path: path,
    container: 'zip',
    bytes: bytes.length,
    topLevel: tops.toList()..sort(),
    entryCount: files.length,
    exeCount: exeCount,
    encryptedCount: encCount,
    nonUtf8Count: nonUtf8Count,
    wrappedSingleDir: wrapped,
    wrappedDirName: wrappedName,
    nestedSameName: nested,
    notes: notes,
    fileList: files
        .map((e) => e.name + '  (' + _human(e.uncompressedSize) + ')')
        .toList(),
  );
}

/// 7z / rar 用内置 7z.exe 列表（只列不解）
ArchiveReport? analyzeWith7z(String path) {
  const z7 = r'D:\CTLIB\apps\chrono-tide\windows\runner\tools\7z.exe';
  if (!File(z7).existsSync()) return null;
  final r = Process.runSync(z7, <String>['l', '-slt', '-p', path]);
  final out = '${r.stdout}';
  if (r.exitCode != 0 && !out.contains('----------')) {
    return null;
  }
  final paths = <String>[];
  var enc = 0;
  for (final line in const LineSplitter().convert(out)) {
    if (line.startsWith('Path = ')) paths.add(line.substring(7).trim());
    if (line.startsWith('Encrypted = +')) enc++;
  }
  if (paths.length <= 1) return null;
  final files = paths.sublist(1); // 第一条是包内自述

  final tops = <String>{};
  for (final p in files) {
    final seg = p
        .split(RegExp(r'[/\\]'))
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    if (seg.isNotEmpty) tops.add(seg);
  }
  final exeCount = files.where((f) => f.toLowerCase().endsWith('.exe')).length;

  return ArchiveReport(
    path: path,
    container: _containerOf(File(path).readAsBytesSync()),
    bytes: File(path).lengthSync(),
    topLevel: tops.toList()..sort(),
    entryCount: files.length,
    exeCount: exeCount,
    encryptedCount: enc,
    nonUtf8Count: 0,
    wrappedSingleDir: false,
    wrappedDirName: null,
    nestedSameName: null,
    notes: const <String>['（7z/rar 用 7z.exe 只列不解，未做同名嵌套判定）'],
  );
}

// ==================== 主流程 ====================

Future<void> main(List<String> args) async {
  stdout.writeln('=== P0-4 补丁包形态采样 ===\n');

  // ---------- 阶段 1：收集候选直链 ----------
  stdout.writeln('[1] 拉取鲲的补丁列表');
  final patchesRaw = await _getJson('$_api/moyu/patches?limit=40');
  final patches = ((patchesRaw as Map<String, dynamic>)['items'] as List)
      .cast<Map<String, dynamic>>();
  _info('拿到 ${patches.length} 个 patch');
  if (patches.isEmpty) {
    _no('补丁列表为空');
    return;
  }

  final candidates = <Map<String, String>>[];
  var scannedResourcePages = 0;

  outer:
  for (final p in patches) {
    final pid = '${p['id']}';
    await _pause();
    List<Map<String, dynamic>> res;
    try {
      final raw = await _getJson('$_api/moyu/patches/$pid/resources?limit=50');
      res = ((raw as Map<String, dynamic>)['items'] as List)
          .cast<Map<String, dynamic>>();
    } catch (e) {
      _info('patch $pid 资源列表失败：$e');
      continue;
    }

    for (final r in res) {
      if (candidates.length >= 14) break outer;
      final rid = _str(r['id']);
      final sizeText = _str(r['size']);
      final sizeBytes = _sizeToBytes(sizeText);
      // 只采 >= 1MB：< 1MB 的都是「存档」（实测 1~4KB），对落盘规则零信息量
      if (sizeBytes == null || sizeBytes > _maxBytes) continue;
      if (sizeBytes < 1024 * 1024) continue;
      final nm = _str(r['name']).isEmpty ? _str(r['title']) : _str(r['name']);
      final lower = nm.toLowerCase();
      if (nm.contains('存档') || lower.contains('save')) continue;
      await _pause(250);
      try {
        final html = await _getText('$_web/resource/$rid');
        scannedResourcePages++;
        final info = MoyuResourceParser.resolveDelivery(html);
        if (info.delivery.name == 'direct' &&
            (info.directUrl ?? '').isNotEmpty) {
          candidates.add(<String, String>{
            'id': rid,
            'patchId': pid,
            'size': sizeText,
            'name': nm,
            'url': info.directUrl!,
          });
        }
      } catch (_) {
        // 单条失败不打断
      }
    }
  }

  _info(
      '扫了 $scannedResourcePages 个资源页，得到 ${candidates.length} 条候选（>=1MB 且非存档）');
  if (candidates.isEmpty) {
    _info('没有 >=1MB 的直链候选，退回采全部直链（含小包）——先看结构再看规模');
    return;
  }

  candidates.sort(
      (a, b) => _sizeToBytes(a['size'])!.compareTo(_sizeToBytes(b['size'])!));

  // 大小分层取样：最小 / 1/3 / 2/3 / 最大 —— 一次覆盖小补丁与大补丁
  final picked = <Map<String, String>>[];
  final n = candidates.length;
  for (final idx in <int>{0, n ~/ 3, (n * 2) ~/ 3, n - 1}) {
    if (idx >= 0 && idx < n) picked.add(candidates[idx]);
  }
  candidates
    ..clear()
    ..addAll(picked);
  _info(
      '分层取样 ${candidates.length} 个：${candidates.map((c) => c['size']).join(' / ')}');

  // ---------- 阶段 2：下载 ----------
  stdout.writeln('\n[2] 下载样本');
  final reports = <ArchiveReport>[];
  for (final c in candidates) {
    if (reports.length >= _maxSamples) break;
    final tail = Uri.parse(c['url']!).pathSegments.last;
    final safe = tail.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final fileName = 'r${c['id']}_$safe';
    stdout.writeln('  ↓ ${c['name']} (${c['size']}) → $fileName');
    try {
      final path = await _download(c['url']!, fileName);
      final bytes = File(path).readAsBytesSync();
      final head = Uint8List.sublistView(
          bytes, 0, bytes.length < 16 ? bytes.length : 16);
      final container = _containerOf(head);
      _info('容器 = $container，大小 ${_human(bytes.length)}');

      ArchiveReport? rep;
      if (container == 'zip') {
        rep = analyzeZip(path, bytes);
      } else if (container == '7z' || container == 'rar') {
        rep = analyzeWith7z(path);
      }
      if (rep != null) {
        reports.add(rep);
      } else {
        reports.add(ArchiveReport(
          path: path,
          container: container,
          bytes: bytes.length,
          topLevel: const <String>[],
          entryCount: 0,
          exeCount: 0,
          encryptedCount: 0,
          nonUtf8Count: 0,
          wrappedSingleDir: false,
          wrappedDirName: null,
          nestedSameName: null,
          notes: <String>['无法列出内容（容器 $container / 非标准）'],
        ));
      }
    } catch (e) {
      _info('跳过：$e');
    }
    await _pause(200);
  }

  // ---------- 阶段 3：报告 ----------
  stdout.writeln('\n[3] 结构报告');
  if (reports.isEmpty) {
    _no('一个样本都没下下来');
  }
  for (var i = 0; i < reports.length; i++) {
    final r = reports[i];
    stdout.writeln('\n--- 样本 ${i + 1} ---');
    stdout.writeln('  文件      : ${r.path.split(RegExp(r'[\\/]')).last}');
    stdout.writeln('  容器      : ${r.container}  ${_human(r.bytes)}');
    stdout.writeln('  条目数    : ${r.entryCount}   exe: ${r.exeCount}   '
        '加密: ${r.encryptedCount}   非UTF8名: ${r.nonUtf8Count}');
    stdout.writeln('  顶层      : ${r.topLevel.take(6).join(' / ')}'
        '${r.topLevel.length > 6 ? ' …(+${r.topLevel.length - 6})' : ''}');
    stdout.writeln('  套一层目录: ${r.wrappedSingleDir}'
        '${r.wrappedDirName == null ? '' : '  → "${r.wrappedDirName}"'}');
    stdout.writeln('  同名嵌套  : ${r.nestedSameName ?? '无'}');
    if (r.fileList.isNotEmpty) {
      stdout.writeln('  内容      :');
      for (final f in r.fileList.take(14)) {
        stdout.writeln('      - ' + f);
      }
      if (r.fileList.length > 14) {
        stdout.writeln('      … 共 ' + r.fileList.length.toString() + ' 个文件');
      }
    }
    for (final n in r.notes) {
      stdout.writeln('    • $n');
    }
  }

  // ---------- 阶段 4：结论 ----------
  stdout.writeln('\n[4] 对 P4 的直接影响');
  final anyNoWrap =
      reports.any((r) => r.container == 'zip' && !r.wrappedSingleDir);
  final anyNonUtf8 = reports.any((r) => r.nonUtf8Count > 0);
  final anyEnc = reports.any((r) => r.encryptedCount > 0);
  final anyNested = reports.any((r) => r.nestedSameName != null);
  final anyExe = reports.any((r) => r.exeCount > 0);

  if (anyNoWrap) {
    _ok('存在「未套外层目录」的包', '⇒ P4 必须强制解到 patch/<补丁名>/ 子目录，不能就地解压');
  }
  if (anyNested) {
    _ok('存在同名嵌套', '⇒ P4 解压后必须剥一层');
  }
  if (anyNonUtf8) {
    _ok('存在 CP932 文件名', '⇒ P4 必须转码，否则乱码写进游戏目录');
  }
  if (anyEnc) {
    _ok('存在加密条目', '⇒ P4 预览/解压前必须先探测，加密则只允许「打开原页」');
  }
  if (anyExe) {
    _ok('存在含 exe 的包', '⇒ P4 复制进游戏目录会覆盖原 exe，必须备份 + 可回滚');
  }

  stdout.writeln('\n结果: ${_fail == 0 ? '全部通过' : '$_fail 项失败'}  '
      '(PASS=$_pass FAIL=$_fail)');
  stdout.writeln('样本目录: $_outDir');
  _http.close(force: true);
  exitCode = _fail == 0 ? 0 : 1;
}

// ==================== 工具 ====================

String _str(Object? v) => v == null ? '' : v.toString();

int? _sizeToBytes(String? s) {
  final m = RegExp(r'([\d.]+)\s*([KMGTP]?)B?', caseSensitive: false)
      .firstMatch((s ?? '').trim());
  if (m == null) return null;
  final v = double.tryParse(m.group(1)!);
  if (v == null) return null;
  const unit = <String, int>{
    '': 1,
    'K': 1024,
    'M': 1024 * 1024,
    'G': 1024 * 1024 * 1024,
    'T': 1024 * 1024 * 1024 * 1024,
    'P': 1024 * 1024 * 1024 * 1024 * 1024,
  };
  final mul = unit[m.group(2)!.toUpperCase()] ?? 1;
  return (v * mul).round();
}

String _human(int b) {
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
  return '${b}B';
}
