# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 G：补充验证
  G1 `.partial` 后缀能否用 -t7z 强制类型正常压缩（Dart 侧做半成品标记的前提）
  G2 压缩吞吐实测（可压 / 不可压 × mx=5 / mx=1），校正方案 §6 的 30–80MB/s 预估
  G3 `7z t` 校验耗时（删本体前必做，需知成本）
"""
import os
import sys
import json
import time
import shutil
import subprocess

SEVENZ = r"D:\CTLIB\windows\runner\tools\7z.exe"
ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "out")
EDGE = os.path.join(ROOT, "edge")
PROBE_DIR = r"D:\CTLIB\dev_probe"


def timed(args, cwd=ROOT):
    t0 = time.time()
    p = subprocess.Popen([SEVENZ] + args, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=cwd)
    out, err = p.communicate()
    return p.returncode, time.time() - t0, out, err


def mbps(total_bytes, sec):
    return (total_bytes / 1048576.0) / sec if sec > 0 else -1


def main():
    os.makedirs(EDGE, exist_ok=True)
    res = {}

    # ---------- G1 .partial 命名 ----------
    part = os.path.join(EDGE, "body.7z.partial")
    if os.path.exists(part):
        os.remove(part)
    rc, dt, _, _ = timed(["a", "-t7z", "-mx=1", "-mmt=2", "-y", part, r"src\many_small"])
    exists = os.path.exists(part)
    # 7z t 能否识别它
    t_exit = None
    if exists:
        p = subprocess.run([SEVENZ, "t", part], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, cwd=ROOT)
        t_exit = p.returncode
    res["partial_naming"] = {
        "exit": rc, "created": exists, "test_exit": t_exit,
        "size": os.path.getsize(part) if exists else -1,
    }
    print(f"[G1] .partial 命名: exit={rc} 生成={exists} 7z t exit={t_exit}")

    # ---------- G2 吞吐 ----------
    cases = [
        ("可压-48MB-mx5", os.path.join(SRC, "big_compressible.dat"), "-mx=5"),
        ("可压-48MB-mx1", os.path.join(SRC, "big_compressible.dat"), "-mx=1"),
        ("随机-64MB-mx5", os.path.join(SRC, "big_incompressible", "rand_0.bin"), "-mx=5"),
    ]
    tp = {}
    for tag, target, mx in cases:
        out = os.path.join(EDGE, f"tp_{tag}.7z")
        if os.path.exists(out):
            os.remove(out)
        sz = os.path.getsize(target)
        rc, dt, _, _ = timed(["a", "-t7z", mx, "-md=64m", "-mmt=2", "-y", out,
                              os.path.relpath(target, ROOT)])
        osz = os.path.getsize(out) if os.path.exists(out) else -1
        tp[tag] = {
            "src_bytes": sz, "archive_bytes": osz, "seconds": round(dt, 2),
            "src_mb_s": round(mbps(sz, dt), 2),
            "ratio": round(osz / sz, 3) if sz else -1,
        }
        print(f"[G2] {tag}: {sz/1048576:.0f}MB → {osz/1048576:.1f}MB "
              f"用 {dt:.1f}s = {mbps(sz, dt):.1f} MB/s (压缩率 {osz/sz:.3f})")
        os.remove(out)
    res["throughput"] = tp

    # ---------- G3 7z t 校验耗时 ----------
    v1 = os.path.join(OUT, "v1.7z")
    if os.path.exists(v1):
        sz = os.path.getsize(v1)
        p = subprocess.Popen([SEVENZ, "t", v1], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, cwd=ROOT)
        t0 = time.time()
        out, err = p.communicate()
        dt = time.time() - t0
        tail = out.decode("utf-8", "replace").strip().splitlines()[-5:]
        res["verify_cost"] = {
            "archive_bytes": sz, "seconds": round(dt, 2),
            "mb_s": round(mbps(sz, dt), 2), "exit": p.returncode, "tail": tail,
        }
        print(f"[G3] 7z t 校验: 归档 {sz/1048576:.1f}MB 用 {dt:.1f}s "
              f"= {mbps(sz, dt):.1f} MB/s, exit={p.returncode}")

    with open(os.path.join(PROBE_DIR, "phase0_extra_result.json"), "w",
              encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print("[G] 结果已写: dev_probe/phase0_extra_result.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
