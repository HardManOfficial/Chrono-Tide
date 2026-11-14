# -*- coding: utf-8 -*-
"""恢复智能解压段到工作区文档（不提交，归属另一条线）"""
import io, sys

def rd(p):
    with io.open(p, 'r', encoding='utf-8') as f: return f.read()

def wr(p, s):
    with io.open(p, 'w', encoding='utf-8', newline='') as f: f.write(s)

BASE = r'D:/CTLIB'
jobs = [
    (BASE + r'\docs\DEV\DEV_LOG.md',
     BASE + r'\dev_probe\_unpack_devlog_section.txt',
     '## 2026-10-04 智能解压 Phase 3.5 补完'),
    (BASE + r'\docs\DEV\SESSION_HANDOFF.md',
     BASE + r'\dev_probe\_unpack_handoff_section.txt',
     '### 2026-10-04 智能解压 Phase 3.5 补完'),
]
ok = []
for target, tmp, mark in jobs:
    assert mark not in rd(target), '恢复前置检查失败(已存在?): ' + target
    body = rd(tmp).rstrip('\n')
    t = rd(target).rstrip('\n') + '\n\n\n' + body + '\n'
    wr(target, t)
    ok.append((target.split('\\')[-1] + ' 恢复', mark in rd(target)))
bad = [n for n, v in ok if not v]
print('RESTORE:', 'ALL PASS' if not bad else 'FAIL ' + str(bad))
sys.exit(1 if bad else 0)
