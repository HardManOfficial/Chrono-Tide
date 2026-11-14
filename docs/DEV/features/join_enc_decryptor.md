# .enc 程序化解密（join_enc_decryptor，Phase 4）

> 智能解压二期（原定独立 Phase 0 先行）。第四轮真机反馈时开发者指示
> 「一口气完成整套方案，包括 .enc 的程序化解密」（2026-10-04 语音），
> 故与解压-入库解耦、两板块计划窗同轮落地。
> **状态：Phase 4 全部落地（代码接入完成 + 探针 8/8 复验 + 进程内 analyze 6 文件 0 error，2026-10-04）。⏳ 真机用真实 .enc 样本做权威兼容性验证。**

---

## 0. 结论摘要（TL;DR）

| 项 | 结论 |
|----|------|
| 目标 | 单文件导入拖入 `.enc`（S.S.E. File Encryptor，Paranoia Works）→ 计划窗识别 → 用户给第 1 层密码 → Dart 原生解密出 zip → 自动续链解压 |
| 路线 | **Dart 原生移植**（淘汰 PFTE CLI——需 Java 运行时 +100MB；淘汰 Web 版——离线/大文件不可行） |
| 容器 | **仅 v4**（SSE 1.8+ 默认）：8B 头 `SSEFE`+ver+algo+params → 32B salt → CTR 加密 32B checkcode → Zip64 密文 → 尾部 32B Blake3 MAC |
| 密码链 | 码点转换 → UTF-8 → HKDF(HMAC-Skein1024/1024) 256B → Argon2id(t=10·2^tm, m=10240·2^mm, p=4, 256B) → HKDF-SHA3-512 ×3（key/nonce/authKey） |
| 密码语义 | `.enc` 解密消耗**计划第 1 层密码**（探测层 0 的预设）；解出的 zip 若再加密 → 第 2 层密码框，顺序自然 |
| 一期算法 | code 0 = AES-256（SSE 默认算法，实际样本 99%）；其余算法码报「暂不支持」 |
| MAC | 解密侧**跳过** Blake3 MAC 校验（移植成本 > 收益）；完整性 = checkcode 正则（密码错即中断）+ zip CRC32 兜底 |
| 验证 | dev_probe/enc_probe 探针 8/8：Skein-1024 BC golden KAT ×3 + Argon2id RFC 9106 §5.3（双实现）+ 确定性 ×2 + 往返自洽 |

## 1. 格式逆向（PFTE 源码实证）

来源：`git clone --depth 1 https://gitlab.com/paranoia-works/paranoia-encryption-tools-for-pc.git`
→ `.workbuddy/pfte_src/`（SSEBaseEngine + CryptoLibs，1065 文件，不进 git）。

### 1.1 容器布局（Encryptor.java :1455-1480 加密侧 / :1960-2160 解密侧）

```
[0..7]    preamble 8B: 'SSEFE' + version(=4) + algorithmCode + customParamsByte
[8..39]   salt 32B（明文）
[40..71]  checkcode 32B（CTR 加密；明文 = a-z0-9 伪随机校验码）
[72..]    Zip64 容器密文
[末-31..] MAC 32B（Blake3 keyed(authKey)；解密侧跳过）
```

- checkcode 快速密码验证：解密首 32B，`[^a-z0-9]` 命中 → InvalidPassword（:2029）
- CheckCodeParserInputStream = 透传流（末尾 32B MAC 摘走不透传），**CTR 计数器跨
  checkcode 段与 zip 段连续**：checkcode 占 keystream block 0-1，zip 从 block 2 起
- CipherInputStreamCTRPIV4.read 的 counter 推进按缓冲区整块；底层流填满语义下
  等价于连续标准 CTR（keystream = E(key, nonce+i)，大端 +1）

### 1.2 密码链（v4，逐字节对齐 Encryptor.java）

1. `convertToCodePoints`（:2451）：ASCII 32-126 保留，其余字符 → 十进制码点数字串
   （'contraseña' → 'contrase241a'）；`Helpers.toBytes(pw,false)` = UTF-8
2. `l0PWHashV3`（:2204-2246，FILE purpose）= HKDF(HMAC-Skein1024/1024, ikm=pwb,
   salt="memorySalt", info="memoryInfo", **256B**)
3. Argon2id（Argon2Params.java：FE 只认内部 version=3）：
   t = 10·2^(customParamsByte 低 4 位)，m = 10240·2^(高 4 位) KiB，p(h)=4，
   输出 **256B**（Argon2Provider.Argon2idHash 第 4 参 = bytes）
4. `deriveParamsArgon2id`（:2286-2325）三段 HKDF-SHA3-512：
   encKey(argonOut,"encKeySalt","encKeyInfo",keySize/8)、
   nonce(argonOut,"nonceSalt","nonceInfo",blockSize/8)、
   authKey(argonOut,"authKeySalt","authKeyInfo",v4=32)
5. 算法表（:2558-2676）：AES-256 code 0（key 32B/块 16B）；文件头默认 customParamsByte
   = 0x11（getCustomParamsByteFE revision 0）→ **t=20, m=20480KiB**

## 2. 实现

| 文件 | 内容 |
|------|------|
| `lib/services/enc/skein_threefish.dart` | Threefish-1024（仅加密方向，80 轮展开）+ Skein-1024 纯哈希，**自移植**（pointycastle 3.9.1 无 Skein；移植自 PFTE 内嵌 BC SkeinEngine/ThreefishEngine）。实现 pointycastle `Digest` 接口（HMac 可包装）。注意：Java `x >>> -n` → Dart 显式 `x >>> (64-n)`；Dart VM int 64 位 wrap 与 Java long 一致 |
| `lib/services/enc/enc_decryptor.dart` | 主解密器：头解析（v4/AES 限定）→ 密码链（自写 HKDF——pointycastle `HKDFKeyDerivator` 按算法名查块长表，Skein 不在表内）→ 流式 CTR 解密（64KB 缓冲，checkcode 先验）→ 产物 zip |
| `lib/services/archive_inspector.dart` | 魔数表 + `('SSEFE','enc')`；`_plausibleExts['enc']`、`_archiveExtHints` + `.enc`；`buildPlan` enc 分支（不跑 7z l，needsPassword=true，warning 提示） |
| `lib/services/extract_manager.dart` | `_executePlanExtract` enc 层分支（解密产物 zip 落临时层 → `continue` 续链下一层；zip 登记 `_taskOwnedTempArchives`）+ `_decryptEncLayer`（密码候选队列/补输弹窗与 `_extractSingleFormat` 同构） |
| `lib/pages/join/widgets/archive_plan_dialog.dart` | `_formatOptions` + 'enc'（手动加层可选）；`_formatLabel('enc')` = 'ENC·解密' |
| `pubspec.yaml` | + `pointycastle: ^3.9.1` |
| `dev_probe/enc_probe/` | `probe_enc.dart`（8 项验证）+ `probe_h0.dart`（RFC H0 中间值对照） |

### 2.1 执行期行为

```
用户拖入 game.enc
→ handleFileSelected: sniff 命中 'enc' → buildPlan: layer0(realFormat='enc', needsPassword=true)
→ 计划窗：第 1 层 = ENC·解密 · 密码（用户填第 1 层密码框）
→ extract_manager._executePlanExtract 第 1 层 currentFormat='enc'
   → _decryptEncLayer：候选队列 = [用户预设第1层, 记忆库, 内置表]（空密码跳过）
   → EncWrongPasswordException → 轮换；队列耗尽 → onPasswordNeeded 补输弹窗
   → 成功 → 产物 game.enc.decrypted.zip 落临时层 N → currentPath=zip, currentFormat='zip' → continue
→ 第 2 层起完全复用既有 zip 解压/重扫/续链（zip 若加密 → 用户第 2 层密码框）
```

## 3. 验证（dev_probe/enc_probe）

探针 8/8 PASS（2026-10-04，dart.exe 直跑，231 期间原生 flutter test 不可用）：

| # | 验证 | 结果 |
|---|------|------|
| 1 | Skein-1024/1024 空消息 = `0fff9563bb32...`（BC SkeinDigestTest / Skein 1.3 NIST golden KAT） | ✅ |
| 2 | Skein-1024/1024 M128 消息 = `96ca81f586c8...` | ✅ |
| 3 | Skein-1024/512 M128 消息 = `5d0416f49c2d...` | ✅ |
| 4 | Argon2id RFC 9106 §5.3（p=4,T=32,m=32,t=3 + secret/AD）= `0d640df58d78...`（pointycastle native_int 与 register64 双实现一致） | ✅ |
| 5-6 | Skein 大输出确定性 / doFinal-reset 复用语义 | ✅ |
| 7 | H0 中间值（probe_h0.dart，Blake2b-512 prehash）= RFC `2889de48...` | ✅ |
| 8 | .enc 往返自洽（Dart 组装 mini 容器 → decrypt → payload 逐字节一致；含 CTR 分段续接 + checkcode 验证） | ✅ |

**性能实测**：全链解密 100KB 样本（含 Argon2id t=20/m=20480/p=4 KDF）= **1.83s**，
可接受（一次性 KDF，大文件时 CTR 部分流式占比极小）。

### 3.1 排障记录（移植过程中踩过的坑）

- **Skein first 标志**：`_ubiStart` 漏置 tweak bit62（first）→ 三条 KAT 全错；
  修正为 `_t1First | (type << 56)` + 块满后 `&= ~_t1First`
- **向量错源**：asecuritysite 在线计算器的 Skein-1024-512 空消息值与 BC golden KAT
  不符（不可信）；以 bc-java `SkeinDigestTest.java`（Skein 1.3 NIST CD）为准
- **RFC 向量张冠李戴**：`c814d9d1...` 是 §5.2 **Argon2i** 的 tag；Argon2id 的期望是
  §5.3 `0d640df5...` —— 差点误判 pointycastle 有 bug（实际完全正确）
- **pointycastle HKDF**：`HKDFKeyDerivator` 按 `algorithmName` 查块长表，
  Skein-1024 不在表内直接崩 → 自写 RFC 5869 HKDF（与 BC HKDFBytesGenerator 语义一致）
- **231 管道故障**：flutter pub get / analyze / test 阵发不可用 → pointycastle 手动
  `dart pub cache add` + 注入 `.dart_tool/package_config.json`；analyze 走进程内探针

## 4. 边界与风险

- **v1-v3 旧版 .enc 不支持**（头布局/KDF 完全不同）：解密器报「暂不支持格式版本 N」。
  社区现行 SSE 1.8+ 产物均为 v4；如真机遇到 v3 再评估
- **非 AES 算法不支持**（RC6/Serpent/Twofish/Blowfish/GOST/Threefish/SHACAL2/C4 复合，
  pointycastle 缺失）：报「暂不支持加密算法代码 N（当前仅支持 AES-256）」。
  SSE File Encryptor 默认即 AES-256
- **MAC 跳过**：恶意构造的 .enc（密文被篡改）解密产物 zip CRC32 会失败 → 解压层报
  完整性错误，不会静默入库
- **真实样本权威验证未做**：往返自洽只能证明实现自洽；「与官方 Java 产物逐字节兼容」
  需真机用用户手里的真实 .enc + 密码走查（⏳ 待办）
- **老路径（非计划驱动）不接 .enc**：老路径无密码来源，7z 也不识别，报「无法识别的
  压缩格式」属预期；单文件导入全走计划路径
- **pubspec.lock**：231 期间 `pub get` 未跑成，lock 暂无 pointycastle 条目；
  真机 build 前的 pub get 会自动补齐（pubspec.yaml 已声明）

## 5. 待办（⏳）

- 真机全链走查：真实 .enc → 计划窗（ENC·解密层 + 密码）→ 解密 → zip 续链 →
  入库；同时验证补输弹窗与密码记忆
- 原生 `flutter analyze` / `flutter test` 恢复后补跑全量（本轮进程内探针 0 error）
- 可选优化：Argon2id 纯 Dart KDF ~1.8s，若真机体验不佳再考虑 FFI 原生库（暂不做，
  避免增加原生依赖）
