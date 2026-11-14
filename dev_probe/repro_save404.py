# -*- coding: utf-8 -*-
"""复现 v2_save_series 幂等路径的 404"""
import sys, io, json, urllib.parse
sys.path.insert(0, r'D:\CTLIB\dev_tools\series_curator')
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
from curator import PB, load_config, ensure_admin

cfg = load_config()
pb = PB(cfg['pb_url'])
ensure_admin(pb, cfg)
print('token:', (pb.token or '')[:16], '...')

title = '命运石之门系列'
fq = urllib.parse.quote(f'title="{title}"')
url_q = f'?page=1&perPage=1&filter={fq}'
print('query string:', url_q)
ok, data = pb.list('series_meta', url_q)
print('lookup ok=', ok)
print('data:', json.dumps(data, ensure_ascii=False)[:400] if ok else data)
