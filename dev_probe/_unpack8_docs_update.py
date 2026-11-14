# -*- coding: utf-8 -*-
# dev_probe/_unpack8_docs_update.py
# 2026-10-05 第二轮实机反馈（Commit B c69be82 + Commit C b450496）文档同步
# DEV_LOG / SESSION_HANDOFF / features/join_unpack_install_center_pipeline 三文档头部插入
import shutil, sys

DOCS = r'D:\CTLIB\docs\DEV'

DEVLOG_ENTRY = '''## 2026-10-05 【修复+功能】智能解压第二轮实机反馈——解压完成≠入库 + 三情景缺口闭环

- **背景**：用户以 `E:\\GAL\\GAL\\常见特殊解压情景` 三情景为验收标准复测。回报：① 情景一第二层
  rar 报「损坏」但 Bandizip/WinRAR 正常；② 确认窗改名后直接自动入库、用户连数据都没来得及填；
  ③ 三情景尚未全自动。
- **修复 ①（1db8fc5）**：RAR5 加密文件名容器「Wrong password → Cannot open the file as archive」
  两形态补进分类器与损坏文案排除；计划层间密码共享（分享者常用同一密码贯穿多层）。
- **修复 ②（c69be82）**：**流程语义修正——解压完成≠入库**：确认窗（文件夹名+删源包）只收口解压
  流程；删自动写 game.json / 注册进库两步与死代码 `_writeLocalArchiveMetadata`（60 行）；
  新增 `onUnpackReadyForManualImport` → `JoinController.pendingExtractedDir` 静态信箱
  （JoinPage 由 Offstage 保活 State 常驻，故用 Notifier 而非构造参数）→ main_container 切添加页
  + toast → JoinPage 消费预填表单（复用 handleFileSelected），入库由用户手动触发。
- **修复 ③（b450496）**：三情景缺口——C1 `extract_manager._sniffDisguisedFiles`：常规候选为空时
  对顶层散文件跑魔数复查，disguised 容器（.mov 实为 enc 等）收为嵌套候选（单候选直续层，多候选走
  既有歧义选择窗），防 `_resolveGameBody` 按散文件数误判本体提前收尾；C2 `join_controller
  .detectFileType` 嗅探回退上移到 exe 判定前（「到手资源.exe」实为 rar 改后缀走解压链；真 exe 的
  PE 头不在压缩魔数表，行为不变）。
- **验证**：进程内探针 7 文件 errors=0（join_controller 2 条存量 warning）；flutter_tester 离线
  探针 27/27——三情景真实文件实测：情景三 exe→rar、第一次解压产物 4 个伪装容器收为候选（3 zip
  拼接诱饵 + 1 真 enc）、介绍.txt 排除；情景一 mp4 拼接/zip/rar；情景二 enc/rar（到手资源.mov
  实测即 enc 容器伪装）；常规后缀不误标伪装。
- **文件**：`extract_manager.dart` / `global_install_center.dart` / `join_controller.dart` /
  `join_page.dart` / `main_container.dart` / `install_center_page.dart`（文案对齐新语义）。
- **遗留**：flutter test 待 C 盘腾挪（archive_inspector_test 9 用例 + 本轮改动补跑）；
  ⏳ 用户真机三情景验收 + rebuild exe。

'''

HANDOFF_ENTRY = '''📦 本轮 · 最后更新：**2026-10-05 深夜·【修复+功能】智能解压第二轮——解压完成≠入库 + 三情景缺口闭环**——
① RAR5 加密文件名误报损坏（Wrong password → Cannot open the file as archive 补进分类器）+ 计划密码
层间共享（1db8fc5）；② **流程语义修正：确认窗只收口解压流程**——确认后经 onUnpackReadyForManualImport
→ JoinController.pendingExtractedDir 静态信箱（Offstage 保活 State 常驻）切添加页预填表单，数据填写
与入库完全由用户手动（c69be82）；③ 三情景缺口闭环：C1 散文件伪装容器魔数复查（防本体误判提前收尾）+
C2 exe 伪装嗅探前移（b450496）。flutter_tester 离线探针 27/27（三情景真实文件实测）；进程内探针 errors=0。
✅ 三情景自动化判定：情景一全自动（mp4 拼接→zip→rar 同密码）；情景二全自动（mov 即 enc 容器→rar→
子目录内压缩包递归发现）；情景三 rar 层后**一次歧义选择窗**（4 候选 = 3 诱饵 zip + 1 真 enc，用户
选定真链条后全自动）——与全流程.txt「使用者自己判断真资源」的人工操作流一致，其余候选随临时层清理。
⚠️ flutter test 挂 231（C 盘 1.1G 满）——存量+新增单测待 C 盘腾挪后补跑。
⏳ **下一步：用户真机三情景验收**（各自全流程.txt 分步走查）+ rebuild exe（改动未入 exe 时间戳）。

'''

FEATURES_ENTRY = '''> 2026-10-05 第二轮实机反馈（1db8fc5 + c69be82 + b450496）：① RAR5 加密文件名误报损坏 +
> 计划密码层间共享（分享者常用同一密码贯穿多层）；② **解压完成≠入库**：确认窗只收口解压流程，
> onUnpackReadyForManualImport → JoinController.pendingExtractedDir 静态信箱（Offstage 保活）
> → 添加页预填表单，数据填写与「确认入库」完全由用户手动操作；③ 三情景缺口：
> `_sniffDisguisedFiles` 散文件伪装容器复查（常规候选空时收 disguised 容器为嵌套候选，多候选走
> 歧义选择窗）+ `detectFileType` 嗅探前移（exe 实为 rar 走解压链）。flutter_tester 离线探针
> 27/27（三情景真实文件实测）；flutter test 待 C 盘腾挪后补跑，真机三情景走查待用户执行。

'''

def patch(path, anchor, insert, label):
    with open(path, 'rb') as f:
        data = f.read().decode('utf-8')
    if '解压完成≠入库 + 三情景缺口闭环' in data:
        print(f'[SKIP] {label}: 已插入过')
        return
    if anchor not in data:
        print(f'[FAIL] {label}: 锚点未找到！')
        sys.exit(1)
    new = data.replace(anchor, insert + anchor, 1)
    shutil.copy2(path, path + '.bak_unpack8')
    with open(path, 'wb') as f:
        f.write(new.encode('utf-8'))
    # 写后复读验证
    with open(path, 'rb') as f:
        back = f.read().decode('utf-8')
    ok = insert.strip()[:40] in back and anchor in back
    print(f'[{"OK" if ok else "FAIL"}] {label}: 写后复读验证 {"通过" if ok else "失败"}')

patch(rf'{DOCS}\DEV_LOG.md',
      '## 2026-10-05 【修复+功能】实机测试两问题',
      DEVLOG_ENTRY, 'DEV_LOG.md')

patch(rf'{DOCS}\SESSION_HANDOFF.md',
      '📦 本轮 · 最后更新：**2026-10-05 深夜·【修复+功能】实机测试两问题闭环**',
      HANDOFF_ENTRY, 'SESSION_HANDOFF.md')

patch(rf'{DOCS}\features\join_unpack_install_center_pipeline.md',
      '> 2026-10-05 实机测试修复（a4e9044 + d5676bd）',
      FEATURES_ENTRY, 'features/pipeline.md')

print('DONE')
