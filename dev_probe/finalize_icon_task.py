# -*- coding: utf-8 -*-
"""finalize_icon_task.py — 图标换新收尾：DEV_LOG/HANDOFF 落地 + 临时文件清理 + git 提交。
输出: dev_probe/_finalize_result.txt（全程文件落盘，不依赖控制台捕获）
"""
import os
import subprocess

BASE = r"D:\CTLIB"
DEV = os.path.join(BASE, "dev_probe")
DOCS = os.path.join(BASE, "docs", "DEV")
DEVLOG = os.path.join(DOCS, "DEV_LOG.md")
HANDOFF = os.path.join(DOCS, "SESSION_HANDOFF.md")
NEW_DEVLOG = os.path.join(DEV, "_new_devlog_entry.txt")
NEW_HANDOFF = os.path.join(DEV, "_new_handoff_block.txt")
RESULT = os.path.join(DEV, "_finalize_result.txt")

out = []


def log(s):
    out.append(str(s))


def run_git(args, tag):
    f = os.path.join(DEV, "_git_%s.txt" % tag)
    try:
        with open(f, "wb") as fh:
            p = subprocess.run(["git", "-C", BASE] + args,
                               stdout=fh, stderr=subprocess.STDOUT, timeout=180)
        return p.returncode, f
    except Exception as e:
        with open(f, "wb") as fh:
            fh.write(("EXC: %r" % e).encode("utf-8", "replace"))
        return -1, f


def read_txt(f):
    with open(f, "rb") as fh:
        return fh.read().decode("utf-8", "replace")


# ---------- 0. 写保护探测 ----------
probe = os.path.join(DOCS, "._probe_tmp_delete_me")
can_write_docs = True
try:
    with open(probe, "wb") as f:
        f.write(b"probe")
    os.remove(probe)
    log("[PROBE] docs/DEV 可写 OK")
except Exception as e:
    can_write_docs = False
    log("[PROBE] docs/DEV 不可写: %r" % (e,))

devlog_ok = False
handoff_ok = False

# ---------- 1. DEV_LOG：旧 PNG 帧条目 -> 最终态条目 ----------
if can_write_docs:
    try:
        data = open(DEVLOG, "rb").read()
        is_crlf = data.count(b"\r\n") > data.count(b"\n") * 0.8
        old_head = "## 2026-10-03 · 全局软件图标换新：exe 图标 + 系统托盘图标".encode("utf-8")
        new_mark = "全局软件图标换新（最终态）".encode("utf-8")
        if data.find(new_mark) != -1:
            devlog_ok = True
            log("[DEVLOG] 最终态条目已存在，跳过（幂等）")
        elif data.find(old_head) == -1:
            log("[DEVLOG] !! 未找到旧条目锚点，需人工处理")
        else:
            start = data.find(old_head)
            end = data.find(b"\n## ", start)
            if end == -1:
                end = len(data)
            nb = open(NEW_DEVLOG, "rb").read().replace(b"\r\n", b"\n").rstrip(b"\n")
            if is_crlf:
                nb = nb.replace(b"\n", b"\r\n")
            nd = data[:start] + nb + data[end:]
            bak = DEVLOG + ".bak_icon"
            open(bak, "wb").write(data)
            with open(DEVLOG, "wb") as f:
                f.write(nd)
            back = open(DEVLOG, "rb").read()
            devlog_ok = (back.find(new_mark) != -1) and (back.find(old_head) == -1)
            log("[DEVLOG] 替换 %s | 备份=%s | %d -> %d B"
                % ("OK" if devlog_ok else "FAIL(未落盘?)", bak, len(data), len(back)))
    except Exception as e:
        log("[DEVLOG] 异常: %r" % (e,))

# ---------- 2. SESSION_HANDOFF：顶部插入图标收官块 ----------
if can_write_docs:
    try:
        data = open(HANDOFF, "rb").read()
        is_crlf = data.count(b"\r\n") > data.count(b"\n") * 0.8
        mark = "【全局软件图标换新】".encode("utf-8")
        anchor = "> 最后更新：**2026-10-03 · 【邮件稳定性加固】".encode("utf-8")
        if data.find(mark) != -1:
            handoff_ok = True
            log("[HANDOFF] 图标块已存在，跳过（幂等）")
        elif data.find(anchor) == -1:
            log("[HANDOFF] !! 未找到锚点，需人工处理")
        else:
            idx = data.find(anchor)
            nb = open(NEW_HANDOFF, "rb").read().replace(b"\r\n", b"\n").rstrip(b"\n")
            # 与现有块整段加粗格式一致：内容末行补 **，再接 ">" 分隔行
            if nb.endswith(b"\n>"):
                nb = nb[:-2] + b"**\n>"
            nb += b"\n"
            if is_crlf:
                nb = nb.replace(b"\n", b"\r\n")
            nd = data[:idx] + nb + data[idx:]
            bak = HANDOFF + ".bak_icon"
            open(bak, "wb").write(data)
            with open(HANDOFF, "wb") as f:
                f.write(nd)
            back = open(HANDOFF, "rb").read()
            handoff_ok = back.find(mark) != -1
            log("[HANDOFF] 插入 %s | 备份=%s | %d -> %d B"
                % ("OK" if handoff_ok else "FAIL(未落盘?)", bak, len(data), len(back)))
    except Exception as e:
        log("[HANDOFF] 异常: %r" % (e,))

# ---------- 3. git status 自查 ----------
rc, f = run_git(["status", "--porcelain"], "status")
log("[GIT] status rc=%d" % rc)
st = read_txt(f)
log(st if st.strip() else "(clean)")

# dev_probe 是否被 git 跟踪（决定工具脚本是否入库）
rc, f2 = run_git(["ls-files", "dev_probe"], "lsfiles")
devprobe_tracked = read_txt(f2).strip() != ""
log("[GIT] dev_probe 被跟踪: %s" % devprobe_tracked)

# ---------- 4. 清理本次临时文件 ----------
tmp_files = [
    "_disk_free.txt", "_py_exit.txt", "_probe_system.txt", "_bootstrap_log.txt",
    "_bootstrap_log_run.py", "_verify_result.txt", "_verify_result.txt.tmp",
    "_orientation_result.txt", "make_app_icon_ico_result.txt",
    "_icon_new_runner_icon.png", "_icon_new_root_icon.png", "_py_out.txt",
    "_git_status.txt", "_git_lsfiles.txt", "_git_add.txt", "_git_commit.txt",
    "_git_log.txt", "_commit_msg.txt",
]
if devlog_ok and handoff_ok:
    tmp_files += ["_new_devlog_entry.txt", "_new_handoff_block.txt"]
for t in tmp_files:
    p = os.path.join(DEV, t)
    try:
        if os.path.exists(p):
            os.remove(p)
            log("[CLEAN] 删除 %s" % t)
    except Exception as e:
        log("[CLEAN] %s 失败: %r" % (t, e))
log("[CLEAN] 保留: make_app_icon_ico.py / verify_orientation.py / verify_and_visual.py / "
    "merge_app_icon.py(并行会话) / _old_icons_backup/ / *.bak_icon")

# ---------- 5. git add + commit（显式文件，禁 -A） ----------
add_list = []
if devlog_ok:
    add_list.append("docs/DEV/DEV_LOG.md")
if handoff_ok:
    add_list.append("docs/DEV/SESSION_HANDOFF.md")
if devprobe_tracked:
    add_list += ["dev_probe/make_app_icon_ico.py",
                 "dev_probe/verify_orientation.py",
                 "dev_probe/verify_and_visual.py"]

if add_list:
    rc, f = run_git(["add", "--"] + add_list, "add")
    log("[GIT] add rc=%d (%s)" % (rc, ", ".join(add_list)))
    rc, f = run_git(["status", "--porcelain"], "status2")
    log("[GIT] 提交前 staged 自查:")
    for line in read_txt(f).splitlines():
        if line[:1] in ("A", "M", "R", "D"):
            log("  " + line)

    msg_path = os.path.join(DEV, "_commit_msg.txt")
    msg = (
        "docs: 图标换新收尾——DEV_LOG/HANDOFF 落地 BMP 帧最终态\n\n"
        "- DEV_LOG: 旧 PNG 帧条目（194,539B/两处）替换为最终态（BMP 帧 372,526B/\n"
        "  exe+托盘+安装器三处、LoadImage 兼容性结论、bottom-up 行序陷阱、f64a971）\n"
        "- SESSION_HANDOFF: 顶部插入图标收官块（待重建 exe+打包+真机走查）\n"
        "- 入库生成/验证工具: make_app_icon_ico.py / verify_orientation.py / verify_and_visual.py\n"
    )
    with open(msg_path, "wb") as fh:
        fh.write(msg.encode("utf-8"))
    rc, f = run_git(["commit", "-F", msg_path], "commit")
    log("[GIT] commit rc=%d" % rc)
    log(read_txt(f).strip())
    rc, f = run_git(["log", "-1", "--stat", "-3"], "log")
    log("[GIT] log -3 --stat:")
    log(read_txt(f))
else:
    log("[GIT] 无可提交内容（文档均未落地），跳过 add/commit")

# ---------- 6. 写结果 ----------
with open(RESULT, "wb") as fh:
    fh.write(("\n".join(out)).encode("utf-8"))
