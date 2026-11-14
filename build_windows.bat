@echo off
chcp 65001 >nul
echo ========================================
echo   Chrono Tide Windows 打包助手
echo ========================================
echo.

echo [1/5] 检查是否有运行的进程...
tasklist | findstr chrono_tide >nul 2>&1
if %errorlevel%==0 (
    echo ⚠️  发现正在运行的 chrono_tide.exe 进程
    echo.
    echo 请先关闭 Chrono Tide 应用后再运行此脚本！
    echo.
    echo 提示: 
    echo   - 检查任务栏是否有应用窗口
    echo   - 或按 Ctrl+Shift+Esc 打开任务管理器结束进程
    echo.
    pause
    exit /b 1
) else {
    echo ✓ 未发现运行中的进程
}

echo.
echo [2/5] 清理构建缓存...
call flutter clean
if %errorlevel% neq 0 (
    echo ❌ 清理失败，请检查是否有文件被占用
    pause
    exit /b 1
)
echo ✓ 清理完成

echo.
echo [3/5] 获取依赖...
call flutter pub get
if %errorlevel% neq 0 (
    echo ❌ 获取依赖失败
    pause
    exit /b 1
)
echo ✓ 依赖获取完成

echo.
echo [4/5] 开始打包...
echo 这可能需要几分钟时间，请耐心等待...
echo.
call flutter build windows
if %errorlevel% neq 0 (
    echo.
    echo ❌ 打包失败！
    echo.
    echo 可能的原因:
    echo   1. 应用程序仍在运行
    echo   2. 文件被其他程序占用
    echo   3. 磁盘空间不足
    echo.
    pause
    exit /b 1
)

echo.
echo [5/5] 检查 Magpie 超分工具...
set "MAGPIE_SRC=windows\runner\magpie"
set "MAGPIE_DST=build\windows\x64\runner\Release\runtime\magpie"
if exist "%MAGPIE_SRC%\Magpie.exe" (
    echo ✓ Magpie.exe 已通过 CMake 安装
) else (
    echo ⚠️  Magpie.exe 未找到！
    echo.
    echo 内置超分功能需要 Magpie，请执行以下步骤：
    echo   1. 从 https://github.com/Blinue/Magpie/releases 下载最新版
    echo   2. 解压后将 Magpie.exe、TouchHelper.exe、effects/ 复制到:
    echo      %MAGPIE_SRC%\
    echo   3. 重新运行此打包脚本
    echo.
    echo 当前仅 config 模板已就绪，超分启动将不可用。
    echo 用户仍可通过外接模式使用自己安装的 Magpie。
)
if not exist "%MAGPIE_DST%\effects" (
    echo ⚠️  effects 目录缺失，超分效果将无法使用
)

echo.
echo ========================================
echo   ✅ 打包成功！
echo ========================================
echo.
echo 输出位置: build\windows\x64\runner\Release\
echo 文件名:   chrono_tide.exe
echo.
echo 是否打开输出文件夹? (Y/N)
choice /C YN /N /M "请选择:"
if errorlevel 2 goto end
if errorlevel 1 explorer "build\windows\x64\runner\Release"

:end
echo.
pause
