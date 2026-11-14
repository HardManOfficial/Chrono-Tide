# -*- coding: utf-8 -*-
"""merge_app_icon.py — 将 ico/ 目录下的单尺寸 ICO 合并为一个多尺寸 ICO（字节级无损）

原理：
  ICO 文件 = 6 字节 ICONDIR + N×16 字节 ICONDIRENTRY + 各帧原始图像数据。
  本脚本不重编码像素，只把各单尺寸源文件的"帧"（图像数据 + 目录项元数据）
  原样搬运进一个新的多帧 ICO。PNG/BMP 帧格式保持原样。

注意：
  - 512x512 不能进 ICO：目录项 bWidth/bHeight 只有 1 字节，256 用 0 表示，
    无 512 的表达方式，强行写入会被系统按 256 解析导致损坏。
  - 可复跑：源目录、目标路径均为常量，源不变则输出字节一致。

用法：
  python merge_app_icon.py            # 生成 dev_probe/_out_app_icon.ico 并自验
  python merge_app_icon.py --apply    # 验证通过后覆盖两处正式图标
"""

import os
import struct
import sys

SRC_DIR = r"D:\CTLIB\ico"
OUT_PATH = r"D:\CTLIB\dev_probe\_out_app_icon.ico"
TARGETS = [
    r"D:\CTLIB\windows\runner\resources\app_icon.ico",  # exe 图标（桌面/任务栏/标题栏）
    r"D:\CTLIB\assets\images\app_icon.ico",             # 托盘图标（flutter_assets）
]
SIZES = [16, 24, 32, 48, 64, 128, 256]  # 512 不进 ICO（格式无法表达）

ICONDIR_FMT = "<HHH"      # reserved, type, count
ENTRY_FMT = "<BBBBHHII"   # w, h, colors, reserved, planes, bitcount, size, offset


def parse_ico(path):
    """解析 ICO，返回 [(width, height, planes, bitcount, raw_image_bytes), ...]"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 6:
        raise ValueError(f"{path}: 文件过短")
    reserved, ico_type, count = struct.unpack_from(ICONDIR_FMT, data, 0)
    if reserved != 0 or ico_type != 1:
        raise ValueError(f"{path}: 非 ICO 文件 (type={ico_type})")
    frames = []
    for i in range(count):
        off = 6 + i * 16
        w, h, _c, _r, planes, bitcnt, nbytes, data_off = struct.unpack_from(ENTRY_FMT, data, off)
        w = 256 if w == 0 else w
        h = 256 if h == 0 else h
        frames.append((w, h, planes, bitcnt, data[data_off:data_off + nbytes]))
    return frames


def build_ico(frames):
    """frames: [(w, h, planes, bitcnt, raw), ...] → 多帧 ICO 字节串"""
    out = struct.pack(ICONDIR_FMT, 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    entries = b""
    body = b""
    for w, h, planes, bitcnt, raw in frames:
        entries += struct.pack(
            ENTRY_FMT,
            0 if w >= 256 else w,
            0 if h >= 256 else h,
            0, 0, planes, bitcnt, len(raw), offset,
        )
        body += raw
        offset += len(raw)
    return out + entries + body


def main():
    apply_mode = "--apply" in sys.argv
    collected = {}
    for size in SIZES:
        src = os.path.join(SRC_DIR, f"CT图标_{size}x{size}.ico")
        if not os.path.exists(src):
            print(f"[MISS] {src}")
            continue
        frames = parse_ico(src)
        # 挑与目标尺寸精确匹配的帧
        hit = [fr for fr in frames if fr[0] == size and fr[1] == size]
        if not hit:
            print(f"[FAIL] {size}x{size}: 源中无精确尺寸帧 (实际 {[(f[0], f[1]) for f in frames]})")
            sys.exit(1)
        w, h, planes, bitcnt, raw = hit[0]
        collected[size] = (w, h, planes, bitcnt, raw)
        print(f"[OK]   {size:>3}x{size:<3} planes={planes} bitcount={bitcnt} bytes={len(raw)} "
              f"format={'PNG' if raw[:8] == b'\x89PNG\r\n\x1a\n' else 'BMP'}")

    if len(collected) != len(SIZES):
        print(f"[FAIL] 尺寸缺失: 期望 {len(SIZES)} 帧, 实得 {len(collected)}")
        sys.exit(1)

    payload = build_ico([collected[s] for s in SIZES])
    with open(OUT_PATH, "wb") as f:
        f.write(payload)
    print(f"[WRITE] {OUT_PATH} ({len(payload)} bytes)")

    # 自验：重新解析输出文件
    verify = parse_ico(OUT_PATH)
    got = sorted((w, h) for w, h, *_ in verify)
    expect = sorted((s, s) for s in SIZES)
    if got != expect:
        print(f"[FAIL] 自验失败: {got}")
        sys.exit(1)
    print(f"[VERIFY] 帧表一致: {got}")

    if apply_mode:
        for t in TARGETS:
            with open(t, "wb") as f:
                f.write(payload)
            check = os.path.getsize(t)
            if check != len(payload):
                print(f"[FAIL] 落盘大小不符: {t} ({check} != {len(payload)})")
                sys.exit(1)
            print(f"[APPLY] {t} ({check} bytes)")
    else:
        print("[HINT] 验证通过。加 --apply 覆盖正式图标。")


if __name__ == "__main__":
    main()
