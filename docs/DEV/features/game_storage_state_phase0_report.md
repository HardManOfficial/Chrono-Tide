# 游戏数据保存（存储状态）· Phase 0 技术验证报告

> **性质**：实测报告。不是方案、不是设计，只记录「跑出来的事实」。
> **日期**：2026-10-02　**执行**：只读业务代码未改（本阶段只新增 `dev_probe/` 探针）
> **对应方案**：`docs/DEV/features/game_storage_state_implementation_plan.md` §7 Phase 0
> **门禁结论**：✅ **允许进入 Phase 1**（附 3 项必改项，见 §1.2）

---

## 0. 一句话结论

**7z 压缩→解压往返 100% 无损（815/815 文件、0 差异、含中文/日文/291 字符长路径/只读/0 字节），回收站能力已用 Dart FFI 实证打通；但方案有三处必须修正：① `_parse7zLine` 正则完全解析不到 7z 的真实进度输出（顺带暴露一个既有 bug）② 吞吐预估 30–80MB/s 严重偏高，实测 5–20MB/s ③ `.partial` 半成品标记 7z 不会自己做，必须由 Dart 侧实现。**

---

## 1. 门禁判定

### 1.1 逐项结果

| 项 | 假设 | 结果 | 判定 |
|---|---|---|---|
| **0.1** | `7z a` 进度与现有 `_parse7zLine` 格式同构 | ❌ **不同构**：7z 输出 `  5%`（`%` 紧跟数字），现有正则 `^\s*(\d+)\s` 要数字后跟空白 → 解析率 **1/29** | ⚠️ 需改规则 |
| **0.2** | 压缩 → 解压 → 往返一致 | ✅ **815/815 文件、0 尺寸差异、0 内容差异**，7 项边界全过 | ✅ 通过 |
| 0.3 | 大目录与超长路径 | ⚠️ 291 字符路径 ✅ 通过；GB 级未测（磁盘仅剩 15G） | ⚠️ 部分 |
| 0.4 | `-sdel` 是否可安全使用 | ⚠️ 会把源**连目录一起删光**（805→0） | ❌ 不用 |
| 0.5 | 删除到回收站可行性 | ✅ Dart FFI `SHFileOperationW` 成功，回收站项数 132→133 | ✅ 通过 |
| 0.6 | 中断 / 磁盘满行为 | ✅ 源**零损伤**；半成品是目标名（无 `.tmp`），`7z t` 可检出 | ✅ 通过 |
| 0.7 | 是否需要分卷 | ✅ 7z 分卷能力 OK；但 `extract_manager` **不认 `.7z.001`** | ✅ 一期不用 |
| 补充 G1 | `.partial` 命名可行 | ✅ `-t7z body.7z.partial` 可生成且可校验 | ✅ |
| 补充 G2 | 压缩吞吐 | ⚠️ **5–61 MB/s**，随机数据仅 **4.9 MB/s** | ⚠️ 修正预估 |
| 补充 G3 | `7z t` 校验成本 | ✅ 129.4MB 仅 **0.26 秒**（494 MB/s） | ✅ 可忽略 |

### 1.2 门禁结论

方案 §7 规定：「若 0.1 或 0.2 不通过 → 停下来报告，重新评估选型」。

- **0.2 通过** → 核心假设（7z 往返无损）成立，**选型无需回退到 ZIP**。
- **0.1 不通过原假设，但方案同时允许「明确记录差异并给出新解析规则」** → 本报告给出新规则（§3.1），改动仅一行正则，**不构成选型问题**。

> **判定：允许进入 Phase 1**，但必须同时执行 §1.3 的三项修正。

### 1.3 三项必改（阻塞 Phase 1 的正确性）

| # | 改什么 | 位置 | 为什么必须改 |
|---|---|---|---|
| **M1** | `_parse7zLine` 正则 `^\s*(\d+)\s` → `^\s*(\d+)%` | `lib/services/extract_manager.dart:1304` | 不改则**压缩进度永远是 0%**；且这同时修掉一个既有 bug —— **现有解压进度条实际也是不动的** |
| **M2** | 吞吐预估 30–80 MB/s → **5–20 MB/s**；8GB 预计 2–5 分钟 → **7–28 分钟** | 方案 §6 性能预算 | 影响 UI「预计剩余时间」文案与用户预期，误差 5 倍以上会直接伤害体验 |
| **M3** | `.partial` 半成品标记**由 Dart 侧实现**（先压到 `xxx.7z.partial`，`7z t` 通过后再 rename） | 新增 `archive_compressor.dart` | 7z **直接写最终文件名**，中断后残留物与正常归档**同名无法区分**（实测） |

---

## 2. 测试环境与数据

### 2.1 环境

| 项 | 实测值 |
|---|---|
| 压缩工具 | `windows/runner/tools/7z.exe`（821,248 B，SHA256 `f00836a6…`）<br>`build/windows/x64/runner/Release/runtime/tools/7z.exe`（388,096 B，SHA256 `1b1a12f9…`） |
| 7z 版本 | **7-Zip (a) 23.01 (x86)** —— 是 `7za` 精简版 |
| 压缩能力 | ✅ **支持创建 7z**（格式表 `7z C...F...c.a.m+..`，codec 含 LZMA2/LZMA/BZip2/Delta/BCJ/7zAES/AES256CBC）<br>两个 exe 二进制不同但**能力一致，均实测可压缩** |
| 不支持 | RAR（故项目另外内置 `UnRAR.exe`） |
| Dart | `flutter/bin/cache/dart-sdk/bin/dart.exe`（3.5.3）—— ✅ **可直接运行探针**，Phase 1 可继续用 Dart 探针验证 |
| 磁盘 | D 盘 326G / 已用 311G / **可用 15G（96%）** |

> ⚠️ **两个 7z.exe 不是同一文件**（大小差 2 倍、哈希不同）。打包脚本 `打包脚本/一键打包.ps1:529` 是从 `$ReleaseDir\runtime\tools\7z.exe` 取，建议后续确认两者来源与版本是否需要统一（**本次只报告，未改**）。

### 2.2 测试树

构造脚本：`dev_probe/phase0_build_tree.py`　清单：`dev_probe/phase0_tree_index.json`

| 项 | 值 |
|---|---|
| 文件数 | **815** |
| 目录数 | 26（含 2 个**空目录**） |
| 总字节 | 185,969,247（177.4 MB） |
| 体积构成 | 128MB 随机（不可压）+ 48MB 高可压 + 800 个小文件 + 杂项 |
| 边界覆盖 | 中文文件名、日文文件名、全角标点、空格与单引号、点开头文件、**0 字节文件**、**只读文件**、**291 字符超长路径**、空目录、大量小文件 |

> 测试数据落在 `.workbuddy/tmp/phase0/`（1.4G），**验证完毕后已全部删除**，未污染仓库。

---

## 3. 逐项实测

### 3.1 【0.1】7z 进度输出格式 —— ❌ 与现有解析不同构

**实测命令**
```
7z a -t7z -mx=5 -md=64m -mmt=2 -bsp1 -y v1.7z "src\*"
7z x v1.7z -o<dir> -y -bsp1
```

**7z 的真实输出**（`\r` 刷新，原始 repr 见 `dev_probe/phase0_out_v1_bsp1.txt`）

压缩侧：
```
  0%
  5% 1 + src\big_compressible.dat
 12% 1 + src\big_compressible.dat
 28% 2 + src\big_incompressible\rand_0.bin
```
解压侧：
```
  0%
 94% 31 - src\big_incompressible\rand_1.bin
 99% 292 - src\many_small\f0258.txt
```

**与现有解析的冲突**

`extract_manager.dart:1302-1312`：
```dart
int? _parse7zLine(String line) {
  final trimmed = line.trimLeft();
  final match = RegExp(r'^\s*(\d+)\s').firstMatch(trimmed);   // ← 要求数字后跟空白
  ...
}
```

- 7z 的进度行是 `  5% 1 + …`，数字 `5` 后面**紧跟 `%`**，不满足 `(\d+)\s`。
- Dart 的 `LineSplitter` 同时认 `\r` / `\n` / `\r\n` → 实测切出 29 段，**只有 1 段**能被该正则命中（解析率 **3.4%**）。

**结论（新解析规则）**

```dart
// 旧：RegExp(r'^\s*(\d+)\s')      ← 解析不到
// 新：RegExp(r'^\s*(\d+)%')        ← 可覆盖 a / x 两种场景
```

同时需保留现有的 `parsed > lastPercent` 防回退判断（多文件/多卷时 7z 的百分比可能重复）。

> 🔴 **附带发现（既有 bug，非本次引入）**：因为正则不匹配，`_extract7z`（`extract_manager.dart:1250`）与 `_extractRarWith7z`（`:1159`）里的 `_parse7zLine` **恒返回 null**，进度事件的 percent 只在 `startPercent`↔`endPercent` 的骨架值之间跳，**真实百分比从未驱动过 UI**。修 M1 会一并修好这个既有缺陷，属于**行为改善**，不是行为变更 —— 但仍建议在 Phase 1 单独跑一次解压回归确认。

---

### 3.2 【0.2】压缩→解压往返 —— ✅ 完全通过

```
7z a -t7z -mx=5 -md=64m -mmt=2 -bsp1 -y v1.7z "src\*"     → exit=0, 129.4MB
7z t v1.7z                                                 → exit=0
7z x v1.7z -o<提取目录> -y -bsp1                            → exit=0
```

`7z t` 输出：
```
Everything is Ok
Folders: 26
Files: 815
```

**逐文件比对结果（815 个文件全部做 SHA256）**

| 比对项 | 结果 |
|---|---|
| 期望文件 / 实际解出 | 815 / **815** |
| 缺失 | **0** |
| 多出 | **0** |
| 尺寸不符 | **0** |
| **内容不符（SHA256）** | **0** |
| 目录缺失 | **0**（26 个目录全部还原，含 2 个**空目录**） |

**边界项逐条**

| 边界 | 结果 |
|---|---|
| 中文文件名 `中文目录/中文测试文件.txt` | ✅ |
| 日文文件名 `日文ディレクトリ/テスト_セーブ.txt` | ✅ |
| 全角标点 `全角（括号）【方括号】、逗号。.txt` | ✅ |
| 点开头 `.hidden_config.ini` | ✅ |
| 0 字节 `c_empty.txt` | ✅ |
| 只读文件 `e_readonly.bin` | ✅（**只读属性也保留**，见 3.3） |
| **291 字符深层路径** | ✅ |
| 空目录（2 个） | ✅ 被归档并还原 |

**一个重要实现细节**：用 `7z a out.7z "src\*"` 会让归档内路径带 `src\` 前缀（解压后多一层）。**应改用工作目录方式**：

```
cd <源目录> && 7z a <归档> *
```
实测该方式：归档 842 条目（816 文件 + 26 目录），**无前缀、不丢点文件**（见 3.3）。

---

### 3.3 【0.3】边界行为补充 —— ⚠️ 部分通过

| 验证 | 结果 | 实测值 |
|---|---|---|
| **只读属性往返** | ✅ 保留 | 源 `0o100444` → 解出 `0o100444` |
| **超长路径** | ✅ 通过（7z **支持 >260 的路径**） | 291 字符路径完整归档并还原 |
| **空目录归档** | ✅ 被保留 | `7z t` 报 `Folders: 26`，与预期一致 |
| **Windows 通配 `*` 是否漏点文件** | ✅ **不漏** | 顶层 `.top_dotfile.txt` 被正常包含 |
| **cwd 方式无前缀** | ✅ | 842 条目全部无 `src\` 前缀 |
| **GB 级（>4GB）大目录** | ❌ **未验证** | 磁盘仅剩 15G，无法构造 |
| **磁盘满中途行为** | ❌ **未验证** | 同上 |

---

### 3.4 【0.4】`-sdel`（压后删源）—— ❌ 结论：不用

```
7z a -t7z -mx=5 -mmt=2 -sdel -y sdel.7z "*"   (cwd=测试子集)
```

| 项 | 值 |
|---|---|
| 源文件数 | 805 → **0** |
| 源残留目录 | **[]（连目录一起删光）** |
| 归档 | ✅ 已生成 |

**结论**：`-sdel` 会在压缩成功后**把源目录整个抹掉**（包括目录本身）。一旦 7z 判定成功但归档实际有问题（如磁盘写满边缘），用户数据将不可恢复。

**按方案原建议执行**：**不用 `-sdel`**，改由 Dart 侧在 `7z t` 校验通过 + 用户二次确认后，自己调用「移入回收站」（3.5 已实证可行）。

---

### 3.5 【0.5】删除到回收站 —— ✅ 通过（Dart FFI 实证）

**这是最终实现要走的技术路径**（项目已有大量 `dart:ffi` 直调系统 DLL 的先例，`ffi` 包已在依赖中）。

探针：`dev_probe/phase0_recycle_probe.dart`（纯 `dart:ffi`，无新增依赖）

```dart
// shell32!SHFileOperationW
fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;
// wFunc = FO_DELETE(0x0003)
```

**实测输出**
```
[F] before: exists=true files=3
[F] 回收站项数 before: D=132  C=228
[F] SHFileOperationW ret=0 (0=成功), aborted=0
[F] after: exists=false files=-1
[F] 回收站项数 after : D=133  C=228
[F] 结论: 目录已消失=true  D盘回收站项数增量=1  C盘增量=0
```

**结论**：`SHFileOperationW(FO_DELETE | FOF_ALLOWUNDO)` 可以把**整个目录**以「一项」的形式移入回收站，原路径消失，`fAnyOperationsAborted=0`。

**实现注意（踩坑记录）**

1. **回收站是「每盘一个」**：D 盘的删除进 `D:\$Recycle.Bin`，不是 C 盘。
2. **不要试图直接列 `$Recycle.Bin` 目录来验证**：`C:\$Recycle.Bin\S-1-5-18`、`D:\$Recycle.Bin\<用户SID>` 均 **ACL 拒绝访问**（`errno=5`）。正确做法是用官方接口 **`SHQueryRecycleBinW`** 查项数（本探针即如此）。
3. `SHFILEOPSTRUCTW.pFrom` 是**双 null 结尾**的宽字符串（`"路径\0\0"`）。

**未验证**：从回收站**还原**（需 UI 或 `IFileOperation`，未测）。但「进了回收站」本身即意味着用户可以手动还原。

---

### 3.6 【0.6】中断行为 —— ✅ 源零损伤

```
启动 7z a … interrupted.7z "src\*"  → 4 秒后 p.kill()
```

| 项 | 值 |
|---|---|
| kill 时是否运行中 | ✅ 是 |
| **源文件数** | 815 → **815**（不变） |
| **源字节数** | 185,969,247 → **185,969,247**（不变） |
| **源完好** | ✅ **true** |
| 新增产物 | `interrupted.7z`（34,970,870 B） |
| 半成品 `7z t` | **exit=2**（能检出损坏） |

**两个关键事实**

1. ✅ **7z 压缩绝不修改源目录** —— 中断后源字节级不变。
2. 🔴 **7z 直接写最终文件名，不产生 `.tmp`** —— 中断残留的 `interrupted.7z` 与正常归档**同名、无法从文件名区分**。

→ 这就是 **M3** 的由来：**半成品标记必须由 Dart 侧自己做**（压到 `xxx.7z.partial`，`7z t` 通过后 rename 为 `xxx.7z`）。G1 已实测该命名可行。

**未验证**：磁盘写满行为（无法在不破坏环境的前提下构造）。

---

### 3.7 【0.7】分卷 —— ✅ 能力可用，但一期不用

```
7z a -t7z -mx=1 -mmt=2 -v50m -y vol.7z "*"
→ 生成 vol.7z.001 / vol.7z.002 / vol.7z.003
7z x vol.7z.001 -o<dir> -y   → exit=0，815/815 自动连接
```

7z 侧分卷能力 **完全正常**（指定 `.001` 即可自动连接全部卷）。

**但 `ExtractManager` 不认它** —— `extract_manager.dart:737-779` 的格式表：

```dart
final singleExts = ['.zip', '.rar', '.7z', '.lz4', '.tar', ...];   // 无 .001
final volumePatterns = [
  RegExp(r'\.part(\d+)\.rar$'),   // 只有 RAR 分卷
  RegExp(r'\.r(\d{2,3})$'),
  RegExp(r'\.rar$'),
];
```

`.7z.001` **不在任何一条规则里** → `_detectFormats` 返回 `[]` → 解压链路无法处理。

**结论**：**一期不用分卷**（避免为此扩大改动面到 `extract_manager`）。分卷的真实需求只在「目标网盘有单文件上限」时出现，属二期云备份议题；若届时需要，必须**同时**给 `extract_manager` 补 `.7z.001` 识别规则。

---

### 3.8 【补充 G1】`.partial` 命名 —— ✅ 可行

```
7z a -t7z -mx=1 -mmt=2 -y body.7z.partial "src\many_small"
→ exit=0，文件已生成；7z t 校验 exit=0
```

非 `.7z` 扩展名配合 `-t7z` 强制类型**完全正常**，且 `7z t` 可校验 → **M3 的方案落地无障碍**。

---

### 3.9 【补充 G2】压缩吞吐 —— ⚠️ 必须修正方案预估

| 场景 | 源 | 归档 | 耗时 | **吞吐** | 压缩率 |
|---|---|---|---|---|---|
| 高可压 48MB（`-mx=5 -md=64m -mmt=2`） | 48.0 MB | 0.07 MB | 0.79s | **61.1 MB/s** | 0.001 |
| 高可压 48MB（`-mx=1`） | 48.0 MB | 0.07 MB | 2.11s | **22.8 MB/s** | 0.001 |
| **随机 64MB（`-mx=5 -md=64m -mmt=2`）** | 64.0 MB | 64.0 MB | 12.99s | **4.9 MB/s** | 1.000 |
| 混合 177.4MB 全量 | 177.4 MB | 129.4 MB | 33.92s | 5.2 MB/s | 0.73 |

**判读**

- 吞吐**极度依赖数据可压性**：可压 61 MB/s ↔ 不可压 4.9 MB/s，差 **12 倍**。
- **真实 Galgame 目录**（CG 多为 jpg/png、音频为 ogg/opus、视频为 mp4 —— 均已压缩）**应接近"随机"端**，即 **5–15 MB/s**。
- 8GB 游戏：按 10 MB/s ≈ **14 分钟**，按 5 MB/s ≈ **28 分钟**。

→ 方案 §6 写的「30–80 MB/s，8GB 约 2–5 分钟」**过于乐观，须修正为 5–20 MB/s / 7–28 分钟**（M2）。

> 附注：`-mx=1`（22.8 MB/s）反而比 `-mx=5`（61.1 MB/s）慢，反直觉。疑似 `-md=64m` 与 `-mx=1` 的字典参数交互所致，**未深究**（可在 Phase 1 定参数时复核）。

---

### 3.10 【补充 G3】`7z t` 校验成本 —— ✅ 可忽略

```
7z t v1.7z    → 129.4MB 归档，0.26 秒（494 MB/s），exit=0
```

**结论**：校验开销远小于压缩本身（因为 7z t 只读归档 + 校验 CRC，不落盘）。「删除本体前必过 `7z t`」的策略**成本可忽略**，可以放心作为强制前置。

---

## 4. 对 Phase 1 的直接影响

| # | 影响 | 行动 |
|---|---|---|
| 1 | `_parse7zLine` 正则必须改 | 抽公共 `SevenZipProgressParser` 时**直接用新正则** `^\s*(\d+)%`；同时修掉既有解压进度 bug |
| 2 | 压缩命令须用**工作目录方式** | `Process.start(exe, ['a','-t7z',...,archive,'*'], workingDirectory: srcDir)` —— 避免归档内出现多余的源目录名前缀 |
| 3 | 归档命名须带 `.partial` | 压到 `<时间戳>_<state>/body.7z.partial` → `7z t` 通过 → rename |
| 4 | **不要用 `-sdel`** | 删除本源由 Dart 侧控制（`7z t` 通过 + 二次确认 + 回收站） |
| 5 | **不要用 `-v` 分卷** | 一期不分卷；`extract_manager` 无 `.7z.001` 识别 |
| 6 | 回收站用 `SHFileOperationW` | 复用本报告探针 `phase0_recycle_probe.dart` 的结构；验证用 `SHQueryRecycleBinW` 而非列目录 |
| 7 | 吞吐预估改 5–20 MB/s | UI「预计剩余时间」按此计算，宁可高估也不要低估 |
| 8 | 压缩参数建议 | `-mmt=2` 保持不变（CPU 限流，实测 2 线程下机器仍可用）；`-mx=5 -md=64m` 可用 |

---

## 5. 未验证项（诚实清单）

| 项 | 为什么没做 | 建议 |
|---|---|---|
| **GB 级（>4GB）真实游戏目录** | 磁盘仅剩 15G（96% 已用），构造成本与环境风险都不合适 | 请开发者在空间充裕的机器上用真实游戏跑一次「压缩→解压→哈希比对」 |
| **磁盘写满中途行为** | 同上，无法在不破坏环境的前提下构造 | 同上；设计上已用「源最后删 + `.partial` + `7z t`」兜底 |
| **从回收站还原** | 需 UI 或 `IFileOperation` | 用户可手动还原即可满足需求 |
| **`-mx=1` 比 `-mx=5` 慢的反常** | 与本次门禁无关 | Phase 1 定压缩档位时复核 |
| **真实 Galgame 的压缩率** | 用的是合成数据（随机+重复块） | 真实游戏资源压缩率应低于随机样本 |
| **两个 7z.exe 不一致的影响** | 只做能力核对，未做版本溯源 | 确认打包链路取哪个文件，是否需统一 |
| **Q4 `flutter test`** | 本环境禁建 Dart 匿名管道 | 本阶段无需（纯探针），Phase 1 需开发者在自己的终端补跑 |

---

## 6. 证据文件索引

| 文件 | 内容 |
|---|---|
| `dev_probe/phase0_build_tree.py` | 测试树构造脚本（可重跑复现） |
| `dev_probe/phase0_tree_index.json` | 815 个文件的相对路径 + 尺寸 + SHA256（比对基准） |
| `dev_probe/phase0_compress_probe.py` | 压缩 + 原始 stdout 捕获（0.1） |
| `dev_probe/phase0_compress_result.json` | 压缩侧进度格式分析结果 |
| `dev_probe/phase0_out_v1_bsp1.txt` | **7z a -bsp1 原始输出 repr**（关键证据） |
| `dev_probe/phase0_out_x_bsp1.txt` | **7z x -bsp1 原始输出 repr**（关键证据） |
| `dev_probe/phase0_out_v3_nobsp.txt` | 无 `-bsp1` 时的输出对照 |
| `dev_probe/phase0_extract_verify.py` | 解压 + 往返校验（0.2） |
| `dev_probe/phase0_extract_result.json` | 往返比对 + 边界项结果 |
| `dev_probe/phase0_edge_probe.py` | 只读属性 / cwd 方式 / `-sdel` / 分卷（0.3/0.4/0.7） |
| `dev_probe/phase0_edge_result.json` | 上述结果 |
| `dev_probe/phase0_interrupt_probe.py` | 中断测试（0.6） |
| `dev_probe/phase0_interrupt_result.json` | 中断结果 |
| `dev_probe/phase0_recycle_probe.dart` | **Dart FFI 回收站探针**（0.5，可直接复用到 Phase 1） |
| `dev_probe/phase0_extra_probe.py` | `.partial` 命名 / 吞吐 / 校验成本（G1/G2/G3） |
| `dev_probe/phase0_extra_result.json` | 上述结果 |

### 复现方法

```bash
# 注意：先 unset 全部代理变量
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY NO_PROXY no_proxy

PY  = "C:/Users/SteinsGate/.workbuddy/binaries/python/versions/3.13.12/python.exe"
DART= ./flutter/bin/cache/dart-sdk/bin/dart.exe

$PY dev_probe/phase0_build_tree.py        # 建测试树（约 177MB）
$PY dev_probe/phase0_compress_probe.py    # 0.1 进度格式
$PY dev_probe/phase0_extract_verify.py    # 0.2 往返校验
$PY dev_probe/phase0_edge_probe.py        # 0.3/0.4/0.7
$PY dev_probe/phase0_interrupt_probe.py   # 0.6 中断
$PY dev_probe/phase0_extra_probe.py       # G1/G2/G3
$DART --packages="D:/CTLIB/.dart_tool/package_config.json" dev_probe/phase0_recycle_probe.dart

# 清理
rm -rf .workbuddy/tmp/phase0
```

---

## 7. 与方案原文的偏差汇总

| 方案原文 | 实测 | 处理 |
|---|---|---|
| §3.1 「解压侧已有 `-bsp1` 进度解析可复用」 | ❌ 解析规则**不匹配**，实际从未生效 | 已给新正则（M1），Phase 1 落地 |
| §6 「压缩吞吐 30–80 MB/s，8GB 约 2–5 分钟」 | ⚠️ 实测 5–20 MB/s（真实数据），8GB 约 7–28 分钟 | 修正为 M2 |
| §4.2 归档布局含 `.partial` 概念 | ✅ 方向正确，但 7z **不自带**该行为 | 明确由 Dart 侧实现（M3） |
| §7 Phase 0「`-sdel` 是否可安全使用」 | ❌ 会连目录删光源 | 结论：不用 |
| §7 Phase 0「分卷 `-v` 是否需要」 | ✅ 7z 能做，但 `extract_manager` 不认 | 结论：一期不用 |
| §2.2「7z 进度解析抽为公共工具，压缩复用」 | ✅ 方向正确 | 抽的时候直接用新正则 |
| §4.2 归档命令 `"<srcDir>\*"` | ⚠️ 会带一层目录名前缀 | 改用 cwd + `*` 方式 |
| 长路径风险 §10 P1「7z 在 >260 路径可能出错」 | ✅ **未复现**，291 字符路径正常 | 风险降级（无需 `\\?\` 前缀） |
| §10 P1「大目录压缩耗时可取消」 | ✅ 可取消，源无损 | 保持 |

---

*报告完 · 2026-10-02*
