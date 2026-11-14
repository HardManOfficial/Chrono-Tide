# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 E：0.6 中断行为
验证：压缩中途 kill 进程后 —— ① 源目录是否零损伤 ② 半成品如何残留
      ③ 半成品能否被 7z t 识别为损坏（用于启动时清理判据）
"""
import os
import sys
import json
import time
import subprocess

SEVENZ = r"D:\CTLIB\windows\runner\tools\7z.exe"
ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
EDGE = os.path.join(ROOT, "edge")
PROBE_DIR = r"D:\CTLIB\dev_probe"


def count_files(root):
    n = 0
    for dp, dn, fn in os.walk(root):
        n += len(fn)
    return n


def dir_size(root):
    t = 0
    for dp, dn, fn in os.walk(root):
        for f in fn:
            try:
                t += os.path.getsize(os.path.join(dp, f))
            except OSError:
                pass
    return t


def main():
    os.makedirs(EDGE, exist_ok=True)
    res = {}

    before_cnt = count_files(SRC)
    before_size = dir_size(SRC)
    outs_before = set(os.listdir(EDGE))

    int_out = os.path.join(EDGE, "interrupted.7z")
    print("[E] 启动压缩，4 秒后 kill ...")
    p = subprocess.Popen(
        [SEVENZ, "a", "-t7z", "-mx=5", "-md=64m", "-mmt=2", "-y",
         int_out, r"src\*"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
    time.sleep(4)
    killed = p.poll() is None
    p.kill()
    out, err = p.communicate()
    rc = p.returncode
    time.sleep(1.5)

    outs_after = set(os.listdir(EDGE))
    new_files = sorted(outs_after - outs_before)

    after_cnt = count_files(SRC)
    after_size = dir_size(SRC)

    # 半成品能否被 t 检出损坏
    t_exit, t_msg = None, ""
    if os.path.exists(int_out):
        tp = subprocess.run([SEVENZ, "t", int_out], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, cwd=ROOT)
        t_exit = tp.returncode
        t_msg = tp.stdout.decode("utf-8", "replace").strip().splitlines()[-3:]

    res["interrupt"] = {
        "was_running_when_killed": killed,
        "process_returncode": rc,
        "src_files_before": before_cnt,
        "src_files_after": after_cnt,
        "src_bytes_before": before_size,
        "src_bytes_after": after_size,
        "source_intact": (before_cnt == after_cnt and before_size == after_size),
        "new_artifacts": new_files,
        "partial_size": os.path.getsize(int_out) if os.path.exists(int_out) else -1,
        "partial_test_exit": t_exit,
        "partial_test_tail": t_msg,
    }

    print(f"[E] kill 时仍在运行={killed} exit={rc}")
    print(f"[E] 源目录: {before_cnt} 文件 / {before_size/1048576:.1f}MB "
          f"→ {after_cnt} 文件 / {after_size/1048576:.1f}MB  (完好={res['interrupt']['source_intact']})")
    print(f"[E] 残留产物: {new_files}")
    if os.path.exists(int_out):
        print(f"[E] 半成品大小={os.path.getsize(int_out)/1048576:.1f}MB, "
              f"7z t exit={t_exit}")
        for ln in t_msg:
            print("      " + ln)

    with open(os.path.join(PROBE_DIR, "phase0_interrupt_result.json"), "w",
              encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print("[E] 结果已写: dev_probe/phase0_interrupt_result.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
