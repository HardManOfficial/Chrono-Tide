@echo off
chcp 65001 >nul
echo ========================================
echo  CTLIB 一键打包脚本（国内镜像版）
echo ========================================

REM 设置国内镜像源（解决 pub.dev 无法访问的问题）
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

echo [INFO] 使用国内镜像源:
echo   PUB_HOSTED_URL=%PUB_HOSTED_URL%
echo   FLUTTER_STORAGE_BASE_URL=%FLUTTER_STORAGE_BASE_URL%
echo.

echo [1/3] 清理构建缓存...
call flutter clean
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] flutter clean 失败
    pause
    exit /b 1
)

echo.
echo [2/3] 获取依赖包...
call flutter pub get
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] flutter pub get 失败
    echo        请检查网络连接或镜像源是否可用
    pause
    exit /b 1
)

echo.
echo [3/3] 开始打包 Windows 版本...
call flutter build windows
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] flutter build windows 失败
    pause
    exit /b 1
)

echo.
echo ========================================
echo  ✅ 打包完成！
echo  输出目录: build\windows\x64\runner\Release\
echo ========================================
pause
