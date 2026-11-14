# -*- coding: utf-8 -*-
"""measure_alpha_bands.py — 分档测量图标"实心主体"占比（只读）
对每帧按 alpha 阈值分档求 bbox：250/200/128/64/16/1
若"≥250 实心区"远小于全帧，说明外圈是半透明光晕 → 视觉上图标会显小。
输出: dev_probe/_alpha_bands.txt
"""
import os
import traceback

from PIL import Image, IcoImagePlugin

ROOT = r"D:\CTLIB"
SRC = os.path.join(ROOT, "ico")
CUR = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
BAK = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
BANDS = [250, 200, 128, 64, 16, 1]
SIZES = [16, 32, 48, 64, 256]

lines = []


def frame_rgba(path, size):
    im = IcoImagePlugin.IcoImageFile(path)
    im.size = (size, size)
    im.load()
    f = im.copy().convert("RGBA")
    return f if f.size == (size, size) else None


def bands(path, size):
    f = frame_rgba(path, size)
    if f is None:
        return None
    a = f.getchannel("A")
    w, h = a.size
    total = float(w * h)
    res = {}
    for thr in BANDS:
        b = a.point(lambda v: 255 if v >= thr else 0)
        bbox = b.getbbox()
        cnt = b.histogram()[255]
        if bbox is None:
            res[thr] = (0, 0, 0, 0.0, 0.0)
            continue
        x0, y0, x1, y1 = bbox
        bw, bh = x1 - x0, y1 - y0
        res[thr] = (bw, bh, cnt, 100.0 * bw * bh / total, 100.0 * cnt / total)
    return res


def dump(title, path, sizes=None):
    lines.append("")
    lines.append("=== %s ===" % title)
    if not os.path.exists(path):
        lines.append("  缺失: %s" % path)
        return
    lines.append("  %s (%d B)" % (path, os.path.getsize(path)))
    lines.append("  %5s | %-52s" % ("尺寸", "各阈值: 内容宽x高 (bbox面积占% / 像素占%)"))
    for s in (sizes or SIZES):
        try:
            r = bands(path, s)
        except Exception as e:
            lines.append("  %5d | 读取失败: %r" % (s, e))
            continue
        if r is None:
            lines.append("  %5d | 无此尺寸帧" % s)
            continue
        parts = []
        for thr in BANDS:
            bw, bh, cnt, area_pct, px_pct = r[thr]
            parts.append("a>=%3d: %2dx%-3d bbox%5.1f%% px%5.1f%%" % (thr, bw, bh, area_pct, px_pct))
        lines.append("  %5d | %s" % (s, parts[0]))
        for p in parts[1:]:
            lines.append("  %5s | %s" % ("", p))


try:
    dump("A. 新源 ico/app_NxN.ico（本次上线）",
         os.path.join(SRC, "app_48x48.ico"), sizes=[48])
    dump("A2. 新源 256", os.path.join(SRC, "app_256x256.ico"), sizes=[256])
    dump("B. 当前落盘 app_icon.ico", CUR, sizes=[48, 256])
    dump("C. v1 PNG 帧版（上一版）", os.path.join(BAK, "assets_app_icon.ico"), sizes=[48, 256])
    dump("D. 开发者原始图标（最早）", os.path.join(BAK, "root_ChronoTide.ico"), sizes=[48])
    lines.append("")
    lines.append("RESULT: BANDS_DONE")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: BANDS_FAILED")

with open(os.path.join(ROOT, "dev_probe", "_alpha_bands.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
