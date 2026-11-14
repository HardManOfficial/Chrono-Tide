# 恢复默认设置（SETTINGS-RESET）

> 2026-11-14 实施。入口在设置窗口页头右上角「恢复默认」，四类可勾选、默认全选。
> 探针：`dev_probe/settings_reset_probe.dart`（55 PASS）。
> 相关：`settings_ui_unification_plan.md`（设置页 IA 与视觉统一）、
> `DECISIONS.md` ADR-020（删除策略：应用内永久删 / 应用外回收站）。

## 1. 背景

设置页有 8 个 tab、70+ 个开关与输入框。用户把某一项改坏之后（最典型：开了
代理导致元数据全抓不到、开了 NSFW 导致封面全糊、把游戏库目录指到不存在的盘），
**没有任何"回到出厂"的手段** —— 只能凭记忆逐项改回去，或者删整个
`data/prefs/shared_preferences.json`（连带账号、令牌、面板布局全丢）。

本功能提供**分域**的恢复：用户自己勾选范围，默认全选。

## 2. 五个关键决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | **按"用户会怎么想"分 4 类**，不按 8 个 tab 分 | 「界面 / 游戏与启动 / 元数据 / 网络与存储」是用户描述"哪里不对"的说法；按 tab 分会让勾选列表变 8 行且互相重叠（如大屏模式属于界面，却挂在独立的 tab 上） |
| 2 | 恢复 = **把键从 prefs 里删掉**，不是写入一堆默认值 | 全项目偏好服务都是「键缺失 ⇒ 用字段初始值」，所以"键不存在"就是全新安装状态。写显式默认值会在下次改默认值后变成"假的默认"，而且需要永远同步维护 |
| 3 | 恢复后**要求重启** | 30+ 个偏好服务都是启动时读一次的单例（`_loaded` 闸），且有 setter 会把内存值写回磁盘 —— 边用边把恢复结果弄脏。逐个加 `reload()` 是 30 处改动 + 加载顺序陷阱，收益远低于重启 |
| 4 | **只删设置，不删用户资产** | 游戏与游戏数据、账号与平台凭证（Token / Cookie / PAT）、自定义主题与背景图文件、Magpie 模板、手柄档案、统计明细、迁移闸、按游戏动态键 —— 一律不碰。问卷式的"一键清空"会让用户不敢用这个功能 |
| 5 | 入口放**页头**，不新增第 9 个 tab | 它不是设置项，是逃生舱。页头右上角的位置在任何 tab 下都一样，且视觉权重低于关闭按钮（危险动作不该最显眼） |

## 3. 四类范围

| 类别 | 覆盖设置页 | 键数 | 恢复时立即生效 | 需要重启 |
|---|---|---|---|---|
| 界面设置 | 外观、大屏模式（+ 窗口几何、库页布局） | 25 | 主题切回暖阳 | 动效、大屏、窗口尺寸、列表面板 |
| 游戏与启动 | 游戏与启动、内容保护（+ 自动导入、字体默认值） | 31 | 开机自启（注册表） | 兼容性、快捷窗口、Magpie、统计模式、NSFW、监控目录 |
| 元数据设置 | 元数据 | 2 | — | 来源开关、字段优先级 |
| 网络与存储 | 网络与存储 | 15 | 解除下载限速（令牌桶清零） | 代理、下载档位、库目录、归档库、云备份、补丁位置 |

> 合计 **73 个键**。唯一事实源：`lib/services/settings_reset/settings_reset_core.dart`
> 的 `kSettingsResetKeys`。

**内容保护（NSFW）归在「游戏与启动」**：它属于"游戏簇"，且它的症状（图片全糊）
与启动/显示类问题同源。若日后用户更愿意把它单列，只需在
`SettingsResetDomain` 加一个枚举值 + 把 6 个 `nsfw_*` 键搬过去，UI 与探针零改动。

## 4. 明确不清理（硬边界）

`kSettingsResetNeverTouchKeys` / `kSettingsResetNeverTouchPrefixes` 是机器可读的
边界声明，探针 A5/A6/A7 逐条断言。

- **凭据**：`pb_auth_token`、`bangumi_personal_access_token`、`kun_galgame_cookie`、
  `two_dfan_cookie`、`sgdb_api_key`、`oauth_token_v1_*`
- **账号资料**：`local_account_*`、`user_id/name/bio/avatar_base64`
- **用户作品**：自定义主题 JSON 与背景图文件（目录内文件，不在 prefs）、
  `magpie_custom_templates`、`data/gamepad_profiles.json`
- **统计明细**：`reported_install_game_ids`、各游戏 `time_tracking` 记录
- **迁移闸**：`*_source_migrated`、`storage_migration_v1_*`（删了会重跑数据迁移）
- **一次性提示的记忆**：`compat_elevation_hint_shown`、`floating_button_hint_shown`、
  `discover_disclaimer_agreed_version`、`theme_default_user_created`
- **按游戏动态键**：`default_exe_<游戏名>`、`save_custom_paths_<游戏名>`、`file_size_<gameId>`

例外说明：**云备份的 WebDAV 账号与密码会被清除**（`cloud_backup_config_v1` 是
一个 JSON，账号密码与"自动备份周期"同住一个键，拆不开）。面板的类别说明里
已明确写出这一条。

## 5. 实现文件

| 文件 | 职责 |
|---|---|
| `lib/services/settings_reset/settings_reset_core.dart` | **纯 Dart**：4 个域、73 键清单、边界清单、`runSettingsReset` 编排（注入 `contains`/`remove`） |
| `lib/services/settings_reset/settings_reset_service.dart` | `SharedPreferences` 注入；开机自启注册表删除；主题立即回默认；限速清零；`scheduleRelaunch()`（延迟 1.5s 拉起新实例） |
| `lib/widgets/settings/settings_reset_dialog.dart` | 面板：勾选（默认全选）→ 二次确认 → 结果页（立即重启 / 稍后）；`debugInitialReport` 供探针直接渲染结果页 |
| `lib/widgets/settings_modal.dart` | 页头右上角入口 `_buildResetEntry()`（28px 高，15px 图标 + 12.5px 文案） |
| `dev_probe/settings_reset_probe.dart` | A 键清单体检 / B 编排行为 / C 渲染 4 组合 / D 交互 / E 负向 / F 结果页 |

### 5.1 为什么"重启"要延迟 1.5 秒

本应用有**单实例文件锁**（`main.dart::_acquireSingleInstanceLock`）。先拉起新实例
再退出自己 ⇒ 新实例抢不到锁，只写入"显示窗口"请求后自杀，用户看到窗口闪一下、
什么都没变。所以顺序必须是「spawn 一个 detached 的 PowerShell → 它 sleep 1.5s
→ `Start-Process` 自身」→ 然后自己 `performCleanExit`。同款逻辑已在
`widgets/elevation_hint_dialog.dart` 验证过。

PowerShell 被组策略/杀软拦时 `scheduleRelaunch()` 返回 false，面板会提示用户
手动重启（不静默失败）。

## 6. 验证

```
# 编译 + 运行（apps/chrono-tide 下）
dartaotruntime <flutter>/bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot \
  --platform <flutter>/bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill \
  --target flutter --packages .dart_tool/package_config.json \
  --output dev_probe/settings_reset.dill dev_probe/settings_reset_probe.dart
<flutter>/bin/cache/artifacts/engine/windows-x64/flutter_tester.exe \
  --disable-vm-service --enable-checked-mode dev_probe/settings_reset.dill
```

- 本功能：**55 PASS / 0 FAIL**
  - A2 是核心：73 个键**逐个**在 `lib/` 源码里找回字面量（排除
    `lib/services/settings_reset/` 自身，否则等于自己给自己作证）
  - A3 四类两两无交集（防「只恢复界面」顺手改掉别的域）
  - B 段用内存假 prefs 覆盖：删除 / 本来就没有 / remove 失败 / contains 抛异常 / 空域
  - C 段 1280×720 与 820×520 × 暖阳 / 极光，0 溢出 0 异常；D 段交互联动
  - F 段结果页单独渲染（高度随副作用条目变化，最容易溢出）
- 回归：`settings_shell_probe` **84 PASS**（新增 A0b / F3b 两条，钉住入口在页头）

## 7. 已知边界

1. **"稍后手动重启"会留下半生效状态**：主题已切回、开机自启已关、限速已解除，
   其余仍是旧值。面板文案已写明"重启后生效"。
2. **升权丢失**：若管理器以管理员身份运行，`Start-Process` 拉起的新实例是普通权限
   （与 `elevation_hint_dialog` 的 RunAs 路径不同）。需要提权时请走托盘菜单
   「以管理员身份重启」。
3. **云备份凭据随设置清除**（见 §4）。
4. **只在 Windows 上验证过**（应用本身只发 Windows）。
5. 结果页**只在恢复后可见**，没有"再次进入看历史"的入口 —— 恢复是一次性动作，
   不做审计日志。

## 8. 以后新增设置怎么办

1. 在 `kSettingsResetKeys` 对应类别里加键名（**逐字符**与源码字面量一致）；
2. 跑探针：A2 会立刻告诉你键名打错（找不到字面量）或被放进两个类别；
3. 如果新键是凭据/用户数据/迁移闸，加进 `kSettingsResetNeverTouchKeys`。

不需要改 UI、不需要改服务层 —— 面板的「N 项」计数由键清单长度自动得算。
