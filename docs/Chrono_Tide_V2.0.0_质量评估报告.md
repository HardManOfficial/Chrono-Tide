# Chrono Tide V2.0.0 深度质量评估报告

- **评估日期**：2026-08-29
- **评估对象**：Chrono Tide 主项目（`D:\CTLIB`，version 2.0.0）
- **评估范围**：`lib/`（200 个 .dart 文件 / 107,450 行）、`server/pb_hooks/`（**空目录**）、`ChronoTide_Setup.iss` 打包配置
- **已排除**：`官网/`、`chrono-tide-opensource/`、`lib/services/.fix_backup_*`（旧备份副本）、根目录第三方制品
- **评估方式**：静态代码审查（只读），未执行程序、未做真机/UI 实测
- **重要说明**：本报告仅做问题分析与定位，**不含任何修复方案或代码片段**

---

## 一、上线评估结论

### 判定：**不建议上线**

2.0.0 目前处于"功能已开发完成、质量未验证"的状态。阻断项不是体验瑕疵，而是三类硬伤：

1. **后端可被任意客户端完全接管**（硬编码 superuser 凭据 + 全明文 HTTP），
2. **用户数据在多条正常路径下会被静默清零或永久删除**，
3. **存在可稳定复现的崩溃与界面锁死路径**。

其中最严重的是安全类问题：一旦安装包公开发布，任何人都可在数分钟内提取出后端超级管理员凭据，
获取全部用户数据的读写删除权限。这类问题**无法通过后续热更新修复**——凭据已经随 2.0.0 安装包泄露，
必须在发布前轮换，因此"先上线再修"的路线不成立。

### 阻断上线的关键问题（必须清零后方可再评估）

| # | 阻断项 | 位置 | 理由 |
|---|--------|------|------|
| B1 | 硬编码 PocketBase **superuser** 账号密码 | `lib/modules/auth/auth_service.dart:26-27, 156-195` | 凭据随安装包分发，泄露不可撤回；superuser = 后端全部集合的读写删除权 |
| B2 | 找回密码无邮箱所有权验证，可任意重置他人密码 | `auth_service.dart:198-360`、`pages/login/forgot_password_dialog.dart` | 知道邮箱即可完整接管任意账号，属账号接管（ATO） |
| B3 | 全部后端通信明文 HTTP | `lib/core/pb_config.dart:7` | 密码、token、superuser 凭据、用户数据均可被链路窃听 |
| B4 | 自动更新：明文 HTTP + 无签名/哈希校验 + 直接执行下载的安装包 | `services/update/update_service.dart:24, 755-771`、`update/update_models.dart:2-19` | 更新通道被劫持即等于全量用户 RCE |
| B5 | OpenList 配置包远程下发、无完整性校验、解压后直接以 `--config` 启动 | `services/openlist_service.dart:94-195, 977-1008` | 远程下发可执行配置，等价于后门通道 |
| B6 | 游戏名/路径清洗不防 `..`，且多处数据写入为整包覆盖 | `extract_manager.dart:825/835/863` 等 10+ 处；`game_data_format.dart:107-168` | 路径穿越 + 已有游戏元数据被清零 |
| B7 | 收藏夹加载失败即清空并覆写磁盘；多入口并发写同一 `.tmp` | `services/collection_service.dart:157-162, 235-254` | 一次瞬时读失败即永久丢失全部收藏夹 |
| B8 | 过滤态下拖拽必崩（RangeError） | `pages/library_page.dart:1096`（配合 `:2179-2183`） | 已核验，收藏夹/搜索态下长按卡片 100% 触发 |
| B9 | 入库取消后进度遮罩永不消失，添加页被永久锁死 | `extract_manager.dart:1987-2005`、`join/join_controller.dart:303-309` | 已核验，用户只能杀进程 |
| B10 | 批量任务删除时删除用户磁盘原图 | `join/batch_import_controller.dart:636-650, 1472-1486` + `join/join_controller.dart:337-345` | 已核验，`pickCover()` 未复制文件，路径可在单/批量间互传 |

---

## 二、问题清单

### 致命（P0）

#### 安全

**S1. 客户端硬编码 PocketBase 超级管理员凭据**
- 位置：`lib/modules/auth/auth_service.dart:26-27`
  ```dart
  static String _e() => '1913672269' '2' '@' '163' '.' 'com';
  static String _p() => 'Bb' '13' '14' '52' '0';
  ```
  使用点：`:156-195` `_getSuperuserToken()` 以该身份请求
  `/api/collections/_superusers/auth-with-password`
- 影响范围：**整个后端**。superuser token 可读写删除 PocketBase 上所有集合的所有记录，
  包括全部 users 记录（邮箱等）。字符串拆分拼接不构成任何保护，`strings`/反编译/抓包均可直接还原；
  且该请求走明文 HTTP（见 S3），中间人一次抓包即得明文。
- 触发条件：任意用户获取安装包后逆向，或在同网段/链路上抓包。
- 等级：**致命**

**S2. 找回密码缺少邮箱所有权校验 → 任意账号接管**
- 位置：`lib/modules/auth/auth_service.dart:198-335`（第 1 步按邮箱查 userId）、
  `:336-437`（第 2 步直接 PATCH 改密码）；
  `lib/pages/login/forgot_password_dialog.dart:10` 注释自述「无需 SMTP，邮箱单因素验证」
- 影响：流程为「输入邮箱 → 服务端返回 userId → 客户端直接把新密码 PATCH 上去」，
  全程无验证码、无邮件链接、无二次确认。攻击者只需知道目标注册邮箱即可重置其密码并接管账号。
  配套的 `lookupEmailByName()`（`:504-570`，按昵称模糊查询返回脱敏邮箱）进一步降低了获取邮箱的门槛。
- 触发条件：在找回密码弹窗输入任意已知注册邮箱 → 直接设置新密码 → 登录。
- 等级：**致命**

**S3. 全部后端通信使用明文 HTTP**
- 位置：`lib/core/pb_config.dart:7` — `http://117.72.115.30:8090`
- 影响：登录密码、auth token、superuser 凭据、用户资料、游戏元数据全部明文传输，
  无任何传输层保护。同一 IP 上的更新服务（`:8000`）同为明文。
- 触发条件：任何网络位置上的被动监听（公共 Wi-Fi、同网段、运营商链路、被控路由）。
- 等级：**致命**

**S4. 自动更新通道无完整性校验且直接执行下载的可执行文件**
- 位置：`lib/services/update/update_service.dart:24`（`http://117.72.115.30:8000/version.json`）、
  `:755-771` `installUpdate()`；`lib/services/update/update_models.dart:2-19`
  ```dart
  class VersionInfo {
    final String latestVersion;
    final String updateLog;
    final String downloadUrl;      // 无 hash / signature / checksum 字段
  }
  ```
  ```dart
  await Process.start(exePath, [], runInShell: true);   // update_service.dart:769
  ```
- 影响：攻击者只要能控制或劫持 `117.72.115.30:8000`（服务器被入侵、域名/IP 劫持、中间人），
  即可让所有在线客户端下载并执行任意程序，权限等同当前用户。这是**全量用户远程代码执行**。
- 触发条件：篡改 version.json 的 `downloadUrl` 指向恶意安装包，等待客户端检查更新。
- 等级：**致命**

**S5. OpenList 配置包远程下发、无签名校验、解压后直接启动**
- 位置：`lib/services/openlist_service.dart:94-195`（从 PocketBase 明文拉取 `data.zip` →
  解压到 `runtime/openlist/data`）、`:977-1008`（`--config` 启动 `openlist.exe`）
- 影响：`data.zip` 内容与来源均无任何完整性/签名校验，下载后直接解压并作为 OpenList 的配置与数据库启动。
  服务端或中间人可控该包，即获得一条"远程下发配置并生效"的通道。
  附带问题：OpenList 以硬编码 `admin/admin` 登录（`:1054-1060`），监听 `127.0.0.1:5244`。
- 触发条件：篡改 PocketBase 中 `openlist_configs` 记录的 `dataZip` 字段。
- 等级：**致命**

**S6. PowerShell 命令注入（图标提取）**
- 位置：`lib/services/icon_extractor_service.dart:52-64`、`:121-181`
  ```dart
  final psScript = '''
  Add-Type -AssemblyName System.Drawing
  \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$exePath")
  ...
  \$fs = [System.IO.File]::OpenWrite("$outputPath")
  ''';
  await Process.run('powershell', ['-NoProfile','-NonInteractive','-Command', psScript]);
  ```
- 影响：`exePath` / `coverPath` / `outputPath` 直接插值进 PowerShell 双引号字符串。
  全项目标题清洗只过滤 `[\\/:*?"<>|]`（见 S7），而 `$`、`(`、`)`、`` ` ``、`;`、`&`
  在 Windows 下均为合法文件名字符。构造形如 `$(Start-Process ...)` 的目录/文件名即可执行任意 PowerShell。
  路径来源是用户导入的游戏目录或网络抓取的标题，攻击者可通过分享的压缩包名称投递。
- 触发条件：入库/生成桌面快捷方式时触发图标提取，路径含 `$(...)` 即执行。
- 等级：**致命**（本地代码执行，需用户导入恶意命名的目录，故定为致命下限）

#### 数据安全

**D1. 路径穿越：游戏名清洗不防 `..`**
- 位置：`services/extract_manager.dart:825/835/863`、`pages/join/join_controller.dart:896/977`、
  `pages/join/batch_import_controller.dart:1377`、`core/path_helper.dart:132`、
  `services/local_game_registry.dart:439/750/1056`、`services/save_backup_service.dart:349`、
  `services/shortcut_service.dart:40`、`widgets/game_detail_dialog.dart`、共 10+ 处
  ```dart
  final safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  ```
- 影响：标题为 `..` 或 `..\..\X` 时，元数据目录/游戏本体目录被写到 Games 目录之外；
  Windows 保留设备名（`CON`、`NUL`、`AUX` 等）与超长路径（>260）未校验，会静默抛 FileSystemException。
  标题可来自网络抓取数据源，非完全受控。
- 触发条件：在批量卡片或入库表单中把标题改为 `..\..\foo` 后入库。
- 等级：**严重**

**D2. `writeGameDir` 整包覆盖已有游戏的 game.json**
- 位置：`lib/services/game_data_format.dart:107-168`
- 影响：重复安装/覆盖入库已存在的游戏时，`play_time`、`sessions`、`first/last_opened_at`、
  `collection_ids`、`play_status`、`mark` 全部清零。批量入库按 2 路并发
  （`batch_import_controller.dart:1276-1293`），两个清洗后同名的游戏会互相覆盖，
  其中一款在库中彻底消失。
- 触发条件：重复安装已入库游戏；或批量列表中存在清洗后同名的游戏。
- 等级：**致命**（用户游玩数据不可恢复丢失）

**D3. 收藏夹加载失败即清空并覆写磁盘文件**
- 位置：`lib/services/collection_service.dart:157-162`
  ```dart
  } catch (e) {
    debugPrint('[COLLECTION] ⚠️ 加载失败: $e');
    _collections = [];
    _loaded = true;
    await _ensurePresetCollections();   // 内部立即 _save() 覆写
  }
  ```
- 影响：一次瞬时读失败（文件被占用、落盘半途、杀软扫描）即导致用户全部收藏夹被永久覆盖清空，
  且 UI 无任何错误提示。
- 触发条件：让 `collections.json` 读取抛异常后重启应用。
- 等级：**致命**

**D4. 收藏夹多入口并发写同一个临时文件，无串行化**
- 位置：`lib/services/collection_service.dart:235-254`（固定 `$_filePath.tmp`）
- 影响：`setMarkMigrated()` / `create()` / `delete()` / `_ensurePresetCollections()` 可并发进入，
  两次写同一 tmp 会互相截断拼接，产出损坏 JSON，进而触发 D3 的清空分支。
- 触发条件：启动阶段预设补建与 UI 写操作重叠。
- 等级：**致命**

**D5. 便携化迁移不校验内容即删除 C 盘旧数据**
- 位置：`lib/services/storage/migration_orchestrator.dart:164-170`
  ```dart
  } else if (newDir.existsSync() && await _countFiles(newDir) > 0) {
    if (deleteOld) await _safeDeleteDir(oldDir);   // 不比对内容，直接删旧
    await MigrationMarkers.injectFlag(prefsFile, unitId);
  ```
- 影响：若安装目录下的 `game_configs`/`user_themes`/`user_backgrounds` 是其他来源产生的无关数据，
  旧的真实数据会被无条件删除，且标志位随即置位使下次不再迁移。数据不可恢复。
- 触发条件：安装目录预先存在同名目录（手工拷贝、旧版残留）后首次启动 2.0.0。
- 等级：**致命**

**D6. 删除游戏递归删除本体 + 元数据，存档备份同归于尽**
- 位置：`lib/services/local_game_registry.dart:1194-1208`；
  存档目录 `Games/{safeName}/saves` 位于 metaDataDir 之内（`save_backup_service.dart:82-85`）
- 影响：一次删除操作同时抹掉游戏本体、元数据与全部存档备份，无回收站、无二次确认说明。
- 触发条件：库页删除任意游戏。
- 等级：**致命**

**D7. 会话归档与 play_time 写入竞争，且两步写无事务**
- 位置：`lib/services/game_data_format.dart:461-524`（`_archiveSessionsIfNeeded`）；
  `:502-517`（先写归档文件，再裁剪 game.json）
- 影响：归档在写队列之外读-改-写 game.json，与 2 秒周期的时长写入竞争，会把已累加的 `play_time`
  整体回退；若两步写之间崩溃，同一批会话同时存在于归档与 game.json 中，
  而读取端直接拼接两者（`experience_history_service.dart:301-304`），导致时长重复计算。
- 触发条件：游戏游玩 >100 次会话后正常退出（触发归档）；或归档窗口内断电/强杀。
- 等级：**致命**

**D8. 旧格式迁移误判，把新格式 game.json 回退成旧数据**
- 位置：`lib/services/game_data_migration.dart:41-44`
  ```dart
  if (hasCtgame && hasGameJson) { skippedCount++; continue; }
  final oldInfoFile = File('${entity.path}/game_info.json');
  if (!await oldInfoFile.exists()) continue;
  ```
- 影响：目录中同时存在新的 `game.json`（含游玩时长）与旧的 `game_info.json` 时，
  用旧数据整包覆盖（见 D2），新数据丢失，且 `game_info.json` 被 rename 成 `.bak` 破坏现场。
  `.ctgame` 是隐藏文件，通过资源管理器/网盘/压缩包复制元数据目录时极易丢失，从而触发误判。
- 触发条件：元数据目录中 `.ctgame` 缺失但 `game_info.json` 残留。
- 等级：**致命**

**D9. 批量任务删除时删除用户磁盘原图**
- 位置：`lib/pages/join/batch_import_controller.dart:636-650`（`_cleanupSingleGameCache`）、
  `:1472-1486`（`_cleanupAllCache`）；
  根因 `lib/pages/join/join_controller.dart:337-345` `pickCover()` 直接保存用户原图路径、未复制；
  路径可在单游戏表单与批量列表间互传（`pages/join_page.dart:132`、`:194-210`）
  ```dart
  if (game.coverFilePath != null && ...) { coverFile.deleteSync(); }
  ```
- 影响：用户手动选择的本地封面图片被当作"缓存"删除，**丢失的是用户自己磁盘上的原文件**，
  不在应用目录内，用户无从恢复，也无从预期。
- 触发条件：在左侧表单选一张本地图片作封面 → 在批量卡片点「×」移除，或点底部「取消」清空列表。
- 等级：**致命**

#### 崩溃 / 界面锁死

**C1. 过滤态下拖拽卡片必崩（RangeError）**
- 位置：`lib/pages/library_page.dart:1096`
  ```dart
  for (int i = 0; i < _games.length; i++) {
    final key = _cardKeys[i];   // _cardKeys 只按 filteredGames 长度维护
  ```
  对比 `:2179-2183` `_buildGameGrid()` 中 `_cardKeys` 按 **filteredGames.length** 维护
- 影响：进入收藏夹视图或搜索过滤后（filtered < 总数）长按卡片触发拖拽 →
  `_recacheCardRects()` 立即越界抛异常，界面红屏。
- 触发条件：收藏夹/搜索过滤生效 + 长按卡片。**已核验。**
- 等级：**致命**

**C2. 入库取消后进度遮罩永不消失，添加页被永久锁死**
- 位置：`lib/services/extract_manager.dart:1987-2005` `cancel()` 末尾发出
  `_emitStatus(ExtractStatus.idle)`；而 `pages/join/join_controller.dart:303-309`
  的 `_onExtractStatusChanged` 只处理 `completed`/`failed`；
  `pages/join_page.dart:410-420` 的移除条件为 `isProgressSuccess || isProgressFailed`
- 影响：取消后既不置成功也不置失败，进度浮层再无任何移除路径，
  黑遮罩 + 「正在入库…」永久停留，页面完全不可操作，只能杀进程。**已核验。**
- 触发条件：单文件导入压缩包 → 弹出进度浮层 → 点「取消」。
- 等级：**致命**

**C3. Magpie 超分启动失败时详情弹窗不可关闭**
- 位置：`lib/widgets/game_detail_dialog.dart:425-449`（`fallbackOnFail == false` 时
  `_isLaunching` 永不复位）→ `:1437` 渲染 `_buildLoadingOverlay()`，
  该遮罩为 `Positioned.fill` 且盖住关闭按钮
- 影响：进度条卡在 100%，弹窗完全不可交互、不可关闭，只能杀进程。
- 触发条件：超分启动失败且 Magpie 设置未开启失败回退。
- 等级：**致命**

**C4. 批量入库控制器监听器在 dispose 时未移除**
- 位置：`lib/pages/join_page.dart:67-85`（`addPostFrameCallback` 中注册监听，未保存引用）、
  `:88-97` `dispose()` 仅 `if (widget.batchController == null) _batchController.dispose();`
- 影响：传入全局 `batchController` 时，页面卸载后批量列表再次 notify →
  `setState() called after dispose()` 崩溃；闭包内还会操作已 dispose 的 controller 的文本控制器。
- 触发条件：JoinPage 被卸载（登出/导航/热重载）后批量列表状态变化。
- 等级：**致命**

### 严重（P1）

**A1. 大量 `await` 后无 `mounted` 检查即 `setState` / 使用 `context`**
- 位置（节选）：
  - `pages/library_page.dart:722-723`（`_refreshFromDisk`）、`:905`（详情关闭后静默刷新）、
    `:686-694`、`:464-472`、`:1511-1630`（拖拽动画回调）
  - `pages/home_page.dart:80-81`
  - `widgets/game_detail_dialog.dart:834/854/862`（移动游戏位置，拷贝数十 GB 期间）、
    `:999/1010`（更换封面）
  - `widgets/save_backup_dialog.dart:269-271, 293-297`
  - `widgets/settings_modal.dart:2659-2678`
  - `pages/game_detail_page.dart:641-644`
- 影响：任一异步操作进行中用户切页/关窗，即触发 `setState() after dispose()` 崩溃。
  大文件拷贝、磁盘扫描、文件选择等长耗时操作尤其容易命中。
- 等级：**严重**

**A2. `didChangeDependencies` 中执行全量磁盘扫描**
- 位置：`lib/pages/library_page.dart:741-744`
- 影响：主题切换、MediaQuery 变化、**窗口 resize/最大化**都会触发 `scan()` + 自定义排序读取
  + 封面全量解析，打断拖拽/编辑态，大库下明显卡顿。
- 触发条件：拖拽窗口边框调整大小、切换明暗主题。
- 等级：**严重**

**A3. 前台检测 FFI 失败时同步调用 PowerShell，阻塞 UI isolate**
- 位置：`lib/services/foreground_window_service.dart:127-136`
  ```dart
  final result = Process.runSync('powershell',
    ['-NoProfile','-NonInteractive','-Command', '...']);
  ```
- 影响：`_checkForegroundAll()` 由 500ms 定时器驱动，FFI 提权不足/受保护进程返回 null 时，
  每次都同步拉起 PowerShell（冷启 1-3s，杀软扫描下 10s+），**UI 完全冻结**，
  并挤压 2s 的时长监控定时器（见 A5）。
- 触发条件：切到以提升权限运行的窗口（任务管理器、部分安装程序）。
- 等级：**严重**

**A4. 游戏退出自动备份在 UI isolate 上做全同步磁盘遍历**
- 位置：`local_game_registry.dart:2889-2927` → `save_scanner.dart:340-394, 615-628`
  （`listSync` / `statSync` / 递归 `_calcDirectorySync`）
- 影响：大型游戏目录（数千子目录、数十 GB）上同步执行，秒级到十秒级 UI 冻结，
  且发生在游戏刚退出或玩满 15 分钟时。自定义路径含 `*` 时
  `_expandDirGlob`（`save_scanner.dart:501-530`）可能逐级展开并枚举整个盘符。
- 等级：**严重**

**A5. 游玩时长 `clamp(0, 4)` 导致定时器被挤压时系统性少计**
- 位置：`lib/services/local_game_registry.dart:2244-2251`
  ```dart
  secondsToAdd = delta.clamp(0, _monitorIntervalSec * 2).toInt();
  ```
- 影响：2s 监控定时器一旦被阻塞（见 A3、A4），真实间隔远超 2s，每次最多只补 4s，
  时长持续少计。反向：精准模式下非前台时 `lastSettledTime` 不推进，
  回到前台那一刻会多计最多 4s。
- 等级：**严重**

**A6. 阅历统计：有 sessions 就完全丢弃 daily_play_log**
- 位置：`lib/services/experience_history_service.dart:264-268`
- 影响：session 只在「正常退出 / 应用退出 / 进程检测连续失败」三条路径写入。
  应用崩溃、被任务管理器结束、断电 → 该会话 `play_time` 已落盘但无 session 记录 →
  阅历日历中当日为 0 或整日缺失，与详情页总时长长期对不上。两源 `count` 语义不同
  （启动次数 vs ≥60s 会话数），切换数据源会导致"游玩次数"跳变。
- 等级：**严重**

**A7. `refreshStaleEntries` 捕获任何异常都把游戏从库中移除**
- 位置：`lib/services/local_game_registry.dart:498-513`
- 影响：游戏放在移动硬盘 / 网络驱动器 / 未就绪设备上时，`exists()` 抛异常 → 条目被静默移出库。
- 触发条件：把游戏目录设在移动硬盘，拔盘状态下启动应用。
- 等级：**严重**

**A8. 恢复存档无确认、无现状快照，直接覆盖当前进度**
- 位置：`lib/services/save_backup_service.dart:213-228`
- 影响：用户当前进度被旧备份无条件覆盖，覆盖前不对现有存档做任何备份。
  `originalPaths` 是备份时的绝对路径，游戏换过目录后会恢复到早已不存在的旧路径（静默丢失）。
- 等级：**严重**

**A9. 自动备份无保留上限，且在游戏运行中复制半写文件**
- 位置：`local_game_registry.dart:2274-2278, 2310-2315` + `save_backup_service.dart:97-179`
- 影响：每次有效会话（≥15 分钟）都产生一份全量备份且永不清理，磁盘持续增长；
  备份在游戏仍在运行时触发，`source.copy()` 无共享锁/VSS，可能复制到写了一半的存档。
- 等级：**严重**

**A10. 备份操作以「文件夹名」而非 id 定位目录，存在误删/误恢复**
- 位置：`lib/services/save_backup_service.dart:197, 274, 295`
- 影响：`_findBackupById` 按 id 匹配，但 `deleteBackup`/`restoreSave`/`renameBackup`
  均按 name 拼路径；`renameBackup` 不检查目标名是否已存在即 rename（同类型会覆盖）。
- 触发条件：把备份 A 重命名为已存在的备份 B 的名字 → B 的目录被替换。
- 等级：**严重**

**A11. 提交按钮禁用态失效且无防抖**
- 位置：`lib/pages/join/widgets/action_buttons.dart:87-117`（`onTap` 永不为 null，
  `canSubmit` 只影响配色）；`join_controller.dart:730-760`（`submitAddGame()` 无 `_isSubmitting` 闸门）
- 影响：灰色态仍可点击；连点可并发启动两次解压/复制流程。
- 等级：**严重**

**A12. 同名游戏并发入库互相覆盖**
- 位置：`lib/pages/join/batch_import_controller.dart:1276-1293`（`batchSize = 2`，`Future.wait`）
- 影响：两个游戏 `metaDataDir` 相同时，`writeGameDir` + `registerExtractionComplete` 交叉写入。
- 等级：**严重**

**A13. 头像上传取消后 loading 永不复位**
- 位置：`lib/widgets/settings_modal.dart:3993-4017`
  ```dart
  setState(() => _isUploadingAvatar = true);
  if (result == null || result.files.isEmpty) return;   // 未复位
  if (file.bytes == null || file.bytes!.isEmpty) return; // 未复位
  ```
- 影响：上传入口永久禁用（`onTap: _isUploadingAvatar ? null : ...`），只能重启应用。
- 触发条件：在文件选择框点取消。
- 等级：**严重**

**A14. 解压阶段无取消入口，关闭面板任务仍在后台运行**
- 位置：`lib/pages/install_center_page.dart:629-698`（`_buildExtractingUI` 只有进度条，
  无取消按钮；下载态 `:620-623` 才有）
- 影响：用户只能关闭面板，解压进程继续执行。
- 等级：**严重**

**A15. 硬编码第三方 API 凭据**
- 位置：
  - `lib/services/metadata_fetcher.dart:33` —
    `kTouchGalApiToken = '<REDACTED>'`（生产 live token）
  - `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart:1448-1449` —
    `'client_id': 'ymgal'`, `'client_secret': 'luna0327'`
- 影响：凭据随安装包分发，可被提取后盗用，导致第三方服务配额耗尽或接口被封禁。
- 等级：**严重**

**A16. 硬编码压缩包默认解压密码**
- 位置：`lib/services/extract_manager.dart:42` — `_defaultPassword = 'Bilibili_Slpeey'`
- 影响：密码明文固化在客户端，且解压日志会把它写进磁盘日志文件
  （`:1059-1062` 记录「密码: xxx」）。同时存在版权合规风险，需确认该密码的来源与授权。
- 等级：**严重**（合规）+ **一般**（信息泄露）

**A17. 进度浮层未监听控制器，进度与成功/失败态永不刷新**
- 位置：`lib/pages/join_page.dart:388-394`（Overlay 插入 `JoinProgressDialog`，
  位于 `AnimatedBuilder` 之上）；`join/widgets/progress_dialog.dart:7-13`（`StatelessWidget`）
- 影响：Overlay 不随控制器 notify 重建，百分比、阶段文案、成功/失败页全部停在「正在入库…」。
- 等级：**严重**

**A18. 拖拽落位用「过滤后索引」操作「全量列表」**
- 位置：`lib/pages/library_page.dart:1426`（`_filteredAndSortedGames[_originalIndex!]` 无边界检查）、
  `:1481-1484`（对来自 `_games` 的 `reordered` 使用过滤后下标）
- 影响：收藏夹视图内拖拽会交换 `_games` 中错误下标的游戏，顺序被写坏并持久化；
  列表在拖拽期间被刷新缩短时 `:1426` 越界。
- 等级：**严重**

**A19. `setState` 在异步动画回调内无 `mounted` 保护（拖拽收尾）**
- 位置：`lib/pages/library_page.dart:1511-1526, 1562-1578, 1581-1598, 1613-1630`
- 影响：拖拽动画 300ms 窗口内切页/关窗 → 崩溃。
- 等级：**严重**

**A20. 多处未捕获的异步异常**
- 位置：
  - `pages/game_detail_page.dart:230-231` `_loadSeriesData`（注释称"静默失败"但无 try/catch）
  - `pages/game_detail_page.dart:339-362` 截图抓取 `apiFetchFuture` 创建后从未 await
  - `pages/join/join_controller.dart:671`、`join_page.dart:138/186` 封面下载 fire-and-forget
  - `pages/join/widgets/metadata_source_settings_dialog.dart:128-149`（`try...finally` 无 catch）
  - `widgets/settings_modal.dart:1288-1303, 1390-1404, 1751-1753`（开关失败静默、无 try/catch）
- 影响：异常逃逸为未捕获异步错误；用户看不到任何失败反馈，设置项实际未生效但显示为成功。
- 等级：**严重**

### 一般（P2）

- **B1. PocketBase filter 拼接注入面**：`lib/repositories/game_repository.dart:52, 250`
  直接把 `searchQuery` 拼进 filter 表达式。
- **B2. `_isSubPath` / `isSubdirectory` 对带尾部分隔符的目录与盘符根失效**：
  `win32_process_service.dart:459-468`、`foreground_window_service.dart:148-161`、
  `utils/path_normalizer.dart:82-86`。`directoryPath` 带尾部 `\` 或为盘符根时，
  逃逸进程检测与路径包含去重全部失效 → 精准模式不计时、导入排重漏判。
- **B3. 会话记录解析失败回退 1970，跨日分配循环约 2 万次**：
  `services/stats_aggregator.dart:123-135, 419-470`。一条 `start_time` 损坏的会话会让
  `_distributeSessionByDays` 从 1970-01-01 迭代到今天，打开阅历/统计页明显卡顿，
  并把时长摊到 2 万个日期上污染 `daily_play_log`。
- **B4. `aggregate()` 的 `gameCount` 统计的是「天-游戏」条目数而非游戏数**：
  `stats_aggregator.dart:202-205`。周/月粒度下「玩过 N 款游戏」虚高。
- **B5. 安装统计重试会产生重复 `install_records`，读-改-写非原子**：
  `services/install_stats_service.dart:96-101, 139-154`。
- **B6. `_inFlight` 在早退路径不复位**：`install_stats_service.dart:53-72`。
  未登录时安装游戏 → 该 gameId 在本进程生命周期内后续登录也永不上报。
- **B7. 日志轮转排序比较器不满足传递性**（失败时 return 0）：
  `services/storage/log_rotation_service.dart:146-152`。`List.sort` 结果未定义，
  可能把**最新日志**排到被删除区间；比较器内做同步 IO，O(n log n) 次 `statSync`。
- **B8. 存储清理不检查是否有进行中的下载/解压**：
  `services/storage/storage_cleanup_service.dart:286-300, 371-403`。
  清理期间若正在下载或解压 → `data/tmp` 被清空、`._temp_layer_*` 被删 → 解压中断、产物残缺。
- **B9. 全部文本输入无长度限制与非法字符校验**：
  `join/widgets/form_inputs.dart` 全文件；`settings_modal.dart:1823-1843`（代理地址，
  任意字符串直接交给 `MetadataFetcher.updateProxy`）；`save_backup_dialog.dart:384-395, 650-668`
  （自定义存档路径不校验，`C:\` 会导致全盘扫描；备份名用作目录名无校验）。
- **B10. 游戏路径编辑只校验「目录存在」**：`join/widgets/batch_import_section.dart:1204-1216`；
  `batch_import_controller.dart:689-698` `updateGamePath` 只改 `folderPath`，
  `launchExe` 保持旧值 → 入库后无法启动。可把路径改成 `C:\`、`C:\Windows`。
- **B11. 启动管理保存按钮无防抖可重复 pop；开关即时生效但「取消」无法回滚**：
  `widgets/launch_manager_dialog.dart:912-956, 453-470`。
- **B12. UndoRedoController（ChangeNotifier）未 dispose**：
  `widgets/theme_editor_dialog.dart:97, 134-138`。反复开关主题设计器持续泄漏。
- **B13. 延迟 500ms 后 `notifyListeners` 无 disposed 保护**：`join/join_controller.dart:317-325`。
- **B14. 库根视图搜索无匹配时完全空白，无任何空态**：
  `library_page.dart:1927-1935`（空态仅在 `_activeCollectionId.isNotEmpty` 时渲染）、`:2178`。
- **B15. 省略级 Overlay 无生命周期管理**：`game_detail_page.dart:1007-1101`。
  `dispose()` 不移除 OverlayEntry，菜单展开时切页 → 全屏透明屏障残留，拦截所有点击。
- **B16. HttpClient 异常路径未关闭 / 响应体未排空**：`game_detail_page.dart:424-443`
  （`statusCode != 200` 时未 drain，也未 close）。
- **B17. 元数据抓取异常被吞，任务仍标记为 completed**：`batch_import_controller.dart:1216-1218, 980-989`。
  抓取失败的游戏显示"完成"，用户无法感知、也不出现重试按钮。
- **B18. 启动程序扫描无深度/数量上限，去重为 O(n²)**：`join/utils/game_folder_scanner.dart:418-431, 552-579`；
  `join_controller.dart:1015` 同样递归无上限。误选 `C:\` 会长时间同步 IO 冻结 UI。
- **B19. `series_repository` 缓存无容量上限**：`repositories/series_repository.dart:21-24`。
- **B20. `updateGameTitle` 半完成状态**：`local_game_registry.dart:1073-1155`，
  目录 rename 成功但 `updateGameJson` 失败时返回 false，磁盘目录名与内存 key 已改。
- **B21. `save_manifest._tryParseKey` 消费输入后返回 null 时不恢复 `_pos`**：
  `services/save_manifest.dart:552-581`，清单解析可能静默出错。

### 轻微（P3）

- `main.dart:364` 覆盖了 `app_log_helper.dart:137` 设置的 `FlutterError.onError`，
  导致框架渲染错误不再写入应用日志文件（仅在控制台 present）。
- 搜索框每键击同步写 SharedPreferences，无防抖：`library_page.dart:702-706`。
- 启动保护标志在「选择启动程序」分支提前释放：`library_page.dart:1675-1677`，
  快速双击可同时弹出多个 ExeSelectorDialog。
- `settings_modal.dart:2658` `endsWith('Magpie.exe')` 大小写敏感，选择 `magpie.exe` 会被误判。
- 详情弹窗固定 `width: 960` + `insetPadding: 24`，窗口宽度 < 1008px 时横向溢出（**待实测确认**）。
- 首页 `_buildPageIndicator` 按 `_filteredGames.length` 生成全部指示点，
  游戏数量达数百时 Row 横向溢出（**待实测确认**）。
- `watch_folder_service.dart:643-644` 候选队列持久化未 await 且异常被吞。

---

## 三、测试覆盖说明

### 已覆盖（静态审查）

| 层次 | 已审查模块 |
|------|-----------|
| 安全/网络 | `pb_config`、`auth_service`、`update_service`、`openlist_service`、`download_core`、`icon_extractor_service`、`system_proxy_detector`、SDK 各数据源 |
| 解压/安装 | `extract_manager`（全文）、`rar_lz4_unzip_service`、`install_path_preference` |
| 数据层 | `local_game_registry`（启动/时长/删除）、`game_data_format`、`game_data_migration`、`collection_service`、`save_backup_service`、`save_manifest`、`save_scanner`、`experience_history_service`、`stats_aggregator`、`install_stats_service`、`watch_folder_service`、`auto_import_pipeline`、`import_dedup_index`、storage 迁移与清理 |
| UI/交互 | `library_page`、`game_detail_dialog`、`settings_modal`、`home_page`、`game_detail_page`、`discover_page`、`install_center_page`、`join/` 全流程、`big_picture/` 大屏模式、`main.dart`、`main_container.dart` |
| 打包 | `ChronoTide_Setup.iss`（已确认随包分发 `runtime/openlist`、`runtime/locale_emulator`、Magpie、7z/UnRAR/bz 等） |

### 未能覆盖（需要补充验证）

1. **服务端实配置**：`server/pb_hooks/` 为空目录，PocketBase 各 collection 的 API rules
   （是否阻止未授权 list/patch）**无法验证**，需直接检查服务端。
2. **真机/UI 实测**：本次为纯静态审查，未运行程序。所有"崩溃""锁死"结论均为代码路径推导，
   建议按报告中「触发条件」逐一实测复核。
3. **内置第三方组件版本**：`runtime/tools/7z.exe` 版本未知。若 < 21.07，
   存在 CVE-2022-29072（7-Zip 解压路径穿越），与 D1 叠加可放大为任意文件写入。
   同理需确认 `UnRAR.exe`、`bz.exe`、`openlist.exe` 版本及其已知 CVE。
4. **边界与压力场景**：超大游戏库（数千款）、超长路径（>260）、非 UTF-8 文件名、
   网络驱动器/移动硬盘/只读介质、多实例并发、断电/强杀恢复、系统休眠与跨零点计时。
5. **大屏/手柄模式（BPM）**：仅做了代码走查，焦点网格策略与快捷键冲突未实测。
6. **国际化与字体**：`钟齐志莽行书.ttf` 等自定义字体的实际渲染与许可合规未审查。
7. **安装/升级路径**：从 1.8.x 升级到 2.0.0 的实际迁移行为未实测（D5 正是该路径上的风险点）。

### 项目自带自动化测试现状

`test/` 下仅 9 个文件：
- `stats_aggregator_test.dart`、`smart_import/gal_game_detector_test.dart`、
  `smart_import/path_normalizer_test.dart`、`smart_import/watch_folder_service_test.dart`、
  `services/import_dedup_index_test.dart`、`services/save_manifest_parse_test.dart`、
  `services/manifest_service_test.dart`、`services/cover_download_service_concurrency_test.dart`、
  `big_picture/`（3 个小组件测试）
- `widget_test.dart` 是占位文件，内容为 `test('placeholder', () => expect(true, isTrue));`

**核心模块零测试覆盖**：`local_game_registry`（2946 行）、`game_data_format`、`extract_manager`、
`auth_service`、`update_service`、`openlist_service` 均无测试；
UI 层无任何 widget/golden 测试；无集成测试。这与"尚未经过全面测试"的现状一致。

---

## 四、待确认项

1. **内置 `runtime/tools/7z.exe` 版本**是否 ≥ 21.07（关系 zip slip 漏洞面）。
2. **PocketBase 服务端 collection 的 API rules**——若后端已启用严格的 list/view 规则，
   S1/S2 的实际可利用性需重新定级（但硬编码 superuser 凭据本身仍是致命项）。
3. **`117.72.115.30:8000` 更新服务器**是否已在运维管控范围内、是否计划启用 HTTPS 与签名。
4. **硬编码解压密码 `Bilibili_Slpeey`** 的来源与使用授权（合规风险）。
5. **`kTouchGalApiToken`** 是个人申请还是官方授权，是否需要改为用户自行填写。
6. **C2（取消后遮罩锁死）** 是否存在上层补偿逻辑未纳入本次审查（当前按代码路径判定为必然发生）。
7. **C3（Magpie 失败弹窗不可关闭）** 中 `fallbackOnFail` 的默认值与用户实际设置分布。
8. **D6（删除游戏连带删除存档备份）** 是否为有意设计——若产品上确需如此，
   至少应在 UI 上明确告知"将同时删除存档备份"。
