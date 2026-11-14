// KUNGAL 外跳入口（2026-10-24）单元测试
//
// 覆盖两件不依赖网络、不依赖运行时的纯逻辑：
// 1. `claimIdOf` —— 从 NextMoe work 对象的 `claim` 块取 KUNGAL 站内 id
//    （只有 site=kungal 且 id 为正整数才算命中，其余一律 null）
// 2. URL 构造 —— 详情页 / 站内搜索页兜底
//
// 组件层（头部胶囊出现/隐藏）不在本文件覆盖：`flutter test` 在本机仍受
// ERROR_PIPE_BUSY(231) 阻塞，需等环境恢复后补跑。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/kungal_link_service.dart';

void main() {
  group('KungalLinkService.claimIdOf', () {
    test('site=kungal 且 id 合法 → 返回 id', () {
      expect(
        KungalLinkService.claimIdOf({
          'claim': {'site': 'kungal', 'site_work_id': '373', 'state': 'live'},
        }),
        '373',
      );
    });

    test('site_work_id 为数字类型同样接受', () {
      expect(
        KungalLinkService.claimIdOf({
          'claim': {'site': 'kungal', 'site_work_id': 12},
        }),
        '12',
      );
    });

    test('站点点名不是 kungal → null', () {
      expect(
        KungalLinkService.claimIdOf({
          'claim': {'site': 'other', 'site_work_id': '373'},
        }),
        isNull,
      );
    });

    test('没有 claim 块 → null', () {
      expect(KungalLinkService.claimIdOf({'id': '1', 'name': 'x'}), isNull);
    });

    test('claim 非 Map → null（不抛异常）', () {
      expect(KungalLinkService.claimIdOf({'claim': 'kungal'}), isNull);
    });

    test('id 非法（空串 / 非数字 / 0 以下）→ null', () {
      for (final bad in ['', 'abc', '0', '-3']) {
        expect(
          KungalLinkService.claimIdOf({
            'claim': {'site': 'kungal', 'site_work_id': bad},
          }),
          isNull,
          reason: 'site_work_id="$bad" 应判为无效',
        );
      }
    });
  });

  group('KungalLinkService URL', () {
    test('detailUrlOf 拼站内详情页', () {
      expect(
        KungalLinkService.detailUrlOf(373),
        'https://www.kungal.com/galgame/373',
      );
    });

    test('detailUrlOf 遇到无效 id → 空串（UI 据此不展示外跳）', () {
      expect(KungalLinkService.detailUrlOf(0), isEmpty);
      expect(KungalLinkService.detailUrlOf(-1), isEmpty);
    });

    test('searchUrlOf 对中文标题做 query 编码', () {
      final url = KungalLinkService.searchUrlOf('海与雪的青蓝色');
      expect(url, startsWith('https://www.kungal.com/search?keywords='));
      expect(url.contains('type=galgame'), isTrue);
      // 已编码：不应残留原始中文
      expect(url.contains('海与雪的青蓝色'), isFalse);
    });

    test('searchUrlOf 空标题 → 站内 galgame 首页', () {
      expect(KungalLinkService.searchUrlOf('   '),
          'https://www.kungal.com/galgame');
    });
  });

  group('KungalLinkService 缓存与并发（2026-10-25 入口常驻修复）', () {
    late KungalLinkService svc;
    var calls = 0;

    setUp(() {
      svc = KungalLinkService.forTest();
      calls = 0;
      KungalLinkService.debugResolver = (titles) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 373;
      };
    });

    tearDown(() => KungalLinkService.debugResolver = null);

    test('已解析 → resolve 同步命中缓存，零网络', () async {
      svc.seed('g1', 373);
      expect(svc.lookup('g1'), 373);
      expect(svc.hasResolved('g1'), isTrue);
      expect(await svc.resolve('g1', ['海与雪的青蓝色']), 373);
      expect(calls, 0, reason: '命中缓存不应发请求');
    });

    test('未解析 → hasResolved 为 false（lookup 同为空但语义不同）', () {
      expect(svc.lookup('g2'), isNull);
      expect(svc.hasResolved('g2'), isFalse);
    });

    test('负结果也算「有结论」，避免入口反复打网络', () async {
      KungalLinkService.debugResolver = (_) async => null;
      expect(await svc.resolve('g3', ['x']), isNull);
      expect(svc.hasResolved('g3'), isTrue);
      expect(svc.lookup('g3'), isNull);
    });

    test('🔴 并发调用共享同一 Future，不会丢弃结果', () async {
      // 这是历史缺陷的回归用例：旧实现第二次调用直接 return null，
      // 用户表现为「退出详情再进来才出现按钮」。
      final first = svc.resolve('g4', ['海与雪的青蓝色']);
      final second = svc.resolve('g4', ['海与雪的青蓝色']);
      final results = await Future.wait([first, second]);

      expect(results, [373, 373], reason: '两次调用必须都拿到同一个结果');
      expect(calls, 1, reason: '并发只应打一次网络');
    });

    test('预解析后立即 lookup 命中（模拟列表预热 → 点卡片）', () async {
      svc.prefetch([(id: 'g5', titles: ['海与雪的青蓝色'])]);
      // 等预解析的 20ms 跑完
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(svc.lookup('g5'), 373);
    });
  });
}
