# ============================================================
#  项目开发面板 · 内核
#  ------------------------------------------------------------
#  这份文件在每个项目的 Dev\scripts\ 下各存一份，互不依赖。
#  换句话说：把整个项目文件夹搬走，面板照样能用。
#
#  由 run.ps1 点源加载，不单独运行。
#  PowerShell 5.1 兼容。
# ============================================================

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# ------------------------------------------------------------
#  路径推导
#    Dev\scripts\_core.ps1  ->  Dev  ->  项目根
# ------------------------------------------------------------
$script:DevDir     = Split-Path -Parent $PSScriptRoot
$script:ProjectDir = Split-Path -Parent $script:DevDir
$script:LogDir     = Join-Path $script:DevDir 'logs'
$script:DistDir    = Join-Path $script:DevDir 'dist'

foreach ($d in @($script:LogDir, $script:DistDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
$script:LogFile = Join-Path $script:LogDir ((Get-Date -Format 'yyyy-MM-dd') + '.log')

# ------------------------------------------------------------
#  工作区根：从项目目录往上找「含 env\toolchains 的目录」
#  找不到就返回 $null —— 此时面板退化为只用系统 PATH，仍可运行
# ------------------------------------------------------------
function Find-CtWorkspace {
    $dir = $script:ProjectDir
    for ($i = 0; $i -lt 6; $i++) {
        if (-not $dir) { break }
        if (Test-Path (Join-Path $dir 'env\toolchains')) { return $dir }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}
$script:WsRoot = Find-CtWorkspace

$script:FlutterExe  = $null
$script:FlutterRoot = $null
$script:FlutterVerRaw = ''

# 本次运行的状态（供 run.ps1 判断退出码、供产物清单判断时间窗）
$script:CtLastOk   = $false
$script:CtRunStart = $null

# ------------------------------------------------------------
#  日志
# ------------------------------------------------------------
$script:LogWriter = $null

function Start-CtLog {
    if ($script:LogWriter) { return }
    $script:LogWriter = New-Object System.IO.StreamWriter($script:LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
    $script:LogWriter.AutoFlush = $true
    Write-CtLog ('----- 开始 (PID ' + $PID + ') -----')
}

function Write-CtLog {
    param([string]$Message)
    if (-not $script:LogWriter) { Start-CtLog }
    $script:LogWriter.WriteLine(("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message))
}

function Stop-CtLog {
    if ($script:LogWriter) {
        Write-CtLog '----- 结束 -----'
        $script:LogWriter.Close()
        $script:LogWriter = $null
    }
}

# ------------------------------------------------------------
#  屏幕输出
# ------------------------------------------------------------
function Write-CtTitle {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-CtLog ('=== ' + $Text + ' ===')
}

function Write-CtStep { param([string]$Text) Write-Host ''; Write-Host ('>>> ' + $Text) -ForegroundColor Yellow; Write-CtLog ('>>> ' + $Text) }
function Write-CtOk   { param([string]$Text) Write-Host ('  [OK]  ' + $Text) -ForegroundColor Green;      Write-CtLog ('[OK] ' + $Text) }
function Write-CtBad  { param([string]$Text) Write-Host ('  [X]   ' + $Text) -ForegroundColor Red;        Write-CtLog ('[FAIL] ' + $Text) }
function Write-CtWarn { param([string]$Text) Write-Host ('  [!]   ' + $Text) -ForegroundColor DarkYellow; Write-CtLog ('[WARN] ' + $Text) }
function Write-CtInfo { param([string]$Text) Write-Host ('        ' + $Text) -ForegroundColor Gray;       Write-CtLog ('      ' + $Text) }

# ------------------------------------------------------------
#  交互
# ------------------------------------------------------------
function Pause-CtExit {
    param([string]$Message = '按回车键关闭窗口 ...')
    if ($env:CT_NO_PAUSE -eq '1') { return }
    Write-Host ''
    Write-Host $Message -ForegroundColor DarkGray
    [void](Read-Host)
}

function Read-CtYesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = '[Y/n]'
    if (-not $Default) { $suffix = '[y/N]' }
    $ans = Read-Host ($Prompt + ' ' + $suffix)
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return ($ans -match '^[yY]')
}

function Read-CtMenu {
    param([string[]]$Options, [int]$Default = 1)
    Write-Host ''
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ('  ' + ($i + 1) + ') ' + $Options[$i]) -ForegroundColor White
    }
    Write-Host '  0) 取消' -ForegroundColor DarkGray
    while ($true) {
        $ans = Read-Host ('请选择 [默认 ' + $Default + ']')
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n)) {
            if ($n -eq 0) { return 0 }
            if ($n -ge 1 -and $n -le $Options.Count) { return $n }
        }
        Write-Host '  输入无效，请重新输入。' -ForegroundColor Red
    }
}

# ------------------------------------------------------------
#  配置读取
# ------------------------------------------------------------
function Get-CtCfg {
    param([string]$Key, $Default = $null)
    if ($script:CTConfig -and $script:CTConfig.ContainsKey($Key)) { return $script:CTConfig[$Key] }
    return $Default
}

function Get-CtCfgArray {
    param([string]$Key)
    $v = Get-CtCfg $Key @()
    if ($null -eq $v) { return @() }
    return @($v)
}

# ------------------------------------------------------------
#  环境注入（全部锁在 D 盘工作区内）
# ------------------------------------------------------------
function Initialize-CtEnv {
    # Flutter
    $candidates = @()
    if ($script:WsRoot) {
        $candidates += (Join-Path $script:WsRoot 'env\toolchains\flutter\bin\flutter.bat')
    }
    $candidates += (Join-Path $script:ProjectDir 'flutter\bin\flutter.bat')
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $script:FlutterExe  = $c
            $script:FlutterRoot = Split-Path -Parent (Split-Path -Parent $c)
            $env:FLUTTER_ROOT   = $script:FlutterRoot
            $bin = Split-Path -Parent $c
            if ($env:PATH -notlike ('*' + $bin + '*')) { $env:PATH = $bin + ';' + $env:PATH }
            break
        }
    }
    if (-not $script:FlutterExe) {
        $cmd = Get-Command flutter -ErrorAction SilentlyContinue
        if ($cmd) {
            $script:FlutterExe = $cmd.Source
            $script:FlutterRoot = Split-Path -Parent (Split-Path -Parent $cmd.Source)
        }
    }

    # 只有找到工作区，才把缓存/临时目录重定向到 D 盘（避免污染 C 盘）
    if ($script:WsRoot) {
        $env:PUB_CACHE = Join-Path $script:WsRoot 'env\cache\pub'
        $tempDir       = Join-Path $script:WsRoot 'env\cache\tmp'
        foreach ($p in @($env:PUB_CACHE, $tempDir)) {
            if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        }
        $env:TEMP = $tempDir
        $env:TMP  = $tempDir

        # git：无条件优先用工作区自带的，不依赖系统有没有装 git。
        # Flutter 启动时要调 git 读版本号，找不到就直接崩溃
        # （ProcessException: Failed to find "git" in the search path）——
        # 本机没有装系统级 Git，SDK 自带的 bin\mingit 又是不完整的，只能靠这里注入。
        $gitExe = Join-Path $script:WsRoot 'env\toolchains\git\cmd\git.exe'
        if (Test-Path $gitExe) {
            $gitDir = Split-Path -Parent $gitExe
            if ($env:PATH -notlike ('*' + $gitDir + '*')) { $env:PATH = $gitDir + ';' + $env:PATH }
        }
        foreach ($t in @('innosetup', '7zip')) {
            $p = Join-Path $script:WsRoot ('env\toolchains\' + $t)
            if ((Test-Path $p) -and ($env:PATH -notlike ('*' + $p + '*'))) { $env:PATH = $p + ';' + $env:PATH }
        }
        $pyDir = Join-Path $script:WsRoot 'env\python'
        if (Test-Path (Join-Path $pyDir 'python.exe')) { $env:PATH = $pyDir + ';' + $env:PATH }
    }
}

# ------------------------------------------------------------
#  执行外部命令：实时输出 + 写日志
# ------------------------------------------------------------
function Invoke-Ct {
    param(
        [string]   $Exe,
        [string[]] $CmdArgs,
        [string]   $WorkDir = $script:ProjectDir,
        [string]   $Label   = '',
        [switch]   $AllowFail
    )
    if ($Label) { Write-CtStep $Label }
    Write-CtLog ('RUN: ' + $Exe + ' ' + ($CmdArgs -join ' ') + '   [cwd=' + $WorkDir + ']')

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    Push-Location $WorkDir
    $code = 1
    try {
        & $Exe @CmdArgs 2>&1 | ForEach-Object {
            $line = $_.ToString()
            Write-Host ('  ' + $line)
            Write-CtLog $line
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        Write-CtLog ('EXCEPTION: ' + $_.Exception.Message)
        Write-Host ('  [X]   ' + $_.Exception.Message) -ForegroundColor Red
        $code = 1
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevEap
    }
    Write-CtLog ('EXIT CODE: ' + $code)

    if ($code -ne 0 -and -not $AllowFail) {
        throw ('命令执行失败（退出码 ' + $code + '）：' + $Exe + ' ' + ($CmdArgs -join ' '))
    }
    return $code
}

# ------------------------------------------------------------
#  环境自检
# ------------------------------------------------------------
function Test-CtFlutterEnv {
    if (-not $script:FlutterExe) {
        Write-CtBad '找不到 Flutter SDK'
        if ($script:WsRoot) { Write-CtInfo ('应在：' + (Join-Path $script:WsRoot 'env\toolchains\flutter')) }
        Write-CtInfo '修复：在项目根双击 Dev\环境体检.bat 看详细结论'
        return $false
    }
    Write-CtOk ('Flutter: ' + $script:FlutterExe)
    $ver = Get-CtFlutterVersion
    if (-not $ver) {
        Write-CtBad 'Flutter 无法启动'
        if ($script:FlutterVerRaw -match 'Failed to find\s+"?git') {
            # 本机没装系统 Git 时的高频坑：Flutter 读版本号必须调 git，找不到就整体崩
            Write-CtInfo '原因：Flutter 启动时要调 git，而 PATH 里找不到 git'
            if ($script:WsRoot) {
                Write-CtInfo ('应有：' + (Join-Path $script:WsRoot 'env\toolchains\git\cmd\git.exe'))
            }
            Write-CtInfo '修复：确认上面那个 git.exe 还在；面板运行时会自动把它加进 PATH'
        } else {
            Write-CtInfo '常见原因：安全软件拦截 / 磁盘空间不足 / 同时开了两个打包窗口'
            Write-CtInfo '手动验证：在命令提示符里执行下面这条，看能不能输出版本号'
            Write-CtInfo ('  "' + $script:FlutterExe + '" --version')
        }
        return $false
    }
    Write-CtOk ('版本: ' + $ver)
    return $true
}

# 取 Flutter 版本号
# 注意：不能用 (& flutter.bat --version | Select-Object -First 1)
# —— Select-Object 拿到一行就关管道，会让 .bat 启动器被提前掐断，
#    而 flutter.bat 开头常有一行空输出/提示行，于是永远判成「启动失败」
function Get-CtFlutterVersion {
    if (-not $script:FlutterExe) { return $null }
    $lines = @()
    $script:FlutterVerRaw = ''
    try {
        $lines = @(& $script:FlutterExe --version 2>&1)
    } catch {
        # native 命令写 stderr 时这里只会拿到 RemoteException 空壳，
        # 原始文本在 ErrorRecord 里，用 Out-String 展开，便于后面落日志排查
        $script:FlutterVerRaw = ($_ | Out-String)
        return $null
    }
    $script:FlutterVerRaw = (($lines | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
        else { $_.ToString() }
    }) -join "`n")
    if ($lines.Count -eq 0) { return $null }
    foreach ($l in $lines) {
        $s = $l.ToString().Trim()
        if ($s -match '^Flutter\s+\d') { return $s }
    }
    foreach ($l in $lines) {
        $s = $l.ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($s)) { return $s }
    }
    return $null
}

function Test-CtGitRepo {
    if (-not (Test-Path (Join-Path $script:ProjectDir '.git'))) {
        Write-CtBad ('这个项目还没有版本控制：' + $script:ProjectDir)
        Write-CtInfo '修复：在项目根执行 git init 后点「保存进度.bat」'
        return $false
    }
    return $true
}

# ------------------------------------------------------------
#  Git
# ------------------------------------------------------------
function Invoke-CtGit {
    param([string[]]$GitArgs, [switch]$AllowFail)
    Write-CtLog ('GIT: git ' + ($GitArgs -join ' '))
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $script:ProjectDir
    $out  = @()
    $code = 1
    try {
        $out  = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $out  = @($_.Exception.Message)
        $code = 1
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevEap
    }
    foreach ($l in $out) { Write-CtLog ('      ' + $l) }
    if ($code -ne 0 -and -not $AllowFail) {
        throw ('git ' + ($GitArgs -join ' ') + ' 失败：' + ($out -join ' | '))
    }
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

function Get-CtGitChanges {
    $r = Invoke-CtGit -GitArgs @('status', '--porcelain')
    return @($r.Output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim() -ne '' })
}

# ------------------------------------------------------------
#  版本号：Flutter 读 pubspec.yaml，其余读 VERSION 文件
# ------------------------------------------------------------
function Get-CtVersionFile {
    $custom = Get-CtCfg 'VersionFile' ''
    if (-not [string]::IsNullOrWhiteSpace($custom)) { return (Join-Path $script:ProjectDir $custom) }
    $kind = Get-CtCfg 'Kind' 'flutter'
    if ($kind -eq 'flutter') { return (Join-Path $script:ProjectDir 'pubspec.yaml') }
    return (Join-Path $script:ProjectDir 'VERSION')
}

function Get-CtVersion {
    $file = Get-CtVersionFile
    if (-not (Test-Path $file)) { return 'unknown' }
    $name = Split-Path -Leaf $file
    if ($name -eq 'pubspec.yaml') {
        foreach ($line in (Get-Content $file -Encoding UTF8)) {
            if ($line -match '^version:\s*(.+)') { return $Matches[1].Trim() }
        }
        return 'unknown'
    }
    foreach ($line in (Get-Content $file -Encoding UTF8)) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
    }
    return 'unknown'
}

function Set-CtVersion {
    param([string]$NewVersion)
    $file = Get-CtVersionFile
    $name = Split-Path -Leaf $file
    if (-not (Test-Path $file)) {
        if ($name -eq 'pubspec.yaml') { throw '没有找到 pubspec.yaml，无法改版本号' }
        [System.IO.File]::WriteAllText($file, ($NewVersion + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-CtOk ('已创建 VERSION：' + $NewVersion)
        return
    }
    if ($name -eq 'pubspec.yaml') {
        $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        $rx = New-Object System.Text.RegularExpressions.Regex('(?m)^version:\s*([0-9][^\r\n\+]*)(\+[0-9]+)?')
        if (-not $rx.IsMatch($text)) { throw 'pubspec.yaml 里没有 version: 行' }
        $m = $rx.Match($text)
        $build = $m.Groups[2].Value
        $text = $rx.Replace($text, ('version: ' + $NewVersion + $build), 1)
        [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
        Write-CtOk ('版本号 -> ' + $NewVersion + $build)
        return
    }
    [System.IO.File]::WriteAllText($file, ($NewVersion + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-CtOk ('版本号 -> ' + $NewVersion)
}

function Step-CtVersion {
    param([string]$Current, [string]$Level)
    $parts = $Current.Split('-')[0].Split('.')
    $major = [int]$parts[0]
    $minor = 1
    if ($parts.Count -ge 2) { $minor = [int]$parts[1] }
    $patch = 0
    if ($parts.Count -ge 3) { $patch = [int]$parts[2] }
    switch ($Level) {
        'major' { $major++; $minor = 0; $patch = 0 }
        'minor' { $minor++; $patch = 0 }
        'patch' { $patch++ }
    }
    return ('{0}.{1}.{2}' -f $major, $minor, $patch)
}

# ------------------------------------------------------------
#  会话包装
# ------------------------------------------------------------
function Start-CtSession {
    param([string]$Action, [string]$Name)
    $v = Get-CtVersion
    $title = $Name + ' · ' + $Action
    if ($v -ne 'unknown') { $title = $title + '  (v' + $v + ')' }
    Write-CtTitle $title
    Write-CtInfo ('项目: ' + $script:ProjectDir)
    if ($script:WsRoot) { Write-CtInfo ('工作区: ' + $script:WsRoot) }
    Write-CtInfo ('日志: ' + $script:LogFile)
}

function Show-CtError {
    param($ErrorRecord)
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Red
    Write-Host '  出错了' -ForegroundColor Red
    Write-Host ('=' * 62) -ForegroundColor Red
    Write-Host ('  ' + $ErrorRecord.Exception.Message) -ForegroundColor Red
    Write-Host ('  位置: 第 ' + $ErrorRecord.InvocationInfo.ScriptLineNumber + ' 行') -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  完整日志: ' + $script:LogFile) -ForegroundColor Yellow
    Write-CtLog ('ERROR: ' + $ErrorRecord.Exception.Message)
}

function Complete-CtSession {
    Stop-CtLog
}

function Invoke-CtScript {
    param([string]$Action, [string]$Name, [scriptblock]$Body)
    # 记下本次开始时间：产物清单靠它区分「这次生成的」和「以前留下的」
    $script:CtRunStart = Get-Date
    Start-CtSession -Action $Action -Name $Name
    Initialize-CtEnv
    $ok = $false
    try {
        & $Body
        $ok = $true
    } catch {
        Show-CtError $_
    } finally {
        $script:CtLastOk = $ok
        Complete-CtSession
        Write-Host ''
        if ($ok) {
            Write-Host ('  + ' + $Action + ' 完成') -ForegroundColor Green
        } else {
            Write-Host ('  x ' + $Action + ' 失败 —— 把 Dev\logs 里最新的日志发给 AI') -ForegroundColor Red
        }
        Pause-CtExit
    }
    return $ok
}

# ============================================================
#  动作
# ============================================================

# ---------------- 启动开发 ----------------
function Action-Dev {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '启动开发' -Name $name -Body {
        $kind = Get-CtCfg 'Kind' 'flutter'

        if ($kind -eq 'flutter') {
            if (-not (Test-CtFlutterEnv)) { throw 'Flutter 环境不可用' }
            Write-CtStep '编译并启动（首次 1-3 分钟）'
            Write-CtInfo '程序起来后改代码会自动热重载；关掉这个窗口即停止'
            Write-Host ''
            Invoke-Ct -Exe $script:FlutterExe -CmdArgs @('run', '-d', 'windows') -Label 'flutter run'
            return
        }

        if ($kind -eq 'python') {
            $py = Get-CtPython
            if (-not $py) { throw '找不到 Python。装好后放进 env\python\ 或加进 PATH' }
            Write-CtOk ('Python: ' + $py)
            foreach ($dep in (Get-CtCfgArray 'PythonDeps')) {
                Write-CtStep ('检查依赖 ' + $dep)
                $probe = 'import ' + ($dep -replace '[-\.]', '_')
                $prevEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                Push-Location $script:ProjectDir
                & $py -c ($probe) 2>&1 | Out-Null
                $depCode = $LASTEXITCODE
                Pop-Location
                $ErrorActionPreference = $prevEap
                if ($depCode -ne 0) {
                    Write-CtWarn ($dep + ' 没装，正在装（只装到当前 Python）')
                    Invoke-Ct -Exe $py -CmdArgs @('-m', 'pip', 'install', $dep, '--quiet') -Label ('pip install ' + $dep)
                }
            }
            $entry = Get-CtCfg 'Entry' 'main.py'
            Invoke-Ct -Exe $py -CmdArgs @($entry) -Label ('python ' + $entry)
            return
        }

        if ($kind -eq 'static') {
            Invoke-StaticPreview
            return
        }

        Write-CtWarn ('这个项目是 ' + $kind + ' 类型，没有「启动开发」')
        $cmd = Get-CtCfg 'DevCommand' ''
        if ([string]::IsNullOrWhiteSpace($cmd)) { return }
        Invoke-Ct -Exe 'cmd' -CmdArgs @('/c', $cmd) -Label '运行项目自带的启动命令'
    }
}

function Get-CtPython {
    $candidates = @()
    if ($script:WsRoot) { $candidates += (Join-Path $script:WsRoot 'env\python\python.exe') }
    $candidates += @('python', 'python3')
    foreach ($c in $candidates) {
        $p = (Get-Command $c -ErrorAction SilentlyContinue).Source
        if ($p) { return $p }
    }
    return $null
}

function Invoke-StaticPreview {
    $site = Get-CtCfg 'SiteDir' '.'
    $siteDir = Join-Path $script:ProjectDir $site
    if (-not (Test-Path (Join-Path $siteDir 'index.html'))) { throw ('找不到站点入口：' + $siteDir) }

    Write-CtStep '启动本地预览服务'
    $py = Get-CtPython
    if (-not $py) {
        Write-CtWarn '没装 Python，改为直接打开文件（部分交互可能受限）'
        Start-Process (Join-Path $siteDir 'index.html')
        return
    }
    $port = Get-CtCfg 'PreviewPort' 8080
    Write-CtInfo ('地址：http://localhost:' + $port)
    Start-Process -FilePath $py -ArgumentList @('-m', 'http.server', $port) `
        -WorkingDirectory $siteDir -WindowStyle Minimized
    Start-Sleep -Seconds 2
    Start-Process ('http://localhost:' + $port)
    Write-CtOk '浏览器已打开'
}

# ---------------- 一键检查 ----------------
function Action-Check {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '一键检查' -Name $name -Body {
        $kind = Get-CtCfg 'Kind' 'flutter'

        if ($kind -ne 'flutter') {
            Write-CtWarn ('这个项目是 ' + $kind + ' 类型，没有静态检查')
            Write-CtInfo '建议直接点「一键打包」，用编译结果做检查'
            return
        }

        if (-not (Test-CtFlutterEnv)) { throw 'Flutter 环境不可用' }

        Write-CtStep '静态检查（只读，不改文件）'
        Write-Host ''

        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Push-Location $script:ProjectDir
        $out = & $script:FlutterExe analyze lib 2>&1
        Pop-Location
        $ErrorActionPreference = $prevEap

        $errors = @()
        $warns  = @()
        foreach ($l in $out) {
            $s = $l.ToString()
            Write-CtLog $s
            if ($s -match '^\s*error\s+')   { $errors += $s }
            elseif ($s -match '^\s*warning\s+') { $warns += $s }
        }

        Write-Host ''
        Write-CtInfo ('错误 error  : ' + $errors.Count)
        Write-CtInfo ('警告 warning: ' + $warns.Count)

        if ($errors.Count -gt 0) {
            Write-Host ''
            Write-CtBad ('有 ' + $errors.Count + ' 个错误，必须修好才能打包：')
            $show = $errors
            if ($show.Count -gt 25) { $show = $show[0..24] }
            foreach ($e in $show) { Write-Host ('  ' + $e) -ForegroundColor Red }
            if ($errors.Count -gt 25) { Write-CtInfo ('…… 还有 ' + ($errors.Count - 25) + ' 条，见日志') }
            throw ('静态检查未通过：' + $errors.Count + ' 个 error')
        }
        Write-CtOk '没有错误'
    }
}

# ---------------- 一键测试 ----------------
function Action-Test {
    $name = Get-CtCfg 'Name' 'Project'
    $known = Get-CtCfgArray 'KnownFailingTests'
    Invoke-CtScript -Action '一键测试' -Name $name -Body {
        $kind = Get-CtCfg 'Kind' 'flutter'
        if ($kind -ne 'flutter') {
            Write-CtWarn '这个项目不是 Flutter 项目，没有自动化测试'
            return
        }
        if (-not (Test-CtFlutterEnv)) { throw 'Flutter 环境不可用' }
        if (-not (Test-Path (Join-Path $script:ProjectDir 'test'))) {
            Write-CtWarn '这个项目没有 test 目录，跳过'
            return
        }

        Write-CtStep '运行全部测试（可能要几分钟）'
        Write-Host ''

        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        Push-Location $script:ProjectDir
        $out = & $script:FlutterExe test 2>&1
        $code = $LASTEXITCODE
        Pop-Location
        $ErrorActionPreference = $prevEap

        $failed = @()
        foreach ($l in $out) {
            $s = $l.ToString()
            Write-CtLog $s
            if ($s -match 'Some tests failed') { Write-CtBad $s.Trim() }
            if ($s -match '\[E\]') { $failed += $s }
        }

        if ($code -eq 0) {
            Write-CtOk '全部测试通过'
            return
        }

        $newFailures = @()
        foreach ($f in $failed) {
            $isKnown = $false
            foreach ($k in $known) { if ($f -match [regex]::Escape($k)) { $isKnown = $true } }
            if (-not $isKnown) { $newFailures += $f }
        }

        Write-CtWarn '有测试没通过'
        if ($known.Count -gt 0) { Write-CtInfo ('已知会失败：' + ($known -join '、')) }
        if ($newFailures.Count -gt 0) {
            Write-CtBad ('新增 ' + $newFailures.Count + ' 个失败：')
            foreach ($f in $newFailures) { Write-Host ('  ' + $f) -ForegroundColor Red }
            throw ('测试未通过：' + $newFailures.Count + ' 个新失败')
        }
        Write-CtInfo '只命中已知失败，不算新问题'
    }
}

# ---------------- 保存进度 ----------------
function Action-Save {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '保存进度' -Name $name -Body {
        if (-not (Test-CtGitRepo)) { throw '这不是一个 git 仓库' }

        Write-CtStep '看看改了什么'
        $changes = Get-CtGitChanges
        if ($changes.Count -eq 0) { Write-CtOk '没有改动，不用保存'; return }

        Write-CtInfo ('共 ' + $changes.Count + ' 处改动：')
        $show = $changes
        if ($show.Count -gt 30) { $show = $show[0..29] }
        foreach ($c in $show) { Write-Host ('  ' + $c) -ForegroundColor DarkGray }
        if ($changes.Count -gt 30) { Write-CtInfo ('…… 还有 ' + ($changes.Count - 30) + ' 处') }

        Write-Host ''
        Write-Host '  用一句话说明这次改了什么（直接回车 = 自动写）' -ForegroundColor Yellow
        $msg = Read-Host '  说明'
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = '保存进度 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

        Write-CtStep '提交'
        Invoke-CtGit -GitArgs @('add', '-A') | Out-Null
        Invoke-CtGit -GitArgs @('commit', '-m', $msg) | Out-Null
        Write-CtOk ('已保存：' + $msg)

        $head = Invoke-CtGit -GitArgs @('log', '-1', '--oneline')
        if ($head.Output.Count -gt 0) { Write-CtInfo ('当前版本：' + $head.Output[0]) }

        Write-Host ''
        if (Read-CtYesNo '顺便打一个备份标签？（以后能一键回到这个点）' $false) {
            $tag = 'backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Invoke-CtGit -GitArgs @('tag', '-a', $tag, '-m', ('备份：' + $msg)) | Out-Null
            Write-CtOk ('已打标签：' + $tag)
        }
    }
}

# ---------------- 编译单个目标（C++ 等） ----------------
function Action-BuildTarget {
    param([string]$Target, [string]$ActionLabel)
    $name = Get-CtCfg 'Name' 'Project'
    $targets = Get-CtCfg 'Targets' @{}
    if (-not $targets.ContainsKey($Target)) { Write-CtBad ('没有定义编译目标：' + $Target); return }
    $bat = $targets[$Target]

    Invoke-CtScript -Action $ActionLabel -Name $name -Body {
        $batPath = Join-Path $script:ProjectDir $bat
        if (-not (Test-Path $batPath)) { throw ('找不到编译脚本：' + $batPath) }

        if (Get-CtCfg 'NeedVS' $false) {
            $vs = Find-CtVisualStudio
            if (-not $vs) { Write-CtWarn '没检测到 Visual Studio，编译可能失败' }
            else { Write-CtInfo ('VS: ' + $vs) }
        }

        Write-CtStep $ActionLabel
        Write-CtInfo '编译需要 1-3 分钟'
        Write-Host ''
        $env:SIMPLEFONTHOOK_NO_PAUSE = '1'
        $code = Invoke-Ct -Exe 'cmd' -CmdArgs @('/c', ('"' + $batPath + '"')) `
            -WorkDir $script:ProjectDir -Label $bat -AllowFail
        if ($code -ne 0) { throw ($ActionLabel + ' 失败（退出码 ' + $code + '）') }
        Write-CtOk ($ActionLabel + ' 完成')
        Show-CtNewArtifacts
    }
}

function Find-CtVisualStudio {
    $vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vsWhere)) {
        $vsWhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (-not (Test-Path $vsWhere)) { return $null }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $path = & $vsWhere -latest -products * -requires Microsoft.ComponentMSBuild -property installationPath 2>&1 | Select-Object -First 1
    $ErrorActionPreference = $prevEap
    if ($path) { return $path }
    # 退一步：不要求组件
    $ErrorActionPreference = 'Continue'
    $path = & $vsWhere -latest -products * -property installationPath 2>&1 | Select-Object -First 1
    $ErrorActionPreference = $prevEap
    return $path
}

function Show-CtNewArtifacts {
    Write-CtStep '产物清单'
    # 只列这次跑出来的文件：旧包留在 dist 里会让人误以为「打了但没生效」
    $since = $script:CtRunStart
    if (-not $since) { $since = (Get-Date).AddMinutes(-30) }
    $since = $since.AddSeconds(-5)

    $scanDirs = @($script:DistDir)
    foreach ($extra in (Get-CtCfgArray 'ArtifactDirs')) {
        $scanDirs += (Join-Path $script:ProjectDir $extra)
    }

    $seen  = @{}
    $found = @()
    foreach ($d in $scanDirs) {
        if (-not (Test-Path $d)) { continue }
        $key = (Resolve-Path $d).Path.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $files = Get-ChildItem $d -File -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -ge $since } |
                 Sort-Object LastWriteTime -Descending
        foreach ($f in $files) { $found += $f }
    }

    if ($found.Count -eq 0) {
        Write-CtWarn '这次没有生成新文件 —— 上面的输出里应该已经有失败信息'
        return
    }
    foreach ($f in $found) {
        Write-CtInfo ($f.FullName.Replace($script:ProjectDir + '\', '') + '   ' +
                      [math]::Round($f.Length / 1MB, 2) + ' MB   ' +
                      $f.LastWriteTime.ToString('HH:mm:ss'))
    }
}

# ---------------- 一键打包 ----------------
# ModeIndex 由入口决定（build / build2 / build3），不弹菜单：
# 双击就该直接开跑，跟以前一样
function Action-Build {
    param([int]$ModeIndex = 1)
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '一键打包' -Name $name -Body {
        $kind   = Get-CtCfg 'Kind' 'flutter'
        $custom = Get-CtCfg 'BuildScript' ''

        if (-not [string]::IsNullOrWhiteSpace($custom)) {
            $scriptPath = Join-Path $script:ProjectDir $custom
            if (-not (Test-Path $scriptPath)) { throw ('找不到打包脚本：' + $scriptPath) }

            $extra = Get-CtCfgArray 'BuildArgs'
            $modes = Get-CtCfg 'BuildModes' @()
            if ($modes -and $modes.Count -gt 0) {
                if ($ModeIndex -lt 1 -or $ModeIndex -gt $modes.Count) { $ModeIndex = 1 }
                $extra = @($modes[$ModeIndex - 1].Args)
                Write-CtInfo ('方式：' + $modes[$ModeIndex - 1].Label)
            }
            else {
                $cleanArgs = Get-CtCfgArray 'CleanArgs'
                if ($ModeIndex -eq 2 -and $cleanArgs.Count -gt 0) {
                    $extra = $cleanArgs
                    Write-CtInfo '方式：全量重来'
                }
            }

            Write-CtStep '开始打包'
            Write-CtInfo '可能需要几分钟，中间会刷很多行，属正常'
            Write-Host ''

            # CT_NO_PAUSE 只给子脚本用：用完必须还原，
            # 否则面板自己的 Pause-CtExit 也会被跳过 —— 双击后窗口一闪就没了
            # CT_ALLOW_PROMPT：让人工双击时子脚本仍会征求确认（比如关掉正在运行的进程），
            # 不被「无人值守」当成默认同意
            $ext = [System.IO.Path]::GetExtension($scriptPath).ToLower()
            $humanMode      = ($env:CT_NO_PAUSE -ne '1')
            $prevNoPause    = $env:CT_NO_PAUSE
            $prevAllowPrompt = $env:CT_ALLOW_PROMPT
            $env:CT_NO_PAUSE = '1'
            if ($humanMode) { $env:CT_ALLOW_PROMPT = '1' }
            try {
                if ($ext -eq '.ps1') {
                    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $extra
                    $code = Invoke-Ct -Exe 'powershell' -CmdArgs $allArgs -WorkDir $script:ProjectDir -Label '调用项目自带打包脚本' -AllowFail
                } else {
                    $allArgs = @('/c', ('"' + $scriptPath + '"')) + $extra
                    $code = Invoke-Ct -Exe 'cmd' -CmdArgs $allArgs -WorkDir $script:ProjectDir -Label '调用项目自带打包脚本' -AllowFail
                }
            } finally {
                $env:CT_NO_PAUSE   = $prevNoPause
                $env:CT_ALLOW_PROMPT = $prevAllowPrompt
            }
            if ($code -ne 0) { throw ('打包失败（退出码 ' + $code + '）') }
            Show-CtNewArtifacts
            return
        }

        if ($kind -eq 'flutter') {
            if (-not (Test-CtFlutterEnv)) { throw 'Flutter 环境不可用' }
            Write-CtStep '编译 Windows 发布版'
            Invoke-Ct -Exe $script:FlutterExe -CmdArgs @('build', 'windows', '--release') -Label 'flutter build'

            Write-CtStep '把产物收进 Dev\dist'
            $releaseDir = Join-Path $script:ProjectDir 'build\windows\x64\runner\Release'
            if (Test-Path $releaseDir) {
                $ver = Get-CtVersion
                $target = Join-Path $script:DistDir ('v' + $ver)
                if (-not (Test-Path $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
                Copy-Item (Join-Path $releaseDir '*') $target -Recurse -Force -ErrorAction SilentlyContinue
                Write-CtOk ('产物已复制到：' + $target)

                # 顺手打个便携 zip，方便直接发给别人（SkipPortableZip 可关）
                if (-not (Get-CtCfg 'SkipPortableZip' $false)) {
                    $leaf = Split-Path -Leaf $script:ProjectDir
                    $zip  = Join-Path $script:DistDir ($leaf + '_v' + $ver + '.zip')
                    if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
                    try {
                        Compress-Archive -Path (Join-Path $target '*') -DestinationPath $zip -Force
                        $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
                        Write-CtOk ('便携版 zip：' + (Split-Path -Leaf $zip) + '   ' + $mb + ' MB')
                    } catch {
                        Write-CtWarn ('打 zip 失败（不影响上面的产物）：' + $_.Exception.Message)
                    }
                }
            } else {
                Write-CtWarn ('没找到构建输出：' + $releaseDir)
            }
            Show-CtNewArtifacts
            return
        }

        if ($kind -eq 'static') {
            $site = Get-CtCfg 'SiteDir' '.'
            $siteDir = Join-Path $script:ProjectDir $site
            if (-not (Test-Path (Join-Path $siteDir 'index.html'))) { throw '找不到站点入口 index.html' }
            Write-CtStep '打包成 zip'
            $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
            $prefix = Get-CtCfg 'PackPrefix' 'site'
            $zip = Join-Path $script:DistDir ($prefix + '-' + $stamp + '.zip')
            if (Test-Path $zip) { Remove-Item $zip -Force }
            Compress-Archive -Path (Join-Path $siteDir '*') -DestinationPath $zip -Force
            $size = [math]::Round((Get-Item $zip).Length / 1MB, 2)
            Write-CtOk ('已生成：' + (Split-Path -Leaf $zip) + '  (' + $size + ' MB)')
            Write-CtInfo ('位置：' + $zip)
            return
        }

        Write-CtWarn ('这个项目是 ' + $kind + ' 类型，还没配置打包方式')
        Write-CtInfo '在 Dev\scripts\_project.ps1 里填 BuildScript 即可'
    }
}

# ---------------- 发布版本 ----------------
function Action-Release {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '发布版本' -Name $name -Body {
        if (-not (Test-CtGitRepo)) { throw '这不是一个 git 仓库' }

        $current = Get-CtVersion
        if ($current -eq 'unknown') { throw ('读不到版本号：' + (Get-CtVersionFile)) }
        Write-CtInfo ('当前版本：v' + $current)

        $changes = Get-CtGitChanges
        if ($changes.Count -gt 0) {
            Write-CtWarn ('还有 ' + $changes.Count + ' 处改动没保存')
            Write-CtInfo '建议先点「保存进度.bat」'
            if (-not (Read-CtYesNo '仍然继续？' $false)) { throw '已取消' }
        }

        $p1 = Step-CtVersion $current 'patch'
        $p2 = Step-CtVersion $current 'minor'
        $p3 = Step-CtVersion $current 'major'

        Write-CtStep '这次是什么级别的更新'
        $choice = Read-CtMenu @(
            ('补丁版 ' + $p1 + '   —— 修 bug、小调整（最常用）'),
            ('次版本 ' + $p2 + '   —— 加了新功能'),
            ('主版本 ' + $p3 + '   —— 大改动，可能不兼容旧数据')
        ) 1
        if ($choice -eq 0) { throw '已取消' }

        $newVersion = $p1
        if ($choice -eq 2) { $newVersion = $p2 }
        if ($choice -eq 3) { $newVersion = $p3 }
        Write-CtInfo ('v' + $current + ' -> v' + $newVersion)

        Write-Host ''
        Write-Host '  写这次更新了什么（一行一条，输入空行结束）' -ForegroundColor Yellow
        $notes = @()
        while ($true) {
            $line = Read-Host '  '
            if ([string]::IsNullOrWhiteSpace($line)) { break }
            $notes += $line
        }
        if ($notes.Count -eq 0) { $notes = @('常规更新') }

        Write-CtStep '改版本号'
        Set-CtVersion -NewVersion $newVersion

        Write-CtStep '写更新日志'
        $changelog = Join-Path $script:ProjectDir 'CHANGELOG.md'
        $date = Get-Date -Format 'yyyy-MM-dd'
        $block = '## [' + $newVersion + '] - ' + $date + "`r`n`r`n"
        foreach ($n in $notes) { $block += '- ' + $n + "`r`n" }
        $block += "`r`n"

        if (Test-Path $changelog) {
            $text = [System.IO.File]::ReadAllText($changelog, [System.Text.Encoding]::UTF8)
            $rx = New-Object System.Text.RegularExpressions.Regex('(?m)^## ')
            if ($rx.IsMatch($text)) {
                $idx = $rx.Match($text).Index
                $text = $text.Substring(0, $idx) + $block + $text.Substring($idx)
            } else {
                $text = $text.TrimEnd() + "`r`n`r`n" + $block
            }
            [System.IO.File]::WriteAllText($changelog, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-CtOk 'CHANGELOG.md 已更新'
        } else {
            [System.IO.File]::WriteAllText($changelog, ('# 更新日志' + "`r`n`r`n" + $block), (New-Object System.Text.UTF8Encoding($false)))
            Write-CtOk 'CHANGELOG.md 已创建'
        }

        Write-CtStep '提交并打标签'
        $verFile = Get-CtVersionFile
        $addTargets = @('CHANGELOG.md')
        if (Test-Path $verFile) { $addTargets += (Split-Path -Leaf $verFile) }
        if (Test-Path (Join-Path $script:ProjectDir 'pubspec.lock')) { $addTargets += 'pubspec.lock' }
        Invoke-CtGit -GitArgs (@('add') + $addTargets) -AllowFail | Out-Null
        Invoke-CtGit -GitArgs @('commit', '-m', ('release: v' + $newVersion)) -AllowFail | Out-Null
        Invoke-CtGit -GitArgs @('tag', '-a', ('v' + $newVersion), '-m', ('版本 v' + $newVersion)) -AllowFail | Out-Null
        Write-CtOk ('已打标签 v' + $newVersion)

        Write-Host ''
        Write-Host ('  v' + $newVersion + ' 已就绪 —— 下一步点「一键打包.bat」') -ForegroundColor Yellow
    }
}

# ---------------- 版本历史 ----------------
function Action-History {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '版本历史' -Name $name -Body {
        if (-not (Test-CtGitRepo)) { throw '这不是一个 git 仓库' }

        Write-CtStep '最近的版本（最新在上）'
        $log = Invoke-CtGit -GitArgs @('log', '--pretty=format:%h|%ad|%s', '--date=format:%m-%d %H:%M', '-20')
        $lines = @($log.Output | ForEach-Object { $_.ToString() } | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { Write-CtWarn '还没有任何提交'; return }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            Write-Host ('  ' + ($i + 1).ToString().PadLeft(2) + ') ' + $lines[$i]) -ForegroundColor White
        }

        Write-CtStep '标签'
        $tags = Invoke-CtGit -GitArgs @('tag', '--list', '--sort=-creatordate') -AllowFail
        $tagList = @($tags.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
        if ($tagList.Count -eq 0) { Write-CtInfo '还没有标签' }
        else {
            $showTags = $tagList
            if ($showTags.Count -gt 12) { $showTags = $showTags[0..11] }
            foreach ($t in $showTags) { Write-Host ('     ' + $t) -ForegroundColor DarkCyan }
        }

        Write-Host ''
        $choice = Read-CtMenu @('查看某一条改了什么', '退回到某个版本（危险）') 1
        if ($choice -eq 0) { return }

        if ($choice -eq 1) {
            $n = Read-Host '  输入编号（1 是最近一条）'
            $idx = 0
            if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $lines.Count) { throw '编号无效' }
            $sha = $lines[$idx - 1].Split('|')[0]
            Write-CtStep ('改动详情：' + $sha)
            $detail = Invoke-CtGit -GitArgs @('show', '--stat', '--pretty=format:%H%n%an%n%ad%n%n%s%n%n%b', $sha)
            foreach ($l in $detail.Output) { Write-Host ('  ' + $l) }
            return
        }

        Write-Host ''
        Write-Host '   回退会丢掉这之后的所有改动' -ForegroundColor Red
        Write-CtInfo '推荐先点「保存进度.bat」，后悔了还能找回来'
        Write-Host ''
        $target = Read-Host '  要退回到哪一条？（hash 或标签名，留空取消）'
        if ([string]::IsNullOrWhiteSpace($target)) { throw '已取消' }
        if (-not (Read-CtYesNo ('确认退回到 ' + $target + ' ？') $false)) { throw '已取消' }

        Write-CtStep '先做安全备份'
        $safeTag = 'before-revert-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Invoke-CtGit -GitArgs @('tag', '-a', $safeTag, '-m', '回退前自动备份') | Out-Null
        Write-CtOk ('已备份为标签：' + $safeTag)

        Write-CtStep ('回退到 ' + $target)
        Invoke-CtGit -GitArgs @('reset', '--hard', $target) | Out-Null
        Write-CtOk '已回退'
        Write-CtInfo ('后悔了执行：git reset --hard ' + $safeTag)
    }
}

# ---------------- 环境体检（本项目视角） ----------------
function Action-Doctor {
    $name = Get-CtCfg 'Name' 'Project'
    Invoke-CtScript -Action '环境体检' -Name $name -Body {
        Write-CtStep '项目'
        Write-CtInfo ('名称: ' + $name)
        Write-CtInfo ('类型: ' + (Get-CtCfg 'Kind' 'flutter'))
        Write-CtInfo ('目录: ' + $script:ProjectDir)
        Write-CtInfo ('版本: ' + (Get-CtVersion))

        Write-CtStep '工作区'
        if ($script:WsRoot) { Write-CtOk ('找到: ' + $script:WsRoot) }
        else { Write-CtWarn '没找到工作区根（不含 env\toolchains）—— 面板仍可用，但依赖系统 PATH' }

        Write-CtStep '工具链'
        if ($script:FlutterExe) {
            $fv = Get-CtFlutterVersion
            if ($fv) {
                Write-CtOk ('Flutter: ' + $fv)
            } elseif ($script:FlutterVerRaw -match 'Failed to find\s+"?git') {
                Write-CtBad 'Flutter 无法启动：找不到 git'
                Write-CtInfo 'Flutter 读版本号必须先调 git，PATH 里没有就会整体崩（不是 Flutter 坏了）'
                if ($script:WsRoot) { Write-CtInfo ('应有：' + (Join-Path $script:WsRoot 'env\toolchains\git\cmd\git.exe')) }
                Write-CtInfo '面板运行时会自动注入这个目录；若仍失败，多半是 PATH 里有异常空段或过长'
            } else {
                Write-CtBad 'Flutter 存在但启动失败'
                Write-CtInfo '最常见原因：Flutter 读版本号要先调 git，PATH 里没有 git 就直接崩'
                if ($script:WsRoot) { Write-CtInfo ('  应有：' + (Join-Path $script:WsRoot 'env\toolchains\git\cmd\git.exe')) }
                Write-CtInfo '其它原因：安全软件拦截 / 磁盘空间不足 / 同时开了两个打包窗口'
                Write-CtInfo ('手动验证：在命令提示符里执行 "' + $script:FlutterExe + '" --version')
                Write-CtLog ('FLUTTER VERSION FAILED >>> ' + $script:FlutterVerRaw)
            }
        } else {
            Write-CtInfo 'Flutter: 未找到（本项目若不是 Flutter 类型则正常）'
        }
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) { Write-CtOk ('Git: ' + $git.Source) } else { Write-CtBad 'Git: 未找到' }
        if ($script:WsRoot) {
            $iscc = Join-Path $script:WsRoot 'env\toolchains\innosetup\ISCC.exe'
            if (Test-Path $iscc) { Write-CtOk 'Inno Setup: 就绪' } else { Write-CtWarn 'Inno Setup: 缺失' }
            $seven = Join-Path $script:WsRoot 'env\toolchains\7zip\7z.exe'
            if (Test-Path $seven) { Write-CtOk '7-Zip: 就绪' } else { Write-CtWarn '7-Zip: 缺失' }
        }

        Write-CtStep '版本控制'
        if (Test-Path (Join-Path $script:ProjectDir '.git')) {
            $cnt = Invoke-CtGit -GitArgs @('rev-list', '--count', 'HEAD') -AllowFail
            Write-CtOk ('Git 仓库正常，提交数 ' + ($cnt.Output -join ''))
            $dirty = (Get-CtGitChanges).Count
            if ($dirty -gt 0) { Write-CtWarn ([string]$dirty + ' 处改动未提交') } else { Write-CtOk '工作区干净' }
        } else {
            Write-CtBad '还没有 git 仓库'
        }

        Write-CtStep 'C 盘污染检查'
        $cPub = Join-Path $env:LOCALAPPDATA 'Pub\Cache'
        if (Test-Path $cPub) { Write-CtWarn ('存在 ' + $cPub + '（旧缓存，可删）') } else { Write-CtOk 'C 盘没有 pub 缓存' }
        Write-CtInfo ('当前 PUB_CACHE: ' + $env:PUB_CACHE)
    }
}

# ============================================================
#  分发
# ============================================================
function Invoke-CtAction {
    param([string]$Action)
    switch ($Action.ToLower()) {
        'dev'       { Action-Dev }
        'check'     { Action-Check }
        'test'      { Action-Test }
        'save'      { Action-Save }
        'build'     { Action-Build -ModeIndex 1 }
        'build2'    { Action-Build -ModeIndex 2 }
        'build3'    { Action-Build -ModeIndex 3 }
        'build32'   { Action-BuildTarget -Target 'x32' -ActionLabel '编译 32 位' }
        'build64'   { Action-BuildTarget -Target 'x64' -ActionLabel '编译 64 位' }
        'buildall'  { Action-BuildTarget -Target 'all' -ActionLabel '编译全部' }
        'pack'      { Action-BuildTarget -Target 'pack' -ActionLabel '打包发布' }
        'release'   { Action-Release }
        'history'   { Action-History }
        'doctor'    { Action-Doctor }
        'preview'   { Action-Dev }
        default     {
            Write-CtBad ('未知动作：' + $Action)
            Write-CtInfo '可用：dev / check / test / save / build / build2 / build3 / build32 / build64 / buildall / pack / release / history / doctor / preview'
            Pause-CtExit
        }
    }
}
