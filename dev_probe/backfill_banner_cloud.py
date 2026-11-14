# -*- coding: utf-8 -*-
"""
横幅封面批量回填：线上 PB games 全量记录 → NextMoe 抓横版封面 → 校验 → 上传。
2026-10-05 追加：NextMoe 无候选时回退 **Hikarinagi**（开发者实测该平台
横幅数据最完整）——需走代理（CF 系，直连 TLS 重置），--proxy 仅作用于
Hikarinagi 的 API 与图片下载；PB / NextMoe 保持国内直连。

用法：
  python backfill_banner_cloud.py --dry-run     # 只抓取+校验，不上传（默认跑全量）
  python backfill_banner_cloud.py --live        # 校验通过后 PATCH 上传到 PB
  python backfill_banner_cloud.py --live --limit N
  python backfill_banner_cloud.py --retry-failed --dry-run \
      --proxy http://127.0.0.1:7892   # 重试上轮失败记录（HK 回退链）

口径与客户端一致（nextmoe_service.dart / hikarinagi_service.dart 2026-10-05）：
- 搜索：originalTitle → title → englishTitle 依次尝试，首个命中即用
- 匹配：归一化后相等 > 包含，取分最高项
- 挑选：covers[] 中宽>高取面积最大 → 无果回退"无尺寸候选"（交下载侧裁决）
- 裁决：PIL 实测宽高比 >= 1.15 且宽 >= 480 才收（治音乐盘图/竖图拉伸）
"""
import argparse
import io
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error

os_path_exists = os.path.exists

BASE = 'http://117.72.115.30:8090'
NM_API = 'https://api.nextmoe.dev/v2'
NM_KEY = 'nmk_live_GHd4EtmxacE16KJahhjTIi4Sa9A4'
# Hikarinagi（OIDC client_credentials，与 hikarinagi_service.dart 同凭据）
HK_API = 'https://www.hikarinagi.org/api/v3/open'
HK_TOKEN_URL = 'https://id.hikarinagi.org/oidc/token'
HK_CLIENT_ID = 'hkn_hCWLqY0zJzWwItBl'
HK_CLIENT_SECRET = '<REDACTED>'
STATE_FILE = 'banner_backfill_state.json'
IMG_DIR = 'banner_backfill_imgs'
MIN_ASPECT = 1.15
MIN_WIDTH = 480

# 代理（可选）：--proxy http://127.0.0.1:7892 时启用。
# 🔴 2026-10-05 语义变更：代理**只**用于 Hikarinagi（API + 图片下载），
# PB / NextMoe 保持直连（国内服务器走代理反而绕路 + WAF 出口 IP 风险）。
PROXY = None
_PROXY_OPENER = None


def _install_proxy():
    global _PROXY_OPENER
    if PROXY:
        handler = urllib.request.ProxyHandler({
            'http': PROXY, 'https': PROXY,
        })
        _PROXY_OPENER = urllib.request.build_opener(handler)


def _proxied_urlopen(req, timeout=60):
    """HK 专用：有代理走代理 opener，无代理走默认。"""
    if _PROXY_OPENER is not None:
        return _PROXY_OPENER.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)

SU_TOKEN = open('pb_su_token.txt', encoding='utf-8').read().strip()

state = {}
try:
    state = json.load(open(STATE_FILE, encoding='utf-8'))
except Exception:
    state = {'done': {}, 'failed': {}}


def pb_req(method, path, token=None, raw=None, content_type=None):
    url = BASE + path
    h = {}
    if token:
        h['Authorization'] = token
    if content_type:
        h['Content-Type'] = content_type
    data = raw.encode('utf-8') if isinstance(raw, str) else raw
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            body = resp.read().decode('utf-8') or '{}'
            return resp.status, json.loads(body)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode('utf-8') or '{}')
        except Exception:
            return e.code, {}
    except Exception as e:
        return -1, {'error': str(e)}


def nm_req(path, params=''):
    url = f'{NM_API}{path}?{params}' if params else f'{NM_API}{path}'
    r = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {NM_KEY}',
        # 🔴 urllib 默认 UA（Python-urllib/x）被 NextMoe WAF 403；curl UA 可过
        'User-Agent': 'curl/8.9.1',
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(r, timeout=40) as resp:
            if resp.status == 429:
                wait = int(resp.headers.get('Retry-After', '30'))
                print(f'    [429] NextMoe 限流，退避 {wait}s')
                time.sleep(wait + 1)
                return nm_req(path, params)
            return resp.status, json.loads(resp.read().decode('utf-8') or '{}')
    except urllib.error.HTTPError as e:
        if e.code == 429:
            wait = int(e.headers.get('Retry-After', '30') or 30)
            print(f'    [429] NextMoe 限流，退避 {wait}s')
            time.sleep(wait + 1)
            return nm_req(path, params)
        return e.code, {}
    except Exception as e:
        return -1, {'error': str(e)}


SPECIAL = re.compile(r'[-_:(（）\)\[\]「」＊*·.．,/\\\'"]')


def norm(s):
    return SPECIAL.sub('', (s or '').lower()).replace(' ', '').replace('　', '')


def pick_best_match(items, keyword):
    """镜像 nextmoe_service._pickBestMatch：相等 > 前缀 > 包含。"""
    kw = norm(keyword)
    if not kw:
        return None
    best, best_score = None, -1
    for it in items:
        if not isinstance(it, dict):
            continue
        names = set()
        if it.get('display_name'):
            names.add(it['display_name'])
        loc = it.get('localized') or {}
        for v in loc.values():
            if isinstance(v, dict) and v.get('value'):
                names.add(v['value'])
        score = 0
        for n in names:
            nn = norm(n)
            if nn == kw:
                score = max(score, 100)
            elif nn.startswith(kw) or kw.startswith(nn):
                score = max(score, 60)
            elif kw in nn or nn in kw:
                score = max(score, 30)
        if score > best_score:
            best_score, best = score, it
    return best if best_score >= 30 else None  # 弱匹配宁缺毋滥


def pick_landscape_banner(detail, exclude_url):
    """镜像 _pickLandscapeBanner 两轮策略。"""
    covers = detail.get('covers') or []
    best_url, best_area, unknown = None, 0, None
    for c in covers:
        if not isinstance(c, dict):
            continue
        url = c.get('url') or ''
        if not url or url == exclude_url:
            continue
        w, h = c.get('width') or 0, c.get('height') or 0
        if w <= 0 or h <= 0:
            unknown = unknown or url
            continue
        if w <= h:
            continue
        if w * h > best_area:
            best_area, best_url = w * h, url
    return best_url or unknown


# ─── Hikarinagi 回退链（2026-10-05）───────────────────────────────────
_hk_token = None
_hk_token_exp = 0.0


def hk_token():
    """OIDC client_credentials 换 access_token（1h 有效，提前 60s 刷新）。"""
    global _hk_token, _hk_token_exp
    if _hk_token and time.time() < _hk_token_exp:
        return _hk_token
    import base64
    basic = base64.b64encode(
        f'{HK_CLIENT_ID}:{HK_CLIENT_SECRET}'.encode()).decode()
    req = urllib.request.Request(HK_TOKEN_URL, method='POST', data=(
        'grant_type=client_credentials&scope=catalog:read').encode(),
        headers={
            'Authorization': f'Basic {basic}',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
            'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
        })
    try:
        with _proxied_urlopen(req, timeout=30) as resp:
            d = json.loads(resp.read().decode('utf-8') or '{}')
    except Exception as e:
        print(f'    [HK] token 失败: {e}')
        return None
    tok = d.get('access_token') or ''
    if not tok:
        print(f'    [HK] token 响应异常: {str(d)[:120]}')
        return None
    _hk_token = tok
    _hk_token_exp = time.time() + max(int(d.get('expires_in') or 3600) - 60, 60)
    return tok


def hk_req(path, params=''):
    """GET /api/v3/open{path}?{params}，Bearer 认证，返回 (status, envelope)。"""
    tok = hk_token()
    if not tok:
        return -1, {}
    url = f'{HK_API}{path}?{params}' if params else f'{HK_API}{path}'
    r = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {tok}',
        'Accept': 'application/json',
        'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
    })
    for attempt in range(2):
        try:
            with _proxied_urlopen(r, timeout=40) as resp:
                return resp.status, json.loads(resp.read().decode('utf-8') or '{}')
        except urllib.error.HTTPError as e:
            if e.code == 401 and attempt == 0:
                global _hk_token, _hk_token_exp
                _hk_token, _hk_token_exp = None, 0.0
                tok = hk_token()
                if not tok:
                    return e.code, {}
                r = urllib.request.Request(url, headers={
                    'Authorization': f'Bearer {tok}',
                    'Accept': 'application/json',
                    'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
                })
                continue
            return e.code, {}
        except Exception as e:
            return -1, {'error': str(e)}
    return -1, {}


def hk_search_banner(jp, title, en):
    """Hikarinagi 搜横幅：jp→title→en 依次搜索，返回 (url, via) 或 (None, '')。
    搜索项只认 type=galgame；标题弱匹配防错配（与 NextMoe 同"宁缺毋滥"）。"""
    for kw, label in ((jp, 'jp'), (title, 'title'), (en, 'en')):
        if not kw.strip():
            continue
        st, env = hk_req('/search', urllib.request.quote(
            f'q={kw}&types=galgame&page=1&page_size=5', safe='=&'))
        time.sleep(1.0)
        if st != 200 or not env.get('success'):
            continue
        items = ((env.get('data') or {}).get('items')) or []
        game_id = None
        for it in items:
            if not isinstance(it, dict):
                continue
            # 标题弱匹配（norm 相等/前缀/包含 ≥30 分），防同名异作
            if pick_best_match([{'display_name': it.get('title')}], kw):
                if it.get('type') == 'galgame' and it.get('id'):
                    game_id = it['id']
                    break
        if not game_id:
            continue
        st2, denv = hk_req(f'/galgames/{game_id}')
        time.sleep(1.0)
        if st2 != 200 or not denv.get('success'):
            continue
        detail = denv.get('data') or {}
        # 竖封面 = votes 最高的 cover（镜像 _parseDetail），作为排除项
        cover, best_votes = '', -1
        for c in detail.get('covers') or []:
            if isinstance(c, dict) and (c.get('votes') or 0) > best_votes:
                best_votes, cover = c.get('votes') or 0, c.get('url') or ''
        cand = pick_landscape_banner(detail, exclude_url=cover)
        if cand:
            return cand, f'hk-{label}:{game_id}'
    return None, ''


def download_and_validate(url, use_proxy=False):
    """下载 + PIL 裁决：返回本地文件名 或 (None, 原因)。
    use_proxy=True 时走代理 opener（Hikarinagi 图床是 CF 系）。"""
    import os
    if url.startswith('/'):
        url = 'https://www.hikarinagi.org' + url
    os.makedirs(IMG_DIR, exist_ok=True)
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ChronoTide/2.1',
    })
    try:
        if use_proxy:
            with _proxied_urlopen(req, timeout=90) as resp:
                data = resp.read()
        else:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
    except Exception as e:
        return None, f'download: {e}'
    if len(data) < 8192:
        return None, f'too small ({len(data)}B)'
    from PIL import Image
    try:
        im = Image.open(io.BytesIO(data))
        im.load()
        w, h = im.size
    except Exception as e:
        return None, f'pillow: {e}'
    if h <= 0 or w / h < MIN_ASPECT:
        return None, f'aspect {w}x{h} < {MIN_ASPECT}'
    if w < MIN_WIDTH:
        return None, f'width {w} < {MIN_WIDTH}'
    fmt = (im.format or 'PNG').lower()
    if fmt == 'gif':
        return None, 'gif not allowed'
    if fmt not in ('png', 'jpeg', 'webp'):
        return None, f'fmt {fmt}'
    ext = {'png': 'png', 'jpeg': 'jpg', 'webp': 'webp'}[fmt]
    name = f'banner_{abs(hash(url)) % 10**10}.{ext}'
    path = os.path.join(IMG_DIR, name)
    with open(path, 'wb') as f:
        f.write(data)
    return path, f'{w}x{h}'


def upload_banner(game_id, path):
    """multipart PATCH 上传横幅。"""
    import mimetypes
    import os
    import uuid
    fn = os.path.basename(path)
    mime = mimetypes.guess_type(fn)[0] or 'image/png'
    boundary = '----ct' + uuid.uuid4().hex
    with open(path, 'rb') as f:
        filedata = f.read()
    body = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="bannerUrl"; filename="{fn}"\r\n'
        f'Content-Type: {mime}\r\n\r\n'
    ).encode('utf-8') + filedata + f'\r\n--{boundary}--\r\n'.encode('utf-8')
    st, resp = pb_req('PATCH', f'/api/collections/games/records/{game_id}',
                      token=SU_TOKEN, raw=body,
                      content_type=f'multipart/form-data; boundary={boundary}')
    return st, resp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--live', action='store_true')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--retry-failed', action='store_true',
                    help='清空上轮 failed 记录使其重跑（配合 HK 回退链）')
    ap.add_argument('--proxy', default=os.environ.get('CT_BACKFILL_PROXY'))
    args = ap.parse_args()
    global PROXY
    PROXY = args.proxy
    _install_proxy()
    if args.dry_run and args.live:
        print('--dry-run 与 --live 互斥'); sys.exit(2)
    if not args.dry_run and not args.live:
        args.dry_run = True
    mode = 'LIVE' if args.live else 'DRY-RUN'
    print(f'===== 横幅回填（{mode}）=====')
    if args.retry_failed:
        n = len(state.get('failed', {}))
        state['failed'] = {}
        print(f'--retry-failed：已清空 {n} 条失败记录，本轮重跑')

    # 1) 拉全量记录
    records, page = [], 1
    while True:
        st, d = pb_req('GET',
                       f'/api/collections/games/records?perPage=200&page={page}&sort=created',
                       token=SU_TOKEN)
        assert st == 200, (st, d)
        records.extend(d['items'])
        if len(records) >= d['totalItems'] or not d['items']:
            break
        page += 1
    print(f'线上 games 总数: {len(records)}')

    todo = [r for r in records if not r.get('bannerUrl')]
    print(f'缺横幅: {len(todo)}（已有 {len(records) - len(todo)}）')
    if args.limit:
        todo = todo[:args.limit]
        print(f'本轮限额: {args.limit}')

    ok = skip = fail = 0
    for i, rec in enumerate(todo, 1):
        gid, title = rec['id'], rec.get('title') or ''
        jp = rec.get('originalTitle') or ''
        en = rec.get('englishTitle') or ''
        key = gid[:12]
        if key in state['done'] or key in state['failed']:
            skip += 1
            continue
        print(f'[{i}/{len(todo)}] {title[:30]}')

        # live 模式复用 dry-run 已验证的本地图（免二次搜索）
        prev = state.get('_dry_done', {}).get(key)
        if args.live and prev and prev.get('file') and os_path_exists(prev['file']):
            path, info = prev['file'], prev.get('info') or 'dry-validated'
            banner_url, via = prev.get('url') or '', 'dry-carry'
            print(f'    ↻ 复用 dry-run 已验证图 {info}')
            if args.live:
                st3, resp3 = upload_banner(gid, path)
                if st3 in (200, 201):
                    print('    ✓ 已上传云端')
                    state['done'][key] = {'title': title, 'file': path}
                    ok += 1
                else:
                    print(f'    ✗ 上传失败 HTTP {st3}')
                    state['failed'][key] = {'title': title,
                                            'reason': f'upload {st3}'}
                    fail += 1
            _save_state()
            continue

        banner_url, via = None, ''
        # ① NextMoe（国内直连）
        for kw, label in ((jp, 'jp'), (title, 'title'), (en, 'en')):
            if not kw.strip():
                continue
            st, sr = nm_req('/catalog/search',
                            f'object=work&q={urllib.request.quote(kw)}&nsfw=true')
            time.sleep(1.1)  # NextMoe free 档 60/min
            if st != 200:
                continue
            items = (sr or {}).get('items') or []
            match = pick_best_match(items, kw)
            if not match:
                continue
            wid = match.get('id')
            st2, detail = nm_req(f'/catalog/works/{wid}',
                                 'nsfw=true&include=covers,titles')
            time.sleep(1.1)
            if st2 != 200:
                continue
            cover = (detail.get('cover') or {}).get('url') or ''
            cand = pick_landscape_banner(detail, exclude_url=cover)
            if cand:
                banner_url, via = cand, f'{label}:{wid}'
                break
        # ② Hikarinagi 回退（走代理；2026-10-05 开发者实测该平台横幅最全）
        if not banner_url:
            cand, hv = hk_search_banner(jp, title, en)
            if cand:
                banner_url, via = cand, hv
                print(f'    [HK] 命中候选 {hv}')
        if not banner_url:
            print('    ✗ 无横幅候选（NextMoe + Hikarinagi 双源皆空）')
            state['failed'][key] = {'title': title, 'reason': 'no-candidate'}
            fail += 1
            _save_state()
            continue

        path, info = download_and_validate(
            banner_url, use_proxy=via.startswith('hk-'))
        if not path:
            print(f'    ✗ 裁决拒收：{info}')
            state['failed'][key] = {'title': title, 'reason': info,
                                    'url': banner_url}
            fail += 1
            _save_state()
            continue
        print(f'    ✓ 命中 {info} via {via}')

        if args.live:
            st3, resp3 = upload_banner(gid, path)
            if st3 in (200, 201):
                print('    ✓ 已上传云端')
                state['done'][key] = {'title': title, 'file': path}
                ok += 1
            else:
                print(f'    ✗ 上传失败 HTTP {st3}: {json.dumps(resp3, ensure_ascii=False)[:200]}')
                state['failed'][key] = {'title': title,
                                        'reason': f'upload {st3}'}
                fail += 1
        else:
            print(f'    (dry-run) 本地留存 {path}')
            # dry-run 结果存独立桶，供 --live 复用（免二次搜索）
            state.setdefault('_dry_done', {})[key] = {
                'title': title, 'file': path, 'url': banner_url, 'info': info}
            state['done'][key] = {'title': title, 'file': path, 'dry': True}
            ok += 1
        _save_state()

    print(f'===== 完成：成功 {ok} / 失败 {fail} / 跳过 {skip} =====')


def _save_state():
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
