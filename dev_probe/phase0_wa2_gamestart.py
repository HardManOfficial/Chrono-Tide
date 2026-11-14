# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 进入游戏并验证「注入按键推进对话」

流程：等标题（≥24s）→ 鼠标点击「开始游戏」→ 逐步截图观察 →
      连按 Enter 并统计画面变化，验证「按键→推进对话」这条 Phase 1 验收链路。

用法：python phase0_wa2_gamestart.py [--fs]
      --fs  点击前先 Alt+Enter 切全屏（验证全屏下整条链路）
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

from PIL import ImageGrab  # noqa: E402

OUT_DIR = r"D:\CTLIB\dev_probe"
TITLE_MIN_WAIT = 24.0
START_BTN = (0.48, 0.541)  # 「开始游戏」分数坐标（由图像分析得出）


def shot(target, name):
    l, t, w, h = P.rect_of(target)
    if w <= 0 or h <= 0:
        return None
    path = os.path.join(OUT_DIR, name)
    ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True).save(path)
    return path


def settle(target, tag="", timeout=25.0, need=3):
    prev = P.sample(target)
    stable, t0 = 0, time.time()
    while time.time() - t0 < timeout:
        time.sleep(0.6)
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        if c <= 1:
            stable += 1
            if stable >= need:
                print("    稳定%s（%.1fs）" % (tag, time.time() - t0))
                return True
        else:
            stable = 0
    print("    !! 稳定超时%s" % tag)
    return False


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
        if stable >= 3 and el >= TITLE_MIN_WAIT:
            print("    标题稳定（%.1fs）" % el)
            return True
    print("    !! 等标题超时")
    return False


def main():
    fs = "--fs" in sys.argv
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")

    print("=" * 72)
    print("Phase 0+ · WA2 进入游戏 + 按键推进验证 · 全屏=%s" % fs)
    print("=" * 72)

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
            break
        time.sleep(0.4)

    if not target:
        print("!! 未出现窗口")
        P.cleanup(before, my_pids)
        return 1

    P.user32.SetForegroundWindow(target)
    print("[2] 等待标题…")
    wait_title(target)

    if fs:
        print("[2.5] Alt+Enter 切全屏")
        P.send_combo(P.VK["alt"], P.VK["return"])
        time.sleep(3.0)
        print("    矩形 %s" % (P.rect_of(target),))
        settle(target, tag="（全屏后）")

    shot(target, "wa2_play_00_title.png")

    print("[3] 点击「开始游戏」%s" % (START_BTN,))
    n = P.send_click_frac(target, *START_BTN)
    print("    插入=%d" % n)
    time.sleep(3.0)
    c, avg = P.diff(P.sample(target), P.sample(target))
    shot(target, "wa2_play_01_clicked.png")
    print("    已截图 wa2_play_01_clicked.png")

    settle(target, tag="（点击后）", timeout=30)
    shot(target, "wa2_play_02_settled.png")

    print("[4] 连按 Enter（观察推进）")
    for i in range(6):
        if not P.user32.IsWindow(target):
            print("    窗口消失")
            break
        b = P.sample(target)
        nn = P.send_key(P.VK["return"], hold_ms=50)
        time.sleep(2.0)
        a = P.sample(target)
        cc, av = P.diff(b, a)
        mark = "  << 有响应" if cc >= 3 else ""
        print("  Enter #%d  插入=%d  变色点 %2d/%d  平均差 %6.1f%s"
              % (i + 1, nn, cc, P.COLS * P.ROWS, av, mark))
        if i in (0, 1, 3):
            shot(target, "wa2_play_1%d_enter.png" % (i + 1))

    print("[5] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
