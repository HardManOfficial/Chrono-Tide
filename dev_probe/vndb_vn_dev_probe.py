# -*- coding: utf-8 -*-
"""按作品名反查 VNDB 的开发者（用于确定会社 id）。

用法：python vndb_vn_dev_probe.py 作品名1 作品名2 ...
"""
import json
import sys
import time
import urllib.request

API = "https://api.vndb.org/kana/vn"


def search(kw):
    body = json.dumps(
        {
            "filters": ["search", "=", kw],
            "fields": "id,title,alttitle,released,developers.id,developers.name",
            "results": 5,
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
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8")).get("results", [])


def main():
    for kw in sys.argv[1:]:
        try:
            res = search(kw)
            print(f"=== {kw} → {len(res)} 命中")
            for vn in res:
                devs = ", ".join(f"{d['id']}/{d['name']}" for d in vn.get("developers") or [])
                print(f"   {vn['id']} {vn['title']} ({vn.get('released')})  dev={devs}")
        except Exception as e:
            print(f"=== {kw} ERR {e}")
        time.sleep(1.5)


if __name__ == "__main__":
    main()
