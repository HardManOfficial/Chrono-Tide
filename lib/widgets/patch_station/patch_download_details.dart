import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/patch_resource.dart';
import '../../services/patch/patch_delivery_service.dart';
import '../../services/patch/patch_download_service.dart';
import '../../services/website_bookmark_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_styles.dart';
import '../game_detail/dark_surface.dart';

/// 「查看下载」的**内容本体**（不含任何窗口外壳）。
///
/// ## 为什么不再弹窗
///
/// v4 时「查看下载」会另开一个居中浮层，用户的面评是：明明就在卡片上点的，
/// 为什么要另开一个窗、还压在面板下面？v5 改成**卡片原地展开**把这块塞进
/// 展开位，因此这里只留内容，外壳交给调用方（浅色横条 / 深色详情栏）。
///
/// ## 三条投递路径怎么落
///
/// | delivery | 信息块 | 主按钮 |
/// |---|---|---|
/// | `direct` | **每个**直链一行 + 大小 + 下载后去向 | 下载到本地（→ 下载确认框） |
/// | `netdisk` | **每个**网盘一行：服务商 + 链接 + 提取码 | 复制链接与提取码 |
/// | `web` | 只能去原站；2DFan 另给积分账与兑换入口 | 打开资源页 |
///
/// 🔴 **「每一个」是关键**：一个资源页经常挂多个网盘（网盘载点1/2）或
/// 「直链 + 网盘」并存。旧实现在解析阶段只保留第一个，用户看不到其余入口，
/// 只能回原页翻 —— 现在 [PatchDeliveryDetail.links] 全量上屏。
///
/// 🔴 2DFan 的积分账要么是真数字（已登录且页面给了价格/余额），要么如实写
/// 「登录后可见」。⛔ 不编假数值，也⛔ 不在未知价格下允许兑换。
///
/// 🔴 补丁站只下载不安装 ⇒ 这里没有任何「应用 / 安装 / 覆盖」动作。
class PatchDownloadDetails extends StatelessWidget {
  const PatchDownloadDetails({
    super.key,
    required this.resource,
    this.detail,
    this.onDark = false,
    this.download,
    this.onDownload,
    this.onCancel,
    this.onRedeem,
    this.onRefresh,
    this.redeeming = false,
    this.dense = false,
  });

  final PatchResource resource;

  /// 按需解析出来的投递详情（展开时异步加载）。
  ///
  /// 为 null 表示「还没开始解析 / 调用方不用解析」—— 此时退回
  /// [PatchDeliveryDetail.fromResource]，只显示模型里已有的入口。
  final PatchDeliveryDetail? detail;

  /// 深色外壳（详情页锚定栏）用深色配色；浅色横条的展开位用默认配色
  final bool onDark;

  final PatchDownloadState? download;

  /// 「下载到本地」→ 调用方接下载链路（先弹确认框再下）
  final VoidCallback? onDownload;

  final VoidCallback? onCancel;

  /// 2DFan「用积分兑换」→ 调用方弹二次确认（**不可逆**，必须由调用方确认）
  final VoidCallback? onRedeem;

  /// 重新解析投递详情（出错或用户手动刷新）
  final VoidCallback? onRefresh;

  /// 兑换请求进行中（按钮转圈并禁用，防止连点）
  final bool redeeming;

  /// 展开位里是否用紧凑间距（深色栏里空间更紧）
  final bool dense;

  _Pal get _p => _Pal(onDark: onDark);

  /// 实际使用的详情（有解析结果用解析结果，否则从模型兜底）
  PatchDeliveryDetail get _d =>
      detail ?? PatchDeliveryDetail.fromResource(resource);

  @override
  Widget build(BuildContext context) {
    final r = resource;
    final gap = dense ? 8.0 : 10.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _linksBlock(),
        if (r.site == PatchSite.twoDfan) ...[
          SizedBox(height: gap),
          _fanAccountBlock(),
        ],
        if (r.note.trim().isNotEmpty) ...[
          SizedBox(height: gap),
          _noteBlock(r.note.trim()),
        ],
        if (r.sha256.trim().isNotEmpty) ...[
          SizedBox(height: gap),
          _shaLine(r.sha256.trim()),
        ],
        SizedBox(height: gap + 2),
        _actionRow(r),
        if (_hasProgress) ...[
          const SizedBox(height: 8),
          _progressRow(),
        ],
      ],
    );
  }

  bool get _hasProgress {
    final dl = download;
    return dl != null && dl.phase != PatchDownloadPhase.idle;
  }

  // ---------------- 三态信息块 ----------------

  /// 下载入口区：直链一组、网盘一组，**逐个列出**。
  ///
  /// 两个站都会出现「一个资源挂多个下载点」：
  /// - 2DFan：`网盘载点1`（百度）+ `海外直连`（`d1.acgxp.com`）
  /// - 鲲：`共 N 个`，可能是直链 + 夸克 + 百度并存
  ///
  /// ⇒ 全都列出来，用户不必回原页翻。
  Widget _linksBlock() {
    final d = _d;
    final directs = d.directLinks;
    final netdisks = d.netdiskLinks;

    if (directs.isEmpty && netdisks.isEmpty) {
      return _webBlock();
    }

    final blocks = <Widget>[
      if (directs.isNotEmpty) _directBlock(directs),
      if (netdisks.isNotEmpty) _netdiskBlock(netdisks),
    ];
    if (blocks.length == 1) return blocks.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        blocks[0],
        SizedBox(height: dense ? 8 : 10),
        blocks[1],
      ],
    );
  }

  /// 直链组
  Widget _directBlock(List<PatchDeliveryLink> links) {
    return _block(
      icon: Icons.link_rounded,
      label: links.length > 1 ? '直链文件 · ${links.length} 个' : '直链文件',
      accent: onDark ? DarkPalette.lightBlue : AppColors.accentCyan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _linkRow(
              title: links[i].label.isEmpty
                  ? (Uri.tryParse(links[i].url)?.host ?? '直链')
                  : links[i].label,
              url: links[i].url,
              trailingLabel: '下载',
              trailingIcon: Icons.download_rounded,
              onTrailing: i == 0 ? onDownload : null,
            ),
          ],
          const SizedBox(height: 6),
          _kv('文件大小', resource.sizeLabel.isEmpty ? '未知' : resource.sizeLabel),
          const SizedBox(height: 4),
          _kv('下载后', '保存到你选择的目录；zip 会顺手解压到同名文件夹'),
        ],
      ),
    );
  }

  /// 网盘组（每个网盘一行 + 提取码）
  Widget _netdiskBlock(List<PatchDeliveryLink> links) {
    return _block(
      icon: Icons.cloud_outlined,
      label: links.length > 1 ? '网盘分享 · ${links.length} 个' : '网盘分享',
      accent: onDark ? DarkPalette.violet : const Color(0xFF7C6BD6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _linkRow(
              title: links[i].provider ??
                  (links[i].label.trim().isEmpty ? '网盘' : links[i].label),
              url: links[i].url,
              code: links[i].extractCode,
              trailingLabel: '打开',
              trailingIcon: Icons.open_in_new_rounded,
              onTrailing: () =>
                  WebsiteBookmarkService.openExternal(links[i].url),
            ),
          ],
        ],
      ),
    );
  }

  /// 一行「标题 + 链接 + 提取码 + 尾部按钮」
  Widget _linkRow({
    required String title,
    required String url,
    String? code,
    required String trailingLabel,
    required IconData trailingIcon,
    VoidCallback? onTrailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _p.body,
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                url,
                maxLines: 1,
                style: TextStyle(fontSize: 10, color: _p.dim),
              ),
              if (code != null && code.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  '提取码 $code',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: onDark ? DarkPalette.violet : const Color(0xFF6A58C8),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        _miniButton(
          label: trailingLabel,
          icon: trailingIcon,
          onTap: onTrailing,
        ),
      ],
    );
  }

  /// 无任何入口时的兜底块
  Widget _webBlock() {
    return _block(
      icon: Icons.open_in_new_rounded,
      label: '需要在站点页面下载',
      accent: onDark ? DarkPalette.yellow : const Color(0xFFC98A00),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _d.reason.isEmpty
                ? '这个条目没有可直接下载的文件，请到原站查看。'
                : _d.reason,
            style: TextStyle(fontSize: 10.5, height: 1.5, color: _p.body),
          ),
          if (_d.error != null) ...[
            const SizedBox(height: 5),
            Text(
              _d.error!,
              style: TextStyle(fontSize: 10, color: AppColors.dangerRed),
            ),
          ],
          if (onRefresh != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: _miniButton(
                label: '重新获取',
                icon: Icons.refresh_rounded,
                onTap: onRefresh,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 2DFan 账号与积分账（只对 2DFan 显示）
  ///
  /// 🔴 数字来源只有两种：**页面真实给了**，或**如实说看不到**。
  /// 早期版本写死「登录后可见」，即使已经登录也不变 —— 那等于把已有能力藏起来。
  Widget _fanAccountBlock() {
    final d = _d;
    final price = d.price;
    final balance = d.balance;
    final loggedIn = d.authenticated;

    final String priceText;
    if (price == null) {
      priceText = '页面未标价';
    } else if (price == 0) {
      priceText = '免费';
    } else {
      priceText = '$price 积分';
    }

    final String balanceText;
    if (!loggedIn) {
      balanceText = '登录后可见';
    } else if (balance == null) {
      balanceText = '读取失败';
    } else {
      balanceText = '$balance 积分';
    }

    final enough = price != null && balance != null && balance >= price;

    return _block(
      icon: Icons.account_balance_wallet_outlined,
      label: '积分账 · ${d.accountSummary.trim().isEmpty ? '未登录' : d.accountSummary}',
      accent: onDark ? DarkPalette.yellow : const Color(0xFFC98A00),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _costTile('本次费用', priceText)),
              const SizedBox(width: 8),
              Expanded(child: _costTile('账号积分', balanceText)),
            ],
          ),
          if (d.requiresPurchase) ...[
            const SizedBox(height: 7),
            Text(
              !loggedIn
                  ? '兑换需要 2DFan 登录态：在设置 → 元数据 → 2DFan 里填入浏览器 Cookie 即可，'
                      '本软件不代输密码（站点用 Cloudflare 验证码）。'
                  : (!enough
                      ? '积分不足，无法兑换。可以先用下面的网盘载点。'
                      : '兑换会立刻扣除 $price 积分且不可撤销，点击后会再确认一次。'),
              style: TextStyle(fontSize: 10.5, height: 1.5, color: _p.dim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _block({
    required IconData icon,
    required String label,
    required Color accent,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(11, 9, 11, 10),
      decoration: BoxDecoration(
        color: _p.tileBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _p.tileBorder,
          width: onDark ? 0.6 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: _p.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(k, style: TextStyle(fontSize: 10.5, color: _p.dim)),
        ),
        Expanded(
          child: SelectableText(
            v,
            maxLines: 2,
            style: TextStyle(fontSize: 11, height: 1.45, color: _p.body),
          ),
        ),
      ],
    );
  }

  Widget _costTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: _p.chipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: _p.dim)),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _p.title,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noteBlock(String note) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: _p.noteBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '说明',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _p.dim,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            note,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, height: 1.5, color: _p.body),
          ),
        ],
      ),
    );
  }

  Widget _shaLine(String sha) {
    return Row(
      children: [
        Text('SHA-256',
            style: TextStyle(fontSize: 9.5, color: _p.dim, letterSpacing: 0.3)),
        const SizedBox(width: 6),
        Expanded(
          child: SelectableText(
            sha,
            maxLines: 1,
            style: TextStyle(fontSize: 9.5, color: _p.dim),
          ),
        ),
      ],
    );
  }

  // ---------------- 动作 ----------------

  /// 动作区。主按钮优先级（从高到低）：
  ///
  /// 1. **软件内下载**（有直链）—— 这是补丁站的核心价值
  /// 2. **用积分兑换**（2DFan，已登录且余额够）—— 兑换后才会有直链
  /// 3. **复制网盘链接与提取码**（无需登录、无需积分）
  /// 4. **打开资源页**（永远可用的兜底）
  ///
  /// 🔴 兑换是不可逆操作：这里只负责把意图交给调用方，**确认弹窗必须由
  /// 调用方（`onRedeem`）弹**，本组件不做任何扣分动作。
  Widget _actionRow(PatchResource r) {
    final d = _d;
    final page = r.webUrl.trim();
    final direct = d.primaryDirectUrl;
    final netdisk = d.primaryNetdisk;
    final canDownloadHere = direct != null && onDownload != null;
    final canRedeem = d.canPurchase && onRedeem != null && !redeeming;

    final ghosts = <Widget>[];
    if (direct != null) {
      ghosts.add(_ghost('复制直链', Icons.copy_rounded, () => _copy(direct)));
    }
    if (netdisk != null) {
      ghosts.add(_ghost(
        '打开${netdisk.provider ?? '网盘'}',
        Icons.open_in_new_rounded,
        () => WebsiteBookmarkService.openExternal(netdisk.url),
      ));
    }
    if (page.isNotEmpty) {
      ghosts.add(_ghost(
        '打开资源页',
        Icons.open_in_new_rounded,
        () => WebsiteBookmarkService.openExternal(page),
      ));
    }

    final Widget primary;
    if (canDownloadHere) {
      primary = _primary(
        '下载到本地',
        Icons.download_rounded,
        onDownload,
        enabled: true,
      );
    } else if (d.canPurchase) {
      primary = _primary(
        redeeming ? '兑换中…' : '用积分兑换并下载',
        Icons.redeem_rounded,
        canRedeem ? onRedeem : null,
        enabled: canRedeem,
      );
    } else if (netdisk != null) {
      primary = _primary(
        '复制链接与提取码',
        Icons.copy_rounded,
        () => _copy(netdisk.extractCode == null
            ? netdisk.url
            : '${netdisk.url}\n提取码：${netdisk.extractCode}'),
        enabled: true,
      );
    } else {
      primary = _primary(
        '打开资源页',
        Icons.open_in_new_rounded,
        page.isEmpty
            ? null
            : () => WebsiteBookmarkService.openExternal(page),
        enabled: page.isNotEmpty,
      );
    }

    return Row(
      children: [
        ...ghosts,
        const Spacer(),
        primary,
      ],
    );
  }

  /// 信息块里的小号描边按钮（「下载」「打开」）
  Widget _miniButton({
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final active = onTap != null;
    final fg = active ? _p.body : _p.dim;
    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.5,
          duration: const Duration(milliseconds: 140),
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _p.tileBorder, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 11.5, color: fg),
                const SizedBox(width: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ghost(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: _button(
        label: label,
        icon: icon,
        onTap: onTap,
        filled: false,
        enabled: true,
      ),
    );
  }

  Widget _primary(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    required bool enabled,
  }) {
    return _button(
      label: label,
      icon: icon,
      onTap: onTap,
      filled: true,
      enabled: enabled,
    );
  }

  Widget _button({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    required bool filled,
    required bool enabled,
  }) {
    final active = enabled && onTap != null;
    final accent = onDark ? DarkPalette.primaryBlue : AppColors.accentCyan;
    final Color fg;
    final Color bg;
    final Color border;
    if (filled) {
      fg = active
          ? (onDark ? Colors.white : AppColors.onAccentSolid)
          : _p.dim;
      bg = active ? accent : Colors.transparent;
      border = active ? accent : _p.tileBorder;
    } else {
      fg = active ? _p.body : _p.dim;
      bg = Colors.transparent;
      border = _p.tileBorder;
    }

    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: active ? onTap : null,
        child: AnimatedOpacity(
          opacity: active ? 1 : 0.45,
          duration: const Duration(milliseconds: 140),
          child: Container(
            height: dense ? 25 : 27,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12.5, color: fg),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: AppStyles.bodyRegular.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- 进度 ----------------

  Widget _progressRow() {
    final dl = download!;
    final failed = dl.phase == PatchDownloadPhase.failed;
    final done = dl.phase == PatchDownloadPhase.done;

    final String text;
    if (dl.phase == PatchDownloadPhase.downloading) {
      final pct =
          dl.fraction == null ? '' : '${(dl.fraction! * 100).toStringAsFixed(0)}%  ';
      final speed = dl.speedLabel.isEmpty ? '' : ' · ${dl.speedLabel}';
      text = '$pct${dl.sizeLabel}$speed';
    } else if (dl.phase == PatchDownloadPhase.verifying) {
      text = '校验中…';
    } else if (dl.phase == PatchDownloadPhase.extracting) {
      text = '解压中…';
    } else if (done) {
      text = dl.extractedCount > 0
          ? '已下载 · 解压出 ${dl.extractedCount} 个文件'
          : '已下载';
    } else if (dl.phase == PatchDownloadPhase.canceled) {
      text = dl.message ?? '已取消';
    } else {
      text = dl.message ?? '下载失败';
    }

    Widget? action;
    if (dl.phase == PatchDownloadPhase.downloading ||
        dl.phase == PatchDownloadPhase.verifying) {
      action = dl.phase == PatchDownloadPhase.downloading && onCancel != null
          ? _ghostOnly('取消', Icons.close_rounded, onCancel!)
          : null;
    } else if (done) {
      final dir = _doneFolder(dl);
      action = dir.isEmpty
          ? null
          : _ghostOnly(
              '打开文件夹',
              Icons.folder_open_rounded,
              () => PatchDownloadService.openInExplorer(dir),
            );
    } else if (failed) {
      action = onDownload == null
          ? null
          : _ghostOnly('重试', Icons.refresh_rounded, onDownload!);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (dl.phase == PatchDownloadPhase.verifying ||
                    dl.phase == PatchDownloadPhase.extracting)
                ? null
                : (done ? 1.0 : dl.fraction),
            minHeight: 3,
            backgroundColor: _p.tileBorder,
            valueColor: AlwaysStoppedAnimation(
              failed ? AppColors.dangerRed : AppColors.accentCyan,
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Expanded(
              child: Text(
                (dl.hint ?? '').trim().isEmpty
                    ? text
                    : '$text · ${dl.hint!.trim()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppStyles.bodyRegular.copyWith(
                  fontSize: 10.5,
                  color: failed ? AppColors.dangerRed : _p.dim,
                ),
              ),
            ),
            if (action != null) action,
          ],
        ),
      ],
    );
  }

  Widget _ghostOnly(String label, IconData icon, VoidCallback onTap) {
    return _button(
      label: label,
      icon: icon,
      onTap: onTap,
      filled: false,
      enabled: true,
    );
  }

  static String _doneFolder(PatchDownloadState dl) {
    final extract = (dl.extractDir ?? '').trim();
    if (extract.isNotEmpty) return extract;
    final saved = (dl.saveDir ?? '').trim();
    if (saved.isNotEmpty) return saved;
    final file = (dl.filePath ?? '').trim();
    if (file.isEmpty) return '';
    final i = file.lastIndexOf(RegExp(r'[\\/]'));
    return i > 0 ? file.substring(0, i) : '';
  }

  static Future<void> _copy(String text) async {
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }
}

/// 浅色 / 深色两套取色。展开位跟面板（浅色），详情页锚定栏跟深色。
class _Pal {
  _Pal({required this.onDark});

  final bool onDark;

  Color get tileBg =>
      onDark ? DarkPalette.linkCardBg : AppColors.background;
  Color get tileBorder =>
      onDark ? DarkPalette.cardBorder : AppColors.border.withOpacity(0.7);
  Color get chipBg =>
      onDark ? DarkPalette.badgeNeutralBg : AppColors.buttonBackground;
  Color get noteBg => onDark ? DarkPalette.noteCardBg : AppColors.background;
  Color get title => onDark ? DarkPalette.textPrimary : AppColors.primaryText;
  Color get body => onDark ? DarkPalette.textBody : AppColors.primaryText.withOpacity(0.86);
  Color get label => onDark ? DarkPalette.textSecondary : AppColors.primaryText.withOpacity(0.8);
  Color get dim => onDark ? DarkPalette.textDim : AppColors.secondaryText;
}
