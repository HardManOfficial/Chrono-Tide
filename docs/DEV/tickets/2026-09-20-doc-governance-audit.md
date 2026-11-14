# 需求单：开发规范与文档治理体系审计（2026-09-20）

| 项 | 值 |
|----|-----|
| **类型** | 优化（文档/流程治理） |
| **优先级** | P0（前 3 项会让 AI 直接走错路） |
| **提出日期** | 2026-09-20 |
| **状态** | 待评估 |
| **关联功能档案** | —（本文档审计对象：`AGENTS.md` / `CLAUDE.md` / `docs/DEV/*`） |

---

## 1. 背景与目标

2026-09-01 建立的「四层防线」治理体系（见 `docs/DEV/README.md`）在**结构上是对的**，
19 天的高强度开发也证明它确实压住了「AI 越界」这个老毛病。用户认为仍不够完善，
本单做一次**只读审计**（本单未改动任何代码，也未改动任何既有文档）。

结论先行：**根因不是"文档写得太少"，而是"会变的事实被复制到 6 个文档，且没有单一
事实源、没有时效字段"。** 复制必分叉 —— 现在 4 处副本已经是错的。

---

## 2. 审计发现

### 🔴 P0-1 易变事实多副本，且多数已过期（单一事实源缺失）

同一个数字散落在 6 个地方，现在 4 个是错的：

| 事实 | 文档里写的 | 实测值 | 位置 |
|------|-----------|--------|------|
| 测试基线 | **181 通过 / 13 失败** | **794 / 0** | `AGENTS.md:142`、`CLAUDE.md:28`、`docs/DEV/README.md:92` |
| analyze 基线 | 约 563 条 | **550 条** | `AGENTS.md:143`、`CLAUDE.md`（隐含） |
| 测试文件数 | 15 个 | **70 个**（`test/**/*_test.dart`） | `docs/DEV/README.md:90` |
| 代码规模 | 约 190 个 Dart 文件 / 10.8 万行 | **268 个 / `lib` 5.5 MB** | `CLAUDE.md:66`、`README.md:89` |
| 项目/模块版本 | v2.0.1 | BPM 已 **v3.10.2** | `AGENTS.md:8`、`CLAUDE.md:64` |

**危害不是"数字旧"，而是它会主动误导**：`CLAUDE.md:28-29` 至今在教 AI
「当前 181 通过 / **13 失败**，13 个失败是存量问题，不要试图修」——那 13 个失败
早已全部修掉（现存 0 失败）。AI 若照着做，会把**真实回归**当成存量放行。

### 🔴 P0-2 `SESSION_HANDOFF.md`（最重要的必读文件）已失去交接功能

- 体量 **80 KB / 948 行**；**前 321 行全是历史元叙述堆叠**，第一个 `## ` 章节出现在 `:322`。
- 同一份文件里存在 **3 个写着「（最新）」的条目**，AI 无法判断谁是当前状态：
  - `:327` `### 本次：导入功能审查 + 批 1 数据安全护栏（最新）`
  - `:436` `### 本次：侧边栏半圆收展按钮适配（最新）`
  - `:454` `### 前情：探索页加载机制优化（最新）`
- **头部与正文分叉**：头部已写到 2026-09-20 的 BPM v3.10.2，而
  `## 🔥 当前正在进行` 里最新一条仍停在 09-12 的导入审查。
- 它同时承担了「交接单 + 变更历史 + 已知坑 + 冻结事项」四种职责，而
  `README.md:31` 的原则是"只维护它一个也能解决 80%"——体量一大，这条原则就失效了。

### 🔴 P0-3 `STATUS_MAP.md` 停更 19 天，规模数字差近一倍，且有一处内容错误

`:6` 写着「最后更新：2026-09-01」，而实际代码已变化极大：

| 文档声明 | 实测 | 位置 |
|---------|------|------|
| `lib/pages/` 24 文件 | **26** | `:34` |
| `lib/services/` 51 文件 | **79** | `:53` |
| `lib/widgets/` 55 文件 | **74** | `:145` |
| `lib/theme/` 11 文件 | **14** | `:165` |
| `lib/big_picture/` 18 文件 | **35**（近乎翻倍） | `:180` |
| `.trae/documents/` 33 篇 | **34** | `:234` |
| `docs/` 26 篇 | **53**（索引漏掉一半） | `:247` |

**内容错误（比数字更危险）**：`:186` 把 `lib/big_picture/focus/` 描述为
「焦点网格策略」。v3.10 起该目录是**三级板块焦点系统**
（`bpm_zone_focus_controller.dart` / `bpm_focus_domain.dart` / `bpm_focus_zone.dart`），
`focus_grid_policy.dart` 已是旧实现。AI 按图索骥会找到**错的入口**。

### 🟠 P1-4 第 4 层防线（技能 / 脚本）在"强制约束文件"里没有入口

`AGENTS.md` 全文 **0 次**提到 `skills` / `memory` / `tickets` / `_TEMPLATE`
（实测 grep 无命中），而它们是：
- `README.md:16` 明确列为第 4 层防线；
- 实际承载了最多增量知识（`.workbuddy/skills/chronotide-dev` 里那批"实测坑"，
  以及 `.workbuddy/memory/MEMORY.md` 的铁律收敛）。

现状盘点：**项目级技能只有 1 个**（`.workbuddy/skills/chronotide-dev`），
另外 5 个可复用技能在**用户级**（`~/.workbuddy/skills/`：`ai-collab-governance`、
`ct-feature-research`、`flutter-engine-probe`、`flutter-golden-visual-verify`、
`git-pack-truncation-rescue`）—— **两级共 6 个技能，没有任何项目文档登记它们**。
新接手的 AI（尤其非 WorkBuddy 的 Cursor / Trae）不知道它们存在，等于白写。

### 🟠 P1-5 ADR 有系统性缺口（停在 ADR-013）

`docs/DEV/DECISIONS.md` 序号只到 **ADR-013**（启动 exe 唯一事实源），
而 2026-09-09 之后产生的一批**非显然决策**只活在 features 档案里，一条都没进 ADR：

| 决策 | 现只存在于 |
|------|-----------|
| BPM v3 Cinema 舞台重构（推翻 v2 双栏） | `features/big_picture_v3_cinema.md` |
| 方向遍历必须用 `inDirection`，禁用 `findFirstFocusInDirection` | 同上 §16 |
| 每个二级板块必须 `BpmFocusZone` + `BpmFocusDomain` 成对装配 | 同上 §17 |
| 手柄「双击 A ≡ 鼠标双击」（单击延迟 300ms 落地） | 同上 §17 |
| 模态门控自持计数（`ModalRoute.isCurrent` 有 250ms 空窗） | 同上 §17 |
| 桌面复用控件在 BPM 内不可聚焦 → 注入式操作条 | 同上 §18 |

按 `README.md:26` 的约定（"做出非显然的设计选择时**立即**追加"），这些都是漏项。
后果很具体：下一个 AI 在 DECISIONS 里查不到，就会**重新设计一套**（正是治理体系
要防的事）。

### 🟠 P1-6 没有测试指南，测试知识散落 4 处

基线在 `README.md`、🧪 标记在 `STATUS_MAP.md`、收尾命令在 `AGENTS.md`、
flaky 清单与"判定失败归属"在 `chronotide-dev` 技能里。缺一份统一回答
「测试放哪 / 怎么命名 / 怎么单跑 / 哪些是 flaky / 失败怎么判归属 / 基线谁说了算」
的文档 —— 而这正是本项目最需要机械化的部分（70 个测试文件、794 条用例）。

### 🟠 P1-7 老文档与权威文档并存，且未标记状态

- `docs/bpm_architecture.md`：自称描述 **BPM 技术架构 + 焦点系统设计**，
  版本 **v1.3.1 / 2026-07-06**（正文讲的是"Ubiquity 风格 5 层叠加"，早已被
  v3 Cinema 重构推翻）。**没有任何"已过时"标记** —— AI 极可能拿它当权威。
- `docs/big_picture_mode.md`：v1.3 用户手册，"适用于 CTLIB v0.8+"。
- 根目录 `UI_DEVELOPMENT_GUIDE.md`：v2.0 / 2026-06-03，与 `AGENTS.md`/`CLAUDE.md`
  并列在根目录，地位不明。

**同类文档已有正确做法可抄**：`docs/DEV/features/nsfw_filter_v1_ABANDONED.md` 开头
就是 `🗄️ 这是 v1 方案的存档副本，仅用于追溯决策依据，不要再照它施工` —— 说明
"状态横幅"这一步本项目已经会做，只是没有把它推成**规范**。

### 🟠 P1-8 功能档案普遍不遵循模板

`features/_TEMPLATE.md` 要求 6 字段表（状态 / 优先级 / 创建日期 / 最后更新 /
关联需求单 / 关联决策）。实测抽样 4 份**全部不合规**，且**普遍缺「最后更新」**：

- `big_picture_v3_cinema.md`：`> 建立日期：2026-09-09　状态：v3.1 导入线已推翻重做…`
  （状态描述停在 v3.1，而正文已到 v3.10.2）
- `network_reliability.md`：`> 状态：P0 已修复…（2026-09-08 / 2026-09-18）`
- `gamepad_adaptation_implementation_plan.md`：只有"产出时间 2026-09-19"
- `library_page_experience_overhaul_plan.md`：只有"创建：2026-09-14"

没有「最后更新」= AI 无法判断档案新鲜度，只能整读 67 KB 才知道现状。

### 🟡 P2-9 文档体积无治理规则（与 memory 目录对比明显）

| 文件 | 体量 |
|------|------|
| `docs/DEV/DEV_LOG.md` | **270 KB / 3909 行** |
| `docs/DEV/SESSION_HANDOFF.md` | 80 KB / 948 行 |
| `docs/DEV/features/big_picture_v3_cinema.md` | 67 KB / 961 行 |
| `docs/` 合计 | **1.65 MB / 53 篇 / 25,898 行** |

`AGENTS.md:1-20` 要求"DEV_LOG 只看最近 3 条"，但**没给命令**（`head -60`），
AI 默认整读 → 上下文爆炸或干脆跳过。而 `.workbuddy/memory/` 已有明确的
「30 天蒸馏 + 归档」规则，`docs/DEV/` 反而一条都没有。

### 🟡 P2-10 提交信息规范未文档化

实际在用的形式（近 40 条统计）：`fix` 12 / `feat` 11 / `docs` 9 / `test` 1 /
`refactor` 1 / `perf` 1，多数带 scope（`fix(bpm):` `docs(skill):`），少数不带。
但 `AGENTS.md` 只写了"信息写清**为什么**改"，**没有任何格式定义**
（type 全集 / scope 词表 / 中英文 / 是否要求正文）。新 AI 必然各写各的。

### 🟡 P2-11 `CHANGELOG.md` 与 `DEV_LOG.md` 职责重叠、无边界

`CHANGELOG.md` 16 KB，停在 **2026-09-14**；`DEV_LOG.md` 每天更新到 09-20。
两者都记"做了什么"，但**没人写清 CHANGELOG 是面向谁**（用户？发布？）和
"谁在什么时机更新它"。分叉是时间问题。

### 🟡 P2-12 临时脚本与产物无归置规则

`.workbuddy/` 顶层现有 **27 个 `tmp_*.py`** + `out_$name.bmp` + `test_full.log`
（历次会话产物，含我自己上一轮留的 `dev_*.py`）。规范没写"临时脚本放哪、何时删"，
于是每次都往根目录丢。

### 🟡 P2-13 三个现成脚本没有用法说明

`tools/dev/` 里 `check-changes.bat` / `verify.bat` / `rollback.bat` 存在（`README.md:16`
提到、技能里有一张表），但 `AGENTS.md` / `docs/DEV/README.md` 都没写"它们各跑什么、
什么时候用"。既然做了工具，就应该在收尾清单里点名使用。

### 🟡 P2-14 打包/发布流程未纳入 DEV 体系

唯一的打包文档是 `docs/打包规范与流程说明_V0.8.md`（**2026-05-21**），
而实际链路是 `ChronoTide_Setup.iss` / `build_windows.bat` / `build_windows_mirror.bat` /
`安装包输出/` / `打包脚本/`。当前是否仍然有效无人能确认，DEV 体系里也没有入口。

### 🟡 P2-15 `test/failures/` 残留未登记

`test/failures/` 有 4 张 2026-09-10 的 golden 失败图（`rail_art_dark_*.png` 等），
未被 `STATUS_MAP.md §九 已知待清理项` 收录。

---

## 3. 优化方案（建议）

### 3.1 结构性一招：建立单一事实源

新增 **`docs/DEV/BASELINE.md`（唯一的"当前事实表"）**，只放**会变**的东西：

```markdown
> 最后核验：YYYY-MM-DD（核验命令：tools/dev/verify.bat）
| 事实 | 当前值 | 核验命令 |
|------|--------|---------|
| 测试基线 | 794 / 0 | flutter test |
| analyze 基线 | analyze lib：550 条存量 info/warning | flutter analyze lib |
| 代码规模 | lib 268 个 dart 文件 / 5.5 MB | find lib -name "*.dart" | wc -l |
| 测试文件数 | 70 | find test -name "*_test.dart" | wc -l |
| Flutter / Dart | 3.24.3 / 3.5.3 | ./flutter/bin/flutter.bat --version |
| flaky 用例 | test/smart_import/、game_move_service_test（并发全量偶发） | — |
```

然后**其余文档只写"见 BASELINE.md"，不再复制数字**。这一条能一次性消灭 P0-1，
并防止以后再分叉。

### 3.2 逐项对应动作

| # | 问题 | 动作 | 触及文件 |
|---|------|------|---------|
| 1 | P0-1 基线分叉 | 新增 `BASELINE.md`；`AGENTS.md`/`CLAUDE.md`/`README.md` 的数字改为引用 | 4 个文件（含新增） |
| 2 | P0-2 交接单失效 | `SESSION_HANDOFF.md` 改造为**只留当前**（≤150 行）：当前状态 / 下一步 / 阻塞 / 已知坑；历史条目迁到 `docs/DEV/archive/handoff-<年月>.md`；**规定同一文件内只允许一个「当前」条目**，且必须有 `> 最后更新：` | 1 改 + 1 新增 + 规则 |
| 3 | P0-3 模块地图过期 | `STATUS_MAP.md` 全量校正（含 `focus/` 描述改为三级板块焦点系统）；把"数字"移出（改为指向 `BASELINE.md`）；新增"维护触发条件"（改动某模块 → 顺手更新该行） | 1 |
| 4 | P1-4 技能无入口 | `AGENTS.md §1 必读清单` 增加两行：`.workbuddy/skills/`（项目级技能清单）与 `.workbuddy/memory/MEMORY.md`（铁律浓缩）；新增 `docs/DEV/SKILLS.md` 登记两级 6 个技能（位置 / 何时用 / 何时更新） | 2 改 + 1 新增 |
| 5 | P1-5 ADR 缺口 | 补 ADR-014 ~ ADR-019（BPM v3 重构 / 方向遍历 API / 板块成对装配 / 双击 A / 模态门控 / 复用控件注入式操作条），**只写"决策 + 理由 + 被推翻的替代方案"**，细节指向 features 档案 | 1 |
| 6 | P1-6 无测试指南 | 新增 `docs/DEV/TESTING.md`：目录约定 / 命名 / 单跑命令 / flaky 清单 / 失败归属判定 / 基线以 `BASELINE.md` 为准 | 新增 |
| 7 | P1-7 老文档状态不明 | 给 3 篇老文档加**状态横幅**（统一格式：`> 🗄️ 已归档 / 已被 X 取代 / 最后更新`），抄 `nsfw_filter_v1_ABANDONED.md` 的现成做法；并把"状态横幅"写进 `AGENTS.md` 作为**新建文档的强制字段** | 3 改 + 规则 |
| 8 | P1-8 档案不遵循模板 | 规定档案头部**必须有** `> 状态｜最后更新｜关联 ADR` 三件套；把 4 份抽样档案的头部补齐（只补头部，不动正文） | 4 + 规则 |
| 9 | P2-9 体积无治理 | `AGENTS.md` 给 DEV_LOG 配**具体读法**（`head -60`）；规定归档阈值（单文件 > **100 KB** 或 > 1500 行 → 按年/月切分到 `archive/`）；`big_picture_v3_cinema.md` 的 §15–§18 可考虑拆成 `bpm_focus_system.md` | 规则 + 可选切分 |
| 10 | P2-10 提交规范 | `AGENTS.md` 补一节：`<type>(<scope>): <摘要>`，type 取 `feat/fix/docs/refactor/perf/test/chore`，scope 用模块名（bpm / data / import / ui / docs…），摘要用中文，正文写"为什么" | 1 |
| 11 | P2-11 CHANGELOG 边界 | 明确：`CHANGELOG.md` = **面向用户/发布**（只在发版时写）；`DEV_LOG.md` = **面向开发**（每次改动追加）。写进 `README.md §二` 表 | 1 |
| 12 | P2-12 临时脚本归置 | 规定：临时脚本一律放 `.workbuddy/tmp/`（或 `tools/dev/tmp/`）并**当次删**；`.workbuddy/` 顶层保持干净 | 规则 + 一次性清理 |
| 13 | P2-13 脚本无说明 | `AGENTS.md §3 收尾清单` 里点名 `tools/dev/check-changes.bat` / `verify.bat` | 1 |
| 14 | P2-14 打包未纳管 | 确认 `docs/打包规范与流程说明_V0.8.md` 是否仍有效：有效则移入 `docs/DEV/`（或加状态头 + 在 STATUS_MAP 登记入口），失效则加废弃横幅 | 1–2 |
| 15 | P2-15 残留未登记 | 把 `test/failures/` 补进 `STATUS_MAP §九 已知待清理项` | 1 |

### 3.3 一并建议：把"文档卫生"变成机械检查

`tools/dev/` 再加一个 `doc-check.bat`，做 3 件事（不做内容判断，只做机械校验）：
1. `docs/DEV/` 下所有 `.md` 是否都有 `最后更新`（否则列出来）；
2. 出现「（最新）」字样超过 1 处 → 报警（专治 P0-2 那种三个"最新"）；
3. 超过 100 KB 的文档 → 提示归档。

这样"文档不会腐坏"就不再依赖人（或 AI）的自觉。

---

## 4. 范围边界

### 4.1 允许改动

- `AGENTS.md`、`CLAUDE.md`、`docs/DEV/README.md`、`docs/DEV/STATUS_MAP.md`、
  `docs/DEV/SESSION_HANDOFF.md`、`docs/DEV/DECISIONS.md`、`CHANGELOG.md`
- 新增：`docs/DEV/BASELINE.md`、`docs/DEV/TESTING.md`、`docs/DEV/SKILLS.md`、
  `docs/DEV/archive/`
- 老文档加状态横幅：`docs/bpm_architecture.md`、`docs/big_picture_mode.md`、
  `UI_DEVELOPMENT_GUIDE.md`、`docs/打包规范与流程说明_V0.8.md`
- `tools/dev/doc-check.bat`（新增）

### 4.2 禁止改动

- ⛔ **任何 `lib/` `test/` 下的代码**（本单是纯文档/流程治理）
- ⛔ 不改 `chrono-tide-opensource/`、`官网/`
- ⛔ 不删除任何既有文档；老文档只**加横幅**，正文保留（历史可追溯）
- ⛔ 不改 `pubspec.yaml` / 构建配置

### 4.3 相关但本次不处理

- `docs/DEV/features/big_picture_v3_cinema.md` 的 §15–§18 是否拆文件（P2-9 的
  可选动作，建议单独提）
- `.workbuddy/` 里 27 个历史临时脚本的一次性清理（需用户逐项确认，涉及删除）
- 其他 3 份档案头部的补齐（本次只做 4 份抽样，其余同类问题在规则落地后陆续补）

---

## 5. 【AI 填写】变更计划（阶段 A 输出，等待批准）

**分期建议**（可按批批准，也可一次全做）：

| 批次 | 内容 | 预计触及 | 风险 |
|------|------|---------|------|
| **批 1（P0）** | 新增 `BASELINE.md`；`AGENTS.md` / `CLAUDE.md` / `README.md` 的过期数字改为引用；`STATUS_MAP.md` 校正 + `focus/` 描述修正 | 4 文件 + 1 新增 | 低（纯文档） |
| **批 2（P0/P1）** | `SESSION_HANDOFF.md` 瘦身改造（当前状态 ≤150 行 + 历史归档）；`AGENTS.md` 必读清单补技能/记忆；新增 `SKILLS.md` | 3 改 + 2 新增 | 中（**会动到最重要的文件**，建议先给结构样例确认再执行） |
| **批 3（P1）** | 补 ADR-014~019；新增 `TESTING.md`；给 3~4 篇老文档加状态横幅；档案头部规则 + 4 份抽样补齐 | 6 改 + 1 新增 | 低 |
| **批 4（P2）** | 提交规范 / DEV_LOG 读法与归档阈值 / CHANGELOG 边界 / 临时脚本归置 / `doc-check.bat` / 残留登记 | 4 改 + 1 新增 | 低 |

**验证方式**：
1. 每批改完 `git diff --stat` 自查（应**只**出现文档与 `tools/` 文件）；
2. 全文 `grep` 一遍过期数字（`181 通过` / `13 失败` / `563` / `190 个 Dart`）应为 0 命中；
3. `grep -c "（最新）" docs/DEV/SESSION_HANDOFF.md` 应为 1；
4. 人工通读 `SESSION_HANDOFF.md` ≤150 行、能在 1 分钟内说清"现在在哪、下一步"；
5. `doc-check.bat` 跑一遍无告警。

**明确不改**：`lib/`、`test/`、`pubspec.yaml`、`chrono-tide-opensource/`、`官网/`、
被审计文档的**正文历史内容**（只加头/改索引）。

> ⬜ 已批准　⬜ 需修改　⬜ 已驳回

---

## 6. 【AI 填写】执行结果（阶段 B 完成后填写）

（待执行）

---

## 7. 验收

- ⬜ 通过　⬜ 不通过（原因：）
- 验收日期：
- 遗留问题：
