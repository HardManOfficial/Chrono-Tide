# -*- coding: utf-8 -*-
"""P2 圆角收敛辅助脚本：
1) 给需要用 AppRadius 令牌的文件补 app_styles import（若无）；
2) game_detail_dialog.dart 按 1-based 行号把窗口级 circular(14) 替换为 AppRadius.xl。
只做这两个机械操作，逐条打印结果；newline='' 保留 CRLF。
"""
import re

IMPORTS = {
    'lib/widgets/game_detail_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/launch_manager_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/exe_selector_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/library/batch_shortcut_dialog.dart': "import '../../theme/app_styles.dart';",
    'lib/widgets/theme_editor_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/background_image_editor_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/pages/login/forgot_password_dialog.dart': "import '../../theme/app_styles.dart';",
    'lib/widgets/save_backup_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/game_data_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/discover_disclaimer_dialog.dart': "import '../theme/app_styles.dart';",
    'lib/widgets/play_stats_panel.dart': "import '../theme/app_styles.dart';",
}

for path, imp in IMPORTS.items():
    with open(path, 'r', encoding='utf-8', newline='') as f:
        src = f.read()
    if 'theme/app_styles' in src:
        print('SKIP (already imported):', path)
        continue
    m = re.search(r"^import ['\"]([^'\"]*theme/app_colors\.dart)['\"];", src, re.M)
    if not m:
        print('WARN no app_colors import:', path)
        continue
    src = src[:m.end()] + '\n' + imp + src[m.end():]
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(src)
    print('OK import:', path)

# game_detail_dialog.dart：行号级替换（1-based）
path = 'lib/widgets/game_detail_dialog.dart'
with open(path, 'r', encoding='utf-8', newline='') as f:
    lines = f.readlines()
for ln in (1532, 4273, 4835, 4972, 5196):
    line = lines[ln - 1]
    if 'BorderRadius.circular(14)' not in line:
        print('FAIL line %d mismatch: %r' % (ln, line))
        break
    lines[ln - 1] = line.replace('BorderRadius.circular(14)',
                                 'BorderRadius.circular(AppRadius.xl)')
    print('OK line %d' % ln)
with open(path, 'w', encoding='utf-8', newline='') as f:
    f.writelines(lines)
print('DONE')
