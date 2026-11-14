# -*- coding: utf-8 -*-
"""量化 NextMoe 全量标签对现词表的覆盖率，并给未命中做结构分析。"""
import json, os, sys, re
from collections import Counter, OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'dev_probe'))
src = open(os.path.join(ROOT, 'dev_probe/gen_tag_vocabulary.py'), encoding='utf-8').read()
ns = {}
exec(src.split('def main()')[0], ns)
norm = ns['norm']

vocab = json.load(open(os.path.join(ROOT, 'assets/data/tag_vocabulary.json'), encoding='utf-8'))
idx = {}
for c in vocab['concepts']:
    for k in [c['name']] + c.get('aliases', []):
        n = norm(k)
        if n and n not in idx:
            idx[n] = c['id'] + ':' + c['name']
print(f'现词表：{len(vocab["concepts"])} 概念 / {len(idx)} 别名键')

tags = json.load(open(os.path.join(ROOT, 'dev_probe/nextmoe_tags_full.json'), encoding='utf-8'))
tags = [t for t in tags if isinstance(t, dict)]
print(f'NextMoe 标签：{len(tags)}')

hit, miss = [], []
for t in tags:
    name = t.get('display_name') or ''
    if norm(name) in idx:
        hit.append(t)
    else:
        miss.append(t)
print(f'\n★ 命中 {len(hit)} / {len(tags)} = {len(hit)/len(tags)*100:.1f}%   未命中 {len(miss)}')

# 分层：core 命中率
for tier in ['core', 'longtail', 'hidden']:
    sub = [t for t in tags if t.get('tier') == tier]
    h = [t for t in sub if norm(t.get('display_name') or '') in idx]
    print(f'  {tier:9s}: {len(h)}/{len(sub)} = {len(h)/len(sub)*100:.1f}%' if sub else '')

# 未命中按 tier 拆
print('\n未命中按 tier:', dict(Counter(t.get('tier') for t in miss)))
print('未命中按 tag_kind:', dict(Counter(t.get('tag_kind') for t in miss)))
print('未命中 sexual:', dict(Counter(t.get('is_sexual') for t in miss)))

# core 未命中全列
core_miss = [t for t in miss if t.get('tier') == 'core']
print(f'\n=== core 未命中（{len(core_miss)} 个，最高优先）===')
print(' | '.join(sorted(t.get('display_name', '') for t in core_miss)))

json.dump([t.get('display_name') for t in miss], open(os.path.join(ROOT, 'dev_probe/nextmoe_miss.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
print('\n未命中清单 → dev_probe/nextmoe_miss.json')
