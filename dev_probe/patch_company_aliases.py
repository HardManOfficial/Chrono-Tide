# -*- coding: utf-8 -*-
"""B1 会社底线：给既有词条追加「探索库里的写法变体」别名（不改词条本体）。

只做别名补充——归一化逻辑与 company_id 一概不动，零回归风险。
用法：python patch_company_aliases.py [--dry-run]
"""
import json
import sys
import unicodedata
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPANY = ROOT / "assets" / "data" / "company_aliases.json"

# standard_name -> 探索库实际写法（原样收录，靠 normalize 折叠全半角/大小写）
PATCH = {
    "Alice Soft": ["AliceSoft(A社）", "AliceSoft", "A社"],
    "MAGES.": ["5pb", "5pb."],
    "Eushully": ["Eushully(E社）", "E社"],
    "Cabbage Soft": ["Cabbage-Soft"],
    "Frontwing": ["Front Wing 前翼社", "Front Wing", "前翼社"],
    "Yuzusoft SOUR": ["ゆずソフトSOUR（酸柚子）", "酸柚子"],
    "Xuse": ["ザウス【純米】", "ザウス"],
    "NEKO WORKs": ["NEKO工作室"],
    "Uguisu Kagura": ["莺神乐", "鶯神楽"],
    "Seikou Soft": ["Seikou Soft."],
    "Lass": ["Lass Lunatic", "ラス"],
}


def norm(s: str) -> str:
    t = re.sub(r"[\s\u3000]+", " ", (s or "").strip())
    return unicodedata.normalize("NFKC", t).lower()


def main():
    dry = "--dry-run" in sys.argv
    data = json.loads(COMPANY.read_text(encoding="utf-8"))
    by_name = {c["standard_name"]: c for c in data["companies"]}
    added, skipped, missing = [], 0, []

    for name, alts in PATCH.items():
        c = by_name.get(name)
        if not c:
            missing.append(name)
            continue
        for a in alts:
            if norm(a) in {norm(x) for x in ([c["standard_name"], c.get("jp_name"), c.get("cn_name")] + c["aliases"])}:
                skipped += 1
                continue
            c["aliases"].append(a)
            added.append((name, a))

    owner, conflicts = {}, []
    for c in data["companies"]:
        for nm in [c["standard_name"], c.get("jp_name"), c.get("cn_name")] + (c.get("aliases") or []):
            k = norm(nm)
            if not k:
                continue
            if k in owner and owner[k] != c["company_id"]:
                conflicts.append((k, owner[k], c["company_id"]))
            else:
                owner[k] = c["company_id"]

    print(f"追加别名 {len(added)} 条（跳过重复 {skipped}）；未找到词条 {missing}")
    for n, a in added:
        print(f"  {n}  <=  {a}")
    print(f"键总数 {len(owner)}")
    if conflicts:
        print("!! 冲突:")
        for k, a, b in conflicts:
            print(f"   {k}: {a} vs {b}")
        raise SystemExit(2)
    print("跨会社键冲突 0")
    if dry:
        print("[dry-run] 未写盘")
        return
    COMPANY.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"落盘复验: companies={len(json.loads(COMPANY.read_text(encoding='utf-8'))['companies'])}")


if __name__ == "__main__":
    main()
