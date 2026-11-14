# -*- coding: utf-8 -*-
"""批次1 · settings_modal.dart 代理卡片（换行容错替换）。"""
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, 'lib', 'widgets', 'settings_modal.dart')


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


def rep_re(s, pattern, new, label, expect=1):
    nl = nl_of(s)
    repl = new.replace('\n', nl)
    s2, n = re.compile(pattern).subn(lambda m: repl, s)
    print('[%s] %s: %d' % ('ok' if n == expect else 'FAIL', label, n))
    assert n == expect, label
    return s2


s = read(P)

s = rep(s,
        "import '../services/metadata_fetcher.dart';",
        "import '../services/metadata_fetcher.dart';\n"
        "import '../services/network_proxy_core.dart';\n"
        "import '../services/network_proxy_policy.dart';",
        'settings: add policy imports')

s = rep(s,
        "  late final TextEditingController _proxyController;\n"
        "  String? _proxySaveMessage;\n"
        "  bool _proxySaveSuccess = false;",
        "  late final TextEditingController _proxyController;\n"
        "  String? _proxySaveMessage;\n"
        "  bool _proxySaveSuccess = false;\n"
        "  NetworkProxyMode _proxyMode = NetworkProxyMode.system;",
        'settings: add mode state')

s = rep(s,
        "  Future<void> _loadProxySettings() async {\n"
        "    final proxy = MetadataFetcher.currentProxy;\n"
        "    if (mounted) {\n"
        "      _proxyController.text = proxy ?? '';\n"
        "    }\n"
        "  }",
        "  Future<void> _loadProxySettings() async {\n"
        "    final policy = NetworkProxyPolicy.instance;\n"
        "    if (mounted) {\n"
        "      setState(() {\n"
        "        _proxyController.text = policy.manualUrl;\n"
        "        _proxyMode = policy.mode;\n"
        "      });\n"
        "    }\n"
        "  }",
        'settings: load from policy')

card_head = '''          const SizedBox(height: 8),
          Text(
            '应用内所有网络请求（元数据、图片、下载、更新检查、云同步）统一使用此代理策略。Windows 可读取静态系统代理；PAC、自动发现或仅 TUN 的场景无法保证自动识别。',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '全局网络代理',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.4),
            ),
            child: DropdownButton<NetworkProxyMode>(
              value: _proxyMode,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              icon: Icon(Icons.expand_more,
                  size: 18, color: AppColors.secondaryText),
              style: TextStyle(fontSize: 14, color: AppColors.primaryText),
              items: <DropdownMenuItem<NetworkProxyMode>>[
                DropdownMenuItem<NetworkProxyMode>(
                  value: NetworkProxyMode.system,
                  child: Text('自动跟随系统代理',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.primaryText)),
                ),
                DropdownMenuItem<NetworkProxyMode>(
                  value: NetworkProxyMode.manual,
                  child: Text('手动代理',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.primaryText)),
                ),
                DropdownMenuItem<NetworkProxyMode>(
                  value: NetworkProxyMode.direct,
                  child: Text('不使用代理（直连）',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.primaryText)),
                ),
              ],
              onChanged: (NetworkProxyMode? value) {
                if (value != null) setState(() => _proxyMode = value);
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '自动跟随会在每次请求前重新读取系统代理，开/关代理无需重启软件。',
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '手动代理 URL',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: AppColors.primaryText,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '仅在选择「手动代理」时生效。支持 http:// 或 127.0.0.1:7890；其他模式下此地址会保存但暂不生效。',
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: AppColors.background,
              border: Border.all(color: AppColors.border, width: 1.4),
            ),
            child: TextField(
              controller: _proxyController,
              enabled: _proxyMode == NetworkProxyMode.manual,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 14,
                height: 20 / 14,
                color: AppColors.primaryText,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: 'http://127.0.0.1:7890',
                hintStyle: TextStyle(
                  fontWeight: FontWeight.w400,
                  fontSize: 14,
                  color: AppColors.inputHint,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            NetworkProxyPolicy.instance.statusText,
            style: TextStyle(
              fontSize: 12,
              height: 17 / 12,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 12),
'''
s = rep_re(s,
           r"          const SizedBox\(height: 8\),\r?\n"
           r"          Text\(\r?\n"
           r"            '配置代理服务器以加速访问海外数据源[\s\S]*?"
           r"(?=          if \(_proxySaveMessage != null\))",
           card_head,
           'settings: rebuild proxy card head')

s = rep(s,
        "      await MetadataFetcher.updateProxy(proxyUrl.isEmpty ? null : proxyUrl);",
        "      await NetworkProxyPolicy.instance.apply(_proxyMode, proxyUrl);",
        'settings: save via policy')
s = rep(s,
        "          _proxySaveMessage =\n"
        "              proxyUrl.isNotEmpty ? '代理已保存：$proxyUrl' : '已清除代理设置';",
        "          _proxySaveMessage = NetworkProxyPolicy.instance.statusText;",
        'settings: status message')
s = rep(s,
        "  Future<void> _handleClearProxy() async {\n"
        "    _proxyController.clear();\n"
        "    await _handleSaveProxy();\n"
        "  }",
        "  Future<void> _handleClearProxy() async {\n"
        "    _proxyController.clear();\n"
        "    setState(() => _proxyMode = NetworkProxyMode.system);\n"
        "    await _handleSaveProxy();\n"
        "  }",
        'settings: clear resets to system')
write(P, s)
print('ALL DONE')
