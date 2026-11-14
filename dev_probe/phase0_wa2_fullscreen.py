# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— WA2 全屏模式下的输入有效性（双向离散信号验证）

原理：`Alt+Enter` 切换全屏/窗口化，会让【窗口矩形】发生离散变化。
      这是不受画面动画干扰的硬信号。
      流程：窗口化 →Alt+Enter→ 全屏 →Alt+Enter→ 窗口化
      若两次矩形变化都发生，则证明：
        · 窗口化下注入有效（第一次切换）
        · **全屏下注入同样有效**（第二次切换，这是 Phase 0 的未覆盖项）

用法：python phase0_wa2_fullscreen.py [exe] [--le]
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

screen_w = P.user32.GetSystemMetrics(0)
screen_h = P.user32.GetSystemMetrics(1)


def classify(hwnd):
    """把窗口矩形归类为 全屏 / 窗口化"""
    l, t, w, h = P.rect_of(hwnd)
    is_fs = (l <= 0 and t <= 0 and w >= screen_w - 2 and h >= screen_h - 2)
    return ("全屏" if is_fs else "窗口化"), (l, t, w, h)


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    exe_name = argv[0] if argv else "WA2_chs.exe"
    use_le = "--le" in sys.argv
    game_exe = os.path.join(P.GAME_DIR, exe_name)

    print("=" * 72)
    print("Phase 0+ · WA2 全屏模式输入有效性 · exe=%s" % exe_name)
    print("  屏幕 %dx%d" % (screen_w, screen_h))
    print("=" * 72)
    if not os.path.exists(game_exe):
        print("!! 缺失: %s" % game_exe)
        return 1

    before = P.windows_map()
    proc = subprocess.Popen([P.LE, game_exe] if use_le else [game_exe],
                            cwd=P.GAME_DIR)
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
    time.sleep(3.0)

    st0, r0 = classify(target)
    print("[2] 初始状态: %s %s" % (st0, r0))

    results = []
    for i in (1, 2):
        print()
        print("[3.%d] Alt+Enter 第 %d 次…" % (i, i))
        n = P.send_combo(P.VK["alt"], P.VK["return"])
        time.sleep(3.5)
        if not P.user32.IsWindow(target):
            print("    !! 窗口消失")
            break
        st, r = classify(target)
        print("    插入=%d  →  %s %s" % (n, st, r))
        results.append((st0 if i == 1 else results[-1][0], st))
        st0 = st

    print()
    print("=" * 72)
    print("判定")
    print("=" * 72)
    if len(results) >= 2:
        to_fs = results[0][1] == "全屏"
        back = results[1][1] == "窗口化"
        print("  窗口化 →全屏 切换: %s" % ("成功" if to_fs else "未发生"))
        print("  全屏   →窗口化 切换: %s" % ("成功" if back else "未发生"))
        if to_fs and back:
            print("  → **全屏模式下注入同样有效** ✅")
        elif to_fs:
            print("  → 仅证明窗口化下有效；全屏下未观察到第二次切换 ⚠️")
        else:
            print("  → 未观察到任何切换 ⚠️")
    else:
        print("  样本不足")
    print("  中间态: %s" % results)

    print()
    print("[4] 清理…")
    P.cleanup(before, my_pids)
    print("    完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
