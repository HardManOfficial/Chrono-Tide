# 图片画质增强（Real-ESRGAN-ncnn-vulkan）实施方案

> ⛔ **【已废除 · 2026-11-04】用户决定废除该功能，代码全部回退**（回退提交见 `DEV_LOG.md`
> 同日条目）。本文档**仅存档**，其中所有实现细节、探针结果、性能数据都描述的是已删除的代码，
> 不得据此恢复任何实现；确需重做请从头审计，不要照抄本文。

> **文档性质**：阶段 A 只读审计 + 技术方案 → **已于 2026-11-04 落地实施**。
> 第 1~13 章保留批准时的原始论证（含当时的估算数字，不改写历史）；
> **实施中修正的标定、真实下载成本、探针结果与遗留项一律见 §14「落地记录」**。
> **决策基线**：2026-11-04 用户确认四条产品级决策（见 §0.2）。
> **实测环境**：AMD Radeon 核显（Vulkan 设备 0）+ NVIDIA RTX 4060 Laptop（设备 1），Windows x64；
> 探针产物在 `.workbuddy/esrgan_probe/`，可视化对比页 `esrgan_compare_demo.html`。
> **核心假设全部已实测**（下面带「实测」标记的数字都是本机跑出来的，不是估的）。

---

## 0. 结论摘要

### 0.1 一句话

**不要在显示链路里做超分**——它每张图有 2.2 秒的进程级固定开销，任何滚动的列表都扛不住。
正确做法是**离线批处理 + 原地替换源文件**：一次算完、永久受益，所有 20 多处图片调用点零改动自动变清晰，
而且因为源图变大后 `cacheWidth` 的 DCT 缩放更划算，**图片反而加载得更快**。

### 0.2 已确认的四条决策

| # | 决策 | 含义 |
|---|---|---|
| D1 | **全自动后台增强** | 扫描/导入后自动入队，用户无感；需要队列、台账与还原能力 |
| D2 | **内置最小集 + 高质量模型按需下载** | 安装包只增约 **7.6 MB**（压缩后 ≈ +3 MB）；9 MB 的 `x4plus-anime` 首次使用时下载 |
| D3 | **覆盖原文件** | 不搞第二份缓存目录，直接替换库里的封面文件 |
| D4 | **自动识别文字密集图并跳过** | 不做「全部处理 + 用户自己看对比」 |

### 0.3 TL;DR 表

| 维度 | 结论 |
|---|---|
| 引擎 | `realesrgan-ncnn-vulkan.exe`（MIT，2022-04 后未再更新，但无替代品） |
| 内置体积 | exe 6.16 MB + `vcomp140.dll` 0.18 MB + `realesr-animevideov3-x4` 1.25 MB = **7.59 MB** |
| 按需模型 | `realesrgan-x4plus-anime` **8.94 MB**（质量档，实测明显优于轻量档） |
| 安装包增长 | **≈ +3 MB**（LZMA/ultra，现有 53.5 MB → 约 56.5 MB） |
| 单张耗时 | 封面 222×307→×4：独显 **≈120 ms** / 核显 **≈1.2 s**（**不含** 2.2 s 进程固定开销） |
| 批量效率 | 20 张攒一批一次跑：独显 4.6 s / 轻量模型 2.8 s（对比一张一进程要 44 s+） |
| 内存峰值 | 质量档 **≈500 MB** / 轻量档 **≈283 MB**（实测，与图片尺寸几乎无关，是模型权重的固定成本） |
| 落盘体积 | 长边 1600（1158×1600）JPEG q92 = **322 KB/张**（源图 27 KB）；500 款库 ≈ **161 MB** |
| 画质 | 全图锐度 222 → **1730**（7.8×）；平坦区噪点 0.0（**不注入颗粒**） |
| 最大风险 | **文字与 logo 会被重绘成假字**（已实测复现，见图 §3.4）→ D4 的闸门必须做，且要标定误判率 |
| 与既有 Magpie 的关系 | **无重叠**。Magpie 是对游戏窗口做实时超分（`magpie_service.dart:769-783`），完全不碰静态图片链路 |

### 0.4 必须先说清的一处冲突

用户选的 **D3（覆盖原文件）** 与 `AGENTS.md` §2.3 的硬禁止项「❌ 删除或改写用户的数据文件（`Games/`…）」**直接冲突**。
本方案不回避这一点，处理方式是把 D3 作为**显式 ADR 例外**记录，并强制附加三道保险：

1. **原件备份**：替换前把原图改名为 `cover.orig.<ext>`（不删任何字节）；
2. **输出校验闸门**：模型输出必须过四道校验才允许替换（详见 §4.4），因为上游 README 自己写着
   "Bug: Some PCs will output black images"，而**实测发现失败时退出码依然是 0**（§3.3）；
3. **一键全量还原**：台账驱动的还原入口，可把任意或全部图片恢复成原件。

**如果这三点不能接受，D3 就必须改成「应用内缓存覆盖层」——那样显示层需要改 20+ 处调用点，方案要大改。请开发者明确认可这一点再开工。**

---

## 1. 背景与目标

### 1.1 用户看到的症状

| 症状 | 现场（用户截图） | 根因 |
|---|---|---|
| BPM 背景整屏糊 + 有方块噪点 | 第三张图，全屏背景卡通人物边缘发虚 | 封面源图 222×307，被 GPU 拉到 1920×1080（**约 8.7 倍**） |
| 图书馆卡片「放大后更糊」 | 第二张图 | 源图本来就只有 200~300 px，`cacheWidth: 480` 只是解码上限，不会创造细节 |
| 标题 logo / 年份角标周围有振铃 | 所有封面 | 源图本身是被 JPEG 压过的低分辨率图，双三次把压缩噪点一起放大 |

### 1.2 目标

1. 封面、游戏截图、BPM 背景在**被放大显示**时，边缘清晰、无方块噪点、无糊边；
2. **全自动**，用户不需要理解什么模型、什么倍数；
3. 对安装包影响 ≤ +4 MB（内置部分），对用户磁盘影响可控且可清；
4. **不明显影响图片加载速度**（这条要靠 §4.2 的架构来保证，不能靠祈祷）；
5. 不可逆操作必须有退路（还原）。

### 1.3 非目标（本期明确不做）

| 不做 | 原因 |
|---|---|
| ❌ 游戏窗口实时超分 | Magpie 已经做了（`magpie_service.dart`），重复造轮子必冲突（两者抢 GPU/DXGI） |
| ❌ 视频 / OP 超分 | 逐帧 ×4，1 分钟视频要几十分钟，且体积爆炸 |
| ❌ 云端超分 | 用户明确要求轻量化与隐私，封面不该上传 |
| ❌ 修改任何显示层 Widget | 覆盖原文件后自然生效；改 Widget = 20+ 处回归风险 |
| ❌ 用户可调参数面板（倍率/模型/tile） | 第一期不做「调参玩具」，只给「开/关 + 质量档位」 |
| ❌ 处理 `assets/` 里的内置图 | 那些是 UI 素材（SVG/小图标），超分无意义还会污染安装包 |
| ❌ 处理网络图（PB 回传截图） | 不落盘、不可控，且用户没要求 |
| ❌ 把 Magpie 的 Anime4K HLSL 复用到静态图 | 见 §3.2 淘汰理由 |

---

## 2. 现状调研（只读审计结果）

### 2.1 图片链路：散、但没有统一入口

**没有统一的封面组件。** 已经数出来的本地封面加载点：

| 场景 | 位置 | 解码上限 |
|---|---|---|
| 图书馆网格卡 | `lib/pages/library_page.dart:4672`（`NsfwImage.file` + `:4686` `Image.file`） | 480×720 |
| 主页网格卡 | `lib/pages/home_page.dart:665`、`:680` | 480×720 |
| 主页小缩略 | `lib/pages/home_page.dart:1629`、`:1638` | 100×140 |
| 探索大厅卡 | `lib/widgets/explore_hall/hall_cover_image.dart:37` | **200** |
| 详情弹窗 | `lib/widgets/game_detail_dialog.dart:1542`、`:1561` | 600 |
| 详情页网络封面 | `lib/pages/game_detail_page.dart:1921-1927` | **无**（原图解码） |
| 截图轮播 | `lib/widgets/screenshot_carousel.dart:437`、`:450`、`:483` | 1920 |
| 封面相册浮层 | `lib/widgets/cover_preview_overlay.dart:310-330` | 1600（网络分支**无**） |
| BPM 背景 | `lib/big_picture/big_picture_shell.dart:1848-1849`、`:1860`、`:1869` | 1280~4096（按物理宽） |
| BPM 编辑/管理 | `lib/big_picture/widgets/bpm_game_edit_dialog.dart:522`、`bpm_background_manager.dart:648/678/696` | 560 / 400 / 240 |
| **无** `cacheWidth` 的漏网处 | `library_drag_overlay.dart:114-119`、`running_task_bar.dart:113-120`、`category_box_sidebar.dart:1531`、`category_box_company_editor.dart:348`、`game_title_logo.dart:72`、`game_detail_dialog.dart:2738/4437` | 原图解码 |

**这正是 D3（覆盖原文件）最大的价值**：上述 20+ 处一行都不用改，全部自动吃到高清图。
反之如果选「缓存覆盖层」，每一处都要加一层「先查增强版路径」的解析，漏一个就是一处不一致。

封面路径解析是统一的，可以放心：

- `GameDataFormat.findCoverFile`（`lib/services/game_data_format.dart:1691-1712`）解析顺序为
  `cover_file`(game.json) → `cover.png` / `cover.jpg` / `cover.jpeg` → 目录内任意 `*cover.*`（排除 `local_cover`）。
- `GameDataFormat.listCoverGallery`（`:1560-1620`）口径一致。

### 2.2 BPM 背景：`decodeWidth` 是个谎言

```dart
// lib/big_picture/big_picture_shell.dart:1847-1849
final double physicalWidth = View.of(context).physicalSize.width;
final int decodeWidth = physicalWidth.clamp(1280.0, 4096.0).round();
```

1920×1080 屏、DPR 1.25 → 请求按 2400 宽解码。但 `ResizeImage` **只会缩小、不会放大**，
源图 222 宽就给你 222 宽，剩下的 10.8 倍由 GPU 线性拉伸 —— 这就是糊的全部来源。
**该字段的语义是「不要超过这个宽」，不是「至少这个宽」。** 方案不改它（非目标），而是让源图真的够大。

### 2.3 已有但没被用起来的资产（重要：别重复引入）

| 资产 | 位置 | 现状与判断 |
|---|---|---|
| **Magpie 完整 HLSL 算法集**（Anime4K / FSR / FSRCNNX / ACNet / CAS / xBRZ…） | `windows/runner/magpie/effects/`（16 MB） | 只服务游戏窗口实时超分。**不能用于静态图**：需要外部进程劫持窗口 + DXGI 捕获，且 Anime4K 是「锐化式放大」，不修复压缩噪点（见 §3.2） |
| **`onnxruntime ^1.4.1`** | `pubspec.yaml:34`，已用于 NSFW 打分 | 见 §3.2 淘汰理由（插件只暴露 CPU EP） |
| **7z 进程调用与进度解析范式** | `archive_compressor.dart:448`（`Process.start` + stdout 环形缓冲 + 取消标志）、`archive_inspector.dart:498` | **直接复用**：本方案的引擎调用照抄这套（含「不能靠退出码判断」的处理） |
| **进程启动统一入口** | `lib/services/launch_process_launcher.dart:144`（detached）、`:214-218`（后路 `cmd /c start` + 15s 超时） | 可复用，但**必须补 `CREATE_NO_WINDOW`**（现有 `_startSilentProcess` 名不副实，会闪黑窗，见 `extract_manager.dart:335`） |
| **按需下载通道** | `openlist_update_core.dart:129-136`（T1/T2 双通道）、`:959`（ETag 指纹）、`:993`（`HttpClient` + Range 分片） | **D2 的「按需下载模型」直接走这条**，但它的 URL 与包名是硬编码单包常量，需抽出通用化（§5.3） |
| **模型按需释放先例** | `lib/services/nsfw/nsfw_model_provider.dart:53` `ensureExtracted()`（校验 `expectedBytes`、临时文件后改名） | 照抄这套「下载/释放 + 校验 + 原子改名」 |
| **打包/分发三处** | `windows/CMakeLists.txt:178-236`（Magpie 安装规则）、`打包脚本/一键打包.ps1:378-399`、`ChronoTide_Setup.iss:161` | 新增二进制**必须三处都加**，漏一处 = 开发能跑、打包后找不到 exe（历史上 Magpie 就踩过） |
| **全局任务管理器** | `lib/services/global_task_manager.dart:71-158` | 只服务下载/解压，**不是通用队列**，不要硬塞；本方案自带轻量队列 |

### 2.4 明确空白（现有能力做不到的）

1. **零超分能力**。全库无 `FragmentProgram`、无 ncnn、无任何「改像素」的服务（唯一的
   `game_title_logo_service.dart:914-971` 只做 alpha 裁边）。
2. **零缩略图落盘缓存**。冷启每张封面都按 `cacheWidth` 重新解码，只有内存 `ImageCache`（64 MB，
   `portable_image_cache_manager.dart:62`）。
3. **零 GPU / Vulkan 能力探测**。全库无 `Vulkan|D3D|DXGI|nvapi` 命中 —— 意味着**无法自动判断
   用户机器能不能跑**，只能「跑一次看结果」。
4. **零图片解码 isolate**。所有解码都在主 isolate；已有的 `compute()`（`bpm_smart_cover_image.dart:110`）
   只算显著性数学，不产出像素。
5. **无可选组件安装机制**（`ChronoTide_Setup.iss` 无 `[Components]`），所以「让用户安装时不装引擎」
   这条走不通，只能「装了但可关」。

---

## 3. 技术选型

### 3.1 候选对比

| 候选 | 体积 | 画质（二次元插画） | 推理速度 | 许可 | 结论 |
|---|---|---|---|---|---|
| **Real-ESRGAN-ncnn-vulkan** | exe 6.16 MB + 模型 1.25~8.94 MB | **最好**（实测，见 §3.4） | 独显 120 ms/张 | MIT（wrapper）+ 模型随仓 | ✅ **选中** |
| waifu2x-ncnn-vulkan | 相近 | 去噪强、锐度弱，重绘更「糊」 | 相近 | MIT | ❌ 二次元放大这块不如 Real-ESRGAN 的 anime 微调 |
| real-cugan-ncnn-vulkan | 模型明显更大（数十 MB） | 略优/相近 | 更慢 | 部分模型非商用限制 | ❌ 违背轻量化，许可还需逐个核 |
| **Anime4K HLSL（已内置）** | 0（复用 Magpie 的 effects） | 线条锐、**不修压缩噪点**，是放大器不是修复器 | 实时 | MIT | ❌ 解决不了「方块噪点」；且需自建 GPU 管线（Flutter 侧无 `FragmentProgram` 先例） |
| **onnxruntime（已在依赖里）** | 0 新依赖 | 同模型同画质 | **CPU 单线程数秒~数十秒** | MIT | ❌ 插件的 `OrtSessionOptions` 未暴露 DirectML/CUDA EP 绑定，等于只有 CPU；且 ONNX fp32 模型比 ncnn 量化版大数倍 |
| 纯 Dart 双三次 + USM 锐化 | 0 | 只提锐度，噪点也被一起锐化 | 快 | — | ❌ 用户抱怨的正是「放大 + 噪点」，锐化会放大噪点 |
| 内置 `libwebp` 自带的高质量缩放 | 0 | — | — | — | ❌ 只是插值 |

**选它的额外理由**：它是唯一「单文件 exe + 纯数据模型、无 Python 运行时、无 CUDA 依赖」的组合，
并且 Vulkan 覆盖 N 卡 / A 卡 / Intel 核显，与项目「用户机器什么显卡都有」的现实吻合。

### 3.2 为什么不用已经躺在包里的两样东西

- **Magpie 的 Anime4K**：它是 **shader 放大器**，假设输入是干净的游戏画面。对一张被 JPEG 压过、
  还带缩略图锯齿的封面，它会把方块边缘一起锐化成硬边（"锐化噪点"），恰恰是用户最讨厌的效果。
  Real-ESRGAN 是**盲复原（blind restoration）**，训练时就喂了压缩/模糊/噪声退化，所以能真的去掉块状噪点。
- **onnxruntime**：项目已经有它，少一个 6 MB 的 exe 听起来很香。但
  ① 该插件只暴露 `OrtSessionOptions`（CPU 线程数），没有 `AppendExecutionProvider_DML` 之类绑定 →
  只能 CPU 推理；② RRDB 类模型 CPU 单张要数秒到数十秒，500 张库要跑几小时；③ ONNX fp32 权重比 ncnn
  量化版大。**结论：能用但代价更大。**

### 3.3 实测得到的硬约束（这几条决定了架构）

| 实测发现 | 对架构的强制要求 |
|---|---|
| **进程固定开销 ≈2.2 s**（启动 + Vulkan 初始化 + 建模型），而单张边际只要 120 ms | **必须攒批**：一个批次一次进程，绝不能一张一进程（否则 20 张 44 s → 4.6 s） |
| **`-g 9`（不存在的 GPU）时仍 `exit 0`，且不产出文件** | **不能靠退出码判成败**，必须校验产物存在 + 尺寸 + 像素合理性 |
| 失败/成功都把设备列表和 `NN.NN%` 进度打到 stdout/stderr | 进度条可从 `NN.NN%` 解析；设备列表恰好可用来做「Vulkan 可用性探测」 |
| 多 GPU 机器默认选**核显**（首次 4.19 s，预热后 2.5 s） | 应解析设备列表挑独显；解析不出来就 `-g 0` 兜底并让用户可覆盖 |
| 模型权重决定内存，与图片尺寸无关（质量档 500 MB / 轻量档 283 MB） | **内存档位只能靠换模型**，调 `-t` 无效（`-t 128` 实测 500→502 MB） |
| 工具自带编码器浪费：x4 图 `-f jpg` 612 KB、`-f webp` 799 KB，而 PIL JPEG q92 只要 232 KB | **不用工具编码**，只取 PNG，自己重编码（§4.5） |
| 透明通道与 WebP 输入输出都正常 | 支持 PNG 带 alpha（BPM 自定义背景可能是透明 PNG） |

### 3.4 画质实测（这就是「放大前后效果对比」）

素材：从用户截图里裁出的**真实封面**《秋之回忆 #5》222×307，按 BPM 背景实际需求放大到 1388×1920。
可视化对比页：`.workbuddy/esrgan_probe/esrgan_compare_demo.html`（可拖动滑块）。

| 指标 | 双三次（现状） | `x4plus-anime` | `animevideov3-x4` |
|---|---|---|---|
| 全图锐度 Laplacian 方差 | 222.4 | **1730.3（7.8×）** | 958.1（4.3×） |
| 平坦区噪声（自动定位源码最平的 5 个 8×8 块） | 0.0 | **0.0** | 0.1 |
| 主观：发丝 / 睫毛 / 皮肤渐变 | 糊成一团、振铃明显 | **分离成线、渐变干净** | 略锐但仍有雾感 |

**关键结论：质量档（8.94 MB）与轻量档（1.25 MB）的差距是肉眼可见的，不是参数级差异。**
所以 D2 的「内置轻量 + 按需高质量」是对的：轻量档保证「能用」，高质量档是「值得点一下下载」。

**同时实测复现了 D4 要防的那个坑**：标题 logo 被重绘成不存在的字形，`2005` 年份角标被扭曲。
这不是偶发，是生成式模型的固有行为 —— **凡是「含可读文字/艺术字/UI 数值」的图，无脑超分就是错**。

---

## 4. 架构设计

### 4.1 五层

```
┌──────────────────────────────────────────────────────────────┐
│ 1 触发层  CoverEnhanceScanner                                 │
│   · 扫描库内全部封面（复用 GameDataFormat.findCoverFile）      │
│   · 双判据筛选：分辨率不足 OR 锐度低（§4.3）                   │
│   · 命中即入队（去重键 = 绝对路径 + 源文件 (size,mtime)）      │
├──────────────────────────────────────────────────────────────┤
│ 2 调度层  CoverEnhanceQueue（单实例 · 串行 · 可暂停）          │
│   · 空闲门槛：无游戏运行 / 无下载解压中 / 非全屏 BPM           │
│   · 攒批：凑够 N 张（默认 12）或静置 30 s 后起一次进程         │
├──────────────────────────────────────────────────────────────┤
│ 3 执行层  RealEsrganEngine（外部进程 · 隐藏窗口 · 可取消）     │
│   · staging 目录：in/  out/（同卷，便于原子改名）             │
│   · 命令行：-i in -o out -n <model> -s 4 -f png -t 0 -g <gpu>  │
│   · Vulkan 不可用 → 整批标记 unsupported 并永久关闭（§4.6）    │
├──────────────────────────────────────────────────────────────┤
│ 4 校验层  EnhanceVerifier（D3 的命门，四道闸）                 │
│   · 产物存在且 >10 KB / 尺寸 == 源×倍数 ±0                    │
│   · 非全黑、非全透明（采样 64 点）                             │
│   · 结构相似度：与「双三次放大的源图」的下采样比对 ≥ 阈值      │
│   · 体积合理性：产物像素熵不异常                               │
├──────────────────────────────────────────────────────────────┤
│ 5 落盘层  CoverEnhanceStore（台账 · 备份 · 原子替换 · 还原）   │
│   · 备份 cover.<ext> → cover.orig.<ext>（不删字节）           │
│   · 重编码为目标尺寸 → 写 .part → rename 覆盖（原子）         │
│   · 写台账 data/cover_enhance/ledger.json                     │
│   · 让 Flutter ImageCache 失效（同 path 换内容必须 evict）     │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 为什么「不影响加载速度」是结构保证的

| 场景 | 现状 | 方案后 |
|---|---|---|
| 列表滚动读封面 | 27 KB 文件 → 解码 → 缩到 200/480 宽 | **165 KB 文件** → DCT 缩放解码到 200/480 宽 |
| 是否在显示链路等 GPU？ | — | **永不等**。显示层读到的永远是磁盘上已经存在的文件 |
| 增强过程中的 UI | — | 后台 isolate + 外部进程，主 isolate 只做文件 rename |
| 大图解码成本 | 源 222 宽不得不整解再放大 | 源 1388 宽但 `cacheWidth` 更小 → libjpeg 走 DCT 1/8 缩放，**解码更快** |

**唯一变慢的是磁盘读取**（27 KB → 330 KB/张）。SSD 上可忽略；**NAS 库用户会感知**，
所以 §6 给了「体积优先」档，§10 把这条列为 P2 风险。

### 4.3 筛选判据：什么图才该增强

两个判据，**都要过才处理**（避免无意义计算与误伤）：

1. **分辨率不足**：`max(w, h) < 目标长边 × 0.75`。
   读宽高**不许全解码** —— 自己解析文件头（JPEG `SOF0/SOF2`、PNG `IHDR`、WebP `VP8X/VP8/VP8L`），
   纯 Dart 约 30 行，1 ms 以内。500 张扫描秒级完成。
2. **锐度不足**：按 256 宽解码一次（`instantiateImageCodec(targetWidth: 256)`，约 10 ms），
   算归一化 Laplacian 方差。已经清晰的图（例如原生 1200 px 的画师原图）**不该被动**。
3. **文字闸门（D4）**：见 §4.7，命中则**跳过并记录原因**，不消耗 GPU。

### 4.4 四道校验闸（D3 的安全带）

替换是不可逆的（有备份但用户会怕），而模型有已知的输出异常。四道闸全过才允许替换：

| 闸 | 判据 | 拦什么 |
|---|---|---|
| G1 存在性 | 文件存在且 > 10 KB | `-g 9` 那种「退出码 0 但没产物」 |
| G2 尺寸 | `宽 == 源宽×4 ± 0`，`高 == 源高×4 ± 0` | 半截写入、错图覆盖 |
| G3 像素 | 采样 64×64 点：非全黑、非全白、非全透明、方差 > 阈值 | README 自己写的 "Some PCs will output black images" |
| G4 结构 | 产物缩到 64×64 与「源图双三次缩到 64×64」的 SSIM ≥ 0.90 | 模型彻底跑飞（生成了一张不相干的图） |

**G4 是最重要的一道**：它不需要原图真值，只要「增强结果在结构上仍是同一张图」。

### 4.5 输出与落盘：为什么必须自己重编码

工具自带编码器实测很浪费：

| 输出方式 | 888×1228 体积 |
|---|---|
| 工具 `-f png` | 1 098 KB |
| 工具 `-f webp` | 799 KB（接近无损） |
| 工具 `-f jpg` | 612 KB（质量拉满，无用） |
| **PIL JPEG q92（同尺寸）** | **232 KB** |

方案：

1. 引擎只输出 **PNG 到 staging**（无损中间件，方便二次处理，也保留 alpha）；
2. 在 `compute()` isolate 里用新依赖 `image`（纯 Dart）做 **目标尺寸重采样 + JPEG q92 编码**；
   **不要在 main isolate 做**（1 MP 编码约几百 ms，会掉帧）；
3. 需要保 alpha 的（源是 PNG/WebP 且含透明）→ 编码 PNG（体积换正确性，这类图很少）。

**中间件体积代价**：一张 4× PNG 约 1.1 MB，批 12 张 = 13 MB 临时占用，处理完立即删。
**必须计入磁盘准入**（复用 `download_space_budget.dart` 的做法登记承诺量）。

### 4.6 降级矩阵

| 故障 | 检测方式 | 降级行为 |
|---|---|---|
| 没有 Vulkan（老核显 / 云主机 / RDP） | 用 `-h` 或空跑一次，看 stderr 是否出现设备列表 | 标记 `unsupported`，**全局永久关闭**并写 prefs；设置页显示原因 |
| 只有核显 | 设备列表无 NVIDIA/AMD 独显关键字 | 自动降到 **轻量档**（283 MB / 更快），不弹窗打扰 |
| 显存不足 / 大图 OOM | 进程崩溃 or G1/G3 失败 | `-t 128` 重试一次；再失败跳过该图并记账 |
| 磁盘不足 | 写入前 `remaining < 2×PNG估计 + 512 MB` | 暂停队列，复用 §2.3 的空间准入风格 |
| 用户正在玩游戏 | `GameLaunchService` 有运行中实例 | 暂停（游戏优先，绝不让 GPU 争抢导致掉帧） |
| 用户取消/关闭功能 | 设置开关 | `cancelCurrent()` + 清理 staging，**已替换的不回滚**（回滚是独立动作） |
| 目标目录只读 / 网络路径失败 | 写入异常 | 该图记 `failed`，**不回退到缓存覆盖层**（D3 明确不要第二份）——如实报错 |

### 4.7 文字闸门（D4）怎么做，以及它可能的失败

**本期方案：纯 Dart 启发式，零新依赖。**

思路：文字/UI 的特征是「高频细笔画 + 高对比 + 局部聚集」。
在 256 px 预览上计算边缘密度图（Sobel），再做 **形态学闭运算 + 连通域**，统计「符合笔画特征
（细长/高对比/面积小）的连通域总像素占比」。

- 占比 **< 阈值 T** → 视为插画，处理；
- 占比 **≥ T** → 跳过，台账记 `skipped_text`。

**诚实说清局限**：

1. **阈值 T 必须实测标定**：建议用 `ct_explore_dump.json` 那 513 条真实库做样本（项目已有这个基准），
   手工标 50 张「有/无文字」，扫 T 从 1% 到 8%。
2. **封面上的标题 logo 也是文字**。本文档 §3.4 那张封面的 logo 占画面不到 3%，按 T=3% 会被**放过**，
   然后照样被重绘。所以 T 必须按「文字区面积占比」而不是「是否含文字」来定 —— 这意味着
   **很多带大标题的封面会被跳过**，全自动的收益会打折。
3. **如果 Phase 0 实测「跳过率 > 30%」**，D4 应升级成 **「文字区回贴」**：把检测到的文字区 mask 外扩 4 px，
   在该区域内贴回「源图双三次放大」的结果，其余区域用模型结果。这样既有清晰度又不毁文字。
   这是 Phase 3 的备选升级路径，本期不做。

---

## 5. 数据模型变更

### 5.1 `game.json`

**不新增字段、不升 `format_version`。**

- 覆盖原文件时**保持原文件名**（`cover_file` 的值不变），所以 schema 零变化。
- 唯一可能的越界：源是 `cover.png`（无 alpha）时，若强行写成 JPEG 会「扩展名与内容不符」。
  **本方案选择：源是 PNG 就输出 PNG**（体积大但正确），并在台账里标记 `format_png`，
  让「体积优先」模式下这类图直接跳过 —— 不动扩展名，不骗解码器。

### 5.2 新增台账文件（不碰 game.json）

`data/cover_enhance/ledger.json`

```jsonc
{
  "version": 1,
  "engine": "realesrgan-ncnn-vulkan/v0.2.0",
  "entries": {
    "<绝对路径的小写 SHA1 前 16 位>": {
      "path": "D:/Games/xxx/cover.jpg",
      "backup": "D:/Games/xxx/cover.orig.jpg",
      "source": { "w": 222, "h": 307, "bytes": 27648, "mtime": 1730000000 },
      "output": { "w": 1158, "h": 1600, "bytes": 329728, "format": "jpeg", "quality": 92 },
      "model": "realesrgan-x4plus-anime",
      "status": "done",        // pending | done | skipped_text | failed | unsupported
      "reason": null,
      "at": 1730700000
    }
  }
}
```

**为什么不用 SQLite**：项目全 JSON 无 SQLite（既有约定），且台账是冷数据，读写频率低。

**为什么必须记 `source.mtime + bytes`**：用户重新下载封面后 `cover_file` 指向新文件，
旧条目必须能自动失效。**但注意：判新旧禁用 mtime 单指标**（ADR-008），所以这里用 `bytes + mtime` 双因子，
且只用于「这条台账还对不对得上」，不用于「哪张更新」。

### 5.3 按需模型分发

复用 OpenList 的分发骨架，但它的 URL 与包名是硬编码单包常量（`openlist_update_core.dart:129-136`），
需要抽出「通用可选组件」的取包逻辑。**替代方案**（更省事）：模型只有 8.94 MB，
直接放在现有更新通道里当**第二个静态资源**，用 `HttpClient` + Range 断点续传下载，
校验 SHA256 后落到 `runtime/esrgan/models/`（照抄 `nsfw_model_provider.dart:53` 的
「临时文件 → 校验 → 改名」三步）。

**推荐后者**：8.94 MB 单文件不需要 T2 那套 6 并发分片，接通用管道反而是过度设计。

### 5.4 prefs 新增

| key | 类型 | 默认 | 说明 |
|---|---|---|---|
| `cover_enhance_enabled` | bool | `true` | 总开关（用户可关） |
| `cover_enhance_quality` | string | `auto` | `auto` / `lite` / `best` |
| `cover_enhance_max_edge` | int | `1600` | 目标长边（体积档位） |
| `cover_enhance_unsupported` | bool | `false` | 探测到无 Vulkan 后的永久标记 |
| `cover_enhance_gpu_index` | int | `-1` | 手动指定 GPU，`-1` 自动 |

---

## 6. 性能预算

### 6.1 量化目标（硬要求）

| 指标 | 目标 | 实测依据 |
|---|---|---|
| 扫描 500 个封面（判据 1，只读文件头） | **< 2 s** | 纯 IO，无解码 |
| 锐度评估（判据 2，256 px 解码） | **< 15 ms/张** | 现有 `cacheWidth` 解码路径同量级 |
| 单张增强边际耗时（独显 / 质量档） | **≤ 200 ms** | 实测 120 ms |
| 单张增强边际耗时（核显 / 轻量档） | **≤ 500 ms** | 实测约 300 ms |
| 一批 12 张总耗时（独显质量档） | **≤ 4 s** | 2.2 s 固定 + 12×0.12 s ≈ 3.6 s |
| UI 主线程阻塞 | **单次 ≤ 16 ms** | 编码进 isolate，落盘只有 rename |
| 峰值额外内存（应用侧） | **≤ 80 MB** | 只持有 PNG 字节与台账 |
| 峰值相机内存（引擎进程） | 质量档 500 MB / 轻量档 283 MB | 实测 |
| 500 款库磁盘增量 | **≤ 200 MB**（长边 1600） | 实测 322 KB/张 × 500 = 161 MB |

### 6.2 时间预估（全量 500 张）

- 独显质量档：500 × 0.12 s + 42 批 × 2.2 s ≈ **2.5 分钟**
- 核显轻量档：500 × 0.3 s + 42 × 2.2 s ≈ **4 分钟**
- 加上重编码（isolate，可并行 1 个）：+ 500 × 0.4 s ≈ **+3.5 分钟**

**结论：全库一次性跑完在 6~8 分钟量级**，完全可以在后台慢慢跑，用户打一局游戏回来就好了。
这也是为什么「全自动」可行 —— 如果每张要 30 秒，全自动就是灾难。

### 6.3 分批策略

- 批次大小 `N = 12`：太小则固定开销占比高（12 × 0.12 = 1.44 s vs 2.2 s 开销，刚好 1:1.5）；
  太大则取消粒度粗、staging 占盘多。
- 队列优先级：**BPM 背景正在用的封面 > 正在浏览的页面 > 其他**（用户感知最强的地方先修）。
- 空闲门槛见 §4.6。

---

## 7. 实施阶段

### Phase 0 · 技术验证（**先证伪，不写业务代码**）

目标：把本文档里标「需实测 / 待标定」的假设全部做实。**任一条证伪，方案要改，不要硬上。**

| # | 验证项 | 方法 | 通过标准 |
|---|---|---|---|
| P0-1 | 引擎在**目标用户机器**上可用 | 打包一个新 exe 到 `dev_probe/`，用户在 3 台机器（N 卡 / A 卡核显 / Intel 核显）各跑一次 | 至少 2/3 能出图 |
| P0-2 | `image` 包 JPEG 编码耗时与体积 | 纯 Dart 探针，10 张 1 MP 图 | ≤ 600 ms/张，q92 体积 ≤ 350 KB |
| P0-3 | 文字启发式阈值标定 | 513 条真实库采样 50 张人工标注 | 误判（该跳没跳）≤ 20% |
| P0-4 | 全库跳过率 | P0-3 标定后跑全量统计 | **> 30% 则 D4 必须升级为「文字区回贴」** |
| P0-5 | 四道闸的拦截力 | 人工造 5 张坏输出（全黑/全白/错图/半截/纯噪） | G1~G4 全部拦下 |
| P0-6 | 原子替换在 **NAS/只读** 路径的行为 | 映射网络驱动器 + 设只读属性 | 明确失败并记账，不产生半截文件 |
| P0-7 | 打包三处是否齐全 | `flutter build windows` + 一键打包 + 安装，检查 Release 与安装后目录 | `runtime/esrgan/` 两个位置都有 |

**Phase 0 产出**：`dev_probe/esrgan_phase0_probe.dart` + 一份带数字的结论。
**注意**：本机 `flutter test` 跑不通（`CreateFile failed 231`），纯 Dart 探针走
`flutter/bin/cache/dart-sdk/bin/dart.exe`，真机验证必须开发者自己在正常终端补跑。

### Phase 1 · 引擎层（无 UI、无自动触发）

- 新增 `lib/services/image_enhance/real_esrgan_engine.dart`：探测、攒批、调用、进度、取消、四道闸。
- 新增 `lib/services/image_enhance/staging_dir.dart`：同卷 staging + 原子改名 + 清理。
- **不接任何 UI**，用探针驱动。此阶段可独立合入。

### Phase 2 · 落盘与还原（仍然无自动触发）

- 新增 `lib/services/image_enhance/cover_enhance_store.dart`：备份、替换、台账、还原。
- 设置页加「一键还原全部」入口（先有退路，再开自动）。

### Phase 3 · 扫描 + 队列 + 自动触发

- 新增 `cover_enhance_scanner.dart`（双判据 + 文字闸门）、`cover_enhance_queue.dart`（调度 + 空闲门槛）。
- 接到「库扫描完成 / 导入完成」之后（**不要接在列表滚动里**）。
- 状态展示：复用 `running_task_bar` 的视觉，但**不要塞进 `GlobalTaskManager`**（它只认下载/解压）。

### Phase 4 · 高质量模型按需下载 + 设置项

- 模型下载通道（§5.3）、`auto/lite/best` 档位、`max_edge` 调节、还原单张。

### Phase 5（可选，仅当 P0-4 触发）· 文字区回贴

---

## 8. 改动文件清单

### 8.1 新增

| 文件 | 作用 | 约行数 |
|---|---|---|
| `lib/services/image_enhance/real_esrgan_engine.dart` | 探测/攒批/调用/进度/四道闸 | ~450 |
| `lib/services/image_enhance/enhance_verifier.dart` | G1~G4 | ~120 |
| `lib/services/image_enhance/cover_enhance_store.dart` | 备份/替换/台账/还原 | ~300 |
| `lib/services/image_enhance/cover_enhance_scanner.dart` | 双判据 + 文字闸门 | ~250 |
| `lib/services/image_enhance/cover_enhance_queue.dart` | 调度 + 空闲门槛 | ~200 |
| `lib/services/image_enhance/image_header_reader.dart` | 文件头宽高解析（JPEG/PNG/WebP） | ~120 |
| `lib/services/image_enhance/esrgan_model_provider.dart` | 模型按需下载/校验/释放 | ~180 |
| `lib/core/path_helper.dart` 内新增 getter | `esrganDir` / `esrganExePath` / `esrganModelsDir` / `coverEnhanceLedgerPath` | ~12 |
| `dev_probe/esrgan_phase0_probe.dart` | Phase 0 全部验证项 | ~400 |
| `windows/runner/esrgan/realesrgan-ncnn-vulkan.exe` | 引擎（二进制） | — |
| `windows/runner/esrgan/vcomp140.dll` | 运行库（`vcomp140d.dll` **不要**带，是调试版） | — |
| `windows/runner/esrgan/models/realesr-animevideov3-x4.{param,bin}` | 内置轻量模型 | — |

> 🔴 **`lib/core/path_helper.dart` 属稳定区**（`portable_*.dart` 之外的路径体系也算高敏感），
> 只允许**新增 getter**，不许改动既有 getter 的语义。改动前需用户显式批准。

### 8.2 修改

| 文件 | 改什么 | 风险 |
|---|---|---|
| `pubspec.yaml` | 加 `image: ^4.x` | 纯 Dart，无原生依赖；编译进 exe 约 +300 KB |
| `windows/CMakeLists.txt` | 在 Magpie 那一段（`:178-236`）后面照抄一段 `esrgan` 的 install 规则 | 漏了 = 打包后找不到 exe |
| `打包脚本/一键打包.ps1` | 在 `:378-399` 的 `[Magpie]` 后补 `[ESRGAN]` 段 | 漏了 = Release 目录缺文件 |
| `ChronoTide_Setup.iss` | 无需改（`:161` 递归打包整个 Release），但**要实测**确认 `runtime/esrgan/` 被带上 | 若被 `Excludes` 误伤则需补 |
| `lib/services/storage/storage_cleanup_service.dart` | 台账目录与 staging 纳入体积统计（`:97` 附近）与清理（`:263` 附近） | 清理逻辑要遵守 ADR-007 护栏 |
| `lib/services/app_state.dart` **或** 设置页 service | 挂初始化钩子（启动时按需建队列） | **稳定区**，改动需批准；可改为在 `main_container` 之外的轻量单例自启动，避免动稳定区 |
| `lib/widgets/settings_modal.dart` | 新增「画质增强」区块（开关/档位/还原/状态） | 纯新增区块，低风险 |

### 8.3 一期明确不碰

- 任何 `Image.file` / `NsfwImage.file` 调用点（20+ 处）—— 覆盖原文件后自动受益；
- `big_picture_shell.dart` 的 `decodeWidth` 逻辑；
- Magpie 全链路（`magpie_service.dart`、`effects/`）；
- `game_data_format.dart` 的任何字段与迁移；
- `chrono-tide-opensource/`；
- 网络图 / 截图 / PB 回传图的任何链路。

---

## 9. 调用点替换清单

**因为选了 D3（覆盖原文件），调用点替换清单基本是空的 —— 这本身是 D3 的最大收益。**
但有三类「非 Widget 的易漏路径」必须处理，否则会出现「文件换了，界面还是旧的」：

| 级别 | 位置 | 处理 |
|---|---|---|
| **P0** | Flutter `ImageCache`（`portable_image_cache_manager.dart:62`） | 替换成功后按 path `evict`，否则同一路径不同内容会显示旧图（内存缓存键是 path+尺寸，不含 mtime） |
| **P0** | 各页 `_coverPathCache`（`library_page.dart:186`、`home_page.dart:49`） | 只缓存路径不缓存内容 → 无需处理，但**必须验证**替换后不会触发「路径未变所以不重建」 |
| **P1** | `CoverDownloadService` 重新下载（`cover_download_service.dart:77-112`，文件名带 nonce） | 重新下载会**覆盖掉增强版**（写 `cover_<nonce>.jpg` 并改 `cover_file`）→ 旧台账条目失效，自动重新入队。**这是预期行为，不是 bug**，但要在 DEV_LOG 写明 |
| **P1** | `GameDataFormat.findCoverFile` 的兜底分支（`:1727` `contains('cover.')`） | `cover.orig.jpg` 会被这个兜底命中 → 只在 `cover_file` 缺失时发生；台账还原时要保证主文件先恢复 |
| **P2** | `bpm_background_manager.dart:648/678/696` 的自定义背景 | 自定义背景在 `metaDataDir`，与封面不同文件，本期不处理（只处理 canonical 封面） |
| **P2** | 截图（`screenshots/`） | 用户提了「游戏截图」，但截图多为原生 1920×1080，双判据会直接筛掉 → **实际很少处理**，不需要单列调用点 |

---

## 10. 风险登记

| 级别 | 风险 | 影响 | 应对 |
|---|---|---|---|
| **P0** | **文字/logo 被重绘**（已实测复现） | 封面标题变成假字，比糊更难看 | D4 闸门 + Phase 0 标定；跳过率 >30% 则升级「文字区回贴」 |
| **P0** | **不可逆覆盖 + 模型输出异常** | 用户全库封面被毁 | 三道保险：原件备份、G1~G4、一键还原；**首版默认「只替换 10 张试跑并提示」，确认后才全量** |
| **P0** | 无 Vulkan 的机器 | 功能完全不可用 | 显式探测 + 永久标记 + 设置页说明；**绝不静默失败** |
| **P0** | 打包漏文件（三处只改了一处） | 开发能跑、用户装完崩溃 | Phase 0 P0-7 强制验证三处；CI 里加一次「Release 目录存在性」检查 |
| **P1** | 输出尺寸与显示需求错配 | 修完还是糊（比如目标长边设 1024 却要撑 1920 背景） | 目标长边默认 1600，BPM 场景按需 1920；在设置页写明「越大越清晰也越占盘」 |
| **P1** | 全自动在用户工作时抢 GPU | 掉帧、风扇狂转 | 空闲门槛（无游戏/无下载/非全屏）+ 批次间 sleep + 可暂停 |
| **P1** | 全库一次性跑 500 张，用户不知道在干什么 | 磁盘突然少 161 MB | 首启只跑「当前可见的 20 张」，其余按空闲增量；设置页显示已用体积 |
| **P2** | NAS 库磁盘 IO 增加（27 KB→322 KB/张） | 网格滚动变卡 | 提供「体积优先」档（长边 1280 = 926×1280，实测 **242 KB**）；检测到 UNC 路径时默认该档 |
| **P2** | 只读/无权限目录 | 替换失败 | 记 `failed` 并跳过，不重试轰炸（照抄 `interrupt_cleanup` 的退避思路） |
| **P2** | `-t` 调不动内存 | 低配机 500 MB 峰值可能触发换页 | 内存档靠换模型（轻量 283 MB），不指望 `-t` |
| **P2** | 引擎 2022 年后停更 | 长期无人修 bug | 引擎隔离在一个 service 后面，将来换 real-cugan/新 ncnn 只改一层 |
| **P3** | 一个 6 MB 的 exe 被杀软误报 | 用户装不上 | 已有 Magpie/SDL3 等同类先例；打包时提供 SHA256 供核对 |
| **P3** | `image` 包引入供应链风险 | 低（纯 Dart、无 postinstall） | 锁版本、审 pubspec.lock diff |

### 10.1 发现但本次不改的既有问题（只报告）

1. `extract_manager.dart:335` 的 `_startSilentProcess` 实际用 `ProcessStartMode.normal`，
   **没有 `CREATE_NO_WINDOW` → 7z 会闪黑窗**。本方案调用 esrgan 时**必须**自己做隐藏窗口，
   不要复用这个方法（会闪）。建议单独立项修。
2. `screenshot_carousel.dart:143` 的 precache 未带 `memCacheWidth`，与 `:456` 的键不同 → 预加载基本无效。
3. `library_drag_overlay.dart:114-119`、`running_task_bar.dart:113-120` 等 6 处无 `cacheWidth`，
   小图位全分辨率解码。修这些是独立收益，与超分无关。
4. 全库无 GPU 探测能力，Magpie 只能让用户手选「低端/中端/高端显卡」（`magpie_service.dart:191-292`）。
   本方案的设备列表解析可顺手抽成公共能力，但**本期不抽**（避免越界）。

---

## 11. 验收标准

### 11.1 功能

- [ ] 首次启动 30 s 内，当前库可见的封面开始被增强，`running_task_bar` 有进度
- [ ] 随机抽 10 张，BPM 背景打开肉眼可见比改前清晰（**用同一张图前后截图对比，不接受「感觉」**）
- [ ] 含文字截图（如带对话框的 CG）**全部被跳过**，台账 `status = skipped_text`
- [ ] 「还原」能把任意一张恢复成字节级一致的原件（`sha256` 相等）
- [ ] 关掉总开关后，不再有任何进程被拉起（任务管理器验证）
- [ ] 无 Vulkan 机器：功能自动禁用，设置页有明确原因，不弹错误框

### 11.2 技术

- [ ] `./flutter/bin/flutter.bat analyze lib/services/image_enhance` → **0 error**（只看新增 error）
- [ ] `flutter test` —— **本机 231 无法执行，必须开发者在正常终端补跑并贴结果**；
      新增用例至少覆盖：文件头解析、四道闸（含 5 张坏输入）、台账读写、原子替换、还原
- [ ] `git status --short` 确认改动只落在 §8 列出的文件
- [ ] 打包后检查 `runtime/esrgan/{exe,dll,models/}` 齐全，安装包体积增长 ≤ 5 MB
- [ ] 500 张全量跑完后，库目录体积增长 ≤ 200 MB，应用内存无泄漏（连续跑 1 h `WorkingSet` 稳定）

### 11.3 未验证声明（诚实标注）

- ❗ 本文档的所有数字来自**单台机器、单张素材**。核显耗时来自同一台机的 AMD iGPU，
  **不代表 Intel UHD 或更老的卡**。
- ❗ 「无 Vulkan」的实际 stderr 文案**未实测**（本机两卡都支持），需 Phase 0 补。
- ❗ `image` 包的编码耗时/体积**未实测**（未装依赖），Phase 0 P0-2 就是为它准备的。
- ❗ 文字启发式的误判率**完全未知**，Phase 0 P0-3/P0-4 是硬门槛。
- ❗ **本方案未写一行业务代码、未跑任何测试。**

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
项目：D:\CTLIB（Flutter Windows，Chrono Tide）。先完整读 AGENTS.md 与
docs/DEV/features/image_upscale_esrgan_implementation_plan.md。

本次任务：按该方案落地 Phase 1（引擎层），不要做 Phase 2 以后的东西。

硬约束：
1. 两段式：先只读审计并输出《变更计划》（文件+行号+改法），等批准再动手。
2. 只新增 lib/services/image_enhance/ 下的文件；不得修改任何 Image.file 调用点、
   不得动 big_picture_shell.dart、不得动 game_data_format.dart、不得动 magpie。
3. 必须攒批：一个批次一次进程。禁止一张图起一次进程（固定开销 2.2s）。
4. 禁止用退出码判成败 —— 实测 -g 9 失败时 exit 0 且不产文件。必须校验产物。
5. 调用外部进程必须隐藏窗口（CREATE_NO_WINDOW / SW_HIDE），不要复用
   extract_manager._startSilentProcess（它会闪黑窗）。
6. 中间件与产物一律放 staging（同卷），原子 rename，禁止跨卷 rename。
7. 删除任何东西前过 PathHelper.isInsideAppStorage / ADR-007 护栏；
   禁止 contains('_temp_layer_')，用 PathHelper.isTempLayerDirName。
8. 本机 flutter test 跑不通（231），纯 Dart 探针用
   flutter/bin/cache/dart-sdk/bin/dart.exe --packages=.dart_tool/package_config.json。
   测试必须注明「需开发者补跑」，不要把没跑的写成通过。
9. 交付时报：改了什么（文件+行号）/ 验证了什么（命令+结果）/ 没验证什么。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 我的建议 |
|---|---|---|
| Q1 | 首版是否先「只处理 10 张并提示」再放开全量？ | **建议是**。覆盖原文件不可逆，第一次让用户看一眼效果再全量，比事后道歉便宜 |
| Q2 | 目标长边默认 1600（实测 322 KB/张）还是 1920（实测 404 KB/张）？ | **1600**。1080p 全屏背景 1600 已够，体积省 20% |
| Q3 | 是否接受新增 `image` 依赖（纯 Dart，+300 KB 编译体积，换 3 倍体积优化）？ | **建议接受**。否则只能用工具自带的粗糙编码器，落盘体积翻 2.6 倍 |
| Q4 | NAS 库默认降到「体积优先」档（长边 1280）？ | **建议是**，可在设置里覆盖 |
| Q5 | 引擎 exe 放 `windows/runner/esrgan/`（跟 Magpie 并列）还是 `assets/`？ | **跟 Magpie 并列**。`assets/` 走 flutter_assets 会被装进 AppData 副本，且 6 MB 二进制进 asset bundle 很别扭 |
| Q6 | 是否同时把「原件备份」暴露给用户（比如游戏详情页显示「原始封面」）？ | 一期只做还原按钮，不做展示 |

---

## 14. 落地记录（2026-11-04 已实施）

> 本章是唯一反映**代码现状**的部分。§1~§13 里的估算若与本章冲突，以本章为准。

### 14.1 决策确认（Q1~Q6 全部按建议执行）

| # | 决策 | 落地结果 |
|---|---|---|
| Q1 | 首版先处理 10 张 | ✅ `CoverEnhanceQueue.trialLimit = 10`，完成后置 `cover_enhance_trial_confirmed`，设置页显示「已试跑 N 张，确认后放开全量」 |
| Q2 | 目标长边默认 1600 | ✅ `CoverEnhanceSettings.defaultMaxEdge = 1600`，设置页可选 1280 / 1600 / 1920 |
| Q3 | 接受 `image` 依赖 | ✅ `image: ^4.2.0`（解析 4.3.0）已进 pubspec，重编码在 `Isolate.run` 内做 |
| Q4 | NAS 默认降到 1280 | ✅ `nasMaxEdge = 1280`，`effectiveMaxEdge(isNetworkPath:)` 在 UNC / 映射盘自动取小值，设置页可覆盖 |
| Q5 | exe 放 `windows/runner/esrgan/` | ✅ 与 Magpie 并列；`PathHelper.esrganDir` 指向 `runtime/esrgan/` |
| Q6 | ~~是否做还原按钮~~ | **用户明确：不做还原入口**。`CoverEnhanceStore.restore()` 代码保留（**仅测试与排障用**），UI 不暴露；风险由 `cover.orig.<ext>` 原件备份兜底 |

### 14.2 代码落点

```
lib/services/image_enhance/                     12 个文件 / 3 643 行
  enhance_log.dart                27   可注入日志 sink（不 import Flutter，纯 Dart 探针可调）
  cover_enhance_store.dart       167   原子替换 + cover.orig 备份 + 回滚（restore 保留不暴露）
  cover_enhance_scanner.dart     171   三道便宜闸：分辨率 / 文字密度 / 锐度
  cover_enhance_settings.dart    187   ChangeNotifier + prefs（enabled/quality/max_edge/trial…）
  image_header_reader.dart       287   只读文件头解 PNG/JPEG/WebP/GIF，不解码像素
  image_preview_analyzer.dart    319   256px 缩略图算锐度 + 文字密度（Sobel + 按行聚类）
  esrgan_model_provider.dart     336   高质量模型按需下载（45MB 整包 → 只取 2 个 entry）
  enhance_image_task.dart        341   isolate 内跑 G1~G4 + 重采样 + 编码
  cover_enhance_ledger.dart      366   台账（bytes+mtime 双因子，ADR-008）
  real_esrgan_engine.dart        379   探测 GPU / 攒批 / 回读产物
  hidden_process_runner.dart     505   FFI CreateProcessW（隐藏窗口 + 文件重定向）
  cover_enhance_queue.dart       558   队列、空闲门槛、试跑限额、批量调度
lib/widgets/settings/image_enhance_settings_card.dart   516  设置页卡片
dev_probe/esrgan_phase0_probe.dart                     448  Phase 0 探针（38 项断言）
test/image_enhance/image_enhance_test.dart             254  单元测试（⚠️ 因 231 未执行，见 14.6）
```

接线 5 处（均为**新增**，未改任何既有逻辑）：

| 文件 | 改动 |
|---|---|
| `lib/core/path_helper.dart` | 只加 6 个 getter（`esrganDir`/`esrganExePath`/`esrganModelsDir`/`coverEnhanceDir`/`coverEnhanceStagingDir`/`coverEnhanceLedgerPath`） |
| `lib/services/local_game_registry.dart` | `scan()` 末尾 `unawaited(delay 12s → kick())`；接这里因为它是首启/导入后/手动刷新三条路径的唯一汇合点 |
| `lib/widgets/settings_modal.dart` | 外观页新增「图片画质增强」Section |
| `lib/services/storage/storage_cleanup_service.dart` | 新增清理单元 `unitCoverEnhanceStaging`（队列运行中跳过） |
| `pubspec.yaml` | `image` + `crypto` |

打包三处（🔴 缺一必现「开发能跑、装完找不到 exe」）：

1. `windows/CMakeLists.txt`：`ESRGAN_SOURCE_DIR` → `install(... DESTINATION ${RUNTIME_DIR}/esrgan)`，含 `models/*.param|*.bin`
2. `打包脚本/一键打包.ps1`：`--- 5.45 Real-ESRGAN ---` 段（**UPX 列表刻意不加**，Vulkan 运行时压缩风险高，等打包实测）
3. `ChronoTide_Setup.iss`：`[Files]` 的 `Source: Release\*; recursesubdirs` 会自动带上 `runtime\esrgan\`，
   但**另加了两条**：① `ProcessList` 补 `realesrgan-ncnn-vulkan.exe`（不杀就锁 exe，覆盖安装必失败）；
   ② `[UninstallDelete]` 只删随包的 4 个文件，**⛔ 不整目录删** —— `models\` 里还有用户按需下载的
   `realesrgan-x4plus-anime`（45 MB 提取出来的），整目录删会逼用户重下。

### 14.3 实施中修正的两处标定（都是实测推翻估算）

**① 锐度闸 0.42 → 4.0，语义整个换了**

方案原写「相对锐度 ≥ 0.42 视为已足够清晰、跳过」。实测 10 张真实封面落在 **0.238 ~ 2.718**，
而被判为「糊」的模拟样本只有 0.06 —— 阈值 0.42 会**误杀 7/10 张真实封面**。

根因：小尺寸但压缩干净的封面，像素级边缘本来就很陡，相对锐度天然偏高；这个指标衡量不了「该不该放大」。
改成 `sharpnessGate = 4.0`，语义变为「**疑似像素画 / 矢量合成图**」（放大后只会更假），
「该不该放大」整体交给分辨率闸 `resolutionGateRatio = 0.75` 判断。

**② 文字闸算法重写（原实现自伤）**

原实现「3×3 膨胀 + 4 邻域连通域」会把相邻字形粘成一条长连通域，面积超上限被整段丢弃
⇒ 对伪文字样块判出 **0%**，等于闸门完全失效。

修正：**去掉膨胀** → 8 邻域连通域 → `_maxGlyphArea` 900→520、`fill` 0.30→0.18 →
再按 y 带聚类要求「同类高度 + 同行 ≥ 6 个字形」才算一行文字。

修正后实测：

| 样本 | 文字密度 | 结论 |
|---|---|---|
| 伪文字样块（6 行 × 12 字） | **31.46%** | 正确拦下（阈值 3.0%） |
| Galgame 对话截图 | **3.55%** | 正确拦下 |
| 10 张真实封面 | **0.00 ~ 0.52%** | 全部放行 |

### 14.4 高质量模型的真实下载成本：不是 8.94 MB，是 45 MB

方案 §6 写的「按需下载 8.94 MB」**做不到**：上游没有单文件直链，release 只有整包
`realesrgan-ncnn-vulkan-20220424-windows.zip`（**45 474 481 B**）。

落地做法：`EsrganModelProvider.downloadBest()` 拉整包 → `ZipDecoder().decodeBuffer()` 只保留
`models/realesrgan-x4plus-anime.{param,bin}` → SHA256 校验 → 原子改名，其余丢弃（装完仍只占 8.9 MB）。
设置页文案**如实写「约 45 MB」**，不写 8.9。

> 代码里留了 `_directBinUrl` / `_directParamUrl` 两个空常量：等上游或镜像提供单文件直链时改这两行即可，
> 不用重写下载逻辑。

### 14.5 Phase 0 探针结果（`dev_probe/esrgan_phase0_probe.dart --engine`）

`pass=38 fail=0`。逐项：

| 组 | 断言内容 | 结果 |
|---|---|---|
| 文件头 | PNG/JPEG/WebP/GIF 尺寸解析、截断文件返回 null 不崩、非图片返回 null | 全过 |
| 四道闸 | G1 拦半截写入与缺失、G2 拦尺寸不符、G3 拦不可压缩单色图（mean=40.5 std=0.50）、G4 拦随机噪声（SSIM 0.020） | 全过 |
| 台账 | 写入 / 已用体积 / 字节变→重做 / mtime 变→重做 / JSON 落盘可读 | 全过 |
| 原子替换 | 备份字节一致、目标已更新、文件头可解析、`restore()` 可用、无 `.tmp` 残留 | 全过 |
| 真引擎 | 探测 1 491 ms，设备 `[[0] AMD Radeon(TM) Graphics, [1] NVIDIA GeForce RTX 4060 Laptop GPU]`，推荐索引 1；批 6 张 1 633 ms 全成功；单张 888×1228 → 259 KB q92 SSIM 0.994 / 262 ms | 全过 |
| 失败场景 | `-g 9`（不存在的 GPU）→ `successCount = 0`，「只看产物不看退出码」生效 | 全过 |

视觉复核：`.workbuddy/esrgan_probe/vis/{before.jpg,after.jpg,compare.png,full_compare.png}`
（真实封面《秋之回忆 二重奏》888×1228 / 277 KB / SSIM 0.988），细节与整体均明显优于双三次。

### 14.6 遗留与未验证项（接手者必读）

1. 🔴 **`flutter test` / `flutter analyze` / `flutter build windows` 全部未跑**——
   本机 `git`/`dart`/`flutter` 子进程一律撞 `CreateFile failed 231 (ERROR_PIPE_BUSY)`。
   已用进程内 analyzer 顶替静态分析（`ct_scan_all.dart` → `files=382 errors=0 warnings=88`），
   但**单元测试 `test/image_enhance/image_enhance_test.dart` 一次都没真正执行过**，需在有干净管道的机器上补跑。
2. 🔴 **一键打包未验证**。CMake/PS1 两处 install 规则是照 Magpie 抄的，逻辑简单，但没实际打过包。
   UPX 是否可用于 `realesrgan-ncnn-vulkan.exe` 完全未测，当前**不加**。
3. 🟡 **NAS / 只读路径未真机验证**：代码有 UNC 判定 + 写入失败回滚，但没有真实只读共享可测。
4. 🟡 **封面艺术字（标题 logo）检测不出来**：10 张真实封面的文字密度全是 0.00~0.52%，
   说明 Sobel 那一套只认「成行的小字号正文」，认不出大字 logo。这类图会被增强，logo 可能被重绘
   ⇒ 靠 Q1 首启试跑（10 张）+ `cover.orig.*` 原件备份兜底。若用户反馈多，D4 需升级为「文字区回贴」。
5. 🟡 `ImageCache` 失效只覆盖 `FileImage`；若将来有页面用 `ResizeImage` 之外的 provider 包了封面，需要补 `evict`。
6. ⚪ `setup` 期 12 秒延迟是拍出来的经验值，真机首启若仍有卡顿，可改为「首帧 + 空闲 3s」双条件。

---

### 14.7 真机反馈：「完全没变化」——根因与修复（2026-11-04 当天）

用户在真实库（`build/.../Release/Games`，7 个游戏）跑完后反馈「感觉和之前没有任何变化」。
查运行时台账（`data/cover_enhance/ledger.json`）后定位到**四个叠加原因**，前三条已修：

| # | 原因 | 证据 | 修复 |
|---|---|---|---|
| 1 | **WebP 源被格式闸静默跳过**（6/7 张） | 台账只有 1 条 `done`；目录里 6 个 `cover.webp` | `isSupportedFormat` 放开 webp；永久性跳过原因写台账 |
| 2 | **png 源无 alpha 也输出 PNG** | 516×730 源 → 1131×1600 **3.13 MB** PNG（同图 JPEG q92 只有 616 KB） | 输出格式改由**像素是否含半透明**决定，不看源格式 |
| 3 | **`ImageCache.evict` 打不中** | UI 用 `Image.file(cacheWidth:)` ⇒ 缓存键是 `ResizeImage`，不是 `FileImage` | 改 `imageCache.clear() + clearLiveImages()` |
| 4 | **显示尺寸太小，收益被缩放吃掉** | 见下表：90px 卡片只有 ×1.04 | 改不了（物理事实），只能在文档/UI 说清「去哪看」 |

第 4 条的实测（HOSHIORI 810×1080，目标长边 1600；锐度 = Laplacian 方差）：

| 实际显示宽度 | 双三次 | 增强后 | 倍数 |
|---|---|---|---|
| **90px（列表卡片）** | 2732 | 2845 | **×1.04** ← 用户看的正是这里 |
| 400px（详情页） | 1082 | 1609 | ×1.49 |
| 860px（全屏大图） | 240 | 738 | ×3.08 |

⚠️ 这不是实现缺陷：卡片把 810px 的图缩到 90px 显示，缩小本身就是最强的低通滤波，
任何超分在这个尺寸下都不可能看出来。**判断效果必须看详情页或大图。**

**WebP 的落盘策略**（`package:image` 能解 WebP 但不能编码，所以不能原地覆盖）：

- 源 jpeg/png 且产物扩展名相同 → **原地替换**（先备份 `cover.orig.<ext>`）；
- 源 webp、或 png 源转 JPEG → **另写同目录 `cover.<ext>`，源文件一个字节都不动**，
  同时把 `game.json` 的 `cover_file` 指过去 —— 因为 `findCoverFile` 的第 2 条会**优先**
  命中 `cover_file`，不更新它界面就会继续显示旧 webp（这也是"看起来没变"的一半原因）。
- 原件就是源文件本身，不复制、不移动、不删除（比"改名备份"更安全）。

验证：新增 `dev_probe/esrgan_fix_probe.dart`（纯 Dart）→ **pass=24 fail=0**，覆盖
「image 解真实库 webp」「非原地写入后源文件字节与哈希不变」「二次写入先备份 cover.orig.jpg」
「无 alpha 走 JPEG / 有半透明走 PNG」。

### 14.8 真机反馈之二：「BPM 背景还是很糊」——横幅根本没被处理（2026-11-04 第二轮）

用户第二次反馈：**封面看着像有变化了，但进 BPM 模式，全屏背景还是糊。**

这次不是「看不出来」，是**完全没处理过**——而且叠了四层，逐层拆开：

| 层 | 问题 | 证据 | 修复 |
|---|---|---|---|
| **1** | **队列只处理 `cover`，BPM 用的是 `banner`** | `big_picture_shell._resolveBackdropPath` 的顺序是「自定义素材 → **横幅** → 竖版封面」；7 个游戏里 3 个有 `banner_file`，台账里 0 条 banner 记录 | `kick()` 枚举时同时收 `findBannerFile`，**横幅排在封面之前** |
| **2** | **目标长边沿用封面的 1600，对横幅是错的** | 1920×740 的超宽横幅降采到长边 1600 ≈ 1600×616，比原图还小 ⇒ 白跑 | 按宽高比反算「铺满 1920×1080 所需的最小尺寸」，两个方向都要够 |
| **3** | **`notifyDataChanged()` 不重读 game.json** | BPM/主页解析路径是「内存优先 + 文件存在就用」，而旧文件按设计原样保留 ⇒ `coverUrl`/`bannerUrl` 仍指向旧文件，**界面永远显示旧图** | 新增 `LocalGameRegistry.refreshGameMediaPaths(dir)`，每张替换成功后调用 |
| **4** | **`decodeWidth` 只按窗口宽** | `BoxFit.cover` 铺满时，超宽横幅是靠**高度**铺满的：1920×740 要放大到 **2802×1080**，而解码宽只有 1920 ⇒ 先降采再拉伸 1.46 倍，原图再清晰也发虚 | `_backdropDecodeWidth = max(物理宽, 物理高 × 图宽高比)`（本地同步读 8 KB 图头并缓存，网络路径回退旧逻辑） |

第 3 层是**同一个坑踩了第二次**：上一轮修了「`ImageCache.evict` 打不中」，
但没意识到路径本身就没变——缓存清得再干净，读的还是旧文件。

#### 三张真实横幅的实测（4× 超分 → 按 1080p 需求重采样 → JPEG q92）

源图铺满 1920×1080 时的原始放大倍数，决定了收益上限：

| 横幅 | 源尺寸 | 比例 | 铺满 1080p 需宽 | 原始放大 | 产物 | 体积 | SSIM | 显示锐度 |
|---|---|---|---|---|---|---|---|---|
| `banner_12.webp`（My Sister） | 560×420 | 1.333 | 1920 | **3.43×** | 1920×1440 | 1009 KB | 0.9950 | 5.02 → 8.14（**×1.62**） |
| `banner_13.webp`（HOSHIORI） | 1024×704 | 1.455 | 1920 | 1.88× | 1920×1320 | 873 KB | 0.9995 | 6.51 → 8.36（**×1.28**） |
| `banner_14.webp`（巨乳ファンタジー） | 1920×740 | 2.595 | **2802** | 1.46× | 2802×1080 | 841 KB | 0.9993 | 3.80 → 5.50（**×1.45**） |

- 锐度口径：`BoxFit.cover` 铺满 1920×1080（BILINEAR，模拟 Skia 默认采样）后相邻像素差均值。
- 🔴 **收益与「源被放大的倍数」强相关**：3.43× 的那张 ×1.62，1.88× 的只有 ×1.28。
  压缩干净、本来就被轻微放大的横幅，超分能拿回的锐度天然有限 —— 这不是实现缺陷。
- 横幅的**文字闸全部 0.00%**（logo 大字检测不到，同封面的已知局限），三道横幅均放行。
  风险由 `banner.orig` 语义兜底：横幅源文件**一个字节都不动**，产物另写 `banner_enh.jpg`。

#### 落盘策略（横幅与封面的差别）

| | 封面 | 横幅 |
|---|---|---|
| 产物名 | `cover.<ext>` | `banner_enh.<ext>` |
| game.json 键 | `cover_file` | `banner_file` |
| 原件 | 同扩展名原地替换 → `cover.orig.<ext>`；异扩展名 → 源文件不动 | **永远不动**（WebP 编不了码，另写新文件） |
| 重复处理防护 | 分辨率闸（产物长边 ≥ 目标 × 0.75） | 产物名判定（`banner_enh`）+ 分辨率闸 |

`bannerTargetEdge = 2880` 只用于**分辨率闸的判断**（源长边 ≥ 2160 视为够用）；
实际输出尺寸按宽高比反算，避免 16:9 横幅被无谓放大到 2880×1620（多 2.2 倍像素、1.5 MB）。

#### 验证

```
dev_probe/esrgan_banner_probe.dart  →  pass=26 fail=0
  §1 三张横幅通过廉价闸 + 文字闸（0.00%）
  §2 真引擎端到端：尺寸 / 短边 / 铺满需求 / 体积 ≤ 1.5MB / 锐度提升
  §3 目标尺寸公式：1920×740 ⇒ 2802
对比图：.workbuddy/esrgan_probe/banner_vis/why_bpm_blurry.png
```

### 14.9 真机反馈之三：「软件怎么 170 多 MB」——两个我造的垃圾（2026-11-04 第三轮）

用户反馈：**安装目录 170 多 MB，超出可接受的 90 MB**。用户的原话是「我都说了要轻量化接入」。

实测 `Release` 目录 **181 MB**，拆开看：

| 项 | 体积 | 性质 |
|---|---|---|
| `data/cover_enhance/staging/` | **49 MB** | 🔴 **我的 bug**：引擎 4× PNG 中间产物没清 |
| `data/app.so.bak_20261104` + `.bak2_20261104` | **36 MB** | 🔴 **我的垃圾**：手搓 AOT 时的回退备份留在了安装目录 |
| `data/flutter_assets/` | 32 MB | 既有（`anime_dbrating_mv3_v0.onnx` 16.8 MB + 字体 + 主题图） |
| `data/app.so` | 18 MB | 既有 |
| `runtime/magpie/` | 14 MB | 既有（实时超分） |
| `runtime/esrgan/` | 7.3 MB | 本次新增（exe 5.88 + dll 0.18 + 模型 1.25） |
| `runtime/tools/` | 7 MB | 既有 |
| `onnxruntime.dll` + `flutter_windows.dll` | 16.4 MB | 既有 |

**85 MB 是垃圾**（49 + 36），真正的功能增量只有 **7.3 MB**。清掉后 **98 MB**。

#### 根因 1：staging 只在整轮结束时清（严重度：高）

`kick()` 的 `finally` 里有 `_cleanupStaging()`，看起来对——但**批次循环里每批都新建一个
`staging/<runId>/`，只有在整轮全部跑完才清**：

- 库大时累积无上限（3 张 = 49 MB ⇒ 100 张可能 GB 级）
- 进程被杀 / 断电 / 崩溃 ⇒ `finally` 不执行，残留**永久**留在安装目录
- 而 staging 就在 `<安装目录>/data/` 下 ⇒ 用户看到的「软件体积」直接膨胀

修（两处）：

1. `_processBatch` 把「引擎批次 → 逐张过闸落盘」整段包进 `try/finally`，
   **本批结束立刻删 `workDir`**（`_cleanupWorkDir`，含路径越界校验）
2. `kick()` 开跑前先 `_cleanupStaging()`，扫掉上次崩溃留下的

#### 根因 2：AOT 回退备份放错了地方（严重度：中）

手搓 `gen_snapshot` 替换 `app.so` 时，把旧快照备份成了
`data/app.so.bak_20261104` / `.bak2_20261104` —— 每个 18 MB，而且**会被打包脚本一起装进安装包**。
已移到 `.workbuddy/esrgan_probe/aot_backup/`（保留可回退，不占安装目录、不入包）。

#### UPX：把新增的 7.3 MB 再砍一半

ncnn + Vulkan 加载器是静态链进 exe 的，`upx --best --lzma` 压到 **21%**：

| 文件 | 前 | 后 | 省 |
|---|---|---|---|
| `realesrgan-ncnn-vulkan.exe` | 5.88 MB | **1.23 MB** | **4.87 MB** |
| `vcomp140.dll` | 178 KB | 不压 | — |

实测（`dev_probe/esrgan_upx_probe.dart` pass=13 fail=0 + `phase0 --engine` pass=38 fail=0）：
压后 Vulkan 探测 1.5~2.1 s 正常、6 张批处理 5.9 s 正常、4× 尺寸正确。

三条纪律：
- **只压 exe，不压 DLL**（DLL 加壳在部分环境加载失败，且只省 90 KB）
- **不要重复压**（`AlreadyPackedException`；`-f` 强压会变大）⇒ 打包脚本判 `> 2 MB` 才压
- **杀软可能误报 UPX 壳** ⇒ 打包脚本可加 `-SkipUPX` 回退（体积回 98 MB）

#### 最终体积账

| 阶段 | 体积 |
|---|---|
| 用户看到的（含垃圾） | **181 MB** |
| 清掉 49 MB staging + 36 MB 备份 | 98 MB |
| UPX 压引擎（−4.87 MB） | **93.1 MB** |

其中既有功能占 **90.7 MB**，本次新增功能净增 **2.4 MB**（7.3 → 2.4）。

> 口径说明：以上是**安装目录**体积。Inno Setup 用 LZMA2 打包，发行包会显著更小
> （`app.so` 18 MB 可压到 5~6 MB），但具体数字需打包实测——⏳ 未验证。

## 附录 A · 实测原始数据

```
引擎：realesrgan-ncnn-vulkan v0.2.0 (2022-04-24)
  exe                     6 161 408 B
  vcomp140.dll              182 704 B
  models/realesr-animevideov3-x2/x3/x4.bin   各 1 247 368 B
  models/realesrgan-x4plus-anime.bin         8 943 500 B
  models/realesrgan-x4plus.bin              33 424 520 B   ← 不用，体积大且非二次元优化

设备枚举（-v 输出）：
  [0 AMD Radeon(TM) Graphics]                 queueC=1[2]
  [1 NVIDIA GeForce RTX 4060 Laptop GPU]      queueC=2[8]

耗时（含 2.2 s 固定开销，除注明外）：
  单张 222×307 → ×4   auto 2512 ms / -g 0 3124 ms / -g 1 2422 ms
  单张  64×88  → ×4   -g 1 2287 ms        ← 即固定开销
  批 5 张  222×307 → ×4  -g 1 2862 ms（质量档）/ 2057 ms（轻量档）
  批 20 张 222×307 → ×4  -g 1 4613 ms（质量档）/ 2752 ms（轻量档）
  批 20 张 222×307 → ×4  -g 0 25 813 ms   ← 核显
  1280×720 → ×2   -g 1 3705 ms

内存峰值（WorkingSet64 轮询）：
  222×307 → ×4 质量档                     500.6 MB
  222×307 → ×4 质量档 -t 128              502.6 MB   ← tile 不降内存
  1280×720 → ×2 质量档 -t 128             516.1 MB
  1280×720 → ×2 轻量档                    282.8 MB

体积（888×1228 同尺寸不同编码）：
  工具 -f png   1 098 311 B
  工具 -f webp    799 070 B
  工具 -f jpg     612 807 B
  PIL jpg q92     232 KB
  PIL webp q90    135 KB

体积（目标尺寸 × 编码，源 222×307 → x4plus-anime）：
  888×1228    png1531KB  jpg92 232KB  webp90 135KB
  1110×1536   png2131KB  jpg92 305KB  webp90 171KB
  1158×1600（默认档）    jpg92 322KB
  1388×1920   png3001KB  jpg92 404KB  webp90 217KB
  926×1280（体积优先档）  jpg92 242KB
  原图 jpg90   27 KB

画质（同区域）：
  锐度 Laplacian 方差   双三次 222.4 / x4plus-anime 1730.3 / animevideov3 958.1
  平坦区噪点 std        均为 0.0~0.1（不注入颗粒）

已知缺陷（复现）：
  · -g 9（不存在）→ exit 0，无产物
  · 标题 logo 与年份角标被重写成假字
  · 工具自带 webp/jpg 编码器体积是合理值的 2.6~5.9 倍
```

## 附录 B · 探针现场

```
.workbuddy/esrgan_probe/
  resrgan.zip / resrgan-models.zip        下载的发行包
  full_pkg/                                解压后的引擎 + models/（可直接复制走）
  src_cover.png                            从用户截图裁出的真实封面 222×307
  src_tiny.png                             96×132 极小样本
  demo_before.jpg / demo_after.jpg         滑块对比（1388×1920 半尺寸）
  demo_before_zoom.jpg / demo_after_zoom.jpg   细节 2×
  risk_before.jpg / risk_after.jpg         文字重绘反面证据
  esrgan_compare_demo.html                 可视化对比页（自包含）
```

---

**文档结束。未获批准前，本方案不产生任何代码改动。**
