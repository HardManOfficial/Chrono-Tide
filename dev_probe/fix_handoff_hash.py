# -*- coding: utf-8 -*-
"""fix_handoff_hash.py — 修 HANDOFF 图标 v2 块的 {hash} 占位符，并只提交自己那一行
（并行会话在同文件有未提交改动 → git diff -U0 过滤 hunk + apply --cached 分离）
输出: dev_probe/_fix_hash_result.txt
"""
import os
import subprocess
import traceback

ROOT = r"D:\CTLIB"
DEV = os.path.join(ROOT, "dev_probe")
HANDOFF = os.path.join(ROOT, "docs", "DEV", "SESSION_HANDOFF.md")
RESULT = os.path.join(DEV, "_fix_hash_result.txt")
HASH = "15fddc1"

out = []


def log(s):
    out.append(str(s))


def run_git(args, tag):
    f = os.path.join(DEV, "_fx_git_%s.txt" % tag)
    try:
        with open(f, "wb") as fh:
            subprocess.run(["git", "-C", ROOT] + args, stdout=fh, stderr=subprocess.STDOUT, timeout=180)
        with open(f, "rb") as fh:
            return fh.read().decode("utf-8", "replace")
    except Exception as e:
        return "EXC: %r" % (e,)


try:
    # 1. 替换占位符
    data = open(HANDOFF, "rb").read()
    old = "（`{hash}`）".encode("utf-8")
    new = ("（`%s`）" % HASH).encode("utf-8")
    cnt = data.count(old)
    if cnt == 0:
        log("[FIX] 未找到占位符（可能已修复）")
    else:
        nd = data.replace(old, new)
        open(HANDOFF, "wb").write(nd)
        back = open(HANDOFF, "rb").read()
        log("[FIX] 替换 %d 处 | 写后校验 占位符残留=%d hash命中=%d | %d -> %d B"
            % (cnt, back.count(old), back.count(new), len(data), len(back)))

    # 2. 当前工作区状态（了解并行会话改动范围）
    log("[GIT] 提交前 status:")
    log(run_git(["status", "--porcelain"], "status").strip())

    # 3. 生成 -U0 diff 并过滤出「含本行改动」的 hunk
    full = run_git(["diff", "-U0", "--", "docs/DEV/SESSION_HANDOFF.md"], "diff")
    lines = full.splitlines(keepends=True)
    header, hunks, cur = [], [], None
    for ln in lines:
        if ln.startswith("@@"):
            if cur is not None:
                hunks.append(cur)
            cur = [ln]
        elif cur is None:
            header.append(ln)
        else:
            cur.append(ln)
    if cur is not None:
        hunks.append(cur)
    mine = [h for h in hunks if any(("15fddc1" in x) or ("{hash}" in x) for x in h)]
    log("[PATCH] 总 hunk=%d，属于本修复的 hunk=%d" % (len(hunks), len(mine)))

    if not mine:
        log("[PATCH] 无自己的 hunk，跳过提交")
    else:
        patch = "".join(header + [l for h in mine for l in h])
        # patch 头部需带 diff --git 等；-U0 下 index 行不必匹配
        pp = os.path.join(DEV, "_my_hash_fix.diff")
        with open(pp, "w", encoding="utf-8", newline="") as f:
            f.write(patch)
        log("[PATCH] 已写 %s:\n%s" % (pp, patch))

        r = run_git(["apply", "--cached", "--unidiff-zero", pp], "apply")
        log("[GIT] apply --cached: %s" % (r.strip() or "(空=成功)"))

        log("[GIT] staged 自查:")
        st2 = run_git(["status", "--porcelain"], "status2")
        for ln in st2.splitlines():
            if ln.startswith("M ") or ln.startswith("MM") or ln.startswith("A "):
                log("  " + ln)

        if "error" not in r.lower() and "fatal" not in r.lower() and "patch does not apply" not in r.lower():
            r2 = run_git(["commit", "-m", "docs: 修正 HANDOFF 图标 v2 块的 commit 占位符为 15fddc1"], "commit")
            log("[GIT] commit: %s" % r2.strip())
            log("[GIT] log -1 --stat:")
            log(run_git(["log", "-1", "--stat", "-1"], "log"))
        else:
            log("[GIT] apply 失败，未提交（工作区仍含修复，待人工处理）")
            run_git(["reset", "--", "docs/DEV/SESSION_HANDOFF.md"], "reset")

    log("RESULT: DONE")
except BaseException:
    log("TRACEBACK:")
    log(traceback.format_exc())
    log("RESULT: FAILED")

with open(RESULT, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
