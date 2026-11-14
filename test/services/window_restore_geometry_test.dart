// 回归测试：恢复历史窗口几何的「可用性下限」（RESTORE-GEOM-FLOOR）。
//
// 事故背景（2026-10-25 真机）：便携版偏好里存了一条 1200×750 物理（= 960×600 逻辑）
// 的历史几何，`WindowGeometryService.restoreBeforeShow()` 每次都忠实还原，于是
// 「更新完打开软件窗口就是小的」，而开发构建因为偏好里没有这条记录，永远走默认
// 1280×720 —— 这正是用户看到的「测试正常、打包后就小」。
//
// 修复口径：`computeRestoreGeometry` 对历史尺寸只做上限（工作区）不做下限，导致
// 任何一次意外缩放都会被永久固化。本测试锁死「低于下限 ⇒ 尺寸回默认、位置照旧」。
//
// 真实数值取自事故机型：1920×1080 @125%（dpi 120）。

import 'package:chrono_tide/services/startup_window_size.dart';
import 'package:flutter_test/flutter_test.dart';

WorkAreaPhysical _work1920() => (
      left: 0,
      top: 0,
      width: 1920,
      height: 1080,
      dpi: 120,
    );

WorkAreaPhysical _workSmall() => (
      left: 0,
      top: 0,
      width: 1366,
      height: 728,
      dpi: 120,
    );

void main() {
  group('computeRestoreGeometry 可用性下限', () {
    test('事故复现：960×600 逻辑的历史几何必须回默认 1600×900', () {
      final geo = computeRestoreGeometry(
        saved: (left: 172, top: 167, width: 1200, height: 750),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo, isNotNull);
      expect(geo!.width, 1600);
      expect(geo.height, 900);
    });

    test('合法几何逐字节 round-trip（不因新增闸门而漂移）', () {
      final geo = computeRestoreGeometry(
        saved: (left: 160, top: 90, width: 1600, height: 900),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.width, 1600);
      expect(geo.height, 900);
      expect(geo.x, 160);
      expect(geo.y, 90);
    });

    // 🔴 2026-10-25 第二轮：下限已从 1120×620 抬到设计尺寸 1280×720
    // （= 默认尺寸），所以"恰好等于下限"与"回默认"结果相同 —— 该档改测
    // "大于下限原样保留"，另加一条"低于下限回默认"覆盖旧边界。
    test('大于下限要原样保留（1700×956 物理 = 1417×797 逻辑）', () {
      final geo = computeRestoreGeometry(
        saved: (left: 100, top: 100, width: 1700, height: 956),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.width, 1700);
      expect(geo.height, 956);
    });

    test('旧下限 1120×620 现在也低于下限，必须回默认', () {
      final geo = computeRestoreGeometry(
        saved: (left: 100, top: 100, width: 1400, height: 775),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.width, 1600);
      expect(geo.height, 900);
    });

    test('尺寸回默认时位置仍按历史相对中心恢复', () {
      final geo = computeRestoreGeometry(
        saved: (left: 400, top: 150, width: 1200, height: 750),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.x + geo.width ~/ 2, closeTo(1000, 2));
      expect(geo.y + geo.height ~/ 2, closeTo(525, 2));
    });

    test('放大后撞到工作区边界时钳制优先，窗口不得出屏', () {
      final geo = computeRestoreGeometry(
        saved: (left: 500, top: 300, width: 1200, height: 750),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.y, greaterThanOrEqualTo(0));
      expect(geo.y + geo.height, lessThanOrEqualTo(1080));
      expect(geo.x, greaterThanOrEqualTo(0));
      expect(geo.x + geo.width, lessThanOrEqualTo(1920));
    });

    test('小屏上下限被工作区钳制接管，不得把窗口撑出屏幕', () {
      final geo = computeRestoreGeometry(
        saved: (left: 40, top: 40, width: 1200, height: 750),
        savedDpi: 120,
        target: _workSmall(),
      );
      expect(geo!.x + geo.width, lessThanOrEqualTo(1366));
      expect(geo.y + geo.height, lessThanOrEqualTo(728));
    });

    test('保存时的屏已不在（无交集）→ 在目标屏居中', () {
      final geo = computeRestoreGeometry(
        saved: (left: 3000, top: 2000, width: 1600, height: 900),
        savedDpi: 120,
        target: _work1920(),
      );
      expect(geo!.x, (1920 - 1600) ~/ 2);
      expect(geo.y, (1080 - 900) ~/ 2);
    });

    test('非法输入返回 null', () {
      expect(
        computeRestoreGeometry(
          saved: (left: 0, top: 0, width: 0, height: 750),
          savedDpi: 120,
          target: _work1920(),
        ),
        isNull,
      );
      expect(
        computeRestoreGeometry(
          saved: (left: 0, top: 0, width: 1600, height: 900),
          savedDpi: 120,
          target: (left: 0, top: 0, width: 0, height: 0, dpi: 120),
        ),
        isNull,
      );
    });
  });
}
