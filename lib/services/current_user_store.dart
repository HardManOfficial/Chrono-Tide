import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../modules/auth/local_account_service.dart';
import '../modules/auth/user_model.dart';
import 'avatar_preset_service.dart';

/// 当前用户身份的**唯一状态源**（`ChangeNotifier`）。
///
/// 设计文档：`docs/DEV/features/local_first_account_and_avatar_plan.md` §3.3 / §4.2。
///
/// 为什么必须存在：改造前全软件唯一用户态容器是 `MainContainer._currentUser`
/// 私有字段，靠构造参数逐层下发。这带来两个死结：
/// ① 用户资料浮窗挂在 `OverlayEntry`（一次性快照），父级 `setState` 不会重建它；
/// ② 头像有 4 个分散的显示点，逐层传参必然漏。
/// 收敛到本 store 后，渲染层各处只订阅本 store（见 `CtUserAvatar`），一处写处处刷。
///
/// 与既有 `BigPictureManager` / `NetworkStatusService` 的 ChangeNotifier 惯例一致，
/// **零新增依赖**（`ChangeNotifier` 是 Flutter 内置）。
class CurrentUserStore extends ChangeNotifier {
  CurrentUserStore._();

  static final CurrentUserStore instance = CurrentUserStore._();

  UserModel? _user;

  /// 当前身份；`null` = 尚未解析（首帧前的极短窗口）。
  UserModel? get user => _user;

  /// 是否是「本地账户」（非云端登录）。业务分支判据与 `UserModel.isLocalAccount` 同源。
  bool get isLocal => _user?.isLocalAccount ?? false;

  /// 是否已有身份（本地或云端）。
  bool get hasUser => _user != null;

  /// 覆盖当前身份并广播。
  ///
  /// 唯一写入口：`MainContainer`（云端/本地全量解析）与本地头像变更路径
  /// （重抽、网格选图、上传自定义图）。
  void apply(UserModel? user) {
    if (identical(_user, user)) return;
    _user = user;
    notifyListeners();
  }

  /// 冷启动阶段 1：**零网络**地从本地账户读取身份，让首帧就有名字与头像。
  ///
  /// 已有云端会话时不必调用（`MainContainer._loadCurrentUser()` 会异步覆盖）。
  Future<void> hydrateFromLocal() async {
    if (!LocalAccountService.exists) return;
    final local = LocalAccountService.load();
    if (local == null) return;
    apply(local);
  }

  /// 重新读取本地账户（改完名字/简介/头像后调用）。
  Future<void> reloadFromLocal() async {
    final local = LocalAccountService.load();
    if (local != null) apply(local);
  }

  /// 老用户兜底（方案 §5.3）：本地账户 `avatarBytes == null && preset == ''`
  /// 时补抽一张内置头像。
  ///
  /// 判定严格（两者都空才触发），**不覆盖**任何已有头像；只应该在身份加载完成后
  /// 调用一次（`MainContainer._loadCurrentUser` 的本地分支），不要在 build 里调。
  Future<void> ensureLocalAvatarPreset() async {
    final current = _user;
    if (current == null || !current.isLocalAccount) return;
    if (current.avatarPreset.isNotEmpty) return;
    if (current.hasAvatarBytes) return;
    await shuffleLocalAvatar();
  }

  /// 重抽一张内置头像 —— **仅本地账户可用**（云端头像由用户上传的图决定，
  /// 抽内置头像没有语义）。
  ///
  /// 顺序：**先乐观更新内存 → notify（≤1 帧可见）→ 再落盘**。
  /// 头像池是 asset 路径，无 IO，因此重抽是「点击即变」而不是等待磁盘。
  /// 返回是否真的换了（false = 非本地态 / 池为空）。
  Future<bool> shuffleLocalAvatar() async {
    final current = _user;
    if (current == null || !current.isLocalAccount) return false;

    final next = AvatarPresetService.randomExcept(current.avatarPreset);
    if (next.isEmpty) return false;

    apply(_localCopyWithPreset(current, next));
    await LocalAccountService.setAvatarPreset(next);
    return true;
  }

  /// 选定某张内置头像（网格选择器）。
  Future<bool> selectLocalAvatarPreset(String presetId) async {
    final current = _user;
    if (current == null || !current.isLocalAccount) return false;
    if (!AvatarPresetService.isValid(presetId)) return false;
    if (current.avatarPreset == presetId && !current.hasAvatarBytes) return false;
    apply(_localCopyWithPreset(current, presetId));
    await LocalAccountService.setAvatarPreset(presetId);
    return true;
  }

  /// 本地账户上传了自定义头像图：写字节 + 清空 preset（两者互斥）。
  Future<void> applyLocalAvatarBytes(Uint8List bytes) async {
    final current = _user;
    if (current == null || !current.isLocalAccount) return;
    apply(UserModel(
      id: current.id,
      email: current.email,
      name: current.name,
      bio: current.bio,
      avatarUrl: '',
      avatarBytes: bytes,
      created: current.created,
      token: current.token,
      isLoggedIn: current.isLoggedIn,
    ));
    await LocalAccountService.updateAvatar(bytes);
  }

  /// 本地资料（名字/简介）变更后的内存同步。
  void applyLocalProfile({String? name, String? bio}) {
    final current = _user;
    if (current == null || !current.isLocalAccount) return;
    apply(current.copyWith(name: name, bio: bio));
  }

  /// 换成「内置头像」形态：**必须显式构造**（`copyWith` 的 `avatarBytes ?? this.x`
  /// 无法把字节置回 null，见方案 §5.1 的技术债说明）。
  UserModel _localCopyWithPreset(UserModel from, String presetId) {
    return UserModel(
      id: from.id,
      email: from.email,
      name: from.name,
      bio: from.bio,
      avatarUrl: '',
      avatarBytes: null,
      avatarPreset: presetId,
      created: from.created,
      token: from.token,
      isLoggedIn: from.isLoggedIn,
    );
  }
}
