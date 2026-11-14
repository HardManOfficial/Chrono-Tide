// 启动程序智能推荐 · 真机验证探针（LAUNCH-RECOMMEND）
//
// 为什么是"裸 Dart VM"而不是 flutter_tester：
// `lib/services/launcher_candidate_analyzer.dart` **只依赖 dart:io**，
// 因此可以直接用 dart.exe 跑真实业务代码（非复刻），无需 gen_kernel_aot +
// flutter_tester 那一套。231（ERROR_PIPE_BUSY）环境下 `flutter test` 不可用，
// 本探针是唯一能真正执行代码的通道。
//
// 运行（在 D:\CTLIB 下）：
//   ./flutter/bin/cache/dart-sdk/bin/dart.exe \
//     --packages="D:/CTLIB/.dart_tool/package_config.json" \
//     dev_probe/launcher_recommend_probe.dart
//
// 覆盖两部分：
//   A. 规则表逐条断言（纯 classify，不碰磁盘）
//   B. 端到端：现场造一个真实目录树（含合法 PE 头桩文件）跑 analyzeSync

import 'dart:io';
import 'dart:typed_data';

import 'package:chrono_tide/services/launcher_candidate_analyzer.dart';

int _pass = 0;
int _fail = 0;

void expect(String name, Object? actual, Object? expected) {
  if ('$actual' == '$expected') {
    _pass++;
  } else {
    _fail++;
    stdout.writeln('[FAIL] $name -> 实际=$actual 期望=$expected');
  }
}

const String _dir = r'D:\G\Softhouse';

LauncherCandidate classify(
  String fileName, {
  int size = 2 * 1024 * 1024,
  int depth = 0,
  int res = 0,
  String title = '',
  List<String> aliases = const <String>[],
  String gameDirectory = _dir,
  String? path,
}) {
  return LauncherCandidateAnalyzer.classify(
    path: path ?? '$gameDirectory\\$fileName',
    fileName: fileName,
    sizeBytes: size,
    depth: depth,
    resourceFilesInDir: res,
    gameDirectory: gameDirectory,
    gameTitle: title,
    gameAliases: aliases,
  );
}

void main() {
  _ruleChecks();
  _endToEnd();
  stdout.writeln('');
  stdout.writeln('RESULT: $_pass passed, $_fail failed');
  stdout.writeln(_fail == 0 ? 'PASS ✅' : 'FAIL ❌');
  exit(_fail == 0 ? 0 : 1);
}

void _ruleChecks() {
  // ---- 汉化标记：粘连与整 token 两种粒度 ----
  final chs = classify('SofthouseChs.exe', title: 'Softhouse');
  expect('CHS 粘连 → 汉化', chs.isLocalized, true);
  expect('CHS 粘连 → 游戏相关', chs.isGame, true);

  expect('_CN 分隔 → 汉化', classify('Softhouse_CN.exe').isLocalized, true);
  expect('CN 粘连 → 汉化', classify('SofthouseCN.exe').isLocalized, true);

  // 🔴 核心边界：`sc` 是 scene / disc 的子串，绝不能做子串匹配
  expect('scene 不判汉化', classify('scene.exe', size: 3 << 20).isLocalized, false);
  expect('disc 不判汉化', classify('disc.exe', size: 3 << 20).isLocalized, false);
  // 🔴 `cht` 同理（yacht 里含 cht）
  expect('yacht 不判汉化', classify('yacht.exe', size: 3 << 20).isLocalized, false);

  // ---- 中文文件名 ----
  final cnStarter = classify('启动游戏.exe', title: '野良与皇女与流浪猫之心');
  expect('中文启动词 → 汉化', cnStarter.isLocalized, true);
  expect('中文启动词 → 游戏相关', cnStarter.isGame, true);
  expect('中文启动词 → 版本标签', cnStarter.versionLabel, '汉化版');

  // 🔴 关键边界：日文原名也是汉字开头，必须靠假名排除
  final jp = classify('恋愛零キロメートル.exe', size: 3 << 20);
  expect('假名文件名不判汉化', jp.isLocalized, false);
  expect('假名文件名 → 日文版', jp.versionLabel, '日文版');

  // ---- 与游戏标题关联 ----
  final exact = classify('野良与皇女与流浪猫之心.exe', title: '野良与皇女与流浪猫之心');
  expect('名字 == 标题', exact.reasons.contains('与游戏标题一致'), true);
  final prefix = classify('野良与皇女与流浪猫之心CN.exe', title: '野良与皇女与流浪猫之心');
  expect('标题 + CN 后缀 → 汉化', prefix.isLocalized, true);
  expect('标题 + CN 后缀 → 游戏相关', prefix.isGame, true);

  // ---- 无关程序 ----
  expect(
      'unins000 → 无关', classify('unins000.exe', size: 200 << 10).isTool, true);
  expect('vcredist → 无关', classify('vcredist_x64.exe', size: 3 << 20).isTool,
      true);
  expect('DXSETUP → 无关', classify('DXSETUP.exe', size: 3 << 20).isTool, true);
  expect('setup → 无关', classify('setup.exe').isTool, true);
  expect('config → 无关', classify('config.exe', size: 900 << 10).isTool, true);
  expect('cg回収 → 无关', classify('cg回収.exe', size: 700 << 10).isTool, true);
  expect(
      '小体积通用名不推荐', classify('Game.exe', size: 100 << 10, res: 0).isTool, true);

  // 🔴 补丁器只在「小体积」时减分：3MB 以上的 *patch.exe 是打过补丁的本体
  expect('小体积汉化补丁 → 无关', classify('汉化补丁.exe', size: 200 << 10, depth: 1).isTool,
      true);
  expect('小体积 patch → 无关', classify('patch.exe', size: 1 << 20).isTool, true);
  expect('大体积 patch → 游戏相关', classify('patch.exe', size: 5 << 20).isGame, true);

  // ---- 运行库目录一票否决 ----
  expect(
    '位于 _CommonRedist 下 → 无关',
    classify(
      'vcredist_x64.exe',
      path: r'D:\G\Softhouse\_CommonRedist\DirectX\dxsetup.exe',
      size: 3 << 20,
    ).isTool,
    true,
  );
  expect(
    '位于 redist 子目录 → 无关',
    classify(
      'weird.exe',
      path: r'D:\G\Softhouse\redist\weird.exe',
      size: 3 << 20,
    ).isTool,
    true,
  );

  // ---- 版本标签 ----
  expect('HD 分隔 → HD 版', classify('Softhouse_HD.exe').versionLabel, 'HD 版');
  expect('HD 粘连 → HD 版', classify('SofthouseHD.exe').versionLabel, 'HD 版');
  expect('汉化 + HD → 组合标签', classify('Softhouse_HD_CHS.exe').versionLabel,
      '汉化 HD 版');
  expect('无标记 → 原版', classify('Softhouse.exe').versionLabel, '原版');
  expect('魔改标记 → 魔改版', classify('Softhouse_mod.exe').versionLabel, '魔改版');

  // ---- 引擎名 / 资源同目录 ----
  final engine = classify('SiglusEngine.exe', size: 2 << 20, res: 5);
  expect('引擎名 → 游戏相关', engine.isGame, true);
  expect('引擎名 + 根目录 + 体积 + 资源 → 够推荐分',
      engine.score >= LauncherCandidateAnalyzer.recommendMinScore, true);

  // ---- 目录深度 ----
  final deep = classify('Softhouse.exe', depth: 2);
  final root = classify('Softhouse.exe', depth: 0);
  expect('深层目录分数更低', deep.score < root.score, true);
}

void _endToEnd() {
  final root = Directory(r'D:\CTLIB\.workbuddy\tmp\launcher_probe\Softhouse');
  if (root.existsSync()) {
    root.deleteSync(recursive: true);
  }
  root.createSync(recursive: true);

  final gameDir = root.path;

  // 本体三兄弟 + 工具若干 + 运行库目录
  _writePe('$gameDir\\Softhouse.exe', size: 1200 * 1024);
  _writePe('$gameDir\\SofthouseChs.exe', size: 1250 * 1024);
  _writePe('$gameDir\\SofthouseHD.exe', size: 1300 * 1024);
  _writePe('$gameDir\\config.exe', size: 700 * 1024);
  _writePe('$gameDir\\cg回収.exe', size: 600 * 1024);
  _writePe('$gameDir\\vcredist_x64.exe', size: 2600 * 1024);
  _writePe('$gameDir\\_CommonRedist\\DirectX\\DXSETUP.exe', size: 1800 * 1024);
  _writePe('$gameDir\\patch\\汉化补丁.exe', size: 200 * 1024);
  // 非 PE 的假 exe（0 字节 / 纯文本）：必须判无效
  File('$gameDir\\broken.exe').writeAsStringSync('not a real exe');

  // 三个资源文件，触发 E5「同目录有游戏资源」
  for (final name in ['data.xp3', 'bgm.xp3', 'voice.xp3']) {
    File('$gameDir\\$name').writeAsBytesSync(Uint8List(16));
  }

  final files = <File>[];
  for (final entity in Directory(gameDir).listSync(recursive: true)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.exe')) {
      files.add(entity);
    }
  }
  expect('端到端：扫到 9 个 exe', files.length, 9);

  final analysis = LauncherCandidateAnalyzer.analyzeSync(
    files: files,
    gameDirectory: gameDir,
    gameTitle: 'Softhouse',
    gameAliases: const <String>['ソフトハウス / Softhouse'],
  );

  final recommended = analysis.recommended;
  expect('端到端：有唯一推荐', recommended != null, true);
  expect(
    '端到端：推荐汉化版而非 HD/原版',
    recommended?.fileName,
    'SofthouseChs.exe',
  );
  expect('端到端：推荐项 PE 有效', recommended?.peValid, true);
  expect('端到端：推荐项架构标签', recommended?.archLabel, '32 位');

  expect(
      '端到端：HD 版被识别', analysis.forPath('$gameDir\\SofthouseHD.exe')?.isHd, true);
  expect('端到端：原版标签', analysis.forPath('$gameDir\\Softhouse.exe')?.versionLabel,
      '原版');
  expect(
      '端到端：config 判无关', analysis.forPath('$gameDir\\config.exe')?.isTool, true);
  expect('端到端：cg回収 判无关', analysis.forPath('$gameDir\\cg回収.exe')?.isTool, true);
  expect('端到端：vcredist 判无关',
      analysis.forPath('$gameDir\\vcredist_x64.exe')?.isTool, true);
  expect(
      '端到端：_CommonRedist 下判无关',
      analysis.forPath('$gameDir\\_CommonRedist\\DirectX\\DXSETUP.exe')?.isTool,
      true);
  expect('端到端：汉化补丁判无关', analysis.forPath('$gameDir\\patch\\汉化补丁.exe')?.isTool,
      true);
  expect(
      '端到端：损坏 exe 判无关', analysis.forPath('$gameDir\\broken.exe')?.isTool, true);

  // 顺序不变量：分析不得改变输入顺序
  expect('端到端：候选顺序与输入一致', analysis.candidates.first.path == files.first.path,
      true);

  // 只有一个推荐
  final recommendedCount =
      analysis.candidates.where((c) => analysis.isRecommended(c.path)).length;
  expect('端到端：角标只标 1 个', recommendedCount, 1);

  // 清理（可还原无需回收站，这是探针自建的目录）
  try {
    root.deleteSync(recursive: true);
  } catch (_) {}
}

void _writePe(String path, {required int size, int machine = 0x014C}) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final bytes = Uint8List(size < 4096 ? 4096 : size);
  bytes[0] = 0x4D; // M
  bytes[1] = 0x5A; // Z
  const peOffset = 0x40;
  final data = ByteData.sublistView(bytes);
  data.setUint32(0x3C, peOffset, Endian.little);
  bytes[peOffset] = 0x50; // P
  bytes[peOffset + 1] = 0x45; // E
  bytes[peOffset + 2] = 0x00;
  bytes[peOffset + 3] = 0x00;
  data.setUint16(peOffset + 4, machine, Endian.little);
  file.writeAsBytesSync(bytes);
}
