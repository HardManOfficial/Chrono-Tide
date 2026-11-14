# 游戏字体替换（换字体）— 调研与集成方案

> 状态：**调研稿 v1.0**（2026-10-09）。本轮为纯阅读调研，未改动任何代码。
> 参考项目：SimpleFontHook（上游 https://github.com/SuQiandYing/SimpleFontHook）
> 本地参考：`D:\CTLIB\其他开发者的项目用于本项目参考\SimpleFontHook`（含 `SimpleFontHook-main` 与较新的 `SimpleFontHook.2.6`，本稿以 **`.2.6`** 为准）
> 证据等级沿用参考项目约定：**O** 观测（源码/产物直读）/ **I** 推断（由观测推导）/ **U** 待确认。

---

## 0. 结论速览

| 维度 | 结论 | 证据 |
|---|---|---|
| 注入方式 | **DLL 代理劫持**，产物名 `winmm.dll`，放目标 exe 同级目录；转发全部 winmm 导出避免破坏系统调用 | O |
| Hook 手段 | 微软 **Detours**（`DetourAttach`），全部经 `org*` 静态函数指针回调原 API | O |
| 主替换点 | `CreateFontA/W`、`CreateFontIndirectA/W/ExA/ExW` → `SelectObject`（HDC 换字体） | O |
| 渲染路径覆盖 | **GDI + GDI+ + DirectWrite** 三条；GDI+ 走私有字体集合，DWrite 走 vtable 索引 15/18 | O |
| 位数支持 | 独立构建 **Win32 与 x64**，产物分别在 `Release/` 与 `x64/Release/` | O |
| 配置存储 | 目标程序目录下 `FontHook.ini`（UTF-8 **带 BOM**），键 `FontNameW` 为**必需项** | O |
| 热切换 | `Config::ConfigVersion` 递增作缓存失效闸门 + 各引擎适配器 `NotifyConfigChanged` | O |
| 我方改造量 | **不需要改 SimpleFontHook 一行 C++**；改造集中在「管理器侧的配置生成 + 注入编排 + 生命周期管理」 | I |

**一句话方案**：把 SimpleFontHook 当作**已编译的第三方注入载荷**（`winmm.dll` + `FontHook.ini`），我方管理器只负责「**按游戏选择字体 → 为该游戏生成独立沙箱目录 → 把代理 DLL 与 INI 投放到正确位置 → 启动/清理**」。**不做源码级集成**，避免承担 16007 行 C++ 的维护与升级成本。

---

## 1. SimpleFontHook 核心原理与关键模块梳理

### 1.1 注入方式：winmm.dll 代理劫持

**观测 O-01**：产物命名为 `winmm.dll`，随附 PDB；`winmm_proxy.h` 中用约 180 行
`#pragma comment(linker, "/export:<name>=C:\Windows\System32\winmm.<name>")` 把 winmm 的
**全部系统导出**（`PlaySound`、`waveOut*`、`mixer*`、`mmio*`、`timeGetTime`、`midi*` 等）原样转发。

**原理**：Windows 加载器在解析导入表时，**exe 所在目录优先于 System32**（除非启用安全 DLL 搜索模式）。
因此把自研 `winmm.dll` 放在游戏 exe 同级，游戏对 `winmm.dll` 的任何导入都会命中我方 DLL；
`DllMain(DLL_PROCESS_ATTACH)` 即为执行入口，此时挂 Hook → 后续游戏调用字体 API 时全部经过我方。

**为什么选 winmm**：
- 几乎所有 galgame 引擎（音效/计时）都会静态导入 `winmm.dll`，命中率高。
- winmm 导出数量可控（~180 个），转发成本低。
- 相比 `d3d9.dll`/`dinput8.dll` 之类，winmm 的调用频率低、对性能影响小。

**推断 I-01**：若某游戏**不导入** winmm，此注入方式失效，需换代理名（如 `d3d9.dll`）。
参考项目未提供多代理名共存方案，需我方自行判断（见 §3.5）。

### 1.2 Hook 手段：Detours + org 指针双保险

**观测 O-02**（`hooks/internal/font_hooks_state.cppinc`）：所有 `org*` 指针的**初值即原 API 地址**：

```cpp
static pSelectObject orgSelectObject = SelectObject;
static pTextOutA     orgTextOutA     = TextOutA;
```

好处有二：
1. **防递归**：Hook 内部要调原函数时走 `org*`，不会再次进入自身。
2. **未挂钩也可用**：即使某个函数因兼容开关没挂上，`org*` 仍是有效地址，代码路径统一。

**观测 O-03**（`font_hooks_install.cppinc`）：钩子按**类别函数**分组挂载，全部包在同一事务里：

```cpp
DetourTransactionBegin();
DetourUpdateThread(GetCurrentThread());
AttachHooksByCategory();          // 15 个类别函数
Yuris::InstallInOpenDetourTransaction();
EntisCompat::InstallInOpenDetourTransaction();
BgiCompat::InstallInOpenDetourTransaction();
Unity::InstallInOpenDetourTransaction();
UnityMono::InstallInOpenDetourTransaction();
DetourTransactionCommit();
```

15 个类别：字体创建、字体资源、运行时库、代码页转换、INI profile、引擎文件、
文本绘制、DC 字体选择、字形轮廓、文本排版度量、字体身份查询、字体枚举、
字形度量补充、字体数据查询、DirectWrite。

**约束（来自 `AGENTS.md` + `docs/adr/README.md`）**：新增代理导出、改工程文件或链接选项，
必须核对 DLL 导出表（`dumpbin /exports`）。这是「代理 DLL 必须完整转发」的硬要求。

### 1.3 分层设计：四条**互不绑定**的独立路径

这是参考项目最重要的架构决策，`AGENTS.md` 明确列为不变量：

> 不把字体替换与代码页转换绑定。

| 路径 | 作用 | 典型触发场景 | 配置键 |
|---|---|---|---|
| **① 字体替换** | 改 `LOGFONT.lfFaceName`，换掉实际绘制字体 | 想用自己喜欢的字体 | `EnableFaceNameReplace` / `FontNameW` |
| **② 字符集伪装** | 改 `LOGFONT.lfCharSet`，让系统按其他字符集挑字 | 繁中游戏缺字、方块 | `EnableCharsetReplace` / `SpoofFromCharset` / `SpoofToCharset` |
| **③ 代码页重定向** | 在 `MultiByteToWideChar`/`WideCharToMultiByte` 边界重写代码页参数 | 引擎硬编码 CP932 导致乱码 | `EnableCodepageRedirect` / `CodepageRedirectFrom` / `To` |
| **④ 文字映射** | 对解码后的文本做字符级替换（如繁→简） | 繁体游戏强制简体字形 | `EnableTextSubstitution` / `TextSubstitutionMode` |

**为什么必须分开**：`docs/diagnostics.md` 记录了一个典型故障——
"换字体后文字变成**错误的汉字**" 就是**误开③或④**造成的（字形对了但选错字）。
分成四条路径，用户才能逐条开关、逐条定位。

**我方含义 I-02**：交给用户的 UI 不应把这四项混成一个"换字体"开关。
建议 UI 上暴露为「换字体」（①）为主开关，「修复乱码」「繁简转换」为**独立高级选项**。

### 1.4 字体替换模型：源 LOGFONT + 替换 HFONT + 版本化缓存

**观测 O-04**（`hooks/internal/model/font_hooks_replacement_cache.cppinc`）：

核心数据结构是**源/替换双向映射**：

- `g_replacementByOriginal`：源 HFONT → 替换 HFONT
- `g_replacementInfoByFont`：替换 HFONT → `{originalFont, sourceLogfont, configVersion}`
- `g_realToVirtualGlyph` / `g_virtualToRealGlyph`：字形索引双向映射

**改写顺序**（`BuildReplacementLogFont`，顺序有语义）：

```
EnableFaceNameReplace  →  改 lfFaceName = ForcedFontNameW
EnableCharsetReplace   →  改 lfCharSet  = ForcedCharset     （Majiro 引擎例外，保留 DEFAULT）
Softpal 特例           →  lfWidth=0, DEFAULT_PITCH|FF_DONTCARE
SpoofCharsetB          →  字符集伪装
高度/宽度缩放          →  FontHeightScale / ScaleLogFontWidth
FontWeight             →  覆盖字重
BgiCompat::NormalizeReplacementFontMetrics   → 引擎专属度量归一
```

返回 bool 表示"是否真的改了"；**没改则直接跳过**（skip reason `no-logfont-change`），避免无谓创建 HFONT。

**逻辑字体视图（关键技巧）**：`ExposeLogicalFontObject(HGDIOBJ)` 在 `GetObjectA/W` 被调用时，
把**替换 HFONT 换回源 HFONT** 返回。这样游戏查询 `GetObject` 拿到的仍是它自己创建的原始字体属性，
**不会因为被替换而改变自身逻辑**（例如某些引擎会用 `GetObject` 结果做二次创建，若拿到替换字体就会雪崩）。

**ConfigVersion 快照机制**：

```cpp
volatile LONG Config::ConfigVersion;   // 每次配置变更递增
```

- 缓存项记录"创建时的版本号"，只接受**当前版本**的缓存。
- `RefreshFontCacheEpoch()`：版本变化时清空 `g_replacementByOriginal` 与字形映射，
  但**保留** `g_replacementInfoByFont`——这样**旧句柄仍可被解包**，不会二次缩放。
- 这是"热切换字体"能生效而不重启游戏的核心机制。

### 1.5 HDC 替换与恢复：决策链

**观测 O-05**（`font_hooks_runtime.cppinc` 的 `ReplaceHdcFont`）决策链，顺序不可乱：

```
1. HookPolicy 决策（ShouldReplaceHdcFont）→ 拒绝则 skip
2. orgGetCurrentObject(hdc, OBJ_FONT) → 空则 skip
3. IsStockFontHandle → 系统内置字体(7个)则 skip
4. TryGetReplacementInfo 且版本一致 → skip（已经是最新的替换字体）
5. 取 sourceLogfont / originalFont，或 orgGetObjectW 现取
6. GetOrCreateReplacementFont → 建/查缓存
7. orgSelectObject(hdc, hNewFont)，返回旧字体
```

`RestoreHdcFont` 的细节：若旧字体是 `oldWasStaleReplacement`（上一轮版本的替换字体），
**不还原**；若替换字体未被托管则 `DeleteObject`。这避免了资源泄漏与还原错版本。

**HookPolicy 拒绝原因**（`hook_policy.cpp`，仅 4 种，全部有字符串名）：

| SkipReason | 触发条件 |
|---|---|
| `picker-thread` | 当前线程是字体选择器线程，或处于内部字体探针（`g_internalFontProbeDepth != 0`） |
| `hook-disabled` | `!EnableFontHook && !EnableCodepageSpoof` |
| `drawtexta-compat-skip` | 开了 FaceNameReplace 且 `CompatSkipDrawTextA`，且当前是 `DrawTextA/ExA` |
| `fontdata-query-compat-skip` | 同上模式，作用于 `GetFontData` |

**TLS 探针旁路**是重要设计：选择器自己枚举字体、预览字体时也要创建 HFONT，
若不旁路就会把自己也替换掉、预览失真。`g_internalFontProbeDepth`（TLS）解决了这点。

### 1.6 文本绘制 Hook 的统一模式

**观测 O-06**（`font_hooks_text_render.cppinc`，8 个绘制 Hook 同一模板）：

```cpp
DEBUG_API_CONTEXT("TextOutA");
TraceApiHit(...);                                    // 采样限流日志
std::wstring subTextW; int useCount = nCount;
bool useWide = SubstituteTextAToWide(lpString, nCount, subTextW, &useCount);  // ④ 文字映射
HFONT hOld, hNew = ReplaceHdcFont(hdc, &hOld);       // ① 换字体
int oldExtra = ApplyHdcCharSpacing(hdc, useCount, false);
ApplyTextDrawSpacing(hdc, x, y, useCount, &drawX, &drawY);
const bool bgiTextOutput = BgiCompat::BeginTextOutput(hdc, &drawY);  // 引擎专属
DEBUG_GDI_ENTER("TextOutA", hdc, hNew);
BOOL ret = useWide ? orgTextOutW(hdc, drawX, drawY, subTextW.c_str(), useCount)
                   : orgTextOutA(hdc, drawX, drawY, lpString, nCount);
BgiCompat::EndTextOutput(bgiTextOutput);
DEBUG_GDI_EXIT("TextOutA", hdc, ret, hNew);
RestoreHdcCharSpacing(hdc, oldExtra);
RestoreHdcFont(hdc, hOld, hNew);
return ret;
```

严格对称的 `Enter/Exit` + `Save/Restore`，保证任何一条提前 return 都不破坏 DC 状态。

**两个特例条件**（易踩坑）：
- `ExtTextOut`：仅当 `(options & ETO_GLYPH_INDEX) == 0` 才做文字替换——字形索引模式下文本不是字符而是索引，替换会画错。
- `DrawTextEx`：仅当 `(format & DT_MODIFYSTRING) == 0` 才替换——`DT_MODIFYSTRING` 会回写缓冲区，替换后长度不匹配会越界。

### 1.7 三条渲染路径的平台差异

| 路径 | Hook 点 | 关键实现 |
|---|---|---|
| **GDI** | `CreateFont*` / `CreateFontIndirect*` / `SelectObject` / `TextOut` / `ExtTextOut` / `DrawText*` / `GetGlyphOutline` / `GetFontData` / 度量 / 枚举 | 主战场，覆盖绝大多数老 galgame |
| **GDI+** | `GdipCreateFontFamilyFromName`（改用 `g_PrivateFontCollection` 私有字体集合）/ `GdipCreateFontFromLogfontW/A` | 通过 `InstallGdiPlusHooks()` 惰性安装；`newLoadLibrary*` 里检测到 `gdiplus` 名字就装 |
| **DirectWrite** | `DWriteCreateFactory` **导出 Hook** → 成功后取 `IDWriteFactory` **vtable**，索引 **15** 挂 `CreateTextFormat`、**18** 挂 `CreateTextLayout` | 两步走；且因 `dwrite.dll` 常延迟加载，起**延迟线程轮询** 200 次 |

**DirectWrite 的双层 Hook 是必要的**：`DWriteCreateFactory` 是导出函数可以 Detour，
但工厂对象的方法在 vtable 里，只能改 vtable 条目。且 vtable 是只读内存，Detours 用 `VirtualProtect` 处理。

**延迟线程细节**：200 次循环，前 40 次 `Sleep(10)`、之后 `Sleep(50)`；
同时尝试 `GetModuleHandleW(L"dwrite.dll")` 与 `L"DWrite.dll"` 两种大小写（Windows 路径不区分大小写，但 API 返回的模块名可能不同）。

### 1.8 配置系统：INI + 必需键 + BOM

**观测 O-07**（`utils.cpp`）：

**文件位置**：`GetModuleFileNameW(hModule)` 取 DLL 所在目录 → 拼 `FontHook.ini`。
即**与 winmm.dll 同目录**（也就是游戏 exe 目录）。

**读取 `LoadConfig` 的关键规则**：
1. 读文件 → 跳过 UTF-8 BOM → `ParseIni`。
2. 🔴 **`FontNameW` 缺失即 `return false`**——整个配置不应用。这是"必需键"。
3. `LooksLikeInternalMetricCloneName` 过滤内部度量克隆名（避免把自己生成的克隆名当用户选择）。
4. `FontNameA` 缺失时由 W 按 ACP 转换。
5. `ForcedFontNameW` 为空 → 强制 `EnableFontHook=false`、`EnableFaceNameReplace=false`。

**`ParseIni` 的"极简"实现**（重要，决定我方生成 INI 的格式自由度）：
- 紧凑线性表，`reserve(80)`。
- 跳过空行与 `;` `#` `[` 开头的行。
- **不解析节标题，节名被忽略**——所以 `[FontHook]` 写不写都行，但写上更规范。
- 同键**后者覆盖**前者。

**写入 `SaveConfig`**：
- 手写 `[FontHook]\r\n` 起始。
- 按**固定顺序**写全部键（不是 INI 库，是自己拼字符串）。
- 写 **UTF-8 BOM `0xEF 0xBB 0xBF`**。
- `FontHeightScale1000 = (DWORD)(FontHeightScale * 1000.0f)`——浮点用整数千分比存储。

**兼容别名回退**（说明该 INI 经过多轮演进，我方生成时**不要用旧键**）：

| 新键 | 回退键 |
|---|---|
| `EnableCodepageRedirect` | `CodePageConvertEnable` 或 `Enable` |
| `CodepageRedirectFrom` | `FromCodePage`（默认 932） |
| `CodepageRedirectTo` | `ToCodePage`（默认 CP_UTF8） |

**运行时强制（INI 改不动）**：
`EnableCodepageRuntimeReplace = EnableCodepageSpoof && SpoofFromCharset != SpoofToCharset`。

**各键夹取规则**：`TextSubstitutionMode ∈ [0,2]`、`DebugSlowMs >= 0`、
`DebugTraceSampleLimit >= 0`、`DebugPickerThreadLogLimit >= 0`、
`ArtemisFontSize >= 0`、`ArtemisRubySize >= -1`、`YurisAtlasCodepage` 需 `IsValidCodePage` 否则 0。

### 1.9 自定义字体加载：两条加载路径

**观测 O-08**（`utils.cpp::LoadCustomFont`，行 597-715）：

```
读 Config::FontFileName
  → 拼 DLL 目录路径
  → 文件不存在则按 galgame*.ttf 再 *.ttf 搜索
  → AddFontResourceExW(path, FR_PRIVATE, NULL)     ← 主路径
  → 若未开代码页伪装 && 未开垂直度量：直接返回
  → 读入内存
  → IsFontCollection 为 TTC → ExtractFontFromCollectionByName
  → EnableCodepageSpoof → PatchOS2CodePageRangeForCharset
  → EnableFontVerticalMetrics → PatchVerticalMetrics
  → AddFontMemResourceEx(...)                       ← 需要打补丁时走内存加载
```

**两条路径的取舍**：
- `AddFontResourceExW(FR_PRIVATE)`：**比 `AddFontMemResourceEx` 更可靠**（源码注释明确）。
  且 `FR_PRIVATE` 只对当前进程可见，不污染系统。
- `AddFontMemResourceEx`：当需要**在内存里打补丁**（改 `OS/2` 代码页位 / 垂直度量）时使用。

**SFNT/TTC 字节级修补**（`font/font_patcher.cpp` + `font/README.md`）：

| 接口 | 作用 | 关键点 |
|---|---|---|
| `PatchOS2CodePageRangeForCharset` | 置位 `OS/2.ulCodePageRange1/2` | ShiftJIS→bit 17、GB2312→bit 18、Hangul→19、Big5→20；bit≠0 时**同时置 bit 0**（Latin1）；`ulCodePageRange1` 在表内偏移 78、`Range2` 在 82 |
| `PatchVerticalMetrics` | 改 `hhea` 与 `OS/2` 垂直度量 | 值按 **unitsPerEm 的千分比**（permille）传入；从 `head` 表偏移 18 读 `unitsPerEm`；ascent 夹取 `[100,2000]`、descent `[-2000,-1]`、lineGap `[-2000,2000]` |
| `PatchNameTableFamily` | 重建 `name` 表设**唯一族名** | 避免"打补丁的内存克隆"与"已安装原字体"**撞名竞态**；TTC 时逐面处理 |
| `PatchCmapAliases` | 重建 Unicode `cmap` 做码位别名 | 供**直接用 FreeType**、不走文本 API 的引擎；**只改 Unicode→字形映射，不改输入编码**；TTC 不支持（直接返回 false） |
| `ExtractFontFromCollectionByName` | 按族名从 TTC 提取独立 SFNT | 按 `name` 表给候选面打分择优 |
| `NormalizeGdiFontData` | 规范化 GDI 导出的字体数据 | GDI 返回的字节可能保留**相对原 TTC 的偏移**，必须先规范化 |

**强约束（`font/README.md`）**：
- 所有 SFNT 整数**大端序**，统一走 `ReadU16BE`/`WriteU32BE` 等。
- 所有偏移/长度**解引用前范围检查**，并防加乘溢出。
- 改表后**必须**：更新目录项校验和 → `head.checkSumAdjustment` 置零 → 重算全字体校验和写回。
  **不可只改内容跳过校验和**——GDI 可能容忍，但 FreeType/HarfBuzz/Unity/Chromium 会直接拒载。
- 失败时保持输入可用（重建类操作先在临时缓冲完成）。

### 1.10 引擎适配框架：三阶段决策

**观测 O-09**（`hooks/internal/engines/README.md`）：

框架把引擎处理拆成**三个独立判断阶段**，`AGENTS.md` 明确要求不可合并：

| 阶段 | 回答的问题 | 证据要求 |
|---|---|---|
| **identity** 身份 | 这是哪个引擎？ | 必须有**多个**独立证据，不能只凭"通用 GDI 导入""窗口类名""单个文件名""文件扩展名/通用归档名" |
| **capability** 能力 | 该引擎的字体资源在哪里？以什么形式存在？ | 归档解析、配置读取、资源定位 |
| **route** 路由 | 用哪条路径替换？ | 决定走 HFONT 替换 / 文件重定向 / 资源注入 |

**为什么要分三阶段**：同一个引擎的不同版本能力不同；把"是什么"和"怎么做"混在一起，
一旦版本判定错就会走错路径，产生难以定位的故障。

**文件 API 边界**（`engine_file_dispatch.cppinc`）：处理顺序**有语义**，不可调换：

```
1. 判断是否隐藏
2. 缓存文件
3. 真实字体文件重定向
4. Web/ASAR 覆盖
5. Artemis 虚拟资源
```

**18 个引擎适配器索引**（引擎 → 主要职责）：

| 引擎 | 职责 |
|---|---|
| common | 公共基础 |
| Artemis | PFS / 表文件 |
| Artemis Legacy | IET / RFT |
| BGI | **DSC 解码 + LINE 字体脚本** |
| classic CatSystem2 | FreeType 文件字体 |
| DxLib | `_FONTSET.MED` |
| EntisGLS | 位图字体 |
| Escu:de | `configure.cfg` |
| KiriKiri / TVP | **预渲染字体 TFT** |
| Majiro | FCD 缓存 |
| Mirai | FreeType 数据源 |
| Ren'Py | **Python 字体映射** |
| Softpal | Pal 默认字体 |
| TinkerBell | 宽字符创建与 DC 跟踪 |
| TyranoScript | ASAR / Web 字体 / Electron 桥接 |
| Unity | Mono / IL2CPP TMP |
| YU-RIS | YPF **位图字体** |

**🔴 关键限制（`engines/README.md` 明确写出）**：

> 通用钩子只能覆盖**经过 Windows 字体 API 的调用**。游戏引擎还可能读取**预渲染字形**、
> 把字体**打包进归档**、长期持有**内部缓存**，或直接用 **FreeType、Python、Mono、IL2CPP、
> Chromium** 渲染。此时替换 `HFONT` 只能影响旁路流程，**屏幕上的真实文本仍由引擎资源决定**。

这条限制直接决定我方**预期管理**：本方案不是"任何游戏都能换字体"，
对 KiriKiri 预渲染 TFT、YU-RIS 位图字体、Entis 位图字体这类游戏，**必须靠引擎适配器改资源**，
否则用户会觉得"选了没用"。

### 1.11 安装 / 卸载 / 配置变更主干

**观测 O-10**（`font_hooks_install.cppinc`）：

```cpp
void Install(HMODULE hModule) {
    g_hModule = hModule;
    Utils::LoadConfig(hModule);                       // ① 先读配置
    Utils::Trace("[TRACE] process attach module=%p exe pid=%lu", ...);
    KrkrPatchMapPrerenderedFontName();                // ② 引擎前置准备（krkr 预渲染名映射）
    EntisCompat::Prepare();
    DetourTransactionBegin();
    DetourUpdateThread(GetCurrentThread());
    AttachHooksByCategory();                          // ③ 挂 15 类 GDI/DWrite Hook
    /* 各引擎 InstallInOpenDetourTransaction */
    DetourTransactionCommit();
    Yuris::Start();                                   // ④ 启动引擎工作线程
    Unity::StartApplyThread();
    UnityMono::StartApplyThread();
    StartDirectWriteDelayedHookThread();              // ⑤ dwrite 延迟轮询
    SoftpalInstallPalFontHooks();
    RenPy::Prepare();
    InstallGdiPlusHooks();                            // ⑥ gdiplus
    StartFontPickerThread(hModule);                   // ⑦ 字体选择器 UI 线程
}
```

**卸载 `PrepareForProcessExit()`**（幂等，`g_processExitPrepared`）严格**逆序**：

```
Utils::RequestShutdown()
 → UnityMono::StopApplyThread(true)
 → Unity::StopApplyThread(true)
 → RenPy::StopWorker(true)
 → Yuris::Stop(true)
 → StopDirectWriteDelayedHookThread(true)
 → StopFontPickerThread(true)
 → Utils::ShutdownDiagnostics(false)
```

参数 `true` = 允许等待。**注意 `AGENTS.md` 的不变量**：

> 不在加载器锁退出路径等待工作线程。

即 `DllMain(DLL_PROCESS_DETACH)` 里**不能**做无限等待，否则死锁/超时被杀。

**配置变更 `NotifyConfigChanged(version)`** 分派顺序（有依赖关系）：

```
Mirai → CatSystem2Compat → Tyrano → RenPy → Yuris → EntisCompat
 → ArtemisLegacy（返回 false 才继续走 Artemis）→ Majiro → DxLib
 → BgiCompat → Unity → UnityMono
```

### 1.12 字体选择器 UI（内置，我方大概率不用）

`ui/` 是一个**独立线程的自绘窗口**（`WS_EX_LAYERED` + `WS_EX_TOPMOST`），
热键 `Insert`（备选 `Pause`、`Scroll Lock`），最小客户区 480×640。

- 聚合翻译单元 `font_picker.cpp` 包含 6 个 `.cppinc` 分片（状态布局 / 应用配置 / 字体列表 / 绘制 / 输入 / 生命周期）。
- **设计约束（`ui/README.md`）**：绘制只读状态、输入只形成意图、**配置写入集中在 `apply_config`**。
- 字体列表**保留用户选择的源字体名**；字体表克隆**使用独立内部名称**，
  避免克隆名污染来源定位与 Ren'Py/Unity 等文件型字体路径。
- 应用流程：校验 → 保存 UTF-8 INI → **递增 `ConfigVersion`** → 通知钩子 + 发布有限重绘消息。
- **配置通知在锁外执行；UI 线程不等待引擎工作线程**。
- `Init` 开头：命令行含 `--type=`（Chromium 子进程）则**直接 return**——避免给每个渲染子进程都开一个选择器。

**我方判断 I-03**：这个 UI 是给「单机游戏内直接调字体」设计的，
**我方管理器应该是"在管理器里选好，再启动游戏"**，因此：
- 可以设 `PickerShowOnStartup=0` 让窗口不弹（或干脆不触发）。
- 但要保留其在进程内的**配置读取与重绘通知**能力（`Init` 里 `LoadConfig` + `ApplyRestoredConfigToGame`）。

### 1.13 诊断与复刻方法（我方集成时的验证工具）

**日志**：`FontHook.trace.log`，位于**目标程序目录**，每个进程会话首次写入时**重建**。

格式：`[HH:MM:SS.mmm][pid=][tid=] message`

**调试配置模板**（写进 INI 即可）：

```ini
[FontHook]
EnableDebugLog=1
DebugSlowMs=50
DebugTraceSampleLimit=128
DebugPickerThreadLogLimit=32
```

**归一化字段**（排障时按这些字段过滤）：`module` / `phase`(`identity|capability|route|render`) /
`decision`(`pass|skip|fallback|error`) / `evidence` / `configVersion` / `request` / `route` /
`fallback` / `duration_us`。

**日志标签**：`[TRACE]`、`[DEBUG][TextSub]`、`[DEBUG][BGI]`、`[DEBUG][CatSystem2]`、
`[DEBUG][UnityMono]`、`[DEBUG][CatSystemUnity]`、`[RenPy]`、`[Tyrano]`、`[Yuris]`、
`[DIAG][crash]`、`[DIAG][hang-watchdog]`。

**定位流程 6 步**（`docs/diagnostics.md`）：
1. 先关**所有**可选兼容功能。
2. 只开"字体名替换"。
3. 分别验证四条路径。
4. 检查引擎探测误判。
5. 对照 API 样本。
6. 记录架构 / DLL SHA-256 / 配置 / 最短复现步骤。

**已知崩溃案例（有直接价值）**：
> KRKR `0xC0000409`，`WINMM.dll+0x5f305` —— 这是**代理 DLL 自身的崩溃**，
> 说明代理劫持路径本身是风险点（见 §3.5）。

**证据等级 O/I/U**（`docs/reproduction.md`）：观测 / 推断 / 待确认。
复刻 7 步：固定样本（`Get-FileHash` 导 CSV）→ 建基线 → 收集静态证据
（`dumpbin /headers|/imports|/exports`）→ 确认身份/能力/路由 → 提取最小契约表 →
在正确边界实现 → 验证矩阵（5 行 × Win32/x64 分别执行）。

### 1.14 构建与发布

**观测**（`docs/build-and-release.md`）：VS2022 + v143 + Win10 SDK。

| 脚本 | 作用 |
|---|---|
| `build_x32.bat` | 编 Win32 → `Release/winmm.dll` |
| `build_x64.bat` | 编 x64 → `x64/Release/winmm.dll` |
| `build_release.bat` | 加 `rebuild` 参数可全量 |
| `pack_release.bat` | 打包 |

Release 优化：LTCG、`/Os`、`/Gw`、关 RTTI、`_HAS_EXCEPTIONS=0`、`/OPT:REF`、`/OPT:ICF`。

**🔴 硬约束**：
- **不允许 C++ 异常跨 DLL 导出 / Win32 hook / 引擎回调传播**。Release 用返回值 + 边界检查 + SEH。
- Post-Build 用 `tools/upx/upx.exe --best --lzma` 压缩；`SIMPLEFONTHOOK_SKIP_PACK=1` 可跳过。

**产物规模**：`Release/winmm.dll` 255,488 字节（2024-09-18）、`x64/Release/winmm.dll` 281,088 字节。

**回滚**（官方流程）：先**退出目标程序**，再恢复原 `winmm.dll` 和 `FontHook.ini`；
**不要在进程加载 DLL 时覆盖文件**。

### 1.15 源码规模（用于评估改造/维护成本）

总计约 **16,007 行**。最大文件：

| 文件 | 行数 |
|---|---|
| `font_hooks_text_substitution_map.cppinc` | 8,741 |
| `font/font_patcher.cpp` | 1,202 |
| `ui/internal/font_picker_font_list.cppinc` | 808 |
| `hooks/internal/font_hooks_state.cppinc` | 595 |
| `ui/internal/font_picker_apply_config.cppinc` | 548 |
| `hooks/internal/font_hooks_text_render.cppinc` | 501 |

**推断 I-04**：这么大且高度专业（Detours + SFNT 字节操作 + 18 引擎适配）的代码库，
**源码级 fork 集成的代价远高于"当作二进制载荷使用"**。这是我方方案的第一条设计依据。

### 1.16 模块结构总览

```
SimpleFontHook/
├── dllmain.cpp            DllMain：ATTACH → FontHooks::Install；DETACH → PrepareForProcessExit
├── winmm_proxy.h          ~180 行 /export 转发全部 winmm 导出
├── utils.cpp              Trace / INI 读写 / LoadCustomFont / GetFontEnglishName
├── font/
│   ├── font_patcher.{h,cpp}    SFNT/TTC 表修补（OS2/垂直度量/name/cmap/TTC 提取）
│   └── README.md
├── hooks/
│   ├── font_hooks.cpp     108 行聚合 TU，按序 include internal/**
│   ├── hook_policy.{h,cpp}    ShouldReplaceHdcFont / ShouldInstallHook / 4 种 SkipReason
│   └── internal/
│       ├── font_hooks_install.cppinc     Install / PrepareForProcessExit / NotifyConfigChanged
│       ├── font_hooks_state.cppinc       全部 org* 指针与全局状态（595 行）
│       ├── font_hooks_runtime.cppinc      DetectCharset / EnsureInitialized / ReplaceHdcFont
│       ├── font_hooks_font_creation.cppinc  CreateFont* Hook + LOGFONT 改写
│       ├── font_hooks_text_render.cppinc    8 个绘制 Hook（501 行）
│       ├── font_hooks_text_substitution*.cppinc  文字映射（含 8741 行映射表）
│       ├── font_hooks_codepage_redirect.cppinc   代码页重定向
│       ├── font_hooks_platform.cppinc    GDI+ / DirectWrite / LoadLibrary（305 行）
│       ├── font_hooks_font_queries.cppinc  度量/枚举/身份/字体数据查询
│       ├── model/font_hooks_replacement_cache.cppinc  源/替换双向映射 + 版本闸门
│       ├── engines/                     18 引擎适配器 + engine_file_dispatch/hooks
│       └── queries/
└── ui/                    独立线程自绘字体选择器（6 个分片）
```

**聚合翻译单元（`.cppinc`）机制**：`font_hooks.cpp` 按**固定顺序** include `internal/**/*.cppinc`，
使原始 API 指针、Detours 目标、引擎状态保持**内部链接**；`.cppinc` **不单独编译**。
`AGENTS.md` 明确：**不把 `.cppinc` 单独编译**、**不绕过 `engine_file_dispatch.cppinc` 复制文件重定向逻辑**。

---

## 2. 集成到我方管理器的最小改造方案

> ⚠️ 本节所有涉及我方管理器内部结构的描述均为**建议方案**，前提假设已标注。
> 凡需要我方实际信息的地方，全部收在 §2.7「待补充项」，**不做臆测**。

### 2.0 方案概览：三条可选路线

| 路线 | 做法 | 优点 | 缺点 | 建议 |
|---|---|---|---|---|
| **A. 二进制载荷 + 沙箱编排** | 不碰 C++，管理器负责"生成 INI + 投放/清理 winmm.dll + 启动" | 改造量最小；跟随上游升级只需换 DLL；不承担 16k 行维护 | 无法深度定制（如自定义 UI、自定义日志） | ✅ **推荐** |
| **B. 源码级 fork 集成** | 把 `font/` + `hooks/` 编进我方进程，改为进程外注入 | 完全可控；能与管理器 UI 深度打通 | 需维护 16k 行 C++ + 双架构构建；跨进程注入 SDK 自研 | ❌ 成本过高 |
| **C. 混合：载荷 + 外置配置器** | 用 A 的载荷，但**不复用其内置 picker UI**，由我方 UI 生成 INI | 兼顾低成本与好体验 | 需确认"不启动 picker 也能正常工作" | ✅ **推荐（A 的落地形态）** |

**选 A/C 的三条依据**：
1. **I-04**：16k 行专业代码，维护成本远超收益。
2. **载荷天然可隔离**：`winmm.dll` + `FontHook.ini` 是**每游戏目录一份**的天然沙箱单位，与管理器"多游戏"模型完美对齐。
3. **配置面很窄**：我方只需生成 INI，**不需要链接任何 C++ 库**。

### 2.1 部署形态：每游戏一个沙箱目录

**核心设计**：**绝不**把 `winmm.dll` 丢进游戏原始安装目录（污染用户文件、卸载困难、多游戏冲突）。
而是建立**独立的启动沙箱**：

```
{数据根}/game_sandbox/{game_id}/
├── winmm.dll              ← 从管理器内置资源按游戏位数拷贝
├── FontHook.ini           ← 管理器生成
├── fonts/                 ← 用户为该游戏选的字体（或引用外部路径）
│   └── user_pick.ttf
└── launch.json            ← 我方自己的启动元数据（记录真实 exe 路径等）
```

**启动时**：管理器不直接在沙箱目录启动（因为游戏 exe 不在那里），而是采用
**「代理启动」**：在沙箱目录放一个极小的**转发器**，或使用 `CreateProcess` 的
**exe 路径 = 游戏真实 exe** 但 **工作目录/搜索路径指向沙箱**。

⚠️ **关键难点 U-01**：Windows 的 DLL 搜索顺序里，
**`exe` 所在目录优先于 `PATH` 与当前工作目录**（取决于安全搜索模式与 manifest）。
若游戏 exe 不在沙箱目录里，仅设"当前工作目录"**不保证** winmm.dll 被优先加载。

**三种可行做法（需实测选一）**：

| 做法 | 说明 | 风险 |
|---|---|---|
| **① exe 硬链接/符号链接进沙箱** | 在沙箱目录建到游戏 exe 的 hardlink/symlink，从沙箱启动 | hardlink 跨卷不可用；symlink 需权限；部分引擎按 exe 路径定位数据目录会找错 |
| **② exe 快捷方式改"起始位置"** | 不可靠，快捷方式不影响 DLL 搜索 | ❌ 不推荐 |
| **③ `CreateProcess` 时用 `lpApplicationName` 指向真实 exe，但先 `SetDllDirectory(沙箱)`** | 进程级 DLL 搜索目录，优先级高于 System32 | 需确认目标游戏未用 `LOAD_LIBRARY_SEARCH_*` 覆盖；`SetDllDirectory` 影响子进程 |
| **④ 直接投放进游戏目录 + 备份原文件** | 最简单，命中率 100% | 污染用户目录；需严格的备份/恢复/校验机制 |

**建议**：**优先③，回退④**。③ 若实测被绕过（如游戏自带 manifest 声明 `Microsoft.Windows.SystemCompatible`），
则对**该游戏单独**降级为④，并在 UI 明确告知用户"将在游戏目录放置文件，可在设置中一键还原"。

> **U-01 待确认**：我方管理器目前如何启动游戏（`GameLaunchService` 走 launch_path）？
> 是否有能力在 `CreateProcess` 前插入 `SetDllDirectory` 或改环境变量？见 §2.7。

### 2.2 配置项：我方需要生成的 INI 最小集

**核心原则**：**只写必需项 + 用户真正需要的项**，其余让 DLL 用默认值。
理由：默认值经过上游调优（且多数引擎开关默认 `1` = 开启），乱写反而关闭功能。

**必需项（不写则整个配置不生效）**：

```ini
[FontHook]
FontNameW=<用户选择的字体族名>
```

**基础项（推荐写）**：

```ini
EnableFontHook=1              ; 总开关
EnableFaceNameReplace=1       ; ① 字体替换
FontFileName=<字体文件路径或文件名>   ; 备用：不装在系统里的字体
EnableDebugLog=1              ; 排障期开，发布期可关
```

**高级项（默认全关，UI 上作为"修复选项"折叠）**：

```ini
; —— ② 字符集伪装：解决缺字/方块 ——
EnableCharsetReplace=0
ForcedCharset=134             ; 134=GB2312, 128=ShiftJIS, 136=Big5(繁), 129=Hangul
SpoofFromCharset=0
SpoofToCharset=0
EnableCodepageSpoof=0

; —— ③ 代码页重定向：解决 CP932 硬编码乱码 ——
EnableCodepageRedirect=0
CodepageRedirectFrom=932
CodepageRedirectTo=65001      ; CP_UTF8

; —— ④ 文字映射：繁→简 ——
EnableTextSubstitution=0
TextSubstitutionMode=0        ; 0..2
TextSubstitutionCodepage=0

; —— ⑤ 垂直度量（字太高/挤在一起）——
EnableFontVerticalMetrics=0
FontAscentPermille=1000
FontDescentPermille=-250
FontLineSpacing=0
```

**⚠️ 我方生成 INI 的三条格式纪律**（依据 §1.8 观测）：

1. **必须写 UTF-8 BOM**（`0xEF 0xBB 0xBF`）——否则含中文的字体名可能被误解析。
2. **字体族名要写 `FontNameW`**（宽字符语义），不要只写 `FontNameA`。
3. **不要用旧键名**（`Enable` / `FromCodePage` / `ToCodePage` / `CodePageConvertEnable`）——
   它们只是兼容回退，写新键更明确。

**🔴 版本兼容纪律**：我方**不应硬编码**"当前所有键"。
上游加键/改键时我方若仍写死旧集合，可能出现"写了但被忽略"或"缺键回退"。
建议：**我方维护一份"键清单 + 默认值"的配置元数据文件**，随内置 DLL 版本一起升级，
生成 INI 时以该元数据为准。（这是我方**唯一**需要跟上游同步的东西。）

### 2.3 注入时机：何时投放、何时清理

| 时机 | 动作 |
|---|---|
| **用户开启"为游戏换字体"** | 生成沙箱目录 → 拷贝对应位数的 `winmm.dll` → 生成 `FontHook.ini`；**不启动游戏** |
| **用户更换字体** | 只**重写 `FontHook.ini`**（增量、原子替换）；沙箱其余不动 |
| **用户点击启动游戏** | 按 §2.1 的做法挂载沙箱并启动；启动后**游戏进程内**自动读 INI |
| **游戏进程退出** | 管理器记录退出码；**不主动删沙箱**（下次还要用） |
| **用户关闭该游戏的换字体** | 删除沙箱中的 `winmm.dll`（或整个沙箱）；游戏目录若用过④则执行还原 |
| **卸载管理器** | 遍历所有沙箱目录清理；若有游戏目录投放则还原 |

**🔴 三个必须遵守的时机约束**（依据 §1.14 回滚流程 + 常识）：

1. **绝不在游戏运行中覆盖 `winmm.dll`**——文件被映射进进程，覆盖会失败或导致进程崩溃。
   管理器必须**检测游戏进程是否存活**（按 exe 路径/进程名），存活则拒绝写入。
2. **`FontHook.ini` 是运行时读取还是启动时读取？**
   **推断 I-05**：`LoadConfig` 在 `Install()` 里只调一次（进程 attach 时），
   之后靠 `ConfigVersion` + 各适配器 `NotifyConfigChanged` 做**进程内热更新**——
   而这些通知由**内置 picker UI 的"应用"按钮**触发。
   ⚠️ **因此：改 INI 后必须重启游戏才生效**。我方 UI 文案应明确写"修改后需重新启动游戏"，
   **不要**承诺"运行时热切换"。
3. **投放前做位数匹配**：先探测游戏 exe 是 32 位还是 64 位，再挑 `winmm.dll`。
   投错位数 → 加载失败，游戏可能直接起不来。

### 2.4 字体配置的数据结构（我方侧）

**建议**：我方侧**不要**复刻 SimpleFontHook 的 INI 键名做数据结构，而是建**我方语义模型**，
再在"生成 INI"这一步做映射。这样上游改键名时我方只改一个映射函数。

```jsonc
// 概念结构（非最终实现；字段命名待与我方现有 game.json 风格统一）
{
  "game_id": "xxxxxxxx",              // 沿用现有身份键 game.json.game_id
  "font_override": {
    "enabled": true,
    "source": {                       // 字体来源
      "kind": "user_file",            // user_file | system_font | bundled
      "path": "D:/fonts/my.ttf",      // user_file / bundled 时有效
      "family_name": "Noto Sans SC",  // 用于写入 FontNameW（system_font 时必填）
      "sha256": "ab12..."             // 便于校验文件未被替换/损坏
    },
    "profile": "default",             // 预设档：default | fix_garbled | trad_to_simp | custom

    // —— 高级项，仅在 profile == custom 时使用 ——
    "charset": {
      "replace": false,
      "forced_charset": 134           // GB2312
    },
    "codepage": {
      "redirect": false,
      "from": 932,
      "to": 65001
    },
    "text_substitution": {
      "enabled": false,
      "mode": 0,
      "codepage": 0
    },
    "vertical_metrics": {
      "enabled": false,
      "ascent_permille": 1000,
      "descent_permille": -250,
      "line_spacing": 0
    },
    "debug": {
      "log": false,                   // 排障开关，UI 上藏在"高级"
      "slow_ms": 0
    }
  },
  "sandbox": {
    "path": "{数据根}/game_sandbox/{game_id}",
    "dll_bitness": 64,                // 投放的 DLL 位数
    "dll_sha256": "...",              // 校验沙箱里的 DLL 未被篡改
    "deployed_at": "2026-10-09T12:00:00Z",
    "launch_mode": "setdll_directory" // setdll_directory | in_game_dir
  }
}
```

**"预设档 profile" 的价值**：GALGAME 用户的真实需求就那几类，
把 §2.2 里 20+ 个键**收敛成 4-5 个预设**，用户只需选一个：

| profile | 对应 | 开启的路径 |
|---|---|---|
| `default` | 我就想换个好看的字体 | ① 字体替换 |
| `fix_garbled` | 乱码/方块 | ① + ③ 代码页重定向 |
| `fix_missing_glyph` | 缺字 | ① + ② 字符集伪装 |
| `trad_to_simp` | 繁体游戏用简体 | ① + ④ 文字映射 |
| `custom` | 手动 | 用户自己勾 |

### 2.5 多游戏配置的隔离与管理

**隔离层次（从强到弱）**：

| 层次 | 做法 | 隔离强度 |
|---|---|---|
| **目录隔离** | 每游戏一个 `game_sandbox/{game_id}/`，各含独立 `winmm.dll` + `FontHook.ini` | ✅ **强**，互相完全不可见 |
| **进程隔离** | 每个游戏是独立进程，DLL 只在自身进程内 Hook | ✅ **强**，天然隔离 |
| **字体资源隔离** | 用 `FR_PRIVATE` 注册字体，只对当前进程可见 | ✅ **强**（观测 O-08） |
| **INI 隔离** | 每游戏自己的 `FontHook.ini`，路径由 DLL 所在目录决定 | ✅ **强** |

**结论 I-06**：**SimpleFontHook 的设计天然就是"每进程一份配置"**，
与"多游戏各自独立配置"的需求**完全对齐，几乎不需要额外做隔离工作**。
这是选它的一个**被低估的优势**。

**管理侧要注意的三件事**：

1. **`game_id` 复用现有身份**：缓存 key 必须按游戏身份，不能按目录名（与既有 ADR 一致）。
2. **沙箱目录要纳入我方存储护栏**：删除沙箱文件时必须过 `PathHelper.isInsideAppStorage`
   （符合现有 ADR-007 归属判定），**绝不**对游戏原始目录做无护栏删除。
3. **"一键恢复默认"的两种含义要分清**：
   - **数据层恢复**：删除/禁用该游戏的 `font_override` 配置 + 移除沙箱 → 游戏回到原样。
   - **游戏目录恢复**：若走过 ④（投放进游戏目录），必须**用备份还原原 `winmm.dll`**；
     若原本没有 `winmm.dll`（多数情况），则删除我方投放的那份。
   ⚠️ 备份必须记录**原文件是否存在 + SHA-256**，不能只记"我放过一个文件"。

**共享字体池（可选优化）**：多个游戏选同一字体时，沙箱里不必各存一份大字体文件，
用引用路径 + 哈希校验即可。但注意 `FontFileName` 若为**相对路径**，是相对 **DLL 目录**解析的，
写相对路径要确认基准目录。

### 2.6 最小改造清单（落地视角）

| # | 改造项 | 工作量 | 说明 |
|---|---|---|---|
| 1 | 内置两种位数的 `winmm.dll`（+ 版本号）作为资源 | 小 | 直接取上游 Release 产物；记录来源版本与 SHA-256 |
| 2 | INI 生成器（我方模型 → INI 文本，UTF-8 BOM） | 小 | 唯一需要跟上游同步的映射层 |
| 3 | 游戏位数探测 | 小 | 读 PE 头 `Machine` 字段（`0x14c`=x86 / `0x8664`=x64） |
| 4 | 沙箱目录管理（建/拷/校验/删） | 中 | 必须接我方存储护栏 |
| 5 | 启动挂载（`SetDllDirectory` 或投放） | **中-大** | **最不确定的一环**，见 U-01 |
| 6 | 设置 UI（字体选择 + 预设档 + 一键恢复） | 中 | 复用我方现有设置页范式 |
| 7 | 排障入口（打开沙箱目录 / 打开 `FontHook.trace.log` / 导出诊断包） | 小 | 直接决定问题反馈质量 |
| 8 | 进程存活检测（防止运行中改文件） | 小 | 按 exe 路径匹配进程 |

**合计**：除第 5 项外，其余都是"常规工程量"，**整体属于中小型特性**。

### 2.7 待补充项（**不臆测**，需我方信息才能定稿）

> 以下每项都会实质影响方案细节，请补充后我再出可执行的实施清单。

**A. 技术栈与进程模型**
- A1. 管理器的技术栈与语言（Flutter？结合 `D:\CTLIB` 下 `pubspec.yaml` 推断是 Flutter，
  但**注入与进程编排是否能落到原生层（Windows runner / FFI）**，需确认。
- A2. 是否有现成的 Windows 原生插件/FFI 层？还是需要新写？
- A3. 是否支持"进程外独立小工具"（例如一个 C++/Rust 的 launcher stub）作为可选形态？

**B. 注入入口（最关键）**
- B1. 当前启动游戏的**唯一事实源**是 `launch_path`（已从项目记忆中读到），
  但具体走哪个服务/函数？是否能在此处插入 `SetDllDirectory` / 环境变量 / 改 `lpCurrentDirectory`？
- B2. 是"管理器直接 `CreateProcess`"还是"交给系统 Shell 打开"？
  后者**无法控制 DLL 搜索路径**，会直接决定能否用路线③。
- B3. 有无沙箱/权限限制（某些游戏需管理员权限、或以兼容模式运行）？
- B4. 用户在管理器设置中是否允许"投放文件进游戏目录"这个行为？（关系到路线④能否作为回退）

**C. 配置存储**
- C1. 现有游戏配置的存储位置与格式（从项目记忆看有 `game.json`，`format_version=4`）——
  `font_override` 字段是**并入 `game.json`** 还是**独立文件**？
- C2. 若并入 `game.json`，是否需要升 `format_version`？
  （参照既有 ADR-012：**纯新增可空字段 ?? 默认，可不升版本**——本特性恰好符合。）
- C3. 数据根目录的具体路径（用于拼 `game_sandbox/`）。

**D. 字体来源**
- D1. 用户字体是"从系统字体列表选"、"自己指定 ttf/otf 文件"，还是两者都要？
- D2. 是否需要管理器**内置**几款合规字体（需确认 OFL/Apache 等授权与分发范围）？
- D3. 字体文件很大（CJK 全量 15MB+），是否需要我方的子集化能力？
  （注：`features/font_strategy.md` 已有子集化方法论，但那是**管理器自身 UI 字体**的，
  能否复用于用户字体是两回事——用户字体若子集化会导致游戏里缺字，**大概率不能子集化**。）

**E. 产品与法务**
- E1. 是否允许"向用户目录投放 DLL"这类行为的授权条款（安装器/用户协议层面）？
- E2. SimpleFontHook 的**许可证**是什么？（本轮调研**未读 LICENSE 文件**，
  若采用路线 A 分发其二进制产物，**必须先确认许可与再分发条件**。）
- E3. 崩溃责任边界：注入第三方 DLL 导致游戏崩溃时的用户提示与免责说明。

**F. 上游跟随策略**
- F1. 是"固定某个上游版本"还是"定期跟进"？若跟进，谁负责回归测试？
- F2. 是否接受"上游产物 UPX 压缩"带来的**杀软误报**风险？（见 §3.6）

---

## 3. 边界情况与风险

### 3.1 位数不匹配（32/64 位）

**事实**：SimpleFontHook **分别构建** Win32 与 x64 两份 `winmm.dll`
（`Release/winmm.dll` 255KB / `x64/Release/winmm.dll` 281KB）。

**风险**：
- 32 位游戏加载 64 位 DLL → **加载失败**。游戏可能：① 静默忽略（winmm 导入失败通常表现为**无声/无计时**，不一定崩）
  ② 直接报错退出。取决于引擎对 `LoadLibrary`/静态导入失败的容忍度。
- 反之亦然。

**必须做**：
1. **投放前探测位数**：读 exe PE 头 `IMAGE_FILE_HEADER.Machine`（`0x014c` = I386，`0x8664` = AMD64）。
   ⚠️ **不要**用"文件名含 64""目录名含 x64"这类启发式判断。
2. **投放后再校验一次**：比对已拷贝文件的 PE `Machine` 与目标。
3. **UI 上明确展示**：设置页显示"已为 32 位游戏部署 32 位组件"。
4. **异常兜底**：若游戏启动后**立刻异常退出**且退出码异常，提示用户"可能是字体组件与游戏不兼容，可一键关闭换字体"。

**推断 I-07**：位数检测失败（如 exe 损坏、非常规 PE）时**必须默认不投放**，
宁可"没换字体"也不要"游戏起不来"。

### 3.2 GDI 与 DirectWrite 的差异

| 维度 | GDI | GDI+ | DirectWrite |
|---|---|---|---|
| 覆盖的老游戏 | **绝大多数** | 部分 | 较少（新引擎/Unity/Chromium） |
| Hook 方式 | Detours 导出函数 | Detours 导出函数 | **导出 + vtable 双层** |
| 加载时机 | 启动即有 | 惰性（`LoadLibraryW("gdiplus")` 时补挂） | **延迟**（可能运行很久才加载 `dwrite.dll`） |
| 字体注册 | `AddFontResourceExW` / `AddFontMemResourceEx` | `GdipNewPrivateFontCollection` + `GdipPrivateAddFontFile` | 依赖系统字体或格式对象 |
| 主要风险 | 替换被游戏内部缓存绕过 | 私有集合加载失败 → 退回原集合（字体没换） | **vtable 未挂上时静默无效果** |

**关键风险点**：
1. **DirectWrite 的延迟加载**：`AttachDirectWriteHooks` 在 `dwrite.dll` 未加载时**只记日志并返回**；
   靠延迟线程轮询（200 次，最长约 40×10 + 160×50 = 8.4 秒）。
   **若游戏在 8.4 秒之后才加载 `dwrite.dll` → Hook 永远不会挂上**，
   表现就是"这个游戏换字体没反应"。
2. **vtable Hook 失败是静默的**：`newDWriteCreateFactory` 里 Trace 了
   `factory vtable hook status=%ld`，但**用户看不到**。
   我方排障入口必须能把这行日志暴露出来。
3. **GDI+ 私有字体集合加载失败**：`LoadGdiPlusPrivateFont` 失败时
   `newGdipCreateFontFamilyFromName` 会**退回原集合**——字体没换，但**不报错**。
   同样是"静默无效果"。

**我方对策**：
- 排障包里必须包含 `FontHook.trace.log`，并在 UI 上给出**判读指引**
  （例如"若日志中有 `delayed hook timed out`，说明该游戏渲染路径不支持本次替换"）。
- **不要**向用户承诺"所有游戏都能换"。

### 3.3 字体缺失与回退

**可能缺失的环节**：

| 环节 | 现象 | 源码依据 |
|---|---|---|
| `FontNameW` 缺失 | **整个配置不应用** | `LoadConfig` 直接 `return false`（O-07） |
| `FontNameW` 指向的字体不存在 | 系统按字体回退表选一个相似字体；**字形可能完全不同** | GDI 本身行为 |
| `ForcedFontNameW` 为空 | 强制 `EnableFontHook=false`、`EnableFaceNameReplace=false` | `LoadConfig`（O-07） |
| `FontFileName` 指向的文件不存在 | `LoadCustomFont` 会尝试 `galgame*.ttf` 再 `*.ttf` 目录搜索；都失败则不加字体资源 | `LoadCustomFont`（O-08） |
| TTC 里找不到该 face | `ExtractFontFromCollectionByName` 返回 false → 不重建 | `font_patcher.cpp:900` |
| 字体表修补失败 | `Patch*` 返回 false → 保持原始输入（**不产生半成品**） | `font/README.md` 不变量 |
| `YurisAtlasCodepage` 非法 | 夹取为 0 | `LoadConfig` 夹取 |

**必须做**：
1. **字体选择时校验存在性**：用户在 UI 选完字体后，管理器**先确认**
   字体族名与文件都可用，再写 INI。
2. **不写空 `FontNameW`**——这是唯一会导致"整个配置静默失效"的坑。
3. **字体文件建议复制进沙箱**（或至少记录绝对路径 + SHA-256）：
   用户可能移动/删除原文件；`FontFileName` 若写相对路径是相对 DLL 目录解析的，容易搞错基准。
4. **字体家族名要精确**：`FontNameW` 匹配的是**字体族名（family name）**，
   不是文件名。同名不同字重（如 "Noto Sans SC" vs "Noto Sans SC Bold"）表现不同。
   我方若从系统字体枚举，应把**可选的族名**直接给用户选，不要让用户手打。

### 3.4 启动器 / 反作弊 / DRM 冲突

**三类风险**：

| 类型 | 机制 | 后果 |
|---|---|---|
| **启动器二次加载** | 很多日式游戏有 `setup.exe` / 启动器，**启动器与主程序可能不同位数**，或启动器本身也导入 winmm | 需**分别部署**两份 DLL；或只对主程序部署 |
| **反作弊/反调试** | 检测 DLL 是否被 Hook、检测模块列表、检测 Detours 特征 | 可能**拦截启动**或**直接判定作弊** |
| **DRM/加壳** | 已加壳（如 SafeDisc、Themida）的 exe 可能校验自身目录文件完整性 | 我方投放的 `winmm.dll` 会被视为**文件被篡改** |

**重要判断**：
- **GALGAME 领域反作弊极少**，DRM 多见于旧商业作品。
- 但 **`docs/diagnostics.md` 明确记录了一个代理 DLL 崩溃**：
  `0xC0000409`（栈缓冲区溢出/安全 cookie 校验失败）+ `WINMM.dll+0x5f305`
  → **说明代理路径本身就是脆弱点**。

**我方对策**：
1. **默认不投放进游戏目录**（路线③优先），降低触发文件完整性校验的概率。
2. **提供"某游戏不适用"的排除清单**：若某游戏已知冲突，UI 直接不给这个选项。
3. **崩溃检测**：记录启动后 N 秒内的异常退出；若发生，下次启动该游戏时**提示并默认禁用换字体**。
4. **绝不修改游戏 exe 本体**——只做目录级 DLL 投放/搜索路径注入。
5. **加壳游戏**：我方**无法**可靠判断是否加壳，因此不做自动判断，只提供"关闭"开关。

### 3.5 注入失败的提示与回滚

**失败模式与提示设计**：

| 失败模式 | 检测方式 | 用户提示 | 自动动作 |
|---|---|---|---|
| DLL 位数不匹配 | PE 头比对 | "该游戏是 32/64 位，已部署对应组件" | 部署前拦截 |
| 游戏未导入 winmm | 启动后 `FontHook.trace.log` **不存在** | "该游戏可能不支持字体替换" | 记录并标记该游戏"不可用" |
| 游戏目录不可写 | 拷贝失败 | "无法写入游戏目录，请以管理员运行或改用手动模式" | 回退到沙箱模式 |
| 游戏启动即崩溃 | 退出码异常 + 时长 < N 秒 | **"字体组件可能导致游戏异常，已自动关闭换字体"** | **自动禁用 + 还原文件** |
| 字体没生效 | 日志有 `decision=skip` | "已应用，但该游戏使用了内置字体资源，可能无法替换" | 仅提示 |
| DWrite vtable 未挂上 | 日志 `delayed hook timed out` | "该游戏渲染方式较新，暂不支持" | 标记能力受限 |

**回滚机制（必须幂等）**：

```
还原(game_id):
  1. 若游戏进程存活 → 拒绝，提示先退出游戏
  2. 若曾投放进游戏目录 (launch_mode == in_game_dir):
       - 若备份记录"原本存在 winmm.dll" → 用备份文件覆盖还原 + 校验 SHA-256
       - 若备份记录"原本不存在"          → 删除我方投放的文件
       - ⚠️ 若备份文件丢失 → 不猜测，明确告知用户"需要手动处理"并给出路径
  3. 删除/清空沙箱目录（过 PathHelper.isInsideAppStorage 护栏）
  4. 清空 font_override 配置（或 enabled=false）
  5. 重新生成一份"无字体覆盖"的启动配置
```

**🔴 备份纪律**：
- 备份**必须**记录：原文件是否存在、SHA-256、备份时间、备份文件路径。
- **不可**只备份"我覆盖过的文件"——"原本不存在"这个信息**同等重要**（否则还原时不知道该删还是该恢复）。
- 参照既有 ADR-007（**归属存疑永远保留**）——若无法确定某文件是否我方投放，**保留不删**。

### 3.6 其他风险

| 风险 | 说明 | 对策 |
|---|---|---|
| **杀软误报** | 上游产物用 **UPX 压缩**（`--best --lzma`）；UPX 是恶意软件常用壳，**极易误报** | ① 用 `SIMPLEFONTHOOK_SKIP_PACK=1` 跳过压缩（体积变大但误报降低）；② 或自行重签名；③ 提交白名单 |
| **许可证 / 再分发** | **本轮未读 LICENSE**；若采用路线 A 需**分发其二进制产物** | 🔴 **必须**先确认许可证与再分发条款（见 E2） |
| **上游升级断裂** | 我方依赖的具体键名/行为可能随上游变化 | 维护配置元数据层（§2.2）；固定版本 + 有意识升级 |
| **多游戏并发** | 用户可能同时开两个游戏 | ✅ 天然安全（每进程独立 INI + 沙箱 + FR_PRIVATE 字体） |
| **字体侵权** | 用户自带商用字体用于游戏 | 我方只做技术通道；**不内置**来源不明的字体 |
| **性能** | 全局 Hook 影响启动时间；`FontHook.trace.log` 每会话重建、可能增大 | 发布期关 `EnableDebugLog`；只在排障期开 |
| **日志泄露隐私** | `FontHook.trace.log` 在**游戏目录**，含字体名等 | 我方"导出诊断包"时要提示用户检查内容 |
| **`--type=` 子进程** | Chromium 类引擎会 fork 大量渲染子进程；上游在 picker `Init` 里对 `--type=` 直接返回 | 我方不需要处理——但**不要**误以为"子进程没 hook 是 bug" |

---

## 4. 建议的实施步骤与验证方式

### 4.1 分阶段实施路线

**Phase 0 — 前置确认（不写业务代码）**
1. 确认 SimpleFontHook 的**许可证**与二进制再分发条件（阻塞项 E2）。
2. 补全 §2.7 的待补充项，特别是 **B1/B2**（启动链路能否注入 DLL 搜索路径）。
3. **手工验证路线③可行性**：拿一个真实 galgame，手工把 `winmm.dll` + `FontHook.ini`
   放进游戏目录，`SetDllDirectory` 指向该目录启动，看是否生效。
   → **这一条是整个方案的技术验证基石，必须先过。**

**Phase 1 — 最小可用（单游戏、无 UI）**
4. 内置两种位数 DLL + 版本元数据。
5. 写 INI 生成器（只支持 `default` profile：`FontNameW` + `EnableFontHook` + `EnableFaceNameReplace`）。
6. 手动构造一个沙箱目录，跑通"选字体 → 生成 INI → 启动 → 生效"闭环。
7. 验证 `FontHook.trace.log` 能正常产生并解析。

**Phase 2 — 管理器集成**
8. PE 位数探测 + DLL 投放 + 沙箱管理（接存储护栏）。
9. 启动挂载（Phase 0 选定的方案）。
10. `font_override` 配置持久化（并入 `game.json`，遵循 ADR-012 不升版本）。
11. **一键恢复默认**（含备份还原路径）。

**Phase 3 — 用户界面**
12. 设置页：字体选择（系统字体列表 + 文件选择）+ profile 选择。
13. 高级折叠区：四条路径的独立开关。
14. 排障入口：打开沙箱 / 打开日志 / 导出诊断包。

**Phase 4 — 健壮性**
15. 进程存活检测 + 运行中拒绝写文件。
16. 启动后异常退出检测 + 自动禁用 + 回滚。
17. 崩溃/无效果的用户提示文案体系。
18. 已知冲突游戏的排除清单机制。

**Phase 5 — 观察与迭代**
19. 收集真实用户日志，按 §1.10 的引擎索引判断哪些引擎需要额外适配。
20. 决定是否要为高频引擎（krkr / YU-RIS / Entis 等位图字体类）做**上游跟进**或**额外方案**。

### 4.2 验证矩阵

沿用参考项目 `docs/reproduction.md` 的验证矩阵思路，**Win32 与 x64 各跑一遍**：

| # | 场景 | 输入 | 预期 |
|---|---|---|---|
| V1 | **正向样本** | 已知支持换字体的游戏（GDI 路径）+ 一个系统字体 | 文字以新字体渲染；日志 `decision=pass` |
| V2 | **非目标样本** | 管理器自身/无关进程 | 无影响；不产生沙箱 |
| V3 | **能力缺失** | KiriKiri 预渲染 TFT 类游戏 | **不崩溃**；日志有 `skip`/`fallback`；提示"可能不支持" |
| V4 | **边界输入** | ① 32 位游戏投 64 位 DLL ② 字体文件被删 ③ `FontNameW` 为空 ④ TTC 字体 ⑤ 含中文/空格路径 | ①拦截或友好提示 ②字回退不崩 ③**配置整体不应用**（需我方拦截）④正确提取 face ⑤路径正常 |
| V5 | **配置切换** | 连续改字体 3 次 + 关闭换字体 + 恢复默认 | 每次重启后生效；恢复后与原状一致 |
| V6 | **位数** | 同一游戏分别 x86/x64 版本 | 各用对应 DLL；PE 校验通过 |
| V7 | **注入失败** | 只读游戏目录 / 占用文件 | 明确提示 + 回退到沙箱模式 |
| V8 | **崩溃回滚** | 人为投错位数 | 自动检测 + 禁用 + 还原 |
| V9 | **GDI+ 路径** | 一个用 GDI+ 的游戏 | 私有字体集合生效 |
| V10 | **DirectWrite 路径** | 一个用 DWrite 的游戏（尽早加载 dwrite） | vtable Hook 成功；日志 `vtable hook status=0` |

### 4.3 证据采集规范（排障包内容）

每次问题反馈，让用户导出一个诊断包：

```
diagnostic_{game_id}_{timestamp}/
├── game_info.json        { 游戏名, exe 路径, PE 位数, 是否加壳(未知), 引擎线索 }
├── font_override.json    我方配置快照
├── FontHook.ini          实际生成的 INI（可脱敏）
├── FontHook.trace.log    核心证据
├── sandbox_list.txt      沙箱目录文件清单 + SHA-256
└── dll_info.txt          我方内置 DLL 的版本号 + SHA-256
```

**判读要点**（写进我方内部文档）：
- 没有 `FontHook.trace.log` → DLL **根本没被加载**（未导入 winmm / DLL 搜索路径不对）。
- 有日志但全是 `skip` → 看 `SkipReason`（4 种，见 §1.5）。
- 有 `delayed hook timed out` → DirectWrite 路径不可用。
- 有 `[DIAG][crash]` → 代理 DLL 层崩溃，属上游问题，需记录 `WINMM.dll+偏移`。

### 4.4 每阶段的最小验证动作

| 阶段结束 | 必须完成的验证 |
|---|---|
| Phase 0 | 路线③手工跑通（真实游戏，换字体视觉生效） |
| Phase 1 | INI 能被正确读取（日志有 `ConfigVersion`，无 `FontNameW` 缺失） |
| Phase 2 | V6（双位数）+ V7（注入失败）+ 一键恢复后游戏与原状一致 |
| Phase 3 | V1（正向）+ V5（连续切换）在 UI 操作下复现 |
| Phase 4 | V8（崩溃回滚）+ 运行中改文件被拒绝 |
| 发布前 | V1–V10 全跑 + Win32/x64 各一遍 + 至少 3 个不同引擎的真实游戏 |

---

## 附录 A：本轮调研的观测清单

| 编号 | 文件 | 结论 |
|---|---|---|
| O-01 | `winmm_proxy.h` | ~180 行 `/export` 转发全部 winmm 导出 |
| O-02 | `font_hooks_state.cppinc` | 全部 `org*` 指针初值即原 API 地址 |
| O-03 | `font_hooks_install.cppinc` | 15 类 Hook 同事务挂载 |
| O-04 | `model/font_hooks_replacement_cache.cppinc` | 源/替换双向映射 + ConfigVersion 闸门 + 逻辑字体视图 |
| O-05 | `font_hooks_runtime.cppinc` | `ReplaceHdcFont` 7 步决策链 |
| O-06 | `font_hooks_text_render.cppinc` | 8 个绘制 Hook 统一模板 + 2 个特例条件 |
| O-07 | `utils.cpp` | INI 位置/必需键/BOM/兼容别名/夹取规则 |
| O-08 | `utils.cpp::LoadCustomFont` | `AddFontResourceExW` 主路径 + 内存打补丁路径 |
| O-09 | `hooks/internal/engines/README.md` | 三阶段决策、文件分派顺序、18 引擎索引、通用钩子局限 |
| O-10 | `font_hooks_install.cppinc` | `Install` / `PrepareForProcessExit` / `NotifyConfigChanged` 主干 |
| O-11 | `font/font_patcher.h` + `font/README.md` | SFNT/TTC 修补接口、大端序、范围检查、校验和纪律 |
| O-12 | `font_patcher.cpp:916-991` | `CodePageRangeBitForCharset` 位映射与 OS/2 偏移 78/82 |
| O-13 | `font_patcher.cpp:993-1009` | 垂直度量按 unitsPerEm permille，夹取范围 |
| O-14 | `font_patcher.cpp:1179-1201` | `PatchNameTableFamily` 逐面处理；`PatchCmapAliases` 不支持 TTC |
| O-15 | `ui/README.md` + `font_picker_lifecycle.cppinc` | picker 生命周期、`--type=` 跳过、配置恢复与应用流程 |
| O-16 | `docs/diagnostics.md` | 日志格式/归一化字段/6 步定位/常见问题/KRKR 崩溃案例 |
| O-17 | `docs/reproduction.md` | O/I/U 证据等级、复刻 7 步、验证矩阵 |
| O-18 | `docs/build-and-release.md` | 双架构构建、Release 优化、异常不得跨边界、回滚流程 |

## 附录 B：关键推断清单

| 编号 | 推断 | 依据 |
|---|---|---|
| I-01 | 未导入 winmm 的游戏此注入方式失效，需换代理名 | O-01 |
| I-02 | UI 不应把四条路径混成一个"换字体"开关 | `AGENTS.md` 不变量 + O-16 误开导致错误汉字的案例 |
| I-03 | 内置 picker UI 对我方用处有限，我方应"管理器里选好再启动" | `ui/README.md` + O-15 |
| I-04 | 源码级 fork 集成代价远高于二进制载荷集成 | §1.15 16,007 行 + 双架构 + 18 引擎适配 |
| I-05 | 改 INI 后**必须重启游戏**才生效（picker 的"应用"按钮才触发运行时热更新） | O-10 `LoadConfig` 只在 Install 调一次 |
| I-06 | 每进程一份 INI + FR_PRIVATE 字体，天然满足多游戏隔离 | O-07 + O-08 |
| I-07 | 位数探测失败必须默认不投放 | 崩溃代价 >> 功能缺失代价 |
| I-08 | 最优部署是"沙箱 + SetDllDirectory"，投放游戏目录仅作回退 | O-01 搜索顺序 + §3.4 文件完整性校验风险 |

## 附录 C：待补充项速查（对应 §2.7）

- **A** 技术栈与进程模型：A1 是否 Flutter + 有无原生层 / A2 是否需新写 / A3 是否可用独立 stub
- **B** 注入入口（**最关键**）：B1 启动链路能否插 `SetDllDirectory` / B2 是否 `CreateProcess` / B3 权限 / B4 是否允许投放用户目录
- **C** 配置存储：C1 并入 `game.json` 还是独立 / C2 是否升 `format_version` / C3 数据根目录
- **D** 字体来源：D1 系统字体还是文件 / D2 是否内置字体 / D3 是否需要子集化
- **E** 产品与法务：E1 投放授权 / **E2 许可证与再分发（阻塞项）** / E3 崩溃责任
- **F** 上游跟随：F1 版本策略 / F2 UPX 误报是否接受
