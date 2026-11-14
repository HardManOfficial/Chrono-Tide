# ============================================================
#  操作面板入口 —— 由 Dev\*.bat 调用
#  用法：run.ps1 dev|check|test|save|build|release|history|doctor
#
#  这个文件在 9 个项目里完全一样，项目差异全在 _project.ps1
# ============================================================

param([string]$Action = '')

. (Join-Path $PSScriptRoot '_project.ps1')
. (Join-Path $PSScriptRoot '_core.ps1')

if ([string]::IsNullOrWhiteSpace($Action)) {
    $Action = Get-CtCfg 'DefaultAction' 'history'
}

Invoke-CtAction -Action $Action

# 无人值守（CT_NO_PAUSE=1）时把成败反映到退出码，方便脚本/AI 判断；
# 人机双击时不返回非零，避免 bat 里的 errorlevel 再 pause 一次（窗口要按两次回车）
if ($env:CT_NO_PAUSE -eq '1') {
    if ($script:CtLastOk) { exit 0 } else { exit 1 }
}
exit 0
