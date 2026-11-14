# -*- coding: utf-8 -*-
"""
make_app_icon_ico.py — 用 ico/ 目录的新版 CT 图标生成全局应用图标

把 ico/ 下 7 张单尺寸 ICO(16..256) 合并为一张多尺寸 ICO（32bpp BMP 帧，最大兼容），
覆盖三处使用点：
  1. windows/runner/resources/app_icon.ico → exe 图标（Runner.rc:55 IDI_APP_ICON，桌面/任务栏/资源管理器）
  2. assets/images/app_icon.ico            → 托盘图标源（tray_service.dart:107 运行时从 flutter_assets 加载）
  3. ChronoTide.ico                        → 安装器图标源（ChronoTide_Setup.iss:31 SetupIconFile）

512x512 帧不进 ICO：非 Windows 标准尺寸，exe 图标最大 256 即可，且省约 1MB 体积。
旧文件先备份到 dev_probe/_old_icons_backup/。
结果写入 dev_probe/make_app_icon_ico_result.txt（本环境 C 盘满导致管道输出不可靠）。
"""
import os
import shutil
import struct

from PIL import Image

ROOT = r"D:\CTLIB"
SRC_DIR = os.path.join(ROOT, "ico")
BACKUP_DIR = os.path.join(ROOT, "dev_probe", "_old_icons_backup")
RESULT_TXT = os.path.join(ROOT, "dev_probe", "make_app_icon_ico_result.txt")

# (目标路径, 备份文件名)
TARGETS = [
    (os.path.join(ROOT, "windows", "runner", "resources", "app_icon.ico"), "runner_app_icon.ico"),
    (os.path.join(ROOT, "assets", "images", "app_icon.ico"), "assets_app_icon.ico"),
    (os.path.join(ROOT, "ChronoTide.ico"), "root_ChronoTide.ico"),
]
SIZES = [16, 24, 32, 48, 64, 128, 256]  # 512 排除：非标准尺寸


def src_path(size):
    return os.path.join(SRC_DIR, "CT图标_%dx%d.ico" % (size, size))


def load_rgba(size):
    im = Image.open(src_path(size))
    fr = im.convert("RGBA")
    if fr.size != (size, size):
        raise SystemExit("FATAL 尺寸不符: %s -> %s" % (src_path(size), fr.size))
    return fr


def frame_bmp(img):
    """单帧 → 32bpp BMP（BITMAPINFOHEADER + BGRA 数据 + 全 0 AND mask）

    ICO 的 BMP 帧标准为 bottom-up 行序：写入前先垂直翻转，
    Windows 自底向上解码后即恢复正确方向。
    """
    w, h = img.size
    bottom_up = img.transpose(Image.FLIP_TOP_BOTTOM)
    raw = bottom_up.tobytes()  # RGBA 行优先（已翻转）
    bgra = bytearray(raw)
    bgra[0::4] = raw[2::4]  # B <- B
    bgra[2::4] = raw[0::4]  # R <- R
    and_row = ((w + 31) // 32) * 4
    mask = b"\x00" * (and_row * h)  # 32bpp 带 alpha 时 AND mask 全 0
    hdr = struct.pack(
        "<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(bgra) + len(mask), 0, 0, 0, 0
    )
    return hdr + bytes(bgra) + mask


def build_ico():
    imgs = [load_rgba(s) for s in SIZES]
    frames = [frame_bmp(im) for im in imgs]
    n = len(frames)
    offset = 6 + 16 * n
    entries = b""
    body = b""
    for size, fr in zip(SIZES, frames):
        entries += struct.pack(
            "<BBBBHHII", size & 0xFF, size & 0xFF, 0, 0, 1, 32, len(fr), offset
        )
        body += fr
        offset += len(fr)
    return struct.pack("<HHH", 0, 1, n) + entries + body


def parse_ico(path):
    """反向解析输出文件，独立验证帧表"""
    with open(path, "rb") as f:
        data = f.read()
    _reserved, itype, count = struct.unpack("<HHH", data[:6])
    sizes = []
    offsets = []
    for i in range(count):
        e = data[6 + 16 * i : 6 + 16 * (i + 1)]
        w, _h = e[0], e[1]
        sizes.append(256 if w == 0 else w)
        offsets.append(struct.unpack("<I", e[12:16])[0])
    return itype, count, sizes, offsets, len(data)


def main():
    lines = []
    try:
        # 0. 源文件齐全性
        missing = [s for s in SIZES if not os.path.exists(src_path(s))]
        if missing:
            raise SystemExit("FATAL 源缺失: %s" % missing)
        lines.append("源文件 7/7 齐全 (%s)" % SRC_DIR)

        # 1. 备份旧图标（已存在则跳过：重跑时保留最早的原始备份）
        os.makedirs(BACKUP_DIR, exist_ok=True)
        for t, bak_name in TARGETS:
            if os.path.exists(t):
                bak = os.path.join(BACKUP_DIR, bak_name)
                if os.path.exists(bak):
                    lines.append("备份: 已存在，跳过 %s" % bak)
                    continue
                shutil.copy2(t, bak)
                lines.append(
                    "备份: %s -> %s (%d bytes)" % (t, bak, os.path.getsize(t))
                )
            else:
                lines.append("备份: 目标不存在，跳过 %s" % t)

        # 2. 构建多尺寸 ICO
        ico = build_ico()
        lines.append("生成多尺寸 ICO: %d bytes, 尺寸=%s" % (len(ico), SIZES))

        # 3. 写三处目标
        for t, _bak in TARGETS:
            with open(t, "wb") as f:
                f.write(ico)
            ok = os.path.exists(t) and os.path.getsize(t) == len(ico)
            lines.append("写入: %s (%d bytes) %s" % (t, os.path.getsize(t), "OK" if ok else "FAIL"))

        # 4. 独立验证：反向解析 + PIL 可解码
        for t, _bak in TARGETS:
            itype, count, sizes, offsets, total = parse_ico(t)
            im = Image.open(t)
            im.load()
            lines.append(
                "验证: %s type=%d frames=%d sizes=%s max_frame=%s total=%d PIL解码=OK"
                % (os.path.relpath(t, ROOT), itype, count, sizes, im.size, total)
            )
            # 帧偏移越界检查
            for off, size in zip(offsets, sizes):
                if off >= total:
                    raise SystemExit("FATAL 帧偏移越界 %s @%d" % (size, off))

        lines.append("RESULT: ALL_OK")
    except Exception as exc:  # noqa: BLE001
        lines.append("RESULT: FAILED — %r" % exc)
        raise
    finally:
        with open(RESULT_TXT, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
