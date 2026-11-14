# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 序章是否【自动推进】（最终对照）

流程：进游戏 → A 段：30s 完全不注入，每 5s 截图 → B 段：连按 2 次 Enter 截图。
产出可拼接对比的截图（wa2_auto_A*.png / wa2_auto_B*.png）。

判定：若 A 段各图文字相同 → 无自动推进 → B 段变化即由注入引起。
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
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")
    print("=" * 72)
    print("Phase 0+ · WA2 序章自动推进对照")
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
    print("[2] 点击开始游戏，进入序章…")
    P.send_click_frac(target, *START_BTN)
    prev = P.sample(target)
    stable, t0 = 0, time.time()
    while time.time() - t0 < 40 and stable < 4:
        time.sleep(1.0)
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        stable = stable + 1 if c <= 1 else 0
    print("    就绪（稳定度 %d），进入 A 段：30s 不注入" % stable)

    for i in range(6):
        time.sleep(5.0)
        shot(target, "wa2_auto_A%d.png" % (i + 1))
        print("    A%d 已截图" % (i + 1))

    print("[3] B 段：连按 Enter ×2（每次间隔 2.5s）")
    for i in range(2):
        P.send_key(P.VK["return"], hold_ms=50)
        time.sleep(2.5)
        shot(target, "wa2_auto_B%d.png" % (i + 1))
        print("    B%d 已截图（插入 Enter）" % (i + 1))

    print("[4] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
