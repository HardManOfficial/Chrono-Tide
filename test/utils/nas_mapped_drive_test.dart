import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/services/game_data_format.dart';
import 'package:chrono_tide/utils/game_path_resolver.dart';
import 'package:chrono_tide/utils/network_path.dart';
import 'package:chrono_tide/utils/path_normalizer.dart';

/// NAS 映射网络驱动器适配单测（★ 2026-10-06；同日晚 方案 B 更新）。
///
/// 只断言**与运行机器无关**的纯逻辑：
/// - 长路径前缀剥离（`\\?\` / `\\?\UNC\`）
/// - 「双形态」存储规范化（方案 B：盘符/用户形态为主 + UNC 兜底）
/// - game.json 读写兼容（老数据 `\\?\UNC\` 读时归一、source_path 兼容）
/// - 解析器对本机必然不可用的路径返回 offline（不做真机网络断言）
/// - 解析器「盘符优先 / UNC 兜底」全流程：经 debugProbe /
///   debugDriveMapProvider / debugRemoteDrives 注入，无真实映射盘也可断言
///
/// 映射盘的真实行为（GetDriveTypeW / WNetGetUniversalNameW /
/// WNetGetConnectionW / resolveSymbolicLinksSync 的盘符→UNC 转换）
/// 依赖真实 NAS 环境，属真机走查范围，不在本文件断言。
void main() {
  group('PathNormalizer.forStore 剥长路径前缀（写入端根因修复）', () {
    test('剥离 resolveSymbolicLinksSync 可能产生的 \\\\?\\UNC\\ 前缀', () {
      expect(PathNormalizer.forStore(r'\\?\UNC\host\share\GAL\X'),
          r'\\host\share\GAL\X');
    });

    test('剥离 \\\\?\\ 盘符前缀', () {
      expect(PathNormalizer.forStore(r'\\?\C:\Games\X'), r'C:\Games\X');
    });

    test('无前缀路径恒等（本地语义不变）', () {
      expect(PathNormalizer.forStore(r'D:\Games\MyGame'), r'D:\Games\MyGame');
      expect(PathNormalizer.forStore(r'\\host\share\GAL\X'),
          r'\\host\share\GAL\X');
    });
  });

  group('GameDataFormat.normalizeStoredDirectory（存储双形态）', () {
    test('UNC 输入：directory = 原值，source 为空（无盘符形态可保留）', () {
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'\\host\share\GAL\X');
      expect(dir, r'\\host\share\GAL\X');
      expect(source, '');
    });

    test('历史脏数据 \\\\?\\UNC\\ 输入：归一为无前缀 UNC', () {
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'\\?\UNC\host\share\GAL\X');
      expect(dir, r'\\host\share\GAL\X');
      expect(source, '');
    });

    test('本地路径：directory 恒等，source 为空', () {
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'D:\Games\MyGame');
      expect(dir, r'D:\Games\MyGame');
      expect(source, '');
    });

    test('空输入返回空对', () {
      expect(GameDataFormat.normalizeStoredDirectory(''), ('', ''));
    });
  });

  group('GameJsonData 老数据兼容（读时归一，不回写）', () {
    test('directory_path 带历史 \\\\?\\UNC\\ 前缀 → 读出为无前缀 UNC', () {
      final data = GameJsonData.fromJson({
        'title': 't',
        'directory_path': r'\\?\UNC\192.168.5.11\share\GAL\X',
      });
      expect(data.directoryPath, r'\\192.168.5.11\share\GAL\X');
    });

    test('source_path 老文件无键 → 空串；有键 → 原样读出', () {
      final old = GameJsonData.fromJson({'title': 't'});
      expect(old.sourcePath, '');

      final neu = GameJsonData.fromJson({
        'title': 't',
        'directory_path': r'\\192.168.5.11\share\GAL\X',
        'source_path': r'Z:\GAL\X',
      });
      expect(neu.sourcePath, r'Z:\GAL\X');
    });

    test('toJson 仅在 source_path 非空时输出（老文件不加键）', () {
      final noSource = GameJsonData.fromJson({'title': 't'}).toJson();
      expect(noSource.containsKey('source_path'), isFalse);

      final withSource = GameJsonData.fromJson({
        'title': 't',
        'directory_path': r'\\192.168.5.11\share\GAL\X',
        'source_path': r'Z:\GAL\X',
      }).toJson();
      expect(withSource['source_path'], r'Z:\GAL\X');
      // 读时归一后的 directory_path 回写为规范形态（同路径，仅去前缀）
      expect(withSource['directory_path'], r'\\192.168.5.11\share\GAL\X');
    });
  });

  group('GamePathResolver（本机可判定场景）', () {
    setUp(() {
      GamePathResolver.debugClearCache();
    });

    test('空存储值 → offline 且提示未记录目录', () async {
      final view = await GamePathResolver.resolve(directoryPath: '');
      expect(view.state, GamePathState.offline);
      expect(view.accessPath, '');
      expect(view.statusText, contains('未记录'));
    });

    test('本地目录不存在 → offline（本地语义回归）', () async {
      final view = await GamePathResolver.resolve(
        directoryPath: r'C:\__ct_nonexistent_dir_9527__\game',
      );
      expect(view.isNetwork, isFalse);
      expect(view.state, GamePathState.offline);
      expect(view.accessPath, '');
      expect(view.statusText, contains('不存在'));
    });

    test('历史 \\\\?\\UNC\\ 形态参与解析时先剥前缀（display 不带畸形前缀）', () async {
      final view = await GamePathResolver.resolve(
        directoryPath: r'\\?\UNC\127.0.0.1\__ct_no_such_share_9527__\game',
      );
      // 本机必然没有该共享：displayPath 必须是无前缀 UNC 形态
      expect(view.displayPath, startsWith(r'\\127.0.0.1\'));
      expect(view.displayPath, isNot(startsWith(r'\\?\')));
      expect(view.isNetwork, isTrue);
      expect(view.state, GamePathState.offline);
      expect(view.statusText, isNotEmpty);
    });

    test('解析结果带缓存（同参数短时间二次调用返回同一实例）', () async {
      final a = await GamePathResolver.resolve(
        directoryPath: r'C:\__ct_nonexistent_dir_9527__\game',
      );
      final b = await GamePathResolver.resolve(
        directoryPath: r'C:\__ct_nonexistent_dir_9527__\game',
      );
      expect(identical(a, b), isTrue);
    });
  });

  // ════════════════════════════════════════════════════════════════
  // ★ 2026-10-06 方案 B：盘符形态为主、UNC 兜底。
  // 经注入钩子（debugProbe / debugDriveMapProvider / debugRemoteDrives /
  // debugDriveUncOverrides）构造映射盘场景，无需真实 NAS。
  // ════════════════════════════════════════════════════════════════
  group('方案 B：盘符为主形态（注入式）', () {
    setUp(() {
      NetworkPath.debugClearCaches();
      GamePathResolver.debugClearCache();
    });

    tearDown(() {
      NetworkPath.debugClearCaches();
      GamePathResolver.debugClearCache();
    });

    void fakeMapDrive() {
      NetworkPath.debugRemoteDrives = {'Z:'};
      NetworkPath.debugDriveUncOverrides = {r'Z:\': r'\\host\share'};
    }

    test('normalizeStoredDirectory：映射盘符导入 → directory 保留盘符，source = UNC', () {
      fakeMapDrive();
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'Z:\GAL\X');
      expect(dir, r'Z:\GAL\X', reason: '主形态必须是用户看到的盘符形态');
      expect(source, r'\\host\share\GAL\X', reason: '备形态必须是 UNC 真路径');
    });

    test('normalizeStoredDirectory：盘符反查不出 UNC（离线导入）→ source 空串', () {
      // 只声明 Z: 是网络盘，不注入 UNC 映射 → 真实 WNet 在本机必然失败
      NetworkPath.debugRemoteDrives = {'Z:'};
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'Z:\GAL\X');
      expect(dir, r'Z:\GAL\X');
      expect(source, '');
    });

    test('normalizeStoredDirectory：UNC 导入 → directory = UNC，source 空串', () {
      fakeMapDrive();
      final (dir, source) =
          GameDataFormat.normalizeStoredDirectory(r'\\host\share\GAL\X');
      expect(dir, r'\\host\share\GAL\X');
      expect(source, '', reason: '盘符形态由解析器运行时反查，不落盘');
    });

    test('解析器：盘符形态可用 → ok，display = access = 盘符路径', () async {
      NetworkPath.debugRemoteDrives = {'Z:'};
      GamePathResolver.debugProbe = (path, _) async => path == r'Z:\GAL\X';
      final view = await GamePathResolver.resolve(directoryPath: r'Z:\GAL\X');
      expect(view.state, GamePathState.ok);
      expect(view.displayPath, r'Z:\GAL\X');
      expect(view.accessPath, r'Z:\GAL\X');
      expect(view.statusText, '');
    });

    test('解析器：盘符不可用、UNC 可用 → uncFallback，display 仍盘符形态', () async {
      NetworkPath.debugRemoteDrives = {'Z:'};
      GamePathResolver.debugProbe = (path, _) async =>
          path == r'\\host\share\GAL\X';
      final view = await GamePathResolver.resolve(
        directoryPath: r'Z:\GAL\X',
        sourcePath: r'\\host\share\GAL\X',
      );
      expect(view.state, GamePathState.uncFallback);
      expect(view.displayPath, r'Z:\GAL\X', reason: '展示用户期望的盘符形态');
      expect(view.accessPath, r'\\host\share\GAL\X');
      expect(view.statusText, isNotEmpty);
    });

    test('解析器：老数据（directory=UNC）→ 反查盘符成功时以盘符形态访问', () async {
      NetworkPath.debugRemoteDrives = {'Z:'};
      GamePathResolver.debugDriveMapProvider =
          (root) => root.toLowerCase() == r'\\host\share' ? 'Z:' : null;
      GamePathResolver.debugProbe = (path, _) async => path == r'Z:\GAL\X';
      final view =
          await GamePathResolver.resolve(directoryPath: r'\\host\share\GAL\X');
      expect(view.state, GamePathState.ok);
      expect(view.accessPath, r'Z:\GAL\X');
    });

    test('解析器：纯 UNC 用户（无任何映射盘）→ ok 且不加噪音提示', () async {
      GamePathResolver.debugProbe =
          (path, _) async => path == r'\\host\share\GAL\X';
      final view =
          await GamePathResolver.resolve(directoryPath: r'\\host\share\GAL\X');
      expect(view.state, GamePathState.ok);
      expect(view.displayPath, r'\\host\share\GAL\X');
      expect(view.statusText, '');
    });

    test('解析器：全部候选失败 → offline；随后进入快速离线通道（不再探测）', () async {
      NetworkPath.debugRemoteDrives = {'Z:'};
      var probeCount = 0;
      GamePathResolver.debugProbe = (path, _) async {
        probeCount++;
        return false;
      };
      final view = await GamePathResolver.resolve(directoryPath: r'Z:\GAL\X');
      expect(view.state, GamePathState.offline);
      expect(view.displayPath, r'Z:\GAL\X', reason: '离线时展示用户形态');
      expect(view.accessPath, '');
      expect(view.statusText, contains('不可达'));
      final firstRound = probeCount;
      expect(firstRound, greaterThanOrEqualTo(2),
          reason: '全候选失败后必须还有一次短超时重试（防 NAS 唤醒误判）');

      // 换一个 cacheKey（带 source_path）绕开 8s 结果缓存，
      // 直接验证 15s 快速离线通道（结果缓存过期后用户也会走到这条路）。
      final view2 = await GamePathResolver.resolve(
        directoryPath: r'Z:\GAL\X',
        sourcePath: r'\\host\share\GAL\X',
      );
      expect(view2.state, GamePathState.offline);
      expect(view2.statusText, contains('刚探测失败'),
          reason: '快速离线通道的提示要与首次区分');
      expect(probeCount, firstRound, reason: '快速离线通道必须短路，不再发起探测');
    });

    test('解析器：盘符重映射（当前指向别的共享）→ UNC 备形态优先探测', () async {
      NetworkPath.debugRemoteDrives = {'Z:'};
      NetworkPath.debugDriveUncOverrides = {r'Z:\': r'\\host2\share2'};
      GamePathResolver.debugDriveMapProvider =
          (root) => root.toLowerCase() == r'\\host\share' ? 'Z:' : null;
      final probed = <String>[];
      GamePathResolver.debugProbe = (path, _) async {
        probed.add(path);
        return path == r'\\host\share\GAL\X';
      };
      final view = await GamePathResolver.resolve(
        directoryPath: r'Z:\GAL\X',
        sourcePath: r'\\host\share\GAL\X',
      );
      expect(probed.first, r'\\host\share\GAL\X',
          reason: '存储盘符已被重映射到别的共享时，UNC 备形态必须先探测');
      expect(view.accessPath, r'\\host\share\GAL\X');
    });
  });
}
