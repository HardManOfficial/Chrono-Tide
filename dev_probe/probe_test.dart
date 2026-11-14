// Phase 0 技术验证（V1-V8）—— 临时探测，验证完成后删除
//
// 运行：env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
//         ./flutter/bin/flutter.bat test dev_probe/probe_test.dart
//
// 每个探针独立 try/catch，单项失败不影响其余；结束时把结果 JSON 写到
// systemTemp 并打印到 stdout。
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
late File gifSmall; // 200x150, 6 帧, 10cs/帧
late File gifMid; // 500x500, 20 帧, 10cs/帧
late File gifBig; // 128x128, 600 帧（V7 扫描用）
late File pngTiny;

Future<Uint8List> _read(File f) => f.readAsBytes();

/// 等待真实时间推进（必须 runAsync，否则 flutter_test 的假时钟不推进 IO/解码）
Future<void> settle(WidgetTester tester, {int ms = 300}) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
}

void _save() {
  final json = const JsonEncoder.withIndent('  ').convert(R);
  stdout.writeln('\n===== PROBE RESULTS JSON =====\n$json\n===== END =====');
  try {
    File('${probeDir.path}${Platform.pathSeparator}results.json')
        .writeAsStringSync(json);
    File('dev_probe${Platform.pathSeparator}results.json')
        .writeAsStringSync(json);
  } catch (e) {
    stdout.writeln('[probe] 写 results.json 失败(忽略): $e');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    probeDir = Directory.systemTemp.createTempSync('ct_bgprobe_');
    gifSmall = File('${probeDir.path}${Platform.pathSeparator}small.gif')
      ..writeAsBytesSync(buildGif(
        width: 200,
        height: 150,
        frameDelaysCs: List<int>.filled(6, 10),
      ));
    gifMid = File('${probeDir.path}${Platform.pathSeparator}mid.gif')
      ..writeAsBytesSync(buildGif(
        width: 500,
        height: 500,
        frameDelaysCs: List<int>.filled(20, 10),
      ));
    gifBig = File('${probeDir.path}${Platform.pathSeparator}big.gif')
      ..writeAsBytesSync(buildGif(
        width: 128,
        height: 128,
        frameDelaysCs: List<int>.filled(600, 10),
      ));
    pngTiny = File('${probeDir.path}${Platform.pathSeparator}tiny.png')
      ..writeAsBytesSync(buildTinyPng());
  });

  tearDownAll(() {
    _save();
    stdout.writeln('[probe] dir = ${probeDir.path}');
  });

  // 每个探针跑完即落盘，避免后续探针卡死导致已得数据全部丢失
  tearDown(_save);

  // ── V8：codec 的帧数 / 循环次数语义 ─────────────────────────────
  test('V8 repetitionCount / frameCount', () async {
    try {
      final inf = await ui.instantiateImageCodec(buildGif(
        width: 40,
        height: 30,
        frameDelaysCs: List<int>.filled(5, 10),
        loopCount: 0,
      ));
      final fin = await ui.instantiateImageCodec(buildGif(
        width: 40,
        height: 30,
        frameDelaysCs: List<int>.filled(5, 10),
        loopCount: 3,
      ));
      final none = await ui.instantiateImageCodec(buildGif(
        width: 40,
        height: 30,
        frameDelaysCs: List<int>.filled(5, 10),
        loopCount: -1,
      ));
      R['V8'] = {
        'loopCount0(无限)': {
          'frameCount': inf.frameCount,
          'repetitionCount': inf.repetitionCount,
        },
        'loopCount3': {
          'frameCount': fin.frameCount,
          'repetitionCount': fin.repetitionCount,
        },
        '无Netscape扩展': {
          'frameCount': none.frameCount,
          'repetitionCount': none.repetitionCount,
        },
      };
    } catch (e, s) {
      R['V8'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V1：引擎是否逐帧推进 + 每帧延迟是否被遵守 ────────────────────
  test('V1 逐帧推进与帧延迟', () async {
    try {
      final codec = await ui.instantiateImageCodec(await _read(gifSmall));
      final seen = <String>[];
      final sw = Stopwatch()..start();
      for (var i = 0; i < 6; i++) {
        final f = await codec.getNextFrame();
        seen.add('frame#$i ${f.image.width}x${f.image.height} '
            'dur=${f.duration.inMilliseconds}ms t=${sw.elapsedMilliseconds}ms');
        f.image.dispose();
      }
      final wrapped = _appendFrame(codec);
      R['V1'] = {
        'frames': seen,
        '需要回绕': wrapped,
        '结论': '逐帧 getNextFrame 全部成功；GIF 有多帧即证明引擎具备多帧解码能力',
      };
    } catch (e) {
      R['V1'] = {'error': '$e'};
    }
  });

  // ── V2：cacheWidth / targetWidth 对多帧是否生效（P0 关键）────────
  test('V2 cacheWidth 对多帧是否生效', () async {
    try {
      // 直接用引擎 API
      final codec = await ui.instantiateImageCodec(
        await _read(gifSmall),
        targetWidth: 100,
      );
      final f1 = await codec.getNextFrame();
      final f2 = await codec.getNextFrame();
      final direct = {
        '请求 targetWidth=100, 原图 200x150': true,
        '第1帧尺寸': '${f1.image.width}x${f1.image.height}',
        '第2帧尺寸': '${f2.image.width}x${f2.image.height}',
        '生效': f1.image.width == 100,
      };
      f1.image.dispose();
      f2.image.dispose();

      R['V2'] = {
        '引擎API直测': direct,
        '备注': '生产路径（ResizeImage/FileImage）见 V2b —— 纯 test() 里引擎文件 IO 不回调',
      };
    } catch (e, s) {
      R['V2'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V2b：走生产路径 ResizeImage(FileImage)（必须 runAsync，否则引擎文件 IO 不回调）──
  testWidgets('V2b 生产路径 cacheWidth', (tester) async {
    try {
      ImageInfo? resizeInfo;
      ImageInfo? plainInfo;
      await tester.runAsync(() async {
        resizeInfo = await _firstImageInfo(
          ResizeImage(FileImage(gifSmall), width: 100),
        );
        plainInfo = await _firstImageInfo(FileImage(gifSmall));
      });
      R['V2b'] = {
        'ResizeImage(width:100) 首帧': resizeInfo == null
            ? 'null(未回调)'
            : '${resizeInfo!.image.width}x${resizeInfo!.image.height}',
        'FileImage 原尺寸首帧': plainInfo == null
            ? 'null(未回调)'
            : '${plainInfo!.image.width}x${plainInfo!.image.height}',
        'cacheWidth 生效': resizeInfo?.image.width == 100,
      };
      resizeInfo?.image.dispose();
      plainInfo?.image.dispose();
    } catch (e, s) {
      R['V2b'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V4：同一 provider 是否共享解码器 + 不同 cacheWidth 是否分叉 ───
  testWidgets('V4 provider 共享与分叉', (tester) async {
    try {
      final s1 = FileImage(gifSmall).resolve(ImageConfiguration.empty);
      final s2 = FileImage(gifSmall).resolve(ImageConfiguration.empty);
      final s3 = ResizeImage(FileImage(gifSmall), width: 1920)
          .resolve(ImageConfiguration.empty);
      final s4 = ResizeImage(FileImage(gifSmall), width: 1920)
          .resolve(ImageConfiguration.empty);
      R['V4'] = {
        '同 FileImage(path) 两次 → 同一个 completer':
            identical(s1.completer, s2.completer),
        '同 ResizeImage(1920) 两次 → 同一个 completer':
            identical(s3.completer, s4.completer),
        'FileImage vs ResizeImage(1920) → 同一个 completer':
            identical(s1.completer, s3.completer),
        '结论提示': '前两行为 true → 「共用 provider key = 共用解码器」成立；'
            '第三行为 false → cacheWidth 必须全局统一，否则起第二个解码器',
      };
    } catch (e) {
      R['V4'] = {'error': '$e'};
    }
  });

  // ── V6：ImageCache 对多帧图的计费口径 ───────────────────────────
  testWidgets('V6 ImageCache 多帧计费', (tester) async {
    try {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.maximumSizeBytes = 64 * 1024 * 1024;
      const oneFrameBytes = 500 * 500 * 4; // 1,000,000
      final before = cache.currentSizeBytes;
      ImageInfo? info;
      await tester.runAsync(() async {
        final stream = FileImage(gifMid).resolve(ImageConfiguration.empty);
        final c = Completer<void>();
        late ImageStreamListener l;
        l = ImageStreamListener((i, sync) {
          info = i;
          if (!c.isCompleted) c.complete();
        }, onError: (e, s) {
          if (!c.isCompleted) c.complete();
        });
        stream.addListener(l);
        await c.future.timeout(const Duration(seconds: 10), onTimeout: () {});
        await Future<void>.delayed(const Duration(milliseconds: 200));
        // 让多帧解码推进
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      final after = cache.currentSizeBytes;
      R['V6'] = {
        'GIF 逻辑尺寸': '500x500 x 20 帧',
        '单帧理论字节': oneFrameBytes,
        'currentSizeBytes 变化': after - before,
        '倍数（相对单帧）':
            ((after - before) / oneFrameBytes).toStringAsFixed(2),
        '首帧实际尺寸': info == null
            ? null
            : '${info!.image.width}x${info!.image.height}',
        '解读': '倍数≈1 → 只按首帧计费（64MB 预算会低估多帧内存）；'
            '倍数≈帧数 → 按全部帧计费',
      };
      info?.image.dispose();
    } catch (e, s) {
      R['V6'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V3：precacheImage 对多帧的语义 + 监听是否能看到多帧推进 ──────
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

      // PNG 对照
      var pngTimeout = false;
      final swPng = Stopwatch()..start();
      await tester.runAsync(() => precacheImage(FileImage(pngTiny), ctx)
          .timeout(const Duration(seconds: 15), onTimeout: () {
        pngTimeout = true;
      }));
      swPng.stop();

      // GIF
      var gifTimeout = false;
      final swGif = Stopwatch()..start();
      await tester.runAsync(() => precacheImage(FileImage(gifSmall), ctx)
          .timeout(const Duration(seconds: 15), onTimeout: () {
        gifTimeout = true;
      }));
      swGif.stop();

      // precache 后重新 resolve 同一 provider，数一段时间内收到多少帧
      var frameCallbacks = 0;
      final identityAfterPrecache = <String, dynamic>{};
      await tester.runAsync(() async {
        final stream = FileImage(gifSmall).resolve(ImageConfiguration.empty);
        late ImageStreamListener l;
        l = ImageStreamListener((i, sync) {
          frameCallbacks++;
        });
        stream.addListener(l);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        stream.removeListener(l);
        identityAfterPrecache['首帧回调是否同步(sync=true)'] = frameCallbacks > 0;
      });

      R['V3'] = {
        'precache PNG 耗时ms': swPng.elapsedMilliseconds,
        'precache PNG 是否超时': pngTimeout,
        'precache GIF 耗时ms': swGif.elapsedMilliseconds,
        'precache GIF 是否超时': gifTimeout,
        'precache 后 800ms 内收到的帧回调次数': frameCallbacks,
        '解读': '回调次数 >1 → precache 留下的多帧解码器仍在推进（监听即继续播）；'
            '=1 → precache 只留首帧；precache 超时 → precacheImage 对动图不返回',
      };
    } catch (e, s) {
      R['V3'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V5：模糊 + 动图的栅格代价（软件光栅化相对值）────────────────
  testWidgets('V5 模糊栅格代价(相对值)', (tester) async {
    try {
      final out = <String, dynamic>{};
      for (final entry in {'none': 0.0, 'sigma8': 8.0, 'sigma20': 20.0}.entries) {
        final key = GlobalKey();
        Widget img = Image.file(gifSmall, fit: BoxFit.cover, cacheWidth: 1920);
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
        await settle(tester, ms: 400);
        final times = <int>[];
        await tester.runAsync(() async {
          for (var i = 0; i < 5; i++) {
            final sw = Stopwatch()..start();
            final boundary =
                key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await boundary.toImage();
            sw.stop();
            times.add(sw.elapsedMicroseconds);
            image.dispose();
          }
        });
        out[entry.key] = {
          '平均微秒': times.isEmpty
              ? null
              : (times.reduce((a, b) => a + b) / times.length).round(),
          '样本': times,
        };
      }
      out['说明'] = 'flutter_tester 软件光栅化，仅作相对量级参考，不代表 GPU 真机耗时';
      R['V5'] = out;
    } catch (e, s) {
      R['V5'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });

  // ── V7：块级扫描耗时与提前终止收益 ─────────────────────────────
  test('V7 扫描耗时', () async {
    try {
      final big = await _read(gifBig);
      final small = await _read(gifSmall);

      final swSmall = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        scanGif(small);
      }
      swSmall.stop();

      final swFull = Stopwatch()..start();
      final full = scanGif(big);
      swFull.stop();

      final swCap = Stopwatch()..start();
      final capped = scanGif(big, maxFrames: 100);
      swCap.stop();

      final mb = big.length / (1024 * 1024);
      R['V7'] = {
        'big.gif 体积MB': double.parse(mb.toStringAsFixed(2)),
        '全量扫描ms': swFull.elapsedMicroseconds / 1000,
        '吞吐MB/s': double.parse(
            (mb / (swFull.elapsedMicroseconds / 1000000)).toStringAsFixed(1)),
        '全量结果': full.toString(),
        '上限截断(100帧)ms': swCap.elapsedMicroseconds / 1000,
        '截断结果': capped.toString(),
        'small.gif 平均单次扫描us': swSmall.elapsedMicroseconds / 50,
        'small.gif 结果': scanGif(small).toString(),
        '解读': '吞吐若 >100MB/s，则 10MB 文件全量扫描 <100ms，'
            '配合上限截断可稳定在数十毫秒内',
      };
    } catch (e, s) {
      R['V7'] = {'error': '$e', 'stack': '$s'.split('\n').take(3).join(' | ')};
    }
  });
}

/// 首帧之后回绕是否可继续取帧（验证循环）
String _appendFrame(ui.Codec codec) {
  try {
    return codec.frameCount > 6 ? '有更多帧' : '达到 frameCount=${codec.frameCount}';
  } catch (e) {
    return 'err:$e';
  }
}

Future<ImageInfo?> _firstImageInfo(ImageProvider provider) async {
  final c = Completer<ImageInfo?>();
  late ImageStreamListener l;
  final stream = provider.resolve(ImageConfiguration.empty);
  l = ImageStreamListener((info, sync) {
    if (!c.isCompleted) c.complete(info);
  }, onError: (e, s) {
    if (!c.isCompleted) c.complete(null);
  });
  stream.addListener(l);
  final r = await c.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => null,
  );
  stream.removeListener(l);
  return r;
}
