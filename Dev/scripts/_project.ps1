# ============================================================
#  Chrono Tide（主项目）· 面板配置
#  只写这个项目与别人不一样的地方；通用逻辑全在 _core.ps1
# ============================================================

$script:CTConfig = @{
    Name              = 'Chrono Tide'
    Kind              = 'flutter'

    # 打包：调用项目原有的完整打包脚本（编译 + 部署运行时 + 装 Inno Setup）
    BuildScript       = 'Dev\scripts\package.ps1'
    BuildModes        = @(
        @{ Label = '增量打包（最快，日常用这个）';      Args = @() },
        @{ Label = '全量重来（彻底干净，出怪问题时用）'; Args = @('-Clean', '-All') },
        @{ Label = '只编译，不做安装包（调试用）';      Args = @('-SkipInstaller', '-SkipUPX') }
    )

    # HEAD 上本来就失败的用例，不是本次改动造成的
    KnownFailingTests = @(
        'cover_preview_overlay_test',
        'cover_gallery_overlay_test',
        'bpm_page_zone_wiring_test'
    )

    ArtifactDirs      = @('Dev\dist')
    DefaultAction     = 'history'
}
