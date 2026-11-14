# -*- coding: utf-8 -*-
"""measure_icon_padding.py — 量化各版本图标「图形内容占画布比例」（只读）
对每个 ICO 的每帧：用 alpha 通道求非透明包围盒 → 内容占比 + 四周留白。
输出: dev_probe/_measure_padding.txt
"""
import os
import traceback

from PIL import Image, IcoImagePlugin

ROOT = r"D:\CTLIB"
SRC = os.path.join(ROOT, "ico")
CUR = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
BAK = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
SIZES = [16, 24, 32, 48, 64, 128, 256]
ALPHA_MIN = 16  # 低于此 alpha 视为"不可见留白"（排除极淡阴影边缘噪声）

lines = []


def frame_rgba(ico_path, size):
    im = IcoImagePlugin.IcoImageFile(ico_path)
    im.size = (size, size)
    im.load()
    f = im.copy().convert("RGBA")
    if f.size != (size, size):
        return None
    return f


def analyze(ico_path, size, thr=ALPHA_MIN):
    f = frame_rgba(ico_path, size)
    if f is None:
        return None
    a = f.getchannel("A").point(lambda v: 255 if v >= thr else 0)
    bbox = a.getbbox()
    if bbox is None:
        return ("EMPTY", 0, 0, 0, 0, 0.0)
    x0, y0, x1, y1 = bbox
    cw, ch = x1 - x0, y1 - y0
    return (bbox, cw, ch, size - cw, size - ch, 100.0 * (cw * ch) / float(size * size))


def dump(title, path, sizes=None):
    lines.append("")
    lines.append("=== %s ===" % title)
    lines.append("  %s (%s)" % (path, ("%d B" % os.path.getsize(path)) if os.path.exists(path) else "缺失"))
    if not os.path.exists(path):
        return
    lines.append("  %5s | %-22s | %-8s | %-12s | %s" % ("尺寸", "alpha bbox", "内容宽高", "顶部留白", "内容面积占比"))
    for s in (sizes or SIZES):
        try:
            r = analyze(path, s)
        except Exception as e:
            lines.append("  %5d | 读取失败: %r" % (s, e))
            continue
        if r is None:
            lines.append("  %5d | (无此尺寸帧)" % s)
            continue
        bbox, cw, ch, padw, padh, ratio = r
        if bbox == "EMPTY":
            lines.append("  %5d | 全透明!" % s)
            continue
        top_pad = bbox[1]
        bottom_pad = s - bbox[3]
        left_pad = bbox[0]
        right_pad = s - bbox[2]
        lines.append("  %5d | %-22s | %-8s | 上%-3d 下%-3d 左%-3d 右%-3d | %.1f%%"
                     % (s, str(bbox), "%dx%d" % (cw, ch), top_pad, bottom_pad, left_pad, right_pad, ratio))


try:
    lines.append("ALPHA 阈值: >= %d 视为可见内容" % ALPHA_MIN)
    for s in SIZES:
        dump("A. 新源包 ico/app_%dx%d.ico（本次采用）" % (s, s),
             os.path.join(SRC, "app_%dx%d.ico" % (s, s)), sizes=[s])
    dump("B. 当前落盘 app_icon.ico（=替换后）", CUR)
    dump("C. v1 PNG 帧版（_old_icons_backup/assets_app_icon.ico）", os.path.join(BAK, "assets_app_icon.ico"))
    dump("D. 开发者原始图标（_old_icons_backup/root_ChronoTide.ico）", os.path.join(BAK, "root_ChronoTide.ico"))

    # 汇总对比：16 / 48 / 256 三个代表尺寸
    lines.append("")
    lines.append("=== E. 汇总（内容面积占比 %）===")
    lines.append("  %-36s %8s %8s %8s" % ("版本", "16px", "48px", "256px"))
    rows = [
        ("新源 app_NxN（当前上线）", lambda s: os.path.join(SRC, "app_%dx%d.ico" % (s, s))),
        ("v1 PNG 帧版（上一版）", lambda s: os.path.join(BAK, "assets_app_icon.ico")),
        ("原始图标（最早）", lambda s: os.path.join(BAK, "root_ChronoTide.ico")),
    ]
    for title, pf in rows:
        row = []
        for s in (16, 48, 256):
            try:
                r = analyze(pf(s), s)
                row.append("%.1f%%" % r[5] if r and r[0] != "EMPTY" else "-")
            except Exception:
                row.append("ERR")
        lines.append("  %-36s %8s %8s %8s" % (title, row[0], row[1], row[2]))

    lines.append("")
    lines.append("RESULT: MEASURE_DONE")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: MEASURE_FAILED")

with open(os.path.join(ROOT, "dev_probe", "_measure_padding.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
