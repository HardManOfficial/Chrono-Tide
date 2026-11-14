# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 标题菜单键盘可操作性验证

背景：标题菜单约 22s 后才出现（Leaf 标志 → 白屏 → 黑屏过场 → 标题）。
      此前在标志/白屏阶段做的按键测试全部无效。
      本探针等到标题稳定后再注入，并逐步截图以人工确认落点。

用法：python phase0_wa2_title.py [--no-enter]
      --no-enter  只测方向键，不按 Enter（避免进入游戏）
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

from PIL import ImageGrab  # noqa: E402

OUT_DIR = r"D:\CTLIB\dev_probe"
TITLE_MIN_WAIT = 24.0  # 标题最早出现的秒数


def shot(target, name):
    l, t, w, h = P.rect_of(target)
    path = os.path.join(OUT_DIR, name)
    ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True).save(path)
    return path


def wait_title(target, timeout=60.0):
    """等到「已过 TITLE_MIN_WAIT」且画面连续稳定。"""
    t0 = time.time()
    prev = P.sample(target)
    stable = 0
    while time.time() - t0 < timeout:
        time.sleep(0.6)
        el = time.time() - t0
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        if c <= 1:
            stable += 1
        else:
            stable = 0
        if stable >= 3 and el >= TITLE_MIN_WAIT:
            print("    标题稳定：用时 %.1fs" % el)
            return True
    print("    !! 等待超时")
    return False


def probe(target, label, action, cap=None, wait=1.8):
    if not P.user32.IsWindow(target):
        print("  %-16s 窗口消失" % label)
        return None
    before = P.sample(target)
    n = action()
    time.sleep(wait)
    if not P.user32.IsWindow(target):
        print("  %-16s 插入=%d  ** 窗口消失 **" % (label, n))
        return None
    after = P.sample(target)
    c, avg = P.diff(before, after)
    note = "  << 有响应" if c >= 3 else ""
    print("  %-16s 插入=%d  变色点 %2d/%d  平均差 %6.1f%s"
          % (label, n, c, P.COLS * P.ROWS, avg, note))
    if cap:
        shot(target, cap)
    return c


def main():
    no_enter = "--no-enter" in sys.argv
    game_exe = os.path.join(P.GAME_DIR, "WA2_chs.exe")

    print("=" * 72)
    print("Phase 0+ · WA2 标题菜单键盘验证 · 按Enter=%s" % (not no_enter))
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
    print("[2] 等待标题出现（≥%.0fs 且稳定）…" % TITLE_MIN_WAIT)
    wait_title(target)
    shot(target, "wa2_nav_00_title.png")

    print("[3] 标题基线（3 × 1.0s）")
    prev = P.sample(target)
    for i in range(3):
        time.sleep(1.0)
        cur = P.sample(target)
        c, avg = P.diff(prev, cur)
        prev = cur
        print("    第%d次 变色点 %d/%d 平均差 %.1f" % (i + 1, c, P.COLS * P.ROWS, avg))

    print("[4] 方向键")
    probe(target, "Down", lambda: P.send_key(P.VK["down"]), "wa2_nav_01_down1.png")
    probe(target, "Down", lambda: P.send_key(P.VK["down"]), "wa2_nav_02_down2.png")
    probe(target, "Up",   lambda: P.send_key(P.VK["up"]),   "wa2_nav_03_up.png")
    probe(target, "Up",   lambda: P.send_key(P.VK["up"]),   None)

    if not no_enter:
        print("[5] Enter ×4（观察是否进入游戏）")
        for i in range(4):
            c = probe(target, "Enter #%d" % (i + 1),
                      lambda: P.send_key(P.VK["return"]),
                      "wa2_nav_1%d_enter.png" % (i + 1), wait=2.5)
            if c is None:
                break
            # 首次 Enter 后给足时间过场
            if i == 0:
                time.sleep(4.0)

    print("[6] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
