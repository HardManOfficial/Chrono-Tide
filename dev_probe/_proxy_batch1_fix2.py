# -*- coding: utf-8 -*-
"""批次1 收尾（修正版）：清掉本次引入的两条告警 + 修正过时注释。"""
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        return f.read()


def write(path, s):
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(s)


def nl_of(s):
    crlf = s.count('\r\n')
    lf = s.count('\n') - crlf
    return '\r\n' if crlf >= lf else '\n'


def rep(s, old, new, label, expect=1):
    nl = nl_of(s)
    pattern = re.compile(r'\r?\n'.join(re.escape(x) for x in old.split('\n')))
    repl = new.replace('\n', nl)
    s2, n = pattern.subn(lambda m: repl, s)
    print('[%s] %s: %d' % ('ok' if n == expect else 'FAIL', label, n))
    assert n == expect, label
    return s2


# 1. settings_modal.dart：删掉本次改动后才变成 unused 的 import
p = os.path.join(ROOT, 'lib', 'widgets', 'settings_modal.dart')
s = read(p)
s = rep(s,
        "import '../services/metadata_fetcher.dart';\n",
        '',
        'settings: drop now-unused MetadataFetcher import')
write(p, s)

# 2. metadata_fetcher.dart：保留「代理变更后重建服务」的既有语义
p = os.path.join(ROOT, 'lib', 'services', 'metadata_fetcher.dart')
s = read(p)
s = rep(s,
        "    await NetworkProxyPolicy.instance.apply(\n"
        "      url.isEmpty ? NetworkProxyMode.system : NetworkProxyMode.manual,\n"
        "      url,\n"
        "    );\n"
        "  }",
        "    await NetworkProxyPolicy.instance.apply(\n"
        "      url.isEmpty ? NetworkProxyMode.system : NetworkProxyMode.manual,\n"
        "      url,\n"
        "    );\n"
        "    // 沿用旧语义：代理变更后重建服务实例（内含 Token 缓存）\n"
        "    _clearServiceCache();\n"
        "    await _initDio();\n"
        "  }",
        'fetcher: keep service rebuild on proxy change')
s = rep(s,
        "    // - 关闭代理但残留注册表：_validateProxy 排除死代理 → 直连",
        "    // - 关闭代理但残留注册表：策略的 TCP 存活验证排除死代理 → 直连",
        'fetcher: fix stale comment')
write(p, s)

print('ALL DONE')
