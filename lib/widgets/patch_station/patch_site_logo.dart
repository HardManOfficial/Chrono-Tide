import 'package:flutter/material.dart';

import '../../models/patch_resource.dart';
import '../../theme/app_colors.dart';

/// 补丁站站点图标（官方素材优先 / 几何 painter 兜底）。
///
/// ## 取图顺序
///
/// 1. **官方素材**：[assetPathOf] 有值 ⇒ 用 `assets/patch_sites/` 下的原图
///    （`Image.asset` + 圆角裁切，视觉上等同 App 图标）。
/// 2. **兜底**：没有素材（社区站）或素材加载失败 ⇒ [CustomPainter] 画几何近似标记。
///
/// | 站点 | 素材 | 兜底图形 |
/// |---|---|---|
/// | 2DFan | `two_dfan.png`（官方 favicon 32×32 饭团脸） | 饭团（三角轮廓 + 海苔带） |
/// | 鲲 | `kunlun.webp`（官方 favicon 256×256） | 鱼（椭圆身 + 三角尾 + 镂空眼） |
/// | 社区 | 无 | 对话气泡 |
///
/// 🔴 **换图只换文件，不许改代码**：把同名同格式的高清图覆盖进
/// `assets/patch_sites/` 即可；若换成别的格式（png/webp 互换），
/// 只需同步改 [assetPathOf] 里的扩展名。⛔ 不要在这里写死路径字符串。
///
/// 🔴 `CustomPainter.paint()` 抛异常会被**静默吞帧**（见 MEMORY「UI 布局坑」），
/// 所以本文件所有绘制都有尺寸守卫，并且探针里逐尺寸验证过无异常。
class PatchSiteLogo extends StatelessWidget {
  const PatchSiteLogo({
    super.key,
    required this.site,
    this.size = 18,
    this.onDark,
  });

  final PatchSite site;
  final double size;

  /// 强制按「深色底」取色。
  ///
  /// 详情页锚定栏（`patch_station_dark_panel`）里是**恒深色**的（与资源分享窗同一套
  /// `DarkPalette`），它不跟随主题 ⇒ 必须显式传 true，否则浅色主题下
  /// 会算出近黑的饭团色，在深色浮层里直接看不见。
  ///
  /// ⚠️ 只影响 painter 兜底；官方素材是固定配色，不受主题影响。
  final bool? onDark;

  /// 官方素材路径；`null` ⇒ 该站没有素材，走 painter。
  static String? assetPathOf(PatchSite site) {
    switch (site) {
      case PatchSite.kunlun:
        return 'assets/patch_sites/kunlun.webp';
      case PatchSite.twoDfan:
        return 'assets/patch_sites/two_dfan.png';
      case PatchSite.community:
        return null;
    }
  }

  /// 站点主色（painter 兜底用）。
  ///
  /// 2DFan 原色是纯黑饭团，深色底下会「消失」⇒ 深色档改用浅灰，
  /// 保留「黑白饭团」观感又不会看不见。
  static Color colorOf(PatchSite site, {bool? onDark}) {
    final dark = onDark ?? AppColors.isDark;
    switch (site) {
      case PatchSite.kunlun:
        return const Color(0xFF2E7BE6);
      case PatchSite.twoDfan:
        return dark ? const Color(0xFFDFDFE6) : const Color(0xFF2B2B31);
      case PatchSite.community:
        return const Color(0xFF2FA36B);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = size.isFinite && size > 0 ? size : 18.0;
    final asset = assetPathOf(site);
    if (asset == null) return _painted(s);

    // 圆角 28% ≈ App 图标观感；`errorBuilder` 保证素材缺失/解码失败时
    // 静默退回 painter，⛔ 不抛红屏（探针里 flutter_tester 无 assetBundle）。
    return SizedBox(
      width: s,
      height: s,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(s * 0.28),
        child: Image.asset(
          asset,
          width: s,
          height: s,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _painted(s),
        ),
      ),
    );
  }

  Widget _painted(double s) => SizedBox(
        width: s,
        height: s,
        child: CustomPaint(
          painter: _SiteMarkPainter(site, colorOf(site, onDark: onDark)),
        ),
      );
}

class _SiteMarkPainter extends CustomPainter {
  _SiteMarkPainter(this.site, this.color);

  final PatchSite site;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return;

    // 底板：淡色圆角方块，让图标在任何卡片底色上都有边界
    final tile = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      Radius.circular(w * 0.28),
    );
    canvas.drawRRect(tile, Paint()..color = color.withOpacity(0.14));

    // 内缩 24% 作为标记绘制区
    final r = Rect.fromLTWH(w * 0.24, h * 0.24, w * 0.52, h * 0.52);
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (w * 0.10).clamp(0.8, 3.0)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    switch (site) {
      case PatchSite.twoDfan:
        _paintOnigiri(canvas, r, fill, stroke);
        break;
      case PatchSite.kunlun:
        _paintFish(canvas, r, fill);
        break;
      case PatchSite.community:
        _paintBubble(canvas, r, fill);
        break;
    }
  }

  /// 饭团（2DFan）：**实心**圆角三角 + 底部海苔带。
  ///
  /// 🔴 v5 修的是「看起来像警告三角」：v4 用的是「细描边空心三角」，
  /// 13px 下就是 `⚠`。改成两块实心 + 双色（米身浅、海苔深）之后，
  /// 小尺寸也能认出是饭团。
  void _paintOnigiri(Canvas canvas, Rect r, Paint fill, Paint stroke) {
    // 圆角三角：三个角用二次贝塞尔收圆，比「大线宽 + round join」更可控
    final cx = r.center.dx;
    final top = r.top;
    final bottom = r.bottom;
    final left = r.left;
    final right = r.right;
    final k = r.width * 0.20; // 圆角半径

    final tri = Path()
      ..moveTo(cx, top)
      ..quadraticBezierTo(cx + k * 0.55, top + k * 0.30, cx + k, top + k * 1.05)
      ..lineTo(right - k * 0.35, bottom - k * 0.25)
      ..quadraticBezierTo(right, bottom, right - k, bottom)
      ..lineTo(left + k, bottom)
      ..quadraticBezierTo(left, bottom, left + k * 0.35, bottom - k * 0.25)
      ..lineTo(cx - k, top + k * 1.05)
      ..quadraticBezierTo(cx - k * 0.55, top + k * 0.30, cx, top)
      ..close();

    // 米身：同色降透明度 ⇒ 与海苔形成层次，又不引入第二个色相
    canvas.drawPath(
      tri,
      Paint()..color = stroke.color.withOpacity(0.55),
    );

    // 海苔：横跨底部的一条，裁进三角内（⛔ 不越出轮廓，否则像贴纸）
    canvas.save();
    canvas.clipPath(tri);
    final nori = Rect.fromLTWH(
      cx - r.width * 0.26,
      bottom - r.height * 0.34,
      r.width * 0.52,
      r.height * 0.34,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(nori, Radius.circular(r.width * 0.05)),
      fill,
    );
    canvas.restore();
  }

  /// 鲲：鱼身（椭圆）+ 尾鳍 + 挖空眼 + 高光背鳍
  void _paintFish(Canvas canvas, Rect r, Paint fill) {
    final body = Rect.fromLTWH(
      r.left,
      r.top + r.height * 0.16,
      r.width * 0.74,
      r.height * 0.68,
    );

    // 尾巴：从左往右张开的三角（贴住身体右缘，避免出现缝隙）
    final tail = Path()
      ..moveTo(body.right - r.width * 0.04, body.center.dy)
      ..lineTo(r.right, r.top + r.height * 0.02)
      ..quadraticBezierTo(
          r.right - r.width * 0.06, body.center.dy, r.right, r.bottom)
      ..close();

    final merged = Path.combine(
      PathOperation.union,
      Path()..addOval(body),
      tail,
    );

    // 眼睛：抠掉一个圆（difference 在 Skia 里比「先画白点」更稳，不挑底色）
    final eye = Path()
      ..addOval(Rect.fromCircle(
        center: Offset(body.left + body.width * 0.26, body.center.dy),
        radius: (r.width * 0.10).clamp(0.7, 2.6),
      ));
    canvas.drawPath(Path.combine(PathOperation.difference, merged, eye), fill);

    // 背鳍：一条小三角，让轮廓不像「鸡蛋」
    canvas.drawPath(
      Path()
        ..moveTo(body.left + body.width * 0.34, body.top + r.height * 0.02)
        ..lineTo(body.left + body.width * 0.52, r.top)
        ..lineTo(body.left + body.width * 0.62, body.top + r.height * 0.06)
        ..close(),
      fill,
    );
  }

  /// 社区：圆角气泡 + 左下小尾巴
  void _paintBubble(Canvas canvas, Rect r, Paint fill) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(r.left, r.top, r.width, r.height * 0.70),
        Radius.circular(r.width * 0.24),
      ),
      fill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(r.left + r.width * 0.26, r.top + r.height * 0.68)
        ..lineTo(r.left + r.width * 0.22, r.bottom)
        ..lineTo(r.left + r.width * 0.56, r.top + r.height * 0.68)
        ..close(),
      fill,
    );
  }

  @override
  bool shouldRepaint(_SiteMarkPainter old) =>
      old.site != site || old.color != color;
}
