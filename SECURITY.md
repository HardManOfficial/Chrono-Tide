# 安全政策

## 凭据处理

- **禁止**把 API Key、OAuth client secret、站点 Cookie、Personal Access Token、账号密码
  或私钥写入本仓库的任何文件（含 `docs/`、`dev_probe/`、`test/` 与 CI 配置）。
- 需要凭据时，使用编译期注入（`--dart-define=...`），或运行时由使用者在
  「设置 → 元数据 → 平台凭证」中填写。本地配置文件应加入 `.gitignore`。
- 打包脚本、推送脚本与 CI 中不得以 `https://user:token@github.com/...` 形式内嵌令牌；
  请使用凭据管理器 / SSH key / 环境变量。

## 本仓库的脱敏说明

开源快照在导出时对源码与历史开发文档做过统一扫描，命中以下模式的内容均已替换为
`<REDACTED>` 或改为编译期注入：

- GitHub PAT / OAuth token / Bearer token
- `apiKey` / `client_secret` / `access_token` / `hash_secret` / `password` 等 long literal
- 内嵌凭据的 URL、Cookie 字面量、私钥块、私人邮箱
- SDK 中的第三方应用凭据（NextMoe API Key、Hikarinagi client id / secret）

**注意**：脱敏只覆盖已知模式。贡献者提交 PR 前请自行检查是否引入了新的凭据。

## 报告问题

- 普通 Bug / 功能建议：开 [Issue](https://github.com/HardManOfficial/Chrono-Tide/issues)。
- 疑似凭据泄露等敏感问题：**不要**在公开 Issue 里贴出具体值，请通过仓库所有者提供的
  私密渠道联系，并同时轮换相关凭据。

## 依赖与二进制

仓库内的第三方二进制（解压 / 转区 / 运行库等）仅用于本地构建，许可与获取方式见
`THIRD-PARTY-NOTICES.md`。分发二次开发产物时请自行确认上游许可是否允许再分发。
