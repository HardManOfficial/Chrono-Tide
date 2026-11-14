# 数据清洗扩充计划（会社词典 × 标签词表）—— 2026-10-26

> 状态：**已执行完成（2026-10-26）**，实测结果见 §8
> 基线：会社 97 家 / 330 键 → **255 家 / 723 键**；标签 688 概念 / 5244 键 → **717 概念 / 5537 键**
> 审计工具（新增，只读）：`dev_probe/audit_ct_coverage.py`；数据快照：`dev_probe/ct_explore_dump.json`（513 条，2026-10-26）
> 关联档案：`features/company_alias_normalization.md`、`features/tag_vocabulary.md`、`features/tag_vocabulary_expansion_plan.md`

---

## 1. 现状量化（本次实测，非估算）

数据源：线上 PocketBase `games` 集合（`http://117.72.115.30:8090`），**513 部**作品，
会社字段为 `Developer`（大写，旧字段名），标签字段为 `tags`（数组，社区整理中文）。

| 维度 | 探库总量 | 现有覆盖 | 缺口 |
|---|---|---|---|
| 会社·有值记录 | 436 条 | 命中 **262 条（60.1%）** | 174 条未命中 |
| 会社·唯一写法 | 110 个 | 命中 **53 个（48.2%）** | 57 个未命中 |
| 标签·出现次数 | 3280 次 | 命中 **2899 次（88.4%）** | 381 次未归类 |
| 标签·唯一写法 | 376 个 | 命中 **196 个（52.1%）** | 180 个未归类 |

会社缺口结构（57 个）：**13 个是既有条目的写法变体**（补别名即可，如 `AliceSoft(A社）`、
`5pb`、`Cabbage-Soft`、`ゆずソフトSOUR（酸柚子）`），**44 个需 VNDB 查证后新建**；
其中 `株式会社`（4 条）是**源头脏数据**，不建词条。

标签缺口结构（180 个）：按语义可分四簇 —— ① 情感/氛围词（爱恋 15、幸福 14、伤痛 4、
归途 4、相伴 4…）② 玩法/结构词（回合战 26、后日谈 10、续篇 4、前传 3…）
③ 舞台词（夏日 16、学院 6、寄宿 4、乡土 4、澄空学园 4…）④ **作品特化营销标签**
（蜜色任务、宝石意志、匣中余响、白河萤视角…约 50 个，无通用检索价值）。

## 2. 目标与验收口径

底线 = 探索库全量；扩展 = 主流 + 小众知名。验收全部可脚本量化（`audit_ct_coverage.py` 复跑）。

| 指标 | 现状 | 底线目标 | 扩展目标 |
|---|---|---|---|
| 会社·记录级命中 | 60.1% | ≥ 95% | ≥ 97% |
| 会社·唯一写法命中 | 48.2% | ≥ 90% | ≥ 93% |
| 会社词典规模 | 97 家 | ≈ 140 家 | **250–300 家** |
| 标签·出现级命中 | 88.4% | ≥ 98% | ≥ 99% |
| 标签·唯一写法命中 | 52.1% | ≥ 85% | ≥ 90% |
| 标签词表规模 | 688 概念 | ≈ 760 概念 | **850–950 概念** |
| 数据自检 | — | id 唯一 / 跨条目键冲突 = 0 / 全概念命中自身 | 同左 |

> 唯一写法命中率的剩余缺口由「作品特化标签 + 无效值」构成，**刻意不收**（判据：无通用检索价值），
> 它们保留在分类匣「其他」分区，不污染维度。

## 3. 分批执行（每批独立可回滚，按批报告）

### B1　会社底线（探索库 57 个未命中）
- 13 个写法变体：**只追加 `aliases`**，不动词条本体（零风险，`company_alias_store.dart` 无需改）。
- 44 个候选：逐条 `POST https://api.vndb.org/kana/producer`（`filters:["search","=",kw]`）
  校验 `vndb_id` / `name` / `original`（日文名）/ `aliases` / `description`（判 `status`）。
  子品牌独立成条（DOLCE / WASABI / Spica / Lunatic / SOUR 先例）。
- `株式会社` 等 4 条无效值：**不入词典**，进「源头脏数据清单」（见 §5）。
- 中文俗称只收可举证来源（VNDB aliases / 萌百 / 月幕），禁止编造。

### B2　会社扩批（第一梯队 → 目标 250–300 家）
- 梯队划分：① 一线大厂（补齐缺漏，如 Leaf / Lose / BaseSon / Escude / HARUKAZE /
  Unison Shift / 07th Expansion / BLACK Cyc / Dual Tail / hibiki works / FlyingShine /
  Qruppo / SQUEEZ / でぼの巣製作所 / wstar / アトリエかぐや 系）② 中坚（あかべぇそふとすりぃ、
  チュアブルソフト、みるくふぁくとりー、Frill、Sister Position、Us:track、Aino+Links…）
  ③ 小众知名 / 同人社团（上海爱丽丝幻乐团、黄昏フロンティア…）。
- 每批 ≤ 40 家，逐批：VNDB 查证 → 生成 JSON 片段 → 键冲突校验 → 写盘 → 复跑覆盖率。
- 子品牌 / 发行商 / 同人社团分列，不合并母品牌（沿用既有纪律）。

### B3　标签底线（探索库 180 个未归类）
- ① 情感/氛围词 → `theme` / `tone`；② 玩法/结构词 → `playstyle`（回合战、后日谈、续篇、
  前传、番外、重制、多线叙事…）；③ 舞台词 → `setting`（夏日、学院、寄宿、乡土、雪镇…）；
  ④ 美术 → `art`；⑤ 年龄/成人 → `age` / `adult`。
- 处理手法：规范名撞既有概念 → **并入其 aliases**；语义独立 → 新建概念（id 沿用
  `th./tone./ps./set./el./ch./art./ad./age.` 前缀）。
- 「一个概念只属一个维度」+ 跨概念别名冲突 = 0（`tag_vocabulary_test.dart` 守护）。
- 作品特化标签（约 50 个）**不入词表**，输出到「源头标签清理建议清单」。

### B4　标签扩批（中文情感向 + 季节/场景词族）
- 以探索库暴露的词族为轴（夏日/冬日/秋日、归乡/归途、相伴/相守/相恋…）系统性补齐
  同族近义写法，避免「补一个漏三个」。
- 再对照 `dev_probe/nextmoe_tags_full.json`（3328 条）与 VNDB 翻译表，挑未覆盖的高频项。

### B5　收尾
- 复跑 `audit_ct_coverage.py`，把「现状 vs 目标」实测表写回本档案。
- 更新 `features/company_alias_normalization.md`（词条数与批次）、`tag_vocabulary.md`（概念数/维度分布）。
- `DEV_LOG.md` / `SESSION_HANDOFF.md` 追加记录；一任务一 commit（`git add` 显式文件）。

## 4. 影响面与风险

| 影响面 | 说明 |
|---|---|
| 分类匣 / 探索页分组菜单 | 未归类桶缩小、维度计数变大（纯数据派生，无代码改动） |
| 会社筛选 / 智能归纳 / 会社墙 | 更多写法归并到同一 `company_id`；会社墙默认仍只显示「库内有作品的词典会社」，扩批不会出现空会社卡 |
| pending 漏斗 | 词典命中后 `removeIfResolved` 自动消化旧条目，pending 只减不增 |
| 启动与包体 | `company_aliases.json` +`~80KB`、`tag_vocabulary.json` +`~60KB`，均为惰性加载 asset |

| 风险 | 对策 |
|---|---|
| 误合并同名不同社 | `company_id` 物理隔离 + `vndb_id` 锚点 + `ambiguousAliases` 测试强制为空 |
| 中文俗称编造 | 只收可举证来源；不确定的入 pending，不入词典 |
| 词表膨胀导致维度语义漂移 | 单维度归属 + 冲突=0 测试；新增概念必须写明归维理由 |
| 探索库是活数据 | 快照固定为 2026-10-26 / 513 条，扩批后复跑同一快照对比，避免基线漂移 |
| 工作区有他人未提交改动 | 本批只碰 `assets/data/*.json`、`dev_probe/*`、`docs/DEV/*`，不碰任何 `lib/` 代码 |

## 5. 源头脏数据清单（建议 PB 侧单独处理，本批不动线上）

| 记录数 | 原值 | 问题 | 建议 |
|---|---|---|---|
| 4 | `株式会社` | 无效（法人后缀当会社） | 补真实会社或清空 |
| 16 | `AliceSoft(A社）` | 中英混写 + 全角括号 | 规范为 `Alice Soft`（客户端已由别名兜底） |
| 7 | `Eushully(E社）` | 同上 | 规范为 `Eushully` |
| 3 | `Cabbage-Soft` | 连字符写法 | 规范为 `Cabbage Soft` |
| 2 | `Front Wing 前翼社` | 中英混写 | 规范为 `Frontwing` |

> 客户端 normalize（`company_alias_store.dart:239`）**不剥标点/连字符**是刻意的保守设计，
> 本批**不改归一化逻辑**，只用显式别名覆盖这些写法。

## 6. 明确不改

- `lib/` 下**任何代码**（含 `company_alias_store.dart` / `tag_vocabulary_store.dart` 的归一化实现）；
- 两份数据的 `format_version`（纯新增条目与别名，不涉及 schema 变更）；
- 线上 PocketBase 数据（§5 仅出清单，改线上需单独批准）；
- `lib/packages/luna_metadata_sdk/**`（稳定区）、`app_state.dart`、主题系统、`windows/runner/`；
- 探索页 / 分类匣 UI 与派生逻辑（数据扩批后自动生效）。

## 7. 验证方式

1. `C:/Users/.../Python313/python.exe dev_probe/audit_ct_coverage.py` —— 覆盖率复跑，对照 §2 表格；
2. 数据自检脚本：id 唯一、跨条目归一化键冲突 = 0、全概念命中自身、`dim` 均已注册；
3. `./flutter/bin/flutter.bat test test/services/company_alias_store_test.dart test/services/tag_vocabulary_test.dart`
   （规模断言为下限，扩批不改测试）；
4. `git status --short` 自查改动面（只应有 `assets/data/`、`dev_probe/`、`docs/DEV/`）。

## 8. 执行结果（2026-10-26 实测）

| 指标 | 执行前 | 目标 | 实测 | 结论 |
|---|---|---|---|---|
| 会社·记录级命中（探索库 436 条） | 60.1% | ≥95% | **98.6%**（430/436） | ✅ |
| 会社·唯一写法命中（110 个） | 48.2% | ≥90% | **97.3%**（107/110） | ✅ |
| 会社词典规模 | 97 家 | 250–300 | **255 家 / 723 键** | ✅ |
| 标签·出现级命中（3280 次） | 88.4% | ≥98% | **98.1%** | ✅ |
| 标签·唯一写法级命中（376 个） | 52.1% | ≥85% | **85.4%** | ✅ |
| 标签词表规模 | 688 概念 | 850–950（乐观） | **717 概念 / 5537 键** | 底线 + 词族达成，未强凑长尾 |
| 数据自检 | — | 全绿 | id 唯一 / 键冲突 0 / 主名命中自身 | ✅ |

- 剩余会社未命中 3 个：`株式会社`(4 条，源头脏数据)、`CLD`(1，未查实)、`DS娘社`(1，社区梗作)。
- 剩余标签未归类 55 个（63 次出现）：全部是刻意不收的作品特化营销标签。
- 工具链（全部只读 / 幂等，可复跑）：`dev_probe/audit_ct_coverage.py`（覆盖率）、
  `verify_data.py`（结构不变量）、`apply_tag_b3.py` + `apply_tag_b4.py`（标签归维）、
  `patch_company_aliases.py` + `build_company_batch.py`（会社扩批）、
  `vndb_producer_probe.py` / `vndb_id_probe.py` / `vndb_vn_dev_probe.py`（VNDB 查证）、
  `fetch_vndb_top_producers.py`（高分作品反推名作会社）。
- ⚠️ **未跑 `flutter test` / `analyze`**：本机再次触发 `CreateFile failed 231`
  （所有管道范例都在使用中），flutter_tools 初始化即失败。已做 Python 等价复刻核对两份
  测试的数据断言（维度 9 / concepts≥400 / 冲突 0 / 抽查标签归属 / companyCount≥78 /
  ambiguousAliases 空 / 主名字段命中自身 / search('社')≥4）。**待开发者在正常终端补跑。**
- ⚠️ 未真机走查：分类匣「其他」分区缩小、会社筛选面板新会社展示名、探索页维度分组菜单。
