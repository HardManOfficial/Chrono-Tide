# -*- coding: utf-8 -*-
"""
Phase 0 游戏注入探针 v2 —— 经内置 Locale Emulator 转区启动后验证注入

背景：直接启动 `Start.exe` / `Start_4o+3.5s.exe` 均以 0xC0000005 崩溃；
经项目内置 LEProc 转区启动后正常弹出「起動設定」对话框 → 确认该游戏依赖日语转区。

判定方法：像素采样对比（不读画面内容、不存图）
  对照组：静态对话框上不注入，两次采样的差异即「自然变化基线」
  实验组：SendInput 发 Enter，采样差异应显著超过基线

安全设计：只取像素颜色数值；结束必定清理进程。
"""
import ctypes
import ctypes.wintypes as wt
import os
import subprocess
import time

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
VK_RETURN = 0x0D
VK_ESCAPE = 0x1B

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
GAME_DIR = r"D:\gal\しごカレ ～エッチな女子大生"
GAME_EXE = os.path.join(GAME_DIR, "Start_4o+3.5s.exe")

COLS, ROWS = 8, 5


def send_key(vk, hold_ms=50):
    def _one(flags):
        inp = INPUT()
        inp.type = INPUT_KEYBOARD
        inp.ki.wVk = vk
        inp.ki.wScan = 0
        inp.ki.dwFlags = flags
        return SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

    n = _one(0)
    time.sleep(hold_ms / 1000.0)
    n += _one(KEYEVENTF_KEYUP)
    return n


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


def sample(hwnd):
    r = wt.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(r))
    w, h = r.right - r.left, r.bottom - r.top
    if w <= 0 or h <= 0:
        return None
    hdc = user32.GetDC(0)
    pts = []
    try:
        for row in range(ROWS):
            for col in range(COLS):
                x = r.left + w * (col + 1) // (COLS + 1)
                y = r.top + h * (row + 1) // (ROWS + 1)
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


def main():
    print("=" * 72)
    print("Phase 0 探针 v2 · 经 Locale Emulator 转区后验证注入")
    print("=" * 72)
    for p in (LE, GAME_EXE):
        if not os.path.exists(p):
            print("!! 缺失: %s" % p)
            return 1

    before = windows_map()
    print("[1] 启动前窗口 %d 个；用 LEProc 转区启动…" % len(before))
    proc = subprocess.Popen([LE, GAME_EXE], cwd=GAME_DIR)
    print("    LEProc PID=%d" % proc.pid)

    target = None
    t0 = time.time()
    while time.time() - t0 < 30:
        now = windows_map()
        fresh = [(h, v) for h, v in now.items()
                 if h not in before and v[0] > 150 and v[1] > 100]
        if fresh:
            fresh.sort(key=lambda kv: kv[1][0] * kv[1][1], reverse=True)
            target, (w, h, pid, title) = fresh[0]
            print("    目标窗口 0x%X  %dx%d  pid=%d  title=%r"
                  % (target, w, h, pid, title))
            break
        time.sleep(0.3)

    if not target:
        print("!! 30s 内未出现窗口")
        try:
            proc.terminate()
        except Exception:
            pass
        return 1

    user32.ShowWindow(target, 9)
    time.sleep(0.3)
    user32.SetForegroundWindow(target)
    time.sleep(1.5)

    fg = user32.GetForegroundWindow()
    print("[2] 抢焦点结果: 目标在前台 = %s（fg=0x%X vs target=0x%X）"
          % (fg == target, fg, target))
    print()

    DELTA = 1.2
    print("[3] 对照组（不注入）")
    base = []
    for i in range(3):
        s1 = sample(target)
        time.sleep(DELTA)
        c, avg = diff(s1, sample(target))
        base.append(c)
        print("    第%d次 变色点 %d/%d  平均通道差 %.1f" % (i + 1, c, COLS * ROWS, avg))
    base_max = max(base)
    print("    → 自然变化上限 %d" % base_max)
    print()

    print("[4] 实验组（注入 Enter，hold=50ms）")
    exp = []
    alive = True
    for i in range(3):
        s1 = sample(target)
        n = send_key(VK_RETURN, hold_ms=50)
        time.sleep(DELTA)
        if not user32.IsWindow(target):
            print("    第%d次 插入=%d → **目标窗口已消失**（对话框被确认，强烈提示已收到）" % (i + 1, n))
            exp.append(COLS * ROWS)
            alive = False
            break
        c, avg = diff(s1, sample(target))
        exp.append(c)
        print("    第%d次 插入=%d  变色点 %d/%d  平均通道差 %.1f"
              % (i + 1, n, c, COLS * ROWS, avg))
    exp_max = max(exp) if exp else 0
    print()

    print("=" * 72)
    print("判定")
    print("=" * 72)
    print("  自然变化上限  : %d" % base_max)
    print("  注入后最大变化: %d%s" % (exp_max, "" if alive else "（窗口被确认关闭）"))
    received = (not alive) or exp_max > max(base_max * 2, base_max + 4)
    print("  → 游戏是否收到按键: %s" % ("**是**" if received else "**否 / 不明确**"))

    # 若对话框被确认，游戏可能已进入全屏，再抓一次新窗口看看
    time.sleep(2.0)
    now = windows_map()
    fresh = [(h, v) for h, v in now.items() if h not in before]
    print()
    print("[5] 确认后的窗口情况（新增 %d 个）" % len(fresh))
    for h, (w, hh, pid, title) in fresh[:5]:
        print("    0x%X  %dx%d  pid=%d  title=%r" % (h, w, hh, pid, title))

    print()
    print("[6] 清理…")
    pids = {v[2] for _h, v in fresh}
    for h, (w, hh, pid, title) in fresh:
        user32.PostMessageW(h, 0x0010, 0, 0)
    time.sleep(1.5)
    for pid in pids:
        try:
            subprocess.run(["taskkill", "/F", "/PID", str(pid)],
                           capture_output=True, timeout=10)
        except Exception as e:
            print("    taskkill %d 失败: %s" % (pid, e))
    if proc.poll() is None:
        proc.terminate()
    time.sleep(0.8)
    print("    完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
