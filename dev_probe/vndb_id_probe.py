# -*- coding: utf-8 -*-
"""按 VNDB producer id 精确取条目（含 aliases / original / description）。

用法：python vndb_id_probe.py out.json p21 p226 ...
"""
import json
import sys
import time
import urllib.request

API = "https://api.vndb.org/kana/producer"
FIELDS = "id,name,original,aliases,lang,type,description"


def get(pid):
    body = json.dumps({"filters": ["id", "=", pid], "fields": FIELDS}).encode("utf-8")
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
        res = json.loads(r.read().decode("utf-8")).get("results", [])
    return res[0] if res else None


def main():
    out_path, ids = sys.argv[1], sys.argv[2:]
    try:
        out = json.load(open(out_path, encoding="utf-8"))
    except Exception:
        out = {}
    for pid in ids:
        if pid in out and isinstance(out[pid], dict) and out[pid].get("name"):
            print(f"skip {pid}")
            continue
        try:
            r = get(pid)
            if not r:
                out[pid] = {"error": "not found"}
                print(f"MISS {pid}")
            else:
                out[pid] = {
                    "id": r["id"],
                    "name": r["name"],
                    "original": r.get("original"),
                    "aliases": r.get("aliases") or [],
                    "lang": r.get("lang"),
                    "type": r.get("type"),
                    "desc": (r.get("description") or "").replace("\n", " ")[:400],
                }
                print(f"OK   {pid} {r['name']} | {r.get('original')} | {r.get('aliases')}")
        except Exception as e:
            out[pid] = {"error": str(e)}
            print(f"ERR  {pid}: {e}")
        json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        time.sleep(1.4)


if __name__ == "__main__":
    main()
