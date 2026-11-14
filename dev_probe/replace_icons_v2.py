# -*- coding: utf-8 -*-
"""replace_icons_v2.py — 全局图标二次换新（bmp 帧多尺寸 ICO）v2

与 v1 (make_app_icon_ico.py) 的差异：
  1. 源命名适配：优先 ico/app_NxN.ico，回退 ico/CT图标_NxN.ico
  2. 备份策略：按「当前文件 md5 前 8 位」命名（<name>_<md5>.ico），md5 已存在则跳过
     —— 保证每次被覆盖的版本都留有副本，且不重复堆叠
  3. 内联全部验证（反向解析 / PIL 解码 / 源图逐像素 / 三处 md5 一致）+ git 自查

覆盖三处：
  windows/runner/resources/app_icon.ico  exe 图标（Runner.rc:55）
  assets/images/app_icon.ico             托盘（tray_service.dart:107）
  ChronoTide.ico                         安装器（Setup.iss:31）
输出: dev_probe/replace_icons_v2_result.txt
"""
import hashlib
import os
import shutil
import struct
import subprocess
import traceback

from PIL import Image, IcoImagePlugin, ImageChops

ROOT = r"D:\CTLIB"
SRC_DIR = os.path.join(ROOT, "ico")
BACKUP_DIR = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
RESULT_TXT = os.path.join(ROOT, "dev_probe", "replace_icons_v2_result.txt")
GIT_DIR = os.path.join(ROOT, "dev_probe")

TARGETS = [
    (os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico"), "runner_app_icon.ico"),
    (os.path.join(ROOT, "assets", "images", "app_icon.ico"), "assets_app_icon.ico"),
    (os.path.join(ROOT, "ChronoTide.ico"), "root_ChronoTide.ico"),
]
SRC_PATTERNS = ["app_%dx%d.ico", "CT图标_%dx%d.ico"]
SIZES = [16, 24, 32, 48, 64, 128, 256]  # 512 排除（ICO 目录项 1 字节上限 256）

lines = []


def md5(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def src_path(size):
    for pat in SRC_PATTERNS:
        p = os.path.join(SRC_DIR, pat % (size, size))
        if os.path.exists(p):
            return p
    return None


def load_rgba(size):
    p = src_path(size)
    if p is None:
        raise RuntimeError("源缺失: %s (尝试 %s)" % (size, SRC_PATTERNS))
    im = Image.open(p).convert("RGBA")
    if im.size != (size, size):
        raise RuntimeError("FATAL 尺寸不符: %s -> %s" % (p, im.size))
    return im, p


def frame_bmp(img):
    """单帧 -> 32bpp BMP（bottom-up 行序 + 全 0 AND mask）"""
    w, h = img.size
    bottom_up = img.transpose(Image.FLIP_TOP_BOTTOM)
    raw = bottom_up.tobytes()
    bgra = bytearray(raw)
    bgra[0::4] = raw[2::4]
    bgra[2::4] = raw[0::4]
    and_row = ((w + 31) // 32) * 4
    mask = b"\x00" * (and_row * h)
    hdr = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(bgra) + len(mask), 0, 0, 0, 0)
    return hdr + bytes(bgra) + mask


def build_ico():
    imgs = [load_rgba(s)[0] for s in SIZES]
    frames = [frame_bmp(im) for im in imgs]
    offset = 6 + 16 * len(frames)
    entries = b""
    body = b""
    for size, fr in zip(SIZES, frames):
        entries += struct.pack("<BBBBHHII", size & 0xFF, size & 0xFF, 0, 0, 1, 32, len(fr), offset)
        body += fr
        offset += len(fr)
    return struct.pack("<HHH", 0, 1, len(frames)) + entries + body


def parse_ico(path):
    data = open(path, "rb").read()
    _reserved, itype, count = struct.unpack("<HHH", data[:6])
    sizes, offsets = [], []
    for i in range(count):
        e = data[6 + 16 * i: 6 + 16 * (i + 1)]
        w = e[0]
        sizes.append(256 if w == 0 else w)
        offsets.append(struct.unpack("<I", e[12:16])[0])
    return itype, count, sizes, offsets, len(data)


def run_git(args, tag):
    f = os.path.join(GIT_DIR, "_v2_git_%s.txt" % tag)
    try:
        with open(f, "wb") as fh:
            subprocess.run(["git", "-C", ROOT] + args, stdout=fh, stderr=subprocess.STDOUT, timeout=120)
        with open(f, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except Exception as e:
        return "EXC: %r" % (e,)


try:
    # 0. 源齐全
    resolved = [(s, src_path(s)) for s in SIZES]
    missing = [s for s, p in resolved if p is None]
    if missing:
        raise RuntimeError("FATAL 源缺失: %s" % missing)
    lines.append("源 7/7 齐全: %s" % ", ".join(os.path.basename(p) for _s, p in resolved))

    # 1. 备份当前三处（md5 命名去重）
    os.makedirs(BACKUP_DIR, exist_ok=True)
    for t, bak_name in TARGETS:
        if not os.path.exists(t):
            lines.append("备份: 目标不存在，跳过 %s" % t)
            continue
        h = md5(t)[:8]
        stem, ext = os.path.splitext(bak_name)
        bak = os.path.join(BACKUP_DIR, "%s_%s%s" % (stem, h, ext))
        if os.path.exists(bak):
            lines.append("备份: 副本已存在(md5=%s)，跳过 %s" % (h, os.path.basename(bak)))
        else:
            shutil.copy2(t, bak)
            lines.append("备份: %s -> %s (%d B)" % (os.path.relpath(t, ROOT), os.path.basename(bak), os.path.getsize(t)))

    # 2. 构建
    ico = build_ico()
    lines.append("生成 32bpp BMP 帧多尺寸 ICO: %d bytes, 尺寸=%s" % (len(ico), SIZES))

    # 3. 写入三处
    for t, _b in TARGETS:
        with open(t, "wb") as f:
            f.write(ico)
        ok = os.path.getsize(t) == len(ico)
        lines.append("写入: %-42s %d B %s" % (os.path.relpath(t, ROOT), os.path.getsize(t), "OK" if ok else "FAIL"))

    # 4. 验证
    tgt = TARGETS[0][0]
    for t, _b in TARGETS:
        itype, count, sizes, offsets, total = parse_ico(t)
        im = Image.open(t)
        im.load()
        lines.append("验证: %-42s type=%d frames=%d sizes=%s PIL=%s total=%d"
                     % (os.path.relpath(t, ROOT), itype, count, sizes, im.size, total))
        for off in offsets:
            if off >= total:
                raise RuntimeError("帧偏移越界 @%d" % off)

    # 5. 逐帧像素/方向 vs 新源
    lines.append("--- 源图逐像素校验（含方向）---")
    same_cnt = 0
    for s in SIZES:
        src_img, sp = load_rgba(s)
        ico_im = IcoImagePlugin.IcoImageFile(tgt)
        ico_im.size = (s, s)
        ico_im.load()
        fr = ico_im.copy().convert("RGBA")
        same = ImageChops.difference(src_img, fr).getbbox() is None
        flipped = ImageChops.difference(src_img.transpose(Image.FLIP_TOP_BOTTOM), fr).getbbox() is None
        verdict = "SAME" if same else ("FLIPPED!!" if flipped else "DIFF!!")
        same_cnt += 1 if same else 0
        lines.append("  %3dx%-3d 源=%s => %s" % (s, s, os.path.basename(sp), verdict))
    lines.append("方向/像素一致: %d/7" % same_cnt)
    if same_cnt != 7:
        raise RuntimeError("逐像素校验未全通过")

    # 6. 三处 md5 一致性
    hs = [md5(t) for t, _b in TARGETS]
    lines.append("三处 md5: %s => %s" % (", ".join(h[:12] for h in hs), "一致 OK" if len(set(hs)) == 1 else "!! 不一致"))
    if len(set(hs)) != 1:
        raise RuntimeError("三处 md5 不一致")

    lines.append("RESULT: ALL_OK")
except BaseException:
    lines.append("TRACEBACK:")
    lines.append(traceback.format_exc())
    lines.append("RESULT: FAILED")
finally:
    # 7. git 自查
    try:
        lines.append("")
        lines.append("--- git status --porcelain（ico 相关）---")
        st = run_git(["status", "--porcelain"], "status")
        for ln in st.splitlines():
            if "ico" in ln.lower() or "ChronoTide" in ln:
                lines.append("  " + ln)
        lines.append("--- git diff --stat（前三行）---")
        ds = run_git(["diff", "--stat"], "diff")
        lines.append("\n".join(ds.splitlines()[:8]))
    except BaseException:
        lines.append("git 自查异常: %s" % traceback.format_exc())
    with open(RESULT_TXT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
