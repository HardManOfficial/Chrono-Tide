# 游戏识别规则文档

本文档描述 CTLIB 批量导入功能的游戏识别机制，包括 5 阶段扫描架构、
GalGameDetector 信号评分体系、引擎特征表、附属文件夹检测规则，
以及典型游戏目录结构示例。便于后续维护调参和用户理解识别决策。

---

## 1. 5 阶段扫描架构

批量导入扫描由 `BatchImportController.scanFolderForGames` 实现，
采用两阶段五步架构，确保精准识别同时避免误识别。

### 阶段一：收集候选目录

- **入口**：`_collectCandidates(dir, candidates, rootPath, depth, maxDepth, excludePatterns)`
- **行为**：递归收集子目录，最大深度 4 层
- **过滤规则**：
  - 跳过隐藏目录（`.` 开头）
  - 按 `WatchFolder.defaultExcludePatterns` 做包含匹配过滤（如 `common`、`launcher`、`install` 等）
- **结果**：候选目录列表（含 rootPath 本身 + 所有未排除的子目录）

### 阶段二：逐个识别

- **入口**：对每个候选目录调用 `_isIndependentGame(candidatePath)`
- **识别器**：`GalGameDetector.detect(folderPath)` 返回 `GalDetectionResult`
- **多维排重**：用 `ImportDedupIndex.check(path, title)` 做路径包含硬冲突 + 同名软警告
  （参考 LunaBox `import_index.go` 四维索引），已入库游戏直接跳过
- **根目录保护**：用户选择的扫描根目录本身不作为游戏（用 `PathNormalizer.forCompare` 规范化比较）
- **通用名拦截**：英文通用名（`game`/`games`/`gal` 等）精确匹配直接拒绝；CJK 关键词（`补丁`/`存档`/`备份`/`汉化`）子串匹配直接拒绝
- **检测缓存**：所有 `mainExeName != null` 的检测结果缓存入 `detectionCache`，供阶段 2.5 复用
- **结果**：所有识别为游戏的目录（含检测结果，不做去重）

### 阶段 2.5：包装文件夹救援（exe 在子目录场景）

- **背景**：直接签名门控（见下方）使 exe 在子目录的游戏本体（如 `命运石之门/bin/game.exe`）
  被判 `isGame=false`。若不救援，这类游戏会完全漏识别——这是直接签名门控的回归风险点。
- **救援条件**（全部满足才提升为游戏）：
  1. 候选未被阶段二识别（不在 `detected`）
  2. 有**继承 exe**（`mainExeInherited=true`，即 exe 在子目录中）
  3. 无直接签名（`hasDirectSignature=false`，有直接签名的应已被阶段二识别）
  4. 非通用名（`GAL`/`bin`/`存档备份` 等本身不应作为游戏）
  5. 名称含 CJK 字符（避免误救英文系统文件夹）
  6. 含 **< 2** 个游戏子目录（≥2 个则判定为容器，不救援）
- **复用缓存**：使用阶段二的 `detectionCache`，避免对同一目录重复调用 `detect()`
- **示例**：
  - `E:\GAL\命运石之门\bin\game.exe` → `命运石之门\` 无直接签名但有继承 exe → 救援为游戏
  - `E:\GAL\JRPG\` 有继承 exe 但含 ≥2 游戏子目录 → 判定容器不救援

### 阶段三：移除归纳文件夹（直接签名判定）

- **核心概念——直接签名**：来自本文件夹**自身**（depth 0）内容的游戏签名，包括：
  - `hasDirectStrongSignal`：引擎核心文件直接位于本文件夹（如 `data.xp3`）
  - `hasDirectExe`：非排除 exe 直接位于本文件夹
  - `hasDirectDataPack` + `hasDirectFeatureDir`：数据包 + 特征目录直接位于本文件夹
  - 对应 `hasDirectSignature = hasDirectStrongSignal || hasDirectExe || (hasDirectDataPack && hasDirectFeatureDir)`
- **判定条件**（基于直接签名，而非继承的强信号）：
  1. 救援提升的游戏（isGame=true 但无直接签名）→ 保留
  2. 有直接强信号 / 直接数据包+特征目录 → 保留（真实游戏本体）
  3. 有直接 exe 但含 **≥2** 个游戏子目录 → **启动器型容器，移除**（行为变更）
  4. 有直接 exe 且 0-1 个游戏子目录 → 保留
  5. 无直接签名 + 有游戏子目录 → 容器，移除
- **移除原因**：容器文件夹（如 `GAL/`、`JRPG/`、启动器型合集）本身不是游戏，
  其子目录才是真正的游戏。直接签名判定阻断容器凭继承的引擎文件被误判为游戏。
- **示例**：
  - `D:\GAL\` 无直接签名 + 有游戏子目录 → 移除（容器）
  - `D:\GAL\游戏A\` 有直接强信号（data.xp3） → 保留（真实游戏）
  - `D:\游戏A\game\.rpyc` → 游戏A 有直接 exe → 保留（game/ 子模块在阶段四跳过）
  - `Launcher.exe + Game1/ + Game2/`（启动器型合集）→ 移除，导入 Game1/Game2

### 阶段四：父子重叠去重

- **判定条件**：某目录是已保留目录的子目录
- **保留规则**：保留父目录（真正的游戏），跳过子模块
- **示例**：
  - `D:\游戏A\` 被保留（有强信号）+ `D:\游戏A\patch\` 被识别为游戏 → `patch\` 被跳过
  - `D:\游戏A\game\` 被识别为游戏（含 .rpyc） → 跳过（父目录 `D:\游戏A\` 已保留）

### 阶段五：共享启动程序去重

- **判定条件**：两个游戏目录共享相同的 exe（深度差 ≤1 且 exe 同名）
- **跳过原因**：同一游戏的不同安装路径（如多版本/多补丁），不应重复导入
- **示例**：
  - `D:\游戏A\` 和 `D:\游戏A\backup\` 都有 `game.exe`，深度差 1 → 跳过 `backup\`

---

## 2. GalGameDetector 信号评分体系

### 评分公式

```
总分 = 强信号数 × 40
     + Σ(中等信号分值)    // 脚本/数据包 +15，特征目录 +8，exe +10
     + 弱信号数 × 5
     - Σ(负信号分值)     // 系统路径 -50，项目标记 -40，无 exe -15，通用名 -30
```

### 判定阈值

- `confidence = score / 100`（clamp 0.0~1.0）
- `isGame` 判定（**直接签名门控**）：
  1. **前置门控**：无直接签名（`hasDirectSignature=false`）→ `isGame=false`。
     阻断容器文件夹（GAL/JRPG）凭继承的引擎文件被误判为游戏。
     `mainExeName` 仍可来自继承（供阶段 2.5 包装文件夹救援使用）。
  2. 有直接签名 → 沿用评分判定：
     - 有强信号 → `score >= 30` 即通过
     - 无强信号但满足救援规则 → 直接通过
     - 其他 → `score >= 30` 且 `medium.length + weak.length >= 2`

### 直接签名 vs 继承信号

检测器 `_collectEntriesSeparate` 分别收集 depth 0（直接）与 depth 1（继承）内容：

| 来源 | 用途 | 字段 |
|------|------|------|
| 直接（depth 0） | isGame 门控（必须有直接签名才是游戏） | `hasDirectStrongSignal` / `hasDirectExe` / `hasDirectDataPack` / `hasDirectFeatureDir` |
| 继承（depth 1） | 评分贡献 + 引擎类型推断 + mainExe 回退 | `strongSignals` / `mediumSignals`（含继承项） |

> **设计决策**：容器文件夹（GAL/JRPG）的子目录是游戏，2 层扫描会继承收集到引擎文件。
> 旧实现不区分来源，容器凭继承强信号被误判为游戏。直接签名门控只认可本文件夹自身内容，
> 容器天然无直接签名 → 不被判定为游戏 → 递归进入子目录发现真游戏。

### 救援规则

覆盖 Ren'Py/Unity 新作（无传统引擎特征文件）：
- 无强信号
- 有 exe 文件（中等信号）
- 目录名含 CJK 字符（弱信号）
- 至少 1 个特征目录或媒体目录

---

## 3. 信号类型详解

### 强信号（+40 每个，引擎核心文件）

直接强判定，即使其他信号弱也通过。

| 引擎类型 | 特征文件片段 |
|----------|-------------|
| Kirikiri / KAG | `data.xp3`, `initial.ks`, `startup.tjs`, `krkr.exe` |
| NScripter | `nss.npa`, `arc.nsa`, `onscripter`, `reallive` |
| SiglusEngine | `siglus`, `siglusengine` |
| System4.x (AliceSoft) | `system40`, `alice` |
| BGI / Buriko | `buriko`, `monshiro`, `bgi.exe` |
| Ren'Py | `renpy`, `.rpyc`, `archive.rpa`, `updates.json` |
| Unity | `unityplayer.dll`, `assembly-csharp.dll`, `globalgamemanagers` |
| RPGMaker / Tyrano / WOLF | `rpgmaker`, `tyrano`, `wolf.exe` |
| 其他 | `light.vn`, `softpal`, `artemis`, `mages`, `nitroplus` 等 |

### 中等信号

| 类型 | 分值 | 触发条件 |
|------|------|----------|
| 脚本文件 | +15 | 扩展名 `.ks`/`.tjs`/`.scp`/`.rb`/`.js`/`.rpy` |
| 数据包文件 | +15 | 扩展名 `.xp3`/`.npa`/`.pak`/`.arc`/`.dat`/`.rpa`/`.rpyc` |
| 特征目录 | +8 | 目录名 `data`/`sound`/`bg`/`cg`/`bgm`/`voice`/`sav`/`script` 等 |
| exe 文件 | +10 | 非排除关键词的 .exe 文件 |

### 弱信号（+5 每个）

- CJK 目录名（含日文/中文/韩文字符）
- 媒体目录名（`image`/`movie`/`bgm`/`music`/`se`/`voice` 等）

### 负信号

| 类型 | 分值 | 触发条件 |
|------|------|----------|
| 系统路径 | -50 | 路径含 `windows`/`program files`/`appdata`/`$recycle.bin` 等 |
| 项目标记 | -40 | 含 `package.json`/`tsconfig.json`/`cargo.toml`/`go.mod` 等 |
| 通用目录名 | -30 | 英文精确匹配 `data`/`config`/`patch`；CJK 子串匹配 `补丁`/`存档`/`备份`/`汉化` |
| 无 exe | -15 | 无强信号且无 exe 文件 |

---

## 4. 附属文件夹检测规则

### 通用目录名表

**英文通用名**（精确匹配 → -30 弱负信号）：

`data`, `config`, `system`, `temp`, `tmp`, `cache`, `update`, `patch`, `save`, `saves`, `backup`, `new folder`, `folder`, `game`, `games`

**CJK 关键词**（子串匹配 → -30 弱负信号 + 硬拦截）：

| 关键词 | 含义 | 拦截场景 |
|--------|------|----------|
| `补丁` | patch | AI补丁、补丁&存档、汉化补丁、更新补丁... |
| `存档` | save | 全CG存档、存档备份... |
| `备份` | backup | 存档备份、备份文件夹... |
| `汉化` | Chinese translation | 汉化补丁、汉化版... |

> **设计决策**：CJK 关键词用**子串匹配**（`folderName.contains(kw)`），
> 而非精确匹配。原因：实际场景中附属文件夹名多为组合名
> （如 "AI补丁"、"补丁&存档"、"[白井木学园]...完整汉化补丁"），
> 精确匹配无法覆盖这些变体。
>
> 安全性：游戏文件夹名通常是游戏标题（如"命运石之门"、"Steins;Gate"），
> 不会包含"补丁/存档/备份/汉化"等附属词汇作为子串，因此子串匹配不会误伤合法游戏名。
>
> 英文通用名仍用精确匹配，避免误伤含 "game" 等子串的合法名称（如 "gameData"）。

### exe 排除关键词表（contains 匹配 → 不作为 mainExe）

**英文**：`uninstall`, `setup`, `installer`, `patch`, `update`, `config`, `tool`, `editor`, `crash`, `report`, `redist`, `vc_redist`, `dxsetup`, `vcredist`

**CJK 关键词**（contains 匹配）：

| 关键词 | 拦截 exe 示例 |
|--------|---------------|
| `汉化` | 汉化补丁.exe, 汉化v1.0.exe |
| `补丁` | 补丁.exe, 修正补丁.exe |
| `修正` | 修正补丁.exe, 修正v2.exe |
| `更新` | 更新程序.exe, 更新.exe |
| `存档` | 存档编辑器.exe, 存档查看器.exe |
| `备份` | 备份工具.exe, 备份.exe |

> **设计决策**：CJK exe 关键词用**包含匹配**（`nameLower.contains(kw)`），
> 因为 exe 文件名变体多（如"汉化补丁v1.0.exe"），需要更宽松的匹配。

### 多层防御

附属文件夹的误识别由多层防御共同拦截：

1. **exe 排除**（E-2）：附属 exe（如"汉化补丁.exe"）被排除，不作为 mainExe
2. **通用名拦截**（E-1 + 控制器硬拦截）：英文精确匹配 + CJK 子串匹配
   - 检测器层：-30 弱负信号（降低评分）
   - 控制器层：`_isGenericName` 硬拦截（直接拒绝，不论评分高低）
   - CJK 子串匹配覆盖组合名："AI补丁"、"补丁&存档"、"全CG存档"、"[白井木学园]...完整汉化补丁"等
3. **直接签名门控**（detector）：无直接签名 → `isGame=false`，阻断容器凭继承信号成游戏
4. **容器移除**（stage 3）：无直接签名 + 有游戏子目录 → 容器移除；有直接 exe 但 ≥2 游戏子目录 → 启动器型容器移除
5. **父子去重**（stage 4）：即使附属文件夹通过以上所有防御，父目录是游戏时也会被跳过

---

## 5. 典型游戏目录结构示例

### 正确识别案例

#### 案例 1：Kirikiri 游戏（标准结构）

```
D:\Games\星空のメモリア\
├── data.xp3          ← 强信号 (Kirikiri)
├── game.exe          ← mainExe
├── bgm\
├── voice\
└── save\
```

- 识别结果：✅ 通过（强信号 +40 + exe +10 + 特征目录 +24 = 74 分）
- mainExe：`game.exe`

#### 案例 2：Ren'Py 游戏（带 game/ 子模块）

```
D:\Games\某某RenPy游戏\
├── game\
│   ├── archive.rpa   ← 强信号 (Ren'Py)
│   ├── script.rpyc   ← 强信号 (Ren'Py)
│   └── saves\
├── game.exe          ← mainExe
└── lib\
```

- 识别结果：✅ 通过（强信号 +80，父目录 `D:\Games\某某RenPy游戏\` 保留）
- `game\` 子模块在 stage 4 被跳过（父子重叠）

#### 案例 3：Unity 游戏（无传统引擎特征文件）

```
D:\Games\某Unity游戏\
├── GameData.exe      ← mainExe（非排除关键词）
├── Game_Data\
│   ├── unityplayer.dll   ← 强信号 (Unity)
│   └── resources.assets  ← 强信号 (Unity)
└── MonoBleedingEdge\
```

- 识别结果：✅ 通过（强信号 +80）

### 误识别拦截案例

#### 案例 4：补丁文件夹被拦截

```
D:\Games\游戏A\
├── data.xp3          ← 强信号（父目录被识别为游戏）
├── game.exe
└── 补丁\              ← 通用名 -30 弱负信号
    ├── 汉化补丁.exe   ← exe 排除（含"汉化"+"补丁"）
    └── readme.txt
```

- `D:\Games\游戏A\`：✅ 识别为游戏（强信号 +40）
- `D:\Games\游戏A\补丁\`：❌ 被拦截（通用名 -30 + exe 被排除 → 无 mainExe → `_isIndependentGame` 返回 null）
- 即使通过识别，也会在 stage 4 被跳过（父子重叠）

#### 案例 5：归纳文件夹被移除（直接签名门控）

```
D:\GAL\               ← 无直接签名（子目录游戏文件被继承但不构成直接签名）→ stage 3 移除
├── 游戏A\
│   └── data.xp3       ← 直接强信号 → 游戏A 识别为游戏
├── 游戏B\
│   └── game.exe       ← 直接 exe → 游戏B 识别为游戏
└── 补丁合集\           ← 通用名 -30 → 不识别
    └── patch.exe      ← exe 排除（含"patch"）
```

- `D:\GAL\`：❌ stage 3 移除（无直接签名 + 有游戏子目录 → 容器）
- `D:\GAL\游戏A\`：✅ 识别为游戏（直接强信号 data.xp3）
- `D:\GAL\游戏B\`：✅ 识别为游戏（直接 exe）
- `D:\GAL\补丁合集\`：❌ 被拦截（通用名 -30 + exe 排除）

#### 案例 6：开发项目被拦截

```
D:\Projects\my_game_tool\
├── package.json       ← 项目标记 -40 强负信号
├── src\
│   └── main.ts
└── build\
    └── tool.exe       ← exe 但项目标记导致扣分
```

- 识别结果：❌ 被拦截（项目标记 -40 + 无强信号 + 无数据包 → 低分）

#### 案例 7：组合名补丁文件夹被拦截（子串匹配 + 游戏本体保护）

```
E:\GAL\Love×Holic ～魅惑の乙女と白濁カンケイ～\
└── Love×Holic ～魅惑の乙女と白濁カンケイ～\     ← 游戏本体（Start.exe + .arc 文件）
    ├── Start.exe          ← mainExe
    ├── bgd.arc, cg00.arc  ← 数据包（.arc → 中等信号 +15）
    ├── message.dat         ← 数据包（.dat → 中等信号 +15）
    ├── Save\               ← 特征目录 +8
    └── 补丁&存档\           ← CJK 子串匹配"补丁" → 硬拦截
        ├── AI补丁\          ← CJK 子串匹配"补丁" → 硬拦截
        │   ├── Start.exe    ← 被拦截（不会成为 mainExe）
        │   └── message.dat
        └── 全CG存档\        ← CJK 子串匹配"存档" → 硬拦截
```

- 游戏本体：✅ 识别为游戏（exe +10 + 数据包 +30 + 特征目录 +8 + CJK +5 = 53 分）
  - 即使有子文件夹通过识别，Stage 3 游戏本体保护（exe+数据包）也会保留
- `补丁&存档\`：❌ 子串匹配"补丁" → 硬拦截（不论评分高低）
- `AI补丁\`：❌ 子串匹配"补丁" → 硬拦截
- `全CG存档\`：❌ 子串匹配"存档" → 硬拦截

> **修复历史**：此前 CJK 关键词用精确匹配，"AI补丁"/"补丁&存档"/"全CG存档"等组合名
> 未被拦截，导致补丁子文件夹被识别为游戏，游戏本体在 Stage 3 被误移除为归纳文件夹。
> 改为子串匹配 + Stage 3 游戏本体保护后修复。

#### 案例 8：多层嵌套汉化补丁被拦截

```
E:\GAL\爱之钥甜园夏日\              ← 游戏本体（4个exe + .dat + 特征目录）
├── アイカギ ～アフターデイズ～.exe   ← mainExe
├── yscfg.dat              ← 数据包 +15
├── cg\, save\             ← 特征目录 +16
└── 补丁\                   ← 精确匹配"补丁" → 硬拦截
    ├── [白井木学园]...完整汉化补丁\  ← 子串匹配"补丁"+"汉化" → 硬拦截
    │   └── 爱之钥～AfterDays～.exe
    ├── 全CG存档\            ← 子串匹配"存档" → 硬拦截
    └── 爱之钥甜园夏日汉化补丁V0,99\ ← 子串匹配"补丁"+"汉化" → 硬拦截
        └── 爱之钥 AfterDays~.exe
```

- 游戏本体：✅ 识别为游戏（exe +10 + 数据包 +15 + 特征目录 +16 + CJK +5 = 46 分）
- 所有补丁子文件夹：❌ 被 CJK 子串匹配硬拦截

#### 案例 9：容器文件夹拦截（GAL 根目录 / JRPG 分类容器）

```
E:\GAL\                ← 根目录保护（不作为游戏）+ 无直接签名 → 不识别
├── JRPG\              ← 无直接签名（子目录游戏文件仅继承）→ stage 3 容器移除
│   ├── 命运石之门\     ← 直接 exe + 直接强信号 → 识别为游戏
│   │   ├── game.exe
│   │   └── data.xp3
│   └── 月姬\           ← 直接 exe + 直接强信号 → 识别为游戏
│       ├── game.exe
│       └── arc.nsa
└── 沙袋游戏\           ← 直接 exe → 识别为游戏
    └── game.exe
```

- `E:\GAL\`：❌ 根目录保护跳过（用户选择的扫描根目录不作为游戏）
- `E:\GAL\JRPG\`：❌ 无直接签名 + 有 ≥2 游戏子目录 → 容器移除（旧实现误判为游戏）
- `E:\GAL\JRPG\命运石之门\`：✅ 识别为游戏（直接 exe + 直接强信号）
- `E:\GAL\JRPG\月姬\`：✅ 识别为游戏
- `E:\GAL\沙袋游戏\`：✅ 识别为游戏

> **修复历史**：旧实现 `_collectEntries` 扫描 2 层不区分直接/继承，JRPG 凭继承子游戏的
> `data.xp3`/`arc.nsa` 获得强信号 → 被误判为游戏导入，而内部真游戏因父子重叠被跳过。
> 直接签名门控使 JRPG `isGame=false`，阶段三移除容器，递归发现内部真游戏。

#### 案例 10：包装文件夹救援（exe 在 bin/ 子目录）

```
E:\GAL\命运石之门\     ← 无直接签名（exe 在 bin/ 子目录）→ 阶段二 isGame=false
├── bin\               ← 通用名拦截（bin 在 englishGenericNames）→ 不识别
│   └── game.exe       ← 继承到父目录作为 mainExeName
├── data\
│   └── config.ini
└── readme.txt
```

- `E:\GAL\命运石之门\`：✅ 阶段 2.5 救援为游戏
  - 阶段二：无直接签名 → `isGame=false`，但 `mainExeName=game.exe`（继承）、`mainExeInherited=true`
  - 阶段 2.5：有继承 exe + 非通用名 + CJK 名 + <2 游戏子目录 → 救援提升为游戏
- `E:\GAL\命运石之门\bin\`：❌ 通用名拦截（bin）

> **设计决策**：直接签名门控会漏识别 exe 在子目录的游戏本体（如 bin/、launcher/ 等）。
> 阶段 2.5 包装文件夹救援通过「继承 exe + 非通用名 + CJK 名 + <2 游戏子目录」条件
> 将这类游戏本体救援回来，复用 `detectionCache` 避免重复 `detect()` 调用。

---

## 6. 调参指南

### 提高识别率（减少漏识别）

- 在 `_engineIndicators` 中添加新引擎的特征文件
- 在 `_featureDirs` 中添加新的游戏特征目录名
- 降低 `defaultThreshold`（当前 0.30）

### 降低误识别率（减少误识别）

- 在 `_englishGenericNames`（精确匹配）或 `_cjkGenericKeywords`（子串匹配）中添加新关键词
- 在 `_exeExcludeKeywords` 中添加新的非游戏 exe 关键词
- 在 `_projectMarkerFiles` 中添加新的项目标记文件
- 提高 `defaultThreshold`

### 日志调试

扫描日志写入 `<exeDir>/logs/scan_<timestamp>.log`（最多 10 个轮转文件），
包含每个候选目录的接受/跳过决策与依据，便于排查识别问题。
