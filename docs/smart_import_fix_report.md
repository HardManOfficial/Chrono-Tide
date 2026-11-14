# 智能自动导入板块 — 功能修复与优化说明

## 一、问题原因分析

### 1. 目标文件夹无法移除（关键 Bug）

**根因：按钮点击区域实际只有 16x16 像素，而非设计预期的 32x32。**

`smart_import_section.dart` 中的移除/排除规则/入库/忽略按钮使用 `InkWell + Container(width:32, height:32, child: Icon(size:16))` 结构。但 `Container` 未设置 `color` 属性，导致 Flutter 的命中测试（hit test）只识别到 `Icon` 的 16x16 绘制区域，而非 Container 的 32x32 空间。`InkWell` 默认使用 `HitTestBehavior.deferToChild`，因此只有点击到图标本身才会触发 `onTap`。

在扫描期间（每 500ms 触发一次 `setState` 重建），频繁的 widget 重建进一步降低了点击命中率，导致按钮"频繁点击失效"。

### 2. 目标文件夹无法进行设置调整（关键 Bug）

**根因：排除规则编辑器在每次 widget 重建时覆盖用户输入。**

`_buildExcludeEditor` 方法在 `build()` 中执行 `_excludeController.text = folder.excludePatterns.join(', ')`，这意味着每次 widget 重建都会重置文本控制器的内容。扫描期间每 500ms 重建一次，用户正在输入的排除规则会被立刻覆盖为已保存的值，导致编辑器完全不可用。

### 3. 路径显示大小写丢失

**根因：`addWatchFolder` 使用 `PathNormalizer.forCompare()` 存储路径，该方法会小写化路径。**

`forCompare` 专为路径比较设计（统一小写、统一分隔符），不适合用于显示。存储的路径被小写化后，UI 上显示的监控路径丢失了原始大小写（如 `D:\Games` 显示为 `d:\games`），影响可读性。

### 4. 操作逻辑不一致

- 添加操作有 SnackBar 反馈，移除/排除规则更新无反馈
- 添加操作触发即时扫描，重新启用文件夹不触发扫描

### 5. 识别算法覆盖面不足

- CJK 附属文件夹关键词只覆盖 4 个（补丁/存档/备份/汉化），遗漏修正/追加/特典/攻略/おまけ/初回/限定等
- 救援规则仅覆盖 CJK 目录名的游戏，遗漏英文命名的便携式 GAL 游戏
- 引擎特征表缺少部分引擎（XNA/FNA/MonoGame/Godot/emote/Pages 等）
- `_collectEntries` 子目录数量无上限，超大目录可能耗尽内存

## 二、解决方案概述

### 修复 1：按钮点击区域（`smart_import_section.dart`）

为所有 `InkWell` 按钮内的 `Container` 添加 `color: Colors.transparent`，使整个 32x32 区域参与命中测试：

```dart
InkWell(
  onTap: () => _removeWatchFolder(folder),
  child: Container(
    width: 32, height: 32,
    color: Colors.transparent,  // ← 关键修复
    child: Icon(Icons.close, size: 16),
  ),
)
```

涉及按钮：排除规则编辑、移除、入库、忽略（共 4 处）。

### 修复 2：排除规则编辑器（`smart_import_section.dart`）

将控制器文本初始化从 `build()` 移到 `_toggleExcludeEditor()`，仅在打开编辑器时设置一次：

```dart
void _toggleExcludeEditor(WatchFolder folder) {
  setState(() {
    if (_editingExcludePath == folder.path) {
      _editingExcludePath = null;
    } else {
      _editingExcludePath = folder.path;
      _excludeController.text = folder.excludePatterns.join(', ');  // 仅此处设置
    }
  });
}
```

### 修复 3：路径存储与匹配（`watch_folder_service.dart`）

- 存储改用 `PathNormalizer.forStore()`（保留原始大小写）
- 新增 `_findFolder()` 辅助方法，所有匹配操作统一用 `forCompare` 双侧规范化比较
- `_stopWatching` 使用实际存储路径（而非输入路径）作为 watcher Map 的 key

```dart
WatchFolder? _findFolder(String path) {
  final normalized = PathNormalizer.forCompare(path);
  for (final f in _watchFolders) {
    if (PathNormalizer.forCompare(f.path) == normalized) return f;
  }
  return null;
}
```

### 修复 4：操作反馈一致性（`smart_import_section.dart`）

- 移除操作：添加 SnackBar "已移除监控路径"
- 排除规则更新：添加 SnackBar "排除规则已更新" / "已清空排除规则"

### 修复 5：重新启用触发扫描（`smart_import_section.dart`）

开关 `onTap` 改为 async，检测从禁用→启用时触发 `scanAllNow()`：

```dart
onTap: () async {
  final wasEnabled = folder.enabled;
  await WatchFolderService.instance.toggleFolderEnabled(folder.path);
  if (!wasEnabled) {
    await WatchFolderService.instance.scanAllNow();
  }
},
```

### 修复 6：扫描算法优化（`gal_game_detector.dart`）

- **CJK 关键词扩展**：新增 修正/追加/特典/攻略/おまけ/初回/限定 共 7 个关键词
- **引擎特征扩展**：新增 kagparser/emote/pages/xna/fna/monogame/godot/unreal 共 8 个引擎
- **救援规则2**：非 CJK 目录名 + exe + 2+ 特征目录/脚本/数据包 → 判定为游戏
- **安全上限**：`_collectEntries` 新增子目录 500 上限 + 循环内提前 break

## 三、测试验证

### 测试文件

| 文件 | 测试数 | 覆盖范围 |
|------|--------|----------|
| `test/smart_import/gal_game_detector_test.dart` | 23 | 引擎识别、救援规则、负信号排除、CJK关键词、边界条件 |
| `test/smart_import/path_normalizer_test.dart` | 19 | 路径规范化、大小写匹配、子目录判断、深度计算 |
| `test/smart_import/watch_folder_service_test.dart` | 28 | 添加/移除/切换/排除规则、逻辑一致性、持久化 |
| **合计** | **70** | **全部通过** |

### 测试覆盖的关键场景

1. **强信号引擎识别**：Kirikiri / Ren'Py / Unity / NScripter / SiglusEngine
2. **救援规则1**：CJK目录名 + exe + 特征目录（无强信号）
3. **救援规则2**：非CJK目录名 + exe + 2+特征目录
4. **负信号排除**：系统目录 / 开发项目标记 / 通用目录名
5. **CJK附属关键词**：补丁/存档/特典/攻略/おまけ
6. **路径大小写不敏感匹配**：添加/移除/切换/排除规则
7. **操作逻辑一致性**：添加→移除→添加、添加→禁用→启用、多路径独立操作
8. **持久化**：配置在 loadSettings 后恢复
9. **边界条件**：不存在路径、空目录、重复添加、安全移除

## 四、修改文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `lib/pages/join/widgets/smart_import_section.dart` | 修复+优化 | 按钮点击区域、排除编辑器、操作反馈、启用触发扫描 |
| `lib/services/watch_folder_service.dart` | 修复+优化 | 路径存储改用forStore、匹配改用_findFolder+forCompare |
| `lib/pages/join/utils/gal_game_detector.dart` | 优化 | CJK关键词扩展、引擎特征扩展、救援规则2、安全上限 |
| `test/smart_import/gal_game_detector_test.dart` | 新增 | 23个测试 |
| `test/smart_import/path_normalizer_test.dart` | 新增 | 19个测试 |
| `test/smart_import/watch_folder_service_test.dart` | 新增 | 28个测试 |
