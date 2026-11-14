# 动态背景图（GIF）支持 —— 实现方案

> 状态：**Phase 0-4 已落地（2026-09-17），待真机走查（Phase 5）**
> 日期：2026-09-17（方案）/ 2026-09-17（实施）
> 决策（用户已拍板）：① 渲染 **零依赖原生 `Image`**；② 上传 **中等门槛 + 超限拒绝**；
> ③ 格式 **静态 jpg/jpeg/png/webp/bmp + 动图仅 GIF**（动画 WebP/APNG 只预留枚举位，不启用）；
> ④ R4 减少动效开关 **做，但作用范围仅「GIF 动态背景」**，不含界面过渡动效（ADR-010）
> 适用：`D:\CTLIB`，Flutter 3.24.3 / Dart 3.5.3（项目内 `./flutter/bin/flutter.bat`）

---

## 实施状态（2026-09-17 更新 —— 后半段章节已按实测修订，阅读时以本节为准）

| Phase | 状态 | 产出 |
|-------|------|------|
| Phase 0 技术验证（V1-V8） | ✅ 完成 | `dev_probe/RESULTS.md`（已提交）；3 项结论推翻了方案原文，见下 |
| Phase 1 校验层 | ✅ 完成 | `lib/theme/background_media.dart`（662 行）+ `test/theme/background_media_test.dart`（20/20） |
| Phase 2 模型 + 渲染 | ✅ 完成 | `animated_background_image.dart`（115 行）、`background_image_config.isAnimated`、resolver 动图分支 + R1/R6/R7 |
| Phase 3 上传 UI | ✅ 完成 | 两个上传入口 picker 收窄 + 门槛拒绝精确回显 + 警告档提示 |
| Phase 4 治理与释放 | ✅ 完成（R3 除外） | **R5 ✅**（编辑器静态首帧）、**R4 ✅**（全局「减少动效」开关，见 §4.3）；**R3 掉帧降级 ❌ 用户确认不做**（口径无法归因到背景图，会误判） |
| Phase 5 真机走查 | ❌ 未走查 | 清单见 §11 |

**实测对方案原文的 6 处修订（已全部落到代码里）**：

1. 🔴 动图分辨率门槛 **4096×4096 → 1920×1080**（§6、§8 的 4096 作废）。
   依据：V2/V2b/W2 引擎+真机双重确认 **`cacheWidth` 对多帧图不生效**，
   4096² 上限等于内存炸弹。静态图维持 4096²。
2. 🔴 动图分支 **不得使用 `cacheWidth`**（§4.3 的 `cacheWidth:1920` 作废）——
   除了无效，它还会把 provider 变成 `ResizeImage` 形态，使三个共用渲染点
   各自起一个解码器。改用 `FilterQuality.low` + `gaplessPlayback: true`。
3. 🔴 R7 释放改为「**只在配置变更时延迟 evict**」，**不在 `dispose` 里 evict**
   （§4.4 原文 "didUpdateWidget / dispose 时 evict" 的 dispose 一半作废）——
   页面切换/State 重建也会走 dispose，在那里 evict 会导致重进时重新解码。
   依据：W4/V6 实测 ImageCache **只按首帧计费**，动图真实内存对它不可见。
4. ✅ 校验层**不加 isolate**（§5.2 的 "isolate 内跑" 作废）——实测扫描 2ms 级。
5. ✅ `precacheImage`（`background_image_resolver.dart:110`）**保持不动**——
   §1.1 怀疑的存量 bug 经 W6 真机实测（27ms）**不存在**。
6. ✅ R1（动图 + 模糊 → 静态首帧）保留 —— V5/W7 实测 σ20 时 raster p95 尖峰 = 基线 **8.2 倍**。

**§13 开放问题的最终答复**：Q1 存量 `.gif` → **升级后直接按动图播放**；
Q3 白名单放开 webp/bmp **连带放开主题包导入 → 用户已确认接受**；
Q4 分辨率上限 → 已按 V2 结果下调到 1920×1080（见修订 1）；
Q5 动画 WebP / APNG → **只留枚举位，不启用**；
**Q2（是否加全局「减少动效」开关 R4）→ 做，作用范围锁定「仅 GIF 动态背景」**
（2026-09-17 拍板，落地见 §4.5 / ADR-010）；**R3 掉帧降级 → 不做**
（`SchedulerBinding.addTimingsCallback` 给的是整帧 build+raster，无法归因到背景图本身；
库页滚动 / 批量导入这两个最重场景本来就超 16ms，会误判并把背景永久降级）。

**§11 真机走查清单（Phase 5，未做）**：① GIF 背景正常循环播放、切页不重启动画；
② 模糊滑块拖到 >0 → 变静态首帧；③ 进「调整位置」编辑器 → 静止且拖拽缩放正常，
应用后回主界面恢复播放；④ 连续切 5 个主题（含 2 个 GIF 背景）→ 内存不单调上涨；
⑤ 上传越限文件 → 提示精确到维度；⑥ 上传 >60s / >30fps 的 GIF → 只警告不拒绝；
⑦ **R4**：设置→外观→「减少动效」开启后背景立刻静止（无需重进页面），
关闭后恢复播放；重启软件后开关状态与静止行为都被记住
（这是 R4 唯一的验收手段 —— 渲染侧接线无法在 flutter_tester 假 async 下断言）。

---

## 0. 结论摘要（TL;DR）

| 项 | 结论 |
|----|------|
| **现状** | `gif` **早已在上传白名单里**（`lib/theme/theme_storage.dart:372`），但全链路**没有任何一处知道它是动图**：模型无格式字段、渲染无动图分支、上传无分辨率/帧数/魔数校验。即「允许上传 GIF 且 Flutter 会把它播起来，但系统对它一无所知」 |
| **核心风险** | 不是「能不能播」，而是**播起来之后没人管**：`ImageFiltered` 模糊按帧重栅格化（`background_image_resolver.dart:266-274/336-344`）、`cacheWidth:1920` 对多帧是否生效未验证、ImageCache 对多帧图计费可能只算首帧、主题切换 300ms 内新旧两个 GIF 同时解码 |
| **方案骨架** | 新增 1 个**校验/探测模块**（isolate 内跑）→ `BackgroundImageConfig` 加**派生** `isAnimated`（**不改 schema，零迁移**）→ `BackgroundImageResolver` 加动图分支 + 4 条降级规则 → 两处上传入口接错误回显 |
| **最大不确定性** | Flutter 3.24.3 **Windows 桌面端**对多帧 GIF 的具体行为（`cacheWidth` 是否生效 / precache 语义 / ImageCache 计费 / 多渲染点是否共享解码器）。**Phase 0 必须实测证伪，未过不得进 Phase 1** |
| **改动规模** | 新增 2 文件、修改 4 文件（其中一个属 🔴 稳定区 `lib/theme/`） |
| **零依赖代价** | 无法限帧（GIF 原帧率播放，50fps 的图就是 50fps）、无法暂停 / 只播一次 / seek。**这是选型 A 的固有上限，不靠实现技巧能绕过**，只能靠「上传门槛 + 运行时降级」兜底 |

---

## 1. 背景与目标

### 1.1 目标

1. 背景图上传从「仅静态图片」扩展为「静态图片 + GIF 动态图」。
2. 明确格式范围、体积 / 分辨率 / 帧数门槛，越限时给出**精确到维度**的拒绝原因。
3. GIF 作为背景时的**播放 / 循环 / 缩放**表现可预期，且在任何配置组合下都不会把 UI 拖卡。
4. 资源（解码器 / 显存帧 / ImageCache 条目）可释放，不因反复换背景而累积。

### 1.2 非目标（本期明确不做）

| 不做 | 理由 |
|------|------|
| 动画 WebP / APNG 上线 | 仅预留枚举位。Flutter 3.24 Windows 桌面端多帧 codec 行为未经实测，Phase 0 不为它们买单 |
| 播放控制 UI（暂停 / 进度 / 只播一次 / 倍速） | 零依赖原生日方案**做不到**（见 §3 选型 A 的固有上限） |
| 视频背景（MP4/WebM） | 需引入播放器依赖 + 编解码分发，属于另一个量级 |
| 上传时重编码 / 抽帧 / 降采样 | 用户选「超限拒绝」；且改写用户原始文件与项目既有护栏（IMP-05/ADR-007 一类）有张力 |
| 内置主题换成动图资源 | 本期只做用户上传通道；`settings_modal.dart:4015-4030` 的预览因此**可不动**（见 §9 P2） |
| BPM 封面 backdrop 动图化（`big_picture_shell.dart:651-672`） | 那是**游戏封面**不是主题背景，与本次无关，明确不碰 |
| NSFW 相关 | 背景图全链路不送检、不打码（已核实无交集），本次不引入 |

---

## 2. 现状调研（全部带 `路径:行号`）

### 2.1 上传链路：2 个入口，1 个统一落盘点

| 入口 | 文件:行号 | 说明 |
|------|-----------|------|
| 设置 → 外观 → 自定义背景 | `lib/widgets/settings_modal.dart:4374`（`_onPickCustomBackground`；picker `:4376`；upload `:4392`） | 上传后**新建用户主题**并立即应用（`:4400-4414`） |
| 主题设计器 → 上传背景 | `lib/widgets/theme_editor_dialog.dart:219`（`_onUploadBackground`；picker `:221`；upload `:230`） | 只更新预览，需点「应用」才落库（`:236` 提示语已写明） |

两处**各自直接调 `FilePicker.platform.pickFiles`**（`settings_modal.dart:4376`、`theme_editor_dialog.dart:221`），
`type: FileType.image`，**没有统一的 picker 封装，也没有 `allowedExtensions` 收窄**。

统一落盘函数只有一个：

```
lib/theme/theme_storage.dart:273  uploadBackgroundImage(sourcePath, ...)
  :278-281  文件存在性检查
  :283-287  体积上限 10MB（唯一门槛）
  :289-290  扩展名提取 + 白名单校验（仅扩展名）
  :292-293  目标文件名 bgUuid.ext
  :295-297  sourceFile.copy 原样落盘（无压缩 / 无缩放 / 无转码）
  :299-303  曾有的 _generateThumbnail 已删除（死代码），注释说明不再预生成缩略图
```

### 2.2 白名单：只有扩展名，没有任何内容校验

```
lib/theme/theme_storage.dart:371-376  validateImageExtension(ext)
  :372  const allowed = ['jpg', 'jpeg', 'png', 'gif'];
```

- **仅扩展名匹配，无魔数 / 文件头校验** → 把 `video.mp4` 改名 `a.gif` 可通过。
- `extractExtensionSafe`（`:359-368`）已有**路径遍历防护**（`p.basename` + `^[a-z0-9]{1,5}$` 正则），这部分是好的，不要动。
- 库内另有一处 GIF 头检测（`lib/services/game_data_migration.dart:179`），但那是**导入迁移**用途，与背景链路无关，**不可复用为背景校验**。

### 2.3 数据模型：无格式字段

`lib/theme/background_image_config.dart`：

```
:47-87    字段：source / assetPath / filename / overlayOpacity / blurSigma / fit / alignment / scale / offsetX / offsetY
:118-125  hasImage
:130-131  legacyAssetPath —— file 来源返回 null（渲染层必须走 Resolver）
:136-150  toJson（custom 模式才写 scale/offsetX/offsetY）
:152-175  fromJson —— 全部字段 `?? 默认值`
:204-230  == 与 hashCode（逐字段）
```

- **没有 `format` / `isAnimated` / 帧信息字段**。
- `CTThemeData.schemaVersion = 1`（`lib/theme/app_theme_manager.dart:234`）；主题包导入有版本闸门
  （`lib/theme/ct_theme_package.dart:150-153`，高于支持版本直接拒绝）。
- 主题 JSON 落 `user_themes/{id}.json`（`theme_storage.dart:44-56,109-126`），激活 id 在 SharedPreferences
  key `app_theme`（`:35,89-92`），背景二进制在 `data/user_backgrounds`（`lib/core/path_helper.dart:63-65`）。

### 2.4 渲染链路：5 个渲染点，3 个共用

统一渲染组件 `BackgroundImageResolver`（`lib/theme/background_image_resolver.dart:21`，StatefulWidget）：

| 渲染点 | 文件:行号 | 说明 |
|--------|-----------|------|
| 桌面主窗口全屏底层 | `lib/widgets/custom_title_bar.dart:274-280` | `Positioned.fill` 全屏；其上还有左侧渐变层 `:282-298` |
| BPM 大屏回退背景 | `lib/big_picture/big_picture_shell.dart:673-680` | 仅当**无聚焦游戏封面**时才回退到主题背景（`:651-672` 是封面 backdrop，不属本次范围） |
| 主题设计器预览 | `lib/widgets/editor_preview_builder.dart:162-163` | 共用 Resolver |
| **设置页主题卡预览（独立实现）** | `lib/widgets/settings_modal.dart:4015-4030` | `Image.asset(data.backgroundImagePath!)` + `Opacity(0.35)`；`data` 来自 `AppThemeManager.themeData(theme)`（`:3896` / `:3977`），**只覆盖内置标准/特色主题（bundled）**，用户上传的 file 主题目前不在这里渲染 |
| main_container 氛围光 | `lib/main_container.dart:1005` | 有背景图时被 `SizedBox.shrink` 挤掉，无需处理 |

Resolver 内部关键结构（**都是 GIF 的敏感点**）：

```
:77-135   _resolveFilePath：异步解析路径
:110      await precacheImage(FileImage(File(path)), context)   ← 动图语义待验证
:141-171  _resolveNaturalSize：取 image.width/height（custom 模式算 coverScale 必需）
:185-197  AnimatedSwitcher 300ms 交叉淡入淡出             ← 换图期间新旧两图同时存在
:206-300  _buildCustomImageStack（custom 模式）
   :252-259  Image.file(..., fit: BoxFit.fill, cacheWidth: 1920)
   :266-274  ImageFiltered 高斯模糊
   :287-295  ColoredBox 遮罩
:303-364  _buildImageStack（cover/contain/tile）
   :322-329  Image.file(..., cacheWidth: 1920)
   :336-344  ImageFiltered 高斯模糊
   :353-361  ColoredBox 遮罩
```

背景图编辑器 `lib/widgets/background_image_editor_dialog.dart`（拖拽定位 / 滚轮缩放）：

```
:109-111  缩放范围 1.0–5.0
:134-188  _loadImageInfo：FileImage / AssetImage → precacheImage(:156) → 取自然尺寸
```

### 2.5 其他已确认事实

- 全局内存图缓存：`PaintingBinding.instance.imageCache.maximumSizeBytes = 64 * 1024 * 1024`
  （`lib/core/portable_image_cache_manager.dart:62`）。**64MB 属实**。
- 背景渲染链与 NSFW **零交集**（背景不送检、不打码），本次不需要动 NSFW。
- `pubspec.yaml:9-34` 依赖清单中**没有任何图像/动图处理包**（无 `image` / `extended_image` / `flutter_gif` / `gif_view`）。
- `lib/theme/**` 属 **🔴 稳定区**（AGENTS.md §2.4），本次要改 `background_image_config.dart` 与
  `background_image_resolver.dart` 两个文件，**开工前必须再向用户确认一次影响面**。

### 2.6 「已有但未被消费的能力」

1. **`gif` 已在白名单**（`theme_storage.dart:372`）——但没有任何后续处理。
2. **custom 模式的缩放/偏移体系已完备**（`scale` / `offsetX` / `offsetY` + 防黑边边界约束
   `background_image_resolver.dart:232-237`）——GIF 可以直接复用这套几何，**不需要新写缩放逻辑**。
3. **`errorBuilder` 已就位**（`background_image_resolver.dart:366-370`）——解码失败的 GIF 会静默降级为空白，
   不会崩溃；本次只需把它升级为「降级到静态首帧 / 明确提示」。

---

## 3. 技术选型（含被淘汰项及理由）

| 方案 | 描述 | 结论 |
|------|------|------|
| **A. 零依赖原生 `Image`** | 用 Flutter 自带 `Image.file` 播放 GIF，靠上传门槛 + 解码尺寸上限 + 降级策略控性能 | ✅ **选定**（用户拍板） |
| B. `gif_view: ^1.0.3` | 第三方动图组件，可控制播放/暂停/seek/帧率/循环次数 | ❌ 淘汰（本次），保留 P1 备选 |
| C. 自研 isolate 帧队列 + `CustomPaint` | 自己解码、自己按帧率 `drawImageRect` | ❌ 淘汰 |
| D. 转码 MP4 + 视频播放器 | 上传时转视频，用播放器渲染 | ❌ 淘汰 |
| E. 预解码序列帧常驻内存 | 上传时拆成 N 张 `ui.Image` 缓存 | ❌ 淘汰 |

**B 的硬事实（备查，不引入）**：`gif_view 1.0.3`，发布于 2025-05-28，verified publisher
`rafaelbarbosatec.com`；依赖仅 `flutter` + `http: ^1.4.0`（与项目现有 `http: ^1.2.0` 兼容，1.4.0 满足 `^1.2.0`）；
Dart 约束 `>=3.4.0 <4.0.0`（项目 3.5.3 满足）。提供 `GifController`（play/pause/stop/seek）、`frameRate`、
`loop`、`onFrame`。**淘汰理由**：① 用户明确选零依赖；② 其 README 只演示 asset/network/memory 三种构造，
**是否有 `file` 构造未经证实**；③ 引入后渲染路径与现有 Resolver 需适配层，改动面翻倍。
**若后续出现「必须限帧 / 必须暂停」的需求，B 是首选升级路径。**

**C 淘汰理由**：工作量 3-5 天；内存 O(帧数)（一个 600 帧 1920×1080 的 GIF 全缓存 = 5GB，只能做滑动窗口，
又要处理释放与掉帧）；收益只是「可控」，而本期需求并不要求播放控制。

**D 淘汰理由**：需引入播放器依赖与编解码分发，包体积与复杂度不成比例；且上传时改写用户文件。

**E 淘汰理由**：内存与帧数成正比，与「中等门槛 600 帧」直接冲突。

### 3.1 选型 A 的固有上限（必须写进方案，不要事后才发现）

Flutter `Image` 对多帧图的处理由 `MultiFrameImageStreamCompleter` 驱动，**公开 API 层面**：

- ✅ 会按 GIF 自身每帧延迟调度并循环（`repetitionCount == -1` 时无限循环）。
- ❌ **没有**暂停 / seek / 只播一次 / 限帧 / 改帧率的公开 API。
- ❌ 无法限制帧率：一个帧延迟 20ms 的 GIF 就是按 50fps 播（受显示器刷新率封顶）。

**因此本方案的性能策略必须是「入口卡住 + 运行时降级」，而不是「播放时调速」。**

---

## 4. 架构设计

```
┌─ L1 校验层（新增，isolate 内执行）────────────────────────────┐
│  BackgroundMediaInspector                                     │
│   · 魔数校验（内容 == 扩展名，防伪装）                          │
│   · 尺寸（GIF 逻辑屏宽高 / PNG IHDR / JPEG SOF / WebP VP8X）    │
│   · GIF 帧数 + 累计时长 + 平均帧率（块级扫描）                   │
│   · 输出 BackgroundMediaInfo{kind, width, height, frameCount,  │
│                              durationMs, avgFps, bytes}        │
│   · 输出 Verdict{ok | reject(reason, dimension)}                │
└───────────────────────────────────────────────────────────────┘
                 ↓ 通过
┌─ L2 模型层（零 schema 变更）───────────────────────────────────┐
│  BackgroundImageConfig.isAnimated  ← 派生自 filename 扩展名     │
│  （不改 toJson / fromJson / == / hashCode → 无迁移）            │
└───────────────────────────────────────────────────────────────┘
                 ↓
┌─ L3 渲染层（BackgroundImageResolver 增加动图分支）──────────────┐
│  isAnimated ? AnimatedBackgroundImage : 现有静态分支             │
│   · 跳过 precacheImage（动图语义不同）                           │
│   · filterQuality: low、gaplessPlayback: true                   │
│   · 解码尺寸上限（若 Phase 0 V2 证实 cacheWidth 对多帧有效）      │
│   · errorBuilder → 降级静态首帧                                 │
│   · 旧背景 evict（换图/销毁时）                                 │
└───────────────────────────────────────────────────────────────┘
                 ↓
┌─ L4 治理层（降级与释放）───────────────────────────────────────┐
│  R1 动图 + blurSigma>0        → 静态首帧                        │
│  R2 上传越门槛                 → 拒绝（精确到维度）              │
│  R3 运行时连续掉帧             → 静态首帧 + 一次性提示            │
│  R4 全局「减少动效」开关        → 静态首帧                        │
│  R5 背景图编辑器 / 主题卡预览   → 一律静态首帧                    │
│  R6 换图过渡期（AnimatedSwitcher 300ms）→ 动图参与时缩到 120ms   │
│  R7 释放：didUpdateWidget / dispose 时 ImageCache.evict          │
└───────────────────────────────────────────────────────────────┘
```

### 4.1 「静态首帧」怎么拿（关键实现点，零依赖）

用一个自定义 `ImageProvider`，只取第一帧，构造 `OneFrameImageStreamCompleter`：

```dart
class FirstFrameFileImage extends FileImage {
  const FirstFrameFileImage(super.file);

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_loadAsync(key, decode));
  }

  Future<ImageInfo> _loadAsync(FileImage key, ImageDecoderCallback decode) async {
    final bytes = await key.file.readAsBytes();
    final buffer = await ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(buffer);            // 由引擎在目标尺寸上解码
    final frame = await codec.getNextFrame();      // 只取第一帧
    return ImageInfo(image: frame.image, scale: key.scale);
  }
  // == / hashCode 继承 FileImage，保证与动图版本 key 不冲突
}
```

> ⚠️ 上面是**骨架**，Flutter 3.24 的 `ImageProvider.loadImage` 签名与 `ImageDecoderCallback`
> 需按项目内实际 SDK 源码对齐（`flutter/bin/cache/pkg/sky_engine` 或 `flutter/packages/flutter/lib/src/painting`）。
> **执行 AI 必须先读本地 SDK 源码确认签名，不要照抄网络片段。**

它同时服务于 R1 / R3 / R4 / R5 与 errorBuilder 兜底，是本次唯一需要新写的渲染基础设施。

### 4.2 全局「单解码实例」约定

三个共用渲染点（`custom_title_bar` / `big_picture_shell` / `editor_preview_builder`）若使用**完全相同**
的 `ImageProvider`（同 path + 同 cacheWidth，`==` 相等），Flutter 的 ImageCache 会让它们**共享同一个
ImageStreamCompleter**，即只存在一个解码器、播放进度天然同步。

**因此：动图分支的 `cacheWidth` 必须由 Resolver 统一计算并强制一致**，不允许各调用点自己传。
（Phase 0 V4 负责实测确认这个共享行为；若不成立，则改为「同一时刻只允许一个动图背景实例」。）

> 🔴 **本节结论已被 Phase 0 修订 2 推翻**：实测 `cacheWidth` 对多帧图**不生效**，
> 且会把 provider 变成 `ResizeImage` 形态反而**破坏**共享。最终实现是
> **动图分支完全不传 `cacheWidth`**（裸 `FileImage`），共享靠「唯一构造点
> `AnimatedBackgroundImage.providerFor`」保证 —— 见
> `lib/theme/animated_background_image.dart` 的类文档。本节保留仅为记录当时的推理。

### 4.3 R4 全局「减少动效」开关（实现记录，2026-09-17）

**作用范围**：仅 GIF 动态背景图。开启后动图不再循环播放，只渲染静态首帧。
**不含**界面过渡动效（`AnimatedSwitcher` 等）—— 这是用户 2026-09-17 明确划定的边界，
UI 文案必须与该范围一致（见 ADR-010）。

实现落点（4 处，均不触碰 schema）：

| 位置 | 内容 |
|------|------|
| `lib/services/motion_preference.dart`（新增） | `MotionPreference extends ChangeNotifier` 单例，pref key `reduce_motion_background`；`load()` 幂等、`setReduceMotion()` 先通知后落盘；`resetForTest()` / `seedForTest()` 对齐 `nsfw_settings.dart` 既有约定 |
| `lib/theme/background_image_resolver.dart:71-99` | `initState` 订阅 / `dispose` 退订；回调 `setState` + 动图缓存 `evict`（复用 R7 的 `_scheduleEvictIfAnimated`） |
| `lib/theme/background_image_resolver.dart:289-295` | `degradeToStaticFrame` 增加 `MotionPreference.instance.reduceMotion \|\|`（R1 条件保持在后） |
| `lib/main.dart:435` | `await MotionPreference.instance.load()`，位置紧随 `AppThemeManager.loadSavedTheme()` |

**为什么偏好要放 `lib/services/`**：偏好类单例在本项目一律住 `lib/services/`
（`install_path_preference.dart` / `nsfw_settings.dart`）。代价是新增了一条
`lib/theme → lib/services` 的 import 边（代码库本就有反方向的
`services/quick_window_service.dart:9 → theme/app_theme_manager.dart`）。

**为什么必须在 `main.dart` 首帧前加载**：动态背景在首帧就会渲染，
若此时偏好尚未读出，开启该开关的用户会先看到 GIF 播几帧再静止（可见闪现）。

**降级时旧解码器怎么收**：provider 换成 `FirstFrameFileImage` 后，旧的多帧
completer 因失去监听而**自行停表**（`flutter/.../image_stream.dart:1118-1122`），
`evict` 只是把常驻解码内存也一并清掉（Phase 0 V6/W4：ImageCache 只按首帧计费，
不主动清就会一直挂着）。

---

## 5. 数据模型变更（精确到位）

### 5.1 结论：**不新增序列化字段，零迁移**

| 项 | 决定 |
|----|------|
| `BackgroundImageConfig` 字段 | **不新增**。只加**派生 getter** `bool get isAnimated` |
| `toJson`（`background_image_config.dart:136-150`） | **不改** |
| `fromJson`（`:152-175`） | **不改**（保持全 `??` 默认，老 JSON 照常可读） |
| `==` / `hashCode`（`:204-230`） | **不改**（派生 getter 不参与） |
| `CTThemeData.schemaVersion`（`app_theme_manager.dart:234`） | **不改**（仍为 1） |
| 主题包 `kSupportedSchemaVersion`（`ct_theme_package.dart:150-153`） | **不改** |

**理由**：GIF 身份 100% 可从 `filename` 扩展名推断（上传时已由魔数校验保证「内容 == 扩展名」），
加字段只会带来序列化兼容面与 `==`/`hashCode` 的连锁修改，收益为零。这是最小变更原则的直接应用。

### 5.2 需要新增的派生 API

```
lib/theme/background_image_config.dart（在现有类内追加，约 6 行）
  /// 是否为动态背景（GIF）。派生自 filename 扩展名；
  /// 上传时已由 BackgroundMediaInspector 的魔数校验保证「内容 == 扩展名」。
  bool get isAnimated =>
      source == BackgroundImageSource.file &&
      filename != null &&
      p.extension(filename!).toLowerCase() == '.gif';
```

> 内置（bundled）主题目前全是 PNG（`lib/theme/theme_registry.dart:139/187/235`），
> 本期不引入动图内置资源，因此 bundled 分支恒为静态。

### 5.3 ⚠️ 行为变化（需要用户知情）

白名单一直允许 `.gif`，所以**存量用户可能已经上传过 GIF 背景**。本次上线后这些存量 GIF
会从「被动播放但无人管理」变成「正式按动图规则渲染」。两种可接受结果：

- 正常播起来（多数情况）；
- 命中某条降级规则（如 blurSigma>0）→ 显示静态首帧，观感与今天一致。

**无破坏性后果**（最差是静态首帧）。若用户希望「存量 GIF 一律先按静态处理」，在 §13 开放问题里确认。

---

## 6. 格式范围与门槛（用户已拍板的三档）

### 6.1 格式

| 类别 | 格式 | 魔数（前 N 字节） | 是否启用 |
|------|------|------------------|---------|
| 静态 | `jpg` / `jpeg` | `FF D8 FF` | ✅ |
| 静态 | `png` | `89 50 4E 47 0D 0A 1A 0A` | ✅ |
| 静态 | `webp` | `RIFF`(0-3) + `WEBP`(8-11) | ✅ 新增 |
| 静态 | `bmp` | `42 4D` | ✅ 新增 |
| 动图 | `gif` | `GIF87a` / `GIF89a` | ✅ |
| 动图 | 动画 WebP | `RIFF`+`WEBP`+`VP8X`(含动画标志) | ⛔ 仅预留枚举位 `animatedWebp` |
| 动图 | APNG | PNG 内 `acTL` 块 | ⛔ 仅预留枚举位 `apng` |

**规则**：魔数判定结果必须与扩展名一致，否则**拒绝**（例如 `.png` 文件实际是 GIF → 拒绝，
防止扩展名欺骗绕过动图门槛）。

### 6.2 门槛（中等档，超限拒绝）

| 维度 | 静态 | GIF |
|------|------|-----|
| 体积 | ≤ 10 MB（沿用 `theme_storage.dart:284`） | ≤ 10 MB |
| 分辨率 | ≤ 4096 × 4096 | ≤ 4096 × 4096（逻辑屏尺寸） |
| 帧数 | — | ≤ 600 帧 |
| 总时长 | — | ≤ 60 s（**警告**，不拒绝） |
| 平均帧率 | — | ≤ 30 fps（**警告**，不拒绝；零依赖方案无法限帧，只能提示用户观感可能偏"快"） |
| 单帧解码像素 | — | ≤ 1920 × 1080 等效（由解码尺寸上限保证） |

拒绝信息必须**精确到维度**，例如：
`GIF 帧数 1240 超过上限 600（体积 6.2MB 合格 / 分辨率 1280×720 合格）`

### 6.3 为什么「拒绝」而不是「静默降级」

项目既有调性是数据安全优先（ADR-007 删除护栏、IMP-05 目录重叠护栏）。静默降级会让用户
「以为传上去了结果背景是静止的」，比直接拒绝更难排查。

---

## 7. 性能预算（量化）

| 指标 | 目标 | 测量方式 |
|------|------|---------|
| 上传校验（≤10MB 文件块级扫描） | **≤ 60 ms** | 在 `compute()` 内跑，UI 不阻塞；Phase 0 V7 实测 |
| 首帧上屏（换背景后到看见画面） | **≤ 300 ms** | 与现有静态图基线一致（现有已是异步解析 + precache） |
| 单帧解码 + 上屏 | **≤ 8 ms** | Release 构建 + Observatory 帧耗时；超 16ms 即视为掉帧 |
| 常驻内存（单个动图背景） | **≤ 20 MB** | 2 帧 × 1920×1080×4B ≈ 17MB + 编码缓冲 |
| 全局动图解码器数量 | **= 1** | 同一时刻只有一个激活主题背景 |
| ImageCache 占用 | **不挤占封面预算** | 全局 64MB（`portable_image_cache_manager.dart:62`）；背景条目必须可 evict |

**已知预算陷阱**：Flutter 的 ImageCache 对多帧图**可能只按首帧计费**（即一条大 GIF 在缓存账本上只算
一帧的钱），会让 64MB 预算失真。**Phase 0 V6 必须实测**；若属实，则动图背景必须**完全绕开 ImageCache 计费**
（或者主动 `evict` + 自己持有引用）。

---

## 8. 实施阶段划分

### Phase 0 —— 技术验证（**必做，先证伪再落地**）

在 `D:\CTLIB\dev_probe\`（临时目录，**不进 `lib/`**，验证完删除）下写一个最小 demo，
用项目内 `./flutter/bin/flutter.bat run -d windows --release` 跑真机，逐条记录实测数据：

| 编号 | 验证项 | 通过标准 |
|------|--------|---------|
| V1 | Windows 桌面端 `Image.file(gif)` 是否真的逐帧播放 | 肉眼 + 帧计数确认在动 |
| V2 | `cacheWidth: 1920` 对多帧 GIF **是否生效** | 打印每帧 `image.width`：等于 1920 则生效；等于原图宽则**不生效** |
| V3 | `precacheImage(FileImage(gif))` 的实际行为 | 是否阻塞、耗时、是否让解码器常驻 |
| V4 | 三个渲染点用相同 provider key 时**是否共享解码器** | 打印 `identity` 或观察帧同步；不共享则改策略 |
| V5 | `ImageFiltered` 模糊 + GIF 的帧耗时（sigma 8 / 20 @ 1920×1080） | 得出「模糊是否必须降级」的量化依据 |
| V6 | ImageCache 对多帧图的计费口径 | 读 `imageCache.currentSizeBytes` 前后差值 |
| V7 | 10MB GIF 块级扫描耗时 | ≤ 60ms |
| V8 | GIF 循环行为（`repetitionCount`） | 确认无限循环 GIF 会一直播 |

**交付**：一份 `dev_probe/RESULTS.md`（数据表格 + 结论 + 每条对后续 Phase 的影响）。
**任何一条不通过，方案要回头改，不得硬着头皮往下做。**

### Phase 1 —— 校验层（新增，不动既有代码）

- 新增 `lib/theme/background_media.dart`：`BackgroundMediaInspector` + `BackgroundMediaInfo` + `Verdict`。
- 纯函数、无 Flutter 依赖（除 `dart:typed_data`），**可在 `compute()` / isolate 中运行**。
- 新增单测 `test/theme/background_media_test.dart`（≥ 12 例）：
  魔数识别 6 种、伪装文件拒绝、GIF 帧数统计（含 Netscape 循环扩展）、帧延迟累计、
  超门槛各维度分别拒绝、边界值（恰好 600 帧 / 恰好 4096）。
- 测试素材：程序化生成最小合法 GIF（不需要用户提供素材）。

### Phase 2 —— 模型派生 + 渲染分支

- `background_image_config.dart`：加 `isAnimated` 派生 getter（约 6 行）。
- 新增 `lib/theme/animated_background_image.dart`：动图 Widget + `FirstFrameFileImage`（§4.1）。
- `background_image_resolver.dart`：
  - 动图分支；`precacheImage` 跳过（`:110` 加条件）；
  - R1（模糊 → 静态）接入；
  - `didUpdateWidget` / `dispose` 里 `ImageCache.evict` 旧 provider（R7）；
  - `AnimatedSwitcher` 动图时 300ms → 120ms（R6）。
- `theme_storage.dart`：`uploadBackgroundImage` 接入 inspector（`:289-290` 附近）+ 白名单扩 webp/bmp（`:372`）。

### Phase 3 —— 上传 UI 与错误回显

- `settings_modal.dart:4374-4415`：picker 加 `allowedExtensions`；捕获 `Verdict` 并 `AppSnackBar.error` 精确提示。
- `theme_editor_dialog.dart:219-243`：同上（已有 try/catch + `AppSnackBar.error`，改动更小）。
- 上传成功后若命中「警告」档（时长/帧率），给 `AppSnackBar.warning` 一次。

### Phase 4 —— 治理与释放

- 全局「减少动效」开关（R4）：放设置 → 外观页，走 SharedPreferences（**不进 `lib/theme/` 的 schema**）。
- R3 运行时掉帧检测：连续 3 帧 > 16ms → 降级 + 一次性 SnackBar。
- R5：`background_image_editor_dialog.dart:147-152` 与 `settings_modal.dart:4015-4030` 强制静态首帧。

### Phase 5 —— 真机走查

走查清单见 §11。

---

## 9. 改动文件清单

### 新增（2）

| 文件 | 内容 |
|------|------|
| `lib/theme/background_media.dart` | 魔数校验 + 尺寸/帧数/时长探测 + 门槛裁决（纯 Dart，isolate 友好） |
| `lib/theme/animated_background_image.dart` | 动图渲染 Widget + `FirstFrameFileImage`（静态首帧 provider） |

### 修改（4）

| 文件 | 位置 | 改动 |
|------|------|------|
| `lib/theme/background_image_config.dart` 🔴稳定区 | 类内追加 | `isAnimated` 派生 getter（约 6 行）；**不动 toJson/fromJson/==/hashCode** |
| `lib/theme/background_image_resolver.dart` 🔴稳定区 | `:110` / `:185-197` / `:206-364` | 动图分支、跳过 precache、模糊降级、evict 释放、过渡时长分流 |
| `lib/theme/theme_storage.dart` 🔴稳定区 | `:289-290` / `:372` | 接入 inspector 校验；白名单补 `webp` / `bmp` |
| `lib/widgets/settings_modal.dart` | `:4374-4415` | picker 收窄 + 精确错误回显 |
| `lib/widgets/theme_editor_dialog.dart` | `:219-243` | 同上（已有 try/catch，改动更小） |
| `lib/widgets/background_image_editor_dialog.dart` | `:147-152` | 强制静态首帧（R5） |

### 一期明确不碰

- `lib/main.dart` / `lib/main_container.dart`（`:1005` 氛围光逻辑已与背景互斥，无需改）
- `lib/widgets/settings_modal.dart:4015-4030` 主题卡预览 —— 它只渲染内置 bundled 主题，本期无动图内置资源
- `lib/big_picture/big_picture_shell.dart:651-672`（游戏封面 backdrop，与主题背景无关）
- `pubspec.yaml`（**零依赖是本次选型的硬约束，任何情况下都不许为了这个功能加包**）
- `lib/core/**`（稳定区）、NSFW 全部、导入链路全部

---

## 10. 调用点替换清单

| 批次 | 位置 | 动作 | 说明 |
|------|------|------|------|
| **P0** | `theme_storage.dart:273` `uploadBackgroundImage` | 接 inspector，越限抛错 | 唯一落盘入口，卡住这里等于卡住全部入口 |
| **P0** | `background_image_config.dart` `isAnimated` | 新增派生 | 所有下游判断的唯一依据 |
| **P0** | `background_image_resolver.dart` 动图分支 | 新增 | 3 个共用渲染点一次生效 |
| **P1** | `settings_modal.dart:4376` picker | 收窄 + 回显 | 用户第一入口 |
| **P1** | `theme_editor_dialog.dart:221` picker | 收窄 + 回显 | 第二入口 |
| **P1** | `background_image_editor_dialog.dart:147-152` | 静态首帧 | 编辑器是定位用途，动图无意义且拖累 |
| **P2** | `settings_modal.dart:4015-4030` | 静态首帧（**仅当引入动图内置主题时才需要**） | 本期可不动，但要在代码里留一行注释说明 |
| **P2** | 全局「减少动效」开关 | 新增设置项 | R4，非必需但建议 |

**易漏点提醒**（靠 grep 才找得到的）：

1. `theme_storage.dart:110-126` 主题 JSON 保存 —— 本次不改 schema，但要确认没被 `toJson` 改动波及。
2. `ct_theme_package.dart:74` **主题包导入**也会调用 `getBackgroundPath`，导入通道走的是
   `validateImageExtension`（`theme_storage.dart:371`），所以扩展白名单会连带放开主题包里的 webp/bmp。
   **必须确认这是期望行为**（我判断是，但请在实施时向用户复述一次）。
3. `background_image_resolver.dart:141-171` 的 `_resolveNaturalSize` 用 `FileImage` 解析自然尺寸 ——
   对 GIF 会启动一次解码；**动图时改为复用首帧信息**，避免多起一个解码器。

---

## 11. 风险登记

| 级别 | 风险 | 影响 | 应对 |
|------|------|------|------|
| **P0** | `cacheWidth` 对多帧 GIF 不生效（V2 未证实） | 一个 4096×4096 的 GIF 按原尺寸解码 → 单帧 67MB，直接爆内存 | Phase 0 V2 实测；若不生效，**门槛里的分辨率上限必须下调**（建议降到 1920）或改用自绘降采样 |
| **P0** | ImageCache 对多帧图只按首帧计费（V6 未证实） | 64MB 预算失真，多个大图共存时 OOM | V6 实测；若属实则动图背景强制 `evict` + 自持引用，不进 ImageCache 账本 |
| **P0** | 换主题时旧 GIF 未 evict | 解码器与帧内存累积，反复换背景后内存单调上涨 | R7：`didUpdateWidget` / `dispose` 必须 evict 旧 provider |
| **P1** | `ImageFiltered` 模糊 + 动图每帧重栅格化 | 全屏 1920×1080 高斯模糊逐帧执行 → 掉帧到个位数 | R1：动图 + blurSigma>0 一律静态首帧（V5 给量化依据） |
| **P1** | 高帧率 GIF（50fps）在 60Hz 屏上占满栅格线程 | 列表滚动 / 页面切换卡 | R3 运行时掉帧降级；门槛里对平均帧率给警告 |
| **P1** | `AnimatedSwitcher` 300ms 期间新旧两个 GIF 同时解码 | 瞬间双倍内存与 CPU | R6：动图参与时过渡缩到 120ms，旧图先静态化 |
| **P2** | 存量 `.gif` 背景在升级后行为改变（开始播放或触发降级） | 用户观感突变 | §5.3 已说明；上线前让用户确认是否「存量一律先静态」 |
| **P2** | 白名单放开 webp/bmp 连带影响主题包导入（`ct_theme_package.dart:74`） | 第三方 `.cttheme` 包可带 webp/bmp 背景 | 我判断可接受；实施时向用户复述确认 |
| **P2** | 魔数校验误杀（某些非标但合法的 PNG/JPEG） | 用户传不上去 | 魔数识别失败时才回退到「仅扩展名」路径并记 debug 日志，**不要直接拒绝** |
| **P3** | 超长 GIF 的块级扫描在极端文件上耗时超预算 | 上传卡顿 | 扫描设上限（读到 600 帧即停并判超门槛），不做全文件遍历 |

---

## 12. 验收标准

### 功能

1. 上传 `.gif` → 背景播放；上传 `.png/.jpg/.webp/.bmp` → 静态，观感与今天一致。
2. 上传超门槛 GIF（体积 / 分辨率 / 帧数任一越限）→ 拒绝，提示**精确到维度**。
3. 把 `x.mp4` 改名 `x.gif` → 被魔数校验拒绝。
4. GIF 背景 + 调高模糊滑块 → 自动变静态首帧（R1）。
5. GIF 背景进「调整位置」编辑器 → 静止，拖拽/缩放正常，应用后回到主界面恢复播放（R5）。
6. 连续切换 5 个不同主题（含 2 个 GIF 背景）→ 内存不单调上涨（R7）。
7. 桌面端与 BPM 回退背景表现一致（共用 Resolver）。

### 技术

8. `./flutter/bin/flutter.bat analyze lib/theme/background_media.dart lib/theme/animated_background_image.dart lib/theme/background_image_config.dart lib/theme/background_image_resolver.dart lib/theme/theme_storage.dart lib/widgets/settings_modal.dart lib/widgets/theme_editor_dialog.dart lib/widgets/background_image_editor_dialog.dart`
   → **0 新增 error**（存量 563 条 info/warning 是基线）。
9. `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy ./flutter/bin/flutter.bat test test/theme/`
   → 全绿；全量基线 **609/0**，**不得新增失败**。
   ⚠️ 跑测试**必须**加 `env -u` 前缀（代理会劫持 flutter_tester）；**analyze 反过来不能加**（会静默失败返回 0 字节）。
10. `git status --short` 自查：改动文件不得超出 §9 清单。
11. `git diff --stat`：每个文件改动行数与计划量级相符（单文件 >150 行需说明理由）。
12. Phase 0 的 `dev_probe/RESULTS.md` 已产出且 8 项验证全部有实测数据。

---

## 13. 待用户决策的开放问题

1. **存量 `.gif` 背景如何处理？** 白名单一直允许 GIF，可能已有存量。
   （A）升级后按动图规则正常播放（默认）；（B）存量一律先按静态首帧，等用户重新调整设置再说。
2. **是否要加全局「减少动效」开关（R4）？** 加了更稳妥（Phase 4），不加则少一个设置项、少一次稳定区外的改动。
3. **白名单放开 webp/bmp 会连带放开主题包导入**（`ct_theme_package.dart:74` 复用同一个白名单），是否接受？
4. **分辨率上限是否需要根据 V2 结果下调到 1920？** 若 `cacheWidth` 对多帧无效，4096 上限就是内存炸弹。
5. **是否接受「动画 WebP / APNG 只留枚举位不启用」？** 若用户实际有大量动画 WebP 素材，需要把 V1/V2 验证扩展到这两个格式。

---

## 14. 给执行 AI 的指令摘要（可直接复制）

> 你是 Chrono Tide（`D:\CTLIB`）的执行 AI。开工前**必须**先读
> `AGENTS.md` / `docs/DEV/SESSION_HANDOFF.md` / `docs/DEV/STATUS_MAP.md` / `docs/DEV/DECISIONS.md`，
> 再读本方案全文，然后按 `AGENTS.md` §2.2 走两段式流程提交《变更计划》等批准。
>
> 任务：为「主题背景图」增加 GIF 动态背景支持。完整方案在
> `docs/DEV/features/animated_background_implementation_plan.md`。
>
> **硬约束**：
> 1. 零新增 pub 依赖 —— 任何情况下都不要改 `pubspec.yaml` 的 dependencies。
> 2. 不新增序列化字段 —— `BackgroundImageConfig` 只加派生 getter，
>    禁止改 `toJson` / `fromJson` / `==` / `hashCode`，禁止动 `schemaVersion`。
> 3. `lib/theme/**` 是稳定区，改动前必须向用户复述影响面并取得显式批准。
> 4. **Phase 0 技术验证未全部产出实测数据之前，禁止写任何业务代码。**
> 5. 跑测试必须加 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy` 前缀；
>    analyze 不能加。测试基线 609/0，不得新增失败。
> 6. 禁止 `git gc`。一个任务一个提交，只 `git add` 显式文件。
> 7. 发现计划外问题 → 停下来报告，不要自作主张扩大范围。
>
> 交付顺序：Phase 0（dev_probe 实测）→ Phase 1（校验层 + 单测）→ Phase 2（模型 + 渲染）
> → Phase 3（上传 UI）→ Phase 4（治理释放）→ Phase 5（真机走查）。
