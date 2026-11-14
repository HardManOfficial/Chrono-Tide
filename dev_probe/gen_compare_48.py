# -*- coding: utf-8 -*-
"""gen_compare_48.py — 48px 实际渲染像素对比：新图标 / v1 / 原始图标（放大 6 倍查看）
输出: dev_probe/icon_48_compare.png
"""
import os
import traceback

from PIL import Image, ImageDraw, ImageFont, IcoImagePlugin

ROOT = r"D:\CTLIB"
BAK = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
OUT = os.path.join(ROOT, "dev_probe", "icon_48_compare.png")
ITEMS = [
    ("NEW  app_48x48 (current)", os.path.join(ROOT, "ico", "app_48x48.ico")),
    ("v1   PNG-frame build", os.path.join(BAK, "assets_app_icon.ico")),
    ("ORIG developer's first", os.path.join(BAK, "root_ChronoTide.ico")),
]
SIZE = 48
ZOOM = 6
CELL = SIZE * ZOOM
PAD = 26
TOP = 66


def font(sz):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\arial.ttf"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            continue
    return ImageFont.load_default()


lines = []
try:
    n = len(ITEMS)
    W = n * CELL + PAD * (n + 1)
    H = TOP + CELL + 60 + PAD
    canvas = Image.new("RGB", (W, H), (238, 240, 244))
    dr = ImageDraw.Draw(canvas)
    dr.text((PAD, 16), u"Desktop icon @48px actual pixels (zoom x6)  -  solid bbox measured by alpha",
            fill=(28, 32, 40), font=font(19))

    for i, (label, path) in enumerate(ITEMS):
        x0 = PAD + i * (CELL + PAD)
        y0 = TOP
        cell = Image.new("RGB", (CELL, CELL), (255, 255, 255))
        if os.path.exists(path):
            im = IcoImagePlugin.IcoImageFile(path)
            im.size = (SIZE, SIZE)
            im.load()
            fr = im.copy().convert("RGBA").resize((CELL, CELL), Image.NEAREST)
            cell.paste(fr, (0, 0), fr)
            # 实心 bbox 统计
            a = im.copy().convert("RGBA").getchannel("A").point(lambda v: 255 if v >= 250 else 0)
            bb = a.getbbox()
            info = "solid bbox=%s (%.0f%%)" % (str(bb), 100.0 * (bb[2] - bb[0]) * (bb[3] - bb[1]) / (SIZE * SIZE)) if bb else "empty"
            lines.append("%s -> %s" % (label, info))
        else:
            info = "missing"
            lines.append("%s -> missing" % label)
        canvas.paste(cell, (x0, y0))
        d2 = ImageDraw.Draw(canvas)
        d2.text((x0, y0 + CELL + 10), label, fill=(28, 32, 40), font=font(17))
        d2.text((x0, y0 + CELL + 32), info, fill=(120, 60, 40), font=font(15))
        # 画 48px 网格参考框（白色虚线感：用细线）
        d2.rectangle([x0, y0, x0 + CELL - 1, y0 + CELL - 1], outline=(150, 155, 165))

    canvas.save(OUT)
    lines.append("saved: %s (%d B, %s)" % (OUT, os.path.getsize(OUT), canvas.size))
    lines.append("RESULT: OK")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: FAILED")

with open(os.path.join(ROOT, "dev_probe", "_compare48_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
