#define AppName "Chrono Tide"
#define AppVer "3.5.0"
#define AppExe "chrono_tide.exe"
#define AppPublisher "Chrono Tide Team"
#define AppURL "https://chrono-tide.com"

[Setup]
; ========== 基础配置 ==========
AppId={{A1B2C3D4-5678-90EF-ABCD-1234567890AB}}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExe}
; [优化-C盘] 默认输出到工作区 out\installers，打包脚本通过 /O 参数再次覆盖
OutputDir=..\..\out\installers
OutputBaseFilename=ChronoTide_Installer_v{#AppVer}
Compression=lzma/ultra
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

; ========== 系统支持门禁（2026-11-14，见 docs/DEV/features/system_support_matrix.md）==========
; flutter_windows.dll 导入 api-ms-win-core-path-l1-1-0.dll（Win8+ PathCch API set），
; Win7 无此 API set 且微软没有官方可再分发包，装完启动必然报缺 DLL。
; 不设 MinVersion 时 Inno Setup 6 默认 6.1sp1，会放行 Win7 SP1 —— 必须显式收紧到 10.0。
MinVersion=10.0
; 主程序及全部插件均为 PE32+。不设时 32 位安装器默认 x86compatible，会放行 32 位 Win10
; （装得上却跑不起来）。x64compatible 放行 x64 与 Win11 ARM64 的 x64 模拟，拦 32 位系统。
ArchitecturesAllowed=x64compatible



; ========== 视觉美化核心 ==========
; 1. 安装包图标（任务栏/标题栏显示）
SetupIconFile=ChronoTide.ico

; 2. 左侧大幅背景图（暖棕复古潮汐风）
; [优化-体积] 2026-10-03 BMP→PNG：原 24bit 无压缩 BMP 15.3MB，PNG 像素级无损后 5.4MB
WizardImageFile=Install_bg.png
; 3. 右上角小图标/Logo
WizardSmallImageFile=Install_icon.png

; 4. 界面简化（跳过多余步骤，保持沉浸感）
; DisableDirPage=no: 始终允许用户选择安装路径（升级时也显示，确保用户可控）
DisableDirPage=no
DisableProgramGroupPage=yes
DisableReadyMemo=yes
DisableFinishedPage=no

; ========== 许可协议与信息页 ==========
; 显示软件介绍页（替代空白欢迎页，增强仪式感）
DisableWelcomePage=no

; ========== 进程关闭策略 ==========
; 不使用 ISS 内置的 CloseApplications（它发送 WM_CLOSE 会被 setPreventClose 拦截）
; 改用 [Code] 段的 PrepareToInstall 函数通过 taskkill /F 强制终止所有进程
CloseApplications=no
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

; ========== Galgame 风格沉浸式文案 ==========
[Messages]
; --- 按钮文字（剧情选项风格） ---
ButtonNext=继续推进(&N)
ButtonBack=回溯操作(&B)
ButtonInstall=开始安装(&I)
ButtonCancel=放弃选项(&C)
ButtonFinish=进入世界线(&F)
ButtonYes=是(&Y)
ButtonNo=否(&N)

; --- 向导标题与品牌标语 ---
BeveledLabel=Chrono Tide — 命运的潮起潮落

; --- 欢迎页文案 ---
WelcomeLabel1=命运的齿轮，开始转动
WelcomeLabel2=欢迎来到 Chrono Tide 的世界。%n%n在这里，你的每一款游戏都将被温柔地收藏与守护。%n%n本软件仅支持 Windows 10 / 11（64 位）；Windows 7 / 8 / 8.1 及 32 位系统无法运行。%n%n点击「继续推进」，开启属于你的时间线。

; --- 选择路径页文案 ---
SelectDirLabel3=选择时间线的锚点 — 安装目录
SelectDirBrowseLabel=安装路径将作为世界线的基点，请谨慎选择。%n%n点击「继续推进」确认路径。

; --- 安装中文案 ---
InstallingLabel=正在构建世界线...请稍候
StatusExtractFiles=正在解压时间碎片...
StatusCreateDirs=正在创建命运节点...
StatusCreateIcons=正在建立传送门...
StatusCreateIniEntries=正在写入世界线参数...
StatusRegisterFiles=正在注册时间线坐标...
StatusRollback=世界线回溯中...
StatusClosingApplications=正在关闭旧时间线的入口...

; --- 安装完成页文案 ---
FinishedHeadingLabel=世界线已变动！安装完成！
FinishedLabel=Chrono Tide 已就绪。%n%n点击「进入世界线」启动软件，开启你的游戏收藏之旅。%n%n愿潮汐与你同在。

; --- 卸载文案 ---
UninstallAppTitle=回溯世界线
UninstallAppFullTitle=回溯世界线 — %1
ConfirmUninstall=确定要回溯世界线吗？%n%n所有游戏数据与设置将被移除。%n%n此操作不可逆转，请三思。
UninstallStatusLabel=世界线正在回溯中...
UninstalledAll=世界线已回溯完毕。%n%n愿我们在下一个时间线重逢。
UninstalledMost=世界线回溯完成，但部分碎片残留。%n%n可手动清理残留文件。
UninstalledAndNeedsRestart=世界线回溯需要重启才能完成。%n%n是否立即重启？

; --- 其他文案 ---
ExitSetupTitle=放弃选项
ExitSetupMessage=安装尚未完成。确定要放弃当前选项吗？%n%n你可以随时重新运行安装向导，继续未完的时间线。
ChangeDiskTitle=需要下一张光盘
SelectDiskLabel2=请插入下一张光盘，然后点击「确定」。%n%n如果文件位于其他位置，请输入正确路径或点击「浏览」。

; ========== 更新安装时清理旧版本文件 ==========
; [InstallDelete] 在 [Files] 安装之前执行，用于清理旧版本残留
;
; ⭐⭐⭐ 以下目录【绝不可】加入删除列表（用户数据保留）：
;    Games/                  - 用户已安装的游戏数据（最核心！）
;    downloads/              - 下载缓存
;    data/                   - 应用数据（除 flutter_assets/app.so/icudtl.dat 外的用户数据）
;    runtime/openlist/data/  - OpenList 配置和数据库
;    logs/                   - 日志文件
;
[InstallDelete]
; 删除根级程序文件（会被新版本替换）
; *.dll 确保旧版多余的插件 DLL 不会残留
Type: files; Name: {app}\chrono_tide.exe
Type: files; Name: {app}\flutter_windows.dll
Type: files; Name: {app}\*.dll

; 删除 Flutter 编译产物（仅程序文件，不删 data/ 下用户自建内容）
Type: filesandordirs; Name: {app}\data\flutter_assets
Type: files; Name: {app}\data\app.so
Type: files; Name: {app}\data\icudtl.dat

; 删除旧版目录结构（V0.8 遗留：_temp_tools/ 和 openlist/ 在根目录）
; 新版已迁移到 runtime/tools/ 和 runtime/openlist/
Type: filesandordirs; Name: {app}\_temp_tools
Type: filesandordirs; Name: {app}\openlist

; 删除 runtime 下的程序文件（会被新版本替换的工具）
; ★ 2026-10-02 OpenList 半移植化：runtime\openlist\openlist.exe 由用户在
;   应用内「对接」获得（zip 从服务器下载解压），安装包已不再内置、装不回
;   新 exe —— 因此绝不可在此删除，否则用户对接在首次更新时即被解除。
;   openlist/data/ 里的用户配置和数据库由 [Files] Excludes 保护。
Type: filesandordirs; Name: {app}\runtime\tools
Type: filesandordirs; Name: {app}\runtime\magpie
Type: filesandordirs; Name: {app}\runtime\locale_emulator
; 旧版可能存在的独立 scraper_service.exe
Type: files; Name: {app}\runtime\scraper_service.exe

; 删除旧位置字体文件（V0.8 曾放在根目录，现已内嵌到 flutter_assets）
Type: files; Name: {app}\Mali-Regular.ttf

[Files]
; 软件本体文件
; [优化-体积] 排除用户运行时数据，保留 Flutter 程序必需文件
; 注意：data\* 不能整体排除！data 目录下包含 Flutter 运行必需文件：
;   - data/app.so (编译后的 Dart 代码)
;   - data/icudtl.dat (ICU 国际化数据)
;   - data/flutter_assets/ (Flutter 资源文件)
; 仅排除运行时生成的缓存和用户数据
; ⭐ 便携化存储子目录必须全部排除，防止安装包混入开发者的
;   auth token / API 密钥 / 锁文件等敏感数据，更新时覆盖用户数据
Source: "build\windows\x64\runner\Release\*"; DestDir: {app}; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "Games\*,downloads\*,logs\*,data\cache\*,data\prefs\*,data\game_configs\*,data\user_themes\*,data\user_backgrounds\*,data\tmp\*,data\lock\*,data\migration\*,data\models\*,data\metadata_fetch.log,data\company_alias_pending.json,data\daily_recommendation.json,data\watch_candidates.json,data\company_wall.json,data\collections.json,data\cleanup_log.jsonl,data\company_logo_attempts.json,data\company_logos\*,data\gamepad_profiles.json,data\op_video_attempts.json,data\tag_library_overrides.json,data\title_logo_attempts.json,data\unpack_passwords.json,data\unpack_settings.json,runtime\font_hook\*,runtime\openlist\data\log\*,runtime\openlist\data\temp\*"

; [优化-体积] 2026-10-03 移除 Mali-Regular.ttf 打包：字体方案已切换为
;   F1 得意黑 / F2 Outfit / F3 NotoSansSC（内嵌 flutter_assets），Mali 代码零引用。

; VC++ 2015-2022 x64 运行库（微软官方分发包，来源 https://aka.ms/vs/17/release/vc_redist.x64.exe）
; 仅安装期释放到临时目录；系统已装则由 [Run] 的 Check 跳过，不重复安装、不留在安装目录。
; 主程序与插件的 PE 导入表硬依赖 VCRUNTIME140_1.dll / MSVCP140.dll / api-ms-win-crt-*。
Source: "redist\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: {group}\{#AppName}; Filename: {app}\{#AppExe}; WorkingDir: {app}
Name: {commondesktop}\{#AppName}; Filename: {app}\{#AppExe}; WorkingDir: {app}; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: 创建桌面快捷方式; Flags: checkedonce

[Run]
; VC++ 2015-2022 x64 运行库：仅当系统缺少 VCRUNTIME140_1.dll 时静默安装。
; 必须排在启动主程序之前；/norestart 避免装完立即重启；属系统共享组件，卸载时不删除。
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Visual C++ 运行库..."; Flags: runhidden waituntilterminated; Check: NeedsVCRedist
; 安装完成后启动软件：使用 WorkingDir 确保工作目录正确
Filename: {app}\{#AppExe}; Description: 启动 Chrono Tide; WorkingDir: {app}; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: dirifempty; Name: {app}

; [优化-体积] 确保安装后创建必要的空目录
; Inno Setup 不会创建空目录，需要显式声明
[Dirs]
Name: {app}\data; Flags: uninsneveruninstall
Name: {app}\data\lock; Flags: uninsneveruninstall
Name: {app}\downloads; Flags: uninsneveruninstall
Name: {app}\Games; Flags: uninsneveruninstall
Name: {app}\logs; Flags: uninsneveruninstall
Name: {app}\runtime\openlist\data; Flags: uninsneveruninstall

; ========== 安装完成后的清理 ==========
[Registry]
; 注册应用路径（确保系统可以正确找到软件）
Root: HKLM; Subkey: "Software\{#AppName}"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey

; ========== [Code] 段：强制进程清理 ==========
; 解决问题1：软件更新时的进程退出问题
;
; 背景：
;   - Dart 层 windowManager.setPreventClose(true) 拦截了 WM_CLOSE 消息
;   - ISS 内置的 CloseApplications 发送 WM_CLOSE 无效（被拦截后仅隐藏到托盘）
;   - 子进程（openlist.exe、Magpie.exe、7z.exe 等）完全不被清理
;   - 单实例锁文件残留导致更新后无法启动
;
; 方案：
;   - 使用 taskkill /F /T 强制终止所有相关进程（绕过 setPreventClose）
;   - 清理 %TEMP%\chrono_tide_instance.lock 单实例锁文件
;   - 清理 %TEMP%\chrono_tide_launch_requests 启动请求目录
[Code]

// 检测是否需要安装 VC++ 2015-2022 x64 运行库。
// 判据取自主程序/插件 PE 导入表的硬依赖 VCRUNTIME140_1.dll（VS 2017 15.x 起才有）。
// 用 {win}\System32 而非 {sys}：安装器是 32 位进程，{sys} 会被重定向到 SysWOW64。
function NeedsVCRedist(): Boolean;
begin
  Result := not FileExists(ExpandConstant('{win}\System32\vcruntime140_1.dll'));
end;

// 需要清理的进程列表（主程序 + 所有内置工具 + 子进程）
// 保持与 lib\services\process_cleanup_service.dart 同步
const
  ProcessList = 'chrono_tide.exe,openlist.exe,Magpie.exe,7z.exe,7za.exe,bz.exe,UnRAR.exe,LEProc.exe,LRProc.exe,scraper_service.exe';

// 执行 taskkill 强制终止单个进程（含子进程树）
// /F = 强制终止（不发送 WM_CLOSE，绕过 setPreventClose 拦截）
// /T = 含子进程树
procedure KillProcessByName(ProcName: String);
var
  ResultCode: Integer;
begin
  // 使用 >nul 2>&1 静默输出，避免 taskkill 错误信息干扰
  // 即使进程不存在，taskkill 也会返回非零退出码，所以不检查返回值
  Exec(ExpandConstant('{cmd}'), '/C taskkill /IM "' + ProcName + '" /F /T >nul 2>&1', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// 检查进程是否仍在运行
function IsProcessRunning(ProcName: String): Boolean;
var
  ResultCode: Integer;
  TempFile: String;
  OutputText: AnsiString;  // LoadStringFromFile 要求 AnsiString 类型
begin
  Result := False;
  TempFile := ExpandConstant('{tmp}\proc_check_' + ProcName + '.txt');

  // tasklist 检查进程，输出到临时文件
  if Exec(ExpandConstant('{cmd}'),
    '/C tasklist /FI "IMAGENAME eq ' + ProcName + '" /NH > "' + TempFile + '" 2>&1',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringFromFile(TempFile, OutputText) then
    begin
      // 如果输出中包含进程名（非"INFO: No tasks"），说明进程还在运行
      // AnsiString 与 String(Unicode) 混合比较时，Inno Setup 自动转换
      if (Pos(ProcName, String(OutputText)) > 0) and (Pos('No tasks', String(OutputText)) = 0) then
        Result := True;
    end;
  end;

  // 清理临时文件
  DeleteFile(TempFile);
end;

// 等待进程退出（最多 WaitSeconds 秒，每 500ms 检查一次）
function WaitForProcessExit(ProcName: String; WaitSeconds: Integer): Boolean;
var
  I: Integer;
begin
  for I := 1 to WaitSeconds * 2 do
  begin
    if not IsProcessRunning(ProcName) then
    begin
      Result := True;
      exit;
    end;
    Sleep(500);
  end;
  // 超时后最后检查一次
  Result := not IsProcessRunning(ProcName);
end;

// 清理单实例锁文件和启动请求目录（关键！防止更新后启动失败）
// 同时清理旧位置(%TEMP%)和新位置(data/lock/)，兼容便携化迁移前后两种路径
procedure CleanupInstanceLock();
var
  LockFile: String;
  RequestDir: String;
begin
  // ===== 旧位置：%TEMP% （便携化迁移前的遗留路径，兼容老版本用户） =====
  // 清理单实例锁文件
  LockFile := ExpandConstant('{%TEMP}\chrono_tide_instance.lock');
  if FileExists(LockFile) then
  begin
    Log('CleanSetup: 删除单实例锁文件(旧位置): ' + LockFile);
    DeleteFile(LockFile);
  end;

  // 清理启动请求目录（避免残留请求干扰新实例）
  RequestDir := ExpandConstant('{%TEMP}\chrono_tide_launch_requests');
  if DirExists(RequestDir) then
  begin
    Log('CleanSetup: 清理启动请求目录(旧位置): ' + RequestDir);
    DelTree(RequestDir, True, True, True);
  end;

  // ===== 新位置：data/lock/ （便携化迁移后的路径） =====
  // 强杀进程后锁文件可能残留，清理避免下次启动误判
  LockFile := ExpandConstant('{app}\data\lock\chrono_tide_instance.lock');
  if FileExists(LockFile) then
  begin
    Log('CleanSetup: 删除单实例锁文件(新位置): ' + LockFile);
    DeleteFile(LockFile);
  end;

  // 清理启动请求目录
  RequestDir := ExpandConstant('{app}\data\lock\chrono_tide_launch_requests');
  if DirExists(RequestDir) then
  begin
    Log('CleanSetup: 清理启动请求目录(新位置): ' + RequestDir);
    DelTree(RequestDir, True, True, True);
  end;
end;

// ========== 核心入口：安装前强制清理所有进程 ==========
// PrepareToInstall 在 [Files] 复制之前执行
// 返回非空字符串会中止安装并显示该字符串作为错误信息
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProcNames: TStringList;
  I: Integer;
  ProcName: String;
  FailedProcs: String;
begin
  Result := '';
  FailedProcs := '';

  Log('CleanSetup: 开始强制清理所有 Chrono Tide 相关进程...');

  ProcNames := TStringList.Create;
  try
    ProcNames.DelimitedText := ProcessList;
    ProcNames.Delimiter := ',';

    // 第一轮：批量强制终止所有进程
    for I := 0 to ProcNames.Count - 1 do
    begin
      ProcName := Trim(ProcNames[I]);
      if ProcName <> '' then
      begin
        Log('CleanSetup: 终止进程: ' + ProcName);
        KillProcessByName(ProcName);
      end;
    end;

    // 等待 2 秒让进程完全退出（文件句柄释放需要时间）
    Sleep(2000);

    // 第二轮：检查并重试未退出的进程
    for I := 0 to ProcNames.Count - 1 do
    begin
      ProcName := Trim(ProcNames[I]);
      if ProcName <> '' then
      begin
        if IsProcessRunning(ProcName) then
        begin
          Log('CleanSetup: 进程仍在运行，再次强制终止: ' + ProcName);
          KillProcessByName(ProcName);
          if not WaitForProcessExit(ProcName, 5) then
          begin
            Log('CleanSetup: 警告: 进程无法终止: ' + ProcName);
            FailedProcs := FailedProcs + ProcName + ', ';
          end;
        end;
      end;
    end;
  finally
    ProcNames.Free;
  end;

  // 清理单实例锁文件（关键！防止更新后启动失败）
  CleanupInstanceLock();

  // 再等待 1 秒确保所有文件句柄完全释放
  Sleep(1000);

  // 如果有进程无法终止，提示用户手动处理
  if FailedProcs <> '' then
  begin
    Result := '以下进程无法自动终止，请手动关闭后重试：' + #13#10 + #13#10 +
              FailedProcs + #13#10 + #13#10 +
              '或重启计算机后再次运行安装程序。';
  end;
end;

// ========== 卸载前同样清理进程 ==========
function InitializeUninstall(): Boolean;
var
  ProcNames: TStringList;
  I: Integer;
  ProcName: String;
begin
  Result := True;

  Log('CleanSetup: 卸载开始，清理所有进程...');

  ProcNames := TStringList.Create;
  try
    ProcNames.DelimitedText := ProcessList;
    ProcNames.Delimiter := ',';

    // 强制终止所有进程
    for I := 0 to ProcNames.Count - 1 do
    begin
      ProcName := Trim(ProcNames[I]);
      if ProcName <> '' then
      begin
        KillProcessByName(ProcName);
      end;
    end;

    // 等待进程退出
    Sleep(2000);
    CleanupInstanceLock();
  finally
    ProcNames.Free;
  end;
end;
