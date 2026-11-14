# -*- coding: utf-8 -*-
"""inspect_new_icons.py — 只读审计：ico/ 新源包 + 当前三处目标 + 历史备份（含帧格式/像素差异）
输出: dev_probe/_inspect_new_icons.txt
"""
import hashlib
import os
import struct
import traceback

from PIL import Image, IcoImagePlugin, ImageChops

ROOT = r"D:\CTLIB"
SRC = os.path.join(ROOT, "ico")
BAK = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
OUT = os.path.join(ROOT, "dev_probe", "_inspect_new_icons.txt")

TARGETS = [
    ("windows/runner/resources/app_icon.ico", "runner_app_icon.ico", "exe 图标(Runner.rc:55)"),
    ("assets/images/app_icon.ico", "assets_app_icon.ico", "托盘(tray_service.dart:107)"),
    ("ChronoTide.ico", "root_ChronoTide.ico", "安装器(Setup.iss:31)"),
]
SIZES = [16, 24, 32, 48, 64, 128, 256]

lines = []


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def frame_kinds(path):
    """解析 ICO 目录表，返回 [(px, 'PNG'|'BMP(hdr)')]"""
    data = open(path, "rb").read()
    if len(data) < 6:
        return []
    _, _, n = struct.unpack("<HHH", data[:6])
    out = []
    for i in range(n):
        e = data[6 + 16 * i: 6 + 16 * (i + 1)]
        if len(e) < 16:
            break
        w = e[0]
        px = 256 if w == 0 else w
        off = struct.unpack("<I", e[12:16])[0]
        sig = data[off:off + 8]
        if sig == b"\x89PNG\r\n\x1a\n":
            k = "PNG"
        else:
            hdr = struct.unpack("<I", data[off:off + 4])[0] if off + 4 <= len(data) else -1
            k = "BMP(hdr=%d)" % hdr
        out.append((px, k))
    return out


try:
    # ---------- A. 新源包 ico/ ----------
    lines.append("=== A. 新源包 %s ===" % SRC)
    if not os.path.isdir(SRC):
        lines.append("!! 目录不存在")
    else:
        names = sorted(os.listdir(SRC))
        lines.append("文件数: %d" % len(names))
        for nm in names:
            p = os.path.join(SRC, nm)
            if not os.path.isfile(p):
                lines.append("  [DIR] %s" % nm)
                continue
            sz = os.path.getsize(p)
            try:
                im = Image.open(p)
                pil_sizes = sorted(im.info.get("sizes") or [im.size], key=lambda x: x[0])
                fk = frame_kinds(p)
                lines.append("  %-18s %8d B  md5=%s  PIL帧=%s  实际帧=%s"
                             % (nm, sz, md5(p)[:12], pil_sizes, fk))
            except Exception as e:
                lines.append("  %-18s %8d B  !! PIL 打开失败: %r  frames=%s"
                             % (nm, sz, e, frame_kinds(p)))

    # ---------- B. 当前三处目标 ----------
    lines.append("")
    lines.append("=== B. 当前三处目标 ===")
    for rel, bak_name, desc in TARGETS:
        p = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.exists(p):
            lines.append("  !! 不存在: %s" % p)
            continue
        sz = os.path.getsize(p)
        fk = frame_kinds(p)
        lines.append("  %-42s %8d B  md5=%s  %s" % (rel, sz, md5(p)[:12], desc))
        lines.append("      帧: %s" % (fk,))

    # ---------- C. 历史备份 ----------
    lines.append("")
    lines.append("=== C. 备份目录 %s ===" % BAK)
    if os.path.isdir(BAK):
        for nm in sorted(os.listdir(BAK)):
            p = os.path.join(BAK, nm)
            if os.path.isfile(p):
                lines.append("  %-26s %8d B  md5=%s  帧=%s"
                             % (nm, os.path.getsize(p), md5(p)[:12], frame_kinds(p)))
    else:
        lines.append("  !! 不存在")

    # ---------- D. 新旧差异：新源 256 帧 vs 当前 target 256 帧 ----------
    lines.append("")
    lines.append("=== D. 像素差异（新源 vs 当前已上线版本，取同名尺寸） ===")
    tgt = os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico")
    for s in SIZES:
        sp = os.path.join(SRC, "app_%dx%d.ico" % (s, s))
        if not (os.path.exists(sp) and os.path.exists(tgt)):
            lines.append("  %3dx%-3d 源或目标缺失，跳过" % (s, s))
            continue
        try:
            a = Image.open(sp).convert("RGBA")
            b = IcoImagePlugin.IcoImageFile(tgt)
            b.size = (s, s)
            b.load()
            c = b.copy().convert("RGBA")
            d = ImageChops.difference(a, c)
            bbox = d.getbbox()
            if bbox is None:
                lines.append("  %3dx%-3d 与当前上线版【完全一致】(新旧同图)" % (s, s))
            else:
                # 差异像素占比
                gray = d.convert("L")
                hist = gray.histogram()
                diff_px = sum(hist[1:])
                lines.append("  %3dx%-3d 【有差异】bbox=%s 差异像素=%d/%d (%.1f%%)"
                             % (s, s, bbox, diff_px, s * s, 100.0 * diff_px / (s * s)))
        except Exception as e:
            lines.append("  %3dx%-3d 比对异常: %r" % (s, s, e))

    # ---------- E. 512 源信息（不进 ICO，仅记录） ----------
    lines.append("")
    p512 = os.path.join(SRC, "app_512x512.ico")
    if os.path.exists(p512):
        lines.append("=== E. 512 源: %d B, 帧=%s（合并时排除：ICO 目录项 1 字节上限 256）"
                     % (os.path.getsize(p512), frame_kinds(p512)))

    lines.append("")
    lines.append("RESULT: AUDIT_DONE")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: AUDIT_FAILED")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
