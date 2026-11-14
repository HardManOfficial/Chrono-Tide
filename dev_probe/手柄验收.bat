@echo off
title Chrono Tide 手柄验收（Phase 1）
cd /d D:\CTLIB

if "%CT_E2E_GAME%"=="" set "CT_E2E_GAME=E:\GAL\白色相簿2\WA2_chs.exe"

echo ==============================================================
echo   Chrono Tide 手柄验收（Phase 1）
echo ==============================================================
echo.
echo   这个脚本会自动启动游戏并监听手柄，你只需要做这几件事：
echo.
echo   [1] 确认已关闭 Chrono Tide 本体（避免和它抢手柄）
echo   [2] 游戏窗口出现后，用鼠标点一下游戏窗口
echo   [3] 用鼠标点标题画面的「开始游戏」，然后等序章自动播完
echo       （序章约 2 分钟自动播放，这段时间按手柄没用，不是坏了）
echo   [4] 进入对话画面后：按手柄 A = 推进对话；按手柄 B = 弹出菜单
echo.
echo   游戏路径: %CT_E2E_GAME%
echo.
if not exist "%CT_E2E_GAME%" (
  echo   [错误] 找不到游戏。请用记事本打开本文件，修改 CT_E2E_GAME 那一行
  echo.
  pause
  exit /b 1
)
echo   确认上面几步都清楚后，按任意键开始...
pause >nul
cls

call flutter\bin\flutter.bat test test\services\gamepad\gamepad_e2e_manual_test.dart --reporter expanded

echo.
echo ==============================================================
echo   结束。请往上翻，找「汇总：注入成功 N 次」那一行。
echo   N 大于 0，并且游戏里的对话确实被推进了 = 验收通过。
echo ==============================================================
echo.
pause
