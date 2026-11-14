# 窗口级圆角体系统一（2026-10-04）

> 状态：**已落地**（待 flutter test 补跑 + 真机走查）
> 关联：DEV_LOG 2026-10-04 · commit「窗口级圆角体系统一」

## 目标

全仓「窗口级容器」（对话框 / 模态面板 / 弹出菜单 / 浮层气泡）的顶层圆角
此前散落 13 种取值（4/6/8/9/10/11/12/14/16/18/20/22/24），其中 7 个窗口
完全直角、9 处 AlertDialog 漏设 shape 落到 M3 默认（约 28dp）。

统一原则：**一种窗口类型对应一档圆角**，且全部复用既有 `AppRadius` 档位
（`lib/theme/app_styles.dart:283`），**不新增、不修改任何令牌值**。

## 四档定义

| 类型 | 圆角 | 令牌 | 适用 |
|---|---|---|---|
| T1 小型对话框 | 12 | `AppRadius.lg` | 确认框 / 输入框 / 进度框（宽 <500） |
| T2 大型模态面板 | 16 | `AppRadius.xl` | 设置 / 详情 / 编辑器（宽 ≥500 或全功能面板） |
| T3 弹出菜单·气泡 | 8 | `AppRadius.md` | 右键菜单 / 浮动通知气泡 / 拖拽跟随层 |
| T4 BPM 大屏弹层 | 16~24 | `BigPictureTheme.containerRadius` 等 | 大屏 TV 观感，维持既有自洽体系 |

## 落地范围（35 文件）

- **P0 直角补齐（7 窗）**：settings_modal / user_profile_modal / auth_modal /
  payment_modal（select+qr 两页）/ install_confirmation_dialog → xl；
  openlist_pair_dialog / metadata_source_settings_dialog → lg。
  直角面板 `clipBehavior: hardEdge → antiAlias`（防描边溢出圆角）。
- **P1 漏网补 shape（9 处）**：gamepad_mapping_editor_dialog→xl；
  gamepad_launch_dialogs×2、gamepad_settings_section×2、main.dart 快捷启动
  失败、library_page 游玩状态 SimpleDialog、batch_import_section 修改路径、
  settings_modal 清理确认 → lg；bpm_background_manager×2 → containerRadius。
- **P2 漂移收敛**：
  - 14→xl：game_detail_dialog 窗口级 5 处（**行号级替换**：1531/4273/4835/
    4972/5196；窗内右键菜单 1978/1998 与 Magpie/日语标签卡 3327/3393 刻意不动）、
    launch_manager_dialog、exe_selector_dialog、batch_shortcut_dialog；
  - 8→xl：theme_editor_dialog、background_image_editor_dialog；
  - 8→lg：forgot_password_dialog（窗口 shell；内部提示条 8 不动）、
    game_detail_page 取消安装确认；
  - DarkShell（`dark_surface.dart:154`）：`radiusShell` 10→16，删除 6 处
    窗口级 `radius:` 覆写（ct_download / publish_game / share_detail /
    share_list / upload_publish / upload_resource），探索详情系窗口彻底统一；
    内部组件（DarkCard/DarkPrimaryButton 等）的 radius 参数不动；
  - 12→xl：save_backup_dialog、game_data_dialog 主窗（内部 3 个小 AlertDialog
    保持 12）、series_panel（外 16 / 内 ClipRRect 14=xl-2）、discover_disclaimer_dialog；
  - 6/4→md：play_stats_panel 收起态、library_drag_overlay。

## 明确不改

- `AppStyle.rXx`（主题分档圆角）与 `AppRadius` 既有值、`test/theme/` 回归基线；
- 页面内部卡片 / 按钮 / 输入框圆角（属组件层，非「窗口级」）；
- 主 OS 窗口边框：圆角需动 `windows/runner/` 稳定区（Win32 HRGN / DWM），
  四角抗锯齿差、收益有限——如需另立任务评估。

## 验证

- ✅ 进程内 analyzer（`.workbuddy/analyze_probe/ct_scan_all.dart`）全 lib
  317 文件 **errors=0**（与 `flutter analyze` 同源；本次仅 231 环境故障时使用）；
- ⏳ `flutter analyze lib` / `flutter test test/theme/` 因 231（C 盘 99%）
  未跑成，环境恢复后补跑；
- ⏳ 未真机走查（重点：设置 / 用户信息 / 登录注册 / 赞赏 / 游戏详情 / 探索
  详情四窗 / BPM 背景管理）。

## 已知边界

- 新增对话框时应按上表选档：小窗 `AppRadius.lg`、大面板 `AppRadius.xl`、
  菜单气泡 `AppRadius.md`、BPM 内用 `BigPictureTheme.containerRadius`；
- DarkShell 系新窗口默认即 16，不要再传 `radius:` 覆写。
