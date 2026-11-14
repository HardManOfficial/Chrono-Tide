import io
p = r"D:\CTLIB\.workbuddy\memory\MEMORY.md"
old = io.open(p, encoding="utf-8").read()
io.open(p + ".bak20261003", "w", encoding="utf-8").write(old)
NEW = r"""# MEMORY.md — Chrono Tide（D:\CTLIB）长期约定

> 2026-10-03 蒸馏（6389→<3k）。权威细节以 AGENTS.md、docs/DEV/*.md、features/*.md、DECISIONS.md、SESSION_HANDOFF.md（最新状态必读）为准。

## 0. 铁律
1. 两段式：先只读审计出《变更计划》等批准再执行；禁从零重设计。
2. 收工：analyze（只看新增 error）→ git 自查 → 更新 DEV_LOG/HANDOFF/features → 一任务一 commit（只 git add 显式文件，禁 -A）。
3. 🔴 Edit/Write 可能"报成功但不落盘"（本仓 CRLF）→ 改完必须 grep/Read 验证。

## 1. 环境
- 用项目内 ./flutter/bin/flutter.bat（3.24.3/Dart 3.5.3），flutter 不在 PATH；改 UI 必须人工验证。
- 🔴 跑 flutter 前同 shell unset 全部代理（http_proxy 时 test 全量假失败）。
- 🔴 本环境禁建 Dart 匿名管道（CreateFile failed 231）⇒ analyze/test 跑不通：analyze 用 .workbuddy/analyze_probe/ 进程内 analyzer（skill flutter-analyze-without-subprocess）；test 不可替代 → 开发者终端跑。⚠️ 跑不了的测试 = 没有测试。
- ✅ dart.exe 本身能跑：flutter/bin/cache/dart-sdk/bin/dart.exe --packages="D:/CTLIB/.dart_tool/package_config.json" <探针>.dart（package:ffi 可用）⇒ 纯 Dart 探针可实测。
- Release：exe 时间戳不变＝没构建；LNK1104＝旧实例锁 → taskkill；test 与 build 不可并行；磁盘 <10G 禁写盘。flaky：test/smart_import/、game_move_service_test（单跑全绿）。
- 🔴 AI 沙箱（2026-10-03 实测）：C 盘 0 剩余 → Bash ENOSPC 瘫、PowerShell 原生输出捕获全丢、Edit/Write ModifyBackup 失败（os error 112）、managed venv python 静默失败 → 用 system Python313（PIL 12.2.0），进程输出一律落盘文件；python -c 多行串会静默崩勿用。
- 🔴 docs/DEV/DEV_LOG.md（560KB）与 SESSION_HANDOFF.md 系统级写保护：python PermissionError（目录内新建也被拒），PowerShell Set-Content/WriteAllLines/Move-Item -Force 报成功但静默不落盘 → 更新前先探锁且必须 Read 验证；锁定期间用独立更新文本落地（图标更新文本在 dev_probe/_new_devlog_entry.txt、_new_handoff_block.txt）。

## 2. 护栏
- 删除清理必须过 PathHelper.isInsideAppStorage；归属存疑永远保留（ADR-007）。
- 目录时间戳仅秒级，禁 mtime 判新旧；确定性＝回传路径的回调瞬间（ADR-008）。
- ⛔ git gc；⛔ 手工 lib_backup；⛔ 动 chrono-tide-opensource/。
- ⛔ 未批准禁动稳定区：main.dart、main_container.dart、lib/theme/、lib/core/portable_*.dart、app_state.dart、windows/runner/、packages/luna_metadata_sdk/。

## 3. 数据层
- 身份 = game.json.game_id；目录名清洗唯一实现 GameKey.dirNameFromTitle；🔴 format_version 实测=4（game_data_format.dart:36）；改字段 → _migrations+升版本+补测试（迁移绕开写队列）。纯新增可空字段 ?? 默认值可不升版本（ADR-012，需开发者确认）。
- 启动 exe 唯一事实源 = launch_path，走 GameLaunchService。
- 候选队列 data/watch_candidates.json（不在 prefs）；大目录遍历 utils/fs_scan.dart；去重键 TitleCleaner.normalizeForCompare；渲染列表=操作列表，卡片 key 按游戏身份。

## 4. UI 布局坑（右栏窄宽 + 浮层）
- 🔴 Wrap 子项在 interactive_wrapper.dart:69-77 下撑满整行竖排 → 子项内包 IntrinsicWidth（⛔ 不改本体）；窄右栏（≈194px）标签行必须 Wrap+先算宽度预算，Row+Spacer 必溢出。
- 🔴 浮层（OverlayEntry/showGeneralDialog）必包 Material(transparency)，否则 Text 继承纯黄双下划线兜底样式；animated_overlay.dart 本身不提供 Material。
- Container(clipBehavior) 只裁直接子级 → 内部滚动件各自加 clipBehavior。布局回归横纵两维都要查。
- 🔴 requestFocus() 非同步生效：同帧读 primaryFocus 先 applyFocusChangesIfNeeded()。

## 5. BPM + 手柄
- 全屏 setAsFrameless + FFI 物理像素；桌面⇄BPM＝420ms 镜头推近（main_container.dart:811）。
- 焦点：BpmFocusZone+BpmFocusDomain 成对装；⛔ 入口 FocusNode/GlobalKey 插桩。
- 手柄：前台守卫目录级；SDL3 进程级单例 ⛔ SDL_Quit()；手柄提示路由须在模态判定之前；排障日志 logs/gamepad_adaptation.log。
- 🔴 产品决策：BPM 整体走本地、不做云端功能/探索页界面。

## 6. PocketBase（必读 features/pb_setup_stepbook.md）
- http://117.72.115.30:8090（京东云封 25 出站），PB 0.34.2。
- 🔴 goja hook：零顶层声明（顶层 const 回调不可见）；禁类型 getter（用 rec.get(k) 判型）；$app.save/delete=超管通道；⛔ 禁整目录覆盖部署。
- 🔴 goja：e.requestInfo 是方法必须 ()；冷却判断禁 created 字符串+new Date（goja 恒 NaN），用 expires_at 反推。邮件三件套=主题含码+text/html 双 part+table 内联样式；找回密码 OTP 服务端化（password_reset_otp.pb.js）。
- 🔴 越权返 404=已拦住；写规则被拒 400 非 403 → 两侧对照；handler 抛非 ApiError ⇒ 400 无信息。注册验证码走自建路由；⛔ 禁开"必须邮箱验证登录"。
- 探针账号用完即删；⛔ 指向真实用户数据；本地实例 .workbuddy/pb_dev/（8091），只部署本地全绿定版包。两条下载通道勿混淆（官方直链 vs game_resources 分享）；署名走发布时快照。
- 🔴 线上限流 *:create=60s/3、*:auth=10s/5 → 探针加 429 退避（21s×10）；京东云 URLError 瞬断需退避；本地邮件探针 pb_dev/_smtp_catch.py（2525）。
- 🔴 PB 0.34 规则语法：@request.body.*（@request.data.* 报 invalid_rule）；updateRule 须显式放行发起转换。

## 7. 当前待办
- 🟢 图标换新（f64a971）：BMP 帧多尺寸 ICO（372526B）已换 exe/托盘/安装器三处（Runner.rc:55 / tray_service.dart:107 / Setup.iss:31）。PNG 帧 LoadImage 不支持（窗口类/托盘加载失败）；🔴 ICO BMP 帧=bottom-up，top-down 写全帧颠倒；512 帧无法进 ICO（bWidth 1 字节封顶 256）。生成器 dev_probe/make_app_icon_ico.py。⏳ 重建 exe+打包+真机走查；DEV_LOG/HANDOFF 更新文本 dev_probe/_new_devlog_entry.txt、_new_handoff_block.txt 待解锁落地。
- ✅ 打包瘦身 P0/P1 收官（16c67f3+cb03e35，features/slimdown_packaging.md）：92.7MB→约 80MB。⚠️ 待：重新打包实测体积、干净安装首启走查、flutter test 补跑。P2 四项+双样式合并暂缓。打包脚本/ 在 .gitignore；ps1 清理列表本就含 cache。
- 🟢 游戏数据保存（存储状态）：Phase 0 通过（b77304d，features/game_storage_state_phase0_report.md）。三决策：文案保持「备份」/不升 format_version/归档只存一份。Phase 1 三必改：① _parse7zLine 正则 → ^\s*(\d+)%（extract_manager.dart:1304，顺带修进度条不动 bug）② 吞吐 5–20 MB/s ③ .partial 标记 Dart 侧做。⛔ -sdel；⛔ -v 分卷（extract_manager 不认 .7z.001，格式表 :737-779）；回收站用 FFI SHFileOperationW。
- 🟡 邮件兼容+找回密码 OTP 待部署 v12：空白邮件=PB 内置 authAlert（迁移 1790991100 关闭）；hook 带预算重试+console.log（🔴 改 hook 必须 cp 同步 pb_dev/pb_hooks/）。本地探针 18/18。⏳ 部署→线上回归→重构建 exe。（features/auth_mail_compat_password_reset.md §6）
- 2026-10-03 标签词表 P0 扩充+ROUND2 收官（62ab615→88d0e62，9 维/426 概念/~3000 别名键，adult 第 9 维；实库 67 部命中 43.8%；生成器 dev_probe/gen_tag_vocabulary.py，EXTRA 禁指向 NEW）。分类匣（d9a5e45）。待 analyze test 补跑+真机走查；分类匣 §5、探索页 adult 分组/概念收敛待拍板。
- NSFW 规划：移除 mask mode、新增 work mode（未开工）。字体：F1 得意黑（标题禁 w700）/F2 Outfit/F3 NotoSansSC。
"""
io.open(p, "w", encoding="utf-8", newline="").write(NEW)
t = io.open(p, encoding="utf-8").read()
keys = ["铁律", "format_version", "bottom-up", "LoadImage", "写保护", "SHFileOperationW", "authAlert"]
io.open(r"D:\CTLIB\dev_probe\_mem_distill_check.txt", "w", encoding="utf-8").write(
    "len=%d allkeys=%s" % (len(t), all(k in t for k in keys)))
