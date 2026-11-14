@echo off
chcp 65001 >nul 2>&1
setlocal
title chrono-tide - release
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run.ps1" release
if errorlevel 1 pause
endlocal
