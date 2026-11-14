# Chrono Tide

> 一款基于 Flutter 的 Windows 桌面端 Galgame / 视觉小说游戏库管理器

![Version](https://img.shields.io/badge/Version-v3.5.0-brightgreen)
![Flutter](https://img.shields.io/badge/Flutter-3.24.3-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.5.3-0175C2?logo=dart)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)
![License](https://img.shields.io/badge/License-MIT-green)

**仓库**：<https://github.com/HardManOfficial/Chrono-Tide>　|　**官网**：<https://chrono-tide.com>
**问题反馈**：<https://github.com/HardManOfficial/Chrono-Tide/issues>　|　**版本发布**：<https://github.com/HardManOfficial/Chrono-Tide/releases>

本项目采用 **MIT** 许可开源，欢迎二次开发、提交 Issue 与 Pull Request。

---

## 从源码构建

环境要求：Flutter **3.24.3** / Dart **3.5.3**，Windows 10/11 x64，Visual Studio 2022（含 C++ 桌面开发工作负载）。

```bash
flutter pub get
flutter build windows --release
```

如需启用依赖密钥的元数据源，通过编译期参数注入，**不要把密钥写进源码**：

```bash
flutter build windows --release \
  --dart-define=NEXTMOE_API_KEY=<你自己的密钥> \
  --dart-define=HIKARINAGI_CLIENT_ID=<你自己的应用 ID> \
  --dart-define=HIKARINAGI_CLIENT_SECRET=<你自己的应用密钥>
```

不注入时这几个元数据源不可用，其余功能不受影响。
更多说明见 [`docs/BUILD_FROM_SOURCE.md`](docs/BUILD_FROM_SOURCE.md)、[`SECURITY.md`](SECURITY.md) 与
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

---

# Chrono Tide

**Chrono Tide (CT)** 是一款专为 Galgame 爱好者打造的桌面端游戏管理器，覆盖从游戏发现、下载安装、入库管理到启动运行（含日文转区）的完整生命周期。

> 基于 Flutter Desktop 构建 | Windows / Linux / macOS

---

## 界面预览

### 主界面布局

应用采用 **三栏式布局**：左侧可折叠导航栏 + 中央内容区 + 自定义标题栏，整体风格简约精致。

- **自定义标题栏** — 隐藏系统原生标题栏，内置最小化 / 最大化 / 关闭按钮
- **侧边导航栏** — 支持折叠/展开，折叠时显示 "CT" 缩写 Logo
- **手写风格字体** — 钟齐志莽行书 / Mali，赋予界面独特的视觉气质

### 三大核心模块

| 模块 | 说明 |
|:---:|------|
| **库 (Library)** | 已入库游戏的本地管理 |
| **探索 (Discover)** | 远程游戏目录浏览与安装 |
| **添加 (Join)** | 手动或批量将本地游戏入库 |

---

## 功能一览

### 游戏库管理

- **卡片网格展示** — 封面图 + 标题 + 收藏星标，悬停时上浮动效
- **拖拽排序** — 长按触发，支持交换/插入两种排序模式，顺序自动持久化
- **双击启动游戏** — 自动调用已选择的启动程序，支持 Locale Emulator 转区模式
- **右键菜单** — 查看详情 / 选择启动程序 / 切换收藏 / 存档备份 / 删除游戏
- **收藏标记** — 金色星标，快速筛选心仪作品

### 探索与安装

- **远程游戏目录** — 分页加载，全量缓存，实时搜索与标签筛选
- **已安装标记** — 绿色边框 + 徽章，避免重复下载
- **一键下载安装** — 点击即开始，自动完成 下载 → 解压 → 入库 全流程
- **全局安装中心** — 右下角悬浮按钮，随时查看下载/解压进度与状态
- **多格式解压** — 支持 ZIP / 7Z / RAR / LZ4 / TAR / ISO / CAB 等主流压缩格式

### 入库系统

- **单游戏入库** — 填写元数据（标题 / 标签 / 描述 / 封面），选择游戏文件夹
- **批量导入** — 多个文件夹同时置入，逐个编辑后统一提交
- **文件拖放** — 直接将游戏文件夹拖入即可识别
- **元数据抓取** — 一键从网络获取游戏信息（Bangumi 等）

### 日文转区 (Locale Emulator)

- 内置 **Locale Emulator 2.5.0.1**，无需额外安装
- 自动检测 PE 架构（x86 / x64），智能选择注入方式
- 转区模式按游戏单独配置，可随时切换
- 支持自定义启动程序选择

### 存档备份

- **自动扫描** — 按存档清单配置自动识别游戏存档位置
- **备份 / 恢复** — 支持整包恢复或单文件恢复，覆盖前二次确认
- **历史记录** — 时间戳、文件数、总大小一目了然
- **自定义路径** — 支持手动指定非标准存档目录

### 主题系统

提供 **7 款经典配色主题** + **沉浸式背景主题**：

| 主题 | 风格 |
|:---:|------|
| Warm Sun | 暖阳色调（默认） |
| Dark Night | 暗色系 |
| Mint | 薄荷绿 |
| Sakura | 樱花粉 |
| Ocean | 海洋蓝 |
| Twilight | 暮光色 |
| Blue Sky / Sakura BG | 沉浸式背景 |

主题切换即时生效，全局无缝过渡。

### 用户系统

- **邮箱注册 / 登录** — 完整的账号体系，支持自动登录
- **个人资料** — 头像上传、昵称、个人简介编辑
- **网络代理** — 支持 HTTP 代理配置，访问海外数据源

### 其他特性

| 特性 | 说明 |
|:---:|------|
| 单实例锁 | 防止重复启动，OS 级文件排他锁 |
| 启动更新检查 | 首帧自动检查，也可手动触发 |
| 中断恢复 | 异常中断后自动清理残留任务 |
| 数据迁移 | 旧版本数据格式自动升级 |
| 安装路径自定义 | 可设置默认游戏安装目录 |
| Shimmer 骨架屏 | 列表加载时的渐变闪烁占位效果 |
| 游戏启动器检测 | 自动识别 AlphaROMdie 等特殊启动器 |

---

## 技术栈

- **前端**: Flutter (Desktop)
- **后端**: PocketBase (BaaS)
- **文件服务**: OpenList (Alist 衍生)
- **解压工具**: 7-Zip / UnRAR / RarLz4Unzip
- **转区工具**: Locale Emulator 2.5.0.1


---

## 二次开发指引

| 目录 | 内容 |
| --- | --- |
| `lib/` | 应用源码（页面、组件、服务、数据模型） |
| `lib/packages/luna_metadata_sdk/` | 元数据抓取 SDK（独立子包） |
| `test/` | 单元测试与组件测试 |
| `dev_probe/` | 开发期行为 / 渲染探针（源码级，非运行时依赖） |
| `windows/` `linux/` `macos/` `android/` `ios/` `web/` | 各平台 runner |
| `assets/` | 图片、字体、运行时小工具 |
| `docs/` | 设计文档、架构决策（ADR）、开发日志 |
| `Dev/scripts/` | 本项目自带的构建 / 打包面板 |

历史架构决策与功能方案集中在 `docs/DEV/`；开始改动前建议先读 `docs/DEV/STATUS_MAP.md`、
`docs/DEV/DECISIONS.md` 与 `docs/DEV/SESSION_HANDOFF.md`。

## 安全

- 本仓库**不包含任何 API Key、Cookie、OAuth 应用密钥、令牌或账号密码**。历史开发记录中出现的凭据已统一脱敏，
  源码中的第三方凭据改为编译期注入。
- 所有第三方凭据请在运行时由使用者自行配置，或按上文 `--dart-define` 注入。
- 若发现疑似泄露的凭据，请按 [`SECURITY.md`](SECURITY.md) 处理，不要公开张贴。

## 已知边界

- 目前仅面向 Windows 桌面端；macOS / Linux / 移动端 runner 保留但未经完整验证。
- 部分元数据平台需要使用者自己的账号凭证，且受对方站点风控策略影响。
- 运行时所需的第三方工具（解压、转区等）许可与获取方式见 `THIRD-PARTY-NOTICES.md`。

## 许可证

MIT © 2026 HardManOfficial — 详见 [`LICENSE`](LICENSE)。
