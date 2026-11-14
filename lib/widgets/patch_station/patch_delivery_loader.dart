import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/patch_resource.dart';
import '../../services/patch/patch_delivery_service.dart';
import '../../services/patch/patch_download_service.dart';
import '../../services/patch/sources/two_dfan_account_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../app_snack_bar.dart';
import '../game_detail/dark_surface.dart';
import 'patch_download_details.dart';

/// 展开位里的「投递详情加载器」：把 [PatchDeliveryService] 接进 UI。
///
/// ## 为什么不把解析塞进面板 State
///
/// 浅色横条的展开位（[PatchExpandedCard]）与深色详情栏（`_PatchRow`）是两套
/// 完全独立的布局，但**要显示的东西一模一样**。若各自在面板 State 里维护
/// 「正在解析哪一条」，就会出现两份并发去重、两份错误处理、两份兑换后回填。
/// ⇒ 收到这个组件里，两个面板只负责「谁来下载」这一件事。
///
/// ## 按需解析的口径（🔴 别改成检索期预取）
///
/// - **鲲 / 社区**：检索阶段已经把 `links` 抓全了，这里同步直出，**零请求**。
/// - **2DFan**：只有展开这一刻才抓 `/downloads/{id}`（价格、余额、兑换端点
///   都在这个页面上）。检索期逐条抓 = 一次搜索几十个请求，站点会限流。
///
/// 缓存与并发去重由 [PatchDeliveryService] 负责，本组件只持有一条结果。
///
/// ## 兑换（唯一会花用户钱的动作）
///
/// 组件**自己弹确认框**（因为价格就显示在这里，交给面板弹反而要再把价格
/// 传一遍）。确认后才调 [TwoDFanAccountService.purchase]，并且：
/// - 价格、余额、登录态由 service 在 POST 前**重新复核**，不一致就中止；
/// - `uncertain`（请求发出但没拿到确认）⇒ 只提示「去网页核对」，
///   ⛔ 不给「重试」按钮 —— 重试可能导致重复扣分。
class PatchDeliveryLoader extends StatefulWidget {
  const PatchDeliveryLoader({
    super.key,
    required this.resource,
    this.detail,
    this.onDark = false,
    this.dense = false,
    this.download,
    this.onDownloadDirect,
    this.onCancel,
    this.autoResolve = true,
  });

  final PatchResource resource;

  /// 已有详情（探针注入 / 父级缓存命中）；非空时**不再发请求**
  final PatchDeliveryDetail? detail;

  final bool onDark;
  final bool dense;

  final PatchDownloadState? download;

  /// 软件内下载：**必须传实际直链** —— 2DFan 的直链是兑换后才出现的，
  /// 模型里的 `directUrl` 永远是空的，所以不能只传一个无参回调。
  final Future<void> Function(String url)? onDownloadDirect;

  final VoidCallback? onCancel;

  /// false ⇒ 不自动解析（探针用；面板里恒为 true）
  final bool autoResolve;

  @override
  State<PatchDeliveryLoader> createState() => _PatchDeliveryLoaderState();
}

class _PatchDeliveryLoaderState extends State<PatchDeliveryLoader> {
  PatchDeliveryDetail? _detail;
  bool _loading = false;
  bool _redeeming = false;

  /// 竞态闸：快速收起/展开另一条时，旧请求回来不能覆盖新条目
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _detail = widget.detail;
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant PatchDeliveryLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resource.key != widget.resource.key) {
      _detail = widget.detail;
      _reqId++; // 让在途请求作废
      _loading = false;
      _bootstrap();
      return;
    }
    if (widget.detail != null && widget.detail != _detail) {
      _detail = widget.detail;
    }
  }

  void _bootstrap() {
    if (!widget.autoResolve) {
      _detail ??= _fallback();
      return;
    }
    if (_detail != null) return;
    // 🔴 只有 2DFan 需要抓页面；其余来源模型里已经有全部入口
    if (widget.resource.site != PatchSite.twoDfan) {
      _detail = _fallback();
      return;
    }
    _load(silentStart: true);
  }

  PatchDeliveryDetail _fallback() =>
      PatchDeliveryDetail.fromResource(widget.resource);

  /// [silentStart] 供 initState 使用：首帧还没 build，直接改字段即可
  /// （⛔ 在 initState 里 setState 是踩点行为）。
  Future<void> _load({bool force = false, bool silentStart = false}) async {
    final id = ++_reqId;
    if (silentStart) {
      _loading = true;
    } else if (mounted) {
      setState(() => _loading = true);
    }
    PatchDeliveryDetail d;
    try {
      d = await PatchDeliveryService.instance.resolve(
        widget.resource,
        force: force,
      );
    } catch (e) {
      d = _fallback().copyWith(
        error: '读取失败：$e',
        reason: '暂时读不到下载方式，可以先打开原页',
      );
    }
    if (!mounted || id != _reqId) return;
    setState(() {
      _detail = d;
      _loading = false;
    });
  }

  /// `https://2dfmax.top/downloads/123` → `2dfmax.top`
  static String? _hostOf(String url) {
    final host = Uri.tryParse(url.trim())?.host ?? '';
    return host.isEmpty ? null : host;
  }

  // ==================== 兑换 ====================

  Future<void> _redeem() async {
    final d = _detail;
    final price = d?.price;
    if (d == null || price == null || _redeeming) return;

    final agree = await _confirmRedeem(d);
    if (agree != true || !mounted) return;

    setState(() => _redeeming = true);
    FanPurchaseResult result;
    try {
      // 与详情解析用**同一个镜像**：Cookie 按域名生效，换域名就等于没登录
      result = await TwoDFanAccountService.instance.purchase(
        widget.resource.id,
        confirmedPrice: price,
        baseOverride: _hostOf(widget.resource.webUrl),
      );
    } catch (e) {
      result = FanPurchaseResult(
        outcome: FanPurchaseOutcome.failed,
        message: '兑换失败：$e',
      );
    }
    if (!mounted) return;
    setState(() => _redeeming = false);

    // 拿回新 plan 就直接回填（省一次抓取，且余额已是扣后的值）
    final plan = result.plan;
    if (plan != null) {
      final next = PatchDeliveryDetail.fromFanPlan(widget.resource, plan);
      PatchDeliveryService.instance.put(widget.resource.key, next);
      if (mounted) {
        setState(() {
          _detail = next;
          _loading = false;
        });
      }
    } else {
      // 失败/不确定：刷新一次让价格与余额回到真实值
      unawaited(_load(force: true));
    }
    if (!mounted) return;

    switch (result.outcome) {
      case FanPurchaseOutcome.purchased:
        AppSnackBar.success(context, '兑换成功，开始下载');
        break;
      case FanPurchaseOutcome.alreadyAvailable:
        AppSnackBar.info(context, '站点已给出下载链接，本次没有扣积分');
        break;
      case FanPurchaseOutcome.failed:
        AppSnackBar.error(context, result.message);
        break;
      case FanPurchaseOutcome.uncertain:
        // 🔴 可能已扣分 ⇒ 只提示核对，绝不自动重试
        AppSnackBar.warning(
          context,
          '${result.message}（结果不确定：请先到网页端核对积分，不要直接重试）',
          duration: const Duration(seconds: 20),
        );
        break;
    }

    if (result.isSuccess) {
      final url = (plan?.fileUrl ?? _detail?.primaryDirectUrl ?? '').trim();
      final cb = widget.onDownloadDirect;
      if (url.isNotEmpty && cb != null) {
        await cb(url);
      }
    }
  }

  /// 兑换二次确认。**必须显示价格与余额**，否则用户是在盲扣积分。
  Future<bool?> _confirmRedeem(PatchDeliveryDetail d) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _RedeemConfirmDialog(
        resource: widget.resource,
        price: d.price ?? 0,
        balance: d.balance,
        accountSummary: d.accountSummary,
      ),
    );
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    // 2DFan 首帧：还没拿到页面 ⇒ 别急着显示「需要在站点下载」这种误导文案
    if (d == null) {
      return _loadingRow();
    }

    final direct = d.primaryDirectUrl;
    final cb = widget.onDownloadDirect;
    final canDownload = direct != null && cb != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (d.error != null && d.links.isNotEmpty) ...[
          _errorLine(d.error!),
          SizedBox(height: widget.dense ? 8 : 10),
        ],
        if (_loading && d.links.isEmpty)
          _loadingRow()
        else
          PatchDownloadDetails(
            resource: widget.resource,
            detail: d,
            onDark: widget.onDark,
            dense: widget.dense,
            download: widget.download,
            onDownload: canDownload ? () => cb(direct) : null,
            onCancel: widget.onCancel,
            onRedeem: d.canPurchase ? _redeem : null,
            onRefresh: () => _load(force: true),
            redeeming: _redeeming,
          ),
      ],
    );
  }

  /// 首帧 / 重新抓取中的占位。⛔ 不显示任何「没有下载方式」的结论性文案。
  Widget _loadingRow() {
    final dim = widget.onDark ? DarkPalette.textDim : AppColors.secondaryText;
    final border =
        widget.onDark ? DarkPalette.cardBorder : AppColors.border.withOpacity(0.7);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: widget.onDark ? 0.6 : 1),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation<Color>(dim),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '正在读取下载方式…',
            style: AppStyles.bodyRegular.copyWith(fontSize: 10.5, color: dim),
          ),
        ],
      ),
    );
  }

  /// 有线可下但整页解析失败时的一行提示（有网的条目不该被一条错误整块替换）
  Widget _errorLine(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded,
            size: 12,
            color: widget.onDark ? DarkPalette.yellow : AppColors.dangerRed),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 10,
              height: 1.4,
              color: widget.onDark ? DarkPalette.textDim : AppColors.secondaryText,
            ),
          ),
        ),
      ],
    );
  }
}

/// 「用积分兑换」的二次确认。
///
/// 🔴 这段文案是本功能的**知情同意书**，改之前想清楚：
/// 兑换后积分立即扣除、站点不退款，⛔ 不提供「撤销」。
class _RedeemConfirmDialog extends StatelessWidget {
  const _RedeemConfirmDialog({
    required this.resource,
    required this.price,
    required this.balance,
    required this.accountSummary,
  });

  final PatchResource resource;
  final int price;
  final int? balance;
  final String accountSummary;

  @override
  Widget build(BuildContext context) {
    final enough = balance != null && balance! >= price;
    final String priceText = price == 0 ? '免费（站点仍需走一次兑换）' : '$price 积分';
    final String balanceText =
        balance == null ? '未能读取' : '$balance 积分';

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 420,
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border, width: 1.4),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: AppColors.border.withOpacity(0.28),
                offset: const Offset(4, 6),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                height: 50,
                color: AppColors.buttonBackground,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(Icons.redeem_rounded,
                        size: 17, color: AppColors.secondaryText),
                    const SizedBox(width: 9),
                    Text(
                      '确认用积分兑换',
                      style: AppStyles.bodyRegular.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      resource.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppStyles.bodyRegular.copyWith(
                        fontSize: 12.5,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText,
                      ),
                    ),
                    if (accountSummary.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        accountSummary,
                        style: AppStyles.bodyRegular.copyWith(
                          fontSize: 10.5,
                          color: AppColors.secondaryText,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(child: _tile('本次扣除', priceText)),
                        const SizedBox(width: 10),
                        Expanded(child: _tile('当前积分', balanceText)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      enough
                          ? '兑换会立即扣除积分，站点侧不支持撤销。兑换成功后软件会直接开始下载。'
                          : '积分不足，无法兑换。可以先用网盘载点，或到站点补充积分。',
                      style: AppStyles.bodyRegular.copyWith(
                        fontSize: 10.5,
                        height: 1.55,
                        color: enough
                            ? AppColors.secondaryText
                            : AppColors.dangerRed,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _btn(
                      context,
                      label: '取消',
                      filled: false,
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                    const SizedBox(width: 8),
                    _btn(
                      context,
                      label: enough ? '确认兑换 $price 积分' : '积分不足',
                      filled: true,
                      onTap: enough
                          ? () => Navigator.of(context).pop(true)
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(String label, String value) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: AppColors.buttonBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 10,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: AppStyles.bodyRegular.copyWith(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(
    BuildContext context, {
    required String label,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    final active = onTap != null;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.45,
          duration: const Duration(milliseconds: 140),
          child: Container(
            height: 29,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: filled
                  ? (active ? AppColors.accentCyan : Colors.transparent)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: filled && active
                    ? AppColors.accentCyan
                    : AppColors.border,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: AppStyles.bodyRegular.copyWith(
                fontSize: 11.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                color: filled && active
                    ? AppColors.onAccentSolid
                    : (active ? AppColors.primaryText : AppColors.secondaryText),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
