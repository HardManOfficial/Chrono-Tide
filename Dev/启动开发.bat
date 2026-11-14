@echo off
chcp 65001 >nul 2>&1
setlocal
title chrono-tide - dev
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run.ps1" dev
if errorlevel 1 pause
endlocal
