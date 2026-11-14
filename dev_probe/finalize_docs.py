# -*- coding: utf-8 -*-
"""把本轮记录并入 DEV_LOG / SESSION_HANDOFF，且不把工作区里他人未提交的改动带进 commit。

做法（沿用 2026-10-26 纪律）：
  1) 备份工作区版本（含他人改动）-> .bak_parallel
  2) git checkout HEAD -- 目标文件（回到干净基线）
  3) 在干净版本上插入本轮记录
  4) git add/commit（由外层执行）
  5) restore: 对 .bak_parallel 做同样插入，写回工作区
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path("/d/CTLIB") if Path("/d/CTLIB").exists() else Path("D:/CTLIB")
DEV_LOG = ROOT / "docs/DEV/DEV_LOG.md"
HANDOFF = ROOT / "docs/DEV/SESSION_HANDOFF.md"
SNIP_LOG = ROOT / ".workbuddy/tmp_devlog_snippet.md"
SNIP_HAND = ROOT / ".workbuddy/tmp_handoff_snippet.md"


def read(p):
    return Path(p).read_text(encoding="utf-8", newline="")


def write(p, s):
    Path(p).write_text(s, encoding="utf-8", newline="")


def crlf(s, sample):
    return s.replace("\r\n", "\n").replace("\n", "\r\n") if "\r\n" in sample else s.replace("\r\n", "\n")


def insert_head(base, snippet):
    """在文件最前面插入（snippet 自带尾部空行）。"""
    return crlf(snippet, base) + base


def replace_first_line(base, snippet):
    """替换首行（📦 本轮 · 最后更新 …），其余原样。"""
    nl = base.find("\n")
    tail = base[nl + 1:]
    sn = crlf(snippet.rstrip("\n"), base) + ("\r\n" if "\r\n" in base else "\n")
    return sn + tail


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "prepare"
    snip_log = read(SNIP_LOG)
    snip_hand = read(SNIP_HAND)

    if phase == "prepare":
        shutil.copy2(DEV_LOG, str(DEV_LOG) + ".bak_parallel")
        shutil.copy2(HANDOFF, str(HANDOFF) + ".bak_parallel")
        subprocess.run(["git", "checkout", "HEAD", "--",
                        str(DEV_LOG.relative_to(ROOT)), str(HANDOFF.relative_to(ROOT))],
                       cwd=str(ROOT), check=True)
        write(DEV_LOG, insert_head(read(DEV_LOG), snip_log))
        write(HANDOFF, replace_first_line(read(HANDOFF), snip_hand))
        print("prepare OK: 已回到 HEAD 基线并插入本轮记录")
        for p in (DEV_LOG, HANDOFF):
            t = read(p)
            print(f"  {p.name}: {len(t.splitlines())} 行, 含本轮={(('DATA-CLEAN-EXPAND') in t)}")
    elif phase == "restore":
        for path, snip, mode in ((DEV_LOG, snip_log, "head"), (HANDOFF, snip_hand, "first")):
            bak = Path(str(path) + ".bak_parallel")
            base = read(bak)
            out = insert_head(base, snip) if mode == "head" else replace_first_line(base, snip)
            write(path, out)
            print(f"restore {path.name}: {len(out.splitlines())} 行（他人改动 + 本轮记录）")
    else:
        raise SystemExit("usage: finalize_docs.py prepare|restore")


if __name__ == "__main__":
    main()
