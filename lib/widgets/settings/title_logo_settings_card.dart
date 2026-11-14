/// 设置页「游戏标题图」卡片 —— 配置 SteamGridDB 个人 API Key。
///
/// ## 这里为什么只有 Key 一个输入框
/// 标题图的抓取是**全自动**的：大标题位渲染时发现缺图 → 后台抓一次，抓到就
/// 展示、抓不到回退文字。用户不需要（也不应该需要）手动点"抓取"。
/// 唯一的配置项就是 SteamGridDB 的 Key —— 因为那是**个人凭据**，不能内置。
///
/// ## 没有 Key 也能用
/// 主线走 Steam 官方 CDN（实测 galgame 覆盖 13/20），完全不需要 Key；
/// 填 Key 只是把剩下那部分缺口补上一截。
///
/// 🔴 保存后必须调 [GameTitleLogoService.onSgdbKeyChanged]：
/// 它会清掉 7 天失败负缓存，否则用户刚填好 Key 却要等一周才生效。
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/game_title_logo_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';

class TitleLogoSettingsCard extends StatefulWidget {
  const TitleLogoSettingsCard({super.key});

  @override
  State<TitleLogoSettingsCard> createState() => _TitleLogoSettingsCardState();
}

class _TitleLogoSettingsCardState extends State<TitleLogoSettingsCard> {
  final TextEditingController _keyController = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _showGuide = false;
  String? _message;
  bool _messageOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await GameTitleLogoService.readSgdbApiKey();
    if (!mounted) return;
    setState(() {
      _keyController.text = key;
      _loading = false;
    });
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageOk = ok;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    final key = _keyController.text.trim();
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (key.isEmpty) {
        await prefs.remove(GameTitleLogoService.sgdbApiKeyPref);
      } else {
        await prefs.setString(GameTitleLogoService.sgdbApiKeyPref, key);
      }
      await GameTitleLogoService.instance.onSgdbKeyChanged();

      if (key.isEmpty) {
        _toast('已清除 Key，标题图只走 Steam 官方源');
      } else if (key.length != 32) {
        _toast('已保存，但长度不是 32 位，可能粘贴不完整', ok: false);
      } else {
        _toast('已保存，切换游戏时会自动重新抓取');
      }
    } catch (e) {
      _toast('保存失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    final key = _keyController.text.trim();
    setState(() => _busy = true);
    try {
      final err = await GameTitleLogoService.instance.verifySgdbApiKey(key);
      if (err == null) {
        _toast('连接正常，Key 可用');
      } else {
        _toast(err, ok: false);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
                BoxShadow(
                  color: AppColors.borderLight,
                  offset: const Offset(2, 2),
                  blurRadius: 0,
                ),
              ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '游戏标题图',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              height: 24 / 16,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '桌面主页与 BPM 主页的大标题位，会自动抓取游戏的艺术字标题图（透明 PNG）'
            '来替代纯文字标题；抓不到就原样显示文字标题。',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '抓取全自动，无需操作。不填 Key 也能覆盖约七成游戏（走 Steam 官方 CDN）；'
            '下面的 Key 只用来把剩下那部分再补一截 —— 属于可选项，留空完全不影响使用。',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 14),

          // ---- 获取方式（可展开） ----
          _guideToggle(),
          if (_showGuide) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '1. 打开 steamgriddb.com，用 Steam 账号登录（免费，无需注册）',
                    style: _guideStyle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '2. 进入个人设置页的 API 小节：',
                    style: _guideStyle,
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    'https://www.steamgriddb.com/profile/preferences/api',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: AppColors.primaryText,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('3. 点「Generate API Key」，复制生成的 32 位字符串', style: _guideStyle),
                  const SizedBox(height: 6),
                  Text('4. 粘贴到下面输入框，点「保存」，再点「验证」确认可用', style: _guideStyle),
                  const SizedBox(height: 10),
                  Text(
                    '🔒 Key 只存在本机（本地偏好设置），不会上传到任何服务器。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 18 / 12,
                      color: AppColors.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),

          // ---- Key 输入 ----
          Text(
            'SteamGridDB API Key（可选）',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _keyController,
            style: TextStyle(fontSize: 13, color: AppColors.primaryText),
            decoration: InputDecoration(
              isDense: true,
              hintText: '粘贴 32 位 Key，留空 = 不使用 SteamGridDB',
              hintStyle:
                  TextStyle(fontSize: 12, color: AppColors.secondaryText),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
          const SizedBox(height: 10),

          if (_message != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _messageOk ? AppColors.successBg : AppColors.errorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      _messageOk ? AppColors.successGreen : AppColors.dangerRed,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _messageOk
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color:
                        _messageOk ? AppColors.successGreen : AppColors.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                        color: _messageOk
                            ? AppColors.successGreen
                            : AppColors.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          Row(
            children: [
              _button('保存', _busy ? null : _save, primary: true),
              const SizedBox(width: 8),
              _button('验证', _busy ? null : _verify),
              const SizedBox(width: 8),
              _button('清除', _busy ? null : _clear),
            ],
          ),
        ],
      ),
    );
  }

  TextStyle get _guideStyle => TextStyle(
        fontSize: 12.5,
        height: 18 / 12.5,
        color: AppColors.primaryText,
      );

  Widget _guideToggle() {
    return GestureDetector(
      onTap: () => setState(() => _showGuide = !_showGuide),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _showGuide ? Icons.expand_less : Icons.expand_more,
            size: 16,
            color: AppColors.primaryText,
          ),
          const SizedBox(width: 4),
          Text(
            '如何获取 Key（约 1 分钟，免费）',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: AppColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clear() async {
    _keyController.text = '';
    await _save();
  }

  Widget _button(String label, VoidCallback? onTap, {bool primary = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: primary ? AppColors.primaryText : AppColors.background,
            border: Border.all(
              color: primary ? AppColors.primaryText : AppColors.border,
              width: 1.2,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: primary ? AppColors.background : AppColors.primaryText,
            ),
          ),
        ),
      ),
    );
  }
}
