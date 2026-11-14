# -*- coding: utf-8 -*-
"""2026-10-05 实机测试两问题修复的文档同步（DEV_LOG / SESSION_HANDOFF / features 档案）。
大文档 Edit 工具历史上不落盘 → 统一走 python 字节级替换，先备份后写，写后复读验证。"""
import shutil, sys

BASE = r'D:\CTLIB'

DEVLOG = BASE + r'\docs\DEV\DEV_LOG.md'
HANDOFF = BASE + r'\docs\DEV\SESSION_HANDOFF.md'
FEATURE = BASE + r'\docs\DEV\features\join_unpack_install_center_pipeline.md'

devlog_entry = '''## 2026-10-05 【修复+功能】实机测试两问题——计划参数漏传修复 + 网盘过审壳（尾部拼接 zip）支持

- **背景**：C1-C5 全量实机测试回报两问题：① `黄昏的禁忌之药.7z.lz4`（2455MB）计划窗正确识别 LZ4
  路线但解压零进展即失败（安装中心只显示兜底文案）；② `Wu5U4_重力势能【PC】.mp4`（2634MB）无法导入。
- **根因 ①（实锤）**：C1 改造时 `global_install_center._startExtraction` 的 `extractMgr.start(...)`
  漏传 `unpackPlan` → extract_manager 退回「从文件名猜格式」老路，把 `.7z.lz4` 猜成「第一层 .7z」，
  7z 打不开 lz4 壳（Release/logs 8 份日志同一模式 `Cannot open the file as [7z] archive`）。
  顺带发现失败文案缺陷：`_rollback` 先 `_emitPhase(failed)` 再 `_emitError`，页面在 phase 回调里
  同步读 errorMessage 拿到旧值 null（且页面未监听 error 流）→ 永远显示兜底文案。
- **根因 ②（实锤）**：该 mp4 实为网盘过审壳——真 MP4 头（2.5GB 视频数据）+ 8.3MB 起尾部拼接 zip
  （内含 2.75GB rar，EOCD 后还有 ~11.3KB 收尾）。头部魔数嗅探只认前缀 → 普通文件拒绝。
  内置 7z 23.01 按 EOCD 打开此文件完全无视前缀（`7z l` exit=0 直解验证）。
- **改动**（commit a4e9044 + d5676bd）：
  - `global_install_center.dart:646` 补 `unpackPlan: _currentTask?.unpackPlan` 透传（一行）；
  - `_rollback` 交换 `_emitError`/`_emitPhase` 顺序 + 去 `Exception:` 前缀（失败显示真实原因）；
  - `archive_inspector.dart` `sniffSync` 新增尾部 256KB EOCD 反查（`_sniffTrailingZip`），两路
    结构校验防误报（路径 A：cd offset+size ≤ 文件长；路径 B：ZIP64 占位 + 紧前方 locator 兜底）；
  - `extract_manager.dart` `_extract7z` 退出码 `!= 0` → `> 1`（7z 语义 1=非致命警告，拼接包解压
    必带「There are data after the end of archive」；CRC/缺卷等致命 2+ 仍失败）。
- **验证**：进程内 analyzer 探针 3 文件 errors=0（warning 全存量）；flutter_tester 离线探针
  （`.workbuddy/tmp_unpack_probe/sniff_probe.dart`）13/13 全绿——含真实 mp4 判 zip+disguised、
  构造样本路径 A/B、非法 EOCD/纯 mp4 不误报、zip/7z/zip.lz4 回归；python 直读用户文件
  验证 EOCD 结构（cd_size=107、cd_off+size≤len 通过、locator 紧贴 EOCD）。
- **⚠️ 未验证**：flutter test 挂 CreateFile failed 231（C 盘仅剩 1.2G 满，管道耗尽）——新单测
  `test/services/archive_inspector_test.dart`（9 用例）已写好待补跑；真机复测两条链路待用户执行。
- **遗留**：C 盘空间是 flutter test 恢复的前置条件；extract_manager 看门狗+决策超时兜底（P1）。

'''

handoff_entry = '''📦 本轮 · 最后更新：**2026-10-05 深夜·【修复+功能】实机测试两问题闭环**——
① `.7z.lz4` 解压零进展失败 = C1 漏传 `unpackPlan`（一行透传恢复计划语义）+ `_rollback` 发错误
信息与切 failed 相位顺序颠倒（交换 + 去 Exception 前缀，失败卡片显示真实原因）；② mp4 无法导入
= 网盘过审壳「真 MP4 头 + 尾部拼接 zip（内含 rar）」：sniffSync 新增尾部 256KB EOCD 反查（两路
结构校验防误报）+ `_extract7z` 退出码 >1 放行（7z warning 语义）。内置 7z 按 EOCD 直解此类文件
（实测验证），buildPlan 自动生成「zip → rar」两层计划。commit：a4e9044→d5676bd。
✅ 进程内探针 0 error；flutter_tester 离线探针 13/13 全绿（含用户真实 mp4 判 zip+disguised）。
⚠️ flutter test 挂 231（C 盘 1.2G 满）——新单测 9 用例待 C 盘腾挪后补跑。
⏳ **下一步：用户真机复测两条链**（.7z.lz4 全链 + .mp4 导入→计划窗 zip→rar→解压→确认入库）。

'''

feature_note = '''> 2026-10-05 实机测试修复（a4e9044 + d5676bd）：① `_startExtraction` 漏传 unpackPlan 已补
> 透传（计划窗确认的层序/密码真正生效）；② `_rollback` 先发错误再切 failed 相位（失败显示真实
> 原因）；③ 新支持网盘过审壳「视频头+尾部拼接 zip」：sniffSync 尾部 EOCD 反查（256KB 窗、两路
> 结构校验）+ `_extract7z` 退出码 >1 放行 7z 非致命警告；flutter_tester 离线探针 13/13 全绿
> （含真实样本判 zip+disguised）；flutter test 待 C 盘腾挪后补跑，真机复测待用户执行。

'''

def patch(path, anchor, insert, backup_suffix):
    bak = path + backup_suffix
    shutil.copyfile(path, bak)
    data = open(path, encoding='utf-8').read()
    if anchor not in data:
        print(f'ANCHOR NOT FOUND in {path}'); sys.exit(1)
    data = data.replace(anchor, insert + anchor, 1)
    open(path, 'w', encoding='utf-8', newline='').write(data)
    # 复读验证
    back = open(path, encoding='utf-8').read()
    ok = insert in back
    print(f'{path}: write={"OK" if ok else "FAILED"} (backup: {bak})')
    return ok

ok1 = patch(DEVLOG, '## 2026-10-04 【功能】解压流水线重构', devlog_entry, '.bak_unpack7')
ok2 = patch(HANDOFF, '📦 本轮 · 最后更新：**2026-10-04 深夜', handoff_entry, '.bak_unpack7')
ok3 = patch(FEATURE, '> 状态：**C1-C5 已落地**', feature_note, '.bak_unpack7')

sys.exit(0 if (ok1 and ok2 and ok3) else 1)
