# 从源码构建与二次开发

## 1. 环境

| 项 | 值 |
| --- | --- |
| Flutter | 3.24.3 |
| Dart | 3.5.3 |
| 目标平台 | Windows 10 / 11 x64 |
| 编译工具 | Visual Studio 2022，勾选「使用 C++ 的桌面开发」 |

```bash
flutter --version
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

产物位于 `build/windows/x64/runner/Release/`。

## 2. 凭据注入

源码中不含任何真实密钥。依赖密钥的元数据源通过 Dart 编译期常量读取：

```bash
flutter build windows --release \
  --dart-define=NEXTMOE_API_KEY=<你自己的密钥> \
  --dart-define=HIKARINAGI_CLIENT_ID=<你自己的应用 ID> \
  --dart-define=HIKARINAGI_CLIENT_SECRET=<你自己的应用密钥>
```

对应源码（均为 `String.fromEnvironment(..., defaultValue: '')`）：

| 编译期变量 | 源码位置 |
| --- | --- |
| `NEXTMOE_API_KEY` | `lib/packages/luna_metadata_sdk/lib/services/nextmoe_service.dart` |
| `HIKARINAGI_CLIENT_ID` | `lib/packages/luna_metadata_sdk/lib/services/hikarinagi_service.dart` |
| `HIKARINAGI_CLIENT_SECRET` | 同上 |

未注入时这几个元数据源不可用（对应服务会检测空值并跳过），其余功能不受影响。
其它平台凭证（Bangumi PAT、2DFan Cookie 等）请在应用内
「设置 → 元数据 → 平台凭证」填写，凭证只保存在本机。

## 3. 目录与文档

- `docs/DEV/STATUS_MAP.md`：功能模块地图
- `docs/DEV/DECISIONS.md`：架构决策记录（ADR）
- `docs/DEV/SESSION_HANDOFF.md`：开发进度与真机待办
- `docs/DEV/DEV_LOG.md`：开发日志
- `docs/DEV/features/*.md`：各功能方案与实施记录
- `CHANGELOG.md`：版本变更记录

## 4. 安装包

`ChronoTide_Setup.iss` 为 Inno Setup 脚本，`Dev/scripts/` 为项目自带的双击式打包面板。
版本号统一由 `pubspec.yaml`、`ChronoTide_Setup.iss`、`VERSION` 与 `CHANGELOG.md` 维护，
发版时请同步更新。

## 5. 验证手段

除 `flutter analyze` / `flutter test` 外，项目还提供 `dev_probe/` 下的行为与渲染探针，
可用项目内 Dart SDK 直接运行：

```bash
flutter/bin/cache/dart-sdk/bin/dart.exe --packages=.dart_tool/package_config.json \
  dev_probe/<探针名>.dart
```

## 6. 提交规范

- 一个改动一个提交，说明「为什么改」。
- 不要提交 `build/`、`.dart_tool/`、`Games/`、`data/`、用户数据与任何凭据。
- 运行期二进制的许可见 `THIRD-PARTY-NOTICES.md`。
