# -*- coding: utf-8 -*-
"""文档同步：智能解压去层级化（76472c4 + 5f29e60）→ DEV_LOG / SESSION_HANDOFF / features"""
import io, os, shutil, datetime

REPO = r"D:\CTLIB"
ENTRY = """
## 2026-10-05 智能解压去层级化：密码组体系 + 改名链 + 安装中心日志/遮挡修复（76472c4 + 5f29e60）

**需求**（用户六条）：①密码去层级化 ②密码记忆策略（本次输入→预设组→历史组→密码库，组为整体不可拆散）③后缀改名链内置+自定义 ④计划窗简化为「设定/后缀」两板块 ⑤实际解压区（密码组填写+位置选择）⑥安装中心操作日志面板 + 弹窗遮挡修复。

**实现**：
- `unpack_store.dart`：PasswordGroup（预设/历史组，签名去重 LRU 10，存 `unpack_settings.json` 'password_groups'）；`passwordLibrary` 汇总保底；内置改名链对齐需求顺序（.mp4/.mov/.exe/.txt/空后缀）+ `defaultAutoTryChains`/`customAutoTryChains` 只读视图。
- `extract_manager.dart`：候选队列 = 本次输入→预设组→历史组→本包记忆/包内提取→密码库（每层同队列）；`_encTryAllowed` 扁平组语义；补输成功整组记历史；`onOpLog` 钩子 7 处打点。
- `archive_plan_dialog.dart`：计划窗=①设定（密码组+密码库管理弹窗）②后缀（内置链展示+自定义规则）；分层密码/映射/策略预览删除；新增 `showExtractStartDialog` 实际解压区。
- `global_install_center.dart`+`install_center_page.dart`：onOpLog 环形缓冲 200 行仅内存、每任务清空；解压视图标题与进度条之间可收起日志面板。
- `main_container.dart`：**遮挡根因=框架级**（flutter navigator.dart:4429 每次 flush `rearrange` + overlay.dart:754 把非路由外来 OverlayEntry 插回最顶）→ 安装中心从根 Overlay 改挂本壳 Stack 顶层（盖页面、天然在弹窗 route 之下）。

**验证**：flutter_tester 离线探针 20/20（组存取/去重/库汇总/链默认与自定义/JSON 往返）；flutter analyze 六文件 0 error（新增 issue 已清）。⚠️ 未真机走查（计划窗/实际解压区/日志面板 UI + 遮挡实测）；UnpackPreset 分层预设模型成 UI 死代码（P2 清理项）。

---
"""


def insert_after_header(path, entry, header_marker):
    full = os.path.join(REPO, path)
    bak = full + ".bak_opt"
    shutil.copy2(full, bak)
    with io.open(full, "r", encoding="utf-8") as f:
        content = f.read()
    if header_marker == "@TOP":
        pos = 0
    else:
        idx = content.find(header_marker)
        if idx < 0:
            raise SystemExit(f"[FAIL] {path}: header marker not found")
        pos = content.find("\n", idx) + 1
    new = content[:pos] + entry + content[pos:]
    with io.open(full, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    # 复读验证
    with io.open(full, "r", encoding="utf-8") as f:
        check = f.read()
    assert entry in check, f"[FAIL] {path}: write-back verify failed"
    print(f"[OK] {path} (+{len(entry)} chars)")


insert_after_header(
    r"docs\DEV\DEV_LOG.md", ENTRY, "# DEV_LOG — 开发时间线")
insert_after_header(
    r"docs\DEV\SESSION_HANDOFF.md", ENTRY, "@TOP")
insert_after_header(
    r"docs\DEV\features\join_unpack_install_center_pipeline.md",
    ENTRY, "# 单文件导入解压流水线重构")
print("ALL DONE")
