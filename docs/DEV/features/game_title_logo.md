# 游戏标题图（Title Logo）—— 主页 / BPM 主页大标题的两种形态

> 状态：**已收尾（Phase 3，2026-10-17）**：自动抓取（Steam CDN + SteamGridDB 双源，
> 零密钥覆盖 70%）+ 两处渲染 + 设置页 Key 配置全部接通。
> **无手动入口、无服务端代查、Key 由用户自填且纯可选**（三条都由用户拍板，见 §2.4）。
> 真实端到端走查**待环境恢复**（见 §7）。
> 关键词：大标题、透明 logo、clear logo、Playnite 同款、`logo_file`、`title_logo.png`、
> SteamGridDB、`sgdb_api_key`

---

## 1. 要解决什么

用户拿 Playnite 全屏主题截图提问：为什么那边的大标题是「艺术字」，而我们是「加粗大字」。

结论（已核实，不是推测）：Playnite 的大标题有**两种形态**，第二种靠的不是把文字渲染得更大，
而是游戏对象上一个**独立的 `Logo` 字段** —— 一张厂商绘制、**透明背景**的艺术字 PNG。
主题里 `Logo` 有值就贴图，没有就回退 `Name` 文字。

所以我们复刻的也是这件事：**多一个"标题图"资产维度**，不是改字体/字号。

---

## 2. 数据从哪来（已实测）

### 2.1 我们不提供 logo 的源

- **NextMoe 目录**：`works/{id}?include=` 白名单实测为
  `titles, refs, relations, credits, releases, popularity, ratings, tags, playtimes,
  series, platforms, intros, covers, screenshots, characters, companies, engines, links`
  —— **没有 logo 项**；`covers[].cover_kind` 只有 `main / pkgfront / pkgcontent`。

### 2.2 我们用的源：Steam 官方 CDN（零密钥）

```
NextMoe 搜索(work) → 锚点解析 → https://cdn.akamai.steamstatic.com/steam/apps/<appid>/logo.png
```

**关键：锚点要读 `refs`，不能只读搜索结果里的 `sources`。** 两者不一致 ——
`sources` 是搜索接口的简化视图，**经常缺项甚至为空**；作品详情
`GET /catalog/works/{id}?include=refs` 里的 `refs[source=steam].external_id`
才是完整映射。实测（`.workbuddy/probe_game_logo/`，2026-10-17）：

| 游戏 | `sources` | `refs` | 结果 |
|---|---|---|---|
| `Clover Day's` | 空 | `2430690` | ✅ 从无到有 |
| `Fate/stay night` | 空 | `2396980` | ✅ 从无到有 |
| `Summer Pockets` | `3418570`（无图） | 补 `897220` | ✅ 新增命中 |

**并且必须遍历全部候选 appid**，不能只取第一个：一个作品常挂多个 steam 锚点，
首个往往是 DLC / 试玩 / 旧包，CDN 上没有 `logo.png`。
实测 `Making*Lovers` 3143290(404)→2093420(200)、`Dies irae` 644540(404)→1011990(200)。

两级合起来的真实覆盖率（`.workbuddy/probe_game_logo/probe_coverage_new_logic.py`）：

| 口径 | 命中 |
|---|---|
| 旧：仅 `sources` 首锚点 | 11/20（55%） |
| 新：`sources`+`refs` 遍历 | **14/20（70%）** |

AOKANA（appid 1044620）= `640×167`，与用户截图里那张是同一资产（连副标题都在图里）。

缺口 6/20 分两类，**都不是"再换个源"能解决的**：
- **素材本身不存在**：`サクラノ詩` / `WHITE ALBUM2` / `Muv-Luv` 的主条目 ——
  appid 在，但 Steam 上就没上传 `logo.png`（`logo_2x` / `logo_3x` 也一并 404 过，
  所以**不要**在代码里加多尺寸兜底，实测零收益）。
- **不是单个作品**：`灰色系列` 是系列名，本来就不该有单张标题图。

⚠️ 匿名的边界（2026-10-17 实测）：`store.steampowered.com`、`api.steampowered.com`
在本机网络**不可达（000）**，`steamspy` 403，`api.bgm.tv` / `query.wikidata.org` 不可达。
VNDB 官方 API（`api.vndb.org/kana`）匿名可用但 `extlinks` **不含 Steam**。
所以「用商店搜索/外部库反查 appid」这条路在国内网络下走不通，
NextMoe 的 `refs` 是唯一稳定可靠的 appid 来源。

### 2.3 第二源：SteamGridDB（补前一级的缺口）

前一级失手（无 appid / 该 appid 没上传 logo.png）才走这里。API 规格取自官方
OpenAPI（`https://www.steamgriddb.com/static/openapi.yml`，v2.10.0，已实测鉴权头为
`Authorization: Bearer <key>`，无 key 返回 `401 {"errors":["Authentication Required"]}`）：

| 步骤 | 端点 | 说明 |
|---|---|---|
| 有 appid | `GET /games/steam/{appid}` → `data.id` | 精确映射，优先 |
| 无 appid | `GET /search/autocomplete/{term}` | 只接受**归一化全等且唯一**（与 2.2 同款纪律） |
| 取图 | `GET /logos/game/{id}?mimes=image/png&types=static&nsfw=false&humor=false&limit=50` | 候选按 `official → white → black → custom`、同档按 `score` 降序 |

最多试 6 个候选（`_sgdbMaxCandidates`），每个都要过 `normalizeLogoPng`
（尺寸下限 / 宽扁比例 / 非全幅不透明 / 裁透明边），第一张合格的才算命中。

🔴 只取 `mimes=image/png`：下游只认 PNG 魔数，webp 会被判成坏图。
🔴 `width` / `height` 在 OpenAPI 里**没写进 logo 的 schema**（文档复用了 Grid schema），
代码按"可能缺省"处理：缺省就不做比例预筛，交给 `normalizeLogoPng` 兜底。

### 2.4 Key 从哪来（用户侧操作，1 分钟，免费）

1. 打开 <https://www.steamgriddb.com/> ，用 **Steam 账号登录**（无需单独注册）；
2. 进 <https://www.steamgriddb.com/profile/preferences/api> ；
3. 点 **Generate API Key**，复制生成的 **32 位**字符串；
4. 设置 → 网络与存储 → 「大标题素材」→ 粘贴 → **保存** → **验证**。

落点：`SharedPreferences['sgdb_api_key']`（**只存本机**，不上传任何服务器）。
保存后调 `GameTitleLogoService.onSgdbKeyChanged()`，它**同时清掉 7 天负缓存** ——
否则用户刚填好 Key 却要等一周才生效，会以为"填了没用"。

🔴 Key 是**个人凭据**，不内置共用 Key：既违反其条款，也会让所有用户共用同一个限流额度。
**没有 Key 时这一级静默跳过**，行为与只有 Steam CDN 时完全一致。

#### 为什么不能内置一个 Key / 不能匿名

用户问过"能不能访客匿名、一定要我去拿 Key 吗"。三个方向都实测过：

| 方向 | 结论 | 依据 |
|---|---|---|
| 匿名调 SteamGridDB | ❌ 不行 | `/search/*`、`/logos/game/*` 无 key 一律 `401 Authentication Required`；它的图片 CDN 用内容哈希做文件名，**不通过 API 就拿不到哈希**，所以连直链都绕不过 |
| 内置一个共用 Key | ❌ 不行 | ① 本项目**有开源目录**（`chrono-tide-opensource/`），Key 写进代码即等于公开泄露，会立刻被撤销；② 所有用户共用同一限流额度，一个人刷崩全体；③ 被封后用户没有自己的 Key 可换，等于永久失效 |
| 找别的匿名字典源 | ❌ 走不通 | 见 2.2 末尾：Steam 商店 / WebAPI / Bangumi / Wikidata / SteamSpy 在本机网络全部不可达 |

所以 Key 是**纯可选增强**，定位是"把 70% 往上再抬一截"。不填永远能用，
只是少数游戏会显示文字标题 —— 那是设计内的正常分支，不是故障。

#### 为什么也没做「服务端代查」（Key 只存在服务器上）

一度设计过更省心的形态：Key 只放 PocketBase，客户端调 `/api/ct/title-logo?appid=`
拿 URL，图片仍由客户端**直连** CDN（不经过我们服务器）—— Key 不下发、用户零操作。
**最终放弃**，三条理由按权重排：

1. **取舍本身**（用户 2026-10-17 拍板）：*"这个 Key 就交给别的用户自己去填，我们这不费这个心思。"*
   为一个纯装饰性增强引入服务器依赖，收益不匹配风险。
2. **技术前提从未验证**：PB 那 8 个 hook **没有一个发过外部 HTTP 请求**
   （零外部 URL、零 `$http.send`），京东云（117.72.115.30）能否连 `steamgriddb.com`
   完全未知。为此写过只读探针 `net_probe.pb.js`，本地 8091 四项全通，但**必须动线上才能验**
   —— 为验一个可选项去改线上，不值。探针从未部署，本地已删。
3. **托管风险由项目承担**：Key 存 PB 则超管可见、服务器被拿下即泄露；Key 若被封，
   **全体用户同时失效**，而用户手里没有自己的 Key 可换。

> 将来若真要再抬覆盖率，优先级更高的做法是**离线补齐表**（把缺口游戏的 logo URL
> 收进 PB 集合或随包内置，客户端只读）：零 Key、零服务器出网依赖。仅覆盖已补的部分。

### 2.5 为什么不做「从封面图抠标题」

用户追问过这条路线，做了实测后否决（脚本与对照图留在
`.workbuddy/probe_game_logo/`）。三条硬理由：

1. **物理不可逆**：标题常压在角色身上（千恋万花压在白发角色头顶、Riddle Joker 压裙摆）。
   要"透明"就得知道被字挡住的地方原本是什么 —— 那些像素已经不存在了。
   对照图 `keyed/千恋万花_keyed.png`：抠出来整片头发变成白块。
2. **定位不可靠**：纯行梯度投影 6 张命中 5 张，ATRI 直接命中角色脸上。
3. **语义错位（最致命）**：封面印的是日文「蒼の彼方のフォーリズム」+ `CERO C` 分级标
   + 存储器提示图标；而我们要显示的是 `AOKANA -Four Rhythms Across the Blue-`。
   自动抠出来的是「错的标题 + 一堆包装盒图标」。

> 行业方案（ViTEraser / DeepEraser / TextDestroyer，STR 场景文字擦除）能力上能做，
> 但它们的方向是「把字抹掉并补背景」（隐私保护），与我们「把字提取出来」正好相反；
> 且需 100–200MB ONNX + 秒级推理，与打包瘦身冲突。**不做**。

---

## 3. 存储与字段

`game.json` 新增两个键（**不升 `format_version`**，沿用 `banner_file` / `storage_state`
的 ADR-012 显式例外：纯新增可空字段，`?? ''` 读取即兼容）：

| 键 | 含义 |
|---|---|
| `logo_file` | 文件名（相对游戏元数据目录），空串 = 无 |
| `logo_origin` | 来源标记：`steam`（官方 CDN）/ `sgdb`（SteamGridDB）/ 空 |

落盘文件名固定 **`title_logo.png`**（`GameDataFormat.titleLogoFileName`）。
`logo_origin` 的唯一用途是**排查时不必翻日志**就能回答"这张图哪来的"。

🔴 **刻意不叫 `logo.png`**：galgame 本体目录常自带 `logo.png` 作为游戏资源，
固定名撞车会让重扫捡到用户游戏文件当标题图。

🔴 **两个键都不在 `_overwritableFields`**：重复入库（`writeGameDir` 的 freshData 里
logo 恒为空串）若覆盖即"已有的图被清了"；抓取也不该由入库流程代劳 —— 它由
`GameTitleLogoService` 落盘后单字段写入（`updateGameJson`）。

---

## 4. 代码落点

| 层 | 文件 | 说明 |
|---|---|---|
| 数据 | `lib/services/game_data_format.dart` | `GameJsonData.logoFile / logoOrigin`、`findLogoFile()`、`titleLogoFileName` |
| 内存 | `lib/services/local_game_registry.dart` | `LibraryGame.logoPath` + 扫描三处填充 |
| 抓取 | `lib/services/game_title_logo_service.dart` | `fetchAndStore`（双源）/ `requestAutoFetch` / `verifySgdbApiKey` / `onSgdbKeyChanged` |
| 配置 | `lib/widgets/settings/title_logo_settings_card.dart` | 设置 → 网络与存储 →「大标题素材」（Key 输入 / 验证 / 清除） |
| 挂载 | `lib/widgets/settings_modal.dart` | `_buildNetworkStorageContent` 内 `SettingsSection('大标题素材')` |
| 展示 | `lib/widgets/game_title_logo.dart` | `GameTitleLogo`（贴图 + 描边 + 回退） |
| 接入 | `lib/pages/home_page.dart` `_buildGameTitle` | 桌面主页大标题 |
| 接入 | `lib/big_picture/pages/big_picture_home.dart` `_buildHeroLogoTitle` | BPM 主页 hero 大标题 |

---

## 5. 🔴 匹配纪律：宁可没有，也不能贴错

贴错图（B 游戏的 logo 出现在 A 游戏上）比没有图难排查得多，用户一眼就会觉得"软件乱了"。
因此只接受两种情况（`_resolveSteamAppId`）：

1. **源锚点精确对齐**：game.json 的 `metadata_source` + `metadata_source_id`
   在搜索结果 `sources[]` 里原样出现（如 `vndb:v12849`）；
2. **标题归一化后完全相等且唯一命中**（`TitleCleaner.normalizeForCompare`，
   比对 `display_name` 与各语言 `localized.*.value`）。

多义命中（≥2 个全等）→ **直接放弃**。模糊相似度匹配故意不做。

SteamGridDB 那一级同款纪律：有 appid 时用 `/games/steam/{appid}` 精确映射；
没有 appid 时才按名字搜，且同样要求**归一化全等且唯一**，同名多条目直接放弃。

配套：会话内 in-flight 去重 + 7 天负缓存（`data/title_logo_attempts.json`），
避免每次启动都去撞必然失败的条目。用户改 Key 时清空该缓存（见 §2.4）。

---

## 6. 展示参数（为什么是这些值）

### 6.1 统一高度、宽度自适应

裁掉透明边后同一 `maxHeight` 的实测尺寸：AOKANA `480×124`（3.87:1）、
CLANNAD `262×124`（2.11:1）。只有固定高度才能让左右两屏视觉重量一致；
`maxWidth` 只是防超长 logo 溢出的安全上限。

| 位置 | maxHeight | maxWidth | 依据 |
|---|---|---|---|
| BPM hero | 124 | 560 | ≈ 两行 64px 标题的视觉高度 |
| 桌面主页 | 64 | 480 | 原文字 38px 行高；60 时带副标题的 logo 副行会糊 |

### 6.2 八向描边（这是关键，别删）

Steam 标题图绝大多数是**白色字 + 透明底**。对照实验
（`.workbuddy/probe_game_logo/preview/light_surface_variants.png`）：

| 方案 | 浅底可读性 |
|---|---|
| 不处理 | ❌ 对比度接近 1:1，等于消失 |
| 45% 剪影 + blur4 | ❌ 仍然看不清 |
| 85% 剪影 + blur5 | 🟡 能读但边缘发脏 |
| **八向 2px 实心描边** | ✅ 最清楚，且保留原图配色 |
| 单色深剪影 | ✅ 清楚但丢失原设计 |

所以实现是：原图下面垫 **8 个平移 2px 的纯色剪影**（`ColorFilter.srcIn`）当"印刷描边"。
浅底描边 `0xE6` 黑、深底 `0xB3` 黑；深底再额外加一层 `blur(12)` 的柔和投影
（对应改造前文字的 `heroTextShadow`），浅底不加（会发脏）。

> 为什么不用 `ImageFilter.dropShadow`：Flutter **3.24.3 的 `dart:ui` 里没有这个 API**
> （已在 `flutter/bin/cache/pkg/sky_engine/lib/ui/` 全量搜索确认）。

### 6.3 回退必须零成本

无图 / 文件丢失（`errorBuilder`）→ 直接返回调用方传入的 `fallback`（改造前的原 widget），
布局与改造前完全一致。

---

## 7. 已知未完成 / 未验证

- 🚫 **手动指定入口：按用户要求不做**（2026-10-17 明确指示"不要手动抓取的入口"）。
  **收尾时已把当时预留的 `importLocalImage()` / `clear()` / `syncRegistryAfterManualEdit()`
  一并删掉**（无调用者 = 死代码，留着会让人误以为"有个入口"）；
  `normalizeLogoPng` 里只为它们存在的 `allowAnyAspect` / `allowOpaque` 也一起去掉，
  现在两道质量闸是**无条件生效**的。（`_applyToRegistry` 仍被自动链路使用，保留。）
- 🚫 **Key 由用户自填，不做服务端代查**（2026-10-17 最终拍板，详见 §2.4 末）。
  验证用的 `net_probe.pb.js` 临时探针**只在本机 8091 跑过，从未部署到线上**
  ⇒ 线上零污染；本地文件已删（zip / 部署说明 / hook 三份）。
- ✅ **SteamGridDB 已接**（Phase 2）：Key 未配置时静默跳过。⚠️ 但**覆盖率提升幅度未实测**
  —— 无 Key 无法打真实请求，只用无效 Key 验证过 401 分支。用户填 Key 后需实测：
  `Summer Pockets / サクラノ詩 / WHITE ALBUM2` 这类前一级失手的条目能否从 SGDB 拿到图。
- ✅ **零密钥覆盖率已从 55% 抬到 70%**（2026-10-17）：靠 ① 读 `refs` 而非 `sources`、
  ② 遍历全部候选 appid、③ 别名判定改用当前检索词（详见 §2.2）。已实测，不需要 Key。
- ⏳ **端到端未走查**：`CreateFile failed 231` 环境下 `flutter test` / `build` 不可用，
  本次只做到「进程内 analyzer 0 error」+ Python 等价合成预览（
  `preview/final_variants.png`）。**下次环境恢复必须补**：
  ① 真实端到端抓一次 AOKANA 看 `title_logo.png` 是否被正确裁剪；
  ② 两条主页的贴图与回退各走一遍；
  ③ 深/浅两个主题各看一眼；
  ④ 设置页填 Key → 保存 → 验证 → 切游戏看是否补抓成功。
- ⏳ `lib/widgets/editor_preview_builder.dart:1190` 的编辑器预览仍用文字标题，
  与主页不一致（**本次刻意不改**，待确认是否需要同步）。

---

## 8. 明确不改

`heroTitleSize` 等主题常量、封面/横幅（`cover_file` / `banner_file`）链路、
`format_version`、稳定区（`main.dart` / `theme/` / `portable_*` / `app_state.dart`）。

**能力边界（三条已被用户明确否决，不要再实现）**：

1. **不做手动指定 / 手动抓取入口** —— 用户两次指示"只做全自动，不要手动入口"。
2. **不做「从封面图自动抠标题」** —— 物理不可逆 + 定位不可靠 + 语义错位（§2.5）。
3. **不内置共用 Key、不做服务端代查** —— 开源镜像会泄露 Key；且服务器出网未验证（§2.4 末）。

**不做也不等于回退**：上述缺失时的行为就是显示文字大标题，
与改造前完全一致，**这是设计内的正常分支，不是故障**。
