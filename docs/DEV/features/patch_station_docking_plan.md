# 补丁站对接（PATCH-STATION）总体方案

**状态**：v5 UI 已落地（用户两次面评 13 条全部对齐），代码在仓内，渲染探针 **135** 断言全绿；⬜ 待真机走查  
**日期**：2026-11-10（v1 架构） / 2026-11-10（v2 UI 对齐） / 2026-11-10 23:0x（v4 首次面评返工） / 2026-11-11 00:1x（v5 二次面评返工）  
**接手说明**：本文件**取代**并扩展 `patch_finder_implementation_plan.md`（2026-11-04 那版只做"查找+跳转"）。  
用户 2026-11-10 明确扩大范围：**要像参考项目 GalGear 一样完整对接多个补丁站**，并在本软件内闭环。  
**参考项目**：`D:\CTLIB\ref\third-party\GalGear-main`（Tauri + Rust）

### v2 修订说明（2026-11-10 用户口述 UI；⚠️ 后续细节已被 **§4 v4** 覆盖，本节保留作决策留痕）

用户复述时纠正了 v1 的两处方向性偏差，**方向以本节为准，UI 细节以 §4 v4 为准**：

| 项    | v1 原写                           | **v2 更正**                                                                                        |
| ---- | ------------------------------- | ------------------------------------------------------------------------------------------------ |
| 入口数量 | D-4 只定"游戏详情页板块"，探索库独立页"留 P6 再议" | **双入口，同时做**：<br />① 探索库主界面顶栏新增「补丁站」按钮 → 展开**补丁站横条**<br />② 游戏详情页新增「补丁」按钮 → **深色锚定栏**（v4：位置在「分享」与「上传」之间，不再是「获取/分享」之间） |
| 作用域  | 未限定                             | **全部功能只服务探索库**，⛔ 不涉及其他界面（库页 / 大厅 / 设置除外，设置仅放补丁源开关）                                               |
| 交互形态 | 未定                              | 与第二行「标签 / 会社 / 评分」同样**点按钮弹下拉**，但这个下拉**比所有按钮的下拉都大**（名称：**补丁站横条**）                                 |
| 下载策略 | 未明说                             | **完全复用探索库现有下载能力**：能直连的直接软件内下载；不能直连的给引导（网盘链接 / 打开原站）                                              |

> 口述原话要点：「搜索栏的右侧向左边缩短，来放一个补丁站的按钮入口」「点击之后…会有一个下拉条，但这个下拉条会比这些所有的按钮都更大」「顶部一个补丁的搜索栏，然后补丁的来源，或者从游戏库中筛选的这个游戏，下方就是补丁资源的横条」「在获取分享的中间新增补丁按钮」

---

## 0. 一页结论

| 项                          | 结论                                                                                                                                                                                                                         |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 旧计划是否保存到位                  | ✅ 保存完整（`features/patch_finder_implementation_plan.md`，25 KB，阶段 A），但**代码零落地**（`grep patch_finder lib/` 无命中），git 也无相关提交                                                                                                      |
| 旧计划范围是否够                   | ❌ 不够。旧计划一期只有"搜索 + 打开浏览器"，**不做下载**。用户这次要的是"对接补丁站"完整闭环                                                                                                                                                                       |
| 🔴 旧计划最大的误判                | 旧计划认为"鲲/NextMoe 补丁拿不到直链（403），所以只能跳转"。**实测推翻**：`/v2/moyu/resources/{id}/file` 确实 403（需 `moyu:files` scope），但**资源网页 HTML 里就有公开直链** `https://dl.imoe.uk/moyu/*.zip`，实测 `HTTP 200`、`Content-Length: 134380932`。**软件内直接下载补丁成立** |
| 可对接到几个补丁站                  | **3 个真实源**（GalGear 只有 2 个，且它的鲲只能跳转）：鲲 Gal（NextMoe moyu，结构化 + 可直下）、2DFan（HTML，需账号）、自家社区（PB `game_resources` + OpenList，可直下）                                                                                                 |
| 我们比 GalGear 强在哪            | ① 数据源是 NextMoe **官方 v2 API**（GalGear 用的是被上游淘汰的 v1 接口），有 `hash`(SHA-256)/`note`(安装说明)/`type` 枚举；② 匹配能走 **catalog id 锚定**，不是它那种"查询串恰好等于标题"；③ 我们已有 `ExtractManager` / 安装中心 / 字体补丁的事务范式可参考（⚠️ `DownloadCore` **不可直接复用**：它会往 `game.json` 塞假条目 ⇒ 补丁下载另写 `patch_download_core.dart`）                         |
| 最大技术风险                     | 探索库 `GameModel` **没有任何外部 id 字段**（`lib/models/game_model.dart` 全文确认）。匹配只能靠"标题 → NextMoe catalog work id"解析 —— 已完成 24 条实测（见下行），**只剩扩样到 100 条**                                                                                        |
| 最大产品决策                     | 2DFan 下载必须登录（实测页面为"登录下载"）→ 已决策**一期就接账号**                                                                                                                                                                                   |
| **P0 实测结果（2026-11-10 已跑）** | 探索库 24 条真实标题：**解析到作品 24/24 = 100%**，**其中有补丁 22/24 = 92%**，共召回 **99 条补丁资源**（均 4.5 条/作品）；直链解析 **6/9 = 67%**，**未命中的 3 条全是网盘型**（夸克/百度），不是解析失败                                                                                  |
| 零迁移承诺                      | 不写 `game.json`、不改 `format_version=4`、不改 `luna_metadata_sdk`、不加 pubspec 依赖                                                                                                                                                  |
| **UI 定位（v4）**              | **只服务探索库**。双入口、**两套外壳、一套数据**：探索库顶栏「补丁站」→ 浅色横条 `PatchStationPanel`（屏宽 52%）；详情页「分享 / 上传」**之间**的「补丁」→ 深色锚定栏 `PatchStationDarkPanel`。⛔ 不新增页面；⛔ 不做常驻「保存到」底栏（下载前弹确认框选目录）。详见 §4 |

---

## 1. 与旧方案的关系（不重复造）

| 主题           | 旧方案（11-04）                   | 本方案（11-10）                                                                                                                    |
| ------------ | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| 检索           | moyu `/v2/moyu` + 2DFan + 社区 | 保留，站点定义为可插拔注册表                                                                                                                |
| 下载           | ❌ 明确不做                       | ✅ 纳入（鲲直链 + 社区；2DFan 二期）                                                                                                       |
| 安装/回滚        | ❌ 二期                         | ✅ 纳入（对齐 GalGear `patches.rs` 事务模型）                                                                                            |
| 匹配           | 担心没 vndb id                  | ✅ **降级解决**：`/v2/catalog/search?object=work&q=` 直接返回 NextMoe 作品 id，用 `refs=catalog:<id>` 锚定，**不需要 vndb_id**（旧方案 O-1 这个头号风险被消解） |
| PB schema 变更 | 可能要补 `vndb_id`               | ✅ 一期不需要（只在 P6 批量徽章时才考虑）                                                                                                       |

---

## 2. 参考项目做了什么（读码结论，附行号）

### 2.1 它的补丁站对接（`crates/core/src/providers.rs`）

- **2DFan**：`GET /search?keyword=` → `parse_links(prefix="/subjects/")` 取前 **5** 个作品（`:426`）→ 逐个 `GET /subjects/{id}/downloads` → `parse_links(prefix="/downloads/")`（`:433`）
  - 解析锚点：`.download-card-title a[href]`、`.download-card-kind`（类型徽章）、`.uploader-name`、`time.download-card-date`、`.download-card-size`（`:210-239`）
  - 域名白名单硬编码 5 个 2DFan 镜像（`:128-139`）——**换域就得改代码**，这是它的短板
- **鲲**：`GET https://www.moyu.moe/api/v1/search/quick?keywords=&content_limit=sfw`（`:477`），**只产出 `web_url`，没有直链**（`:543-553`）
- **失败降级**：两个源并发（`std::thread::scope`，`:455`），单源失败只记 warning，不伪造条目（`:465-473`）
  - ⚠️ 但它在 `/downloads` 页抓失败时会**伪造一条"作品级资源"**（`:439-445`）——**我们不复刻这个反面做法**

### 2.2 它的落盘事务（`crates/core/src/patches.rs`，827 行）

这套是本项目最该抄的部分：

1. `preview()`：解包到临时 staging，逐文件算 before/after SHA-256、字节数、是否覆盖（`:163-258`）
2. 路径安全：`relative()` 拒绝对路径/`..`/盘符/`\0`/Windows 保留名（`CON/PRN/AUX/NUL/COM1-9/LPT1-9`）/`.galgear*`/尾随空格点（`:69-99`）；`target()` 拒绝目标链路上任何符号链接、校验 canonicalize 不逃出根（`:100-123`）
3. `install()`：写前**重新校验**每个目标与暂存文件的哈希（`Files changed since preview`，`:438-456`）；备份原文件后原子写；任何一步失败 → `rollback()`
4. `rollback()`：先校验**所有**备份与当前文件，再逆序恢复；状态机 `installing → installed → restoring → restored`；启动时 `recover()` 收拾残留事务（`:531-629`）
5. 重叠补丁必须**逆序卸载**（`:601-616`）
6. 补丁本体以解包目录形式存在游戏根的 `patch/<补丁名>/`，原文件备份为 `patch/<补丁名>_original/`（`patches/folders.rs:30-46, 349-389`）
7. EXE 补丁**不代跑**：只登记 `manual_pending`，由用户自己执行后点"已安装"（`patches.rs:631-675`）——**这个克制值得保留**

### 2.3 它的 2DFan 账号（`crates/core/src/fan_account.rs`，1051 行）

Cookie 注入 → 只读账户态（余额）→ `requires_purchase` / `free` / `can_purchase` 三态 → 积分购买 → 免费领取 → 拿到 `file_url` 才算 `can_download`。  
**这就是"完全对接"2DFan 的真实成本**：1051 行 + 代理 + 账号风险。

### 2.4 它的三个短板（我们逐条规避）

| 短板                        | 位置                                 | 我们的对策                                                           |
| ------------------------- | ---------------------------------- | --------------------------------------------------------------- |
| 不做补丁↔游戏匹配，只靠"查询串 == 库中标题" | `crates/ui/src/patches.rs:385-395` | catalog id 锚定 + 标题解析缓存 + 多别名                                    |
| 不推断补丁该放哪，按包内相对路径直接落游戏根    | `patches.rs:193-216`               | 预览页显式列出"将被覆盖/新增/删除"的文件，用户确认                                     |
| 2DFan 域名硬编码               | `providers.rs:128-139`             | 复用我们 `TwoDFanService.kFanDomains` 的"镜像优先、主域垫底 + 运行期回退 + 软冷却"三件套 |

---

## 3. 站点能力矩阵（2026-11-10 全部实测，可复现）

| 站                        | 检索                                                                | 详情/说明                                                                                                                     | 直链                                                                | 凭证                                             | 结论                        |
| ------------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------- | ------------------------- |
| **鲲 Gal / NextMoe moyu** | `GET /v2/moyu/patches?refs=catalog:<id>` ✅；`?limit=`、`?cursor=` ✅ | `GET /v2/moyu/patches/{patchId}/resources` ✅ 返回 `name/size/hash(SHA-256)/note(安装说明)/type/language/download_count/web_url` | ✅ **资源页 HTML 内含 `https://dl.imoe.uk/moyu/*.zip`，实测 200 / 134 MB** | 我们已有 `nmk_live_` 密钥（`nextmoe_service.dart:60`） | ✅ **P0 主源，唯一"结构化 + 可直下"** |
| **2DFan**                | `GET /search?keyword=` → `/subjects/{id}/downloads` ✅ 实测 9 条补丁    | ✅ `/downloads/{id}` 页有说明                                                                                                  | ❌ 实测页面为"登录下载"，需 Cookie + 积分                                       | 需用户账号 + 代理                                     | ⚠️ **P1 检索源；下载需单独批准（二期）** |
| **自家社区**                 | PB `game_resources`（已有 `GameResourceService`）                     | ✅ 有 `unzip_code`/`languages`/`platforms`/`resource_type`（枚举里早就有"全年龄补丁/民间汉化"）                                              | ✅ OpenList 直链                                                     | 无                                              | ✅ **P0 必需，独有能力**          |
| 鲲旧接口 v1 `quick`          | ✅                                                                 | 仅外链                                                                                                                       | ❌                                                                 | 无                                              | ❌ 淘汰：NextMoe v2 是它的正式上游   |

### 3.1 实测命令与结果（留档）

```
# 1) 补丁列表（catalog 锚定）
GET /v2/moyu/patches?refs=catalog:15  → 200, id=15, vndb_id=v19073, type=[fix,manual,other,save], resource_count=10
# 2) 批量锚定
GET /v2/moyu/patches?refs=catalog:15,catalog:87,catalog:180,catalog:1822 → 200
# 3) 补丁资源（关键字段）
GET /v2/moyu/patches/87/resources → id=5459, name="CROSS†CHANNEL 復刻版 Ai无码补丁",
    size="102.537 MB", hash=ee3eb0f...(SHA-256), note="解压到根目录覆盖同名文件。…", type=["decensor"]
# 4) 官方直链接口（仍需 scope）
GET /v2/moyu/resources/11425/file → 403 SCOPE_REQUIRED
# 5) 但资源网页有公开直链
GET https://www.moyu.moe/resource/11425 → HTML 内含 https://dl.imoe.uk/moyu/2711e3ae-....zip
HEAD 该直链 → 200, Content-Type: application/zip, Content-Length: 134380932
# 6) 标题 → 作品 id（身份解析链，项目内已有同款调用）
GET /v2/catalog/search?object=work&q=千恋万花&nsfw=true → items[0].id=15, sources 内含 vndb:v19073
# 7) 2DFan
GET https://2dfmax.top/search?keyword=千恋万花 → 200（139 KB），subjects: 3100/7978/8811/6509
GET https://2dfmax.top/subjects/3100/downloads → 200，download-card-title ×9
GET https://2dfmax.top/downloads/15801 → 含 `登录下载`，无公开直链
# 8) 鲲 v1 兜底
GET https://www.moyu.moe/api/v1/search/quick?keywords=test&content_limit=sfw → 200
```

**⚠️ 关于第 5 条的诚实声明**：直链是网页公开可得的 `dl.imoe.uk` 链接，不是绕过授权。但它是**页面结构依赖**，站点改版就会失效 ⇒ 必须做成"解析失败 → 自动降级为跳转原站"，不能当硬依赖。同时 `hash` 必须参与校验（下一节）。

### 3.2 P0 实测补充（2026-11-10 同一轮，脚本一次跑完）

**① 直链解析覆盖率：6/9 = 67%，未命中的全是网盘型**

| 补丁                       | 结果                                | 投递形态                                                                                  |
| ------------------------ | --------------------------------- | ------------------------------------------------------------------------------------- |
| Steam版内容还原+汉化补丁 v0.6.0   | ✅ `application/zip` 134,380,932 B | `direct`                                                                              |
| CROSS†CHANNEL 復刻版 Ai无码补丁 | ✅ 107,517,662 B                   | `direct`                                                                              |
| 【群青学院·放送部】人工汉化补丁         | ✅ 709,141,470 B                   | `direct`                                                                              |
| パニカル・コンフュージョン AI翻译补丁     | ✅ 14,298,210 B                    | `direct`                                                                              |
| 转区运行                     | ✅ 2,969,098 B                     | `direct`                                                                              |
| （无名资源）                   | ✅ 5,499,933 B                     | `direct`                                                                              |
| resource/9659            | ❌ 无 dl.imoe.uk                    | `netdisk`：夸克 `quark.cn/s/7ccd032bc22c` + 百度 `pan.baidu.com/s/1uEfrVRozAPq7GgXGEwgcJg` |
| resource/8342            | ❌ 无 dl.imoe.uk                    | `netdisk`：百度 `pan.baidu.com/s/1jrTvnbw2Jox6xGvwytuUeg`                                |
| resource/7628            | ❌ 无 dl.imoe.uk                    | `netdisk`                                                                             |

🔴 **结论：补丁有三种投递形态，UI 与数据模型必须区分，不能只有"能下/不能下"两态。**  
这也是一个产品机会：网盘型可以显示"网盘链接 + 提取码"，用户复制即可，比只给一个原站页面体验好。

**② 探索库标题 → 作品 → 补丁 命中率（关键指标，旧计划 P0-2）**

样本：PB `games` 第 2 页 24 条（`totalItems=546`），别名顺序 `title → originalTitle → englishTitle`。

```
sample=24  解析到作品=24/24 (100%)  有补丁=22/24 (92%)  共召回 99 条补丁资源
0 条完全没解析到   0 错误
```

样例（真实输出）：

```
苍之彼方的四重奏            -> work 24    patches=1  res=9
苍之彼方的四重奏 EXTRA1     -> work 25    patches=1  res=5
死馆1：濒死轮回的卿…        -> work 293   patches=1  res=8
猫娘乐园 Vol.1             -> work 94    patches=1  res=6
纸上的魔法使                -> work 127   patches=1  res=8
死馆2:逝去的骑士…           -> work 101   patches=1  res=0   ← 解析对了，但该作品确实没补丁
```

⚠️ **样本偏差必须承认**：第 2 页偏主流作品；冷门/新作命中率会低。故 P0-2 仍需扩到 **100 条（含末页冷门）+ 精度抽检**（防止"搜到的是同系列另一部"）。但 92% 已经远超旧计划的 50% 出口判据 ⇒ **标题解析可以作主路径，无需 PB 加 `vndb_id`**。

---

## 4. UI 设计详规（v4，2026-11-10 22:5x 用户看实机后逐条重定）

### v4 相对 v2/v3 的八条改动（用户面评，逐条可追溯）

| # | 用户原话要点 | v4 落法 |
|---|---|---|
| 1 | 「并不是铺满了整个界面，而是大概是一个二分之一这么一个面板」 | 探索库面板宽 = `屏幕宽 × 52%`（夹在 460–700），右缘贴窗口右，从按钮下方垂到底 |
| 2 | 「把这整块面板分为两个板块……上方放搜索、游戏库、来源，下方是资源结果」 | 上板块（`buttonBackground` 底 + 下缘分隔线）／下板块（`background` 底 + 卡片） |
| 3 | 「搜索栏内的右侧，给它加一个搜索按钮」 | 搜索框内部右端一枚实心「🔍 搜索」按钮（26dp 高），回车仍可用 |
| 4 | 「所谓游戏库选择，不是探索库里的游戏，而是管理器库页的本地游戏」 | 改读 `LocalGameRegistry.instance.gamesMap`；内联下拉 + 筛选框，不再弹居中窗 |
| 5 | 「每个补丁卡片会给它标上补丁站的图标，2DFan 是小饭团，Kun 也有自己的图标」 | `patch_site_logo.dart` 用 CustomPainter 画：饭团 / 鲲鱼 / 气泡，三处尺寸自适应 |
| 6 | 「不仅可以打开资源页，还有查看下载……在软件内看到具体信息，并且会提供下载按钮」 | 每条都有「查看下载」→ `PatchInfoSheet`（直链 / 网盘 / 2DFan 积分三态） |
| 7 | 「保存到这个不需要在这设计……执行下载之前会弹一个确认框，可以自行选择目录」 | 删掉底栏；改 `PatchDownloadConfirm`（与 `InstallConfirmationDialog` 同款语言） |
| 8 | 「详情页的补丁面板做成类似旁边官方下载和用户分享的这么一个面板」 | 新增 `PatchStationDarkPanel`，`DarkPalette` + `showDarkAnchoredPanel`，宽 600 |

> 一句话：**数据层 / 卡片语义 / 详情浮层 / 下载链路全共用，只有外壳分两套** ——
> 探索库是浅色大下拉条，详情页是深色锚定栏（与「获取」「分享」同族）。

---

### 4.1 站点清单（UI「来源筛选」直接对应）

| UI 显示名 | 枚举 | 图标 | 数据来源 | 检索方式 | 直链 |
|---|---|---|---|---|---|
| **2DFan** | `twoDfan` | 饭团（三角 + 海苔） | `2dfmax.top` 等镜像（镜像优先、`.com` 垫底） | HTML（`/search` → `/subjects/{id}/downloads`） | ❌ 需登录 + 积分 |
| **鲲** | `kunlun` | 鱼（椭圆身 + 三角尾 + 镂空眼） | 列表 `api.nextmoe.dev/v2`；直链 `www.moyu.moe/resource/{id}` HTML | v2 API + HTML 解析 | ✅ `dl.imoe.uk` |
| **社区** | `community` | 对话气泡 | 自家 PB `game_resources` + OpenList | PB 查询 | ✅ OpenList |

鲲与 NextMoe 合并为一个源（v2 是鲲的官方 API 上游）——**一源两通道**，重复条目从根上消失。

---

### 4.2 入口 A —— 探索库顶栏「补丁站」

```
┌ 探索库顶栏 ────────────────────────────────────────────────┐
│ [🔍 搜索游戏…            ] [🧩 补丁站] [来源 ▾] [🚀 发布上传] │
└──────────────┬────────────────────────────────────────────┘
               │ 点击（搜索框右侧让位，宽度由 Expanded 自然收缩）
               ▼
      面板宽 = 屏宽 52%，右缘贴窗口右，从按钮下方垂到底边
```

- 图标准入：`_buildTopBarActionButton(icon: Icons.extension_rounded, label: '补丁站')`
- 锚点：`_patchStationButtonKey`（`discover_page.dart`）
- 带参：`initialQuery = _searchController.text.trim()`（把探索库当前搜索词带进去）
- ⛔ 不新增页面、不改探索库网格、不改 `_performFilter`

---

### 4.3 入口 B —— 详情页「补丁」（深色锚定栏）

**位置**：「分享」与「上传」之间（`game_detail_header.dart` `_buildPrimary` 复用）
**配色**：中性灰描边 + `AppColors.secondaryText` 文字（与主色按钮分层）
**点击**：`PatchStationDarkPanel.show(anchor: 补丁按钮自己的矩形, game: 当前作品)`

```
┌ 补丁站  星织梦未来                    [刷新] [关闭] ┐
│ (饭团)2DFan 4  (鱼)鲲 2  (气泡)社区 0              │  ← 来源 chip（深色）
├────────────────────────────────────────────────────┤
│ (饭团) ヱスガソラ 原版 步兵补丁        [查看下载][原页] │
│        2DFan · 无码 · 29.2 MB · yirigahama          │
│ (鱼)   缘之空 AI 无码补丁              [查看下载][原页] │
│        鲲 · AI翻译 · 256.3 MB · yirigahama          │
└────────────────────────────────────────────────────┘
```

| 项 | 规格 |
|---|---|
| 外壳 | `DarkShell`（恒深色，与「资源分享」同一套 `DarkPalette`） |
| 宽 | `DarkPalette.shareListWidth` = 600 |
| 高 | ⓐ 自然高上限：列表 `maxHeight: 430` 内部滚动；ⓑ 外层再被按钮下方剩余空间收紧（见下） |
| 锚点 | **补丁按钮自己的矩形**（不是整条操作行）；拿不到退回 `_actionAnchorRect()` |
| 定位 | `showDarkAnchoredPanel(stickBelow: true)`：**恒贴按钮下方**，放不下就压缩自身 + 内部滚动（⛔ 不再翻到上方） |
| 锁定 | 只出这一部作品；⛔ 不提供「换作品」（要换去探索库入口） |
| 文案边界 | ⛔ 不出现「安装 / 应用 / 套用到游戏」 |

#### 4.3.1 🔴🔴 为什么必须 `stickBelow`（v5.1，用户面评「点击之后直接跑到上面去了」）

`showDarkAnchoredPanel` 的默认算法是「下方放得下 → 贴下方；放不下 → 翻到上方」。这条
对矮面板（下载栏 155px、分享栏 160px）成立，但本栏自然高 **≈530px**，
1280×720 下按钮下方只剩 ≈420px：

```
roomBelow(420) >= roomAbove(≈200)  → 选「贴下方」 top = anchor.bottom + 8 ≈ 289
maxTop  = 708 − 530 = 178
top = 289.clamp(44, 178) = 178        ← 被夹到 178，整块跑到按钮**上方**，压住标题区
```

第 4 步的「夹紧」在面板高于剩余空间时反而把面板**上推**，这是肉眼看到「弹到上面」的真因。
（不是居中、不是锚点算错。）

修法：`showDarkAnchoredPanel(stickBelow: true)`

| 行为 | 默认 | `stickBelow: true` |
|---|---|---|
| 高度上限 | 整个可用区（标题栏下 → 窗底） | **锚点下方剩余空间**（`bottomLimit − anchor.bottom − gap`） |
| 位置 | 下方 / 上方二选一 | 恒为 `anchor.bottom + anchorGap` |
| 放不下时 | 翻到上方 | **压缩自身**，列表内部滚动 |
| 兜底 | — | 下方 < 200px（按钮贴窗底）时退回默认翻上逻辑，免得挤成一条缝 |

配套要求：正文区**不能**再包一层 `Column` 塞「降级提示行」——那会让列表变成非弹性子项
（拿到无界高度），既压不下去也滚不动，直接溢出。降级提示行改成滚动内容的**首项**
（`_buildList(leading: ...)`）。

实测（`patch_ui_probe` E2，1280×720，锚点 `Rect(330,300,84,38)`）：
`left=330`（=锚点左缘）、`top=346`（=按钮底+8）、`h=362`（=708−346，压到刚好）、`bottom=708`。

---

### 4.4 补丁站横条（`PatchStationPanel`，浅色，探索库）

#### 4.4.1 结构

```
┌ 上板块（buttonBackground + 下缘分隔线）───────────────────┐
│ [🔍 搜索游戏名或补丁名…            (🔍搜索)]  ↻   ✕      │ ①
│ [▤ 从游戏库选择 | 选择或搜索游戏名…            ×  ⌄]     │ ②
│   └（展开）┌ 筛选本地游戏库…            3 ┐              │
│            │ 千恋＊万花 ✓                │              │
│            │ 缘之空                      │              │
│            └─────────────────────────────┘              │
│ [(全部 36)] [(饭团)2DFan 36] [(鱼)鲲 0] [(气泡)社区 0]   │ ③
├──────────────────────────────────────────────────────────┤
│ 下板块（background）                                     │
│  ┌─卡片─┐ ┌─卡片─┐   ← 恒两列，铺满整行                  │ ④
│  ├──────┤ └──────┘                                      │
│  ┌─卡片─┐ ┌─卡片─┐                                      │
│  │ 展开卡（占满整行，详情就地铺开）──────────────────────┐│ ⑤
│  └──────┘ └──────┘                                      │
└──────────────────────────────────────────────────────────┘
```

> ⑤「查看下载」**不弹窗**：卡片原位**向右展开占满整行**，右边那张卡自然排到下一行
> （`Wrap` 自动换行，⛔ 不自己算坐标）。详见 §4.6。

#### 4.4.2 几何（🔴 尺寸由可用空间反推，禁止写死）

| 维度 | 公式 |
|---|---|
| 宽 | `min(屏宽 − 32, clamp(屏宽 × 0.52, 460, 700))` |
| 水平 | `left = max(16, 屏宽 − 宽 − 16)` —— **右缘贴窗口右**（与顶栏「发布上传」右缘对齐） |
| 顶 | `anchor.bottom + 6` |
| 高 | `屏高 − 顶 − 16`；若 < 320 → `height = min(320, 屏高 − 32)` 并回抬 `top` |
| 卡片列数 | 🔴 **恒等式** `columns × 卡宽 + (columns−1) × gap == innerWidth`；`innerWidth = LayoutBuilder.maxWidth − 2×12`，`columns ∈ [1,3]` 且卡宽 ≥ 236（`PatchGridMetrics.resolve`）。1440/1280/1080 三档实测 **2 列**，卡宽 331.4 / 314.2 / 262.2 |
| 展开卡宽 | `innerWidth`（整行）⇒ `Wrap` 自然独占一行、右侧卡下移 |
| 下拉高 | `(面板高 − 185).clamp(96, 190)` —— 展开时**不会把结果区挤成负数** |

> 🔴🔴 列宽**必须**用 `LayoutBuilder.constraints.maxWidth` 算，⛔ 不能用面板宽
> `metrics.width`：两者差着 `Border.all(1.6)×2 = 3.2px`，一旦用面板宽反推，
> `Wrap` 拿到的可用宽少 3.2 ⇒ 两列放不下 ⇒ **退化成 1 列 + 右边一大片空白**
> （2026-11-10 用户实机就是这样报的）。

#### 4.4.3 上板块三件套

| 区 | 内容 | 关键点 |
|---|---|---|
| ① 搜索 | 输入框 + 栏内「搜索」按钮 + 清空 × + 刷新 ↻ + 关闭 ✕ | 🔴 栏内按钮是**必需**（不熟快捷键的人不会按回车）；回车照旧可用 |
| ② 游戏库 | 图标 + 「从游戏库选择」+ 当前选中名 + × + ⌄ | 锁定态退化为只读「已锁定」；展开是**内联下拉**（不弹居中窗），带筛选框与计数 |
| ③ 来源 | 全部 / 2DFan / 鲲 / 社区，各带站点图标 + 条数 | 失败源标红 `!`；切换零网络（内存过滤） |

#### 4.4.4 补丁卡片（结果区单元）

```
┌──────────────────────────────────────────┐
│ (饭团) 2DFan  [无码]                 29.2 MB │ ← 站点图标+站名+类型 … 大小
│ ヱスガソラ 原版 步兵补丁                       │ ← 标题 2 行
│ 适用于 缘之空 · yirigahama · 夸克 · 提取码 kUz4│ ← 元信息 + 投递形态
│                          [查看下载]  [原页] │ ← 两个动作
└──────────────────────────────────────────┘
```

| 元素 | 规格 |
|---|---|
| 卡宽 | 由父级 `LayoutBuilder` + `PatchGridMetrics` 反推（两列：1080→262.2 / 1280→314.2 / 1440→331.4），**不写死** |
| 卡高 | `kPatchCardHeight = 138`（定高，避免同行高矮不齐） |
| 站点图标 | `PatchSiteLogo(size: 16)`，**官方素材优先**（`assets/patch_sites/`），无素材/加载失败才退回 painter |
| 类型徽章 | 最多 2 个（`badgeLabels`，对不上的显示原文） |
| 元信息行 | 适用于 / 作者 / **投递形态** / 下载次数，单行省略 |
| 主按钮 | 「查看下载」→ **原地展开**该卡（`_toggleExpand` → `PatchExpandedCard`），⛔ 不再弹 `PatchInfoSheet` |
| 次按钮 | 「原页」→ 系统浏览器（永远可用的兜底） |
| 有下载记录时 | 底部整行让给进度条 + 状态文案 + 取消 / 继续 / 重试 / 打开文件夹 |

#### 4.4.5 状态与降级

| 状态 | 表现 |
|---|---|
| 加载中 | 居中「正在检索补丁…」（三源并发说明） |
| 部分源失败 | 顶部浅红提示条 + 其余源照常出卡，⛔ 不伪造条目 |
| 全部失败 | 「所有补丁源都不可用」+ 重试 |
| 无结果 | 「没有找到补丁」+ 分支说明（切「全部」/ 换名称 / 从游戏库锚定） |
| 未输入 | 「输入游戏名开始查找补丁」+「也可以从游戏库挑一部作品锚定」 |

#### 4.4.6 交互

- 点面板外空白 → 关闭；`✕` → 关闭
- 换来源 tab / 改关键词 → 面板内重查，**不关面板**
- 快速改词有**轮次闸**（`_runId`），旧请求回来不覆盖新结果
- 下载进度只重建结果区（`AnimatedBuilder` 只包网格，⛔ 不包整个面板）
- 面板关闭后 `postFrameCallback` 仍在队列里 ⇒ `_runSearch` 必须 `mounted` 早退

---

### 4.5 「从游戏库选择」的数据来源

| 项 | 结论 |
|---|---|
| 数据 | 🔴 `LocalGameRegistry.instance.allGames` —— 与**库页**（`library_page.dart`）完全同源。用户反复强调：这里是「库页」那一批本地游戏，⛔ **不是**探索库在线列表 |
| id | `gameId`（空则退 `directoryPath`），交给 `PatchIdentityResolver` 解析鲲的作品 id |
| 候选标题 | `title` + `subtitle`（副标题＝原名/罗马音） |
| 缩略图 | `coverPath`（`Image.file` + `errorBuilder` 防红屏），下拉每行 30px 定高 |
| 缓存 | 首次展开取一次存 `_gamesCache`（本地库上千条，⛔ 每次 build 都重扫）；`invalidateGames()` 供注册表变化后刷新 |
| 注入点 | `PatchStationPanel.show(gamePicker:)` —— 探针用它注入假数据，生产留空即读注册表 |
| 兜底 | 注册表为空 → 下拉里写「本地游戏库为空，可先用关键词搜」，不拦检索 |
| 回车 | 🔴 筛选框回车 = **选中第一项**并立即检索；空列表时只关下拉 |

> 🔴 **2026-11-14 回归修复（用户报障：「从库中选择」列的是探索库云端作品）**
> `discover_page.dart::_openPatchStation()` 曾主动注入
> `gamePicker: () => [for (final g in _displayGames) …]`。而 `_games()` 的规则是
> **注入优先**，注入一存在就把上表的默认实现整个盖掉 ⇒ 下拉里全是探索库
> 云端作品、每行没有 `coverPath` 因而一片灰色占位图、计数显示 362。
> 已删除该注入，生产调用恢复留空 ⇒ 只读 `LocalGameRegistry.instance.allGames`。
>
> **用户 2026-11-14 裁决**：只针对「库」页里**用户导入 / 已下载入库**的游戏；
> ⛔ 不含下载中或未入库的记录；⛔ 不在「库」页另加入口（入口维持探索页顶栏 + 详情页）。
> `initialQuery`（探索页带入当前搜索词）保留，与本口径无关。
>
> **防回归**：`dev_probe/patch_station_probe.dart::_probeLibraryPickerSource()`
> 按花括号配平截出 `_openPatchStation()` 函数体，断言不含 `gamePicker` /
> `_displayGames` / `_allGames`、仍含 `initialQuery`；另断言面板默认仍读
> `LocalGameRegistry.instance.allGames` 且 `gamePicker` 注入点仍在（探针要用）。

---

### 4.6 「查看下载」= 原地展开（v5，2026-11-11 用户重定）

> 🔴 **不另开窗口**。用户原话：「为什么这个查看下载一定要另外设计一个窗口呢？就不能在
> 原来的卡片的基础上点击之后，就将这个卡片展开……展开的时候往右边展开，原先右边的卡片
> 就往下排，然后把详情信息依次展到这里来。」
>
> ⇒ `PatchInfoSheet`（恒深色居中浮层）**已删除**，拆成两块：

| 文件 | 职责 |
|---|---|
| `PatchExpandedCard`（定义在 `patch_card.dart` 内，无独立文件） | **外壳**：站点图标 + 站名 + 徽章 + 大小 + 「收起」→ 标题 → 元信息行 → 分隔线 → 详情本体 |
| `patch_download_details.dart` | **内容本体**（无窗口外壳）：投递三态块 / 说明 / SHA-256 / 动作行 / 进度行。`onDark` 控制浅色两套取色，`dense` 控制紧凑排版 |

#### 4.6.1 布局契约

- 展开项宽 = `innerWidth`（整行）⇒ `Wrap` 自动独占一行，右侧卡片**自动**下排。
  ⛔ 不自己算 y 坐标、⛔ 不用 `Stack`、⛔ 不改造 `Wrap`。
- 展开态边框换 `AppColors.accentCyan.withOpacity(0.45)` 作视觉标记。
- 同一时刻**只允许一个**展开项（`String? _expandedKey`）；换搜索结果时清空。
- 点「收起」或再点同一张卡 → 回到普通卡（`_countOf<PatchCard> == 6`）。
- 深色详情页（`patch_station_dark_panel`）同款：`_PatchRow` 展开时下方就地铺
  `PatchDownloadDetails(onDark: true, dense: true)`，同样不弹窗。

#### 4.6.2 投递三态（内容与 v4 一致，只是换了承载容器）

| delivery | 投递块 | 主按钮 |
|---|---|---|
| `direct` | 「直链文件 · `dl.imoe.uk`」+ 文件大小 + 下载后去向 | **下载到本地**（→ 下载确认框） |
| `netdisk` | 「夸克网盘分享」+ 链接 + 提取码（**缺失显式写「原页未公开」**） | **复制链接与提取码** |
| `web` | 「需要在站点页面下载」+ 2DFan 的「本次费用 / 账号积分 = 登录后可见」两格 + 说明 | **打开资源页** |

> 🔴 2DFan 的积分/费用如实写「登录后可见」：没有 Cookie 时下载页只给登录框，
> 拿不到真实数字。⛔ 不编假数值；P5 接入 Cookie 后再换成真实「所需积分 / 我的积分」。
>
> ⚠️ 标题**不在** `PatchDownloadDetails` 里（由 `PatchExpandedCard` 外壳提供）——
> 探针 F 段因此删掉了「显示补丁标题」三条断言，别再加回去。

---

### 4.7 下载确认框（`PatchDownloadConfirm`）

点「下载到本地」→ **先确认再下**（与下载游戏本体一致）：

```
┌ 确认下载 ───────────────────────────────┐
│ (饭团) 2DFan [无码]              29.2 MB │
│ ヱスガソラ 原版 步兵补丁                   │
│                                          │
│ 保存位置            与下载游戏本体一致，可自选│
│ [📂 D:\...\ChronoTide_Patches      ›] [默认位置]│
│                                          │
│ 将写入（并解压到同名文件夹）                │
│ D:\...\ChronoTide_Patches\moyu_5459_xxx.zip│
│                                          │
│ 下载包体积 29.2 MB   目标盘可用 213 GB     │
│ ⓘ 只下载，不会装进游戏目录，也不会启动游戏  │
│                          [取消] [开始下载] │
└──────────────────────────────────────────┘
```

| 规则 | 说明 |
|---|---|
| 默认目录 | 用户上次选的 → 建议目录 `<库根>/ChronoTide_Patches`（⛔ 不能落进 `ChronoTide_Cache`，那里会被清理扫掉） |
| 写权限 | 点「开始下载」时**真写一个探针文件再删**（只读盘靠「目录存在」骗不过） |
| 空间 | 下载包体积 vs 目标盘可用，不足给红字警告但**不禁用**（解压后体积不可预知） |
| 记忆 | 确认后 `PatchSaveLocation.set(dir)` 记住，下次默认 |
| 文案 | ⛔ 不出现「安装 / 应用 / 覆盖游戏」 |

---

### 4.8 站点图标（`patch_site_logo.dart`）

**取图顺序：官方素材优先，painter 兜底。**

| 站点 | 素材（`assets/patch_sites/`） | 兜底 painter | 依据 |
|---|---|---|---|
| 2DFan | `two_dfan.png`（官方 favicon 32×32，饭团脸） | 实心圆角三角 + 裁进轮廓的海苔带 | 站点 logo 就是饭团 |
| 鲲 | `kunlun.webp`（官方 favicon 256×256） | 椭圆身 + 三角尾并集，眼睛 difference 挖空 | 站点官方 mark |
| 社区 | 无（`assetPathOf` 返回 null） | 圆角气泡 + 左下尾巴 | 用户分享 |

- 素材以 `Image.asset(fit: cover)` + `ClipRRect(28% 圆角)` 渲染，观感等同 App 图标
- 🔴 `errorBuilder` 兜住两种失败：素材文件缺失、flutter_tester 下无 assetBundle（探针环境）⇒ 静默退回 painter，⛔ 不红屏、不抛 `FlutterError`
- 🔴 **换图只换文件**：同名同格式覆盖 `assets/patch_sites/` 即可，零代码改动；换格式才改 `assetPathOf` 的扩展名
- painter 兜底：底板 `color.withOpacity(0.14)` 圆角方块；深色档 2DFan 近黑 → `#DFDFE6`（深色浮层必须传 `onDark: true`）
- 🔴 `CustomPainter.paint()` 抛异常是**静默吞帧** ⇒ 探针逐尺寸（10/12/16/19.5/22/34 × 3 站）验证
- 🟡 2DFan 官方只发布到 32×32（4 个镜像站的 favicon 全部同一份 5430 字节），34px 档有 6% 上采样；用户提供高清原图后覆盖同名文件即可

---

### 4.9 布局红线（照 `MEMORY.md` 第 5 节）

1. 🔴🔴 **面板内容必须整份落框内**：1280×720 / 1280×688 / 800×600 三档都要验，判据不是「0 溢出」而是「没被压扁、没有半张卡、没有残行」
2. 🔴 `clamp(lo, hi)` 当 `hi < lo` **抛 `ArgumentError`** ⇒ 所有尺寸反推走 `_clampSafe`
3. 🔴 展开态（游戏库下拉）是**可变高度**且不参与 Column 分配 ⇒ 上限必须按剩余空间反推，否则面板一矮就 RenderFlex overflow
4. 🔴 `pop()` 之后立刻 `push()` 会「一边退一边进」⇒ 关闭详情浮层再开确认框必须走 `addPostFrameCallback`
5. 🔴 哨兵必须注入真实数据（6 条含网盘无码型 + 超长标题 + 单源失败 + 窄屏）

---

### 4.10 与 GalGear 的 UI 对照

| GalGear | 我们 | 说明 |
|---|---|---|
| 独立左侧导航「补丁」页 | 浮层（浅色大下拉条 / 深色锚定栏） | 只服务探索库，不新增页面 |
| 顶部：名称 + 「搜索补丁」 + 「令牌配置」 | 搜索栏内「搜索」按钮 | 凭证放设置里，不占主界面 |
| 「从游戏库搜索」下拉 | 同款内联下拉（本地游戏库 + 筛选框） | 数据来自 `LocalGameRegistry` |
| 「全部来源 25 / 鲲Gal 0 / 2DFan 25」 | 同款来源 chip（带站点图标 + 计数） | 直接对齐 |
| 结果 = 纵向列表（一行一条，右侧两个按钮） | 多列卡片（每张两个按钮：查看下载 / 原页） | 与探索库网格语言一致 |
| 每条：「查看下载」+「打开资源页」 | 同款两动作 | ✅ 本轮补齐 |
| 「下载确认」内联卡（费用 / 积分 / 目录 / 下载文件） | `PatchInfoSheet` + `PatchDownloadConfirm` 两个浮层 | 我们把「看图/看信息」和「确认落点」拆开，各自更专注 |
| 站点图标（饭团等） | 同款（饭团 / 鱼 / 气泡） | ✅ 本轮补齐 |

---

## 5. 总体架构

```
┌───────────────────────────── UI 层（只服务探索库，见 §4 v4）
│ ① 探索库顶栏「补丁站」按钮 → PatchStationPanel（浅色横条，屏宽 52%）
│ ② 游戏详情页「补丁」按钮（分享↔上传之间）→ PatchStationDarkPanel（深色锚定栏）
│ ③ PatchDownloadDetails + PatchExpandedCard（「查看下载」原地展开：直链 / 网盘 / 网页）
│ ④ PatchDownloadConfirm（下载前确认：选目录 + 落点预览 + 空间账）
│ ⑤ 设置 →「补丁源」（站点开关 / 2DFan Cookie / 代理 / NextMoe key 状态）
└──────────────────┬────────────────────────────
                   ▼
        PatchSearchService（聚合 / 去重 / 降级 / 缓存 / 限流）
                   │
   ┌───────────────┼────────────────┬──────────────────┐
   ▼               ▼                ▼                  ▼
MoyuPatchSource  TwoDFanPatchSource CommunityPatchSource  (可插拔：PatchSource 抽象)
 │ JSON v2        │ HTML + 镜像回退   │ PB game_resources
 │ + 直链解析     │ 只读检索(一期)    │ + OpenList
 └───────────────┴────────────────┴──────────────────┘
                   │
                   ▼
      PatchIdentityResolver（标题/别名 → NextMoe work id → refs=catalog:<id>）
                   │
                   ▼
        PatchDownloadService（.part 续传 + 进度 + 取消 + 流式 SHA-256 校验 + 磁盘预检）
                   │
                   ▼
        PatchExtractService（进程内 package:archive；剥外层目录；zip slip 拦截）
                   │
                   ▼
        用户自选目录（默认 <库根>/ChronoTide_Patches / <包名>[_2]）—— 到此为止
```

> 🔴 v3/v4 起链路终点就是「文件躺在用户选的目录里」。原 `PatchInstallService` /
> `PatchLibraryService`（备份 → 覆盖 → manifest → 回滚）**已整批取消**，见 §7 P4-B。

**设计原则（与项目既有护栏一致）**

1. **id 优先，标题兜底**：能拿到 catalog id 就绝不用标题猜；标题只用于"首次解析"，结果进磁盘缓存（含负缓存）。
2. **单源失败只降级不伪造**：任一源失败 → 该源卡片显示"暂时不可用"，其余照常出；⛔ 不造假条目凑数（GalGear 的反面教材）。
3. **网络绝不进 `build()`**：浮层先开、loading 先出、结果异步追加。
4. **直链是"可能会碎"的能力**：解析失败一律降级成"打开原站"，UI 文案写清"在浏览器中下载"。
5. **落点必须用户确认，且永不覆盖已有文件**：下载前弹 `PatchDownloadConfirm`（可改目录 + 落点预览 + 空间账）；重名自动 `_2`/`_3`。
6. **EXE 补丁不代跑**：只提示「含可执行文件」+ 打开所在文件夹，用户自己决定（GalGear 的克制，我们也照做）。
7. **限流**：走 `luna_metadata_sdk/lib/services/rate_limiter.dart` 的 `executeRateLimited(SourceType.nextmoe, ...)`。

### 5.1 「鲲的补丁几乎搜不到」的两个独立根因（v5.2，2026-11-13）

用户面评：kungal 的缘之空页面上明明有一大串补丁（Splane 汉化整合包 / AI 无码 / DL 版步兵 / 修正 1.01 / 全 CG 存档…），
软件里无论详情页「补丁」还是探索库顶栏「补丁站」都几乎搜不到。**这是两个各自独立、都能单独造成「没有鲲」的 bug。**

现场实测（用应用内置的同一个 `nmk_live_` 密钥直连）：

| 请求 | 结果 |
|---|---|
| `GET /v2/moyu/patches?refs=catalog:51&limit=100` | `{"items":[], "missing":["catalog:51"]}` ← **我们的现状** |
| `GET /v2/moyu/patches?refs=catalog:51&limit=100&nsfw=true` | `1` 个 patch，`resource_count=11` |
| `GET /v2/moyu/patches?refs=catalog:51&limit=100&nsfw=false` | `{"items":[], "missing":["catalog:51"]}` |
| `GET /v2/moyu/patches/51/resources?limit=100` | 11 条（与 kungal 页面上那串完全对得上，**resources 不需要 nsfw**） |
| `GET /v2/moyu/patches?refs=catalog:15&nsfw=true`（千恋＊万花，`content_limit=sfw`） | 1 个 patch，`resource_count=10` ← **不会因为带 nsfw 反而变少** |

> kungal 页面上那块「补丁下载」的 Nuxt 缓存键是 `api:galgame-moyu-patches:51`，
> 说明**站上读的就是 moyu 这一份数据**，我们没查错站；kungal 自家 `/api/*`
> 现在全部 401（「用户登录失效」），走 NextMoe v2 才是正确路径。

**Bug ①：`nsfw` 只在上下文里，从没传进源**

服务端默认按 SFW 过滤，`content_limit=nsfw` 的 patch 整条被丢进 `missing`；
映射层只看到「items 为空」⇒ 当成「这部作品确实没补丁」，**连 `failures` 都不进**，
UI 上既不报错也没有卡片，静默消失。表现就是「SFW 补丁能搜到、R18 补丁全不见」。

- 修法：`_fetchPatches(workId, nsfw: ctx.nsfw)`；参数表抽成纯函数
  `sources/moyu_query_params.dart` 的 `buildMoyuPatchesQuery()`，**`nsfw` 是必需参数**
  （漏传＝编译错误，而不是只在 R18 作品上才暴露的静默数据丢失）。
- `_fetchResources` 刻意**不加** nsfw：按 patch id 直取，实测不带 nsfw 也返回完整 11 条。

**Bug ②：全局关键词检索根本没请求鲲**

`PatchSearchService.search` 原来的门禁是 `(gameId ?? '').isNotEmpty` 才做身份解析；
探索库顶栏「补丁站」在没选中游戏时 `gameId` 是 `null` ⇒ 这一步被整段跳过。
而鲲的能力表是 `byKeyword: false`（NextMoe 没有补丁名检索，只能 `refs=catalog:<id>`
锚定）⇒ **鲲一次都不会被请求**，全局搜出来的自然全是 2DFan 的。

- 修法：门禁去掉 gameId 依赖，缓存键降级为 `kw:<归一化关键词>`
  （纯函数 `patchIdentityCacheKey()`）；**没有 gameId 时只采信 `isConfident`（≥0.8）**
  的结果（纯函数 `acceptKeywordWorkMatch()`）——没有权威锚点时唯一依据是标题相似度，
  `pickWorkMatch` 完全对不上会退化成「取首条 + 0.5」，那种结果拿去查鲲就是串味。
  有 gameId 时的行为**完全不变**（低置信度照用，UI 显示「匹配到：X」）。

| 项 | 值 |
|---|---|
| 新增文件 | `lib/services/patch/sources/moyu_query_params.dart`（纯 Dart） |
| 改动文件 | `moyu_patch_source.dart`、`patch_identity_matcher.dart`（+2 纯函数）、`patch_search_service.dart` |
| 未动 | 2DFan 源、社区源、`_fetchResources`、UI 三层、下载链路、`MoyuV2Mapper` 字段映射、`pickWorkMatch` 打分算法 |
| 回归 | `patch_station_probe` 124 → **144**；`patch_ui_probe` 135 → **140**（新增 L 段 5 条） |
| 预期 | 缘之空：鲲 0 → **11**（叠加 2DFan 的 36 条后约 45 条） |

### 5.2 2DFan 账号/积分兑换 + 多入口投递（v5.3，2026-11-13）

用户面评（原话）：

> 我之前要你实现的一个功能你并没有实现……就是保证我们软件可以登录这个玩家的 2DFAN 账号，
> 并且实现在软件内使用自己账号下的积分来兑换并下载这个补丁资源。
> ……如果是直链，那我们是不是也应该实现本地这个软件类的在线下载；如果是网盘资源，
> 那么展开的页面中是不是就应该出现对应的网盘的信息，来方便用户不用打开原页就可以查询下载。

#### ① 先说死结论：**不代登录**（实测，别再试）

抓 `2dfmax.top/login` 的真实表单：

```html
<form action="/login" method="post">
  <input name="login"> <input name="password">
  <div class="cf-turnstile" data-sitekey="0x4AAAAAAAju-ZORvFgbC-Cd"></div>
</form>
```

验证码是 **Cloudflare Turnstile**（站内还带 `aliyun_captcha_verify_param`）。它在真实浏览器里跑
指纹挑战、服务端校验**一次性 token** ⇒ **任何纯 HTTP 的「输密码代登录」都不可能通过**；
内嵌 WebView 也大概率被判 bot。参考项目 GalGear 同样**不做代登录**（`fan_account.rs` 只吃
`FanCredentials{cookie, token}`）。

⇒ 本项目口径：**「登录」= 复用你在浏览器里已经登录好的会话**。用户在浏览器登录一次
（Turnstile 由他本人拖一下），把 Cookie 粘进「设置 → 元数据 → 2DFan」，软件即获得完整账号能力
（看昵称/积分 → 查价 → 兑换 → 把文件下到本地）。Cookie 输入口 v5 之前就有，本次把它从
「只保存」升级为「**真校验**」：粘贴后立刻在**实际要用的镜像**上读一次首页，
回「已登录：昵称 · 积分 N」或「站点仍视你为未登录」——这样才能揪出
**Cookie 与镜像域名不匹配**这个最容易踩的坑（在 `2dfan.com` 登录、软件探到 `2dfmax.top`）。

#### ② 兑换的三条护栏（对齐参考项目语义，缺一不可）

1. **下单前复核**：`purchase()` 先 `inspect()` 一次，`fresh.price` 必须等于用户在确认框里
   看到的价格，不等就中止；余额不足 / 登录态失效 / 无端点 / **无标价**一律拒绝
   （⛔ 绝不在不知道价格的情况下扣分）。
2. **只 POST 一次**：⛔ 不自动重试。超时或网络异常时我们**不知道**服务器有没有扣分，
   只能回 `uncertain` 让用户去网页核对 —— 自动重发就是**扣两次**。
3. **下单后再查一次**：只有页面真出现文件链接才算成功；已给过链接的直接回
   `alreadyAvailable`（不重复扣）。

UI 侧：`uncertain` 只出黄色提示 + 「去网页核对」，**不给「重试」按钮**；
确认框必须同时显示「本次扣除 X 积分」与「当前积分 Y」，否则用户是在盲扣。

#### ③ 多入口投递（鲲的「共 N 个」不再只留第一个）

旧实现 `resolveDelivery` 只保留**第一个**链接，一个资源页挂「网盘载点1/2 + 海外直连」时
其余入口直接丢失，用户只能回原页翻 —— 与「不打开原页就能下载」的目标相反。

现在：`PatchResource.links` 收全部入口（直链在前、网盘在后，各自保持页面顺序），
`PatchDeliveryDetail.links` 原样上屏，`PatchDownloadDetails` 逐条渲染
服务商 / 链接 / 提取码 / 单条「打开」。

| 项 | 值 |
|---|---|
| 新增文件 | `sources/two_dfan_page_parser.dart`（纯 Dart 解析）、`sources/two_dfan_account_service.dart`（会话 / 查价 / 兑换）、`patch_delivery_service.dart`（按需解析 + 2 分钟缓存 + 并发去重）、`widgets/patch_station/patch_delivery_loader.dart`（展开位加载器 + 兑换确认框） |
| 改动文件 | `models/patch_resource.dart`（+`links`）、`sources/moyu_resource_parser.dart`（返回全部入口）、`sources/moyu_patch_source.dart`、`patch_download_details.dart`（多入口 + 积分块）、`patch_card.dart` / `patch_station_panel.dart` / `patch_station_dark_panel.dart`（接线 + 直链回传）、`services/metadata_credentials.dart`（+`verifyTwoDFanCookie`）、`widgets/settings/metadata/metadata_accounts_card.dart`（保存后真校验） |
| 为什么 2DFan 是「按需解析」 | 检索期逐条抓 `/downloads/{id}` = 一次搜索 5 部作品 × N 条补丁 ≈ 几十个请求，站点限流 + 用户等十几秒。改成**点开「查看下载」那一刻才抓这一条**；鲲/社区在检索时已抓全，同步直出**零请求** |
| 镜像一致性 | 详情抓取与兑换 POST 都用 **`resource.webUrl` 的 host**（检索阶段已探通的那个），否则会出现「列表说已登录、展开说未登录」 |
| 直链回传 | 2DFan 的 `directUrl` 模型里**恒为空**（兑换后才有）⇒ 面板回调改成 `onDownloadDirect(url)`，下载前 `copyWith(delivery: direct, directUrl: url)`；`_lastDirectUrl[key]` 记住上次地址，失败「重试」才不会报「没有直链」 |
| 探针 | `patch_station_probe` 144 → **182**（2DFan 账号 8 + 下载页 30）；`patch_ui_probe` 140 → **149**（F2 浅/深 ×4 + F3 3） |

#### ④ 仍未验证 / 待真机

- ⏳ **真实兑换没有跑过**（会扣真积分，须用户自己点）。代码侧只有夹具与静态分析在护航。
- ⏳ 真实页面是否仍含 `data-island="NexusHeader"` / `.download-info-item` / `csrf-token`：
  2026-11-13 抓 `2dfmax.top/downloads/38989` 实测**命中**（价格 7 积分、百度网盘 `ep1f`、
  csrf 86 字符），站点改版后需重新对样本。
- ⏳ 2DFan 的「下载」有概率跳到中间页（需 JS），那种资源我们只能给原页链接。

---

## 6. 数据模型（全部纯内存 / JSON 缓存，零 schema 迁移）

### 6.1 `lib/models/patch_resource.dart`（新增）

```dart
enum PatchSite {
  kunlun,    // 鲲：列表/元数据走 api.nextmoe.dev/v2，直链走 www.moyu.moe 资源页 HTML
  twoDfan,   // 2DFan
  community, // 自家 PB game_resources + OpenList
}

extension PatchSiteLabel on PatchSite {
  String get displayName => switch (this) {
        PatchSite.kunlun => '鲲',
        PatchSite.twoDfan => '2DFan',
        PatchSite.community => '社区',
      };
  String get tag => switch (this) {
        PatchSite.kunlun => 'moyu',      // 去重/缓存键前缀（沿用 NextMoe 资源 id 空间）
        PatchSite.twoDfan => '2dfan',
        PatchSite.community => 'pb',
      };
}

/// 补丁投递形态（P0 实测结论：三种形态真实存在，不能只做"能下/不能下"两态）
enum PatchDelivery {
  direct,   // 有可直连文件（moyu 的 dl.imoe.uk / 社区 OpenList）→ 软件内下载
  netdisk,  // 只有网盘分享（夸克 / 百度）→ 展示链接 + 提取码，复制/浏览器打开
  web,      // 只能跳转原站（2DFan 未登录、直链解析失败）
}

enum PatchKind {                       // 跨站归一化（moyu 的 type 枚举 + 2DFan 徽章 + PB resource_type）
  translation,   // manual / 汉化 / 民间汉化
  aiTranslation, // ai / AI翻译
  machine,       // machine / machine_polishing / 机翻
  save,          // save / 全CG存档
  decensor,      // decensor / 无码
  crack,         // crack
  fix,           // fix / 修正
  mod,           // mod
  r18,           // r18 / 全年龄补丁
  image, other,
}

class PatchResource {
  final String key;            // 全局去重键："moyu:5459" / "2dfan:15801" / "pb:<recId>"
  final PatchSite site;
  final String id;             // 站内 id
  final String title;
  final String gameTitle;
  final List<PatchKind> kinds;
  final List<String> languages; // 归一化 zh-Hans/ja/en
  final List<String> platforms;
  final int? sizeBytes;         // 数值（不用 GalGear 的字符串，展示层格式化）
  final String sha256;          // moyu 有，其余空
  final String note;            // 安装说明（可含换行，长文本）
  final String webUrl;          // 原站页面（兜底动作）
  final PatchDelivery delivery; // direct / netdisk / web
  final String? directUrl;      // 直链；null = 无直连文件
  final String? netdiskUrl;     // 网盘分享链接（delivery==netdisk 时非空）
  final String? extractCode;    // 网盘提取码
  final int downloadCount;
  final String author;
  final DateTime? updatedAt;
  bool get downloadable => delivery == PatchDelivery.direct && (directUrl ?? '').isNotEmpty;
}

class PatchQueryResult {
  final List<PatchResource> resources;
  final Map<PatchSite, String> failures;  // 源 → 失败原因（UI 显示"该源暂不可用"）
  final bool resolvedByTitle;             // 是否走的是标题兜底（UI 可提示"匹配可能不准"）
}
```


### 6.2 缓存（新增，不属 schema）

| 文件                                         | 内容                                                  | TTL                                     |
| ------------------------------------------ | --------------------------------------------------- | --------------------------------------- |
| `data/cache/patch_identity.json`           | `{gameId: {workId, matchedTitle, resolvedAt}}`，含负缓存 | 30 天（对齐 `kungal_link_service._diskTtl`） |
| `data/cache/patch_search_<hash>.json`      | 检索结果快照（按 游戏id 或 关键词 哈希）                             | 24 小时                                   |
| `data/cache/moyu_direct_<resourceId>.json` | 直链解析结果（含失效时间）                                       | 24 小时（直链可能过期，故短）                        |

### 6.3 落盘结构（v3/v4：**不写 `game.json`，也不写游戏目录**）

```
<保存目录>/<包名>/              ← 解压产物（用户自选；重名 → <包名>_2 / _3，⛔ 不覆盖）
<保存目录>/<包名>.zip           ← 原始压缩包（保留；解压只是附赠）
<保存目录>                      ← 默认 <库根>/ChronoTide_Patches
```

- 🔴 `<保存目录>` 由用户在 `PatchDownloadConfirm` 里确认，记忆在 prefs `patch_save_location`。
- 🔴 默认目录**不能**放 `ChronoTide_Cache`（会被缓存清理扫掉，而补丁下完就是成品）。
- ⛔ 没有 `manifest.json`、没有 `.ct_backup`、没有状态机、没有 `recover()` —— 全部属「安装」语义，已取消。
- 下载中的 `.part` 留在同一目录，成功后删除，取消/失败按既有「取消带重试删分片」规则清理。

---

## 7. 分期与验收（每期独立可交付、独立 commit）

### P0 — 技术验证（先证伪，再写业务）

| 编号   | 假设                       | 方法                                                                  | 出口判据                                          | 状态                                                         |
| ---- | ------------------------ | ------------------------------------------------------------------- | --------------------------------------------- | ---------------------------------------------------------- |
| P0-1 | 鲲直链解析器对多类型资源都成立          | 取 10 条不同类型（zip/7z/exe/多资源）实测解析                                      | ≥ 8/10 → 通过；否则直链只做"尽力而为"                      | 🟡 **已跑 9 条 = 6/9 命中；未命中 3 条全是网盘型** ⇒ 达标但需把"网盘型"建模（见 §3.2） |
| P0-2 | 探索库标题 → NextMoe work 命中率 | 取探索库真实标题，跑 `/v2/catalog/search`                                     | ≥ 70% 走 P1；50–70% 加"别名+会社"加权；< 50% 回退关键词入口    | ✅ **24 条实测：解析 100% / 有补丁 92%**（样本偏主流，需扩到 100 条复核）          |
| P0-3 | 2DFan 补丁页选择器稳定           | 抓 5 个作品的 `/subjects/{id}/downloads`                                 | ≥ 4/5 解析出 ≥1 条                                | 🟡 1/1 已验证（9 条），待扩到 5 个                                    |
| P0-4 | 补丁包结构样本足够                | 下载 2–3 个真实补丁，看目录形态（是否嵌套同名目录/是否含 EXE/是否有密码）                          | 定出"预览规则"                                      | ✅ **4 个真实包已采样**（1.2–27.9MB）：4/4 套一层外层目录、4/4 含 exe、0 加密 ⇒ 推翻旧落点方案（§7 P4） |
| P0-5 | 双入口 + 横条不撑破布局            | ① 详情页操作行加「补丁」后是否换行；② 补丁站横条在 1280×720 / 最小窗的落框；③ 探索库顶栏第一行被压窄后搜索框是否可用 | 双尺寸 `takeException() isNull` **且**无压扁、无换行、无残行 | ✅ **渲染探针 102 断言全绿**；v4 面板 1280×720 实测 666×542，算法与渲染逐像素一致 |

**P0 基本完成**：站点可达性 / 字段 / 直链（§3）已验证，包形态已采样（P0-4），布局已探针（P0-5）。
**P0-2 还需扩样**（24 → 100 条含冷门）并做精度抽检 —— 这是唯一还开着的 P0 项。

### P1 — 数据层（纯 Dart，不碰 UI）

1. `lib/models/patch_resource.dart`
2. `lib/services/patch/patch_source.dart`（抽象 + 站点注册表 + 能力矩阵）
3. `lib/services/patch/sources/moyu_patch_source.dart`（列表 + 资源 + 直链解析，全部 `@visibleForTesting` 纯函数出口）
4. `lib/services/patch/sources/two_dfan_patch_source.dart`（检索；复用 `kFanDomains` 常量，**只读不改 SDK**）
5. `lib/services/patch/sources/community_patch_source.dart`（读 `game_resources`）
6. `lib/services/patch/patch_identity_resolver.dart`（标题 → work id，独立缓存）
7. `lib/services/patch/patch_search_service.dart`（并发 + 去重 + 降级 + 限流）

**出口**：`dev_probe/patch_station_probe.dart` 离线夹具全绿 + 一条真网络冒烟；`test/services/patch_station_test.dart` 夹具单测。

### P2 — 补丁站横条 + 双入口（**本轮 UI 重点**，见 §4）

> 🔴 **本节是 v4 口径**（用户 2026-11-10 面评后重定，详见 §4 与 §11）。

1. `lib/widgets/patch_station/patch_station_panel.dart`（`PatchStationPanel` + `show()` Overlay 定位 + **内联游戏库下拉**）
2. `lib/widgets/patch_station/patch_card.dart`（横向卡片，`[查看下载][原页]` 两枚按钮 + 站点图标）
3. `lib/widgets/patch_station/patch_info_sheet.dart`（**「查看下载」三态浮层**：直链 / 网盘 / 网页）
4. `lib/widgets/patch_station/patch_site_logo.dart`（三站图标，CustomPainter 零 assets）
5. `lib/widgets/patch_station/patch_download_confirm.dart`（**下载前确认框**，选目录，替代常驻「保存到」底栏）
6. `lib/widgets/patch_station/patch_station_dark_panel.dart`（**详情页深色锚定栏**，与「资源分享」同外壳）
7. `discover_page.dart`：第一行 `Row` 插「补丁站」按钮（`:1066-1077`）+ `_openPatchStation()`
8. `game_detail_header.dart`：`_buildActionRow()` 在**「分享」与「上传」之间**插「补丁」+ `onPatch`
9. `game_detail_page.dart`：`_handlePatchTap()` → `PatchStationDarkPanel.show(...)`（只加回调，不动既有获取/分享/上传逻辑）

**验收**（每条都要过）：

- 探索库点「补丁站」→ 面板约**半屏宽**（52%，夹 460–700）、右缘贴右、从按钮垂到窗底，**不出屏、不压扁**
- 面板**分两个板块**：上＝搜索栏（内嵌搜索按钮）+ 游戏库选择 + 来源 chip；下＝结果卡
- 搜索栏**内右端**有可点的搜索按钮（不必按 Enter）
- 「从游戏库选择」读**管理器库页的本地游戏**（`LocalGameRegistry`），⛔ 不是探索库 `_allGames`
- 详情页点「补丁」→ 深色锚定栏打开，只出该游戏的补丁
- 每张卡片都标**站点图标** + `[查看下载][原页]`；「查看下载」能看直链 / 网盘（含提取码）/ 网页（费用与积分）三态
- 底栏**没有**常驻「保存到」；点下载才弹确认框，框里选目录
- 三源 chip 计数正确；0 计数源置灰；单源挂掉 → 提示条 + 其余结果照常
- 超长标题 / 8+ 条结果 / 网盘型条目 / 最小窗 —— **四种哨兵数据都要渲染探针**
- `takeException() isNull` **且**无内容被挤压（🔴 只查 exception 会漏掉压扁）

### P3 — 软件内下载

1. `lib/services/patch/patch_download_service.dart` + `patch_download_core.dart`（🔴 **不复用 `DownloadCore`** —— 它会往 `game.json` 塞假条目；自己实现 `.part` 续传 / 进度 / 取消 + 流式 SHA-256）
2. 下载任务接入 `GlobalTaskManager`（复用任务条，**不新建浮层**）

**验收**：断网重连续传；sha256 不匹配必须删包并报错；取消要清干净临时包（对齐既有"取消带重试删分片"规则）。

### P4 — 落盘（解压 → 预览 → 备份 → 应用 → 回滚 → 本地库）

> 🔴 **本节已被 P0-4 实测重写（2026-11-10）**。原方案写的是「统一解到  
> `patch/<补丁名>/`」，实测证明**只对四分之一的包成立**，下面是改后的方案。

#### P0-4 包形态实测（4 个真实包，1.2MB–27.9MB，全部来自鲲直链）

| 样本                   | 外层目录                                          | 包内内容                                                                                                                                     | 形态                       |
| -------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| Humanity 机翻 1.2MB    | `Humanity_CN_@ic`                             | `Humanity_CN_@ic.exe` + `script.dcn`                                                                                                     | **换 exe 型**（补丁自带一份游戏主程序） |
| パニカル Claude 机翻 5.2MB | `パニカル・コンフュージョンclaude-3-5-sonnet-20240620翻译补丁` | `winmm.dll` `LoaderDll.dll` `LocaleEmulator.dll` `FONTCHANGER.dll` `hook.ini` `font.ttf` `configure.exe` `…_CN.exe` `…_CN.bin` `先看我.txt` | **DLL 注入型**              |
| 星織ユメミライ v1.02 17.9MB | `hoshiori_patch_v102`                         | `GameData/Gameexe.dat` `GameData/Scene.pck` `GameData/g00/*` `GameData/koe/*` `update.exe` `update.ini` `★はじめにお読み下さい.txt`                | **覆盖式补丁型**（树结构与游戏本体同构）   |
| 9-nine 樱空汉化 27.9MB   | `【樱空汉化组】9-nine-…Ver1.0`                       | `Setup.exe`（单文件）                                                                                                                         | **自解压安装器型**              |

统计：**4/4 都套了一层外层目录**、**4/4 都含 exe**、0 加密、0 非 UTF-8 文件名。

#### 为什么原方案不成立

| 形态      | 放 `patch/<名>/` 子目录的后果                                 |
| ------- | ----------------------------------------------------- |
| DLL 注入型 | ❌ **补丁不生效** —— `winmm.dll` 靠 DLL 搜索顺序劫持，必须和游戏 exe 同目录 |
| 覆盖式补丁   | ❌ **游戏读不到** —— `GameData/` 必须与游戏根同构                   |
| 换 exe 型 | ⚠️ 能装但没用 —— 用户还得自己把 exe 搬到游戏根                         |
| 自解压安装器  | ✅ 放子目录才对（然后引导用户运行 `Setup.exe`）                        |

⇒ **结论被 v3/v4 改写过两次**：
① 它证明了「⛔ 绝不能自动铺到某个固定目录」；
② 但它**不**意味着软件要替用户判断落点 —— 用户定调「纯下载器」后，最终语义是
**「解到用户自己选的目录，怎么用由用户决定，我们只把包形态和用法提示说清楚」**。
（中间的「隔离区 + 用户指认落点 + 事务安装」版本已作废，见下。）

#### P4 落地清单（A 批已落地；B 批 ⛔ **已取消**）

**P4-A（✅ 已落地 2026-11-10，离线探针 **179** 断言全绿）**

| 文件                                              | 职责                                                                       | 为什么可以现在就做              |
| ----------------------------------------------- | ------------------------------------------------------------------------ | ---------------------- |
| `lib/services/patch/patch_path_guard.dart`      | 路径归一 / zip slip / 盘符 / UNC / 保留名 / **剥唯一外层目录**                           | 纯函数，零 IO               |
| `lib/services/patch/patch_preview.dart`         | 树摘要 → 落点建议（`gameRoot` / `patchSubdir` / `installerOnly` / `blocked`）+ 告警 | 纯函数，零 IO               |
| `lib/services/patch/patch_extract_service.dart` | 解压到 `<库根>/ChronoTide_Cache/patches/<key>/extracted/`                     | 只写**我们自己的缓存目录**，不碰游戏本体 |

实现要点（都是实测逼出来的）：

- **解压用进程内 `package:archive`，不用 7z CLI** —— 本环境匿名管道被系统级占满  
  （`CreateFile failed 231`），`Process.run` / `runSync` 一律抛  
  `ProcessException: 所有的管道范例都在使用中`，CLI 方案**验证不了**。  
  代价：只支持 zip（P0-4 的 4 个样本全是 zip），7z/rar 走**显式降级**（不假装支持）。
- **先校验后落盘**：`decode → validateEntryPaths → 有非法项整包拒绝 → resolveLayout → 才写`。  
  写盘路径只用归一化后的相对路径拼，⛔ 绝不拼 `ArchiveFile.name` 原文。
- **解完再比对**：磁盘上的实际文件集合 == 清单集合，不等就抛错并清理  
  （防"预览说写到 A、实际写到 B"）。
- **失败不留半成品**：`extracted/` 与临时目录一起清，否则下次会把残留叠加进来。
- 进程内实测：伪造一个含 `../../../evil.dll` 的 zip → **整包拒绝**（拒 1 项）、  
  包外未生成文件、解压产物已清理。

**P4-B（⛔ 已取消 —— 2026-11-10 用户定调「补丁站＝纯下载器」）**

> **不再实施，不再等待批准。** 下文仅作历史留档：它是「会写用户游戏目录」的那一批，
> 与新口径直接冲突。补丁的「使用 / 安装」若将来要做，单独立项，不混在补丁站里。
>
> 新口径：下载 → 解压（到用户选定目录旁）→ **完事**。不下发到游戏目录、不备份、不回滚、
> 不代跑 EXE。所以 `patch_install_service` / `patch_library_service` / `patch_preview_sheet`
> 三个文件与 `.ct_backup` 事务**全部作废**（见 §8「已删除 / 已作废」表）。

| 文件（作废） | 原职责 | 为什么作废 |
| --- | --- | --- |
| `lib/services/patch/patch_install_service.dart` | 事务：`.ct_backup/<txId>/` → 逐文件覆盖 → `manifest.json` → 逆序回滚 → `recover()` | 不写游戏目录 |
| `lib/services/patch/patch_library_service.dart` | 扫隔离区与游戏目录 `patch/`，列已装补丁 / 卸载 / 切回备份 | 无「已装」概念，补丁就是用户目录里的文件 |
| `lib/widgets/patch_station/patch_preview_sheet.dart` | 安装前预览：将被覆盖的文件 + 确认 | 无安装步骤；落点提示改由 `patch_preview.dart` 纯函数提供 |

#### P0-4 逼出来的硬约束（已按「纯下载器」改写）

- 🔴 **4/4 含 exe ⇒ 解压后必须点名**「该补丁含可执行文件」；⛔ 不代跑、不代装，由用户自己决定要不要执行
- 🔴 **`*.txt` 说明文件要能直接打开**：3/4 带  
  `先看我.txt` / `★はじめにお読み下さい.txt`，安装顺序与配置要求全在里面
- 🔴 **单文件安装器不代跑**：`Setup.exe` 只提示「这是安装器，需你自己运行」
- 🔴 **外层目录名不可信**：`Humanity_CN_@ic` / `hoshiori_patch_v102` 是作者内部代号，  
  ⛔ 不能当补丁显示名（显示名用站上的 `title`）
- 🔴 **DLL 型补丁要提示落点**：解压后提醒「此补丁需与游戏 exe 同目录才生效」——只提示，不替用户搬文件

**验收**：下载完成后磁盘上的文件集合 = 解压清单；取消 / 失败不留半成品；穿越路径整包拒绝；
含 exe 与说明文件的补丁必须被点名；⛔ 全程不往游戏目录写任何字节。

### P5 — 2DFan 账号下载（**已决策必做，与 P3/P4 并列**）

1. Cookie 存储（走既有凭据存储方式）+ 直链解析 + 积分三态提示。  
   **前置（缺一不可）**：① 用户提供可用 Cookie；② 代理可用（站点在国内网络下不稳）；③ 明确"免费领取 / 积分购买"要不要做。  
   **风险**：账号风险、站点反爬、积分误消费 ⇒ 默认关闭，明确文案"使用你自己的账号与积分"，任何消费动作都要二次确认。

### P6 — 增强（可选）

1. 探索库卡片"有 N 个补丁"徽章（批量 `refs=catalog:`，需先有身份缓存）
2. 补丁更新提示（同一补丁有新版本）
3. 社区补丁上传（把本地补丁发布到 PB，形成自家源闭环）

---

## 8. 改动文件清单（v5 实测版，2026-11-11 00:1x 按磁盘真实内容复核）

### 新增（29 个，全部已落地）

**模型与数据层（16 个）**

| 文件 | 职责 | 期 |
| --- | --- | --- |
| `lib/models/patch_resource.dart` | 三站统一模型 + `PatchDelivery` 三态 + `PatchKind` 归一化 + 大小解析 | P1 |
| `lib/services/patch/patch_source.dart` | `PatchSource` 抽象 / `PatchQueryContext` / 能力矩阵 | P1 |
| `lib/services/patch/patch_identity_matcher.dart` | 标题归一化 + work 匹配 + **置信度**（纯函数） | P1 |
| `lib/services/patch/patch_identity_resolver.dart` | 标题 → work id（30 天磁盘缓存 + `_inFlight` 存 Future） | P1 |
| `lib/services/patch/patch_search_service.dart` | 三源并发 / 去重 / 降级 / 10 分钟内存缓存 | P1 |
| `lib/services/patch/sources/moyu_resource_parser.dart` | 资源页 HTML 双通道解析 + v2 JSON 映射（纯函数） | P1 |
| `lib/services/patch/sources/moyu_query_params.dart` | **纯函数**：v2 查询参数（`nsfw` 为必需参数，漏传即编译错误） | P1 + v5.2 |
| `lib/services/patch/sources/moyu_patch_source.dart` | 鲲（v2 列表 + HTML 直链，并发受限 3/4） | P1 |
| `lib/services/patch/sources/two_dfan_patch_source.dart` | 2DFan（镜像回退 + 2 分钟软冷却；一期只检索，不下文件） | P1 |
| `lib/services/patch/sources/community_patch_source.dart` | 社区 PB `game_resources` | P1 |
| `lib/services/patch/patch_download_core.dart` | **纯逻辑**：文件名清洗 / 字节格式化 / 流式 sha256（零 Flutter 依赖） | P3 |
| `lib/services/patch/patch_download_service.dart` | 下载器：`.part` 续传 / 进度速率 / 取消 / sha256 校验 / 磁盘预检 | P3 |
| `lib/services/patch/patch_save_location.dart` | 保存目录建议 + 记忆 + 可写探测（默认 `<库根>/ChronoTide_Patches`） | P3 |
| `lib/services/patch/patch_path_guard.dart` | 路径归一 / zip slip / 盘符 / UNC / 保留名 / **剥唯一外层目录**（纯函数） | P4-A |
| `lib/services/patch/patch_preview.dart` | 树摘要 → 落点建议（`gameRoot`/`patchSubdir`/`installerOnly`/`blocked`）+ 告警（纯函数） | P4-A |
| `lib/services/patch/patch_extract_service.dart` | 解压到隔离区（进程内 `package:archive`，不用 7z CLI） | P4-A |

**UI（7 个，`lib/widgets/patch_station/`）**

| 文件 | 职责 | 期 |
| --- | --- | --- |
| `patch_station_panel.dart` | **探索库浅色横条**：屏宽 52%（夹 460–700）、右缘贴右、从锚点垂到窗底；上板块＝搜索栏（**内嵌搜索按钮**）+ 游戏库选择 + 来源 chip，下板块＝**两列结果卡网格**；含内联游戏库下拉（定高 30px 行 + 懒加载） | P2 + v4 + v5 |
| `patch_layout.dart` | 网格度量纯函数 `PatchGridMetrics.resolve`：恒等式 `cols × 卡宽 + (cols−1) × gap == innerWidth`，卡宽 ≥ 236、最多 3 列 | v5 |
| `patch_card.dart` | 横向卡片：站点图标 + 站名 + 类型徽章 + 大小 / 标题 2 行 / 适用于·作者·投递形态·下载数 / `[查看下载][原页]`；**另含 `PatchExpandedCard`**（原地展开的外壳，占满整行） | P2 + v4 + v5 |
| `patch_download_details.dart` | **投递详情内容本体**（无窗口外壳）：直链 / 网盘 / 网页三态块 + 说明 + SHA-256 + 动作行 / 进度行；`onDark` 两套取色、`dense` 紧凑排版；**v5.3 起 `links` 全量逐条上屏**（多网盘不再只留第一个）+ 2DFan 积分块 | v5 + v5.3 |
| `patch_delivery_loader.dart` | **展开位加载器**（v5.3）：按需调 `PatchDeliveryService`（鲲/社区同步直出零请求、2DFan 展开才抓）、首帧「正在读取下载方式…」、积分兑换二次确认框、结果回填 + `onDownloadDirect(url)` 回传真实直链 | v5.3 |
| `patch_download_confirm.dart` | **下载确认框**：补丁卡 + 保存位置（可改目录 + 「默认位置」）+ 落点预览（`SelectableText`）+ 体积/空间账 +「只下载，不进游戏目录、不启动游戏」；确认时真写探针验可写 | v4 |
| `patch_station_dark_panel.dart` | **详情页深色锚定栏**：与「资源分享」同一套外壳（`showDarkAnchoredPanel`，宽 600），头 + 来源 chip + 行列表 + 进度；行可就地展开 `PatchDownloadDetails(onDark)` | v4 + v5 |
| `patch_site_logo.dart` | 三站图标：**官方素材优先**（`assetPathOf` → `assets/patch_sites/`）+ `errorBuilder` 静默退回 CustomPainter（饭团 / 鱼 / 气泡）；`onDark` 只影响 painter | v4 + v5 |

**素材（2 个，`assets/patch_sites/`）**

| 文件 | 来源 | 规格 |
| --- | --- | --- |
| `two_dfan.png` | 2DFan 官方 favicon（4 个镜像站同一份 5430B 的 `.ico`，解出 32×32 BMP 转 PNG） | 32×32 / 2190B |
| `kunlun.webp` | 鲲官方 favicon（`https://moyu.moe/favicon.webp`，与 `apple-touch-icon` 同一图） | 256×256 / 10718B |

**探针（5 个，`dev_probe/`）**

| 文件 | 断言数 | 覆盖 |
| --- | --- | --- |
| `patch_station_probe.dart` | **124** | 数据层离线夹具（解析 / 归一化 / 去重 / 降级） |
| `patch_ui_probe.dart` | **140** | A 按钮不换行 / B 面板几何 / C 卡片三态 / C2 下载五态 / D 全量面板 / E 深色浮层 / **E2 贴按钮下方 3 条** / F 详情内容三态 / G 图标 / **G2 素材槽位** / H 默认目录 / I 下拉双尺寸 / **J 两列恒等式三尺寸** / **K 原地展开** / **L 关键词检索问到鲲** |
| `patch_download_probe.dart` | **23** | 文件名清洗 / 字节格式化 / 流式 sha256 已知向量 |
| `patch_install_probe.dart` | **179** | 落盘护栏：穿越包拦截 / 外壳剥离 / 解压清单比对 |
| `patch_archive_probe.dart` | — | 容器与解压形态验证 |

### 已删除 / 已作废（与 v2/v3 的差异，别按老文档找文件）

| 曾计划 | 现状 | 原因 |
| --- | --- | --- |
| `patch_info_sheet.dart` | ⛔ **v5 已删除**（文件不在仓内） | 用户要求「查看下载」**原地展开、不另开窗** ⇒ 拆成 `patch_download_details.dart`（内容）+ `patch_card.dart` 里的 `PatchExpandedCard`（外壳） |
| `patch_detail_sheet.dart` | ⛔ 同上（先改名 `patch_info_sheet`，再整体删除） | 「查看下载」承载三态投递详情，语义早已不是「说明浮层」 |
| `patch_game_picker.dart` | **不建独立文件**，改 `patch_station_panel.dart` 内联下拉 | 下拉只要一个筛选框 + 列表，独立文件多一层回调；高度还需由面板反推，同文件更稳 |
| `patch_save_dir_dialog.dart` | ⛔ **已删除**，改 `patch_download_confirm.dart` | 与「下载游戏本体」同构：**下载前弹确认框选目录**，不要常驻「保存到」底栏 |
| `patch_install_service.dart` | ⛔ 取消 | v3 定调**纯下载器**，不写游戏目录 |
| `patch_library_service.dart` | ⛔ 取消 | 同上（本地补丁＝用户自选目录里的文件，不需要登记表） |
| `patch_preview_sheet.dart` | ⛔ 取消 | 无安装步骤 ⇒ 无「应用前预览」；`patch_preview.dart` 保留为**落点提示**纯函数 |
| `.ct_backup` 事务 / 覆盖哈希比对 / 逆序回滚 | ⛔ 取消 | 全部属「安装」语义 |
| `test/services/patch/*` | 未建 | `analyze`/`test` 恒挂 231；验证全部走 `dev_probe` 纯 Dart + `flutter_tester`（见 §11） |

### 修改（4 个，均为最小插入）

| 文件 | 改什么 | 期 |
| --- | --- | --- |
| `lib/pages/discover_page.dart` | **①** 第一行 `Row`（`:1066-1077`）插「补丁站」按钮 + `_openPatchStation()`<br>**②** 新增 `_patchStationButtonKey`（`GlobalKey`，给 Overlay 定位）<br>⛔ 不动 `_performFilter` / 筛选 / 卡片网格 / `_allGames` | P2 |
| `lib/widgets/game_detail/game_detail_header.dart` | `_buildActionRow()`（`:213-271`）在**「分享」与「上传」之间**插「补丁」（中性灰描边），新增 `onPatch` + `patchButtonKey` | P2 |
| `lib/pages/game_detail_page.dart` | 透传 `_handlePatchTap()` → `PatchStationDarkPanel.show(...)`；`_patchAnchorRect()` 优先取**补丁按钮自己的矩形**，拿不到退回整条操作行 | P2 + v4 |
| `pubspec.yaml` | `assets:` 下加一行 `- assets/patch_sites/`（⚠️ 只声明素材目录，**不新增任何依赖**） | v5 |

> 「补丁」按钮与探索库「补丁站」按钮**共用同一份数据、同一个 `PatchDownloadDetails`、同一条下载链路**，只是外壳不同（浅色横条 vs 深色锚定栏）。

### 明确不改（红线）

`lib/main.dart`、`lib/main_container.dart`、`lib/theme/`、`lib/core/portable_*.dart`、`lib/services/app_state.dart`、`windows/runner/`、`lib/packages/luna_metadata_sdk/`（**只 import 常量**）、`pubspec.yaml`（不新增依赖）、`lib/services/download_core.dart`（只调用）、`lib/services/game_data_format.dart`、`lib/services/extract_manager.dart`（只调用）。

**v2 / v4 追加**：

- `discover_page.dart` 的 `_performFilter` / `_selectedTags` / `_selectedDevelopers` / `_buildGameGrid` / 顶栏第二行筛选按钮 —— **一格不动**，只在第一行 `Row` 里插一个按钮 + 一个回调
- `game_detail_header.dart` 的「获取 / 分享 / 上传 / ▏ / ♡ / 外跳 / 💬」既有顺序与配色 —— **不动**，只插一个按钮
- `library_page.dart`（库页）、大厅、`explore_hall` 相关 —— **完全不碰**（只服务探索库）
- `tags_popup_menu.dart` —— **不改造**，补丁站横条另建 Overlay（它绑死了标签数据结构）
- 🔴 v4 起「游戏库选择」读 `LocalGameRegistry`（**管理器库页**那一批本地游戏），⛔ 不再从探索库 `_allGames` 取 —— 因此 `discover_page.dart` 连 `_allGames` 都不用碰
- 🔴 v5 更正：API 是 `LocalGameRegistry.instance.allGames`（不是 `gamesMap`），与 `library_page.dart:1841` **逐字符同源**；v4 文档里的 `gamesMap` 写法已作废

---

## 9. 风险登记

| 级别     | 风险                                                  | 应对                                                                             |
| ------ | --------------------------------------------------- | ------------------------------------------------------------------------------ |
| **P0** | ~~标题 → work 命中率未知~~ **已解除**：24 条实测解析 100% / 有补丁 92% | 仍需扩样到 100 条（含冷门）并做精度抽检（防"同系列串味"）；串味则加会社/发售年二次校验                                |
| **P0** | **约 1/3 的鲲补丁是网盘型（夸克/百度），无法软件内直下**                   | 建模为 `PatchDelivery.netdisk`：展示分享链接 + 提取码 + 一键复制；UI 文案不承诺"能下"。⛔ 不做网盘登录/抓取       |
| **P0** | 鲲直链是 HTML 解析，站点改版即失效                                | 解析失败一律降级跳转；直链缓存 24h；不把下载做成唯一路径                                                 |
| **P0** | ~~应用补丁 = 覆盖用户游戏文件，打错就坏档~~ **已解除**：v3 定调纯下载器，**根本不写游戏目录** | 不再安装 ⇒ 无覆盖风险。P4-A 只写我们自己的隔离区，且逐条校验路径安全 |
| **P1** | 2DFan 需要账号/积分，处理不当会动用户资产                            | P5 单独批准，默认关闭，只读预览 + 明确提示，不自动消费                                                 |
| **P1** | 补丁包里有 EXE，诱导用户运行                                    | 只登记不代跑；EXE 只能"打开所在文件夹 + 用户自己装"                                                 |
| **P1** | 补丁带恶意文件/路径穿越                                        | 移植 `patches.rs` 的 `relative()`/`target()` 全套校验；单文件 ≤128 MiB、总数 ≤10000、总 ≤1 GiB |
| **P1** | NextMoe 配额 60/分                                     | 走 `executeRateLimited`；只在详情页按需查询，不做全屏预热（徽章留到 P6）                               |
| **P1** | 详情页操作行 `Wrap` 加第 3 个主按钮后换行，破坏设计稿对称                  | `Wrap` 可换行但视觉会断 ⇒ P0-5 实测 480px 是否还在单行；最小窗下允许换行但必须 `runSpacing: 8` 自然折         |
| **P1** | 补丁站横条尺寸写死 → 小窗被裁 / 大窗空荡                             | 尺寸全部由 `MediaQuery` 可用空间**反推**（§4.4.2）；出屏翻转 + 左右 clamp；双尺寸探针                    |
| **P1** | 鲲 / NextMoe 数据同源导致同一补丁出现两遍                          | 聚合层去重键 `sha256 > 直链路径 > 站内 id`，重复优先保留 NextMoe 条目（§4.1）                         |
| **P2** | 与 `KungalLinkService` 重复请求同一 work                   | 一期各自缓存；P6 再抽公共 resolver（旧方案 P2 风险，结论不变）                                        |
| **P2** | 内容分级                                                | 沿用现有 `nsfw` 开关与 NSFW 检测；补丁列表按 `content_limit` 过滤                               |

---

## 11. 进度与下一步

**总览（截至 2026-11-13 16:0x）**

| # | 项 | 状态 |
| --- | --- | --- |
| 1 | P0-1 直链解析（9 条样本 6 命中，3 条网盘型） | ✅ |
| 2 | P0-2 命中率（24 条 → 解析 100% / 有补丁 92% / 召回 99 条） | ✅ 待扩样到 100 条 |
| 3 | P0-4 包形态采样（4 个真实包，1.2–27.9MB） | ✅ 推翻旧落点方案 |
| 4 | P0-5 双入口布局探针 | ✅ 不换行、不压扁 |
| 5 | P1 数据层（15 文件） | ✅ 0 error，离线探针 **124** |
| 6 | P2 双入口 + 横条 | ✅ |
| 7 | P3 软件内下载（续传 / 校验 / 取消） | ✅ 探针 **23** |
| 8 | P4-A 路径护栏 + 落点预览 + 隔离区解压 | ✅ 探针 **179** |
| 9 | **v4 UI 全面返工（用户面评 8 条）** | ✅ 渲染探针 **102** |
| 10 | **v5 二次面评（5 条：两列 / 库页语义 / 真素材 / 原地展开 / 崩溃）** | ✅ 渲染探针 **132** |
| 11 | **v5.1 三次面评（1 条：深色栏必须挂在按钮下方）** | ✅ 渲染探针 **135** |
| 12 | **v5.2 数据面（鲲搜不到：`nsfw` 没传 + 全局检索跳过身份解析）** | ✅ 模型探针 **144** / 渲染探针 **140** |
| 13 | 静态分析（`lib/services/patch/**` + `lib/widgets/patch_station/**` + `patch_resource.dart`） | ✅ **0 error 0 warning 0 info** |
| 14 | **v5.3 功能面（2DFan 账号/积分兑换 + 直链软件内下载 + 多网盘全量展示）** | ✅ 模型探针 **182** / 渲染探针 **149**；⏳ 真实兑换待用户点 |
| 15 | **v5.4 语义回归（「从库中选择」误用探索库云端列表）** | ✅ 模型探针 **188** / 渲染探针全绿；⏳ 真机看本地封面与计数 |
| — | ~~P4-B 安装事务 / 本地库 / 预览浮层~~ | ⛔ **v3 已取消，见下** |

### ⛔ P4-B 为什么取消（改口径，不是砍需求）

用户 2026-11-10 定调：

> 补丁站是**单纯的下载补丁**，不直接立即使用该补丁，就类似于下载游戏一样……这些都是用户自己选择路径，
> 我们的软件可以帮忙下载解压，但不在立刻使用。下载解压完成之后，这个下载好的补丁包就老老实实放在
> 用户自己选的路径中就行。

⇒ 原 P4-B 的三个文件（`patch_install_service.dart` / `patch_library_service.dart` /
`patch_preview_sheet.dart`）**全部作废**，`.ct_backup` 事务、覆盖哈希比对、逆序回滚、
启动 `recover()` 随之取消。P4-A 的三个文件保留（仍要解压、仍要防穿越），但语义从「安装前置」
变成**「下载后的顺手解压」**。补丁「使用」以后单独立项。

### v4 UI 返工清单（22:5x–23:0x，用户逐条面评后重做）

| # | 用户原话要点 | 落地 |
| --- | --- | --- |
| 1 | 面板不要铺满整个界面，约二分之一 | `_widthRatio = 0.52`（夹 460–700），右缘贴窗口右，从锚点垂到窗底 —— 1280×720 实测 **666×542** |
| 2 | 搜索栏最右侧要有搜索按钮（别只靠 Enter） | `_buildSearchRow()` 把 `_searchButton()` **嵌进输入框内右端**（实心 accentCyan「搜索」），外部只留 ↻ / ✕ |
| 3 | 「游戏库选择」指管理器库页的本地游戏 | `_games()` 改读 `LocalGameRegistry.instance.gamesMap`；`gamePicker` 仅留作探针注入点 |
| 4 | 面板分上下两个板块（对齐 GalGear） | `_buildHeaderBlock()`（`buttonBackground` 底 + 下缘分隔线）/ `Expanded(_buildResultArea())`（`background` 底） |
| 5 | 要有「查看下载」，能在软件内看到下载信息 | 新增 `PatchInfoSheet`：直链块 / 网盘块（含提取码）/ 网页块（2DFan 写「本次费用 / 账号积分 = 登录后可见」）+ 底栏动作 |
| 6 | 底栏「保存到」删掉，下载前弹确认框选目录 | 删 `_buildSaveFooter()`；新增 `PatchDownloadConfirm`，确认后 `PatchSaveLocation.set(dir)` 再下载 |
| 7 | 卡片要标站点图标（2DFan 小饭团、鲲也有） | `PatchSiteLogo`：饭团 / 鱼 / 气泡三枚 CustomPainter，**零 assets**，10–34px 六档都验过 |
| 8 | 详情页补丁面板做成旁边「官方下载 / 用户分享」那样的深色面板 | 新增 `PatchStationDarkPanel`（`showDarkAnchoredPanel`，宽 600），锚点用补丁按钮自己的矩形 |

### v5 UI 返工清单（2026-11-10 23:3x–2026-11-11 00:1x，二次面评 5 条）

| # | 用户原话要点 | 落地 |
| --- | --- | --- |
| 1 | 结果排成一列、左右大片空白，「直接给它做成两排」 | 新增 `patch_layout.dart`（`PatchGridMetrics.resolve` 纯函数）；`_buildGrid` 改 `LayoutBuilder` 取真实可用宽 ⇒ 恒等式 `cols × 卡宽 + (cols−1) × 10 == innerWidth`。三档实测 **2 列**：1080→262.2 / 1280→314.2 / 1440→331.4 |
| 2 | 「从游戏库选择」= **库页**的本地库，不是探索库 | `_games()` 改读 `LocalGameRegistry.instance.allGames`（与 `library_page.dart` 同源）+ `PatchGameRef.coverPath` 缩略图 + `_gamesCache` 缓存 + `invalidateGames()` |
| 3 | 2DFan / 鲲 的图标要用**真素材** | 新增 `assets/patch_sites/{two_dfan.png, kunlun.webp}`（官方 favicon 原件）+ pubspec 声明；`PatchSiteLogo.assetPathOf()` 素材优先、`errorBuilder` 静默退回 painter |
| 4 | 「查看下载」不许另开窗，卡片**往右展开**、右边的卡往下排 | 删 `patch_info_sheet.dart`；新增 `PatchDownloadDetails`（内容本体）+ `PatchExpandedCard`（外壳）；展开项宽 = 整行 ⇒ `Wrap` 天然独占一行。深色详情页同款就地展开 |
| 5 | 从游戏库选完按 ENTER / 点搜索会**卡死崩溃**，去看日志 | 见下「崩溃排查」；代码侧三处加固 |

### 崩溃排查（2026-11-10 23:31 / 23:36 两份 minidump）

手写 Python 解析 `MDMP`（ThreadList/ModuleList/Exception 三个 stream）：

| 项 | 结论 |
| --- | --- |
| 异常码 | `0xC000001D` `EXCEPTION_ILLEGAL_INSTRUCTION`（**不是** Dart 异常，是原生层执行了非法指令） |
| 崩溃点 | `flutter_windows.dll + 0x5A9918`，落在 `.text` 段，非 `ud2` 陷阱 |
| 可见性 | ⛔ 该 DLL 经 **UPX 压缩**（节名 `UPX0/UPX1/UPX2`，6.78MB vs 原件 45MB）⇒ RVA≠磁盘偏移，**出不了符号**，无法定位到具体函数 |

⇒ 无法从 dump 定位，改从调用链侧收口（用户描述的触发路径非常明确：
「从游戏库选中 → 直接 ENTER / 直点搜索」）：

| # | 隐患 | 修法 |
| --- | --- | --- |
| 1 | `onSubmitted` 回调里**同步**发起网络请求 + 改路由 ⇒ 在输入法/IME 提交帧内重入 build | 全部转 `WidgetsBinding.instance.addPostFrameCallback` |
| 2 | `setState` 回调里改 `TextEditingController.text` 会同步触发 listener ⇒ 再次 `setState`（重入） | controller 赋值与 `_query` 挪到 `setState` **之后** |
| 3 | 回车 + 点按钮可并发送出两次检索 | 加单飞闸 `bool _searching`，`finally` 里按 `_runId` 归位 |

### 探针汇总（全部绿）

| 探针 | 断言 | 结果 |
| --- | --- | --- |
| `patch_station_probe.dart` | **144** | ✅ 0 失败 |
| `patch_install_probe.dart` | 179 | ✅ 0 失败 |
| `patch_ui_probe.dart` | **140** | ✅ 0 失败 |
| `patch_download_probe.dart` | 23 | ✅ 0 失败 |

`patch_ui_probe` 分段：A 按钮不换行 ×5 尺寸 / B 面板几何 ×4 场景 ×3 值 / C 卡片三态 ×9 /
C2 下载五态 ×10 + 2 文案 / D 全量面板 ×11 / E 深色浮层 ×5 / F 详情内容三态 ×10 /
G 图标 3 站 ×6 尺寸 = 18 / **G2 素材槽位 ×5** / H 默认目录 ×2 /
**I 游戏库下拉 ×6**（1280×720 与 800×600 双尺寸）/
**J 两列恒等式 ×12**（1080/1280/1440）/ **K 原地展开 ×10** /
**L 关键词检索是否问到鲲 ×5**（v5.2）。

`patch_station_probe` 新增两段（v5.2）：`MoyuQueryParams` ×8（`nsfw` 必须出现且取值为
`true`/`false`、resources 不带 nsfw）/ `PatchIdentity · 关键词检索门禁` ×12
（`kw:` 缓存键、`isConfident` 采信门槛、用真实 `catalog/search` 响应形状跑一遍）。

> 🔴 v5 修探针自己的两个坑：① J/K 段原来用 `_expectedMetrics().width − 24` 当 `inner`，
> 漏扣面板 `Border.all(1.6)` ⇒ 三个尺寸**恒差 3.2px**，改成 `_panelInnerWidth()` 后逐像素相等；
> ② I 段「下拉可展开」原来写 `t == '筛选本地游戏库…'` 全等，提示语加长后假失败 ⇒ 改 `contains`。

**v4 面板几何实测（1280×720）**

| 项 | 实测 |
| --- | --- |
| 面板宽 | **666**（= 1280 × 0.52，占屏 52%） |
| 面板高 | **542**（锚点下沿 → 窗口底 − 16） |
| 右缘 | 贴窗口右 − 16（与顶栏「发布上传」视觉对齐） |
| 算法 vs 渲染 | 665.6 × 542.0 ⇒ **逐像素一致** |

**P0-5 渲染探针实测结果（全绿）**

| 项 | 实测 |
| --- | --- |
| 详情页操作行换行 | 1280 / 1248 / 1180 / 1080 / 1000 宽下 `Wrap` 高**恒为 38**（= 单行）⇒ 不换行 |
| 「补丁」按钮 | x=330，宽 84.5（与「分享」82 同量级） |
| 补丁卡片三态 × 宽 250/300/528 | **0 溢出** |

### 实测中挖出并修掉的真 bug（都进探针做回归）

1. `PatchKind.fromRaw('ai')` 识别失败 —— 裸 `ai` 是鲲的合法 type 值；`contains('ai')` 会误伤 `detail`/`available` ⇒ 改词边界匹配
2. `kinds` 可能为空 ⇒ UI `kinds.first` 抛 `Bad state: No element` ⇒ mapper 兜底 `[other]`
3. 网盘多链接按 URL 字典序排 ⇒ 百度排在夸克前，与页面顺序不符 ⇒ 改「保持原始顺序 + 直链优先」
4. `R18补丁` 被归成「分级」⇒ 拆成 `r18`（显示 R18）/ `allAges`（显示 全年龄）
5. 🔴 **面板关闭后 `postFrameCallback` 仍 `setState`** ⇒ `setState() called after dispose()`。修法：`_runSearch` 与 postFrameCallback 双处 `mounted` 早退
6. 🔴 **`clamp(lo, hi)` 在 `hi < lo` 时抛 `ArgumentError`**（不是返回边界值）。`MediaQuery` 未就绪（0×0）或窗口极矮时直接崩在 build 里 ⇒ 新增 `_clampSafe`
7. 🔴 **`pop()` 后立刻 `push()` 会让路由栈「一边退一边进」** ⇒ `PatchInfoSheet` 点下载后新窗被上一层的退场动画一起带走。修法：`addPostFrameCallback` 等这一帧结束
8. 🔴 **去重键会把不同补丁判成同一份**（探针假数据三者全同）⇒ 生产语义正确（同文件合并），但 §D 探针必须让 `sha256`/`directUrl`/`key` 各自唯一，否则测的是去重不是渲染
9. 🔴 **`MaterialApp` 的 Element 被复用 ⇒ 上次的 `OverlayEntry` 还挂在树上** ⇒ `PatchStationPanel.show()` 必须在插入新 entry 前**主动移除同 anchor 的旧 entry**（靠 `_activeEntry` 单例 + `remove()`），改动这块必须回归 D1–D4
10. 🔴 **游戏库下拉在矮面板下 `RenderFlex overflow`** ⇒ 下拉不参与 Column 分配、高度可变。修法：`(metrics.height - 166).clamp(96, 190)` 反推列表上限，并把 `metrics` 传进 `_buildHeaderBlock`

**P3 外部接口实测**

| 项 | 结果 |
| --- | --- |
| `dl.imoe.uk` 是否支持 Range | ✅ `Accept-Ranges: bytes`，Range 请求返回 **206** 且字节正确 |
| `Content-Length` | ✅ 有（134380932） |
| 续传拼接正确性 | ✅ 一次下 4MB vs「2MB + 续传 2MB」拼接，**sha256 完全相同** |
| 流式 sha256 | ✅ 空文件 / `"abc"` 已知向量 / 3MB 多分块 全部正确 |

**探针可运行前置（缺一必挂）**

1. 必须手工 `ThemeRegistry.registerBuiltinThemes()` —— 探针不跑 `main.dart`，否则 `AppThemeManager.current` 空指针
2. 屏幕尺寸只能用 `MaterialApp.builder` 包一层 `MediaQuery` 注入 —— `binding.setSurfaceSize` 只改渲染边界，`MediaQuery.sizeOf` 读不到
3. ⛔ `binding.runAsync` / `Future.delayed` 在 `flutter_tester` 下**永久挂起** ⇒ 异步数据一律「先挂载、后注入」
4. ⛔ `binding.handlePointerEvent(...)` 返回 `void`，**不能 await**（会编译错）

### 下一步（按顺序）

1. **真机走查**（tester 里已全绿，但真机仍是唯一验收标准）：双入口、52% 几何、**两列铺满**、
   **原地展开（右边的卡是否真的往下排）**、三态详情、确认框选目录、**从游戏库选中后按 ENTER 不再崩**
2. **P0-2 扩样**：100 条（含末页冷门）+ 精度抽检（纯只读，可随时插做）
3. **补全 P4-A 容器覆盖**：7z/rar 解压路径（需真实 7z/rar 样本才能验）
4. 等用户给 2DFan Cookie（P5 前置）
5. ~~等批准 P4-B~~ —— **已取消**，不再等

---

## 附：本轮诚实声明

- ✅ 已完成：旧计划核查、GalGear 三个核心文件通读（`providers.rs` / `patches.rs` / `patches/downloads.rs` / `patches/folders.rs` / `ui/patches.rs` / `fan_account.rs` 片段）、三站可达性与字段实测、鲲直链实测可下、项目侧基础设施盘点（DownloadCore / ExtractManager / 安装中心 / 字体补丁事务 / 7z 内置）、**P0-1 与 P0-2 实测**
- ✅ **v2 UI 侧已读码定位**：`discover_page.dart:1066-1077`（顶栏第一行 Row）、`discover_page.dart:85`（`_allGames`）、`tags_popup_menu.dart:77-115/219-230/249-251`（Overlay 定位与尺寸范式）、`game_detail_header.dart:213-271`（`_buildActionRow` + `Wrap` 换行风险）、`game_detail_header.dart:308+`（`_buildPrimary` 可复用）
- ❌ 未做：任何业务代码；`analyze` / `test` 未跑（无改动）；补丁包形态未采样（P0-4）；渲染探针未做（P0-5）；命中率未扩样到 100 条；**面板视觉稿未出**（§4 给的是规格，不是像素稿，落地前建议先跑渲染探针把尺寸定死）
- ⚠️ 工作区现状：`apps/chrono-tide` 有 **47 个文件未提交改动**（上一轮 `discover_install_and_download_fixes` 等），本轮**不碰、不提交**，避免混入
- ⚠️ 探针脚本是临时文件（已删），数据结论已固化在本文 §3.2，可据此复现
- ⚠️ **口述与实测的差异已标注**：用户说的「Kunlun」按 `www.moyu.moe`（鲲站）理解，「Next」按 `api.nextmoe.dev`（NextMoe）理解 —— 两者**数据同源**，已在 §4.1 用去重方案处理；若你的本意不是这样（比如「Kunlun」指另一个独立站），请直接纠正，那 §4.1 与 P1 的源实现要改

**v4 追加（2026-11-10 23:0x，UI 返工后）**

- ✅ 本轮真做了：6 个 widget 文件（3 新增 / 2 重写 / 1 删除）、`game_detail_page.dart` 切深色浮层、
  `patch_ui_probe` 扩到 **102 断言**、文档 §4 / §7 / §8 / §9 / §11 **全量同步到 v4**
- ✅ 静态分析：`lib/services/patch/**` + `lib/widgets/patch_station/**` + `patch_resource.dart`
  **0 error 0 warning 0 info**
- ✅ 验证手段的诚实边界：`analyze` / `test` 恒挂 231 ⇒ 静态检查走进程内探针（会漏 lint）；
  UI 只经 `flutter_tester` 验证，**真机尚未走查**
- ⚠️ 仍未做：真机走查、P0-2 扩样、7z/rar 容器、2DFan Cookie（P5）
- ⚠️ 上面那条「❌ 未做……面板视觉稿未出」是 **v1 当时**的记录，v4 已全部落地，保留仅为追溯
- ⚠️ 仍未提交：补丁站这块改动尚未 `git add`（仓库里另积着 40+ 个上轮未提交文件，按规矩不混入）

**v5 追加（2026-11-11 00:1x，二次面评后）**

- ✅ 本轮真做了：新增 `patch_layout.dart` + `patch_download_details.dart`，删除 `patch_info_sheet.dart`；
  `patch_card.dart` 加 `PatchExpandedCard`；`patch_station_panel.dart` 改两列 + 原地展开 + 库页数据源 +
  崩溃三条加固；`patch_station_dark_panel.dart` 改就地展开；`patch_site_logo.dart` 改素材优先；
  新增 `assets/patch_sites/` 两颗官方图标 + pubspec 声明
- ✅ 探针：`patch_ui_probe` **102 → 132 → 135 断言全绿**（新增 G2 ×5 / J ×12 / K ×10 / E2 ×3，删 F 三条标题断言）
- ✅ 离线回归：`patch_station_probe` 124 / `patch_install_probe` 179 / `patch_download_probe` 23 —— 全绿
- ✅ 静态分析：`lib/widgets/patch_station/**` 7 文件 **0/0/0**（探针仅剩 2 条 `@visibleForTesting` 预期告警）
- ⚠️ 崩溃**没有拿到符号级证据**：两份 minidump 都指向 `flutter_windows.dll` 的 UPX 压缩段，
  只能从调用链收口（`addPostFrameCallback` / 控制器赋值移出 `setState` / 单飞闸）。
  ⇒ **真机复现一次才算修完**，下次崩了请把 `data/crash/*.dmp` 一起留下
- ⚠️ 上面 bug 清单第 7 条提到的 `PatchInfoSheet` **已不存在**，该条仅作历史留痕
- ⚠️ 2DFan 素材只有官方 32×32（4 个镜像站同一份），需要更清晰的原图请覆盖 `assets/patch_sites/two_dfan.png`
- ⚠️ 仍未提交：同 v4，补丁站改动整体还没 `git add`
