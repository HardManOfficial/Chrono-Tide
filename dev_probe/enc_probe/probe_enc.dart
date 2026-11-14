// .enc 解密器 Phase 0b 探针：
//   1. Skein-1024/512 空消息官方向量（验证 Threefish-1024 + UBI + 配置块 + 输出变换）
//   2. Argon2id RFC 9106 §5.3 测试向量（验证 pointycastle Argon2 用法）
//   3. HKDF（Skein/SHA3-512 两路）确定性 + 输出长度
//   4. .enc 往返自洽：手工加密 mini 样本 → EncDecryptor.decrypt → 数据一致
//
// 跑法（231 管道故障期间，dart.exe 直跑）：
//   ./flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages=D:/CTLIB/.dart_tool/package_config.json dev_probe/enc_probe/probe_enc.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chrono_tide/services/enc/enc_decryptor.dart';
import 'package:chrono_tide/services/enc/skein_threefish.dart';
import 'package:pointycastle/export.dart' hide Argon2BytesGenerator;
import 'package:pointycastle/key_derivators/argon2_native_int_impl.dart'
    as ni;
import 'package:pointycastle/key_derivators/argon2_register64_impl.dart'
    as r64;

var _pass = 0;
var _fail = 0;

void check(String name, bool ok, {String detail = ''}) {
  if (ok) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name  $detail');
  }
}

String hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexDecode(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() async {
  print('=== 1. Skein-1024 官方 KAT（BC SkeinDigestTest / Skein 1.3 NIST CD） ===');
  // 向量 1：Skein-1024/1024，空消息。
  final skeinA = Skein1024Digest(outputSizeBytes: 128);
  final outA = Uint8List(128);
  skeinA.doFinal(outA, 0);
  const expectA =
      '0fff9563bb3279289227ac77d319b6fff8d7e9f09da1247b72a0a265cd6d2a62'
      '645ad547ed8193db48cff847c06494a03f55666d3b47eb4c20456c9373c86297'
      'd630d5578ebd34cb40991578f9f52b18003efa35d3da6553ff35db91b81ab890'
      'bec1b189b7f52cb2a783ebb7d823d725b0b4a71f6824e88f68f982eefc6d19c6';
  check('Skein-1024/1024 empty', hex(outA) == expectA,
      detail: 'got ${hex(outA)}');

  // 向量 2：M128 公共消息，Skein-1024/1024。
  const m128Hex =
      'fbd17c26b61a82e12e125f0d459b96c91ab4837dff22b39b78439430cdfc5dc8'
      '78bb393a1a5f79bef30995a85a12923339ba8ab7d8fc6dc5fec6f4ed22c122bb'
      'e7eb61981892966de5cef576f71fc7a80d14dab2d0c03940b95b9fb3a727c66a'
      '6e1ff0dc311b9aa21a3054484802154c1826c2a27a0914152aeb76f1168d4410';
  final m128 = _hexDecode(m128Hex);

  final skeinB = Skein1024Digest(outputSizeBytes: 128)
    ..update(m128, 0, m128.length);
  final outB = Uint8List(128);
  skeinB.doFinal(outB, 0);
  const expectB =
      '96ca81f586c825d0360aef5acaec49ad55289e1797072eee198b64f349ce65b6'
      'e6ed804fe38f05135fe769cc56240ddda5098f620865ce4a4278c77fa2ec6bc3'
      '1c0f354ca78c7ca81665bfcc5dc54258c3b8310ed421d9157f36c093814d9b25'
      '103d83e0ddd89c52d0050e13a64c6140e6388431961685734b1f138fe2243086';
  check('Skein-1024/1024 M128', hex(outB) == expectB,
      detail: 'got ${hex(outB)}');

  // 向量 3：M128 消息，Skein-1024/512。
  final skeinC = Skein1024Digest(outputSizeBytes: 64)
    ..update(m128, 0, m128.length);
  final outC = Uint8List(64);
  skeinC.doFinal(outC, 0);
  const expectC =
      '5d0416f49c2d08dfd40a1446169dc6a1d516e23b8b853be4933513051de8d5c2'
      '6baccffb08d3b16516ba3c6ccf3e9a6c78fff6ef955f2dbc56e1459a7cdba9a5';
  check('Skein-1024/512 M128', hex(outC) == expectC,
      detail: 'got ${hex(outC)}');

  print('=== 2. Argon2id RFC 9106 §5.3 测试向量（双实现对照） ===');
  // p=4, T=32, m=32, t=3; pwd=32×01, salt=16×02, secret=8×03, ad=12×04。
  // 注意：0d640df5... 是 Argon2id 的 tag（c814d9d1... 是 §5.2 Argon2i 的，勿混）。
  const expectArgon =
      '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659';

  Uint8List argonRun({required bool nativeInt}) {
    final KeyDerivator gen = nativeInt
        ? ni.Argon2BytesGenerator()
        : r64.Argon2BytesGenerator();
    gen.init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      Uint8List.fromList(List.filled(16, 0x02)),
      desiredKeyLength: 32,
      iterations: 3,
      memory: 32,
      lanes: 4,
      version: Argon2Parameters.ARGON2_VERSION_13,
      secret: Uint8List.fromList(List.filled(8, 0x03)),
      additional: Uint8List.fromList(List.filled(12, 0x04)),
    ));
    final aout = Uint8List(32);
    gen.deriveKey(Uint8List.fromList(List.filled(32, 0x01)), 0, aout, 0);
    return aout;
  }

  final aNat = argonRun(nativeInt: true);
  final aReg = argonRun(nativeInt: false);
  check('Argon2id native_int impl', hex(aNat) == expectArgon,
      detail: 'got ${hex(aNat)}');
  check('Argon2id register64 impl', hex(aReg) == expectArgon,
      detail: 'got ${hex(aReg)}');

  print('=== 3. KDF 链确定性 ===');
  // _deriveKeys 是私有，直接复用 decrypt 内部路径不便；这里验证
  // HKDF-Skein 输出 256B 确定性（两次调用一致）。
  // 通过公开行为验证：往返自洽已覆盖 KDF；此处仅验证 Skein 大输出确定性。
  final s1 = Skein1024Digest(outputSizeBytes: 128)
    ..update(utf8.encode('chrono'), 0, 6);
  final o1 = Uint8List(128);
  s1.doFinal(o1, 0);
  final s2 = Skein1024Digest(outputSizeBytes: 128)
    ..update(utf8.encode('chrono'), 0, 6);
  final o2 = Uint8List(128);
  s2.doFinal(o2, 0);
  check('Skein deterministic', hex(o1) == hex(o2));
  // HMac 实际复用语义：doFinal → reset → 重新 update 相同消息 → 输出必须一致。
  // （BC 语义：reset 不清消息缓冲残留，与 BC 对齐；空 doFinal 不属于使用场景。）
  check('Skein reset-reuse', () {
    final o3 = Uint8List(128);
    s1.update(utf8.encode('chrono'), 0, 6);
    s1.doFinal(o3, 0);
    return hex(o3) == hex(o1);
  }());

  print('=== 4. .enc 往返自洽（Dart 加密 mini 样本 → decrypt） ===');
  await _roundTrip();

  print('=== 结果: $_pass pass / $_fail fail ===');
  exit(_fail > 0 ? 1 : 0);
}

/// 用与解密器相同的 KDF/CTR 组装一个 mini .enc，再走 EncDecryptor.decrypt 验证。
/// KDF 部分通过公开 decrypt 无法直接调用私有 _deriveKeys → 在探针里重写一份
/// （仅测试用），CTR 逻辑照解密器对称实现。
Future<void> _roundTrip() async {
  const password = 'SS_PASSWORD_01';
  final salt = Uint8List.fromList(
      List.generate(32, (i) => (i * 7 + 3) & 0xff));
  const customParamsByte = 0x11; // t=20, m=20480

  // --- 与解密器一致的内联 KDF（探针局部复制） ---
  final pwb = utf8.encode(EncDecryptorWrapper.toCodePoints(password));
  final l0 = EncDecryptorWrapper.hkdfSkein(pwb);
  final argon = ni.Argon2BytesGenerator()
    ..init(Argon2Parameters(
      Argon2Parameters.ARGON2_id,
      salt,
      desiredKeyLength: 256,
      iterations: 10 * (1 << (customParamsByte & 0x0f)),
      memory: 10240 * (1 << ((customParamsByte >> 4) & 0x0f)),
      lanes: 4,
      version: Argon2Parameters.ARGON2_VERSION_13,
    ));
  final argonOutput = Uint8List(256);
  argon.deriveKey(l0, 0, argonOutput, 0);
  final encKey = EncDecryptorWrapper.hkdfSha3(
      argonOutput, 'encKeySalt', 'encKeyInfo', 32);
  final nonce =
      EncDecryptorWrapper.hkdfSha3(argonOutput, 'nonceSalt', 'nonceInfo', 16);

  // --- 组装 .enc ---
  const checkCode = 'abc123def456ghij789klmnop0123456'; // 32 chars a-z0-9
  assert(checkCode.length == 32);
  final payload = Uint8List.fromList(
      List.generate(100000, (i) => (i * 31 + 11) & 0xff));
  final mac = Uint8List(32);

  final head = BytesBuilder();
  head.add(utf8.encode('SSEFE'));
  head.addByte(4);
  head.addByte(0); // AES-256
  head.addByte(customParamsByte);
  head.add(salt);
  head.add(_ctr(encKey, nonce, utf8.encode(checkCode)));
  // payload 段 CTR 续接：checkcode 32B 已消耗 keystream block 0-1。
  head.add(_ctr(encKey, nonce, payload, blockOffset: 2));
  head.add(mac);

  final encFile = File('D:/CTLIB/.workbuddy/enc_probe_rt.enc');
  encFile.writeAsBytesSync(head.toBytes());

  // --- 解密 ---
  final outZip = 'D:/CTLIB/.workbuddy/enc_probe_rt.zip';
  final sw = Stopwatch()..start();
  try {
    await EncDecryptor.decrypt(
        encPath: encFile.path, outputZipPath: outZip, password: password);
    sw.stop();
    final got = File(outZip).readAsBytesSync();
    check('roundtrip payload', hex(got) == hex(payload),
        detail: 'len ${got.length} vs ${payload.length}');
    print('      (decrypt time incl. Argon2id t=20/m=20480: '
        '${sw.elapsedMilliseconds} ms)');
  } catch (e) {
    sw.stop();
    check('roundtrip payload', false, detail: 'exception: $e');
  } finally {
    if (encFile.existsSync()) encFile.deleteSync();
    final z = File(outZip);
    if (z.existsSync()) z.deleteSync();
  }
}

/// 探针局部 CTR 加密（与解密器对称）。[blockOffset] 续接前段已消耗的块数。
Uint8List _ctr(Uint8List key, Uint8List nonce, Uint8List data,
    {int blockOffset = 0}) {
  final aes = AESEngine()..init(true, KeyParameter(key));
  final counter = Uint8List.fromList(nonce);
  // 先推进 blockOffset 个块。
  for (var k = 0; k < blockOffset; k++) {
    for (var i = counter.length - 1; i >= 0; i--) {
      final v = (counter[i] + 1) & 0xff;
      counter[i] = v;
      if (v != 0) break;
    }
  }
  final ks = Uint8List(16);
  final out = Uint8List(data.length);
  var off = 0;
  while (off < data.length) {
    aes.processBlock(counter, 0, ks, 0);
    final n = (data.length - off) < 16 ? (data.length - off) : 16;
    for (var i = 0; i < n; i++) {
      out[off + i] = data[off + i] ^ ks[i];
    }
    off += n;
    for (var i = counter.length - 1; i >= 0; i--) {
      final v = (counter[i] + 1) & 0xff;
      counter[i] = v;
      if (v != 0) break;
    }
  }
  return out;
}

/// 探针专用桥：复用解密器的私有 KDF 逻辑（避免双份实现漂移）。
class EncDecryptorWrapper {
  static String toCodePoints(String s) => EncDecryptor.debugToCodePoints(s);

  static Uint8List hkdfSkein(Uint8List ikm) =>
      EncDecryptor.debugHkdfSkein(ikm);

  static Uint8List hkdfSha3(
          Uint8List ikm, String salt, String info, int len) =>
      EncDecryptor.debugHkdfSha3(ikm, salt, info, len);
}
