# COMMUNITY-LINKS · 社群入口与官方链接直达

> 2026-10-23 实施。需求源：用户口头需求（4 处 UI 位置）。代码验证状态见文末。

## 1. 目标

给用户两条「找得到我们」的路：**反馈/交流**（QQ 群）与**信息源**（GitHub 仓库、项目官网），
全部在客户端内一键直达，不让用户去别处搜。

## 2. 单一事实源

`lib/core/app_links.dart`：

| 常量 | 值 |
|---|---|
| `AppLinks.githubRepo` | `https://github.com/HardManOfficial/Chrono-Tide` |
| `AppLinks.officialWebsite` | `http://www.chronotide.site` |
| `AppLinks.qqGroupInvite` | `https://qm.qq.com/q/bfBwMSBiJU`（官网社区区同源） |
| `AppLinks.qqGroupNumber` | `1091837834` |
| `AppLinks.qqGroupName` | `时之汐社` |
| `AppLinks.qqGroupQrAsset` | `assets/images/qq_group_qr.png`（316×364，官网同源素材） |

> 换群 / 换官网时**只改这一个文件**。二维码图直接替换同名 asset 即可（尺寸变了要同步
> `user_profile_modal._buildGroupQrOverlay` 里的等比高度 `200 * 364 / 316`）。

## 3. 三处入口

| 位置 | 实现 | 文件 |
|---|---|---|
| 用户资料面板 ·「为小站充电」标题行右侧【加入群聊】 | 组件内 Stack 遮罩 + 二维码卡片 | `widgets/user_profile_modal.dart` `_buildGroupEntryChip` / `_buildGroupQrOverlay` |
| 设置 → 关于应用 · 左下角「了解我们」两个文字链接 | 内容区改「可滚动主体 + 底部链接区」 | `widgets/settings_modal.dart` `_buildAboutContent` / `_buildAboutLinks` |
| 探索大厅 → 文档与趣味 → 介绍 · 两枚直达胶囊 | 正文下方 Wrap（`_LinkPill`） | `widgets/explore_hall/docs_section.dart` `_buildIntroWithLinks` |

打开方式统一 `WebsiteBookmarkService.openExternal(url)`（零依赖 + http/https 白名单）。

## 4. 🔴 下次动这块必须知道的坑

1. **用户资料面板在根 Overlay 上**（`main_container.dart:965` `OverlayEntry`）⇒ 组件内
   `showDialog` / `showGeneralDialog` 弹的路由层会被本窗口遮挡。二维码面板因此做成
   **同层 Stack**（`_showGroupQr`）。要加别的弹层也照这个模式。
2. 遮罩必须 `ClipRRect(AppRadius.xl)`，否则矩形色块会在窗口圆角外露出直角。
3. 文字链接必须包 `IntrinsicWidth` —— `InteractiveWrapper` 内部 AnimatedContainer 的
   `alignment: center` 在松约束下撑满整行，可点区会横跨全宽。
4. 关于页用了 `Expanded + SingleChildScrollView`，**不要**把外层 Column 改回
   `mainAxisSize.min`（会把左下角链接顶到内容中间，且在 520 最小高度下溢出）。

## 5. 验证状态

- ✅ 进程内 analyzer：4 文件 errors=0，无新增 warning。
- ⏳ 未跑 `flutter test`、未真机走查（231 故障期）。待补：
  `flutter test test/explore_hall/ test/widgets/` + 四处点击走查（含窄窗口 960×540 与最小设置窗 820×520）。
