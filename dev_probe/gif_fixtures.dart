// Phase 0 探测用素材生成器（临时工具，验证完成后删除）
//
// 手写最小合法 GIF89a / PNG，不依赖任何第三方图像库。
import 'dart:io';
import 'dart:typed_data';

// ── GIF ────────────────────────────────────────────────────────────

/// LZW 码长恒定的「无压缩」编码：每 2 个像素发一次 CLEAR。
/// minCodeSize=2 → clear=4, end=5, firstAvailable=6, codeSize=3。
/// 组结构 [CLEAR, c1, c2]：c1 不增字典项，c2 使 firstAvailable 6→7 < 8，码长不涨。
Uint8List _lzwPixels(List<int> pixels) {
  const clear = 4, end = 5, codeSize = 3;
  final codes = <int>[];
  var i = 0;
  while (i < pixels.length) {
    codes.add(clear);
    codes.add(pixels[i]);
    i++;
    if (i < pixels.length) {
      codes.add(pixels[i]);
      i++;
    }
  }
  codes.add(clear);
  codes.add(end);

  // LSB-first 位打包
  final out = BytesBuilder();
  var acc = 0, accBits = 0;
  for (final c in codes) {
    acc |= c << accBits;
    accBits += codeSize;
    while (accBits >= 8) {
      out.addByte(acc & 0xFF);
      acc >>= 8;
      accBits -= 8;
    }
  }
  if (accBits > 0) out.addByte(acc & 0xFF);
  return out.toBytes();
}

void _u16(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

/// 生成多帧 GIF。
///
/// [frameDelaysCs] 每帧延迟，单位 1/100 秒。
/// [loopCount] 0 = 无限循环（写 Netscape 扩展）；>0 = 指定循环次数；负数 = 不写扩展。
Uint8List buildGif({
  required int width,
  required int height,
  required List<int> frameDelaysCs,
  int loopCount = 0,
  bool colorPerFrame = true,
}) {
  final b = BytesBuilder();
  b.add('GIF89a'.codeUnits);
  _u16(b, width);
  _u16(b, height);
  b.addByte(0xF0); // GCT flag=1, colorRes=7, sort=0, GCT size=2
  b.addByte(0);
  b.addByte(0);
  b.add([0x00, 0x00, 0x00]); // index 0 = black
  b.add([0xFF, 0xFF, 0xFF]); // index 1 = white

  if (loopCount >= 0) {
    b.add([0x21, 0xFF, 0x0B]);
    b.add('NETSCAPE2.0'.codeUnits);
    b.addByte(0x03);
    b.addByte(0x01);
    _u16(b, loopCount);
    b.addByte(0x00);
  }

  for (var f = 0; f < frameDelaysCs.length; f++) {
    final color = colorPerFrame ? (f % 2) : 0;
    b.add([0x21, 0xF9, 0x04]);
    b.addByte(0x08); // disposal=2
    _u16(b, frameDelaysCs[f]);
    b.addByte(0);
    b.addByte(0);
    b.addByte(0x2C);
    _u16(b, 0);
    _u16(b, 0);
    _u16(b, width);
    _u16(b, height);
    b.addByte(0x00);
    b.addByte(0x02); // LZW min code size
    final data = _lzwPixels(List<int>.filled(width * height, color));
    for (var off = 0; off < data.length; off += 255) {
      final n = (data.length - off) < 255 ? data.length - off : 255;
      b.addByte(n);
      b.add(Uint8List.sublistView(data, off, off + n));
    }
    b.addByte(0x00);
  }

  b.addByte(0x3B);
  return b.toBytes();
}

// ── PNG ────────────────────────────────────────────────────────────

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

List<int> _pngChunk(String type, List<int> data) {
  final crc = _crc32(<int>[...type.codeUnits, ...data]);
  return <int>[
    (data.length >> 24) & 0xFF,
    (data.length >> 16) & 0xFF,
    (data.length >> 8) & 0xFF,
    data.length & 0xFF,
    ...type.codeUnits,
    ...data,
    (crc >> 24) & 0xFF,
    (crc >> 16) & 0xFF,
    (crc >> 8) & 0xFF,
    crc & 0xFF,
  ];
}

/// 生成宽 [width] 高 [height] 的 8bit 灰度 PNG（纯色），用于静态图对照。
Uint8List buildPng({required int width, required int height, int gray = 0}) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: none
    raw.add(Uint8List(width)..fillRange(0, width, gray));
  }
  final idat = ZLibCodec().encode(raw.toBytes());
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._pngChunk('IHDR', <int>[
      (width >> 24) & 0xFF, (width >> 16) & 0xFF,
      (width >> 8) & 0xFF, width & 0xFF,
      (height >> 24) & 0xFF, (height >> 16) & 0xFF,
      (height >> 8) & 0xFF, height & 0xFF,
      8, 0, 0, 0, // bitDepth=8, colorType=0(grayscale), compression/filter/interlace=0
    ]),
    ..._pngChunk('IDAT', idat),
    ..._pngChunk('IEND', <int>[]),
  ]);
}

/// 把 PNG 的 IHDR 尺寸读出来（不做完整解码），用于自检素材本身正确。
List<int> readPngSize(Uint8List d) => <int>[
      (d[16] << 24) | (d[17] << 16) | (d[18] << 8) | d[19],
      (d[20] << 24) | (d[21] << 16) | (d[22] << 8) | d[23],
    ];
