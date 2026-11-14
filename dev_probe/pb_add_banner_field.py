# -*- coding: utf-8 -*-
import io, json, urllib.request

BASE = 'http://117.72.115.30:8090'
TOKEN = open('pb_su_token.txt', encoding='utf-8').read().strip()

def req(method, path, token=None, body=None, raw_body=None, headers=None):
    url = BASE + path
    data = None
    h = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        h['Content-Type'] = 'application/json'
    elif raw_body is not None:
        data = raw_body
    if token:
        h['Authorization'] = token
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode('utf-8') or '{}')
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode('utf-8') or '{}')

# 1) 读当前 schema
st, coll = req('GET', '/api/collections/games', token=TOKEN)
assert st == 200, (st, coll)
fields = coll['fields']
if any(f.get('name') == 'bannerUrl' for f in fields):
    print('SKIP: bannerUrl already exists')
else:
    cover = next(f for f in fields if f['name'] == 'coverUrl')
    banner = {k: v for k, v in cover.items() if k not in ('id', 'name', 'presentable')}
    banner['name'] = 'bannerUrl'
    new_fields = fields + [banner]
    st2, resp2 = req('PATCH', '/api/collections/games', token=TOKEN,
                     body={'fields': new_fields})
    print('PATCH:', st2)
    if st2 != 200:
        print(json.dumps(resp2, ensure_ascii=False)[:2000]); raise SystemExit(1)

# 2) 验证
st3, coll3 = req('GET', '/api/collections/games', token=TOKEN)
names = [f['name'] for f in coll3['fields']]
bf = next((f for f in coll3['fields'] if f['name'] == 'bannerUrl'), None)
print('bannerUrl field:', json.dumps(bf, ensure_ascii=False)[:300] if bf else 'MISSING!')
print('total fields:', len(names))
print('RESULT:', 'OK' if bf else 'FAIL')
