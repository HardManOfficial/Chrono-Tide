# -*- coding: utf-8 -*-
"""verify_and_visual.py — git 改动面自查 + 导出新图标 256 帧供视觉验证（全程落盘）"""
import subprocess

OUT = r"D:\CTLIB\dev_probe\_verify_result.txt"
lines = []


def run(args, cwd=None):
    with open(OUT + ".tmp", "w", encoding="utf-8") as f:  # 句柄级重定向，不用匿名管道
        r = subprocess.run(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)
    with open(OUT + ".tmp", "r", encoding="utf-8", errors="replace") as f:
        return r.returncode, f.read()


# 1. git 自查
for title, args in [
    ("git status --porcelain", ["git", "status", "--porcelain"]),
    ("git diff --stat", ["git", "diff", "--stat"]),
    ("git ls-files (ico)", ["git", "ls-files", "*.ico"]),
]:
    code, text = run(args, cwd=r"D:\CTLIB")
    lines.append("=== %s (exit=%d) ===\n%s" % (title, code, text.rstrip()))

# 2. 导出 256 帧 PNG（视觉验证用）
from PIL import Image

for name, path in [
    ("new_runner_icon", r"D:\CTLIB\windows\runner\resources\app_icon.ico"),
    ("new_root_icon", r"D:\CTLIB\ChronoTide.ico"),
]:
    im = Image.open(path)
    im.size  # 最大帧 256
    out_png = r"D:\CTLIB\dev_probe\_icon_%s.png" % name
    im.save(out_png)
    lines.append("导出: %s (%dx%d)" % (out_png, im.size[0], im.size[1]))

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
