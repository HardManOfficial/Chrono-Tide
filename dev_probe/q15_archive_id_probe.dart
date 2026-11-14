// Q15 探针：归档 id 命名 —— 从 game_archive_service.dart 源码提取真实实现装配执行
import 'dart:io';

class Q15Probe {
  static String newArchiveId(DateTime now, String state, {String? title}) {
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
    final clean = sanitizeTitleForId(title);
    return clean.isEmpty ? '${ts}_$state' : '${clean}_${ts}_$state';
  }
  static String sanitizeTitleForId(String? title) {
    if (title == null) return '';
    var t = title
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (t.length > 40) t = t.substring(0, 40);
    // Windows 目录名不允许以点/空格结尾
    t = t.replaceAll(RegExp(r'[. ]+$'), '');
    return t;
  }
}

void main() {
  var pass = 0, fail = 0;
  void check(String name, bool cond) {
    if (cond) { pass++; print('PASS  ' + name); } else { fail++; print('FAIL  ' + name); }
  }
  final t = DateTime(2026, 10, 3, 12, 30, 45);

  final id1 = Q15Probe.newArchiveId(t, 'sealed', title: '美少女万華鏡');
  check('常规命名: ' + id1, id1 == '美少女万華鏡_2026-10-03_12-30-45_sealed');

  final id2 = Q15Probe.newArchiveId(t, 'packed', title: r'Game: A/B <C> "D" *E?');
  check('非法字符清洗: ' + id2, !id2.contains(RegExp(r'[\/:*?"<>|]')));

  final longTitle = '很长的游戏标题' * 10;
  final id3 = Q15Probe.newArchiveId(t, 'sealed', title: longTitle);
  final namePart3 = id3.split('_2026')[0];
  check('截断40: len=' + namePart3.length.toString(), namePart3.length <= 40);

  final id4 = Q15Probe.newArchiveId(t, 'sealed', title: '   ');
  check('空标题回退旧格式: ' + id4, id4 == '2026-10-03_12-30-45_sealed');

  final id5 = Q15Probe.newArchiveId(t, 'sealed', title: null);
  check('null回退旧格式: ' + id5, id5 == '2026-10-03_12-30-45_sealed');

  final id6 = Q15Probe.newArchiveId(t, 'sealed', title: 'Clannad. ');
  check('末尾点空格剔除: ' + id6, id6.startsWith('Clannad_'));

  stdout.writeln('RESULT: ' + pass.toString() + ' PASS / ' + fail.toString() + ' FAIL');
  if (fail > 0) exit(1);
}
