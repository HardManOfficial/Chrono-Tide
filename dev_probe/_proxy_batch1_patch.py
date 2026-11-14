# -*- coding: utf-8 -*-
"""批次1：把散落的代理解析收敛到 NetworkProxyPolicy（换行容错替换）。"""
import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'lib')


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


# ─────────────────────────────────────────────────────────────
# 1. metadata_fetcher.dart
# ─────────────────────────────────────────────────────────────
p = os.path.join(LIB, 'services', 'metadata_fetcher.dart')
s = read(p)

s = rep(s,
        "import 'package:dio/io.dart';\n", '',
        'fetcher: drop dio/io import')

s = rep(s,
        "import '../core/path_helper.dart';\nimport 'system_proxy_detector.dart';",
        "import '../core/path_helper.dart';\n"
        "import 'network_proxy_core.dart';\n"
        "import 'network_proxy_policy.dart';",
        'fetcher: swap imports')

s = rep(s,
        "  static String? _proxyUrl;\n"
        "  static String? _resolvedProxyUrl; // 三级解析后的最终代理 URL（app配置 > 系统代理）\n"
        "  static Dio? _dio;",
        "  static Dio? _dio;",
        'fetcher: drop duplicated proxy state')

s = rep(s,
        "    fetchLog('[MetadataFetcher] 已解析代理: ${_resolvedProxyUrl ?? \"无（直连）\"}');",
        "    fetchLog('[MetadataFetcher] ${NetworkProxyPolicy.instance.statusText}');",
        'fetcher: init log')

new_proxy_block = '''  // ==================== 代理设置 ====================

  /// 加载全局代理策略并安装全局 HttpOverrides。
  ///
  /// 策略（自动跟随系统代理 / 手动 / 直连）与运行期刷新全部由
  /// [NetworkProxyPolicy] 统一负责；本类只负责把全局 Dio 接上去。
  static Future<void> _loadProxySettings() async {
    await NetworkProxyPolicy.instance.load();
  }

  /// 初始化全局 Dio 并接入统一代理策略。
  ///
  /// 🔴 旧实现在这里一次性解析代理（app 配置 > 系统代理 > 环境变量），
  /// 把结果写死进 `onHttpClientCreate` ⇒ 运行期开关系统代理永远不生效；
  /// 且手动 URL 会永久压过系统代理、代理端口不通时静默退回直连 ——
  /// 这正是「开了代理元数据抓取反而时好时坏」的根因。
  /// 现在回调只读策略的当前值，策略自己按 TTL 在请求前刷新。
  static Future<void> _initDio() async {
    _dio = Dio(BaseOptions(
      // P0.1：缩短超时，单源最坏从 30s 降至 15s，配合并发降低总耗时
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'ChronoTide/1.0 (Metadata Scraper)',
      },
    ));
    NetworkProxyPolicy.instance.attachTo(_dio!);
  }

  /// 兼容旧调用方：写入手动代理（空 = 回到自动跟随系统代理）。
  /// 设置页现在直接调 [NetworkProxyPolicy.apply]。
  static Future<void> updateProxy(String? proxyUrl) async {
    final url = (proxyUrl ?? '').trim();
    await NetworkProxyPolicy.instance.apply(
      url.isEmpty ? NetworkProxyMode.system : NetworkProxyMode.manual,
      url,
    );
  }

'''
s = rep_re(s,
           r"  // ==================== 代理设置 ====================[\s\S]*?"
           r"(?=  /// 清空服务实例缓存（P0.3）)",
           new_proxy_block,
           'fetcher: replace whole proxy block')

s = rep(s,
        "  static String? get currentProxy => _proxyUrl;",
        "  static String? get currentProxy {\n"
        "    final url = NetworkProxyPolicy.instance.manualUrl;\n"
        "    return url.isEmpty ? null : url;\n"
        "  }",
        'fetcher: currentProxy delegates')
write(p, s)

# ─────────────────────────────────────────────────────────────
# 2. company_logo_service.dart
# ─────────────────────────────────────────────────────────────
p = os.path.join(LIB, 'services', 'company_logo_service.dart')
s = read(p)
s = rep(s, "import 'package:dio/io.dart';\n", '', 'logo: drop dio/io')
s = rep(s, "import 'package:shared_preferences/shared_preferences.dart';\n", '',
        'logo: drop prefs')
s = rep(s, "import 'system_proxy_detector.dart';",
        "import 'network_proxy_policy.dart';", 'logo: swap detector import')
s = rep(s,
        "    // app 配置代理 > Windows 系统代理 > 环境变量\n"
        "    String? proxy;\n"
        "    try {\n"
        "      final prefs = await SharedPreferences.getInstance();\n"
        "      final configured = prefs.getString('proxy_url');\n"
        "      if (configured != null && configured.isNotEmpty) proxy = configured;\n"
        "    } catch (_) {}\n"
        "    proxy ??= await SystemProxyDetector.detectProxy();\n"
        "\n"
        "    final adapter = dio.httpClientAdapter;\n"
        "    if (adapter is DefaultHttpClientAdapter) {\n"
        "      final proxyUrl = proxy;\n"
        "      adapter.onHttpClientCreate = (client) {\n"
        "        if (proxyUrl != null && proxyUrl.isNotEmpty) {\n"
        "          client.findProxy = (_) => 'PROXY $proxyUrl';\n"
        "        } else {\n"
        "          client.findProxy = HttpClient.findProxyFromEnvironment;\n"
        "        }\n"
        "        return client;\n"
        "      };\n"
        "    }",
        "    // 全局统一代理策略（自动跟随系统代理 / 手动 / 直连）。\n"
        "    NetworkProxyPolicy.instance.attachTo(dio);",
        'logo: delegate to policy')
write(p, s)

# ─────────────────────────────────────────────────────────────
# 3. game_title_logo_service.dart
# ─────────────────────────────────────────────────────────────
p = os.path.join(LIB, 'services', 'game_title_logo_service.dart')
s = read(p)
s = rep(s, "import 'package:dio/io.dart';\n", '', 'title: drop dio/io')
s = rep(s, "import 'system_proxy_detector.dart';",
        "import 'network_proxy_policy.dart';", 'title: swap detector import')
s = rep(s,
        "    // app 配置代理 > Windows 系统代理 > 环境变量（与 MetadataFetcher 同款）\n"
        "    String? proxy;\n"
        "    try {\n"
        "      final prefs = await SharedPreferences.getInstance();\n"
        "      final configured = prefs.getString('proxy_url');\n"
        "      if (configured != null && configured.isNotEmpty) proxy = configured;\n"
        "    } catch (_) {}\n"
        "    proxy ??= await SystemProxyDetector.detectProxy();\n"
        "\n"
        "    final adapter = dio.httpClientAdapter;\n"
        "    if (adapter is DefaultHttpClientAdapter) {\n"
        "      final proxyUrl = proxy;\n"
        "      adapter.onHttpClientCreate = (client) {\n"
        "        if (proxyUrl != null && proxyUrl.isNotEmpty) {\n"
        "          client.findProxy = (_) => 'PROXY $proxyUrl';\n"
        "        } else {\n"
        "          client.findProxy = HttpClient.findProxyFromEnvironment;\n"
        "        }\n"
        "        return client;\n"
        "      };\n"
        "    }",
        "    // 全局统一代理策略（自动跟随系统代理 / 手动 / 直连）。\n"
        "    NetworkProxyPolicy.instance.attachTo(dio);",
        'title: delegate to policy')
write(p, s)

# ─────────────────────────────────────────────────────────────
# 4. game_op_video_service.dart / game_op_video_core.dart
# ─────────────────────────────────────────────────────────────
p = os.path.join(LIB, 'services', 'game_op_video_service.dart')
s = read(p)
s = rep(s, "import 'package:shared_preferences/shared_preferences.dart';\n", '',
        'opvideo: drop prefs')
s = rep(s, "import 'system_proxy_detector.dart';",
        "import 'network_proxy_policy.dart';", 'opvideo: swap detector import')
s = rep(s,
        "  /// 代理：App 内配置 > Windows 系统代理（与标题图/元数据抓取同款优先级）。\n"
        "  Future<String> _resolveProxy() async {\n"
        "    try {\n"
        "      final SharedPreferences prefs = await SharedPreferences.getInstance();\n"
        "      final String configured = (prefs.getString('proxy_url') ?? '').trim();\n"
        "      if (configured.isNotEmpty) return configured;\n"
        "    } catch (_) {}\n"
        "    try {\n"
        "      return (await SystemProxyDetector.detectProxy()) ?? '';\n"
        "    } catch (_) {\n"
        "      return '';\n"
        "    }\n"
        "  }",
        "  /// 代理：委托全局统一策略，每次下载前刷新一次（运行期开/关系统代理可跟随）。\n"
        "  Future<String> _resolveProxy() async {\n"
        "    final policy = NetworkProxyPolicy.instance;\n"
        "    await policy.refresh();\n"
        "    return policy.effectiveProxy ?? '';\n"
        "  }",
        'opvideo: delegate to policy')
write(p, s)

p = os.path.join(LIB, 'services', 'game_op_video_core.dart')
s = read(p)
s = rep(s,
        "    if (proxy.isNotEmpty) {\n"
        "      client.findProxy = (Uri _) => 'PROXY $proxy';\n"
        "    } else {\n"
        "      client.findProxy = HttpClient.findProxyFromEnvironment;\n"
        "    }",
        "    if (proxy.isNotEmpty) {\n"
        "      client.findProxy = (Uri _) => 'PROXY $proxy';\n"
        "    }\n"
        "    // proxy 为空时不覆写 findProxy ⇒ 继承全局 HttpOverrides 注入的统一策略",
        'opcore: inherit global policy when no explicit proxy')
write(p, s)

# ─────────────────────────────────────────────────────────────
# 5. settings_modal.dart —— 代理卡片（批次1）
# ─────────────────────────────────────────────────────────────
p = os.path.join(LIB, 'widgets', 'settings_modal.dart')
s = read(p)

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
           r"          const SizedBox\(height: 8\);\r?\n"
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
write(p, s)

print('ALL DONE')
