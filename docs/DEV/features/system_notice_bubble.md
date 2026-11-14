# 功能档案：系统提示聊天气泡（通用提示系统重构）

| 项 | 值 |
|----|-----|
| **状态** | 开发中（代码完成，待真机走查） |
| **优先级** | P1 |
| **创建日期** | 2026-10-02 |
| **最后更新** | 2026-10-02 |
| **关联需求单** | —（开发者口头需求） |
| **关联决策** | — |

---

## 1. 目标：解决什么问题

原提示系统只有一条路径：`AppSnackBar` → `ScaffoldMessenger.showSnackBar`，表现为**屏幕底部
的浮动提示条**。两个问题：

1. **丑**：与全应用的设计语言（极简、克制）格格不入；
2. **挡操作**：底部正是库页/详情页批量操作按钮所在区域，提示一弹就盖住。

目标：把所有提示（成功/警告/错误/提示）**收敛到右下角固定的用户按钮一侧**，
以 QQ 聊天「头像 + 气泡」的形态呈现——软件在跟你说话，而不是在屏幕底部拍你一下。

## 2. 用户可见行为

- 任意操作触发提示 → 右下角用户头像**正上方**冒出一条聊天气泡并向上堆叠；
- 气泡**实心语义底色 + 白字**：成功绿 / 警告黄 / 错误红 / 提示蓝；
- 每条气泡**右上角有 ✕**，可单独关掉；
- 每条气泡底部都有**倒计时细线**，到时自动收起：成功/提示 ≈2.5s、警告 8s、**错误 15s**
  （2026-10-03 开发者拍板：错误不再常驻；首版 30s 体感偏长，同日改定 15s，仍可随时 ✕）；
- 同屏最多 4 条，超出时最旧一条自动退场（带收缩动画）；
- **BPM 大屏模式**下改为挂在**顶栏用户按钮下方**，向下堆叠（该模式没有右下角按钮）。

## 3. 设计思路：为什么这么做

- **单一收口点**：全项目 125 处调用都走 `AppSnackBar.{success,error,warning,info}`。
  因此**只改这一个文件的方法体**，125 处调用零改动即自动切换形态 —— 这是本方案
  成本最低的关键。4 个方法签名一字未改。
- **挂在 `MaterialApp.builder` 而非各外壳里**：挂在 Navigator **之上**，于是
  **弹窗 / OverlayEntry / BPM 外壳全都盖不住它**。若挂在 `FloatingUserButton` 里
  （非稳定区、看起来更省事），对话框内触发的提示会被对话框遮住 —— 这是被否决的方案。
- **配色沿用旧款「实心红黄绿 + 白字」**（开发者明确指定）：色值仍取主题令牌
  `AppColors.{successGreen,warningAmber,dangerRed,infoBlue}`，随明暗主题自适应，
  不引入硬编码色。
- **不加逐条头像**：常驻的用户按钮本身就是「头像 + 气泡」里的头像，气泡用**三角尾巴**
  指向它；再加小头像会重复且与常驻按钮打架。
- **去重 + 限量**：同一「等级 + 文案」在栈内已存在时不重复入栈（只重置其倒计时），
  避免后台任务高频报同一错误刷屏；同屏上限 4 条。

## 4. 实现位置

| 文件 | 职责 | 备注 |
|------|------|------|
| `lib/services/system_notice_service.dart` | **新增** 全局提示总线（单例 ChangeNotifier） | push / dismiss / clear / 去重 / 限量 / 定时过期 |
| `lib/widgets/system_notice_bubble.dart` | **新增** 渲染层：气泡堆叠 + 双锚点 + 进出场动画 | `SystemNoticeLayer` 是唯一对外入口 |
| `lib/widgets/app_snack_bar.dart` | 改为委托：4 个方法体 push 到 service | **全项目唯一提示入口**；另 `export` 了 `NoticeLevel` |
| `lib/main.dart` | 在 `MaterialApp.builder` 的 Stack 顶层挂 `SystemNoticeLayer` | 稳定区改动，开发者已批准 |

## 5. 关键数据结构

```dart
enum NoticeLevel { success, warning, error, info }

class SystemNotice {
  final int id;                        // 进程内自增
  final NoticeLevel level;
  final String message;
  final String? title;                 // 气泡首行小标题，缺省按等级取「操作成功/注意/出错了/提示」
  final Duration? autoDismissAfter;    // null = 常驻（错误档），否则按此自动收起
  final DateTime createdAt;
}
```

默认驻留：成功/提示 2.5s、警告 8s（`_warningLived`）、**错误常驻**
（`AppSnackBar.error` 传 `duration` 可改为自动收起）。

## 6. 历史决策与踩过的坑

- **锚点定位必须在层内自建 `Align + Padding`**：`main.dart` 里用 `Positioned.fill` 挂载，
  会给子级**紧约束**；此时 `SizedBox(width: 336)` 会被 `BoxConstraints.enforce` 压回全屏宽
  （现象：气泡跑到屏幕顶部/横向铺满）。⇒ 层内必须 `Align(alignment) + Padding(...)`，
  `Positioned.fill` 只负责铺满，定位交给 Align。
- **`SizeTransition.axisAlignment` 方向**：桌面堆叠**底部固定**（贴着头像向上长）⇒
  最新一条要「从下往上」显现 ⇒ `axisAlignment = 1.0`；BPM 顶部固定 ⇒ `-1.0`。
  写反会导致新气泡出现时整个堆叠抖一下。
- **浮层必须包 `Material`**：渲染层在 Navigator 之上，没有 Scaffold 的 `DefaultTextStyle`，
  不包 `Material(type: MaterialType.transparency)` 文字会继承「纯黄双下划线」兜底样式
  （与 `animated_overlay.dart` 同坑）。
- **`AnimatedList` 的 `initialItemCount` 只在首帧生效**：锚点切换（桌面⇄BPM）时必须
  **用 `ValueKey(anchor)` 重建 State**，否则内部计数与新顺序错位 → 越界。
- **service 的通知可能发生在 build 期间**（错误路径里直接 push）⇒ 监听回调里若
  `schedulerPhase == persistentCallbacks` 则延到帧末 `addPostFrameCallback` 再同步。
- **`listener` 里不要只改列表不 `setState`**：尾巴挂在哪一条取决于列表内容，
  同步后必须 `setState` 刷新。
- **🔴 气泡右对齐必须放在 `SizeTransition` 之内**（2026-10-03 真机截图实测定位）：
  `SizeTransition` 内部实现是 `Align(alignment: Alignment(-1.0, axisAlignment), heightFactor:)`
  —— **x 分量写死 -1.0（贴左）**。在 item 外层包 `Align(centerRight)` 包住的是一个
  撑满堆叠宽度（336）的 SizeTransition，对内部完全无效 ⇒ 气泡整体贴到堆叠左缘，
  右缘距窗口右缘 193 逻辑px（应为 40），尾巴跟着偏 ≈150px。
  修法：`FadeTransition` 之内、`content` 之外包 `Align(centerRight)`。
  附：尾巴 `rightInset` 的数值链「锚点 right + rightInset + 尾宽/2 = 头像中心距右缘」
  在右对齐修复后才真正成立（桌面 40+21+7=68=40+56/2；BPM 26+15+7=48=26+44/2）。

## 7. 当前进度

- [x] 审计（旧系统唯一入口 + 44 处直连 `ScaffoldMessenger` + 2 处 `maybeOf` 封装）
- [x] `SystemNoticeService` / `SystemNoticeLayer` 新增
- [x] `AppSnackBar` 改为委托（125 处调用零改动）
- [x] `main.dart` 全局挂载 + BPM 锚点适配
- [x] 44 处直连 `ScaffoldMessenger` 全量收敛（13 文件）
- [x] 交互原型 `.workbuddy/prototypes/system_notice_bubble_preview.html`
- [x] 进程内 analyzer：`errors=0`；改动文件新增 warning = **0**（与 HEAD 基线逐条对照）
- [ ] **真机走查**（桌面四档 + 关闭 + 堆叠 + 倒计时 + BPM 锚点 + 弹窗内触发 + 窄窗口）
- [ ] 开发者终端补跑 `flutter test`

## 8. 已知问题

| 问题 | 严重度 | 是否已定位 | 备注 |
|------|--------|-----------|------|
| 未真机走查 | P1 | 是 | 本环境无法运行 GUI，须开发者验收 |
| 未跑 `flutter test` | P1 | 是 | 本环境禁建匿名管道，flutter test 跑不通 |
| BPM 顶部气泡的三角尾巴未绘制 | P2 | 是 | `tailUp` 分支只有 6px 间隙占位、没画 `_tail(up:true)`；且 `borderRadius` 收角写在右下、应随 tailUp 换右上。待 BPM 真机走查时一并修 |
| BPM 顶部气泡的三角尾巴未绘制 | P2 | 是 | `tailUp` 分支只有 6px 间隙占位、没画 `_tail(up:true)`；且 `borderRadius` 收角写在右下、应随 tailUp 换右上。待 BPM 真机走查时一并修 |

## 9. 待办

- [ ] 真机走查（尤其：**对话框内触发**的提示是否正常显示在最上层）
- [ ] 开发者终端 `flutter test test/services/system_notice_service_test.dart`
- [x] 错误档是否改自动收起 → **已拍板并落地（2026-10-03）**：错误档 **15s** 自动收起（带倒计时条；
  首版 30s 经真机体感反馈改短），并删除 16 处调用点显式传的 2~5s 短时长统一吃新默认；警告档维持 8s

## 10. ⛔ 不要动的地方

- **`AppSnackBar` 的 4 个方法签名**：全项目 125 处依赖，改名/改参=大规模回归。
- **不要把渲染层改挂到 `FloatingUserButton` 或各外壳**：会丢「高于弹窗」这一特性。
- **不要给 `SystemNoticeLayer` 加 `Positioned.fill` 之外的紧约束**：见 §6 第一条。
- **颜色不要硬编码**：必须继续走 `AppColors` 令牌，否则明暗主题会失配。
