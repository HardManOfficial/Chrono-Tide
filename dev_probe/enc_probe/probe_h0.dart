// RFC 9106 §5.3 Argon2id H0 中间值对照：
//   H0 = Blake2b-512([le32 p, le32 taglen, le32 m, le32 t, le32 version, le32 type,
//                     le32 pwdlen, pwd, le32 saltlen, salt, le32 secretlen, secret,
//                     le32 adlen, ad])
// RFC 期望 H0 = 28 89 de 48 7e b4 2a e5 ... a1 e9 97
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

void main() {
  final b = BytesBuilder();
  void le32(int v) {
    final u = Uint8List(4);
    u[0] = v & 0xff;
    u[1] = (v >> 8) & 0xff;
    u[2] = (v >> 16) & 0xff;
    u[3] = (v >> 24) & 0xff;
    b.add(u);
  }

  le32(4); // p (lanes)
  le32(32); // tag length
  le32(32); // m (KiB)
  le32(3); // t (passes)
  le32(19); // version 0x13
  le32(2); // type Argon2id
  le32(32);
  b.add(Uint8List.fromList(List.filled(32, 0x01))); // pwd
  le32(16);
  b.add(Uint8List.fromList(List.filled(16, 0x02))); // salt
  le32(8);
  b.add(Uint8List.fromList(List.filled(8, 0x03))); // secret
  le32(12);
  b.add(Uint8List.fromList(List.filled(12, 0x04))); // ad

  final blake = Blake2bDigest(digestSize: 64);
  final input = b.toBytes();
  blake.update(input, 0, input.length);
  final h0 = Uint8List(64);
  blake.doFinal(h0, 0);

  final got = h0.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
  print('H0 got : $got');
  print('H0 want: '
      '2889de487eb42ae500c0007ed9252f1069eadec40d5765b485de6dc2437a67b85'
      '46a2f0acc1a0882db8fcf74714b472e94df421a5da1112ffa11434370a1e997');
  print(got ==
          '2889de487eb42ae500c0007ed9252f1069eadec40d5765b485de6dc2437a67b85'
              '46a2f0acc1a0882db8fcf74714b472e94df421a5da1112ffa11434370a1e997'
      ? 'H0 MATCH'
      : 'H0 MISMATCH');
}
