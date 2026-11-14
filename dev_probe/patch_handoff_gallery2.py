# -*- coding: utf-8 -*-
import io, shutil
path = r'D:/CTLIB/docs/DEV/SESSION_HANDOFF.md'
shutil.copyfile(path, path + '.bak_gallery2b')
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    text = f.read()

if 'GALLERY2-VERIFY' in text:
    print('SKIP(already)'); raise SystemExit

# 找第一个条目标题（## 开头，跳过文件头引用块）
lines = text.split('\n')
first_entry = None
for i, ln in enumerate(lines):
    if ln.startswith('## ') and 'SESSION_HANDOFF' not in ln:
        first_entry = i
        break
assert first_entry is not None, 'no entry heading'
insert_at = first_entry  # 插到第一个条目之前

entry = '''📦 本轮 · 最后更新：**2026-10-05 深夜·【修复+功能】横幅抓取全链路加固 + 相册改版 + 添加页相册**——
P0 横幅修复四环节：hikarinagi 接入 covers[] 横幅挑选（此前没解析）+ NextMoe 两轮策略（无尺寸候选回退）+ MIX 链 nextmoe→hikarinagi→kun（kun 论坛头图降链尾）+ **下载侧宽高比校验 ≥1.15 兜底**（CoverDownloadService.downloadBanner，假横幅/音乐盘图在此拒收）。⚠️ 开发者口述「EXTeMOE」按 LunaBox 血统判定为 Hikarinagi，待确认。相册浮层：全窗口自由拖动 + 第三按钮改「恢复」+ 上一张/下一张 + 抓取入口移除（纯相册）。添加页：「相册 N」入口 + cover_preview_overlay.dart（竖/横双类型预览）。验证：analyze 9 文件 0 error；⏳ test 被 231 拦死未跑成 + 未真机走查。
详见 docs/DEV/features/game_banner_cover.md §8。GALLERY2-VERIFY

'''
lines.insert(insert_at, entry)
with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write('\n'.join(lines))
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    t2 = f.read()
print('OK' if 'GALLERY2-VERIFY' in t2 else 'VERIFY FAIL')
