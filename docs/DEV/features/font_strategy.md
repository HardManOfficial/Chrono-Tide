# 字体策略（三字体分工）— 功能档案

> 状态：**现行 v2.2**（2026-09-08）。演进：v0 打包三字体（Inter 缺失/ZhiMangXing 3.88MB/Mali）
> → v1 全系统字体（用户实测"丑"，废弃）→ v2 内置三字体（ZCOOL KuaiLe）→
> v2.1 F1 换得意黑 → **v2.2 子集安全网修正（GB2312 一级字表）**。

## 方案（勿推翻，除非用户要求）

| 角色 | 字体 | family 声明 | 用途 | 子集大小 |
|---|---|---|---|---|
| F1 中文装饰大标题 | 得意黑 SmileySans-Oblique（OFL，单字重，italicAngle -8°） | `SmileySans` | 24-38px 装饰标题（display/headline/titleLarge/heading） | 996KB |
| F2 英文/数字装饰 | Outfit（OFL） | `Outfit` | 装饰数字/版本号（decorativeNumber） | 17KB |
| F3 UI 功能字体 | Noto Sans CJK SC Regular（OFL） | `NotoSansSC` | 11-16px 按钮/标签/正文/卡片标题 | 986KB |

- 接线点：`pubspec.yaml` fonts 段（:66-75）+ `lib/theme/app_styles.dart`
  （3 常量 :14/:17/:20 + 25 TextStyle 按角色分字体）。
- 决策记录：得意黑 w400 本身重笔画，**标题禁止再加 w700 合成粗体**
  （v2.0 事故：Skia 合成把笔画糊在一起）；详情页主标题 maxLines 3（:1275-1281）。

## 子集化方法（重建指南）

1. 源字体放 `%TEMP%\smiley\`：
   - `SmileySans-Oblique.ttf`：GitHub `atelier-anchor/smiley-sans` Releases v2.0.1（2.57MB）
   - `NotoSansCJKsc-Regular.otf`：GitHub `notofonts/noto-cjk`（15.7MB；
     raw.githubusercontent 直连被代理干扰时走 jsdelivr：`cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/...`）
2. 扫描字符集：`python dev_tmp_charset_scan.py`（扫 lib/**/*.dart 非注释字符 → `dev_tmp_charset.txt`）
3. 子集化：`PYTHONPATH=<fontTools目录> python dev_tmp_subset_smiley.py`
   （字符集 = 扫描 ∪ **GB2312 一级字表 3755 字，gb2312 codec 区位 16-55 生成**
   ∪ 常用符号；F3 专用瘦身配置在内）
4. 验证：fontTools 断言 GB2312-L1 零缺口（脚本/验证片段见 DEV_LOG v2.2 条目）

⚠️ **历史教训**：所谓"安全网"绝不能用 `range(0x4E00, 0x4E00+3500)` 码位切片
（部首序≠字频序，GB2312 一级缺一半）；`pyftsubset` 的 `drop_tables` 是**整体
替换**语义，覆盖时必须把默认丢弃表（vhea/vmtx 等）写全，否则竖排表回流体积翻倍。

## 已知边界

- F1 得意黑**不含日文汉字**（181 个 lib 扫描字回退系统字，如 両乗価侶）——源字体
  固有限制，全量打包也无解；F3 Noto CJK 全覆盖。
- 子集不含 GB2312 二级字与生僻字 → 库内极生僻游戏名仍回退系统字（可接受；
  如需覆盖改用 GB2312 全表 6763 字重建，F1 约 +300KB / F3 约 +700KB）。
- 得意黑是斜体设计（-8°），为字体风格而非 bug。
- **未做真机视觉验证**（字体总包 1999KB）。
