/// `NsfwImage` **调用方装饰层契约**回归。
///
/// ## 这份测试守的是什么
///
/// 角标按钮在 `NsfwImage` **自身子树内**能正常收到点击；但调用方常在它之上
/// 再叠一层全尺寸装饰（压暗 / 提亮 / 毛玻璃遮罩）。问题出在 `Stack` 的命中
/// 测试规则上：
///
/// - `Container(color: …)` → `ColoredBox`，其 RenderObject 用
///   `HitTestBehavior.opaque`；
/// - `Stack.hitTestChildren` **自上向下**扫描，命中第一个子节点就停止。
///
/// 于是这层装饰把角标整个挡在命中测试之外 —— 表现为**看得见、点不动**。
///
/// v2.7 用户实测：探索库卡片（`discover_page`）、探索详情封面
/// （`game_detail_page`）、BPM 大屏首页卡片（`big_picture_home`）三处**全部**
/// 因此失效。修复方式是在这三处把装饰层包进 `IgnorePointer`。
///
/// 本文件用「有 / 无 `IgnorePointer`」两组对照把这条机制钉死：
/// 调用方今后若又叠了裸遮罩，第一组用例会明确指向根因。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_store.dart';
import 'package:chrono_tide/services/nsfw/nsfw_settings.dart';
import 'package:chrono_tide/widgets/nsfw/nsfw_image.dart';

const String _sig = 'censor_detect_v1.0_n/640/0.2';
const String _path = r'D:\Games\Demo\.metadata\cover.jpg';
const Key _childKey = Key('nsfw-test-child');

const NsfwBox _box = NsfwBox(
  x0: 100,
  y0: 100,
  x1: 200,
  y1: 200,
  label: 0,
  conf: 0.9,
);

Future<ui.Image> _makeImage(int w, int h) async {
  final Uint8List rgba = Uint8List(w * h * 4);
  for (int i = 0; i < w * h; i++) {
    rgba[i * 4] = 200;
    rgba[i * 4 + 1] = 100;
    rgba[i * 4 + 2] = 50;
    rgba[i * 4 + 3] = 255;
  }
  final ui.ImmutableBuffer buffer =
      await ui.ImmutableBuffer.fromUint8List(rgba);
  final ui.ImageDescriptor desc = ui.ImageDescriptor.raw(
    buffer,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final ui.Codec codec = await desc.instantiateCodec();
  final ui.FrameInfo frame = await codec.getNextFrame();
  return frame.image;
}

class _ReadyProvider extends ImageProvider<_ReadyProvider> {
  _ReadyProvider(this.image, this.tag);
  final ui.Image image;
  final String tag;
  @override
  Future<_ReadyProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ReadyProvider>(this);
  @override
  ImageStreamCompleter loadImage(
    _ReadyProvider key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
      );
  @override
  bool operator ==(Object other) =>
      other is _ReadyProvider && other.tag == tag;
  @override
  int get hashCode => tag.hashCode;
}

Finder get _child => find.byKey(_childKey);
Finder get _blur => find.byType(ImageFiltered);
Finder get _revealBadge => find.byKey(const Key('nsfw_reveal_badge'));

Widget _child0() => Container(key: _childKey, color: const Color(0xFF00FF00));

/// 复刻探索库 / 探索详情卡片：`cover` 类敏感封面之上叠一层全尺寸装饰遮罩。
Widget _hostWithScrim({required bool ignore}) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                NsfwImage.file(
                  _path,
                  contentKind: NsfwContentKind.cover,
                  child: _child0(),
                ),
                // 调用方风格的全尺寸压暗层（探索详情为白色 0.38、探索库为
                // background 0.33），此处取同型即可。
                IgnorePointer(
                  ignoring: ignore,
                  child: Container(color: Colors.white.withOpacity(0.38)),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  late ui.Image image400;
  late Directory tmpRoot;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    image400 = await _makeImage(400, 400);
  });

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ct_nsfw_scrim_');
    PathHelper.exeDirOverride = tmpRoot.path;
    NsfwSettings.resetForTest();
    NsfwDetectionStore.resetForTest();
    NsfwImage.debugProviderFactory =
        (NsfwImage w) => _ReadyProvider(image400, 'ready');
    NsfwImage.debugEnqueueOverride =
        (String path, {bool highPriority = false}) async => null;
  });

  tearDown(() async {
    NsfwImage.debugProviderFactory = null;
    NsfwImage.debugEnqueueOverride = null;
    NsfwSettings.resetForTest();
    NsfwDetectionStore.resetForTest();
    PathHelper.exeDirOverride = null;
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  void seed() {
    NsfwSettings.instance.seedForTest(
      enabled: true,
      allowReveal: true,
      mode: NsfwDisplayMode.clean,
    );
    NsfwDetectionStore.instance.seedForTest(_sig, <String, NsfwDetection>{
      NsfwDetectionStore.keyForFile(_path): NsfwDetection(
        imgW: 400,
        imgH: 400,
        detectedAtMs: 1700000000000,
        boxes: const <NsfwBox>[_box],
      ),
    });
  }

  group('调用方装饰层契约（v2.7.1）', () {
    testWidgets('装饰层未包 IgnorePointer → 角标被挡在命中测试外（点不动）',
        (WidgetTester tester) async {
      seed();
      await tester.pumpWidget(_hostWithScrim(ignore: false));

      expect(_revealBadge, findsOneWidget, reason: '角标在树上、看得见');
      await tester.tap(_revealBadge, warnIfMissed: false);
      await tester.pump();
      expect(
        _blur,
        findsOneWidget,
        reason: '裸 Container(color:) 遮罩用 HitTestBehavior.opaque 吞掉点击，'
            '模糊仍在 —— 这正是用户报告的"看得见点不动"',
      );
    });

    testWidgets('装饰层包 IgnorePointer → 角标可点、成功揭示（修复形态）',
        (WidgetTester tester) async {
      seed();
      await tester.pumpWidget(_hostWithScrim(ignore: true));

      expect(_revealBadge, findsOneWidget);
      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_blur, findsNothing, reason: '点击穿透到底层角标 → 揭示成功');
      expect(_child, findsOneWidget);
    });
  });
}
