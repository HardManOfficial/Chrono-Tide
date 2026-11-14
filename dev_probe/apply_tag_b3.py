# -*- coding: utf-8 -*-
"""B3 标签底线：把探索库 180 个未归类标签落位到 9 维。

三类决策：
  MERGE  -> 追加为该概念的别名（语义已被既有概念覆盖）
  NEW    -> 新建概念（含同族别名，一次收干净）
  DROP   -> 刻意不收（作品特化营销标签 / 无效值），进「其他」分区并输出清理清单

纪律：一个概念一个维度；跨概念归一化键冲突必须为 0；幂等（可重复运行）。
用法：python apply_tag_b3.py [--dry-run]
"""
import json
import shutil
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VOCAB = ROOT / "assets" / "data" / "tag_vocabulary.json"
DIMS = ROOT / "assets" / "data" / "tag_dimensions.json"
REPORT = ROOT / "dev_probe" / "tag_b3_report.json"

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


# ---------------------------------------------------------------- 并入既有概念
MERGE = {
    "回合战": "ps.turn_based",
    "夏日": "el.summer",
    "爱恋": "th.romance",
    "幸福": "tone.heartwarming",
    "争霸": "el.war",
    "权谋": "el.politics",
    "推理剧": "tone.mystery",
    "学院": "set.school",
    "相伴": "th.bond",
    "心动": "th.romance",
    "寄宿": "set.dorm",
    "乡土": "set.countryside",
    "伤痛": "tone.utsu",
    "归途": "th.reunion",
    "澄空学园": "set.school",
    "约会": "th.romance",
    "相守": "th.bond",
    "温存": "tone.heartwarming",
    "相恋": "th.romance",
    "恋曲": "th.romance",
    "音乐": "el.music",
    "运动": "ps.sports",
    "冬日": "el.winter",
    "惜别": "th.parting",
    "时空": "el.timetravel",
    "热恋": "th.romance",
    "青涩": "tone.youth",
    "追梦": "th.self_discovery",
    "秘闻": "el.secret",
    "公寓互动": "el.cohabitation",
    "重制": "el.remake",
    "小镇": "set.countryside",
    "咖啡店物语": "set.cafe",
    "西幻": "set.fantasy",
    "异能战斗": "el.superpower",
    "人鱼诅咒": "el.curse",
    "婚后": "th.marriage",
    "抉择": "ps.choices",
    "思念": "th.one_sided",
    "追寻": "th.self_discovery",
    "探寻": "th.self_discovery",
    "寻我": "th.self_discovery",
    "使命追寻": "th.self_discovery",
    "和解": "th.redemption",
    "理解": "th.bond",
    "沟通": "th.bond",
    "寻真": "el.secret",
    "谎言": "el.secret",
    "求生": "ps.survival",
    "异界": "set.isekai",
    "沉沦": "tone.dark",
    "挣扎": "tone.dark",
    "怪谈": "el.urban_legend",
    "禁恋": "th.ethics",
    "虚妄": "tone.nihilism",
    "博弈": "el.battle_of_wits",
    "斗智": "el.battle_of_wits",
    "悸动": "th.romance",
    "温情": "tone.heartwarming",
    "情感向": "th.romance",
    "多男主": "th.reverse_harem",
    "雪镇": "set.countryside",
    "雪山": "set.countryside",
    "乡间": "set.countryside",
    "圣诞": "el.christmas",
    "海岛": "set.island",
    "多线叙事": "ps.branch",
    "文学感": "art.literary",
    "梦世界": "el.dream",
    "特摄": "el.hero_team",
    "部活": "el.school_club",
    "氛围向": "tone.atmosphere",
    "悲恋": "tone.tragedy",
    "STG": "ps.shooting",
    "别离": "th.parting",
    "轮回宿命": "el.loop",
    "暗杀": "el.murder",
    "枪战": "el.battle",
    "奇幻战斗": "el.battle",
    "古风": "set.ancient_china",
    "大观园": "set.ancient_china",
    "时间回溯": "el.timetravel",
    "种田": "ps.business",
    "谍战": "el.stealth",
    "青涩初恋": "th.first_love",
    "初中往事": "set.school",
    "追加短篇": "ps.short_form",
    "悬疑猎奇": "tone.grotesque",
    "暗夜罪案": "el.crime",
    "平行校园": "el.parallel",
    "放学": "set.school",
}

# ---------------------------------------------------------------- 新建概念
NEW = [
    dict(id="ps.afterstory", name="后日谈", dim="playstyle",
         aliases=["后日谈", "后日谈篇", "AfterStory", "后日谈剧情"],
         reason="主线结局之后的追加篇章，与「续篇/前传/番外」同族的篇章形态"),
    dict(id="ps.sequel", name="续篇", dim="playstyle",
         aliases=["续篇", "续作", "续集", "正统续作"],
         reason="系列正统后续作品，用户按篇章顺序检索"),
    dict(id="ps.prequel", name="前传", dim="playstyle",
         aliases=["前传", "前日谈", "前篇"],
         reason="时间线在正传之前的作品"),
    dict(id="ps.spinoff", name="番外", dim="playstyle",
         aliases=["番外", "外传", "番外篇", "Spin-off"],
         reason="脱离主线的支线作品"),
    dict(id="ps.collection", name="合集", dim="playstyle",
         aliases=["合集", "总集篇", "合集篇", "合集版"],
         reason="多部作品打包合集"),
    dict(id="th.emotional_tangle", name="情感纠葛", dim="theme",
         aliases=["情感纠葛", "纠葛", "感情纠葛"],
         reason="多角关系与内心拉扯，比「三角恋」更宽的母题"),
    dict(id="th.life_death", name="生死", dim="theme",
         aliases=["生死", "死生", "生死观"],
         reason="以生死抉择为核心命题"),
    dict(id="th.human_nature", name="人性", dim="theme",
         aliases=["人性", "人心", "人间性"],
         reason="以人性拷问为母题"),
    dict(id="th.long_distance", name="异地恋", dim="theme",
         aliases=["异地", "异地恋", "远距离恋爱"],
         reason="空间阻隔下的恋爱关系"),
    dict(id="th.encounter", name="邂逅", dim="theme",
         aliases=["邂逅", "初遇", "初相识", "相遇", "相逢"],
         reason="以相遇本身为情感主题（区别于「重逢」）"),
    dict(id="el.legend", name="传说", dim="element",
         aliases=["传说", "传奇", "秘闻传说"],
         reason="围绕传说/传承展开的叙事装置"),
    dict(id="el.folklore", name="民俗传说", dim="element",
         aliases=["民俗传说", "乡土传说"],
         reason="民俗学母题（与「都市传说」互为乡土/都市两极）"),
    dict(id="el.conquest", name="征服支配", dim="element",
         aliases=["征服", "制霸", "支配"],
         reason="势力扩张与支配关系，区别于「战争」的宏观叙事"),
    dict(id="el.rebellion", name="反抗", dim="element",
         aliases=["抗争", "抗命", "反抗", "叛变", "起义"],
         reason="对权威/命运的抗争"),
    dict(id="el.disguise", name="伪装", dim="element",
         aliases=["伪装", "假身份", "易容"],
         reason="身份伪装与假面设定，独立于「秘密」"),
    dict(id="el.prophecy", name="预言", dim="element",
         aliases=["预言", "宿命预言"],
         reason="预言驱动的宿命叙事，独立于泛化的「命运」"),
    dict(id="el.body_swap", name="意识交换", dim="element",
         aliases=["意识交换", "身心交换"],
         reason="交换身体/意识，区别于「附身」与「性别转换」"),
    dict(id="el.autumn", name="秋天", dim="element",
         aliases=["秋日", "秋季", "秋天", "红叶"],
         reason="季节词族补全（既有夏/冬，缺秋）"),
    dict(id="tone.nostalgia", name="怀旧", dim="tone",
         aliases=["怀旧", "追忆", "乡愁"],
         reason="整体观感的怀旧基调"),
    dict(id="tone.loneliness", name="孤独", dim="tone",
         aliases=["孤独", "孤寂", "封闭"],
         reason="孤立感基调，独立于「郁系」"),
    dict(id="tone.hope", name="希望", dim="tone",
         aliases=["希望", "祈愿", "憧憬"],
         reason="正向希冀基调，与「治愈」区分"),
    dict(id="tone.realism", name="现实主义", dim="tone",
         aliases=["现实", "现实向"],
         reason="写实取向的叙事基调"),
    dict(id="art.good_art", name="美术优秀", dim="art",
         aliases=["美术", "美术优秀", "精美美术", "作画优秀"],
         reason="探索库用「美术」直接评价作画水准"),
    dict(id="ch.quintuplets", name="五胞胎", dim="character",
         aliases=["五胞胎"],
         reason="角色身份特征（姊妹设定检索）"),
    dict(id="ad.medical_exam", name="身体检查", dim="adult",
         aliases=["体检", "身体检查", "健康检查"],
         reason="R18 场景类型"),
    dict(id="age.teen", name="15+", dim="age",
         aliases=["15+", "15禁", "15岁以上"],
         reason="分级词族补全（既有全年龄/R18）"),
    dict(id="set.starry_night", name="星空", dim="setting",
         aliases=["星空", "星夜", "满天星", "繁星"],
         reason="场景意象，独立于「天文学」学科母题"),
]

# ---------------------------------------------------------------- 刻意不收
DROP_REASON = {
    "作品特化": "作品专属营销标签，无通用检索价值",
    "无效值": "写法无效或复合标签，建议 PB 侧规范",
}
DROP = {
    # 作品特化（副标题式 / 专有名词）
    "魔法秘录": "作品特化", "时钟": "作品特化", "地月": "作品特化",
    "蜜色任务": "作品特化", "水城": "作品特化", "七日": "作品特化",
    "东方": "作品特化", "向日葵": "作品特化", "宝石意志": "作品特化",
    "宝石誓约": "作品特化", "匣中余响": "作品特化", "白河萤视角": "作品特化",
    "萤光初遇": "作品特化", "盛夏心结": "作品特化", "秋忆救赎": "作品特化",
    "雪下残梦": "作品特化", "孽缘缠劫": "作品特化", "悲愿流转": "作品特化",
    "生死哀歌": "作品特化", "浮生幻梦": "作品特化", "空寂恋念": "作品特化",
    "时间恋曲": "作品特化", "夏日甜梦": "作品特化", "夏日相伴": "作品特化",
    "夏日归乡": "作品特化", "命运悲歌": "作品特化", "平行校园": "作品特化",
    "双篇忆曲": "作品特化", "三篇章": "作品特化", "雨后余思": "作品特化",
    "记忆幻梦": "作品特化", "时空宿命": "作品特化", "恋之奇迹": "作品特化",
    "恋之救赎": "作品特化", "爱之抉择": "作品特化", "执念": "作品特化",
    "约定": "作品特化", "异象": "作品特化", "灾难": "作品特化",
    "死生观": "作品特化", "任务": "作品特化", "使命追寻": "作品特化",
    # 无效 / 复合 / 评判类
    "完结": "无效值", "收束": "无效值", "整合": "无效值",
    "IF 线": "无效值", "if": "无效值",
    "同居全年龄": "无效值", "实验性": "无效值", "杂学": "无效值",
    "晦涩": "无效值", "神作": "无效值", "多时代": "无效值",
    "直播": "无效值", "同级": "无效值", "救世": "无效值",
}


def main():
    dry = "--dry-run" in sys.argv
    vocab = json.loads(VOCAB.read_text(encoding="utf-8"))
    dims = {d["id"] for d in json.loads(DIMS.read_text(encoding="utf-8"))["dimensions"]}
    concepts = vocab["concepts"]
    by_id = {c["id"]: c for c in concepts}

    # 1) MERGE
    merged, skipped_merge = [], []
    for raw, cid in MERGE.items():
        c = by_id.get(cid)
        if not c:
            raise SystemExit(f"MERGE 目标概念不存在: {cid}")
        if raw in c["aliases"] or norm(raw) == norm(c["name"]):
            skipped_merge.append(raw)
            continue
        c["aliases"].append(raw)
        merged.append((raw, cid))

    # 2) NEW
    added, skipped_new = [], []
    for n in NEW:
        if n["dim"] not in dims:
            raise SystemExit(f"未注册维度: {n['dim']}")
        if n["id"] in by_id:
            skipped_new.append(n["id"])
            continue
        concepts.append(
            dict(id=n["id"], name=n["name"], dim=n["dim"], aliases=list(dict.fromkeys(n["aliases"])))
        )
        by_id[n["id"]] = concepts[-1]
        added.append(n["id"])

    # 3) 冲突校验（先到先得口径下必须为 0）
    owner = {}
    conflicts = []
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

    ids = [c["id"] for c in concepts]
    assert len(ids) == len(set(ids)), "id 重复"

    dist = Counter(c["dim"] for c in concepts)
    report = {
        "concepts_before": len(concepts) - len(added),
        "concepts_after": len(concepts),
        "aliases_total": sum(1 + len(c["aliases"]) for c in concepts),
        "dim_dist": dict(dist),
        "merged": merged,
        "merged_skipped": skipped_merge,
        "new": added,
        "new_skipped": skipped_new,
        "drop": DROP,
    }
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"概念 {report['concepts_before']} -> {report['concepts_after']}")
    print(f"匹配键总数 {report['aliases_total']}")
    print(f"MERGE {len(merged)} 条（跳过已存在 {len(skipped_merge)}）")
    print(f"NEW   {len(added)} 个（跳过已存在 {len(skipped_new)}）")
    print(f"DROP  {len(DROP)} 条")
    print(f"维度分布 {dict(dist)}")
    print("跨概念键冲突 0")

    if dry:
        print("[dry-run] 未写盘")
        return

    shutil.copy2(VOCAB, VOCAB.with_suffix(".json.bak_b3"))
    VOCAB.write_text(
        json.dumps(vocab, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    # 复验（防「报成功未落盘」）
    again = json.loads(VOCAB.read_text(encoding="utf-8"))
    print(f"落盘复验: concepts={len(again['concepts'])} 首条={again['concepts'][0]['id']}")


if __name__ == "__main__":
    main()
