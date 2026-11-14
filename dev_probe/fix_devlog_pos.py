# -*- coding: utf-8 -*-
import io, shutil
path = r'D:\CTLIB\docs\DEV\DEV_LOG.md'
shutil.copyfile(path, r'D:\CTLIB\docs\DEV\DEV_LOG.md.bak_gallery2')
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    text = f.read()

start_marker = '## 2026-10-04 【功能】封面管理浮层'
header_marker = '# DEV_LOG — 开发时间线'
assert text.startswith(start_marker), 'unexpected head'
idx_end = text.find(header_marker)
assert idx_end > 0, 'header not found'
devlog = text[:idx_end]          # 我插入的条目（含尾部空行）
rest = text[idx_end:]            # 原始文件内容

anchor = '## 2026-10-04 【研究】单文件导入「智能解压」方案'
pos = rest.find(anchor)
assert pos > 0, 'anchor missing'
fixed = rest[:pos] + devlog + rest[pos:]
with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(fixed)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    t2 = f.read()
h = t2.find(header_marker)
a = t2.find(start_marker)
r = t2.find(anchor)
print('ORDER OK' if 0 <= h < a < r else 'ORDER BAD', h, a, r)
