# -*- coding: utf-8 -*-
"""收尾文档更新：DEV_LOG 头部插条目 + SESSION_HANDOFF 插「本轮」条目。
字节级替换，带 .bak 备份，写后复读验证。"""
import shutil, sys

DEVLOG_ENTRY = '''## 2026-10-04 【UI】窗口级圆角体系统一——四类窗口四档圆角

- **背景**：全仓窗口级容器圆角散落 13 种取值（4~24），7 个窗口完全直角、
  9 处 AlertDialog 漏设 shape 落到 M3 默认（约 28）。按「一类窗口一档圆角」收敛。
- **令牌**：全部落既有 `AppRadius` 档（**不新增/不改任何令牌值**）：
  T1 小型对话框 = lg(12) / T2 大型模态面板 = xl(16) /
  T3 弹出菜单·气泡 = md(8) / T4 BPM 维持 `BigPictureTheme.containerRadius`(16) 大圆角自洽（只补漏）。
- **P0 直角补齐（7 窗）**：settings_modal / user_profile_modal / auth_modal /
  payment_modal×2 / install_confirmation_dialog → xl；
  openlist_pair_dialog / metadata_source_settings_dialog → lg；
  直角面板 `clipBehavior: hardEdge → antiAlias`。
- **P1 漏网补 shape（9 处）**：手柄 4 处（mapping_editor→xl、launch_dialogs×2→lg、
  settings_section×2→lg）、main.dart 快捷启动失败→lg、library_page 游玩状态
  SimpleDialog→lg、batch_import 修改路径→lg、settings_modal 清理确认→lg、
  bpm_background_manager×2→containerRadius。
- **P2 漂移收敛**：14→xl：game_detail_dialog 窗口级 5 处（1531/4273/4835/4972/5196
  行号级替换；窗内右键菜单/标签卡刻意不动）+ launch_manager + exe_selector +
  batch_shortcut；8→xl：theme_editor / background_image_editor；8→lg：
  forgot_password / game_detail_page 取消安装确认；DarkShell `radiusShell`
  10→16 且删 6 处窗口级覆写（ct_download / publish / share_detail / share_list /
  upload_publish / upload_resource）；12→xl：save_backup / game_data 主窗 /
  series_panel（内层 ClipRRect 同步 xl-2）/ discover_disclaimer；6/4→md：
  play_stats_panel 收起态 / library_drag_overlay。
- **验证**：进程内 analyzer 全 lib 317 文件 **errors=0**；⏳ flutter
  analyze/test 被 231 拦死（C 盘 99%，余 1.8G），环境恢复后补跑
  `flutter analyze lib` + `flutter test test/theme/` + 真机走查。
- **明确不改**：AppStyle/AppRadius 既有令牌值与其测试基线、页面内部组件圆角、
  主 OS 窗口边框（需动 windows/runner 稳定区，另立任务评估）。
- ⚠️ 工作区存在**他人未提交**改动（path_helper / main_container /
  openlist_provision，OpenList 对接标记），本次 commit 未包含。
- 辅助脚本：dev_probe/radius_p2_imports.py（import 批补 + 行号级替换）。
- 详见 docs/DEV/features/window_radius_system.md。

---

'''

HANDOFF_ENTRY = '''📦 本轮 · 最后更新：**2026-10-04 上午·【UI】窗口级圆角体系统一**——
全仓窗口级容器圆角从 13 种散落值收敛为四档：T1 小对话框 12 / T2 大面板 16 /
T3 菜单气泡 8 / T4 BPM 维持 16 自洽；补齐 7 个直角窗口 + 9 处 M3 默认漏网 +
DarkShell 10→16 并删 6 处覆写；全部走既有 AppRadius 令牌（无新增/改值）。
验证：进程内 analyzer 317 文件 errors=0；⏳ flutter analyze/test 被 231
（C 盘 99%）拦死待补跑 + 真机走查。工作区他人未提交改动（OpenList 对接
标记 3 文件）未纳入本次提交。详见 docs/DEV/features/window_radius_system.md。

'''

def patch(path, anchor, entry, label):
    shutil.copy2(path, path + '.bak_radius')
    with open(path, 'r', encoding='utf-8', newline='') as f:
        src = f.read()
    if 'window_radius_system' in src:
        print('SKIP already patched:', label)
        return
    idx = src.find(anchor)
    if idx < 0:
        print('FAIL anchor not found in', label)
        sys.exit(1)
    out = src[:idx] + entry + src[idx:]
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(out)
    # 复读验证
    with open(path, 'r', encoding='utf-8', newline='') as f:
        back = f.read()
    ok = entry.replace('\r\n', '\n') in back.replace('\r\n', '\n')
    print(('OK  ' if ok else 'FAIL verify ') + label, 'size', len(src), '->', len(back))

patch('docs/DEV/DEV_LOG.md', '## 2026-10-04 【功能】横幅封面',
      DEVLOG_ENTRY, 'DEV_LOG')
patch('docs/DEV/SESSION_HANDOFF.md',
      '📦 本轮 · 最后更新：**2026-10-04 上午·【功能】横幅封面',
      HANDOFF_ENTRY, 'SESSION_HANDOFF')
