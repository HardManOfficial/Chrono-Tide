# -*- coding: utf-8 -*-
"""场景 A 端到端实测：模拟库分类匣（library_page._tagSections + 筛选）全流程。

复刻 TagVocabularyStore 的 normalize/resolve/conceptIdsOfGame/matchesSelection 语义
（口径与 dev_probe/tag_vocab_verify.dart 一致，已 18/18 对齐 Dart 端），
读取真实库 game.json → derive → 按维度输出分区 → 模拟点击筛选。
只读探针，不写任何文件。
"""
import json, glob, sys

# ---- 复刻 normalizeTag（与 store 逐字符一致） ----
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

# ---- 加载词表（真实打包数据） ----
dims = json.load(open('D:/CTLIB/assets/data/tag_dimensions.json', encoding='utf-8'))['dimensions']
vocab = json.load(open('D:/CTLIB/assets/data/tag_vocabulary.json', encoding='utf-8'))
alias_idx, concepts = {}, {c['id']: c for c in vocab['concepts']}
for c in vocab['concepts']:
    for k in [c['name']] + c.get('aliases', []):
        n = norm(k)
        if n and n not in alias_idx:
            alias_idx[n] = c['id']

def resolve(raw):
    return alias_idx.get(norm(raw))

def concept_ids_of_game(tags):
    seen = set()
    for t in tags:
        cid = resolve(t)
        if cid: seen.add(cid)
    return seen

# ---- 模拟 derive（同一游戏同概念只计一次） ----
base = r'D:/CTLIB/build/windows/x64/runner/Release/Games'
games = []
for f in glob.glob(base + '/*/game.json'):
    d = json.load(open(f, encoding='utf-8'))
    tags = [t for t in (d.get('tags') or []) if isinstance(t, str) and t.strip()]
    games.append(tags)

concept_counts, unclassified = {}, {}
for tags in games:
    seen_c, seen_u = set(), set()
    for t in tags:
        cid = resolve(t)
        if cid:
            seen_c.add(cid)
        else:
            n = norm(t)
            if n: seen_u.add(n)
    for cid in seen_c: concept_counts[cid] = concept_counts.get(cid, 0) + 1
    for n in seen_u: unclassified[n] = unclassified.get(n, 0) + 1

print('=== 场景 A：库分类匣（derive 实测） ===')
print(f'游戏数: {len(games)}  命中概念数: {len(concept_counts)}  其他分区标签: {len(unclassified)}')
total_sections = 0
for dim in dims:
    members = [(cid, concept_counts[cid]) for cid in concept_counts
               if concepts[cid]['dim'] == dim['id']]
    if not members:
        print(f"  [{dim['title']}] 0 成员 → 自动隐藏")
        continue
    members.sort(key=lambda x: -x[1])
    total_sections += 1
    sample = '、'.join(f"{concepts[cid]['name']}({n})" for cid, n in members[:6])
    print(f"  [{dim['title']}] {len(members)} 个概念将展示 | Top: {sample}")
print(f'→ 分类匣将渲染 {total_sections} 个标签分区 + 「其他」分区(Top80 封顶, 实际 {len(unclassified)})')

# ---- 模拟 matchesSelection（点击「成人内容」分区某概念筛选） ----
print()
print('=== 场景 A：筛选实测（matchesSelection 语义：维度内并集·维度间交集） ===')
for probe in ['NTR', '百合', '后宫', '凌辱', '纯爱', '泣系']:
    cid = resolve(probe)
    if cid is None:
        print(f'  点击「{probe}」→ 概念不存在'); continue
    n = sum(1 for tags in games if cid in concept_ids_of_game(tags))
    dim_title = next(d['title'] for d in dims if d['id'] == concepts[cid]['dim'])
    print(f'  点击「{probe}」（{dim_title}·{concepts[cid]["name"]}）→ 筛出 {n} 部游戏')
