// font_compatibility_service_test.dart
// 本地「不兼容游戏清单」服务单测（Phase 4.3）。
//
// ⚠️ 本机 `flutter test` 受 `CreateFile failed 231` 限制可能跑不了；
// 同一批断言已有可执行版 `.workbuddy/probe_fonthook_ui/compat_probe.dart`
// （flutter_tester 直跑，26 PASS / 0 FAIL，2026-10-17）。
// 本文件保留给环境恢复后的 `flutter test`。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/font_compatibility_service.dart';

const String _sample = '''
{
  "version": 1,
  "updatedAt": "2026-10-17",
  "entries": [
    {
      "titles": ["某移植作 Remastered", "某移植作"],
      "exes": ["somegame.exe"],
      "severity": "warn",
      "reason": "引擎自绘字体缓存，替换后按钮文字错位。",
      "doc": "https://example.com/issue/123"
    },
    { "titles": ["仅提示的作品"], "severity": "info", "reason": "仅作提示。" },
    { "titles": [], "exes": ["onlyexe.exe"], "reason": "只按启动程序名匹配。" },
    { "titles": ["缺原因"], "severity": "warn" },
    { "titles": ["空白原因"], "reason": "   " },
    { "reason": "既无标题也无 exe" },
    "not-an-object"
  ]
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = FontCompatibilityService.instance;

  setUp(svc.resetForTest);
  tearDown(svc.resetForTest);

  group('解析与计数', () {
    test('有效条目计入；缺 reason / 无匹配键 / 非对象的被忽略', () {
      svc.seedFromJsonForTest(_sample);
      expect(svc.entryCount, 3);
      expect(svc.isEmpty, isFalse);
      expect(svc.damaged, isFalse);
    });

    test('空对象 → 0 条，且不标记 damaged', () {
      svc.seedFromJsonForTest('{}');
      expect(svc.entryCount, 0);
      expect(svc.isEmpty, isTrue);
      expect(svc.damaged, isFalse);
    });

    test('entries 非数组 → 0 条', () {
      svc.seedFromJsonForTest('{"entries":"not-a-list"}');
      expect(svc.entryCount, 0);
    });

    test('非法 JSON 不抛异常，且标记 damaged（按无清单处理）', () {
      expect(() => svc.seedFromJsonForTest('这不是 JSON {{{'), returnsNormally);
      expect(svc.entryCount, 0);
      expect(svc.damaged, isTrue);
    });
  });

  group('标题匹配（走 TitleCleaner.normalizeForCompare）', () {
    setUp(() => svc.seedFromJsonForTest(_sample));

    test('精确标题命中', () {
      expect(svc.lookup(title: '某移植作 Remastered'), isNotNull);
    });

    test('别名命中', () {
      expect(svc.lookup(title: '某移植作'), isNotNull);
    });

    test('全角字母命中（全半角折叠）', () {
      expect(svc.lookup(title: '某移植作ｒｅｍａｓｔｅｒｅｄ'), isNotNull);
    });

    test('前后空格与大小写不敏感', () {
      expect(svc.lookup(title: '  某移植作  REMASTERED '), isNotNull);
    });

    test('标点被忽略后仍命中', () {
      expect(svc.lookup(title: '某移植作-Remastered!!'), isNotNull);
    });

    test('未命中返回 null', () {
      expect(svc.lookup(title: '根本不存在的游戏'), isNull);
    });
  });

  group('exe 匹配（标题未命中时回退）', () {
    setUp(() => svc.seedFromJsonForTest(_sample));

    test('标题未命中 → 回退 exe 命中', () {
      expect(
        svc.lookup(title: '毫不相干的标题', exeName: 'onlyexe.exe'),
        isNotNull,
      );
    });

    test('带路径 + 大小写不敏感', () {
      expect(svc.lookup(exeName: r'D:\games\some\SomeGame.EXE'), isNotNull);
    });

    test('未知 exe → null；两参数都空 → null', () {
      expect(svc.lookup(exeName: 'other.exe'), isNull);
      expect(svc.lookup(), isNull);
    });
  });

  group('severity 与字段透传', () {
    setUp(() => svc.seedFromJsonForTest(_sample));

    test('warn 条目 isWarning=true，reason/doc 透传', () {
      final v = svc.lookup(title: '某移植作');
      expect(v, isNotNull);
      expect(v!.isWarning, isTrue);
      expect(v.reason, contains('字体缓存'));
      expect(v.doc, startsWith('https://'));
    });

    test('info 条目 isWarning=false', () {
      final v = svc.lookup(title: '仅提示的作品');
      expect(v, isNotNull);
      expect(v!.isWarning, isFalse);
    });
  });

  group('FontCompatEntry.fromJson 边界', () {
    test('缺 reason → null', () {
      expect(FontCompatEntry.fromJson({'titles': ['x']}), isNull);
    });

    test('reason 为空串 / 空白 → null', () {
      expect(FontCompatEntry.fromJson({'titles': ['x'], 'reason': ''}), isNull);
      expect(
          FontCompatEntry.fromJson({'titles': ['x'], 'reason': '  '}), isNull);
    });

    test('titles 与 exes 都空 → null', () {
      expect(FontCompatEntry.fromJson({'reason': 'r'}), isNull);
      expect(
          FontCompatEntry.fromJson(
              {'reason': 'r', 'titles': [], 'exes': []}),
          isNull);
    });

    test('非 Map → null', () {
      expect(FontCompatEntry.fromJson('str'), isNull);
      expect(FontCompatEntry.fromJson(123), isNull);
      expect(FontCompatEntry.fromJson(null), isNull);
    });

    test('severity 缺省 → warn；显式 info → info', () {
      final a = FontCompatEntry.fromJson({'titles': ['x'], 'reason': 'r'});
      expect(a!.severity, FontCompatSeverity.warn);
      final b = FontCompatEntry.fromJson(
          {'titles': ['x'], 'reason': 'r', 'severity': 'INFO'});
      expect(b!.severity, FontCompatSeverity.info);
    });
  });
}
