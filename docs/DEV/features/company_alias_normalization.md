# 会社归一化（会社别名映射库）—— 设计与分阶段计划

> 状态：**Phase 1+2 已实施**；**Phase 3 大部分已实施**（BPM 联动 / 详情收敛 /
> pending 命中清理 / 详情页联想 / 库页待审区 / join 表单联想）；词典已扩批至
> **255 家 / 723 键**（2026-10-26 第六批，探索库覆盖率 98.6%）。  
> 最后更新：2026-10-26　词典正本：`assets/data/company_aliases.json`（docs 下的副本已迁走）  
> 实现：`lib/services/company_alias_store.dart`、`lib/services/company_alias_pending.dart`；测试：`company_alias_store_test.dart`、`company_normalization_phase2_test.dart`

---

## 1. 问题定义（现状证据）

同一会社存在日文原名 / 英文官方名 / 中文译名 / 玩家圈内昵称多套写法，多数据源  
抓取时各自透传原文，导致一条会社多个分组键：

- 数据源侧：`luna_metadata_sdk` 聚合 VNDB / Bangumi / KUNGAL / NEXTMOE / TouchGal  
  五个源，各源 `Game.company`（`lib/packages/luna_metadata_sdk/lib/models/game.dart:9`）  
  原文直接落库 —— `lib/services/metadata_fetcher.dart:1013`：  
  `'developer': game.company ?? ''`。
- 本地库侧：`LibraryGame.developer`（`lib/services/local_game_registry.dart:246`）  
  只存原文；写穿接口 `setGameDeveloper`（`local_game_registry.dart:570-583`）  
  仅 trim，无任何归一化。
- 消费侧（分裂现场）：
  - 会社筛选 = 精确字符串比对（`lib/pages/library_page.dart:281-284`）；
  - 智能归纳 `dev:<会社>` 组 = `game.developer.trim() == value`  
    （`lib/services/library_smart_group_service.dart:66-69`，只 trim）；
  - 搜索匹配会社名（`library_page.dart:270-278`）。

后果：「sprite / 雪碧社 / 精灵社」会是 3 个筛选项、3 个归纳组、3 条搜索路径。

## 2. 方案总览（对参考草案的取舍与增强）

参考草案（company_master + company_alias 双表）方向正确，按本项目实际做四点增强：

| # | 决策                                            | 理由                                                                                                                                              |
| - | --------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | **不引数据库**：单一 JSON 词典 + 运行时派生倒排索引              | 本项目是文件型便携应用（`data/*.json` + `assets/data/`），双表外键维护成本高；别名索引是派生物，与 ADR-012「派生索引惰性构建」同构，可随时重建                                                      |
| 2 | **双字段绑定：`developer`（原文）+ `company_id`（解析结果）** | 写时解析一次，筛选时零成本（int 比对）；原文永远保留，词典扩充后可全量重解析（backfill），不丢信息                                                                                         |
| 3 | **保守归一化三层，明确不做模糊**                            | trim/折叠空白 → 全角转半角 → 大小写折叠。**不做**：剥「社」后缀、剥「株式会社」前缀、去标点模糊 —— 宁可漏匹配进 pending，不可错合并（呼应 ADR-007「归属存疑保留」精神）                                           |
| 4 | **`vndb_id` 作外部锚点 + `pending` 漏斗**            | 抓 VNDB 优先按 producer id 对齐（id 比名字强）；未命中原文进 `data/company_alias_pending.json`（复用 watch_candidates 模式：raw + count + first_seen + 样例），作为词典扩充的人工归并漏斗 |

另有两个预留字段：`status`（active / discontinued，词典已有值）与  
`successor_company_id`（改名/合并继任，v1 无实例，YAGNI 但 schema 留位；  
启用后筛选可加「含前史」开关）。

## 3. 词典数据格式（format_version = 1）

```jsonc
{
  "format_version": 1,
  "updated_at": "2026-09-28",
  "companies": [{
    "company_id": 3,                  // 稳定数字主键，终身不变，绝不复用
    "standard_name": "sprite",        // 标准主名：优先 VNDB producer 名
    "jp_name": "sprite",              // 日文官方原名（无独立写法则同标准名）
    "cn_name": null,                  // 中文正式译名，无则 null，禁止编造
    "vndb_id": "p1326",               // 外部主数据锚点
    "status": "active",               // active | discontinued
    "successor_company_id": null,     // 预留：改名/合并继任
    "comment": "…",                   // 备注（解散时间/子品牌去向等）
    "aliases": ["Sprite", "雪碧社", "精灵社", "冷饭社", "苍彼社", "S-WORKS", "…"]
  }]
}
```

规则：

- standard_name / jp_name / cn_name / aliases 在运行时**全部并入倒排索引**，  
  均可作为匹配键（`CompanyAliasStore.parse`）；
- 跨会社同名别名 = 重名陷阱：构建期检出并记入 `ambiguousAliases` 预警，  
  测试强制为空 —— 词典入库前必须人工裁决；
- 子品牌（Yuzusoft SOUR、Navel honeybell、Circus Northern/Fetish/Metal、  
  Leaf/リーフ）独立成条，**不并入母品牌**（VNDB 亦分列，合并会污染抓取对齐）；
- 首批 10 家（2026-09-28）：Yuzusoft(1) minori(2) sprite(3) Frontwing(4) Key(5)
  AUGUST(6) Navel(7) CIRCUS(8) AQUAPLUS(9) Lump of Sugar(10)；
- 第二批 26 家（2026-09-29）：NITRO PLUS(11) TYPE-MOON(12) FAVORITE(13)
  MOONSTONE(14) feng(15) Applique(16) Purple software(17) PULLTOP(18) Palette(19)
  ensemble(20) Innocent Grey(21) CLOCKUP(22) Whirlpool(23) Makura(24)
  NEKO WORKs(25) Eushully(26) Liar-soft(27) Studio Ryokucha(28) Azarashi Soft(29)
  Sphere(30) CUFFS(31) CUBE(32) SAGA PLANETS(33) ALcot(34) ALcot Honey Comb(35)
  Yoru no Hitsuji(36)。**合计 36 家 / 153 个匹配键，跨会社冲突 0**；
- 第三批 3 家（2026-09-29 凌晨）：elf(37) Studio e.go!(38) 0verflow(39)；
- 第四批 39 家（2026-09-29 上午，全量 VNDB API 实查 + description 过去时判状态）：
  VISUAL ARTS(40) Alice Soft(41) age(42) KeroQ(43) HOOKSOFT(44，hook 表记并入
  同条 p106) SMEE(45) ASa Project(46) Cabbage Soft(47) GIGA(48) KID(49)
  tone work's(50) HAMHAM-SOFT(51) NekoNeko Soft(52) Marmalade(53) Sakura Soft(54)
  Hulotte(55) Caramel BOX(56) Pajamas Soft(57) HuneX(58) ensemble SWEET(59)
  U･Me SOFT(60) BISHOP(61) INTERHEART(62) Clochette(63) Triangle(64) TinkerBell(65)
  Softhouse-Seal(66) propeller(67) SkyFish(68) Waffle(69) Lass(70) Laplacian(71)
  SukeraSparo(72) Xuse(73) MAGES.(74，原 5pb. 改名) Uguisu Kagura(75) AKABEiSOFT2(76)
  Minato Soft(77) Yuzusoft SOUR(78)。
  **合计 78 家 / 269 个匹配键，跨会社冲突 0**；中文俗称大量采用 VNDB producer
  aliases 社区维护数据（爱丽丝社/戏画社/猫猫社/卷心菜社/音符社/颜艺社/橘汁社/
  时停社/三角社/铃铛社等，可举证）；discontinued 9 家：minori、elf、Studio e.go!、
  GIGA(2022 末休止)、KID(2007 破产)、Caramel BOX、Lass、Laplacian、Xuse(2021 破产)。
  Nostalgic Soft 无独立 VNDB 条目，未收（漏斗兜底）；
- 第五批 19 家（2026-09-29 晚，VNDB API 实查 + description 判状态 + 外部检索补证）：
  F&C Co., Ltd.(79) Cocktail Soft(80，F&C 旗下品牌) CandySoft(81，维基百科记载为
  INTERHEART 旗下) Cherry Soft(82) CROSSNET(83，discontinued) bootUP!(84)
  Akatsuki WORKS(85) Aries(86，与 CIRCUS 的 Aries 品牌无关) Astronauts(87，太空人社)
  PeasSoft(88) RococoWorks(89，discontinued) rootnuko+H(90，全年龄主品牌 rootnuko
  不并入) Rosebleu(91) SILKY'S(92，elf 系) SILKY'S PLUS(93，9 -nine- 系列)
  Silver Bullet(94，银弹社) SofthouseChara(95，软屋社/伽羅社等俗称直采 VNDB)
  Windmill(96，风车社) Windmill Oasis(97)。
  **合计 97 家 / 330 个匹配键，跨会社冲突 0**。状态补证记录：CROSSNET 由 VNDB
  description「doesn't exist anymore」判 discontinued（该表述在关键词表之外，
  人工复核抓出）；F&C 无停业直接证据（glitchwave 标 1997-present），保守标
  active 并注明存疑；bootUP!（2023-12 仍有新作，GameFAQs）与 CandySoft
  （2018-2020 有新作）经外部检索确认 active；Dall(p2579) description 空且
  无别名、流传度不足，不收。Astronauts 的俗称「太空人社」与其子品牌 Sirius
  同名，为避免归一化键冲突只收主条目；
- status 口径：只有在**有明确停业/倒闭证据**时才标 discontinued（目前仅 minori，
  2019-02-28）。第二批一律记 active —— 若某社实际已休眠而误标，属可订正的数据问题，
  不会造成错合并（company_id 隔离不受影响）；
- 已显式标注的重名/易混会社（均未合并）：FAVORITE(p612) vs Favorite/ファボライト
  (p10307)、Palette/ぱれっと(p10) vs Palette/パレット(p2938)、
  Applique/あっぷりけ(p232) vs ApRicoT/アプリコット(p548)、
  NEKO WORKs(p4488) vs 猫猫社 NEKONEKO Software。

## 4. 归一化与解析管线

```
raw ──normalize──▶ key ──aliasIndex[key]──▶ company_id
                     │
                     └─ 未命中 ──▶ pending 队列（人工归并 → 词典新条目）
```

`normalize`（`company_alias_store.dart`）：trim → 连续空白（含 U+3000）折叠 →  


全角 ASCII（U+FF01–FF5E）转半角 → 大写转小写。幂等、无副作用；  
展示层永远用原文/`displayName`（cn_name 优先，回退 standard_name）。

## 5. 与游戏数据的绑定（Phase 2 核心，待批准）

原则：**`developer` 原文不动**（兼容展示、导出与既有数据），新增  
`company_id`（int，可空）。解析收敛点唯一 —— `LocalGameRegistry`：

1. 词典入包：`assets/data/company_aliases.json` + `pubspec.yaml` assets +1 行  
   （⚠️ pubspec.yaml 正被并行会话改动，落地需协调）；
2. `game.json` 增 `company_id` 字段：按 ADR-013 走 `_migrations` +  
   `format_version` 3→4 + 迁移测试；就地写回必须绕开写队列（既有教训）；
3. 写入收敛：`setGameDeveloper`（`local_game_registry.dart:570`）写前 resolve，  
   命中 → 同步写 `company_id`；未命中 → 置空 + 追加 pending；
4. 读时回填：`scan()` 后对「developer 非空但 company_id 为空」的游戏做  
   backfill（命中才写回）；
5. 口径切换：
   - `library_smart_group_service.dart:66-69` + `deriveGroups`：命中 → 组键  
     `devId:<company_id>`，未命中 → 保留 `dev:<原文>`；⚠️ `data/smart_groups.json`  
     已存覆盖项是旧键，需键映射迁移（旧键 resolve→新键，未命中保留旧键）；
   - `library_page.dart:281`（筛选）、`:270`（搜索）、`:3847`/`:3916-3971`  
     （会社筛选区列表 → 归一化后列表，显示 displayName）。

**明确不改**：`lib/packages/luna_metadata_sdk/**`（稳定区，company 原文照旧透传）、  
`lib/models/game_model.dart`（下载中心模型，归一化统一收敛在 LibraryGame 侧）、  
`app_state.dart` / `main.dart` / `main_container.dart` / `theme/**` /  
`core/portable_*.dart`（稳定区）；join_page 手动录入正被并行会话改动，本次不碰。

## 6. 分阶段

- **Phase 1（已完成）**：词典 v1（10 家）+ `company_alias_store.dart`  
  （parse/normalize/resolve/byVndbId/byId/search/ambiguous 预警）+ 测试  
  （单测 + 种子数据集成测试）。
- **Phase 2（✅ 2026-09-28 晚已实施）**：§5 全部落地——  
  ① 词典入包 `assets/data/company_aliases.json`（docs 副本已迁走，正本唯一）+  
  `pubspec.yaml` 注册；② `game_data_format.dart`：currentVersion 3→4 + `_migrateV3ToV4`  
  + GameJsonData.company_id + writeGameDir 写入即解析 + `company_id` 进覆盖黑名单  
  （必须跟随 developer 生效，防悬空绑定）；③ `local_game_registry.dart`：  
  LibraryGame.companyId + scan 双分支同步 + `_backfillCompanyIds()` 读时回填  
  （命中写回、未命中进 pending，会话内同键只记一次）+ setGameDeveloper 收敛  
  （别名命中同 id、原文不洗写、未命中进 pending、失败回滚双字段）；  
  ④ `library_smart_group_service.dart`：devId 分组（跨写法归并）+ matches 口径 +  
  旧覆盖项键 `dev:<原文>`→`devId:<id>` 迁移（纯函数可测）；⑤ `library_page.dart`：  
  筛选/搜索/面板会社列表切换（DeveloperFilterEntry，面板内搜索支持别名）。  
  新增 `company_alias_pending.dart`（data/company_alias_pending.json 漏斗）。  
  验证：定向测试 76/76（新增 34 + 受影响既有 42），全量见 DEV_LOG；  
  ⚠️ 未真机走查：backfill 首启写盘量、面板展示名观感、拖拽写穿后组名。
- **Phase 3（大部分已实施 2026-09-29）**：① **BPM 库页联动**
  （`big_picture_library_page.dart` 搜索 = 归一化文本 + 别名展开，与桌面库页同口径）；
  ② **详情页编辑会社收敛**（`game_detail_dialog.dart` 此前直接写 game.json 绕过
  setGameDeveloper，用户手改「雪碧社」不会并入 sprite 组 → 已补 company_id 解析）；
  ③ **命中即清 pending**（`company_alias_pending.dart` 新增 `removeIfResolved`；
  writeGameDir / setGameDeveloper / registerExtractionComplete / _backfillCompanyIds /
  详情页保存 五处解析命中点自动消化旧条目——否则词典扩批后 pending 只增不减）；
  ④ **详情页会社输入联想**（`_buildDeveloperRow` 编辑态输入时从词典联想，
  chips 展示「标准名（中文名）」，点击填入标准名 → 保存时 resolve 必命中）；
  ⑤ **库页待审区**（会社筛选展开态底部「未解析会社 (n)」：查看/复制/忽略，
  复制供人工查证补词典；一键映射到已有会社为后续可选项）；
  ⑥ **词典第三批扩批**（36→39 家：elf p131 / Studio e.go! p17 / 0verflow p74，
  前两家 VNDB 描述过去时判 discontinued，0verflow 为 Stack Ltd. 现役 active）。
  ⚠️ ③④⑤⑥ 本轮再次遭遇环境故障（Dart VM spawn 任意子进程 CreateFile failed 231，
  dart analyze 亦挂——analysis_server 同为子进程）**未跑 analyze/test**；已做
  Python 括号配平校验 + 逐行 diff 复核（修掉 1 处 String?→String 类型错误）+
  词典等价校验（39 家 id 唯一 / 164 键 / 0 冲突 / 新三家抽样全命中），待环境恢复
  首命令补跑。剩余：join 表单联想（低优先）、pending 一键映射、Phase 4；
- **（2026-09-29 上午续）⑦ join 表单联想**
  （`join/widgets/form_inputs.dart` DeveloperInput：ValueListenableBuilder 监听
  输入框，chips 挂在 51 高输入框下方，点击填标准名；StatelessWidget 无需 setState）；
  **⑧ 词典第四批扩批** 39→**78 家 / 269 键**（明细见 §3 第三、四批；状态判定 =
  VNDB description 过去时/破产/休止关键词，Alice Soft 的 "was established" 属
  成立叙述不误判）；**⑨ 适配全面审计结论**：join 单发（填表单中转后走
  writeGameDir/registerExtractionComplete）、批量导入（batch_import_controller）、
  auto_import_pipeline 三条入库链路全部经已解析的收敛入口，**无需改透传**；
  BPM 编辑对话框无会社字段；`kungal_calendar_service` 署名与词典无关。
  **会社数据相关环节至此全部闭环**：抓取(原文)→入库(writeGameDir 解析)→
  展示(原文)→编辑(解析+联想)→筛选/分组(devId)→搜索(别名)→漏斗(未命中收集
  →命中自动清理→人工审阅)。测试「规模与结构」改下限断言 ≥78（扩批不再改测试）。
  ⚠️ 本轮 analyze/test 仍未跑（沙箱 Dart VM 子进程故障持续），Python 等价校验：
  78 家 id 唯一 / 269 键 0 冲突 / 全量主名命中自身 0 失败 / 抽样 8 组全过。
- **（2026-09-29 晚续）⑩ 环境复测 + 词典第五批扩批** 78→**97 家 / 330 键**
  （明细见 §3 第五批；+260 行，纯数据新增，无 dart 代码改动）。
  环境复测结论：沙箱故障仍未恢复——`flutter analyze` 挂在 flutter_tools 初始化
  读注册表（os.dart:594 runSync → reg.exe 被沙箱拦截）；绕过 flutter_tools 直跑
  `dart analyze` 挂在 AnalysisServer.start → Process.start（process_patch.dart:402），
  即 Dart VM spawn 子进程故障与昨日同源，未恢复。验证由 Python 等价校验兜底：
  97 家 id 唯一 / 330 键 0 冲突（校验器还抓掉一处人工笔误：SILKY'S 条目误含
  "Silky's Plus" 与 93 号主名撞键，修正后通过）/ 15 组抽样命中全过（含旧批次
  回归与「Nostalgic Soft / Dall 不命中」负样本）。
- **Phase 4（可选）**：会社维度的统计页/发现页接入；词典扩批（第二梯队会社）。

## 7. 风险与边界

| 风险                        | 对策                                                                     |
| ------------------------- | ---------------------------------------------------------------------- |
| smart_groups 旧键迁移破坏用户归纳覆盖 | 键映射迁移 + 迁移测试；resolve 失败一律保留旧键                                          |
| game.json 迁移死锁/写回冲突       | 按 ADR-013：读时应用 + 就地写回**绕开写队列**，补迁移测试                                   |
| 误合并（同名小社团/相似名）            | company_id 物理隔离 + vndb_id 锚点 + conservative normalize + ambiguous 预警测试 |
| 词典加载失败拖垮启动                | 捕获降级为「无 company_id 模式」，行为与现状完全一致                                       |
| 词典永远不全                    | pending 漏斗 + 定期人工归并（本档案 §3 的维护流程即来源）                                   |
| 别名收录标准                    | 仅收圈内公开、可举证的叫法（萌百/月幕外号专栏/VNDB 官方别名/百度百科别名栏），禁止编造；「巨儒社（巨乳社变体）」类同义变体需人工确认 |

## 8. 测试与验收

- Phase 1（已过）：`test/services/company_alias_store_test.dart`  
  —— normalize 8 例 / resolve 命中与未命中 / vndb 锚点 / search 联想 /  
  种子集成（10 条全命中自身、无跨会社冲突、id 唯一）/ 防御性解析 5 例。
- Phase 2：全量 `flutter test`（基线按 chronotide-dev skill「项目硬事实」，  
  不固化数字）；迁移用例 + backfill 用例 + smart_groups 键迁移用例。

## 9. 遗留与开放问题

- 「精灵社」与「雪碧社」并存（均为萌百收录俗称），已同时入库；
- Leaf/リーフ 是否并入 AQUAPLUS 待用户定（同法人、VNDB 分列，本批未并入）；
- 词典长尾扩批：第二～五批已完成，合计 **97 家 / 330 键**；剩余候选
  （信息不足 / 待议）：Nostalgic Soft（第五批复查确认无 VNDB 条目）、
  Dall(p2579)（description 空、无别名、流传度不足，暂不收）、Giga 子品牌、
  Pulltop Latte / Moonstone Cherry / HOOKSOFT 集团子品牌是否分立、
  F&C FC01/FC02/DreamSoft 等老标签（小众）、Leaf/リーフ 并入与否（待用户定）；
- ⚠️ 环境恢复后首命令补跑（Phase 3 ③④⑤⑥ 未验证部分）：
  `flutter analyze lib/services/company_alias_pending.dart lib/services/game_data_format.dart lib/services/local_game_registry.dart lib/pages/library_page.dart lib/widgets/game_detail_dialog.dart test/services/company_normalization_phase2_test.dart`
  与 `flutter test test/services/company_alias_store_test.dart test/services/company_normalization_phase2_test.dart`；
- 未真机走查：① 首次启动 backfill 的写盘量与耗时（每命中一游戏一次小写，  
  只发生一次）② 库页面板会社列表展示名（如「柚子社」「sprite」）观感  
  ③ 详情页与 join 表单输入会社时的联想 chips 布局与点击填入  
  ④ 库页待审区「未解析会社」展开/复制/忽略 ⑤ BPM 别名搜索 ⑥ 78 家新批次
  别名在筛选面板「面板内搜索」的命中率；
- pending 一键映射（审阅区直接把未解析名归并到某已有会社并批量改写
  相关游戏 company_id）：涉及批量写盘，需单独设计确认流程；
- `metadata_fetcher` 透传链路不改（审计确认：抓取结果仅作表单填充中转，
  入库统一走已解析的 writeGameDir / registerExtractionComplete / backfill，
  见 §6 ⑨ 审计结论）。

## 10. 2026-10-26 第六批扩批：97 → 255 家 / 723 键（DATA-CLEAN-EXPAND）

- **触发**：探索库会社覆盖率仅 60.1%（记录级）——「数据清洗覆盖不够」。
- **审计口径**：线上 PB `games` 集合全量 513 条（`dev_probe/ct_explore_dump.json` 快照），
  会社字段为 `Developer`（大写旧名）。工具：`dev_probe/audit_ct_coverage.py`（只读、可复跑，
  复刻 `CompanyAliasStore.normalize`）。
- **底线段（B1）**：探索库 57 个未命中会社 →
  ① 13 个写法变体只补 `aliases`（`AliceSoft(A社）` / `5pb` / `Cabbage-Soft` /
  `Front Wing 前翼社` / `ゆずソフトSOUR（酸柚子）` / `ザウス【純米】` / `NEKO工作室` /
  `莺神乐` / `Lass Lunatic` / `Seikou Soft.` 等，零风险）；
  ② 44 个经 VNDB 实查新建（でぼの巣製作所 / BaseSon / ωstar / Leaf / SQUEEZ / Lose /
  Escu:de / HARUKAZE / Unison Shift: Blossom / 07th Expansion / Madosoft / Bug System /
  BLACK Cyc / Dual Tail / STING / D.O. / hibiki works / FlyingShine / Qruppo /
  SILKY'S PLUS DOLCE+WASABI / ROOT / Shiratama / Us:track / Aino+Links / Enterbrain /
  Astronauts: Spica+Sirius+Alya+Comet / Chuablesoft / AKABEiSOFT3 / Atelier Kaguya +
  BerkshireYorkshire + TEAM HEARTBEAT / Frill / Shatou Sombrero / Milk Factory /
  Sister Position / Sekai Project / Connection / paleontology / Seikou Soft / CyberFront /
  SEACOXX / KAI / CRYSTALiA / FlyingShine 三个子品牌）。
- **扩批段（B2）**：以 **VNDB 高分作品反推名作会社**（`dev_probe/fetch_vndb_top_producers.py`
  拉 rating 降序 top500，聚合 developers 出现次数：297 个 producer，count≥2 未收录 69 个），
  叠加人工挑选的 count=1 知名会社（Littlewitch / OVERDRIVE / ApRicoT / Kogado / GUST /
  KISS / Ricotta / Spray / CRAFTWORK / ETERNAL / TinkleBell / Karin / BLACKRAINBOW /
  Syangrila / Lusterise / Liquid / ANIM.teamMM / Heiantei / Quince Soft / iMel / SEEC /
  CING / Regista / Primula / PIL/SLASH / Cheritz / coly / LicoBiTs 等），
  以及乙女向（Otomate / Design Factory / Rejet / honeybee / QuinRose / Voltage / inre /
  ichicolumn / LoveDelivery / Rouscou / Karin Chatnoir Ω / Aromarie / Daisy2 /
  Holicworks / Tennenouji / SDR Project / Vingt-et-un）+ 综合厂商 AVG 线
  （CAPCOM / KONAMI / SEGA / Koei Tecmo / Chunsoft / Spike Chunsoft / Idea Factory /
  Nippon Ichi / PROTOTYPE / Enterbrain / Takuyo / Kemco / Red Entertainment / aNCHOR）+
  子品牌/老牌（PULLTOP LATTE / Navel honeybell / Fairytale / FOG / WillPlus / Cotton Soft /
  Princess Soft / Penguin Works / Sumikko Soft / Hiqo Soft / Shakunage / Erectlip /
  Hiyoko Soft / Meromero Cute / Chien / CITRUS / Tily / NITRO CHiRAL / NITRO ORIGIN）。
- **手工条目（VNDB 无 producer 记录）2 条**：`Team Shanghai Alice`（东方Project，
  别名含「上海爱丽丝幻乐团」「上海アリス幻樂団」）、`娱乐通`（中文代理发行商，discontinued）。
- **刻意不收**：西方独立开发者/个人社团（Caribdis / GB Patch / Echo Project /
  Grasshopper Manufacture 等，中文圈无检索价值）、法人分部与主条目重复者
  （KCET / KOEI / MAGES. Inc.）、社区梗作（`DS娘社`）。
- **数据卫生**：`vndb_id` 全局唯一；`standard_name` 去法人后缀（CAPCOM / Koei Tecmo /
  Nippon Ichi Software / Rejet / Holicworks / coly / Cheritz / iMel / SEEC / Regista /
  Voltage / Vingt-et-un Systems / Red Entertainment / Design Factory / Takuyo / Kemco）；
  `cn_name` 只取 VNDB aliases 中「含汉字、无假名、非法人全称」的项，无则 null（不编造）；
  脏别名（`Ltd.` / `Inc.` / `Co.` 残片）过滤；子品牌独立成条不并入母品牌。
- **结果**：97 家 / 330 键 → **255 家 / 723 键**（active 238 / discontinued 17）。
  探索库会社命中：记录级 60.1% → **98.6%**（430/436）；唯一写法 48.2% → **97.3%**。
  仅剩 3 个未命中：`株式会社`(4，源头脏数据)、`CLD`(1，未查实)、`DS娘社`(1，梗作)。
- **验证**：`dev_probe/verify_data.py` PASS（id 唯一 / vndb_id 唯一 / 跨会社键冲突 0 /
  主名字段全部命中自身）；测试断言等价复刻（companyCount≥78、ambiguousAliases 空、
  search('社')≥4→121 键）全部满足。
  ⚠️ `flutter test`/`analyze` **未跑成**——本机再次出现 `CreateFile failed 231`
  （所有管道范例都在使用中，flutter_tools 初始化即挂），与历史环境故障同源。
- **源头脏数据（建议 PB 侧单独处理，本次未动线上）**：`株式会社`(4)、
  `AliceSoft(A社）`(16)、`Eushully(E社）`(7)、`Cabbage-Soft`(3)、`Front Wing 前翼社`(2)
  —— 客户端现已用别名兜住，但 PB 记录本身建议规范化。
- **明确未改**：`CompanyAliasStore` 的 normalize 实现（不剥标点/连字符是刻意保守设计）、
  `format_version`（仍为 1，纯新增条目）、任何 `lib/` 代码。
