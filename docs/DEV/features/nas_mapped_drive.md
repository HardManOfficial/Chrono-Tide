# NAS 映射网络驱动器适配（2026-10-06）

> 状态：✅ 已落地（commit `ac348d6`）。单测在故障环境以 flutter_tester 离线探针 24/24 PASS 验证；`flutter test` 与映射盘真机走查待补。

## 1. 问题与根因

**现象**：用户把 NAS 映射为网络驱动器（如 `Z:`）当日常磁盘，批量/智能导入后
`game.json.directory_path` 变成 `\\?\UNC\192.168.5.11\share\...` 形态——
游戏无法启动、无法定位文件；盘符重映射后彻底失效。

**根因（唯一写入汇点）**：

```
writeGameDir → PathNormalizer.forStore(resolveSymlinks: true)
  → Directory.resolveSymbolicLinksSync()
```

Dart 在 Windows 上对映射网络驱动器，`resolveSymbolicLinksSync()` 返回
`\\?\UNC\host\share\...` **长路径前缀形态**。该前缀 Explorer / CreateProcess /
cmd / 快捷方式 / 游戏本体均不接受，历史代码原样落盘。
（`forCompare` 一直有剥前缀逻辑，所以排重从未坏过——坏的只是持久化形态与访问链。）

## 2. 设计口径（用户批准）

> 保存 UNC 真实路径，盘符仅做显示。访问时优先盘符，盘符失效自动切 UNC。
> 增加网络盘识别、连接校验、异常状态提醒。不自动修改用户存储的路径。
> 确保网络波动的稳定性处理。

**为什么 directory_path 存 UNC 而不是盘符形态**：身份 / 排重 / 移动判定都锚定
`directory_path`。盘符是会话级资源（重映射、换机、换字母），写盘符形态会在
盘符变化后产生「同库双条目」与路径漂移。UNC 是盘符无关的稳定锚。

**双形态落盘**（ADR-012 例外：纯新增可空字段 `?? ''`，不升 format_version）：

| 字段 | 内容 | 用途 |
|------|------|------|
| `directory_path` | UNC 真路径（无前缀）`\\host\share\...` | 身份/排重/移动判定/兜底访问 |
| `source_path`（新） | 用户原始盘符形态 `Z:\...`；无盘符形态时为空串 | 仅显示 + 优先访问 |

## 3. 写入端改动

| 文件 | 改动 |
|------|------|
| `lib/utils/path_normalizer.dart` | `forStore` 在 resolveSymlinks 后、`p.normalize` 前剥 `\\?\` / `\\?\UNC\` 前缀（`package:path` 对带前缀路径无法正确 normalize）。对无前缀路径恒等 |
| `lib/utils/network_path.dart` | `_driveUnc` 双通道：`WNetGetUniversalNameW` 离线可能失败 → 补 `WNetGetConnectionW`（查本地连接表，断连映射盘通常仍可解析）；新增 `driveLetterForUncShare(uncRoot)` 遍历 A-Z 反查当前映射同共享盘符 |
| `lib/services/game_data_format.dart` | `normalizeStoredDirectory(raw) → (UNC, 盘符形态)`；`writeGameDir` 落双形态；`_overwritableFields` 加 `source_path`（重新导入覆盖生效）；`GameJsonData.fromJson` 读时归一（剥历史前缀，**不回写**）、`source_path` 空不出键（老文件零 diff） |
| `lib/services/local_game_registry.dart` | `LibraryGame.sourcePath`；scan 合并镜像 game.json；`registerExtractionComplete(..., sourcePath:)`；`updateGameLocation` / `relinkGameLocation` 回写统一双形态；**自愈守卫**：网络盘目录跳过本地 `existsSync` 检查——离线时不再把 directory_path 顶掉（同时消除同步 IO 卡 UI） |
| `lib/pages/join/batch_import_controller.dart`、`lib/services/auto_import_pipeline.dart` | `registerExtractionComplete` 传 `sourcePath`（用户看到的原始路径） |

## 4. 访问端改动（新 `lib/utils/game_path_resolver.dart`）

解析链（唯一入口 `GamePathResolver.resolve(directoryPath:, sourcePath:)`）：

```
① source_path 可用 ──可用──→ ok（与用户习惯一致）
      ↓不可用
② WNetGetConnectionW 反查当前映射同共享的盘符 ──命中且可用──→ ok（重映射自动跟随）
      ↓
③ 存储值 UNC 直连 ──可用──→ uncFallback（显示仍优先盘符形态）
      ↓
④ 全部不可达 ──→ offline（明确提示，绝不静默写入/改写存储路径）
```

本地路径退化为「目录存在 = ok」，与既有本地语义完全一致。

**网络波动稳定性**：全部探测异步 `exists()` + 4s 超时；结果 8s TTL 缓存；
同卷根 30s 快速离线通道（批量场景防雪崩）；`SetErrorMode` 抑制系统「无磁盘」弹窗。

**接入点**（离线时给明确原因，不弹 exe 选择器 / 不弹启动管理器）：

| 场景 | 文件 |
|------|------|
| 启动游戏 | `game_launch_service.dart`（`lastResolveFailureReason`）、`main.dart`、`main_container.dart`、`library_page.dart`（双击）、`big_picture/big_picture_shell.dart` |
| 打开所在目录 | `game_detail_dialog.dart`（目录行显示盘符形态 + 实时状态文案）、BPM shell |
| 快捷方式批量创建 | `shortcut_service.dart`（离线条目跳过，快速离线通道兜底） |

## 5. 兼容性

- **老数据 `\\?\UNC\...`**：读时归一（fromJson 剥前缀），解析按同一逻辑走；
  **不回写存储值**（不自动改用户数据）。
- **老数据盘符形态 / 老数据无 source_path**：sourcePath 为空串，解析链从 ② 开始；
  下次重新导入（`_overwritableFields` 含 source_path）或用户改位置时自然补全双形态。
- **本地磁盘**：`forStore` 对无前缀路径恒等；resolver 对本地路径退化为原语义。
  已有导入功能零行为变化。

## 6. 验证

- **进程内 analyzer 探针**（14 改动文件）：`errors=0`；19 warnings / 3 infos
  逐条核对行号均在存量区域，零新增。
- **flutter_tester 离线探针**（`.workbuddy/probe_nas/`，24/24 PASS，因
  CreateFile failed 231 环境故障代替 `flutter test`）：
  - S1 前缀剥离 4 例（`\\?\UNC\` / `\\?\` / 无前缀恒等×2）
  - S2 存储双形态 5 例（UNC / 历史脏数据 / 本地 / 空）
  - S3 game.json 兼容 6 例（读时归一 / source_path 条件输出 / 老文件零 diff）
  - S4 resolver 9 例（offline / display 无畸形前缀 / 文案 / 缓存 identical；
    S4h 真实跑通 FFI 反查 → SMB 探测 → offline 全链）
- ⏳ `flutter test test/utils/nas_mapped_drive_test.dart` 待 C 盘恢复后补跑。
- ⏳ 真机走查（需真实 NAS 映射盘）：
  1. Z: 在线导入 → 详情窗目录行显示 `Z:\...`，game.json 内 `directory_path`
     为无前缀 UNC + `source_path` 为 `Z:\...`；
  2. 启动游戏 / 打开目录正常；
  3. 断开映射（或 NAS 关机）→ 启动给出「网络位置不可达」提示，不弹选择器、
     存储路径不变；NAS 恢复后重试成功；
  4. 把同一共享重映射为 Y: → 启动/打开目录自动跟随 Y:（② 反查生效）；
  5. 存量 `\\?\UNC\` 老数据游戏 → 详情窗显示无前缀路径，功能可用。

## 7. 已知边界

- `WNetGetUniversalNameW` / SMB 探测在远端彻底断网（非本机连接表可查）时
  依赖 4s 超时，批量场景由 30s 快速离线通道兜底。
- flutter_tester 直跑下 `Directory.exists()` 永不返回（引擎怪癖，见 skill
  flutter-analyze-without-subprocess 第六坑），探针依赖 resolver 自身 4s
  timeout 兜底——真机 `flutter test` 无此问题。


## 8. 打包修复（2026-10-06 追加）

`_uncFromConnection()` 原写法 `malloc<Utf16>(n)` 在 release AOT 下编译失败：
ffi 2.1.3 的 `Utf16` 只 `extends Opaque`，不是 `SizedNativeType`，
而 `AllocatorAlloc.call<T extends SizedNativeType>` 要求上界。
改为 `malloc<Uint16>(n).cast<Utf16>()`（与 `input_injector.dart:416`、
`win32_process_service.dart:330` 同款），`lpLength` 以 wchar 计，语义等价。

🔴 **验证教训**：本功能原先「进程内 analyzer errors=0」的结论**不足以放行 release** ——
该类 CFE 泛型上界错误 analyzer 不报。以后涉及 FFI 分配改动的验收要补一条
JIT 单文件对照（`dart.exe --packages=.dart_tool/package_config.json probe.dart`）。

## 9. 方案 B：盘符为主形态（2026-10-06 晚，真机反馈驱动）

### 9.1 真机反馈与日志实证（测试者 logs）

- 详情页目录仍显示 UNC（测试者看不到自己的 `Z:\...`）；
- 「突然变成离线状态」，而 Explorer/网络磁盘均稳定挂载；
- `game_launch_2026-10-06.log` 实证：**UNC 路径直接启动成功**（PID 正常）
  —— 证明 `CreateProcess` 接受 UNC 工作目录（报 "UNC paths are not
  supported" 的只是 cmd.exe），前一版「UNC 工作目录必然失败」的判断过重。

### 9.2 诊断（三项叠加）

| 级别 | 缺陷 | 位置 |
|------|------|------|
| P0-1 | `source_path` 恒为空：双形态判据用 `forCompare`（内部会把盘符归一成 UNC），盘符形态与 UNC 形态算出同一结果 → 被判「相同」→ 冗余 | game_data_format.dart 原 :330-333 |
| P0-2 | `_driveUnc` 把**失败结果（null）永久缓存**，同一文件 `_isRemoteDrive` 却明确「未挂载不缓存」→ 瞬时反查失败 = 本进程余生反查全 null → 候选②死掉 → 误判离线 | network_path.dart 原 :268-277 |
| P1 | 探测超时 4s（NAS 唤醒经常超）+ 30s 快速离线通道 + 8s 结果缓存三级放大「突然离线」 | game_path_resolver.dart |

### 9.3 方案 B 改动（用户批准口径：**与本地盘一致的体验**）

- **写入端**（game_data_format.dart `normalizeStoredDirectory`）：
  - 映射盘符导入 → `directory_path` = **用户盘符形态**（`Z:\...`），
    `source_path` = UNC 真路径兜底（盘符重映射/未挂载时用）；
  - UNC 导入 → directory = UNC，source = 空串（盘符形态由访问端动态反查，
    不落盘 —— 映射随时可变，落盘即过期）；
  - 本地路径分支与本地语义不变。身份/排重/同卷判定不受形态影响
    （`forCompare` 本就归一两种形态）。
- **访问端**（game_path_resolver.dart 重写）：
  - 探测顺序 = **盘符形态候选优先**（存储值/source/动态反查），全失败再
    UNC 候选，再对主存储值做一次 5s 短超时重试（防唤醒抖动误判），
    仍失败才 offline；
  - 盘符重映射防护：存储盘符当前指向的共享与备形态共享**明确不同**时
    UNC 优先（`canonicalizeVolume` 解析不出时不动顺序，未知≠重映射）；
  - 超时 4s→10s；快速离线通道 30s→15s；离线文案按「首次/缓存」区分；
  - 老 UNC 数据读端兼容：反查盘符成功即以盘符形态访问，不回写存储；
  - 纯 UNC 用户（从未有映射）→ ok 且不加噪音提示。
- **启动链**（local_game_registry.dart）：cmd /c start 回退通道在 UNC
  工作目录时不传 `workingDirectory`（cmd 拒绝 UNC cwd；Process.start 不受限）。
- **P0-2 修复**（network_path.dart）：`_driveUnc` 成功值永久缓存、失败值
  仅 5s TTL。
- **详情窗**（game_detail_dialog.dart）：目录状态非空时菜单新增
  「重新检测目录」= `GamePathResolver.invalidateCache()`（正式 API）+ 重探。

### 9.4 测试与验证

- `test/utils/nas_mapped_drive_test.dart` 新增注入式用例组（9 例）：
  经 `NetworkPath.debugRemoteDrives / debugDriveUncOverrides` +
  `GamePathResolver.debugDriveMapProvider / debugProbe` 无真机构造映射盘。
- 🔴 本会话 231 持续（OS 层 cmd.exe 管道耗尽），`flutter test` 无法启动；
  **等价验证**：`.workbuddy/_nas_b_probe.dart`（逐条复刻 9 例断言）
  经 frontend_server_aot + flutter_tester 离线运行 **30/30 PASS**；
  进程内 analyzer 六文件 0 error（11 warning 全为存量）。
- ⏳ 待环境恢复补跑 `flutter test test/utils/nas_mapped_drive_test.dart`；
  ⏳ 映射盘真机五步走查（§6）+ 新增第 6 步：**离线导入的存量游戏在
  NAS 恢复后详情页应显示 `Z:\` 形态**。
