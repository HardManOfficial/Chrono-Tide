# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 对话推进方式判定（自动 / 键盘 / 鼠标）

序章是「黑底居中文字」，用 8×5 稀疏网格采样会漏掉文字区域，
因此本探针改为【文字带区域】灰度差（y 24%~42%，x 15%~85%）。

流程：进游戏 → 先空等（排除自动推进）→ Enter → Space → 鼠标点击，
      每步输出文字带变化量并留截图。

用法：python phase0_wa2_advance.py [--fs]
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
START_BTN = (0.48, 0.541)


def shot(target, name):
    l, t, w, h = P.rect_of(target)
    path = os.path.join(OUT_DIR, name)
    ImageGrab.grab(bbox=(l, t, l + w, t + h), all_screens=True).save(path)
    return path


def band(target):
    """对话区域 灰度像素（跳过标题栏/菜单栏；序章为黑底居中文字，全区域对比即可）"""
    l, t, w, h = P.rect_of(target)
    x0, x1 = l + int(w * 0.08), l + int(w * 0.92)
    y0, y1 = t + int(h * 0.08), t + int(h * 0.99)
    if x1 - x0 < 8 or y1 - y0 < 8:
        return None
    img = ImageGrab.grab(bbox=(x0, y0, x1, y1), all_screens=True).convert("L")
    return list(img.getdata())


def bdiff(a, b):
    if a is None or b is None or len(a) != len(b):
        return -1.0
    return sum(abs(x - y) for x, y in zip(a, b)) / max(1, len(a))


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
    print("Phase 0+ · WA2 对话推进方式判定 · 全屏=%s" % fs)
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
    if fs:
        P.send_combo(P.VK["alt"], P.VK["return"])
        time.sleep(3.0)
        print("    全屏矩形 %s" % (P.rect_of(target),))

    print("[2] 点击开始游戏…")
    P.send_click_frac(target, *START_BTN)
    print("    等待序章稳定…")
    prev = P.sample(target)
    stable, t0 = 0, time.time()
    while time.time() - t0 < 40 and stable < 4:
        time.sleep(1.0)
        cur = P.sample(target)
        c, _ = P.diff(prev, cur)
        prev = cur
        stable = stable + 1 if c <= 1 else 0
    print("    就绪（稳定度 %d）" % stable)
    shot(target, "wa2_adv_00_start.png")

    print()
    print("[3] 推进方式对照（指标＝对话文字带灰度平均差，>3 视为有变化）")
    cur = band(target)

    def measure(label, action=None, wait=2.2, cap=None):
        nonlocal cur
        if action is not None:
            action()
        time.sleep(wait)
        if not P.user32.IsWindow(target):
            print("  %-14s 窗口消失" % label)
            return None
        nxt = band(target)
        d = bdiff(cur, nxt)
        cur = nxt
        mark = "   << 有响应" if d > 3 else ""
        kind = "（无输入）" if action is None else ""
        print("  %-14s%s 文字带差 %6.2f%s" % (label, kind, d, mark))
        if cap:
            shot(target, cap)
        return d

    measure("空等 A", None, 3.0)
    measure("空等 B", None, 3.0)
    measure("Enter #1", lambda: P.send_key(P.VK["return"]), 2.2, "wa2_adv_01_enter.png")
    measure("Enter #2", lambda: P.send_key(P.VK["return"]), 2.2, "wa2_adv_02_enter.png")
    measure("Space",    lambda: P.send_key(P.VK["space"]), 2.2, "wa2_adv_03_space.png")
    measure("左键点击", lambda: P.send_click_frac(target, 0.5, 0.5), 2.2, "wa2_adv_04_click.png")
    measure("左键点击", lambda: P.send_click_frac(target, 0.5, 0.5), 2.2, None)
    measure("Esc",      lambda: P.send_key(P.VK["escape"]), 2.2, "wa2_adv_05_esc.png")

    print()
    print("[4] 清理…")
    P.cleanup(before, my_pids)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
