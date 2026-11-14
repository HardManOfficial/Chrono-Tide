# STATUS_MAP — 功能模块地图

> **AI 开工前必读本文件。** 作用是让你在 5 分钟内知道：代码在哪、每个模块干什么、
> 哪些地方是雷区、去哪找历史方案文档。
>
> 最后更新：**2026-10-01**（探索详情页重构 + 4 个深色弹窗 + 探索库来源角标）
> 增量补充：**2026-10-17**（§3.10 游戏字体替换接入 CTFontHook；同日三轮改版：P3.1 管理器=安装器、面板改浮层 → P3.2 字体设置**改回独立窗口**并逐段照原工具版式 → P3.3 **两栏布局**（左兼容设置+字形微调 / 右选字体+预览）、标题栏压到 34、整页不滚动）
> 增量补充：**2026-10-24**（§3.2 启动链路新增 4 个服务 + `launchByTitle`；§3.7 托盘启动改道；§4 新增「启动管理 / 启动兼容性」组件行 —— 见 `features/launch_compatibility_upgrade.md`、ADR-019）
> 增量补充：**2026-10-26**（§3.3 新增 `launcher_candidate_analyzer.dart` 启动程序候选分析器；§4「启动管理」行补推荐角标 —— 见 `features/launcher_smart_recommend.md`、ADR-021）
> ⚠️ 2026-10-01 之后的其他改动（探索协议门禁 / BPM 手柄适配 / NSFW v2.6-v2.7 / OpenList 更新
> 与路径迁移 / 窗口几何持久化 / 智能解压后续轮次等）**尚未回填本表**，请以 `DEV_LOG.md` 为准。
> 维护原则：改动了某模块就顺手更新对应行的状态；发现新模块就补一行。请勿整体重写。

---

## 图例

| 标记 | 含义 |
|------|------|
| 🔴 | **高风险**：3000+ 行巨型文件、或属于稳定区、或牵一发动全身。改动必须走完整审批 |
| 🟡 | **中风险**：逻辑较复杂或与其他模块耦合较多，改动需谨慎 |
| ⚪ | 一般模块，按常规流程即可 |
| 📄 | 有历史方案文档，见文末「文档索引」 |
| 🧪 | 有测试覆盖 |

---

## 一、应用骨架

| 文件 | 行数 | 职责 | 风险 |
|------|------|------|------|
| `lib/main.dart` | ~900 | 应用入口：初始化、窗口配置、全局服务注册 | 🔴 稳定区 |
| `lib/main_container.dart` | ~800 | 主容器：页面路由、侧边栏/标题栏骨架、全局浮层 | 🔴 稳定区 |
| `lib/app_log_helper.dart` | — | 日志辅助 | ⚪ |
| `lib/services/app_state.dart` | — | **全局状态中枢**（Provider），几乎所有页面都依赖 | 🔴 稳定区 |

---

## 二、页面层 `lib/pages/`（24 文件 / 800 KB）

| 页面 | 入口文件 | 行数 | 说明 |
|------|---------|------|------|
| 主页 | `home_page.dart` | 1610 | 游戏网格、启动入口、统计入口 | 🟡 |
| 库页 | `library_page.dart` | **3643** | 游戏列表、筛选、排序、收藏夹 | 🔴 巨型文件 📄 |
| 详情页 | `game_detail_page.dart` | **2158** | 游戏详情整页视图；**v2 探索详情页重构（2026-10-01）**：头部复刻设计、右列大安装按钮删除（并入「Chrono Tide 下载」弹窗）、左列「用户分享」改由「分享」弹窗承载 → 见 `lib/widgets/game_detail/` | 🟡 📄 |
| 探索页 | `discover_page.dart` | **2638** | 元数据发现/推荐流；卡片来源角标 `可安装`/`用户分享`/`可安装 · N 分享` | 🟡 📄 |
| 添加页 | `join_page.dart` + `join/`（15 文件） | 1571+ | 游戏导入：智能导入 / 批量导入 / 元数据抓取 | 🟡 📄 🧪 |
| 安装中心 | `install_center_page.dart` | — | 下载与安装任务管理 | ⚪ |
| 登录/注册 | `login/`、`register/`、`modules/auth/` | — | 账号体系 | ⚪ |

**`join/` 子模块**（添加页，导入链路核心）：
- 控制器：`join_controller.dart`（单游戏）、`batch_import_controller.dart`（批量）
- 工具：`utils/gal_game_detector.dart` 🧪、`utils/game_folder_scanner.dart`
- 组件：`widgets/` 下 11 个（表单、拖放区、元数据区块、数据源设置弹窗等）

---

## 三、服务层 `lib/services/`（51 文件 / 1.3 MB）—— 按职责域分组

### 3.1 游戏数据与存储
| 文件 | 说明 | 风险 |
|------|------|------|
| `local_game_registry.dart` | **本地游戏注册表**，数据读写核心 | 🔴 2965 行 |
| `game_data_format.dart` | 游戏数据格式定义与序列化 | 🟡 |
| `game_data_migration.dart` | 旧版本数据迁移 | 🟡 |
| `repositories/game_repository.dart` | 数据仓库抽象；v2.1.17 起兼管元数据回传云端（`updateGameMetadata` / `buildMetadataBody`） | ⚪ |
| `repositories/series_repository.dart` | 游戏系列仓库 | ⚪ |
| `storage/` | 存储迁移编排（`migration_orchestrator.dart` 等） | 🟡 📄 |
| `manifest_service.dart` | 清单服务 | 🧪 |
| `game_resource_service.dart` | **资源来源层**（PB `game_resources`）：只读 4 方法 + `communityCountBatch`（探索库角标现算）+ `createCommunityResource` + 计数走 `/api/ct/resource/...`（未部署静默降级） | ⚪ 2026-10-01 新增 📄 |

### 3.2 游戏启动链路（历史 bug 高发区）
| 文件 | 说明 | 风险 |
|------|------|------|
| `game_launch_service.dart` | **启动总入口**，所有启动方式都应收敛到这里；2026-10-24 新增 `launchByTitle`（托盘/快捷方式等「只有标题」的入口） | 🔴 |
| `launch_process_launcher.dart` | **权限裁决唯一来源**（direct / elevated / shellFallback 三条通道）：740 自动转提权、UNC 工作目录不进 cmd、失败回退 `cmd /c start`。2026-10-24 新增 | 🔴 📄 |
| `elevation_service.dart` | 自身/PID 提权判定（`TokenElevation`）、`ShellExecuteExW + runas` 拉起进程、自提权重启。🔴 `SHELLEXECUTEINFOW` x64 = **112 字节**（实测）。2026-10-24 新增 | 🟡 📄 |
| `game_compatibility_service.dart` | **HKCU 兼容性层**（`AppCompatFlags\Layers`）唯一写方：解析 / 每启动幂等 upsert / 按记账精确回滚 / 路径迁移。2026-10-24 新增 | 🟡 📄 |
| `win32_registry_service.dart` | FFI 注册表读写（仅 HKCU / 仅 REG_SZ），同步、不抛异常。🔴 `HKEY_CURRENT_USER` 必须写 **-2147483647**。2026-10-24 新增 | 🟡 |
| `compat_preference.dart` | 兼容性总开关 / 超分转区提权 / 提权提示一次性（SharedPreferences，**懒加载**，刻意不接 `main.dart`）。2026-10-24 新增 | ⚪ |
| `game_launcher_detector.dart` | 启动器/转区工具探测 | 🟡 |
| `magpie_service.dart` | Magpie 超分启动集成（PowerShell 仅剩窗口类名探测/激活；**DPI 注册表写入已移交给兼容性层**） | 🔴 1797 行 |
| `locale_service.dart` / `locale_logger.dart` | Locale Emulator 转区（`launchWithLocale` 新增 `elevate`） | 🟡 |
| `game_launch_logger.dart` | 游玩时长记录 | 🟡 📄 |
| `foreground_window_service.dart` | 前台窗口检测 | ⚪ |
| `win32_process_service.dart` / `process_cleanup_service.dart` | 进程管理与清理 | 🟡 |

📄 启动链路整体设计与踩坑：`features/launch_compatibility_upgrade.md`；决策：ADR-019

### 3.3 扫描与导入
| 文件 | 说明 | 风险 |
|------|------|------|
| `auto_import_pipeline.dart` | 自动导入流水线 | 🟡 📄 |
| `exe_scanner.dart` / `save_scanner.dart` | 可执行文件 / 存档扫描 | ⚪ |
| `launcher_candidate_analyzer.dart` | **启动程序候选分析器**（展示期）：分类（无关 / 游戏相关）+ 版本标签（汉化 / HD / 魔改 / 其它语言 / 原版）+ 唯一推荐 + PE 头校验。🔴 **只依赖 `dart:io`**（231 下可用裸 Dart VM 跑探针）；🔴 短标记严禁子串匹配（`sc`∈`scene`）；🔴 汉化分与分类分解耦。2026-10-26 新增，与导入期的 `game_launcher_detector`, **两套独立规则**不谈统一 | 🟡 📄 |
| `watch_folder_service.dart` | 监控文件夹 | 🧪 📄 |
| `import_dedup_index.dart` | 导入去重索引 | 🧪 📄 |

### 3.4 下载 / 安装 / 解压
| 文件 | 说明 | 风险 |
|------|------|------|
| `download_core.dart` | 下载核心 | 🟡 |
| `global_install_center.dart` / `global_task_manager.dart` | 全局任务调度 | 🟡 |
| `extract_manager.dart` | 解压调度 | 🔴 2029 行 |
| `rar_lz4_unzip_service.dart` | RAR / LZ4 解压 | 🟡 📄 |
| `install_path_preference.dart` / `install_stats_service.dart` | 安装路径偏好与统计 | ⚪ |
| `interrupt_cleanup.dart` | 中断清理 | ⚪ |

### 3.5 元数据（抓取与整合）
| 文件 | 说明 | 风险 |
|------|------|------|
| `metadata_fetcher.dart` | **数据源调度**：`kSourceOrder` 是数据源顺序的唯一来源 | 🟡 📄 🧪 |
| `discover_metadata_service.dart` | 探索页元数据懒加载（7 天磁盘缓存）；v2.1.17 起优先读云端沉淀、抓取后回传 | 🟡 📄 |
| `metadata_service.dart` / `discover_metadata_service.dart` | 元数据服务 / 探索页数据 | 🟡 |
| `cover_download_service.dart` | 封面下载（含并发控制） | 🧪 |
| `screenshot_fetch_service.dart` | 截图抓取 | ⚪ |
| `packages/luna_metadata_sdk/` | **独立元数据 SDK**（12 文件，`metadata_services.dart` 1593 行） | 🔴 稳定区 |

### 3.6 统计与存档
| 文件 | 说明 | 风险 |
|------|------|------|
| `stats_aggregator.dart` | 游玩时长聚合统计 | 🟡 🧪 📄 |
| `experience_history_service.dart` | 游玩履历 | ⚪ |
| `file_size_service.dart` | 体积统计 | ⚪ |
| `save_backup_service.dart` / `save_manifest.dart` | 存档备份与清单 | 🟡 🧪 |

### 3.7 系统与集成
| 文件 | 说明 | 风险 |
|------|------|------|
| `autostart_service.dart` / `tray_service.dart` | 开机自启 / 托盘。**托盘「最近游玩」2026-10-24 改走 `GameLaunchService.launchByTitle`**（原直调 `launchGame` 会跳过超分） | ⚪ |
| `shortcut_service.dart` | 桌面快捷方式（创建/删除/改图标，手动触发） | ⚪ 📄 |
| `auto_shortcut_preference.dart` | 「首次启动自动生成桌面快捷方式」全局偏好（**默认关**，设置窗口「游戏与启动 → 系统」） | ⚪ 📄 |
| `quick_window_service.dart` | 快捷窗口 | ⚪ |
| `system_proxy_detector.dart` / `network_status_service.dart` | 代理与网络状态 | ⚪ |
| `network_proxy_core.dart` / `network_proxy_policy.dart` | **全局网络代理策略唯一事实源**（2026-11-13）｜`core` 纯 Dart 三态枚举 + 规范化 + findProxy 生成 + TTL；`policy` 负责 `load`/`apply`/`refresh`/`attachTo(Dio)`/`installGlobalOverrides()`。运行期按 10s TTL 跟随系统代理，开/关代理无需重启 | 🟡 📄 |
| `metadata_field_priority.dart` | 字段级「首选平台」覆盖（2026-11-13，设置 → 元数据 → 字段优先级）。落盘 `metadata_field_priority`，值为**列表**（平台组，兼容旧单值 JSON）；`resolveChain` 只把选中的提到链首（组内保序），其余仍按内置链后备 | ⚪ 📄 |
| `metadata_credentials.dart` | 平台凭证：Bangumi PAT 在线校验（区分 401/403 与网络不通）、鲲 Cookie 校验（**看 `code 205`，不看 HTTP 200**）、Hikarinagi 内置凭据实测；`MetadataCredentialKind` 四态 | ⚪ 📄 |
| `kun_cookie.dart`（SDK） | 鲲登录 Cookie 持久化（`kun_galgame_cookie`）+ 进程内缓存；`kun_service.dart` 每次请求透传 `Cookie`，识别 `code 205` 并在 `fetchLog` 明说「需要登录」 | ⚪ 📄 |
| `metadata_refresh_core.dart` / `metadata_refresh_service.dart` | **全量更新元数据**（2026-11-13）｜`core` 纯 Dart：空值归一 + `computeRefreshUpdates`（默认只补空字段，键名白名单 10 个，绝不碰标题/封面/截图）；`service` 单例 ChangeNotifier：串行+间隔+可取消+失败项重试，写盘只走 `updateGameJsonAtomic` | 🟡 📄 |
| `oauth/`（5 文件）+ `metadata_login_service.dart` | **平台账号一键 OAuth 登录**（2026-11-13，ADR-025）｜`oauth_pkce`/`oauth_token` 纯 Dart（PKCE + 令牌模型）；`oauth_providers` 是两家的 client_id / 回调端口与路径 / scope 唯一事实源（⚠️ 回调端口 23380 与 client 绑定，且被 ReinaManager 常驻，不可改）；`oauth_loopback` 本地回调服务器（**先写响应再 complete**）；`metadata_login_service` 编排换令牌/刷新/退出。抓取层：`hikarinagi_service` 用户令牌优先、`nextmoe_service` 拦截器按请求注入 | 🟡 📄 |
| `openlist_service.dart` | OpenList 集成（云存储） | 🟡 |
| `update/` | 更新检查 | ⚪ |
| `user_cache_service.dart` | 用户缓存 | ⚪ |
| `system_notice_service.dart` | **全局系统提示总线**（2026-10-02 新增）：原底部 SnackBar 统一迁移为「系统提示聊天气泡」，`SystemNoticeLayer` 挂 `MaterialApp.builder` 顶层 | 🟡 📄 |

### 3.8 收藏夹与工具
| 文件 | 说明 | 风险 |
|------|------|------|
| `collection_service.dart` | 收藏夹（含置顶逻辑、脏数据规整） | 🟡 🧪 |
| `path_validator.dart` | 路径校验 | ⚪ |
| `icon_extractor_service.dart` | 图标提取 | ⚪ |

### 3.9 NSFW 内容保护 `lib/services/nsfw/`（v2：YOLO 局部检测，2026-09-04）
| 文件 | 说明 | 风险 |
|------|------|------|
| `nsfw_detection_service.dart` | 检测服务：isolate worker + 双优先级队列 + 开关裁决；下载落盘自动入队 | 🟡 |
| `nsfw_scan_service.dart` | 全量扫描存量封面/截图；首次开启触发、签名变化强制重扫 | 🟡 |
| `nsfw_detection_store.dart` | 判定缓存（文件键+URL 别名键，JSON 落盘，签名失整表失效） | ⚪ |
| `nsfw_model_provider.dart` | 模型从 assets 释放到 `data/models/`（12MB，字节数校验） | ⚪ |
| `nsfw_settings.dart` | 总开关/置信度/推理尺寸/揭示权限（SharedPreferences） | ⚪ |
| `nsfw_box.dart` / `yolo_postprocess.dart` | bbox 数据 + YOLO 解码/NMS | ⚪ |

详细方案与实施状态：`docs/DEV/features/nsfw_filter_implementation_plan.md`（v2 见 §15）

### 3.10 游戏字体替换（CTFontHook）—— 2026-10-17 新增
| 文件 | 说明 | 风险 |
|------|------|------|
| `game_font_patch_service.dart` | **部署层**：把 `winmm.dll` 投放进游戏 exe 同目录（同名代理劫持 ⇒ **启动链路零改动**）；`probe` / `install` / `uninstall` / `writeConfig` / `readConfig` / `resolveExePath` + `detectPeArchFromHeader`（只读前 4KB） | 🟡 📄 |
| `font_hook_ini_codec.dart` | `FontHook.ini` 生成 / 解析（UTF-16LE，手写编解码）；🔴 `PickerShowOnStartup=0` **硬编码**，UI 不可见（否则游戏内字体面板每次启动都弹出挡游戏） | 🟡 |
| `win32_font_enumerator.dart` | FFI `gdi32!EnumFontFamiliesExW` 系统字体枚举（🔴 `lfCharSet` 必须 **1=DEFAULT_CHARSET**）+ isolate + 磁盘缓存；提供降级路径 | 🟡 |
| `font_override_prefs.dart` | 跨游戏**本机偏好**（引导决策记录 / 建议默认字体 / 字符集 / 排版）；**懒加载**，刻意不接 `main.dart` 稳定区；`suggestFontName()` 为新装游戏给一份能生效的初值 | ⚪ |
| `font_compatibility_service.dart` | 本地「不兼容游戏清单」读取与匹配（只读、不联网、不上报；缺失 / 损坏一律按「无清单」处理） | ⚪ |

- 模型：`lib/models/game_font_override.dart` ∷ `game.json.font_override`（**不升** `format_version`，**绝不进** `_overwritableFields`）。
- 载荷：`runtime/fonthook/{32bit,64bit}/winmm.dll`（打包脚本 `5.5 FontHook` 节部署；**不入** `pubspec.yaml` 的 assets）。
- 清单：`resources/fonthook/incompatible.json` → `runtime/fonthook/incompatible.json`（当前 `entries` 为空）。
- 详细方案与实施状态：`docs/DEV/features/game_font_override_implementation_plan.md`（Phase 0–4 全部完成）

---

## 四、组件层 `lib/widgets/`（55 文件 / 1.2 MB）

| 分组 | 文件 | 行数 | 风险 |
|------|------|------|------|
| **详情弹窗** | `game_detail_dialog.dart` | **4810** | 🔴 巨型文件，启动逻辑已在此收敛 |
| **探索详情新弹窗** | `game_detail/`：`dark_surface.dart`(840 共享层：固定深色调色板 + 原子组件 + `showDarkCenteredDialog`/`showDarkAnchoredPanel`) / `ct_download_dialog.dart`(412 获取·锚定 515dp) / `share_list_dialog.dart`(363 分享·锚定 600dp) / `share_detail_dialog.dart`(448 分享详情·居中 725×915) / `upload_resource_dialog.dart`(**1028** 上传·居中 679×1083) / `game_detail_header.dart`(374 头部) / `kanban_identity.dart`(128 看板娘「时之 汐乃」常量) | — | 🟡 2026-10-01 新增 📄 |
| **设置** | `settings_modal.dart` | **4096** | 🔴 巨型文件 |
| **启动管理 / 启动兼容性 / 启动程序推荐** | `launch_manager_dialog.dart`(1438：转区 / 超分 / **以管理员身份运行** 三个同级开关 + **启动兼容性** 分组两个开关) / `exe_selector_dialog.dart`(同款管理员开关) / `elevation_hint_dialog.dart`(新增：「建议以管理员重启」一生一次提示 + 延迟提权重启)；2026-10-24 新增。**2026-10-26**：两处列表接入 `launcher_candidate_analyzer`，用 `launcher_badges.dart`（`★ 推荐` / 灰 `工具`，固定 18px、无最小触控区）+ 第二行版本词缀；🔴 推荐只标角标，**不重排 / 不隐藏 / 不改默认选中** | — | 🟡 📄 |
| 主题设计器 | `theme_editor_dialog.dart` + `theme_editor/`（多文件） | — | 🔴 稳定区 📄 |
| 编辑器预览 | `editor_preview_builder.dart` | 1941 | 🟡 |
| 存档备份弹窗 | `save_backup_dialog.dart` | 1536 | 🟡 |
| 库页组件 | `library/`（多文件：`collection_sidebar.dart`、`collection_picker_menu.dart` 等） | — | 🟡 |
| 对话框基建 | `app_dialog.dart`、`confirm_dialog.dart`、`name_dialog.dart` | — | 🔴 被全局复用 |
| **NSFW 渲染** | `nsfw/`（`nsfw_image.dart` 统一装饰器入口 + `nsfw_mosaic_painter.dart` 局部马赛克；31 处接入点见方案 §9） | — | 🟡 🧪 |
| 下载 UI | `download_button.dart`、`download_progress_bar.dart`、`extract_status.dart` | — | ⚪ |
| 探索页弹窗 | `discover_filter_dialog.dart`、`discover_all_tags_dialog.dart`、`discover_disclaimer_dialog.dart` | — | ⚪ |
| 取色/颜色 | `hsv_color_picker.dart`、`color_channel_panel.dart`、`recent_colors_strip.dart`、`eyedropper_overlay.dart` | — | ⚪ |
| 背景图编辑器 | `background_image_editor_dialog.dart`、`layer_tree_panel.dart` | — | 🟡 📄 |
| 其他 | `sidebar.dart`、`custom_title_bar.dart`、`floating_task_button.dart`、`floating_user_button.dart`、`touch_gesture_handler.dart`、`undo_redo_bar.dart` 等 | — | ⚪ |
| **系统提示气泡** | `app_snack_bar.dart`（全项目提示**唯一入口**，改为委托）+ `system_notice_bubble.dart`（渲染层，2026-10-02 新增） | — | 🟡 📄 |
| **游戏字体替换** | `font_picker_dialog.dart`(单游戏**字体选择器窗口**：**左右两栏**——左 300 宽放兼容设置 + 字形微调（2 列×4 行，每格带独立开关）、右栏搜索/字符集/字体列表/预览；标题栏 34、整页不滚动；**无「恢复」按钮**) / `font_library_panel.dart`(全库「字体器管理」浮层：清单+批量安装/恢复) / `font_hook_gate_dialog.dart`(首次启动安装引导)；2026-10-17 新增，同日三轮改版（P3.1 管理器=安装器 → P3.2 字体设置改回窗口 → P3.3 两栏布局；原 `game_font_dialog.dart` / `library_font_manager_dialog.dart` / `font_picker_panel.dart` 均已删除） | — | 🟡 |

---

## 五、主题系统 `lib/theme/`（11 文件）—— 🔴 稳定区

| 文件 | 职责 |
|------|------|
| `app_theme_manager.dart` | 主题管理器（中枢） |
| `theme_registry.dart` / `theme_element_registry.dart` | 主题与主题元素注册表 |
| `background_image_config.dart` / `background_image_resolver.dart` | 背景图配置与解析 |
| `ct_theme_package.dart` | 主题包定义 |
| `theme_storage.dart` | 主题持久化 |
| `app_colors.dart` / `app_spacing.dart` / `app_styles.dart` / `app_breakpoints.dart` | 设计令牌（颜色/间距/样式/断点） |

> ⚠️ 主题系统改动会波及**全部 UI**。任何改动必须先说明影响范围并取得批准。

---

## 六、BPM 大屏模式 `lib/big_picture/`（18 文件）

| 子模块 | 说明 |
|--------|------|
| `big_picture_manager.dart` | BPM 状态管理 | 🧪 |
| `big_picture_shell.dart` / `big_picture_theme.dart` | 外壳与主题 |
| `pages/` | BPM 页面（含详情页 `big_picture_detail.dart`） |
| `widgets/` | BPM 组件（导航条、焦点发光、交互包装器等） | 🧪 |
| `focus/` | 焦点网格策略 | 🧪 |

📄 历史方案：`big_picture_mode_implementation_plan.md` 等 6 篇（见文档索引）

---

## 七、数据模型与工具

| 目录 | 文件 |
|------|------|
| `lib/models/` | `game_model.dart`（含 `hasOfficial`）、`game_metadata.dart`、`series_model.dart`、`watch_folder.dart`、`discover_filter_state.dart`、`download_state.dart`、**`game_resource_model.dart`（27 字段 + 3 枚举，2026-10-01 新增 🧪）** |
| `lib/utils/` | `path_normalizer.dart` 🧪、`network_path.dart` 🧪（网络路径/卷身份/映射盘可达性，2026-09-26 NAS 适配）、`title_cleaner.dart`、`game_config_manager.dart`、`pb_filter.dart` |
| `lib/core/` | `path_helper.dart`（🔴 路径中枢，含测试用 `exeDirOverride`）、`pb_config.dart`、`portable_file_system.dart`、`portable_image_cache_manager.dart`、`portable_shared_preferences_store.dart` |

> 🔴 `lib/core/portable_*.dart` 是**便携化路径体系**，改错会导致用户数据目录错乱，属稳定区。

---

## 八、高风险文件清单（改这些要格外小心）

按行数排序的巨型文件，AI 在这类文件里最容易「顺手改坏别处」：

| 文件 | 行数 | 建议 |
|------|------|------|
| `lib/widgets/game_detail_dialog.dart` | 4810 | 优先做**局部**修改，不要整体重写 |
| `lib/widgets/settings_modal.dart` | 4096 | 同上 |
| `lib/pages/library_page.dart` | 3643 | 同上 |
| `lib/services/local_game_registry.dart` | 2965 | 数据核心，改前务必跑相关测试 |
| `lib/services/extract_manager.dart` | 2029 | 解压流程复杂，注意中断与清理分支 |
| `lib/widgets/editor_preview_builder.dart` | 1941 | — |
| `lib/pages/game_detail_page.dart` | **2158** | — |

---

## 九、已知待清理项（发现即记录，处理需单独提需求）

| 项 | 位置 | 说明 |
|----|------|------|
| 残留备份目录 | `lib/services/.fix_backup_20260809_playtime_magpie/` | 2678 行的隐藏备份目录残留在源码树中，疑为 2026-08-09 修改 `local_game_registry.dart` 时留下的。是否删除需确认 |
| 人工备份目录 | `lib_backup_20260601/`、`lib_backup_sidebar_20260601_182229/`、`lib_backup_theme_20260602/` | Git 建立前的保命手段，**现已废弃**，但删除前请确认无遗漏改动 |
| 测试覆盖空白 | `lib/pages/`、`lib/widgets/` | 占代码量约 60% 却零测试覆盖，改 UI 必须人工验证 |

---

## 十、历史方案文档索引

### `.trae/documents/`（33 篇，Trae 时代积累的方案文档）

**按主题归类**（内容为历史方案，动手前按需查阅；注意有些方案可能已过时）：

- **BPM 大屏模式**：`big_picture_mode_implementation_plan.md`、`bpm_execution_plan_phase2_to_5.md`、`bpm_phase3_to_5_completion_plan.md`、`bpm_finalization_plan.md`、`bpm_optimization_refactor_plan.md`、`bpm_ui_optimization_plan.md`、`bpm_ui_optimization_v1.2_*.md`（7 篇）
- **批量导入 / 扫描**：`batch-import-*.md`（5 篇）、`batch_import_dedup_scan_optimization.md`、`文件扫描导入机制修复计划.md`（7 篇）
- **元数据**：`metadata_system_upgrade_plan.md`、`metadata_upgrade_completion_plan.md`、`metadata_section_card_optimization.md`（3 篇）
- **游玩时长统计**：`game-playtime-architecture-upgrade.md`（53 KB，最大）、`game-playtime-launch-fix.md`、`游玩时长统计系统重构方案.md`、`stats_aggregator`（4 篇）
- **主题设计器**：`主题设计器-编辑模式明确化与影响范围提示完善.md`、`主题设计器-背景图编辑器-Figma风格拖拽缩放.md`（2 篇）
- **UI 优化**：`sidebar-ui-polish.md`、`title_bar_optimization_plan.md`、`discover_page_refactor_plan.md`、`UI_UX_UPGRADE_PLAN.md`（4 篇）
- **安装与部署**：`安装流程清理与日志缓存管理优化方案.md`、`portable-storage-migration.md`、`desktop_shortcut_polish.md`、`更换游戏目录功能开发计划.md`（4 篇）
- **其他**：`rar_lz4解压工具重写方案.md`、`offline-mode-optimization.md`、`fix-gamedetailpage-install-blank-screen.md`、`(1) 游戏导入标题异常.md`（4 篇）

### `docs/`（26 篇，正式文档）

- **V2.0.0 系列**：`Chrono_Tide_V2.0.0_质量评估报告.md`、`_优化建议清单.md`、`_改动定位与归属判定.md`、`_上线前核查报告.md`、`_性能审计与优化方案.md`、`_性能优化实施报告.md`、`RELEASE_NOTES_v2.0.0.md`
- **架构与方案**：`bpm_architecture.md`、`big_picture_mode.md`、`CTLIB_功能性分析报告_v1.0.md`、`元数据抓取系统技术研究报告_V1.0.md`、`game_detection_rules.md`
- **UI 与设计**：`UI_主题系统升级方案.md`、`UI_库页详情窗口升级方案_v1.0.md`、`UI_UX_UPGRADE_PLAN.md`、`figma-ui-spec.md`、`游玩统计折线表升级*.md`
- **流程**：`打包规范与流程说明_V0.8.md`、`官网升级整理方案.md`

### 项目根目录

- `UI_DEVELOPMENT_GUIDE.md`（17 KB，UI 开发规范）
- `README.md` / `GITHUB_README.md` / `CHANGELOG.md`
- `我的计划设想/` —— **你的开发设想记录，AI 只读不改**（该目录下有同名说明文件）
