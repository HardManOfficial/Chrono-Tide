# -*- coding: utf-8 -*-
"""场景 B 端到端实测：探索页标签筛选链路（云端 games 集合 → 词表分组/收敛统计）。

匿名拉取线上 PocketBase games 集合（探索页数据源，GET 只读），
用新词表复刻 discover_page 的 _buildTagMenuGroups 分组逻辑与 _performFilter
的 contains 筛选语义，输出：分组效果 / 命中率 / adult 暴露面 / 其他分区 Top。
只读探针。429 时按线上限流经验退避 21s（最多 8 次）。
"""
import json, time, urllib.request, urllib.error, sys

NOISE = {0x20,0x09,0x0A,0x0D,0x3000,0xB7,0x30FB,0x2C,0x3001,0x3002,0x2E,0x21,0x3F,
         0x7E,0x2D,0x2010,0x2013,0x2014,0x2015,0x5F,0x28,0x29,0x3014,0x3015,0x3010,
         0x3011,0x5B,0x5D,0x7B,0x7D,0x300C,0x300D,0x300E,0x300F,0x22,0x27,0x3A,0x3B,
         0x2A,0x23,0x40,0x26,0x2F,0x5C,0x7C}
def norm(raw):
    out = []
    for c in raw.strip():
        o = ord(c)
        if 0xFF01 <= o <= 0xFF5E: o -= 0xFEE0
        if o in NOISE: continue
        if 0x41 <= o <= 0x5A: o += 0x20
        out.append(chr(o))
    return ''.join(out)

dims = json.load(open('D:/CTLIB/assets/data/tag_dimensions.json', encoding='utf-8'))['dimensions']
dim_title = {d['id']: d['title'] for d in dims}
vocab = json.load(open('D:/CTLIB/assets/data/tag_vocabulary.json', encoding='utf-8'))
alias_idx, concepts = {}, {c['id']: c for c in vocab['concepts']}
for c in vocab['concepts']:
    for k in [c['name']] + c.get('aliases', []):
        n = norm(k)
        if n and n not in alias_idx:
            alias_idx[n] = c['id']

def resolve(raw):
    return alias_idx.get(norm(raw))

BASE = 'http://117.72.115.30:8090/api/collections/games/records'
def fetch(page, per=200):
    url = f'{BASE}?page={page}&perPage={per}&fields=id,tags,title&sort=-created'
    for attempt in range(8):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                print(f'  429 限流，退避 21s（第 {attempt+1} 次）', file=sys.stderr)
                time.sleep(21); continue
            raise
        except urllib.error.URLError as e:
            print(f'  URLError {e.reason}，退避 21s（第 {attempt+1} 次）', file=sys.stderr)
            time.sleep(21); continue
    raise RuntimeError('重试耗尽')

print('=== 场景 B：云端 games 标签拉取（探索页数据源） ===')
records, page, total = [], 1, None
while True:
    data = fetch(page)
    total = data.get('totalItems', 0)
    items = data.get('items', [])
    records.extend(items)
    print(f'  page {page}: +{len(items)}（累计 {len(records)}/{total}）')
    if not items or len(records) >= total or page >= 15: break
    page += 1
    time.sleep(1.5)

games_with_tags = [r for r in records if isinstance(r.get('tags'), list) and r['tags']]
print(f'带标签资源: {len(games_with_tags)}/{len(records)}')
occ = {}
for r in games_with_tags:
    for t in r['tags']:
        if isinstance(t, str) and t.strip():
            occ[t] = occ.get(t, 0) + 1
uniq = sorted(occ)
hit = [t for t in uniq if resolve(t)]
print(f'云端去重标签: {len(uniq)}  命中词表: {len(hit)} = {len(hit)/max(len(uniq),1)*100:.1f}%')
occh = sum(c for t, c in occ.items() if resolve(t))
print(f'出现次数口径: {occh}/{sum(occ.values())} = {occh/max(sum(occ.values()),1)*100:.1f}%')

print()
print('=== 分组菜单实测（复刻 _buildTagMenuGroups：维度 → 原文标签） ===')
by_dim, unclassified = {}, []
for t in uniq:
    cid = resolve(t)
    if cid is None:
        unclassified.append(t); continue
    by_dim.setdefault(concepts[cid]['dim'], []).append(t)
for d in dims:
    ts = by_dim.get(d['id'], [])
    if not ts: continue
    print(f"  [{d['title']}] {len(ts)} 个原文标签将归入此组: " + ' | '.join(ts[:8]))
print(f'  [其他] {len(unclassified)} 个（放最后，不丢数据）')

# adult 暴露面
adult_tags = by_dim.get('adult', [])
adult_res = sum(1 for r in games_with_tags if any(resolve(t) and concepts[resolve(t)]['dim'] == 'adult' for t in r['tags']))
print()
print(f'=== adult 维度暴露面（内容安全盘点） ===')
print(f'成人概念命中的原文标签 {len(adult_tags)} 个: ' + ' | '.join(adult_tags[:15]))
print(f'带成人概念标签的资源: {adult_res} 部（若匿名规则可见，分组菜单会展示这些原文标签）')

miss = sorted((c, t) for t, c in occ.items() if not resolve(t))
print()
print('=== 其他分区 Top40（未命中词表；下一轮扩充输入） ===')
print(' | '.join(f'{t}({c})' for c, t in sorted(miss, reverse=True)[:40]))
