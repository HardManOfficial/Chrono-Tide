# -*- coding: utf-8 -*-
"""B4 标签扩批：中文情感 / 季节 / 场景词族的同义写法收敛。

原则：能并入既有概念的一律并入（补别名），语义确实独立的才新建。
探索库底线（98.1%）已达标，本批是「补同族漏项」——避免补一个漏三个。
用法：python apply_tag_b4.py [--dry-run]
"""
import json
import shutil
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VOCAB = ROOT / "assets" / "data" / "tag_vocabulary.json"
DIMS = ROOT / "assets" / "data" / "tag_dimensions.json"
REPORT = ROOT / "dev_probe" / "tag_b4_report.json"

FW_START, FW_END, FW_OFF = 0xFF01, 0xFF5E, 0xFEE0
NOISE = {
    0x20, 0x09, 0x0A, 0x0D, 0x3000, 0xB7, 0x30FB, 0x2C, 0x3001, 0x3002, 0x2E,
    0x21, 0x3F, 0x7E, 0x2D, 0x2010, 0x2013, 0x2014, 0x2015, 0x5F, 0x28, 0x29,
    0x3014, 0x3015, 0x3010, 0x3011, 0x5B, 0x5D, 0x7B, 0x7D, 0x300C, 0x300D,
    0x300E, 0x300F, 0x22, 0x27, 0x3A, 0x3B, 0x2A, 0x23, 0x40, 0x26, 0x2F,
    0x5C, 0x7C,
}


def norm(s: str) -> str:
    out = []
    for ch in s.strip():
        c = ord(ch)
        if FW_START <= c <= FW_END:
            c -= FW_OFF
        if c in NOISE:
            continue
        if 0x41 <= c <= 0x5A:
            c += 0x20
        out.append(chr(c))
    return "".join(out)


NEW = [
    dict(id="el.spring", name="春天", dim="element",
         aliases=["春日", "春季", "春暖花开", "春天"],
         reason="季节词族补全（夏/秋/冬已有，缺春）"),
    dict(id="tone.bittersweet", name="苦甜交织", dim="tone",
         aliases=["苦甜", "微苦", "苦甜交织"],
         reason="介于「治愈」与「致郁」之间的观感基调，探索库高频情感词"),
]

MERGE = {
    # 季节
    "el.summer": ["盛夏", "炎夏", "暑夏", "暑假", "夏日回忆"],
    "el.winter": ["寒冬", "冬季", "雪季", "冬日回忆"],
    "el.autumn": ["深秋", "晚秋", "初秋"],
    # 舞台 / 场景
    "set.countryside": ["乡下", "农村", "田园生活", "田园牧歌", "雪乡", "雪国", "北国", "山村"],
    "set.beach": ["海滨", "沙滩", "海岸"],
    "set.school": ["学园", "高中", "中学", "学校生活", "学生生活"],
    "set.city": ["都市", "城市", "现代都市"],
    "set.cafe": ["咖啡馆", "咖啡店"],
    "el.christmas": ["圣诞夜", "平安夜"],
    "el.school_club": ["部活动"],
    "el.urban_legend": ["都市怪谈", "校园怪谈"],
    "el.cohabitation": ["同居生活", "同住"],
    # 情感 / 主题
    "th.romance": ["恋慕", "爱慕", "倾心", "爱意", "眷恋", "依恋", "恋情", "相爱"],
    "th.first_love": ["初恋情怀", "初次恋爱", "初恋故事"],
    "th.one_sided": ["暗恋", "单相思"],
    "th.reunion": ["再会", "久别重逢", "归乡", "返乡", "回乡"],
    "th.parting": ["分别", "告别"],
    "th.bond": ["牵绊", "陪伴", "厮守", "羁绊感"],
    "th.harem": ["后宫向", "后宫展开"],
    "th.reverse_harem": ["逆后宫向"],
    # 基调
    "tone.heartwarming": ["暖心", "和煦", "温馨日常"],
    "tone.utsu": ["胃痛", "沉重感"],
    "tone.tragedy": ["悲情", "哀伤"],
    "tone.healing": ["疗愈", "治愈向"],
    "tone.comedy": ["幽默", "诙谐", "喜感"],
    "tone.moe": ["萌系", "废萌日常"],
    "tone.drama": ["剧情向", "重剧情"],
    # 玩法 / 结构
    "ps.collection": ["短篇集", "选集"],
    "ps.fandisc": ["FD", "粉丝盘", "番外盘"],
    "ps.branch": ["分支剧情", "多路线", "路线分歧"],
    "ps.choices": ["选择支", "多选项"],
    "ps.multiple_protagonist": ["多视点主角"],
    # 叙事元素
    "el.loop": ["时间循环", "循环"],
    "el.timetravel": ["穿越", "时间旅行", "时空穿越"],
    # 美术音频
    "art.fullvoice": ["全程语音", "全CV"],
    "art.ost": ["原声集", "游戏音乐", "BGM"],
    "art.highcg": ["高清CG", "CG精美"],
    # 角色
    "ch.twins": ["双子", "双胞胎"],
    "ch.yamato": ["大和抚子"],
    "ch.kuudere": ["无表情"],
}


def main():
    dry = "--dry-run" in sys.argv
    vocab = json.loads(VOCAB.read_text(encoding="utf-8"))
    dims = {d["id"] for d in json.loads(DIMS.read_text(encoding="utf-8"))["dimensions"]}
    concepts = vocab["concepts"]
    by_id = {c["id"]: c for c in concepts}

    merged, skipped = [], 0
    for cid, names in MERGE.items():
        c = by_id.get(cid)
        if not c:
            raise SystemExit(f"MERGE 目标不存在: {cid}")
        for nm in names:
            if nm in c["aliases"] or norm(nm) == norm(c["name"]):
                skipped += 1
                continue
            c["aliases"].append(nm)
            merged.append((nm, cid))

    added = []
    for n in NEW:
        if n["dim"] not in dims:
            raise SystemExit(f"未注册维度: {n['dim']}")
        if n["id"] in by_id:
            continue
        concepts.append(dict(id=n["id"], name=n["name"], dim=n["dim"],
                             aliases=list(dict.fromkeys(n["aliases"]))))
        by_id[n["id"]] = concepts[-1]
        added.append(n["id"])

    owner, conflicts = {}, []
    for c in concepts:
        for nm in [c["name"]] + c["aliases"]:
            k = norm(nm)
            if not k:
                continue
            if k in owner and owner[k] != c["id"]:
                conflicts.append((k, owner[k], c["id"]))
            else:
                owner[k] = c["id"]
    if conflicts:
        print("!! 跨概念键冲突:")
        for k, a, b in conflicts:
            print(f"   {k}: {a} vs {b}")
        raise SystemExit(2)

    dist = Counter(c["dim"] for c in concepts)
    REPORT.write_text(json.dumps({
        "concepts_after": len(concepts),
        "keys_total": sum(1 + len(c["aliases"]) for c in concepts),
        "merged": merged, "merged_skipped": skipped, "new": added,
        "dim_dist": dict(dist),
    }, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"概念 {len(concepts)}，键 {sum(1 + len(c['aliases']) for c in concepts)}")
    print(f"MERGE {len(merged)}（跳过已存在 {skipped}）  NEW {len(added)}")
    print(f"维度分布 {dict(dist)}；跨概念键冲突 0")

    if dry:
        print("[dry-run] 未写盘")
        return
    shutil.copy2(VOCAB, VOCAB.with_suffix(".json.bak_b4"))
    VOCAB.write_text(json.dumps(vocab, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    again = json.loads(VOCAB.read_text(encoding="utf-8"))
    print(f"落盘复验: concepts={len(again['concepts'])}")


if __name__ == "__main__":
    main()
