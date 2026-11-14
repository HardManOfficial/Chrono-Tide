# ============================================================
# Chrono Tide 一键打包脚本（优化版 v2.1）
# ============================================================
# 兼容: Windows PowerShell 5.1+
# 编码: UTF-8 with BOM
# ============================================================

param(
    [switch]$Clean,
    [switch]$SkipInstaller,
    [switch]$SkipUPX,
    [switch]$All
)

if ($All) {
    $Clean = $true
    $SkipInstaller = $false
    $SkipUPX = $false
}

# 退出码：任何一步失败都必须让调用方（面板 / bat）能感知到
# 之前只打印 SCRIPT ERROR 而不返回非零，导致面板把失败当成功、窗口直接关掉
$ExitCode = 0

# ======================== 路径与配置 ========================
# 始终基于脚本文件位置推导项目根目录，避免工作目录导致空值
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
}
# 最终兜底：已知路径（ENV-REBUILD 2026-11-09：面板位于 apps\chrono-tide\Dev\scripts）
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = "D:\CTLIB\apps\chrono-tide\Dev\scripts"
}
# Dev\scripts -> Dev -> 项目根
$DevDir      = Split-Path -Parent $ScriptDir
$ProjectRoot = Split-Path -Parent $DevDir
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = "D:\CTLIB\apps\chrono-tide"
    $DevDir      = Join-Path $ProjectRoot "Dev"
}
# 工作区根（D:\CTLIB）：环境在这一层
$CTRoot = Split-Path -Parent (Split-Path -Parent $ProjectRoot)

# 工作目录
$WorkDir = Join-Path $DevDir "build_work"
$TempDir = Join-Path $WorkDir "temp"
$LogDir = Join-Path $DevDir "logs"
# 产物统一落到本项目的 Dev\dist（一个项目一个产物目录，不再汇到工作区）
$OutputDir = Join-Path $DevDir "dist"

# Flutter 构建输出
$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"

# 外置依赖源路径
$OpenListSource = Join-Path $ProjectRoot "openlist"
$ToolsSource = Join-Path $ProjectRoot "assets\tools"
$MagpieSource = Join-Path $ProjectRoot "windows\runner\magpie"
$LESource = Join-Path $ProjectRoot "windows\runner\locale_emulator"
$RunnerTools = Join-Path $ProjectRoot "windows\runner\tools"
# CTFontHook 游戏字体替换载荷（独立项目，已迁到 apps\ct-font-hook，按版本目录取最新）
$FontHookDistRoot = Join-Path $CTRoot "apps\ct-font-hook\dist"
# 许可文本从 CTFontHook 仓库根取（dist 发布包里**不含** LICENSE / 第三方声明）
$FontHookSrcRoot = Join-Path $CTRoot "apps\ct-font-hook"

# UPX 工具路径
$UPXExe = Join-Path $ProjectRoot "upx-4.2.4-win64\upx.exe"

# Inno Setup 编译器路径（优先工作区 env\toolchains，已从 D:\Chrono Tide 工具 迁入）
$ISCCExe = $null
$ISCCPaths = @(
    (Join-Path $CTRoot "env\toolchains\innosetup\ISCC.exe"),
    "D:\Chrono Tide 工具\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)
foreach ($p in $ISCCPaths) {
    if (Test-Path $p) { $ISCCExe = $p; break }
}

# 版本号
$PubspecPath = Join-Path $ProjectRoot "pubspec.yaml"
$Version = "unknown"
if (Test-Path $PubspecPath) {
    $lines = Get-Content $PubspecPath -Encoding UTF8
    foreach ($line in $lines) {
        if ($line -match '^version:\s*(.+)') {
            $Version = $Matches[1].Trim()
            break
        }
    }
}

# 保存原始 TEMP（后续仅 Inno Setup 阶段重定向）
$OrigTemp = $env:TEMP
$OrigTmp = $env:TMP

# ======================== 辅助函数 ========================

function Write-Step([string]$Step, [string]$Message) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  [$Step] $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Done([string]$Message) {
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "  [!!] $Message" -ForegroundColor Yellow
}

function Write-Fail([string]$Message) {
    Write-Host "  [X]  $Message" -ForegroundColor Red
}

function Write-Info([string]$Message) {
    Write-Host "  ..  $Message" -ForegroundColor Gray
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DirSize([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return 0 }
    $files = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
    if ($files) {
        return ($files | Measure-Object -Property Length -Sum).Sum
    }
    return 0
}


# ======================== 主流程 ========================
$TotalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {

Write-Host ""
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Chrono Tide v$Version - Build Script" -ForegroundColor Magenta
Write-Host "========================================" -ForegroundColor Magenta
Write-Host "  Project:  $ProjectRoot"
Write-Host "  WorkDir:  $WorkDir"
Write-Host "  Output:   $OutputDir"
Write-Host "  Mode:     $(if ($Clean) {'Full Rebuild'} else {'Incremental'})"
Write-Host "  UPX:      $(if ($SkipUPX) {'Skip'} else {'Enable'})"
Write-Host "  Installer:$(if ($SkipInstaller) {'Skip'} else {'Enable'})"
Write-Host ""

# ======================== Step 0: Environment ========================
Write-Step "0/7" "Environment Check"

foreach ($d in @($WorkDir, $TempDir, $LogDir, $OutputDir)) {
    if ([string]::IsNullOrWhiteSpace($d)) {
        throw "Work directory path is empty — check ScriptDir/ProjectRoot"
    }
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}
Write-Done "Work directories ready"

# 优先检测工作区 Flutter SDK（D:\CTLIB\env\toolchains\flutter\bin），其次项目内旧位置，再次系统 PATH
$localFlutterDir = Join-Path $CTRoot "env\toolchains\flutter\bin"
if (-not (Test-Path (Join-Path $localFlutterDir "flutter.bat"))) {
    $legacyFlutterDir = Join-Path $ProjectRoot "flutter\bin"
    if (Test-Path (Join-Path $legacyFlutterDir "flutter.bat")) { $localFlutterDir = $legacyFlutterDir }
}
# 直接用绝对路径调用，不依赖 PATH（PATH 里装的别的版本会造成版本错乱）
$FlutterExe = Join-Path $localFlutterDir "flutter.bat"
if (-not (Test-Path $FlutterExe)) {
    $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCmd) { $FlutterExe = $flutterCmd.Source }
}
if (-not (Test-Path $FlutterExe)) {
    Write-Fail "Flutter SDK not found! Expected at: $localFlutterDir"
    throw "Flutter not found"
}
# 让 flutter_tools 内部子进程也能定位 SDK
$env:FLUTTER_ROOT = Split-Path -Parent $localFlutterDir
if ($env:PATH -notlike "*$localFlutterDir*") { $env:PATH = "$localFlutterDir;$env:PATH" }
# pub 缓存锁在 D 盘
if (-not $env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $CTRoot "env\cache\pub" }
Write-Done "Flutter: $FlutterExe"

if (-not (Test-Path (Join-Path $ProjectRoot "pubspec.yaml"))) {
    Write-Fail "pubspec.yaml not found at: $ProjectRoot"
    throw "Invalid project root"
}
Write-Done "Project root: $ProjectRoot"

# Windows 开发者模式：带插件的 Windows 构建要建符号链接（.plugin_symlinks），
# 未开启时 flutter build 只会丢一句英文 "Building with plugins requires symlink support"
# 然后以 exit code 1 退出，很难看出是什么问题 —— 这里提前翻译成人话
$devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = $null
if (Test-Path $devModeKey) {
    $devMode = (Get-ItemProperty -Path $devModeKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
}
if ($devMode -ne 1) {
    Write-Warn "Windows 开发者模式未开启"
    Write-Info "带插件的项目无法构建（系统拒绝创建符号链接），会在编译阶段失败"
    Write-Info "一键修复：右键以管理员身份运行  D:\CTLIB\修复环境-开启开发者模式.bat"
    Write-Info "手动开启：设置 → 隐私和安全性 → 开发者选项 → 开发人员模式"
}

# Visual Studio C++ 工具链：Flutter 编译 Windows 程序的硬依赖
# 缺了只会得到一句 "Unable to find suitable Visual Studio toolchain"，看不出要装什么
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsInstall = $null
if (Test-Path $vswhere) {
    $prevEapVs = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $vsRaw = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>&1
    $ErrorActionPreference = $prevEapVs
    if ($vsRaw) { $vsInstall = ([string]($vsRaw | Select-Object -First 1)).Trim() }
}
if ($vsInstall -and (Test-Path $vsInstall)) {
    Write-Done ('MSVC 工具链: ' + $vsInstall)
} else {
    Write-Warn "没找到 Visual Studio C++ 工具链（MSVC）"
    Write-Info "Flutter 编译 Windows 程序必须用 MSVC —— 不装一定失败"
    Write-Info "一键安装：右键以管理员身份运行  D:\CTLIB\安装C++编译工具链.bat"
    Write-Info "（约 1.5-3 GB，5-30 分钟，只需装一次）"
    Write-Info "注意：装了 Build Tools 但没勾 MSVC 编译器的话，vswhere 照样查不到，必须补装"
}

# ======================== Step 1: Process Check ========================
Write-Step "1/7" "Process Check"

$runningProcs = @()
foreach ($pname in @('chrono_tide', 'openlist')) {
    $proc = Get-Process -Name $pname -ErrorAction SilentlyContinue
    if ($proc) {
        $runningProcs += $pname
        Write-Warn "Running process: $pname (PID: $($proc.Id -join ', '))"
    }
}

if ($runningProcs.Count -gt 0) {
    Write-Host ""
    Write-Host "  These processes must be closed:" -ForegroundColor Yellow
    foreach ($rp in $runningProcs) { Write-Host "    - $rp" -ForegroundColor Yellow }
    Write-Host ""
    # 无人值守（AI / 定时任务）才自动关；人工双击时仍然问一句，避免误杀正在用的程序
    if ($env:CT_NO_PAUSE -eq '1' -and $env:CT_ALLOW_PROMPT -ne '1') {
        Write-Host "  Auto-closing (unattended mode) ..." -ForegroundColor Gray
        $answer = 'Y'
    } else {
        $answer = Read-Host "  Auto-close them? (Y/N)"
    }
    if ($answer -eq 'Y' -or $answer -eq 'y') {
        # 🔴 这里必须自己确认「真的杀掉了」。旧写法是
        #     Stop-Process -Name $rp -Force -ErrorAction SilentlyContinue
        #     Write-Done "Stopped: $rp"
        # 失败被 SilentlyContinue 吞掉，而 Write-Done 无条件打印 ⇒ 日志里明明写着
        # 「[OK] Stopped」，旧实例却还活着、一直锁着 Release\chrono_tide.exe，
        # 于是 78 秒后在 LINK 阶段炸成 LNK1104「无法打开文件」，
        # 看起来像编译错误，实际是进程没关。
        foreach ($rp in $runningProcs) {
            $killErr = ''
            $dead = $false
            for ($i = 1; $i -le 3; $i++) {
                $procs = @(Get-Process -Name $rp -ErrorAction SilentlyContinue)
                if ($procs.Count -eq 0) { $dead = $true; break }
                foreach ($p in $procs) {
                    # Kill() 比 Stop-Process 稳：它直接持有进程句柄，不重新按名解析
                    try { $p.Kill() } catch { $killErr = $_.Exception.Message }
                }
                Start-Sleep -Milliseconds 600
            }
            if (-not $dead) {
                if (@(Get-Process -Name $rp -ErrorAction SilentlyContinue).Count -eq 0) { $dead = $true }
            }
            if ($dead) {
                Write-Done "Stopped: $rp"
            } else {
                throw "无法结束进程 $rp（$killErr）。请手动关闭它再重试。"
            }
        }
        Start-Sleep -Seconds 1
    } else {
        throw "Please close processes manually and retry"
    }
} else {
    Write-Done "No conflicting processes"
}

# ---- 构建前的硬门禁：Release\chrono_tide.exe 必须真的可写 ----
# 进程死了 ≠ 文件立刻能写：句柄回收、杀软扫描、资源管理器预览都可能还压着它。
# 与其等到 LINK 阶段才以 LNK1104 的形式炸出来（那时已经烧掉一分多钟编译时间，
# 而且报错指向的是链接器，极易误判成代码问题），不如在这里先问一次。
$probeExe = Join-Path $ReleaseDir "chrono_tide.exe"
if (Test-Path $probeExe) {
    $swUnlock = [System.Diagnostics.Stopwatch]::StartNew()
    $unlocked = $false
    while ($swUnlock.Elapsed.TotalSeconds -lt 15) {
        try {
            $fsProbe = [System.IO.File]::Open(
                $probeExe,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            $fsProbe.Close()
            $unlocked = $true
            break
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $unlocked) {
        throw "文件仍被占用，无法写入：$probeExe`n  已等待 15 秒。常见占用者：另一个 chrono_tide 实例 / 杀软实时扫描 / 资源管理器的预览或属性窗口。`n  关闭后重试即可；只有确实是进程在跑时，才会真报 LNK1104。"
    }
    Write-Done "Release exe writable ($([math]::Round($swUnlock.Elapsed.TotalSeconds, 1))s)"
}

# ======================== Step 2: Clean (optional) ========================
if ($Clean) {
    Write-Step "2/7" "Full Clean (-Clean mode)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    Push-Location $ProjectRoot
    & $FlutterExe --no-version-check clean 2>&1 | Out-Null
    Pop-Location

    if (Test-Path $ReleaseDir) {
        # 注意: 不清理 data/ 目录，它包含 Flutter 编译产物
        foreach ($sub in @("$ReleaseDir\Games", "$ReleaseDir\downloads", "$ReleaseDir\logs")) {
            if (Test-Path $sub) {
                Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $sw.Stop()
    Write-Done "Clean done ($($sw.Elapsed.ToString('mm\:ss')))"
} else {
    Write-Step "2/7" "Incremental Build (skip clean)"
    Write-Info "Use -Clean for full rebuild"
    Write-Done "Skipped"
}

# ======================== Step 3: Dependencies ========================
Write-Step "3/7" "Dependency Check"

$packageConfig = Join-Path $ProjectRoot ".dart_tool\package_config.json"
$pubspecYaml = Join-Path $ProjectRoot "pubspec.yaml"
$needPubGet = $false

if (-not (Test-Path $packageConfig)) {
    $needPubGet = $true
    Write-Info "package_config.json missing, need pub get"
} else {
    $configTime = (Get-Item $packageConfig).LastWriteTime
    $yamlTime = (Get-Item $pubspecYaml).LastWriteTime
    if ($yamlTime -gt $configTime) {
        $needPubGet = $true
        Write-Info "pubspec.yaml changed, need pub get"
    } else {
        Write-Done "Dependencies up to date"
    }
}

if ($needPubGet) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location $ProjectRoot
    & $FlutterExe --no-version-check pub get 2>&1 | ForEach-Object { Write-Host "  $_" }
    $pubResult = $LASTEXITCODE
    Pop-Location
    if ($pubResult -ne 0) {
        throw "flutter pub get failed (exit code: $pubResult)"
    }
    $sw.Stop()
    Write-Done "Dependencies resolved ($($sw.Elapsed.ToString('mm\:ss')))"
}

# ======================== Step 4: Flutter Build ========================
Write-Step "4/7" "Build Windows Release"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

Push-Location $ProjectRoot
# --no-version-check：本机没有安装系统级 Git，Flutter 的版本新鲜度检查会调用 git，
# 找不到就整个崩溃（ProcessException: Failed to find "git" in the search path）。
# 这个检查只是比对 SDK 版本是否最新，对构建毫无必要 —— 关掉即可离线构建、也更稳。
& $FlutterExe --no-version-check build windows --release 2>&1 | ForEach-Object { Write-Host "  $_" }
$buildResult = $LASTEXITCODE
Pop-Location

$sw.Stop()

if ($buildResult -ne 0) {
    throw "Build failed (exit code: $buildResult)"
}

$exePath = Join-Path $ReleaseDir "chrono_tide.exe"
if (-not (Test-Path $exePath)) {
    throw "chrono_tide.exe not found after build"
}

$exeSize = (Get-Item $exePath).Length
Write-Done "Build OK: chrono_tide.exe ($(Format-Size $exeSize))"
Write-Info "Build time: $($sw.Elapsed.ToString('mm\:ss'))"

# ======================== Step 5: Deploy Runtime ========================
Write-Step "5/7" "Deploy Runtime Dependencies"

# --- 5.1 OpenList ---
# ★ 2026-10-02 OpenList 半移植化：安装包不再内置 OpenList（原 148MB 的
#   openlist.exe + data，占安装包体积大头）。改为应用内「对接」流程按需
#   从官方服务器下载整合包（openlist_provision.dart，zip ≈53MB，解压到
#   runtime/ 与既有路径吻合）。
#   此段职责：确保 Release 中**不存在** runtime\openlist —— 既不复制新版，
#   也清掉上一版打包可能复制进去的残留（否则 iss 会把它打进新安装包 /
#   混入便携包，白带 149MB）。用户已对接的 openlist 在其安装目录里，
#   与 Release 无关，更新安装时由 iss [InstallDelete] 语义保护（不删）。
Write-Host ""
Write-Host "  [OpenList]" -ForegroundColor White
$olDestDir = Join-Path $ReleaseDir "runtime\openlist"
if (Test-Path $olDestDir) {
    Remove-Item $olDestDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Done "Removed stale runtime\openlist from Release (semi-portable)"
} else {
    Write-Info "OpenList not bundled (semi-portable: paired in-app on demand)"
}

# --- 5.2 Tools ---
# ★ [优化-体积] 2026-10-03：bz.exe/UnRAR.exe/ark*.dll 不再在此复制——它们已作为
#   Flutter assets 打进 data\flutter_assets\assets\tools\（pubspec.yaml:53-57），
#   运行时由 rar_lz4_unzip_service.dart:_ensureToolsExist 在首次解压 .rar.lz4 时
#   释放到 runtime\tools\（缺才释放）。此前脚本+assets 双份携带，包体多付 ~3.9MB。
#   7z.exe/7za.dll 无 asset 副本，仍必须由脚本部署。
Write-Host ""
Write-Host "  [Tools]" -ForegroundColor White
$toolsDestDir = Join-Path $ReleaseDir "runtime\tools"
if (-not (Test-Path $toolsDestDir)) {
    New-Item -ItemType Directory -Path $toolsDestDir -Force | Out-Null
}

if (Test-Path $RunnerTools) {
    foreach ($f in @("7z.exe", "7za.dll")) {
        $src = Join-Path $RunnerTools $f
        if (Test-Path $src) {
            Copy-Item $src $toolsDestDir -Force
            Write-Info "Copied: $f"
        }
    }
    Write-Done "7z tools deployed (rar_lz4 tools: on-demand release from assets)"
} else {
    Write-Warn "windows\runner\tools not found at: $RunnerTools"
}

foreach ($sub in @("$toolsDestDir\Far", "$toolsDestDir\x64")) {
    if (Test-Path $sub) {
        Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "Cleaned: $(Split-Path $sub -Leaf)/"
    }
}

# --- 5.3 Locale Emulator ---
Write-Host ""
Write-Host "  [Locale Emulator]" -ForegroundColor White
if (Test-Path "$LESource\LEProc.exe") {
    $leDestDir = Join-Path $ReleaseDir "runtime\locale_emulator"
    if (-not (Test-Path $leDestDir)) {
        New-Item -ItemType Directory -Path $leDestDir -Force | Out-Null
    }
    foreach ($f in @("LEProc.exe", "LoaderDll.dll", "LocaleEmulator.dll", "LECommonLibrary.dll", "LEConfig.xml")) {
        $src = Join-Path $LESource $f
        if (Test-Path $src) { Copy-Item $src $leDestDir -Force }
    }
    $leLangSrc = Join-Path $LESource "Lang"
    $leLangDst = Join-Path $leDestDir "Lang"
    if (Test-Path $leLangSrc) {
        if (Test-Path $leLangDst) { Remove-Item $leLangDst -Recurse -Force }
        Copy-Item $leLangSrc $leLangDst -Recurse -Force
    }
    Write-Done "Locale Emulator deployed"
} else {
    Write-Info "Locale Emulator source not found, skipped"
}

# --- 5.4 Magpie ---
Write-Host ""
Write-Host "  [Magpie]" -ForegroundColor White
if (Test-Path "$MagpieSource\Magpie.exe") {
    $magpieDestDir = Join-Path $ReleaseDir "runtime\magpie"
    if (-not (Test-Path $magpieDestDir)) {
        New-Item -ItemType Directory -Path $magpieDestDir -Force | Out-Null
    }
    foreach ($f in @("Magpie.exe", "Microsoft.UI.Xaml.dll", "resources.pri")) {
        $src = Join-Path $MagpieSource $f
        if (Test-Path $src) { Copy-Item $src $magpieDestDir -Force }
    }
    $thSrc = Join-Path $MagpieSource "TouchHelper.exe"
    if (Test-Path $thSrc) { Copy-Item $thSrc $magpieDestDir -Force }
    foreach ($sub in @("config", "effects")) {
        $src = Join-Path $MagpieSource $sub
        $dst = Join-Path $magpieDestDir $sub
        if (Test-Path $src) {
            if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
            Copy-Item $src $dst -Recurse -Force
        }
    }
    Write-Done "Magpie deployed"
} else {
    Write-Info "Magpie source not found, skipped"
}

# --- 5.5 FontHook（游戏字体替换载荷）---
# 与 Locale Emulator / Magpie 同族范式：部署到 runtime/，不入 assets
# （避免安装包双份携带 ~1.2MB）。载荷源是同级的 CTFontHook 独立仓库发布目录。
Write-Host ""
Write-Host "  [FontHook]" -ForegroundColor White
if (Test-Path $FontHookDistRoot) {
    # 取名字最大的发布包（形如 CTFontHook-0.1.1-20261016-2056），要求两个架构齐备
    $fhPkg = Get-ChildItem $FontHookDistRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Test-Path (Join-Path $_.FullName "32bit\winmm.dll")) -and
            (Test-Path (Join-Path $_.FullName "64bit\winmm.dll"))
        } | Sort-Object Name -Descending | Select-Object -First 1
    if ($fhPkg) {
        $fhDestDir = Join-Path $ReleaseDir "runtime\fonthook"
        foreach ($fhSub in @("32bit", "64bit")) {
            $fhDstSub = Join-Path $fhDestDir $fhSub
            if (-not (Test-Path $fhDstSub)) {
                New-Item -ItemType Directory -Path $fhDstSub -Force | Out-Null
            }
            Copy-Item (Join-Path $fhPkg.FullName "$fhSub\winmm.dll") $fhDstSub -Force
        }
        # 生成本项目自己的 version.json（**不是** CTFontHook 的文件）
        $fhVer = $fhPkg.Name
        if ($fhPkg.Name -match '^[A-Za-z]+-(\d+\.\d+(?:\.\d+)?)') { $fhVer = $Matches[1] }
        $fh32 = Join-Path $fhDestDir "32bit\winmm.dll"
        $fh64 = Join-Path $fhDestDir "64bit\winmm.dll"
        $fhMeta = [ordered]@{
            upstream    = "CTFontHook"
            version     = $fhVer
            obtained_at = (Get-Date).ToString("yyyy-MM-dd")
            license     = "MIT"
            dll         = [ordered]@{
                "32bit" = [ordered]@{
                    size   = (Get-Item $fh32).Length
                    sha256 = (Get-FileHash $fh32 -Algorithm SHA256).Hash.ToLower()
                }
                "64bit" = [ordered]@{
                    size   = (Get-Item $fh64).Length
                    sha256 = (Get-FileHash $fh64 -Algorithm SHA256).Hash.ToLower()
                }
            }
        }
        # 用无 BOM 的 UTF-8 写（PowerShell 5.1 的 Out-File -Encoding utf8 会带 BOM，
        # 会让 Dart 侧 jsonDecode 直接抛错）
        $fhJson = $fhMeta | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText(
            (Join-Path $fhDestDir "version.json"),
            $fhJson,
            (New-Object System.Text.UTF8Encoding($false)))
        # 开源许可随载荷部署（与 SDL3 的 runtime/sdl3/LICENSE.txt 同范式），
        # 供设置面板「开源组件致谢」的 CTFontHook / Detours 条目引用。
        foreach ($fhDoc in @("LICENSE.txt", "THIRD-PARTY-NOTICES.md")) {
            $fhDocSrc = Join-Path $FontHookSrcRoot $fhDoc
            if (Test-Path $fhDocSrc) {
                Copy-Item $fhDocSrc $fhDestDir -Force
            }
        }
        # 本地「不兼容游戏清单」（Phase 4.3）：从仓库 resources/fonthook/ 复制。
        # 只读清单，缺失不报错（清单可以为空）。
        $fhCompatSrc = Join-Path $ProjectRoot "resources\fonthook\incompatible.json"
        if (Test-Path $fhCompatSrc) {
            Copy-Item $fhCompatSrc $fhDestDir -Force
        } else {
            Write-Info "FontHook incompatible.json not found, skipped"
        }
        Write-Done "FontHook deployed ($($fhPkg.Name))"
    } else {
        Write-Info "FontHook package not found under dist, skipped"
    }
} else {
    Write-Info "FontHook source not found, skipped"
}

# --- 5.6 Create empty dirs ---
Write-Host ""
Write-Host "  [Runtime Dirs]" -ForegroundColor White
foreach ($d in @('data', 'downloads', 'Games', 'logs')) {
    $dirPath = Join-Path $ReleaseDir $d
    if (-not (Test-Path $dirPath)) {
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }
}
Write-Done "Runtime dirs created"

# --- 5.7 Cleanup user data ---
# 注意: data/ 目录包含 Flutter 编译产物(app.so, flutter_assets, icudtl.dat)，不能清空！
# 只清理 Games/downloads/logs 的内容（运行时产生的用户数据）
# 同时清理 data/ 下的便携存储运行时子目录（prefs/game_configs/user_themes 等），
# 防止开发者的认证 token、API 密钥、锁文件等敏感数据被打包进安装包。
Write-Host ""
Write-Host "  [Cleanup]" -ForegroundColor White
foreach ($d in @("$ReleaseDir\Games", "$ReleaseDir\downloads", "$ReleaseDir\logs")) {
    if (Test-Path $d) {
        Get-ChildItem $d -Recurse -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Info "Cleaned user data dirs (Games/downloads/logs)"

# 清理 data/ 下的便携存储运行时子目录（仅运行时生成，非 Flutter 编译产物）
# 这些目录若残留开发者的数据（尤其 prefs/shared_preferences.json 含 auth token），
# 会被 Inno Setup 打包进安装包并在更新时覆盖用户数据。
# [优化-体积] 2026-10-03 清理列表追加 models（NSFW 模型运行时释放副本 17MB）
#   与 data 根级运行时 JSON（收藏/监视候选/会社待审等，防混入安装包）
foreach ($sub in @("prefs", "game_configs", "user_themes", "user_backgrounds", "cache", "tmp", "lock", "migration", "models")) {
    $target = Join-Path $ReleaseDir "data\$sub"
    if (Test-Path $target) {
        Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# 清理运行时日志文件（非 Flutter 编译产物）
$runtimeLog = Join-Path $ReleaseDir "data\metadata_fetch.log"
if (Test-Path $runtimeLog) { Remove-Item $runtimeLog -Force -ErrorAction SilentlyContinue }
# [优化-体积] 2026-10-03 清理 data 根级运行时 JSON（与 iss Excludes 同步）：
#   收藏夹/监视候选/会社别名待审队列等均为本机运行数据，严禁混入安装包
# 2026-10-17 补齐第二批（此前遗漏、实测混入发布包的个人数据）：
#   手柄映射档案 / 解包密码与设置 / 标签库覆盖 / 标题图·OP视频·会社Logo
#   抓取记账（负缓存）/ 会社 Logo 图片缓存 —— 全是开发者本机使用痕迹
foreach ($jsonFile in @("collections.json", "watch_candidates.json", "company_alias_pending.json", "daily_recommendation.json", "company_wall.json", "cleanup_log.jsonl", "company_logo_attempts.json", "gamepad_profiles.json", "op_video_attempts.json", "tag_library_overrides.json", "title_logo_attempts.json", "unpack_passwords.json", "unpack_settings.json")) {
    $j = Join-Path $ReleaseDir "data\$jsonFile"
    if (Test-Path $j) { Remove-Item $j -Force -ErrorAction SilentlyContinue }
}
# 会社 Logo 图片缓存目录（本机下载的图标缓存，非程序资源）
$companyLogosDir = Join-Path $ReleaseDir "data\company_logos"
if (Test-Path $companyLogosDir) {
    Remove-Item $companyLogosDir -Recurse -Force -ErrorAction SilentlyContinue
}
# 旧版字体器载荷残留（runtime\font_hook，现行部署目录是 runtime\fonthook）：
# 旧命名 winmm_x86/x64.dll 已废弃，留着只会把失效 DLL 打进安装包
$staleFontHookDir = Join-Path $ReleaseDir "runtime\font_hook"
if (Test-Path $staleFontHookDir) {
    Remove-Item $staleFontHookDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "Removed stale runtime\font_hook (current payload: runtime\fonthook)"
}
Write-Info "Cleaned portable storage runtime dirs (prefs/game_configs/themes/backgrounds/cache/tmp/lock/migration/models) + runtime JSONs"

$olDataCleanup = Join-Path $ReleaseDir "runtime\openlist\data"
if (Test-Path $olDataCleanup) {
    $logFile = Join-Path $olDataCleanup "log\log.log"
    if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }
    $tempDir2 = Join-Path $olDataCleanup "temp"
    if (Test-Path $tempDir2) { Remove-Item $tempDir2 -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Info "Cleaned openlist runtime logs"
Write-Done "Cleanup done"

# ======================== Step 6: UPX Compression ========================
if (-not $SkipUPX) {
    Write-Step "6/7" "UPX Compression"

    if (Test-Path $UPXExe) {
        $totalSaved = 0

        $compressTargets = @(
            ,@("flutter_windows.dll", "Flutter Engine")
            ,@("chrono_tide.exe", "Main App")
            ,@("desktop_drop_plugin.dll", "Drop Plugin")
            ,@("screen_retriever_windows_plugin.dll", "Screen Plugin")
            ,@("system_tray_plugin.dll", "Tray Plugin")
            ,@("window_manager_plugin.dll", "Window Plugin")
        )

        foreach ($target in $compressTargets) {
            $filePath = Join-Path $ReleaseDir $target[0]
            if (Test-Path $filePath) {
                $beforeSize = (Get-Item $filePath).Length
                & $UPXExe --best -q -f $filePath 2>&1 | Out-Null
                $afterSize = (Get-Item $filePath).Length
                $saved = $beforeSize - $afterSize
                if ($saved -gt 0) {
                    $totalSaved += $saved
                    Write-Info "$($target[1]): $(Format-Size $beforeSize) -> $(Format-Size $afterSize) (saved $(Format-Size $saved))"
                } else {
                    Write-Info "$($target[1]): no compression gain"
                }
            }
        }

        foreach ($toolName in @("7z.exe", "bz.exe", "UnRAR.exe")) {
            $toolPath = Join-Path $toolsDestDir $toolName
            if (Test-Path $toolPath) {
                $beforeSize = (Get-Item $toolPath).Length
                & $UPXExe --best -q -f $toolPath 2>&1 | Out-Null
                $afterSize = (Get-Item $toolPath).Length
                $saved = $beforeSize - $afterSize
                if ($saved -gt 0) {
                    $totalSaved += $saved
                    Write-Info "${toolName}: $(Format-Size $beforeSize) -> $(Format-Size $afterSize)"
                }
            }
        }

        $magpieExe = Join-Path $ReleaseDir "runtime\magpie\Magpie.exe"
        if (Test-Path $magpieExe) {
            $beforeSize = (Get-Item $magpieExe).Length
            & $UPXExe --best -q -f $magpieExe 2>&1 | Out-Null
            $afterSize = (Get-Item $magpieExe).Length
            $saved = $beforeSize - $afterSize
            if ($saved -gt 0) {
                $totalSaved += $saved
                Write-Info "Magpie.exe: $(Format-Size $beforeSize) -> $(Format-Size $afterSize)"
            }
        }

        Write-Info "openlist.exe skipped (Go binary, UPX may break it)"
        Write-Done "UPX done, total saved: $(Format-Size $totalSaved)"
    } else {
        Write-Warn "UPX not found: $UPXExe"
    }
} else {
    Write-Step "6/7" "UPX Compression (skipped)"
}

# ======================== Step 7: Verify & Report ========================
Write-Step "7/7" "Verification & Report"

$checks = @(
    ,@("chrono_tide.exe", "$ReleaseDir\chrono_tide.exe")
    ,@("flutter_windows.dll", "$ReleaseDir\flutter_windows.dll")
    ,@("data/app.so", "$ReleaseDir\data\app.so")
    # openlist.exe 校验已移除（2026-10-02 半移植化）：Release 中不应存在，
    # 存在反而说明 5.1 残留清理失败
    ,@("7z.exe", "$ReleaseDir\runtime\tools\7z.exe")
    ,@("data/", "$ReleaseDir\data")
    ,@("downloads/", "$ReleaseDir\downloads")
    ,@("Games/", "$ReleaseDir\Games")
    ,@("logs/", "$ReleaseDir\logs")
)

$allPassed = $true
foreach ($check in $checks) {
    if (Test-Path $check[1]) {
        Write-Done $check[0]
    } else {
        Write-Fail "$($check[0]) (MISSING!)"
        $allPassed = $false
    }
}

# --- rar_lz4 工具：随包携带的是 asset 副本，runtime\tools 由运行时按需释放 ---
# ★ 2026-11-10 修正判据：[优化-体积] 起 bz.exe/UnRAR.exe/ark.x64.dll 不再预置到
#   runtime\tools\，而是打进 data\flutter_assets\assets\tools\（pubspec.yaml assets），
#   由 rar_lz4_unzip_service.dart:_ensureToolsExist 首次解压 .rar.lz4 时释放。
#   旧判据查 runtime\tools\ 必然报 MISSING —— 那是"还没跑过解压"，不是"打包缺文件"。
#   正确判据：asset 副本必须随包在（否则运行时无处可释放）。
$assetToolsDir = Join-Path $ReleaseDir "data\flutter_assets\assets\tools"
$releasedDir   = Join-Path $ReleaseDir "runtime\tools"
foreach ($toolName in @("bz.exe", "UnRAR.exe", "ark.x64.dll")) {
    if (-not (Test-Path (Join-Path $assetToolsDir $toolName))) {
        Write-Fail "$toolName (asset 缺失! 应在 data\flutter_assets\assets\tools)"
        $allPassed = $false
    } elseif (Test-Path (Join-Path $releasedDir $toolName)) {
        Write-Done "$toolName (asset + 已释放)"
    } else {
        Write-Done "$toolName (asset 随包，首次解压时自动释放)"
    }
}

$TotalStopwatch.Stop()

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Build Report" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

$releaseTotalSize = Get-DirSize $ReleaseDir
Write-Host "  Version:   $Version"
Write-Host "  Time:      $($TotalStopwatch.Elapsed.ToString('mm\:ss'))"
Write-Host "  Release:   $(Format-Size $releaseTotalSize)"
Write-Host "  Path:      $ReleaseDir"
Write-Host ""

# ======================== Inno Setup ========================
if ((-not $SkipInstaller) -and $allPassed -and $ISCCExe) {
    Write-Host ""
    Write-Step "Extra" "Inno Setup Installer"

    $issPath = Join-Path $ProjectRoot "ChronoTide_Setup.iss"
    if (Test-Path $issPath) {
        $installerSw = [System.Diagnostics.Stopwatch]::StartNew()

        # ★ BOM 自愈：检测并修复双重 BOM（EF BB BF EF BB BF）。
        # 某些编辑器（VS Code/IDE）保存时会自动追加 BOM，导致 .iss
        # 首行 #define 前出现无效字符，ISCC 报 "Undeclared identifier"。
        # 修复：跳过双重 BOM 的前 6 字节，只保留单个 BOM 重写文件。
        try {
            $issBytes = [System.IO.File]::ReadAllBytes($issPath)
            if ($issBytes.Length -ge 6 -and
                $issBytes[0] -eq 0xEF -and $issBytes[1] -eq 0xBB -and $issBytes[2] -eq 0xBF -and
                $issBytes[3] -eq 0xEF -and $issBytes[4] -eq 0xBB -and $issBytes[5] -eq 0xBF) {
                Write-Warn "ISS file has double BOM, auto-fixing..."
                $fixedBytes = ([byte[]](0xEF, 0xBB, 0xBF)) + $issBytes[6..($issBytes.Length - 1)]
                [System.IO.File]::WriteAllBytes($issPath, $fixedBytes)
                Write-Done "Double BOM removed (saved $($issBytes.Length - $fixedBytes.Length) bytes)"
            }
        } catch {
            Write-Warn "BOM check failed (non-blocking): $($_.Exception.Message)"
        }

        if (-not (Test-Path $OutputDir)) {
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        }

        $issTempDir = Join-Path $WorkDir "inno_temp"
        if (-not (Test-Path $issTempDir)) {
            New-Item -ItemType Directory -Path $issTempDir -Force | Out-Null
        }

        Write-Info "ISCC: $ISCCExe"
        Write-Info "Output: $OutputDir"

        # Redirect TEMP only during ISCC compilation
        $env:TEMP = $issTempDir
        $env:TMP = $issTempDir

        Push-Location $ProjectRoot
        # 修复：PowerShell 5.1 会将 /O="path" 在 = 处拆分为 /O 和 =path 两个参数
        # ISCC 也不支持 /O path（空格分隔会被当作两个脚本文件名）
        # 正确方式：/O 直接拼接路径（/Opath），无 = 无空格
        $outputArg = "/O" + $OutputDir
        & $ISCCExe $outputArg $issPath 2>&1 | ForEach-Object { Write-Host "  $_" }
        $issResult = $LASTEXITCODE
        Pop-Location

        # Restore TEMP
        $env:TEMP = $OrigTemp
        $env:TMP = $OrigTmp

        $installerSw.Stop()

        if ($issResult -eq 0) {
            $installerFile = Get-ChildItem $OutputDir -Filter "ChronoTide_Installer_v*.exe" -ErrorAction SilentlyContinue |
                             Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($installerFile) {
                Write-Done "Installer created"
                Write-Info "File: $($installerFile.FullName)"
                Write-Info "Size: $(Format-Size $installerFile.Length)"
                Write-Info "Time: $($installerSw.Elapsed.ToString('mm\:ss'))"
            }
        } else {
            Write-Warn "ISCC exit code: $issResult"
        }

        if (Test-Path $issTempDir) {
            Remove-Item $issTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Warn "ISS not found: $issPath"
    }
} elseif (-not $ISCCExe) {
    Write-Info "ISCC not found, installer skipped"
}

# ======================== Cleanup ========================
if (Test-Path $TempDir) {
    Get-ChildItem $TempDir -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# ======================== Final Result ========================
Write-Host ""
if ($allPassed) {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  BUILD SUCCESS!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Time:    $($TotalStopwatch.Elapsed.ToString('mm\:ss'))"
    Write-Host "  Release: $(Format-Size $releaseTotalSize)"
    Write-Host "  Path:    $ReleaseDir"
    if (Test-Path $OutputDir) {
        $installerFile = Get-ChildItem $OutputDir -Filter "ChronoTide_Installer_v*.exe" -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($installerFile) {
            Write-Host "  Installer: $(Format-Size $installerFile.Length)"
            Write-Host "  Installer Path: $($installerFile.FullName)"
        }
    }
} else {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  BUILD FAILED - missing files, check above" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    $ExitCode = 1
}

} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  SCRIPT ERROR!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Line:  $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    $ExitCode = 1
}

# 防止窗口一闪而过；无人值守（AI / 定时任务）时用 CT_NO_PAUSE=1 跳过
if ($env:CT_NO_PAUSE -ne '1') {
    Write-Host ""
    Write-Host "按回车键关闭窗口 ..." -ForegroundColor Gray
    [void](Read-Host)
}

# 最后一行必须是退出码，否则调用方永远看到 0
exit $ExitCode
