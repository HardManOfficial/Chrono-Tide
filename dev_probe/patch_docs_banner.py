# -*- coding: utf-8 -*-
# 2026-10-04 横幅封面：DEV_LOG 顶部插入 + SESSION_HANDOFF 顶部插入（字节级替换，带 .bak 备份与复读验证）
import shutil, sys, io

def patch(path, marker, insert_text, backup_suffix='.bak_banner'):
    bak = path + backup_suffix
    shutil.copyfile(path, bak)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        content = f.read()
    if insert_text.strip()[:60] in content:
        print('SKIP (already patched):', path)
        return
    idx = content.find(marker)
    if idx < 0:
        print('MARKER NOT FOUND in', path)
        sys.exit(1)
    new_content = content[:idx] + insert_text + content[idx:]
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(new_content)
    # 复读验证
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        verify = f.read()
    ok = insert_text.strip()[:60] in verify
    print('PATCHED' if ok else 'VERIFY FAIL', path, '| len', len(content), '->', len(verify))

DEVLOG_ENTRY = '''## 2026-10-04 【功能】横幅封面（第二封面系统）——BPM 背景 / 主页大图横幅优先

- **背景**：竖向 2:3 封面在 BPM 背景与主页大图上是破坏性放大裁切（不完整+模糊）。
  新增游戏第二套封面数据「横幅封面」（横向高清 key visual，非截图），来源对标
  Luna Box 的元数据抓取。UI 优先级：横幅 → 竖向封面（两级回退）。
- **数据层**（game_data_format.dart）：game.json 新增可空 `banner_file`
  （**不升版本**，ADR-012 例外先例：storage_state）；列入覆盖黑名单（抓取派生，
  重复入库以本次为准）；`_downloadAndSaveBanner`（复用 CoverDownloadService，
  文件名 banner_<nonce>.<ext>）；`findBannerFile` 三级探测（传入值→json 键→
  banner.* 扫描）；toJson 仅非默认值输出（老文件字节级不变）。
- **模型层**（local_game_registry.dart）：`LibraryGame.bannerUrl`；scan 两分支
  同步填充 + registerExtractionComplete 即时探测。
- **抓取层**（luna_metadata_sdk + metadata_fetcher.dart）：NextMoe 解析详情
  `covers[]` 选横版（宽>高、面积最大；旧代码只读单数 cover 丢掉了数组）；
  KunGal `effective_banner_url/banner_url` 直通；VNDB kana API 无横幅字段
  （如实记录，不参与供给）；MIX 新增 banner_url 优先级链（NextMoe→KunGal）。
- **导入链**：writeGameDir 新参 bannerUrl；智能导入 / 批量导入透传；详情窗
  抓取 `_downloadBannerFromUrl`（落盘+写 json+同步 registry+广播）。
  下载安装链（extract_manager）暂不透传——云端资源记录无横幅数据源（P2）。
- **UI**：BPM `_resolveBackdropPath` 插横幅层（自定义背景→横幅→竖封面）；
  主页 `_bannerPathCache` + `_buildBannerImage`（限宽 960）+ 模糊背景层横幅
  优先 + 封面卡横幅时自适应 3:2（180×120）/无横幅 3:4。
- **验证**：进程内 analyzer 全部改动文件 errors=0（SDK 嵌套包用独立分析根
  ct_analyze_probe_sdk.dart）；新测试 game_banner_cover_test.dart 5 例静态
  0 error；⏳ flutter test 因阵发 231（C 盘 99%）未跑成，flutter_tester 实测
  异步 IO 静默死亡（连 await File.readAsString 都不返回），环境恢复后补跑；
  ⏳ 未真机走查。详见 docs/DEV/features/game_banner_cover.md。

---

'''

HANDOFF_ENTRY = '''📦 本轮 · 最后更新：**2026-10-04 上午·【功能】横幅封面（第二封面系统）**——
game.json 新增 `banner_file`（不升版本，ADR-012 例外先例）；抓取侧 NextMoe
`covers[]` 选横版 + KunGal banner_url 直通（VNDB 无横幅字段），MIX 加
banner_url 优先级链；智能/批量导入与详情窗抓取透传落盘；UI：BPM 背景
（自定义背景→横幅→竖封面）与主页大图（模糊背景层 + 封面卡自适应 3:2）横幅
优先回退竖封面。验证：进程内 analyzer 全改动文件 errors=0；新测试 5 例静态
0 error；⏳ flutter test 被 231（C 盘 99%）拦死未跑成 + 未真机走查。详见
docs/DEV/features/game_banner_cover.md。

'''

patch('docs/DEV/DEV_LOG.md', '## 2026-10-04 【修复】探索页预计时长永不显示', DEVLOG_ENTRY)
patch('docs/DEV/SESSION_HANDOFF.md', '📦 本轮 · 最后更新：**2026-10-04 上午·【修复】会社墙全量收录', HANDOFF_ENTRY)
print('DONE')
