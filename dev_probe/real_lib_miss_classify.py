# -*- coding: utf-8 -*-
"""实库未命中标签分类：会社/年份/平台类（体系外）vs 真语义缺口。只读探针。"""
import json, glob, re, sys
sys.path.insert(0, 'D:/CTLIB/dev_probe')
src = open('D:/CTLIB/dev_probe/gen_tag_vocabulary.py', encoding='utf-8').read()
ns = {}
exec(src.split('def main()')[0], ns)
norm = ns['norm']
d = json.load(open('D:/CTLIB/assets/data/tag_vocabulary.json', encoding='utf-8'))
idx = {}
for c in d['concepts']:
    for k in [c['name']] + c.get('aliases', []):
        n = norm(k)
        if n and n not in idx:
            idx[n] = c['id']

base = r'D:/CTLIB/build/windows/x64/runner/Release/Games'
uniq = {}
for f in glob.glob(base + '/*/game.json'):
    d2 = json.load(open(f, encoding='utf-8'))
    for t in (d2.get('tags') or []):
        if isinstance(t, str) and t.strip():
            uniq[t] = uniq.get(t, 0) + 1
miss = sorted([(c, t) for t, c in uniq.items() if norm(t) not in idx], reverse=True)

def is_year(t):
    return bool(re.fullmatch(r'(19|20)\d{2}([-–]\d{1,2})?', t.strip()))

def is_latin_brand(t):
    return bool(re.fullmatch(r"[A-Za-z0-9 .&'!·\\-]+", t.strip()))

def is_brandish(t):
    return bool(re.search(r'社$|そふと|Soft$|Works$|Project$|Games?$|team$|Team$|石$', t))

com_like = [(c, t) for c, t in miss if is_year(t) or is_latin_brand(t) or is_brandish(t)]
com_set = set(t for _, t in com_like)
rest = [(c, t) for c, t in miss if t not in com_set]

print(f'未命中 {len(miss)} = 会社/品牌/年份/平台 {len(com_like)} + 真语义 {len(rest)}')
print()
print('=== 会社/年份/平台类（设计上不进词表，会社墙/排序体系负责）===')
print(' | '.join(f'{t}({c})' for c, t in com_like[:60]))
print()
print('=== 真语义缺口（全部）===')
print(' | '.join(f'{t}({c})' for c, t in rest))
