# -*- coding: utf-8 -*-
"""深挖典型系列条目级质量"""
import json, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

with open(r'D:\CTLIB\dev_probe\series_audit_series.json', encoding='utf-8') as f:
    series = json.load(f)['items']
with open(r'D:\CTLIB\dev_probe\series_audit_entries.json', encoding='utf-8') as f:
    entries = json.load(f)['items']

by_id = {e['id']: e for e in entries}
title_of = {s['id']: s['title'] for s in series}
ent_of = {}
for e in entries:
    ent_of.setdefault(e.get('series'), []).append(e)

targets = ['命运石之门系列', '兰斯系列', '甜蜜女友系列', 'AIR', '星之梦系列', '万华镜系列', '借恋系列', '恋姬†系列', '水仙', '白色相簿系列']
for s in series:
    if s['title'] not in targets:
        continue
    print(f"\n=== {s['title']} (mode={s.get('mode') or '(空)'}) desc={bool(s.get('description'))} ===")
    def game_title(e):
        g = e.get('expand', {}).get('game')
        if not g:
            return '(悬空)'
        if isinstance(g, list):
            g = g[0] if g else {}
        return g.get('title', '?')
    for e in ent_of.get(s['id'], []):
        gtitle = game_title(e)
        parent = by_id.get(e.get('parent'))
        ptitle = game_title(parent) if parent else '(根)'
        print(f"  [{e.get('relationType') or '?'}] {gtitle[:38]:<40} parent={ptitle[:20]:<22} sort={e.get('sortOrder')}")

# 全局：parent 字段为空的条目里 relationType 分布（根的语义混乱）
print("\n=== 全局根节点 relationType ===")
from collections import Counter
roots = [e for e in entries if not e.get('parent')]
print(dict(Counter(e.get('relationType') for e in roots)))

# 全局：sortOrder 是否在用
zeros = sum(1 for e in entries if e.get('sortOrder') == 0)
print(f"\nsortOrder=0 的条目: {zeros}/{len(entries)}")

# 树模式里 standalone 条目的 parent 情况
standalone = [e for e in entries if e.get('relationType') == 'standalone']
st_parent = sum(1 for e in standalone if e.get('parent'))
print(f"standalone 条目 {len(standalone)} 个，其中有 parent 的: {st_parent}")
