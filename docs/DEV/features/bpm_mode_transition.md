# 桌面 ⇄ BPM 模式切换过渡动画

> 建立日期：2026-10-03　状态：**已实现，待真机走查观感**
> 关联代码：`lib/main_container.dart`、`lib/big_picture/big_picture_manager.dart`、
> `lib/big_picture/widgets/bpm_enter_overlay.dart`
> 前身：v3.8.1「镜头推近」420ms 对称 fade+scale（`71fa7fb`，已被本文档方案替换）
> 形状探针：`.workbuddy/probe_bpm_icon/`（**对 Steam 参考截图逐行扫描**定轮廓 + 逐帧预演）

---

## 1. 需求（用户原话要义）

1. 桌面 → BPM：**生硬、不连贯**，要求加入流畅的过渡动画，使切换平滑自然、不突兀。
2. 补充明确（2026-10-03 二次确认）：期望的效果参考 **Steam 大屏切换** ——
   「进入后先是出现**画布**，画布中间有个**大手柄图标**；大手柄期间还有特效，
   像是**一个光点滑着走**，达成一个手柄的动画」，用它来表示大屏模式的**加载**。
3. BPM → 桌面：**不需要动画**，但同样要丝滑、无卡顿感、无额外延迟。
4. 不影响两种模式下的正常功能与整体性能。
5. **三次确认（2026-10-03 晚）** —— 用户贴出 Steam 截图并否掉第一版手柄：
   - 手柄**不要**十字键 / 摇杆 / 按键 / 填充 / 泛光，就照 Steam 那个**纯轮廓**来
     （宽平圆顶 + 两侧斜下 → 两个下垂握把 + 上方一个小圆）；
   - 中间过程要的是「**两个光点从同一个起点出发，轮流沿手柄轮廓勾出整个外形**」；
   - 整个流程要**更快** —— 不要让人干看着黑幕等。
   - 用户对三步机制的描述与实现一致，原话：「第一步桌面产生黑幕 → 第二步黑幕放大到
     全屏 → 第三步全屏后黑幕消失、显示 BPM；动画就是为了让这三步看起来够丝滑，
     之间有一个**会动的东西**，不要让用户干看着黑屏」。

6. **四次确认（2026-10-03 深夜，本文档当前版本）** —— 轮廓描出已经满意，要求补一个收尾：
   > 「把（手柄）边框做出来之后，也就是准备进入 BPM 界面……在这一瞬间，或者说这个
   > 瞬间之前的一小段时间，我希望在这个轮廓搭建完之后，这个手柄边框**向外发光、闪**，
   > **柔光地闪一下**，但这个一定要**微**，一定要那个**柔眼**地闪一下。」

   → 新增「**收尾柔光**」子段，见 §3.5。**总时长维持 0.99s 不变** ——
   用户明确「现在这个总时长我觉得就很舒服」。

---

## 2. 现状审计：旧实现为什么「生硬」

旧实现（替换前）由两处叠加造成：

| # | 位置（旧） | 现象 | 根因 |
|---|---|---|---|
| P0-1 | `big_picture_manager.dart:81-95`（旧 `enter()`） | 切换瞬间「先抖一下」 | 顺序是 `写偏好 → 同步窗口背景色 → 切全屏 → notifyListeners()`。**全屏切换期间屏幕上仍是桌面外壳被拉伸铺满显示器**，几帧之后才开始切壳动画 |
| P0-2 | `main_container.dart:968-980`（旧 build） | 过渡期掉帧、不连贯 | `AnimatedSwitcher` 的 `transitionBuilder` 对**整棵全屏外壳**做 `FadeTransition + ScaleTransition`：入场 BPM 树与出场桌面树在过渡期内**同时逐帧重绘**，且 `FadeTransition` 在不透明子树上是 `saveLayer` 级开销 |
| P0-3 | 同上 | 出场「多等一拍」 | 出场复用同一 tween 反向播放 420ms —— 桌面从不可见到完全可见要等 420ms，用户报告的「加了个动画反而慢」 |
| P1-1 | 同上 | 动画尾部炸一帧 | `AnimatedSwitcher` 在动画结束后才 dispose 出场子树，销毁大树的时刻落在动画尾帧 |

> 关键判断：**光加动画不解决问题** —— 不把「全屏切换」和「逐帧重绘量」一起处理，
> 动画越华丽越晃眼。用户要的「手柄 + 光点」动画属于**第三段**（加载指示），
> 必须建立在「幕布已遮住窗口抖动」这个前提上才好看。

---

## 3. 方案设计：三段式（幕布 → 手柄点亮 → 揭开落座）

### 3.1 时间线

两个控制器分工：`_bpmEnter`（幕布 alpha + 外壳缩放，进度 0→1 分两段 `animateTo`）、
`_bpmLogo`（手柄图标自身进度 0→1，固定时长）。

| 阶段 | 时间 | 屏幕内容 | 窗口 |
|---|---|---|---|
| ① 幕布合拢 | 0 → 150ms | 桌面内容被 **BPM 底色实心层**「吞没」（alpha 0→1，easeIn） | 仍是窗口尺寸 |
| ①→② 峰值 | =150ms | 整屏 = 不透明幕布；此刻**卸载桌面外壳**、下发全屏切换 | 幕布后才切全屏（观众看到的是「黑幕放大到全屏」） |
| ② 手柄描出 | 150ms → +421ms | 幕布中央**两个光点从同一点出发、一左一右沿轮廓把手柄画出来**（详见 §3.5） | 并行完成全屏 |
| ②b 收尾柔光 | 紧随 ② → +119ms | 轮廓合拢，整条边框**向外发一次柔光**、先快后慢散掉；描边本体同时轻微加粗（详见 §3.5） | 已全屏 |
| ③ 揭开 + 落座 | 紧随 ②b → +300ms | 幕布连图标一起 alpha 1→0（easeOutCubic）；外壳 `1.06 → 1.0` 居中缩放回落落座 | 已全屏 |

总时长 ≈ `150ms + max(窗口切换耗时, 540ms) + 300ms` ≈ **0.99s**（旧方案 1.37s，本次提速 28%）。
**②b 是塞进 ② 的 540ms 之内的**（`_traceTo` 0.94 → 0.78 腾出尾段），**不增加总时长**。

②与③的交界：`await sync`（窗口就绪闸门）与 `await 图标动画剩余时长` 两者都完成才进入③ ——
**谁慢等谁**。窗口若更快，动画也完整播完（否则用户只看到一闪而过，等于没有）。

### 3.2 为什么是「幕布」而不是「淡出桌面」

| 备选 | 代价 | 结论 |
|---|---|---|
| 桌面 `Opacity` 淡出 | 整棵桌面树的 `saveLayer`（4K 全屏离屏缓冲） | ✗ |
| 桌面 + BPM 对称交叉淡入淡出（旧做法） | 两棵树同时逐帧重绘 | ✗ |
| **实心色块（幕布）改 alpha 覆盖** | 单个全屏矩形的色值变化，**零 saveLayer、零离屏** | ✓ 采用 |

幕布取色 = **`BpmColors.deepBase`（BPM 自己的底色）**，而不是桌面主题色：

- 幕布揭开后露出的是 BPM 外壳，用桌面主题色会在「浅色桌面 → 深色大屏」之间闪一下；
  用 BPM 底色则全程同色，视觉上读作「进入大屏的黑色画布」（与 Steam 一致）。
- 配套：`BigPictureManager._syncWindowBackground` 在**入场**时改传 BPM 底色
  （出场仍传桌面主题色）—— 否则浅色桌面主题下，全屏展开瞬间露出的新区域会闪一条白边。
- 代价：`BpmThemeController` 的调色板随系统明暗切换，故幕布颜色在**进入瞬间取一次**
  存在 `_bpmCurtainColor`，不逐帧读主题。

### 3.3 为什么把全屏切换推迟到幕布之后

旧顺序里「窗口尺寸变化」发生在**可见**的静态桌面上 → 用户看到内容被拉伸重排。
现方案把全屏切换排在幕布升起之后，尺寸变化的抖动 100% 发生在幕后。
实现上由 `BigPictureManager.enterCurtainRise` 单一常量同时驱动「推迟量」与「动画第一段」，
避免两处魔数漂移（`main_container.dart` 的 `_kBpmCurtainRise` 直接引用它）。

### 3.4 闸门：第二段起必须与窗口全屏并行

`BigPictureManager.enter()` 暴露 `enterWindowSync`（`Completer` 派生的 `Future`，
在 `finally` 中必定 complete）。入场动画在「幕布全盖」后：
先 `_bpmLogo.forward(from: 0)` 起动画，再 `await` 闸门，最后补 `await` 图标动画的剩余时长。
另有 2s 兜底超时：闸门万一未释放（原生调用卡死），过渡不会永远停在幕布上。

### 3.5 手柄图标的分镜（`BpmEnterOverlay`）

`lib/big_picture/widgets/bpm_enter_overlay.dart`。图标自身进度 `progress` 0→1，
子区间常量写在 `_SteamControllerPainter` 内：

| 子区间 | 画面 |
|---|---|
| 0.00 → 0.06 | 图标层整体淡入 |
| 0.00 → 0.18 | Steam 键小圆淡入（它是「两个光点从同一点出发」的那个点） |
| 0.03 → 0.78 | **两个光点自顶中央出发**，顺时针 / 逆时针各画一半，在底平台汇合；头部亮核 + `cherryRose` 锥形拖尾 |
| 0.78 → 1.00 | **收尾柔光**：合拢瞬间整条边框向外发一次光、先快后慢散掉；拖尾与光点同时熄灭，描边本体轻微加粗 |

> ⚠️ 描出终点取 **0.78** 而不是 0.94：0.94 只剩 6% ≈ **32ms**，闪不出任何可感知的东西。
> 前移到 0.78 后腾出 22% ≈ **119ms** 给柔光 —— 而这 119ms 本来就是「画完之后在干等」
> 的尾段，所以**总时长不变**（用户明确要求维持现有总时长）。

#### 轮廓：从参考截图**量**出来，不靠眼睛估

第一版手柄（十字键 + 双摇杆 + 四键 + 剪影填充 + 泛光）被用户否掉，原因就是
「花里胡哨、不像 Steam」。重做时改成**先把参考截图量成数字**：

1. 取亮像素包围盒 → **图标宽高比实测 1.364**（旧实现用 1.6，所以一直「又扁又圆」）；
2. 逐行扫描轮廓的左右边界（`.workbuddy/probe_bpm_icon/extract_profile.py`），得到剖面：
   **顶边只占约 74% 宽**（x 34..206），两侧斜向下外扩，**最宽点在 y≈71% 处**（x 3 / 237），
   底部两个握把收到 x≈31 / 204，**底中央是一段浅 V 平台**（y≈119）；
3. 用半高宽量描边：**≈12px/304 ⇒ 约 9.5 设计单位**（扣掉外发光取 8.4）——
   Steam 的线比第一版粗得多，这也是「不像」的一部分；
4. 小圆用亮像素外接框量：圆心 (119.6, 38.5)、外半径 14.2。

锚点（24 个，顺时针、**起点 = 顶部中央**）写死在 `_anchors`，相邻锚点间用
**Catmull-Rom 转三次贝塞尔**补曲线 ⇒ 处处相切连续，不会出现棱角。

> 🔴 参考截图（用户给的第一张）其实是**动画中间帧**：底中央那道「缺口」是两笔
> 还没合拢的地方，左侧笔画的末端还带着拖尾渐隐。别把它当成终态去复刻缺口。

#### 两个光点怎么走

- 轮廓是**单条闭合路径**，锚点起点即顶中央 ⇒ 两个光点天然同点出发；
- 用 `PathMetric`（弧长参数化）而非 `SweepGradient`（按**角度**分布，在半径大的
  握把处会明显加速，观感不匀）：
  - 顺时针笔 = `metric.extractPath(0, headFwd)`，`headFwd = travel × L/2`
  - 逆时针笔 = `metric.extractPath(headBack, L)`，`headBack = L − travel × L/2`
  - 两笔各覆盖一半弧长 ⇒ 同一时刻同速，在**弧长中点 = 底平台**汇合；
- 拖尾 18 段分段线性近似锥形（宽 `1.4 + 4.6·(1−t)`，alpha `(1−t)^1.6`），
  采样时把 `s` 夹在 `[0, L]`，越界段自动退化（起笔瞬间自然没有尾巴）；
- **绘制进度用 `Curves.easeInOutSine`**，不是 `easeInOutCubic`：后者前重后轻，
  逐帧预演发现 `t=0.70` 就已经画完 97%，最后三成时间在干等。换 sine 后
  0.30 / 0.50 / 0.70 / 0.85 对应 20% / 52% / 83% / 97%，全程匀速感。

#### 收尾柔光（轮廓合拢后向外发一次光）

`_paintGlow()`，画在**最底层**（描边之下），辉光从轮廓背后渗出来。

🔴 **必须用填充路径 + `BlurStyle.outer`**。`outer` 的语义是 `blur(shape) − shape`，
拿到的是**形状之外**的雾。若偷懒改成「描边 + 模糊」，环带的**外侧和内侧会一起发光**，
手柄内部会被点亮 —— 那就不叫「向外发光」了。

| 项 | 取值 | 作用 |
|---|---|---|
| 窗口 | `t` 0.78 → 1.00（≈119ms） | 与合拢同刻起步，到图标段结束正好散尽 |
| 强度包络 | 前 30% `easeOutCubic`，后 70% `(1−y)^1.7` | **先快后慢**才读作「闪」；反过来是「渐亮」 |
| 峰值 | `_glowPeak = 0.68` | 实机观感定稿值（开发者自选），调这一个数就能改强弱 |
| 扩散 | σ = `_stroke × (0.9 → 3.2)`，随 `easeOutCubic` 变大 | 光从贴着轮廓一路散开 |
| 两层 | 外层 `α×0.55` @ σ；内层 `α` @ `σ×0.45` | 外层负责「散开」，内层负责「贴着边框亮起来」 |
| 描边增益 | `_glowGain = 1.15` | 闪光期描边本体加粗，读作「边缘自己亮了一下」 |

🔴 **柔光色不能复用描边色** —— 两套调色板的底色和主色恰好是反的：

| 主题 | `deepBase`（幕布） | `textPrimary`（描边） | 复用描边色做辉光的后果 |
|---|---|---|---|
| Cinema（深） | `#0C0F16` 黑 | `#FFF7F8` 白 | ✅ 白光，正确 |
| Ocean（浅） | `#F1F8FF` **白** | `#11395C` **深蓝** | ❌ 白底上渗出深色阴影，读作**发黑** |

故 `glow = isDark ? textPrimary : cherryRose`（浅色取亮蓝 `#2E9BE6`）——
与既有的 `spark` 分支同一思路。

🔴 **画布四周必须留白**：`_glowMargin = _stroke × _glowBlurMax × 3.3 ≈ 88.7`
（画布 ≈ 417×353，painter 先 `scale` 再 `translate(margin, margin)`，手柄仍在正中）。
高斯尾部要 ≈3σ 才衰减到不可见；σ≈26.9 时若只留 44，边缘还剩约 26% 强度，
浅色主题上能看出一条**淡淡的直角边**。

**不要指望「绘制溢出 size 不会被裁」**：`CustomPaint` 外面套了 `RepaintBoundary` /
`Transform` 之后这个行为是不确定的（`PictureLayer` 的 bounds 按 size 估），
留白才是确定性做法。这一条是在预览页里**实测撞到**的 —— SVG 侧的辉光一开始就被
`viewBox` 裁成了一个直角亮矩形，详见 §6。

#### 其它

- **配色全走 `BpmColors`**：描边 `ink = textPrimary`、拖尾 `accent = cherryRose`、
  头部亮核 `spark = isDark ? Colors.white : mistBlue`，深浅两套 BPM 调色板自适应。
- **尺寸**：`min(屏幕短边 × 0.30, 520)`（下限 240）。1080p ⇒ 324px（与 Steam 的
  图标占屏比一致，实测参考图里图标占宽 16%）。
- **退场**：揭开期淡出曲线与幕布**同一条**（easeOutCubic），并轻微放大（+6%）——
  若比幕布慢，图标会「悬浮」在已露出的大屏界面上，读作残影 bug。
- **终态不留在树里**：完成即随幕布一起消失，BPM 稳态没有任何手柄图层。

---

## 4. 关键实现约束（改这段代码前必读）

1. **根 Stack 槽位恒定**（`main_container.dart:_buildModeRoot`）
   槽位 0 = 桌面外壳，槽位 1 = BPM 层。桌面态时槽位 1 不存在、BPM 态时槽位 0
   退化为 `SizedBox.shrink()`，但**槽位 0 永不消失** —— 否则 BPM 外壳会从 index 1
   滑到 index 0，element 身份断裂 → 整个大屏外壳被重建（页面归位首页、焦点/手柄/
   背景媒体服务全部重启），动画尾部炸卡顿。
   配套约束：`_showDesktopDuringEnter` **初值必须为 false** —— 该标志只在入场动画
   第一段为 true；初值为 true 时，若 `MainContainer` 恰在 BPM 态下被重建
   （BPM 内退出登录 → 重新登录，`isActive` 仍为 true），桌面外壳会被永久挂在
   BPM 外壳背后（白占内存，氛围层呼吸/任务横幅定时器继续跑）。
   桌面态不依赖该标志（`showDesktop = !isActive || _showDesktopDuringEnter`）。
2. **BPM 层内部槽位同样恒定**（`_buildBpmTransition`）
   外壳永远在 index 0（包在恒存的 `Offstage` + `Transform.scale` 里），幕布（槽位 1）
   与手柄图标（槽位 2）是可增删的**尾随**槽位。动画结束时只删尾随槽位，不重建外壳。
3. **外壳 widget 只在模式翻转时构造一次**
   逐帧重建靠 `AnimatedBuilder(animation: Listenable.merge([_bpmEnter, _bpmLogo]), child: shell, builder: ...)`
   的 `child` 复用 —— 逐帧重建的只有外层几层包装，不含整棵大屏界面。
4. **稳态缩放必须返回精确 `1.0`**
   `RenderTransform` 对恒等矩阵走平移快路径（`proxy_box.dart:2538 getAsTranslation`），
   返回 1.0000001 会常驻一个 `TransformLayer` 并让文字变糊。故 `_bpmEnterScale` 在
   `v >= 1.0` 与 `v <= peak` 两个端点做**显式**返回，不依赖曲线端点求值的浮点结果。
5. **幕布同时吞掉过渡期输入**
   `RenderColoredBox` 命中即止 ⇒ 幕布存在的整段时间内点击不会穿透到桌面/大屏，
   天然防住「连点两次 = 进又退」。
6. **入场期间外壳 `Offstage`（不绘制但保状态）**
   幕布合拢前屏幕上必须是「桌面被吞没」；`Offstage` 仍会 layout 子级，因此
   `initState`（手柄服务、系统状态、库数据预热）照常在这 150ms 内完成，峰值后
   只需首次 paint。
7. **🔴 `animateTo` 必须走 `.orCancel` + `on TickerCanceled`**
   `TickerFuture` 在被打断时**主 future 永不完成**（`ticker.dart` 的
   `Ticker.stop(canceled: true)` 只 complete `orCancel` 那一路，`Ticker.dispose()`
   同样走 `_cancel`）。直接 `await` 会让协程永久挂起，`on TickerCanceled` 变成死代码。
8. **🔴 必须有 `_bpmRunId` 轮次闸**
   承接第 7 条：`animateTo` 被取消后主 future 永不完成，于是「退出 → 立刻再进入」时，
   上一轮挂起的协程会**在下一轮里被唤醒**；此时只判断 `isActive` 已为 true，
   旧协程会把新入场的幕布阶段直接跳过。每次模式翻转 `_bpmRunId++`，在途协程发现
   轮次变了就收工。
9. **图标层只在过渡期间存在**
   Stack 槽位条件是 `_bpmLogo.value > 0.0001 && reveal < 1.0`：稳态（`reveal == 1`）
   与出场（`_bpmLogo.value = 1.0`）都取不到，组树里不留常驻图层；`BpmEnterOverlay`
   内部在 `opacity <= 0.002` 时直接返回 `SizedBox.shrink()` 作为二重保险。
   出场把 `_bpmLogo.value` 置 1.0 也顺带 `stop()` 掉在途的图标动画，不留残影。
10. **🔴 `PathMetrics` 只能迭代一次 —— 绝不写 `isEmpty` + `first`**
    `PathMetrics.iterator` getter 每次返回**同一个**迭代器实例，而 `isEmpty` 与
    `first` 各消耗一次 `moveNext()`。轮廓只有一条 contour ⇒ `.first` 抛
    `StateError`，而这个异常抛在 `paint()` 里会被**静默吞掉整帧**。
    参见 §6.1（真机事故复盘）。要用 `outlineMetric` 缓存值；遍历多条 contour 用
    `computeMetrics().toList()`。
11. **🔴 任何 `paint()` 里的改动都要有 `takeException()` 回归测试**
    绘制期异常不崩不弹窗，只让画面**停在上一帧** —— 真机上表现为「动画没播」，
    极易误判成动画时长/参数问题。`test/big_picture/widgets/bpm_enter_overlay_test.dart`
    是模板：逐进度 pump 一遍，`expect(tester.takeException(), isNull)`。

---

## 5. 性能手法与掉帧退路

| 手法 | 作用 |
|---|---|
| 实心幕布改 alpha（非 `Opacity` 包树） | 过渡期每帧只重绘一个全屏矩形，无 `saveLayer` |
| 外壳外挂 `RepaintBoundary` + `Transform.scale` | 落座期间外壳的绘制命令被缓存，每帧只更新变换矩阵（缩放交给合成器），不重跑整棵大屏界面的 paint |
| 图标层自带 `RepaintBoundary` | 光点逐帧重绘的只有那一块 ≤520px 的画布，且**不**与幕布/外壳同帧重绘 |
| 图标尺寸按短边百分比封顶 520px | 4K 下也不做全屏量级的栅格化 |
| 轮廓每次 paint 只 `computeMetrics()` 一次（24 段三次贝塞尔） | 弧长查询的固定成本，微秒级 |
| 拖尾限 18 段、辉光仅 2 处 `MaskFilter`（两个光点各一处） | 每帧绘制调用与离屏层数量可控 |
| **收尾柔光只在 119ms（≈7 帧）内绘制**，且 `BlurStyle.outer` 打在**填充**路径上 | 两次 `drawPath` + 高斯被限制在极短窗口内，稳态不留任何图层 |
| 出场零动画（进度直达 1） | 出场每帧只有一个外壳在绘制；桌面一出现就是正确的窗口尺寸 |
| 桌面在幕布全盖时卸载（而非动画结束后） | 大树销毁的一帧被不透明幕布盖住 |

> **退路 1**：落座缩放会让外壳在 4K 下逐帧重栅格。若低端 GPU 上仍掉帧，
> 把 `main_container.dart` 的 `_kBpmEnterScale` 改为 `1.0` 即可**保留幕布 + 手柄动画、
> 去掉推近**（改常量即可，不影响任何结构约束）。
> **退路 2**：若手柄动画本身在低端 GPU 掉帧，把 `_kBpmLogoDuration` 压到 `360ms` 以内，
> 或把 `_SteamControllerPainter._paintHead` 里的头部外发光（`MaskFilter.blur`）去掉
> —— 拖尾本身已能表达「光点在走」。
> **退路 3**：若柔光那 119ms 掉帧（模糊半径最大时 σ≈27 设计单位，4K 下屏幕侧可能
> 接近 90px），先把 `_glowBlurMax` 从 `3.2` 降到 `2.2`（扩散变小、模糊半径直接变小），
> 再不行去掉 `_paintGlow` 里**外层**那一次 `drawPath`（只留内层窄光）。

---

## 6. 验证记录

| 项 | 结果 |
|---|---|
| 形状探针（**对参考截图量测**） | ✅ `.workbuddy/probe_bpm_icon/`：亮像素包围盒 → 宽高比 1.364；`extract_profile.py` 逐行扫出轮廓剖面；半高宽量出描边 8.4；小圆外接框量出圆心/半径。红线叠加比对图（`13_overlay.png`）与参考轮廓基本重合 |
| 动画预演（**Dart 同款数学**） | ✅ `dart_preview.py` 按 `bpm_enter_overlay.dart` 里逐行相同的缓动/拖尾公式渲出 6 帧分镜与 1080p 合成图，确认节奏与观感；据此发现并修掉 `easeInOutCubic` 的「前重后轻」问题 |
| 过渡时序预览（**可直接在浏览器里跑**） | ✅ `.workbuddy/probe_bpm_icon/bpm_enter_preview.html`：按 §5 真实常量 + Flutter 同款 `Cubic` 曲线复刻 0 → 990ms 全时间线（桌面 → 幕布 → 双光点描出 → **收尾柔光** → 揭开落座），带播放 / 时间轴拖动 / 阶段读数 / **柔光开关** / **柔光强度滑块** / **深浅主题切换** / **0.35× 慢放**，URL 参数 `?t=` `&theme=ocean` `&peak=` `&glow=0`。**不出 exe 就能先判断「合不合手」** |
| 柔光形态与裁剪（**无头浏览器逐帧定格**） | ✅ 在柔光窗口内取 5 个时间点定点截图、PIL 拼 contact sheet 逐帧核对：只向外、外沿无硬边、深浅两套配色都成立。**靠这一步抓到两个真 bug**：① `<filter>` region 默认只有 `-10%~120%`，辉光在元素 bbox 外被硬切；② **SVG 根元素默认 `overflow:hidden`**，超出 `viewBox` 的辉光被裁成**直角亮矩形**（截图里肉眼可见）。这两个坑就是 §3.5「画布留白」那条约束的来源 |
| 柔光峰值取值 | ✅ 由开发者在预览页**动态**里定稿：`0.68`（不是猜的，滑块拖出来的） |
| Dart ↔ 探针锚点一致性 | ✅ 脚本逐点比对：Dart `_anchors` 24 点与 Python `ANCHORS` **零失配** |
| **Flutter 真实渲染逐帧落盘** | ✅ `.workbuddy/probe_bpm_icon/render_probe_test.dart`（第 0 行注释：「copy 进 `test/` 再跑」）：用 `RepaintBoundary.toImage()` 把 painter 在**真实引擎**里的绘制导成 PNG（`.workbuddy/probe_bpm_icon/render/dark_t*.png` / `light_t*.png`）。肉眼看：双光点自顶中央同点出发 → 沿轮廓勾出 → 底平台汇合 → 柔光峰值 → 散尽，全程与设计一致。**这是本项目第一次拿到 Flutter 侧的真实画面** |
| **柔光没被画布裁出硬边（像素级）** | ✅ 对柔光峰值帧 `dark_t085.png` 扫描：画布四边像素值 = 底色量级（15）；手柄盒左右外侧（x=500 / x=780）相邻像素最大跳变 = **1**（即纯平滑梯度）；最大跳变 235 全部落在描边处。**留白取 3.3σ 有余量** |
| Dart ↔ 预览页常量一致性 | ✅ `check_constants_sync.py`：**8/8 全一致**（含主体 240 × 176） |
| 静态分析（**真实 `flutter analyze`**） | ✅ 改动文件 `No issues found!`；全 lib **613 issues / 0 error**（info + warning 均为存量基线，与本次改动无关） |
| 单元测试（新增回归测试） | ✅ `flutter test test/big_picture/widgets/bpm_enter_overlay_test.dart` → **7/7 通过**。见 §6.1：这条测试就是为下面那次真机事故立的护栏 |
| `flutter test test/big_picture/`（整目录） | ⚠️ 203 通过 / **2 失败**。失败在 `bpm_interactive_wrapper_test.dart`「未选中组件双击」`!timersPending`，**单跑同样失败、与本次改动无关**（存量问题，待单独处理） |
| 改动面 | ✅ `git status` 仅 `lib/big_picture/widgets/bpm_enter_overlay.dart`（`main_container.dart` 本轮零改动） |
| 真机走查 | ⚠️ **未做** —— 观感、4K 帧率仍需人工确认；但「到底有没有动画」已由上面的真实渲染 PNG 实证 |

### 6.1 🔴 一次真实事故：`paint()` 里的异常会**静默吞掉整帧**

开发者真机反馈：「启动 BPM 没有动画，只有黑幕，闪一下就进 BPM 了」，而预览页一切正常。

**根因**：`_SteamControllerPainter.paint()` 里曾写成

```dart
final metrics = outline.computeMetrics();
if (metrics.isEmpty) return;      // ← 消耗掉唯一那条 contour
final metric = metrics.first;     // ← 第二次 moveNext() 返回 false ⇒ 抛异常
```

- 引擎 `PathMetrics` **不记忆迭代**（`sky_engine/lib/ui/painting.dart:3198-3206`：`iterator` getter
  每次都返回**同一个** `_PathMetricIterator` 实例）；
- 而 `isEmpty` 与 `first` 各自会消耗一次 `moveNext()`（`dart-sdk/lib/core/iterable.dart:541 / 641`）；
- 手柄轮廓只有**一条** contour ⇒ `.first` 抛 `StateError: Bad state: No element`。

**为什么表现成「全黑 + 没有动画」**：异常抛在 `paint()` 内 ⇒ 冒泡到
`SchedulerBinding._invokeFrameCallback` 被 catch ⇒ 该帧 `compositeFrame()` 被跳过
⇒ 画面**停在上一帧**（正好是幕布刚全盖的黑帧）。所以整段手柄动画一帧都没上屏，
直到 `reveal` 结束、图标层被移出组树、绘制恢复正常，BPM 才「啪」地跳出来。

**修复**：轮廓的测量器**只取一次并缓存**（`static final ui.PathMetric outlineMetric =
outline.computeMetrics().first;`）+ 缓存周长 `outlineLength`。顺带省掉每帧一次 native
`PathMeasure` 分配。要遍历多条 contour 时用 `computeMetrics().toList()`。

**护栏**：新增 `test/big_picture/widgets/bpm_enter_overlay_test.dart`，用
`tester.takeException()` 把「绘制期异常」钉死 —— 覆盖淡入段 / 描出段 / 柔光段 / 终态 /
整个 `reveal` 区间。**A/B 实证**：把旧写法放回去，5 条测试立刻变红并打印
`StateError:<Bad state: No element>`；修复后 7/7 全绿。

> 📌 教训：**「绘制期异常」在 Flutter 里不会崩、不会报错弹窗，只会让画面停在上一帧**。
> 凡是 `CustomPainter` 里的逻辑改动，都必须有 `flutter test` + `takeException()` 兜底 ——
> 靠肉眼看真机很容易误判成「动画太短没看清」。

### 6.2 🔴 启动恢复路径的动画「闪现/缺失」（2026-10-04）

开发者反馈：**以大屏模式退出软件后再启动（或开机即大屏模式）**，恢复 BPM 时动画不完整
——「有点类似闪现，突然闪出来然后进入界面」。

两个叠加根因（`main.dart` `_initPostFirstFrame`）：

1. **notify 无人接收（竞态）**：`restoreFromPrefs()` 在首帧后 200ms 就触发 `enter()` →
   `notifyListeners()`，而 `MainContainer` 要等 `_checkAuthState()`（异步）完成才挂载、
   才 `addListener`。auth 更慢时这次通知**没有接收方**，入场动画协程根本没启动；
   MainContainer 之后挂载时控制器已是稳态 1.0 ⇒ 直接渲染 BPM、零动画。
2. **初始化风暴饿死动画帧**：`enter()` 本身**不等动画播完**就返回（动画在 MainContainer
   的协程里异步跑），紧接着 `ManifestService.init()` 在**主 isolate 同步解析 16.7MB YAML**
   （自述 0.3~1.5s），其后还有 VNDB 字典、截图扫描等一连串重活 —— 恰好压在手柄描出动画
   的 540ms 上 ⇒ 帧被成批跳过 ⇒ 「闪现」。

**修复（两道门闩，`BigPictureManager`）**：

- `signalShellReady()`：`MainContainer.initState`（addListener 之后）调用 →
  `restoreFromPrefs()` 先等这道闩**再 `enter()`**，保证 notify 必有人接收；
- `signalEnterAnimationDone()`：`_runBpmEnter` 收尾（finally）/ 出场直达稳态分支调用 →
  `restoreFromPrefs()` 在 `enter()` 之后再等这道闩才返回 —— 排在它后面的启动重活因此
  **全部推迟到动画收尾之后**，不再与描出动画竞争 UI 线程；
- 两道闩各带 **8s 超时兜底**：任何一环失灵（如停在登录页、MainContainer 迟迟不挂载）
  退化为旧行为，绝不悬置启动初始化。`enter()` 每轮重置动画闩，防止上一轮信号串门。

**修复后恢复时序**：loading → auth 完成 → MainContainer 挂载（桌面壳短暂露脸）→
signalShellReady → enter → 幕布 150ms 合拢（此刻重活还没开跑）→ 全屏 → 手柄描出
540ms（零竞争，流畅）→ 揭落座 300ms → signalEnterAnimationDone → 重活才开跑。

**护栏**：`big_picture_manager_test.dart` 新增 3 例 —— ① restore 先到：未 signal 前
不得 enter；② enter 返回 ≠ 动画播完，restore 等 done 才返回；③ signal 先到：restore
立即完成不被 8s 超时拖住。⚠️ 测试侧两个坑：单例 `_shellReady` 是 final Completer，
「未就绪」初态用例必须排在 signal 用例**之前**；`enter()` 内部有 150ms 幕布延迟，
handler 断言要放宽为 `contains(true)`，且断言失败时必须 try/finally 收尾悬置的
restore，否则污染后续用例。

---

## 7. 可调项与后续

| 旋钮 | 位置 | 现值 | 说明 |
|---|---|---|---|
| 幕布合拢时长 | `BigPictureManager.enterCurtainRise` | 150ms | 同时是全屏切换的推迟量 |
| **手柄动画时长** | `main_container.dart: _kBpmLogoDuration` | 540ms | **直接决定入场总时长**（2 段之外的那一段） |
| 揭开时长 | `main_container.dart: _kBpmReveal` | 300ms | 越长越从容，越短越脆 |
| 推近幅度 | `main_container.dart: _kBpmEnterScale` | 1.06 | 设 1.0 = 去掉推近（性能退路） |
| 落座曲线 | `main_container.dart: _bpmEnterScale` | easeInOutCubic | 开头缓 ⇒ 幕布还盖着时几乎不动，揭开过半才明显回落落座 |
| 幕布曲线 | `main_container.dart: _curtainAlpha` | easeIn / easeOutCubic | 控制「吞没」与「揭开」的手感 |
| 峰值进度标记 | `main_container.dart: _kBpmCurtainPeak` | 0.25 | 仅进度标记，与两段时长比例无关 |
| 图标子区间 | `bpm_enter_overlay.dart: _SteamControllerPainter` 顶部常量 | 见 §3.5 | 淡入 / 小圆 / 两笔起止 各自区间 |
| 轮廓锚点 | `bpm_enter_overlay.dart: _SteamControllerPainter._anchors` | 24 点 | 改之前先在 `.workbuddy/probe_bpm_icon/` 校形状 |
| 描边宽度 / 小圆 | `bpm_enter_overlay.dart` | 8.4 / r13.0+4.4 | 实测自参考图 |
| 拖尾长度 / 段数 | `bpm_enter_overlay.dart` | 62 / 18 | 拖尾越长越「彗星」 |
| 两笔缓动 | `bpm_enter_overlay.dart` | easeInOutSine | ⚠️ 别换回 easeInOutCubic（前重后轻） |
| **柔光峰值** | `bpm_enter_overlay.dart: _glowPeak` | 0.68 | 「闪」的强弱，**只调这一个就够**；设 0 = 关掉柔光 |
| 柔光窗口 | 同上：`_traceTo` ↔ `_glowFrom`/`_glowTo` | 0.78 → 1.00 | 窗口 = (1 − `_traceTo`) × 540ms ≈ 119ms。把 `_traceTo` 往下压可加长柔光，代价是描出更快 |
| 柔光扩散 | 同上：`_glowBlurMin` / `_glowBlurMax` | 0.9 / 3.2 | σ = 描边宽 × 此系数（最大 ≈27 设计单位）。⚠️ 改了要把 `_glowMargin` 一起看（它按 `×3.3` 自动推导，无需手改） |
| 描边加粗 | 同上：`_glowGain` | 1.15 | 闪光期描边本体的加粗倍数；设 `1.0` = 只发光、不加粗 |
| 柔光包络 | 同上：`_glowRiseEnd` | 0.30 | 前 30% 升、后 70% 散；调大 = 升得更慢，会从「闪」变成「渐亮」 |
| 图标大小 | `bpm_enter_overlay.dart: BpmEnterOverlay.build` | 短边×0.30，封顶 520 | 下限 240（指**手柄**视觉宽；画布比它大一圈） |
| 轮廓测量器 / 周长 | `bpm_enter_overlay.dart: outlineMetric / outlineLength` | 缓存的 static final | ⚠️ **别改成每帧 `computeMetrics()` 后又 `isEmpty` 又 `first`** —— 见 §6.1，会让整帧静默不上屏 |

**后续可考虑（未做）**：
- 图标下方加一条细进度条 / 「正在进入大屏幕模式」文案（Steam 有 loading 文案）；
- 给 BPM 侧加轻微暗角或模糊（Steam 的 zoom 带一点 blur）—— `BackdropFilter`/
  `ImageFilter.blur` 在 4K 全屏是重开销，需先做真机帧率验证再决定；
- 手柄轮廓可以换成别的造型（如 Steam Deck 的横握形），只需替换 `_anchors`
  并在探针里重新校形 —— 机制（单条闭合路径 + 弧长双笔）不用动。

---

## 8. 关联文件

| 文件 | 角色 |
|---|---|
| `lib/main_container.dart` | 过渡动画本体：常量、`_bpmEnter`/`_bpmLogo` 控制器、`_bpmRunId`、`_runBpmEnter()`、`_curtainAlpha()`、`_bpmEnterScale()`、`_buildModeRoot()`、`_buildBpmTransition()` |
| `lib/big_picture/widgets/bpm_enter_overlay.dart` | 手柄图标层：`_anchors` 轮廓、Catmull-Rom 闭合路径、`outlineMetric`/`outlineLength`（**缓存**的轮廓测量器，见 §6.1）、`PathMetric` 双笔弧长描出、拖尾/亮核、Steam 键小圆、**收尾柔光（`_paintGlow` + 填充路径 + `BlurStyle.outer`）**、画布留白 `_glowMargin` |
| `test/big_picture/widgets/bpm_enter_overlay_test.dart` | **回归护栏**（7 例）：逐进度 pump 一遍并 `expect(tester.takeException(), isNull)`，把「绘制期异常静默吞帧」钉死；另含组树契约（透明度 0 / reveal=1 不建画布、画布宽高比） |
| `lib/big_picture/big_picture_manager.dart` | 入场时序（notify 先于全屏切换）、`enterCurtainRise`、`enterWindowSync` 闸门、`_syncWindowBackground([color])` |
| `.workbuddy/probe_bpm_icon/` | 造型/动效探针：`extract_profile.py`（扫参考图剖面）、`mask_ref.py`、`steam_shape.py`（锚点与分镜）、`compare.py`（叠加比对）、`dart_preview.py`（按 Dart 同款数学预演）、`bpm_enter_preview.html`（过渡全时间线预览页，浏览器直开）、**`render_probe_test.dart`（把 Flutter 真实渲染导成 PNG，需 copy 进 `test/` 跑）+ `render/`（产物）**、`probe_pathmetrics_iterator.dart`（§6.1 那个坑的纯 Dart 实证）、`check_constants_sync.py`（Dart ↔ 预览页常量比对） |
| `docs/bpm_architecture.md` | §1.1 架构图与决策表、§7.2 过渡实现（已同步） |
| `docs/DEV/features/big_picture_v3_cinema.md` | §v3.8.1（旧 420ms 实现记录，已被本文档取代） |
