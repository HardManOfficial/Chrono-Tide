# -*- coding: utf-8 -*-
"""C6 文档同步：DEV_LOG 头插 / SESSION_HANDOFF 头插 / 方案档案状态行更新。写后复读验证。"""
import io
import sys

def read(p):
    with io.open(p, 'r', encoding='utf-8', newline='') as f:
        return f.read()

def write(p, s):
    with io.open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)
    back = read(p)
    assert back == s, 'VERIFY FAILED: ' + p
    print('OK  ', p, len(s.encode('utf-8')), 'bytes')

# ── 1) DEV_LOG.md：在五场景条目之前插入新条目 ──
p1 = 'docs/DEV/DEV_LOG.md'
devlog = read(p1)

entry = '''## 2026-10-04 【功能】解压流水线重构——本地压缩包任务并入安装中心（C1-C5 落地）

- **背景**：真机「请稍候」十分钟冻结 + 取消卡死 + `.7z.lz4` 观感停点的审计收口
  （方案 `docs/DEV/features/join_unpack_install_center_pipeline.md`；冻结根因 =
  JoinProgressDialog 是 OverlayEntry 里的 StatelessWidget，无 markNeedsBuild 无订阅，
  内容永不重建）。用户拍板一次性做完 C1-C6 供全量实机测试。
- **C1（0fb86d6）**：InstallTask 支持 localArchive（kind/localArchivePath/unpackPlan/
  localCoverFilePath/双标题/元数据源等 8 新字段，downloadUrl 可空化）；
  InstallPhase 新增 awaitingConfirmation（确认窗挂起队列不推进，成功终态=确认入库完成）；
  四个注入回调（onUnpackDecisionRequest/onUnpackFinishConfirm/onUnpackImportCompleted/
  onUnpackImportCancelled）；_executeTask 网络预检仅 download、下载段分流、解压后路由
  _finishLocalArchive（改名→元数据→注册→习惯记忆→删源包勾选），catch 对 localArchive
  跳过终极兜底直接回滚；_startExtraction 输入源按 kind 取 + onExtractDecision 透传 +
  failed 直接抛（确认窗才是成功闸门）；cancelCurrentTask 对 awaitingConfirmation no-op。
- **C2（52932b6）**：main_container 注入五类执行期决策弹窗（password/strategy/
  ambiguity/body/corrupt，迁自 join_page decisionProvider 样板）+ 确认入库窗
  （showExtractFinishDialog → 服务层 UnpackFinishOutcome 转换）+ 完成/放弃 toast；
  dispose 解绑，防壳销毁后触达失效 context。
- **C3（2946705）**：join_controller.startExtractFlow 改为构造 InstallTask 提交
  GlobalInstallCenter.submitTask（表单数据构造时全部快照，resetForm 均为重新赋值
  不清快照），不再直接驱动 GlobalTaskManager 共享 ExtractManager；gameId=local_+毫秒
  时间戳；提示已入队后 resetForm；库页刷新依赖 registerExtractionComplete 末尾
  _notifyStructural 自动通知。
- **C4（7b05daf，-798 行）**：删 JoinProgressDialog 机制（join_page 进度 Overlay 全套 +
  progress_dialog.dart 206 行整删）+ join_controller 解压进度状态机（_isProgress*/
  _isCancelled/initListeners/_onExtract* 四监听/handleExtractSuccess/_adoptExtractedDir/
  _finalizeAdoptedExtraction/resolveExtractionTargetDir/_renameExtractedDir/_habit*/
  _PendingCoverData/resetProgress/cancelOperation/共享 ExtractManager 接线拆卸）——
  职责全部迁到安装中心 _finishLocalArchive 链；startCopyFlow 保留（文件夹/exe 拷贝流程）。
- **C5（8b9dc7a）**：install_center_page 适配——switch 新增 awaitingConfirmation case
  （待确认占位 UI）/ _buildExtractingUI 补取消按钮（DownloadButton isExtracting
  「取消获取」）/ header 徽标三态（下载中/解压中/待确认）。
- **验证**：flutter analyze 全程被 231（管道耗尽阵发）拦死 → 进程内 analyzer 探针
  每步 0 error（C1 抓到 1 个真实类型错误已修：onExtractDecision 闭包可空 Future）；
  五改动文件 + extract_manager + BPM shell 联合探针 0 error（warning 全为内核存量）；
  全仓 grep 无已删符号代码级残留。⏳ 未跑 flutter test（231 未恢复）、未真机走查
  ——待用户全量实机测试。
- **遗留**：① extract_manager.dart:3399 注释描述旧遮罩行为已过时（内核本次不动）；
  ② JoinProgressDialog 两处历史注释残留（join_controller，仅注释无代码）；
  ③ ExtractManager 进程 await 看门狗 + 决策 Completer 兜底超时（P1 单独提交）；
  ④ 批量/智能导入仍走老路径不识别分卷/本体。

'''

anchor1 = '## 2026-10-04 【功能】单文件导入智能解压五场景 v2'
assert anchor1 in devlog, 'DEV_LOG anchor missing'
assert entry not in devlog, 'DEV_LOG already patched'
devlog = devlog.replace(anchor1, entry + anchor1, 1)
write(p1, devlog)

# ── 2) SESSION_HANDOFF.md：在第一个「📦 本轮」之前插入新段 ──
p2 = 'docs/DEV/SESSION_HANDOFF.md'
handoff = read(p2)

block = '''📦 本轮 · 最后更新：**2026-10-04 深夜·【功能】解压流水线重构 C1-C5——本地压缩包任务并入安装中心**——
单文件导入的压缩包解压从「JoinController 直驱共享 ExtractManager + 冻结的 JoinProgressDialog」
整体切换为「安装中心串行队列 + awaitingConfirmation 确认收口」：InstallTask 新增 localArchive
形态（8 新字段）/ InstallPhase + awaitingConfirmation（挂起即不推进队列，成功终态=确认入库完成）/
执行期五类决策弹窗与确认入库窗由 main_container 注入 / 旧进度窗机制与解压进度状态机整删
（C4 净 -798 行，progress_dialog.dart 整删）/ 安装中心 UI 适配（待确认占位 + 解压取消按钮 +
三态徽标）。commit 链：0fb86d6→52932b6→2946705→7b05daf→8b9dc7a（C1-C5 各一）。
方案契约：docs/DEV/features/join_unpack_install_center_pipeline.md（状态行已同步）。
⚠️ 全程进程内 analyzer 探针 0 error（231 阵发拦死原生 analyze）；未跑 flutter test、
未真机走查——⏳ **下一步就是用户全量实机测试**（导入压缩包全链：计划窗→队列→决策弹窗→
确认文件夹名→入库/放弃；以及解压中取消、队列多任务串行）。
遗留：extract_manager 看门狗+决策超时兜底（P1 单独提交）、批量/智能导入不识别分卷/本体。

'''

anchor2 = '📦 本轮 · 最后更新：'
idx = handoff.find(anchor2)
assert idx >= 0, 'HANDOFF anchor missing'
assert block not in handoff, 'HANDOFF already patched'
handoff = handoff[:idx] + block + handoff[idx:]
write(p2, handoff)

# ── 3) 方案档案：状态行更新 ──
p3 = 'docs/DEV/features/join_unpack_install_center_pipeline.md'
plan = read(p3)

old_status = '> 状态：**待批准**（阶段 A 产出，未动任何代码）'
new_status = ('> 状态：**C1-C5 已落地**（0fb86d6→52932b6→2946705→7b05daf→8b9dc7a）；'
              'C6 文档同步本条。进程内探针 0 error；⏳ 未跑 flutter test、待全量真机走查。')
assert old_status in plan, 'PLAN status anchor missing'
assert new_status not in plan, 'PLAN already patched'
plan = plan.replace(old_status, new_status, 1)
write(p3, plan)

print('ALL DONE')
