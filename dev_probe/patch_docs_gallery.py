# -*- coding: utf-8 -*-
import io, shutil

def patch(path, anchor, insert, before=True, backup=None):
    if backup:
        shutil.copyfile(path, backup)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        text = f.read()
    if insert.strip()[:40] in text:
        print('SKIP(already):', path)
        return
    idx = text.find(anchor)
    assert idx >= 0, 'anchor not found in ' + path
    new = (insert + text[:idx] + text[idx:]) if before else (text[:idx] + insert + text[idx:])
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(new)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        ok = 'GALLERY-VERIFY-TOKEN' in f.read() or insert.strip()[:60] in f.read()
    print('OK' if ok else 'VERIFY FAIL', path)

# 1) DEV_LOG 头部插入
devlog = '''## 2026-10-04 【功能】封面管理浮层——LunaBox 风格大图预览 + 多封面切换

- **背景**：横幅封面落地后缺查看/管理入口。参照开发者提供的 LunaBox 截图，
  详情窗封面加入口按钮 → 全屏磨砂浮层：大图预览 + **自由拖拽**（趣味性）+
  缩放预览按钮（TransformationController，不动真实文件）+ 循环切换 + 底部
  胶囊工具条（浏览组：缩小/放大/下一张/上传；编辑组：设为竖屏封面/设为
  横幅封面/删除/抓取）。
- **改动**：`game_data_format.dart` 新增 `listCoverGallery()`（canonical 竖封面
  → banner → `covers/` 自定义图，不改 game.json schema）+ `coversDirName` 常量；
  新组件 `lib/widgets/cover_gallery_overlay.dart`；`game_detail_dialog.dart`
  封面两态加入口（查看态右下角/编辑态右上角）+ 四操作回调（`_applyCoverRole`
  复用 _downloadCoverFromUrl 的 registry 同步/缓存失效/广播链；上传对齐
  screenshots/ 先例；删除带 covers/ 前缀 + isInsideAppStorage 双守卫）。
- **关键决策**：①「设为竖/横封面」= 复制为 cover.{ext}/banner.{ext} 并
  updateGameJson——老代码零感知，无 schema 变更；② IMP-05 护栏沿用
  （应用存储外不覆盖既有 cover.*，改时间戳替代名）；③ 浮层内「抓取」=
  先关浮层 → 查看态自动切编辑态 → 触发 _fetchMetadata（结果面板只在编辑态
  渲染 game_detail_dialog.dart:2207，不关浮层会被磨砂层压住）。
- **验证**：flutter analyze 改动文件 0 error（新组件 0 issue）；flutter test
  test/services/cover_gallery_test.dart **4/4 PASS**（231 已缓解，原生可跑）。
  ⏳ 未真机走查。
- **遗留**：P2 BPM 侧上传/管理入口（BPM 结构不变量约束，待开发者确认）；
  P2 存量横幅回填。
- **文件**：game_data_format.dart / widgets/cover_gallery_overlay.dart(新) /
  widgets/game_detail_dialog.dart / test/services/cover_gallery_test.dart(新)

'''
patch(r'D:\CTLIB\docs\DEV\DEV_LOG.md',
      '## 2026-10-04 【研究】单文件导入「智能解压」方案',
      devlog, before=True, backup=r'D:\CTLIB\docs\DEV\DEV_LOG.md.bak_gallery')

# 2) SESSION_HANDOFF 插入（最新 📦 在最前）
handoff = '''📦 本轮 · 最后更新：**2026-10-04 深夜·【功能】封面管理浮层（LunaBox 风格）**——
详情窗封面加入口（查看态右下角/编辑态右上角）→ 全屏磨砂浮层：大图可**自由拖拽**
（趣味性）+ 缩放预览（不动真实文件）+ 循环切换 + 工具条（上传/设为竖屏封面/
设为横幅封面/删除/抓取）。数据层新增 `listCoverGallery()`（canonical + `covers/`
自定义图，**不改 game.json schema**，「设为」= 复制为 cover.{ext}/banner.{ext} +
updateGameJson）；上传对齐 screenshots/ 先例；删除带 covers/ 前缀 +
isInsideAppStorage 双守卫；浮层内「抓取」先关浮层再切编辑态触发（结果面板
只在编辑态渲染 :2207）。验证：analyze 0 error + flutter test 4/4 PASS
（**231 已缓解，原生 test/analyze 均恢复**）；⏳ 未真机走查。遗留 P2：BPM 侧
上传/管理入口（BPM 结构不变量，待拍板）、存量横幅回填。
详见 docs/DEV/features/game_banner_cover.md §7。GALLERY-VERIFY-TOKEN

'''
patch(r'D:\CTLIB\docs\DEV\SESSION_HANDOFF.md',
      '📦 本轮 · 最后更新：**2026-10-04 上午·【服务】OpenList 旧内置迁移**',
      handoff, before=True, backup=r'D:\CTLIB\docs\DEV\SESSION_HANDOFF.md.bak_gallery')

# 3) 功能档案追加 §7
feature = '''

---

## §7 封面管理浮层（2026-10-04 深夜，LunaBox 风格参照）

**入口**：详情窗封面上的相册小按钮（查看态右下角 / 编辑态右上角）。

**交互**（开发者提供的 LunaBox 截图为基准）：
- 全屏磨砂遮罩（深浅主题自适应），图片直接浮在其上；单击空白/Esc 关闭
- 图片**可自由拖拽**（InteractiveViewer + 无边界 margin）——与截图查看器的
  核心差异，趣味性/观赏性
- 缩放按钮仅预览用途（TransformationController 中心锚点缩放 0.5–5.0，
  双击复位），不动真实文件
- 底部胶囊工具条：浏览组（缩小/放大/下一张/上传）+ 编辑组（设为竖屏封面/
  设为横幅封面/删除/抓取），忙碌态转圈、禁用态置灰

**数据面**（`game_data_format.dart`）：
- `listCoverGallery(dir)`：canonical 竖封面（cover_file→cover.*）→ 横幅
  （banner_file→banner.*）→ `covers/` 子目录自定义图（排序、去重、滤非图片）
- `coversDirName = 'covers'`（护栏：改名会破坏删除前缀守卫，有测试钉住）

**操作语义**（`game_detail_dialog.dart`）：
| 操作 | 实现 |
|---|---|
| 上传 | file_picker 多选 → 复制为 `covers/custom_<stamp>_<i>.{ext}`（对齐 screenshots/ 先例，无 json 写入） |
| 设为竖屏封面 | 复制为 `cover.{ext}` + updateGameJson('cover_file') + registry.coverUrl + 缓存失效 + 广播（复用 _downloadCoverFromUrl 同步链） |
| 设为横幅封面 | 复制为 `banner.{ext}` + updateGameJson('banner_file') + registry.bannerUrl + 广播 |
| 删除 | 仅 `covers/` 前缀 + `PathHelper.isInsideAppStorage` 双守卫；canonical 图不可删（置灰，可被替换） |
| 抓取 | 先关浮层 → 查看态自动 `_enterEditMode()` → `_fetchMetadata()`（结果面板只在编辑态渲染 :2207） |

**护栏**：IMP-05 沿用——元数据目录在应用存储外时，「设为」不覆盖既有
cover.*/banner.*，改时间戳替代名（护数据，不拦意图）。

**设计理由（为什么不用 game.json 存封面列表）**：covers/ 目录即真相，
零 schema 变更、零迁移；canonical 竖/横封面保持单字段语义，BPM/主页/
库页所有既有读取路径零改动。

**遗留**：P2 BPM 侧上传/管理入口（BPM 结构不变量约束，待开发者确认）；
P2 存量横幅回填；⏳ 真机走查。

**测试**：`test/services/cover_gallery_test.dart` 4 例（顺序/身份标记、
json 指定名优先、空目录、coversDirName 护栏）——**4/4 PASS**。
'''
path = r'D:\CTLIB\docs\DEV\features\game_banner_cover.md'
shutil.copyfile(path, path + '.bak_gallery')
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(feature)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    print('OK' if '§7 封面管理浮层' in f.read() else 'VERIFY FAIL', path)
