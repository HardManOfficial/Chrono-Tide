# -*- coding: utf-8 -*-
"""审计：探索库（PB games 集合）对现有会社词典 / 标签词表的覆盖率。

只读脚本。复刻 Dart 侧归一化口径：
- 会社 company_alias_store.normalize: trim -> 空白折叠 -> 全角ASCII转半角 -> A-Z 小写
- 标签 tag_vocabulary_store.normalizeTag: trim -> 全角转半角 -> 小写 -> 去噪声字符
用法：python audit_ct_coverage.py
"""
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DUMP = ROOT / "dev_probe" / "ct_explore_dump.json"
COMPANY = ROOT / "assets" / "data" / "company_aliases.json"
VOCAB = ROOT / "assets" / "data" / "tag_vocabulary.json"
DIMS = ROOT / "assets" / "data" / "tag_dimensions.json"

FW_START, FW_END, FW_OFF = 0xFF01, 0xFF5E, 0xFEE0

NOISE = {
    0x20, 0x09, 0x0A, 0x0D,
    0x3000,
    0xB7, 0x30FB,
    0x2C,
    0x3001, 0x3002,
    0x2E,
    0x21, 0x3F,
    0x7E,
    0x2D, 0x2010, 0x2013, 0x2014, 0x2015,
    0x5F,
    0x28, 0x29, 0x3014, 0x3015, 0x3010, 0x3011,
    0x5B, 0x5D, 0x7B, 0x7D,
    0x300C, 0x300D, 0x300E, 0x300F,
    0x22, 0x27,
    0x3A, 0x3B,
    0x2A, 0x23, 0x40, 0x26, 0x2F, 0x5C, 0x7C,
}


def norm_company(raw: str) -> str:
    s = raw.strip()
    if not s:
        return ""
    s = re.sub(r"[\s\u3000]+", " ", s)
    out = []
    for ch in s:
        c = ord(ch)
        if FW_START <= c <= FW_END:
            c -= FW_OFF
        if 0x41 <= c <= 0x5A:
            c += 0x20
        out.append(chr(c))
    return "".join(out)


def norm_tag(raw: str) -> str:
    s = raw.strip()
    if not s:
        return ""
    out = []
    for ch in s:
        c = ord(ch)
        if FW_START <= c <= FW_END:
            c -= FW_OFF
        if c in NOISE:
            continue
        if 0x41 <= c <= 0x5A:
            c += 0x20
        out.append(chr(c))
    return "".join(out)


def load_company_index():
    data = json.loads(COMPANY.read_text(encoding="utf-8"))
    idx = {}
    for c in data["companies"]:
        names = [c["standard_name"], c.get("jp_name"), c.get("cn_name")]
        names += c.get("aliases") or []
        for n in names:
            if not n:
                continue
            k = norm_company(n)
            if k and k not in idx:
                idx[k] = c["company_id"]
    return data, idx


def load_tag_index():
    data = json.loads(VOCAB.read_text(encoding="utf-8"))
    idx = {}
    for c in data["concepts"]:
        for n in [c["name"]] + (c.get("aliases") or []):
            k = norm_tag(n)
            if k and k not in idx:
                idx[k] = c["id"]
    return data, idx


def main():
    games = json.loads(DUMP.read_text(encoding="utf-8"))
    cdata, cidx = load_company_index()
    vdata, tidx = load_tag_index()
    dims = {d["id"]: d["title"] for d in json.loads(DIMS.read_text(encoding="utf-8"))["dimensions"]}
    concepts = {c["id"]: c for c in vdata["concepts"]}

    print("=" * 78)
    print(f"探索库记录数: {len(games)}")
    print(f"会社词典: {len(cdata['companies'])} 家 / {len(cidx)} 归一键")
    print(f"标签词表: {len(vdata['concepts'])} 概念 / {len(tidx)} 归一键")
    print("=" * 78)

    # ---------------- 会社 ----------------
    dev_records = [g for g in games if (g.get("Developer") or "").strip()]
    norm_counter = Counter()
    display = {}
    hit_records = 0
    c_miss = Counter()
    c_miss_display = {}
    for g in dev_records:
        raw = g["Developer"].strip()
        k = norm_company(raw)
        norm_counter[k] += 1
        display.setdefault(k, raw)
        if k in cidx:
            hit_records += 1
        else:
            c_miss[k] += 1
            c_miss_display.setdefault(k, raw)

    print(f"\n【会社】有会社字段记录: {len(dev_records)}/{len(games)}")
    print(f"  唯一会社（归一后）: {len(norm_counter)}")
    print(f"  记录级命中: {hit_records}/{len(dev_records)} = {hit_records/len(dev_records)*100:.1f}%")
    uk_hit = len(norm_counter) - len(c_miss)
    print(f"  唯一值命中: {uk_hit}/{len(norm_counter)} = {uk_hit/len(norm_counter)*100:.1f}%")
    print(f"  未命中唯一值: {len(c_miss)} 个，涉及 {sum(c_miss.values())} 条记录")
    print("\n  未命中 TOP 60（按记录数）：")
    for k, n in c_miss.most_common(60):
        print(f"    {n:3d}  {c_miss_display[k]}")

    # ---------------- 标签 ----------------
    tag_counter = Counter()
    tag_display = {}
    total_tag_occ = 0
    hit_occ = 0
    miss_by_norm = Counter()
    miss_display = {}
    games_miss_all = 0
    for g in games:
        raw_tags = g.get("tags") or []
        if isinstance(raw_tags, str):
            raw_tags = [x.strip() for x in re.split(r"[,，、]", raw_tags) if x.strip()]
        seen_hit = False
        for raw in raw_tags:
            raw = (raw or "").strip()
            if not raw:
                continue
            total_tag_occ += 1
            k = norm_tag(raw)
            if not k:
                continue
            tag_counter[k] += 1
            tag_display.setdefault(k, raw)
            if k in tidx:
                hit_occ += 1
                seen_hit = True
            else:
                miss_by_norm[k] += 1
                miss_display.setdefault(k, raw)
        if not seen_hit:
            games_miss_all += 1

    print(f"\n【标签】标签出现总次数: {total_tag_occ}")
    print(f"  唯一标签（归一后）: {len(tag_counter)}")
    print(f"  出现次数级命中: {hit_occ}/{total_tag_occ} = {hit_occ/total_tag_occ*100:.1f}%")
    uk_hit = len(tag_counter) - len(miss_by_norm)
    print(f"  唯一标签级命中: {uk_hit}/{len(tag_counter)} = {uk_hit/len(tag_counter)*100:.1f}%")
    print(f"  未归类唯一标签: {len(miss_by_norm)} 个，涉及 {sum(miss_by_norm.values())} 次出现")
    print(f"  「全部标签都未归类」的作品: {games_miss_all}/{len(games)}")
    print("\n  未归类 TOP 120（按出现次数）：")
    for k, n in miss_by_norm.most_common(120):
        print(f"    {n:3d}  {miss_display[k]}")

    # 命中标签的维度分布
    dim_occ = Counter()
    for k, n in tag_counter.items():
        cid = tidx.get(k)
        if cid:
            dim_occ[concepts[cid]["dim"]] += n
    print("\n  探索库命中的维度分布（按出现次数）：")
    for d, n in dim_occ.most_common():
        print(f"    {dims.get(d, d):8s} {d:12s} {n:5d}")

    # 同义词冗余：探索库中多个原始写法落到同一概念
    by_concept = defaultdict(set)
    for k in tag_counter:
        cid = tidx.get(k)
        if cid:
            by_concept[cid].add(tag_display[k])
    multi = [(cid, v) for cid, v in by_concept.items() if len(v) > 1]
    print(f"\n  多写法收敛到同一概念的概念数: {len(multi)}")
    for cid, v in sorted(multi, key=lambda x: -len(x[1]))[:15]:
        print(f"    {concepts[cid]['name']}({cid}): {' / '.join(sorted(v))}")

    # 导出未命中明细供后续扩词
    out = {
        "total_games": len(games),
        "company": {
            "records_with_dev": len(dev_records),
            "unique": len(norm_counter),
            "record_hit_rate": round(hit_records / len(dev_records), 4) if dev_records else 0,
            "missing": [{"raw": c_miss_display[k], "norm": k, "count": n} for k, n in c_miss.most_common()],
        },
        "tag": {
            "total_occ": total_tag_occ,
            "unique": len(tag_counter),
            "occ_hit_rate": round(hit_occ / total_tag_occ, 4) if total_tag_occ else 0,
            "missing": [{"raw": miss_display[k], "norm": k, "count": n} for k, n in miss_by_norm.most_common()],
        },
    }
    (ROOT / "dev_probe" / "ct_coverage_report.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print("\n明细已写入 dev_probe/ct_coverage_report.json")


if __name__ == "__main__":
    main()
