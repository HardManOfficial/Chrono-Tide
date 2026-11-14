# -*- coding: utf-8 -*-
"""finalize_icons_v2.py — 图标 v2 收尾：DEV_LOG/HANDOFF 落地 + commit + memory 同步
输出: dev_probe/_finalize_v2_result.txt
"""
import os
import shutil
import struct
import subprocess
import traceback

ROOT = r"D:\CTLIB"
DEV = os.path.join(ROOT, "dev_probe")
DOCS = os.path.join(ROOT, "docs", "DEV")
DEVLOG = os.path.join(DOCS, "DEV_LOG.md")
HANDOFF = os.path.join(DOCS, "SESSION_HANDOFF.md")
MEM = os.path.join(ROOT, ".workbuddy", "memory", "MEMORY.md")
TODAY = os.path.join(ROOT, ".workbuddy", "memory", "2026-10-03.md")
RESULT = os.path.join(DEV, "_finalize_v2_result.txt")

out = []


def log(s):
    out.append(str(s))


def rw_bytes(p):
    with open(p, "rb") as f:
        return f.read()


def ww_bytes(p, b):
    with open(p, "wb") as f:
        f.write(b)


def run_git(args, tag):
    f = os.path.join(DEV, "_v2f_git_%s.txt" % tag)
    try:
        with open(f, "wb") as fh:
            subprocess.run(["git", "-C", ROOT] + args, stdout=fh, stderr=subprocess.STDOUT, timeout=180)
        return rw_bytes(f).decode("utf-8", "replace")
    except Exception as e:
        return "EXC: %r" % (e,)


def norm(text, is_crlf):
    b = text.encode("utf-8").replace(b"\r\n", b"\n")
    return b.replace(b"\n", b"\r\n") if is_crlf else b


DEVLOG_ENTRY = """## 2026-10-03 · 全局软件图标换新 v2：新素材包（app_NxN 命名）重出三处统一

**结论**：开发者提供更新后的素材包（命名由 `CT图标_NxN.ico` 变为 `app_NxN.ico`，
8 个单尺寸单帧 PNG：16/24/32/48/64/128/256/512），按 v1 流程重出 **32bpp BMP 帧
多尺寸 ICO = 372,526 字节**（尺寸组合未变故体积与 v1 相同），覆盖三处：
① `windows/runner/resources/app_icon.ico`（exe，Runner.rc:55）；
② `assets/images/app_icon.ico`（托盘，tray_service.dart:107）；
③ `ChronoTide.ico`（安装器，ChronoTide_Setup.iss:31）。**零代码改动**。
**确认是新图**：与 v1（当前上线版）逐尺寸像素差异 ~71%（16px 183/256 → 256px
46,448/65,536），非同一张。
**v1 回滚副本**：`dev_probe/_old_icons_backup/*_193a6bce.ico`（v1 三处 372,526 B）。
备份策略由 v1 的「已存在则跳过」改为**按被覆盖文件 md5 前 8 位命名 + md5 去重**，
保证每版都有独立副本且不重复堆叠。
**素材包异常（未采用，需知悉）**：`ico/app_512x512.ico` 为**不规范文件**——ICO
目录项 bWidth=0（声明 256）而 PNG 帧实际 512×512（427,615 B）；ICO 目录项宽高仅
1 字节本就无法表达 512，采用将致「声明 256/内容 512」不符 → **继续排除 512**
（256 即 Windows 上限）。
**验证**：反向解析 7 帧一致 + PIL 解码 OK + 与**新源**逐像素 7/7 SAME（含方向）
+ 三处 md5 完全一致（`6aa59591f024`）。工具 `dev_probe/replace_icons_v2.py`
（源名双兼容：app_NxN 优先 / CT图标_NxN 回退；内联全部验证 + git 自查）。
**遗留**：⚠️ 需重建 exe + 打包后才生效；真机走查五处（桌面/任务栏/托盘/Alt-Tab/
安装器）；桌面若仍显旧图 = Windows 图标缓存（重启 Explorer）。`ico/` 源素材目录
仍 untracked（沿用不入库惯例）。另：`.workbuddy/skills/chronotide-dev/SKILL.md`
有标签会话的未提交改动（生成器 backup 纪律），**未纳入本提交**。
"""

HANDOFF_BLOCK = """> 最后更新：**2026-10-03 晚 · 【全局软件图标 v2 换新】新素材包重出三处统一**（`{hash}`）——
> 素材包命名改 `ico/app_NxN.ico`（8 尺寸）→ 重出 32bpp BMP 帧多尺寸 ICO（372,526B）
> 覆盖 exe / 托盘 / 安装器三处；与 v1 逐尺寸像素差异 ~71%（确认新图）；逐像素 7/7
> SAME + 三处 md5 一致（6aa59591f024）。v1 回滚副本 `_old_icons_backup/*_193a6bce.ico`；
> 备份策略改「md5 命名去重」。⚠️ `app_512x512.ico` 目录项声明 256/内容 512（不规范）
> 未采用。工具 `dev_probe/replace_icons_v2.py`。⏳ 待重建 exe + 打包 + 真机走查
> （桌面旧图=图标缓存，重启 Explorer）。⚠️ 工作区另有 `.workbuddy/skills/chronotide-dev/
> SKILL.md` 未提交改动（标签词表生成器 backup 纪律，属标签会话，未纳入本提交）。**
"""

TODAY_ENTRY = """
## 图标换新 v2（新素材包 app_NxN）

- 素材包改名 `ico/app_NxN.ico`（8 尺寸，含不规范的 512）→ 重出 32bpp BMP 帧多尺寸 ICO（372,526B），三处覆盖（exe/托盘/安装器）。与 v1 逐尺寸像素差异 ~71%（确认新图）；逐像素 7/7 SAME（含方向）+ 三处 md5 一致。
- ⚠️ `app_512x512.ico` 不规范：目录项 bWidth=0（声明 256）但内容 512×512 → 未采用；256 为 ICO/Windows 上限。
- 备份策略升级：按被覆盖文件 md5 前 8 位命名 + md5 去重（v1 三处副本 `_old_icons_backup/*_193a6bce.ico`），替代 v1 的「已存在则跳过」。
- 🔴 环境新事实：PowerShell `>` 重定向默认 **UTF-16LE** → Read 工具判为二进制不可读，必须 `Out-File -Encoding utf8` 或 python 转码；磁盘恢复（C 余 ~787MB / D 余 ~34.5GB，D 红线解除）。
- ⚠️ 计划外发现：`.workbuddy/skills/chronotide-dev/SKILL.md` 有标签会话未提交改动，已排除在本次提交外。
- ⏳ 待：重建 exe + 打包 + 真机走查（桌面旧图=缓存，重启 Explorer）。
"""

mem_icon_old = None
mem_icon_new = None
devlog_ok = handoff_ok = False
commit_hash = "?"

try:
    # ---------- 磁盘 ----------
    try:
        c = shutil.disk_usage("C:\\")
        d = shutil.disk_usage("D:\\")
        log("[DISK] C free=%.2f GB (%.1f%% used) | D free=%.2f GB (%.1f%% used)"
            % (c.free / 2**30, 100.0 * c.used / c.total, d.free / 2**30, 100.0 * d.used / d.total))
    except Exception as e:
        log("[DISK] 查询失败 %r" % (e,))

    # ---------- 1. DEV_LOG 插入 ----------
    try:
        data = rw_bytes(DEVLOG)
        is_crlf = data.count(b"\r\n") > data.count(b"\n") * 0.8
        mark = "全局软件图标换新 v2".encode("utf-8")
        anchor = "## 2026-10-03 · 全局软件图标换新（最终态）".encode("utf-8")
        if data.find(mark) != -1:
            devlog_ok = True
            log("[DEVLOG] v2 条目已存在，跳过（幂等）")
        else:
            idx = data.find(anchor)
            if idx == -1:
                log("[DEVLOG] !! 未找到锚点")
            else:
                nb = norm(DEVLOG_ENTRY, is_crlf)
                nd = data[:idx] + nb + data[idx:]
                ww_bytes(DEVLOG + ".bak_icon_v2", data)
                ww_bytes(DEVLOG, nd)
                back = rw_bytes(DEVLOG)
                devlog_ok = back.find(mark) != -1
                log("[DEVLOG] 插入 %s | %d -> %d B"
                    % ("OK" if devlog_ok else "FAIL", len(data), len(back)))
    except Exception as e:
        log("[DEVLOG] 异常: %r" % (e,))

    # ---------- 2. HANDOFF 插入 ----------
    try:
        data = rw_bytes(HANDOFF)
        is_crlf = data.count(b"\r\n") > data.count(b"\n") * 0.8
        mark = "【全局软件图标 v2 换新】".encode("utf-8")
        anchor = "> 最后更新：**2026-10-03 · 【全局软件图标换新】".encode("utf-8")
        if data.find(mark) != -1:
            handoff_ok = True
            log("[HANDOFF] v2 块已存在，跳过（幂等）")
        else:
            idx = data.find(anchor)
            if idx == -1:
                log("[HANDOFF] !! 未找到锚点")
            else:
                nb = norm(HANDOFF_BLOCK, is_crlf)
                nd = data[:idx] + nb + data[idx:]
                ww_bytes(HANDOFF + ".bak_icon_v2", data)
                ww_bytes(HANDOFF, nd)
                back = rw_bytes(HANDOFF)
                handoff_ok = back.find(mark) != -1
                log("[HANDOFF] 插入 %s | %d -> %d B"
                    % ("OK" if handoff_ok else "FAIL", len(data), len(back)))
    except Exception as e:
        log("[HANDOFF] 异常: %r" % (e,))

    # ---------- 3. git add + commit ----------
    add_list = [
        "ChronoTide.ico",
        "assets/images/app_icon.ico",
        "windows/runner/resources/app_icon.ico",
        "dev_probe/replace_icons_v2.py",
    ]
    if devlog_ok:
        add_list.append("docs/DEV/DEV_LOG.md")
    if handoff_ok:
        add_list.append("docs/DEV/SESSION_HANDOFF.md")

    run_git(["add", "--"] + add_list, "add")
    log("[GIT] add: %s" % ", ".join(add_list))
    log("[GIT] 提交前 staged 自查:")
    st = run_git(["status", "--porcelain"], "status")
    for line in st.splitlines():
        if line[:2] in ("A ", "M ", "AM", "MM"):
            log("  " + line)

    msg = (
        "chore(assets): 全局图标 v2 换新——新素材包重出 BMP 帧多尺寸 ICO（三处统一）\n\n"
        "- 素材包改名 ico/app_NxN.ico（8 尺寸单帧 PNG）→ 重出 32bpp BMP 帧多尺寸 ICO\n"
        "  （372,526B，尺寸组合同 v1），覆盖三处：\n"
        "  windows/runner/resources/app_icon.ico（exe，Runner.rc:55）\n"
        "  assets/images/app_icon.ico（托盘，tray_service.dart:107）\n"
        "  ChronoTide.ico（安装器，ChronoTide_Setup.iss:31）\n"
        "- 与 v1 逐尺寸像素差异 ~71%，确认是新图；与源逐像素 7/7 SAME（含方向）；\n"
        "  三处 md5 一致（6aa59591f024）\n"
        "- app_512x512.ico 不规范（目录项声明 256 / 内容 512×512）未采用；256 为 Windows 上限\n"
        "- v1 回滚副本 dev_probe/_old_icons_backup/*_193a6bce.ico；备份策略改 md5 命名去重\n"
        "- 新增工具 dev_probe/replace_icons_v2.py（源名双兼容 + 内联验证 + git 自查）\n"
        "- 零代码改动；需重建 exe + 打包 + 真机走查后生效\n"
    )
    mp = os.path.join(DEV, "_v2_commit_msg.txt")
    with open(mp, "wb") as f:
        f.write(msg.encode("utf-8"))
    r = run_git(["commit", "-F", mp], "commit")
    log("[GIT] commit:")
    log(r.strip())
    commit_hash = run_git(["log", "-1", "--format=%h"], "hash").strip() or "?"
    log("[GIT] hash=%s" % commit_hash)
    log("[GIT] log -1 --stat:")
    log(run_git(["log", "-1", "--stat", "-1"], "log"))

    # ---------- 4. MEMORY.md 两处替换 ----------
    try:
        md = rw_bytes(MEM).decode("utf-8")
        old_env_start = "- 🔴 AI 沙箱（2026-10-03 实测）：C 盘 0 剩余"
        lines_md = md.split("\n")
        n_env = n_icon = 0
        new_lines = []
        for ln in lines_md:
            if ln.startswith(old_env_start):
                new_lines.append(
                    "- 🔴 AI 沙箱（2026-10-03 实测，晚间磁盘已缓解 C 余~787MB / D 余~34.5GB）："
                    "曾 C 盘 0 剩余致 Bash ENOSPC 瘫、Edit/Write ModifyBackup 失败（os error 112）、"
                    "managed venv python 静默失败 → 用 system Python313（PIL 12.2.0），进程输出一律落盘文件；"
                    "python -c 多行串会静默崩勿用。🔴 PowerShell `>` 重定向默认 **UTF-16LE**（Read 判二进制不可读）"
                    "→ 用 `Out-File -Encoding utf8` 或 python 转码；PowerShell 原生输出捕获仍不可靠。"
                )
                n_env += 1
            elif ln.startswith("- ✅ 图标换新（f64a971 + fb10255）"):
                new_lines.append(
                    "- ✅ 图标换新 v2（%s）：最新素材包 `ico/app_NxN.ico`（8 尺寸）→ 32bpp BMP 帧多尺寸 ICO"
                    "（372,526B）覆盖 exe/托盘/安装器三处；v1 副本 `_old_icons_backup/*_193a6bce.ico`；"
                    "工具 dev_probe/replace_icons_v2.py（源名双兼容+备份 md5 去重+内联验证）。"
                    "⚠️ `app_512x512.ico` 不规范（目录项声明 256/内容 512）未采用；PNG 帧 LoadImage 不支持；"
                    "🔴 ICO BMP 帧=bottom-up；bWidth 1 字节封顶 256。⏳ 剩：重建 exe+打包+真机走查"
                    "（桌面旧图=图标缓存，重启 Explorer）。" % commit_hash
                )
                n_icon += 1
            else:
                new_lines.append(ln)
        ww_bytes(MEM, "\n".join(new_lines).encode("utf-8"))
        back = rw_bytes(MEM).decode("utf-8")
        log("[MEM] 环境条=%d 图标条=%d | 写后校验 hash=%s / v2标记=%s"
            % (n_env, n_icon, "OK" if commit_hash in back else "MISS",
               "OK" if "图标换新 v2" in back else "MISS"))
    except Exception as e:
        log("[MEM] 异常: %r" % (e,))

    # ---------- 5. 今日日志 append ----------
    try:
        tb = rw_bytes(TODAY)
        if tb.count("图标换新 v2".encode("utf-8")) > 0:
            log("[TODAY] v2 条目已存在，跳过")
        else:
            sep = b"" if tb.endswith(b"\n") else b"\n"
            tb2 = tb + sep + norm(TODAY_ENTRY, tb.count(b"\r\n") > tb.count(b"\n") * 0.8)
            ww_bytes(TODAY, tb2)
            log("[TODAY] append OK | %d -> %d B" % (len(tb), len(rw_bytes(TODAY))))
    except Exception as e:
        log("[TODAY] 异常: %r" % (e,))

    # ---------- 6. 清理临时文件 ----------
    for t in ["_inspect_run.txt", "_inspect_new_icons.txt", "_v2_run.txt",
              "_skill_diff.txt", "_skill_diff_u8.txt", "_disk_now.txt", "_disk_now_u8.txt",
              "replace_icons_v2_result.txt", "_v2_git_status.txt", "_v2_git_diff.txt",
              "_v2f_git_add.txt", "_v2f_git_status.txt", "_v2f_git_commit.txt",
              "_v2f_git_hash.txt", "_v2f_git_log.txt", "_v2_commit_msg.txt"]:
        p = os.path.join(DEV, t)
        try:
            if os.path.exists(p):
                os.remove(p)
                log("[CLEAN] 删除 %s" % t)
        except Exception as e:
            log("[CLEAN] %s 失败: %r" % (t, e))
    log("[CLEAN] 保留: replace_icons_v2.py / inspect_new_icons.py(一次性审计) / _old_icons_backup/")
    log("RESULT: ALL_DONE")
except BaseException:
    log("TRACEBACK:")
    log(traceback.format_exc())
    log("RESULT: FAILED")

with open(RESULT, "wb") as f:
    f.write(("\n".join(out) + "\n").encode("utf-8"))
