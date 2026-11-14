# -*- coding: utf-8 -*-
import io
path = r'D:/CTLIB/.workbuddy/memory/2026-10-05.md'
text = '''

---

## 横幅抓取全链路加固 + 相册改版 + 添加页相册（commit 616d444）

- P0 四环节：hikarinagi covers[] 横幅挑选接入（此前没解析）+ NextMoe 两轮策略（无尺寸候选回退）+ MIX 链 nextmoe→hikarinagi→kun + 下载侧宽高比校验 ≥1.15（downloadCover minAspectRatio / downloadBanner，缓存+网络两路径，假横幅删文件拒收）。
- ⚠️ 开发者口述「EXTeMOE」与六源显示名对不上，按 LunaBox 血统判定为 Hikarinagi（hikarinagi_service 注释即「参考 LunaBox metadata_hikarinagi.go」），待确认。
- 相册浮层：全窗口自由拖动（Positioned.fill）、第三按钮改「恢复」、+上一张/下一张（←/→ 键）、抓取入口移除（纯相册，onFetch 全清）。
- 添加页：metadata_section「相册 N」入口 + cover_preview_overlay.dart（网络 URL 预览，NsfwImage.network + CachedNetworkImage）。
- 🔴 并行会话活跃：SESSION_HANDOFF 会被并行重写——插入条目用 python 找第一个 `## ` 条目行（不再锚定具体旧文本，会被收编覆盖）；确认自己 commit 在历史后不必慌。
- 🔴 bash heredoc 内多段 python 脚本按顺序执行，前面 assert 挂掉后面段不会跑——一次脚本做完所有文件的写入再统一验证，或每文件独立脚本。
- 验证：analyze 9 文件 0 error；⏳ test 阵发 231 未跑成 + 未真机走查。
'''
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(text)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    print('APPENDED+VERIFIED' if '616d444' in f.read() else 'VERIFY FAIL')
