import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_model.dart';
import '../../services/avatar_preset_service.dart';

/// 本地账户服务 —— 「本地状态」的身份中枢。
///
/// 设计文档：`docs/DEV/features/local_account_mode.md`。术语约定：
/// - **本地账户**：仅存于本机（SharedPreferences `local_account_*` 独立 key），
///   无 PocketBase 记录、无 token；id 形如 `local_xxxxxxxx`。
/// - **账号**：已登录的 PocketBase `users` 记录（由 [AuthService] 管理）。
///
/// 🔴 与 `UserCacheService`（`user_*`，云端账号展示缓存）和 `AuthService`
/// 的 `pb_*` 凭据 key **完全隔离**：`AuthService.logout()` 会清空后两者，
/// 绝不能波及本地账户资料 —— 这是「本地/云端资料并存互不覆盖」的基石。
///
/// 使用前置：main.dart 启动时（`UserCacheService.init()` 之后）调用 [init]。
class LocalAccountService {
  LocalAccountService._();

  static const String _keyId = 'local_account_id';
  static const String _keyName = 'local_account_name';
  static const String _keyBio = 'local_account_bio';
  static const String _keyAvatarB64 = 'local_account_avatar_b64';
  static const String _keyCreatedAt = 'local_account_created_at';

  /// 内置头像池 id（如 `av_07`）。与 [_keyAvatarB64] 互斥：存 id 时无字节。
  ///
  /// 为什么存 id 而不是字节：prefs 只多 5 字节、能区分「内置/上传」、首启动零 IO。
  /// 见方案 §3.2 与 §5.2。
  static const String _keyAvatarPreset = 'local_account_avatar_preset';

  /// 新用户默认名字（统一初始账号）。
  static const String defaultName = '萌萌团';

  static bool _isInitialized = false;
  static late SharedPreferences _prefs;

  static bool get isInitialized => _isInitialized;

  /// 初始化（幂等）。必须在任何读/写之前完成。
  static Future<void> init() async {
    if (_isInitialized) return;
    _prefs = await SharedPreferences.getInstance();
    _isInitialized = true;
    debugPrint('[LOCAL-ACCOUNT] init done');
  }

  static void _ensureInit() {
    if (!_isInitialized) {
      throw StateError('LocalAccountService 尚未 init()，请先在启动时初始化');
    }
  }

  /// 是否已存在本地账户（init 后可同步读取）。
  static bool get exists =>
      _isInitialized && (_prefs.getString(_keyId)?.isNotEmpty ?? false);

  /// 创建本地账户。名字必填（由调用方 UI 校验非空），头像/简介可选。
  /// 返回创建后的 [UserModel]（isLocalAccount=true）。
  ///
  /// [avatarBytes] 与 [avatarPreset] **二选一**：两者都传时以字节为准并忽略 preset。
  static Future<UserModel> create({
    required String name,
    String bio = '',
    Uint8List? avatarBytes,
    String avatarPreset = '',
  }) async {
    _ensureInit();
    final id = 'local_${_randomSuffix()}';
    await _prefs.setString(_keyId, id);
    await _prefs.setString(_keyName, name);
    await _prefs.setString(_keyBio, bio);
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      await _prefs.setString(_keyAvatarB64, base64Encode(avatarBytes));
      await _prefs.remove(_keyAvatarPreset);
    } else {
      await _prefs.remove(_keyAvatarB64);
      if (avatarPreset.isNotEmpty) {
        await _prefs.setString(_keyAvatarPreset, avatarPreset);
      } else {
        await _prefs.remove(_keyAvatarPreset);
      }
    }
    await _prefs.setString(_keyCreatedAt, DateTime.now().toIso8601String());
    debugPrint('[LOCAL-ACCOUNT] ✅ 本地账户已创建 | id=$id name=$name '
        'preset=${avatarPreset.isEmpty ? "(无)" : avatarPreset}');
    return load()!;
  }

  /// **首次启动自动创建**统一的本地默认账户：名 [defaultName]、简介空、
  /// 头像从内置池随机抽一张并**落盘固化**（只抽一次，不是每次启动重抽）。
  ///
  /// 🔴 三重护栏：
  /// ① 已存在账户时**直接返回现有账户**，绝不覆盖老用户资料（方案 R1）；
  /// ② 内部**禁止**任何 asset 读取 / 图片解码（方案 R6：首帧卡顿）；
  /// ③ 只写 6 个 prefs key，耗时 < 15ms。
  static Future<UserModel> createDefault() async {
    _ensureInit();
    if (exists) {
      final existing = load();
      if (existing != null) {
        debugPrint('[LOCAL-ACCOUNT] createDefault 跳过（账户已存在，不覆盖）');
        return existing;
      }
    }
    // 池 id 取自同步可读的常量表/缓存，零 IO。
    final preset = AvatarPresetService.randomExcept(null);
    return create(name: defaultName, bio: '', avatarPreset: preset);
  }

  /// 加载本地账户；不存在返回 null。
  ///
  /// 头像直接解码进 [UserModel.avatarBytes]（不走 UserCacheService 的
  /// 云端缓存 key，避免「本地/云端头像」两个 base64 来源互相污染）。
  static UserModel? load() {
    if (!exists) return null;
    final id = _prefs.getString(_keyId)!;
    Uint8List? avatarBytes;
    final b64 = _prefs.getString(_keyAvatarB64);
    if (b64 != null && b64.isNotEmpty) {
      try {
        avatarBytes = Uint8List.fromList(base64Decode(b64));
      } catch (e) {
        debugPrint('[LOCAL-ACCOUNT] ⚠️ 头像 base64 解码失败（忽略头像）: $e');
      }
    }
    return UserModel(
      id: id,
      email: '', // 本地账户无邮箱
      name: _prefs.getString(_keyName) ?? '',
      bio: _prefs.getString(_keyBio) ?? '',
      avatarUrl: '', // 无云端头像 URL
      avatarBytes: avatarBytes,
      avatarPreset: _prefs.getString(_keyAvatarPreset) ?? '',
      created:
          DateTime.tryParse(_prefs.getString(_keyCreatedAt) ?? '') ??
              DateTime.now(),
      token: '',
      isLoggedIn: false,
    );
  }

  /// 更新本地资料（名字/简介）。与设置窗口「账号区块」的本地分支共用。
  static Future<void> updateProfile({String? name, String? bio}) async {
    _ensureInit();
    if (name != null) await _prefs.setString(_keyName, name);
    if (bio != null) await _prefs.setString(_keyBio, bio);
    debugPrint('[LOCAL-ACCOUNT] 本地资料已更新');
  }

  /// 当前内置头像 id（无则空串）。同步可读，供上传前判定来源。
  static String get avatarPreset =>
      _isInitialized ? (_prefs.getString(_keyAvatarPreset) ?? '') : '';

  /// 选用某张内置头像：写 preset 并**清掉旧的上传字节**（两者互斥）。
  static Future<void> setAvatarPreset(String presetId) async {
    _ensureInit();
    await _prefs.remove(_keyAvatarB64);
    await _prefs.setString(_keyAvatarPreset, presetId);
    debugPrint('[LOCAL-ACCOUNT] 本地头像已切换为内置 $presetId');
  }

  /// 更新本地头像（base64 落盘，量级与既有云端头像缓存相同）。
  /// 上传自定义图 → 清空 preset，避免「来源判不清」。
  static Future<void> updateAvatar(Uint8List bytes) async {
    _ensureInit();
    await _prefs.setString(_keyAvatarB64, base64Encode(bytes));
    await _prefs.remove(_keyAvatarPreset);
  }

  /// 移除本地头像（字节与 preset 一并清空，回到默认图标）。
  static Future<void> removeAvatar() async {
    _ensureInit();
    await _prefs.remove(_keyAvatarB64);
    await _prefs.remove(_keyAvatarPreset);
  }

  /// 清除本地账户（本期不挂任何 UI，仅供未来「删除本地身份」使用）。
  static Future<void> clear() async {
    _ensureInit();
    await _prefs.remove(_keyId);
    await _prefs.remove(_keyName);
    await _prefs.remove(_keyBio);
    await _prefs.remove(_keyAvatarB64);
    await _prefs.remove(_keyAvatarPreset);
    await _prefs.remove(_keyCreatedAt);
    debugPrint('[LOCAL-ACCOUNT] 本地账户已清除');
  }

  /// 8 位十六进制随机后缀。
  static String _randomSuffix() {
    final rnd = Random.secure();
    return List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
  }

  /// 仅供测试：重置内存态（SharedPreferences 实例），配合
  /// `SharedPreferences.setMockInitialValues({})` 实现用例间隔离。
  @visibleForTesting
  static Future<void> resetForTest() async {
    _isInitialized = false;
    await init();
  }
}
