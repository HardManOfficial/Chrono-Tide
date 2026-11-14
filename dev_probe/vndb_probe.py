# -*- coding: utf-8 -*-
"""VNDB API 实测：系列标准、覆盖度、社区合集概念是否存在（只读）"""
import json, urllib.request, ssl, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

# 关代理（本仓铁律）
for k in list(__import__('os').environ):
    if 'proxy' in k.lower():
        del __import__('os').environ[k]

API = 'https://api.vndb.org/kana/vn'
CTX = ssl.create_default_context()

def query(filters, fields='id,title,relations{relation,relation_official,id,title}', results=10):
    body = json.dumps({'filters': filters, 'fields': fields, 'results': results}).encode()
    req = urllib.request.Request(API, data=body, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=25, context=CTX) as r:
        return json.load(r)

REL_CN = {
    'seq': '续作', 'preq': '前传', 'same': '同一世界观(不同角色)',
    'alt': '替代版本(重制)', 'altsetting': '平行世界(同角色不同世界线)',
    'side': '支线', 'par': '母本篇', 'fan': 'Fandisc', 'orig': '原作',
    'same_series': '同一系列', 'char': '共享角色', 'mon': '货币化? ', 'ot': '其他',
}

# 1. 搜「命运石之门」看关系模型
print('===== 1) Steins;Gate 搜索 =====')
r = query(['search', '=', 'Steins;Gate'])
for v in r['results'][:3]:
    print(f"\n[{v['id']}] {v['title']} —— relations {len(v.get('relations', []))} 条:")
    for rel in v.get('relations', []):
        cn = REL_CN.get(rel['relation'], rel['relation'])
        off = '官方' if rel.get('relation_official') else '非官方'
        print(f"   {cn}({rel['relation']},{off}) -> {rel['title']}")

# 2. 搜「十二神器」「九宫格」——社区合集概念是否存在
print('\n===== 2) 社区合集概念在 VNDB 是否存在 =====')
for kw in ['十二神器', '九宫格']:
    r = query(['search', '=', kw])
    print(f"搜索 '{kw}': {r.get('count', 0)} 条结果 -> {[x['title'] for x in r['results'][:5]]}")

# 3. 十二神器成员之间的关系边（素晴日 / euphoria）
print('\n===== 3) 十二神器成员之间的关系（社区合集在关系图中不可见）=====')
for kw in ['Subarashiki Hibi', 'EUPHORIA']:
    r = query(['search', '=', kw])
    if not r['results']:
        print(f"{kw}: 无结果"); continue
    v = r['results'][0]
    titles = [x['title'] for x in v.get('relations', [])]
    print(f"[{v['id']}] {v['title']}: {len(v.get('relations', []))} 条关系 -> {titles}")

# 4. 覆盖度抽查：我们云端游戏的冷门成员在 VNDB 有没有
print('\n===== 4) 冷门作品覆盖度抽查 =====')
for kw in ['重生萝莉岛', '媚肉之香', '魔女恋爱日记', '杀恋']:
    r = query(['search', '=', kw])
    print(f"'{kw}': {r.get('count', 0)} 条 -> {[x['title'] for x in r['results'][:3]]}")
