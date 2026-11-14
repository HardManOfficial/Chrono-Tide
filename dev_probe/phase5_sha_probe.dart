// SHA-256 / HMAC-SHA256 纯 Dart 实现 —— NIST FIPS 180-4 + RFC 4231 官方测试向量。
// 验证对象：lib/services/cloud_backup/sha256_hmac.dart（源码复制级一致，
// 探针通过相对路径导入真实源文件，测的就是生产代码）。
//
// 云备份 SigV4 依赖 HMAC-SHA256；签名错 = 云端全 403，必须在探针层逐字节锁死。

import 'dart:io';
import 'dart:typed_data';

import '../lib/services/cloud_backup/sha256_hmac.dart';

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

void main() {
  // ---- SHA-256（FIPS 180-4 示例 + NIST 向量）----
  check('SHA256("")',
      sha256Hex('') == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  check('SHA256("abc")',
      sha256Hex('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  check('SHA256(448bit msg)',
      sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq') ==
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');

  // 长消息：一百万个 'a'（多 block 路径）—— 限制在少量 block 也能测多轮；
  // 为控制探针时长用 100 万字符（JIT 下 <1s）。
  final sb = StringBuffer();
  for (var i = 0; i < 1000000; i++) {
    sb.write('a');
  }
  check('SHA256(1e6 x a)',
      sha256Hex(sb.toString()) ==
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');

  // 非 ASCII 字节路径（0x00-0xff 全字节覆盖，双重 block）
  final allBytes = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    allBytes[i] = i;
  }
  check('SHA256(0x00-0xff)',
      bytesToHex(sha256Bytes(allBytes)) ==
          '40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880');

  // ---- HMAC-SHA256（RFC 4231 Test Case 1/2/6/7）----
  // TC1: key = 0x0b*20, data = "Hi There"
  final tc1 = hmacSha256(
      Uint8List.fromList(List.filled(20, 0x0b)), 'Hi There'.codeUnits);
  check('HMAC RFC4231 TC1',
      bytesToHex(tc1) ==
          'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');

  // TC2: key = "Jefe", data = "what do ya want for nothing?"
  final tc2 = hmacSha256(
      'Jefe'.codeUnits, 'what do ya want for nothing?'.codeUnits);
  check('HMAC RFC4231 TC2',
      bytesToHex(tc2) ==
          '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');

  // TC6: key 131 字节（> block size 64，触发先 hash 路径）
  final tc6Key = Uint8List.fromList(List.filled(131, 0xaa));
  final tc6 = hmacSha256(
      tc6Key, 'Test Using Larger Than Block-Size Key - Hash Key First'.codeUnits);
  check('HMAC RFC4231 TC6 (key>block)',
      bytesToHex(tc6) ==
          '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');

  // TC7: key 131 字节 + data 54 字节（组合路径）
  final tc7 = hmacSha256(
      tc6Key,
      'This is a test using a larger than block-size key and a larger than '
              'block-size data. The key needs to be hashed before being used by the HMAC algorithm.'
          .codeUnits);
  check('HMAC RFC4231 TC7',
      bytesToHex(tc7) ==
          '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2');

  stdout.writeln('RESULT: $pass PASS / $fail FAIL');
  if (fail > 0) exit(1);
}
