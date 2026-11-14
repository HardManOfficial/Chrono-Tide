// P3 下载纯逻辑离线探针（纯 Dart，不需要 flutter_tester）。
//
// 跑法：
//   dart dev_probe/patch_download_probe.dart
//
// 覆盖：
//   1. 文件名清洗（Windows 非法字符 / 超长 / 空标题 / 扩展名回退）
//   2. 字节格式化（B/KB/MB/GB 边界 + 进度形式）
//   3. 流式 sha256（多分块 + 空文件 + 与已知向量比对）
import 'dart:convert';
import 'dart:io';

import 'package:chrono_tide/models/patch_resource.dart';
import 'package:chrono_tide/services/patch/patch_download_core.dart';

int _fail = 0;
void _eq(String name, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (!ok) _fail++;
  print('${ok ? "PASS" : "FAIL"} | $name'
      '${ok ? "" : " | 实际=<$actual> 期望=<$expected>"}');
}

void _ok(String name, bool cond, [String? detail]) {
  if (!cond) _fail++;
  print('${cond ? "PASS" : "FAIL"} | $name${detail == null ? "" : " | $detail"}');
}

PatchResource _res({
  String title = '千恋＊万花 汉化补丁',
  PatchSite site = PatchSite.kunlun,
  String id = '7117',
}) =>
    PatchResource(
      key: '${site.tag}:$id',
      site: site,
      id: id,
      groupId: 'g1',
      title: title,
      gameTitle: '千恋＊万花',
      kinds: const [PatchKind.translation],
      rawKinds: const ['汉化'],
      languages: const [],
      platforms: const [],
      sizeBytes: 1234,
      sha256: '',
      note: '',
      webUrl: '',
      delivery: PatchDelivery.direct,
      directUrl: 'https://dl.imoe.uk/moyu/x.zip',
    );

void main() async {
  print('--- 1. 文件名清洗 ---');

  _eq(
    '常规：站点前缀 + id',
    patchFileName(_res(), 'https://dl.imoe.uk/moyu/abc.zip'),
    'moyu_7117_千恋＊万花 汉化补丁.zip',
  );

  _eq(
    'Windows 非法字符全替换',
    patchFileName(
      _res(title: r'a\b/c:d*e?f"g<h>i|j'),
      'https://x/y.7z',
    ),
    'moyu_7117_a_b_c_d_e_f_g_h_i_j.7z',
  );

  _eq(
    '换行/制表折叠为下划线',
    patchFileName(_res(title: 'a\nb\tc'), 'https://x/y.zip'),
    'moyu_7117_a_b_c.zip',
  );

  _eq(
    '连续空白折叠为单空格',
    patchFileName(_res(title: 'a    b'), 'https://x/y.zip'),
    'moyu_7117_a b.zip',
  );

  final longTitle = '统' * 120;
  final longName = patchFileName(_res(title: longTitle), 'https://x/y.zip');
  // 前缀 `moyu_7117_` = 10 字符，主干截到 60，扩展名 4
  _eq('超长标题截断到 60 字', longName.length, 10 + 60 + 4);

  _eq(
    '空标题退回 patch',
    patchFileName(_res(title: '   '), 'https://x/y.zip'),
    'moyu_7117_patch.zip',
  );

  _eq(
    '无扩展名退回 .zip',
    patchFileName(_res(), 'https://dl.imoe.uk/moyu/abc'),
    'moyu_7117_千恋＊万花 汉化补丁.zip',
  );

  _eq(
    '扩展名过长（>.6）退回 .zip',
    patchFileName(_res(), 'https://x/y.verylongext'),
    'moyu_7117_千恋＊万花 汉化补丁.zip',
  );

  _eq(
    '2DFan 站点标记',
    patchFileName(_res(site: PatchSite.twoDfan, id: '3100'), 'https://x/y.zip'),
    '2dfan_3100_千恋＊万花 汉化补丁.zip',
  );

  print('--- 2. 字节格式化 ---');

  _eq('0 B', formatPatchBytes(0), '0 B');
  _eq('1023 B', formatPatchBytes(1023), '1023 B');
  _eq('1024 B → 1 KB', formatPatchBytes(1024), '1 KB');
  _eq('1536 B → 2 KB（四舍五入）', formatPatchBytes(1536), '2 KB');
  _eq('1 MB', formatPatchBytes(1024 * 1024), '1.0 MB');
  _eq('1.5 GB', formatPatchBytes((1.5 * 1024 * 1024 * 1024).round()), '1.50 GB');
  _eq(
    '进度形式',
    formatPatchBytes(512 * 1024 * 1024, 1024 * 1024 * 1024),
    '512.0 MB / 1.00 GB',
  );
  _eq('total=0 不带进度后缀', formatPatchBytes(2048, 0), '2 KB');

  print('--- 3. 流式 sha256 ---');

  final tmp = Directory.systemTemp.createTempSync('ct_patch_sha_');
  try {
    // 空文件 —— SHA256("") 的已知值
    final empty = File('${tmp.path}/empty.bin');
    empty.writeAsBytesSync(const <int>[]);
    _eq(
      '空文件',
      await sha256OfFile(empty.path),
      'e3b0c44298fc1c149afbf4c8996fb924'
          '27ae41e4649b934ca495991b7852b855',
    );

    // "abc" 的已知值
    final abc = File('${tmp.path}/abc.bin');
    abc.writeAsBytesSync(utf8.encode('abc'));
    _eq(
      '"abc"',
      await sha256OfFile(abc.path),
      'ba7816bf8f01cfea414140de5dae2223'
          'b00361a396177a9cb410ff61f20015ad',
    );

    // 3 MB 随机数据：验证多分块累积与原值一致（流式最容易在分块边界出错）
    final big = File('${tmp.path}/big.bin');
    final bytes = List<int>.generate(3 * 1024 * 1024, (i) => (i * 31 + 7) & 0xFF);
    big.writeAsBytesSync(bytes);
    final got = await sha256OfFile(big.path);
    _ok('3MB 结果长度 64', got.length == 64, 'len=${got.length}');
    _ok('3MB 结果全小写十六进制',
        RegExp(r'^[0-9a-f]{64}$').hasMatch(got), got);
    // 同一文件算两次必须一致（排除分块状态残留）
    _eq('3MB 两次结果一致', await sha256OfFile(big.path), got);
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  print('');
  print(_fail == 0 ? '结果: 全部通过' : '结果: $_fail 项失败');
  exit(_fail == 0 ? 0 : 1);
}
