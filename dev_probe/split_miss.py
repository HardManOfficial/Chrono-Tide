# -*- coding: utf-8 -*-
"""把 NextMoe 未命中标签分层导出，便于分批人工归类。"""
import json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'dev_probe'))
src = open(os.path.join(ROOT, 'dev_probe/gen_tag_vocabulary.py'), encoding='utf-8').read()
ns = {}
exec(src.split('def main()')[0], ns)
norm = ns['norm']
vocab = json.load(open(os.path.join(ROOT, 'assets/data/tag_vocabulary.json'), encoding='utf-8'))
idx = set()
for c in vocab['concepts']:
    for k in [c['name']] + c.get('aliases', []):
        n = norm(k)
        if n:
            idx.add(n)

tags = json.load(open(os.path.join(ROOT, 'dev_probe/nextmoe_tags_full.json'), encoding='utf-8'))
miss = [t for t in tags if isinstance(t, dict) and norm(t.get('display_name') or '') not in idx]

def dump(name, lst):
    names = sorted({t.get('display_name', '') for t in lst})
    open(os.path.join(ROOT, f'dev_probe/nm_{name}.txt'), 'w', encoding='utf-8').write('\n'.join(names))
    print(f'{name}: {len(names)}')

dump('core_content', [t for t in miss if t.get('tier') == 'core' and t.get('tag_kind') == 'content'])
dump('core_meta', [t for t in miss if t.get('tier') == 'core' and t.get('tag_kind') == 'meta'])
dump('long_content', [t for t in miss if t.get('tier') == 'longtail' and t.get('tag_kind') == 'content'])
dump('long_meta', [t for t in miss if t.get('tier') == 'longtail' and t.get('tag_kind') == 'meta'])
dump('hidden_all', [t for t in miss if t.get('tier') == 'hidden'])

# 组合式统计（含「女主角/主人公/角色」后缀）
import re
suf = re.compile(r'(女主角|男主人公|女主人公|主人公|男主角|配角|角色|主角|女角色|男角色)$')
lc = [t.get('display_name', '') for t in miss if t.get('tier') == 'longtail' and t.get('tag_kind') == 'content']
comp = [t for t in lc if suf.search(t)]
print(f'\nlong_content 中组合式（含人物后缀）: {len(comp)}')
print('组合式样本:', ' | '.join(sorted(comp)[:30]))
