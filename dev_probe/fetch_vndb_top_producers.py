# -*- coding: utf-8 -*-
"""B2 会社扩批：以 VNDB 高分作品（rating 降序 top 500）反推「名作会社」排行。

口径：某会社在 top500 高分 VN 中出现的次数 = 名作密度，作为「主流/知名」的客观代理。
输出 dev_probe/vndb_top_producers.json（含 id / name / 命中作品数 / 代表作）。
"""
import json
import time
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

API = "https://api.vndb.org/kana/vn"
OUT = Path(__file__).resolve().parent / "vndb_top_producers.json"
PAGES = 5  # 5 * 100 = top 500


def fetch(page):
    body = json.dumps(
        {
            "filters": ["rating", ">=", 10],
            "sort": "rating",
            "reverse": True,
            "fields": "id,title,rating,developers.id,developers.name",
            "results": 100,
            "page": page,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        API,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "ChronoTide/1.0 (metadata curation; contact: local)",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode("utf-8")).get("results", [])


def main():
    cnt = Counter()
    names = {}
    samples = defaultdict(list)
    total = 0
    for p in range(1, PAGES + 1):
        items = fetch(p)
        total += len(items)
        for vn in items:
            for d in vn.get("developers") or []:
                cnt[d["id"]] += 1
                names[d["id"]] = d["name"]
                if len(samples[d["id"]]) < 3:
                    samples[d["id"]].append(f"{vn['title']}({vn.get('rating')})")
        print(f"page {p}: {len(items)} items, cum {total}")
        time.sleep(2.0)
    rows = [
        {"id": pid, "name": names[pid], "count": n, "samples": samples[pid]}
        for pid, n in cnt.most_common()
    ]
    OUT.write_text(
        json.dumps({"total_vn": total, "producers": rows}, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    print(f"会社数 {len(rows)}，写入 {OUT.name}")
    for r in rows[:40]:
        print(f"  {r['count']:3d} {r['id']:7s} {r['name']}")


if __name__ == "__main__":
    main()
