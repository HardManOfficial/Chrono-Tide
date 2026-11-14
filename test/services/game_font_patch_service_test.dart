// game_font_patch_service_test.dart
// 「游戏字体替换」部署层回归测试（2026-10-17）。
//
// 全部在临时目录里做，不碰任何真实游戏目录。
// 覆盖：载荷部署、PE 架构识别、安装/还原往返、备份与还原语义、
//       守卫（已装/运行中/架构未知）、配置读写、与原工具互认、
//       game.json 的 font_override 在「重新入库」下不被清空。
//
// 路径隔离：PathHelper.exeDirOverride 必须在任何路径 getter 首次解析前设置。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/models/game_font_override.dart';
import 'package:chrono_tide/services/font_hook_ini_codec.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/services/game_font_patch_service.dart';

/// 造一个最小的合法 PE 文件头（够 `detectPeArchFromHeader` 读出 machine）。
List<int> minimalPe(int machine) {
  final b = List<int>.filled(1024, 0);
  b[0] = 0x4D; // 'M'
  b[1] = 0x5A; // 'Z'
  b[0x3C] = 0x40; // e_lfanew → 0x40
  b[0x40] = 0x50; // 'P'
  b[0x41] = 0x45; // 'E'
  b[0x42] = 0x00;
  b[0x43] = 0x00;
  b[0x44] = machine & 0xFF; // Machine
  b[0x45] = (machine >> 8) & 0xFF;
  return b;
}

void main() {
  late Directory appRoot;
  late Directory payloadDist;

  setUpAll(() {
    appRoot = Directory.systemTemp.createTempSync('ct_fonthook_app_');
    PathHelper.exeDirOverride = appRoot.path;

    // 造一个「CTFontHook 发布包」形态的载荷源
    payloadDist =
        Directory(p.join(appRoot.path, 'dist', 'CTFontHook-9.9.9-20260101-0000'))
          ..createSync(recursive: true);
    for (final sub in ['32bit', '64bit']) {
      final f = File(p.join(payloadDist.path, sub, 'winmm.dll'));
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(List<int>.filled(sub == '32bit' ? 128 : 256, 0xAB));
    }
  });

  tearDownAll(() {
    PathHelper.exeDirOverride = null;
    try {
      if (appRoot.existsSync()) appRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    // 每个用例都从干净的载荷目录开始
    final dir = Directory(PathHelper.fontHookDir);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    GameFontPatchService.resetPayloadCache();
  });

  Directory newGame({int arch = 0x8664, bool withExe = true}) {
    final d = Directory(p.join(appRoot.path, 'Games',
        'g_${DateTime.now().microsecondsSinceEpoch}'))
      ..createSync(recursive: true);
    if (withExe) {
      File(p.join(d.path, 'game.exe')).writeAsBytesSync(minimalPe(arch));
    }
    return d;
  }

  group('载荷部署与定位', () {
    test('未部署时报「未就绪」且 install 抛可读异常', () async {
      final s = GameFontPatchService.payloadStatus(refresh: true);
      // 开发态可能回退到真实 dist（本机存在）；只断言「未就绪时 message 可读」
      expect(s.ready, isFalse, reason: '测试环境不应命中开发态回退');
      expect(s.message, isNotEmpty);
      final g = newGame();
      await expectLater(
        GameFontPatchService.install(g.path,
            exePath: p.join(g.path, 'game.exe')),
        throwsA(isA<FontPatchException>()),
      );
    });

    test('preparePayloadFrom ⇒ 就绪 + 生成 version.json（含 size/sha256）', () async {
      final s =
          await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      expect(s.ready, isTrue);
      expect(s.version, '9.9.9');

      expect(File(PathHelper.fontHookDll32Path).existsSync(), isTrue);
      expect(File(PathHelper.fontHookDll64Path).existsSync(), isTrue);
      expect(File(PathHelper.fontHookDll32Path).lengthSync(), 128);
      expect(File(PathHelper.fontHookDll64Path).lengthSync(), 256);

      final vj = jsonDecode(
          File(PathHelper.fontHookVersionFilePath).readAsStringSync());
      expect(vj['upstream'], 'CTFontHook');
      expect(vj['license'], 'MIT');
      expect(vj['dll']['32bit']['size'], 128);
      expect(vj['dll']['64bit']['sha256'], hasLength(64));
    });

    test('载荷缺少某个架构 ⇒ 抛异常（不静默降级）', () async {
      final bad = Directory(p.join(appRoot.path, 'dist_bad'))
        ..createSync(recursive: true);
      File(p.join(bad.path, '32bit', 'winmm.dll'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1]);
      await expectLater(
        GameFontPatchService.preparePayloadFrom(bad.path),
        throwsA(isA<FontPatchException>()),
      );
    });
  });

  group('PE 架构识别（只读文件头）', () {
    test('32/64 位识别正确', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final x64 = newGame(arch: 0x8664);
      final x86 = newGame(arch: 0x014C);
      expect(
          GameFontPatchService.detectPeArchFromHeader(
              p.join(x64.path, 'game.exe')),
          PeArch.x64);
      expect(
          GameFontPatchService.detectPeArchFromHeader(
              p.join(x86.path, 'game.exe')),
          PeArch.x86);
    });

    test('非 PE / 不存在的文件 ⇒ unknown', () {
      final d = newGame(withExe: false);
      final txt = File(p.join(d.path, 'nope.txt'))..writeAsStringSync('hello');
      expect(GameFontPatchService.detectPeArchFromHeader(txt.path),
          PeArch.unknown);
      expect(GameFontPatchService.detectPeArchFromHeader(p.join(d.path, 'x.exe')),
          PeArch.unknown);
    });

    test('archSubDir 映射', () {
      expect(GameFontPatchService.archSubDir(PeArch.x86), '32bit');
      expect(GameFontPatchService.archSubDir(PeArch.x64), '64bit');
      expect(GameFontPatchService.archSubDir(PeArch.unknown), '');
    });
  });

  group('安装 / 探测 / 还原 往返', () {
    test('从未安装 → 安装 → 状态为 installedByUs → 还原', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame();
      final exe = p.join(g.path, 'game.exe');

      expect(GameFontPatchService.probe(g.path).state,
          PatchState.notInstalled);

      final after = await GameFontPatchService.install(g.path, exePath: exe);
      expect(after.state, PatchState.installedByUs);
      expect(after.winmmPresent, isTrue);
      expect(after.manifest!.dllArch, '64bit');
      expect(after.manifest!.managedByUs, isTrue);

      // 投放的确实是 64bit 载荷
      expect(File(p.join(g.path, 'winmm.dll')).lengthSync(), 256);
      // manifest 是 UTF-16LE + BOM
      final mf = File(p.join(g.path, '.CTFontHook', 'manifest.ini'));
      final raw = mf.readAsBytesSync();
      expect(raw[0], 0xFF);
      expect(raw[1], 0xFE);

      final removed = await GameFontPatchService.uninstall(g.path);
      expect(removed.state, PatchState.notInstalled);
      expect(File(p.join(g.path, 'winmm.dll')).existsSync(), isFalse);
      expect(Directory(p.join(g.path, '.CTFontHook')).existsSync(), isFalse);
    });

    test('原本已有 winmm.dll ⇒ 备份并在还原时恢复原文件；FontHook.ini 无则保留', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame();
      final exe = p.join(g.path, 'game.exe');
      final originalDll = List<int>.filled(7, 0x11);
      File(p.join(g.path, 'winmm.dll')).writeAsBytesSync(originalDll);
      await GameFontPatchService.writeConfig(g.path,
          const GameFontOverride(enabled: true, fontName: 'SimSun'));

      final r = await GameFontPatchService.install(g.path, exePath: exe);
      expect(r.manifest!.hadWinmm, isTrue);
      expect(r.manifest!.hadIni, isTrue);
      // 备份存在
      expect(
          File(p.join(g.path, '.CTFontHook', 'backup', 'winmm.dll'))
              .existsSync(),
          isTrue);

      // 还原
      await GameFontPatchService.uninstall(g.path);
      expect(File(p.join(g.path, 'winmm.dll')).readAsBytesSync(), originalDll);
      // hadIni=true ⇒ FontHook.ini 从备份还原（内容与安装前一致）
      expect(File(p.join(g.path, 'FontHook.ini')).existsSync(), isTrue);
    });

    test('原本没有 FontHook.ini ⇒ 还原后 ini 被保留（内含玩家设置）', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame();
      final exe = p.join(g.path, 'game.exe');

      await GameFontPatchService.install(g.path, exePath: exe);
      expect(GameFontPatchService.probe(g.path).manifest!.hadIni, isFalse);
      // 装完后写一份配置（模拟用户设置）
      await GameFontPatchService.writeConfig(g.path,
          const GameFontOverride(enabled: true, fontName: 'SimSun'));
      expect(File(p.join(g.path, 'FontHook.ini')).existsSync(), isTrue);

      await GameFontPatchService.uninstall(g.path);
      // winmm.dll 移除，但 ini 保留
      expect(File(p.join(g.path, 'winmm.dll')).existsSync(), isFalse);
      expect(File(p.join(g.path, 'FontHook.ini')).existsSync(), isTrue);
    });

    test('已安装时重复安装被拒（与原工具同语义）', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame();
      final exe = p.join(g.path, 'game.exe');
      await GameFontPatchService.install(g.path, exePath: exe);
      await expectLater(
        GameFontPatchService.install(g.path, exePath: exe),
        throwsA(isA<FontPatchException>()),
      );
    });

    test('架构未知 ⇒ 拒绝安装', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame(withExe: false);
      final notPe = File(p.join(g.path, 'bad.exe'))..writeAsStringSync('nope');
      await expectLater(
        GameFontPatchService.install(g.path, exePath: notPe.path),
        throwsA(isA<FontPatchException>()),
      );
    });

    test('无安装记录时还原被拒', () async {
      final g = newGame();
      await expectLater(
        GameFontPatchService.uninstall(g.path),
        throwsA(isA<FontPatchException>()),
      );
    });

    test('有 manifest 但 winmm.dll 缺失 ⇒ staleOrDamaged', () async {
      await GameFontPatchService.preparePayloadFrom(payloadDist.path);
      final g = newGame();
      final exe = p.join(g.path, 'game.exe');
      await GameFontPatchService.install(g.path, exePath: exe);

      // 模拟「游戏更新覆盖掉了 DLL」
      File(p.join(g.path, 'winmm.dll')).deleteSync();
      expect(GameFontPatchService.probe(g.path).state,
          PatchState.staleOrDamaged);
    });
  });

  group('与原工具互认', () {
    test('原工具装的（无 ManagedBy）⇒ installedByExternal，且可被我们还原', () async {
      final g = newGame();
      // 按 CTFontHook 的 WriteManifest 口径手工造一份安装
      final bakDir = Directory(p.join(g.path, '.CTFontHook', 'backup'))
        ..createSync(recursive: true);
      File(p.join(g.path, 'winmm.dll')).writeAsBytesSync(List<int>.filled(64, 1));
      final manifest = [
        '[CTFontHook]',
        'InstalledAt=2026-01-01 00:00:00',
        'DllArch=64bit',
        'HadWinmm=0',
        'HadIni=0',
      ].join('\r\n');
      File(p.join(bakDir.path, 'manifest.ini'))
          .writeAsBytesSync([0xFF, 0xFE, ...FontHookIniCodec.utf16leEncode(manifest)]);

      final r = GameFontPatchService.probe(g.path);
      expect(r.state, PatchState.installedByExternal);
      expect(r.manifest!.managedByUs, isFalse);
      expect(r.detail, contains('CTFontHook'));

      // 我们能还原它
      await GameFontPatchService.uninstall(g.path);
      expect(File(p.join(g.path, 'winmm.dll')).existsSync(), isFalse);
      expect(Directory(p.join(g.path, '.CTFontHook')).existsSync(), isFalse);
    });
  });

  group('配置读写', () {
    test('writeConfig → readConfig 往返；PickerShowOnStartup 落盘为 0', () async {
      final g = newGame();
      const cfg = GameFontOverride(
          enabled: true, fontName: 'Microsoft YaHei', charset: FontCharset.gb2312);
      await GameFontPatchService.writeConfig(g.path, cfg);

      final ini = File(p.join(g.path, 'FontHook.ini'));
      final text =
          FontHookIniCodec.decodeWithBomStripped(ini.readAsBytesSync());
      expect(FontHookIniCodec.parseEntries(text)['PickerShowOnStartup'], '0');

      final back = GameFontPatchService.readConfig(g.path)!;
      expect(back.enabled, isTrue);
      expect(back.fontName, 'Microsoft YaHei');
      expect(back.charset, FontCharset.gb2312);
    });

    test('fontName 为空 ⇒ 拒绝写盘（空 FontNameW 会让配置整体失效）', () async {
      final g = newGame();
      await expectLater(
        GameFontPatchService.writeConfig(
            g.path, const GameFontOverride(enabled: true)),
        throwsA(isA<FontPatchException>()),
      );
    });

    test('readConfig：无 ini / 缺 FontNameW ⇒ null（不覆盖原文件）', () async {
      final g = newGame();
      expect(GameFontPatchService.readConfig(g.path), isNull);
      File(p.join(g.path, 'FontHook.ini'))
          .writeAsStringSync('[FontHook]\nEnableFontHook=1\n');
      expect(GameFontPatchService.readConfig(g.path), isNull);
    });

    test('写配置时保留游戏内面板加的高级键（读-改-写）', () async {
      final g = newGame();
      File(p.join(g.path, 'FontHook.ini')).writeAsStringSync('[FontHook]\n'
          'FontNameW=Old\n'
          'EnableFontHook=1\n'
          'EnableCodepageSpoof=1\n'
          'SpoofCodepage=932\n');
      await GameFontPatchService.writeConfig(
          g.path, const GameFontOverride(enabled: true, fontName: 'New'));
      final e = FontHookIniCodec.parseEntries(
          File(p.join(g.path, 'FontHook.ini')).readAsStringSync());
      expect(e['FontNameW'], 'New');
      expect(e['EnableCodepageSpoof'], '1');
      expect(e['SpoofCodepage'], '932');
    });
  });

  group('game.json 的 font_override 持久化（🔴 不进 _overwritableFields）', () {
    test('重新入库（writeGameDir）不会清空 font_override', () async {
      final dir = Directory(p.join(PathHelper.gamesDir, 'persist_test'))
        ..createSync(recursive: true);
      const cfg = GameFontOverride(
          enabled: true, fontName: 'SimSun', dllArch: '64bit', managedByUs: true);
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'format_version': 4,
        'title': '旧标题',
        'play_time': 3600,
        'font_override': cfg.toJson(),
      }));

      await GameDataFormat.writeGameDir(targetDir: dir.path, title: '新标题');

      final j = jsonDecode(File(p.join(dir.path, 'game.json')).readAsStringSync())
          as Map<String, dynamic>;
      expect(j['title'], '新标题'); // 本次导入字段生效
      expect(j['font_override'], isNotNull); // 🔴 用户状态保留
      final back = GameFontOverride.fromJson(
          Map<String, dynamic>.from(j['font_override'] as Map));
      expect(back.enabled, isTrue);
      expect(back.fontName, 'SimSun');
      expect(back.dllArch, '64bit');
    });

    test('GameJsonData 往返：font_override 一致；缺失时为 null 且不输出键', () {
      const cfg = GameFontOverride(enabled: true, fontName: 'SimSun');
      final d = GameJsonData(
        formatVersion: 4,
        title: 'x',
        fontOverride: cfg.toJson(),
      );
      final back = GameJsonData.fromJson(d.toJson());
      expect(back.fontOverride, isNotNull);
      expect(GameFontOverride.fromJson(back.fontOverride).fontName, 'SimSun');

      final empty = GameJsonData(formatVersion: 4, title: 'y');
      expect(empty.toJson().containsKey('font_override'), isFalse);
    });

    test('老 game.json（无 font_override 键）读取不破坏原内容', () async {
      final dir = Directory(p.join(PathHelper.gamesDir, 'legacy_test'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'game.json')).writeAsStringSync(jsonEncode({
        'format_version': 4,
        'title': '老游戏',
        'play_time': 120,
      }));
      await GameDataFormat.writeGameDir(targetDir: dir.path, title: '老游戏');
      final j = jsonDecode(File(p.join(dir.path, 'game.json')).readAsStringSync())
          as Map<String, dynamic>;
      expect(j['play_time'], 120);
      expect(j.containsKey('font_override'), isFalse);
    });
  });
}
