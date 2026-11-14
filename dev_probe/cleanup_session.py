# -*- coding: utf-8 -*-
"""cleanup_session.py — 清理本轮诊断临时文件（保留工具脚本/备份/文档更新文本）"""
import os

ROOT = r"D:\CTLIB"
RESULT = os.path.join(ROOT, "dev_probe", "_cleanup_result.txt")

KEEP = {
    "make_app_icon_ico.py",       # 生成器（可复跑）
    "verify_orientation.py",      # 方向校验器
    "_new_devlog_entry.txt",      # DEV_LOG 更新文本（待锁释放落地）
    "_new_handoff_block.txt",     # HANDOFF 更新文本（待锁释放落地）
}
DEL = [
    "finalize_icon_task.py", "finalize_icon_task_v2.py", "gen_full_docs.py",
    "verify_and_visual.py", "_finalize_result.txt", "_gen_full_result.txt",
    "_gen_full_result_copy.txt", "_move_result.txt", "_ps_edit_result.txt",
    "_probe_result.txt", "_commit_msg.txt", "_out_app_icon.ico",
    "_devlog_full_new.md", "_handoff_full_new.md", "_write_probe.txt",
]
# docs/DEV 下的探针与遗留备份（PowerShell 可写区，python 删可能被拦，尽力而为）
DEL_IN_DOCS = ["_write_probe.txt", "DEV_LOG.md.icon_bak", "SESSION_HANDOFF.md.icon_bak"]

lines = []
d = os.path.join(ROOT, "dev_probe")
for name in os.listdir(d):
    if name in KEEP:
        continue
    if name in DEL or name.startswith("_probe_") or name.startswith("_py_") or name.startswith("_sp_"):
        p = os.path.join(d, name)
        try:
            if os.path.isfile(p):
                os.remove(p)
                lines.append("DEL dev_probe/%s" % name)
        except Exception as exc:  # noqa: BLE001
            lines.append("SKIP dev_probe/%s: %r" % (name, exc))

for name in DEL_IN_DOCS:
    p = os.path.join(ROOT, "docs", "DEV", name)
    try:
        if os.path.exists(p):
            os.remove(p)
            lines.append("DEL docs/DEV/%s" % name)
        else:
            lines.append("ABSENT docs/DEV/%s" % name)
    except Exception as exc:  # noqa: BLE001
        lines.append("SKIP docs/DEV/%s: %r" % (name, exc))

with open(RESULT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
