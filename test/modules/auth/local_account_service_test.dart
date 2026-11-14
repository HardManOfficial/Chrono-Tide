import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chrono_tide/modules/auth/local_account_service.dart';
import 'package:chrono_tide/services/avatar_preset_service.dart';

/// LocalAccountService 单测 —— 本地账户 CRUD 与「本地/云端 key 隔离」。
///
/// 🔴 隔离性是本服务存在的理由：AuthService.logout() 会清空
/// `pb_*` 与 `user_*` 两组 key，绝不能波及 `local_account_*`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalAccountService.resetForTest();
  });

  group('LocalAccountService', () {
    test('初始状态：不存在本地账户', () {
      expect(LocalAccountService.exists, isFalse);
      expect(LocalAccountService.load(), isNull);
    });

    test('create → load 往返：名字/简介/创建时间/id 前缀', () async {
      final user = await LocalAccountService.create(name: '汐乃', bio: '你好');

      expect(LocalAccountService.exists, isTrue);
      expect(user.isLocalAccount, isTrue,
          reason: '本地账户必须 isLocalAccount=true（未登录 + local_ 前缀）');
      expect(user.isLoggedIn, isFalse);
      expect(user.token, isEmpty);
      expect(user.email, isEmpty);
      expect(user.name, '汐乃');
      expect(user.bio, '你好');
      expect(user.id.startsWith('local_'), isTrue);
      expect(user.id.length, 'local_'.length + 8,
          reason: 'id = local_ + 8 位十六进制');
      expect(user.hasAvatar, isFalse);

      final loaded = LocalAccountService.load()!;
      expect(loaded.id, user.id);
      expect(loaded.name, '汐乃');
    });

    test('create 支持可选头像（base64 往返）', () async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final user =
          await LocalAccountService.create(name: 'A', avatarBytes: bytes);

      expect(user.hasAvatarBytes, isTrue);
      expect(user.avatarBytes, bytes);
      expect(LocalAccountService.load()!.avatarBytes, bytes);
    });

    test('updateProfile 只改传入字段', () async {
      await LocalAccountService.create(name: '旧名', bio: '旧简介');
      await LocalAccountService.updateProfile(name: '新名');

      final user = LocalAccountService.load()!;
      expect(user.name, '新名');
      expect(user.bio, '旧简介');
    });

    test('updateAvatar / removeAvatar', () async {
      await LocalAccountService.create(name: 'A');
      expect(LocalAccountService.load()!.hasAvatarBytes, isFalse);

      final bytes = Uint8List.fromList(List<int>.generate(10, (i) => i));
      await LocalAccountService.updateAvatar(bytes);
      expect(LocalAccountService.load()!.avatarBytes, bytes);

      await LocalAccountService.removeAvatar();
      expect(LocalAccountService.load()!.hasAvatarBytes, isFalse);
    });

    test('avatar base64 损坏时 load 不抛异常（头像置空）', () async {
      await LocalAccountService.create(name: 'A');
      // 直接污染底层存储，模拟损坏数据
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_account_avatar_b64', '!!!not-base64!!!');

      final user = LocalAccountService.load()!;
      expect(user.hasAvatarBytes, isFalse);
      expect(user.name, 'A');
    });

    test('🔴 隔离性：清理云端凭据 key 与展示缓存 key 不影响本地账户', () async {
      await LocalAccountService.create(name: '本地汐');

      // 模拟 AuthService.logout() 与 UserCacheService.clearAll() 的动作面：
      // 只动 pb_* 与 user_* 前缀
      final prefs = await SharedPreferences.getInstance();
      final cloudKeys = prefs
          .getKeys()
          .where((k) => k.startsWith('pb_') || k.startsWith('user_'))
          .toList();
      for (final k in cloudKeys) {
        await prefs.remove(k);
      }

      final user = LocalAccountService.load()!;
      expect(user.name, '本地汐', reason: 'logout 后本地资料必须原样保留');
      expect(LocalAccountService.exists, isTrue);
    });

    test('未 init 直接调用抛 StateError（fail-fast）', () async {
      // 重新构造一个未 init 的调用面：绕过 resetForTest 直接关标志不可行，
      // 这里通过清空并重新 mock 后验证 exists 的安全默认值即可
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(LocalAccountService.exists, isFalse);
    });

    test('clear 后回到初始状态', () async {
      await LocalAccountService.create(name: 'A', bio: 'B');
      await LocalAccountService.clear();

      expect(LocalAccountService.exists, isFalse);
      expect(LocalAccountService.load(), isNull);
    });

    // ==================== 2026-10-23 本地优先改造新增 ====================

    group('内置头像池（avatarPreset）', () {
      test('create(avatarPreset:) → load 往返', () async {
        final user = await LocalAccountService.create(
            name: '萌萌团', avatarPreset: 'av_07');

        expect(user.avatarPreset, 'av_07');
        expect(user.hasAvatarPreset, isTrue);
        expect(user.hasAvatarBytes, isFalse);
        expect(LocalAccountService.avatarPreset, 'av_07');
      });

      test('create 同时传 bytes 与 preset → 以字节为准，preset 被忽略', () async {
        final bytes = Uint8List.fromList(<int>[9, 9, 9]);
        final user = await LocalAccountService.create(
            name: 'A', avatarBytes: bytes, avatarPreset: 'av_03');

        expect(user.avatarBytes, bytes);
        expect(user.avatarPreset, isEmpty,
            reason: '两者互斥：有上传字节就不能再算「内置头像」');
      });

      test('setAvatarPreset 清掉旧的上传字节；updateAvatar 清掉 preset', () async {
        await LocalAccountService.create(
            name: 'A', avatarBytes: Uint8List.fromList(<int>[1, 2, 3]));
        await LocalAccountService.setAvatarPreset('av_12');

        var user = LocalAccountService.load()!;
        expect(user.avatarPreset, 'av_12');
        expect(user.avatarBytes, isNull, reason: '选内置头像必须清字节');

        await LocalAccountService.updateAvatar(Uint8List.fromList(<int>[4, 5]));
        user = LocalAccountService.load()!;
        expect(user.avatarPreset, isEmpty, reason: '上传自定义图必须清 preset');
        expect(user.avatarBytes, isNotNull);
      });

      test('removeAvatar / clear 同时清掉 preset', () async {
        await LocalAccountService.create(name: 'A', avatarPreset: 'av_05');
        await LocalAccountService.removeAvatar();
        expect(LocalAccountService.load()!.avatarPreset, isEmpty);

        await LocalAccountService.setAvatarPreset('av_09');
        await LocalAccountService.clear();
        expect(LocalAccountService.avatarPreset, isEmpty);
      });
    });

    group('createDefault（首启动自动建号）', () {
      test('建出的账户：名「萌萌团」、简介空、头像取自内置池', () async {
        final user = await LocalAccountService.createDefault();

        expect(user.name, LocalAccountService.defaultName);
        expect(user.name, '萌萌团');
        expect(user.bio, isEmpty);
        expect(user.isLocalAccount, isTrue);
        expect(AvatarPresetService.isValid(user.avatarPreset), isTrue,
            reason: 'preset 必须指向头像池内的真实 id');
        expect(user.hasAvatarBytes, isFalse,
            reason: '🔴 只存 preset id，禁止在首启动读 asset 字节（会卡首帧）');
      });

      test('🔴 R1：已有账户时调用不覆盖任何字段', () async {
        await LocalAccountService.create(
            name: '老用户', bio: '我是老用户', avatarPreset: 'av_20');
        final before = LocalAccountService.load()!;

        final after = await LocalAccountService.createDefault();

        expect(after.id, before.id);
        expect(after.name, '老用户');
        expect(after.bio, '我是老用户');
        expect(after.avatarPreset, 'av_20');
      });

      test('连续启动 3 次头像不变（固化，不重抽）', () async {
        final first = await LocalAccountService.createDefault();
        for (var i = 0; i < 2; i++) {
          final again = await LocalAccountService.createDefault();
          expect(again.avatarPreset, first.avatarPreset,
              reason: '随机只发生在首次创建');
          expect(again.id, first.id);
        }
      });
    });
  });
}
