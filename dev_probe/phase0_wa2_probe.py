# -*- coding: utf-8 -*-
"""
Phase 0+ 探针 —— 白色相簿2 (Leaf / AquaPlus 引擎) 注入验证

用途：补齐 Phase 0 未覆盖的「引擎差异」。WA2 目录内无任何 xinput/dinput DLL，
      是「零手柄感知」的典型样本。

用法：
    python phase0_wa2_probe.py observe [exe] [--le]   # 只启动 + 观察自然变化
    python phase0_wa2_probe.py inject  [exe] [--le]   # 启动 + 注入（离散信号判定）

判定方法：
    WA2 标题界面有动画背景 → 像素对比失效，改用【离散信号】：
    - 窗口矩形变化（全屏切换）
    - 目标窗口消失（被确认/退出）
    - 新窗口出现（对话框/菜单弹出）
    - 标题变化
安全设计：结束必定 taskkill 清理本次启动的全部新进程。
"""
import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import sys
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

INPUT_KEYBOARD = 1
INPUT_MOUSE = 0
KEYEVENTF_KEYUP = 0x0002
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004

VK = {
    "return": 0x0D, "escape": 0x1B, "space": 0x20,
    "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "ctrl": 0x11, "alt": 0x12, "pagedown": 0x22, "pageup": 0x21,
    "f1": 0x70, "f5": 0x74,
}

ULONG_PTR = ctypes.c_size_t


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD),
                ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]


class _U(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _U)]


SendInput = user32.SendInput
SendInput.argtypes = [wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
SendInput.restype = wt.UINT
user32.GetDC.restype = wt.HDC
user32.GetDC.argtypes = [wt.HWND]
user32.ReleaseDC.argtypes = [wt.HWND, wt.HDC]
gdi32.GetPixel.restype = wt.DWORD
gdi32.GetPixel.argtypes = [wt.HDC, ctypes.c_int, ctypes.c_int]
user32.GetWindowTextW.argtypes = [wt.HWND, wt.LPWSTR, ctypes.c_int]

LE = r"D:\CTLIB\build\windows\x64\runner\Release\runtime\locale_emulator\LEProc.exe"
GAME_DIR = r"E:\GAL\白色相簿2"

COLS, ROWS = 8, 5


# ──────────────── 输入注入 ────────────────

def _key(vk, flags):
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.ki.wVk = vk
    inp.ki.dwFlags = flags
    return SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def send_key(vk, hold_ms=50):
    n = _key(vk, 0)
    time.sleep(hold_ms / 1000.0)
    n += _key(vk, KEYEVENTF_KEYUP)
    return n


def send_combo(mod_vk, vk, hold_ms=60):
    n = _key(mod_vk, 0)
    time.sleep(0.02)
    n += _key(vk, 0)
    time.sleep(hold_ms / 1000.0)
    n += _key(vk, KEYEVENTF_KEYUP)
    n += _key(mod_vk, KEYEVENTF_KEYUP)
    return n


def send_click_frac(hwnd, fx, fy):
    """在窗口矩形相对坐标 (fx, fy) 处点击（0..1）"""
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    sw, sh = user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)
    ax = int(((r.left + w * fx) * 65535) / sw)
    ay = int(((r.top + h * fy) * 65535) / sh)
    seq = [(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay),
           (MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE, ax, ay),
           (MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_ABSOLUTE, ax, ay),
           (MOUSEEVENTF_LEFTUP | MOUSEEVENTF_ABSOLUTE, ax, ay)]
    n = 0
    for flags, x, y in seq:
        inp = INPUT()
        inp.type = INPUT_MOUSE
        inp.mi.dx, inp.mi.dy = x, y
        inp.mi.dwFlags = flags
        n += SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))
        time.sleep(0.03)
    return n


# ──────────────── 窗口与采样 ────────────────

def title_of(hwnd):
    buf = ctypes.create_unicode_buffer(256)
    user32.GetWindowTextW(hwnd, buf, 256)
    return buf.value


def windows_map():
    out = {}

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def _cb(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            r = wt.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(r))
            pid = wt.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            out[hwnd] = (r.right - r.left, r.bottom - r.top, pid.value,
                         title_of(hwnd))
        return True

    user32.EnumWindows(_cb, 0)
    return out


def rect_of(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    return r.left, r.top, r.right - r.left, r.bottom - r.top


def sample(hwnd):
    x0, y0, w, h = rect_of(hwnd)
    if w <= 0 or h <= 0:
        return None
    hdc = user32.GetDC(0)
    pts = []
    try:
        for row in range(ROWS):
            for col in range(COLS):
                x = x0 + w * (col + 1) // (COLS + 1)
                y = y0 + h * (row + 1) // (ROWS + 1)
                pts.append(gdi32.GetPixel(hdc, x, y) & 0xFFFFFF)
    finally:
        user32.ReleaseDC(0, hdc)
    return pts


def diff(a, b):
    if a is None or b is None:
        return -1, -1.0
    changed, total = 0, 0
    for pa, pb in zip(a, b):
        d = (abs(((pa >> 16) & 255) - ((pb >> 16) & 255))
             + abs(((pa >> 8) & 255) - ((pb >> 8) & 255))
             + abs((pa & 255) - (pb & 255)))
        total += d
        if d > 24:
            changed += 1
    return changed, total / max(1, len(a))


# ──────────────── 主流程 ────────────────

def kill_pids(pids):
    for pid in sorted(pids):
        try:
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=10)
        except Exception as e:
            print("    taskkill %d 失败: %s" % (pid, e))


def cleanup(before, my_pids):
    now = windows_map()
    fresh = [(h, v) for h, v in now.items() if h not in before]
    pids = set(my_pids)
    for h, v in fresh:
        pids.add(v[2])
        user32.PostMessageW(h, 0x0010, 0, 0)
    time.sleep(1.5)
    kill_pids(pids)
    time.sleep(0.8)


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    mode = argv[0] if argv else "observe"
    exe_name = argv[1] if len(argv) > 1 else "WA2_chs.exe"
    use_le = "--le" in sys.argv
    game_exe = os.path.join(GAME_DIR, exe_name)

    print("=" * 72)
    print("Phase 0+ 探针 · 白色相簿2 (Leaf engine) · mode=%s" % mode)
    print("  exe=%s  转区=%s" % (exe_name, use_le))
    print("=" * 72)
    if not os.path.exists(game_exe):
        print("!! 缺失: %s" % game_exe)
        return 1
    if use_le and not os.path.exists(LE):
        print("!! 缺失 LE: %s" % LE)
        return 1

    before = windows_map()
    print("[1] 启动前窗口 %d 个；启动游戏…" % len(before))
    cmd = [LE, game_exe] if use_le else [game_exe]
    proc = subprocess.Popen(cmd, cwd=GAME_DIR)
    my_pids = {proc.pid}
    print("    启动器 PID=%d" % proc.pid)

    target = None
    t0 = time.time()
    while time.time() - t0 < 40:
        now = windows_map()
        fresh = [(h, v) for h, v in now.items()
                 if h not in before and v[0] > 200 and v[1] > 150]
        if fresh:
            fresh.sort(key=lambda kv: kv[1][0] * kv[1][1], reverse=True)
            target, (w, h, pid, title) = fresh[0]
            print("    目标窗口 0x%X  %dx%d  pid=%d  title=%r"
                  % (target, w, h, pid, title))
            break
        if proc.poll() is not None and not use_le:
            print("!! 进程已退出，退出码 %s" % proc.returncode)
            return 1
        time.sleep(0.4)

    if not target:
        print("!! 40s 内未出现窗口")
        cleanup(before, my_pids)
        return 1

    user32.ShowWindow(target, 9)
    time.sleep(0.3)
    user32.SetForegroundWindow(target)
    time.sleep(2.0)

    fg = user32.GetForegroundWindow()
    print("[2] 目标在前台 = %s" % (fg == target))
    print("    窗口矩形: %s" % (rect_of(target),))
    print("    屏幕分辨率: %dx%d"
          % (user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)))
    print()

    print("[3] 自然变化基线（不注入，连续 5 次 × 1.0s）")
    base = []
    prev = sample(target)
    for i in range(5):
        time.sleep(1.0)
        cur = sample(target)
        c, avg = diff(prev, cur)
        base.append(c)
        prev = cur
        print("    第%d次 变色点 %d/%d  平均通道差 %.1f"
              % (i + 1, c, COLS * ROWS, avg))
    print("    → 自然变化上限 %d" % max(base))

    if mode != "inject":
        print()
        print("[4] observe 模式：不注入。清理…")
        cleanup(before, my_pids)
        print("    完成")
        return 0

    print()
    print("[4] 注入测试（动画界面下用【离散信号】判定）")
    known = set(windows_map().keys())
    tests = [
        ("Alt+Enter", lambda: send_combo(VK["alt"], VK["return"])),
        ("Enter",     lambda: send_key(VK["return"])),
        ("Esc",       lambda: send_key(VK["escape"])),
        ("Space",     lambda: send_key(VK["space"])),
        ("Down",      lambda: send_key(VK["down"])),
    ]
    for label, fn in tests:
        if not user32.IsWindow(target):
            print("  %-10s 目标窗口已消失，停止" % label)
            break
        r0, t0 = rect_of(target), title_of(target)
        n = fn()
        time.sleep(1.5)
        gone = not user32.IsWindow(target)
        r1, t1 = rect_of(target), title_of(target)
        now = windows_map()
        newh = [h for h in now if h not in known]
        sig = []
        if gone:
            sig.append("** 目标窗口已消失 **")
        else:
            if r0 != r1:
                sig.append("矩形 %s -> %s" % (r0, r1))
            if t0 != t1:
                sig.append("标题 %r -> %r" % (t0, t1))
        for h in newh[:3]:
            sig.append("新窗口 %r %dx%d" % (now[h][3], now[h][0], now[h][1]))
            known.add(h)
        print("  %-10s 插入=%d  %s"
              % (label, n, " ; ".join(sig) if sig else "无离散变化"))
        if gone:
            break

    print()
    print("[5] 清理…")
    cleanup(before, my_pids)
    print("    完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
