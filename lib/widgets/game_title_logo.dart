import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 游戏大标题位：**有标题图（透明 logo）就贴图，没有就退回文字标题**。
///
/// ## 为什么需要这一层
/// 「大标题」有两种形态（Playnite 同款）：① 加粗加大的文字；② 厂商绘制的
/// 艺术字 logo（透明背景，如 `AOKANA -Four Rhythms Across the Blue-`）。
/// 后者不是"把字渲染得更大"，而是一张独立素材。本 widget 只负责**展示**，
/// 取图由 `GameTitleLogoService` 负责。
///
/// ## 展示要点（这些参数不是随手写的）
/// - **统一高度、宽度自适应**：不同游戏的 logo 画布形状差异很大（实测裁掉
///   透明边后 AOKANA 480×124、CLANNAD 262×124），只有固定高度才能让左右
///   两屏的视觉重量一致；[maxWidth] 只是防超长 logo 溢出的安全上限。
/// - **八向描边**：Steam 的标题图绝大多数是**白色字 + 透明底**。
///   直接贴只有两种情况翻车：浅色背景（桌面主页浅色主题）上白字对比度
///   接近 1:1，等于消失；深色底上遇到亮画面（雪景/白天空）同样糊。
///   实测对比（`.workbuddy/probe_game_logo/preview/light_surface_variants.png`）：
///   45% 剪影 + blur 仍然看不清，**八向 2px 实心描边**最清楚且保留原图配色，
///   所以在原图下面垫 8 个平移的纯色剪影当"印刷描边"。
/// - **深色底额外加一层柔和投影**：对应改造前文字的 `heroTextShadow`，
///   让 logo 从 backdrop 上"浮"起来；浅色底不需要，否则边缘会发脏。
/// - **回退必须零成本**：无图 / 文件丢失（`errorBuilder`）都直接返回
///   [fallback]，与改造前的渲染完全一致，不产生任何额外布局差异。
class GameTitleLogo extends StatelessWidget {
  const GameTitleLogo({
    super.key,
    required this.logoPath,
    required this.fallback,
    required this.maxWidth,
    required this.maxHeight,
    this.onLightSurface = false,
  });

  /// 标题图本地绝对路径；空串 = 无标题图。
  final String logoPath;

  /// 无标题图 / 加载失败时的文字标题（调用方原样传入现有 widget）。
  final Widget fallback;

  final double maxWidth;
  final double maxHeight;

  /// 背景是否为浅色（桌面主页跟随主题）。决定描边浓度与是否加投影。
  final bool onLightSurface;

  /// 描边半径（逻辑像素）。2px 在 60~124 的显示高度上都成立，
  /// 不随图片缩放变化 —— 平移的是画布坐标，与图片缩放无关。
  static const double _strokeRadius = 2.0;

  /// 八向偏移：上下左右 + 四个对角，保证描边均匀无缺口。
  static const List<Offset> _strokeOffsets = [
    Offset(-_strokeRadius, 0),
    Offset(_strokeRadius, 0),
    Offset(0, -_strokeRadius),
    Offset(0, _strokeRadius),
    Offset(-_strokeRadius, -_strokeRadius),
    Offset(_strokeRadius, _strokeRadius),
    Offset(-_strokeRadius, _strokeRadius),
    Offset(_strokeRadius, -_strokeRadius),
  ];

  @override
  Widget build(BuildContext context) {
    if (logoPath.isEmpty) return fallback;

    // 每次 build 新建 Image，但 FileImage 按 (path, scale) 相等，
    // 全部命中 ImageCache —— 不会重复解码。
    Widget image({bool isTop = false}) => Image.file(
          File(logoPath),
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          filterQuality: FilterQuality.high,
          // 快速翻页时不闪白
          gaplessPlayback: true,
          errorBuilder: isTop
              ? (_, __, ___) => fallback
              : (_, __, ___) => const SizedBox.shrink(),
        );

    // 浅底用更实的描边（要压住白底），深底略淡（避免边缘出现黑边感）
    final strokeColor = onLightSurface
        ? const Color(0xE6000000) // 90% 黑
        : const Color(0xB3000000); // 70% 黑

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
      child: Stack(
        // 描边会溢出 Stack 边界，交给父级自然裁切（两处调用点都有边距）
        clipBehavior: Clip.none,
        children: [
          // 柔和投影（仅深色底）：压住亮画面，让 logo 从 backdrop 上浮起来
          if (!onLightSurface)
            IgnorePointer(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Transform.translate(
                  offset: const Offset(0, 4),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(
                        const Color(0x8C000000), BlendMode.srcIn),
                    child: image(),
                  ),
                ),
              ),
            ),
          // 八向描边
          for (final offset in _strokeOffsets)
            IgnorePointer(
              child: Transform.translate(
                offset: offset,
                child: ColorFiltered(
                  colorFilter:
                      ColorFilter.mode(strokeColor, BlendMode.srcIn),
                  child: image(),
                ),
              ),
            ),
          image(isTop: true),
        ],
      ),
    );
  }
}
