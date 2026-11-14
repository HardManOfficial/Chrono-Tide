# Chrono Tide V2.0.0 · 六步修复方案改动定位与归属判定

- **编制日期**：2026-08-29
- **编制人**：高见远（架构师）
- **输入**：`Chrono_Tide_V2.0.0_质量评估报告.md`、`Chrono_Tide_V2.0.0_优化建议清单.md`
- **性质**：只做改动定位与可执行性判定，**不含实现代码**，本次不修改任何 `lib/` 下文件
- **判定对象**：清单全部 18 条（P0×6、P1×5、P2×6、P3×1）

---

## 〇、判定口径

| 类别 | 定义 | 处理原则 |
|---|---|---|
| **A** | 客户端可独立安全修复：改客户端即可闭环，不依赖服务端配合，不破坏现有功能 | 可立刻开工 |
| **B** | 需服务端协同：客户端单边改动会破坏功能或造成事故，必须与服务端变更配对发布 | 严格「服务端先、客户端后」；过渡期必须能降级放行 |
| **C** | 纯服务端/运维：客户端无从代劳，只能由项目负责人在 PocketBase 后台或服务器上操作 | 由项目负责人执行，客户端不排期 |

**B 类的硬规则**：客户端侧新增的校验/约束，在服务端字段未就位时**必须降级放行**（缺失即跳过，不得缺失即拒绝）。否则等同于把「未配置的服务端」判成「攻击」，会一次性打挂全部在线客户端。

**硬约束**：不升级依赖、不换技术栈、不顺带重构、对外接口行为不变。

---

## 一、归属判定总表

| 编号 | 条目 | 归属 | 一句话结论 |
|---|---|---|---|
| P0-1 | 云端 `games` 可被任意登录用户改写 | **B** | 服务端先收紧 `games` 写权限（C 部分），客户端再撤掉直写（A 部分）。单边先改只会导致静默失效，不是事故 |
| P0-2 | 客户端硬编码 superuser 凭据 | **B**（轮换本身是 **C**） | 轮换凭据**立刻做**（C）；客户端去凭据必须等服务端 hook 就位 |
| P0-3 | 找回密码在客户端用 superuser 改密码 | **B** | 与 P0-2 是同一处代码、同一次服务端改造，不得拆开 |
| P0-4 | 全站明文 HTTP | **B ｜严禁单边先改** | 客户端先改 = 全部已发布用户立即失联 |
| P0-5 | 更新包无完整性校验 | **B ｜严禁单边先改** | 客户端先加"必须校验" = 所有客户端无法更新 |
| P0-6 | OpenList 配置包无校验 | **B ｜严禁单边先改** | 客户端先加"必须校验" = OpenList 永不启动 |
| P1-1 | `games` 搜索 filter 注入 | **A** | 客户端转义可独立闭环，服务端白名单是加分项不阻塞 |
| P1-2 | 安装统计去重键可刷量 | **C** | 唯一索引 + 服务端回填；客户端改传 `userId` 需服务端先加字段，不阻断发布 |
| P1-3 | `users` 字段级权限待确认 | **C** | 纯后台配置；客户端提交字段已正确，无需改动 |
| P1-4 | 本地数据丢失（5 处） | **A** | 全本地，可立刻开工；其中删除连带存档一条需产品先决策 |
| P1-5 | 崩溃与界面锁死（4 处） | **A** | 全本地，可立刻开工，是本次性价比最高的一组 |
| P2-1 | 登录凭据明文持久化 | **A（加密落盘）＋C（token 有效期）** | 加密落盘可独立做；缩短有效期/吊销属服务端 |
| P2-2 | 服务端无限速与审计 | **C** | 客户端内存限流保留即可，不作为防线 |
| P2-3 | 昵称查邮箱批量枚举 | **C** | 服务端按 IP+账号限流；客户端 60s 限制保留 |
| P2-4 | 头像/截图缺服务端校验 | **C** | 服务端校验魔数、尺寸、配额 |
| P2-5 | OpenList 本地 admin/admin | **A ｜需排在 P0-6 之后** | 本地随机密码会被远程下发的 `data.zip` 覆盖，先做等于白做 |
| P2-6 | 解压与计算稳定性（4 处） | **A** | 全本地；其中存档扫描异步化成本较高，可拆出 |
| P3 | 日志脱敏 / 错误处理 / UI 细节 | **A** | 可随时插空做 |

**统计**：A 类 **7 条**、B 类 **6 条**、C 类 **5 条**。

---

## 二、B 类逐条拆解（服务端先 / 客户端后 / 单边后果）

### P0-4　全站 HTTPS　★ 最高顺序风险

| 项 | 内容 |
|---|---|
| 服务端先 | ① 为 `117.72.115.30:8090` 与更新服务 `:8000` 配置证书并启用 HTTPS；② 保留 80/8090 的 HTTP→HTTPS 重定向；③ 配置自动续期并加到期告警 |
| 客户端后 | `lib/core/pb_config.dart:7` 的 `_baseUrl` 字面量改 https；`lib/services/update/update_service.dart:24` 的 `_serverUrl` 同步改 https |
| **客户端先改的后果** | **严禁。** 服务端未配证书时，`https://117.72.115.30:8090` 直接 TLS 握手失败 → 登录、云端游戏库、远程安装、安装统计、OpenList 配置同步**全量失效**；`:8000` 同理导致更新检查永久报错。已发布客户端无法回滚（只能靠发新版），等于自断全部在线用户 |

- `pb_config.dart:7` 的影响面：`PBConfig.pb` / `PBConfig.baseUrl` 被 11 个文件共 57 处引用（`auth_service.dart` 33、`install_stats_service.dart` 6、`game_repository.dart` 5、`series_repository.dart` 3、`openlist_service.dart` 2、`game_detail_page.dart` 2、`game_model.dart` 2、`series_model.dart` 2，其余各 1）。
- 回归风险：自签证书会被 Dart `HttpClient` 拒绝（需可信 CA，不接受绕过校验的写法）；端口若从 8090 变更，需同步防火墙与重定向。

### P0-5　更新包完整性校验

| 项 | 内容 |
|---|---|
| 服务端先 | ① `version.json` 增加 `sha256`（建议同时给 `size`）字段并**先行上线**，保证新旧客户端都能拉到；② `downloadUrl` 固定为 HTTPS 且限制在同一域名/目录 |
| 客户端后 | `update_models.dart:2-19` 的 `VersionInfo` 增加可选 `sha256`/`size` 字段（`fromJson` 缺失时填 `null`，**不得**因缺失判为无效）；`update_service.dart` 在分片合并完成后（`_mergeChunks` 之后、`installUpdate` 之前）比对哈希，不匹配则删除产物并终止；`installUpdate()`（`:755-771`）入口增加一道"校验未通过不得 `Process.start`"的拦截 |
| **客户端先改的后果** | **严禁强校验。** 若服务端 `version.json` 尚无 hash 而客户端要求"必须有且必须匹配"，则**所有客户端永远无法更新**，且用户只看到"校验失败"，无法自救 |

- 过渡策略（必须实现）：`sha256 == null` → 跳过校验、正常安装；`sha256 != null` → 严格比对，失败即中止。这样服务端加字段的瞬间自动生效，无需二次发版。
- 调用点：`main.dart:508`、`widgets/settings_modal.dart:205`（检查）；`widgets/update_dialog.dart:80`（下载）、`:128`（安装）。
- 回归风险：多线程分片合并后字节序错误会导致误判（需在合并完成、文件流关闭后再算）；大文件（数百 MB）同步算 SHA-256 会卡 UI，需分块读流。

### P0-6　OpenList 配置包校验

| 项 | 内容 |
|---|---|
| 服务端先 | 在 `openlist_configs` 记录（当前硬编码 ID `tj9z6skib6207if`）中增加 `dataZipSha256` 字段并填入真实哈希；开启记录变更审计 |
| 客户端后 | `openlist_service.dart:124-155`：取 `dataZipSha256`；在 `_downloadZipWithFullDiagnostics()` 成功后、`_verifyZipFileSignature()` 之后追加哈希比对；不匹配则不解压、不启动，回退本地缓存并告警 |
| **客户端先改的后果** | **严禁强校验。** 字段缺失即拒绝 → `data.zip` 永不解压 → `_needsDataExtraction()` 恒为真 → OpenList **永不启动**，远程安装/网盘播放全线挂掉 |

- 现状已有 `_verifyZipFileSignature()`（`:158`）只验 ZIP 魔数，不构成完整性保护。
- 过渡策略：`dataZipSha256` 为空 → 维持现状；非空 → 严格校验。
- 回归风险：哈希计算在下载后同步执行（包体可能数十 MB），需避免阻塞；校验失败时的回退路径（用旧 `data/` 启动）必须仍然可用，否则等于把"配置可疑"升级为"功能不可用"。

### P0-2 / P0-3　superuser 凭据与找回密码（同一处代码，合并处理）

| 项 | 内容 |
|---|---|
| 服务端先（C 部分，**立刻做**） | ① **立即轮换** superuser 邮箱与密码，旧凭据视为已泄露；② 排查旧凭据期间的异常操作记录 |
| 服务端先（B 部分） | 提供自定义接口（PocketBase hook / 自定义路由），服务端持凭据执行，客户端只提交业务参数。需覆盖三个能力：<br>· `requestReset(email)` → 查 userId<br>· `resetPassword(userId, newPassword)` → 改密码<br>· `lookupEmailByName(name)` → 脱敏邮箱查询<br>服务端侧同时加真实限流（按 IP + 账号）与审计日志 |
| 客户端后 | `auth_service.dart` 删除 `:26-29`（`_e()`/`_p()` 及 `_suEmail`/`_suPwd`）、`:156-196`（`_getSuperuserToken` 及 `_suToken`/`_suTokenExpiry` 缓存）；把 `:244-316`（`_doRequestReset`）、`:363-436`（`_doResetPassword`）、`:532-576`（`_doLookupEmailByName`）三处的"取 superuser token + 直连 PB"改为调用新的自定义接口；**保留**上层的输入校验、防枚举文案、60s 客户端限流与 401 重试外壳不变 |
| **客户端先改的后果** | 找回密码 / 找回账号 **完全失效**（表现为"服务暂不可用"）。用户端无降级路径（PocketBase 自带的 `request-password-reset` 需要 SMTP，当前未启用） |

- 影响调用点：`pages/login/forgot_password_dialog.dart:128`（requestReset）、`:172`（resetPassword）、`:214`（lookupEmailByName）。三处对外方法签名保持不变，UI 层零改动。
- **必须明确的取舍**：移除 superuser 凭据与"找回密码仍可用"是**强绑定**的——服务端 hook 不上线，客户端就不能删凭据。二者之间没有中间态。若服务端改造排期不定，唯一可立刻执行的是**轮换凭据**（把泄露面从"永久有效"降到"已更换"），客户端代码保持不动。
- 回归风险：新接口的错误码/文案需与现有 `_translatePbError` 兼容，否则弹窗会出现原文英文错误；`RequestResetResult.token` 字段当前复用为 userId，新接口返回结构变化会影响 `forgot_password_dialog.dart:172` 的传参。

### P0-1　`games` 集合写权限

| 项 | 内容 |
|---|---|
| 服务端先 | ① 收紧 `games` 的 updateRule 与字段级权限，`downloadUrl`/`status`/`title`/`coverUrl`/`installCount` 仅管理员可写；② `installCount` 改为服务端 hook 自增；③ 截图投稿改走独立待审集合；④ 开审计与告警 |
| 客户端后 | ① `install_stats_service.dart:139-155` 的 `_incrementGameInstallCount()` 不再由客户端读-改-写（改为只建 `install_records`，计数由服务端 hook 完成）；② `game_detail_page.dart:454-478` 的截图直传改为投到待审集合（需服务端先给集合名与字段） |
| **客户端先改的后果** | 服务端未收紧时客户端停止自增 → `installCount` 停止增长（数字不动，不报错、不崩溃）；截图投稿入口需服务端先给目标集合，否则 404。属于**静默降级**，不是事故 |

- 截图上传失败路径已存在（`game_detail_page.dart:476-478` 只打日志），不会崩。
- 回归风险：`installCount` 改为服务端自增后，若 hook 未生效，详情页"安装人数"会永久停在 0（`fetchInstallCount` 返回 0 而非 null，UI 会显示 0 而不是隐藏）。**建议服务端先灰度一个游戏验证计数链路，客户端再撤**。

---

## 三、A 类逐条改动定位

### P1-1　filter 注入　（可立刻开工）

| 项 | 内容 |
|---|---|
| 位置 | `lib/repositories/game_repository.dart:52`、`:250`；`lib/services/install_stats_service.dart:183` |
| 现状 | `final filter = "title ~ '$searchQuery'";`（用户输入直接拼接）<br>`static String _escape(String value) => value.replaceAll("'", "\\'");`（只转义单引号） |
| 最小改动 | 新增一个统一的 filter 字符串转义函数：先转义反斜杠、再转义单引号，外加长度截断（建议 ≤64 字符）与空串短路；三处调用改为经该函数处理。`_escape` 的现有行为保持不变（它只服务 `userName`，不共用） |
| 影响调用点 | `game_repository.dart:52`（`getGameList`）、`:250`（`getGameCount`）；`install_stats_service.dart:127`（`_hasServerRecord`） |
| 回归风险 | 搜索含单引号/反斜杠的标题时行为变化（从"报错/无结果"变为"能搜到"）——属修复而非回归；截断长度若过短会影响长标题搜索 |

### P1-4　本地数据丢失　（可立刻开工，最高业务价值）

| 子项 | 位置 | 最小改动 | 影响调用点 | 回归风险 |
|---|---|---|---|---|
| a. 整包覆盖 | `game_data_format.dart:107-142` | 写入前若 `game.json` 已存在，先读出并保留 `play_time`/`sessions`/`first_opened_at`/`last_opened_at`/`collection_ids`/`play_status`/`mark`/`completed`，用新值覆盖其余字段后合并写出（沿用现有 `_atomicWriteFile`，不新增写路径） | 所有入库/重装路径（`extract_manager`、`batch_import_controller` 均经 `writeGameDir`） | 合并字段清单漏项会继续丢数据；`updated_at` 语义需明确为"本次写入时间" |
| b. 加载失败即清空 | `collection_service.dart:157-162` | catch 分支改为：不清空 `_collections`、不调 `_ensurePresetCollections()`（即不触发 `_save()` 覆写），仅置 `_loaded = true` 并暴露一个错误标志供 UI 提示 | `load()` 由启动流程调用；`byId`/`create`/`delete` 依赖 `_collections` | 用户会看到空收藏夹但磁盘数据仍在（正确的降级）；需确认上层不依赖"load 后必有两条预设" |
| c. 并发写同一 tmp | `collection_service.dart:235-255` | 临时文件名加唯一后缀（进程内自增或时间戳）；并用一个 `Future` 写队列把 `_save()` 串行化（与 `game_data_format.dart:149-165` 现成的 `_writeQueues` 同款写法） | `create`/`rename`/`recolor`/`delete`/`_ensurePresetCollections` 全部经 `_save()` | 串行化后写盘顺序变化；rename 的原子性依赖同分区，需保持 tmp 与目标同目录 |
| d. 迁移不校验即删 | `storage/migration_orchestrator.dart:164-170` | 该分支改为先比对新旧目录的**文件数与总字节数**（`:176-188` 已有现成的 `_countFiles`/`_dirSizeBytes`），一致才置标志并删旧；不一致则保留旧目录、标记 failed 并告警，不置标志 | `_migrateUnit` 的三个迁移单元（game_configs / user_themes / user_backgrounds） | 大目录算总字节会变慢；旧目录保留会占空间（可接受，优于误删） |
| e. 删游戏连带删存档 | `local_game_registry.dart:1194-1208` | **需产品先决策**。若为有意设计：删除确认弹窗增加"将同时删除 N 份存档备份"文案与独立勾选项；若为无意：删除前把 `Games/{safeName}/saves` 移出到应用级回收目录再删本体 | 库页删除入口、`save_backup_service.dart:82-85`（存档目录位于 metaDataDir 之内） | 改动删除流程属高风险；若移出需处理同名冲突与磁盘占用 |

### P1-5　崩溃与界面锁死　（可立刻开工，性价比最高）

| 子项 | 位置 | 最小改动 | 影响调用点 | 回归风险 |
|---|---|---|---|---|
| a. 过滤态拖拽必崩 | `library_page.dart:1096` | 循环上界由 `_games.length` 改为 `_cardKeys.length`（`_cardKeys` 在 `_buildGameGrid` 中按 `filteredGames.length` 维护，`:2183-2188`）。这样 `_cachedCardRects` 的键与实际渲染的卡片一一对应 | `_recacheCardRects()` 被 `_onScrollChanged`(`:1082`)、拖拽启动、自动滚动回调调用；下游 `_calculateInsertOffsets`(`:1390-1409`) 与 `_updateHoverIndex` 消费 `_cachedCardRects` | 索引语义从"全量索引"变为"过滤后索引"，与 `_endDrag` 里 `_filteredAndSortedGames[_originalIndex!]`(`:1426`) 的语义**一致**（原本就是混用的），属对齐而非改变。仍需重点回归：过滤态下拖拽排序落位是否正确（A18 混用问题不在本次范围，不展开） |
| b. 取消后遮罩锁死 | `extract_manager.dart:2005` ＋ `join/join_controller.dart:303-309` | 方案一（最小）：`cancel()` 末尾改为发出 `ExtractStatus.failed`，并置一条"已取消"的错误文案，让 `join_controller` 既有的 failed 分支自然收敛遮罩。<br>方案二（语义更准）：给 `ExtractStatus` 枚举（`extract_manager.dart:13-18`）增加 `cancelled`，`cancel()` 发该状态，`join_controller:304` 的条件里并入 `cancelled`（置 `_isProgressFailed = true`） | `extract_manager.dart:2005` 的 `_emitStatus`；监听方 `join_controller.dart:296-299`；`download_core.dart:764-768`、`global_install_center.dart:430/447/719`、`global_task_manager.dart:111-112` 均按 `failed`/`completed`/`idle` 分支判断 | **选方案二需确认**：新增枚举值后 `download_core`/`global_install_center`/`global_task_manager` 的分支是否会把 `cancelled` 误判为 "idle=空闲可用"（`global_task_manager:111-112` 把 `idle` 当可复用状态）。**推荐方案一**，改动面最小、不引入新枚举值 |
| c. Magpie 失败弹窗不可关闭 | `widgets/game_detail_dialog.dart:441-448` | 为 `else if (MagpieService.instance.fallbackOnFail)` 补一个 `else` 分支：复位 `_isLaunching = false`（同时 `_launchProgress = 0`），并给出失败提示 | `_isLaunching` 控制 `:1437` 的 `_buildLoadingOverlay()`（`Positioned.fill`，盖住关闭按钮） | 复位后遮罩消失，用户可关闭弹窗；需确认 `mounted` 判断与后续 `setState` 不冲突 |
| d. 删批量任务删用户原图 | `batch_import_controller.dart:636-650`、`:1472-1486` | 删除前判断 `coverFilePath` 是否位于应用自己的缓存/临时目录内（`PathHelper` 已有 portableTmpDir 等路径），**不在应用目录内则一律不删**。根因 `join_controller.dart:334-347` 的 `pickCover()` 保存的是用户原图绝对路径——本次**不重构 pickCover**（不在最小改动范围），只加路径归属判断 | `_cleanupSingleGameCache()` 被删除单个任务调用；`_cleanupAllCache()` 被 `clearAll` 与 `dispose()`(`:1492`) 调用 | 应用缓存目录内产生的临时封面将不再被清理 → 磁盘缓慢增长（可接受，优于删用户文件）；需确保判断用的是规范化路径（大小写、分隔符） |

### P2-1　凭据明文持久化（客户端部分）

| 项 | 内容 |
|---|---|
| 位置 | `lib/modules/auth/auth_service.dart:941-955`（`_saveAuthState` 写 SharedPreferences）；`:930-939` 恢复；便携路径 `core/path_helper.dart:60` → `{exeDir}/data/prefs/shared_preferences.json` |
| 最小改动 | 落盘前对 token（及 userId/email）做本地加密后再写入，读取时解密。密钥用 Windows DPAPI（或等价的机器/用户态绑定手段）派生。优先只加密 `_keyToken` 与 `_keyUserEmail`，其余字段保持明文以便兼容 |
| 影响调用点 | `_saveAuthState`、`_restoreAuthState`（`:930`）、登出清理、`user_cache_service.dart` |
| 回归风险 | **便携版整目录拷贝到另一台机器后登录态会失效**（密钥与机器绑定）——这正是本条要的效果，但需明确告知用户；升级路径上要能兼容已存在的明文 token（解密失败则按未登录处理，不能崩） |

> 注意：若改为系统凭据存储（Credential Manager），便携版"拷目录即迁移"的体验会被打破，且 `main.dart:303` 的 `PortableSharedPreferencesStore` 重定向逻辑需一并调整。**建议本次只做本地加密，不换存储介质。**

### P2-5　OpenList 本地 admin/admin　（**必须排在 P0-6 之后**）

| 项 | 内容 |
|---|---|
| 位置 | `lib/services/openlist_service.dart:1054-1060`（`_login()` 的凭据候选列表第二组硬编码 `admin/admin`）；`_readCredentialsFromConfig()` 为首选凭据来源 |
| 最小改动 | 首次启动且配置文件中无有效凭据时，随机生成本地管理员密码并写回本地 config（即 `_readCredentialsFromConfig()` 读取的那个 config 文件），不再依赖硬编码兜底 |
| **顺序依赖** | `data/` 目录由远程下发的 `data.zip` 解压覆盖（`:164-180`）。**若 P0-6 的校验与 P2-5 的本地密码未同时就位，下一次服务端推包就会把本地随机密码覆盖回 admin/admin**，本条等于白做。因此本条必须排在 P0-6 客户端改造之后，或至少在服务端承诺不再推送含凭据的 config 之后 |
| 影响调用点 | `_login()`（`:1051-1065`）、`_readCredentialsFromConfig()`、`_syncConfig()` 的解压覆盖逻辑 |
| 回归风险 | 本地 config 若被服务端下发包覆盖，客户端会登录失败 → OpenList 不可用。需明确"本地凭据优先级高于下发包"的冲突策略 |

### P2-6　解压与计算稳定性

| 子项 | 位置 | 最小改动 | 回归风险 |
|---|---|---|---|
| FFI 失败同步拉 PowerShell | `foreground_window_service.dart:127-136` | 把 `Process.runSync` 改为异步 `Process.run`；并加一个"PowerShell 回退最近一次触发时间"的节流（如 60s 内最多一次），期间直接返回 null | 前台检测的精度下降（提权进程路径可能短暂取不到）；该值被 500ms 定时器驱动，改异步后需防止回调乱序 |
| 存档扫描全同步遍历 | `local_game_registry.dart:2889-2927` → `save_scanner.dart:340-394, 615-628` | 把整段扫描移入 `compute`/Isolate，返回结构化结果 | 改动面较大，跨 isolate 需可序列化；建议**单独排期**，不与本次其他改动混在一起 |
| 时长 `clamp(0, 4)` | `local_game_registry.dart:2244-2251` | 上界由 `_monitorIntervalSec * 2` 放宽到一个更大的上限（如单次最多补 5 分钟），并区分"定时器被挤压"与"真实挂起" | 放开上界后，系统休眠再唤醒可能一次性补计大量时长。需配合非前台判定，否则时长反而变虚高 |
| 移动硬盘未就绪被移出库 | `local_game_registry.dart:498-513` | catch 分支不再加入 `staleKeys`（`exists()` 抛异常 ≠ 路径不存在）；只对"确认不存在"与"缺 `.ctgame` 文件"两种情况清理 | 真·网络驱动器离线时条目会长期留在库中，启动时无法访问——需 UI 有"路径不可用"标识，否则用户会看到打不开的游戏 |

### P3　日志脱敏与错误处理　（随时可插空）

| 项 | 位置 | 最小改动 |
|---|---|---|
| 解压密码写日志 | `services/extract_manager.dart:1059-1063` | 该行改为只输出"有密码/无密码"，不输出密码本身 |
| 完整邮箱写日志 | `modules/auth/auth_service.dart:67`、`:651`（及同类输出点） | 统一改为脱敏（保留首字符与域名） |
| FlutterError.onError 被覆盖 | `main.dart:364` 覆盖 `app_log_helper.dart:137` | 合并两处处理：先调用原有 `onError`，再走框架默认 present |
| UI 细节 | `library_page.dart:702-706`（搜索无防抖）、`:1675-1677`（启动保护提前释放）、`settings_modal.dart:2658`（`endsWith('Magpie.exe')` 大小写敏感） | 分别加防抖、延后释放标志位、改大小写不敏感比较 |

---

## 四、依赖关系与重排后的执行顺序

用户原始六步的最大问题是：**把 6 条 B/C 类排在第一步，而它们几乎全部依赖尚未动工的服务端**，客户端团队在等待期无事可做。重排后如下。

### 阶段 0｜立刻，零代码（服务端/运维）

1. **轮换 PocketBase superuser 邮箱与密码**（P0-2 的 C 部分）。
2. 排查旧凭据期间的异常操作记录。

> 这一步不需要任何代码改动，也不需要与客户端联调，**今天就该做完**。它把"永久有效的泄露"降级为"已更换"，是整个方案里唯一能立刻止损的动作。

### 阶段 1｜可立刻开工（纯客户端，零服务端依赖）

| 优先级 | 条目 | 内容 | 说明 |
|---|---|---|---|
| P0 | **P1-5** | 4 处崩溃与锁死（a/b/c/d） | 用户高频命中、可稳定复现，修复后立即可验证 |
| P0 | **P1-4** | 5 处本地数据丢失（a/b/c/d；e 待产品决策） | 本地工具的立身之本，属于"修了就立刻少一批差评" |
| P1 | **P1-1** | filter 转义 | 改动小，可与上两项同批提测 |
| P2 | **P3** | 日志脱敏 + FlutterError 合并 + 3 处 UI 细节 | 插空做，不单独占排期 |

> 这一阶段**完全不依赖服务端**，可以一口气做到提测。建议作为一个版本先发（本地修复版），不必等云端整改。

### 阶段 2｜客户端可独立做，但排在阶段 1 之后

- **P2-6** 稳定性 4 项（其中"存档扫描异步化"建议单独排期，成本显著高于其余三项）
- **P2-1（客户端部分）** 凭据本地加密

### 阶段 3｜B 类（等服务端，严格按顺序）

| 顺序 | 服务端动作 | 客户端动作 | 能否并行准备 |
|---|---|---|---|
| ① | — | — | **可以**：P0-5/P0-6 的客户端代码可按"字段缺失即跳过"先行写完并合入，此时行为与现状完全一致，**零风险**，服务端一加字段即自动生效 |
| ② | P0-5：`version.json` 增加 `sha256` | （已就绪，自动生效） | — |
| ③ | P0-6：`openlist_configs` 增加 `dataZipSha256` | （已就绪，自动生效） | — |
| ④ | P0-4：双端口 HTTPS + 重定向 + 自动续期 | P0-4：改两处 URL 常量 | 客户端改动是 2 行，但要**卡在服务端验收通过后**才合入 |
| ⑤ | P0-2/P0-3：轮换凭据 + 上线三个自定义接口（含限流与审计） | P0-2/P0-3：删 superuser 凭据，三个方法切到新接口 | 客户端可先按新接口契约写好，用开关切换，等服务端联调通过再翻开关 |
| ⑥ | P0-1：收紧 `games` 写权限 + `installCount` hook 自增 + 截图待审集合 | P0-1：撤客户端自增、截图改投待审集合 | 需服务端先给集合名与字段定义 |
| ⑦ | — | **P2-5**：OpenList 本地随机密码 | 必须排在 ③ 之后，否则会被下发包覆盖 |

### 阶段 4｜C 类配置（服务端/运维，不占客户端排期）

- P1-2：`install_records` 建 `UNIQUE(gameId, userId)` 唯一索引；加 `userId` 字段；`gameTitle` 由服务端回填（客户端改传 `userId` 需在此之后）
- P1-3：`users` 集合字段级 create/update 权限，仅开放 `name`/`description`/`avatar`
- P2-2：登录/注册/找回密码/安装上报/投稿分别加服务端限流；密码重置、`games` 变更、`installCount` 异常增长开审计告警
- P2-3：`lookupEmailByName` 对应接口按 IP + 账号维度限流，配额严于普通接口
- P2-4：头像与截图的服务端文件类型/尺寸/魔数校验，单账号配额与投稿频率

### 关键顺序依赖一览

```
轮换凭据(阶段0) ─────────────────────────────┐
                                             ▼
P1-5/P1-4/P1-1/P3 (阶段1，零依赖，立刻开工)   P0-2/P0-3 hook 上线 ─→ 客户端删 superuser
        │                                                            （无中间态，不可拆）
        ▼
P2-6 / P2-1客户端 (阶段2)
        │
        ▼
P0-5 hash 字段 ──→ 客户端校验自动生效 ──→ P2-5 本地密码(必须在 P0-6 之后)
P0-6 hash 字段 ──→ 客户端校验自动生效
P0-4 HTTPS 就绪 ──→ 客户端改 2 处 URL（严禁提前）
P0-1 权限收紧 ──→ 客户端撤直写（提前只会导致静默降级）
```

---

## 五、回归风险清单与最小验证方式

| 改动项 | 可能影响的现有功能 | 最小验证方式 |
|---|---|---|
| P1-5a 拖拽越界 | 库页拖拽排序、拖拽归类、过滤/搜索态交互 | 编译通过 → 启动 → 库页进入某收藏夹 → 长按卡片拖拽 → 排序落位正确、无红屏；再在全量视图重复一次 |
| P1-5b 取消遮罩 | 单文件导入、压缩包含取消 | 编译 → 导入任意压缩包 → 进度浮层出现后点「取消」→ 遮罩 1s 内消失、添加页可继续操作 |
| P1-5c Magpie 失败 | 超分启动、普通启动 | 编译 → 关闭「失败回退」→ 用无效路径触发 Magpie 启动失败 → 弹窗可关闭、进度条复位 |
| P1-5d 删原图 | 批量入库、取消、clearAll、退出 | 编译 → 在单游戏表单选一张**桌面上的**图片作封面 → 加入批量列表 → 点「×」移除 → 确认桌面原图仍在 |
| P1-4a 整包覆盖 | 重复入库、批量入库、覆盖安装 | 编译 → 入库一款游戏 → 记录游玩时长 → 再次入库同一款 → 确认时长/收藏夹/评分保留 |
| P1-4b 收藏夹加载 | 启动、收藏夹增删改、删除游戏后的引用清理 | 编译 → 手工把 `collections.json` 改坏 → 启动 → 确认**不再**被清空覆写（先备份原文件） |
| P1-4c 并发写 tmp | 收藏夹全部写操作 | 编译 → 快速连续新建/重命名/删除多个收藏夹 → 重启确认数据完整 |
| P1-4d 迁移删旧 | 首次启动的便携化迁移 | 编译 → 在安装目录预置一个含无关文件的 `game_configs` → 首次启动 → 确认 C 盘旧数据未被删 |
| P1-4e 删除连带存档 | 库页删除游戏、存档备份与恢复 | 编译 → 对有存档备份的游戏执行删除 → 确认弹窗文案与勾选行为符合产品决策 |
| P1-1 filter 转义 | 探索页搜索、游戏总数、安装统计查重 | 编译 → 搜索含 `'` 与 `\` 的标题 → 不报错、结果正确；正常中文/英文搜索结果不变 |
| P2-1 凭据加密 | 登录、重启恢复登录态、登出、便携版整目录迁移 | 编译 → 登录 → 重启确认仍登录 → 换一台机器拷整个目录 → 确认按预期需要重新登录且**不崩溃** |
| P2-6 FFI 回退异步 | 精准计时模式、游玩时长统计 | 编译 → 切到以提升权限运行的窗口 → 确认 UI 不冻结、时长仍在累加 |
| P2-6 clamp 放宽 | 游玩时长统计、阅历日历 | 编译 → 正常游玩 10 分钟 → 确认时长与实际相符（不虚高、不少计） |
| P2-6 移动硬盘条目 | 库页刷新、启动扫描 | 编译 → 把游戏放在移动硬盘 → 拔盘启动 → 确认游戏仍在库中（标记不可用）而非消失 |
| P0-4 切 HTTPS | **全部云端功能** | 服务端验收后 → 编译 → 登录 / 探索页拉列表 / 远程安装 / 检查更新，逐项冒烟 |
| P0-5 哈希校验 | 自动更新全流程 | 用正确包验证"能更新"；手工篡改一个字节验证"拒绝安装且不残留 exe"；删掉 `sha256` 字段验证"降级放行仍能更新" |
| P0-6 哈希校验 | OpenList 启动、远程安装、网盘播放 | 正确包验证"能启动"；篡改包验证"不解压、不启动、回退本地缓存"；字段缺失验证"行为与现状一致" |
| P0-2/P0-3 去凭据 | 找回密码、昵称查邮箱、登录、注册 | 逐条冒烟：找回密码全流程、按昵称查邮箱、正常登录注册；并验证超 user token 相关日志已消失 |
| P0-1 撤直写 | 安装人数显示、截图投稿、远程安装 | 安装一款云端游戏 → 确认 `installCount` 递增；上传截图 → 确认进入待审集合而非直接生效 |
| P2-5 本地随机密码 | OpenList 登录、远程安装、网盘播放 | 首次启动后确认本地 config 中已是随机密码；再触发一次服务端配置下发，确认本地密码**未被覆盖** |
| P3 日志脱敏 | 无功能影响 | 编译 → 解压一个带密码的包 → 检查日志文件不含明文密码 |

**通用前置**：每一批次合入后至少 `flutter analyze` + `flutter build windows` 通过，再按上表冒烟。

---

## 六、明确不处理项（本次不做，后续评审无需重复提出）

| 项 | 位置 | 确认结论 |
|---|---|---|
| TouchGal API Token | `lib/services/metadata_fetcher.dart:33` | **不改。** 开发者本人申请、官方允许公开 |
| ymgal client_id / client_secret | `lib/packages/luna_metadata_sdk/lib/services/metadata_services.dart:1448-1449` | **不改。** 同上 |
| 默认解压密码 `_defaultPassword` | `lib/services/extract_manager.dart:42` | **不改。** 功能常量，仅做日志脱敏（P3） |
| OpenList `_configRecordId` | `lib/services/openlist_service.dart:9` | **不改。** 普通资源标识，无安全影响 |
| 后端地址 / 更新服务地址的字面量本身 | `pb_config.dart:7`、`update_service.dart:24` | **保留硬编码。** 问题在于传输未加密与缺少校验（P0-4/P0-5），不在地址写死 |

**另需确认（不影响开工，但需项目负责人答复）**：
1. `local_game_registry.dart:1194-1208` 删除游戏连带删除存档备份，是否为有意设计？
2. `runtime/tools/7z.exe` 版本是否 ≥ 21.07（关系 zip slip 漏洞面，与路径穿越叠加可放大）；`UnRAR.exe`、`bz.exe`、`openlist.exe` 版本亦需确认。
3. P0-2/P0-3 的服务端 hook 预计排期 —— 这决定了客户端去凭据动作的最早可执行时间。

---

## 七、给项目负责人的服务端待办清单（可直接转交）

| # | 事项 | 对应条目 | 阻塞谁 |
|---|---|---|---|
| 1 | **轮换 superuser 邮箱与密码**（今天就做） | P0-2 | 不阻塞任何人，但它是止损前提 |
| 2 | 排查旧凭据期间的异常操作记录 | P0-2 | — |
| 3 | 收紧 `games` updateRule 与字段级权限；`installCount` 改 hook 自增；建截图待审集合（需告知客户端集合名与字段） | P0-1 | 阻塞 P0-1 客户端改造 |
| 4 | 上线三个自定义接口：`requestReset` / `resetPassword` / `lookupEmailByName`，服务端持凭据执行 + 真实限流 + 审计 | P0-2 / P0-3 | 阻塞客户端删除 superuser 凭据 |
| 5 | `:8090` 与 `:8000` 配置 HTTPS 证书 + 保留 HTTP 重定向 + 自动续期告警 | P0-4 | 阻塞客户端切 https（**严禁提前**） |
| 6 | `version.json` 增加 `sha256`（建议附 `size`）字段 | P0-5 | 客户端可先写好，字段一上线即生效 |
| 7 | `openlist_configs` 记录增加 `dataZipSha256` 字段并填值；开启记录变更审计 | P0-6 | 同上 |
| 8 | `install_records` 建 `UNIQUE(gameId, userId)` + 加 `userId` 字段 + 服务端回填 `gameTitle` | P1-2 | 阻塞客户端改传 userId（不阻断发布） |
| 9 | `users` 集合字段级 create/update 权限，仅开放 `name`/`description`/`avatar` | P1-3 | 不阻塞客户端 |
| 10 | 登录/注册/找回密码/安装上报/投稿分别加服务端限流；关键操作开审计告警 | P2-2 / P2-3 | 不阻塞客户端 |
| 11 | 头像与截图的服务端文件类型/尺寸/魔数校验 + 单账号配额 | P2-4 | 不阻塞客户端 |
