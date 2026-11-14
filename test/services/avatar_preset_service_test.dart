import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/avatar_preset_service.dart';

/// AvatarPresetService 单测 —— 内置头像池的枚举 / 路径 / 排除当前的随机抽取。
///
/// 覆盖方案 §7 Phase 1 的三条判据：随机排除当前、id 稳定性、缺图回退。
/// 同时充当 Phase 0 探针：
/// - P-01：`AssetManifest.loadFromAssetBundle` 在测试环境下能列出全部 34 项；
/// - P-02（部分）：能读到 webp 原始字节且魔数正确（真正解码见 widget 测试）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => AvatarPresetService.resetCacheForTest());

  group('头像池常量与路径', () {
    test('兜底常量表是 av_01 … av_34，共 34 项且与素材命名一致', () {
      final ids = AvatarPresetService.fallbackIds;
      expect(ids.length, 34);
      expect(ids.first, 'av_01');
      expect(ids.last, 'av_34');
      // 零填充：字典序 == 数值序（GridView 顺序依赖这一点）
      expect(ids, List<String>.from(ids)..sort());
    });

    test('pathOf 拼出资源路径；空 id 返回空串', () {
      expect(AvatarPresetService.pathOf('av_07'),
          'assets/images/avatars/av_07.webp');
      expect(AvatarPresetService.pathOf(''), isEmpty);
    });

    test('isValid 只认池内 id', () {
      expect(AvatarPresetService.isValid('av_01'), isTrue);
      expect(AvatarPresetService.isValid('av_99'), isFalse);
      expect(AvatarPresetService.isValid(''), isFalse);
    });
  });

  group('随机抽取', () {
    test('🔴 randomExcept 永远不返回 current（否则用户以为按钮坏了）', () {
      final current = AvatarPresetService.ids[3];
      for (var i = 0; i < 300; i++) {
        final picked = AvatarPresetService.randomExcept(current);
        expect(picked, isNot(current));
        expect(AvatarPresetService.isValid(picked), isTrue);
      }
    });

    test('current 为空/不在池内时仍返回池内 id', () {
      expect(AvatarPresetService.isValid(AvatarPresetService.randomExcept(null)),
          isTrue);
      expect(
          AvatarPresetService.isValid(
              AvatarPresetService.randomExcept('not_a_preset')),
          isTrue);
    });

    test('多次抽取能覆盖到多张（不是恒定同一张）', () {
      final seen = <String>{};
      for (var i = 0; i < 60; i++) {
        seen.add(AvatarPresetService.randomExcept(null));
      }
      expect(seen.length, greaterThan(5));
    });
  });

  group('Phase 0 探针（对真实 asset bundle）', () {
    test('P-01：AssetManifest 能列出 34 张头像', () async {
      final ids = await AvatarPresetService.ensureLoaded();
      expect(ids.length, 34,
          reason: '列出数量与 assets/images/avatars/ 实际文件数一致');
      expect(ids, contains('av_01'));
      expect(ids, contains('av_34'));
      // 缓存：第二次调用不再走 manifest
      expect(identical(await AvatarPresetService.ensureLoaded(), ids), isTrue);
    });

    test('P-02(部分)：能读到 webp 原始字节且魔数为 RIFF/WEBP', () async {
      final bytes = await AvatarPresetService.loadBytes('av_01');
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(1024));
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
    });

    test('loadBytes 对空 id / 不存在资源返回 null（不抛异常）', () async {
      expect(await AvatarPresetService.loadBytes(''), isNull);
      expect(await AvatarPresetService.loadBytes('av_does_not_exist'), isNull);
    });

    test('ensureLoaded 失败时回退常量表（模拟无 manifest 的 bundle）', () async {
      AvatarPresetService.resetCacheForTest();
      final ids =
          await AvatarPresetService.ensureLoaded(bundle: _EmptyBundle());
      expect(ids, AvatarPresetService.fallbackIds);
    });
  });
}

/// 模拟「拿不到 asset 清单」的 bundle，验证降级路径不抛异常。
class _EmptyBundle extends CachingAssetBundle {
  _EmptyBundle();

  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('asset not found: $key');
  }
}
