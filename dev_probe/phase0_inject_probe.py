# -*- coding: utf-8 -*-
"""
Phase 0 输入注入探针（机制层）—— 不依赖游戏

对应方案文档 `docs/DEV/features/gamepad_adaptation_implementation_plan.md` §7 Phase 0：
  · 0-4 键码格式（虚拟键码 vs 扫描码）与按键保持时长
  · 顺带证明 SendInput 是否**真的更新了键盘状态**（这是它相对 PostMessage 的核心优势）

安全设计：全程只发 **F13 / F14 / F15**（0x7C–0x7E）。标准键盘没有这三个键，
几乎没有程序绑定它们，因此 SendInput 的全局注入不会干扰用户正在用的窗口。

不修改任何文件。运行即输出结论表。
"""
import ctypes
import ctypes.wintypes as wt
import time

user32 = ctypes.windll.user32

INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_SCANCODE = 0x0008
KEYEVENTF_EXTENDEDKEY = 0x0001
MAPVK_VK_TO_VSC = 0

VK_F13, VK_F14, VK_F15 = 0x7C, 0x7D, 0x7E

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


class _INPUTunion(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _INPUTunion)]


SendInput = user32.SendInput
SendInput.argtypes = [wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
SendInput.restype = wt.UINT

user32.MapVirtualKeyW.argtypes = [wt.UINT, wt.UINT]
user32.MapVirtualKeyW.restype = wt.UINT

user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_ushort

user32.GetForegroundWindow.restype = wt.HWND


def _send(vk, scan, flags):
    """投递一个键盘事件，返回 SendInput 实际插入的事件数（0 = 被拒，多为 UIPI 权限问题）"""
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.ki.wVk = vk
    inp.ki.wScan = scan
    inp.ki.dwFlags = flags
    inp.ki.time = 0
    inp.ki.dwExtraInfo = 0
    return SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def probe_press(vk, *, scancode=False, hold_ms=50):
    """
    按一次键（down → 保持 hold_ms → up），并在保持期间轮询 GetAsyncKeyState。
    返回 (插入事件数, 是否被 GetAsyncKeyState 观察到按下, 实际观察窗口 ms)
    """
    scan = user32.MapVirtualKeyW(vk, MAPVK_VK_TO_VSC) if scancode else 0
    down_flags = KEYEVENTF_SCANCODE if scancode else 0
    up_flags = down_flags | KEYEVENTF_KEYUP

    n_down = _send(vk, scan, down_flags)
    t0 = time.perf_counter()
    observed = False
    while (time.perf_counter() - t0) * 1000 < hold_ms:
        if user32.GetAsyncKeyState(vk) & 0x8000:
            observed = True
        time.sleep(0.001)
    elapsed = (time.perf_counter() - t0) * 1000
    n_up = _send(vk, scan, up_flags)
    # 抬起后确认已释放
    time.sleep(0.005)
    still_down = bool(user32.GetAsyncKeyState(vk) & 0x8000)
    return n_down + n_up, observed, elapsed, still_down


def main():
    print("=" * 68)
    print("Phase 0 探针 · 机制层（SendInput / 键码格式 / 保持时长）")
    print("=" * 68)
    print("INPUT 结构大小 : %d 字节（x64 期望 40）" % ctypes.sizeof(INPUT))
    fg = user32.GetForegroundWindow()
    print("当前前台窗口   : 0x%X（测试只用 F13-F15，不干扰它）" % (fg or 0))
    print()

    if ctypes.sizeof(INPUT) != 40:
        print("!! INPUT 结构大小不符，后续结论不可信，终止")
        return 1

    results = []

    # ── 测试 A：虚拟键码 vs 扫描码 ──
    print("─" * 68)
    print("测试 A · 键码格式（hold = 50ms）")
    print("─" * 68)
    print("%-14s %-10s %-12s %-10s %-10s" %
          ("模式", "事件数", "被观测到", "保持ms", "抬起后仍按"))

    for label, scancode, vk in (("虚拟键码", False, VK_F13),
                                ("扫描码", True, VK_F14)):
        n, obs, ms, stuck = probe_press(vk, scancode=scancode, hold_ms=50)
        results.append(("A", label, n, obs))
        print("%-14s %-10d %-12s %-10.1f %-10s" %
              (label, n, "是" if obs else "否", ms, "是!" if stuck else "否"))
    print()

    # ── 测试 B：保持时长扫描（用扫描码模式，更接近游戏场景）──
    print("─" * 68)
    print("测试 B · 保持时长扫描（扫描码模式）")
    print("─" * 68)
    print("%-12s %-12s %-10s %s" % ("保持 ms", "被观测到", "实际 ms", "备注"))
    for hold in (1, 5, 10, 20, 30, 50, 100):
        n, obs, ms, stuck = probe_press(VK_F15, scancode=True, hold_ms=hold)
        note = "抬起后仍按下!" if stuck else ""
        results.append(("B", hold, n, obs))
        print("%-12d %-12s %-10.1f %s" %
              (hold, "是" if obs else "否", ms, note))
    print()

    # ── 结论 ──
    print("=" * 68)
    print("结论")
    print("=" * 68)
    a_ok = [r for r in results if r[0] == "A" and r[3]]
    print("· SendInput 返回非 0 事件数 : %s" %
          ("是" if all(r[2] > 0 for r in results) else "否（UIPI 拦截？）"))
    print("· 虚拟键码模式可被观测到    : %s" %
          ("是" if any(r[3] for r in results if r[0] == "A" and r[1] == "虚拟键码") else "否"))
    print("· 扫描码模式可被观测到      : %s" %
          ("是" if any(r[3] for r in results if r[0] == "A" and r[1] == "扫描码") else "否"))
    print("· 最短可观测保持时长        : %s" %
          (min([r[1] for r in results if r[0] == "B" and r[3]], default="无")))
    print()
    print("注意：本探针只证明「SendInput 生效且更新了键盘状态」。")
    print("      游戏能否收到（尤其独占全屏 / DirectInput 轮询式引擎）须用真游戏验证。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
