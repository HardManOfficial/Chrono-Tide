# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 游戏流程观察（序章之后何时进入「输入驱动对话」）

流程：进游戏 → O 段：120s 不注入，每 12s 截图 → E 段：连按 3 次 Enter，每次截图。
产出：wa2_flow_O*.png / wa2_flow_E*.png
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

from PIL import ImageGrab  # noqa: E402

OUT_DIR = r"D:\CTLIB\dev_probe"
START_BTN = (0.48, 0.541)


def shot(target, name):
    l, t, w, h = P.rect_of(target)
    p = os.path.join(OUT_DIR, name)
    ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True).save(p)
    return p


def wait_title(target, timeout=60.0):
    t0 = time.time()
    prev = P.sample(target)
    stable = 0
    while time.time() - t0 < timeout:
        time.sleep(0.6)
        el = time.time() - t0
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        stable = stable + 1 if c <= 1 else 0
        if stable >= 3 and el >= 24.0:
            print("    标题稳定（%.1fs）" % el)
            return True
    print("    !! 等标题超时")
    return False


def main():
    obs_secs = float(sys.argv[1]) if len(sys.argv) > 1 else 120.0
    step = 12.0
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")
    print("=" * 72)
    print("Phase 0+ · WA2 流程观察（序章后 %.0fs 不注入，再测 Enter）" % obs_secs)
    print("=" * 72)

    before = P.windows_map()
    proc = subprocess.Popen([game_exe], cwd=P.GAME_DIR)
    my_pids = {proc.pid}
    target = None
    t0 = time.time()
    while time.time() - t0 < 40:
        now = P.windows_map()
        fresh = [(h, v) for h, v in now.items()
                 if h not in before and v[0] > 200 and v[1] > 150]
        if fresh:
            fresh.sort(key=lambda kv: kv[1][0] * kv[1][1], reverse=True)
            target = fresh[0][0]
            break
        time.sleep(0.4)
    if not target:
        print("!! 未出现窗口")
        P.cleanup(before, my_pids)
        return 1

    P.user32.SetForegroundWindow(target)
    print("[1] 等待标题…")
    wait_title(target)
    print("[2] 点击开始游戏…")
    P.send_click_frac(target, *START_BTN)
    time.sleep(3.0)

    n = int(obs_secs / step)
    print("[3] O 段：%.0fs 不注入，每 %.0fs 截图" % (obs_secs, step))
    for i in range(n):
        time.sleep(step)
        shot(target, "wa2_flow_O%02d.png" % (i + 1))
        print("    O%02d (%.0fs) 已截图" % (i + 1, (i + 1) * step))

    print("[4] E 段：连按 Enter ×3")
    for i in range(3):
        P.send_key(P.VK["return"], hold_ms=50)
        time.sleep(2.5)
        shot(target, "wa2_flow_E%d.png" % (i + 1))
        print("    E%d 已截图（插入 Enter）" % (i + 1))

    print("[5] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
