// Phase 0 探测：GIF 元数据块级扫描器（临时工具，验证完成后移植进 lib 并删除本文件）
//
// 只按块结构跳跃，不解压像素数据，因此成本与文件体积近似线性，
// 且可在扫到 maxFrames 帧时提前终止。
import 'dart:typed_data';

class GifScanResult {
  const GifScanResult({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.totalDelayCs,
    required this.truncated,
    required this.ok,
    this.error,
  });

  final int width;
  final int height;
  final int frameCount;

  /// 累计帧延迟，单位 1/100 秒（GIF GCE 的 delay 字段单位）
  final int totalDelayCs;

  /// 是否因触达 maxFrames 上限而提前终止
  final bool truncated;
  final bool ok;
  final String? error;

  double get averageFps =>
      totalDelayCs <= 0 ? 0 : frameCount * 100 / totalDelayCs;

  @override
  String toString() =>
      'GifScan(${width}x$height, frames=$frameCount, '
      'delay=${totalDelayCs}cs, fps=${averageFps.toStringAsFixed(1)}, '
      'truncated=$truncated, ok=$ok${error == null ? '' : ', err=$error'})';
}

int _u16(Uint8List d, int i) => d[i] | (d[i + 1] << 8);

/// 跳过一串子块，p 指向第一个长度字节；返回终止符之后的位置。
int _skipSubBlocks(Uint8List d, int p) {
  while (p < d.length) {
    final n = d[p];
    if (n == 0) return p + 1;
    p += 1 + n;
  }
  return p;
}

GifScanResult scanGif(Uint8List d, {int maxFrames = 100000}) {
  final isGif = d.length >= 13 && d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46;
  if (!isGif) {
    return const GifScanResult(
      width: 0,
      height: 0,
      frameCount: 0,
      totalDelayCs: 0,
      truncated: false,
      ok: false,
      error: 'not a GIF',
    );
  }

  final width = _u16(d, 6);
  final height = _u16(d, 8);
  final packed = d[10];
  var pos = 13;
  if ((packed & 0x80) != 0) {
    pos += 3 * (1 << ((packed & 0x07) + 1)); // 跳过全局调色板
  }

  var frames = 0;
  var delayCs = 0;
  var truncated = false;

  while (pos < d.length) {
    final block = d[pos];
    if (block == 0x3B) break; // trailer

    if (block == 0x21) {
      // 扩展块：0x21 label blockSize data... 0x00
      if (pos + 2 >= d.length) break;
      final label = d[pos + 1];
      if (label == 0xF9 && pos + 6 < d.length) {
        delayCs += _u16(d, pos + 4); // Graphic Control Extension 的 delay
      }
      pos = _skipSubBlocks(d, pos + 2);
      continue;
    }

    if (block == 0x2C) {
      // 帧（图像描述符）：0x2C + 9 字节
      if (pos + 10 > d.length) break;
      frames++;
      if (frames >= maxFrames) {
        truncated = true;
        break;
      }
      final imgPacked = d[pos + 9];
      var p = pos + 10;
      if ((imgPacked & 0x80) != 0) {
        p += 3 * (1 << ((imgPacked & 0x07) + 1)); // 局部调色板
      }
      p += 1; // LZW min code size
      pos = _skipSubBlocks(d, p);
      continue;
    }

    break; // 未知块：结构已损坏
  }

  return GifScanResult(
    width: width,
    height: height,
    frameCount: frames,
    totalDelayCs: delayCs,
    truncated: truncated,
    ok: frames > 0,
    error: frames > 0 ? null : 'no frame block found',
  );
}
