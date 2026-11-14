# -*- coding: utf-8 -*-
"""会社词典扩批：把 VNDB 取回的 producer 数据落成词条草稿。

规则（沿用 company_alias_normalization.md §3 纪律）：
- company_id 从现有 max+1 开始，稳定递增，绝不复用；
- standard_name = VNDB name（优先），jp_name = original（无则同标准名）；
- cn_name：只从 VNDB aliases 里挑「含汉字且无假名」的项，否则 null（禁止编造）；
- aliases：VNDB aliases 全量并入（去标点差异、去与标准名等价项），中文俗称保留；
- status：description 命中停业/倒闭关键词才标 discontinued；
- 子品牌/母品牌关系写进 comment，不合并条目。
用法：python build_company_batch.py [--dry-run]
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPANY = ROOT / "assets" / "data" / "company_aliases.json"
SRC = ROOT / "dev_probe" / "vndb_ids.json"
IDS = ROOT / "dev_probe" / "b2_ids.txt"
REPORT = ROOT / "dev_probe" / "company_batch_report.json"

# 人工定名覆盖：VNDB 名不适合做标准名时（法人后缀、写法不一致）在此收敛
NAME_OVERRIDE = {
    "p4153": "STING",
    "p520": "Enterbrain",
    "p24097": "Seikou Soft",
    "p543": "CyberFront",
    "p365": "BLACK Cyc",
    "p507": "Dual Tail",
    "p709": "でぼの巣製作所",
    # 去掉法人后缀，统一展示名
    "p1588": "Koei Tecmo",
    "p350": "CAPCOM",
    "p352": "Idea Factory",
    "p88": "Nippon Ichi Software",
    "p5769": "Holicworks",
    "p1499": "Rejet",
    "p1424": "Vingt-et-un Systems",
    "p1078": "Red Entertainment",
    "p2361": "Design Factory",
    "p202": "coly",
    "p203": "Cheritz",
    "p210": "iMel",
    "p211": "SEEC",
    "p214": "Regista",
    "p174": "Voltage",
    "p564": "SEGA",
    "p77": "KONAMI",
    "p331": "Chunsoft",
    "p567": "Takuyo",
    "p906": "Kemco",
}

# VNDB 无独立 producer 条目、但中文圈确有检索价值的实体（手工条目，vndb_id 置空）
MANUAL = [
    dict(standard_name="Team Shanghai Alice", jp_name="上海アリス幻樂団",
         cn_name="上海爱丽丝幻乐团", vndb_id=None, status="active",
         comment="东方Project 同人社团（ZUN 个人社团）；VNDB 无独立 producer 条目，按公开通称收录",
         aliases=["上海爱丽丝幻乐团", "上海アリス幻楽団", "上海アリス幻樂団", "东方Project", "ZUN"]),
    dict(standard_name="娱乐通", jp_name=None, cn_name="娱乐通",
         vndb_id=None, status="discontinued",
         comment="北京娱乐通科技发展有限公司，2000 年代中文正版 galgame 代理发行商（红楼梦等）；据公开资料已停止相关业务",
         aliases=["Yule Tong", "Entertainment Trading"]),
]

# 人工补充别名（VNDB 没有但中文圈常用的叫法，均可举证）
EXTRA_ALIASES = {
    "p709": ["Debonosu Works", "DebonosuWorks"],
    "p21": ["Leaf社", "叶子社"],
    "p1008": ["wstar", "ωstar", "美少女万华镜社"],
    "p226": ["BaseSon", "恋姬社"],
    "p434": ["SQUEEZ", "炎孕社"],
    "p1279": ["Lose社"],
    "p403": ["Escude", "小E社"],
    "p1386": ["时钟机关社"],
    "p82": ["07th", "龙骑士07"],
    "p3312": ["Madosoft", "窗社", "窓社"],
    "p5049": ["Bug System", "毒蜜蜂"],
    "p357": ["Lass社"],
    "p390": ["Shiratama", "白玉社"],
    "p164": ["ROOT社"],
    "p170": ["Chuable Soft"],
    "p2793": ["Akabee Soft 3"],
    "p171": ["Atelier Kaguya", "竹子社"],
    "p6745": ["Milk Factory", "牛奶社"],
    "p7659": ["Qruppo"],
    "p2015": ["hibiki works"],
    "p85": ["FlyingShine"],
    "p19": ["D.O."],
    "p589": ["Otomate", "オトメイト"],
    "p242": ["light"],
    "p1741": ["Torotoro Resistance"],
}

DISCONTINUED_RE = re.compile(
    r"bankrupt|bankruptcy|closed|ceased|discontinued|defunct|dissolved|no longer|"
    r"倒産|解散|廃業|活動休止|倒閉|破产|已不复存在|doesn't exist anymore",
    re.I,
)
# cn_name 屏蔽：与母品牌/其他条目中文俗称撞键的子品牌
CN_BLOCK = {"p2693"}
KANA = re.compile(r"[\u3040-\u309F\u30A0-\u30FF]")
HAN = re.compile(r"[\u4e00-\u9fff]")


def norm(s: str) -> str:
    if not s:
        return ""
    t = re.sub(r"[\s\u3000]+", " ", s).strip()
    t = unicodedata.normalize("NFKC", t).lower()
    return t


LEGAL_SUFFIX = re.compile(
    r"株式会社|有限会社|合同会社|Inc\.?|Co\.?,?\s*Ltd\.?|Ltd\.?|Corp\.?|Corporation|Systems", re.I
)
ASCII_ONLY_RE = re.compile(r"^[A-Za-z0-9\s.\-&']*社$")


def pick_cn(aliases):
    """从别名里挑中文名：含汉字、不含假名、2-10 字、非法人全称、非「英文+社」。"""
    cands = []
    for a in aliases:
        if not (HAN.search(a) and not KANA.search(a) and 2 <= len(a) <= 10):
            continue
        if LEGAL_SUFFIX.search(a) or ASCII_ONLY_RE.match(a):
            continue
        cands.append(a)
    if not cands:
        return None
    cands.sort(key=len)
    return cands[0]


def clean_desc(d: str, limit=110):
    d = re.sub(r"\[url[^\]]*\].*?\[/url\]", "", d or "", flags=re.I)
    d = re.sub(r"\[[^\]]*\]", "", d)
    d = re.sub(r"https?://\S+", "", d)
    d = re.sub(r"\s+", " ", d).strip()
    return d[:limit]


def main():
    dry = "--dry-run" in sys.argv
    data = json.loads(SRC.read_text(encoding="utf-8"))
    ids = IDS.read_text(encoding="utf-8").split()
    comp = json.loads(COMPANY.read_text(encoding="utf-8"))
    have_vndb = {c.get("vndb_id"): c for c in comp["companies"] if c.get("vndb_id")}
    next_id = max(c["company_id"] for c in comp["companies"]) + 1

    created, skipped_exist, missing = [], [], []
    for pid in ids:
        rec = data.get(pid)
        if not isinstance(rec, dict) or not rec.get("name"):
            missing.append(pid)
            continue
        if pid in have_vndb:
            skipped_exist.append((pid, have_vndb[pid]["standard_name"]))
            continue
        name = NAME_OVERRIDE.get(pid, rec["name"])
        aliases = list(dict.fromkeys((rec.get("aliases") or []) + EXTRA_ALIASES.get(pid, [])))
        aliases = [a for a in aliases if norm(a) != norm(name)]
        aliases = [
            a for a in aliases
            if not re.fullmatch(r"(Ltd\.?|Inc\.?|Co\.?|Corp\.?|Corporation|Systems)", a.strip(), re.I)
        ]
        cn = None if pid in CN_BLOCK else pick_cn(aliases)
        if pid in CN_BLOCK:
            aliases = [a for a in aliases if norm(a) != norm("太空人社")]
        desc = clean_desc(rec.get("desc") or "")
        status = "discontinued" if DISCONTINUED_RE.search(rec.get("desc") or "") else "active"
        comp["companies"].append({
            "company_id": next_id,
            "standard_name": name,
            "jp_name": rec.get("original") or name,
            "cn_name": cn,
            "vndb_id": pid,
            "status": status,
            "successor_company_id": None,
            "comment": desc or None,
            "aliases": aliases,
        })
        created.append((next_id, name, rec.get("original"), cn, status, aliases[:4]))
        next_id += 1

    # 手工条目（VNDB 无 producer 记录但中文圈有检索价值）
    existing_names = {c["standard_name"] for c in comp["companies"]}
    for m in MANUAL:
        if m["standard_name"] in existing_names:
            continue
        comp["companies"].append({
            "company_id": next_id,
            "standard_name": m["standard_name"],
            "jp_name": m.get("jp_name") or m["standard_name"],
            "cn_name": m.get("cn_name"),
            "vndb_id": m.get("vndb_id"),
            "status": m.get("status", "active"),
            "successor_company_id": None,
            "comment": m.get("comment"),
            "aliases": m.get("aliases") or [],
        })
        created.append((next_id, m["standard_name"], m.get("jp_name"), m.get("cn_name"),
                        m.get("status", "active"), (m.get("aliases") or [])[:4]))
        next_id += 1

    # 键冲突校验
    owner, conflicts = {}, []
    for c in comp["companies"]:
        for nm in [c["standard_name"], c.get("jp_name"), c.get("cn_name")] + (c.get("aliases") or []):
            k = norm(nm)
            if not k:
                continue
            if k in owner and owner[k] != c["company_id"]:
                conflicts.append((k, owner[k], c["company_id"]))
            else:
                owner[k] = c["company_id"]

    print(f"新建 {len(created)} 家，已存在跳过 {len(skipped_exist)}，取数失败 {len(missing)}")
    for row in created:
        print(f"  {row[0]:3d} {row[1][:28]:28s} | jp={str(row[2])[:16]:16s} | cn={row[3]} | {row[4]} | {row[5]}")
    print(f"合计 {len(comp['companies'])} 家 / 键 {len(owner)}")
    if conflicts:
        print("!! 键冲突:")
        for k, a, b in conflicts:
            print(f"   {k}: {a} vs {b}")
        raise SystemExit(2)
    print("跨会社键冲突 0")
    REPORT.write_text(json.dumps({
        "created": created, "skipped": skipped_exist, "missing": missing,
        "total_companies": len(comp["companies"]), "total_keys": len(owner),
    }, ensure_ascii=False, indent=1), encoding="utf-8")

    if dry:
        print("[dry-run] 未写盘")
        return
    COMPANY.write_text(json.dumps(comp, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    again = json.loads(COMPANY.read_text(encoding="utf-8"))
    print(f"落盘复验: companies={len(again['companies'])}")


if __name__ == "__main__":
    main()
