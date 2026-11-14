# -*- coding: utf-8 -*-
"""
Phase 0+ 辅助 —— 抓取 WA2 标题界面截图（用于定位 START 按钮坐标）

仅抓取标题界面，用于工程定位；不抓取游戏正文内容。

用法：python phase0_wa2_shot.py [输出png] [exe]
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

from PIL import ImageGrab  # noqa: E402


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else r"D:\CTLIB\dev_probe\wa2_title.png"
    exe_name = sys.argv[2] if len(sys.argv) > 2 else "WA2_chs.exe"
    game_exe = os.path.join(P.GAME_DIR, exe_name)

    before = P.windows_map()
    proc = subprocess.Popen([game_exe], cwd=P.GAME_DIR)
    my_pids = {proc.pid}
    print("[1] 启动 PID=%d" % proc.pid)

    target = None
    t0 = time.time()
    while time.time() - t0 < 40:
        now = P.windows_map()
        fresh = [(h, v) for h, v in now.items()
                 if h not in before and v[0] > 200 and v[1] > 150]
        if fresh:
            fresh.sort(key=lambda kv: kv[1][0] * kv[1][1], reverse=True)
            target, (w, h, pid, title) = fresh[0]
            print("    目标 0x%X %dx%d pid=%d %r" % (target, w, h, pid, title))
            break
        time.sleep(0.4)

    if not target:
        print("!! 未出现窗口")
        P.cleanup(before, my_pids)
        return 1

    P.user32.SetForegroundWindow(target)
    print("[2] 等待标题稳定…")
    prev = P.sample(target)
    stable = 0
    t0 = time.time()
    while time.time() - t0 < 40 and stable < 3:
        time.sleep(0.6)
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        stable = stable + 1 if c <= 1 else 0
    print("    稳定度=%d，耗时 %.1fs" % (stable, time.time() - t0))

    l, t, w, h = P.rect_of(target)
    img = ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True)
    img.save(out)
    print("[3] 已保存 %s  (%dx%d)" % (out, img.size[0], img.size[1]))

    print("[4] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
