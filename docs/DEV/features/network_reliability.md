# 网络链路韧性（Network Reliability）

> 状态：**P0 已修复 + P2 差网络自适应分片已完成（代码），待真机验证**（2026-09-08 / 2026-09-18）
> 相关代码：`lib/services/download_core.dart`、`lib/services/network_status_service.dart`、
> `lib/services/global_install_center.dart`、`lib/pages/game_detail_page.dart`
> 测试：`test/services/download_core_resilience_test.dart`

---

## 1. 问题现象（用户反馈）

1. 探索页游戏**云端安装经常失败**，但设备网络连接正常稳定；
2. 软件在**网络正常时莫名断联**。

审计结论：这是**两组独立根因**，都不是用户网络环境问题。

---

## 2. 云端安装链路

```
探索页 / 详情页
   ↓ game.downloadUrl（这是「游戏路径」，如 /游戏名/xxx.rar，不是 HTTP URL）
OpenListService.getGameDownloadUrl(gamePath)
   ↓ 本地 OpenList 进程 127.0.0.1:5244 → 云盘 raw_url 签名直链（会过期）
DownloadCore.start(url)
   ↓ HEAD 探大小 → 4 分片并行 Range 下载 → Isolate 合并 → ExtractManager 解压
```

⚠️ `game.downloadUrl` 字段存的是**路径**不是 URL，必须经 `getGameDownloadUrl` 解析后才能下载。

---

## 3. 根因与修复

### P0-1 分片重试从 0 开始（无断点续传）

- **旧**：`_downloadChunk` 重试前 `await file.delete()`，再请求完整 `start-end` 区间。
  5GB 游戏 = 1.25GB/分片，90% 处抖动即丢弃 ~1.1GB 重下，3 次重试几乎必败。
- **新**：保留临时文件，以 `已落盘字节数` 为起点请求 `Range: start+已收-end`，
  `IOSink` 用 `FileMode.append` 追加写入。跨重试、跨任务（同名临时文件）均可续传。

### P0-2 分片静默截断被误判为完成

- **旧**：`await for` 流正常结束就 `completed = true`，**从不校验字节数**。
  服务器提前断流（Content-Length 说满、实际少发）不抛异常 → 合并后大小不符 →
  整次安装失败且流量全部浪费。
- **新**：以 `File.length()` 为准校验，≠ 分片大小即抛错进入续传重试。
  另加：响应 `content-length` 与请求区间不符时直接判失败（防服务器忽略 Range 返回全量）。

### P0-3 HEAD 零重试

- **旧**：`dio.head(url)` 单次失败即整次安装失败（下载还没开始就结束）。
- **新**：`_headWithRetry` 4 次退避重试（500ms/1000ms/1500ms），并在 401/403/404/416 时刷新直链。

### P0-4 云盘签名直链过期后重试必败

- **旧**：直链仅在任务开始时解析一次，重试永远复用同一个已失效 URL。
- **新**：`DownloadCore.start` 接受可选 `urlResolver`；`_refreshUrlIfNeeded` 在
  `DioExceptionType.badResponse` 且状态码 ∈ {401, 403, 404, 416} 时重新解析直链。
  透传路径：`game_detail_page.dart:665` → `InstallTask.urlResolver`（`global_install_center.dart:50,63,374`）
  → `DownloadCore.start`。

### P0-5 / P1 `Future.wait` 提前抛错 + 全局误删临时文件

- **旧**：`Future.wait` 默认 `eagerError: true`，一个分片失败立刻抛出，其余分片仍在后台写盘；
  同时 `_handleError` → `_cleanupTempFiles` **递归扫描整个下载目录**删除所有
  `.part_*`/`.chunk_*`，而 `GlobalTaskManager` 与 `GlobalInstallCenter` 可并存 → 误删他人分片。
- **新**：`eagerError: false` 聚合错误，失败时先 cancel 同批其余分片再统一抛；
  `_cleanupTempFiles` 只删**本任务**的分片。

### P0-6 网络状态误判离线（「莫名断联」）

- **旧**：探针 3s 超时 + 连续 2 次失败即判离线 + **只探单台小型 VPS**
  （`http://117.72.115.30:8090/api/health`）。6~8 秒的服务慢响应即被判为设备离线。
  而 `discover_page.dart:733`、`auth_service.dart:780,812` 都 gate 在 `isOnline` 上
  → 探索页拒绝加载、登录被拒。
- **新**：超时 3s→6s、阈值 2→3、**多点探测**（服务不通时再探
  `https://www.gstatic.com/generate_204` / `https://www.baidu.com/`，只有服务与公网都不通
  才判离线）、改用复用的 `http.Client`（旧实现每次 `http.get` 都新建+关闭 Client）。

### P1 其他

- 单流下载（服务器不支持 Range）此前**零重试** → 加 3 次退避重试；
- 重试上限 3→6，退避 1s→2s→4s→8s→15s（上限）；
- DIO `connectTimeout`/`sendTimeout` 20s→30s（云盘握手偏慢）；
- 失败时**保留**分片以便重试续传（新增 `_resumableBytes` 诊断输出）。

### P2 差网络自适应分片（2026-09-18，针对 4G/抖动网络下大文件仍失败、慢）

- **现象**：P0 落地后用户在 4G/弱网下 >GB 级下载仍**经常失败、速度慢**，基本无法下载。
- **根因 A**：固定 4 分片、每片 = `totalSize/4`（5GB→1.25GB/片），任一失败即 cancel 同批其余
  → 弱网下「多个连接同时保持稳定」的门槛高，失败面随并发放大，且一抖要恢复整片；
- **根因 B**：分片粒度过大 → 断点续传的恢复成本高；
- **改动**（`_DownloadTier{high,mid,low}` + `_probeTier` + 并发窗口 worker 池）：
  - 下载前 Range 取前 4MB 探测实际吞吐分档（超时/失败回落最稳的低档）；
  - 分片改按档位**固定大小**切分：好网 64MB×并发4 / 中 32MB×3 / 差 16MB×2 → 抖动只影响
    单个小块（恢复成本从 1.25GB 降到 ≤64MB），弱网降并发减小失败面；
  - 单分片失败**不再取消同批其余分片**（改为记录错误、保留已完成分片供续传），
    消除旧 `eagerError + cancel 同批` 的一次失败杀全队。
- **兼容性**：`_downloadChunk` 已有护栏——旧 4 分片临时文件长度 > 新分片大小会自动删除重下，
  跨策略升级续传不会串数据。
- **续修复（同日真机实测仍是问题：「下载卡在中途」）**：真正的卡因是——差网络连接**半开**
  （服务器停发但 TCP 未断）时，Dio `receiveTimeout=300s` 要等 **5 分钟**才重连单分片，表现就是
  「卡在中途不动」；且分片重试上限 6 对弱网太少。已把 `receiveTimeout` 300s→**45s**（45s 无新
  数据即判定半开 → 走分片续传重连），分片重试上限 6→**15**（弱网靠小步续传把大文件慢慢啃完；
  好网一次成功无感）。—— 好网保持高并发大分片（快），坏网小分片 + 快速重连（稳）。
- **续修复 2（同日真机实测「downloads 出现 112 个分片 + 卡死不动」）**：
  - **根因 A（112 片）**：差网 low 档 16MB/片在大文件下爆出上百片、`.part_*.tmp` 暴增。
    加**分片数 clamp**（`kMaxChunks=32 / kMinChunkSize=8MB`，[download_core.dart:539](file:///d:/CTLIB/lib/services/download_core.dart#L539)）：
    超 32 片则按需放大分片尺寸，~1.8GB 最多 32 片 ×56MB；断点续传仍逐字节可用。
  - **根因 B（卡死不动）**：Dio `receiveTimeout` **只作用于连接/响应头阶段，不约束
    `ResponseBody.stream` 的 body 逐块读取** → 弱网半开时 body 被卡住、`await for` 永久挂起、
    `.tmp` 停止增长。`_downloadChunk`（[download_core.dart:643](file:///d:/CTLIB/lib/services/download_core.dart#L643)）
    **新增应用层无数据看门狗**：`Timer.periodic(5s)` 监测无新字节时长，>45s 判定半开 →
    `chunk.cancelToken.cancel()` 记入 `watchdogHit`，catch 时区分「看门狗取消 → 续传重试」vs
    「用户取消 → 透传」，`finally { watchdog.cancel(); }`。这才是真机「卡死不动」的直接机理。

---

## 4. 测试

`test/services/download_core_resilience_test.dart`（本地 `HttpServer` 注入故障，不发真实网络请求）：

| 用例 | 注入的故障 | 断言 |
|------|-----------|------|
| P0-1/P0-2 | 首次请求只发一半就关闭连接（只截断文件开头的首次请求，模拟一次短断流） | 最终大小精确等于 Content-Length；且出现「起点 > 0」的 Range 请求（证明是续传而非重下）。注：分片策略 2026-09-18 改为自适应档位后不再固定 4 分片，断言口径相应从「不在分片边界」改为「起点>0」 |
| P0-3 | 前 2 次 HEAD 返回 500 | 重试后 completed |
| P0-4 | 旧路径一律 403 | `urlResolver` 被调用，刷新后 completed |

⚠️ **测试编写注意**：**不要**调用 `TestWidgetsFlutterBinding.ensureInitialized()` ——
它会安装 `HttpOverrides` 使所有 `HttpClient` 请求直接返回 400。
本测试不需要 widget 环境；但解压链路会读 `SharedPreferences`，
需在 `setUpAll` 里 `SharedPreferences.setMockInitialValues({})`（项目既有做法）。

---

## 5. 遗留与待办

| 优先级 | 事项 |
|--------|------|
| 🔴 P0 | `lib/big_picture/pages/big_picture_discover.dart:582` 把 `widget.game.downloadUrl`（**游戏路径**）直接当直链传给 `InstallTask`，**从未调用 `getGameDownloadUrl` 解析** → BPM 大屏模式探索页安装必然失败。需照搬 `game_detail_page.dart:612,645` 的解析逻辑（约 5 行）。**发现但未经用户批准，未改** |
| 🟠 P1 | 失败保留分片 = 放弃安装会残留临时文件，需「清除下载缓存」入口（本次未动 UI） |
| 🟠 P2 | 元数据 SDK 各数据源：8~20s 超时，**仅 429 有重试，网络异常无重试**（`metadata_base.dart:148 executeRateLimited`） |
| ⚪ | OpenList 空闲 10 分钟自动关闭（`openlist_service.dart:19`）。当前下载走云盘直链不受影响，但若未来改走本地代理会成为新的中断源 |

---

## 6. 真机验证清单

- [ ] 探索页安装一个大游戏（>3GB），中途**手动断开 WiFi 5 秒再恢复** → 应看到续传日志
      （`↻ 分片N 续传自 X/Y`）并最终安装成功，而不是失败
- [ ] 安装失败后**点重试** → 日志出现 `💾 保留已下载 X，重试时自动续传`，进度不归零
- [ ] 正常网络下观察 5~10 分钟：右下角/用户按钮的在线状态圆点**不再莫名变灰**
- [ ] 真正断网 → 应在约 20~30 秒内（6s × 3 次阈值 + 轮询间隔）判定离线，而非 6~8 秒
- [ ] 服务器宕机但设备联网 → 应保持在线（仅服务不可达）
- [ ] 大文件（>1.5GB）差网下 `downloads` 目录分片数应 **≤32**（此前 112 片的 clamp 已生效）
- [ ] 弱网半开时 → 分片 `.tmp` 停止增长 **≤45s** 内应出现 `⏹ 分片N 长时间无数据(>45s)，看门狗中断` 日志 →
      自动续传重连，进度继续推进而非永久卡死
