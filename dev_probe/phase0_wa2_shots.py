# -*- coding: utf-8 -*-
"""
Phase 0+ 辅助 —— WA2 启动后画面时间序列截图（不注入）

用途：搞清「Leaf 标志 → 标题菜单」的自然演进与停留时长。

用法：python phase0_wa2_shots.py [间隔秒] [张数] [前缀]
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

from PIL import ImageGrab  # noqa: E402

OUT_DIR = r"D:\CTLIB\dev_probe"


def main():
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 4.0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    prefix = sys.argv[3] if len(sys.argv) > 3 else "wa2_seq"
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")

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
            target = fresh[0][0]
            print("    目标 0x%X %dx%d" % (target, fresh[0][1][0], fresh[0][1][1]))
            break
        time.sleep(0.4)

    if not target:
        print("!! 未出现窗口")
        P.cleanup(before, my_pids)
        return 1

    P.user32.SetForegroundWindow(target)
    t_start = time.time()
    for i in range(count):
        time.sleep(interval)
        if not P.user32.IsWindow(target):
            print("    窗口消失于第 %d 张" % (i + 1))
            break
        el = time.time() - t_start
        l, t, w, h = P.rect_of(target)
        path = os.path.join(OUT_DIR, "%s_%02d_%.0fs.png" % (prefix, i + 1, el))
        img = ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True)
        img.save(path)
        # 采样差异，作为「是否还在变化」的快速指标
        s = P.sample(target)
        print("    %5.1fs  %s  %dx%d  样本%r" % (el, os.path.basename(path), w, h, s[:3]))

    print("[2] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
