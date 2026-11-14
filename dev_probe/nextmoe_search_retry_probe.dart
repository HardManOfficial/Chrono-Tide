// NextMoe 全站搜索连接级重试探针（flutter_tester，真 HTTP e2e）
//
// 背景（2026-11-14）：api.nextmoe.dev 解析到两个 Cloudflare 边缘 IP，其一
// 黑洞 TCP 连接 ⇒ 连接失败概率 ~50%，旧实现一次超时就返回空 ⇒ 鲲源 0 命中。
// 修复：连接层失败重试（最多 3 次，重连重新解析换边）。
//
// 编译跑法同 site_library_resource_probe.dart（platform dill 在
// engine/common/flutter_patched_sdk/，⛔ 不在 windows-x64/）。
//
// 退出码：0 = 全绿；1 = 有失败。
import 'dart:async';
import 'dart:io';

import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

int _pass = 0;
int _fail = 0;

void L(String m) => stdout.writeln(m);

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
  }
  L('  ${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : ' | $detail'}');
}

Future<List<SiteSearchHit>> _search(String kw) {
  L('  → 搜索 [$kw] …');
  return NextMoeService()
      .searchWorks(kw, limit: 10)
      .timeout(const Duration(seconds: 90), onTimeout: () {
    L('  [TIMEOUT] [$kw] 90s 超时');
    throw TimeoutException('searchWorks($kw)');
  });
}

Future<void> main() async {
  L('=== NextMoe searchWorks 真 HTTP e2e（含连接级重试）===');
  await stdout.flush();

  // 三个关键词各搜一次：只要有一次「命中非空 + id/标题合法」就算链路恢复。
  // 上游黑洞是间歇性的，重试后应稳定命中；若三连全空才算失败。
  final keywords = <String>['AIR', '丸子与银河龙', 'Clannad'];
  var anyHit = false;

  for (final kw in keywords) {
    try {
      final hits = await _search(kw);
      await stdout.flush();
      check('搜索[$kw] 非空', hits.isNotEmpty, 'got ${hits.length}');
      if (hits.isNotEmpty) {
        anyHit = true;
        final h0 = hits.first;
        check('搜索[$kw] id 十进制', int.tryParse(h0.siteId) != null, h0.siteId);
        check('搜索[$kw] 标题非空', h0.title.isNotEmpty, h0.title);
        check('搜索[$kw] detailUrl=作品直链',
            h0.detailUrl?.startsWith('https://www.kungal.com/galgame/') ?? false,
            h0.detailUrl ?? 'null');
        L('      · Top1: ${h0.siteId} ${h0.title}');
      }
    } catch (e, st) {
      check('搜索[$kw] 未抛异常', false, '$e');
      for (final l in st.toString().split('\n').take(6)) {
        L('      @ $l');
      }
    }
    await stdout.flush();
  }

  check('至少一个关键词命中', anyHit);

  L('');
  L('=== 结果: $_pass PASS / $_fail FAIL ===');
  await stdout.flush();
  exitCode = _fail == 0 ? 0 : 1;
}
