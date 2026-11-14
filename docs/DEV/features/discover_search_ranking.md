# 探索库库内搜索 · 相关性排序（DISCOVER-SEARCH-RANKER）

> 最后更新：2026-11-13　｜　状态：✅ 代码完成（32 项行为探针全绿），⏳ 待真机走查
> 相关：`site_search_plan.md`（站外全站搜索，**另一套打分口径，⛔ 不要合并**）

---

## 1. 问题（用户报障 + 实测结论）

用户在探索页原生搜索栏搜 `AIR`，第一屏出来的是「三角圆舞曲 Fandisc / 天使的星期日 /
悠久之翼 / 天色幻想岛 / 七色的轮回转生 / 月姬 / 巧克甜恋…」，真正的 AIR 要翻页才看得到。

**根因不在匹配，在排序**（2026-11-13 用云端库 562 条真实数据实测）：

| 环节 | 现状 | 后果 |
|---|---|---|
| 匹配（召回） | `title / originalTitle / englishTitle / tags / developer` 五字段裸 `contains` | 拉丁词没有词边界：`fairy`→`air`、`amairo`→`air`、`pairing`→`air` 全算命中（13 条命中里 10 条是这种噪音） |
| 排序 | `DiscoverSortOption.defaultOrder` = **完全不排序**，沿用 PB 的 `-created` | 最新录入的噪音排在前面；标题就叫 AIR 的两条因为录入早，被挤到最后一页 |
| 提示 | 卡片上不显示「命中了哪个字段」 | 用户看不出这些结果跟 AIR 有什么关系 |

命中 13 条的实测分布：

| 记录 | 命中字段 | 匹配性质 |
|---|---|---|
| AIR原版 / AIR重置版 | `title` | 完全命中 |
| 月姬 | `englishTitle` = "…crimson **air**" | 真词边界 |
| 三角圆舞曲 -Triple Pairing- | `title`/`orig`/`eng` 的 "p**air**ing" | 裸子串（噪音） |
| 悠久之翼 / 天使的星期日 | `englishTitle` 的 "f**air**y" | 裸子串（噪音） |
| 天色幻想岛 / 巧克甜恋 1-3 | `englishTitle` 的 "am**air**o" | 裸子串（噪音） |
| 7 色的轮回转生 / 9-nine | "nan**air**o" / "s**air**o" | 裸子串（噪音） |

## 2. 行为（用户 2026-11-13 拍板）

1. **召回一行不改**：会社、标签、原名、英文名的搜索能力全部保留（弱命中保留，只是垫底）。
2. **相关性永远优先**：只要有关键词，标题最匹配的永远在最前；用户手选的
   「评分 / 名称 / 文件大小」只决定**同一相关档次内**的先后。
3. 弱命中（英文名裸子串）垫到所有真命中之后，不删除。

### 2.1 打分表（`discover_search_ranker.dart`）

字段基准分 + 匹配质量加成：

| 字段 | 完全相等 | 前缀 | 词边界 / 中文子串 | 裸子串（弱命中） |
|---|---|---|---|---|
| 主标题 `title` | 1400 | 1300 | 1200 | 60 |
| 日文原名 `originalTitle` | 1200 | 1100 | 1000 | 55 |
| 英文名 `englishTitle` | 1100 | 1000 | 900 | 50 |
| 会社 `developer`（含别名） | 820 | 720 | 620 | 45 |
| 标签 `tags` | 700 | — | 500 | 40 |

- 真命中最低 500（标签词边界）> 任何弱命中（≤60）⇒ 弱命中结构性垫底。
- 多关键词（空格/逗号分隔）= AND，取**最弱**那个关键词的分数。
- 同分保持传入顺序（Dart `List.sort` 不稳定，用原始下标兜底）。

### 2.2 匹配质量判定（两套文本各司其职）

| 判定 | 用哪份文本 | 为什么 |
|---|---|---|
| 完全相等 / 前缀 / 中文子串 | **去标点**文本 | 搜 `triplepairing` 能命中 `Triple Pairing` |
| 拉丁词边界 `\bkw\b` | **保留空格标点的原文** | 去标点会把 `ef - a fairy tale` 压成 `efafairytale`，`\bair\b` 永远不成立（探针抓到的真 bug） |
| 中英混排兜底 | 去标点文本 + 位置判定 | `三角圆舞曲triplepairing` 里 kw 前后是 CJK ⇒ 真命中；`fairy` 里前后是拉丁字母 ⇒ 弱命中 |

## 3. 实现位置

| 文件 | 作用 |
|---|---|
| `lib/services/discover_search/discover_search_ranker.dart`（新） | 纯 Dart 打分 + 稳定重排；不依赖 Flutter，可离线测 |
| `lib/pages/discover_page.dart`（改，+14 行） | `_performFilter` 在既有排序 switch **之后**追加一次相关性重排；import 一行 |

接线位置关键点：必须在用户排序之后调用（后者成为同档次序），且在
`setState(_displayGames = filtered)` 之前。

## 4. 实测效果（562 条真实库数据）

搜 `AIR` → 前四名：

```
1300  AIR重置版
1300  AIR原版
 900  月姬          （englishTitle "crimson air" 真词边界）
  60  三角圆舞曲 -Triple Pairing-   ← 之后全是弱命中，顺序仍是 PB 原序
```

搜索 `Key`（会社）→ `key` 标题/英文名命中在前，会社命中 820 紧随其后；
搜索 `悠久` → 悠久之翼-前篇(1300) / 后篇(1300) / 杀恋～悠久…(1200)。

## 5. 验证记录

| 手段 | 结果 |
|---|---|
| 进程内 analyzer（ranker / discover_page / 单测） | **0 error**（discover_page 3 条存量 warning 未动） |
| 行为探针 `.workbuddy/probe_discover_search/probe.dart` | **32 PASS / 0 FAIL**（fixture = 真实库 13 条含 air 的记录） |
| 负向对照 | 把 `_wWeakEnglish` 从 50 抬到 950 ⇒ **6 项失败**，确认探针有效 |
| 探索页整屏渲染探针 | A–D 4 屏 LAYOUT OK，FAIL=0 |
| `flutter test`（`test/services/discover_search_ranker_test.dart`） | ⏳ 231 环境下跑不了，待环境恢复补跑 |

## 6. ⛔ 不要动的地方

- **召回条件**（`_performFilter` 里那段 `contains` 判定）：用户明确要「多数据搜索」，
  收窄字段会丢掉合法搜索。要更精准只能调**分数**，不要删字段。
- **弱命中不许删**：`fairy`/`amairo` 这类保留在最后一档，删了就搜不到
  「只记得英文名一部分」的作品。
- **`_stripAll` 与 `_levelOf` 的两套文本**：合并成一套会让词边界或标点归一化
  其中之一失效（两条都有探针守着）。
- **`site_search_ranker.dart`**：站外口径，字段与兜底策略完全不同，⛔ 不要抽公共类。

## 7. 待办 / Phase 2

- [ ] 卡片上标注「命中字段」（如「会社命中」小角标），让用户理解弱命中为何出现
- [ ] 「只看标题匹配」开关（严格模式），给要求极致精准的用户
- [ ] 简介 `description` 是否进召回：目前**不参与**（会让噪音爆炸），需要单独评估
- [ ] 繁体标题 `traditionalChineseTitle` 目前不参与召回与打分，可考虑补上
