# -*- coding: utf-8 -*-
"""
Phase 0+ 真机联调探针 —— WA2「按键推进对话」验证

目标：打通 Phase 1 的验收判定 ——
      「注入 Enter → 游戏画面确实推进」+ 全屏模式下同样有效。

判定：等待画面【稳定】后（连续 N 次采样无变化）再注入，
      此时像素对比是可靠的（动画已停止）。

用法：
    python phase0_wa2_story.py                # 窗口化
    python phase0_wa2_story.py --fullscreen   # 先 Alt+Enter 切全屏再测
    python phase0_wa2_story.py --enter-only   # 跳过方向键，直接连按 Enter
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402


def settle(target, timeout=40.0, need=3, tag=""):
    """等待画面稳定：连续 need 次采样几乎无变化。返回耗时，失败返回 -1。"""
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
                el = time.time() - t0
                print("    画面稳定%s，耗时 %.1fs" % (tag, el))
                return el
        else:
            stable = 0
    print("    !! 稳定超时（%s）" % tag)
    return -1


def step(label, target, action, wait=1.6):
    """注入一次并报告画面变化。"""
    if not P.user32.IsWindow(target):
        print("  %-18s 目标窗口已消失" % label)
        return None
    before = P.sample(target)
    n = action()
    time.sleep(wait)
    if not P.user32.IsWindow(target):
        print("  %-18s 插入=%d  ** 窗口已消失 **" % (label, n))
        return None
    after = P.sample(target)
    c, avg = P.diff(before, after)
    mark = "  << 有响应" if c >= 3 else ""
    print("  %-18s 插入=%d  变色点 %2d/%d  平均差 %6.1f%s"
          % (label, n, c, P.COLS * P.ROWS, avg, mark))
    return c


def main():
    argv = sys.argv[1:]
    fullscreen = "--fullscreen" in argv
    enter_only = "--enter-only" in argv
    control = "--control" in argv
    exe_name = "WA2_chs.exe"
    game_exe = os.path.join(P.GAME_DIR, exe_name)

    print("=" * 72)
    print("Phase 0+ 联调 · WA2 按键推进验证 · 全屏=%s 仅Enter=%s 控制组=%s"
          % (fullscreen, enter_only, control))
    print("=" * 72)

    before = P.windows_map()
    proc = subprocess.Popen([game_exe], cwd=P.GAME_DIR)
    my_pids = {proc.pid}
    print("[1] 启动 PID=%d，等待窗口…" % proc.pid)

    target = None
    t0 = time.time()
    while time.time() - t0 < 40:
        now = P.windows_map()
        fresh = [(h, v) for h, v in now.items()
                 if h not in before and v[0] > 200 and v[1] > 150]
        if fresh:
            fresh.sort(key=lambda kv: kv[1][0] * kv[1][1], reverse=True)
            target, (w, h, pid, title) = fresh[0]
            print("    目标 0x%X  %dx%d  pid=%d  %r" % (target, w, h, pid, title))
            break
        time.sleep(0.4)

    if not target:
        print("!! 未出现窗口")
        P.cleanup(before, my_pids)
        return 1

    P.user32.ShowWindow(target, 9)
    time.sleep(0.3)
    P.user32.SetForegroundWindow(target)
    print("[2] 矩形 %s" % (P.rect_of(target),))

    print("[3] 等待标题画面稳定…")
    settle(target, tag="（标题）")

    if fullscreen:
        print("[4] Alt+Enter 切全屏")
        P.send_combo(P.VK["alt"], P.VK["return"])
        time.sleep(3.0)
        print("    矩形 %s" % (P.rect_of(target),))
        settle(target, tag="（全屏后）")

    print("[5] 稳定基线（3 × 1.0s，应接近 0）")
    prev = P.sample(target)
    for i in range(3):
        time.sleep(1.0)
        cur = P.sample(target)
        c, avg = P.diff(prev, cur)
        prev = cur
        print("    第%d次 变色点 %d/%d  平均差 %.1f" % (i + 1, c, P.COLS * P.ROWS, avg))

    print()
    print("[6] 按键序列")
    if control:
        print("    ** 控制组：注入惰性键 F13(0x7C)，节奏与实验组一致 **")
        down = up = enter = (lambda: P.send_key(0x7C))
        lbl_d, lbl_u, lbl_e = "F13(控)", "F13(控)", "F13(控)"
    else:
        down = lambda: P.send_key(P.VK["down"])
        up = lambda: P.send_key(P.VK["up"])
        enter = lambda: P.send_key(P.VK["return"])
        lbl_d, lbl_u, lbl_e = "Down（菜单导航）", "Up", "Enter"

    if not enter_only:
        step(lbl_d, target, down, 1.2)
        step(lbl_d, target, down, 1.2)
        step(lbl_u, target, up, 1.2)

    for i in range(6):
        c = step("%s #%d" % (lbl_e, i + 1), target, enter, 1.8)
        if c is None:
            break
        if i == 0:
            print("    （若进入游戏，等待过场…）")
            time.sleep(4.0)
            settle(target, timeout=20, tag="（过场后）")

    print()
    print("[7] 清理…")
    P.cleanup(before, my_pids)
    print("    完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
