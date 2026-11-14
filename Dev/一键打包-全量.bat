@echo off
chcp 65001 >nul 2>&1
setlocal
title chrono-tide - build2
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run.ps1" build2
if errorlevel 1 pause
endlocal
