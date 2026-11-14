// DPAPI 探针：CryptProtectData/CryptUnprotectData 往返实测（纯 Dart）
// 运行：flutter/bin/cache/dart-sdk/bin/dart.exe dev_probe/phase5_dpapi_probe.dart
import 'dart:convert';

import '../lib/services/cloud_backup/dpapi_helper.dart';

void main() {
  var pass = 0, fail = 0;
  void check(String name, bool cond) {
    if (cond) {
      pass++;
      print('PASS  $name');
    } else {
      fail++;
      print('FAIL  $name');
    }
  }

  // 1. 往返：ASCII + 中文 + 特殊字符
  const secret = 'webdav-pass-中文!@#¥';
  final cipher = DpapiHelper.protect(utf8.encode(secret));
  check('密文非空且 != 明文', cipher.isNotEmpty && !utf8.encode(secret)
      .toString()
      .contains(cipher.toString()));
  final round = utf8.decode(DpapiHelper.unprotect(cipher));
  check('往返一致: $round', round == secret);

  // 2. 同明文两次加密密文不同（DPAPI 随机会话密钥）
  final cipher2 = DpapiHelper.protect(utf8.encode(secret));
  check('两次密文不同（随机密钥）', !cipher.toString().contains(cipher2.toString()) &&
      cipher.length != 0);

  // 3. base64 便捷封装
  final b64 = DpapiHelper.protectToBase64(secret);
  check('base64 往返', DpapiHelper.unprotectFromBase64(b64) == secret);

  // 4. 篡改密文必须失败（不能静默返回垃圾）
  final tampered = List<int>.from(cipher);
  tampered[cipher.length ~/ 2] ^= 0xFF;
  var threw = false;
  try {
    DpapiHelper.unprotect(tampered);
  } catch (_) {
    threw = true;
  }
  check('篡改密文解密抛异常', threw);

  print('\nRESULT: $pass PASS / $fail FAIL');
  if (fail > 0) throw StateError('probe failed');
}
