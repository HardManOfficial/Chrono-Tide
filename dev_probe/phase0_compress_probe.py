# -*- coding: utf-8 -*-
"""
Phase 0 · 步骤 B：压缩 + 原样捕获 7z 输出（核心：验证 -bsp1 进度格式）

目的：
  0.1 验证 `7z a ... -bsp1` 的输出能否被 extract_manager.dart:1302 的
      _parse7zLine（正则 ^\s*(\d+)\s）解析出百分比。
      关键疑点：7z 的进度行是 "45%"（百分号紧跟数字），而正则要求数字后跟空白。

  0.2 压缩 → 用 7z x 解压 → 往返一致（文件数/字节/sha256）。

产出：
  .workbuddy/tmp/phase0/out/*.7z
  dev_probe/phase0_out_<tag>.txt   （原始 stdout 的可读转义 dump）
"""
import os
import re
import sys
import json
import time
import subprocess

SEVENZ = r"D:\CTLIB\windows\runner\tools\7z.exe"
ROOT = r"D:\CTLIB\.workbuddy\tmp\phase0"
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "out")
PROBE_DIR = r"D:\CTLIB\dev_probe"

# 项目解压侧的真实解析规则（extract_manager.dart:1302-1312 的等价实现）
PARSE7Z_RE = re.compile(r"^\s*(\d+)\s")


def dart_parse7z_line(line: str):
    """等价于 Dart: line.trimLeft() 后 RegExp(r'^\s*(\d+)\s').firstMatch"""
    trimmed = line.lstrip()
    m = PARSE7Z_RE.match(trimmed)
    if m:
        v = int(m.group(1))
        if v <= 100:
            return v
    return None


def run(args, tag):
    t0 = time.time()
    p = subprocess.Popen(
        [SEVENZ] + args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=ROOT,
    )
    out, err = p.communicate()
    dt = time.time() - t0
    # 原始 dump（转义形式，保留 \r \n）
    dump = os.path.join(PROBE_DIR, f"phase0_out_{tag}.txt")
    with open(dump, "w", encoding="utf-8") as f:
        f.write(f"### CMD: 7z {' '.join(args)}\n")
        f.write(f"### cwd: {ROOT}\n")
        f.write(f"### exit={p.returncode}  elapsed={dt:.2f}s\n")
        f.write(f"### stdout bytes={len(out)}  stderr bytes={len(err)}\n")
        f.write("\n===== STDOUT (repr) =====\n")
        f.write(repr(out) + "\n")
        f.write("\n===== STDERR (repr) =====\n")
        f.write(repr(err) + "\n")
    return p.returncode, out, err, dt, dump


def analyse_stdout(raw: bytes, label: str):
    """按 \r 与 \n 两种切分方式，统计有多少行能被 _parse7zLine 解析。"""
    text = raw.decode("utf-8", errors="replace")
    by_lf = text.split("\n")
    by_cr = re.split(r"[\r\n]+", text)

    def stat(lines):
        parsed, unparsed_samples = 0, []
        for ln in lines:
            if not ln.strip():
                continue
            v = dart_parse7z_line(ln)
            if v is not None:
                parsed += 1
            elif len(unparsed_samples) < 6:
                unparsed_samples.append(ln[:90])
        return parsed, unparsed_samples

    p_lf, s_lf = stat(by_lf)
    p_cr, s_cr = stat(by_cr)

    print(f"\n--- {label} ---")
    print(f"  raw stdout: {len(raw)} bytes")
    print(f"  split by \\n : {len(by_lf)} 段, 可被 _parse7zLine 解析 {p_lf} 段")
    print(f"  split by \\r : {len(by_cr)} 段, 可被 _parse7zLine 解析 {p_cr} 段")
    if s_cr:
        print(f"  未被解析的样本（前 3）:")
        for s in s_cr[:3]:
            print(f"    | {s}")
    # 显示含 '%' 的行（进度行）
    pct_lines = [ln for ln in by_cr if "%" in ln][:5]
    print(f"  含 '%' 的行（前 5）:")
    for s in pct_lines:
        print(f"    | {s[:100]}")
    return {
        "stdout_bytes": len(raw),
        "segments_by_lf": len(by_lf),
        "segments_by_cr": len(by_cr),
        "parsed_by_lf": p_lf,
        "parsed_by_cr": p_cr,
        "pct_samples": pct_lines,
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    variants = [
        ("v1_bsp1", ["a", "-t7z", "-mx=5", "-md=64m", "-mmt=2", "-bsp1", "-y",
                      os.path.join(OUT, "v1.7z"), r"src\*"]),
        ("v2_bsp1_bb1", ["a", "-t7z", "-mx=5", "-md=64m", "-mmt=2", "-bsp1", "-bb1", "-y",
                          os.path.join(OUT, "v2.7z"), r"src\*"]),
        ("v3_nobsp", ["a", "-t7z", "-mx=5", "-md=64m", "-mmt=2", "-y",
                       os.path.join(OUT, "v3.7z"), r"src\*"]),
    ]
    results = {}
    for tag, args in variants:
        print(f"\n[B] 执行 {tag} ...")
        rc, out, err, dt, dump = run(args, tag)
        archive = [a for a in args if a.endswith(".7z")][0]
        size = os.path.getsize(archive) if os.path.exists(archive) else -1
        print(f"[B] {tag}: exit={rc} elapsed={dt:.2f}s archive={size/1048576:.1f}MB")
        info = analyse_stdout(out, f"{tag} stdout")
        info.update({"tag": tag, "exit": rc, "elapsed_s": round(dt, 2),
                     "archive_bytes": size, "dump": dump})
        results[tag] = info

    with open(os.path.join(PROBE_DIR, "phase0_compress_result.json"), "w",
              encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    print("\n[B] 结果已写: dev_probe/phase0_compress_result.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
