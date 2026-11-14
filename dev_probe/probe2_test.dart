// Phase 0 第二轮：走「Image widget 生产路径」的探针（第一轮 provider 路径未回调，
// 测到的是空白图）。每个探针都先断言图像确实加载，否则标记 invalid。
//
// 运行：env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
//         ./flutter/bin/flutter.bat test dev_probe/probe2_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gif_fixtures.dart';
import 'gif_scan.dart';

final Map<String, dynamic> R = {};

late Directory probeDir;
late File gifSmall; // 200x150, 6 帧
late File gifMid; // 500x500, 20 帧
late File pngStatic; // 800x600 静态对照

void _save() {
  final json = const JsonEncoder.withIndent('  ').convert(R);
  stdout.writeln('\n@@@JSON@@@$json@@@END@@@');
  try {
    File('dev_probe${Platform.pathSeparator}results2.json')
        .writeAsStringSync(json);
  } catch (e) {
    stdout.writeln('[probe2] 落盘失败(忽略): $e');
  }
}

/// 用 Image widget 加载（= 生产路径），推进若干帧后返回首个 ImageInfo
Future<ImageInfo?> pumpImage(
  WidgetTester tester,
  ImageProvider provider, {
  double w = 400,
  double h = 300,
  int ms = 800,
  int stepMs = 100,
}) async {
  ImageInfo? got;
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: w,
        height: h,
        child: Image(image: provider, fit: BoxFit.cover),
      ),
    ),
  ));
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener l;
  l = ImageStreamListener((info, sync) {
    got ??= info;
  });
  stream.addListener(l);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
  for (var t = 0; t < ms; t += stepMs) {
    await tester.pump(Duration(milliseconds: stepMs));
  }
  stream.removeListener(l);
  return got;
}

String? sizeOf(ImageInfo? i) =>
    i == null ? null : '${i.image.width}x${i.image.height}';

int? widthOf(ImageInfo? i) => i?.image.width;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    probeDir = Directory.systemTemp.createTempSync('ct_bgprobe2_');
    String p(String n) => '${probeDir.path}${Platform.pathSeparator}$n';
    gifSmall = File(p('small.gif'))
      ..writeAsBytesSync(buildGif(
        width: 200,
        height: 150,
        frameDelaysCs: List<int>.filled(6, 10),
      ));
    gifMid = File(p('mid.gif'))
      ..writeAsBytesSync(buildGif(
        width: 500,
        height: 500,
        frameDelaysCs: List<int>.filled(20, 10),
      ));
    pngStatic = File(p('static.png'))
      ..writeAsBytesSync(buildPng(width: 800, height: 600, gray: 0x80));
  });

  tearDownAll(_save);
  tearDown(_save);

  // ── 素材自检：PNG 尺寸可读 ───────────────────────────────────────
  test('V0 素材自检', () async {
    final png = pngStatic.readAsBytesSync();
    final sz = readPngSize(png);
    R['V0'] = {
      'png 自读尺寸': '$sz',
      'gifSmall 文件大小': gifSmall.lengthSync(),
    };
  });

  // ── V7c：扫描器 vs 引擎 frameCount 交叉验证（含真实世界 GIF）────────
  test('V7c 扫描器正确性交叉验证', () async {
    final out = <String, dynamic>{};
    final candidates = <String, File>{
      'fixture small': gifSmall,
      'fixture mid': gifMid,
      '真实 demo-cli.gif': File('ludusavi-master/docs/demo-cli.gif'),
      '真实 demo-gui.gif': File('ludusavi-master/docs/demo-gui.gif'),
    };
    for (final e in candidates.entries) {
      try {
        if (!e.value.existsSync()) {
          out[e.key] = {'跳过': '文件不存在 ${e.value.path}'};
          continue;
        }
        final bytes = await e.value.readAsBytes();
        final scan = scanGif(bytes);
        final codec = await ui.instantiateImageCodec(bytes);
        out[e.key] = {
          '体积KB': (bytes.length / 1024).round(),
          '扫描器': scan.toString(),
          '引擎 frameCount': codec.frameCount,
          '引擎 repetitionCount': codec.repetitionCount,
          '帧数一致': scan.frameCount == codec.frameCount,
        };
      } catch (ex) {
        out[e.key] = {'error': '$ex'};
      }
    }
    R['V7c'] = out;
  });

  // ── V1w：Image widget 路径下图像确实加载 + 逐帧推进（核心假设）─────
  testWidgets('V1w widget 路径加载与逐帧推进', (tester) async {
    try {
      final provider = FileImage(gifSmall);
      var callbacks = 0;
      String? firstSync;
      ImageInfo? firstInfo;
      final sw = Stopwatch()..start();

      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Image(image: provider, fit: BoxFit.cover),
          ),
        ),
      ));
      // 与 widget 同一 key → 同一 stream（V4 已证）
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener l;
      l = ImageStreamListener((info, sync) {
        if (callbacks == 0) {
          firstSync = 'sync=$sync t=${sw.elapsedMilliseconds}ms';
          firstInfo = info;
        }
        callbacks++;
      });
      stream.addListener(l);

      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      stream.removeListener(l);

      R['V1w'] = {
        '图像已加载': firstInfo != null,
        '首帧尺寸': sizeOf(firstInfo),
        '首帧回调': firstSync,
        '2 秒内帧回调次数': callbacks,
        '结论': firstInfo == null
            ? '加载失败（探针 invalid）'
            : (callbacks > 1
                ? 'Image widget 路径确实逐帧推进 → GIF 背景会动'
                : '只收到首帧 → widget 路径不会推进（需重新评估方案）'),
      };
    } catch (e, s) {
      R['V1w'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V2b/V2c：widget 路径下 cacheWidth 对动图 / 静态图是否生效 ──────
  testWidgets('V2b cacheWidth 动图', (tester) async {
    try {
      final img = await pumpImage(
        tester,
        ResizeImage(FileImage(gifSmall), width: 100),
      );
      R['V2b'] = {
        '请求 cacheWidth=100，原图 200x150': true,
        '实际解码尺寸': sizeOf(img) ?? 'null(未加载)',
        'cacheWidth 生效': widthOf(img) == 100,
        '探针有效': img != null,
      };
    } catch (e) {
      R['V2b'] = {'error': '$e'};
    }
  });

  testWidgets('V2c cacheWidth 静态图对照', (tester) async {
    try {
      final resized = await pumpImage(
        tester,
        ResizeImage(FileImage(pngStatic), width: 100),
      );
      final plain = await pumpImage(tester, FileImage(pngStatic));
      R['V2c'] = {
        'PNG 800x600 + cacheWidth=100 → 实际': sizeOf(resized) ?? 'null(未加载)',
        'PNG 800x600 原尺寸 → 实际': sizeOf(plain) ?? 'null(未加载)',
        '静态 cacheWidth 生效': widthOf(resized) == 100,
        '探针有效': resized != null && plain != null,
      };
    } catch (e) {
      R['V2c'] = {'error': '$e'};
    }
  });

  // ── V3：precacheImage 对动图的语义 ───────────────────────────────
  testWidgets('V3 precacheImage 语义', (tester) async {
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();

      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ));

      final swPng = Stopwatch()..start();
      await tester.runAsync(() => precacheImage(FileImage(pngStatic), ctx)
          .timeout(const Duration(seconds: 15), onTimeout: () {}));
      swPng.stop();

      final swGif = Stopwatch()..start();
      await tester.runAsync(() => precacheImage(FileImage(gifSmall), ctx)
          .timeout(const Duration(seconds: 15), onTimeout: () {}));
      swGif.stop();

      // precache 后重新挂监听并 pump，看多帧是否继续推进
      var callbacks = 0;
      final provider = FileImage(gifSmall);
      final stream = provider.resolve(ImageConfiguration.empty);
      late ImageStreamListener l;
      l = ImageStreamListener((info, sync) => callbacks++);
      stream.addListener(l);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      stream.removeListener(l);

      R['V3'] = {
        'precache PNG(800x600) 耗时ms': swPng.elapsedMilliseconds,
        'precache GIF(200x150x6) 耗时ms': swGif.elapsedMilliseconds,
        '仅挂监听（无 widget）时 1s 内帧回调': callbacks,
        '解读': '回调>1 → 挂上监听即继续推进（多帧 completer 存活）；'
            '=1 → 只留首帧静帧',
      };
    } catch (e, s) {
      R['V3'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V6：ImageCache 对多帧图的计费口径 ───────────────────────────
  testWidgets('V6 ImageCache 多帧计费', (tester) async {
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.maximumSizeBytes = 64 * 1024 * 1024;

      // 先跑一次静态图对照，确认探针能产生计费
      final staticImg = await pumpImage(tester, FileImage(pngStatic));
      final afterStatic = cache.currentSizeBytes;
      cache.clear();

      final gifImg = await pumpImage(tester, FileImage(gifMid));
      final afterGif = cache.currentSizeBytes;

      const gifOneFrame = 500 * 500 * 4; // 1,000,000
      const pngOneFrame = 800 * 600 * 4; // 1,920,000

      R['V6'] = {
        '静态 800x600 加载后 currentSizeBytes': afterStatic,
        '静态理论单帧': pngOneFrame,
        '静态探针有效': staticImg != null,
        'GIF 500x500x20 加载后 currentSizeBytes': afterGif,
        'GIF 理论单帧': gifOneFrame,
        '倍数（相对单帧）':
            (afterGif / gifOneFrame).toStringAsFixed(2),
        'GIF 实际解码尺寸': sizeOf(gifImg),
        'GIF 探针有效': gifImg != null,
        '解读': '倍数≈1 → 只按首帧计费（64MB 预算低估多帧内存）；'
            '倍数≈帧数(20) → 按全部帧计费',
      };
    } catch (e, s) {
      R['V6'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V5：模糊栅格代价（软件光栅化相对值，仅在图像确实加载时有效）──
  testWidgets('V5 模糊栅格代价', (tester) async {
    try {
      final out = <String, dynamic>{};
      for (final entry in {'none': 0.0, 'sigma8': 8.0, 'sigma20': 20.0}.entries) {
        final key = GlobalKey();
        Widget img = Image(image: FileImage(gifSmall), fit: BoxFit.cover);
        if (entry.value > 0) {
          img = ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: entry.value,
              sigmaY: entry.value,
            ),
            child: img,
          );
        }
        await tester.pumpWidget(MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(width: 800, height: 600, child: img),
            ),
          ),
        ));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        ImageInfo? probeInfo;
        final probeStream = FileImage(gifSmall).resolve(ImageConfiguration.empty);
        late ImageStreamListener pl;
        pl = ImageStreamListener((info, sync) {
          probeInfo ??= info;
        });
        probeStream.addListener(pl);
        await tester.pump();
        probeStream.removeListener(pl);
        final loaded = probeInfo != null;
        final times = <int>[];
        await tester.runAsync(() async {
          for (var i = 0; i < 6; i++) {
            final sw = Stopwatch()..start();
            final boundary = key.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
            final image = await boundary.toImage();
            sw.stop();
            times.add(sw.elapsedMicroseconds);
            image.dispose();
          }
        });
        times.removeAt(0); // 丢弃首次（含暖机）
        out[entry.key] = {
          '图像已加载': loaded,
          '平均微秒(去首次)': times.isEmpty
              ? null
              : (times.reduce((a, b) => a + b) / times.length).round(),
          '样本': times,
        };
      }
      out['说明'] = 'flutter_tester 软件光栅化，仅相对量级；真机 GPU 需另行走查';
      R['V5'] = out;
    } catch (e, s) {
      R['V5'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });
}
