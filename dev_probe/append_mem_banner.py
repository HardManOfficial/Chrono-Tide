# -*- coding: utf-8 -*-
import io
path = r'D:/CTLIB/.workbuddy/memory/2026-10-04.md'
text = '''

---

## 横幅封面（第二封面系统）——BPM 背景/主页大图横幅优先（commit 446074d）

- 需求：竖 2:3 封面在 BPM 背景/主页大图是破坏性放大裁切 → 引入横向高清横幅封面（非截图）作为第二套标准数据，横幅→竖封面两级回退。
- 全链路：game.json `banner_file`（不升版本，storage_state 先例）→ LibraryGame.bannerUrl → SDK（NextMoe covers[] 选横版 / KunGal banner_url 直通 / **VNDB kana API 无横幅字段**）→ MIX banner_url 优先级链（NextMoe→KunGal）→ 智能导入/批量导入/详情窗透传 → BPM 背景（自定义背景→横幅→竖封面）与主页 UI（模糊背景层横幅优先 + 封面卡横幅时 3:2）。
- 验证：进程内 analyzer 全改动文件 errors=0（SDK 嵌套包需独立分析根，新增 .workbuddy/analyze_probe/ct_analyze_probe_sdk.dart）；测试 5 例（test/services/game_banner_cover_test.dart）已写但 flutter test 被 231 拦死未跑。
- 🔴 新环境事实：flutter_tester 离线探针下**异步 dart:io IO 会静默死亡**（await File.readAsString() 不返回、退出码 0、无报错）——探针只可用同步 File 落盘；GameJsonData 构造器 required formatVersion（写测试别漏）。
- 遗留：环境恢复补跑 flutter test；真机走查；P2 存量回填（参照 CompanyLogoService.autoFetchMissingLogos 模式）；P2 下载安装链（需云端资源记录补横幅字段）。详见 docs/DEV/features/game_banner_cover.md。
- ⚠️ 工作区仍有并行会话未提交改动约 16 个 M 文件（main.dart/openlist/gamepad 系列/payment_modal 等），本轮提交只含本任务 15 文件，未触碰。
'''
with io.open(path, 'a', encoding='utf-8', newline='') as f:
    f.write(text)
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    ok = '446074d' in f.read()
print('APPENDED+VERIFIED' if ok else 'VERIFY FAIL')
