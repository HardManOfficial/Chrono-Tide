# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 对话推进方式【三段对照】（空等 / Enter / 左键点击）

流程：进游戏 → 等待 140s（越过序章开场）→
      A 段：15s 不注入，每 3s 截图
      B 段：每 3s 注入 Enter 并截图
      C 段：每 3s 注入左键点击并截图
产出 wa2_in_A*.png / B*.png / C*.png，供拼接对比。
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
PREROLL = float(sys.argv[1]) if len(sys.argv) > 1 else 140.0
N = 5
GAP = 3.0


def shot(target, name):
    l, t, w, h = P.rect_of(target)
    ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True).save(
        os.path.join(OUT_DIR, name))


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
            return True
    return False


def main():
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")
    print("=" * 72)
    print("Phase 0+ · WA2 三段对照 · 预跑 %.0fs" % PREROLL)
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
    print("[1] 等标题…")
    wait_title(target)
    print("[2] 点击开始游戏…")
    P.send_click_frac(target, *START_BTN)
    print("[3] 预跑 %.0fs（越过序章开场）…" % PREROLL)
    time.sleep(PREROLL)

    print("[4] A 段：不注入")
    for i in range(N):
        shot(target, "wa2_in_A%d.png" % (i + 1))
        time.sleep(GAP)
    print("[5] B 段：每 %.0fs 注入 Enter" % GAP)
    for i in range(N):
        P.send_key(P.VK["return"], hold_ms=50)
        time.sleep(GAP)
        shot(target, "wa2_in_B%d.png" % (i + 1))
    print("[6] C 段：每 %.0fs 注入左键点击(中心)" % GAP)
    for i in range(N):
        P.send_click_frac(target, 0.5, 0.45)
        time.sleep(GAP)
        shot(target, "wa2_in_C%d.png" % (i + 1))

    print("[7] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
