# -*- coding: utf-8 -*-
"""gen_icon_preview_v2.py — 把落盘 app_icon.ico 的 7 帧渲染成一张预览图（供开发者确认）
输出: dev_probe/new_icon_v2_preview.png
"""
import os
import traceback

from PIL import Image, ImageDraw, ImageFont, IcoImagePlugin

ROOT = r"D:\CTLIB"
ICO = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
OUT_PNG = os.path.join(ROOT, "dev_probe", "new_icon_v2_preview.png")
SIZES = [16, 24, 32, 48, 64, 128, 256]
BG = (248, 249, 251)      # 浅色背景（IDE light 主题）
FG = (32, 36, 44)
CELL_W, CELL_H, PAD = 300, 360, 24
FRAME_BOX = 240


def font(sz):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\arial.ttf"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            continue
    return ImageFont.load_default()


lines = []
try:
    cols = 4
    rows = (len(SIZES) + cols - 1) // cols
    W = cols * CELL_W + PAD * (cols + 1)
    H = rows * CELL_H + PAD * (rows + 1) + 46
    canvas = Image.new("RGB", (W, H), BG)
    dr = ImageDraw.Draw(canvas)
    dr.text((PAD, 14), "Chrono Tide - app_icon.ico (v2) frames  [source: ico/app_NxN.ico]",
            fill=FG, font=font(20))

    ico = IcoImagePlugin.IcoImageFile(ICO)
    for i, s in enumerate(SIZES):
        r, c = divmod(i, cols)
        x0 = PAD + c * (CELL_W + PAD)
        y0 = 46 + PAD + r * (CELL_H + PAD)
        cell = Image.new("RGB", (CELL_W, CELL_H), (255, 255, 255))
        ico.size = (s, s)
        ico.load()
        fr = ico.copy().convert("RGBA")
        scale = FRAME_BOX / float(s)
        nw = max(1, int(round(s * scale)))
        resample = Image.NEAREST if scale >= 2 else Image.LANCZOS
        big = fr.resize((nw, nw), resample)
        cell.paste(big, ((CELL_W - nw) // 2, (CELL_H - 40 - nw) // 2), big)
        d2 = ImageDraw.Draw(cell)
        d2.text((CELL_W // 2 - 34, CELL_H - 32), "%dx%d" % (s, s), fill=FG, font=font(18))
        canvas.paste(cell, (x0, y0))
        lines.append("frame %dx%d ok" % (s, s))

    canvas.save(OUT_PNG)
    lines.append("saved: %s (%d B, %s)" % (OUT_PNG, os.path.getsize(OUT_PNG), canvas.size))
    lines.append("RESULT: OK")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: FAILED")

with open(os.path.join(ROOT, "dev_probe", "_preview_v2_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
