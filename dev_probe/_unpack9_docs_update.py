# -*- coding: utf-8 -*-
# dev_probe/_unpack9_docs_update.py
# 2026-10-05 第三轮实机反馈（7z 完整版替换 498ed08）文档同步
import shutil, sys

DOCS = r'D:\CTLIB\docs\DEV'

DEVLOG_ENTRY = '''## 2026-10-05 【修复】三情景全挂 rar 层——根因：内置 7z 是 7za 精简版无 RAR 解码器

- **背景**：三情景复测全部失败在 rar 层（「解压失败（密码候选均无效）| Cannot open the file as
  archive，exitCode=2」），用户输入正确密码（Bandizip/WinRAR 手动可解）仍失败——排除密码问题。
- **根因（实锤）**：内置 `7z.exe` 实为 **7-Zip (a) 精简形态**（7za + 7za.dll 284KB），只内置
  7z/zip 等核心格式、**不含 RAR 编解码器**——对任何 RAR（含无加密普通 rar）都报
  `Cannot open the file as archive`。历史 rar 层所有失败（误报损坏/密码轮换全灭）根因都是它；
  用户手动解压正常是因为 Bandizip/WinRAR 带完整 RAR 支持。`.rar.lz4` 专链（bz.exe+UnRAR.exe）
  早已绕开此坑，智能解压流水线的 rar 层没有绕。
- **修复（498ed08）**：7-Zip 26.03 完整版 `7z.exe`(577KB x64) + `7z.dll`(1.9MB，含 Rar1-5) 替换
  `windows/runner/tools/` 与 `build/.../Release/runtime/tools/` 两处（iss 按 Release 整体打包，
  安装包同步生效）。**零代码改动**，PathHelper.bundled7zPath 全部调用点超集兼容。旧文件备份
  `*.bak_7zrar`。7z.exe 因 .gitignore `*.exe` 不入库（存量规则）。
- **验证（Release 侧 7z 直测）**：情景一 rar `-pacgs`=0；情景二 rar `-p奈乃香`（中文密码+加密
  文件名）=0；情景三 exe 伪装 rar `-pHM`=0；mp4 尾部拼接 zip=0（回归）；`.7z.lz4` 走专链不受影响。
- **遗留**：⏳ 用户重建 exe 后三情景真机复测（本轮之前的解压完成≠入库等修复同样未入 exe）。

'''

HANDOFF_ENTRY = '''📦 本轮 · 最后更新：**2026-10-05 深夜·【修复】三情景全挂 rar 层根因——内置 7z 是 7za 精简版无
RAR 解码器（498ed08）**——用户密码正确仍「Cannot open the file as archive」：内置 7z.exe 实为
7-Zip (a) 形态（7za.dll 284KB，无 RAR codec），对任何 RAR 都打不开，与密码/加密文件名无关（此前
rar 层全部失败的真正根因）。已换 7-Zip 26.03 完整版 7z.exe+7z.dll（1.9MB 含 Rar1-5），替换
windows/runner/tools 与 Release/runtime/tools 两处，零代码改动，iss 打包同步生效。
✅ Release 侧直测：三情景 rar（含中文密码/加密文件名/exe 伪装）全 EXIT=0；mp4 拼接 zip 回归=0。
⚠️ 旧文件备份 *.bak_7zrar；7z.exe 因 .gitignore 不入库（存量缺口，新克隆需自放）。
⏳ **下一步：用户重建 exe → 三情景真机复测**（含解压完成≠入库、伪装容器复查等前几轮修复，均未入 exe）。

'''

def patch(path, anchor, insert, label):
    with open(path, 'rb') as f:
        data = f.read().decode('utf-8')
    if '7za 精简版无 RAR' in data or '7za 精简版无\nRAR' in data:
        print(f'[SKIP] {label}: 已插入过')
        return
    if anchor not in data:
        print(f'[FAIL] {label}: 锚点未找到！')
        sys.exit(1)
    new = data.replace(anchor, insert + anchor, 1)
    shutil.copy2(path, path + '.bak_unpack9')
    with open(path, 'wb') as f:
        f.write(new.encode('utf-8'))
    with open(path, 'rb') as f:
        back = f.read().decode('utf-8')
    ok = '7za 精简版' in back and anchor in back
    print(f'[{"OK" if ok else "FAIL"}] {label}: 写后复读验证 {"通过" if ok else "失败"}')

patch(rf'{DOCS}\DEV_LOG.md',
      '## 2026-10-05 【修复+功能】智能解压第二轮实机反馈',
      DEVLOG_ENTRY, 'DEV_LOG.md')

patch(rf'{DOCS}\SESSION_HANDOFF.md',
      '📦 本轮 · 最后更新：**2026-10-05 深夜·【修复+功能】智能解压第二轮',
      HANDOFF_ENTRY, 'SESSION_HANDOFF.md')

print('DONE')
