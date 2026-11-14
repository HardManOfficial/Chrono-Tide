import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../../widgets/confirm_dialog.dart';
import '../../widgets/install_confirmation_dialog.dart';
import '../download_acceleration.dart';
import '../global_install_center.dart';
import '../install_path_preference.dart';
import '../local_game_registry.dart';
import '../network_proxy_policy.dart';

/// 全站库「获取」→ 软件原生安装（下载 + 解压 + 入库）的入口。
///
/// ## 为什么不复用 CloudInstallFlow
///
/// [CloudInstallFlow] 面向**探索库**（PocketBase 记录驱动）：它要先做 OpenList
/// 配对、把网盘**路径**换成会过期的签名直链。全站库拿到的是 letmoe 托管直链
/// （`https://dl.imoe.uk/letmoe/<uuid>.zip`，不签名不过期），走那条链只会多出
/// 两次必然失败的步骤。这里直接组装 [InstallTask] 交给
/// [GlobalInstallCenter.submitTask]——串行队列、进度浮层、取消、解压、
/// 自动入库、失败回滚全部复用现成的一套。
///
/// ## 合成 gameId
///
/// 站外作品没有 PocketBase 记录。[InstallTask.gameId] 会被写进 game.json 的
/// `cloud_game_id`（本地注册表 `cloud:` 索引），格式 `site:<源key>:<站点id>`
/// 与 PB 的 15 位 id 天然不冲突，也自带来源信息。
///
/// ## 只做游戏本体
///
/// 只有 `type == 'game'` 的资源才走安装（本体→解压→入库）。特典/广播剧这类
/// 资源包内没有可执行本体，解压会触发「未找到本体」决策弹窗，仍保留
/// 「下载到本地」（见资源面板）。
enum SiteLibraryInstallResult {
  /// 已提交（空闲则立即执行，忙碌则入队）
  submitted,

  /// 用户在确认弹窗取消
  cancelled,

  /// 同一作品已在安装或队列中
  duplicate,

  /// 下载地址非法 / 缺地址
  linkFailed,
}

class SiteLibraryInstallFlow {
  SiteLibraryInstallFlow._();

  /// HEAD 量体积的超时。直链在 Cloudflare 后面，慢但可用；
  /// 超时只影响「体积显示」，不阻断安装，故取较短值。
  static const Duration _headTimeout = Duration(seconds: 8);

  /// 弹确认框（含体积/剩余空间预览）→ 组装任务 → 提交安装中心。
  ///
  /// 永不抛异常：所有失败路径都以枚举返回，调用方只负责提示。
  static Future<SiteLibraryInstallResult> submit({
    required BuildContext context,
    required SiteSearchHit hit,
    required LetmoeResource resource,
    required LetmoeMirror mirror,
  }) async {
    // ① 安全闸：URL 来自远端 API，⛔ 不能把 file:// / 自定义 scheme 交给
    //    HttpClient（与资源面板同一条纪律）。
    final uri = Uri.tryParse(mirror.url);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (uri == null || (scheme != 'http' && scheme != 'https')) {
      return SiteLibraryInstallResult.linkFailed;
    }

    final gameId = buildGameId(hit);
    if (GlobalInstallCenter.instance.isQueuedOrRunning(gameId)) {
      return SiteLibraryInstallResult.duplicate;
    }

    // ② 同标题已在库：不拦截（用户可能就是要重装一份），但必须说清后果
    //    ——解压会生成 `标题_1` 目录，库里出现两个同名条目。
    final existing = LocalGameRegistry.instance.getGameByTitle(hit.title);
    if (existing != null) {
      final proceed = await showConfirmDialog(
        context: context,
        title: '库中已有同名作品',
        message: '「${hit.title}」已经在你的游戏库里了'
            '（${existing.directoryPath}）。\n\n'
            '继续安装会重新下载并解压一份新的副本，游戏库里会出现两个'
            '同名条目。如果你只想修好现有安装，请先删掉旧条目再安装。',
        confirmText: '仍然安装',
        cancelText: '取消',
        hint: '重新安装不会覆盖原目录',
      );
      if (!proceed) return SiteLibraryInstallResult.cancelled;
    }

    // ③ 体积：LetmoeResource.bytes 实测不准（样本差 15%），
    //    组合包自带 bytes 才可信；其余现量一次 HEAD。
    final expectedSizeBytes = mirror.bytes > 0
        ? mirror.bytes
        : await _probeSize(mirror.url);

    // ④ 通道探测：当前直连、且本机能用一个代理把这条直链拉通时，把选择权
    //    交给用户（默认不勾）。探测结果是「耗时上限约 12s 的最坏情况」，
    //    但正常机器上没有代理端口时 400ms 内就返回 null。
    //
    //    背景见 [DownloadAcceleration]：letmoe 直连实测 0.2 MB/s/连接，
    //    经本机代理 2–2.7 MB/s/连接，差一个数量级。
    //    ⚠️ 已经走全局代理时不再探测：再套一层会变成双重代理。
    final hasGlobalProxy =
        NetworkProxyPolicy.instance.effectiveProxy != null;
    final proxy = hasGlobalProxy
        ? null
        : await DownloadAcceleration.detect(probeUrl: mirror.url);
    var useProxy = false;

    // ⑤ 确认弹窗：安装位置 + 完整路径 + 体积/剩余空间（+ 可选的加速通道）
    final confirm = await InstallConfirmationDialog.show(
      context: context,
      gameTitle: hit.title,
      gameCoverUrl: hit.coverUrl,
      gameDescription: hit.summary,
      gameTags: hit.tags,
      knownSizeBytes: expectedSizeBytes > 0 ? expectedSizeBytes : null,
      proxySuggestion: proxy,
      onProxyChanged: (v) => useProxy = v,
    );
    if (confirm != InstallConfirmationResult.confirmed) {
      return SiteLibraryInstallResult.cancelled;
    }

    // ⑤ 安装位置：上次使用 → 默认位置 → null（应用默认目录）。
    //    确认弹窗里用户改过的选择由 InstallConfirmationDialog.show 自行
    //    记进 InstallPathPreference，这里读到的是最终值。
    String? customLocation =
        await InstallPathPreference.instance.getLastUsedLocation();
    if (customLocation == null || customLocation.isEmpty) {
      customLocation =
          await InstallPathPreference.instance.getDefaultGameLocation();
    }

    final task = InstallTask(
      gameId: gameId,
      title: hit.title,
      description: hit.summary,
      coverUrl: hit.coverUrl,
      bannerUrl: hit.bannerUrl,
      tags: hit.tags.isEmpty ? null : hit.tags,
      downloadUrl: mirror.url,
      developer: hit.developer,
      customGameLocation: customLocation,
      screenshotUrls:
          hit.screenshotUrls.isEmpty ? null : hit.screenshotUrls,
      subtitle: hit.subtitle,
      expectedSizeBytes: expectedSizeBytes > 0 ? expectedSizeBytes : null,
      // ⛔ 不设 urlResolver：托管直链不签名不过期，重试沿用原 URL 即可。
      // ★ DL-ACCEL：只有用户在弹窗里勾了「使用本机代理加速」才带上代理，
      //   否则 null ⇒ 跟随全局策略（行为与改动前一致）。
      proxyUrl: useProxy ? proxy : null,
      // ★ DL-SINGLE-STREAM（2026-11-14 用户拍板）：全站库直链一律单连接
      //   下载，不分片、不做档位探测。理由见 [DownloadCore.start] 的
      //   `preferSingleStream` 注释：稳定性/安全性优先于峰值吞吐。
      singleStream: true,
    );

    // fire-and-forget：submitTask 的 Future 在任务**执行完毕**才 resolve，
    // await 它会把 UI 卡到下载+解压全部结束（CloudInstallFlow 的白屏事故）。
    // 进度交给左下角任务按钮 / 安装中心。
    unawaited(GlobalInstallCenter.instance.submitTask(task));
    return SiteLibraryInstallResult.submitted;
  }

  /// 合成 gameId：`site:<源key>:<站点id>`。
  ///
  /// 同时用作 game.json 的 `cloud_game_id` 与安装队列去重键——同一作品
  /// 无论从卡片还是详情页点「获取」，都落到同一个键上。
  static String buildGameId(SiteSearchHit hit) =>
      'site:${hit.source.key}:${hit.siteId}';

  /// HEAD 量下载包体积（best-effort，失败返回 0）。
  ///
  /// 有些 CDN 拒绝 HEAD：此时退回 `Range: bytes=0-0` 的 GET，从
  /// `Content-Range` 的 `/总长` 取（只为一个字节，代价可接受）。
  static Future<int> _probeSize(String url) async {
    final client = HttpClient()
      ..connectionTimeout = _headTimeout
      ..userAgent = 'ChronoTide/1.0 (Site Library Install)';
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return 0;

      var req = await client.headUrl(uri).timeout(_headTimeout);
      var resp = await req.close().timeout(_headTimeout);
      await resp.drain<void>();
      final len = resp.contentLength;
      if (resp.statusCode == 200 && len > 0) return len;

      req = await client.getUrl(uri).timeout(_headTimeout);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      resp = await req.close().timeout(_headTimeout);
      await resp.drain<void>();
      final contentRange = resp.headers.value('content-range') ?? '';
      final slash = contentRange.lastIndexOf('/');
      if (slash >= 0) {
        final total = int.tryParse(contentRange.substring(slash + 1).trim());
        if (total != null && total > 0) return total;
      }
      return 0;
    } catch (e) {
      debugPrint('[SITE-INSTALL] 体积探测失败（不影响安装）: $e');
      return 0;
    } finally {
      client.close(force: true);
    }
  }
}
