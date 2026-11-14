import urllib.request, os, re, sys, html, gzip, io
proxy=os.environ.get('https_proxy')
op=urllib.request.build_opener(urllib.request.ProxyHandler({'http':proxy,'https':proxy}))
op.addheaders=[('User-Agent','Mozilla/5.0 (Windows NT 10.0; Win64; x64)'),('Accept-Encoding','gzip')]
def get(url):
    r=urllib.request.Request(url)
    d=op.open(r,timeout=30).read()
    if d[:2]==b'\x1f\x8b': d=gzip.decompress(d)
    return d.decode('utf-8','ignore')
def text(h):
    h=re.sub(r'(?is)<(script|style|noscript)[^>]*>.*?</\1>',' ',h)
    h=re.sub(r'(?s)<[^>]+>',' ',h)
    h=html.unescape(h)
    return re.sub(r'[ \t\r\f\v]+',' ',h)
for u in sys.argv[1:]:
    try:
        t=text(get(u))
        print('==== ',u,' len=',len(t))
        print(t[:3000])
    except Exception as e:
        print('ERR',u,repr(e)[:200])
