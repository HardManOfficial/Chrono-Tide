# -*- coding: utf-8 -*-
import io, sys

def rd(p):
    with io.open(p, 'r', encoding='utf-8') as f: return f.read()

def append(p, text, key):
    t = rd(p)
    assert key not in t, 'duplicate: ' + p
    with io.open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(t.rstrip('\n') + '\n' + text)
    return key in rd(p)

B = r'D:/CTLIB'
ok = []
ok.append(('DEV_LOG', append(B + r'\docs\DEV\DEV_LOG.md',
    '''
- **[追加 16:45] 系列条目改单行拖动滚动列表 + 强制 2:1 占比**：用户第三次迭代（强制要求）——弃 2x2 网格，改探索大厅同款 HallHScroll（hall_visuals.dart:273 鼠标拖动滚动封装）+ 横向 ListView 单行（卡宽固定 210，放不下靠拖动，尾部「+N」格=全系列-相关条目数）；game_detail_page.dart:2077/2097 截图 flex:2 / 系列 flex:1 强制裁剪配比（系列区套 NeverScrollable ScrollView 作矮窗口裁剪兜底）。存量 note：game_detail_page.dart:310-375 有 5 条存量 null-check warning（非本次引入，未修）。analyzer：series_strip 0/0。''',
    '单行拖动滚动列表 + 强制 2:1 占比')))
ok.append(('HANDOFF', append(B + r'\docs\DEV\SESSION_HANDOFF.md',
    '''
- [追加 16:45] 详情页系列条目定稿方向：单行 HallHScroll 拖动列表（大厅同款）+ 截图/系列=2/3:1/3 弹性强制；待热重载复查。''',
    '单行 HallHScroll 拖动列表定稿方向')))
bad = [n for n, v in ok if not v]
print('VERIFY:', 'ALL PASS' if not bad else 'FAIL ' + str(bad))
sys.exit(1 if bad else 0)
