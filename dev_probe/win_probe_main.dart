// Phase 0 真机探针入口（临时，验证完成后删除）
//
// 为什么需要它：flutter_tester 的 fake scheduler 下 ImageProvider 回调不推进、
// ImageCache 不计费，V1w/V2b/V2c/V6/V5 在纯测试环境拿不到有效数据。
//
// 运行（debug 模式，避免覆盖用户已验证的 Release 产物）：
//   ./flutter/bin/flutter.bat run -d windows -t dev_probe/win_probe_main.dart
//
// 探针跑完写 dev_probe/win_results.json 并 exit(0)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'gif_fixtures.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

/// precacheImage 需要 BuildContext
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class _ProbeApp extends StatefulWidget {
  const _ProbeApp({super.key});

  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final Map<String, dynamic> _r = {};
  late Directory _dir;
  late File _gifSmall;
  late File _gifMid;
  late File _gifHd;
  late File _pngStatic;

  /// 当前探针要展示的 provider（由探针流程设置）
  ImageProvider? _provider;
  double _blurSigma = 0;
  final _tick = ValueNotifier<double>(0);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    final base = Directory('${Directory.current.path}${Platform.pathSeparator}dev_probe');
    _dir = base.existsSync() ? base : Directory.systemTemp.createTempSync('ct_bgwin_');
    String p(String n) => '${_dir.path}${Platform.pathSeparator}$n';
    _gifSmall = File(p('w_small.gif'))
      ..writeAsBytesSync(buildGif(
        width: 200,
        height: 150,
        frameDelaysCs: List<int>.filled(6, 10),
      ));
    _gifMid = File(p('w_mid.gif'))
      ..writeAsBytesSync(buildGif(
        width: 500,
        height: 500,
        frameDelaysCs: List<int>.filled(20, 10),
      ));
    // 贴近真实全屏背景尺寸的动图（W5 模糊代价用）
    _gifHd = File(p('w_hd.gif'))
      ..writeAsBytesSync(buildGif(
        width: 1920,
        height: 1053,
        frameDelaysCs: List<int>.filled(6, 10),
      ));
    // 静态对照图改用项目真实 PNG（自写的 buildPng 产出的文件引擎解不开，
    // 见 RESULTS.md「探针自身缺陷」；这里用生产环境实际使用的主题背景图）
    _pngStatic = File('assets${Platform.pathSeparator}images'
        '${Platform.pathSeparator}themes${Platform.pathSeparator}blue_sky.png');
    if (!_pngStatic.existsSync()) {
      _pngStatic = File(p('w_static.png'))
        ..writeAsBytesSync(buildPng(width: 800, height: 600, gray: 0x80));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _runAll());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _tick.dispose();
    super.dispose();
  }

  // ── 通用：挂 provider 到画面上并等待首帧 ──────────────────────────
  Future<ImageInfo?> _showAndWait(ImageProvider provider,
      {double blurSigma = 0, int waitMs = 1200}) async {
    setState(() {
      _provider = provider;
      _blurSigma = blurSigma;
    });
    // 等真实 vsync 若干帧
    final info = await _firstInfo(provider, waitMs);
    return info;
  }

  Future<ImageInfo?> _firstInfo(ImageProvider provider, int waitMs,
      {int countFrames = 0, void Function(int)? onCount}) async {
    ImageInfo? got;
    var n = 0;
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener((info, sync) {
      got ??= info;
      n++;
      onCount?.call(n);
    });
    stream.addListener(l);
    await Future<void>.delayed(Duration(milliseconds: waitMs));
    stream.removeListener(l);
    return got;
  }

  String _size(ImageInfo? i) =>
      i == null ? 'null(未回调)' : '${i.image.width}x${i.image.height}';

  Future<void> _runAll() async {
    try {
      // W1：widget 路径是否逐帧推进（真机真实 vsync）
      var gifFrames = 0;
      final gifInfo = await _firstInfo(
        FileImage(_gifSmall),
        2000,
        onCount: (c) => gifFrames = c,
      );
      _r['W1_动图在widget路径逐帧推进'] = {
        '图像已加载': gifInfo != null,
        '首帧尺寸': _size(gifInfo),
        '2 秒内帧回调次数（10cs 延迟 = 预期 ~20）': gifFrames,
        '结论': gifInfo == null
            ? '加载失败'
            : (gifFrames > 1 ? '✅ 会动' : '❌ 只播首帧'),
      };

      // W2：cacheWidth 对动图是否生效（生产路径 ResizeImage）
      final animResized =
          await _showAndWait(ResizeImage(FileImage(_gifSmall), width: 100));
      _r['W2_cacheWidth对动图'] = {
        '请求 100，原图 200x150': true,
        '实际': _size(animResized),
        'cacheWidth 生效': animResized?.image.width == 100,
      };

      // W3：静态图对照（真实 PNG 1920x1053）
      final pngResized =
          await _showAndWait(ResizeImage(FileImage(_pngStatic), width: 100));
      final pngPlain = await _showAndWait(FileImage(_pngStatic));
      _r['W3_cacheWidth对静态图'] = {
        '素材': _pngStatic.path,
        'PNG 原图 + cacheWidth=100 → 实际': _size(pngResized),
        'PNG 原尺寸 → 实际': _size(pngPlain),
        '静态 cacheWidth 生效': pngResized?.image.width == 100,
        '探针有效': pngResized != null && pngPlain != null,
      };

      // W4：ImageCache 计费口径
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      final staticInfo = await _showAndWait(FileImage(_pngStatic));
      final afterStatic = cache.currentSizeBytes;
      cache.clear();
      final gifLoaded = await _showAndWait(FileImage(_gifMid));
      final afterGif = cache.currentSizeBytes;
      _r['W4_ImageCache计费'] = {
        '静态 PNG 加载后': afterStatic,
        'GIF 500x500x20 加载后（理论单帧 1000000）': afterGif,
        'GIF 相对单帧倍数': (afterGif / 1000000).toStringAsFixed(2),
        'GIF 实际解码尺寸': _size(gifLoaded),
        '静态实际解码尺寸': _size(staticInfo),
        'GIF 20 帧却只计首帧 → 64MB 预算低估多帧内存':
            afterGif == 1000000,
      };
      cache.clear();

      // W6：precacheImage 对动图是否会返回（生产代码 background_image_resolver.dart:110
      // 就是 await 它之后才显示背景 —— 若对 GIF 不返回，现有 GIF 用户背景永远不显示）
      final pre = <String, dynamic>{};
      for (final e in {
        'PNG(1920x1053)': _pngStatic,
        'GIF(200x150x6)': _gifSmall,
        'GIF(1920x1053x6)': _gifHd,
      }.entries) {
        PaintingBinding.instance.imageCache.clear();
        final ctx2 = navigatorKey.currentContext!;
        final sw = Stopwatch()..start();
        var timedOut = false;
        await precacheImage(FileImage(e.value), ctx2).timeout(
          const Duration(seconds: 20),
          onTimeout: () => timedOut = true,
        );
        sw.stop();
        pre[e.key] = {
          '耗时ms': sw.elapsedMilliseconds,
          '是否超时(20s)': timedOut,
        };
      }
      pre['结论'] = pre.values
              .whereType<Map<String, dynamic>>()
              .any((m) => m['是否超时(20s)'] == true)
          ? '❌ 有动图 precache 未返回 → 生产代码必须对动图跳过 precache'
          : '✅ 动图 precache 正常返回，现有 await 流程可用';
      _r['W6_precacheImage对动图'] = pre;

      // W7：全屏背景的真实帧耗时（debug 模式相对值）
      // 对照设计：静态 PNG(同尺寸) 无模糊 = 基线；动图无模糊 = 动图自身代价；
      // 动图 + sigma8 / sigma20 = 模糊增量代价
      final blurRuns = <String, dynamic>{};
      final cases = <MapEntry<String, ({File file, double sigma})>>[
        MapEntry('A_静态PNG_无模糊(基线)',
            (file: _pngStatic, sigma: 0.0)),
        MapEntry('B_动图_无模糊', (file: _gifHd, sigma: 0.0)),
        MapEntry('C_动图_sigma8', (file: _gifHd, sigma: 8.0)),
        MapEntry('D_动图_sigma20', (file: _gifHd, sigma: 20.0)),
      ];
      for (final e in cases) {
        await _showAndWait(FileImage(e.value.file), blurSigma: e.value.sigma);
        final timings = <FrameTiming>[];
        void cb(List<FrameTiming> t) => timings.addAll(t);
        SchedulerBinding.instance.addTimingsCallback(cb);
        // 强制连续出帧：每 16ms 改一次值 → 驱动重绘（不依赖 Ticker，避免假 vsync）
        var n = 0;
        _ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
          _tick.value = (n++ % 1000) / 1000.0;
        });
        await Future<void>.delayed(const Duration(seconds: 2));
        _ticker?.cancel();
        SchedulerBinding.instance.removeTimingsCallback(cb);
        timings.removeWhere((t) => t.rasterDuration == Duration.zero);
        final raster = timings.map((t) => t.rasterDuration.inMicroseconds).toList()
          ..sort();
        final build = timings.map((t) => t.buildDuration.inMicroseconds).toList()
          ..sort();
        double avg(List<int> a) =>
            a.isEmpty ? 0 : a.reduce((x, y) => x + y) / a.length;
        blurRuns[e.key] = {
          '帧数': timings.length,
          'raster 平均us': avg(raster).round(),
          'raster p95us':
              raster.isEmpty ? 0 : raster[(raster.length * 0.95).floor().clamp(0, raster.length - 1)],
          'raster 超16.7ms帧数（掉帧）':
              timings.where((t) => t.rasterDuration.inMicroseconds > 16700).length,
          'build 平均us': avg(build).round(),
        };
      }
      blurRuns['说明'] = 'debug(JIT) 模式真机数据，仅相对量级';
      _r['W7_模糊帧耗时'] = blurRuns;
    } catch (e, s) {
      _r['error'] = '$e\n${s.toString().split('\n').take(4).join('\n')}';
    } finally {
      final json = const JsonEncoder.withIndent('  ').convert(_r);
      stdout.writeln('@@@WIN_PROBE@@@$json@@@END@@@');
      try {
        File('${_dir.path}${Platform.pathSeparator}win_results.json')
            .writeAsStringSync(json);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      home: Scaffold(
        body: ValueListenableBuilder<double>(
          valueListenable: _tick,
          builder: (context, v, _) {
            Widget bg = _provider == null
                ? const ColoredBox(color: Colors.black)
                : Image(image: _provider!, fit: BoxFit.cover);
            if (_blurSigma > 0) {
              bg = ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: _blurSigma,
                  sigmaY: _blurSigma,
                ),
                child: bg,
              );
            }
            return SizedBox.expand(
              child: RepaintBoundary(
                child: Transform.scale(scale: 1 + v * 0.001, child: bg),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _VsyncShim extends TickerProvider {
  const _VsyncShim();
  @override
  Ticker createTicker(TickerCallback onTick) =>
      Ticker(onTick, debugLabel: 'probe');
}


