# -*- coding: utf-8 -*-
"""审计线上 series / series_entries 数据质量（只读）"""
import json, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

with open(r'D:\CTLIB\dev_probe\series_audit_series.json', encoding='utf-8') as f:
    series = json.load(f)['items']
with open(r'D:\CTLIB\dev_probe\series_audit_entries.json', encoding='utf-8') as f:
    entries = json.load(f)['items']

print(f"=== 总量: series={len(series)}  series_entries={len(entries)} ===\n")

# series 字段样例
if series:
    print("series 字段:", list(series[0].keys()))
print("series_entries 字段:", list(entries[0].keys()) if entries else None)

# mode 分布
from collections import Counter
mode_dist = Counter(s.get('mode', '(空)') or '(空)' for s in series)
print("\nmode 分布:", dict(mode_dist))

# 每个 series 的成员数
cnt = Counter(e.get('series') for e in entries)
title_of = {s['id']: s['title'] for s in series}
print("\n--- 各系列成员数 ---")
for s in series:
    sid = s['id']
    print(f"  [{s.get('mode') or '?'}] {title_of.get(sid, sid)[:30]:<32} {cnt.get(sid, 0)} 部")
orphan_series = [s['id'] for s in series if cnt.get(s['id'], 0) == 0]
print(f"空系列（0 成员）: {len(orphan_series)} 个 -> {orphan_series}")

# entries 的 series 指向缺失
sid_set = set(title_of)
dangling = [e['id'] for e in entries if e.get('series') not in sid_set]
print(f"条目指向不存在系列: {len(dangling)}")

# relationType 分布
rt = Counter(e.get('relationType') or '(空)' for e in entries)
print("\nrelationType 分布:", dict(rt))

# 每部作品属于几个系列（正常应为 1，UNIQUE 约束）
game_series = {}
for e in entries:
    game_series.setdefault(e.get('game'), []).append(e.get('series'))
multi = {g: ss for g, ss in game_series.items() if len(ss) > 1}
print(f"一部作品属于多个系列: {len(multi)} 部")

# game expand 悬空（游戏被删）
dangling_game = [e['id'] for e in entries if not e.get('expand', {}).get('game')]
print(f"game 悬空条目: {len(dangling_game)}")

# 树结构健康度：parent 指向、主线链
print("\n--- 树结构（tree 模式系列逐个检查）---")
ent_of = {}
for e in entries:
    ent_of.setdefault(e.get('series'), []).append(e)
for s in series:
    if s.get('mode') != 'tree':
        continue
    es = ent_of.get(s['id'], [])
    by_id = {e['id']: e for e in es}
    roots = [e for e in es if not e.get('parent')]
    mainline_children = [e for e in es if e.get('relationType') in ('main', 'sequel') and e.get('parent')]
    # 根的数量与 relationType
    root_types = Counter(e.get('relationType') for e in roots)
    # 悬空 parent
    bad_parent = [e['id'] for e in es if e.get('parent') and e['parent'] not in by_id]
    # 环检测
    def has_cycle():
        for start in es:
            seen, cur = set(), start.get('parent')
            while cur:
                if cur in seen: return True
                seen.add(cur)
                cur = by_id.get(cur, {}).get('parent')
        return False
    cyc = has_cycle()
    # 每个节点的 relationType = main 的数量（非根 main 是异常？main 应是起点）
    main_nonroot = [e['id'] for e in es if e.get('relationType') == 'main' and e.get('parent')]
    flags = []
    if len(roots) != 1: flags.append(f"根数={len(roots)}{dict(root_types)}")
    if bad_parent: flags.append(f"悬空parent {len(bad_parent)}")
    if cyc: flags.append("有环")
    if main_nonroot: flags.append(f"非根main {len(main_nonroot)}")
    if not mainline_children and len(es) > 1: flags.append("无主线链(main/sequel 子节点=0)")
    print(f"  {s['title'][:24]:<26} 成员{len(es):>3}  {'⚠ ' + '; '.join(flags) if flags else 'OK'}")
