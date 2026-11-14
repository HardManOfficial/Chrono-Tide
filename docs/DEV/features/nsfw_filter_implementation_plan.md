# NSFW 内容过滤系统 · 开发方案

> **文档性质**：实施方案。**Phase 1（L0 元数据层 + 渲染层）已于 2026-09-03 完成代码，
> 未经真机视觉验证**，实施状态见 §14。
> **编写日期**：2026-09-03　**项目版本**：v2.0.1　**适用目录**：`D:\CTLIB`
> **前置必读**：`AGENTS.md`、`docs/DEV/SESSION_HANDOFF.md`、`docs/DEV/STATUS_MAP.md`
>
> ⚠️ **执行者注意**：本项目强制两段式流程（只读审计 → 输出变更计划 → **等用户批准** → 执行）。
> 后续 Phase（2/3）开工前仍需输出《变更计划》给用户确认。

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

### v2.3（判定规则 r3 · 应用版本 v2.1.8，2026-09-07）—— 判定精准化

用户反馈：真裸露图漏处理 + 正常风景/动物图被处理。24 张真实照片 +
Python ORT 实测定位，两个根因均与直觉相反：

1. **漏检根因是 v2.2.1 自建的 `applyR18Gate`**：非敏感真实照片最高分仅
   0.07~0.17（模型本身零误报），该门却把真裸露图上 0.3~0.55 的单框检出
   清空成"判定健康"。**已删除。结论：不要再加自定义复核门**，误报风险由
   模型官方 F1 最优阈值承担。
2. **"正常图被处理"实为未判定模糊等待态**：480 分辨率对几十像素的敏感
   部位出结果慢 + 5s 看门狗太慢，图长时间停在模糊预览被当成"被处理"。

变更清单：

- 模型 `censor_detect_v1.0_n`(12MB, F1 0.80) → `censor_detect_v1.0_s`
  （44.6MB, F1 0.83，MIT），`expectedBytes=44586353`
- 置信度阈值回归**官方 F1 最优点 0.238**（上游 `threshold.json`），且不再
  从 prefs 读取——判定口径全局唯一，杜绝"同一张图你的糊了我的没糊"
- 推理分辨率 480 → **640（官方默认）**；预处理由拉伸 resize 改**等比缩放**
  （短边 ceil 对齐 32），decode 按 `imgW/inferW`、`imgH/inferH` 双轴还原
- 模糊看门狗 promote 5s → **800ms**（30s 放行兜底不变）
- `modelSignature` → `r3/...`，存量判定缓存整表作废全量重判
- 应用版本 → 2.1.8（pubspec + ChronoTide_Setup.iss；安装包增量约 +33MB）

**验证**：analyze（NSFW 全目录）0 error；test/services/nsfw 87/87、
test/widgets/nsfw 49/49（全链路推理用例真实跑通 s 模型）。
**未验证**：❌ 打包 + 真机（首启 r3 签名触发全量重判，封面短暂模糊属预期）。

***

### v2.3.3（应用版本 2.1.11）——用户标准校准：阈值 0.36

- **标准**（用户 `研究图片/判定标准.txt` + 43+26 张参考图）：露点/全裸/半裸/
  透视 = 敏感；性感擦边 = 健全；误报绝对优先。
- **实证**：双胞胎封面（健全 0.3464 vs 敏感 0.3783）证明点检测器对该边界
  不可约；640 等比为最优预处理；分类器（anime_rating mobilenetv3）与肤色
  否决两条补救路线实测失败。
- **校准**：`defaultConfThreshold` 0.278→**0.360**（误报 2→1、召回 22/26；
  库内误拦 5→2）；签名含阈值自动作废存量缓存。
- **能力边界（勿再调参）**：无点半裸/蜷缩裸 4 张结构性漏检；卡通图形
  （弹丸熊 0.637）误报。根治 = 更强模型（caformer 50MB+）或白名单功能。

### v2.3.2（应用版本 2.1.10）——渲染修复：模糊雾溢出

- **现象**：详情弹窗封面模糊底部溢出到按钮区（用户截图 QG）。
- **根因**：`ImageFiltered` 合成层绘制边界 = child 外扩约 3×sigma
  （σ20 → 60px）；`RenderStack.paint` 仅在布局溢出时才裁剪
  （stack.dart:659），模糊不改布局尺寸永不触发。非布局溢出，是合成溢出。
- **修复**：`_blurred()` 用 `ClipRect` 包 `ImageFiltered`（无条件裁剪），
  覆盖未判定预览与判定敏感两条模糊路径。零布局影响。
- **验证**：analyze 0 error；NSFW widget 52/52（新增 3 条回归）+
  services 87/87。

***

## 15. v2.4 模型完全替换（2026-09-07，v2.1.12）

### 15.1 动机与选型
用户拍板"完全替换成更强大的模型，但控制体积"。v2.1.11 已证明 YOLO
点检测器存在结构性盲区（全裸无露点=漏、卡通图形=误报）。同场实测
（D:/nsfw_model_eval/，脚本 nsfw_model_eval.py / quantize_eval.py /
size_experiments.py）：

| 方案 | 体积 | 延迟/张 | 参考集（43健全/26敏感） | 判定 |
|---|---|---|---|---|
| censor_detect_v1.0_n @0.360（旧） | 12.1MB | 29ms | 误报 1、召回 22 | 基线 |
| anime_dbrating caformer_s36 fp32 @0.60 | 149.6MB | 221ms | 误报 0、召回 26/26 | 质量天花板，体积否决 |
| 同上 int8 动态量化 | 38.2MB | 1258ms | 误报 1、间隙收窄 | 本机 CPU 无 VNNI，弃 |
| 同上 fp16 | 75.1MB | 1511ms | 0/26 | CPU 逐算子 Cast，弃 |
| **anime_dbrating mv3 @0.648（选定）** | **16.8MB** | **16ms** | **误报 0、召回 25/26** | ✅ |
| anime_rating caformer_plus @0.65 | 149.6MB | 222ms | 召回 19/26 | 数据集无人工过滤，弃 |

⚠️ 纠偏 v2.1.11 的"分类器路线失败"结论：该结论仅适用于 anime_rating 的
r18 单列分数与旧预处理；anime_dbrating 的 q+e（questionable+explicit）
双列分数 + 384 方形 + half 归一化分离度优秀。half 归一化 (x/255-0.5)/0.5
对两族模型都优于 imagenet 均值。

### 15.4 v2.1.14 UI 微调与性能瘦身

- 角标：敏感态 NSFW 徽标由右上角移到**左上角**（卡片右上角多被自身元素
  占用）；右下角沙漏/揭示角标不动。
- 模糊：`_fullBlurSigma` 20→14、`fallbackBlurSigma` 12→10（合成成本与
  sigma 正相关；14 仍远超可辨认阈值；外扩 60px→42px）。
- 性能：`_workerCount` 3→2、`intraOp` 2→1（常驻满载线程 6→2，模型常驻
  内存 ≈50MB→≈33MB）；单张 16~30ms 下 2 worker 仍有 60~120 张/秒。
- 测试侧：`workerSlotsForTest` 消除并发测试对 worker 数的硬编码。

### 15.3 ⚠️ v2.1.12 事故与 v2.1.13 修复（全量漏拦：二次 softmax）

v2.1.12 上线即翻车：「NSFW 完全没有工作」＝缓存 403 条全判健康、0 条带框。

- **根因**：模型输出**已是 softmax 概率**（图内烧了 softmax；真 R18 封面
  实测 raw=[0.070,0.065,0.762,0.103]，min≥0、sum=1.000），后处理却无条件
  再 softmax → q+e 0.864→0.603 跌破 0.648 → 全量漏拦。15.2 的分离间隙
  [0.6287,0.6680] 是 python 评测"概率直用"口径测的，Dart 未对齐。
- **修复**：`_normalize4` 概率自检（≥0 且 sum≈1±0.02 → 直用，否则
  softmax）；签名 r5→**r6** 作废错误缓存；4 个回归测试（真实输出数值
  作用例，旧实现必挂）。138/138 通过。
- **铁律**：换模型必须先用真实输出实证"概率 or logits"（看 min/sum）；
  端到端测试必须含"敏感命中"方向断言。

### 15.2 判定口径（r5/anime_dbrating_mv3_v0/384/0.648）
- 预处理：整图**拉伸** 384×384（timm PIL resize 语义；等比缩放退役），
  归一化 (x/255-0.5)/0.5；
- 分数 = softmax(questionable) + softmax(explicit)，即 danbooru 语义下
  "擦边以上"的程度；sensitive（内衣/泳装）计健全侧，对齐用户标准；
- T=0.648 = 分离间隙 [0.6287, 0.6680] 中点（误报 0/43，召回 25/26；
  1 张漏检为全裸无点结构盲区，与旧模型同源）；
- 敏感 → **全图合成框**（NsfwBox(0,0,imgW,imgH)，conf=分数）：v2.2 起渲染
  "敏感即整图模糊"不消费 bbox，合成框复用既有存储/通知/签名链路，
  **零 schema 变更、零渲染层改动**。

### 15.3 库内 42 封面人眼复核（按用户判定标准）
- 新拦下（旧模型漏检）：plugin 0.02→0.869（**性爱特写**）、
  Love×Holic 0.318→0.866（白浊微比基尼，questionable）；
- 保持拦截：ママラブ！２、Managed；
- 放行（旧模型曾误拦或边缘）：魔女的夜宴/MNDYY 0.588<0.648 ✅；
- 新增边界误拦（阈值不可分，阈值侧无解）：QG 妻しぼり 0.832（内裤擦边）、
  末世孤雄4 0.822（强抱截图当封面）→ 根治推荐 per-image 白名单。

### 15.4 代码改动
- `assets/models/`：删 n 模型；增 `anime_dbrating_mv3_v0.onnx`（16,832,684B，
  OpenRAIL，来源与口径见同名 .LICENSE）；pubspec 资产名同步；
- 新 `lib/services/nsfw/nsfw_rating_postprocess.dart`（softmax/阈值/全图框，
  常数注释含完整校准依据）；删 `yolo_postprocess.dart` 及其测试；
- `nsfw_detection_service.dart`：384 方形解码、(x/255-0.5)/0.5 归一化、
  评分后处理；`nsfw_settings.dart`：modelId/签名 r5、NsfwInferSize→单值
  accurate(384)；`nsfw_box.dart`：labelNames→四级 rating 标签；
- 版本 2.1.12。验证：analyze 0 error、NSFW 134/134
  （含真实 ONNX 链路集成测试——新模型在 Dart ORT 加载推理成功）。

### 15.5 遗留与升级路径
- 体积下限的强度上限即 mv3（16.8MB）；caformer fp32（149.6MB，参考集
  满分 26/26、库内误拦少 1）同场数据已留档（clf_scores.csv），若用户
  接受体积可直接换文件+升 T=0.60+签名 r6；
- int8/fp16 压缩在本机 CPU 已实测否决，勿再试；
- 白名单/手动重判功能仍是对边界样本的唯一根治路径。

## 16. v2.5 揭示入口改造：右下角角标按钮（2026-10-04 凌晨）

> 注：工作模式本身（v2.1.15）此前**没有档案章节**（§15 是 v2.4，之后直接跳到本节）。
> 本节顺带把它的渲染语义记全。

### 16.1 动机：能力早就有，入口错了两处

「点击显示原图」在 Phase 1 就有了（`enableReveal` + `_revealed`），但两处不完善：

1. **入口是整图 `GestureDetector`** —— 它会吃掉调用方自身的单击/双击/长按。库页/探索页
   网格卡片有「点进详情」语义，因此被迫一律关掉（`library_page.dart` 旧注释原文：
   「网格卡片一律不开 enableReveal」）⇒ 用户在卡片上根本用不到揭示。
2. **内容图（截图类）从未接上** —— `contentKind` 默认 `NsfwContentKind.image`，敏感态在
   `build()` 第 3 步就 `return _buildBlurredPreview(sensitive: true)`，永远走不到
   `_decorate` ⇒ `screenshot_carousel.dart:440/489` 传的 `enableReveal: true` 是**死代码**。

### 16.2 设计（用户拍板）

| 模式 | 角标出现时机 | 点击效果 |
| --- | --- | --- |
| 纯净模式 · 封面类（`cover`） | 恒常显示（本身就是遮蔽指示） | 显示原图 ⇄ 恢复遮蔽 |
| 纯净模式 · 内容图（`image`） | 恒常显示（与左上角 NSFW 徽标并存） | 同上 |
| 工作模式（`work`） | **鼠标悬浮**或已揭示时 150ms 淡入 | 占位图 ⇄ 真实图片 |

- 角标 ＝ **唯一**揭示入口（`_revealBadge()`，key `nsfw_reveal_badge`）；整图手势删除。
- 可点性 ＝ 接入点 `enableReveal` × 用户总闸 `NsfwSettings.allowReveal`。任一为假时角标
  退回 `IgnorePointer` 纯指示，**绝不抢点击**。
- 「检测中」（未判定）的模糊预览**永不**可揭示 —— 那是 fail-closed 的检测窗口
  （`:697-699` 分支），放行等于未判定就把原图直出。
- 新增 `_showingRevealed = _revealed && _revealEnabled`：关总闸 / 换模式**立即**回到遮蔽态，
  不留「开关已关、原图仍亮着」的窗口。

### 16.3 安全边界（务必保留）

工作模式**不做任何判定、不加载模型、不入队推理**，因此它的揭示是**无差别**的：
任何图悬浮点一下就能看到原图，没有模型兜底。这是用户明确选择的行为
（办公场景下由使用者自己负责屏幕）。**不要**「顺手」给它补判定 —— 那会毁掉
工作模式「最轻量」的定位。

### 16.4 接入点清单

| 接入点 | 开启揭示 |
| --- | --- |
| `library_page.dart:4226` 库页网格卡片封面 | ✅ 本轮新开 |
| `discover_page.dart:2332` 探索页卡片封面 | ✅ 本轮新开 |
| `home_page.dart:514` 首页卡片封面 | ✅ 本轮新开 |
| `game_detail_dialog.dart:1334/1353/3891` 详情封面、截图网格 | ✅ 原有 |
| `screenshot_carousel.dart:440/489` 截图轮播 | ✅ 原有，**v2.5 起才真正生效** |
| `home_page.dart:1387` 最近游玩小缩略图（50×70） | ❌ 有意不开（20px 角标会盖住小图） |
| 导入 / 发布 / 元数据预览、系列条、大厅封面、BPM 大屏 | ❌ 本轮不动 |

### 16.5 验证

| 项 | 结果 |
| --- | --- |
| 进程内 analyzer（6 文件） | ✅ errors=0（余下 warning/info 为 HEAD 存量未使用导入等） |
| `flutter analyze` / `flutter test` | 🔴 **本机跑不了**：C 盘 100% 满（剩 391MB）→ `CreateFile failed 231` |
| 离线 widget 断言探针 `.workbuddy/probe_nsfw_v25/nsfw_v25_probe.dart` | ✅ **9 场景 / 38 断言全绿**（flutter_tester + frontend_server） |
| 真机走查 | ⏳ 未做 |

探针覆盖：封面揭示切换、整图点击不揭示、内容图揭示、检测中不可揭示、
工作模式悬浮揭示、开关闸门（接入点 / 总闸）、关闸立即复位、工作模式零推理入队。

### 16.6 遗留

- 角标外观在两种模式下**完全一致**（同一个 `_revealBadge()`）：用户无法从角标本身
  区分「这是 AI 判定过的敏感图」还是「这是工作模式的占位图」。若要区分，可给工作模式
  换一个图标（未做）。
- `home_page.dart:1387` 的小缩略图仍会显示**不可点**的角标 —— 历史行为，且
  `width: double.infinity` 绕过了 `_minBadgeSlot` 判断。要不要一并收紧待定。

### 16.7 桌面端交互提示

`tester.tap` 用的是触摸指针，**不会**触发 `MouseRegion`。测试工作模式悬浮必须用
`tester.createGesture(kind: PointerDeviceKind.mouse)` + `moveTo`；离线探针里则必须给
每次悬浮换一个**新的 device**（`MouseTracker._MouseState` 按 device 分桶，复用 device
会触发 `(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)` 断言）。

## 17. v2.6 分级判定：单一强度 · 双阈值 + explicit 硬门（2026-10-15）

> 背景：用户反馈纯净模式「强度控制不完善」，兼有**误判**（正常图被拦）与
> **漏判**（露点图未处理，探索库尤甚）。用户拍板：**只保留一个强度**，
> 不向用户暴露分级选择。方案见 `nsfw_purity_mode_optimization_plan.md`。
> 提交 `f33e337`；版本号消歧 `5002565`。

### 17.1 判定语义（三档，内部标记）

旧口径只有一个布尔：`score = P(questionable)+P(explicit) >= 0.648` 即处理。
v2.6 在同一模型输出上做**三档**判定，但仍**只有一个处理下限**（不漏判）：

| tier | 触发条件 | 渲染 |
| --- | --- | --- |
| `none` | `score < 0.648` | 不处理，原图直出 |
| `suspect` | `score >= 0.648` 且未命中硬门 | **仍模糊** + 琥珀色「疑似」徽标 |
| `blocked` | `P(explicit) >= 0.5` **或** `score >= 0.85` | **仍模糊** + 红色「NSFW」徽标 |

- 常量：`explicitBlockThreshold = 0.5`、`highConfBlockThreshold = 0.85`；
  处理下限沿用 `defaultFlagThreshold = 0.648`（**不低于**旧口径 ⇒ 零漏判回归）。
- `NsfwTier` 枚举 + `NsfwBox.tier`（默认 `blocked`，`isHandled` getter）。
- **fail-closed**：suspect 与 blocked **模糊强度完全一致**，tier 只改徽标文案/配色，
  绝不因分级而放行原图。
- 单一强度 ⇒ **无 UI 开关、无设置项**，用户无从选择。

### 17.2 阈值来自实测（M4）

70 张样本（39 判定敏感 / 31 判定干净）离线跑模型 + 客户缓存真值比对：

| 组 | P(explicit) 范围 | 结论 |
| --- | --- | --- |
| 干净组（31） | max **0.212** | — |
| 明确露点子集 | min **0.533** | ⇐ 与干净组之间存在**隔离带**，0.5 落在带内安全 |

- 拼图人工核验：`P(e) >= 0.5` 组（n=16）100% 为真·明确露点；
  `P(e) < 0.5 且 score >= 0.648`（n=23）= eroge 封面 / 擦边。
- 离线回放（用客户真值分数）：**FP(误拦)=0，FN(漏处理)=0**，
  分布 none=31 / suspect=23 / blocked=16。

### 17.3 缓存与序列化

- `modelSignature` 由 `r6` → `r7`（`nsfw_settings.dart`）：新规则会改变
  「是否处理」的判定，旧缓存整表作废重判。
- `NsfwBox.toJson` **仅当 tier != blocked 时**写 `'t'` 键（blocked 省略，省体积）；
  `fromJson` 缺 `'t'` 键 ⇒ 默认 `blocked` ⇒ **旧缓存零迁移**、行为不变。
- worker 协议不变（tier 随既有 toJson/fromJson 流转）。

### 17.4 验证

| 项 | 结果 |
| --- | --- |
| 进程内 analyzer（9 文件） | ✅ errors=0 / warnings=0 |
| 纯 Dart 单测复刻 `dev_probe/nsfw_m4/verify_tier_unit.dart` | ✅ 22/22（常量、三分层、decode 产出、fail-closed 守卫、tier 向后兼容） |
| 离线回放 `replay_tier.dart` | ✅ FP=0 / FN=0 |
| `flutter analyze` / `flutter test` | 🔴 本机仍报 231（环境禁止建匿名管道），改环境恢复后补跑 |
| 真机走查 suspect「疑似」徽标 | ⏳ 未做 |

### 17.5 待办（未开工）

- P2：人工标注回归集（当前 M4 为自动分组 + 抽检）。
- P3：探索库全量重扫（本次未覆盖库内历史缓存）。
- P4：分辨率一致性（M3 发现探针重推理与客户缓存分数差约 0.06–0.07，
  疑为 resize 插值差异；本次回放改用客户真值规避，根因未锁）。

## 18. v2.7 UI 统一：揭示角标左上角 · 默认可揭示 · 手动模糊下沉（2026-10-16）

> 背景：用户反馈三处 UI 问题 —— ① 隐藏/显示（眼睛）按钮在**右下角**，被探索页
> 星级评分等角标遮挡；② 可点击行为不一致（封面相册等站点显示了角标却点不动）；
> ③ 图库「模糊」与 NSFW 打码是两套互不相干的机制。用户拍板：①「沉浸模式」按
> 「纯净 + 工作」两模式一并处理；② 改**默认开启揭示**；③ 手动模糊**下沉进
> [NsfwImage] 且独立于总闸**。提交 `35eb21d`。

### 18.1 改动 1：眼睛按钮 右下角 → 左上角

全部集中在 `lib/widgets/nsfw/nsfw_image.dart`：

| 渲染路径 | 旧 | 新 |
| --- | --- | --- |
| `_buildBlurredPreview`（内容图敏感） | 左上角徽标 + **右下角**眼睛 | 合并为单个 `Positioned(left:4,top:4)` = `Row[徽标, 4px, 眼睛]` |
| `_buildBlurredPreview`（检测中） | **右下角**沙漏 | 沙漏一并移左上角（同样会被星级角标压住） |
| `_decorate`（封面类敏感） | **右下角**眼睛（无徽标） | 左上角眼睛 |
| `_buildWorkPlaceholder`（工作模式） | **右下角**浮出眼睛 | 左上角浮出 |

- 敏感徽标抽出为 `_sensitiveBadge(bool explicitBlocked)`；键
  `nsfw_nsfw_badge` / `nsfw_suspect_badge` 保持不变。

### 18.2 改动 2：可点击行为统一（默认开启揭示）

- `NsfwImage.file` / `NsfwImage.network` 的 `enableReveal` 默认 `false → true`。
- 效果：封面相册、BPM 大屏 5 处、截图网格、系列/CT/大厅/安装中心等**全部
  站点无需改一行**即自动获得「角标可点」，消除「显示了角标却点不动的死角标」。
- 唯一例外：`home_page.dart` 最近游玩 40×55 小缩略图加 `showBadge: false`
  （该处宽高传的是 `double.infinity`，不显式关闭会被槽位判定误判为大槽位）。
- 全局闸 `NsfwSettings.allowReveal` 仍是唯一总闸；关闭时角标退回纯指示。

### 18.3 改动 3：手动「模糊」下沉进 NsfwImage（独立于总闸）

- `game.isBlurred`（图库「模糊」）此前由调用方在外层套 `ImageFiltered(sigma 12)`，
  无徽标、不可揭示，与 NSFW 打码（sigma 14）是两套机制。
- 现将 `manuallyBlurred` 语义改为：本组件统一渲染 = 同一 sigma 14 + 左上角
  灰色「模糊」徽标（键 `nsfw_manual_blur_badge`）+ 角标按钮（可揭示）。
- 新增 `_buildManualBlur()`；`build()` 首行
  `if (widget.manuallyBlurred) return _buildManualBlur();` **排在总开关判断
  之前** ⇒ **独立于 `NsfwSettings.enabled`**：用户显式标记优先级最高，关掉
  NSFW 总闸也保留该图模糊。揭示仍受 `allowReveal` 约束（与其它场合一致）。
- 删除三处外层 `ImageFiltered` 并原地接线：`library_page.dart`（卡片封面）、
  `home_page.dart`（`_buildCoverCard`）、`library_ghost_card.dart`（拖拽占位）。
  `home_page` 的装饰性背景（`_buildBlurredBackground`，本身已有 `BackdropFilter`）
  **不动**。
- 因不再使用 `ImageFilter`，`library_page.dart` / `library_ghost_card.dart` 的
  `import 'dart:ui';` 一并移除（避免 `unused_import`）。
- `settings_modal.dart` 文案「点右下角眼睛角标」→「点左上角眼睛角标」。

### 18.4 明确不改

NSFW 判定链路 / 阈值 / 检测缓存 / `modelSignature`（v2.6 不动）、工作模式
「零推理」性质、`NsfwSettings` 持久化 schema、BPM 三段式动画。

### 18.5 验证

| 项 | 结果 |
| --- | --- |
| 进程内 analyzer（7 文件） | ✅ errors=0（12 warning / 2 info 全为既有，已逐条核对不在本次 diff 区块） |
| `flutter test test/widgets/nsfw/nsfw_image_test.dart` | ✅ 63/63（含新增「手动模糊下沉 + 独立总闸」「左上角位置回归」） |
| `flutter test test/services/nsfw/` | ✅ 68/68 |
| `library_card_key_identity` / `settings_theme_cards_layout` | ✅ 通过 |
| `cover_preview_overlay_test` / `cover_gallery_overlay_test` | ⚠️ 2 例**既有**失败（HEAD 上同样失败，与本次无关） |
| `bpm_page_zone_wiring_test` | ⚠️ 1 例**既有**失败（HEAD 同样失败） |
| 真机走查（探索页星级不再遮挡 / 封面相册可揭示 / BPM / 工作模式 / 图库模糊） | ⏳ 未做 |

### 18.6 遗留

- 真机走查待做（尤其左上角是否与各站点既有元素冲突 —— 本次最大回归面）。
- `cover_*_overlay` / `bpm_page_zone_wiring` 的既有失败与本特性无关，
  另行处理（不在本次范围）。

## 19. v2.7.1 点击阻断修复：装饰遮罩必须 `IgnorePointer`（2026-10-16）

> 起因：用户实测反馈 —— 探索库、库页封面、探索详情封面上的「眼睛」揭示角标
> **看得见、点不动**。v2.7 声称「统一可点击」，但在这三处没有真正生效。

### 19.1 根因（已实测钉死）

角标按钮**自身逻辑没问题**（`enableReveal` 默认 `true`、`allowReveal` 默认
`true`、`_revealBadge()` 已挂 `GestureDetector(opaque, onTap)`）。问题是
**调用方在 `NsfwImage` 之上又叠了一层全尺寸装饰遮罩**：

| 站点 | 遮罩 | 位置 |
| --- | --- | --- |
| 探索库卡片 | `Container(color: AppColors.background.withOpacity(0.33))` | `discover_page.dart:2534` |
| 探索详情封面 | `Container(color: Colors.white.withOpacity(0.38))` | `game_detail_page.dart:1808` |
| BPM 大屏首页卡片 | `AnimatedOpacity(ColoredBox(BpmColors.cardMask))` | `big_picture_home.dart:986` |

`Container(color:)` → `ColoredBox`，其 RenderObject 用
**`HitTestBehavior.opaque`**；而 `Stack.hitTestChildren` **自上向下**扫描、
命中第一个子节点就停止 —— 装饰层先被命中，其下的 `NsfwImage` 根本没进入
命中测试，角标因此永远收不到 pointer 事件。

> 对比：`Container(decoration: BoxDecoration(color: …))` → `DecoratedBox`，
> **不吞**点击。所以多数卡片外框没这个问题。

**实测对照**（临时 widget 用例，四组）：

| 用例 | 结果 |
| --- | --- |
| 敏感封面（无遮罩）点角标 | ✅ 可揭示 |
| 敏感封面 **+ 叠 `Container(color:)`** | ❌ 点不动（复现根因） |
| 遮罩包 `IgnorePointer` 后 | ✅ 可揭示（修复有效） |
| 本地库页卡片真实结构（`Positioned.fill` + `ClipRRect` + `Stack`） | ✅ 本就可点 |

### 19.2 改动

**A. 三处装饰遮罩包 `IgnorePointer`**（纯视觉层不该接收指针事件）：

- `discover_page.dart`：探索库卡片的压暗层。
- `game_detail_page.dart`：探索详情封面的提亮层。
- `big_picture_home.dart`：BPM 首页卡片的压暗层。

**B. 左上角让位**（角标自 `left:4` 起、宽约 20px）：把**同占左上角**的
调用方指示徽标右移到 `left:30` 并包 `IgnorePointer`（其内部 `Text` 也可能
命中吞掉点击）：

- `discover_page.dart`：「已安装」徽标。
- `library_page.dart`：「存储状态」胶囊、「编辑模式选中勾选」。

**C. 死角标清理**：`home_page.dart` 的**装饰性毛玻璃背景**
（`_buildBlurredBackground`）被 `BackdropFilter` 糊掉又被半透明遮罩压住，
其上角标既看不见也点不到 —— 改为 `showBadge: false`
（`_buildCoverImage` / `_buildBannerImage` 新增 `showBadge` 参数）。

**D. 约定固化**：`nsfw_image.dart` 头部新增硬性约定「叠在图片之上的装饰层
**必须**包 `IgnorePointer`」，并新增回归测试
`test/widgets/nsfw/nsfw_image_scrim_contract_test.dart`（有/无 `IgnorePointer`
两组对照）。

### 19.3 明确不改

NSFW 判定链路 / 阈值 / 检测缓存 / `modelSignature`（v2.6 不动）、
`NsfwSettings` 持久化 schema、BPM 三段式动画、遮罩的视觉参数（颜色/透明度）。

### 19.4 验证

| 项 | 结果 |
| --- | --- |
| 进程内 analyzer（6 文件） | ✅ 0 error（12 warning + 3 info 全在既有代码，已核对不在本次 diff 区块） |
| `test/widgets/nsfw/` + `test/services/nsfw/` | ✅ 133/133（含新契约测试 2 例） |
| `big_picture` + `explore_hall` + `game_detail` + `library_card` | ⚠️ 5 例失败，**`git stash` 回 HEAD 复跑同样失败** ⇒ 既有失败 |
| 真机走查（探索库 / 库页 / 探索详情角标可点） | ⏳ 待做 |

### 19.5 遗留

- 真机走查（本次最大回归面仍是「左上角排布」）。
- BPM 首页的「操作引导」角标（`big_picture_home.dart`，`top/left: 8`）与揭示
  角标仍可能重叠 —— BPM 以手柄/键盘为主，鼠标点角标罕见，暂未动。
- §18.6 提到的「左上角是否与既有元素冲突」在本轮得到确认（正是 B 项修的东西）。

## 附：参考资料

| 资源                               | 地址                                              | 用途              |
| -------------------------------- | ----------------------------------------------- | --------------- |
| `flutter_onnxruntime`            | `pub.dev/packages/flutter_onnxruntime`          | 推理运行时（v1.8.4）   |
| `deepghs/anime_rating`           | `huggingface.co/deepghs/anime_rating`           | 主模型（MIT）        |
| ModelScope 镜像                    | `modelscope.cn/models/deepghs/anime_rating`     | 国内下载            |
| `deepghs/anime_censor_detection` | `huggingface.co/deepghs/anime_censor_detection` | Phase 3 可选（MIT） |
| imgutils 文档                      | `dghs-imgutils.deepghs.org`                     | 预处理与归一化参考实现     |
| `image` 包                        | `pub.dev/packages/image`                        | 纯 Dart 图像处理     |

