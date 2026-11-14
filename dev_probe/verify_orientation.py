# -*- coding: utf-8 -*-
"""verify_orientation.py — 验证合并后 ICO 各帧与源 ICO 是否逐像素一致（含方向校验）"""
import traceback

OUT = r"D:\CTLIB\dev_probe\_orientation_result.txt"
ROOT = r"D:\CTLIB"
SRC_DIR = ROOT + r"\ico"
NEW = ROOT + r"\windows\runner\resources\app_icon.ico"
SIZES = [16, 24, 32, 48, 64, 128, 256]

lines = []
try:
    from PIL import IcoImagePlugin
    from PIL import Image, ImageChops

    ico = IcoImagePlugin.IcoImageFile(NEW)
    lines.append("文件帧表: %s" % sorted(ico.info.get("sizes") or [], key=lambda x: x[0]))

    for s in SIZES:
        src = Image.open("%s\\CT图标_%dx%d.ico" % (SRC_DIR, s, s)).convert("RGBA")
        ico.size = (s, s)  # Pillow 官方选帧方式：设置 size 后重新 load
        ico.load()
        frame = ico.copy().convert("RGBA")
        if frame.size != (s, s):
            lines.append("%3dx%-3d 帧尺寸异常: %s" % (s, s, frame.size))
            continue

        same = ImageChops.difference(src, frame).getbbox() is None
        same_flipped = (
            ImageChops.difference(
                src.transpose(Image.FLIP_TOP_BOTTOM), frame
            ).getbbox()
            is None
        )
        if same:
            verdict = "SAME ✅"
        elif same_flipped:
            verdict = "FLIPPED ❌(需修)"
        else:
            verdict = "DIFF ❌(需查)"
        lines.append("%3dx%-3d 直接一致=%s 翻转后一致=%s => %s" % (s, s, same, same_flipped, verdict))
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
