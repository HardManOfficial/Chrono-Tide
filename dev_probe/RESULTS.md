# Phase 0 技术验证结果 —— 动态背景图（GIF）支持

> 日期：2026-09-17　对应方案：`docs/DEV/features/animated_background_implementation_plan.md` §8 Phase 0
> 环境：Flutter 3.24.3 / Dart 3.5.3（项目内 `./flutter/bin/flutter.bat`），Windows 桌面
> 探针代码：本目录 `probe_test.dart`（flutter_tester）、`probe2_test.dart`（widget 路径）、
> `win_probe_main.dart`（真机 debug 窗口）、`gif_fixtures.dart`、`gif_scan.dart`
> ⚠️ 探针与夹具在验证完成后删除，本文档是唯一留存物

---

## 0. 结论摘要

| 编号 | 假设 | 结果 | 对方案的影响 |
|------|------|------|-------------|
| V1 | 引擎具备多帧解码，逐帧 `getNextFrame` + 正确 duration | ✅ 成立 | 无需自研解码 |
| **W1** | **Windows 桌面 `Image` widget 路径下 GIF 真的会逐帧播放** | ✅ **成立**（2s 收到 19 帧回调，10cs=100ms/帧，精确匹配） | 零依赖方案可行，**不需要 gif_view** |
| **V2 / V2b / W2** | `cacheWidth` / `ResizeImage` 能限制动图解码尺寸 | ❌ **证伪**（引擎层 + 真机双重确认：请求 100，实际仍 200×150） | 🔴 **推翻原计划的「1920 限宽解码」**：动图必须靠上传门槛卡尺寸 |
| V2c / W3 | `cacheWidth` 对静态图有效（对照组） | ✅ 成立（PNG 1920×1053 + cacheWidth=100 → 解码为 100×54） | 静态分支保持原样 |
| V3 / **W6** | `precacheImage` 对动图可用 | ✅ 真机正常（1920×1053×6 帧仅 **27ms**）；flutter_tester 里的 15s 超时是**假 async 环境假象** | 现有 `await precacheImage` 流程**不需要改**，也**不是**存量 bug |
| V4 | 同 provider key → 共享同一解码器 | ✅ 成立（`identical(completer)` = true）；不同 cacheWidth → 分叉 | 三个渲染点必须统一 provider 形态，否则起多个解码器 |
| **V6 / W4** | ImageCache 对多帧图的计费口径 | ✅ **只按首帧计费**（500×500×20 帧的 GIF，`currentSizeBytes` 只增加 1,000,000 = 恰好单帧） | 🔴 64MB 预算对动图**低估 20 倍**，必须主动 evict |
| V5 / W7 | 模糊 + 动图的逐帧代价 | ⚠️ 有数据（见 §5），**无掉帧**，但 p95 尖峰 8 倍 | R1（动图+模糊→静态）保留，但依据从「推断」升级为「实测」 |
| V7 / V7c | 块级扫描器的正确性与性能 | ✅ 吞吐 **5.4 GB/s**（5.31MB / 0.98ms）；帧数与引擎 `frameCount` **4/4 完全一致**（含 2 个真实 GIF） | 扫描器可直接移植；**无需 isolate** |

**一句话**：零依赖方案成立（会播、性能可接受），但**「靠 cacheWidth 给动图限尺寸」这条路被彻底堵死**，必须改由上传门槛保证单帧尺寸。

---

## 1. 关键证伪：cacheWidth 对多帧 GIF 无效

这是本次最重要的发现，直接改变方案设计。

```
V2（引擎 API 直测，instantiateImageCodec）
  请求 targetWidth=100，原图 200x150
  第1帧实际尺寸: 200x150     ← 未缩放
  第2帧实际尺寸: 200x150     ← 未缩放
  生效: false

W2（真机生产路径，ResizeImage(FileImage(gif), width: 100)）
  实际: 200x150
  cacheWidth 生效: false

V2c/W3（对照组：静态 PNG）
  PNG 1920x1053 + cacheWidth=100 → 实际 100x54   ← 静态生效
  PNG 1920x1053 原尺寸          → 实际 1920x1053
```

**后果**：方案原定「动图也按 1920 限宽解码」不可实现。一个 4096×4096 的 GIF 会以原尺寸逐帧解码 —— 单帧 67MB。
因此**把动图的分辨率门槛从 4096×4096 下调为 1920×1080（单帧像素 ≤2,073,600）**，静态图维持 4096×4096。
若用户强需更大尺寸的动图，唯一出路是上传时重编码（本期明确不做）。

---

## 2. 动图确实会播放（核心假设成立）

```
W1 真机（Windows debug 窗口，10cs/帧 = 10fps）
  图像已加载: true
  首帧尺寸: 200x150
  2 秒内帧回调次数: 19        ← 预期 ~20，精确匹配
  结论: ✅ 会动
```

`ui.Codec.repetitionCount` 语义（V8）确认：

| GIF 循环方式 | `frameCount` | `repetitionCount` | 含义 |
|---|---|---|---|
| Netscape 扩展 loop=0 | 5 | **-1** | 无限循环 |
| Netscape 扩展 loop=3 | 5 | **3** | 播 3 轮 |
| 无 Netscape 扩展 | 5 | **0** | 只播一轮 |

→ 常见网图（带 Netscape 扩展、loop=0）会**无限循环**播放，符合背景图预期，无需额外处理。

---

## 3. ImageCache 计费：只算首帧（P0 风险确认）

```
W4 真机
  静态 PNG 1920x1053 加载后: 8,087,040   ← 1920×1053×4，精确单帧
  GIF 500x500x20 加载后:     1,000,000   ← 500×500×4，**20 帧却只算 1 帧**
  GIF 相对单帧倍数: 1.00
```

源码侧佐证：`ImageStreamCompleter.sizeBytes => image.height * image.width * 4`
（`flutter/packages/flutter/lib/src/painting/image_stream.dart:129`），
且 `ImageCache._trackLiveImage` 只取首帧 `info.sizeBytes`。

**后果**：64MB 的 `imageCache.maximumSizeBytes`（`lib/core/portable_image_cache_manager.dart:62`）
对动图**严重低估**，LRU 不会及时淘汰动图条目。反复切换多个 GIF 背景时，内存会单调上涨。

**对策（已写入方案 R7）**：动图配置变更时**主动 evict** 旧 provider，且延迟到过渡动画结束后执行
（避免打断 120ms 交叉淡入淡出）。**不在 `dispose` 里 evict** —— 页面切换/重建可能触发 dispose，
过早 evict 会导致重新解码。

---

## 4. provider 共享与分叉（决定「必须统一 provider 形态」）

```
V4
  同 FileImage(path) 两次            → 同一个 completer: true
  同 ResizeImage(1920) 两次          → 同一个 completer: true
  FileImage vs ResizeImage(1920)     → 同一个 completer: false   ← 分叉
```

**结论**：`ImageCache` 以 provider key 区分。三个共用渲染点（标题栏 / BPM 回退 / 设计器预览）
若 provider 形态不一致，会各自建立独立解码器 —— 动图场景下等于**同一张 GIF 被解码多份并各自播放**。
→ 动图分支的 provider 必须由 `BackgroundImageResolver` 统一构造，**不允许调用点自行传 cacheWidth**。

---

## 5. 模糊 + 动图的逐帧代价（真机数据）

真机 debug 窗口，1920×1053 动图作为全屏背景，2 秒采样（`FrameTiming.rasterDuration`）：

| 场景 | raster 平均 | raster p95 | 超 16.7ms 帧数 | build 平均 |
|------|------------|-----------|---------------|-----------|
| A 静态 PNG（同尺寸）无模糊——基线 | 415 µs | 539 µs | 0 | 1203 µs |
| B 动图 无模糊 | 563 µs | 605 µs | 0 | 1030 µs |
| C 动图 σ8 | 1022 µs | 1900 µs | 0 | 1011 µs |
| D 动图 σ20 | 1365 µs | **4990 µs** | 0 | 897 µs |

解读：
- 动图本身（B vs A）只增加 **+148 µs（+36%）**，代价温和 → 动图背景**不加模糊时可以放心开**。
- 模糊才是主项：C 相对 B **+82%**，D 相对 B **+143%**，且 D 的 **p95 从 605µs 飙到 4990µs（8.2×）**。
  尖峰形态与「GIF 换帧 → 纹理上传 → 全屏模糊重栅格化」的机制吻合。
- 本机窗口未最大化，所有场景都未掉帧；但代价随**画布面积**线性增长 ——
  用户最大化到 2560×1440（面积 ×2.25）时 D 的 p95 将接近 11ms，1440p 全屏则大概率掉帧。

**结论**：R1（**动图 + blurSigma>0 → 只显示静态首帧**）保留，且现在有实测支撑而非纯推理。

> ⚠️ 数据限制：debug（JIT）模式，绝对值高于 release；应视为**相对量级**参考。

---

## 6. 块级扫描器：正确性与性能

**正确性交叉验证**（与引擎 `ui.Codec.frameCount` 逐一对齐）：

| 样本 | 体积 | 扫描器 | 引擎 frameCount | 一致 |
|------|------|--------|----------------|------|
| 夹具 200×150×6 | 99 KB | frames=6, delay=60cs, 10.0fps | 6 | ✅ |
| 夹具 500×500×20 | 2.76 MB | frames=20, delay=200cs | 20 | ✅ |
| **真实** `demo-cli.gif` | 130 KB | 581×370, frames=286, 15.0fps | 286 | ✅ |
| **真实** `demo-gui.gif` | 1.29 MB | 1026×800, frames=214, 15.0fps | 214 | ✅ |

两个真实世界 GIF 来自参考项目 `ludusavi-master/docs/`，含真实的 Netscape 循环扩展、
局部调色板与注释扩展 —— 扫过去全部正确，说明块级跳跃逻辑覆盖了真实文件形态。

**性能**：5.31 MB 全量扫描 **0.98 ms**（≈5.4 GB/s）；上限截断（100 帧）0.065 ms。
→ 10MB 文件扫描约 **2 ms**，配合 `File.readAsBytes` 的异步读盘，**不需要 isolate**。
方案中「Phase 4 治理层」原列为 compute()，现简化为同 isolate 直算（已同步到实现）。

---

## 7. 环境限制与探针自身缺陷（诚实记录）

- **flutter_tester 无法验证 provider 路径**：`ImageProvider.resolve` + listener 在 widget test
  的假 async 环境下不回调（`Image widget` 加载完成也不触发），`ImageCache` 也不计费。
  第一轮 probe 里 `precacheImage(GIF)` 显示 15s 超时，**是真机不存在的假象**（W6 真机 27ms）。
  → 凡涉及真实解码/缓存的结论，一律以 `win_probe_main.dart` 真机数据为准。
- **手写 PNG 夹具不可用**：`gif_fixtures.dart` 的 `buildPng` 产出的 PNG 引擎解不开
  （W3 第一轮 `null(未回调)`）。已改用项目真实素材 `assets/images/themes/blue_sky.png` 做对照。
  Phase 1 单测里的 PNG 夹具**只用于头部解析**（校验层不解码像素），因此不受影响；
  另有真实 PNG 用例覆盖。
- **`flutter run` 卡在 VM Service**：本机 shell 注入了 `HTTP_PROXY/HTTPS_PROXY`，
  会劫持 WebSocket，导致探针 app 退出后 `flutter run` 长时间重试。
  探针在 `exit(0)` 前已把结果写入 `dev_probe/win_results.json`，不受影响。
- **真机探针必须注入 `PROGRAMFILES(X86)`**：本 shell 缺该变量，不加会直接
  `Error: %PROGRAMFILES(X86)% environment variable not found.` 早退。

---

## 8. 对方案的具体修订（已同步进实现）

1. 🔴 **动图分辨率门槛 4096×4096 → 1920×1080**（单帧像素 ≤ 2,073,600），静态维持 4096×4096。
   拒绝文案必须说明原因（动图无法降采样解码）。
2. 🔴 **动图分支不得使用 `cacheWidth`**（无效且误导），改为 `filterQuality: low` + `gaplessPlayback: true`。
3. 🔴 **R7 释放策略**：只在配置变更时延迟 evict（过渡结束后），不在 dispose 里 evict。
4. ✅ **`precacheImage` 流程保持不动**（原担心的存量 bug 不存在）。
5. ✅ **校验层不加 isolate**（实测 2ms 级），简化实现。
6. ✅ 复核 **R1 保留**（实测 p95 尖峰 8.2×）。
