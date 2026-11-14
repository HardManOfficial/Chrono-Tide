# -*- coding: utf-8 -*-
"""Phase A-F 收尾：更新 DEV_LOG / SESSION_HANDOFF / join_unpack_scenarios_v2.md
字节级操作（LF），先备份 .bak_unpack6，写后复读验证。"""
import shutil
import sys

BAK = '.bak_unpack6'

DEV_LOG = 'docs/DEV/DEV_LOG.md'
HANDOFF = 'docs/DEV/SESSION_HANDOFF.md'
PLAN = 'docs/DEV/features/join_unpack_scenarios_v2.md'

new_log_entry = """## 2026-10-04 【功能】单文件导入智能解压五场景 v2——Phase A-F 全量落地（分卷/歧义/本体/自动尝试/交互收口）

- **背景**：开发者五条明确需求（分卷归并 / 多文件歧义挂起 / 本体识别终止 /
  未知后缀映射决策 / 交互总原则），方案 docs/DEV/features/join_unpack_scenarios_v2.md；
  拍板：缺卷直接失败+明确报因（用户改判挂起）、诱饵随临时层清理、扫描=顶层+子目录一层、
  包内密码提取纳入 F；本体判定=子目录≥1 或非说明散文件≥2（JSON body_rules 可配置）。
- **Phase A（25feed8 底座）**：ExtractCandidate / ExtractDecisionRequest（password/strategy/
  ambiguity/corrupt 四通道）/ ExtractDecisionResult + 统一钩子 onExtractDecision
  （onPasswordNeeded 保留回落）+ 扫描器重构 _scanForCandidates（顶层+子目录一层、按路径
  确定性排序、修复 folder/game.zip 漏检误判完成）+ waiting_for_strategy 决策窗补落地。
- **Phase B（c6ddf11）**：UnpackStore 默认候选链 14 后缀（auto_try_chains 持久化，.mp4/.mov
  顺序为需求方给定）+ 链纳入扫描门控（chainMode=planned.disguised，防真实游戏目录误伤）+
  _autoTryFormats（scratch 试解/每候选前清层/enc 走 _decryptEncLayer 且无密码源跳过防白耗 KDF）+
  决策记忆双回写（任务内 taskFormatByExt + 持久化映射表 isDefault 通用项）。
- **Phase C（511caac）**：detectVolumeGroup 五种分卷命名（7z.NNN / zip.NNN / partN.rar /
  rar旧式 rNN / zip旧式 zNN）+ buildPlan 分卷先行（缺卷→空层计划+明确缺段报因 →
  join_controller 弹计划窗前预检直接失败）+ 执行期喂首卷 firstVolumePath；
  习惯 signature 不含路径 → 同组天然命中（方案 §1.1 卷组指纹风险项不成立，未实现）。
- **Phase D（e0c3e2a）**：≥2 候选挂起「目标文件选择框」（kind:'ambiguity'）+
  _recommendCandidate 推荐引擎（majority_outlier：≥3 候选/后缀恰两类/异类仅 1/占比<1/3 →
  推荐并给理由；规则可启停持久化）+ 诱饵随临时层清理（零额外代码）。
- **Phase E（1c1d315）**：★修复 Phase B 隐患——循环顶 plan.realFormat（探针按后缀猜）
  覆盖尾部实证格式（auto-try 命中 enc 被打回）→ nextLayerFormatLocked 锁定标记，探针预设
  仅第 0 层生效；尾部判定链抽 _resolveUnknownFormat（applyMemory 门控，.exe 本体场景
  不读不写决策记忆防误伤真实主程序；顺带修决策窗文案双点）+ _probeSfx（孤 exe 静默
  7z t 试解）+ _resolveGameBody 本体三段判定（目录达标→finished / 孤 exe→SFX→续链 /
  否则「未找到本体」弹窗：仍以此收尾/取消）+ UnpackStore.bodyRules + showBodyNotFoundDialog。
- **Phase F（c853f2f 交互收口）**：corrupt 分类弹窗（kind:'corrupt'，_corruptMessage 密码排除→
  不支持→缺卷→CRC→通用兜底；「继续重试/取消解压」，重试清层重解）+ ⚠️顺带修 corrupt 重试
  密码队列空表坑（layerPwQueue 在重试循环外求值一次，seen 复用同 Phase B 坑）+ 7z 失败异常附
  stderr 摘要（裸 exitCode 无从分类）+ 磁盘预检落地（archive_inspector._freeDiskBytesOf 恒 null
  → GetDiskFreeSpaceExW FFI，UNC/非 Windows/异常 → null 静默跳过，随 NetworkPath 降级原则）+
  包内密码提取 _harvestPasswords（rar 注释 7z l -slt Comment + 同目录密码.txt/说明.txt 抽
  「密码/Password」行 → 第 0 层候选队列，优先内置表；纯增强项异常静默）；挂起态清理豁免不单做
  （缺卷挂起已改判直接失败，剩余挂起取消=放弃 → 既有失败清理语义自洽）。
- **改动文件**（6 commit 合计 7 个 lib 文件）：lib/services/extract_manager.dart（主体）、
  unpack_store.dart、unpack_plan.dart、archive_inspector.dart、lib/pages/join/join_controller.dart、
  join_page.dart、lib/pages/join/widgets/archive_plan_dialog.dart。
- **验证**：每 Phase 进程内 analyzer 探针 errors=0（extract_manager 13 warnings+1 info 与
  Phase D 基线逐条对应仅行号偏移，零新增）；commit 链 25feed8 → c6ddf11 → 511caac →
  e0c3e2a → 1c1d315 → c853f2f。⚠️ 未跑 flutter test（C 盘 99% 满，231 阵发期）、未真机走查；
  pubspec.lock 仍缺 pointycastle 条目（pub get 自动补）。
- **遗留**：批量/智能导入走老解压路径不识别分卷/本体（留后续统一）；分卷整组删源语义未做
  （F 裁剪项）；ambiguity 规则 UI 编辑器/映射环重复提示为 P2；多 exe 第二轮仅对第一个弹
  决策窗（SFX 轮已全员静默试解）。

"""

handoff_block = """📦 本轮 · 最后更新：**2026-10-04 晚·【功能】智能解压五场景 v2 Phase A-F 全量落地**——
分卷归并（五种命名识别+缺卷直接失败明确报因+执行期喂首卷）/ 多文件歧义挂起选择框+推荐引擎 /
本体识别三段判定（目录达标 / 孤 exe SFX 试解续链 / 未找到本体弹窗）/ 未知后缀自动尝试链
（14 后缀+伪装链门控+决策记忆回写）/ 交互总原则收口（corrupt 分类弹窗「继续重试/取消」+
磁盘预检 GetDiskFreeSpaceExW FFI 落地+包内密码提取 rar 注释/密码.txt）。
commit 链：25feed8→c6ddf11→511caac→e0c3e2a→1c1d315→c853f2f（每 Phase 一个）。
方案契约：docs/DEV/features/join_unpack_scenarios_v2.md（状态行已同步）。
⚠️ 全程进程内 analyzer 探针验证 errors=0（warning 与基线一致零新增）；未跑 flutter test
（C 盘 99% 满）、未真机走查。已知边界：批量/智能导入走老解压路径不识别分卷/本体。
⏳ 待办：C 盘腾挪后补跑原生 analyze + flutter test + pub get（补 pointycastle.lock 条目）
→ 真机全链走查（分卷缺卷/伪装链/歧义/SFX exe/损坏重试/密码提取）。

"""

plan_old = "> 阶段 A 产物（只读审计完成，本文档为《变更计划》底稿）。**状态：待开发者批准，未动任何代码。**"
plan_new = ("> 阶段 A 产物（《变更计划》底稿）。**状态：已批准并全部落地（2026-10-04，Phase A-F 六连提交："
            "25feed8 底座 → c6ddf11 自动尝试 → 511caac 分卷归并 → e0c3e2a 多文件歧义 → "
            "1c1d315 本体识别+Phase B 隐患修复 → c853f2f 交互收口）。拍板结果：缺卷直接失败+明确报因"
            "（用户改判挂起）、诱饵随临时层清理、扫描=顶层+子目录一层、包内密码提取纳入 F；"
            "本体判定规则 JSON 可配置（unpack_settings.json 'body_rules'）。**")

log_anchor = "## 2026-10-04 【功能】单文件导入智能解压 第四轮+Phase 4"
handoff_anchor = "# SESSION_HANDOFF — 会话交接单"


def patch(path, fn, label):
    with open(path, 'rb') as f:
        data = f.read().decode('utf-8')
    shutil.copyfile(path, path + BAK)
    out = fn(data)
    if out == data:
        print(f'[FAIL] {label}: 内容未变化（锚点未命中）')
        sys.exit(1)
    with open(path, 'wb') as f:
        f.write(out.encode('utf-8'))
    # 复读验证
    with open(path, 'rb') as f:
        back = f.read().decode('utf-8')
    if back != out:
        print(f'[FAIL] {label}: 复读不一致（落盘失败）')
        sys.exit(1)
    print(f'[OK] {label}: 已写入并复读验证 ({len(out)} chars)')


def patch_devlog(d):
    i = d.find(log_anchor)
    if i < 0:
        return d
    return d[:i] + new_log_entry + d[i:]


def patch_handoff(d):
    i = d.find('📦 本轮')
    j = d.find(handoff_anchor)
    if i < 0 or j < 0 or j <= i:
        return d
    return d[:i] + handoff_block + d[j:]


def patch_plan(d):
    if plan_old not in d:
        return d
    return d.replace(plan_old, plan_new, 1)


patch(DEV_LOG, patch_devlog, 'DEV_LOG')
patch(HANDOFF, patch_handoff, 'SESSION_HANDOFF')
patch(PLAN, patch_plan, 'PLAN doc')
print('ALL DONE')
