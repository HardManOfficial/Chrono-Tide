# -*- coding: utf-8 -*-
"""数据自检：会社词典 / 标签词表的结构不变量（扩批后必跑）。"""
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
C = ROOT / "assets" / "data" / "company_aliases.json"
V = ROOT / "assets" / "data" / "tag_vocabulary.json"
D = ROOT / "assets" / "data" / "tag_dimensions.json"


def cnorm(s):
    t = re.sub(r"[\s\u3000]+", " ", (s or "").strip())
    return unicodedata.normalize("NFKC", t).lower()


FW_START, FW_END, FW_OFF = 0xFF01, 0xFF5E, 0xFEE0
NOISE = {0x20, 0x09, 0x0A, 0x0D, 0x3000, 0xB7, 0x30FB, 0x2C, 0x3001, 0x3002, 0x2E,
         0x21, 0x3F, 0x7E, 0x2D, 0x2010, 0x2013, 0x2014, 0x2015, 0x5F, 0x28, 0x29,
         0x3014, 0x3015, 0x3010, 0x3011, 0x5B, 0x5D, 0x7B, 0x7D, 0x300C, 0x300D,
         0x300E, 0x300F, 0x22, 0x27, 0x3A, 0x3B, 0x2A, 0x23, 0x40, 0x26, 0x2F,
         0x5C, 0x7C}


def tnorm(s):
    out = []
    for ch in (s or "").strip():
        c = ord(ch)
        if FW_START <= c <= FW_END:
            c -= FW_OFF
        if c in NOISE:
            continue
        if 0x41 <= c <= 0x5A:
            c += 0x20
        out.append(chr(c))
    return "".join(out)


def main():
    ok = True
    comp = json.loads(C.read_text(encoding="utf-8"))
    ids = [c["company_id"] for c in comp["companies"]]
    vids = [c["vndb_id"] for c in comp["companies"] if c.get("vndb_id")]
    print(f"[会社] format_version={comp.get('format_version')} 条目={len(ids)}")
    print(f"  id 唯一: {len(ids) == len(set(ids))}；vndb_id 唯一: {len(vids) == len(set(vids))}")
    if len(ids) != len(set(ids)) or len(vids) != len(set(vids)):
        ok = False
    empty = [c["standard_name"] for c in comp["companies"] if not (c["standard_name"] or "").strip()]
    print(f"  空标准名: {len(empty)}")
    owner, conflicts = {}, []
    for c in comp["companies"]:
        for nm in [c["standard_name"], c.get("jp_name"), c.get("cn_name")] + (c.get("aliases") or []):
            k = cnorm(nm)
            if not k:
                continue
            if k in owner and owner[k] != c["company_id"]:
                conflicts.append((k, owner[k], c["company_id"]))
            else:
                owner[k] = c["company_id"]
    print(f"  归一键 {len(owner)}；跨会社键冲突 {len(conflicts)}")
    for k, a, b in conflicts[:10]:
        print(f"    {k}: {a} vs {b}")
    if conflicts or empty:
        ok = False
    st = Counter(c.get("status") for c in comp["companies"])
    print(f"  状态分布 {dict(st)}")

    vocab = json.loads(V.read_text(encoding="utf-8"))
    dims = {d["id"] for d in json.loads(D.read_text(encoding="utf-8"))["dimensions"]}
    concepts = vocab["concepts"]
    cids = [c["id"] for c in concepts]
    print(f"[标签] format_version={vocab.get('format_version')} 概念={len(concepts)}")
    print(f"  id 唯一: {len(cids) == len(set(cids))}")
    bad_dim = [c["id"] for c in concepts if c["dim"] not in dims]
    print(f"  未注册维度: {len(bad_dim)} {bad_dim[:5]}")
    owner2, conflicts2 = {}, []
    for c in concepts:
        for nm in [c["name"]] + (c.get("aliases") or []):
            k = tnorm(nm)
            if not k:
                continue
            if k in owner2 and owner2[k] != c["id"]:
                conflicts2.append((k, owner2[k], c["id"]))
            else:
                owner2[k] = c["id"]
    print(f"  归一键 {len(owner2)}；跨概念键冲突 {len(conflicts2)}")
    for k, a, b in conflicts2[:10]:
        print(f"    {k}: {a} vs {b}")
    if conflicts2 or bad_dim or len(cids) != len(set(cids)):
        ok = False
    dist = Counter(c["dim"] for c in concepts)
    print(f"  维度分布 {dict(sorted(dist.items()))}")
    empty_name = [c["id"] for c in concepts if not (c.get("name") or "").strip()]
    print(f"  空规范名: {len(empty_name)}")
    if empty_name:
        ok = False
    print("\n结论:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
