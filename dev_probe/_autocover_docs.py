# -*- coding: utf-8 -*-
"""autocover 文档收尾：摘出智能解压段(暂存) + 追加 autocover 条目 + 落盘自验证"""
import io, sys

def rd(p):
    with io.open(p, 'r', encoding='utf-8') as f: return f.read()

def wr(p, s):
    with io.open(p, 'w', encoding='utf-8', newline='') as f: f.write(s)

BASE = r'D:/CTLIB'
DL  = BASE + r'\docs\DEV\DEV_LOG.md'
SH  = BASE + r'\docs\DEV\SESSION_HANDOFF.md'
FT  = BASE + r'\docs\DEV\features\series_curator_tool.md'
TMP1 = BASE + r'\dev_probe\_unpack_devlog_section.txt'
TMP2 = BASE + r'\dev_probe\_unpack_handoff_section.txt'

# ---------- 1. DEV_LOG：摘出智能解压段 ----------
t = rd(DL)
mark1 = '## 2026-10-04 智能解压 Phase 3.5 补完'
i = t.find(mark1)
assert i > 0, 'DEV_LOG 智能解压标记未找到'
assert t.find(mark1, i+1) < 0, 'DEV_LOG 智能解压标记不唯一'
section1 = t[i:]            # 含标记到文件尾
head1 = t[:i].rstrip('\n') + '\n'
wr(TMP1, section1)
wr(DL, head1)

# ---------- 2. DEV_LOG：追加 autocover 条目 ----------
dl_new = '''

## 2026-10-04 系列封面自动补全（v1.3）：取系列第一个游戏的封面作系列封面
- 背景：系列封面图难收集 → 采纳用户方案「用系列第一个游戏的封面」；客户端 series_section.dart:153/390 直接渲染 coverUrl 全 URL，**客户端零改动**。
- 工具 v1.3：curator.py 新增 pick_first_game（main_axis 中 playOrder 最小者，缺则全体成员兜底）/ game_cover_url（coverUrl|cover 字段 → {PB}/api/files/games/{id}/{文件名}）/ autocover_series（分页扫 series_meta+members，默认只填空缺，override 可覆盖）；POST /api/v2/autocover；设置页「系列封面自动补全」卡片（一键补全 / 覆盖全部带确认）。
- 全量实跑（2026-10-04）：**43 系列全部填充 ✓**，0 个已有封面被覆盖、0 个失败。抽查 3 个 URL（含特殊长文件名）匿名 GET 全 200（593KB/357KB/59KB）；云端 series_meta.coverUrl 落库复核 ✓。
- 语义注意：coverUrl 是生成时的快照引用，源游戏删图/换图不会联动（与「整理是快照不是订阅」一致）；单个系列可用「覆盖全部」重跑修正。
- 档案：docs/DEV/features/series_curator_tool.md §v1.3
'''
wr(DL, head1.rstrip('\n') + dl_new)

# ---------- 3. SESSION_HANDOFF：摘出智能解压段 ----------
t = rd(SH)
mark2 = '### 2026-10-04 智能解压 Phase 3.5 补完'
i = t.find(mark2)
assert i > 0, 'HANDOFF 智能解压标记未找到'
assert t.find(mark2, i+1) < 0, 'HANDOFF 智能解压标记不唯一'
section2 = t[i:]
head2 = t[:i].rstrip('\n') + '\n'
wr(TMP2, section2)

sh_new = '''

### 2026-10-04 系列封面自动补全（最新）
- 工具 v1.3 autocover：取系列第一个游戏（main_axis 最小 playOrder）的封面 → series_meta.coverUrl，客户端零改动。已对云端全量实跑：**43 系列全部填充**，0 覆盖 0 失败，抽查 URL 匿名全 200。
- 设置页入口：一键补全（只填空缺）/ 覆盖全部（带确认）。⏳ 真机看板效果待 exe 重建（清 C 盘解 231）。
'''
wr(SH, head2.rstrip('\n') + sh_new)

# ---------- 4. features 档案：v1.3 段（插在「## 后续（待定）」前） ----------
t = rd(FT)
mark3 = '## 后续（待定）'
i = t.find(mark3)
assert i > 0, '档案「后续（待定）」标记未找到'
ft_new = '''## v1.3 系列封面自动补全（2026-10-04）

- 背景：系列封面图难收集 → 采纳用户方案：**用系列第一个游戏的封面当系列封面**。
- 规则：第一个游戏 = main_axis 中 playOrder 最小者（无 main_axis 时取全体成员中最小）；
  封面取该游戏 `coverUrl`/`cover` 字段 → `{PB}/api/files/games/{id}/{文件名}`。
- 入口：⚙ 设置页「系列封面自动补全」卡片——「一键补全封面」（只填空缺，默认）/
  「覆盖全部」（danger，需确认）→ POST /api/v2/autocover `{override}`。
- 全量实跑（2026-10-04）：**43 系列全部填充 ✓**（0 已有封面被跳过=原本全空、0 失败）。
  抽查 3 个 URL 匿名 GET 全 200（含 1 个特殊长文件名）；云端 series_meta.coverUrl 落库复核 ✓。
- 客户端零改动：series_section.dart:153/390 的 HallCoverImage(networkUrl:) 直接吃全 URL。
- 语义注意：coverUrl 存的是**生成时的游戏封面引用**，源游戏日后删图/换图不会联动
  （快照语义，与「整理是快照不是订阅」一致）；需要时对单个系列手动修正后「覆盖全部」重跑。


'''
wr(FT, t[:i] + ft_new + t[i:])

# ---------- 5. 落盘自验证 ----------
ok = []
ok.append(('DEV_LOG autocover', '系列封面自动补全（v1.3）' in rd(DL)))
ok.append(('DEV_LOG 智能解压已摘出', mark1 not in rd(DL)))
ok.append(('HANDOFF autocover', '系列封面自动补全（最新）' in rd(SH)))
ok.append(('HANDOFF 智能解压已摘出', mark2 not in rd(SH)))
ok.append(('档案 v1.3', 'v1.3 系列封面自动补全' in rd(FT)))
ok.append(('档案 后续段仍在', mark3 in rd(FT)))
ok.append(('暂存1非空', len(rd(TMP1)) > 100))
ok.append(('暂存2非空', len(rd(TMP2)) > 100))
bad = [n for n, v in ok if not v]
print('VERIFY:', 'ALL PASS' if not bad else 'FAIL ' + str(bad))
sys.exit(1 if bad else 0)
