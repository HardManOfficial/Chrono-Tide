# 外观页「系统主题」卡片排布 — 横排修复

> 建档：2026-09-19　状态：✅ 已修复（待真机视觉验收）
> 关联：`docs/DEV/features/button_system_upgrade_plan.md`（按钮体系 v3.9）、
> `docs/DEV/features/modern_light_dark_theme_plan.md`（三大系统主题）
> 提交：见 DEV_LOG 2026-09-19 条目

---

## 1. 问题现象

用户报告：设置 → 外观 →「系统主题」的三个主题按钮（暖阳 / 浅色 / 深色）

- 实际渲染为**一列竖排**，且三张卡**水平居中**；
- 期望：**一行横排**，从左到右 = 暖阳 → 浅色 → 深色，并保持卡片样式不变。

截图证据（用户提供）：三张 108×64 小方卡，x 坐标完全一致、y 每隔 72 递增。

---

## 2. 根因（不是构建版本问题，是布局陷阱）

代码位置 `lib/widgets/settings_modal.dart:3918`（修复前）：

```dart
Wrap(
  spacing: 8, runSpacing: 8,
  children: standardThemes.map((theme) {
    return InteractiveWrapper(          // ← 罪魁祸首在这一层
      onTap: ..., hoverScale: 1.04,
      child: Container(width: 108, height: 64, ...),
    );
  }).toList(),
)
```

`lib/widgets/interactive_wrapper.dart:69-77`：

```dart
child: AnimatedContainer(
  duration: ..., curve: ...,
  transform: Matrix4.identity()..translate(...)..scale(scale),
  alignment: Alignment.center,          // ← 关键
  child: widget.child,
),
```

**机制**：`Container`（以及 `AnimatedContainer`）只要 `alignment != null`，就会把子组件包进
`Align`。`RenderPositionedBox` 在**有界约束**下，`size.width = constraints.maxWidth`
（因为 `widthFactor == null` 且 `maxWidth != infinity`）——即 **Align 会撑满整行宽度**。

`Wrap` 给每个子项的约束是 `maxWidth = 整行宽度`（有界），于是：

1. 每个 `InteractiveWrapper` 的布局宽度 = 整行宽度 → 每个 run 只放得下一个 → **竖排**；
2. 卡片本身仍被 `Align(center)` 居中 → **水平居中**。

两个现象与截图完全吻合。**注释里写的「横向排列」从未真正生效过**（2026-09-13 起即如此，
不是回归，是自引入之日就存在的隐性缺陷）。

### 实验证据（负向对照，已跑完后删除）

在 600 宽容器里放同样的 `Wrap`：

| 结构 | 实测 x（三张卡） | 实测 y | 结果 |
|------|-----------------|--------|------|
| `Wrap` + `InteractiveWrapper`（修复前） | 292.9 / 292.9 / 292.9 | 22 / 94 / 166 | 竖排 + 居中 ❌ |
| `Wrap` + `SizedBox(108×64)` + `InteractiveWrapper`（修复后） | 46.9 / 162.9 / 278.9 | 22 / 22 / 22 | 同行，间距 116=108+8 ✅ |

---

## 3. 修复方式（最小变更）

**只改 `lib/widgets/settings_modal.dart` 一个文件，+10/-1 行**，纯插入、无缩进重排：

```dart
final card = InteractiveWrapper( ... );      // 原 `return InteractiveWrapper(` 改为具名局部变量
return SizedBox(                             // 新增：先给出定宽槽位
  width: 108,
  height: 64,
  child: card,
);
```

**为什么在这里修而不是改 `InteractiveWrapper`**：

- `InteractiveWrapper` 是全库共享组件（`settings_modal.dart` 就有 26 处调用），
  `alignment` 同时承担「子组件定位」与「缩放动画原点」两个职责；
  直接去掉它会影响所有调用点的布局与 hover 观感 → 违反最小变更原则。
- 在 `Wrap` 子项上先给紧约束（`SizedBox`）即可让 `Align` 不再撑满，
  卡片尺寸/造型/阴影/hover 缩放全部保持不变。

> ⚠️ **可复用规则**：`InteractiveWrapper`（或任何内部含 `alignment` 的 `Container`）
> **作为 `Wrap` / `Row` 的子项时必须先定宽**，否则会独占整行。
> 全库扫描（2026-09-19）另有 1 处同款：`lib/widgets/recent_colors_strip.dart:63`
> 的「最近颜色」条（22×22 色块，`Wrap` + `InteractiveWrapper`）——
> **尚未修复，待用户拍板**。

---

## 4. 明确不改

- `SemicirclePainter` / 主题三令牌（BUG-05）与此无关，未动。
- 卡片尺寸 108×64、圆角、边框（选中 = accent 边 + 抬升）、emoji + 名称布局：
  全部原样保留（用户要求「保持按钮样式」）。
- 主题顺序来源 `AppThemeManager.standardThemes`（= `CTTheme.values` 过滤后的枚举序
  `warmSun → frost → obsidian`，即 暖阳 → 浅色 → 深色）：未动，天然满足「左→右」要求。
- `Wrap` 的 `spacing/runSpacing = 8`：保留（窄窗时可换行，不溢出）。

---

## 5. 验证

| 项 | 结果 |
|----|------|
| `flutter analyze lib/widgets/settings_modal.dart` | 18 条 info/warning 全为存量（2406/2707/2977/3210-3221/4624 行），**0 新增 error** |
| 新增回归测试 `test/widgets/settings_theme_cards_layout_test.dart` | ✅ 通过。pump **真实 `SettingsModal`** 并切到外观页，断言：3 个 108×64 槽位、纵向中心重合（同行）、相邻间距 = 108+8、卡片文本顺序 = 暖阳/浅色/深色 |
| 全量测试 | 见 DEV_LOG（对比基线 682/0） |
| `git diff --stat` | 仅 `settings_modal.dart` 1 个文件，+10/-1 |

**未验证**：真机视觉验收（需用户人工确认观感）。

---

## 6. 遗留 / 待办

- **P1** `lib/widgets/recent_colors_strip.dart:63` 同款陷阱：`Wrap` + `InteractiveWrapper`
  直接作子项 → 色块每行只显示一个。修法同上（包 `SizedBox(22×22)`）。**待批准**。
- **P2** 建议在 `InteractiveWrapper` 的文档注释里补一句「作为 Wrap/Row 子项需先定宽」，
  或提供 `fixedSize` 便捷参数，从源头避免第三次踩坑。**待批准**。
- **P2** `settings_modal.dart:3916` 原注释「横向排列」在修复前与事实不符——已在修复处
  改为说明陷阱的注释。
