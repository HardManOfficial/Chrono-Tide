# -*- coding: utf-8 -*-
"""第五批扩批：id 79-97（19 家）。写入后自动校验：JSON 可解析、id 唯一、跨条目归一化键冲突检查。"""
import json, re, unicodedata, sys

PATH = r"D:\CTLIB\assets\data\company_aliases.json"

def norm(s: str) -> str:
    if not s:
        return None
    t = re.sub(r"[\s\u3000]+", " ", s).strip()
    if not t:
        return None
    return unicodedata.normalize("NFKC", t).lower()

BATCH = [
    dict(standard_name="F&C Co., Ltd.", jp_name="エフアンドシー", cn_name=None, vndb_id="p80",
         status="active", comment="1997 年承接 IDES 品牌与员工；F=FairyTale、C=Cocktail Soft。近年品牌活动停滞（2017 年仍有官方博客），状态存疑待核实；旗下 Cocktail Soft 独立条目",
         aliases=["F&C", "FANDC"]),
    dict(standard_name="Cocktail Soft", jp_name="カクテル・ソフト", cn_name=None, vndb_id="p126",
         status="active", comment="F&C 旗下品牌（VNDB 别名 F&C 02）；1989 年设立，2002 年停止后 2004 年再开（维基百科沿革）",
         aliases=["カクテルソフト", "F&C 02", "Cocktail Soft"]),
    dict(standard_name="CandySoft", jp_name="きゃんでぃそふと", cn_name=None, vndb_id="p96",
         status="active", comment="维基百科记载为 INTERHEART（本库 61 号）旗下品牌；つよきす 系列；2018-2020 年仍有新作",
         aliases=["キャンディーソフト", "キャンディソフト", "Candy Soft"]),
    dict(standard_name="Cherry Soft", jp_name="ちぇりーそふと", cn_name=None, vndb_id="p784",
         status="active", comment="VNDB 无状态描述，状态未核实（保守标 active）",
         aliases=["CherrySoft"]),
    dict(standard_name="CROSSNET", jp_name="クロスネット", cn_name=None, vndb_id="p83",
         status="discontinued", comment="VNDB：已不复存在，分裂为 ApRicoT 与 FAVORITE（本库 13 号，p612）；网站 2009-05 起失效",
         aliases=["Cross net"]),
    dict(standard_name="bootUP!", jp_name=None, cn_name=None, vndb_id="p173",
         status="active", comment="合同会社ブートアップ；Aneimo 系列；GameFAQs 记录最新作 2023-12",
         aliases=["ブートアップ", "合同会社ブートアップ"]),
    dict(standard_name="Akatsuki WORKS", jp_name="暁WORKS", cn_name=None, vndb_id="p180",
         status="active", comment="Hello,world. 等；子品牌 BLACK / -響- 不并入本条",
         aliases=["晓WORKS", "Akatsuki Works"]),
    dict(standard_name="Aries", jp_name="アリエス", cn_name=None, vndb_id="p733",
         status="active", comment="与 CIRCUS 的 Aries 品牌无关（VNDB 注明），注意与 Alice Soft 区分",
         aliases=["Aries software creation"]),
    dict(standard_name="Astronauts", jp_name="アストロノーツ", cn_name=None, vndb_id="p2692",
         status="active", comment="俗称太空人社（VNDB aliases）；子品牌 Sirius/Spica/Alya/Comet 不并入（Sirius 同用「太空人社」俗称，为避免归一化键冲突只收主条目）",
         aliases=["太空人社"]),
    dict(standard_name="PeasSoft", jp_name=None, cn_name=None, vndb_id="p325",
         status="active", comment=None,
         aliases=["ピースソフト"]),
    dict(standard_name="RococoWorks", jp_name=None, cn_name=None, vndb_id="p457",
         status="discontinued", comment="Tarte 破产后由其员工成立；2011-12 解散（VNDB description）",
         aliases=["Rococo Works"]),
    dict(standard_name="rootnuko+H", jp_name="rootnuko＋Ｈ", cn_name=None, vndb_id="p2771",
         status="active", comment="全年龄主品牌 rootnuko（p1018）不并入本条",
         aliases=["√nuko+H", "root nuko+H"]),
    dict(standard_name="Rosebleu", jp_name=None, cn_name=None, vndb_id="p518",
         status="active", comment="由原 Navel 员工创立的品牌（VNDB description）",
         aliases=["ロゼブル"]),
    dict(standard_name="SILKY'S", jp_name="シルキーズ", cn_name=None, vndb_id="p254",
         status="active", comment="elf 系品牌；SILKY'S PLUS 独立条目",
         aliases=[]),
    dict(standard_name="SILKY'S PLUS", jp_name="シルキーズプラス", cn_name=None, vndb_id="p4449",
         status="active", comment="9 -nine- 系列；俗称シルプラ（VNDB aliases）",
         aliases=["シルプラ"]),
    dict(standard_name="Silver Bullet", jp_name=None, cn_name=None, vndb_id="p330",
         status="active", comment="俗称银弹社（VNDB aliases）；暁の護衛 系列",
         aliases=["银弹社", "シルバーバレット"]),
    dict(standard_name="SofthouseChara", jp_name="ソフトハウスキャラ", cn_name=None, vndb_id="p211",
         status="active", comment="中文俗称直接采自 VNDB aliases（软屋社/软房社/伽羅社等）",
         aliases=["Softhouse Chara", "shchara", "软屋社", "软房社", "软房子", "伽羅社"]),
    dict(standard_name="Windmill", jp_name="ういんどみる", cn_name=None, vndb_id="p221",
         status="active", comment="俗称风车社；子品牌 Oasis 独立条目",
         aliases=["风车社"]),
    dict(standard_name="Windmill Oasis", jp_name="ういんどみる Oasis", cn_name=None, vndb_id="p2316",
         status="active", comment="Windmill 旗下品牌",
         aliases=["Windmill Oasis"]),
]

data = json.load(open(PATH, encoding="utf-8"))
companies = data["companies"]
existing_ids = {c["company_id"] for c in companies}
existing_names = {norm(c["standard_name"]) for c in companies}

# 前置校验：不重复、不与现有主名冲突
next_id = max(existing_ids) + 1
assert next_id == 79, f"期望 next_id=79，实际 {next_id}"
for i, b in enumerate(BATCH):
    if norm(b["standard_name"]) in existing_names:
        sys.exit(f"FATAL: {b['standard_name']} 与现有主名冲突")

for b in BATCH:
    companies.append({
        "company_id": next_id,
        "standard_name": b["standard_name"],
        "jp_name": b["jp_name"],
        "cn_name": b["cn_name"],
        "vndb_id": b["vndb_id"],
        "status": b["status"],
        "successor_company_id": None,
        "comment": b["comment"],
        "aliases": b["aliases"],
    })
    next_id += 1

data["updated_at"] = "2026-09-29"
json.dump(data, open(PATH, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

# ===== 写后校验 =====
d2 = json.load(open(PATH, encoding="utf-8"))
ids = [c["company_id"] for c in d2["companies"]]
assert len(ids) == len(set(ids)), "company_id 重复"
assert len(d2["companies"]) == 97, f"总数 {len(d2['companies'])} != 97"

keys = {}
conflicts = []
for c in d2["companies"]:
    cid = c["company_id"]
    names = [c["standard_name"], c.get("jp_name"), c.get("cn_name")] + (c.get("aliases") or [])
    for n in names:
        if not n:
            continue
        k = norm(n)
        if not k:
            continue
        if k in keys and keys[k] != cid:
            conflicts.append((k, keys[k], cid))
        keys[k] = cid
assert not conflicts, f"键冲突: {conflicts}"

disc = [c["standard_name"] for c in d2["companies"] if c["status"] == "discontinued"]
cn = sum(1 for c in d2["companies"] if c.get("cn_name"))
al = sum(1 for c in d2["companies"] for _ in (c.get("aliases") or []))
print(f"OK: 97 家 / {len(keys)} 键 / 0 冲突 / cn_name {cn} 家 / discontinued {len(disc)} 家: {disc}")
print(f"第五批新增别名总数: {sum(len(b['aliases']) for b in BATCH)}")
