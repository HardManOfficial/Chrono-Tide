# -*- coding: utf-8 -*-
"""VNDB producer 查证探针（B1 会社底线批次）。

对候选会社名逐个调用 VNDB Kana API 的 producer 搜索，保存原始结果供人工判定。
限速：每次请求间隔 1.6s（VNDB 200 req / 5 min）。
用法：python vndb_producer_probe.py out.json 候选1 候选2 ...
"""
import json
import sys
import time
import urllib.request

API = "https://api.vndb.org/kana/producer"
FIELDS = "id,name,original,aliases,lang,type,description"


def search(kw):
    body = json.dumps(
        {"filters": ["search", "=", kw], "fields": FIELDS, "results": 6}
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
        return json.loads(r.read().decode("utf-8"))


def main():
    out_path = sys.argv[1]
    kws = sys.argv[2:]
    out = {}
    try:
        out = json.load(open(out_path, encoding="utf-8"))
    except Exception:
        out = {}
    for kw in kws:
        if kw in out:
            print(f"skip {kw}")
            continue
        try:
            res = search(kw)
            out[kw] = [
                {
                    "id": x["id"],
                    "name": x["name"],
                    "original": x.get("original"),
                    "aliases": x.get("aliases") or [],
                    "lang": x.get("lang"),
                    "type": x.get("type"),
                    "desc": (x.get("description") or "").replace("\n", " ")[:160],
                }
                for x in res.get("results", [])
            ]
            print(f"OK   {kw}: {[x['id'] + '/' + x['name'] for x in out[kw]]}")
        except Exception as e:
            out[kw] = {"error": str(e)}
            print(f"ERR  {kw}: {e}")
        json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        time.sleep(1.6)


if __name__ == "__main__":
    main()
