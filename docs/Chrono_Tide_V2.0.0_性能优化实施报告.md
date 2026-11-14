# Chrono Tide V2.0.0 性能优化实施报告

- **日期**：2026-08-29
- **范围**：按性能审计结论执行，**不换官方 OpenList**（用户决策）、**服务端一律不碰**（用户决策）
- **约束**：保功能完整、交互体验与用户信任不受影响；不升级依赖、不换技术栈、最小改动

---

## 一、已实施项

### 1. Magpie effects 裁剪 —— 产物 −13MB

| 项 | 内容 |
|---|---|
| 位置 | `windows/runner/magpie/effects/`（打包源，CMakeLists:168 指向此处） |
| 删除 | `CuNNy`(4.9M)、`CuNNy2`(2.4M)、`RAVU`(2.8M)、`NNEDI3`(2.5M) |
| 依据 | 全库仅 `assets/magpie/scaling_modes_template.json` 声明效果引用，模板只用到 Anime4K / FSR / FSRCNNX / ACNet / CRT / Lanczos / Bicubic / Nearest 等；四个目录无 config 引用（`windows/runner/magpie/config/` grep 无命中） |
| 效果 | effects 目录 17MB → **4.0MB** |
| 风险控制 | 只删四个大目录，SMAA/xBRZ/NIS/Sharpen/CAS/FXAA/Pixel Art 等小体积项（合计 <1MB）全部保留，避免误伤 Magpie 托盘 UI 的手动选择；项目根目录 `Magpie-v0.12.1-x64` / `Magpie-dev` 保留完整备份 |

### 2. manifest.yaml gzip 化 —— 产物 −14.5MB（安装包约 −2~3MB）

| 项 | 内容 |
|---|---|
| 改动 | `assets/data/manifest.yaml`（16.7MB）→ `manifest.yaml.gz`（**2.27MB**，压缩率 87%） |
| 代码适配 | `services/manifest_service.dart`：`rootBundle.load` + `GZipCodec().decode` + `utf8.decode`（`dart:io` 内置，无新依赖） |
| 关联改动 | `pubspec.yaml:57` asset 声明；`test/services/save_manifest_parse_test.dart` 同步改为读 gz 解压 |
| 验证 | Python 往返校验：`gzip` 解压后与原文件字节完全一致 |
| 风险控制 | 加载失败已有降级路径（`isReady=false` → SaveScanner 回退通用检测）；本服务已在首帧后加载 |

### 3. 启动链优化：首帧前任务后移 —— 冷启动提速

`main.dart` 原为 22 步串行 await，全部在 `runApp()` 之前。现把不涉及首帧渲染的 6 项移到首帧后：

| 移出项 | 说明 |
|---|---|
| `ManifestService.init` | **最大单项**，16.7MB YAML 解析（估 0.3~1.5s）；gz 化后更快 |
| `LogRotationService.rotateAll` | 纯清理任务 |
| `ScreenshotFetchService.scanPendingGames` | 截图任务恢复 |
| `MetadataFetcher.init` | VNDB 字典 + 数据源 + 缓存 |
| `DiscoverMetadataService.init` | 探索页缓存（依赖前者，顺序保持不变） |
| `WatchFolderService.startAll` | 文件夹监控 |

实现要点：`runApp()` 之后直接写代码**仍会先于首帧执行**（warm-up frame 排在后续 Timer 中），
因此经 `Future.delayed(200ms, _initPostFirstFrame)` 让出首帧，新函数内各步保持原有依赖顺序与异常保护。

### 4. didChangeDependencies 守卫 —— 消除 resize 全量重扫

`pages/library_page.dart`：`didChangeDependencies` 原先每次触发都执行 `_refreshFromDisk()`
（全量 `scan()` + 自定义排序读取 + 封面全量解析）。主题切换、**窗口 resize/最大化**均会触发。

改为不再在此回调刷新。首次加载由 `initState` 的 `_refreshFromDisk()` 负责（原本每次挂载实际扫了 **两遍**）；
后续数据一致性由 `_onRegistryChanged`（结构性变化 → `_loadGames`）与详情弹窗关闭后的 `_silentRefresh` 维护。

### 5. Image.file 补 cacheWidth —— 12 处

限制解码尺寸，避免高分辨率原图全量解码造成的内存尖峰（4K 截图单张约 33MB）。

| 场景 | cacheWidth | 位置 |
|---|---|---|
| 截图轮播主图 | 1920 | `widgets/screenshot_carousel.dart:457` |
| 全屏背景（2 处） | 1920 | `theme/background_image_resolver.dart` |
| BPM 全屏封面 | 1920 | `big_picture/pages/big_picture_home.dart:205` |
| 详情封面（3 处） | 600 | `game_detail_dialog.dart`、`big_picture_detail.dart` |
| 卡片封面（5 处） | 480 | `home_page`、`big_picture_home/game_card/metadata_section`、`smart_import_section` |
| 批量卡片小图 | 132 | `batch_import_section.dart` |
| 缩略图 | 240 | `field_lock_button.dart` |

（另 3 处原本已有限宽，未改动：`home_page:1377`、`library_page:2932`）

### 6. _loadLaunchModes 缓存 —— 消除 O(N) 重复读盘

`pages/library_page.dart:800`：原先每次结构性刷新都对**全部游戏**逐个读 `game.json`（O(N) 次磁盘读）。
加 `_launchModesLoaded` 集合，已读过的游戏跳过；外部修改（启动管理对话框）经回调
`_localeModes[title] = mode` 保持内存同步。

---

## 二、评估后**否决**的项（含理由）

按"保证功能完整、交互体验与用户信任不受影响"的硬约束，以下项经评估后**不实施**：

| 项 | 预期收益 | 否决理由 |
|---|---|---|
| **换官方 OpenList** | 产物 −85~105MB | 用户明确决策不换 |
| **游玩时长落盘降频 2s→10~15s** | 写放大 18~90MB/h → 1/5 | **收益不成立**：90MB/h × 4h/天 ≈ 每年 131GB，对主流 500GB SSD（约 300TBW）仅占 0.04%；代价是崩溃/强杀时丢失最近 10~15 秒时长——游玩时长是用户核心资产，直接损害用户信任。收益极小而损失用户可感知，不做 |
| **志莽行书字体子集化** | −2.5MB | 该字体用于渲染**动态字符**（`big_picture_detail.dart:521` 渲染游戏名首字 `initial`，全库 65 处引用）。子集化会缺字——游戏名可为任意中日文字符 |
| **主题图 PNG → WebP** | 产物 −1.5MB | 环境无 Pillow，需新装工具；收益小。建议后续备好工具链再做 |
| **app_icon.ico 重制** | −0.6MB | 解析发现 3 个重复的 256×256 条目（374KB+117KB+264KB）。属品牌资产，手工裁剪风险不匹配收益，建议用专业图标工具重制 |
| **app.so --obfuscate** | −1~3MB | 收益小，代价是崩溃堆栈不可读、需管理符号文件。当前刚完成 24 处缺陷修复，排障能力比 1~3MB 更重要 |
| **500ms 前台检测降频** | 轻微 | FFI 正常路径已是毫秒级，上次优化已给 PowerShell 回退加 60s 节流，再降频收益有限 |

---

## 三、验证

（待补：analyze / 测试 / 构建 / 体积对比）

---

## 四、长期防劣化建议

### 体积防劣化（CI 可落地）
1. **产物体积阈值**：在构建脚本中统计 `build/windows/x64/runner/Release` 总体积与
   `runtime/`、`data/flutter_assets/` 分项体积，超过阈值（建议产物 220MB / assets 20MB）即失败并输出增量明细
2. **大文件白名单**：对新增 >5MB 的资产要求显式登记（路径 + 用途 + 是否可懒加载），进 PR 检查清单
3. **第三方二进制版本登记**：`runtime/` 下每个 exe/dll 记录来源与版本，避免再次出现
   "148MB 的 openlist.exe" 这类无人核对的第三方产物

### 性能监控（轻量）
1. **冷启动分段计时**：在 `main.dart` 首帧前后各打一个时间戳，落日志；关注 `_initPostFirstFrame` 耗时
2. **首帧后任务耗时**：`ManifestService.init` 等各步单独计时，异常变慢可被发现
3. **内存/图片**：关注 `flutter_assets` 与图片缓存水位（桌面端可用任务管理器粗测，无需埋点）

### 下次可继续的方向（按性价比）
1. 主题图 WebP（补工具链后，−1.5MB）
2. ico 专业重制（−0.6MB）
3. 若未来启用 Play Store / Microsoft Store 分发，重新评估 OpenList 精简与符号剥离
