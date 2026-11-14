# Chrono Tide · 时之汐

> **一站式 Galgame / 视觉小说游戏库管理器** —— 把「发现 → 获取 → 入库 → 整理 → 启动 → 游玩 → 备份」串成一条完整链路的 Windows 桌面应用。

<img width="888" height="648" alt="gempix2-1791190372745" src="https://github.com/user-attachments/assets/2d03114d-5a5f-4b2e-a149-ea286079a114" />

![Version](https://img.shields.io/badge/Version-v3.5.0-brightgreen)
![Flutter](https://img.shields.io/badge/Flutter-3.24.3-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.5.3-0175C2?logo=dart)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

**仓库**：<https://github.com/HardManOfficial/Chrono-Tide>　|　**官网**：<https://chrono-tide.com>
**问题反馈**：[Issues](https://github.com/HardManOfficial/Chrono-Tide/issues)　|　**版本发布**：[Releases](https://github.com/HardManOfficial/Chrono-Tide/releases)　|　**更新日志**：[CHANGELOG.md](CHANGELOG.md)

Chrono Tide（CT）不只是「给游戏排个封面网格」。它是一套围绕 Galgame 使用场景长出来的完整工具集：
多源元数据自动聚合、全站资源检索与一键安装、补丁站与本地补丁管理、日文转区 / 超分 / 字体替换等启动兼容能力、
存档备份与云同步、本地 AI 内容保护、可深度定制的主题与大屏模式，以及贯穿全局的账号、代理与任务体系。

本项目以 **MIT** 许可开源，欢迎二次开发、提交 Issue 与 Pull Request。

---

## 目录

- [亮点速览](#亮点速览)
- [界面与形态](#界面与形态)
- [功能全景](#功能全景)
- [V3.5.0 更新重点](#v350-更新重点)
- [技术架构](#技术架构)
- [从源码构建](#从源码构建)
- [二次开发指引](#二次开发指引)
- [安全与凭据](#安全与凭据)
- [已知边界](#已知边界)
- [致谢](#-致谢)
- [许可证](#许可证)

---

## 亮点速览

| 能力 | 一句话 |
| --- | --- |
| **元数据** | 10 条数据源优先级链 + MIX 字段级整合，平台账号、字段优先级、全量更新均可配置 |
| **获取** | 探索大厅 / 全站搜索 / 全站库直链下载安装 / 补丁站 v5.4 / 用户分享与上传 |
| **启动** | 普通 · 超分 · 转区 · 托盘四条链路合一，兼容层自动配置、提权裁决、游戏字体替换 |
| **整理** | 智能导入、启动程序智能推荐、分类匣、收藏夹、搜索相关性排序、安全删除 |
| **保护** | 存档备份 / 恢复、归档加密与云备份、本地 ONNX 推理的 NSFW 纯净模式 |
| **个性** | 6 套内置主题 + 主题设计器（24 可编辑元素、HSV 取色、背景图层、撤销重做） |
| **沉浸** | 大屏模式 BPM：手柄导航、焦点网格、标题图、背景视频 |
| **工程** | 便携化数据目录、单实例锁、自动更新、全局代理三态、缓存治理、恢复默认设置 |

---

## 界面与形态

**主壳** —— 自定义标题栏 + 可折叠侧边栏 + 内容区；设计尺寸 / 默认尺寸 / 最小尺寸 / 恢复下限统一为 **1280×720**，窄窗下自动改为「详情独占 + 竖条游戏库」布局。侧边栏按比例等比缩放，跨 960×540 ~ 2560×1440 不溢出。

**五个主要界面**

| 界面 | 职责 |
| --- | --- |
| 主页 | 最近游玩、7 日游玩时长曲线、状态筛选（游玩中 / 已通关 / 未入坑 / 已弃坑）、透明艺术字标题图 |
| 库页 | 网格卡片、拖拽排序、收藏夹、分类匣、搜索、右键菜单、补丁管理、批量操作与编辑模式 |
| 详情 | 元数据 / 标签 / 截图轮播 / 系列横条 / 匹配记录，启动与编辑一体；KUNGAL 作品页与攻略页双外跳 |
| 探索 | 探索大厅、全站搜索、资源来源筛选、作品资源库、补丁站、上传与分享 |
| 添加 | 智能导入、批量导入、拖放、压缩包安装、元数据匹配、封面相册 |

**大屏模式（BPM）** —— 为客厅 / 串流场景准备的全屏启动器：封面背景、标题层、状态筛选条、底部游戏轮播、手柄导航与焦点网格，支持 OP / ED / PV 背景视频自动探测与标题图。

**外观与个性化** —— 内置 **6 套主题**（暖阳 / 浅色 / 深色 / 墨绿金 / 樱花浪漫 / 蓝天白云）；主题设计器支持 24 个可编辑元素、HSV 调色板、取色器、Recent Colors、背景图层编辑、50 步撤销重做，以及 `.cttheme` 导入导出。字体体系覆盖中文装饰标题、英文数字与 UI 正文三档。

**设置页** —— 按「我的 / 界面 / 游戏 / 系统」4 簇组织 8 个分组：个人资料、外观、大屏模式、游戏与启动、元数据、内容保护、网络与存储、关于应用。

---

## 功能全景

### 1 · 游戏入库与整理

- **智能导入**：自动识别游戏本体与附属文件夹，支持单游戏、批量导入、文件夹拖放、监控文件夹自动入库、导入去重索引
- **启动程序候选分析**：自动区分无关工具与游戏程序，标注 HD / 原版 / 魔改 / 汉化版本，汉化版给出「★ 推荐」角标，候选全部过 PE 头校验（只标角标，不重排、不隐藏、不改默认选中）
- **库内组织**：卡片网格、拖拽排序、收藏与置顶、状态角标、分类匣（会社归一化词典 **255 家**、标签受控词表 **717 概念**）、多条件筛选
- **搜索**：库内搜索采用纯 Dart 打分 + 稳定重排，标题强命中优先，弱命中垫底；用户手选排序降为同档次序
- **安全删除**：应用数据目录内永久删除，应用外文件移入**回收站可还原**；网络位置、盘根、祖先目录、系统目录一律拒删并说明原因；批量删除先统计可回收 / 受保护数量，操作写审计日志
- **数据体系**：以 `game.json` 的 `game_id` 为身份、目录名由标题清洗唯一生成（`format_version = 4`），支持旧版本数据迁移、游戏位置迁移、NAS / 映射盘路径适配与全套便携化路径

### 2 · 元数据与作品资料

- **10 条数据源优先级链**：`MIX → NextMoe → CT 探索库 → 2Dfan → VNDB → 鲲GAL → Hikarinagi → 月幕GAL → Steam → Bangumi`
  （v3.5.0 起移除 DLsite / ErogameScape / TouchGal，新增 2Dfan；MIX 按字段优先级整合多平台结果）
- **设置 → 元数据**：平台账号与凭证、拉取来源开关、字段级「首选平台」覆盖、大标题素材、**全量更新**（默认只补空字段，绝不覆盖标题 / 封面 / 截图，串行可取消、失败重试）
- **平台账号体系**：四平台登录态，NextMoe / Hikarinagi 支持 **PKCE + 本地回调**的一键 OAuth 登录；Bangumi PAT、鲲 Cookie 等凭证在线校验并明确区分「需要登录 / 网络不通」
- **资料维度**：封面、横幅、截图、别名、副标题、简介、会社、发售日、标签、系列、评分、攻略外链；7 天磁盘缓存、封面并发下载、抓取后云端沉淀与回传
- **标题图与素材**：Steam CDN + SteamGridDB 双源自动抓取透明 Logo，无图自动回退文字大标题；SteamGridDB Key 为纯可选增强

### 3 · 发现 · 获取 · 安装

- **探索大厅与全站搜索**：结果条、标题相关性重排、「获取 / 分享」彻底分开、「打开原站」直达作品页；库内 0 结果时可一键跳全站搜索
- **全站资源库**：用户分享资源、上传资源、分享详情、**本体直链下载并安装**（去重 → 体积准入 → 确认 → 下载 → 解压 → 自动入库）
- **补丁站 v5.4**：鲲 / 社区 / 2DFan 多源投递，多网盘与直链全量展示、直链可在软件内下载；2DFan 账号积分与兑换（下单前复核价格、只提交一次、超时不重发）；「从游戏库选择」只读已入库本地游戏
- **本地补丁管理（PATCH-VAULT）**：库页右键「补丁管理」支持导入本地补丁、形态识别、落点转移、逐文件清单 + 二次确认 + 备份 + manifest 记账，可单补丁撤销，并按严格逆序「一键恢复原版」
- **下载链路**：全局安装中心与任务调度、下载准入 2× 包体校验、解压前空间预检、**下载加速通道**（本机代理探测，默认不勾）、单连接稳定下载；成功 / 取消 / 失败全链路清理缓存，磁盘写满不再假装在下载
- **解压能力**：ZIP / 7Z / RAR / LZ4 / `.rar.lz4` / TAR / ISO / CAB 及 `.enc` 加密包（7-Zip、Bandizip 命令行、UnRAR、`archive` + `pointycastle` 组合）
- **OpenList 对接**：云端文件服务配置热更、组件静默升级、网盘路径迁移适配，未对接不产生任何下载

### 4 · 启动与兼容

- **四条启动链路合一**：普通启动 / Magpie 超分 / Locale Emulator 转区 / 托盘「最近游玩」统一收敛到 `GameLaunchService`，避免绕过兼容性逻辑
- **转区与超分**：内置 Locale Emulator，按游戏单独配置转区模式，自动识别 PE 架构；Magpie 超分可跟随游戏提权
- **启动兼容性**：启动前自动写入 HKCU 兼容性层（Win8 兼容 / 禁用全屏优化 / 替代高 DPI 缩放），按记账精确回滚；权限裁决支持「以管理员身份运行」三处开关与一生一次重启提示
- **游戏字体替换（CTFontHook）**：向游戏目录投放 `winmm.dll` 代理劫持，启动链路零改动；两栏字体选择器（搜索 / 字符集 / 字体自身渲染 / 兼容设置 / 字形微调 / 中英日预览）、全库批量安装与恢复、纯本地不兼容清单；逐游戏开关，默认关闭
- **游玩统计**：启动时长记录、游玩履历、聚合统计与 7 日曲线、进程清理与前台窗口检测

### 5 · 存档 · 备份 · 内容保护

- **存档**：自动扫描存档清单、备份 / 整包或单文件恢复、覆盖前二次确认、历史记录（时间戳 / 文件数 / 体积）、自定义非标准存档路径
- **归档与云备份**：7-Zip 归档压缩、`.enc` 加密（AES / Serpent / Twofish / Blowfish / Skein / SHA3 / Argon2id / HKDF）、云端备份与 OpenList 对接
- **NSFW 纯净模式**：内置 ONNX 模型本地推理（isolate worker + 双优先级队列）、分级判定与局部马赛克、全量扫描存量封面 / 截图、判定缓存与签名失效重扫；**原图字节不变、全程不联网**

### 6 · 账号 · 社区 · 系统能力

- **本地优先账号**：全新安装首启动直接进主界面，自动创建本地身份并从 **34 张系统头像**中随机取一张；云端功能未登录时统一提示「本地管理功能不受影响」；支持在线注册 / 登录 / 自动登录、资料与头像四处即时同步、社群入口
- **网络代理**：`system / manual / direct` 三态唯一事实源，10s TTL 运行期跟随系统代理，代理不可用直接失败而不静默回退
- **系统集成**：托盘与「重置窗口位置」逃生入口、开机自启、桌面快捷方式、单实例锁、启动更新检查（`appcast.xml`）、系统提示气泡、窗口几何记忆与自适应、缓存管理（只清可再生缓存）、恢复默认设置（删 prefs 键 + 延迟重启，不删凭据与用户资产）
- **开发面板**：每个项目自带 `Dev/scripts` 双击式构建 / 打包面板，安装包内置 VC++ x64 运行库并收紧系统门禁

---

## V3.5.0 更新重点

> 覆盖 2026-10-28 ~ 2026-11-14（41 次提交 + 本轮改动）。完整条目见 [CHANGELOG.md](CHANGELOG.md)。

| 主线 | 内容 |
| --- | --- |
| 全站搜索与资源获取 | 搜索扩展到全站资源库、结果条 v2、标题相关性重排、打开原站直达作品页、全站库直链下载安装 |
| 补丁站 v5 系列 | 鲲 / 社区 / 2DFan 多源、网盘与直链全量展示、2DFan 积分兑换 |
| 本地补丁管理 | PATCH-VAULT 导入 / 备份 / manifest / 严格逆序一键恢复原版 |
| 元数据源 v3 与账号 | 移除 3 源、接入 2Dfan、新增设置 → 元数据板块、PKCE OAuth 一键登录 |
| 网络与下载链路 | 全局代理三态、下载加速通道、单连接下载、下载 / 存储全链路审计与清理 |
| 设置与界面统一 | 库页详情窗口 v3、恢复默认设置、侧栏 4 簇 + 分组卡片、关于页开源组件致谢 |
| 发布工程治理 | 项目自包含开发面板、安装包运行库与门禁收紧 |

---

## 技术架构

| 层 | 内容 |
| --- | --- |
| 框架 | Flutter **3.24.3** / Dart **3.5.3**，Windows 原生 runner + Win32 FFI（`gdi32` / `kernel32` / 注册表 / `ShellExecuteExW`） |
| 状态 | Provider 全局状态中枢 + 单例服务（带 `_loaded` 闸的懒加载偏好） |
| 分层 | `lib/pages/` · `lib/services/`（按职责域分组）· `lib/widgets/` · `lib/theme/` · `lib/big_picture/` · `lib/models/` · `lib/core/` |
| 元数据 | `lib/packages/luna_metadata_sdk/` 独立子包，统一数据源接口、限流、标签翻译与凭证注入 |
| 存储 | 本地 JSON 注册表 + 便携化路径体系 + SharedPreferences；云端 PocketBase，文件服务 OpenList |
| 验证 | `test/` 单元与组件测试；`dev_probe/` 行为 / 渲染探针（离线 CFE 编译 + `flutter_tester` 渲染断言） |
| 文档 | `docs/DEV/STATUS_MAP.md`（功能地图）、`DECISIONS.md`（ADR）、`DEV_LOG.md`、`features/`（95 篇功能方案）、`SESSION_HANDOFF.md` |

---

## 从源码构建

环境要求：**Flutter 3.24.3 / Dart 3.5.3**、Windows 10/11 x64、Visual Studio 2022（含「使用 C++ 的桌面开发」工作负载）。

```bash
flutter pub get
flutter build windows --release
```

部分元数据源需要使用者自己的凭证。本仓库**不含任何密钥**，请通过编译期参数注入，不要写进源码：

```bash
flutter build windows --release \
  --dart-define=NEXTMOE_API_KEY=<YOUR_KEY> \
  --dart-define=HIKARINAGI_CLIENT_ID=<YOUR_CLIENT_ID> \
  --dart-define=HIKARINAGI_CLIENT_SECRET=<YOUR_CLIENT_SECRET>
```

不注入时仅这几个元数据源不可用，其余功能不受影响。运行时所需的第三方工具（解压、转区、超分等）许可与获取方式见
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)；更多说明见 [`docs/BUILD_FROM_SOURCE.md`](docs/BUILD_FROM_SOURCE.md) 与 [`SECURITY.md`](SECURITY.md)。

---

## 二次开发指引

| 目录 | 内容 |
| --- | --- |
| `lib/` | 应用源码（页面、组件、服务、数据模型） |
| `lib/packages/luna_metadata_sdk/` | 元数据抓取 SDK（独立子包） |
| `test/` | 单元测试与组件测试 |
| `dev_probe/` | 开发期行为 / 渲染探针（源码级，非运行时依赖） |
| `windows/` `linux/` `macos/` `android/` `ios/` `web/` | 各平台 runner |
| `assets/` | 图片、字体、运行时小工具、会社 / 标签词表、ONNX 模型 |
| `docs/` | 设计文档、架构决策（ADR）、开发日志、功能方案 |
| `Dev/scripts/` | 项目自带的构建 / 打包面板 |

动手前建议先读 `docs/DEV/STATUS_MAP.md`、`docs/DEV/DECISIONS.md` 与 `docs/DEV/SESSION_HANDOFF.md`。
项目约定较严格：最小变更、两段式审批、稳定区（`main.dart` / `main_container.dart` / `lib/theme/` / `portable_*` / `app_state.dart` / `windows/runner/` 原生层）改动需显式确认。

---

## 安全与凭据

- 本仓库**不包含任何 API Key、Cookie、OAuth 应用密钥、访问令牌或账号密码**；历史开发记录中出现的凭据已统一脱敏，源码中的第三方凭据改为编译期注入。
- 所有第三方凭证请在运行时自行配置，或按上文 `--dart-define` 注入。
- 若发现疑似泄露的凭据，请按 [`SECURITY.md`](SECURITY.md) 处理，不要公开张贴。

---

## 已知边界

- 目前**仅面向 Windows 桌面端**完整验证；macOS / Linux / 移动端 runner 保留在仓库中，但未经完整验证。
- 全站库直链采用单连接下载，建议配合「下载加速通道」或全局代理使用；直连单流速率受上游限速影响。
- 2DFan 登录受 Cloudflare Turnstile 限制，需在浏览器登录后把 Cookie 填入「设置 → 元数据 → 平台凭证」。
- 部分元数据平台需要使用者自己的账号凭证，且受对方站点风控策略影响；游戏游玩记录（Play Log）排期至下一版本，v3.5.0 不含。
- `flutter analyze` / `flutter test` 与完整 Release 构建需在正常终端执行；真机走查清单见 `docs/DEV/SESSION_HANDOFF.md`。

---

## 🙏 致谢

Chrono Tide 站在很多优秀项目与社区的肩上。以下按「内置工具 / 开源依赖 / 字体素材 / 数据服务 / 上游与社区」列出，
完整清单与许可边界见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

### 内置工具与运行时组件

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| **7-Zip**（`7z.exe` / `7z.dll` / `7za.exe`，含 Far 插件与 x64 变体） | 压缩包解压、归档与备份 | LGPL-2.1+ / BSD（许可文本见 7-Zip 官网） |
| **Bandizip 命令行** `bz.exe` + `ark.x64.dll` / `bdzshl.x64.dll` / `ark.x64.lgpl.dll` | `.lz4` / `.rar.lz4` 外层解压 | 随附二进制，权利归 Bandizip 所有 |
| **UnRAR** `UnRAR.exe` | RAR 内层解压 | RARLAB UnRAR License |
| **Locale Emulator**（`LEProc.exe` 等） | 日文游戏转区启动 | 见上游项目许可 |
| **Magpie** | 游戏窗口超分辨率增强 | 见上游项目许可 |
| **SDL3** | 大屏模式手柄输入 | zlib License |
| **CTFontHook 0.1.1** | 游戏字体替换（`winmm.dll` 代理劫持） | MIT License |
| **Microsoft Detours 4.0.1** | 字体钩子底层依赖 | MIT License |
| **ONNX Runtime** | 本地 NSFW 模型推理 | MIT License |

### Flutter / Dart 开源依赖

`window_manager`、`system_tray`、`desktop_drop`、`file_picker`、`flutter_svg`、`auto_size_text`、
`cached_network_image` / `flutter_cache_manager`、`fl_chart`、`video_player` / `video_player_win`、
`dio`、`http`、`pocketbase`、`crypto`、`pointycastle`、`archive`、`ffi`、`onnxruntime`、
`path` / `path_provider`、`shared_preferences`、`package_info_plus`、`file`、`uuid` 等 ——
感谢 Flutter / Dart 团队与各包维护者，各包许可见其上游仓库。

### 字体 · 模型 · 素材

- **Smiley Sans（得意黑）/ Outfit / Noto Sans SC** —— 界面三档字体，SIL Open Font License
- **Mali / 钟齐志莽行书** —— 手写风格字体，请按字体自带许可使用
- **anime_dbrating**（Hugging Face `deepghs/anime_dbrating`，MobilenetV3 权重）—— NSFW 判定模型，OpenRAIL，来源与本地化口径见 `assets/models/anime_dbrating_mv3_v0.LICENSE`
- **Coverr / Mixkit** —— 背景视频与演示素材，许可页见 `dev_probe/docs/`
- 34 张系统头像、主题背景与界面插画为项目自制素材

### 数据与服务

感谢以下开放接口与资料站点，让作品资料、封面、补丁与资源检索成为可能：
**Bangumi、VNDB、月幕GAL、Steam、SteamGridDB、2DFan、鲲GAL、Kungal、NextMoe、Hikarinagi**，
以及后端的 **PocketBase** 与文件服务 **OpenList / Alist**。
其中部分平台需使用者自己的账号凭证；本项目仅调用公开接口、与上述站点无隶属或背书关系，使用请遵守各自服务条款。

### 上游项目与社区

- **LunaBox** —— `luna_metadata_sdk` 的原始 Go 实现与设计参考
- **Playnite** —— 透明标题图等交互设计的灵感来源
- **各大民间汉化组** —— 无偿为爱产出汉化内容，推动圈内作品交流传播；所有汉化内容版权归对应汉化组所有
- **每一位提交反馈、参与测试与分享资源的用户** —— 功能迭代几乎都来自真实使用场景

> 上述第三方组件的权利归各自所有者所有。本仓库的 MIT 许可仅覆盖 Chrono Tide 自身源码；
> 再分发时请以各上游许可为准，详见 `THIRD-PARTY-NOTICES.md`。

---

## 许可证

**MIT © 2026 HardManOfficial** —— 详见 [`LICENSE`](LICENSE)。
