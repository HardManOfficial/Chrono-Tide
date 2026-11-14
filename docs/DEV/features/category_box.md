# 分类匣（CategoryBox）—— 库页收藏夹 → 作品分类模块改造

> 状态：**已实施（2026-10-02）**，待真机走查。
> 设计依据：Figma「Sidebar - 分类匣」四份导出 JSON + 四张参考图
> （`素材/新建文件夹 (2)/`），几何规格为 1280×720 @1x 实测值。

## 1. 需求与结构

原库页右侧「收藏夹栏」（收藏夹条目 + 智能归纳混排）整体改造为**分类匣**，
按「用户分类 / 系统分类」组织为三个视图，头部下拉切换：

| 视图 | 性质 | 数据来源 | 交互 |
|---|---|---|---|
| 收藏夹 | 用户分类 | `CollectionService`（不变） | 点击进入 / 拖拽归类 / 悬停编辑 / 新建 |
| 标签库 | 系统分类 | **受控词表**（8 维度 + 概念 + 别名，`features/tag_vocabulary.md`）+ 库内派生计数 | 维度内并集·维度间交集多选 / 拖拽写穿规范名 / 编辑标签 |
| 会社墙 | 系统分类 | 会社词典（库内有作品者）+ 自定义会社 + 关注存储（**纯派生，无预置**） | 点击过滤 / 拖拽写穿设会社 / 关注 / 添加会社 |

三条铁律延续：分类匣条目仍是「拖拽投放命中检测」的目标（GlobalKey 契约不变）；
成员计数永远派生不落盘；用户意愿（关注/自定义）才落盘。

## 2. 文件清单

**新增**：
- `assets/data/tag_dimensions.json` —— 标签维度注册表（8 维度；见 `features/tag_vocabulary.md`）
- `assets/data/tag_vocabulary.json` —— 标签受控词表（97 概念 + 别名；同义归并 / 单维度归属）
- `lib/services/tag_vocabulary_store.dart` —— 词表加载 + 归一化 + 派生
  （`CompanyAliasStore` 同款纪律：失败降级不抛异常，可重试）
- `lib/services/company_wall_store.dart` —— ① `CompanyWallStore`：关注关系 +
  自定义会社，落盘 `data/company_wall.json`（P1-4b 加载失败不覆写 / P1-4c 串行化
  原子写）
- `lib/widgets/library/category_box_sidebar.dart` —— 侧栏本体（含视图模型
  `CategoryBoxTag/TagSection/Company`）
- `lib/widgets/library/category_box_editors.dart` —— 「编辑标签」「添加会社」弹窗
- `lib/services/company_logo_service.dart` —— 会社图标抓取（NextMoe 会社目录，
  vndb 源锚点对齐；2026-10-04）
- `lib/widgets/library/category_box_company_editor.dart` —— 「编辑会社信息」弹窗
  （上传/抓取/移除图标 + 显示名覆盖；2026-10-04）
- `lib/services/tag_library_override_store.dart` —— 标签库**用户覆盖层**
  （维度改名/新增、概念归属覆盖、未归类收编、全局隐藏；落盘
  `data/tag_library_overrides.json`；2026-10-04）

> **2026-10-02 升级**：原 `tag_taxonomy.json`（9 标签种子表）/ `tag_taxonomy_store.dart` /
> `company_spotlight.json`（会社墙 4 张示例卡）/ `CompanySpotlightStore` **已删除**，
> 由受控词表 + 纯派生会社墙取代（见 `features/tag_vocabulary.md`）。

**修改**：
- `lib/pages/library_page.dart` —— 换侧栏、`_activeTagKeys` 多选过滤、面包屑
  （标签库/会社墙分支）、空态遮罩、`_applySmartGroupDrop` 兜底（0 成员种子标签 /
  会社卡直接还原写穿目标）、键表同步扩展、新存储加载与监听
- `lib/widgets/library/collection_sidebar.dart` —— 删除死类 `CollectionSidebar`，
  保留复用弹窗（`CollectionEditDialog` / `SmartGroupEditDialog`）
- `lib/services/library_smart_group_service.dart` —— +`tagKeyPrefix` 常量
- `pubspec.yaml` —— +2 assets

## 3. 设计规格落点（Figma 实测）

- 侧栏总宽 **324**（1px 左缘描边 + 内容列 ≈299 + 右侧 24px 留白列）；Header 高 55.2，
  下缘即分隔线；内容区 pad 18.4/17.6/17.6/17.6；Footer 上缘细线 + 39.2 高主按钮
- 搜索框高 28.8 / radius 4 / 边 #e0d5c5；副标题 9.6px（左 #a18c75 右 #ad9780 →
  secondaryText / placeholderText）；细说明 8.8px；标题 16px letterSpacing 2
- 切换下拉：宽 235.2 / radius 6.4 / 条目 56 高 / 选中底 `#f4ede3` → `cardHoverBg` + check
- 标签 chip：圆点 5px + 名 10.5px + 衬线计数；Wrap + IntrinsicWidth（探索大厅
  同款右栏窄宽布局坑，禁 Row+Spacer）
- 会社卡：127×131 两列 gap 9.6；logo 区 64 高（柔和底色对 + 衬线字标）+
  名 11px + 副名 8.8px + 「N 部作品」+「+ 关注」chip
- 颜色全部映射 `AppColors` 语义令牌（设计稿暖米色在深色主题下自适应），未硬编码

## 4. 数据契约

- **标签库**：受控词表（9 维度）驱动；**只展示库内计数 > 0 的概念**（0 成员维度/概念
  自动隐藏，分类由库数据派生）；未命中词表的标签进「其他」分区（计数降序，封顶 80）。
  计数 = `TagVocabularyStore.derive`（归一化归并口径）。多选过滤 = **维度内并集 ·
  维度间交集**（概念键 `concept:<id>`，其他分区键 `tag:<原文>`），缓存 hash 含选中键序。
  **用户覆盖层**（`TagLibraryOverrideStore`，2026-10-04 升级，展示层合并、覆盖优先）：
  - 维度改名：asset 维度标题覆盖（**不改该维度下概念的筛选行为**）；
  - 新增维度：用户自定义分区，系统**不自动归类**（语义类似「其他」延伸）；
  - 概念归属覆盖：`concept_id → 维度 id`（跨维度拖拽写入，只影响展示分区
    与该维度筛选入口）；
  - 未归类收编：归一化原文 → 维度 id（把「其他」标签拖进任意维度）；
  - **全局隐藏**：隐藏标签集（归一化键）——所有本地标签展示点
    （库页/详情页/BPM 卡片 meta/BPM 详情）统一过
    `TagLibraryOverrideStore.filterVisibleTags`；标签库编辑模式显示斜眼图标可恢复；
  - **重命名/删除 = 写穿**：`LocalGameRegistry.renameTagEverywhere/removeTagEverywhere`
    按归一化匹配改写全部命中游戏的 `game.json`（不可逆，UI 二次确认）；
    写穿后覆盖层键经 `migrateKey` 跟随迁移。
- **会社墙**：列表 = 库内有作品的词典会社（数量降序 → 名字）→ 自定义会社
  （创建序）。词典会社键 `devId:<id>`（计数按 company_id），自定义会社
  键 `dev:<名称>`（计数按 developer 原文精确匹配）。关注键：词典 = companyId
  字符串，自定义 = custom id。
  **显示层覆盖**（`CompanyWallStore` v2，2026-10-04 升级）：
  - `display_names`：会社键 → 用户显示名（**只改显示名**，会社键 / company_id /
    成员计数 / 筛选行为全部不变）；空串 = 清除覆盖回退词典名；
  - `logo_files`：会社键 → 图标文件名（实体落 `data/company_logos/<键>.<ext>`，
    卡片有图显示图 / 无图回退衬线字标）；
  - 图标来源 = 用户上传（file_picker）或**自动抓取**（`CompanyLogoService`：
    NextMoe 会社检索 → `sources` 含 `vndb:<id>` 精确锚点对齐 → 详情
    `include=logo` → 下载落盘；Phase 0 探针 8/8 命中 100%）；
  - 入口 = 会社卡片 hover 右上角圆形「编辑会社信息」按钮。
- **联动**（2026-10-04 升级）：三视图**可叠加**——实际列表 = 收藏夹 ∩ 会社 ∩
  标签组合。每个视图的**计数派生**输入 = 全库经**其他维度**过滤后的集合
  （`_contextGames(exclude*)`，排除自身维度防自反馈清空）：
  - 标签库计数 = 收藏夹 ∩ 会社过滤后派生；会社墙计数 = 收藏夹 ∩ 标签过滤后派生；
    收藏夹计数 = 会社 ∩ 标签过滤后派生；
  - 已选中的标签即使计数归 0 也保留显示（否则组合筛选时选中项凭空消失）；
  - 面包屑显示组合链「游戏库 > 收藏夹 > 会社 > 标签（+ 总数）」，点任一条件
    **单独移除**；≥2 维度叠加且无匹配时提示「当前筛选组合没有匹配的作品」；
  - **BPM 面板同口径**（`big_picture_library_page.dart`，2026-10-04 深夜对齐）：
    去互斥三入口 + `_contextGames` 同构实现 + 面板收藏夹计数/「所有游戏」计数
    上下文口径 + 筛选 pill 组合标签（收藏夹 + 会社 + 标签全展示）。
    ⚠️ BPM 无面包屑（面板收起靠 pill 指示，点 = 清除全部）；标签分区仍为
    简化版（无覆盖层/维度编辑，与桌面差异沿用原状）。
- **拖拽**：沿用原命中机制（`_smartGroupItemKeys` + `_dropTargetSmartGroupKey`），
  键预登记（种子标签 + 会社卡候选），未挂载键不参与命中，无开销。

## 5. 待确认项（实现采用的保守默认）

1. 头部右上「分类匣」pill = 打开与标题触发等价的同一下拉。
2. 多选过滤 = **维度内并集 · 维度间交集**（2026-10-02 升级，见 `features/tag_vocabulary.md`）。
3. 会社墙**纯派生**（2026-10-02 升级）：删除「示例」预置与「示例 / 自定义」来源筛选，
4. 「编辑标签」= 展示层管理弹窗（重命名/隐藏走 `SmartGroupService` 覆盖项，
   **不批量改游戏数据**）；「添加会社」= 自定义会社（重名拒绝）。
5. 衬线小字用系统 serif 回退链（`serif → SimSun`，应用未捆绑衬线中文字体），
   与设计稿 Noto Serif SC 观感接近但有细节差异。
6. 收藏夹条目图标按设计稿：文件夹描边（特别关注 = 实心琥珀星），
   不再使用 iconKind 的手柄/书签形状（数据字段保留）。
7. 旧「智能归纳」侧栏分区被标签库/会社墙取代；`SmartGroupService` 与其编辑弹窗
   保留复用（面包屑「编辑分组」入口仍在）。

## 6. 验证与遗留

- 进程内 analyzer（`.workbuddy/analyze_probe/`）：全 lib **errors=0**
  （warnings/infos 均为存量死代码）。
- ⚠️ `flutter test` 无法在本环境运行（管道 231 故障）——**开发者须在自己的终端
  跑 `flutter\bin\flutter.bat analyze test` 终验**。
- 遗留：真机走查（三视图切换、拖拽到标签 chip / 会社卡、多选面包屑、关注落盘、
  深色主题下观感）。

## 7. 升级记录

- **2026-10-04 BPM 面板对齐联动口径**（同日晚）：`big_picture_library_page.dart`
  去互斥三入口（`_selectCollection/_toggleTagKey/_enterCompanyKey`）+ `_contextGames`
  同构实现 + `_tagSections/_companyCards` 上下文派生 + 面板收藏夹/「所有游戏」计数
  联动 + 筛选 pill 组合标签（收藏夹 + 会社 + 标签全展示）。

- **2026-10-04 三视图联动**（实机反馈驱动）：取消收藏夹 / 标签 / 会社三视图
  互斥（`_enterCollection/_enterSmartGroup/_toggleTagKey` 不再清空其余维度）；
  三个视图的计数派生改**上下文口径**（`_contextGames(exclude*)`：排除自身
  维度、参与其他维度过滤）；面包屑升级为组合链（点单项移除）+ 组合空态提示。
  已选中标签计数归 0 保留显示。

- **2026-10-02 标签系统升级**（实机反馈驱动）：标签库由 9 条手写种子表改为
  **受控词表**（8 维度 / 97 概念 / 别名同义归并 / 单维度归属），过滤语义改为
  **维度内并集 · 维度间交集**；会社墙改**纯派生**并删除示例预置。详见
  `features/tag_vocabulary.md`。
- **2026-10-04 会社墙升级（会社图标 + 编辑会社信息）**：
  - `CompanyWallStore` v1→v2（新增 `display_names` / `logo_files` 覆盖表，
    兼容读 v1；P1-4b/4c 纪律不变）；
  - 新增 `CompanyLogoService`（NextMoe 会社 logo 抓取，vndb 源锚点精确对齐，
    失败静默降级）与 `category_box_company_editor.dart`（编辑会社信息弹窗）；
  - 会社卡片：logo 区支持图片（有图显示图 / 无图回退字标）+ hover 右上角
    「编辑会社信息」圆形按钮；
  - 改名语义：**只改显示名**，会社身份与筛选功能不变（弹窗内置提示）。
- **2026-10-04 标签库升级（内联编辑 + 写穿 + 全局隐藏）**：
  - 「编辑标签」由弹窗改为**面板内联编辑模式**（底栏「编辑标签」⇄「完成编辑」）：
    维度标题 ✎ 改名、顶部「＋ 新增维度」、标签 chip ⚙ 菜单
    （重命名写穿 / 全局隐藏 / 从所有游戏删除）、跨维度拖拽改挂；
  - 新增 `TagLibraryOverrideStore`（用户覆盖层，5 张表，P1-4b/4c）与
    `LocalGameRegistry.renameTagEverywhere/removeTagEverywhere`（归一化匹配写穿，
    单游戏失败回滚不中断整批，通知只发一次）；
  - 全局隐藏接入全部本地标签展示点（`filterVisibleTags` 唯一出口）；
  - 提示文案（内置）：改维度标题/归属不改筛选内容；新增维度系统不自动归类；
    重命名/删除写穿前二次确认。


---

## 8. 2026-10-04 · 编辑灰屏根因修复 + 会社墙全自动图标 + 封面式卡片

### 8.1 🔴 「编辑标签」灰屏（P0，已修）

- 现象：点「编辑标签」后标签库列表区整块变灰（release ErrorWidget 兜底）。
- 根因：`_buildTagSection` 中 `Widget body` 被重新赋值为 `DragTarget` 后，
  `DragTarget.builder` 闭包仍引用该**变量**（Dart 闭包捕获变量引用而非值）→
  builder 产物自包含 DragTarget 自身 → 挂载时无限递归 → 栈溢出。
- 修复：builder 引用快照 `final sectionBody = body;`。
- 回归：`test/widgets/library/category_box_sidebar_edit_test.dart`（5 例）。

### 8.2 会社图标全自动抓取（产品语义修正：无需任何按钮）

- `CompanyLogoService.autoFetchMissingLogos`：墙内派生出无图标会社 →
  后台自动检索 NextMoe 落盘 → `setLogo` 通知刷新。
- 去重：会话 in-flight/attempted 集 + 负缓存落盘
  `data/company_logo_attempts.json`（失败 7 天内不重试，防打满限流）。
- 挂点：`library_page._companyCards` 派生后 `Timer.run` 脱离 build 相。

### 8.3 封面式会社卡片（UI 重设计）

- GridView（固定 131 高）→ LayoutBuilder + Wrap 两列等宽（行高随内容）。
- 卡片 = tint 底色封面 + 图标 + **半透明信息条**（background@0.84，
  叠加封面内底部，文字完整清晰）。
- 图标自适应：**宽度铺满**（BoxFit.fitWidth）、高度按原始宽高比→
  短于基准(108)顶对齐、方形/高图向下扩展、超限(176)改 contain 居中；
  横长 logo（如 Navel）零留白零裁切（修复旧 BoxFit.cover 裁切问题）。
- 宽高比经 `instantiateImageCodec` 异步解码一次缓存（未就绪回退 contain）。

### 8.4 顺带修补

- `CompanyWallStore._save()` 在 `_loadFailed` 时跳过写盘（P1-4b 真正落地）。
- `CompanyLogoService.fileNameKey` 纯符号键兜底 `company`。
