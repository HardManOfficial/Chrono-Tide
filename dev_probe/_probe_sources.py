import urllib.request, json, os, re
proxy=os.environ.get('https_proxy')
op=urllib.request.build_opener(urllib.request.ProxyHandler({'http':proxy,'https':proxy}))
def get(url, headers=None, method='GET', data=None, timeout=30):
    h={'User-Agent':'ChronoTide/1.0 (Metadata Scraper)','Accept':'application/json'}
    if headers: h.update(headers)
    req=urllib.request.Request(url, headers=h, method=method, data=data)
    try:
        return op.open(req,timeout=timeout).read().decode('utf-8','ignore')
    except Exception as e:
        return 'ERR '+repr(e)[:150]
def keyscan(txt, label):
    try: j=json.loads(txt)
    except Exception: print(label,'非JSON:',txt[:200]); return
    flat=[]
    def walk(o,p=''):
        if isinstance(o,dict):
            for k,v in o.items():
                flat.append(p+k); walk(v,p+k+'.')
        elif isinstance(o,list):
            for v in o[:2]: walk(v,p)
    walk(j)
    hits=[k for k in flat if re.search(r'video|movie|trailer|youtube|pv_|_pv|billibili|bilibili|mp4|m3u8',k,re.I)]
    print(f'[{label}] 顶层字段={list(j.keys())[:15] if isinstance(j,dict) else type(j)}')
    print(f'   视频相关字段: {hits[:20] if hits else "无"}')

# NextMoe 搜索
r=get('https://api.nextmoe.dev/v2/catalog/search?object=work&q=STEINS%3BGATE&nsfw=true',
      {'Authorization':'Bearer <REDACTED>'})
print('NextMoe search:', r[:300])
try:
    j=json.loads(r); items=j.get('data') or j.get('items') or j if isinstance(j,list) else j
    wid=None
    if isinstance(items,list) and items: wid=items[0].get('id')
    print('NextMoe work id:', wid)
    if wid:
        d=get(f'https://api.nextmoe.dev/v2/catalog/works/{wid}?nsfw=true&include=titles,intros,covers,screenshots,companies,tags,ratings,videos',
              {'Authorization':'Bearer <REDACTED>'})
        keyscan(d,'NextMoe detail(含 videos include)')
        print('   raw head:', d[:400])
except Exception as e: print('nm parse',e)
