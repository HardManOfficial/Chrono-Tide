// Phase 1 探针：验证 7z stdout 进度行的切分与解析规则
//
// 目的：在写 SevenZipProgressParser 之前，先实测 Dart LineSplitter 对
// 7z 真实输出（混用 \r\n 与 \r）的切分行为，以及新旧正则的命中率。
//
// 用法：
//   flutter/bin/cache/dart-sdk/bin/dart.exe --packages="D:/CTLIB/.dart_tool/package_config.json" \
//     dev_probe/phase1_progress_parser_probe.dart
//
// 数据源：dev_probe/phase0_out_*.txt（Phase 0 原样捕获的 7z stdout）
import 'dart:convert';
import 'dart:io';

/// 旧正则（extract_manager.dart:1304 现状）
final _oldRe = RegExp(r'^\s*(\d+)\s');

/// 新正则候选
final _newRe = RegExp(r'(\d{1,3})%');

int? _oldParse(String line) {
  final m = _oldRe.firstMatch(line.trimLeft());
  if (m == null) return null;
  final v = int.tryParse(m.group(1)!);
  if (v == null || v > 100) return null;
  return v;
}

int? _newParse(String line) {
  final m = _newRe.firstMatch(line);
  if (m == null) return null;
  final v = int.tryParse(m.group(1)!);
  if (v == null || v > 100) return null;
  return v;
}

/// 从 Phase 0 捕获文件里把内层 "STDOUT (repr)" 的原始字节还原出来。
/// 这些文件里的写法是 python 的 repr（b'...'），我们直接按字节扫 7z 段落。
/// 简化做法：不做完整 repr 解码，而是把整个文件当 utf8 读，
/// 用 `\r` 与 `\n` 真实字符切分——因为探针文件本身把 \r\n 写成了字面
/// 的 `\r\n` 两字符转义，所以我们先做一次转义还原。
String _unescapeRepr(String s) {
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && i + 1 < s.length) {
      final n = s[i + 1];
      if (n == 'r') {
        buf.write('\r');
        i++;
        continue;
      }
      if (n == 'n') {
        buf.write('\n');
        i++;
        continue;
      }
      if (n == 't') {
        buf.write('\t');
        i++;
        continue;
      }
      if (n == r'\') {
        buf.write(r'\');
        i++;
        continue;
      }
      if (n == "'") {
        buf.write("'");
        i++;
        continue;
      }
      if (n == 'x' && i + 3 < s.length) {
        final hex = s.substring(i + 2, i + 4);
        final v = int.tryParse(hex, radix: 16);
        if (v != null) {
          buf.writeCharCode(v);
          i += 3;
          continue;
        }
      }
    }
    buf.write(c);
  }
  return buf.toString();
}

void main() {
  print('=== 1) LineSplitter 对 7z 真实 stdout 的切分行为 ===');

  for (final f in [
    'dev_probe/phase0_out_v1_bsp1.txt',
    'dev_probe/phase0_out_x_bsp1.txt',
  ]) {
    final file = File(f);
    if (!file.existsSync()) {
      print('  [跳过] 不存在: $f');
      continue;
    }
    final raw = file.readAsStringSync();
    // 取 "===== STDOUT (repr) =====" 之后的内容并做转义还原
    final idx = raw.indexOf('===== STDOUT');
    final seg = idx >= 0 ? raw.substring(idx) : raw;
    final stdoutText = _unescapeRepr(seg);

    final lines = const LineSplitter().convert(stdoutText);
    final oldHits = lines.map(_oldParse).where((e) => e != null).length;
    final newHits = lines.map(_newParse).where((e) => e != null).length;

    print('  文件: $f');
    print('    LineSplitter 切出段数 = ${lines.length}');
    print('    旧正则 ^\\s*(\\d+)\\s   命中 = $oldHits');
    print('    新正则 (\\d{1,3})%     命中 = $newHits');
    print('    样例(前 3 个含 % 的段):');
    var shown = 0;
    for (final l in lines) {
      if (l.contains('%')) {
        print('      ${jsonEncode(l)}');
        shown++;
        if (shown >= 3) break;
      }
    }
  }

  print('');
  print('=== 2) 手工按 \\r 与 \\n 双切 的分段数对照 ===');
  for (final f in [
    'dev_probe/phase0_out_v1_bsp1.txt',
    'dev_probe/phase0_out_x_bsp1.txt',
  ]) {
    final file = File(f);
    if (!file.existsSync()) continue;
    final raw = file.readAsStringSync();
    final idx = raw.indexOf('===== STDOUT');
    final stdoutText = _unescapeRepr(idx >= 0 ? raw.substring(idx) : raw);
    // 把 \r\n 先折叠成 \n，再按 \n 与 \r 切
    final folded = stdoutText.replaceAll('\r\n', '\n');
    final byNl = folded.split('\n');
    final byCr = folded.split(RegExp(r'[\r\n]'));
    final newHitsCr =
        byCr.map(_newParse).where((e) => e != null).length;
    print('  文件: $f');
    print('    split(\'\\n\') 段数 = ${byNl.length}');
    print('    split([\\r\\n]) 段数 = ${byCr.length}  新正则命中 = $newHitsCr');
  }

  print('');
  print('=== 3) 单调性检查（新正则解析出的百分比序列）===');
  for (final f in [
    'dev_probe/phase0_out_v1_bsp1.txt',
    'dev_probe/phase0_out_x_bsp1.txt',
  ]) {
    final file = File(f);
    if (!file.existsSync()) continue;
    final raw = file.readAsStringSync();
    final idx = raw.indexOf('===== STDOUT');
    final stdoutText =
        _unescapeRepr(idx >= 0 ? raw.substring(idx) : raw).replaceAll('\r\n', '\n');
    final vals = stdoutText
        .split(RegExp(r'[\r\n]'))
        .map(_newParse)
        .whereType<int>()
        .toList();
    var monotonic = true;
    for (var i = 1; i < vals.length; i++) {
      if (vals[i] < vals[i - 1]) monotonic = false;
    }
    print('  文件: $f');
    print('    解析出 ${vals.length} 个百分比: ${vals.take(6).toList()} ... ${vals.skip(vals.length - 3).toList()}');
    print('    单调不减 = $monotonic');
  }
}
