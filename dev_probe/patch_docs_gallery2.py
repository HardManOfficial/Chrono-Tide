# -*- coding: utf-8 -*-
import io, shutil

def patch(path, anchor, insert, before=True, backup=None):
    if backup: shutil.copyfile(path, backup)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        text = f.read()
    marker = insert.strip()[:50]
    if marker in text:
        print('SKIP(already):', path); return
    idx = text.find(anchor)
    assert idx >= 0, 'anchor not found in ' + path
    new = (insert + text[:idx] + text[idx:]) if before else (text[:idx] + insert + text[idx:])
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(new)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        t2 = f.read()
    print('OK' if marker in t2 else 'VERIFY FAIL', path)

devlog = '''## 2026-10-05 【修复+功能】横幅抓取全链路加固 + 相册浮层交互改版 + 添加页相册

- **P0 横幅抓取修复**（开发者反馈：部分游戏漏抓横幅 / KunGal 抓成音乐盘图）：
  ① hikarinagi_service._parseDetail 接入 covers[] 横版挑选（此前完全没解析，
  开发者实测该平台横幅数据最完整；挑选规则与 NextMoe 同口径）；② NextMoe
  两轮策略——无已确认横版时回退「无尺寸元数据候选」（旧逻辑直接跳过是漏抓
  主因之一）；③ MIX banner_url 链 nextmoe→hikarinagi→kun（KunGal 论坛头图
  无尺寸元数据、曾混入音乐盘图，降为链尾）；④ **下载侧宽高比校验兜底**
  （CoverDownloadService.downloadCover 新增 minAspectRatio / downloadBanner
  便捷入口，≥1.15，缓存路径与网络路径都校验，不达标删文件拒收）——任何源
  的假横幅在此裁决。⚠️ 开发者口述「EXTeMOE」与六源显示名均对不上，按数据
  形态判定为 Hikarinagi（注释标注「参考 LunaBox metadata_hikarinagi.go」）；
  若实指其他平台需开发者再确认。
- **相册浮层交互改版**（详情窗）：图片区改 Positioned.fill 全窗口自由拖动
  （取消上下边框遮挡）；第三按钮「下一张」→「恢复初始居中」；新增上一张/
  下一张按钮（←/→ 键同步）；**抓取入口移除（纯相册）**，onFetch 回调链全清。
- **添加页相册系统**：metadata_section 头部新增「相册 N」入口（N=选中结果
  竖版+横幅计数，0 张禁用）；新组件 cover_preview_overlay.dart（磨砂全屏 +
  竖/横切换 + 拖拽缩放 + 网络图 CachedNetworkImage 预览）。
- **验证**：flutter analyze 9 改动文件 **0 error**；⏳ flutter test 被阵发 231
  拦死未跑成（两轮退避重试均 231；本轮未动 listCoverGallery 等既有测试覆盖
  的 API）；⏳ 未真机走查。
- **文件**：hikarinagi/nextmoe/metadata_fetcher/cover_download_service/
  game_data_format/game_detail_dialog/cover_gallery_overlay/metadata_section
  + cover_preview_overlay.dart(新)

'''
patch(r'D:/CTLIB/docs/DEV/DEV_LOG.md',
      '## 2026-10-04 【功能】封面管理浮层',
      devlog, before=True, backup=r'D:/CTLIB/docs/DEV/DEV_LOG.md.bak_gallery2')

handoff = '''📦 本轮 · 最后更新：**2026-10-05·【修复+功能】横幅抓取全链路加固 + 相册改版**——
P0：hikarinagi 接入 covers[] 横幅挑选（此前没解析）+ NextMoe 两轮策略（无尺寸
候选回退）+ MIX 链 nextmoe→hikarinagi→kun + **下载侧宽高比校验 ≥1.15 兜底**
（downloadBanner，假横幅/音乐盘图在此拒收）；⚠️ 开发者口述「EXTeMOE」按形态
判定为 Hikarinagi，待确认。相册浮层：全窗口自由拖动 + 恢复按钮 + 上一张/下一张
+ 抓取入口移除（纯相册）。添加页：「相册 N」入口 + cover_preview_overlay.dart
（竖/横双类型预览）。验证：analyze 9 文件 0 error；⏳ test 被 231 拦死未跑成 +
未真机走查。GALLERY2-VERIFY

'''
patch(r'D:/CTLIB/docs/DEV/SESSION_HANDOFF.md',
      '📦 本轮 · 最后更新：**2026-10-04 深夜·【功能】封面管理浮层（LunaBox 风格）**',
      handoff, before=True, backup=r'D:/CTLIB/docs/DEV/SESSION_HANDOFF.md.bak_gallery2')

feature = '''

---

## §8 横幅抓取全链路加固 + 相册交互改版 + 添加页相册（2026-10-05）

### 8.1 横幅抓取修复（P0）

**症状**：① 部分游戏未抓取到横幅；② KunGal 抓成音乐盘图。

**根因与修复**（四环节）：
| 环节 | 根因 | 修复 |
|---|---|---|
| Hikarinagi | covers[] 一直在响应里但**从未解析横幅**（只按 votes 选竖封面） | `_parseDetail` 接入横版挑选（与 NextMoe 同口径：有尺寸横版取面积最大 → 无尺寸候选兜底） |
| NextMoe | 缺宽高元数据的真横幅被直接跳过 | 两轮策略：无已确认横版时回退「无尺寸候选」 |
| MIX 链 | kun 论坛头图混入音乐盘图 | `banner_url` 链 nextmoe→hikarinagi→**kun 链尾** |
| 下载侧 | 源数据无尺寸校验，假横幅直落盘 | `downloadCover(minAspectRatio)` / `downloadBanner`：解码校验 ≥1.15，不达标删文件拒收（缓存+网络两路径都校验） |

**⚠️ 平台名确认**：开发者口述「EXTeMOE」与六源显示名（NextMoe/Hikarinagi/
KunGal/月幕GAL/TouchGal/Bangumi）均对不上。按 Luna Box 血统（hikarinagi
注释标注「参考 LunaBox metadata_hikarinagi.go」）与数据形态判定为
**Hikarinagi**；若实指其他平台，需补接该源。

### 8.2 相册浮层交互改版（详情窗）

- 图片区 `Positioned.fill` **全窗口**自由拖动（取消上下边框遮挡）
- 第三按钮「下一张」→「**恢复**初始居中」；新增上一张/下一张（←/→ 键同步）
- **抓取入口移除（纯相册）**：onFetch 回调链全清；抓取走详情窗编辑态

### 8.3 添加页相册系统

- `metadata_section.dart` 头部「相册 N」入口（N = 选中结果竖版+横幅计数，
  0 张禁用）
- 新组件 `cover_preview_overlay.dart`：磨砂全屏 + 竖/横切换 + 拖拽缩放 +
  网络图预览（NsfwImage.network + CachedNetworkImage，对齐卡片模式）
- 双类型抓取：抓取链已同时输出 cover_url + banner_url（§6 MIX 链），
  无需新增抓取逻辑

### 8.4 验证

- ✅ flutter analyze 9 改动文件 0 error
- ⏳ flutter test 被阵发 231 拦死（两轮退避重试均 231）；本轮未动
  listCoverGallery 等既有测试覆盖的 API
- ⏳ 未真机走查
'''
path = r'D:/CTLIB/docs/DEV/features/game_banner_cover.md'
shutil.copyfile(path, path + '.bak_gallery2')
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(feature)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    print('OK' if '§8 横幅抓取全链路加固' in f.read() else 'VERIFY FAIL', path)
