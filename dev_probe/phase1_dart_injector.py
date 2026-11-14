# -*- coding: utf-8 -*-
"""
Phase 1 探针 —— 用【Dart 注入器】(lib/services/gamepad/input_injector.dart) 真机驱动 WA2

方法：Python 负责窗口编排与观察（复用 phase0_wa2_probe），Dart 负责注入。
判定信号：`Alt+Enter` 全屏切换（窗口矩形离散变化，不受画面动画干扰）。

序列（含控制组）：
  rect0                    初始窗口化
  → Dart 注入 F13（惰性）   矩形应 **不变**（控制组，证明变化确实来自注入）
  → Dart 注入 Alt+Enter     矩形应 → 全屏
  → Dart 注入 Alt+Enter     矩形应 → 窗口化

用法：python phase1_dart_injector.py [exe]
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import phase0_wa2_probe as P  # noqa: E402

ROOT = r"D:\CTLIB"
DART_CANDIDATES = [
    os.path.join(ROOT, r"flutter\bin\dart.bat"),
    os.path.join(ROOT, r"flutter\bin\cache\dart-sdk\bin\dart.exe"),
]
PROBE = os.path.join(ROOT, r"dev_probe\injector_probe.dart")

screen_w = P.user32.GetSystemMetrics(0)
screen_h = P.user32.GetSystemMetrics(1)


def find_dart():
    for c in DART_CANDIDATES:
        if os.path.exists(c):
            return c
    return None


def classify(hwnd):
    l, t, w, h = P.rect_of(hwnd)
    is_fs = (l <= 0 and t <= 0 and w >= screen_w - 2 and h >= screen_h - 2)
    return ("全屏" if is_fs else "窗口化"), (l, t, w, h)


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


def run_probe(dart, pid, mode):
    cmd = [dart, "run", PROBE, str(pid), mode]
    print("    $ dart run injector_probe.dart %d %s" % (pid, mode))
    try:
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=180)
    except subprocess.TimeoutExpired:
        print("    !! dart 探针超时")
        return None
    for line in (r.stdout or "").splitlines():
        print("      | %s" % line)
    if r.returncode != 0:
        print("    !! 退出码 %s" % r.returncode)
        for line in (r.stderr or "").splitlines()[:6]:
            print("      ! %s" % line)
    return r.returncode


def main():
    exe_name = sys.argv[1] if len(sys.argv) > 1 else "WA2_chs.exe"
    game_exe = os.path.join(P.GAME_DIR, exe_name)
    dart = find_dart()

    print("=" * 72)
    print("Phase 1 · Dart 注入器真机验证（WA2 / Leaf 引擎）")
    print("  dart=%s" % dart)
    print("  screen=%dx%d" % (screen_w, screen_h))
    print("=" * 72)
    if dart is None:
        print("!! 找不到 dart 可执行文件")
        return 1
    if not os.path.exists(PROBE):
        print("!! 缺失探针 %s" % PROBE)
        return 1

    before = P.windows_map()
    proc = subprocess.Popen([game_exe], cwd=P.GAME_DIR)
    my_pids = {proc.pid}
    print("[1] 启动 WA2 PID=%d" % proc.pid)

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

    game_pid = P.windows_map()[target][2]
    P.user32.SetForegroundWindow(target)
    print("[2] 目标进程 PID=%d（Dart 侧将绑定它）" % game_pid)
    print("[3] 等待标题画面稳定…")
    ok = wait_title(target)
    print("    标题就绪=%s" % ok)

    steps = []
    st, rect = classify(target)
    print("[4] 初始状态: %s %s" % (st, rect))

    print()
    print("[5.1] 控制组 —— Dart 注入惰性键 F13（应无变化）")
    run_probe(dart, game_pid, "f13")
    time.sleep(2.0)
    st_f13, rect_f13 = classify(target)
    changed_f13 = rect_f13 != rect
    print("      → %s %s   变化=%s" % (st_f13, rect_f13, changed_f13))
    steps.append(("F13 控制组（应不变）", not changed_f13))

    print()
    print("[5.2] Dart 注入 Alt+Enter（应 → 全屏）")
    run_probe(dart, game_pid, "altenter")
    time.sleep(3.5)
    st1, rect1 = classify(target)
    print("      → %s %s" % (st1, rect1))
    steps.append(("Alt+Enter → 全屏", st1 == "全屏"))

    print()
    print("[5.3] Dart 注入 Alt+Enter（应 → 窗口化）")
    run_probe(dart, game_pid, "altenter")
    time.sleep(3.5)
    st2, rect2 = classify(target)
    print("      → %s %s" % (st2, rect2))
    steps.append(("Alt+Enter → 窗口化", st2 == "窗口化"))

    print()
    print("=" * 72)
    print("判定")
    print("=" * 72)
    all_ok = True
    for label, passed in steps:
        print("  [%s] %s" % ("PASS" if passed else "FAIL", label))
        all_ok = all_ok and passed
    print("  → %s" % ("**Dart 注入器真机验证通过** ✅" if all_ok
                      else "**存在失败项** ❌"))

    print()
    print("[6] 清理…")
    P.cleanup(before, my_pids)
    return 0 if all_ok else 4


if __name__ == "__main__":
    raise SystemExit(main())
