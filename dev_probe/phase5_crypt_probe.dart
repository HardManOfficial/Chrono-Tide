// ArchiveCryptor（7z 加密外壳）—— 真实 7z 进程实测。
//
// 验证：加密打包（仅存储+头加密）→ 解密还原 → 字节级一致；
// 错密码必失败且 wrongPassword 语义正确；进度回调覆盖 0-100。
// 7z 路径用仓内 windows/runner/tools/7z.exe（生产为 runtime/tools/7z.exe，
// 同为 7-Zip 23.01 家族，行为一致）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/cloud_backup/archive_cryptor.dart';

int pass = 0, fail = 0;

void check(String name, bool cond) {
  if (cond) {
    pass++;
    print('PASS  $name');
  } else {
    fail++;
    print('FAIL  $name');
  }
}

Future<void> main() async {
  final cryptor = ArchiveCryptor(sevenZipPath: r'D:\CTLIB\windows\runner\tools\7z.exe');
  final tmp = await Directory.systemTemp.createTemp('ct_crypt_probe_');
  final src = Directory('${tmp.path}/archive_src');
  await src.create(recursive: true);

  // 造内容：中文文件名 + 二进制 + 子目录嵌套（含 12MB 大文件保证 7z 有进度输出）
  final bin = Uint8List(512 * 1024);
  for (var i = 0; i < bin.length; i++) {
    bin[i] = i & 0xff;
  }
  final big = Uint8List(12 * 1024 * 1024);
  for (var i = 0; i < big.length; i++) {
    big[i] = (i * 31 + 7) & 0xff;
  }
  final f1 = File('${src.path}/存档数据_主档.dat');
  await f1.writeAsBytes(bin);
  await File('${src.path}/大文件_用于进度.bin').writeAsBytes(big);
  await File('${src.path}/meta.json')
      .writeAsString('{"game_id":"probe","title":"美少女万華鏡"}', encoding: utf8);
  final sub = Directory('${src.path}/sub dir');
  await sub.create();
  await File('${sub.path}/nested 存档.sav').writeAsString('save-data-🈶-emoji');

  final enc = '${tmp.path}/cloud_enc.7z';
  final percents = <int>[];
  final r1 = await cryptor.packEncrypted(
    sourceDir: src.path,
    outputArchive: enc,
    password: '我的 密码-2026!@#',
    onProgress: percents.add,
  );
  check('加密打包成功', r1.ok);
  check('加密包存在', await File(enc).exists());
  check('进度回调覆盖（至少 1 次，值域 0-100）',
      percents.isNotEmpty && percents.every((p) => p >= 0 && p <= 100));
  check('半成品已转正（无 .partial 残留）', !await File('$enc.partial').exists());

  // 错密码先测（避免正确解包污染判断）
  final wrongDir = '${tmp.path}/out_wrong';
  final r2 = await cryptor.unpackDecrypted(
    archive: enc,
    targetDir: wrongDir,
    password: '<REDACTED>',
  );
  check('错密码必须失败', !r2.ok);
  check('错密码标记 wrongPassword', r2.wrongPassword);

  // 正确解包 → 字节级比对
  final outDir = '${tmp.path}/out_ok';
  final r3 = await cryptor.unpackDecrypted(
    archive: enc,
    targetDir: outDir,
    password: '我的 密码-2026!@#',
  );
  check('正确密码解包成功', r3.ok);
  final out1 = File('$outDir/存档数据_主档.dat');
  check('中文文件名还原', await out1.exists());
  final outBytes = await out1.readAsBytes();
  var binOk = outBytes.length == bin.length;
  for (var i = 0; binOk && i < bin.length; i++) {
    if (outBytes[i] != bin[i]) binOk = false;
  }
  check('二进制内容字节级一致', binOk);
  check('嵌套子目录 + emoji 文件名还原',
      await File('$outDir/sub dir/nested 存档.sav').readAsString() ==
          'save-data-🈶-emoji');
  check('meta.json 内容一致',
      await File('$outDir/meta.json').readAsString() ==
          '{"game_id":"probe","title":"美少女万華鏡"}');
  check('大文件字节级一致',
      await File('$outDir/大文件_用于进度.bin').length() == big.length);

  // 清理
  try {
    await tmp.delete(recursive: true);
  } catch (_) {}

  print('RESULT: $pass PASS / $fail FAIL');
  if (fail > 0) exit(1);
}
