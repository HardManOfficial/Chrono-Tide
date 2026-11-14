import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/portable_image_cache_manager.dart';
import 'nsfw/nsfw_image.dart';
import '../theme/app_colors.dart';

/// 添加页封面预览浮层（2026-10-05，详情窗封面管理浮层的轻量变体）。
///
/// 场景差异：添加页尚未入库（无 metaDataDir），封面是抓取结果的**网络 URL**
/// （竖版 cover_url + 横幅 banner_url）或用户已选的**本地图片**，因此本浮层
/// 默认只读：仅查看 + 竖/横/本地切换 + 拖拽缩放。
///
/// 2026-10-10 扩展：新增**可选**动作回调（[CoverPreviewOverlay.onUpload] /
/// [CoverPreviewOverlay.onSetCover] / [CoverPreviewOverlay.onDelete]）——
/// 添加页相册传入后即获得「上传导入 / 设为封面 / 删除」能力（与库详情统一），
/// 不传（如探索库详情预览）则行为与旧版逐字一致（只读）。
class CoverPreviewItem {
  /// 网络图片地址（与 [path] 二选一）
  final String url;

  /// 本地图片路径（与 [url] 二选一）
  final String path;

  final String label;

  const CoverPreviewItem({this.url = '', this.path = '', required this.label});

  bool get isLocal => path.isNotEmpty;

  bool get isEmpty => url.isEmpty && path.isEmpty;
}

class CoverPreviewOverlay extends StatefulWidget {
  final String gameTitle;
  final List<CoverPreviewItem> items;
  final int initialIndex;

  /// 上传本地图片（file_picker），返回成功新增数量；null = 不提供该能力
  final Future<int> Function()? onUpload;

  /// 把当前预览的候选图设为封面，返回是否成功；null = 不提供该能力
  final Future<bool> Function(CoverPreviewItem item)? onSetCover;

  /// 删除/清除当前封面，返回是否成功；null = 不提供该能力
  final Future<bool> Function()? onDelete;

  /// 动作执行后重新取候选清单（默认复用 [items]）；null 时不做刷新
  final List<CoverPreviewItem> Function()? itemsProvider;

  const CoverPreviewOverlay({
    super.key,
    required this.gameTitle,
    required this.items,
    this.initialIndex = 0,
    this.onUpload,
    this.onSetCover,
    this.onDelete,
    this.itemsProvider,
  });

  @override
  State<CoverPreviewOverlay> createState() => _CoverPreviewOverlayState();
}

class _CoverPreviewOverlayState extends State<CoverPreviewOverlay> {
  static const double _minScale = 0.5;
  static const double _maxScale = 5.0;

  /// 图片默认显示尺寸 = 视口 × 此系数（2026-10-05，与封面管理浮层同口径：
  /// 横幅/竖图都不要默认贴满全窗口，缩小居中、四周留磨砂；看大图用缩放按钮）
  static const double _contentScale = 0.7;

  final TransformationController _tc = TransformationController();
  late List<CoverPreviewItem> _items;
  late int _index;
  Size _viewSize = Size.zero;

  /// 忙碌标记：'' | 'upload' | 'set' | 'delete'
  String _busy = '';

  /// 是否提供了任一动作能力（决定工具条是否显示动作组）
  bool get _hasActions =>
      widget.onUpload != null ||
      widget.onSetCover != null ||
      widget.onDelete != null;

  CoverPreviewItem? get _current =>
      _items.isEmpty ? null : _items[_index.clamp(0, _items.length - 1)];

  @override
  void initState() {
    super.initState();
    _items = List<CoverPreviewItem>.of(widget.items);
    _index = _items.isEmpty ? 0 : widget.initialIndex.clamp(0, _items.length - 1);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  /// 动作后重取候选（[itemsProvider] 优先，否则沿用构造传入的 items）
  void _refresh() {
    final next = widget.itemsProvider?.call() ?? widget.items;
    if (!mounted) return;
    setState(() {
      _items = List<CoverPreviewItem>.of(next);
      if (_index >= _items.length) _index = 0;
      _tc.value = Matrix4.identity();
    });
  }

  Future<void> _handleUpload() async {
    final cb = widget.onUpload;
    if (cb == null || _busy.isNotEmpty) return;
    setState(() => _busy = 'upload');
    try {
      final n = await cb();
      if (n > 0) _refresh();
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _handleSetCover() async {
    final cb = widget.onSetCover;
    final cur = _current;
    if (cb == null || cur == null || _busy.isNotEmpty) return;
    setState(() => _busy = 'set');
    try {
      final ok = await cb(cur);
      if (ok) _refresh();
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _handleDelete() async {
    final cb = widget.onDelete;
    if (cb == null || _busy.isNotEmpty) return;
    setState(() => _busy = 'delete');
    try {
      final ok = await cb();
      if (ok) _refresh();
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  void _go(int delta) {
    if (_items.length < 2) return;
    setState(() {
      _index = (_index + delta + _items.length) % _items.length;
      _tc.value = Matrix4.identity();
    });
  }

  void _resetView() => _tc.value = Matrix4.identity();


  /// 以视口中心为锚点缩放（仅预览）
  void _zoom(double factor) {
    final current = _tc.value;
    final scale = current.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final newScale = (scale * factor).clamp(_minScale, _maxScale);
    final eff = newScale / scale;
    final cx = _viewSize.width / 2;
    final cy = _viewSize.height / 2;
    final anchor = Matrix4.identity()
      ..translate(cx, cy)
      ..scale(eff)
      ..translate(-cx, -cy);
    _tc.value = anchor.multiplied(current);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark;
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (_items.length >= 2) ...{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _go(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _go(1),
            },
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: _close,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: isDark
                        ? Colors.black.withOpacity(0.50)
                        : Colors.black.withOpacity(0.35),
                  ),
                ),
              ),
              // 图片区：全窗口自由拖拽 + 缩放
              // 🔴 必须排在顶栏/工具条**之前**（2026-10-05 修复，同
              //    CoverGalleryOverlay）：原先排在顶栏之后，InteractiveViewer
              //    全窗口吞掉指针事件，右上角关闭按钮永远点不到 → 无法退出
              Positioned.fill(child: _buildViewer()),
              Positioned(
                top: 16,
                left: 20,
                right: 16,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.gameTitle} - 封面预览',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _close,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.9),
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 18, color: Colors.black87),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: _buildToolbar(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final item = _current;
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: _minScale,
                maxScale: _maxScale,
                panEnabled: true,
                child: Center(
                  child: item == null
                      ? Text(
                          _hasActions
                              ? '暂无封面图\n可点下方「上传导入」添加本地图片'
                              : '暂无封面图\n先在左侧选择一个抓取结果',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              height: 1.6),
                        )
                      : ConstrainedBox(
                          // 2026-10-05：默认显示框压到视口 × _contentScale，
                          // 横幅/竖图都居中缩小，不再贴满全窗口
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * _contentScale,
                            maxHeight: constraints.maxHeight * _contentScale,
                          ),
                          child: GestureDetector(
                            onDoubleTap: _resetView,
                            child: item.isLocal
                                // 本地图片（用户已选封面 / 上传导入）
                                ? NsfwImage.file(
                                    item.path,
                                    contentKind: NsfwContentKind.cover,
                                    fit: BoxFit.contain,
                                    decodeWidth: 1600,
                                    child: Image.file(
                                      File(item.path),
                                      fit: BoxFit.contain,
                                      cacheWidth: 1600,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.broken_image_outlined,
                                        size: 48,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  )
                                : NsfwImage.network(
                                    item.url,
                                    contentKind: NsfwContentKind.cover,
                                    detectOnDemand: true,
                                    child: CachedNetworkImage(
                                      cacheManager:
                                          PortableImageCacheManager(),
                                      imageUrl: item.url,
                                      fit: BoxFit.contain,
                                      placeholder: (context, url) =>
                                          const Center(
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          const Icon(
                                        Icons.broken_image_outlined,
                                        size: 48,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                ),
              ),
            ),
            if (item != null)
              Positioned(
                // 2026-10-05 下移避让顶栏标题（图片层已改到顶栏之下）
                top: 56,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    _items.length > 1
                        ? '${item.label} · ${_index + 1}/${_items.length}'
                        : item.label,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white24, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolButton(
                  icon: Icons.zoom_out_rounded,
                  tip: '缩小预览',
                  onTap: () => _zoom(1 / 1.25)),
              _toolButton(
                  icon: Icons.zoom_in_rounded,
                  tip: '放大预览',
                  onTap: () => _zoom(1.25)),
              _toolButton(
                icon: Icons.chevron_left_rounded,
                tip: '上一张',
                onTap: _items.length >= 2 ? () => _go(-1) : null,
              ),
              _toolButton(
                  icon: Icons.center_focus_strong_rounded,
                  tip: '恢复初始居中',
                  onTap: _resetView),
              _toolButton(
                icon: Icons.chevron_right_rounded,
                tip: '下一张',
                onTap: _items.length >= 2 ? () => _go(1) : null,
              ),
              // ── 动作组（仅添加页传入回调时出现；探索库详情预览不显示）──
              if (_hasActions) ...[
                const SizedBox(width: 4),
                Container(width: 1, height: 20, color: Colors.white24),
                const SizedBox(width: 4),
                if (widget.onSetCover != null)
                  _toolButton(
                    icon: Icons.check_circle_outline_rounded,
                    tip: _current == null
                        ? '设为封面（无选中图）'
                        : '把当前图设为添加到游戏的封面',
                    busy: _busy == 'set',
                    onTap: _current == null ? null : _handleSetCover,
                  ),
                if (widget.onUpload != null)
                  _toolButton(
                    icon: Icons.add_photo_alternate_outlined,
                    tip: '上传导入本地图片并设为封面',
                    busy: _busy == 'upload',
                    onTap: _handleUpload,
                  ),
                if (widget.onDelete != null)
                  _toolButton(
                    icon: Icons.delete_outline_rounded,
                    tip: '删除当前封面',
                    busy: _busy == 'delete',
                    onTap: _handleDelete,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
    bool busy = false,
  }) {
    // 全局忙碌时统一禁用（与 CoverGalleryOverlay 同口径），避免并发动作
    final enabled = onTap != null && _busy.isEmpty;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon,
                    size: 20, color: enabled ? Colors.white : Colors.white30),
          ),
        ),
      ),
    );
  }
}
