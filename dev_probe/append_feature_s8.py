# -*- coding: utf-8 -*-
import io, shutil
path = r'D:/CTLIB/docs/DEV/features/game_banner_cover.md'
shutil.copyfile(path, path + '.bak_gallery2b')
feature = '''

---

## §8 横幅抓取全链路加固 + 相册交互改版 + 添加页相册（2026-10-05）

### 8.1 横幅抓取修复（P0）

**症状**：① 部分游戏未抓取到横幅；② KunGal 抓成音乐盘图。

**根因与修复**（四环节）：

| 环节 | 根因 | 修复 |
|---|---|---|
| Hikarinagi | covers[] 一直在响应里但从未解析横幅（只按 votes 选竖封面） | _parseDetail 接入横版挑选（与 NextMoe 同口径） |
| NextMoe | 缺宽高元数据的真横幅被直接跳过 | 两轮策略：无已确认横版时回退「无尺寸候选」 |
| MIX 链 | kun 论坛头图混入音乐盘图 | banner_url 链 nextmoe→hikarinagi→kun 链尾 |
| 下载侧 | 源数据无尺寸校验，假横幅直落盘 | downloadCover(minAspectRatio) / downloadBanner：解码校验 ≥1.15，不达标删文件拒收（缓存+网络两路径） |

**平台名确认**：开发者口述「EXTeMOE」与六源显示名均对不上。按 LunaBox 血统
（hikarinagi 注释标注「参考 LunaBox metadata_hikarinagi.go」）与数据形态判定为
**Hikarinagi**；若实指其他平台，需补接该源。

### 8.2 相册浮层交互改版（详情窗）

- 图片区 Positioned.fill **全窗口**自由拖动（取消上下边框遮挡，顶栏/工具条浮于图上）
- 第三按钮「下一张」→「恢复初始居中」；新增上一张/下一张按钮（←/→ 键同步）
- **抓取入口移除（纯相册）**：onFetch 回调链全清；抓取走详情窗编辑态

### 8.3 添加页相册系统

- metadata_section.dart 头部「相册 N」入口（N = 选中结果竖版+横幅计数，0 张禁用）
- 新组件 cover_preview_overlay.dart：磨砂全屏 + 竖/横切换 + 拖拽缩放 +
  网络图预览（NsfwImage.network + CachedNetworkImage，对齐卡片模式）
- 双类型抓取：抓取链已同时输出 cover_url + banner_url（§6 MIX 链），无需新增

### 8.4 验证

- ✅ flutter analyze 9 改动文件 0 error
- ⏳ flutter test 被阵发 231 拦死（两轮退避重试均 231）；本轮未动
  listCoverGallery 等既有测试覆盖的 API
- ⏳ 未真机走查
'''
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(feature)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    print('OK' if '§8 横幅抓取全链路加固' in f.read() else 'VERIFY FAIL')
