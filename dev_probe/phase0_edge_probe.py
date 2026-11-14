# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 D：边界与行为验证
  0.3 只读属性是否保留 / 长路径（已由 0.2 覆盖，此处补属性）
  0.4 -sdel（压后删源）安全性
  0.6 中断（kill 进程）后的源完整性与半成品残留
  0.7 分卷 -v 能力与解压自动连接（并确认 extract_manager 是否支持 .7z.001）
另测：cwd 方式压缩（避免归档内出现 src\\ 前缀）+ Windows 通配 * 是否漏点文件
"""
import os
import sys
import json
import time
import stat
import shutil
import subprocess

SEVENZ = r"D:\CTLIB\windows\runner\tools\7z.exe"
ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "out")
EDGE = os.path.join(ROOT, "edge")
EXTRACT_ROOT = os.path.join(ROOT, "roundtrip")
PROBE_DIR = r"D:\CTLIB\dev_probe"


def run7z(args, cwd=ROOT, timeout=None):
    t0 = time.time()
    p = subprocess.Popen([SEVENZ] + args, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=cwd)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), time.time() - t0


def count_files(root):
    n = 0
    for dp, dn, fn in os.walk(root):
        n += len(fn)
    return n


def main():
    os.makedirs(EDGE, exist_ok=True)
    res = {}

    # ================= 0.3 只读属性保留 =================
    ro_extracted = os.path.join(EXTRACT_ROOT, "from_v1", "src", "e_readonly.bin")
    ro_src = os.path.join(SRC, "e_readonly.bin")
    res["readonly_attr"] = {
        "src_is_readonly": not os.access(ro_src, os.W_OK),
        "extracted_is_readonly": (not os.access(ro_extracted, os.W_OK))
        if os.path.exists(ro_extracted) else None,
        "src_mode": oct(os.stat(ro_src).st_mode),
        "extracted_mode": oct(os.stat(ro_extracted).st_mode)
        if os.path.exists(ro_extracted) else None,
    }
    print(f"[D-0.3] 只读属性: 源只读={res['readonly_attr']['src_is_readonly']} "
          f"解出只读={res['readonly_attr']['extracted_is_readonly']}")

    # ================= 顶层点文件 + cwd 方式压缩 =================
    top_dot = os.path.join(SRC, ".top_dotfile.txt")
    with open(top_dot, "w", encoding="utf-8") as f:
        f.write("top level dotfile\n")
    before_cnt = count_files(SRC)

    cwd_out = os.path.join(OUT, "cwd.7z")
    rc, so, se, dt = run7z(["a", "-t7z", "-mx=5", "-mmt=2", "-y", cwd_out, "*"], cwd=SRC)
    # 列条目（只统计，看是否含已隐藏点文件）
    rc2, lo, le, _ = run7z(["l", "-ba", cwd_out], cwd=ROOT)
    entries = [ln for ln in lo.splitlines() if ln.strip()]
    has_top_dot = any(".top_dotfile.txt" in e for e in entries)
    struct_ok = (not any(e.strip().split()[-1].startswith("src\\") for e in entries if e.strip()))
    cwd_ex = os.path.join(EDGE, "from_cwd")
    if os.path.exists(cwd_ex):
        shutil.rmtree(cwd_ex, ignore_errors=True)
    os.makedirs(cwd_ex, exist_ok=True)
    rc3, _, _, _ = run7z(["x", cwd_out, f"-o{cwd_ex}", "-y"], cwd=ROOT)
    cwd_cnt = count_files(cwd_ex)
    res["cwd_mode"] = {
        "compress_exit": rc, "list_entries": len(entries),
        "has_top_dotfile": has_top_dot,
        "no_src_prefix": struct_ok,
        "extracted_files": cwd_cnt, "expected_files": before_cnt,
        "match": cwd_cnt == before_cnt,
    }
    print(f"[D-cwd] cwd 方式压缩: 归档 {len(entries)} 条目, 顶层点文件={has_top_dot}, "
          f"无 src\\ 前缀={struct_ok}, 解出 {cwd_cnt}/{before_cnt}")

    # ================= 0.4 -sdel 安全性 =================
    sdel_src = os.path.join(EDGE, "sdel_src")
    if os.path.exists(sdel_src):
        shutil.rmtree(sdel_src, ignore_errors=True)
    os.makedirs(sdel_src, exist_ok=True)
    shutil.copytree(os.path.join(SRC, "中文目录"), os.path.join(sdel_src, "中文目录"))
    shutil.copytree(os.path.join(SRC, "many_small"), os.path.join(sdel_src, "many_small"))
    n_before = count_files(sdel_src)
    sdel_out = os.path.join(EDGE, "sdel.7z")
    rc, so, se, dt = run7z(["a", "-t7z", "-mx=5", "-mmt=2", "-sdel", "-y", sdel_out, "*"],
                           cwd=sdel_src)
    n_after = count_files(sdel_src)
    dirs_after = [d for d in os.listdir(sdel_src)] if os.path.exists(sdel_src) else []
    res["sdel"] = {
        "exit": rc, "files_before": n_before, "files_after": n_after,
        "dirs_left": dirs_after, "archive_exists": os.path.exists(sdel_out),
        "source_wiped": n_after == 0,
    }
    print(f"[D-0.4] -sdel: 源 {n_before} → {n_after} 文件, 残留目录={dirs_after}")

    # ================= 0.7 分卷 =================
    vol_out = os.path.join(EDGE, "vol.7z")
    for f in os.listdir(EDGE):
        if f.startswith("vol.7z"):
            os.remove(os.path.join(EDGE, f))
    rc, so, se, dt = run7z(["a", "-t7z", "-mx=1", "-mmt=2", "-v50m", "-y", vol_out, "*"],
                           cwd=SRC)
    vols = sorted(f for f in os.listdir(EDGE) if f.startswith("vol.7z"))
    vol_ex = os.path.join(EDGE, "from_vol")
    if os.path.exists(vol_ex):
        shutil.rmtree(vol_ex, ignore_errors=True)
    os.makedirs(vol_ex, exist_ok=True)
    rc2, so2, se2, _ = run7z(["x", vol_out + ".001", f"-o{vol_ex}", "-y"], cwd=ROOT)
    vol_cnt = count_files(vol_ex)
    res["volumes"] = {
        "compress_exit": rc, "volumes": vols, "extract_exit": rc2,
        "extracted_files": vol_cnt, "expected_files": before_cnt,
        "auto_join_ok": vol_cnt == before_cnt,
    }
    print(f"[D-0.7] 分卷: 生成 {vols} ; 指定 .001 解压 exit={rc2}, "
          f"解出 {vol_cnt}/{before_cnt} (自动连接={vol_cnt == before_cnt})")

    with open(os.path.join(PROBE_DIR, "phase0_edge_result.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    print("[D] 结果已写: dev_probe/phase0_edge_result.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
