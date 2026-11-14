// DL-SINGLE-STREAM 探针（2026-11-14）
//
// 验证「全站库直链强制单连接下载」的分支判定与默认值。
//
// ⚠️ 为什么只测分支、不测真下载：完整 DownloadCore.start 会走
//    `DownloadCacheDir.resolveFor` → `Directory.create(recursive: true)`，
//    该调用在 flutter_tester 里永久挂起（项目已知坑），裸 VM 又无法加载
//    dart:ui（DownloadCore 依赖 flutter/foundation）。所以把「走哪条路」的
//    判定抽成纯函数 [DownloadCore.resolveStrategy]，在这里锁死全部组合；
//    真实链路（下载 → 解压 → 入库）由真机走查确认。
//
// 运行：
//   dartaotruntime gen_kernel_aot.dart.snapshot --platform <platform_strong.dill> \
//     --target flutter --packages .dart_tool/package_config.json \
//     --output .probe.dill dev_probe/single_stream_probe.dart
//   flutter_tester.exe --disable-vm-service --enable-checked-mode .probe.dill

import 'dart:io';

import 'package:chrono_tide/services/download_core.dart';
import 'package:chrono_tide/services/global_install_center.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('✅ PASS  $name${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _fail++;
    print('❌ FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

String _s(DownloadStrategy v) => v.name;

void main() {
  print('=== [A] 分支判定：缓存 / 单流指定 / Range 的组合 ===');

  // A1 缓存已有完整包 → 永不重下（哪怕这次是单流任务）
  check(
    'A1 缓存命中优先于单流指定',
    DownloadCore.resolveStrategy(
          hasCompletePackage: true,
          preferSingleStream: true,
          supportsRange: true,
        ) ==
        DownloadStrategy.skipExisting,
    _s(DownloadCore.resolveStrategy(
      hasCompletePackage: true,
      preferSingleStream: true,
      supportsRange: true,
    )),
  );
  check(
    'A2 缓存命中优先于分片',
    DownloadCore.resolveStrategy(
          hasCompletePackage: true,
          preferSingleStream: false,
          supportsRange: true,
        ) ==
        DownloadStrategy.skipExisting,
  );

  // A3 全站库：支持 Range 也必须走单流（不能被分片抢走）
  check(
    'A3 preferSingleStream=true + 支持Range → 单流',
    DownloadCore.resolveStrategy(
          hasCompletePackage: false,
          preferSingleStream: true,
          supportsRange: true,
        ) ==
        DownloadStrategy.singleStream,
  );
  check(
    'A4 preferSingleStream=true + 不支持Range → 单流',
    DownloadCore.resolveStrategy(
          hasCompletePackage: false,
          preferSingleStream: true,
          supportsRange: false,
        ) ==
        DownloadStrategy.singleStream,
  );

  // A5/A6 探索库（默认）行为零变化
  check(
    'A5 默认 + 支持Range → 分片（探索库行为不变）',
    DownloadCore.resolveStrategy(
          hasCompletePackage: false,
          preferSingleStream: false,
          supportsRange: true,
        ) ==
        DownloadStrategy.chunked,
  );
  check(
    'A6 默认 + 不支持Range → 单流兜底',
    DownloadCore.resolveStrategy(
          hasCompletePackage: false,
          preferSingleStream: false,
          supportsRange: false,
        ) ==
        DownloadStrategy.singleStream,
  );

  print('\n=== [B] InstallTask 默认不带单流 ===');
  const normal = InstallTask(gameId: 'pb0123456789abc', title: '探索库作品');
  const siteLike = InstallTask(
    gameId: 'site:moyu:2222',
    title: '全站库作品',
    singleStream: true,
  );
  check('B1 InstallTask.singleStream 默认 false', normal.singleStream == false,
      '${normal.singleStream}');
  check('B2 全站库任务可显式置 true', siteLike.singleStream == true,
      '${siteLike.singleStream}');
  check('B3 默认任务的 proxyUrl 仍为空', normal.proxyUrl == null,
      '${normal.proxyUrl}');

  print('\n=== 结果: $_pass PASS / $_fail FAIL ===');
  exit(_fail == 0 ? 0 : 1);
}
