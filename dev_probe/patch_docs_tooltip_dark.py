# -*- coding: utf-8 -*-
"""TOOLTIP-DARK-CONTRAST 文档落盘（幂等）。

2026-11-03：深色主题 Tooltip 可读性修复的档案更新。
直接用字节级读写，避开 Edit 工具在大文件上「报成功但不落盘」的历史问题。
"""
import io
import os

ROOT = r'D:\CTLIB'
MARK = 'TOOLTIP-DARK-CONTRAST'

DEVLOG = os.path.join(ROOT, 'docs', 'DEV', 'DEV_LOG.md')
HANDOFF = os.path.join(ROOT, 'docs', 'DEV', 'SESSION_HANDOFF.md')
PLAN = os.path.join(ROOT, 'docs', 'DEV', 'features', 'modern_light_dark_theme_plan.md')

DEVLOG_ENTRY = """## 2026-11-03 【UI】深色主题悬浮提示可读性（TOOLTIP-DARK-CONTRAST）

**需求源**：用户截图指出深色主题下多处悬浮提示是「浅白 / 灰白底 + 白色文字，根本看不清」，
点名探索大厅的「点击直达浏览器」「GitHub 仓库」「项目官网」，以及其它同类悬浮提示，要求统一调整。

### 根因（`dev_probe/scan_tooltip_colors.py` 扫全 lib 共 66 个 Tooltip）

- **3 处**写成 `decoration.color = AppColors.primaryText` + `textStyle.color = Colors.white`。
  深色档 `primaryText` = `#E7ECF5`（近白）⇒ **白底白字，对比度仅 1.19:1**。
  位置：`widgets/explore_hall/website_section.dart`（常用站点卡）、
  `widgets/explore_hall/docs_section.dart`（`_LinkPill`，即 GitHub / 官网两枚图标）、
  `widgets/settings_modal.dart`（超分预设 chip，同类但未被截图）。
- 其余默认 Tooltip 走 Flutter 深色分支 `Colors.white.withOpacity(0.9)` 的亮白浮块
  （`flutter/packages/flutter/lib/src/material/tooltip.dart:762-765`），字可读但在深色界面里刺眼。

### 改法（用户批准方案 B）

- `lib/theme/app_colors.dart`：新增派生 getter `tooltipBg` / `tooltipFg` / `tooltipBorder`——
  深色档 = `alphaBlend(白 8%, background)` 的提亮深浮面 + `primaryText` 浅字 + `border` 细边；
  浅色档 = 原 `primaryText` 深面 + 白字（**逐像素不变**）。不改 `CTThemeData` 结构、不动任何既有成员。
- `lib/main.dart:_buildThemeData`：新增 `tooltipTheme`，**仅深色档给值**，浅色档传 `null`
  ⇒ 完全沿用框架默认，浅色主题零变化。
- 上述 3 处自定义 Tooltip 改为引用新 getter。

### 量化

| | 底色 | 文字 | 对比度 |
|---|---|---|---|
| 修复前（深色） | `#E7ECF5` | `#FFFFFF` | 1.19:1 |
| 修复后（深色） | `#222731` | `#E7ECF5` | **12.6:1** |

### 验证

- 进程内静态分析（231 环境）：5 个改动文件 **0 error**，仅存量 warning（未使用 import 等，与本次无关）。
- ⏳ 未做：`flutter analyze` 全量（231）、`flutter test`（231 下无法 spawn 子进程）、真机走查。

"""

HANDOFF_ENTRY = """📦 本轮 · 最后更新：**2026-11-03 ·【UI】深色主题悬浮提示可读性（TOOLTIP-DARK-CONTRAST）**

## 2026-11-03 · TOOLTIP-DARK-CONTRAST（✅ 代码 + 静态分析｜⏳ 缺 `flutter test` 与真机走查）

### 用户这次说的

「深色主题这里有很多悬浮提示，浅白色 / 灰白色的背景加上白色文字，我根本就看不清」，
点名「点击直达浏览器」「GitHub 仓库」「项目官网」「探索大厅这一块」等等，「这边调整一下」。

### 结论

- 根因只有一种写法：`decoration.color = AppColors.primaryText` + `textStyle.color = Colors.white`。
  深色档 `primaryText = #E7ECF5`（近白）⇒ 白底白字（对比度 1.19:1）。全项目 66 个 Tooltip 里只有 3 处这么写。
- 已按批准的方案 B 修：新增 `AppColors.tooltipBg/Fg/Border` + `main.dart` 深色档 `tooltipTheme`
  + 3 处改为引用 getter。深色对比度 1.19:1 → **12.6:1**；浅色主题逐像素不变。

### 改动文件

- `lib/theme/app_colors.dart`（+19 行，仅追加 getter）
- `lib/main.dart`（`_buildThemeData` 内 +19 行，仅加 `tooltipTheme`）
- `lib/widgets/explore_hall/website_section.dart`、`lib/widgets/explore_hall/docs_section.dart`、
  `lib/widgets/settings_modal.dart`（各 6–8 行）

### 下一步（按优先级）

1. **P0**：环境恢复后补 `flutter analyze`（全量）+ `flutter test`（`test/widgets/`、`test/explore_hall/` 相关）。
2. **P0**：真机深色主题走查——常用站点卡、GitHub / 官网图标、超分预设 chip 三处 hover；
   以及侧栏图标、发售日历格、相关话题等默认 Tooltip 的新观感。
3. **P1**：若发现 BPM 大屏页也有同类反色写法，单独开一轮（本次按计划只动桌面三处）。

"""

PLAN_SECTION = """
## 11. 深色主题悬浮提示可读性（TOOLTIP-DARK-CONTRAST，2026-11-03）

**问题**：深色档 `primaryText = #E7ECF5`（近白）。历史上 3 处 Tooltip 用
`decoration.color: AppColors.primaryText` 做底、`textStyle.color: Colors.white` 做字
⇒ 白底白字，对比度 1.19:1，几乎不可读。

**位置**：`widgets/explore_hall/website_section.dart`、`widgets/explore_hall/docs_section.dart`（`_LinkPill`）、
`widgets/settings_modal.dart`（超分预设 chip）。

**方案（已实施）**：

1. `AppColors` 新增派生 getter（不改 `CTThemeData` 结构）：
   - `tooltipBg`：深色 = `Color.alphaBlend(Colors.white.withOpacity(0.08), background)`；浅色 = `primaryText`
   - `tooltipFg`：深色 = `primaryText`；浅色 = `Colors.white`
   - `tooltipBorder`：`border`
2. `main.dart:_buildThemeData` 增加 `tooltipTheme`，**仅深色档给值**（浅色传 null ⇒ 框架默认，零变化），
   顺带把「默认 Tooltip 在深色下是 `Colors.white.withOpacity(0.9)` 亮白浮块」一并统一成深色浮层。
3. 三处自定义 Tooltip 改为引用上述 getter。

**效果**：深色对比度 1.19:1 → 12.6:1（底 `#222731` / 字 `#E7ECF5`）；浅色主题逐像素不变。

**扫描工具**：`dev_probe/scan_tooltip_colors.py`（遍历 lib 下全部 `Tooltip(`，打印底/字色，
用于后续回归「又有人写反色」）。
"""


def read_text(p):
    with io.open(p, 'rb') as f:
        raw = f.read()
    return raw.decode('utf-8'), (b'\r\n' in raw)


def write_text(p, text, crlf):
    data = text.replace('\r\n', '\n')
    if crlf:
        data = data.replace('\n', '\r\n')
    with io.open(p, 'wb') as f:
        f.write(data.encode('utf-8'))


def prepend(p, entry):
    text, crlf = read_text(p)
    if MARK in text.split('\n\n')[0] and entry.split('\n')[0] in text[:4000]:
        print('SKIP (already present):', p)
        return
    if entry.split('\n')[0] in text[:6000]:
        print('SKIP (already present):', p)
        return
    write_text(p, entry + text, crlf)
    print('PREPENDED:', p)


def append(p, section):
    text, crlf = read_text(p)
    if 'TOOLTIP-DARK-CONTRAST' in text:
        print('SKIP (already present):', p)
        return
    base = text.rstrip('\r\n')
    write_text(p, base + '\n' + section, crlf)
    print('APPENDED:', p)


prepend(DEVLOG, DEVLOG_ENTRY)
prepend(HANDOFF, HANDOFF_ENTRY)
append(PLAN, PLAN_SECTION)
