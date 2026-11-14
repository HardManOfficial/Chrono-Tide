# -*- coding: utf-8 -*-
"""gen_overscan_preview.py — 三档放大裁切（1.00 / 1.08 / 1.15）在 48px 下的实测预览
输出: dev_probe/icon_overscan_preview.png
"""
import os
import traceback

from PIL import Image, ImageDraw, ImageFont, IcoImagePlugin

ROOT = r"D:\CTLIB"
SRC_ICO = os.path.join(ROOT, "ico", "app_48x48.ico")
SRC_BIG = os.path.join(ROOT, "ico", "app_256x256.ico")
OUT = os.path.join(ROOT, "dev_probe", "icon_overscan_preview.png")
FACTORS = [1.00, 1.08, 1.15]
ZOOM = 6
PAD = 26


def font(sz):
    for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\arial.ttf"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            continue
    return ImageFont.load_default()


def load(path, size):
    im = IcoImagePlugin.IcoImageFile(path)
    im.size = (size, size)
    im.load()
    return im.copy().convert("RGBA")


def overscan(img, f):
    if abs(f - 1.0) < 1e-6:
        return img
    w, h = img.size
    nw, nh = int(round(w * f)), int(round(h * f))
    big = img.resize((nw, nh), Image.LANCZOS)
    l, t = (nw - w) // 2, (nh - h) // 2
    return big.crop((l, t, l + w, t + h))


rows = [(48, SRC_ICO, "48px (medium desktop icon)"), (256, SRC_BIG, "256px (large/zoom reference)")]
lines = []
try:
    W = len(FACTORS) * 48 * ZOOM + PAD * (len(FACTORS) + 1)
    row_h = 48 * ZOOM + 76
    H = 60 + row_h * len(rows) + PAD
    canvas = Image.new("RGB", (W, H), (238, 240, 244))
    dr = ImageDraw.Draw(canvas)
    dr.text((PAD, 16), u"Over-scan test: content enlarged then cropped to canvas (same design, larger visual body)",
            fill=(28, 32, 40), font=font(19))

    for ri, (size, src, label) in enumerate(rows):
        base = load(src, size)
        y0 = 60 + ri * row_h
        dr.text((PAD, y0), label, fill=(28, 32, 40), font=font(16))
        for ci, f in enumerate(FACTORS):
            img = overscan(base, f).resize((48 * ZOOM, 48 * ZOOM), Image.NEAREST)
            x0 = PAD + ci * (48 * ZOOM + PAD)
            yy = y0 + 24
            cell = Image.new("RGB", (48 * ZOOM, 48 * ZOOM), (255, 255, 255))
            cell.paste(img, (0, 0), img)
            canvas.paste(cell, (x0, yy))
            d2 = ImageDraw.Draw(canvas)
            d2.rectangle([x0, yy, x0 + 48 * ZOOM - 1, yy + 48 * ZOOM - 1], outline=(150, 155, 165))
            d2.text((x0, yy + 48 * ZOOM + 6), "x%.2f" % f, fill=(120, 60, 40), font=font(17))
            lines.append("row %s factor %.2f ok" % (size, f))

    canvas.save(OUT)
    lines.append("saved: %s (%d B, %s)" % (OUT, os.path.getsize(OUT), canvas.size))
    lines.append("RESULT: OK")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: FAILED")

with open(os.path.join(ROOT, "dev_probe", "_overscan_result.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
