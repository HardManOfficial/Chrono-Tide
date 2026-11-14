# NSFW 内容过滤系统 · 开发方案【v1 已废弃 · 存档】

> 🗄️ **这是 v1 方案的存档副本，仅用于追溯决策依据，不要再照它施工。**
>
> **废弃时间**：2026-09-04　**废弃原因**：v1 采用「分类模型 + 整图马赛克」，
> 且 `NsfwImage` 被设计为 Image 替代品，需在 32 个接入点各自复刻渲染细节，
> 覆盖率只做到 9/32。v2 改为「YOLOv8 检测模型 + 局部马赛克 + 装饰器组件」，
> 见 [`nsfw_filter_implementation_plan.md` §15](./nsfw_filter_implementation_plan.md)。
>
> **v1 代码已全部删除**（`nsfw_filter_service` / `nsfw_metadata_signal` /
> `nsfw_model_service` / `nsfw_score_store` / `nsfw_level` / `image_preprocess`），
> 需要时可 `git show 2fc8cb8:<路径>` 取回。
>
> 原文如下，内容未作任何改动。
>
> **文档性质**：实施方案（v1，已废弃）　**编写日期**：2026-09-03
> **项目版本**：v2.0.1　**适用目录**：`D:\CTLIB`

***

## 0. 结论摘要（TL;DR）

| 项                           | 结论                                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------------- |
| **核心策略**                    | **四层判定 + 一层渲染**。判定优先级：人工标记 > 元数据信号 > 本地模型推理 > 默认放行                                          |
| **推理引擎**                    | `flutter_onnxruntime ^1.8.4`（ONNX Runtime 1.23.0），**纯本地 CPU 推理，不联网、不上云**                    |
| **模型选型**                    | `deepghs/anime_rating` 的 `mobilenetv3_sce_dist`（**MIT 许可**、0.63 GFLOPS、约 17MB、官方准确率 69.49%） |
| **为何不用 NudeNet / NSFW\.js** | 二者均在**真人照片**上训练，对二次元插画（Galgame CG/HCG）误判率极高。deepghs 模型在 120 万张动漫图上训练，是本项目唯一合理选择             |
| **打码方式**                    | 真马赛克（像素化），用 `cacheWidth` 低分辨率解码 + `FilterQuality.none` 放大实现，**零新增依赖、GPU 无关**                |
| **是否动原图**                   | **绝对不动**。原图文件保持字节级不变，马赛克**只在渲染层瞬时生效**                                                       |
| **模型分发**                    | 随安装包打包进 `assets/models/`，开箱即用                                                               |
| **改动规模**                    | 新增 8 个文件 + 修改约 12 个文件；**一期不触碰任何稳定区**                                                        |

**最重要的一个设计取舍**：一期**刻意不修改** `lib/packages/luna_metadata_sdk/`（稳定区），
改用「扫描已有 tags 关键词」的方式获取元数据信号（§4.2）。这样能在零稳定区改动的前提下
拿到 L0 信号；需要的新数据源字段放到二期单独申请。

***

## 1. 背景与目标

### 1.1 需求原文

> 项目管理器会网络拉取 Galgame 元数据、封面、CG、HCG 素材；一部分内容属于成人向，
> 不能直接全部展示，需要 NSFW 过滤。本地端推理，不动数据本身，NSFW 作品可以保留条目，
> 封面模糊，判定 NSFW 的图片默认打马赛克 / 模糊占位。

### 1.2 拆解出的硬约束

| 编号 | 约束                | 对设计的直接影响                       |
| -- | ----------------- | ------------------------------ |
| C1 | **本地端推理**         | 排除一切云端 API；必须自带 ONNX 运行时与模型    |
| C2 | **不动数据本身**        | ❌ 禁止「下载时把马赛克版写盘」这条捷径。原图必须字节级不变 |
| C3 | **NSFW 作品保留条目**   | 是「打码」不是「删除/隐藏」。游戏条目、名称、元数据全部保留 |
| C4 | **封面模糊 / 默认打马赛克** | 需要全局生效的渲染拦截，且默认状态必须是「已打码」      |
| C5 | 素材以**二次元插画**为主    | 通用 NSFW 模型（真人训练）直接出局，见 §3.2    |

### 1.3 非目标（本期明确不做）

- ❌ 不做视频 / 动态 CG 的逐帧检测（只处理静态图片）

- ❌ 不做「隐藏/删除 NSFW 作品」模式

- ❌ 不做云端同步的偏好同步

- ❌ 不做局部精确马赛克（敏感部位 bbox），见 §8 Phase 3

***

## 2. 现状调研结论

> 以下行号均于 2026-09-03 实地核对，可直接引用。

### 2.1 已有的成人向信号 —— 全都没被消费

调研发现：**项目的成人向数据其实已经抓回来了，但一个都没用上。**

| 数据源              | 已有的成人信号                                                 | 位置                                                                                           | 当前状态                 |
| ---------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------- |
| **ErogameScape** | 解析出 `18禁`/`非18禁`/`陵辱もの` 等**作为 tags**                    | `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart:1190`                    | ✅ **已在 tags 里，可直接用** |
| 标签翻译表            | `成人内容`/`高成人度`/`成人向`/`凌辱` 等中文映射已存在                       | `lib/packages/luna_metadata_sdk/lib/services/tag_translator.dart:165, 210-211, 598-605, 643` | ✅ **中文关键词表现成**       |
| Bangumi          | 请求体已带 `'nsfw': true`                                    | `bangumi_service.dart:109`                                                                   | ⚠️ 只请求，未解析响应字段       |
| VNDB             | 注释已写明「增加 image\_flagging 用于 NSFW 判定」但 **fields 串漏写该字段** | `metadata_services.dart:66-70`                                                               | ❌ 未取到                |
| KunGal           | 文档称有 `content_limit` + `age_limit` 双标记                  | `kun_service.dart:25`                                                                        | ❌ 纯注释                |
| Hikarinagi       | 详情含 `nsfw` 字段                                           | `hikarinagi_service.dart:32`                                                                 | ❌ 纯注释                |
| TouchGal         | `allowNsfw=true` 请求参数                                   | `touchgal_service.dart:27,68,112,152`                                                        | ❌                    |
| DLsite           | Cookie `adultchecked=1` 绕过年龄验证                          | `metadata_services.dart:653`                                                                 | ❌                    |

> 💡 **关键洞察**：L0（元数据信号层）在一期**不需要改任何数据源 service** ——
> 只要扫描 `ErogameScape` 已经塞进 tags 的 `18禁` 等关键词即可拿到高置信信号。
> 这是本项目「零稳定区改动」方案成立的基础。

### 2.2 已有的打码先例 —— 可复用

项目**已经存在**一套手动封面模糊功能，是现成的骨架：

| 环节                | 位置                                                                                                                                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 持久化字段 `isBlurred` | `lib/services/game_data_format.dart:76`（字段白名单）、`:189`（默认 false）、`:819-821`（`setBlurred()`）、`:1255`/`:1302`（序列化，**注意：序列化在 game\_data\_format.dart，local\_game\_registry 无 toMap/fromMap**） |
| 运行时模型             | `lib/services/local_game_registry.dart:220`（字段声明）、`:253`（构造默认值）、`:606`（更新已有游戏）、`:661`（新建游戏复制）                                                                                             |
| 渲染（库页卡片）          | `lib/pages/library_page.dart:3010-3017`（`ImageFiltered` + sigma 12）                                                                                                                       |
| 渲染（首页）            | `lib/pages/home_page.dart:707-713`                                                                                                                                                        |
| 右键菜单入口            | `lib/pages/library_page.dart:339-341`、`:2592-2594`                                                                                                                                        |

**设计决策**：`isBlurred` 语义是「用户手动标记」，保持不变、继续作为**最高优先级的 L2 人工层**。
新增的 `nsfwLevel` 是自动判定结果，二者独立存储、互不覆盖。

### 2.3 图片渲染入口 —— 28 处，无统一组件

**不存在** `cover_widget.dart` / `smart_image.dart` 之类的公共封装。
图片渲染散落在 **18 个文件、28 处**裸调用：

- **本地图** **`Image.file`（18 处）**：`home_page.dart:509,1380`、`library_page.dart:2940`、
  `library_ghost_card.dart:157`、`library_drag_overlay.dart:113`、
  `game_detail_dialog.dart:1204,1216,2131,3630`、`screenshot_carousel.dart:457`、
  `big_picture_home.dart:205,923`、`big_picture_detail.dart:500`、
  `big_picture_game_card.dart:186`、`bpm_metadata_section.dart:194`、
  `batch_import_section.dart:818`、`smart_import_section.dart:1143`、`field_lock_button.dart:90`

- **网络图** **`CachedNetworkImage`（12 处）**：`discover_page.dart:1354`、`game_detail_page.dart:1233`、
  `game_detail_dialog.dart:3363`、`screenshot_carousel.dart:428`、
  `big_picture_discover.dart:517,658`、`bpm_metadata_section.dart:202`、
  `metadata_section.dart:325`、`batch_import_section.dart:835`、
  `series_panel.dart:434`、`series_strip.dart:395`

- **裸** **`Image.network`（3 处，未走 CacheManager）**：`install_center_page.dart:371,521`、
  `install_confirmation_dialog.dart:249`

**两处非 Widget 路径（最容易漏）**：

1. `lib/widgets/game_detail_dialog.dart:3630` —— `_ScreenshotLightbox` 大图（`:3540` 定义，`:2434` 触发），
   直接用 `Image.file`，**完全绕过轮播组件**
2. `lib/widgets/screenshot_carousel.dart:136` —— `precacheImage(CachedNetworkImageProvider(...))`，
   不是 Widget，但会预加载原图

### 2.4 依赖现状

`pubspec.yaml` 中图像处理相关依赖：只有 `cached_network_image ^3.4.1`、`flutter_cache_manager ^3.4.1`、`flutter_svg ^2.0.10`。
**没有** `image`、`extended_image`、`flutter_image_compress`、`photo_view`。

已有 `dart:ui` 的 `ImageFilter` 使用先例：`lib/pages/home_page.dart:482`（`BackdropFilter` 毛玻璃）。

### 2.5 数据持久化

- 全项目**无 SQLite**，全部 JSON 文件

- 数据根：`PathHelper.dataDir = <exeDir>/data`（`lib/core/path_helper.dart:62`）

- 游戏主数据：游戏目录下 `game.json`（`game_data_format.dart:172`）

- `format_version` 当前为 `1`（`game_data_format.dart:12`），**全文件无任何版本升级分支**
  → 新增字段用 `?? 默认值` 读取即可，**不会触发数据迁移**

- 元数据缓存：`data/cache/metadata_cache.json`，版本号 `_cacheVersion = 3`（`metadata_fetcher.dart:54`）

***

## 3. 技术选型

### 3.1 推理运行时：选 `flutter_onnxruntime`

| 候选                        | Windows 支持           | 维护状态                                               | 结论       |
| ------------------------- | -------------------- | -------------------------------------------------- | -------- |
| **`flutter_onnxruntime`** | ✅ CPU 推理全支持          | **v1.8.4，10 天前更新**（2026-08 下旬），ONNX Runtime 1.23.0 | ✅ **选定** |
| `ort_dart`（Rust 后端）       | ✅ DirectML + XNNPACK | 需 Rust 工具链，构建复杂度高                                  | ❌        |
| `tflite_flutter`          | ⚠️ 桌面端支持弱            | 维护不活跃                                              | ❌        |
| 自己写 FFI 调 ORT C API       | ✅                    | 工作量大、内存管理易错                                        | ❌        |

**已知代价**：

- Windows 构建时 CMake 会**自动从官方仓库下载** `onnxruntime-win-x64-1.23.0.zip`，
  **首次构建需要联网**，并把约 15MB 的 `onnxruntime.dll` 打进产物。
  → 需在离线构建环境预置该 zip，或接受首次联网构建。

- 插件仅在 CPU EP 上验证（CUDA / DirectML 在 Windows 侧为 Placeholder 或未验证），
  **一期一律走 CPU**。

### 3.2 模型：选 `deepghs/anime_rating`（动漫专用）

**这是本方案最关键的一次选型，理由是场景匹配度。**

| 候选                                             | 训练数据                        | 体积                | 对二次元的适用性                  | 许可                    | 结论            |
| ---------------------------------------------- | --------------------------- | ----------------- | ------------------------- | --------------------- | ------------- |
| **`deepghs/anime_ratingmobilenetv3_sce_dist`** | **120 万张动漫图**（sankaku 分级体系） | \~17MB0.63 GFLOPS | ✅ **专为二次元设计**官方准确率 69.49% | **MIT**               | ✅ **选定**      |
| `deepghs/anime_censor_detection`               | 动漫（部位检测）                    | 44.6MB            | ✅ 精确，但 F1 仅 0.83          | MIT                   | 二期可选（Phase 3） |
| `deepghs/anime_dbrating`                       | 丹东分级                        | \~17MB            | ✅ 4 类分级                   | ⚠️ **openrail**，商用需评估 | ❌ 许可风险        |
| NudeNet (YOLOv8)                               | **真人照片**                    | 小                 | ❌ 二次元误判严重                 | MIT                   | ❌             |
| NSFW\.js / open\_nsfw                          | **真人照片为主**                  | \~20MB            | ❌ 仅 `hentai` 类勉强可用        | MIT                   | ❌             |

> **重要提醒（必须写进 UI 文案）**：deepghs 官方明确声明
> 「safe / r15 / r18 之间边界模糊，数据未经人工清洗，模型只能提供**粗略判断**」。
> 因此本系统的定位是**降低意外暴露风险的辅助手段**，不是精确的内容分级器。
> UI 上不应宣称「智能识别成人内容」，建议文案为「NSFW 内容保护（辅助判定）」。

**模型规格（开发时须实测核对 meta.json）**：

```
仓库:   huggingface.co/deepghs/anime_rating
变体:   mobilenetv3_sce_dist   (蒸馏自 caformer_s36_plus，小模型中最高准确率 69.49%)
输入:   [1, 3, 256, 256] float32, NCHW      ← 256 为推断值，以 meta.json 为准
归一化: (x / 255.0 - 0.5) / 0.5
输出:   [1, 3] logits → softmax → [safe, r15, r18]   ← 标签顺序以 meta.json 为准
许可:   MIT  ✅
```

> ⚠️ `deepghs/anime_rating` 的 HuggingFace 页面在国内可能直连失败。
> 建议从 **ModelScope 镜像**（`modelscope.cn/models/deepghs/anime_rating`）下载，
> 下载后**校验 SHA256** 并把哈希硬编码进代码做启动时校验。

### 3.3 图像预处理：新增 `image` 包

预处理链路：`文件/网络 bytes → 解码 → resize 256×256 → RGB → NCHW float32`

| 方案                                | 优点                                       | 缺点                                      | 结论       |
| --------------------------------- | ---------------------------------------- | --------------------------------------- | -------- |
| **`image`** **包（纯 Dart）**         | 纯 Dart 无平台依赖，**可在 isolate 中安全运行**；API 简单 | 纯 Dart 解码大 JPEG 较慢（估算 200–400ms/张）      | ✅ **选定** |
| `dart:ui` `instantiateImageCodec` | 原生解码，快 10×                               | 后台 isolate 中使用需处理 `RootIsolateToken`，坑多 | 二期性能优化备选 |

`image` 包是纯 Dart，**不含原生代码**，不会给 Windows 打包带来额外复杂度。

### 3.4 打码实现：真马赛克，零依赖

```dart
Image.file(
  File(path),
  cacheWidth: 32,                    // 强制以 32px 宽解码 → 信息已不可逆丢失
  filterQuality: FilterQuality.none, // 最近邻放大 → 硬边色块 = 马赛克
  fit: BoxFit.cover,
)
```

**为什么不用高斯模糊**：模糊在数学上是可逆卷积，存在被「去模糊」还原的风险；
且 Galgame CG 常见大面积皮肤色块，模糊后轮廓仍可辨。**马赛克是降采样，信息真丢失。**

> ⚠️ **必须实测**：`cacheWidth` + `FilterQuality.none` 在 Flutter 3.24 / Windows 桌面端
> 是否稳定产生马赛克效果，需写一个最小 demo 验证（§7 Phase 0 任务 P0-1）。
> 若不生效，**Plan B**：用 `image` 包 `copyResize` 到极小尺寸再放大，
> 编码为 PNG 字节流后用 `Image.memory` 显示（多一次编解码，但结果确定）。

***

## 4. 架构设计

### 4.1 四层判定 + 一层渲染

```
                      ┌─────────────────────────────┐
                      │   L2 人工标记（最高权威）      │
                      │   isBlurred / 用户手动切换     │
                      └──────────────┬──────────────┘
                                     │ 无人工标记 ↓
                      ┌──────────────▼──────────────┐
                      │   L0 元数据信号（作品级）      │
                      │   tags 关键词 / 数据源归属     │
                      └──────────────┬──────────────┘
                                     │ 无信号 ↓
                      ┌──────────────▼──────────────┐
                      │   L1 本地模型推理（图片级）     │
                      │   ONNX + 结果缓存             │
                      └──────────────┬──────────────┘
                                     │ 推理失败/未启用 ↓
                      ┌──────────────▼──────────────┐
                      │   L3 默认放行（可配置）        │
                      └─────────────────────────────┘

                                  ↓ 判定结果

                      ┌─────────────────────────────┐
                      │   渲染层 NsfwImage 组件        │
                      │   马赛克 / 原图 / 临时揭示      │
                      └─────────────────────────────┘
```

**判定优先级（代码中的短路顺序）**：`L2 > L0 > L1 > L3`
任何一层得出确定结论就不再往下走 —— 这是性能与体验的关键：
L1 模型推理是**兜底**而非常规路径，绝大多数作品会被 L0 拦下，从而完全不触发推理。

### 4.2 L0 元数据信号层（一期零稳定区改动）

**信号源 A：tags 关键词匹配**（主力，零改动）

`ErogameScape` 已把成人标记塞进 tags（`metadata_services.dart:1190`），
且 `tag_translator.dart` 已把这些标记翻译成中文。

**R18 正向关键词**（命中任一 → `r18`）：

```
18禁、成人内容、高成人度、成人向、凌辱、和姦、抜きゲー、性的描写、高H度
```

**SFW 反向关键词**（命中任一 → `safe`）：

```
非18禁、无成人内容、非抜きゲー、全年齢
```

> 🔥 **P0 陷阱 —— 子串误判**：
> `非18禁` **包含** `18禁` 子串！用 `tag.contains('18禁')` 会把全年龄作品判成 R18。
> **必须先跑反向关键词表，命中即短路为 safe，再跑正向表。**
> 同理 `非抜きゲー` 包含 `抜きゲー`。

**信号源 B：数据源归属**（辅助）

`DLsite` 源的条目默认按 R18 处理（该站以成人向为主），
除非 tags 中出现反向关键词。此规则**可通过设置关闭**。

**信号源 A/B 均命中失败** → 交由 L1。

### 4.3 L1 模型推理层

**触发时机**（都必须异步、不阻塞 UI）：

1. 元数据抓取完成、封面/截图**下载落盘后**（后台队列，串行）
2. 用户在库页对「未判定」条目手动点「重新判定」

**不触发**：滚动列表时的实时判定（性能不可接受，见 §6 性能预算）。

**结果缓存**（关键，避免重复推理）：

- 落盘：`<exeDir>/data/cache/nsfw_scores.json`

- Key：`sha256(图片字节).substring(0,16) + '_' + 文件字节长度`

- Value：`{ level: int, confidence: double, modelVer: String, ts: int }`

- 模型版本变更时整表失效

**降级策略**：模型加载失败 / 推理异常 / 模型文件缺失 →
静默降级为「仅 L0 + L2」，**绝不因 NSFW 模块崩溃影响主流程**。
所有异常必须被捕获并写日志，不得向上传播。

### 4.4 渲染层 `NsfwImage`

统一组件，内部查询 `NsfwFilterService` 得到「是否打码」，输出马赛克或原图。

```dart
/// 用法示例（替换 Image.file / CachedNetworkImage）
NsfwImage.file(
  path,
  nsfwLevel: game.nsfwLevel,   // 作品级判定结果，可为 null
  fit: BoxFit.cover,
  borderRadius: BorderRadius.circular(4),
)
NsfwImage.network(url, nsfwLevel: level, fit: BoxFit.cover)
```

**交互**：

- 默认渲染马赛克

- 点击 / 悬停显示「👁 长按查看」提示，长按或点击后**临时揭示**（本次会话内、或直接恢复到下次渲染）

- 已打码的图右下角显示小锁图标（可选，受设置控制）

- 详情弹窗顶部显示提示条：「此内容已按 NSFW 策略打码 · \[临时显示]」

**全局开关**（持久化在 `data/prefs/shared_preferences.json`）：

| Key                    | 类型   | 默认      | 说明                             |
| ---------------------- | ---- | ------- | ------------------------------ |
| `nsfw_filter_enabled`  | bool | `true`  | 总开关                            |
| `nsfw_strictness`      | int  | `1`     | 0=宽松（只糊 r18）、1=标准（糊 r15 + r18） |
| `nsfw_model_enabled`   | bool | `true`  | 是否启用 L1 模型推理（关掉则纯 L0）          |
| `nsfw_reveal_remember` | bool | `false` | 揭示状态是否记住                       |

***

## 5. 数据模型变更

### 5.1 新增枚举 `lib/models/nsfw_level.dart`

```dart
/// NSFW 分级。数值与 deepghs/anime_rating 的三分类对齐。
enum NsfwLevel { safe, r15, r18 }

extension NsfwLevelExt on NsfwLevel {
  int get value => index;                       // 0 / 1 / 2
  static NsfwLevel fromValue(int? v) =>
      v == null ? NsfwLevel.safe : NsfwLevel.values[v.clamp(0, 2)];
}
```

### 5.2 `LibraryGame` 新增字段

位置：`lib/services/local_game_registry.dart:220` 附近（`isBlurred` 之后）

```dart
NsfwLevel nsfwLevel;        // 判定结果，默认 safe
String nsfwSource;          // 判定来源：'' | 'metadata' | 'model' | 'manual'
```

默认值：`NsfwLevel.safe` / `''`（`local_game_registry.dart:253` 构造参数区）。

### 5.3 持久化 `game.json`

位置：`lib/services/game_data_format.dart`

| 改动点          | 行号         | 改法                                           |
| ------------ | ---------- | -------------------------------------------- |
| 字段白名单        | `:76`      | 追加 `'nsfw_level'`、`'nsfw_source'`            |
| 默认值          | `:189`     | `nsfwLevel: json['nsfw_level'] as int? ?? 0` |
| 读取（fromJson） | `:1234` 附近 | 同上，用 `?? 0` → **不触发迁移**                      |
| 写入（toJson）   | `:1285` 附近 | 追加两个字段                                       |

> ✅ **无需数据迁移**：`format_version` 保持 `1`，新字段用 `??` 兜底，
> 旧 `game.json` 读取时自动得到 `safe`。**不要** bump `format_version`。

### 5.4 元数据缓存

- `_convertToLegacyFormat`（`metadata_fetcher.dart:952-982`）输出 Map 中新增 `nsfw_level` 键

- **bump** **`_cacheVersion`** **从 3 → 4**（`metadata_fetcher.dart:54`），使旧缓存整体失效

> 🔥 **P0 陷阱 —— MIX 合并丢弃 0 值**：
> `_mergeMixResults` 的 `pick()`（`metadata_fetcher.dart:714-727`）中，
> 空值判定含 `(value is num && value == 0)`。
> 而 `nsfw_level = 0` 恰恰代表 **safe**（合法且常见的值），
> 会被误判为空值而丢弃，导致所有 safe 作品丢失判定结果。
> **必须**在 `pick()` 中对 `nsfw_level` 字段特判，或改用 `null` 表示未知、用 `1` 起编。
> 推荐后者：持久化用 `0=未知 / 1=safe / 2=r15 / 3=r18`，从根上避开这个坑。

***

## 6. 性能预算

| 环节                         | 估算耗时            | 备注                     |
| -------------------------- | --------------- | ---------------------- |
| ONNX 模型首次加载                | 300–800ms       | 应用启动后**延迟懒加载**，不在启动路径上 |
| 纯 Dart 解码 1920×1080 JPEG   | 200–400ms       | `image` 包；是整条链路的瓶颈     |
| resize → 256×256 + NCHW 转换 | 15–30ms         | <br />                 |
| mobilenetv3 推理（CPU）        | 30–60ms         | 0.63 GFLOPS            |
| **单张合计**                   | **\~250–500ms** | <br />                 |

**导入一个游戏（封面 1 + 截图 6）≈ 2–3.5 秒。**

硬性要求：

1. 推理**必须**在独立 isolate 中运行，不得占用 UI 线程
2. 使用**串行队列 + 并发上限 1**，不得并发推理（避免内存峰值）
3. 导入流程**不等待**推理结果 —— 先按 L0 判定渲染，L1 结果出来后再局部刷新（差值刷新，不整表重建）
4. 库页滚动时**禁止**触发推理

***

## 7. 实施阶段划分

> 每个 Phase 开始前都要输出《变更计划》并等用户批准。**一次只做一个 Phase。**

### Phase 0 —— 技术验证（必须先做，产出验证报告）

| 编号   | 任务                                                                                                            | 验收标准                                     |
| ---- | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| P0-1 | 最小 demo 验证 `cacheWidth` + `FilterQuality.none` 在 Windows 桌面端产出马赛克                                             | 截图证明马赛克生效；若不生效，确定 Plan B                 |
| P0-2 | 最小 demo 跑通 `flutter_onnxruntime` 在 Windows 的 CPU 推理（用 1+1 的加法模型即可）                                            | `flutter run -d windows` 成功输出推理结果        |
| P0-3 | 从 ModelScope 下载 `anime_rating` / `mobilenetv3_sce_dist`，核对 `meta.json` 的 `input_size`、`labels` 顺序，记录文件 SHA256 | 产出一张「模型规格确认表」，代码中的常量以此为准                 |
| P0-4 | 用 Python + onnxruntime 对同一批 CG 图跑一遍，人工抽查 20 张（10 张正常 CG / 10 张 HCG）的实际准确率                                     | 产出准确率报告。**若二次元图准确率低于 60%，需回本项目重新评估模型选型** |
| P0-5 | 确认 `onnxruntime-win-x64` DLL 的最终体积与打包方式                                                                       | 记录打包后安装包增量                               |

**Phase 0 的全部产出是一份验证报告 + 决策，不写进主工程。**

### Phase 1 —— L0 元数据层 + 渲染层（无模型，可独立交付）

1. 新增 `lib/models/nsfw_level.dart`
2. 新增 `lib/services/nsfw/nsfw_filter_service.dart`（判定仲裁 + 开关 + 缓存查询）
3. 新增 `lib/services/nsfw/nsfw_metadata_signal.dart`（tags 关键词匹配，**注意 §4.2 的子串陷阱**）
4. `local_game_registry.dart` / `game_data_format.dart` 加字段（§5.2 / §5.3）
5. 新增 `lib/widgets/nsfw/nsfw_image.dart`
6. 替换 **P0 批次 8 处**渲染调用点（见 §9.1）
7. `settings_modal.dart` 新增「NSFW 内容保护」卡片

**交付价值**：即便模型还没接，用户已能获得「ErogameScape 18禁 作品自动打码」的能力。

### Phase 2 —— L1 模型推理层

1. `pubspec.yaml` 新增 `flutter_onnxruntime`、`image` 依赖 + `assets/models/` 条目
2. 新增 `lib/services/nsfw/nsfw_model_service.dart`（会话管理、懒加载、推理）
3. 新增 `lib/services/nsfw/image_preprocess.dart`（isolate 内预处理）
4. 新增 `lib/services/nsfw/nsfw_score_store.dart`（结果缓存）
5. 在截图/封面下载完成后接入后台判定队列
6. 设置页新增「启用图片智能判定」开关 + 模型状态显示

### Phase 3 —— 补齐渲染入口 + 可选增强

1. 替换剩余 20 处渲染调用点（§9.2）
2. 处理两处非 Widget 路径：`game_detail_dialog.dart:3630`（Lightbox）、
   `screenshot_carousel.dart:136`（precache）
3. 库页右键菜单新增「标记为 NSFW / 取消标记」（复用 `isBlurred` 入口样式）
4. **（可选，需单独评估）** 引入 `anime_censor_detection` 做局部精确马赛克
5. 单元测试：`nsfw_metadata_signal_test.dart`、`nsfw_level_test.dart`

***

## 8. 改动文件清单（供《变更计划》引用）

### 8.1 新增文件

| 路径                                                     | 职责                                   |
| ------------------------------------------------------ | ------------------------------------ |
| `lib/models/nsfw_level.dart`                           | 分级枚举 + 阈值常量                          |
| `lib/services/nsfw/nsfw_filter_service.dart`           | **总控**：四层判定仲裁、全局开关、ChangeNotifier 通知 |
| `lib/services/nsfw/nsfw_metadata_signal.dart`          | L0：tags 关键词匹配                        |
| `lib/services/nsfw/nsfw_model_service.dart`            | L1：ONNX 会话管理与推理（Phase 2）             |
| `lib/services/nsfw/image_preprocess.dart`              | 图像预处理（isolate 内，Phase 2）             |
| `lib/services/nsfw/nsfw_score_store.dart`              | 判定结果缓存持久化（Phase 2）                   |
| `lib/widgets/nsfw/nsfw_image.dart`                     | **统一渲染组件**                           |
| `assets/models/anime_rating_mobilenetv3_sce_dist.onnx` | 模型文件（Phase 2）                        |
| `assets/models/anime_rating_meta.json`                 | 模型元信息（Phase 2）                       |

### 8.2 修改文件

| 路径                                      | 位置                           | 改法                                                        | 风险                                      |
| --------------------------------------- | ---------------------------- | --------------------------------------------------------- | --------------------------------------- |
| `lib/core/path_helper.dart`             | `:73` 附近                     | 新增 `modelsDir`、`nsfwCacheFilePath` 两个 getter              | ⚪ 纯新增                                   |
| `lib/services/local_game_registry.dart` | `:220`、`:253`                | `LibraryGame` 加 2 字段 + 构造默认值                              | 🟡 数据核心，改前跑测试                           |
| `lib/services/game_data_format.dart`    | `:76`、`:189`、`:1234`、`:1285` | 持久化 2 字段                                                  | 🟡 同上                                   |
| `lib/services/metadata_fetcher.dart`    | `:54`、`:583`、`:714`、`:952`   | `_cacheVersion` 3→4；优先级表加 `nsfw_level`；`pick()` 特判；转换函数透传 | 🔴 见 §5.4 陷阱                            |
| `lib/widgets/settings_modal.dart`       | `:68`、`:85`、`:893`           | 加 1 个字段 + 1 次加载 + 1 个卡片（照抄 `:1222-1329` 结构）               | 🟡 4096 行巨型文件，只做局部插入                    |
| 渲染调用点                                   | 见 §9                         | 替换为 `NsfwImage`                                           | 🟡 逐个验证                                 |
| `pubspec.yaml`                          | `:9`、`:46`                   | 新增 2 依赖 + 1 assets 条目                                     | 🟡 AGENTS.md 2.3 禁止改依赖**版本**，新增依赖需向用户说明 |

### 8.3 🔴 一期明确不碰（稳定区）

| 模块                                        | 原因                                                                                                    |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `lib/packages/luna_metadata_sdk/`         | **稳定区**。一期用 tags 关键词方案绕开。二期若要取 VNDB `image_flagging`、Bangumi `nsfw`、Hikarinagi `nsfw` 字段，**必须单独申请批准** |
| `lib/main.dart`、`lib/main_container.dart` | 入口与容器，不需要动                                                                                            |
| `lib/theme/`                              | 主题系统，不需要动                                                                                             |
| `lib/core/portable_*.dart`                | 便携路径体系，`path_helper.dart` 只做**新增 getter**                                                             |
| `lib/services/app_state.dart`             | 全局状态中枢，不接入；NSFW 用独立 Service                                                                           |
| `windows/runner/`                         | 原生层，不需要动                                                                                              |

***

## 9. 渲染调用点替换清单

### 9.1 Phase 1 必改（P0 批次，8 处 —— 覆盖约 90% 视觉面积）

| # | 位置                                                | 场景                          |
| - | ------------------------------------------------- | --------------------------- |
| 1 | `lib/pages/home_page.dart:509`                    | 首页网格封面                      |
| 2 | `lib/pages/library_page.dart:2940`                | 库页卡片封面                      |
| 3 | `lib/widgets/game_detail_dialog.dart:1204`        | 详情弹窗主封面                     |
| 4 | `lib/widgets/game_detail_dialog.dart:3630`        | **截图 Lightbox 大图**（独立路径，勿漏） |
| 5 | `lib/widgets/screenshot_carousel.dart:457`        | 截图轮播·本地分支                   |
| 6 | `lib/widgets/screenshot_carousel.dart:428`        | 截图轮播·网络分支                   |
| 7 | `lib/pages/discover_page.dart:1354`               | 探索页推荐流封面                    |
| 8 | `lib/big_picture/pages/big_picture_home.dart:205` | 大屏首页全屏背景                    |

### 9.2 Phase 3 补齐（P1 批次，20 处）

`home_page.dart:1380`、`library_ghost_card.dart:157`、`library_drag_overlay.dart:113`、
`game_detail_dialog.dart:1216,2131,3363`、`game_detail_page.dart:1233`、
`big_picture_home.dart:923`、`big_picture_detail.dart:500`、`big_picture_game_card.dart:186`、
`bpm_metadata_section.dart:194,202`、`big_picture_discover.dart:517,658`、
`metadata_section.dart:325`、`batch_import_section.dart:818,835`、
`smart_import_section.dart:1143`、`field_lock_button.dart:90`、
`series_panel.dart:434`、`series_strip.dart:395`

### 9.3 P2 批次（3 处，低优先级）

`install_center_page.dart:371,521`、`install_confirmation_dialog.dart:249`
（下载/安装流程的小缩略图，尺寸小、优先级低）

### 9.4 非 Widget 路径（勿漏）

`lib/widgets/screenshot_carousel.dart:136` —— `precacheImage(CachedNetworkImageProvider(...))`。
此处虽不影响渲染，但会预加载原图。应改为：先查判定结果，NSFW 时不预加载，
或直接预加载马赛克版本。

***

## 10. 风险登记（P0–P3）

| 级别        | 风险                                                             | 影响                     | 应对                                                                  |
| --------- | -------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------- |
| 🔴 **P0** | **子串误判**：`非18禁` 含 `18禁`，`非抜きゲー` 含 `抜きゲー`                       | 全年龄作品被误打码，**属于严重功能缺陷** | 先跑反向表并短路；写单元测试覆盖                                                    |
| 🔴 **P0** | **`_mergeMixResults`** **丢弃 0 值**（`metadata_fetcher.dart:723`） | safe 判定在 MIX 源下全部丢失    | 持久化编码改为 `0=未知`，从根上避开；或 `pick()` 特判                                  |
| 🔴 **P0** | **二次元模型准确率未经实测**                                               | 模型选错 → 整个 L1 层白做       | Phase 0 的 P0-4 必须做，低于 60% 就换方案                                      |
| 🟡 **P1** | `cacheWidth` + `FilterQuality.none` 在 Windows 端可能不生效           | 马赛克变成普通缩放，功能失效         | Phase 0 的 P0-1 验证；Plan B 用 `image` 包预生成                             |
| 🟡 **P1** | ONNX Runtime DLL 首次构建需联网下载                                     | 离线 CI / 打包环境构建失败       | 预置 `onnxruntime-win-x64-1.23.0.zip` 到 `assets/tools/` 并改 CMake 指向本地 |
| 🟡 **P1** | 纯 Dart 解码大图慢（200–400ms/张）                                      | 批量导入时后台任务堆积            | 独立 isolate + 串行队列；必要时换 `dart:ui` 原生解码                               |
| 🟡 **P1** | **模型许可合规**：`anime_dbrating` 是 openrail 而非 MIT                  | 若误用会有合规风险              | 只用 `anime_rating`（MIT）；把许可文件一并放进 `assets/models/LICENSE`            |
| ⚪ **P2**  | 28 处替换遗漏                                                       | 某个入口漏打码                | 按 §9 清单逐项勾选；Phase 0 先做全局 grep 复核实际数量                                |
| ⚪ **P2**  | 误判导致正常 CG 被打码                                                  | 用户体验受损                 | 提供「标记为安全」手动入口 + 宽松/标准两档严格度                                          |
| ⚪ **P3**  | 模型文件 17MB 增大安装包                                                | 分发体积                   | 已由用户决策接受（随包分发）                                                      |
| ⚪ **P3**  | 未来的局部马赛克（Phase 3 可选）F1 仅 0.83                                  | 漏检区域露出                 | 仅作为增强，不作为主要手段                                                       |

***

## 11. 验收标准

### 11.1 功能验收

- [ ] 一个 ErogameScape 标记为 `18禁` 的游戏，导入后封面/截图**默认显示马赛克**

- [ ] 一个明确全年龄的游戏（`非18禁`），**不被打码**

- [ ] 关闭总开关后，所有图恢复正常显示

- [ ] 严格度切到「宽松」，r15 图恢复显示、r18 图仍打码

- [ ] 点击打码图可临时揭示，且该状态受设置控制

- [ ] **原图文件字节未变**（对比打码前后的文件 SHA256）

- [ ] 手动「标记为 NSFW」优先级最高，能覆盖自动判定

- [ ] 模型文件缺失/损坏时，应用**不崩溃**，自动降级为纯 L0 模式

### 11.2 技术验收

```bash
# 静态检查（只针对改动文件，基线为 0 error）
./flutter/bin/flutter.bat analyze lib/services/nsfw/ lib/widgets/nsfw/ lib/models/nsfw_level.dart

# 测试（基线：181 通过 / 13 失败，13 个失败全在 test/big_picture/widgets/ 是存量问题，不得新增失败）
./flutter/bin/flutter.bat test test/services/ test/models/

# 自查改动面（必须无计划外文件）
git status --short
git diff --stat
```

### 11.3 收尾（AGENTS.md §3 强制）

- [ ] `docs/DEV/DEV_LOG.md` 追加一条

- [ ] 更新 `docs/DEV/features/nsfw_filter_implementation_plan.md` 的状态与实测数据

- [ ] 更新 `docs/DEV/SESSION_HANDOFF.md`

- [ ] 若产生架构决策（如模型选型、编码方案），追加到 `docs/DEV/DECISIONS.md`

- [ ] 一个任务一个 commit，信息写清「为什么改」

- [ ] 向用户报告：改了什么（文件+行号）、验证了什么（命令+结果）、**没验证什么**

***

## 12. 给执行 AI 的指令摘要

```
你是 Chrono Tide 项目的开发者。请先完整阅读：
  1. D:\CTLIB\AGENTS.md                      ← AI 行为宪法，强制约束
  2. D:\CTLIB\docs\DEV\SESSION_HANDOFF.md    ← 当前进度
  3. D:\CTLIB\docs\DEV\STATUS_MAP.md         ← 模块地图
  4. 本文件

任务：实现 NSFW 内容过滤系统。

硬约束：
  · 两段式流程：先只读审计、输出《变更计划》，等用户批准后才动手
  · 最小变更：只改必需的那几行，禁止顺手重构/格式化/优化
  · 一次只做一个 Phase（从 Phase 0 开始）
  · 一期禁止触碰 lib/packages/luna_metadata_sdk/ 等稳定区（见 §8.3）
  · 禁止 bump format_version，禁止改依赖版本（新增依赖需说明）
  · 禁止运行 git gc
  · 用项目内 Flutter：./flutter/bin/flutter.bat（3.24.3 / Dart 3.5.3）
  · 测试基线 181 通过 / 13 失败（存量，不得新增失败）
  · 交付物简体中文，引用代码必须给 文件路径:行号，问题按 P0–P3 标注

特别注意三个 P0 陷阱（§10）：
  1. tags 匹配的子串误判（非18禁 含 18禁）
  2. _mergeMixResults 丢弃 0 值
  3. 二次元模型准确率必须先实测再落地
```

***

## 13. 待用户决策的开放问题

| # | 问题                                                          | 决策                                        |
| - | ----------------------------------------------------------- | ----------------------------------------- |
| 1 | 安装包体积增加约 17MB（模型）+ 15MB（ORT DLL）是否可接受？                      | 已决策：可接受。但若实测增量远超预期需重新评估                   |
| 2 | 默认严格度设「标准」（r15 也打码）还是「宽松」（只糊 r18）？                          | **已决策（2026-09-03，AI 代拍板）：标准**             |
| 3 | 揭示（reveal）状态是否跨会话记忆？                                        | **已决策（2026-09-03，AI 代拍板）：不记忆**，揭示态仅存于组件实例 |
| 4 | 是否需要在探索页（discover）也启用过滤？                                    | **已决策（2026-09-03，AI 代拍板）：启用**             |
| 5 | 二期是否申请改 `luna_metadata_sdk` 以取 VNDB `image_flagging` 等原生字段？ | 待一期上线后根据实际覆盖率决定                           |
| 6 | 是否需要把 NSFW 判定做成可插拔（用户自选模型）？                                 | **已决策（2026-09-03，AI 代拍板）：不做**             |

***

## 14. 实施状态（2026-09-03 更新）

### Phase 1 —— ✅ 代码完成（未经真机视觉验证）

- 新增：`lib/models/nsfw_level.dart`、`lib/services/nsfw/nsfw_metadata_signal.dart`、
  `lib/services/nsfw/nsfw_filter_service.dart`、`lib/widgets/nsfw/nsfw_image.dart`、
  `test/services/nsfw_metadata_signal_test.dart`（17 用例全过）

- 数据层：`LibraryGame` / `GameJsonData` 新增 `nsfwLevel`(可空)/`nsfwSource`；
  `scan()` 在更新/新建分支同步 L0 判定（人工标记优先保留）

- 渲染层：§9.1 的 8 处 P0 批次全部替换为 `NsfwImage`

- 设置页：「NSFW 内容保护」卡片（总开关 + 宽松/标准严格度）

- 验证：analyze 0 error；全量测试 198 通过 / 13 失败（13 个失败为存量，无新增）

**实现偏离方案的决策**（详见 DEV\_LOG 2026-09-03 Phase 1 条目）：

1. **未改** **`metadata_fetcher.dart`**（原 §5.4 计划）：L0 由 scan() 现场算 tags，无需进元数据缓存，
   同时避开 pick() 0 值陷阱与全用户缓存失效
2. **持久化编码 1=safe/2=r15/3=r18，未判定写 null**（落实 §5.4 建议）
3. **nsfwLevel 可空**（null=未判定放行），偏离 §5.1 非空枚举设计
4. **点击揭示按场景白名单**（enableReveal 默认 false）：网格卡片有自身点击手势，
   仅轮播/Lightbox/详情封面可点击揭示

**待办**：真机验证马赛克效果（P0-1）→ Phase 0 剩余（P0-2\~P0-5）→ Phase 2 → Phase 3

### Phase 0（部分）+ Phase 2 —— ✅ 代码完成（未经真机推理验证）

**Phase 0 已完成项**：

- ✅ P0-2/P0-5：`flutter_onnxruntime` 要求 Dart ≥3.7.0（本项目 3.5.3），**换用
  `onnxruntime: ^1.4.1`**（纯 FFI 绑定，自带 Windows DLL，Dart ≥2.17 兼容）

- ✅ P0-3：`mobilenetv3_sce_dist` 模型（16,827,558 bytes）+ `meta.json` + MIT LICENSE
  已就位于 `assets/models/`，SHA256 `31814BA0…DEFDE4E`

- ⏸ P0-1（cacheWidth 马赛克实测）：与 Phase 1 真机视觉验证合并进行

- ⏸ P0-4（准确率抽查）：见本节末尾「真机推理抽查方案」

**Phase 2 新增/修改**：

- 新增 `lib/services/nsfw/image_preprocess.dart`：解码→squash 缩放→(v/127.5−1)
  归一化→NCHW float32；`decodeImage` 对坏数据抛 RangeError 已兜住统一转 FormatException

- 新增 `lib/services/nsfw/nsfw_score_store.dart`：路径键缓存（**偏离方案 §4.3 的
  sha256 内容键**——渲染层 build 内需同步查询，内容哈希做不到；代价是同图换路径重判一次），
  JSON 落盘 `data/cache/nsfw_scores.json`，`modelVersion` 变更整表失效，2s 去抖保存

- 新增 `lib/services/nsfw/nsfw_model_service.dart`：常驻 worker isolate（协议 Map 消息，
  弃用包自带 OrtIsolateSession 的 broadcast stream——并发串包）+ 串行队列并发 1 +
  连续 3 次失败降级 unavailable + 30MB 解压炸弹防护；输入尺寸**运行时 FFI 读
  SessionGetInputTypeInfo**（meta.json 未写 input\_size），worker 内加载/推理

- `nsfw_filter_service.dart`：新增 `modelEnabled`（key=`nsfw_model_enabled`，默认开）

- `nsfw_image.dart`：L0 判定通过后再查 L1 图片级缓存，命中 r15/r18 同样打码

- `screenshot_fetch_service.dart` / `cover_download_service.dart`：下载落盘后
  `enqueueClassification`（幂等 + 静默降级，绝不影响下载主流程）

- `settings_modal.dart`：「NSFW 内容保护」卡片内新增「图片智能判定（本地模型）」开关

  - 实时状态行（未启用/加载中/已就绪·输入 N×N/不可用·已降级）

- `path_helper.dart`：`modelsDir` / `nsfwCacheFilePath`

- 测试：`nsfw_image_preprocess_test.dart`（3 用例）+ `nsfw_score_store_test.dart`（3 用例）

**验证**：analyze（改动文件）0 error；NSFW 测试 23/23 通过；
`flutter build windows --release` 成功，`onnxruntime.dll`(9.18MB) 在 Release 根目录、
模型 asset 在 flutter\_assets 中（安装包增量约 25MB）。

**未验证**：❌ 真机模型推理（模型释放→worker 就绪→实际打码链路）未跑过；
❌ P0-4 准确率抽查未做。

**真机推理抽查方案（P0-4，交用户执行）**：

1. `flutter run -d windows`（或直接跑 Release exe）→ 设置 → NSFW 内容保护 →
   确认「图片智能判定」状态行显示「已就绪 · 输入 ×…」
2. 找一个已知 R18 作品触发封面/截图重新下载（或删除
   `data/cache/nsfw_scores.json` 后重启），观察图片是否自动打码
3. 抽查 10 张正常 CG + 10 张 HCG 的判定准确率，低于 60% 则回退重选模型

***

## 附：参考资料

| 资源                               | 地址                                              | 用途              |
| -------------------------------- | ----------------------------------------------- | --------------- |
| `flutter_onnxruntime`            | `pub.dev/packages/flutter_onnxruntime`          | 推理运行时（v1.8.4）   |
| `deepghs/anime_rating`           | `huggingface.co/deepghs/anime_rating`           | 主模型（MIT）        |
| ModelScope 镜像                    | `modelscope.cn/models/deepghs/anime_rating`     | 国内下载            |
| `deepghs/anime_censor_detection` | `huggingface.co/deepghs/anime_censor_detection` | Phase 3 可选（MIT） |
| imgutils 文档                      | `dghs-imgutils.deepghs.org`                     | 预处理与归一化参考实现     |
| `image` 包                        | `pub.dev/packages/image`                        | 纯 Dart 图像处理     |

