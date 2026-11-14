# 功能档案：桌面模式侧边栏收起/展开按钮（半圆 toggle）UI 适配

| 项 | 值 |
|----|-----|
| **状态** | 已上线（代码完成，待真机视觉验收） |
| **优先级** | P1 |
| **创建日期** | 2026-09-11 |
| **最后更新** | 2026-09-11 |
| **关联决策** | BUG-05（主题色令牌化）、UX-08（AnimatedPositioned）、UX-25（Tooltip/Semantics） |

---

## 1. 目标：解决什么问题

桌面模式左侧导航栏的收起/展开按钮是一个 17×34 的**半圆手绘按钮**
（`SemicirclePainter`），因造型特殊（CustomPaint 而非常规组件）长期游离于
软件 UI 体系之外：无 hover/按压反馈、无 Tooltip/Semantics、图标字重丢失。
本次在**完全保留半圆造型与静息态观感**的前提下，把交互层适配到全应用规范。

## 2. 用户可见行为

- 静止时：与改造前**逐像素一致**（t=0 时 Color.lerp 恒等原色）。
- 悬停/按压：半圆填充与描边 200ms 渐亮（与全应用 hover 时长一致），
  移出渐隐；按压显示同款渐亮（与侧栏导航项 onTapDown 复用 hover 的模型一致）。
- 悬停 400ms 后出现 Tooltip「收起侧边栏 / 展开侧边栏」（按点击后发生的动作）；
  屏幕阅读器可播报按钮语义（UX-25）。
- 位置滑动（250ms easeOutCubic）、尺寸 17×34、chevron 16px 均未变。

## 3. 设计思路：为什么这么做

1. **颜色渐变而非透明度/缩放**：全应用 hover 惯例是「背景色变化」（导航项
   `cardHoverBg` + 200ms AnimatedContainer），不缩放。半圆是 CustomPaint，
   无法用 AnimatedContainer，改用 `TweenAnimationBuilder<double>` 驱动 t、
   把 lerp 后的颜色传给 painter 现有参数——painter 零改动。
2. **渐变目标选 toggleIcon**：icon 是每个主题中对比度最高的颜色
   （主题设计器按「纸/线/字」映射），因此 6 套预设主题 + 自定义主题下
   「向 icon 渐变」方向恒正确、幅度恒可见。填充 lerp 0.14、描边 lerp 0.4。
3. **文案方向修正**：被移植的死代码 `buildSemicircleToggle`（sidebar.dart
   原 206-255 行）里 Tooltip 文案是**反的**（`isLeft→'展开侧边栏'`，实际
   isLeft=展开态点击=收起）。移植时已修正为按点击后动作描述。
4. **被否决**：阴影 hover 增强（需改 painter，超出必要范围）；半圆镜像
   翻转的补间动画（属造型变更，违反「保持设计」前提）。

## 4. 实现位置

| 文件 | 职责 | 备注 |
|------|------|------|
| `lib/main_container.dart:875-973` | `SidebarToggleWidget`（在用组件，StatefulWidget 化） | 本次唯一功能性改动 |
| `lib/main_container.dart:854-866` | 挂载点（AnimatedPositioned 250ms） | 未动（UX-08） |
| `lib/widgets/sidebar.dart:606-678` | `SemicirclePainter`（半圆绘制） | **零改动**，颜色本就参数化 |
| `lib/widgets/sidebar.dart:206` | 死代码删除备注 | 原 `buildSemicircleToggle` 已删（0 调用点，用户批准） |
| `lib/widgets/editor_preview_builder.dart:256` | 主题设计器预览（独立简化版） | 未动，预览仍有效 |
| `lib/theme/app_theme_manager.dart:77-79` | toggleBg/toggleBorder/toggleIcon 令牌 | 未动，6 主题+自定义主题全覆盖 |

## 5. 关键数据结构

```dart
// hover 渐亮：t 由 TweenAnimationBuilder 0→1 驱动（200ms，无 curve=linear，
// 与导航项 AnimatedContainer 默认曲线一致）
fillColor:   Color.lerp(AppColors.toggleBg,     AppColors.toggleIcon, 0.14 * t)!,
borderColor: Color.lerp(AppColors.toggleBorder, AppColors.toggleIcon, 0.4  * t)!,
// isLeft 语义：isLeft = !侧栏收起 → chevron_left → 点击后收起
final action = widget.isLeft ? '收起侧边栏' : '展开侧边栏';
```

## 6. 历史决策与踩过的坑

- **BUG-05**：painter 颜色曾硬编码，已令牌化为 `AppColors.toggleBg/toggleBorder/toggleIcon`
  （app_colors.dart:72-74），BPM 导入窗口覆盖层（bpm_theme_controller.dart:367-369）
  也映射了这三色，改色必须走主题系统。
- **UX-08**：按钮位置曾随折叠瞬时跳跃，已用 `AnimatedPositioned`（250ms
  easeOutCubic）与侧栏 `AnimatedContainer` 同步，勿改回瞬时定位。
- **UX-25 半途而废的教训**：可访问性改进当时做在了死代码 `buildSemicircleToggle`
  上（0 调用点），在用组件从未受益——「给无人调用的方法加无障碍」等于没加。
- **死代码删除**：`buildSemicircleToggle` 经用户批准已删（2026-09-11）；
  `Sidebar.onToggle` 字段保留（公开 API，暂无消费方），main_container.dart:795
  的传参保留。

## 7. 当前进度

- [x] 审计：确认按钮现状、死代码、主题链路（2026-09-11）
- [x] 变更计划获批（用户批准含死代码删除）
- [x] `SidebarToggleWidget` 交互层适配（hover/按压/Tooltip/Semantics/字重/命中区）
- [x] 死代码删除 + 留痕注释
- [x] analyze 两文件 0 新增 error（6 条 info 均为存量）
- [x] 全量 test（需去代理跑，见 §8）
- [ ] **真机视觉验收**（用户）：hover 渐亮/移出渐隐、Tooltip、6 主题+自定义
      主题+背景图下观感、展开/收起滑动、点击功能

## 8. 已知问题

| 问题 | 严重度 | 是否已定位 | 备注 |
|------|--------|-----------|------|
| 本会话 shell 注入 `HTTP_PROXY/HTTPS_PROXY=127.0.0.1:55282` 导致 flutter_tester WebSocket 全挂（27 套件 0 加载） | ⚠️ 环境问题 | ✅ | 跑测试须 `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy` 前缀；与项目代码无关 |
| `Icons.weight: 700` 对 MaterialIcons 静态字体可能为 no-op | ⚪ | ✅ | 与死代码版本一致，无害 |

## 9. 待办

- [ ] 真机验收（§7 清单）
- [ ] （远期）若主题设计器需要「hover 预览色」，可把 lerp 规则提为令牌

## 10. ⛔ 不要动的地方

- **`SemicirclePainter` 本体**（sidebar.dart:606-678）：半圆造型是历史设计，
  颜色已参数化，改形状=破坏用户要求保留的设计。
- **尺寸 17×34 / 图标 16px / 位置公式**（main_container.dart:854-866 与
  widget 内 SizedBox）：与侧栏 71/224 宽度联动，改一处会错位。
- **主题三令牌**：自定义主题（主题设计器）与 BPM 导入窗口覆盖层都依赖，
  勿替换为其他颜色或硬编码。
