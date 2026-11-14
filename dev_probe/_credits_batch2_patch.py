# -*- coding: utf-8 -*-
"""批次2：把「开源组件致谢」从网络与存储页搬到关于应用右下角。"""
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

# 1. 删除「缓存管理」卡片尾部的整块致谢（原 4189-4231）
s = rep_re(s,
           r"          const SizedBox\(height: 32\),\r?\n"
           r"          Text\(\r?\n"
           r"            '开源组件致谢'[\s\S]*?"
           r"(?=        \],\r?\n      \),\r?\n    \);\r?\n  \})",
           '',
           'credits: remove from storage card')

# 2. 关于页底部：左「了解我们」+ 右「开源组件致谢」
s = rep(s,
        "          _buildAboutLinks(),\n"
        "        ],",
        "          Row(\n"
        "            crossAxisAlignment: CrossAxisAlignment.start,\n"
        "            children: [\n"
        "              _buildAboutLinks(),\n"
        "              const Spacer(),\n"
        "              Flexible(child: _buildAboutCredits()),\n"
        "            ],\n"
        "          ),\n"
        "        ],",
        'credits: bottom row with right-hand block')

# 3. 新增右下角精简致谢构件
credits_widget = '''  /// 开源组件致谢（2026-11-12 从「网络与存储 → 缓存管理」底部迁来）。
  ///
  /// 常驻关于页**右下角**：只列组件名 + 许可类型，完整许可文本指向安装目录。
  /// 🔴 底部是常驻区（见 _buildAboutContent 的两段式注释），最小窗口
  /// _kMinHeight=520 下不能溢出 ⇒ 高度必须可控，故只放精简三行。
  Widget _buildAboutCredits() {
    TextStyle line = TextStyle(
      fontSize: 11,
      height: 15 / 11,
      color: AppColors.secondaryText,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '开源组件致谢',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.placeholderText,
          ),
        ),
        const SizedBox(height: 4),
        Text('SDL3 · zlib License', style: line),
        Text('CTFontHook 0.1.1 · MIT License', style: line),
        Text('Microsoft Detours 4.0.1 · MIT License', style: line),
        const SizedBox(height: 3),
        Text(
          '完整许可见安装目录 runtime/ 下的 LICENSE 文件',
          style: TextStyle(
            fontSize: 10,
            height: 14 / 10,
            color: AppColors.placeholderText,
          ),
        ),
      ],
    );
  }

'''
s = rep(s,
        "  /// 单条文字链接。",
        credits_widget + "  /// 单条文字链接。",
        'credits: insert _buildAboutCredits')
write(P, s)
print('ALL DONE')
