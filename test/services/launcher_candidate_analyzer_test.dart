// 启动程序智能推荐 · 判定规则测试（LAUNCH-RECOMMEND，2026-10-26）
//
// 只测纯规则入口 `LauncherCandidateAnalyzer.classify`（不碰文件系统），
// 端到端（真目录 + PE 头桩文件）由 `dev_probe/launcher_recommend_probe.dart` 覆盖。
//
// ⚠️ 本机 `flutter test` 因 ERROR_PIPE_BUSY(231) 不可用，本文件写完但**尚未执行**；
//    同一批断言已在探针里以裸 Dart VM 跑过（50/50 PASS），两者口径一致。

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/launcher_candidate_analyzer.dart';

void main() {
  const gameDir = r'D:\G\Softhouse';
  const mb = 1024 * 1024;

  LauncherCandidate classify(
    String fileName, {
    int size = 2 * mb,
    int depth = 0,
    int res = 0,
    String title = '',
    List<String> aliases = const <String>[],
    String? path,
  }) =>
      LauncherCandidateAnalyzer.classify(
        path: path ?? '$gameDir\\$fileName',
        fileName: fileName,
        sizeBytes: size,
        depth: depth,
        resourceFilesInDir: res,
        gameDirectory: gameDir,
        gameTitle: title,
        gameAliases: aliases,
      );

  group('汉化标记：匹配粒度', () {
    test('CHS 与文件名粘连', () {
      expect(classify('SofthouseChs.exe').isLocalized, isTrue);
    });

    test('_CN 分隔符形态', () {
      expect(classify('Softhouse_CN.exe').isLocalized, isTrue);
    });

    test('CN 直接粘连', () {
      expect(classify('SofthouseCN.exe').isLocalized, isTrue);
    });

    test('中文「汉化」直接命中', () {
      expect(classify('Softhouse汉化版.exe').isLocalized, isTrue);
    });

    // 🔴 核心边界：短标记只做「整 token 相等」，绝不做子串匹配
    test('scene 不因含 sc 被判汉化', () {
      expect(classify('scene.exe', size: 3 * mb).isLocalized, isFalse);
    });

    test('disc 不因含 sc 被判汉化', () {
      expect(classify('disc.exe', size: 3 * mb).isLocalized, isFalse);
    });

    test('yacht 不因含 cht 被判汉化', () {
      expect(classify('yacht.exe', size: 3 * mb).isLocalized, isFalse);
    });
  });

  group('中文文件名与日文汉字的区分', () {
    test('中文启动词 → 汉化版且判为游戏相关', () {
      final c = classify('启动游戏.exe', title: '野良与皇女与流浪猫之心');
      expect(c.isLocalized, isTrue);
      expect(c.isGame, isTrue);
      expect(c.versionLabel, '汉化版');
    });

    // 🔴 日文原名同样以汉字开头，必须靠假名排除
    test('含假名的日文名不判汉化', () {
      final c = classify('恋愛零キロメートル.exe', size: 3 * mb);
      expect(c.isLocalized, isFalse);
      expect(c.versionLabel, '日文版');
    });
  });

  group('与游戏标题/目录名的关联', () {
    test('名字完全等于标题', () {
      final c = classify('野良与皇女与流浪猫之心.exe', title: '野良与皇女与流浪猫之心');
      expect(c.reasons.contains('与游戏标题一致'), isTrue);
      expect(c.isGame, isTrue);
    });

    test('标题 + 短后缀（CN）', () {
      final c = classify('野良与皇女与流浪猫之心CN.exe', title: '野良与皇女与流浪猫之心');
      expect(c.isLocalized, isTrue);
      expect(c.isGame, isTrue);
    });

    test('与目录名同名', () {
      final c = classify('Softhouse.exe');
      expect(c.reasons.contains('与游戏目录同名'), isTrue);
    });

    test('别名重合（副标题为 / 拼接串时自动拆分）', () {
      final c = classify('Softhouse.exe',
          aliases: const <String>['ソフトハウス / Softhouse']);
      expect(c.reasons.any((r) => r.startsWith('与别名')), isTrue);
    });
  });

  group('无关程序识别', () {
    test('unins000 卸载器', () {
      expect(classify('unins000.exe', size: 200 * 1024).isTool, isTrue);
    });

    test('vcredist 运行库', () {
      expect(classify('vcredist_x64.exe', size: 3 * mb).isTool, isTrue);
    });

    test('DXSETUP', () {
      expect(classify('DXSETUP.exe', size: 3 * mb).isTool, isTrue);
    });

    test('setup 安装包', () {
      expect(classify('setup.exe').isTool, isTrue);
    });

    test('config 配置工具', () {
      expect(classify('config.exe', size: 900 * 1024).isTool, isTrue);
    });

    test('cg 回収工具', () {
      expect(classify('cg回収.exe', size: 700 * 1024).isTool, isTrue);
    });

    test('小体积通用名不足以判为启动程序', () {
      expect(classify('Game.exe', size: 100 * 1024).isTool, isTrue);
    });

    // 🔴 补丁器只在「小体积」时减分：3MB 以上的 *patch.exe 是打过补丁的本体
    test('小体积汉化补丁 → 无关', () {
      expect(classify('汉化补丁.exe', size: 200 * 1024, depth: 1).isTool, isTrue);
    });

    test('小体积 patch → 无关', () {
      expect(classify('patch.exe', size: 1 * mb).isTool, isTrue);
    });

    test('大体积 patch → 游戏相关', () {
      expect(classify('patch.exe', size: 5 * mb).isGame, isTrue);
    });

    test('位于 _CommonRedist 下一票否决', () {
      final c = classify('dxsetup.exe',
          path: r'D:\G\Softhouse\_CommonRedist\DirectX\dxsetup.exe',
          size: 3 * mb);
      expect(c.isTool, isTrue);
      expect(c.reasons.contains('位于运行库/安装器目录'), isTrue);
    });

    test('位于 redist 子目录一票否决', () {
      final c = classify('weird.exe',
          path: r'D:\G\Softhouse\redist\weird.exe', size: 3 * mb);
      expect(c.isTool, isTrue);
    });
  });

  group('版本标签', () {
    test('HD 分隔标记', () {
      expect(classify('Softhouse_HD.exe').versionLabel, 'HD 版');
    });

    test('HD 粘连标记', () {
      expect(classify('SofthouseHD.exe').versionLabel, 'HD 版');
    });

    test('汉化 + HD 组合标签', () {
      expect(classify('Softhouse_HD_CHS.exe').versionLabel, '汉化 HD 版');
    });

    test('无标记 → 原版（互斥推断）', () {
      expect(classify('Softhouse.exe').versionLabel, '原版');
    });

    test('魔改标记', () {
      expect(classify('Softhouse_mod.exe').versionLabel, '魔改版');
    });
  });

  group('体积 / 目录深度的相对影响', () {
    test('引擎名 + 资源 + 根目录能过推荐门槛', () {
      final c = classify('SiglusEngine.exe', size: 2 * mb, res: 5);
      expect(c.isGame, isTrue);
      expect(c.score >= LauncherCandidateAnalyzer.recommendMinScore, isTrue);
    });

    test('同条件下深层目录分数更低', () {
      final deep = classify('Softhouse.exe', depth: 2);
      final root = classify('Softhouse.exe', depth: 0);
      expect(deep.score < root.score, isTrue);
    });

    test('同目录资源文件数提升分数', () {
      final withRes = classify('Softhouse.exe', res: 5);
      final noRes = classify('Softhouse.exe', res: 0);
      expect(withRes.score > noRes.score, isTrue);
    });
  });
}
