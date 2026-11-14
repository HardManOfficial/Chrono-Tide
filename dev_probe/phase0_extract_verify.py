# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 C：解压侧进度格式 + 往返无损校验

回答：
  0.1 解压侧 `7z x ... -bsp1` 的 stdout 能否被 _parse7zLine（^\s*(\d+)\s）解析？
  0.2 压缩 → 7z x 解压 → 文件数 / 总字节 / 逐文件 sha256 是否完全一致？
      （含 中文/日文文件名、>260 长路径、只读文件、0 字节文件、空目录）

产出：dev_probe/phase0_extract_result.json
"""
import os
import re
import sys
import json
import time
import subprocess

sys.path.insert(0, r"D:\CTLIB\dev_probe")
from phase0_compress_probe import dart_parse7z_line, analyse_stdout  # noqa

SEVENZ = r"D:\CTLIB\windows\runner\tools\7z.exe"
ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "out")
EXTRACT_ROOT = os.path.join(ROOT, "roundtrip")
INDEX = r"D:\CTLIB\dev_probe\phase0_tree_index.json"
PROBE_DIR = r"D:\CTLIB\dev_probe"


def sha256_of(path, chunk=1 << 20):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def scan_long(root):
    long_root = "\\\\?\\" + os.path.abspath(root)
    stack, files, dirs = [long_root], [], []
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError as e:
            print(f"!! scandir 失败: {d} {e}")
            continue
        for e in entries:
            if e.is_dir(follow_symlinks=False):
                dirs.append(e.path[len(long_root) + 1:].replace("\\", "/"))
                stack.append(e.path)
            else:
                files.append(e.path)
    return long_root, files, dirs


def main():
    results = {}

    # ---------- 0.1 解压侧进度格式 ----------
    ex_dir = os.path.join(EXTRACT_ROOT, "from_v1")
    if os.path.exists(EXTRACT_ROOT):
        import shutil
        shutil.rmtree(EXTRACT_ROOT, ignore_errors=True)
    os.makedirs(ex_dir, exist_ok=True)

    args = ["x", os.path.join(OUT, "v1.7z"), f"-o{ex_dir}", "-y", "-bsp1"]
    t0 = time.time()
    p = subprocess.Popen([SEVENZ] + args, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, cwd=ROOT)
    out, err = p.communicate()
    dt = time.time() - t0
    with open(os.path.join(PROBE_DIR, "phase0_out_x_bsp1.txt"), "w",
              encoding="utf-8") as f:
        f.write(f"### CMD: 7z {' '.join(args)}\nexit={p.returncode} elapsed={dt:.2f}s\n")
        f.write(f"### stdout bytes={len(out)} stderr bytes={len(err)}\n\n")
        f.write("===== STDOUT (repr) =====\n" + repr(out) + "\n\n")
        f.write("===== STDERR (repr) =====\n" + repr(err) + "\n")

    xinfo = analyse_stdout(out, "7z x -bsp1 stdout")
    xinfo["exit"] = p.returncode
    xinfo["elapsed_s"] = round(dt, 2)
    results["extract_progress"] = xinfo

    # ---------- 7z t 完整性校验 ----------
    t0 = time.time()
    p = subprocess.Popen([SEVENZ, "t", os.path.join(OUT, "v1.7z")],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=ROOT)
    tout, terr = p.communicate()
    ttext = tout.decode("utf-8", errors="replace")
    results["test_archive"] = {
        "exit": p.returncode,
        "elapsed_s": round(time.time() - t0, 2),
        "tail": ttext.strip().splitlines()[-6:],
    }
    print(f"\n[C] 7z t 校验: exit={p.returncode}")
    for ln in results["test_archive"]["tail"]:
        print("    " + ln)

    # ---------- 0.2 往返比对 ----------
    idx = json.load(open(INDEX, encoding="utf-8"))
    expected = {f["rel"]: (f["size"], f["sha256"]) for f in idx["files"]}
    expected_dirs = set(idx["dirs"])

    long_root, files, dirs = scan_long(ex_dir)
    found = {}
    for fp in files:
        rel = fp[len(long_root) + 1:].replace("\\", "/")
        # 归档内带 `src\` 前缀（因为压缩命令是 src\*）→ 归一化用于比对
        if rel.startswith("src/"):
            rel = rel[4:]
        found[rel] = fp
    found_dirs = set(dirs)
    if any(d.startswith("src") for d in found_dirs):
        found_dirs = {d[4:] if d.startswith("src/") else d for d in found_dirs}
        found_dirs.discard("")

    missing = sorted(set(expected) - set(found))
    extra = sorted(set(found) - set(expected))
    content_diff, size_diff = [], []
    for rel in sorted(set(expected) & set(found)):
        esz, esha = expected[rel]
        asz = os.path.getsize(found[rel])
        if asz != esz:
            size_diff.append({"rel": rel, "expected": esz, "actual": asz})
        asha = sha256_of(found[rel])
        if asha != esha:
            content_diff.append({"rel": rel, "expected_sha": esha, "actual_sha": asha})

    dirs_missing = sorted(expected_dirs - found_dirs)

    # 边界项单独确认
    edge = {}
    for key, rel in [
        ("中文文件名", "中文目录/中文测试文件.txt"),
        ("日文文件名", "日文ディレクトリ/テスト_セーブ.txt"),
        ("0字节文件", "c_empty.txt"),
        ("只读文件", "e_readonly.bin"),
        ("全角标点", "中文目录/全角（括号）【方括号】、逗号。.txt"),
        ("点开头文件", "中文目录/.hidden_config.ini"),
        ("深层>260文件", [k for k in expected if "deep_target" in k][0]
         if any("deep_target" in k for k in expected) else ""),
    ]:
        edge[key] = {"rel": rel, "ok": rel in found and rel not in
                     [d["rel"] for d in content_diff] and rel not in
                     [d["rel"] for d in size_diff]}

    results["roundtrip"] = {
        "expected_files": len(expected),
        "expected_dirs": len(expected_dirs),
        "extracted_files": len(found),
        "extracted_dirs": len(found_dirs),
        "missing": missing,
        "extra": extra,
        "size_diff": size_diff,
        "content_diff": content_diff,
        "dirs_missing": dirs_missing,
        "edge_cases": edge,
    }

    print(f"\n[C] ===== 往返比对 =====")
    print(f"  期望文件 {len(expected)} / 实际解出 {len(found)}")
    print(f"  缺失 {len(missing)} | 多出 {len(extra)} | 尺寸不符 {len(size_diff)} | 内容不符 {len(content_diff)}")
    print(f"  空/目录：期望 {len(expected_dirs)} 实际 {len(found_dirs)} 缺失 {dirs_missing}")
    if missing:
        print("  -- 缺失样本:")
        for m in missing[:8]:
            print(f"     - {m}")
    if extra:
        print("  -- 多出样本:")
        for m in extra[:8]:
            print(f"     + {m}")
    print("  -- 边界项:")
    for k, v in edge.items():
        flag = "OK " if v["ok"] else "FAIL"
        print(f"     [{flag}] {k}: {v['rel']}")

    with open(os.path.join(PROBE_DIR, "phase0_extract_result.json"), "w",
              encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    print("\n[C] 结果已写: dev_probe/phase0_extract_result.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
