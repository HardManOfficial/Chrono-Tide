# Chrono Tide 开发治理体系

> 建立于 **2026-09-01**，用四层防线解决 AI 辅助开发中的两个顽疾：
> **① AI 越界修改、修一个 bug 冒出三个新 bug**
> **② 项目没有开发记录，AI 每次从零开始，项目越开发越陌生**

---

## 一、四层防线

| 层 | 机制 | 解决什么 | 位置 |
|----|------|---------|------|
| **第 1 层** | **Git 版本控制** | 改崩了能一键回滚、能看清 AI 究竟动了什么 | 仓库根，基线 tag `baseline-v2.0.1` |
| **第 2 层** | **AI 行为宪法** | 防越界、防顺手重构、强制先审计后执行 | [`AGENTS.md`](../../AGENTS.md) / [`CLAUDE.md`](../../CLAUDE.md) |
| **第 3 层** | **项目知识中枢** | 让 AI 接得上历史进度，不再从零开始 | 本目录 `docs/DEV/` |
| **第 4 层** | **工作流 Skill + 审计脚本** | 把流程固化成可复用动作，机械执行不靠自觉 | `.workbuddy/skills/`、`tools/dev/` |

---

## 二、docs/DEV 文件职责与更新时机

| 文件 | 作用 | **谁在什么时机更新** |
|------|------|---------------------|
| **`SESSION_HANDOFF.md`** | 会话交接单：现在在做什么、做到哪、下一步、有哪些坑 | **每次开发会话结束时必须更新**（最重要的一份） |
| **`STATUS_MAP.md`** | 功能模块地图：模块职责、入口文件、风险等级、关联文档 | 新增/重构模块时更新；发现模块状态变化时顺手改 |
| **`DECISIONS.md`** | 架构决策记录（ADR）：**为什么**这么设计 | 做出非显然的设计选择时立即追加 |
| **`DEV_LOG.md`** | 开发时间线：某天做了什么、改了哪些文件、结论与遗留 | **每次改动完成后追加一条**（追加，不覆盖） |
| **`features/`** | 功能档案：单个功能的目标、设计思路、实现位置、已知问题 | 开发某功能时建立并维护；改完必须回写状态 |
| **`tickets/`** | 需求单 / Bug 单：任务的结构化描述与验收标准 | 提需求时新建，完成后归档 |

**最低维护成本原则：** 如果时间紧，只维护 `SESSION_HANDOFF.md` 一个文件也能解决 80% 的问题。

---

## 三、日常工作流

### 你（项目主人）要做的

1. **提需求时**：在 `tickets/` 新建一份需求单（复制 `_TEMPLATE.md`），
   写清目标、范围、**明确不要动什么**。
2. **AI 输出《变更计划》后**：花 1 分钟核对范围，批准或驳回。
3. **收工时**：确认 AI 已更新 `SESSION_HANDOFF.md` 和 `DEV_LOG.md`。

### AI 要做的

```
读 SESSION_HANDOFF → 读 STATUS_MAP → 读相关 features/ 档案
        ↓
   只读审计，输出《变更计划》
        ↓
  【等待你批准】
        ↓
   执行 → analyze → test → git status/diff 自查越界
        ↓
   更新 DEV_LOG + features + SESSION_HANDOFF → commit
```

---

## 四、常用命令

```bash
# 看 AI 这次到底改了哪些文件（最重要）
git status --short
git diff --stat

# 回滚某个文件到改动前
git restore lib/xxx.dart

# 回滚到基线（慎用，会丢弃全部改动）
git checkout baseline-v2.0.1 -- lib/

# 看某个文件被改了多少
git diff lib/xxx.dart

# 静态检查（只检查改动的文件，不要全量）
./flutter/bin/flutter.bat analyze lib/path/to/file.dart

# 跑测试
./flutter/bin/flutter.bat test test/services/

# ⛔ 永远不要跑：git gc （在受限环境下会损坏 .git 目录）
```

---

## 五、已知的项目现状（2026-09-01 摸底）

- 代码规模：`lib/` 约 **10.8 万行** Dart 代码
- 测试覆盖：**15 个测试文件**，仅覆盖 `big_picture/` `services/` `smart_import/` 三块；
  `pages/` 与 `widgets/`（合计占代码量约 60%）**零测试覆盖**
- 测试基线：**181 通过 / 13 失败**（13 个失败为存量问题，在 `test/big_picture/widgets/`）
- 高风险巨型文件：见 [`STATUS_MAP.md`](./STATUS_MAP.md) 的「高风险文件」一节

> 测试覆盖不足意味着：改 UI 类代码后**必须人工验证**。
> AI 必须在报告里明确写出「已验证 / 未验证」的边界。
