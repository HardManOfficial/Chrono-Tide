# BPM 自定义背景图 + OP 视频背景播放 — 实施方案

> 建立日期：2026-09-26　状态：**待批准（阶段 A 只读审计产出，尚未动任何代码）**
> 参考：B 站 Playnite「最好看的 Gal 启动器主题 —— ubiquity」个人改造视频
> 关联档案：`docs/DEV/features/big_picture_v3_cinema.md`（BPM v3.x 全量演进史）
> 关联 ADR：`ADR-009`（动态背景图零依赖原生播放）、`ADR-010`（减少动效偏好）、`ADR-012`（schema 版本链）

---

## 0. 结论摘要（TL;DR）

| 项 | 结论 |
|---|---|
| **本期做什么** | ① 每游戏可上传**自定义背景展示图**（仅 BPM 大屏）；② 每游戏可上传 **OP 视频（mp4）**；③ 主页底部栏选中游戏**停留 3s** 后封面淡出、视频在 UI 背后播放，播完淡出恢复封面 |
| **视频技术选型** | **`video_player_win` 3.2.2**（Windows Media Foundation，BSD-3，仅 +约 130KB dll，零 GPL/LGPL）+ 官方 `video_player` 作为 app-facing API。**用户已拍板** |
| **为什么不选 media_kit** | 安装包 +约 40MB（捆绑 libmpv），与项目「轻量 + 体积克制」基线冲突；OP 场景仅需 MP4/H.264，MF 原生覆盖 |
| **音频** | **加设置开关，默认静音**（用户已拍板） |
| **重播规则** | **提供开关，默认「每次选中都播」**（用户已拍板） |
| **背景图作用范围** | **仅 BPM 大屏模式**，桌面零影响（用户已拍板） |
| **落点** | 背景层是 shell 层**单一 widget 树** `_buildBackdrop()`（`big_picture_shell.dart:1039`），选中信号已就位（`_stageGame`），新增一层视频层即可 |
| **改动面** | 新增 4 文件；修改 6 文件，其中 **2 处属稳定区/需显式批准**：`pubspec.yaml`（新增依赖）、`lib/main.dart`（注册插件 + 载入偏好） |
| **schema** | 新增 2 个字段走 **`updateGameJson` merge**（与既有 `bpm_backdrop_x/y/zoom` 同构），**不升 `format_version`、零迁移**（理由与证据见 §5） |
| **最大风险** | P0 = 插件注册改稳定区 `main.dart`；P1 = MediaFoundation 依赖系统 codec（冷门编码可能黑屏）；P1 = 现有 backdrop scrim 会明显压暗视频（`0xA6`≈65%），需为播放态引入专用遮罩令牌 |
| **Phase 0** | **必须先做技术验证**：插件在 Flutter 3.24.3 编译、Texture 层 z 序、3s 预热时序、`isCompleted` 可靠性、dispose 无泄漏、1080p 解码开销 |

---

## 1. 背景与目标

### 1.1 用户原话拆解

用户想复刻 Playnite 的 Galgame 主题（ubiquity）观感，明确要 3 种 BPM 主页背景：

1. **游戏封面背景**（现有能力）；
2. **封面图 + OP 视频播放**（本期新增）。

用户描述的交互效果（原文）：

> 上传了视频的游戏在封面图背景展示 3s 后自动播放视频，效果设计：在主页底部栏选中的游戏在经过 3s 后封面图淡淡的消失随后播放视频，播放过程中主页如大标题、详情等组件保持不变，视频在背后播放但尽可能清晰，视频完整播放直至结束，结束后淡淡恢复原背景图。

另外要求：现有「游戏背景图可调整截取位置」的能力要保留，并**支持用户自行上传图片作为对应游戏的背景封面展示图**。

### 1.2 目标（可验收）

| # | 目标 | 验收方式 |
|---|---|---|
| G1 | 在 BPM 编辑窗口可为单个游戏上传自定义背景图，BPM 大屏用它替换封面作为 backdrop | 真机：上传后主页背景变为该图；桌面不受影响 |
| G2 | 在 BPM 编辑窗口可为单个游戏上传 OP 视频（mp4），可移除 | 真机：文件落到游戏目录、`game.json` 写入字段、可删除 |
| G3 | 主页底部栏选中（含焦点移动与点击）停留 3s → 封面**淡出** → 视频在 UI 层背后播放 | 真机：计时、交叉淡入、UI 组件纹丝不动 |
| G4 | 视频完整播完 → **淡出** → 恢复原背景（封面或自定义背景图） | 真机：播完自动恢复，无残留黑帧 |
| G5 | 播放中切换游戏 / 离开主页 / 打开详情面板 / 退出 BPM → 立刻停播并恢复背景 | 真机：无音频残留、无解码器泄漏 |
| G6 | 音频默认静音，可在设置中开启；重播默认「每次选中都播」，可改为「每进入一次只播一次」 | 设置页两个开关生效 |
| G7 | 没有视频的游戏，行为与改动前**逐位一致**（零回归） | 存量用例 + 真机 |

### 1.3 非目标（本期明确不做）

- ❌ **不做桌面模式**：自定义背景图与 OP 视频**仅 BPM 大屏**使用（用户拍板）。
- ❌ 不做在线/流媒体视频，**仅本地文件**。
- ❌ 不做视频剪辑 / 转码 / 抽帧做封面。
- ❌ 不做视频循环播放（用户明确要求「完整播放直至结束」）。
- ❌ 不做视频音量渐入渐出、不做播放进度条 / 控制条（背景用途，不需要控件）。
- ❌ 不改动现有封面背景链路、不改 `NsfwImage` 本体、不改 `BpmSmartAlignedImage` 的显著性算法。
- ❌ 不引入 `media_kit` / `fvp` / `dart_vlc`。
- ❌ 不重构 `_buildBackdrop` 的既有遮罩算法（只新增「播放态遮罩」分支）。

---

## 2. 现状调研（全部带 `文件:行号`）

### 2.1 背景渲染链路（**核心**）

| 事实 | 位置 |
|---|---|
| 全屏背景由 **shell** 渲染（非 home 页），`Stack` 首个子项 | `big_picture_shell.dart:909` 调 `_buildBackdrop()`；定义 `big_picture_shell.dart:1039-1140` |
| 背景层结构：`[主题底渐变, 图片层, 径向微光, 纵向遮罩, 横向遮罩]` | `big_picture_shell.dart:1084-1137` |
| 图片层：`NsfwImage.file` → `Transform.scale` → `BpmSmartAlignedImage` | `big_picture_shell.dart:1053-1069` |
| 解码宽度按物理像素 clamp(1280,4096) | `big_picture_shell.dart:1045-1046` |
| 「当前选中游戏」状态：`_stageGame` | `big_picture_shell.dart:108` |
| 选中链路：`_ShelfCard.onSelected` → `onStageGameChanged` → shell `_onStageGameChanged` | `big_picture_home.dart:754` → `:335-344` |
| **焦点即选中**（键盘/手柄移动焦点也切舞台） | `big_picture_home.dart:874-876` |
| 封面路径解析：优先 `coverUrl`（本地绝对路径），回退 `findCoverFile` | `big_picture_shell.dart:324-333` |
| 手动对齐缓存：`_backdropAdj` ← `BpmBackdropAdjustment.read` | `big_picture_shell.dart:347-354` |
| 换游戏**无过渡动画**（瞬时替换，无 `AnimatedSwitcher`） | `big_picture_shell.dart:1039-1140` 无动画包装 |
| 页面切换有 200ms fade（仅 stage，不含背景） | `big_picture_shell.dart:1150-1155` |
| 遮罩令牌（深色）：`backdropScrimV` 底段 `0xA6`(65%)；`backdropScrimH` 左段 `0x8A`(54%) | `bpm_theme_controller.dart:221-232` |
| 遮罩令牌（浅色）：`backdropScrimV` 底段 `0x6B`；`backdropScrimH` 左段 `0x61` | `bpm_theme_controller.dart:292-303` |
| NSFW：背景包 `NsfwImage.file`，未判定完成即整图模糊 σ14 | `big_picture_shell.dart:1053`；`widgets/nsfw/nsfw_image.dart:697-699` |

> ⚠️ **关键结论**：换游戏是「瞬时替换」，**没有任何交叉淡入淡出**。用户要求的「淡淡地消失 / 淡淡地恢复」是**新增能力**，必须自己引入动画包装（本期新增，不改既有行为——用 opacity 动画包住新增层，无视频时不产生任何动画）。

### 2.2 上传 / 持久化既有范式

| 事实 | 位置 |
|---|---|
| BPM 替换封面：`FilePicker(type: FileType.image)` → 白名单 jpg/jpeg/webp 否则 png → 文件名 `cover_user_<ms>.<ext>` → `copy` 到 `$_metaDataDir/` → `updateGameJson({'cover_file': newName})` → 内存同步 + `notifyDataChanged()` | `bpm_game_edit_dialog.dart:93-128` |
| 截图同款：`screenshots/` 子目录 + 相对名 `screenshots/user_<stamp>_<i>.<ext>` + `screenshot_files` | `bpm_game_edit_dialog.dart:132-169` |
| 全局主题背景图上传：白名单 + `BackgroundMediaInspector` 内容校验 + UUID 文件名 → `data/user_backgrounds/` → 存**主题 JSON** | `theme_storage.dart:281-327` |
| BPM 背景裁剪参数：`BpmBackdropAdjustment`，字段 `bpm_backdrop_x/y/zoom`，**不在 GameDataFormat 建模**，BPM 侧直接 `updateGameJson` merge | `bpm_backdrop_tuner.dart:22-81`（读 `:56-66`、写 `:69-71`、重置 `:74-80`） |
| 单游戏元数据目录：`Games/<safeName>/`，含 `game.json`、`cover.png` 或 `cover_user_*`、`screenshots/`、`bpm_play_history.json` | `path_helper.dart:63-86`；`local_game_registry.dart:1080` |
| 应用自有目录归属闸门 | `path_helper.dart:234-255`（`isInsideAppStorage`） |
| 每游戏 JSON 落盘的非建模范式：`bpm_play_history.dart:49-104`（纯 `dart:io`，不走写队列） | `big_picture/services/bpm_play_history.dart` |

### 2.3 全局偏好范式（音频/重播开关照它做）

| 事实 | 位置 |
|---|---|
| `MotionPreference`：`ChangeNotifier` 单例 + pref key + `load()`/`setXxx()` + `resetForTest`/`seedForTest` | `lib/services/motion_preference.dart` 全文（83 行） |
| 首帧前加载（必须） | `main.dart:449` `await MotionPreference.instance.load();` |

### 2.4 game.json 字段与写机制

| 事实 | 位置 |
|---|---|
| `currentVersion = 3`；迁移链 `{1: _migrateV1ToV2, 2: _migrateV2ToV3}` | `game_data_format.dart:31`、`:41-45` |
| 覆盖黑名单 `_overwritableFields`（不在集合内 = 重复入库时保留） | `game_data_format.dart:180-211` |
| `writeGameDir` 的 `gameData` map（新入库默认值） | `game_data_format.dart:322-363` |
| `GameJsonData` 类字段 | `game_data_format.dart:1414-1503` |
| `GameJsonData.fromJson` | `game_data_format.dart:1554`（唯一调用方 `:1071`，在 `readGameJson` 内） |
| `GameJsonData.toJson` 定义 | `game_data_format.dart:1614` |
| ⚠️ **`GameJsonData.toJson()` 在 `lib/` 下无生产调用方**（已 grep 全库确认）→ **当前不存在「全量序列化写回 game.json」的路径** | 见 §5 决策依据 |
| ADR-012 纪律：字段新增 / 改名 / 语义变更必须 ①追加迁移 ②升版本 ③补测试 | `game_data_format.dart:27-30`；`docs/DEV/DECISIONS.md:405-446` |

### 2.5 视频能力现状

**结论：项目当前零视频依赖、零视频代码。** 全库搜 `video_player | media_kit | fvp | mpv | dart_vlc | chewie | VideoPlayer | ffmpeg`，`lib/` 内**零命中**；`pubspec.yaml:9-34` dependencies 无任何视频包。现状「动态背景」**仅支持 GIF**（`ADR-009`），且是用零依赖原生 `Image` 播的，**没有暂停 / seek / 只播一次 / 限帧的公开 API**（`DECISIONS.md:295-297`）—— 因此 OP 视频**必须新增播放器依赖**，无法复用 GIF 那条链路。

---

## 3. 技术选型（含被淘汰项）

### 3.1 候选对比

| 方案 | 体积代价 | 许可 | 格式支持 | 维护 | 判定 |
|---|---|---|---|---|---|
| **`video_player_win` 3.2.2** | **+约 130KB**（单个 dll），复用系统 MF 解码器 | **BSD-3**，官方声明「No GPL / LGPL 3rd-party library inside」 | 依赖 Windows 预装 codec；**MP4/H.264/AAC 原生支持** | 3.2.2 发布于约 7 个月前，fluttergems 标 Good | ✅ **采用（用户拍板）** |
| `media_kit` 1.2.6 + `media_kit_video` + `media_kit_libs_video` | 捆绑 libmpv，**安装包 +约 40MB**（移动端更甚） | LGPL 合规版（可商用） | 几乎全格式（FFmpeg） | 最活跃（2026-08 仍有提交） | ❌ 体积与项目基线冲突 |
| `fvp` | **约 10MB**（3 个动态库），用系统 ffmpeg 可降到约 2MB | MIT | FFmpeg 全格式 + D3D11 硬解 | Good | ❌ 作为官方 `video_player` 替代后端，生态小众；体积仍高于选型 A |
| `dart_vlc` / `flutter_vlc_player` | 依赖 VLC | — | 全格式 | 已停更 / 依赖外部 VLC | ❌ 已淘汰 |
| 复用 ADR-009 的零依赖 GIF 链路 | 0 | — | 需用户把 mp4 转 GIF（体积爆炸、无音频、无暂停） | — | ❌ 不可行（用户明确要 mp4 + 完整播放） |

### 3.2 选型 A 的已知局限（**必须在方案里兜底**）

来自官方 README 的原文声明：

1. **「This package use texture to display video, so play 4K or 60fps video should be slow」** → 本项目背景视频场景必须限制分辨率（建议 ≤1080p/30fps，见 §5 门槛）。
2. **播放依赖系统预装 codec**：「All the media format can be played by WMP can also be played by this package」→ 冷门编码（HEVC 需装「HEVC 视频扩展」、AV1 需商店扩展）**可能黑屏或初始化失败** → 必须 `errorBuilder` / `catchError` 兜底并**静默回退封面**（不弹错误打断用户）。
3. **不支持 HLS（.m3u8）** → 与本期无关（仅本地 mp4）。
4. 需要显式注册：`if (!kIsWeb && Platform.isWindows) WindowsVideoPlayer.registerWith();`（官方 README「Quick Start」）→ **这是稳定区 `main.dart` 的改动**。

### 3.3 依赖新增（**需用户显式批准**）

```yaml
# pubspec.yaml dependencies 段追加
  video_player: ^2.4.7        # app-facing API（官方，Windows 端无实现，由 video_player_win 补齐）
  video_player_win: ^3.2.2    # Windows 平台实现（Media Foundation）
```

> ⚠️ AGENTS.md §2.3 明令「禁止修改 `pubspec.yaml` 的依赖版本」——此处属**任务明确要求的新增依赖**，必须走显式批准。

---

## 4. 架构设计

### 4.1 分层图

```
┌─ 偏好层（新增） lib/services/bpm_op_video_preference.dart ──────────────┐
│  op_video_sound_enabled         默认 false（静音）                       │
│  op_video_autoplay_always       默认 true（每次选中都播）                 │
│  仿 MotionPreference：ChangeNotifier 单例 + main.dart 首帧前 load()      │
└────────────────────────────────────────────────────────────────────────┘
                                  │ 订阅
┌─ 状态机层（新增） lib/big_picture/services/bpm_backdrop_media_controller.dart ─┐
│  状态：idle → arming(3s) → fadingIn → playing → fadingOut → idle            │
│  职责：3s 计时 / 预热 initialize / play / 监听 isCompleted / dispose         │
│  可注入播放器工厂 → 纯逻辑部分可单测（不依赖真解码）                          │
└────────────────────────────────────────────────────────────────────────┘
                                  │ 通知
┌─ 渲染层  lib/big_picture/big_picture_shell.dart（_buildBackdrop 扩展）──────┐
│  Stack: [主题底, 图片层(可淡出), ★视频层(新增), 微光, ★播放态遮罩(新增), 纵横遮罩] │
│  新增 widget: lib/big_picture/widgets/bpm_op_video_layer.dart               │
└────────────────────────────────────────────────────────────────────────┘
                                  ▲ 驱动
┌─ 触发源 ────────────────────────────────────────────────────────────────┐
│  _stageGame 变化（big_picture_shell.dart:335-344）/ currentPage 变化       │
│  / 面板开合 / BPM 退出 / 应用生命周期                                       │
└────────────────────────────────────────────────────────────────────────┘
                                  ▲ 数据
┌─ 数据层 ────────────────────────────────────────────────────────────────┐
│  game.json: bpm_custom_backdrop / bpm_op_video（相对 metaDataDir 的相对路径）│
│  文件落点: Games/<safeName>/ 内（与 cover_user_* / screenshots/ 同层）      │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.2 状态机（`bpm_backdrop_media_controller.dart`）

| 状态 | 进入条件 | 行为 | 退出 |
|---|---|---|---|
| `idle` | 初始 / 恢复完成 | 只显示图片层 | 选中游戏有视频且 `currentPage==0` → 启动 3s `Timer` → `arming` |
| `arming` | 3s 计时中 | **同时**开始 `initialize()` 预热（关键：把耗时挪到这 3s 内） | 3s 到 → `fadingIn`；期间换游戏/离开 → `cancel()` 回 `idle` |
| `fadingIn` | 预热完成且计时到 | 图片层 240ms 淡出至 0 + 视频层淡入至 1，然后 `play()` | 动画结束 → `playing` |
| `playing` | 播放中 | 监听 `controller.value.isCompleted` | 播完 / 被打断 → `fadingOut` |
| `fadingOut` | 播完或被切断 | 视频层 240ms 淡出 + 图片层淡入 | 动画结束 → `dispose()` 播放器 → `idle` |

**打断规则（统一收敛到一个 `cancel()`）**：

| 触发 | 行为 |
|---|---|
| `_stageGame` 变为另一个游戏 | `cancel()` 立即停播 + 释放，新游戏重新计时 |
| `currentPage != 0`（切到我的库 / 打开导入窗口） | `cancel()` |
| 打开详情面板（`_panelGame != null`） | `cancel()`（面板打开时把背景让给面板） |
| 退出 BPM（`BigPictureManager.exit()` / shell dispose） | `cancel()` + `dispose()` |
| 应用最小化 / 窗口失活 | 建议 `pause()`（可选，见开放问题 Q4） |

**重播规则实现**：`op_video_autoplay_always == true` → 每次 `_stageGame` 变化都走完整流程；`false` → 本会话内已自动播过的 `game_id` 记入内存 `Set`，后续选中只显示封面（可手动触发，见开放问题 Q3）。

### 4.3 渲染层细节

**视频层的 cover 语义**（BPM 背景是全屏 `BoxFit.cover`，视频必须同样铺满而非留黑边）：

```dart
// bpm_op_video_layer.dart（示意）
Positioned.fill(
  child: Opacity(
    opacity: fade,                       // 0..1 由状态机驱动
    child: FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),   // Texture 渲染，z 序可控
      ),
    ),
  ),
)
```

**插入位置**：`big_picture_shell.dart:1094` 的 `if (imageLayer != null) imageLayer,` 之后、`:1096` 微光层之前。

**播放态遮罩（新增令牌）**：现有 `backdropScrimV` 底段 `0xA6`(65%) 是为静态封面 + 底部 shelf 文字可读设计的，直接盖在视频上会**明显压暗**（与「视频尽可能清晰」冲突）。方案：在 `BpmPalette` 新增一组**播放态遮罩令牌**（如 `backdropScrimVPlaying` / `backdropScrimHPlaying`，底段降到 `0x5A` 量级），由 `fade` 值在两个令牌组间线性插值；**深/浅主题各一套**。具体数值属真机观感调优项（Phase 1 走查）。

**NSFW 策略**：视频层**不经过 `NsfwImage`**（该组件服务于图片文件判定）。建议默认策略：**若当前处于 NSFW clean 模式且该游戏需要模糊（`is_blurred` 或判定敏感），则不自动播放视频**，保持封面模糊——理由：视频整层模糊既失去观赏意义又消耗解码器，且「先模糊后揭示」的交互在背景场景不成立。此策略列入开放问题 Q2。

### 4.4 入口 UI

在 `bpm_game_edit_dialog.dart`（BPM 主题编辑窗口）新增两个区块，紧邻现有「封面」区：

| 区块 | 交互 | 落盘 |
|---|---|---|
| **背景展示图** | 选择图片（`FileType.image`）→ 复制到 `Games/<safeName>/backdrop_user_<ms>.<ext>` → 写入 `bpm_custom_backdrop`；显示缩略图 + 「移除」（回退封面） | `updateGameJson` merge |
| **OP 视频** | 选择视频（`FileType.custom` + `allowedExtensions: ['mp4','m4v']`）→ 复制到 `Games/<safeName>/op_video_user_<ms>.mp4` → 写入 `bpm_op_video`；显示文件名 + 大小 + 「移除」 | 同上 |

> 现有「背景」按钮（详情面板 → `BpmBackdropTuner`，`bpm_game_detail_panel.dart:116`）的**拖动/缩放参数继续生效**，且应**同时作用于自定义背景图**（因为 `bpm_backdrop_*` 本就是 backdrop 的位置控制，与图片来源无关）→ 一期只需保证 `_buildBackdrop` 在「有自定义背景图」分支同样读 `_backdropAdj`。

---

## 5. 数据模型变更（精确到行号）

### 5.1 新增字段

| 字段 | 类型 | 语义 | 默认 |
|---|---|---|---|
| `bpm_custom_backdrop` | `String` | 自定义背景图**相对 `metaDataDir`** 的文件名（如 `backdrop_user_1758888000000.jpg`）；空 = 用封面 | `''` / 不存在 |
| `bpm_op_video` | `String` | OP 视频**相对 `metaDataDir`** 的文件名（如 `op_video_user_1758888000000.mp4`）；空 = 无视频 | `''` / 不存在 |

### 5.2 🔴 建模路线决策：**走 `updateGameJson` merge，不升 schema**

**推荐路线 B（仿 `bpm_backdrop_x/y/zoom` 先例）**，理由与证据：

1. **有直接先例**：`bpm_backdrop_x/y/zoom` 三个字段就是 BPM 侧私有参数，**不在 `GameDataFormat` 建模、不升版本**，直接 `updateGameJson` merge（`bpm_backdrop_tuner.dart:56-80`）。新字段与它们完全同构（都是「BPM 私有 UI 参数 + 用户累积数据」）。
2. **当前不存在全量序列化写回路径**：已 grep 确认 `GameJsonData.toJson()`（`game_data_format.dart:1614`）在 `lib/` 下**无生产调用方**；`fromJson` 唯一调用方是读路径（`:1071`）。因此未建模字段**不会**被静默写没。
3. **`_mergePreservedFields` 语义天然保留**：不在 `_overwritableFields`（`:180-211`）内的字段，在重复入库时**一律保留**（`:216-218`），正合「用户上传的媒体路径不该被重新导入清空」。
4. **零迁移、零写放大**：不升 `currentVersion`（仍为 3），不触发 ADR-012 描述的全库「一次性写放大」（`DECISIONS.md:442-444`）。
5. **符合最小变更铁律**（AGENTS.md §2.1）。

**路线 A（升 v4 + 建模）作为备选**：更贴合 ADR-012 的「字段新增必须①迁移②升版本③补测试」纪律，代价是全库老 `game.json` 各重写一次。**触发切换的条件**：若实施期间发现任何引入 `GameJsonData` 全量序列化写回的改动，**必须同时改用路线 A**，否则字段会丢。

> 🔴 **给执行 AI 的硬约束**：无论走哪条路线，**不得**把 `bpm_custom_backdrop` / `bpm_op_video` 加入 `_overwritableFields`（`:180-211`）——它们与 `screenshot_files`（`:209`）同属「丢失会导致用户资产从 UI 消失」的累积型字段。

### 5.3 文件落点

```
Games/<safeName>/
├── game.json                     ← 新增 bpm_custom_backdrop / bpm_op_video 两键
├── cover.png | cover_user_*.jpg   ← 现有
├── backdrop_user_<ms>.jpg        ← ★ 新增（自定义背景图）
├── op_video_user_<ms>.mp4        ← ★ 新增（OP 视频）
├── screenshots/
└── bpm_play_history.json
```

选 `metaDataDir` 同层的理由：① 与 `cover_user_*`（`bpm_game_edit_dialog.dart:106-110`）完全一致；② 随游戏目录一起迁移 / 删除，无需新增清理逻辑（**待确认**：`finalizeGameMove` 是否整目录搬移，见 §10 R6）。

### 5.4 上传门槛（必须做内容级校验，不能只看扩展名）

| 项 | 门槛 | 理由 |
|---|---|---|
| 背景图 | 沿用现有图片白名单 jpg/jpeg/webp/png | 与 `bpm_game_edit_dialog.dart:102-105` 一致 |
| 视频 | 仅 `mp4` / `m4v`；**必须**校验文件头（`ftyp` box），扩展名不符则拒绝 | 防「x.mp4 其实是别的东西」（`animated_background_implementation_plan.md:126` 已有同类反例警示） |
| 视频体积 | 建议 ≤ 500MB（超限拒绝并告知实际大小） | 解码器 + 内存预算 |
| 视频分辨率 | 建议 ≤ 1920×1080，帧率 ≤ 60 | 官方 README 自述 texture 渲染 4K/60fps 会慢（§3.2） |

---

## 6. 性能预算

| 项 | 预算 | 保证手段 |
|---|---|---|
| UI 线程阻塞 | **0**（3s 计时与视频初始化都不许阻塞 build） | `Timer` + 异步 `initialize()`；初始化放 `arming` 阶段 |
| 首次可播放延迟 | 3s 计时结束时应已 `isInitialized`（预热成功）；若未完成则放弃本次播放回 `idle` | `arming` 期提前 `initialize()`；加超时（如 2.5s） |
| 淡入淡出时长 | ≤ 240ms（对齐既有 `focusAnimDuration` 量级） | 与 `AnimatedSwitcher` 200ms（`big_picture_shell.dart:1151`）同级 |
| 解码器驻留 | **仅 `playing` 期间**；`idle` 时不存在控制器 | 状态机 `dispose()` + `OpVideoLayer` 的 `if (controller == null) return SizedBox.shrink()` |
| 切换游戏时的释放 | 上一控制器必须**先 dispose 再建新**（不可并发持有两个） | `cancel()` 串行化；`_generation` 序号防竞态（异步 initialize 回来时若已换代则直接 dispose 丢弃） |
| 内存 | 1080p 视频解码缓冲约数十 MB 量级；不得同时存在 2 个 | 同上 |
| 首帧不闪白 | 视频层初始 `opacity: 0`，`FittedBox` 前不渲染 | 未初始化时返回 `SizedBox.shrink()` |

🔴 **竞态防护（必做）**：`initialize()` 是异步的，3s 计时期间用户可能已换游戏 N 次。每次启动流程必须携带**递增 `_generation`**，异步回调落地时校验世代号，不匹配则**立即 dispose** 该控制器并丢弃，绝不 `play()`。

---

## 7. 实施阶段划分

### Phase 0 — 技术验证（**先证伪，再落地**）

> 目的：把「方案成立的前提」实测出来。**不通过就不进入 Phase 1**。

| # | 验证项 | 方法 | 通过标准 |
|---|---|---|---|
| 0-1 | **插件可编译** | pubspec 加 `video_player` + `video_player_win` → `./flutter/bin/flutter.bat build windows`（Debug 即可） | 编译通过，构建产物含约 130KB 的插件 dll |
| 0-2 | **Texture 层 z 序** | 最小 demo：`Stack` 内 `[图片, VideoPlayer, Container(半透明黑)]`，`Container` 必须在视频**之上** | 遮罩正常盖在视频上；视频不穿透到 UI 上层 |
| 0-3 | **3s 预热时序可行** | `arming` 阶段 `initialize()`，3s 后 `play()` | 计时到点后**无可见卡顿**即开始出画面 |
| 0-4 | **`isCompleted` 可靠触发** | 播一个短 mp4 到结尾 | `controller.value.isCompleted == true` 稳定触发（至少 5 次） |
| 0-5 | **dispose 无泄漏** | 反复切换 20 次游戏（各带视频） | 无句柄/内存单调上涨；无 `Player already disposed` 类异常 |
| 0-6 | **1080p MP4 开销** | 背景播放 1080p/30fps MP4 + 前台 UI 滚动 | 帧率与 CPU 占用可接受（主观 + 任务管理器）；无掉帧尖峰 |
| 0-7 | **冷门编码兜底** | 试一个 HEVC 或 AV1 的 mp4 | `initialize()` 失败时能被捕获、静默回退封面、不崩溃 |
| 0-8 | **纯 Flutter 层 vs Texture 混排** | BPM 主页真实跑一遍（不简化） | 视频在背后、hero/shelf 文字清晰、无黑块/绿块 |

产出：`dev_probe/RESULTS` 风格的实测记录（项目既有惯例，见 `ADR-009` 提及的 Phase 0 八项）。

### Phase 1 — 数据与上传（不涉及播放）

1. `game_data_format.dart`：确认无需改动（走路线 B）；若要显式登记默认值，仅在 `writeGameDir` 的 map（`:322-363`）考虑——**但按路线 B 不必加**（缺失即视为无）。
2. `bpm_game_edit_dialog.dart`：新增「背景展示图」「OP 视频」两个区块 + 上传/移除 + 门槛校验（§5.4）。
3. `bpm_backdrop_tuner.dart` / `bpm_game_detail_panel.dart`：确认自定义背景图与调参链路互通。
4. **此阶段结束即可验收 G1 / G2**（不播视频，仅换背景图）。

### Phase 2 — 视频播放核心

1. 新增 `lib/services/bpm_op_video_preference.dart`（仿 `motion_preference.dart`）。
2. 新增 `lib/big_picture/services/bpm_backdrop_media_controller.dart`（状态机 + 预热 + 竞态防护）。
3. 新增 `lib/big_picture/widgets/bpm_op_video_layer.dart`（Texture 层）。
4. `big_picture_shell.dart`：`_buildBackdrop` 拆层接线 + `_onStageGameChanged` / 页面切换 / 面板开关 / dispose 的 `cancel()` 接线。
5. `bpm_theme_controller.dart`：新增播放态遮罩令牌（深浅两套）。
6. `pubspec.yaml` + `main.dart`（注册插件 + 偏好 load）——**稳定区，需批准**。

### Phase 3 — 设置项与收尾

1. 设置页新增「OP 视频音量」「OP 视频重播」两个开关（入口位置见开放问题 Q1）。
2. 真机走查（§11.3）。
3. 更新 `big_picture_v3_cinema.md`（新增 §18 章节）、`DEV_LOG.md`、`SESSION_HANDOFF.md`、`DECISIONS.md`（新增 ADR：视频选型与「仅 BPM」范围）。

---

## 8. 改动文件清单

### 8.1 新增（4 个）

| 文件 | 内容 | 风险 |
|---|---|---|
| `lib/services/bpm_op_video_preference.dart` | 两个偏好开关的单例（仿 `motion_preference.dart`，83 行） | ⚪ |
| `lib/big_picture/services/bpm_backdrop_media_controller.dart` | 背景媒体状态机（`idle/arming/fadingIn/playing/fadingOut`）+ 预热 + 竞态防护 | 🟡 |
| `lib/big_picture/widgets/bpm_op_video_layer.dart` | 视频 Texture 渲染层（`BoxFit.cover` 语义 + `Opacity` 驱动） | 🟡 |
| `test/big_picture/services/bpm_backdrop_media_controller_test.dart` | 状态机单测（用可注入的假播放器，不依赖真解码） | ⚪ |

### 8.2 修改（6 个）

| 文件 | 改动 | 风险 |
|---|---|---|
| `pubspec.yaml` | dependencies 追加 `video_player` / `video_player_win` | 🔴 **需批准** |
| `lib/main.dart` | `WindowsVideoPlayer.registerWith()`（`main()` 内、`runApp` 前）+ `BpmOpVideoPreference.instance.load()`（与 `:449` 同层） | 🔴 **稳定区，需批准** |
| `lib/big_picture/big_picture_shell.dart` | `_buildBackdrop` 拆层 + 视频层接入 + 4 处 `cancel()` 接线 + dispose 释放 | 🔴 高（BPM 核心外壳） |
| `lib/big_picture/widgets/bpm_game_edit_dialog.dart` | 新增两个上传区块 | 🟡 |
| `lib/big_picture/bpm_theme_controller.dart` | 新增播放态遮罩令牌（深/浅两套） | 🔴 主题令牌（波及 BPM 全 UI，但只**新增**、不改既有值） |
| `lib/widgets/settings_modal.dart`（或 BPM 内设置入口） | 两个开关 UI | 🔴 巨型文件，需局部改动（**入口位置待定，见 Q1**） |

### 8.3 一期明确不碰

- `lib/theme/**`（主题系统）——不新增令牌、不改 `BackgroundImageConfig`。
- `lib/core/portable_*.dart`（便携路径体系）。
- `lib/services/app_state.dart`（全局状态中枢）。
- `lib/services/nsfw/**`（NSFW 服务本体）——只**消费**判定结果。
- `lib/big_picture/widgets/bpm_smart_cover_image.dart`（智能裁剪算法）——不改。
- `lib/big_picture/widgets/bpm_backdrop_tuner.dart` 的算法——只确认互通，不改逻辑。
- `windows/runner/**`——**预期不需要动**（`video_player_win` 作为 Flutter 插件由构建系统自动注册；Phase 0-1 验证若发现需要动，**停下报告**）。
- 桌面任何页面/链路。
- 开源镜像 `chrono-tide-opensource/`（需同步时单独处理）。

---

## 9. 调用点替换清单（按优先级分批）

| 优先级 | 位置 | 操作 | 备注 |
|---|---|---|---|
| **P0** | `big_picture_shell.dart:1094`（图片层之后） | **插入**视频层 | 唯一渲染插入点 |
| **P0** | `big_picture_shell.dart:335-344`（`_onStageGameChanged`） | **追加** `mediaController.onStageGameChanged(game)` | 触发源 |
| **P0** | `big_picture_shell.dart:1039`（`_buildBackdrop` 内） | 图片层包 `Opacity`（承载淡出） | 需取出 `fade` 值 |
| **P0** | `big_picture_shell.dart` dispose | **追加** `mediaController.dispose()` | 防解码器泄漏 |
| **P1** | 页面切换处（`_currentPage` 变化，`:1148-1160` 附近） | **追加** `mediaController.cancel()`（非主页时） | 我的库不播视频 |
| **P1** | `_showGamePanel` / `_dismissPanel`（`:357-379`） | **追加** `cancel()` | 面板打开时让位 |
| **P1** | `bpm_game_edit_dialog.dart:91-128` 区块附近 | **新增**两个上传区块 | 入口 UI |
| **P2** | `bpm_theme_controller.dart:253` / `:319` 前后 | **新增**播放态遮罩令牌字段与取值 | 深浅各一套 |
| **P2** | 设置页 | **新增**两个开关 | 入口位置待定 |

> ⚠️ **易漏的非 Widget 路径**：① `big_picture_shell.dart` 的 `dispose()`（不在 build 里，极易漏）；② 退出 BPM 的 `BigPictureManager.exit()` 链路；③ 应用窗口最小化（可选 pause）。

---

## 10. 风险登记（P0–P3）

| # | 级别 | 风险 | 影响 | 应对 |
|---|---|---|---|---|
| R1 | **P0** | 插件注册需改稳定区 `main.dart`；依赖新增需改 `pubspec.yaml` | 违反 AGENTS 红线，未批准将被叫停 | **本方案已显式标注，等待用户批准后再进入 Phase 1** |
| R2 | **P0** | 异步 `initialize()` 竞态：3s 内换游戏 N 次，旧控制器回调晚到并 `play()` | 播放错误游戏的视频 / 多个解码器同时存活 / 崩溃 | 递增 `_generation` 序号 + 落地校验 + 立即 dispose（§6 已列为硬约束） |
| R3 | **P1** | MediaFoundation 依赖系统 codec：HEVC/AV1/冷门封装初始化失败 | 用户上传后黑屏或卡住 | `errorBuilder` + `catchError` **静默回退封面**；上传时用文件头校验拦掉明显非 mp4；文档告知用户「用 H.264 编码的 MP4 最稳」 |
| R4 | **P1** | 现有 `backdropScrimV` 底段 `0xA6`(65%) 直接压暗视频 | 视频「不够清晰」，违背用户核心诉求 | 新增播放态遮罩令牌（§4.3），随 `fade` 插值；数值真机调优 |
| R5 | **P1** | NSFW clean 模式下视频与「模糊」策略冲突 | 违规内容以视频形式未经模糊展示 | 默认策略：clean 模式 + 需模糊 → **不自动播放**（§4.3，Q2 待确认） |
| R6 | **P2** | 视频文件落在 `metaDataDir`，若搬移游戏只搬 `game.json` 不搬媒体 | 搬移后视频路径失效（静默回退封面，不崩溃） | 实施前确认 `finalizeGameMove` 的搬移语义（是否整目录）；若不全搬，需同步处理 |
| R7 | **P2** | 大体积视频（>500MB）复制耗时长阻塞 UI | 上传时界面卡顿 | 复制走 `await` + 进度提示；门槛拒绝超限文件 |
| R8 | **P2** | `settings_modal.dart`（4096 行巨型文件）改动 | 顺手改坏别处 | 严格局部改动、`git diff --stat` 自查 |
| R9 | **P3** | 用户上传 mp4 带音频，静音开关默认 false 但用户开启了音量 | 主页浏览时突然出声 | 音量默认取较低值（如 0.35）；切换游戏时音频随 `cancel()` 立即停 |
| R10 | **P3** | 双显示器 / DPI 变化下视频层尺寸 | 裁切异常 | `FittedBox(cover)` 天然自适应；走查多分辨率 |

---

## 11. 验收标准

### 11.1 功能验收

| # | 场景 | 期望 |
|---|---|---|
| F1 | 上传背景图 → 主页选中该游戏 | 背景变为自定义图（非封面）；桌面无变化 |
| F2 | 移除背景图 | 回退到封面背景 |
| F3 | 调整背景位置/缩放（BpmBackdropTuner） | 对自定义背景图同样生效 |
| F4 | 上传 OP 视频 → 主页选中停留 3s | 封面淡出、视频淡入并播放；hero 标题/详情组件**位置与内容不变** |
| F5 | 视频播放中滚动 shelf / 移动焦点 | 视频继续播；UI 不闪、不重建 |
| F6 | 视频播完 | 淡出视频、恢复背景；无黑帧残留 |
| F7 | 播放中切到另一个游戏 | 立刻停播（无音频残留），新游戏重新计时 |
| F8 | 播放中切到「我的库」/ 打开详情面板 / 退出 BPM | 立刻停播并释放 |
| F9 | 停留不足 3s 就切走 | 完全不播（无预热的副作用） |
| F10 | 上传的 mp4 是 HEVC（系统无扩展） | 静默回退封面，不崩溃、不弹错误 |
| F11 | 关闭「声音」开关 → 播放 | 无声 |
| F12 | 关闭「每次选中都播」→ 同一游戏二次选中 | 不自动播（或按 Q3 决定的语义） |
| F13 | 未上传视频的游戏 | 行为与本方案实施前**完全一致** |

### 11.2 技术验收（命令 + 基线）

```bash
# 仅对自己改动的文件
./flutter/bin/flutter.bat analyze lib/big_picture lib/services/bpm_op_video_preference.dart lib/main.dart lib/services/game_data_format.dart
# 相关用例 + 不新增失败
./flutter/bin/flutter.bat test test/big_picture/ test/services/
# 越界自查
git status --short && git diff --stat
```

- `analyze`：**0 新增 error**（存量 info/warning 以 `chronotide-dev` skill 的「项目硬事实」表为准，**不要固化数字**）。
- `test`：基线以 skill 表为准（**勿引用历史值**）；新增状态机用例必须全绿。
- ⚠️ 工作区若有他人未提交改动，基线会漂移 → 先 `git status` 定位归属。

### 11.3 真机走查清单（**必须逐项确认，未做即标注「未走查」**）

1. [ ] F1–F13 全部；
2. [ ] 深色 Cinema 主题下：视频清晰度、播放态遮罩浓度、右下 shelf 文字可读性；
3. [ ] 浅色地海蔚蓝主题下：同上（浅色遮罩是白色系，压暗逻辑完全不同）；
4. [ ] 1080p / 2K / 4K 三种分辨率下的视频裁切与性能；
5. [ ] 手柄操作切换游戏时，视频是否被正确打断/重启（焦点即选中语义）；
6. [ ] 连续快速切换 20 个游戏：无崩溃、无内存单调上涨、无 `Player already disposed`；
7. [ ] BPM 退出后进程无残留解码器占用（任务管理器 / 重新进入 BPM 正常）；
8. [ ] 上传大视频（如 300MB）的复制耗时与界面响应。

---

## 12. 给执行 AI 的指令摘要（可直接复制）

```
你正在为 Chrono Tide（D:\CTLIB，Flutter Windows Galgame 管理器）实施
「BPM 自定义背景图 + OP 视频背景播放」。方案文档：
docs/DEV/features/bpm_custom_backdrop_and_op_video_plan.md（先完整读它）。

开工前必读：AGENTS.md / docs/DEV/SESSION_HANDOFF.md / docs/DEV/STATUS_MAP.md /
docs/DEV/DECISIONS.md / docs/DEV/features/big_picture_v3_cinema.md

硬约束：
1. 先做 Phase 0 技术验证（8 项），不通过不进入 Phase 1。
2. Flutter 用 ./flutter/bin/flutter.bat（不用全局）。
3. pubspec.yaml 与 lib/main.dart 属需显式批准项 —— 用户已在本方案中批准，
   但仍须逐条报告改动。
4. 新增字段 bpm_custom_backdrop / bpm_op_video 走 updateGameJson merge，
   不升 format_version、零迁移；绝不加入 _overwritableFields。
5. 异步 initialize() 必须带世代号防竞态；不匹配立即 dispose。
6. 无视频的游戏行为必须逐位不变。
7. 不禁 git gc；每次改动后 analyze + test + git status --short 自查。
8. 收尾更新 DEV_LOG.md（插在 <!-- LOG-ENTRIES --> 下方第一条）、
   SESSION_HANDOFF.md、big_picture_v3_cinema.md、DECISIONS.md（新增 ADR）。
9. 未真机走查的部分必须诚实标注。
```

---

## 13. 待用户决策的开放问题

| # | 问题 | 建议默认 | 影响 |
|---|---|---|---|
| **Q1** | 「OP 视频音量」「重播规则」两个开关的**设置入口**放哪？BPM 顶部栏主题按钮旁？BPM 内独立设置面板？还是桌面设置页？ | BPM 内（顶部栏加一个设置入口），因为它只影响 BPM | 影响 `settings_modal.dart`（巨型文件）是否被改动 |
| **Q2** | NSFW clean 模式下，对需模糊的游戏：**不自动播放** vs 整层模糊后播放 vs 照常播放？ | **不自动播放**（保持封面模糊） | 影响 R5 的实现分支 |
| **Q3** | 「每进入一次大屏只播一次」模式下，是否提供**手动触发**入口（如 hero 上加一个 ▶ 按钮再播一次）？ | 一期不提供（保持最小） | 少一个 UI 元素，降低工作量 |
| **Q4** | 应用窗口**最小化 / 失焦**时：暂停视频 vs 继续播（会听到声音） | **暂停**（省资源、避免后台出声） | 影响状态机是否监听 `AppLifecycle` |
| **Q5** | 视频体积/分辨率门槛的具体数值：500MB / 1080p 是否合适？ | 500MB / 1080p / 60fps | 影响上传校验与拒绝文案 |
| **Q6** | 自定义背景图**是否也要在「我的库」页生效**？ | 是（shell 层 backdrop 本就被两页共用，`_stageGame` 在库页仍有效） | 若否，需在库页禁用自定义背景图 |

---

## 附录 A：本方案的证据链（可独立复核）

- 背景渲染：`big_picture_shell.dart:1039-1140`（`_buildBackdrop` 全文）、`:1084-1137`（Stack 五层）、`:1053-1069`（图片层）
- 选中链路：`big_picture_shell.dart:335-344`、`big_picture_home.dart:754`、`:874-876`
- 遮罩取值：`bpm_theme_controller.dart:221-232`（深）、`:292-303`（浅）
- 上传范式：`bpm_game_edit_dialog.dart:93-128`（封面）、`:132-169`（截图）
- 偏好范式：`lib/services/motion_preference.dart`（全文 83 行）、`main.dart:449`
- schema：`game_data_format.dart:31`（version=3）、`:41-45`（迁移链）、`:180-211`（覆盖黑名单）、`:322-363`（默认 map）、`:1414-1503`（模型）、`:1554`（fromJson）、`:1614`（toJson，**无生产调用方**）
- BPM 私有字段先例：`bpm_backdrop_tuner.dart:22-81`
- 视频能力现状：全库 grep `video_player|media_kit|fvp|mpv|dart_vlc|chewie|VideoPlayer|ffmpeg` → `lib/` 零命中；`pubspec.yaml:9-34` 无视频包
- 选型事实：`video_player_win` 3.2.2（pub.dev，BSD-3，约 130KB dll，Media Foundation，README 自述 4K/60fps 慢）
