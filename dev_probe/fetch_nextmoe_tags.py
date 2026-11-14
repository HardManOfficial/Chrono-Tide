# -*- coding: utf-8 -*-
"""全量拉取 NextMoe 标签目录（/v2/catalog/tags），作为词表扩充的基准语料。

用法：python dev_probe/fetch_nextmoe_tags.py
输出：dev_probe/nextmoe_tags_full.json
"""
import json, time, urllib.request, urllib.error, os, sys

API = 'https://api.nextmoe.dev/v2/catalog/tags'
KEY = 'nmk_live_GHd4EtmxacE16KJahhjTIi4Sa9A4'
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'nextmoe_tags_full.json')

# 清代理
for k in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY']:
    os.environ.pop(k, None)


def fetch(cursor=None, limit=100):
    url = f'{API}?nsfw=true&has_works=true&limit={limit}&view=full'
    if cursor:
        url += f'&cursor={urllib.parse.quote(cursor)}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {KEY}',
        'User-Agent': 'ChronoTide/1.0 (TagVocab Research)',
        'Accept': 'application/json',
    })
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = int(e.headers.get('Retry-After', '21'))
                print(f'  429 限流，等待 {wait}s...', flush=True)
                time.sleep(wait + 1)
                continue
            print(f'  HTTP {e.code}: {e.read()[:200]}', flush=True)
            raise
        except Exception as e:
            print(f'  异常 {e}，重试...', flush=True)
            time.sleep(3)
    raise RuntimeError('重试耗尽')


def main():
    all_tags = []
    cursor = None
    page = 0
    while True:
        page += 1
        data = fetch(cursor)
        items = data.get('items', [])
        all_tags.extend(items)
        print(f'  第 {page} 页: +{len(items)} (累计 {len(all_tags)})', flush=True)
        cursor = data.get('next_cursor')
        if not cursor:
            break
        time.sleep(1.1)
    json.dump(all_tags, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
    print(f'\n完成：{len(all_tags)} 个标签 → {OUT}')

    # 统计
    from collections import Counter
    print('tag_kind:', dict(Counter(t.get('tag_kind') for t in all_tags)))
    print('tier:', dict(Counter(t.get('tier') for t in all_tags)))
    print('is_sexual:', dict(Counter(t.get('is_sexual') for t in all_tags)))
    print('样例:', ' | '.join((t.get('display_name') or '') for t in all_tags[:40]))


if __name__ == '__main__':
    main()
